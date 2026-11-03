//! Immutable CPU-written, GPU-importable SHM snapshots.
//!
//! Only an unpublished buffer may be mapped for writing. Published storage is
//! held by scene sources, image leases, sampled-reader fences AND cached EGL
//! imports. The final storage owner returns it to the bounded free list.

use std::ffi::c_void;
use std::io;
use std::os::fd::{AsFd, AsRawFd};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, Weak};

use smithay::backend::allocator::dmabuf::{AsDmabuf, Dmabuf};
use smithay::backend::allocator::gbm::{GbmBuffer, GbmBufferFlags, GbmDevice};
use smithay::backend::allocator::{Fourcc, Modifier};
use smithay::backend::drm::DrmDeviceFd;
use smithay::backend::renderer::ImportDma;
use smithay::backend::renderer::gles::GlesRenderer;
use smithay::reexports::gbm::AsRaw;
use tracing::{info, warn};

const MIN_PAYLOAD: usize = 1024 * 1024;
const MAX_PAYLOAD: usize = 128 * 1024 * 1024;
// Reserve conservatively before allocation, then charge the actual exported
// FD extent. Larger/padded/unsupported allocations retain the CPU path.
const MAX_ALLOCATION: usize = 144 * 1024 * 1024;
const MAX_LIVE_BYTES: usize = 512 * 1024 * 1024;
const MAX_FREE_BYTES: usize = 128 * 1024 * 1024;
const MAX_FREE_BUFFERS: usize = 3;

#[link(name = "gbm")]
unsafe extern "C" {
    fn gbm_bo_map(
        bo: *mut c_void,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
        flags: u32,
        stride: *mut u32,
        data: *mut *mut c_void,
    ) -> *mut c_void;
    fn gbm_bo_unmap(bo: *mut c_void, data: *mut c_void);
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

struct ByteBudget {
    live: AtomicUsize,
    limit: usize,
}

impl ByteBudget {
    fn reserve(self: &Arc<Self>, bytes: usize) -> Option<BytePermit> {
        self.live
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |live| {
                live.checked_add(bytes).filter(|next| *next <= self.limit)
            })
            .ok()?;
        Some(BytePermit {
            budget: Arc::clone(self),
            bytes,
        })
    }
}

struct BytePermit {
    budget: Arc<ByteBudget>,
    bytes: usize,
}

impl BytePermit {
    fn charge_actual(&mut self, bytes: usize) -> io::Result<()> {
        if bytes == 0 || bytes > self.bytes {
            return Err(io::Error::other(
                "mapped SHM allocation exceeds reservation",
            ));
        }
        self.budget
            .live
            .fetch_sub(self.bytes - bytes, Ordering::Relaxed);
        self.bytes = bytes;
        Ok(())
    }
}

impl Drop for BytePermit {
    fn drop(&mut self) {
        let previous = self.budget.live.fetch_sub(self.bytes, Ordering::Relaxed);
        debug_assert!(previous >= self.bytes);
    }
}

struct Buffer {
    bo: GbmBuffer,
    dmabuf: Dmabuf,
    width: u32,
    height: u32,
    extent: usize,
    _permit: BytePermit,
}

struct State {
    device: GbmDevice<DrmDeviceFd>,
    free: Vec<Buffer>,
    free_bytes: usize,
}

pub(crate) struct MappedShmPool {
    state: Mutex<State>,
    budget: Arc<ByteBudget>,
    enabled: AtomicBool,
    first_publication: AtomicBool,
    first_reuse: AtomicBool,
    budget_warning: AtomicBool,
}

pub(crate) struct PendingMappedShm {
    buffer: Option<Buffer>,
    pool: Weak<MappedShmPool>,
}

pub(crate) struct MappedShmStorage {
    buffer: Option<Buffer>,
    pool: Weak<MappedShmPool>,
}

impl MappedShmPool {
    pub(crate) fn new(device: DrmDeviceFd) -> io::Result<Self> {
        let gbm = GbmDevice::new(device)?;
        Ok(Self {
            state: Mutex::new(State {
                device: gbm,
                free: Vec::with_capacity(MAX_FREE_BUFFERS),
                free_bytes: 0,
            }),
            budget: Arc::new(ByteBudget {
                live: AtomicUsize::new(0),
                limit: MAX_LIVE_BYTES,
            }),
            enabled: AtomicBool::new(false),
            first_publication: AtomicBool::new(false),
            first_reuse: AtomicBool::new(false),
            budget_warning: AtomicBool::new(false),
        })
    }

