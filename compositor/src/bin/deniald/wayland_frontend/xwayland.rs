use std::os::fd::OwnedFd;

use smithay::desktop::Window;
use smithay::input::pointer::Focus;
use smithay::reexports::wayland_server::Resource;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::utils::{Logical, Point, Rectangle, SERIAL_COUNTER, Size};
use smithay::wayland::seat::WaylandFocus;
use smithay::wayland::selection::SelectionTarget;
use smithay::wayland::selection::data_device::{
    clear_data_device_selection, current_data_device_selection_userdata,
    request_data_device_client_selection, set_data_device_selection,
};
use smithay::wayland::xwayland_keyboard_grab::XWaylandKeyboardGrabHandler;
use smithay::wayland::xwayland_shell::{XWaylandShellHandler, XWaylandShellState};
use smithay::xwayland::xwm::{Reorder, ResizeEdge, WmWindowProperty, XwmId};
use smithay::xwayland::{X11Surface, X11Wm, XwmHandler};
use tracing::{debug, error, info, warn};

#[cfg(feature = "flutter")]
use super::super::PendingWindowEvent;
use super::super::RuntimeState;
#[cfg(feature = "flutter")]
use super::super::wire::WindowAction;
#[cfg(feature = "flutter")]
use super::super::wire::{WindowPlacementChange, WindowPlacementPhase};
#[cfg(feature = "flutter")]
use super::window_management::{
    queue_window_action_for_window, queue_window_placement_for_monitor,
};
use super::{KeyboardFocusTarget, MoveSurfaceGrab, ResizeEdges, X11ResizeSurfaceGrab};

#[cfg(feature = "flutter")]
fn queue_x11_action(state: &mut RuntimeState, surface: &X11Surface, action: WindowAction) {
    if let Some(window) = window_for_x11(state, surface) {
        queue_window_action_for_window(state, &window, action);
    }
}

#[cfg(feature = "flutter")]
fn x11_shell_geometry_locked(state: &RuntimeState, surface: &X11Surface) -> bool {
    let Some(window) = window_for_x11(state, surface) else {
        return false;
    };
    state
        .wayland
        .as_ref()
        .is_some_and(|frontend| frontend.window_geometry_locked(&window))
}

fn window_for_x11(state: &RuntimeState, surface: &X11Surface) -> Option<Window> {
    state
        .wayland
        .as_ref()?
        .space
        .elements()
        .find(|window| window.x11_surface() == Some(surface))
        .cloned()
}

fn root_surface_for_x11(surface: &X11Surface) -> Option<WlSurface> {
    surface.wl_surface()
}

fn constrain_x11_size_to_output(
    mut geometry: Rectangle<i32, Logical>,
    output: Rectangle<i32, Logical>,
) -> Rectangle<i32, Logical> {
    geometry.size = Size::from((
        geometry.size.w.clamp(1, output.size.w.max(1)),
        geometry.size.h.clamp(1, output.size.h.max(1)),
    ));
    geometry
}

fn initial_managed_x11_geometry(
    mut requested: Rectangle<i32, Logical>,
    output: Rectangle<i32, Logical>,
    anchor: Rectangle<i32, Logical>,
) -> Rectangle<i32, Logical> {
    if requested.size.w <= 0 || requested.size.h <= 0 {
        requested.size = Size::from((800, 600));
    }
    requested = constrain_x11_size_to_output(requested, output);
    let desired = Point::<i32, Logical>::from((
        anchor
            .loc
            .x
            .saturating_add((anchor.size.w.saturating_sub(requested.size.w)) / 2),
        anchor
            .loc
            .y
            .saturating_add((anchor.size.h.saturating_sub(requested.size.h)) / 2),
    ));
    let max_x = output
        .loc
        .x
        .saturating_add(output.size.w)
        .saturating_sub(requested.size.w);
    let max_y = output
        .loc
        .y
        .saturating_add(output.size.h)
        .saturating_sub(requested.size.h);
    requested.loc = Point::from((
        desired.x.clamp(output.loc.x, max_x),
        desired.y.clamp(output.loc.y, max_y),
    ));
    requested
}

