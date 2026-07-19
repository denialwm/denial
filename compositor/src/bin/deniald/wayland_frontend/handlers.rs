use super::window_management::{
    clear_toplevel_state, configure_toplevel_for_output, toplevel_has_state,
};
#[cfg(feature = "flutter")]
use super::window_management::{
    queue_window_action, queue_window_placement, toplevel_shell_geometry_locked,
};
use super::*;
use smithay::wayland::selection::{SelectionSource, SelectionTarget};
use std::collections::HashSet;
use std::os::fd::OwnedFd;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

pub(super) const MAX_WAYLAND_CLIENTS: usize = 128;
const MAX_SURFACES_PER_CLIENT: usize = 1_024;
const MAX_WAYLAND_SURFACES: usize = 16_384;
// Core wayland.xml assigns wl_display.error.no_memory numeric value 2.
const WL_DISPLAY_NO_MEMORY: u32 = 2;

fn try_reserve(counter: &AtomicUsize, limit: usize) -> bool {
    counter
        .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |current| {
            (current < limit).then_some(current + 1)
        })
        .is_ok()
}

fn release(counter: &AtomicUsize, amount: usize) {
    if amount == 0 {
        return;
    }
    let _ = counter.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |current| {
        Some(current.saturating_sub(amount))
    });
}

#[derive(Default)]
pub(super) struct WaylandClientBudget {
    clients: AtomicUsize,
    surfaces: AtomicUsize,
}

impl WaylandClientBudget {
    pub(super) fn try_reserve_client(self: &Arc<Self>) -> Option<DenialClientState> {
        try_reserve(&self.clients, MAX_WAYLAND_CLIENTS).then(|| DenialClientState {
            compositor_state: CompositorClientState::default(),
            budget: Some(Arc::clone(self)),
            surfaces: Mutex::new(HashSet::new()),
            reservation_live: AtomicBool::new(true),
        })
    }
}

#[cfg(feature = "flutter")]
const fn commit_affects_published_scene(
    effectively_synchronized: bool,
    has_desktop_owner: bool,
    published_visual_update: bool,
) -> bool {
    // A synchronized subsurface commit only updates cached state. Its parent
    // commit publishes the complete transaction and marks the scene dirty.
    // Conversely, a cursor, drag icon, or otherwise untracked surface has no
    // representation in Flutter's desktop scene even when it has a buffer.
    !effectively_synchronized && has_desktop_owner && published_visual_update
}

#[cfg(feature = "flutter")]
const fn commit_has_visual_update(
    first_buffer: bool,
    buffer_removed: bool,
    has_damage: bool,
    sampling_changed: bool,
) -> bool {
    first_buffer || buffer_removed || has_damage || sampling_changed
}

pub(super) struct DenialClientState {
    compositor_state: CompositorClientState,
    budget: Option<Arc<WaylandClientBudget>>,
    surfaces: Mutex<HashSet<ObjectId>>,
    reservation_live: AtomicBool,
}

impl Default for DenialClientState {
    fn default() -> Self {
        Self {
            compositor_state: CompositorClientState::default(),
            budget: None,
            surfaces: Mutex::new(HashSet::new()),
            reservation_live: AtomicBool::new(true),
        }
    }
}

impl DenialClientState {
    fn try_register_surface(&self, surface: ObjectId) -> bool {
        let mut surfaces = self
            .surfaces
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        // Keep this test under the same lock as teardown. Otherwise a surface
        // creation racing client disconnection could reserve quota after the
        // disconnect callback had returned everything.
        if !self.reservation_live.load(Ordering::Acquire) {
            return false;
        }
        if surfaces.contains(&surface) {
            return true;
        }
        if surfaces.len() >= MAX_SURFACES_PER_CLIENT {
            return false;
        }
        if let Some(budget) = self.budget.as_ref()
            && !try_reserve(&budget.surfaces, MAX_WAYLAND_SURFACES)
        {
            return false;
        }
        if surfaces.insert(surface) {
            true
        } else {
            if let Some(budget) = self.budget.as_ref() {
                release(&budget.surfaces, 1);
            }
            false
        }
    }

    fn unregister_surface(&self, surface: &ObjectId) {
        let removed = self
            .surfaces
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(surface);
        if removed && let Some(budget) = self.budget.as_ref() {
            release(&budget.surfaces, 1);
        }
    }

    fn release_reservations(&self) {
        let remaining_surfaces = {
            let mut surfaces = self
                .surfaces
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if !self.reservation_live.swap(false, Ordering::AcqRel) {
                return;
            }
            let remaining_surfaces = surfaces.len();
            surfaces.clear();
            remaining_surfaces
        };

        if let Some(budget) = self.budget.as_ref() {
            release(&budget.surfaces, remaining_surfaces);
            release(&budget.clients, 1);
        }
    }
}

impl Drop for DenialClientState {
    fn drop(&mut self) {
        self.release_reservations();
    }
}

impl ClientData for DenialClientState {
    fn initialized(&self, _client_id: ClientId) {}

    fn disconnected(&self, _client_id: ClientId, _reason: DisconnectReason) {
        // ClientData may remain alive after the connection disappears. Return
        // both reservations promptly; Drop is an idempotent fallback.
        self.release_reservations();
    }
}

#[derive(Clone)]
struct DenialSurfaceOwner(ClientId);

