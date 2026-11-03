//! Transactions that rebuild presentation: DRM topology changes and a
//! refreshed Flutter bundle.

use super::*;

#[derive(Clone, Copy)]
pub(super) struct TopologyReconfigurationRequest {
    scanout_rebased: bool,
    kms_reconfigure_requested: bool,
    resident_geometry_reconfigure_requested: bool,
}

pub(super) struct ObservedOutputTopology {
    outputs: Vec<ConnectedOutput>,
    changed: bool,
}

pub(super) enum OutputTopologyObservation {
    Stable,
    WaitingForOutputs,
    Reconfigure(ObservedOutputTopology),
}

pub(super) fn take_topology_reconfiguration_request(
    scanout_rebased: bool,
    events: &mut RuntimeState,
) -> Option<TopologyReconfigurationRequest> {
    let kms_reconfigure_requested = std::mem::take(&mut events.kms_reconfigure_requested);
    let resident_geometry_reconfigure_requested =
        std::mem::take(&mut events.resident_geometry_reconfigure_requested);
    if !events.topology_dirty
        && !scanout_rebased
        && !kms_reconfigure_requested
        && !resident_geometry_reconfigure_requested
    {
        return None;
    }
    events.topology_dirty = false;
    Some(TopologyReconfigurationRequest {
        scanout_rebased,
        kms_reconfigure_requested,
        resident_geometry_reconfigure_requested,
    })
}

impl Session<'_, '_> {
    pub(super) fn observe_output_topology(
        &mut self,
        request: TopologyReconfigurationRequest,
    ) -> Result<OutputTopologyObservation, Box<dyn Error>> {
        let Self {
            drm_scanner,
            drm,
            max_outputs,
            output_configuration,
            scanouts,
            outputs_disconnected,
            policy_journal,
            flutter,
            events,
            event_loop,
            ..
        } = self;
        let max_outputs = *max_outputs;
        let TopologyReconfigurationRequest {
            scanout_rebased,
            kms_reconfigure_requested,
            resident_geometry_reconfigure_requested,
        } = request;
        let ConfiguredOutputs { outputs, selection } =
            connected_outputs(drm_scanner, drm, max_outputs, output_configuration)?;
        policy_journal.record(&selection);
        // The DPMS debounce judges connectors. A fallback output and the panels
        // under a closed lid are lit or dark by policy, so they are left out: a
        // monitor which drops its connector while asleep must not light the
        // fallback in its place, and closing the lid needs no debounce.
        let connector_decided = |name: &str| !selection.policy.overrides(name);
        let observed_output_changed = output_properties_changed(
            outputs
                .iter()
                .filter(|output| connector_decided(&output.name)),
            scanouts,
        );
        let dpms_debounce_bypassed = scanout_rebased
            || kms_reconfigure_requested
            || resident_geometry_reconfigure_requested
            || observed_output_changed;
        if dpms_debounce_bypassed {
            // A VT/KMS rebase invalidates scheduler ownership, while an explicit
            // reconfiguration or another output change is authoritative. None may
            // be held behind a stale DPMS connector exception.
            events.dpms_topology.cancel();
        }
        let deferred_dpms_topology = if dpms_debounce_bypassed {
            None
        } else {
            events.dpms_topology.defer_missing_outputs(
                Instant::now(),
                scanouts
                    .iter()
                    .filter(|scanout| connector_decided(&scanout.output.name))
                    .map(|scanout| scanout.output.id),
                outputs
                    .iter()
                    .filter(|output| connector_decided(&output.name))
                    .map(|output| output.id),
            )
        };
        let topology_deferred = if let Some(deferred) = deferred_dpms_topology {
            if deferred.first_observation {
                if let Some(grace_until) = deferred.grace_until {
                    info!(
                        missing_outputs = deferred.missing_outputs,
                        grace_ms = grace_until
                            .saturating_duration_since(Instant::now())
                            .as_millis(),
                        "deferred transient connector removal during DPMS wake"
                    );
                } else {
                    info!(
                        missing_outputs = deferred.missing_outputs,
                        "deferred connector removal while its output remains DPMS-off"
                    );
                }
            }
            true
        } else {
            false
        };

        if outputs.is_empty() && !topology_deferred {
            if !*outputs_disconnected {
                *outputs_disconnected = true;
                events.output_control_dirty = true;
                flutter.set_outputs_visible(false)?;
                warn!(
                    retry_ms = KMS_PRESENTATION_RECOVERY_RETRY.as_millis(),
                    "no connected display can be lit; keeping the session alive until one can"
                );
            }
            events.topology_dirty = true;
            events.resident_geometry_reconfigure_requested |=
                resident_geometry_reconfigure_requested;
            event_loop.dispatch(KMS_PRESENTATION_RECOVERY_RETRY, events)?;
            return Ok(OutputTopologyObservation::WaitingForOutputs);
        }
        if !topology_deferred && *outputs_disconnected {
            *outputs_disconnected = false;
            info!(
                connected_outputs = outputs.len(),
                "a display can be lit again; rebuilding presentation state"
            );
        }
        if !topology_deferred {
            events.output_control_dirty = true;
        }
        let changed = !topology_deferred
            && (outputs.len() != scanouts.len() || output_properties_changed(&outputs, scanouts));
        if !topology_deferred {
            info!(
                connected_outputs = outputs.len(),
                changed,
                resumed = scanout_rebased,
                forced = kms_reconfigure_requested,
                resident_geometry = resident_geometry_reconfigure_requested,
                "completed event-driven DRM topology rescan"
            );
        }
        if changed
            || scanout_rebased
            || kms_reconfigure_requested
            || resident_geometry_reconfigure_requested
        {
            Ok(OutputTopologyObservation::Reconfigure(
                ObservedOutputTopology { outputs, changed },
            ))
        } else {
            Ok(OutputTopologyObservation::Stable)
        }
    }

