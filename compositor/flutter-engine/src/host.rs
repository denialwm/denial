use std::cell::RefCell;
use std::error::Error;
use std::ffi::{CStr, CString, c_void};
use std::fmt;
use std::mem;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::{Path, PathBuf};
use std::ptr;
use std::slice;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, ThreadId};

use crate::{EngineError, EngineLibrary, LoadError, RunningEngine, sys};

// These values are deliberately far above Denial's normal traffic. They are
// boundary guards, not protocol limits: a corrupt/pathological engine message
// must not turn one callback into an effectively unbounded allocation or
// `from_raw_parts` length.
const MAX_FLUTTER_DAMAGE_RECTS: usize = 4_096;
const MAX_PLATFORM_MESSAGE_BYTES: usize = 4 * 1024 * 1024;
const MAX_IN_FLIGHT_PLATFORM_MESSAGE_BYTES: usize = 16 * 1024 * 1024;
const MAX_IN_FLIGHT_PLATFORM_MESSAGES: usize = 256;
const MAX_PLATFORM_CHANNEL_BYTES: usize = 1_024;
const MAX_GL_PROC_NAME_BYTES: usize = 1_024;
const MAX_FLUTTER_LOG_TAG_BYTES: usize = 1_024;
const MAX_FLUTTER_LOG_MESSAGE_BYTES: usize = 64 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ScheduledTask {
    pub runner: usize,
    pub task: u64,
    pub target_time_nanos: u64,
}

impl ScheduledTask {
    fn as_flutter_task(self) -> sys::FlutterTask {
        sys::FlutterTask {
            runner: self.runner as sys::FlutterTaskRunner,
            task: self.task,
        }
    }
}

#[derive(Debug)]
pub struct PlatformMessage {
    pub channel: String,
    pub data: Vec<u8>,
    response_handle: usize,
    _budget: PlatformMessageBudgetPermit,
}

impl Drop for PlatformMessage {
    fn drop(&mut self) {
        self._budget
            .budget
            .release_storage(mem::take(&mut self.channel), mem::take(&mut self.data));
    }
}

#[derive(Debug)]
pub enum EngineEvent {
    PlatformTask(ScheduledTask),
    Vsync(isize),
    PlatformMessage(PlatformMessage),
}

#[derive(Clone, Copy)]
pub struct PresentFrame<'a> {
    pub framebuffer: u32,
    pub frame_damage: &'a [sys::FlutterRect],
    pub buffer_damage: &'a [sys::FlutterRect],
}

pub trait OpenGlHandler: Send + Sync + 'static {
    fn make_current(&self) -> bool;
    fn clear_current(&self) -> bool;
    fn make_resource_current(&self) -> bool;
    fn framebuffer(&self, width: u32, height: u32) -> u32;
    fn present(&self, frame: PresentFrame<'_>) -> bool;
    fn populate_existing_damage(&self, framebuffer: isize, damage: &mut Vec<sys::FlutterRect>);
    fn resolve_proc(&self, name: &CStr) -> *mut c_void;
    fn event(&self, event: EngineEvent);

    /// Runs on Flutter's render thread after every raster task which was
    /// queued before the sentinel. Embedders use this to close transactions
    /// that legitimately produced no present callback.
    fn raster_idle(&self) {}

    fn populate_external_texture(
        &self,
        _texture_id: i64,
        _width: usize,
        _height: usize,
        _texture: &mut sys::FlutterOpenGLTexture,
    ) -> bool {
        false
    }

    fn surface_transformation(&self) -> sys::FlutterTransformation {
        sys::FlutterTransformation {
            scaleX: 1.0,
            skewX: 0.0,
            transX: 0.0,
            skewY: 0.0,
            scaleY: 1.0,
            transY: 0.0,
            pers0: 0.0,
            pers1: 0.0,
            pers2: 1.0,
        }
    }

    fn log(&self, tag: &str, message: &str) {
        if tag.is_empty() {
            eprintln!("flutter: {message}");
        } else {
            eprintln!("flutter[{tag}]: {message}");
        }
    }
}

#[derive(Clone, Debug)]
pub struct EngineProject {
    pub engine_library: PathBuf,
    pub assets: PathBuf,
    pub icu_data: PathBuf,
    pub aot_library: PathBuf,
}

#[derive(Debug)]
pub enum HostError {
    Load(LoadError),
    Engine(EngineError),
    PathContainsNul { field: &'static str, path: PathBuf },
}

impl fmt::Display for HostError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Load(error) => error.fmt(formatter),
            Self::Engine(error) => error.fmt(formatter),
            Self::PathContainsNul { field, path } => {
                write!(
                    formatter,
                    "Flutter {field} path contains a NUL: {}",
                    path.display()
                )
            }
        }
    }
}

