use std::collections::{BTreeMap, HashMap, HashSet};
use std::error::Error;
use std::ffi::{OsStr, OsString};
#[cfg(feature = "flutter")]
use std::hash::Hash;
use std::sync::Arc;
use std::time::{Duration, Instant};

use denial_core::topology::{AtlasPlan, OutputId, OutputTransform, TopologySnapshot};
use super::output_topology::ScrollingLayoutAxis;
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
    LayerSurface as DesktopLayerSurface, PopupKeyboardGrab, PopupKind, PopupManager,
    PopupPointerGrab, PopupUngrabStrategy, Space, Window, WindowSurfaceType,
    find_popup_root_surface, get_popup_toplevel_coords, layer_map_for_output,
};
use smithay::input::dnd::{DnDGrab, DndGrabHandler, GrabType, Source};
#[cfg(feature = "flutter")]
use smithay::input::keyboard::xkb;
use smithay::input::keyboard::XkbConfig;
use smithay::input::pointer::{
    CursorImageStatus, CursorImageSurfaceData, Focus, PointerHandle,
};
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
    CompositorState, SurfaceAttributes, add_blocker, add_post_commit_hook, add_pre_commit_hook,
    get_parent, is_sync_subsurface, with_states,
};
#[cfg(feature = "flutter")]
use smithay::wayland::compositor::Cacheable;
use smithay::wayland::cursor_shape::CursorShapeManagerState;
#[cfg(feature = "flutter")]
use smithay::wayland::compositor::{
    TraversalAction, with_surface_tree_downward, with_surface_tree_upward,
};
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
use smithay::wayland::selection::ext_data_control::{
    DataControlHandler as ExtDataControlHandler, DataControlState as ExtDataControlState,
};
use smithay::wayland::selection::wlr_data_control::{
    DataControlHandler as WlrDataControlHandler, DataControlState as WlrDataControlState,
};
use smithay::wayland::shell::xdg::{
    PopupSurface, PositionerState, SurfaceCachedState, ToplevelSurface, XdgShellHandler,
    XdgShellState, XdgToplevelSurfaceData,
};
use smithay::wayland::shell::xdg::decoration::{XdgDecorationHandler, XdgDecorationState};
use smithay::wayland::shell::wlr_layer::{
    KeyboardInteractivity, LAYER_SURFACE_ROLE, Layer as WlrLayer,
    LayerSurface as WlrLayerSurface, LayerSurfaceCachedState, LayerSurfaceData,
    WlrLayerShellHandler, WlrLayerShellState,
};
use smithay::wayland::shm::{ShmHandler, ShmState};
use smithay::wayland::socket::ListeningSocketSource;
use smithay::wayland::tablet_manager::{TabletManagerState, TabletSeatHandler};
use smithay::wayland::viewporter::ViewporterState;
use smithay::wayland::alpha_modifier::{AlphaModifierState, AlphaModifierSurfaceCachedState};
use smithay::wayland::xdg_activation::XdgActivationState;
use smithay::wayland::xdg_foreign::{XdgForeignHandler, XdgForeignState};
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
    MoveSurfaceGrab, ResizeEdges, ResizeSurfaceGrab, checked_pointer_grab, constrain_dimension,
};
use super::window_layout::{WindowLayout, create_window_layout};
use super::window_placement_store::{
    RestoredWindowPlacement, WindowIdentity, WindowPlacementState, WindowPlacementStore,
    default_state_path,
};
#[cfg(feature = "flutter")]
use super::wire::{
    CursorStateDescription, CursorStateKind, InputLayoutSnapshot, SurfaceLayerDescription,
    SurfaceRoleDescription, WindowContentKind, WindowDescription, WindowGeometry,
    WindowOpacityClass, WindowPlacement, WindowPlacementChange, WindowPlacementPhase,
};

