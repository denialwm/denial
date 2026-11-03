//! Per-surface opt-outs and native mobile client geometry.

use super::managed_window::ManagedWindow;
use super::*;
use smithay::reexports::wayland_server::{Client, DataInit, Dispatch, GlobalDispatch, New};

pub mod protocol {
    pub mod server {
        #![allow(
            dead_code,
            non_camel_case_types,
            non_upper_case_globals,
            non_snake_case,
            unused_imports,
            unused_unsafe,
            unused_variables,
            clippy::all,
            missing_docs
        )]
        use wayland_server;
        use wayland_server::protocol::*;
        pub mod __interfaces {
            use wayland_server::backend as wayland_backend;
            use wayland_server::protocol::__interfaces::*;
            wayland_scanner::generate_interfaces!("protocol/denial-insets-v1.xml");
        }
        use self::__interfaces::*;
        wayland_scanner::generate_server_code!("protocol/denial-insets-v1.xml");
    }
}

use protocol::server::denial_insets_manager_v1::{self, DenialInsetsManagerV1};
use protocol::server::denial_keyboard_inset_v1::{self, DenialKeyboardInsetV1};

#[cfg(test)]
#[path = "insets/tests.rs"]
mod tests;

fn configure_mobile_toplevel(toplevel: &ToplevelSurface, size: Size<i32, Logical>) {
    toplevel.with_pending_state(|pending| {
        pending.size = Some(size);
        pending.states.unset(xdg_toplevel::State::Fullscreen);
        pending.states.unset(xdg_toplevel::State::Maximized);
        // Mobile clients fill their assigned rectangle, including dialogs and
        // clients managing their own insets. Leave unrelated state bits alone.
        for edge in [
            xdg_toplevel::State::TiledLeft,
            xdg_toplevel::State::TiledRight,
            xdg_toplevel::State::TiledTop,
            xdg_toplevel::State::TiledBottom,
        ] {
            pending.states.set(edge);
        }
    });
    // Smithay compares with the last sent/acked state and filters unsupported
    // tiled states for legacy clients. Reconciliation must not force a configure.
    toplevel.send_pending_configure();
}

#[cfg(feature = "flutter")]
pub(super) fn configure_desktop_toplevel(
    toplevel: &ToplevelSurface,
    size: Size<i32, Logical>,
    state: WindowPlacementState,
) {
    toplevel.with_pending_state(|pending| {
        pending.size = Some(size);
        pending.states.unset(xdg_toplevel::State::Resizing);
        if !state.fullscreen {
            pending.fullscreen_output = None;
        }
        for edge in [
            xdg_toplevel::State::TiledLeft,
            xdg_toplevel::State::TiledRight,
            xdg_toplevel::State::TiledTop,
            xdg_toplevel::State::TiledBottom,
        ] {
            pending.states.unset(edge);
        }
        for (flag, enabled) in [
            (xdg_toplevel::State::Fullscreen, state.fullscreen),
            (xdg_toplevel::State::Maximized, state.maximized),
        ] {
            if enabled {
                pending.states.set(flag);
            } else {
                pending.states.unset(flag);
            }
        }
    });
    toplevel.send_pending_configure();
}

/// Mobile-only windows have no previous desktop placement. Retain the client
/// size where it fits and center it inside the desktop's reserved work area.
#[cfg(feature = "flutter")]
fn initial_desktop_geometry(
    size: Size<i32, Logical>,
    bounds: Rectangle<i32, Logical>,
) -> Rectangle<i32, Logical> {
    let size = Size::from((
        size.w.clamp(1, bounds.size.w.max(1)),
        size.h.clamp(1, bounds.size.h.max(1)),
    ));
    topology::centered_transient_geometry(size, bounds, bounds)
}

/// Matches the mobile status bar's logical height. Output scaling is applied
/// by the ordinary client configure/viewport and native texture projection.
/// A landscape output shows no status bar, so its windows get no inset.
pub(super) const MOBILE_STATUS_INSET: i32 = 48;

struct SelfManagedInsets;

