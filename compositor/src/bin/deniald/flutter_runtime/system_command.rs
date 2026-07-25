use std::error::Error;
use std::ffi::{CStr, OsStr, OsString};
use std::fmt;
use std::io;
use std::mem::MaybeUninit;
use std::num::NonZeroU64;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;
use std::time::Duration;

use tracing::{debug, info, warn};

pub const CHANNEL: &CStr = c"denial/system_command";

const HEADER_SIZE: usize = 1 + size_of::<u64>() + size_of::<u32>();
const MAX_PACKET_SIZE: usize = 64 * 1024;
const MAX_ARGUMENTS: usize = 64;
const MAX_ARGUMENT_SIZE: usize = 4096;
const MAX_TRACKED_APPLICATIONS: usize = 64;
const REAPER_POLL_INTERVAL: Duration = Duration::from_millis(250);
const LAUNCH_APPLICATION: u8 = 0;
const LOGOUT: u8 = 3;

// Never pass connection selectors inherited from a parent/nested compositor
// to applications. WAYLAND_DISPLAY is installed explicitly below; all other
// compositor/GPU bootstrap choices belong only to deniald.
const APPLICATION_ENVIRONMENT_REMOVALS: &[&str] = &[
    "AQ_DRM_DEVICES",
    "__EGL_VENDOR_LIBRARY_FILENAMES",
    "WLR_DRM_DEVICES",
    "WLR_RENDERER",
    "GBM_BACKEND",
    "LIBSEAT_BACKEND",
    "WAYLAND_SOCKET",
    "DISPLAY",
    "HYPRLAND_INSTANCE_SIGNATURE",
    "SWAYSOCK",
    "I3SOCK",
    "NIRI_SOCKET",
    "RIVER_SOCKET",
    "WAYFIRE_SOCKET",
    "XDG_ACTIVATION_TOKEN",
    "DESKTOP_STARTUP_ID",
    "NOTIFY_SOCKET",
    "WATCHDOG_PID",
    "WATCHDOG_USEC",
    "LISTEN_FDS",
    "LISTEN_FDNAMES",
    "LISTEN_PID",
    "SYSTEMD_EXEC_PID",
    "DENIA_LAUNCH_REQUEST_ID",
    "DENIA_UWSM_FINALIZE",
    "DENIAL_SOCKET",
    // This is useful for keeping compositor diagnostics machine-readable, but
    // it must not silently disable color in applications launched by Denial.
    "NO_COLOR",
];

#[derive(Debug, Eq, PartialEq)]
enum Request {
    LaunchApplication {
        arguments: Vec<String>,
        launch_request_id: Option<NonZeroU64>,
    },
    Logout,
}

#[derive(Debug, Eq, PartialEq)]
pub enum DecodeError {
    InvalidPacketSize(usize),
    TooManyArguments(u32),
    TruncatedArgumentLength(usize),
    InvalidArgumentSize { index: usize, size: u32 },
    TruncatedArgument { index: usize },
    ArgumentContainsNul(usize),
    ArgumentIsNotUtf8(usize),
    TrailingBytes,
    LaunchHasNoArguments,
    UnexpectedLaunchMetadata,
    UnsupportedCommand(u8),
}

impl fmt::Display for DecodeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidPacketSize(size) => write!(formatter, "invalid packet size {size}"),
            Self::TooManyArguments(count) => write!(formatter, "too many arguments: {count}"),
            Self::TruncatedArgumentLength(index) => {
                write!(formatter, "argument {index} has a truncated length")
            }
            Self::InvalidArgumentSize { index, size } => {
                write!(formatter, "argument {index} has invalid size {size}")
            }
            Self::TruncatedArgument { index } => {
                write!(formatter, "argument {index} is truncated")
            }
            Self::ArgumentContainsNul(index) => {
                write!(formatter, "argument {index} contains NUL")
            }
            Self::ArgumentIsNotUtf8(index) => {
                write!(formatter, "argument {index} is not UTF-8")
            }
            Self::TrailingBytes => formatter.write_str("packet has trailing bytes"),
            Self::LaunchHasNoArguments => formatter.write_str("launch command has no arguments"),
            Self::UnexpectedLaunchMetadata => {
                formatter.write_str("non-launch command carries launch metadata")
            }
            Self::UnsupportedCommand(command) => {
                write!(formatter, "unsupported system command {command}")
            }
        }
    }
}

