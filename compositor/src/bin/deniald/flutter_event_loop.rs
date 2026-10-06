//! Bounded calloop dispatch for Flutter, Wayland, KMS, and control-plane events.

use super::kms_pipeline::{
    HotplugRequest, ResidentModeRequest, apply_hotplug_topology, apply_resident_mode_topology,
};
use super::kms_session::{
    log_shutdown, recover_stalled_kms_presentation, service_session_lifecycle,
};
use super::*;
use denial_core::volition;
use smithay::reexports::calloop::channel::{
    Event as ChannelEvent, SyncSender, channel, sync_channel,
};

const BACKGROUND_SERVICE_INTERVAL: Duration = Duration::from_nanos(1_000_000_000 / 30);
const BACKGROUND_MAINTENANCE_INTERVAL: Duration = Duration::from_millis(100);

struct OperationCadence {
    next_service: Instant,
    next_maintenance: Instant,
}

impl OperationCadence {
    fn new(now: Instant) -> Self {
        Self {
            next_service: now,
            next_maintenance: now,
        }
    }

    fn take_service_due(&mut self, now: Instant) -> bool {
        take_periodic_deadline(now, &mut self.next_service, BACKGROUND_SERVICE_INTERVAL)
    }

    fn take_maintenance_due(&mut self, now: Instant) -> bool {
        take_periodic_deadline(
            now,
            &mut self.next_maintenance,
            BACKGROUND_MAINTENANCE_INTERVAL,
        )
    }

    fn limit_dispatch_timeout(&self, now: Instant, timeout: Duration) -> Duration {
        timeout
            .min(self.next_service.saturating_duration_since(now))
            .min(self.next_maintenance.saturating_duration_since(now))
    }
}

fn take_periodic_deadline(now: Instant, deadline: &mut Instant, interval: Duration) -> bool {
    if now < *deadline {
        return false;
    }
    *deadline = now.checked_add(interval).unwrap_or(now);
    true
}

fn interactive_service_work_pending(events: &RuntimeState) -> bool {
    !events.pending_shell_actions.is_empty()
        || !events.pending_shortcut_launches.is_empty()
        || !events.pending_window_events.is_empty()
}

fn output_transaction_waiting(
    ready_output_apply: bool,
    pending_output_apply: bool,
    resident_geometry_reconfigure_requested: bool,
) -> bool {
    ready_output_apply || pending_output_apply || resident_geometry_reconfigure_requested
}

fn start_notification_server(
    event_loop: &mut EventLoop<'_, RuntimeState>,
) -> Result<Option<NotificationServer>, Box<dyn Error>> {
    let notification_events = Arc::new(Mutex::new(VecDeque::with_capacity(
        NOTIFICATION_EVENT_QUEUE_CAPACITY,
    )));
    let notification_publish_queue = Arc::clone(&notification_events);
    let (notification_sender, notification_source) = channel();
    match NotificationServer::start(move |event, _| {
        let should_wake = {
            let mut queue = notification_publish_queue
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let should_wake = queue.is_empty();
            if queue.len() == NOTIFICATION_EVENT_QUEUE_CAPACITY {
                queue.pop_front();
            }
            queue.push_back(event);
            should_wake
        };
        if should_wake {
            // One calloop message wakes the compositor for the complete
            // coalesced batch; the notification worker never busy-waits.
            let _ = notification_sender.send(());
        }
    }) {
        Ok(server) => {
            let notification_dispatch_queue = Arc::clone(&notification_events);
            event_loop.handle().insert_source(
                notification_source,
                move |event, _, state: &mut RuntimeState| {
                    if let ChannelEvent::Msg(()) = event {
                        let mut queue = notification_dispatch_queue
                            .lock()
                            .unwrap_or_else(std::sync::PoisonError::into_inner);
                        state.pending_notification_events.extend(queue.drain(..));
                    }
                },
            )?;
            Ok(Some(server))
        }
        Err(error) => {
            error!(%error, "Denial could not start its notification service");
            Ok(None)
        }
    }
}

fn start_orientation_sensor(
    event_loop: &mut EventLoop<'_, RuntimeState>,
) -> Result<Option<orientation_sensor::OrientationSensor>, Box<dyn Error>> {
    match orientation_sensor::OrientationSensor::start() {
        Ok((sensor, source)) => {
            event_loop
                .handle()
                .insert_source(source, |event, _, state: &mut RuntimeState| {
                    if let ChannelEvent::Msg(orientation) = event {
                        state.pending_orientation = Some(orientation);
                    }
                })?;
            Ok(Some(sensor))
        }
        Err(error) => {
            warn!(%error, "could not start the orientation sensor worker");
            Ok(None)
        }
    }
}

