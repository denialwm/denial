//! Persistent native audio and monitor-brightness controls.
//!
//! Input callbacks only enqueue bounded, coalescible commands. PulseAudio and
//! DDC/CI traffic stays on dedicated workers because either native library can
//! block while reconnecting or waiting for hardware.

use std::collections::HashMap;
use std::error::Error;
use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::fmt;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, SyncSender};
use std::sync::{Mutex, MutexGuard};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use libloading::Library;
use tracing::{info, warn};

const CONTROL_STEP: f64 = 0.05;
const MAX_AUDIO_LEVEL: f64 = 1.4;
const DDC_COALESCE_WINDOW: Duration = Duration::from_millis(24);
const COMMAND_QUEUE_CAPACITY: usize = 128;
const EVENT_QUEUE_CAPACITY: usize = 64;
const MAX_AUDIO_STREAMS: usize = 256;
const MAX_AUDIO_STREAM_NAME_BYTES: usize = 1024;
const MAX_BRIGHTNESS_CONNECTOR_BYTES: usize = 128;

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct AudioStreamState {
    pub(super) id: u32,
    pub(super) name: String,
    pub(super) level_percent: u8,
    pub(super) muted: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub(super) enum SystemControlEvent {
    AudioLevel { level: f64, request_serial: u32 },
    AudioStreams(Vec<AudioStreamState>),
    BrightnessLevel { monitor_id: i64, level: f64 },
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) enum AudioRequest {
    ReadLevel,
    SetLevel { level: f64, request_serial: u32 },
    RequestStreams,
    SetStreamLevel { stream_id: u32, level: f64 },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum AudioRequestDecodeError {
    InvalidSize(usize),
    UnsupportedCommand(u8),
}

impl fmt::Display for AudioRequestDecodeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidSize(size) => write!(formatter, "invalid audio packet size {size}"),
            Self::UnsupportedCommand(command) => {
                write!(formatter, "unsupported audio command {command}")
            }
        }
    }
}

impl Error for AudioRequestDecodeError {}

pub(super) fn decode_audio_request(packet: &[u8]) -> Result<AudioRequest, AudioRequestDecodeError> {
    match packet {
        [0] => Ok(AudioRequest::ReadLevel),
        [1, percent, serial @ ..] if serial.len() == size_of::<u32>() => {
            let request_serial = u32::from_le_bytes(
                serial
                    .try_into()
                    .expect("audio request serial length was checked"),
            );
            Ok(AudioRequest::SetLevel {
                level: f64::from((*percent).min(100)) / 100.0,
                request_serial,
            })
        }
        [2] => Ok(AudioRequest::RequestStreams),
        [3, id @ ..] if id.len() == size_of::<u32>() + 1 => {
            let stream_id = u32::from_le_bytes(
                id[..size_of::<u32>()]
                    .try_into()
                    .expect("audio stream identity length was checked"),
            );
            Ok(AudioRequest::SetStreamLevel {
                stream_id,
                level: f64::from(id[size_of::<u32>()].min(100)) / 100.0,
            })
        }
        [command, ..] if matches!(*command, 0..=3) || packet.is_empty() => {
            Err(AudioRequestDecodeError::InvalidSize(packet.len()))
        }
        [command, ..] => Err(AudioRequestDecodeError::UnsupportedCommand(*command)),
        [] => Err(AudioRequestDecodeError::InvalidSize(0)),
    }
}

#[derive(Clone, Debug, PartialEq)]
pub(super) enum BrightnessRequest {
    Read {
        connector: String,
        monitor_id: i64,
    },
    Set {
        connector: String,
        monitor_id: i64,
        level: f64,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum BrightnessRequestDecodeError {
    InvalidSize(usize),
    UnsupportedCommand(u8),
    InvalidMonitorId(i64),
    InvalidConnector,
}

impl fmt::Display for BrightnessRequestDecodeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidSize(size) => write!(formatter, "invalid brightness packet size {size}"),
            Self::UnsupportedCommand(command) => {
                write!(formatter, "unsupported brightness command {command}")
            }
            Self::InvalidMonitorId(monitor_id) => {
                write!(formatter, "invalid brightness monitor id {monitor_id}")
            }
            Self::InvalidConnector => write!(formatter, "invalid brightness connector"),
        }
    }
}