impl Error for HostError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Load(error) => Some(error),
            Self::Engine(error) => Some(error),
            Self::PathContainsNul { .. } => None,
        }
    }
}

impl From<LoadError> for HostError {
    fn from(error: LoadError) -> Self {
        Self::Load(error)
    }
}

impl From<EngineError> for HostError {
    fn from(error: EngineError) -> Self {
        Self::Engine(error)
    }
}

struct CallbackState {
    handler: Arc<dyn OpenGlHandler>,
    platform_thread: ThreadId,
    platform_message_budget: Arc<PlatformMessageBudget>,
    engine_handle: AtomicUsize,
    post_render_thread_task: unsafe extern "C" fn(
        sys::FlutterEngine,
        sys::VoidCallback,
        *mut c_void,
    ) -> sys::FlutterEngineResult,
    raster_sentinel_pending: AtomicBool,
}

#[derive(Debug, Default)]
struct PlatformMessageStoragePoolState {
    entries: Vec<(String, Vec<u8>)>,
    retained_bytes: usize,
}

impl PlatformMessageBudget {
    fn acquire_storage(&self) -> (String, Vec<u8>) {
        let mut state = self
            .storage
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let Some((channel, payload)) = state.entries.pop() else {
            return (String::new(), Vec::new());
        };
        state.retained_bytes = state
            .retained_bytes
            .saturating_sub(channel.capacity().saturating_add(payload.capacity()));
        (channel, payload)
    }

    fn release_storage(&self, mut channel: String, mut payload: Vec<u8>) {
        channel.clear();
        payload.clear();
        let retained = channel.capacity().saturating_add(payload.capacity());
        let mut state = self
            .storage
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let Some(next_retained) = state.retained_bytes.checked_add(retained) else {
            return;
        };
        if state.entries.len() >= MAX_IN_FLIGHT_PLATFORM_MESSAGES
            || next_retained > MAX_IN_FLIGHT_PLATFORM_MESSAGE_BYTES
        {
            return;
        }
        state.entries.push((channel, payload));
        state.retained_bytes = next_retained;
    }
}

#[derive(Debug, Default)]
struct PlatformMessageBudget {
    messages: AtomicUsize,
    bytes: AtomicUsize,
    storage: Mutex<PlatformMessageStoragePoolState>,
}

impl PlatformMessageBudget {
    fn try_acquire(self: &Arc<Self>, bytes: usize) -> Option<PlatformMessageBudgetPermit> {
        if bytes > MAX_IN_FLIGHT_PLATFORM_MESSAGE_BYTES {
            return None;
        }
        self.messages
            // These atomics enforce quotas only. The message owns its storage
            // through Arc and crosses threads through the embedder handler.
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |messages| {
                (messages < MAX_IN_FLIGHT_PLATFORM_MESSAGES).then_some(messages + 1)
            })
            .ok()?;
        if self
            .bytes
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |in_flight| {
                in_flight
                    .checked_add(bytes)
                    .filter(|total| *total <= MAX_IN_FLIGHT_PLATFORM_MESSAGE_BYTES)
            })
            .is_err()
        {
            self.messages.fetch_sub(1, Ordering::Relaxed);
            return None;
        }
        Some(PlatformMessageBudgetPermit {
            budget: Arc::clone(self),
            bytes,
        })
    }
}

#[derive(Debug)]
struct PlatformMessageBudgetPermit {
    budget: Arc<PlatformMessageBudget>,
    bytes: usize,
}

impl Drop for PlatformMessageBudgetPermit {
    fn drop(&mut self) {
        self.budget.bytes.fetch_sub(self.bytes, Ordering::Relaxed);
        self.budget.messages.fetch_sub(1, Ordering::Relaxed);
    }
}

thread_local! {
    static EXISTING_DAMAGE: RefCell<Vec<sys::FlutterRect>> = const { RefCell::new(Vec::new()) };
}

struct EngineHostState {
    engine: Option<RunningEngine>,
    _library: Arc<EngineLibrary>,
    _callback_state: Box<CallbackState>,
    _renderer: Box<sys::FlutterRendererConfig>,
    _platform_runner: Box<sys::FlutterTaskRunnerDescription>,
    _custom_runners: Box<sys::FlutterCustomTaskRunners>,
    _project_args: Box<sys::FlutterProjectArgs>,
    _assets: CString,
    _icu_data: CString,
    _argv: Vec<CString>,
    _argv_pointers: Vec<*const std::ffi::c_char>,
}

