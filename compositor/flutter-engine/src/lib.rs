#![deny(unsafe_op_in_unsafe_fn)]
#![deny(clippy::undocumented_unsafe_blocks)]

use std::error::Error;
use std::ffi::{CStr, CString, c_void};
use std::fmt;
use std::mem;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::Arc;
use std::time::Duration;

use libloading::Library;

mod host;

pub use host::{
    BackingStoreRequest, CompositorBackingStore, DartRuntimeMode, EngineEvent, EngineHost,
    EngineProject, HostError, OpenGlHandler, ParseRendererBackendError, PlatformMessage,
    PresentFrame, PresentView, RendererBackend, ScheduledTask,
};

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RenderOutputTransform {
    pub scale_x: f64,
    pub skew_x: f64,
    pub translate_x: f64,
    pub skew_y: f64,
    pub scale_y: f64,
    pub translate_y: f64,
}

impl RenderOutputTransform {
    fn as_ffi(self) -> sys::FlutterTransformation {
        sys::FlutterTransformation {
            scaleX: self.scale_x,
            skewX: self.skew_x,
            transX: self.translate_x,
            skewY: self.skew_y,
            scaleY: self.scale_y,
            transY: self.translate_y,
            pers0: 0.0,
            pers1: 0.0,
            pers2: 1.0,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RenderOutput {
    pub render_view_id: i64,
    pub configuration_generation: u64,
    pub source_physical_x: f64,
    pub source_physical_y: f64,
    pub source_physical_width: f64,
    pub source_physical_height: f64,
    pub target_width: usize,
    pub target_height: usize,
    pub scale_120: u32,
    pub source_to_target_transform: RenderOutputTransform,
}

impl RenderOutput {
    fn as_ffi(self) -> sys::DenialFlutterRenderOutput {
        sys::DenialFlutterRenderOutput {
            struct_size: mem::size_of::<sys::DenialFlutterRenderOutput>(),
            render_view_id: self.render_view_id,
            configuration_generation: self.configuration_generation,
            source_physical_x: self.source_physical_x,
            source_physical_y: self.source_physical_y,
            source_physical_width: self.source_physical_width,
            source_physical_height: self.source_physical_height,
            target_width: self.target_width,
            target_height: self.target_height,
            scale_120: self.scale_120,
            source_to_target_transform: self.source_to_target_transform.as_ffi(),
        }
    }
}

#[derive(Debug, Default)]
pub struct RenderOutputFfiScratch {
    outputs: Vec<sys::DenialFlutterRenderOutput>,
}

impl RenderOutputFfiScratch {
    pub fn with_capacity(capacity: usize) -> Self {
        Self {
            outputs: Vec::with_capacity(capacity),
        }
    }
}

#[allow(
    clippy::all,
    clippy::undocumented_unsafe_blocks,
    dead_code,
    improper_ctypes,
    non_camel_case_types,
    non_snake_case,
    non_upper_case_globals,
    unsafe_op_in_unsafe_fn
)]
pub mod sys;

#[derive(Debug)]
pub enum LoadError {
    Library {
        path: PathBuf,
        source: libloading::Error,
    },
    Symbol(libloading::Error),
    ProcTable(sys::FlutterEngineResult),
    MissingProc(&'static str),
}

impl fmt::Display for LoadError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Library { path, source } => {
                write!(formatter, "could not load {}: {source}", path.display())
            }
            Self::Symbol(source) => {
                write!(
                    formatter,
                    "required Flutter engine symbol is unavailable: {source}"
                )
            }
            Self::ProcTable(result) => {
                write!(formatter, "Flutter rejected its proc table: {result:?}")
            }
            Self::MissingProc(name) => write!(formatter, "Flutter proc table omitted {name}"),
        }
    }
}

impl Error for LoadError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Library { source, .. } | Self::Symbol(source) => Some(source),
            Self::ProcTable(_) | Self::MissingProc(_) => None,
        }
    }
}

