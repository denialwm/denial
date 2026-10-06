use smithay::desktop::Window;
use smithay::output::Output;
use smithay::reexports::wayland_server::Resource;
use smithay::reexports::wayland_server::protocol::wl_output;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::utils::{Logical, Rectangle, Size};
#[cfg(feature = "flutter")]
use smithay::utils::{Point, SERIAL_COUNTER};
#[cfg(feature = "flutter")]
use smithay::wayland::seat::WaylandFocus;
use tracing::warn;

#[cfg(feature = "flutter")]
use super::super::PendingWindowEvent;
use super::super::RuntimeState;
use super::super::window_grab::constrain_dimension;
#[cfg(feature = "flutter")]
use super::super::window_layout::LayoutDirection;
#[cfg(feature = "flutter")]
use super::super::window_placement_store::RestoredWindowPlacement;
#[cfg(feature = "flutter")]
use super::super::wire::{
    WindowAction, WindowCommand, WindowGeometry, WindowPlacementChange, WindowPlacementPhase,
};
use super::WindowGeometryAuthority;
#[cfg(feature = "flutter")]
use super::clamp_window_geometry;
#[cfg(feature = "flutter")]
use super::focus::clear_keyboard_focus;
use super::focus::request_keyboard_focus;
use super::managed_window::{ClientStateRequestKind, ClientWindowState, ManagedWindow};
#[cfg(feature = "flutter")]
use super::window_presentation::{
    ShellFixedMaximizeTransition, ShellFullscreenExit, ShellWindowPresentation,
};
#[cfg(feature = "flutter")]
use super::{WaylandFrontend, WindowId};

fn bound_geometry_size(mut geometry: Rectangle<i32, Logical>) -> Rectangle<i32, Logical> {
    geometry.size = Size::from((
        constrain_dimension(geometry.size.w, 1, 0),
        constrain_dimension(geometry.size.h, 1, 0),
    ));
    geometry
}

#[cfg(feature = "flutter")]
fn configured_window_size(
    requested: Size<i32, Logical>,
    minimum: Size<i32, Logical>,
    maximum: Size<i32, Logical>,
    compositor_owned: bool,
) -> Size<i32, Logical> {
    if compositor_owned {
        requested
    } else {
        Size::from((
            constrain_dimension(requested.w, minimum.w, maximum.w),
            constrain_dimension(requested.h, minimum.h, maximum.h),
        ))
    }
}

// Must match DesktopMetrics.frameBorder in the embedded shell.
pub(super) const SHELL_FRAME_BORDER: i32 = 1;

pub(super) fn shell_draws_server_frame(window: &Window) -> bool {
    ManagedWindow::new(window).is_some_and(|window| window.facts().server_side_decorated)
}

pub(super) fn shell_content_geometry(
    mut frame: Rectangle<i32, Logical>,
    server_side_decorated: bool,
) -> Rectangle<i32, Logical> {
    if server_side_decorated
        && frame.size.w > SHELL_FRAME_BORDER * 2
        && frame.size.h > SHELL_FRAME_BORDER * 2
    {
        frame.loc.x += SHELL_FRAME_BORDER;
        frame.loc.y += SHELL_FRAME_BORDER;
        frame.size.w -= SHELL_FRAME_BORDER * 2;
        frame.size.h -= SHELL_FRAME_BORDER * 2;
    }
    frame
}

pub(super) fn maximized_shell_content_geometry(
    frame: Rectangle<i32, Logical>,
    server_side_decorated: bool,
    managed_layout: bool,
) -> Rectangle<i32, Logical> {
    shell_content_geometry(frame, server_side_decorated && managed_layout)
}

/// Drop client-protocol fullscreen/maximize state before a shell-owned
/// configure or SUPER pointer interaction.
///
/// Denial's Flutter fullscreen is deliberately independent from XDG/EWMH
/// state. Keeping those states coupled makes a game's focus-loss request undo
/// SUPER+F and causes normal shell resize commands to be rejected.
#[cfg(feature = "flutter")]
pub(super) fn clear_client_geometry_constraints(window: &Window) -> bool {
    ManagedWindow::new(window).is_some_and(|window| window.clear_geometry_constraints())
}

/// Applies shell-owned geometry through the one managed-window adapter.
///
/// Policy callers never branch on XDG versus Xwayland. The only backend
/// distinction is the terminal protocol handshake: XDG needs a configure
/// serial, while `set_window_geometry_target` emits the X11 configure.
#[cfg(feature = "flutter")]
fn configure_shell_owned_geometry(
    state: &mut RuntimeState,
    window: &Window,
    target: Rectangle<i32, Logical>,
    authority: WindowGeometryAuthority,
) {
    clear_client_geometry_constraints(window);
    if let Some(window) = ManagedWindow::new(window) {
        window.prepare_shell_geometry(target);
    }
    state
        .wayland
        .as_mut()
        .expect("missing Wayland frontend")
        .set_window_geometry_target_with_authority(window, target, authority);
}

#[cfg(feature = "flutter")]
fn shell_maximized_geometry(
    frontend: &WaylandFrontend,
    window: &Window,
    from: Rectangle<i32, Logical>,
) -> Option<Rectangle<i32, Logical>> {
    let output = frontend.output_for_geometry(from)?.output.clone();
    let output_geometry = frontend.space.output_geometry(&output)?;
    Some(maximized_shell_content_geometry(
        frontend.maximize_work_area(Some(&output), output_geometry),
        shell_draws_server_frame(window),
        frontend.window_layout_manages_geometry(),
    ))
}

#[cfg(feature = "flutter")]
fn preserves_client_fullscreen_geometry(
    client_fullscreen: bool,
    current_target: Rectangle<i32, Logical>,
    requested_target: Rectangle<i32, Logical>,
) -> bool {
    client_fullscreen && current_target == requested_target
}

#[cfg(feature = "flutter")]
fn authoritative_geometry_rejects_configure(
    geometry_owned: bool,
    current_target: Rectangle<i32, Logical>,
    requested_target: Rectangle<i32, Logical>,
) -> bool {
    geometry_owned && current_target != requested_target
}

#[cfg(feature = "flutter")]
fn transfer_restore_geometry(
    mut restore: Rectangle<i32, Logical>,
    source_output: Rectangle<i32, Logical>,
    destination_output: Rectangle<i32, Logical>,
    destination_bounds: Rectangle<i32, Logical>,
) -> Rectangle<i32, Logical> {
    let translated_coordinate = |coordinate: i32, source: i32, destination: i32| {
        (i64::from(coordinate) - i64::from(source) + i64::from(destination))
            .clamp(i64::from(i32::MIN), i64::from(i32::MAX)) as i32
    };
    restore.loc = Point::from((
        translated_coordinate(restore.loc.x, source_output.loc.x, destination_output.loc.x),
        translated_coordinate(restore.loc.y, source_output.loc.y, destination_output.loc.y),
    ));
    clamp_window_geometry(restore, destination_bounds)
}

/// Activates one managed client window through the single native focus path.
///
/// The Flutter scene owns Denial's visible z-order while Smithay and Xwayland
/// retain independent focus/stacking state. Keeping all three updates in one
/// transaction prevents a client from becoming keyboard-active underneath a
/// different visible window.
pub(super) fn activate_window(
    state: &mut RuntimeState,
    window: &Window,
    serial: smithay::utils::Serial,
) -> bool {
    #[cfg(feature = "flutter")]
    {
        let Some((window_id, minimized)) = state.wayland.as_ref().and_then(|frontend| {
            let root = frontend.window_root_surface(window)?;
            Some((
                frontend.surface_id(&root)?,
                frontend.surface_is_minimized(&root.id()),
            ))
        }) else {
            return false;
        };
        if minimized {
            state
                .wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .restore_window_workspace(window_id);
        } else if !state
            .wayland
            .as_ref()
            .expect("missing Wayland frontend")
            .window_is_on_active_workspace(window_id)
        {
            return false;
        }
    }
    let (keyboard, keyboard_focus) = {
        let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
        let keyboard = frontend.seat.get_keyboard().expect("seat has no keyboard");
        let Some(keyboard_focus) = frontend.keyboard_focus_for_window(window) else {
            return false;
        };
        (keyboard, keyboard_focus)
    };

    #[cfg(feature = "flutter")]
    let window_id = state.wayland.as_ref().and_then(|frontend| {
        frontend
            .window_root_surface(window)
            .and_then(|surface| frontend.surface_id(&surface))
    });

    #[cfg(feature = "flutter")]
    let resumed;
    {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        #[cfg(feature = "flutter")]
        {
            resumed = frontend
                .window_root_surface(window)
                .is_some_and(|surface| frontend.set_surface_minimized(surface.id(), false));
            if resumed && let Some(managed) = ManagedWindow::new(window) {
                managed.prepare_minimized(false);
            }
            if resumed {
                frontend.reconcile_window_layout(window);
            }
        }
        #[cfg(not(feature = "flutter"))]
        let resumed = false;

        frontend.raise_window(window, true);
        for candidate in frontend.space.elements() {
            let changed = candidate.set_activated(candidate == window);
            if let Some(managed) = ManagedWindow::new(candidate) {
                managed.prepare_activation(changed || (candidate == window && resumed));
            }
        }
    }

    request_keyboard_focus(state, &keyboard, Some(keyboard_focus), serial);
    #[cfg(feature = "flutter")]
    if let Some(window_id) = window_id {
        state
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .record_workspace_focus(window_id);
        state
            .pending_window_events
            .push_activation(window_id, resumed);
    }
    state.scene_sync.mark_dirty();
    true
}

