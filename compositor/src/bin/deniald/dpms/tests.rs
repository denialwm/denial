use super::*;

fn output(id: u64) -> OutputId {
    OutputId(id)
}

#[test]
fn powered_off_output_removal_is_deferred_until_wake() {
    let now = Instant::now();
    let mut guard = DpmsTopologyGuard::default();
    guard.note_powered_off(output(2));

    assert_eq!(
        guard.defer_missing_outputs(now, [output(1), output(2)], [output(1)],),
        Some(DeferredDpmsTopology {
            missing_outputs: 1,
            grace_until: None,
            first_observation: true,
        })
    );
    assert!(!guard.service_deadline(now + Duration::from_secs(60)));
}

#[test]
fn waking_output_removal_is_bounded_by_the_grace_deadline() {
    let now = Instant::now();
    let deadline = now + DPMS_WAKE_TOPOLOGY_GRACE;
    let mut guard = DpmsTopologyGuard::default();
    guard.note_powered_off(output(2));
    guard.note_wake(output(2), now);

    assert_eq!(
        guard.defer_missing_outputs(now, [output(1), output(2)], [output(1)],),
        Some(DeferredDpmsTopology {
            missing_outputs: 1,
            grace_until: Some(deadline),
            first_observation: true,
        })
    );
    assert_eq!(
        guard.limit_dispatch_timeout(now, Duration::from_secs(30)),
        DPMS_WAKE_TOPOLOGY_GRACE,
    );
    assert!(guard.service_deadline(deadline));
    assert_eq!(
        guard.defer_missing_outputs(deadline, [output(1), output(2)], [output(1)],),
        None,
    );
}

#[test]
fn recovered_connector_cancels_the_pending_removal() {
    let now = Instant::now();
    let mut guard = DpmsTopologyGuard::default();
    guard.note_powered_off(output(2));
    guard.note_wake(output(2), now);
    assert!(
        guard
            .defer_missing_outputs(now, [output(1), output(2)], [output(1)])
            .is_some()
    );

    assert_eq!(
        guard.defer_missing_outputs(
            now + Duration::from_millis(500),
            [output(1), output(2)],
            [output(1), output(2)],
        ),
        None,
    );
    assert!(!guard.service_deadline(now + DPMS_WAKE_TOPOLOGY_GRACE));
}

#[test]
fn genuine_non_dpms_removal_is_never_deferred() {
    let now = Instant::now();
    let mut guard = DpmsTopologyGuard::default();
    guard.note_powered_off(output(2));
    guard.note_wake(output(2), now);

    assert_eq!(
        guard.defer_missing_outputs(now, [output(1), output(2)], [output(2)],),
        None,
    );
}

#[test]
fn recovery_cancellation_removes_all_dpms_exceptions() {
    let now = Instant::now();
    let mut guard = DpmsTopologyGuard::default();
    guard.note_powered_off(output(2));
    guard.note_wake(output(2), now);
    guard.cancel();

    assert_eq!(
        guard.defer_missing_outputs(now, [output(1), output(2)], [output(1)],),
        None,
    );
}