impl Error for DecodeError {}

#[derive(Debug)]
pub enum DispatchError {
    Decode(DecodeError),
    WaylandUnavailable,
    ApplicationLimitReached,
    Reaper(io::Error),
    Spawn(io::Error),
}

impl fmt::Display for DispatchError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Decode(error) => write!(formatter, "invalid system-command packet: {error}"),
            Self::WaylandUnavailable => {
                formatter.write_str("cannot launch an application without a Wayland display")
            }
            Self::ApplicationLimitReached => write!(
                formatter,
                "cannot track more than {MAX_TRACKED_APPLICATIONS} launched applications"
            ),
            Self::Reaper(error) => write!(formatter, "could not start child reaper: {error}"),
            Self::Spawn(error) => write!(formatter, "could not launch application: {error}"),
        }
    }
}

impl Error for DispatchError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Decode(error) => Some(error),
            Self::Reaper(error) | Self::Spawn(error) => Some(error),
            Self::WaylandUnavailable | Self::ApplicationLimitReached => None,
        }
    }
}

impl From<DecodeError> for DispatchError {
    fn from(error: DecodeError) -> Self {
        Self::Decode(error)
    }
}

struct LaunchLimiter {
    active: AtomicUsize,
    limit: usize,
}

impl LaunchLimiter {
    const fn new(limit: usize) -> Self {
        Self {
            active: AtomicUsize::new(0),
            limit,
        }
    }

    fn try_acquire(&self) -> Option<LaunchPermit<'_>> {
        self.active
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |active| {
                (active < self.limit).then_some(active + 1)
            })
            .ok()?;
        Some(LaunchPermit { limiter: self })
    }
}

struct LaunchPermit<'a> {
    limiter: &'a LaunchLimiter,
}

impl Drop for LaunchPermit<'_> {
    fn drop(&mut self) {
        self.limiter.active.fetch_sub(1, Ordering::AcqRel);
    }
}

static LAUNCH_LIMITER: LaunchLimiter = LaunchLimiter::new(MAX_TRACKED_APPLICATIONS);

pub struct SystemCommandHandler {
    wayland_display: Option<OsString>,
    x11_display: Option<OsString>,
    output_control_socket: Option<OsString>,
    logout_requested: bool,
}

impl SystemCommandHandler {
    pub fn new(
        wayland_display: Option<OsString>,
        x11_display: Option<OsString>,
        output_control_socket: Option<OsString>,
    ) -> Self {
        Self {
            wayland_display,
            x11_display,
            output_control_socket,
            logout_requested: false,
        }
    }

    pub fn handle(&mut self, packet: &[u8]) -> Result<(), DispatchError> {
        match decode(packet)? {
            Request::LaunchApplication {
                arguments,
                launch_request_id,
            } => {
                let display = self
                    .wayland_display
                    .as_deref()
                    .ok_or(DispatchError::WaylandUnavailable)?;
                let executable = arguments[0].clone();
                let pid = launch_application(
                    &arguments,
                    launch_request_id,
                    display,
                    self.x11_display.as_deref(),
                    self.output_control_socket.as_deref(),
                )?;
                info!(pid, executable, "launched application from Flutter shell");
            }
            Request::Logout => {
                self.logout_requested = true;
                info!("Flutter shell requested session logout");
            }
        }
        Ok(())
    }

    pub fn take_logout_requested(&mut self) -> bool {
        std::mem::take(&mut self.logout_requested)
    }
}