/// Gives focus to the topmost remaining managed client window.
///
/// Window destruction removes the current keyboard target independently from
/// Flutter's visible stack. Re-enter the ordinary activation path so the
/// replacement receives protocol keyboard focus as well as shell activation.
#[cfg(feature = "flutter")]
pub(super) fn activate_topmost_window(state: &mut RuntimeState) -> bool {
    let next = {
        let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
        frontend
            .space
            .elements()
            .rfind(|candidate| {
                ManagedWindow::new(candidate)
                    .is_some_and(|managed| !managed.facts().override_redirect)
                    && frontend.window_root_surface(candidate).is_some_and(|root| {
                        root.is_alive()
                            && !frontend.surface_is_minimized(&root.id())
                            && frontend
                                .surface_id(&root)
                                .is_some_and(|id| frontend.window_is_on_active_workspace(id))
                    })
            })
            .cloned()
    };
    next.is_some_and(|window| activate_window(state, &window, SERIAL_COUNTER.next_serial()))
}

/// Gives focus to a usable window when a workspace has no remembered target.
///
/// Native windows retain a compositor-owned stacking order, so try them from
/// topmost to bottommost. Local Flutter windows do not currently have an
/// equivalent native stack; they remain a last-resort target for workspaces
/// that contain no activatable client window.
#[cfg(feature = "flutter")]
fn activate_workspace_fallback(
    state: &mut RuntimeState,
    monitor_id: i64,
    workspace_id: u8,
) -> bool {
    let Some(output_id) = u64::try_from(monitor_id).ok() else {
        return false;
    };
    let (client_windows, local_window_ids) = {
        let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
        let belongs_to_workspace = |window_id| {
            frontend
                .workspace_location(window_id)
                .is_some_and(|location| {
                    location.output.0 == output_id && location.workspace == workspace_id
                })
        };
        let client_windows = frontend
            .space
            .elements()
            .rev()
            .filter(|candidate| {
                ManagedWindow::new(candidate)
                    .is_some_and(|managed| !managed.facts().override_redirect)
                    && frontend.window_root_surface(candidate).is_some_and(|root| {
                        root.is_alive()
                            && !frontend.surface_is_minimized(&root.id())
                            && frontend
                                .surface_id(&root)
                                .is_some_and(&belongs_to_workspace)
                    })
            })
            .cloned()
            .collect::<Vec<_>>();
        let local_window_ids = frontend
            .local_windows
            .iter()
            .filter(|window| {
                !frontend.window_is_minimized(window.id) && belongs_to_workspace(window.id)
            })
            .map(|window| window.id)
            .collect::<Vec<_>>();
        (client_windows, local_window_ids)
    };

    for window in client_windows {
        if activate_window(state, &window, SERIAL_COUNTER.next_serial()) {
            return true;
        }
    }
    local_window_ids
        .into_iter()
        .any(|window_id| activate_local_flutter_window(state, window_id))
}

#[cfg(feature = "flutter")]
fn apply_window_command(state: &mut RuntimeState, command: WindowCommand) {
    match command {
        WindowCommand::CreateLocal {
            app_id,
            title,
            geometry,
        } => create_local_window(state, app_id, title, geometry),
        WindowCommand::SwitchWorkspace {
            monitor_id,
            workspace_id,
        } => {
            switch_monitor_workspace(state, monitor_id, workspace_id);
        }
        WindowCommand::MoveToWorkspace {
            window_id,
            monitor_id,
            workspace_id,
            follow,
        } => {
            move_window_to_workspace(state, window_id, monitor_id, workspace_id, follow);
        }
        command => apply_targeted_window_command(state, command),
    }
}

#[cfg(feature = "flutter")]
fn create_local_window(
    state: &mut RuntimeState,
    app_id: String,
    title: String,
    geometry: WindowGeometry,
) {
    let created = state
        .wayland
        .as_mut()
        .expect("missing Wayland frontend")
        .create_local_flutter_window(app_id, title, geometry);
    match created {
        Ok(window_id) => {
            activate_local_flutter_window(state, window_id);
        }
        Err(error) => warn!(?error, "could not create local Flutter window"),
    }
}

#[cfg(feature = "flutter")]
fn apply_targeted_window_command(state: &mut RuntimeState, command: WindowCommand) {
    let window_id = command
        .window_id()
        .expect("non-global window command is missing its target");
    let is_local = state
        .wayland
        .as_ref()
        .is_some_and(|frontend| frontend.is_local_flutter_window(window_id));
    if is_local {
        apply_local_window_command(state, window_id, command);
        return;
    }

    let window = state
        .wayland
        .as_ref()
        .and_then(|frontend| frontend.window_for_id(window_id));
    let Some(window) = window else {
        warn!(window_id, ?command, "ignored command for stale window");
        return;
    };
    let root_surface = state
        .wayland
        .as_ref()
        .and_then(|frontend| frontend.window_root_surface(&window));
    let Some(root_surface) = root_surface else {
        warn!(
            window_id,
            "ignored command for a window without a root surface"
        );
        return;
    };
    apply_client_window_command(state, window_id, &window, &root_surface, command);
}

#[cfg(feature = "flutter")]
fn apply_local_window_command(state: &mut RuntimeState, window_id: u64, command: WindowCommand) {
    match command {
        WindowCommand::Close { .. } => {
            let removed = state
                .wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .remove_local_flutter_window(window_id);
            if removed {
                state.scene_sync.mark_dirty();
            }
        }
        WindowCommand::Focus { .. } => {
            activate_local_flutter_window(state, window_id);
        }
        WindowCommand::Configure { geometry, .. } => {
            let changed = state
                .wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .configure_local_flutter_window(window_id, geometry);
            if changed {
                state.scene_sync.mark_dirty();
            }
        }
        WindowCommand::CreateLocal { .. }
        | WindowCommand::SwitchWorkspace { .. }
        | WindowCommand::MoveToWorkspace { .. } => unreachable!(),
    }
}

#[cfg(feature = "flutter")]
fn apply_client_window_command(
    state: &mut RuntimeState,
    window_id: u64,
    window: &Window,
    root_surface: &WlSurface,
    command: WindowCommand,
) {
    match command {
        WindowCommand::Close { .. } => {
            close_window(window);
        }
        WindowCommand::Focus { .. } => {
            activate_window(state, window, SERIAL_COUNTER.next_serial());
        }
        WindowCommand::Configure {
            geometry,
            exact,
            layout_drop,
            ..
        } => configure_client_window(
            state,
            window_id,
            window,
            root_surface,
            geometry,
            exact,
            layout_drop,
        ),
        WindowCommand::CreateLocal { .. }
        | WindowCommand::SwitchWorkspace { .. }
        | WindowCommand::MoveToWorkspace { .. } => unreachable!(),
    }
}

#[cfg(feature = "flutter")]
fn apply_layout_drop_from_command(
    state: &mut RuntimeState,
    window: &Window,
    geometry: WindowGeometry,
) -> bool {
    let scene_origin = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .atlas_origin;
    let drop_location = Point::<i32, Logical>::from((
        clamped_scene_coordinate(geometry.x + geometry.width / 2.0 + scene_origin.x),
        clamped_scene_coordinate(geometry.y + geometry.height / 2.0 + scene_origin.y),
    ));
    let layout_geometry = {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        frontend
            .apply_layout_drop(window, drop_location, None)
            .then(|| frontend.window_geometry_target(window))
    };
    let Some(layout_geometry) = layout_geometry else {
        return false;
    };

    queue_transient_window_placement(
        state,
        window,
        layout_geometry,
        WindowPlacementPhase::End,
        WindowPlacementChange::Move,
    );
    state.scene_sync.mark_dirty();
    true
}

#[cfg(feature = "flutter")]
fn clamped_scene_coordinate(coordinate: f64) -> i32 {
    coordinate
        .round()
        .clamp(f64::from(i32::MIN), f64::from(i32::MAX)) as i32
}

#[cfg(feature = "flutter")]
fn transfer_shell_restore_between_outputs(
    frontend: &mut WaylandFrontend,
    root_surface: &WlSurface,
    current_target: Rectangle<i32, Logical>,
    requested_target: Rectangle<i32, Logical>,
) -> bool {
    let output_transfer = frontend
        .output_for_geometry(current_target)
        .and_then(|source| {
            frontend
                .output_for_geometry(requested_target)
                .map(|destination| {
                    (
                        source.id,
                        source.logical_geometry,
                        destination.id,
                        destination.logical_geometry,
                        destination.output.clone(),
                    )
                })
        })
        .filter(|(source_id, _, destination_id, _, _)| source_id != destination_id);
    let Some((_, source_geometry, _, destination_geometry, destination_output)) = output_transfer
    else {
        return false;
    };

    let destination_bounds =
        frontend.maximize_work_area(Some(&destination_output), destination_geometry);
    let Some(presentation) = frontend
        .window_record_for_surface_mut(&root_surface.id())
        .and_then(|record| record.shell_presentation.as_mut())
    else {
        return false;
    };
    presentation.map_geometries(|geometry| {
        transfer_restore_geometry(
            geometry,
            source_geometry,
            destination_geometry,
            destination_bounds,
        )
    });
    true
}

