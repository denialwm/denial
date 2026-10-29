//! Frame production and presentation: render events, page flips, output
//! ticks, and the display power that decides which outputs present.

use super::*;

impl Session<'_, '_> {
    pub(super) fn service_kms_lifecycle(&mut self) -> Result<bool, Box<dyn Error>> {
        let Self {
            drm,
            scanouts,
            swapchain,
            event_loop,
            events,
            scheduler,
            deadline,
            ..
        } = self;
        let deadline = *deadline;
        if events
            .lifecycle
            .requires_kms_service(drm.is_active(), events.device_removed)
            && let Err(error) =
                service_session_lifecycle(drm, scanouts, &**swapchain, event_loop, events, deadline)
        {
            if !error.is::<kms_session::KmsResumeError>() {
                return Err(error);
            }
            warn!(%error, "scheduling KMS recovery after session resume failed");
            events.kms_presentation_recovery_requested = true;
        }
        if !events.kms_presentation_recovery_requested {
            return Ok(false);
        }
        events.kms_presentation_recovery_requested = false;
        scheduler.shutdown_volition();
        recover_stalled_kms_presentation(drm, event_loop, events)?;
        Ok(true)
    }

    pub(super) fn acknowledge_render_events(&mut self) -> Result<bool, Box<dyn Error>> {
        let Self {
            drm,
            scanouts,
            event_loop,
            events,
            flutter,
            scheduler,
            volition_events,
            ..
        } = self;
        if !events.sampled_buffer_releases.is_empty() {
            install_sampled_buffer_releases(event_loop, events)?;
        }
        if !events.ready_fence_signals.is_empty() {
            scheduler.acknowledge_ready_fences(flutter, events.ready_fence_signals.drain(..))?;
        }
        volition_events.drain_into(&mut events.volition_events);
        if events.volition_events.is_empty() {
            return Ok(false);
        }
        let volition_events = std::mem::take(&mut events.volition_events);
        let Some(stall) =
            scheduler.acknowledge_volition_events(volition_events, scanouts, events)?
        else {
            return Ok(false);
        };
        let commit = stall.commit();
        error!(
            stream = commit.stream,
            framebuffer_index = commit.frame,
            %stall,
            "KMS lookahead lost a usable presentation state; rebuilding the DRM and render stack in this session"
        );
        scheduler.shutdown_volition();
        recover_stalled_kms_presentation(drm, event_loop, events)?;
        Ok(true)
    }

    pub(super) fn synchronize_software_dimming(&mut self) -> Result<(), Box<dyn Error>> {
        let Self {
            drm,
            scanouts,
            events,
            flutter,
            gamma_topology: known_topology,
            ..
        } = self;
        let requests = flutter
            .drain_software_dimming_requests()
            .collect::<Vec<_>>();
        let topology_changed = gamma_topology_changed(
            known_topology.as_deref(),
            scanouts
                .iter()
                .map(|scanout| (scanout.output.id, scanout.output.crtc)),
        );
        let external_changes_pending = events.frontend().has_pending_gamma_changes();
        if !gamma_work_pending(
            topology_changed,
            !requests.is_empty() || !events.control.software_dimming.is_empty(),
            external_changes_pending,
            events.gamma_reapply_requested || events.scanout_rebased,
        ) {
            return Ok(());
        }
        if topology_changed {
            *known_topology = Some(
                scanouts
                    .iter()
                    .map(|scanout| (scanout.output.id, scanout.output.crtc))
                    .collect(),
            );
        }
        let gamma_reapply_requested = std::mem::take(&mut events.gamma_reapply_requested);
        let force_gamma_reapply = events.scanout_rebased || gamma_reapply_requested;
        let states = gamma_control::synchronize_gamma_control(
            drm,
            scanouts,
            events,
            &requests,
            force_gamma_reapply,
        );
        for state in states {
            flutter.send_software_dimming_state(state)?;
        }
        Ok(())
    }