pub(super) fn self_managed(surface: &WlSurface) -> bool {
    with_states(surface, |states| {
        states.data_map.get::<SelfManagedInsets>().is_some()
    })
}

/// Surfaces laid out around the on-screen keyboard instead of being lifted
/// by the shell, and the keyboard height the shell last reported.
#[derive(Debug, Default)]
pub(super) struct KeyboardInsets {
    objects: Vec<KeyboardInset>,
    height: u32,
}

#[derive(Debug)]
struct KeyboardInset {
    resource: DenialKeyboardInsetV1,
    surface: WlSurface,
    sent: u32,
}

pub(super) fn init(display: &DisplayHandle) {
    display.create_global::<RuntimeState, DenialInsetsManagerV1, _>(2, ());
}

impl GlobalDispatch<DenialInsetsManagerV1, ()> for RuntimeState {
    fn bind(
        _state: &mut Self,
        _handle: &DisplayHandle,
        _client: &Client,
        resource: New<DenialInsetsManagerV1>,
        _data: &(),
        data_init: &mut DataInit<'_, Self>,
    ) {
        data_init.init(resource, ());
    }
}

impl Dispatch<DenialInsetsManagerV1, ()> for RuntimeState {
    fn request(
        state: &mut Self,
        _client: &Client,
        resource: &DenialInsetsManagerV1,
        request: denial_insets_manager_v1::Request,
        _data: &(),
        _handle: &DisplayHandle,
        data_init: &mut DataInit<'_, Self>,
    ) {
        match request {
            denial_insets_manager_v1::Request::SetSelfManaged { surface } => {
                if self_managed(&surface) {
                    return;
                }
                if with_renderer_surface_state(&surface, |state| state.buffer().is_some())
                    .unwrap_or(false)
                {
                    resource.post_error(
                        denial_insets_manager_v1::Error::MappedSurface,
                        "declare self-managed insets before attaching the initial buffer",
                    );
                    return;
                }
                with_states(&surface, |states| {
                    states
                        .data_map
                        .insert_if_missing_threadsafe(|| SelfManagedInsets);
                });
                if let Some(frontend) = state.wayland.as_mut()
                    && let Some(window) = frontend.window_for_root_surface(&surface)
                {
                    frontend.configure_mobile_window(&window);
                }
                state.scene_sync.mark_dirty();
            }
            denial_insets_manager_v1::Request::GetKeyboardInset { id, surface } => {
                let Some(frontend) = state.wayland.as_mut() else {
                    return;
                };
                if frontend.keyboard_inset_surface(&surface) {
                    resource.post_error(
                        denial_insets_manager_v1::Error::KeyboardInsetExists,
                        "the surface already has a keyboard inset object",
                    );
                    return;
                }
                let resource = data_init.init(id, ());
                let height = frontend.keyboard_inset_height(&surface);
                resource.inset(height, 0);
                frontend.keyboard_insets.objects.push(KeyboardInset {
                    resource,
                    surface,
                    sent: height,
                });
                // The shell stops lifting the surface's window.
                state.scene_sync.mark_dirty();
            }
            denial_insets_manager_v1::Request::Destroy => {}
        }
    }
}

impl Dispatch<DenialKeyboardInsetV1, ()> for RuntimeState {
    fn request(
        _state: &mut Self,
        _client: &Client,
        _resource: &DenialKeyboardInsetV1,
        _request: denial_keyboard_inset_v1::Request,
        _data: &(),
        _handle: &DisplayHandle,
        _data_init: &mut DataInit<'_, Self>,
    ) {
    }

    fn destroyed(state: &mut Self, _client: ClientId, resource: &DenialKeyboardInsetV1, _: &()) {
        if let Some(frontend) = state.wayland.as_mut() {
            frontend
                .keyboard_insets
                .objects
                .retain(|object| object.resource != *resource);
        }
        state.scene_sync.mark_dirty();
    }
}

impl WaylandFrontend {
    /// Whether the surface is laid out around the on-screen keyboard, so the
    /// shell must not lift its window.
    pub(super) fn keyboard_inset_surface(&self, surface: &WlSurface) -> bool {
        self.keyboard_insets
            .objects
            .iter()
            .any(|object| object.surface == *surface)
    }