#[cfg(feature = "flutter")]
fn configure_client_window(
    state: &mut RuntimeState,
    window_id: u64,
    window: &Window,
    root_surface: &WlSurface,
    geometry: WindowGeometry,
    exact: bool,
    layout_drop: bool,
) {
    if layout_drop && apply_layout_drop_from_command(state, window, geometry) {
        return;
    }

    let mobile_window = state
        .wayland
        .as_ref()
        .is_some_and(|frontend| frontend.mobile_window_geometry(window).is_some());
    if mobile_window {
        state
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .configure_mobile_window(window);
        return;
    }

    let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
    let geometry_owned =
        frontend.window_is_layout_managed(window) || frontend.window_geometry_authoritative(window);
    let scene_origin = frontend.atlas_origin;
    let Some(managed) = ManagedWindow::new(window) else {
        return;
    };
    let facts = managed.facts();
    if !exact && facts.client_state.resizing {
        warn!(
            window_id,
            "ignored Flutter configure during an active client resize"
        );
        return;
    }
    if facts.override_redirect {
        warn!(
            window_id,
            "ignored Flutter configure for an unmanaged window"
        );
        return;
    }

    let requested_size = Size::<i32, Logical>::from((
        geometry.width.round() as i32,
        geometry.height.round() as i32,
    ));
    // Fullscreen owns the output rectangle. Games commonly make their current
    // maximized resolution both the X11 minimum and maximum; honoring those
    // hints here would leave the native surface maximized while Flutter
    // stretches it fullscreen.
    let size = configured_window_size(
        requested_size,
        facts.minimum_size,
        facts.maximum_size,
        exact || geometry_owned,
    );
    let target_location = Point::<i32, Logical>::from((
        clamped_scene_coordinate(geometry.x + scene_origin.x),
        clamped_scene_coordinate(geometry.y + scene_origin.y),
    ));
    let target = Rectangle::new(target_location, size);
    if !exact
        && authoritative_geometry_rejects_configure(
            geometry_owned,
            frontend.window_geometry_target(window),
            target,
        )
    {
        // Flutter mirrors compositor geometry for rendering and also emits
        // interactive stacking placement. A managed layout remains the sole
        // geometry authority, except while shell fullscreen temporarily
        // overlays its retained tile.
        return;
    }

    let (preserve_client_fullscreen, transferred_shell_restore) = {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        let current_target = frontend.window_geometry_target(window);
        let preserve_client_fullscreen = !exact
            && preserves_client_fullscreen_geometry(
                facts.client_state.fullscreen,
                current_target,
                target,
            );
        let transferred_shell_restore =
            transfer_shell_restore_between_outputs(frontend, root_surface, current_target, target);
        (preserve_client_fullscreen, transferred_shell_restore)
    };
    if !preserve_client_fullscreen {
        // A different rectangle is a shell-authored move/resize, so the client
        // protocol must stop constraining geometry. An identical fullscreen
        // rectangle is only Flutter echoing the XDG/EWMH transition Rust
        // already granted; clearing it would make browsers require a second
        // click.
        clear_client_geometry_constraints(window);
        state
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .clear_restore_geometry(&root_surface.id());
    }

    managed.prepare_shell_geometry(target);
    let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
    frontend.set_window_geometry_target_policy(window, target, exact);
    if transferred_shell_restore {
        frontend.remember_window_placement(window);
    }
    if layout_drop {
        queue_window_placement(
            state,
            window,
            target,
            WindowPlacementPhase::End,
            WindowPlacementChange::Move,
        );
    }
    state.scene_sync.mark_dirty();
}

#[cfg(feature = "flutter")]
pub(in super::super) fn apply_window_commands(
    state: &mut RuntimeState,
    commands: impl IntoIterator<Item = WindowCommand>,
) -> Result<(), std::io::Error> {
    let mut had_commands = false;
    for command in commands {
        had_commands = true;
        apply_window_command(state, command);
    }
    // Shell commands arrive independently of client input and presentation.
    // In particular, a close sent after its preview leaves the screen must
    // reach the client even when no further client or output frame is due.
    if had_commands && let Some(frontend) = state.wayland.as_mut() {
        frontend.display_handle.flush_clients()?;
    }
    Ok(())
}

#[cfg(feature = "flutter")]
pub(super) fn switch_monitor_workspace(
    state: &mut RuntimeState,
    monitor_id: i64,
    workspace_id: u8,
) -> bool {
    let changed = state
        .wayland
        .as_mut()
        .expect("missing Wayland frontend")
        .switch_workspace(monitor_id, workspace_id);
    if !changed {
        return false;
    }

    let focused = focused_window(state);
    if let Some(window) = focused {
        let remains_visible = state.wayland.as_ref().is_some_and(|frontend| {
            frontend
                .window_root_surface(&window)
                .and_then(|root| frontend.surface_id(&root))
                .is_some_and(|window_id| frontend.window_is_on_active_workspace(window_id))
        });
        if !remains_visible {
            release_window_focus(state, &window);
        }
    }
    if let Some(local) = focused_local_window(state) {
        let remains_visible = state
            .wayland
            .as_ref()
            .is_some_and(|frontend| frontend.window_is_on_active_workspace(local));
        if !remains_visible {
            state
                .wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .clear_local_flutter_focus();
        }
    }
    state.queue_workspace_action(monitor_id, workspace_id);
    let remembered = state
        .wayland
        .as_ref()
        .and_then(|frontend| frontend.remembered_workspace_focus(monitor_id, workspace_id));
    let restored_focus = remembered.is_some_and(|window_id| {
        if state
            .wayland
            .as_ref()
            .is_some_and(|frontend| frontend.is_local_flutter_window(window_id))
        {
            activate_local_flutter_window(state, window_id)
        } else if let Some(window) = state
            .wayland
            .as_ref()
            .and_then(|frontend| frontend.window_for_id(window_id))
        {
            activate_window(state, &window, SERIAL_COUNTER.next_serial())
        } else {
            false
        }
    });
    if !restored_focus {
        activate_workspace_fallback(state, monitor_id, workspace_id);
    }
    state.scene_sync.mark_dirty();
    true
}

#[cfg(feature = "flutter")]
pub(super) fn move_window_to_workspace(
    state: &mut RuntimeState,
    window_id: u64,
    monitor_id: Option<i64>,
    workspace_id: u8,
    follow: bool,
) -> bool {
    let requested_output = monitor_id
        .and_then(|monitor_id| u64::try_from(monitor_id).ok())
        .map(denial_core::topology::OutputId);
    let location = {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        if frontend.window_is_minimized(window_id) {
            frontend.set_local_flutter_window_minimized(window_id, false);
        } else if let Some(window) = frontend.window_for_id(window_id)
            && let Some(root) = frontend.window_root_surface(&window)
            && frontend.surface_is_minimized(&root.id())
        {
            frontend.set_surface_minimized(root.id(), false);
        }
        let location = frontend.move_window_to_workspace(window_id, requested_output, workspace_id);
        if location.is_some() {
            if let Some(destination) = requested_output {
                move_window_geometry_to_output(frontend, window_id, destination);
            }
            frontend.rebuild_window_layout();
        }
        location
    };
    let Some(location) = location else {
        return false;
    };
    let monitor_id = match i64::try_from(location.output.0) {
        Ok(monitor_id) => monitor_id,
        Err(_) => return false,
    };
    if follow {
        switch_monitor_workspace(state, monitor_id, workspace_id);
        if state
            .wayland
            .as_ref()
            .is_some_and(|frontend| frontend.is_local_flutter_window(window_id))
        {
            activate_local_flutter_window(state, window_id);
        } else if let Some(window) = state
            .wayland
            .as_ref()
            .and_then(|frontend| frontend.window_for_id(window_id))
        {
            activate_window(state, &window, SERIAL_COUNTER.next_serial());
        }
    } else {
        if focused_local_window(state) == Some(window_id) {
            state
                .wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .clear_local_flutter_focus();
        }
        if let Some(window) = state
            .wayland
            .as_ref()
            .and_then(|frontend| frontend.window_for_id(window_id))
        {
            release_window_focus(state, &window);
        }
    }
    state.scene_sync.mark_dirty();
    true
}

#[cfg(feature = "flutter")]
fn move_window_geometry_to_output(
    frontend: &mut super::WaylandFrontend,
    window_id: u64,
    destination: denial_core::topology::OutputId,
) {
    let Some(destination_geometry) = frontend
        .outputs
        .iter()
        .find(|output| output.id == destination)
        .map(|output| output.logical_geometry)
    else {
        return;
    };
    if frontend.is_local_flutter_window(window_id) {
        let Some(current) = frontend.local_flutter_window_geometry(window_id) else {
            return;
        };
        let current_rect = Rectangle::<i32, Logical>::new(
            Point::from((current.x.round() as i32, current.y.round() as i32)),
            Size::from((current.width.round() as i32, current.height.round() as i32)),
        );
        let Some(source_geometry) = frontend
            .output_for_geometry(current_rect)
            .map(|output| output.logical_geometry)
        else {
            return;
        };
        let target = transfer_restore_geometry(
            current_rect,
            source_geometry,
            destination_geometry,
            destination_geometry,
        );
        frontend.set_local_flutter_window_global_geometry(
            window_id,
            WindowGeometry {
                x: f64::from(target.loc.x),
                y: f64::from(target.loc.y),
                width: f64::from(target.size.w),
                height: f64::from(target.size.h),
            },
        );
        return;
    }
    let Some(window) = frontend.window_for_id(window_id) else {
        return;
    };
    let current = frontend.window_geometry_target(&window);
    let Some(source_geometry) = frontend
        .output_for_geometry(current)
        .map(|output| output.logical_geometry)
    else {
        return;
    };
    let target = transfer_restore_geometry(
        current,
        source_geometry,
        destination_geometry,
        destination_geometry,
    );
    frontend.set_window_geometry_target(&window, target);
}

