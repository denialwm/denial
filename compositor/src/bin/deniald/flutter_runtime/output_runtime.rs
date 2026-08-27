//! Output geometry, external-texture staging, raster authorization, and presentation.

use super::*;

impl FlutterRuntime {
    /// Installs new logical geometry while retaining the engine, EGL contexts
    /// and native output pools. This path is valid only when connector IDs and
    /// native target extents are unchanged, as is the case for compositor-side
    /// rotation.
    pub fn reconfigure_output_geometry(
        &mut self,
        snapshot: &TopologySnapshot,
        atlas: &AtlasPlan,
        transition: OutputGeometryTransition,
    ) -> Result<(), Box<dyn Error>> {
        let plans = atlas
            .render_outputs(snapshot)
            .ok_or("Flutter render outputs do not match the updated topology")?;
        if plans.len() != self.render_outputs.len() {
            return Err("transform-only topology changed the physical output set".into());
        }

        let mut ffi_outputs = Vec::with_capacity(plans.len());
        let mut runtime_outputs = Vec::with_capacity(plans.len());
        for plan in plans {
            let resident = self
                .render_outputs
                .iter()
                .find(|output| output.output_id == plan.output_id)
                .ok_or("updated topology has no resident Flutter output")?;
            let atlas_output = atlas
                .outputs
                .iter()
                .find(|output| output.id == plan.output_id)
                .ok_or("updated Flutter output is absent from its atlas")?;
            let snapshot_output = snapshot
                .outputs
                .iter()
                .find(|output| output.id == plan.output_id)
                .ok_or("updated Flutter output is absent from its topology")?;
            if resident.render_view_id != plan.render_view_id
                || resident.target_size != plan.target_size
            {
                return Err("updated topology changed a resident physical render target".into());
            }
            ffi_outputs.push(RenderOutput {
                render_view_id: plan.render_view_id.get(),
                // Pool identity is structural. A logical projection update
                // must continue to match frames to the resident pool.
                configuration_generation: resident.configuration_generation,
                source_physical_x: f64::from(plan.source_rect.x),
                source_physical_y: f64::from(plan.source_rect.y),
                source_physical_width: f64::from(plan.source_rect.width),
                source_physical_height: f64::from(plan.source_rect.height),
                target_width: plan.target_size.width as usize,
                target_height: plan.target_size.height as usize,
                scale_120: plan.scale_120,
                source_to_target_transform: RenderOutputTransform {
                    scale_x: plan.source_to_target_transform.scale_x,
                    skew_x: plan.source_to_target_transform.skew_x,
                    translate_x: plan.source_to_target_transform.translate_x,
                    skew_y: plan.source_to_target_transform.skew_y,
                    scale_y: plan.source_to_target_transform.scale_y,
                    translate_y: plan.source_to_target_transform.translate_y,
                },
            });
            runtime_outputs.push(RuntimeRenderOutput {
                output_id: plan.output_id,
                render_view_id: plan.render_view_id,
                configuration_generation: resident.configuration_generation,
                target_size: resident.target_size,
                transform: snapshot_output.transform,
                logical_x: atlas_output.logical_rect.x - atlas.logical_origin.0,
                logical_y: atlas_output.logical_rect.y - atlas.logical_origin.1,
                logical_width: atlas_output.logical_rect.width,
                logical_height: atlas_output.logical_rect.height,
            });
        }

        let host = self
            .host
            .as_ref()
            .ok_or("Flutter runtime is shutting down")?;
        let mut rotation_animation = (transition == OutputGeometryTransition::AnimatedRotation)
            .then(|| {
                OutputRotationAnimation::new(
                    &self.render_outputs,
                    &self.render_output_configuration,
                    &runtime_outputs,
                    &ffi_outputs,
                    Instant::now(),
                )
            })
            .flatten();
        if let Some(animation) = rotation_animation.as_mut() {
            let (initial_outputs, sample) = animation.sample(animation.started_at);
            debug_assert!(!sample.complete);
            debug_assert!(!sample.geometry_resize_due);
            host.engine()
                .set_render_outputs_reusing(initial_outputs, &mut self.render_output_ffi_scratch)?;
            self.output_rotation_animation = rotation_animation;
            self.pending_output_geometry = Some(PendingOutputGeometry {
                snapshot: snapshot.clone(),
                atlas: atlas.clone(),
                ffi_outputs,
                runtime_outputs,
            });
            return Ok(());
        }

        host.engine()
            .set_render_outputs_reusing(&ffi_outputs, &mut self.render_output_ffi_scratch)?;
        self.output_rotation_animation = None;
        self.pending_output_geometry = None;
        self.publish_output_geometry(snapshot, atlas, ffi_outputs, runtime_outputs)
    }