#[derive(Debug)]
struct CancelledSurfaceReadiness;

impl Blocker for CancelledSurfaceReadiness {
    fn state(&self) -> BlockerState {
        BlockerState::Cancelled
    }
}

fn cancel_unsynchronized_surface_commit(surface: &WlSurface) {
    // Applying a commit after its readiness source failed would let Flutter
    // sample producer-owned storage without any acquire guarantee. Discard the
    // transaction instead; the client can submit a later buffer once the
    // compositor event loop is healthy again.
    add_blocker(surface, CancelledSurfaceReadiness);
}

fn install_surface_readiness_hook(surface: &WlSurface) {
    add_pre_commit_hook::<RuntimeState, _>(surface, |state, _display, surface| {
        // LoopHandle is deliberately fetched at invocation time: Smithay's
        // surface hooks are Send + Sync, while calloop handles are confined to
        // the compositor thread that executes this hook.
        let loop_handle = state
            .wayland
            .as_ref()
            .expect("missing Wayland frontend")
            .loop_handle
            .clone();
        let (acquire_point, dmabuf) = with_states(surface, |states| {
            let mut syncobj = states.cached_state.get::<DrmSyncobjCachedState>();
            let acquire_point = syncobj.pending().acquire_point.clone();
            let mut attributes = states.cached_state.get::<SurfaceAttributes>();
            let dmabuf =
                attributes
                    .pending()
                    .buffer
                    .as_ref()
                    .and_then(|assignment| match assignment {
                        BufferAssignment::NewBuffer(buffer) => get_dmabuf(buffer).cloned().ok(),
                        _ => None,
                    });
            (acquire_point, dmabuf)
        });
        let Some(dmabuf) = dmabuf else {
            return;
        };
        let Some(client) = surface.client() else {
            warn!(surface_id = ?surface.id(), "DMA-BUF commit has no owning Wayland client");
            cancel_unsynchronized_surface_commit(surface);
            return;
        };

        if let Some(acquire_point) = acquire_point {
            match acquire_point.generate_blocker() {
                Ok((blocker, source)) => {
                    let source_client = client.clone();
                    match loop_handle.insert_source(source, move |_, _, state| {
                        let display_handle = state
                            .wayland
                            .as_ref()
                            .expect("missing Wayland frontend")
                            .display_handle
                            .clone();
                        state
                            .client_compositor_state(&source_client)
                            .blocker_cleared(state, &display_handle);
                        Ok(())
                    }) {
                        Ok(_) => {
                            add_blocker(surface, blocker);
                            return;
                        }
                        Err(error) => {
                            error!(
                                ?error,
                                surface_id = ?surface.id(),
                                "could not monitor explicit DMA-BUF acquire point"
                            );
                            cancel_unsynchronized_surface_commit(surface);
                            return;
                        }
                    }
                }
                Err(error) => {
                    error!(
                        %error,
                        surface_id = ?surface.id(),
                        "could not create explicit DMA-BUF acquire blocker"
                    );
                    cancel_unsynchronized_surface_commit(surface);
                    return;
                }
            }
        }

        // Clients without wp_linux_drm_syncobj_v1 still publish their producer
        // write fence through the DMA-BUF reservation object. Delay the surface
        // transaction until the exclusive fence is readable, matching the old
        // C++ compositor's implicit-sync fallback.
        let Ok((blocker, source)) = dmabuf.generate_blocker(Interest::READ) else {
            return;
        };
        let source_client = client.clone();
        match loop_handle.insert_source(source, move |_, _, state| {
            let display_handle = state
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .display_handle
                .clone();
            state
                .client_compositor_state(&source_client)
                .blocker_cleared(state, &display_handle);
            Ok(())
        }) {
            Ok(_) => add_blocker(surface, blocker),
            Err(error) => {
                error!(
                    ?error,
                    surface_id = ?surface.id(),
                    "could not monitor implicit DMA-BUF acquire fence"
                );
                cancel_unsynchronized_surface_commit(surface);
            }
        }
    });
}

impl CompositorHandler for RuntimeState {
    fn compositor_state(&mut self) -> &mut CompositorState {
        &mut self
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .compositor_state
    }