#[cfg(feature = "flutter")]
pub(super) fn activate_local_flutter_window(state: &mut RuntimeState, window_id: u64) -> bool {
    let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
    if frontend.window_is_minimized(window_id) {
        frontend.set_local_flutter_window_minimized(window_id, false);
    } else if !frontend.window_is_on_active_workspace(window_id) {
        return false;
    }
    if !frontend.focus_local_flutter_window(window_id) {
        return false;
    }
    frontend.record_workspace_focus(window_id);
    let keyboard = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .seat
        .get_keyboard()
        .expect("seat has no keyboard");
    deactivate_client_windows(state.wayland.as_mut().expect("missing Wayland frontend"));
    clear_keyboard_focus(state, &keyboard, SERIAL_COUNTER.next_serial());
    state
        .pending_window_events
        .push(PendingWindowEvent::Activated(window_id));
    state.scene_sync.mark_dirty();
    true
}

#[cfg(feature = "flutter")]
fn deactivate_client_windows(frontend: &mut super::WaylandFrontend) {
    for candidate in frontend.space.elements() {
        let changed = candidate.set_activated(false);
        if let Some(managed) = ManagedWindow::new(candidate) {
            managed.prepare_activation(changed);
        }
    }
}

#[cfg(feature = "flutter")]
pub(in super::super) fn queue_local_flutter_window_placement(
    state: &mut RuntimeState,
    window_id: u64,
    phase: WindowPlacementPhase,
    change: WindowPlacementChange,
) {
    let placement = state
        .wayland
        .as_ref()
        .and_then(|frontend| frontend.local_flutter_window_placement(window_id, phase, change));
    if let Some(placement) = placement {
        state
            .pending_window_events
            .push(PendingWindowEvent::Placement(placement));
    }
}

#[cfg(feature = "flutter")]
pub(in super::super) fn queue_window_placement(
    state: &mut RuntimeState,
    window: &Window,
    geometry: Rectangle<i32, Logical>,
    phase: WindowPlacementPhase,
    change: WindowPlacementChange,
) {
    queue_window_placement_for_monitor(state, window, geometry, geometry, phase, change);
}

/// Publishes compositor-owned presentation geometry without treating it as a
/// stacking placement to restore in a future session. Layout drags use this
/// for their translated preview and their authoritative destination tile.
#[cfg(feature = "flutter")]
pub(in super::super) fn queue_transient_window_placement(
    state: &mut RuntimeState,
    window: &Window,
    geometry: Rectangle<i32, Logical>,
    phase: WindowPlacementPhase,
    change: WindowPlacementChange,
) {
    queue_window_placement_for_monitor_with_persistence(
        state, window, geometry, geometry, phase, change, false,
    );
}

/// Publishes transient geometry while retaining the layout row's physical
/// output even when a scrolling tile is mostly or completely off-screen.
#[cfg(feature = "flutter")]
pub(in super::super) fn queue_transient_window_placement_for_monitor(
    state: &mut RuntimeState,
    window: &Window,
    geometry: Rectangle<i32, Logical>,
    monitor_geometry: Rectangle<i32, Logical>,
    phase: WindowPlacementPhase,
    change: WindowPlacementChange,
) {
    queue_window_placement_for_monitor_with_persistence(
        state,
        window,
        geometry,
        monitor_geometry,
        phase,
        change,
        false,
    );
}

#[cfg(feature = "flutter")]
pub(super) fn queue_window_placement_for_monitor(
    state: &mut RuntimeState,
    window: &Window,
    geometry: Rectangle<i32, Logical>,
    monitor_geometry: Rectangle<i32, Logical>,
    phase: WindowPlacementPhase,
    change: WindowPlacementChange,
) {
    queue_window_placement_for_monitor_with_persistence(
        state,
        window,
        geometry,
        monitor_geometry,
        phase,
        change,
        true,
    );
}

#[cfg(feature = "flutter")]
pub(super) fn queue_client_window_placement_for_monitor(
    state: &mut RuntimeState,
    window: &Window,
    geometry: Rectangle<i32, Logical>,
    monitor_geometry: Rectangle<i32, Logical>,
    phase: WindowPlacementPhase,
    change: WindowPlacementChange,
) {
    queue_window_placement_for_monitor_with_persistence(
        state,
        window,
        geometry,
        monitor_geometry,
        phase,
        change,
        false,
    );
}

#[cfg(feature = "flutter")]
fn queue_window_placement_for_monitor_with_persistence(
    state: &mut RuntimeState,
    window: &Window,
    geometry: Rectangle<i32, Logical>,
    monitor_geometry: Rectangle<i32, Logical>,
    phase: WindowPlacementPhase,
    change: WindowPlacementChange,
    persist: bool,
) {
    let placement = {
        let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
        let Some(placement) =
            frontend.window_placement(window, geometry, monitor_geometry, phase, change)
        else {
            return;
        };
        placement
    };
    if persist && phase == WindowPlacementPhase::End {
        state
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .remember_window_geometry(window, geometry);
    }
    state
        .pending_window_events
        .push(PendingWindowEvent::Placement(placement));
}

#[cfg(feature = "flutter")]
pub(super) fn queue_restored_window_state(
    state: &mut RuntimeState,
    window: &Window,
    restored: RestoredWindowPlacement,
    target: Rectangle<i32, Logical>,
) {
    queue_window_placement_for_monitor(
        state,
        window,
        restored.geometry,
        target,
        WindowPlacementPhase::End,
        WindowPlacementChange::Resize,
    );
    if restored.state.maximized {
        queue_window_action_for_window(state, window, WindowAction::Maximize);
    }
    if restored.state.fullscreen {
        queue_window_action_for_window(state, window, WindowAction::Fullscreen);
    }
}

#[cfg(feature = "flutter")]
pub(super) fn queue_window_action_for_window(
    state: &mut RuntimeState,
    window: &Window,
    action: WindowAction,
) {
    let window_id = state.wayland.as_ref().and_then(|frontend| {
        frontend
            .window_root_surface(window)
            .and_then(|surface| frontend.surface_id(&surface))
    });
    if let Some(window_id) = window_id {
        state
            .pending_window_events
            .push(PendingWindowEvent::Action(window_id, action));
    }
}

#[cfg(feature = "flutter")]
fn focused_window(state: &RuntimeState) -> Option<Window> {
    let frontend = state.wayland.as_ref()?;
    let focused = frontend.seat.get_keyboard()?.current_focus()?;
    let surface = focused.wl_surface()?;
    let root = frontend.owning_toplevel_surface(&surface)?;
    frontend.window_for_root_surface(&root)
}

#[cfg(feature = "flutter")]
pub(super) fn focus_toplevel_in_direction(
    state: &mut RuntimeState,
    direction: LayoutDirection,
) -> bool {
    let Some(focused) = focused_window(state) else {
        return false;
    };
    let target = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .layout_neighbor_window(&focused, direction);
    target.is_some_and(|target| activate_window(state, &target, SERIAL_COUNTER.next_serial()))
}

#[cfg(feature = "flutter")]
pub(super) fn swap_toplevel_in_direction(
    state: &mut RuntimeState,
    direction: LayoutDirection,
) -> bool {
    let Some(focused) = focused_window(state) else {
        return false;
    };
    let Some(target) = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .layout_neighbor_window(&focused, direction)
    else {
        return false;
    };
    let changed = state
        .wayland
        .as_mut()
        .expect("missing Wayland frontend")
        .swap_layout_windows(&focused, &target);
    if !changed {
        return false;
    }
    for window in [&focused, &target] {
        let geometry = state
            .wayland
            .as_ref()
            .expect("missing Wayland frontend")
            .window_geometry_target(window);
        queue_transient_window_placement(
            state,
            window,
            geometry,
            WindowPlacementPhase::End,
            WindowPlacementChange::Move,
        );
    }
    state.scene_sync.mark_dirty();
    true
}

/// Drop keyboard/activation focus only when `window` currently owns it.
///
/// Minimized clients remain mapped so Flutter can keep presenting their live
/// desktop widget. That makes clearing focus an explicit operation rather than
/// a side effect of unmapping the Wayland surface.
#[cfg(feature = "flutter")]
pub(super) fn release_window_focus(state: &mut RuntimeState, window: &Window) -> bool {
    if focused_window(state).as_ref() != Some(window) {
        return false;
    }

    let keyboard = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .seat
        .get_keyboard()
        .expect("seat has no keyboard");
    let changed = window.set_activated(false);
    if let Some(managed) = ManagedWindow::new(window) {
        managed.prepare_activation(changed);
    }
    clear_keyboard_focus(state, &keyboard, SERIAL_COUNTER.next_serial());
    state.scene_sync.mark_dirty();
    true
}

#[cfg(feature = "flutter")]
fn focused_local_window(state: &RuntimeState) -> Option<u64> {
    state
        .wayland
        .as_ref()
        .and_then(|frontend| frontend.focused_local_flutter_window())
}

#[cfg(feature = "flutter")]
pub(super) fn focused_workspace_window(state: &RuntimeState) -> Option<(u64, i64)> {
    let frontend = state.wayland.as_ref()?;
    let window_id = frontend.focused_local_flutter_window().or_else(|| {
        let window = focused_window(state)?;
        let root = frontend.window_root_surface(&window)?;
        frontend.surface_id(&root)
    })?;
    let location = frontend.workspace_location(window_id)?;
    Some((window_id, i64::try_from(location.output.0).ok()?))
}

