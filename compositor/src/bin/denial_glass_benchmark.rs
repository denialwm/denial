//! Offscreen glass profiling using Denial's own Flutter embedder.
//!
//! Opens only a DRM render node. It cannot acquire DRM master, change scanout,
//! create a Wayland window, or restart the compositor being investigated.
#![deny(unsafe_op_in_unsafe_fn)]
#![deny(clippy::undocumented_unsafe_blocks)]
#![recursion_limit = "256"]

use std::error::Error;
use std::ffi::{CStr, c_char, c_void};
use std::fs::{self, OpenOptions};
use std::mem;
use std::ops::Deref;
use std::os::fd::AsFd;
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread::{self, ThreadId};
use std::time::{Duration, Instant};

use denial_core::topology::{OutputId, PixelSize, RenderViewId};
use denial_flutter_engine::{
    BackingStoreRequest, CompositorBackingStore, DartRuntimeMode, EngineEvent, EngineHost,
    EngineLibrary, EngineProject, OpenGlHandler, PresentFrame, PresentView, RenderOutput,
    RenderOutputTransform, RendererBackend, ScheduledTask, sys,
};
use sha2::{Digest, Sha256};
use smithay::backend::allocator::dmabuf::{AsDmabuf, Dmabuf};
use smithay::backend::allocator::gbm::{GbmAllocator, GbmBuffer, GbmBufferFlags, GbmDevice};
use smithay::backend::allocator::{Allocator, Buffer as AllocatorBuffer, Fourcc, Modifier};
use smithay::backend::egl::context::{GlAttributes, PixelFormatRequirements};
use smithay::backend::egl::display::EGLDisplayHandle;
use smithay::backend::egl::fence::EGLFence;
use smithay::backend::egl::{self, EGLContext, EGLDisplay};
use smithay::backend::egl::{ffi as egl_ffi, get_proc_address};
use smithay::backend::renderer::gles::ffi as gl;
use smithay::reexports::rustix::time::{ClockId, clock_gettime};
use tracing::error;
#[allow(dead_code)]
#[path = "deniald/egl_context.rs"]
mod desktop_egl;
use desktop_egl as egl_context;
#[allow(dead_code)]
#[path = "deniald/flutter_runtime/damage.rs"]
mod desktop_damage;
#[allow(dead_code)]
#[path = "deniald/flutter_runtime/renderer/gl.rs"]
mod desktop_gl;
#[path = "deniald/flutter_runtime/renderer/handler/gpu_deadline.rs"]
mod gpu_deadline;

fn clock_micros(clock: ClockId) -> u64 {
    let time = clock_gettime(clock);
    time.tv_sec as u64 * 1_000_000 + time.tv_nsec as u64 / 1000
}

type FenceStepSample = (u64, [(u64, u64); 9]);

static PRIORITY_FAILURES: AtomicI32 = AtomicI32::new(0);

unsafe extern "C" fn set_worker_thread_priority(priority: sys::FlutterThreadPriority) {
    let (policy, sched_priority) = match priority {
        sys::FlutterThreadPriority_kDisplay | sys::FlutterThreadPriority_kRaster => {
            (libc::SCHED_RR | libc::SCHED_RESET_ON_FORK, 1)
        }
        sys::FlutterThreadPriority_kBackground | sys::FlutterThreadPriority_kNormal => {
            (libc::SCHED_OTHER | libc::SCHED_RESET_ON_FORK, 0)
        }
        _ => return,
    };
    let param = libc::sched_param { sched_priority };
    // SAFETY: pid zero changes only the calling worker thread. The callback
    // uses fixed Linux scheduler values and never touches the parent process.
    if unsafe { libc::syscall(libc::SYS_sched_setscheduler, 0, policy, &param) } != 0 {
        PRIORITY_FAILURES.fetch_add(1, Ordering::Relaxed);
    }
}

#[derive(Default)]
struct FenceStats {
    exports: u64,
    deadlines: u64,
    urgent_deadlines: u64,
    errors: u64,
    last_error: Option<String>,
}

enum WorkerContext {
    Standard(EGLContext),
    Desktop(desktop_egl::SharedEglContext),
}

impl Deref for WorkerContext {
    type Target = EGLContext;

    fn deref(&self) -> &Self::Target {
        match self {
            Self::Standard(context) => context,
            Self::Desktop(context) => context,
        }
    }
}

struct OwnedContext {
    context: WorkerContext,
    owner: Option<ThreadId>,
}

impl OwnedContext {
    fn bind(&mut self) -> bool {
        let thread = thread::current().id();
        if self.owner.is_some_and(|owner| owner != thread) {
            return false;
        }
        // SAFETY: ownership is checked under the handler's mutex. A context
        // can move between threads only after clear_current releases it.
        if unsafe { self.context.make_current() }.is_err() {
            return false;
        }
        self.owner = Some(thread);
        true
    }

    fn unbind(&mut self) -> bool {
        if self
            .owner
            .is_some_and(|owner| owner != thread::current().id())
        {
            return false;
        }
        if self.context.unbind().is_err() {
            return false;
        }
        self.owner = None;
        true
    }
}

#[derive(Default)]
struct Target {
    framebuffer: u32,
    texture: u32,
    depth_stencil: u32,
    depth_bits: i32,
    stencil_bits: i32,
    samples: i32,
    internal_format: i32,
    width: usize,
    height: usize,
}

struct RootImage {
    display: EGLDisplay,
    image: usize,
    _dmabuf: Dmabuf,
    _buffer: GbmBuffer,
}

impl RootImage {
    fn new(
        display: &EGLDisplay,
        gbm: &GbmDevice<Arc<fs::File>>,
        modifier: Modifier,
        fourcc: Fourcc,
    ) -> Result<Self, Box<dyn Error>> {
        // Match the desktop's allocation flags without importing a DRM
        // framebuffer or issuing any KMS ioctl. The fd is render-node-only.
        let mut allocator = GbmAllocator::new(
            gbm.clone(),
            GbmBufferFlags::RENDERING | GbmBufferFlags::SCANOUT,
        );
        let buffer = allocator.create_buffer(1264, 2780, fourcc, &[modifier])?;
        let actual = AllocatorBuffer::format(&buffer);
        if actual.code != fourcc || actual.modifier != modifier {
            return Err(
                format!("worker root allocation changed its requested format: {actual:?}").into(),
            );
        }
        let dmabuf = buffer.export()?;
        let image = display.create_image_from_dmabuf(&dmabuf)? as usize;
        Ok(Self {
            display: display.clone(),
            image,
            _dmabuf: dmabuf,
            _buffer: buffer,
        })
    }
}

