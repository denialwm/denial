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
mod tests {
    use super::*;

    #[test]
    fn pause_edge_survives_an_immediate_reactivation() {
        let mut state = LifecycleState::default();

        state.pause_session();
        state.activate_session();

        assert!(state.seat_active());
        assert!(state.take_pause_pending());
        assert!(!state.take_pause_pending());
    }

    #[test]
    fn duplicate_pause_notifications_are_idempotent() {
        let mut state = LifecycleState::default();

        state.pause_session();
        state.pause_session();

        assert!(!state.seat_active());
        assert!(state.take_pause_pending());
        assert!(!state.take_pause_pending());
    }

    #[test]
    fn first_shutdown_reason_wins() {
        let mut state = LifecycleState::default();

        state.request_shutdown(ShutdownReason::NativeEscapeShortcut);
        state.request_shutdown(ShutdownReason::Terminate);

        assert_eq!(
            state.shutdown_reason(),
            Some(ShutdownReason::NativeEscapeShortcut)
        );
    }

    #[test]
    fn native_escape_has_an_explicit_non_signal_reason() {
        assert_eq!(
            ShutdownReason::NativeEscapeShortcut.description(),
            "Ctrl+Alt+Backspace"
        );
    }

    #[test]
    fn teardown_gate_only_arms_one_caller() {
        let mut gate = TeardownGate::default();

        assert!(gate.begin());
        assert!(!gate.begin());
        assert!(!gate.begin());
    }

    #[test]
    fn finite_inactive_wait_preserves_the_outer_deadline() {
        let now = Instant::now();
        let deadline = now + Duration::from_secs(7);

        assert_eq!(
            inactive_dispatch(now, Some(deadline)),
            InactiveDispatch::Wait(Some(Duration::from_secs(7)))
        );
        assert_eq!(
            inactive_dispatch(deadline, Some(deadline)),
            InactiveDispatch::DeadlineReached
        );
    }

    #[test]
    fn unlimited_inactive_wait_remains_event_driven() {
        assert_eq!(
            inactive_dispatch(Instant::now(), None),
            InactiveDispatch::Wait(None)
        );
    }
}
