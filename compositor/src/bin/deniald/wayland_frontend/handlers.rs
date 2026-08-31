#[cfg(feature = "flutter")]
use super::super::render_audit_enabled;
#[cfg(feature = "flutter")]
use super::window_management::{
    activate_topmost_window, queue_client_window_placement_for_monitor,
    queue_restored_window_state, queue_window_action, queue_window_placement,
    reassert_exact_toplevel_geometry, release_window_focus, set_toplevel_suspended,
    toplevel_shell_geometry_locked,
};
use super::window_management::{
    activate_window, clear_toplevel_state, configure_toplevel_for_output, toplevel_has_state,
};
use super::*;
use smithay::wayland::selection::{SelectionSource, SelectionTarget};
use smithay::wayland::xdg_activation::{
    XdgActivationHandler, XdgActivationState, XdgActivationToken, XdgActivationTokenData,
};
use std::collections::HashSet;
use std::os::fd::OwnedFd;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use tracing::debug;

pub(super) const MAX_WAYLAND_CLIENTS: usize = 128;
const MAX_SURFACES_PER_CLIENT: usize = 1_024;
const MAX_WAYLAND_SURFACES: usize = 16_384;
// Core wayland.xml assigns wl_display.error.no_memory numeric value 2.
const WL_DISPLAY_NO_MEMORY: u32 = 2;

fn initial_toplevel_location(
    output: Option<Rectangle<i32, Logical>>,
    cascade_offset: i32,
) -> Point<i32, Logical> {
    let origin = output.map_or_else(|| Point::from((0, 0)), |output| output.loc);
    Point::from((
        origin.x.saturating_add(cascade_offset),
        origin.y.saturating_add(cascade_offset),
    ))
}

#[cfg(feature = "flutter")]
struct SurfaceCommitAudit {
    interval_started: Instant,
    commits: u64,
    visual_updates: u64,
    damage_commits: u64,
    callback_commits: u64,
    buffer_attach_commits: u64,
    buffer_remove_commits: u64,
    first_buffer_commits: u64,
    sampling_change_commits: u64,
}

#[cfg(feature = "flutter")]
impl Default for SurfaceCommitAudit {
    fn default() -> Self {
        Self {
            interval_started: Instant::now(),
            commits: 0,
            visual_updates: 0,
            damage_commits: 0,
            callback_commits: 0,
            buffer_attach_commits: 0,
            buffer_remove_commits: 0,
            first_buffer_commits: 0,
            sampling_change_commits: 0,
        }
    }
}

#[cfg(feature = "flutter")]
#[derive(Clone, Copy)]
struct SurfaceCommitAuditSample {
    visual_update: bool,
    has_damage: bool,
    has_frame_callbacks: bool,
    buffer_attached: bool,
    buffer_removed: bool,
    first_buffer: bool,
    sampling_changed: bool,
}

