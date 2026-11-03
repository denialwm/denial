//! Destination-owned GPU transfer. No context or CPU fence wait reaches the raster thread.
//!
//! Plans try destination GLES source import first, with a lazy Vulkan bridge fallback.
//! A worker completes all source/bridge readers before
//! returning a native destination fence. KMS retirement remains the caller's job.
//! A failed completion is terminal: the caller must quarantine the pool slot too.

#[allow(dead_code)]
pub mod benchmark;
mod gl_timer;
mod worker_shutdown;
pub(super) use worker_shutdown::finish_process_workers;
pub mod vulkan;

use std::{
    collections::HashMap,
    ffi::{CStr, CString},
    os::fd::{AsRawFd, OwnedFd},
    panic::{AssertUnwindSafe, catch_unwind},
    rc::Rc,
    sync::{
        Arc, Weak,
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc::{self, Receiver, SyncSender},
    },
    thread,
    time::{Duration, Instant},
};

use smithay::backend::{
    allocator::{Buffer, Fourcc, Modifier, dmabuf::Dmabuf, format::FormatSet, gbm::GbmDevice},
    drm::DrmDeviceFd,
    egl::{EGLContext, EGLDisplay, fence::EGLFence, ffi::egl, get_proc_address},
    renderer::gles::ffi as gl,
};
use vulkan::{TransferPair, VulkanTransfer};

const QUEUE_DEPTH: usize = MAX_TARGETS;
const MAX_TARGETS: usize = 64;
const COMPLETION_TIMEOUT: Duration = Duration::from_secs(1);
const CONTROL_TIMEOUT: Duration = Duration::from_secs(10);
type Result<T> = std::result::Result<T, String>;
// Wall-time stage splits: waits include GPU execution and wakeup latency.
#[derive(Default)]
pub(super) struct Timings {
    queue_us: f64,
    source_wait_us: f64,
    vk_record_us: f64,
    vk_submit_us: f64,
    vk_wait_us: f64,
    gl_draw_us: f64,
    gl_wait_us: f64,
    vk_gpu_us: Option<f64>,
    gl_gpu_us: Option<f64>,
}
fn micros(start: Instant) -> f64 {
    start.elapsed().as_secs_f64() * 1e6
}

type Completion = Box<dyn FnOnce(Result<OwnedFd>) + Send>;

pub struct TransferDevice {
    jobs: SyncSender<Command>,
    render_formats: FormatSet,
    texture_formats: FormatSet,
    healthy: Arc<AtomicBool>,
    next_id: AtomicU64,
}

pub struct TransferTarget {
    device: Arc<TransferDevice>,
    id: u64,
    // The worker and queued commands retain this lease until both readers finish.
    lease: Arc<Lease>,
    alive: Arc<()>,
}

struct Lease {
    source: Dmabuf,
    bridge: Option<Dmabuf>,
    scanout: Dmabuf,
    pending: AtomicBool,
}

enum Command {
    Modifiers(Fourcc, u32, u32, SyncSender<Vec<Modifier>>),
    Prepare(u64, Arc<Lease>, Weak<()>, SyncSender<Result<()>>),
    Submit {
        id: u64,
        lease: Arc<Lease>,
        _alive: Arc<()>,
        source_fence: OwnedFd,
        queued_at: Option<Instant>,
        callback: Completion,
    },
}

impl TransferDevice {
    pub fn new(source_fd: DrmDeviceFd, destination_fd: DrmDeviceFd) -> Result<Arc<Self>> {
        Self::new_with_direct_rejection(source_fd, destination_fd, false)
    }

    // Fault injection is private to the offscreen harness; normal sessions always probe.
    fn new_with_direct_rejection(
        source_fd: DrmDeviceFd,
        destination_fd: DrmDeviceFd,
        reject_direct: bool,
    ) -> Result<Arc<Self>> {
        let (jobs, receiver) = mpsc::sync_channel(QUEUE_DEPTH);
        let (ready, initialized) = mpsc::sync_channel(1);
        let healthy = Arc::new(AtomicBool::new(true));
        let worker_health = healthy.clone();
        // All device/context state is constructed, used and destroyed on this thread.
        // Dropping the last sender lets it drain accepted jobs; no event/raster
        // thread joins it or waits for GPU work during plan destruction.
        let worker = thread::Builder::new()
            .name("denial-gpu-transfer".into())
            .spawn(move || {
                crate::cpu_scheduling::normalize_current_worker("gpu-transfer");
                let destination = match Destination::new(destination_fd) {
                    Ok(destination) => destination,
                    Err(error) => {
                        let _ = ready.send(Err(error));
                        return;
                    }
                };
                if ready
                    .send(Ok((
                        destination.display.dmabuf_render_formats().clone(),
                        destination.display.dmabuf_texture_formats().clone(),
                    )))
                    .is_err()
                {
                    return;
                }
                let mut worker = Worker {
                    destination,
                    vulkan: None,
                    _source_fd: source_fd,
                    reject_direct,
                    targets: HashMap::new(),
                    healthy: worker_health,
                    uncertain: false,
                    retained: Vec::new(),
                    first_completed: false,
                };
                if catch_unwind(AssertUnwindSafe(|| worker.run(&receiver))).is_err() {
                    worker.healthy.store(false, Ordering::Release);
                    worker.uncertain = true;
                    tracing::error!("GPU transfer worker panicked; quarantining device leases");
                    // Accepted jobs may still have active producers. Keep their
                    // storage and give their brokers a terminal completion too.
                    for command in receiver.try_iter() {
                        if let Command::Submit {
                            lease, callback, ..
                        } = command
                        {
                            worker.retained.push(lease);
                            let _ = catch_unwind(AssertUnwindSafe(|| {
                                callback(Err("GPU transfer worker panicked".into()));
                            }));
                        }
                    }
                }
                if worker.uncertain {
                    // Completion is unknown. Neither device teardown nor pool destruction
                    // is permission to free/reuse storage still touched by a GPU. Keep
                    // the complete context/import graph alive until process exit.
                    tracing::error!(
                        "GPU transfer completion uncertain; retaining device and buffer leases"
                    );
                    std::mem::forget(worker);
                }
            })
            .map_err(|error| format!("spawn destination transfer worker: {error}"))?;
        worker_shutdown::register(worker);
        let (render_formats, texture_formats) = initialized
            .recv_timeout(CONTROL_TIMEOUT)
            .map_err(|error| format!("initialize destination transfer worker: {error}"))??;
        Ok(Arc::new(Self {
            jobs,
            render_formats,
            texture_formats,
            healthy,
            next_id: AtomicU64::new(1),
        }))
    }