#[cfg(feature = "flutter")]
fn queue_local_window_action(state: &mut RuntimeState, window_id: u64, action: WindowAction) {
    state
        .pending_window_events
        .push(PendingWindowEvent::Action(window_id, action));
    state.scene_sync.mark_dirty();
}

#[cfg(feature = "flutter")]
pub(super) fn toggle_always_on_top_focused_toplevel(state: &mut RuntimeState) -> bool {
    let local_window_id = focused_local_window(state);
    let client_window = local_window_id
        .is_none()
        .then(|| focused_window(state))
        .flatten();
    let window_id = local_window_id.or_else(|| {
        let frontend = state.wayland.as_ref()?;
        let root = frontend.window_root_surface(client_window.as_ref()?)?;
        frontend.surface_id(&root)
    });
    let Some(window_id) = window_id else {
        return false;
    };

    let pinned = {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        let record = frontend.window_registry.ensure(WindowId::new(window_id));
        record.pinned = !record.pinned;
        record.pinned
    };
    if let Some(window) = client_window {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        // Pinned windows are floating overlays in every layout. Reconcile
        // immediately so pinning collapses the vacated tile and restores the
        // saved stacking rectangle, while unpinning enrolls the current
        // floating rectangle as the next restore geometry.
        frontend.reconcile_window_layout(&window);
        if pinned {
            frontend.raise_window(&window, true);
        }
    }
    state.scene_sync.mark_dirty();
    true
}

#[cfg(feature = "flutter")]
pub(super) fn minimize_focused_toplevel(state: &mut RuntimeState) -> bool {
    if let Some(window_id) = focused_local_window(state) {
        return minimize_toplevel_by_id(state, window_id);
    }
    let Some(window) = focused_window(state) else {
        return false;
    };
    minimize_window(state, &window)
}

#[cfg(feature = "flutter")]
pub(super) fn minimize_all_toplevels(state: &mut RuntimeState) -> bool {
    let (local_window_ids, client_windows) = {
        let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
        let local_window_ids = frontend
            .local_windows
            .iter()
            .filter(|window| frontend.window_is_on_active_workspace(window.id))
            .map(|window| window.id)
            .collect::<Vec<_>>();
        let client_windows = frontend
            .space
            .elements()
            .filter(|window| {
                ManagedWindow::new(window).is_some_and(|managed| !managed.facts().override_redirect)
                    && frontend.window_root_surface(window).is_some_and(|root| {
                        root.is_alive()
                            && !frontend.surface_is_minimized(&root.id())
                            && frontend
                                .surface_id(&root)
                                .is_some_and(|id| frontend.window_is_on_active_workspace(id))
                    })
            })
            .cloned()
            .collect::<Vec<_>>();
        (local_window_ids, client_windows)
    };

    let mut minimized = false;
    for window_id in local_window_ids {
        minimized |= minimize_toplevel_by_id(state, window_id);
    }
    for window in client_windows {
        minimized |= minimize_window(state, &window);
    }
    minimized
}

#[cfg(feature = "flutter")]
pub(super) fn minimize_toplevel_by_id(state: &mut RuntimeState, window_id: u64) -> bool {
    let local = state
        .wayland
        .as_ref()
        .is_some_and(|frontend| frontend.is_local_flutter_window(window_id));
    if local {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        if frontend.focused_local_flutter_window() == Some(window_id) {
            frontend.clear_local_flutter_focus();
        }
        if !frontend.set_local_flutter_window_minimized(window_id, true) {
            return false;
        }
        queue_local_window_action(state, window_id, WindowAction::Minimize);
        return true;
    }
    let Some(window) = state
        .wayland
        .as_ref()
        .and_then(|frontend| frontend.window_for_id(window_id))
    else {
        return false;
    };
    minimize_window(state, &window)
}

#[cfg(feature = "flutter")]
fn minimize_window(state: &mut RuntimeState, window: &Window) -> bool {
    apply_managed_minimize(state, window, true)
}

#[cfg(feature = "flutter")]
pub(super) fn close_focused_toplevel(state: &mut RuntimeState) -> bool {
    if let Some(window_id) = focused_local_window(state) {
        return close_toplevel_by_id(state, window_id);
    }
    let Some(window) = focused_window(state) else {
        return false;
    };
    close_window(&window)
}

#[cfg(feature = "flutter")]
pub(super) fn close_toplevel_by_id(state: &mut RuntimeState, window_id: u64) -> bool {
    let local = state
        .wayland
        .as_ref()
        .is_some_and(|frontend| frontend.is_local_flutter_window(window_id));
    if local {
        let removed = state
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .remove_local_flutter_window(window_id);
        if removed {
            state.scene_sync.mark_dirty();
        }
        return removed;
    }
    let Some(window) = state
        .wayland
        .as_ref()
        .and_then(|frontend| frontend.window_for_id(window_id))
    else {
        return false;
    };
    close_window(&window)
}

#[cfg(feature = "flutter")]
fn close_window(window: &Window) -> bool {
    ManagedWindow::new(window).is_some_and(|window| window.close())
}

#[cfg(feature = "flutter")]
struct ShellGeometryTransition {
    target: Rectangle<i32, Logical>,
    action: WindowAction,
    arrange_layout: bool,
}

#[cfg(feature = "flutter")]
fn toggle_scrolling_layout_maximize(state: &mut RuntimeState, window: &Window) -> bool {
    let presentation = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .managed_window_presentation(window);
    if !presentation.fullscreen
        && state
            .wayland
            .as_ref()
            .expect("missing Wayland frontend")
            .window_geometry_locked(window)
    {
        return true;
    }

    let maximized = {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        let Some(root) = frontend.window_root_surface(window) else {
            return false;
        };
        let surface_id = root.id();
        let maximized = presentation.fullscreen || !frontend.window_is_layout_maximized(window);
        let layout_maximized = frontend.window_is_layout_maximized(window);
        if layout_maximized != maximized && !frontend.set_layout_window_maximized(window, maximized)
        {
            return true;
        }
        if presentation.fullscreen {
            frontend.take_shell_presentation(&surface_id);
            frontend.clear_restore_geometry(&surface_id);
            clear_client_geometry_constraints(window);
        }
        frontend.arrange_layout_windows();
        maximized
    };
    queue_window_action_for_window(
        state,
        window,
        if maximized {
            WindowAction::Maximize
        } else {
            WindowAction::Restore
        },
    );
    state.scene_sync.mark_dirty();
    true
}

#[cfg(feature = "flutter")]
fn resolve_fixed_maximize_transition(
    frontend: &mut WaylandFrontend,
    window: &Window,
    client: ClientWindowState,
) -> Option<ShellGeometryTransition> {
    let root_surface = frontend.window_root_surface(window)?;
    let surface_id = root_surface.id();
    let shell_presentation = frontend.take_shell_presentation(&surface_id);
    let shell_transition = shell_presentation.map(|presentation| {
        if client.fullscreen
            && let ShellWindowPresentation::Maximized { normal_geometry } = presentation
        {
            ShellFixedMaximizeTransition::SelectMaximized {
                normal_geometry,
                existing_geometry: None,
            }
        } else {
            presentation.toggle_fixed_maximize()
        }
    });

    let transition = match shell_transition {
        Some(ShellFixedMaximizeTransition::RestoreNormal { geometry }) => {
            frontend.clear_restore_geometry(&surface_id);
            ShellGeometryTransition {
                target: bound_geometry_size(geometry),
                action: WindowAction::Restore,
                arrange_layout: frontend.window_is_layout_managed(window),
            }
        }
        Some(ShellFixedMaximizeTransition::SelectMaximized {
            normal_geometry,
            existing_geometry,
        }) => {
            let target = if let Some(existing_geometry) = existing_geometry {
                bound_geometry_size(existing_geometry)
            } else if let Some(target) = shell_maximized_geometry(frontend, window, normal_geometry)
            {
                target
            } else {
                if let Some(presentation) = shell_presentation {
                    frontend.set_shell_presentation(&surface_id, presentation);
                }
                return None;
            };
            frontend.set_shell_presentation(
                &surface_id,
                ShellWindowPresentation::Maximized { normal_geometry },
            );
            ShellGeometryTransition {
                target,
                action: WindowAction::Maximize,
                arrange_layout: false,
            }
        }
        None if client.fullscreen => {
            let normal_geometry = frontend
                .take_restore_geometry(&surface_id)
                .unwrap_or_else(|| frontend.window_geometry_target(window));
            let target = shell_maximized_geometry(frontend, window, normal_geometry)?;
            frontend.set_shell_presentation(
                &surface_id,
                ShellWindowPresentation::Maximized { normal_geometry },
            );
            ShellGeometryTransition {
                target,
                action: WindowAction::Maximize,
                arrange_layout: false,
            }
        }
        None if client.maximized => {
            let normal_geometry = frontend
                .take_restore_geometry(&surface_id)
                .unwrap_or_else(|| frontend.window_geometry_target(window));
            ShellGeometryTransition {
                target: bound_geometry_size(normal_geometry),
                action: WindowAction::Restore,
                arrange_layout: frontend.window_is_layout_managed(window),
            }
        }
        None => {
            let normal_geometry = bound_geometry_size(frontend.window_geometry_target(window));
            let target = shell_maximized_geometry(frontend, window, normal_geometry)?;
            frontend.set_shell_presentation(
                &surface_id,
                ShellWindowPresentation::Maximized { normal_geometry },
            );
            ShellGeometryTransition {
                target,
                action: WindowAction::Maximize,
                arrange_layout: false,
            }
        }
    };
    Some(transition)
}

