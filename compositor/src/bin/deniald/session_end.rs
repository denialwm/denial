//! Orderly session end: apps quit while their display is still there.
//!
//! An app whose Wayland display disappears dies in whatever state it was in.
//! Electron apps then count the failed GPU process relaunches as GPU crashes,
//! and some of them turn hardware acceleration off for good. At poweroff the
//! user's systemd manager also stops each app scope by sending SIGTERM to every
//! process in it at once, so an app's helper processes die before the app can
//! close them itself.
//!
//! So before the session ends, Denial sends SIGTERM to each app's own process
//! only: the Wayland client, or the process an X11 window names. The app then
//! shuts its helpers down in order. Denial keeps serving the display meanwhile
//! and goes on once they have all exited or [`DRAIN_LIMIT`] has passed. A
//! second SIGINT or SIGTERM while it waits ends the session at once.
//!
//! Three things start it: SIGINT or SIGTERM, the shell's logout, and logind's
//! PrepareForShutdown, whose delay inhibitor is released when the apps are
//! gone so that systemd finds nothing left to kill. Apps run by systemd
//! services are systemd's; Denial asks only those in scopes, which is where
//! launchers and Chromium put apps, and those it started in its own cgroup.

use std::fs;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::time::{Duration, Instant};

use smithay::reexports::calloop::timer::{TimeoutAction, Timer};
use tracing::{info, warn};

use super::RuntimeState;
use super::lifecycle::ShutdownReason;

/// Stays within logind's default `InhibitDelayMaxSec` of five seconds, so a
/// poweroff never waits for Denial longer than for any other delay inhibitor.
const DRAIN_LIMIT: Duration = Duration::from_secs(4);
const EXIT_CHECK_INTERVAL: Duration = Duration::from_millis(50);

/// What happens once the apps are gone.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum SessionEndGoal {
    /// Denial ends.
    Exit(ShutdownReason),
    /// The system powers off or reboots; Denial ends when systemd stops it.
    #[cfg_attr(not(feature = "flutter"), allow(dead_code))]
    ReleaseShutdownDelay,
}

#[derive(Debug, Default)]
pub(super) struct SessionEnd {
    drain: Option<Drain>,
}

#[derive(Debug)]
struct Drain {
    apps: Vec<App>,
    started: Instant,
    exit: Option<ShutdownReason>,
    release_shutdown_delay: bool,
}

#[derive(Debug)]
struct App {
    pid: i32,
    /// Readable once the process has exited.
    pidfd: OwnedFd,
}

/// Asks the session's apps to quit, then reaches `goal`.
pub(super) fn begin(state: &mut RuntimeState, goal: SessionEndGoal) {
    if let Some(drain) = state.session_end.drain.as_mut() {
        match goal {
            SessionEndGoal::Exit(reason) if drain.exit.is_some() => {
                warn!(
                    reason = reason.description(),
                    remaining = drain.apps.len(),
                    "second end request; not waiting for the apps any longer"
                );
                finish(state);
            }
            SessionEndGoal::Exit(reason) => drain.exit = Some(reason),
            SessionEndGoal::ReleaseShutdownDelay => drain.release_shutdown_delay = true,
        }
        return;
    }

    let mut drain = Drain {
        apps: Vec::new(),
        started: Instant::now(),
        exit: None,
        release_shutdown_delay: false,
    };
    match goal {
        SessionEndGoal::Exit(reason) => drain.exit = Some(reason),
        SessionEndGoal::ReleaseShutdownDelay => drain.release_shutdown_delay = true,
    }
    let timer = state.wayland.as_ref().map(|frontend| {
        let own_cgroup = cgroup_of(std::process::id() as i32);
        let mut pids = frontend.session_app_pids();
        pids.sort_unstable();
        pids.dedup();
        for pid in pids {
            if !is_session_app(pid, own_cgroup.as_deref()) {
                continue;
            }
            let Some(pidfd) = pidfd_open(pid) else {
                continue;
            };
            if let Err(error) = pidfd_send_signal(&pidfd, libc::SIGTERM) {
                warn!(pid, %error, "could not ask an app to quit");
                continue;
            }
            info!(pid, app = %process_name(pid), "asked app to quit before the session ends");
            drain.apps.push(App { pid, pidfd });
        }
        frontend.loop_handle().clone()
    });
    let waiting = !drain.apps.is_empty();
    if waiting {
        info!(
            apps = drain.apps.len(),
            limit_ms = DRAIN_LIMIT.as_millis(),
            ?goal,
            "waiting for apps to quit while the display stays up"
        );
    }
    state.session_end.drain = Some(drain);
    let Some(loop_handle) = timer.filter(|_| waiting) else {
        finish(state);
        return;
    };
    let inserted =
        loop_handle.insert_source(Timer::from_duration(EXIT_CHECK_INTERVAL), |_, _, state| {
            if check(state) {
                TimeoutAction::Drop
            } else {
                TimeoutAction::ToDuration(EXIT_CHECK_INTERVAL)
            }
        });
    if let Err(error) = inserted {
        warn!(%error, "could not wait for apps to quit");
        finish(state);
    }
}

/// Returns true once the drain has ended.
fn check(state: &mut RuntimeState) -> bool {
    let Some(drain) = state.session_end.drain.as_mut() else {
        return true;
    };
    drain.apps.retain(|app| !exited(&app.pidfd));
    if !drain.apps.is_empty() && drain.started.elapsed() < DRAIN_LIMIT {
        return false;
    }
    finish(state);
    true
}

