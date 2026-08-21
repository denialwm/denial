use smithay::desktop::Window;
use smithay::output::Output;
use smithay::reexports::wayland_protocols::xdg::shell::server::xdg_toplevel;
use smithay::reexports::wayland_server::Resource;
use smithay::reexports::wayland_server::protocol::wl_output;
use smithay::utils::{Logical, Rectangle, Size};
#[cfg(feature = "flutter")]
use smithay::utils::{Point, SERIAL_COUNTER};
use smithay::wayland::compositor::with_states;
#[cfg(feature = "flutter")]
use smithay::wayland::seat::WaylandFocus;
#[cfg(feature = "flutter")]
use smithay::wayland::shell::xdg::SurfaceCachedState;
use smithay::wayland::shell::xdg::{ToplevelSurface, XdgToplevelSurfaceData};
#[cfg(feature = "flutter")]
use smithay::xwayland::xwm::{WmWindowType, X11Surface};
use tracing::warn;

#[cfg(feature = "flutter")]
use super::super::PendingWindowEvent;
use super::super::RuntimeState;
use super::super::window_grab::constrain_dimension;
#[cfg(feature = "flutter")]
use super::super::window_placement_store::RestoredWindowPlacement;
#[cfg(feature = "flutter")]
use super::super::wire::{
    WindowAction, WindowCommand, WindowGeometry, WindowPlacementChange, WindowPlacementPhase,
};
#[cfg(feature = "flutter")]
use super::clamp_window_geometry;

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
    exact: bool,
) -> Size<i32, Logical> {
    if exact {
        requested
    } else {
        Size::from((
            constrain_dimension(requested.w, minimum.w, maximum.w),
            constrain_dimension(requested.h, minimum.h, maximum.h),
        ))
    }
}

fn client_restore_geometry(
    initial_configure_sent: bool,
    geometry: Rectangle<i32, Logical>,
) -> Option<Rectangle<i32, Logical>> {
    (initial_configure_sent && geometry.size.w > 0 && geometry.size.h > 0)
        .then(|| bound_geometry_size(geometry))
}

#[cfg(feature = "flutter")]
// Must match DesktopMetrics.frameBorder in the embedded shell.
const SHELL_FRAME_BORDER: i32 = 1;

#[cfg(feature = "flutter")]
pub(super) fn shell_draws_server_frame(window: &Window) -> bool {
    if window.toplevel().is_some() {
        return true;
    }
    window
        .x11_surface()
        .is_some_and(shell_draws_x11_server_frame)
}

#[cfg(feature = "flutter")]
pub(super) fn shell_draws_x11_server_frame(x11: &X11Surface) -> bool {
    // Denial owns the frame for managed X11 toplevels regardless of client
    // decoration hints. Protocol-level popups remain unframed.
    !x11.is_override_redirect()
        && !matches!(
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
        )
}

#[cfg(feature = "flutter")]
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

/// Drop client-protocol fullscreen/maximize state before a shell-owned
/// configure or SUPER pointer interaction.
///
/// Denial's Flutter fullscreen is deliberately independent from XDG/EWMH
/// state. Keeping those states coupled makes a game's focus-loss request undo
/// SUPER+F and causes normal shell resize commands to be rejected.
#[cfg(feature = "flutter")]
pub(super) fn clear_client_geometry_constraints(window: &Window) -> bool {
    if let Some(toplevel) = window.toplevel() {
        if !toplevel.wl_surface().is_alive() {
            return false;
        }
        return toplevel.with_pending_state(|pending| {
            let fullscreen = pending.states.unset(xdg_toplevel::State::Fullscreen);
            let maximized = pending.states.unset(xdg_toplevel::State::Maximized);
            if fullscreen {
                pending.fullscreen_output = None;
            }
            fullscreen || maximized
        });
    }

    let Some(x11) = window.x11_surface() else {
        return false;
    };
    let fullscreen = x11.is_fullscreen();
    let maximized = x11.is_maximized();
    if fullscreen && let Err(error) = x11.set_fullscreen(false) {
        warn!(%error, window = x11.window_id(), "could not clear X11 fullscreen for shell geometry");
    }
    if maximized && let Err(error) = x11.set_maximized(false) {
        warn!(%error, window = x11.window_id(), "could not clear X11 maximized state for shell geometry");
    }
    fullscreen || maximized
}