impl Error for BrightnessRequestDecodeError {}

pub(super) fn decode_brightness_request(
    packet: &[u8],
) -> Result<BrightnessRequest, BrightnessRequestDecodeError> {
    const HEADER_BYTES: usize = 12;
    if packet.len() < HEADER_BYTES {
        return Err(BrightnessRequestDecodeError::InvalidSize(packet.len()));
    }
    let command = packet[0];
    if command > 1 {
        return Err(BrightnessRequestDecodeError::UnsupportedCommand(command));
    }
    let monitor_id = i64::from_le_bytes(
        packet[1..9]
            .try_into()
            .expect("brightness monitor id has a fixed packet width"),
    );
    if monitor_id < 0 {
        return Err(BrightnessRequestDecodeError::InvalidMonitorId(monitor_id));
    }
    let connector_length = usize::from(u16::from_le_bytes(
        packet[10..12]
            .try_into()
            .expect("brightness connector length has a fixed packet width"),
    ));
    if connector_length == 0
        || connector_length > MAX_BRIGHTNESS_CONNECTOR_BYTES
        || packet.len() != HEADER_BYTES + connector_length
    {
        return Err(BrightnessRequestDecodeError::InvalidSize(packet.len()));
    }
    let connector = std::str::from_utf8(&packet[HEADER_BYTES..])
        .ok()
        .filter(|value| !value.contains('\0'))
        .ok_or(BrightnessRequestDecodeError::InvalidConnector)?
        .to_owned();
    match command {
        0 => Ok(BrightnessRequest::Read {
            connector,
            monitor_id,
        }),
        1 => Ok(BrightnessRequest::Set {
            connector,
            monitor_id,
            level: f64::from(packet[9].min(100)) / 100.0,
        }),
        _ => unreachable!("brightness command was range checked"),
    }
}

enum AudioCommand {
    ReadLevel,
    SetLevel { level: f64, request_serial: u32 },
    Adjust(f64),
    ToggleMute,
    RequestStreams,
    SetStreamLevel { stream_id: u32, level: f64 },
    Stop,
}

enum BrightnessCommand {
    Read {
        connector: String,
        monitor_id: i64,
    },
    Set {
        connector: String,
        monitor_id: i64,
        level: f64,
    },
    Adjust {
        connector: String,
        monitor_id: i64,
        delta: f64,
    },
    Stop,
}

#[derive(Clone)]
struct SystemControlEventSender {
    sender: SyncSender<SystemControlEvent>,
    pending: Arc<AtomicBool>,
}

impl SystemControlEventSender {
    fn new(sender: SyncSender<SystemControlEvent>, pending: Arc<AtomicBool>) -> Self {
        Self { sender, pending }
    }

    fn try_send(&self, event: SystemControlEvent) {
        // Publish before the bounded send so a concurrent main-thread swap
        // cannot miss an event which is already visible in the channel. Set
        // it again after success to close the inverse swap-before-send race.
        self.pending.store(true, Ordering::Release);
        if self.sender.try_send(event).is_ok() {
            self.pending.store(true, Ordering::Release);
        }
    }
}

/// Process-lifetime handles used by the compositor input path.
pub(super) struct SystemControls {
    audio_commands: SyncSender<AudioCommand>,
    brightness_commands: SyncSender<BrightnessCommand>,
    #[cfg_attr(not(feature = "flutter"), allow(dead_code))]
    events: Receiver<SystemControlEvent>,
    events_pending: Arc<AtomicBool>,
    audio_worker: Option<JoinHandle<()>>,
    brightness_worker: Option<JoinHandle<()>>,
}

