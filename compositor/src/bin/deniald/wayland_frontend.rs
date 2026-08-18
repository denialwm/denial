use std::collections::{HashMap, HashSet};
use std::error::Error;
use std::ffi::{OsStr, OsString};
#[cfg(feature = "flutter")]
use std::hash::Hash;
use std::process::Stdio;
use std::sync::Arc;
use std::time::{Duration, Instant};

use denial_core::topology::{AtlasPlan, OutputId, TopologySnapshot};
#[cfg(feature = "flutter")]
use smithay::backend::allocator::Buffer as AllocatorBuffer;
use smithay::backend::allocator::dmabuf::Dmabuf;
use smithay::backend::drm::{DrmDeviceFd, DrmNode};
use smithay::backend::egl::EGLDevice;
use smithay::backend::renderer::Bind;
use smithay::backend::renderer::damage::OutputDamageTracker;
use smithay::backend::renderer::element::surface::WaylandSurfaceRenderElement;
use smithay::backend::renderer::gles::GlesRenderer;
use smithay::backend::renderer::utils::on_commit_buffer_handler;
#[cfg(feature = "flutter")]
use smithay::backend::renderer::utils::{
    RendererSurfaceStateUserData, with_renderer_surface_state,
};
use smithay::backend::renderer::{Color32F, Frame, ImportDma, Renderer};
use smithay::backend::session::libseat::LibSeatSession;
use smithay::desktop::{
    PopupKeyboardGrab, PopupKind, PopupManager, PopupPointerGrab, PopupUngrabStrategy, Space,
    Window, WindowSurfaceType, find_popup_root_surface, get_popup_toplevel_coords,
};
use smithay::input::dnd::{DnDGrab, DndGrabHandler, GrabType, Source};
#[cfg(feature = "flutter")]
use smithay::input::keyboard::xkb;
use smithay::input::keyboard::XkbConfig;
use smithay::input::pointer::{CursorImageStatus, Focus, PointerHandle};
use smithay::input::{Seat, SeatHandler, SeatState};
use smithay::output::{Mode, Output, PhysicalProperties, Scale, Subpixel};
use smithay::reexports::calloop::{
    EventLoop, Interest, LoopHandle, Mode as PollMode, PostAction, generic::Generic,
};
#[cfg(feature = "flutter")]
use smithay::reexports::calloop::RegistrationToken;
use smithay::reexports::wayland_protocols::xdg::shell::server::xdg_toplevel;
use smithay::reexports::wayland_protocols::xdg::decoration::zv1::server::zxdg_toplevel_decoration_v1::Mode as XdgDecorationMode;
use smithay::reexports::wayland_server::backend::{
    ClientData, ClientId, DisconnectReason, GlobalId, ObjectId, protocol::ProtocolError,
};
use smithay::reexports::wayland_server::protocol::{
    wl_buffer, wl_output, wl_seat, wl_surface::WlSurface,
};
use smithay::reexports::wayland_server::{Client, Display, DisplayHandle, Resource};
use smithay::utils::{
    Logical, Physical, Point, Rectangle, SERIAL_COUNTER, Serial, Size, Transform,
};
use smithay::wayland::buffer::BufferHandler;
use smithay::wayland::compositor::{
    Blocker, BlockerState, BufferAssignment, CompositorClientState, CompositorHandler,
    CompositorState, SurfaceAttributes, add_blocker, add_pre_commit_hook, get_parent,
    is_sync_subsurface, with_states,
};
#[cfg(feature = "flutter")]
use smithay::wayland::compositor::Cacheable;
use smithay::wayland::cursor_shape::CursorShapeManagerState;
#[cfg(feature = "flutter")]
use smithay::wayland::compositor::{TraversalAction, with_surface_tree_upward};
use smithay::wayland::dmabuf::get_dmabuf;
use smithay::wayland::dmabuf::{
    DmabufFeedbackBuilder, DmabufGlobal, DmabufHandler, DmabufState, ImportNotifier,
};
use smithay::wayland::drm_syncobj::{
    DrmSyncobjCachedState, DrmSyncobjHandler, DrmSyncobjState, supports_syncobj_eventfd,
};
use smithay::wayland::fractional_scale::{
    FractionalScaleManagerState, with_fractional_scale,
};
use smithay::wayland::output::{OutputHandler, OutputManagerState};
use smithay::wayland::pointer_constraints::{PointerConstraintsHandler, PointerConstraintsState};
use smithay::wayland::relative_pointer::RelativePointerManagerState;
use smithay::wayland::seat::WaylandFocus;
use smithay::wayland::selection::SelectionHandler;
use smithay::wayland::selection::data_device::{
    DataDeviceHandler, DataDeviceState, WaylandDndGrabHandler, set_data_device_focus,
};
use smithay::wayland::shell::xdg::{
    PopupSurface, PositionerState, SurfaceCachedState, ToplevelSurface, XdgShellHandler,
    XdgShellState, XdgToplevelSurfaceData,
};
use smithay::wayland::shell::xdg::decoration::{XdgDecorationHandler, XdgDecorationState};
use smithay::wayland::shm::{ShmHandler, ShmState};
use smithay::wayland::socket::ListeningSocketSource;
use smithay::wayland::tablet_manager::TabletSeatHandler;
use smithay::wayland::viewporter::ViewporterState;
use smithay::wayland::xwayland_shell::XWaylandShellState;
use smithay::wayland::xwayland_keyboard_grab::XWaylandKeyboardGrabState;
use smithay::wayland::xdg_activation::XdgActivationState;
use smithay::xwayland::{X11Wm, XWayland, XWaylandClientData, XWaylandEvent};
use tracing::{error, info, warn};

#[cfg(feature = "flutter")]
use super::PendingWindowEvent;
use super::RuntimeState;
#[cfg(feature = "flutter")]
use super::flutter_runtime::{ExternalTextureFrame, ShmSnapshotPool, ShmTextureFrame};
#[cfg(feature = "flutter")]
use super::frame_scheduler::FrameTick;
#[cfg(feature = "flutter")]
use super::local_windows::{LocalFlutterWindows, LocalWindowError};
use super::native_shortcut::ShortcutManager;
use super::settings::SettingsManager;
use super::window_grab::{
    MoveSurfaceGrab, ResizeEdges, ResizeSurfaceGrab, X11ResizeSurfaceGrab, checked_pointer_grab,
    constrain_dimension,
};
use super::window_placement_store::{
    RestoredWindowPlacement, WindowIdentity, WindowPlacementState, WindowPlacementStore,
    default_state_path,
};
#[cfg(feature = "flutter")]
use super::wire::{
    InputLayoutSnapshot, SurfaceLayerDescription, SurfaceRoleDescription, WindowAction,
    WindowContentKind, WindowDescription, WindowGeometry, WindowOpacityClass, WindowPlacement,
    WindowPlacementChange, WindowPlacementPhase,
};

#[path = "wayland_frontend/clipboard.rs"]
mod clipboard_io;
#[path = "wayland_frontend/focus.rs"]
mod focus;
#[path = "wayland_frontend/handlers.rs"]
mod handlers;
#[cfg(feature = "flutter")]
#[path = "wayland_frontend/idle_inhibit.rs"]
mod idle_inhibit;
#[path = "wayland_frontend/input.rs"]
mod input;
#[path = "wayland_frontend/input_method.rs"]
pub(super) mod input_method;
#[cfg(feature = "flutter")]
pub(super) use input::{dispatch_shell_keyboard, reconcile_flutter_pointer_route};
#[path = "wayland_frontend/input_source.rs"]
mod input_source;
#[path = "wayland_frontend/output_power.rs"]
mod output_power;
#[path = "wayland_frontend/presentation.rs"]
mod presentation;
#[path = "wayland_frontend/screencopy.rs"]
mod screencopy;
#[cfg(feature = "flutter")]
pub(crate) use screencopy::{copy_atlas_region_to_memory, copy_atlas_to_dmabuf};
#[cfg(feature = "flutter")]
#[path = "wayland_frontend/surface_snapshot.rs"]
mod surface_snapshot;
#[path = "wayland_frontend/text_input.rs"]
mod text_input;
#[path = "wayland_frontend/topology.rs"]
mod topology;
#[path = "wayland_frontend/window_management.rs"]
mod window_management;
#[path = "wayland_frontend/xwayland.rs"]
mod xwayland;

#[cfg(feature = "flutter")]
pub(super) use clipboard_io::{
    DeferredClipboardCapture, apply_clipboard_actions, cancel_clipboard_captures,
};
use focus::KeyboardFocusTarget;
use handlers::{MAX_WAYLAND_CLIENTS, WaylandClientBudget};
#[cfg(feature = "flutter")]
use idle_inhibit::IdleInhibitors;
#[cfg(feature = "flutter")]
use input::{ClientInputRoute, RoutedPointerTarget};
pub(super) use input::{init_libinput, reset_all_input_devices};
#[cfg(feature = "flutter")]
pub(super) use input::{install_keyboard_settings, install_touchpad_settings};
#[cfg(feature = "flutter")]
use input_method::EditorEndpoint;
use input_method::InputMethodManager;
use output_power::OutputPowerManager;
#[cfg(feature = "flutter")]
use surface_snapshot::{rgba_payload_len, shm_cache_budget_for_atlas, snapshot_shm_buffer};
use text_input::{SeatFocusKind, TextInputManager};
pub(super) use topology::saturating_point_add;
use topology::{
    choose_popup_output, clamp_window_geometry, configure_output, output_logical_bounds,
    saturating_point_sub,
};
use window_management::toplevel_has_state;
#[cfg(feature = "flutter")]
pub(super) use window_management::{
    apply_window_commands, queue_local_flutter_window_placement, queue_window_placement,
};
#[cfg(feature = "flutter")]
use window_management::{
    shell_content_geometry, shell_draws_server_frame, shell_draws_x11_server_frame,
};

const MAX_PENDING_DMABUF_IMPORTS: usize = 128;
const XDG_ACTIVATION_TOKEN_LIFETIME: Duration = Duration::from_secs(10);

fn dmabuf_import_queue_has_capacity(pending: usize) -> bool {
    pending < MAX_PENDING_DMABUF_IMPORTS
}

#[cfg(feature = "flutter")]
#[derive(Debug)]
struct OutputWindowMembership<K, V> {
    output_by_window: HashMap<K, OutputId>,
    windows_by_output: HashMap<OutputId, Vec<(K, V)>>,
}

#[cfg(feature = "flutter")]
impl<K, V> Default for OutputWindowMembership<K, V> {
    fn default() -> Self {
        Self {
            output_by_window: HashMap::new(),
            windows_by_output: HashMap::new(),
        }
    }
}

#[cfg(feature = "flutter")]
impl<K: Clone + Eq + Hash, V> OutputWindowMembership<K, V> {
    fn update(&mut self, key: K, value: V, output: Option<OutputId>) -> bool {
        if self.output_by_window.get(&key).copied() == output {
            return false;
        }
        self.remove(&key);
        let Some(output) = output else {
            return true;
        };
        self.output_by_window.insert(key.clone(), output);
        self.windows_by_output
            .entry(output)
            .or_default()
            .push((key, value));
        true
    }

    fn remove(&mut self, key: &K) -> Option<V> {
        let output = self.output_by_window.remove(key)?;
        let windows = self
            .windows_by_output
            .get_mut(&output)
            .expect("window output index lost its output bucket");
        let index = windows
            .iter()
            .position(|(candidate, _)| candidate == key)
            .expect("window output index lost its window entry");
        let (_, value) = windows.swap_remove(index);
        if windows.is_empty() {
            self.windows_by_output.remove(&output);
        }
        Some(value)
    }

    fn clear(&mut self) {
        self.output_by_window.clear();
        self.windows_by_output.clear();
    }

    fn windows(&self, output: OutputId) -> impl Iterator<Item = &V> {
        self.windows_by_output
            .get(&output)
            .into_iter()
            .flatten()
            .map(|(_, window)| window)
    }
}

#[cfg(feature = "flutter")]
fn software_cursor_shape(status: &CursorImageStatus) -> &'static str {
    match status {
        CursorImageStatus::Hidden => "none",
        CursorImageStatus::Named(icon) => icon.name(),
        // A client-owned cursor surface cannot be represented by the current
        // CursorShape wire payload.  Keep exactly one cursor renderer (Dart)
        // and use its neutral arrow rather than drawing the surface a second
        // time in the compositor atlas.
        CursorImageStatus::Surface(_) => "default",
    }
}

#[cfg(feature = "flutter")]
fn accepted_flutter_cursor_shape(
    target: RoutedPointerTarget,
    shape: &'static str,
) -> Option<&'static str> {
    matches!(target, RoutedPointerTarget::Flutter).then_some(shape)
}

#[cfg(feature = "flutter")]
fn cursor_shape_for_modality(pointer_visible: bool, active_shape: &'static str) -> &'static str {
    if pointer_visible {
        active_shape
    } else {
        "none"
    }
}

#[cfg(feature = "flutter")]
fn cursor_position_for_modality(pointer_visible: bool, position: (f64, f64)) -> Option<(f64, f64)> {
    pointer_visible.then_some(position)
}

pub(super) struct WaylandFrontend {
    pub start_time: Instant,
    socket_name: OsString,
    loop_handle: LoopHandle<'static, RuntimeState>,
    pub display_handle: DisplayHandle,
    pub space: Space<Window>,
    pub compositor_state: CompositorState,
    pub xdg_shell_state: XdgShellState,
    pub xdg_activation_state: XdgActivationState,
    pub xwayland_shell_state: XWaylandShellState,
    pub _xwayland_keyboard_grab_state: XWaylandKeyboardGrabState,
    pub _relative_pointer_manager_state: RelativePointerManagerState,
    pub _pointer_constraints_state: PointerConstraintsState,
    _viewporter_state: ViewporterState,
    _fractional_scale_manager_state: FractionalScaleManagerState,
    pub xwm: Option<X11Wm>,
    xwayland_client: Client,
    xwayland_scale: u32,
    xdisplay: u32,
    _xdg_decoration_state: XdgDecorationState,
    _cursor_shape_state: CursorShapeManagerState,
    pub shm_state: ShmState,
    pub dmabuf_state: DmabufState,
    drm_syncobj_state: Option<DrmSyncobjState>,
    dmabuf_global: Option<DmabufGlobal>,
    dmabuf_render_node: Option<DrmNode>,
    pending_dmabuf_imports: Vec<(Dmabuf, ImportNotifier)>,
    dmabuf_import_queue_saturated: bool,
    surface_buffers: HashMap<ObjectId, wl_buffer::WlBuffer>,
    #[cfg(feature = "flutter")]
    surface_shm_frames: HashMap<ObjectId, ShmTextureFrame>,
    #[cfg(feature = "flutter")]
    shm_snapshot_pool: Arc<ShmSnapshotPool>,
    #[cfg(feature = "flutter")]
    shm_snapshot_bytes: usize,
    #[cfg(feature = "flutter")]
    shm_snapshot_budget_bytes: usize,
    #[cfg(feature = "flutter")]
    next_shm_revision: u64,
    #[cfg(feature = "flutter")]
    pending_surface_commits: HashMap<ObjectId, SurfaceCommitKind>,
    #[cfg(feature = "flutter")]
    committed_surfaces_scratch: Vec<WlSurface>,
    #[cfg(feature = "flutter")]
    published_surface_ids_scratch: Vec<u64>,
    #[cfg(feature = "flutter")]
    scene_windows_scratch: Vec<WindowDescription>,
    #[cfg(feature = "flutter")]
    scene_textures_scratch: Vec<ExternalTextureFrame>,
    #[cfg(feature = "flutter")]
    scene_popups_scratch: Vec<(PopupKind, Point<i32, Logical>)>,
    #[cfg(feature = "flutter")]
    scene_surface_windows: HashMap<u64, u64>,
    #[cfg(feature = "flutter")]
    scene_surface_windows_scratch: HashMap<u64, u64>,
    #[cfg(feature = "flutter")]
    scene_complex_windows: HashSet<u64>,
    #[cfg(feature = "flutter")]
    scene_complex_windows_scratch: HashSet<u64>,
    #[cfg(feature = "flutter")]
    output_window_membership: OutputWindowMembership<ObjectId, Window>,
    #[cfg(feature = "flutter")]
    local_windows: LocalFlutterWindows,
    #[cfg(feature = "flutter")]
    pending_shm_snapshots: HashSet<ObjectId>,
    #[cfg(feature = "flutter")]
    surface_buffer_revisions: HashMap<ObjectId, u64>,
    #[cfg(feature = "flutter")]
    next_buffer_revision: u64,
    surface_ids: HashMap<ObjectId, u64>,
    surfaces_by_id: HashMap<u64, WlSurface>,
    next_surface_id: u64,
    configured_window_geometries: HashMap<ObjectId, Rectangle<i32, Logical>>,
    exact_window_geometries: HashMap<ObjectId, Rectangle<i32, Logical>>,
    restore_window_geometries: HashMap<ObjectId, Rectangle<i32, Logical>>,
    #[cfg(feature = "flutter")]
    shell_maximize_restore_geometries: HashMap<ObjectId, Rectangle<i32, Logical>>,
    #[cfg(feature = "flutter")]
    shell_fullscreen_restore_geometries: HashMap<ObjectId, Rectangle<i32, Logical>>,
    #[cfg(feature = "flutter")]
    shell_vertical_restore_geometries: HashMap<ObjectId, (i32, i32)>,
    #[cfg(feature = "flutter")]
    local_vertical_restore_geometries: HashMap<u64, (f64, f64)>,
    #[cfg(feature = "flutter")]
    input_layout: Option<InputLayoutSnapshot>,
    #[cfg(feature = "flutter")]
    shell_fullscreen_locks: HashSet<ObjectId>,
    #[cfg(feature = "flutter")]
    visible_window_ids: HashSet<u64>,
    #[cfg(feature = "flutter")]
    input_root_ids_scratch: HashMap<ObjectId, u64>,
    #[cfg(feature = "flutter")]
    input_visibility_known: bool,
    #[cfg(feature = "flutter")]
    client_input_route_cache: Option<ClientInputRoute>,
    #[cfg(feature = "flutter")]
    client_pointer_capture: Option<ClientInputRoute>,
    #[cfg(feature = "flutter")]
    pointer_constraint_escape: input::PointerConstraintEscape,
    #[cfg(feature = "flutter")]
    client_pointer_buttons: HashSet<u32>,
    #[cfg(feature = "flutter")]
    retired_pointer_buttons: HashSet<u32>,
    #[cfg(feature = "flutter")]
    client_pointer_presses: Vec<input::ClientPointerPress>,
    #[cfg(feature = "flutter")]
    flutter_pointer_press: Option<FlutterPointerPress>,
    #[cfg(feature = "flutter")]
    clipboard_drag_active: bool,
    wayland_pointer_buttons: HashSet<u32>,
    #[cfg(feature = "flutter")]
    routed_pointer_target: RoutedPointerTarget,
    /// Whether the most recent pointing modality is a physical pointer.
    ///
    /// Layout reconciliation may route Smithay's stored pointer location even
    /// when no mouse or touchpad has produced input.  Keep that protocol state
    /// independent from cursor visibility so opening a client cannot invent a
    /// cursor on a touch-only system.
    #[cfg(feature = "flutter")]
    pointer_cursor_visible: bool,
    /// Last-writer-wins handoff from the routed pointer owner's cursor request
    /// to the Flutter-owned software cursor.
    #[cfg(feature = "flutter")]
    pending_cursor_shape: Option<&'static str>,
    #[cfg(feature = "flutter")]
    published_cursor_shape: Option<&'static str>,
    /// Latest compositor-authoritative pointer position for cursor painting
    /// while Flutter pointer hit testing is intentionally inactive.
    ///
    /// This bypasses Flutter hit testing while a Wayland client owns input.
    #[cfg(feature = "flutter")]
    pending_cursor_position: Option<(f64, f64)>,
    #[cfg(feature = "flutter")]
    flutter_touch_slots: HashSet<i32>,
    #[cfg(feature = "flutter")]
    client_touch_routes: HashMap<i32, ClientInputRoute>,
    #[cfg(feature = "flutter")]
    client_touch_frame_pending: bool,
    #[cfg(feature = "flutter")]
    flutter_keyboard_keys: HashSet<u32>,
    #[cfg(feature = "flutter")]
    shell_keyboard_keys: HashSet<u32>,
    #[cfg(feature = "flutter")]
    flutter_compose: Option<xkb::compose::State>,
    #[cfg(feature = "flutter")]
    flutter_repeat_key: Option<u32>,
    #[cfg(feature = "flutter")]
    flutter_repeat_generation: u64,
    #[cfg(feature = "flutter")]
    flutter_repeat_token: Option<RegistrationToken>,
    retired_keyboard_keys: HashSet<u32>,
    #[cfg(feature = "flutter")]
    minimized_windows: HashSet<ObjectId>,
    window_placements: WindowPlacementStore,
    restored_window_positions: HashSet<ObjectId>,
    client_geometry_state_requests: HashSet<ObjectId>,
    pending_client_sized_placements: HashMap<ObjectId, PendingClientSizedPlacement>,
    pub _output_manager_state: OutputManagerState,
    pub seat_state: SeatState<RuntimeState>,
    pub data_device_state: DataDeviceState,
    pub popups: PopupManager,
    pub seat: Seat<RuntimeState>,
    pub(super) settings: SettingsManager,
    pub(super) shortcuts: ShortcutManager,
    pub(super) keyboard_layout_names: Vec<String>,
    pub(super) active_keyboard_layout: usize,
    pub(super) keyboard_configuration_changed: bool,
    presentation: presentation::PresentationTracker,
    #[cfg(feature = "flutter")]
    idle_inhibitors: IdleInhibitors,
    output_power: OutputPowerManager,
    screencopy: screencopy::ScreencopyManager,
    text_input: TextInputManager,
    input_method: InputMethodManager,
    outputs: Vec<WaylandOutput>,
    work_area: crate::options::WorkAreaOptions,
    ticker_output: Option<OutputId>,
    pub atlas_output: Output,
    damage_tracker: OutputDamageTracker,
    next_window_offset: i32,
    desktop_bounds: smithay::utils::Rectangle<i32, Logical>,
    touch_bounds: smithay::utils::Rectangle<i32, Logical>,
    pointer_location: Point<f64, Logical>,
    cursor_status: CursorImageStatus,
    atlas_origin: Point<f64, Logical>,
    atlas_scale: f64,
    atlas_size: Size<i32, Physical>,
}

#[cfg(feature = "flutter")]
#[derive(Clone, Copy, Debug)]
struct FlutterPointerPress {
    button: u32,
    serial: Serial,
    time: u32,
    location: Point<f64, Logical>,
}

#[cfg(feature = "flutter")]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum ShellFullscreenTransition {
    EnterShell,
    ExitShell,
    ExitClient,
    Blocked,
}