    pub(super) fn service_page_flip_completions(
        &mut self,
        iteration_now: Instant,
    ) -> Result<bool, Box<dyn Error>> {
        let Self {
            renderer,
            drm,
            swapchain,
            scanouts,
            event_loop,
            events,
            flutter,
            scheduler,
            frame_scheduler,
            ..
        } = self;
        let (changed, power) = events
            .fingerprint
            .service(drm, renderer, scanouts, flutter)?;
        for (output, powered) in power {
            events.output_power_requests.insert(output, powered);
        }
        if changed {
            frame_scheduler.mark_all_dirty();
            wayland_frontend::reset_all_input_devices(events);
        }
        if std::mem::take(&mut events.control.repaint_outputs) {
            frame_scheduler.mark_all_dirty();
        }
        for app_id in std::mem::take(&mut events.control.repaint_apps) {
            let textures = flutter.app_texture_ids(&app_id);
            for scanout in scanouts.iter() {
                frame_scheduler.mark_app_dirty(scanout.output.id, textures.iter().copied());
            }
        }
        let runtime = &mut **flutter;
        scheduler.handle_completions(
            runtime,
            swapchain
                .outputs_mut()
                .ok_or("page-flip completion has no physical output pools")?,
            scanouts,
            events,
        )?;
        for presented in scheduler
            .presented_outputs()
            .iter()
            .filter(|presented| presented.presented_at.is_some())
        {
            frame_scheduler.observe_presentation(
                presented.id,
                presented.timeline_target,
                presented.observed_at,
            );
        }
        if !drm.is_active() {
            return Ok(false);
        }
        let Some(stall) = scheduler.presentation_stall(iteration_now) else {
            return Ok(false);
        };
        let output = scanouts
            .get(stall.scanout_index)
            .map(|scanout| scanout.output.name.as_str())
            .unwrap_or("unknown");
        error!(
            output,
            framebuffer_index = stall.framebuffer_index,
            pending_frames = stall.pending_frames,
            stalled_ms = stall.elapsed.as_millis(),
            "KMS presentation stopped making progress; rebuilding the DRM and render stack in this session"
        );
        // A DPMS wake can accept a commit while its link is still training and
        // then withhold the flip event. Recover synchronously without ending the
        // display-manager session.
        scheduler.shutdown_volition();
        recover_stalled_kms_presentation(drm, event_loop, events)?;
        Ok(true)
    }

    pub(super) fn publish_completed_flutter_frames(&mut self) -> Result<(), Box<dyn Error>> {
        let Self {
            flutter: runtime,
            scheduler,
            swapchain,
            scanouts,
            events,
            event_loop,
            frame_scheduler,
            raster_frames,
            ..
        } = self;
        // Raster completion is published before its callback wakeup. Retire that
        // wakeup and transfer the finished batch before the timeline decision.
        runtime.observe_frame_ready_events(&mut events.flutter_events);
        submit_ready_frames(runtime, scheduler, swapchain, scanouts, events)?;
        let mut published = false;
        loop {
            let Some(ready) =
                runtime.take_ready_frame(|output| scheduler.ready_handoff_available(output))
            else {
                break;
            };
            let output = ready.output_id;
            let dirty_serial = ready.request.dirty_serial;
            if let Some(watch) = scheduler.publish_ready(runtime, ready)? {
                install_ready_fence_watch(event_loop, watch)?;
            }
            frame_scheduler.complete_render(output, dirty_serial);
            *raster_frames = raster_frames.saturating_add(1);
            published = true;
        }
        // A freshly published frame may be ready for handoff immediately. Keep
        // that submission on this wake even when no output timeline tick is due.
        if published {
            submit_ready_frames(runtime, scheduler, swapchain, scanouts, events)?;
        }
        Ok(())
    }