fn decode(packet: &[u8]) -> Result<Request, DecodeError> {
    if !(HEADER_SIZE..=MAX_PACKET_SIZE).contains(&packet.len()) {
        return Err(DecodeError::InvalidPacketSize(packet.len()));
    }

    let command = packet[0];
    let launch_request_id = u64::from_le_bytes(
        packet[1..1 + size_of::<u64>()]
            .try_into()
            .expect("fixed-size header was checked"),
    );
    let argument_count = u32::from_le_bytes(
        packet[1 + size_of::<u64>()..HEADER_SIZE]
            .try_into()
            .expect("fixed-size header was checked"),
    );
    if argument_count > MAX_ARGUMENTS as u32 {
        return Err(DecodeError::TooManyArguments(argument_count));
    }

    let mut offset = HEADER_SIZE;
    let mut arguments = Vec::with_capacity(argument_count as usize);
    for index in 0..argument_count as usize {
        let length_end = offset
            .checked_add(size_of::<u32>())
            .filter(|end| *end <= packet.len())
            .ok_or(DecodeError::TruncatedArgumentLength(index))?;
        let length = u32::from_le_bytes(
            packet[offset..length_end]
                .try_into()
                .expect("argument length boundary was checked"),
        );
        offset = length_end;
        if length == 0 || length > MAX_ARGUMENT_SIZE as u32 {
            return Err(DecodeError::InvalidArgumentSize {
                index,
                size: length,
            });
        }
        let end = offset
            .checked_add(length as usize)
            .filter(|end| *end <= packet.len())
            .ok_or(DecodeError::TruncatedArgument { index })?;
        let bytes = &packet[offset..end];
        if bytes.contains(&0) {
            return Err(DecodeError::ArgumentContainsNul(index));
        }
        let argument = std::str::from_utf8(bytes)
            .map_err(|_| DecodeError::ArgumentIsNotUtf8(index))?
            .to_owned();
        arguments.push(argument);
        offset = end;
    }
    if offset != packet.len() {
        return Err(DecodeError::TrailingBytes);
    }

    match command {
        LAUNCH_APPLICATION => {
            if arguments.is_empty() {
                return Err(DecodeError::LaunchHasNoArguments);
            }
            Ok(Request::LaunchApplication {
                arguments,
                launch_request_id: NonZeroU64::new(launch_request_id),
            })
        }
        LOGOUT => {
            if launch_request_id != 0 || !arguments.is_empty() {
                return Err(DecodeError::UnexpectedLaunchMetadata);
            }
            Ok(Request::Logout)
        }
        command => Err(DecodeError::UnsupportedCommand(command)),
    }
}

fn launch_application(
    arguments: &[String],
    launch_request_id: Option<NonZeroU64>,
    wayland_display: &OsStr,
    x11_display: Option<&OsStr>,
    output_control_socket: Option<&OsStr>,
) -> Result<u32, DispatchError> {
    // Start the reaper first. If the system cannot create that one persistent
    // thread, no process is launched that Denial would be unable to reap.
    let reaper = reaper_sender().map_err(DispatchError::Reaper)?;
    // Reserve capacity before fork/exec. The permit follows the Child into the
    // reaper and is released only after wait(2), bounding both processes and
    // the otherwise-unbounded std mpsc queue.
    let permit = LAUNCH_LIMITER
        .try_acquire()
        .ok_or(DispatchError::ApplicationLimitReached)?;
    let mut command = application_command(
        arguments,
        launch_request_id,
        wayland_display,
        x11_display,
        output_control_socket,
    );
    let child = command.spawn().map_err(DispatchError::Spawn)?;
    let pid = child.id();
    let mut tracked = TrackedChild {
        child,
        _permit: permit,
        reaped: false,
    };
    match reaper.sender.send(tracked) {
        Ok(()) => return Ok(pid),
        Err(error) => {
            invalidate_reaper_sender(reaper.generation);
            tracked = error.0;
        }
    }

    // A dead reaper disconnects its sender. Restart it once and preserve the
    // already-running child instead of turning a recoverable monitor failure
    // into an application launch failure.
    match reaper_sender() {
        Ok(replacement) => match replacement.sender.send(tracked) {
            Ok(()) => {
                warn!(pid, "restarted child reaper after an unexpected disconnect");
                return Ok(pid);
            }
            Err(error) => {
                invalidate_reaper_sender(replacement.generation);
                tracked = error.0;
            }
        },
        Err(error) => {
            let _ = terminate_and_reap(&mut tracked.child);
            return Err(DispatchError::Reaper(error));
        }
    }
    let _ = terminate_and_reap(&mut tracked.child);
    Err(DispatchError::Reaper(io::Error::new(
        io::ErrorKind::BrokenPipe,
        "child reaper stopped unexpectedly after restart",
    )))
}

