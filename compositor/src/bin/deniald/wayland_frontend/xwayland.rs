use std::ffi::{OsStr, OsString};
use std::os::fd::OwnedFd;
use std::process::Stdio;

use denial_core::topology::SCALE_BASE;
use smithay::desktop::Window;
use smithay::input::pointer::Focus;
use smithay::reexports::calloop::EventLoop;
use smithay::reexports::wayland_server::Resource;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::reexports::wayland_server::{Client, DisplayHandle};
use smithay::utils::{Logical, Point, Rectangle, SERIAL_COUNTER, Size};
use smithay::wayland::compositor::CompositorClientState;
use smithay::wayland::seat::WaylandFocus;
use smithay::wayland::selection::SelectionTarget;
use smithay::wayland::selection::data_device::{
    clear_data_device_selection, current_data_device_selection_userdata,
    request_data_device_client_selection, set_data_device_selection,
};
use smithay::wayland::xwayland_keyboard_grab::{
    XWaylandKeyboardGrabHandler, XWaylandKeyboardGrabState,
};
use smithay::wayland::xwayland_shell::{XWaylandShellHandler, XWaylandShellState};
use smithay::xwayland::xwm::settings::Value as XSettingValue;
use smithay::xwayland::xwm::{Reorder, ResizeEdge, WmWindowProperty, XwmId};
use smithay::xwayland::{
    X11Surface, X11Wm, XWayland, XWaylandClientData, XWaylandEvent, XwmHandler,
};
use tracing::{debug, error, info, warn};

#[cfg(feature = "flutter")]
use super::super::PendingWindowEvent;
use super::super::RuntimeState;
use super::focus::request_keyboard_focus;
use super::window_management::activate_window;
use super::window_management::{
    ManagedClientStateRequest, apply_managed_client_state_request, managed_client_grab_allowed,
};
#[cfg(feature = "flutter")]
use super::window_management::{apply_managed_minimize, queue_restored_window_state};
use super::{
    KeyboardFocusTarget, MoveSurfaceGrab, ResizeEdges, ResizeSurfaceGrab, WindowIdentity,
    centered_transient_geometry, clamp_window_geometry, constrain_dimension,
};

const XWAYLAND_BASE_DPI: u32 = 96;
const XWAYLAND_SCALE_MODE_ENV: &str = "DENIAL_XWAYLAND_SCALE_MODE";

/// The complete optional Xwayland subsystem.
///
/// Keeping every X11-owned resource behind this boundary makes runtime
/// disablement an absent value and compile-time disablement an empty facade.
pub(crate) struct XWaylandState {
    active: Option<ActiveXWayland>,
}

struct ActiveXWayland {
    shell_state: XWaylandShellState,
    _keyboard_grab_state: XWaylandKeyboardGrabState,
    xwm: Option<X11Wm>,
    #[cfg(feature = "flutter")]
    xembed_tray: Option<super::super::xembed_tray::XEmbedTray>,
    client: Client,
    scale_mode: XWaylandScaleMode,
    scale_120: u32,
    display: u32,
}