    fn client_compositor_state<'a>(&self, client: &'a Client) -> &'a CompositorClientState {
        if let Some(state) = client.get_data::<XWaylandClientData>() {
            return &state.compositor_state;
        }
        &client
            .get_data::<DenialClientState>()
            .expect("unknown Wayland client data")
            .compositor_state
    }

    fn new_surface(&mut self, surface: &WlSurface) {
        let (display_handle, client) = {
            let frontend = self.wayland.as_ref().expect("missing Wayland frontend");
            let display_handle = frontend.display_handle.clone();
            let client = display_handle.get_client(surface.id());
            (display_handle, client)
        };
        let client = client.expect("new surface belongs to an unknown Wayland client");
        if let Some(client_state) = client.get_data::<DenialClientState>()
            && !client_state.try_register_surface(surface.id())
        {
            warn!(
                client_id = ?client.id(),
                surface_id = ?surface.id(),
                per_client_limit = MAX_SURFACES_PER_CLIENT,
                global_limit = MAX_WAYLAND_SURFACES,
                "disconnecting Wayland client that exceeded the surface budget"
            );
            client.kill(
                &display_handle,
                ProtocolError {
                    code: WL_DISPLAY_NO_MEMORY,
                    object_id: 1,
                    object_interface: "wl_display".into(),
                    message: "Denial Wayland surface budget exhausted".into(),
                },
            );
            return;
        }
        if client.get_data::<DenialClientState>().is_none()
            && client.get_data::<XWaylandClientData>().is_none()
        {
            warn!(client_id = ?client.id(), "disconnecting client with unknown Wayland state");
            client.kill(
                &display_handle,
                ProtocolError {
                    code: WL_DISPLAY_NO_MEMORY,
                    object_id: 1,
                    object_interface: "wl_display".into(),
                    message: "Denial rejected an unknown Wayland client".into(),
                },
            );
            return;
        }
        install_surface_readiness_hook(surface);
        with_states(surface, |states| {
            states
                .data_map
                .insert_if_missing_threadsafe(|| DenialSurfaceOwner(client.id()));
        });
        self.wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .register_surface(surface);
    }

    fn commit(&mut self, surface: &WlSurface) {
        let synchronized = is_sync_subsurface(surface);
        let (buffer_update, has_damage, has_frame_callbacks) = with_states(surface, |states| {
            let mut attributes = states.cached_state.get::<SurfaceAttributes>();
            let current = attributes.current();
            let buffer_update = match current.buffer.as_ref() {
                Some(BufferAssignment::NewBuffer(buffer)) => Some(Some(buffer.clone())),
                Some(BufferAssignment::Removed) => Some(None),
                None => None,
            };
            (
                buffer_update,
                !current.damage.is_empty(),
                !current.frame_callbacks.is_empty(),
            )
        });
        #[cfg(not(feature = "flutter"))]
        let _ = (has_damage, has_frame_callbacks);
        #[cfg(feature = "flutter")]
        let previous_sampling = with_renderer_surface_state(surface, |state| {
            (
                state.view(),
                state.buffer_size(),
                state.buffer_scale(),
                state.buffer_transform(),
            )
        });
        #[cfg(feature = "flutter")]
        let (first_buffer, buffer_removed) = {
            let frontend = self.wayland.as_ref().expect("missing Wayland frontend");
            (
                buffer_update.as_ref().is_some_and(Option::is_some)
                    && !frontend.surface_buffers.contains_key(&surface.id()),
                buffer_update.as_ref().is_some_and(Option::is_none),
            )
        };
        if let Some(buffer) = buffer_update {
            let frontend = self.wayland.as_mut().expect("missing Wayland frontend");
            if let Some(buffer) = buffer {
                #[cfg(feature = "flutter")]
                if get_dmabuf(&buffer).is_ok() {
                    frontend.pending_shm_snapshots.remove(&surface.id());
                } else {
                    frontend.pending_shm_snapshots.insert(surface.id());
                }
                frontend.surface_buffers.insert(surface.id(), buffer);
            } else {
                frontend.surface_buffers.remove(&surface.id());
                #[cfg(feature = "flutter")]
                frontend.pending_shm_snapshots.remove(&surface.id());
            }
        }
        on_commit_buffer_handler::<Self>(surface);
        let frontend = self.wayland.as_mut().expect("missing Wayland frontend");
        #[cfg(feature = "flutter")]
        let sampling_changed = previous_sampling
            != with_renderer_surface_state(surface, |state| {
                (
                    state.view(),
                    state.buffer_size(),
                    state.buffer_scale(),
                    state.buffer_transform(),
                )
            });
        #[cfg(feature = "flutter")]
        let visual_update =
            commit_has_visual_update(first_buffer, buffer_removed, has_damage, sampling_changed);
        #[cfg(feature = "flutter")]
        if visual_update {
            frontend.queue_surface_commit(surface);
        }
        #[cfg(feature = "flutter")]
        let mut published_visual_update = false;
        if !synchronized {
            #[cfg(feature = "flutter")]
            {
                // A callback-only Chromium commit must not create a new
                // external-texture generation. Pending synchronized child
                // damage is still published by this parent transaction.
                published_visual_update = frontend.publish_surface_commits(surface);
            }
            let mut root = surface.clone();
            while let Some(parent) = get_parent(&root) {
                root = parent;
            }
            let window = frontend.window_for_root_surface(&root);
            if let Some(window) = window {
                window.on_commit();
                frontend.reconcile_committed_window_geometry(&window);
            }
        }
        #[cfg(feature = "flutter")]
        let affects_published_scene = commit_affects_published_scene(
            synchronized,
            frontend.owning_toplevel_surface(surface).is_some(),
            published_visual_update,
        );
        handle_xdg_commit(&mut frontend.popups, &frontend.space, surface);
        #[cfg(feature = "flutter")]
        if affects_published_scene {
            self.scene_sync.mark_dirty();
        }
        #[cfg(feature = "flutter")]
        if has_frame_callbacks {
            // C++ wakes its output state machine from every surface commit
            // carrying a frame callback. Keep only the edge here; the
            // scheduler resolves the owning output once per committed batch.
            self.frame_callback_demand = true;
        }
        #[cfg(not(feature = "flutter"))]
        self.scene_sync.mark_dirty();
    }

    fn destroyed(&mut self, surface: &WlSurface) {
        // A system-backend ObjectId is already invalid by the time this
        // callback runs, so DisplayHandle::get_client(surface.id()) is not a
        // reliable way to find the owner. The ClientId captured at creation
        // remains usable while that client is alive.
        let owner = with_states(surface, |states| {
            states
                .data_map
                .get::<DenialSurfaceOwner>()
                .map(|owner| owner.0.clone())
        });
        if let Some(frontend) = self.wayland.as_ref()
            && let Some(owner) = owner
            && let Ok(client_data) = frontend
                .display_handle
                .backend_handle()
                .get_client_data(owner)
            && let Some(client_state) = (*client_data).downcast_ref::<DenialClientState>()
        {
            client_state.unregister_surface(&surface.id());
        }
        let frontend = self.wayland.as_mut().expect("missing Wayland frontend");
        frontend.remove_surface_state(surface, true);
        self.scene_sync.mark_dirty();
    }
}

