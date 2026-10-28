//! Output configuration requests from Settings and the display policy:
//! staging, applying, confirming and publishing them.

use super::*;

/// What restores the outputs if the user does not confirm a configuration in
/// time.
struct ConfirmationRollback {
    configuration: RuntimeOutputConfiguration,
    power: BTreeMap<OutputId, bool>,
    timeout: Duration,
}

/// What an applied configuration still owes its request: the reply, and the
/// confirmation or persistence it asked for.
struct OutputApplyCompletion {
    request: PendingOutputApply,
    current_serial: u64,
    confirmation_rollback: Option<ConfirmationRollback>,
    prepared_persistence: Option<options::PreparedOutputConfig>,
}

struct StagedOutputApply {
    completion: OutputApplyCompletion,
    configuration: RuntimeOutputConfiguration,
    outputs: Vec<ConnectedOutput>,
    desired_power: BTreeMap<OutputId, bool>,
    transform_only: bool,
    hardware_changed: bool,
    resident_mode_change: bool,
    topology_changed: bool,
}

pub(super) fn output_properties_changed<'a>(
    outputs: impl IntoIterator<Item = &'a ConnectedOutput>,
    scanouts: &[Scanout],
) -> bool {
    outputs.into_iter().any(|output| {
        scanouts
            .iter()
            .find(|scanout| scanout.output.id == output.id)
            .is_none_or(|scanout| {
                scanout.output.crtc != output.crtc
                    || scanout.output.mode != output.mode
                    || scanout.output.connector != output.connector
                    || scanout.output.vrr_enabled != output.vrr_enabled
            })
    })
}

fn output_hardware_changed(outputs: &[ConnectedOutput], scanouts: &[Scanout]) -> bool {
    outputs.len() != scanouts.len() || output_properties_changed(outputs, scanouts)
}

/// A refresh/VRR transition can keep Flutter's native render targets resident
/// when every connector remains on the same CRTC at the same pixel extent.
/// Transform changes retain their existing geometry-only path; combining one
/// with a modeset is deliberately left to the general hotplug transaction.
fn resident_mode_change_supported(outputs: &[ConnectedOutput], scanouts: &[Scanout]) -> bool {
    outputs.len() == scanouts.len()
        && outputs.iter().all(|output| {
            scanouts
                .iter()
                .find(|scanout| scanout.output.id == output.id)
                .is_some_and(|scanout| {
                    scanout.output.connector == output.connector
                        && scanout.output.crtc == output.crtc
                        && scanout.output.mode.size() == output.mode.size()
                        && scanout.output.transform == output.transform
                })
        })
        && outputs.iter().any(|output| {
            scanouts
                .iter()
                .find(|scanout| scanout.output.id == output.id)
                .is_some_and(|scanout| {
                    scanout.output.mode != output.mode
                        || scanout.output.vrr_enabled != output.vrr_enabled
                })
        })
}

fn prepare_output_confirmation_rollback(
    request: &PendingOutputApply,
    scanouts: &[Scanout],
    output_configuration: &RuntimeOutputConfiguration,
) -> Option<ConfirmationRollback> {
    request
        .configuration
        .confirmation_timeout_milliseconds
        .map(|timeout_milliseconds| ConfirmationRollback {
            configuration: output_configuration.clone(),
            power: scanouts
                .iter()
                .map(|scanout| (scanout.output.id, scanout.powered))
                .collect(),
            timeout: Duration::from_millis(timeout_milliseconds),
        })
}

