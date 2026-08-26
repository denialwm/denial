//! Published input scene, pointer projection, callbacks, and popup constraints.

use super::*;

pub(super) fn constrain_pointer_to_outputs(
    position: Point<f64, Logical>,
    outputs: impl IntoIterator<Item = Rectangle<i32, Logical>>,
) -> Option<Point<f64, Logical>> {
    let mut closest = None;
    for output in outputs {
        if output.size.w <= 0 || output.size.h <= 0 {
            continue;
        }

        let left = f64::from(output.loc.x);
        let top = f64::from(output.loc.y);
        let right = left + f64::from(output.size.w);
        let bottom = top + f64::from(output.size.h);
        if position.x >= left && position.x < right && position.y >= top && position.y < bottom {
            return Some(position);
        }

        // Logical output rectangles are half-open. Use the immediately
        // preceding representable coordinate at their far edges so the
        // projection remains inside the chosen output without sacrificing
        // subpixel motion across an adjoining output boundary.
        let projected = Point::from((
            position.x.clamp(left, right.next_down()),
            position.y.clamp(top, bottom.next_down()),
        ));
        let dx = position.x - projected.x;
        let dy = position.y - projected.y;
        let distance_squared = dx.mul_add(dx, dy * dy);
        if closest
            .as_ref()
            .is_none_or(|(best_distance, _)| distance_squared < *best_distance)
        {
            closest = Some((distance_squared, projected));
        }
    }
    closest.map(|(_, position)| position)
}

impl WaylandFrontend {
    #[cfg(feature = "flutter")]
    pub(crate) fn has_pending_frame_callbacks(&self) -> bool {
        !self.pending_frame_callback_windows.is_empty()
            || !self.pending_input_method_frame_callbacks.is_empty()
    }