impl Drop for RootImage {
    fn drop(&mut self) {
        // SAFETY: this image was created once on the retained display. EGL
        // image destruction does not invalidate existing texture siblings.
        unsafe {
            egl::ffi::egl::DestroyImageKHR(**self.display.get_display_handle(), self.image as _);
        }
    }
}

struct Handler {
    render: Mutex<OwnedContext>,
    resource: Mutex<OwnedContext>,
    gl: GlApi,
    targets: Vec<WorkerTarget>,
    current_target: AtomicUsize,
    events: mpsc::Sender<EngineEvent>,
    started: Mutex<Option<Instant>>,
    completed_us: Mutex<Vec<u64>>,
    paint_damage: Mutex<Vec<(u64, f64)>>,
    buffer_damage: Mutex<Vec<(u64, f64)>>,
    present_stages: Mutex<Vec<(u64, u64, u64, u64, u64)>>,
    copy_stages: Mutex<Vec<(u64, u64, u64)>>,
    slow_fence_steps: Mutex<Vec<FenceStepSample>>,
    raster_thread: AtomicI32,
    export_fence: bool,
    hint_deadline: bool,
    fence_stats: Mutex<FenceStats>,
    gpu_deadline_hints: gpu_deadline::GpuDeadlineHints,
    pending_view: Mutex<Option<(u32, u64, f64, f64)>>,
}

struct WorkerTarget {
    gl: Mutex<Target>,
    image: Option<usize>,
    scanout_copy: Option<ScanoutCopy>,
    damage: Mutex<desktop_damage::DamageRegion>,
    presents: AtomicU64,
}

struct ScanoutCopy {
    image: usize,
    enabled: bool,
    target: Mutex<Option<u32>>,
    shader: Arc<Mutex<Option<desktop_gl::ShaderBlit>>>,
    gl: desktop_gl::GlApi,
}

impl ScanoutCopy {
    fn prepare(&self) -> Result<(), Box<dyn Error>> {
        let mut target = self.target.lock().unwrap();
        if target.is_some() {
            return Ok(());
        }
        let mut texture = 0;
        let mut framebuffer = 0;
        let gl = self.gl;
        // SAFETY: the raster context is current during backing-store creation.
        // The worker retains the EGL image until after that context is destroyed.
        unsafe {
            (gl.gen_textures)(1, &mut texture);
            (gl.bind_texture)(gl::TEXTURE_2D, texture);
            (gl.image_target_texture)(gl::TEXTURE_2D, self.image as _);
            (gl.tex_parameter_i)(gl::TEXTURE_2D, gl::TEXTURE_MIN_FILTER, gl::NEAREST as i32);
            (gl.tex_parameter_i)(gl::TEXTURE_2D, gl::TEXTURE_MAG_FILTER, gl::NEAREST as i32);
            (gl.tex_parameter_i)(gl::TEXTURE_2D, gl::TEXTURE_WRAP_S, gl::CLAMP_TO_EDGE as i32);
            (gl.tex_parameter_i)(gl::TEXTURE_2D, gl::TEXTURE_WRAP_T, gl::CLAMP_TO_EDGE as i32);
            (gl.gen_framebuffers)(1, &mut framebuffer);
            (gl.bind_framebuffer)(gl::DRAW_FRAMEBUFFER, framebuffer);
            (gl.framebuffer_texture_2d)(
                gl::DRAW_FRAMEBUFFER,
                gl::COLOR_ATTACHMENT0,
                gl::TEXTURE_2D,
                texture,
                0,
            );
            if framebuffer == 0
                || texture == 0
                || (gl.check_framebuffer_status)(gl::DRAW_FRAMEBUFFER) != gl::FRAMEBUFFER_COMPLETE
                || (gl.get_error)() != gl::NO_ERROR
            {
                return Err("worker compressed copy target is incomplete".into());
            }
        }
        let mut shader = self.shader.lock().unwrap();
        if shader.is_none() {
            *shader = Some(desktop_gl::create_shader_blit(gl)?);
        }
        *target = Some(framebuffer);
        Ok(())
    }

    fn copy(&self, texture: u32, size: PixelSize) -> Result<(), Box<dyn Error>> {
        if !self.enabled {
            return Ok(());
        }
        let framebuffer = self
            .target
            .lock()
            .unwrap()
            .ok_or("worker scanout copy target was not prepared")?;
        let shader = self
            .shader
            .lock()
            .unwrap()
            .ok_or("worker scanout copy shader was not prepared")?;
        desktop_gl::copy_to_scanout(self.gl, texture, framebuffer, size, shader)
            .map_err(|error| format!("worker scanout shader copy failed: {error:#x}").into())
    }
}

struct GlApi(gl::Gles2);

// SAFETY: the table contains immutable process-lifetime function addresses.
// Calls which access GL state are confined to the current render context.
unsafe impl Sync for GlApi {}