#[cfg(any(feature = "flutter", test))]
fn normalized_x11_opacity(opacity: Option<u32>) -> f32 {
    opacity.map_or(1.0, |value| value as f32 / u32::MAX as f32)
}

#[cfg(feature = "flutter")]
pub(super) fn x11_window_opacity(surface: &X11Surface) -> f32 {
    normalized_x11_opacity(surface.opacity())
}

fn map_x11_window(state: &mut RuntimeState, surface: X11Surface, override_redirect: bool) {
    if window_for_x11(state, &surface).is_some() {
        return;
    }

    let geometry = surface.last_configure();
    let window = Window::new_x11_window(surface.clone());
    let configured = {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        let configured = if override_redirect {
            geometry
        } else {
            let transient_parent = surface.is_transient_for().and_then(|parent_id| {
                frontend.space.elements().find_map(|candidate| {
                    candidate
                        .x11_surface()
                        .filter(|candidate| candidate.window_id() == parent_id)
                        .map(|_| frontend.window_geometry_target(candidate))
                })
            });
            let pointer = Point::<i32, Logical>::from((
                frontend.pointer_location.x.floor() as i32,
                frontend.pointer_location.y.floor() as i32,
            ));
            let output = transient_parent
                .and_then(|parent| {
                    frontend
                        .output_for_geometry(parent)
                        .map(|entry| entry.logical_geometry)
                })
                .or_else(|| {
                    frontend
                        .outputs
                        .iter()
                        .find(|entry| entry.logical_geometry.contains(pointer))
                        .map(|entry| entry.logical_geometry)
                })
                .or_else(|| frontend.outputs.first().map(|entry| entry.logical_geometry))
                .unwrap_or(frontend.desktop_bounds);
            initial_managed_x11_geometry(geometry, output, transient_parent.unwrap_or(output))
        };
        frontend
            .space
            .map_element(window.clone(), configured.loc, true);
        if !override_redirect {
            for candidate in frontend.space.elements() {
                let changed = candidate.set_activated(candidate == &window);
                if changed && let Some(toplevel) = candidate.toplevel() {
                    toplevel.send_pending_configure();
                }
            }
        }
        configured
    };

    if !override_redirect && let Err(error) = surface.configure(configured) {
        warn!(%error, window = surface.window_id(), "could not configure a new X11 window");
    }
    if !override_redirect {
        // Publish the compositor's bounded geometry immediately. The game's
        // first buffer may still have virtual-desktop dimensions until it
        // handles ConfigureNotify; exposing that stale size to Flutter makes
        // the window span both monitors for at least one scene generation.
        state
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .set_window_geometry_target(&window, configured);
    }

    if !override_redirect {
        let keyboard = state
            .wayland
            .as_ref()
            .expect("missing Wayland frontend")
            .seat
            .get_keyboard()
            .expect("seat has no keyboard");
        keyboard.set_focus(
            state,
            Some(KeyboardFocusTarget::X11(surface.clone())),
            SERIAL_COUNTER.next_serial(),
        );
        #[cfg(feature = "flutter")]
        if let Some(window_id) = state.wayland.as_ref().and_then(|frontend| {
            surface
                .wl_surface()
                .and_then(|root| frontend.surface_id(&root))
        }) {
            state
                .pending_window_events
                .push(PendingWindowEvent::Activated(window_id));
        }
    }
    state.scene_sync.mark_dirty();
    info!(
        window = surface.window_id(),
        override_redirect,
        title = surface.title(),
        class = surface.class(),
        "mapped X11 window"
    );
}

