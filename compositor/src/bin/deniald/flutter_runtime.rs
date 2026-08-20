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
#[cfg(test)]
use super::frame_scheduler::FrameTick;
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

#[path = "flutter_runtime/damage.rs"]
mod damage;

use damage::DamageRegion;

const FLUTTER_KEY_EVENT_CHANNEL: &CStr = c"flutter/keyevent";
const FLUTTER_LIFECYCLE_CHANNEL: &CStr = c"flutter/lifecycle";
const FLUTTER_LIFECYCLE_RESUMED: &[u8] = b"AppLifecycleState.resumed";
const FLUTTER_LIFECYCLE_HIDDEN: &[u8] = b"AppLifecycleState.hidden";
const AUDIO_CHANNEL: &CStr = c"denial/audio";
const AUDIO_STATE_CHANNEL: &CStr = c"denial/audio_state";
const AUDIO_STREAMS_STATE_CHANNEL: &CStr = c"denial/audio_streams_state";
const BRIGHTNESS_CHANNEL: &CStr = c"denial/brightness";
const BRIGHTNESS_STATE_CHANNEL: &CStr = c"denial/brightness_state";
const WINDOW_CLOSE_COMPLETE_CHANNEL: &CStr = c"denial/window_close_complete";
const GLFW_MOD_CONTROL: u32 = 0x0002;
const GLFW_MOD_ALT: u32 = 0x0004;
const FLUTTER_MOUSE_WHEEL_SCROLL_PIXELS: f64 = 53.0;
const V120_UNITS_PER_WHEEL_STEP: f64 = 120.0;
const MAX_CACHED_DMABUF_BINDINGS_PER_TEXTURE: usize = 8;
const MAX_CACHED_SHM_BINDINGS: usize = 32;
const MAX_CACHED_EXTERNAL_TEXTURE_LEASES: usize = 256;
const MAX_RECYCLED_SAMPLED_BUFFER_BATCHES: usize = 8;
const MAX_RECYCLED_SHM_BUFFERS: usize = 8;
const MAX_RECYCLED_SHM_BYTES: usize = 64 * 1024 * 1024;
const MAX_QUEUED_INPUT_EVENTS: usize = 4096;
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

#[derive(Debug)]
struct RenderDamageAudit {
    interval_started: Instant,
    presented_outputs: u64,
    empty_transactions: u64,
    frame_rects: u64,
    buffer_rects: u64,
    frame_coverage: f64,
    buffer_coverage: f64,
    max_frame_coverage: f64,
    max_buffer_coverage: f64,
    full_frame_damage: u64,
    full_buffer_damage: u64,
    empty_frame_damage: u64,
    empty_buffer_damage: u64,
    sampled_transactions: u64,
    sampled_textures: u64,
    max_sampled_textures: usize,
    sampled_texture_counts: HashMap<i64, u64>,
    sampled_generation_advances: u64,
    sampled_generation_repeats: u64,
    last_sampled_generations: HashMap<i64, u64>,
    render_authorizations: u64,
    authorization_lateness: Duration,
    authorization_lateness_max: Duration,
    target_blocked_ready: u64,
    target_blocked_exhausted: u64,
    last_render_view_id: Option<i64>,
    last_frame_damage: String,
    last_buffer_damage: String,
}

impl RenderDamageAudit {
    fn new() -> Self {
        Self {
            interval_started: Instant::now(),
            presented_outputs: 0,
            empty_transactions: 0,
            frame_rects: 0,
            buffer_rects: 0,
            frame_coverage: 0.0,
            buffer_coverage: 0.0,
            max_frame_coverage: 0.0,
            max_buffer_coverage: 0.0,
            full_frame_damage: 0,
            full_buffer_damage: 0,
            empty_frame_damage: 0,
            empty_buffer_damage: 0,
            sampled_transactions: 0,
            sampled_textures: 0,
            max_sampled_textures: 0,
            sampled_texture_counts: HashMap::new(),
            sampled_generation_advances: 0,
            sampled_generation_repeats: 0,
            last_sampled_generations: HashMap::new(),
            render_authorizations: 0,
            authorization_lateness: Duration::ZERO,
            authorization_lateness_max: Duration::ZERO,
            target_blocked_ready: 0,
            target_blocked_exhausted: 0,
            last_render_view_id: None,
            last_frame_damage: "-".to_owned(),
            last_buffer_damage: "-".to_owned(),
        }
    }

    fn record_target_blocked(&mut self, blocked: RenderTargetBlocked) {
        match blocked {
            RenderTargetBlocked::ReadyHandoff => {
                self.target_blocked_ready = self.target_blocked_ready.saturating_add(1);
            }
            RenderTargetBlocked::PoolExhausted => {
                self.target_blocked_exhausted = self.target_blocked_exhausted.saturating_add(1);
            }
        }
    }

    fn record_present(
        &mut self,
        render_view_id: i64,
        size: PixelSize,
        frame_damage: &[sys::FlutterRect],
        buffer_damage: &[sys::FlutterRect],
    ) {
        let mut frame_region = DamageRegion::empty(size.width, size.height);
        let mut buffer_region = DamageRegion::empty(size.width, size.height);
        frame_region.replace_from_flutter(frame_damage);
        buffer_region.replace_from_flutter(buffer_damage);

        let target_pixels = (f64::from(size.width) * f64::from(size.height)).max(1.0);
        let frame_coverage = frame_region.damaged_area() / target_pixels;
        let buffer_coverage = buffer_region.damaged_area() / target_pixels;
        self.presented_outputs = self.presented_outputs.saturating_add(1);
        self.frame_rects = self
            .frame_rects
            .saturating_add(frame_region.rect_count() as u64);
        self.buffer_rects = self
            .buffer_rects
            .saturating_add(buffer_region.rect_count() as u64);
        self.frame_coverage += frame_coverage;
        self.buffer_coverage += buffer_coverage;
        self.max_frame_coverage = self.max_frame_coverage.max(frame_coverage);
        self.max_buffer_coverage = self.max_buffer_coverage.max(buffer_coverage);
        self.full_frame_damage = self
            .full_frame_damage
            .saturating_add(u64::from(frame_region.is_full()));
        self.full_buffer_damage = self
            .full_buffer_damage
            .saturating_add(u64::from(buffer_region.is_full()));
        self.empty_frame_damage = self
            .empty_frame_damage
            .saturating_add(u64::from(frame_region.is_empty()));
        self.empty_buffer_damage = self
            .empty_buffer_damage
            .saturating_add(u64::from(buffer_region.is_empty()));
        self.last_render_view_id = Some(render_view_id);
        self.last_frame_damage = frame_region.compact_description();
        self.last_buffer_damage = buffer_region.compact_description();
        self.maybe_report();
    }

    fn record_empty_transaction(&mut self) {
        self.empty_transactions = self.empty_transactions.saturating_add(1);
        self.maybe_report();
    }

    fn record_sampled_textures(&mut self, sampled: Option<&SampledBufferHoldBatch>) {
        let sampled_textures = sampled.map_or(0, SampledBufferHoldBatch::len);
        self.sampled_transactions = self.sampled_transactions.saturating_add(1);
        self.sampled_textures = self
            .sampled_textures
            .saturating_add(sampled_textures as u64);
        self.max_sampled_textures = self.max_sampled_textures.max(sampled_textures);
        if let Some(sampled) = sampled {
            for (texture_id, generation) in sampled.texture_generations() {
                let count = self.sampled_texture_counts.entry(texture_id).or_default();
                *count = count.saturating_add(1);
                if self.last_sampled_generations.insert(texture_id, generation) == Some(generation)
                {
                    self.sampled_generation_repeats =
                        self.sampled_generation_repeats.saturating_add(1);
                } else {
                    self.sampled_generation_advances =
                        self.sampled_generation_advances.saturating_add(1);
                }
            }
        }
    }

    fn record_render_authorization(&mut self, lateness: Duration) {
        self.render_authorizations = self.render_authorizations.saturating_add(1);
        self.authorization_lateness = self.authorization_lateness.saturating_add(lateness);
        self.authorization_lateness_max = self.authorization_lateness_max.max(lateness);
    }

    fn sampled_texture_counts_description(&self) -> String {
        if self.sampled_texture_counts.is_empty() {
            return "-".to_owned();
        }
        let mut counts = self.sampled_texture_counts.iter().collect::<Vec<_>>();
        counts.sort_unstable_by_key(|(texture_id, _)| **texture_id);
        counts
            .into_iter()
            .map(|(texture_id, count)| format!("{texture_id}:{count}"))
            .collect::<Vec<_>>()
            .join(",")
    }

    fn maybe_report(&mut self) {
        let elapsed = self.interval_started.elapsed();
        if elapsed < RENDER_AUDIT_INTERVAL {
            return;
        }

        let output_denominator = self.presented_outputs.max(1) as f64;
        let sampled_denominator = self.sampled_transactions.max(1) as f64;
        let authorization_denominator = self.render_authorizations.max(1) as f64;
        info!(
            target: "deniald::render_audit",
            source = "embedder",
            interval_ms = elapsed.as_secs_f64() * 1_000.0,
            presented_outputs = self.presented_outputs,
            empty_transactions = self.empty_transactions,
            frame_damage_avg_pct = self.frame_coverage / output_denominator * 100.0,
            frame_damage_max_pct = self.max_frame_coverage * 100.0,
            frame_damage_avg_rects = self.frame_rects as f64 / output_denominator,
            frame_damage_full = self.full_frame_damage,
            frame_damage_empty = self.empty_frame_damage,
            buffer_damage_avg_pct = self.buffer_coverage / output_denominator * 100.0,
            buffer_damage_max_pct = self.max_buffer_coverage * 100.0,
            buffer_damage_avg_rects = self.buffer_rects as f64 / output_denominator,
            buffer_damage_full = self.full_buffer_damage,
            buffer_damage_empty = self.empty_buffer_damage,
            sampled_textures_avg = self.sampled_textures as f64 / sampled_denominator,
            sampled_textures_max = self.max_sampled_textures,
            sampled_texture_counts = %self.sampled_texture_counts_description(),
            sampled_generation_advances = self.sampled_generation_advances,
            sampled_generation_repeats = self.sampled_generation_repeats,
            authorization_lateness_avg_us = self.authorization_lateness.as_secs_f64()
                * 1_000_000.0
                / authorization_denominator,
            authorization_lateness_max_us = self.authorization_lateness_max.as_secs_f64()
                * 1_000_000.0,
            target_blocked_ready = self.target_blocked_ready,
            target_blocked_exhausted = self.target_blocked_exhausted,
            last_render_view_id = ?self.last_render_view_id,
            last_frame_damage = %self.last_frame_damage,
            last_buffer_damage = %self.last_buffer_damage,
            "Flutter per-output render audit"
        );

        self.interval_started = Instant::now();
        self.presented_outputs = 0;
        self.empty_transactions = 0;
        self.frame_rects = 0;
        self.buffer_rects = 0;
        self.frame_coverage = 0.0;
        self.buffer_coverage = 0.0;
        self.max_frame_coverage = 0.0;
        self.max_buffer_coverage = 0.0;
        self.full_frame_damage = 0;
        self.full_buffer_damage = 0;
        self.empty_frame_damage = 0;
        self.empty_buffer_damage = 0;
        self.sampled_transactions = 0;
        self.sampled_textures = 0;
        self.max_sampled_textures = 0;
        self.sampled_texture_counts.clear();
        self.sampled_generation_advances = 0;
        self.sampled_generation_repeats = 0;
        self.last_sampled_generations.clear();
        self.render_authorizations = 0;
        self.authorization_lateness = Duration::ZERO;
        self.authorization_lateness_max = Duration::ZERO;
        self.target_blocked_ready = 0;
        self.target_blocked_exhausted = 0;
        self.last_render_view_id = None;
        self.last_frame_damage.clear();
        self.last_frame_damage.push('-');
        self.last_buffer_damage.clear();
        self.last_buffer_damage.push('-');
    }
}

#[derive(Debug, Default)]
struct PlatformTaskBudget {
    pending: AtomicUsize,
}

impl PlatformTaskBudget {
    fn try_acquire(self: &Arc<Self>) -> Option<PlatformTaskPermit> {
        self.pending
            // This is only a hard quota. Task publication and ownership are
            // synchronized independently by the inbox mutex and Arc.
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |pending| {
                (pending < MAX_PENDING_PLATFORM_TASKS).then_some(pending + 1)
            })
            .ok()?;
        Some(PlatformTaskPermit {
            budget: Arc::clone(self),
        })
    }
}

#[derive(Debug)]
struct PlatformTaskPermit {
    budget: Arc<PlatformTaskBudget>,
}

impl Drop for PlatformTaskPermit {
    fn drop(&mut self) {
        let previous = self.budget.pending.fetch_sub(1, Ordering::Relaxed);
        debug_assert!(previous != 0, "platform task budget underflow");
    }
}

#[derive(Debug)]
struct PendingPlatformTask {
    task: ScheduledTask,
    permit: PlatformTaskPermit,
}

#[derive(Debug, Default)]
struct CoalescedWakeup {
    pending: AtomicBool,
}

impl CoalescedWakeup {
    fn begin(&self) -> bool {
        // The flag carries edge ownership only; payloads are synchronized by
        // their broker mutex or channel send.
        !self.pending.swap(true, Ordering::Relaxed)
    }

    fn acknowledge(&self) {
        self.pending.store(false, Ordering::Relaxed);
    }
}

/// A producer-side batch whose channel carries only an edge notification.
///
/// Producers append before arming the wakeup. The consumer disarms before it
/// swaps buffers, so a concurrent append is either included in this batch or
/// emits the next edge; it can never remain queued without a wakeup.
#[derive(Debug)]
struct CoalescedInbox<T> {
    state: Mutex<CoalescedInboxState<T>>,
}

#[derive(Debug)]
struct CoalescedInboxState<T> {
    items: Vec<T>,
    armed: bool,
}

impl<T> CoalescedInbox<T> {
    fn with_capacity(capacity: usize) -> Self {
        Self {
            state: Mutex::new(CoalescedInboxState {
                items: Vec::with_capacity(capacity),
                armed: false,
            }),
        }
    }

    /// Returns true only for the producer responsible for sending the edge.
    fn push(&self, item: T) -> bool {
        let mut state = lock(&self.state);
        state.items.push(item);
        if state.armed {
            false
        } else {
            state.armed = true;
            true
        }
    }

    fn take_into(&self, output: &mut Vec<T>) {
        debug_assert!(output.is_empty());
        let mut state = lock(&self.state);
        state.armed = false;
        mem::swap(&mut state.items, output);
    }

    fn discard_after_failed_wakeup(&self) {
        let mut state = lock(&self.state);
        state.armed = false;
        state.items.clear();
    }
}

#[derive(Debug)]
pub enum RuntimeEvent {
    Engine {
        generation: u64,
        event: EngineEvent,
    },
    PlatformTasksReady {
        generation: u64,
    },
    QueueOverflow {
        generation: u64,
        queue: &'static str,
    },
    FatalRender {
        generation: u64,
        reason: String,
    },
    VmServiceUri {
        generation: u64,
        uri: String,
    },
    FrameReady {
        generation: u64,
    },
    SampledBuffersReady {
        fence: Option<OwnedFd>,
        batch: SampledBufferHoldBatch,
    },
}

#[derive(Clone, Copy, Debug)]
struct PointerRecord {
    phase: sys::FlutterPointerPhase,
    x: f64,
    y: f64,
    device: i32,
    signal_kind: sys::FlutterPointerSignalKind,
    scroll_x: f64,
    scroll_y: f64,
    device_kind: sys::FlutterPointerDeviceKind,
    buttons: i64,
    /// True only for position samples which can be superseded before Flutter
    /// observes them. Button transitions can also use Flutter's `Move` phase,
    /// so deriving this from `phase` would occasionally lose state changes.
    replaceable_motion: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct KeyboardRecord {
    keycode: u32,
    unicode: u32,
    modifiers: u32,
    pressed: bool,
}

#[derive(Clone, Copy, Debug)]
enum InputRecord {
    Pointer(PointerRecord),
    Keyboard(KeyboardRecord),
}

fn flutter_scroll_delta(
    amount: Option<f64>,
    v120: Option<f64>,
    source: AxisSource,
    scroll_speed_factor: f64,
) -> f64 {
    // Smithay reports finger/continuous scrolling in pixels, but mouse-wheel
    // `amount` is the physical angle (normally 15 degrees per click). Prefer
    // the logical v120 step for wheels and match Flutter's Linux embedder,
    // which maps one wheel click to 53 physical pixels.
    let delta = v120.map_or_else(
        || amount.unwrap_or(0.0),
        |value| value * FLUTTER_MOUSE_WHEEL_SCROLL_PIXELS / V120_UNITS_PER_WHEEL_STEP,
    );
    if source == AxisSource::Finger {
        delta * scroll_speed_factor
    } else {
        delta
    }
}

#[derive(Debug)]
pub struct InputQueue {
    size: Size<i32, Logical>,
    pointer_x: f64,
    pointer_y: f64,
    pointer_buttons: i64,
    mouse_added: bool,
    touch_positions: HashMap<i32, (f64, f64)>,
    events: VecDeque<InputRecord>,
}

impl Default for InputQueue {
    fn default() -> Self {
        Self::new(PixelSize::new(1, 1))
    }
}

impl InputQueue {
    pub fn new(size: PixelSize) -> Self {
        let width = i32::try_from(size.width).unwrap_or(i32::MAX).max(1);
        let height = i32::try_from(size.height).unwrap_or(i32::MAX).max(1);
        Self {
            size: (width, height).into(),
            pointer_x: f64::from(width) / 2.0,
            pointer_y: f64::from(height) / 2.0,
            pointer_buttons: 0,
            mouse_added: false,
            touch_positions: HashMap::with_capacity(10),
            events: VecDeque::with_capacity(64),
        }
    }

    pub fn resize(&mut self, size: PixelSize) {
        let width = i32::try_from(size.width).unwrap_or(i32::MAX).max(1);
        let height = i32::try_from(size.height).unwrap_or(i32::MAX).max(1);
        self.size = (width, height).into();
        self.pointer_x = self.pointer_x.clamp(0.0, f64::from(width));
        self.pointer_y = self.pointer_y.clamp(0.0, f64::from(height));
        // This resize follows a full Flutter engine restart during a topology
        // transaction. The new engine has observed no device lifecycle yet,
        // so retaining Add/Down state from the retired generation would make
        // its first pointer packet invalid. Preserve only the physical
        // position and let subsequent input establish a fresh lifecycle.
        self.pointer_buttons = 0;
        self.mouse_added = false;
        self.events.clear();
        self.touch_positions.clear();
    }

    /// Updates the desktop bounds without synthesizing a new input device
    /// generation. Transform-only topology changes keep the engine alive, so
    /// pressed buttons and touch contacts must remain coherent.
    pub fn resize_preserving_state(&mut self, size: PixelSize) {
        let width = i32::try_from(size.width).unwrap_or(i32::MAX).max(1);
        let height = i32::try_from(size.height).unwrap_or(i32::MAX).max(1);
        self.size = (width, height).into();
        self.pointer_x = self.pointer_x.clamp(0.0, f64::from(width));
        self.pointer_y = self.pointer_y.clamp(0.0, f64::from(height));
        for position in self.touch_positions.values_mut() {
            position.0 = position.0.clamp(0.0, f64::from(width));
            position.1 = position.1.clamp(0.0, f64::from(height));
        }
    }

    pub fn has_pending(&self) -> bool {
        !self.events.is_empty()
    }

    pub fn handle(&mut self, event: &SmithayInputEvent<LibinputInputBackend>) {
        self.handle_with_scroll_speed_factor(event, 1.0);
    }

    pub fn handle_with_scroll_speed_factor(
        &mut self,
        event: &SmithayInputEvent<LibinputInputBackend>,
        scroll_speed_factor: f64,
    ) {
        match event {
            // Mouse motion must enter through `handle_pointer_motion_at`.
            // Libinput deltas are not an absolute-position authority: the
            // compositor may clamp, confine, lock, or warp the pointer before
            // Flutter observes it. Integrating them here would make Flutter's
            // hit-test position drift away from the Wayland seat.
            SmithayInputEvent::PointerMotion { .. }
            | SmithayInputEvent::PointerMotionAbsolute { .. } => {}
            SmithayInputEvent::PointerButton { event, .. } => {
                let Some(mask) = mouse_button_mask(event.button_code()) else {
                    return;
                };
                self.ensure_mouse_added();
                let was_pressed = self.pointer_buttons != 0;
                match event.state() {
                    ButtonState::Pressed => self.pointer_buttons |= mask,
                    ButtonState::Released => self.pointer_buttons &= !mask,
                }
                let is_pressed = self.pointer_buttons != 0;
                self.push_mouse(
                    match (was_pressed, is_pressed) {
                        (false, true) => sys::FlutterPointerPhase_kDown,
                        (true, false) => sys::FlutterPointerPhase_kUp,
                        _ => sys::FlutterPointerPhase_kMove,
                    },
                    false,
                );
            }
            SmithayInputEvent::PointerAxis { event, .. } => {
                self.ensure_mouse_added();
                let scroll_x = flutter_scroll_delta(
                    event.amount(Axis::Horizontal),
                    event.amount_v120(Axis::Horizontal),
                    event.source(),
                    scroll_speed_factor,
                );
                let scroll_y = flutter_scroll_delta(
                    event.amount(Axis::Vertical),
                    event.amount_v120(Axis::Vertical),
                    event.source(),
                    scroll_speed_factor,
                );
                if scroll_x != 0.0 || scroll_y != 0.0 {
                    self.push(InputRecord::Pointer(PointerRecord {
                        phase: if self.pointer_buttons == 0 {
                            sys::FlutterPointerPhase_kHover
                        } else {
                            sys::FlutterPointerPhase_kMove
                        },
                        x: self.pointer_x,
                        y: self.pointer_y,
                        device: 0,
                        signal_kind: sys::FlutterPointerSignalKind_kFlutterPointerSignalKindScroll,
                        scroll_x,
                        scroll_y,
                        device_kind: sys::FlutterPointerDeviceKind_kFlutterPointerDeviceKindMouse,
                        buttons: self.pointer_buttons,
                        replaceable_motion: false,
                    }));
                }
            }
            SmithayInputEvent::TouchDown { event, .. } => {
                let position = event.position_transformed(self.size);
                let device = touch_device(event.slot());
                self.touch_positions
                    .insert(device, (position.x, position.y));
                self.push_touch(
                    sys::FlutterPointerPhase_kAdd,
                    position.x,
                    position.y,
                    device,
                    false,
                );
                self.push_touch(
                    sys::FlutterPointerPhase_kDown,
                    position.x,
                    position.y,
                    device,
                    false,
                );
            }
            SmithayInputEvent::TouchMotion { event, .. } => {
                let position = event.position_transformed(self.size);
                let device = touch_device(event.slot());
                self.touch_positions
                    .insert(device, (position.x, position.y));
                self.push_touch(
                    sys::FlutterPointerPhase_kMove,
                    position.x,
                    position.y,
                    device,
                    true,
                );
            }
            SmithayInputEvent::TouchUp { event, .. } => {
                let device = touch_device(event.slot());
                let (x, y) = self.touch_positions.remove(&device).unwrap_or((0.0, 0.0));
                self.push_touch(sys::FlutterPointerPhase_kUp, x, y, device, false);
                self.push_touch(sys::FlutterPointerPhase_kRemove, x, y, device, false);
            }
            SmithayInputEvent::TouchCancel { event, .. } => {
                let device = touch_device(event.slot());
                let (x, y) = self.touch_positions.remove(&device).unwrap_or((0.0, 0.0));
                self.push_touch(sys::FlutterPointerPhase_kCancel, x, y, device, false);
                self.push_touch(sys::FlutterPointerPhase_kRemove, x, y, device, false);
            }
            _ => {}
        }
    }

    /// Queues a touch position already projected into Flutter's physical
    /// desktop pixels. Output rotation is owned by the compositor, so passing
    /// libinput's native-axis coordinates through `position_transformed`
    /// would make Flutter disagree with Wayland hit testing.
    pub fn handle_touch_at(
        &mut self,
        event: &SmithayInputEvent<LibinputInputBackend>,
        x: f64,
        y: f64,
    ) {
        let x = x.clamp(0.0, f64::from(self.size.w));
        let y = y.clamp(0.0, f64::from(self.size.h));
        match event {
            SmithayInputEvent::TouchDown { event, .. } => {
                let device = touch_device(event.slot());
                self.touch_positions.insert(device, (x, y));
                self.push_touch(sys::FlutterPointerPhase_kAdd, x, y, device, false);
                self.push_touch(sys::FlutterPointerPhase_kDown, x, y, device, false);
            }
            SmithayInputEvent::TouchMotion { event, .. } => {
                let device = touch_device(event.slot());
                self.touch_positions.insert(device, (x, y));
                self.push_touch(sys::FlutterPointerPhase_kMove, x, y, device, true);
            }
            _ => debug_assert!(false, "touch position supplied for a non-positional event"),
        }
    }

    /// Aligns Flutter's mouse state to the compositor-owned desktop position.
    ///
    /// This does not emit an event or start a Flutter device lifecycle. It is
    /// used before semantic mouse transitions and after topology changes so
    /// their coordinates can never inherit independently integrated motion.
    pub fn synchronize_pointer_position(&mut self, x: f64, y: f64) {
        debug_assert!(x.is_finite() && y.is_finite());
        if !x.is_finite() || !y.is_finite() {
            return;
        }
        self.pointer_x = x.clamp(0.0, f64::from(self.size.w));
        self.pointer_y = y.clamp(0.0, f64::from(self.size.h));
    }

    /// Queues mouse motion at the position already resolved by the compositor.
    pub fn handle_pointer_motion_at(&mut self, x: f64, y: f64) {
        self.synchronize_pointer_position(x, y);
        self.ensure_mouse_added();
        self.push_mouse(
            if self.pointer_buttons == 0 {
                sys::FlutterPointerPhase_kHover
            } else {
                sys::FlutterPointerPhase_kMove
            },
            true,
        );
    }

    /// Ends Flutter's mouse-device lifecycle when compositor routing leaves
    /// the shell input endpoint.
    pub fn handle_pointer_leave_at(&mut self, x: f64, y: f64) {
        self.synchronize_pointer_position(x, y);
        if !self.mouse_added {
            return;
        }
        // A compositor drag can route motion through Smithay while Flutter
        // still owns the pressed-button lifecycle. Defer Remove until the
        // matching Up has reached Flutter; a later client-routed sample will
        // retry this idempotently.
        if self.pointer_buttons != 0 {
            return;
        }
        self.push_mouse(sys::FlutterPointerPhase_kRemove, false);
        self.mouse_added = false;
    }

    pub fn mouse_lifecycle_active(&self) -> bool {
        self.mouse_added
    }

    pub fn pointer_captured(&self) -> bool {
        self.pointer_buttons != 0
    }

    pub fn cancel_device_lifecycles(&mut self, pointer: bool, touch: bool) {
        if pointer {
            if self.mouse_added {
                if self.pointer_buttons != 0 {
                    self.pointer_buttons = 0;
                    self.push_mouse(sys::FlutterPointerPhase_kCancel, false);
                }
                self.push_mouse(sys::FlutterPointerPhase_kRemove, false);
            }
            self.pointer_buttons = 0;
            self.mouse_added = false;
        }

        if touch {
            let mut positions = self.touch_positions.drain().collect::<Vec<_>>();
            positions.sort_unstable_by_key(|(device, _)| *device);
            for (device, (x, y)) in positions {
                self.push_touch(sys::FlutterPointerPhase_kCancel, x, y, device, false);
                self.push_touch(sys::FlutterPointerPhase_kRemove, x, y, device, false);
            }
        }
    }

    pub fn handle_keyboard(
        &mut self,
        key: KeysymHandle<'_>,
        state: KeyState,
        modifiers: &ModifiersState,
    ) {
        let unicode = key.modified_sym().key_char().map(u32::from).unwrap_or(0);
        self.handle_keyboard_with_unicode(key.raw_code().raw(), state, modifiers, unicode);
    }

    pub fn handle_keyboard_with_unicode(
        &mut self,
        xkb_keycode: u32,
        state: KeyState,
        modifiers: &ModifiersState,
        unicode: u32,
    ) {
        let keycode = xkb_keycode.saturating_sub(8);
        self.push(InputRecord::Keyboard(KeyboardRecord {
            keycode,
            unicode,
            modifiers: glfw_modifiers(modifiers),
            pressed: state == KeyState::Pressed,
        }));
    }

    fn ensure_mouse_added(&mut self) {
        if self.mouse_added {
            return;
        }
        self.mouse_added = true;
        self.push_mouse(sys::FlutterPointerPhase_kAdd, false);
    }

    fn push_mouse(&mut self, phase: sys::FlutterPointerPhase, replaceable_motion: bool) {
        self.push(InputRecord::Pointer(PointerRecord {
            phase,
            x: self.pointer_x,
            y: self.pointer_y,
            device: 0,
            signal_kind: sys::FlutterPointerSignalKind_kFlutterPointerSignalKindNone,
            scroll_x: 0.0,
            scroll_y: 0.0,
            device_kind: sys::FlutterPointerDeviceKind_kFlutterPointerDeviceKindMouse,
            buttons: self.pointer_buttons,
            replaceable_motion,
        }));
    }

    fn push_touch(
        &mut self,
        phase: sys::FlutterPointerPhase,
        x: f64,
        y: f64,
        device: i32,
        replaceable_motion: bool,
    ) {
        self.push(InputRecord::Pointer(PointerRecord {
            phase,
            x,
            y,
            device,
            signal_kind: sys::FlutterPointerSignalKind_kFlutterPointerSignalKindNone,
            scroll_x: 0.0,
            scroll_y: 0.0,
            device_kind: sys::FlutterPointerDeviceKind_kFlutterPointerDeviceKindTouch,
            buttons: 0,
            replaceable_motion,
        }));
    }

    fn push(&mut self, event: InputRecord) {
        push_bounded_input(&mut self.events, event, MAX_QUEUED_INPUT_EVENTS);
    }
}

fn push_bounded_input(events: &mut VecDeque<InputRecord>, event: InputRecord, capacity: usize) {
    if capacity == 0 {
        return;
    }

    if let Some(device) = event.replaceable_motion_device() {
        // Keep at most one sample per device in the replaceable tail. Removing
        // and appending (instead of overwriting in place) preserves the order
        // of interleaved multi-touch samples by their most recent occurrence.
        let replace = events
            .iter()
            .enumerate()
            .rev()
            .take_while(|(_, queued)| queued.replaceable_motion_device().is_some())
            .find_map(|(index, queued)| {
                (queued.replaceable_motion_device() == Some(device)).then_some(index)
            });
        if let Some(index) = replace {
            events.remove(index);
            events.push_back(event);
            return;
        }
    }

    if events.len() >= capacity {
        if let Some(index) = events
            .iter()
            .position(|queued| queued.replaceable_motion_device().is_some())
        {
            events.remove(index);
        } else if event.replaceable_motion_device().is_some() {
            // A fresh position sample must never displace a queued Add,
            // Down/Up, button-state change or keyboard event.
            return;
        } else {
            // A finite queue cannot retain an unbounded stream made entirely
            // of semantic transitions. This pathological fallback keeps the
            // hard bound; ordinary motion floods take the branches above.
            events.pop_front();
        }
    }
    events.push_back(event);
}

impl InputRecord {
    fn replaceable_motion_device(self) -> Option<i32> {
        match self {
            Self::Pointer(event) if event.replaceable_motion => Some(event.device),
            Self::Pointer(_) | Self::Keyboard(_) => None,
        }
    }
}

fn glfw_modifiers(modifiers: &ModifiersState) -> u32 {
    u32::from(modifiers.shift)
        | (u32::from(modifiers.ctrl) << 1)
        | (u32::from(modifiers.alt) << 2)
        | (u32::from(modifiers.logo) << 3)
        | (u32::from(modifiers.caps_lock) << 4)
        | (u32::from(modifiers.num_lock) << 5)
}

fn glfw_keycode(keycode: u32) -> u32 {
    match keycode {
        1 => 256,                   // Escape
        2..=10 => 49 + keycode - 2, // 1..9
        11 => 48,                   // 0
        12 => 45,                   // Minus
        13 => 61,                   // Equal
        14 => 259,                  // Backspace
        15 => 258,                  // Tab
        16..=25 => [81, 87, 69, 82, 84, 89, 85, 73, 79, 80][(keycode - 16) as usize],
        26 => 91,  // Left bracket
        27 => 93,  // Right bracket
        28 => 257, // Enter
        29 => 341, // Left control
        30..=38 => [65, 83, 68, 70, 71, 72, 74, 75, 76][(keycode - 30) as usize],
        39 => 59,  // Semicolon
        40 => 39,  // Apostrophe
        41 => 96,  // Grave accent
        42 => 340, // Left shift
        43 => 92,  // Backslash
        44..=50 => [90, 88, 67, 86, 66, 78, 77][(keycode - 44) as usize],
        51 => 44,  // Comma
        52 => 46,  // Period
        53 => 47,  // Slash
        54 => 344, // Right shift
        55 => 332, // Keypad multiply
        56 => 342, // Left alt
        57 => 32,  // Space
        58 => 280, // Caps lock
        59..=68 => 290 + keycode - 59,
        69 => 282,       // Num lock
        70 => 281,       // Scroll lock
        71 => 327,       // Keypad 7
        72 => 328,       // Keypad 8
        73 => 329,       // Keypad 9
        74 => 333,       // Keypad subtract
        75 => 324,       // Keypad 4
        76 => 325,       // Keypad 5
        77 => 326,       // Keypad 6
        78 => 334,       // Keypad add
        79 => 321,       // Keypad 1
        80 => 322,       // Keypad 2
        81 => 323,       // Keypad 3
        82 => 320,       // Keypad 0
        83 | 121 => 330, // Keypad decimal/comma
        87 => 300,       // F11
        88 => 301,       // F12
        96 => 335,       // Keypad enter
        97 => 345,       // Right control
        98 => 331,       // Keypad divide
        99 => 283,       // Print screen
        100 => 346,      // Right alt
        102 => 268,      // Home
        103 => 265,      // Up
        104 => 266,      // Page up
        105 => 263,      // Left
        106 => 262,      // Right
        107 => 269,      // End
        108 => 264,      // Down
        109 => 267,      // Page down
        110 => 260,      // Insert
        111 => 261,      // Delete
        117 => 336,      // Keypad equal
        119 => 284,      // Pause
        125 => 343,      // Left super
        126 => 347,      // Right super
        127 => 348,      // Menu
        183..=194 => 302 + keycode - 183,
        _ => keycode,
    }
}

fn mouse_button_mask(button: u32) -> Option<i64> {
    match button {
        0x110 => Some(1),
        0x111 => Some(2),
        0x112 => Some(4),
        0x113 | 0x116 => Some(8),
        0x114 | 0x115 => Some(16),
        _ => None,
    }
}

fn touch_device(slot: smithay::backend::input::TouchSlot) -> i32 {
    i32::from(slot).saturating_add(1).max(1)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum BufferState {
    Free,
    Rendering,
    Ready,
    Pending,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RenderTargetBlocked {
    ReadyHandoff,
    PoolExhausted,
}

#[derive(Clone, Copy, Debug)]
struct OutputPoolDescriptor<'a> {
    output_id: OutputId,
    render_view_id: RenderViewId,
    configuration_generation: u64,
    size: PixelSize,
    initial_scanout: usize,
    framebuffers: &'a [u32],
}

#[derive(Debug)]
struct OutputBufferSlot {
    framebuffer: u32,
    state: BufferState,
    output_refs: usize,
    fence: Option<OwnedFd>,
    /// Pixels actually repainted while producing the Ready generation. This
    /// is distinct from `damage`, which is the repair history the slot still
    /// needs before it can represent the newest scene.
    ready_damage: Option<DamageRegion>,
    damage: DamageRegion,
    screenshot_request_id: Option<u64>,
    rendered_at: Option<Instant>,
    ready_transaction: u64,
    request: Option<OutputFrameRequest>,
}

#[derive(Debug)]
struct OutputBufferPool {
    output_id: OutputId,
    render_view_id: RenderViewId,
    configuration_generation: u64,
    size: PixelSize,
    slots: Vec<OutputBufferSlot>,
    authorized_request: Option<AuthorizedOutputRequest>,
}

#[derive(Clone, Copy, Debug)]
struct AuthorizedOutputRequest {
    request: OutputFrameRequest,
    authorized_at: Instant,
}

#[derive(Debug)]
struct OutputBufferBroker {
    pools: Vec<OutputBufferPool>,
    transaction: u64,
    next_screenshot: Option<(OutputId, u64)>,
}

#[derive(Debug)]
pub struct ReadyOutputFrame {
    pub output_id: OutputId,
    pub render_view_id: RenderViewId,
    pub configuration_generation: u64,
    pub index: usize,
    pub fence: Option<OwnedFd>,
    pub damage: DamageRegion,
    pub screenshot_request_id: Option<u64>,
    pub rendered_at: Option<Instant>,
    pub request: OutputFrameRequest,
}

impl OutputBufferBroker {
    fn new<'a>(
        descriptors: impl IntoIterator<Item = OutputPoolDescriptor<'a>>,
    ) -> Result<Self, &'static str> {
        let mut output_ids = HashSet::new();
        let mut render_view_ids = HashSet::new();
        let mut framebuffers = HashSet::new();
        let mut pools = Vec::new();
        let mut generation = None;
        for descriptor in descriptors {
            if descriptor.configuration_generation == 0
                || generation.is_some_and(|value| value != descriptor.configuration_generation)
                || !output_ids.insert(descriptor.output_id)
                || !render_view_ids.insert(descriptor.render_view_id)
                || descriptor.size.width == 0
                || descriptor.size.height == 0
                || descriptor.initial_scanout >= descriptor.framebuffers.len()
                || descriptor.framebuffers.len() < 3
                || descriptor
                    .framebuffers
                    .iter()
                    .any(|framebuffer| *framebuffer == 0 || !framebuffers.insert(*framebuffer))
            {
                return Err("invalid physical output framebuffer pool");
            }
            generation = Some(descriptor.configuration_generation);
            let slots = descriptor
                .framebuffers
                .iter()
                .copied()
                .enumerate()
                .map(|(index, framebuffer)| OutputBufferSlot {
                    framebuffer,
                    state: BufferState::Free,
                    output_refs: usize::from(index == descriptor.initial_scanout),
                    fence: None,
                    ready_damage: None,
                    damage: DamageRegion::full(descriptor.size.width, descriptor.size.height),
                    screenshot_request_id: None,
                    rendered_at: None,
                    ready_transaction: 0,
                    request: None,
                })
                .collect();
            pools.push(OutputBufferPool {
                output_id: descriptor.output_id,
                render_view_id: descriptor.render_view_id,
                configuration_generation: descriptor.configuration_generation,
                size: descriptor.size,
                slots,
                authorized_request: None,
            });
        }
        if pools.is_empty() {
            return Err("physical output framebuffer pools are empty");
        }
        pools.sort_by_key(|pool| pool.render_view_id);
        Ok(Self {
            pools,
            transaction: 0,
            next_screenshot: None,
        })
    }