impl BufferHandler for RuntimeState {
    fn buffer_destroyed(&mut self, buffer: &wl_buffer::WlBuffer) {
        let frontend = self.wayland.as_mut().expect("missing Wayland frontend");
        frontend
            .surface_buffers
            .retain(|_, current| current != buffer);
        self.scene_sync.mark_dirty();
    }
}

impl DrmSyncobjHandler for RuntimeState {
    fn drm_syncobj_state(&mut self) -> Option<&mut DrmSyncobjState> {
        self.wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .drm_syncobj_state
            .as_mut()
    }
}

impl ShmHandler for RuntimeState {
    fn shm_state(&self) -> &ShmState {
        &self
            .wayland
            .as_ref()
            .expect("missing Wayland frontend")
            .shm_state
    }
}

impl DmabufHandler for RuntimeState {
    fn dmabuf_state(&mut self) -> &mut DmabufState {
        &mut self
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .dmabuf_state
    }

    fn dmabuf_imported(
        &mut self,
        _global: &DmabufGlobal,
        dmabuf: Dmabuf,
        notifier: ImportNotifier,
    ) {
        self.wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .queue_dmabuf_import(dmabuf, notifier);
    }
}

impl OutputHandler for RuntimeState {}

impl SeatHandler for RuntimeState {
    type KeyboardFocus = KeyboardFocusTarget;
    type PointerFocus = WlSurface;
    type TouchFocus = WlSurface;

    fn seat_state(&mut self) -> &mut SeatState<Self> {
        &mut self
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .seat_state
    }

    fn cursor_image(&mut self, _seat: &Seat<Self>, image: CursorImageStatus) {
        let frontend = self.wayland.as_mut().expect("missing Wayland frontend");
        #[cfg(feature = "flutter")]
        frontend.update_cursor_image(image);
        #[cfg(not(feature = "flutter"))]
        {
            frontend.cursor_status = image;
        }
    }

    fn focus_changed(&mut self, seat: &Seat<Self>, focused: Option<&KeyboardFocusTarget>) {
        let display_handle = self
            .wayland
            .as_ref()
            .expect("missing Wayland frontend")
            .display_handle
            .clone();
        let client = focused
            .and_then(WaylandFocus::wl_surface)
            .and_then(|surface| display_handle.get_client(surface.id()).ok());
        set_data_device_focus(&display_handle, seat, client);
    }
}

// wp_cursor_shape_manager_v1 shares its dispatcher with tablet cursor
// shapes.  Denial does not advertise tablet seats yet, so the default inert
// callback is sufficient while enabling named pointer cursors.
impl TabletSeatHandler for RuntimeState {}

impl PointerConstraintsHandler for RuntimeState {
    fn new_constraint(&mut self, surface: &WlSurface, pointer: &PointerHandle<Self>) {
        if pointer.current_focus().as_ref() == Some(surface) {
            smithay::wayland::pointer_constraints::with_pointer_constraint(
                surface,
                pointer,
                |constraint| {
                    if let Some(constraint) = constraint {
                        constraint.activate();
                    }
                },
            );
        }
    }

    fn remove_constraint(&mut self, _surface: &WlSurface, _pointer: &PointerHandle<Self>) {}

    fn cursor_position_hint(
        &mut self,
        _surface: &WlSurface,
        _pointer: &PointerHandle<Self>,
        _location: Point<f64, Logical>,
    ) {
    }
}

impl SelectionHandler for RuntimeState {
    type SelectionUserData = ();

    fn new_selection(
        &mut self,
        selection: SelectionTarget,
        source: Option<SelectionSource>,
        _seat: Seat<Self>,
    ) {
        if selection != SelectionTarget::Clipboard {
            return;
        }
        if let Some(xwm) = self
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .xwm
            .as_mut()
            && let Err(error) =
                xwm.new_selection(selection, source.map(|source| source.mime_types()))
        {
            warn!(%error, "could not publish Wayland clipboard to Xwayland");
        }
    }

    fn send_selection(
        &mut self,
        selection: SelectionTarget,
        mime_type: String,
        fd: OwnedFd,
        _seat: Seat<Self>,
        _user_data: &(),
    ) {
        if selection != SelectionTarget::Clipboard {
            return;
        }
        if let Some(xwm) = self
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .xwm
            .as_mut()
            && let Err(error) = xwm.send_selection(selection, mime_type, fd)
        {
            warn!(%error, "could not transfer Xwayland clipboard data to Wayland");
        }
    }
}

