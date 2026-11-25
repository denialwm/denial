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

    /// Record `fence`, a submission that sampled the buffer. Submissions on
    /// one queue complete in order, so the newest covers every earlier
    /// sample. The Vulkan composer adds a second queue: a sample on the other
    /// one that may still run is merged in.
    #[cfg(feature = "flutter")]
    pub(crate) fn sampled_by(&self, fence: &Arc<OwnedFd>) {
        let mut sampled = self
            .sampled
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if crate::options::VULKAN_COMPOSER.load(std::sync::atomic::Ordering::Relaxed)
            && let Some(previous) = sampled.as_ref()
            && !Arc::ptr_eq(previous, fence)
            && !signalled(previous)
        {
            match merge(previous, fence) {
                Ok(merged) => {
                    *sampled = Some(Arc::new(merged));
                    return;
                }
                Err(error) => {
                    warn!(%error, "could not merge release fences; waiting for the earlier one");
                    wait(previous);
                }
            }
        }
        *sampled = Some(Arc::clone(fence));
    }
}

#[cfg(feature = "flutter")]
fn poll_fence(fence: &OwnedFd, timeout_ms: i32) -> bool {
    use std::os::fd::AsRawFd;
    let mut pollfd = libc::pollfd {
        fd: fence.as_raw_fd(),
        events: libc::POLLIN,
        revents: 0,
    };
    loop {
        // SAFETY: one valid pollfd for a live descriptor.
        let ready = unsafe { libc::poll(&mut pollfd, 1, timeout_ms) };
        if ready >= 0 || std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted {
            return ready > 0;
        }
    }
}

#[cfg(feature = "flutter")]
fn signalled(fence: &OwnedFd) -> bool {
    poll_fence(fence, 0)
}

#[cfg(feature = "flutter")]
fn wait(fence: &OwnedFd) {
    poll_fence(fence, -1);
}

/// A sync_file that signals once both do (SYNC_IOC_MERGE).
#[cfg(feature = "flutter")]
fn merge(first: &OwnedFd, second: &OwnedFd) -> std::io::Result<OwnedFd> {
    use std::os::fd::{AsRawFd, FromRawFd};
    #[repr(C)]
    struct SyncMergeData {
        name: [u8; 32],
        fd2: i32,
        fence: i32,
        flags: u32,
        pad: u32,
    }
    const SYNC_IOC_MERGE: libc::c_ulong = 0xc030_3e03;
    let mut data = SyncMergeData {
        name: *b"denial-client-release\0\0\0\0\0\0\0\0\0\0\0",
        fd2: second.as_raw_fd(),
        fence: -1,
        flags: 0,
        pad: 0,
    };
    // SAFETY: SYNC_IOC_MERGE reads fd2 and writes `fence` in this struct.
    let result = unsafe { libc::ioctl(first.as_raw_fd(), SYNC_IOC_MERGE, &mut data) };
    if result < 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: the kernel returned a new descriptor the caller owns.
    Ok(unsafe { OwnedFd::from_raw_fd(data.fence) })
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
                Err(error) => {
                    warn!(%error, "could not attach a release fence; signalling once it signals");
                    #[cfg(feature = "flutter")]
                    wait(&fence);
                }
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