#[cfg(feature = "flutter")]
fn record_surface_commit_audit(
    frontend: &WaylandFrontend,
    surface: &WlSurface,
    sample: SurfaceCommitAuditSample,
) {
    if !render_audit_enabled() {
        return;
    }

    let mut root = surface.clone();
    while let Some(parent) = get_parent(&root) {
        root = parent;
    }
    let surface_id = frontend.surface_id(surface);
    let root_id = frontend.surface_id(&root);
    with_states(surface, |states| {
        states
            .data_map
            .insert_if_missing_threadsafe(|| Mutex::new(SurfaceCommitAudit::default()));
        let mut audit = states
            .data_map
            .get::<Mutex<SurfaceCommitAudit>>()
            .expect("surface commit audit was just initialized")
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        audit.commits = audit.commits.saturating_add(1);
        audit.visual_updates = audit
            .visual_updates
            .saturating_add(u64::from(sample.visual_update));
        audit.damage_commits = audit
            .damage_commits
            .saturating_add(u64::from(sample.has_damage));
        audit.callback_commits = audit
            .callback_commits
            .saturating_add(u64::from(sample.has_frame_callbacks));
        audit.buffer_attach_commits = audit
            .buffer_attach_commits
            .saturating_add(u64::from(sample.buffer_attached));
        audit.buffer_remove_commits = audit
            .buffer_remove_commits
            .saturating_add(u64::from(sample.buffer_removed));
        audit.first_buffer_commits = audit
            .first_buffer_commits
            .saturating_add(u64::from(sample.first_buffer));
        audit.sampling_change_commits = audit
            .sampling_change_commits
            .saturating_add(u64::from(sample.sampling_changed));

        let elapsed = audit.interval_started.elapsed();
        if elapsed.as_secs_f64() < 1.0 {
            return;
        }
        info!(
            target: "deniald::render_audit",
            source = "wayland_commit",
            interval_ms = elapsed.as_secs_f64() * 1_000.0,
            ?surface_id,
            ?root_id,
            commits = audit.commits,
            visual_updates = audit.visual_updates,
            damage_commits = audit.damage_commits,
            callback_commits = audit.callback_commits,
            buffer_attach_commits = audit.buffer_attach_commits,
            buffer_remove_commits = audit.buffer_remove_commits,
            first_buffer_commits = audit.first_buffer_commits,
            sampling_change_commits = audit.sampling_change_commits,
            "Wayland surface commit audit"
        );
        *audit = SurfaceCommitAudit::default();
    });
}

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
    buffer_attached: bool,
    buffer_removed: bool,
    sampling_changed: bool,
) -> bool {
    // wl_surface.damage describes how a newly pending buffer differs from
    // the current surface contents; it does not itself provide new contents.
    // In particular, Moonlight's independent frame-callback pacer commits
    // damage at output refresh even though its renderer only attaches a new
    // stream buffer at the configured stream rate. Publishing those
    // damage-only commits would resample an unchanged external texture.
    first_buffer || buffer_attached || buffer_removed || sampling_changed
}

#[cfg(feature = "flutter")]
const fn surface_commit_kind(
    first_buffer: bool,
    buffer_attached: bool,
    buffer_removed: bool,
    sampling_changed: bool,
) -> Option<super::SurfaceCommitKind> {
    if !commit_has_visual_update(
        first_buffer,
        buffer_attached,
        buffer_removed,
        sampling_changed,
    ) {
        return None;
    }
    if buffer_attached && !first_buffer && !buffer_removed && !sampling_changed {
        Some(super::SurfaceCommitKind::BufferOnly)
    } else {
        Some(super::SurfaceCommitKind::Metadata)
    }
}

#[cfg(feature = "flutter")]
fn opaque_regions_signature(regions: Option<&[Rectangle<i32, Logical>]>) -> (usize, u64) {
    let Some(regions) = regions else {
        return (0, 0);
    };
    // Stable, allocation-free FNV-1a over the normalized renderer regions.
    // This runs on the compositor thread, including Chromium's 240 Hz buffer
    // path, so keep it proportional only to the usually tiny region list.
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    for rect in regions {
        for value in [rect.loc.x, rect.loc.y, rect.size.w, rect.size.h] {
            hash ^= u64::from(value as u32);
            hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
        }
    }
    (regions.len(), hash)
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

#[cfg(feature = "flutter")]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct SurfaceCommitMetadata {
    has_damage: bool,
    has_frame_callbacks: bool,
}

#[cfg(feature = "flutter")]
impl SurfaceCommitMetadata {
    fn merge_into_current(self, current: &mut Self) {
        current.has_damage |= self.has_damage;
        current.has_frame_callbacks |= self.has_frame_callbacks;
    }
}

#[cfg(feature = "flutter")]
impl Cacheable for SurfaceCommitMetadata {
    fn commit(&mut self, _display: &DisplayHandle) -> Self {
        std::mem::take(self)
    }

    fn merge_into(self, current: &mut Self, _display: &DisplayHandle) {
        self.merge_into_current(current);
    }
}

