use std::ffi::CString;
use std::ptr::{self, NonNull};
use std::sync::atomic::{AtomicUsize, Ordering};

use super::*;

static POSTED_RASTER_SENTINELS: AtomicUsize = AtomicUsize::new(0);
static POSTED_RASTER_SENTINEL_ENGINE: AtomicUsize = AtomicUsize::new(0);

struct NoopGlHandler;

impl OpenGlHandler for NoopGlHandler {
    fn make_current(&self) -> bool {
        true
    }

    fn clear_current(&self) -> bool {
        true
    }

    fn make_resource_current(&self) -> bool {
        true
    }

    fn framebuffer(&self, _width: u32, _height: u32) -> u32 {
        0
    }

    fn present(&self, _frame: PresentFrame<'_>) -> bool {
        true
    }

    fn populate_existing_damage(&self, _framebuffer: isize, _damage: &mut Vec<sys::FlutterRect>) {}

    fn resolve_proc(&self, _name: &CStr) -> *mut c_void {
        ptr::null_mut()
    }

    fn event(&self, _event: EngineEvent) {}
}

unsafe extern "C" fn record_raster_sentinel(
    engine: sys::FlutterEngine,
    callback: sys::VoidCallback,
    _data: *mut c_void,
) -> sys::FlutterEngineResult {
    POSTED_RASTER_SENTINEL_ENGINE.store(engine as usize, Ordering::SeqCst);
    POSTED_RASTER_SENTINELS.store(usize::from(callback.is_some()), Ordering::SeqCst);
    sys::FlutterEngineResult_kSuccess
}

#[test]
fn publishing_engine_handle_rearms_startup_raster_sentinel() {
    POSTED_RASTER_SENTINELS.store(0, Ordering::SeqCst);
    POSTED_RASTER_SENTINEL_ENGINE.store(0, Ordering::SeqCst);
    let state = CallbackState {
        handler: Arc::new(NoopGlHandler),
        platform_thread: thread::current().id(),
        platform_message_budget: Arc::new(PlatformMessageBudget::default()),
        engine_handle: AtomicUsize::new(0),
        post_render_thread_task: record_raster_sentinel,
        raster_sentinel_pending: AtomicBool::new(false),
    };
    let data = ptr::from_ref(&state).cast_mut().cast::<c_void>();

    queue_raster_sentinel(&state, data);
    assert_eq!(POSTED_RASTER_SENTINELS.load(Ordering::SeqCst), 0);
    assert!(!state.raster_sentinel_pending.load(Ordering::SeqCst));

    publish_engine_handle(&state, 37, data);
    assert_eq!(POSTED_RASTER_SENTINELS.load(Ordering::SeqCst), 1);
    assert_eq!(POSTED_RASTER_SENTINEL_ENGINE.load(Ordering::SeqCst), 37);
    assert!(state.raster_sentinel_pending.load(Ordering::SeqCst));
}

#[test]
fn engine_command_line_caps_the_resource_cache_when_requested() {
    let project = EngineProject {
        engine_library: PathBuf::from("/engine"),
        assets: PathBuf::from("/assets"),
        icu_data: PathBuf::from("/icudtl.dat"),
        runtime: DartRuntimeMode::Aot,
        aot_library: Some(PathBuf::from("/libapp.so")),
        renderer_backend: RendererBackend::SkiaGles,
        resource_cache_max_bytes_threshold: 256 * 1024 * 1024,
    };
    let arguments = engine_command_line(&project);
    let arguments = arguments
        .iter()
        .map(|argument| argument.to_str().unwrap())
        .collect::<Vec<_>>();
    assert_eq!(
        arguments,
        ["deniald", "--resource-cache-max-bytes-threshold=268435456"]
    );

    let default_arguments = engine_command_line(&EngineProject {
        resource_cache_max_bytes_threshold: 0,
        ..project
    });
    assert_eq!(default_arguments.len(), 1);
    assert_eq!(default_arguments[0].to_str().unwrap(), "deniald");
}

#[test]
fn impeller_is_default_without_experimental_sdfs() {
    assert_eq!(RendererBackend::default(), RendererBackend::ImpellerGles);
    let project = EngineProject {
        engine_library: PathBuf::from("/engine"),
        assets: PathBuf::from("/assets"),
        icu_data: PathBuf::from("/icudtl.dat"),
        runtime: DartRuntimeMode::Aot,
        aot_library: Some(PathBuf::from("/libapp.so")),
        renderer_backend: RendererBackend::ImpellerGles,
        resource_cache_max_bytes_threshold: 0,
    };
    let arguments = engine_command_line(&project);
    let arguments = arguments
        .iter()
        .map(|argument| argument.to_str().unwrap())
        .collect::<Vec<_>>();
    assert_eq!(
        arguments,
        [
            "deniald",
            "--enable-impeller=true",
            "--denial-gl-fbo-zero-is-no-target"
        ]
    );
}

#[test]
fn jit_command_line_enables_a_loopback_authenticated_vm_service() {
    let arguments = engine_command_line(&EngineProject {
        engine_library: PathBuf::from("/engine"),
        assets: PathBuf::from("/assets"),
        icu_data: PathBuf::from("/icudtl.dat"),
        runtime: DartRuntimeMode::Jit,
        aot_library: None,
        renderer_backend: RendererBackend::SkiaGles,
        resource_cache_max_bytes_threshold: 0,
    });
    let arguments = arguments
        .iter()
        .map(|argument| argument.to_str().unwrap())
        .collect::<Vec<_>>();
    assert!(arguments.contains(&"--enable-checked-mode"));
    assert!(arguments.contains(&"--vm-service-host=127.0.0.1"));
    assert!(arguments.contains(&"--vm-service-port=0"));
    assert!(arguments.contains(&"--disable-vm-service-publication"));
    assert!(!arguments.contains(&"--disable-service-auth-codes"));
}

#[test]
fn profile_command_line_enables_profiling_without_debug_checks() {
    let arguments = engine_command_line(&EngineProject {
        engine_library: PathBuf::from("/engine"),
        assets: PathBuf::from("/assets"),
        icu_data: PathBuf::from("/icudtl.dat"),
        runtime: DartRuntimeMode::AotProfile,
        aot_library: Some(PathBuf::from("/libapp.so")),
        renderer_backend: RendererBackend::SkiaGles,
        resource_cache_max_bytes_threshold: 0,
    });
    let arguments = arguments
        .iter()
        .map(|argument| argument.to_str().unwrap())
        .collect::<Vec<_>>();
    assert!(arguments.contains(&"--enable-dart-profiling"));
    assert!(arguments.contains(&"--vm-service-host=127.0.0.1"));
    assert!(arguments.contains(&"--vm-service-port=0"));
    assert!(arguments.contains(&"--disable-vm-service-publication"));
    assert!(!arguments.contains(&"--enable-checked-mode"));
    assert!(!arguments.contains(&"--disable-service-auth-codes"));
}

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
        unsafe { bounded_c_str(oversized_channel.as_ptr(), MAX_PLATFORM_CHANNEL_BYTES) }.is_none()
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