pub struct EngineHost {
    /// Everything reachable through pointers retained by Flutter lives in one
    /// allocation. A failed FlutterEngineShutdown does not prove that the
    /// engine stopped using any of it, so the whole allocation is leaked as a
    /// unit on that error path.
    state: Option<Box<EngineHostState>>,
}

impl EngineHost {
    pub fn start(
        project: &EngineProject,
        handler: Arc<dyn OpenGlHandler>,
    ) -> Result<Self, HostError> {
        let library = Arc::new(EngineLibrary::load(&project.engine_library)?);
        Self::start_with_library(project, handler, library)
    }

    /// Starts an engine using a library whose lifetime is owned by the caller
    /// as well as the host. Keeping this `Arc` across sequential engine
    /// instances avoids unloading Flutter while its process-global workers are
    /// winding down during an embedder restart.
    pub fn start_with_library(
        project: &EngineProject,
        handler: Arc<dyn OpenGlHandler>,
        library: Arc<EngineLibrary>,
    ) -> Result<Self, HostError> {
        let aot_data = library.create_aot_data(&project.aot_library)?;
        let assets = path_cstring("assets", &project.assets)?;
        let icu_data = path_cstring("ICU", &project.icu_data)?;
        let argv = vec![CString::new("deniald").expect("static argv has no NUL")];
        let argv_pointers = argv
            .iter()
            .map(|argument| argument.as_ptr())
            .collect::<Vec<_>>();

        let mut callback_state = Box::new(CallbackState {
            handler,
            platform_thread: thread::current().id(),
            platform_message_budget: Arc::new(PlatformMessageBudget::default()),
            engine_handle: AtomicUsize::new(0),
            post_render_thread_task: library
                .proc_table()
                .PostRenderThreadTask
                .expect("validated Flutter proc table"),
            raster_sentinel_pending: AtomicBool::new(false),
        });
        let state = (&mut *callback_state as *mut CallbackState).cast::<c_void>();

        let open_gl = sys::FlutterOpenGLRendererConfig {
            struct_size: mem::size_of::<sys::FlutterOpenGLRendererConfig>(),
            make_current: Some(make_current),
            clear_current: Some(clear_current),
            present: None,
            fbo_callback: None,
            make_resource_current: Some(make_resource_current),
            fbo_reset_after_present: true,
            surface_transformation: Some(surface_transformation),
            gl_proc_resolver: Some(resolve_proc),
            gl_external_texture_frame_callback: Some(populate_external_texture),
            fbo_with_frame_info_callback: Some(framebuffer),
            present_with_info: Some(present),
            populate_existing_damage: Some(populate_existing_damage),
        };
        let renderer = Box::new(sys::FlutterRendererConfig {
            type_: sys::FlutterRendererType_kOpenGL,
            __bindgen_anon_1: sys::FlutterRendererConfig__bindgen_ty_1 { open_gl },
        });
        let platform_runner = Box::new(sys::FlutterTaskRunnerDescription {
            struct_size: mem::size_of::<sys::FlutterTaskRunnerDescription>(),
            user_data: state,
            runs_task_on_current_thread_callback: Some(runs_task_on_current_thread),
            post_task_callback: Some(post_task),
            identifier: state as usize,
            destruction_callback: None,
        });
        let custom_runners = Box::new(sys::FlutterCustomTaskRunners {
            struct_size: mem::size_of::<sys::FlutterCustomTaskRunners>(),
            platform_task_runner: &*platform_runner,
            render_task_runner: ptr::null(),
            thread_priority_setter: None,
            ui_task_runner: ptr::null(),
        });
        let project_args = Box::new(sys::FlutterProjectArgs {
            struct_size: mem::size_of::<sys::FlutterProjectArgs>(),
            assets_path: assets.as_ptr(),
            icu_data_path: icu_data.as_ptr(),
            // AOT data is owned by this host and collected after shutdown.
            // Flutter only permits that when every engine using the mapping
            // opts into a full Dart VM shutdown; otherwise process-global VM
            // workers may still be executing instructions from the mapping.
            shutdown_dart_vm_when_done: true,
            command_line_argc: i32::try_from(argv_pointers.len()).expect("one argv entry"),
            command_line_argv: argv_pointers.as_ptr(),
            platform_message_callback: Some(platform_message),
            vsync_callback: Some(request_vsync),
            custom_task_runners: &*custom_runners,
            log_message_callback: Some(log_message),
            ..sys::FlutterProjectArgs::default()
        });

        // SAFETY: every callback pointer references `callback_state`, whose
        // allocation is retained by the returned host until after shutdown.
        let engine = unsafe { library.run(&renderer, &project_args, state, aot_data)? };
        callback_state
            .engine_handle
            .store(engine.raw_handle() as usize, Ordering::Release);
        Ok(Self {
            state: Some(Box::new(EngineHostState {
                engine: Some(engine),
                _library: library,
                _callback_state: callback_state,
                _renderer: renderer,
                _platform_runner: platform_runner,
                _custom_runners: custom_runners,
                _project_args: project_args,
                _assets: assets,
                _icu_data: icu_data,
                _argv: argv,
                _argv_pointers: argv_pointers,
            })),
        })
    }

