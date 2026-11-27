//! Pure lifecycle state shared by the KMS event-loop callbacks.
//!
//! Keeping signal and seat notifications separate from the DRM operations
//! makes duplicate/out-of-order notifications harmless and leaves the actual
//! pause/resume work on the compositor thread.

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

/// The exit status that asks `denial-session` to start Denial again.
pub(super) const RESTART_EXIT_STATUS: i32 = 75;

static RESTART_REQUESTED: AtomicBool = AtomicBool::new(false);

/// The session ends to start again: the normal teardown runs, then the
/// process exits with [RESTART_EXIT_STATUS].
pub(super) fn request_restart() {
    RESTART_REQUESTED.store(true, Ordering::Release);
}

pub(super) fn restart_requested() -> bool {
    RESTART_REQUESTED.load(Ordering::Acquire)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum ShutdownReason {
    Interrupt,
    Terminate,
    NativeEscapeShortcut,
    #[cfg_attr(not(feature = "flutter"), allow(dead_code))]
    Logout,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum InactiveDispatch {
    DeadlineReached,
    Wait(Option<Duration>),
}

/// Selects the blocking policy while libseat is inactive.
///
/// Unlimited sessions sleep until an event wakes calloop. Finite harnesses
/// carry their wall-clock deadline into the suspended state so switching VTs
/// cannot turn a bounded run into an unbounded wait.
pub(super) fn inactive_dispatch(now: Instant, deadline: Option<Instant>) -> InactiveDispatch {
    match deadline {
        None => InactiveDispatch::Wait(None),
        Some(deadline) if now >= deadline => InactiveDispatch::DeadlineReached,
        Some(deadline) => InactiveDispatch::Wait(Some(deadline.duration_since(now))),
    }
}

impl ShutdownReason {
    pub(super) const fn description(self) -> &'static str {
        match self {
            Self::Interrupt => "SIGINT",
            Self::Terminate => "SIGTERM",
            Self::NativeEscapeShortcut => "Ctrl+Alt+Backspace",
            Self::Logout => "shell logout",
        }
    }
}

#[derive(Debug)]
pub(super) struct LifecycleState {
    seat_active: bool,
    pause_pending: bool,
    shutdown: Option<ShutdownReason>,
}


impl Default for LifecycleState {
    fn default() -> Self {
        Self {
            // deniald waits for libseat activation before it acquires DRM,
            // so every runtime state starts from an active seat.
            seat_active: true,
            pause_pending: false,
            shutdown: None,
        }
    }
}

impl LifecycleState {
    pub(super) fn pause_session(&mut self) {
        self.seat_active = false;
        // Keep this edge even if ActivateSession is delivered in the same
        // calloop dispatch. DrmDevice must observe pause before reactivation.
        self.pause_pending = true;
    }

    pub(super) fn activate_session(&mut self) {
        self.seat_active = true;
    }

    pub(super) fn take_pause_pending(&mut self) -> bool {
        std::mem::take(&mut self.pause_pending)
    }

    pub(super) const fn seat_active(&self) -> bool {
        self.seat_active
    }

    pub(super) const fn requires_kms_service(
        &self,
        drm_active: bool,
        device_removed: bool,
    ) -> bool {
        self.pause_pending
            || self.shutdown.is_some()
            || !self.seat_active
            || device_removed
            || !drm_active
    }

    pub(super) fn request_shutdown(&mut self, reason: ShutdownReason) {
        // The first request is the reason reported to the user. Further
        // requests remain coalesced instead of introducing teardown races.
        self.shutdown.get_or_insert(reason);
    }

    pub(super) const fn shutdown_reason(&self) -> Option<ShutdownReason> {
        self.shutdown
    }
}