fn unmap_x11_window(state: &mut RuntimeState, surface: &X11Surface) {
    let Some(window) = window_for_x11(state, surface) else {
        return;
    };
    let keyboard = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .seat
        .get_keyboard()
        .expect("seat has no keyboard");
    let was_focused = matches!(
        keyboard.current_focus(),
        Some(KeyboardFocusTarget::X11(ref focused)) if focused == surface
    );
    let next_focus = {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        #[cfg(feature = "flutter")]
        frontend.invalidate_window_input_routes(&window);
        frontend.space.unmap_elem(&window);
        if was_focused {
            let next = frontend
                .space
                .elements()
                .rfind(|candidate| {
                    candidate
                        .x11_surface()
                        .is_none_or(|x11| !x11.is_override_redirect())
                })
                .cloned();
            for candidate in frontend.space.elements() {
                let changed = candidate.set_activated(next.as_ref() == Some(candidate));
                if changed && let Some(toplevel) = candidate.toplevel() {
                    toplevel.send_pending_configure();
                }
            }
            next.and_then(|window| frontend.keyboard_focus_for_window(&window))
        } else {
            None
        }
    };
    if !surface.is_override_redirect()
        && let Err(error) = surface.set_mapped(false)
    {
        warn!(%error, window = surface.window_id(), "could not unmap X11 window");
    }
    if was_focused {
        #[cfg(feature = "flutter")]
        let next_window_id = next_focus.as_ref().and_then(|focus| {
            let root = focus.wl_surface()?;
            state
                .wayland
                .as_ref()
                .and_then(|frontend| frontend.surface_id(&root))
        });
        keyboard.set_focus(state, next_focus, SERIAL_COUNTER.next_serial());
        #[cfg(feature = "flutter")]
        if let Some(window_id) = next_window_id {
            state
                .pending_window_events
                .push(PendingWindowEvent::Activated(window_id));
        }
    }
    state.scene_sync.mark_dirty();
}

fn configure_x11_for_output(state: &mut RuntimeState, surface: &X11Surface, enabled: bool) {
    let Some(window) = window_for_x11(state, surface) else {
        return;
    };
    let target = if enabled {
        let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
        frontend
            .space
            .outputs_for_element(&window)
            .first()
            .or_else(|| frontend.space.outputs().next())
            .and_then(|output| frontend.space.output_geometry(output))
    } else {
        root_surface_for_x11(surface).and_then(|root| {
            state
                .wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .restore_window_geometries
                .remove(&root.id())
        })
    };
    let Some(target) = target else {
        return;
    };

    let restore_to_publish = if enabled && let Some(root) = root_surface_for_x11(surface) {
        let current = state
            .wayland
            .as_ref()
            .expect("missing Wayland frontend")
            .window_geometry_target(&window);
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        match frontend.restore_window_geometries.entry(root.id()) {
            std::collections::hash_map::Entry::Vacant(entry) => {
                entry.insert(current);
                Some(current)
            }
            std::collections::hash_map::Entry::Occupied(_) => None,
        }
    } else {
        None
    };
    state
        .wayland
        .as_mut()
        .expect("missing Wayland frontend")
        .set_window_geometry_target(&window, target);
    #[cfg(feature = "flutter")]
    if let Some(restore) = restore_to_publish {
        queue_window_placement_for_monitor(
            state,
            &window,
            restore,
            target,
            WindowPlacementPhase::End,
            WindowPlacementChange::Resize,
        );
    }
    #[cfg(not(feature = "flutter"))]
    let _ = restore_to_publish;
    state.scene_sync.mark_dirty();
}

impl XWaylandShellHandler for RuntimeState {
    fn xwayland_shell_state(&mut self) -> &mut XWaylandShellState {
        &mut self
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .xwayland_shell_state
    }

    fn surface_associated(&mut self, _xwm: XwmId, wl_surface: WlSurface, surface: X11Surface) {
        let frontend = self.wayland.as_mut().expect("missing Wayland frontend");
        let stable_id = frontend.register_surface(&wl_surface);
        #[cfg(feature = "flutter")]
        let focused = matches!(
            frontend
                .seat
                .get_keyboard()
                .and_then(|keyboard| keyboard.current_focus()),
            Some(KeyboardFocusTarget::X11(ref candidate)) if candidate == &surface
        );
        debug!(
            window = surface.window_id(),
            surface = ?wl_surface.id(),
            "associated X11 window with Wayland surface"
        );
        #[cfg(feature = "flutter")]
        if focused {
            self.pending_window_events
                .push(PendingWindowEvent::Activated(stable_id));
        }
        #[cfg(not(feature = "flutter"))]
        let _ = stable_id;
        self.scene_sync.mark_dirty();
    }
}