#[cfg(feature = "flutter")]
fn shell_fullscreen_transition(
    client_fullscreen: bool,
    shell_fullscreen: bool,
    geometry_locked: bool,
) -> ShellFullscreenTransition {
    if client_fullscreen {
        return ShellFullscreenTransition::ExitClient;
    }
    if shell_fullscreen {
        return ShellFullscreenTransition::ExitShell;
    }
    if geometry_locked {
        return ShellFullscreenTransition::Blocked;
    }
    ShellFullscreenTransition::EnterShell
}

struct WaylandOutput {
    id: OutputId,
    connector: String,
    output: Output,
    global: GlobalId,
    logical_geometry: Rectangle<i32, Logical>,
    capture_source: Rectangle<i32, Physical>,
    capture_size: Size<i32, Physical>,
    powered: bool,
    #[cfg(feature = "flutter")]
    presentation_batch: presentation::OutputPresentationBatch,
    #[cfg(feature = "flutter")]
    submitted_this_batch: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum InitialXdgPlacementPolicy {
    SkipSaved,
    ClientSized,
    RestoreShellState,
}

fn initial_xdg_placement_policy(
    has_parent: bool,
    has_same_app_sibling: bool,
    initial_configure_sent: bool,
    client_state_request_seen: bool,
    client_state: WindowPlacementState,
    saved_state: WindowPlacementState,
) -> InitialXdgPlacementPolicy {
    if has_parent
        || has_same_app_sibling
        || initial_configure_sent
        || client_state.maximized
        || client_state.fullscreen
    {
        return InitialXdgPlacementPolicy::SkipSaved;
    }
    if !client_state_request_seen && (saved_state.maximized || saved_state.fullscreen) {
        InitialXdgPlacementPolicy::RestoreShellState
    } else {
        InitialXdgPlacementPolicy::ClientSized
    }
}

#[derive(Clone, Copy)]
struct PendingClientSizedPlacement {
    requested_location: Point<i32, Logical>,
    output_id: OutputId,
}

#[cfg(feature = "flutter")]
#[derive(Clone, Copy)]
struct SurfaceTreeContext {
    location: Point<i32, Logical>,
    parent_surface_id: u64,
}

#[cfg(feature = "flutter")]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SurfaceCommitKind {
    BufferOnly,
    Metadata,
}

#[cfg(feature = "flutter")]
const BORDER_ALPHA_MAX_INSET: i32 = 16;
#[cfg(feature = "flutter")]
const BORDER_ALPHA_MIN_COVERAGE_PERCENT: i64 = 90;

#[cfg(feature = "flutter")]
fn classify_window_opacity(
    surface_bounds: Rectangle<i32, Logical>,
    content: Rectangle<i32, Logical>,
    opaque_regions: Option<&[Rectangle<i32, Logical>]>,
    opacity: f32,
) -> WindowOpacityClass {
    if opacity < 1.0 || content.size.w <= 0 || content.size.h <= 0 {
        return WindowOpacityClass::ContentTranslucent;
    }
    if !surface_bounds.contains_rect(content) {
        return WindowOpacityClass::ContentTranslucent;
    }
    let Some(opaque_regions) = opaque_regions else {
        return WindowOpacityClass::ContentTranslucent;
    };

    let missing = content.subtract_rects(opaque_regions.iter().copied());
    if missing.is_empty() {
        return WindowOpacityClass::FullyOpaque;
    }

    let content_area = i64::from(content.size.w) * i64::from(content.size.h);
    let missing_area = missing
        .iter()
        .map(|rect| i64::from(rect.size.w) * i64::from(rect.size.h))
        .sum::<i64>();
    let opaque_area = content_area.saturating_sub(missing_area);
    if opaque_area.saturating_mul(100)
        < content_area.saturating_mul(BORDER_ALPHA_MIN_COVERAGE_PERCENT)
    {
        return WindowOpacityClass::ContentTranslucent;
    }

    // XDG window geometry already removes client-side shadow padding. Permit
    // only a narrow residual edge band for rounded corners and decoration
    // antialiasing; any unknown alpha reaching the interior remains genuinely
    // content-translucent.
    let inset = (content.size.w.min(content.size.h) / 10).clamp(1, BORDER_ALPHA_MAX_INSET);
    let interior_size = (content.size.w - inset * 2, content.size.h - inset * 2);
    if interior_size.0 <= 0 || interior_size.1 <= 0 {
        return WindowOpacityClass::ContentTranslucent;
    }
    let interior = Rectangle::new(
        (content.loc.x + inset, content.loc.y + inset).into(),
        interior_size.into(),
    );
    if interior
        .subtract_rects(opaque_regions.iter().copied())
        .is_empty()
    {
        WindowOpacityClass::BorderAlphaOnly
    } else {
        WindowOpacityClass::ContentTranslucent
    }
}

#[cfg(feature = "flutter")]
impl SurfaceCommitKind {
    const fn merge(self, next: Self) -> Self {
        if matches!(self, Self::Metadata) || matches!(next, Self::Metadata) {
            Self::Metadata
        } else {
            Self::BufferOnly
        }
    }
}

#[cfg(feature = "flutter")]
struct PublishedSurfaceCommits {
    metadata_changed: bool,
    buffer_surface_ids: Vec<u64>,
}

#[cfg(feature = "flutter")]
fn input_routing_changed(
    current: Option<&InputLayoutSnapshot>,
    next: &InputLayoutSnapshot,
) -> bool {
    current.is_none_or(|current| {
        current.flags != next.flags
            || current.shell_regions != next.shell_regions
            || current.software_keyboard_regions != next.software_keyboard_regions
            || current.windows != next.windows
    })
}

#[cfg(feature = "flutter")]
fn input_visibility_changed(
    current: Option<&InputLayoutSnapshot>,
    next: &InputLayoutSnapshot,
) -> bool {
    current.is_none_or(|current| current.visible_surface_ids != next.visible_surface_ids)
}

#[cfg(feature = "flutter")]
fn window_expects_sample(
    input_visibility_known: bool,
    visible_window_ids: &HashSet<u64>,
    window_id: u64,
) -> bool {
    !input_visibility_known || visible_window_ids.contains(&window_id)
}

#[cfg(feature = "flutter")]
fn flutter_compose_state() -> Option<xkb::compose::State> {
    let locale = ["LC_ALL", "LC_CTYPE", "LANG"]
        .into_iter()
        .filter_map(std::env::var_os)
        .find(|value| !value.is_empty())
        .unwrap_or_else(|| OsString::from("C.UTF-8"));
    let context = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
    match xkb::compose::Table::new_from_locale(&context, &locale, xkb::compose::COMPILE_NO_FLAGS) {
        Ok(table) => Some(xkb::compose::State::new(
            &table,
            xkb::compose::STATE_NO_FLAGS,
        )),
        Err(()) => {
            warn!(
                ?locale,
                "XKB Compose table is unavailable for Flutter input"
            );
            None
        }
    }
}