impl DataDeviceHandler for RuntimeState {
    fn data_device_state(&mut self) -> &mut DataDeviceState {
        &mut self
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .data_device_state
    }
}

impl DndGrabHandler for RuntimeState {}

impl WaylandDndGrabHandler for RuntimeState {
    fn dnd_requested<S: Source>(
        &mut self,
        source: S,
        _icon: Option<WlSurface>,
        seat: Seat<Self>,
        serial: Serial,
        type_: GrabType,
    ) {
        match type_ {
            GrabType::Pointer => {
                let Some(pointer) = seat.get_pointer() else {
                    warn!("cancelled pointer DND request on a seat without a pointer");
                    source.cancel();
                    return;
                };
                let Some(start_data) = pointer.grab_start_data() else {
                    warn!("cancelled pointer DND request without an active pointer grab");
                    source.cancel();
                    return;
                };
                let display_handle = self
                    .wayland
                    .as_ref()
                    .expect("missing Wayland frontend")
                    .display_handle
                    .clone();
                let grab = DnDGrab::new_pointer(&display_handle, start_data, source, seat);
                pointer.set_grab(self, grab, serial, Focus::Keep);
            }
            GrabType::Touch => source.cancel(),
        }
    }
}

impl XdgShellHandler for RuntimeState {
    fn xdg_shell_state(&mut self) -> &mut XdgShellState {
        &mut self
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .xdg_shell_state
    }

    fn new_toplevel(&mut self, surface: ToplevelSurface) {
        let focus = surface.wl_surface().clone();
        let keyboard = self
            .wayland
            .as_ref()
            .expect("missing Wayland frontend")
            .seat
            .get_keyboard()
            .expect("seat has no keyboard");
        let initial_activation = {
            let frontend = self.wayland.as_mut().expect("missing Wayland frontend");
            let window = Window::new_wayland_window(surface);
            let offset = frontend.next_window_offset;
            frontend.next_window_offset = (frontend.next_window_offset + 48).min(384);
            frontend
                .space
                .map_element(window.clone(), (offset, offset), true);
            for candidate in frontend.space.elements() {
                let changed = candidate.set_activated(candidate == &window);
                if changed && let Some(toplevel) = candidate.toplevel() {
                    toplevel.send_pending_configure();
                }
            }
            #[cfg(feature = "flutter")]
            let initial_activation = frontend.surface_id(&focus);
            #[cfg(not(feature = "flutter"))]
            let initial_activation = None::<u64>;
            initial_activation
        };
        keyboard.set_focus(
            self,
            Some(KeyboardFocusTarget::Wayland(focus)),
            SERIAL_COUNTER.next_serial(),
        );
        #[cfg(feature = "flutter")]
        if let Some(window_id) = initial_activation {
            self.pending_window_events
                .push(PendingWindowEvent::Activated(window_id));
        }
        #[cfg(not(feature = "flutter"))]
        let _ = initial_activation;
        self.scene_sync.mark_dirty();
    }

    fn new_popup(&mut self, surface: PopupSurface, _positioner: PositionerState) {
        let frontend = self.wayland.as_mut().expect("missing Wayland frontend");
        frontend.unconstrain_popup(&surface);
        let _ = frontend.popups.track_popup(PopupKind::Xdg(surface));
        self.scene_sync.mark_dirty();
    }

    fn app_id_changed(&mut self, _surface: ToplevelSurface) {
        self.scene_sync.mark_dirty();
    }

    fn title_changed(&mut self, _surface: ToplevelSurface) {
        self.scene_sync.mark_dirty();
    }

    fn reposition_request(
        &mut self,
        surface: PopupSurface,
        positioner: PositionerState,
        token: u32,
    ) {
        surface.with_pending_state(|state| {
            state.geometry = positioner.get_geometry();
            state.positioner = positioner;
        });
        self.wayland
            .as_ref()
            .expect("missing Wayland frontend")
            .unconstrain_popup(&surface);
        surface.send_repositioned(token);
        self.scene_sync.mark_dirty();
    }

    fn move_request(&mut self, surface: ToplevelSurface, seat: wl_seat::WlSeat, serial: Serial) {
        if toplevel_has_state(&surface, xdg_toplevel::State::Fullscreen)
            || toplevel_has_state(&surface, xdg_toplevel::State::Maximized)
        {
            warn!("ignored XDG move while the toplevel is constrained");
            return;
        }
        let Some(seat) = Seat::from_resource(&seat) else {
            return;
        };
        #[cfg(feature = "flutter")]
        let start_data = self
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .take_client_pointer_press(surface.wl_surface(), serial)
            .or_else(|| checked_pointer_grab(&seat, surface.wl_surface(), serial));
        #[cfg(not(feature = "flutter"))]
        let start_data = checked_pointer_grab(&seat, surface.wl_surface(), serial);
        let Some(start_data) = start_data else {
            warn!(
                ?serial,
                "rejected XDG move without a matching implicit grab"
            );
            return;
        };
        let window = self.wayland.as_ref().and_then(|frontend| {
            frontend
                .space
                .elements()
                .find(|window| {
                    window
                        .toplevel()
                        .is_some_and(|candidate| candidate.wl_surface() == surface.wl_surface())
                })
                .cloned()
        });
        let Some(window) = window else {
            return;
        };
        let initial_location = self
            .wayland
            .as_ref()
            .expect("missing Wayland frontend")
            .space
            .element_location(&window)
            .unwrap_or_default();
        #[cfg(feature = "flutter")]
        {
            let geometry = self
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .window_geometry_target(&window);
            queue_window_placement(
                self,
                &window,
                geometry,
                WindowPlacementPhase::Begin,
                WindowPlacementChange::Move,
            );
        }
        let pointer = seat.get_pointer().expect("seat has no pointer");
        pointer.set_grab(
            self,
            MoveSurfaceGrab::new(start_data, window, initial_location),
            serial,
            Focus::Clear,
        );
        self.scene_sync.mark_dirty();
    }