impl XWaylandKeyboardGrabHandler for RuntimeState {
    fn keyboard_focus_for_xsurface(&self, surface: &WlSurface) -> Option<KeyboardFocusTarget> {
        let frontend = self.wayland.as_ref()?;
        let window = frontend.window_for_root_surface(surface)?;
        frontend.keyboard_focus_for_window(&window)
    }
}

impl XwmHandler for RuntimeState {
    fn xwm_state(&mut self, _xwm: XwmId) -> &mut X11Wm {
        self.wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .xwm
            .as_mut()
            .expect("missing Xwayland window manager")
    }

    fn new_window(&mut self, _xwm: XwmId, _window: X11Surface) {}

    fn new_override_redirect_window(&mut self, _xwm: XwmId, _window: X11Surface) {}

    fn map_window_request(&mut self, _xwm: XwmId, window: X11Surface) {
        if let Err(error) = window.set_mapped(true) {
            warn!(%error, window = window.window_id(), "could not grant X11 map request");
            return;
        }
        map_x11_window(self, window, false);
    }

    fn mapped_override_redirect_window(&mut self, _xwm: XwmId, window: X11Surface) {
        map_x11_window(self, window, true);
    }

    fn unmapped_window(&mut self, _xwm: XwmId, window: X11Surface) {
        unmap_x11_window(self, &window);
    }

    fn destroyed_window(&mut self, _xwm: XwmId, window: X11Surface) {
        unmap_x11_window(self, &window);
        if let Some(root) = root_surface_for_x11(&window) {
            self.wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .remove_surface_state(&root, false);
        }
    }

    fn configure_request(
        &mut self,
        _xwm: XwmId,
        window: X11Surface,
        _x: Option<i32>,
        _y: Option<i32>,
        width: Option<u32>,
        height: Option<u32>,
        _reorder: Option<Reorder>,
    ) {
        let element = window_for_x11(self, &window);
        #[cfg(feature = "flutter")]
        let shell_geometry_locked = element.as_ref().is_some_and(|element| {
            self.wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .window_geometry_locked(element)
        });
        #[cfg(not(feature = "flutter"))]
        let shell_geometry_locked = false;
        let mut geometry = element.as_ref().map_or_else(
            || window.last_configure(),
            |element| {
                self.wayland
                    .as_ref()
                    .expect("missing Wayland frontend")
                    .window_geometry_target(element)
            },
        );
        if shell_geometry_locked {
            if let Some(element) = element {
                self.wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .set_window_geometry_target(&element, geometry);
            }
            self.scene_sync.mark_dirty();
            return;
        }
        if let Some(width) = width {
            geometry.size.w = i32::try_from(width).unwrap_or(i32::MAX).clamp(1, 16_384);
        }
        if let Some(height) = height {
            geometry.size.h = i32::try_from(height).unwrap_or(i32::MAX).clamp(1, 16_384);
        }
        if let Some(element) = element {
            let output_geometry = {
                let frontend = self.wayland.as_ref().expect("missing Wayland frontend");
                frontend
                    .output_for_geometry(frontend.window_geometry_target(&element))
                    .map(|entry| entry.logical_geometry)
            };
            if let Some(output_geometry) = output_geometry {
                if window.is_fullscreen() || window.is_maximized() {
                    geometry = output_geometry;
                } else {
                    geometry = constrain_x11_size_to_output(geometry, output_geometry);
                }
            }
            self.wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .set_window_geometry_target(&element, geometry);
        } else if let Err(error) = window.configure(geometry) {
            warn!(%error, window = window.window_id(), "could not grant unmapped X11 configure request");
        }
        self.scene_sync.mark_dirty();
    }

