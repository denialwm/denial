//! Flutter's OpenGL embedder wired directly to native per-output scanout pools.
//!
//! All ABI-facing code lives in `denial-flutter-engine`.  This module owns the
//! compositor side of the contract: shared EGL contexts, imported output FBOs,
//! atomic raster batches, and the buffer-state machine that prevents Flutter
//! from rendering into a buffer still being scanned out.

use std::collections::{BTreeMap, BTreeSet, BinaryHeap, HashMap, HashSet, VecDeque};
use std::error::Error;
use std::ffi::{CStr, OsString, c_char, c_void};
use std::hash::Hash;
use std::io::{Read, Write};
use std::mem;
use std::os::fd::{AsFd, OwnedFd};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, Weak};
use std::thread::{self, ThreadId};
use std::time::{Duration, Instant};

use denial_core::topology::{
    AtlasPlan, OutputId, OutputTransform, PixelSize, RenderViewId, SCALE_BASE, TopologySnapshot,
};
use denial_flutter_engine::{
    BackingStoreRequest, CompositorBackingStore, DartRuntimeMode, EngineError, EngineEvent,
    EngineHost, EngineLibrary, EngineLocale, EngineProject, OpenGlHandler, PlatformMessage,
    PresentFrame, PresentView, RenderOutput, RenderOutputFfiScratch, RenderOutputTransform,
    RendererBackend, ScheduledTask, sys,
};
use sha2::{Digest, Sha256};
use smithay::backend::allocator::dmabuf::Dmabuf;
use smithay::backend::allocator::{Buffer as AllocatorBuffer, Fourcc, Modifier};
use smithay::backend::egl::display::EGLDisplayHandle;
use smithay::backend::egl::fence::EGLFence;
use smithay::backend::egl::{EGLContext, ffi as egl_ffi, get_proc_address};
use smithay::backend::input::{
    AbsolutePositionEvent, Axis, AxisSource, ButtonState, InputEvent as SmithayInputEvent,
    KeyState, PointerAxisEvent, PointerButtonEvent, TouchEvent,
};
use smithay::backend::libinput::LibinputInputBackend;
use smithay::backend::renderer::gles::ffi as gl;
use smithay::backend::renderer::utils::Buffer as RendererBufferGuard;
use smithay::input::keyboard::{KeysymHandle, ModifiersState};
use smithay::reexports::calloop::channel::Sender;
use smithay::utils::{Logical, Size};
use tracing::{debug, error, info, warn};

use super::egl_context;
use super::frame_scheduler::{OutputFrameRequest, PendingFrame};
use super::idle_policy;
use super::native_app_plugin::NativeBufferRelease;
use super::render_audit_enabled;
use super::wire::{self, WireBridge};

#[path = "flutter_runtime/mouse_cursor.rs"]
mod mouse_cursor;
#[path = "flutter_runtime/platform.rs"]
mod platform;
#[path = "flutter_runtime/system_command.rs"]
pub(super) mod system_command;
#[path = "flutter_runtime/text_input.rs"]
mod text_input;
pub(super) use super::wayland_frontend::input_method::InputMethodTransaction;
pub(super) use text_input::TextInputSnapshot;

#[path = "flutter_runtime/cursor_bridge.rs"]
mod cursor_bridge;
#[path = "flutter_runtime/damage.rs"]
mod damage;
#[path = "flutter_runtime/engine_session.rs"]
mod engine_session;
#[path = "flutter_runtime/event_pipeline.rs"]
mod event_pipeline;
#[path = "flutter_runtime/input.rs"]
mod input;
#[path = "flutter_runtime/output_pipeline.rs"]
mod output_pipeline;
#[path = "flutter_runtime/output_runtime.rs"]
mod output_runtime;
#[path = "flutter_runtime/platform_dispatch.rs"]
mod platform_dispatch;
#[path = "flutter_runtime/render_audit.rs"]
mod render_audit;
#[path = "flutter_runtime/renderer.rs"]
mod renderer;
#[path = "flutter_runtime/scene_bridge.rs"]
mod scene_bridge;
#[path = "flutter_runtime/service_bridge.rs"]
mod service_bridge;