#[cfg(feature = "flutter")]
fn surface_tree_has_frame_callbacks(root: &WlSurface) -> bool {
    let mut found = false;
    with_surface_tree_downward(
        root,
        (),
        |_, _, &()| TraversalAction::DoChildren(()),
        |_, states, &()| {
            let mut attributes = states.cached_state.get::<SurfaceAttributes>();
            found |= !attributes.current().frame_callbacks.is_empty();
        },
        |_, _, &()| true,
    );
    found
}

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
            let (dmabuf, has_damage, has_frame_callbacks) = {
                let mut attributes = states.cached_state.get::<SurfaceAttributes>();
                let pending = attributes.pending();
                let dmabuf = pending
                    .buffer
                    .as_ref()
                    .and_then(|assignment| match assignment {
                        BufferAssignment::NewBuffer(buffer) => get_dmabuf(buffer).cloned().ok(),
                        _ => None,
                    });
                (
                    dmabuf,
                    !pending.damage.is_empty(),
                    !pending.frame_callbacks.is_empty(),
                )
            };
            #[cfg(feature = "flutter")]
            {
                *states.cached_state.get::<SurfaceCommitMetadata>().pending() =
                    SurfaceCommitMetadata {
                        has_damage,
                        has_frame_callbacks,
                    };
            }
            #[cfg(not(feature = "flutter"))]
            let _ = (has_damage, has_frame_callbacks);
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
        let buffer_update = with_states(surface, |states| {
            let mut attributes = states.cached_state.get::<SurfaceAttributes>();
            let current = attributes.current();
            match current.buffer.as_ref() {
                Some(BufferAssignment::NewBuffer(buffer)) => Some(Some(buffer.clone())),
                Some(BufferAssignment::Removed) => Some(None),
                None => None,
            }
        });
        #[cfg(feature = "flutter")]
        let commit_metadata = with_states(surface, |states| {
            let mut metadata = states.cached_state.get::<SurfaceCommitMetadata>();
            std::mem::take(metadata.current())
        });
        #[cfg(feature = "flutter")]
        let (has_damage, has_frame_callbacks) = (
            commit_metadata.has_damage,
            commit_metadata.has_frame_callbacks,
        );
        #[cfg(feature = "flutter")]
        let has_frame_callbacks =
            !synchronized && (has_frame_callbacks || surface_tree_has_frame_callbacks(surface));
        #[cfg(not(feature = "flutter"))]
        let (has_damage, has_frame_callbacks) = with_states(surface, |states| {
            let mut attributes = states.cached_state.get::<SurfaceAttributes>();
            let current = attributes.current();
            (
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
                opaque_regions_signature(state.opaque_regions()),
            )
        });
        #[cfg(feature = "flutter")]
        let (first_buffer, buffer_attached, buffer_removed) = {
            let frontend = self.wayland.as_ref().expect("missing Wayland frontend");
            (
                buffer_update.as_ref().is_some_and(Option::is_some)
                    && !frontend.surface_buffers.contains_key(&surface.id()),
                buffer_update.as_ref().is_some_and(Option::is_some),
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
        #[cfg(feature = "flutter")]
        if matches!(
            self.wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .cursor_status,
            CursorImageStatus::Surface(ref cursor_surface) if cursor_surface == surface
        ) {
            with_states(surface, |states| {
                let buffer_delta = states
                    .cached_state
                    .get::<SurfaceAttributes>()
                    .current()
                    .buffer_delta
                    .take();
                if let (Some(buffer_delta), Some(attributes)) = (
                    buffer_delta,
                    states.data_map.get::<CursorImageSurfaceData>(),
                ) {
                    let mut attributes = attributes
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner());
                    attributes.hotspot =
                        cursor_hotspot_after_buffer_delta(attributes.hotspot, buffer_delta);
                }
            });
        }
        let input_method_changed = {
            let frontend = self.wayland.as_mut().expect("missing Wayland frontend");
            frontend.text_input.surface_committed(surface);
            frontend.synchronize_input_method()
        };
        if input_method_changed {
            self.scene_sync.mark_dirty();
        }
        #[cfg(feature = "flutter")]
        let mut restored_window_state = None;
        #[cfg(feature = "flutter")]
        let mut client_sized_window_state = None;
        #[cfg(feature = "flutter")]
        let mut committed_window_metadata_changed = false;
        let frontend = self.wayland.as_mut().expect("missing Wayland frontend");
        #[cfg(feature = "flutter")]
        let sampling_changed = previous_sampling
            != with_renderer_surface_state(surface, |state| {
                (
                    state.view(),
                    state.buffer_size(),
                    state.buffer_scale(),
                    state.buffer_transform(),
                    opaque_regions_signature(state.opaque_regions()),
                )
            });
        #[cfg(feature = "flutter")]
        let commit_kind = surface_commit_kind(
            first_buffer,
            buffer_attached,
            buffer_removed,
            sampling_changed,
        );
        #[cfg(feature = "flutter")]
        let visual_update = commit_kind.is_some();
        #[cfg(feature = "flutter")]
        record_surface_commit_audit(
            frontend,
            surface,
            SurfaceCommitAuditSample {
                visual_update,
                has_damage,
                has_frame_callbacks,
                buffer_attached,
                buffer_removed,
                first_buffer,
                sampling_changed,
            },
        );
        #[cfg(feature = "flutter")]
        if let Some(kind) = commit_kind {
            frontend.queue_surface_commit(surface, kind);
        }
        #[cfg(feature = "flutter")]
        let mut published_surface_commits = None;
        #[cfg(feature = "flutter")]
        let active_cursor_root = (!synchronized)
            .then(|| frontend.active_cursor_root_for(surface))
            .flatten();
        #[cfg(feature = "flutter")]
        let cursor_callback_root = (!synchronized)
            .then(|| frontend.cursor_root_for(surface))
            .flatten();
        if !synchronized {
            #[cfg(feature = "flutter")]
            {
                // A callback-only Chromium commit must not create a new
                // external-texture generation. Pending synchronized child
                // damage is still published by this parent transaction.
                if let Some(cursor_root) = active_cursor_root.as_ref() {
                    let commits = frontend.publish_cursor_surface_commits(cursor_root);
                    frontend.record_cursor_surface_commits(cursor_root, commits);
                } else {
                    published_surface_commits = Some(frontend.publish_surface_commits(surface));
                }
            }
            let mut root = surface.clone();
            while let Some(parent) = get_parent(&root) {
                root = parent;
            }
            let window = frontend.window_for_root_surface(&root);
            if let Some(window) = window {
                #[cfg(feature = "flutter")]
                let previous_content_geometry = window.geometry();
                #[cfg(feature = "flutter")]
                let previous_target_geometry = frontend.window_geometry_target(&window);
                // app_id, parent, constraints and explicit state requests are
                // final for the XDG initial commit. Resolve placement here,
                // immediately before the first configure. Normal toplevels
                // retain only Denial's location intent and receive a zero-size
                // configure so the client can reveal its own dimensions.
                frontend.reconcile_window_layout(&window);
                let restored = frontend.restore_xdg_window_placement(&window);
                #[cfg(feature = "flutter")]
                if let Some((restored, target)) = restored {
                    restored_window_state = Some((window.clone(), restored, target));
                }
                #[cfg(not(feature = "flutter"))]
                let _ = restored;
                window.on_commit();
                frontend.reconcile_committed_window_geometry(&window);
                #[cfg(feature = "flutter")]
                let client_sized_target = frontend.reconcile_client_sized_window_placement(&window);
                #[cfg(feature = "flutter")]
                {
                    let current_target_geometry = frontend.window_geometry_target(&window);
                    if previous_target_geometry != current_target_geometry {
                        frontend.update_window_output_membership(&window);
                    }
                    committed_window_metadata_changed |= previous_content_geometry
                        != window.geometry()
                        || previous_target_geometry != current_target_geometry;
                }
                #[cfg(feature = "flutter")]
                if let Some(target) = client_sized_target {
                    client_sized_window_state = Some((window, target));
                }
                #[cfg(not(feature = "flutter"))]
                let _ = frontend.reconcile_client_sized_window_placement(&window);
            }
        }
        #[cfg(feature = "flutter")]
        let owning_toplevel = frontend.owning_toplevel_surface(surface);
        #[cfg(feature = "flutter")]
        let input_method_popup = frontend.input_method.popup_root_surface(surface);
        #[cfg(feature = "flutter")]
        if has_frame_callbacks {
            // A client cursor's scheduling contract is independent of
            // whether policy currently lets Flutter display its artwork.
            // Xwayland retains one cursor upload until this callback arrives
            // and otherwise cannot submit a later non-null X cursor.
            if let Some(cursor_root) = cursor_callback_root.as_ref() {
                frontend
                    .pending_cursor_frame_callback_roots
                    .insert(cursor_root.id());
            } else if let Some(popup_root) = input_method_popup.as_ref() {
                frontend
                    .pending_input_method_frame_callbacks
                    .insert(popup_root.id());
            } else {
                let owner = owning_toplevel
                    .as_ref()
                    .cloned()
                    .unwrap_or_else(|| frontend.toplevel_candidate_surface(surface));
                frontend.pending_frame_callback_windows.insert(owner.id());
            }
        }
        #[cfg(feature = "flutter")]
        let has_published_owner = owning_toplevel.is_some() || input_method_popup.is_some();
        #[cfg(feature = "flutter")]
        let published_visual_update = published_surface_commits.as_ref().is_some_and(|published| {
            published.metadata_changed || !published.buffer_surface_ids.is_empty()
        });
        #[cfg(feature = "flutter")]
        let affects_published_scene = commit_affects_published_scene(
            synchronized,
            has_published_owner,
            published_visual_update,
        );
        handle_xdg_commit(&mut frontend.popups, &frontend.space, surface);
        #[cfg(feature = "flutter")]
        if let Some((window, restored, target)) = restored_window_state {
            queue_restored_window_state(self, &window, restored, target);
        }
        #[cfg(feature = "flutter")]
        if let Some((window, target)) = client_sized_window_state {
            queue_client_window_placement_for_monitor(
                self,
                &window,
                target,
                target,
                WindowPlacementPhase::End,
                WindowPlacementChange::Resize,
            );
        }
        #[cfg(feature = "flutter")]
        if let Some(published) = published_surface_commits {
            if committed_window_metadata_changed {
                self.scene_sync.mark_dirty();
            } else if affects_published_scene {
                if published.metadata_changed {
                    // A full publication captures every source in the tree,
                    // so buffer-only entries in the same transaction need no
                    // separate acknowledgement.
                    self.scene_sync.mark_dirty();
                } else {
                    self.scene_sync
                        .mark_surfaces_dirty(published.buffer_surface_ids.iter().copied());
                }
            }
            self.wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .recycle_published_surface_ids(published.buffer_surface_ids);
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

impl smithay::wayland::fractional_scale::FractionalScaleHandler for RuntimeState {
    fn new_fractional_scale(&mut self, surface: WlSurface) {
        self.wayland
            .as_ref()
            .expect("missing Wayland frontend")
            .update_surface_fractional_scale(&surface);
    }
}

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
        frontend.update_tablet_cursor_image(image);
        #[cfg(not(feature = "flutter"))]
        {
            frontend.cursor_status = image;
        }
    }

    fn led_state_changed(
        &mut self,
        _seat: &Seat<Self>,
        led_state: smithay::input::keyboard::LedState,
    ) {
        let leds = led_state.into();
        for device in self.keyboard_devices.values_mut() {
            device.led_update(leds);
        }
    }

    fn focus_changed(&mut self, seat: &Seat<Self>, focused: Option<&KeyboardFocusTarget>) {
        #[cfg(feature = "flutter")]
        if focused.is_some() {
            self.wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .clear_local_flutter_focus();
        }
        let display_handle = self
            .wayland
            .as_ref()
            .expect("missing Wayland frontend")
            .display_handle
            .clone();
        let client = focused
            .and_then(WaylandFocus::wl_surface)
            .and_then(|surface| display_handle.get_client(surface.id()).ok());
        let focused_surface = focused
            .and_then(WaylandFocus::wl_surface)
            .map(|surface| surface.into_owned());
        let focus_kind = match focused {
            Some(KeyboardFocusTarget::Wayland(_)) => super::SeatFocusKind::Wayland,
            Some(KeyboardFocusTarget::X11(_)) => super::SeatFocusKind::Xwayland,
            None => super::SeatFocusKind::None,
        };
        let input_method_changed = {
            let frontend = self.wayland.as_mut().expect("missing Wayland frontend");
            frontend.text_input.set_keyboard_focus(
                &display_handle,
                focused_surface.clone(),
                focus_kind,
            );
            frontend.synchronize_input_method()
        };
        if input_method_changed {
            self.scene_sync.mark_dirty();
        }
        set_data_device_focus(&display_handle, seat, client);
        #[cfg(feature = "flutter")]
        {
            super::clipboard_io::release_deferred_clipboard_capture(self, focused_surface.as_ref());
        }
    }
}