    fn begin_transaction(&mut self) {
        self.transaction = self.transaction.wrapping_add(1).max(1);
        for pool in &mut self.pools {
            for slot in &mut pool.slots {
                if slot.state == BufferState::Rendering && slot.output_refs == 0 {
                    slot.damage.invalidate();
                    slot.state = BufferState::Free;
                    slot.fence = None;
                    slot.ready_damage = None;
                    slot.rendered_at = None;
                    slot.screenshot_request_id = None;
                    slot.ready_transaction = 0;
                    slot.request = None;
                }
            }
        }
    }

    fn target_available(&self, output: OutputId) -> bool {
        self.pools
            .iter()
            .find(|pool| pool.output_id == output)
            .is_some_and(|pool| {
                pool.authorized_request.is_none()
                    && !pool
                        .slots
                        .iter()
                        .any(|slot| slot.state != BufferState::Free)
                    && pool
                        .slots
                        .iter()
                        .any(|slot| slot.state == BufferState::Free && slot.output_refs == 0)
            })
    }

    fn authorize(&mut self, request: OutputFrameRequest, now: Instant) -> Option<i64> {
        if request.dirty_serial == 0 || !self.target_available(request.tick.output) {
            return None;
        }
        let pool = self
            .pools
            .iter_mut()
            .find(|pool| pool.output_id == request.tick.output)?;
        pool.authorized_request = Some(AuthorizedOutputRequest {
            request,
            authorized_at: now,
        });
        Some(pool.render_view_id.get())
    }

    fn cancel_authorizations(&mut self, render_view_ids: &[i64]) {
        for pool in &mut self.pools {
            if render_view_ids.contains(&pool.render_view_id.get()) {
                pool.authorized_request = None;
            }
        }
    }

    fn expire_authorizations(&mut self, now: Instant) -> usize {
        let mut expired = 0;
        for pool in &mut self.pools {
            let should_expire = pool.authorized_request.is_some_and(|authorization| {
                now.saturating_duration_since(authorization.authorized_at)
                    >= authorization.request.tick.interval.saturating_mul(2)
            });
            if should_expire {
                pool.authorized_request = None;
                expired += 1;
            }
        }
        expired
    }

    fn acquire(
        &mut self,
        render_view_id: i64,
        size: PixelSize,
    ) -> Result<u32, RenderTargetBlocked> {
        let Some(pool) = self
            .pools
            .iter_mut()
            .find(|pool| pool.render_view_id.get() == render_view_id && pool.size == size)
        else {
            return Err(RenderTargetBlocked::PoolExhausted);
        };
        let Some(authorization) = pool.authorized_request else {
            return Err(RenderTargetBlocked::PoolExhausted);
        };
        if pool
            .slots
            .iter()
            .any(|slot| slot.state == BufferState::Ready)
        {
            return Err(RenderTargetBlocked::ReadyHandoff);
        }
        let Some(slot_index) = pool
            .slots
            .iter()
            .position(|slot| slot.state == BufferState::Free && slot.output_refs == 0)
        else {
            return Err(RenderTargetBlocked::PoolExhausted);
        };
        pool.authorized_request = None;
        let slot = &mut pool.slots[slot_index];
        slot.state = BufferState::Rendering;
        slot.fence = None;
        slot.ready_damage = None;
        slot.rendered_at = None;
        slot.screenshot_request_id = self
            .next_screenshot
            .filter(|(output, _)| *output == pool.output_id)
            .map(|(_, request_id)| request_id);
        slot.ready_transaction = 0;
        slot.request = Some(authorization.request);
        Ok(slot.framebuffer)
    }

    fn validate_backing_store(
        &self,
        render_view_id: i64,
        framebuffer: u32,
        size: PixelSize,
    ) -> bool {
        self.pools.iter().any(|pool| {
            pool.render_view_id.get() == render_view_id
                && pool.size == size
                && pool
                    .slots
                    .iter()
                    .any(|slot| slot.framebuffer == framebuffer)
        })
    }

    fn mark_ready(
        &mut self,
        render_view_id: i64,
        framebuffer: u32,
        frame_damage: &[sys::FlutterRect],
        buffer_damage: &[sys::FlutterRect],
        fence: Option<OwnedFd>,
        rendered_at: Option<Instant>,
    ) -> bool {
        let Some(pool) = self
            .pools
            .iter_mut()
            .find(|pool| pool.render_view_id.get() == render_view_id)
        else {
            return false;
        };
        let Some(index) = pool
            .slots
            .iter()
            .position(|slot| slot.framebuffer == framebuffer)
        else {
            return false;
        };
        if pool.slots[index].state != BufferState::Rendering
            || pool
                .slots
                .iter()
                .enumerate()
                .any(|(other_index, slot)| other_index != index && slot.state == BufferState::Ready)
        {
            return false;
        }
        let mut frame_damage_region = DamageRegion::empty(pool.size.width, pool.size.height);
        frame_damage_region.replace_from_flutter(frame_damage);
        let mut buffer_damage_region = DamageRegion::empty(pool.size.width, pool.size.height);
        buffer_damage_region.replace_from_flutter(buffer_damage);
        for (other_index, slot) in pool.slots.iter_mut().enumerate() {
            if other_index != index {
                slot.damage.union(&frame_damage_region);
            }
        }
        let slot = &mut pool.slots[index];
        slot.damage.clear();
        slot.ready_damage = Some(buffer_damage_region);
        slot.state = BufferState::Ready;
        slot.fence = fence;
        slot.rendered_at = rendered_at;
        slot.ready_transaction = self.transaction;
        true
    }

    fn finish_transaction(&mut self) -> Vec<ReadyOutputFrame> {
        let transaction = self.transaction;
        let mut outputs = Vec::with_capacity(self.pools.len());
        for pool in &mut self.pools {
            let Some(index) = pool.slots.iter().position(|slot| {
                slot.state == BufferState::Ready && slot.ready_transaction == transaction
            }) else {
                continue;
            };
            let slot = &mut pool.slots[index];
            slot.state = BufferState::Pending;
            slot.ready_transaction = 0;
            let request = slot
                .request
                .take()
                .expect("a ready output must retain its timeline request");
            outputs.push(ReadyOutputFrame {
                output_id: pool.output_id,
                render_view_id: pool.render_view_id,
                configuration_generation: pool.configuration_generation,
                index,
                fence: slot.fence.take(),
                damage: slot
                    .ready_damage
                    .take()
                    .expect("a ready output must retain its raster damage"),
                screenshot_request_id: slot.screenshot_request_id.take(),
                rendered_at: slot.rendered_at.take(),
                request,
            });
        }
        if let Some((output, request_id)) = self.next_screenshot
            && outputs.iter().any(|frame| {
                frame.output_id == output && frame.screenshot_request_id == Some(request_id)
            })
        {
            self.next_screenshot = None;
        }
        outputs
    }

    fn populate_existing_damage(
        &self,
        framebuffer: isize,
        output: &mut Vec<sys::FlutterRect>,
    ) -> bool {
        let Ok(framebuffer) = u32::try_from(framebuffer) else {
            return false;
        };
        let Some(slot) = self
            .pools
            .iter()
            .flat_map(|pool| &pool.slots)
            .find(|slot| slot.framebuffer == framebuffer)
        else {
            return false;
        };
        slot.damage.write_flutter(output);
        true
    }

    fn publish(&mut self, output: &ReadyOutputFrame) -> Result<(), &'static str> {
        let slot = self
            .pools
            .iter_mut()
            .find(|pool| pool.output_id == output.output_id)
            .and_then(|pool| pool.slots.get_mut(output.index))
            .ok_or("Flutter output publication slot is out of range")?;
        if slot.state != BufferState::Pending || slot.output_refs != 0 {
            return Err("Flutter output publication slot is not exclusively pending");
        }
        slot.state = BufferState::Free;
        slot.output_refs = 1;
        Ok(())
    }

    fn release_output(&mut self, output: OutputId, index: usize) -> Result<(), &'static str> {
        let slot = self
            .pools
            .iter_mut()
            .find(|pool| pool.output_id == output)
            .and_then(|pool| pool.slots.get_mut(index))
            .ok_or("Flutter released output slot is out of range")?;
        if slot.output_refs == 0 {
            return Err("released a Flutter buffer without an output owner");
        }
        slot.output_refs -= 1;
        Ok(())
    }

    fn tag_next_frame_for_screenshot(
        &mut self,
        output: OutputId,
        request_id: u64,
    ) -> Result<(), &'static str> {
        if request_id == 0
            || self.next_screenshot.is_some()
            || !self.pools.iter().any(|pool| pool.output_id == output)
        {
            return Err("a screenshot frame is already pending");
        }
        self.next_screenshot = Some((output, request_id));
        Ok(())
    }

    fn cancel_screenshot_frame(&mut self, request_id: u64) {
        if self
            .next_screenshot
            .is_some_and(|(_, pending)| pending == request_id)
        {
            self.next_screenshot = None;
        }
        for slot in self.pools.iter_mut().flat_map(|pool| &mut pool.slots) {
            if slot.screenshot_request_id == Some(request_id) {
                slot.screenshot_request_id = None;
            }
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum VsyncRegistration {
    Accepted,
    Duplicate,
    AtCapacity,
}

#[derive(Debug, Default)]
struct PendingVsyncBatons {
    values: VecDeque<isize>,
}

impl PendingVsyncBatons {
    fn register(&mut self, baton: isize) -> VsyncRegistration {
        if self.values.contains(&baton) {
            return VsyncRegistration::Duplicate;
        }
        if self.values.len() == MAX_PENDING_VSYNC_BATONS {
            return VsyncRegistration::AtCapacity;
        }
        self.values.push_back(baton);
        VsyncRegistration::Accepted
    }

    fn complete(&mut self, baton: isize) -> bool {
        let Some(index) = self.values.iter().position(|candidate| *candidate == baton) else {
            return false;
        };
        self.values.remove(index);
        true
    }

    fn has_pending(&self) -> bool {
        !self.values.is_empty()
    }

    fn take_next(&mut self) -> Option<isize> {
        self.values.pop_front()
    }

    fn restore_front(&mut self, baton: isize) {
        debug_assert!(self.values.len() < MAX_PENDING_VSYNC_BATONS);
        debug_assert!(!self.values.contains(&baton));
        self.values.push_front(baton);
    }

    fn take_all(&mut self) -> VecDeque<isize> {
        mem::take(&mut self.values)
    }
}

struct ContextBinding {
    context: egl_context::SharedEglContext,
    owner: Option<ThreadId>,
}

impl ContextBinding {
    fn new(context: egl_context::SharedEglContext) -> Self {
        Self {
            context,
            owner: None,
        }
    }

    fn make_current(&mut self) -> bool {
        let thread = thread::current().id();
        if self.owner.is_some_and(|owner| owner != thread) {
            error!("refusing to bind an EGL context still owned by another thread");
            return false;
        }
        // SAFETY: ownership above prevents the context from becoming current
        // on two threads. Flutter later releases it through clear_current().
        match unsafe { self.context.make_current() } {
            Ok(()) => {
                self.owner = Some(thread);
                true
            }
            Err(error) => {
                error!(%error, "could not make Flutter EGL context current");
                false
            }
        }
    }

    fn clear_current(&mut self) -> bool {
        let thread = thread::current().id();
        if self.owner.is_some_and(|owner| owner != thread) {
            error!("refusing to unbind a Flutter EGL context from the wrong thread");
            return false;
        }
        match self.context.unbind() {
            Ok(()) => {
                self.owner = None;
                true
            }
            Err(error) => {
                error!(%error, "could not clear Flutter EGL context");
                false
            }
        }
    }
}

#[derive(Clone, Copy)]
struct GlApi {
    gen_textures: unsafe extern "system" fn(i32, *mut u32),
    bind_texture: unsafe extern "system" fn(u32, u32),
    tex_parameter_i: unsafe extern "system" fn(u32, u32, i32),
    tex_image_2d: unsafe extern "system" fn(u32, i32, i32, i32, i32, i32, u32, u32, *const c_void),
    image_target_texture: unsafe extern "system" fn(u32, *const c_void),
    delete_textures: unsafe extern "system" fn(i32, *const u32),
    gen_framebuffers: unsafe extern "system" fn(i32, *mut u32),
    bind_framebuffer: unsafe extern "system" fn(u32, u32),
    framebuffer_texture_2d: unsafe extern "system" fn(u32, u32, u32, u32, i32),
    check_framebuffer_status: unsafe extern "system" fn(u32) -> u32,
    create_shader: unsafe extern "system" fn(u32) -> u32,
    shader_source: unsafe extern "system" fn(u32, i32, *const *const c_char, *const i32),
    compile_shader: unsafe extern "system" fn(u32),
    get_shader_iv: unsafe extern "system" fn(u32, u32, *mut i32),
    get_shader_info_log: unsafe extern "system" fn(u32, i32, *mut i32, *mut c_char),
    delete_shader: unsafe extern "system" fn(u32),
    create_program: unsafe extern "system" fn() -> u32,
    attach_shader: unsafe extern "system" fn(u32, u32),
    link_program: unsafe extern "system" fn(u32),
    get_program_iv: unsafe extern "system" fn(u32, u32, *mut i32),
    get_program_info_log: unsafe extern "system" fn(u32, i32, *mut i32, *mut c_char),
    delete_program: unsafe extern "system" fn(u32),
    use_program: unsafe extern "system" fn(u32),
    get_uniform_location: unsafe extern "system" fn(u32, *const c_char) -> i32,
    uniform_1i: unsafe extern "system" fn(i32, i32),
    active_texture: unsafe extern "system" fn(u32),
    enable: unsafe extern "system" fn(u32),
    disable: unsafe extern "system" fn(u32),
    is_enabled: unsafe extern "system" fn(u32) -> u8,
    get_boolean_v: unsafe extern "system" fn(u32, *mut u8),
    color_mask: unsafe extern "system" fn(u8, u8, u8, u8),
    draw_arrays: unsafe extern "system" fn(u32, i32, i32),
    delete_framebuffers: unsafe extern "system" fn(i32, *const u32),
    gen_renderbuffers: unsafe extern "system" fn(i32, *mut u32),
    bind_renderbuffer: unsafe extern "system" fn(u32, u32),
    renderbuffer_storage: unsafe extern "system" fn(u32, u32, i32, i32),
    framebuffer_renderbuffer: unsafe extern "system" fn(u32, u32, u32, u32),
    delete_renderbuffers: unsafe extern "system" fn(i32, *const u32),
    get_integer_v: unsafe extern "system" fn(u32, *mut i32),
    viewport: unsafe extern "system" fn(i32, i32, i32, i32),
    get_error: unsafe extern "system" fn() -> u32,
    flush: unsafe extern "system" fn(),
    finish: unsafe extern "system" fn(),
}

impl GlApi {
    fn load() -> Result<Self, Box<dyn Error>> {
        macro_rules! symbol {
            ($name:literal, $kind:ty) => {{
                // SAFETY: an EGL context is current while this table is built.
                let address = unsafe { get_proc_address($name) };
                if address.is_null() {
                    return Err(format!("required OpenGL symbol {} is unavailable", $name).into());
                }
                // SAFETY: each concrete signature below comes from GLES2/EGL
                // headers and the symbol was resolved from the active driver.
                unsafe { mem::transmute::<*const c_void, $kind>(address) }
            }};
        }

        Ok(Self {
            gen_textures: symbol!("glGenTextures", unsafe extern "system" fn(i32, *mut u32)),
            bind_texture: symbol!("glBindTexture", unsafe extern "system" fn(u32, u32)),
            tex_parameter_i: symbol!("glTexParameteri", unsafe extern "system" fn(u32, u32, i32)),
            tex_image_2d: symbol!(
                "glTexImage2D",
                unsafe extern "system" fn(u32, i32, i32, i32, i32, i32, u32, u32, *const c_void)
            ),
            image_target_texture: symbol!(
                "glEGLImageTargetTexture2DOES",
                unsafe extern "system" fn(u32, *const c_void)
            ),
            delete_textures: symbol!(
                "glDeleteTextures",
                unsafe extern "system" fn(i32, *const u32)
            ),
            gen_framebuffers: symbol!(
                "glGenFramebuffers",
                unsafe extern "system" fn(i32, *mut u32)
            ),
            bind_framebuffer: symbol!("glBindFramebuffer", unsafe extern "system" fn(u32, u32)),
            framebuffer_texture_2d: symbol!(
                "glFramebufferTexture2D",
                unsafe extern "system" fn(u32, u32, u32, u32, i32)
            ),
            check_framebuffer_status: symbol!(
                "glCheckFramebufferStatus",
                unsafe extern "system" fn(u32) -> u32
            ),
            create_shader: symbol!("glCreateShader", unsafe extern "system" fn(u32) -> u32),
            shader_source: symbol!(
                "glShaderSource",
                unsafe extern "system" fn(u32, i32, *const *const c_char, *const i32)
            ),
            compile_shader: symbol!("glCompileShader", unsafe extern "system" fn(u32)),
            get_shader_iv: symbol!(
                "glGetShaderiv",
                unsafe extern "system" fn(u32, u32, *mut i32)
            ),
            get_shader_info_log: symbol!(
                "glGetShaderInfoLog",
                unsafe extern "system" fn(u32, i32, *mut i32, *mut c_char)
            ),
            delete_shader: symbol!("glDeleteShader", unsafe extern "system" fn(u32)),
            create_program: symbol!("glCreateProgram", unsafe extern "system" fn() -> u32),
            attach_shader: symbol!("glAttachShader", unsafe extern "system" fn(u32, u32)),
            link_program: symbol!("glLinkProgram", unsafe extern "system" fn(u32)),
            get_program_iv: symbol!(
                "glGetProgramiv",
                unsafe extern "system" fn(u32, u32, *mut i32)
            ),
            get_program_info_log: symbol!(
                "glGetProgramInfoLog",
                unsafe extern "system" fn(u32, i32, *mut i32, *mut c_char)
            ),
            delete_program: symbol!("glDeleteProgram", unsafe extern "system" fn(u32)),
            use_program: symbol!("glUseProgram", unsafe extern "system" fn(u32)),
            get_uniform_location: symbol!(
                "glGetUniformLocation",
                unsafe extern "system" fn(u32, *const c_char) -> i32
            ),
            uniform_1i: symbol!("glUniform1i", unsafe extern "system" fn(i32, i32)),
            active_texture: symbol!("glActiveTexture", unsafe extern "system" fn(u32)),
            enable: symbol!("glEnable", unsafe extern "system" fn(u32)),
            disable: symbol!("glDisable", unsafe extern "system" fn(u32)),
            is_enabled: symbol!("glIsEnabled", unsafe extern "system" fn(u32) -> u8),
            get_boolean_v: symbol!("glGetBooleanv", unsafe extern "system" fn(u32, *mut u8)),
            color_mask: symbol!("glColorMask", unsafe extern "system" fn(u8, u8, u8, u8)),
            draw_arrays: symbol!("glDrawArrays", unsafe extern "system" fn(u32, i32, i32)),
            delete_framebuffers: symbol!(
                "glDeleteFramebuffers",
                unsafe extern "system" fn(i32, *const u32)
            ),
            gen_renderbuffers: symbol!(
                "glGenRenderbuffers",
                unsafe extern "system" fn(i32, *mut u32)
            ),
            bind_renderbuffer: symbol!("glBindRenderbuffer", unsafe extern "system" fn(u32, u32)),
            renderbuffer_storage: symbol!(
                "glRenderbufferStorage",
                unsafe extern "system" fn(u32, u32, i32, i32)
            ),
            framebuffer_renderbuffer: symbol!(
                "glFramebufferRenderbuffer",
                unsafe extern "system" fn(u32, u32, u32, u32)
            ),
            delete_renderbuffers: symbol!(
                "glDeleteRenderbuffers",
                unsafe extern "system" fn(i32, *const u32)
            ),
            get_integer_v: symbol!("glGetIntegerv", unsafe extern "system" fn(u32, *mut i32)),
            viewport: symbol!("glViewport", unsafe extern "system" fn(i32, i32, i32, i32)),
            get_error: symbol!("glGetError", unsafe extern "system" fn() -> u32),
            flush: symbol!("glFlush", unsafe extern "system" fn()),
            finish: symbol!("glFinish", unsafe extern "system" fn()),
        })
    }
}

#[derive(Clone, Copy, Debug)]
struct GlTarget {
    output_id: OutputId,
    render_view_id: RenderViewId,
    configuration_generation: u64,
    size: PixelSize,
    buffer_index: usize,
    scanout_image: usize,
    render_image: usize,
    scanout_texture: u32,
    scanout_framebuffer: u32,
    render_texture: u32,
    render_framebuffer: u32,
}

impl GlTarget {
    fn needs_blit(self) -> bool {
        self.render_framebuffer != self.scanout_framebuffer
    }
}

#[derive(Clone, Copy, Debug)]
struct ShaderBlit {
    program: u32,
    source_uniform: i32,
}

#[derive(Debug, Default)]
struct ExternalTextureResourceBudget {
    live: AtomicUsize,
}

impl ExternalTextureResourceBudget {
    fn try_acquire(self: &Arc<Self>) -> Option<ExternalTextureResourcePermit> {
        self.live
            // This counter bounds ownership but publishes no binding data;
            // Arc and the surrounding mutexes provide that synchronization.
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |live| {
                (live < MAX_LIVE_EXTERNAL_TEXTURE_RESOURCES).then_some(live + 1)
            })
            .ok()?;
        Some(ExternalTextureResourcePermit {
            budget: Arc::clone(self),
        })
    }
}

struct ExternalTextureResourcePermit {
    budget: Arc<ExternalTextureResourceBudget>,
}

impl Drop for ExternalTextureResourcePermit {
    fn drop(&mut self) {
        let previous = self.budget.live.fetch_sub(1, Ordering::Relaxed);
        debug_assert!(previous != 0, "external texture resource budget underflow");
    }
}

struct ExternalTextureBinding {
    // The dma-buf file descriptors must remain live for the EGLImage lifetime.
    dmabuf_image: Option<(Dmabuf, usize)>,
    texture: u32,
    _resource_permit: ExternalTextureResourcePermit,
}

struct RetiredExternalBindingQueue {
    bindings: Mutex<Vec<ExternalTextureBinding>>,
    pending: AtomicBool,
}

impl RetiredExternalBindingQueue {
    fn new() -> Self {
        Self {
            bindings: Mutex::new(Vec::new()),
            pending: AtomicBool::new(false),
        }
    }

    fn push(&self, binding: ExternalTextureBinding) {
        lock(&self.bindings).push(binding);
        // Queue contents are published by the mutex; this is only a fast-path
        // hint for avoiding its acquisition.
        self.pending.store(true, Ordering::Relaxed);
    }
}

struct CachedTextureBinding {
    binding: Option<ExternalTextureBinding>,
    retirements: Arc<RetiredExternalBindingQueue>,
}

impl CachedTextureBinding {
    fn texture(&self) -> u32 {
        self.binding.as_ref().map_or(0, |binding| binding.texture)
    }
}

impl Drop for CachedTextureBinding {
    fn drop(&mut self) {
        if let Some(binding) = self.binding.take() {
            self.retirements.push(binding);
        }
    }
}

enum ExternalTextureLeaseResource {
    Dmabuf {
        // The cached EGLImage/texture can outlive an individual Flutter frame,
        // but the producer buffer guard must not: releasing this lease is what
        // eventually permits the producer to recycle its allocation.
        _binding: Arc<CachedTextureBinding>,
        _buffer_guard: Option<ExternalBufferGuard>,
        _resource_permit: ExternalTextureResourcePermit,
    },
    Shm {
        _binding: Arc<CachedTextureBinding>,
        _resource_permit: ExternalTextureResourcePermit,
    },
    Retained {
        // Native producer buffers are copied once into this private texture.
        // Later Flutter frames never sample producer-owned storage after its
        // release fence signals.
        _binding: Arc<CachedTextureBinding>,
        _resource_permit: ExternalTextureResourcePermit,
    },
}

struct PreparedExternalTexture {
    texture_id: i64,
    source_generation: u64,
    width: usize,
    height: usize,
    name: u32,
    resource: ExternalTextureLeaseResource,
    sampled_buffer: Option<ExternalBufferGuard>,
}

type ExternalTextureLeasePool = Mutex<Vec<Box<ExternalTextureLease>>>;

struct ExternalTextureLease {
    resource: Option<ExternalTextureLeaseResource>,
    pool: Weak<ExternalTextureLeasePool>,
}

impl ExternalTextureLease {
    fn retire(mut lease: Box<Self>) {
        // Release buffer guards and resource permits before making this token
        // reusable. Cached GL bindings remain alive through their cache Arc.
        drop(lease.resource.take());
        let Some(pool) = lease.pool.upgrade() else {
            return;
        };
        let mut available = lock(&pool);
        if available.len() < MAX_CACHED_EXTERNAL_TEXTURE_LEASES {
            available.push(lease);
        }
    }
}

struct RecencyEntry<K, V> {
    key: K,
    value: V,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct RecencyCacheStats {
    hits: u64,
    misses: u64,
    capacity_evictions: u64,
    explicit_removals: u64,
}

/// Tiny bounded LRU used on the raster path. The ring is deliberate: Flutter
/// normally visits external textures in the same order every frame, making
/// each oldest-to-newest rotation O(1), while the bounded linear lookup keeps
/// dma-buf identity as Smithay's Arc identity without a second hash-key model.
struct RecencyCache<K, V> {
    entries: VecDeque<RecencyEntry<K, V>>,
    capacity: usize,
    stats: RecencyCacheStats,
}

impl<K: Eq, V: Clone> RecencyCache<K, V> {
    fn new(capacity: usize) -> Self {
        assert!(capacity > 0, "recency cache capacity must be positive");
        Self {
            entries: VecDeque::with_capacity(capacity),
            capacity,
            stats: RecencyCacheStats::default(),
        }
    }

    fn get_by(&mut self, mut matches: impl FnMut(&K) -> bool) -> Option<V> {
        let Some(index) = self.entries.iter().position(|entry| matches(&entry.key)) else {
            if cfg!(test) {
                self.stats.misses = self.stats.misses.saturating_add(1);
            }
            return None;
        };
        if cfg!(test) {
            self.stats.hits = self.stats.hits.saturating_add(1);
        }
        let entry = self
            .entries
            .remove(index)
            .expect("located recency entry disappeared");
        let value = entry.value.clone();
        // Entries are stored oldest-to-newest, avoiding a wrapping/saturating
        // logical clock entirely.
        self.entries.push_back(entry);
        Some(value)
    }

    fn insert(&mut self, key: K, value: V) -> Option<V> {
        if let Some(index) = self.entries.iter().position(|entry| entry.key == key) {
            let mut entry = self
                .entries
                .remove(index)
                .expect("located recency entry disappeared");
            let previous = mem::replace(&mut entry.value, value);
            self.entries.push_back(entry);
            return Some(previous);
        }
        self.entries.push_back(RecencyEntry { key, value });
        if self.entries.len() <= self.capacity {
            return None;
        }
        if cfg!(test) {
            self.stats.capacity_evictions = self.stats.capacity_evictions.saturating_add(1);
        }
        Some(
            self.entries
                .pop_front()
                .expect("over-capacity recency cache is non-empty")
                .value,
        )
    }

    fn remove_where(&mut self, mut predicate: impl FnMut(&K) -> bool) -> Vec<V> {
        let mut removed = Vec::new();
        let mut index = 0;
        while index < self.entries.len() {
            if predicate(&self.entries[index].key) {
                removed.push(
                    self.entries
                        .remove(index)
                        .expect("indexed recency entry disappeared")
                        .value,
                );
            } else {
                index += 1;
            }
        }
        if cfg!(test) {
            self.stats.explicit_removals = self
                .stats
                .explicit_removals
                .saturating_add(u64::try_from(removed.len()).unwrap_or(u64::MAX));
        }
        removed
    }

    #[cfg(test)]
    fn stats(&self) -> RecencyCacheStats {
        self.stats
    }

    fn drain(&mut self) -> Vec<V> {
        self.entries.drain(..).map(|entry| entry.value).collect()
    }
}

/// Independent bounded buffer rings keyed by Flutter external-texture ID.
///
/// A single global LRU becomes a complete miss stream when several clients'
/// rotating DMA-BUF pools collectively exceed its capacity: Flutter visits
/// the textures in a stable order, so each miss evicts the buffer needed by a
/// later texture in the same frame. Partitioning keeps one busy client from
/// evicting every other client's reusable EGLImages. The compositor-wide
/// `ExternalTextureResourceBudget` remains the hard ownership bound.
struct PartitionedRecencyCache<O, K, V> {
    partitions: HashMap<O, RecencyCache<K, V>>,
    capacity_per_partition: usize,
}

impl<O: Eq + Hash, K: Eq, V: Clone> PartitionedRecencyCache<O, K, V> {
    fn new(capacity_per_partition: usize) -> Self {
        assert!(
            capacity_per_partition > 0,
            "partitioned recency cache capacity must be positive"
        );
        Self {
            partitions: HashMap::new(),
            capacity_per_partition,
        }
    }

    fn get_by(&mut self, owner: &O, matches: impl FnMut(&K) -> bool) -> Option<V> {
        self.partitions.get_mut(owner)?.get_by(matches)
    }

    fn insert(&mut self, owner: O, key: K, value: V) -> Option<V> {
        let capacity = self.capacity_per_partition;
        self.partitions
            .entry(owner)
            .or_insert_with(|| RecencyCache::new(capacity))
            .insert(key, value)
    }

    fn remove(&mut self, owner: &O) -> Vec<V> {
        self.partitions
            .remove(owner)
            .map_or_else(Vec::new, |mut partition| partition.drain())
    }

    fn drain(&mut self) -> Vec<V> {
        self.partitions
            .drain()
            .flat_map(|(_, mut partition)| partition.drain())
            .collect()
    }
}

#[derive(Default)]
struct ShmSnapshotPoolState {
    buffers: Vec<Vec<u8>>,
    retained_bytes: usize,
}

pub(super) struct ShmSnapshotPool {
    state: Mutex<ShmSnapshotPoolState>,
}

impl ShmSnapshotPool {
    pub(super) fn new() -> Self {
        Self {
            state: Mutex::new(ShmSnapshotPoolState {
                buffers: Vec::with_capacity(MAX_RECYCLED_SHM_BUFFERS),
                retained_bytes: 0,
            }),
        }
    }

    pub(super) fn acquire(&self, desired_len: usize) -> Vec<u8> {
        let mut state = lock(&self.state);
        let candidate = state
            .buffers
            .iter()
            .enumerate()
            .filter(|(_, buffer)| buffer.capacity() >= desired_len)
            .min_by_key(|(_, buffer)| buffer.capacity())
            .map(|(index, _)| index);
        let Some(index) = candidate else {
            return Vec::new();
        };
        let mut buffer = state.buffers.swap_remove(index);
        state.retained_bytes = state.retained_bytes.saturating_sub(buffer.capacity());
        buffer.clear();
        buffer
    }

    fn recycle(&self, mut buffer: Vec<u8>) {
        buffer.clear();
        let retained = buffer.capacity();
        if retained == 0 || retained > MAX_RECYCLED_SHM_BYTES {
            return;
        }
        let mut state = lock(&self.state);
        let Some(next_retained) = state.retained_bytes.checked_add(retained) else {
            return;
        };
        if state.buffers.len() >= MAX_RECYCLED_SHM_BUFFERS || next_retained > MAX_RECYCLED_SHM_BYTES
        {
            return;
        }
        state.buffers.push(buffer);
        state.retained_bytes = next_retained;
    }
}

struct ShmPixelStorage {
    pixels: Option<Vec<u8>>,
    pool: Weak<ShmSnapshotPool>,
}

impl Drop for ShmPixelStorage {
    fn drop(&mut self) {
        let Some(pixels) = self.pixels.take() else {
            return;
        };
        if let Some(pool) = self.pool.upgrade() {
            pool.recycle(pixels);
        }
    }
}

#[derive(Clone)]
pub(super) struct ShmTextureFrame {
    width: u32,
    height: u32,
    revision: u64,
    rgba: Arc<ShmPixelStorage>,
}

impl ShmTextureFrame {
    #[cfg(test)]
    pub(super) fn new(
        width: u32,
        height: u32,
        revision: u64,
        rgba: Vec<u8>,
    ) -> Result<Self, &'static str> {
        Self::from_pixels(width, height, revision, rgba, Weak::new())
    }

    pub(super) fn new_pooled(
        width: u32,
        height: u32,
        revision: u64,
        rgba: Vec<u8>,
        pool: &Arc<ShmSnapshotPool>,
    ) -> Result<Self, &'static str> {
        Self::from_pixels(width, height, revision, rgba, Arc::downgrade(pool))
    }

    fn from_pixels(
        width: u32,
        height: u32,
        revision: u64,
        rgba: Vec<u8>,
        pool: Weak<ShmSnapshotPool>,
    ) -> Result<Self, &'static str> {
        let expected = usize::try_from(width)
            .ok()
            .and_then(|width| width.checked_mul(usize::try_from(height).ok()?))
            .and_then(|pixels| pixels.checked_mul(4))
            .ok_or("SHM texture dimensions overflow")?;
        if width == 0 || height == 0 || rgba.len() != expected {
            return Err("SHM texture has invalid dimensions or payload length");
        }
        Ok(Self {
            width,
            height,
            revision,
            // Keep the snapshot's Vec allocation intact. Converting Vec<u8>
            // into Arc<[u8]> may copy the complete client frame.
            rgba: Arc::new(ShmPixelStorage {
                pixels: Some(rgba),
                pool,
            }),
        })
    }

    fn pixels(&self) -> &[u8] {
        self.rgba
            .pixels
            .as_deref()
            .expect("live SHM frame lost its pixel storage")
    }

    pub(super) fn width(&self) -> u32 {
        self.width
    }

    pub(super) fn height(&self) -> u32 {
        self.height
    }
}

#[derive(Clone)]
enum ExternalBufferGuard {
    Wayland { _guard: RendererBufferGuard },
    Native(NativeBufferRelease),
}

impl ExternalBufferGuard {
    fn is_native(&self) -> bool {
        matches!(self, Self::Native(_))
    }
}

#[derive(Clone)]
enum ExternalTextureSource {
    Dmabuf {
        dmabuf: Dmabuf,
        buffer_guard: Option<ExternalBufferGuard>,
        revision: u64,
    },
    Shm(ShmTextureFrame),
}

impl ExternalTextureSource {
    fn generation(&self) -> u64 {
        match self {
            Self::Dmabuf { revision, .. } => *revision,
            Self::Shm(frame) => frame.revision,
        }
    }

