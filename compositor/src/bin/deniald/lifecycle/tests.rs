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
fn active_kms_session_needs_no_periodic_lifecycle_service() {
    let mut state = LifecycleState::default();

    assert!(!state.requires_kms_service(true, false));
    assert!(state.requires_kms_service(false, false));
    assert!(state.requires_kms_service(true, true));

    state.pause_session();
    state.activate_session();
    assert!(state.requires_kms_service(true, false));
    assert!(state.take_pause_pending());
    assert!(!state.requires_kms_service(true, false));
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