impl WaylandFrontend {
    pub fn new(
        event_loop: &mut EventLoop<'static, RuntimeState>,
        snapshot: &TopologySnapshot,
        session: LibSeatSession,
        seat_name: &str,
        drm_device: DrmDeviceFd,
        work_area: crate::options::WorkAreaOptions,
        settings: SettingsManager,
        shortcuts: ShortcutManager,
    ) -> Result<Self, Box<dyn Error>> {
        let display = Display::<RuntimeState>::new()?;
        let display_handle = display.handle();
        let loop_handle = event_loop.handle();
        let compositor_state = CompositorState::new::<RuntimeState>(&display_handle);
        let xdg_shell_state = XdgShellState::new::<RuntimeState>(&display_handle);
        let xdg_activation_state = XdgActivationState::new::<RuntimeState>(&display_handle);
        let xwayland_shell_state = XWaylandShellState::new::<RuntimeState>(&display_handle);
        let xwayland_keyboard_grab_state =
            XWaylandKeyboardGrabState::new::<RuntimeState>(&display_handle);
        let relative_pointer_manager_state =
            RelativePointerManagerState::new::<RuntimeState>(&display_handle);
        let pointer_constraints_state =
            PointerConstraintsState::new::<RuntimeState>(&display_handle);
        let viewporter_state = ViewporterState::new::<RuntimeState>(&display_handle);
        let fractional_scale_manager_state =
            FractionalScaleManagerState::new::<RuntimeState>(&display_handle);
        let xdg_decoration_state = XdgDecorationState::new::<RuntimeState>(&display_handle);
        let cursor_shape_state = CursorShapeManagerState::new::<RuntimeState>(&display_handle);
        let presentation = presentation::PresentationTracker::new(&display_handle);
        #[cfg(feature = "flutter")]
        let idle_inhibitors = IdleInhibitors::new(&display_handle);
        let output_power = OutputPowerManager::new(&display_handle);
        let screencopy = screencopy::ScreencopyManager::new(&display_handle);
        let text_input = TextInputManager::new(&display_handle);
        let input_method = InputMethodManager::new(&display_handle);
        let shm_state = ShmState::new::<RuntimeState>(&display_handle, vec![]);
        let dmabuf_state = DmabufState::new();
        let drm_syncobj_state = if supports_syncobj_eventfd(&drm_device) {
            info!("advertising linux-drm-syncobj-v1 explicit synchronization");
            Some(DrmSyncobjState::new::<RuntimeState>(
                &display_handle,
                drm_device,
            ))
        } else {
            warn!("DRM syncobj eventfd is unavailable; retaining implicit DMA-BUF synchronization");
            None
        };
        let output_manager_state =
            OutputManagerState::new_with_xdg_output::<RuntimeState>(&display_handle);
        let data_device_state = DataDeviceState::new::<RuntimeState>(&display_handle);
        let mut seat_state = SeatState::new();
        let mut seat = seat_state.new_wl_seat(&display_handle, "seat0");
        let keyboard = settings.keyboard();
        let keyboard_layout_names = keyboard.compiled_layout_names()?;
        let xkb_names = keyboard.xkb_names();
        #[cfg(feature = "flutter")]
        let flutter_compose = flutter_compose_state();
        // Supplying every field explicitly makes the compositor configuration
        // independent of XKB_DEFAULT_* inherited from a display manager.
        seat.add_keyboard(
            XkbConfig {
                rules: "evdev",
                model: "pc105",
                layout: &xkb_names.layout,
                variant: &xkb_names.variant,
                options: Some(xkb_names.options),
            },
            i32::try_from(keyboard.repeat_delay_ms)?,
            i32::try_from(keyboard.repeat_rate_hz)?,
        )?;
        seat.add_pointer();
        seat.add_touch();
        let popups = PopupManager::default();
        let mut space = Space::default();

        let logical_bounds = snapshot.logical_bounds.ok_or("Wayland topology is empty")?;
        let desktop_bounds = smithay::utils::Rectangle::new(
            (
                logical_bounds.x.round() as i32,
                logical_bounds.y.round() as i32,
            )
                .into(),
            (
                logical_bounds.width.round().max(1.0) as i32,
                logical_bounds.height.round().max(1.0) as i32,
            )
                .into(),
        );
        let pointer_location = Point::from((
            f64::from(desktop_bounds.loc.x) + f64::from(desktop_bounds.size.w) / 2.0,
            f64::from(desktop_bounds.loc.y) + f64::from(desktop_bounds.size.h) / 2.0,
        ));
        let touch_bounds = snapshot
            .outputs
            .first()
            .map(|output| {
                let rect = output.logical_rect();
                Rectangle::new(
                    (rect.x.round() as i32, rect.y.round() as i32).into(),
                    (
                        rect.width.round().max(1.0) as i32,
                        rect.height.round().max(1.0) as i32,
                    )
                        .into(),
                )
            })
            .unwrap_or(desktop_bounds);

        let atlas = AtlasPlan::for_snapshot(snapshot).ok_or("Wayland topology has no atlas")?;
        let mut outputs = Vec::with_capacity(snapshot.outputs.len());
        for spec in &snapshot.outputs {
            let capture = atlas
                .outputs
                .iter()
                .find(|output| output.id == spec.id)
                .ok_or("Wayland output is missing from the atlas plan")?;
            let output = Output::new(
                spec.name.clone(),
                PhysicalProperties {
                    size: (0, 0).into(),
                    subpixel: Subpixel::Unknown,
                    make: "Denial".into(),
                    model: spec.name.clone(),
                    serial_number: format!("connector-{}", spec.id.0),
                },
            );
            configure_output(&output, spec)?;
            let global = output.create_global::<RuntimeState>(&display_handle);
            space.map_output(&output, (spec.position.x, spec.position.y));
            outputs.push(WaylandOutput {
                id: spec.id,
                connector: spec.name.clone(),
                output,
                global,
                logical_geometry: output_logical_bounds(spec),
                capture_source: Rectangle::new(
                    (
                        i32::try_from(capture.source_rect.x)?,
                        i32::try_from(capture.source_rect.y)?,
                    )
                        .into(),
                    (
                        i32::try_from(capture.source_rect.width)?,
                        i32::try_from(capture.source_rect.height)?,
                    )
                        .into(),
                ),
                capture_size: (
                    i32::try_from(capture.scanout_size.width)?,
                    i32::try_from(capture.scanout_size.height)?,
                )
                    .into(),
                powered: true,
                #[cfg(feature = "flutter")]
                presentation_batch: presentation::OutputPresentationBatch::new(),
                #[cfg(feature = "flutter")]
                submitted_this_batch: false,
            });
        }

        #[cfg(feature = "flutter")]
        let shm_snapshot_budget_bytes =
            shm_cache_budget_for_atlas(atlas.pixel_size.width, atlas.pixel_size.height);
        let atlas_mode = Mode {
            size: (
                i32::try_from(atlas.pixel_size.width)?,
                i32::try_from(atlas.pixel_size.height)?,
            )
                .into(),
            refresh: snapshot
                .outputs
                .iter()
                .map(|output| output.refresh_millihz)
                .max()
                .map(i32::try_from)
                .transpose()?
                .unwrap_or(60_000),
        };
        let atlas_output = Output::new(
            "denial-atlas".into(),
            PhysicalProperties {
                size: (0, 0).into(),
                subpixel: Subpixel::Unknown,
                make: "Denial".into(),
                model: "Shared scene atlas".into(),
                serial_number: "internal".into(),
            },
        );
        atlas_output.change_current_state(
            Some(atlas_mode),
            Some(Transform::Normal),
            Some(Scale::Fractional(
                atlas.engine_scale_120 as f64 / denial_core::topology::SCALE_BASE as f64,
            )),
            Some(
                (
                    atlas.logical_origin.0.round() as i32,
                    atlas.logical_origin.1.round() as i32,
                )
                    .into(),
            ),
        );
        atlas_output.set_preferred(atlas_mode);
        space.map_output(
            &atlas_output,
            (
                atlas.logical_origin.0.round() as i32,
                atlas.logical_origin.1.round() as i32,
            ),
        );
        let damage_tracker = OutputDamageTracker::from_output(&atlas_output);
        let atlas_origin = Point::from(atlas.logical_origin);
        let atlas_scale = atlas.engine_scale_120 as f64 / denial_core::topology::SCALE_BASE as f64;
        let atlas_size = Size::from((
            i32::try_from(atlas.pixel_size.width)?,
            i32::try_from(atlas.pixel_size.height)?,
        ));

        let client_budget = Arc::new(WaylandClientBudget::default());
        let socket_name = init_listener(display, event_loop, client_budget)?;
        let xwayland_scale = xwayland::scale_for_engine(atlas.engine_scale_120);
        let xwayland_dpi = xwayland::dpi(xwayland_scale);
        let xwayland_args = ["-dpi".to_owned(), xwayland_dpi.to_string()];
        let (xwayland, xwayland_client) = XWayland::spawn(
            &display_handle,
            None,
            std::iter::empty::<(String, String)>(),
            xwayland_args,
            true,
            Stdio::null(),
            Stdio::null(),
            |_| {},
        )?;
        xwayland_client
            .get_data::<XWaylandClientData>()
            .expect("Xwayland client is missing compositor state")
            .compositor_state
            .set_client_scale(f64::from(xwayland_scale));
        let xdisplay = xwayland.display_number();
        let window_placement_path = default_state_path();
        let window_placements = match WindowPlacementStore::load(window_placement_path.clone()) {
            Ok(store) => store,
            Err(error) => {
                warn!(
                    %error,
                    path = ?window_placement_path,
                    "could not load saved window placements; starting with an empty store"
                );
                WindowPlacementStore::empty(window_placement_path)
            }
        };
        if window_placements.len() > 0 {
            info!(
                placements = window_placements.len(),
                "loaded saved window placements"
            );
        }
        let xwm_loop_handle = event_loop.handle();
        let xwm_display_handle = display_handle.clone();
        let xwm_client = xwayland_client.clone();
        event_loop
            .handle()
            .insert_source(xwayland, move |event, _, state| match event {
                XWaylandEvent::Ready {
                    x11_socket,
                    display_number,
                } => match X11Wm::start_wm(
                    xwm_loop_handle.clone(),
                    &xwm_display_handle,
                    x11_socket,
                    xwm_client.clone(),
                ) {
                    Ok(mut xwm) => {
                        let Some(frontend) = state.wayland.as_mut() else {
                            error!(
                                display_number,
                                "Xwayland became ready without Wayland frontend state"
                            );
                            return;
                        };
                        if let Err(error) = xwayland::publish_dpi(&mut xwm, frontend.xwayland_scale)
                        {
                            error!(%error, "could not publish Xwayland DPI settings");
                        }
                        frontend.xwm = Some(xwm);
                        info!(
                            display = %format_args!(":{display_number}"),
                            scale = frontend.xwayland_scale,
                            dpi = xwayland::dpi(frontend.xwayland_scale),
                            "Xwayland is ready"
                        );
                        state.scene_sync.mark_dirty();
                    }
                    Err(error) => {
                        error!(
                            %error,
                            display_number,
                            "could not start the Xwayland window manager"
                        );
                    }
                },
                XWaylandEvent::Error => {
                    error!(
                        display = %format_args!(":{xdisplay}"),
                        "Xwayland exited during startup"
                    );
                }
            })?;
        init_libinput(event_loop, session, seat_name)?;
        Ok(Self {
            start_time: Instant::now(),
            socket_name,
            loop_handle,
            display_handle,
            space,
            compositor_state,
            xdg_shell_state,
            xdg_activation_state,
            xwayland_shell_state,
            _xwayland_keyboard_grab_state: xwayland_keyboard_grab_state,
            _relative_pointer_manager_state: relative_pointer_manager_state,
            _pointer_constraints_state: pointer_constraints_state,
            _viewporter_state: viewporter_state,
            _fractional_scale_manager_state: fractional_scale_manager_state,
            xwm: None,
            xwayland_client,
            xwayland_scale,
            xdisplay,
            _xdg_decoration_state: xdg_decoration_state,
            _cursor_shape_state: cursor_shape_state,
            shm_state,
            dmabuf_state,
            drm_syncobj_state,
            dmabuf_global: None,
            dmabuf_render_node: None,
            pending_dmabuf_imports: Vec::new(),
            dmabuf_import_queue_saturated: false,
            surface_buffers: HashMap::new(),
            #[cfg(feature = "flutter")]
            surface_shm_frames: HashMap::new(),
            #[cfg(feature = "flutter")]
            shm_snapshot_pool: Arc::new(ShmSnapshotPool::new()),
            #[cfg(feature = "flutter")]
            shm_snapshot_bytes: 0,
            #[cfg(feature = "flutter")]
            shm_snapshot_budget_bytes,
            #[cfg(feature = "flutter")]
            next_shm_revision: 1,
            #[cfg(feature = "flutter")]
            pending_surface_commits: HashMap::new(),
            #[cfg(feature = "flutter")]
            committed_surfaces_scratch: Vec::new(),
            #[cfg(feature = "flutter")]
            published_surface_ids_scratch: Vec::new(),
            #[cfg(feature = "flutter")]
            scene_windows_scratch: Vec::new(),
            #[cfg(feature = "flutter")]
            scene_textures_scratch: Vec::new(),
            #[cfg(feature = "flutter")]
            scene_popups_scratch: Vec::new(),
            #[cfg(feature = "flutter")]
            scene_surface_windows: HashMap::new(),
            #[cfg(feature = "flutter")]
            scene_surface_windows_scratch: HashMap::new(),
            #[cfg(feature = "flutter")]
            scene_complex_windows: HashSet::new(),
            #[cfg(feature = "flutter")]
            scene_complex_windows_scratch: HashSet::new(),
            #[cfg(feature = "flutter")]
            output_window_membership: OutputWindowMembership::default(),
            #[cfg(feature = "flutter")]
            local_windows: LocalFlutterWindows::default(),
            #[cfg(feature = "flutter")]
            pending_shm_snapshots: HashSet::new(),
            #[cfg(feature = "flutter")]
            surface_buffer_revisions: HashMap::new(),
            #[cfg(feature = "flutter")]
            next_buffer_revision: 1,
            surface_ids: HashMap::new(),
            surfaces_by_id: HashMap::new(),
            next_surface_id: 1,
            configured_window_geometries: HashMap::new(),
            exact_window_geometries: HashMap::new(),
            restore_window_geometries: HashMap::new(),
            #[cfg(feature = "flutter")]
            shell_maximize_restore_geometries: HashMap::new(),
            #[cfg(feature = "flutter")]
            shell_fullscreen_restore_geometries: HashMap::new(),
            #[cfg(feature = "flutter")]
            shell_vertical_restore_geometries: HashMap::new(),
            #[cfg(feature = "flutter")]
            local_vertical_restore_geometries: HashMap::new(),
            #[cfg(feature = "flutter")]
            input_layout: None,
            #[cfg(feature = "flutter")]
            shell_fullscreen_locks: HashSet::new(),
            #[cfg(feature = "flutter")]
            visible_window_ids: HashSet::new(),
            #[cfg(feature = "flutter")]
            input_root_ids_scratch: HashMap::new(),
            #[cfg(feature = "flutter")]
            input_visibility_known: false,
            #[cfg(feature = "flutter")]
            client_input_route_cache: None,
            #[cfg(feature = "flutter")]
            client_pointer_capture: None,
            #[cfg(feature = "flutter")]
            pointer_constraint_escape: input::PointerConstraintEscape::default(),
            #[cfg(feature = "flutter")]
            client_pointer_buttons: HashSet::new(),
            #[cfg(feature = "flutter")]
            retired_pointer_buttons: HashSet::new(),
            #[cfg(feature = "flutter")]
            client_pointer_presses: Vec::new(),
            #[cfg(feature = "flutter")]
            flutter_pointer_press: None,
            #[cfg(feature = "flutter")]
            clipboard_drag_active: false,
            wayland_pointer_buttons: HashSet::new(),
            #[cfg(feature = "flutter")]
            routed_pointer_target: RoutedPointerTarget::Flutter,
            #[cfg(feature = "flutter")]
            pointer_cursor_visible: false,
            #[cfg(feature = "flutter")]
            pending_cursor_shape: Some("none"),
            #[cfg(feature = "flutter")]
            published_cursor_shape: None,
            #[cfg(feature = "flutter")]
            pending_cursor_position: None,
            #[cfg(feature = "flutter")]
            flutter_touch_slots: HashSet::new(),
            #[cfg(feature = "flutter")]
            client_touch_routes: HashMap::new(),
            #[cfg(feature = "flutter")]
            client_touch_frame_pending: false,
            #[cfg(feature = "flutter")]
            flutter_keyboard_keys: HashSet::new(),
            #[cfg(feature = "flutter")]
            shell_keyboard_keys: HashSet::new(),
            #[cfg(feature = "flutter")]
            flutter_compose,
            #[cfg(feature = "flutter")]
            flutter_repeat_key: None,
            #[cfg(feature = "flutter")]
            flutter_repeat_generation: 0,
            #[cfg(feature = "flutter")]
            flutter_repeat_token: None,
            retired_keyboard_keys: HashSet::new(),
            #[cfg(feature = "flutter")]
            minimized_windows: HashSet::new(),
            window_placements,
            restored_window_positions: HashSet::new(),
            client_geometry_state_requests: HashSet::new(),
            pending_client_sized_placements: HashMap::new(),
            _output_manager_state: output_manager_state,
            seat_state,
            data_device_state,
            popups,
            seat,
            settings,
            shortcuts,
            keyboard_layout_names,
            active_keyboard_layout: 0,
            keyboard_configuration_changed: false,
            presentation,
            #[cfg(feature = "flutter")]
            idle_inhibitors,
            output_power,
            screencopy,
            text_input,
            input_method,
            outputs,
            work_area,
            ticker_output: snapshot.ticker,
            atlas_output,
            damage_tracker,
            next_window_offset: 48,
            desktop_bounds,
            touch_bounds,
            pointer_location,
            cursor_status: CursorImageStatus::default_named(),
            atlas_origin,
            atlas_scale,
            atlas_size,
        })
    }

    #[cfg(feature = "flutter")]
    fn update_cursor_image(&mut self, image: CursorImageStatus) {
        let shape = if self.clipboard_drag_active {
            "default"
        } else {
            software_cursor_shape(&image)
        };
        self.cursor_status = image;
        if self.pointer_cursor_visible
            && matches!(self.routed_pointer_target, RoutedPointerTarget::Client(_))
        {
            self.queue_cursor_shape(shape);
        }
    }

    #[cfg(feature = "flutter")]
    fn queue_cursor_shape(&mut self, shape: &'static str) {
        if self.pending_cursor_shape == Some(shape)
            || (self.pending_cursor_shape.is_none() && self.published_cursor_shape == Some(shape))
        {
            return;
        }
        self.pending_cursor_shape = Some(shape);
    }

    #[cfg(feature = "flutter")]
    pub(super) fn request_flutter_cursor_shape(&mut self, shape: &'static str) {
        if !self.pointer_cursor_visible {
            return;
        }
        if self.clipboard_drag_active {
            self.queue_cursor_shape("default");
            return;
        }
        if let Some(shape) = accepted_flutter_cursor_shape(self.routed_pointer_target, shape) {
            self.queue_cursor_shape(shape);
        }
    }

    #[cfg(feature = "flutter")]
    pub(super) fn set_clipboard_drag_active(&mut self, active: bool) {
        if self.clipboard_drag_active == active {
            if active && self.pointer_cursor_visible {
                self.queue_cursor_shape("default");
            }
            return;
        }
        self.clipboard_drag_active = active;
        self.published_cursor_shape = None;
        self.pending_cursor_shape = if !self.pointer_cursor_visible {
            Some("none")
        } else if active {
            Some("default")
        } else {
            match self.routed_pointer_target {
                RoutedPointerTarget::Flutter => None,
                RoutedPointerTarget::Client(_) => Some(software_cursor_shape(&self.cursor_status)),
            }
        };
    }

    #[cfg(feature = "flutter")]
    fn set_routed_pointer_target(&mut self, target: RoutedPointerTarget) {
        if self.routed_pointer_target == target {
            return;
        }
        self.routed_pointer_target = target;
        self.published_cursor_shape = None;
        if !self.pointer_cursor_visible {
            self.pending_cursor_shape = Some("none");
            self.pending_cursor_position = None;
            return;
        }
        if self.clipboard_drag_active {
            self.pending_cursor_shape = Some("default");
            return;
        }
        match target {
            // Dart's MouseRegion owns cursor selection again.  Discard a
            // client update which has not crossed the bridge yet so it cannot
            // overwrite the newer Flutter shape after the route switch.
            RoutedPointerTarget::Flutter => self.pending_cursor_shape = None,
            // Do not retain the previous client (or Flutter) shape while the
            // newly entered client is waiting to call wl_pointer.set_cursor.
            RoutedPointerTarget::Client(_) => self.pending_cursor_shape = Some("default"),
        }
    }