    fn same_generation(&self, other: &Self) -> bool {
        match (self, other) {
            (
                Self::Dmabuf {
                    dmabuf: current_buffer,
                    revision: current,
                    ..
                },
                Self::Dmabuf {
                    dmabuf: next_buffer,
                    revision: next,
                    ..
                },
            ) => current == next && current_buffer == next_buffer,
            (Self::Shm(current), Self::Shm(next)) => {
                current.revision == next.revision
                    && current.width == next.width
                    && current.height == next.height
                    && Arc::ptr_eq(&current.rgba, &next.rgba)
            }
            _ => false,
        }
    }
}

#[derive(Default)]
struct ExternalTextureSlot {
    current: Option<ExternalTextureSource>,
    queued: Option<ExternalTextureSource>,
    lookahead: Option<ExternalTextureSource>,
    current_sampled: bool,
    expects_sample: bool,
}

impl ExternalTextureSlot {
    fn queue(&mut self, source: ExternalTextureSource, expects_sample: bool) -> bool {
        self.expects_sample = expects_sample;
        let unchanged = self
            .queued
            .as_ref()
            .is_some_and(|candidate| candidate.same_generation(&source))
            || self
                .lookahead
                .as_ref()
                .is_some_and(|candidate| candidate.same_generation(&source))
            || self
                .current
                .as_ref()
                .is_some_and(|candidate| candidate.same_generation(&source));
        if unchanged {
            return false;
        }
        // Preserve one generation on either side of a tick boundary. The
        // immediate successor is stable; only excess lookahead is latest-only.
        if self.queued.is_none() {
            self.queued = Some(source);
        } else {
            self.lookahead = Some(source);
        }
        true
    }

    fn advance(&mut self) -> bool {
        if self.queued.is_none()
            || (self.current.is_some() && !self.current_sampled && self.expects_sample)
        {
            return false;
        }
        self.current = self.queued.take();
        self.queued = self.lookahead.take();
        self.current_sampled = false;
        true
    }

    fn has_queued(&self) -> bool {
        self.queued.is_some()
    }
}

struct SampledBufferHold {
    texture_id: i64,
    generation: u64,
    buffer_guard: ExternalBufferGuard,
}

type SampledBufferBatchPool = Mutex<Vec<Vec<SampledBufferHold>>>;

pub struct SampledBufferHoldBatch {
    holds: Option<Vec<SampledBufferHold>>,
    pool: Weak<SampledBufferBatchPool>,
}

impl SampledBufferHoldBatch {
    fn len(&self) -> usize {
        self.holds.as_ref().map_or(0, Vec::len)
    }

    fn texture_generations(&self) -> impl Iterator<Item = (i64, u64)> + '_ {
        self.holds
            .iter()
            .flatten()
            .map(|hold| (hold.texture_id, hold.generation))
    }

    pub(super) fn materialize_native_releases(
        &self,
        fence: std::os::fd::BorrowedFd<'_>,
    ) -> Result<(), Box<dyn Error>> {
        for hold in self.holds.iter().flatten() {
            if let ExternalBufferGuard::Native(release) = &hold.buffer_guard {
                release.materialize(fence)?;
            }
        }
        Ok(())
    }

    pub(super) fn complete_native_releases(&self) -> Result<(), Box<dyn Error>> {
        for hold in self.holds.iter().flatten() {
            if let ExternalBufferGuard::Native(release) = &hold.buffer_guard {
                release.complete()?;
            }
        }
        Ok(())
    }

    pub(super) fn complete_native_releases_without_fence(&self) -> Result<(), Box<dyn Error>> {
        for hold in self.holds.iter().flatten() {
            if let ExternalBufferGuard::Native(release) = &hold.buffer_guard {
                release.complete_without_fence()?;
            }
        }
        Ok(())
    }
}

impl std::fmt::Debug for SampledBufferHoldBatch {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SampledBufferHoldBatch")
            .field("len", &self.holds.as_ref().map_or(0, std::vec::Vec::len))
            .finish()
    }
}

impl Drop for SampledBufferHoldBatch {
    fn drop(&mut self) {
        let Some(mut holds) = self.holds.take() else {
            return;
        };
        // RendererBufferGuard destruction may emit wl_buffer.release and, for
        // wp_linux_drm_syncobj_v1 clients, signal the matching release point.
        // Batches are deliberately dropped by the compositor event loop only
        // after the Flutter render fence signals, never by the raster thread.
        holds.clear();
        let Some(pool) = self.pool.upgrade() else {
            return;
        };
        let mut available = lock(&pool);
        if available.len() < MAX_RECYCLED_SAMPLED_BUFFER_BATCHES {
            available.push(holds);
        }
    }
}

#[repr(u8)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum FlutterProducerState {
    Idle,
    Requested,
    Rasterizing,
    Preparing,
}

impl FlutterProducerState {
    const fn as_u8(self) -> u8 {
        self as u8
    }

    fn from_u8(value: u8) -> Self {
        match value {
            value if value == Self::Requested.as_u8() => Self::Requested,
            value if value == Self::Rasterizing.as_u8() => Self::Rasterizing,
            value if value == Self::Preparing.as_u8() => Self::Preparing,
            _ => Self::Idle,
        }
    }
}

/// Serializes display authorization with Flutter's asynchronous UI/raster
/// pipeline. `OnVsync` can legitimately produce no raster task, so a
/// reservation cannot remain `Requested` forever; conversely, releasing it
/// immediately from a render-thread marker races ahead of the UI thread that
/// will enqueue the real raster task.
struct ProducerArbiter {
    state: AtomicU8,
    requested_at: Mutex<Option<Instant>>,
}

impl ProducerArbiter {
    fn new() -> Self {
        Self {
            state: AtomicU8::new(FlutterProducerState::Idle.as_u8()),
            requested_at: Mutex::new(None),
        }
    }