    pub fn render_formats(&self) -> &FormatSet {
        &self.render_formats
    }

    pub fn direct_source_modifiers(&self, fourcc: Fourcc) -> Vec<Modifier> {
        self.texture_formats
            .iter()
            .filter(|format| format.code == fourcc)
            .map(|format| format.modifier)
            .collect()
    }

    /// Vulkan candidates are queried only after direct-import candidates fail.
    pub fn source_modifiers(&self, fourcc: Fourcc, width: u32, height: u32) -> Vec<Modifier> {
        if !self.healthy.load(Ordering::Acquire) {
            return Vec::new();
        }
        let (reply, result) = mpsc::sync_channel(1);
        if self
            .jobs
            .try_send(Command::Modifiers(fourcc, width, height, reply))
            .is_err()
        {
            return Vec::new();
        }
        result.recv_timeout(CONTROL_TIMEOUT).unwrap_or_default()
    }

    /// Probe a freshly allocated plan before any producer or KMS reader uses it.
    pub fn prepare(
        self: &Arc<Self>,
        source: Dmabuf,
        bridge: Option<Dmabuf>,
        scanout: Dmabuf,
    ) -> Result<Arc<TransferTarget>> {
        if !self.healthy.load(Ordering::Acquire) {
            return Err("GPU transfer route is poisoned".into());
        }
        validate_layouts(&source, bridge.as_ref(), &scanout)?;
        let lease = Arc::new(Lease {
            source,
            bridge,
            scanout,
            pending: AtomicBool::new(false),
        });
        let alive = Arc::new(());
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (reply, result) = mpsc::sync_channel(1);
        self.jobs
            .try_send(Command::Prepare(
                id,
                lease.clone(),
                Arc::downgrade(&alive),
                reply,
            ))
            .map_err(|error| format!("queue transfer preparation: {error}"))?;
        result
            .recv_timeout(CONTROL_TIMEOUT)
            .map_err(|error| format!("prepare transfer target: {error}"))??;
        Ok(Arc::new(TransferTarget {
            device: self.clone(),
            id,
            lease,
            alive,
        }))
    }
}

impl TransferTarget {
    /// Queue one full-frame transfer. Caller keeps the scanout unavailable until
    /// KMS retirement, and keeps the entire slot quarantined on any error.
    pub fn submit(&self, source_fence: OwnedFd, callback: Completion) -> Result<()> {
        if !self.device.healthy.load(Ordering::Acquire) {
            self.retain_rejected_producer();
            return Err("GPU transfer route is poisoned".into());
        }
        if self
            .lease
            .pending
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            self.retain_rejected_producer();
            return Err("GPU transfer target already in flight".into());
        }
        let job = Command::Submit {
            id: self.id,
            lease: self.lease.clone(),
            _alive: self.alive.clone(),
            source_fence,
            queued_at: crate::render_audit_enabled().then(Instant::now),
            callback,
        };
        if let Err(error) = self.device.jobs.try_send(job) {
            self.lease.pending.store(false, Ordering::Release);
            self.retain_rejected_producer();
            return Err(format!("queue GPU transfer: {error}"));
        }
        Ok(())
    }

    fn retain_rejected_producer(&self) {
        // Source work has already been issued when submit is called. A full or
        // disconnected queue cannot accept its fence for a completion wait.
        // Reject terminally and retain the fixed-sized plan lease until exit,
        // rather than letting teardown recycle pending producer storage.
        self.device.healthy.store(false, Ordering::Release);
        std::mem::forget(self.lease.clone());
    }
}

fn validate_layouts(source: &Dmabuf, bridge: Option<&Dmabuf>, scanout: &Dmabuf) -> Result<()> {
    let size = source.size();
    if size.w <= 0
        || size.h <= 0
        || bridge.is_some_and(|bridge| bridge.size() != size)
        || scanout.size() != size
    {
        return Err("transfer buffers must have equal, positive dimensions".into());
    }
    if bridge.is_some_and(|bridge| {
        source.format().code != bridge.format().code || bridge.format().modifier != Modifier::Linear
    }) {
        return Err("Vulkan bridge must be explicit LINEAR and use the source fourcc".into());
    }
    let backings = |buffer: &Dmabuf| -> Result<Vec<_>> {
        buffer
            .handles()
            .map(|fd| {
                rustix::fs::fstat(fd)
                    .map(|stat| (stat.st_dev, stat.st_ino))
                    .map_err(|error| format!("transfer DMA-BUF backing identity: {error}"))
            })
            .collect()
    };
    let source_backings = backings(source)?;
    let bridge_backings = bridge.map(backings).transpose()?.unwrap_or_default();
    let scanout_backings = backings(scanout)?;
    let overlaps =
        |left: &Vec<_>, right: &Vec<_>| left.iter().any(|identity| right.contains(identity));
    if overlaps(&source_backings, &bridge_backings)
        || overlaps(&source_backings, &scanout_backings)
        || overlaps(&bridge_backings, &scanout_backings)
    {
        return Err("transfer requires independently allocated source, bridge and scanout".into());
    }
    Ok(())
}

