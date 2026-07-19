use std::collections::{HashMap, HashSet};
use std::error::Error;
use std::ffi::{OsStr, OsString};
use std::process::Stdio;
use std::sync::Arc;
use std::time::Instant;

use denial_core::topology::{AtlasPlan, OutputId, TopologySnapshot};
#[cfg(feature = "flutter")]
use smithay::backend::allocator::Buffer as AllocatorBuffer;
use smithay::backend::allocator::dmabuf::Dmabuf;
use smithay::backend::drm::DrmNode;
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
use smithay::input::pointer::{CursorImageStatus, Focus, PointerHandle};
use smithay::input::{Seat, SeatHandler, SeatState};
use smithay::output::{Mode, Output, PhysicalProperties, Scale, Subpixel};
use smithay::reexports::calloop::{
    EventLoop, Interest, Mode as PollMode, PostAction, generic::Generic,
};
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
    BufferAssignment, CompositorClientState, CompositorHandler, CompositorState, SurfaceAttributes,
    get_parent, is_sync_subsurface, with_states,
};
use smithay::wayland::cursor_shape::CursorShapeManagerState;
#[cfg(feature = "flutter")]
use smithay::wayland::compositor::{TraversalAction, with_surface_tree_upward};
#[cfg(feature = "flutter")]
use smithay::wayland::dmabuf::get_dmabuf;
use smithay::wayland::dmabuf::{
    DmabufFeedbackBuilder, DmabufGlobal, DmabufHandler, DmabufState, ImportNotifier,
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
    PopupSurface, PositionerState, ToplevelSurface, XdgShellHandler, XdgShellState,
    XdgToplevelSurfaceData,
};
use smithay::wayland::shell::xdg::decoration::{XdgDecorationHandler, XdgDecorationState};
use smithay::wayland::shm::{ShmHandler, ShmState};
use smithay::wayland::socket::ListeningSocketSource;
use smithay::wayland::tablet_manager::TabletSeatHandler;
use smithay::wayland::xwayland_shell::XWaylandShellState;
use smithay::wayland::xwayland_keyboard_grab::XWaylandKeyboardGrabState;
use smithay::xwayland::{X11Wm, XWayland, XWaylandClientData, XWaylandEvent};
#[cfg(feature = "flutter")]
use smithay::xwayland::xwm::WmWindowType;
use tracing::{error, info, warn};

#[cfg(feature = "flutter")]
use super::PendingWindowEvent;
use super::RuntimeState;
#[cfg(feature = "flutter")]
use super::flutter_runtime::{ExternalTextureFrame, ShmSnapshotPool, ShmTextureFrame};
use super::window_grab::{
    MoveSurfaceGrab, ResizeEdges, ResizeSurfaceGrab, X11ResizeSurfaceGrab, checked_pointer_grab,
};
#[cfg(feature = "flutter")]
use super::wire::{
    InputLayoutSnapshot, SurfaceLayerDescription, SurfaceRoleDescription, WindowAction,
    WindowDescription, WindowGeometry, WindowPlacement, WindowPlacementChange,
    WindowPlacementPhase,
};

#[path = "wayland_frontend/focus.rs"]
mod focus;
#[path = "wayland_frontend/handlers.rs"]
mod handlers;
#[path = "wayland_frontend/input.rs"]
mod input;
#[path = "wayland_frontend/input_source.rs"]
mod input_source;
#[path = "wayland_frontend/presentation.rs"]
mod presentation;
#[cfg(feature = "flutter")]
#[path = "wayland_frontend/surface_snapshot.rs"]
mod surface_snapshot;
#[path = "wayland_frontend/topology.rs"]
mod topology;
#[path = "wayland_frontend/window_management.rs"]
mod window_management;
#[path = "wayland_frontend/xwayland.rs"]
mod xwayland;

use focus::KeyboardFocusTarget;
use handlers::{MAX_WAYLAND_CLIENTS, WaylandClientBudget};
#[cfg(feature = "flutter")]
use input::{ClientInputRoute, RoutedPointerTarget};
pub(super) use input::{init_libinput, reset_all_input_devices};
#[cfg(feature = "flutter")]
use surface_snapshot::{rgba_payload_len, shm_cache_budget_for_atlas, snapshot_shm_buffer};
pub(super) use topology::saturating_point_add;
use topology::{
    choose_popup_output, configure_output, output_logical_bounds, saturating_point_sub,
};
#[cfg(feature = "flutter")]
use window_management::toplevel_has_state;
#[cfg(feature = "flutter")]
pub(super) use window_management::{apply_window_commands, queue_window_placement};