    fn configure_notify(
        &mut self,
        _xwm: XwmId,
        window: X11Surface,
        geometry: Rectangle<i32, Logical>,
        _above: Option<u32>,
    ) {
        let Some(element) = window_for_x11(self, &window) else {
            return;
        };
        let frontend = self.wayland.as_mut().expect("missing Wayland frontend");
        if window.is_override_redirect() {
            // Override-redirect geometry belongs to the client. Menus, combo
            // boxes and other popup surfaces must follow it exactly.
            frontend.space.map_element(element, geometry.loc, false);
        } else {
            // ConfigureNotify also follows compositor-issued X11 configures.
            // Feeding that notification back into Space gives the client a
            // second location authority and makes moves drift by frame extents
            // or by a stale pre-grab coordinate. Managed placement is always
            // owned by the compositor.
            let target = frontend.window_geometry_target(&element);
            frontend.space.relocate_element(&element, target.loc);
        }
        self.scene_sync.mark_dirty();
    }

    fn property_notify(&mut self, _xwm: XwmId, _window: X11Surface, _property: WmWindowProperty) {
        self.scene_sync.mark_dirty();
    }

    fn maximize_request(&mut self, _xwm: XwmId, window: X11Surface) {
        #[cfg(feature = "flutter")]
        let shell_geometry_locked = x11_shell_geometry_locked(self, &window);
        let was_fullscreen = window.is_fullscreen();
        let was_maximized = window.is_maximized();
        if was_fullscreen && let Err(error) = window.set_fullscreen(false) {
            warn!(%error, window = window.window_id(), "could not clear X11 fullscreen state");
        }
        if !was_maximized && let Err(error) = window.set_maximized(true) {
            warn!(%error, window = window.window_id(), "could not maximize X11 window");
        }
        #[cfg(feature = "flutter")]
        if shell_geometry_locked {
            self.scene_sync.mark_dirty();
            return;
        }
        if was_maximized && !was_fullscreen {
            return;
        }
        configure_x11_for_output(self, &window, true);
        #[cfg(feature = "flutter")]
        if !shell_geometry_locked {
            if was_fullscreen {
                queue_x11_action(self, &window, WindowAction::Restore);
            }
            queue_x11_action(self, &window, WindowAction::Maximize);
        }
    }

    fn unmaximize_request(&mut self, _xwm: XwmId, window: X11Surface) {
        #[cfg(feature = "flutter")]
        let shell_geometry_locked = x11_shell_geometry_locked(self, &window);
        if !window.is_maximized() {
            return;
        }
        if let Err(error) = window.set_maximized(false) {
            warn!(%error, window = window.window_id(), "could not restore X11 window");
        }
        #[cfg(feature = "flutter")]
        if shell_geometry_locked {
            self.scene_sync.mark_dirty();
            return;
        }
        configure_x11_for_output(self, &window, false);
        #[cfg(feature = "flutter")]
        if !shell_geometry_locked {
            queue_x11_action(self, &window, WindowAction::Restore);
        }
    }

    fn fullscreen_request(&mut self, _xwm: XwmId, window: X11Surface) {
        #[cfg(feature = "flutter")]
        let shell_geometry_locked = x11_shell_geometry_locked(self, &window);
        let was_maximized = window.is_maximized();
        let was_fullscreen = window.is_fullscreen();
        if was_maximized && let Err(error) = window.set_maximized(false) {
            warn!(%error, window = window.window_id(), "could not clear X11 maximized state");
        }
        if !was_fullscreen && let Err(error) = window.set_fullscreen(true) {
            warn!(%error, window = window.window_id(), "could not fullscreen X11 window");
        }
        #[cfg(feature = "flutter")]
        if shell_geometry_locked {
            self.scene_sync.mark_dirty();
            return;
        }
        if was_fullscreen && !was_maximized {
            return;
        }
        configure_x11_for_output(self, &window, true);
        #[cfg(feature = "flutter")]
        if !shell_geometry_locked {
            if was_maximized {
                queue_x11_action(self, &window, WindowAction::Restore);
            }
            queue_x11_action(self, &window, WindowAction::ToggleFullscreen);
        }
    }