    #[cfg(feature = "flutter")]
    pub(super) fn queue_cursor_state_for_flutter_generation(&mut self) {
        self.published_cursor_shape = None;
        if !self.pointer_cursor_visible {
            self.pending_cursor_shape = Some("none");
            self.pending_cursor_position = None;
            return;
        }
        match self.routed_pointer_target {
            RoutedPointerTarget::Flutter => {
                self.pending_cursor_shape = None;
                self.pending_cursor_position = None;
            }
            RoutedPointerTarget::Client(_) => {
                self.pending_cursor_shape = Some(software_cursor_shape(&self.cursor_status));
                self.pending_cursor_position = Some(self.flutter_scene_pointer_position());
            }
        }
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn reset_flutter_input_generation(&mut self) {
        // The replacement engine has not observed the old generation's
        // layout, pressed keys, or active touch sequences. Forget them so a
        // later release/up cannot be delivered to the new engine without its
        // matching press/down. Client captures and routes remain untouched.
        self.input_layout = None;
        self.text_input.set_shell_capture(false);
        self.text_input.retire_flutter_generation();
        self.synchronize_input_method();
        self.visible_window_ids.clear();
        self.input_visibility_known = false;
        self.invalidate_idle_inhibition();
        self.client_input_route_cache = None;
        self.flutter_touch_slots.clear();
        // Cursor publication belongs to the Flutter engine generation too.
        // Replay native client state to the replacement renderer, while a
        // Flutter-owned route will select its shape after the fresh Add/Hover.
        self.queue_cursor_state_for_flutter_generation();
        input::retire_flutter_generation_keys(
            &mut self.flutter_keyboard_keys,
            &mut self.retired_keyboard_keys,
        );
        input::retire_flutter_generation_keys(
            &mut self.flutter_input_method_keys,
            &mut self.retired_input_method_keys,
        );
    }

    pub(super) fn surface_under(
        &self,
        position: Point<f64, Logical>,
    ) -> Option<(WlSurface, Point<f64, Logical>)> {
        self.space
            .element_under(position)
            .and_then(|(window, location)| {
                window
                    .surface_under(position - location.to_f64(), WindowSurfaceType::ALL)
                    .map(|(surface, offset)| {
                        (surface, saturating_point_add(offset, location).to_f64())
                    })
            })
    }

    pub(super) fn clamp_pointer(&self, position: Point<f64, Logical>) -> Point<f64, Logical> {
        if let Some(position) = constrain_pointer_to_outputs(
            position,
            self.outputs.iter().map(|output| output.logical_geometry),
        ) {
            return position;
        }

        // A live topology always has an output, but retain the bounding-box
        // fallback for defensive behavior during incomplete initialization.
        let right = f64::from(self.desktop_bounds.loc.x + self.desktop_bounds.size.w - 1);
        let bottom = f64::from(self.desktop_bounds.loc.y + self.desktop_bounds.size.h - 1);
        Point::from((
            position
                .x
                .clamp(f64::from(self.desktop_bounds.loc.x), right),
            position
                .y
                .clamp(f64::from(self.desktop_bounds.loc.y), bottom),
        ))
    }

    /// Projects the compositor-owned logical pointer into Flutter's physical
    /// atlas pixels, as required by `FlutterPointerEvent`.
    #[cfg(feature = "flutter")]
    pub(crate) fn flutter_pointer_position_physical(&self) -> (f64, f64) {
        (
            (self.pointer_location.x - self.atlas_origin.x) * self.atlas_scale,
            (self.pointer_location.y - self.atlas_origin.y) * self.atlas_scale,
        )
    }

    /// Projects the compositor-owned pointer into Flutter framework logical
    /// coordinates. Structured messages consumed directly by Dart do not pass
    /// through Flutter's physical-to-logical pointer-event conversion.
    #[cfg(feature = "flutter")]
    pub(super) fn flutter_scene_pointer_position(&self) -> (f64, f64) {
        (
            self.pointer_location.x - self.atlas_origin.x,
            self.pointer_location.y - self.atlas_origin.y,
        )
    }

    pub(super) fn control_output_under_pointer(&self) -> Option<(&str, i64)> {
        let pointer = Point::from((
            self.pointer_location.x.floor() as i32,
            self.pointer_location.y.floor() as i32,
        ));
        self.outputs.iter().find_map(|entry| {
            if !entry.logical_geometry.contains(pointer) {
                return None;
            }
            Some((entry.connector.as_str(), i64::try_from(entry.id.0).ok()?))
        })
    }

    pub fn render(
        &mut self,
        renderer: &mut GlesRenderer,
        dmabuf: &mut Dmabuf,
    ) -> Result<(), Box<dyn Error>> {
        let mut framebuffer = renderer.bind(dmabuf)?;
        let output_result = smithay::desktop::space::render_output::<
            _,
            WaylandSurfaceRenderElement<GlesRenderer>,
            _,
            _,
        >(
            &self.atlas_output,
            renderer,
            &mut framebuffer,
            1.0,
            0,
            [&self.space],
            &[],
            &mut self.damage_tracker,
            [0.015, 0.02, 0.035, 1.0],
        )?;
        drop(output_result);

        if !matches!(self.cursor_status, CursorImageStatus::Hidden) {
            let logical_cursor = self.pointer_location - self.atlas_origin;
            let cursor_rect = Rectangle::<i32, Physical>::new(
                (
                    (logical_cursor.x * self.atlas_scale).round() as i32,
                    (logical_cursor.y * self.atlas_scale).round() as i32,
                )
                    .into(),
                (12, 20).into(),
            );
            let mut frame =
                renderer.render(&mut framebuffer, self.atlas_size, Transform::Normal)?;
            frame.clear(Color32F::new(0.96, 0.98, 1.0, 1.0), &[cursor_rect])?;
            frame.finish()?.wait()?;
        }
        Ok(())
    }

    pub fn frame_submitted(&mut self) -> Result<(), Box<dyn Error>> {
        debug_assert!(self.seat.get_keyboard().is_some());
        debug_assert!(self.seat.get_pointer().is_some());
        debug_assert!(self.seat.get_touch().is_some());
        let elapsed = self.start_time.elapsed();
        let windows = self
            .space
            .elements()
            .map(|window| {
                // A frame callback is one-shot even when the atlas spans several
                // CRTCs. Attribute it to the physical output owning this window
                // instead of sending once per output (or hardcoding output zero).
                let frame_output = self
                    .output_for_geometry(self.window_geometry_target(window))
                    .map(|entry| entry.output.clone())
                    .unwrap_or_else(|| self.atlas_output.clone());
                (window.clone(), frame_output)
            })
            .collect::<Vec<_>>();
        self.presentation.submitted(windows, elapsed);
        self.display_handle.flush_clients()?;
        Ok(())
    }

    #[cfg(feature = "flutter")]
    pub fn outputs_submitted(&mut self, output_ids: &[OutputId]) -> Result<(), Box<dyn Error>> {
        if output_ids.is_empty() {
            return Ok(());
        }

        self.presentation.begin_output_batch();
        for entry in &mut self.outputs {
            entry.submitted_this_batch = output_ids.contains(&entry.id);
            if entry.submitted_this_batch {
                entry.presentation_batch.begin(&entry.output);
                for window in self.output_window_membership.windows(entry.id) {
                    entry
                        .presentation_batch
                        .submit_window(&entry.output, window);
                }
            }
        }
        // Submission only captures presentation-feedback objects. Protocol
        // events are emitted by the matching page flip, so there is nothing
        // to flush on this boundary.
        Ok(())
    }

    #[cfg(feature = "flutter")]
    pub fn outputs_presented(
        &mut self,
        outputs: &[crate::PresentedOutput],
    ) -> Result<(), Box<dyn Error>> {
        if outputs.is_empty() {
            return Ok(());
        }
        let mut feedback_delivered = false;
        let observed_now = Instant::now();
        for presented_output in outputs.iter().copied() {
            if let Some(entry) = self
                .outputs
                .iter_mut()
                .find(|entry| entry.id == presented_output.id)
            {
                feedback_delivered |= self.presentation.presented_output(
                    &mut entry.presentation_batch,
                    presented_output.presented_at,
                    observed_now.saturating_duration_since(presented_output.observed_at),
                    presented_output.sequence,
                );
            }
        }
        if feedback_delivered {
            self.display_handle.flush_clients()?;
        }
        Ok(())
    }

    #[cfg(feature = "flutter")]
    pub fn frame_tick(&mut self, tick: FrameTick) -> Result<(), Box<dyn Error>> {
        let callback_time = self.presentation.timeline_time(tick.render_deadline);
        let mut sent = 0usize;
        if !self.pending_frame_callback_windows.is_empty() {
            for window in self.output_window_membership.windows(tick.output) {
                let Some(root) = window.wl_surface() else {
                    continue;
                };
                if !self.pending_frame_callback_windows.remove(&root.id()) {
                    continue;
                }
                sent = sent.saturating_add(presentation::send_window_frame_callbacks(
                    window,
                    callback_time,
                ));
            }
        }
        let callback_millis = callback_time.as_millis() as u32;
        if !self.pending_input_method_frame_callbacks.is_empty() {
            for popup in self.input_method.visible_popups() {
                if self
                    .pending_input_method_frame_callbacks
                    .contains(&popup.surface().id())
                    && self
                        .surface_id(popup.surface())
                        .is_some_and(|surface_id| self.visible_window_ids.contains(&surface_id))
                {
                    self.pending_input_method_frame_callbacks
                        .remove(&popup.surface().id());
                    sent = sent.saturating_add(presentation::send_surface_frame_callbacks(
                        popup.surface(),
                        callback_millis,
                    ));
                }
            }
        }
        if sent == 0 {
            return Ok(());
        }
        self.display_handle.flush_clients()?;
        Ok(())
    }

    pub fn after_present(&mut self) -> Result<(), Box<dyn Error>> {
        self.presentation.presented();
        self.space.refresh();
        self.popups.cleanup();
        self.display_handle.flush_clients()?;
        Ok(())
    }

    pub(super) fn unconstrain_popup(&self, popup: &PopupSurface) {
        let popup_kind = PopupKind::Xdg(popup.clone());
        let Ok(root) = find_popup_root_surface(&popup_kind) else {
            return;
        };
        let Some(window) = self.space.elements().find(|window| {
            window
                .toplevel()
                .is_some_and(|top| top.wl_surface() == &root)
        }) else {
            return;
        };
        let window_geometry = self.space.element_geometry(window).unwrap_or_default();
        let parent_offset = get_popup_toplevel_coords(&popup_kind);
        let positioner = popup.with_pending_state(|state| state.positioner);
        let desired_geometry = positioner.get_geometry();
        let anchor = saturating_point_add(
            saturating_point_add(
                saturating_point_add(window_geometry.loc, parent_offset),
                positioner.anchor_rect.loc,
            ),
            Point::from((
                positioner.anchor_rect.size.w / 2,
                positioner.anchor_rect.size.h / 2,
            )),
        );
        let desired_global = Rectangle::new(
            saturating_point_add(
                saturating_point_add(window_geometry.loc, parent_offset),
                desired_geometry.loc,
            ),
            desired_geometry.size,
        );
        let output_geometry = choose_popup_output(
            self.outputs
                .iter()
                .filter_map(|entry| self.space.output_geometry(&entry.output)),
            anchor,
            desired_global,
        );
        let Some(output_geometry) = output_geometry else {
            return;
        };
        let mut target = output_geometry;
        target.loc = saturating_point_sub(
            saturating_point_sub(target.loc, parent_offset),
            window_geometry.loc,
        );
        popup.with_pending_state(|state| {
            state.geometry = state.positioner.get_unconstrained_geometry(target);
        });
    }
}

#[cfg(test)]
mod pointer_confinement_tests {
    use super::*;

