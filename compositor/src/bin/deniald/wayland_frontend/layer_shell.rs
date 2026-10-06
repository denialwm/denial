//! Generic wlr-layer-shell lifecycle and output placement.

use super::*;

impl WaylandFrontend {
    pub(super) fn layer_surface_for_surface(
        &self,
        surface: &WlSurface,
    ) -> Option<DesktopLayerSurface> {
        let root = self.toplevel_candidate_surface(surface);
        self.outputs.iter().find_map(|entry| {
            layer_map_for_output(&entry.output)
                .layer_for_surface(&root, WindowSurfaceType::TOPLEVEL)
                .cloned()
        })
    }

    pub(super) fn layer_root_surface(&self, surface: &WlSurface) -> Option<(WlSurface, OutputId)> {
        let root = self.toplevel_candidate_surface(surface);
        self.outputs.iter().find_map(|entry| {
            let map = layer_map_for_output(&entry.output);
            map.layer_for_surface(
                &root,
                WindowSurfaceType::TOPLEVEL | WindowSurfaceType::SUBSURFACE,
            )
            .map(|layer| (layer.wl_surface().clone(), entry.id))
        })
    }

    pub(super) fn layer_keyboard_focus_for_surface(
        &self,
        surface: &WlSurface,
    ) -> Option<KeyboardFocusTarget> {
        let layer = self.layer_surface_for_surface(surface)?;
        layer
            .can_receive_keyboard_focus()
            .then(|| KeyboardFocusTarget::Wayland(layer.wl_surface().clone()))
    }

    /// Returns the topmost mapped top/overlay layer which requested exclusive
    /// keyboard focus. Layer-shell requires this focus to remain authoritative
    /// even when the pointer is over another client.
    pub(super) fn exclusive_layer_keyboard_focus(&self) -> Option<KeyboardFocusTarget> {
        for kind in [WlrLayer::Overlay, WlrLayer::Top] {
            for output in &self.outputs {
                let map = layer_map_for_output(&output.output);
                if let Some(layer) = map.layers_on(kind).rev().find(|layer| {
                    layer.cached_state().keyboard_interactivity == KeyboardInteractivity::Exclusive
                }) {
                    return Some(KeyboardFocusTarget::Wayland(layer.wl_surface().clone()));
                }
            }
        }
        None
    }

    pub(super) fn commit_layer_surface(&mut self, surface: &WlSurface) -> bool {
        let Some((root, output_id)) = self.layer_root_surface(surface) else {
            return false;
        };
        if root != *surface {
            return false;
        }
        let Some(output) = self.outputs.iter().find(|entry| entry.id == output_id) else {
            return false;
        };
        let initial_configure_sent = with_states(&root, |states| {
            states
                .data_map
                .get::<LayerSurfaceData>()
                .is_some_and(|data| {
                    data.lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner())
                        .initial_configure_sent
                })
        });
        let mut map = layer_map_for_output(&output.output);
        let changed = map.arrange();
        if !initial_configure_sent
            && let Some(layer) = map.layer_for_surface(&root, WindowSurfaceType::TOPLEVEL)
        {
            layer.layer_surface().send_configure();
        }
        changed
    }

    fn set_layer_surface_scale(&self, surface: &WlSurface, output: &Output) {
        let preferred_scale =
            Self::client_preferred_scale(surface, output.current_scale().fractional_scale());
        with_states(surface, |states| {
            with_fractional_scale(states, |fractional_scale| {
                fractional_scale.set_preferred_scale(preferred_scale);
            });
        });
    }
}

impl WlrLayerShellHandler for RuntimeState {
    fn shell_state(&mut self) -> &mut WlrLayerShellState {
        &mut self
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .layer_shell_state
    }

    fn new_layer_surface(
        &mut self,
        surface: WlrLayerSurface,
        requested_output: Option<wl_output::WlOutput>,
        _layer: WlrLayer,
        namespace: String,
    ) {
        let frontend = self.wayland.as_mut().expect("missing Wayland frontend");
        let output = requested_output
            .as_ref()
            .and_then(Output::from_resource)
            .and_then(|requested| {
                frontend
                    .outputs
                    .iter()
                    .find(|entry| entry.output == requested)
                    .map(|entry| entry.output.clone())
            })
            .or_else(|| frontend.outputs.first().map(|entry| entry.output.clone()));
        let Some(output) = output else {
            surface.send_close();
            return;
        };

        frontend.set_layer_surface_scale(surface.wl_surface(), &output);
        let layer = DesktopLayerSurface::new(surface, namespace);
        if let Err(error) = layer_map_for_output(&output).map_layer(&layer) {
            warn!(%error, "could not map layer-shell surface");
            layer.layer_surface().send_close();
            return;
        }
        self.scene_sync.mark_dirty();
    }

    fn new_popup(&mut self, parent: WlrLayerSurface, popup: PopupSurface) {
        let frontend = self.wayland.as_mut().expect("missing Wayland frontend");
        let popup_surface = popup.wl_surface().clone();
        // XdgShellHandler::new_popup already tracks every XDG popup. At that
        // point a layer-shell popup is still parentless, so PopupManager keeps
        // it in its pending list until the first surface commit. Tracking it
        // again here, after get_popup assigns the layer parent, inserts it into
        // the popup tree immediately; the first commit then inserts the pending
        // entry a second time and publishes the same surface twice.
        if let Some((_, output_id)) = frontend.layer_root_surface(parent.wl_surface())
            && let Some(output) = frontend.outputs.iter().find(|entry| entry.id == output_id)
        {
            frontend.set_layer_surface_scale(&popup_surface, &output.output);
        }
        self.scene_sync.mark_dirty();
    }

    fn layer_destroyed(&mut self, surface: WlrLayerSurface) {
        let frontend = self.wayland.as_mut().expect("missing Wayland frontend");
        for output in &frontend.outputs {
            let mut map = layer_map_for_output(&output.output);
            let Some(layer) = map
                .layers()
                .find(|layer| layer.layer_surface() == &surface)
                .cloned()
            else {
                continue;
            };
            map.unmap_layer(&layer);
            break;
        }
        #[cfg(feature = "flutter")]
        frontend
            .pending_layer_frame_callback_roots
            .remove(&surface.wl_surface().id());
        frontend.remove_surface_state(surface.wl_surface(), false);
        self.scene_sync.mark_dirty();
    }
}