#[cfg(feature = "flutter")]
pub(super) fn set_toplevel_suspended(toplevel: &ToplevelSurface, suspended: bool) -> bool {
    if !toplevel.wl_surface().is_alive() {
        return false;
    }
    toplevel.with_pending_state(|pending| {
        if suspended {
            pending.states.set(xdg_toplevel::State::Suspended)
        } else {
            pending.states.unset(xdg_toplevel::State::Suspended)
        }
    })
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

    {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        #[cfg(feature = "flutter")]
        let resumed = frontend
            .window_root_surface(window)
            .is_some_and(|surface| frontend.set_surface_minimized(surface.id(), false))
            && window
                .toplevel()
                .is_some_and(|toplevel| set_toplevel_suspended(toplevel, false));
        #[cfg(not(feature = "flutter"))]
        let resumed = false;

        if let Some(x11) = window.x11_surface()
            && let Err(error) = x11.set_hidden(false)
        {
            warn!(%error, window = x11.window_id(), "could not restore activated X11 window");
        }
        frontend.raise_window(window, true);
        for candidate in frontend.space.elements() {
            let changed = candidate.set_activated(candidate == window);
            if let Some(toplevel) = candidate.toplevel()
                && (changed || (candidate == window && resumed))
                && toplevel.wl_surface().is_alive()
            {
                toplevel.send_pending_configure();
            }
        }
    }

    keyboard.set_focus(state, Some(keyboard_focus), serial);
    #[cfg(feature = "flutter")]
    if let Some(window_id) = window_id {
        state
            .pending_window_events
            .push(PendingWindowEvent::Activated(window_id));
    }
    state.scene_sync.mark_dirty();
    true
}