    #[cfg(feature = "flutter")]
    pub(super) fn take_cursor_shape_update(&mut self) -> Option<&'static str> {
        let shape = self.pending_cursor_shape.take()?;
        self.published_cursor_shape = Some(shape);
        Some(shape)
    }

    #[cfg(feature = "flutter")]
    fn queue_cursor_position(&mut self) {
        self.pending_cursor_position = cursor_position_for_modality(
            self.pointer_cursor_visible,
            self.flutter_scene_pointer_position(),
        );
    }

    #[cfg(feature = "flutter")]
    fn set_pointer_cursor_visible(&mut self, visible: bool) {
        if self.pointer_cursor_visible == visible {
            return;
        }
        self.pointer_cursor_visible = visible;
        self.published_cursor_shape = None;
        if !visible {
            self.pending_cursor_shape = Some("none");
            self.pending_cursor_position = None;
            return;
        }

        let active_shape = if self.clipboard_drag_active {
            "default"
        } else {
            match self.routed_pointer_target {
                RoutedPointerTarget::Flutter => "default",
                RoutedPointerTarget::Client(_) => software_cursor_shape(&self.cursor_status),
            }
        };
        self.pending_cursor_shape = Some(cursor_shape_for_modality(visible, active_shape));
        self.pending_cursor_position = cursor_position_for_modality(
            visible && matches!(self.routed_pointer_target, RoutedPointerTarget::Client(_)),
            self.flutter_scene_pointer_position(),
        );
    }

    #[cfg(feature = "flutter")]
    pub(super) fn take_cursor_position_update(&mut self) -> Option<(f64, f64)> {
        self.pending_cursor_position.take()
    }

    pub fn socket_name(&self) -> &OsStr {
        &self.socket_name
    }

    pub fn xdisplay_name(&self) -> OsString {
        OsString::from(format!(":{}", self.xdisplay))
    }

    pub(super) fn window_root_surface(&self, window: &Window) -> Option<WlSurface> {
        window.wl_surface().map(|surface| surface.into_owned())
    }

    pub(super) fn keyboard_focus_for_window(&self, window: &Window) -> Option<KeyboardFocusTarget> {
        if let Some(surface) = window.x11_surface() {
            // X11Surface implements the ICCCM focus handshake in addition to
            // forwarding wl_keyboard events to its associated wl_surface.
            surface.wl_surface()?;
            return Some(KeyboardFocusTarget::X11(surface.clone()));
        }
        self.window_root_surface(window)
            .map(KeyboardFocusTarget::Wayland)
    }

    /// Mints a one-shot token for a user launch initiated by Denial's shell.
    pub(super) fn create_launch_activation_token(&mut self) -> String {
        self.xdg_activation_state
            .retain_tokens(|_, data| data.timestamp.elapsed() <= XDG_ACTIVATION_TOKEN_LIFETIME);
        let (token, _) = self.xdg_activation_state.create_external_token(None);
        token.to_string()
    }

    /// Raises a desktop window in both compositor and X11 stacking state.
    ///
    /// `Space` owns Denial's visual and Wayland hit-test order, but rootless
    /// Xwayland keeps an independent X stack. Leaving the latter unchanged can
    /// make an X client below the visible window continue receiving pointer
    /// events in their overlap.
    pub(super) fn raise_window(&mut self, window: &Window, activate: bool) {
        self.space.raise_element(window, activate);
        let Some(surface) = window.x11_surface().cloned() else {
            return;
        };
        // Override-redirect popups are deliberately absent from XWM's EWMH
        // client stack and are already placed by Xwayland at map time.
        if surface.is_override_redirect() {
            return;
        }
        let Some(xwm) = self.xwm.as_mut() else {
            return;
        };
        if let Err(error) = xwm.raise_window(&surface) {
            warn!(
                %error,
                window = surface.window_id(),
                "could not synchronize raised X11 window"
            );
        }
    }

    #[cfg(feature = "flutter")]
    pub(super) fn window_for_id(&self, window_id: u64) -> Option<Window> {
        self.space
            .elements()
            .find(|window| {
                self.window_root_surface(window)
                    .as_ref()
                    .and_then(|surface| self.surface_id(surface))
                    == Some(window_id)
            })
            .cloned()
    }

    #[cfg(feature = "flutter")]
    pub(super) fn window_shell_fullscreen_locked(&self, window: &Window) -> bool {
        self.window_root_surface(window)
            .is_some_and(|root_surface| self.shell_fullscreen_locks.contains(&root_surface.id()))
    }

    #[cfg(feature = "flutter")]
    pub(super) fn window_geometry_locked(&self, window: &Window) -> bool {
        let Some(root_surface) = self.window_root_surface(window) else {
            return false;
        };
        if self.shell_fullscreen_locks.contains(&root_surface.id())
            || self
                .exact_window_geometries
                .contains_key(&root_surface.id())
        {
            return true;
        }
        let Some(window_id) = self.surface_id(&root_surface) else {
            return false;
        };
        self.input_layout.as_ref().is_some_and(|layout| {
            layout
                .windows
                .iter()
                .any(|region| region.window_id == window_id && region.geometry_locked())
        })
    }

    #[cfg(feature = "flutter")]
    pub(super) fn exact_window_geometry(&self, window: &Window) -> Option<Rectangle<i32, Logical>> {
        self.window_root_surface(window)
            .and_then(|surface| self.exact_window_geometries.get(&surface.id()).copied())
    }

    #[cfg(feature = "flutter")]
    pub(super) fn toggle_shell_fullscreen_lock(
        &mut self,
        window: &Window,
        client_fullscreen: bool,
    ) -> Option<ShellFullscreenTransition> {
        let root_surface = self.window_root_surface(window)?;
        let object_id = root_surface.id();
        let transition = shell_fullscreen_transition(
            client_fullscreen,
            self.shell_fullscreen_locks.contains(&object_id),
            self.window_geometry_locked(window),
        );
        match transition {
            ShellFullscreenTransition::ExitShell | ShellFullscreenTransition::ExitClient => {
                self.shell_fullscreen_locks.remove(&object_id);
                return Some(transition);
            }
            ShellFullscreenTransition::Blocked => return Some(transition),
            ShellFullscreenTransition::EnterShell => {}
        }
        let preserve_maximized = self.window_placement_state(window).maximized;
        let restore = self
            .shell_maximize_restore_geometries
            .get(&object_id)
            .copied()
            .or_else(|| self.restore_window_geometries.get(&object_id).copied())
            .unwrap_or_else(|| self.window_geometry_target(window));
        if preserve_maximized {
            self.shell_maximize_restore_geometries
                .entry(object_id.clone())
                .or_insert(restore);
        }
        self.shell_fullscreen_restore_geometries
            .insert(object_id.clone(), restore);
        self.shell_fullscreen_locks.insert(object_id);
        Some(transition)
    }

    pub(super) fn window_for_root_surface(&self, surface: &WlSurface) -> Option<Window> {
        self.space
            .elements()
            .find(|window| self.window_root_surface(window).as_ref() == Some(surface))
            .cloned()
    }

    fn window_identity(&self, window: &Window) -> Option<WindowIdentity> {
        if let Some(toplevel) = window.toplevel() {
            return with_states(toplevel.wl_surface(), |states| {
                let attributes = states
                    .data_map
                    .get::<XdgToplevelSurfaceData>()?
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                WindowIdentity::wayland(attributes.app_id.as_deref()?)
            });
        }
        let x11 = window.x11_surface()?;
        (!x11.is_override_redirect())
            .then(|| x11.class())
            .and_then(|class| WindowIdentity::x11(&class))
    }

    fn window_has_same_identity_sibling(&self, window: &Window, identity: &WindowIdentity) -> bool {
        self.space.elements().any(|candidate| {
            candidate != window && self.window_identity(candidate).as_ref() == Some(identity)
        })
    }

    pub(super) fn mark_client_geometry_state_request(&mut self, surface: &WlSurface) {
        self.client_geometry_state_requests.insert(surface.id());
    }

    fn window_has_transient_parent(&self, window: &Window) -> bool {
        if let Some(toplevel) = window.toplevel() {
            return with_states(toplevel.wl_surface(), |states| {
                states
                    .data_map
                    .get::<XdgToplevelSurfaceData>()
                    .and_then(|attributes| {
                        attributes
                            .lock()
                            .unwrap_or_else(|poisoned| poisoned.into_inner())
                            .parent
                            .clone()
                    })
                    .is_some()
            });
        }
        window
            .x11_surface()
            .is_some_and(|surface| surface.is_transient_for().is_some())
    }

    fn fallback_output_geometry(&self) -> Option<Rectangle<i32, Logical>> {
        let pointer = Point::<i32, Logical>::from((
            self.pointer_location.x.floor() as i32,
            self.pointer_location.y.floor() as i32,
        ));
        self.outputs
            .iter()
            .find(|entry| entry.logical_geometry.contains(pointer))
            .or_else(|| self.outputs.first())
            .map(|entry| entry.logical_geometry)
    }

    fn restored_placement_for_identity(
        &self,
        identity: &WindowIdentity,
        fallback_output: Rectangle<i32, Logical>,
    ) -> Option<RestoredWindowPlacement> {
        self.window_placements.restored_placement(
            identity,
            self.outputs
                .iter()
                .map(|entry| (entry.connector.clone(), entry.logical_geometry)),
            fallback_output,
        )
    }

    fn window_placement_state(&self, window: &Window) -> WindowPlacementState {
        let state = if let Some(toplevel) = window.toplevel() {
            WindowPlacementState {
                maximized: toplevel_has_state(toplevel, xdg_toplevel::State::Maximized),
                fullscreen: toplevel_has_state(toplevel, xdg_toplevel::State::Fullscreen),
            }
        } else if let Some(x11) = window.x11_surface() {
            WindowPlacementState {
                maximized: x11.is_maximized(),
                fullscreen: x11.is_fullscreen(),
            }
        } else {
            WindowPlacementState::default()
        };
        #[cfg(feature = "flutter")]
        let state = self
            .window_root_surface(window)
            .map_or(state, |root| WindowPlacementState {
                maximized: state.maximized
                    || self
                        .shell_maximize_restore_geometries
                        .contains_key(&root.id()),
                fullscreen: state.fullscreen || self.shell_fullscreen_locks.contains(&root.id()),
            });
        state
    }

    #[cfg(feature = "flutter")]
    fn apply_restored_window_state(
        &mut self,
        window: &Window,
        normal_geometry: Rectangle<i32, Logical>,
        state: WindowPlacementState,
    ) -> Rectangle<i32, Logical> {
        if !state.maximized && !state.fullscreen {
            return normal_geometry;
        }
        let Some(root) = self.window_root_surface(window) else {
            return normal_geometry;
        };
        let Some((output, output_geometry)) = self
            .output_for_geometry(normal_geometry)
            .map(|entry| (entry.output.clone(), entry.logical_geometry))
        else {
            return normal_geometry;
        };
        let object_id = root.id();
        let server_frame = shell_draws_server_frame(window);
        let mut target = normal_geometry;
        if state.maximized {
            let frame = self.maximize_work_area(Some(&output), output_geometry);
            target = shell_content_geometry(frame, server_frame);
            self.shell_maximize_restore_geometries
                .insert(object_id.clone(), normal_geometry);
        }
        if state.fullscreen {
            target = shell_content_geometry(output_geometry, server_frame);
            self.shell_fullscreen_restore_geometries
                .insert(object_id.clone(), normal_geometry);
            self.shell_fullscreen_locks.insert(object_id);
        }
        target
    }

    fn restore_xdg_window_placement(
        &mut self,
        window: &Window,
    ) -> Option<(RestoredWindowPlacement, Rectangle<i32, Logical>)> {
        let toplevel = window.toplevel()?;
        let root = toplevel.wl_surface();
        let object_id = root.id();
        if self.restored_window_positions.contains(&object_id) {
            return None;
        }
        let (identity, has_parent, initial_configure_sent) = with_states(root, |states| {
            let Some(attributes) = states.data_map.get::<XdgToplevelSurfaceData>() else {
                return (None, false, false);
            };
            let attributes = attributes
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            (
                attributes
                    .app_id
                    .as_deref()
                    .and_then(WindowIdentity::wayland),
                attributes.parent.is_some(),
                attributes.initial_configure_sent,
            )
        });
        let identity = identity?;
        let fallback_output = self.fallback_output_geometry()?;
        let mut restored = self.restored_placement_for_identity(&identity, fallback_output)?;
        let client_state = WindowPlacementState {
            maximized: toplevel_has_state(toplevel, xdg_toplevel::State::Maximized),
            fullscreen: toplevel_has_state(toplevel, xdg_toplevel::State::Fullscreen),
        };
        let policy = initial_xdg_placement_policy(
            has_parent,
            self.window_has_same_identity_sibling(window, &identity),
            initial_configure_sent,
            self.client_geometry_state_requests.contains(&object_id),
            client_state,
            restored.state,
        );
        if policy == InitialXdgPlacementPolicy::SkipSaved {
            return None;
        }

        let (output_id, output_geometry) = self
            .output_for_geometry(restored.geometry)
            .map(|output| (output.id, output.logical_geometry))
            .or_else(|| {
                self.outputs
                    .first()
                    .map(|output| (output.id, output.logical_geometry))
            })?;
        restored.geometry = clamp_window_geometry(restored.geometry, output_geometry);

        if policy == InitialXdgPlacementPolicy::ClientSized {
            // A zero-sized initial XDG configure is an explicit instruction
            // for the client to choose its own dimensions. Keep only Denial's
            // output/location intent until the first committed client
            // geometry exists; injecting the saved application size here
            // stretches independent auxiliary toplevels to the main window.
            toplevel.with_pending_state(|pending| pending.size = None);
            self.space.relocate_element(window, restored.geometry.loc);
            self.update_window_output_membership(window);
            self.pending_client_sized_placements.insert(
                object_id.clone(),
                PendingClientSizedPlacement {
                    requested_location: restored.geometry.loc,
                    output_id,
                },
            );
            self.restored_window_positions.insert(object_id);
            info!(
                backend = ?identity.backend(),
                app_id = identity.app_id(),
                x = restored.geometry.loc.x,
                y = restored.geometry.loc.y,
                saved_width = restored.geometry.size.w,
                saved_height = restored.geometry.size.h,
                "restored saved window location; client chooses initial size"
            );
            return None;
        }

        let (minimum, maximum) = with_states(root, |states| {
            let mut cached = states.cached_state.get::<SurfaceCachedState>();
            let current = cached.current();
            (current.min_size, current.max_size)
        });
        restored.geometry.size = Size::from((
            constrain_dimension(restored.geometry.size.w, minimum.w, maximum.w),
            constrain_dimension(restored.geometry.size.h, minimum.h, maximum.h),
        ));
        restored.geometry = clamp_window_geometry(restored.geometry, output_geometry);
        #[cfg(feature = "flutter")]
        let target = self.apply_restored_window_state(window, restored.geometry, restored.state);
        #[cfg(not(feature = "flutter"))]
        let target = restored.geometry;
        toplevel.with_pending_state(|pending| pending.size = Some(target.size));
        self.set_window_geometry_target(window, target);
        self.restored_window_positions.insert(object_id);
        info!(
            backend = ?identity.backend(),
            app_id = identity.app_id(),
            x = target.loc.x,
            y = target.loc.y,
            width = target.size.w,
            height = target.size.h,
            maximized = restored.state.maximized,
            fullscreen = restored.state.fullscreen,
            "restored saved window placement"
        );
        Some((restored, target))
    }

    pub(super) fn defer_client_sized_window_placement(&mut self, window: &Window) -> bool {
        let Some(root) = self.window_root_surface(window) else {
            return false;
        };
        let geometry = self.window_geometry_target(window);
        let Some(output_id) = self
            .output_for_geometry(geometry)
            .map(|output| output.id)
            .or_else(|| self.outputs.first().map(|output| output.id))
        else {
            return false;
        };
        let object_id = root.id();
        self.configured_window_geometries.remove(&object_id);
        self.pending_client_sized_placements.insert(
            object_id,
            PendingClientSizedPlacement {
                requested_location: geometry.loc,
                output_id,
            },
        );
        true
    }

    fn reconcile_client_sized_window_placement(
        &mut self,
        window: &Window,
    ) -> Option<Rectangle<i32, Logical>> {
        let root = self.window_root_surface(window)?;
        let object_id = root.id();
        let pending = self
            .pending_client_sized_placements
            .get(&object_id)
            .copied()?;
        let committed = window.geometry();
        if committed.size.w <= 0 || committed.size.h <= 0 {
            return None;
        }
        let output_geometry = self
            .outputs
            .iter()
            .find(|output| output.id == pending.output_id)
            .map(|output| output.logical_geometry)
            .or_else(|| self.fallback_output_geometry())?;
        let target = clamp_window_geometry(
            Rectangle::new(pending.requested_location, committed.size),
            output_geometry,
        );
        self.space.relocate_element(window, target.loc);
        self.update_window_output_membership(window);
        self.pending_client_sized_placements.remove(&object_id);
        info!(
            x = target.loc.x,
            y = target.loc.y,
            width = target.size.w,
            height = target.size.h,
            "placed client-sized Wayland window"
        );
        Some(target)
    }

    pub(super) fn remember_window_geometry(
        &mut self,
        window: &Window,
        geometry: Rectangle<i32, Logical>,
    ) {
        if self.window_has_transient_parent(window) {
            return;
        }
        let Some(identity) = self.window_identity(window) else {
            return;
        };
        let state = self.window_placement_state(window);
        let Some(output) = self.output_for_geometry(geometry) else {
            return;
        };
        let connector = output.connector.clone();
        let output_geometry = output.logical_geometry;
        if let Err(error) = self.window_placements.remember(
            identity.clone(),
            &connector,
            output_geometry,
            geometry,
            state,
        ) {
            warn!(
                %error,
                backend = ?identity.backend(),
                app_id = identity.app_id(),
                "could not persist window placement"
            );
        }
    }

    pub(super) fn remember_window_placement(&mut self, window: &Window) {
        let geometry = self
            .window_root_surface(window)
            .and_then(|root| {
                #[cfg(feature = "flutter")]
                if let Some(geometry) = self
                    .shell_maximize_restore_geometries
                    .get(&root.id())
                    .copied()
                {
                    return Some(geometry);
                }
                #[cfg(feature = "flutter")]
                if let Some(geometry) = self
                    .shell_fullscreen_restore_geometries
                    .get(&root.id())
                    .copied()
                {
                    return Some(geometry);
                }
                self.restore_window_geometries.get(&root.id()).copied()
            })
            .unwrap_or_else(|| self.window_geometry_target(window));
        self.remember_window_geometry(window, geometry);
    }

    pub(super) fn window_geometry_target(&self, window: &Window) -> Rectangle<i32, Logical> {
        self.window_root_surface(window)
            .and_then(|surface| {
                self.exact_window_geometries
                    .get(&surface.id())
                    .or_else(|| self.configured_window_geometries.get(&surface.id()))
                    .copied()
            })
            .or_else(|| self.space.element_geometry(window))
            .unwrap_or_else(|| window.bbox())
    }

    pub(super) fn update_window_output_membership(&mut self, window: &Window) {
        let output_index = self.output_index_for_geometry(self.window_geometry_target(window));
        let output = output_index.map(|index| self.outputs[index].id);
        let output_scale = output_index
            .map(|index| {
                self.outputs[index]
                    .output
                    .current_scale()
                    .fractional_scale()
            })
            .unwrap_or(1.0);
        window.with_surfaces(|surface, states| {
            let preferred_scale = Self::client_preferred_scale(surface, output_scale);
            with_fractional_scale(states, |fractional_scale| {
                fractional_scale.set_preferred_scale(preferred_scale);
            });
        });
        #[cfg(feature = "flutter")]
        if let Some(root_surface) = self.window_root_surface(window) {
            self.output_window_membership
                .update(root_surface.id(), window.clone(), output);
        }
    }

    #[cfg(feature = "flutter")]
    pub(super) fn remove_window_output_membership(&mut self, surface: &WlSurface) {
        self.output_window_membership.remove(&surface.id());
    }

    pub(super) fn rebuild_window_output_membership(&mut self) {
        #[cfg(feature = "flutter")]
        self.output_window_membership.clear();
        let windows = self.space.elements().cloned().collect::<Vec<_>>();
        for window in windows {
            self.update_window_output_membership(&window);
        }
    }

    pub(super) fn set_window_geometry_target(
        &mut self,
        window: &Window,
        target: Rectangle<i32, Logical>,
    ) {
        let Some(root_surface) = self.window_root_surface(window) else {
            return;
        };
        self.shell_vertical_restore_geometries
            .remove(&root_surface.id());
        if let Some(x11) = window.x11_surface()
            && !x11.is_override_redirect()
            && x11.last_configure() != target
            && let Err(error) = x11.configure(target)
        {
            warn!(%error, window = x11.window_id(), "could not configure X11 geometry");
        }
        // Space stores an element's *global geometry location*, not its
        // wl_surface render origin.  Window::geometry().loc is only the local
        // offset of the client geometry inside that surface (CSD shadows and
        // X11 frame extents commonly make it non-zero).  Applying that offset
        // here a second time makes the published geometry and native hitboxes
        // diverge, and feeds the offset back into every configure/commit cycle.
        self.space.relocate_element(window, target.loc);
        if window.geometry().size == target.size {
            // A move needs no client acknowledgement.  Reading the geometry
            // back from Space is already authoritative and avoids retaining a
            // stale target indefinitely when the client has no reason to
            // commit another buffer.
            self.configured_window_geometries.remove(&root_surface.id());
        } else {
            self.configured_window_geometries
                .insert(root_surface.id(), target);
        }
        self.update_window_output_membership(window);
    }

    #[cfg(feature = "flutter")]
    pub(super) fn set_window_geometry_target_policy(
        &mut self,
        window: &Window,
        target: Rectangle<i32, Logical>,
        exact: bool,
    ) {
        let Some(root_surface) = self.window_root_surface(window) else {
            return;
        };
        if exact {
            self.exact_window_geometries
                .insert(root_surface.id(), target);
        } else {
            self.exact_window_geometries.remove(&root_surface.id());
        }
        self.set_window_geometry_target(window, target);
    }

    fn reconcile_committed_window_geometry(&mut self, window: &Window) {
        let Some(root_surface) = self.window_root_surface(window) else {
            return;
        };
        let surface_id = root_surface.id();
        let exact = self.exact_window_geometries.get(&surface_id).copied();
        let target = exact.or_else(|| self.configured_window_geometries.get(&surface_id).copied());
        let Some(target) = target else {
            return;
        };
        let committed = window.geometry();
        // `target.loc` and Space's element location use the same global
        // geometry coordinate system.  `committed.loc` remains surface-local
        // and must affect rendering only (Space subtracts it internally).
        self.space.relocate_element(window, target.loc);
        if committed.size == target.size {
            self.configured_window_geometries.remove(&surface_id);
        } else if exact.is_some() {
            if let Some(toplevel) = window.toplevel() {
                toplevel.with_pending_state(|pending| {
                    pending.states.unset(xdg_toplevel::State::Fullscreen);
                    pending.states.unset(xdg_toplevel::State::Maximized);
                    pending.states.unset(xdg_toplevel::State::Resizing);
                    pending.fullscreen_output = None;
                    pending.size = Some(target.size);
                });
                toplevel.send_pending_configure();
            } else if let Some(x11) = window.x11_surface()
                && !x11.is_override_redirect()
                && x11.last_configure() != target
                && let Err(error) = x11.configure(target)
            {
                warn!(%error, window = x11.window_id(), "could not reassert exact X11 geometry");
            }
        }
    }

    #[cfg(feature = "flutter")]
    fn window_placement(
        &self,
        window: &Window,
        geometry: Rectangle<i32, Logical>,
        monitor_geometry: Rectangle<i32, Logical>,
        phase: WindowPlacementPhase,
        change: WindowPlacementChange,
    ) -> Option<WindowPlacement> {
        let root_surface = self.window_root_surface(window)?;
        let window_id = self.surface_id(&root_surface)?;
        let monitor_id = self
            .output_for_geometry(monitor_geometry)
            .and_then(|entry| i64::try_from(entry.id.0).ok())?;
        Some(WindowPlacement {
            window_id,
            monitor_id,
            // Workspaces are not split yet. Keep a real, stable ownership ID
            // rather than the protocol's invalid -1 sentinel.
            workspace_id: 1,
            phase,
            change,
            geometry: WindowGeometry {
                x: f64::from(geometry.loc.x) - self.atlas_origin.x,
                y: f64::from(geometry.loc.y) - self.atlas_origin.y,
                width: f64::from(geometry.size.w),
                height: f64::from(geometry.size.h),
            },
        })
    }

    #[cfg(feature = "flutter")]
    pub(super) fn replay_window_state_events(&self) -> Vec<PendingWindowEvent> {
        let mut events = Vec::new();
        for window in self.space.elements() {
            let Some(root_surface) = self.window_root_surface(window) else {
                continue;
            };
            let Some(window_id) = self.surface_id(&root_surface) else {
                continue;
            };
            let (fullscreen, client_maximized) = if let Some(toplevel) = window.toplevel() {
                (
                    toplevel_has_state(toplevel, xdg_toplevel::State::Fullscreen),
                    toplevel_has_state(toplevel, xdg_toplevel::State::Maximized),
                )
            } else if let Some(x11) = window.x11_surface() {
                (x11.is_fullscreen(), x11.is_maximized())
            } else {
                (false, false)
            };
            let shell_maximized = self
                .shell_maximize_restore_geometries
                .contains_key(&root_surface.id());
            let shell_fullscreen = self.shell_fullscreen_locks.contains(&root_surface.id());
            let maximized = client_maximized || shell_maximized;
            let fullscreen = fullscreen || shell_fullscreen;
            if fullscreen || maximized {
                if let Some(restore) = self
                    .shell_maximize_restore_geometries
                    .get(&root_surface.id())
                    .or_else(|| {
                        self.shell_fullscreen_restore_geometries
                            .get(&root_surface.id())
                    })
                    .or_else(|| self.restore_window_geometries.get(&root_surface.id()))
                    .copied()
                    && let Some(placement) = self.window_placement(
                        window,
                        restore,
                        self.window_geometry_target(window),
                        WindowPlacementPhase::End,
                        WindowPlacementChange::Resize,
                    )
                {
                    events.push(PendingWindowEvent::Placement(placement));
                }
                if maximized {
                    events.push(PendingWindowEvent::Action(
                        window_id,
                        WindowAction::Maximize,
                    ));
                }
                if fullscreen {
                    events.push(PendingWindowEvent::Action(
                        window_id,
                        WindowAction::ToggleFullscreen,
                    ));
                }
            }
            if self.minimized_windows.contains(&root_surface.id()) {
                events.push(PendingWindowEvent::Action(
                    window_id,
                    WindowAction::Minimize,
                ));
            }
        }

        let focused = self
            .seat
            .get_keyboard()
            .and_then(|keyboard| keyboard.current_focus());
        if let Some(window_id) = focused
            .as_ref()
            .and_then(|focus| focus.wl_surface())
            .and_then(|surface| self.owning_toplevel_surface(&surface))
            .filter(|surface| !self.minimized_windows.contains(&surface.id()))
            .as_ref()
            .and_then(|surface| self.surface_id(surface))
        {
            events.push(PendingWindowEvent::Activated(window_id));
        }
        events
    }

    fn register_surface(&mut self, surface: &WlSurface) -> u64 {
        if let Some(surface_id) = self.surface_ids.get(&surface.id()).copied() {
            return surface_id;
        }

        let maximum = i64::MAX as u64;
        let mut surface_id = self.next_surface_id.clamp(1, maximum);
        let first_candidate = surface_id;
        while self.surfaces_by_id.contains_key(&surface_id) || {
            #[cfg(feature = "flutter")]
            {
                self.local_windows.contains(surface_id)
            }
            #[cfg(not(feature = "flutter"))]
            {
                false
            }
        } {
            surface_id = if surface_id == maximum {
                1
            } else {
                surface_id + 1
            };
            assert_ne!(
                surface_id, first_candidate,
                "exhausted positive Flutter texture identifiers"
            );
        }
        self.next_surface_id = if surface_id == maximum {
            1
        } else {
            surface_id + 1
        };
        self.surface_ids.insert(surface.id(), surface_id);
        self.surfaces_by_id.insert(surface_id, surface.clone());
        surface_id
    }

    #[cfg(feature = "flutter")]
    pub(super) fn create_local_flutter_window(
        &mut self,
        app_id: String,
        title: String,
        mut geometry: WindowGeometry,
    ) -> Result<u64, LocalWindowError> {
        // Dart speaks in atlas-relative logical coordinates, while native
        // window state follows Space and remains global across topology moves.
        geometry.x += self.atlas_origin.x;
        geometry.y += self.atlas_origin.y;
        let surfaces_by_id = &self.surfaces_by_id;
        self.local_windows.create(app_id, title, geometry, |id| {
            surfaces_by_id.contains_key(&id)
        })
    }

    #[cfg(feature = "flutter")]
    pub(super) fn focused_local_flutter_window(&self) -> Option<u64> {
        self.local_windows.focused()
    }

    #[cfg(feature = "flutter")]
    pub(super) fn is_local_flutter_window(&self, window_id: u64) -> bool {
        self.local_windows.contains(window_id)
    }

    #[cfg(feature = "flutter")]
    pub(super) fn focus_local_flutter_window(&mut self, window_id: u64) -> bool {
        self.local_windows.focus(window_id)
    }

    #[cfg(feature = "flutter")]
    pub(super) fn clear_local_flutter_focus(&mut self) {
        self.local_windows.clear_focus();
    }

    #[cfg(feature = "flutter")]
    pub(super) fn configure_local_flutter_window(
        &mut self,
        window_id: u64,
        mut geometry: WindowGeometry,
    ) -> bool {
        geometry.x += self.atlas_origin.x;
        geometry.y += self.atlas_origin.y;
        self.local_vertical_restore_geometries.remove(&window_id);
        self.local_windows.configure(window_id, geometry)
    }

    #[cfg(feature = "flutter")]
    pub(super) fn local_flutter_window_geometry(&self, window_id: u64) -> Option<WindowGeometry> {
        self.local_windows
            .get(window_id)
            .map(|window| window.geometry)
    }

    #[cfg(feature = "flutter")]
    pub(super) fn set_local_flutter_window_global_geometry(
        &mut self,
        window_id: u64,
        geometry: WindowGeometry,
    ) -> bool {
        self.local_vertical_restore_geometries.remove(&window_id);
        self.local_windows.configure(window_id, geometry)
    }

    #[cfg(feature = "flutter")]
    pub(super) fn local_flutter_window_placement(
        &self,
        window_id: u64,
        phase: WindowPlacementPhase,
        change: WindowPlacementChange,
    ) -> Option<WindowPlacement> {
        let geometry = self.local_windows.get(window_id)?.geometry;
        let global_geometry = Rectangle::<i32, Logical>::new(
            Point::from((
                geometry
                    .x
                    .round()
                    .clamp(f64::from(i32::MIN), f64::from(i32::MAX)) as i32,
                geometry
                    .y
                    .round()
                    .clamp(f64::from(i32::MIN), f64::from(i32::MAX)) as i32,
            )),
            Size::from((
                geometry.width.round().clamp(1.0, f64::from(i32::MAX)) as i32,
                geometry.height.round().clamp(1.0, f64::from(i32::MAX)) as i32,
            )),
        );
        let monitor_id = self
            .output_for_geometry(global_geometry)
            .and_then(|entry| i64::try_from(entry.id.0).ok())?;
        Some(WindowPlacement {
            window_id,
            monitor_id,
            workspace_id: 1,
            phase,
            change,
            geometry: WindowGeometry {
                x: geometry.x - self.atlas_origin.x,
                y: geometry.y - self.atlas_origin.y,
                width: geometry.width,
                height: geometry.height,
            },
        })
    }

    #[cfg(feature = "flutter")]
    pub(super) fn remove_local_flutter_window(&mut self, window_id: u64) -> bool {
        self.local_vertical_restore_geometries.remove(&window_id);
        self.local_windows.remove(window_id)
    }

    fn remove_surface_state(&mut self, surface: &WlSurface, remove_identity: bool) {
        let object_id = surface.id();
        #[cfg(feature = "flutter")]
        self.remove_window_output_membership(surface);
        #[cfg(feature = "flutter")]
        self.idle_inhibitors.remove_surface(surface);
        #[cfg(feature = "flutter")]
        let stable_id = self.surface_ids.get(&object_id).copied();
        #[cfg(feature = "flutter")]
        let removes_toplevel = self
            .space
            .elements()
            .any(|window| self.window_root_surface(window).as_ref() == Some(surface));

        self.surface_buffers.remove(&object_id);
        self.configured_window_geometries.remove(&object_id);
        self.exact_window_geometries.remove(&object_id);
        self.restore_window_geometries.remove(&object_id);
        self.restored_window_positions.remove(&object_id);
        self.client_geometry_state_requests.remove(&object_id);
        self.pending_client_sized_placements.remove(&object_id);
        #[cfg(feature = "flutter")]
        self.shell_maximize_restore_geometries.remove(&object_id);
        #[cfg(feature = "flutter")]
        self.shell_fullscreen_restore_geometries.remove(&object_id);
        #[cfg(feature = "flutter")]
        self.shell_vertical_restore_geometries.remove(&object_id);
        if matches!(
            &self.cursor_status,
            CursorImageStatus::Surface(cursor_surface) if cursor_surface == surface
        ) {
            #[cfg(feature = "flutter")]
            self.update_cursor_image(CursorImageStatus::default_named());
            #[cfg(not(feature = "flutter"))]
            {
                self.cursor_status = CursorImageStatus::default_named();
            }
        }

        #[cfg(feature = "flutter")]
        {
            let cached_route_is_stale =
                self.client_input_route_cache.as_ref().is_some_and(|route| {
                    &route.surface == surface
                        || (removes_toplevel
                            && self.owning_toplevel_surface(&route.surface).as_ref()
                                == Some(surface))
                });
            let pointer_route_is_stale =
                self.client_pointer_capture.as_ref().is_some_and(|route| {
                    &route.surface == surface
                        || (removes_toplevel
                            && self.owning_toplevel_surface(&route.surface).as_ref()
                                == Some(surface))
                });
            let stale_touch_slots = self
                .client_touch_routes
                .iter()
                .filter_map(|(slot, route)| {
                    (&route.surface == surface
                        || (removes_toplevel
                            && self.owning_toplevel_surface(&route.surface).as_ref()
                                == Some(surface)))
                    .then_some(*slot)
                })
                .collect::<Vec<_>>();

            self.remove_surface_shm_frame(&object_id);
            self.pending_surface_commits.remove(&object_id);
            self.pending_shm_snapshots.remove(&object_id);
            self.surface_buffer_revisions.remove(&object_id);
            self.minimized_windows.remove(&object_id);
            self.shell_fullscreen_locks.remove(&object_id);
            if let Some(stable_id) = stable_id {
                self.pointer_constraint_escape.forget_window(stable_id);
            }

            if cached_route_is_stale {
                self.client_input_route_cache = None;
            }
            if pointer_route_is_stale {
                self.client_pointer_capture = None;
                self.client_pointer_buttons.clear();
                self.client_pointer_presses.clear();
            }
            for slot in stale_touch_slots {
                self.client_touch_routes.remove(&slot);
            }
            if stable_id.is_some_and(|stable_id| {
                self.routed_pointer_target == RoutedPointerTarget::Client(stable_id)
            }) {
                self.set_routed_pointer_target(RoutedPointerTarget::Flutter);
            }
        }

        if remove_identity && let Some(stable_id) = self.surface_ids.remove(&object_id) {
            let removed = self.surfaces_by_id.remove(&stable_id);
            debug_assert!(
                removed
                    .as_ref()
                    .is_none_or(|candidate| candidate == surface)
            );
        }
    }

    #[cfg(feature = "flutter")]
    fn surface_id(&self, surface: &WlSurface) -> Option<u64> {
        self.surface_ids.get(&surface.id()).copied()
    }

    #[cfg(feature = "flutter")]
    pub(super) fn live_toplevel_ids(&self) -> HashSet<u64> {
        self.space
            .elements()
            .filter_map(|window| self.window_root_surface(window))
            .filter_map(|surface| self.surface_id(&surface))
            .collect()
    }

    fn toplevel_candidate_surface(&self, surface: &WlSurface) -> WlSurface {
        let mut tree_root = surface.clone();
        while let Some(parent) = get_parent(&tree_root) {
            tree_root = parent;
        }

        self.popups
            .find_popup(&tree_root)
            .and_then(|popup| find_popup_root_surface(&popup).ok())
            .unwrap_or(tree_root)
    }

    pub(super) fn update_surface_fractional_scale(&self, surface: &WlSurface) {
        let root = self.toplevel_candidate_surface(surface);
        let preferred_scale = self
            .window_for_root_surface(&root)
            .and_then(|window| {
                self.output_for_geometry(self.window_geometry_target(&window))
                    .map(|output| output.output.current_scale().fractional_scale())
            })
            .or_else(|| {
                self.outputs
                    .first()
                    .map(|output| output.output.current_scale().fractional_scale())
            })
            .unwrap_or(1.0);
        let preferred_scale = Self::client_preferred_scale(surface, preferred_scale);
        with_states(surface, |states| {
            with_fractional_scale(states, |fractional_scale| {
                fractional_scale.set_preferred_scale(preferred_scale);
            });
        });
    }

    fn client_preferred_scale(surface: &WlSurface, output_scale: f64) -> f64 {
        let client_scale = surface
            .client()
            .and_then(|client| {
                client
                    .get_data::<XWaylandClientData>()
                    .map(|data| data.compositor_state.client_scale())
            })
            .unwrap_or(1.0)
            .max(f64::EPSILON);
        (output_scale / client_scale).max(1.0)
    }

    #[cfg(feature = "flutter")]
    fn owning_toplevel_surface(&self, surface: &WlSurface) -> Option<WlSurface> {
        let candidate = self.toplevel_candidate_surface(surface);
        self.space
            .elements()
            .any(|window| self.window_root_surface(window).as_ref() == Some(&candidate))
            .then_some(candidate)
    }

    #[cfg(feature = "flutter")]
    fn remove_surface_shm_frame(&mut self, surface_id: &ObjectId) {
        let Some(frame) = self.surface_shm_frames.remove(surface_id) else {
            return;
        };
        let bytes = rgba_payload_len(frame.width(), frame.height())
            .expect("validated SHM frame dimensions must fit usize");
        debug_assert!(bytes <= self.shm_snapshot_bytes);
        self.shm_snapshot_bytes = self.shm_snapshot_bytes.saturating_sub(bytes);
    }

    #[cfg(feature = "flutter")]
    fn update_surface_shm_frame(&mut self, surface: &WlSurface, buffer: &wl_buffer::WlBuffer) {
        let surface_id = surface.id();
        // Drop the previous CPU snapshot before reserving its replacement, so
        // repeated commits cannot transiently grow the owned cache without a
        // bound. Flutter may retain the Arc for its current raster frame only.
        self.remove_surface_shm_frame(&surface_id);
        let available_cache_bytes = self
            .shm_snapshot_budget_bytes
            .saturating_sub(self.shm_snapshot_bytes);
        let revision = self.next_shm_revision;
        match snapshot_shm_buffer(
            buffer,
            revision,
            available_cache_bytes,
            &self.shm_snapshot_pool,
        ) {
            Ok(Some(frame)) => {
                let frame_bytes = rgba_payload_len(frame.width(), frame.height())
                    .expect("validated SHM frame dimensions must fit usize");
                debug_assert!(frame_bytes <= available_cache_bytes);
                self.shm_snapshot_bytes = self
                    .shm_snapshot_bytes
                    .checked_add(frame_bytes)
                    .expect("bounded SHM snapshot accounting must not overflow");
                self.next_shm_revision = revision.wrapping_add(1).max(1);
                self.surface_shm_frames.insert(surface_id, frame);
            }
            Ok(None) => {}
            Err(error) => {
                warn!(
                    %error,
                    surface_id = ?surface_id,
                    buffer_id = ?buffer.id(),
                    cached_bytes = self.shm_snapshot_bytes,
                    cache_budget_bytes = self.shm_snapshot_budget_bytes,
                    "could not snapshot Wayland SHM buffer for Flutter"
                );
            }
        }
    }

    #[cfg(feature = "flutter")]
    fn queue_surface_commit(&mut self, surface: &WlSurface, kind: SurfaceCommitKind) {
        self.pending_surface_commits
            .entry(surface.id())
            .and_modify(|pending| *pending = pending.merge(kind))
            .or_insert(kind);
    }

    #[cfg(feature = "flutter")]
    fn publish_surface_commits(&mut self, root: &WlSurface) -> PublishedSurfaceCommits {
        let mut committed_surfaces = std::mem::take(&mut self.committed_surfaces_scratch);
        committed_surfaces.clear();
        let mut buffer_surface_ids = std::mem::take(&mut self.published_surface_ids_scratch);
        buffer_surface_ids.clear();
        with_surface_tree_upward(
            root,
            (),
            |_, _, _| TraversalAction::DoChildren(()),
            |surface, _, _| committed_surfaces.push(surface.clone()),
            |_, _, _| true,
        );

        let mut metadata_changed = false;
        for surface in committed_surfaces.drain(..) {
            let Some(kind) = self.pending_surface_commits.remove(&surface.id()) else {
                continue;
            };
            let current_buffer = with_renderer_surface_state(&surface, |state| {
                state.buffer().map(|buffer| (**buffer).clone())
            })
            .flatten();
            if current_buffer
                .as_ref()
                .is_some_and(|buffer| get_dmabuf(buffer).is_ok())
            {
                let revision = self.next_buffer_revision.max(1);
                self.next_buffer_revision = revision.wrapping_add(1).max(1);
                self.surface_buffer_revisions.insert(surface.id(), revision);
                self.pending_shm_snapshots.remove(&surface.id());
                self.remove_surface_shm_frame(&surface.id());
            } else if let Some(buffer) = current_buffer {
                self.surface_buffer_revisions.remove(&surface.id());
                if self.pending_shm_snapshots.remove(&surface.id())
                    || !self.surface_shm_frames.contains_key(&surface.id())
                {
                    self.update_surface_shm_frame(&surface, &buffer);
                }
            } else {
                self.surface_buffer_revisions.remove(&surface.id());
                self.pending_shm_snapshots.remove(&surface.id());
                self.remove_surface_shm_frame(&surface.id());
            }

            // SurfaceAttributes aggregates damage across commits until the
            // compositor consumes it. The renderer helper drains damage when
            // a new buffer is attached, but deliberately leaves damage-only
            // commits untouched. Consume that remainder only after this
            // surface's transaction is published: clearing it in the commit
            // handler would discard synchronized-subsurface damage before the
            // parent transaction can process it, while leaving it here makes
            // later callback-only commits look like fresh visual updates.
            with_states(&surface, |states| {
                let mut attributes = states.cached_state.get::<SurfaceAttributes>();
                attributes.current().damage.clear();
            });

            match kind {
                SurfaceCommitKind::BufferOnly => {
                    let Some(surface_id) = self.surface_id(&surface) else {
                        metadata_changed = true;
                        continue;
                    };
                    // A buffer can take the fast path only after its surface
                    // has appeared in an accepted full scene. This also
                    // excludes pre-map and zero-geometry commits.
                    let owner = self.scene_surface_windows.get(&surface_id).copied();
                    if owner == Some(surface_id)
                        && !self.scene_complex_windows.contains(&surface_id)
                    {
                        buffer_surface_ids.push(surface_id);
                    } else {
                        metadata_changed = true;
                    }
                }
                SurfaceCommitKind::Metadata => metadata_changed = true,
            }
        }
        self.committed_surfaces_scratch = committed_surfaces;
        PublishedSurfaceCommits {
            metadata_changed,
            buffer_surface_ids,
        }
    }

    #[cfg(feature = "flutter")]
    fn recycle_published_surface_ids(&mut self, mut surface_ids: Vec<u64>) {
        surface_ids.clear();
        debug_assert!(self.published_surface_ids_scratch.is_empty());
        self.published_surface_ids_scratch = surface_ids;
    }

    pub fn init_renderer(&mut self, renderer: &mut GlesRenderer) -> Result<(), Box<dyn Error>> {
        if self.dmabuf_global.is_some() {
            return Ok(());
        }

        let render_node = match EGLDevice::device_for_display(renderer.egl_context().display())
            .and_then(|device| device.try_get_render_node())
        {
            Ok(node) => node,
            Err(error) => {
                warn!(%error, "could not identify the EGL render node; advertising linux-dmabuf v3");
                None
            }
        };
        let render_formats =
            <GlesRenderer as Bind<Dmabuf>>::supported_formats(renderer).unwrap_or_default();
        self.set_screencopy_dmabuf_formats(render_formats);
        let formats = renderer.dmabuf_formats();
        let global = if let Some(node) = render_node {
            let feedback = DmabufFeedbackBuilder::new(node.dev_id(), formats).build()?;
            self.dmabuf_render_node = Some(node);
            info!(?node, "advertising linux-dmabuf v4 with renderer feedback");
            self.dmabuf_state
                .create_global_with_default_feedback::<RuntimeState>(
                    &self.display_handle,
                    &feedback,
                )
        } else {
            info!("advertising linux-dmabuf v3 without renderer feedback");
            self.dmabuf_state
                .create_global::<RuntimeState>(&self.display_handle, formats)
        };
        self.dmabuf_global = Some(global);
        Ok(())
    }

    pub fn process_pending_dmabufs(
        &mut self,
        renderer: &mut GlesRenderer,
    ) -> Result<(), Box<dyn Error>> {
        if self.pending_dmabuf_imports.is_empty() {
            return Ok(());
        }
        for (dmabuf, notifier) in self.pending_dmabuf_imports.drain(..) {
            if renderer.import_dmabuf(&dmabuf, None).is_ok() {
                if let Some(node) = self.dmabuf_render_node {
                    dmabuf.set_node(node);
                }
                if notifier.successful::<RuntimeState>().is_err() {
                    warn!("linux-dmabuf client disappeared before import completed");
                }
            } else {
                warn!(
                    planes = dmabuf.num_planes(),
                    "rejected client linux-dmabuf import"
                );
                notifier.failed();
            }
        }
        // Flutter owns steady-state composition, so this Smithay renderer
        // never reaches the render-frame cleanup which normally prunes dead
        // WeakDmabuf cache keys and destroys their EGLImages. Without an
        // explicit cleanup here, every client buffer ever validated remains
        // resident through the renderer's dma-buf cache for the lifetime of
        // the compositor.
        renderer.cleanup_texture_cache()?;
        self.dmabuf_import_queue_saturated = false;
        self.display_handle.flush_clients()?;
        Ok(())
    }

    fn queue_dmabuf_import(&mut self, dmabuf: Dmabuf, notifier: ImportNotifier) {
        if !dmabuf_import_queue_has_capacity(self.pending_dmabuf_imports.len()) {
            if !self.dmabuf_import_queue_saturated {
                warn!(
                    limit = MAX_PENDING_DMABUF_IMPORTS,
                    "rejecting client linux-dmabuf imports until the bounded queue is drained"
                );
                self.dmabuf_import_queue_saturated = true;
            }
            notifier.failed();
            return;
        }
        self.pending_dmabuf_imports.push((dmabuf, notifier));
    }

    #[cfg(feature = "flutter")]
    #[allow(clippy::too_many_arguments)]
    fn append_surface_tree(
        &self,
        root: &WlSurface,
        origin: Point<i32, Logical>,
        root_role: SurfaceRoleDescription,
        root_parent_surface_id: u64,
        popup_root_surface_id: u64,
        expects_sample: bool,
        composition_order: &mut u32,
        layers: &mut Vec<SurfaceLayerDescription>,
        textures: &mut Vec<ExternalTextureFrame>,
    ) {
        with_surface_tree_upward(
            root,
            SurfaceTreeContext {
                location: origin,
                parent_surface_id: root_parent_surface_id,
            },
            |surface, states, context| {
                let Some(renderer_state) = states.data_map.get::<RendererSurfaceStateUserData>()
                else {
                    return TraversalAction::SkipChildren;
                };
                let renderer_state = renderer_state
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                match renderer_state.view() {
                    Some(view) => {
                        let Some(surface_id) = self.surface_id(surface) else {
                            return TraversalAction::SkipChildren;
                        };
                        TraversalAction::DoChildren(SurfaceTreeContext {
                            location: saturating_point_add(context.location, view.offset),
                            parent_surface_id: surface_id,
                        })
                    }
                    None => TraversalAction::SkipChildren,
                }
            },
            |surface, states, context| {
                let Some(surface_id) = self.surface_id(surface) else {
                    return;
                };
                let Some(renderer_state) = states.data_map.get::<RendererSurfaceStateUserData>()
                else {
                    return;
                };
                let renderer_state = renderer_state
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                let Some(view) = renderer_state.view() else {
                    return;
                };
                if view.dst.w <= 0 || view.dst.h <= 0 {
                    return;
                }

                let location = saturating_point_add(context.location, view.offset);
                let transform = renderer_state.buffer_transform();
                let scale = renderer_state.buffer_scale().max(1);
                let source = renderer_state
                    .buffer_size()
                    .map(|buffer_size| {
                        view.src
                            .to_buffer(f64::from(scale), transform, &buffer_size.to_f64())
                    })
                    .unwrap_or_default();
                let renderer_buffer = renderer_state.buffer();
                let opaque = renderer_state.opaque_regions().is_some_and(|regions| {
                    Rectangle::from_size(view.dst)
                        .subtract_rects(regions.iter().copied())
                        .is_empty()
                });
                let dmabuf = renderer_buffer
                    .and_then(|buffer| get_dmabuf(buffer).ok())
                    .cloned();
                let buffer_guard = dmabuf.as_ref().and_then(|_| renderer_buffer.cloned());
                let (texture_id, width, height) = if let (Some(dmabuf), Some(buffer_guard)) =
                    (dmabuf, buffer_guard)
                {
                    let width = dmabuf.width();
                    let height = dmabuf.height();
                    let Ok(texture_id) = i64::try_from(surface_id) else {
                        return;
                    };
                    let revision = self
                        .surface_buffer_revisions
                        .get(&surface.id())
                        .copied()
                        .unwrap_or_default();
                    textures.push(ExternalTextureFrame::from_dmabuf(
                        texture_id,
                        dmabuf,
                        buffer_guard,
                        revision,
                        expects_sample,
                    ));
                    (surface_id, width, height)
                } else if let Some(frame) = self.surface_shm_frames.get(&surface.id()).cloned() {
                    let width = frame.width();
                    let height = frame.height();
                    let Ok(texture_id) = i64::try_from(surface_id) else {
                        return;
                    };
                    textures.push(ExternalTextureFrame::from_shm(
                        texture_id,
                        frame,
                        expects_sample,
                    ));
                    (surface_id, width, height)
                } else {
                    (0, 0, 0)
                };
                let role = if surface == root {
                    root_role
                } else {
                    SurfaceRoleDescription::Subsurface
                };
                layers.push(SurfaceLayerDescription {
                    surface_id,
                    parent_surface_id: context.parent_surface_id,
                    popup_root_surface_id,
                    role,
                    texture_id,
                    width,
                    height,
                    surface_x: f64::from(location.x),
                    surface_y: f64::from(location.y),
                    surface_width: f64::from(view.dst.w),
                    surface_height: f64::from(view.dst.h),
                    texture_source_x: source.loc.x,
                    texture_source_y: source.loc.y,
                    texture_source_width: source.size.w,
                    texture_source_height: source.size.h,
                    transform: transform_to_wire(transform),
                    scale_120: u32::try_from(scale).unwrap_or(1).saturating_mul(120),
                    composition_order: *composition_order,
                    opacity: 1.0,
                    opaque,
                });
                *composition_order = composition_order.saturating_add(1);
            },
            |_, _, _| true,
        );
    }

    #[cfg(feature = "flutter")]
    fn external_texture_frame(
        &self,
        surface_id: u64,
        expects_sample: bool,
    ) -> Option<ExternalTextureFrame> {
        let surface = self.surfaces_by_id.get(&surface_id)?;
        let (renderable, dmabuf_source) = with_renderer_surface_state(surface, |state| {
            let renderable = state
                .view()
                .is_some_and(|view| view.dst.w > 0 && view.dst.h > 0);
            let renderer_buffer = state.buffer();
            let dmabuf = renderer_buffer
                .and_then(|buffer| get_dmabuf(buffer).ok())
                .cloned();
            let buffer_guard = dmabuf.as_ref().and_then(|_| renderer_buffer.cloned());
            (renderable, dmabuf.zip(buffer_guard))
        })?;
        if !renderable {
            return None;
        }
        let texture_id = i64::try_from(surface_id).ok().filter(|id| *id > 0)?;
        if let Some((dmabuf, buffer_guard)) = dmabuf_source {
            let revision = self
                .surface_buffer_revisions
                .get(&surface.id())
                .copied()
                .unwrap_or_default();
            return Some(ExternalTextureFrame::from_dmabuf(
                texture_id,
                dmabuf,
                buffer_guard,
                revision,
                expects_sample,
            ));
        }
        self.surface_shm_frames
            .get(&surface.id())
            .cloned()
            .map(|frame| ExternalTextureFrame::from_shm(texture_id, frame, expects_sample))
    }

    /// Build source updates only for surfaces whose already-published layout
    /// is unchanged. `None` requests a conservative full scene rebuild.
    #[cfg(feature = "flutter")]
    pub fn flutter_dirty_textures(
        &mut self,
        surface_ids: impl IntoIterator<Item = u64>,
    ) -> Option<Vec<ExternalTextureFrame>> {
        let mut textures = std::mem::take(&mut self.scene_textures_scratch);
        textures.clear();
        for surface_id in surface_ids {
            let Some(window_id) = self.scene_surface_windows.get(&surface_id).copied() else {
                self.scene_textures_scratch = textures;
                return None;
            };
            let expects_sample = window_expects_sample(
                self.input_visibility_known,
                &self.visible_window_ids,
                window_id,
            );
            let Some(frame) = self.external_texture_frame(surface_id, expects_sample) else {
                self.scene_textures_scratch = textures;
                return None;
            };
            textures.push(frame);
        }
        Some(textures)
    }

    #[cfg(feature = "flutter")]
    pub fn recycle_flutter_dirty_textures(&mut self, mut textures: Vec<ExternalTextureFrame>) {
        textures.clear();
        debug_assert!(self.scene_textures_scratch.is_empty());
        self.scene_textures_scratch = textures;
    }

    #[cfg(feature = "flutter")]
    fn surface_tree_offset(
        &self,
        root: &WlSurface,
        target: &WlSurface,
    ) -> Option<Point<i32, Logical>> {
        let mut target_offset = None;
        with_surface_tree_upward(
            root,
            Point::from((0, 0)),
            |surface, states, location| {
                let Some(renderer_state) = states.data_map.get::<RendererSurfaceStateUserData>()
                else {
                    return TraversalAction::SkipChildren;
                };
                let renderer_state = renderer_state
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                let Some(view) = renderer_state.view() else {
                    return TraversalAction::SkipChildren;
                };
                let location = saturating_point_add(*location, view.offset);
                if surface == target {
                    target_offset = Some(location);
                }
                TraversalAction::DoChildren(location)
            },
            |_, _, _| {},
            |_, _, _| true,
        );
        target_offset
    }

    #[cfg(feature = "flutter")]
    fn input_method_editor_rectangle_global(&self) -> Option<Rectangle<i32, Logical>> {
        let editor = self.input_method.active_editor()?;
        let rectangle = editor.cursor_rectangle.unwrap_or_default();
        let origin = match editor.endpoint {
            EditorEndpoint::Flutter { .. } => Point::from((
                self.atlas_origin
                    .x
                    .round()
                    .clamp(f64::from(i32::MIN), f64::from(i32::MAX)) as i32,
                self.atlas_origin
                    .y
                    .round()
                    .clamp(f64::from(i32::MIN), f64::from(i32::MAX)) as i32,
            )),
            EditorEndpoint::Wayland { surface, .. } => {
                let root = self.owning_toplevel_surface(&surface)?;
                let window = self.window_for_root_surface(&root)?;
                let root_origin = saturating_point_sub(
                    self.window_geometry_target(&window).loc,
                    window.geometry().loc,
                );
                let surface_offset = self.surface_tree_offset(&root, &surface)?;
                saturating_point_add(root_origin, surface_offset)
            }
        };
        Some(Rectangle::new(
            saturating_point_add(origin, rectangle.loc),
            rectangle.size,
        ))
    }

    #[cfg(feature = "flutter")]
    fn place_input_method_popup(
        &self,
        cursor: Rectangle<i32, Logical>,
        size: Size<i32, Logical>,
    ) -> Rectangle<i32, Logical> {
        let anchor = Rectangle::new(
            Point::from((cursor.loc.x, cursor.loc.y.saturating_add(cursor.size.h))),
            (1, 1).into(),
        );
        let bounds = self
            .output_for_geometry(anchor)
            .map(|output| output.logical_geometry)
            .unwrap_or(self.desktop_bounds);
        let width = size.w.max(1).min(bounds.size.w.max(1));
        let height = size.h.max(1).min(bounds.size.h.max(1));
        let right = bounds
            .loc
            .x
            .saturating_add(bounds.size.w)
            .saturating_sub(width);
        let bottom = bounds
            .loc
            .y
            .saturating_add(bounds.size.h)
            .saturating_sub(height);
        let x = cursor.loc.x.clamp(bounds.loc.x, right.max(bounds.loc.x));
        let below = cursor.loc.y.saturating_add(cursor.size.h);
        let above = cursor.loc.y.saturating_sub(height);
        let y = if below <= bottom { below } else { above }
            .clamp(bounds.loc.y, bottom.max(bounds.loc.y));
        Rectangle::new((x, y).into(), (width, height).into())
    }

    #[cfg(feature = "flutter")]
    pub fn flutter_scene(
        &mut self,
    ) -> Result<(Vec<WindowDescription>, Vec<ExternalTextureFrame>), Box<dyn Error>> {
        let mut windows = std::mem::take(&mut self.scene_windows_scratch);
        let mut textures = std::mem::take(&mut self.scene_textures_scratch);
        textures.clear();
        let mut popups = std::mem::take(&mut self.scene_popups_scratch);
        popups.clear();
        let mut surface_windows = std::mem::take(&mut self.scene_surface_windows_scratch);
        surface_windows.clear();
        let mut complex_windows = std::mem::take(&mut self.scene_complex_windows_scratch);
        complex_windows.clear();
        let input_method_editor_rectangle = self.input_method_editor_rectangle_global();
        let input_method_popups = self.input_method.visible_popups();
        let mut window_count = 0;
        for window in self.space.elements() {
            let Some(surface) = self.window_root_surface(window) else {
                continue;
            };
            let Some(stable_id) = self.surface_id(&surface) else {
                let x11 = window.x11_surface();
                warn!(
                    surface = ?surface.id(),
                    surface_alive = surface.is_alive(),
                    backend = if x11.is_some() { "x11" } else { "wayland" },
                    x11_window = ?x11.as_ref().map(|surface| surface.window_id()),
                    x11_override_redirect = ?x11
                        .as_ref()
                        .map(|surface| surface.is_override_redirect()),
                    "omitting desktop window without a stable surface identifier"
                );
                // TODO: Make surface destruction and desktop-window eviction
                // atomic and idempotent. A wl_surface destruction callback can
                // remove the stable identity before the XDG/Xwayland teardown
                // callback removes its Window from Space, especially during
                // Xwayland override-redirect remaps.
                continue;
            };
            let geometry = self.window_geometry_target(window);
            if geometry.size.w <= 0 || geometry.size.h <= 0 {
                continue;
            }
            let content = window.geometry();
            if content.size.w <= 0 || content.size.h <= 0 {
                continue;
            }
            let (mut title, mut app_id, mut layers) = windows
                .get_mut(window_count)
                .map(|previous| {
                    (
                        std::mem::take(&mut previous.title),
                        std::mem::take(&mut previous.app_id),
                        std::mem::take(&mut previous.surfaces),
                    )
                })
                .unwrap_or_default();
            title.clear();
            app_id.clear();
            layers.clear();
            let x11 = window.x11_surface();
            if window.toplevel().is_some() {
                with_states(&surface, |states| {
                    let Some(attributes) = states.data_map.get::<XdgToplevelSurfaceData>() else {
                        return;
                    };
                    let attributes = attributes
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner());
                    if let Some(value) = &attributes.title {
                        title.push_str(value);
                    }
                    if let Some(value) = &attributes.app_id {
                        app_id.push_str(value);
                    }
                });
            } else if let Some(x11) = x11.as_ref() {
                // Smithay exposes these X11 properties as owned strings.
                title = x11.title();
                app_id = x11.class();
            }
            let mut composition_order = 0;
            // Flutter does not sample a texture after its window leaves the
            // visible scene (for example, once a minimize animation reaches
            // zero opacity). Mailbox those buffers without waiting for a
            // sample so restore begins with the client's latest generation.
            // Until Dart publishes its first visibility snapshot, preserve
            // the conservative sampled-texture lifetime contract.
            let expects_sample = window_expects_sample(
                self.input_visibility_known,
                &self.visible_window_ids,
                stable_id,
            );
            self.append_surface_tree(
                &surface,
                (0, 0).into(),
                SurfaceRoleDescription::Root,
                0,
                0,
                expects_sample,
                &mut composition_order,
                &mut layers,
                &mut textures,
            );

            popups.extend(PopupManager::popups_for_surface(&surface));
            popups.reverse();
            for (popup, popup_location) in popups.drain(..) {
                let popup_surface = popup.wl_surface();
                let Some(popup_surface_id) = self.surface_id(popup_surface) else {
                    continue;
                };
                let parent_surface_id = match &popup {
                    PopupKind::Xdg(popup) => popup
                        .get_parent_surface()
                        .and_then(|parent| self.surface_id(&parent))
                        .unwrap_or(0),
                    PopupKind::InputMethod(_) => 0,
                };
                let popup_origin = saturating_point_sub(
                    saturating_point_add(content.loc, popup_location),
                    popup.geometry().loc,
                );
                self.append_surface_tree(
                    popup_surface,
                    popup_origin,
                    SurfaceRoleDescription::Popup,
                    parent_surface_id,
                    popup_surface_id,
                    expects_sample,
                    &mut composition_order,
                    &mut layers,
                    &mut textures,
                );
            }

            for layer in &layers {
                if layer.texture_id > 0 {
                    surface_windows.insert(layer.surface_id, stable_id);
                }
            }
            if layers.len() != 1 || layers[0].surface_id != stable_id {
                // Smithay exposes no compositor callback for immediate
                // wl_subsurface stacking requests. Keep multi-layer windows
                // on the metadata path so a later buffer commit cannot hide
                // an intervening order change from Flutter.
                complex_windows.insert(stable_id);
            }

            let root_layer = layers.iter().find(|layer| layer.surface_id == stable_id);
            let fallback_width = u32::try_from(content.size.w)?;
            let fallback_height = u32::try_from(content.size.h)?;
            let (
                texture_id,
                root_width,
                root_height,
                texture_source_x,
                texture_source_y,
                texture_source_width,
                texture_source_height,
                transform,
                scale_120,
                opacity,
            ) = root_layer.map_or((0, 0, 0, 0.0, 0.0, 0.0, 0.0, 0, 120, 1.0), |layer| {
                (
                    layer.texture_id,
                    layer.width,
                    layer.height,
                    layer.texture_source_x,
                    layer.texture_source_y,
                    layer.texture_source_width,
                    layer.texture_source_height,
                    layer.transform,
                    layer.scale_120,
                    layer.opacity,
                )
            });
            let width = if root_width > 0 {
                root_width
            } else {
                fallback_width
            };
            let height = if root_height > 0 {
                root_height
            } else {
                fallback_height
            };
            let monitor_id = self
                .output_for_geometry(geometry)
                .and_then(|entry| i64::try_from(entry.id.0).ok())
                .unwrap_or(-1);
            let (suppress_animations, server_side_decorated, window_opacity) = x11
                .as_ref()
                .map(|x11| {
                    let server_side_decorated = shell_draws_x11_server_frame(x11);
                    (
                        !server_side_decorated,
                        server_side_decorated,
                        xwayland::x11_window_opacity(x11),
                    )
                })
                .unwrap_or((false, true, 1.0));
            if window_opacity < 1.0 {
                for layer in &mut layers {
                    layer.opacity *= window_opacity;
                    layer.opaque = false;
                }
            }
            let opacity_class = with_renderer_surface_state(&surface, |state| {
                let Some(view) = state.view() else {
                    return WindowOpacityClass::ContentTranslucent;
                };
                classify_window_opacity(
                    Rectangle::from_size(view.dst),
                    content,
                    state.opaque_regions(),
                    opacity * window_opacity,
                )
            })
            .unwrap_or(WindowOpacityClass::ContentTranslucent);
            let description = WindowDescription {
                object_id: stable_id,
                surface_id: stable_id,
                window_id: stable_id,
                texture_id,
                title,
                app_id,
                width,
                height,
                surface_x: f64::from(content.loc.x),
                surface_y: f64::from(content.loc.y),
                surface_width: f64::from(content.size.w),
                surface_height: f64::from(content.size.h),
                texture_source_x,
                texture_source_y,
                texture_source_width,
                texture_source_height,
                geometry_x: f64::from(geometry.loc.x) - self.atlas_origin.x,
                geometry_y: f64::from(geometry.loc.y) - self.atlas_origin.y,
                geometry_width: f64::from(geometry.size.w),
                geometry_height: f64::from(geometry.size.h),
                monitor_id,
                transform,
                scale_120,
                content_x: f64::from(content.loc.x),
                content_y: f64::from(content.loc.y),
                content_width: f64::from(content.size.w),
                content_height: f64::from(content.size.h),
                suppress_animations,
                server_side_decorated,
                opacity: opacity * window_opacity,
                surfaces: layers,
                content_kind: WindowContentKind::SurfaceTree,
                opacity_class,
            };
            if let Some(previous) = windows.get_mut(window_count) {
                *previous = description;
            } else {
                windows.push(description);
            }
            window_count += 1;
        }
        for local_window in self.local_windows.iter() {
            let width = local_window
                .geometry
                .width
                .round()
                .clamp(1.0, f64::from(u32::MAX)) as u32;
            let height = local_window
                .geometry
                .height
                .round()
                .clamp(1.0, f64::from(u32::MAX)) as u32;
            let global_geometry = Rectangle::<i32, Logical>::new(
                Point::from((
                    local_window
                        .geometry
                        .x
                        .round()
                        .clamp(f64::from(i32::MIN), f64::from(i32::MAX)) as i32,
                    local_window
                        .geometry
                        .y
                        .round()
                        .clamp(f64::from(i32::MIN), f64::from(i32::MAX)) as i32,
                )),
                Size::from((
                    i32::try_from(width).unwrap_or(i32::MAX),
                    i32::try_from(height).unwrap_or(i32::MAX),
                )),
            );
            let monitor_id = self
                .output_for_geometry(global_geometry)
                .and_then(|entry| i64::try_from(entry.id.0).ok())
                .unwrap_or(-1);
            let (mut title, mut app_id, mut surfaces) = windows
                .get_mut(window_count)
                .map(|previous| {
                    (
                        std::mem::take(&mut previous.title),
                        std::mem::take(&mut previous.app_id),
                        std::mem::take(&mut previous.surfaces),
                    )
                })
                .unwrap_or_default();
            title.clear();
            title.push_str(&local_window.title);
            app_id.clear();
            app_id.push_str(&local_window.app_id);
            surfaces.clear();
            let description = WindowDescription {
                object_id: local_window.id,
                surface_id: local_window.id,
                window_id: local_window.id,
                texture_id: 0,
                title,
                app_id,
                width,
                height,
                surface_x: 0.0,
                surface_y: 0.0,
                surface_width: local_window.geometry.width,
                surface_height: local_window.geometry.height,
                texture_source_x: 0.0,
                texture_source_y: 0.0,
                texture_source_width: 0.0,
                texture_source_height: 0.0,
                geometry_x: local_window.geometry.x - self.atlas_origin.x,
                geometry_y: local_window.geometry.y - self.atlas_origin.y,
                geometry_width: local_window.geometry.width,
                geometry_height: local_window.geometry.height,
                monitor_id,
                transform: 0,
                scale_120: 120,
                content_x: 0.0,
                content_y: 0.0,
                content_width: local_window.geometry.width,
                content_height: local_window.geometry.height,
                suppress_animations: false,
                server_side_decorated: true,
                opacity: 1.0,
                surfaces,
                content_kind: WindowContentKind::LocalFlutter,
                opacity_class: WindowOpacityClass::FullyOpaque,
            };
            if let Some(previous) = windows.get_mut(window_count) {
                *previous = description;
            } else {
                windows.push(description);
            }
            window_count += 1;
        }
        if let Some(cursor_rectangle) = input_method_editor_rectangle {
            for popup in input_method_popups {
                let surface = popup.surface();
                let Some(stable_id) = self.surface_id(surface) else {
                    continue;
                };
                let (mut title, mut app_id, mut layers) = windows
                    .get_mut(window_count)
                    .map(|previous| {
                        (
                            std::mem::take(&mut previous.title),
                            std::mem::take(&mut previous.app_id),
                            std::mem::take(&mut previous.surfaces),
                        )
                    })
                    .unwrap_or_default();
                title.clear();
                title.push_str("Input method");
                app_id.clear();
                app_id.push_str("denia-systemui-input-method");
                layers.clear();
                let expects_sample = window_expects_sample(
                    self.input_visibility_known,
                    &self.visible_window_ids,
                    stable_id,
                );
                let mut composition_order = 0;
                self.append_surface_tree(
                    surface,
                    (0, 0).into(),
                    SurfaceRoleDescription::Root,
                    0,
                    0,
                    expects_sample,
                    &mut composition_order,
                    &mut layers,
                    &mut textures,
                );
                if layers.is_empty() {
                    continue;
                }
                let min_x = layers
                    .iter()
                    .map(|layer| layer.surface_x)
                    .fold(f64::INFINITY, f64::min);
                let min_y = layers
                    .iter()
                    .map(|layer| layer.surface_y)
                    .fold(f64::INFINITY, f64::min);
                let max_x = layers
                    .iter()
                    .map(|layer| layer.surface_x + layer.surface_width)
                    .fold(f64::NEG_INFINITY, f64::max);
                let max_y = layers
                    .iter()
                    .map(|layer| layer.surface_y + layer.surface_height)
                    .fold(f64::NEG_INFINITY, f64::max);
                let logical_width = (max_x - min_x).ceil().clamp(1.0, f64::from(i32::MAX)) as i32;
                let logical_height = (max_y - min_y).ceil().clamp(1.0, f64::from(i32::MAX)) as i32;
                let geometry = self.place_input_method_popup(
                    cursor_rectangle,
                    (logical_width, logical_height).into(),
                );
                for layer in &layers {
                    if layer.texture_id > 0 {
                        surface_windows.insert(layer.surface_id, stable_id);
                    }
                }
                if layers.len() != 1 || layers[0].surface_id != stable_id {
                    complex_windows.insert(stable_id);
                }
                let root_layer = layers.iter().find(|layer| layer.surface_id == stable_id);
                let (
                    texture_id,
                    width,
                    height,
                    texture_source_x,
                    texture_source_y,
                    texture_source_width,
                    texture_source_height,
                    transform,
                    scale_120,
                ) = root_layer.map_or((0, 0, 0, 0.0, 0.0, 0.0, 0.0, 0, 120), |layer| {
                    (
                        layer.texture_id,
                        layer.width,
                        layer.height,
                        layer.texture_source_x,
                        layer.texture_source_y,
                        layer.texture_source_width,
                        layer.texture_source_height,
                        layer.transform,
                        layer.scale_120,
                    )
                });
                let monitor_id = self
                    .output_for_geometry(geometry)
                    .and_then(|output| i64::try_from(output.id.0).ok())
                    .unwrap_or(-1);
                let description = WindowDescription {
                    object_id: stable_id,
                    surface_id: stable_id,
                    window_id: stable_id,
                    texture_id,
                    title,
                    app_id,
                    width,
                    height,
                    surface_x: min_x,
                    surface_y: min_y,
                    surface_width: f64::from(logical_width),
                    surface_height: f64::from(logical_height),
                    texture_source_x,
                    texture_source_y,
                    texture_source_width,
                    texture_source_height,
                    geometry_x: f64::from(geometry.loc.x) - self.atlas_origin.x,
                    geometry_y: f64::from(geometry.loc.y) - self.atlas_origin.y,
                    geometry_width: f64::from(geometry.size.w),
                    geometry_height: f64::from(geometry.size.h),
                    monitor_id,
                    transform,
                    scale_120,
                    content_x: min_x,
                    content_y: min_y,
                    content_width: f64::from(logical_width),
                    content_height: f64::from(logical_height),
                    suppress_animations: true,
                    server_side_decorated: false,
                    opacity: 1.0,
                    surfaces: layers,
                    content_kind: WindowContentKind::SurfaceTree,
                    opacity_class: WindowOpacityClass::ContentTranslucent,
                };
                if let Some(previous) = windows.get_mut(window_count) {
                    *previous = description;
                } else {
                    windows.push(description);
                }
                window_count += 1;
            }
        }
        windows.truncate(window_count);
        self.scene_popups_scratch = popups;
        std::mem::swap(&mut self.scene_surface_windows, &mut surface_windows);
        self.scene_surface_windows_scratch = surface_windows;
        std::mem::swap(&mut self.scene_complex_windows, &mut complex_windows);
        self.scene_complex_windows_scratch = complex_windows;
        Ok((windows, textures))
    }

    #[cfg(feature = "flutter")]
    pub fn recycle_flutter_scene(
        &mut self,
        windows: Vec<WindowDescription>,
        textures: Vec<ExternalTextureFrame>,
    ) {
        debug_assert!(self.scene_windows_scratch.is_empty());
        debug_assert!(self.scene_textures_scratch.is_empty());
        self.scene_windows_scratch = windows;
        self.scene_textures_scratch = textures;
    }

    #[cfg(feature = "flutter")]
    pub fn install_input_layout(
        &mut self,
        layout: InputLayoutSnapshot,
    ) -> (Option<InputLayoutSnapshot>, bool, bool) {
        self.text_input
            .set_shell_capture(layout.keyboard_capture() || layout.exclusive_shell());
        let input_method_changed = self.synchronize_input_method();
        let first_generation_layout = self.input_layout.is_none();
        let routing_changed = input_routing_changed(self.input_layout.as_ref(), &layout);
        let visibility_changed = input_visibility_changed(self.input_layout.as_ref(), &layout);
        if visibility_changed {
            let mut root_ids = std::mem::take(&mut self.input_root_ids_scratch);
            root_ids.clear();
            for window in self.space.elements() {
                let Some(root) = self.window_root_surface(window) else {
                    continue;
                };
                if let Some(window_id) = self.surface_id(&root) {
                    root_ids.insert(root.id(), window_id);
                }
            }

            let mut visible_window_ids = std::mem::take(&mut self.visible_window_ids);
            visible_window_ids.clear();
            for surface_id in &layout.visible_surface_ids {
                let Some(surface) = self.surfaces_by_id.get(surface_id) else {
                    continue;
                };
                let root = self.toplevel_candidate_surface(surface);
                if let Some(window_id) = root_ids.get(&root.id()).copied() {
                    visible_window_ids.insert(window_id);
                }
            }
            self.input_root_ids_scratch = root_ids;
            self.visible_window_ids = visible_window_ids;
        }
        self.input_visibility_known = true;
        let previous = self.input_layout.replace(layout);
        if routing_changed {
            self.client_input_route_cache = None;
        }
        if first_generation_layout {
            // InputLayout is published from the live widget tree, after the
            // replacement Dart bridge has subscribed to cursor updates.
            self.queue_cursor_state_for_flutter_generation();
        }
        (
            previous,
            visibility_changed || input_method_changed,
            routing_changed,
        )
    }

    #[cfg(feature = "flutter")]
    fn queue_cursor_state_for_flutter_generation(&mut self) {
        self.published_cursor_shape = None;
        if !self.pointer_cursor_visible {
            self.pending_cursor_shape = Some("none");
            self.pending_cursor_position = None;
            return;
        }
        match self.routed_pointer_target {
            RoutedPointerTarget::Flutter => {
                self.pending_cursor_shape = None;
                self.pending_cursor_position = None;
            }
            RoutedPointerTarget::Client(_) => {
                self.pending_cursor_shape = Some(software_cursor_shape(&self.cursor_status));
                self.pending_cursor_position = Some(self.flutter_scene_pointer_position());
            }
        }
    }

    #[cfg(feature = "flutter")]
    pub(super) fn reset_flutter_input_generation(&mut self) {
        // The replacement engine has not observed the old generation's
        // layout, pressed keys, or active touch sequences. Forget them so a
        // later release/up cannot be delivered to the new engine without its
        // matching press/down. Client captures and routes remain untouched.
        self.input_layout = None;
        self.text_input.set_shell_capture(false);
        self.text_input.retire_flutter_generation();
        self.synchronize_input_method();
        self.visible_window_ids.clear();
        self.input_visibility_known = false;
        self.client_input_route_cache = None;
        self.flutter_touch_slots.clear();
        // Cursor publication belongs to the Flutter engine generation too.
        // Replay native client state to the replacement renderer, while a
        // Flutter-owned route will select its shape after the fresh Add/Hover.
        self.queue_cursor_state_for_flutter_generation();
        input::retire_flutter_generation_keys(
            &mut self.flutter_keyboard_keys,
            &mut self.retired_keyboard_keys,
        );
    }

    fn surface_under(
        &self,
        position: Point<f64, Logical>,
    ) -> Option<(WlSurface, Point<f64, Logical>)> {
        self.space
            .element_under(position)
            .and_then(|(window, location)| {
                window
                    .surface_under(position - location.to_f64(), WindowSurfaceType::ALL)
                    .map(|(surface, offset)| {
                        (surface, saturating_point_add(offset, location).to_f64())
                    })
            })
    }

    fn clamp_pointer(&self, position: Point<f64, Logical>) -> Point<f64, Logical> {
        let right = f64::from(self.desktop_bounds.loc.x + self.desktop_bounds.size.w - 1);
        let bottom = f64::from(self.desktop_bounds.loc.y + self.desktop_bounds.size.h - 1);
        Point::from((
            position
                .x
                .clamp(f64::from(self.desktop_bounds.loc.x), right),
            position
                .y
                .clamp(f64::from(self.desktop_bounds.loc.y), bottom),
        ))
    }

    /// Projects the compositor-owned logical pointer into Flutter's physical
    /// atlas pixels, as required by `FlutterPointerEvent`.
    #[cfg(feature = "flutter")]
    pub(super) fn flutter_pointer_position_physical(&self) -> (f64, f64) {
        (
            (self.pointer_location.x - self.atlas_origin.x) * self.atlas_scale,
            (self.pointer_location.y - self.atlas_origin.y) * self.atlas_scale,
        )
    }

    /// Projects the compositor-owned pointer into Flutter framework logical
    /// coordinates. Structured messages consumed directly by Dart do not pass
    /// through Flutter's physical-to-logical pointer-event conversion.
    #[cfg(feature = "flutter")]
    fn flutter_scene_pointer_position(&self) -> (f64, f64) {
        (
            self.pointer_location.x - self.atlas_origin.x,
            self.pointer_location.y - self.atlas_origin.y,
        )
    }

    fn control_output_under_pointer(&self) -> Option<(&str, i64)> {
        let pointer = Point::from((
            self.pointer_location.x.floor() as i32,
            self.pointer_location.y.floor() as i32,
        ));
        self.outputs.iter().find_map(|entry| {
            if !entry.logical_geometry.contains(pointer) {
                return None;
            }
            Some((entry.connector.as_str(), i64::try_from(entry.id.0).ok()?))
        })
    }

    pub fn render(
        &mut self,
        renderer: &mut GlesRenderer,
        dmabuf: &mut Dmabuf,
    ) -> Result<(), Box<dyn Error>> {
        let mut framebuffer = renderer.bind(dmabuf)?;
        let output_result = smithay::desktop::space::render_output::<
            _,
            WaylandSurfaceRenderElement<GlesRenderer>,
            _,
            _,
        >(
            &self.atlas_output,
            renderer,
            &mut framebuffer,
            1.0,
            0,
            [&self.space],
            &[],
            &mut self.damage_tracker,
            [0.015, 0.02, 0.035, 1.0],
        )?;
        drop(output_result);

        if !matches!(self.cursor_status, CursorImageStatus::Hidden) {
            let logical_cursor = self.pointer_location - self.atlas_origin;
            let cursor_rect = Rectangle::<i32, Physical>::new(
                (
                    (logical_cursor.x * self.atlas_scale).round() as i32,
                    (logical_cursor.y * self.atlas_scale).round() as i32,
                )
                    .into(),
                (12, 20).into(),
            );
            let mut frame =
                renderer.render(&mut framebuffer, self.atlas_size, Transform::Normal)?;
            frame.clear(Color32F::new(0.96, 0.98, 1.0, 1.0), &[cursor_rect])?;
            frame.finish()?.wait()?;
        }
        Ok(())
    }

    pub fn frame_submitted(&mut self) -> Result<(), Box<dyn Error>> {
        debug_assert!(self.seat.get_keyboard().is_some());
        debug_assert!(self.seat.get_pointer().is_some());
        debug_assert!(self.seat.get_touch().is_some());
        let elapsed = self.start_time.elapsed();
        let windows = self
            .space
            .elements()
            .map(|window| {
                // A frame callback is one-shot even when the atlas spans several
                // CRTCs. Attribute it to the physical output owning this window
                // instead of sending once per output (or hardcoding output zero).
                let frame_output = self
                    .output_for_geometry(self.window_geometry_target(window))
                    .map(|entry| entry.output.clone())
                    .unwrap_or_else(|| self.atlas_output.clone());
                (window.clone(), frame_output)
            })
            .collect::<Vec<_>>();
        self.presentation.submitted(windows, elapsed);
        self.display_handle.flush_clients()?;
        Ok(())
    }

    #[cfg(feature = "flutter")]
    pub fn outputs_submitted(&mut self, output_ids: &[OutputId]) -> Result<(), Box<dyn Error>> {
        if output_ids.is_empty() {
            return Ok(());
        }

        self.presentation.begin_output_batch();
        for entry in &mut self.outputs {
            entry.submitted_this_batch = output_ids.contains(&entry.id);
            if entry.submitted_this_batch {
                entry.presentation_batch.begin(&entry.output);
                for window in self.output_window_membership.windows(entry.id) {
                    entry
                        .presentation_batch
                        .submit_window(&entry.output, window);
                }
            }
        }
        self.display_handle.flush_clients()?;
        Ok(())
    }

    #[cfg(feature = "flutter")]
    pub fn outputs_presented(
        &mut self,
        outputs: &[super::PresentedOutput],
    ) -> Result<(), Box<dyn Error>> {
        let mut presented = false;
        let observed_now = Instant::now();
        for presented_output in outputs.iter().copied() {
            if let Some(entry) = self
                .outputs
                .iter_mut()
                .find(|entry| entry.id == presented_output.id)
            {
                self.presentation.presented_output(
                    &mut entry.presentation_batch,
                    presented_output.presented_at,
                    observed_now.saturating_duration_since(presented_output.observed_at),
                    presented_output.sequence,
                );
                presented = true;
            }
        }
        if !presented {
            return Ok(());
        }
        self.space.refresh();
        self.popups.cleanup();
        self.display_handle.flush_clients()?;
        Ok(())
    }

    #[cfg(feature = "flutter")]
    pub fn frame_tick(&mut self, tick: FrameTick) -> Result<(), Box<dyn Error>> {
        let callback_time = tick
            .presented_at
            .unwrap_or_else(|| self.presentation.monotonic_now());
        let mut sent = 0usize;
        for window in self.output_window_membership.windows(tick.output) {
            sent = sent.saturating_add(presentation::send_window_frame_callbacks(
                window,
                callback_time,
            ));
        }
        let callback_millis = callback_time.as_millis() as u32;
        for popup in self.input_method.visible_popups() {
            if self
                .surface_id(popup.surface())
                .is_some_and(|surface_id| self.visible_window_ids.contains(&surface_id))
            {
                sent = sent.saturating_add(presentation::send_surface_frame_callbacks(
                    popup.surface(),
                    callback_millis,
                ));
            }
        }
        if sent == 0 {
            return Ok(());
        }
        self.display_handle.flush_clients()?;
        Ok(())
    }

    pub fn after_present(&mut self) -> Result<(), Box<dyn Error>> {
        self.presentation.presented();
        self.space.refresh();
        self.popups.cleanup();
        self.display_handle.flush_clients()?;
        Ok(())
    }

    fn unconstrain_popup(&self, popup: &PopupSurface) {
        let popup_kind = PopupKind::Xdg(popup.clone());
        let Ok(root) = find_popup_root_surface(&popup_kind) else {
            return;
        };
        let Some(window) = self.space.elements().find(|window| {
            window
                .toplevel()
                .is_some_and(|top| top.wl_surface() == &root)
        }) else {
            return;
        };
        let window_geometry = self.space.element_geometry(window).unwrap_or_default();
        let parent_offset = get_popup_toplevel_coords(&popup_kind);
        let positioner = popup.with_pending_state(|state| state.positioner);
        let desired_geometry = positioner.get_geometry();
        let anchor = saturating_point_add(
            saturating_point_add(
                saturating_point_add(window_geometry.loc, parent_offset),
                positioner.anchor_rect.loc,
            ),
            Point::from((
                positioner.anchor_rect.size.w / 2,
                positioner.anchor_rect.size.h / 2,
            )),
        );
        let desired_global = Rectangle::new(
            saturating_point_add(
                saturating_point_add(window_geometry.loc, parent_offset),
                desired_geometry.loc,
            ),
            desired_geometry.size,
        );
        let output_geometry = choose_popup_output(
            self.outputs
                .iter()
                .filter_map(|entry| self.space.output_geometry(&entry.output)),
            anchor,
            desired_global,
        );
        let Some(output_geometry) = output_geometry else {
            return;
        };
        let mut target = output_geometry;
        target.loc = saturating_point_sub(
            saturating_point_sub(target.loc, parent_offset),
            window_geometry.loc,
        );
        popup.with_pending_state(|state| {
            state.geometry = state.positioner.get_unconstrained_geometry(target);
        });
    }
}