impl Deref for GlApi {
    type Target = gl::Gles2;

    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl Handler {
    fn target(&self, width: usize, height: usize) -> Option<CompositorBackingStore> {
        if width == 0 || height == 0 || width > 4096 || height > 4096 {
            return None;
        }
        let slot = &self.targets[self.current_target.load(Ordering::Relaxed)];
        if slot.image.is_some() && (width != 1264 || height != 2780) {
            return None;
        }
        if let Some(copy) = &slot.scanout_copy
            && let Err(error) = copy.prepare()
        {
            eprintln!("{error}");
            return None;
        }
        let mut target = slot.gl.lock().unwrap();
        // SAFETY: Flutter calls framebuffer allocation with the render context
        // current. These GL names belong solely to this offscreen worker.
        unsafe {
            if target.framebuffer != 0 && (target.width != width || target.height != height) {
                self.gl.DeleteFramebuffers(1, &target.framebuffer);
                self.gl.DeleteTextures(1, &target.texture);
                self.gl.DeleteRenderbuffers(1, &target.depth_stencil);
                *target = Target::default();
            }
            if target.framebuffer == 0 {
                *slot.damage.lock().unwrap() =
                    desktop_damage::DamageRegion::full(width as u32, height as u32);
                self.gl.GenTextures(1, &mut target.texture);
                self.gl.BindTexture(gl::TEXTURE_2D, target.texture);
                self.gl
                    .TexParameteri(gl::TEXTURE_2D, gl::TEXTURE_MIN_FILTER, gl::LINEAR as i32);
                self.gl
                    .TexParameteri(gl::TEXTURE_2D, gl::TEXTURE_MAG_FILTER, gl::LINEAR as i32);
                if let Some(image) = slot.image {
                    self.gl
                        .EGLImageTargetTexture2DOES(gl::TEXTURE_2D, image as _);
                    self.gl.TexParameteri(
                        gl::TEXTURE_2D,
                        gl::TEXTURE_MIN_FILTER,
                        gl::NEAREST as i32,
                    );
                    self.gl.TexParameteri(
                        gl::TEXTURE_2D,
                        gl::TEXTURE_MAG_FILTER,
                        gl::NEAREST as i32,
                    );
                    self.gl.TexParameteri(
                        gl::TEXTURE_2D,
                        gl::TEXTURE_WRAP_S,
                        gl::CLAMP_TO_EDGE as i32,
                    );
                    self.gl.TexParameteri(
                        gl::TEXTURE_2D,
                        gl::TEXTURE_WRAP_T,
                        gl::CLAMP_TO_EDGE as i32,
                    );
                } else {
                    self.gl.TexImage2D(
                        gl::TEXTURE_2D,
                        0,
                        gl::RGBA8 as i32,
                        width as i32,
                        height as i32,
                        0,
                        gl::RGBA,
                        gl::UNSIGNED_BYTE,
                        std::ptr::null(),
                    );
                }
                self.gl.GetTexLevelParameteriv(
                    gl::TEXTURE_2D,
                    0,
                    gl::TEXTURE_INTERNAL_FORMAT,
                    &mut target.internal_format,
                );
                self.gl.GenFramebuffers(1, &mut target.framebuffer);
                self.gl.BindFramebuffer(gl::FRAMEBUFFER, target.framebuffer);
                self.gl.FramebufferTexture2D(
                    gl::FRAMEBUFFER,
                    gl::COLOR_ATTACHMENT0,
                    gl::TEXTURE_2D,
                    target.texture,
                    0,
                );
                // The embedder supplies only placeholder depth/stencil
                // descriptors when wrapping a physical-output FBO. As on the
                // desktop, its actual D24S8 attachment belongs to the host.
                self.gl.GenRenderbuffers(1, &mut target.depth_stencil);
                self.gl
                    .BindRenderbuffer(gl::RENDERBUFFER, target.depth_stencil);
                self.gl.RenderbufferStorage(
                    gl::RENDERBUFFER,
                    gl::DEPTH24_STENCIL8,
                    width as i32,
                    height as i32,
                );
                self.gl.FramebufferRenderbuffer(
                    gl::FRAMEBUFFER,
                    gl::DEPTH_STENCIL_ATTACHMENT,
                    gl::RENDERBUFFER,
                    target.depth_stencil,
                );
                self.gl.GetIntegerv(gl::DEPTH_BITS, &mut target.depth_bits);
                self.gl
                    .GetIntegerv(gl::STENCIL_BITS, &mut target.stencil_bits);
                self.gl.GetIntegerv(gl::SAMPLES, &mut target.samples);
                if self.gl.CheckFramebufferStatus(gl::FRAMEBUFFER) != gl::FRAMEBUFFER_COMPLETE
                    || target.depth_stencil == 0
                    || target.depth_bits < 24
                    || target.stencil_bits < 8
                    || target.samples > 1
                    || self.gl.GetError() != gl::NO_ERROR
                {
                    return None;
                }
                target.width = width;
                target.height = height;
            }
            // Match the desktop's backing-store contract even when this FBO
            // was allocated on an earlier frame and a different slot is bound.
            self.gl.BindFramebuffer(gl::FRAMEBUFFER, target.framebuffer);
            self.gl.Viewport(0, 0, width as i32, height as i32);
        }
        Some(CompositorBackingStore {
            framebuffer: target.framebuffer,
            format: gl::RGBA8,
            user_data: target.framebuffer as usize,
        })
    }

    fn prepare_frame_fence(&self, deadline_ns: u64) {
        if !self.export_fence {
            return;
        }
        let timestamp = clock_micros(ClockId::Monotonic);
        let started = Instant::now();
        let cpu_started = clock_micros(ClockId::ThreadCPUTime);
        let mut steps = [(0, 0); 9];
        let mut mark = |index: usize| {
            steps[index] = (
                started.elapsed().as_micros() as u64,
                clock_micros(ClockId::ThreadCPUTime).saturating_sub(cpu_started),
            );
        };
        let result = (|| -> Result<(), Box<dyn Error>> {
            let context = self.render.lock().unwrap();
            mark(1);
            let fence = EGLFence::create(context.context.display())?;
            mark(2);
            // SAFETY: present runs with our raster context current. This
            // flush publishes only this worker's preceding GL commands.
            unsafe { self.gl.Flush() };
            mark(3);
            let native = fence.export()?;
            mark(4);
            self.fence_stats.lock().unwrap().exports += 1;
            if self.hint_deadline {
                if self.gpu_deadline_hints.set(native.as_fd(), deadline_ns)? {
                    let mut stats = self.fence_stats.lock().unwrap();
                    stats.deadlines += 1;
                    stats.urgent_deadlines += u64::from(deadline_ns == 0);
                }
            }
            mark(5);
            drop(native);
            mark(6);
            drop(fence);
            mark(7);
            drop(context);
            mark(8);
            Ok(())
        })();
        if steps[8].0 >= 2000 {
            let mut samples = self.slow_fence_steps.lock().unwrap();
            if samples.len() < 2000 {
                samples.push((timestamp, steps));
            }
        }
        if let Err(error) = result {
            let mut stats = self.fence_stats.lock().unwrap();
            stats.errors += 1;
            stats.last_error = Some(error.to_string());
        }
    }

    fn finish_frame(&self) -> bool {
        // SAFETY: the present callback runs with this worker's render context
        // current. Finish measures completion of the whole offscreen frame;
        // it does not read pixels or insert per-draw timestamp queries.
        unsafe { self.gl.Finish() };
        if let Some(started) = self.started.lock().unwrap().take() {
            let mut samples = self.completed_us.lock().unwrap();
            if samples.len() < 20000 {
                samples.push(started.elapsed().as_micros() as u64);
            }
        }
        true
    }
}

impl OpenGlHandler for Handler {
    fn make_current(&self) -> bool {
        if !self.render.lock().unwrap().bind() {
            return false;
        }
        self.started
            .lock()
            .unwrap()
            .get_or_insert_with(Instant::now);
        // SAFETY: gettid returns the calling thread's identifier without
        // changing its scheduling or affinity.
        self.raster_thread
            .store(unsafe { libc::gettid() }, Ordering::Relaxed);
        true
    }

    fn clear_current(&self) -> bool {
        self.render.lock().unwrap().unbind()
    }

    fn make_resource_current(&self) -> bool {
        self.resource.lock().unwrap().bind()
    }