struct Worker {
    // Imported targets drop before the device/context/GBM ownership graph.
    targets: HashMap<u64, GpuTarget>,
    destination: Rc<Destination>,
    vulkan: Option<VulkanTransfer>,
    reject_direct: bool,
    _source_fd: DrmDeviceFd,
    healthy: Arc<AtomicBool>,
    uncertain: bool,
    retained: Vec<Arc<Lease>>,
    first_completed: bool,
}

impl Worker {
    fn run(&mut self, receiver: &Receiver<Command>) {
        while let Ok(command) = receiver.recv() {
            if !self.uncertain {
                self.targets
                    .retain(|_, target| target.alive.strong_count() > 0);
            }
            match command {
                Command::Modifiers(fourcc, width, height, reply) => {
                    let modifiers = if self.uncertain {
                        Vec::new()
                    } else {
                        match self.vulkan() {
                            Ok(vulkan) => vulkan.source_modifiers(fourcc, width, height),
                            Err(error) => {
                                tracing::warn!(%error, "Vulkan fallback capability query failed");
                                Vec::new()
                            }
                        }
                    };
                    let _ = reply.send(modifiers);
                }
                Command::Prepare(id, lease, alive, reply) => {
                    let result =
                        match catch_unwind(AssertUnwindSafe(|| self.prepare(id, lease, alive))) {
                            Ok(result) => result,
                            Err(_) => {
                                self.poison();
                                Err("GPU transfer preparation panicked".into())
                            }
                        };
                    let _ = reply.send(result);
                }
                Command::Submit {
                    id,
                    lease,
                    source_fence,
                    queued_at,
                    callback,
                    _alive,
                } => {
                    // Retain even a queued producer before entering potentially
                    // failing APIs. A panic must not drop its allocation lease.
                    self.retained.push(lease.clone());
                    let result = catch_unwind(AssertUnwindSafe(|| {
                        self.submit(id, &source_fence, queued_at)
                    }))
                    .unwrap_or_else(|_| Err("GPU transfer submission panicked".into()));
                    if result.is_err() {
                        self.poison();
                    }
                    if !self.uncertain {
                        self.retained.pop();
                    }
                    lease.pending.store(false, Ordering::Release);
                    if catch_unwind(AssertUnwindSafe(|| callback(result))).is_err() {
                        tracing::error!("GPU transfer completion callback panicked");
                    }
                }
            }
        }
    }

    fn poison(&mut self) {
        self.uncertain = true;
        self.healthy.store(false, Ordering::Release);
    }

    fn vulkan(&mut self) -> Result<&mut VulkanTransfer> {
        if self.vulkan.is_none() {
            self.vulkan = Some(VulkanTransfer::new(self._source_fd.as_raw_fd())?);
        }
        Ok(self.vulkan.as_mut().unwrap())
    }

    fn prepare(&mut self, id: u64, lease: Arc<Lease>, alive: Weak<()>) -> Result<()> {
        if self.uncertain {
            return Err("GPU transfer route is poisoned".into());
        }
        if self.targets.len() >= MAX_TARGETS {
            return Err("GPU transfer import pool is full".into());
        }
        let destination = self.destination.clone();
        let reject_direct = self.reject_direct;
        let target = direct_then_bridge(
            || {
                if reject_direct {
                    return Err("offscreen test rejected direct destination import".into());
                }
                GpuTarget::new(destination.clone(), None, lease.clone(), alive.clone())
            },
            |direct_error| {
                let bridge = lease
                    .bridge
                    .as_ref()
                    .ok_or_else(|| format!("direct destination import rejected: {direct_error}"))?;
                tracing::info!(%direct_error, "direct destination import rejected; trying Vulkan bridge");
                let pair = self.vulkan()?.import_pair(&lease.source, bridge)?;
                GpuTarget::new(
                    destination.clone(),
                    Some(pair),
                    lease.clone(),
                    alive.clone(),
                )
            },
        )?;
        tracing::info!(
            target_id = id,
            direct_source = target.pair.is_none(),
            "destination import route prepared"
        );
        // Fresh plan storage has no producer or KMS reader. Probe the actual
        // sized imports, copy, FBO draw, native-fence export and completion.
        self.targets.insert(id, target);
        let result = self.copy_and_draw(id).map(drop);
        if result.is_err() {
            self.poison();
        }
        result
    }