    pub(super) fn apply_observed_output_topology(
        &mut self,
        request: TopologyReconfigurationRequest,
        observed: ObservedOutputTopology,
    ) -> Result<(), Box<dyn Error>> {
        let TopologyReconfigurationRequest {
            scanout_rebased,
            kms_reconfigure_requested,
            resident_geometry_reconfigure_requested,
        } = request;
        let ObservedOutputTopology { outputs, changed } = observed;

        cancel_active_screenshot(
            &mut self.screenshot_manager,
            self.flutter,
            true,
            "display topology changed",
        )?;
        let resident_targets_busy = resident_geometry_reconfigure_requested
            && !changed
            && !kms_reconfigure_requested
            && self
                .scanouts
                .iter()
                .any(|scanout| !self.flutter.output_target_available(scanout.output.id));
        if !scanout_rebased && (self.scheduler.has_pending_scanout_work() || resident_targets_busy)
        {
            // Finish any ready old-topology batch before creating the common
            // rollback point used by the hotplug transaction.
            self.events.topology_dirty = true;
            self.events.kms_reconfigure_requested = kms_reconfigure_requested;
            self.events.resident_geometry_reconfigure_requested =
                resident_geometry_reconfigure_requested;
            return self.drain_frames_before_reconfiguration();
        }
        if !scanout_rebased {
            self.scheduler
                .prepare_reconfiguration(self.scanouts, &mut self.events)?;
        }
        if resident_geometry_reconfigure_requested
            && !changed
            && !scanout_rebased
            && !kms_reconfigure_requested
        {
            let staged_configuration = self.output_configuration.clone();
            apply_resident_output_geometry(
                self.scanouts,
                self.swapchain,
                self.topology,
                &mut self.output_configuration,
                ResidentGeometry {
                    outputs,
                    configuration: staged_configuration,
                    transition: flutter_runtime::OutputGeometryTransition::Immediate,
                },
                &mut self.events,
                self.flutter,
            )?;
            self.frame_scheduler
                .reconfigure(self.scanouts, Instant::now());
            self.events.scanout_rebased = false;
            return Ok(());
        }

        let topology_apply = apply_hotplug_topology(HotplugRequest {
            renderer: self.renderer,
            allocator: self.scanout_allocator,
            drm: self.drm,
            swapchain: self.swapchain,
            scanouts: self.scanouts,
            restore_state: self.restore_state,
            topology: self.topology,
            outputs,
            configuration: &self.output_configuration,
            frame_number: self.raster_frames,
            event_loop: self.event_loop,
            events: &mut self.events,
            flutter: Some(&mut *self.flutter),
            flutter_launcher: Some(&mut *self.flutter_launcher),
        });
        if let Err(error) = topology_apply {
            if kms_reconfigure_requested
                && self.flutter.is_running()
                && crate::output_color::clear_hdr_requests()
            {
                // The rollback kept the old pools; build them again in SDR.
                warn!(%error, "could not show HDR; returning every display to SDR");
                self.events.kms_reconfigure_requested = true;
                self.events.topology_dirty = true;
                return Ok(());
            }
            if scanout_rebased && self.flutter.is_running() {
                // A monitor may still be link-training after the synchronous
                // recovery baseline. Keep the login alive and retry a fresh scan.
                warn!(
                    %error,
                    retry_ms = KMS_PRESENTATION_RECOVERY_RETRY.as_millis(),
                    "KMS topology rebuild is waiting for the display hardware"
                );
                self.events.scanout_rebased = true;
                self.events.topology_dirty = true;
                self.event_loop
                    .dispatch(KMS_PRESENTATION_RECOVERY_RETRY, &mut self.events)?;
                return Ok(());
            }
            return Err(error);
        }
        self.replace_frame_schedulers("output scheduler has no physical output pools")?;
        if self.events.flutter_reload_requested {
            self.events.flutter_reload_requested = false;
            info!(
                generation = self.flutter_launcher.generation,
                "loaded the refreshed Flutter bundle during topology restart"
            );
        }
        // A pause/resume serviced inside the topology transaction was already
        // absorbed by its synchronous candidate commit and the new scheduler.
        self.events.scanout_rebased = false;
        Ok(())
    }