fn prepare_output_persistence(
    request: &PendingOutputApply,
    staged_configuration: &RuntimeOutputConfiguration,
    output_config: Option<&Path>,
) -> Result<Option<options::PreparedOutputConfig>, String> {
    if !request.configuration.persistent {
        return Ok(None);
    }
    let path = output_config.ok_or("persistent output configuration has no target file")?;
    let persisted_outputs = request
        .configuration
        .outputs
        .iter()
        .map(|output| options::PersistedOutput {
            name: output.name.clone(),
            // Settings shows the effective state, which can include a transient
            // fallback or clamshell. Save the reconciled preference instead.
            enabled: !staged_configuration.disabled_outputs.contains(&output.name),
            x: output.x,
            y: output.y,
            width: output.mode.width,
            height: output.mode.height,
            refresh_millihz: output.mode.refresh_millihz,
            scale_120: (output.scale * f64::from(SCALE_BASE)).round() as u32,
            transform: staged_configuration
                .transforms
                .get(&output.name)
                .copied()
                .unwrap_or(OutputTransform::Normal),
            scrolling_layout_axis: staged_configuration.scrolling_layout_axis(&output.name),
            adaptive_sync: output.adaptive_sync,
        })
        .collect::<Vec<_>>();
    options::prepare_output_config_persistence(
        path,
        &persisted_outputs,
        request.configuration.primary_output.as_deref(),
    )
    .map(Some)
}

impl Session<'_, '_> {
    pub(super) fn handle_output_confirmation_requests(&mut self) -> bool {
        let Self {
            events,
            active_output_confirmation: active_confirmation,
            output_configuration,
            pending_output_confirmation_success: successful_confirmations,
            ..
        } = self;
        let mut handled = false;
        while let Some(request) = events.control.output_confirmations.pop_front() {
            let Some(pending) = active_confirmation.take() else {
                request.reply(Err(output_control::OutputControlFailure::new(
                    "stale_confirmation",
                    "there is no output configuration awaiting confirmation",
                )));
                continue;
            };
            if request.token != pending.state.token {
                *active_confirmation = Some(pending);
                request.reply(Err(output_control::OutputControlFailure::new(
                    "stale_confirmation",
                    "the output confirmation token is stale",
                )));
                continue;
            }

            handled = true;
            match request.action {
                OutputConfirmationAction::Keep => {
                    if let Some(prepared) = pending.prepared_persistence
                        && let Err(error) = prepared.commit()
                    {
                        *output_configuration = pending.rollback_configuration;
                        events.output_power_requests.extend(pending.rollback_power);
                        events.resident_geometry_reconfigure_requested = true;
                        events.output_control_dirty = true;
                        warn!(%error, "could not persist confirmed output configuration; rolling it back");
                        request.reply(Err(output_control::OutputControlFailure::new(
                            "persistence_failed",
                            error,
                        )));
                        continue;
                    }
                    events.output_control_dirty = true;
                    info!(token = pending.state.token, "kept output configuration");
                    successful_confirmations.push_back(request);
                }
                OutputConfirmationAction::Rollback => {
                    *output_configuration = pending.rollback_configuration;
                    events.output_power_requests.extend(pending.rollback_power);
                    events.resident_geometry_reconfigure_requested = true;
                    events.output_control_dirty = true;
                    info!(
                        token = pending.state.token,
                        "rolling back output configuration on request"
                    );
                    successful_confirmations.push_back(request);
                }
            }
        }
        handled
    }

