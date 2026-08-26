//! Pure lifecycle state shared by the KMS event-loop callbacks.
//!
//! Keeping signal and seat notifications separate from the DRM operations
//! makes duplicate/out-of-order notifications harmless and leaves the actual
//! pause/resume work on the compositor thread.

use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum ShutdownReason {
    Interrupt,
    Terminate,
    NativeEscapeShortcut,
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
        }
    }
}

#[derive(Debug)]
pub(super) struct LifecycleState {
    seat_active: bool,
    pause_pending: bool,
    shutdown: Option<ShutdownReason>,
}

#[derive(Debug, Default)]
pub(super) struct TeardownGate {
    started: bool,
}

impl TeardownGate {
    /// Returns true exactly once, for the caller responsible for teardown.
    pub(super) fn begin(&mut self) -> bool {
        !std::mem::replace(&mut self.started, true)
    }
}

impl Default for LifecycleState {
    fn default() -> Self {
        Self {
            // deniald refuses to acquire DRM unless libseat is active, so
            // every runtime state starts from an active seat.
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

#[cfg(test)]
#[path = "lifecycle/tests.rs"]
mod tests;
