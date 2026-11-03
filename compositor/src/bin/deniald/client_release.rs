//! Explicit-sync release points of the client buffers Flutter samples.
//!
//! Smithay's renderer state signals a commit's release point on the CPU when
//! the last guard of its buffer drops. Flutter's frame batches hold guards
//! until the event loop sees their sync_file signal, so that drop waits for
//! the GPU and then for the event loop. Denial takes the point at commit
//! instead. A batch hands its submission's sync_file to the point when Flutter
//! submits and stops holding it; once nothing shows the buffer any more, the
//! point is attached to the newest submission that sampled it, and the kernel
//! signals it when the GPU has read the buffer. A buffer no submission sampled
//! is released on the CPU.
use smithay::backend::renderer::utils::RendererSurfaceStateUserData;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
#[cfg(feature = "flutter")]
use smithay::wayland::compositor::SurfaceData;
use smithay::wayland::compositor::{BufferAssignment, SurfaceAttributes, with_states};
use smithay::wayland::drm_syncobj::{DrmSyncPoint, DrmSyncobjCachedState};
use std::os::fd::{AsFd, OwnedFd};
use std::sync::{Arc, Mutex};
use tracing::warn;

#[derive(Debug)]
pub(crate) struct ClientRelease {
    point: DrmSyncPoint,
    /// The newest Flutter submission that sampled the buffer.
    sampled: Mutex<Option<Arc<OwnedFd>>>,
}

impl ClientRelease {
    fn new(point: DrmSyncPoint) -> Arc<Self> {
        Arc::new(Self {
            point,
            sampled: Mutex::new(None),
        })
    }

    /// Record `fence`, a submission that sampled the buffer. Submissions
    /// complete in order, so the newest one covers every earlier sample.
    #[cfg(feature = "flutter")]
    pub(crate) fn sampled_by(&self, fence: &Arc<OwnedFd>) {
        *self
            .sampled
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(Arc::clone(fence));
    }
}

impl Drop for ClientRelease {
    fn drop(&mut self) {
        let sampled = self
            .sampled
            .get_mut()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .take();
        if let Some(fence) = sampled {
            match self.point.import_sync_file(fence.as_fd()) {
                Ok(()) => return,
                Err(error) => warn!(%error, "could not attach a release fence; signalling now"),
            }
        }
        if let Err(error) = self.point.signal() {
            warn!(%error, "could not signal a client buffer release point");
        }
    }
}

/// The release point of the buffer a surface currently shows.
#[derive(Default)]
struct CurrentRelease(Mutex<Option<Arc<ClientRelease>>>);

/// Take the release point of a buffer this commit attaches, before Smithay's
/// renderer state claims it.
pub(crate) fn take_attached(surface: &WlSurface) -> Option<DrmSyncPoint> {
    with_states(surface, |states| {
        let attaches = matches!(
            states
                .cached_state
                .get::<SurfaceAttributes>()
                .current()
                .buffer,
            Some(BufferAssignment::NewBuffer(_))
        );
        if !attaches {
            return None;
        }
        states
            .cached_state
            .get::<DrmSyncobjCachedState>()
            .current()
            .release_point
            .take()
    })
}

/// Make `point` the release of the buffer the surface now shows, after a
/// commit attached or removed one. Without a sampleable buffer the point is
/// signalled at once.
pub(crate) fn replace(surface: &WlSurface, point: Option<DrmSyncPoint>) {
    let point = point.map(ClientRelease::new);
    let (previous, unused) = with_states(surface, |states| {
        let has_buffer = states
            .data_map
            .get::<RendererSurfaceStateUserData>()
            .is_some_and(|renderer| {
                renderer
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner())
                    .buffer()
                    .is_some()
            });
        let (shown, unused) = if has_buffer {
            (point, None)
        } else {
            (None, point)
        };
        let slot = states
            .data_map
            .get_or_insert_threadsafe(CurrentRelease::default);
        let mut current = slot
            .0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        (std::mem::replace(&mut *current, shown), unused)
    });
    // Signal outside the surface lock.
    drop((previous, unused));
}

#[cfg(feature = "flutter")]
/// The release a new guard of the surface's current buffer must carry.
pub(crate) fn current(states: &SurfaceData) -> Option<Arc<ClientRelease>> {
    states.data_map.get::<CurrentRelease>().and_then(|slot| {
        slot.0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    })
}
