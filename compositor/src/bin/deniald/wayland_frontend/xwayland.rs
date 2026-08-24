use std::ffi::OsStr;
use std::os::fd::OwnedFd;

use denial_core::topology::SCALE_BASE;
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
use smithay::xwayland::xwm::settings::Value as XSettingValue;
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
use super::window_management::activate_window;
#[cfg(feature = "flutter")]
use super::window_management::{
    queue_restored_window_state, queue_window_action_for_window,
    queue_window_placement_for_monitor, release_window_focus,
};
use super::{
    KeyboardFocusTarget, MoveSurfaceGrab, ResizeEdges, WindowIdentity, X11ResizeSurfaceGrab,
    clamp_window_geometry, constrain_dimension,
};

const XWAYLAND_BASE_DPI: u32 = 96;
const XWAYLAND_SCALE_MODE_ENV: &str = "DENIAL_XWAYLAND_SCALE_MODE";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum XWaylandScaleMode {
    Fractional,
    Integer,
}

impl XWaylandScaleMode {
    fn parse(value: Option<&OsStr>) -> Option<Self> {
        match value.and_then(OsStr::to_str).map(str::trim) {
            None | Some("") | Some("fractional") => Some(Self::Fractional),
            Some("integer") => Some(Self::Integer),
            Some(_) => None,
        }
    }
}

pub(super) fn scale_mode_from_environment() -> XWaylandScaleMode {
    let value = std::env::var_os(XWAYLAND_SCALE_MODE_ENV);
    match XWaylandScaleMode::parse(value.as_deref()) {
        Some(mode) => mode,
        None => {
            warn!(
                variable = XWAYLAND_SCALE_MODE_ENV,
                value = ?value,
                "ignored invalid Xwayland scale mode; expected fractional or integer"
            );
            XWaylandScaleMode::Fractional
        }
    }
}

pub(super) fn scale_for_engine(engine_scale_120: u32, mode: XWaylandScaleMode) -> u32 {
    let scale_120 = engine_scale_120.max(SCALE_BASE);
    match mode {
        XWaylandScaleMode::Fractional => scale_120,
        XWaylandScaleMode::Integer => scale_120.div_ceil(SCALE_BASE).saturating_mul(SCALE_BASE),
    }
}

pub(super) fn client_scale(scale_120: u32) -> f64 {
    f64::from(scale_120.max(SCALE_BASE)) / f64::from(SCALE_BASE)
}

fn scaled_dpi(scale_120: u32, integer_scale: u32) -> u32 {
    let numerator = u64::from(XWAYLAND_BASE_DPI).saturating_mul(u64::from(scale_120));
    let denominator = u64::from(SCALE_BASE).saturating_mul(u64::from(integer_scale.max(1)));
    let rounded = numerator.saturating_add(denominator / 2) / denominator;
    u32::try_from(rounded).unwrap_or(u32::MAX)
}

pub(super) fn dpi(scale_120: u32) -> u32 {
    scaled_dpi(scale_120.max(SCALE_BASE), 1)
}

fn gdk_window_scale(scale_120: u32) -> u32 {
    scale_120.max(SCALE_BASE) / SCALE_BASE
}

fn gdk_unscaled_dpi(scale_120: u32) -> u32 {
    scaled_dpi(scale_120.max(SCALE_BASE), gdk_window_scale(scale_120))
}

pub(super) fn publish_dpi(
    xwm: &mut X11Wm,
    scale_120: u32,
) -> Result<(), smithay::xwayland::xwm::SettingsError> {
    let xft_dpi = i32::try_from(dpi(scale_120).saturating_mul(1024)).unwrap_or(i32::MAX);
    let unscaled_dpi =
        i32::try_from(gdk_unscaled_dpi(scale_120).saturating_mul(1024)).unwrap_or(i32::MAX);
    let window_scale = i32::try_from(gdk_window_scale(scale_120)).unwrap_or(i32::MAX);
    xwm.set_xsettings(
        [
            ("Gdk/WindowScalingFactor", window_scale),
            ("Gdk/UnscaledDPI", unscaled_dpi),
            ("Xft/DPI", xft_dpi),
        ]
        .into_iter()
        .map(|(name, value)| (name.to_owned(), XSettingValue::Integer(value))),
    )
}