    pub(super) fn service_flutter_reload(&mut self) -> Result<bool, Box<dyn Error>> {
        if !self.events.flutter_reload_requested {
            return Ok(false);
        }
        cancel_active_screenshot(
            &mut self.screenshot_manager,
            self.flutter,
            true,
            "Flutter runtime is refreshing",
        )?;
        let scanout_work_pending = self.scheduler.has_pending_scanout_work();
        let resident_targets_idle = self
            .scanouts
            .iter()
            .all(|scanout| self.flutter.output_target_available(scanout.output.id));
        if scanout_work_pending || !resident_targets_idle {
            // Stop servicing the producer while its last output batch reaches
            // every affected CRTC. A ready fence or page flip wakes calloop.
            self.drain_frames_before_reconfiguration()?;
            return Ok(true);
        }

        self.scheduler
            .prepare_reconfiguration(self.scanouts, &mut self.events)?;
        let reload = self.reload_flutter_runtime()?;
        self.events.flutter_reload_requested = false;
        match reload {
            FlutterReloadOutcome::Replaced | FlutterReloadOutcome::RolledBack => {
                self.replace_frame_schedulers("output scheduler has no physical output pools")?;
                info!(
                    generation = self.flutter_launcher.generation,
                    "refreshed Flutter bundle without restarting the compositor session"
                );
            }
            FlutterReloadOutcome::Retained => {
                info!(
                    generation = self.flutter_launcher.generation,
                    "retained the active Flutter bundle after refresh preflight rejection"
                );
            }
        }
        Ok(true)
    }