impl SystemControls {
    pub(super) fn new() -> io::Result<Self> {
        let (events_tx, events) = mpsc::sync_channel(EVENT_QUEUE_CAPACITY);
        let events_pending = Arc::new(AtomicBool::new(false));
        let events_tx = SystemControlEventSender::new(events_tx, Arc::clone(&events_pending));
        let (audio_commands, audio_rx) = mpsc::sync_channel(COMMAND_QUEUE_CAPACITY);
        let audio_events = events_tx.clone();
        let subscription_commands = audio_commands.clone();
        let audio_worker = thread::Builder::new()
            .name("denial-audio".into())
            .spawn(move || {
                crate::cpu_scheduling::normalize_current_worker("audio");
                run_audio_worker(audio_rx, audio_events, subscription_commands);
            })?;

        let (brightness_commands, brightness_rx) = mpsc::sync_channel(COMMAND_QUEUE_CAPACITY);
        let brightness_worker = match thread::Builder::new()
            .name("denial-brightness".into())
            .spawn(move || {
                crate::cpu_scheduling::normalize_current_worker("brightness");
                run_brightness_worker(brightness_rx, events_tx);
            }) {
            Ok(worker) => worker,
            Err(error) => {
                let _ = audio_commands.send(AudioCommand::Stop);
                let _ = audio_worker.join();
                return Err(error);
            }
        };

        Ok(Self {
            audio_commands,
            brightness_commands,
            events,
            events_pending,
            audio_worker: Some(audio_worker),
            brightness_worker: Some(brightness_worker),
        })
    }

    pub(super) fn volume_up(&self) {
        self.adjust_audio(CONTROL_STEP);
    }

    pub(super) fn volume_down(&self) {
        self.adjust_audio(-CONTROL_STEP);
    }

    pub(super) fn toggle_mute(&self) {
        let _ = self.audio_commands.try_send(AudioCommand::ToggleMute);
    }

    pub(super) fn handle_audio_request(&self, request: AudioRequest) -> bool {
        let command = match request {
            AudioRequest::ReadLevel => AudioCommand::ReadLevel,
            AudioRequest::SetLevel {
                level,
                request_serial,
            } => AudioCommand::SetLevel {
                level,
                request_serial,
            },
            AudioRequest::RequestStreams => AudioCommand::RequestStreams,
            AudioRequest::SetStreamLevel { stream_id, level } => {
                AudioCommand::SetStreamLevel { stream_id, level }
            }
        };
        self.audio_commands.try_send(command).is_ok()
    }

    pub(super) fn handle_brightness_request(&self, request: BrightnessRequest) -> bool {
        let command = match request {
            BrightnessRequest::Read {
                connector,
                monitor_id,
            } => BrightnessCommand::Read {
                connector,
                monitor_id,
            },
            BrightnessRequest::Set {
                connector,
                monitor_id,
                level,
            } => BrightnessCommand::Set {
                connector,
                monitor_id,
                level,
            },
        };
        self.brightness_commands.try_send(command).is_ok()
    }

    fn adjust_audio(&self, delta: f64) {
        let _ = self.audio_commands.try_send(AudioCommand::Adjust(delta));
    }

    pub(super) fn brightness_up(&self, connector: String, monitor_id: i64) {
        self.adjust_brightness(connector, monitor_id, CONTROL_STEP);
    }

    pub(super) fn brightness_down(&self, connector: String, monitor_id: i64) {
        self.adjust_brightness(connector, monitor_id, -CONTROL_STEP);
    }

    fn adjust_brightness(&self, connector: String, monitor_id: i64, delta: f64) {
        let _ = self
            .brightness_commands
            .try_send(BrightnessCommand::Adjust {
                connector,
                monitor_id,
                delta,
            });
    }

    #[cfg_attr(not(feature = "flutter"), allow(dead_code))]
    pub(super) fn take_event_signal(&self) -> bool {
        self.events_pending.swap(false, Ordering::AcqRel)
    }

    #[cfg_attr(not(feature = "flutter"), allow(dead_code))]
    pub(super) fn try_event(&self) -> Option<SystemControlEvent> {
        self.events.try_recv().ok()
    }
}

impl Drop for SystemControls {
    fn drop(&mut self) {
        let _ = self.audio_commands.send(AudioCommand::Stop);
        let _ = self.brightness_commands.send(BrightnessCommand::Stop);
        if self
            .audio_worker
            .take()
            .is_some_and(|worker| worker.join().is_err())
        {
            warn!("native audio worker panicked during shutdown");
        }
        if self
            .brightness_worker
            .take()
            .is_some_and(|worker| worker.join().is_err())
        {
            warn!("native brightness worker panicked during shutdown");
        }
    }
}

#[path = "system_controls/audio.rs"]
mod audio;
#[path = "system_controls/brightness.rs"]
mod brightness;

use audio::run_audio_worker;
use brightness::run_brightness_worker;

#[cfg(test)]
#[path = "system_controls/tests.rs"]
mod tests;