    fn submit(
        &mut self,
        id: u64,
        source_fence: &OwnedFd,
        queued_at: Option<Instant>,
    ) -> Result<OwnedFd> {
        if self.uncertain {
            return Err("GPU transfer route is poisoned".into());
        }
        let mut timing = queued_at.map(|queued| Timings {
            queue_us: micros(queued),
            ..Default::default()
        });
        let start = timing.as_ref().map(|_| Instant::now());
        wait_source(source_fence, COMPLETION_TIMEOUT)?;
        if let (Some(timing), Some(start)) = (&mut timing, start) {
            timing.source_wait_us = micros(start);
        }
        let native = self.copy_and_draw_timed(id, timing.as_mut())?;
        if let Some(t) = timing {
            tracing::info!(
                target_id = id,
                queue_us = t.queue_us,
                source_wait_us = t.source_wait_us,
                vk_record_us = t.vk_record_us,
                vk_submit_us = t.vk_submit_us,
                vk_wait_us = t.vk_wait_us,
                gl_draw_us = t.gl_draw_us,
                gl_wait_us = t.gl_wait_us,
                vk_gpu_us = ?t.vk_gpu_us,
                gl_gpu_us = ?t.gl_gpu_us,
                total_us = queued_at.map(micros).unwrap_or_default(),
                "GPU transfer stage audit"
            );
        }
        if !self.first_completed {
            let size = self.targets[&id].lease.scanout.size();
            tracing::info!(
                target = id,
                width = size.w,
                height = size.h,
                final_fence_fd = native.as_raw_fd(),
                direct_source = self.targets[&id].pair.is_none(),
                "first destination GLES scanout transfer completed; final writer fence signaled"
            );
            self.first_completed = true;
        }
        Ok(native)
    }

    fn copy_and_draw(&mut self, id: u64) -> Result<OwnedFd> {
        self.copy_and_draw_timed(id, None)
    }

    fn copy_and_draw_timed(
        &mut self,
        id: u64,
        mut timing: Option<&mut Timings>,
    ) -> Result<OwnedFd> {
        let target = self
            .targets
            .get(&id)
            .ok_or("GPU transfer target was retired")?;
        if let Some(pair) = &target.pair {
            self.vulkan
                .as_mut()
                .ok_or("Vulkan bridge device missing")?
                .copy_timed(pair, timing.as_deref_mut())
                .map_err(|error| format!("Vulkan bridge copy: {error}"))?;
        }
        target.draw_timed(timing)
    }
}

// EGL's import advertisement is not GBM's allocation advertisement. Start
// direct probing with native GBM storage and portable LINEAR, not arbitrary
// import-only modifiers (some drivers assert instead of rejecting allocation).
// Vulkan fallback candidates have the additional real Vulkan layout negotiation.
pub fn source_allocation_candidates(
    modifiers: &[Modifier],
    use_bridge: bool,
) -> Vec<Option<Modifier>> {
    if use_bridge {
        modifiers
            .iter()
            .copied()
            .filter(|modifier| *modifier != Modifier::Invalid)
            .map(Some)
            .chain(std::iter::once(None))
            .collect()
    } else {
        std::iter::once(None)
            .chain(
                modifiers
                    .contains(&Modifier::Linear)
                    .then_some(Some(Modifier::Linear)),
            )
            .collect()
    }
}

// Import failure is recoverable before submitting any buffer work. A completion
// failure is not: the caller must poison/quarantine instead of changing routes.
fn direct_then_bridge<T>(
    direct: impl FnOnce() -> Result<T>,
    bridge: impl FnOnce(String) -> Result<T>,
) -> Result<T> {
    match direct() {
        Ok(target) => Ok(target),
        Err(direct_error) => bridge(direct_error.clone()).map_err(|bridge_error| {
            format!("direct import: {direct_error}; Vulkan fallback: {bridge_error}")
        }),
    }
}