    pub(super) fn publish_output_geometry(
        &mut self,
        snapshot: &TopologySnapshot,
        atlas: &AtlasPlan,
        ffi_outputs: Vec<RenderOutput>,
        runtime_outputs: Vec<RuntimeRenderOutput>,
    ) -> Result<(), Box<dyn Error>> {
        let host = self
            .host
            .as_ref()
            .ok_or("Flutter runtime is shutting down")?;
        let device_pixel_ratio = f64::from(atlas.engine_scale_120) / f64::from(SCALE_BASE);
        host.engine()
            .send_window_metrics(&sys::FlutterWindowMetricsEvent {
                struct_size: mem::size_of::<sys::FlutterWindowMetricsEvent>(),
                width: atlas.pixel_size.width as usize,
                height: atlas.pixel_size.height as usize,
                pixel_ratio: device_pixel_ratio,
                display_id: 0,
                view_id: 0,
                ..sys::FlutterWindowMetricsEvent::default()
            })?;
        self.device_pixel_ratio = device_pixel_ratio;
        let layout_update = self.wire.update_topology(snapshot, atlas)?;
        host.engine()
            .send_platform_message(wire::TO_FLUTTER_CHANNEL, layout_update)?;

        self.render_output_configuration = ffi_outputs;
        self.render_outputs = runtime_outputs;
        self.texture_output_membership.clear();
        let cursor_ids = self.cursor_texture_ids.clone();
        self.install_cursor_texture_membership(&cursor_ids);
        for output in &self.render_outputs {
            self.pending_output_updates
                .entry(output.output_id)
                .or_default()
                .extend(self.scene_texture_ids.iter().copied());
            self.pending_output_updates
                .entry(output.output_id)
                .or_default()
                .extend(self.cursor_texture_ids.iter().copied());
        }
        Ok(())
    }

    pub fn output_rotation_animation_active(&self) -> bool {
        self.output_rotation_animation.is_some()
    }

    /// Advances only the synthetic output projection. The engine applies this
    /// to its retained layer tree, so the Dart scene, external textures, EGL
    /// targets and native scanout buffers remain untouched between samples.
    pub fn advance_output_rotation_animation(
        &mut self,
        now: Instant,
    ) -> Result<OutputRotationAdvance, Box<dyn Error>> {
        let Some(animation) = self.output_rotation_animation.as_mut() else {
            return Ok(OutputRotationAdvance::default());
        };
        let (outputs, sample) = animation.sample(now);
        self.host
            .as_ref()
            .ok_or("Flutter runtime is shutting down")?
            .engine()
            .set_render_outputs_reusing(outputs, &mut self.render_output_ffi_scratch)?;
        if sample.geometry_resize_due {
            let pending = self
                .pending_output_geometry
                .take()
                .ok_or("output rotation reached its resize point without pending geometry")?;
            self.publish_output_geometry(
                &pending.snapshot,
                &pending.atlas,
                pending.ffi_outputs,
                pending.runtime_outputs,
            )?;
        }
        if sample.complete {
            if self.pending_output_geometry.is_some() {
                return Err("output rotation completed before publishing pending geometry".into());
            }
            self.output_rotation_animation = None;
        }
        Ok(OutputRotationAdvance {
            advanced: true,
            geometry_published: sample.geometry_resize_due,
        })
    }

    pub fn publish_output(&self, output: &ReadyOutputFrame) -> Result<(), Box<dyn Error>> {
        self.handler.publish_output(output).map_err(Into::into)
    }

    pub fn release_output(&self, output: OutputId, index: usize) -> Result<(), Box<dyn Error>> {
        self.handler
            .release_output(output, index)
            .map_err(Into::into)
    }

    pub(crate) fn retain_output(
        &self,
        output: OutputId,
        index: usize,
    ) -> Result<OutputBufferLease, Box<dyn Error>> {
        self.handler.retain_output(output, index)?;
        Ok(OutputBufferLease {
            handler: Arc::clone(&self.handler),
            output,
            index,
        })
    }

    pub fn has_output_updates(&self) -> bool {
        !self.pending_output_updates.is_empty()
    }

