//! Native client render targets. Only final-owner release recycles a BO.
//!
//! EGL imports, Flutter images, and asynchronous reader fences all retain
//! storage. The exported allocation extent, including auxiliary planes, stays
//! charged while cached/free or externally owned. No CPU map or GL in Drop.

use smithay::backend::allocator::dmabuf::{AsDmabuf, Dmabuf};
use smithay::backend::allocator::gbm::{GbmBuffer, GbmBufferFlags, GbmDevice};
use smithay::backend::allocator::{Fourcc, Modifier};
use smithay::backend::drm::DrmDeviceFd;
use std::collections::HashSet;
use std::io;
use std::os::fd::{AsFd, AsRawFd};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, Weak};

const MAX_ALLOCATION: usize = 144 * 1024 * 1024;
const MAX_LIVE_BYTES: usize = 512 * 1024 * 1024;
const MAX_FREE_BYTES: usize = 128 * 1024 * 1024;
const MAX_FREE_BUFFERS: usize = 3;

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}
struct Budget {
    live: AtomicUsize,
}
struct Permit {
    budget: Arc<Budget>,
    bytes: usize,
}
impl Permit {
    fn reserve(budget: &Arc<Budget>) -> Option<Self> {
        budget
            .live
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |live| {
                live.checked_add(MAX_ALLOCATION)
                    .filter(|v| *v <= MAX_LIVE_BYTES)
            })
            .ok()?;
        Some(Self {
            budget: Arc::clone(budget),
            bytes: MAX_ALLOCATION,
        })
    }
    fn charge(&mut self, bytes: usize) -> io::Result<()> {
        if bytes == 0 || bytes > self.bytes {
            return Err(io::Error::other("native target extent exceeds reservation"));
        }
        self.budget
            .live
            .fetch_sub(self.bytes - bytes, Ordering::Relaxed);
        self.bytes = bytes;
        Ok(())
    }
}
impl Drop for Permit {
    fn drop(&mut self) {
        let previous = self.budget.live.fetch_sub(self.bytes, Ordering::Relaxed);
        debug_assert!(previous >= self.bytes);
    }
}
struct Buffer {
    _bo: GbmBuffer,
    dmabuf: Dmabuf,
    size: [u32; 2],
    bytes: usize,
    _permit: Permit,
}
struct State {
    device: GbmDevice<DrmDeviceFd>,
    modifiers: Vec<Modifier>,
    free: Vec<Buffer>,
    free_bytes: usize,
}
pub(super) struct NativeWindowPool {
    state: Mutex<State>,
    budget: Arc<Budget>,
    next_id: AtomicU64,
}
pub(super) struct NativeWindowStorage {
    buffer: Option<Buffer>,
    pool: Weak<NativeWindowPool>,
    pub(super) allocation_id: u64,
}
impl NativeWindowPool {
    pub(super) fn new(device: DrmDeviceFd, modifiers: Vec<Modifier>) -> io::Result<Arc<Self>> {
        Ok(Arc::new(Self {
            state: Mutex::new(State {
                device: GbmDevice::new(device)?,
                modifiers,
                free: Vec::new(),
                free_bytes: 0,
            }),
            budget: Arc::new(Budget {
                live: AtomicUsize::new(0),
            }),
            next_id: AtomicU64::new(0),
        }))
    }
    pub(super) fn acquire(
        self: &Arc<Self>,
        size: [u32; 2],
    ) -> io::Result<Option<Arc<NativeWindowStorage>>> {
        if size.contains(&0)
            || size.iter().any(|v| *v > 8192)
            || u64::from(size[0]) * u64::from(size[1]) > 32 * 1024 * 1024
        {
            return Err(io::Error::other("invalid native target size"));
        }
        let allocation_id = self
            .next_id
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |v| v.checked_add(1))
            .map_err(|_| io::Error::other("native target identity exhausted"))?
            + 1;
        let mut state = lock(&self.state);
        let buffer = if let Some(index) = state.free.iter().position(|b| b.size == size) {
            let buffer = state.free.swap_remove(index);
            state.free_bytes -= buffer.bytes;
            buffer
        } else {
            let permit = Permit::reserve(&self.budget);
            let mut permit = if let Some(permit) = permit {
                permit
            } else {
                state.free.clear();
                state.free_bytes = 0;
                let Some(permit) = Permit::reserve(&self.budget) else {
                    return Ok(None);
                };
                permit
            };
            // Let the active GPU choose its native renderable layout. In
            // particular, do not force the CPU-oriented LINEAR SHM layout.
            let preferred = state
                .modifiers
                .iter()
                .copied()
                .filter(|modifier| *modifier != Modifier::Linear && *modifier != Modifier::Invalid)
                .collect::<Vec<_>>();
            let raw = if preferred.is_empty() {
                state.device.create_buffer_object::<()>(
                    size[0],
                    size[1],
                    Fourcc::Abgr8888,
                    GbmBufferFlags::RENDERING,
                )?
            } else {
                state
                    .device
                    .create_buffer_object_with_modifiers::<()>(
                        size[0],
                        size[1],
                        Fourcc::Abgr8888,
                        preferred.iter().copied(),
                    )
                    .or_else(|_| {
                        state.device.create_buffer_object::<()>(
                            size[0],
                            size[1],
                            Fourcc::Abgr8888,
                            GbmBufferFlags::RENDERING,
                        )
                    })?
            };
            let bo = GbmBuffer::from_bo(raw, false);
            if bo.modifier() == Modifier::Invalid || bo.plane_count() == 0 || bo.plane_count() > 4 {
                return Err(io::Error::other(
                    "native target has no explicit bounded layout",
                ));
            }
            let dmabuf = bo.export().map_err(io::Error::other)?;
            let mut identities = HashSet::new();
            let mut bytes = 0usize;
            for ((fd, offset), stride) in
                dmabuf.handles().zip(dmabuf.offsets()).zip(dmabuf.strides())
            {
                let stat = rustix::fs::fstat(fd)?;
                let extent = if stat.st_size > 0 {
                    usize::try_from(stat.st_size).map_err(io::Error::other)?
                } else {
                    let duplicate = fd.as_fd().try_clone_to_owned()?;
                    // SAFETY: query the length of a live DMA-BUF, never its data.
                    let end = unsafe { libc::lseek(duplicate.as_raw_fd(), 0, libc::SEEK_END) };
                    let error = (end <= 0).then(io::Error::last_os_error);
                    unsafe { libc::lseek(duplicate.as_raw_fd(), 0, libc::SEEK_SET) };
                    if let Some(error) = error {
                        return Err(error);
                    }
                    usize::try_from(end).map_err(io::Error::other)?
                };
                if stride == 0 || offset as usize >= extent {
                    return Err(io::Error::other("native target plane outside allocation"));
                }
                if identities.insert((stat.st_dev, stat.st_ino)) {
                    bytes = bytes
                        .checked_add(extent)
                        .ok_or_else(|| io::Error::other("native allocation overflow"))?;
                }
            }
            permit.charge(bytes)?;
            Buffer {
                _bo: bo,
                dmabuf,
                size,
                bytes,
                _permit: permit,
            }
        };
        Ok(Some(Arc::new(NativeWindowStorage {
            buffer: Some(buffer),
            pool: Arc::downgrade(self),
            allocation_id,
        })))
    }
    pub(super) fn live_bytes(&self) -> usize {
        self.budget.live.load(Ordering::Relaxed)
    }
    pub(super) fn clear_free(&self) {
        let mut state = lock(&self.state);
        state.free.clear();
        state.free_bytes = 0;
    }
}
impl NativeWindowStorage {
    pub(super) fn dmabuf(&self) -> &Dmabuf {
        &self.buffer.as_ref().expect("native storage owns BO").dmabuf
    }
}
impl Drop for NativeWindowStorage {
    fn drop(&mut self) {
        let Some(buffer) = self.buffer.take() else {
            return;
        };
        let Some(pool) = self.pool.upgrade() else {
            return;
        };
        let mut state = lock(&pool.state);
        if state.free.len() < MAX_FREE_BUFFERS
            && state
                .free_bytes
                .checked_add(buffer.bytes)
                .is_some_and(|v| v <= MAX_FREE_BYTES)
        {
            state.free_bytes += buffer.bytes;
            state.free.push(buffer);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn allocation_budget_reserves_padding_and_releases_only_after_final_owner() {
        let budget = Arc::new(Budget {
            live: AtomicUsize::new(0),
        });
        let first = Permit::reserve(&budget).unwrap();
        let second = Permit::reserve(&budget).unwrap();
        let mut third = Permit::reserve(&budget).unwrap();
        assert!(Permit::reserve(&budget).is_none());
        third.charge(32 * 1024 * 1024).unwrap();
        let fourth = Permit::reserve(&budget).unwrap();
        let owner = Arc::new(third);
        let reader = Arc::clone(&owner);
        drop(owner);
        assert_eq!(
            budget.live.load(Ordering::Relaxed),
            3 * MAX_ALLOCATION + 32 * 1024 * 1024
        );
        drop(reader);
        assert_eq!(budget.live.load(Ordering::Relaxed), 3 * MAX_ALLOCATION);
        drop((first, second, fourth));
        assert_eq!(budget.live.load(Ordering::Relaxed), 0);
    }
    #[test]
    fn unmeasurable_or_oversized_export_cannot_escape_its_reservation() {
        let budget = Arc::new(Budget {
            live: AtomicUsize::new(0),
        });
        let mut permit = Permit::reserve(&budget).unwrap();
        assert!(permit.charge(0).is_err());
        assert!(permit.charge(MAX_ALLOCATION + 1).is_err());
        assert_eq!(budget.live.load(Ordering::Relaxed), MAX_ALLOCATION);
        drop(permit);
        assert_eq!(budget.live.load(Ordering::Relaxed), 0);
    }
}