#[derive(Debug)]
pub enum EngineError {
    PathContainsNul(PathBuf),
    LocaleContainsNul(&'static str),
    Call {
        operation: &'static str,
        result: sys::FlutterEngineResult,
    },
    NullHandle(&'static str),
}

impl fmt::Display for EngineError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::PathContainsNul(path) => {
                write!(formatter, "path contains a NUL byte: {}", path.display())
            }
            Self::LocaleContainsNul(field) => {
                write!(formatter, "Flutter locale {field} contains a NUL byte")
            }
            Self::Call { operation, result } => {
                write!(formatter, "Flutter {operation} failed with result {result}")
            }
            Self::NullHandle(operation) => {
                write!(formatter, "Flutter {operation} returned a null handle")
            }
        }
    }
}

impl Error for EngineError {}

pub struct EngineLibrary {
    table: sys::FlutterEngineProcTable,
    set_render_outputs: unsafe extern "C" fn(
        sys::FlutterEngine,
        *const sys::DenialFlutterRenderOutput,
        usize,
    ) -> sys::FlutterEngineResult,
    request_frame_for_external_textures:
        unsafe extern "C" fn(sys::FlutterEngine) -> sys::FlutterEngineResult,
    schedule_frame_for_external_textures:
        unsafe extern "C" fn(sys::FlutterEngine, *const i64, usize) -> sys::FlutterEngineResult,
    render_outputs: unsafe extern "C" fn(
        sys::FlutterEngine,
        *const i64,
        usize,
        *const i64,
        usize,
        bool,
        u64,
        u64,
    ) -> sys::FlutterEngineResult,
    set_external_texture_gl_state_callback: unsafe extern "C" fn(
        sys::FlutterEngine,
        Option<unsafe extern "C" fn(*mut c_void, i64) -> bool>,
        *mut c_void,
    ) -> sys::FlutterEngineResult,
    _library: Library,
}

