//! One queue for the composer and the engine's Impeller Vulkan renderer.
//!
//! The engine renders on the composer's device and queue. Vulkan requires external synchronization of a queue, and
//! Impeller submits from the raster thread and from its IO workers. The
//! engine resolves every Vulkan procedure through `instance_proc`, which
//! hands it locked variants of the queue entry points; the composer takes
//! the same lock (`QUEUE`) around its own submissions and waits. Fence
//! waits and status queries need no lock.

use std::ffi::{CStr, c_char};
use std::sync::{Mutex, MutexGuard, PoisonError};

use ash::vk;

/// Held around every use of the shared queue.
static QUEUE: Mutex<()> = Mutex::new(());

/// The loader's entry points behind the locked ones. Device-level commands
/// resolved through the instance are loader trampolines: they dispatch on
/// their handle, so one set serves every device.
#[derive(Clone, Copy)]
struct Procs {
    get_instance_proc_addr: vk::PFN_vkGetInstanceProcAddr,
    get_device_proc_addr: vk::PFN_vkGetDeviceProcAddr,
    queue_submit: vk::PFN_vkQueueSubmit,
    queue_submit2: vk::PFN_vkQueueSubmit2,
    queue_wait_idle: vk::PFN_vkQueueWaitIdle,
    device_wait_idle: vk::PFN_vkDeviceWaitIdle,
}

static PROCS: Mutex<Option<Procs>> = Mutex::new(None);

pub(super) fn lock() -> MutexGuard<'static, ()> {
    QUEUE.lock().unwrap_or_else(PoisonError::into_inner)
}

fn procs() -> Option<Procs> {
    *PROCS.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Records the loader's entry points from a live instance. Called when the
/// composer's device is created for the engine.
pub(super) fn install(entry: &ash::Entry, instance: vk::Instance) -> Result<(), String> {
    let get_instance_proc_addr = entry.static_fn().get_instance_proc_addr;
    // SAFETY: resolution on a live instance with NUL-terminated names; each
    // pointer is transmuted to the signature its name defines.
    let resolve = |name: &CStr| unsafe { get_instance_proc_addr(instance, name.as_ptr()) };
    let missing = |name: &CStr| format!("Vulkan loader lacks {}", name.to_string_lossy());
    unsafe {
        let procs = Procs {
            get_instance_proc_addr,
            get_device_proc_addr: std::mem::transmute::<
                unsafe extern "system" fn(),
                vk::PFN_vkGetDeviceProcAddr,
            >(
                resolve(c"vkGetDeviceProcAddr").ok_or_else(|| missing(c"vkGetDeviceProcAddr"))?,
            ),
            queue_submit: std::mem::transmute::<unsafe extern "system" fn(), vk::PFN_vkQueueSubmit>(
                resolve(c"vkQueueSubmit").ok_or_else(|| missing(c"vkQueueSubmit"))?,
            ),
            queue_submit2: std::mem::transmute::<unsafe extern "system" fn(), vk::PFN_vkQueueSubmit2>(
                resolve(c"vkQueueSubmit2").ok_or_else(|| missing(c"vkQueueSubmit2"))?,
            ),
            queue_wait_idle: std::mem::transmute::<
                unsafe extern "system" fn(),
                vk::PFN_vkQueueWaitIdle,
            >(
                resolve(c"vkQueueWaitIdle").ok_or_else(|| missing(c"vkQueueWaitIdle"))?,
            ),
            device_wait_idle: std::mem::transmute::<
                unsafe extern "system" fn(),
                vk::PFN_vkDeviceWaitIdle,
            >(
                resolve(c"vkDeviceWaitIdle").ok_or_else(|| missing(c"vkDeviceWaitIdle"))?,
            ),
        };
        *PROCS.lock().unwrap_or_else(PoisonError::into_inner) = Some(procs);
    }
    Ok(())
}

/// The engine's `vkGetInstanceProcAddr`: the loader's procedure, or its
/// locked variant for the queue entry points.
///
/// # Safety
/// As `vkGetInstanceProcAddr`.
pub(in crate::flutter_runtime) unsafe extern "system" fn instance_proc(
    instance: vk::Instance,
    name: *const c_char,
) -> vk::PFN_vkVoidFunction {
    let procs = procs()?;
    if name.is_null() {
        return None;
    }
    // SAFETY: forwarded as received.
    let original = unsafe { (procs.get_instance_proc_addr)(instance, name) };
    // SAFETY: the caller passes a NUL-terminated name.
    intercept(unsafe { CStr::from_ptr(name) }, original)
}

unsafe extern "system" fn device_proc(
    device: vk::Device,
    name: *const c_char,
) -> vk::PFN_vkVoidFunction {
    let procs = procs()?;
    if name.is_null() {
        return None;
    }
    // SAFETY: forwarded as received.
    let original = unsafe { (procs.get_device_proc_addr)(device, name) };
    // SAFETY: the caller passes a NUL-terminated name.
    intercept(unsafe { CStr::from_ptr(name) }, original)
}

fn intercept(name: &CStr, original: vk::PFN_vkVoidFunction) -> vk::PFN_vkVoidFunction {
    // An entry point the driver does not have stays absent.
    original?;
    let function = match name.to_bytes() {
        b"vkGetInstanceProcAddr" => instance_proc as *const (),
        b"vkGetDeviceProcAddr" => device_proc as *const (),
        b"vkQueueSubmit" => submit as *const (),
        b"vkQueueSubmit2" | b"vkQueueSubmit2KHR" => submit2 as *const (),
        b"vkQueueWaitIdle" => queue_wait_idle as *const (),
        b"vkDeviceWaitIdle" => device_wait_idle as *const (),
        _ => return original,
    };
    // SAFETY: each function above has the exact system ABI of the procedure
    // its name defines; the caller restores that type.
    Some(unsafe { std::mem::transmute::<*const (), unsafe extern "system" fn()>(function) })
}

unsafe extern "system" fn submit(
    queue: vk::Queue,
    count: u32,
    submits: *const vk::SubmitInfo<'_>,
    fence: vk::Fence,
) -> vk::Result {
    let Some(procs) = procs() else {
        return vk::Result::ERROR_INITIALIZATION_FAILED;
    };
    let _queue = lock();
    // SAFETY: forwarded as received, with the queue externally synchronized.
    unsafe { (procs.queue_submit)(queue, count, submits, fence) }
}

unsafe extern "system" fn submit2(
    queue: vk::Queue,
    count: u32,
    submits: *const vk::SubmitInfo2<'_>,
    fence: vk::Fence,
) -> vk::Result {
    let Some(procs) = procs() else {
        return vk::Result::ERROR_INITIALIZATION_FAILED;
    };
    let _queue = lock();
    // SAFETY: as `submit`. vkQueueSubmit2KHR is the same command.
    unsafe { (procs.queue_submit2)(queue, count, submits, fence) }
}

unsafe extern "system" fn queue_wait_idle(queue: vk::Queue) -> vk::Result {
    let Some(procs) = procs() else {
        return vk::Result::ERROR_INITIALIZATION_FAILED;
    };
    let _queue = lock();
    // SAFETY: as `submit`.
    unsafe { (procs.queue_wait_idle)(queue) }
}

unsafe extern "system" fn device_wait_idle(device: vk::Device) -> vk::Result {
    let Some(procs) = procs() else {
        return vk::Result::ERROR_INITIALIZATION_FAILED;
    };
    // vkDeviceWaitIdle synchronizes every queue of the device.
    let _queue = lock();
    // SAFETY: as `submit`.
    unsafe { (procs.device_wait_idle)(device) }
}