    /// Only mobile app windows reach the bottom of the output, so only the
    /// mobile presentation reports the keyboard over them, and only to
    /// windows on the phone: the keyboard never shows on a desk.
    fn keyboard_inset_height(&self, surface: &WlSurface) -> u32 {
        if self.mobile_shell && self.surface_on_phone(surface) {
            self.keyboard_insets.height
        } else {
            0
        }
    }

    fn surface_on_phone(&self, surface: &WlSurface) -> bool {
        if !self.phone_with_desk() {
            return true;
        }
        self.owning_toplevel_surface(surface)
            .is_none_or(|root| self.root_on_phone(&root.id()))
    }

    /// The shell's keyboard starts moving to `height` logical pixels over
    /// `duration` milliseconds.
    pub(super) fn set_keyboard_height(&mut self, height: u32, duration: u32) {
        self.keyboard_insets.height = height;
        self.send_keyboard_insets(duration);
    }

    fn send_keyboard_insets(&mut self, duration: u32) {
        let heights = self
            .keyboard_insets
            .objects
            .iter()
            .map(|object| self.keyboard_inset_height(&object.surface))
            .collect::<Vec<_>>();
        for (object, height) in self.keyboard_insets.objects.iter_mut().zip(heights) {
            if object.sent != height && object.surface.is_alive() {
                object.resource.inset(height, duration);
                object.sent = height;
            }
        }
    }
}

impl WaylandFrontend {
    #[cfg(feature = "flutter")]
    pub(super) fn set_mobile_presentation(&mut self, mobile: bool) -> bool {
        if self.mobile_shell == mobile {
            return false;
        }
        let windows = self.space.elements().cloned().collect::<Vec<_>>();
        if mobile {
            // Save desktop targets before mobile policy overwrites them. The
            // layout keeps its own normal rectangles for a later return.
            for window in &windows {
                let Some(root) = self.window_root_surface(window) else {
                    continue;
                };
                let target = self.window_geometry_target(window);
                let state = self.window_placement_state(window);
                if let Some(record) = self.ensure_window_record_for_surface(&root.id()) {
                    let intent = record.geometry_intent.unwrap_or_else(|| {
                        WindowGeometryIntent::for_contract(
                            target,
                            WindowGeometryAuthority::Pending,
                            None,
                        )
                    });
                    record.mobile_restore = Some((intent, state));
                }
            }
            self.mobile_shell = true;
            for window in &windows {
                self.configure_mobile_window(window);
            }
        } else {
            // Filter before changing the mode so system UI and unmanaged X11
            // surfaces retain their independent placement policy.
            let windows = windows
                .into_iter()
                .filter(|window| self.mobile_window_geometry(window).is_some())
                .collect::<Vec<_>>();
            self.mobile_shell = false;
            for window in &windows {
                let Some(root) = self.window_root_surface(window) else {
                    continue;
                };
                let saved = self
                    .window_record_for_surface_mut(&root.id())
                    .and_then(|record| record.mobile_restore.take());
                let (mut target, mut authority, mut state) = if let Some((intent, state)) = saved {
                    (intent.target, intent.authority, state)
                } else {
                    let current = self.window_geometry_target(window);
                    let Some(output) = self.output_for_geometry(current) else {
                        continue;
                    };
                    let bounds =
                        self.maximize_work_area(Some(&output.output), output.logical_geometry);
                    let bounds = shell_content_geometry(bounds, shell_draws_server_frame(window));
                    (
                        initial_desktop_geometry(current.size, bounds),
                        WindowGeometryAuthority::Pending,
                        WindowPlacementState::default(),
                    )
                };
                if !self.window_layout.manages_geometry()
                    && !state.fullscreen
                    && let Some(record) = self.window_record_for_surface_mut(&root.id())
                    && record.shell_presentation.is_none()
                    && let Some(normal) = record.layout_restore_geometry.take()
                {
                    target = normal;
                    authority = WindowGeometryAuthority::Pending;
                    state.maximized = false;
                }
                if let Some(toplevel) = window.toplevel() {
                    configure_desktop_toplevel(toplevel, target.size, state);
                }
                self.set_window_geometry_target_with_authority(window, target, authority);
            }
            self.rebuild_window_layout();
        }
        self.send_keyboard_insets(0);
        self.client_input_route_cache = None;
        info!(mobile, "changed native window presentation");
        true
    }