impl EngineLibrary {
    pub fn load(path: impl AsRef<Path>) -> Result<Self, LoadError> {
        let path = path.as_ref();
        // SAFETY: the library stays owned by `EngineLibrary` for longer than
        // every copied function pointer in its proc table.
        let library = unsafe { Library::new(path) }.map_err(|source| LoadError::Library {
            path: path.to_owned(),
            source,
        })?;
        type GetProcAddresses =
            unsafe extern "C" fn(*mut sys::FlutterEngineProcTable) -> sys::FlutterEngineResult;
        // SAFETY: the symbol name and signature come from the versioned
        // Flutter embedder bindings generated for this engine revision.
        let get_proc_addresses = unsafe {
            *library
                .get::<GetProcAddresses>(b"FlutterEngineGetProcAddresses\0")
                .map_err(LoadError::Symbol)?
        };
        type RequestFrameForExternalTextures =
            unsafe extern "C" fn(sys::FlutterEngine) -> sys::FlutterEngineResult;
        // SAFETY: this Denial-specific symbol is declared by the versioned
        // embedder header shipped with our coupled Flutter engine.
        let request_frame_for_external_textures = unsafe {
            *library
                .get::<RequestFrameForExternalTextures>(
                    b"DenialFlutterEngineRequestFrameForExternalTextures\0",
                )
                .map_err(LoadError::Symbol)?
        };
        type ScheduleFrameForExternalTextures =
            unsafe extern "C" fn(sys::FlutterEngine, *const i64, usize) -> sys::FlutterEngineResult;
        // SAFETY: this Denial-specific symbol is declared by the versioned
        // embedder header shipped with our coupled Flutter engine.
        let schedule_frame_for_external_textures = unsafe {
            *library
                .get::<ScheduleFrameForExternalTextures>(
                    b"DenialFlutterEngineScheduleFrameForExternalTextures\0",
                )
                .map_err(LoadError::Symbol)?
        };
        type RenderOutputs = unsafe extern "C" fn(
            sys::FlutterEngine,
            *const i64,
            usize,
            *const i64,
            usize,
            bool,
            u64,
            u64,
        ) -> sys::FlutterEngineResult;
        // SAFETY: this Denial-specific symbol is declared by the versioned
        // embedder header shipped with our coupled Flutter engine.
        let render_outputs = unsafe {
            *library
                .get::<RenderOutputs>(b"DenialFlutterEngineRenderOutputs\0")
                .map_err(LoadError::Symbol)?
        };
        type SetRenderOutputs = unsafe extern "C" fn(
            sys::FlutterEngine,
            *const sys::DenialFlutterRenderOutput,
            usize,
        ) -> sys::FlutterEngineResult;
        // SAFETY: this Denial-specific symbol is declared by the versioned
        // embedder header shipped with our coupled Flutter engine.
        let set_render_outputs = unsafe {
            *library
                .get::<SetRenderOutputs>(b"DenialFlutterEngineSetRenderOutputs\0")
                .map_err(LoadError::Symbol)?
        };
        type SetExternalTextureGlStateCallback = unsafe extern "C" fn(
            sys::FlutterEngine,
            Option<unsafe extern "C" fn(*mut c_void, i64) -> bool>,
            *mut c_void,
        )
            -> sys::FlutterEngineResult;
        // SAFETY: this callback registration is part of Denial's versioned
        // engine extension and is loaded from the same retained library.
        let set_external_texture_gl_state_callback = unsafe {
            *library
                .get::<SetExternalTextureGlStateCallback>(
                    b"DenialFlutterEngineSetExternalTextureGlStateCallback\0",
                )
                .map_err(LoadError::Symbol)?
        };
        // SAFETY: the C API explicitly requires a zero-initialized table with
        // only `struct_size` populated before the call.
        let mut table: sys::FlutterEngineProcTable = unsafe { mem::zeroed() };
        table.struct_size = mem::size_of::<sys::FlutterEngineProcTable>();
        // SAFETY: `table` is writable and has the exact ABI generated from the
        // engine header checked into this repository.
        let result = unsafe { get_proc_addresses(&mut table) };
        if result != sys::FlutterEngineResult_kSuccess {
            return Err(LoadError::ProcTable(result));
        }
        macro_rules! require_proc {
            ($field:ident) => {
                if table.$field.is_none() {
                    return Err(LoadError::MissingProc(stringify!($field)));
                }
            };
        }
        require_proc!(CreateAOTData);
        require_proc!(CollectAOTData);
        require_proc!(Run);
        require_proc!(Shutdown);
        require_proc!(SendWindowMetricsEvent);
        require_proc!(SendPointerEvent);
        require_proc!(SendKeyEvent);
        require_proc!(SendPlatformMessage);
        require_proc!(SendPlatformMessageResponse);
        require_proc!(RegisterExternalTexture);
        require_proc!(UnregisterExternalTexture);
        require_proc!(MarkExternalTextureFrameAvailable);
        require_proc!(OnVsync);
        require_proc!(PostRenderThreadTask);
        require_proc!(GetCurrentTime);
        require_proc!(RunTask);
        require_proc!(UpdateLocales);
        require_proc!(RunsAOTCompiledDartCode);
        require_proc!(NotifyDisplayUpdate);
        Ok(Self {
            table,
            set_render_outputs,
            request_frame_for_external_textures,
            schedule_frame_for_external_textures,
            render_outputs,
            set_external_texture_gl_state_callback,
            _library: library,
        })
    }

    pub fn runs_aot_compiled_dart_code(&self) -> bool {
        let function = self
            .table
            .RunsAOTCompiledDartCode
            .expect("validated Flutter proc table");
        // SAFETY: the copied pointer remains valid while `_library` is owned.
        unsafe { function() }
    }

    pub fn proc_table(&self) -> &sys::FlutterEngineProcTable {
        &self.table
    }

    pub fn create_aot_data(
        self: &Arc<Self>,
        elf: impl AsRef<Path>,
    ) -> Result<AotData, EngineError> {
        let elf = elf.as_ref();
        let path = CString::new(elf.as_os_str().as_bytes())
            .map_err(|_| EngineError::PathContainsNul(elf.to_owned()))?;
        let source = sys::FlutterEngineAOTDataSource {
            type_: sys::FlutterEngineAOTDataSourceType_kFlutterEngineAOTDataSourceTypeElfPath,
            __bindgen_anon_1: sys::FlutterEngineAOTDataSource__bindgen_ty_1 {
                elf_path: path.as_ptr(),
            },
        };
        let mut data = ptr::null_mut();
        let function = self
            .table
            .CreateAOTData
            .expect("validated Flutter proc table");
        // SAFETY: `source` and its path remain live for the duration of the
        // call and `data` is a writable out-pointer.
        let result = unsafe { function(&source, &mut data) };
        check_result("CreateAOTData", result)?;
        if data.is_null() {
            return Err(EngineError::NullHandle("CreateAOTData"));
        }
        Ok(AotData {
            data,
            library: Arc::clone(self),
        })
    }