use damage::DamageRegion;
pub use event_pipeline::RuntimeEvent;
use event_pipeline::{
    CoalescedInbox, CoalescedWakeup, PendingPlatformTask, PlatformTaskBudget, PlatformTaskPermit,
};
pub use input::InputQueue;
use input::{InputRecord, KeyboardRecord, flutter_physical_scroll_delta, glfw_keycode};
pub use output_pipeline::ReadyOutputFrame;
use output_pipeline::{
    OutputBufferBroker, OutputPoolDescriptor, PendingVsyncBatons, RenderTargetBlocked,
    VsyncRegistration,
};
use render_audit::{RenderAuditStage, RenderDamageAudit};
pub use renderer::SampledBufferHoldBatch;
pub(super) use renderer::{
    ExternalTextureFrame, OutputGeometryTransition, OutputRotationAdvance, ShmSnapshotPool,
    ShmTextureFrame, SyncedWaylandScene,
};
use renderer::{
    FlutterGlHandler, OutputRotationAnimation, PendingOutputGeometry, RuntimeRenderOutput,
};

const FLUTTER_KEY_EVENT_CHANNEL: &CStr = c"flutter/keyevent";
const FLUTTER_LIFECYCLE_CHANNEL: &CStr = c"flutter/lifecycle";
const FLUTTER_SETTINGS_CHANNEL: &CStr = c"flutter/settings";
const FLUTTER_LIFECYCLE_RESUMED: &[u8] = b"AppLifecycleState.resumed";
const FLUTTER_LIFECYCLE_HIDDEN: &[u8] = b"AppLifecycleState.hidden";
const AUDIO_CHANNEL: &CStr = c"denial/audio";
const AUDIO_STATE_CHANNEL: &CStr = c"denial/audio_state";
const AUDIO_STREAMS_STATE_CHANNEL: &CStr = c"denial/audio_streams_state";
const AUDIO_DEVICES_STATE_CHANNEL: &CStr = c"denial/audio_devices_state";
const BRIGHTNESS_CHANNEL: &CStr = c"denial/brightness";
const BRIGHTNESS_STATE_CHANNEL: &CStr = c"denial/brightness_state";
const WINDOW_CLOSE_COMPLETE_CHANNEL: &CStr = c"denial/window_close_complete";
const CURSOR_PRESENTED_CHANNEL: &CStr = c"denial/cursor_presented";
const GLFW_MOD_CONTROL: u32 = 0x0002;
const GLFW_MOD_ALT: u32 = 0x0004;
const MAX_CACHED_DMABUF_BINDINGS_PER_TEXTURE: usize = 8;
const MAX_CACHED_SHM_BINDINGS: usize = 32;
const MAX_CACHED_EXTERNAL_TEXTURE_LEASES: usize = 256;
const MAX_RECYCLED_SAMPLED_BUFFER_BATCHES: usize = 8;
const MAX_RECYCLED_SHM_BUFFERS: usize = 8;
const MAX_RECYCLED_SHM_BYTES: usize = 64 * 1024 * 1024;
const MAX_INPUT_EVENTS_PER_COMPOSITOR_ITERATION: usize = 64;
const MAX_PENDING_VSYNC_BATONS: usize = 256;
const MAX_PENDING_PLATFORM_TASKS: usize = 4096;
const MAX_RETAINED_WINDOW_CLOSE_LEASES: usize = 4096;
const MAX_PLATFORM_TASKS_PER_DISPATCH: usize = 256;
const INITIAL_PLATFORM_TASK_BATCH_CAPACITY: usize = 64;
const MAX_LIVE_EXTERNAL_TEXTURE_RESOURCES: usize = 1024;
const PLATFORM_TASK_MAX_DISPATCH_TIMEOUT: Duration = Duration::from_millis(100);
const MAX_PENDING_AUDIO_REQUESTS: usize = 128;
const MAX_PENDING_BRIGHTNESS_REQUESTS: usize = 128;
const MAX_PENDING_UI_DEVELOPMENT_COMMANDS: usize = 64;
const WINDOW_CLOSE_LEASE_TIMEOUT: Duration = Duration::from_secs(5);
const RENDER_AUDIT_INTERVAL: Duration = Duration::from_secs(1);
const FLUTTER_RESOURCE_CACHE_MAX_BYTES_THRESHOLD: usize = 256 * 1024 * 1024;
const OUTPUT_ROTATION_ANIMATION_DURATION: Duration = Duration::from_millis(300);
const OUTPUT_ROTATION_RESIZE_PROGRESS: f64 = 0.78;