fn init_listener(
    display: Display<RuntimeState>,
    event_loop: &mut EventLoop<'_, RuntimeState>,
    client_budget: Arc<WaylandClientBudget>,
) -> Result<OsString, Box<dyn Error>> {
    let listening_socket = ListeningSocketSource::new_auto()?;
    let socket_name = listening_socket.socket_name().to_os_string();
    event_loop
        .handle()
        .insert_source(listening_socket, move |client_stream, _, state| {
            info!("accepted Wayland client connection");
            let Some(frontend) = state.wayland.as_mut() else {
                warn!("discarding Wayland connection without frontend state");
                return;
            };
            let Some(client_state) = client_budget.try_reserve_client() else {
                warn!(
                    limit = MAX_WAYLAND_CLIENTS,
                    "discarding Wayland connection because the client budget is exhausted"
                );
                return;
            };
            if let Err(error) = frontend
                .display_handle
                .insert_client(client_stream, Arc::new(client_state))
            {
                // Resource exhaustion or a client disconnect during accept
                // must not turn a failed connection into a compositor panic.
                // Dropping the stream rejects this client only.
                warn!(%error, "failed to insert Wayland client");
            }
        })?;
    event_loop.handle().insert_source(
        Generic::new(display, Interest::READ, PollMode::Level),
        |_, display, state| {
            // SAFETY: calloop owns the Display source for the entire event-loop
            // registration and it is removed only when the loop is dropped.
            unsafe {
                let display = display.get_mut();
                display.dispatch_clients(state)?;
                display.flush_clients()?;
            }
            Ok(PostAction::Continue)
        },
    )?;
    Ok(socket_name)
}