    fn output(x: i32, y: i32, width: i32, height: i32) -> Rectangle<i32, Logical> {
        Rectangle::new((x, y).into(), (width, height).into())
    }

    fn constrain(
        position: (f64, f64),
        outputs: &[Rectangle<i32, Logical>],
    ) -> Option<Point<f64, Logical>> {
        constrain_pointer_to_outputs(Point::from(position), outputs.iter().copied())
    }

    #[test]
    fn offset_rotated_workstation_layout_rejects_its_empty_regions() {
        let outputs = [output(0, 563, 2560, 1440), output(2560, 0, 1440, 2560)];

        assert_eq!(
            constrain((1000.0, 800.0), &outputs),
            Some((1000.0, 800.0).into())
        );
        assert_eq!(
            constrain((3000.0, 100.0), &outputs),
            Some((3000.0, 100.0).into())
        );
        assert_eq!(
            constrain((1000.0, 100.0), &outputs),
            Some((1000.0, 563.0).into())
        );
        assert_eq!(
            constrain((1000.0, 2400.0), &outputs),
            Some((1000.0, 2003.0_f64.next_down()).into())
        );
        assert_eq!(
            constrain((4500.0, 1000.0), &outputs),
            Some((4000.0_f64.next_down(), 1000.0).into())
        );
    }