#[path = "wayland_frontend/clipboard.rs"]
mod clipboard_io;
#[path = "wayland_frontend/cursor_state.rs"]
mod cursor_state;
#[path = "wayland_frontend/focus.rs"]
mod focus;
#[cfg(feature = "flutter")]
#[path = "wayland_frontend/frame_timeline.rs"]
mod frame_timeline;
#[path = "wayland_frontend/gamma_control.rs"]
mod gamma_control;
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
#[path = "wayland_frontend/insets.rs"]
mod insets;
#[path = "wayland_frontend/managed_window.rs"]
mod managed_window;
#[cfg(feature = "flutter")]
pub(super) use focus::{restore_shell_keyboard_focus, suspend_keyboard_focus_for_shell};
#[cfg(feature = "flutter")]
pub(super) use input::{dispatch_shell_keyboard, reconcile_flutter_pointer_route};
#[path = "wayland_frontend/input_source.rs"]
mod input_source;
#[path = "wayland_frontend/layer_shell.rs"]
mod layer_shell;
#[path = "wayland_frontend/output_power.rs"]
mod output_power;
#[path = "wayland_frontend/presentation.rs"]
mod presentation;
#[path = "wayland_frontend/scene_input.rs"]
mod scene_input;
#[path = "wayland_frontend/screencopy.rs"]
mod screencopy;
#[path = "wayland_frontend/startup.rs"]
mod startup;
#[path = "wayland_frontend/surface_pipeline.rs"]
mod surface_pipeline;
#[cfg(feature = "flutter")]
pub(crate) use screencopy::{
    OutputCompositeSource, compose_output_targets_to_atlas, copy_atlas_region_to_memory,
};
#[cfg(feature = "flutter")]
#[path = "wayland_frontend/surface_snapshot.rs"]
mod surface_snapshot;
#[path = "wayland_frontend/text_input.rs"]
mod text_input;
#[path = "wayland_frontend/topology.rs"]
mod topology;
#[cfg(feature = "flutter")]
#[path = "wayland_frontend/touch_gestures.rs"]
mod touch_gestures;
#[path = "wayland_frontend/window_layout.rs"]
mod window_layout_adapter;
#[cfg(feature = "flutter")]
pub(crate) use window_layout_adapter::LayoutDropTarget;
#[path = "wayland_frontend/window_management.rs"]
mod window_management;
#[cfg(feature = "flutter")]
#[path = "wayland_frontend/window_outputs.rs"]
mod window_outputs;
#[cfg(feature = "flutter")]
#[path = "wayland_frontend/window_presentation.rs"]
mod window_presentation;
#[path = "wayland_frontend/window_registry.rs"]
mod window_registry;
#[path = "wayland_frontend/window_state.rs"]
mod window_state;
#[cfg(feature = "flutter")]
#[path = "wayland_frontend/workspace.rs"]
mod workspace;
#[cfg_attr(
    not(feature = "xwayland"),
    path = "wayland_frontend/xwayland_disabled.rs"
)]
#[cfg_attr(feature = "xwayland", path = "wayland_frontend/xwayland.rs")]
mod xwayland;