impl XWaylandState {
    pub(super) fn start(
        enabled: bool,
        event_loop: &mut EventLoop<'static, RuntimeState>,
        display_handle: &DisplayHandle,
        engine_scale_120: u32,
        settings: &super::SettingsManager,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        if !enabled {
            info!("Xwayland disabled for this session");
            return Ok(Self { active: None });
        }

        let shell_state = XWaylandShellState::new::<RuntimeState>(display_handle);
        let keyboard_grab_state = XWaylandKeyboardGrabState::new::<RuntimeState>(display_handle);
        let scale_mode = scale_mode_from_environment();
        let scale_120 = scale_for_engine(engine_scale_120, scale_mode);
        let xwayland_args = ["-dpi".to_owned(), dpi(scale_120).to_string()];
        let cursor_size = settings.cursor_size();
        let mut environment = vec![(
            OsString::from("XCURSOR_SIZE"),
            OsString::from(cursor_size.to_string()),
        )];
        #[cfg(feature = "flutter")]
        if let Some(cursor_environment) = crate::xcursor_sentinel::environment() {
            environment.extend(
                cursor_environment
                    .into_iter()
                    .map(|(name, value)| (OsString::from(name), OsString::from(value))),
            );
        }

        // Smithay has no pre-exec hook here. Temporarily widen this spawning
        // thread, synchronized with our guard, so Xwayland gets the app domain.
        let (source, client) = crate::cpu_scheduling::with_application_affinity(|| {
            XWayland::spawn(
                display_handle,
                None,
                environment,
                xwayland_args,
                true,
                Stdio::null(),
                Stdio::null(),
                |_| {},
            )
        })?;
        client
            .get_data::<XWaylandClientData>()
            .expect("Xwayland client is missing compositor state")
            .compositor_state
            .set_client_scale(client_scale(scale_120));
        let xdisplay = source.display_number();
        let xwm_loop_handle = event_loop.handle();
        let xwm_display_handle = display_handle.clone();
        let xwm_client = client.clone();
        event_loop
            .handle()
            .insert_source(source, move |event, _, state| match event {
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
                        let cursor_size = frontend.settings.cursor_size();
                        let active = frontend
                            .xwayland
                            .active
                            .as_mut()
                            .expect("Xwayland became ready after being disabled");
                        if let Err(error) =
                            publish_settings(&mut xwm, active.scale_120, cursor_size)
                        {
                            error!(%error, "could not publish Xwayland settings");
                        }
                        active.xwm = Some(xwm);
                        #[cfg(feature = "flutter")]
                        match super::super::xembed_tray::XEmbedTray::start(OsString::from(format!(
                            ":{}",
                            active.display
                        ))) {
                            Ok(tray) => active.xembed_tray = Some(tray),
                            Err(error) => {
                                warn!(%error, "could not start the XEmbed tray host")
                            }
                        }
                        info!(
                            display = %format_args!(":{display_number}"),
                            scale = client_scale(active.scale_120),
                            scale_mode = ?active.scale_mode,
                            dpi = dpi(active.scale_120),
                            cursor_size,
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

        Ok(Self {
            active: Some(ActiveXWayland {
                shell_state,
                _keyboard_grab_state: keyboard_grab_state,
                xwm: None,
                #[cfg(feature = "flutter")]
                xembed_tray: None,
                client,
                scale_mode,
                scale_120,
                display: xdisplay,
            }),
        })
    }

    pub(super) fn display_name(&self) -> Option<OsString> {
        self.active
            .as_ref()
            .map(|active| OsString::from(format!(":{}", active.display)))
    }

    pub(super) fn raise_windows(&mut self, windows: &[Window]) {
        let Some(xwm) = self.active.as_mut().and_then(|active| active.xwm.as_mut()) else {
            return;
        };
        for window in windows {
            let Some(surface) = window.x11_surface() else {
                continue;
            };
            // Override-redirect popups are absent from XWM's EWMH stack and
            // are already placed by Xwayland at map time.
            if surface.is_override_redirect() {
                continue;
            }
            if let Err(error) = xwm.raise_window(surface) {
                warn!(
                    %error,
                    window = surface.window_id(),
                    "could not synchronize X11 stacking order"
                );
            }
        }
    }

    pub(super) fn publish_selection(
        &mut self,
        selection: SelectionTarget,
        mime_types: Option<Vec<String>>,
    ) -> Result<(), String> {
        let Some(xwm) = self.active.as_mut().and_then(|active| active.xwm.as_mut()) else {
            return Ok(());
        };
        xwm.new_selection(selection, mime_types)
            .map_err(|error| error.to_string())
    }

    pub(super) fn send_selection(
        &mut self,
        selection: SelectionTarget,
        mime_type: String,
        fd: OwnedFd,
    ) -> Result<(), String> {
        self.active
            .as_mut()
            .and_then(|active| active.xwm.as_mut())
            .ok_or_else(|| "Xwayland clipboard owner disappeared".to_owned())?
            .send_selection(selection, mime_type, fd)
            .map_err(|error| error.to_string())
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn take_xembed_event_signal(&self) -> bool {
        self.active
            .as_ref()
            .and_then(|active| active.xembed_tray.as_ref())
            .is_some_and(super::super::xembed_tray::XEmbedTray::take_event_signal)
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn try_xembed_event(&self) -> Option<crate::xembed_tray_protocol::XEmbedTrayEvent> {
        self.active
            .as_ref()
            .and_then(|active| active.xembed_tray.as_ref())
            .and_then(super::super::xembed_tray::XEmbedTray::try_event)
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn invoke_xembed(
        &self,
        command: crate::xembed_tray_protocol::XEmbedTrayCommand,
    ) -> bool {
        self.active
            .as_ref()
            .and_then(|active| active.xembed_tray.as_ref())
            .is_some_and(|tray| tray.invoke(command))
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn request_xembed_replay(&self) {
        if let Some(tray) = self
            .active
            .as_ref()
            .and_then(|active| active.xembed_tray.as_ref())
        {
            tray.request_replay();
        }
    }
}

pub(super) fn client_compositor_state(client: &Client) -> Option<&CompositorClientState> {
    client
        .get_data::<XWaylandClientData>()
        .map(|data| &data.compositor_state)
}

pub(super) fn is_client(client: &Client) -> bool {
    client.get_data::<XWaylandClientData>().is_some()
}

pub(super) fn surface_client_scale(surface: &WlSurface) -> Option<f64> {
    surface.client().and_then(|client| {
        client
            .get_data::<XWaylandClientData>()
            .map(|data| data.compositor_state.client_scale())
    })
}

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

pub(super) fn publish_settings(
    xwm: &mut X11Wm,
    scale_120: u32,
    cursor_size: u32,
) -> Result<(), smithay::xwayland::xwm::SettingsError> {
    let xft_dpi = i32::try_from(dpi(scale_120).saturating_mul(1024)).unwrap_or(i32::MAX);
    let unscaled_dpi =
        i32::try_from(gdk_unscaled_dpi(scale_120).saturating_mul(1024)).unwrap_or(i32::MAX);
    let window_scale = i32::try_from(gdk_window_scale(scale_120)).unwrap_or(i32::MAX);
    let mut settings = vec![
        (
            "Gdk/WindowScalingFactor".to_owned(),
            XSettingValue::Integer(window_scale),
        ),
        (
            "Gdk/UnscaledDPI".to_owned(),
            XSettingValue::Integer(unscaled_dpi),
        ),
        (
            "Gtk/CursorThemeSize".to_owned(),
            XSettingValue::Integer(i32::try_from(cursor_size).unwrap_or(i32::MAX)),
        ),
        // XSettings is visible only to GTK's X11 backend. Publishing the XIM
        // arm here leaves native Wayland clients on GTK's automatic context.
        (
            "Gtk/IMModule".to_owned(),
            XSettingValue::String(
                crate::settings::x11_gtk_input_method_backend_fallback().to_owned(),
            ),
        ),
        ("Xft/DPI".to_owned(), XSettingValue::Integer(xft_dpi)),
    ];
    #[cfg(feature = "flutter")]
    if crate::xcursor_sentinel::is_active() {
        settings.push((
            "Gtk/CursorThemeName".to_owned(),
            XSettingValue::String(crate::xcursor_sentinel::THEME_NAME.to_owned()),
        ));
    }
    xwm.set_xsettings(settings.into_iter())
}

impl super::WaylandFrontend {
    pub(super) fn set_xwayland_scale(
        &mut self,
        engine_scale_120: u32,
    ) -> Result<bool, Box<dyn std::error::Error>> {
        let Some(active) = self.xwayland.active.as_mut() else {
            return Ok(false);
        };
        let scale_120 = scale_for_engine(engine_scale_120, active.scale_mode);
        if scale_120 == active.scale_120 {
            return Ok(false);
        }

        active
            .client
            .get_data::<XWaylandClientData>()
            .ok_or("Xwayland client is missing compositor state")?
            .compositor_state
            .set_client_scale(client_scale(scale_120));
        if let Some(xwm) = active.xwm.as_mut() {
            publish_settings(xwm, scale_120, self.settings.cursor_size())?;
        }
        active.scale_120 = scale_120;
        Ok(true)
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn publish_xwayland_settings(&mut self) -> Result<(), Box<dyn std::error::Error>> {
        let cursor_size = self.settings.cursor_size();
        if let Some(active) = self.xwayland.active.as_mut()
            && let Some(xwm) = active.xwm.as_mut()
        {
            publish_settings(xwm, active.scale_120, cursor_size)?;
        }
        Ok(())
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

fn initial_map_activates(override_redirect: bool) -> bool {
    !override_redirect
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
    centered_transient_geometry(requested.size, anchor, output)
}

#[cfg(any(feature = "flutter", test))]
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
                (transient_parent.is_none() && !frontend.window_layout_manages_geometry())
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
        // Override-redirect surfaces are client-owned popups. Mapping one may
        // raise it visually, but must not clear the managed owner's active
        // state or publish the popup itself as the active desktop window.
        frontend.space.map_element(
            window.clone(),
            configured.loc,
            initial_map_activates(override_redirect),
        );
        frontend.update_window_output_membership(&window);
        if !override_redirect {
            frontend.announce_foreign_toplevel(&window);
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
        state
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .reconcile_window_layout(&window);
        #[cfg(feature = "flutter")]
        state
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .configure_mobile_window(&window);
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
        request_keyboard_focus(
            state,
            &keyboard,
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
        let was_layout_managed = frontend.window_is_layout_managed(&window);
        frontend.remove_window_from_layout(&window, true);
        if !was_layout_managed {
            frontend.remember_window_placement(&window);
        }
        if let Some(root) = frontend.window_root_surface(&window) {
            frontend.remove_foreign_toplevel(&root);
            #[cfg(feature = "flutter")]
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
        request_keyboard_focus(state, &keyboard, next_focus, SERIAL_COUNTER.next_serial());
        #[cfg(feature = "flutter")]
        if let Some(window_id) = next_window_id {
            state
                .pending_window_events
                .push(PendingWindowEvent::Activated(window_id));
        }
    }
    state.scene_sync.mark_dirty();
}

impl XWaylandShellHandler for RuntimeState {
    fn xwayland_shell_state(&mut self) -> &mut XWaylandShellState {
        &mut self
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .xwayland
            .active
            .as_mut()
            .expect("Xwayland shell requested while Xwayland is disabled")
            .shell_state
    }

    fn surface_associated(&mut self, _xwm: XwmId, wl_surface: WlSurface, surface: X11Surface) {
        let frontend = self.wayland.as_mut().expect("missing Wayland frontend");
        let stable_id = frontend.register_window(&wl_surface).get();
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
            if !surface.is_override_redirect() {
                frontend.announce_foreign_toplevel(&window);
            }
            frontend.reconcile_window_layout(&window);
            #[cfg(feature = "flutter")]
            frontend.configure_mobile_window(&window);
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
            .xwayland
            .active
            .as_mut()
            .expect("Xwayland handler requested while Xwayland is disabled")
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
        let geometry_authoritative = element.as_ref().is_some_and(|element| {
            self.wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .window_geometry_authoritative(element)
        });
        #[cfg(not(feature = "flutter"))]
        let geometry_authoritative = false;
        let mut geometry = element.as_ref().map_or_else(
            || window.last_configure(),
            |element| {
                self.wayland
                    .as_ref()
                    .expect("missing Wayland frontend")
                    .window_geometry_target(element)
            },
        );
        let layout_managed = element.as_ref().is_some_and(|element| {
            self.wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .window_is_layout_managed(element)
        });
        if geometry_authoritative || layout_managed {
            if let Some(element) = element {
                self.wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .reassert_window_geometry_target(&element);
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
        frontend.refresh_image_copy_constraints_if_changed();
        self.scene_sync.mark_dirty();
    }

    fn property_notify(&mut self, _xwm: XwmId, window: X11Surface, property: WmWindowProperty) {
        if let Some(element) = window_for_x11(self, &window) {
            self.wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .update_foreign_toplevel(&element);
        }
        if matches!(
            property,
            WmWindowProperty::NormalHints
                | WmWindowProperty::TransientFor
                | WmWindowProperty::WindowType
        ) && let Some(element) = window_for_x11(self, &window)
        {
            self.wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .reconcile_window_layout(&element);
        }
        self.scene_sync.mark_dirty();
    }

    fn maximize_request(&mut self, _xwm: XwmId, window: X11Surface) {
        if let Some(window) = window_for_x11(self, &window) {
            apply_managed_client_state_request(self, &window, ManagedClientStateRequest::Maximize);
        }
    }

    fn unmaximize_request(&mut self, _xwm: XwmId, window: X11Surface) {
        if let Some(window) = window_for_x11(self, &window) {
            apply_managed_client_state_request(
                self,
                &window,
                ManagedClientStateRequest::Unmaximize,
            );
        }
    }

    fn fullscreen_request(&mut self, _xwm: XwmId, window: X11Surface) {
        if let Some(window) = window_for_x11(self, &window) {
            apply_managed_client_state_request(
                self,
                &window,
                ManagedClientStateRequest::Fullscreen(None),
            );
        }
    }

    fn unfullscreen_request(&mut self, _xwm: XwmId, window: X11Surface) {
        if let Some(window) = window_for_x11(self, &window) {
            apply_managed_client_state_request(
                self,
                &window,
                ManagedClientStateRequest::Unfullscreen,
            );
        }
    }

    fn minimize_request(&mut self, _xwm: XwmId, _window: X11Surface) {
        #[cfg(feature = "flutter")]
        if let Some(window) = window_for_x11(self, &_window) {
            apply_managed_minimize(self, &window, true);
        }
    }

    fn unminimize_request(&mut self, _xwm: XwmId, window: X11Surface) {
        #[cfg(feature = "flutter")]
        if let Some(window) = window_for_x11(self, &window) {
            apply_managed_minimize(self, &window, false);
        }
    }

    fn resize_request(&mut self, _xwm: XwmId, window: X11Surface, _button: u32, edge: ResizeEdge) {
        let Some(element) = window_for_x11(self, &window) else {
            return;
        };
        if !managed_client_grab_allowed(self, &element) {
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
        let geometry = self
            .wayland
            .as_ref()
            .expect("missing Wayland frontend")
            .window_geometry_target(&element);
        self.wayland
            .as_ref()
            .expect("missing Wayland frontend")
            .prepare_window_interactive_resize(&element, geometry.size, false);
        pointer.set_grab(
            self,
            ResizeSurfaceGrab::new(
                start_data,
                element,
                ResizeEdges::from_x11(edge),
                geometry.loc,
                geometry.size,
            ),
            SERIAL_COUNTER.next_serial(),
            Focus::Clear,
        );
    }

    fn move_request(&mut self, _xwm: XwmId, window: X11Surface, _button: u32) {
        let Some(element) = window_for_x11(self, &window) else {
            return;
        };
        if !managed_client_grab_allowed(self, &element) {
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
        if let Some(active) = self
            .wayland
            .as_mut()
            .and_then(|frontend| frontend.xwayland.active.as_mut())
        {
            active.xwm = None;
        }
        warn!("lost the Xwayland window-manager connection");
    }
}

#[cfg(test)]
mod tests {
    use super::initial_map_activates;

    #[test]
    fn override_redirect_mapping_does_not_take_activation() {
        assert!(initial_map_activates(false));
        assert!(!initial_map_activates(true));
    }
}