#[cfg(feature = "flutter")]
fn transform_to_wire(transform: Transform) -> u32 {
    match transform {
        Transform::Normal => 0,
        Transform::_90 => 1,
        Transform::_180 => 2,
        Transform::_270 => 3,
        Transform::Flipped => 4,
        Transform::Flipped90 => 5,
        Transform::Flipped180 => 6,
        Transform::Flipped270 => 7,
    }
}

smithay::delegate_dispatch2!(RuntimeState);

#[cfg(test)]
mod tests {
    #[cfg(feature = "flutter")]
    use super::OutputWindowMembership;
    #[cfg(feature = "flutter")]
    use super::{
        CursorImageStatus, RoutedPointerTarget, ShellFullscreenTransition,
        accepted_flutter_cursor_shape, classify_window_opacity, cursor_position_for_modality,
        cursor_shape_for_modality, input_routing_changed, input_visibility_changed,
        shell_fullscreen_transition, software_cursor_shape, window_expects_sample,
    };
    use super::{
        InitialXdgPlacementPolicy, MAX_PENDING_DMABUF_IMPORTS, dmabuf_import_queue_has_capacity,
        initial_xdg_placement_policy,
    };
    use super::{RuntimeState, ViewporterState, XdgActivationState};
    use crate::window_placement_store::WindowPlacementState;
    #[cfg(feature = "flutter")]
    use crate::wire::{InputLayoutSnapshot, InputRect, WindowOpacityClass};
    #[cfg(feature = "flutter")]
    use denial_core::topology::OutputId;
    #[cfg(feature = "flutter")]
    use smithay::input::pointer::CursorIcon;
    use smithay::reexports::wayland_server::Display;
    #[cfg(feature = "flutter")]
    use smithay::utils::{Logical, Rectangle};
    #[cfg(feature = "flutter")]
    use std::collections::HashSet;