    fn stage_output_apply(
        &mut self,
        request: PendingOutputApply,
        connectors: Vec<ConnectedConnector>,
        current_snapshot: &output_control::OutputControlSnapshot,
    ) -> Option<StagedOutputApply> {
        let Self {
            max_outputs,
            output_configuration,
            output_config,
            topology,
            scanouts,
            events,
            ..
        } = self;
        let max_outputs = *max_outputs;
        let persistence_available = output_config.is_some();
        let output_config = output_config.as_deref();
        if request.configuration.serial != current_snapshot.serial {
            let message = format!(
                "configuration serial {} is stale; current serial is {}",
                request.configuration.serial, current_snapshot.serial
            );
            request.reply(Err(output_control::OutputControlFailure::new(
                "stale_configuration",
                message,
            )));
            events.topology_dirty = true;
            return None;
        }

        let transform_only = output_request_changes_only_transforms(
            &current_snapshot.outputs,
            &request.configuration.outputs,
        ) && current_snapshot.primary_output
            == request.configuration.primary_output;
        let confirmation_rollback =
            prepare_output_confirmation_rollback(&request, scanouts, output_configuration);
        let (configuration, desired_power) = match configuration_from_output_request(
            &request.configuration,
            &connectors,
            max_outputs,
            output_configuration,
            persistence_available,
        ) {
            Ok(configuration) => configuration,
            Err(error) => {
                request.reply(Err(error));
                return None;
            }
        };
        let outputs = match configured_outputs(connectors, max_outputs, &configuration) {
            Ok(configured) => configured.outputs,
            Err(error) => {
                request.reply(Err(output_control::OutputControlFailure::new(
                    "invalid_configuration",
                    error.to_string(),
                )));
                return None;
            }
        };

        let preview = (|| -> Result<TopologySnapshot, Box<dyn Error>> {
            let mut preview_topology = topology.clone();
            let preview_snapshot =
                update_topology_for_outputs(&mut preview_topology, &outputs, &configuration)?;
            AtlasPlan::for_snapshot(&preview_snapshot)
                .ok_or("output configuration produced no scanout atlas")?;
            Ok(preview_snapshot)
        })();
        let preview = match preview {
            Ok(preview) => preview,
            Err(error) => {
                request.reply(Err(output_control::OutputControlFailure::new(
                    "invalid_configuration",
                    error.to_string(),
                )));
                return None;
            }
        };
        let prepared_persistence = match prepare_output_persistence(
            &request,
            &configuration,
            output_config,
        ) {
            Ok(prepared) => prepared,
            Err(error) => {
                request.reply(Err(output_control::OutputControlFailure::new(
                    "persistence_failed",
                    &error,
                )));
                warn!(%error, path = ?output_config, "could not prepare persistent output configuration");
                return None;
            }
        };
        let hardware_changed = output_hardware_changed(&outputs, scanouts);
        let resident_mode_change = resident_mode_change_supported(&outputs, scanouts);
        let current_topology = topology.snapshot();
        let topology_changed = preview.outputs != current_topology.outputs
            || preview.ticker != current_topology.ticker;

        Some(StagedOutputApply {
            completion: OutputApplyCompletion {
                request,
                current_serial: current_snapshot.serial,
                confirmation_rollback,
                prepared_persistence,
            },
            configuration,
            outputs,
            desired_power,
            transform_only,
            hardware_changed,
            resident_mode_change,
            topology_changed,
        })
    }

    fn apply_requested_output_power(
        &mut self,
        desired_power: BTreeMap<OutputId, bool>,
    ) -> Result<(), Box<dyn Error>> {
        self.events.output_power_requests.extend(desired_power);
        if apply_output_power_requests(
            self.flutter,
            &mut self.scheduler,
            self.swapchain,
            self.scanouts,
            &mut self.events,
        )? {
            self.frame_scheduler
                .reconfigure(self.scanouts, Instant::now());
        }
        Ok(())
    }

    fn finish_output_apply(&mut self, completion: OutputApplyCompletion) {
        let OutputApplyCompletion {
            request,
            current_serial,
            confirmation_rollback,
            prepared_persistence,
        } = completion;
        if let Some(rollback) = confirmation_rollback {
            self.active_output_confirmation = Some(begin_output_confirmation(
                current_serial,
                rollback.timeout,
                rollback.configuration,
                rollback.power,
                prepared_persistence,
            ));
        } else if let Some(prepared) = prepared_persistence {
            self.events.output_control_dirty = true;
            if let Err(error) = prepared.commit() {
                request.reply(Err(output_control::OutputControlFailure::new(
                    "persistence_failed",
                    &error,
                )));
                warn!(%error, "output configuration applied but could not be persisted");
                return;
            }
        }
        self.pending_output_success = Some(request);
    }