    /// Starts an engine whose callbacks may dereference `user_data`.
    ///
    /// # Safety
    ///
    /// The caller must keep `user_data` valid until the returned engine has
    /// shut down. Every callback installed in `renderer` and `args` must obey
    /// Flutter's threading and lifetime contract.
    pub unsafe fn run(
        self: &Arc<Self>,
        renderer: &sys::FlutterRendererConfig,
        args: &sys::FlutterProjectArgs,
        user_data: *mut c_void,
        aot_data: Option<AotData>,
    ) -> Result<RunningEngine, EngineError> {
        let mut project_args = *args;
        project_args.aot_data = aot_data.as_ref().map_or(ptr::null_mut(), AotData::as_raw);
        let mut handle = ptr::null_mut();
        let function = self.table.Run.expect("validated Flutter proc table");
        // SAFETY: upheld by this method's caller; all stack-resident config
        // structures remain live for the synchronous Run call.
        let result = unsafe {
            function(
                sys::FLUTTER_ENGINE_VERSION as usize,
                renderer,
                &project_args,
                user_data,
                &mut handle,
            )
        };
        check_result("Run", result)?;
        if handle.is_null() {
            return Err(EngineError::NullHandle("Run"));
        }
        Ok(RunningEngine {
            handle,
            library: Arc::clone(self),
            aot_data,
        })
    }
}

pub struct AotData {
    data: sys::FlutterEngineAOTData,
    library: Arc<EngineLibrary>,
}

impl AotData {
    pub fn as_raw(&self) -> sys::FlutterEngineAOTData {
        self.data
    }
}

impl Drop for AotData {
    fn drop(&mut self) {
        if self.data.is_null() {
            return;
        }
        let function = self
            .library
            .table
            .CollectAOTData
            .expect("validated Flutter proc table");
        // SAFETY: this handle was returned by CreateAOTData from the same
        // loaded engine and is collected exactly once here.
        let _ = unsafe { function(self.data) };
        self.data = ptr::null_mut();
    }
}

pub struct RunningEngine {
    handle: sys::FlutterEngine,
    library: Arc<EngineLibrary>,
    aot_data: Option<AotData>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EngineLocale {
    language_code: CString,
    country_code: Option<CString>,
    script_code: Option<CString>,
    variant_code: Option<CString>,
}

impl EngineLocale {
    pub fn new(
        language_code: &str,
        country_code: Option<&str>,
        script_code: Option<&str>,
        variant_code: Option<&str>,
    ) -> Result<Self, EngineError> {
        Ok(Self {
            language_code: locale_string("language code", language_code)?,
            country_code: country_code
                .map(|value| locale_string("country code", value))
                .transpose()?,
            script_code: script_code
                .map(|value| locale_string("script code", value))
                .transpose()?,
            variant_code: variant_code
                .map(|value| locale_string("variant code", value))
                .transpose()?,
        })
    }

    pub fn language_code(&self) -> &CStr {
        &self.language_code
    }

    pub fn country_code(&self) -> Option<&CStr> {
        self.country_code.as_deref()
    }

    pub fn script_code(&self) -> Option<&CStr> {
        self.script_code.as_deref()
    }

    pub fn variant_code(&self) -> Option<&CStr> {
        self.variant_code.as_deref()
    }

    fn as_flutter_locale(&self) -> sys::FlutterLocale {
        sys::FlutterLocale {
            struct_size: mem::size_of::<sys::FlutterLocale>(),
            language_code: self.language_code.as_ptr(),
            country_code: self
                .country_code
                .as_ref()
                .map_or(ptr::null(), |value| value.as_ptr()),
            script_code: self
                .script_code
                .as_ref()
                .map_or(ptr::null(), |value| value.as_ptr()),
            variant_code: self
                .variant_code
                .as_ref()
                .map_or(ptr::null(), |value| value.as_ptr()),
        }
    }
}

fn locale_string(field: &'static str, value: &str) -> Result<CString, EngineError> {
    CString::new(value).map_err(|_| EngineError::LocaleContainsNul(field))
}

impl RunningEngine {
    pub(crate) fn raw_handle(&self) -> sys::FlutterEngine {
        self.handle
    }

