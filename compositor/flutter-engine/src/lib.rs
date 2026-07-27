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
    DartRuntimeMode, EngineEvent, EngineHost, EngineProject, HostError, OpenGlHandler,
    PlatformMessage, PresentFrame, ScheduledTask,
};

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
    schedule_frame_for_external_textures:
        unsafe extern "C" fn(sys::FlutterEngine, *const i64, usize) -> sys::FlutterEngineResult,
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
        require_proc!(RunsAOTCompiledDartCode);
        require_proc!(NotifyDisplayUpdate);
        Ok(Self {
            table,
            schedule_frame_for_external_textures,
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

impl RunningEngine {
    pub(crate) fn raw_handle(&self) -> sys::FlutterEngine {
        self.handle
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loads_the_bundled_flutter_engine_abi() {
        let repository = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let bundle = repository.join("dart_shell/build/linux/x64/release/bundle");
        let engine = bundle.join("lib/libflutter_engine.so");
        assert!(engine.is_file(), "repository has no Flutter engine bundle");
        let library = EngineLibrary::load(engine).expect("load bundled Flutter engine");
        assert!(library.runs_aot_compiled_dart_code());
        let library = Arc::new(library);
        let app = bundle.join("lib/libapp.so");
        let _aot = library.create_aot_data(app).expect("load bundled AOT data");
    }
}