    pub(super) fn acquire_pending_output_apply(
        &mut self,
        scanout_rebased: bool,
    ) -> Result<bool, Box<dyn Error>> {
        if scanout_rebased && let Some((request, _)) = self.ready_output_apply.take() {
            // A VT resume invalidates the scheduler and any connector view
            // prepared against it. Re-scan the request after topology repair.
            self.events.control.output_applies.push_front(request);
        }
        if scanout_rebased || self.ready_output_apply.is_some() {
            return Ok(false);
        }
        let Some(request) = self.events.control.output_applies.pop_front() else {
            return Ok(false);
        };
        if self.active_output_confirmation.is_some() {
            request.reply(Err(output_control::OutputControlFailure::new(
                "confirmation_pending",
                "keep or roll back the current output configuration before applying another",
            )));
            return Ok(true);
        }
        if self.scheduler.has_pending_scanout_work() {
            self.events.control.output_applies.push_front(request);
            self.drain_frames_before_reconfiguration()?;
            return Ok(true);
        }

        let connectors = match scan_connected_connectors(self.drm_scanner, self.drm) {
            Ok(connectors) => connectors,
            Err(error) => {
                request.reply(Err(output_control::OutputControlFailure::new(
                    "apply_failed",
                    format!("DRM connector scan failed: {error}"),
                )));
                self.events.topology_dirty = true;
                return Ok(true);
            }
        };
        // A direct apply request performs a fresh connector scan. Route that
        // observation through the same boundary publication as udev topology and
        // mode changes before validating its serial.
        self.events.output_control_dirty = true;
        self.ready_output_apply = Some((request, connectors));
        Ok(true)
    }

    fn apply_resident_output_configuration(
        &mut self,
        staged: StagedOutputApply,
    ) -> Result<(), Box<dyn Error>> {
        let StagedOutputApply {
            completion,
            configuration,
            outputs,
            desired_power,
            transform_only,
            ..
        } = staged;
        self.scheduler
            .prepare_reconfiguration(self.scanouts, &mut self.events)?;
        let transition = if transform_only {
            flutter_runtime::OutputGeometryTransition::AnimatedRotation
        } else {
            flutter_runtime::OutputGeometryTransition::Immediate
        };
        let apply = apply_resident_output_geometry(
            self.scanouts,
            self.swapchain,
            self.topology,
            &mut self.output_configuration,
            ResidentGeometry {
                outputs,
                configuration,
                transition,
            },
            &mut self.events,
            self.flutter,
        );
        if let Err(error) = apply {
            let message = error.to_string();
            self.events.output_control_dirty = true;
            completion
                .request
                .reply(Err(output_control::OutputControlFailure::new(
                    "apply_failed",
                    &message,
                )));
            warn!(%message, "rejected resident output reconfiguration");
            return Ok(());
        }
        self.frame_scheduler
            .reconfigure(self.scanouts, Instant::now());
        self.apply_requested_output_power(desired_power)?;
        self.finish_output_apply(completion);
        Ok(())
    }

    fn apply_hardware_output_configuration(
        &mut self,
        staged: StagedOutputApply,
    ) -> Result<(), Box<dyn Error>> {
        let StagedOutputApply {
            completion,
            configuration,
            outputs,
            desired_power,
            resident_mode_change,
            ..
        } = staged;
        self.scheduler
            .prepare_reconfiguration(self.scanouts, &mut self.events)?;
        let apply = if resident_mode_change {
            apply_resident_mode_topology(ResidentModeRequest {
                drm: self.drm,
                swapchain: self.swapchain,
                scanouts: self.scanouts,
                restore_state: self.restore_state,
                topology: self.topology,
                outputs,
                current_configuration: &mut self.output_configuration,
                staged_configuration: configuration.clone(),
                event_loop: self.event_loop,
                events: &mut self.events,
                flutter: self.flutter,
            })
        } else {
            apply_hotplug_topology(HotplugRequest {
                renderer: self.renderer,
                allocator: self.scanout_allocator,
                drm: self.drm,
                swapchain: self.swapchain,
                scanouts: self.scanouts,
                restore_state: self.restore_state,
                topology: self.topology,
                outputs,
                configuration: &configuration,
                frame_number: self.raster_frames,
                event_loop: self.event_loop,
                events: &mut self.events,
                flutter: Some(&mut *self.flutter),
                flutter_launcher: Some(&mut *self.flutter_launcher),
            })
        };
        if let Err(error) = apply {
            let message = error.to_string();
            self.events.output_control_dirty = true;
            completion
                .request
                .reply(Err(output_control::OutputControlFailure::new(
                    "apply_failed",
                    &message,
                )));
            if !self.flutter.is_running() {
                return Err(format!(
                    "output-control transaction failed after Flutter shutdown: {message}"
                )
                .into());
            }
            // Rollback restarts Flutter on the retained old pools, so its new
            // broker must not receive completion events from the old scheduler.
            self.replace_frame_schedulers("rollback lost its physical output pools")?;
            warn!(%message, "rejected output-control transaction");
            return Ok(());
        }

        self.events
            .frontend_mut()
            .set_scrolling_layout_axes(&configuration.scrolling_layout_axes);
        self.output_configuration = configuration;
        self.events.output_control_dirty = true;
        self.replace_frame_schedulers("output scheduler has no physical output pools")?;
        self.apply_requested_output_power(desired_power)?;
        self.events.scanout_rebased = false;
        self.finish_output_apply(completion);
        Ok(())
    }