    fn try_request(&self, now: Instant) -> bool {
        if self
            .state
            .compare_exchange(
                FlutterProducerState::Idle.as_u8(),
                FlutterProducerState::Requested.as_u8(),
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_err()
        {
            return false;
        }
        *lock(&self.requested_at) = Some(now);
        true
    }

    fn cancel_request(&self) {
        self.state
            .store(FlutterProducerState::Idle.as_u8(), Ordering::Release);
        lock(&self.requested_at).take();
    }

    fn begin_raster(&self) -> bool {
        // A raster task may begin after a no-raster timeout won its Requested
        // -> Idle race. Claim Idle as well so that late work still excludes a
        // second producer until present()/raster_idle() closes it.
        loop {
            let state = FlutterProducerState::from_u8(self.state.load(Ordering::Acquire));
            if !matches!(
                state,
                FlutterProducerState::Idle | FlutterProducerState::Requested
            ) {
                return false;
            }
            if self
                .state
                .compare_exchange(
                    state.as_u8(),
                    FlutterProducerState::Rasterizing.as_u8(),
                    Ordering::AcqRel,
                    Ordering::Acquire,
                )
                .is_ok()
            {
                lock(&self.requested_at).take();
                return true;
            }
        }
    }

    fn begin_present(&self) {
        self.state
            .store(FlutterProducerState::Preparing.as_u8(), Ordering::Release);
        lock(&self.requested_at).take();
    }

    fn finish(&self) -> FlutterProducerState {
        let previous = FlutterProducerState::from_u8(
            self.state
                .swap(FlutterProducerState::Idle.as_u8(), Ordering::AcqRel),
        );
        lock(&self.requested_at).take();
        previous
    }

    #[cfg(test)]
    fn recover_no_raster(&self, now: Instant, timeout: Duration) -> bool {
        if FlutterProducerState::from_u8(self.state.load(Ordering::Acquire))
            != FlutterProducerState::Requested
        {
            return false;
        }
        let mut requested_at = lock(&self.requested_at);
        let Some(started_at) = *requested_at else {
            return false;
        };
        if now.saturating_duration_since(started_at) < timeout {
            return false;
        }
        if self
            .state
            .compare_exchange(
                FlutterProducerState::Requested.as_u8(),
                FlutterProducerState::Idle.as_u8(),
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_err()
        {
            return false;
        }
        requested_at.take();
        true
    }

    #[cfg(test)]
    fn is_busy(&self) -> bool {
        FlutterProducerState::from_u8(self.state.load(Ordering::Acquire))
            != FlutterProducerState::Idle
    }
}

#[derive(Clone)]
pub(super) struct ExternalTextureFrame {
    pub texture_id: i64,
    source: ExternalTextureSource,
    expects_sample: bool,
}

impl ExternalTextureFrame {
    pub(super) fn from_dmabuf(
        texture_id: i64,
        dmabuf: Dmabuf,
        buffer_guard: RendererBufferGuard,
        revision: u64,
        expects_sample: bool,
    ) -> Self {
        Self {
            texture_id,
            source: ExternalTextureSource::Dmabuf {
                dmabuf,
                buffer_guard: Some(ExternalBufferGuard::Wayland {
                    _guard: buffer_guard,
                }),
                revision,
            },
            expects_sample,
        }
    }

    pub(super) fn from_owned_dmabuf(texture_id: i64, dmabuf: Dmabuf, revision: u64) -> Self {
        Self {
            texture_id,
            source: ExternalTextureSource::Dmabuf {
                dmabuf,
                buffer_guard: None,
                revision,
            },
            expects_sample: false,
        }
    }

    pub(super) fn from_native_dmabuf(
        texture_id: i64,
        dmabuf: Dmabuf,
        release: NativeBufferRelease,
        revision: u64,
        expects_sample: bool,
    ) -> Self {
        Self {
            texture_id,
            source: ExternalTextureSource::Dmabuf {
                dmabuf,
                buffer_guard: Some(ExternalBufferGuard::Native(release)),
                revision,
            },
            expects_sample,
        }
    }

    pub(super) fn from_shm(texture_id: i64, frame: ShmTextureFrame, expects_sample: bool) -> Self {
        Self {
            texture_id,
            source: ExternalTextureSource::Shm(frame),
            expects_sample,
        }
    }
}

pub(super) struct SyncedWaylandScene {
    pub(super) windows: Vec<wire::WindowDescription>,
    pub(super) textures: Vec<ExternalTextureFrame>,
    pub(super) window_snapshot_changed: bool,
}

#[derive(Clone, Copy, Debug)]
struct RuntimeRenderOutput {
    output_id: OutputId,
    render_view_id: RenderViewId,
    configuration_generation: u64,
    target_size: PixelSize,
    transform: OutputTransform,
    logical_x: f64,
    logical_y: f64,
    logical_width: f64,
    logical_height: f64,
}

impl RuntimeRenderOutput {
    fn intersects(self, x: f64, y: f64, width: f64, height: f64) -> bool {
        width > 0.0
            && height > 0.0
            && x < self.logical_x + self.logical_width
            && y < self.logical_y + self.logical_height
            && x + width > self.logical_x
            && y + height > self.logical_y
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum OutputGeometryTransition {
    Immediate,
    AnimatedRotation,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(super) struct OutputRotationAdvance {
    pub(super) advanced: bool,
    pub(super) geometry_published: bool,
}

#[derive(Clone, Copy, Debug)]
struct AnimatedOutputRotation {
    frame_index: usize,
    initial_angle: f64,
    initial_scale_x: f64,
    initial_scale_y: f64,
}

#[derive(Debug)]
struct OutputRotationAnimation {
    started_at: Instant,
    before_resize_targets: Vec<RenderOutput>,
    after_resize_targets: Vec<RenderOutput>,
    frame: Vec<RenderOutput>,
    outputs: Vec<AnimatedOutputRotation>,
    resized: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct OutputRotationSample {
    complete: bool,
    geometry_resize_due: bool,
}

#[derive(Debug)]
struct PendingOutputGeometry {
    snapshot: TopologySnapshot,
    atlas: AtlasPlan,
    ffi_outputs: Vec<RenderOutput>,
    runtime_outputs: Vec<RuntimeRenderOutput>,
}

impl OutputRotationAnimation {
    fn new(
        previous: &[RuntimeRenderOutput],
        previous_targets: &[RenderOutput],
        current: &[RuntimeRenderOutput],
        targets: &[RenderOutput],
        now: Instant,
    ) -> Option<Self> {
        if previous.len() != previous_targets.len() || current.len() != targets.len() {
            return None;
        }
        let mut before_resize_targets = Vec::with_capacity(targets.len());
        let mut outputs = Vec::new();
        for (frame_index, output) in current.iter().enumerate() {
            let previous = previous
                .iter()
                .find(|previous| previous.output_id == output.output_id)?;
            let mut before_target = *previous_targets
                .iter()
                .find(|target| target.render_view_id == previous.render_view_id.get())?;
            let delta = shortest_rotation_delta(previous.transform, output.transform);
            if delta != 0 {
                let (initial_scale_x, initial_scale_y) = if delta.unsigned_abs() & 1 == 1 {
                    (
                        f64::from(output.target_size.width) / f64::from(output.target_size.height),
                        f64::from(output.target_size.height) / f64::from(output.target_size.width),
                    )
                } else {
                    (1.0, 1.0)
                };
                debug_assert_eq!(
                    targets[frame_index].render_view_id,
                    output.render_view_id.get()
                );
                let animation = AnimatedOutputRotation {
                    frame_index,
                    initial_angle: -f64::from(delta) * std::f64::consts::FRAC_PI_2,
                    initial_scale_x,
                    initial_scale_y,
                };
                before_target.source_to_target_transform = rotated_render_transform(
                    before_target.source_to_target_transform,
                    before_target.target_width as f64,
                    before_target.target_height as f64,
                    -animation.initial_angle,
                    animation.initial_scale_x,
                    animation.initial_scale_y,
                );
                outputs.push(animation);
            }
            before_resize_targets.push(before_target);
        }
        if outputs.is_empty() {
            return None;
        }
        let after_resize_targets = targets.to_vec();
        let frame = before_resize_targets.clone();
        Some(Self {
            started_at: now,
            before_resize_targets,
            after_resize_targets,
            frame,
            outputs,
            resized: false,
        })
    }

    fn sample(&mut self, now: Instant) -> (&[RenderOutput], OutputRotationSample) {
        let linear = now.saturating_duration_since(self.started_at).as_secs_f64()
            / OUTPUT_ROTATION_ANIMATION_DURATION.as_secs_f64();
        let complete = linear >= 1.0;
        let eased = ease_in_out_cubic(linear.clamp(0.0, 1.0));
        let geometry_resize_due = !self.resized && eased >= OUTPUT_ROTATION_RESIZE_PROGRESS;
        self.resized |= geometry_resize_due;
        let targets = if self.resized {
            &self.after_resize_targets
        } else {
            &self.before_resize_targets
        };
        self.frame.copy_from_slice(targets);
        for animated in &self.outputs {
            let output = &mut self.frame[animated.frame_index];
            output.source_to_target_transform = animated_rotation_transform(
                output.source_to_target_transform,
                output.target_width as f64,
                output.target_height as f64,
                *animated,
                eased,
            );
        }
        (
            &self.frame,
            OutputRotationSample {
                complete,
                geometry_resize_due,
            },
        )
    }
}

fn transform_turns(transform: OutputTransform) -> i8 {
    match transform {
        OutputTransform::Normal | OutputTransform::Flipped => 0,
        OutputTransform::Rotate90 | OutputTransform::Flipped90 => 1,
        OutputTransform::Rotate180 | OutputTransform::Flipped180 => 2,
        OutputTransform::Rotate270 | OutputTransform::Flipped270 => 3,
    }
}

fn shortest_rotation_delta(previous: OutputTransform, current: OutputTransform) -> i8 {
    match (transform_turns(current) - transform_turns(previous)).rem_euclid(4) {
        0 => 0,
        1 => 1,
        2 => 2,
        3 => -1,
        _ => unreachable!(),
    }
}

fn ease_in_out_cubic(progress: f64) -> f64 {
    if progress < 0.5 {
        4.0 * progress * progress * progress
    } else {
        1.0 - (-2.0 * progress + 2.0).powi(3) / 2.0
    }
}

fn animated_rotation_transform(
    target: RenderOutputTransform,
    target_width: f64,
    target_height: f64,
    animation: AnimatedOutputRotation,
    progress: f64,
) -> RenderOutputTransform {
    let remaining = 1.0 - progress;
    let angle = animation.initial_angle * remaining;
    let scale_x = animation.initial_scale_x.powf(remaining);
    let scale_y = animation.initial_scale_y.powf(remaining);
    rotated_render_transform(target, target_width, target_height, angle, scale_x, scale_y)
}

fn rotated_render_transform(
    target: RenderOutputTransform,
    target_width: f64,
    target_height: f64,
    angle: f64,
    scale_x: f64,
    scale_y: f64,
) -> RenderOutputTransform {
    let (sin, cos) = angle.sin_cos();
    let center_x = target_width * 0.5;
    let center_y = target_height * 0.5;
    let presentation = RenderOutputTransform {
        scale_x: scale_x * cos,
        skew_x: -scale_x * sin,
        translate_x: center_x - scale_x * cos * center_x + scale_x * sin * center_y,
        skew_y: scale_y * sin,
        scale_y: scale_y * cos,
        translate_y: center_y - scale_y * sin * center_x - scale_y * cos * center_y,
    };
    compose_render_transforms(presentation, target)
}

/// Returns `after(before(point))` in Flutter's affine field layout.
fn compose_render_transforms(
    after: RenderOutputTransform,
    before: RenderOutputTransform,
) -> RenderOutputTransform {
    RenderOutputTransform {
        scale_x: after.scale_x * before.scale_x + after.skew_x * before.skew_y,
        skew_x: after.scale_x * before.skew_x + after.skew_x * before.scale_y,
        translate_x: after.scale_x * before.translate_x
            + after.skew_x * before.translate_y
            + after.translate_x,
        skew_y: after.skew_y * before.scale_x + after.scale_y * before.skew_y,
        scale_y: after.skew_y * before.skew_x + after.scale_y * before.scale_y,
        translate_y: after.skew_y * before.translate_x
            + after.scale_y * before.translate_y
            + after.translate_y,
    }
}

unsafe extern "C" fn retire_external_texture(user_data: *mut c_void) {
    if user_data.is_null() {
        return;
    }
    let retired = contain_ffi_unwind(|| {
        // SAFETY: every non-null pointer installed in FlutterOpenGLTexture was
        // produced by Box::into_raw exactly once for this callback. Reclaiming
        // it inside the guard also contains panics from field destructors.
        ExternalTextureLease::retire(unsafe {
            Box::from_raw(user_data.cast::<ExternalTextureLease>())
        });
    });
    if !retired {
        // Logging is also Rust code invoked from the C trampoline, so keep it
        // inside the same no-unwind discipline.
        let _ = contain_ffi_unwind(|| {
            error!("panic while retiring a Flutter external texture lease");
        });
    }
}

fn contain_ffi_unwind(callback: impl FnOnce()) -> bool {
    match catch_unwind(AssertUnwindSafe(callback)) {
        Ok(()) => true,
        Err(payload) => {
            // A `panic_any` payload owns arbitrary user code in Drop. Dropping
            // it after catch_unwind could start a second unwind across C.
            mem::forget(payload);
            false
        }
    }
}

#[derive(Clone, Copy, Debug)]
struct PendingOutputPresentation {
    view_id: i64,
    framebuffer: u32,
}

struct FlutterGlHandler {
    render_context: Mutex<ContextBinding>,
    resource_context: Mutex<ContextBinding>,
    display: Arc<EGLDisplayHandle>,
    gl: GlApi,
    targets: Mutex<Vec<GlTarget>>,
    shader_blit: Mutex<Option<ShaderBlit>>,
    depth_stencils: Mutex<Vec<u32>>,
    broker: Mutex<OutputBufferBroker>,
    pending_output_presentation: Mutex<Option<PendingOutputPresentation>>,
    external_texture_sources: Mutex<HashMap<i64, ExternalTextureSlot>>,
    raster_sampled_buffers: Mutex<Vec<SampledBufferHold>>,
    sampled_buffer_release_fence: Mutex<Option<OwnedFd>>,
    sampled_buffer_batch_pool: Arc<SampledBufferBatchPool>,
    dmabuf_texture_cache: Mutex<PartitionedRecencyCache<i64, Dmabuf, Arc<CachedTextureBinding>>>,
    retained_native_texture_cache:
        Mutex<PartitionedRecencyCache<i64, u64, Arc<CachedTextureBinding>>>,
    shm_texture_cache: Mutex<RecencyCache<(i64, u64), Arc<CachedTextureBinding>>>,
    retired_external_bindings: Arc<RetiredExternalBindingQueue>,
    retired_external_binding_scratch: Mutex<Vec<ExternalTextureBinding>>,
    external_texture_lease_pool: Arc<ExternalTextureLeasePool>,
    prepared_external_texture: Mutex<Option<PreparedExternalTexture>>,
    external_texture_resource_budget: Arc<ExternalTextureResourceBudget>,
    pending_vsync_batons: Mutex<PendingVsyncBatons>,
    platform_task_budget: Arc<PlatformTaskBudget>,
    platform_tasks: CoalescedInbox<PendingPlatformTask>,
    ready_frames: Mutex<VecDeque<ReadyOutputFrame>>,
    frame_ready_wakeup: CoalescedWakeup,
    queue_overflow_wakeup: CoalescedWakeup,
    render_audit: Option<Mutex<RenderDamageAudit>>,
    events: Sender<RuntimeEvent>,
    generation: u64,
    desktop_size: PixelSize,
    producer: ProducerArbiter,
}

impl FlutterGlHandler {
    #[allow(clippy::too_many_arguments)]
    fn new<'a>(
        render_context: egl_context::SharedEglContext,
        resource_context: egl_context::SharedEglContext,
        output_pools: impl IntoIterator<Item = OutputRenderTargetPool<'a>>,
        desktop_size: PixelSize,
        renderer_backend: RendererBackend,
        offscreen_blit: bool,
        events: Sender<RuntimeEvent>,
        generation: u64,
    ) -> Result<Arc<Self>, Box<dyn Error>> {
        let display = render_context.display().get_display_handle();
        // SAFETY: this context was just created and has never been current on
        // another thread. It is unbound before ownership reaches Flutter.
        unsafe { render_context.make_current()? };
        let gl = GlApi::load()?;
        let needs_depth_stencil = renderer_backend == RendererBackend::ImpellerGles;
        let mut depth_stencils = Vec::new();
        info!(
            %renderer_backend,
            offscreen_blit,
            "creating Flutter physical-output texture targets"
        );
        let mut targets = Vec::new();
        let mut broker_descriptors = Vec::new();

        for pool in output_pools {
            let width =
                i32::try_from(pool.size.width).map_err(|_| "Flutter output width exceeds GLES")?;
            let height = i32::try_from(pool.size.height)
                .map_err(|_| "Flutter output height exceeds GLES")?;
            let mut depth_stencil = 0;
            if needs_depth_stencil {
                // Impeller wraps Denial's supplied FBO. One packed attachment can
                // be shared by one output's rotating FBOs because the raster
                // runner is serial and clears it for each render pass.
                // SAFETY: this new GLES context is current and the arguments and
                // output pointer are valid.
                unsafe {
                    let _ = (gl.get_error)();
                    (gl.gen_renderbuffers)(1, &mut depth_stencil);
                    (gl.bind_renderbuffer)(gl::RENDERBUFFER, depth_stencil);
                    (gl.renderbuffer_storage)(
                        gl::RENDERBUFFER,
                        gl::DEPTH24_STENCIL8,
                        width,
                        height,
                    );
                }
                // SAFETY: the same GLES context remains current.
                let allocation_error = unsafe { (gl.get_error)() };
                depth_stencils.push(depth_stencil);
                if depth_stencil == 0 || allocation_error != gl::NO_ERROR {
                    warn!(
                        renderbuffer = depth_stencil,
                        error = format_args!("{allocation_error:#x}"),
                        "Impeller GLES depth/stencil allocation failed"
                    );
                    destroy_depth_stencils(gl, &mut depth_stencils);
                    destroy_targets(gl, &display, &mut targets);
                    render_context.unbind()?;
                    return Err("could not allocate Impeller GLES depth/stencil storage".into());
                }
            }

            let target_start = targets.len();
            for (buffer_index, (scanout_dmabuf, render_dmabuf)) in
                pool.dmabufs.into_iter().enumerate()
            {
                let image = match render_context
                    .display()
                    .create_image_from_dmabuf(scanout_dmabuf)
                {
                    Ok(image) => image,
                    Err(error) => {
                        destroy_targets(gl, &display, &mut targets);
                        destroy_depth_stencils(gl, &mut depth_stencils);
                        render_context.unbind()?;
                        return Err(error.into());
                    }
                };
                let mut target = GlTarget {
                    output_id: pool.output_id,
                    render_view_id: pool.render_view_id,
                    configuration_generation: pool.configuration_generation,
                    size: pool.size,
                    buffer_index,
                    scanout_image: image as usize,
                    render_image: 0,
                    scanout_texture: 0,
                    scanout_framebuffer: 0,
                    render_texture: 0,
                    render_framebuffer: 0,
                };
                // SAFETY: a compatible GLES context is current and all output
                // pointers reference live local integers.
                unsafe {
                    (gl.gen_textures)(1, &mut target.scanout_texture);
                    (gl.bind_texture)(gl::TEXTURE_2D, target.scanout_texture);
                    (gl.tex_parameter_i)(
                        gl::TEXTURE_2D,
                        gl::TEXTURE_MIN_FILTER,
                        gl::NEAREST as i32,
                    );
                    (gl.tex_parameter_i)(
                        gl::TEXTURE_2D,
                        gl::TEXTURE_MAG_FILTER,
                        gl::NEAREST as i32,
                    );
                    (gl.tex_parameter_i)(
                        gl::TEXTURE_2D,
                        gl::TEXTURE_WRAP_S,
                        gl::CLAMP_TO_EDGE as i32,
                    );
                    (gl.tex_parameter_i)(
                        gl::TEXTURE_2D,
                        gl::TEXTURE_WRAP_T,
                        gl::CLAMP_TO_EDGE as i32,
                    );
                    (gl.image_target_texture)(gl::TEXTURE_2D, image.cast());
                    (gl.gen_framebuffers)(1, &mut target.scanout_framebuffer);
                    (gl.bind_framebuffer)(gl::FRAMEBUFFER, target.scanout_framebuffer);
                    (gl.framebuffer_texture_2d)(
                        gl::FRAMEBUFFER,
                        gl::COLOR_ATTACHMENT0,
                        gl::TEXTURE_2D,
                        target.scanout_texture,
                        0,
                    );
                    if !offscreen_blit && depth_stencil != 0 {
                        (gl.framebuffer_renderbuffer)(
                            gl::FRAMEBUFFER,
                            gl::DEPTH_STENCIL_ATTACHMENT,
                            gl::RENDERBUFFER,
                            depth_stencil,
                        );
                    }
                }
                // Direct mode exposes this imported texture to Flutter. Offscreen
                // mode keeps it only as the destination of the final native-size
                // copy, so effects and partial repaint never need to read it.
                let mut actual_samples = 0;
                let mut actual_stencil_bits = 0;
                // SAFETY: the same compatible GLES context remains current, the
                // newly created framebuffer is still bound, and the output
                // pointer references a live local integer.
                let framebuffer_status = unsafe {
                    let status = (gl.check_framebuffer_status)(gl::FRAMEBUFFER);
                    (gl.get_integer_v)(gl::SAMPLES, &mut actual_samples);
                    if needs_depth_stencil {
                        (gl.get_integer_v)(gl::STENCIL_BITS, &mut actual_stencil_bits);
                    }
                    status
                };
                if target.scanout_texture == 0
                    || target.scanout_framebuffer == 0
                    || framebuffer_status != gl::FRAMEBUFFER_COMPLETE
                    || (!offscreen_blit && actual_samples > 1)
                    || (!offscreen_blit && needs_depth_stencil && actual_stencil_bits < 8)
                {
                    warn!(
                        texture = target.scanout_texture,
                        framebuffer = target.scanout_framebuffer,
                        status = framebuffer_status,
                        actual_samples,
                        actual_stencil_bits,
                        "Flutter output scanout FBO creation failed"
                    );
                    let mut failed = vec![target];
                    destroy_targets(gl, &display, &mut failed);
                    destroy_targets(gl, &display, &mut targets);
                    destroy_depth_stencils(gl, &mut depth_stencils);
                    render_context.unbind()?;
                    return Err("a Flutter output scanout framebuffer is incomplete".into());
                }

                if offscreen_blit {
                    let Some(render_dmabuf) = render_dmabuf else {
                        let mut failed = vec![target];
                        destroy_targets(gl, &display, &mut failed);
                        destroy_targets(gl, &display, &mut targets);
                        destroy_depth_stencils(gl, &mut depth_stencils);
                        render_context.unbind()?;
                        return Err(
                            "offscreen blit target is missing its linear render DMA-BUF".into()
                        );
                    };
                    let render_format = AllocatorBuffer::format(render_dmabuf);
                    if render_format.code != Fourcc::Xrgb8888
                        || render_format.modifier != Modifier::Linear
                    {
                        let mut failed = vec![target];
                        destroy_targets(gl, &display, &mut failed);
                        destroy_targets(gl, &display, &mut targets);
                        destroy_depth_stencils(gl, &mut depth_stencils);
                        render_context.unbind()?;
                        return Err(format!(
                            "offscreen Flutter render target is not linear XR24: {render_format:?}"
                        )
                        .into());
                    }
                    let render_image = match render_context
                        .display()
                        .create_image_from_dmabuf(render_dmabuf)
                    {
                        Ok(image) => image,
                        Err(error) => {
                            let mut failed = vec![target];
                            destroy_targets(gl, &display, &mut failed);
                            destroy_targets(gl, &display, &mut targets);
                            destroy_depth_stencils(gl, &mut depth_stencils);
                            render_context.unbind()?;
                            return Err(error.into());
                        }
                    };
                    target.render_image = render_image as usize;
                    // Flutter's root target is an explicitly LINEAR GBM DMA-BUF.
                    // Backdrop reads therefore cannot inherit UBWC compression
                    // from either Mesa's ordinary texture allocator or scanout.
                    // SAFETY: the compatible GLES context remains current and all
                    // names and attachment dimensions belong to this handler.
                    unsafe {
                        let _ = (gl.get_error)();
                        (gl.gen_textures)(1, &mut target.render_texture);
                        (gl.bind_texture)(gl::TEXTURE_2D, target.render_texture);
                        (gl.tex_parameter_i)(
                            gl::TEXTURE_2D,
                            gl::TEXTURE_MIN_FILTER,
                            gl::NEAREST as i32,
                        );
                        (gl.tex_parameter_i)(
                            gl::TEXTURE_2D,
                            gl::TEXTURE_MAG_FILTER,
                            gl::NEAREST as i32,
                        );
                        (gl.tex_parameter_i)(
                            gl::TEXTURE_2D,
                            gl::TEXTURE_WRAP_S,
                            gl::CLAMP_TO_EDGE as i32,
                        );
                        (gl.tex_parameter_i)(
                            gl::TEXTURE_2D,
                            gl::TEXTURE_WRAP_T,
                            gl::CLAMP_TO_EDGE as i32,
                        );
                        (gl.image_target_texture)(gl::TEXTURE_2D, render_image.cast());
                        (gl.gen_framebuffers)(1, &mut target.render_framebuffer);
                        (gl.bind_framebuffer)(gl::FRAMEBUFFER, target.render_framebuffer);
                        (gl.framebuffer_texture_2d)(
                            gl::FRAMEBUFFER,
                            gl::COLOR_ATTACHMENT0,
                            gl::TEXTURE_2D,
                            target.render_texture,
                            0,
                        );
                        if depth_stencil != 0 {
                            (gl.framebuffer_renderbuffer)(
                                gl::FRAMEBUFFER,
                                gl::DEPTH_STENCIL_ATTACHMENT,
                                gl::RENDERBUFFER,
                                depth_stencil,
                            );
                        }
                    }
                    actual_samples = 0;
                    actual_stencil_bits = 0;
                    // SAFETY: the newly created render framebuffer is still bound
                    // in the current compatible GLES context.
                    let render_status = unsafe {
                        let status = (gl.check_framebuffer_status)(gl::FRAMEBUFFER);
                        (gl.get_integer_v)(gl::SAMPLES, &mut actual_samples);
                        if needs_depth_stencil {
                            (gl.get_integer_v)(gl::STENCIL_BITS, &mut actual_stencil_bits);
                        }
                        status
                    };
                    // SAFETY: querying the current context's error queue has no
                    // additional pointer or object-lifetime requirements.
                    let render_error = unsafe { (gl.get_error)() };
                    if target.render_texture == 0
                        || target.render_framebuffer == 0
                        || render_status != gl::FRAMEBUFFER_COMPLETE
                        || render_error != gl::NO_ERROR
                        || actual_samples > 1
                        || (needs_depth_stencil && actual_stencil_bits < 8)
                    {
                        warn!(
                            texture = target.render_texture,
                            framebuffer = target.render_framebuffer,
                            status = render_status,
                            error = format_args!("{render_error:#x}"),
                            actual_samples,
                            actual_stencil_bits,
                            "Flutter offscreen output FBO creation failed"
                        );
                        let mut failed = vec![target];
                        destroy_targets(gl, &display, &mut failed);
                        destroy_targets(gl, &display, &mut targets);
                        destroy_depth_stencils(gl, &mut depth_stencils);
                        render_context.unbind()?;
                        return Err("a Flutter offscreen output framebuffer is incomplete".into());
                    }
                } else {
                    target.render_framebuffer = target.scanout_framebuffer;
                }
                targets.push(target);
            }
            let framebuffers = targets[target_start..]
                .iter()
                .map(|target| target.render_framebuffer)
                .collect::<Vec<_>>();
            broker_descriptors.push((
                pool.output_id,
                pool.render_view_id,
                pool.configuration_generation,
                pool.size,
                pool.initial_scanout,
                framebuffers,
            ));
        }
        let mut shader_blit = match create_shader_blit(gl) {
            Ok(pipeline) => Some(pipeline),
            Err(error) => {
                destroy_targets(gl, &display, &mut targets);
                destroy_depth_stencils(gl, &mut depth_stencils);
                render_context.unbind()?;
                return Err(error);
            }
        };
        // SAFETY: zero is the default GLES object and the context is current.
        unsafe {
            (gl.use_program)(0);
            (gl.bind_framebuffer)(gl::FRAMEBUFFER, 0);
            (gl.bind_texture)(gl::TEXTURE_2D, 0);
            (gl.bind_renderbuffer)(gl::RENDERBUFFER, 0);
        }
        render_context.unbind()?;

        if targets.len() < 3 {
            // SAFETY: Flutter does not own this context yet.
            unsafe { render_context.make_current()? };
            destroy_shader_blit(gl, &mut shader_blit);
            destroy_targets(gl, &display, &mut targets);
            destroy_depth_stencils(gl, &mut depth_stencils);
            render_context.unbind()?;
            return Err("Flutter presentation needs physical output buffer pools".into());
        }
        let broker = match OutputBufferBroker::new(broker_descriptors.iter().map(
            |(output_id, render_view_id, configuration_generation, size, initial, framebuffers)| {
                OutputPoolDescriptor {
                    output_id: *output_id,
                    render_view_id: *render_view_id,
                    configuration_generation: *configuration_generation,
                    size: *size,
                    initial_scanout: *initial,
                    framebuffers,
                }
            },
        )) {
            Ok(broker) => broker,
            Err(error) => {
                // Keep the constructor's new validation path leak-free: GL
                // targets do not own automatic destructors.
                // SAFETY: target construction has finished, the render
                // context is unbound, and Flutter does not own it yet.
                unsafe { render_context.make_current()? };
                destroy_shader_blit(gl, &mut shader_blit);
                destroy_targets(gl, &display, &mut targets);
                destroy_depth_stencils(gl, &mut depth_stencils);
                render_context.unbind()?;
                return Err(error.into());
            }
        };
        info!(
            outputs = broker.pools.len(),
            buffers = targets.len(),
            offscreen_blit,
            render_modifier = ?offscreen_blit.then_some(Modifier::Linear),
            "imported native output pools into Flutter EGL context"
        );
        let render_audit = render_audit_enabled().then(|| {
            info!(
                target: "deniald::render_audit",
                width = desktop_size.width,
                height = desktop_size.height,
                "Flutter physical-output render audit enabled"
            );
            Mutex::new(RenderDamageAudit::new())
        });

        Ok(Arc::new(Self {
            render_context: Mutex::new(ContextBinding::new(render_context)),
            resource_context: Mutex::new(ContextBinding::new(resource_context)),
            display,
            gl,
            targets: Mutex::new(targets),
            shader_blit: Mutex::new(shader_blit),
            depth_stencils: Mutex::new(depth_stencils),
            broker: Mutex::new(broker),
            pending_output_presentation: Mutex::new(None),
            external_texture_sources: Mutex::new(HashMap::new()),
            raster_sampled_buffers: Mutex::new(Vec::new()),
            sampled_buffer_release_fence: Mutex::new(None),
            sampled_buffer_batch_pool: Arc::new(Mutex::new(Vec::with_capacity(
                MAX_RECYCLED_SAMPLED_BUFFER_BATCHES,
            ))),
            dmabuf_texture_cache: Mutex::new(PartitionedRecencyCache::new(
                MAX_CACHED_DMABUF_BINDINGS_PER_TEXTURE,
            )),
            retained_native_texture_cache: Mutex::new(PartitionedRecencyCache::new(
                MAX_CACHED_DMABUF_BINDINGS_PER_TEXTURE,
            )),
            shm_texture_cache: Mutex::new(RecencyCache::new(MAX_CACHED_SHM_BINDINGS)),
            retired_external_bindings: Arc::new(RetiredExternalBindingQueue::new()),
            retired_external_binding_scratch: Mutex::new(Vec::new()),
            external_texture_lease_pool: Arc::new(Mutex::new(Vec::with_capacity(
                MAX_CACHED_EXTERNAL_TEXTURE_LEASES,
            ))),
            prepared_external_texture: Mutex::new(None),
            external_texture_resource_budget: Arc::new(ExternalTextureResourceBudget::default()),
            pending_vsync_batons: Mutex::new(PendingVsyncBatons::default()),
            platform_task_budget: Arc::new(PlatformTaskBudget::default()),
            platform_tasks: CoalescedInbox::with_capacity(INITIAL_PLATFORM_TASK_BATCH_CAPACITY),
            ready_frames: Mutex::new(VecDeque::with_capacity(8)),
            frame_ready_wakeup: CoalescedWakeup::default(),
            queue_overflow_wakeup: CoalescedWakeup::default(),
            render_audit,
            events,
            generation,
            desktop_size,
            producer: ProducerArbiter::new(),
        }))
    }

    fn take_ready_frame(
        &self,
        mut output_available: impl FnMut(OutputId) -> bool,
    ) -> Option<ReadyOutputFrame> {
        let mut frames = lock(&self.ready_frames);
        let index = frames
            .iter()
            .position(|frame| output_available(frame.output_id))?;
        frames.remove(index)
    }

    fn has_ready_frames(&self) -> bool {
        !lock(&self.ready_frames).is_empty()
    }

    fn publish_output(&self, output: &ReadyOutputFrame) -> Result<(), &'static str> {
        lock(&self.broker).publish(output)
    }

    fn authorize_outputs(&self, requests: &[OutputFrameRequest], views: &mut Vec<i64>) {
        views.clear();
        let mut broker = lock(&self.broker);
        let now = Instant::now();
        for request in requests {
            if let Some(view) = broker.authorize(*request, now) {
                views.push(view);
            }
        }
    }

    fn output_target_available(&self, output: OutputId) -> bool {
        lock(&self.broker).target_available(output)
    }

    fn cancel_output_authorizations(&self, render_view_ids: &[i64]) {
        lock(&self.broker).cancel_authorizations(render_view_ids);
    }

    fn expire_output_authorizations(&self, now: Instant) -> usize {
        lock(&self.broker).expire_authorizations(now)
    }

    fn release_output(&self, output: OutputId, index: usize) -> Result<(), &'static str> {
        lock(&self.broker).release_output(output, index)
    }

    fn tag_next_frame_for_screenshot(
        &self,
        output: OutputId,
        request_id: u64,
    ) -> Result<(), &'static str> {
        lock(&self.broker).tag_next_frame_for_screenshot(output, request_id)
    }

    fn cancel_screenshot_frame(&self, request_id: u64) {
        lock(&self.broker).cancel_screenshot_frame(request_id);
    }

    fn set_external_texture_sources(
        &self,
        frames: impl IntoIterator<Item = ExternalTextureFrame>,
        changed: &mut Vec<i64>,
    ) {
        let mut sources = lock(&self.external_texture_sources);
        for ExternalTextureFrame {
            texture_id,
            source,
            expects_sample,
        } in frames
        {
            if sources
                .entry(texture_id)
                .or_default()
                .queue(source, expects_sample)
            {
                changed.push(texture_id);
            }
        }
    }

    fn advance_external_texture_sources(&self, texture_ids: &[i64], deferred: &mut Vec<i64>) {
        let mut sources = lock(&self.external_texture_sources);
        for texture_id in texture_ids {
            if let Some(slot) = sources.get_mut(texture_id) {
                slot.advance();
                if slot.has_queued() {
                    deferred.push(*texture_id);
                }
            }
        }
    }

    fn advance_all_external_texture_sources(&self, changed: &mut Vec<i64>) {
        let mut sources = lock(&self.external_texture_sources);
        for (texture_id, slot) in sources.iter_mut() {
            if slot.advance() {
                changed.push(*texture_id);
            }
        }
    }

    fn current_external_texture(&self, texture_id: i64) -> Option<ExternalTextureSource> {
        lock(&self.external_texture_sources)
            .get(&texture_id)?
            .current
            .clone()
    }

    fn mark_external_texture_sampled(&self, texture_id: i64, generation: u64) {
        let mut sources = lock(&self.external_texture_sources);
        let Some(slot) = sources.get_mut(&texture_id) else {
            return;
        };
        if slot
            .current
            .as_ref()
            .is_some_and(|source| source.generation() == generation)
        {
            slot.current_sampled = true;
        }
    }

    fn record_sampled_buffer(
        &self,
        texture_id: i64,
        generation: u64,
        buffer_guard: ExternalBufferGuard,
    ) {
        let mut sampled = lock(&self.raster_sampled_buffers);
        if sampled
            .iter()
            .any(|hold| hold.texture_id == texture_id && hold.generation == generation)
        {
            return;
        }
        sampled.push(SampledBufferHold {
            texture_id,
            generation,
            buffer_guard,
        });
    }

    fn seal_sampled_buffers(&self) -> Option<SampledBufferHoldBatch> {
        let mut sampled = lock(&self.raster_sampled_buffers);
        if sampled.is_empty() {
            return None;
        }
        let mut replacement = lock(&self.sampled_buffer_batch_pool)
            .pop()
            .unwrap_or_default();
        debug_assert!(replacement.is_empty());
        mem::swap(&mut *sampled, &mut replacement);
        Some(SampledBufferHoldBatch {
            holds: Some(replacement),
            pool: Arc::downgrade(&self.sampled_buffer_batch_pool),
        })
    }

    fn rearm_abandoned_samples(&self) {
        let sampled = lock(&self.raster_sampled_buffers);
        if sampled.is_empty() {
            return;
        }
        let mut sources = lock(&self.external_texture_sources);
        for hold in sampled.iter() {
            let Some(slot) = sources.get_mut(&hold.texture_id) else {
                continue;
            };
            if slot
                .current
                .as_ref()
                .is_some_and(|source| source.generation() == hold.generation)
            {
                slot.current_sampled = false;
            }
        }
    }

    fn publish_sampled_buffer_release(
        &self,
        fence: Option<OwnedFd>,
        batch: Option<SampledBufferHoldBatch>,
    ) -> bool {
        let Some(batch) = batch else {
            return true;
        };
        match self
            .events
            .send(RuntimeEvent::SampledBuffersReady { fence, batch })
        {
            Ok(()) => true,
            Err(error) => {
                // The event-loop owner disappeared before it could watch the
                // sync_file. Complete the command stream before retaining the
                // orphaned event through process teardown.
                // SAFETY: this helper is called only by render-thread
                // callbacks while Flutter's GLES context is current.
                unsafe { (self.gl.finish)() };
                // The compositor receiver no longer exists, so there is no
                // sound Wayland thread on which to release these guards.
                // Preserve them through process teardown instead of running
                // wl_buffer.release from Flutter's raster thread.
                mem::forget(error);
                false
            }
        }
    }

    fn remove_external_texture_source(&self, texture_id: i64) {
        lock(&self.external_texture_sources).remove(&texture_id);
        let retired_dmabufs = lock(&self.dmabuf_texture_cache).remove(&texture_id);
        let retired_native = lock(&self.retained_native_texture_cache).remove(&texture_id);
        let retired_shm =
            lock(&self.shm_texture_cache).remove_where(|(owner, _)| *owner == texture_id);
        // Dropping a cache reference never issues GL calls. If no Flutter
        // lease still references the binding, its Drop queues destruction for
        // the next callback with the raster context current.
        drop((retired_dmabufs, retired_native, retired_shm));
    }

    fn cached_dmabuf_binding(
        &self,
        texture_id: i64,
        dmabuf: &Dmabuf,
    ) -> Option<Arc<CachedTextureBinding>> {
        lock(&self.dmabuf_texture_cache).get_by(&texture_id, |cached| cached == dmabuf)
    }

    fn cache_dmabuf_binding(
        &self,
        texture_id: i64,
        dmabuf: Dmabuf,
        binding: Arc<CachedTextureBinding>,
    ) {
        let retired = lock(&self.dmabuf_texture_cache).insert(texture_id, dmabuf, binding);
        drop(retired);
    }

    fn cached_retained_native_binding(
        &self,
        texture_id: i64,
        revision: u64,
    ) -> Option<Arc<CachedTextureBinding>> {
        lock(&self.retained_native_texture_cache)
            .get_by(&texture_id, |cached_revision| *cached_revision == revision)
    }

    fn cache_retained_native_binding(
        &self,
        texture_id: i64,
        revision: u64,
        binding: Arc<CachedTextureBinding>,
    ) {
        let retired =
            lock(&self.retained_native_texture_cache).insert(texture_id, revision, binding);
        drop(retired);
    }

    fn cached_shm_binding(
        &self,
        texture_id: i64,
        revision: u64,
    ) -> Option<Arc<CachedTextureBinding>> {
        lock(&self.shm_texture_cache)
            .get_by(|(owner, cached_revision)| *owner == texture_id && *cached_revision == revision)
    }

    fn cache_shm_binding(
        &self,
        texture_id: i64,
        revision: u64,
        binding: Arc<CachedTextureBinding>,
    ) {
        let retired = lock(&self.shm_texture_cache).insert((texture_id, revision), binding);
        drop(retired);
    }

    fn lease_external_texture(
        &self,
        resource: ExternalTextureLeaseResource,
    ) -> Box<ExternalTextureLease> {
        let mut lease = lock(&self.external_texture_lease_pool)
            .pop()
            .unwrap_or_else(|| {
                Box::new(ExternalTextureLease {
                    resource: None,
                    pool: Arc::downgrade(&self.external_texture_lease_pool),
                })
            });
        debug_assert!(lease.resource.is_none());
        lease.resource = Some(resource);
        lease
    }

    fn complete_vsync(&self, baton: isize) {
        lock(&self.pending_vsync_batons).complete(baton);
    }

    fn take_pending_vsync_batons(&self) -> VecDeque<isize> {
        lock(&self.pending_vsync_batons).take_all()
    }

    fn take_next_vsync(&self) -> (Option<isize>, bool) {
        let mut pending = lock(&self.pending_vsync_batons);
        let baton = pending.take_next();
        (baton, pending.has_pending())
    }

    fn restore_vsync(&self, baton: isize) {
        lock(&self.pending_vsync_batons).restore_front(baton);
    }

    fn has_pending_vsync(&self) -> bool {
        lock(&self.pending_vsync_batons).has_pending()
    }

    fn try_request_frame(&self) -> bool {
        self.producer.try_request(Instant::now())
    }

    fn cancel_requested_frame(&self) {
        self.producer.cancel_request();
    }

    fn begin_raster_frame(&self) -> bool {
        self.producer.begin_raster()
    }

    fn begin_present(&self) {
        self.producer.begin_present();
    }

    fn finish_producer_frame(&self) -> FlutterProducerState {
        self.producer.finish()
    }

    fn acknowledge_frame_ready(&self) {
        self.frame_ready_wakeup.acknowledge();
    }

    fn publish_ready_frames(&self, frames: Vec<ReadyOutputFrame>) -> bool {
        if frames.is_empty() {
            return true;
        }
        lock(&self.ready_frames).extend(frames);
        if !self.frame_ready_wakeup.begin() {
            return true;
        }
        let sent = self
            .events
            .send(RuntimeEvent::FrameReady {
                generation: self.generation,
            })
            .is_ok();
        if !sent {
            self.frame_ready_wakeup.acknowledge();
        }
        sent
    }

    fn take_platform_tasks(&self, output: &mut Vec<PendingPlatformTask>) {
        self.platform_tasks.take_into(output);
    }

    fn report_queue_overflow(&self, queue: &'static str) {
        if !self.queue_overflow_wakeup.begin() {
            return;
        }
        if self
            .events
            .send(RuntimeEvent::QueueOverflow {
                generation: self.generation,
                queue,
            })
            .is_err()
        {
            self.queue_overflow_wakeup.acknowledge();
        }
    }

    fn blit_to_scanout(&self, render_framebuffer: u32) -> bool {
        let target = lock(&self.targets)
            .iter()
            .find(|target| target.render_framebuffer == render_framebuffer)
            .copied();
        let Some(target) = target else {
            error!(
                framebuffer = render_framebuffer,
                "Flutter presented an unknown physical-output target"
            );
            return false;
        };
        if !target.needs_blit() {
            return true;
        }

        let Some(shader_blit) = *lock(&self.shader_blit) else {
            error!("offscreen Flutter target has no shader-copy pipeline");
            return false;
        };

        // The raster commands and this draw share one GLES context, so command
        // ordering makes the completed LINEAR scene texture available without
        // a CPU wait. Use ordinary texture sampling into the compressed KMS
        // target instead of glBlitFramebuffer: the latter enters a faulty CP
        // copy path on this Adreno and eventually faults while reading IOVA 0.
        let width = target.size.width as i32;
        let height = target.size.height as i32;
        let mut previous_draw_framebuffer = 0;
        let mut previous_program = 0;
        let mut previous_active_texture = 0;
        let mut previous_texture_2d = 0;
        let mut previous_viewport = [0; 4];
        let mut previous_color_mask = [gl::FALSE; 4];
        let mut previous_capabilities = [false; 5];
        // SAFETY: Flutter invokes present with this handler's render context
        // current, and every GL object below remains live in this handler.
        unsafe {
            for _ in 0..8 {
                if (self.gl.get_error)() == gl::NO_ERROR {
                    break;
                }
            }
            (self.gl.get_integer_v)(gl::DRAW_FRAMEBUFFER_BINDING, &mut previous_draw_framebuffer);
            (self.gl.get_integer_v)(gl::CURRENT_PROGRAM, &mut previous_program);
            (self.gl.get_integer_v)(gl::ACTIVE_TEXTURE, &mut previous_active_texture);
            (self.gl.get_integer_v)(gl::VIEWPORT, previous_viewport.as_mut_ptr());
            (self.gl.get_boolean_v)(gl::COLOR_WRITEMASK, previous_color_mask.as_mut_ptr());
            for (saved, capability) in previous_capabilities.iter_mut().zip([
                gl::BLEND,
                gl::CULL_FACE,
                gl::DEPTH_TEST,
                gl::SCISSOR_TEST,
                gl::STENCIL_TEST,
            ]) {
                *saved = (self.gl.is_enabled)(capability) == gl::TRUE;
            }
            (self.gl.active_texture)(gl::TEXTURE0);
            (self.gl.get_integer_v)(gl::TEXTURE_BINDING_2D, &mut previous_texture_2d);

            (self.gl.bind_framebuffer)(gl::DRAW_FRAMEBUFFER, target.scanout_framebuffer);
            (self.gl.viewport)(0, 0, width, height);
            (self.gl.disable)(gl::BLEND);
            (self.gl.disable)(gl::CULL_FACE);
            (self.gl.disable)(gl::DEPTH_TEST);
            (self.gl.disable)(gl::SCISSOR_TEST);
            (self.gl.disable)(gl::STENCIL_TEST);
            (self.gl.color_mask)(gl::TRUE, gl::TRUE, gl::TRUE, gl::TRUE);
            (self.gl.use_program)(shader_blit.program);
            (self.gl.active_texture)(gl::TEXTURE0);
            (self.gl.bind_texture)(gl::TEXTURE_2D, target.render_texture);
            (self.gl.uniform_1i)(shader_blit.source_uniform, 0);
            (self.gl.draw_arrays)(gl::TRIANGLES, 0, 3);
        }
        // SAFETY: the same render context remains current after the blit.
        let draw_error = unsafe { (self.gl.get_error)() };
        // Skia caches GLES state across frames. Restore every binding and
        // fixed-function value touched by the copy so the following Flutter
        // frame cannot inherit a stale program, texture, mask, or capability.
        // SAFETY: all values were queried from this same current context.
        unsafe {
            (self.gl.use_program)(previous_program as u32);
            (self.gl.bind_texture)(gl::TEXTURE_2D, previous_texture_2d as u32);
            (self.gl.active_texture)(previous_active_texture as u32);
            (self.gl.bind_framebuffer)(gl::DRAW_FRAMEBUFFER, previous_draw_framebuffer as u32);
            (self.gl.viewport)(
                previous_viewport[0],
                previous_viewport[1],
                previous_viewport[2],
                previous_viewport[3],
            );
            (self.gl.color_mask)(
                previous_color_mask[0],
                previous_color_mask[1],
                previous_color_mask[2],
                previous_color_mask[3],
            );
            for (enabled, capability) in previous_capabilities.into_iter().zip([
                gl::BLEND,
                gl::CULL_FACE,
                gl::DEPTH_TEST,
                gl::SCISSOR_TEST,
                gl::STENCIL_TEST,
            ]) {
                if enabled {
                    (self.gl.enable)(capability);
                } else {
                    (self.gl.disable)(capability);
                }
            }
        }
        // SAFETY: the same render context remains current after restoration.
        let restore_error = unsafe { (self.gl.get_error)() };
        let error = if draw_error != gl::NO_ERROR {
            draw_error
        } else {
            restore_error
        };
        if error != gl::NO_ERROR {
            error!(
                framebuffer = render_framebuffer,
                scanout_framebuffer = target.scanout_framebuffer,
                error = format_args!("{error:#x}"),
                "Flutter scene-to-scanout shader copy failed"
            );
            return false;
        }
        true
    }

    fn retain_native_texture(
        &self,
        source_texture: u32,
        width: u32,
        height: u32,
    ) -> Result<Arc<CachedTextureBinding>, Box<dyn Error>> {
        let width_i32 = i32::try_from(width).map_err(|_| "native snapshot width exceeds GLES")?;
        let height_i32 =
            i32::try_from(height).map_err(|_| "native snapshot height exceeds GLES")?;
        if source_texture == 0 || width_i32 <= 0 || height_i32 <= 0 {
            return Err("native snapshot has invalid texture or dimensions".into());
        }
        let binding_permit = self
            .external_texture_resource_budget
            .try_acquire()
            .ok_or("native snapshot exceeded the external texture resource limit")?;
        let shader_blit = lock(&self.shader_blit)
            .as_ref()
            .copied()
            .ok_or("native snapshot has no GLES copy pipeline")?;

        let mut previous_draw_framebuffer = 0;
        let mut previous_program = 0;
        let mut previous_active_texture = 0;
        let mut previous_texture_2d = 0;
        let mut previous_viewport = [0; 4];
        let mut previous_color_mask = [gl::FALSE; 4];
        let mut previous_capabilities = [false; 5];
        let mut texture = 0;
        let mut framebuffer = 0;
        let framebuffer_status;
        let draw_error;

        // The callback owns Flutter's current GLES context. Save and restore
        // every state touched by the private copy so Skia cannot observe the
        // snapshot operation in the surrounding external-texture callback.
        // SAFETY: all queried pointers are valid local storage and every GL
        // object is created, used, and either retained or deleted in this call.
        unsafe {
            for _ in 0..8 {
                if (self.gl.get_error)() == gl::NO_ERROR {
                    break;
                }
            }
            (self.gl.get_integer_v)(gl::DRAW_FRAMEBUFFER_BINDING, &mut previous_draw_framebuffer);
            (self.gl.get_integer_v)(gl::CURRENT_PROGRAM, &mut previous_program);
            (self.gl.get_integer_v)(gl::ACTIVE_TEXTURE, &mut previous_active_texture);
            (self.gl.get_integer_v)(gl::VIEWPORT, previous_viewport.as_mut_ptr());
            (self.gl.get_boolean_v)(gl::COLOR_WRITEMASK, previous_color_mask.as_mut_ptr());
            for (saved, capability) in previous_capabilities.iter_mut().zip([
                gl::BLEND,
                gl::CULL_FACE,
                gl::DEPTH_TEST,
                gl::SCISSOR_TEST,
                gl::STENCIL_TEST,
            ]) {
                *saved = (self.gl.is_enabled)(capability) == gl::TRUE;
            }
            (self.gl.active_texture)(gl::TEXTURE0);
            (self.gl.get_integer_v)(gl::TEXTURE_BINDING_2D, &mut previous_texture_2d);

            (self.gl.gen_textures)(1, &mut texture);
            (self.gl.bind_texture)(gl::TEXTURE_2D, texture);
            (self.gl.tex_parameter_i)(gl::TEXTURE_2D, gl::TEXTURE_MIN_FILTER, gl::LINEAR as i32);
            (self.gl.tex_parameter_i)(gl::TEXTURE_2D, gl::TEXTURE_MAG_FILTER, gl::LINEAR as i32);
            (self.gl.tex_parameter_i)(gl::TEXTURE_2D, gl::TEXTURE_WRAP_S, gl::CLAMP_TO_EDGE as i32);
            (self.gl.tex_parameter_i)(gl::TEXTURE_2D, gl::TEXTURE_WRAP_T, gl::CLAMP_TO_EDGE as i32);
            (self.gl.tex_image_2d)(
                gl::TEXTURE_2D,
                0,
                gl::RGBA8 as i32,
                width_i32,
                height_i32,
                0,
                gl::RGBA,
                gl::UNSIGNED_BYTE,
                ptr::null(),
            );
            (self.gl.gen_framebuffers)(1, &mut framebuffer);
            (self.gl.bind_framebuffer)(gl::DRAW_FRAMEBUFFER, framebuffer);
            (self.gl.framebuffer_texture_2d)(
                gl::DRAW_FRAMEBUFFER,
                gl::COLOR_ATTACHMENT0,
                gl::TEXTURE_2D,
                texture,
                0,
            );
            framebuffer_status = (self.gl.check_framebuffer_status)(gl::DRAW_FRAMEBUFFER);
            if texture != 0 && framebuffer != 0 && framebuffer_status == gl::FRAMEBUFFER_COMPLETE {
                (self.gl.viewport)(0, 0, width_i32, height_i32);
                (self.gl.disable)(gl::BLEND);
                (self.gl.disable)(gl::CULL_FACE);
                (self.gl.disable)(gl::DEPTH_TEST);
                (self.gl.disable)(gl::SCISSOR_TEST);
                (self.gl.disable)(gl::STENCIL_TEST);
                (self.gl.color_mask)(gl::TRUE, gl::TRUE, gl::TRUE, gl::TRUE);
                (self.gl.use_program)(shader_blit.program);
                (self.gl.active_texture)(gl::TEXTURE0);
                (self.gl.bind_texture)(gl::TEXTURE_2D, source_texture);
                (self.gl.uniform_1i)(shader_blit.source_uniform, 0);
                (self.gl.draw_arrays)(gl::TRIANGLES, 0, 3);
            }
            draw_error = (self.gl.get_error)();

            (self.gl.use_program)(previous_program as u32);
            (self.gl.bind_texture)(gl::TEXTURE_2D, previous_texture_2d as u32);
            (self.gl.active_texture)(previous_active_texture as u32);
            (self.gl.bind_framebuffer)(gl::DRAW_FRAMEBUFFER, previous_draw_framebuffer as u32);
            (self.gl.viewport)(
                previous_viewport[0],
                previous_viewport[1],
                previous_viewport[2],
                previous_viewport[3],
            );
            (self.gl.color_mask)(
                previous_color_mask[0],
                previous_color_mask[1],
                previous_color_mask[2],
                previous_color_mask[3],
            );
            for (enabled, capability) in previous_capabilities.into_iter().zip([
                gl::BLEND,
                gl::CULL_FACE,
                gl::DEPTH_TEST,
                gl::SCISSOR_TEST,
                gl::STENCIL_TEST,
            ]) {
                if enabled {
                    (self.gl.enable)(capability);
                } else {
                    (self.gl.disable)(capability);
                }
            }
            if framebuffer != 0 {
                (self.gl.delete_framebuffers)(1, &framebuffer);
            }
        }
        // SAFETY: the same render context remains current after restoration.
        let restore_error = unsafe { (self.gl.get_error)() };
        if texture == 0
            || framebuffer == 0
            || framebuffer_status != gl::FRAMEBUFFER_COMPLETE
            || draw_error != gl::NO_ERROR
            || restore_error != gl::NO_ERROR
        {
            // SAFETY: an allocated texture remains owned by this context and
            // has not escaped on the failure path.
            unsafe {
                if texture != 0 {
                    (self.gl.delete_textures)(1, &texture);
                }
            }
            return Err(format!(
                "native snapshot copy failed: framebuffer={framebuffer} status={framebuffer_status:#x} draw={draw_error:#x} restore={restore_error:#x}"
            )
            .into());
        }
        Ok(Arc::new(CachedTextureBinding {
            binding: Some(ExternalTextureBinding {
                dmabuf_image: None,
                texture,
                _resource_permit: binding_permit,
            }),
            retirements: Arc::clone(&self.retired_external_bindings),
        }))
    }

    fn destroy_targets(&self) {
        let mut targets = lock(&self.targets);
        let mut shader_blit = lock(&self.shader_blit);
        let mut depth_stencils = lock(&self.depth_stencils);
        if targets.is_empty() && shader_blit.is_none() && depth_stencils.is_empty() {
            return;
        }
        let mut context = lock(&self.render_context);
        // SAFETY: EngineHost has already shut down and joined its raster
        // thread, so this context is no longer current anywhere else.
        if let Err(error) = unsafe { context.context.make_current() } {
            error!(%error, "could not bind Flutter context for output-target cleanup");
            return;
        }
        context.owner = Some(thread::current().id());
        let cached_dmabufs = lock(&self.dmabuf_texture_cache).drain();
        let cached_native = lock(&self.retained_native_texture_cache).drain();
        let cached_shm = lock(&self.shm_texture_cache).drain();
        drop((cached_dmabufs, cached_native, cached_shm));
        self.destroy_retired_external_bindings();
        destroy_shader_blit(self.gl, &mut shader_blit);
        destroy_targets(self.gl, &self.display, &mut targets);
        destroy_depth_stencils(self.gl, &mut depth_stencils);
        let _ = context.clear_current();
    }

    fn destroy_retired_external_bindings(&self) {
        // The flag is a hint in front of the mutex-protected queue. Missing a
        // concurrent transition here only defers reclamation to the next
        // callback; it cannot lose the queued binding or clear the flag.
        if !self
            .retired_external_bindings
            .pending
            .load(Ordering::Relaxed)
        {
            return;
        }
        if !self
            .retired_external_bindings
            .pending
            .swap(false, Ordering::Relaxed)
        {
            return;
        }
        let mut retired = lock(&self.retired_external_binding_scratch);
        debug_assert!(retired.is_empty());
        {
            let mut pending = lock(&self.retired_external_bindings.bindings);
            mem::swap(&mut *retired, &mut *pending);
        }
        for binding in retired.drain(..) {
            // SAFETY: this is called only with the Flutter render context
            // current, and every object was created by that context.
            unsafe {
                if binding.texture != 0 {
                    (self.gl.delete_textures)(1, &binding.texture);
                }
                if let Some((_dmabuf, image)) = binding.dmabuf_image
                    && image != 0
                {
                    egl_ffi::egl::DestroyImageKHR(
                        self.display.handle,
                        image as egl_ffi::egl::types::EGLImageKHR,
                    );
                }
            }
        }
    }

    /// Reserves a cache hit for the immediately following Flutter texture
    /// callback without issuing GL calls. Holding the binding and Wayland
    /// guard here closes the race between the engine's preflight and callback.
    fn prepare_external_texture_without_gl(&self, texture_id: i64) -> bool {
        let mut prepared_slot = lock(&self.prepared_external_texture);
        if prepared_slot.take().is_some() {
            return false;
        }
        if self
            .retired_external_bindings
            .pending
            .load(Ordering::Relaxed)
        {
            return false;
        }
        let Some(source) = self.current_external_texture(texture_id) else {
            return false;
        };
        let source_generation = source.generation();
        let Some(lease_permit) = self.external_texture_resource_budget.try_acquire() else {
            return false;
        };
        let (width, height, binding, resource, sampled_buffer) = match source {
            ExternalTextureSource::Dmabuf {
                dmabuf,
                buffer_guard,
                revision,
            } => {
                let dmabuf_width = dmabuf.width();
                let dmabuf_height = dmabuf.height();
                let width = usize::try_from(dmabuf_width).unwrap_or_default();
                let height = usize::try_from(dmabuf_height).unwrap_or_default();
                if buffer_guard
                    .as_ref()
                    .is_some_and(ExternalBufferGuard::is_native)
                {
                    let Some(binding) = self.cached_retained_native_binding(texture_id, revision)
                    else {
                        return false;
                    };
                    let resource = ExternalTextureLeaseResource::Retained {
                        _binding: Arc::clone(&binding),
                        _resource_permit: lease_permit,
                    };
                    (width, height, binding, resource, None)
                } else {
                    let Some(binding) = self.cached_dmabuf_binding(texture_id, &dmabuf) else {
                        return false;
                    };
                    let sampled_buffer = buffer_guard.clone();
                    let resource = ExternalTextureLeaseResource::Dmabuf {
                        _binding: Arc::clone(&binding),
                        _buffer_guard: buffer_guard,
                        _resource_permit: lease_permit,
                    };
                    (width, height, binding, resource, sampled_buffer)
                }
            }
            ExternalTextureSource::Shm(frame) => {
                let width = usize::try_from(frame.width).unwrap_or_default();
                let height = usize::try_from(frame.height).unwrap_or_default();
                let Some(binding) = self.cached_shm_binding(texture_id, frame.revision) else {
                    return false;
                };
                let resource = ExternalTextureLeaseResource::Shm {
                    _binding: Arc::clone(&binding),
                    _resource_permit: lease_permit,
                };
                (width, height, binding, resource, None)
            }
        };
        let name = binding.texture();
        if width == 0 || height == 0 || name == 0 {
            return false;
        }
        *prepared_slot = Some(PreparedExternalTexture {
            texture_id,
            source_generation,
            width,
            height,
            name,
            resource,
            sampled_buffer,
        });
        true
    }

    /// Drain the bounded GLES error queue while the Flutter render context is
    /// current. Returning the first error lets callers reject a partially
    /// created texture without caching or publishing it to Flutter.
    fn take_gl_error(&self) -> Option<u32> {
        const GL_NO_ERROR: u32 = 0;
        const MAX_DRAINED_ERRORS: usize = 16;

        let mut first = None;
        for _ in 0..MAX_DRAINED_ERRORS {
            // SAFETY: every caller runs from a Flutter callback with this
            // handler's render context current.
            let error = unsafe { (self.gl.get_error)() };
            if error == GL_NO_ERROR {
                break;
            }
            first.get_or_insert(error);
        }
        first
    }
}

impl OpenGlHandler for FlutterGlHandler {
    fn make_current(&self) -> bool {
        let current = lock(&self.render_context).make_current();
        if current && self.begin_raster_frame() {
            debug_assert!(lock(&self.sampled_buffer_release_fence).is_none());
            lock(&self.broker).begin_transaction();
        }
        current
    }

    fn clear_current(&self) -> bool {
        lock(&self.render_context).clear_current()
    }

    fn make_resource_current(&self) -> bool {
        lock(&self.resource_context).make_current()
    }

    fn raster_idle(&self) {
        // The host posts this sentinel behind Flutter's current render work.
        // If present() already sealed the transaction this is idempotent; if
        // the transaction had no present callback it supplies the missing
        // REQUESTED/RASTERIZING -> IDLE transition.
        let ready = lock(&self.broker).finish_transaction();
        let previous = self.finish_producer_frame();
        if !ready.is_empty() {
            let sampled = self.seal_sampled_buffers();
            if let Some(audit) = &self.render_audit {
                lock(audit).record_sampled_textures(sampled.as_ref());
            }
            let release_fence = lock(&self.sampled_buffer_release_fence).take();
            self.publish_sampled_buffer_release(release_fence, sampled);
            self.publish_ready_frames(ready);
        } else {
            lock(&self.sampled_buffer_release_fence).take();
            if let Some(audit) = &self.render_audit {
                lock(audit).record_empty_transaction();
            }
        }
        if matches!(
            previous,
            FlutterProducerState::Requested | FlutterProducerState::Rasterizing
        ) {
            self.rearm_abandoned_samples();
            let batch = self.seal_sampled_buffers();
            if batch.is_some() {
                // The raster transaction returned without present(), so no
                // exportable fence exists. Match the C++ conservative path.
                // SAFETY: the sentinel runs on Flutter's render thread after
                // the abandoned raster task.
                unsafe { (self.gl.finish)() };
                self.publish_sampled_buffer_release(None, batch);
            }
        }
    }

    fn surface_transformation(&self) -> sys::FlutterTransformation {
        // The legacy root surface is never presented. Denial's engine applies
        // the OpenGL Y inversion independently while preparing each physical
        // render view, using that target's native height.
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

    fn framebuffer(&self, width: u32, height: u32) -> u32 {
        debug!(
            width,
            height, "ignored legacy Flutter root-surface FBO request"
        );
        0
    }

    fn create_backing_store(&self, request: BackingStoreRequest) -> Option<CompositorBackingStore> {
        let size = PixelSize::new(
            u32::try_from(request.width).ok()?,
            u32::try_from(request.height).ok()?,
        );
        let framebuffer = match lock(&self.broker).acquire(request.view_id, size) {
            Ok(framebuffer) => framebuffer,
            Err(blocked) => {
                if let Some(audit) = &self.render_audit {
                    lock(audit).record_target_blocked(blocked);
                }
                // Every independently clocked output can temporarily retain a
                // scanning generation, an atomic submission awaiting page flip,
                // and a newer ready generation. Exhaustion remains ordinary
                // producer backpressure if a supported topology reaches its
                // bounded worst case. Flutter accepts FBO 0 as a skipped frame;
                // present() completes that no-op successfully so it returns to
                // AwaitVSync instead of entering a retry storm that could starve
                // the page flip which frees the next target.
                return None;
            }
        };
        // Leave the selected FBO current as required by the embedder OpenGL
        // contract. Denial's versioned engine stack queries the attached
        // level-zero texture and wraps it as borrowed storage; Skia owns the
        // stencil and dynamic-MSAA resources used to render into it.
        // SAFETY: Flutter calls this with the render context current.
        unsafe {
            (self.gl.bind_framebuffer)(gl::FRAMEBUFFER, framebuffer);
            (self.gl.viewport)(0, 0, size.width as i32, size.height as i32);
        }
        Some(CompositorBackingStore {
            framebuffer,
            format: gl::RGBA8,
            // The pool owns the target. This identity makes a malformed or
            // cross-view present observable without allocating a callback
            // baton for every raster pass.
            user_data: framebuffer as usize,
        })
    }

    fn collect_backing_store(&self, backing_store: CompositorBackingStore) -> bool {
        // Flutter returns only its temporary render-target borrow. The native
        // target stays in OutputBufferBroker and is recycled after KMS ownership is
        // released, not when the engine destroys its wrapper.
        lock(&self.targets).iter().any(|target| {
            target.render_framebuffer == backing_store.framebuffer
                && backing_store.user_data == backing_store.framebuffer as usize
        })
    }

    fn present_view(&self, view: PresentView<'_>) -> bool {
        let target = lock(&self.targets)
            .iter()
            .find(|target| {
                target.render_view_id.get() == view.view_id
                    && target.render_framebuffer == view.backing_store.framebuffer
            })
            .copied();
        let Some(target) = target else {
            error!(
                view_id = view.view_id,
                framebuffer = view.backing_store.framebuffer,
                "Flutter compositor presented an unknown output backing store"
            );
            return false;
        };
        if view.backing_store.user_data != view.backing_store.framebuffer as usize
            || view.offset_x != 0.0
            || view.offset_y != 0.0
            || view.width != f64::from(target.size.width)
            || view.height != f64::from(target.size.height)
            || !lock(&self.broker).validate_backing_store(
                view.view_id,
                view.backing_store.framebuffer,
                target.size,
            )
        {
            error!(
                view_id = view.view_id,
                framebuffer = view.backing_store.framebuffer,
                offset_x = view.offset_x,
                offset_y = view.offset_y,
                width = view.width,
                height = view.height,
                expected_width = target.size.width,
                expected_height = target.size.height,
                output_id = target.output_id.0,
                configuration_generation = target.configuration_generation,
                buffer_index = target.buffer_index,
                "Flutter compositor presented an invalid physical-output layer"
            );
            return false;
        }
        let mut pending = lock(&self.pending_output_presentation);
        if pending.is_some() {
            error!(view_id = view.view_id, "nested Flutter output presentation");
            return false;
        }
        *pending = Some(PendingOutputPresentation {
            view_id: view.view_id,
            framebuffer: view.backing_store.framebuffer,
        });
        // The external-view callback identifies the physical backing store.
        // Exact frame and buffer damage arrive immediately afterwards through
        // the root SurfaceFrame's standard present-with-info callback.
        true
    }

    fn present(&self, frame: PresentFrame<'_>) -> bool {
        let Some(pending) = lock(&self.pending_output_presentation).take() else {
            if frame.framebuffer == 0 {
                // A raster task with no compositor layer still submits its
                // otherwise unused root SurfaceFrame.
                return true;
            }
            error!(
                framebuffer = frame.framebuffer,
                "legacy Flutter surface attempted to bypass output compositor"
            );
            return false;
        };
        if frame.framebuffer != 0 {
            error!(
                view_id = pending.view_id,
                framebuffer = frame.framebuffer,
                "Flutter output damage bypassed the root presentation handoff"
            );
            return false;
        }
        let view_id = pending.view_id;
        let framebuffer = pending.framebuffer;
        self.begin_present();
        (|| {
            // Surface removal and cache eviction can happen on the platform
            // thread, where issuing GL/EGL destruction calls is forbidden. A
            // raster present owns the render context, so reclaim those queued
            // resources even when no further external texture is populated.
            self.destroy_retired_external_bindings();
            if !self.blit_to_scanout(framebuffer) {
                let sampled = self.seal_sampled_buffers();
                // A failed copy cannot produce a KMS fence. Finish Flutter's
                // sampling before releasing client buffers, then let the next
                // acquisition invalidate and recycle this rendering slot.
                // SAFETY: present runs with the raster context current.
                unsafe { (self.gl.finish)() };
                let _ = self.publish_sampled_buffer_release(None, sampled);
                return false;
            }
            let context = lock(&self.render_context);
            let fence = match EGLFence::create(context.context.display()) {
                Ok(fence) => {
                    // The fence follows Flutter's render commands. Flushing
                    // publishes the native sync_file without waiting for GPU
                    // completion on the raster thread.
                    // SAFETY: present runs with the raster context current.
                    unsafe { (self.gl.flush)() };
                    match fence.export() {
                        Ok(fence) => Some(fence),
                        Err(error) => {
                            let reason = format!(
                                "could not export the required Flutter native fence: {error}"
                            );
                            error!(%error, "required Flutter native fence export failed");
                            // Complete outstanding sampling only so teardown
                            // can release imported client buffers safely. This
                            // frame is not published as an unfenced fallback.
                            // SAFETY: present runs with the raster context current.
                            unsafe { (self.gl.finish)() };
                            let sampled = self.seal_sampled_buffers();
                            let _ = self.publish_sampled_buffer_release(None, sampled);
                            let _ = self.events.send(RuntimeEvent::FatalRender {
                                generation: self.generation,
                                reason,
                            });
                            return false;
                        }
                    }
                }
                Err(error) => {
                    let reason =
                        format!("could not create the required Flutter native fence: {error}");
                    error!(%error, "required Flutter native fence creation failed");
                    // Complete outstanding sampling only so teardown can
                    // release imported client buffers safely. This frame is
                    // not published as an unfenced fallback.
                    // SAFETY: present runs with the raster context current.
                    unsafe { (self.gl.finish)() };
                    let sampled = self.seal_sampled_buffers();
                    let _ = self.publish_sampled_buffer_release(None, sampled);
                    let _ = self.events.send(RuntimeEvent::FatalRender {
                        generation: self.generation,
                        reason,
                    });
                    return false;
                }
            };
            if let Some(audit) = &self.render_audit {
                lock(audit).record_present(
                    view_id,
                    lock(&self.targets)
                        .iter()
                        .find(|target| target.render_framebuffer == framebuffer)
                        .map_or(self.desktop_size, |target| target.size),
                    frame.frame_damage,
                    frame.buffer_damage,
                );
            }
            let release_fence = match fence.as_ref() {
                Some(fence) => match fence.as_fd().try_clone_to_owned() {
                    Ok(fence) => Some(fence),
                    Err(error) => {
                        warn!(%error, "could not duplicate Flutter render fence; using glFinish for sampled buffers");
                        // SAFETY: present runs with the raster context current.
                        unsafe { (self.gl.finish)() };
                        None
                    }
                },
                None => {
                    // Fence-less output presentation is only reachable after
                    // a synchronous GL completion fallback.
                    // SAFETY: present runs with the raster context current.
                    unsafe { (self.gl.finish)() };
                    None
                }
            };
            *lock(&self.sampled_buffer_release_fence) = release_fence;
            let rendered_at = self.render_audit.as_ref().map(|_| Instant::now());
            if !lock(&self.broker).mark_ready(
                view_id,
                framebuffer,
                frame.frame_damage,
                frame.buffer_damage,
                fence,
                rendered_at,
            ) {
                error!(
                    view_id,
                    framebuffer, "Flutter presented an output FBO that was not rendering"
                );
                return false;
            }
            true
        })()
    }

    fn populate_existing_damage(&self, framebuffer: isize, damage: &mut Vec<sys::FlutterRect>) {
        if framebuffer == 0 {
            return;
        }
        if !lock(&self.broker).populate_existing_damage(framebuffer, damage) {
            // Flutter should only ask about an FBO returned by framebuffer().
            // Unknown IDs still degrade safely instead of declaring no damage.
            warn!(
                framebuffer,
                "Flutter requested damage for an unknown output FBO"
            );
            let size = lock(&self.targets)
                .iter()
                .find(|target| target.render_framebuffer as isize == framebuffer)
                .map_or(self.desktop_size, |target| target.size);
            damage.push(sys::FlutterRect {
                left: 0.0,
                top: 0.0,
                right: f64::from(size.width),
                bottom: f64::from(size.height),
            });
        }
    }

    fn resolve_proc(&self, name: &CStr) -> *mut c_void {
        let Ok(name) = name.to_str() else {
            return ptr::null_mut();
        };
        // SAFETY: Flutter asks for procedures while one of our EGL contexts is
        // current on the calling engine thread.
        unsafe { get_proc_address(name).cast_mut() }
    }

    fn external_texture_callback_may_modify_gl(&self, texture_id: i64) -> bool {
        !self.prepare_external_texture_without_gl(texture_id)
    }

    fn populate_external_texture(
        &self,
        texture_id: i64,
        _width: usize,
        _height: usize,
        texture: &mut sys::FlutterOpenGLTexture,
    ) -> bool {
        let prepared = lock(&self.prepared_external_texture).take();
        if let Some(prepared) = prepared {
            if prepared.texture_id != texture_id {
                // The engine extension promises that this callback immediately
                // follows the preflight for the same texture. Refuse the frame
                // without touching GL if a mismatched engine violates it.
                error!(
                    texture_id,
                    prepared_texture_id = prepared.texture_id,
                    "external texture preflight did not match Flutter callback"
                );
                return false;
            }
            let lease = self.lease_external_texture(prepared.resource);
            *texture = sys::FlutterOpenGLTexture {
                target: gl::TEXTURE_2D,
                name: prepared.name,
                format: gl::RGBA8,
                user_data: Box::into_raw(lease).cast(),
                destruction_callback: Some(retire_external_texture),
                width: prepared.width,
                height: prepared.height,
            };
            if let Some(buffer_guard) = prepared.sampled_buffer {
                self.record_sampled_buffer(texture_id, prepared.source_generation, buffer_guard);
            }
            self.mark_external_texture_sampled(texture_id, prepared.source_generation);
            return true;
        }
        // Flutter invokes this callback with the render context current. Drain
        // leases released by earlier engine frames before allocating the next
        // direct EGLImage binding.
        self.destroy_retired_external_bindings();
        let Some(source) = self.current_external_texture(texture_id) else {
            return false;
        };
        let source_generation = source.generation();
        let Some(lease_permit) = self.external_texture_resource_budget.try_acquire() else {
            warn!(
                texture_id,
                limit = MAX_LIVE_EXTERNAL_TEXTURE_RESOURCES,
                "rejected Flutter external texture lease after resource limit"
            );
            return false;
        };
        let (width, height, name, lease, sampled_buffer) = match source {
            ExternalTextureSource::Dmabuf {
                dmabuf,
                buffer_guard,
                revision,
            } => {
                let dmabuf_width = dmabuf.width();
                let dmabuf_height = dmabuf.height();
                let width = usize::try_from(dmabuf_width).unwrap_or_default();
                let height = usize::try_from(dmabuf_height).unwrap_or_default();
                if width == 0 || height == 0 {
                    return false;
                }
                let cached = self.cached_dmabuf_binding(texture_id, &dmabuf);
                let binding = if let Some(binding) = cached {
                    binding
                } else {
                    let Some(binding_permit) = self.external_texture_resource_budget.try_acquire()
                    else {
                        warn!(
                            texture_id,
                            limit = MAX_LIVE_EXTERNAL_TEXTURE_RESOURCES,
                            "rejected dma-buf EGLImage after external texture resource limit"
                        );
                        return false;
                    };
                    let context = lock(&self.render_context);
                    let image = match context.context.display().create_image_from_dmabuf(&dmabuf) {
                        Ok(image) => image,
                        Err(error) => {
                            warn!(%error, texture_id, "could not import Wayland dma-buf for Flutter");
                            return false;
                        }
                    };
                    drop(context);
                    let mut name = 0;
                    if let Some(error) = self.take_gl_error() {
                        warn!(
                            error = format_args!("{error:#x}"),
                            texture_id, "discarded stale GLES error before dma-buf import"
                        );
                    }
                    // SAFETY: the Flutter render context is current on this callback thread.
                    unsafe {
                        (self.gl.gen_textures)(1, &mut name);
                        (self.gl.bind_texture)(gl::TEXTURE_2D, name);
                        (self.gl.tex_parameter_i)(
                            gl::TEXTURE_2D,
                            gl::TEXTURE_MIN_FILTER,
                            gl::LINEAR as i32,
                        );
                        (self.gl.tex_parameter_i)(
                            gl::TEXTURE_2D,
                            gl::TEXTURE_MAG_FILTER,
                            gl::LINEAR as i32,
                        );
                        (self.gl.tex_parameter_i)(
                            gl::TEXTURE_2D,
                            gl::TEXTURE_WRAP_S,
                            gl::CLAMP_TO_EDGE as i32,
                        );
                        (self.gl.tex_parameter_i)(
                            gl::TEXTURE_2D,
                            gl::TEXTURE_WRAP_T,
                            gl::CLAMP_TO_EDGE as i32,
                        );
                        (self.gl.image_target_texture)(gl::TEXTURE_2D, image.cast());
                    }
                    let gl_error = self.take_gl_error();
                    if name == 0 || gl_error.is_some() {
                        // SAFETY: the texture, when allocated, belongs to the
                        // current render context and has not escaped this call.
                        unsafe {
                            if name != 0 {
                                (self.gl.delete_textures)(1, &name);
                            }
                        }
                        // SAFETY: the image was created on this EGL display and
                        // has not been installed in a cache entry.
                        unsafe {
                            egl_ffi::egl::DestroyImageKHR(self.display.handle, image);
                        }
                        if let Some(error) = gl_error {
                            warn!(
                                error = format_args!("{error:#x}"),
                                texture_id, "rejected Wayland dma-buf after GLES import failure"
                            );
                        }
                        return false;
                    }
                    let binding = Arc::new(CachedTextureBinding {
                        binding: Some(ExternalTextureBinding {
                            dmabuf_image: Some((dmabuf.clone(), image as usize)),
                            texture: name,
                            _resource_permit: binding_permit,
                        }),
                        retirements: Arc::clone(&self.retired_external_bindings),
                    });
                    self.cache_dmabuf_binding(texture_id, dmabuf, Arc::clone(&binding));
                    // An insertion can evict an inactive LRU entry. Its Drop
                    // only queued GL objects, and this callback owns a current
                    // render context, so reclaim them immediately.
                    self.destroy_retired_external_bindings();
                    binding
                };
                let name = binding.texture();
                if name == 0 {
                    return false;
                }
                if buffer_guard
                    .as_ref()
                    .is_some_and(ExternalBufferGuard::is_native)
                {
                    let (retained, copied) = if let Some(retained) =
                        self.cached_retained_native_binding(texture_id, revision)
                    {
                        (retained, false)
                    } else {
                        let retained =
                            match self.retain_native_texture(name, dmabuf_width, dmabuf_height) {
                                Ok(retained) => retained,
                                Err(error) => {
                                    warn!(
                                        %error,
                                        texture_id,
                                        revision,
                                        "could not retain native dma-buf for Flutter"
                                    );
                                    return false;
                                }
                            };
                        self.cache_retained_native_binding(
                            texture_id,
                            revision,
                            Arc::clone(&retained),
                        );
                        self.destroy_retired_external_bindings();
                        (retained, true)
                    };
                    let name = retained.texture();
                    if name == 0 {
                        return false;
                    }
                    let sampled_buffer = copied.then(|| buffer_guard.clone()).flatten();
                    (
                        width,
                        height,
                        name,
                        ExternalTextureLeaseResource::Retained {
                            _binding: retained,
                            _resource_permit: lease_permit,
                        },
                        sampled_buffer,
                    )
                } else {
                    let sampled_buffer = buffer_guard.clone();
                    (
                        width,
                        height,
                        name,
                        ExternalTextureLeaseResource::Dmabuf {
                            _binding: binding,
                            _buffer_guard: buffer_guard,
                            _resource_permit: lease_permit,
                        },
                        sampled_buffer,
                    )
                }
            }
            ExternalTextureSource::Shm(frame) => {
                let width = usize::try_from(frame.width).unwrap_or_default();
                let height = usize::try_from(frame.height).unwrap_or_default();
                if width == 0 || height == 0 {
                    return false;
                }
                let Ok(width_i32) = i32::try_from(frame.width) else {
                    return false;
                };
                let Ok(height_i32) = i32::try_from(frame.height) else {
                    return false;
                };
                let binding = if let Some(binding) =
                    self.cached_shm_binding(texture_id, frame.revision)
                {
                    binding
                } else {
                    let Some(binding_permit) = self.external_texture_resource_budget.try_acquire()
                    else {
                        warn!(
                            texture_id,
                            limit = MAX_LIVE_EXTERNAL_TEXTURE_RESOURCES,
                            "rejected SHM upload after external texture resource limit"
                        );
                        return false;
                    };
                    let mut name = 0;
                    if let Some(error) = self.take_gl_error() {
                        warn!(
                            error = format_args!("{error:#x}"),
                            texture_id, "discarded stale GLES error before SHM upload"
                        );
                    }
                    // SHM snapshots are tightly packed RGBA8, so the default
                    // four-byte unpack alignment is valid for every row.
                    // SAFETY: Flutter invokes this callback with the render
                    // context current; `frame.pixels()` contains the complete
                    // validated width-by-height RGBA payload.
                    unsafe {
                        (self.gl.gen_textures)(1, &mut name);
                        (self.gl.bind_texture)(gl::TEXTURE_2D, name);
                        (self.gl.tex_parameter_i)(
                            gl::TEXTURE_2D,
                            gl::TEXTURE_MIN_FILTER,
                            gl::LINEAR as i32,
                        );
                        (self.gl.tex_parameter_i)(
                            gl::TEXTURE_2D,
                            gl::TEXTURE_MAG_FILTER,
                            gl::LINEAR as i32,
                        );
                        (self.gl.tex_parameter_i)(
                            gl::TEXTURE_2D,
                            gl::TEXTURE_WRAP_S,
                            gl::CLAMP_TO_EDGE as i32,
                        );
                        (self.gl.tex_parameter_i)(
                            gl::TEXTURE_2D,
                            gl::TEXTURE_WRAP_T,
                            gl::CLAMP_TO_EDGE as i32,
                        );
                        (self.gl.tex_image_2d)(
                            gl::TEXTURE_2D,
                            0,
                            gl::RGBA as i32,
                            width_i32,
                            height_i32,
                            0,
                            gl::RGBA,
                            gl::UNSIGNED_BYTE,
                            frame.pixels().as_ptr().cast(),
                        );
                    }
                    let gl_error = self.take_gl_error();
                    if name == 0 || gl_error.is_some() {
                        // SAFETY: the texture, when allocated, belongs to the
                        // current render context and has not escaped this call.
                        unsafe {
                            if name != 0 {
                                (self.gl.delete_textures)(1, &name);
                            }
                        }
                        if let Some(error) = gl_error {
                            warn!(
                                error = format_args!("{error:#x}"),
                                texture_id,
                                "rejected Wayland SHM texture after GLES upload failure"
                            );
                        }
                        return false;
                    }
                    let revision = frame.revision;
                    let binding = Arc::new(CachedTextureBinding {
                        binding: Some(ExternalTextureBinding {
                            dmabuf_image: None,
                            texture: name,
                            _resource_permit: binding_permit,
                        }),
                        retirements: Arc::clone(&self.retired_external_bindings),
                    });
                    self.cache_shm_binding(texture_id, revision, Arc::clone(&binding));
                    self.destroy_retired_external_bindings();
                    binding
                };
                let name = binding.texture();
                if name == 0 {
                    return false;
                }
                (
                    width,
                    height,
                    name,
                    ExternalTextureLeaseResource::Shm {
                        _binding: binding,
                        _resource_permit: lease_permit,
                    },
                    None,
                )
            }
        };
        if width == 0 || height == 0 {
            drop(lease);
            return false;
        }
        let lease = self.lease_external_texture(lease);
        *texture = sys::FlutterOpenGLTexture {
            target: gl::TEXTURE_2D,
            name,
            format: gl::RGBA8,
            user_data: Box::into_raw(lease).cast(),
            destruction_callback: Some(retire_external_texture),
            width,
            height,
        };
        if let Some(buffer_guard) = sampled_buffer {
            self.record_sampled_buffer(texture_id, source_generation, buffer_guard);
        }
        self.mark_external_texture_sampled(texture_id, source_generation);
        true
    }

    fn event(&self, event: EngineEvent) {
        if let EngineEvent::PlatformTask(task) = &event {
            let Some(permit) = self.platform_task_budget.try_acquire() else {
                error!(
                    runner = task.runner,
                    task = task.task,
                    limit = MAX_PENDING_PLATFORM_TASKS,
                    "dropped Flutter platform task after pending task limit"
                );
                self.report_queue_overflow("platform task");
                return;
            };
            if !self.platform_tasks.push(PendingPlatformTask {
                task: *task,
                permit,
            }) {
                return;
            }
            if self
                .events
                .send(RuntimeEvent::PlatformTasksReady {
                    generation: self.generation,
                })
                .is_err()
            {
                self.platform_tasks.discard_after_failed_wakeup();
            }
            return;
        }
        // AwaitVSync batons are one-shot obligations owned by the embedder.
        // Keep an independent record before handing the event to calloop so a
        // topology restart can fulfil batons that have not reached the main
        // thread yet. Flutter shutdown may otherwise race a blocked animator.
        if let EngineEvent::Vsync(baton) = &event {
            match lock(&self.pending_vsync_batons).register(*baton) {
                VsyncRegistration::Accepted => {}
                VsyncRegistration::Duplicate => {
                    warn!(baton, "ignored duplicate pending Flutter vsync baton");
                    return;
                }
                VsyncRegistration::AtCapacity => {
                    error!(
                        baton,
                        limit = MAX_PENDING_VSYNC_BATONS,
                        "dropped Flutter vsync request after pending baton limit"
                    );
                    self.report_queue_overflow("vsync baton");
                    return;
                }
            }
        }
        let _ = self.events.send(RuntimeEvent::Engine {
            generation: self.generation,
            event,
        });
    }

    fn log(&self, tag: &str, message: &str) {
        if tag.is_empty() {
            eprintln!("flutter: {message}");
        } else {
            eprintln!("flutter[{tag}]: {message}");
        }
        let Some(uri) = vm_service_uri_from_log(message) else {
            return;
        };
        let _ = self.events.send(RuntimeEvent::VmServiceUri {
            generation: self.generation,
            uri: uri.to_owned(),
        });
    }
}

fn vm_service_uri_from_log(message: &str) -> Option<&str> {
    const MAX_VM_SERVICE_URI_BYTES: usize = 2048;
    const ANNOUNCEMENT: &str = "The Dart VM service is listening on ";
    const LOOPBACK_PREFIX: &str = "http://127.0.0.1:";
    let start = message
        .find(ANNOUNCEMENT)?
        .checked_add(ANNOUNCEMENT.len())?;
    let uri = message[start..]
        .split_ascii_whitespace()
        .next()?
        .trim_end_matches(['.', ',', ';']);
    if uri.len() > MAX_VM_SERVICE_URI_BYTES {
        return None;
    }
    let authority_and_path = uri.strip_prefix(LOOPBACK_PREFIX)?;
    let (port, authentication_path) = authority_and_path.split_once('/')?;
    if port.parse::<u16>().ok().is_none_or(|port| port == 0)
        || authentication_path.is_empty()
        || !authentication_path
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'/' | b'=' | b'_' | b'-'))
    {
        return None;
    }
    Some(uri)
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

const SCANOUT_VERTEX_SHADER: &[u8] = b"#version 300 es\n\
precision highp float;\n\
out vec2 texture_coordinate;\n\
void main() {\n\
    vec2 position = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));\n\
    texture_coordinate = position;\n\
    gl_Position = vec4(position * 2.0 - 1.0, 0.0, 1.0);\n\
}\n\0";

const SCANOUT_FRAGMENT_SHADER: &[u8] = b"#version 300 es\n\
precision highp float;\n\
uniform sampler2D source_texture;\n\
in vec2 texture_coordinate;\n\
layout(location = 0) out vec4 fragment_color;\n\
void main() {\n\
    fragment_color = texture(source_texture, texture_coordinate);\n\
}\n\0";

fn create_shader_blit(gl: GlApi) -> Result<ShaderBlit, Box<dyn Error>> {
    let vertex = compile_shader(gl, gl::VERTEX_SHADER, SCANOUT_VERTEX_SHADER)?;
    let fragment = match compile_shader(gl, gl::FRAGMENT_SHADER, SCANOUT_FRAGMENT_SHADER) {
        Ok(fragment) => fragment,
        Err(error) => {
            // SAFETY: `vertex` was created in the current context above.
            unsafe { (gl.delete_shader)(vertex) };
            return Err(error);
        }
    };
    // SAFETY: a compatible GLES context is current and both shader names are
    // valid in it until they are deleted after the link attempt.
    let program = unsafe {
        let program = (gl.create_program)();
        if program != 0 {
            (gl.attach_shader)(program, vertex);
            (gl.attach_shader)(program, fragment);
            (gl.link_program)(program);
        }
        (gl.delete_shader)(vertex);
        (gl.delete_shader)(fragment);
        program
    };
    if program == 0 {
        return Err("could not allocate Flutter scanout-copy shader program".into());
    }
    let mut linked = 0;
    // SAFETY: `program` is a live program in the current GLES context.
    unsafe { (gl.get_program_iv)(program, gl::LINK_STATUS, &mut linked) };
    if linked == 0 {
        let log = program_info_log(gl, program);
        // SAFETY: the failed program remains live until this deletion.
        unsafe { (gl.delete_program)(program) };
        return Err(format!("could not link Flutter scanout-copy shader: {log}").into());
    }
    // SAFETY: the name is NUL-terminated and the linked program is live.
    let source_uniform = unsafe { (gl.get_uniform_location)(program, c"source_texture".as_ptr()) };
    if source_uniform < 0 {
        // SAFETY: the linked program remains live until this deletion.
        unsafe { (gl.delete_program)(program) };
        return Err("Flutter scanout-copy shader omitted its source sampler".into());
    }
    Ok(ShaderBlit {
        program,
        source_uniform,
    })
}

fn compile_shader(gl: GlApi, kind: u32, source: &[u8]) -> Result<u32, Box<dyn Error>> {
    debug_assert_eq!(source.last(), Some(&0));
    // SAFETY: a compatible GLES context is current, `source` is NUL-terminated,
    // and the driver copies it during this call.
    let shader = unsafe {
        let shader = (gl.create_shader)(kind);
        if shader != 0 {
            let source = source.as_ptr().cast::<c_char>();
            (gl.shader_source)(shader, 1, &source, ptr::null());
            (gl.compile_shader)(shader);
        }
        shader
    };
    if shader == 0 {
        return Err("could not allocate Flutter scanout-copy shader".into());
    }
    let mut compiled = 0;
    // SAFETY: `shader` is live in the current GLES context.
    unsafe { (gl.get_shader_iv)(shader, gl::COMPILE_STATUS, &mut compiled) };
    if compiled == 0 {
        let log = shader_info_log(gl, shader);
        // SAFETY: the failed shader remains live until this deletion.
        unsafe { (gl.delete_shader)(shader) };
        return Err(format!("could not compile Flutter scanout-copy shader: {log}").into());
    }
    Ok(shader)
}

fn shader_info_log(gl: GlApi, shader: u32) -> String {
    let mut length = 0;
    // SAFETY: `shader` is live in the current GLES context.
    unsafe { (gl.get_shader_iv)(shader, gl::INFO_LOG_LENGTH, &mut length) };
    gl_info_log(length, |capacity, written, bytes| unsafe {
        // SAFETY: the output buffer contains `capacity` writable bytes.
        (gl.get_shader_info_log)(shader, capacity, written, bytes)
    })
}

fn program_info_log(gl: GlApi, program: u32) -> String {
    let mut length = 0;
    // SAFETY: `program` is live in the current GLES context.
    unsafe { (gl.get_program_iv)(program, gl::INFO_LOG_LENGTH, &mut length) };
    gl_info_log(length, |capacity, written, bytes| unsafe {
        // SAFETY: the output buffer contains `capacity` writable bytes.
        (gl.get_program_info_log)(program, capacity, written, bytes)
    })
}

fn gl_info_log(length: i32, read: impl FnOnce(i32, *mut i32, *mut c_char)) -> String {
    let capacity = usize::try_from(length.max(1)).unwrap_or(1).min(64 * 1024);
    let mut bytes = vec![0u8; capacity];
    let mut written = 0;
    read(
        i32::try_from(capacity).unwrap_or(i32::MAX),
        &mut written,
        bytes.as_mut_ptr().cast(),
    );
    let written = usize::try_from(written.max(0))
        .unwrap_or(0)
        .min(bytes.len());
    bytes.truncate(written);
    String::from_utf8_lossy(&bytes)
        .trim_end_matches('\0')
        .to_owned()
}

fn destroy_shader_blit(gl: GlApi, shader_blit: &mut Option<ShaderBlit>) {
    let Some(shader_blit) = shader_blit.take() else {
        return;
    };
    // SAFETY: cleanup runs with the owning GLES context current and this
    // program was created exactly once by `create_shader_blit`.
    unsafe { (gl.delete_program)(shader_blit.program) };
}

fn destroy_targets(gl: GlApi, display: &EGLDisplayHandle, targets: &mut Vec<GlTarget>) {
    for target in targets.drain(..).rev() {
        // SAFETY: cleanup runs with the owning shared EGL context current;
        // every object/image was created exactly once by this handler.
        unsafe {
            if target.render_framebuffer != 0
                && target.render_framebuffer != target.scanout_framebuffer
            {
                (gl.delete_framebuffers)(1, &target.render_framebuffer);
            }
            if target.render_texture != 0 {
                (gl.delete_textures)(1, &target.render_texture);
            }
            if target.scanout_framebuffer != 0 {
                (gl.delete_framebuffers)(1, &target.scanout_framebuffer);
            }
            if target.scanout_texture != 0 {
                (gl.delete_textures)(1, &target.scanout_texture);
            }
            if target.render_image != 0 {
                egl_ffi::egl::DestroyImageKHR(
                    display.handle,
                    target.render_image as egl_ffi::egl::types::EGLImageKHR,
                );
            }
            if target.scanout_image != 0 {
                egl_ffi::egl::DestroyImageKHR(
                    display.handle,
                    target.scanout_image as egl_ffi::egl::types::EGLImageKHR,
                );
            }
        }
    }
}

fn destroy_depth_stencil(gl: GlApi, renderbuffer: &mut u32) {
    if *renderbuffer == 0 {
        return;
    }
    // SAFETY: cleanup runs with the owning shared GLES context current and
    // this renderbuffer was created exactly once by the handler.
    unsafe { (gl.delete_renderbuffers)(1, renderbuffer) };
    *renderbuffer = 0;
}

fn destroy_depth_stencils(gl: GlApi, renderbuffers: &mut Vec<u32>) {
    for renderbuffer in renderbuffers.iter_mut() {
        destroy_depth_stencil(gl, renderbuffer);
    }
    renderbuffers.clear();
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
    pending_idle_dpms_timeout: Option<Option<Duration>>,
    pending_dpms_off: bool,
    pending_vm_service_uri: Option<String>,
    generation: u64,
    scheduled_tasks: BinaryHeap<QueuedPlatformTask>,
    platform_task_scratch: Vec<PendingPlatformTask>,
    next_platform_task_order: u64,
    registered_external_textures: HashSet<i64>,
    scene_texture_ids: HashSet<i64>,
    render_outputs: Vec<RuntimeRenderOutput>,
    render_output_configuration: Vec<RenderOutput>,
    output_rotation_animation: Option<OutputRotationAnimation>,
    pending_output_geometry: Option<PendingOutputGeometry>,
    render_output_ffi_scratch: RenderOutputFfiScratch,
    texture_output_membership: HashMap<i64, Vec<OutputId>>,
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
    frame_interval: Duration,
    kms_frame_clock_enabled: bool,
    outputs_visible: Option<bool>,
    published_text_input_state: Option<(bool, bool, bool, u32, u32, u64)>,
    frame_ready_observed: bool,
    last_pointer_timestamp_micros: usize,
}

impl FlutterRuntime {
    #[allow(clippy::too_many_arguments)]
    pub fn start<'a>(
        shared_context: &EGLContext,
        output_pools: impl IntoIterator<Item = OutputRenderTargetPool<'a>>,
        snapshot: &TopologySnapshot,
        atlas: &AtlasPlan,
        refresh_millihz: u32,
        offscreen_blit: bool,
        factory: &FlutterRuntimeFactory,
        events: Sender<RuntimeEvent>,
        authentication: Arc<super::authentication::AuthenticationController>,
        clipboard: super::clipboard::ClipboardManager,
        work_area: super::options::WorkAreaOptions,
        generation: u64,
        wayland_display: Option<OsString>,
        x11_display: Option<OsString>,
        output_control_socket: Option<OsString>,
    ) -> Result<Self, Box<dyn Error>> {
        let wire = WireBridge::new(snapshot, atlas, work_area)?;
        let render_outputs = atlas
            .render_outputs(snapshot)
            .ok_or("Flutter render outputs do not match the topology snapshot")?;
        let runtime_render_outputs = render_outputs
            .iter()
            .map(|output| {
                let atlas_output = atlas
                    .outputs
                    .iter()
                    .find(|candidate| candidate.id == output.output_id)
                    .expect("validated render output is absent from its atlas");
                let snapshot_output = snapshot
                    .outputs
                    .iter()
                    .find(|candidate| candidate.id == output.output_id)
                    .expect("validated render output is absent from its topology");
                RuntimeRenderOutput {
                    output_id: output.output_id,
                    render_view_id: output.render_view_id,
                    configuration_generation: output.configuration_generation,
                    target_size: output.target_size,
                    transform: snapshot_output.transform,
                    logical_x: atlas_output.logical_rect.x - atlas.logical_origin.0,
                    logical_y: atlas_output.logical_rect.y - atlas.logical_origin.1,
                    logical_width: atlas_output.logical_rect.width,
                    logical_height: atlas_output.logical_rect.height,
                }
            })
            .collect::<Vec<_>>();
        let render_context = egl_context::create_shared_context("Flutter raster", shared_context)?;
        let resource_context =
            egl_context::create_shared_context("Flutter resource", shared_context)?;
        let handler = FlutterGlHandler::new(
            render_context,
            resource_context,
            output_pools,
            atlas.pixel_size,
            factory.project.renderer_backend,
            offscreen_blit,
            events,
            generation,
        )?;
        let host = EngineHost::start_with_library_and_priority_setter(
            &factory.project,
            handler.clone(),
            Arc::clone(&factory.library),
            Some(super::cpu_scheduling::set_flutter_thread_priority),
        )?;
        if let Some(locale) = locale_from_environment(|name| std::env::var(name).ok()) {
            host.engine()
                .update_locales(std::slice::from_ref(&locale))?;
        }
        let refresh_hz = f64::from(refresh_millihz) / 1_000.0;
        let device_pixel_ratio = f64::from(atlas.engine_scale_120) / f64::from(SCALE_BASE);
        host.engine().notify_displays(
            sys::FlutterEngineDisplaysUpdateType_kFlutterEngineDisplaysUpdateTypeStartup,
            &[sys::FlutterEngineDisplay {
                struct_size: mem::size_of::<sys::FlutterEngineDisplay>(),
                display_id: 0,
                single_display: true,
                refresh_rate: refresh_hz,
                width: atlas.pixel_size.width as usize,
                height: atlas.pixel_size.height as usize,
                device_pixel_ratio,
            }],
        )?;
        host.engine()
            .send_window_metrics(&sys::FlutterWindowMetricsEvent {
                struct_size: mem::size_of::<sys::FlutterWindowMetricsEvent>(),
                width: atlas.pixel_size.width as usize,
                height: atlas.pixel_size.height as usize,
                pixel_ratio: device_pixel_ratio,
                display_id: 0,
                view_id: 0,
                ..sys::FlutterWindowMetricsEvent::default()
            })?;
        let render_outputs = render_outputs
            .into_iter()
            .map(|output| RenderOutput {
                render_view_id: output.render_view_id.get(),
                configuration_generation: output.configuration_generation,
                source_physical_x: f64::from(output.source_rect.x),
                source_physical_y: f64::from(output.source_rect.y),
                source_physical_width: f64::from(output.source_rect.width),
                source_physical_height: f64::from(output.source_rect.height),
                target_width: output.target_size.width as usize,
                target_height: output.target_size.height as usize,
                scale_120: output.scale_120,
                source_to_target_transform: RenderOutputTransform {
                    scale_x: output.source_to_target_transform.scale_x,
                    skew_x: output.source_to_target_transform.skew_x,
                    translate_x: output.source_to_target_transform.translate_x,
                    skew_y: output.source_to_target_transform.skew_y,
                    scale_y: output.source_to_target_transform.scale_y,
                    translate_y: output.source_to_target_transform.translate_y,
                },
            })
            .collect::<Vec<_>>();
        host.engine().set_render_outputs(&render_outputs)?;
        let render_output_count = render_outputs.len();
        let frame_interval = Duration::from_secs_f64(1.0 / refresh_hz.max(1.0));
        info!(
            bundle = %factory.bundle.display(),
            refresh_hz,
            width = atlas.pixel_size.width,
            height = atlas.pixel_size.height,
            device_pixel_ratio,
            native_fence = true,
            resource_cache_max_mib =
                factory.project.resource_cache_max_bytes_threshold / (1024 * 1024),
            output_targets = render_outputs.len(),
            "started Rust Flutter embedder with native physical-output raster targets"
        );
        Ok(Self {
            host: Some(host),
            handler,
            wire,
            text_input: text_input::TextInputPlugin::default(),
            platform: platform::PlatformPlugin::new(clipboard.clone()),
            mouse_cursor: mouse_cursor::MouseCursorPlugin::default(),
            clipboard,
            published_clipboard_revision: 0,
            system_commands: system_command::SystemCommandHandler::new(
                wayland_display,
                x11_display,
                output_control_socket,
            ),
            authentication,
            pending_audio_requests: VecDeque::with_capacity(16),
            pending_brightness_requests: VecDeque::with_capacity(16),
            pending_ui_development_commands: VecDeque::with_capacity(8),
            pending_idle_dpms_timeout: None,
            pending_dpms_off: false,
            pending_vm_service_uri: None,
            generation,
            scheduled_tasks: BinaryHeap::with_capacity(INITIAL_PLATFORM_TASK_BATCH_CAPACITY),
            platform_task_scratch: Vec::with_capacity(INITIAL_PLATFORM_TASK_BATCH_CAPACITY),
            next_platform_task_order: 0,
            registered_external_textures: HashSet::new(),
            scene_texture_ids: HashSet::new(),
            render_outputs: runtime_render_outputs,
            render_output_configuration: render_outputs,
            output_rotation_animation: None,
            pending_output_geometry: None,
            render_output_ffi_scratch: RenderOutputFfiScratch::with_capacity(render_output_count),
            texture_output_membership: HashMap::new(),
            pending_output_updates: BTreeMap::new(),
            changed_texture_scratch: Vec::new(),
            render_view_scratch: Vec::with_capacity(render_output_count),
            render_texture_scratch: Vec::new(),
            screenshot_texture_id: None,
            pending_screenshot_frame: None,
            scene_texture_id_scratch: Vec::new(),
            window_close_texture_leases: WindowCloseTextureLeases::default(),
            pending_frame_texture_ids: Vec::new(),
            pointer_event_scratch: Vec::with_capacity(64),
            key_event_scratch: Vec::with_capacity(160),
            frame_interval,
            kms_frame_clock_enabled: false,
            outputs_visible: None,
            published_text_input_state: None,
            frame_ready_observed: false,
            last_pointer_timestamp_micros: 0,
        })
    }

    /// Delivers one bounded input batch and leaves the rest queued in order.
    /// Motion is already latest-only within each semantic tail; limiting the
    /// batch keeps an input flood from monopolizing the compositor between
    /// physical display deadlines without dropping transitions.
    pub fn process_input_batch(&mut self, input: &mut InputQueue) -> Result<bool, Box<dyn Error>> {
        if input.events.is_empty() {
            return Ok(false);
        }
        let engine_now = usize::try_from(self.host().engine().current_time_nanos() / 1_000)
            .unwrap_or(usize::MAX);
        let mut timestamp = engine_now.max(self.last_pointer_timestamp_micros.saturating_add(1));
        // The engine consumes this slice synchronously. Reuse its backing
        // allocation because libinput commonly wakes us once per pointer
        // sample, which otherwise causes one allocator round-trip per event.
        let mut pointer_events = mem::take(&mut self.pointer_event_scratch);
        pointer_events.clear();
        pointer_events.reserve(
            input
                .events
                .len()
                .min(MAX_INPUT_EVENTS_PER_COMPOSITOR_ITERATION),
        );
        let mut key_message = mem::take(&mut self.key_event_scratch);
        for _ in 0..MAX_INPUT_EVENTS_PER_COMPOSITOR_ITERATION {
            let Some(event) = input.events.pop_front() else {
                break;
            };
            match event {
                InputRecord::Pointer(event) => {
                    pointer_events.push(sys::FlutterPointerEvent {
                        struct_size: mem::size_of::<sys::FlutterPointerEvent>(),
                        phase: event.phase,
                        timestamp,
                        x: event.x,
                        y: event.y,
                        device: event.device,
                        signal_kind: event.signal_kind,
                        scroll_delta_x: event.scroll_x,
                        scroll_delta_y: event.scroll_y,
                        device_kind: event.device_kind,
                        buttons: event.buttons,
                        view_id: 0,
                        ..sys::FlutterPointerEvent::default()
                    });
                    self.last_pointer_timestamp_micros = timestamp;
                    timestamp = timestamp.saturating_add(1);
                }
                InputRecord::Keyboard(event) => {
                    self.flush_pointer_events(&mut pointer_events)?;
                    self.send_flutter_keyboard_record(event, &mut key_message)?;
                }
            }
        }
        self.flush_pointer_events(&mut pointer_events)?;
        self.pointer_event_scratch = pointer_events;
        self.key_event_scratch = key_message;
        Ok(!input.events.is_empty())
    }

    /// Retires raster-completion wakeups before ordinary Flutter messages.
    /// The raster thread publishes the completed target before sending this
    /// event, so observing it here makes that target available to the KMS lane
    /// without running platform tasks, settings, or other callback traffic.
    pub fn observe_frame_ready_events(&mut self, events: &mut Vec<RuntimeEvent>) {
        let generation = self.generation;
        let mut observed = false;
        events.retain(|event| match event {
            RuntimeEvent::FrameReady {
                generation: event_generation,
            } if *event_generation == generation => {
                observed = true;
                false
            }
            _ => true,
        });
        if observed {
            self.handler.acknowledge_frame_ready();
            self.frame_ready_observed = true;
        }
    }

    fn send_flutter_keyboard_record(
        &mut self,
        event: KeyboardRecord,
        key_message: &mut Vec<u8>,
    ) -> Result<(), Box<dyn Error>> {
        encode_key_event(event, key_message);
        self.host()
            .engine()
            .send_platform_message(FLUTTER_KEY_EVENT_CHANNEL, key_message)?;
        if event.pressed
            && !(event.unicode != 0 && event.modifiers & (GLFW_MOD_CONTROL | GLFW_MOD_ALT) != 0)
        {
            let engine = self
                .host
                .as_ref()
                .expect("Flutter runtime is shutting down")
                .engine();
            let text_messages = self.text_input.on_key_pressed(event.keycode, event.unicode);
            for message in text_messages {
                engine.send_platform_message(text_input::CHANNEL, message)?;
            }
        }
        Ok(())
    }

    fn flush_pointer_events(
        &self,
        events: &mut Vec<sys::FlutterPointerEvent>,
    ) -> Result<(), EngineError> {
        if !events.is_empty() {
            self.host().engine().send_pointer_events(events)?;
            events.clear();
        }
        Ok(())
    }

    pub fn process_events(
        &mut self,
        events: impl IntoIterator<Item = RuntimeEvent>,
    ) -> Result<(), Box<dyn Error>> {
        for event in events {
            match event {
                RuntimeEvent::PlatformTasksReady { generation }
                    if generation == self.generation =>
                {
                    self.receive_platform_tasks()?;
                }
                RuntimeEvent::Engine {
                    generation,
                    event: EngineEvent::Vsync(baton),
                } if generation == self.generation => {
                    if !self.kms_frame_clock_enabled {
                        if !self.handler.try_request_frame() {
                            return Err(
                                "Flutter requested a timed vsync while its producer was busy"
                                    .into(),
                            );
                        }
                        self.collect_external_texture_updates();
                        if let Err(error) = self.publish_external_texture_transaction() {
                            self.handler.cancel_requested_frame();
                            return Err(error);
                        }
                        if let Err(error) = self
                            .host()
                            .engine()
                            .on_vsync_after(baton, self.frame_interval)
                        {
                            self.handler.cancel_requested_frame();
                            return Err(error.into());
                        }
                        self.handler.complete_vsync(baton);
                    }
                }
                RuntimeEvent::Engine {
                    generation,
                    event: EngineEvent::PlatformMessage(message),
                } if generation == self.generation => {
                    self.handle_platform_message(message)?;
                }
                RuntimeEvent::FrameReady { generation } if generation == self.generation => {
                    self.handler.acknowledge_frame_ready();
                    self.frame_ready_observed = true;
                }
                RuntimeEvent::QueueOverflow { generation, queue }
                    if generation == self.generation =>
                {
                    return Err(format!("Flutter {queue} queue exceeded its safety limit").into());
                }
                RuntimeEvent::FatalRender { generation, reason }
                    if generation == self.generation =>
                {
                    return Err(reason.into());
                }
                RuntimeEvent::VmServiceUri { generation, uri } if generation == self.generation => {
                    self.pending_vm_service_uri = Some(uri);
                }
                RuntimeEvent::Engine { .. }
                | RuntimeEvent::PlatformTasksReady { .. }
                | RuntimeEvent::QueueOverflow { .. }
                | RuntimeEvent::FatalRender { .. }
                | RuntimeEvent::VmServiceUri { .. }
                | RuntimeEvent::FrameReady { .. }
                | RuntimeEvent::SampledBuffersReady { .. } => {}
            }
        }
        self.run_due_tasks()?;
        self.expire_window_close_texture_leases()?;
        self.publish_authentication_events()
    }

    fn publish_authentication_events(&mut self) -> Result<(), Box<dyn Error>> {
        while let Some(event) = self.authentication.try_event() {
            self.host()
                .engine()
                .send_platform_message(super::authentication::STATE_CHANNEL, &event.encode())?;
        }
        Ok(())
    }

    fn receive_platform_tasks(&mut self) -> Result<(), Box<dyn Error>> {
        self.handler
            .take_platform_tasks(&mut self.platform_task_scratch);
        for PendingPlatformTask { task, permit } in self.platform_task_scratch.drain(..) {
            let order = self.next_platform_task_order;
            self.next_platform_task_order = order
                .checked_add(1)
                .ok_or("Flutter platform task ordering sequence exhausted")?;
            self.scheduled_tasks.push(QueuedPlatformTask {
                task,
                permit,
                order,
            });
        }
        Ok(())
    }

    pub fn next_dispatch_timeout(&self) -> Duration {
        if self.scheduled_tasks.is_empty() {
            return PLATFORM_TASK_MAX_DISPATCH_TIMEOUT;
        }
        let now = self.host().engine().current_time_nanos();
        platform_task_dispatch_timeout(&self.scheduled_tasks, now)
    }

    pub fn take_ready_frame(
        &mut self,
        output_available: impl FnMut(OutputId) -> bool,
    ) -> Option<ReadyOutputFrame> {
        if !self.frame_ready_observed {
            return None;
        }
        let ready = self.handler.take_ready_frame(output_available);
        self.frame_ready_observed = self.handler.has_ready_frames();
        ready
    }

    pub fn enable_kms_frame_clock(&mut self) {
        self.kms_frame_clock_enabled = true;
    }

    /// Mirrors physical desktop visibility into Flutter's standard lifecycle.
    ///
    /// A desktop whose outputs are all powered off is equivalent to a hidden
    /// desktop window: the framework retains widget state and timers while
    /// disabling frame production until visibility is restored.
    pub fn set_outputs_visible(&mut self, visible: bool) -> Result<(), Box<dyn Error>> {
        if self.outputs_visible == Some(visible) {
            return Ok(());
        }
        let state = if visible {
            FLUTTER_LIFECYCLE_RESUMED
        } else {
            FLUTTER_LIFECYCLE_HIDDEN
        };
        self.host()
            .engine()
            .send_platform_message(FLUTTER_LIFECYCLE_CHANNEL, state)?;
        self.outputs_visible = Some(visible);
        info!(
            visible,
            lifecycle = std::str::from_utf8(state).unwrap_or("unknown"),
            "synchronized Flutter desktop visibility"
        );
        Ok(())
    }

    /// Installs new logical geometry while retaining the engine, EGL contexts
    /// and native output pools. This path is valid only when connector IDs and
    /// native target extents are unchanged, as is the case for compositor-side
    /// rotation.
    pub fn reconfigure_output_geometry(
        &mut self,
        snapshot: &TopologySnapshot,
        atlas: &AtlasPlan,
        transition: OutputGeometryTransition,
    ) -> Result<(), Box<dyn Error>> {
        let plans = atlas
            .render_outputs(snapshot)
            .ok_or("Flutter render outputs do not match the updated topology")?;
        if plans.len() != self.render_outputs.len() {
            return Err("transform-only topology changed the physical output set".into());
        }

        let mut ffi_outputs = Vec::with_capacity(plans.len());
        let mut runtime_outputs = Vec::with_capacity(plans.len());
        for plan in plans {
            let resident = self
                .render_outputs
                .iter()
                .find(|output| output.output_id == plan.output_id)
                .ok_or("updated topology has no resident Flutter output")?;
            let atlas_output = atlas
                .outputs
                .iter()
                .find(|output| output.id == plan.output_id)
                .ok_or("updated Flutter output is absent from its atlas")?;
            let snapshot_output = snapshot
                .outputs
                .iter()
                .find(|output| output.id == plan.output_id)
                .ok_or("updated Flutter output is absent from its topology")?;
            if resident.render_view_id != plan.render_view_id
                || resident.target_size != plan.target_size
            {
                return Err("updated topology changed a resident physical render target".into());
            }
            ffi_outputs.push(RenderOutput {
                render_view_id: plan.render_view_id.get(),
                // Pool identity is structural. A logical projection update
                // must continue to match frames to the resident pool.
                configuration_generation: resident.configuration_generation,
                source_physical_x: f64::from(plan.source_rect.x),
                source_physical_y: f64::from(plan.source_rect.y),
                source_physical_width: f64::from(plan.source_rect.width),
                source_physical_height: f64::from(plan.source_rect.height),
                target_width: plan.target_size.width as usize,
                target_height: plan.target_size.height as usize,
                scale_120: plan.scale_120,
                source_to_target_transform: RenderOutputTransform {
                    scale_x: plan.source_to_target_transform.scale_x,
                    skew_x: plan.source_to_target_transform.skew_x,
                    translate_x: plan.source_to_target_transform.translate_x,
                    skew_y: plan.source_to_target_transform.skew_y,
                    scale_y: plan.source_to_target_transform.scale_y,
                    translate_y: plan.source_to_target_transform.translate_y,
                },
            });
            runtime_outputs.push(RuntimeRenderOutput {
                output_id: plan.output_id,
                render_view_id: plan.render_view_id,
                configuration_generation: resident.configuration_generation,
                target_size: resident.target_size,
                transform: snapshot_output.transform,
                logical_x: atlas_output.logical_rect.x - atlas.logical_origin.0,
                logical_y: atlas_output.logical_rect.y - atlas.logical_origin.1,
                logical_width: atlas_output.logical_rect.width,
                logical_height: atlas_output.logical_rect.height,
            });
        }

        let host = self
            .host
            .as_ref()
            .ok_or("Flutter runtime is shutting down")?;
        let mut rotation_animation = (transition == OutputGeometryTransition::AnimatedRotation)
            .then(|| {
                OutputRotationAnimation::new(
                    &self.render_outputs,
                    &self.render_output_configuration,
                    &runtime_outputs,
                    &ffi_outputs,
                    Instant::now(),
                )
            })
            .flatten();
        if let Some(animation) = rotation_animation.as_mut() {
            let (initial_outputs, sample) = animation.sample(animation.started_at);
            debug_assert!(!sample.complete);
            debug_assert!(!sample.geometry_resize_due);
            host.engine()
                .set_render_outputs_reusing(initial_outputs, &mut self.render_output_ffi_scratch)?;
            self.output_rotation_animation = rotation_animation;
            self.pending_output_geometry = Some(PendingOutputGeometry {
                snapshot: snapshot.clone(),
                atlas: atlas.clone(),
                ffi_outputs,
                runtime_outputs,
            });
            return Ok(());
        }

        host.engine()
            .set_render_outputs_reusing(&ffi_outputs, &mut self.render_output_ffi_scratch)?;
        self.output_rotation_animation = None;
        self.pending_output_geometry = None;
        self.publish_output_geometry(snapshot, atlas, ffi_outputs, runtime_outputs)
    }

    fn publish_output_geometry(
        &mut self,
        snapshot: &TopologySnapshot,
        atlas: &AtlasPlan,
        ffi_outputs: Vec<RenderOutput>,
        runtime_outputs: Vec<RuntimeRenderOutput>,
    ) -> Result<(), Box<dyn Error>> {
        let host = self
            .host
            .as_ref()
            .ok_or("Flutter runtime is shutting down")?;
        host.engine()
            .send_window_metrics(&sys::FlutterWindowMetricsEvent {
                struct_size: mem::size_of::<sys::FlutterWindowMetricsEvent>(),
                width: atlas.pixel_size.width as usize,
                height: atlas.pixel_size.height as usize,
                pixel_ratio: f64::from(atlas.engine_scale_120) / f64::from(SCALE_BASE),
                display_id: 0,
                view_id: 0,
                ..sys::FlutterWindowMetricsEvent::default()
            })?;
        let layout_update = self.wire.update_topology(snapshot, atlas)?;
        host.engine()
            .send_platform_message(wire::TO_FLUTTER_CHANNEL, layout_update)?;

        self.render_output_configuration = ffi_outputs;
        self.render_outputs = runtime_outputs;
        self.texture_output_membership.clear();
        for output in &self.render_outputs {
            self.pending_output_updates
                .entry(output.output_id)
                .or_default()
                .extend(self.scene_texture_ids.iter().copied());
        }
        Ok(())
    }

    pub fn output_rotation_animation_active(&self) -> bool {
        self.output_rotation_animation.is_some()
    }

    /// Advances only the synthetic output projection. The engine applies this
    /// to its retained layer tree, so the Dart scene, external textures, EGL
    /// targets and native scanout buffers remain untouched between samples.
    pub fn advance_output_rotation_animation(
        &mut self,
        now: Instant,
    ) -> Result<OutputRotationAdvance, Box<dyn Error>> {
        let Some(animation) = self.output_rotation_animation.as_mut() else {
            return Ok(OutputRotationAdvance::default());
        };
        let (outputs, sample) = animation.sample(now);
        self.host
            .as_ref()
            .ok_or("Flutter runtime is shutting down")?
            .engine()
            .set_render_outputs_reusing(outputs, &mut self.render_output_ffi_scratch)?;
        if sample.geometry_resize_due {
            let pending = self
                .pending_output_geometry
                .take()
                .ok_or("output rotation reached its resize point without pending geometry")?;
            self.publish_output_geometry(
                &pending.snapshot,
                &pending.atlas,
                pending.ffi_outputs,
                pending.runtime_outputs,
            )?;
        }
        if sample.complete {
            if self.pending_output_geometry.is_some() {
                return Err("output rotation completed before publishing pending geometry".into());
            }
            self.output_rotation_animation = None;
        }
        Ok(OutputRotationAdvance {
            advanced: true,
            geometry_published: sample.geometry_resize_due,
        })
    }

    pub fn publish_output(&self, output: &ReadyOutputFrame) -> Result<(), Box<dyn Error>> {
        self.handler.publish_output(output).map_err(Into::into)
    }

    pub fn release_output(&self, output: OutputId, index: usize) -> Result<(), Box<dyn Error>> {
        self.handler
            .release_output(output, index)
            .map_err(Into::into)
    }

    pub fn take_output_updates(&mut self) -> BTreeMap<OutputId, BTreeSet<i64>> {
        mem::take(&mut self.pending_output_updates)
    }

    pub fn recycle_output_updates(&mut self, mut updates: BTreeMap<OutputId, BTreeSet<i64>>) {
        for textures in updates.values_mut() {
            textures.clear();
        }
        updates.clear();
        debug_assert!(self.pending_output_updates.is_empty());
        self.pending_output_updates = updates;
    }

    fn rebuild_texture_output_membership(&mut self, windows: &[wire::WindowDescription]) {
        self.texture_output_membership.clear();
        for window in windows {
            let outputs = self
                .render_outputs
                .iter()
                .filter(|output| {
                    output.intersects(
                        window.geometry_x,
                        window.geometry_y,
                        window.geometry_width,
                        window.geometry_height,
                    )
                })
                .map(|output| output.output_id)
                .collect::<Vec<_>>();
            if outputs.is_empty() {
                continue;
            }
            let mut remember = |texture_id: u64| {
                if let Ok(texture_id) = i64::try_from(texture_id)
                    && texture_id > 0
                {
                    self.texture_output_membership
                        .insert(texture_id, outputs.clone());
                }
            };
            remember(window.texture_id);
            for surface in &window.surfaces {
                remember(surface.texture_id);
            }
        }
    }

    fn stage_changed_textures(&mut self) {
        for texture_id in self.changed_texture_scratch.drain(..) {
            if let Some(outputs) = self.texture_output_membership.get(&texture_id) {
                for output in outputs {
                    self.pending_output_updates
                        .entry(*output)
                        .or_default()
                        .insert(texture_id);
                }
            } else {
                for output in &self.render_outputs {
                    self.pending_output_updates
                        .entry(output.output_id)
                        .or_default()
                        .insert(texture_id);
                }
            }
        }
    }

    pub fn pending_frame(&self) -> PendingFrame {
        // Output authorization is a bounded per-output queue reservation, not
        // a global raster lock. A framework frame can legitimately consume
        // OnVsync without producing a raster task, so expire an unclaimed
        // reservation after two of that output's own intervals.
        let expired = self.handler.expire_output_authorizations(Instant::now());
        if expired > 0 {
            debug!(
                expired,
                "released output render authorizations which produced no raster task"
            );
        }
        PendingFrame {
            flutter_requested: self.handler.has_pending_vsync(),
        }
    }

    pub fn output_target_available(&self, output: OutputId) -> bool {
        self.handler.output_target_available(output)
    }

    pub fn arm_screenshot_frame(
        &mut self,
        output: OutputId,
        request_id: u64,
    ) -> Result<(), Box<dyn Error>> {
        if request_id == 0 || self.pending_screenshot_frame.is_some() {
            return Err("a screenshot frame is already armed".into());
        }
        self.pending_screenshot_frame = Some((output, request_id));
        Ok(())
    }

    pub fn cancel_screenshot_frame(&mut self, request_id: u64) {
        if self
            .pending_screenshot_frame
            .is_some_and(|(_, pending)| pending == request_id)
        {
            self.pending_screenshot_frame = None;
        }
        self.handler.cancel_screenshot_frame(request_id);
    }

    fn collect_external_texture_updates(&mut self) {
        self.handler
            .advance_all_external_texture_sources(&mut self.pending_frame_texture_ids);
        self.pending_frame_texture_ids.sort_unstable();
        self.pending_frame_texture_ids.dedup();
    }

    fn publish_external_texture_transaction(&mut self) -> Result<bool, Box<dyn Error>> {
        if self.pending_frame_texture_ids.is_empty() {
            return Ok(false);
        }
        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        engine.schedule_frame_for_external_textures(&self.pending_frame_texture_ids)?;
        self.pending_frame_texture_ids.clear();
        Ok(true)
    }

    /// Execute exactly the output work authorized by the display clocks.
    pub fn render_authorized_outputs(
        &mut self,
        requests: &[OutputFrameRequest],
        texture_ids: impl IntoIterator<Item = i64>,
        flutter_output: Option<OutputId>,
    ) -> Result<bool, Box<dyn Error>> {
        if !self.kms_frame_clock_enabled {
            return Err("the KMS Flutter frame clock is not enabled".into());
        }
        if requests.is_empty() {
            return Ok(false);
        }

        self.handler
            .authorize_outputs(requests, &mut self.render_view_scratch);
        if self.render_view_scratch.is_empty() {
            return Ok(false);
        }

        let flutter_tick = flutter_output.and_then(|output_id| {
            let render_view_id = self
                .render_outputs
                .iter()
                .find(|output| output.output_id == output_id)?
                .render_view_id
                .get();
            self.render_view_scratch
                .contains(&render_view_id)
                .then(|| {
                    requests
                        .iter()
                        .find(|request| request.tick.output == output_id)
                        .map(|request| request.tick)
                })
                .flatten()
        });
        self.render_texture_scratch.clear();
        self.render_texture_scratch.extend(texture_ids);
        self.render_texture_scratch.sort_unstable();
        self.render_texture_scratch.dedup();
        self.changed_texture_scratch.clear();
        self.handler.advance_external_texture_sources(
            &self.render_texture_scratch,
            &mut self.changed_texture_scratch,
        );
        self.stage_changed_textures();

        let selected_tick = flutter_tick.unwrap_or_else(|| {
            requests
                .iter()
                .filter(|request| {
                    self.render_outputs
                        .iter()
                        .find(|output| output.output_id == request.tick.output)
                        .is_some_and(|output| {
                            self.render_view_scratch
                                .contains(&output.render_view_id.get())
                        })
                })
                .min_by_key(|request| request.tick.presentation_target)
                .map(|request| request.tick)
                .expect("an authorized render view has an output-timeline request")
        });

        let baton = if flutter_tick.is_some() {
            let (baton, _) = self.handler.take_next_vsync();
            let Some(baton) = baton else {
                self.handler
                    .cancel_output_authorizations(&self.render_view_scratch);
                return Err("a KMS-authorized Flutter frame has no AwaitVSync baton".into());
            };
            Some(baton)
        } else {
            None
        };

        let tagged_screenshot = self.pending_screenshot_frame.and_then(|pending| {
            self.render_outputs
                .iter()
                .find(|output| output.output_id == pending.0)
                .filter(|output| {
                    self.render_view_scratch
                        .contains(&output.render_view_id.get())
                })
                .map(|_| pending)
        });
        if let Some((output, request_id)) = tagged_screenshot {
            if let Err(error) = self
                .handler
                .tag_next_frame_for_screenshot(output, request_id)
            {
                if let Some(baton) = baton {
                    self.handler.restore_vsync(baton);
                }
                self.handler
                    .cancel_output_authorizations(&self.render_view_scratch);
                return Err(error.into());
            }
            self.pending_screenshot_frame = None;
        }

        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let now_nanos = engine.current_time_nanos();
        let observation_delay =
            Instant::now().saturating_duration_since(selected_tick.render_deadline);
        if let Some(audit) = &self.handler.render_audit {
            lock(audit).record_render_authorization(observation_delay);
        }
        let target_after_deadline = selected_tick
            .presentation_target
            .saturating_duration_since(selected_tick.render_deadline);
        let (frame_start_nanos, frame_target_nanos) =
            timeline_vsync_timestamps(now_nanos, observation_delay, target_after_deadline);

        if let Err(error) = engine.render_outputs(
            &self.render_view_scratch,
            &self.render_texture_scratch,
            flutter_tick.is_some(),
            frame_start_nanos,
            frame_target_nanos,
        ) {
            if let Some(baton) = baton {
                self.handler.restore_vsync(baton);
            }
            if let Some((output, request_id)) = tagged_screenshot {
                self.handler.cancel_screenshot_frame(request_id);
                self.pending_screenshot_frame = Some((output, request_id));
            }
            self.handler
                .cancel_output_authorizations(&self.render_view_scratch);
            return Err(error.into());
        }

        if let Some(baton) = baton
            && let Err(error) = engine.on_vsync(baton, frame_start_nanos, frame_target_nanos)
        {
            self.handler.restore_vsync(baton);
            if let Some((output, request_id)) = tagged_screenshot {
                self.handler.cancel_screenshot_frame(request_id);
                self.pending_screenshot_frame = Some((output, request_id));
            }
            self.handler
                .cancel_output_authorizations(&self.render_view_scratch);
            return Err(error.into());
        }
        Ok(baton.is_some())
    }

    pub fn sync_wayland_scene(
        &mut self,
        windows: Vec<wire::WindowDescription>,
        mut frames: Vec<ExternalTextureFrame>,
        restored_window_ids: &BTreeSet<u64>,
    ) -> Result<SyncedWaylandScene, Box<dyn Error>> {
        self.rebuild_texture_output_membership(&windows);
        let mut desired = mem::take(&mut self.scene_texture_ids);
        desired.clear();
        desired.reserve(frames.len());
        for frame in &frames {
            if frame.texture_id <= 0 || !desired.insert(frame.texture_id) {
                return Err("external texture identifiers must be unique and positive".into());
            }
        }

        // Both work collections retain their capacity across client buffer
        // commits; scene synchronization commonly runs at application frame
        // rate even when the window count is unchanged.
        let mut removed = mem::take(&mut self.scene_texture_id_scratch);
        removed.clear();
        removed.reserve(frames.len());
        // Update all sources under one short mutex acquisition. Taking this
        // lock once per surface caused avoidable platform/raster contention
        // for multi-window scenes.
        self.changed_texture_scratch.clear();
        self.handler
            .set_external_texture_sources(frames.drain(..), &mut self.changed_texture_scratch);
        self.stage_changed_textures();
        for texture_id in &desired {
            if self.registered_external_textures.insert(*texture_id) {
                self.host()
                    .engine()
                    .register_external_texture(*texture_id)?;
            }
        }

        // Publish metadata without authorizing a frame. Dart may express its
        // own AwaitVSync demand, while the matching texture sources remain
        // queued until the KMS frame clock collects the complete transaction.
        let (window_snapshot_changed, windows) = {
            let engine = self
                .host
                .as_ref()
                .expect("Flutter runtime is shutting down")
                .engine();
            let (update, recycled_windows) =
                self.wire.update_windows(windows, restored_window_ids)?;
            let changed = if let Some(update) = update {
                engine.send_platform_message(wire::TO_FLUTTER_CHANNEL, update)?;
                true
            } else {
                false
            };
            (changed, recycled_windows)
        };
        if window_snapshot_changed {
            let next_windows = window_texture_map(self.wire.window_descriptions());
            let retired = self
                .window_close_texture_leases
                .publish(next_windows, Instant::now());
            if retired.lease_count > 0 {
                warn!(
                    count = retired.lease_count,
                    limit = MAX_RETAINED_WINDOW_CLOSE_LEASES,
                    "retired old window close-frame leases at the safety limit"
                );
            }
        }
        removed.extend(
            self.registered_external_textures
                .difference(&desired)
                .filter(|texture_id| {
                    self.screenshot_texture_id != Some(**texture_id)
                        && !self
                            .window_close_texture_leases
                            .retains_texture(**texture_id)
                })
                .copied(),
        );
        for texture_id in removed.drain(..) {
            self.host()
                .engine()
                .unregister_external_texture(texture_id)?;
            self.handler.remove_external_texture_source(texture_id);
            self.pending_frame_texture_ids
                .retain(|pending| *pending != texture_id);
            self.registered_external_textures.remove(&texture_id);
        }

        self.scene_texture_ids = desired;
        self.scene_texture_id_scratch = removed;
        Ok(SyncedWaylandScene {
            windows,
            textures: frames,
            window_snapshot_changed,
        })
    }

    /// Replace sources for textures whose published surface layout is
    /// unchanged. Registration and Dart window metadata remain untouched.
    pub fn sync_wayland_buffers(
        &mut self,
        mut frames: Vec<ExternalTextureFrame>,
    ) -> Result<Vec<ExternalTextureFrame>, Box<dyn Error>> {
        let mut texture_ids = mem::take(&mut self.scene_texture_id_scratch);
        texture_ids.clear();
        for frame in &frames {
            if frame.texture_id <= 0
                || !self.scene_texture_ids.contains(&frame.texture_id)
                || texture_ids.contains(&frame.texture_id)
            {
                self.scene_texture_id_scratch = texture_ids;
                return Err(
                    "buffer-only updates must target unique published external textures".into(),
                );
            }
            texture_ids.push(frame.texture_id);
        }

        self.changed_texture_scratch.clear();
        self.handler
            .set_external_texture_sources(frames.drain(..), &mut self.changed_texture_scratch);
        self.stage_changed_textures();
        texture_ids.clear();
        self.scene_texture_id_scratch = texture_ids;
        Ok(frames)
    }

    pub fn synced_window_ids(&self) -> impl Iterator<Item = u64> + '_ {
        self.wire.window_ids()
    }