#[cfg(feature = "flutter")]
/// Applies SUPER+W maximize. Scrolling layouts own maximize in their retained
/// node; fixed layouts own it in the window's shell presentation record.
pub(super) fn toggle_shell_maximize_focused_toplevel(state: &mut RuntimeState) -> bool {
    if let Some(window_id) = focused_local_window(state) {
        queue_local_window_action(state, window_id, WindowAction::ToggleMaximize);
        return true;
    }
    let Some(window) = focused_window(state) else {
        return false;
    };
    let client = ManagedWindow::new(&window)
        .map(|window| window.facts().client_state)
        .unwrap_or_default();

    let scrolling_maximize = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .window_is_scrolling_layout_managed(&window);
    if scrolling_maximize {
        return toggle_scrolling_layout_maximize(state, &window);
    }
    let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
    let presentation = frontend.managed_window_presentation(&window);
    if !presentation.fullscreen && frontend.window_geometry_locked(&window) {
        return true;
    }

    let transition = resolve_fixed_maximize_transition(
        state.wayland.as_mut().expect("missing Wayland frontend"),
        &window,
        client,
    );
    let Some(transition) = transition else {
        return false;
    };
    let authority = if transition.action == WindowAction::Maximize {
        WindowGeometryAuthority::Shell
    } else {
        WindowGeometryAuthority::Pending
    };
    configure_shell_owned_geometry(state, &window, transition.target, authority);
    if transition.arrange_layout {
        state
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .arrange_layout_windows();
    }
    state
        .wayland
        .as_mut()
        .expect("missing Wayland frontend")
        .remember_window_placement(&window);
    // State-setting actions are deliberate here. If Flutter is still
    // reconciling a fresh window snapshot, an idempotent Restore/Maximize
    // cannot invert the shell state the compositor just applied.
    queue_window_action_for_window(state, &window, transition.action);
    state.scene_sync.mark_dirty();
    true
}

#[cfg(feature = "flutter")]
fn toggle_local_vertical_maximize(state: &mut RuntimeState, window_id: u64) -> bool {
    let (target, restore) = {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        let Some(current) = frontend.local_flutter_window_geometry(window_id) else {
            return false;
        };
        if let Some((y, height)) = frontend
            .window_record_mut(window_id)
            .and_then(|record| record.vertical_restore_geometry.take())
        {
            (
                WindowGeometry {
                    x: current.x,
                    y,
                    width: current.width,
                    height,
                },
                None,
            )
        } else {
            let current_rect = Rectangle::<i32, Logical>::new(
                Point::from((current.x.round() as i32, current.y.round() as i32)),
                Size::from((
                    current.width.round().max(1.0) as i32,
                    current.height.round().max(1.0) as i32,
                )),
            );
            let Some(output) = frontend
                .output_for_geometry(current_rect)
                .map(|entry| entry.output.clone())
            else {
                return false;
            };
            let Some(output_geometry) = frontend.space.output_geometry(&output) else {
                return false;
            };
            let work_area = frontend.maximize_work_area(Some(&output), output_geometry);
            (
                WindowGeometry {
                    x: current.x,
                    y: f64::from(work_area.loc.y),
                    width: current.width,
                    height: f64::from(work_area.size.h),
                },
                Some((current.y, current.height)),
            )
        }
    };

    let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
    frontend.set_local_flutter_window_global_geometry(window_id, target);
    if let Some(restore) = restore {
        frontend
            .window_registry
            .ensure(WindowId::new(window_id))
            .vertical_restore_geometry = Some(restore);
    }
    queue_local_flutter_window_placement(
        state,
        window_id,
        WindowPlacementPhase::End,
        WindowPlacementChange::Resize,
    );
    state.scene_sync.mark_dirty();
    true
}

#[cfg(feature = "flutter")]
fn toggle_client_vertical_maximize(state: &mut RuntimeState, window: &Window) -> bool {
    let client_fullscreen =
        ManagedWindow::new(window).is_some_and(|window| window.facts().client_state.fullscreen);
    let (target, restore) = {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        if client_fullscreen || frontend.window_geometry_locked(window) {
            return true;
        }
        let Some(root_surface) = frontend.window_root_surface(window) else {
            return false;
        };
        let surface_id = root_surface.id();
        let current = bound_geometry_size(frontend.window_geometry_target(window));
        if let Some((y, height)) = frontend
            .window_record_for_surface_mut(&surface_id)
            .and_then(|record| record.vertical_restore_geometry.take())
        {
            (
                Rectangle::new(
                    Point::from((current.loc.x, y as i32)),
                    Size::from((current.size.w, height as i32)),
                ),
                None,
            )
        } else {
            let Some(output) = frontend
                .output_for_geometry(current)
                .map(|entry| entry.output.clone())
            else {
                return false;
            };
            let Some(output_geometry) = frontend.space.output_geometry(&output) else {
                return false;
            };
            let frame = frontend.maximize_work_area(Some(&output), output_geometry);
            let content = shell_content_geometry(frame, shell_draws_server_frame(window));
            (
                Rectangle::new(
                    Point::from((current.loc.x, content.loc.y)),
                    Size::from((current.size.w, content.size.h)),
                ),
                Some((
                    surface_id,
                    (f64::from(current.loc.y), f64::from(current.size.h)),
                )),
            )
        }
    };

    clear_client_geometry_constraints(window);
    if let Some(window) = ManagedWindow::new(window) {
        window.prepare_shell_geometry(target);
    }
    let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
    let authority = if restore.is_some() {
        WindowGeometryAuthority::Shell
    } else {
        WindowGeometryAuthority::Pending
    };
    frontend.set_window_geometry_target_with_authority(window, target, authority);
    if let Some((surface_id, geometry)) = restore {
        if let Some(record) = frontend.ensure_window_record_for_surface(&surface_id) {
            record.vertical_restore_geometry = Some(geometry);
        }
    }
    queue_window_placement_for_monitor(
        state,
        window,
        target,
        target,
        WindowPlacementPhase::End,
        WindowPlacementChange::Resize,
    );
    state.scene_sync.mark_dirty();
    true
}

#[cfg(feature = "flutter")]
/// Toggles a work-area-height alignment while preserving the focused window's
/// current horizontal position and width.
pub(super) fn toggle_shell_vertical_maximize_focused_toplevel(state: &mut RuntimeState) -> bool {
    if let Some(window_id) = focused_local_window(state) {
        return toggle_local_vertical_maximize(state, window_id);
    }
    let Some(window) = focused_window(state) else {
        return false;
    };
    toggle_client_vertical_maximize(state, &window)
}

#[cfg(feature = "flutter")]
fn resolve_shell_fullscreen_exit(
    frontend: &mut WaylandFrontend,
    window: &Window,
    root: &WlSurface,
    current: Rectangle<i32, Logical>,
) -> Option<ShellGeometryTransition> {
    let surface_id = root.id();
    let shell_presentation = frontend.take_shell_presentation(&surface_id);
    let transition = match shell_presentation.and_then(ShellWindowPresentation::exit_fullscreen) {
        Some(ShellFullscreenExit::Normal { geometry }) => ShellGeometryTransition {
            target: bound_geometry_size(geometry),
            action: WindowAction::Restore,
            arrange_layout: frontend.window_is_layout_managed(window),
        },
        Some(ShellFullscreenExit::Maximized {
            normal_geometry,
            geometry,
            layout_owned,
        }) => {
            if layout_owned && frontend.window_is_scrolling_layout_managed(window) {
                frontend.set_layout_window_maximized(window, true);
                ShellGeometryTransition {
                    target: bound_geometry_size(geometry),
                    action: WindowAction::Maximize,
                    arrange_layout: true,
                }
            } else {
                let target = if layout_owned {
                    let Some(target) = shell_maximized_geometry(frontend, window, normal_geometry)
                    else {
                        if let Some(presentation) = shell_presentation {
                            frontend.set_shell_presentation(&surface_id, presentation);
                        }
                        return None;
                    };
                    target
                } else {
                    bound_geometry_size(geometry)
                };
                frontend.set_shell_presentation(
                    &surface_id,
                    ShellWindowPresentation::Maximized { normal_geometry },
                );
                ShellGeometryTransition {
                    target,
                    action: WindowAction::Maximize,
                    arrange_layout: false,
                }
            }
        }
        None if let Some(ShellWindowPresentation::Maximized { normal_geometry }) =
            shell_presentation =>
        {
            let Some(target) = shell_maximized_geometry(frontend, window, normal_geometry) else {
                frontend.set_shell_presentation(
                    &surface_id,
                    ShellWindowPresentation::Maximized { normal_geometry },
                );
                return None;
            };
            frontend.set_shell_presentation(
                &surface_id,
                ShellWindowPresentation::Maximized { normal_geometry },
            );
            ShellGeometryTransition {
                target,
                action: WindowAction::Maximize,
                arrange_layout: false,
            }
        }
        None => {
            let target = frontend
                .take_restore_geometry(&surface_id)
                .unwrap_or(current);
            let layout_maximized = frontend.window_is_layout_maximized(window);
            ShellGeometryTransition {
                target: bound_geometry_size(target),
                action: if layout_maximized {
                    WindowAction::Maximize
                } else {
                    WindowAction::Restore
                },
                arrange_layout: frontend.window_is_layout_managed(window),
            }
        }
    };
    Some(transition)
}