/// Borrowed native storage used only while constructing the Flutter EGL
/// target table. KMS keeps ownership of every DMA-BUF and framebuffer.
pub(super) struct OutputRenderTargetPool<'a> {
    pub output_id: OutputId,
    pub render_view_id: RenderViewId,
    pub configuration_generation: u64,
    pub size: PixelSize,
    pub initial_scanout: usize,
    pub dmabufs: Vec<(&'a Dmabuf, Option<&'a Dmabuf>)>,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

pub struct FlutterRuntimeFactory {
    bundle: PathBuf,
    project: EngineProject,
    library: Arc<EngineLibrary>,
}

impl FlutterRuntimeFactory {
    pub fn new(
        bundle: &Path,
        runtime: DartRuntimeMode,
        renderer_backend: RendererBackend,
    ) -> Result<Self, Box<dyn Error>> {
        let project = project_from_bundle(bundle, runtime, renderer_backend)?;
        let library = Arc::new(EngineLibrary::load(&project.engine_library)?);
        Ok(Self {
            bundle: bundle.to_owned(),
            project,
            library,
        })
    }
}

#[derive(Debug)]
struct QueuedPlatformTask {
    task: ScheduledTask,
    permit: PlatformTaskPermit,
    order: u64,
}

impl PartialEq for QueuedPlatformTask {
    fn eq(&self, other: &Self) -> bool {
        self.task.target_time_nanos == other.task.target_time_nanos && self.order == other.order
    }
}

pub(super) fn bundle_engine_fingerprint(bundle: &Path) -> Result<[u8; 32], Box<dyn Error>> {
    let engine = first_file(&[
        bundle.join("lib/libflutter_engine.so"),
        bundle.join("libflutter_engine.so"),
    ])
    .ok_or_else(|| format!("{} has no libflutter_engine.so", bundle.display()))?;
    let mut file = std::fs::File::open(&engine).map_err(|error| {
        format!(
            "could not open Flutter engine {}: {error}",
            engine.display()
        )
    })?;
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let bytes = file.read(&mut buffer).map_err(|error| {
            format!(
                "could not read Flutter engine {}: {error}",
                engine.display()
            )
        })?;
        if bytes == 0 {
            break;
        }
        digest.update(&buffer[..bytes]);
    }
    Ok(digest.finalize().into())
}

impl Eq for QueuedPlatformTask {}

impl PartialOrd for QueuedPlatformTask {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for QueuedPlatformTask {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        // BinaryHeap is a max-heap. Reverse both stable scheduling keys so
        // the earliest deadline and then the oldest arrival stay at the top.
        other
            .task
            .target_time_nanos
            .cmp(&self.task.target_time_nanos)
            .then_with(|| other.order.cmp(&self.order))
    }
}

fn platform_task_dispatch_timeout(tasks: &BinaryHeap<QueuedPlatformTask>, now: u64) -> Duration {
    tasks
        .peek()
        .map(|queued| Duration::from_nanos(queued.task.target_time_nanos.saturating_sub(now)))
        .unwrap_or(PLATFORM_TASK_MAX_DISPATCH_TIMEOUT)
        .min(PLATFORM_TASK_MAX_DISPATCH_TIMEOUT)
}

fn take_next_due_platform_task(
    tasks: &mut BinaryHeap<QueuedPlatformTask>,
    now: u64,
) -> Option<QueuedPlatformTask> {
    if tasks.peek()?.task.target_time_nanos > now {
        return None;
    }
    tasks.pop()
}

fn timeline_vsync_timestamps(
    engine_now_nanos: u64,
    observation_delay: Duration,
    target_after_deadline: Duration,
) -> (u64, u64) {
    let observation_delay = u64::try_from(observation_delay.as_nanos()).unwrap_or(u64::MAX);
    let target_after_deadline = u64::try_from(target_after_deadline.as_nanos()).unwrap_or(u64::MAX);
    let frame_start = engine_now_nanos.saturating_sub(observation_delay);
    (
        frame_start,
        frame_start.saturating_add(target_after_deadline),
    )
}

struct WindowCloseTextureLease {
    texture_ids: Vec<i64>,
    expires_at: Instant,
}

#[derive(Default)]
struct RetiredWindowCloseLeases {
    lease_count: usize,
    texture_ids: Vec<i64>,
}

#[derive(Default)]
struct WindowCloseTextureLeases {
    published_windows: HashMap<u64, Vec<i64>>,
    closing_windows: HashMap<u64, WindowCloseTextureLease>,
    retained_texture_references: HashMap<i64, usize>,
}