    pub(super) fn mobile_window_geometry(
        &self,
        window: &Window,
    ) -> Option<Rectangle<i32, Logical>> {
        if !self.mobile_shell
            || ManagedWindow::new(window).is_some_and(|window| window.facts().override_redirect)
        {
            return None;
        }
        let root = self.window_root_surface(window)?;
        let system_ui = window.toplevel().is_some_and(|toplevel| {
            with_states(toplevel.wl_surface(), |states| {
                let Some(data) = states.data_map.get::<XdgToplevelSurfaceData>() else {
                    return false;
                };
                let data = data.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
                data.app_id
                    .as_deref()
                    .into_iter()
                    .chain(data.title.as_deref())
                    .any(|name| name == "denia-home" || name.starts_with("denia-systemui"))
            })
        });
        if system_ui {
            return None;
        }
        let output = self.output_for_geometry(self.window_geometry_target(window));
        // A window on a desk keeps desktop placement.
        if output.is_some_and(|output| self.output_is_desk(output)) {
            return None;
        }
        let mut geometry = output
            .or_else(|| self.phone_output())
            .map(|output| output.logical_geometry)
            .or_else(|| self.fallback_output_geometry())?;
        let top = if self_managed(&root) || geometry.size.w > geometry.size.h {
            0
        } else {
            MOBILE_STATUS_INSET.min((geometry.size.h - 1).max(0))
        };
        geometry.loc.y += top;
        geometry.size.h -= top;
        Some(geometry)
    }

    pub(super) fn configure_mobile_window(&mut self, window: &Window) {
        let Some(target) = self.mobile_window_geometry(window) else {
            return;
        };
        if let Some(toplevel) = window.toplevel() {
            configure_mobile_toplevel(toplevel, target.size);
        }
        // An unchanged geometry target can still need a state-only configure.
        // Avoid rewriting geometry/authority when only XDG state has changed.
        if self.recorded_exact_window_geometry(window) == Some(target) {
            return;
        }
        self.set_window_geometry_target_with_authority(
            window,
            target,
            WindowGeometryAuthority::Exact,
        );
    }

    pub(super) fn mobile_window_inset(&self, window: &Window) -> i32 {
        let Some(geometry) = self.mobile_window_geometry(window) else {
            return 0;
        };
        self.output_for_geometry(geometry).map_or(0, |output| {
            (geometry.loc.y - output.logical_geometry.loc.y).max(0)
        })
    }
}

