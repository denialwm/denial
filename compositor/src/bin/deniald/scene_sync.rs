//! Revision tracking for publishing the native Wayland scene to Flutter.
//!
//! A scene snapshot is acknowledged as soon as Flutter accepts it. Presentation
//! deliberately does not mutate this state: a Wayland commit can arrive while
//! a previously synchronized Flutter frame is waiting for KMS, and clearing a
//! dirty flag after that flip would lose the newer commit.

#[cfg(feature = "flutter")]
use std::collections::HashMap;

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