impl WindowCloseTextureLeases {
    fn is_empty(&self) -> bool {
        self.closing_windows.is_empty()
    }

    fn publish(
        &mut self,
        next_windows: HashMap<u64, Vec<i64>>,
        now: Instant,
    ) -> RetiredWindowCloseLeases {
        let previous_windows = mem::replace(&mut self.published_windows, next_windows);
        let removed_windows = previous_windows
            .into_iter()
            .filter(|(window_id, _)| !self.published_windows.contains_key(window_id))
            .collect::<Vec<_>>();
        let mut retired = RetiredWindowCloseLeases::default();

        for (window_id, texture_ids) in removed_windows {
            if texture_ids.is_empty() {
                continue;
            }
            if self.closing_windows.contains_key(&window_id) {
                self.remove(window_id, &mut retired.texture_ids);
                retired.lease_count = retired.lease_count.saturating_add(1);
            }
            while self.closing_windows.len() >= MAX_RETAINED_WINDOW_CLOSE_LEASES {
                let Some(oldest_window_id) = self
                    .closing_windows
                    .iter()
                    .min_by_key(|(_, lease)| lease.expires_at)
                    .map(|(window_id, _)| *window_id)
                else {
                    break;
                };
                self.remove(oldest_window_id, &mut retired.texture_ids);
                retired.lease_count = retired.lease_count.saturating_add(1);
            }
            for texture_id in &texture_ids {
                let references = self
                    .retained_texture_references
                    .entry(*texture_id)
                    .or_default();
                *references = references.saturating_add(1);
            }
            self.closing_windows.insert(
                window_id,
                WindowCloseTextureLease {
                    texture_ids,
                    expires_at: now.checked_add(WINDOW_CLOSE_LEASE_TIMEOUT).unwrap_or(now),
                },
            );
        }
        retired
    }

    fn complete(&mut self, window_id: u64) -> RetiredWindowCloseLeases {
        let mut retired = RetiredWindowCloseLeases::default();
        if self.remove(window_id, &mut retired.texture_ids) {
            retired.lease_count = 1;
        }
        retired
    }

    fn expire(&mut self, now: Instant) -> RetiredWindowCloseLeases {
        let expired_window_ids = self
            .closing_windows
            .iter()
            .filter_map(|(window_id, lease)| (lease.expires_at <= now).then_some(*window_id))
            .collect::<Vec<_>>();
        let mut retired = RetiredWindowCloseLeases::default();
        for window_id in expired_window_ids {
            if self.remove(window_id, &mut retired.texture_ids) {
                retired.lease_count = retired.lease_count.saturating_add(1);
            }
        }
        retired
    }

    fn retains_texture(&self, texture_id: i64) -> bool {
        self.retained_texture_references.contains_key(&texture_id)
    }

    fn remove(&mut self, window_id: u64, texture_ids: &mut Vec<i64>) -> bool {
        let Some(lease) = self.closing_windows.remove(&window_id) else {
            return false;
        };
        for texture_id in lease.texture_ids {
            let remove_reference = self
                .retained_texture_references
                .get_mut(&texture_id)
                .is_some_and(|references| {
                    *references = references.saturating_sub(1);
                    *references == 0
                });
            if remove_reference {
                self.retained_texture_references.remove(&texture_id);
            }
            texture_ids.push(texture_id);
        }
        true
    }
}

fn window_texture_map(windows: &[wire::WindowDescription]) -> HashMap<u64, Vec<i64>> {
    let mut textures = HashMap::with_capacity(windows.len());
    for window in windows {
        let texture_ids = if window.surfaces.is_empty() {
            i64::try_from(window.texture_id)
                .ok()
                .filter(|texture_id| *texture_id > 0)
                .into_iter()
                .collect()
        } else {
            window
                .surfaces
                .iter()
                .filter_map(|surface| i64::try_from(surface.texture_id).ok())
                .filter(|texture_id| *texture_id > 0)
                .collect()
        };
        textures.insert(window.window_id, texture_ids);
    }
    textures
}

fn decode_window_close_complete(data: &[u8]) -> Option<u64> {
    let window_id = u64::from_le_bytes(data.try_into().ok()?);
    (window_id > 0).then_some(window_id)
}

fn decode_cursor_presented(data: &[u8]) -> Option<u64> {
    let epoch = u64::from_le_bytes(data.try_into().ok()?);
    (epoch > 0).then_some(epoch)
}