    pub fn engine(&self) -> &RunningEngine {
        self.state
            .as_deref()
            .and_then(|state| state.engine.as_ref())
            .expect("Flutter engine is shut down")
    }

    pub fn run_scheduled_task(&self, task: ScheduledTask) -> Result<(), EngineError> {
        self.engine().run_task(&task.as_flutter_task())
    }

    pub fn respond(&self, message: &mut PlatformMessage, data: &[u8]) -> Result<(), EngineError> {
        // Flutter response handles are one-shot opaque capabilities. Taking
        // the handle before entering C prevents accidental retries/double use
        // through the safe Rust API, including when Flutter returns an error.
        let response_handle = mem::take(&mut message.response_handle);
        self.engine()
            .send_platform_message_response(response_handle, data)
    }

    pub fn shutdown(mut self) -> Result<(), EngineError> {
        self.shutdown_state()
    }

    fn shutdown_state(&mut self) -> Result<(), EngineError> {
        let Some(mut state) = self.state.take() else {
            return Ok(());
        };
        let result = state
            .engine
            .as_mut()
            .map_or(Ok(()), RunningEngine::shutdown_in_place);
        if result.is_ok() {
            state
                ._callback_state
                .engine_handle
                .store(0, Ordering::Release);
        }
        release_or_leak(state, result)
    }
}

impl Drop for EngineHost {
    fn drop(&mut self) {
        // `shutdown_state` removes ownership before calling Flutter. On
        // failure it leaks that ownership, so returning from Drop cannot issue
        // a second shutdown or free memory still reachable by engine workers.
        let _ = self.shutdown_state();
    }
}

fn release_or_leak<T, E>(owner: T, result: Result<(), E>) -> Result<(), E> {
    if result.is_err() {
        // FlutterEngineShutdown returning an error gives us no lifetime
        // guarantee whatsoever. Leaking is bounded by process lifetime and is
        // the only sound option: the compositor aborts its runtime loop after
        // propagating this error, and the OS reclaims the allocation.
        mem::forget(owner);
    }
    result
}

fn path_cstring(field: &'static str, path: &Path) -> Result<CString, HostError> {
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        CString::new(path.as_os_str().as_bytes()).map_err(|_| HostError::PathContainsNul {
            field,
            path: path.to_owned(),
        })
    }
}

fn dispatch<R>(data: *mut c_void, fallback: R, callback: impl FnOnce(&CallbackState) -> R) -> R {
    if data.is_null() {
        return fallback;
    }
    catch_ffi_unwind(fallback, || {
        // SAFETY: every trampoline receives the stable CallbackState pointer
        // installed by EngineHost and EngineHost shuts the engine down before
        // dropping that allocation.
        let state = unsafe { &*data.cast::<CallbackState>() };
        callback(state)
    })
}

fn catch_ffi_unwind<R>(fallback: R, callback: impl FnOnce() -> R) -> R {
    match catch_unwind(AssertUnwindSafe(callback)) {
        Ok(value) => value,
        Err(payload) => {
            // Dropping an arbitrary `panic_any` payload may itself panic. It
            // therefore cannot happen after the unwind was caught at an FFI
            // boundary. This leaks only the exceptional panic payload.
            mem::forget(payload);
            fallback
        }
    }
}

unsafe extern "C" fn make_current(data: *mut c_void) -> bool {
    dispatch(data, false, |state| {
        let current = state.handler.make_current();
        if current {
            queue_raster_sentinel(state, data);
        }
        current
    })
}

unsafe extern "C" fn clear_current(data: *mut c_void) -> bool {
    dispatch(data, false, |state| state.handler.clear_current())
}

unsafe extern "C" fn make_resource_current(data: *mut c_void) -> bool {
    dispatch(data, false, |state| state.handler.make_resource_current())
}

unsafe extern "C" fn framebuffer(data: *mut c_void, info: *const sys::FlutterFrameInfo) -> u32 {
    if info.is_null() {
        return 0;
    }
    dispatch(data, 0, |state| {
        // SAFETY: Flutter owns a readable frame-info struct for this call.
        let info = unsafe { &*info };
        if info.struct_size < mem::size_of::<sys::FlutterFrameInfo>() {
            return 0;
        }
        state.handler.framebuffer(info.size.width, info.size.height)
    })
}

