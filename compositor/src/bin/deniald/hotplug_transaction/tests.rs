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