    fn apply_staged_output_configuration(
        &mut self,
        staged: StagedOutputApply,
    ) -> Result<(), Box<dyn Error>> {
        if staged.hardware_changed {
            return self.apply_hardware_output_configuration(staged);
        }
        if staged.topology_changed {
            return self.apply_resident_output_configuration(staged);
        }
        let StagedOutputApply {
            completion,
            configuration,
            desired_power,
            ..
        } = staged;
        self.events
            .frontend_mut()
            .set_scrolling_layout_axes(&configuration.scrolling_layout_axes);
        self.output_configuration = configuration;
        self.events.output_control_dirty = true;
        self.apply_requested_output_power(desired_power)?;
        self.finish_output_apply(completion);
        Ok(())
    }

    pub(super) fn service_ready_output_apply(
        &mut self,
        scanout_rebased: bool,
        current_output_snapshot: Option<&output_control::OutputControlSnapshot>,
    ) -> Result<bool, Box<dyn Error>> {
        if scanout_rebased {
            return Ok(false);
        }
        let Some((request, connectors)) = self.ready_output_apply.take() else {
            return Ok(false);
        };
        let scanout_work_pending = self.scheduler.has_pending_scanout_work();
        let resident_targets_idle = self
            .scanouts
            .iter()
            .all(|scanout| self.flutter.output_target_available(scanout.output.id));
        if scanout_work_pending || !resident_targets_idle {
            // Connector discovery deliberately spans an event-loop iteration. A
            // Flutter frame which was already in flight can become ready or
            // submitted during that boundary. Keep the prepared request as a
            // render barrier and drain that final old-geometry frame.
            self.ready_output_apply = Some((request, connectors));
            self.drain_frames_before_reconfiguration()?;
            return Ok(true);
        }

        let current_snapshot =
            current_output_snapshot.expect("prepared output apply has a publication snapshot");
        if let Some(staged) = self.stage_output_apply(request, connectors, current_snapshot) {
            self.apply_staged_output_configuration(staged)?;
        }
        Ok(true)
    }

    /// The orientation sensor runs only while a panel that follows it is lit.
    pub(super) fn synchronize_orientation_demand(&self) {
        if let Some(sensor) = &self.orientation_sensor {
            sensor.set_wanted(self.scanouts.iter().any(|scanout| {
                scanout.powered && output_topology::orientation_sensor_output(&scanout.output.name)
            }));
        }
    }

