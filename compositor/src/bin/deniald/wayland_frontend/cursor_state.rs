//! Cursor publication and frontend identity.

use super::*;

#[cfg(feature = "flutter")]
fn finish_cursor_state(
    mut state: CursorStateDescription,
    mut unused_layers: Vec<SurfaceLayerDescription>,
) -> CursorStateDescription {
    if state.kind != CursorStateKind::Surface {
        // Named and hidden cursors borrow this allocation only as scratch. A
        // surface cursor may have been reclassified after traversal, so never
        // let its discarded layers become a named-cursor payload.
        unused_layers.clear();
        state.surfaces = unused_layers;
    }
    state
}

impl WaylandFrontend {
    #[cfg(feature = "flutter")]
    pub(super) fn update_cursor_image(&mut self, image: CursorImageStatus) {
        let previous_surface = match &self.cursor_status {
            CursorImageStatus::Surface(surface) => Some(surface.clone()),
            _ => None,
        };
        self.cursor_status = image;
        if let Some(previous) = previous_surface
            && !matches!(&self.cursor_status, CursorImageStatus::Surface(current) if current == &previous)
        {
            self.leave_cursor_surface(&previous);
            self.cursor_output = None;
            self.cursor_output_scale = None;
        }
        if self.pointer_cursor_visible
            && matches!(self.routed_pointer_target, RoutedPointerTarget::Client(_))
        {
            self.queue_cursor_image_publication();
            self.update_cursor_output_membership();
        }
    }

    #[cfg(feature = "flutter")]
    pub(super) fn update_tablet_cursor_image(&mut self, image: CursorImageStatus) {
        self.cursor_status = image;
        if self.pointer_cursor_visible {
            self.queue_cursor_image_publication();
            self.update_cursor_output_membership();
        }
    }

    #[cfg(feature = "flutter")]
    fn queue_cursor_image_publication(&mut self) {
        let publication = self.resolved_client_cursor_publication();
        if matches!(publication, CursorPublication::Surface(_)) {
            // Xwayland reuses one wl_surface for successive X cursors. Its
            // wl_pointer.set_cursor requests can therefore change the role's
            // hotspot without changing surface identity. Force the complete
            // description across the bridge so Dart never anchors a new
            // cursor buffer with the preceding cursor's hotspot.
            self.published_cursor_state = None;
            self.pending_cursor_state = Some(publication);
        } else {
            self.queue_cursor_publication(publication);
        }
    }