const MAX_PENDING_DMABUF_IMPORTS: usize = 128;

fn dmabuf_import_queue_has_capacity(pending: usize) -> bool {
    pending < MAX_PENDING_DMABUF_IMPORTS
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

pub(super) struct WaylandFrontend {
    pub start_time: Instant,
    socket_name: OsString,
    pub display_handle: DisplayHandle,
    pub space: Space<Window>,
    pub compositor_state: CompositorState,
    pub xdg_shell_state: XdgShellState,
    pub xwayland_shell_state: XWaylandShellState,
    pub _xwayland_keyboard_grab_state: XWaylandKeyboardGrabState,
    pub _relative_pointer_manager_state: RelativePointerManagerState,
    pub _pointer_constraints_state: PointerConstraintsState,
    pub xwm: Option<X11Wm>,
    xdisplay: u32,
    _xdg_decoration_state: XdgDecorationState,
    _cursor_shape_state: CursorShapeManagerState,
    pub shm_state: ShmState,
    pub dmabuf_state: DmabufState,
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
    pending_surface_commits: HashSet<ObjectId>,
    #[cfg(feature = "flutter")]
    committed_surfaces_scratch: Vec<WlSurface>,
    #[cfg(feature = "flutter")]
    scene_windows_scratch: Vec<WindowDescription>,
    #[cfg(feature = "flutter")]
    scene_textures_scratch: Vec<ExternalTextureFrame>,
    #[cfg(feature = "flutter")]
    scene_popups_scratch: Vec<(PopupKind, Point<i32, Logical>)>,
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
    restore_window_geometries: HashMap<ObjectId, Rectangle<i32, Logical>>,
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
    client_pointer_buttons: HashSet<u32>,
    #[cfg(feature = "flutter")]
    client_pointer_presses: Vec<input::ClientPointerPress>,
    wayland_pointer_buttons: HashSet<u32>,
    #[cfg(feature = "flutter")]
    routed_pointer_target: RoutedPointerTarget,
    /// Last-writer-wins handoff from a Wayland client's cursor request to the
    /// Flutter-owned software cursor.  This is deliberately a single slot:
    /// cursor changes can arrive on every client motion and only the newest
    /// shape matters by the time Dart is dispatched.
    #[cfg(feature = "flutter")]
    pending_cursor_shape: Option<&'static str>,
    #[cfg(feature = "flutter")]
    published_client_cursor_shape: Option<&'static str>,
    #[cfg(feature = "flutter")]
    flutter_touch_slots: HashSet<i32>,
    #[cfg(feature = "flutter")]
    client_touch_routes: HashMap<i32, ClientInputRoute>,
    #[cfg(feature = "flutter")]
    flutter_keyboard_keys: HashSet<u32>,
    retired_keyboard_keys: HashSet<u32>,
    #[cfg(feature = "flutter")]
    minimized_windows: HashSet<ObjectId>,
    pub _output_manager_state: OutputManagerState,
    pub seat_state: SeatState<RuntimeState>,
    pub data_device_state: DataDeviceState,
    pub popups: PopupManager,
    pub seat: Seat<RuntimeState>,
    presentation: presentation::PresentationTracker,
    outputs: Vec<WaylandOutput>,
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

struct WaylandOutput {
    id: OutputId,
    connector: String,
    output: Output,
    global: GlobalId,
    logical_geometry: Rectangle<i32, Logical>,
    #[cfg(feature = "flutter")]
    presentation_batch: presentation::OutputPresentationBatch,
    #[cfg(feature = "flutter")]
    submitted_this_batch: bool,
}

#[cfg(feature = "flutter")]
#[derive(Clone, Copy)]
struct SurfaceTreeContext {
    location: Point<i32, Logical>,
    parent_surface_id: u64,
}

#[cfg(feature = "flutter")]
fn input_routing_changed(
    current: Option<&InputLayoutSnapshot>,
    next: &InputLayoutSnapshot,
) -> bool {
    current.is_none_or(|current| {
        current.flags != next.flags
            || current.shell_regions != next.shell_regions
            || current.windows != next.windows
    })
}

impl WaylandFrontend {
    pub fn new(
        event_loop: &mut EventLoop<'static, RuntimeState>,
        snapshot: &TopologySnapshot,
        session: LibSeatSession,
        seat_name: &str,
    ) -> Result<Self, Box<dyn Error>> {
        let display = Display::<RuntimeState>::new()?;
        let display_handle = display.handle();
        let compositor_state = CompositorState::new::<RuntimeState>(&display_handle);
        let xdg_shell_state = XdgShellState::new::<RuntimeState>(&display_handle);
        let xwayland_shell_state = XWaylandShellState::new::<RuntimeState>(&display_handle);
        let xwayland_keyboard_grab_state =
            XWaylandKeyboardGrabState::new::<RuntimeState>(&display_handle);
        let relative_pointer_manager_state =
            RelativePointerManagerState::new::<RuntimeState>(&display_handle);
        let pointer_constraints_state =
            PointerConstraintsState::new::<RuntimeState>(&display_handle);
        let xdg_decoration_state = XdgDecorationState::new::<RuntimeState>(&display_handle);
        let cursor_shape_state = CursorShapeManagerState::new::<RuntimeState>(&display_handle);
        let presentation = presentation::PresentationTracker::new(&display_handle);
        let shm_state = ShmState::new::<RuntimeState>(&display_handle, vec![]);
        let dmabuf_state = DmabufState::new();
        let output_manager_state =
            OutputManagerState::new_with_xdg_output::<RuntimeState>(&display_handle);
        let data_device_state = DataDeviceState::new::<RuntimeState>(&display_handle);
        let mut seat_state = SeatState::new();
        let mut seat = seat_state.new_wl_seat(&display_handle, "seat0");
        // Match Denial's established desktop defaults. A 200 ms delay made
        // normal key holds cross the client-side repeat threshold and showed
        // up as doubled/tripled letters during ordinary typing.
        seat.add_keyboard(Default::default(), 600, 25)?;
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

        let mut outputs = Vec::with_capacity(snapshot.outputs.len());
        for spec in &snapshot.outputs {
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
                #[cfg(feature = "flutter")]
                presentation_batch: presentation::OutputPresentationBatch::new(),
                #[cfg(feature = "flutter")]
                submitted_this_batch: false,
            });
        }

        let atlas = AtlasPlan::for_snapshot(snapshot).ok_or("Wayland topology has no atlas")?;
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
        let (xwayland, xwayland_client) = XWayland::spawn(
            &display_handle,
            None,
            std::iter::empty::<(String, String)>(),
            std::iter::empty::<String>(),
            true,
            Stdio::null(),
            Stdio::null(),
            |_| {},
        )?;
        let xdisplay = xwayland.display_number();
        let xwm_loop_handle = event_loop.handle();
        let xwm_display_handle = display_handle.clone();
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
                    xwayland_client.clone(),
                ) {
                    Ok(xwm) => {
                        let Some(frontend) = state.wayland.as_mut() else {
                            error!(
                                display_number,
                                "Xwayland became ready without Wayland frontend state"
                            );
                            return;
                        };
                        frontend.xwm = Some(xwm);
                        info!(
                            display = %format_args!(":{display_number}"),
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
            display_handle,
            space,
            compositor_state,
            xdg_shell_state,
            xwayland_shell_state,
            _xwayland_keyboard_grab_state: xwayland_keyboard_grab_state,
            _relative_pointer_manager_state: relative_pointer_manager_state,
            _pointer_constraints_state: pointer_constraints_state,
            xwm: None,
            xdisplay,
            _xdg_decoration_state: xdg_decoration_state,
            _cursor_shape_state: cursor_shape_state,
            shm_state,
            dmabuf_state,
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
            pending_surface_commits: HashSet::new(),
            #[cfg(feature = "flutter")]
            committed_surfaces_scratch: Vec::new(),
            #[cfg(feature = "flutter")]
            scene_windows_scratch: Vec::new(),
            #[cfg(feature = "flutter")]
            scene_textures_scratch: Vec::new(),
            #[cfg(feature = "flutter")]
            scene_popups_scratch: Vec::new(),
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
            restore_window_geometries: HashMap::new(),
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
            client_pointer_buttons: HashSet::new(),
            #[cfg(feature = "flutter")]
            client_pointer_presses: Vec::new(),
            wayland_pointer_buttons: HashSet::new(),
            #[cfg(feature = "flutter")]
            routed_pointer_target: RoutedPointerTarget::Flutter,
            #[cfg(feature = "flutter")]
            pending_cursor_shape: None,
            #[cfg(feature = "flutter")]
            published_client_cursor_shape: None,
            #[cfg(feature = "flutter")]
            flutter_touch_slots: HashSet::new(),
            #[cfg(feature = "flutter")]
            client_touch_routes: HashMap::new(),
            #[cfg(feature = "flutter")]
            flutter_keyboard_keys: HashSet::new(),
            retired_keyboard_keys: HashSet::new(),
            #[cfg(feature = "flutter")]
            minimized_windows: HashSet::new(),
            _output_manager_state: output_manager_state,
            seat_state,
            data_device_state,
            popups,
            seat,
            presentation,
            outputs,
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
        let shape = software_cursor_shape(&image);
        self.cursor_status = image;
        if matches!(self.routed_pointer_target, RoutedPointerTarget::Client(_)) {
            self.queue_client_cursor_shape(shape);
        }
    }

    #[cfg(feature = "flutter")]
    fn queue_client_cursor_shape(&mut self, shape: &'static str) {
        if self.pending_cursor_shape == Some(shape)
            || (self.pending_cursor_shape.is_none()
                && self.published_client_cursor_shape == Some(shape))
        {
            return;
        }
        self.pending_cursor_shape = Some(shape);
    }

    #[cfg(feature = "flutter")]
    fn set_routed_pointer_target(&mut self, target: RoutedPointerTarget) {
        if self.routed_pointer_target == target {
            return;
        }
        self.routed_pointer_target = target;
        self.published_client_cursor_shape = None;
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
        self.published_client_cursor_shape = Some(shape);
        Some(shape)
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
    pub(super) fn window_geometry_locked(&self, window: &Window) -> bool {
        let Some(root_surface) = self.window_root_surface(window) else {
            return false;
        };
        if self.shell_fullscreen_locks.contains(&root_surface.id()) {
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
    pub(super) fn toggle_shell_fullscreen_lock(&mut self, window: &Window) {
        let Some(root_surface) = self.window_root_surface(window) else {
            return;
        };
        if !self.shell_fullscreen_locks.remove(&root_surface.id())
            && !self.window_geometry_locked(window)
        {
            self.shell_fullscreen_locks.insert(root_surface.id());
        }
    }

    pub(super) fn window_for_root_surface(&self, surface: &WlSurface) -> Option<Window> {
        self.space
            .elements()
            .find(|window| self.window_root_surface(window).as_ref() == Some(surface))
            .cloned()
    }

    pub(super) fn window_geometry_target(&self, window: &Window) -> Rectangle<i32, Logical> {
        self.window_root_surface(window)
            .and_then(|surface| {
                self.configured_window_geometries
                    .get(&surface.id())
                    .copied()
            })
            .or_else(|| self.space.element_geometry(window))
            .unwrap_or_else(|| window.bbox())
    }

    pub(super) fn set_window_geometry_target(
        &mut self,
        window: &Window,
        target: Rectangle<i32, Logical>,
    ) {
        let Some(root_surface) = self.window_root_surface(window) else {
            return;
        };
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
    }

    fn reconcile_committed_window_geometry(&mut self, window: &Window) {
        let Some(root_surface) = self.window_root_surface(window) else {
            return;
        };
        let surface_id = root_surface.id();
        let Some(target) = self.configured_window_geometries.get(&surface_id).copied() else {
            return;
        };
        let committed = window.geometry();
        // `target.loc` and Space's element location use the same global
        // geometry coordinate system.  `committed.loc` remains surface-local
        // and must affect rendering only (Space subtracts it internally).
        self.space.relocate_element(window, target.loc);
        if committed.size == target.size {
            self.configured_window_geometries.remove(&surface_id);
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
            let (fullscreen, maximized) = if let Some(toplevel) = window.toplevel() {
                (
                    toplevel_has_state(toplevel, xdg_toplevel::State::Fullscreen),
                    toplevel_has_state(toplevel, xdg_toplevel::State::Maximized),
                )
            } else if let Some(x11) = window.x11_surface() {
                (x11.is_fullscreen(), x11.is_maximized())
            } else {
                (false, false)
            };
            if fullscreen || maximized {
                if let Some(restore) = self
                    .restore_window_geometries
                    .get(&root_surface.id())
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
                events.push(PendingWindowEvent::Action(
                    window_id,
                    if fullscreen {
                        WindowAction::ToggleFullscreen
                    } else {
                        WindowAction::Maximize
                    },
                ));
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
        while self.surfaces_by_id.contains_key(&surface_id) {
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

    fn remove_surface_state(&mut self, surface: &WlSurface, remove_identity: bool) {
        let object_id = surface.id();
        #[cfg(feature = "flutter")]
        let stable_id = self.surface_ids.get(&object_id).copied();
        #[cfg(feature = "flutter")]
        let removes_toplevel = self
            .space
            .elements()
            .any(|window| self.window_root_surface(window).as_ref() == Some(surface));

        self.surface_buffers.remove(&object_id);
        self.configured_window_geometries.remove(&object_id);
        self.restore_window_geometries.remove(&object_id);
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

    #[cfg(feature = "flutter")]
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
    fn queue_surface_commit(&mut self, surface: &WlSurface) {
        self.pending_surface_commits.insert(surface.id());
    }

    #[cfg(feature = "flutter")]
    fn publish_surface_commits(&mut self, root: &WlSurface) -> bool {
        let mut committed_surfaces = std::mem::take(&mut self.committed_surfaces_scratch);
        committed_surfaces.clear();
        with_surface_tree_upward(
            root,
            (),
            |_, _, _| TraversalAction::DoChildren(()),
            |surface, _, _| committed_surfaces.push(surface.clone()),
            |_, _, _| true,
        );

        let mut published = false;
        for surface in committed_surfaces.drain(..) {
            if !self.pending_surface_commits.remove(&surface.id()) {
                continue;
            }
            published = true;
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
        }
        self.committed_surfaces_scratch = committed_surfaces;
        published
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
                let dmabuf = renderer_buffer
                    .and_then(|buffer| get_dmabuf(buffer).ok())
                    .cloned();
                let buffer_guard = dmabuf.as_ref().and_then(|_| renderer_buffer.cloned());
                let (texture_id, width, height) = if let (Some(dmabuf), Some(buffer_guard)) =
                    (dmabuf, buffer_guard)
                {
                    let width = dmabuf.width();
                    let height = dmabuf.height();
                    if let Ok(texture_id) = i64::try_from(surface_id) {
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
                    } else {
                        (0, width, height)
                    }
                } else if let Some(frame) = self.surface_shm_frames.get(&surface.id()).cloned() {
                    let width = frame.width();
                    let height = frame.height();
                    if let Ok(texture_id) = i64::try_from(surface_id) {
                        textures.push(ExternalTextureFrame::from_shm(
                            texture_id,
                            frame,
                            expects_sample,
                        ));
                        (surface_id, width, height)
                    } else {
                        (0, width, height)
                    }
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
                });
                *composition_order = composition_order.saturating_add(1);
            },
            |_, _, _| true,
        );
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
        let mut window_count = 0;
        for window in self.space.elements() {
            let Some(surface) = self.window_root_surface(window) else {
                continue;
            };
            let stable_id = self
                .surface_id(&surface)
                .ok_or("desktop window is missing its stable surface identifier")?;
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
            // Every mapped client remains a live texture producer. In
            // particular, a minimized window must continue sampling new
            // buffers so restoring it never exposes an abandoned/black frame.
            let expects_sample = true;
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
                    let popup_like = x11.is_override_redirect()
                        || matches!(
                            x11.window_type(),
                            Some(
                                WmWindowType::Combo
                                    | WmWindowType::Dnd
                                    | WmWindowType::DropdownMenu
                                    | WmWindowType::Menu
                                    | WmWindowType::Notification
                                    | WmWindowType::PopupMenu
                                    | WmWindowType::Tooltip
                            )
                        );
                    (
                        popup_like,
                        !popup_like && !x11.is_decorated(),
                        xwayland::x11_window_opacity(x11),
                    )
                })
                .unwrap_or((false, true, 1.0));
            if window_opacity < 1.0 {
                for layer in &mut layers {
                    layer.opacity *= window_opacity;
                }
            }
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
            };
            if let Some(previous) = windows.get_mut(window_count) {
                *previous = description;
            } else {
                windows.push(description);
            }
            window_count += 1;
        }
        windows.truncate(window_count);
        self.scene_popups_scratch = popups;
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
    ) -> Option<InputLayoutSnapshot> {
        let routing_changed = input_routing_changed(self.input_layout.as_ref(), &layout);
        let visibility_changed = self
            .input_layout
            .as_ref()
            .is_none_or(|current| current.visible_surface_ids != layout.visible_surface_ids);
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
        previous
    }

    #[cfg(feature = "flutter")]
    pub(super) fn reset_flutter_input_generation(&mut self) {
        // The replacement engine has not observed the old generation's
        // layout, pressed keys, or active touch sequences. Forget them so a
        // later release/up cannot be delivered to the new engine without its
        // matching press/down. Client captures and routes remain untouched.
        self.input_layout = None;
        self.visible_window_ids.clear();
        self.input_visibility_known = false;
        self.client_input_route_cache = None;
        self.flutter_touch_slots.clear();
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

    /// Projects the compositor-owned logical pointer into the Flutter atlas.
    /// Flutter runs at pixel ratio 1, so embedder pointer coordinates are
    /// physical atlas pixels rather than desktop logical coordinates.
    #[cfg(feature = "flutter")]
    pub(super) fn flutter_pointer_position(&self) -> (f64, f64) {
        (
            (self.pointer_location.x - self.atlas_origin.x) * self.atlas_scale,
            (self.pointer_location.y - self.atlas_origin.y) * self.atlas_scale,
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
            }
        }
        for window in self.space.elements() {
            let geometry = self.window_geometry_target(window);
            let Some(output_index) = self.output_index_for_geometry(geometry) else {
                continue;
            };
            if self.outputs[output_index].submitted_this_batch {
                let entry = &mut self.outputs[output_index];
                entry
                    .presentation_batch
                    .submit_window(&entry.output, window);
            }
        }
        self.display_handle.flush_clients()?;
        Ok(())
    }

    #[cfg(feature = "flutter")]
    pub fn outputs_presented(
        &mut self,
        outputs: &[super::PresentedOutput],
        callback_outputs: &mut Vec<OutputId>,
    ) -> Result<(), Box<dyn Error>> {
        callback_outputs.clear();
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

        // Match the C++ compositor's physical-edge contract. A client is
        // released only after the previous KMS submission really presented;
        // the scheduler uses callback_outputs to arm one lookahead edge for
        // every output on which client work was requested.
        for window in self.space.elements() {
            let geometry = self.window_geometry_target(window);
            let Some(output_index) = self.output_index_for_geometry(geometry) else {
                continue;
            };
            let output_id = self.outputs[output_index].id;
            let Some(presented_output) = outputs
                .iter()
                .find(|presented_output| presented_output.id == output_id)
            else {
                continue;
            };
            let callback_time = presented_output.presented_at.unwrap_or_else(|| {
                presented_output
                    .observed_at
                    .saturating_duration_since(self.start_time)
            });
            if presentation::send_window_frame_callbacks(window, callback_time) > 0
                && !callback_outputs.contains(&output_id)
            {
                callback_outputs.push(output_id);
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

    /// Collect outputs on which any mapped client is waiting for a frame
    /// callback. This mirrors C++ `SurfaceRegistry::hasFrameCallbacks`: the
    /// callback itself demands one physical edge even when its commit carried
    /// no new pixels and arrived after the normal lookahead edge.
    #[cfg(feature = "flutter")]
    pub fn outputs_with_frame_callback_demand(&self, output_ids: &mut Vec<OutputId>) {
        output_ids.clear();
        for window in self.space.elements() {
            if !presentation::window_has_frame_callbacks(window) {
                continue;
            }
            let geometry = self.window_geometry_target(window);
            let Some(output_index) = self.output_index_for_geometry(geometry) else {
                continue;
            };
            let output_id = self.outputs[output_index].id;
            if !output_ids.contains(&output_id) {
                output_ids.push(output_id);
            }
        }
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
                // must not turn an untrusted connection into a compositor
                // panic. Dropping the stream rejects this client only.
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
    use super::{CursorImageStatus, input_routing_changed, software_cursor_shape};
    use super::{MAX_PENDING_DMABUF_IMPORTS, dmabuf_import_queue_has_capacity};
    #[cfg(feature = "flutter")]
    use crate::wire::{InputLayoutSnapshot, InputRect};
    #[cfg(feature = "flutter")]
    use smithay::input::pointer::CursorIcon;

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
    fn input_route_survives_epoch_and_visibility_only_layout_updates() {
        let current = InputLayoutSnapshot::default();
        let mut next = current.clone();
        next.epoch = 9;
        next.visible_surface_ids.push(42);
        assert!(!input_routing_changed(Some(&current), &next));

        next.shell_regions.push(InputRect {
            x: 0.0,
            y: 0.0,
            width: 10.0,
            height: 10.0,
        });
        assert!(input_routing_changed(Some(&current), &next));
        assert!(input_routing_changed(None, &next));
    }
}