    fn unfullscreen_request(&mut self, _xwm: XwmId, window: X11Surface) {
        #[cfg(feature = "flutter")]
        let shell_geometry_locked = x11_shell_geometry_locked(self, &window);
        if !window.is_fullscreen() {
            return;
        }
        if let Err(error) = window.set_fullscreen(false) {
            warn!(%error, window = window.window_id(), "could not leave X11 fullscreen");
        }
        #[cfg(feature = "flutter")]
        if shell_geometry_locked {
            self.scene_sync.mark_dirty();
            return;
        }
        configure_x11_for_output(self, &window, false);
        #[cfg(feature = "flutter")]
        if !shell_geometry_locked {
            queue_x11_action(self, &window, WindowAction::ToggleFullscreen);
        }
    }

    fn minimize_request(&mut self, _xwm: XwmId, _window: X11Surface) {
        #[cfg(feature = "flutter")]
        if let Some(root) = root_surface_for_x11(&_window) {
            self.wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .minimized_windows
                .insert(root.id());
        }
        #[cfg(feature = "flutter")]
        queue_x11_action(self, &_window, WindowAction::Minimize);
        self.scene_sync.mark_dirty();
    }

    fn unminimize_request(&mut self, _xwm: XwmId, window: X11Surface) {
        if let Err(error) = window.set_hidden(false) {
            warn!(%error, window = window.window_id(), "could not restore X11 window");
        }
        #[cfg(feature = "flutter")]
        if let Some(root) = root_surface_for_x11(&window) {
            self.wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .minimized_windows
                .remove(&root.id());
        }
        #[cfg(feature = "flutter")]
        queue_x11_action(self, &window, WindowAction::Restore);
        self.scene_sync.mark_dirty();
    }

    fn resize_request(&mut self, _xwm: XwmId, window: X11Surface, _button: u32, edge: ResizeEdge) {
        if window.is_override_redirect() || window.is_fullscreen() || window.is_maximized() {
            return;
        }
        #[cfg(feature = "flutter")]
        if x11_shell_geometry_locked(self, &window) {
            return;
        }
        let pointer = self
            .wayland
            .as_ref()
            .expect("missing Wayland frontend")
            .seat
            .get_pointer()
            .expect("seat has no pointer");
        let Some(start_data) = pointer.grab_start_data() else {
            debug!(
                window = window.window_id(),
                "ignored X11 resize without a pointer grab"
            );
            return;
        };
        let Some(element) = window_for_x11(self, &window) else {
            return;
        };
        let geometry = self
            .wayland
            .as_ref()
            .expect("missing Wayland frontend")
            .window_geometry_target(&element);
        pointer.set_grab(
            self,
            X11ResizeSurfaceGrab::new(
                start_data,
                element,
                window,
                ResizeEdges::from_x11(edge),
                geometry,
            ),
            SERIAL_COUNTER.next_serial(),
            Focus::Clear,
        );
    }

    fn move_request(&mut self, _xwm: XwmId, window: X11Surface, _button: u32) {
        if window.is_override_redirect() || window.is_fullscreen() || window.is_maximized() {
            return;
        }
        #[cfg(feature = "flutter")]
        if x11_shell_geometry_locked(self, &window) {
            return;
        }
        let pointer = self
            .wayland
            .as_ref()
            .expect("missing Wayland frontend")
            .seat
            .get_pointer()
            .expect("seat has no pointer");
        let Some(start_data) = pointer.grab_start_data() else {
            debug!(
                window = window.window_id(),
                "ignored X11 move without a pointer grab"
            );
            return;
        };
        let Some(element) = window_for_x11(self, &window) else {
            return;
        };
        let initial_location = self
            .wayland
            .as_ref()
            .expect("missing Wayland frontend")
            .space
            .element_location(&element)
            .unwrap_or_default();
        pointer.set_grab(
            self,
            MoveSurfaceGrab::new(start_data, element, initial_location),
            SERIAL_COUNTER.next_serial(),
            Focus::Clear,
        );
    }

