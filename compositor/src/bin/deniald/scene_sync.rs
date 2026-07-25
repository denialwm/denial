//! Revision tracking for publishing the native Wayland scene to Flutter.
//!
//! A scene snapshot is acknowledged as soon as Flutter accepts it. Presentation
//! deliberately does not mutate this state: a Wayland commit can arrive while
//! a previously synchronized Flutter frame is waiting for KMS, and clearing a
//! dirty flag after that flip would lose the newer commit.

#[cfg(feature = "flutter")]
use std::collections::HashMap;

#[derive(Debug, Eq, PartialEq)]
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
}

impl Default for SceneSyncState {
    fn default() -> Self {
        Self {
            metadata_revision: 0,
            #[cfg(feature = "flutter")]
            synchronized_metadata_revision: None,
            #[cfg(feature = "flutter")]
            buffer_revision: 0,
            #[cfg(feature = "flutter")]
            synchronized_buffer_revision: 0,
            #[cfg(feature = "flutter")]
            dirty_surfaces: HashMap::new(),
        }
    }
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
    pub(super) fn mark_dirty(&mut self) {
        // A wrap is not realistically reachable, but invalidating the
        // acknowledgement preserves correctness if it ever happens.
        #[cfg(feature = "flutter")]
        if self.metadata_revision == u64::MAX {
            self.synchronized_metadata_revision = None;
        }
        self.metadata_revision = self.metadata_revision.wrapping_add(1);
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
mod tests {
    use super::{SceneSyncState, WindowEventDisposition, window_event_disposition};

    #[test]
    fn initial_scene_is_published_exactly_once() {
        let mut state = SceneSyncState::default();
        let initial = state
            .pending_metadata_revision()
            .expect("initial publication");
        state.mark_metadata_synchronized(initial, 0);

        assert_eq!(state.pending_metadata_revision(), None);
        assert_eq!(state.pending_buffer_revision(), None);
    }

    #[test]
    fn change_after_snapshot_is_not_acknowledged_by_older_sync() {
        let mut state = SceneSyncState::default();
        let snapshot = state
            .pending_metadata_revision()
            .expect("initial publication");
        state.mark_dirty();
        state.mark_metadata_synchronized(snapshot, 0);

        assert_eq!(state.pending_metadata_revision(), Some(1));
    }

    #[test]
    fn runtime_restart_republishes_an_unchanged_scene() {
        let mut state = SceneSyncState::default();
        let initial = state
            .pending_metadata_revision()
            .expect("initial publication");
        state.mark_metadata_synchronized(initial, 0);
        state.invalidate_runtime();

        assert_eq!(state.pending_metadata_revision(), Some(initial));
    }

    #[test]
    fn buffer_only_changes_do_not_republish_metadata() {
        let mut state = SceneSyncState::default();
        state.mark_metadata_synchronized(0, 0);
        state.mark_surfaces_dirty([7, 9]);

        assert_eq!(state.pending_metadata_revision(), None);
        assert_eq!(state.pending_buffer_revision(), Some(1));
        let mut dirty = state.dirty_surface_ids(1).collect::<Vec<_>>();
        dirty.sort_unstable();
        assert_eq!(dirty, [7, 9]);

        state.mark_buffers_synchronized(1);
        assert_eq!(state.pending_buffer_revision(), None);
        assert_eq!(state.dirty_surface_ids(1).count(), 0);
    }

    #[test]
    fn older_buffer_acknowledgement_keeps_newer_surface_work() {
        let mut state = SceneSyncState::default();
        state.mark_metadata_synchronized(0, 0);
        state.mark_surfaces_dirty([7]);
        let snapshot = state.pending_buffer_revision().unwrap();
        state.mark_surfaces_dirty([9]);
        state.mark_buffers_synchronized(snapshot);

        assert_eq!(state.pending_buffer_revision(), Some(2));
        assert_eq!(state.dirty_surface_ids(2).collect::<Vec<_>>(), [9]);
    }

    #[test]
    fn pre_buffer_window_events_wait_for_the_first_published_snapshot() {
        assert_eq!(
            window_event_disposition(false, true),
            WindowEventDisposition::Retain
        );
        assert_eq!(
            window_event_disposition(true, true),
            WindowEventDisposition::Send
        );
    }

    #[test]
    fn only_events_for_destroyed_toplevels_are_dropped() {
        assert_eq!(
            window_event_disposition(false, false),
            WindowEventDisposition::Drop
        );
    }
}