    fn framebuffer(&self, width: u32, height: u32) -> u32 {
        self.target(width as usize, height as usize)
            .map_or(0, |target| target.framebuffer)
    }

    fn create_backing_store(&self, request: BackingStoreRequest) -> Option<CompositorBackingStore> {
        self.target(request.width, request.height)
    }

    fn collect_backing_store(&self, store: CompositorBackingStore) -> bool {
        store.user_data == store.framebuffer as usize
            && self
                .targets
                .iter()
                .any(|slot| slot.gl.lock().unwrap().framebuffer == store.framebuffer)
    }

    fn present(&self, frame: PresentFrame<'_>) -> bool {
        let Some((framebuffer, deadline_ns, width, height)) =
            self.pending_view.lock().unwrap().take()
        else {
            return frame.framebuffer == 0;
        };
        // Denial's root surface uses FBO zero only as the damage handoff;
        // the earlier external-view callback supplied the actual target.
        if framebuffer == 0 || frame.framebuffer != 0 {
            return false;
        }
        let index = self.current_target.load(Ordering::Relaxed);
        let slot = &self.targets[index];
        if slot.gl.lock().unwrap().framebuffer != framebuffer {
            return false;
        }
        let area: f64 = frame
            .frame_damage
            .iter()
            .map(|rect| {
                (rect.right.min(width) - rect.left.max(0.0)).max(0.0)
                    * (rect.bottom.min(height) - rect.top.max(0.0)).max(0.0)
            })
            .sum();
        let mut samples = self.paint_damage.lock().unwrap();
        if samples.len() < 20000 && width > 0.0 && height > 0.0 {
            samples.push((
                deadline_ns / 1000,
                (area / (width * height) * 100.0).min(100.0),
            ));
        }
        drop(samples);
        let timestamp_us = clock_micros(ClockId::Monotonic);
        let cpu_us = || clock_micros(ClockId::ThreadCPUTime);
        if let Some(copy) = &slot.scanout_copy {
            let copy_start = Instant::now();
            let copy_cpu_start = cpu_us();
            let target = slot.gl.lock().unwrap();
            if let Err(error) = copy.copy(
                target.texture,
                PixelSize {
                    width: target.width as u32,
                    height: target.height as u32,
                },
            ) {
                eprintln!("{error}");
                return false;
            }
            let mut samples = self.copy_stages.lock().unwrap();
            if samples.len() < 20000 {
                samples.push((
                    timestamp_us,
                    copy_start.elapsed().as_micros() as u64,
                    cpu_us().saturating_sub(copy_cpu_start),
                ));
            }
        }
        let fence_start = Instant::now();
        let fence_cpu_start = cpu_us();
        self.prepare_frame_fence(deadline_ns);
        let fence_us = fence_start.elapsed().as_micros() as u64;
        let fence_cpu_us = cpu_us().saturating_sub(fence_cpu_start);
        let finish_start = Instant::now();
        let finish_cpu_start = cpu_us();
        let presented = self.finish_frame();
        let finish_us = finish_start.elapsed().as_micros() as u64;
        let finish_cpu_us = cpu_us().saturating_sub(finish_cpu_start);
        let mut stages = self.present_stages.lock().unwrap();
        if stages.len() < 20000 {
            stages.push((
                timestamp_us,
                fence_us,
                fence_cpu_us,
                finish_us,
                finish_cpu_us,
            ));
        }
        drop(stages);
        if presented {
            // Reuse the compositor's bounded DamageRegion implementation and
            // its per-slot repair rule: each other buffer accumulates changes
            // since it was last painted, while this completed buffer is fresh.
            let size = slot.gl.lock().unwrap();
            let mut changed =
                desktop_damage::DamageRegion::empty(size.width as u32, size.height as u32);
            changed.replace_from_flutter(frame.frame_damage);
            for (other_index, other) in self.targets.iter().enumerate() {
                if other_index == index {
                    other.damage.lock().unwrap().clear();
                } else {
                    other.damage.lock().unwrap().union(&changed);
                }
            }
            let mut repaired =
                desktop_damage::DamageRegion::empty(size.width as u32, size.height as u32);
            repaired.replace_from_flutter(frame.buffer_damage);
            let mut samples = self.buffer_damage.lock().unwrap();
            if samples.len() < 20000 {
                samples.push((
                    timestamp_us,
                    repaired.damaged_area() / (size.width * size.height) as f64 * 100.0,
                ));
            }
            slot.presents.fetch_add(1, Ordering::Relaxed);
            // Finish above completed this worker's GPU work. This models
            // buffer rotation and age, without pretending to model KMS queues.
            self.current_target
                .store((index + 1) % self.targets.len(), Ordering::Relaxed);
        }
        presented
    }

    fn present_view(&self, view: PresentView<'_>) -> bool {
        // Match the desktop: this callback identifies the target, then the
        // root SurfaceFrame's present callback supplies exact frame damage
        // after submitting its GL commands. Finish/export only at that point.
        let mut pending = self.pending_view.lock().unwrap();
        if pending.is_some() {
            return false;
        }
        *pending = Some((
            view.backing_store.framebuffer,
            view.presentation_time_nanos,
            view.width,
            view.height,
        ));
        true
    }

    fn populate_existing_damage(&self, framebuffer: isize, damage: &mut Vec<sys::FlutterRect>) {
        damage.clear();
        if framebuffer == 0 {
            return;
        }
        for slot in &self.targets {
            if slot.gl.lock().unwrap().framebuffer as isize == framebuffer {
                slot.damage.lock().unwrap().write_flutter(damage);
                return;
            }
        }
        // As on the desktop, an unknown FBO must not claim an undamaged scene.
        desktop_damage::DamageRegion::full(1264, 2780).write_flutter(damage);
    }

    fn resolve_proc(&self, name: &CStr) -> *mut c_void {
        // SAFETY: EGL is initialized and the requested symbol is a valid C
        // string supplied by Flutter's GL loader.
        unsafe { egl::get_proc_address(name.to_str().unwrap_or_default()) as *mut c_void }
    }

    fn event(&self, event: EngineEvent) {
        let _ = self.events.send(event);
    }