unsafe extern "C" fn present(data: *mut c_void, info: *const sys::FlutterPresentInfo) -> bool {
    if info.is_null() {
        return false;
    }
    dispatch(data, false, |state| {
        // SAFETY: Flutter owns a readable present-info struct and damage
        // arrays for the duration of this callback.
        let info = unsafe { &*info };
        if info.struct_size < mem::size_of::<sys::FlutterPresentInfo>() {
            return false;
        }
        // SAFETY: `info` was validated above and Flutter keeps the referenced
        // damage array readable for the duration of present().
        let Some(frame_damage) = (unsafe { damage_slice(&info.frame_damage) }) else {
            return false;
        };
        // SAFETY: same callback-lifetime guarantee as `frame_damage`; the
        // helper additionally validates pointer, alignment and element count.
        let Some(buffer_damage) = (unsafe { damage_slice(&info.buffer_damage) }) else {
            return false;
        };
        state.handler.present(PresentFrame {
            framebuffer: info.fbo_id,
            frame_damage,
            buffer_damage,
        })
    })
}

unsafe fn damage_slice(damage: &sys::FlutterDamage) -> Option<&[sys::FlutterRect]> {
    if damage.struct_size < mem::size_of::<sys::FlutterDamage>() {
        return None;
    }
    if damage.num_rects == 0 {
        return Some(&[]);
    }
    if damage.damage.is_null()
        || damage.num_rects > MAX_FLUTTER_DAMAGE_RECTS
        || !(damage.damage as usize).is_multiple_of(mem::align_of::<sys::FlutterRect>())
    {
        return None;
    }
    // SAFETY: Flutter guarantees a readable array for present(); the checks
    // above additionally keep the Rust slice length bounded and well-formed.
    Some(unsafe { slice::from_raw_parts(damage.damage, damage.num_rects) })
}

unsafe extern "C" fn populate_existing_damage(
    data: *mut c_void,
    framebuffer: isize,
    damage: *mut sys::FlutterDamage,
) {
    if damage.is_null() {
        return;
    }
    // Leave a valid empty result even if the Rust handler panics.
    // SAFETY: Flutter supplied this full-size writable out-parameter for the
    // callback and retains exclusive access until this function returns.
    unsafe {
        (*damage).struct_size = mem::size_of::<sys::FlutterDamage>();
        (*damage).num_rects = 0;
        (*damage).damage = ptr::null_mut();
    }
    dispatch(data, (), |state| {
        EXISTING_DAMAGE.with(|storage| {
            let mut storage = storage.borrow_mut();
            storage.clear();
            state
                .handler
                .populate_existing_damage(framebuffer, &mut storage);
            // SAFETY: Flutter supplied a writable damage out-parameter. TLS
            // storage keeps the returned array alive beyond this callback.
            unsafe {
                (*damage).struct_size = mem::size_of::<sys::FlutterDamage>();
                (*damage).num_rects = storage.len();
                (*damage).damage = if storage.is_empty() {
                    ptr::null_mut()
                } else {
                    storage.as_mut_ptr()
                };
            }
        });
    });
}

unsafe extern "C" fn resolve_proc(data: *mut c_void, name: *const std::ffi::c_char) -> *mut c_void {
    if name.is_null() {
        return ptr::null_mut();
    }
    dispatch(data, ptr::null_mut(), |state| {
        // SAFETY: Flutter supplies a readable NUL-terminated procedure name.
        let Some(name) = (unsafe { bounded_c_str(name, MAX_GL_PROC_NAME_BYTES) }) else {
            return ptr::null_mut();
        };
        state.handler.resolve_proc(name)
    })
}

unsafe extern "C" fn surface_transformation(data: *mut c_void) -> sys::FlutterTransformation {
    dispatch(data, identity_transformation(), |state| {
        state.handler.surface_transformation()
    })
}

fn identity_transformation() -> sys::FlutterTransformation {
    sys::FlutterTransformation {
        scaleX: 1.0,
        skewX: 0.0,
        transX: 0.0,
        skewY: 0.0,
        scaleY: 1.0,
        transY: 0.0,
        pers0: 0.0,
        pers1: 0.0,
        pers2: 1.0,
    }
}

unsafe extern "C" fn runs_task_on_current_thread(data: *mut c_void) -> bool {
    dispatch(data, false, |state| {
        thread::current().id() == state.platform_thread
    })
}