pub struct FlutterRuntime {
    host: Option<EngineHost>,
    handler: Arc<FlutterGlHandler>,
    wire: WireBridge,
    text_input: text_input::TextInputPlugin,
    platform: platform::PlatformPlugin,
    mouse_cursor: mouse_cursor::MouseCursorPlugin,
    clipboard: super::clipboard::ClipboardManager,
    published_clipboard_revision: u64,
    system_commands: system_command::SystemCommandHandler,
    authentication: Arc<super::authentication::AuthenticationController>,
    pending_audio_requests: VecDeque<super::system_controls::AudioRequest>,
    pending_brightness_requests: VecDeque<super::system_controls::BrightnessRequest>,
    pending_ui_development_commands: VecDeque<super::ui_development::UiDevelopmentCommand>,
    pending_idle_policy: Option<idle_policy::IdlePolicyConfiguration>,
    pending_dpms_off: bool,
    pending_vm_service_uri: Option<String>,
    generation: u64,
    scheduled_tasks: BinaryHeap<QueuedPlatformTask>,
    platform_task_scratch: Vec<PendingPlatformTask>,
    next_platform_task_order: u64,
    registered_external_textures: HashSet<i64>,
    scene_texture_ids: HashSet<i64>,
    cursor_texture_ids: HashSet<i64>,
    retired_cursor_texture_ids: BTreeMap<u64, HashSet<i64>>,
    cursor_epoch: u64,
    cursor_output: Option<OutputId>,
    render_outputs: Vec<RuntimeRenderOutput>,
    render_output_configuration: Vec<RenderOutput>,
    output_rotation_animation: Option<OutputRotationAnimation>,
    pending_output_geometry: Option<PendingOutputGeometry>,
    render_output_ffi_scratch: RenderOutputFfiScratch,
    texture_output_membership: HashMap<i64, Arc<[OutputId]>>,
    pending_output_updates: BTreeMap<OutputId, BTreeSet<i64>>,
    changed_texture_scratch: Vec<i64>,
    render_view_scratch: Vec<i64>,
    render_texture_scratch: Vec<i64>,
    screenshot_texture_id: Option<i64>,
    pending_screenshot_frame: Option<(OutputId, u64)>,
    scene_texture_id_scratch: Vec<i64>,
    window_close_texture_leases: WindowCloseTextureLeases,
    pending_frame_texture_ids: Vec<i64>,
    pointer_event_scratch: Vec<sys::FlutterPointerEvent>,
    key_event_scratch: Vec<u8>,
    device_pixel_ratio: f64,
    frame_interval: Duration,
    kms_frame_clock_enabled: bool,
    outputs_visible: Option<bool>,
    published_text_input_state: Option<(bool, bool, bool, u32, u32, u64)>,
    frame_ready_observed: bool,
    last_pointer_timestamp_micros: usize,
}

/// Keeps one published physical-output target unavailable to Flutter while an
/// asynchronous compositor consumer still reads it. The lease owns the exact
/// renderer generation which published the slot, so a topology-driven Flutter
/// restart cannot redirect its eventual release into a replacement pool.
pub(super) struct OutputBufferLease {
    handler: Arc<FlutterGlHandler>,
    output: OutputId,
    index: usize,
}

impl Drop for OutputBufferLease {
    fn drop(&mut self) {
        let released = self.handler.release_output(self.output, self.index);
        debug_assert!(released.is_ok(), "asynchronous output lease lost its owner");
    }
}

fn encode_key_event(event: KeyboardRecord, output: &mut Vec<u8>) {
    let keycode = glfw_keycode(event.keycode);
    let event_type = if event.pressed { "keydown" } else { "keyup" };
    output.clear();
    if event.unicode == 0 {
        write!(
            output,
            r#"{{"keyCode":{keycode},"keymap":"linux","toolkit":"glfw","scanCode":{keycode},"modifiers":{},"type":"{event_type}"}}"#,
            event.modifiers,
        )
        .expect("writing JSON into a Vec cannot fail");
    } else {
        write!(
            output,
            r#"{{"keyCode":{keycode},"keymap":"linux","toolkit":"glfw","scanCode":{keycode},"modifiers":{},"type":"{event_type}","unicodeScalarValues":{}}}"#,
            event.modifiers, event.unicode,
        )
        .expect("writing JSON into a Vec cannot fail");
    }
}

impl Drop for FlutterRuntime {
    fn drop(&mut self) {
        if let Err(error) = self.shutdown_engine() {
            error!(%error, "Flutter engine shutdown failed");
        }
    }
}

