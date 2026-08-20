use super::{DPMS_WAKE_TOPOLOGY_GRACE, transient_dpms_output_removal_count};
use denial_core::topology::OutputId;
use std::time::Instant;

#[test]
fn missing_output_is_deferred_only_inside_dpms_wake_grace() {
    let now = Instant::now();
    let grace_until = now + DPMS_WAKE_TOPOLOGY_GRACE;
    let current = [OutputId(4), OutputId(5)];

    assert_eq!(
        transient_dpms_output_removal_count(Some(grace_until), now, current, [OutputId(5)]),
        1
    );
    assert_eq!(
        transient_dpms_output_removal_count(Some(grace_until), grace_until, current, [OutputId(5)]),
        0
    );
    assert_eq!(
        transient_dpms_output_removal_count(None, now, current, [OutputId(5)]),
        0
    );
}

#[test]
fn recovered_or_additive_topology_is_never_deferred() {
    let now = Instant::now();
    let grace_until = now + DPMS_WAKE_TOPOLOGY_GRACE;

    assert_eq!(
        transient_dpms_output_removal_count(
            Some(grace_until),
            now,
            [OutputId(4), OutputId(5)],
            [OutputId(4), OutputId(5)]
        ),
        0
    );
    assert_eq!(
        transient_dpms_output_removal_count(
            Some(grace_until),
            now,
            [OutputId(5)],
            [OutputId(4), OutputId(5)]
        ),
        0
    );
}