fn wait_source(fd: &OwnedFd, timeout: Duration) -> Result<()> {
    let started = Instant::now();
    loop {
        let remaining = timeout.saturating_sub(started.elapsed());
        if remaining.is_zero() {
            return Err("source native fence timed out".into());
        }
        let mut pollfd = libc::pollfd {
            fd: fd.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        let milliseconds = remaining.as_millis().max(1).min(i32::MAX as u128) as i32;
        // SAFETY: one initialized pollfd is borrowed for the duration of poll.
        let result = unsafe { libc::poll(&mut pollfd, 1, milliseconds) };
        if result < 0 {
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Err(format!("poll source native fence: {error}"));
        }
        if result == 0 {
            continue;
        }
        if pollfd.revents & (libc::POLLERR | libc::POLLNVAL | libc::POLLHUP) != 0 {
            return Err(format!(
                "source native fence failed (poll events {:#x})",
                pollfd.revents
            ));
        }
        if pollfd.revents & libc::POLLIN != 0 {
            return Ok(());
        }
    }
}

// Raw GLES avoids Renderer::finish's glFinish fallback when fence creation
// fails. Every completion wait in this route has an explicit finite deadline.
struct Destination {
    timer: Option<gl_timer::GlTimer>,
    gl: gl::Gles2,
    program: u32,
    vao: u32,
    context: EGLContext,
    display: EGLDisplay,
    _gbm: GbmDevice<DrmDeviceFd>,
}

impl Destination {
    fn new(fd: DrmDeviceFd) -> Result<Rc<Self>> {
        let destination_dev = fd
            .dev_id()
            .map_err(|error| format!("destination DRM identity: {error}"))?;
        let destination_fd = fd.as_raw_fd();
        let destination_path = std::fs::read_link(format!("/proc/self/fd/{destination_fd}"))
            .map(|path| path.display().to_string())
            .unwrap_or_default();
        let gbm = GbmDevice::new(fd).map_err(|error| format!("destination GBM: {error}"))?;
        // SAFETY: GBM is retained after display/context destruction.
        let display = unsafe { EGLDisplay::new(gbm.clone()) }
            .map_err(|error| format!("destination EGL: {error}"))?;
        let context = crate::egl_context::create_render_context(&display)
            .map_err(|error| error.to_string())?;
        // SAFETY: this context is created and remains current on its owning worker only.
        unsafe { context.make_current() }
            .map_err(|error| format!("destination context: {error}"))?;
        // SAFETY: EGL loader is initialized and each symbol name is a valid string.
        let gl = gl::Gles2::load_with(|name| unsafe { get_proc_address(name) });
        if !gl.EGLImageTargetTexture2DOES.is_loaded() || !gl.GenVertexArrays.is_loaded() {
            return Err("destination requires GLES3 and EGL image texture import".into());
        }
        // SAFETY: EGL/GL strings are driver-owned NUL-terminated strings;
        // these core queries run with their display/context alive and current.
        let (egl_vendor, gl_vendor, gl_renderer) = unsafe {
            let string = |ptr: *const std::ffi::c_char| {
                if ptr.is_null() {
                    String::new()
                } else {
                    CStr::from_ptr(ptr).to_string_lossy().into_owned()
                }
            };
            (
                string(egl::QueryString(
                    **display.get_display_handle(),
                    egl::VENDOR as i32,
                )),
                string(gl.GetString(gl::VENDOR).cast()),
                string(gl.GetString(gl::RENDERER).cast()),
            )
        };
        tracing::info!(destination_fd, destination_dev, destination_path,
            %egl_vendor, %gl_vendor, %gl_renderer,
            "GPU transfer destination context bound to DRM device");
        let mut destination = Self {
            timer: crate::render_audit_enabled()
                .then(|| gl_timer::GlTimer::load(&gl))
                .flatten(),
            gl,
            program: 0,
            vao: 0,
            context,
            display,
            _gbm: gbm,
        };
        let probe = EGLFence::create(&destination.display)
            .map_err(|error| format!("destination fence probe: {error}"))?;
        if !probe.is_native() {
            return Err("destination cannot export EGL native fences".into());
        }
        // SAFETY: the owning worker has this destination context current.
        unsafe {
            destination.gl.Flush();
        }
        let _native = probe
            .export()
            .map_err(|error| format!("destination native-fence export probe: {error}"))?;
        if !probe
            .client_wait(Some(COMPLETION_TIMEOUT), false)
            .map_err(|error| error.to_string())?
        {
            // No buffer commands have been submitted by this empty-context probe.
            return Err("destination native-fence probe timed out".into());
        }
        destination.program = compile_program(&destination.gl, false)?;
        // SAFETY: the owning context is current and vao is a writable GLuint.
        unsafe {
            destination.gl.GenVertexArrays(1, &mut destination.vao);
        }
        check_gl(&destination.gl, "destination shader/VAO")?;
        Ok(Rc::new(destination))
    }
}

impl Drop for Destination {
    fn drop(&mut self) {
        drop(self.timer.take());
        // SAFETY: all destruction occurs on the owning worker, with its context current.
        unsafe {
            if self.program != 0 {
                self.gl.DeleteProgram(self.program);
            }
            if self.vao != 0 {
                self.gl.DeleteVertexArrays(1, &self.vao);
            }
        }
        let _ = self.context.unbind();
    }
}

struct ImageTexture {
    destination: Rc<Destination>,
    texture: u32,
    image: egl::types::EGLImage,
    texture_target: u32,
}

impl ImageTexture {
    fn new(destination: Rc<Destination>, dmabuf: &Dmabuf, external: bool) -> Result<Self> {
        let image = destination
            .display
            .create_image_from_dmabuf(dmabuf)
            .map_err(|error| format!("destination DMA-BUF image import: {error}"))?;
        let texture_target = if external {
            gl::TEXTURE_EXTERNAL_OES
        } else {
            gl::TEXTURE_2D
        };
        let mut imported = Self {
            destination,
            texture: 0,
            image,
            texture_target,
        };
        let gl = &imported.destination.gl;
        // SAFETY: the image belongs to this current context's display; all GL
        // parameters are valid and texture is a writable owned GLuint.
        unsafe {
            gl.GenTextures(1, &mut imported.texture);
            gl.BindTexture(texture_target, imported.texture);
            gl.TexParameteri(texture_target, gl::TEXTURE_MIN_FILTER, gl::NEAREST as i32);
            gl.TexParameteri(texture_target, gl::TEXTURE_MAG_FILTER, gl::NEAREST as i32);
            gl.TexParameteri(texture_target, gl::TEXTURE_WRAP_S, gl::CLAMP_TO_EDGE as i32);
            gl.TexParameteri(texture_target, gl::TEXTURE_WRAP_T, gl::CLAMP_TO_EDGE as i32);
            gl.EGLImageTargetTexture2DOES(texture_target, image.cast());
            gl.BindTexture(texture_target, 0);
        }
        check_gl(gl, "destination DMA-BUF texture import")?;
        Ok(imported)
    }
}

impl Drop for ImageTexture {
    fn drop(&mut self) {
        // SAFETY: imports are destroyed on the worker after completed reads,
        // before their display/context and DMA-BUF lease are released.
        unsafe {
            self.destination.gl.DeleteTextures(1, &self.texture);
            egl::DestroyImageKHR(**self.destination.display.get_display_handle(), self.image);
        }
    }
}

struct GpuTarget {
    framebuffer: u32,
    program: u32,
    bridge: ImageTexture,
    _scanout: ImageTexture,
    pair: Option<TransferPair>,
    lease: Arc<Lease>,
    alive: Weak<()>,
}

impl GpuTarget {
    fn new(
        destination: Rc<Destination>,
        pair: Option<TransferPair>,
        lease: Arc<Lease>,
        alive: Weak<()>,
    ) -> Result<Self> {
        if !destination
            .display
            .dmabuf_render_formats()
            .contains(&lease.scanout.format())
        {
            return Err("destination EGL cannot render the returned scanout layout".into());
        }
        let sampled = if pair.is_none() {
            &lease.source
        } else {
            lease
                .bridge
                .as_ref()
                .ok_or("Vulkan route requires bridge storage")?
        };
        if !destination
            .display
            .dmabuf_texture_formats()
            .contains(&sampled.format())
        {
            return Err("destination EGL cannot sample the selected source layout".into());
        }
        let external = !destination
            .display
            .dmabuf_render_formats()
            .contains(&sampled.format());
        let bridge = ImageTexture::new(destination.clone(), sampled, external)?;
        let scanout = ImageTexture::new(destination.clone(), &lease.scanout, false)?;
        let program = if external {
            compile_program(&destination.gl, true)?
        } else {
            destination.program
        };
        let mut target = Self {
            framebuffer: 0,
            program,
            bridge,
            _scanout: scanout,
            pair,
            lease,
            alive,
        };
        // SAFETY: the current worker context owns both the allocated FBO and
        // imported 2D scanout texture; the status query verifies completeness.
        unsafe {
            destination.gl.GenFramebuffers(1, &mut target.framebuffer);
            destination
                .gl
                .BindFramebuffer(gl::FRAMEBUFFER, target.framebuffer);
            destination.gl.FramebufferTexture2D(
                gl::FRAMEBUFFER,
                gl::COLOR_ATTACHMENT0,
                gl::TEXTURE_2D,
                target._scanout.texture,
                0,
            );
            let status = destination.gl.CheckFramebufferStatus(gl::FRAMEBUFFER);
            destination.gl.BindFramebuffer(gl::FRAMEBUFFER, 0);
            if status != gl::FRAMEBUFFER_COMPLETE {
                return Err(format!("destination framebuffer incomplete: {status:#x}"));
            }
        }
        check_gl(&destination.gl, "destination framebuffer")?;
        Ok(target)
    }

    fn draw_timed(&self, mut timing: Option<&mut Timings>) -> Result<OwnedFd> {
        let start = timing.as_ref().map(|_| Instant::now());
        let destination = &self.bridge.destination;
        let gl = &destination.gl;
        let size = self.lease.scanout.size();
        let timer = timing.as_ref().and(destination.timer.as_ref());
        if let Some(timer) = timer {
            timer.begin(gl);
        }
        // SAFETY: this worker owns the current context, shader, VAO, complete
        // FBO and imported bridge. Both allocations stay leased through completion.
        unsafe {
            gl.BindFramebuffer(gl::FRAMEBUFFER, self.framebuffer);
            gl.Viewport(0, 0, size.w, size.h);
            gl.Disable(gl::BLEND);
            gl.Disable(gl::DITHER);
            gl.Disable(gl::SCISSOR_TEST);
            gl.Disable(gl::DEPTH_TEST);
            gl.Disable(gl::STENCIL_TEST);
            gl.UseProgram(self.program);
            gl.BindVertexArray(destination.vao);
            gl.ActiveTexture(gl::TEXTURE0);
            gl.BindTexture(self.bridge.texture_target, self.bridge.texture);
            gl.DrawArrays(gl::TRIANGLES, 0, 3);
            gl.BindTexture(self.bridge.texture_target, 0);
            gl.BindVertexArray(0);
            gl.BindFramebuffer(gl::FRAMEBUFFER, 0);
        }
        if let Some(timer) = timer {
            timer.end();
        }
        check_gl(gl, "destination bridge sampling draw")?;
        let fence = EGLFence::create(&destination.display)
            .map_err(|error| format!("destination draw fence: {error}"))?;
        // SAFETY: flush publishes preceding commands on this current context.
        unsafe {
            gl.Flush();
        }
        let native = fence
            .export()
            .map_err(|error| format!("destination final fence export: {error}"))?;
        if let (Some(timing), Some(start)) = (&mut timing, start) {
            timing.gl_draw_us = micros(start);
        }
        let wait_start = timing.as_ref().map(|_| Instant::now());
        if !fence
            .client_wait(Some(COMPLETION_TIMEOUT), false)
            .map_err(|error| format!("destination draw completion: {error}"))?
        {
            return Err("destination GLES reader completion timed out".into());
        }
        if let (Some(timing), Some(start)) = (&mut timing, wait_start) {
            timing.gl_wait_us = micros(start);
            timing.gl_gpu_us = timer.and_then(|timer| timer.read(gl));
        }
        Ok(native)
    }
}

impl Drop for GpuTarget {
    fn drop(&mut self) {
        let destination = &self.bridge.destination;
        // SAFETY: the worker retires targets only after their GPU readers
        // completed; incomplete/failed setup has submitted no draw commands.
        unsafe {
            destination.gl.DeleteFramebuffers(1, &self.framebuffer);
            if self.program != destination.program {
                destination.gl.DeleteProgram(self.program);
            }
        }
    }
}

fn check_gl(gl: &gl::Gles2, stage: &str) -> Result<()> {
    // SAFETY: all callers run with the destination context current.
    let error = unsafe { gl.GetError() };
    if error == gl::NO_ERROR {
        Ok(())
    } else {
        // Failed import probes must not leave GL error flags for a fallback.
        for _ in 0..16 {
            if unsafe { gl.GetError() } == gl::NO_ERROR {
                break;
            }
        }
        Err(format!("{stage}: GL error {error:#x}"))
    }
}

fn compile_program(gl: &gl::Gles2, external: bool) -> Result<u32> {
    // Identical row orientation through both imports: this is a storage transfer,
    // not another output transform. The scene producer already applied that transform.
    let vertex = "#version 300 es\nprecision highp float; out vec2 uv; void main() { vec2 p=vec2(float((gl_VertexID<<1)&2), float(gl_VertexID&2)); uv=p; gl_Position=vec4(p*2.0-1.0,0.0,1.0); }";
    let fragment = if external {
        "#version 300 es\n#extension GL_OES_EGL_image_external_essl3 : require\nprecision highp float; uniform samplerExternalOES image; in vec2 uv; out vec4 color; void main(){color=texture(image,uv);}"
    } else {
        "#version 300 es\nprecision highp float; uniform sampler2D image; in vec2 uv; out vec4 color; void main(){color=texture(image,uv);}"
    };
    let vertex = compile_shader(gl, gl::VERTEX_SHADER, vertex)?;
    let fragment = match compile_shader(gl, gl::FRAGMENT_SHADER, fragment) {
        Ok(shader) => shader,
        Err(error) => {
            // SAFETY: vertex is a live shader created in this current context.
            unsafe {
                gl.DeleteShader(vertex);
            }
            return Err(error);
        }
    };
    // SAFETY: the destination context is current on the owning worker.
    let program = unsafe { gl.CreateProgram() };
    let mut linked = 0;
    // SAFETY: shaders/program belong to this current context, linked is
    // writable, and deleting attached shaders defers release until detach.
    unsafe {
        gl.AttachShader(program, vertex);
        gl.AttachShader(program, fragment);
        gl.LinkProgram(program);
        gl.GetProgramiv(program, gl::LINK_STATUS, &mut linked);
        gl.DeleteShader(vertex);
        gl.DeleteShader(fragment);
    }
    if linked == 0 {
        let mut log = [0u8; 1024];
        let mut length = 0;
        // SAFETY: log and length are writable with the supplied lengths;
        // program is an owned object which failed to link.
        unsafe {
            gl.GetProgramInfoLog(
                program,
                log.len() as i32,
                &mut length,
                log.as_mut_ptr().cast(),
            );
            gl.DeleteProgram(program);
        }
        return Err(format!(
            "destination shader link: {}",
            String::from_utf8_lossy(&log[..(length.max(0) as usize).min(log.len())])
        ));
    }
    // Newly linked sampler uniforms default to texture unit zero.
    Ok(program)
}

fn compile_shader(gl: &gl::Gles2, kind: u32, source: &str) -> Result<u32> {
    let source = CString::new(source).map_err(|error| error.to_string())?;
    // SAFETY: kind is a GLES vertex/fragment shader enum and context is current.
    let shader = unsafe { gl.CreateShader(kind) };
    let mut compiled = 0;
    // SAFETY: source is NUL-terminated and remains live for ShaderSource;
    // shader belongs to this current context and compiled is writable.
    unsafe {
        gl.ShaderSource(shader, 1, &source.as_ptr(), std::ptr::null());
        gl.CompileShader(shader);
        gl.GetShaderiv(shader, gl::COMPILE_STATUS, &mut compiled);
    }
    if compiled == 0 {
        let mut log = [0u8; 1024];
        let mut length = 0;
        // SAFETY: log and length are writable with the supplied lengths;
        // shader is an owned object which failed compilation.
        unsafe {
            gl.GetShaderInfoLog(
                shader,
                log.len() as i32,
                &mut length,
                log.as_mut_ptr().cast(),
            );
            gl.DeleteShader(shader);
        }
        return Err(format!(
            "destination shader compile: {}",
            String::from_utf8_lossy(&log[..(length.max(0) as usize).min(log.len())])
        ));
    }
    Ok(shader)
}

#[cfg(test)]
mod tests {
    use super::*;
    use smithay::backend::allocator::dmabuf::DmabufFlags;
    use std::os::fd::FromRawFd;

    fn pipe() -> (OwnedFd, OwnedFd) {
        let mut fds = [-1; 2];
        // SAFETY: pipe2 initializes the two-element writable descriptor array.
        assert_eq!(
            unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC | libc::O_NONBLOCK) },
            0
        );
        // SAFETY: successful pipe2 returned two distinct, owned descriptors.
        unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) }
    }

    // Metadata-only allocations; these tests never pass the pipe FD to a GPU.
    fn buffer(fourcc: Fourcc, modifier: Modifier, size: (i32, i32)) -> Dmabuf {
        let (read, _write) = pipe();
        let mut builder = Dmabuf::builder(size, fourcc, modifier, DmabufFlags::empty());
        assert!(builder.add_plane(read, 0, (size.0.max(1) as u32) * 4));
        builder.build().unwrap()
    }

    fn lease() -> Arc<Lease> {
        Arc::new(Lease {
            source: buffer(Fourcc::Abgr8888, Modifier::Linear, (16, 16)),
            bridge: Some(buffer(Fourcc::Abgr8888, Modifier::Linear, (16, 16))),
            scanout: buffer(Fourcc::Xrgb8888, Modifier::Linear, (16, 16)),
            pending: AtomicBool::new(false),
        })
    }

    #[test]
    fn direct_allocation_does_not_treat_import_only_modifiers_as_allocatable() {
        let modifiers = [Modifier::Invalid, Modifier::Linear, Modifier::from(0x1234)];
        assert_eq!(
            source_allocation_candidates(&modifiers, false),
            [None, Some(Modifier::Linear)]
        );
        assert_eq!(
            source_allocation_candidates(&modifiers, true),
            [Some(Modifier::Linear), Some(Modifier::from(0x1234)), None]
        );
    }

    #[test]
    fn successful_direct_import_never_initializes_vulkan() {
        assert_eq!(
            direct_then_bridge(|| Ok(7), |_| panic!("Vulkan called for direct success")),
            Ok(7)
        );
        let plan = lease();
        assert!(validate_layouts(&plan.source, None, &plan.scanout).is_ok());
        assert!(validate_layouts(&plan.source, None, &plan.source).is_err());
    }

    #[test]
    fn rejected_direct_import_attempts_vulkan_and_preserves_errors() {
        let order = std::cell::RefCell::new(Vec::new());
        let result = direct_then_bridge(
            || {
                order.borrow_mut().push("direct");
                Err("EGL rejected actual source layout".into())
            },
            |error| {
                assert!(error.contains("EGL rejected"));
                order.borrow_mut().push("Vulkan");
                Ok(9)
            },
        );
        assert_eq!(result, Ok(9));
        assert_eq!(*order.borrow(), ["direct", "Vulkan"]);
        let error = direct_then_bridge::<()>(
            || Err("direct reason".into()),
            |_| Err("bridge reason".into()),
        )
        .unwrap_err();
        assert!(error.contains("direct reason") && error.contains("bridge reason"));
    }

    #[test]
    fn layouts_reject_implicit_bridge_size_mismatch_and_alias() {
        let plan = lease();
        assert!(validate_layouts(&plan.source, plan.bridge.as_ref(), &plan.scanout).is_ok());
        let implicit = buffer(Fourcc::Abgr8888, Modifier::Invalid, (16, 16));
        assert!(validate_layouts(&plan.source, Some(&implicit), &plan.scanout).is_err());
        let wrong_size = buffer(Fourcc::Xrgb8888, Modifier::Linear, (8, 8));
        assert!(validate_layouts(&plan.source, plan.bridge.as_ref(), &wrong_size).is_err());
        assert!(validate_layouts(&plan.source, Some(&plan.source), &plan.scanout).is_err());
        // Distinct DMA-BUF wrappers around duplicate FDs still alias storage.
        let mut alias = Dmabuf::builder_from_buffer(&plan.source, DmabufFlags::empty());
        alias.add_plane(
            plan.source
                .handles()
                .next()
                .unwrap()
                .try_clone_to_owned()
                .unwrap(),
            0,
            64,
        );
        assert!(
            validate_layouts(&plan.source, Some(&alias.build().unwrap()), &plan.scanout).is_err()
        );
    }

    #[test]
    fn queued_job_pins_plan_until_consumed() {
        let (jobs, receiver) = mpsc::sync_channel(1);
        let device = Arc::new(TransferDevice {
            jobs,
            render_formats: FormatSet::default(),
            texture_formats: FormatSet::default(),
            healthy: Arc::new(AtomicBool::new(true)),
            next_id: AtomicU64::new(1),
        });
        let target = TransferTarget {
            device,
            id: 1,
            lease: lease(),
            alive: Arc::new(()),
        };
        let weak_plan = Arc::downgrade(&target.lease);
        let weak_alive = Arc::downgrade(&target.alive);
        let (fence, _write) = pipe();
        assert!(target.submit(fence, Box::new(|_| {})).is_ok());
        drop(target);
        assert!(weak_plan.upgrade().is_some());
        assert!(weak_alive.upgrade().is_some());
        drop(receiver.recv().unwrap());
        assert!(weak_plan.upgrade().is_none());
        assert!(weak_alive.upgrade().is_none());
    }

    #[test]
    fn full_queue_releases_pending_claim() {
        let (jobs, _receiver) = mpsc::sync_channel(1);
        let (reply, _result) = mpsc::sync_channel(1);
        assert!(
            jobs.try_send(Command::Modifiers(Fourcc::Abgr8888, 16, 16, reply))
                .is_ok()
        );
        let device = Arc::new(TransferDevice {
            jobs,
            render_formats: FormatSet::default(),
            texture_formats: FormatSet::default(),
            healthy: Arc::new(AtomicBool::new(true)),
            next_id: AtomicU64::new(1),
        });
        let target = TransferTarget {
            device,
            id: 1,
            lease: lease(),
            alive: Arc::new(()),
        };
        let (fence, _write) = pipe();
        assert!(target.submit(fence, Box::new(|_| {})).is_err());
        assert!(!target.lease.pending.load(Ordering::Acquire));
    }

    #[test]
    fn source_wait_has_finite_timeout() {
        let (read, _write) = pipe();
        let start = Instant::now();
        assert!(
            wait_source(&read, Duration::from_millis(5))
                .unwrap_err()
                .contains("timed out")
        );
        assert!(start.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn source_wait_accepts_readiness_and_rejects_hangup() {
        let (read, write) = pipe();
        // SAFETY: one readable byte is supplied to a live owned pipe writer.
        assert_eq!(
            unsafe { libc::write(write.as_raw_fd(), b"x".as_ptr().cast(), 1) },
            1
        );
        assert!(wait_source(&read, Duration::from_millis(5)).is_ok());
        let (read, write) = pipe();
        drop(write);
        assert!(
            wait_source(&read, Duration::from_millis(5))
                .unwrap_err()
                .contains("failed")
        );
    }
}