#[cfg(feature = "flutter")]
fn resolve_shell_fullscreen_entry(
    frontend: &mut WaylandFrontend,
    window: &Window,
    root: &WlSurface,
    current: Rectangle<i32, Logical>,
    client: ClientWindowState,
) -> Option<ShellGeometryTransition> {
    let assigned_output = frontend
        .managed_layout_space(window)
        .map(|space| space.output);
    let target = assigned_output
        .and_then(|output| {
            frontend
                .outputs
                .iter()
                .find(|entry| entry.id == output)
                .map(|entry| entry.logical_geometry)
        })
        .or_else(|| {
            frontend
                .output_for_geometry(current)
                .map(|entry| entry.logical_geometry)
        })?;

    let surface_id = root.id();
    let previous = frontend.take_shell_presentation(&surface_id).or_else(|| {
        client
            .maximized
            .then(|| ShellWindowPresentation::Maximized {
                normal_geometry: frontend
                    .take_restore_geometry(&surface_id)
                    .unwrap_or(current),
            })
    });
    let layout_normal_geometry = frontend.window_is_layout_maximized(window).then(|| {
        frontend
            .window_record_for_surface(&surface_id)
            .and_then(|record| record.layout_restore_geometry)
            .unwrap_or(current)
    });
    frontend.set_shell_presentation(
        &surface_id,
        ShellWindowPresentation::fullscreen(current, previous, layout_normal_geometry),
    );
    Some(ShellGeometryTransition {
        target,
        action: WindowAction::Fullscreen,
        arrange_layout: false,
    })
}

#[cfg(feature = "flutter")]
pub(super) fn toggle_shell_fullscreen_focused_toplevel(state: &mut RuntimeState) -> bool {
    if let Some(window_id) = focused_local_window(state) {
        queue_local_window_action(state, window_id, WindowAction::ToggleFullscreen);
        return true;
    }
    let Some(window) = focused_window(state) else {
        return false;
    };
    let client = ManagedWindow::new(&window)
        .map(|window| window.facts().client_state)
        .unwrap_or_default();

    // SUPER+F is compositor-owned. Rust resolves one physical output and
    // applies the complete geometry before Flutter mirrors the state; the
    // multi-output Flutter canvas is never a fullscreen target.
    let initial = {
        let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
        let root = frontend.window_root_surface(&window);
        root.map(|root| {
            (
                root,
                frontend.managed_window_presentation(&window),
                bound_geometry_size(frontend.window_geometry_target(&window)),
                frontend.exact_window_geometry(&window).is_some(),
            )
        })
    };
    let Some((root, presentation, current, exact_geometry)) = initial else {
        return false;
    };
    if !presentation.fullscreen && exact_geometry {
        return true;
    }

    let transition = {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        if presentation.fullscreen {
            resolve_shell_fullscreen_exit(frontend, &window, &root, current)
        } else {
            resolve_shell_fullscreen_entry(frontend, &window, &root, current, client)
        }
    };
    let Some(transition) = transition else {
        return false;
    };

    if transition.arrange_layout {
        clear_client_geometry_constraints(&window);
        state
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .arrange_layout_windows();
    } else {
        let authority = if matches!(
            transition.action,
            WindowAction::Fullscreen | WindowAction::Maximize
        ) {
            WindowGeometryAuthority::Shell
        } else {
            WindowGeometryAuthority::Pending
        };
        configure_shell_owned_geometry(state, &window, transition.target, authority);
    }
    state
        .wayland
        .as_mut()
        .expect("missing Wayland frontend")
        .remember_window_placement(&window);
    queue_window_action_for_window(state, &window, transition.action);
    state.scene_sync.mark_dirty();
    true
}

/// A protocol client request after XDG/Xwayland callback admission.
///
/// The optional output resource is meaningful only to XDG fullscreen's wire
/// acknowledgement. Output selection, geometry ownership, layout interaction,
/// and Flutter publication are otherwise identical for every managed window.
pub(super) enum ManagedClientStateRequest {
    Maximize,
    Unmaximize,
    Fullscreen(Option<wl_output::WlOutput>),
    Unfullscreen,
}

impl ManagedClientStateRequest {
    fn kind(&self) -> ClientStateRequestKind {
        match self {
            Self::Maximize => ClientStateRequestKind::Maximize,
            Self::Unmaximize => ClientStateRequestKind::Unmaximize,
            Self::Fullscreen(_) => ClientStateRequestKind::Fullscreen,
            Self::Unfullscreen => ClientStateRequestKind::Unfullscreen,
        }
    }

    fn fullscreen_output(&self) -> Option<&wl_output::WlOutput> {
        match self {
            Self::Fullscreen(output) => output.as_ref(),
            Self::Maximize | Self::Unmaximize | Self::Unfullscreen => None,
        }
    }
}

fn request_enters_client_state(kind: ClientStateRequestKind) -> bool {
    matches!(
        kind,
        ClientStateRequestKind::Maximize | ClientStateRequestKind::Fullscreen
    )
}

fn client_state_unconstrained_after(
    kind: ClientStateRequestKind,
    before: ClientWindowState,
) -> bool {
    match kind {
        ClientStateRequestKind::Unmaximize => !before.fullscreen,
        ClientStateRequestKind::Unfullscreen => !before.maximized,
        ClientStateRequestKind::Maximize | ClientStateRequestKind::Fullscreen => false,
    }
}

fn resolve_entering_client_state_target(
    state: &mut RuntimeState,
    window: &Window,
    request: &ManagedClientStateRequest,
    kind: ClientStateRequestKind,
    current: Rectangle<i32, Logical>,
    scrolling_layout_maximize: bool,
) -> Option<(Rectangle<i32, Logical>, Option<wl_output::WlOutput>)> {
    let requested_output_resource = request.fullscreen_output();
    let (output, monitor, fullscreen_output) = {
        let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
        let requested_output = requested_output_resource
            .and_then(Output::from_resource)
            .filter(|candidate| {
                frontend
                    .outputs
                    .iter()
                    .any(|entry| entry.output == *candidate)
            });
        let fullscreen_output = requested_output
            .as_ref()
            .and_then(|_| requested_output_resource.cloned());
        let output = requested_output
            .or_else(|| {
                frontend.managed_layout_space(window).and_then(|space| {
                    frontend
                        .outputs
                        .iter()
                        .find(|entry| entry.id == space.output)
                        .map(|entry| entry.output.clone())
                })
            })
            .or_else(|| {
                frontend
                    .output_for_geometry(current)
                    .map(|entry| entry.output.clone())
            })?;
        let monitor = frontend.space.output_geometry(&output)?;
        (output, monitor, fullscreen_output)
    };

    if kind == ClientStateRequestKind::Fullscreen {
        return Some((monitor, fullscreen_output));
    }

    debug_assert_eq!(kind, ClientStateRequestKind::Maximize);
    if scrolling_layout_maximize
        && let Some(target) = state
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .layout_target_for_window(window)
    {
        return Some((target, fullscreen_output));
    }

    let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
    let target = maximized_shell_content_geometry(
        frontend.maximize_work_area(Some(&output), monitor),
        shell_draws_server_frame(window),
        frontend.window_layout_manages_geometry(),
    );
    Some((target, fullscreen_output))
}

fn store_client_restore_geometry(
    state: &mut RuntimeState,
    root: &WlSurface,
    current: Rectangle<i32, Logical>,
) -> Option<Rectangle<i32, Logical>> {
    let restore = bound_geometry_size(current);
    let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
    match frontend.ensure_window_record_for_surface(&root.id()) {
        Some(record) if record.restore_geometry.is_none() => {
            record.restore_geometry = Some(restore);
            Some(restore)
        }
        _ => None,
    }
}

fn apply_client_state_geometry(
    state: &mut RuntimeState,
    window: &Window,
    target: Option<Rectangle<i32, Logical>>,
    restore: Option<Rectangle<i32, Logical>>,
    restore_to_publish: Option<Rectangle<i32, Logical>>,
    unconstrained_after: bool,
) {
    if let Some(target) = target {
        state
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .set_window_geometry_target_with_authority(
                window,
                target,
                WindowGeometryAuthority::ClientState,
            );
        #[cfg(feature = "flutter")]
        if let Some(restore) = restore_to_publish {
            queue_client_window_placement_for_monitor(
                state,
                window,
                restore,
                target,
                WindowPlacementPhase::End,
                WindowPlacementChange::Resize,
            );
        }
        #[cfg(not(feature = "flutter"))]
        let _ = restore_to_publish;
        return;
    }
    if !unconstrained_after {
        return;
    }

    let layout_managed = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .window_is_layout_managed(window);
    if layout_managed {
        state
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .arrange_layout_windows();
    } else if let Some(restore) = restore {
        state
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .set_window_geometry_target(window, restore);
    } else {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        frontend.defer_client_sized_window_placement(window);
        frontend.clear_window_geometry_intent(window);
    }
}

#[cfg(feature = "flutter")]
fn publish_client_state_to_shell(state: &mut RuntimeState, window: &Window) {
    let presentation = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .managed_window_presentation(window);
    let action = if presentation.fullscreen {
        WindowAction::Fullscreen
    } else if presentation.maximized {
        WindowAction::Maximize
    } else {
        WindowAction::Restore
    };
    queue_window_action_for_window(state, window, action);
}