    fn resize_request(
        &mut self,
        surface: ToplevelSurface,
        seat: wl_seat::WlSeat,
        serial: Serial,
        edge: xdg_toplevel::ResizeEdge,
    ) {
        if toplevel_has_state(&surface, xdg_toplevel::State::Fullscreen)
            || toplevel_has_state(&surface, xdg_toplevel::State::Maximized)
        {
            warn!("ignored XDG resize while the toplevel is constrained");
            return;
        }
        let Some(edges) = ResizeEdges::from_xdg(edge) else {
            return;
        };
        let Some(seat) = Seat::from_resource(&seat) else {
            return;
        };
        #[cfg(feature = "flutter")]
        let start_data = self
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .take_client_pointer_press(surface.wl_surface(), serial)
            .or_else(|| checked_pointer_grab(&seat, surface.wl_surface(), serial));
        #[cfg(not(feature = "flutter"))]
        let start_data = checked_pointer_grab(&seat, surface.wl_surface(), serial);
        let Some(start_data) = start_data else {
            warn!(
                ?serial,
                "rejected XDG resize without a matching implicit grab"
            );
            return;
        };
        let window = self.wayland.as_ref().and_then(|frontend| {
            frontend
                .space
                .elements()
                .find(|window| {
                    window
                        .toplevel()
                        .is_some_and(|candidate| candidate.wl_surface() == surface.wl_surface())
                })
                .cloned()
        });
        let Some(window) = window else {
            return;
        };
        let (initial_location, initial_size) = {
            let frontend = self.wayland.as_ref().expect("missing Wayland frontend");
            (
                frontend.space.element_location(&window).unwrap_or_default(),
                frontend.window_geometry_target(&window).size,
            )
        };
        #[cfg(feature = "flutter")]
        {
            let geometry = self
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .window_geometry_target(&window);
            queue_window_placement(
                self,
                &window,
                geometry,
                WindowPlacementPhase::Begin,
                WindowPlacementChange::Resize,
            );
        }
        surface.with_pending_state(|pending| {
            pending.states.set(xdg_toplevel::State::Resizing);
        });
        surface.send_pending_configure();
        let pointer = seat.get_pointer().expect("seat has no pointer");
        pointer.set_grab(
            self,
            ResizeSurfaceGrab::new(
                start_data,
                window,
                surface,
                edges,
                initial_location,
                initial_size,
            ),
            serial,
            Focus::Clear,
        );
        self.scene_sync.mark_dirty();
    }

    fn maximize_request(&mut self, surface: ToplevelSurface) {
        #[cfg(feature = "flutter")]
        let was_fullscreen = toplevel_has_state(&surface, xdg_toplevel::State::Fullscreen);
        #[cfg(feature = "flutter")]
        let shell_geometry_locked = toplevel_shell_geometry_locked(self, &surface);
        let changed =
            configure_toplevel_for_output(self, &surface, None, xdg_toplevel::State::Maximized);
        #[cfg(feature = "flutter")]
        if (changed || was_fullscreen) && !shell_geometry_locked {
            if was_fullscreen {
                queue_window_action(self, &surface, WindowAction::Restore);
            }
            queue_window_action(self, &surface, WindowAction::Maximize);
        }
        #[cfg(not(feature = "flutter"))]
        let _ = changed;
    }

    fn unmaximize_request(&mut self, surface: ToplevelSurface) {
        #[cfg(feature = "flutter")]
        let shell_geometry_locked = toplevel_shell_geometry_locked(self, &surface);
        let changed = clear_toplevel_state(self, &surface, xdg_toplevel::State::Maximized);
        #[cfg(feature = "flutter")]
        if changed && !shell_geometry_locked {
            queue_window_action(self, &surface, WindowAction::Restore);
        }
        #[cfg(not(feature = "flutter"))]
        let _ = changed;
        self.scene_sync.mark_dirty();
    }

    fn fullscreen_request(
        &mut self,
        surface: ToplevelSurface,
        output: Option<wl_output::WlOutput>,
    ) {
        #[cfg(feature = "flutter")]
        let was_maximized = toplevel_has_state(&surface, xdg_toplevel::State::Maximized);
        #[cfg(feature = "flutter")]
        let shell_geometry_locked = toplevel_shell_geometry_locked(self, &surface);
        let changed = configure_toplevel_for_output(
            self,
            &surface,
            output.as_ref(),
            xdg_toplevel::State::Fullscreen,
        );
        #[cfg(feature = "flutter")]
        if (changed || was_maximized) && !shell_geometry_locked {
            if was_maximized {
                queue_window_action(self, &surface, WindowAction::Restore);
            }
            queue_window_action(self, &surface, WindowAction::ToggleFullscreen);
        }
        #[cfg(not(feature = "flutter"))]
        let _ = changed;
    }