fn project_from_bundle(
    bundle: &Path,
    runtime: DartRuntimeMode,
    renderer_backend: RendererBackend,
) -> Result<EngineProject, Box<dyn Error>> {
    let engine_library = first_file(&[
        bundle.join("lib/libflutter_engine.so"),
        bundle.join("libflutter_engine.so"),
    ])
    .ok_or_else(|| format!("{} has no libflutter_engine.so", bundle.display()))?;
    let assets = bundle.join("data/flutter_assets");
    let icu_data = bundle.join("data/icudtl.dat");
    let aot_library = match runtime {
        DartRuntimeMode::Aot | DartRuntimeMode::AotProfile => Some(
            first_file(&[bundle.join("lib/libapp.so"), bundle.join("libapp.so")])
                .ok_or_else(|| format!("{} has no libapp.so", bundle.display()))?,
        ),
        DartRuntimeMode::Jit => {
            let kernel = assets.join("kernel_blob.bin");
            if !kernel.is_file() {
                return Err(
                    format!("JIT Flutter kernel is missing at {}", kernel.display()).into(),
                );
            }
            None
        }
    };
    for (name, path) in [("Flutter assets", &assets), ("ICU data", &icu_data)] {
        if !path.exists() {
            return Err(format!("{name} is missing at {}", path.display()).into());
        }
    }
    Ok(EngineProject {
        engine_library,
        assets,
        icu_data,
        runtime,
        aot_library,
        renderer_backend,
        // Flutter derives 48 bytes per physical viewport pixel, which gives a
        // 5120x1440 virtual desktop a 337.5 MiB cache. Keep the official
        // adaptive behavior below the cap while preventing large multi-output
        // scenes from retaining more than a conservative desktop-sized budget.
        resource_cache_max_bytes_threshold: FLUTTER_RESOURCE_CACHE_MAX_BYTES_THRESHOLD,
    })
}

fn locale_from_environment(read: impl FnMut(&str) -> Option<String>) -> Option<EngineLocale> {
    ["LC_ALL", "LC_MESSAGES", "LANG"]
        .into_iter()
        .filter_map(read)
        .find_map(|value| parse_posix_locale(&value))
}

fn parse_posix_locale(value: &str) -> Option<EngineLocale> {
    let value = value.trim();
    if value.is_empty()
        || value.eq_ignore_ascii_case("C")
        || value.eq_ignore_ascii_case("POSIX")
        || value.to_ascii_uppercase().starts_with("C.")
    {
        return None;
    }
    let base = value.split_once('@').map_or(value, |(base, _)| base);
    let base = base.split_once('.').map_or(base, |(base, _)| base);
    let mut parts = base.split(['_', '-']);
    let language = parts.next()?.to_ascii_lowercase();
    if !(2..=3).contains(&language.len())
        || !language.bytes().all(|byte| byte.is_ascii_alphabetic())
    {
        return None;
    }

    let mut script = None;
    let mut country = None;
    let mut variants = Vec::new();
    for part in parts.filter(|part| !part.is_empty()) {
        if script.is_none()
            && part.len() == 4
            && part.bytes().all(|byte| byte.is_ascii_alphabetic())
        {
            let mut characters = part.chars();
            script = characters.next().map(|first| {
                format!(
                    "{}{}",
                    first.to_ascii_uppercase(),
                    characters.as_str().to_ascii_lowercase()
                )
            });
        } else if country.is_none()
            && ((part.len() == 2 && part.bytes().all(|byte| byte.is_ascii_alphabetic()))
                || (part.len() == 3 && part.bytes().all(|byte| byte.is_ascii_digit())))
        {
            country = Some(part.to_ascii_uppercase());
        } else {
            variants.push(part.to_owned());
        }
    }

    if language == "zh" && script.is_none() {
        script = match country.as_deref() {
            Some("CN" | "SG") => Some("Hans".to_owned()),
            Some("TW" | "HK" | "MO") => Some("Hant".to_owned()),
            _ => None,
        };
    }
    let variant = (!variants.is_empty()).then(|| variants.join("_"));
    EngineLocale::new(
        &language,
        country.as_deref(),
        script.as_deref(),
        variant.as_deref(),
    )
    .ok()
}

fn first_file(paths: &[PathBuf]) -> Option<PathBuf> {
    paths.iter().find(|path| path.is_file()).cloned()
}