    pub fn take_output_updates(&mut self) -> BTreeMap<OutputId, BTreeSet<i64>> {
        mem::take(&mut self.pending_output_updates)
    }

    pub fn recycle_output_updates(&mut self, mut updates: BTreeMap<OutputId, BTreeSet<i64>>) {
        for textures in updates.values_mut() {
            textures.clear();
        }
        updates.clear();
        debug_assert!(self.pending_output_updates.is_empty());
        self.pending_output_updates = updates;
    }

    pub(super) fn rebuild_texture_output_membership(
        &mut self,
        windows: &[wire::WindowDescription],
    ) {
        self.texture_output_membership.clear();
        for window in windows {
            let outputs: Arc<[OutputId]> = self
                .render_outputs
                .iter()
                .filter(|output| {
                    output.intersects(
                        window.geometry_x,
                        window.geometry_y,
                        window.geometry_width,
                        window.geometry_height,
                    )
                })
                .map(|output| output.output_id)
                .collect::<Vec<_>>()
                .into();
            if outputs.is_empty() {
                continue;
            }
            let mut remember = |texture_id: u64| {
                if let Ok(texture_id) = i64::try_from(texture_id)
                    && texture_id > 0
                {
                    self.texture_output_membership
                        .insert(texture_id, Arc::clone(&outputs));
                }
            };
            remember(window.texture_id);
            for surface in &window.surfaces {
                remember(surface.texture_id);
            }
        }
    }

    pub(super) fn stage_changed_textures(&mut self) {
        for texture_id in self.changed_texture_scratch.drain(..) {
            if let Some(outputs) = self.texture_output_membership.get(&texture_id) {
                for output in outputs.iter() {
                    self.pending_output_updates
                        .entry(*output)
                        .or_default()
                        .insert(texture_id);
                }
            } else {
                for output in &self.render_outputs {
                    self.pending_output_updates
                        .entry(output.output_id)
                        .or_default()
                        .insert(texture_id);
                }
            }
        }
    }

    pub fn with_frame_readiness<T>(
        &self,
        action: impl FnOnce(PendingFrame, &mut dyn FnMut(OutputId) -> bool) -> T,
    ) -> T {
        // Output authorization is a bounded per-output queue reservation, not
        // a global raster lock. A framework frame can legitimately consume
        // OnVsync without producing a raster task, so expire an unclaimed
        // reservation after two of that output's own intervals.
        let pending = PendingFrame {
            flutter_requested: self.handler.has_pending_vsync(),
        };
        let (result, expired) = self
            .handler
            .with_output_target_availability(Instant::now(), |target_available| {
                action(pending, target_available)
            });
        if expired > 0 {
            debug!(
                expired,
                "released output render authorizations which produced no raster task"
            );
        }
        result
    }

    pub fn output_target_available(&self, output: OutputId) -> bool {
        self.handler.output_target_available(output)
    }

    pub fn arm_screenshot_frame(
        &mut self,
        output: OutputId,
        request_id: u64,
    ) -> Result<(), Box<dyn Error>> {
        if request_id == 0 || self.pending_screenshot_frame.is_some() {
            return Err("a screenshot frame is already armed".into());
        }
        self.pending_screenshot_frame = Some((output, request_id));
        Ok(())
    }

    pub fn cancel_screenshot_frame(&mut self, request_id: u64) {
        if self
            .pending_screenshot_frame
            .is_some_and(|(_, pending)| pending == request_id)
        {
            self.pending_screenshot_frame = None;
        }
        self.handler.cancel_screenshot_frame(request_id);
    }

    pub(super) fn collect_external_texture_updates(&mut self) {
        self.handler
            .advance_all_external_texture_sources(&mut self.pending_frame_texture_ids);
        self.pending_frame_texture_ids.sort_unstable();
        self.pending_frame_texture_ids.dedup();
    }

    pub(super) fn publish_external_texture_transaction(&mut self) -> Result<bool, Box<dyn Error>> {
        if self.pending_frame_texture_ids.is_empty() {
            return Ok(false);
        }
        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        engine.schedule_frame_for_external_textures(&self.pending_frame_texture_ids)?;
        self.pending_frame_texture_ids.clear();
        Ok(true)
    }