fn application_command(
    arguments: &[String],
    launch_request_id: Option<NonZeroU64>,
    wayland_display: &OsStr,
    x11_display: Option<&OsStr>,
    output_control_socket: Option<&OsStr>,
) -> Command {
    let mut command = Command::new(&arguments[0]);
    // Command inherits the user session environment intentionally: PATH,
    // locale, TERM/COLORTERM, HOME, XDG data/config roots and toolkit settings
    // are application state, not compositor state. Override only Denial's
    // identity/Wayland endpoint and remove the bootstrap variables below.
    command
        .args(&arguments[1..])
        .env("WAYLAND_DISPLAY", wayland_display)
        .env("XDG_CURRENT_DESKTOP", "Denial")
        .env("XDG_SESSION_DESKTOP", "Denial")
        .env("XDG_SESSION_TYPE", "wayland")
        .env("DESKTOP_SESSION", "Denial")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        // Do not place applications in the compositor's signal group. The
        // login-session owner remains responsible for terminating them.
        .process_group(0);
    for variable in APPLICATION_ENVIRONMENT_REMOVALS {
        command.env_remove(variable);
    }
    if let Some(display) = x11_display {
        command.env("DISPLAY", display);
    }
    if let Some(socket) = output_control_socket {
        command.env("DENIAL_SOCKET", socket);
    }
    // calloop's signalfd intentionally blocks the shutdown signals in every
    // compositor thread. A fork inherits that mask, so undo it in the child
    // between fork and exec; otherwise ordinary applications cannot receive
    // SIGINT/SIGTERM from their own process manager.
    // SAFETY: the closure uses only libc signal-mask operations which are
    // valid in the post-fork child, touches no shared Rust state, and returns
    // before exec on every error.
    unsafe {
        command.pre_exec(|| {
            let mut signals = MaybeUninit::<libc::sigset_t>::uninit();
            if libc::sigemptyset(signals.as_mut_ptr()) != 0 {
                return Err(io::Error::last_os_error());
            }
            let mut signals = signals.assume_init();
            if libc::sigaddset(&mut signals, libc::SIGINT) != 0
                || libc::sigaddset(&mut signals, libc::SIGTERM) != 0
            {
                return Err(io::Error::last_os_error());
            }
            let result = libc::pthread_sigmask(libc::SIG_UNBLOCK, &signals, std::ptr::null_mut());
            if result != 0 {
                return Err(io::Error::from_raw_os_error(result));
            }
            Ok(())
        });
    }
    if let Some(request_id) = launch_request_id {
        command.env("DENIA_LAUNCH_REQUEST_ID", request_id.get().to_string());
    }
    command
}

struct TrackedChild {
    child: Child,
    _permit: LaunchPermit<'static>,
    reaped: bool,
}

struct ReaperChildren(Vec<TrackedChild>);

impl Drop for ReaperChildren {
    fn drop(&mut self) {
        // This path is primarily an unwind guard for an unexpected reaper
        // panic. Avoid logging or allocation: kill and wait every still-owned
        // child before their permits can be released.
        for tracked in &mut self.0 {
            if tracked.reaped {
                continue;
            }
            let _ = terminate_application_group(&mut tracked.child);
            loop {
                match tracked.child.wait() {
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                    _ => break,
                }
            }
        }
    }
}

#[derive(Clone)]
struct ReaperSender {
    generation: u64,
    sender: Sender<TrackedChild>,
}