/// Applies one client state request through Denial's managed-window path.
///
/// XDG state/configure serials and X11 EWMH setters remain terminal protocol
/// handshakes. They do not own any shell policy beyond this function.
pub(super) fn apply_managed_client_state_request(
    state: &mut RuntimeState,
    window: &Window,
    request: ManagedClientStateRequest,
) -> bool {
    #[cfg(feature = "flutter")]
    if let Some(exact) = state
        .wayland
        .as_ref()
        .and_then(|frontend| frontend.exact_window_geometry(window))
    {
        configure_shell_owned_geometry(state, window, exact, WindowGeometryAuthority::Exact);
        state.scene_sync.mark_dirty();
        return true;
    }

    let scrolling_layout_maximize = matches!(
        request,
        ManagedClientStateRequest::Maximize | ManagedClientStateRequest::Unmaximize
    ) && state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .window_is_scrolling_layout_managed(window);
    if scrolling_layout_maximize {
        let maximized = matches!(request, ManagedClientStateRequest::Maximize);
        state
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .set_layout_window_maximized(window, maximized);
    } else if matches!(request, ManagedClientStateRequest::Maximize)
        && state
            .wayland
            .as_ref()
            .expect("missing Wayland frontend")
            .window_is_layout_managed(window)
    {
        // Fixed managed layouts continue rejecting client maximize rather
        // than letting a screen-sized overlay obscure their remaining tiles.
        state
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .arrange_layout_windows();
        state.scene_sync.mark_dirty();
        return true;
    }

    let root = state
        .wayland
        .as_ref()
        .and_then(|frontend| frontend.window_root_surface(window));
    let Some(root) = root else {
        return false;
    };
    state
        .wayland
        .as_mut()
        .expect("missing Wayland frontend")
        .mark_client_geometry_state_request(&root);

    #[cfg(feature = "flutter")]
    if state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .window_shell_fullscreen_locked(window)
    {
        // Shell fullscreen is the geometry authority. Reject client attempts
        // to replace it and reassert the one retained target for both protocols.
        let target = state
            .wayland
            .as_ref()
            .expect("missing Wayland frontend")
            .window_geometry_target(window);
        configure_shell_owned_geometry(state, window, target, WindowGeometryAuthority::Shell);
        state.scene_sync.mark_dirty();
        return true;
    }

    let Some(managed) = ManagedWindow::new(window) else {
        return false;
    };
    let before = managed.facts().client_state;
    let kind = request.kind();
    let entering = request_enters_client_state(kind);
    let unconstrained_after = client_state_unconstrained_after(kind, before);
    let current = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .window_geometry_target(window);
    let (target, fullscreen_output) = if entering {
        let Some((target, fullscreen_output)) = resolve_entering_client_state_target(
            state,
            window,
            &request,
            kind,
            current,
            scrolling_layout_maximize,
        ) else {
            return false;
        };
        (Some(target), fullscreen_output)
    } else {
        (None, None)
    };

    let restore_to_publish = if !before.fullscreen
        && !before.maximized
        && entering
        && managed.can_store_client_restore()
        && current.size.w > 0
        && current.size.h > 0
    {
        store_client_restore_geometry(state, &root, current)
    } else {
        None
    };
    let restore = if !entering && unconstrained_after {
        state
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .take_restore_geometry(&root.id())
            .map(bound_geometry_size)
    } else {
        None
    };

    let target_size = target.or(restore).map(|geometry| geometry.size);
    if !managed.prepare_client_state_request(kind, target_size, fullscreen_output) {
        return false;
    }

    apply_client_state_geometry(
        state,
        window,
        target,
        restore,
        restore_to_publish,
        unconstrained_after,
    );
    if scrolling_layout_maximize {
        state
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .arrange_layout_windows();
    }
    #[cfg(feature = "flutter")]
    publish_client_state_to_shell(state, window);
    state.scene_sync.mark_dirty();
    true
}

/// Common admission gate for protocol-initiated move and resize grabs.
pub(super) fn managed_client_grab_allowed(state: &RuntimeState, window: &Window) -> bool {
    let Some(facts) = ManagedWindow::new(window).map(|window| window.facts()) else {
        return false;
    };
    if facts.override_redirect
        || facts.client_state.fullscreen
        || facts.client_state.maximized
        || state
            .wayland
            .as_ref()
            .is_some_and(|frontend| frontend.window_is_layout_managed(window))
    {
        return false;
    }
    #[cfg(feature = "flutter")]
    if state.wayland.as_ref().is_some_and(|frontend| {
        frontend.window_shell_fullscreen_locked(window)
            || frontend.exact_window_geometry(window).is_some()
    }) {
        return false;
    }
    true
}

#[cfg(feature = "flutter")]
pub(super) fn apply_managed_minimize(
    state: &mut RuntimeState,
    window: &Window,
    minimized: bool,
) -> bool {
    let Some(managed) = ManagedWindow::new(window) else {
        return false;
    };
    let Some(root) = state
        .wayland
        .as_ref()
        .and_then(|frontend| frontend.window_root_surface(window))
    else {
        return false;
    };
    managed.prepare_minimized(minimized);
    state
        .wayland
        .as_mut()
        .expect("missing Wayland frontend")
        .set_surface_minimized(root.id(), minimized);
    if minimized {
        state
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .remove_window_from_layout(window, false);
        release_window_focus(state, window);
        queue_window_action_for_window(state, window, WindowAction::Minimize);
    } else {
        state
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .reconcile_window_layout(window);
        queue_window_action_for_window(state, window, WindowAction::Restore);
    }
    state.scene_sync.mark_dirty();
    true
}

/// Finalize the window side of a committed output-membership change.
///
/// KMS calls this only after retired CRTCs are dark and after replacement
/// Flutter startup can no longer fail. Keeping it separate from
/// `update_topology` also leaves rollback free to restore the untouched layout
/// trees when publication or engine startup fails.
#[cfg(feature = "flutter")]
pub(crate) fn finalize_topology_window_reconciliation(
    state: &mut RuntimeState,
    reconciliation: super::topology::TopologyWindowReconciliation,
) {
    if !reconciliation.layout_membership_changed {
        return;
    }

    let mut changed = false;
    for window_id in reconciliation.windows_to_minimize {
        let local = state
            .wayland
            .as_ref()
            .is_some_and(|frontend| frontend.is_local_flutter_window(window_id));
        if local {
            let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
            if frontend.focused_local_flutter_window() == Some(window_id) {
                frontend.clear_local_flutter_focus();
            }
            changed |= frontend.set_local_flutter_window_minimized(window_id, true);
            continue;
        }

        let Some(window) = state
            .wayland
            .as_ref()
            .and_then(|frontend| frontend.window_for_id(window_id))
        else {
            continue;
        };
        let Some(root) = state
            .wayland
            .as_ref()
            .and_then(|frontend| frontend.window_root_surface(&window))
        else {
            continue;
        };
        if let Some(managed) = ManagedWindow::new(&window) {
            managed.prepare_minimized(true);
        }
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        changed |= frontend.set_surface_minimized(root.id(), true);
        changed |= frontend.detach_window_from_layout(&window, false);
        release_window_focus(state, &window);
    }

    changed |= state
        .wayland
        .as_mut()
        .is_some_and(WaylandFrontend::arrange_layout_windows);
    if changed {
        state.scene_sync.mark_dirty();
    }
}

#[cfg(all(test, feature = "flutter"))]
mod tests {
    use smithay::utils::{Logical, Point, Rectangle, Size};

    use super::{
        authoritative_geometry_rejects_configure, configured_window_size,
        maximized_shell_content_geometry,
    };

    fn rect(x: i32, y: i32, width: i32, height: i32) -> Rectangle<i32, Logical> {
        Rectangle::new(Point::from((x, y)), Size::from((width, height)))
    }

    #[test]
    fn managed_layout_accepts_shell_fullscreen_geometry() {
        let tile = rect(10, 10, 940, 1040);
        let fullscreen = rect(0, 0, 1920, 1080);

        assert!(authoritative_geometry_rejects_configure(
            true, tile, fullscreen
        ));
        assert!(!authoritative_geometry_rejects_configure(true, tile, tile));
        assert!(!authoritative_geometry_rejects_configure(
            false, tile, fullscreen
        ));
    }

    #[test]
    fn shell_fullscreen_overrides_fixed_client_size_hints() {
        let maximized = Size::<i32, Logical>::from((2542, 1397));
        let fullscreen = Size::<i32, Logical>::from((2560, 1440));

        assert_eq!(
            configured_window_size(fullscreen, maximized, maximized, false),
            maximized,
        );
        assert_eq!(
            configured_window_size(fullscreen, maximized, maximized, true),
            fullscreen,
        );
    }

    #[test]
    fn managed_layout_overrides_fixed_client_size_hints() {
        let client_fixed = Size::<i32, Logical>::from((2280, 1397));
        let tile = Size::<i32, Logical>::from((1265, 1397));

        assert_eq!(
            configured_window_size(tile, client_fixed, client_fixed, false),
            client_fixed,
        );
        assert_eq!(
            configured_window_size(tile, client_fixed, client_fixed, true),
            tile,
        );
    }

    #[test]
    fn managed_layout_maximize_reserves_the_shell_frame() {
        let frame = rect(8, 40, 1904, 1032);

        assert_eq!(
            maximized_shell_content_geometry(frame, true, true),
            rect(9, 41, 1902, 1030),
        );
        assert_eq!(maximized_shell_content_geometry(frame, true, false), frame,);
        assert_eq!(maximized_shell_content_geometry(frame, false, true), frame,);
    }
}