    pub fn take_input_layout_update(&mut self) -> Option<wire::InputLayoutSnapshot> {
        self.wire.take_input_layout_update()
    }

    pub fn recycle_input_layout(&mut self, layout: wire::InputLayoutSnapshot) {
        self.wire.recycle_input_layout(layout);
    }

    pub fn drain_window_commands(&mut self) -> impl Iterator<Item = wire::WindowCommand> + '_ {
        self.wire.drain_window_commands()
    }

    pub fn drain_keyboard_commands(&mut self) -> impl Iterator<Item = wire::KeyboardCommand> + '_ {
        self.wire.drain_keyboard_commands()
    }

    pub fn take_text_input_state(&mut self) -> Option<(u64, TextInputSnapshot)> {
        self.text_input
            .take_state_change()
            .map(|snapshot| (self.generation, snapshot))
    }

    pub fn dispatch_input_method_to_flutter(
        &mut self,
        generation: u64,
        client_id: i64,
        transaction: &InputMethodTransaction,
    ) -> Result<bool, Box<dyn Error>> {
        if generation != self.generation {
            return Ok(false);
        }
        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let messages = self.text_input.apply_input_method(client_id, transaction);
        let delivered = !messages.is_empty();
        for message in messages {
            engine.send_platform_message(text_input::CHANNEL, message)?;
        }
        Ok(delivered)
    }

    pub fn drain_notification_commands(
        &mut self,
    ) -> impl Iterator<Item = wire::NotificationCommand> + '_ {
        self.wire.drain_notification_commands()
    }

    pub fn drain_settings_commands(&mut self) -> impl Iterator<Item = wire::SettingsCommand> + '_ {
        self.wire.drain_settings_commands()
    }

    pub fn take_work_area_update(&mut self) -> Option<super::options::WorkAreaOptions> {
        self.wire.take_work_area_update()
    }

    pub fn take_logout_requested(&mut self) -> bool {
        self.system_commands.take_logout_requested()
    }

    pub fn take_application_launch(&mut self) -> Option<system_command::PendingApplicationLaunch> {
        self.system_commands.take_application_launch()
    }

    pub fn start_application(
        &mut self,
        launch: system_command::PendingApplicationLaunch,
        activation_token: Option<&str>,
    ) -> Result<(), system_command::DispatchError> {
        self.system_commands
            .start_application(launch, activation_token)
    }

    pub fn start_shortcut_application(
        &mut self,
        arguments: Vec<String>,
        shell: bool,
        activation_token: Option<&str>,
    ) -> Result<(), system_command::DispatchError> {
        self.system_commands
            .start_shortcut_application(arguments, shell, activation_token)
    }

    pub fn take_screenshot_requested(&mut self) -> Option<system_command::ScreenshotRequest> {
        self.system_commands.take_screenshot_requested()
    }

    pub fn take_screenshot_prepared(&mut self) -> Option<std::num::NonZeroU64> {
        self.system_commands.take_screenshot_prepared()
    }

    pub fn take_screenshot_cancelled(&mut self) -> Option<std::num::NonZeroU64> {
        self.system_commands.take_screenshot_cancelled()
    }

    pub fn take_idle_dpms_timeout(&mut self) -> Option<Option<Duration>> {
        self.pending_idle_dpms_timeout.take()
    }

    pub fn take_dpms_off_requested(&mut self) -> bool {
        std::mem::take(&mut self.pending_dpms_off)
    }

    pub fn take_mouse_cursor_request(&mut self) -> Option<&'static str> {
        self.mouse_cursor.take_request()
    }

    pub fn send_window_action(
        &mut self,
        window_id: u64,
        action: wire::WindowAction,
    ) -> Result<(), Box<dyn Error>> {
        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let event = self.wire.encode_window_action(window_id, action)?;
        engine.send_platform_message(wire::TO_FLUTTER_CHANNEL, event)?;
        Ok(())
    }

    pub fn send_window_activated(&mut self, window_id: u64) -> Result<(), Box<dyn Error>> {
        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let event = self.wire.encode_window_activated(window_id)?;
        engine.send_platform_message(wire::TO_FLUTTER_CHANNEL, event)?;
        Ok(())
    }

    pub fn send_window_placement(
        &mut self,
        placement: wire::WindowPlacement,
    ) -> Result<(), Box<dyn Error>> {
        let event = self.wire.encode_window_placement(placement)?;
        self.host()
            .engine()
            .send_platform_message(wire::TO_FLUTTER_CHANNEL, &event)?;
        Ok(())
    }

    pub fn send_shell_action(
        &mut self,
        action: wire::ShellAction,
        monitor_id: Option<i64>,
    ) -> Result<(), Box<dyn Error>> {
        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let event = self.wire.encode_shell_action(action, monitor_id)?;
        engine.send_platform_message(wire::TO_FLUTTER_CHANNEL, event)?;
        Ok(())
    }

    pub fn register_screenshot_texture(
        &mut self,
        dmabuf: Dmabuf,
        revision: u64,
    ) -> Result<i64, Box<dyn Error>> {
        if self.screenshot_texture_id.is_some() {
            return Err("a screenshot texture is already registered".into());
        }
        let texture_id = (1..=i64::MAX)
            .rev()
            .find(|texture_id| !self.registered_external_textures.contains(texture_id))
            .ok_or("Flutter external texture identifiers are exhausted")?;
        self.host().engine().register_external_texture(texture_id)?;
        self.registered_external_textures.insert(texture_id);
        self.changed_texture_scratch.clear();
        self.handler.set_external_texture_sources(
            [ExternalTextureFrame::from_owned_dmabuf(
                texture_id, dmabuf, revision,
            )],
            &mut self.changed_texture_scratch,
        );
        self.stage_changed_textures();
        self.screenshot_texture_id = Some(texture_id);
        Ok(texture_id)
    }

    pub fn unregister_screenshot_texture(&mut self, texture_id: i64) -> Result<(), Box<dyn Error>> {
        if self.screenshot_texture_id != Some(texture_id) {
            return Err("screenshot texture identity does not match the active texture".into());
        }
        self.host()
            .engine()
            .unregister_external_texture(texture_id)?;
        self.handler.remove_external_texture_source(texture_id);
        self.pending_frame_texture_ids
            .retain(|pending| *pending != texture_id);
        self.registered_external_textures.remove(&texture_id);
        self.screenshot_texture_id = None;
        Ok(())
    }

    pub fn send_screenshot_action(
        &mut self,
        action: wire::ShellAction,
        request_id: u64,
        texture_id: Option<i64>,
    ) -> Result<(), Box<dyn Error>> {
        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let event = self
            .wire
            .encode_screenshot_action(action, request_id, texture_id)?;
        engine.send_platform_message(wire::TO_FLUTTER_CHANNEL, event)?;
        Ok(())
    }

    pub fn send_cursor_shape(&mut self, shape: &str) -> Result<(), Box<dyn Error>> {
        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let update = self.wire.encode_cursor_shape(shape)?;
        engine.send_platform_message(wire::TO_FLUTTER_CHANNEL, update)?;
        Ok(())
    }

    pub fn send_cursor_position(&mut self, x: f64, y: f64) -> Result<(), Box<dyn Error>> {
        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let update = self.wire.encode_cursor_position(x, y)?;
        engine.send_platform_message(wire::TO_FLUTTER_CHANNEL, update)?;
        Ok(())
    }

    pub fn publish_text_input_state(
        &mut self,
        active: bool,
        input_panel_visible: bool,
        legacy: bool,
        content_hint: u32,
        content_purpose: u32,
        activation_serial: u64,
    ) -> Result<(), Box<dyn Error>> {
        let state = (
            active,
            input_panel_visible,
            legacy,
            content_hint,
            content_purpose,
            activation_serial,
        );
        if self.published_text_input_state == Some(state) {
            return Ok(());
        }
        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let update = self.wire.encode_text_input_state(
            active,
            input_panel_visible,
            legacy,
            content_hint,
            content_purpose,
        )?;
        engine.send_platform_message(wire::TO_FLUTTER_CHANNEL, update)?;
        self.published_text_input_state = Some(state);
        Ok(())
    }

    pub fn send_notification_event(
        &mut self,
        event: &super::notification_server::NotificationEvent,
    ) -> Result<(), Box<dyn Error>> {
        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let update = self.wire.encode_notification_event(event)?;
        engine.send_platform_message(wire::TO_FLUTTER_CHANNEL, update)?;
        Ok(())
    }

    pub fn send_settings_document_response(
        &mut self,
        request_id: u64,
        revision: u64,
        document: Option<&str>,
        error: Option<&str>,
    ) -> Result<(), Box<dyn Error>> {
        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let response = self
            .wire
            .encode_settings_document_response(request_id, revision, document, error)?;
        engine.send_platform_message(wire::TO_FLUTTER_CHANNEL, response)?;
        Ok(())
    }

    pub fn send_input_device_capabilities_response(
        &mut self,
        request_id: u64,
        revision: u64,
        has_touchpad: bool,
        touchpad: &super::settings::TouchpadSettings,
        error: Option<&str>,
    ) -> Result<(), Box<dyn Error>> {
        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let response = self.wire.encode_input_device_capabilities_response(
            request_id,
            revision,
            has_touchpad,
            touchpad,
            error,
        )?;
        engine.send_platform_message(wire::TO_FLUTTER_CHANNEL, response)?;
        Ok(())
    }

    pub fn send_keyboard_settings_response(
        &mut self,
        request_id: u64,
        revision: u64,
        keyboard: &super::settings::KeyboardSettings,
        display_names: &[String],
        active_layout: usize,
        error: Option<&str>,
    ) -> Result<(), Box<dyn Error>> {
        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let response = self.wire.encode_keyboard_settings_response(
            request_id,
            revision,
            keyboard,
            display_names,
            active_layout,
            error,
        )?;
        engine.send_platform_message(wire::TO_FLUTTER_CHANNEL, response)?;
        Ok(())
    }

    pub fn send_shortcut_configuration_response(
        &mut self,
        request_id: u64,
        revision: u64,
        shortcuts: &[super::native_shortcut::ShortcutBinding],
        supported_inputs: &[super::native_shortcut::ShortcutInputDefinition],
        error: Option<&str>,
    ) -> Result<(), Box<dyn Error>> {
        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let response = self.wire.encode_shortcut_configuration_response(
            request_id,
            revision,
            shortcuts,
            supported_inputs,
            error,
        )?;
        engine.send_platform_message(wire::TO_FLUTTER_CHANNEL, response)?;
        Ok(())
    }

    pub fn send_shortcut_validation_response(
        &mut self,
        request_id: u64,
        revision: u64,
        validation: &super::native_shortcut::ShortcutValidation,
    ) -> Result<(), Box<dyn Error>> {
        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let response = self
            .wire
            .encode_shortcut_validation_response(request_id, revision, validation)?;
        engine.send_platform_message(wire::TO_FLUTTER_CHANNEL, response)?;
        Ok(())
    }

    pub fn send_system_control_event(
        &mut self,
        event: &super::system_controls::SystemControlEvent,
    ) -> Result<(), Box<dyn Error>> {
        match event {
            super::system_controls::SystemControlEvent::AudioLevel {
                level,
                request_serial,
            } => {
                let mut packet = [0u8; 5];
                packet[0] = (level.clamp(0.0, 1.0) * 100.0).round() as u8;
                packet[1..].copy_from_slice(&request_serial.to_le_bytes());
                self.host()
                    .engine()
                    .send_platform_message(AUDIO_STATE_CHANNEL, &packet)?;
            }
            super::system_controls::SystemControlEvent::AudioStreams(streams) => {
                let payload_size = streams.iter().try_fold(size_of::<u32>(), |size, stream| {
                    size.checked_add(8)?.checked_add(stream.name.len())
                });
                let Some(payload_size) = payload_size else {
                    return Err("audio stream-state packet size overflow".into());
                };
                let mut packet = Vec::with_capacity(payload_size);
                packet.extend_from_slice(
                    &u32::try_from(streams.len())
                        .map_err(|_| "too many audio streams for the platform packet")?
                        .to_le_bytes(),
                );
                for stream in streams {
                    let name = stream.name.as_bytes();
                    let name_length = u16::try_from(name.len())
                        .map_err(|_| "audio stream name exceeds the platform packet limit")?;
                    packet.extend_from_slice(&stream.id.to_le_bytes());
                    packet.push(stream.level_percent.min(100));
                    packet.push(u8::from(stream.muted));
                    packet.extend_from_slice(&name_length.to_le_bytes());
                    packet.extend_from_slice(name);
                }
                self.host()
                    .engine()
                    .send_platform_message(AUDIO_STREAMS_STATE_CHANNEL, &packet)?;
            }
            super::system_controls::SystemControlEvent::BrightnessLevel { monitor_id, level } => {
                let mut packet = [0u8; 9];
                packet[..8].copy_from_slice(&monitor_id.to_le_bytes());
                packet[8] = (level.clamp(0.0, 1.0) * 100.0).round() as u8;
                self.host()
                    .engine()
                    .send_platform_message(BRIGHTNESS_STATE_CHANNEL, &packet)?;
            }
        }
        Ok(())
    }

    pub fn drain_audio_requests(
        &mut self,
    ) -> impl Iterator<Item = super::system_controls::AudioRequest> + '_ {
        self.pending_audio_requests.drain(..)
    }

    pub fn drain_brightness_requests(
        &mut self,
    ) -> impl Iterator<Item = super::system_controls::BrightnessRequest> + '_ {
        self.pending_brightness_requests.drain(..)
    }

    pub fn drain_ui_development_commands(
        &mut self,
    ) -> impl Iterator<Item = super::ui_development::UiDevelopmentCommand> + '_ {
        self.pending_ui_development_commands.drain(..)
    }

    pub fn take_vm_service_uri(&mut self) -> Option<String> {
        self.pending_vm_service_uri.take()
    }

    pub fn publish_ui_development_state(&mut self, packet: &[u8]) -> Result<(), Box<dyn Error>> {
        self.host()
            .engine()
            .send_platform_message(super::ui_development::STATE_CHANNEL, packet)?;
        Ok(())
    }

    pub fn authentication(&self) -> Arc<super::authentication::AuthenticationController> {
        Arc::clone(&self.authentication)
    }

    pub fn clipboard(&self) -> super::clipboard::ClipboardManager {
        self.clipboard.clone()
    }

    pub fn publish_clipboard_state(&mut self) -> Result<(), Box<dyn Error>> {
        let revision = self.clipboard.revision();
        if revision == self.published_clipboard_revision {
            return Ok(());
        }
        let packet = self.clipboard.state_packet();
        self.host()
            .engine()
            .send_platform_message(super::clipboard::STATE_CHANNEL, &packet)?;
        self.published_clipboard_revision = revision;
        Ok(())
    }

    fn retire_window_close_textures(
        &mut self,
        texture_ids: impl IntoIterator<Item = i64>,
    ) -> Result<(), Box<dyn Error>> {
        for texture_id in texture_ids {
            if self.scene_texture_ids.contains(&texture_id)
                || self.screenshot_texture_id == Some(texture_id)
                || self.window_close_texture_leases.retains_texture(texture_id)
                || !self.registered_external_textures.contains(&texture_id)
            {
                continue;
            }
            self.host()
                .engine()
                .unregister_external_texture(texture_id)?;
            self.handler.remove_external_texture_source(texture_id);
            self.pending_frame_texture_ids
                .retain(|pending| *pending != texture_id);
            self.registered_external_textures.remove(&texture_id);
        }
        Ok(())
    }

    fn expire_window_close_texture_leases(&mut self) -> Result<(), Box<dyn Error>> {
        let retired = self.window_close_texture_leases.expire(Instant::now());
        if retired.lease_count == 0 {
            return Ok(());
        }
        warn!(
            count = retired.lease_count,
            timeout_ms = WINDOW_CLOSE_LEASE_TIMEOUT.as_millis(),
            "released window close-frame leases after Flutter acknowledgement timeout"
        );
        self.retire_window_close_textures(retired.texture_ids)
    }

    fn run_due_tasks(&mut self) -> Result<(), Box<dyn Error>> {
        if self.scheduled_tasks.is_empty() {
            return Ok(());
        }
        // Evaluate one due-set per calloop turn. Tasks which mature while an
        // earlier task runs are picked up by the next zero-timeout turn; this
        // both bounds clock FFI traffic and gives input/DRM sources a fair
        // dispatch edge between long platform-task bursts.
        let now = self.host().engine().current_time_nanos();
        for _ in 0..MAX_PLATFORM_TASKS_PER_DISPATCH {
            let Some(queued) = take_next_due_platform_task(&mut self.scheduled_tasks, now) else {
                break;
            };
            // Release queue capacity before entering Flutter. Running a task
            // may synchronously cause the engine to post another task.
            let QueuedPlatformTask { task, permit, .. } = queued;
            drop(permit);
            self.host().run_scheduled_task(task)?;
        }
        // If more tasks are already due, next_dispatch_timeout() returns zero
        // and calloop gets another turn. This prevents a timer flood from
        // starving input, DRM/session events or graceful shutdown.
        Ok(())
    }

    fn handle_platform_message(
        &mut self,
        mut message: PlatformMessage,
    ) -> Result<(), Box<dyn Error>> {
        // Authentication can change earlier in this same engine-event batch.
        // Refresh the clipboard gate before serving any synchronous reply so
        // a lock request cannot be followed by one last unredacted read.
        self.clipboard
            .set_locked(self.authentication.security_gate_locked());
        if message.channel.as_bytes() == text_input::CHANNEL.to_bytes() {
            let host = self
                .host
                .as_ref()
                .expect("Flutter runtime is shutting down");
            let response = self.text_input.handle_platform_message(&message.data);
            host.respond(&mut message, response)?;
            return Ok(());
        }
        if message.channel.as_bytes() == platform::CHANNEL.to_bytes() {
            let response = self.platform.handle_platform_message(&message.data);
            self.host().respond(&mut message, &response)?;
            return Ok(());
        }
        if message.channel.as_bytes() == mouse_cursor::CHANNEL.to_bytes() {
            let response = self.mouse_cursor.handle_platform_message(&message.data);
            self.host().respond(&mut message, &response)?;
            return Ok(());
        }
        if message.channel == super::clipboard::CONTROL_CHANNEL {
            let response = self.clipboard.handle_control_packet(&message.data);
            self.host().respond(&mut message, &response)?;
            return Ok(());
        }

        // Release Flutter's request handle before dispatching any
        // asynchronous Denial response. The shell receives request/reply
        // data on its dedicated ordered native-to-Flutter channel.
        self.host().respond(&mut message, &[])?;
        if message.channel.as_bytes() == super::authentication::CHANNEL.to_bytes() {
            let result = self.authentication.handle_packet(&message.data);
            // Authentication responses can contain credentials. The
            // controller has moved them into its scrub-on-drop buffer, so
            // erase the engine-owned copy before releasing this message.
            message.data.fill(0);
            if let Err(error) = result {
                warn!(%error, "rejected Denial authentication request from Flutter");
            }
        } else if message.channel == wire::TO_NATIVE_CHANNEL {
            let host = self
                .host
                .as_ref()
                .expect("Flutter runtime is shutting down");
            match self.wire.handle(&message.data) {
                Ok(Some(response)) => {
                    host.engine()
                        .send_platform_message(wire::TO_FLUTTER_CHANNEL, response)?;
                }
                Ok(None) => {}
                Err(error) => warn!(%error, "rejected Denial wire message from Flutter"),
            }
        } else if message.channel.as_bytes() == system_command::CHANNEL.to_bytes() {
            if self.authentication.security_gate_locked() {
                warn!("rejected Denial system command while the session is locked");
            } else if let Err(error) = self.system_commands.handle(&message.data) {
                warn!(%error, "rejected Denial system command from Flutter");
            }
        } else if message.channel.as_bytes() == AUDIO_CHANNEL.to_bytes() {
            match super::system_controls::decode_audio_request(&message.data) {
                Ok(request) if self.pending_audio_requests.len() < MAX_PENDING_AUDIO_REQUESTS => {
                    self.pending_audio_requests.push_back(request);
                }
                Ok(_) => warn!(
                    limit = MAX_PENDING_AUDIO_REQUESTS,
                    "dropped excess Denial audio request from Flutter"
                ),
                Err(error) => warn!(%error, "rejected Denial audio request from Flutter"),
            }
        } else if message.channel.as_bytes() == BRIGHTNESS_CHANNEL.to_bytes() {
            match super::system_controls::decode_brightness_request(&message.data) {
                Ok(request)
                    if self.pending_brightness_requests.len() < MAX_PENDING_BRIGHTNESS_REQUESTS =>
                {
                    self.pending_brightness_requests.push_back(request);
                }
                Ok(_) => warn!(
                    limit = MAX_PENDING_BRIGHTNESS_REQUESTS,
                    "dropped excess Denial brightness request from Flutter"
                ),
                Err(error) => warn!(%error, "rejected Denial brightness request from Flutter"),
            }
        } else if message.channel.as_bytes() == super::ui_development::CONTROL_CHANNEL.to_bytes() {
            match super::ui_development::decode_control_packet(&message.data) {
                Ok(command)
                    if self.pending_ui_development_commands.len()
                        < MAX_PENDING_UI_DEVELOPMENT_COMMANDS =>
                {
                    self.pending_ui_development_commands.push_back(command);
                }
                Ok(_) => warn!(
                    limit = MAX_PENDING_UI_DEVELOPMENT_COMMANDS,
                    "dropped excess Denial UI development command from Flutter"
                ),
                Err(error) => {
                    warn!(%error, "rejected Denial UI development command from Flutter");
                }
            }
        } else if message.channel.as_bytes() == idle_policy::CHANNEL.to_bytes() {
            match idle_policy::decode_timeout(&message.data) {
                Ok(timeout) => self.pending_idle_dpms_timeout = Some(timeout),
                Err(error) => warn!(%error, "rejected Denial idle policy from Flutter"),
            }
        } else if message.channel.as_bytes() == idle_policy::DISPLAY_POWER_CHANNEL.to_bytes() {
            match idle_policy::decode_display_power_off(&message.data) {
                Ok(()) => self.pending_dpms_off = true,
                Err(error) => warn!(%error, "rejected Denial display-power request from Flutter"),
            }
        } else if message.channel.as_bytes() == WINDOW_CLOSE_COMPLETE_CHANNEL.to_bytes() {
            match decode_window_close_complete(&message.data) {
                Some(window_id) => {
                    let retired = self.window_close_texture_leases.complete(window_id);
                    self.retire_window_close_textures(retired.texture_ids)?;
                }
                None => warn!("rejected malformed window close completion from Flutter"),
            }
        }
        Ok(())
    }

    fn host(&self) -> &EngineHost {
        // shutdown() consumes FlutterRuntime, and shutdown_engine() is only
        // called by that consuming path or Drop. Engine callbacks retain the
        // separate FlutterGlHandler Arc and never call this accessor, so a
        // late callback cannot observe the transient host=None state.
        self.host
            .as_ref()
            .expect("Flutter runtime is shutting down")
    }

    pub fn shutdown(mut self) -> Result<(), EngineError> {
        self.shutdown_engine()
    }

    fn shutdown_engine(&mut self) -> Result<(), EngineError> {
        // No queued task may be run once host shutdown begins. Dropping the
        // permits also releases the producer-side bound before engine joins.
        self.scheduled_tasks.clear();
        let Some(host) = self.host.take() else {
            return Ok(());
        };
        for texture_id in self.registered_external_textures.drain() {
            match host.engine().unregister_external_texture(texture_id) {
                Ok(()) => self.handler.remove_external_texture_source(texture_id),
                Err(error) => {
                    // Keep the source alive until engine shutdown. If that
                    // also fails, EngineHost deliberately retains its
                    // callback Arc and this resource with it.
                    error!(%error, texture_id, "failed to unregister Flutter external texture");
                }
            }
        }
        let pending_batons = self.handler.take_pending_vsync_batons();
        if !pending_batons.is_empty() {
            let now = host.engine().current_time_nanos();
            let interval = u64::try_from(self.frame_interval.as_nanos()).unwrap_or(u64::MAX);
            for baton in &pending_batons {
                if let Err(error) =
                    host.engine()
                        .on_vsync(*baton, now, now.saturating_add(interval))
                {
                    error!(%error, baton, "failed to fulfil Flutter vsync during shutdown");
                }
            }
            debug!(
                count = pending_batons.len(),
                "fulfilled pending Flutter vsync batons before shutdown"
            );
        }
        let result = host.shutdown();
        if result.is_ok() {
            self.handler.destroy_targets();
        } else {
            // The leaked EngineHost owns another Arc to this handler. Do not
            // destroy GL targets or external texture sources that an engine
            // worker may still reach after a failed shutdown.
            error!("retaining Flutter GL resources after failed engine shutdown");
        }
        result
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

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_near(actual: f64, expected: f64) {
        assert!(
            (actual - expected).abs() < 1.0e-9,
            "expected {expected}, got {actual}"
        );
    }

    #[test]
    fn output_rotation_uses_the_shortest_cardinal_path() {
        assert_eq!(
            shortest_rotation_delta(OutputTransform::Normal, OutputTransform::Rotate90),
            1
        );
        assert_eq!(
            shortest_rotation_delta(OutputTransform::Normal, OutputTransform::Rotate270),
            -1
        );
        assert_eq!(
            shortest_rotation_delta(OutputTransform::Rotate270, OutputTransform::Normal),
            1
        );
        assert_eq!(
            shortest_rotation_delta(OutputTransform::Flipped90, OutputTransform::Flipped270),
            2
        );
    }

    #[test]
    fn animated_projection_has_exact_filled_cardinal_endpoints() {
        let target = RenderOutputTransform {
            scale_x: 0.0,
            skew_x: -1.0,
            translate_x: 1920.0,
            skew_y: 1.0,
            scale_y: 0.0,
            translate_y: 0.0,
        };
        let animation = AnimatedOutputRotation {
            frame_index: 0,
            initial_angle: -std::f64::consts::FRAC_PI_2,
            initial_scale_x: 1920.0 / 1080.0,
            initial_scale_y: 1080.0 / 1920.0,
        };

        let initial = animated_rotation_transform(target, 1920.0, 1080.0, animation, 0.0);
        assert_near(initial.scale_x, 1920.0 / 1080.0);
        assert_near(initial.skew_x, 0.0);
        assert_near(initial.translate_x, 0.0);
        assert_near(initial.skew_y, 0.0);
        assert_near(initial.scale_y, 1080.0 / 1920.0);
        assert_near(initial.translate_y, 0.0);

        let final_projection = animated_rotation_transform(target, 1920.0, 1080.0, animation, 1.0);
        assert_eq!(final_projection, target);
    }

    #[test]
    fn output_rotation_defers_canvas_resize_until_the_final_quarter() {
        let output_id = OutputId(1);
        let render_view_id = RenderViewId::for_output(output_id).unwrap();
        let previous_runtime = RuntimeRenderOutput {
            output_id,
            render_view_id,
            configuration_generation: 7,
            target_size: PixelSize::new(1080, 1920),
            transform: OutputTransform::Normal,
            logical_x: 0.0,
            logical_y: 0.0,
            logical_width: 1080.0,
            logical_height: 1920.0,
        };
        let current_runtime = RuntimeRenderOutput {
            transform: OutputTransform::Rotate90,
            logical_width: 1920.0,
            logical_height: 1080.0,
            ..previous_runtime
        };
        let identity = RenderOutputTransform {
            scale_x: 1.0,
            skew_x: 0.0,
            translate_x: 0.0,
            skew_y: 0.0,
            scale_y: 1.0,
            translate_y: 0.0,
        };
        let previous_target = RenderOutput {
            render_view_id: render_view_id.get(),
            configuration_generation: 7,
            source_physical_x: 0.0,
            source_physical_y: 0.0,
            source_physical_width: 1080.0,
            source_physical_height: 1920.0,
            target_width: 1080,
            target_height: 1920,
            scale_120: SCALE_BASE,
            source_to_target_transform: identity,
        };
        let final_transform = RenderOutputTransform {
            scale_x: 0.0,
            skew_x: -1.0,
            translate_x: 1080.0,
            skew_y: 1.0,
            scale_y: 0.0,
            translate_y: 0.0,
        };
        let current_target = RenderOutput {
            source_physical_width: 1920.0,
            source_physical_height: 1080.0,
            source_to_target_transform: final_transform,
            ..previous_target
        };
        let started_at = Instant::now();
        let mut animation = OutputRotationAnimation::new(
            &[previous_runtime],
            &[previous_target],
            &[current_runtime],
            &[current_target],
            started_at,
        )
        .unwrap();

        let (frame, sample) = animation.sample(started_at);
        assert!(!sample.geometry_resize_due);
        assert_eq!(frame[0].source_physical_width, 1080.0);
        assert_near(frame[0].source_to_target_transform.scale_x, 1.0);
        assert_near(frame[0].source_to_target_transform.skew_x, 0.0);
        assert_near(frame[0].source_to_target_transform.translate_x, 0.0);
        assert_near(frame[0].source_to_target_transform.skew_y, 0.0);
        assert_near(frame[0].source_to_target_transform.scale_y, 1.0);
        assert_near(frame[0].source_to_target_transform.translate_y, 0.0);

        let (frame, sample) = animation.sample(started_at + Duration::from_millis(180));
        assert!(!sample.geometry_resize_due);
        assert_eq!(frame[0].source_physical_width, 1080.0);

        let (frame, sample) = animation.sample(started_at + Duration::from_millis(200));
        assert!(sample.geometry_resize_due);
        assert_eq!(frame[0].source_physical_width, 1920.0);

        let (_, sample) = animation.sample(started_at + Duration::from_millis(220));
        assert!(!sample.geometry_resize_due);

        let (frame, sample) = animation.sample(started_at + OUTPUT_ROTATION_ANIMATION_DURATION);
        assert!(sample.complete);
        assert_eq!(frame[0], current_target);
    }

    #[test]
    fn producer_request_expires_only_after_the_no_raster_grace_period() {
        let producer = ProducerArbiter::new();
        let started_at = Instant::now();
        let grace = Duration::from_millis(17);

        assert!(producer.try_request(started_at));
        assert!(producer.is_busy());
        assert!(!producer.recover_no_raster(started_at + Duration::from_millis(16), grace));
        assert!(producer.recover_no_raster(started_at + grace, grace));
        assert!(!producer.is_busy());
    }

    #[test]
    fn raster_claim_wins_over_no_raster_recovery() {
        let producer = ProducerArbiter::new();
        let started_at = Instant::now();

        assert!(producer.try_request(started_at));
        producer.begin_raster();
        assert!(!producer.recover_no_raster(started_at + Duration::from_secs(1), Duration::ZERO));
        assert_eq!(producer.finish(), FlutterProducerState::Rasterizing);
        assert!(!producer.is_busy());
    }

    #[test]
    fn late_raster_reclaims_an_expired_reservation() {
        let producer = ProducerArbiter::new();
        let started_at = Instant::now();

        assert!(producer.try_request(started_at));
        assert!(producer.recover_no_raster(
            started_at + Duration::from_millis(20),
            Duration::from_millis(17)
        ));
        producer.begin_raster();
        assert!(producer.is_busy());
        assert_eq!(producer.finish(), FlutterProducerState::Rasterizing);
    }

    #[test]
    fn posix_locale_parser_preserves_chinese_script_distinctions() {
        let simplified = parse_posix_locale("zh_CN.UTF-8").expect("Simplified Chinese locale");
        assert_eq!(simplified.language_code(), c"zh");
        assert_eq!(simplified.country_code(), Some(c"CN"));
        assert_eq!(simplified.script_code(), Some(c"Hans"));

        let traditional = parse_posix_locale("zh_TW.UTF-8").expect("Traditional Chinese locale");
        assert_eq!(traditional.country_code(), Some(c"TW"));
        assert_eq!(traditional.script_code(), Some(c"Hant"));
    }

    #[test]
    fn locale_environment_uses_posix_category_precedence() {
        let locale = locale_from_environment(|name| match name {
            "LC_ALL" => Some(String::new()),
            "LC_MESSAGES" => Some("zh-Hans-SG.UTF-8".to_owned()),
            "LANG" => Some("en_US.UTF-8".to_owned()),
            _ => None,
        })
        .expect("message locale");
        assert_eq!(locale.language_code(), c"zh");
        assert_eq!(locale.country_code(), Some(c"SG"));
        assert_eq!(locale.script_code(), Some(c"Hans"));
        assert_eq!(locale.variant_code(), None);
    }

    #[test]
    fn vm_service_log_parser_only_accepts_the_configured_loopback_service() {
        assert_eq!(
            vm_service_uri_from_log(
                "The Dart VM service is listening on http://127.0.0.1:43125/AUTH=/"
            ),
            Some("http://127.0.0.1:43125/AUTH=/")
        );
        assert_eq!(
            vm_service_uri_from_log("http://0.0.0.0:43125/unsafe=/"),
            None
        );
        assert_eq!(
            vm_service_uri_from_log("application printed http://127.0.0.1:43125/spoof=/"),
            None
        );
        assert_eq!(
            vm_service_uri_from_log("http://127.0.0.1:not-a-port/token=/"),
            None
        );
        assert_eq!(vm_service_uri_from_log("http://127.0.0.1:43125/"), None);
        assert_eq!(vm_service_uri_from_log("ordinary Flutter log"), None);
    }

    #[test]
    fn flutter_scroll_delta_scales_only_finger_scroll() {
        assert_eq!(
            flutter_scroll_delta(Some(15.0), Some(120.0), AxisSource::Wheel, 5.0),
            53.0
        );
        assert_eq!(
            flutter_scroll_delta(Some(-15.0), Some(-60.0), AxisSource::Wheel, 0.05),
            -26.5
        );
        assert_eq!(
            flutter_scroll_delta(Some(7.25), None, AxisSource::Finger, 2.0),
            14.5
        );
        assert_eq!(
            flutter_scroll_delta(Some(7.25), None, AxisSource::Continuous, 2.0),
            7.25
        );
        assert_eq!(
            flutter_scroll_delta(None, None, AxisSource::Finger, 5.0),
            0.0
        );
    }

    #[test]
    fn closing_window_textures_remain_leased_until_flutter_completes() {
        let now = Instant::now();
        let mut leases = WindowCloseTextureLeases::default();
        assert_eq!(
            leases
                .publish(HashMap::from([(41, vec![7, 8])]), now)
                .lease_count,
            0
        );

        let retired = leases.publish(HashMap::new(), now);
        assert_eq!(retired.lease_count, 0);
        assert!(retired.texture_ids.is_empty());
        assert!(leases.retains_texture(7));
        assert!(leases.retains_texture(8));

        let retired = leases.complete(41);
        assert_eq!(retired.lease_count, 1);
        assert_eq!(retired.texture_ids, [7, 8]);
        assert!(!leases.retains_texture(7));
        assert!(!leases.retains_texture(8));
        assert_eq!(leases.complete(41).lease_count, 0);
    }

    #[test]
    fn closing_window_texture_leases_have_a_watchdog() {
        let now = Instant::now();
        let mut leases = WindowCloseTextureLeases::default();
        leases.publish(HashMap::from([(41, vec![7])]), now);
        leases.publish(HashMap::new(), now);

        assert_eq!(
            leases
                .expire(now + WINDOW_CLOSE_LEASE_TIMEOUT - Duration::from_nanos(1))
                .lease_count,
            0
        );
        let retired = leases.expire(now + WINDOW_CLOSE_LEASE_TIMEOUT);
        assert_eq!(retired.lease_count, 1);
        assert_eq!(retired.texture_ids, [7]);
        assert!(!leases.retains_texture(7));
    }

    #[test]
    fn window_close_completion_is_one_positive_little_endian_id() {
        assert_eq!(
            decode_window_close_complete(&0x0102_0304_0506_0708_u64.to_le_bytes()),
            Some(0x0102_0304_0506_0708)
        );
        assert_eq!(decode_window_close_complete(&0_u64.to_le_bytes()), None);
        assert_eq!(decode_window_close_complete(&[1; 7]), None);
        assert_eq!(decode_window_close_complete(&[1; 9]), None);
    }

    #[test]
    fn timeline_vsync_preserves_the_deadline_across_dispatch_latency() {
        let interval = Duration::from_millis(5);
        let (start, target) =
            timeline_vsync_timestamps(1_000_000_000, Duration::from_micros(750), interval);
        assert_eq!(start, 999_250_000);
        assert_eq!(target, 1_004_250_000);

        let (saturated_start, saturated_target) =
            timeline_vsync_timestamps(100, Duration::from_nanos(200), Duration::from_nanos(50));
        assert_eq!((saturated_start, saturated_target), (0, 50));
    }

    struct PanicsOnDrop;

    impl Drop for PanicsOnDrop {
        fn drop(&mut self) {
            panic!("panic payload escaped its containment guard");
        }
    }

    #[test]
    fn external_texture_ffi_guard_forgets_hostile_panic_payloads() {
        assert!(!contain_ffi_unwind(|| std::panic::panic_any(PanicsOnDrop)));
    }

    #[test]
    fn external_texture_resource_budget_is_exact_and_reusable() {
        let budget = Arc::new(ExternalTextureResourceBudget::default());
        let permits = (0..MAX_LIVE_EXTERNAL_TEXTURE_RESOURCES)
            .map(|_| budget.try_acquire().unwrap())
            .collect::<Vec<_>>();
        assert!(budget.try_acquire().is_none());
        assert_eq!(
            budget.live.load(Ordering::Acquire),
            MAX_LIVE_EXTERNAL_TEXTURE_RESOURCES
        );
        drop(permits);
        assert_eq!(budget.live.load(Ordering::Acquire), 0);
        assert!(budget.try_acquire().is_some());
    }

    #[test]
    fn cached_shm_binding_retires_after_its_last_flutter_lease() {
        let budget = Arc::new(ExternalTextureResourceBudget::default());
        let retirements = Arc::new(RetiredExternalBindingQueue::new());
        let binding = Arc::new(CachedTextureBinding {
            binding: Some(ExternalTextureBinding {
                dmabuf_image: None,
                texture: 77,
                _resource_permit: budget.try_acquire().unwrap(),
            }),
            retirements: Arc::clone(&retirements),
        });
        let cached = Arc::clone(&binding);
        let pool = Arc::new(Mutex::new(Vec::new()));
        let lease = Box::new(ExternalTextureLease {
            resource: Some(ExternalTextureLeaseResource::Shm {
                _binding: binding,
                _resource_permit: budget.try_acquire().unwrap(),
            }),
            pool: Arc::downgrade(&pool),
        });
        assert_eq!(budget.live.load(Ordering::Acquire), 2);

        let raw = Box::into_raw(lease).cast();
        // SAFETY: `raw` came from exactly one Box::into_raw above and this is
        // the callback's single ownership-consuming invocation.
        unsafe { retire_external_texture(raw) };
        assert_eq!(lock(&pool).len(), 1);
        assert!(lock(&pool)[0].resource.is_none());
        assert!(lock(&retirements.bindings).is_empty());
        assert!(!retirements.pending.load(Ordering::Acquire));
        assert_eq!(budget.live.load(Ordering::Acquire), 1);
        drop(cached);
        assert!(retirements.pending.load(Ordering::Acquire));
        assert_eq!(lock(&retirements.bindings).len(), 1);
        let binding = lock(&retirements.bindings).pop().unwrap();
        assert_eq!(binding.texture, 77);
        drop(binding);
        assert_eq!(budget.live.load(Ordering::Acquire), 0);
    }

    #[test]
    fn shm_source_generation_requires_the_same_snapshot_identity() {
        let pixels = vec![1, 2, 3, 4];
        let pixel_storage = pixels.as_ptr();
        let frame = ShmTextureFrame::new(1, 1, 9, pixels).unwrap();
        assert_eq!(frame.pixels().as_ptr(), pixel_storage);
        let current = ExternalTextureSource::Shm(frame.clone());
        let same_snapshot = ExternalTextureSource::Shm(frame);
        let colliding_revision =
            ExternalTextureSource::Shm(ShmTextureFrame::new(1, 1, 9, vec![5, 6, 7, 8]).unwrap());

        assert!(current.same_generation(&same_snapshot));
        assert!(!current.same_generation(&colliding_revision));
    }

    #[test]
    fn external_texture_queue_preserves_one_jittered_successor() {
        let source = |revision, value| {
            ExternalTextureSource::Shm(
                ShmTextureFrame::new(1, 1, revision, vec![value, 0, 0, 255]).unwrap(),
            )
        };
        let mut slot = ExternalTextureSlot::default();

        let first = source(1, 1);
        assert!(slot.queue(first.clone(), true));
        // Scene-only commits can republish every texture. They must not prime
        // another Flutter frame unless the visual generation really changed.
        assert!(!slot.queue(first, true));
        assert!(slot.advance());
        assert_eq!(slot.current.as_ref().unwrap().generation(), 1);
        assert!(!slot.current_sampled);

        assert!(slot.queue(source(2, 2), true));
        assert!(!slot.advance());
        assert_eq!(slot.current.as_ref().unwrap().generation(), 1);

        // A commit arriving across the tick boundary must not replace the
        // immediate successor or the generation already granted to Flutter.
        assert!(slot.queue(source(3, 3), true));
        assert_eq!(slot.queued.as_ref().unwrap().generation(), 2);
        assert_eq!(slot.lookahead.as_ref().unwrap().generation(), 3);
        slot.current_sampled = true;
        assert!(slot.advance());
        assert_eq!(slot.current.as_ref().unwrap().generation(), 2);
        assert_eq!(slot.queued.as_ref().unwrap().generation(), 3);
        assert!(slot.lookahead.is_none());
        assert!(!slot.current_sampled);
        assert!(!slot.advance());

        slot.current_sampled = true;
        assert!(slot.advance());
        assert_eq!(slot.current.as_ref().unwrap().generation(), 3);
        assert!(!slot.has_queued());

        // If the client gets farther ahead, retain the immediate successor
        // and replace only the far end of the bounded queue.
        assert!(slot.queue(source(4, 4), true));
        assert!(slot.queue(source(5, 5), true));
        assert!(slot.queue(source(6, 6), true));
        assert_eq!(slot.queued.as_ref().unwrap().generation(), 4);
        assert_eq!(slot.lookahead.as_ref().unwrap().generation(), 6);
        slot.current_sampled = true;
        assert!(slot.advance());
        assert_eq!(slot.current.as_ref().unwrap().generation(), 4);
        assert_eq!(slot.queued.as_ref().unwrap().generation(), 6);

        // Like C++, off-scene surfaces do not wait forever for a sample which
        // the shell has explicitly said it will not draw.
        assert!(slot.queue(source(7, 7), false));
        assert!(slot.advance());
        assert_eq!(slot.current.as_ref().unwrap().generation(), 6);
        assert_eq!(slot.queued.as_ref().unwrap().generation(), 7);
    }

    #[test]
    fn released_shm_frames_recycle_their_pixel_allocation() {
        let pool = Arc::new(ShmSnapshotPool::new());
        let mut pixels = Vec::with_capacity(4096);
        pixels.extend_from_slice(&[1, 2, 3, 4]);
        let pixel_storage = pixels.as_ptr();
        let frame = ShmTextureFrame::new_pooled(1, 1, 1, pixels, &pool).unwrap();
        drop(frame);

        let recycled = pool.acquire(4);
        assert_eq!(recycled.as_ptr(), pixel_storage);
        assert!(recycled.capacity() >= 4096);
        assert!(lock(&pool.state).buffers.is_empty());
        assert_eq!(lock(&pool.state).retained_bytes, 0);
    }

    fn queued_pointer(
        phase: sys::FlutterPointerPhase,
        x: f64,
        device: i32,
        buttons: i64,
        replaceable_motion: bool,
    ) -> InputRecord {
        InputRecord::Pointer(PointerRecord {
            phase,
            x,
            y: x,
            device,
            signal_kind: sys::FlutterPointerSignalKind_kFlutterPointerSignalKindNone,
            scroll_x: 0.0,
            scroll_y: 0.0,
            device_kind: if device == 0 {
                sys::FlutterPointerDeviceKind_kFlutterPointerDeviceKindMouse
            } else {
                sys::FlutterPointerDeviceKind_kFlutterPointerDeviceKindTouch
            },
            buttons,
            replaceable_motion,
        })
    }

    fn queued_scroll(delta: f64) -> InputRecord {
        InputRecord::Pointer(PointerRecord {
            phase: sys::FlutterPointerPhase_kHover,
            x: 0.0,
            y: 0.0,
            device: 0,
            signal_kind: sys::FlutterPointerSignalKind_kFlutterPointerSignalKindScroll,
            scroll_x: 0.0,
            scroll_y: delta,
            device_kind: sys::FlutterPointerDeviceKind_kFlutterPointerDeviceKindMouse,
            buttons: 0,
            replaceable_motion: false,
        })
    }

    fn queued_key(pressed: bool) -> InputRecord {
        InputRecord::Keyboard(KeyboardRecord {
            keycode: 30,
            unicode: u32::from('a'),
            modifiers: 0,
            pressed,
        })
    }

    #[test]
    fn input_queue_coalesces_each_motion_tail_by_latest_device_order() {
        let mut events = VecDeque::new();
        push_bounded_input(
            &mut events,
            queued_pointer(sys::FlutterPointerPhase_kAdd, 0.0, 1, 0, false),
            8,
        );
        push_bounded_input(
            &mut events,
            queued_pointer(sys::FlutterPointerPhase_kMove, 1.0, 1, 0, true),
            8,
        );
        push_bounded_input(
            &mut events,
            queued_pointer(sys::FlutterPointerPhase_kMove, 2.0, 2, 0, true),
            8,
        );
        push_bounded_input(
            &mut events,
            queued_pointer(sys::FlutterPointerPhase_kMove, 3.0, 1, 0, true),
            8,
        );

        let samples: Vec<_> = events
            .iter()
            .filter_map(|event| match event {
                InputRecord::Pointer(event) if event.replaceable_motion => {
                    Some((event.device, event.x))
                }
                InputRecord::Pointer(_) | InputRecord::Keyboard(_) => None,
            })
            .collect();
        assert_eq!(samples, [(2, 2.0), (1, 3.0)]);

        // A semantic transition is a compaction boundary even when Flutter
        // represents that transition with the Move phase (second button).
        push_bounded_input(
            &mut events,
            queued_pointer(sys::FlutterPointerPhase_kMove, 3.0, 1, 3, false),
            8,
        );
        push_bounded_input(
            &mut events,
            queued_pointer(sys::FlutterPointerPhase_kMove, 4.0, 1, 3, true),
            8,
        );
        push_bounded_input(
            &mut events,
            queued_pointer(sys::FlutterPointerPhase_kMove, 5.0, 1, 3, true),
            8,
        );

        assert_eq!(events.len(), 5);
        let mut tail = events.iter().rev();
        assert!(matches!(
            tail.next(),
            Some(InputRecord::Pointer(PointerRecord {
                x: 5.0,
                replaceable_motion: true,
                ..
            }))
        ));
        assert!(matches!(
            tail.next(),
            Some(InputRecord::Pointer(PointerRecord {
                buttons: 3,
                replaceable_motion: false,
                ..
            }))
        ));
    }

    #[test]
    fn input_queue_motion_flood_preserves_transitions_and_latest_position() {
        let mut events = VecDeque::new();
        for event in [
            queued_pointer(sys::FlutterPointerPhase_kAdd, 0.0, 0, 0, false),
            queued_pointer(sys::FlutterPointerPhase_kDown, 0.0, 0, 1, false),
            queued_pointer(sys::FlutterPointerPhase_kMove, 0.0, 0, 3, false),
            queued_key(false),
            queued_pointer(sys::FlutterPointerPhase_kUp, 0.0, 0, 0, false),
        ] {
            push_bounded_input(&mut events, event, 6);
        }
        for x in 1..=10_000 {
            push_bounded_input(
                &mut events,
                queued_pointer(sys::FlutterPointerPhase_kHover, f64::from(x), 0, 0, true),
                6,
            );
        }

        assert_eq!(events.len(), 6);
        assert!(
            matches!(events[0], InputRecord::Pointer(event) if event.phase == sys::FlutterPointerPhase_kAdd)
        );
        assert!(
            matches!(events[1], InputRecord::Pointer(event) if event.phase == sys::FlutterPointerPhase_kDown)
        );
        assert!(
            matches!(events[2], InputRecord::Pointer(event) if event.buttons == 3 && !event.replaceable_motion)
        );
        assert!(matches!(events[3], InputRecord::Keyboard(event) if !event.pressed));
        assert!(
            matches!(events[4], InputRecord::Pointer(event) if event.phase == sys::FlutterPointerPhase_kUp)
        );
        assert!(
            matches!(events[5], InputRecord::Pointer(event) if event.x == 10_000.0 && event.replaceable_motion)
        );
    }

    #[test]
    fn input_queue_resize_starts_a_fresh_flutter_device_lifecycle() {
        let mut input = InputQueue::new(PixelSize::new(1920, 1080));
        input.pointer_x = 1900.0;
        input.pointer_y = 1000.0;
        input.pointer_buttons = 3;
        input.mouse_added = true;
        input.touch_positions.insert(4, (100.0, 200.0));
        input.events.push_back(queued_pointer(
            sys::FlutterPointerPhase_kMove,
            42.0,
            0,
            3,
            false,
        ));

        input.resize(PixelSize::new(1280, 720));

        assert_eq!((input.pointer_x, input.pointer_y), (1280.0, 720.0));
        assert_eq!(input.pointer_buttons, 0);
        assert!(!input.mouse_added);
        assert!(input.touch_positions.is_empty());
        assert!(input.events.is_empty());
    }

    #[test]
    fn compositor_position_remains_authoritative_during_repeated_locked_motion() {
        let mut input = InputQueue::new(PixelSize::new(1920, 1080));

        // A locked pointer can produce an arbitrary stream of relative
        // libinput deltas while its compositor position remains fixed. Every
        // Flutter sample must use that resolved position, not integrate those
        // deltas independently.
        for _ in 0..128 {
            input.handle_pointer_motion_at(713.25, 419.75);
        }

        assert_eq!((input.pointer_x, input.pointer_y), (713.25, 419.75));
        assert_eq!(input.events.len(), 2); // Add plus coalesced Hover.
        assert!(matches!(
            input.events.back(),
            Some(InputRecord::Pointer(PointerRecord {
                x: 713.25,
                y: 419.75,
                replaceable_motion: true,
                ..
            }))
        ));
    }

    #[test]
    fn routed_pointer_leave_and_reentry_create_balanced_flutter_lifecycles() {
        let mut input = InputQueue::new(PixelSize::new(1920, 1080));

        input.handle_pointer_motion_at(100.0, 200.0);
        input.handle_pointer_leave_at(300.0, 400.0);
        input.handle_pointer_leave_at(300.0, 400.0);
        input.handle_pointer_motion_at(500.0, 600.0);

        let phases = input
            .events
            .iter()
            .filter_map(|event| match event {
                InputRecord::Pointer(event) => {
                    Some((event.phase, event.x, event.y, event.replaceable_motion))
                }
                InputRecord::Keyboard(_) => None,
            })
            .collect::<Vec<_>>();
        assert_eq!(
            phases,
            vec![
                (sys::FlutterPointerPhase_kAdd, 100.0, 200.0, false,),
                (sys::FlutterPointerPhase_kHover, 100.0, 200.0, true,),
                (sys::FlutterPointerPhase_kRemove, 300.0, 400.0, false,),
                (sys::FlutterPointerPhase_kAdd, 500.0, 600.0, false,),
                (sys::FlutterPointerPhase_kHover, 500.0, 600.0, true,),
            ]
        );
        assert!(input.mouse_added);
        assert_eq!((input.pointer_x, input.pointer_y), (500.0, 600.0));
    }

    #[test]
    fn routed_pointer_leave_waits_for_flutter_button_capture_to_end() {
        let mut input = InputQueue::new(PixelSize::new(1920, 1080));

        input.handle_pointer_motion_at(100.0, 200.0);
        input.pointer_buttons = 1;
        input.handle_pointer_leave_at(300.0, 400.0);
        assert!(input.mouse_lifecycle_active());
        assert!(input.events.iter().all(|event| !matches!(
            event,
            InputRecord::Pointer(event)
                if event.phase == sys::FlutterPointerPhase_kRemove
        )));

        input.pointer_buttons = 0;
        input.handle_pointer_leave_at(300.0, 400.0);
        assert!(!input.mouse_lifecycle_active());
        assert!(input.events.iter().any(|event| matches!(
            event,
            InputRecord::Pointer(event)
                if event.phase == sys::FlutterPointerPhase_kRemove
        )));
    }

    #[test]
    fn input_queue_device_removal_terminates_and_restarts_lifecycles() {
        let mut input = InputQueue::new(PixelSize::new(1920, 1080));
        input.pointer_buttons = 1;
        input.mouse_added = true;
        input.touch_positions.insert(4, (100.0, 200.0));

        input.cancel_device_lifecycles(true, true);

        assert_eq!(input.pointer_buttons, 0);
        assert!(!input.mouse_added);
        assert!(input.touch_positions.is_empty());
        let terminal_phases = input
            .events
            .iter()
            .filter_map(|event| match event {
                InputRecord::Pointer(event) => Some((event.device, event.phase)),
                InputRecord::Keyboard(_) => None,
            })
            .collect::<Vec<_>>();
        assert_eq!(
            terminal_phases,
            vec![
                (0, sys::FlutterPointerPhase_kCancel),
                (0, sys::FlutterPointerPhase_kRemove),
                (4, sys::FlutterPointerPhase_kCancel),
                (4, sys::FlutterPointerPhase_kRemove),
            ]
        );
    }

    #[test]
    fn input_queue_evicts_motion_before_scroll_or_state_transition() {
        let mut events = VecDeque::new();
        for event in [
            queued_pointer(sys::FlutterPointerPhase_kAdd, 0.0, 0, 0, false),
            queued_pointer(sys::FlutterPointerPhase_kHover, 1.0, 0, 0, true),
            queued_scroll(15.0),
            queued_key(false),
            queued_pointer(sys::FlutterPointerPhase_kUp, 1.0, 0, 0, false),
        ] {
            push_bounded_input(&mut events, event, 5);
        }
        push_bounded_input(
            &mut events,
            queued_pointer(sys::FlutterPointerPhase_kHover, 2.0, 0, 0, true),
            5,
        );

        assert_eq!(events.len(), 5);
        assert!(events.iter().any(|event| matches!(
            event,
            InputRecord::Pointer(PointerRecord {
                signal_kind: sys::FlutterPointerSignalKind_kFlutterPointerSignalKindScroll,
                ..
            })
        )));
        assert!(
            events
                .iter()
                .any(|event| matches!(event, InputRecord::Keyboard(key) if !key.pressed))
        );
        assert!(events.iter().any(|event| matches!(
            event,
            InputRecord::Pointer(PointerRecord {
                x: 2.0,
                replaceable_motion: true,
                ..
            })
        )));
        assert!(!events.iter().any(|event| matches!(
            event,
            InputRecord::Pointer(PointerRecord {
                x: 1.0,
                replaceable_motion: true,
                ..
            })
        )));
    }

    #[test]
    fn recency_cache_evicts_the_least_recently_used_binding() {
        let mut cache = RecencyCache::new(2);
        assert!(cache.insert(1, "one").is_none());
        assert!(cache.insert(2, "two").is_none());
        assert_eq!(cache.get_by(|key| *key == 1), Some("one"));

        assert_eq!(cache.insert(3, "three"), Some("two"));
        assert_eq!(cache.get_by(|key| *key == 1), Some("one"));
        assert_eq!(cache.get_by(|key| *key == 2), None);
        assert_eq!(cache.get_by(|key| *key == 3), Some("three"));
        assert_eq!(
            cache.stats(),
            RecencyCacheStats {
                hits: 3,
                misses: 1,
                capacity_evictions: 1,
                explicit_removals: 0,
            }
        );
    }

    #[test]
    fn recency_cache_can_retire_every_binding_owned_by_a_texture() {
        let mut cache = RecencyCache::new(4);
        assert!(cache.insert((7, 1), "seven-a").is_none());
        assert!(cache.insert((8, 2), "eight").is_none());
        assert!(cache.insert((7, 3), "seven-b").is_none());

        let mut retired = cache.remove_where(|(texture_id, _)| *texture_id == 7);
        retired.sort_unstable();
        assert_eq!(retired, ["seven-a", "seven-b"]);
        assert_eq!(cache.get_by(|key| *key == (8, 2)), Some("eight"));
        assert_eq!(cache.stats().explicit_removals, 2);
    }

    #[test]
    fn partitioned_recency_cache_keeps_each_texture_buffer_ring_resident() {
        let mut cache = PartitionedRecencyCache::new(4);
        for texture_id in 0..10 {
            for buffer in 0..4 {
                assert!(
                    cache
                        .insert(texture_id, buffer, (texture_id, buffer))
                        .is_none()
                );
            }
        }

        // Forty rotating buffers exceed the old global capacity of 32. Every
        // generation must remain a hit when the same ten clients are sampled
        // repeatedly in Flutter's stable scene order.
        for _ in 0..3 {
            for texture_id in 0..10 {
                for buffer in 0..4 {
                    assert_eq!(
                        cache.get_by(&texture_id, |candidate| *candidate == buffer),
                        Some((texture_id, buffer))
                    );
                }
            }
        }
    }

    #[test]
    fn partitioned_recency_cache_evicts_and_retires_only_one_texture() {
        let mut cache = PartitionedRecencyCache::new(2);
        assert!(cache.insert(7, 1, "seven-a").is_none());
        assert!(cache.insert(7, 2, "seven-b").is_none());
        assert!(cache.insert(8, 1, "eight-a").is_none());
        assert!(cache.insert(8, 2, "eight-b").is_none());

        assert_eq!(cache.insert(7, 3, "seven-c"), Some("seven-a"));
        assert_eq!(cache.get_by(&7, |key| *key == 1), None);
        assert_eq!(cache.get_by(&8, |key| *key == 1), Some("eight-a"));

        let mut retired = cache.remove(&7);
        retired.sort_unstable();
        assert_eq!(retired, ["seven-b", "seven-c"]);
        assert_eq!(cache.get_by(&7, |_| true), None);
        assert_eq!(cache.drain().len(), 2);
    }

    fn rect(left: f64, top: f64, right: f64, bottom: f64) -> sys::FlutterRect {
        sys::FlutterRect {
            left,
            top,
            right,
            bottom,
        }
    }

    #[test]
    fn evdev_keys_use_the_existing_linux_glfw_contract() {
        assert_eq!(glfw_keycode(1), 256);
        assert_eq!(glfw_keycode(16), u32::from('Q'));
        assert_eq!(glfw_keycode(30), u32::from('A'));
        assert_eq!(glfw_keycode(59), 290);
        assert_eq!(glfw_keycode(105), 263);
        assert_eq!(glfw_keycode(125), 343);
        assert_eq!(glfw_keycode(999), 999);
    }

    #[test]
    fn key_event_message_includes_layout_derived_unicode() {
        let mut message = Vec::new();
        encode_key_event(
            KeyboardRecord {
                keycode: 30,
                unicode: u32::from('à'),
                modifiers: 1,
                pressed: true,
            },
            &mut message,
        );
        let message: serde_json::Value = serde_json::from_slice(&message).unwrap();
        assert_eq!(message["keyCode"], u32::from('A'));
        assert_eq!(message["scanCode"], u32::from('A'));
        assert_eq!(message["unicodeScalarValues"], u32::from('à'));
        assert_eq!(message["modifiers"], 1);
        assert_eq!(message["type"], "keydown");

        let storage = message.as_object().expect("decoded key event");
        assert_eq!(storage["keymap"], "linux");
        let mut bytes = Vec::with_capacity(160);
        let allocation = bytes.as_ptr();
        encode_key_event(
            KeyboardRecord {
                keycode: 30,
                unicode: 0,
                modifiers: 0,
                pressed: false,
            },
            &mut bytes,
        );
        assert_eq!(bytes.as_ptr(), allocation);
        let release: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(release["type"], "keyup");
        assert!(release.get("unicodeScalarValues").is_none());
    }

    #[test]
    fn pending_vsync_batons_are_deduplicated_bounded_and_one_shot() {
        let mut pending = PendingVsyncBatons::default();
        assert_eq!(pending.register(7), VsyncRegistration::Accepted);
        assert_eq!(pending.register(7), VsyncRegistration::Duplicate);
        assert!(pending.complete(7));
        assert!(!pending.complete(7));
        // Reuse after completion is valid; only simultaneous duplicate
        // obligations are ambiguous and suppressed.
        assert_eq!(pending.register(7), VsyncRegistration::Accepted);
        assert!(pending.complete(7));

        for baton in 0..MAX_PENDING_VSYNC_BATONS {
            assert_eq!(
                pending.register(isize::try_from(baton).unwrap()),
                VsyncRegistration::Accepted
            );
        }
        assert_eq!(pending.register(-1), VsyncRegistration::AtCapacity);
        let batons = pending.take_all();
        assert_eq!(batons.len(), MAX_PENDING_VSYNC_BATONS);
        assert!(pending.take_all().is_empty());

        pending.register(41);
        pending.register(42);
        assert_eq!(pending.take_next(), Some(41));
        pending.restore_front(41);
        assert_eq!(pending.take_all(), VecDeque::from([41, 42]));
    }

    fn queued_platform_task(
        budget: &Arc<PlatformTaskBudget>,
        task: u64,
        target_time_nanos: u64,
        order: u64,
    ) -> QueuedPlatformTask {
        QueuedPlatformTask {
            task: ScheduledTask {
                runner: 1,
                task,
                target_time_nanos,
            },
            permit: budget.try_acquire().unwrap(),
            order,
        }
    }

    #[test]
    fn platform_task_budget_bounds_channel_and_runtime_ownership() {
        let budget = Arc::new(PlatformTaskBudget::default());
        let mut permits = (0..MAX_PENDING_PLATFORM_TASKS)
            .map(|_| budget.try_acquire().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(
            budget.pending.load(Ordering::Acquire),
            MAX_PENDING_PLATFORM_TASKS
        );
        assert!(budget.try_acquire().is_none());

        permits.truncate(MAX_PENDING_PLATFORM_TASKS - 1);
        assert_eq!(
            budget.pending.load(Ordering::Acquire),
            MAX_PENDING_PLATFORM_TASKS - 1
        );
        let replacement = budget.try_acquire().unwrap();
        assert!(budget.try_acquire().is_none());

        drop(replacement);
        drop(permits);
        assert_eq!(budget.pending.load(Ordering::Acquire), 0);
    }

    #[test]
    fn platform_tasks_run_by_deadline_fifo_and_handle_clock_extremes() {
        let budget = Arc::new(PlatformTaskBudget::default());
        let mut tasks = BinaryHeap::from([
            queued_platform_task(&budget, 1, 50, 0),
            queued_platform_task(&budget, 2, 20, 1),
            queued_platform_task(&budget, 3, 20, 2),
            queued_platform_task(&budget, 4, u64::MAX, 3),
        ]);

        assert_eq!(
            platform_task_dispatch_timeout(&tasks, 0),
            Duration::from_nanos(20)
        );
        assert!(take_next_due_platform_task(&mut tasks, 19).is_none());
        let second = take_next_due_platform_task(&mut tasks, 20).unwrap();
        assert_eq!(second.task.task, 2);
        drop(second);
        let third = take_next_due_platform_task(&mut tasks, 20).unwrap();
        assert_eq!(third.task.task, 3);
        drop(third);
        let first = take_next_due_platform_task(&mut tasks, 50).unwrap();
        assert_eq!(first.task.task, 1);
        drop(first);

        assert_eq!(
            platform_task_dispatch_timeout(&tasks, u64::MAX - 5),
            Duration::from_nanos(5)
        );
        let last = take_next_due_platform_task(&mut tasks, u64::MAX).unwrap();
        assert_eq!(last.task.task, 4);
        drop(last);
        assert_eq!(
            platform_task_dispatch_timeout(&tasks, u64::MAX),
            Duration::from_millis(100)
        );

        tasks.push(queued_platform_task(&budget, 5, 0, 4));
        assert_eq!(
            platform_task_dispatch_timeout(&tasks, u64::MAX),
            Duration::ZERO
        );
        drop(take_next_due_platform_task(&mut tasks, u64::MAX));
        assert_eq!(budget.pending.load(Ordering::Acquire), 0);
    }

    #[test]
    fn due_platform_task_batch_yields_before_starving_the_event_loop() {
        let budget = Arc::new(PlatformTaskBudget::default());
        let mut tasks = (0..=MAX_PLATFORM_TASKS_PER_DISPATCH)
            .map(|task| {
                let order = u64::try_from(task).unwrap();
                queued_platform_task(&budget, order, 0, order)
            })
            .collect::<BinaryHeap<_>>();

        for expected in 0..MAX_PLATFORM_TASKS_PER_DISPATCH {
            let queued = take_next_due_platform_task(&mut tasks, 0).unwrap();
            assert_eq!(queued.task.task, u64::try_from(expected).unwrap());
            drop(queued);
        }
        assert_eq!(tasks.len(), 1);
        assert_eq!(platform_task_dispatch_timeout(&tasks, 0), Duration::ZERO);
        drop(tasks);
        assert_eq!(budget.pending.load(Ordering::Acquire), 0);
    }

    #[test]
    fn frame_ready_wakeup_coalesces_until_acknowledged() {
        let wakeup = CoalescedWakeup::default();
        assert!(wakeup.begin());
        for _ in 0..10_000 {
            assert!(!wakeup.begin());
        }
        wakeup.acknowledge();
        assert!(wakeup.begin());
        wakeup.acknowledge();
    }

    #[test]
    fn coalesced_inbox_batches_edges_and_recycles_storage() {
        let inbox = CoalescedInbox::with_capacity(4);
        let mut batch = Vec::with_capacity(4);

        assert!(inbox.push(1));
        assert!(!inbox.push(2));
        assert!(!inbox.push(3));
        inbox.take_into(&mut batch);
        assert_eq!(batch, [1, 2, 3]);

        batch.clear();
        assert!(inbox.push(4));
        assert!(!inbox.push(5));
        inbox.take_into(&mut batch);
        assert_eq!(batch, [4, 5]);

        batch.clear();
        assert!(inbox.push(6));
        inbox.discard_after_failed_wakeup();
        assert!(inbox.push(7));
        inbox.take_into(&mut batch);
        assert_eq!(batch, [7]);
    }

    fn output_broker() -> OutputBufferBroker {
        let first = [11, 12, 13];
        let second = [21, 22, 23];
        OutputBufferBroker::new([
            OutputPoolDescriptor {
                output_id: OutputId(1),
                render_view_id: RenderViewId::for_output(OutputId(1)).unwrap(),
                configuration_generation: 7,
                size: PixelSize::new(1920, 1080),
                initial_scanout: 0,
                framebuffers: &first,
            },
            OutputPoolDescriptor {
                output_id: OutputId(2),
                render_view_id: RenderViewId::for_output(OutputId(2)).unwrap(),
                configuration_generation: 7,
                size: PixelSize::new(2560, 1440),
                initial_scanout: 0,
                framebuffers: &second,
            },
        ])
        .unwrap()
    }

    fn pool(broker: &OutputBufferBroker, output: OutputId) -> &OutputBufferPool {
        broker
            .pools
            .iter()
            .find(|pool| pool.output_id == output)
            .unwrap()
    }

    fn pool_mut(broker: &mut OutputBufferBroker, output: OutputId) -> &mut OutputBufferPool {
        broker
            .pools
            .iter_mut()
            .find(|pool| pool.output_id == output)
            .unwrap()
    }

    fn output_request(output: OutputId, render_deadline: Instant) -> OutputFrameRequest {
        OutputFrameRequest {
            tick: FrameTick {
                output,
                sequence: 1,
                interval: Duration::from_millis(10),
                render_deadline,
                presentation_target: render_deadline + Duration::from_millis(10),
            },
            dirty_serial: 1,
        }
    }

    fn acquire_output(broker: &mut OutputBufferBroker, output: OutputId, size: PixelSize) -> u32 {
        let render_deadline = Instant::now();
        let request = output_request(output, render_deadline);
        let view = RenderViewId::for_output(output).unwrap().get();
        assert_eq!(broker.authorize(request, render_deadline), Some(view));
        broker.acquire(view, size).unwrap()
    }

    #[test]
    fn output_authorizations_queue_independently_on_the_single_raster_thread() {
        let mut broker = output_broker();
        let now = Instant::now();
        let first = OutputId(1);
        let second = OutputId(2);
        let first_view = RenderViewId::for_output(first).unwrap().get();
        let second_view = RenderViewId::for_output(second).unwrap().get();

        assert_eq!(
            broker.authorize(output_request(first, now), now),
            Some(first_view)
        );
        assert_eq!(
            broker.authorize(output_request(second, now), now),
            Some(second_view)
        );
        assert!(!broker.target_available(first));
        assert!(!broker.target_available(second));

        broker.begin_transaction();
        let framebuffer = broker
            .acquire(first_view, PixelSize::new(1920, 1080))
            .unwrap();
        assert!(broker.mark_ready(first_view, framebuffer, &[], &[], None, None));
        assert_eq!(broker.finish_transaction().len(), 1);

        assert!(pool(&broker, second).authorized_request.is_some());
        broker.begin_transaction();
        assert!(
            broker
                .acquire(second_view, PixelSize::new(2560, 1440))
                .is_ok()
        );
    }

    #[test]
    fn unclaimed_output_authorization_expires_after_two_output_intervals() {
        let mut broker = output_broker();
        let now = Instant::now();
        let output = OutputId(1);
        let view = RenderViewId::for_output(output).unwrap().get();
        assert_eq!(
            broker.authorize(output_request(output, now), now),
            Some(view)
        );

        assert_eq!(
            broker.expire_authorizations(now + Duration::from_millis(19)),
            0
        );
        assert_eq!(
            broker.expire_authorizations(now + Duration::from_millis(20)),
            1
        );
        assert!(broker.target_available(output));
    }

    #[test]
    fn output_broker_rejects_cross_output_aliases_and_mixed_generations() {
        let first = [1, 2, 3, 4];
        let aliased = [4, 5, 6, 7];
        let descriptor = |output, generation, framebuffers| OutputPoolDescriptor {
            output_id: OutputId(output),
            render_view_id: RenderViewId::for_output(OutputId(output)).unwrap(),
            configuration_generation: generation,
            size: PixelSize::new(64, 48),
            initial_scanout: 0,
            framebuffers,
        };
        assert!(OutputBufferBroker::new([]).is_err());
        assert!(
            OutputBufferBroker::new([descriptor(1, 1, &first), descriptor(2, 1, &aliased),])
                .is_err()
        );
        let second = [5, 6, 7, 8];
        assert!(
            OutputBufferBroker::new([descriptor(1, 1, &first), descriptor(2, 2, &second),])
                .is_err()
        );
    }

    #[test]
    fn raster_transaction_publishes_each_rendered_output() {
        let mut broker = output_broker();
        broker.begin_transaction();
        let first_view = RenderViewId::for_output(OutputId(1)).unwrap().get();
        let second_view = RenderViewId::for_output(OutputId(2)).unwrap().get();
        let first = acquire_output(&mut broker, OutputId(1), PixelSize::new(1920, 1080));
        let second = acquire_output(&mut broker, OutputId(2), PixelSize::new(2560, 1440));
        assert_eq!((first, second), (12, 22));
        assert!(broker.mark_ready(
            first_view,
            first,
            &[rect(1.0, 1.0, 5.0, 5.0)],
            &[rect(0.0, 0.0, 1920.0, 1080.0)],
            None,
            None
        ));
        assert!(broker.mark_ready(second_view, second, &[], &[], None, None));

        let outputs = broker.finish_transaction();
        assert_eq!(outputs.len(), 2);
        assert!(
            outputs
                .iter()
                .find(|output| output.output_id == OutputId(1))
                .unwrap()
                .damage
                .is_full()
        );
        assert!(
            outputs
                .iter()
                .find(|output| output.output_id == OutputId(2))
                .unwrap()
                .damage
                .is_empty()
        );
        assert!(outputs.iter().all(|output| {
            output.request.tick.output == output.output_id
                && output.request.tick.presentation_target
                    == output.request.tick.render_deadline + output.request.tick.interval
        }));
        assert_eq!(
            outputs
                .iter()
                .map(|output| output.output_id)
                .collect::<HashSet<_>>(),
            HashSet::from([OutputId(1), OutputId(2)])
        );
    }

    #[test]
    fn partial_output_transaction_is_handed_off_independently() {
        let mut broker = output_broker();
        broker.begin_transaction();
        let first_view = RenderViewId::for_output(OutputId(1)).unwrap().get();
        let first = acquire_output(&mut broker, OutputId(1), PixelSize::new(1920, 1080));
        acquire_output(&mut broker, OutputId(2), PixelSize::new(2560, 1440));
        assert!(broker.mark_ready(first_view, first, &[], &[], None, None));

        let outputs = broker.finish_transaction();
        assert_eq!(outputs.len(), 1);
        assert_eq!(outputs[0].output_id, OutputId(1));
        assert_eq!(
            pool(&broker, OutputId(1))
                .slots
                .iter()
                .filter(|slot| slot.state == BufferState::Pending)
                .count(),
            1
        );
        assert_eq!(
            pool(&broker, OutputId(2))
                .slots
                .iter()
                .filter(|slot| slot.state == BufferState::Rendering)
                .count(),
            1
        );
    }

    #[test]
    fn every_pool_entry_starts_with_full_repair_damage() {
        let broker = output_broker();
        for output in [OutputId(1), OutputId(2)] {
            let pool = pool(&broker, output);
            assert!(pool.slots.iter().all(|slot| slot.damage.is_full()));
            assert!(pool.slots.iter().all(|slot| slot.ready_damage.is_none()));
        }
    }

    #[test]
    fn frame_damage_advances_other_slots_without_spreading_selected_repair() {
        let mut broker = output_broker();
        let output = OutputId(1);
        let view = RenderViewId::for_output(output).unwrap().get();
        let size = PixelSize::new(1920, 1080);
        for slot in &mut pool_mut(&mut broker, output).slots {
            slot.damage.clear();
        }
        pool_mut(&mut broker, output).slots[1]
            .damage
            .replace_from_flutter(&[rect(10.0, 10.0, 20.0, 20.0)]);

        broker.begin_transaction();
        let framebuffer = acquire_output(&mut broker, output, size);
        assert_eq!(framebuffer, 12);
        assert!(broker.mark_ready(
            view,
            framebuffer,
            &[rect(30.0, 30.0, 40.0, 40.0)],
            &[rect(10.0, 10.0, 20.0, 20.0), rect(30.0, 30.0, 40.0, 40.0),],
            None,
            None,
        ));

        let ready = broker.finish_transaction().pop().unwrap();
        assert!(ready.damage.intersects_pixel_rect(10, 10, 1, 1));
        assert!(ready.damage.intersects_pixel_rect(30, 30, 1, 1));
        let pool = pool(&broker, output);
        assert!(pool.slots[ready.index].damage.is_empty());
        for (index, slot) in pool.slots.iter().enumerate() {
            if index != ready.index {
                assert!(slot.damage.intersects_pixel_rect(30, 30, 1, 1));
                assert!(!slot.damage.intersects_pixel_rect(10, 10, 1, 1));
            }
        }
    }

    #[test]
    fn empty_damage_preserves_the_selected_buffer_and_other_histories() {
        let mut broker = output_broker();
        let output = OutputId(1);
        let view = RenderViewId::for_output(output).unwrap().get();
        let size = PixelSize::new(1920, 1080);
        for slot in &mut pool_mut(&mut broker, output).slots {
            slot.damage.clear();
        }

        broker.begin_transaction();
        let framebuffer = acquire_output(&mut broker, output, size);
        assert!(broker.mark_ready(view, framebuffer, &[], &[], None, None));
        let ready = broker.finish_transaction().pop().unwrap();
        assert!(ready.damage.is_empty());
        assert!(
            pool(&broker, output)
                .slots
                .iter()
                .all(|slot| slot.damage.is_empty())
        );
    }

    #[test]
    fn abandoned_raster_invalidates_instead_of_marking_the_slot_current() {
        let mut broker = output_broker();
        let output = OutputId(1);
        let size = PixelSize::new(1920, 1080);
        for slot in &mut pool_mut(&mut broker, output).slots {
            slot.damage.clear();
        }

        broker.begin_transaction();
        let framebuffer = acquire_output(&mut broker, output, size);
        broker.begin_transaction();

        let slot = pool(&broker, output)
            .slots
            .iter()
            .find(|slot| slot.framebuffer == framebuffer)
            .unwrap();
        assert_eq!(slot.state, BufferState::Free);
        assert!(slot.damage.is_full());
        assert!(slot.ready_damage.is_none());
    }

    #[test]
    fn output_leases_retire_independently_without_cross_output_refcounts() {
        let mut broker = output_broker();
        broker.begin_transaction();
        for (output, size) in [
            (OutputId(1), PixelSize::new(1920, 1080)),
            (OutputId(2), PixelSize::new(2560, 1440)),
        ] {
            let view = RenderViewId::for_output(output).unwrap().get();
            let framebuffer = acquire_output(&mut broker, output, size);
            assert!(broker.mark_ready(view, framebuffer, &[], &[], None, None));
        }
        let outputs = broker.finish_transaction();
        for output in &outputs {
            broker.publish(output).unwrap();
        }

        let first = outputs
            .iter()
            .find(|output| output.output_id == OutputId(1))
            .unwrap();
        let second = outputs
            .iter()
            .find(|output| output.output_id == OutputId(2))
            .unwrap();
        broker.release_output(first.output_id, 0).unwrap();
        broker.release_output(first.output_id, first.index).unwrap();
        assert_eq!(pool(&broker, OutputId(1)).slots[first.index].output_refs, 0);
        assert_eq!(
            pool(&broker, OutputId(2)).slots[second.index].output_refs,
            1
        );
        assert!(broker.release_output(first.output_id, first.index).is_err());
    }

    #[test]
    fn output_publication_validates_only_its_own_slot() {
        let mut broker = output_broker();
        broker.begin_transaction();
        for (output, size) in [
            (OutputId(1), PixelSize::new(1920, 1080)),
            (OutputId(2), PixelSize::new(2560, 1440)),
        ] {
            let view = RenderViewId::for_output(output).unwrap().get();
            let framebuffer = acquire_output(&mut broker, output, size);
            assert!(broker.mark_ready(view, framebuffer, &[], &[], None, None));
        }
        let mut outputs = broker.finish_transaction();
        let valid_second_index = outputs[1].index;
        outputs[1].index = usize::MAX;

        broker.publish(&outputs[0]).unwrap();
        assert!(broker.publish(&outputs[1]).is_err());
        let first = &pool(&broker, outputs[0].output_id).slots[outputs[0].index];
        assert_eq!(first.state, BufferState::Free);
        assert_eq!(first.output_refs, 1);
        let second = &pool(&broker, outputs[1].output_id).slots[valid_second_index];
        assert_eq!(second.state, BufferState::Pending);
        assert_eq!(second.output_refs, 0);

        outputs[1].index = valid_second_index;
        broker.publish(&outputs[1]).unwrap();
        for output in &outputs {
            let slot = &pool(&broker, output.output_id).slots[output.index];
            assert_eq!(slot.state, BufferState::Free);
            assert_eq!(slot.output_refs, 1);
        }
    }

    #[test]
    fn three_output_buffers_hold_scanning_submitted_and_ready_generations() {
        let mut broker = output_broker();
        let output = OutputId(1);
        let view = RenderViewId::for_output(output).unwrap().get();
        let size = PixelSize::new(1920, 1080);

        for expected_framebuffer in [12, 13] {
            broker.begin_transaction();
            let framebuffer = acquire_output(&mut broker, output, size);
            assert_eq!(framebuffer, expected_framebuffer);
            assert!(broker.mark_ready(view, framebuffer, &[], &[], None, None));
            let frames = broker.finish_transaction();
            assert_eq!(frames.len(), 1);
            broker.publish(&frames[0]).unwrap();
        }

        let pool = pool(&broker, output);
        assert_eq!(pool.slots.len(), 3);
        assert_eq!(
            pool.slots
                .iter()
                .map(|slot| slot.output_refs)
                .sum::<usize>(),
            3
        );
        assert!(!broker.target_available(output));
    }

    #[test]
    fn screenshot_tag_applies_only_to_its_target_output() {
        let mut broker = output_broker();
        broker
            .tag_next_frame_for_screenshot(OutputId(1), 41)
            .unwrap();
        broker.begin_transaction();
        for (output, size) in [
            (OutputId(1), PixelSize::new(1920, 1080)),
            (OutputId(2), PixelSize::new(2560, 1440)),
        ] {
            let view = RenderViewId::for_output(output).unwrap().get();
            let framebuffer = acquire_output(&mut broker, output, size);
            assert!(broker.mark_ready(view, framebuffer, &[], &[], None, None));
        }
        assert!(!broker.target_available(OutputId(1)));
        assert!(!broker.target_available(OutputId(2)));
        let outputs = broker.finish_transaction();
        assert_eq!(
            outputs
                .iter()
                .find(|output| output.output_id == OutputId(1))
                .unwrap()
                .screenshot_request_id,
            Some(41)
        );
        assert_eq!(
            outputs
                .iter()
                .find(|output| output.output_id == OutputId(2))
                .unwrap()
                .screenshot_request_id,
            None
        );
        assert!(broker.next_screenshot.is_none());
    }
}