    pub(crate) fn enable(self: &Arc<Self>, renderer: &mut GlesRenderer) {
        let result = (|| -> io::Result<()> {
            let mut pending = self
                .allocate(64, 64)?
                .ok_or_else(|| io::Error::other("mapped SHM probe budget"))?;
            pending.write(|destination, stride| {
                // SAFETY: write validates the entire mapping's range.
                unsafe { destination.write_bytes(0, stride * 64) };
                true
            })?;
            let storage = pending.publish();
            renderer
                .import_dmabuf(storage.dmabuf(), None)
                .map_err(|error| io::Error::other(format!("mapped SHM EGL import: {error}")))?;
            Ok(())
        })();
        match result {
            Ok(()) => {
                self.enabled.store(true, Ordering::Release);
                info!(
                    max_live_bytes = MAX_LIVE_BYTES,
                    max_free_bytes = MAX_FREE_BYTES,
                    "mapped SHM snapshots available: ABGR8888 LINEAR CPU map and EGL import"
                );
            }
            Err(error) => {
                warn!(%error, "mapped SHM snapshots unavailable; retaining CPU snapshots")
            }
        }
    }

    pub(crate) fn acquire(self: &Arc<Self>, width: u32, height: u32) -> Option<PendingMappedShm> {
        let bytes = (width as usize)
            .checked_mul(height as usize)?
            .checked_mul(4)?;
        if !self.enabled.load(Ordering::Acquire) || !(MIN_PAYLOAD..=MAX_PAYLOAD).contains(&bytes) {
            return None;
        }
        match self.allocate(width, height) {
            Ok(buffer) => buffer,
            Err(error) => {
                self.disable(&error);
                None
            }
        }
    }

    pub(crate) fn disable(&self, error: &io::Error) {
        if self.enabled.swap(false, Ordering::AcqRel) {
            warn!(%error, "mapped SHM snapshot preparation failed; future snapshots use CPU storage");
        }
    }

    fn allocate(self: &Arc<Self>, width: u32, height: u32) -> io::Result<Option<PendingMappedShm>> {
        let mut state = lock(&self.state);
        let buffer = if let Some(index) = state
            .free
            .iter()
            .position(|b| b.width == width && b.height == height)
        {
            let buffer = state.free.swap_remove(index);
            state.free_bytes -= buffer.extent;
            if !self.first_reuse.swap(true, Ordering::Relaxed) {
                info!(
                    width,
                    height,
                    allocation_bytes = buffer.extent,
                    "mapped SHM allocation reused after final owner release"
                );
            }
            buffer
        } else {
            let Some(mut permit) = self.budget.reserve(MAX_ALLOCATION) else {
                if self.enabled.load(Ordering::Acquire)
                    && !self.budget_warning.swap(true, Ordering::Relaxed)
                {
                    warn!(
                        live_bytes = self.budget.live.load(Ordering::Relaxed),
                        "mapped SHM budget exhausted; using CPU snapshot for this update"
                    );
                }
                return Ok(None);
            };
            let raw = state.device.create_buffer_object::<()>(
                width,
                height,
                Fourcc::Abgr8888,
                GbmBufferFlags::LINEAR | GbmBufferFlags::RENDERING,
            )?;
            // Check the returned layout, then export that explicit modifier.
            // The allocator wrapper marks its legacy flag-based fallback as
            // implicit even when gbm_bo_get_modifier proves LINEAR.
            let bo = GbmBuffer::from_bo(raw, false);
            if bo.modifier() != Modifier::Linear || bo.plane_count() != 1 || bo.offset(0) != 0 {
                return Err(io::Error::other(
                    "mapped SHM requires one explicit LINEAR plane at offset zero",
                ));
            }
            let dmabuf = bo.export().map_err(io::Error::other)?;
            let handles = dmabuf.handles().collect::<Vec<_>>();
            if handles.len() != 1 {
                return Err(io::Error::other("mapped SHM unexpected FD count"));
            }
            let fd = handles[0];
            let stat = rustix::fs::fstat(fd)?;
            let extent = if stat.st_size > 0 {
                usize::try_from(stat.st_size).map_err(io::Error::other)?
            } else {
                let duplicate = fd.as_fd().try_clone_to_owned()?;
                // SAFETY: a live owned DMA-BUF duplicate; this only queries
                // allocation length, then restores its non-data offset.
                let end = unsafe { libc::lseek(duplicate.as_raw_fd(), 0, libc::SEEK_END) };
                let error = (end <= 0).then(io::Error::last_os_error);
                unsafe { libc::lseek(duplicate.as_raw_fd(), 0, libc::SEEK_SET) };
                if let Some(error) = error {
                    return Err(error);
                }
                usize::try_from(end).map_err(io::Error::other)?
            };
            permit.charge_actual(extent)?;
            Buffer {
                bo,
                dmabuf,
                width,
                height,
                extent,
                _permit: permit,
            }
        };
        Ok(Some(PendingMappedShm {
            buffer: Some(buffer),
            pool: Arc::downgrade(self),
        }))
    }

    fn recycle(&self, buffer: Buffer) {
        if !self.enabled.load(Ordering::Acquire) {
            return;
        }
        let mut state = lock(&self.state);
        if state.free.len() < MAX_FREE_BUFFERS
            && state
                .free_bytes
                .checked_add(buffer.extent)
                .is_some_and(|next| next <= MAX_FREE_BYTES)
        {
            state.free_bytes += buffer.extent;
            state.free.push(buffer);
        }
    }
}