unsafe extern "C" fn post_task(task: sys::FlutterTask, target_time_nanos: u64, data: *mut c_void) {
    dispatch(data, (), |state| {
        state
            .handler
            .event(EngineEvent::PlatformTask(ScheduledTask {
                runner: task.runner as usize,
                task: task.task,
                target_time_nanos,
            }));
    });
}

unsafe extern "C" fn request_vsync(data: *mut c_void, baton: isize) {
    dispatch(data, (), |state| {
        state.handler.event(EngineEvent::Vsync(baton));
        queue_raster_sentinel(state, data);
    });
}

fn queue_raster_sentinel(state: &CallbackState, data: *mut c_void) {
    if state
        .raster_sentinel_pending
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return;
    }
    let handle = state.engine_handle.load(Ordering::Acquire);
    if handle == 0 {
        state
            .raster_sentinel_pending
            .store(false, Ordering::Release);
        return;
    }
    // SAFETY: the handle belongs to the live engine retaining `data`; the
    // callback state outlives every render-thread task until shutdown joins
    // that thread.
    let result = unsafe {
        (state.post_render_thread_task)(handle as sys::FlutterEngine, Some(raster_idle), data)
    };
    if result != sys::FlutterEngineResult_kSuccess {
        state
            .raster_sentinel_pending
            .store(false, Ordering::Release);
        state.handler.raster_idle();
    }
}

unsafe extern "C" fn raster_idle(data: *mut c_void) {
    dispatch(data, (), |state| {
        state
            .raster_sentinel_pending
            .store(false, Ordering::Release);
        state.handler.raster_idle();
    });
}

unsafe extern "C" fn populate_external_texture(
    data: *mut c_void,
    texture_id: i64,
    width: usize,
    height: usize,
    texture: *mut sys::FlutterOpenGLTexture,
) -> bool {
    if texture.is_null() {
        return false;
    }
    dispatch(data, false, |state| {
        // SAFETY: Flutter supplies a writable texture out-pointer for the
        // duration of this synchronous callback.
        let texture = unsafe { &mut *texture };
        state
            .handler
            .populate_external_texture(texture_id, width, height, texture)
    })
}

unsafe extern "C" fn platform_message(
    message: *const sys::FlutterPlatformMessage,
    data: *mut c_void,
) {
    if message.is_null() {
        return;
    }
    dispatch(data, (), |state| {
        // SAFETY: Flutter owns this message and all fields for the callback.
        let message = unsafe { &*message };
        if message.struct_size < mem::size_of::<sys::FlutterPlatformMessage>() {
            return;
        }
        let channel = if message.channel.is_null() {
            None
        } else {
            // SAFETY: Flutter owns a readable NUL-terminated channel name and
            // payload for this callback.
            unsafe { bounded_c_str(message.channel, MAX_PLATFORM_CHANNEL_BYTES) }
        };
        let decoded_size = channel.and_then(|channel| {
            valid_platform_payload_length(message.message, message.message_size)?;
            channel.to_bytes().len().checked_add(message.message_size)
        });
        // Count rejected messages too, so a Dart flood of invalid/oversized
        // packets cannot bypass the aggregate queue bound. Once saturated we
        // drop the pathological request rather than risk compositor-wide OOM.
        let Some(budget) = state
            .platform_message_budget
            .try_acquire(decoded_size.unwrap_or(0))
        else {
            return;
        };
        let (mut decoded_channel, mut payload) = state.platform_message_budget.acquire_storage();
        let decoded = decoded_size.and_then(|_| {
            let channel = channel?;
            decoded_channel.clear();
            match channel.to_str() {
                Ok(channel) => decoded_channel.push_str(channel),
                Err(_) => decoded_channel.push_str(&channel.to_string_lossy()),
            }
            // SAFETY: the null/length pair was validated above and Flutter
            // owns the payload for this callback.
            unsafe {
                copy_platform_payload_into(message.message, message.message_size, &mut payload)
            }?;
            Some(())
        });
        // Preserve the response handle when rejecting malformed/oversized
        // input. The runtime will consume it, while an empty channel routes
        // the rejected payload to no plugin.
        if decoded.is_none() {
            decoded_channel.clear();
            payload.clear();
        }
        state
            .handler
            .event(EngineEvent::PlatformMessage(PlatformMessage {
                channel: decoded_channel,
                data: payload,
                response_handle: message.response_handle as usize,
                _budget: budget,
            }));
    });
}