    fn log(&self, tag: &str, message: &str) {
        if !message.contains("http://") && !message.contains("https://") {
            eprintln!("flutter[{tag}]: {message}");
        }
    }
}

fn digest(path: &Path) -> Result<String, Box<dyn Error>> {
    Ok(format!("{:x}", Sha256::digest(fs::read(path)?)))
}

fn main() -> Result<(), Box<dyn Error>> {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    if args.len() < 5
        || args[5..].iter().any(|arg| {
            arg != "--gpu-stage-audit"
                && arg != "--direct-glass"
                && arg != "--inward-glass-bounds"
                && arg != "--fence-only"
                && arg != "--fence-deadline"
                && arg != "--timeline"
                && arg != "--desktop-render-priorities"
                && arg != "--driver-single-thread"
                && arg != "--pooled-glass-targets"
                && arg != "--resource-audit"
                && arg != "--retain-glass-targets"
                && arg != "--retain-glass-by-budget"
                && arg != "--implicit-msaa"
                && arg != "--pooled-glass-material"
                && !arg.starts_with("--root-storage=")
                && !arg.starts_with("--root-format=")
                && !arg.starts_with("--start-phase-us=")
                && !arg.starts_with("--scanout-copy=")
                && !arg.starts_with("--root-buffers=")
        })
    {
        return Err(
            "usage: denial-glass-benchmark BUNDLE SETTINGS OUTPUT PARENT_PID BOOT_ID [--gpu-stage-audit] [--direct-glass] [--inward-glass-bounds] [--fence-only | --fence-deadline] [--timeline] [--desktop-render-priorities] [--driver-single-thread] [--pooled-glass-targets] [--resource-audit] [--retain-glass-targets] [--retain-glass-by-budget] [--implicit-msaa] [--pooled-glass-material] [--root-storage=texture|linear|compressed] [--root-format=xrgb|xbgr|argb|abgr] [--start-phase-us=0..999999] [--scanout-copy=on|off] [--root-buffers=1|3]".into(),
        );
    }
    let stage_audit = args[5..].iter().any(|arg| arg == "--gpu-stage-audit");
    let direct_glass = args[5..].iter().any(|arg| arg == "--direct-glass");
    let inward_glass_bounds = args[5..].iter().any(|arg| arg == "--inward-glass-bounds");
    let hint_deadline = args[5..].iter().any(|arg| arg == "--fence-deadline");
    let fence_only = args[5..].iter().any(|arg| arg == "--fence-only");
    let timeline = args[5..].iter().any(|arg| arg == "--timeline");
    let desktop_priorities = args[5..]
        .iter()
        .any(|arg| arg == "--desktop-render-priorities");
    let driver_single_thread = args[5..].iter().any(|arg| arg == "--driver-single-thread");
    let pooled_glass_targets = args[5..].iter().any(|arg| arg == "--pooled-glass-targets");
    let resource_audit = args[5..].iter().any(|arg| arg == "--resource-audit");
    let retain_glass_targets = args[5..].iter().any(|arg| arg == "--retain-glass-targets");
    let retain_glass_by_budget = args[5..]
        .iter()
        .any(|arg| arg == "--retain-glass-by-budget");
    let implicit_msaa = args[5..].iter().any(|arg| arg == "--implicit-msaa");
    if retain_glass_by_budget && !retain_glass_targets {
        return Err("budget-only retention requires --retain-glass-targets".into());
    }
    let pooled_glass_material = args[5..].iter().any(|arg| arg == "--pooled-glass-material");
    let mut buffer_choices = args[5..]
        .iter()
        .filter_map(|arg| arg.strip_prefix("--root-buffers="));
    let root_buffers = match buffer_choices.next().unwrap_or("1") {
        "1" => 1,
        "3" => 3,
        _ => return Err("root-buffers must be 1 or 3".into()),
    };
    if buffer_choices.next().is_some() {
        return Err("choose only one root-buffers value".into());
    }
    let mut copy_choices = args[5..]
        .iter()
        .filter_map(|arg| arg.strip_prefix("--scanout-copy="));
    let scanout_copy = match copy_choices.next() {
        None => None,
        Some("on") => Some(true),
        Some("off") => Some(false),
        _ => return Err("scanout copy must be on or off".into()),
    };
    if copy_choices.next().is_some() {
        return Err("choose only one scanout-copy value".into());
    }
    let mut start_phases = args[5..]
        .iter()
        .filter_map(|arg| arg.strip_prefix("--start-phase-us="));
    let start_phase_us = start_phases.next().map(str::parse::<u32>).transpose()?;
    if start_phases.next().is_some() || start_phase_us.is_some_and(|phase| phase >= 1_000_000) {
        return Err("choose one start phase in [0, 1000000) microseconds".into());
    }
    let mut root_choices = args[5..]
        .iter()
        .filter_map(|arg| arg.strip_prefix("--root-storage="));
    let (root_storage, root_modifier) = match root_choices.next().unwrap_or("texture") {
        "texture" => ("gles_rgba8_texture", None),
        "linear" => ("gbm_linear_xr24", Some(Modifier::Linear)),
        "compressed" => ("gbm_qcom_compressed_xr24", Some(Modifier::Qcom_compressed)),
        _ => return Err("root storage must be texture, linear or compressed".into()),
    };
    if root_choices.next().is_some() {
        return Err("choose only one root storage mode".into());
    }
    let mut formats = args[5..]
        .iter()
        .filter_map(|arg| arg.strip_prefix("--root-format="));
    let format_arg = formats.next();
    let (root_fourcc, format_suffix) = match format_arg.unwrap_or("xrgb") {
        "xrgb" => (Fourcc::Xrgb8888, "xr24"),
        "xbgr" => (Fourcc::Xbgr8888, "xb24"),
        "argb" => (Fourcc::Argb8888, "ar24"),
        "abgr" => (Fourcc::Abgr8888, "ab24"),
        _ => return Err("root format must be xrgb, xbgr, argb or abgr".into()),
    };
    if formats.next().is_some() || (format_arg.is_some() && root_modifier.is_none()) {
        return Err("choose one root format, with GBM root storage".into());
    }
    let root_storage = root_storage.replace("xr24", format_suffix);
    if scanout_copy.is_some()
        && (root_modifier != Some(Modifier::Linear) || root_fourcc != Fourcc::Xrgb8888)
    {
        return Err(
            "scanout-copy comparison requires the desktop's linear XR24 render target".into(),
        );
    }
    if hint_deadline && fence_only {
        return Err("choose either --fence-only or --fence-deadline".into());
    }
    let bundle = PathBuf::from(&args[0]).canonicalize()?;
    let settings = PathBuf::from(&args[1]).canonicalize()?;
    let output = PathBuf::from(&args[2]);
    if !output.is_absolute() || output.exists() || !output.parent().is_some_and(Path::is_dir) {
        return Err("output must be an unused absolute path in an existing directory".into());
    }
    let parent_pid: u32 = args[3].parse()?;
    if parent_pid <= 1 || parent_pid == std::process::id() {
        return Err("expected the running compositor's PID".into());
    }
    let parent = PathBuf::from(format!("/proc/{parent_pid}"));
    let parent_start = fs::read_to_string(parent.join("stat"))?
        .rsplit_once(") ")
        .ok_or("invalid parent process stat")?
        .1
        .split_whitespace()
        .nth(19)
        .ok_or("missing parent start time")?
        .to_owned();
    let check_parent = || -> Result<(), Box<dyn Error>> {
        if fs::read_to_string("/proc/sys/kernel/random/boot_id")?.trim() != args[4]
            || fs::read_to_string(parent.join("comm"))?.trim() != "deniald"
            || fs::read_to_string(parent.join("stat"))?
                .rsplit_once(") ")
                .ok_or("invalid parent process stat")?
                .1
                .split_whitespace()
                .nth(19)
                != Some(parent_start.as_str())
        {
            return Err("compositor identity changed; stop remote profiling".into());
        }
        Ok(())
    };
    check_parent()?;
    if desktop_priorities {
        let mut param = libc::sched_param { sched_priority: 0 };
        // SAFETY: these calls only query the identified compositor process.
        let matches = unsafe {
            libc::sched_getscheduler(parent_pid as libc::pid_t) & !libc::SCHED_RESET_ON_FORK
                == libc::SCHED_RR
                && libc::sched_getparam(parent_pid as libc::pid_t, &mut param) == 0
                && param.sched_priority == 1
        };
        if !matches {
            return Err("desktop priority comparison requires a SCHED_RR/1 compositor".into());
        }
    }
    // Use the desktop's eligible CPUs before creating any worker threads.
    // Otherwise Linux can place this short-lived process on efficiency cores
    // even when the compositor is restricted to the performance cluster.
    // This changes only our own affinity; the compositor is read-only here.
    // SAFETY: cpu_set_t is plain storage and both calls receive its exact size.
    let cpu_affinity = unsafe {
        let mut affinity: libc::cpu_set_t = mem::zeroed();
        if libc::sched_getaffinity(
            parent_pid as libc::pid_t,
            mem::size_of_val(&affinity),
            &mut affinity,
        ) != 0
            || libc::sched_setaffinity(0, mem::size_of_val(&affinity), &affinity) != 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        (0..libc::CPU_SETSIZE as usize)
            .filter(|&cpu| libc::CPU_ISSET(cpu, &affinity))
            .collect::<Vec<_>>()
    };
    let native_output = output.with_extension("native.json");
    let native_file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&native_output)?;
    // SAFETY: no threads or EGL/Flutter libraries have been started yet. These
    // variables affect only this disposable worker, never the live compositor.
    unsafe {
        std::env::set_var("DENIAL_OFFSCREEN_BENCHMARK_SETTINGS", &settings);
        std::env::set_var(
            "DENIA_GLES_IMPLICIT_MSAA",
            if implicit_msaa { "1" } else { "0" },
        );
        std::env::set_var("DENIAL_OFFSCREEN_BENCHMARK_OUTPUT", &output);
        std::env::set_var(
            "DENIA_GLASS_POOLED_MATERIAL_PADDING",
            if pooled_glass_material { "1" } else { "0" },
        );
        std::env::set_var(
            "DENIA_GLASS_RETAIN_TARGETS",
            if retain_glass_targets { "1" } else { "0" },
        );
        std::env::set_var(
            "DENIA_GLASS_RETAIN_TARGETS_BY_BUDGET",
            if retain_glass_by_budget { "1" } else { "0" },
        );
        if let Some(phase) = start_phase_us {
            std::env::set_var(
                "DENIAL_OFFSCREEN_BENCHMARK_START_PHASE_US",
                phase.to_string(),
            );
        } else {
            std::env::remove_var("DENIAL_OFFSCREEN_BENCHMARK_START_PHASE_US");
        }
        std::env::set_var(
            "DENIA_GL_RESOURCE_AUDIT",
            if resource_audit { "1" } else { "0" },
        );
        if driver_single_thread {
            std::env::set_var("GALLIUM_THREAD", "0");
        }
        std::env::set_var(
            "DENIA_GLASS_POOLED_TARGET_PADDING",
            if pooled_glass_targets { "1" } else { "0" },
        );
        std::env::set_var(
            "DENIAL_OFFSCREEN_BENCHMARK_TIMELINE",
            if timeline { "1" } else { "0" },
        );
        std::env::set_var("DENIA_RENDER_AUDIT", if stage_audit { "1" } else { "0" });
        std::env::set_var("DENIA_GPU_STAGE_AUDIT", if stage_audit { "1" } else { "0" });
        std::env::set_var(
            "DENIA_GLASS_DIRECT_MATERIAL",
            if direct_glass { "1" } else { "0" },
        );
        std::env::set_var(
            "DENIA_GLASS_INWARD_BOUNDS",
            if inward_glass_bounds { "1" } else { "0" },
        );
    }
    let done = Arc::new(AtomicBool::new(false));
    let watchdog_done = done.clone();
    thread::spawn(move || {
        thread::sleep(Duration::from_secs(100));
        if !watchdog_done.load(Ordering::Acquire) {
            eprintln!("offscreen benchmark exceeded its lifetime");
            std::process::exit(124);
        }
    });