struct ReaperSlot {
    next_generation: u64,
    active: Option<ReaperSender>,
}

impl ReaperSlot {
    fn invalidate(&mut self, generation: u64) {
        if self
            .active
            .as_ref()
            .is_some_and(|sender| sender.generation == generation)
        {
            self.active = None;
        }
    }
}

static REAPER_SLOT: Mutex<ReaperSlot> = Mutex::new(ReaperSlot {
    next_generation: 0,
    active: None,
});

fn reaper_sender() -> io::Result<ReaperSender> {
    let mut slot = REAPER_SLOT
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(sender) = slot.active.as_ref() {
        return Ok(sender.clone());
    }

    let (sender, receiver) = mpsc::channel();
    thread::Builder::new()
        .name("denial-child-reaper".into())
        .spawn(move || reap_children(receiver))?;
    slot.next_generation = slot.next_generation.wrapping_add(1);
    let sender = ReaperSender {
        generation: slot.next_generation,
        sender,
    };
    slot.active = Some(sender.clone());
    Ok(sender)
}

fn invalidate_reaper_sender(generation: u64) {
    let mut slot = REAPER_SLOT
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    slot.invalidate(generation);
}

fn terminate_and_reap(child: &mut Child) -> bool {
    if let Err(error) = terminate_application_group(child)
        && error.kind() != io::ErrorKind::InvalidInput
        && error.raw_os_error() != Some(libc::ESRCH)
    {
        warn!(pid = child.id(), %error, "failed to terminate untracked application process");
    }
    loop {
        match child.wait() {
            Ok(_) => return true,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            // Another SIGCHLD consumer may already have collected it. ECHILD
            // proves there is no zombie left for this process to reap.
            Err(error) if error.raw_os_error() == Some(libc::ECHILD) => return true,
            Err(error) => {
                warn!(pid = child.id(), %error, "failed to wait for application process");
                return false;
            }
        }
    }
}

fn terminate_application_group(child: &mut Child) -> io::Result<()> {
    if let Ok(process_group) = i32::try_from(child.id())
        && process_group > 0
    {
        // SAFETY: application_command created a fresh process group whose ID
        // is the child PID. A negative kill target addresses that group only.
        if unsafe { libc::kill(-process_group, libc::SIGKILL) } == 0 {
            return Ok(());
        }
    }
    // The application may have changed groups immediately after exec. Still
    // terminate the owned leader as a conservative fallback.
    child.kill()
}