    fn unfullscreen_request(&mut self, surface: ToplevelSurface) {
        #[cfg(feature = "flutter")]
        let shell_geometry_locked = toplevel_shell_geometry_locked(self, &surface);
        let changed = clear_toplevel_state(self, &surface, xdg_toplevel::State::Fullscreen);
        #[cfg(feature = "flutter")]
        if changed && !shell_geometry_locked {
            queue_window_action(self, &surface, WindowAction::ToggleFullscreen);
        }
        #[cfg(not(feature = "flutter"))]
        let _ = changed;
        self.scene_sync.mark_dirty();
    }

    fn minimize_request(&mut self, _surface: ToplevelSurface) {
        #[cfg(feature = "flutter")]
        {
            self.wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .minimized_windows
                .insert(_surface.wl_surface().id());
            queue_window_action(self, &_surface, WindowAction::Minimize);
        }
        self.scene_sync.mark_dirty();
    }

    fn grab(&mut self, surface: PopupSurface, seat: wl_seat::WlSeat, serial: Serial) {
        let Some(seat): Option<Seat<RuntimeState>> = Seat::from_resource(&seat) else {
            return;
        };
        let kind = PopupKind::Xdg(surface);
        let Ok(root) = find_popup_root_surface(&kind) else {
            return;
        };
        let mut grab = {
            let frontend = self.wayland.as_mut().expect("missing Wayland frontend");
            let tracked_root = frontend.space.elements().any(|window| {
                window
                    .toplevel()
                    .is_some_and(|toplevel| toplevel.wl_surface() == &root)
            });
            if !tracked_root {
                return;
            }
            let result = frontend.popups.grab_popup(
                KeyboardFocusTarget::Wayland(root.clone()),
                kind,
                &seat,
                serial,
            );
            match result {
                Ok(grab) => grab,
                Err(error) => {
                    warn!(?error, ?serial, "rejected XDG popup grab");
                    return;
                }
            }
        };

        #[cfg(feature = "flutter")]
        {
            let frontend = self.wayland.as_mut().expect("missing Wayland frontend");
            frontend.client_pointer_capture = None;
            frontend.client_pointer_buttons.clear();
            frontend.client_pointer_presses.clear();
        }

        let previous_serial = grab.previous_serial().unwrap_or_else(|| grab.serial());
        let keyboard = seat.get_keyboard();
        let pointer = seat.get_pointer();
        let keyboard_conflict = keyboard.as_ref().is_some_and(|keyboard| {
            keyboard.is_grabbed()
                && !(keyboard.has_grab(serial) || keyboard.has_grab(previous_serial))
        });
        let pointer_conflict = pointer.as_ref().is_some_and(|pointer| {
            pointer.is_grabbed() && !(pointer.has_grab(serial) || pointer.has_grab(previous_serial))
        });
        if keyboard_conflict || pointer_conflict {
            grab.ungrab(PopupUngrabStrategy::All);
            warn!(
                ?serial,
                keyboard_conflict, pointer_conflict, "rejected XDG popup grab over another grab"
            );
            self.scene_sync.mark_dirty();
            return;
        }

        if let Some(keyboard) = keyboard {
            keyboard.set_focus(self, grab.current_grab(), serial);
            keyboard.set_grab(self, PopupKeyboardGrab::new(&grab), serial);
        }
        if let Some(pointer) = pointer {
            pointer.set_grab(self, PopupPointerGrab::new(&grab), serial, Focus::Keep);
        }
        self.scene_sync.mark_dirty();
    }

    fn toplevel_destroyed(&mut self, surface: ToplevelSurface) {
        let frontend = self.wayland.as_mut().expect("missing Wayland frontend");
        let window = frontend
            .space
            .elements()
            .find(|window| {
                window
                    .toplevel()
                    .is_some_and(|toplevel| toplevel.wl_surface() == surface.wl_surface())
            })
            .cloned();
        // Resolve and remove routes for subsurfaces while the owning
        // toplevel is still discoverable in Space. Role destruction can also
        // arrive after Space already lost the window, so cleanup is
        // unconditional and preserves only the wl_surface stable identity.
        frontend.remove_surface_state(surface.wl_surface(), false);
        if let Some(window) = window {
            frontend.space.unmap_elem(&window);
        }
        self.scene_sync.mark_dirty();
    }

    fn popup_destroyed(&mut self, surface: PopupSurface) {
        let frontend = self.wayland.as_mut().expect("missing Wayland frontend");
        frontend.remove_surface_state(surface.wl_surface(), false);
        // The Flutter path does not call WaylandFrontend::render(), where
        // PopupManager cleanup normally lives. Reap dead popup trees and grabs
        // here so role churn cannot retain one entry per destroyed popup.
        frontend.popups.cleanup();
        self.scene_sync.mark_dirty();
    }
}

const fn shell_decoration_mode() -> XdgDecorationMode {
    // Flutter owns the visible frame, title bar, shadows, and window actions.
    // Advertising client-side decorations would render a second frame inside
    // that shell-owned frame, so Denial deliberately keeps one policy for
    // defaults as well as explicit client requests.
    XdgDecorationMode::ServerSide
}