// wp_cursor_shape_manager_v1 shares its dispatcher with tablet cursor shapes.
// Keep tablet-tool cursor requests on the same software-cursor path used by
// client pointer cursors so Flutter can publish them with the scene.
impl TabletSeatHandler for RuntimeState {
    fn tablet_tool_image(
        &mut self,
        _tool: &smithay::backend::input::TabletToolDescriptor,
        image: CursorImageStatus,
    ) {
        let frontend = self.wayland.as_mut().expect("missing Wayland frontend");
        #[cfg(feature = "flutter")]
        frontend.update_cursor_image(image);
        #[cfg(not(feature = "flutter"))]
        {
            frontend.cursor_status = image;
        }
    }
}

impl PointerConstraintsHandler for RuntimeState {
    fn new_constraint(&mut self, surface: &WlSurface, pointer: &PointerHandle<Self>) {
        #[cfg(feature = "flutter")]
        if self.secure_session_locked() {
            return;
        }
        #[cfg(feature = "flutter")]
        if self
            .wayland
            .as_ref()
            .is_some_and(|frontend| frontend.pointer_constraint_released_for_surface(surface))
        {
            return;
        }
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
    type SelectionUserData = super::super::clipboard::ClipboardSelection;

    fn new_selection(
        &mut self,
        selection: SelectionTarget,
        source: Option<SelectionSource>,
        _seat: Seat<Self>,
    ) {
        #[cfg(feature = "flutter")]
        if self.secure_session_locked() {
            return;
        }
        if selection != SelectionTarget::Clipboard {
            return;
        }
        let mime_types = source
            .as_ref()
            .map(SelectionSource::mime_types)
            .unwrap_or_default();
        clipboard_io::observe_selection(self, clipboard_io::CaptureOwner::Wayland, &mime_types);
        if let Some(xwm) = self
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .xwm
            .as_mut()
            && let Err(error) = xwm.new_selection(selection, source.map(|_| mime_types))
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
        user_data: &super::super::clipboard::ClipboardSelection,
    ) {
        #[cfg(feature = "flutter")]
        if self.secure_session_locked() {
            return;
        }
        if selection != SelectionTarget::Clipboard {
            return;
        }
        if let Some(item_id) = user_data.history_item_id() {
            clipboard_io::send_retained_selection(self, item_id, &mime_type, fd);
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
        #[cfg(feature = "flutter")]
        if self.secure_session_locked() {
            source.cancel();
            return;
        }
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
            let location = initial_toplevel_location(frontend.fallback_output_geometry(), offset);
            frontend.space.map_element(window.clone(), location, true);
            frontend.update_window_output_membership(&window);
            frontend.remember_layout_insertion_anchor(&window);
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
        let wl_surface = surface.wl_surface().clone();
        let _ = frontend.popups.track_popup(PopupKind::Xdg(surface));
        frontend.update_surface_fractional_scale(&wl_surface);
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
        if self
            .wayland
            .as_ref()
            .expect("missing Wayland frontend")
            .window_is_layout_managed(&window)
        {
            warn!("ignored XDG move for a layout-managed toplevel");
            return;
        }
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
        if self
            .wayland
            .as_ref()
            .expect("missing Wayland frontend")
            .window_is_layout_managed(&window)
        {
            warn!("ignored XDG resize for a layout-managed toplevel");
            return;
        }
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
        if reassert_exact_toplevel_geometry(self, &surface) {
            return;
        }
        let layout_managed = self
            .wayland
            .as_ref()
            .and_then(|frontend| frontend.window_for_root_surface(surface.wl_surface()))
            .is_some_and(|window| {
                self.wayland
                    .as_ref()
                    .expect("missing Wayland frontend")
                    .window_is_layout_managed(&window)
            });
        if layout_managed {
            self.wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .arrange_layout_windows();
            self.scene_sync.mark_dirty();
            return;
        }
        self.wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .mark_client_geometry_state_request(surface.wl_surface());
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
        if reassert_exact_toplevel_geometry(self, &surface) {
            return;
        }
        self.wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .mark_client_geometry_state_request(surface.wl_surface());
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
        if reassert_exact_toplevel_geometry(self, &surface) {
            return;
        }
        self.wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .mark_client_geometry_state_request(surface.wl_surface());
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
        if reassert_exact_toplevel_geometry(self, &surface) {
            return;
        }
        self.wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .mark_client_geometry_state_request(surface.wl_surface());
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
            let window = self
                .wayland
                .as_ref()
                .and_then(|frontend| frontend.window_for_root_surface(_surface.wl_surface()));
            self.wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .set_surface_minimized(_surface.wl_surface().id(), true);
            if set_toplevel_suspended(&_surface, true) {
                _surface.send_pending_configure();
            }
            if let Some(window) = window.as_ref() {
                self.wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .remove_window_from_layout(window, false);
                release_window_focus(self, window);
            }
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
        let window = self
            .wayland
            .as_ref()
            .expect("missing Wayland frontend")
            .space
            .elements()
            .find(|window| {
                window
                    .toplevel()
                    .is_some_and(|toplevel| toplevel.wl_surface() == surface.wl_surface())
            })
            .cloned();
        let was_focused = window
            .as_ref()
            .is_some_and(|window| release_window_focus(self, window));
        // Native Wayland clients choose their normal size and may create
        // independent auxiliary toplevels with the same app_id. Destruction
        // is therefore not evidence of user placement intent; interactive
        // shell move/resize/state actions persist at their own end boundary.
        // Cleanup remains unconditional because role destruction can arrive
        // after Space has already lost the window.
        {
            let frontend = self.wayland.as_mut().expect("missing Wayland frontend");
            if let Some(window) = window.as_ref() {
                frontend.remove_window_from_layout(window, true);
            }
            frontend.remove_surface_state(surface.wl_surface(), false);
            if let Some(window) = window {
                frontend.space.unmap_elem(&window);
            }
        }
        if was_focused {
            activate_topmost_window(self);
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

impl XdgActivationHandler for RuntimeState {
    fn activation_state(&mut self) -> &mut XdgActivationState {
        &mut self
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .xdg_activation_state
    }

    fn token_created(&mut self, _token: XdgActivationToken, data: XdgActivationTokenData) -> bool {
        if !self.client_activation_permitted() {
            return false;
        }
        let Some((serial, seat_resource)) = data.serial else {
            // Tokens minted by clients must prove recent user interaction.
            // Shell launch tokens bypass this callback and are trusted by
            // construction through create_external_token.
            return false;
        };
        let frontend = self.wayland.as_ref().expect("missing Wayland frontend");
        Seat::from_resource(&seat_resource) == Some(frontend.seat.clone())
            && frontend
                .seat
                .get_keyboard()
                .and_then(|keyboard| keyboard.last_enter())
                .is_some_and(|last_enter| serial.is_no_older_than(&last_enter))
    }

    fn request_activation(
        &mut self,
        token: XdgActivationToken,
        data: XdgActivationTokenData,
        surface: WlSurface,
    ) {
        // Activation tokens are capabilities. Consume every recognized token
        // exactly once, including rejected or stale requests.
        self.activation_state().remove_token(&token);
        if !self.client_activation_permitted()
            || data.timestamp.elapsed() > XDG_ACTIVATION_TOKEN_LIFETIME
        {
            debug!(app_id = ?data.app_id, "rejected stale or locked XDG activation request");
            return;
        }

        let mut root = surface;
        while let Some(parent) = get_parent(&root) {
            root = parent;
        }
        let window = self
            .wayland
            .as_ref()
            .and_then(|frontend| frontend.window_for_root_surface(&root));
        let Some(window) = window else {
            debug!(app_id = ?data.app_id, "ignored XDG activation for an unmanaged surface");
            return;
        };
        if activate_window(self, &window, SERIAL_COUNTER.next_serial()) {
            debug!(app_id = ?data.app_id, "honored XDG activation request");
        }
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