unsafe extern "C" fn log_message(
    tag: *const std::ffi::c_char,
    message: *const std::ffi::c_char,
    data: *mut c_void,
) {
    dispatch(data, (), |state| {
        let tag = if tag.is_null() {
            String::new()
        } else {
            // SAFETY: Flutter log strings are readable and NUL-terminated for
            // this callback. Rejecting an oversized string bounds both scan
            // time and UTF-8 replacement allocation.
            unsafe { bounded_c_str(tag, MAX_FLUTTER_LOG_TAG_BYTES) }
                .map_or_else(String::new, |tag| tag.to_string_lossy().into_owned())
        };
        let message = if message.is_null() {
            String::new()
        } else {
            // SAFETY: Flutter log strings are readable and NUL-terminated for
            // this callback; the helper stops scanning at the explicit cap.
            unsafe { bounded_c_str(message, MAX_FLUTTER_LOG_MESSAGE_BYTES) }.map_or_else(
                || String::from("<oversized Flutter log message>"),
                |message| message.to_string_lossy().into_owned(),
            )
        };
        state.handler.log(&tag, &message);
    });
}

unsafe fn bounded_c_str<'a>(value: *const std::ffi::c_char, max_bytes: usize) -> Option<&'a CStr> {
    if value.is_null() {
        return None;
    }
    for length in 0..=max_bytes {
        // SAFETY: the Flutter C API guarantees that `value` is readable up to
        // its NUL terminator; reading stops at that terminator or our cap.
        if unsafe { value.add(length).read() } == 0 {
            // SAFETY: the loop just found the sole required trailing NUL and
            // every preceding byte belongs to the same C string.
            let bytes = unsafe { slice::from_raw_parts(value.cast::<u8>(), length + 1) };
            // SAFETY: `bytes` ends at the first NUL observed by the loop, so
            // it contains one trailing NUL and no interior NUL bytes.
            return Some(unsafe { CStr::from_bytes_with_nul_unchecked(bytes) });
        }
    }
    None
}

unsafe fn copy_platform_payload_into(
    value: *const u8,
    length: usize,
    output: &mut Vec<u8>,
) -> Option<()> {
    valid_platform_payload_length(value, length)?;
    output.clear();
    if length == 0 {
        return Some(());
    }
    output.try_reserve_exact(length).ok()?;
    // SAFETY: Flutter owns a readable `length`-byte payload for this callback;
    // the cap also makes the slice length valid for Rust.
    output.extend_from_slice(unsafe { slice::from_raw_parts(value, length) });
    Some(())
}

#[cfg(test)]
unsafe fn copy_platform_payload(value: *const u8, length: usize) -> Option<Vec<u8>> {
    let mut payload = Vec::new();
    // SAFETY: the caller upholds the same pointer contract forwarded to the
    // production helper.
    unsafe { copy_platform_payload_into(value, length, &mut payload) }?;
    Some(payload)
}

fn valid_platform_payload_length(value: *const u8, length: usize) -> Option<()> {
    if length > MAX_PLATFORM_MESSAGE_BYTES || (value.is_null() && length != 0) {
        None
    } else {
        Some(())
    }
}

#[cfg(test)]
mod tests {
    use std::ffi::CString;
    use std::ptr::{self, NonNull};
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;