    // A render node exposes rendering ioctls only, with no KMS/master access.
    let node = OpenOptions::new()
        .read(true)
        .write(true)
        .open("/dev/dri/renderD128")?;
    let gbm = GbmDevice::new(Arc::new(node))?;
    // SAFETY: this EGLDisplay retains a clone of GBM and its render-node file.
    let display = unsafe { EGLDisplay::new(gbm.clone()) }?;
    let root_images = (0..root_buffers)
        .map(|_| {
            root_modifier
                .map(|modifier| RootImage::new(&display, &gbm, modifier, root_fourcc))
                .transpose()
        })
        .collect::<Result<Vec<_>, _>>()?;
    // Both ON and OFF allocate the same compressed destination and shader.
    // Only the draw differs, so the control has the same retained resources.
    let copy_images = (0..root_buffers)
        .map(|_| {
            scanout_copy
                .map(|_| {
                    RootImage::new(&display, &gbm, Modifier::Qcom_compressed, Fourcc::Xrgb8888)
                })
                .transpose()
        })
        .collect::<Result<Vec<_>, _>>()?;
    let attributes = GlAttributes {
        version: (3, 2),
        profile: None,
        debug: false,
        vsync: false,
    };
    let format = PixelFormatRequirements {
        hardware_accelerated: Some(true),
        color_bits: Some(24),
        float_color_buffer: false,
        alpha_bits: Some(8),
        depth_bits: None,
        stencil_bits: None,
        multisampling: Some(0),
    };
    // Reuse the desktop's exact shared-context helper in comparison mode,
    // including its high GPU priority and explicit context flush control.
    let root_context = desktop_priorities
        .then(|| desktop_egl::create_render_context(&display))
        .transpose()?;
    let (context, resource) = if let Some(root) = &root_context {
        (
            WorkerContext::Desktop(desktop_egl::create_shared_context("worker raster", root)?),
            WorkerContext::Desktop(desktop_egl::create_shared_context("worker resource", root)?),
        )
    } else {
        let context = EGLContext::new_with_config(&display, attributes, format)?;
        let resource = EGLContext::new_shared(&display, &context)?;
        (
            WorkerContext::Standard(context),
            WorkerContext::Standard(resource),
        )
    };
    context.unbind()?;
    resource.unbind()?;
    let gl = gl::Gles2::load_with(|symbol| {
        // SAFETY: EGL is initialized before loading its GLES entry points.
        unsafe { egl::get_proc_address(symbol) }
    });
    let copy_gl = scanout_copy
        .map(|_| -> Result<_, Box<dyn Error>> {
            // SAFETY: before EngineHost starts, this context has no other owner.
            unsafe {
                context.make_current()?;
            }
            let table = desktop_gl::GlApi::load();
            context.unbind()?;
            table
        })
        .transpose()?;
    let copy_shader = Arc::new(Mutex::new(None));
    let targets = (0..root_buffers)
        .map(|index| WorkerTarget {
            gl: Mutex::new(Target::default()),
            image: root_images[index].as_ref().map(|image| image.image),
            scanout_copy: scanout_copy.map(|enabled| ScanoutCopy {
                image: copy_images[index].as_ref().unwrap().image,
                enabled,
                target: Mutex::new(None),
                shader: Arc::clone(&copy_shader),
                gl: copy_gl.unwrap(),
            }),
            damage: Mutex::new(desktop_damage::DamageRegion::full(1264, 2780)),
            presents: AtomicU64::new(0),
        })
        .collect();
    let (send, receive) = mpsc::channel();
    let handler = Arc::new(Handler {
        render: Mutex::new(OwnedContext {
            context,
            owner: None,
        }),
        resource: Mutex::new(OwnedContext {
            context: resource,
            owner: None,
        }),
        gl: GlApi(gl),
        targets,
        current_target: AtomicUsize::new(0),
        events: send,
        started: Mutex::new(None),
        completed_us: Mutex::new(Vec::new()),
        paint_damage: Mutex::new(Vec::new()),
        buffer_damage: Mutex::new(Vec::new()),
        present_stages: Mutex::new(Vec::new()),
        copy_stages: Mutex::new(Vec::new()),
        slow_fence_steps: Mutex::new(Vec::new()),
        raster_thread: AtomicI32::new(0),
        export_fence: hint_deadline || fence_only,
        hint_deadline,
        fence_stats: Mutex::new(FenceStats::default()),
        gpu_deadline_hints: gpu_deadline::GpuDeadlineHints::default(),
        pending_view: Mutex::new(None),
    });
    let project = EngineProject {
        engine_library: bundle.join("lib/libflutter_engine.so"),
        assets: bundle.join("data/flutter_assets"),
        icu_data: bundle.join("data/icudtl.dat"),
        runtime: DartRuntimeMode::AotProfile,
        aot_library: Some(bundle.join("lib/libapp.so")),
        renderer_backend: RendererBackend::ImpellerGles,
        resource_cache_max_bytes_threshold: 0,
    };
    let library = Arc::new(EngineLibrary::load(&project.engine_library)?);
    let host = EngineHost::start_with_library_and_priority_setter(
        &project,
        handler.clone(),
        library,
        desktop_priorities.then_some(set_worker_thread_priority),
    )?;
    let engine = host.engine();
    engine.notify_displays(
        sys::FlutterEngineDisplaysUpdateType_kFlutterEngineDisplaysUpdateTypeStartup,
        &[sys::FlutterEngineDisplay {
            struct_size: mem::size_of::<sys::FlutterEngineDisplay>(),
            display_id: 0,
            single_display: true,
            refresh_rate: 120.0,
            width: 1264,
            height: 2780,
            device_pixel_ratio: 2.0,
        }],
    )?;
    engine.send_window_metrics(&sys::FlutterWindowMetricsEvent {
        struct_size: mem::size_of::<sys::FlutterWindowMetricsEvent>(),
        width: 1264,
        height: 2780,
        pixel_ratio: 2.0,
        display_id: 0,
        view_id: 0,
        ..sys::FlutterWindowMetricsEvent::default()
    })?;
    engine.set_render_outputs(&[RenderOutput {
        render_view_id: -1,
        configuration_generation: 1,
        source_physical_x: 0.0,
        source_physical_y: 0.0,
        source_physical_width: 1264.0,
        source_physical_height: 2780.0,
        target_width: 1264,
        target_height: 2780,
        scale_120: 240,
        source_to_target_transform: RenderOutputTransform {
            scale_x: 1.0,
            skew_x: 0.0,
            translate_x: 0.0,
            skew_y: 0.0,
            scale_y: 1.0,
            translate_y: 0.0,
        },
    }])?;
    let mut tasks = Vec::<ScheduledTask>::new();
    let mut batons = Vec::new();
    let interval = 1_000_000_000_u64 / 120;
    let mut next_frame = engine.current_time_nanos() + interval;
    let deadline = Instant::now() + Duration::from_secs(90);
    let mut next_health = Instant::now();
    let mut frequency_samples = Vec::new();
    loop {
        while let Ok(event) = receive.try_recv() {
            match event {
                EngineEvent::PlatformTask(task) => tasks.push(task),
                EngineEvent::Vsync(baton) => batons.push(baton),
                EngineEvent::PlatformMessage(mut message) => host.respond(&mut message, &[])?,
            }
        }
        let now = engine.current_time_nanos();
        let mut pending = Vec::new();
        for task in tasks.drain(..) {
            if task.target_time_nanos <= now {
                host.run_scheduled_task(task)?;
            } else {
                pending.push(task);
            }
        }
        tasks = pending;
        if now >= next_frame {
            next_frame = now + interval;
            if !batons.is_empty() {
                engine.render_outputs(&[-1], &[], true, now, next_frame)?;
                for baton in batons.drain(..) {
                    engine.on_vsync(baton, now, next_frame)?;
                }
            }
        }
        if Instant::now() >= next_health {
            check_parent()?;
            let raster_tid = handler.raster_thread.load(Ordering::Relaxed);
            let raster_cpu = fs::read_to_string(format!("/proc/self/task/{raster_tid}/stat"))
                .ok()
                .and_then(|stat| stat.rsplit_once(") ").map(|(_, rest)| rest.to_owned()))
                .and_then(|stat| stat.split_whitespace().nth(36)?.parse::<u32>().ok());
            let read_number =
                |path: &Path| -> Option<u64> { fs::read_to_string(path).ok()?.trim().parse().ok() };
            frequency_samples.push(serde_json::json!({
                "timestamp_us": now / 1000,
                "gpu_frequency_hz": read_number(Path::new("/sys/class/devfreq/3d00000.gpu/cur_freq")),
                "raster_cpu": raster_cpu,
                "raster_cpu_frequency_khz": raster_cpu.and_then(|cpu| read_number(
                    Path::new(&format!("/sys/devices/system/cpu/cpu{cpu}/cpufreq/scaling_cur_freq")))),
                "raster_policy": if raster_tid > 0 {
                    // SAFETY: querying this worker's thread changes no policy.
                    Some(unsafe { libc::sched_getscheduler(raster_tid) })
                } else { None },
            }));
            if fs::read(&output)
                .ok()
                .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
                .is_some_and(|result| result["status"] == "completed")
            {
                break;
            }
            if Instant::now() >= deadline {
                return Err("offscreen workload timed out".into());
            }
            next_health = Instant::now() + Duration::from_millis(250);
        }
        thread::sleep(Duration::from_micros(500));
    }
    host.shutdown()?;
    check_parent()?;
    let fence_stats = handler.fence_stats.lock().unwrap();
    let root_pool = handler
        .targets
        .iter()
        .map(|slot| {
            let target = slot.gl.lock().unwrap();
            serde_json::json!({
                "framebuffer": target.framebuffer, "texture": target.texture,
                "presents": slot.presents.load(Ordering::Relaxed),
                "depth_bits": target.depth_bits, "stencil_bits": target.stencil_bits,
                "samples": target.samples,
            })
        })
        .collect::<Vec<_>>();
    let target = handler.targets[0].gl.lock().unwrap();
    serde_json::to_writer_pretty(
        native_file,
        &serde_json::json!({
            "mode": "offscreen_profile", "render_node": "/dev/dri/renderD128",
            // Version 2 follows the desktop callback sequence and finishes
            // the GPU once, in the standard root-surface present callback.
            "presentation_protocol_version": 2,
            "root_target_version": 2,
            "root_buffer_count": root_buffers,
            "root_pool": root_pool,
            "damage_tracking": "shared_desktop_damage_region_per_buffer",
            "root_target": {
                "drm_fourcc": root_modifier.map(|_| format!("{root_fourcc:?}")),
                "gl_internal_format": target.internal_format,
                "declared_gl_format": gl::RGBA8,
                "storage": root_storage,
                "drm_modifier": root_modifier.map(u64::from),
                "depth_bits": target.depth_bits,
                "stencil_bits": target.stencil_bits,
                "samples": target.samples,
            },
            "worker_sha256": digest(Path::new("/proc/self/exe"))?,
            "parent_pid": parent_pid, "parent_boot": args[4],
            "engine_sha256": digest(&project.engine_library)?,
            "app_sha256": digest(project.aot_library.as_ref().unwrap())?,
            "settings_sha256": digest(&settings)?,
            "completion_us": *handler.completed_us.lock().unwrap(),
            "paint_damage_samples": handler.paint_damage.lock().unwrap().iter()
                .map(|(timestamp_us, percent)| serde_json::json!({
                    "timestamp_us": timestamp_us, "percent": percent,
                })).collect::<Vec<_>>(),
            "buffer_damage_samples": handler.buffer_damage.lock().unwrap().iter()
                .map(|(timestamp_us, percent)| serde_json::json!({
                    "timestamp_us": timestamp_us, "percent": percent,
                })).collect::<Vec<_>>(),
            "synchronous_gpu_completion": true,
            "scanout_copy": scanout_copy.map(|enabled| serde_json::json!({
                "enabled": enabled, "storage": "gbm_qcom_compressed_xr24",
                "drm_modifier": u64::from(Modifier::Qcom_compressed),
                "pipeline": "shared_desktop_shader_copy",
            })),
            "scanout_copy_cpu_samples": handler.copy_stages.lock().unwrap().iter()
                .map(|(timestamp_us, wall_us, cpu_us)| serde_json::json!({
                    "timestamp_us": timestamp_us, "wall_us": wall_us, "cpu_us": cpu_us,
                })).collect::<Vec<_>>(),
            "present_stage_samples": handler.present_stages.lock().unwrap().iter()
                .map(|(timestamp, fence, fence_cpu, finish, finish_cpu)| serde_json::json!({
                    "timestamp_us": timestamp, "fence_us": fence,
                    "fence_cpu_us": fence_cpu, "finish_us": finish,
                    "finish_cpu_us": finish_cpu,
                })).collect::<Vec<_>>(),
            "slow_fence_step_names": ["start", "context_lock", "egl_create",
                "gl_flush", "egl_export", "deadline", "fd_drop", "egl_drop", "context_unlock"],
            "slow_fence_steps": handler.slow_fence_steps.lock().unwrap().iter()
                .map(|(timestamp_us, steps)| serde_json::json!({
                    "timestamp_us": timestamp_us, "elapsed_wall_cpu_us": steps,
                })).collect::<Vec<_>>(),
            "gpu_stage_audit": stage_audit,
            "direct_glass_material": direct_glass,
            "inward_glass_bounds": inward_glass_bounds,
            "fence_only": fence_only,
            "fence_deadline": hint_deadline,
            "timeline": timeline,
            "desktop_render_priorities": desktop_priorities,
            "thread_priority_failures": PRIORITY_FAILURES.load(Ordering::Relaxed),
            "driver_single_thread": driver_single_thread,
            "pooled_glass_targets": pooled_glass_targets,
            "resource_audit": resource_audit,
            "retain_glass_targets": retain_glass_targets,
            "retain_glass_by_budget": retain_glass_by_budget,
            "implicit_msaa_requested": implicit_msaa,
            "pooled_glass_material": pooled_glass_material,
            "start_phase_us": start_phase_us,
            "gallium_thread_environment": std::env::var("GALLIUM_THREAD").ok(),
            "fence_stats": {
                "exports": fence_stats.exports, "deadlines": fence_stats.deadlines,
                "urgent_deadlines": fence_stats.urgent_deadlines,
                "errors": fence_stats.errors, "last_error": fence_stats.last_error,
            },
            "cpu_affinity": cpu_affinity,
            "frequency_samples": frequency_samples,
        }),
    )?;
    done.store(true, Ordering::Release);
    Ok(())
}