#[cfg(feature = "flutter")]
pub(in super::super) fn apply_window_commands(
    state: &mut RuntimeState,
    commands: impl IntoIterator<Item = WindowCommand>,
) {
    for command in commands {
        let command = match command {
            WindowCommand::CreateLocal {
                app_id,
                title,
                geometry,
            } => {
                let created = state
                    .wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .create_local_flutter_window(app_id, title, geometry);
                let window_id = match created {
                    Ok(window_id) => window_id,
                    Err(error) => {
                        warn!(?error, "could not create local Flutter window");
                        continue;
                    }
                };
                activate_local_flutter_window(state, window_id);
                continue;
            }
            command => command,
        };

        let window_id = command
            .window_id()
            .expect("non-create window command is missing its target");
        let is_local = state
            .wayland
            .as_ref()
            .is_some_and(|frontend| frontend.is_local_flutter_window(window_id));
        if is_local {
            match command {
                WindowCommand::Close { .. } => {
                    if state
                        .wayland
                        .as_mut()
                        .expect("missing Wayland frontend")
                        .remove_local_flutter_window(window_id)
                    {
                        state.scene_sync.mark_dirty();
                    }
                }
                WindowCommand::Focus { .. } => {
                    activate_local_flutter_window(state, window_id);
                }
                WindowCommand::Configure { geometry, .. } => {
                    if state
                        .wayland
                        .as_mut()
                        .expect("missing Wayland frontend")
                        .configure_local_flutter_window(window_id, geometry)
                    {
                        state.scene_sync.mark_dirty();
                    }
                }
                WindowCommand::CreateLocal { .. } => unreachable!(),
            }
            continue;
        }

        let window = state
            .wayland
            .as_ref()
            .and_then(|frontend| frontend.window_for_id(window_id));
        let Some(window) = window else {
            warn!(window_id, ?command, "ignored command for stale window");
            continue;
        };
        let Some(root_surface) = state
            .wayland
            .as_ref()
            .and_then(|frontend| frontend.window_root_surface(&window))
        else {
            warn!(
                window_id,
                "ignored command for a window without a root surface"
            );
            continue;
        };

        match command {
            WindowCommand::Close { .. } => {
                if let Some(toplevel) = window.toplevel() {
                    toplevel.send_close();
                } else if let Some(x11) = window.x11_surface()
                    && let Err(error) = x11.close()
                {
                    warn!(%error, window_id, "could not close X11 window");
                }
            }
            WindowCommand::Focus { .. } => {
                activate_window(state, &window, SERIAL_COUNTER.next_serial());
            }
            WindowCommand::Configure {
                geometry, exact, ..
            } => {
                let requested_size = Size::<i32, Logical>::from((
                    geometry.width.round() as i32,
                    geometry.height.round() as i32,
                ));
                let (minimum, maximum) = if let Some(toplevel) = window.toplevel() {
                    if !exact && toplevel_has_state(toplevel, xdg_toplevel::State::Resizing) {
                        warn!(
                            window_id,
                            "ignored Flutter configure during an active XDG resize"
                        );
                        continue;
                    }
                    with_states(toplevel.wl_surface(), |states| {
                        let mut cached = states.cached_state.get::<SurfaceCachedState>();
                        let current = cached.current();
                        (current.min_size, current.max_size)
                    })
                } else if let Some(x11) = window.x11_surface() {
                    if x11.is_override_redirect() {
                        warn!(
                            window_id,
                            "ignored Flutter configure for an override-redirect X11 window"
                        );
                        continue;
                    }
                    (
                        x11.min_size().unwrap_or_else(|| Size::from((1, 1))),
                        x11.max_size().unwrap_or_else(|| Size::from((0, 0))),
                    )
                } else {
                    continue;
                };
                let size = configured_window_size(requested_size, minimum, maximum, exact);
                let scene_origin = state
                    .wayland
                    .as_ref()
                    .expect("missing Wayland frontend")
                    .atlas_origin;
                let target_location = Point::<i32, Logical>::from((
                    (geometry.x + scene_origin.x)
                        .round()
                        .clamp(f64::from(i32::MIN), f64::from(i32::MAX)) as i32,
                    (geometry.y + scene_origin.y)
                        .round()
                        .clamp(f64::from(i32::MIN), f64::from(i32::MAX)) as i32,
                ));
                let target = Rectangle::new(target_location, size);
                let (preserve_client_fullscreen, transferred_shell_restore) = {
                    let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                    let client_fullscreen =
                        window.toplevel().is_some_and(|toplevel| {
                            toplevel_has_state(toplevel, xdg_toplevel::State::Fullscreen)
                        }) || window.x11_surface().is_some_and(|x11| x11.is_fullscreen());
                    let current_target = frontend.window_geometry_target(&window);
                    let preserve_client_fullscreen = !exact
                        && preserves_client_fullscreen_geometry(
                            client_fullscreen,
                            current_target,
                            target,
                        );
                    let output_transfer = frontend
                        .output_for_geometry(current_target)
                        .and_then(|source| {
                            frontend.output_for_geometry(target).map(|destination| {
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
                    let mut transferred_shell_restore = false;
                    if let Some((_, source_geometry, _, destination_geometry, destination_output)) =
                        output_transfer
                    {
                        let destination_bounds = frontend
                            .maximize_work_area(Some(&destination_output), destination_geometry);
                        let surface_id = root_surface.id();
                        if let Some(restore) = frontend
                            .shell_maximize_restore_geometries
                            .get_mut(&surface_id)
                        {
                            *restore = transfer_restore_geometry(
                                *restore,
                                source_geometry,
                                destination_geometry,
                                destination_bounds,
                            );
                            transferred_shell_restore = true;
                        }
                        if let Some(restore) = frontend
                            .shell_fullscreen_restore_geometries
                            .get_mut(&surface_id)
                        {
                            *restore = transfer_restore_geometry(
                                *restore,
                                source_geometry,
                                destination_geometry,
                                destination_bounds,
                            );
                            transferred_shell_restore = true;
                        }
                    }
                    (preserve_client_fullscreen, transferred_shell_restore)
                };
                if !preserve_client_fullscreen {
                    // A different rectangle is a shell-authored move/resize,
                    // so the client protocol must stop constraining geometry.
                    // An identical fullscreen rectangle is only Flutter
                    // echoing the XDG/EWMH transition Rust already granted;
                    // clearing it would make browsers require a second click.
                    clear_client_geometry_constraints(&window);
                    state
                        .wayland
                        .as_mut()
                        .expect("missing Wayland frontend")
                        .restore_window_geometries
                        .remove(&root_surface.id());
                }
                if let Some(toplevel) = window.toplevel() {
                    toplevel.with_pending_state(|pending| {
                        if exact {
                            pending.states.unset(xdg_toplevel::State::Resizing);
                        }
                        pending.size = Some(size);
                    });
                    toplevel.send_pending_configure();
                }
                let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                frontend.set_window_geometry_target_policy(&window, target, exact);
                if transferred_shell_restore {
                    frontend.remember_window_placement(&window);
                }
                state.scene_sync.mark_dirty();
            }
            WindowCommand::CreateLocal { .. } => unreachable!(),
        }
    }
}

#[cfg(feature = "flutter")]
pub(super) fn activate_local_flutter_window(state: &mut RuntimeState, window_id: u64) -> bool {
    if !state
        .wayland
        .as_mut()
        .expect("missing Wayland frontend")
        .focus_local_flutter_window(window_id)
    {
        return false;
    }
    let keyboard = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .seat
        .get_keyboard()
        .expect("seat has no keyboard");
    deactivate_client_windows(state.wayland.as_mut().expect("missing Wayland frontend"));
    keyboard.set_focus(state, None, SERIAL_COUNTER.next_serial());
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
        if let Some(candidate) = candidate.toplevel()
            && changed
            && candidate.wl_surface().is_alive()
        {
            candidate.send_pending_configure();
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
        queue_window_action_for_window(state, window, WindowAction::ToggleFullscreen);
    }
}

#[cfg(feature = "flutter")]
pub(super) fn queue_window_action(
    state: &mut RuntimeState,
    surface: &ToplevelSurface,
    action: WindowAction,
) {
    let window = state
        .wayland
        .as_ref()
        .and_then(|frontend| frontend.window_for_root_surface(surface.wl_surface()));
    if let Some(window) = window {
        queue_window_action_for_window(state, &window, action);
    }
}

#[cfg(feature = "flutter")]
pub(super) fn toplevel_shell_geometry_locked(
    state: &RuntimeState,
    surface: &ToplevelSurface,
) -> bool {
    state.wayland.as_ref().is_some_and(|frontend| {
        frontend
            .window_for_root_surface(surface.wl_surface())
            .as_ref()
            .is_some_and(|window| frontend.window_shell_fullscreen_locked(window))
    })
}

#[cfg(feature = "flutter")]
pub(super) fn reassert_exact_toplevel_geometry(
    state: &mut RuntimeState,
    surface: &ToplevelSurface,
) -> bool {
    let exact = state.wayland.as_ref().and_then(|frontend| {
        frontend
            .window_for_root_surface(surface.wl_surface())
            .and_then(|window| frontend.exact_window_geometry(&window))
    });
    let Some(exact) = exact else {
        return false;
    };
    surface.with_pending_state(|pending| {
        pending.states.unset(xdg_toplevel::State::Fullscreen);
        pending.states.unset(xdg_toplevel::State::Maximized);
        pending.states.unset(xdg_toplevel::State::Resizing);
        pending.fullscreen_output = None;
        pending.size = Some(exact.size);
    });
    if surface.is_initial_configure_sent() {
        surface.send_configure();
    }
    state.scene_sync.mark_dirty();
    true
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
    if let Some(toplevel) = window.toplevel()
        && changed
        && toplevel.wl_surface().is_alive()
    {
        toplevel.send_pending_configure();
    }
    keyboard.set_focus(state, None, SERIAL_COUNTER.next_serial());
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
fn queue_local_window_action(state: &mut RuntimeState, window_id: u64, action: WindowAction) {
    state
        .pending_window_events
        .push(PendingWindowEvent::Action(window_id, action));
    state.scene_sync.mark_dirty();
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
    let Some(root) = state
        .wayland
        .as_ref()
        .and_then(|frontend| frontend.window_root_surface(window))
    else {
        return false;
    };
    state
        .wayland
        .as_mut()
        .expect("missing Wayland frontend")
        .set_surface_minimized(root.id(), true);
    if let Some(toplevel) = window.toplevel()
        && set_toplevel_suspended(toplevel, true)
    {
        toplevel.send_pending_configure();
    }
    // Minimization is a shell visibility state. X11Surface::set_hidden(true)
    // advertises IconicState/_NET_WM_STATE_HIDDEN and explicitly permits the
    // application to stop rendering, which would make its live Flutter texture
    // stale or black. Keep the client mapped and producing frames.
    queue_window_action_for_window(state, window, WindowAction::Minimize);
    release_window_focus(state, window);
    state.scene_sync.mark_dirty();
    true
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
    if let Some(toplevel) = window.toplevel() {
        toplevel.send_close();
        true
    } else if let Some(x11) = window.x11_surface() {
        if let Err(error) = x11.close() {
            warn!(%error, "could not close X11 window");
            return false;
        }
        true
    } else {
        false
    }
}

#[cfg(feature = "flutter")]
/// Atomically applies the shell-owned SUPER+Up geometry before notifying
/// Flutter. The XDG/EWMH maximized state stays untouched, but Rust remains the
/// placement authority throughout the transition instead of waiting for a
/// later Flutter frame to return the requested coordinates.
pub(super) fn toggle_shell_maximize_focused_toplevel(state: &mut RuntimeState) -> bool {
    if let Some(window_id) = focused_local_window(state) {
        queue_local_window_action(state, window_id, WindowAction::ToggleMaximize);
        return true;
    }
    let Some(window) = focused_window(state) else {
        return false;
    };
    let (client_fullscreen, client_maximized) = if let Some(toplevel) = window.toplevel() {
        (
            toplevel_has_state(toplevel, xdg_toplevel::State::Fullscreen),
            toplevel_has_state(toplevel, xdg_toplevel::State::Maximized),
        )
    } else if let Some(x11) = window.x11_surface() {
        (x11.is_fullscreen(), x11.is_maximized())
    } else {
        (false, false)
    };

    let (target, action) = {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        if client_fullscreen || frontend.window_geometry_locked(&window) {
            // SUPER+Up is a no-op while true fullscreen is active.
            return true;
        }
        let Some(root_surface) = frontend.window_root_surface(&window) else {
            return false;
        };
        let surface_id = root_surface.id();
        if let Some(restore) = frontend
            .shell_maximize_restore_geometries
            .remove(&surface_id)
        {
            frontend.restore_window_geometries.remove(&surface_id);
            (bound_geometry_size(restore), WindowAction::Restore)
        } else if client_maximized {
            let restore = frontend
                .restore_window_geometries
                .remove(&surface_id)
                .unwrap_or_else(|| frontend.window_geometry_target(&window));
            (bound_geometry_size(restore), WindowAction::Restore)
        } else {
            let restore = bound_geometry_size(frontend.window_geometry_target(&window));
            let Some(output) = frontend
                .output_for_geometry(restore)
                .map(|entry| entry.output.clone())
            else {
                return false;
            };
            let Some(output_geometry) = frontend.space.output_geometry(&output) else {
                return false;
            };
            let frame = frontend.maximize_work_area(Some(&output), output_geometry);
            let target = shell_content_geometry(frame, shell_draws_server_frame(&window));
            frontend
                .shell_maximize_restore_geometries
                .insert(surface_id, restore);
            (target, WindowAction::Maximize)
        }
    };

    clear_client_geometry_constraints(&window);
    if let Some(toplevel) = window.toplevel() {
        toplevel.with_pending_state(|pending| {
            pending.states.unset(xdg_toplevel::State::Resizing);
            pending.size = Some(target.size);
        });
        toplevel.send_pending_configure();
    }
    state
        .wayland
        .as_mut()
        .expect("missing Wayland frontend")
        .set_window_geometry_target(&window, target);
    state
        .wayland
        .as_mut()
        .expect("missing Wayland frontend")
        .remember_window_placement(&window);
    // State-setting actions are deliberate here. If Flutter is still
    // reconciling a fresh window snapshot, an idempotent Restore/Maximize
    // cannot invert the shell state the compositor just applied.
    queue_window_action_for_window(state, &window, action);
    state.scene_sync.mark_dirty();
    true
}

#[cfg(feature = "flutter")]
/// Toggles a work-area-height alignment while preserving the focused window's
/// current horizontal position and width.
pub(super) fn toggle_shell_vertical_maximize_focused_toplevel(state: &mut RuntimeState) -> bool {
    if let Some(window_id) = focused_local_window(state) {
        let (target, restore) = {
            let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
            let Some(current) = frontend.local_flutter_window_geometry(window_id) else {
                return false;
            };
            if let Some((y, height)) = frontend
                .local_vertical_restore_geometries
                .remove(&window_id)
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
                .local_vertical_restore_geometries
                .insert(window_id, restore);
        }
        queue_local_flutter_window_placement(
            state,
            window_id,
            WindowPlacementPhase::End,
            WindowPlacementChange::Resize,
        );
        state.scene_sync.mark_dirty();
        return true;
    }

    let Some(window) = focused_window(state) else {
        return false;
    };
    let client_fullscreen = if let Some(toplevel) = window.toplevel() {
        toplevel_has_state(toplevel, xdg_toplevel::State::Fullscreen)
    } else if let Some(x11) = window.x11_surface() {
        x11.is_fullscreen()
    } else {
        false
    };
    let (target, restore) = {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        if client_fullscreen || frontend.window_geometry_locked(&window) {
            return true;
        }
        let Some(root_surface) = frontend.window_root_surface(&window) else {
            return false;
        };
        let surface_id = root_surface.id();
        let current = bound_geometry_size(frontend.window_geometry_target(&window));
        if let Some((y, height)) = frontend
            .shell_vertical_restore_geometries
            .remove(&surface_id)
        {
            (
                Rectangle::new(
                    Point::from((current.loc.x, y)),
                    Size::from((current.size.w, height)),
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
            let content = shell_content_geometry(frame, shell_draws_server_frame(&window));
            (
                Rectangle::new(
                    Point::from((current.loc.x, content.loc.y)),
                    Size::from((current.size.w, content.size.h)),
                ),
                Some((surface_id, (current.loc.y, current.size.h))),
            )
        }
    };

    clear_client_geometry_constraints(&window);
    if let Some(toplevel) = window.toplevel() {
        toplevel.with_pending_state(|pending| {
            pending.states.unset(xdg_toplevel::State::Resizing);
            pending.size = Some(target.size);
        });
        toplevel.send_pending_configure();
    }
    let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
    frontend.set_window_geometry_target(&window, target);
    if let Some((surface_id, geometry)) = restore {
        frontend
            .shell_vertical_restore_geometries
            .insert(surface_id, geometry);
    }
    queue_window_placement_for_monitor(
        state,
        &window,
        target,
        target,
        WindowPlacementPhase::End,
        WindowPlacementChange::Resize,
    );
    state.scene_sync.mark_dirty();
    true
}

pub(super) fn toggle_shell_fullscreen_focused_toplevel(state: &mut RuntimeState) -> bool {
    if let Some(window_id) = focused_local_window(state) {
        queue_local_window_action(state, window_id, WindowAction::ToggleFullscreen);
        return true;
    }
    let Some(window) = focused_window(state) else {
        return false;
    };

    let client_fullscreen = if let Some(toplevel) = window.toplevel() {
        toplevel_has_state(toplevel, xdg_toplevel::State::Fullscreen)
    } else if let Some(x11) = window.x11_surface() {
        x11.is_fullscreen()
    } else {
        false
    };

    // SUPER+F is a shell-owned geometry toggle. Do not set the XDG fullscreen
    // state here: doing so asks the client to enter its own fullscreen mode.
    // Flutter tracks the restore frame and sends back a plain ConfigureWindow
    // command with the output-sized (or restored) geometry.
    let transition = {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        let Some(transition) = frontend.toggle_shell_fullscreen_lock(&window, client_fullscreen)
        else {
            return true;
        };
        transition
    };
    match transition {
        super::ShellFullscreenTransition::Blocked => return true,
        super::ShellFullscreenTransition::EnterShell => {
            state
                .wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .remember_window_placement(&window);
        }
        super::ShellFullscreenTransition::ExitShell => {
            let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
            frontend.remember_window_placement(&window);
            if let Some(root) = frontend.window_root_surface(&window) {
                frontend
                    .shell_fullscreen_restore_geometries
                    .remove(&root.id());
            }
        }
        super::ShellFullscreenTransition::ExitClient => {
            exit_client_fullscreen_for_shell_shortcut(state, &window);
            let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
            if let Some(root) = frontend.window_root_surface(&window) {
                frontend
                    .shell_fullscreen_restore_geometries
                    .remove(&root.id());
            }
        }
    }
    queue_window_action_for_window(state, &window, WindowAction::ToggleFullscreen);
    state.scene_sync.mark_dirty();
    true
}

#[cfg(feature = "flutter")]
fn exit_client_fullscreen_for_shell_shortcut(state: &mut RuntimeState, window: &Window) {
    if let Some(toplevel) = window.toplevel().cloned() {
        clear_toplevel_state(state, &toplevel, xdg_toplevel::State::Fullscreen);
        return;
    }

    let Some(x11) = window.x11_surface().cloned() else {
        return;
    };
    if let Err(error) = x11.set_fullscreen(false) {
        warn!(%error, window = x11.window_id(), "could not leave X11 fullscreen for SUPER+F");
    }
    super::xwayland::configure_x11_for_output(state, &x11, false, false);
}

pub(super) fn configure_toplevel_for_output(
    state: &mut RuntimeState,
    surface: &ToplevelSurface,
    requested_output: Option<&wl_output::WlOutput>,
    xdg_state: xdg_toplevel::State,
) -> bool {
    if !surface.wl_surface().is_alive()
        || (xdg_state != xdg_toplevel::State::Fullscreen
            && xdg_state != xdg_toplevel::State::Maximized)
    {
        return false;
    }
    let window = state.wayland.as_ref().and_then(|frontend| {
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
        return false;
    };
    let was_constrained = toplevel_has_state(surface, xdg_toplevel::State::Fullscreen)
        || toplevel_has_state(surface, xdg_toplevel::State::Maximized);
    let (geometry, fullscreen_output) = {
        let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
        let requested = requested_output
            .and_then(Output::from_resource)
            .filter(|candidate| {
                frontend
                    .outputs
                    .iter()
                    .any(|entry| entry.output == *candidate)
            });
        let fullscreen_output = requested.as_ref().and_then(|_| requested_output.cloned());
        let window_geometry = frontend.window_geometry_target(&window);
        let output = requested.or_else(|| {
            frontend
                .output_for_geometry(window_geometry)
                .map(|entry| entry.output.clone())
        });
        let Some(output) = output else {
            return false;
        };
        let Some(geometry) = frontend.space.output_geometry(&output) else {
            return false;
        };
        // Maximized clients get the shell work area; only true fullscreen
        // covers the system bar.
        let geometry = if xdg_state == xdg_toplevel::State::Maximized {
            frontend.maximize_work_area(Some(&output), geometry)
        } else {
            geometry
        };
        (geometry, fullscreen_output)
    };

    let changed = surface.with_pending_state(|pending| {
        let mut changed = pending.states.set(xdg_state);
        changed |= pending.states.unset(xdg_toplevel::State::Resizing);
        pending.size = Some(geometry.size);
        if xdg_state == xdg_toplevel::State::Fullscreen {
            changed |= pending.states.unset(xdg_toplevel::State::Maximized);
            pending.fullscreen_output = fullscreen_output;
        } else if xdg_state == xdg_toplevel::State::Maximized {
            changed |= pending.states.unset(xdg_toplevel::State::Fullscreen);
            pending.fullscreen_output = None;
        }
        changed
    });
    let restore_to_publish = {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        let restore = if !was_constrained {
            client_restore_geometry(
                surface.is_initial_configure_sent(),
                frontend.window_geometry_target(&window),
            )
            .inspect(|restore| {
                frontend
                    .restore_window_geometries
                    .insert(surface.wl_surface().id(), *restore);
            })
        } else {
            None
        };
        frontend.set_window_geometry_target(&window, geometry);
        restore
    };
    #[cfg(feature = "flutter")]
    if let Some(restore) = restore_to_publish {
        queue_client_window_placement_for_monitor(
            state,
            &window,
            restore,
            geometry,
            WindowPlacementPhase::End,
            WindowPlacementChange::Resize,
        );
    }
    #[cfg(not(feature = "flutter"))]
    let _ = restore_to_publish;
    if surface.is_initial_configure_sent() {
        surface.send_configure();
    }
    state.scene_sync.mark_dirty();
    changed
}

pub(super) fn clear_toplevel_state(
    state: &mut RuntimeState,
    surface: &ToplevelSurface,
    xdg_state: xdg_toplevel::State,
) -> bool {
    if !surface.wl_surface().is_alive()
        || (xdg_state != xdg_toplevel::State::Fullscreen
            && xdg_state != xdg_toplevel::State::Maximized)
    {
        return false;
    }
    let window = state.wayland.as_ref().and_then(|frontend| {
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
    let (changed, unconstrained) = surface.with_pending_state(|pending| {
        let changed = pending.states.unset(xdg_state);
        if changed && xdg_state == xdg_toplevel::State::Fullscreen {
            pending.fullscreen_output = None;
        }
        let unconstrained = !pending.states.contains(xdg_toplevel::State::Fullscreen)
            && !pending.states.contains(xdg_toplevel::State::Maximized);
        if changed && unconstrained {
            pending.size = None;
        }
        (changed, unconstrained)
    });
    if changed && unconstrained {
        let surface_id = surface.wl_surface().id();
        let restore = state
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .restore_window_geometries
            .remove(&surface_id)
            .map(bound_geometry_size);
        match (window.as_ref(), restore) {
            (Some(window), Some(restore)) => {
                surface.with_pending_state(|pending| pending.size = Some(restore.size));
                state
                    .wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .set_window_geometry_target(window, restore);
            }
            (Some(window), None) => {
                state
                    .wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .defer_client_sized_window_placement(window);
            }
            (None, _) => {
                state
                    .wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .configured_window_geometries
                    .remove(&surface_id);
            }
        }
    }
    if surface.is_initial_configure_sent() {
        surface.send_configure();
    }
    changed
}

pub(super) fn toplevel_has_state(
    surface: &ToplevelSurface,
    xdg_state: xdg_toplevel::State,
) -> bool {
    if !surface.wl_surface().is_alive() {
        return false;
    }
    with_states(surface.wl_surface(), |states| {
        let Some(attributes) = states.data_map.get::<XdgToplevelSurfaceData>() else {
            return false;
        };
        let attributes = attributes
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        attributes
            .server_pending
            .clone()
            .unwrap_or_else(|| attributes.current_server_state())
            .states
            .contains(xdg_state)
    })
}

#[cfg(test)]
#[path = "window_management/tests.rs"]
mod tests;