fn finish(state: &mut RuntimeState) {
    let Some(drain) = state.session_end.drain.take() else {
        return;
    };
    let waited_ms = drain.started.elapsed().as_millis();
    if drain.apps.is_empty() {
        info!(waited_ms, "apps quit before the session end");
    } else {
        let running = drain
            .apps
            .iter()
            .map(|app| format!("{} ({})", process_name(app.pid), app.pid))
            .collect::<Vec<_>>()
            .join(", ");
        warn!(waited_ms, %running, "apps still running; ending the session without them");
    }
    if drain.release_shutdown_delay {
        release_shutdown_delay(state);
    }
    if let Some(reason) = drain.exit {
        state.lifecycle.request_shutdown(reason);
    }
}

#[cfg(feature = "flutter")]
fn release_shutdown_delay(state: &mut RuntimeState) {
    if state
        .system_controls
        .as_ref()
        .is_some_and(super::system_controls::SystemControls::release_shutdown_delay)
    {
        info!("released the logind shutdown delay inhibitor");
    }
}

#[cfg(not(feature = "flutter"))]
fn release_shutdown_delay(_state: &mut RuntimeState) {}

/// An app is a process of this user in a scope (launchers and Chromium put
/// apps there) or in Denial's own cgroup (apps Denial started that stayed
/// there). Systemd services, Denial itself and other users' processes are not.
fn is_session_app(pid: i32, own_cgroup: Option<&str>) -> bool {
    if pid <= 0 || pid == std::process::id() as i32 {
        return false;
    }
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    let owned = fs::metadata(format!("/proc/{pid}"))
        .is_ok_and(|metadata| std::os::unix::fs::MetadataExt::uid(&metadata) == uid);
    owned && cgroup_of(pid).is_some_and(|cgroup| is_app_cgroup(&cgroup, own_cgroup))
}

fn is_app_cgroup(cgroup: &str, own_cgroup: Option<&str>) -> bool {
    own_cgroup == Some(cgroup)
        || cgroup
            .rsplit('/')
            .next()
            .is_some_and(|unit| unit.ends_with(".scope"))
}

/// The process's cgroup v2 path.
fn cgroup_of(pid: i32) -> Option<String> {
    let contents = fs::read_to_string(format!("/proc/{pid}/cgroup")).ok()?;
    contents
        .lines()
        .find_map(|line| line.strip_prefix("0::"))
        .map(str::to_owned)
}

fn process_name(pid: i32) -> String {
    fs::read_to_string(format!("/proc/{pid}/comm"))
        .map(|name| name.trim_end().to_owned())
        .unwrap_or_else(|_| "?".to_owned())
}

fn pidfd_open(pid: i32) -> Option<OwnedFd> {
    // SAFETY: pidfd_open takes a PID and flags and returns a new descriptor
    // or -1.
    let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
    match RawFd::try_from(fd) {
        // SAFETY: a nonnegative result is a new descriptor owned only here.
        Ok(fd) if fd >= 0 => Some(unsafe { OwnedFd::from_raw_fd(fd) }),
        _ => None,
    }
}

fn pidfd_send_signal(pidfd: &OwnedFd, signal: libc::c_int) -> std::io::Result<()> {
    // SAFETY: the descriptor is a live pidfd; a null siginfo asks the kernel
    // to fill it as kill(2) would.
    let result = unsafe {
        libc::syscall(
            libc::SYS_pidfd_send_signal,
            pidfd.as_raw_fd(),
            signal,
            std::ptr::null::<libc::siginfo_t>(),
            0,
        )
    };
    if result == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

fn exited(pidfd: &OwnedFd) -> bool {
    let mut poll_fd = libc::pollfd {
        fd: pidfd.as_raw_fd(),
        events: libc::POLLIN,
        revents: 0,
    };
    // SAFETY: one initialized pollfd for a descriptor the caller keeps open.
    let ready = unsafe { libc::poll(&mut poll_fd, 1, 0) };
    ready > 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scopes_and_own_cgroup_are_apps_services_are_not() {
        let own = "/user.slice/user-1000.slice/session-10.scope";
        assert!(is_app_cgroup(
            "/user.slice/user-1000.slice/user@1000.service/app.slice/app-com.anthropic.Claude-1197956.scope",
            Some(own)
        ));
        assert!(is_app_cgroup(own, Some(own)));
        assert!(is_app_cgroup(
            "/system.slice/denial.service",
            Some("/system.slice/denial.service")
        ));
        assert!(!is_app_cgroup(
            "/user.slice/user-1000.slice/user@1000.service/session.slice/xdg-desktop-portal.service",
            Some(own)
        ));
        assert!(!is_app_cgroup(
            "/user.slice/user-1000.slice/user@1000.service/app.slice/droidloom.service",
            Some(own)
        ));
    }

    #[test]
    fn apps_quit_on_sigterm_and_the_drain_sees_it() {
        let mut child = std::process::Command::new("sleep")
            .arg("30")
            .spawn()
            .unwrap();
        let pid = child.id() as i32;
        let pidfd = pidfd_open(pid).unwrap();
        assert!(!exited(&pidfd));
        pidfd_send_signal(&pidfd, libc::SIGTERM).unwrap();
        child.wait().unwrap();
        assert!(exited(&pidfd));
    }

    #[test]
    fn a_session_without_wayland_ends_at_once() {
        let mut state = RuntimeState::default();
        begin(&mut state, SessionEndGoal::Exit(ShutdownReason::Terminate));
        assert_eq!(
            state.lifecycle.shutdown_reason(),
            Some(ShutdownReason::Terminate)
        );
        assert!(state.session_end.drain.is_none());
    }
}
