//! Revision tracking for publishing the native Wayland scene to Flutter.
//!
//! A scene snapshot is acknowledged as soon as Flutter accepts it. Presentation
//! deliberately does not mutate this state: a Wayland commit can arrive while
//! a previously synchronized Flutter frame is waiting for KMS, and clearing a
//! dirty flag after that flip would lose the newer commit.

#[cfg(feature = "flutter")]
use std::collections::{HashMap, HashSet};

#[derive(Debug, Default, Eq, PartialEq)]
pub(super) struct SceneSyncState {
    metadata_revision: u64,
    #[cfg(feature = "flutter")]
    // `None` guarantees an initial empty snapshot too. Flutter needs that
    // publication to establish its authoritative window list.
    synchronized_metadata_revision: Option<u64>,
    #[cfg(feature = "flutter")]
    buffer_revision: u64,
    #[cfg(feature = "flutter")]
    synchronized_buffer_revision: u64,
    #[cfg(feature = "flutter")]
    dirty_surfaces: HashMap<u64, u64>,
    #[cfg(feature = "flutter")]
    dirty_windows: HashSet<u64>,
    #[cfg(feature = "flutter")]
    full_metadata: bool,
}

/// What to do with a window event when the native window list and Dart's
/// currently published window list temporarily differ.
///
/// A live XDG toplevel is deliberately distinct from a published one: before
/// its first buffer there is no `WindowDescription` to send to Dart, but focus
/// and placement events generated during that interval must survive until the
/// first renderable snapshot.
#[cfg(feature = "flutter")]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum WindowEventDisposition {
    Send,
    Retain,
    Drop,
}

#[cfg(feature = "flutter")]
pub(super) const fn window_event_disposition(
    published: bool,
    live_toplevel: bool,
) -> WindowEventDisposition {
    if published {
        WindowEventDisposition::Send
    } else if live_toplevel {
        WindowEventDisposition::Retain
    } else {
        WindowEventDisposition::Drop
    }
}

impl SceneSyncState {
    #[cfg(feature = "flutter")]
    pub(super) fn metadata_revision(&self) -> u64 {
        self.metadata_revision
    }

    pub(super) fn mark_dirty(&mut self) {
        #[cfg(feature = "flutter")]
        {
            self.full_metadata = true;
            self.dirty_windows.clear();
        }
        // A wrap is not realistically reachable, but invalidating the
        // acknowledgement preserves correctness if it ever happens.
        #[cfg(feature = "flutter")]
        if self.metadata_revision == u64::MAX {
            self.synchronized_metadata_revision = None;
        }
        self.metadata_revision = self.metadata_revision.wrapping_add(1);
    }

    #[cfg(feature = "flutter")]
    pub(super) fn mark_window_dirty(&mut self, window_id: u64) {
        if self.metadata_revision == u64::MAX {
            self.mark_dirty();
        } else {
            self.metadata_revision += 1;
            self.dirty_windows.insert(window_id);
        }
    }

    #[cfg(feature = "flutter")]
    pub(super) fn metadata_windows(&self) -> Option<&HashSet<u64>> {
        (!self.full_metadata && self.synchronized_metadata_revision.is_some())
            .then_some(&self.dirty_windows)
    }

    #[cfg(feature = "flutter")]
    pub(super) fn mark_surfaces_dirty(&mut self, surface_ids: impl IntoIterator<Item = u64>) {
        let mut surface_ids = surface_ids.into_iter().peekable();
        if surface_ids.peek().is_none() {
            return;
        }

        if self.buffer_revision == u64::MAX {
            // Keep the ordering used by acknowledgement simple across the
            // practically unreachable wrap boundary.
            self.buffer_revision = 1;
            self.synchronized_buffer_revision = 0;
            for dirty_revision in self.dirty_surfaces.values_mut() {
                *dirty_revision = 1;
            }
            for surface_id in surface_ids {
                self.dirty_surfaces.insert(surface_id, 1);
            }
            return;
        }
        self.buffer_revision += 1;
        let revision = self.buffer_revision;
        for surface_id in surface_ids {
            self.dirty_surfaces.insert(surface_id, revision);
        }
    }

    #[cfg(feature = "flutter")]
    pub(super) fn pending_metadata_revision(&self) -> Option<u64> {
        (self.synchronized_metadata_revision != Some(self.metadata_revision))
            .then_some(self.metadata_revision)
    }

    #[cfg(feature = "flutter")]
    pub(super) fn pending_buffer_revision(&self) -> Option<u64> {
        (self.synchronized_buffer_revision != self.buffer_revision).then_some(self.buffer_revision)
    }

    #[cfg(feature = "flutter")]
    pub(super) const fn buffer_revision(&self) -> u64 {
        self.buffer_revision
    }

    #[cfg(feature = "flutter")]
    pub(super) fn dirty_surface_ids(&self, revision: u64) -> impl Iterator<Item = u64> + '_ {
        self.dirty_surfaces
            .iter()
            .filter_map(move |(surface_id, dirty_revision)| {
                (*dirty_revision <= revision).then_some(*surface_id)
            })
    }

    #[cfg(feature = "flutter")]
    pub(super) fn mark_metadata_synchronized(
        &mut self,
        metadata_revision: u64,
        buffer_revision: u64,
    ) {
        self.synchronized_metadata_revision = Some(metadata_revision);
        if self.metadata_revision == metadata_revision {
            self.full_metadata = false;
            self.dirty_windows.clear();
        }
        self.mark_buffers_synchronized(buffer_revision);
    }

    #[cfg(feature = "flutter")]
    pub(super) fn mark_buffers_synchronized(&mut self, revision: u64) {
        self.synchronized_buffer_revision = revision;
        self.dirty_surfaces
            .retain(|_, dirty_revision| *dirty_revision > revision);
    }

    #[cfg(feature = "flutter")]
    pub(super) fn invalidate_runtime(&mut self) {
        self.synchronized_metadata_revision = None;
    }
}

#[cfg(all(test, feature = "flutter"))]
mod incremental_metadata_tests {
    use super::*;

    #[test]
    fn global_changes_override_local_metadata_and_rehydration_stays_complete() {
        let mut state = SceneSyncState::default();
        assert!(state.metadata_windows().is_none());
        state.mark_metadata_synchronized(0, 0);
        state.mark_window_dirty(10);
        state.mark_window_dirty(20);
        assert_eq!(state.metadata_windows(), Some(&HashSet::from([10, 20])));
        state.mark_dirty();
        state.mark_window_dirty(30);
        assert!(state.metadata_windows().is_none());
        state.mark_metadata_synchronized(state.metadata_revision, 0);
        assert_eq!(state.metadata_windows(), Some(&HashSet::new()));
        state.invalidate_runtime();
        assert!(state.metadata_windows().is_none());
    }

    #[test]
    fn acknowledging_an_older_snapshot_preserves_newer_window_invalidations() {
        let mut state = SceneSyncState::default();
        state.mark_metadata_synchronized(0, 0);
        state.mark_window_dirty(10);
        let captured = state.metadata_revision;
        state.mark_window_dirty(20);
        state.mark_metadata_synchronized(captured, 0);
        assert!(state.pending_metadata_revision().is_some());
        assert!(state.metadata_windows().unwrap().contains(&20));
        state.mark_dirty();
        state.mark_metadata_synchronized(captured, 0);
        assert!(state.metadata_windows().is_none());
    }
}