    #[cfg(feature = "flutter")]
    pub(super) fn queue_cursor_publication(&mut self, publication: CursorPublication) {
        if self.pending_cursor_state.as_ref() == Some(&publication)
            || (self.pending_cursor_state.is_none()
                && self.published_cursor_state.as_ref() == Some(&publication))
        {
            return;
        }
        self.pending_cursor_state = Some(publication);
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn request_flutter_cursor_shape(&mut self, shape: &'static str) {
        if !self.pointer_cursor_visible {
            return;
        }
        if self.clipboard_drag_active {
            self.queue_cursor_publication(CursorPublication::Named("default"));
            return;
        }
        if let Some(shape) = accepted_flutter_cursor_shape(self.routed_pointer_target, shape) {
            self.queue_cursor_publication(CursorPublication::Named(shape));
        }
    }

    #[cfg(feature = "flutter")]
    pub(super) fn set_clipboard_drag_active(&mut self, active: bool) {
        if self.clipboard_drag_active == active {
            if active && self.pointer_cursor_visible {
                self.queue_cursor_publication(CursorPublication::Named("default"));
            }
            return;
        }
        self.clipboard_drag_active = active;
        self.published_cursor_state = None;
        self.pending_cursor_state = if !self.pointer_cursor_visible {
            Some(CursorPublication::Hidden)
        } else if active {
            Some(CursorPublication::Named("default"))
        } else {
            match self.routed_pointer_target {
                RoutedPointerTarget::Flutter => None,
                RoutedPointerTarget::Client(_) => Some(self.resolved_client_cursor_publication()),
            }
        };
        self.update_cursor_output_membership();
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn set_compositor_pointer_grab_active(&mut self, active: bool) {
        if self.compositor_pointer_grab_active == active {
            return;
        }
        self.compositor_pointer_grab_active = active;
        if !self.pointer_cursor_visible
            || !matches!(self.routed_pointer_target, RoutedPointerTarget::Client(_))
        {
            return;
        }
        self.published_cursor_state = None;
        self.pending_cursor_state = Some(self.resolved_client_cursor_publication());
        self.update_cursor_output_membership();
    }

    #[cfg(feature = "flutter")]
    pub(super) fn set_routed_pointer_target(&mut self, target: RoutedPointerTarget) {
        if self.routed_pointer_target == target {
            return;
        }
        self.routed_pointer_target = target;
        self.published_cursor_state = None;
        if !self.pointer_cursor_visible {
            self.pending_cursor_state = Some(CursorPublication::Hidden);
            self.pending_cursor_position = None;
            self.update_cursor_output_membership();
            return;
        }
        if self.clipboard_drag_active {
            self.pending_cursor_state = Some(CursorPublication::Named("default"));
            self.update_cursor_output_membership();
            return;
        }
        match target {
            // Dart's MouseRegion owns cursor selection again.  Discard a
            // client update which has not crossed the bridge yet so it cannot
            // overwrite the newer Flutter shape after the route switch.
            RoutedPointerTarget::Flutter => self.pending_cursor_state = None,
            // Do not retain the previous client (or Flutter) shape while the
            // newly entered client is waiting to call wl_pointer.set_cursor.
            RoutedPointerTarget::Client(_) => {
                self.pending_cursor_state = Some(CursorPublication::Named("default"));
            }
        }
        self.update_cursor_output_membership();
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn take_cursor_state_update(&mut self) -> Option<CursorPublication> {
        let state = self.pending_cursor_state.take()?;
        self.published_cursor_state = Some(state.clone());
        Some(state)
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn flutter_cursor_state(
        &mut self,
        publication: CursorPublication,
    ) -> (CursorStateDescription, Vec<ExternalTextureFrame>) {
        let mut layers = std::mem::take(&mut self.cursor_state_layers_scratch);
        layers.clear();
        let mut textures = std::mem::take(&mut self.cursor_state_textures_scratch);
        textures.clear();
        let mut state = match publication {
            CursorPublication::Hidden => CursorStateDescription::hidden(),
            CursorPublication::Named(shape) => CursorStateDescription::named(shape),
            CursorPublication::Surface(surface) => {
                let hotspot = with_states(&surface, |states| {
                    states
                        .data_map
                        .get::<CursorImageSurfaceData>()
                        .map(|attributes| {
                            attributes
                                .lock()
                                .unwrap_or_else(|poisoned| poisoned.into_inner())
                                .hotspot
                        })
                        .unwrap_or_default()
                });
                let mut composition_order = 0;
                self.append_surface_tree(
                    &surface,
                    Point::from((0, 0)),
                    SurfaceRoleDescription::Root,
                    0,
                    0,
                    true,
                    &mut composition_order,
                    &mut layers,
                    &mut textures,
                );
                if let Some(cursor_override) = self.xwayland_cursor_override(&surface) {
                    // Xwayland calls wl_pointer.set_cursor before attaching
                    // and committing the replacement buffer. It also reuses
                    // this surface for later application cursors, so the
                    // final composed layer is the first authoritative place
                    // to classify the buffer selected by that request.
                    textures.clear();
                    let publication = match cursor_override {
                        crate::xcursor_sentinel::CursorOverride::Hidden => {
                            CursorPublication::Hidden
                        }
                        crate::xcursor_sentinel::CursorOverride::Named(shape) => {
                            CursorPublication::Named(shape)
                        }
                    };
                    self.published_cursor_state = Some(publication.clone());
                    match publication {
                        CursorPublication::Hidden => CursorStateDescription::hidden(),
                        CursorPublication::Named(shape) => CursorStateDescription::named(shape),
                        CursorPublication::Surface(_) => {
                            unreachable!("cursor override is semantic")
                        }
                    }
                } else {
                    CursorStateDescription {
                        epoch: 0,
                        kind: CursorStateKind::Surface,
                        shape: String::new(),
                        hotspot_x: f64::from(hotspot.x),
                        hotspot_y: f64::from(hotspot.y),
                        surfaces: std::mem::take(&mut layers),
                    }
                }
            }
        };
        self.pending_cursor_metadata = false;
        self.pending_cursor_buffer_surface_ids.clear();
        state = finish_cursor_state(state, layers);
        (state, textures)
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn recycle_flutter_cursor_state(
        &mut self,
        mut state: CursorStateDescription,
        mut textures: Vec<ExternalTextureFrame>,
    ) {
        state.surfaces.clear();
        textures.clear();
        debug_assert!(self.cursor_state_layers_scratch.is_empty());
        debug_assert!(self.cursor_state_textures_scratch.is_empty());
        self.cursor_state_layers_scratch = state.surfaces;
        self.cursor_state_textures_scratch = textures;
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn take_cursor_buffer_updates(&mut self) -> Option<Vec<ExternalTextureFrame>> {
        if self.pending_cursor_metadata || self.pending_cursor_buffer_surface_ids.is_empty() {
            return None;
        }
        let surface_ids = std::mem::take(&mut self.pending_cursor_buffer_surface_ids);
        let mut textures = std::mem::take(&mut self.cursor_state_textures_scratch);
        textures.clear();
        for surface_id in &surface_ids {
            let Some(frame) = self.external_texture_frame(*surface_id, true) else {
                let publication = self.resolved_client_cursor_publication();
                self.pending_cursor_metadata = matches!(publication, CursorPublication::Surface(_));
                self.published_cursor_state = None;
                self.pending_cursor_state = Some(publication);
                if self.pending_cursor_metadata {
                    self.pending_cursor_buffer_surface_ids = surface_ids;
                } else {
                    self.pending_cursor_buffer_surface_ids.clear();
                }
                self.cursor_state_textures_scratch = textures;
                return None;
            };
            textures.push(frame);
        }
        self.pending_cursor_buffer_surface_ids = surface_ids;
        self.pending_cursor_buffer_surface_ids.clear();
        Some(textures)
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn recycle_cursor_buffer_updates(
        &mut self,
        mut textures: Vec<ExternalTextureFrame>,
    ) {
        textures.clear();
        debug_assert!(self.cursor_state_textures_scratch.is_empty());
        self.cursor_state_textures_scratch = textures;
    }

    #[cfg(feature = "flutter")]
    pub(super) fn record_cursor_surface_commits(
        &mut self,
        _root: &WlSurface,
        commits: PublishedSurfaceCommits,
    ) {
        let PublishedSurfaceCommits {
            metadata_changed,
            mut buffer_surface_ids,
        } = commits;
        let publication = self.resolved_client_cursor_publication();
        let publication_changed = self.published_cursor_state.as_ref() != Some(&publication);
        if metadata_changed
            || publication_changed
            || !matches!(publication, CursorPublication::Surface(_))
        {
            self.pending_cursor_metadata = matches!(publication, CursorPublication::Surface(_));
            self.pending_cursor_buffer_surface_ids.clear();
            self.published_cursor_state = None;
            self.pending_cursor_state = Some(publication);
            self.cursor_output = None;
            self.cursor_output_scale = None;
            self.update_cursor_output_membership();
        } else {
            self.pending_cursor_buffer_surface_ids
                .extend(buffer_surface_ids.iter().copied());
        }
        buffer_surface_ids.clear();
        debug_assert!(self.published_surface_ids_scratch.is_empty());
        self.published_surface_ids_scratch = buffer_surface_ids;
    }

    #[cfg(feature = "flutter")]
    pub(super) fn queue_cursor_position(&mut self) {
        self.update_cursor_output_membership();
        self.pending_cursor_position = cursor_position_for_modality(
            self.pointer_cursor_visible,
            self.flutter_scene_pointer_position(),
        );
    }

    #[cfg(feature = "flutter")]
    pub(super) fn set_pointer_cursor_visible(&mut self, visible: bool) {
        if self.pointer_cursor_visible == visible {
            return;
        }
        self.pointer_cursor_visible = visible;
        self.published_cursor_state = None;
        if !visible {
            self.pending_cursor_state = Some(CursorPublication::Hidden);
            self.pending_cursor_position = None;
            self.update_cursor_output_membership();
            return;
        }

        let active_state = if self.clipboard_drag_active {
            CursorPublication::Named("default")
        } else {
            match self.routed_pointer_target {
                RoutedPointerTarget::Flutter => CursorPublication::Named("default"),
                RoutedPointerTarget::Client(_) => self.resolved_client_cursor_publication(),
            }
        };
        self.pending_cursor_state = Some(active_state);
        self.pending_cursor_position = cursor_position_for_modality(
            visible && matches!(self.routed_pointer_target, RoutedPointerTarget::Client(_)),
            self.flutter_scene_pointer_position(),
        );
        self.update_cursor_output_membership();
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn take_cursor_position_update(&mut self) -> Option<(f64, f64)> {
        self.pending_cursor_position.take()
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn queue_cursor_policy_update(&mut self) {
        if self.pointer_cursor_visible
            && matches!(self.routed_pointer_target, RoutedPointerTarget::Client(_))
        {
            self.published_cursor_state = None;
            self.pending_cursor_state = Some(self.resolved_client_cursor_publication());
            self.update_cursor_output_membership();
        }
    }

    #[cfg(feature = "flutter")]
    pub(super) fn resolved_client_cursor_publication(&self) -> CursorPublication {
        let intent = match &self.cursor_status {
            CursorImageStatus::Hidden => ClientCursorIntent::Hidden,
            CursorImageStatus::Named(icon) => ClientCursorIntent::Named(icon.name()),
            CursorImageStatus::Surface(_) => ClientCursorIntent::Surface,
        };
        match resolved_client_cursor_intent(
            intent,
            self.settings.allow_client_cursor_surfaces(),
            self.clipboard_drag_active || self.compositor_pointer_grab_active,
        ) {
            ClientCursorIntent::Hidden => CursorPublication::Hidden,
            ClientCursorIntent::Named(shape) => CursorPublication::Named(shape),
            ClientCursorIntent::Surface => {
                let CursorImageStatus::Surface(surface) = &self.cursor_status else {
                    unreachable!("surface cursor intent must retain its wl_surface")
                };
                if let Some(cursor_override) = self.xwayland_cursor_override(surface) {
                    match cursor_override {
                        crate::xcursor_sentinel::CursorOverride::Hidden => {
                            CursorPublication::Hidden
                        }
                        crate::xcursor_sentinel::CursorOverride::Named(shape) => {
                            CursorPublication::Named(shape)
                        }
                    }
                } else {
                    CursorPublication::Surface(surface.clone())
                }
            }
        }
    }

    #[cfg(feature = "flutter")]
    fn xwayland_cursor_override(
        &self,
        surface: &WlSurface,
    ) -> Option<crate::xcursor_sentinel::CursorOverride> {
        if !self.is_xwayland_cursor_surface(surface) {
            return None;
        }
        let frame = self.surface_shm_frames.get(&surface.id())?;
        if frame.is_fully_transparent() {
            return Some(crate::xcursor_sentinel::CursorOverride::Hidden);
        }
        if !crate::xcursor_sentinel::is_active() {
            return None;
        }
        let pixel = frame.pixels_if_single()?;
        crate::xcursor_sentinel::override_for_marker(frame.width(), frame.height(), &pixel)
    }

    #[cfg(feature = "flutter")]
    fn is_xwayland_cursor_surface(&self, surface: &WlSurface) -> bool {
        surface
            .client()
            .is_some_and(|client| xwayland::is_client(&client))
    }

    #[cfg(feature = "flutter")]
    pub(super) fn active_cursor_root_for(&self, surface: &WlSurface) -> Option<WlSurface> {
        if !self.pointer_cursor_visible
            || self.clipboard_drag_active
            || self.compositor_pointer_grab_active
            || !self.settings.allow_client_cursor_surfaces()
            || !matches!(self.routed_pointer_target, RoutedPointerTarget::Client(_))
        {
            return None;
        }
        self.cursor_root_for(surface)
    }

    #[cfg(feature = "flutter")]
    pub(super) fn cursor_root_for(&self, surface: &WlSurface) -> Option<WlSurface> {
        let CursorImageStatus::Surface(cursor_root) = &self.cursor_status else {
            return None;
        };
        let mut root = surface.clone();
        while let Some(parent) = get_parent(&root) {
            root = parent;
        }
        (root == *cursor_root).then_some(root)
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn cursor_output_id(&self) -> Option<OutputId> {
        self.cursor_output
    }

    #[cfg(feature = "flutter")]
    pub(super) fn update_cursor_output_membership(&mut self) {
        let cursor_surface = match self.resolved_client_cursor_publication() {
            CursorPublication::Surface(surface)
                if self.pointer_cursor_visible
                    && matches!(self.routed_pointer_target, RoutedPointerTarget::Client(_)) =>
            {
                Some(surface)
            }
            _ => None,
        };
        let pointer = Point::from((
            self.pointer_location.x.floor() as i32,
            self.pointer_location.y.floor() as i32,
        ));
        let next_output_entry = cursor_surface.as_ref().and_then(|_| {
            self.outputs
                .iter()
                .find(|entry| entry.logical_geometry.contains(pointer))
        });
        let next_output = next_output_entry.map(|entry| entry.id);
        let next_output_scale =
            next_output_entry.map(|entry| entry.output.current_scale().fractional_scale());
        if self.cursor_output == next_output
            && self.cursor_output_scale == next_output_scale
            && cursor_surface.is_some()
        {
            return;
        }
        self.cursor_output = next_output;
        self.cursor_output_scale = next_output_scale;
        let Some(surface) = cursor_surface else {
            if let CursorImageStatus::Surface(surface) = &self.cursor_status {
                self.leave_cursor_surface(surface);
            }
            return;
        };
        let output_scale = next_output_scale.unwrap_or(1.0);
        for entry in &self.outputs {
            let entered = Some(entry.id) == next_output;
            with_surface_tree_downward(
                &surface,
                (),
                |_, _, &()| TraversalAction::DoChildren(()),
                |child, states, &()| {
                    if entered {
                        entry.output.enter(child);
                    } else {
                        entry.output.leave(child);
                    }
                    let preferred_scale = Self::client_preferred_scale(child, output_scale);
                    with_fractional_scale(states, |fractional_scale| {
                        fractional_scale.set_preferred_scale(preferred_scale);
                    });
                },
                |_, _, &()| true,
            );
        }
    }

    #[cfg(feature = "flutter")]
    fn leave_cursor_surface(&self, surface: &WlSurface) {
        with_surface_tree_downward(
            surface,
            (),
            |_, _, &()| TraversalAction::DoChildren(()),
            |child, _, &()| {
                for output in &self.outputs {
                    output.output.leave(child);
                }
            },
            |_, _, &()| true,
        );
    }

    pub fn socket_name(&self) -> &OsStr {
        &self.socket_name
    }

    pub fn xdisplay_name(&self) -> Option<OsString> {
        self.xwayland.display_name()
    }
}

#[cfg(all(test, feature = "flutter"))]
mod tests {
    use super::*;
    use crate::wire;

    #[test]
    fn reclassified_named_cursor_drops_traversed_surface_layers() {
        let layer = SurfaceLayerDescription {
            surface_id: 1,
            parent_surface_id: 0,
            popup_root_surface_id: 0,
            role: SurfaceRoleDescription::Root,
            texture_id: 1,
            width: 1,
            height: 1,
            surface_x: 0.0,
            surface_y: 0.0,
            surface_width: 1.0,
            surface_height: 1.0,
            texture_source_x: 0.0,
            texture_source_y: 0.0,
            texture_source_width: 1.0,
            texture_source_height: 1.0,
            transform: 0,
            scale_120: 120,
            composition_order: 0,
            opacity: 1.0,
            opaque: false,
        };

        let state = finish_cursor_state(CursorStateDescription::named("pointer"), vec![layer]);

        assert_eq!(state.kind, CursorStateKind::Named);
        assert!(state.surfaces.is_empty());
        assert!(wire::validate_cursor_state(&CursorStateDescription { epoch: 1, ..state }).is_ok());
    }
}
