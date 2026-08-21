use super::*;

#[cfg(test)]
mod decoration_policy_tests {
    use super::*;

    #[test]
    fn flutter_shell_is_always_the_decoration_owner() {
        assert_eq!(shell_decoration_mode(), XdgDecorationMode::ServerSide);
    }
}

#[cfg(test)]
mod client_budget_tests {
    use super::*;

    #[test]
    fn atomic_quota_rejects_the_exact_boundary_without_overflowing() {
        let counter = AtomicUsize::new(MAX_WAYLAND_CLIENTS - 1);
        assert!(try_reserve(&counter, MAX_WAYLAND_CLIENTS));
        assert!(!try_reserve(&counter, MAX_WAYLAND_CLIENTS));
        assert_eq!(counter.load(Ordering::Relaxed), MAX_WAYLAND_CLIENTS);
    }

    #[test]
    fn dropping_client_state_returns_its_connection_reservation() {
        let budget = Arc::new(WaylandClientBudget::default());
        let client = budget.try_reserve_client().expect("first client fits");
        assert_eq!(budget.clients.load(Ordering::Relaxed), 1);
        drop(client);
        assert_eq!(budget.clients.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn disconnect_release_is_prompt_idempotent_and_closes_registration() {
        let budget = Arc::new(WaylandClientBudget::default());
        let client = budget.try_reserve_client().expect("first client fits");
        assert!(client.try_register_surface(ObjectId::null()));
        assert_eq!(budget.clients.load(Ordering::Relaxed), 1);
        assert_eq!(budget.surfaces.load(Ordering::Relaxed), 1);

        client.release_reservations();
        assert_eq!(budget.clients.load(Ordering::Relaxed), 0);
        assert_eq!(budget.surfaces.load(Ordering::Relaxed), 0);
        assert!(!client.try_register_surface(ObjectId::null()));

        client.release_reservations();
        drop(client);
        assert_eq!(budget.clients.load(Ordering::Relaxed), 0);
        assert_eq!(budget.surfaces.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn quota_release_is_saturating_under_teardown() {
        let counter = AtomicUsize::new(1);
        release(&counter, usize::MAX);
        assert_eq!(counter.load(Ordering::Relaxed), 0);
    }
}

#[cfg(all(test, feature = "flutter"))]
mod surface_commit_tests {
    use super::super::super::SurfaceCommitKind;
    use super::{
        SurfaceCommitMetadata, commit_affects_published_scene, commit_has_visual_update,
        surface_commit_kind,
    };

    #[test]
    fn ignores_commits_that_cannot_publish_native_scene_state() {
        // Cursor, drag icon, and an otherwise unmapped surface have no desktop
        // owner. A synchronized child is published by the parent commit.
        assert!(!commit_affects_published_scene(false, false, true));
        assert!(!commit_affects_published_scene(true, true, true));
        assert!(!commit_affects_published_scene(false, true, false));
    }

    #[test]
    fn publishes_desynchronized_and_root_tree_commits() {
        // Toplevel roots, popup roots, parents releasing synchronized state,
        // and desynchronized subsurfaces all resolve to a desktop owner.
        assert!(commit_affects_published_scene(false, true, true));
    }

    #[test]
    fn buffer_assignment_or_sampling_change_is_a_visual_generation() {
        assert!(!commit_has_visual_update(false, false, false, false));
        assert!(commit_has_visual_update(true, false, false, false));
        assert!(commit_has_visual_update(false, true, false, false));
        assert!(commit_has_visual_update(false, false, true, false));
        assert!(commit_has_visual_update(false, false, false, true));
    }

    #[test]
    fn only_same_layout_replacement_buffers_take_the_texture_fast_path() {
        assert_eq!(
            surface_commit_kind(false, true, false, false),
            Some(SurfaceCommitKind::BufferOnly)
        );
        assert_eq!(
            surface_commit_kind(true, true, false, false),
            Some(SurfaceCommitKind::Metadata)
        );
        assert_eq!(
            surface_commit_kind(false, true, false, true),
            Some(SurfaceCommitKind::Metadata)
        );
        assert_eq!(
            surface_commit_kind(false, false, true, false),
            Some(SurfaceCommitKind::Metadata)
        );
        assert_eq!(surface_commit_kind(false, false, false, false), None);
        assert_eq!(
            SurfaceCommitKind::BufferOnly.merge(SurfaceCommitKind::Metadata),
            SurfaceCommitKind::Metadata
        );
    }

    #[test]
    fn damage_only_callback_commit_is_not_a_visual_generation() {
        let callback_damage = SurfaceCommitMetadata {
            has_damage: true,
            has_frame_callbacks: true,
        };
        assert!(callback_damage.has_damage);
        assert!(callback_damage.has_frame_callbacks);
        assert!(!commit_has_visual_update(false, false, false, false));
    }

    #[test]
    fn consumed_damage_does_not_leak_into_a_callback_only_commit() {
        let mut current = SurfaceCommitMetadata::default();
        SurfaceCommitMetadata {
            has_damage: true,
            has_frame_callbacks: true,
        }
        .merge_into_current(&mut current);
        let visual = std::mem::take(&mut current);
        assert!(visual.has_damage);
        assert!(visual.has_frame_callbacks);

        SurfaceCommitMetadata {
            has_damage: false,
            has_frame_callbacks: true,
        }
        .merge_into_current(&mut current);
        let callback_only = std::mem::take(&mut current);
        assert!(!callback_only.has_damage);
        assert!(callback_only.has_frame_callbacks);
        assert!(!commit_has_visual_update(false, false, false, false));
    }
}