impl WaylandFrontend {
    /// Project a larger window canvas around the original client buffer. The
    /// engine draws the reserved strip inside the root TextureLayer; client
    /// DMA-BUF imports, storage, and buffer-only updates remain unchanged.
    pub(super) fn project_mobile_inset(
        &self,
        window: &Window,
        content: Rectangle<i32, Logical>,
        layers: &mut [SurfaceLayerDescription],
        textures: &mut [ExternalTextureFrame],
    ) -> Rectangle<i32, Logical> {
        let top = self.mobile_window_inset(window);
        if top <= 0 {
            return content;
        }
        let Some(root_id) = self
            .window_root_surface(window)
            .and_then(|root| self.surface_id(&root))
        else {
            return content;
        };
        let Some(root_index) = layers
            .iter()
            .position(|layer| layer.surface_id == root_id && layer.texture_id > 0)
        else {
            return content;
        };
        let frame = Rectangle::new(
            (content.loc.x, content.loc.y - top).into(),
            (content.size.w, content.size.h.saturating_add(top)).into(),
        );
        let scale = self
            .output_for_geometry(self.window_geometry_target(window))
            .map_or(1.0, |output| {
                output.output.current_scale().fractional_scale()
            });
        let width = (f64::from(frame.size.w) * scale).round().max(1.0);
        let height = (f64::from(frame.size.h) * scale).round().max(1.0);
        let sx = width / f64::from(frame.size.w);
        let sy = height / f64::from(frame.size.h);
        // Clip ordinary children in source geometry, without adding Flutter
        // clip layers. Popups retain their own surface-tree coordinates.
        for layer in layers
            .iter_mut()
            .filter(|layer| layer.popup_root_surface_id == 0)
        {
            clip_layer_to_content(layer, content, layer.surface_id == root_id);
            if layer.texture_id == 0
                && let Some(texture) = textures
                    .iter_mut()
                    .find(|texture| texture.texture_id == layer.surface_id as i64)
            {
                texture.expects_sample = false;
            }
        }
        let root = &mut layers[root_index];
        let root_texture = textures
            .iter_mut()
            .find(|texture| texture.texture_id == root_id as i64);
        // A cropped root is published in canvas coordinates; this presentation
        // replaces that canvas, so address the original buffer directly.
        let source = super::surface_pipeline::canvas_rect_to_buffer(
            root_texture
                .as_ref()
                .and_then(|texture| texture.presentation.as_ref()),
            [
                root.texture_source_x,
                root.texture_source_y,
                root.texture_source_width,
                root.texture_source_height,
            ],
        );
        let presentation = denial_flutter_engine::ExternalTexturePresentation {
            struct_size: std::mem::size_of::<denial_flutter_engine::ExternalTexturePresentation>(),
            width,
            height,
            source,
            destination: [
                (root.surface_x - f64::from(frame.loc.x)) * sx,
                (root.surface_y - f64::from(frame.loc.y)) * sy,
                root.surface_width * sx,
                root.surface_height * sy,
            ],
            background: [0.0, 0.0, width, f64::from(top) * sy],
            // The engine samples the current app image; black is the empty-source fallback.
            background_argb: 0xff000000,
        };
        if let Some(texture) = root_texture {
            texture.presentation = Some(presentation);
        }
        root.width = width as u32;
        root.height = height as u32;
        root.surface_x = f64::from(frame.loc.x);
        root.surface_y = f64::from(frame.loc.y);
        root.surface_width = f64::from(frame.size.w);
        root.surface_height = f64::from(frame.size.h);
        root.texture_source_x = 0.0;
        root.texture_source_y = 0.0;
        root.texture_source_width = width;
        root.texture_source_height = height;
        frame
    }
}

fn clip_layer_to_content(
    layer: &mut SurfaceLayerDescription,
    content: Rectangle<i32, Logical>,
    root: bool,
) {
    if layer.surface_width <= 0.0 || layer.surface_height <= 0.0 {
        return;
    }
    let left = layer.surface_x.max(f64::from(content.loc.x));
    let top = layer.surface_y.max(f64::from(content.loc.y));
    let right =
        (layer.surface_x + layer.surface_width).min(f64::from(content.loc.x + content.size.w));
    let bottom =
        (layer.surface_y + layer.surface_height).min(f64::from(content.loc.y + content.size.h));
    if right <= left || bottom <= top {
        if root {
            // Keep the root texture as the virtual canvas for the strip even
            // when all client content is supplied by subsurfaces.
            layer.surface_width = 0.0;
            layer.surface_height = 0.0;
            layer.texture_source_width = 0.0;
            layer.texture_source_height = 0.0;
        } else {
            // Preserve non-empty protocol geometry and parent identity for
            // descendants, but do not paint or wait to sample this buffer.
            layer.texture_id = 0;
        }
        return;
    }
    let sx = layer.texture_source_width / layer.surface_width;
    let sy = layer.texture_source_height / layer.surface_height;
    layer.texture_source_x += (left - layer.surface_x) * sx;
    layer.texture_source_y += (top - layer.surface_y) * sy;
    layer.surface_x = left;
    layer.surface_y = top;
    layer.surface_width = (right - left).max(0.0);
    layer.surface_height = (bottom - top).max(0.0);
    layer.texture_source_width = layer.surface_width * sx;
    layer.texture_source_height = layer.surface_height * sy;
}