    #[test]
    fn subpixel_motion_crosses_an_adjoining_output_seam() {
        let outputs = [output(0, 563, 2560, 1440), output(2560, 0, 1440, 2560)];

        assert_eq!(
            constrain((2559.75, 1000.0), &outputs),
            Some((2559.75, 1000.0).into())
        );
        assert_eq!(
            constrain((2560.0, 1000.0), &outputs),
            Some((2560.0, 1000.0).into())
        );
    }

    #[test]
    fn negative_and_disconnected_output_coordinates_project_to_the_nearest_edge() {
        let negative = [output(-1920, -360, 1920, 1080)];
        assert_eq!(
            constrain((-2000.0, 0.0), &negative),
            Some((-1920.0, 0.0).into())
        );

        let disconnected = [output(0, 0, 100, 100), output(300, 0, 100, 100)];
        assert_eq!(
            constrain((160.0, 50.0), &disconnected),
            Some((100.0_f64.next_down(), 50.0).into())
        );
        assert_eq!(
            constrain((250.0, 50.0), &disconnected),
            Some((300.0, 50.0).into())
        );
    }

    #[test]
    fn topology_removal_rehomes_a_pointer_from_a_removed_output() {
        let retained = [output(0, 0, 100, 100)];

        assert_eq!(
            constrain((350.0, 50.0), &retained),
            Some((100.0_f64.next_down(), 50.0).into())
        );
        assert_eq!(constrain((0.0, 0.0), &[]), None);
    }
}