    /// Installs Denial's synchronous preflight for external-texture resolves.
    /// Returning `false` promises that the immediately following standard
    /// texture callback will not issue GL calls, allowing the engine to retain
    /// Ganesh's command batch and state cache.
    ///
    /// # Safety
    ///
    /// `user_data` must remain valid until engine shutdown and the callback
    /// must not unwind across the C ABI.
    pub(crate) unsafe fn set_external_texture_gl_state_callback(
        &self,
        callback: Option<unsafe extern "C" fn(*mut c_void, i64) -> bool>,
        user_data: *mut c_void,
    ) -> Result<(), EngineError> {
        let function = self.library.set_external_texture_gl_state_callback;
        // SAFETY: upheld by this method's caller; the engine synchronously
        // copies the function and opaque pointer into its retained resolver.
        check_result("SetExternalTextureGlStateCallback", unsafe {
            function(self.handle, callback, user_data)
        })
    }

    pub fn current_time_nanos(&self) -> u64 {
        let function = self
            .library
            .table
            .GetCurrentTime
            .expect("validated Flutter proc table");
        // SAFETY: this proc has no arguments and the engine library is live.
        unsafe { function() }
    }

    /// Atomically replaces the complete physical-output raster snapshot.
    /// Flutter copies the slice before this call returns and installs it on
    /// the raster runner between frame transactions.
    pub fn set_render_outputs(&self, outputs: &[RenderOutput]) -> Result<(), EngineError> {
        let mut scratch = RenderOutputFfiScratch::with_capacity(outputs.len());
        self.set_render_outputs_reusing(outputs, &mut scratch)
    }

    /// Variant for display-clock animation paths which retain their FFI
    /// storage between projection samples.
    pub fn set_render_outputs_reusing(
        &self,
        outputs: &[RenderOutput],
        scratch: &mut RenderOutputFfiScratch,
    ) -> Result<(), EngineError> {
        let function = self.library.set_render_outputs;
        scratch.outputs.clear();
        scratch
            .outputs
            .extend(outputs.iter().copied().map(RenderOutput::as_ffi));
        let pointer = if scratch.outputs.is_empty() {
            ptr::null()
        } else {
            scratch.outputs.as_ptr()
        };
        // SAFETY: the live engine synchronously copies this bounded slice;
        // null is supplied only for the explicitly supported empty snapshot.
        check_result("SetRenderOutputs", unsafe {
            function(self.handle, pointer, scratch.outputs.len())
        })
    }

    pub fn on_vsync(
        &self,
        baton: isize,
        frame_start_nanos: u64,
        frame_target_nanos: u64,
    ) -> Result<(), EngineError> {
        let function = self
            .library
            .table
            .OnVsync
            .expect("validated Flutter proc table");
        // SAFETY: `handle` remains live until shutdown.
        check_result("OnVsync", unsafe {
            function(self.handle, baton, frame_start_nanos, frame_target_nanos)
        })
    }

    pub fn on_vsync_after(&self, baton: isize, interval: Duration) -> Result<(), EngineError> {
        let start = self.current_time_nanos();
        let interval = u64::try_from(interval.as_nanos()).unwrap_or(u64::MAX);
        self.on_vsync(baton, start, start.saturating_add(interval))
    }

    pub fn run_task(&self, task: &sys::FlutterTask) -> Result<(), EngineError> {
        let function = self
            .library
            .table
            .RunTask
            .expect("validated Flutter proc table");
        // SAFETY: `task` came from this engine and is read synchronously.
        check_result("RunTask", unsafe { function(self.handle, task) })
    }