    /// Execute exactly the output work authorized by the display clocks.
    pub fn render_authorized_outputs(
        &mut self,
        requests: &[OutputFrameRequest],
        texture_ids: impl IntoIterator<Item = i64>,
        flutter_output: Option<OutputId>,
    ) -> Result<bool, Box<dyn Error>> {
        if !self.kms_frame_clock_enabled {
            return Err("the KMS Flutter frame clock is not enabled".into());
        }
        if requests.is_empty() {
            return Ok(false);
        }

        self.handler
            .authorize_outputs(requests, &mut self.render_view_scratch);
        if self.render_view_scratch.is_empty() {
            return Ok(false);
        }

        let flutter_tick = flutter_output.and_then(|output_id| {
            let render_view_id = self
                .render_outputs
                .iter()
                .find(|output| output.output_id == output_id)?
                .render_view_id
                .get();
            self.render_view_scratch
                .contains(&render_view_id)
                .then(|| {
                    requests
                        .iter()
                        .find(|request| request.tick.output == output_id)
                        .map(|request| request.tick)
                })
                .flatten()
        });
        self.render_texture_scratch.clear();
        self.render_texture_scratch.extend(texture_ids);
        self.render_texture_scratch.sort_unstable();
        self.render_texture_scratch.dedup();
        self.changed_texture_scratch.clear();
        self.handler.advance_external_texture_sources(
            &self.render_texture_scratch,
            &mut self.changed_texture_scratch,
        );
        self.stage_changed_textures();

        let selected_tick = flutter_tick.unwrap_or_else(|| {
            requests
                .iter()
                .filter(|request| {
                    self.render_outputs
                        .iter()
                        .find(|output| output.output_id == request.tick.output)
                        .is_some_and(|output| {
                            self.render_view_scratch
                                .contains(&output.render_view_id.get())
                        })
                })
                .min_by_key(|request| request.tick.presentation_target)
                .map(|request| request.tick)
                .expect("an authorized render view has an output-timeline request")
        });

        let baton = if flutter_tick.is_some() {
            let (baton, _) = self.handler.take_next_vsync();
            let Some(baton) = baton else {
                self.handler
                    .cancel_output_authorizations(&self.render_view_scratch);
                return Err("a KMS-authorized Flutter frame has no AwaitVSync baton".into());
            };
            Some(baton)
        } else {
            None
        };

        let tagged_screenshot = self.pending_screenshot_frame.and_then(|pending| {
            self.render_outputs
                .iter()
                .find(|output| output.output_id == pending.0)
                .filter(|output| {
                    self.render_view_scratch
                        .contains(&output.render_view_id.get())
                })
                .map(|_| pending)
        });
        if let Some((output, request_id)) = tagged_screenshot {
            if let Err(error) = self
                .handler
                .tag_next_frame_for_screenshot(output, request_id)
            {
                if let Some(baton) = baton {
                    self.handler.restore_vsync(baton);
                }
                self.handler
                    .cancel_output_authorizations(&self.render_view_scratch);
                return Err(error.into());
            }
            self.pending_screenshot_frame = None;
        }

        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let now_nanos = engine.current_time_nanos();
        let observation_delay =
            Instant::now().saturating_duration_since(selected_tick.render_deadline);
        if let Some(audit) = &self.handler.render_audit {
            lock(audit).record_render_authorization(observation_delay);
        }
        let target_after_deadline = selected_tick
            .presentation_target
            .saturating_duration_since(selected_tick.render_deadline);
        let (frame_start_nanos, frame_target_nanos) =
            timeline_vsync_timestamps(now_nanos, observation_delay, target_after_deadline);

        if let Err(error) = engine.render_outputs(
            &self.render_view_scratch,
            &self.render_texture_scratch,
            flutter_tick.is_some(),
            frame_start_nanos,
            frame_target_nanos,
        ) {
            if let Some(baton) = baton {
                self.handler.restore_vsync(baton);
            }
            if let Some((output, request_id)) = tagged_screenshot {
                self.handler.cancel_screenshot_frame(request_id);
                self.pending_screenshot_frame = Some((output, request_id));
            }
            self.handler
                .cancel_output_authorizations(&self.render_view_scratch);
            return Err(error.into());
        }

        if let Some(baton) = baton
            && let Err(error) = engine.on_vsync(baton, frame_start_nanos, frame_target_nanos)
        {
            self.handler.restore_vsync(baton);
            if let Some((output, request_id)) = tagged_screenshot {
                self.handler.cancel_screenshot_frame(request_id);
                self.pending_screenshot_frame = Some((output, request_id));
            }
            self.handler
                .cancel_output_authorizations(&self.render_view_scratch);
            return Err(error.into());
        }
        Ok(baton.is_some())
    }
}