    pub(super) fn reload_flutter_runtime(
        &mut self,
    ) -> Result<FlutterReloadOutcome, Box<dyn Error>> {
        let Self {
            renderer,
            swapchain,
            scanouts,
            topology,
            events,
            flutter,
            flutter_launcher,
            ..
        } = self;
        let (renderer, flutter, flutter_launcher) =
            (&mut **renderer, &mut **flutter, &mut **flutter_launcher);
        let snapshot = topology.snapshot();
        let atlas = AtlasPlan::for_snapshot(&snapshot)
            .ok_or("current topology produced no atlas during Flutter bundle refresh")?;
        let output_swapchains = swapchain
            .outputs()
            .ok_or("Flutter bundle refresh has no physical output pools")?;
        // Validate every replacement context and FBO while the active runtime and
        // its imports remain alive. Some EGL drivers cannot reliably tear down an
        // engine and then immediately reimport the same DMA-BUF pool; a failed
        // preflight is still reversible because Flutter has not been taken yet.
        // The second preparation restarts a shell if the replacement fails.
        let prepare = || {
            flutter_launcher.prepare_output_targets(renderer, output_swapchains, atlas.pixel_size)
        };
        let (prepared, rollback_prepared) = match prepare().and_then(|a| Ok((a, prepare()?))) {
            Ok(prepared) => prepared,
            Err(error) => {
                flutter_launcher.retain_runtime_after_switch_failure(flutter, error.as_ref());
                warn!(
                    %error,
                    "Flutter bundle refresh renderer preflight failed; retaining the active runtime"
                );
                return Ok(FlutterReloadOutcome::Retained);
            }
        };
        let prepare_restart = (|| -> Result<(), Box<dyn Error>> {
            flutter.process_events(events.flutter_events.drain(..))?;
            let _ = flutter_launcher.synchronize_ui_development(flutter)?;
            synchronize_authentication_boundary(events);
            synchronize_clipboard(flutter, events)?;
            synchronize_system_control_events(flutter, events)?;
            synchronize_shell_keyboard(flutter, events)?;
            synchronize_settings(flutter, events)?;
            synchronize_system_bar_configuration(flutter, events, Some(flutter_launcher));
            synchronize_flutter_window_management(flutter, events)?;
            synchronize_flutter_input_layout(flutter, events)?;
            Ok(())
        })();
        if let Err(error) = prepare_restart {
            flutter_launcher.retain_runtime_after_switch_failure(flutter, error.as_ref());
            warn!(
                %error,
                "Flutter pre-refresh drain failed; retaining the active runtime"
            );
            return Ok(FlutterReloadOutcome::Retained);
        }
        events.plugin_actions = Default::default();
        events
            .native_escape_shortcut
            .set_plugin_actions(&events.plugin_actions);
        flutter
            .shutdown()
            .map_err(|error| format!("Flutter shutdown before refresh failed: {error}"))?;
        events.flutter_events.clear();

        let mut start = |prepared| -> Result<flutter_runtime::FlutterRuntime, Box<dyn Error>> {
            let mut runtime = flutter_launcher.start_with_targets(
                renderer,
                output_swapchains,
                scanouts,
                &snapshot,
                &atlas,
                Some(prepared),
            )?;
            events.install_workspace_snapshot(&mut runtime)?;
            Ok(runtime)
        };
        // A shell that cannot start leaves Denial with nothing to show. Start
        // again with what the launcher selects now (it falls back to the packaged
        // shell after a custom one fails); if that fails too, the error ends the
        // session and systemd starts a new one.
        let outcome = match start(prepared) {
            Ok(runtime) => {
                *flutter = runtime;
                FlutterReloadOutcome::Replaced
            }
            Err(error) => {
                warn!(%error, "refreshed Flutter bundle did not start; restarting the shell");
                *flutter = start(rollback_prepared).map_err(|rollback| {
                    format!("refreshed Flutter bundle did not start ({error}), nor did the shell after it ({rollback})")
                })?;
                FlutterReloadOutcome::RolledBack
            }
        };
        events.begin_replacement_flutter_generation(swapchain.desktop_size());
        Ok(outcome)
    }
}