    struct DropProbe(&'static AtomicUsize);

    impl Drop for DropProbe {
        fn drop(&mut self) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }

    #[test]
    fn successful_shutdown_releases_the_lifetime_graph() {
        static DROPS: AtomicUsize = AtomicUsize::new(0);
        DROPS.store(0, Ordering::SeqCst);

        assert_eq!(release_or_leak(DropProbe(&DROPS), Ok::<(), ()>(())), Ok(()));
        assert_eq!(DROPS.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn failed_shutdown_leaks_the_lifetime_graph() {
        static DROPS: AtomicUsize = AtomicUsize::new(0);
        DROPS.store(0, Ordering::SeqCst);

        assert_eq!(release_or_leak(DropProbe(&DROPS), Err::<(), _>(7)), Err(7));
        assert_eq!(DROPS.load(Ordering::SeqCst), 0);
    }

    struct PanicsOnDrop;

    impl Drop for PanicsOnDrop {
        fn drop(&mut self) {
            panic!("panic payload was dropped outside the FFI catch");
        }
    }

    #[test]
    fn ffi_guard_does_not_drop_a_hostile_panic_payload() {
        let fallback = catch_ffi_unwind(37, || std::panic::panic_any(PanicsOnDrop));
        assert_eq!(fallback, 37);
    }

    #[test]
    fn damage_slice_rejects_incoherent_and_pathological_lengths() {
        let mut rect = sys::FlutterRect {
            left: 0.0,
            top: 0.0,
            right: 1.0,
            bottom: 1.0,
        };
        let valid = sys::FlutterDamage {
            struct_size: mem::size_of::<sys::FlutterDamage>(),
            num_rects: 1,
            damage: &mut rect,
        };
        // SAFETY: `damage` points to the aligned local `rect`, which remains
        // readable for the declared single-element slice throughout the call.
        assert_eq!(unsafe { damage_slice(&valid) }.map(<[_]>::len), Some(1));

        let null_nonempty = sys::FlutterDamage {
            num_rects: 1,
            damage: ptr::null_mut(),
            ..valid
        };
        // SAFETY: the null/non-empty pair is deliberately invalid, but
        // damage_slice rejects it before constructing or reading a slice.
        assert!(unsafe { damage_slice(&null_nonempty) }.is_none());

        let oversized = sys::FlutterDamage {
            num_rects: MAX_FLUTTER_DAMAGE_RECTS + 1,
            damage: NonNull::<sys::FlutterRect>::dangling().as_ptr(),
            ..valid
        };
        // SAFETY: the oversized length is rejected before the aligned
        // dangling sentinel can be dereferenced.
        assert!(unsafe { damage_slice(&oversized) }.is_none());

        let short_struct = sys::FlutterDamage {
            struct_size: mem::size_of::<usize>(),
            num_rects: 0,
            damage: ptr::null_mut(),
        };
        // SAFETY: `short_struct` is a live Rust value; its advertised short
        // ABI size makes damage_slice return before inspecting the pointer.
        assert!(unsafe { damage_slice(&short_struct) }.is_none());
    }

    #[test]
    fn inbound_strings_and_payloads_are_bounded_before_copying() {
        let channel = CString::new("denial/native").expect("static test channel has no NUL");
        assert_eq!(
            // SAFETY: channel owns a live NUL-terminated allocation for the
            // duration of the bounded scan.
            unsafe { bounded_c_str(channel.as_ptr(), MAX_PLATFORM_CHANNEL_BYTES) },
            Some(channel.as_c_str())
        );

        let oversized_channel = CString::new(vec![b'x'; MAX_PLATFORM_CHANNEL_BYTES + 1])
            .expect("test channel has no interior NUL");
        assert!(
            // SAFETY: the CString allocation contains more than every byte
            // examined up to the cap, including a later trailing NUL.
            unsafe { bounded_c_str(oversized_channel.as_ptr(), MAX_PLATFORM_CHANNEL_BYTES) }
                .is_none()
        );

        let bytes = [1_u8, 2, 3];
        assert_eq!(
            // SAFETY: bytes.as_ptr() is readable for bytes.len() bytes and the
            // array outlives the copy.
            unsafe { copy_platform_payload(bytes.as_ptr(), bytes.len()) },
            Some(bytes.to_vec())
        );
        // SAFETY: the invalid null/non-empty pair is rejected by length
        // validation before any source read.
        assert!(unsafe { copy_platform_payload(ptr::null(), 1) }.is_none());
        assert!(
            // SAFETY: the excessive length is rejected before the dangling
            // sentinel pointer can be dereferenced.
            unsafe {
                copy_platform_payload(
                    NonNull::<u8>::dangling().as_ptr(),
                    MAX_PLATFORM_MESSAGE_BYTES + 1,
                )
            }
            .is_none()
        );
    }

    #[test]
    fn platform_message_budget_bounds_count_and_aggregate_bytes() {
        let budget = Arc::new(PlatformMessageBudget::default());
        let full_budget = budget
            .try_acquire(MAX_IN_FLIGHT_PLATFORM_MESSAGE_BYTES)
            .expect("exact byte budget must fit");
        assert!(budget.try_acquire(1).is_none());
        drop(full_budget);

        let permits = (0..MAX_IN_FLIGHT_PLATFORM_MESSAGES)
            .map(|_| budget.try_acquire(0).expect("message count below cap"))
            .collect::<Vec<_>>();
        assert!(budget.try_acquire(0).is_none());
        drop(permits);
        assert!(budget.try_acquire(1).is_some());
    }

    #[test]
    fn platform_message_drop_recycles_channel_and_payload_storage() {
        let budget = Arc::new(PlatformMessageBudget::default());
        let mut channel = String::with_capacity(64);
        channel.push_str("flutter/textinput");
        let mut data = Vec::with_capacity(256);
        data.extend_from_slice(b"editing state");
        let channel_pointer = channel.as_ptr();
        let data_pointer = data.as_ptr();

        drop(PlatformMessage {
            channel,
            data,
            response_handle: 0,
            _budget: budget
                .try_acquire(13)
                .expect("test message fits the in-flight budget"),
        });

        let (channel, data) = budget.acquire_storage();
        assert!(channel.is_empty());
        assert!(data.is_empty());
        assert_eq!(channel.as_ptr(), channel_pointer);
        assert_eq!(data.as_ptr(), data_pointer);
    }
}
