//! Revision tracking for publishing the native Wayland scene to Flutter.
//!
//! A scene snapshot is acknowledged as soon as Flutter accepts it. Presentation
//! deliberately does not mutate this state: a Wayland commit can arrive while
//! a previously synchronized Flutter frame is waiting for KMS, and clearing a
//! dirty flag after that flip would lose the newer commit.

#[derive(Debug, Default, Eq, PartialEq)]
pub(super) struct SceneSyncState {
    current_revision: u64,
    #[cfg(feature = "flutter")]
    // `None` guarantees an initial empty snapshot too. Flutter needs that
    // publication to establish its authoritative window list.
    synchronized_revision: Option<u64>,
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
        if self.current_revision == u64::MAX {
            self.synchronized_revision = None;
        }
        self.current_revision = self.current_revision.wrapping_add(1);
    }

    #[cfg(feature = "flutter")]
    pub(super) fn pending_revision(&self) -> Option<u64> {
        (self.synchronized_revision != Some(self.current_revision)).then_some(self.current_revision)
    }

    #[cfg(feature = "flutter")]
    pub(super) fn mark_synchronized(&mut self, revision: u64) {
        self.synchronized_revision = Some(revision);
    }

    #[cfg(feature = "flutter")]
    pub(super) fn invalidate_runtime(&mut self) {
        self.synchronized_revision = None;
    }
}

#[cfg(all(test, feature = "flutter"))]
mod tests {
    use super::{SceneSyncState, WindowEventDisposition, window_event_disposition};

    #[test]
    fn initial_scene_is_published_exactly_once() {
        let mut state = SceneSyncState::default();
        let initial = state.pending_revision().expect("initial publication");
        state.mark_synchronized(initial);

        assert_eq!(state.pending_revision(), None);
    }

    #[test]
    fn change_after_snapshot_is_not_acknowledged_by_older_sync() {
        let mut state = SceneSyncState::default();
        let snapshot = state.pending_revision().expect("initial publication");
        state.mark_dirty();
        state.mark_synchronized(snapshot);

        assert_eq!(state.pending_revision(), Some(1));
    }

    #[test]
    fn runtime_restart_republishes_an_unchanged_scene() {
        let mut state = SceneSyncState::default();
        let initial = state.pending_revision().expect("initial publication");
        state.mark_synchronized(initial);
        state.invalidate_runtime();

        assert_eq!(state.pending_revision(), Some(initial));
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