    #[cfg(feature = "flutter")]
    #[test]
    fn window_opacity_distinguishes_content_from_client_decoration_alpha() {
        let surface = Rectangle::<i32, Logical>::from_size((2572, 1438).into());
        let content = Rectangle::<i32, Logical>::new((16, 18).into(), (2540, 1396).into());
        let chromium_regions = [
            Rectangle::new((24, 10).into(), (2524, 8).into()),
            Rectangle::new((16, 18).into(), (2540, 1388).into()),
        ];

        assert_eq!(
            classify_window_opacity(surface, content, Some(&chromium_regions), 1.0),
            WindowOpacityClass::BorderAlphaOnly
        );
        assert_eq!(
            classify_window_opacity(surface, content, Some(&[content]), 1.0),
            WindowOpacityClass::FullyOpaque
        );
        assert_eq!(
            classify_window_opacity(surface, content, Some(&chromium_regions), 0.0),
            WindowOpacityClass::ContentTranslucent
        );
    }

    #[cfg(feature = "flutter")]
    #[test]
    fn alpha_reaching_the_window_interior_remains_content_translucent() {
        let surface = Rectangle::<i32, Logical>::from_size((1000, 1000).into());
        let opaque = [Rectangle::new((0, 0).into(), (1000, 940).into())];

        assert_eq!(
            classify_window_opacity(surface, surface, Some(&opaque), 1.0),
            WindowOpacityClass::ContentTranslucent
        );
        assert_eq!(
            classify_window_opacity(surface, surface, None, 1.0),
            WindowOpacityClass::ContentTranslucent
        );
    }