    fn allow_selection_access(&mut self, xwm: XwmId, selection: SelectionTarget) -> bool {
        if selection != SelectionTarget::Clipboard {
            return false;
        }
        self.wayland
            .as_ref()
            .and_then(|frontend| frontend.seat.get_keyboard())
            .and_then(|keyboard| keyboard.current_focus())
            .and_then(|focus| focus.wl_surface().map(|surface| surface.into_owned()))
            .and_then(|surface| {
                self.wayland.as_ref()?.space.elements().find_map(|window| {
                    let x11 = window.x11_surface()?;
                    (x11.wl_surface().as_ref() == Some(&surface)).then(|| x11.xwm_id())
                })
            })
            .flatten()
            == Some(xwm)
    }

    fn send_selection(
        &mut self,
        _xwm: XwmId,
        selection: SelectionTarget,
        mime_type: String,
        fd: OwnedFd,
    ) {
        if selection == SelectionTarget::Clipboard
            && let Err(error) = request_data_device_client_selection(
                &self
                    .wayland
                    .as_ref()
                    .expect("missing Wayland frontend")
                    .seat,
                mime_type,
                fd,
            )
        {
            error!(%error, "could not send Wayland clipboard data to Xwayland");
        }
    }

    fn new_selection(&mut self, _xwm: XwmId, selection: SelectionTarget, mime_types: Vec<String>) {
        if selection != SelectionTarget::Clipboard {
            return;
        }
        let frontend = self.wayland.as_ref().expect("missing Wayland frontend");
        set_data_device_selection(&frontend.display_handle, &frontend.seat, mime_types, ());
    }

    fn cleared_selection(&mut self, _xwm: XwmId, selection: SelectionTarget) {
        if selection != SelectionTarget::Clipboard {
            return;
        }
        let frontend = self.wayland.as_ref().expect("missing Wayland frontend");
        if current_data_device_selection_userdata(&frontend.seat).is_some() {
            clear_data_device_selection(&frontend.display_handle, &frontend.seat);
        }
    }

    fn disconnected(&mut self, _xwm: XwmId) {
        if let Some(frontend) = self.wayland.as_mut() {
            frontend.xwm = None;
        }
        warn!("lost the Xwayland window-manager connection");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn managed_x11_window_cannot_start_across_multiple_outputs() {
        let output = Rectangle::new((2560, 0).into(), (2560, 1440).into());
        let requested = Rectangle::new((0, 0).into(), (5120, 1440).into());

        assert_eq!(
            initial_managed_x11_geometry(requested, output, output),
            output
        );
    }

    #[test]
    fn managed_x11_window_is_centered_inside_its_selected_output() {
        let output = Rectangle::new((-1920, 200).into(), (1920, 1080).into());
        let requested = Rectangle::new((0, 0).into(), (800, 600).into());

        assert_eq!(
            initial_managed_x11_geometry(requested, output, output),
            Rectangle::new((-1360, 440).into(), (800, 600).into())
        );
    }

    #[test]
    fn managed_x11_transient_is_centered_on_parent_and_clamped_to_output() {
        let output = Rectangle::new((0, 0).into(), (1920, 1080).into());
        let parent = Rectangle::new((1500, 800).into(), (400, 240).into());
        let requested = Rectangle::new((0, 0).into(), (640, 480).into());

        assert_eq!(
            initial_managed_x11_geometry(requested, output, parent),
            Rectangle::new((1280, 600).into(), (640, 480).into())
        );
    }

    #[test]
    fn x11_opacity_is_normalized_to_the_wire_range() {
        assert_eq!(normalized_x11_opacity(None), 1.0);
        assert_eq!(normalized_x11_opacity(Some(0)), 0.0);
        assert_eq!(normalized_x11_opacity(Some(u32::MAX)), 1.0);
        assert!((normalized_x11_opacity(Some(u32::MAX / 2)) - 0.5).abs() < 0.000_001);
    }

    #[test]
    fn later_x11_configure_is_bounded_to_one_output() {
        let output = Rectangle::new((0, 0).into(), (1920, 1080).into());
        let requested = Rectangle::new((32, 64).into(), (16_384, 8_000).into());

        assert_eq!(
            constrain_x11_size_to_output(requested, output),
            Rectangle::new((32, 64).into(), (1920, 1080).into())
        );
    }
}
