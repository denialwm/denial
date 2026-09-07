//! Optional urgency hints for an already exported GPU completion fence.

use std::os::fd::BorrowedFd;
use std::sync::atomic::{AtomicBool, Ordering};

use smithay::reexports::rustix::{io, ioctl, time};

#[repr(C)]
struct SyncSetDeadline {
    deadline_ns: u64,
    pad: u64,
}

const _: () = assert!(std::mem::size_of::<SyncSetDeadline>() == 16);

#[derive(Default)]
pub(crate) struct GpuDeadlineHints {
    unavailable: AtomicBool,
}

impl GpuDeadlineHints {
    /// Uses the frame's CLOCK_MONOTONIC target. Flutter omits targets which
    /// were already missed before rasterization; those frames need completion
    /// now. The hint neither waits on the fence nor changes governor settings.
    /// Unsupported kernels disable further attempts for this renderer only.
    pub(crate) fn set(&self, fence: BorrowedFd<'_>, target_ns: u64) -> io::Result<bool> {
        if self.unavailable.load(Ordering::Relaxed) {
            return Ok(false);
        }
        let deadline_ns = if target_ns != 0 {
            target_ns
        } else {
            let now = time::clock_gettime(time::ClockId::Monotonic);
            now.tv_sec as u64 * 1_000_000_000 + now.tv_nsec as u64
        };
        // Linux sync_file.h: _IOW('>', 5, struct sync_set_deadline).
        const REQUEST: ioctl::Opcode = ioctl::opcode::write::<SyncSetDeadline>(b'>', 5);
        // SAFETY: this exact C-layout UAPI struct has zero padding and the
        // borrowed descriptor remains valid for the synchronous ioctl call.
        let result = unsafe {
            ioctl::ioctl(
                fence,
                ioctl::Setter::<REQUEST, _>::new(SyncSetDeadline {
                    deadline_ns,
                    pad: 0,
                }),
            )
        };
        if let Err(error) = result {
            if error != io::Errno::INTR {
                self.unavailable.store(true, Ordering::Relaxed);
            }
            return Err(error);
        }
        Ok(true)
    }
}