    #[test]
    fn advertises_wp_viewporter_version_one() {
        let display = Display::<RuntimeState>::new().expect("Wayland display should initialize");
        let display_handle = display.handle();
        let viewporter = ViewporterState::new::<RuntimeState>(&display_handle);
        let global = display_handle
            .backend_handle()
            .global_info(viewporter.global())
            .expect("wp_viewporter global should remain registered");

        assert_eq!(global.interface.name, "wp_viewporter");
        assert_eq!(global.version, 1);
        assert!(!global.disabled);
    }

    #[test]
    fn advertises_xdg_activation_version_one() {
        let display = Display::<RuntimeState>::new().expect("Wayland display should initialize");
        let display_handle = display.handle();
        let activation = XdgActivationState::new::<RuntimeState>(&display_handle);
        let global = display_handle
            .backend_handle()
            .global_info(activation.global())
            .expect("xdg_activation_v1 global should remain registered");

        assert_eq!(global.interface.name, "xdg_activation_v1");
        assert_eq!(global.version, 1);
        assert!(!global.disabled);
    }

    #[test]
    fn dmabuf_import_queue_enforces_its_exact_boundary() {
        assert!(dmabuf_import_queue_has_capacity(
            MAX_PENDING_DMABUF_IMPORTS - 1
        ));
        assert!(!dmabuf_import_queue_has_capacity(
            MAX_PENDING_DMABUF_IMPORTS
        ));
        assert!(!dmabuf_import_queue_has_capacity(usize::MAX));
    }

    #[cfg(feature = "flutter")]
    #[test]
    fn output_window_membership_moves_without_duplicates_and_removes_cleanly() {
        let first = OutputId(1);
        let second = OutputId(2);
        let mut membership = OutputWindowMembership::<u64, &'static str>::default();

        assert!(membership.update(10, "first", Some(first)));
        assert!(membership.update(20, "second", Some(first)));
        assert!(!membership.update(10, "first", Some(first)));
        assert_eq!(
            membership.windows(first).copied().collect::<Vec<_>>(),
            vec!["first", "second"]
        );

        assert!(membership.update(10, "first", Some(second)));
        assert_eq!(
            membership.windows(first).copied().collect::<Vec<_>>(),
            vec!["second"]
        );
        assert_eq!(
            membership.windows(second).copied().collect::<Vec<_>>(),
            vec!["first"]
        );

        assert_eq!(membership.remove(&10), Some("first"));
        assert_eq!(membership.remove(&10), None);
        assert_eq!(membership.windows(second).count(), 0);
        membership.clear();
        assert_eq!(membership.windows(first).count(), 0);
    }

    #[test]
    fn normal_xdg_toplevels_keep_saved_location_but_choose_their_size() {
        assert_eq!(
            initial_xdg_placement_policy(
                false,
                false,
                false,
                false,
                WindowPlacementState::default(),
                WindowPlacementState::default(),
            ),
            InitialXdgPlacementPolicy::ClientSized
        );
    }

    #[test]
    fn explicit_client_state_wins_over_saved_shell_state() {
        let saved_fullscreen = WindowPlacementState {
            maximized: false,
            fullscreen: true,
        };
        assert_eq!(
            initial_xdg_placement_policy(
                false,
                false,
                false,
                true,
                WindowPlacementState::default(),
                saved_fullscreen,
            ),
            InitialXdgPlacementPolicy::ClientSized
        );
        assert_eq!(
            initial_xdg_placement_policy(
                false,
                false,
                false,
                true,
                saved_fullscreen,
                WindowPlacementState::default(),
            ),
            InitialXdgPlacementPolicy::SkipSaved
        );
    }

    #[test]
    fn only_primary_unparented_toplevels_restore_shell_owned_state() {
        let saved_maximized = WindowPlacementState {
            maximized: true,
            fullscreen: false,
        };
        assert_eq!(
            initial_xdg_placement_policy(
                false,
                false,
                false,
                false,
                WindowPlacementState::default(),
                saved_maximized,
            ),
            InitialXdgPlacementPolicy::RestoreShellState
        );
        for (has_parent, has_sibling, configured) in [
            (true, false, false),
            (false, true, false),
            (false, false, true),
        ] {
            assert_eq!(
                initial_xdg_placement_policy(
                    has_parent,
                    has_sibling,
                    configured,
                    false,
                    WindowPlacementState::default(),
                    saved_maximized,
                ),
                InitialXdgPlacementPolicy::SkipSaved
            );
        }
    }

    #[cfg(feature = "flutter")]
    #[test]
    fn wayland_cursor_names_and_visibility_map_to_shell_shapes() {
        assert_eq!(
            software_cursor_shape(&CursorImageStatus::Named(CursorIcon::Text)),
            "text"
        );
        assert_eq!(
            software_cursor_shape(&CursorImageStatus::Named(CursorIcon::NwseResize)),
            "nwse-resize"
        );
        assert_eq!(software_cursor_shape(&CursorImageStatus::Hidden), "none");
    }

    #[cfg(feature = "flutter")]
    #[test]
    fn only_the_flutter_pointer_owner_can_request_a_shell_cursor() {
        assert_eq!(
            accepted_flutter_cursor_shape(RoutedPointerTarget::Flutter, "text"),
            Some("text")
        );
        assert_eq!(
            accepted_flutter_cursor_shape(RoutedPointerTarget::Client(42), "text"),
            None
        );
    }

    #[cfg(feature = "flutter")]
    #[test]
    fn touch_modality_suppresses_replayed_cursor_shape_and_position() {
        assert_eq!(cursor_shape_for_modality(false, "text"), "none");
        assert_eq!(cursor_position_for_modality(false, (32.0, 64.0)), None);
        assert_eq!(cursor_shape_for_modality(true, "text"), "text");
        assert_eq!(
            cursor_position_for_modality(true, (32.0, 64.0)),
            Some((32.0, 64.0))
        );
    }

    #[cfg(feature = "flutter")]
    #[test]
    fn input_route_survives_epoch_and_visibility_only_layout_updates() {
        let current = InputLayoutSnapshot::default();
        let mut next = current.clone();
        next.epoch = 9;
        next.visible_surface_ids.push(42);
        assert!(!input_routing_changed(Some(&current), &next));
        assert!(input_visibility_changed(Some(&current), &next));

        next.shell_regions.push(InputRect {
            x: 0.0,
            y: 0.0,
            width: 10.0,
            height: 10.0,
        });
        assert!(input_routing_changed(Some(&current), &next));
        assert!(input_routing_changed(None, &next));
    }

    #[cfg(feature = "flutter")]
    #[test]
    fn only_visible_windows_wait_for_flutter_texture_samples() {
        let visible = HashSet::from([42]);

        assert!(window_expects_sample(false, &visible, 7));
        assert!(window_expects_sample(true, &visible, 42));
        assert!(!window_expects_sample(true, &visible, 7));
    }

    #[cfg(feature = "flutter")]
    #[test]
    fn client_fullscreen_shortcut_exits_across_input_layout_races() {
        use ShellFullscreenTransition::{EnterShell, ExitClient, ExitShell};

        assert_eq!(shell_fullscreen_transition(true, false, true), ExitClient);
        assert_eq!(shell_fullscreen_transition(true, false, false), ExitClient);
        assert_eq!(shell_fullscreen_transition(true, true, true), ExitClient);
        assert_eq!(shell_fullscreen_transition(false, true, true), ExitShell);
        assert_eq!(shell_fullscreen_transition(false, false, false), EnterShell);
    }
}