fn synchronize_software_dimming(
    drm: &mut DrmDevice,
    scanouts: &[Scanout],
    events: &mut RuntimeState,
    flutter: &mut Option<flutter_runtime::FlutterRuntime>,
) -> Result<(), Box<dyn Error>> {
    let requests = flutter
        .as_mut()
        .map(|runtime| {
            runtime
                .drain_software_dimming_requests()
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let gamma_reapply_requested = std::mem::take(&mut events.gamma_reapply_requested);
    let force_gamma_reapply = events.scanout_rebased || gamma_reapply_requested;
    let states = gamma_control::synchronize_gamma_control(
        drm,
        scanouts,
        events,
        &requests,
        force_gamma_reapply,
    );
    if let Some(runtime) = flutter.as_mut() {
        for state in states {
            runtime.send_software_dimming_state(state)?;
        }
    }
    Ok(())
}

fn handle_ui_development_requests(
    events: &mut RuntimeState,
    flutter: &mut Option<flutter_runtime::FlutterRuntime>,
    flutter_launcher: &mut FlutterLauncher,
) {
    while let Some(request) = events.pending_ui_development.pop_front() {
        let Some(runtime) = flutter.as_mut() else {
            request.reply(Err(output_control::OutputControlFailure::new(
                "unavailable",
                "the Flutter runtime is unavailable",
            )));
            continue;
        };
        let is_query = request.command.kind() == ui_development::CommandKind::Query;
        let (reload_requested, state) =
            flutter_launcher.handle_external_ui_development(runtime, request.command.clone());
        if reload_requested {
            events.flutter_reload_requested = true;
        }
        if !is_query && let Some(error) = state.error_message() {
            request.reply(Err(output_control::OutputControlFailure::new(
                "rejected", error,
            )));
        } else {
            request.reply(Ok(state));
        }
    }
}

fn handle_output_confirmation_requests(
    events: &mut RuntimeState,
    active_confirmation: &mut Option<ActiveOutputConfirmation>,
    output_configuration: &mut RuntimeOutputConfiguration,
    successful_confirmations: &mut VecDeque<PendingOutputConfirmation>,
) -> bool {
    let mut handled = false;
    while let Some(request) = events.pending_output_confirmations.pop_front() {
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

#[allow(clippy::too_many_arguments)]
fn begin_pending_screenshot_selection(
    events: &mut RuntimeState,
    manager: &mut Option<screenshot::ScreenshotManager>,
    topology: &TopologyManager,
    scheduler: &output_scheduler::OutputScheduler,
    swapchain: &RenderSwapchains,
    scanouts: &[Scanout],
    allocator: &mut GbmAllocator<DrmDeviceFd>,
    runtime: &mut flutter_runtime::FlutterRuntime,
) -> Result<bool, Box<dyn Error>> {
    let Some(target_output) = events.pending_screenshot_selection.take() else {
        return Ok(false);
    };
    let Some(manager) = manager.as_mut() else {
        warn!("screenshot selection ignored because the writer is unavailable");
        return Ok(false);
    };
    let snapshot = topology.snapshot();
    let atlas = AtlasPlan::for_snapshot(&snapshot).ok_or("screenshot preparation has no atlas")?;
    if scheduler
        .framebuffer_index_for_output(target_output, scanouts)
        .is_none()
    {
        warn!(?target_output, "screenshot target output is not powered");
        return Ok(true);
    }
    let output_swapchains = swapchain
        .outputs()
        .ok_or("screenshot selection has no physical output pools")?;
    let modifier = screenshot_buffer_modifier(scheduler, output_swapchains, target_output)?;
    match manager.begin_selection(allocator, target_output, atlas, modifier) {
        Ok(Some(request_id)) => {
            if let Err(error) = runtime.send_screenshot_action(
                wire::ShellAction::ScreenshotRegion,
                request_id,
                None,
            ) {
                let _ = manager.cancel_selection(runtime, Some(request_id));
                return Err(error);
            }
        }
        Ok(None) => debug!("ignored repeated screenshot selection shortcut"),
        Err(error) => warn!(%error, "could not allocate screenshot selection buffer"),
    }
    Ok(false)
}

fn handle_prepared_screenshot(
    request_id: Option<std::num::NonZeroU64>,
    manager: &mut Option<screenshot::ScreenshotManager>,
    scheduler: &output_scheduler::OutputScheduler,
    scanouts: &[Scanout],
    runtime: &mut flutter_runtime::FlutterRuntime,
    frame_scheduler: &mut frame_scheduler::FrameScheduler,
) -> Result<bool, Box<dyn Error>> {
    let Some(request_id) = request_id else {
        return Ok(false);
    };
    let Some(manager) = manager.as_mut() else {
        return Ok(false);
    };
    if manager.request_id() != Some(request_id.get()) {
        return Ok(false);
    }
    let Some(target_output) = manager.target_output() else {
        return Err("prepared screenshot lost its target output".into());
    };
    if scheduler
        .framebuffer_index_for_output(target_output, scanouts)
        .is_none()
    {
        let finished = manager.cancel_selection(runtime, Some(request_id.get()))?;
        if let Some(request_id) = finished {
            runtime.send_screenshot_action(wire::ShellAction::ScreenshotDone, request_id, None)?;
        }
        return Ok(true);
    }
    if manager.prepared(request_id.get()) {
        runtime.arm_screenshot_frame(target_output, request_id.get())?;
        frame_scheduler.mark_output_dirty(target_output);
    } else {
        warn!(
            request_id = request_id.get(),
            "ignored stale screenshot preparation"
        );
    }
    Ok(false)
}

fn handle_cancelled_screenshot(
    request_id: Option<std::num::NonZeroU64>,
    manager: &mut Option<screenshot::ScreenshotManager>,
    runtime: &mut flutter_runtime::FlutterRuntime,
) -> Result<(), Box<dyn Error>> {
    let Some(request_id) = request_id else {
        return Ok(());
    };
    let Some(manager) = manager.as_mut() else {
        return Ok(());
    };
    let Some(request_id) = manager.cancel_selection(runtime, Some(request_id.get()))? else {
        return Ok(());
    };
    runtime.send_screenshot_action(wire::ShellAction::ScreenshotDone, request_id, None)?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn handle_screenshot_request(
    request: Option<flutter_runtime::system_command::ScreenshotRequest>,
    manager: &mut Option<screenshot::ScreenshotManager>,
    renderer: &mut GlesRenderer,
    allocator: &mut GbmAllocator<DrmDeviceFd>,
    topology: &TopologyManager,
    scheduler: &output_scheduler::OutputScheduler,
    swapchain: &RenderSwapchains,
    runtime: &mut flutter_runtime::FlutterRuntime,
) -> Result<(), Box<dyn Error>> {
    let Some(request) = request else {
        return Ok(());
    };
    let Some(manager) = manager.as_mut() else {
        warn!("screenshot request ignored because the writer is unavailable");
        return Ok(());
    };

    if request.request_id.is_none() {
        let snapshot = topology.snapshot();
        let Some(atlas) = AtlasPlan::for_snapshot(&snapshot) else {
            warn!("screenshot capture skipped because the atlas is unavailable");
            return Ok(());
        };
        let output_swapchains = swapchain
            .outputs()
            .ok_or("live screenshot has no physical output pools")?;
        let mut sources = screenshot_composite_sources(scheduler, output_swapchains, &atlas)?;
        let source_output = atlas
            .outputs
            .first()
            .ok_or("live screenshot atlas has no outputs")?
            .id;
        let modifier = screenshot_buffer_modifier(scheduler, output_swapchains, source_output)?;
        if let Err(error) =
            manager.capture_live(renderer, allocator, &atlas, modifier, &mut sources, request)
        {
            warn!(%error, "screenshot capture failed");
        }
        return Ok(());
    }

    let request_id = request
        .request_id
        .expect("checked screenshot request identity")
        .get();
    if manager.request_id() != Some(request_id) {
        return Ok(());
    }
    if let Err(error) = manager.finish_selection(renderer, runtime, request) {
        warn!(%error, request_id, "frozen screenshot capture failed");
    }
    runtime.send_screenshot_action(wire::ShellAction::ScreenshotDone, request_id, None)?;
    Ok(())
}

fn next_dispatch_timeout(
    now: Instant,
    runtime: &flutter_runtime::FlutterRuntime,
    frame_scheduler: &frame_scheduler::FrameScheduler,
    operation_cadence: &OperationCadence,
    events: &RuntimeState,
    drm: &DrmDevice,
    scheduler: &output_scheduler::OutputScheduler,
    deadline: Option<Instant>,
) -> Option<Duration> {
    let mut timeout = frame_scheduler.limit_dispatch_timeout(now, runtime.next_dispatch_timeout());
    timeout = operation_cadence.limit_dispatch_timeout(now, timeout);
    timeout = events.idle_policy.limit_dispatch_timeout(now, timeout);
    timeout = events.dpms_topology.limit_dispatch_timeout(now, timeout);
    if events.fingerprint.active() {
        timeout = timeout.min(Duration::from_millis(20));
    }
    if drm.is_active() {
        timeout = scheduler.limit_presentation_watchdog_timeout(now, timeout);
    }
    if events.flutter_input.has_pending() || !events.flutter_events.is_empty() {
        timeout = Duration::ZERO;
    }
    match deadline {
        Some(deadline) if now >= deadline => None,
        Some(deadline) => Some(timeout.min(deadline.saturating_duration_since(now))),
        None => Some(timeout),
    }
}

fn create_frame_schedulers(
    drm: &DrmDevice,
    volition_events: &SyncSender<volition::Event>,
    scanouts: &[Scanout],
    swapchain: &RenderSwapchains,
    flutter: &mut Option<flutter_runtime::FlutterRuntime>,
    events: &mut RuntimeState,
    missing_swapchains: &'static str,
    missing_runtime: &'static str,
) -> Result<
    (
        output_scheduler::OutputScheduler,
        frame_scheduler::FrameScheduler,
    ),
    Box<dyn Error>,
> {
    let scheduler = output_scheduler::OutputScheduler::new(
        drm,
        volition_events.clone(),
        scanouts,
        swapchain.outputs().ok_or(missing_swapchains)?,
        flutter.as_mut().ok_or(missing_runtime)?,
        events,
    )?;
    let frame_scheduler = frame_scheduler::FrameScheduler::new(scanouts, Instant::now());
    Ok((scheduler, frame_scheduler))
}

#[allow(clippy::too_many_arguments)]
fn drain_frames_before_reconfiguration(
    flutter: &Option<flutter_runtime::FlutterRuntime>,
    scheduler: &mut output_scheduler::OutputScheduler,
    swapchain: &RenderSwapchains,
    scanouts: &[Scanout],
    events: &mut RuntimeState,
    event_loop: &mut EventLoop<'_, RuntimeState>,
    deadline: Option<Instant>,
) -> Result<(), Box<dyn Error>> {
    submit_ready_frames(
        flutter
            .as_ref()
            .ok_or("Flutter runtime disappeared before frame submission")?,
        scheduler,
        swapchain,
        scanouts,
        events,
    )?;
    let now = Instant::now();
    let timeout = deadline.map_or(Duration::from_millis(50), |deadline| {
        Duration::from_millis(50).min(deadline.saturating_duration_since(now))
    });
    event_loop.dispatch(timeout, events)?;
    Ok(())
}

fn output_properties_changed(outputs: &[ConnectedOutput], scanouts: &[Scanout]) -> bool {
    outputs.iter().any(|output| {
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
) -> Option<(
    RuntimeOutputConfiguration,
    BTreeMap<OutputId, bool>,
    Duration,
)> {
    request
        .configuration
        .confirmation_timeout_milliseconds
        .map(|timeout_milliseconds| {
            let rollback_power = scanouts
                .iter()
                .map(|scanout| (scanout.output.id, scanout.powered))
                .collect::<BTreeMap<_, _>>();
            (
                output_configuration.clone(),
                rollback_power,
                Duration::from_millis(timeout_milliseconds),
            )
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
            enabled: output.enabled,
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

fn apply_requested_output_power(
    desired_power: BTreeMap<OutputId, bool>,
    flutter: &mut Option<flutter_runtime::FlutterRuntime>,
    scheduler: &mut output_scheduler::OutputScheduler,
    frame_scheduler: &mut frame_scheduler::FrameScheduler,
    swapchain: &mut RenderSwapchains,
    scanouts: &mut Vec<Scanout>,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    events.output_power_requests.extend(desired_power);
    if apply_output_power_requests(
        flutter
            .as_mut()
            .ok_or("Flutter runtime disappeared during output power application")?,
        scheduler,
        swapchain,
        scanouts,
        events,
    )? {
        frame_scheduler.reconfigure(scanouts, Instant::now());
    }
    Ok(())
}

fn finish_output_apply(
    request: PendingOutputApply,
    current_serial: u64,
    confirmation_rollback: Option<(
        RuntimeOutputConfiguration,
        BTreeMap<OutputId, bool>,
        Duration,
    )>,
    prepared_persistence: Option<options::PreparedOutputConfig>,
    active_confirmation: &mut Option<ActiveOutputConfirmation>,
    pending_success: &mut Option<PendingOutputApply>,
    events: &mut RuntimeState,
) {
    if let Some((rollback_configuration, rollback_power, timeout)) = confirmation_rollback {
        *active_confirmation = Some(begin_output_confirmation(
            current_serial,
            timeout,
            rollback_configuration,
            rollback_power,
            prepared_persistence,
        ));
    } else if let Some(prepared) = prepared_persistence {
        events.output_control_dirty = true;
        if let Err(error) = prepared.commit() {
            request.reply(Err(output_control::OutputControlFailure::new(
                "persistence_failed",
                &error,
            )));
            warn!(%error, "output configuration applied but could not be persisted");
            return;
        }
    }
    *pending_success = Some(request);
}

struct StagedOutputApply {
    request: PendingOutputApply,
    current_serial: u64,
    configuration: RuntimeOutputConfiguration,
    outputs: Vec<ConnectedOutput>,
    desired_power: BTreeMap<OutputId, bool>,
    confirmation_rollback: Option<(
        RuntimeOutputConfiguration,
        BTreeMap<OutputId, bool>,
        Duration,
    )>,
    prepared_persistence: Option<options::PreparedOutputConfig>,
    transform_only: bool,
    hardware_changed: bool,
    resident_mode_change: bool,
    topology_changed: bool,
}

#[allow(clippy::too_many_arguments)]
fn stage_output_apply(
    request: PendingOutputApply,
    connectors: Vec<ConnectedConnector>,
    current_snapshot: &output_control::OutputControlSnapshot,
    max_outputs: usize,
    output_configuration: &RuntimeOutputConfiguration,
    persistence_available: bool,
    output_config: Option<&Path>,
    topology: &TopologyManager,
    scanouts: &[Scanout],
    events: &mut RuntimeState,
) -> Option<StagedOutputApply> {
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
        Ok(outputs) => outputs,
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
    let topology_changed =
        preview.outputs != current_topology.outputs || preview.ticker != current_topology.ticker;

    Some(StagedOutputApply {
        request,
        current_serial: current_snapshot.serial,
        configuration,
        outputs,
        desired_power,
        confirmation_rollback,
        prepared_persistence,
        transform_only,
        hardware_changed,
        resident_mode_change,
        topology_changed,
    })
}

#[allow(clippy::too_many_arguments)]
fn acquire_pending_output_apply(
    scanout_rebased: bool,
    ready_output_apply: &mut Option<(PendingOutputApply, Vec<ConnectedConnector>)>,
    active_output_confirmation: &Option<ActiveOutputConfirmation>,
    scheduler: &mut output_scheduler::OutputScheduler,
    drm_scanner: &mut DrmScanner<SimpleCrtcMapper>,
    drm: &mut DrmDevice,
    flutter: &Option<flutter_runtime::FlutterRuntime>,
    swapchain: &RenderSwapchains,
    scanouts: &[Scanout],
    events: &mut RuntimeState,
    event_loop: &mut EventLoop<'_, RuntimeState>,
    deadline: Option<Instant>,
) -> Result<bool, Box<dyn Error>> {
    if scanout_rebased && let Some((request, _)) = ready_output_apply.take() {
        // A VT resume invalidates the scheduler and any connector view
        // prepared against it. Re-scan the request after topology repair.
        events.pending_output_applies.push_front(request);
    }
    if scanout_rebased || ready_output_apply.is_some() {
        return Ok(false);
    }
    let Some(request) = events.pending_output_applies.pop_front() else {
        return Ok(false);
    };
    if active_output_confirmation.is_some() {
        request.reply(Err(output_control::OutputControlFailure::new(
            "confirmation_pending",
            "keep or roll back the current output configuration before applying another",
        )));
        return Ok(true);
    }
    if scheduler.has_pending_scanout_work() {
        events.pending_output_applies.push_front(request);
        drain_frames_before_reconfiguration(
            flutter, scheduler, swapchain, scanouts, events, event_loop, deadline,
        )?;
        return Ok(true);
    }

    let connectors = match scan_connected_connectors(drm_scanner, drm) {
        Ok(connectors) => connectors,
        Err(error) => {
            request.reply(Err(output_control::OutputControlFailure::new(
                "apply_failed",
                format!("DRM connector scan failed: {error}"),
            )));
            events.topology_dirty = true;
            return Ok(true);
        }
    };
    // A direct apply request performs a fresh connector scan. Route that
    // observation through the same boundary publication as udev topology and
    // mode changes before validating its serial.
    events.output_control_dirty = true;
    *ready_output_apply = Some((request, connectors));
    Ok(true)
}

#[allow(clippy::too_many_arguments)]
fn apply_resident_output_configuration(
    request: PendingOutputApply,
    current_serial: u64,
    configuration: RuntimeOutputConfiguration,
    outputs: Vec<ConnectedOutput>,
    desired_power: BTreeMap<OutputId, bool>,
    confirmation_rollback: Option<(
        RuntimeOutputConfiguration,
        BTreeMap<OutputId, bool>,
        Duration,
    )>,
    prepared_persistence: Option<options::PreparedOutputConfig>,
    transform_only: bool,
    swapchain: &mut RenderSwapchains,
    scanouts: &mut Vec<Scanout>,
    topology: &mut TopologyManager,
    events: &mut RuntimeState,
    flutter: &mut Option<flutter_runtime::FlutterRuntime>,
    scheduler: &mut output_scheduler::OutputScheduler,
    frame_scheduler: &mut frame_scheduler::FrameScheduler,
    output_configuration: &mut RuntimeOutputConfiguration,
    active_output_confirmation: &mut Option<ActiveOutputConfirmation>,
    pending_output_success: &mut Option<PendingOutputApply>,
) -> Result<(), Box<dyn Error>> {
    scheduler.prepare_reconfiguration(scanouts, events)?;
    let transition = if transform_only {
        flutter_runtime::OutputGeometryTransition::AnimatedRotation
    } else {
        flutter_runtime::OutputGeometryTransition::Immediate
    };
    let apply = apply_resident_output_geometry(
        scanouts,
        swapchain,
        topology,
        output_configuration,
        outputs,
        configuration,
        transition,
        events,
        flutter
            .as_mut()
            .ok_or("Flutter runtime disappeared during resident output reconfiguration")?,
    );
    if let Err(error) = apply {
        let message = error.to_string();
        events.output_control_dirty = true;
        request.reply(Err(output_control::OutputControlFailure::new(
            "apply_failed",
            &message,
        )));
        warn!(%message, "rejected resident output reconfiguration");
        return Ok(());
    }
    frame_scheduler.reconfigure(scanouts, Instant::now());
    apply_requested_output_power(
        desired_power,
        flutter,
        scheduler,
        frame_scheduler,
        swapchain,
        scanouts,
        events,
    )?;
    finish_output_apply(
        request,
        current_serial,
        confirmation_rollback,
        prepared_persistence,
        active_output_confirmation,
        pending_output_success,
        events,
    );
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn apply_hardware_output_configuration(
    request: PendingOutputApply,
    current_serial: u64,
    configuration: RuntimeOutputConfiguration,
    outputs: Vec<ConnectedOutput>,
    desired_power: BTreeMap<OutputId, bool>,
    confirmation_rollback: Option<(
        RuntimeOutputConfiguration,
        BTreeMap<OutputId, bool>,
        Duration,
    )>,
    prepared_persistence: Option<options::PreparedOutputConfig>,
    resident_mode_change: bool,
    renderer: &mut GlesRenderer,
    scanout_allocator: &mut ScanoutAllocator,
    drm: &mut DrmDevice,
    swapchain: &mut RenderSwapchains,
    scanouts: &mut Vec<Scanout>,
    restore_state: &mut RestoreState,
    topology: &mut TopologyManager,
    raster_frames: u64,
    event_loop: &mut EventLoop<'_, RuntimeState>,
    events: &mut RuntimeState,
    flutter: &mut Option<flutter_runtime::FlutterRuntime>,
    flutter_launcher: &mut FlutterLauncher,
    scheduler: &mut output_scheduler::OutputScheduler,
    frame_scheduler: &mut frame_scheduler::FrameScheduler,
    output_configuration: &mut RuntimeOutputConfiguration,
    active_output_confirmation: &mut Option<ActiveOutputConfirmation>,
    pending_output_success: &mut Option<PendingOutputApply>,
    retired_output_flips: &mut u64,
    volition_event_sender: &SyncSender<volition::Event>,
) -> Result<(), Box<dyn Error>> {
    scheduler.prepare_reconfiguration(scanouts, events)?;
    let apply = if resident_mode_change {
        apply_resident_mode_topology(ResidentModeRequest {
            drm,
            swapchain,
            scanouts,
            restore_state,
            topology,
            outputs,
            current_configuration: output_configuration,
            staged_configuration: configuration.clone(),
            event_loop,
            events,
            flutter: flutter
                .as_mut()
                .ok_or("Flutter runtime disappeared during resident mode change")?,
        })
    } else {
        apply_hotplug_topology(HotplugRequest {
            renderer,
            allocator: scanout_allocator,
            drm,
            swapchain,
            scanouts,
            restore_state,
            topology,
            outputs,
            configuration: &configuration,
            frame_number: raster_frames,
            event_loop,
            events,
            flutter,
            flutter_launcher: Some(flutter_launcher),
        })
    };
    if let Err(error) = apply {
        let message = error.to_string();
        events.output_control_dirty = true;
        request.reply(Err(output_control::OutputControlFailure::new(
            "apply_failed",
            &message,
        )));
        if flutter.is_none() {
            return Err(format!(
                "output-control transaction failed after Flutter shutdown: {message}"
            )
            .into());
        }
        // Rollback restarts Flutter on the retained old pools, so its new
        // broker must not receive completion events from the old scheduler.
        *retired_output_flips = retired_output_flips.saturating_add(scheduler.presented_frames());
        (*scheduler, *frame_scheduler) = create_frame_schedulers(
            drm,
            volition_event_sender,
            scanouts,
            swapchain,
            flutter,
            events,
            "rollback lost its physical output pools",
            "Flutter runtime disappeared during output-control rollback",
        )?;
        warn!(%message, "rejected output-control transaction");
        return Ok(());
    }

    *retired_output_flips = retired_output_flips.saturating_add(scheduler.presented_frames());
    if let Some(frontend) = events.wayland.as_mut() {
        frontend.set_scrolling_layout_axes(&configuration.scrolling_layout_axes);
    }
    *output_configuration = configuration;
    events.output_control_dirty = true;
    (*scheduler, *frame_scheduler) = create_frame_schedulers(
        drm,
        volition_event_sender,
        scanouts,
        swapchain,
        flutter,
        events,
        "output scheduler has no physical output pools",
        "Flutter runtime was not restarted after output reconfiguration",
    )?;
    apply_requested_output_power(
        desired_power,
        flutter,
        scheduler,
        frame_scheduler,
        swapchain,
        scanouts,
        events,
    )?;
    events.scanout_rebased = false;
    finish_output_apply(
        request,
        current_serial,
        confirmation_rollback,
        prepared_persistence,
        active_output_confirmation,
        pending_output_success,
        events,
    );
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn apply_staged_output_configuration(
    staged: StagedOutputApply,
    renderer: &mut GlesRenderer,
    scanout_allocator: &mut ScanoutAllocator,
    drm: &mut DrmDevice,
    swapchain: &mut RenderSwapchains,
    scanouts: &mut Vec<Scanout>,
    restore_state: &mut RestoreState,
    topology: &mut TopologyManager,
    raster_frames: u64,
    event_loop: &mut EventLoop<'_, RuntimeState>,
    events: &mut RuntimeState,
    flutter: &mut Option<flutter_runtime::FlutterRuntime>,
    flutter_launcher: &mut FlutterLauncher,
    scheduler: &mut output_scheduler::OutputScheduler,
    frame_scheduler: &mut frame_scheduler::FrameScheduler,
    output_configuration: &mut RuntimeOutputConfiguration,
    active_output_confirmation: &mut Option<ActiveOutputConfirmation>,
    pending_output_success: &mut Option<PendingOutputApply>,
    retired_output_flips: &mut u64,
    volition_event_sender: &SyncSender<volition::Event>,
) -> Result<(), Box<dyn Error>> {
    let StagedOutputApply {
        request,
        current_serial,
        configuration,
        outputs,
        desired_power,
        confirmation_rollback,
        prepared_persistence,
        transform_only,
        hardware_changed,
        resident_mode_change,
        topology_changed,
    } = staged;

    if !hardware_changed && !topology_changed {
        if let Some(frontend) = events.wayland.as_mut() {
            frontend.set_scrolling_layout_axes(&configuration.scrolling_layout_axes);
        }
        *output_configuration = configuration;
        events.output_control_dirty = true;
        apply_requested_output_power(
            desired_power,
            flutter,
            scheduler,
            frame_scheduler,
            swapchain,
            scanouts,
            events,
        )?;
        finish_output_apply(
            request,
            current_serial,
            confirmation_rollback,
            prepared_persistence,
            active_output_confirmation,
            pending_output_success,
            events,
        );
        return Ok(());
    }

    if !hardware_changed {
        return apply_resident_output_configuration(
            request,
            current_serial,
            configuration,
            outputs,
            desired_power,
            confirmation_rollback,
            prepared_persistence,
            transform_only,
            swapchain,
            scanouts,
            topology,
            events,
            flutter,
            scheduler,
            frame_scheduler,
            output_configuration,
            active_output_confirmation,
            pending_output_success,
        );
    }

    apply_hardware_output_configuration(
        request,
        current_serial,
        configuration,
        outputs,
        desired_power,
        confirmation_rollback,
        prepared_persistence,
        resident_mode_change,
        renderer,
        scanout_allocator,
        drm,
        swapchain,
        scanouts,
        restore_state,
        topology,
        raster_frames,
        event_loop,
        events,
        flutter,
        flutter_launcher,
        scheduler,
        frame_scheduler,
        output_configuration,
        active_output_confirmation,
        pending_output_success,
        retired_output_flips,
        volition_event_sender,
    )
}

#[allow(clippy::too_many_arguments)]
fn service_ready_output_apply(
    scanout_rebased: bool,
    ready_output_apply: &mut Option<(PendingOutputApply, Vec<ConnectedConnector>)>,
    current_output_snapshot: Option<&output_control::OutputControlSnapshot>,
    max_outputs: usize,
    persistence_available: bool,
    output_config: Option<&Path>,
    renderer: &mut GlesRenderer,
    scanout_allocator: &mut ScanoutAllocator,
    drm: &mut DrmDevice,
    swapchain: &mut RenderSwapchains,
    scanouts: &mut Vec<Scanout>,
    restore_state: &mut RestoreState,
    topology: &mut TopologyManager,
    raster_frames: u64,
    event_loop: &mut EventLoop<'_, RuntimeState>,
    events: &mut RuntimeState,
    flutter: &mut Option<flutter_runtime::FlutterRuntime>,
    flutter_launcher: &mut FlutterLauncher,
    scheduler: &mut output_scheduler::OutputScheduler,
    frame_scheduler: &mut frame_scheduler::FrameScheduler,
    output_configuration: &mut RuntimeOutputConfiguration,
    active_output_confirmation: &mut Option<ActiveOutputConfirmation>,
    pending_output_success: &mut Option<PendingOutputApply>,
    retired_output_flips: &mut u64,
    volition_event_sender: &SyncSender<volition::Event>,
    deadline: Option<Instant>,
) -> Result<bool, Box<dyn Error>> {
    if scanout_rebased {
        return Ok(false);
    }
    let Some((request, connectors)) = ready_output_apply.take() else {
        return Ok(false);
    };
    let scanout_work_pending = scheduler.has_pending_scanout_work();
    let resident_targets_idle = flutter.as_ref().is_some_and(|runtime| {
        scanouts
            .iter()
            .all(|scanout| runtime.output_target_available(scanout.output.id))
    });
    if scanout_work_pending || !resident_targets_idle {
        // Connector discovery deliberately spans an event-loop iteration. A
        // Flutter frame which was already in flight can become ready or
        // submitted during that boundary. Keep the prepared request as a
        // render barrier and drain that final old-geometry frame.
        *ready_output_apply = Some((request, connectors));
        drain_frames_before_reconfiguration(
            flutter, scheduler, swapchain, scanouts, events, event_loop, deadline,
        )?;
        return Ok(true);
    }

    let current_snapshot =
        current_output_snapshot.expect("prepared output apply has a publication snapshot");
    if let Some(staged) = stage_output_apply(
        request,
        connectors,
        current_snapshot,
        max_outputs,
        output_configuration,
        persistence_available,
        output_config,
        topology,
        scanouts,
        events,
    ) {
        apply_staged_output_configuration(
            staged,
            renderer,
            scanout_allocator,
            drm,
            swapchain,
            scanouts,
            restore_state,
            topology,
            raster_frames,
            event_loop,
            events,
            flutter,
            flutter_launcher,
            scheduler,
            frame_scheduler,
            output_configuration,
            active_output_confirmation,
            pending_output_success,
            retired_output_flips,
            volition_event_sender,
        )?;
    }
    Ok(true)
}

#[derive(Clone, Copy)]
struct TopologyReconfigurationRequest {
    scanout_rebased: bool,
    kms_reconfigure_requested: bool,
    resident_geometry_reconfigure_requested: bool,
}

struct ObservedOutputTopology {
    outputs: Vec<ConnectedOutput>,
    changed: bool,
}

enum OutputTopologyObservation {
    Stable,
    WaitingForOutputs,
    Reconfigure(ObservedOutputTopology),
}

fn take_topology_reconfiguration_request(
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

#[allow(clippy::too_many_arguments)]
fn observe_output_topology(
    request: TopologyReconfigurationRequest,
    drm_scanner: &mut DrmScanner<SimpleCrtcMapper>,
    drm: &mut DrmDevice,
    max_outputs: usize,
    output_configuration: &RuntimeOutputConfiguration,
    scanouts: &[Scanout],
    outputs_disconnected: &mut bool,
    flutter: &mut Option<flutter_runtime::FlutterRuntime>,
    events: &mut RuntimeState,
    event_loop: &mut EventLoop<'_, RuntimeState>,
) -> Result<OutputTopologyObservation, Box<dyn Error>> {
    let TopologyReconfigurationRequest {
        scanout_rebased,
        kms_reconfigure_requested,
        resident_geometry_reconfigure_requested,
    } = request;
    let outputs = connected_outputs(drm_scanner, drm, max_outputs, output_configuration)?;
    let observed_output_changed = output_properties_changed(&outputs, scanouts);
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
            scanouts.iter().map(|scanout| scanout.output.id),
            outputs.iter().map(|output| output.id),
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
            flutter
                .as_mut()
                .ok_or("Flutter runtime disappeared while outputs were disconnected")?
                .set_outputs_visible(false)?;
            warn!(
                retry_ms = KMS_PRESENTATION_RECOVERY_RETRY.as_millis(),
                "all DRM outputs disconnected; keeping the session alive until one reconnects"
            );
        }
        events.topology_dirty = true;
        events.resident_geometry_reconfigure_requested |= resident_geometry_reconfigure_requested;
        event_loop.dispatch(KMS_PRESENTATION_RECOVERY_RETRY, events)?;
        return Ok(OutputTopologyObservation::WaitingForOutputs);
    }
    if !topology_deferred && *outputs_disconnected {
        *outputs_disconnected = false;
        info!(
            connected_outputs = outputs.len(),
            "DRM output reconnected; rebuilding presentation state"
        );
    }
    if !topology_deferred {
        events.output_control_dirty = true;
    }
    let changed =
        !topology_deferred && (outputs.len() != scanouts.len() || observed_output_changed);
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

#[allow(clippy::too_many_arguments)]
fn apply_observed_output_topology(
    request: TopologyReconfigurationRequest,
    observed: ObservedOutputTopology,
    screenshot_manager: &mut Option<screenshot::ScreenshotManager>,
    renderer: &mut GlesRenderer,
    scanout_allocator: &mut ScanoutAllocator,
    drm: &mut DrmDevice,
    swapchain: &mut RenderSwapchains,
    scanouts: &mut Vec<Scanout>,
    restore_state: &mut RestoreState,
    topology: &mut TopologyManager,
    output_configuration: &mut RuntimeOutputConfiguration,
    raster_frames: u64,
    event_loop: &mut EventLoop<'_, RuntimeState>,
    deadline: Option<Instant>,
    events: &mut RuntimeState,
    flutter: &mut Option<flutter_runtime::FlutterRuntime>,
    flutter_launcher: &mut FlutterLauncher,
    scheduler: &mut output_scheduler::OutputScheduler,
    frame_scheduler: &mut frame_scheduler::FrameScheduler,
    retired_output_flips: &mut u64,
    volition_event_sender: &SyncSender<volition::Event>,
) -> Result<(), Box<dyn Error>> {
    let TopologyReconfigurationRequest {
        scanout_rebased,
        kms_reconfigure_requested,
        resident_geometry_reconfigure_requested,
    } = request;
    let ObservedOutputTopology { outputs, changed } = observed;

    cancel_active_screenshot(
        screenshot_manager,
        flutter
            .as_mut()
            .ok_or("Flutter runtime disappeared before topology change")?,
        true,
        "display topology changed",
    )?;
    let resident_targets_busy = resident_geometry_reconfigure_requested
        && !changed
        && !kms_reconfigure_requested
        && flutter.as_ref().is_none_or(|runtime| {
            scanouts
                .iter()
                .any(|scanout| !runtime.output_target_available(scanout.output.id))
        });
    if !scanout_rebased && (scheduler.has_pending_scanout_work() || resident_targets_busy) {
        // Finish any ready old-topology batch before creating the common
        // rollback point used by the hotplug transaction.
        events.topology_dirty = true;
        events.kms_reconfigure_requested = kms_reconfigure_requested;
        events.resident_geometry_reconfigure_requested = resident_geometry_reconfigure_requested;
        drain_frames_before_reconfiguration(
            flutter, scheduler, swapchain, scanouts, events, event_loop, deadline,
        )?;
        return Ok(());
    }
    if !scanout_rebased {
        scheduler.prepare_reconfiguration(scanouts, events)?;
    }
    if resident_geometry_reconfigure_requested
        && !changed
        && !scanout_rebased
        && !kms_reconfigure_requested
    {
        let staged_configuration = output_configuration.clone();
        apply_resident_output_geometry(
            scanouts,
            swapchain,
            topology,
            output_configuration,
            outputs,
            staged_configuration,
            flutter_runtime::OutputGeometryTransition::Immediate,
            events,
            flutter
                .as_mut()
                .ok_or("Flutter runtime disappeared during resident geometry rollback")?,
        )?;
        frame_scheduler.reconfigure(scanouts, Instant::now());
        events.scanout_rebased = false;
        return Ok(());
    }

    *retired_output_flips = retired_output_flips.saturating_add(scheduler.presented_frames());
    let topology_apply = apply_hotplug_topology(HotplugRequest {
        renderer,
        allocator: scanout_allocator,
        drm,
        swapchain,
        scanouts,
        restore_state,
        topology,
        outputs,
        configuration: output_configuration,
        frame_number: raster_frames,
        event_loop,
        events,
        flutter,
        flutter_launcher: Some(flutter_launcher),
    });
    if let Err(error) = topology_apply {
        if scanout_rebased && flutter.is_some() {
            // A monitor may still be link-training after the synchronous
            // recovery baseline. Keep the login alive and retry a fresh scan.
            warn!(
                %error,
                retry_ms = KMS_PRESENTATION_RECOVERY_RETRY.as_millis(),
                "KMS topology rebuild is waiting for the display hardware"
            );
            events.scanout_rebased = true;
            events.topology_dirty = true;
            event_loop.dispatch(KMS_PRESENTATION_RECOVERY_RETRY, events)?;
            return Ok(());
        }
        return Err(error);
    }
    (*scheduler, *frame_scheduler) = create_frame_schedulers(
        drm,
        volition_event_sender,
        scanouts,
        swapchain,
        flutter,
        events,
        "output scheduler has no physical output pools",
        "Flutter runtime was not restarted after topology change",
    )?;
    if events.flutter_reload_requested {
        events.flutter_reload_requested = false;
        info!(
            generation = flutter_launcher.generation,
            "loaded the refreshed Flutter bundle during topology restart"
        );
    }
    // A pause/resume serviced inside the topology transaction was already
    // absorbed by its synchronous candidate commit and the new scheduler.
    events.scanout_rebased = false;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn service_flutter_reload(
    screenshot_manager: &mut Option<screenshot::ScreenshotManager>,
    renderer: &mut GlesRenderer,
    drm: &DrmDevice,
    swapchain: &mut RenderSwapchains,
    scanouts: &[Scanout],
    topology: &TopologyManager,
    event_loop: &mut EventLoop<'_, RuntimeState>,
    deadline: Option<Instant>,
    events: &mut RuntimeState,
    flutter: &mut Option<flutter_runtime::FlutterRuntime>,
    flutter_launcher: &mut FlutterLauncher,
    scheduler: &mut output_scheduler::OutputScheduler,
    frame_scheduler: &mut frame_scheduler::FrameScheduler,
    retired_output_flips: &mut u64,
    volition_event_sender: &SyncSender<volition::Event>,
) -> Result<bool, Box<dyn Error>> {
    if !events.flutter_reload_requested {
        return Ok(false);
    }
    cancel_active_screenshot(
        screenshot_manager,
        flutter
            .as_mut()
            .ok_or("Flutter runtime disappeared before bundle refresh")?,
        true,
        "Flutter runtime is refreshing",
    )?;
    let scanout_work_pending = scheduler.has_pending_scanout_work();
    let resident_targets_idle = flutter.as_ref().is_some_and(|runtime| {
        scanouts
            .iter()
            .all(|scanout| runtime.output_target_available(scanout.output.id))
    });
    if scanout_work_pending || !resident_targets_idle {
        // Stop servicing the producer while its last output batch reaches
        // every affected CRTC. A ready fence or page flip wakes calloop.
        drain_frames_before_reconfiguration(
            flutter, scheduler, swapchain, scanouts, events, event_loop, deadline,
        )?;
        return Ok(true);
    }

    scheduler.prepare_reconfiguration(scanouts, events)?;
    let reload = reload_flutter_runtime(
        renderer,
        swapchain,
        scanouts,
        topology,
        events,
        flutter,
        flutter_launcher,
    )?;
    events.flutter_reload_requested = false;
    match reload {
        FlutterReloadOutcome::Replaced => {
            *retired_output_flips =
                retired_output_flips.saturating_add(scheduler.presented_frames());
            (*scheduler, *frame_scheduler) = create_frame_schedulers(
                drm,
                volition_event_sender,
                scanouts,
                swapchain,
                flutter,
                events,
                "output scheduler has no physical output pools",
                "Flutter runtime was not restarted after bundle refresh",
            )?;
            info!(
                generation = flutter_launcher.generation,
                "refreshed Flutter bundle without restarting the compositor session"
            );
        }
        FlutterReloadOutcome::Retained => {
            info!(
                generation = flutter_launcher.generation,
                "retained the active Flutter bundle after refresh preflight rejection"
            );
        }
    }
    Ok(true)
}

#[allow(clippy::too_many_arguments)]
fn service_page_flip_completions(
    renderer: &mut GlesRenderer,
    drm: &mut DrmDevice,
    swapchain: &mut RenderSwapchains,
    scanouts: &[Scanout],
    event_loop: &mut EventLoop<'_, RuntimeState>,
    iteration_now: Instant,
    events: &mut RuntimeState,
    flutter: &mut Option<flutter_runtime::FlutterRuntime>,
    scheduler: &mut output_scheduler::OutputScheduler,
    frame_scheduler: &mut frame_scheduler::FrameScheduler,
) -> Result<bool, Box<dyn Error>> {
    let (changed, power) = events.fingerprint.service(
        drm,
        renderer,
        scanouts,
        flutter.as_mut().ok_or("fingerprint requires Flutter")?,
    )?;
    for (output, powered) in power {
        events.output_power_requests.insert(output, powered);
    }
    if changed {
        frame_scheduler.mark_all_dirty();
        wayland_frontend::reset_all_input_devices(events);
    }
    let runtime = flutter
        .as_mut()
        .ok_or("Flutter runtime disappeared during page-flip completion")?;
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

#[allow(clippy::too_many_arguments)]
fn publish_completed_flutter_frames(
    runtime: &mut flutter_runtime::FlutterRuntime,
    scheduler: &mut output_scheduler::OutputScheduler,
    swapchain: &RenderSwapchains,
    scanouts: &[Scanout],
    events: &mut RuntimeState,
    event_loop: &mut EventLoop<'_, RuntimeState>,
    frame_scheduler: &mut frame_scheduler::FrameScheduler,
    raster_frames: &mut u64,
) -> Result<(), Box<dyn Error>> {
    // Raster completion is published before its callback wakeup. Retire that
    // wakeup and transfer the finished batch before the timeline decision.
    runtime.observe_frame_ready_events(&mut events.flutter_events);
    submit_ready_frames(runtime, scheduler, swapchain, scanouts, events)?;
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
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn schedule_next_flutter_frame(
    runtime: &mut flutter_runtime::FlutterRuntime,
    scheduler: &output_scheduler::OutputScheduler,
    topology: &TopologyManager,
    ready_output_apply: bool,
    frame_limit: Option<u64>,
    raster_frames: u64,
    delivered_vsyncs: &mut u64,
    frame_scheduler: &mut frame_scheduler::FrameScheduler,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    // Publish a Wayland buffer committed immediately before an output
    // deadline so the same timer decision sees its dirty state.
    try_synchronize_flutter_buffers(runtime, events)?;
    let frame_now = Instant::now();
    if runtime.output_rotation_animation_active() && frame_scheduler.output_tick_due(frame_now) {
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
        !events.pending_output_applies.is_empty(),
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

#[allow(clippy::too_many_arguments)]
fn dispatch_output_ticks(
    runtime: &mut flutter_runtime::FlutterRuntime,
    scheduler: &mut output_scheduler::OutputScheduler,
    swapchain: &RenderSwapchains,
    scanouts: &[Scanout],
    events: &mut RuntimeState,
    frame_scheduler: &frame_scheduler::FrameScheduler,
) -> Result<(), Box<dyn Error>> {
    submit_ready_frames(runtime, scheduler, swapchain, scanouts, events)?;
    for tick in frame_scheduler.output_ticks().iter().copied() {
        if let Some(frontend) = events.wayland.as_mut() {
            frontend.frame_tick(tick)?;
        }
        scheduler.process_screencopies_at_tick(
            tick,
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

#[allow(clippy::too_many_arguments)]
fn freeze_prepared_screenshot_frame(
    manager: &mut Option<screenshot::ScreenshotManager>,
    renderer: &mut GlesRenderer,
    runtime: &mut flutter_runtime::FlutterRuntime,
    topology: &TopologyManager,
    scheduler: &output_scheduler::OutputScheduler,
    swapchain: &RenderSwapchains,
    scanouts: &[Scanout],
) -> Result<(), Box<dyn Error>> {
    let Some(manager) = manager.as_mut() else {
        return Ok(());
    };
    let Some(target_output) = manager.target_output() else {
        return Ok(());
    };
    let Some(request_id) = manager.request_id() else {
        return Ok(());
    };
    if scheduler
        .screenshot_framebuffer_for_output(target_output, request_id, scanouts)
        .is_none()
    {
        return Ok(());
    }

    let snapshot = topology.snapshot();
    let atlas =
        AtlasPlan::for_snapshot(&snapshot).ok_or("prepared screenshot has no desktop atlas")?;
    let mut sources = screenshot_composite_sources(
        scheduler,
        swapchain
            .outputs()
            .ok_or("prepared screenshot has no physical output pools")?,
        &atlas,
    )?;
    match manager.capture_prepared_frame(renderer, runtime, target_output, &mut sources) {
        Ok(Some((request_id, texture_id))) => runtime.send_screenshot_action(
            wire::ShellAction::ScreenshotTextureReady,
            request_id,
            Some(texture_id),
        )?,
        Ok(None) => {}
        Err(error) => {
            warn!(%error, "could not freeze the screenshot selection canvas");
            if let Some(request_id) = manager.cancel_selection(runtime, None)? {
                runtime.send_screenshot_action(
                    wire::ShellAction::ScreenshotDone,
                    request_id,
                    None,
                )?;
            }
        }
    }
    Ok(())
}

fn process_flutter_event_batch(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    if events.flutter_input.has_pending() {
        runtime.process_input_batch(&mut events.flutter_input)?;
    }
    // Drain in place so the callback queue retains its allocation across the
    // steady-state AwaitVSync and platform-task hot path.
    let event_count = events
        .flutter_events
        .len()
        .min(MAX_FLUTTER_EVENTS_PER_ITERATION);
    runtime.process_events(events.flutter_events.drain(..event_count))?;
    synchronize_authentication_boundary(events);
    synchronize_flutter_window_commands(runtime, events)?;
    Ok(())
}

fn dispatch_when_background_slice_expires(
    started: Instant,
    event_loop: &mut EventLoop<'_, RuntimeState>,
    events: &mut RuntimeState,
) -> Result<bool, Box<dyn Error>> {
    if started.elapsed() < COMPOSITOR_BACKGROUND_SLICE {
        return Ok(false);
    }
    event_loop.dispatch(Duration::ZERO, events)?;
    Ok(true)
}

#[allow(clippy::too_many_arguments)]
fn synchronize_periodic_power_configuration(
    runtime: &mut flutter_runtime::FlutterRuntime,
    flutter_launcher: &mut FlutterLauncher,
    scanouts: &[Scanout],
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    if flutter_launcher.synchronize_ui_development(runtime)? {
        events.flutter_reload_requested = true;
    }
    synchronize_idle_dpms_configuration(runtime, events);
    synchronize_requested_dpms_off(runtime, scanouts, events);
    Ok(())
}

fn synchronize_periodic_shell_services(
    runtime: &mut flutter_runtime::FlutterRuntime,
    flutter_launcher: &mut FlutterLauncher,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    synchronize_clipboard(runtime, events)?;
    synchronize_system_control_events(runtime, events)?;
    synchronize_notification_events(runtime, events)?;
    synchronize_xembed_tray(runtime, events)?;
    synchronize_shell_keyboard(runtime, events)?;
    synchronize_settings(runtime, events)?;
    synchronize_system_bar_configuration(runtime, events, Some(flutter_launcher));
    Ok(())
}

fn cancel_invalid_screenshot_selection(
    manager: &mut Option<screenshot::ScreenshotManager>,
    runtime: &mut flutter_runtime::FlutterRuntime,
    topology: &TopologyManager,
    scheduler: &output_scheduler::OutputScheduler,
    scanouts: &[Scanout],
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    let invalid = manager.as_ref().is_some_and(|manager| {
        manager.request_id().is_some()
            && (events.secure_session_locked()
                || manager.topology_epoch() != Some(topology.epoch())
                || manager.target_output().is_some_and(|output| {
                    scheduler
                        .framebuffer_index_for_output(output, scanouts)
                        .is_none()
                }))
    });
    if invalid {
        cancel_active_screenshot(
            manager,
            runtime,
            true,
            "screenshot canvas is no longer valid",
        )?;
    }
    Ok(())
}

fn synchronize_flutter_scene_and_input(
    runtime: &mut flutter_runtime::FlutterRuntime,
    background_services_due: bool,
    frame_scheduler: &mut frame_scheduler::FrameScheduler,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    if background_services_due {
        synchronize_flutter_window_management(runtime, events)?;
    }
    synchronize_flutter_scene(runtime, events)?;
    collect_flutter_output_damage(runtime, frame_scheduler);
    synchronize_flutter_input_layout(runtime, events)?;
    synchronize_wayland_cursor(runtime, events)?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn service_kms_lifecycle(
    drm: &mut DrmDevice,
    scanouts: &mut Vec<Scanout>,
    swapchain: &mut RenderSwapchains,
    event_loop: &mut EventLoop<'_, RuntimeState>,
    events: &mut RuntimeState,
    scheduler: &mut output_scheduler::OutputScheduler,
    deadline: Option<Instant>,
) -> Result<bool, Box<dyn Error>> {
    if events
        .lifecycle
        .requires_kms_service(drm.is_active(), events.device_removed)
        && let Err(error) =
            service_session_lifecycle(drm, scanouts, swapchain, event_loop, events, deadline)
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

#[allow(clippy::too_many_arguments)]
fn acknowledge_render_events(
    drm: &mut DrmDevice,
    scanouts: &[Scanout],
    event_loop: &mut EventLoop<'_, RuntimeState>,
    events: &mut RuntimeState,
    flutter: &Option<flutter_runtime::FlutterRuntime>,
    scheduler: &mut output_scheduler::OutputScheduler,
) -> Result<bool, Box<dyn Error>> {
    if !events.sampled_buffer_releases.is_empty() {
        install_sampled_buffer_releases(event_loop, events)?;
    }
    if !events.ready_fence_signals.is_empty() {
        scheduler.acknowledge_ready_fences(
            flutter
                .as_ref()
                .ok_or("Flutter runtime disappeared during fence acknowledgement")?,
            events.ready_fence_signals.drain(..),
        )?;
    }
    if events.volition_events.is_empty() {
        return Ok(false);
    }
    let volition_events = std::mem::take(&mut events.volition_events);
    let Some(stall) = scheduler.acknowledge_volition_events(volition_events, scanouts, events)?
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

#[allow(clippy::too_many_arguments)]
fn apply_pending_sensor_orientation(
    pending_sensor_rotation: OutputTransform,
    output_configuration: &mut RuntimeOutputConfiguration,
    active_output_confirmation: &mut Option<ActiveOutputConfirmation>,
    scanouts: &mut Vec<Scanout>,
    swapchain: &mut RenderSwapchains,
    topology: &mut TopologyManager,
    scheduler: &mut output_scheduler::OutputScheduler,
    frame_scheduler: &mut frame_scheduler::FrameScheduler,
    flutter: &mut Option<flutter_runtime::FlutterRuntime>,
    events: &mut RuntimeState,
    now: Instant,
) -> Result<(), Box<dyn Error>> {
    if pending_sensor_rotation == output_configuration.sensor_rotation
        || scheduler.has_pending_scanout_work()
        || flutter.as_ref().is_none_or(|runtime| {
            runtime.output_rotation_animation_active()
                || scanouts
                    .iter()
                    .any(|scanout| !runtime.output_target_available(scanout.output.id))
        })
    {
        return Ok(());
    }
    scheduler.prepare_reconfiguration(scanouts, events)?;
    apply_automatic_orientation(
        scanouts,
        swapchain,
        topology,
        output_configuration,
        pending_sensor_rotation,
        events,
        flutter
            .as_mut()
            .ok_or("Flutter runtime disappeared during automatic orientation")?,
    )?;
    if let Some(pending) = active_output_confirmation.as_mut() {
        pending.rollback_configuration.sensor_rotation = pending_sensor_rotation;
    }
    frame_scheduler.reconfigure(scanouts, now);
    Ok(())
}

fn expire_output_confirmation(
    now: Instant,
    active_confirmation: &mut Option<ActiveOutputConfirmation>,
    output_configuration: &mut RuntimeOutputConfiguration,
    events: &mut RuntimeState,
) {
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

fn output_control_publication_deferred(events: &RuntimeState) -> bool {
    events.resident_geometry_reconfigure_requested
}

fn output_control_publication_became_dirty(was_dirty: bool, is_dirty: bool) -> bool {
    !was_dirty && is_dirty
}

#[allow(clippy::too_many_arguments)]
fn publish_output_control_updates(
    output_control: &output_control::OutputControlPublisher,
    drm_scanner: &mut DrmScanner<SimpleCrtcMapper>,
    scanouts: &[Scanout],
    topology: &TopologyManager,
    output_configuration: &RuntimeOutputConfiguration,
    persistence_available: bool,
    active_output_confirmation: &Option<ActiveOutputConfirmation>,
    ready_output_apply: bool,
    pending_output_success: &mut Option<PendingOutputApply>,
    pending_confirmation_success: &mut VecDeque<PendingOutputConfirmation>,
    events: &mut RuntimeState,
) -> Result<Option<output_control::OutputControlSnapshot>, Box<dyn Error>> {
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

#[allow(clippy::too_many_arguments)]
fn synchronize_power_policy(
    background_services_due: bool,
    background_maintenance_due: bool,
    scanout_rebased: bool,
    scanouts: &mut Vec<Scanout>,
    swapchain: &mut RenderSwapchains,
    scheduler: &mut output_scheduler::OutputScheduler,
    frame_scheduler: &mut frame_scheduler::FrameScheduler,
    flutter: &mut Option<flutter_runtime::FlutterRuntime>,
    events: &mut RuntimeState,
    now: Instant,
) -> Result<bool, Box<dyn Error>> {
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
        let power_changed = apply_output_power_requests(
            flutter
                .as_mut()
                .ok_or("Flutter runtime disappeared during DPMS dispatch")?,
            scheduler,
            swapchain,
            scanouts,
            events,
        )?;
        if power_changed {
            frame_scheduler.reconfigure(scanouts, Instant::now());
        }
    }
    release_sleep_delay_if_ready(scanouts, events);
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

#[allow(clippy::too_many_arguments)]
fn shutdown_flutter_session(
    screenshot_manager: &mut Option<screenshot::ScreenshotManager>,
    flutter: &mut Option<flutter_runtime::FlutterRuntime>,
    scheduler: &mut output_scheduler::OutputScheduler,
    drm: &mut DrmDevice,
    swapchain: &mut RenderSwapchains,
    scanouts: &mut Vec<Scanout>,
    event_loop: &mut EventLoop<'_, RuntimeState>,
    events: &mut RuntimeState,
    restore_framebuffer: bool,
) -> Result<(), Box<dyn Error>> {
    cancel_active_screenshot(
        screenshot_manager,
        flutter
            .as_mut()
            .ok_or("Flutter runtime disappeared before screenshot teardown")?,
        false,
        "compositor is shutting down",
    )?;
    if drm.is_active() {
        let failures = events
            .gamma_control
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .restore_all(drm);
        for error in failures {
            warn!(%error, "could not restore DRM gamma state during shutdown");
        }
    }
    quiesce_flutter_page_flips(
        flutter
            .as_mut()
            .ok_or("Flutter runtime disappeared before page-flip quiescence")?,
        scheduler,
        drm,
        swapchain,
        scanouts,
        event_loop,
        events,
        restore_framebuffer,
    );
    scheduler.shutdown_volition();
    flutter
        .take()
        .ok_or("Flutter runtime disappeared during orderly shutdown")?
        .shutdown()
        .map_err(|error| format!("Flutter engine shutdown failed: {error}"))?;
    Ok(())
}

pub(super) struct FlutterEventLoopContext<'a, 'event_loop> {
    pub(super) renderer: &'a mut GlesRenderer,
    pub(super) drm: &'a mut DrmDevice,
    pub(super) swapchain: &'a mut RenderSwapchains,
    pub(super) scanouts: &'a mut Vec<Scanout>,
    pub(super) restore_state: &'a mut RestoreState,
    pub(super) drm_scanner: &'a mut DrmScanner<SimpleCrtcMapper>,
    pub(super) allocator: &'a mut GbmAllocator<DrmDeviceFd>,
    pub(super) scanout_allocator: &'a mut ScanoutAllocator,
    pub(super) topology: &'a mut TopologyManager,
    pub(super) max_outputs: usize,
    pub(super) output_configuration: RuntimeOutputConfiguration,
    pub(super) output_config: Option<PathBuf>,
    pub(super) output_control: output_control::OutputControlPublisher,
    pub(super) portal_ipc: Option<portal_ipc::PortalIpcPublisher>,
    pub(super) wayland: Option<wayland_frontend::WaylandFrontend>,
    pub(super) gamma_control: Arc<Mutex<gamma_control::GammaController>>,
    // The startup boundary retains ownership so an error or unwind cannot
    // destroy the engine before that boundary releases DRM master.
    pub(super) flutter: &'a mut Option<flutter_runtime::FlutterRuntime>,
    pub(super) flutter_launcher: &'a mut FlutterLauncher,
    pub(super) duration: Option<Duration>,
    pub(super) frame_limit: Option<u64>,
    pub(super) event_loop: &'a mut EventLoop<'event_loop, RuntimeState>,
}

pub(super) fn run_flutter_event_loop(
    context: FlutterEventLoopContext<'_, '_>,
) -> Result<framebuffer::Handle, Box<dyn Error>> {
    let FlutterEventLoopContext {
        renderer,
        drm,
        swapchain,
        scanouts,
        restore_state,
        drm_scanner,
        allocator,
        scanout_allocator,
        topology,
        max_outputs,
        mut output_configuration,
        output_config,
        output_control,
        portal_ipc,
        wayland,
        gamma_control,
        flutter,
        flutter_launcher,
        duration,
        frame_limit,
        event_loop,
    } = context;
    let persistence_available = output_config.is_some();
    let started = Instant::now();
    let deadline = duration
        .map(|duration| {
            started
                .checked_add(duration)
                .ok_or("Flutter session duration exceeds the monotonic clock range")
        })
        .transpose()?;
    let system_controls = wayland
        .as_ref()
        .map(|_| SystemControls::new())
        .transpose()?;
    let notification_server = start_notification_server(event_loop)?;
    let initial_runtime = flutter
        .as_ref()
        .ok_or("Flutter runtime was not initialized")?;
    let authentication = Some(initial_runtime.authentication());
    let clipboard = initial_runtime.clipboard();
    let native_escape_shortcut = wayland
        .as_ref()
        .map(|frontend| frontend.shortcuts.engine())
        .unwrap_or_default();
    let initial_theme_snapshot = portal_ipc.as_ref().map(|publisher| publisher.snapshot());
    let initial_settings_document_revision = output_control.settings_document_revision();
    let mut events = RuntimeState {
        wayland,
        gamma_control,
        native_escape_shortcut,
        clipboard,
        system_controls,
        notification_server,
        portal_ipc,
        published_theme_snapshot: initial_theme_snapshot,
        published_settings_document_revision: Some(initial_settings_document_revision),
        resolved_theme_accent: initial_theme_snapshot
            .map_or_else(DesktopAccentColor::default, |snapshot| {
                snapshot.accent_color
            }),
        authentication,
        flutter_active: true,
        flutter_input: flutter_runtime::InputQueue::new(swapchain.desktop_size()),
        output_control: Some(output_control.clone()),
        ..RuntimeState::default()
    };
    if let Some(settings_path) = events
        .wayland
        .as_ref()
        .map(|frontend| frontend.settings.path().to_path_buf())
        && let Err(error) = settings_watch::install(&event_loop.handle(), &settings_path)
    {
        warn!(%error, path = %settings_path.display(), "could not watch Denial settings for external edits");
    }
    let _orientation_sensor = start_orientation_sensor(event_loop)?;
    let (volition_event_sender, volition_event_source) = sync_channel(8);
    event_loop.handle().insert_source(
        volition_event_source,
        |event, _, state: &mut RuntimeState| {
            if let ChannelEvent::Msg(event) = event {
                state.volition_events.push(event);
            }
        },
    )?;
    events.synchronize_flutter_pointer_position();
    let mut raster_frames = 0u64;
    let mut delivered_vsyncs = 0u64;
    let mut retired_output_flips = 0u64;
    let (mut scheduler, mut frame_scheduler) = create_frame_schedulers(
        drm,
        &volition_event_sender,
        scanouts,
        swapchain,
        flutter,
        &mut events,
        "output scheduler has no physical output pools",
        "Flutter runtime disappeared before output scheduling",
    )?;
    flutter
        .as_mut()
        .ok_or("Flutter runtime disappeared during initial visibility publication")?
        .set_outputs_visible(scanouts.iter().any(|scanout| scanout.powered))?;
    let mut screenshot_manager = match screenshot::ScreenshotManager::new(events.clipboard.clone())
    {
        Ok(manager) => Some(manager),
        Err(error) => {
            warn!(%error, "screenshot writer is unavailable");
            None
        }
    };
    let mut ready_output_apply: Option<(PendingOutputApply, Vec<ConnectedConnector>)> = None;
    let mut pending_output_success: Option<PendingOutputApply> = None;
    let mut pending_output_confirmation_success: VecDeque<PendingOutputConfirmation> =
        VecDeque::new();
    let mut active_output_confirmation: Option<ActiveOutputConfirmation> = None;
    let mut pending_sensor_rotation = output_configuration.sensor_rotation;
    let mut outputs_disconnected = false;
    let mut operation_cadence = OperationCadence::new(Instant::now());

    // Any native helper inadvertently created by an elevated Flutter thread
    // is normalized before the compositor itself becomes realtime.
    cpu_scheduling::contain_unregistered_priority_threads();
    cpu_scheduling::promote_compositor_thread();

    loop {
        if service_kms_lifecycle(
            drm,
            scanouts,
            swapchain,
            event_loop,
            &mut events,
            &mut scheduler,
            deadline,
        )? {
            continue;
        }
        synchronize_software_dimming(drm, scanouts, &mut events, flutter)?;
        let iteration_now = Instant::now();
        if events.dpms_topology.service_deadline(iteration_now) {
            events.topology_dirty = true;
            info!("DPMS wake topology grace expired; applying the observed connector state");
        }
        let flutter_background_event = events
            .flutter_events
            .iter()
            .any(flutter_runtime::RuntimeEvent::queues_background_service_work);
        let background_services_due = operation_cadence.take_service_due(iteration_now)
            || flutter_background_event
            || interactive_service_work_pending(&events);
        let background_maintenance_due = operation_cadence.take_maintenance_due(iteration_now)
            || events
                .idle_policy
                .next_deadline()
                .is_some_and(|deadline| iteration_now >= deadline);
        if let Some(orientation) = events.pending_orientation.take() {
            pending_sensor_rotation = orientation.output_rotation();
            debug!(?orientation, rotation = ?pending_sensor_rotation, "observed device orientation");
        }
        if acknowledge_render_events(
            drm,
            scanouts,
            event_loop,
            &mut events,
            flutter,
            &mut scheduler,
        )? {
            continue;
        }
        apply_pending_sensor_orientation(
            pending_sensor_rotation,
            &mut output_configuration,
            &mut active_output_confirmation,
            scanouts,
            swapchain,
            topology,
            &mut scheduler,
            &mut frame_scheduler,
            flutter,
            &mut events,
            iteration_now,
        )?;
        expire_output_confirmation(
            iteration_now,
            &mut active_output_confirmation,
            &mut output_configuration,
            &mut events,
        );
        let current_output_snapshot = publish_output_control_updates(
            &output_control,
            drm_scanner,
            scanouts,
            topology,
            &output_configuration,
            persistence_available,
            &active_output_confirmation,
            ready_output_apply.is_some(),
            &mut pending_output_success,
            &mut pending_output_confirmation_success,
            &mut events,
        )?;
        if let Some(reason) = events.lifecycle.shutdown_reason() {
            log_shutdown(reason);
            break;
        }
        if deadline.is_some_and(|deadline| iteration_now >= deadline) {
            break;
        }
        if frame_limit.is_some_and(|limit| raster_frames >= limit) {
            break;
        }
        if events.device_removed {
            return Err("the active DRM device was removed in Flutter event loop".into());
        }

        // A presenting scanout whose connector vanished has no valid target,
        // so keep its old scheduler quiescent until a fresh scan can rebuild
        // it. Blanked scanouts stay outside the scheduler while retaining
        // their trained connector and CRTC state.
        let scanout_rebased = events.scanout_rebased
            || (outputs_disconnected && scanouts.iter().any(|scanout| scanout.powered));
        // Keep this as a level-triggered recovery latch until the topology
        // transaction installs a fresh scheduler. Consuming it here lets an
        // unrelated publication boundary skip topology repair for one
        // iteration; the stale scheduler then immediately redetects the same
        // submitted frame and can spin in KMS recovery with every CRTC off.
        if scanout_rebased && let Some(runtime) = flutter.as_mut() {
            cancel_active_screenshot(
                &mut screenshot_manager,
                runtime,
                true,
                "scanout state changed",
            )?;
        }
        if !scanout_rebased {
            if service_page_flip_completions(
                renderer,
                drm,
                swapchain,
                scanouts,
                event_loop,
                iteration_now,
                &mut events,
                flutter,
                &mut scheduler,
                &mut frame_scheduler,
            )? {
                continue;
            }
            let runtime = flutter
                .as_mut()
                .ok_or("Flutter runtime disappeared during frame scheduling")?;
            publish_completed_flutter_frames(
                runtime,
                &mut scheduler,
                swapchain,
                scanouts,
                &mut events,
                event_loop,
                &mut frame_scheduler,
                &mut raster_frames,
            )?;

            schedule_next_flutter_frame(
                runtime,
                &scheduler,
                topology,
                ready_output_apply.is_some(),
                frame_limit,
                raster_frames,
                &mut delivered_vsyncs,
                &mut frame_scheduler,
                &mut events,
            )?;

            dispatch_output_ticks(
                runtime,
                &mut scheduler,
                swapchain,
                scanouts,
                &mut events,
                &frame_scheduler,
            )?;

            // Freeze a tagged output batch as soon as its page-flip completion
            // makes it visible, before another frame can replace it.
            freeze_prepared_screenshot_frame(
                &mut screenshot_manager,
                renderer,
                runtime,
                topology,
                &scheduler,
                swapchain,
                scanouts,
            )?;
        }
        if let Some(error) = events.error.take() {
            return Err(format!("DRM event error in Flutter event loop: {error}").into());
        }

        let background_started = Instant::now();
        if synchronize_power_policy(
            background_services_due,
            background_maintenance_due,
            scanout_rebased,
            scanouts,
            swapchain,
            &mut scheduler,
            &mut frame_scheduler,
            flutter,
            &mut events,
            background_started,
        )? {
            // Publish DPMS changes at the single loop-boundary gate above
            // before processing more compositor or Flutter work.
            continue;
        }

        handle_ui_development_requests(&mut events, flutter, flutter_launcher);

        if handle_output_confirmation_requests(
            &mut events,
            &mut active_output_confirmation,
            &mut output_configuration,
            &mut pending_output_confirmation_success,
        ) {
            continue;
        }

        if acquire_pending_output_apply(
            scanout_rebased,
            &mut ready_output_apply,
            &active_output_confirmation,
            &mut scheduler,
            drm_scanner,
            drm,
            flutter,
            swapchain,
            scanouts,
            &mut events,
            event_loop,
            deadline,
        )? {
            continue;
        }

        if service_ready_output_apply(
            scanout_rebased,
            &mut ready_output_apply,
            current_output_snapshot.as_ref(),
            max_outputs,
            persistence_available,
            output_config.as_deref(),
            renderer,
            scanout_allocator,
            drm,
            swapchain,
            scanouts,
            restore_state,
            topology,
            raster_frames,
            event_loop,
            &mut events,
            flutter,
            flutter_launcher,
            &mut scheduler,
            &mut frame_scheduler,
            &mut output_configuration,
            &mut active_output_confirmation,
            &mut pending_output_success,
            &mut retired_output_flips,
            &volition_event_sender,
            deadline,
        )? {
            continue;
        }

        if let Some(request) = take_topology_reconfiguration_request(scanout_rebased, &mut events) {
            match observe_output_topology(
                request,
                drm_scanner,
                drm,
                max_outputs,
                &output_configuration,
                scanouts,
                &mut outputs_disconnected,
                flutter,
                &mut events,
                event_loop,
            )? {
                OutputTopologyObservation::Stable => {}
                OutputTopologyObservation::WaitingForOutputs => continue,
                OutputTopologyObservation::Reconfigure(observed) => {
                    apply_observed_output_topology(
                        request,
                        observed,
                        &mut screenshot_manager,
                        renderer,
                        scanout_allocator,
                        drm,
                        swapchain,
                        scanouts,
                        restore_state,
                        topology,
                        &mut output_configuration,
                        raster_frames,
                        event_loop,
                        deadline,
                        &mut events,
                        flutter,
                        flutter_launcher,
                        &mut scheduler,
                        &mut frame_scheduler,
                        &mut retired_output_flips,
                        &volition_event_sender,
                    )?;
                    continue;
                }
            }
        }
        if events.output_control_dirty {
            continue;
        }

        if service_flutter_reload(
            &mut screenshot_manager,
            renderer,
            drm,
            swapchain,
            scanouts,
            topology,
            event_loop,
            deadline,
            &mut events,
            flutter,
            flutter_launcher,
            &mut scheduler,
            &mut frame_scheduler,
            &mut retired_output_flips,
            &volition_event_sender,
        )? {
            continue;
        }

        let runtime = flutter
            .as_mut()
            .ok_or("Flutter runtime disappeared from event loop")?;
        // Close/focus/configure are interactive commands, not periodic service
        // work. Drain them before a spent background slice can defer them;
        // otherwise busy frames can indefinitely postpone an app's close.
        process_flutter_event_batch(runtime, &mut events)?;
        if dispatch_when_background_slice_expires(background_started, event_loop, &mut events)? {
            continue;
        }
        if background_services_due {
            synchronize_periodic_power_configuration(
                runtime,
                flutter_launcher,
                scanouts,
                &mut events,
            )?;
        }
        cancel_invalid_screenshot_selection(
            &mut screenshot_manager,
            runtime,
            topology,
            &scheduler,
            scanouts,
            &mut events,
        )?;
        if background_services_due {
            synchronize_periodic_shell_services(runtime, flutter_launcher, &mut events)?;
        }
        if dispatch_when_background_slice_expires(background_started, event_loop, &mut events)? {
            continue;
        }
        synchronize_flutter_scene_and_input(
            runtime,
            background_services_due,
            &mut frame_scheduler,
            &mut events,
        )?;
        if dispatch_when_background_slice_expires(background_started, event_loop, &mut events)? {
            continue;
        }
        let screenshot_prepared = runtime.take_screenshot_prepared();
        let screenshot_cancelled = runtime.take_screenshot_cancelled();
        let screenshot_request = runtime.take_screenshot_requested();
        if runtime.take_logout_requested() {
            info!("Flutter requested session logout");
            break;
        }
        if events.flutter_channel_closed {
            return Err("Flutter callback channel closed while the engine was running".into());
        }
        if let Some(frontend) = events.wayland.as_mut() {
            frontend.process_pending_dmabufs(renderer)?;
            frontend.process_toplevel_screencopies(renderer)?;
        }

        if begin_pending_screenshot_selection(
            &mut events,
            &mut screenshot_manager,
            topology,
            &scheduler,
            swapchain,
            scanouts,
            allocator,
            runtime,
        )? || handle_prepared_screenshot(
            screenshot_prepared,
            &mut screenshot_manager,
            &scheduler,
            scanouts,
            runtime,
            &mut frame_scheduler,
        )? {
            continue;
        }
        handle_cancelled_screenshot(screenshot_cancelled, &mut screenshot_manager, runtime)?;
        handle_screenshot_request(
            screenshot_request,
            &mut screenshot_manager,
            renderer,
            allocator,
            topology,
            &scheduler,
            swapchain,
            runtime,
        )?;

        let Some(dispatch_timeout) = next_dispatch_timeout(
            Instant::now(),
            runtime,
            &frame_scheduler,
            &operation_cadence,
            &events,
            drm,
            &scheduler,
            deadline,
        ) else {
            break;
        };
        event_loop.dispatch(dispatch_timeout, &mut events)?;
    }

    shutdown_flutter_session(
        &mut screenshot_manager,
        flutter,
        &mut scheduler,
        drm,
        swapchain,
        scanouts,
        event_loop,
        &mut events,
        // A real login session hands KMS ownership back to its display
        // manager. Restoring the framebuffer captured before Denial started is
        // both unnecessary and dangerous here: an atomic commit can wait
        // forever on a fence owned by the compositor which is currently
        // tearing down. Finite KMS tests still restore their captured state
        // after a successful drain.
        duration.is_none(),
    )?;

    let elapsed = started.elapsed();
    let output_page_flips = retired_output_flips.saturating_add(scheduler.presented_frames());
    info!(
        raster_frames,
        output_page_flips,
        delivered_vsyncs,
        elapsed_ms = elapsed.as_secs_f64() * 1_000.0,
        raster_frames_per_second = raster_frames as f64 / elapsed.as_secs_f64(),
        finite = duration.is_some(),
        "independently clocked Flutter KMS session complete"
    );
    Ok(swapchain.representative_framebuffer())
}

#[cfg(test)]
mod tests {
    use super::{
        RuntimeState, output_control_publication_became_dirty, output_control_publication_deferred,
        output_transaction_waiting,
    };

    #[test]
    fn resident_geometry_rollback_stops_frame_production_while_targets_drain() {
        assert!(output_transaction_waiting(false, false, true));
    }

    #[test]
    fn idle_output_transaction_does_not_stop_frame_production() {
        assert!(!output_transaction_waiting(false, false, false));
    }

    #[test]
    fn output_control_publication_waits_for_resident_geometry_reconfiguration() {
        let mut events = RuntimeState::default();
        assert!(!output_control_publication_deferred(&events));

        events.topology_dirty = true;
        assert!(!output_control_publication_deferred(&events));
        events.resident_geometry_reconfigure_requested = true;
        assert!(output_control_publication_deferred(&events));
    }

    #[test]
    fn deferred_dirty_publication_does_not_starve_rollback_reconfiguration() {
        assert!(output_control_publication_became_dirty(false, true));
        assert!(!output_control_publication_became_dirty(true, true));
    }
}
