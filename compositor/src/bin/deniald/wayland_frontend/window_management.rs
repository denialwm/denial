#[cfg(feature = "flutter")]
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
use tracing::warn;

#[cfg(feature = "flutter")]
use super::super::PendingWindowEvent;
use super::super::RuntimeState;
use super::super::window_grab::constrain_dimension;
#[cfg(feature = "flutter")]
use super::super::wire::{
    WindowAction, WindowCommand, WindowPlacementChange, WindowPlacementPhase,
};

fn bound_geometry_size(mut geometry: Rectangle<i32, Logical>) -> Rectangle<i32, Logical> {
    geometry.size = Size::from((
        constrain_dimension(geometry.size.w, 1, 0),
        constrain_dimension(geometry.size.h, 1, 0),
    ));
    geometry
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
pub(in super::super) fn apply_window_commands(
    state: &mut RuntimeState,
    commands: impl IntoIterator<Item = WindowCommand>,
) {
    for command in commands {
        let window_id = command.window_id();
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
                let keyboard = state
                    .wayland
                    .as_ref()
                    .expect("missing Wayland frontend")
                    .seat
                    .get_keyboard()
                    .expect("seat has no keyboard");
                let keyboard_focus = state
                    .wayland
                    .as_ref()
                    .expect("missing Wayland frontend")
                    .keyboard_focus_for_window(&window);
                {
                    let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                    frontend.minimized_windows.remove(&root_surface.id());
                    if let Some(x11) = window.x11_surface()
                        && let Err(error) = x11.set_hidden(false)
                    {
                        warn!(%error, window_id, "could not restore focused X11 window");
                    }
                    frontend.raise_window(&window, true);
                    for candidate in frontend.space.elements() {
                        let changed = candidate.set_activated(candidate == &window);
                        if let Some(candidate) = candidate.toplevel()
                            && changed
                            && candidate.wl_surface().is_alive()
                        {
                            candidate.send_pending_configure();
                        }
                    }
                }
                keyboard.set_focus(state, keyboard_focus, SERIAL_COUNTER.next_serial());
                state
                    .pending_window_events
                    .push(PendingWindowEvent::Activated(window_id));
                state.scene_sync.mark_dirty();
            }
            WindowCommand::Configure { geometry, .. } => {
                let requested_size = Size::<i32, Logical>::from((
                    geometry.width.round() as i32,
                    geometry.height.round() as i32,
                ));
                let (minimum, maximum) = if let Some(toplevel) = window.toplevel() {
                    if toplevel_has_state(toplevel, xdg_toplevel::State::Resizing) {
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
                let size = Size::<i32, Logical>::from((
                    constrain_dimension(requested_size.w, minimum.w, maximum.w),
                    constrain_dimension(requested_size.h, minimum.h, maximum.h),
                ));
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
                clear_client_geometry_constraints(&window);
                state
                    .wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .restore_window_geometries
                    .remove(&root_surface.id());
                if let Some(toplevel) = window.toplevel() {
                    toplevel.with_pending_state(|pending| pending.size = Some(size));
                    toplevel.send_pending_configure();
                }
                state
                    .wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .set_window_geometry_target(&window, target);
                state.scene_sync.mark_dirty();
            }
        }
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
    let placement = {
        let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
        let Some(placement) =
            frontend.window_placement(window, geometry, monitor_geometry, phase, change)
        else {
            return;
        };
        placement
    };
    state
        .pending_window_events
        .push(PendingWindowEvent::Placement(placement));
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
            .is_some_and(|window| frontend.window_geometry_locked(window))
    })
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
pub(super) fn minimize_focused_toplevel(state: &mut RuntimeState) -> bool {
    let Some(window) = focused_window(state) else {
        return false;
    };
    let Some(root) = state
        .wayland
        .as_ref()
        .and_then(|frontend| frontend.window_root_surface(&window))
    else {
        return false;
    };
    state
        .wayland
        .as_mut()
        .expect("missing Wayland frontend")
        .minimized_windows
        .insert(root.id());
    // Minimization is a shell visibility state. X11Surface::set_hidden(true)
    // advertises IconicState/_NET_WM_STATE_HIDDEN and explicitly permits the
    // application to stop rendering, which would make its live Flutter texture
    // stale or black. Keep the client mapped and producing frames.
    queue_window_action_for_window(state, &window, WindowAction::Minimize);
    state.scene_sync.mark_dirty();
    true
}

#[cfg(feature = "flutter")]
pub(super) fn close_focused_toplevel(state: &RuntimeState) -> bool {
    let Some(window) = focused_window(state) else {
        return false;
    };
    if let Some(toplevel) = window.toplevel() {
        toplevel.send_close();
        true
    } else if let Some(x11) = window.x11_surface() {
        if let Err(error) = x11.close() {
            warn!(%error, "could not close focused X11 window");
            return false;
        }
        true
    } else {
        false
    }
}

#[cfg(feature = "flutter")]
pub(super) fn toggle_shell_fullscreen_focused_toplevel(state: &mut RuntimeState) -> bool {
    let Some(window) = focused_window(state) else {
        return false;
    };

    // SUPER+F is a shell-owned geometry toggle. Do not set the XDG fullscreen
    // state here: doing so asks the client to enter its own fullscreen mode.
    // Flutter tracks the restore frame and sends back a plain ConfigureWindow
    // command with the output-sized (or restored) geometry.
    state
        .wayland
        .as_mut()
        .expect("missing Wayland frontend")
        .toggle_shell_fullscreen_lock(&window);
    queue_window_action_for_window(state, &window, WindowAction::ToggleFullscreen);
    state.scene_sync.mark_dirty();
    true
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
            let restore = bound_geometry_size(frontend.window_geometry_target(&window));
            frontend
                .restore_window_geometries
                .insert(surface.wl_surface().id(), restore);
            Some(restore)
        } else {
            None
        };
        frontend.set_window_geometry_target(&window, geometry);
        restore
    };
    #[cfg(feature = "flutter")]
    if let Some(restore) = restore_to_publish {
        queue_window_placement_for_monitor(
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
        match (window, restore) {
            (Some(window), Some(restore)) => {
                surface.with_pending_state(|pending| pending.size = Some(restore.size));
                state
                    .wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .set_window_geometry_target(&window, restore);
            }
            _ => {
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
mod tests {
    use super::*;
    use smithay::utils::Point;

    #[test]
    fn restore_geometry_keeps_location_but_bounds_hostile_extents() {
        let bounded = bound_geometry_size(Rectangle::new(
            Point::from((i32::MIN, i32::MAX)),
            Size::from((i32::MAX, 0)),
        ));
        assert_eq!(bounded.loc, Point::from((i32::MIN, i32::MAX)));
        assert_eq!(bounded.size, Size::from((16_384, 1)));
    }
}
