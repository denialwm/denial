use super::*;
use std::cell::Cell;
use std::rc::Rc;

fn key(output: u64, crtc: u32) -> ScanoutKey {
    ScanoutKey { output, crtc }
}

#[test]
fn reconcile_plan_reuses_only_exact_scanout_ownership() {
    let current = [key(1, 10), key(2, 11)];
    let desired = [key(2, 11), key(1, 12), key(3, 10)];

    assert_eq!(
        plan_reconcile(&current, &desired).unwrap(),
        vec![
            ScanoutOrigin::Reuse(1),
            ScanoutOrigin::Create,
            ScanoutOrigin::Create,
        ]
    );
}

#[test]
fn reconcile_plan_rejects_aliasing_a_crtc() {
    let error = plan_reconcile(&[], &[key(1, 10), key(2, 10)]).unwrap_err();

    assert_eq!(error, ReconcilePlanError::DuplicateCrtc(10));
}

#[test]
fn reconcile_plan_rejects_corrupt_current_ownership_and_zero_handles() {
    assert_eq!(
        plan_reconcile(&[key(1, 10), key(1, 11)], &[]).unwrap_err(),
        ReconcilePlanError::DuplicateOutput(1)
    );
    assert_eq!(
        plan_reconcile(&[key(1, 10), key(2, 10)], &[]).unwrap_err(),
        ReconcilePlanError::DuplicateCrtc(10)
    );
    assert_eq!(
        plan_reconcile(&[], &[key(0, 10)]).unwrap_err(),
        ReconcilePlanError::InvalidOutput
    );
    assert_eq!(
        plan_reconcile(&[], &[key(1, 0)]).unwrap_err(),
        ReconcilePlanError::InvalidCrtc
    );
    assert_eq!(
        plan_reconcile(&[], &[key(1, 10), key(1, 11)]).unwrap_err(),
        ReconcilePlanError::DuplicateOutput(1)
    );
}

#[test]
fn failure_injection_requires_rollback_only_after_a_real_commit() {
    let mut progress = HotplugProgress::default();
    assert!(!progress.rollback_required());

    progress.mark_validated();
    assert!(!progress.rollback_required());

    progress.record_commit();
    assert!(progress.rollback_required());
    progress.record_commit();
    assert!(progress.rollback_required());

    progress.mark_presented();
    assert!(progress.rollback_required());
    progress.mark_rolled_back();
    assert_eq!(progress.phase(), HotplugPhase::RolledBack);
    assert!(!progress.rollback_required());
}

#[test]
fn finalized_transaction_never_rolls_back() {
    let mut progress = HotplugProgress::default();
    progress.mark_validated();
    progress.record_commit();
    progress.mark_presented();
    progress.mark_finalized();

    assert_eq!(progress.phase(), HotplugPhase::Finalized);
    assert!(!progress.rollback_required());
}

#[test]
fn all_outputs_powered_off_can_finalize_without_a_kms_commit() {
    let mut progress = HotplugProgress::default();
    progress.mark_validated();
    progress.mark_presented();
    progress.mark_finalized();

    assert_eq!(progress.phase(), HotplugPhase::Finalized);
    assert!(!progress.rollback_required());
}

#[test]
fn commit_counter_saturates_but_never_loses_rollback_requirement() {
    let mut progress = HotplugProgress {
        phase: HotplugPhase::Committing,
        committed_outputs: usize::MAX,
    };
    progress.record_commit();

    assert_eq!(progress.committed_outputs, usize::MAX);
    assert!(progress.rollback_required());
}

#[test]
fn candidate_install_reuses_the_candidate_allocation_and_resolves_immediately() {
    let mut destination = vec![99_u32];
    let mut candidate = Vec::with_capacity(8);
    candidate.extend([1, 2, 3]);
    let candidate_pointer = candidate.as_ptr();
    let candidate_capacity = candidate.capacity();
    let mut resolved = false;

    let displaced = install_candidate(&mut destination, &mut candidate, &mut resolved);

    assert!(resolved);
    assert!(candidate.is_empty());
    assert_eq!(destination, [1, 2, 3]);
    assert_eq!(destination.as_ptr(), candidate_pointer);
    assert_eq!(destination.capacity(), candidate_capacity);
    assert_eq!(displaced, [99]);
}

#[test]
fn candidate_install_resolves_before_displaced_resources_can_drop() {
    struct DropAfterResolution {
        resolved: Rc<Cell<bool>>,
        check: bool,
    }

    impl Drop for DropAfterResolution {
        fn drop(&mut self) {
            if self.check {
                assert!(self.resolved.get(), "resource dropped before resolution");
            }
        }
    }

    let observed = Rc::new(Cell::new(false));
    let mut destination = vec![DropAfterResolution {
        resolved: observed.clone(),
        check: true,
    }];
    let mut candidate = vec![DropAfterResolution {
        resolved: observed.clone(),
        check: false,
    }];
    let mut resolved = false;

    let displaced = install_candidate(&mut destination, &mut candidate, &mut resolved);
    observed.set(resolved);
    drop(displaced);

    assert!(resolved);
    assert_eq!(destination.len(), 1);
}

#[test]
fn quarantined_created_resources_are_excluded_from_hardware_rollback() {
    let mut restored = vec!["old-a", "old-b"];
    let mut quarantined = vec!["created-clear-failed"];

    let rollback_count = append_quarantined(&mut restored, &mut quarantined);

    assert_eq!(rollback_count, 2);
    assert_eq!(&restored[..rollback_count], ["old-a", "old-b"]);
    assert_eq!(restored[rollback_count..], ["created-clear-failed"]);
    assert!(quarantined.is_empty());
}