impl super::WaylandFrontend {
    pub(super) fn set_xwayland_scale(
        &mut self,
        engine_scale_120: u32,
    ) -> Result<bool, Box<dyn std::error::Error>> {
        let scale_120 = scale_for_engine(engine_scale_120, self.xwayland_scale_mode);
        if scale_120 == self.xwayland_scale_120 {
            return Ok(false);
        }

        self.xwayland_client
            .get_data::<smithay::xwayland::XWaylandClientData>()
            .ok_or("Xwayland client is missing compositor state")?
            .compositor_state
            .set_client_scale(client_scale(scale_120));
        if let Some(xwm) = self.xwm.as_mut() {
            publish_dpi(xwm, scale_120)?;
        }
        self.xwayland_scale_120 = scale_120;
        Ok(true)
    }

    pub(super) fn reconfigure_x11_for_scale(&self) -> Result<(), Box<dyn std::error::Error>> {
        for window in self.space.elements() {
            let Some(surface) = window.x11_surface() else {
                continue;
            };
            if !surface.is_override_redirect() {
                surface.configure(self.window_geometry_target(window))?;
            }
        }
        Ok(())
    }
}

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
        .is_some_and(|frontend| frontend.window_shell_fullscreen_locked(&window))
}

#[cfg(feature = "flutter")]
fn reassert_exact_x11_geometry(state: &mut RuntimeState, surface: &X11Surface) -> bool {
    let Some(window) = window_for_x11(state, surface) else {
        return false;
    };
    let exact = state
        .wayland
        .as_ref()
        .and_then(|frontend| frontend.exact_window_geometry(&window));
    let Some(exact) = exact else {
        return false;
    };
    if surface.is_fullscreen()
        && let Err(error) = surface.set_fullscreen(false)
    {
        warn!(%error, window = surface.window_id(), "could not clear exact X11 fullscreen state");
    }
    if surface.is_maximized()
        && let Err(error) = surface.set_maximized(false)
    {
        warn!(%error, window = surface.window_id(), "could not clear exact X11 maximized state");
    }
    state
        .wayland
        .as_mut()
        .expect("missing Wayland frontend")
        .set_window_geometry_target(&window, exact);
    state.scene_sync.mark_dirty();
    true
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

fn x11_monitor_geometry(
    geometry: Rectangle<i32, Logical>,
    physical_outputs: impl IntoIterator<Item = Rectangle<i32, Logical>>,
) -> Option<Rectangle<i32, Logical>> {
    let center = Point::from((
        geometry.loc.x.saturating_add(geometry.size.w / 2),
        geometry.loc.y.saturating_add(geometry.size.h / 2),
    ));
    super::choose_popup_output(physical_outputs, center, geometry)
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
    if override_redirect && surface.class() == "denial-xembed-tray" {
        info!(
            window = surface.window_id(),
            "mapped the hidden XEmbed tray host"
        );
        return;
    }

    let geometry = surface.last_configure();
    let window = Window::new_x11_window(surface.clone());
    let (configured, restored_record) = {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        let (configured, restored_record) = if override_redirect {
            (geometry, None)
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
            let initial =
                initial_managed_x11_geometry(geometry, output, transient_parent.unwrap_or(output));
            let identity = WindowIdentity::x11(&surface.class());
            let restored = identity.and_then(|identity| {
                transient_parent
                    .is_none()
                    .then(|| frontend.restored_placement_for_identity(&identity, output))
                    .flatten()
                    .map(|restored| (identity, restored))
            });
            match restored {
                Some((identity, mut restored)) => {
                    let minimum = surface.min_size().unwrap_or_else(|| Size::from((1, 1)));
                    let maximum = surface.max_size().unwrap_or_else(|| Size::from((0, 0)));
                    restored.geometry.size = Size::from((
                        constrain_dimension(restored.geometry.size.w, minimum.w, maximum.w),
                        constrain_dimension(restored.geometry.size.h, minimum.h, maximum.h),
                    ));
                    if let Some(output) = frontend.output_for_geometry(restored.geometry) {
                        restored.geometry =
                            clamp_window_geometry(restored.geometry, output.logical_geometry);
                    }
                    #[cfg(feature = "flutter")]
                    let target = frontend.apply_restored_window_state(
                        &window,
                        restored.geometry,
                        restored.state,
                    );
                    #[cfg(not(feature = "flutter"))]
                    let target = restored.geometry;
                    (target, Some((identity, restored)))
                }
                None => (initial, None),
            }
        };
        frontend
            .space
            .map_element(window.clone(), configured.loc, true);
        frontend.update_window_output_membership(&window);
        if !override_redirect {
            for candidate in frontend.space.elements() {
                let changed = candidate.set_activated(candidate == &window);
                if changed && let Some(toplevel) = candidate.toplevel() {
                    toplevel.send_pending_configure();
                }
            }
        }
        (configured, restored_record)
    };

    if let Some((identity, restored)) = restored_record.as_ref() {
        info!(
            backend = ?identity.backend(),
            app_id = identity.app_id(),
            x = configured.loc.x,
            y = configured.loc.y,
            width = configured.size.w,
            height = configured.size.h,
            maximized = restored.state.maximized,
            fullscreen = restored.state.fullscreen,
            "restored saved window placement"
        );
    }

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
        #[cfg(feature = "flutter")]
        if let Some((_, restored)) = restored_record {
            queue_restored_window_state(state, &window, restored, configured);
        }
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
        frontend.remember_window_placement(&window);
        #[cfg(feature = "flutter")]
        if let Some(root) = frontend.window_root_surface(&window) {
            frontend.remove_window_output_membership(&root);
        }
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

pub(super) fn configure_x11_for_output(
    state: &mut RuntimeState,
    surface: &X11Surface,
    enabled: bool,
    work_area: bool,
) {
    let Some(window) = window_for_x11(state, surface) else {
        return;
    };
    let target = if enabled {
        let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
        let geometry = frontend.window_geometry_target(&window);
        // `Space` also contains `denial-atlas`, the rendering-only Flutter
        // canvas. X11 clients must only ever receive a physical monitor's
        // logical geometry for maximized and fullscreen windows. Maximize
        // additionally stays out of the shell system-bar strip.
        x11_monitor_geometry(
            geometry,
            frontend.outputs.iter().map(|entry| entry.logical_geometry),
        )
        .map(|monitor| {
            if work_area {
                frontend.maximize_work_area(None, monitor)
            } else {
                monitor
            }
        })
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
    state
        .wayland
        .as_mut()
        .expect("missing Wayland frontend")
        .remember_window_placement(&window);
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
        let mapped_window = {
            frontend
                .space
                .elements()
                .find(|window| window.x11_surface() == Some(&surface))
                .cloned()
        };
        if let Some(window) = mapped_window {
            // Xwayland may map the X11 window before its wl_surface becomes
            // associated. The initial map cannot index a root surface in that
            // ordering, so finish the one-time membership update here.
            frontend.update_window_output_membership(&window);
        }
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
                x11_monitor_geometry(
                    frontend.window_geometry_target(&element),
                    frontend.outputs.iter().map(|entry| entry.logical_geometry),
                )
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
            frontend
                .space
                .map_element(element.clone(), geometry.loc, false);
        } else {
            // ConfigureNotify also follows compositor-issued X11 configures.
            // Feeding that notification back into Space gives the client a
            // second location authority and makes moves drift by frame extents
            // or by a stale pre-grab coordinate. Managed placement is always
            // owned by the compositor.
            let target = frontend.window_geometry_target(&element);
            frontend.space.relocate_element(&element, target.loc);
        }
        frontend.update_window_output_membership(&element);
        self.scene_sync.mark_dirty();
    }

    fn property_notify(&mut self, _xwm: XwmId, _window: X11Surface, _property: WmWindowProperty) {
        self.scene_sync.mark_dirty();
    }

    fn maximize_request(&mut self, _xwm: XwmId, window: X11Surface) {
        #[cfg(feature = "flutter")]
        if reassert_exact_x11_geometry(self, &window) {
            return;
        }
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
        configure_x11_for_output(self, &window, true, true);
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
        if reassert_exact_x11_geometry(self, &window) {
            return;
        }
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
        configure_x11_for_output(self, &window, false, false);
        #[cfg(feature = "flutter")]
        if !shell_geometry_locked {
            queue_x11_action(self, &window, WindowAction::Restore);
        }
    }

    fn fullscreen_request(&mut self, _xwm: XwmId, window: X11Surface) {
        #[cfg(feature = "flutter")]
        if reassert_exact_x11_geometry(self, &window) {
            return;
        }
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
        configure_x11_for_output(self, &window, true, false);
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
        if reassert_exact_x11_geometry(self, &window) {
            return;
        }
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
        configure_x11_for_output(self, &window, false, false);
        #[cfg(feature = "flutter")]
        if !shell_geometry_locked {
            queue_x11_action(self, &window, WindowAction::ToggleFullscreen);
        }
    }

    fn minimize_request(&mut self, _xwm: XwmId, _window: X11Surface) {
        #[cfg(feature = "flutter")]
        let window = window_for_x11(self, &_window);
        #[cfg(feature = "flutter")]
        if let Some(root) = root_surface_for_x11(&_window) {
            self.wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .set_surface_minimized(root.id(), true);
        }
        #[cfg(feature = "flutter")]
        if let Some(window) = window.as_ref() {
            release_window_focus(self, window);
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
                .set_surface_minimized(root.id(), false);
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

    fn active_window_request(
        &mut self,
        _xwm: XwmId,
        window: X11Surface,
        _timestamp: u32,
        _currently_active_window: Option<X11Surface>,
    ) {
        if !self.client_activation_permitted() {
            debug!(
                window = window.window_id(),
                "rejected X11 activation while locked"
            );
            return;
        }
        let Some(window) = window_for_x11(self, &window) else {
            return;
        };
        if activate_window(self, &window, SERIAL_COUNTER.next_serial()) {
            debug!("honored X11 active-window request");
        }
    }

    fn allow_selection_access(&mut self, xwm: XwmId, selection: SelectionTarget) -> bool {
        #[cfg(feature = "flutter")]
        if self.secure_session_locked() {
            return false;
        }
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
        #[cfg(feature = "flutter")]
        if self.secure_session_locked() {
            return;
        }
        if selection != SelectionTarget::Clipboard {
            return;
        }
        let retained_item_id = current_data_device_selection_userdata(
            &self
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .seat,
        )
        .and_then(|selection| selection.history_item_id());
        if let Some(item_id) = retained_item_id {
            super::clipboard_io::send_retained_selection(self, item_id, &mime_type, fd);
            return;
        }
        if let Err(error) = request_data_device_client_selection(
            &self
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .seat,
            mime_type,
            fd,
        ) {
            error!(%error, "could not send Wayland clipboard data to Xwayland");
        }
    }

    fn new_selection(&mut self, _xwm: XwmId, selection: SelectionTarget, mime_types: Vec<String>) {
        #[cfg(feature = "flutter")]
        if self.secure_session_locked() {
            return;
        }
        if selection != SelectionTarget::Clipboard {
            return;
        }
        super::clipboard_io::observe_selection(
            self,
            super::clipboard_io::CaptureOwner::Xwayland,
            &mime_types,
        );
        let frontend = self.wayland.as_ref().expect("missing Wayland frontend");
        set_data_device_selection(
            &frontend.display_handle,
            &frontend.seat,
            mime_types,
            super::super::clipboard::ClipboardSelection::Xwayland,
        );
    }

    fn cleared_selection(&mut self, _xwm: XwmId, selection: SelectionTarget) {
        #[cfg(feature = "flutter")]
        if self.secure_session_locked() {
            return;
        }
        if selection != SelectionTarget::Clipboard {
            return;
        }
        let xwayland_owned = self
            .wayland
            .as_ref()
            .and_then(|frontend| current_data_device_selection_userdata(&frontend.seat))
            .is_some_and(|selection| selection.is_xwayland());
        if xwayland_owned {
            super::clipboard_io::observe_selection(
                self,
                super::clipboard_io::CaptureOwner::Xwayland,
                &[],
            );
            let frontend = self.wayland.as_ref().expect("missing Wayland frontend");
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
#[path = "xwayland/tests.rs"]
mod tests;
