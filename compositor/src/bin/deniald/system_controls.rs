//! Persistent native audio and monitor-brightness controls.
//!
//! Input callbacks only enqueue bounded, coalescible commands. PulseAudio and
//! DDC/CI traffic stays on dedicated workers because either native library can
//! block while reconnecting or waiting for hardware.

use std::collections::HashMap;
use std::error::Error;
use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::fmt;
use std::io;
use std::ptr;
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

/// Process-lifetime handles used by the compositor input path.
pub(super) struct SystemControls {
    audio_commands: SyncSender<AudioCommand>,
    brightness_commands: SyncSender<BrightnessCommand>,
    #[cfg_attr(not(feature = "flutter"), allow(dead_code))]
    events: Receiver<SystemControlEvent>,
    audio_worker: Option<JoinHandle<()>>,
    brightness_worker: Option<JoinHandle<()>>,
}

impl SystemControls {
    pub(super) fn new() -> io::Result<Self> {
        let (events_tx, events) = mpsc::sync_channel(EVENT_QUEUE_CAPACITY);
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

    pub(super) fn handle_audio_request(&self, request: AudioRequest) {
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
        let _ = self.audio_commands.try_send(command);
    }

    pub(super) fn handle_brightness_request(&self, request: BrightnessRequest) {
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
        let _ = self.brightness_commands.try_send(command);
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

#[repr(C)]
struct PaThreadedMainloop {
    _private: [u8; 0],
}

#[repr(C)]
struct PaMainloopApi {
    _private: [u8; 0],
}

#[repr(C)]
struct PaContext {
    _private: [u8; 0],
}

#[repr(C)]
struct PaOperation {
    _private: [u8; 0],
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct PaSampleSpec {
    format: c_int,
    rate: u32,
    channels: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct PaChannelMap {
    channels: u8,
    map: [c_int; 32],
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct PaCVolume {
    channels: u8,
    values: [u32; 32],
}

#[repr(C)]
struct PaServerInfo {
    user_name: *const c_char,
    host_name: *const c_char,
    server_version: *const c_char,
    server_name: *const c_char,
    sample_spec: PaSampleSpec,
    default_sink_name: *const c_char,
    default_source_name: *const c_char,
    cookie: u32,
    channel_map: PaChannelMap,
}

#[repr(C)]
struct PaSinkInfoPrefix {
    name: *const c_char,
    index: u32,
    description: *const c_char,
    sample_spec: PaSampleSpec,
    channel_map: PaChannelMap,
    owner_module: u32,
    volume: PaCVolume,
    mute: c_int,
}

#[repr(C)]
struct PaProplist {
    _private: [u8; 0],
}

#[repr(C)]
struct PaSinkInputInfoPrefix {
    index: u32,
    name: *const c_char,
    owner_module: u32,
    client: u32,
    sink: u32,
    sample_spec: PaSampleSpec,
    channel_map: PaChannelMap,
    volume: PaCVolume,
    buffer_usec: u64,
    sink_usec: u64,
    resample_method: *const c_char,
    driver: *const c_char,
    mute: c_int,
    proplist: *mut PaProplist,
}

type ContextStateCallback = Option<unsafe extern "C" fn(*mut PaContext, *mut c_void)>;
type ServerInfoCallback =
    Option<unsafe extern "C" fn(*mut PaContext, *const PaServerInfo, *mut c_void)>;
type SinkInfoCallback =
    Option<unsafe extern "C" fn(*mut PaContext, *const PaSinkInfoPrefix, c_int, *mut c_void)>;
type SinkInputInfoCallback =
    Option<unsafe extern "C" fn(*mut PaContext, *const PaSinkInputInfoPrefix, c_int, *mut c_void)>;
type SuccessCallback = Option<unsafe extern "C" fn(*mut PaContext, c_int, *mut c_void)>;
type SubscriptionCallback = Option<unsafe extern "C" fn(*mut PaContext, u32, u32, *mut c_void)>;

struct PulseApi {
    _library: Library,
    mainloop_new: unsafe extern "C" fn() -> *mut PaThreadedMainloop,
    mainloop_free: unsafe extern "C" fn(*mut PaThreadedMainloop),
    mainloop_start: unsafe extern "C" fn(*mut PaThreadedMainloop) -> c_int,
    mainloop_stop: unsafe extern "C" fn(*mut PaThreadedMainloop),
    mainloop_lock: unsafe extern "C" fn(*mut PaThreadedMainloop),
    mainloop_unlock: unsafe extern "C" fn(*mut PaThreadedMainloop),
    mainloop_wait: unsafe extern "C" fn(*mut PaThreadedMainloop),
    mainloop_signal: unsafe extern "C" fn(*mut PaThreadedMainloop, c_int),
    mainloop_get_api: unsafe extern "C" fn(*mut PaThreadedMainloop) -> *mut PaMainloopApi,
    context_new: unsafe extern "C" fn(*mut PaMainloopApi, *const c_char) -> *mut PaContext,
    context_unref: unsafe extern "C" fn(*mut PaContext),
    context_connect:
        unsafe extern "C" fn(*mut PaContext, *const c_char, u32, *const c_void) -> c_int,
    context_disconnect: unsafe extern "C" fn(*mut PaContext),
    context_get_state: unsafe extern "C" fn(*const PaContext) -> c_int,
    context_set_state_callback:
        unsafe extern "C" fn(*mut PaContext, ContextStateCallback, *mut c_void),
    context_set_subscribe_callback:
        unsafe extern "C" fn(*mut PaContext, SubscriptionCallback, *mut c_void),
    context_subscribe:
        unsafe extern "C" fn(*mut PaContext, u32, SuccessCallback, *mut c_void) -> *mut PaOperation,
    context_get_server_info:
        unsafe extern "C" fn(*mut PaContext, ServerInfoCallback, *mut c_void) -> *mut PaOperation,
    context_get_sink_info_by_name: unsafe extern "C" fn(
        *mut PaContext,
        *const c_char,
        SinkInfoCallback,
        *mut c_void,
    ) -> *mut PaOperation,
    context_set_sink_volume_by_name: unsafe extern "C" fn(
        *mut PaContext,
        *const c_char,
        *const PaCVolume,
        SuccessCallback,
        *mut c_void,
    ) -> *mut PaOperation,
    context_set_sink_mute_by_name: unsafe extern "C" fn(
        *mut PaContext,
        *const c_char,
        c_int,
        SuccessCallback,
        *mut c_void,
    ) -> *mut PaOperation,
    context_get_sink_input_info_list: unsafe extern "C" fn(
        *mut PaContext,
        SinkInputInfoCallback,
        *mut c_void,
    ) -> *mut PaOperation,
    context_get_sink_input_info: unsafe extern "C" fn(
        *mut PaContext,
        u32,
        SinkInputInfoCallback,
        *mut c_void,
    ) -> *mut PaOperation,
    context_set_sink_input_volume: unsafe extern "C" fn(
        *mut PaContext,
        u32,
        *const PaCVolume,
        SuccessCallback,
        *mut c_void,
    ) -> *mut PaOperation,
    context_set_sink_input_mute: unsafe extern "C" fn(
        *mut PaContext,
        u32,
        c_int,
        SuccessCallback,
        *mut c_void,
    ) -> *mut PaOperation,
    operation_unref: unsafe extern "C" fn(*mut PaOperation),
    cvolume_avg: unsafe extern "C" fn(*const PaCVolume) -> u32,
    cvolume_set: unsafe extern "C" fn(*mut PaCVolume, u32, u32) -> *mut PaCVolume,
    proplist_gets: unsafe extern "C" fn(*const PaProplist, *const c_char) -> *const c_char,
}

impl PulseApi {
    fn load() -> Result<Self, String> {
        // SAFETY: the library name is fixed and every copied symbol remains
        // valid because the Library is retained by PulseApi for its lifetime.
        unsafe {
            let library = Library::new("libpulse.so.0")
                .map_err(|error| format!("could not load libpulse.so.0: {error}"))?;
            macro_rules! symbol {
                ($name:literal) => {
                    *library
                        .get(concat!($name, "\0").as_bytes())
                        .map_err(|error| format!("missing libpulse symbol {}: {error}", $name))?
                };
            }
            Ok(Self {
                mainloop_new: symbol!("pa_threaded_mainloop_new"),
                mainloop_free: symbol!("pa_threaded_mainloop_free"),
                mainloop_start: symbol!("pa_threaded_mainloop_start"),
                mainloop_stop: symbol!("pa_threaded_mainloop_stop"),
                mainloop_lock: symbol!("pa_threaded_mainloop_lock"),
                mainloop_unlock: symbol!("pa_threaded_mainloop_unlock"),
                mainloop_wait: symbol!("pa_threaded_mainloop_wait"),
                mainloop_signal: symbol!("pa_threaded_mainloop_signal"),
                mainloop_get_api: symbol!("pa_threaded_mainloop_get_api"),
                context_new: symbol!("pa_context_new"),
                context_unref: symbol!("pa_context_unref"),
                context_connect: symbol!("pa_context_connect"),
                context_disconnect: symbol!("pa_context_disconnect"),
                context_get_state: symbol!("pa_context_get_state"),
                context_set_state_callback: symbol!("pa_context_set_state_callback"),
                context_set_subscribe_callback: symbol!("pa_context_set_subscribe_callback"),
                context_subscribe: symbol!("pa_context_subscribe"),
                context_get_server_info: symbol!("pa_context_get_server_info"),
                context_get_sink_info_by_name: symbol!("pa_context_get_sink_info_by_name"),
                context_set_sink_volume_by_name: symbol!("pa_context_set_sink_volume_by_name"),
                context_set_sink_mute_by_name: symbol!("pa_context_set_sink_mute_by_name"),
                context_get_sink_input_info_list: symbol!("pa_context_get_sink_input_info_list"),
                context_get_sink_input_info: symbol!("pa_context_get_sink_input_info"),
                context_set_sink_input_volume: symbol!("pa_context_set_sink_input_volume"),
                context_set_sink_input_mute: symbol!("pa_context_set_sink_input_mute"),
                operation_unref: symbol!("pa_operation_unref"),
                cvolume_avg: symbol!("pa_cvolume_avg"),
                cvolume_set: symbol!("pa_cvolume_set"),
                proplist_gets: symbol!("pa_proplist_gets"),
                _library: library,
            })
        }
    }
}

struct PulseSignal {
    mainloop: *mut PaThreadedMainloop,
    signal: unsafe extern "C" fn(*mut PaThreadedMainloop, c_int),
}

struct PulseSubscription {
    commands: SyncSender<AudioCommand>,
}

const PA_SUBSCRIPTION_MASK_SINK: u32 = 1 << 0;
const PA_SUBSCRIPTION_MASK_SINK_INPUT: u32 = 1 << 2;
const PA_SUBSCRIPTION_MASK_SERVER: u32 = 1 << 7;
const PA_SUBSCRIPTION_EVENT_FACILITY_MASK: u32 = 0x0f;
const PA_SUBSCRIPTION_EVENT_SINK: u32 = 0;
const PA_SUBSCRIPTION_EVENT_SINK_INPUT: u32 = 2;
const PA_SUBSCRIPTION_EVENT_SERVER: u32 = 7;

unsafe extern "C" fn on_subscription_event(
    _context: *mut PaContext,
    event_type: u32,
    _index: u32,
    userdata: *mut c_void,
) {
    if userdata.is_null() {
        return;
    }
    // SAFETY: PulseConnection retains the subscription allocation until the
    // callback is unregistered and the threaded mainloop has stopped.
    let subscription = unsafe { &*userdata.cast::<PulseSubscription>() };
    match event_type & PA_SUBSCRIPTION_EVENT_FACILITY_MASK {
        PA_SUBSCRIPTION_EVENT_SINK | PA_SUBSCRIPTION_EVENT_SERVER => {
            let _ = subscription.commands.try_send(AudioCommand::ReadLevel);
        }
        PA_SUBSCRIPTION_EVENT_SINK_INPUT => {
            let _ = subscription.commands.try_send(AudioCommand::RequestStreams);
        }
        _ => {}
    }
}

unsafe extern "C" fn on_context_state(_context: *mut PaContext, userdata: *mut c_void) {
    if userdata.is_null() {
        return;
    }
    // SAFETY: PulseConnection pins this allocation until after the context is
    // disconnected and its threaded mainloop has stopped.
    let signal = unsafe { &*userdata.cast::<PulseSignal>() };
    // SAFETY: the callback is invoked by the live mainloop owning this handle.
    unsafe { (signal.signal)(signal.mainloop, 0) };
}

struct PulseConnection {
    mainloop: *mut PaThreadedMainloop,
    context: *mut PaContext,
    signal: Box<PulseSignal>,
    subscription: Box<PulseSubscription>,
    started: bool,
}

impl PulseConnection {
    fn connect(
        api: &PulseApi,
        subscription_commands: SyncSender<AudioCommand>,
    ) -> Result<Self, &'static str> {
        // SAFETY: all handles are created and destroyed through the matching
        // libpulse API and remain confined to the audio worker.
        unsafe {
            let mainloop = (api.mainloop_new)();
            if mainloop.is_null() {
                return Err("could not allocate PulseAudio mainloop");
            }
            let application = c"Denial Rust";
            let context = (api.context_new)((api.mainloop_get_api)(mainloop), application.as_ptr());
            if context.is_null() {
                (api.mainloop_free)(mainloop);
                return Err("could not allocate PulseAudio context");
            }
            let mut connection = Self {
                mainloop,
                context,
                signal: Box::new(PulseSignal {
                    mainloop,
                    signal: api.mainloop_signal,
                }),
                subscription: Box::new(PulseSubscription {
                    commands: subscription_commands,
                }),
                started: false,
            };
            (api.context_set_state_callback)(
                context,
                Some(on_context_state),
                (&mut *connection.signal as *mut PulseSignal).cast(),
            );
            (api.context_set_subscribe_callback)(
                context,
                Some(on_subscription_event),
                (&mut *connection.subscription as *mut PulseSubscription).cast(),
            );
            if (api.context_connect)(context, ptr::null(), 0, ptr::null()) < 0
                || (api.mainloop_start)(mainloop) < 0
            {
                connection.close(api);
                return Err("could not start PulseAudio connection");
            }
            connection.started = true;
            (api.mainloop_lock)(mainloop);
            while context_state_is_good((api.context_get_state)(context))
                && (api.context_get_state)(context) != PA_CONTEXT_READY
            {
                (api.mainloop_wait)(mainloop);
            }
            let ready = (api.context_get_state)(context) == PA_CONTEXT_READY;
            (api.mainloop_unlock)(mainloop);
            if !ready {
                connection.close(api);
                return Err("PulseAudio context did not become ready");
            }

            (api.mainloop_lock)(mainloop);
            let query = SuccessQuery {
                mainloop,
                signal: api.mainloop_signal,
                state: Mutex::new(SuccessQueryState {
                    done: false,
                    success: false,
                }),
            };
            let operation = (api.context_subscribe)(
                context,
                PA_SUBSCRIPTION_MASK_SINK
                    | PA_SUBSCRIPTION_MASK_SINK_INPUT
                    | PA_SUBSCRIPTION_MASK_SERVER,
                Some(on_success),
                (&query as *const SuccessQuery).cast_mut().cast(),
            );
            let subscribed = wait_for_success(api, &connection, operation, &query);
            (api.mainloop_unlock)(mainloop);
            if !subscribed {
                connection.close(api);
                return Err("could not subscribe to PulseAudio state changes");
            }
            info!("Denial Rust audio connected through native libpulse");
            Ok(connection)
        }
    }

    fn close(&mut self, api: &PulseApi) {
        // SAFETY: close is called at most once for handles owned by this value.
        unsafe {
            if !self.context.is_null() {
                if self.started {
                    (api.mainloop_lock)(self.mainloop);
                    (api.context_set_subscribe_callback)(self.context, None, ptr::null_mut());
                    (api.context_disconnect)(self.context);
                    (api.mainloop_unlock)(self.mainloop);
                }
                if self.started {
                    (api.mainloop_stop)(self.mainloop);
                }
                self.started = false;
                (api.context_unref)(self.context);
                self.context = ptr::null_mut();
            }
            if !self.mainloop.is_null() {
                (api.mainloop_free)(self.mainloop);
                self.mainloop = ptr::null_mut();
            }
        }
    }
}

const PA_CONTEXT_READY: c_int = 4;

fn context_state_is_good(state: c_int) -> bool {
    (0..=PA_CONTEXT_READY).contains(&state)
}

struct ServerQuery {
    mainloop: *mut PaThreadedMainloop,
    signal: unsafe extern "C" fn(*mut PaThreadedMainloop, c_int),
    state: Mutex<ServerQueryState>,
}

struct ServerQueryState {
    done: bool,
    sink: Option<CString>,
}

fn lock_unpoisoned<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

unsafe extern "C" fn on_server_info(
    _context: *mut PaContext,
    info: *const PaServerInfo,
    userdata: *mut c_void,
) {
    if userdata.is_null() {
        return;
    }
    // SAFETY: query lives on the waiting worker stack until this callback has
    // completed and the operation is unreferenced.
    let query = unsafe { &*userdata.cast::<ServerQuery>() };
    let mut state = lock_unpoisoned(&query.state);
    if !info.is_null() {
        // SAFETY: libpulse owns a valid info record for this callback.
        let sink = unsafe { (*info).default_sink_name };
        if !sink.is_null() {
            // SAFETY: PulseAudio strings are NUL-terminated for callback life.
            state.sink = Some(unsafe { CStr::from_ptr(sink) }.to_owned());
        }
    }
    state.done = true;
    drop(state);
    // SAFETY: this is the live mainloop associated with the query.
    unsafe { (query.signal)(query.mainloop, 0) };
}

struct SinkQuery {
    mainloop: *mut PaThreadedMainloop,
    signal: unsafe extern "C" fn(*mut PaThreadedMainloop, c_int),
    state: Mutex<SinkQueryState>,
}

struct SinkQueryState {
    done: bool,
    sink: Option<PulseSinkState>,
}

struct PulseSinkState {
    volume: PaCVolume,
    channels: u8,
    muted: bool,
}

unsafe extern "C" fn on_sink_info(
    _context: *mut PaContext,
    info: *const PaSinkInfoPrefix,
    end_of_list: c_int,
    userdata: *mut c_void,
) {
    if userdata.is_null() {
        return;
    }
    // SAFETY: query remains live until the operation completes.
    let query = unsafe { &*userdata.cast::<SinkQuery>() };
    let mut state = lock_unpoisoned(&query.state);
    if end_of_list != 0 {
        state.done = true;
    } else if !info.is_null() {
        // SAFETY: libpulse supplies a valid ABI-stable prefix for the callback.
        let info = unsafe { &*info };
        let channels = if info.channel_map.channels > 0 {
            info.channel_map.channels
        } else {
            info.volume.channels
        };
        if channels > 0 {
            state.sink = Some(PulseSinkState {
                volume: info.volume,
                channels,
                muted: info.mute != 0,
            });
        }
    }
    let done = state.done;
    drop(state);
    if done {
        // SAFETY: this is the live mainloop associated with the query.
        unsafe { (query.signal)(query.mainloop, 0) };
    }
}

struct SinkInputQuery {
    mainloop: *mut PaThreadedMainloop,
    signal: unsafe extern "C" fn(*mut PaThreadedMainloop, c_int),
    state: Mutex<SinkInputQueryState>,
}

struct SinkInputQueryState {
    done: bool,
    input: Option<PulseSinkInputState>,
}

struct PulseSinkInputState {
    channels: u8,
    muted: bool,
}

unsafe extern "C" fn on_sink_input_info(
    _context: *mut PaContext,
    info: *const PaSinkInputInfoPrefix,
    end_of_list: c_int,
    userdata: *mut c_void,
) {
    if userdata.is_null() {
        return;
    }
    // SAFETY: query remains live until the introspection operation completes.
    let query = unsafe { &*userdata.cast::<SinkInputQuery>() };
    let mut state = lock_unpoisoned(&query.state);
    if end_of_list != 0 {
        state.done = true;
    } else if !info.is_null() {
        // SAFETY: libpulse supplies the stable sink-input prefix for callback life.
        let info = unsafe { &*info };
        let channels = if info.channel_map.channels > 0 {
            info.channel_map.channels
        } else {
            info.volume.channels
        };
        if channels > 0 {
            state.input = Some(PulseSinkInputState {
                channels,
                muted: info.mute != 0,
            });
        }
    }
    let done = state.done;
    drop(state);
    if done {
        // SAFETY: this is the live mainloop associated with the query.
        unsafe { (query.signal)(query.mainloop, 0) };
    }
}

struct SinkInputListQuery {
    mainloop: *mut PaThreadedMainloop,
    signal: unsafe extern "C" fn(*mut PaThreadedMainloop, c_int),
    proplist_gets: unsafe extern "C" fn(*const PaProplist, *const c_char) -> *const c_char,
    cvolume_avg: unsafe extern "C" fn(*const PaCVolume) -> u32,
    state: Mutex<SinkInputListQueryState>,
}

struct SinkInputListQueryState {
    done: bool,
    success: bool,
    streams: Vec<AudioStreamState>,
}

unsafe extern "C" fn on_sink_input_list(
    _context: *mut PaContext,
    info: *const PaSinkInputInfoPrefix,
    end_of_list: c_int,
    userdata: *mut c_void,
) {
    if userdata.is_null() {
        return;
    }
    // SAFETY: query remains live until the list operation completes.
    let query = unsafe { &*userdata.cast::<SinkInputListQuery>() };
    let mut state = lock_unpoisoned(&query.state);
    if end_of_list < 0 {
        state.done = true;
    } else if end_of_list > 0 {
        state.done = true;
        state.success = true;
    } else if !info.is_null() && state.streams.len() < MAX_AUDIO_STREAMS {
        // SAFETY: libpulse supplies the stable sink-input prefix for callback life.
        let info = unsafe { &*info };
        // SAFETY: volume is a complete pa_cvolume copied from libpulse.
        let average = unsafe { (query.cvolume_avg)(&info.volume) };
        state.streams.push(AudioStreamState {
            id: info.index,
            // SAFETY: every inspected string is owned by libpulse for callback life.
            name: unsafe { pulse_stream_name(query.proplist_gets, info) },
            level_percent: ((f64::from(average) / 65_536.0).clamp(0.0, 1.0) * 100.0).round() as u8,
            muted: info.mute != 0,
        });
    }
    let done = state.done;
    drop(state);
    if done {
        // SAFETY: this is the live mainloop associated with the query.
        unsafe { (query.signal)(query.mainloop, 0) };
    }
}

unsafe fn pulse_stream_name(
    proplist_gets: unsafe extern "C" fn(*const PaProplist, *const c_char) -> *const c_char,
    info: &PaSinkInputInfoPrefix,
) -> String {
    let mut selected = ptr::null();
    if !info.proplist.is_null() {
        for property in [c"application.name", c"media.name", c"application.id"] {
            // SAFETY: proplist and property are valid for the active callback.
            let value = unsafe { proplist_gets(info.proplist, property.as_ptr()) };
            if !value.is_null() {
                selected = value;
                break;
            }
        }
    }
    if selected.is_null() {
        selected = info.name;
    }
    let name = if selected.is_null() {
        "Unknown application".into()
    } else {
        // SAFETY: selected is a callback-lifetime NUL-terminated PulseAudio string.
        unsafe { CStr::from_ptr(selected) }
            .to_string_lossy()
            .into_owned()
    };
    truncate_utf8(name, MAX_AUDIO_STREAM_NAME_BYTES)
}

fn truncate_utf8(mut value: String, maximum: usize) -> String {
    if value.len() <= maximum {
        return value;
    }
    let mut boundary = maximum;
    while boundary > 0 && !value.is_char_boundary(boundary) {
        boundary -= 1;
    }
    value.truncate(boundary);
    value
}

struct SuccessQuery {
    mainloop: *mut PaThreadedMainloop,
    signal: unsafe extern "C" fn(*mut PaThreadedMainloop, c_int),
    state: Mutex<SuccessQueryState>,
}

struct SuccessQueryState {
    done: bool,
    success: bool,
}

unsafe extern "C" fn on_success(_context: *mut PaContext, success: c_int, userdata: *mut c_void) {
    if userdata.is_null() {
        return;
    }
    // SAFETY: query remains live until the operation completes.
    let query = unsafe { &*userdata.cast::<SuccessQuery>() };
    let mut state = lock_unpoisoned(&query.state);
    state.success = success != 0;
    state.done = true;
    drop(state);
    // SAFETY: this is the live mainloop associated with the query.
    unsafe { (query.signal)(query.mainloop, 0) };
}

fn query_default_sink(api: &PulseApi, connection: &PulseConnection) -> Option<CString> {
    // SAFETY: the threaded mainloop lock serializes every context operation;
    // the stack query stays live until its operation is complete or the
    // context leaves a usable state.
    unsafe {
        let query = ServerQuery {
            mainloop: connection.mainloop,
            signal: api.mainloop_signal,
            state: Mutex::new(ServerQueryState {
                done: false,
                sink: None,
            }),
        };
        (api.mainloop_lock)(connection.mainloop);
        let operation = (api.context_get_server_info)(
            connection.context,
            Some(on_server_info),
            (&query as *const ServerQuery).cast_mut().cast(),
        );
        if operation.is_null() {
            (api.mainloop_unlock)(connection.mainloop);
            return None;
        }
        while !lock_unpoisoned(&query.state).done
            && context_state_is_good((api.context_get_state)(connection.context))
        {
            (api.mainloop_wait)(connection.mainloop);
        }
        (api.operation_unref)(operation);
        (api.mainloop_unlock)(connection.mainloop);
        lock_unpoisoned(&query.state).sink.take()
    }
}

fn query_sink(api: &PulseApi, connection: &PulseConnection, sink: &CStr) -> Option<PulseSinkState> {
    // SAFETY: see query_default_sink; the same ownership and locking rules
    // apply to this introspection operation.
    unsafe {
        let query = SinkQuery {
            mainloop: connection.mainloop,
            signal: api.mainloop_signal,
            state: Mutex::new(SinkQueryState {
                done: false,
                sink: None,
            }),
        };
        (api.mainloop_lock)(connection.mainloop);
        let operation = (api.context_get_sink_info_by_name)(
            connection.context,
            sink.as_ptr(),
            Some(on_sink_info),
            (&query as *const SinkQuery).cast_mut().cast(),
        );
        if operation.is_null() {
            (api.mainloop_unlock)(connection.mainloop);
            return None;
        }
        while !lock_unpoisoned(&query.state).done
            && context_state_is_good((api.context_get_state)(connection.context))
        {
            (api.mainloop_wait)(connection.mainloop);
        }
        (api.operation_unref)(operation);
        (api.mainloop_unlock)(connection.mainloop);
        lock_unpoisoned(&query.state).sink.take()
    }
}

fn query_sink_input(
    api: &PulseApi,
    connection: &PulseConnection,
    stream_id: u32,
) -> Option<PulseSinkInputState> {
    // SAFETY: the threaded-mainloop lock serializes this operation and the
    // stack query stays live through the terminal callback.
    unsafe {
        let query = SinkInputQuery {
            mainloop: connection.mainloop,
            signal: api.mainloop_signal,
            state: Mutex::new(SinkInputQueryState {
                done: false,
                input: None,
            }),
        };
        (api.mainloop_lock)(connection.mainloop);
        let operation = (api.context_get_sink_input_info)(
            connection.context,
            stream_id,
            Some(on_sink_input_info),
            (&query as *const SinkInputQuery).cast_mut().cast(),
        );
        if operation.is_null() {
            (api.mainloop_unlock)(connection.mainloop);
            return None;
        }
        while !lock_unpoisoned(&query.state).done
            && context_state_is_good((api.context_get_state)(connection.context))
        {
            (api.mainloop_wait)(connection.mainloop);
        }
        (api.operation_unref)(operation);
        (api.mainloop_unlock)(connection.mainloop);
        lock_unpoisoned(&query.state).input.take()
    }
}

fn query_sink_inputs(
    api: &PulseApi,
    connection: &PulseConnection,
) -> Option<Vec<AudioStreamState>> {
    // SAFETY: the threaded-mainloop lock serializes this operation and the
    // callback never retains any server-owned pointers.
    unsafe {
        let query = SinkInputListQuery {
            mainloop: connection.mainloop,
            signal: api.mainloop_signal,
            proplist_gets: api.proplist_gets,
            cvolume_avg: api.cvolume_avg,
            state: Mutex::new(SinkInputListQueryState {
                done: false,
                success: false,
                streams: Vec::with_capacity(16),
            }),
        };
        (api.mainloop_lock)(connection.mainloop);
        let operation = (api.context_get_sink_input_info_list)(
            connection.context,
            Some(on_sink_input_list),
            (&query as *const SinkInputListQuery).cast_mut().cast(),
        );
        if operation.is_null() {
            (api.mainloop_unlock)(connection.mainloop);
            return None;
        }
        while !lock_unpoisoned(&query.state).done
            && context_state_is_good((api.context_get_state)(connection.context))
        {
            (api.mainloop_wait)(connection.mainloop);
        }
        (api.operation_unref)(operation);
        (api.mainloop_unlock)(connection.mainloop);
        let mut state = lock_unpoisoned(&query.state);
        state.success.then(|| std::mem::take(&mut state.streams))
    }
}

fn wait_for_success(
    api: &PulseApi,
    connection: &PulseConnection,
    operation: *mut PaOperation,
    query: &SuccessQuery,
) -> bool {
    if operation.is_null() {
        return false;
    }
    // SAFETY: caller holds the threaded mainloop lock; query stays alive until
    // the operation callback finishes or the context fails.
    unsafe {
        while !lock_unpoisoned(&query.state).done
            && context_state_is_good((api.context_get_state)(connection.context))
        {
            (api.mainloop_wait)(connection.mainloop);
        }
        (api.operation_unref)(operation);
    }
    lock_unpoisoned(&query.state).success
}

fn read_pulse_level(api: &PulseApi, connection: &PulseConnection) -> Option<f64> {
    let sink = query_default_sink(api, connection)?;
    let state = query_sink(api, connection, &sink)?;
    // SAFETY: state.volume is a complete pa_cvolume copied from libpulse.
    let current = unsafe { (api.cvolume_avg)(&state.volume) } as f64 / 65_536.0;
    Some(current.clamp(0.0, 1.0))
}

fn set_pulse_level(api: &PulseApi, connection: &PulseConnection, target: f64) -> Option<f64> {
    let sink = query_default_sink(api, connection)?;
    let state = query_sink(api, connection, &sink)?;
    let target = target.clamp(0.0, MAX_AUDIO_LEVEL);
    let pulse_level = (target * 65_536.0).round() as u32;
    let mut volume = PaCVolume::default();
    // SAFETY: volume is a complete pa_cvolume and channels came from the
    // validated server record. The context stays locked through completion.
    unsafe {
        (api.cvolume_set)(&mut volume, u32::from(state.channels), pulse_level);
        (api.mainloop_lock)(connection.mainloop);
    }
    let volume_query = SuccessQuery {
        mainloop: connection.mainloop,
        signal: api.mainloop_signal,
        state: Mutex::new(SuccessQueryState {
            done: false,
            success: false,
        }),
    };
    // SAFETY: sink and volume remain live through the synchronous wait.
    let volume_operation = unsafe {
        (api.context_set_sink_volume_by_name)(
            connection.context,
            sink.as_ptr(),
            &volume,
            Some(on_success),
            (&volume_query as *const SuccessQuery).cast_mut().cast(),
        )
    };
    let volume_applied = wait_for_success(api, connection, volume_operation, &volume_query);
    // SAFETY: balances the lock acquired above.
    unsafe { (api.mainloop_unlock)(connection.mainloop) };
    if !volume_applied {
        return None;
    }

    if target > 0.0 && state.muted {
        // Raising a level is an explicit request to hear that output.
        // SAFETY: the context operation is serialized by the mainloop lock.
        unsafe { (api.mainloop_lock)(connection.mainloop) };
        let mute_query = SuccessQuery {
            mainloop: connection.mainloop,
            signal: api.mainloop_signal,
            state: Mutex::new(SuccessQueryState {
                done: false,
                success: false,
            }),
        };
        // SAFETY: sink remains live through the synchronous wait.
        let mute_operation = unsafe {
            (api.context_set_sink_mute_by_name)(
                connection.context,
                sink.as_ptr(),
                0,
                Some(on_success),
                (&mute_query as *const SuccessQuery).cast_mut().cast(),
            )
        };
        let unmuted = wait_for_success(api, connection, mute_operation, &mute_query);
        // SAFETY: balances the lock acquired above.
        unsafe { (api.mainloop_unlock)(connection.mainloop) };
        if !unmuted {
            return None;
        }
    }

    Some(target.clamp(0.0, 1.0))
}

fn adjust_pulse_level(api: &PulseApi, connection: &PulseConnection, delta: f64) -> Option<f64> {
    let sink = query_default_sink(api, connection)?;
    let state = query_sink(api, connection, &sink)?;
    // SAFETY: state.volume is a valid pa_cvolume copied from libpulse.
    let current = unsafe { (api.cvolume_avg)(&state.volume) } as f64 / 65_536.0;
    let target = (current + delta).clamp(0.0, MAX_AUDIO_LEVEL);
    set_pulse_level(api, connection, target)
}

fn toggle_pulse_mute(api: &PulseApi, connection: &PulseConnection) -> Option<f64> {
    let sink = query_default_sink(api, connection)?;
    let state = query_sink(api, connection, &sink)?;
    // SAFETY: the context operation is serialized by the threaded-mainloop lock.
    unsafe { (api.mainloop_lock)(connection.mainloop) };
    let query = SuccessQuery {
        mainloop: connection.mainloop,
        signal: api.mainloop_signal,
        state: Mutex::new(SuccessQueryState {
            done: false,
            success: false,
        }),
    };
    // SAFETY: sink remains live through the synchronous wait.
    let operation = unsafe {
        (api.context_set_sink_mute_by_name)(
            connection.context,
            sink.as_ptr(),
            if state.muted { 0 } else { 1 },
            Some(on_success),
            (&query as *const SuccessQuery).cast_mut().cast(),
        )
    };
    let applied = wait_for_success(api, connection, operation, &query);
    // SAFETY: balances the lock acquired above.
    unsafe { (api.mainloop_unlock)(connection.mainloop) };
    if !applied {
        return None;
    }
    // SAFETY: state.volume is a valid server-provided pa_cvolume.
    let level = unsafe { (api.cvolume_avg)(&state.volume) } as f64 / 65_536.0;
    Some(level.clamp(0.0, 1.0))
}

fn set_pulse_stream_level(
    api: &PulseApi,
    connection: &PulseConnection,
    stream_id: u32,
    target: f64,
) -> Option<()> {
    let state = query_sink_input(api, connection, stream_id)?;
    let target = target.clamp(0.0, 1.0);
    let mut volume = PaCVolume::default();
    // SAFETY: volume is a complete pa_cvolume and the channel count came from
    // the queried sink-input record.
    unsafe {
        (api.cvolume_set)(
            &mut volume,
            u32::from(state.channels),
            (target * 65_536.0).round() as u32,
        );
        (api.mainloop_lock)(connection.mainloop);
    }
    let volume_query = SuccessQuery {
        mainloop: connection.mainloop,
        signal: api.mainloop_signal,
        state: Mutex::new(SuccessQueryState {
            done: false,
            success: false,
        }),
    };
    // SAFETY: volume remains live through the synchronous wait.
    let operation = unsafe {
        (api.context_set_sink_input_volume)(
            connection.context,
            stream_id,
            &volume,
            Some(on_success),
            (&volume_query as *const SuccessQuery).cast_mut().cast(),
        )
    };
    let applied = wait_for_success(api, connection, operation, &volume_query);
    // SAFETY: balances the lock acquired above.
    unsafe { (api.mainloop_unlock)(connection.mainloop) };
    if !applied {
        return None;
    }

    if target > 0.0 && state.muted {
        // SAFETY: the context operation is serialized by the mainloop lock.
        unsafe { (api.mainloop_lock)(connection.mainloop) };
        let mute_query = SuccessQuery {
            mainloop: connection.mainloop,
            signal: api.mainloop_signal,
            state: Mutex::new(SuccessQueryState {
                done: false,
                success: false,
            }),
        };
        // SAFETY: no borrowed callback data escapes the wait.
        let operation = unsafe {
            (api.context_set_sink_input_mute)(
                connection.context,
                stream_id,
                0,
                Some(on_success),
                (&mute_query as *const SuccessQuery).cast_mut().cast(),
            )
        };
        let unmuted = wait_for_success(api, connection, operation, &mute_query);
        // SAFETY: balances the lock acquired above.
        unsafe { (api.mainloop_unlock)(connection.mainloop) };
        if !unmuted {
            return None;
        }
    }
    Some(())
}

fn run_audio_worker(
    commands: Receiver<AudioCommand>,
    events: SyncSender<SystemControlEvent>,
    subscription_commands: SyncSender<AudioCommand>,
) {
    let api = match PulseApi::load() {
        Ok(api) => api,
        Err(error) => {
            warn!(%error, "native audio controls are unavailable");
            while !matches!(commands.recv(), Ok(AudioCommand::Stop) | Err(_)) {}
            return;
        }
    };
    let mut connection: Option<PulseConnection> = None;
    let mut failure_latched = false;
    'worker: while let Ok(first) = commands.recv() {
        let mut level = None;
        let mut delta = 0.0;
        let mut toggle_mute = false;
        let mut state_requested = false;
        let mut request_serial = 0;
        let mut streams_requested = false;
        let mut stream_levels = HashMap::<u32, f64>::new();

        let mut absorb = |command: AudioCommand| -> bool {
            match command {
                AudioCommand::ReadLevel => state_requested = true,
                AudioCommand::SetLevel {
                    level: next,
                    request_serial: serial,
                } => {
                    level = Some(next.clamp(0.0, 1.0));
                    delta = 0.0;
                    request_serial = serial;
                    state_requested = true;
                }
                AudioCommand::Adjust(next) => {
                    if let Some(current) = level.as_mut() {
                        *current = (*current + next).clamp(0.0, MAX_AUDIO_LEVEL);
                    } else {
                        delta = (delta + next).clamp(-MAX_AUDIO_LEVEL, MAX_AUDIO_LEVEL);
                    }
                    request_serial = 0;
                    state_requested = true;
                }
                AudioCommand::ToggleMute => {
                    toggle_mute = !toggle_mute;
                    state_requested = true;
                    request_serial = 0;
                }
                AudioCommand::RequestStreams => streams_requested = true,
                AudioCommand::SetStreamLevel { stream_id, level } => {
                    stream_levels.insert(stream_id, level.clamp(0.0, 1.0));
                    streams_requested = true;
                }
                AudioCommand::Stop => return false,
            }
            true
        };

        if !absorb(first) {
            break;
        }
        while let Ok(command) = commands.try_recv() {
            if !absorb(command) {
                break 'worker;
            }
        }
        if connection.is_none() {
            match PulseConnection::connect(&api, subscription_commands.clone()) {
                Ok(active) => connection = Some(active),
                Err(error) => {
                    if !std::mem::replace(&mut failure_latched, true) {
                        warn!(%error, "native audio connection failed");
                    }
                    continue;
                }
            }
        }
        let Some(active) = connection.as_ref() else {
            continue;
        };
        let mut operation_failed = false;
        if let Some(level) = level {
            operation_failed |= set_pulse_level(&api, active, level).is_none();
        }
        if !operation_failed && delta != 0.0 {
            operation_failed |= adjust_pulse_level(&api, active, delta).is_none();
        }
        if !operation_failed && toggle_mute {
            operation_failed |= toggle_pulse_mute(&api, active).is_none();
        }
        if !operation_failed {
            for (stream_id, stream_level) in stream_levels {
                if set_pulse_stream_level(&api, active, stream_id, stream_level).is_none() {
                    // A stream can legitimately disappear between the UI
                    // snapshot and this write. Refresh the list without
                    // discarding the otherwise healthy Pulse connection.
                    streams_requested = true;
                }
            }
        }
        if !operation_failed && state_requested {
            if let Some(level) = read_pulse_level(&api, active) {
                let _ = events.try_send(SystemControlEvent::AudioLevel {
                    level,
                    request_serial,
                });
            } else {
                operation_failed = true;
            }
        }
        if !operation_failed && streams_requested {
            if let Some(streams) = query_sink_inputs(&api, active) {
                let _ = events.try_send(SystemControlEvent::AudioStreams(streams));
            } else {
                operation_failed = true;
            }
        }
        if operation_failed {
            if !std::mem::replace(&mut failure_latched, true) {
                warn!("native PulseAudio operation failed; reconnecting");
            }
            if let Some(mut active) = connection.take() {
                active.close(&api);
            }
        } else {
            failure_latched = false;
        }
    }
    if let Some(mut active) = connection {
        active.close(&api);
    }
}

type DdcDisplayRef = *mut c_void;
type DdcDisplayHandle = *mut c_void;

#[repr(C)]
struct DdcIoPath {
    io_mode: c_int,
    path: c_int,
}

#[repr(C)]
struct DdcDisplayInfo2 {
    marker: [c_char; 4],
    dispno: c_int,
    path: DdcIoPath,
    usb_bus: c_int,
    usb_device: c_int,
    mfg_id: [c_char; 4],
    model_name: [c_char; 14],
    serial: [c_char; 14],
    product_code: u16,
    edid_bytes: [u8; 128],
    vcp_version: [u8; 2],
    dref: DdcDisplayRef,
    drm_card_connector: [c_char; 32],
    drm_card_connector_found_by: c_int,
    drm_connector_id: i16,
    unused: [*mut c_void; 8],
}

#[repr(C)]
#[derive(Default)]
struct DdcNonTableValue {
    maximum_high: u8,
    maximum_low: u8,
    current_high: u8,
    current_low: u8,
}

struct DdcApi {
    _library: Library,
    init: unsafe extern "C" fn(*const c_char, c_int, c_int, *mut *mut *mut c_char) -> c_int,
    redetect_displays: unsafe extern "C" fn() -> c_int,
    get_display_refs: unsafe extern "C" fn(bool, *mut *mut DdcDisplayRef) -> c_int,
    get_display_info: unsafe extern "C" fn(DdcDisplayRef, *mut *mut DdcDisplayInfo2) -> c_int,
    free_display_info: unsafe extern "C" fn(*mut DdcDisplayInfo2),
    open_display: unsafe extern "C" fn(DdcDisplayRef, bool, *mut DdcDisplayHandle) -> c_int,
    close_display: unsafe extern "C" fn(DdcDisplayHandle) -> c_int,
    get_value: unsafe extern "C" fn(DdcDisplayHandle, u8, *mut DdcNonTableValue) -> c_int,
    set_value: unsafe extern "C" fn(DdcDisplayHandle, u8, u8, u8) -> c_int,
    status_description: unsafe extern "C" fn(c_int) -> *const c_char,
}

impl DdcApi {
    fn load() -> Result<Self, String> {
        // SAFETY: fixed SONAMEs are tried in ABI order and copied symbols stay
        // live because this value owns the loaded library.
        unsafe {
            let library = Library::new("libddcutil.so.5")
                .or_else(|_| Library::new("libddcutil.so"))
                .map_err(|error| format!("could not load libddcutil: {error}"))?;
            macro_rules! symbol {
                ($name:literal) => {
                    *library
                        .get(concat!($name, "\0").as_bytes())
                        .map_err(|error| format!("missing libddcutil symbol {}: {error}", $name))?
                };
            }
            Ok(Self {
                init: symbol!("ddca_init2"),
                redetect_displays: symbol!("ddca_redetect_displays"),
                get_display_refs: symbol!("ddca_get_display_refs"),
                get_display_info: symbol!("ddca_get_display_info2"),
                free_display_info: symbol!("ddca_free_display_info2"),
                open_display: symbol!("ddca_open_display2"),
                close_display: symbol!("ddca_close_display"),
                get_value: symbol!("ddca_get_non_table_vcp_value"),
                set_value: symbol!("ddca_set_non_table_vcp_value2"),
                status_description: symbol!("ddca_rc_desc"),
                _library: library,
            })
        }
    }

    fn describe_status(&self, status: c_int) -> String {
        // SAFETY: libddcutil returns a process-lifetime NUL-terminated string.
        let description = unsafe { (self.status_description)(status) };
        if description.is_null() {
            format!("status {status}")
        } else {
            // SAFETY: checked for null and owned by the loaded library.
            unsafe { CStr::from_ptr(description) }
                .to_string_lossy()
                .into_owned()
        }
    }
}

struct DdcWorker {
    api: DdcApi,
    displays: HashMap<String, DdcDisplayRef>,
    desired: HashMap<String, f64>,
    failure_latched: HashMap<String, bool>,
}

impl DdcWorker {
    fn start() -> Result<Self, String> {
        let api = DdcApi::load()?;
        // DDCA_SYSLOG_NEVER=0 and DISABLE_CONFIG_FILE=1 keep this embedded
        // controller independent from global logging/configuration policy.
        // SAFETY: null optional arguments and flags follow ddca_init2's API.
        let status = unsafe { (api.init)(ptr::null(), 0, 1, ptr::null_mut()) };
        if status != 0 {
            return Err(format!(
                "DDC initialization failed: {}",
                api.describe_status(status)
            ));
        }
        let mut worker = Self {
            api,
            displays: HashMap::new(),
            desired: HashMap::new(),
            failure_latched: HashMap::new(),
        };
        worker.refresh_displays(false)?;
        info!("Denial Rust brightness connected through native libddcutil");
        Ok(worker)
    }

    fn refresh_displays(&mut self, redetect: bool) -> Result<(), String> {
        if redetect {
            // SAFETY: called only on the dedicated DDC worker.
            let status = unsafe { (self.api.redetect_displays)() };
            if status != 0 {
                return Err(format!(
                    "DDC display redetection failed: {}",
                    self.api.describe_status(status)
                ));
            }
        }
        let mut references: *mut DdcDisplayRef = ptr::null_mut();
        // SAFETY: libddcutil returns its null-terminated reference array.
        let status = unsafe { (self.api.get_display_refs)(false, &mut references) };
        if status != 0 || references.is_null() {
            return Err(format!(
                "DDC display enumeration failed: {}",
                self.api.describe_status(status)
            ));
        }
        let mut displays = HashMap::new();
        let mut index = 0usize;
        loop {
            // SAFETY: get_display_refs promises a null-terminated array.
            let reference = unsafe { *references.add(index) };
            if reference.is_null() {
                break;
            }
            let mut info: *mut DdcDisplayInfo2 = ptr::null_mut();
            // SAFETY: reference came from the same library enumeration.
            let info_status = unsafe { (self.api.get_display_info)(reference, &mut info) };
            if info_status == 0 && !info.is_null() {
                // SAFETY: connector is a fixed NUL-terminated public field.
                let connector = unsafe {
                    CStr::from_ptr((*info).drm_card_connector.as_ptr())
                        .to_string_lossy()
                        .into_owned()
                };
                let connector = connector_from_ddc_name(&connector);
                if !connector.is_empty() {
                    displays.insert(connector, reference);
                }
                // SAFETY: info was allocated by ddca_get_display_info2.
                unsafe { (self.api.free_display_info)(info) };
            }
            index += 1;
        }
        self.displays = displays;
        if self.displays.is_empty() {
            Err("DDC found no controllable displays".into())
        } else {
            Ok(())
        }
    }

    fn display(&mut self, connector: &str) -> Option<DdcDisplayRef> {
        if let Some(reference) = self.displays.get(connector) {
            return Some(*reference);
        }
        self.refresh_displays(true).ok()?;
        self.displays.get(connector).copied()
    }

    fn read(&mut self, connector: &str, monitor_id: i64, events: &SyncSender<SystemControlEvent>) {
        self.control(connector, monitor_id, None, events);
    }

    fn set(
        &mut self,
        connector: &str,
        monitor_id: i64,
        level: f64,
        events: &SyncSender<SystemControlEvent>,
    ) {
        self.control(
            connector,
            monitor_id,
            Some(BrightnessChange::Set(level)),
            events,
        );
    }

    fn adjust(
        &mut self,
        connector: &str,
        monitor_id: i64,
        delta: f64,
        events: &SyncSender<SystemControlEvent>,
    ) {
        self.control(
            connector,
            monitor_id,
            Some(BrightnessChange::Adjust(delta)),
            events,
        );
    }

    fn control(
        &mut self,
        connector: &str,
        monitor_id: i64,
        change: Option<BrightnessChange>,
        events: &SyncSender<SystemControlEvent>,
    ) {
        let Some(reference) = self.display(connector) else {
            self.log_failure_once(connector, "has no matching DDC display");
            return;
        };
        let mut handle = ptr::null_mut();
        // SAFETY: reference is owned by libddcutil and all use is serialized.
        let open_status = unsafe { (self.api.open_display)(reference, false, &mut handle) };
        if open_status != 0 || handle.is_null() {
            let detail = self.api.describe_status(open_status);
            self.log_failure_once(connector, &format!("could not open DDC display: {detail}"));
            return;
        }

        let mut value = DdcNonTableValue::default();
        // SAFETY: handle is open and value is a complete response buffer.
        let read_status = unsafe { (self.api.get_value)(handle, 0x10, &mut value) };
        let maximum = u16::from_be_bytes([value.maximum_high, value.maximum_low]);
        let current = u16::from_be_bytes([value.current_high, value.current_low]);
        if read_status != 0 || maximum == 0 {
            // SAFETY: balances the successful open above.
            unsafe { (self.api.close_display)(handle) };
            let detail = self.api.describe_status(read_status);
            self.log_failure_once(connector, &format!("could not read VCP 0x10: {detail}"));
            return;
        }

        let actual = f64::from(current) / f64::from(maximum);
        let Some(change) = change else {
            // SAFETY: balances the successful open above.
            unsafe { (self.api.close_display)(handle) };
            self.desired.insert(connector.to_owned(), actual);
            self.failure_latched.insert(connector.to_owned(), false);
            let _ = events.try_send(SystemControlEvent::BrightnessLevel {
                monitor_id,
                level: actual,
            });
            return;
        };
        let target = match change {
            BrightnessChange::Set(level) => level.clamp(0.0, 1.0),
            BrightnessChange::Adjust(delta) => {
                (self.desired.get(connector).copied().unwrap_or(actual) + delta).clamp(0.0, 1.0)
            }
        };
        let target_value = (target * f64::from(maximum)).round() as u16;
        let [high, low] = target_value.to_be_bytes();
        // Publish presentation state before the potentially slow I2C write.
        let _ = events.try_send(SystemControlEvent::BrightnessLevel {
            monitor_id,
            level: target,
        });
        // SAFETY: handle is open and the VCP payload is two scalar bytes.
        let write_status = unsafe { (self.api.set_value)(handle, 0x10, high, low) };
        // SAFETY: balances the successful open above.
        unsafe { (self.api.close_display)(handle) };
        if write_status != 0 {
            let detail = self.api.describe_status(write_status);
            self.log_failure_once(connector, &format!("could not write VCP 0x10: {detail}"));
            let _ = events.try_send(SystemControlEvent::BrightnessLevel {
                monitor_id,
                level: actual,
            });
            self.desired.insert(connector.to_owned(), actual);
            return;
        }
        self.desired.insert(connector.to_owned(), target);
        self.failure_latched.insert(connector.to_owned(), false);
    }

    fn log_failure_once(&mut self, connector: &str, message: &str) {
        if !self
            .failure_latched
            .insert(connector.to_owned(), true)
            .unwrap_or(false)
        {
            warn!(connector, %message, "native brightness adjustment failed");
        }
    }
}

#[derive(Clone, Copy)]
enum BrightnessChange {
    Set(f64),
    Adjust(f64),
}

fn connector_from_ddc_name(name: &str) -> String {
    let name = name.trim_matches(char::from(0));
    if let Some(rest) = name.strip_prefix("card")
        && let Some((_, connector)) = rest.split_once('-')
    {
        return connector.to_owned();
    }
    name.to_owned()
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum PendingBrightnessCommand {
    Read,
    Set(f64),
    Adjust(f64),
}

fn brightness_command_parts(
    command: BrightnessCommand,
) -> Option<(String, i64, PendingBrightnessCommand)> {
    match command {
        BrightnessCommand::Read {
            connector,
            monitor_id,
        } => Some((connector, monitor_id, PendingBrightnessCommand::Read)),
        BrightnessCommand::Set {
            connector,
            monitor_id,
            level,
        } => Some((connector, monitor_id, PendingBrightnessCommand::Set(level))),
        BrightnessCommand::Adjust {
            connector,
            monitor_id,
            delta,
        } => Some((
            connector,
            monitor_id,
            PendingBrightnessCommand::Adjust(delta),
        )),
        BrightnessCommand::Stop => None,
    }
}

fn merge_brightness_command(
    pending: &mut HashMap<String, (i64, PendingBrightnessCommand)>,
    connector: String,
    monitor_id: i64,
    incoming: PendingBrightnessCommand,
) {
    let Some((saved_monitor_id, saved)) = pending.get_mut(&connector) else {
        pending.insert(connector, (monitor_id, incoming));
        return;
    };
    *saved_monitor_id = monitor_id;
    *saved = match (*saved, incoming) {
        (saved, PendingBrightnessCommand::Read) => saved,
        (_, PendingBrightnessCommand::Set(level)) => PendingBrightnessCommand::Set(level),
        (PendingBrightnessCommand::Set(level), PendingBrightnessCommand::Adjust(delta)) => {
            PendingBrightnessCommand::Set((level + delta).clamp(0.0, 1.0))
        }
        (PendingBrightnessCommand::Adjust(delta), PendingBrightnessCommand::Adjust(next)) => {
            PendingBrightnessCommand::Adjust((delta + next).clamp(-1.0, 1.0))
        }
        (PendingBrightnessCommand::Read, PendingBrightnessCommand::Adjust(delta)) => {
            PendingBrightnessCommand::Adjust(delta)
        }
    };
}

fn receive_brightness_batch(
    first: BrightnessCommand,
    commands: &Receiver<BrightnessCommand>,
) -> Option<HashMap<String, (i64, PendingBrightnessCommand)>> {
    let (connector, monitor_id, command) = brightness_command_parts(first)?;
    let mut pending = HashMap::new();
    merge_brightness_command(&mut pending, connector, monitor_id, command);
    let deadline = Instant::now() + DDC_COALESCE_WINDOW;
    loop {
        let timeout = deadline.saturating_duration_since(Instant::now());
        match commands.recv_timeout(timeout) {
            Ok(command) => {
                let (connector, monitor_id, command) = brightness_command_parts(command)?;
                merge_brightness_command(&mut pending, connector, monitor_id, command);
            }
            Err(RecvTimeoutError::Disconnected) => return None,
            Err(RecvTimeoutError::Timeout) => return Some(pending),
        }
    }
}

fn run_brightness_worker(
    commands: Receiver<BrightnessCommand>,
    events: SyncSender<SystemControlEvent>,
) {
    let mut worker = match DdcWorker::start() {
        Ok(worker) => worker,
        Err(error) => {
            warn!(%error, "native brightness controls are unavailable");
            while !matches!(commands.recv(), Ok(BrightnessCommand::Stop) | Err(_)) {}
            return;
        }
    };
    while let Ok(first) = commands.recv() {
        let Some(batch) = receive_brightness_batch(first, &commands) else {
            break;
        };
        for (connector, (monitor_id, command)) in batch {
            match command {
                PendingBrightnessCommand::Read => worker.read(&connector, monitor_id, &events),
                PendingBrightnessCommand::Set(level) => {
                    worker.set(&connector, monitor_id, level, &events);
                }
                PendingBrightnessCommand::Adjust(delta) => {
                    worker.adjust(&connector, monitor_id, delta, &events);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::mem::{offset_of, size_of};

    #[test]
    fn native_control_ffi_prefixes_match_the_installed_stable_abi() {
        assert_eq!(size_of::<PaSampleSpec>(), 12);
        assert_eq!(size_of::<PaChannelMap>(), 132);
        assert_eq!(size_of::<PaCVolume>(), 132);
        assert_eq!(offset_of!(PaServerInfo, default_sink_name), 48);
        assert_eq!(offset_of!(PaSinkInfoPrefix, volume), 172);
        assert_eq!(offset_of!(PaSinkInfoPrefix, mute), 304);
        assert_eq!(offset_of!(PaSinkInputInfoPrefix, volume), 172);
        assert_eq!(offset_of!(PaSinkInputInfoPrefix, mute), 336);
        assert_eq!(offset_of!(PaSinkInputInfoPrefix, proplist), 344);

        assert_eq!(offset_of!(DdcDisplayInfo2, dref), 192);
        assert_eq!(offset_of!(DdcDisplayInfo2, drm_card_connector), 200);
        assert_eq!(size_of::<DdcDisplayInfo2>(), 304);
        assert_eq!(size_of::<DdcNonTableValue>(), 4);
    }

    #[test]
    fn flutter_audio_packets_decode_strictly_and_clamp_percentages() {
        assert_eq!(decode_audio_request(&[0]).unwrap(), AudioRequest::ReadLevel);
        assert_eq!(
            decode_audio_request(&[1, 140, 0x78, 0x56, 0x34, 0x12]).unwrap(),
            AudioRequest::SetLevel {
                level: 1.0,
                request_serial: 0x1234_5678,
            }
        );
        assert_eq!(
            decode_audio_request(&[2]).unwrap(),
            AudioRequest::RequestStreams
        );
        assert_eq!(
            decode_audio_request(&[3, 7, 0, 0, 0, 25]).unwrap(),
            AudioRequest::SetStreamLevel {
                stream_id: 7,
                level: 0.25,
            }
        );
        assert_eq!(
            decode_audio_request(&[1, 50]).unwrap_err(),
            AudioRequestDecodeError::InvalidSize(2)
        );
        assert_eq!(
            decode_audio_request(&[9]).unwrap_err(),
            AudioRequestDecodeError::UnsupportedCommand(9)
        );
    }

    #[test]
    fn flutter_brightness_packets_target_one_monitor_strictly() {
        let mut packet = vec![1, 0, 0, 0, 0, 0, 0, 0, 0, 125, 4, 0];
        packet.extend_from_slice(b"DP-4");
        assert_eq!(
            decode_brightness_request(&packet).unwrap(),
            BrightnessRequest::Set {
                connector: "DP-4".into(),
                monitor_id: 0,
                level: 1.0,
            }
        );

        packet[0] = 0;
        assert_eq!(
            decode_brightness_request(&packet).unwrap(),
            BrightnessRequest::Read {
                connector: "DP-4".into(),
                monitor_id: 0,
            }
        );
        assert_eq!(
            decode_brightness_request(&packet[..12]).unwrap_err(),
            BrightnessRequestDecodeError::InvalidSize(12)
        );
        packet[0] = 9;
        assert_eq!(
            decode_brightness_request(&packet).unwrap_err(),
            BrightnessRequestDecodeError::UnsupportedCommand(9)
        );
    }

    #[test]
    fn audio_stream_names_truncate_only_at_utf8_boundaries() {
        assert_eq!(truncate_utf8("Denial".into(), 16), "Denial");
        assert_eq!(truncate_utf8("Denia 🌊".into(), 9), "Denia ");
    }

    #[test]
    fn ddc_connector_names_drop_only_the_card_prefix() {
        assert_eq!(connector_from_ddc_name("card2-DP-4"), "DP-4");
        assert_eq!(connector_from_ddc_name("DP-4"), "DP-4");
        assert_eq!(connector_from_ddc_name("card2-HDMI-A-1"), "HDMI-A-1");
    }

    #[test]
    fn brightness_batch_coalesces_detents_per_connector() {
        let (sender, receiver) = mpsc::channel();
        sender
            .send(BrightnessCommand::Adjust {
                connector: "DP-4".into(),
                monitor_id: 4,
                delta: CONTROL_STEP,
            })
            .unwrap();
        sender
            .send(BrightnessCommand::Adjust {
                connector: "DP-4".into(),
                monitor_id: 4,
                delta: CONTROL_STEP,
            })
            .unwrap();
        let first = receiver.recv().unwrap();
        let batch = receive_brightness_batch(first, &receiver).unwrap();
        assert_eq!(batch["DP-4"], (4, PendingBrightnessCommand::Adjust(0.10)));
    }

    #[test]
    fn brightness_read_cannot_discard_a_pending_write() {
        let mut pending = HashMap::new();
        merge_brightness_command(
            &mut pending,
            "DP-4".into(),
            4,
            PendingBrightnessCommand::Set(0.61),
        );
        merge_brightness_command(
            &mut pending,
            "DP-4".into(),
            4,
            PendingBrightnessCommand::Read,
        );
        assert_eq!(pending["DP-4"], (4, PendingBrightnessCommand::Set(0.61)));
    }
}