    pub fn update_locales(&self, locales: &[EngineLocale]) -> Result<(), EngineError> {
        let flutter_locales = locales
            .iter()
            .map(EngineLocale::as_flutter_locale)
            .collect::<Vec<_>>();
        let mut locale_pointers = flutter_locales
            .iter()
            .map(std::ptr::from_ref)
            .collect::<Vec<_>>();
        let function = self
            .library
            .table
            .UpdateLocales
            .expect("validated Flutter proc table");
        // SAFETY: Flutter reads the locale structs and their NUL-terminated
        // strings synchronously and does not retain any supplied pointer.
        check_result("UpdateLocales", unsafe {
            function(
                self.handle,
                locale_pointers.as_mut_ptr(),
                locale_pointers.len(),
            )
        })
    }

    pub fn send_window_metrics(
        &self,
        event: &sys::FlutterWindowMetricsEvent,
    ) -> Result<(), EngineError> {
        let function = self
            .library
            .table
            .SendWindowMetricsEvent
            .expect("validated Flutter proc table");
        // SAFETY: the event remains readable for the synchronous call.
        check_result("SendWindowMetricsEvent", unsafe {
            function(self.handle, event)
        })
    }

    pub fn notify_displays(
        &self,
        update_type: sys::FlutterEngineDisplaysUpdateType,
        displays: &[sys::FlutterEngineDisplay],
    ) -> Result<(), EngineError> {
        let function = self
            .library
            .table
            .NotifyDisplayUpdate
            .expect("validated Flutter proc table");
        // SAFETY: the slice remains readable for the synchronous call.
        check_result("NotifyDisplayUpdate", unsafe {
            function(self.handle, update_type, displays.as_ptr(), displays.len())
        })
    }

    pub fn send_pointer_events(
        &self,
        events: &[sys::FlutterPointerEvent],
    ) -> Result<(), EngineError> {
        let function = self
            .library
            .table
            .SendPointerEvent
            .expect("validated Flutter proc table");
        // SAFETY: the slice remains readable for the synchronous call.
        check_result("SendPointerEvent", unsafe {
            function(self.handle, events.as_ptr(), events.len())
        })
    }

    pub fn send_platform_message(&self, channel: &CStr, data: &[u8]) -> Result<(), EngineError> {
        let function = self
            .library
            .table
            .SendPlatformMessage
            .expect("validated Flutter proc table");
        let message = sys::FlutterPlatformMessage {
            struct_size: mem::size_of::<sys::FlutterPlatformMessage>(),
            channel: channel.as_ptr(),
            message: data.as_ptr(),
            message_size: data.len(),
            response_handle: ptr::null(),
        };
        // SAFETY: all pointers in `message` remain valid for the call.
        check_result("SendPlatformMessage", unsafe {
            function(self.handle, &message)
        })
    }

    pub fn send_platform_message_response(
        &self,
        response_handle: usize,
        data: &[u8],
    ) -> Result<(), EngineError> {
        let function = self
            .library
            .table
            .SendPlatformMessageResponse
            .expect("validated Flutter proc table");
        let response_handle = response_handle as *const sys::FlutterPlatformMessageResponseHandle;
        if response_handle.is_null() {
            return Ok(());
        }
        // SAFETY: Flutter supplied this opaque handle in a platform-message
        // callback and owns it until exactly one response is sent.
        check_result("SendPlatformMessageResponse", unsafe {
            function(self.handle, response_handle, data.as_ptr(), data.len())
        })
    }

    pub fn register_external_texture(&self, texture_id: i64) -> Result<(), EngineError> {
        let function = self
            .library
            .table
            .RegisterExternalTexture
            .expect("validated Flutter proc table");
        // SAFETY: the engine handle is live and the identifier is owned by the
        // embedder for this engine instance.
        check_result("RegisterExternalTexture", unsafe {
            function(self.handle, texture_id)
        })
    }

    pub fn unregister_external_texture(&self, texture_id: i64) -> Result<(), EngineError> {
        let function = self
            .library
            .table
            .UnregisterExternalTexture
            .expect("validated Flutter proc table");
        // SAFETY: the engine handle is live; Flutter accepts unregistering a
        // texture previously registered on this same handle.
        check_result("UnregisterExternalTexture", unsafe {
            function(self.handle, texture_id)
        })
    }

    pub fn mark_external_texture_frame_available(
        &self,
        texture_id: i64,
    ) -> Result<(), EngineError> {
        let function = self
            .library
            .table
            .MarkExternalTextureFrameAvailable
            .expect("validated Flutter proc table");
        // SAFETY: the identifier is registered on this live engine.
        check_result("MarkExternalTextureFrameAvailable", unsafe {
            function(self.handle, texture_id)
        })
    }