pub(super) use clipboard_io::DeferredClipboardCapture;
#[cfg(feature = "flutter")]
pub(super) use clipboard_io::{apply_clipboard_actions, cancel_clipboard_captures};
use focus::KeyboardFocusTarget;
use handlers::{MAX_WAYLAND_CLIENTS, WaylandClientBudget};
#[cfg(feature = "flutter")]
use idle_inhibit::IdleInhibitors;
#[cfg(feature = "flutter")]
use input::{ClientInputRoute, RoutedPointerTarget};
pub(super) use input::{init_libinput, reset_all_input_devices};
#[cfg(feature = "flutter")]
pub(super) use input::{
    install_keyboard_settings, install_mouse_settings, install_touchpad_settings,
};
#[cfg(feature = "flutter")]
use input_method::EditorEndpoint;
use input_method::InputMethodManager;
use managed_window::toplevel_has_state;
use output_power::OutputPowerManager;
#[cfg(feature = "flutter")]
use surface_snapshot::{rgba_payload_len, shm_cache_budget_for_atlas, snapshot_shm_buffer};
use text_input::{SeatFocusKind, TextInputManager};
pub(super) use topology::saturating_point_add;
use topology::{
    centered_transient_geometry, choose_popup_output, clamp_window_geometry, configure_output,
    output_logical_bounds, saturating_point_sub,
};
use window_management::SHELL_FRAME_BORDER;
#[cfg(feature = "flutter")]
pub(super) use window_management::{
    apply_window_commands, finalize_topology_window_reconciliation,
    queue_local_flutter_window_placement, queue_transient_window_placement, queue_window_placement,
};
#[cfg(feature = "flutter")]
use window_management::{
    maximized_shell_content_geometry, shell_content_geometry, shell_draws_server_frame,
};
use window_registry::{WindowId, WindowRegistry};

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
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum CursorPublication {
    Hidden,
    Named(&'static str),
    Surface(WlSurface),
}

#[cfg(feature = "flutter")]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ClientCursorIntent {
    Hidden,
    Named(&'static str),
    Surface,
}

#[cfg(feature = "flutter")]
fn resolved_client_cursor_intent(
    intent: ClientCursorIntent,
    allow_surface: bool,
    shell_cursor_override: bool,
) -> ClientCursorIntent {
    if shell_cursor_override {
        return ClientCursorIntent::Named("default");
    }
    match intent {
        ClientCursorIntent::Surface if !allow_surface => ClientCursorIntent::Named("default"),
        intent => intent,
    }
}

#[cfg(feature = "flutter")]
fn cursor_hotspot_after_buffer_delta(
    mut hotspot: Point<i32, Logical>,
    buffer_delta: Point<i32, Logical>,
) -> Point<i32, Logical> {
    hotspot -= buffer_delta;
    hotspot
}

#[cfg(feature = "flutter")]
fn cursor_frame_callback_matches(cursor_output: Option<OutputId>, tick_output: OutputId) -> bool {
    cursor_output.is_none_or(|output| output == tick_output)
}

#[cfg(feature = "flutter")]
fn accepted_flutter_cursor_shape(
    target: RoutedPointerTarget,
    shape: &'static str,
) -> Option<&'static str> {
    matches!(target, RoutedPointerTarget::Flutter).then_some(shape)
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
    pub xdg_foreign_state: XdgForeignState,
    pub xdg_activation_state: XdgActivationState,
    pub(crate) xwayland: xwayland::XWaylandState,
    pub _relative_pointer_manager_state: RelativePointerManagerState,
    pub _pointer_constraints_state: PointerConstraintsState,
    _viewporter_state: ViewporterState,
    _alpha_modifier_state: AlphaModifierState,
    _fractional_scale_manager_state: FractionalScaleManagerState,
    _xdg_decoration_state: XdgDecorationState,
    _cursor_shape_state: CursorShapeManagerState,
    _tablet_manager_state: TabletManagerState,
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
    scene_layer_surface_roots: HashSet<u64>,
    #[cfg(feature = "flutter")]
    scene_layer_surface_roots_scratch: HashSet<u64>,
    window_membership_scratch: Vec<Window>,
    #[cfg(feature = "flutter")]
    output_window_membership: OutputWindowMembership<ObjectId, Window>,
    #[cfg(feature = "flutter")]
    pending_frame_callback_windows: HashSet<ObjectId>,
    #[cfg(feature = "flutter")]
    pending_layer_frame_callback_roots: HashSet<ObjectId>,
    #[cfg(feature = "flutter")]
    pending_input_method_frame_callbacks: HashSet<ObjectId>,
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
    window_registry: WindowRegistry,
    window_layout: Box<dyn WindowLayout<ObjectId>>,
    #[cfg(feature = "flutter")]
    input_layout: Option<InputLayoutSnapshot>,
    #[cfg(feature = "flutter")]
    shell_keyboard_focus: Option<KeyboardFocusTarget>,
    #[cfg(feature = "flutter")]
    input_root_ids: HashMap<ObjectId, u64>,
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
    #[cfg(feature = "flutter")]
    compositor_pointer_grab_active: bool,
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
    pending_cursor_state: Option<CursorPublication>,
    #[cfg(feature = "flutter")]
    published_cursor_state: Option<CursorPublication>,
    #[cfg(feature = "flutter")]
    pending_cursor_metadata: bool,
    #[cfg(feature = "flutter")]
    pending_cursor_buffer_surface_ids: HashSet<u64>,
    #[cfg(feature = "flutter")]
    cursor_state_layers_scratch: Vec<SurfaceLayerDescription>,
    #[cfg(feature = "flutter")]
    cursor_state_textures_scratch: Vec<ExternalTextureFrame>,
    #[cfg(feature = "flutter")]
    pending_cursor_frame_callback_roots: HashSet<ObjectId>,
    #[cfg(feature = "flutter")]
    cursor_output: Option<OutputId>,
    #[cfg(feature = "flutter")]
    cursor_output_scale: Option<f64>,
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
    touch_gestures: touch_gestures::TouchGestureState,
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
    workspaces_enabled: bool,
    #[cfg(feature = "flutter")]
    workspace_count: u8,
    #[cfg(feature = "flutter")]
    active_workspaces: HashMap<OutputId, u8>,
    #[cfg(feature = "flutter")]
    workspace_focus_history: HashMap<(OutputId, u8), u64>,
    window_placements: WindowPlacementStore,
    pub _output_manager_state: OutputManagerState,
    pub seat_state: SeatState<RuntimeState>,
    pub data_device_state: DataDeviceState,
    ext_data_control_state: ExtDataControlState,
    wlr_data_control_state: WlrDataControlState,
    pub popups: PopupManager,
    pub seat: Seat<RuntimeState>,
    session: LibSeatSession,
    layer_shell_state: WlrLayerShellState,
    libinput: smithay::reexports::input::Libinput,
    pub(super) settings: SettingsManager,
    pub(super) shortcuts: ShortcutManager,
    pub(super) keyboard_layout_names: Vec<String>,
    pub(super) active_keyboard_layout: usize,
    pub(super) keyboard_configuration_changed: bool,
    presentation: presentation::PresentationTracker,
    #[cfg(feature = "flutter")]
    frame_timeline: frame_timeline::FrameTimelineManager,
    #[cfg(feature = "flutter")]
    mobile_shell: bool,
    #[cfg(feature = "flutter")]
    idle_inhibitors: IdleInhibitors,
    #[cfg(feature = "flutter")]
    idle_inhibition_dirty: bool,
    #[cfg(feature = "flutter")]
    idle_inhibition_cached: bool,
    output_power: OutputPowerManager,
    gamma_control: gamma_control::GammaControlManager,
    screencopy: screencopy::ScreencopyManager,
    text_input: TextInputManager,
    input_method: InputMethodManager,
    outputs: Vec<WaylandOutput>,
    scrolling_layout_axes: BTreeMap<String, ScrollingLayoutAxis>,
    work_area: crate::options::WorkAreaOptions,
    ticker_output: Option<OutputId>,
    pub atlas_output: Output,
    damage_tracker: OutputDamageTracker,
    next_window_offset: i32,
    desktop_bounds: smithay::utils::Rectangle<i32, Logical>,
    touch_bounds: smithay::utils::Rectangle<i32, Logical>,
    touch_transform: OutputTransform,
    tablet_output_mappings: HashMap<String, String>,
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

struct WaylandOutput {
    id: OutputId,
    connector: String,
    transform: OutputTransform,
    output: Output,
    global: GlobalId,
    logical_geometry: Rectangle<i32, Logical>,
    capture_source: Rectangle<i32, Physical>,
    capture_size: Size<i32, Physical>,
    powered: bool,
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

#[derive(Clone, Copy)]
struct PendingAuxiliaryToplevelPlacement {
    pointer_location: Point<i32, Logical>,
    output_id: OutputId,
}

const fn should_place_auxiliary_toplevel_at_pointer(
    has_parent: bool,
    has_same_app_sibling: bool,
    layout_managed: bool,
) -> bool {
    !has_parent && has_same_app_sibling && !layout_managed
}

#[cfg(test)]
mod initial_toplevel_placement_tests {
    use super::*;

    #[test]
    fn only_unparented_floating_siblings_follow_the_pointer() {
        assert!(should_place_auxiliary_toplevel_at_pointer(
            false, true, false
        ));
        assert!(!should_place_auxiliary_toplevel_at_pointer(
            true, true, false
        ));
        assert!(!should_place_auxiliary_toplevel_at_pointer(
            false, false, false
        ));
        assert!(!should_place_auxiliary_toplevel_at_pointer(
            false, true, true
        ));
    }
}

/// The single compositor-side geometry contract for a managed window.
///
/// Protocol callbacks may acknowledge or challenge this target, but neither
/// XDG nor Xwayland gets a second placement record. Pending targets disappear
/// after acknowledgement; authoritative targets remain until the policy which
/// owns them (layout, client state, or shell state) explicitly replaces them.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct WindowGeometryIntent {
    target: Rectangle<i32, Logical>,
    authority: WindowGeometryAuthority,
    reassertion: WindowGeometryReassertion,
}

impl WindowGeometryIntent {
    fn for_contract(
        target: Rectangle<i32, Logical>,
        authority: WindowGeometryAuthority,
        previous: Option<Self>,
    ) -> Self {
        let reassertion = previous
            .filter(|previous| previous.target == target && previous.authority == authority)
            .map_or(WindowGeometryReassertion::Available, |previous| {
                previous.reassertion
            });
        Self {
            target,
            authority,
            reassertion,
        }
    }

    fn retained_after_commit(self, committed: Size<i32, Logical>) -> bool {
        committed != self.target.size || self.authority.persistent()
    }

    fn claim_reassertion(&mut self) -> WindowGeometryReassertionAction {
        match self.reassertion {
            WindowGeometryReassertion::Available => {
                self.reassertion = WindowGeometryReassertion::Sent;
                WindowGeometryReassertionAction::Send
            }
            WindowGeometryReassertion::Sent => {
                self.reassertion = WindowGeometryReassertion::Suppressed;
                WindowGeometryReassertionAction::ReportSuppressed
            }
            WindowGeometryReassertion::Suppressed => WindowGeometryReassertionAction::Suppress,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
enum WindowGeometryReassertion {
    #[default]
    Available,
    Sent,
    Suppressed,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WindowGeometryReassertionAction {
    Send,
    ReportSuppressed,
    Suppress,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WindowGeometryAuthority {
    Pending,
    Layout,
    ClientState,
    Shell,
    Exact,
}

impl WindowGeometryAuthority {
    const fn persistent(self) -> bool {
        !matches!(self, Self::Pending)
    }

    const fn exact(self) -> bool {
        matches!(self, Self::Shell | Self::Exact)
    }
}

fn committed_size_requires_reassertion(
    target: Size<i32, Logical>,
    preview: Option<Size<i32, Logical>>,
    committed: Size<i32, Logical>,
) -> bool {
    preview.is_none() && committed != target
}

#[cfg(test)]
mod window_geometry_intent_tests {
    use super::*;

    fn intent(authority: WindowGeometryAuthority) -> WindowGeometryIntent {
        WindowGeometryIntent {
            target: Rectangle::new((10, 20).into(), (800, 600).into()),
            authority,
            reassertion: WindowGeometryReassertion::Available,
        }
    }

    #[test]
    fn matching_commit_releases_only_one_shot_geometry() {
        let committed = Size::from((800, 600));
        assert!(!intent(WindowGeometryAuthority::Pending).retained_after_commit(committed));
        assert!(intent(WindowGeometryAuthority::Layout).retained_after_commit(committed));
        assert!(intent(WindowGeometryAuthority::ClientState).retained_after_commit(committed));
        assert!(intent(WindowGeometryAuthority::Shell).retained_after_commit(committed));
        assert!(intent(WindowGeometryAuthority::Exact).retained_after_commit(committed));
    }

    #[test]
    fn mismatched_commit_never_replaces_the_current_target() {
        let committed = Size::from((1920, 1080));
        for authority in [
            WindowGeometryAuthority::Pending,
            WindowGeometryAuthority::Layout,
            WindowGeometryAuthority::ClientState,
            WindowGeometryAuthority::Shell,
            WindowGeometryAuthority::Exact,
        ] {
            assert!(intent(authority).retained_after_commit(committed));
        }
    }

    #[test]
    fn layout_preview_suppresses_authoritative_size_reassertion() {
        let target = Size::from((800, 600));
        let preview = Size::from((400, 600));

        assert!(!committed_size_requires_reassertion(
            target,
            Some(preview),
            preview,
        ));
        assert!(!committed_size_requires_reassertion(
            target,
            Some(preview),
            Size::from((640, 600)),
        ));
        assert!(committed_size_requires_reassertion(target, None, preview,));
    }

    #[test]
    fn one_geometry_contract_can_only_reassert_once() {
        let mut intent = intent(WindowGeometryAuthority::Layout);
        assert_eq!(
            intent.claim_reassertion(),
            WindowGeometryReassertionAction::Send
        );
        assert_eq!(
            intent.claim_reassertion(),
            WindowGeometryReassertionAction::ReportSuppressed
        );
        assert_eq!(
            intent.claim_reassertion(),
            WindowGeometryReassertionAction::Suppress
        );
    }

    #[test]
    fn unchanged_geometry_contract_preserves_its_reassertion_guard() {
        let target = Rectangle::new((10, 20).into(), (800, 600).into());
        let mut previous =
            WindowGeometryIntent::for_contract(target, WindowGeometryAuthority::Layout, None);
        assert_eq!(
            previous.claim_reassertion(),
            WindowGeometryReassertionAction::Send
        );

        let unchanged = WindowGeometryIntent::for_contract(
            target,
            WindowGeometryAuthority::Layout,
            Some(previous),
        );
        assert_eq!(unchanged.reassertion, WindowGeometryReassertion::Sent);

        let changed = WindowGeometryIntent::for_contract(
            Rectangle::new((10, 20).into(), (900, 600).into()),
            WindowGeometryAuthority::Layout,
            Some(previous),
        );
        assert_eq!(changed.reassertion, WindowGeometryReassertion::Available);
    }
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
            let Some(mut client_state) = client_budget.try_reserve_client() else {
                warn!(
                    limit = MAX_WAYLAND_CLIENTS,
                    "discarding Wayland connection because the client budget is exhausted"
                );
                return;
            };
            if let Some(credentials) = socket_peer_credentials(&client_stream) {
                client_state.peer_pid = Some(credentials.pid);
                client_state.peer_uid = Some(credentials.uid);
            }
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

// Cache peer identity before inserting the socket. Global visibility callbacks
// run under the Wayland backend lock and must never re-enter it for credentials.
fn socket_peer_credentials(stream: &std::os::unix::net::UnixStream) -> Option<libc::ucred> {
    use std::os::fd::AsRawFd;
    let mut credentials = std::mem::MaybeUninit::<libc::ucred>::uninit();
    let mut size = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: getsockopt writes at most size bytes to a correctly sized ucred.
    let status = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            credentials.as_mut_ptr().cast(),
            &mut size,
        )
    };
    if status != 0 || size as usize != std::mem::size_of::<libc::ucred>() {
        return None;
    }
    // SAFETY: the successful call initialized the complete structure.
    Some(unsafe { credentials.assume_init() })
}

#[cfg(feature = "flutter")]
pub(super) fn is_root_client(client: &Client) -> bool {
    client
        .get_data::<handlers::DenialClientState>()
        .is_some_and(|state| state.peer_uid == Some(0))
}

#[cfg(all(test, feature = "flutter"))]
pub(super) fn fingerprint_test_client(uid: Option<u32>) -> Arc<dyn ClientData> {
    let mut data = handlers::DenialClientState::default();
    data.peer_uid = uid;
    Arc::new(data)
}

#[cfg(feature = "flutter")]
#[path = "wayland_frontend/wake_gesture.rs"]
mod wake_gesture;
