//! Native controls reached directly from Flutter platform messages.

use std::error::Error;
use std::ffi::CStr;
use std::fmt;
use std::io;
use std::os::unix::net::UnixDatagram;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

pub(super) const HAPTICS_CHANNEL: &CStr = c"denial/haptics";

const HAPTICS_SOCKET_PATH: &str = "/run/denia-hapticsd/socket";
const HAPTICS_TAP: &[u8] = b"tap";
const HAPTICS_MIN_GAP: Duration = Duration::from_micros(18_000);

pub(super) trait HapticsTransport {
    fn prewarm(&mut self) -> io::Result<()>;
    fn tap(&mut self) -> io::Result<()>;
    fn reset(&mut self);
}

#[derive(Debug)]
pub(super) struct UnixHapticsTransport {
    path: PathBuf,
    socket: Option<UnixDatagram>,
}

impl Default for UnixHapticsTransport {
    fn default() -> Self {
        Self {
            path: PathBuf::from(HAPTICS_SOCKET_PATH),
            socket: None,
        }
    }
}

impl UnixHapticsTransport {
    fn ensure_socket(&mut self) -> io::Result<()> {
        if self.socket.is_none() {
            let socket = UnixDatagram::unbound()?;
            socket.set_nonblocking(true)?;
            self.socket = Some(socket);
        }
        Ok(())
    }

    fn send_to(&mut self, payload: &[u8], path: &Path) -> io::Result<()> {
        self.ensure_socket()?;
        let sent = self
            .socket
            .as_ref()
            .ok_or_else(|| io::Error::other("haptics socket disappeared"))?
            .send_to(payload, path)?;
        if sent != payload.len() {
            return Err(io::Error::new(
                io::ErrorKind::WriteZero,
                "short haptics datagram",
            ));
        }
        Ok(())
    }
}

impl HapticsTransport for UnixHapticsTransport {
    fn prewarm(&mut self) -> io::Result<()> {
        self.ensure_socket()
    }

    fn tap(&mut self) -> io::Result<()> {
        let path = self.path.clone();
        self.send_to(HAPTICS_TAP, &path)
    }

    fn reset(&mut self) {
        self.socket = None;
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum HapticsOutcome {
    Prewarmed,
    Tapped,
    RateLimited,
    TransportUnavailable,
}

#[derive(Debug)]
pub(super) enum HapticsError {
    InvalidPacketSize(usize),
    UnsupportedCommand(u8),
    Transport {
        operation: &'static str,
        source: io::Error,
    },
}

impl fmt::Display for HapticsError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidPacketSize(size) => {
                write!(formatter, "invalid haptics packet size {size}")
            }
            Self::UnsupportedCommand(command) => {
                write!(formatter, "unsupported haptics command {command}")
            }
            Self::Transport { operation, source } => {
                write!(formatter, "haptics {operation} failed: {source}")
            }
        }
    }
}

impl Error for HapticsError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Transport { source, .. } => Some(source),
            Self::InvalidPacketSize(_) | Self::UnsupportedCommand(_) => None,
        }
    }
}

#[derive(Clone, Copy)]
enum HapticsCommand {
    Prewarm,
    Tap,
}

fn decode(packet: &[u8]) -> Result<HapticsCommand, HapticsError> {
    match packet {
        [0] => Ok(HapticsCommand::Prewarm),
        [1] => Ok(HapticsCommand::Tap),
        [command] => Err(HapticsError::UnsupportedCommand(*command)),
        _ => Err(HapticsError::InvalidPacketSize(packet.len())),
    }
}

pub(super) struct HapticsHandler<T = UnixHapticsTransport> {
    transport: T,
    epoch: Instant,
    last_tap: Option<Duration>,
    transport_warning_latched: bool,
}

impl HapticsHandler<UnixHapticsTransport> {
    pub(super) fn new() -> Self {
        Self::with_transport(UnixHapticsTransport::default())
    }
}

impl<T: HapticsTransport> HapticsHandler<T> {
    pub(super) fn with_transport(transport: T) -> Self {
        Self {
            transport,
            epoch: Instant::now(),
            last_tap: None,
            transport_warning_latched: false,
        }
    }

    pub(super) fn handle(&mut self, packet: &[u8]) -> Result<HapticsOutcome, HapticsError> {
        self.handle_at(packet, self.epoch.elapsed())
    }

    fn handle_at(&mut self, packet: &[u8], now: Duration) -> Result<HapticsOutcome, HapticsError> {
        match decode(packet)? {
            HapticsCommand::Prewarm => {
                let result = self.transport.prewarm();
                self.finish_transport(result, "prewarm", HapticsOutcome::Prewarmed)
            }
            HapticsCommand::Tap => {
                if self
                    .last_tap
                    .is_some_and(|last| now >= last && now.saturating_sub(last) < HAPTICS_MIN_GAP)
                {
                    return Ok(HapticsOutcome::RateLimited);
                }
                self.last_tap = Some(now);
                let result = self.transport.tap();
                self.finish_transport(result, "tap", HapticsOutcome::Tapped)
            }
        }
    }

    fn finish_transport(
        &mut self,
        result: io::Result<()>,
        operation: &'static str,
        success: HapticsOutcome,
    ) -> Result<HapticsOutcome, HapticsError> {
        match result {
            Ok(()) => {
                self.transport_warning_latched = false;
                Ok(success)
            }
            Err(source) => {
                self.transport.reset();
                if std::mem::replace(&mut self.transport_warning_latched, true) {
                    Ok(HapticsOutcome::TransportUnavailable)
                } else {
                    Err(HapticsError::Transport { operation, source })
                }
            }
        }
    }
}