fn reap_children(receiver: Receiver<TrackedChild>) {
    let mut children = ReaperChildren(Vec::with_capacity(MAX_TRACKED_APPLICATIONS));
    let mut disconnected = false;
    loop {
        let received = if disconnected {
            thread::sleep(REAPER_POLL_INTERVAL);
            Err(mpsc::RecvTimeoutError::Timeout)
        } else if children.0.is_empty() {
            receiver
                .recv()
                .map_err(|_| mpsc::RecvTimeoutError::Disconnected)
        } else {
            receiver.recv_timeout(REAPER_POLL_INTERVAL)
        };
        match received {
            Ok(child) => children.0.push(child),
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => disconnected = true,
        }

        children
            .0
            .retain_mut(|tracked| match tracked.child.try_wait() {
                Ok(Some(status)) => {
                    tracked.reaped = true;
                    debug!(pid = tracked.child.id(), %status, "application process exited");
                    false
                }
                Ok(None) => true,
                Err(error) if error.raw_os_error() == Some(libc::ECHILD) => {
                    // A foreign SIGCHLD consumer already reaped it. Do not signal
                    // the stale PID: it may have been reused for another group.
                    tracked.reaped = true;
                    false
                }
                Err(error) => {
                    warn!(pid = tracked.child.id(), %error, "failed to poll application process");
                    // Never discard a Child merely because non-blocking wait
                    // failed. Kill+wait keeps the permit held until the kernel no
                    // longer owns a reapable child and prevents zombie leakage.
                    tracked.reaped = terminate_and_reap(&mut tracked.child);
                    !tracked.reaped
                }
            });
        if disconnected && children.0.is_empty() {
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn packet(command: u8, request_id: u64, arguments: &[&[u8]]) -> Vec<u8> {
        let mut packet = vec![command];
        packet.extend_from_slice(&request_id.to_le_bytes());
        packet.extend_from_slice(&(arguments.len() as u32).to_le_bytes());
        for argument in arguments {
            packet.extend_from_slice(&(argument.len() as u32).to_le_bytes());
            packet.extend_from_slice(argument);
        }
        packet
    }

    #[test]
    fn decodes_launch_and_logout_packets() {
        assert_eq!(
            decode(&packet(
                LAUNCH_APPLICATION,
                42,
                &[b"foot", b"--title", "è".as_bytes()]
            )),
            Ok(Request::LaunchApplication {
                arguments: vec!["foot".into(), "--title".into(), "è".into()],
                launch_request_id: NonZeroU64::new(42),
            })
        );
        assert_eq!(decode(&packet(LOGOUT, 0, &[])), Ok(Request::Logout));
    }

    #[test]
    fn rejects_unbounded_or_structurally_invalid_packets() {
        assert_eq!(decode(&[]), Err(DecodeError::InvalidPacketSize(0)));
        assert_eq!(
            decode(&vec![0; MAX_PACKET_SIZE + 1]),
            Err(DecodeError::InvalidPacketSize(MAX_PACKET_SIZE + 1))
        );

        let mut too_many = packet(LAUNCH_APPLICATION, 0, &[]);
        too_many[9..13].copy_from_slice(&((MAX_ARGUMENTS + 1) as u32).to_le_bytes());
        assert_eq!(
            decode(&too_many),
            Err(DecodeError::TooManyArguments((MAX_ARGUMENTS + 1) as u32))
        );

        let mut truncated = packet(LAUNCH_APPLICATION, 0, &[b"foot"]);
        truncated.pop();
        assert_eq!(
            decode(&truncated),
            Err(DecodeError::TruncatedArgument { index: 0 })
        );

        let mut trailing = packet(LOGOUT, 0, &[]);
        trailing.push(0);
        assert_eq!(decode(&trailing), Err(DecodeError::TrailingBytes));
    }

    #[test]
    fn rejects_unsafe_argument_encodings() {
        assert_eq!(
            decode(&packet(LAUNCH_APPLICATION, 0, &[b""])),
            Err(DecodeError::InvalidArgumentSize { index: 0, size: 0 })
        );
        assert_eq!(
            decode(&packet(LAUNCH_APPLICATION, 0, &[b"bad\0argument"])),
            Err(DecodeError::ArgumentContainsNul(0))
        );
        assert_eq!(
            decode(&packet(LAUNCH_APPLICATION, 0, &[&[0xff]])),
            Err(DecodeError::ArgumentIsNotUtf8(0))
        );
    }

    #[test]
    fn validates_command_specific_fields() {
        assert_eq!(
            decode(&packet(LAUNCH_APPLICATION, 0, &[])),
            Err(DecodeError::LaunchHasNoArguments)
        );
        assert_eq!(
            decode(&packet(LOGOUT, 1, &[])),
            Err(DecodeError::UnexpectedLaunchMetadata)
        );
        assert_eq!(
            decode(&packet(LOGOUT, 0, &[b"extra"])),
            Err(DecodeError::UnexpectedLaunchMetadata)
        );
        assert_eq!(
            decode(&packet(99, 0, &[])),
            Err(DecodeError::UnsupportedCommand(99))
        );
    }

    #[test]
    fn launch_limiter_holds_capacity_until_permits_are_dropped() {
        let limiter = LaunchLimiter::new(2);
        let first = limiter.try_acquire().expect("first launch fits");
        let second = limiter.try_acquire().expect("second launch fits");
        assert!(limiter.try_acquire().is_none());
        assert_eq!(limiter.active.load(Ordering::Acquire), 2);

        drop(first);
        let replacement = limiter.try_acquire().expect("reaped launch frees capacity");
        assert_eq!(limiter.active.load(Ordering::Acquire), 2);
        drop((second, replacement));
        assert_eq!(limiter.active.load(Ordering::Acquire), 0);
    }

    #[test]
    fn stale_reaper_failure_cannot_invalidate_a_replacement() {
        let (sender, _receiver) = mpsc::channel::<TrackedChild>();
        let mut slot = ReaperSlot {
            next_generation: 8,
            active: Some(ReaperSender {
                generation: 8,
                sender,
            }),
        };
        slot.invalidate(7);
        assert_eq!(
            slot.active.as_ref().map(|sender| sender.generation),
            Some(8)
        );
        slot.invalidate(8);
        assert!(slot.active.is_none());
    }

    #[test]
    fn builds_a_direct_process_with_denial_wayland_environment() {
        let arguments = vec!["foot".into(), "--title".into(), "hello world".into()];
        let command = application_command(
            &arguments,
            NonZeroU64::new(17),
            OsStr::new("wayland-7"),
            Some(OsStr::new(":42")),
            Some(OsStr::new("/run/user/1000/denial/control.sock")),
        );
        assert_eq!(command.get_program(), OsStr::new("foot"));
        assert_eq!(
            command.get_args().collect::<Vec<_>>(),
            [OsStr::new("--title"), OsStr::new("hello world")]
        );
        let environment = command
            .get_envs()
            .map(|(key, value)| (key.to_owned(), value.map(OsStr::to_owned)))
            .collect::<std::collections::BTreeMap<_, _>>();
        assert_eq!(
            environment.get(OsStr::new("WAYLAND_DISPLAY")),
            Some(&Some(OsString::from("wayland-7")))
        );
        assert_eq!(
            environment.get(OsStr::new("DISPLAY")),
            Some(&Some(OsString::from(":42")))
        );
        assert_eq!(
            environment.get(OsStr::new("XDG_CURRENT_DESKTOP")),
            Some(&Some(OsString::from("Denial")))
        );
        assert_eq!(
            environment.get(OsStr::new("DENIAL_SOCKET")),
            Some(&Some(OsString::from("/run/user/1000/denial/control.sock")))
        );
        assert_eq!(
            environment.get(OsStr::new("DENIA_LAUNCH_REQUEST_ID")),
            Some(&Some(OsString::from("17")))
        );
        assert_eq!(environment.get(OsStr::new("AQ_DRM_DEVICES")), Some(&None));
        assert_eq!(
            environment.get(OsStr::new("__EGL_VENDOR_LIBRARY_FILENAMES")),
            Some(&None)
        );
        assert_eq!(environment.get(OsStr::new("NO_COLOR")), Some(&None));
        for inherited in ["PATH", "LANG", "LC_ALL", "TERM", "COLORTERM", "HOME"] {
            assert_eq!(
                environment.get(OsStr::new(inherited)),
                None,
                "{inherited} must be inherited from the user session"
            );
        }
        for variable in APPLICATION_ENVIRONMENT_REMOVALS
            .iter()
            .copied()
            .filter(|variable| {
                !matches!(
                    *variable,
                    "DENIA_LAUNCH_REQUEST_ID" | "DENIAL_SOCKET" | "DISPLAY"
                )
            })
        {
            assert_eq!(
                environment.get(OsStr::new(variable)),
                Some(&None),
                "{variable} leaked into the application command"
            );
        }
    }

    #[test]
    fn launch_without_output_control_removes_an_inherited_stale_socket() {
        let command =
            application_command(&["foot".into()], None, OsStr::new("wayland-7"), None, None);
        let environment = command
            .get_envs()
            .map(|(key, value)| (key.to_owned(), value.map(OsStr::to_owned)))
            .collect::<std::collections::BTreeMap<_, _>>();

        assert_eq!(environment.get(OsStr::new("DENIAL_SOCKET")), Some(&None));
    }
}