    pub(super) fn apply_pending_sensor_orientation(
        &mut self,
        now: Instant,
    ) -> Result<(), Box<dyn Error>> {
        let Self {
            pending_sensor_rotation,
            output_configuration,
            active_output_confirmation,
            scanouts,
            swapchain,
            topology,
            scheduler,
            frame_scheduler,
            flutter,
            events,
            ..
        } = self;
        let pending_sensor_rotation = *pending_sensor_rotation;
        let requested_rotation = orientation_sensor::select_rotation(
            pending_sensor_rotation,
            events.frontend().settings.locked_sensor_rotation(),
        );
        if requested_rotation == output_configuration.sensor_rotation
            || scheduler.has_pending_scanout_work()
            || flutter.output_rotation_animation_active()
            || scanouts
                .iter()
                .any(|scanout| !flutter.output_target_available(scanout.output.id))
        {
            return Ok(());
        }
        scheduler.prepare_reconfiguration(scanouts, events)?;
        apply_automatic_orientation(
            scanouts,
            swapchain,
            topology,
            output_configuration,
            requested_rotation,
            events,
            flutter,
        )?;
        if let Some(pending) = active_output_confirmation.as_mut() {
            pending.rollback_configuration.sensor_rotation = requested_rotation;
        }
        events.frontend_mut().settings.current_sensor_rotation =
            output_configuration.sensor_rotation;
        frame_scheduler.reconfigure(scanouts, now);
        Ok(())
    }

    /// Lets the display policy follow the lid. A topology rescan then lights or
    /// turns off the built-in panels; nothing changes when the lid covers no
    /// output that the policy would otherwise light.
    pub(super) fn apply_pending_lid_position(&mut self) {
        let Self {
            output_configuration,
            active_output_confirmation,
            events,
            ..
        } = self;
        let Some(closed) = events.lid.take_pending() else {
            return;
        };
        if closed == output_configuration.lid_closed {
            return;
        }
        output_configuration.lid_closed = closed;
        // A rollback restores the user's configuration, not an older lid position.
        if let Some(pending) = active_output_confirmation.as_mut() {
            pending.rollback_configuration.lid_closed = closed;
        }
        info!(closed, "lid moved");
        events.topology_dirty = true;
    }

    pub(super) fn expire_output_confirmation(&mut self, now: Instant) {
        let Self {
            active_output_confirmation: active_confirmation,
            output_configuration,
            events,
            ..
        } = self;
        if active_confirmation
            .as_ref()
            .is_none_or(|pending| now < pending.deadline)
        {
            return;
        }
        let pending = active_confirmation
            .take()
            .expect("expired output confirmation exists");
        *output_configuration = pending.rollback_configuration;
        events.output_power_requests.extend(pending.rollback_power);
        events.resident_geometry_reconfigure_requested = true;
        events.output_control_dirty = true;
        info!(
            token = pending.state.token,
            "rolling back unconfirmed output configuration"
        );
    }

    pub(super) fn publish_output_control_updates(
        &mut self,
    ) -> Result<Option<output_control::OutputControlSnapshot>, Box<dyn Error>> {
        let Self {
            output_control,
            drm_scanner,
            scanouts,
            topology,
            output_configuration,
            output_config,
            active_output_confirmation,
            ready_output_apply,
            pending_output_success,
            pending_output_confirmation_success: pending_confirmation_success,
            events,
            ..
        } = self;
        let persistence_available = output_config.is_some();
        let ready_output_apply = ready_output_apply.is_some();
        // A rollback updates `output_configuration` before its KMS/Flutter
        // topology transaction updates `scanouts` and `topology`. Publishing in
        // that interval would expose a snapshot assembled from two different
        // configurations. Keep the previous snapshot (including its pending
        // confirmation) authoritative until reconfiguration has completed.
        let publication_deferred = output_control_publication_deferred(events);
        let needs_snapshot = ready_output_apply || pending_output_success.is_some();
        let mut snapshot = if publication_deferred {
            None
        } else {
            output_control.publish_if_dirty(&mut events.output_control_dirty, || {
                output_control_state(
                    drm_scanner,
                    scanouts,
                    topology,
                    output_configuration,
                    persistence_available,
                    active_output_confirmation
                        .as_ref()
                        .map(|pending| pending.state),
                )
            })?
        };
        if needs_snapshot && snapshot.is_none() {
            snapshot = Some(output_control.snapshot());
        }
        if !publication_deferred {
            if let Some(request) = pending_output_success.take() {
                request.reply(Ok(snapshot
                    .as_ref()
                    .expect("successful output apply has a publication snapshot")
                    .clone()));
            }
            while let Some(request) = pending_confirmation_success.pop_front() {
                request.reply(Ok(()));
            }
        }
        Ok(snapshot)
    }
}