impl PendingMappedShm {
    /// The caller owns an unpublished allocation; no GPU image can read it.
    pub(crate) fn write<T>(&mut self, copy: impl FnOnce(*mut u8, usize) -> T) -> io::Result<T> {
        let buffer = self.buffer.as_mut().expect("unpublished mapped SHM buffer");
        let mut stride = 0;
        let mut data = std::ptr::null_mut();
        let bo = buffer.bo.as_raw().cast_mut().cast::<c_void>();
        // WRITE only avoids requesting an unnecessary readback/staging copy.
        // SAFETY: exclusive unpublished BO, checked nonzero dimensions.
        let address = unsafe {
            gbm_bo_map(
                bo,
                0,
                0,
                buffer.width,
                buffer.height,
                2,
                &mut stride,
                &mut data,
            )
        };
        if address.is_null() {
            return Err(io::Error::last_os_error());
        }
        struct Mapping {
            bo: *mut c_void,
            data: *mut c_void,
        }
        impl Drop for Mapping {
            fn drop(&mut self) {
                // SAFETY: successful map, unmaps exactly once even on panic.
                unsafe { gbm_bo_unmap(self.bo, self.data) };
            }
        }
        let _mapping = Mapping { bo, data };
        let stride = stride as usize;
        let bytes = stride
            .checked_mul(buffer.height as usize)
            .ok_or_else(|| io::Error::other("mapped SHM stride overflow"))?;
        if stride < buffer.width as usize * 4 || bytes > buffer.extent {
            return Err(io::Error::other(
                "mapped SHM range exceeds its exported backing",
            ));
        }
        // Clear row padding before publication; client texels are written by
        // the guarded SHM copy below. No stale pool padding is exposed.
        for row in 0..buffer.height as usize {
            unsafe {
                address
                    .cast::<u8>()
                    .add(row * stride + buffer.width as usize * 4)
                    .write_bytes(0, stride - buffer.width as usize * 4)
            };
        }
        Ok(copy(address.cast(), stride))
    }

    pub(crate) fn publish(mut self) -> Arc<MappedShmStorage> {
        if let Some(pool) = self.pool.upgrade() {
            if pool.enabled.load(Ordering::Acquire)
                && !pool.first_publication.swap(true, Ordering::Relaxed)
            {
                let buffer = self.buffer.as_ref().expect("unpublished mapped storage");
                info!(
                    width = buffer.width,
                    height = buffer.height,
                    allocation_bytes = buffer.extent,
                    live_bytes = pool.budget.live.load(Ordering::Relaxed),
                    "mapped SHM snapshot published"
                );
            }
        }
        Arc::new(MappedShmStorage {
            buffer: self.buffer.take(),
            pool: self.pool.clone(),
        })
    }
}

impl MappedShmStorage {
    pub(crate) fn dmabuf(&self) -> &Dmabuf {
        &self.buffer.as_ref().expect("published storage").dmabuf
    }
}

impl Drop for PendingMappedShm {
    fn drop(&mut self) {
        if let (Some(buffer), Some(pool)) = (self.buffer.take(), self.pool.upgrade()) {
            pool.recycle(buffer)
        }
    }
}

impl Drop for MappedShmStorage {
    fn drop(&mut self) {
        if let (Some(buffer), Some(pool)) = (self.buffer.take(), self.pool.upgrade()) {
            pool.recycle(buffer)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn actual_extent_is_charged_until_the_last_owner_releases_it() {
        let budget = Arc::new(ByteBudget {
            live: AtomicUsize::new(0),
            limit: 512,
        });
        let mut permit = budget.reserve(144).unwrap();
        permit.charge_actual(33).unwrap();
        assert_eq!(budget.live.load(Ordering::Relaxed), 33);
        let owner = Arc::new(permit);
        let cached_import = Arc::clone(&owner);
        let reader_fence = Arc::clone(&owner);
        drop(owner);
        drop(cached_import);
        assert_eq!(budget.live.load(Ordering::Relaxed), 33);
        drop(reader_fence);
        assert_eq!(budget.live.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn reservations_reject_overflow_exhaustion_and_oversized_backings() {
        let budget = Arc::new(ByteBudget {
            live: AtomicUsize::new(0),
            limit: 512,
        });
        let mut first = budget.reserve(400).unwrap();
        assert!(budget.reserve(113).is_none());
        assert!(budget.reserve(usize::MAX).is_none());
        assert!(first.charge_actual(401).is_err());
        assert!(first.charge_actual(0).is_err());
        assert_eq!(budget.live.load(Ordering::Relaxed), 400);
        first.charge_actual(100).unwrap();
        let second = budget.reserve(412).unwrap();
        assert_eq!(budget.live.load(Ordering::Relaxed), 512);
        drop((first, second));
        assert_eq!(budget.live.load(Ordering::Relaxed), 0);
    }
}