    pub(super) fn schedule_next_flutter_frame(&mut self) -> Result<(), Box<dyn Error>> {
        let Self {
            flutter: runtime,
            scheduler,
            topology,
            ready_output_apply,
            frame_limit,
            raster_frames,
            delivered_vsyncs,
            frame_scheduler,
            events,
            ..
        } = self;
        let ready_output_apply = ready_output_apply.is_some();
        let (frame_limit, raster_frames) = (*frame_limit, *raster_frames);
        // Publish a Wayland buffer committed immediately before an output
        // deadline so the same timer decision sees its dirty state.
        try_synchronize_flutter_buffers(runtime, events)?;
        let frame_now = Instant::now();
        if runtime.output_rotation_animation_active() && frame_scheduler.output_tick_due(frame_now)
        {
            let advance = runtime.advance_output_rotation_animation(frame_now)?;
            if advance.advanced {
                frame_scheduler.mark_all_dirty();
            }
            if advance.geometry_published {
                let snapshot = topology.snapshot();
                let atlas = AtlasPlan::for_snapshot(&snapshot)
                    .ok_or("animated output resize produced no Flutter desktop geometry")?;
                synchronize_resident_flutter_geometry_state(events, &atlas);
            }
        }
        collect_flutter_output_damage(runtime, frame_scheduler);

        let transaction_waiting = output_transaction_waiting(
            ready_output_apply,
            !events.control.output_applies.is_empty(),
            events.resident_geometry_reconfigure_requested,
        );
        if transaction_waiting || frame_limit.is_some_and(|limit| raster_frames >= limit) {
            return Ok(());
        }
        let frame_action = runtime.with_frame_readiness(|pending, target_available| {
            frame_scheduler.step_with_output_readiness(frame_now, pending, |output| {
                (scheduler.render_available(output), target_available(output))
            })
        });
        if let frame_scheduler::FrameAction::Render { flutter_output } = frame_action
            && runtime.render_authorized_outputs(
                frame_scheduler.render_requests(),
                frame_scheduler.render_texture_ids(),
                flutter_output,
            )?
        {
            frame_scheduler.flutter_frame_dispatched();
            *delivered_vsyncs = delivered_vsyncs.saturating_add(1);
        }
        Ok(())
    }

    pub(super) fn dispatch_output_ticks(&mut self) -> Result<(), Box<dyn Error>> {
        let Self {
            renderer,
            flutter: runtime,
            scheduler,
            swapchain,
            scanouts,
            events,
            frame_scheduler,
            ..
        } = self;
        for tick in frame_scheduler.output_ticks().iter().copied() {
            events.frontend_mut().frame_tick(tick)?;
            scheduler.process_screencopies_at_tick(
                tick,
                renderer,
                runtime,
                swapchain
                    .outputs()
                    .ok_or("screencopy has no physical output pools")?,
                scanouts,
                events,
            )?;
        }
        Ok(())
    }

    pub(super) fn synchronize_power_policy(
        &mut self,
        background_services_due: bool,
        background_maintenance_due: bool,
        scanout_rebased: bool,
        now: Instant,
    ) -> Result<bool, Box<dyn Error>> {
        let Self {
            scanouts,
            swapchain,
            scheduler,
            frame_scheduler,
            flutter,
            events,
            ..
        } = self;
        let output_control_was_dirty = events.output_control_dirty;
        if background_services_due {
            collect_output_power_requests(events);
        }
        if background_maintenance_due {
            synchronize_idle_dpms(scanouts, events, now);
        }
        dpms::synchronize_wake_gestures(scanouts, events);
        synchronize_power_button(scanouts, events);
        synchronize_fingerprint_display_wake(scanouts, scheduler, events);
        synchronize_sleep_transition(scanouts, events);
        if !scanout_rebased && !events.output_power_requests.is_empty() {
            let power_changed =
                apply_output_power_requests(flutter, scheduler, swapchain, scanouts, events)?;
            if power_changed {
                frame_scheduler.reconfigure(scanouts, Instant::now());
            }
        }
        release_sleep_delay_if_ready(scanouts, events);
        events
            .wifi_power_save
            .sync(scanouts.iter().any(|scanout| scanout.powered));
        // The output publisher normally clears this bit at the start of the
        // iteration, so a transition to dirty here asks for one publication
        // boundary before more work. During confirmation rollback publication is
        // deliberately deferred while the old geometry is still resident. That
        // pre-existing dirty bit must not keep short-circuiting the loop before
        // the topology transaction which can actually complete the rollback.
        Ok(output_control_publication_became_dirty(
            output_control_was_dirty,
            events.output_control_dirty,
        ))
    }
}