fn configure_shell_decoration(toplevel: &ToplevelSurface) {
    toplevel.with_pending_state(|state| {
        state.decoration_mode = Some(shell_decoration_mode());
    });
    if toplevel.is_initial_configure_sent() {
        toplevel.send_pending_configure();
    }
}

impl XdgDecorationHandler for RuntimeState {
    fn new_decoration(&mut self, toplevel: ToplevelSurface) {
        configure_shell_decoration(&toplevel);
    }

    fn request_mode(&mut self, toplevel: ToplevelSurface, _mode: XdgDecorationMode) {
        configure_shell_decoration(&toplevel);
    }

    fn unset_mode(&mut self, toplevel: ToplevelSurface) {
        configure_shell_decoration(&toplevel);
    }
}

fn handle_xdg_commit(popups: &mut PopupManager, space: &Space<Window>, surface: &WlSurface) {
    if let Some(window) = space
        .elements()
        .find(|window| {
            window
                .toplevel()
                .is_some_and(|top| top.wl_surface() == surface)
        })
        .cloned()
    {
        let initial_configure_sent = with_states(surface, |states| {
            states
                .data_map
                .get::<XdgToplevelSurfaceData>()
                .expect("missing XDG toplevel state")
                .lock()
                .expect("poisoned XDG toplevel state")
                .initial_configure_sent
        });
        if !initial_configure_sent {
            window
                .toplevel()
                .expect("XDG window without toplevel")
                .send_configure();
        }
    }

    popups.commit(surface);
    if let Some(PopupKind::Xdg(popup)) = popups.find_popup(surface)
        && !popup.is_initial_configure_sent()
        && let Err(error) = popup.send_configure()
    {
        // A client may destroy the popup while its requests are being
        // drained. Reject that popup without escalating a stale resource into
        // a compositor-wide panic.
        warn!(%error, surface_id = ?surface.id(), "initial XDG popup configure failed");
    }
}

#[cfg(test)]
mod decoration_policy_tests {
    use super::*;

    #[test]
    fn flutter_shell_is_always_the_decoration_owner() {
        assert_eq!(shell_decoration_mode(), XdgDecorationMode::ServerSide);
    }
}

#[cfg(test)]
mod client_budget_tests {
    use super::*;

    #[test]
    fn atomic_quota_rejects_the_exact_boundary_without_overflowing() {
        let counter = AtomicUsize::new(MAX_WAYLAND_CLIENTS - 1);
        assert!(try_reserve(&counter, MAX_WAYLAND_CLIENTS));
        assert!(!try_reserve(&counter, MAX_WAYLAND_CLIENTS));
        assert_eq!(counter.load(Ordering::Relaxed), MAX_WAYLAND_CLIENTS);
    }

    #[test]
    fn dropping_client_state_returns_its_connection_reservation() {
        let budget = Arc::new(WaylandClientBudget::default());
        let client = budget.try_reserve_client().expect("first client fits");
        assert_eq!(budget.clients.load(Ordering::Relaxed), 1);
        drop(client);
        assert_eq!(budget.clients.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn disconnect_release_is_prompt_idempotent_and_closes_registration() {
        let budget = Arc::new(WaylandClientBudget::default());
        let client = budget.try_reserve_client().expect("first client fits");
        assert!(client.try_register_surface(ObjectId::null()));
        assert_eq!(budget.clients.load(Ordering::Relaxed), 1);
        assert_eq!(budget.surfaces.load(Ordering::Relaxed), 1);

        client.release_reservations();
        assert_eq!(budget.clients.load(Ordering::Relaxed), 0);
        assert_eq!(budget.surfaces.load(Ordering::Relaxed), 0);
        assert!(!client.try_register_surface(ObjectId::null()));

        client.release_reservations();
        drop(client);
        assert_eq!(budget.clients.load(Ordering::Relaxed), 0);
        assert_eq!(budget.surfaces.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn quota_release_is_saturating_under_teardown() {
        let counter = AtomicUsize::new(1);
        release(&counter, usize::MAX);
        assert_eq!(counter.load(Ordering::Relaxed), 0);
    }
}

#[cfg(all(test, feature = "flutter"))]
mod tests {
    use super::{commit_affects_published_scene, commit_has_visual_update};

    #[test]
    fn ignores_commits_that_cannot_publish_native_scene_state() {
        // Cursor, drag icon, and an otherwise unmapped surface have no desktop
        // owner. A synchronized child is published by the parent commit.
        assert!(!commit_affects_published_scene(false, false, true));
        assert!(!commit_affects_published_scene(true, true, true));
        assert!(!commit_affects_published_scene(false, true, false));
    }

    #[test]
    fn publishes_desynchronized_and_root_tree_commits() {
        // Toplevel roots, popup roots, parents releasing synchronized state,
        // and desynchronized subsurfaces all resolve to a desktop owner.
        assert!(commit_affects_published_scene(false, true, true));
    }

    #[test]
    fn callback_only_or_empty_buffer_rotation_is_not_a_visual_generation() {
        assert!(!commit_has_visual_update(false, false, false, false));
        assert!(commit_has_visual_update(true, false, false, false));
        assert!(commit_has_visual_update(false, true, false, false));
        assert!(commit_has_visual_update(false, false, true, false));
        assert!(commit_has_visual_update(false, false, false, true));
    }
}