    /// Requests one texture-only frame without publishing dirty texture IDs.
    /// Denial uses this to obtain AwaitVSync while the previous raster frame
    /// finishes, then publishes the new texture generations at authorization.
    pub fn request_frame_for_external_textures(&self) -> Result<(), EngineError> {
        let function = self.library.request_frame_for_external_textures;
        // SAFETY: the engine handle is live for this synchronous request.
        check_result("RequestFrameForExternalTextures", unsafe {
            function(self.handle)
        })
    }

    /// Schedules one texture-only frame for the complete set of updates
    /// collected by Denial's frame clock. A framework-requested layer-tree
    /// rebuild already pending in Flutter remains authoritative and coalesces
    /// with this request.
    pub fn schedule_frame_for_external_textures(
        &self,
        texture_ids: &[i64],
    ) -> Result<(), EngineError> {
        if texture_ids.is_empty() {
            return Ok(());
        }
        let function = self.library.schedule_frame_for_external_textures;
        // SAFETY: the engine is live and the slice remains readable while the
        // custom API synchronously copies all texture identifiers.
        check_result("ScheduleFrameForExternalTextures", unsafe {
            function(self.handle, texture_ids.as_ptr(), texture_ids.len())
        })
    }

    /// Authorizes exactly the specified physical outputs for one raster
    /// transaction. When `rebuild_scene` is false, the engine reuses the
    /// latest scene without involving Dart.
    pub fn render_outputs(
        &self,
        render_view_ids: &[i64],
        texture_ids: &[i64],
        rebuild_scene: bool,
        frame_start_nanos: u64,
        frame_target_nanos: u64,
    ) -> Result<(), EngineError> {
        if render_view_ids.is_empty() {
            return Ok(());
        }
        let function = self.library.render_outputs;
        let texture_ids_ptr = if texture_ids.is_empty() {
            ptr::null()
        } else {
            texture_ids.as_ptr()
        };
        // SAFETY: the engine is live and both slices remain readable while
        // the custom API synchronously copies their contents.
        check_result("RenderOutputs", unsafe {
            function(
                self.handle,
                render_view_ids.as_ptr(),
                render_view_ids.len(),
                texture_ids_ptr,
                texture_ids.len(),
                rebuild_scene,
                frame_start_nanos,
                frame_target_nanos,
            )
        })
    }

    pub fn shutdown(mut self) -> Result<(), EngineError> {
        let result = self.shutdown_in_place();
        if result.is_err() {
            // Callers using RunningEngine directly do not have another chance
            // to preserve this ownership after the consuming method returns.
            // Keep the handle, AOT mapping and engine library alive forever;
            // EngineHost additionally retains the callback/config graph.
            mem::forget(self);
        }
        result
    }

    pub(crate) fn shutdown_in_place(&mut self) -> Result<(), EngineError> {
        if self.handle.is_null() {
            return Ok(());
        }
        let function = self
            .library
            .table
            .Shutdown
            .expect("validated Flutter proc table");
        // SAFETY: the handle remains live until Flutter confirms successful
        // shutdown. On failure it deliberately remains non-null so its whole
        // ownership graph can be leaked instead of torn down unsafely.
        check_result("Shutdown", unsafe { function(self.handle) })?;
        self.handle = ptr::null_mut();
        Ok(())
    }
}

impl Drop for RunningEngine {
    fn drop(&mut self) {
        if self.shutdown_in_place().is_err() {
            // A direct RunningEngine drop cannot retain the embedder-owned
            // callback pointer, whose lifetime is the unsafe caller's
            // responsibility, but it must at least never unmap AOT code or
            // unload the library while engine workers may still execute it.
            if let Some(aot_data) = self.aot_data.take() {
                mem::forget(aot_data);
            }
        }
    }
}

fn check_result(
    operation: &'static str,
    result: sys::FlutterEngineResult,
) -> Result<(), EngineError> {
    if result == sys::FlutterEngineResult_kSuccess {
        Ok(())
    } else {
        Err(EngineError::Call { operation, result })
    }
}
