//! Bounded calloop dispatch for Flutter, Wayland, KMS, and control-plane events.

use super::kms_pipeline::{HotplugRequest, apply_hotplug_topology, ticker_refresh_millihz};
use super::kms_session::{
    log_shutdown, recover_stalled_kms_presentation, service_session_lifecycle,
};
use super::*;

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
    pub(super) wayland: Option<wayland_frontend::WaylandFrontend>,
    pub(super) flutter: flutter_runtime::FlutterRuntime,
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
        wayland,
        flutter,
        flutter_launcher,
        duration,
        frame_limit,
        event_loop,
    } = context;
    use smithay::reexports::calloop::channel::{Event as ChannelEvent, channel, sync_channel};

    let persistence_available = output_config.is_some();
    let native_app_snapshot = topology.snapshot();
    let native_app_atlas = AtlasPlan::for_snapshot(&native_app_snapshot)
        .ok_or("native application plugin initialization has no output atlas")?;
    let native_app_refresh_millihz = ticker_refresh_millihz(&native_app_snapshot)?;
    let native_app_plugins = native_app_plugin::NativeAppPluginManager::load_configured(
        drm.as_fd(),
        native_app_atlas.engine_scale_120,
        SCALE_BASE,
        native_app_refresh_millihz,
    )?;
    let native_plugin_poll_descriptors = native_app_plugins
        .as_ref()
        .map(native_app_plugin::NativeAppPluginManager::poll_descriptors)
        .transpose()?
        .unwrap_or_default();
    let native_plugin_formats = renderer
        .dmabuf_formats()
        .iter()
        .filter(|format| format.modifier != Modifier::Invalid)
        .take(native_app_plugin::MAX_FORMATS)
        .map(|format| native_app_plugin::NativeAppFormatV1 {
            format: format.code as u32,
            modifier: u64::from(format.modifier),
        })
        .collect::<Vec<_>>();
    let (native_release_sender, native_release_source) = channel();
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
    let (notification_sender, notification_source) =
        sync_channel(NOTIFICATION_EVENT_QUEUE_CAPACITY);
    let notification_server = match NotificationServer::start(move |mut event, stopping| {
        loop {
            match notification_sender.try_send(event) {
                Ok(()) => break,
                Err(std::sync::mpsc::TrySendError::Full(returned))
                    if !stopping.load(Ordering::Acquire) =>
                {
                    event = returned;
                    std::thread::sleep(Duration::from_millis(1));
                }
                Err(_) => break,
            }
        }
    }) {
        Ok(server) => {
            event_loop.handle().insert_source(
                notification_source,
                |event, _, state: &mut RuntimeState| {
                    if let ChannelEvent::Msg(event) = event {
                        state.pending_notification_events.push_back(event);
                    }
                },
            )?;
            Some(server)
        }
        Err(notification_error) => {
            error!(%notification_error, "Denial could not start its notification service");
            None
        }
    };
    let authentication = Some(flutter.authentication());
    let clipboard = flutter.clipboard();
    let native_escape_shortcut = wayland
        .as_ref()
        .map(|frontend| frontend.shortcuts.engine())
        .unwrap_or_default();
    let mut events = RuntimeState {
        wayland,
        native_escape_shortcut,
        clipboard,
        system_controls,
        notification_server,
        authentication,
        flutter_active: true,
        flutter_input: flutter_runtime::InputQueue::new(swapchain.desktop_size()),
        native_app_plugins,
        native_release_sender: Some(native_release_sender),
        native_plugin_formats,
        native_plugin_default_size: (
            swapchain.desktop_size().width,
            swapchain.desktop_size().height,
        ),
        ..RuntimeState::default()
    };
    let _orientation_sensor = match orientation_sensor::OrientationSensor::start() {
        Ok((sensor, source)) => {
            event_loop
                .handle()
                .insert_source(source, |event, _, state: &mut RuntimeState| {
                    if let ChannelEvent::Msg(orientation) = event {
                        state.pending_orientation = Some(orientation);
                    }
                })?;
            Some(sensor)
        }
        Err(error) => {
            warn!(%error, "could not start the orientation sensor worker");
            None
        }
    };
    event_loop.handle().insert_source(
        native_release_source,
        |event, _, state: &mut RuntimeState| {
            if let ChannelEvent::Msg(command) = event {
                state.native_release_commands.push_back(command);
            }
        },
    )?;
    for (plugin_index, descriptor) in native_plugin_poll_descriptors {
        event_loop.handle().insert_source(
            Generic::new(descriptor, Interest::READ, PollMode::Level),
            move |_, _, state: &mut RuntimeState| {
                let mut actions = std::mem::take(&mut state.native_plugin_actions);
                let result = match state.native_app_plugins.as_mut() {
                    Some(manager) => manager
                        .dispatch(plugin_index, &mut actions)
                        .map_err(|error| error.to_string()),
                    None => Err("native application plugin manager disappeared".to_owned()),
                };
                state.native_plugin_actions = actions;
                if let Err(error) = result {
                    warn!(plugin_index, %error, "disabled failed native application plugin event source");
                    return Ok(PostAction::Remove);
                }
                Ok(PostAction::Continue)
            },
        )?;
    }
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
    let mut flutter = Some(flutter);
    let mut scheduler = output_scheduler::OutputScheduler::new(
        drm,
        volition_event_sender.clone(),
        scanouts,
        swapchain
            .outputs()
            .ok_or("output scheduler has no physical output pools")?,
        flutter
            .as_mut()
            .ok_or("Flutter runtime disappeared before output scheduling")?,
        &mut events,
    )?;
    flutter
        .as_mut()
        .ok_or("Flutter runtime disappeared during initial visibility publication")?
        .set_outputs_visible(scanouts.iter().any(|scanout| scanout.powered))?;
    let mut frame_scheduler = frame_scheduler::FrameScheduler::new(scanouts, Instant::now());
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

    // Any native helper inadvertently created by an elevated Flutter thread
    // is normalized before the compositor itself becomes realtime.
    cpu_scheduling::contain_unregistered_priority_threads();
    cpu_scheduling::promote_compositor_thread();

    loop {
        service_session_lifecycle(drm, scanouts, swapchain, event_loop, &mut events, deadline)?;
        service_native_app_plugins(event_loop, &mut events, allocator)?;
        let iteration_now = Instant::now();
        if let Some(orientation) = events.pending_orientation.take() {
            pending_sensor_rotation = orientation.output_rotation();
            debug!(?orientation, rotation = ?pending_sensor_rotation, "observed device orientation");
        }
        events.service_topology_recheck_deadline(iteration_now);
        install_sampled_buffer_releases(event_loop, &mut events)?;
        scheduler.acknowledge_ready_fences(
            flutter
                .as_ref()
                .ok_or("Flutter runtime disappeared during fence acknowledgement")?,
            events.ready_fence_signals.drain(..),
        )?;
        let volition_events = std::mem::take(&mut events.volition_events);
        if let Some(stall) =
            scheduler.acknowledge_volition_events(volition_events, scanouts, &mut events)?
        {
            let commit = stall.commit();
            error!(
                stream = commit.stream,
                framebuffer_index = commit.frame,
                %stall,
                "KMS lookahead remained busy; rebuilding the DRM and render stack in this session"
            );
            scheduler.shutdown_volition();
            recover_stalled_kms_presentation(drm, event_loop, &mut events)?;
            continue;
        }
        let orientation_targets_idle = flutter.as_ref().is_some_and(|runtime| {
            !runtime.output_rotation_animation_active()
                && scanouts
                    .iter()
                    .all(|scanout| runtime.output_target_available(scanout.output.id))
        });
        if pending_sensor_rotation != output_configuration.sensor_rotation
            && !scheduler.has_pending_scanout_work()
            && orientation_targets_idle
        {
            scheduler.prepare_reconfiguration(scanouts, &mut events)?;
            apply_automatic_orientation(
                scanouts,
                swapchain,
                topology,
                &mut output_configuration,
                pending_sensor_rotation,
                &mut events,
                flutter
                    .as_mut()
                    .ok_or("Flutter runtime disappeared during automatic orientation")?,
            )?;
            if let Some(pending) = active_output_confirmation.as_mut() {
                pending.rollback_configuration.sensor_rotation = pending_sensor_rotation;
            }
            frame_scheduler.reconfigure(scanouts, iteration_now);
        }
        if active_output_confirmation
            .as_ref()
            .is_some_and(|pending| iteration_now >= pending.deadline)
        {
            let pending = active_output_confirmation
                .take()
                .expect("expired output confirmation exists");
            output_configuration = pending.rollback_configuration;
            events.output_power_requests.extend(pending.rollback_power);
            events.resident_geometry_reconfigure_requested = true;
            events.output_control_dirty = true;
            info!(
                token = pending.state.token,
                "rolling back unconfirmed output configuration"
            );
        }
        let needs_output_snapshot =
            ready_output_apply.is_some() || pending_output_success.is_some();
        let mut current_output_snapshot =
            output_control.publish_if_dirty(&mut events.output_control_dirty, || {
                output_control_state(
                    drm_scanner,
                    scanouts,
                    topology,
                    &output_configuration,
                    persistence_available,
                    active_output_confirmation
                        .as_ref()
                        .map(|pending| pending.state),
                )
            })?;
        if needs_output_snapshot && current_output_snapshot.is_none() {
            current_output_snapshot = Some(output_control.snapshot());
        }
        if let Some(request) = pending_output_success.take() {
            request.reply(Ok(current_output_snapshot
                .as_ref()
                .expect("successful output apply has a publication snapshot")
                .clone()));
        }
        while let Some(request) = pending_output_confirmation_success.pop_front() {
            request.reply(Ok(()));
        }
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

        // A powered scanout whose connector vanished has no valid
        // presentation target, so keep its old scheduler quiescent until a
        // fresh scan can rebuild it. Already-powered-off scanouts must remain
        // serviceable: their queued DPMS wake commit is what can bring a sink
        // (and therefore its connector) back in the first place.
        let scanout_rebased = events.scanout_rebased
            || (outputs_disconnected && scanouts.iter().any(|scanout| scanout.powered));
        events.scanout_rebased = false;
        if scanout_rebased && let Some(runtime) = flutter.as_mut() {
            cancel_active_screenshot(
                &mut screenshot_manager,
                runtime,
                true,
                "scanout state changed",
            )?;
        }
        if !scanout_rebased {
            let runtime = flutter
                .as_mut()
                .ok_or("Flutter runtime disappeared during page-flip completion")?;
            scheduler.handle_completions(
                runtime,
                swapchain
                    .outputs_mut()
                    .ok_or("page-flip completion has no physical output pools")?,
                scanouts,
                &mut events,
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
            if drm.is_active()
                && let Some(stall) = scheduler.presentation_stall(iteration_now)
            {
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
                // A monitor waking from DPMS can accept an atomic commit while
                // its link is still training, then withhold the matching
                // page-flip event.  Do not return an error here: a display
                // manager interprets the compositor's non-zero exit as an
                // ordinary ended session and drops the user onto a getty.
                // Reset to a synchronous KMS baseline instead; the topology
                // branch below rescans the connectors and recreates Flutter
                // and its per-output scheduler.
                scheduler.shutdown_volition();
                recover_stalled_kms_presentation(drm, event_loop, &mut events)?;
                continue;
            }
            // Deadline-critical lane. Raster completion is published before
            // its callback wakeup, so retire that wakeup without servicing
            // unrelated Flutter messages and transfer the finished output
            // batch before the sole output-timeline decision below. Physical
            // presentations retire resources but never authorize rendering.
            // Input and compositor bookkeeping deliberately run afterward.
            runtime.observe_frame_ready_events(&mut events.flutter_events);

            // A page flip can retire the sole submitted generation while its
            // following frame already occupies Ready. Move that frame into
            // the now-free Volition slot before the timer decision, exposing
            // the third pool entry for exactly one new raster lookahead.
            submit_ready_frames(&mut scheduler, swapchain)?;

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
                raster_frames = raster_frames.saturating_add(1);
            }

            // A Wayland buffer commit can wake calloop immediately before an
            // output deadline. Publish that already-committed source before
            // consuming the tick, so the timer observes the app's dirty state
            // in the same iteration. Metadata rebuilds remain in the
            // background lane below; this is only the steady-state buffer
            // handoff required by the central scheduling decision.
            try_synchronize_flutter_buffers(runtime, &mut events)?;
            let frame_now = Instant::now();
            if runtime.output_rotation_animation_active()
                && frame_scheduler.output_tick_due(frame_now)
            {
                let advance = runtime.advance_output_rotation_animation(frame_now)?;
                if advance.advanced {
                    // Projection-only frames reuse Flutter's retained scene.
                    // No Dart vsync, external-texture advance or buffer
                    // allocation is needed before the late geometry handoff.
                    frame_scheduler.mark_all_dirty();
                }
                if advance.geometry_published {
                    let snapshot = topology.snapshot();
                    let atlas = AtlasPlan::for_snapshot(&snapshot)
                        .ok_or("animated output resize produced no Flutter desktop geometry")?;
                    synchronize_resident_flutter_geometry_state(&mut events, &atlas);
                }
            }
            collect_flutter_output_damage(runtime, &mut frame_scheduler);

            let output_apply_waiting =
                ready_output_apply.is_some() || !events.pending_output_applies.is_empty();
            if !output_apply_waiting && frame_limit.is_none_or(|limit| raster_frames < limit) {
                let frame_action = frame_scheduler.step_with_output_availability(
                    frame_now,
                    runtime.pending_frame(),
                    |output| {
                        scheduler.render_available(output)
                            && runtime.output_target_available(output)
                    },
                );
                match frame_action {
                    frame_scheduler::FrameAction::Skip => {}
                    frame_scheduler::FrameAction::Render { flutter_output } => {
                        if runtime.render_authorized_outputs(
                            frame_scheduler.render_requests(),
                            frame_scheduler.render_texture_ids(),
                            flutter_output,
                        )? {
                            frame_scheduler.flutter_frame_dispatched();
                            delivered_vsyncs = delivered_vsyncs.saturating_add(1);
                        }
                    }
                }
            }

            // Queue any output targets which were complete when this iteration began.
            // This remains ahead of input, Wayland traversal, and background
            // shell synchronization, but follows frame-clock authorization so
            // those tasks cannot perturb Flutter's animation timestamp.
            submit_ready_frames(&mut scheduler, swapchain)?;
            for tick in frame_scheduler.output_ticks().iter().copied() {
                if let Some(frontend) = events.wayland.as_mut() {
                    frontend.frame_tick(tick)?;
                }
                scheduler.process_screencopies_at_tick(
                    tick,
                    renderer,
                    swapchain
                        .outputs_mut()
                        .ok_or("screencopy has no physical output pools")?,
                    scanouts,
                    &mut events,
                )?;
            }

            // Freeze a tagged output batch as soon as its page-flip completion
            // makes it visible. Waiting for a later timeline tick would let
            // another frame replace the tagged scanout first.
            if let Some(manager) = screenshot_manager.as_mut()
                && let Some(target_output) = manager.target_output()
                && let Some(request_id) = manager.request_id()
                && scheduler
                    .screenshot_framebuffer_for_output(target_output, request_id, scanouts)
                    .is_some()
            {
                let snapshot = topology.snapshot();
                let atlas = AtlasPlan::for_snapshot(&snapshot)
                    .ok_or("prepared screenshot has no desktop atlas")?;
                let mut sources = screenshot_composite_sources(
                    &scheduler,
                    swapchain
                        .outputs()
                        .ok_or("prepared screenshot has no physical output pools")?,
                    &atlas,
                )?;
                match manager.capture_prepared_frame(renderer, runtime, target_output, &mut sources)
                {
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
            }
        }
        if let Some(error) = events.error.take() {
            return Err(format!("DRM event error in Flutter event loop: {error}").into());
        }

        let background_started = Instant::now();

        collect_output_power_requests(&mut events);
        synchronize_idle_dpms(scanouts, &mut events, background_started);
        // The synchronous VT-resume commit invalidated the old scheduler's
        // per-output buffer ownership. Preserve requests until the topology
        // path below recreates that scheduler.
        if !scanout_rebased && !events.output_power_requests.is_empty() {
            let power_changed = apply_output_power_requests(
                flutter
                    .as_mut()
                    .ok_or("Flutter runtime disappeared during DPMS dispatch")?,
                &mut scheduler,
                swapchain,
                scanouts,
                &mut events,
            )?;
            if power_changed {
                frame_scheduler.reconfigure(scanouts, Instant::now());
            }
        }
        if events.output_control_dirty {
            // Publish DPMS changes at the single loop-boundary gate above
            // before processing more compositor or Flutter work.
            continue;
        }

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

        let mut output_confirmation_handled = false;
        while let Some(request) = events.pending_output_confirmations.pop_front() {
            let Some(pending) = active_output_confirmation.take() else {
                request.reply(Err(output_control::OutputControlFailure::new(
                    "stale_confirmation",
                    "there is no output configuration awaiting confirmation",
                )));
                continue;
            };
            if request.token != pending.state.token {
                active_output_confirmation = Some(pending);
                request.reply(Err(output_control::OutputControlFailure::new(
                    "stale_confirmation",
                    "the output confirmation token is stale",
                )));
                continue;
            }

            output_confirmation_handled = true;
            match request.action {
                OutputConfirmationAction::Keep => {
                    if let Some(prepared) = pending.prepared_persistence
                        && let Err(error) = prepared.commit()
                    {
                        output_configuration = pending.rollback_configuration;
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
                    pending_output_confirmation_success.push_back(request);
                }
                OutputConfirmationAction::Rollback => {
                    output_configuration = pending.rollback_configuration;
                    events.output_power_requests.extend(pending.rollback_power);
                    events.resident_geometry_reconfigure_requested = true;
                    events.output_control_dirty = true;
                    info!(
                        token = pending.state.token,
                        "rolling back output configuration on request"
                    );
                    pending_output_confirmation_success.push_back(request);
                }
            }
        }
        if output_confirmation_handled {
            continue;
        }

        if scanout_rebased && let Some((request, _)) = ready_output_apply.take() {
            // A VT resume invalidates the scheduler and any connector view
            // prepared against it. Re-scan the request after topology repair.
            events.pending_output_applies.push_front(request);
        }

        if !scanout_rebased
            && ready_output_apply.is_none()
            && let Some(request) = events.pending_output_applies.pop_front()
        {
            if active_output_confirmation.is_some() {
                request.reply(Err(output_control::OutputControlFailure::new(
                    "confirmation_pending",
                    "keep or roll back the current output configuration before applying another",
                )));
                continue;
            }
            if scheduler.has_pending_scanout_work() {
                submit_ready_frames(&mut scheduler, swapchain)?;
                events.pending_output_applies.push_front(request);
                let now = Instant::now();
                let timeout = deadline.map_or(Duration::from_millis(50), |deadline| {
                    Duration::from_millis(50).min(deadline.saturating_duration_since(now))
                });
                event_loop.dispatch(timeout, &mut events)?;
                continue;
            }

            let connectors = match scan_connected_connectors(drm_scanner, drm) {
                Ok(connectors) => connectors,
                Err(error) => {
                    request.reply(Err(output_control::OutputControlFailure::new(
                        "apply_failed",
                        format!("DRM connector scan failed: {error}"),
                    )));
                    events.topology_dirty = true;
                    continue;
                }
            };
            // A direct apply request performs a fresh connector scan. Route
            // that observation through the same boundary publication as udev
            // topology and mode changes before validating its serial.
            events.output_control_dirty = true;
            ready_output_apply = Some((request, connectors));
            continue;
        }

        if !scanout_rebased && let Some((request, connectors)) = ready_output_apply.take() {
            let scanout_work_pending = scheduler.has_pending_scanout_work();
            let resident_targets_idle = flutter.as_ref().is_some_and(|runtime| {
                scanouts
                    .iter()
                    .all(|scanout| runtime.output_target_available(scanout.output.id))
            });
            if scanout_work_pending || !resident_targets_idle {
                // Connector discovery deliberately spans an event-loop
                // iteration. A Flutter frame which was already in flight can
                // become ready or submitted during that boundary. Keep the
                // prepared request as a render barrier and drain that final
                // old-geometry frame instead of treating normal scheduler
                // ownership as a fatal reconfiguration error.
                ready_output_apply = Some((request, connectors));
                submit_ready_frames(&mut scheduler, swapchain)?;
                let now = Instant::now();
                let timeout = deadline.map_or(Duration::from_millis(50), |deadline| {
                    Duration::from_millis(50).min(deadline.saturating_duration_since(now))
                });
                event_loop.dispatch(timeout, &mut events)?;
                continue;
            }
            let current_snapshot = current_output_snapshot
                .as_ref()
                .expect("prepared output apply has a publication snapshot");
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
                continue;
            }
            let transform_only_request = output_request_changes_only_transforms(
                &current_snapshot.outputs,
                &request.configuration.outputs,
            );
            let confirmation_rollback = request
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
                });
            let (staged_configuration, desired_power) = match configuration_from_output_request(
                &request.configuration,
                &connectors,
                max_outputs,
                &output_configuration,
                persistence_available,
            ) {
                Ok(configuration) => configuration,
                Err(error) => {
                    request.reply(Err(error));
                    continue;
                }
            };
            let outputs = match configured_outputs(connectors, max_outputs, &staged_configuration) {
                Ok(outputs) => outputs,
                Err(error) => {
                    request.reply(Err(output_control::OutputControlFailure::new(
                        "invalid_configuration",
                        error.to_string(),
                    )));
                    continue;
                }
            };
            let preview = (|| -> Result<TopologySnapshot, Box<dyn Error>> {
                let mut preview_topology = topology.clone();
                let preview_snapshot = update_topology_for_outputs(
                    &mut preview_topology,
                    &outputs,
                    &staged_configuration,
                )?;
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
                    continue;
                }
            };
            let prepared_persistence = if request.configuration.persistent {
                let path = output_config
                    .as_deref()
                    .expect("persistent requests were rejected without --output-config");
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
                        adaptive_sync: output.adaptive_sync,
                    })
                    .collect::<Vec<_>>();
                match options::prepare_output_config_persistence(path, &persisted_outputs) {
                    Ok(prepared) => Some(prepared),
                    Err(error) => {
                        request.reply(Err(output_control::OutputControlFailure::new(
                            "persistence_failed",
                            &error,
                        )));
                        warn!(%error, path = %path.display(), "could not prepare persistent output configuration");
                        continue;
                    }
                }
            } else {
                None
            };
            let hardware_changed = outputs.len() != scanouts.len()
                || outputs.iter().any(|output| {
                    scanouts
                        .iter()
                        .find(|scanout| scanout.output.id == output.id)
                        .is_none_or(|scanout| {
                            scanout.output.crtc != output.crtc
                                || scanout.output.mode != output.mode
                                || scanout.output.connector != output.connector
                                || scanout.output.vrr_enabled != output.vrr_enabled
                        })
                });
            let topology_changed = preview.outputs != topology.snapshot().outputs;
            if !scanout_rebased && !hardware_changed && !topology_changed {
                output_configuration = staged_configuration;
                events.output_control_dirty = true;
                events.output_power_requests.extend(desired_power);
                let power_changed = apply_output_power_requests(
                    flutter
                        .as_mut()
                        .ok_or("Flutter runtime disappeared during output power application")?,
                    &mut scheduler,
                    swapchain,
                    scanouts,
                    &mut events,
                )?;
                if power_changed {
                    frame_scheduler.reconfigure(scanouts, Instant::now());
                }
                if let Some((rollback_configuration, rollback_power, timeout)) =
                    confirmation_rollback
                {
                    active_output_confirmation = Some(begin_output_confirmation(
                        current_snapshot.serial,
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
                        continue;
                    }
                }
                pending_output_success = Some(request);
                continue;
            }

            if !scanout_rebased && !hardware_changed {
                scheduler.prepare_reconfiguration(scanouts, &mut events)?;
                // Output transforms on resident Flutter pools are compositor
                // projections, never KMS plane rotations. Give Settings the
                // same retained-layer transition used by sensor orientation;
                // mixed layout, scale and mode transactions remain immediate.
                let transition = if transform_only_request {
                    flutter_runtime::OutputGeometryTransition::AnimatedRotation
                } else {
                    flutter_runtime::OutputGeometryTransition::Immediate
                };
                let apply = apply_resident_output_geometry(
                    scanouts,
                    swapchain,
                    topology,
                    &mut output_configuration,
                    outputs,
                    staged_configuration,
                    transition,
                    &mut events,
                    flutter.as_mut().ok_or(
                        "Flutter runtime disappeared during resident output reconfiguration",
                    )?,
                );
                if let Err(error) = apply {
                    let message = error.to_string();
                    events.output_control_dirty = true;
                    request.reply(Err(output_control::OutputControlFailure::new(
                        "apply_failed",
                        &message,
                    )));
                    warn!(%message, "rejected resident output reconfiguration");
                    continue;
                }
                frame_scheduler.reconfigure(scanouts, Instant::now());
                events.output_power_requests.extend(desired_power);
                let power_changed = apply_output_power_requests(
                    flutter
                        .as_mut()
                        .ok_or("Flutter runtime disappeared during output power application")?,
                    &mut scheduler,
                    swapchain,
                    scanouts,
                    &mut events,
                )?;
                if power_changed {
                    frame_scheduler.reconfigure(scanouts, Instant::now());
                }
                if let Some((rollback_configuration, rollback_power, timeout)) =
                    confirmation_rollback
                {
                    active_output_confirmation = Some(begin_output_confirmation(
                        current_snapshot.serial,
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
                        continue;
                    }
                }
                pending_output_success = Some(request);
                continue;
            }

            if !scanout_rebased {
                scheduler.prepare_reconfiguration(scanouts, &mut events)?;
            }
            let apply = apply_hotplug_topology(HotplugRequest {
                renderer,
                allocator: scanout_allocator,
                drm,
                swapchain,
                scanouts,
                restore_state,
                topology,
                outputs,
                configuration: &staged_configuration,
                frame_number: raster_frames,
                event_loop,
                events: &mut events,
                flutter: &mut flutter,
                flutter_launcher: Some(flutter_launcher),
            });
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
                warn!(%message, "rejected output-control transaction");
                continue;
            }

            retired_output_flips =
                retired_output_flips.saturating_add(scheduler.presented_frames());
            output_configuration = staged_configuration;
            events.output_control_dirty = true;
            scheduler = output_scheduler::OutputScheduler::new(
                drm,
                volition_event_sender.clone(),
                scanouts,
                swapchain
                    .outputs()
                    .ok_or("output scheduler has no physical output pools")?,
                flutter
                    .as_mut()
                    .ok_or("Flutter runtime was not restarted after output reconfiguration")?,
                &mut events,
            )?;
            frame_scheduler = frame_scheduler::FrameScheduler::new(scanouts, Instant::now());
            events.output_power_requests.extend(desired_power);
            let power_changed = apply_output_power_requests(
                flutter
                    .as_mut()
                    .ok_or("Flutter runtime disappeared during output power application")?,
                &mut scheduler,
                swapchain,
                scanouts,
                &mut events,
            )?;
            if power_changed {
                frame_scheduler.reconfigure(scanouts, Instant::now());
            }
            if let Some((rollback_configuration, rollback_power, timeout)) = confirmation_rollback {
                active_output_confirmation = Some(begin_output_confirmation(
                    current_snapshot.serial,
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
                    events.scanout_rebased = false;
                    continue;
                }
            }
            pending_output_success = Some(request);
            events.scanout_rebased = false;
            continue;
        }

        let kms_reconfigure_requested = events.kms_reconfigure_requested;
        events.kms_reconfigure_requested = false;
        let resident_geometry_reconfigure_requested =
            events.resident_geometry_reconfigure_requested;
        events.resident_geometry_reconfigure_requested = false;
        if events.topology_dirty
            || scanout_rebased
            || kms_reconfigure_requested
            || resident_geometry_reconfigure_requested
        {
            events.topology_dirty = false;
            let outputs = connected_outputs(drm_scanner, drm, max_outputs, &output_configuration)?;
            let now = Instant::now();
            if outputs.is_empty() {
                if !outputs_disconnected {
                    outputs_disconnected = true;
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
                event_loop.dispatch(KMS_PRESENTATION_RECOVERY_RETRY, &mut events)?;
                continue;
            }
            if outputs_disconnected {
                outputs_disconnected = false;
                info!(
                    connected_outputs = outputs.len(),
                    "DRM output reconnected; rebuilding presentation state"
                );
            }
            let transient_removals = if !scanout_rebased && !kms_reconfigure_requested {
                transient_dpms_output_removal_count(
                    events.dpms_wake_topology_grace_until,
                    now,
                    scanouts.iter().map(|scanout| scanout.output.id),
                    outputs.iter().map(|output| output.id),
                )
            } else {
                0
            };
            if transient_removals > 0 {
                let recheck_at = events
                    .dpms_wake_topology_grace_until
                    .expect("transient DPMS removal has an active grace deadline");
                let first_observation = events.topology_recheck_at.replace(recheck_at).is_none();
                if first_observation {
                    info!(
                        missing_outputs = transient_removals,
                        grace_ms = recheck_at.saturating_duration_since(now).as_millis(),
                        "deferred transient connector removal during DPMS wake"
                    );
                }
            } else {
                if events.topology_recheck_at.take().is_some() {
                    info!("cancelled deferred connector removal after DPMS topology recovered");
                }
                events.output_control_dirty = true;
                let changed = outputs.len() != scanouts.len()
                    || outputs.iter().any(|output| {
                        scanouts
                            .iter()
                            .find(|scanout| scanout.output.id == output.id)
                            .is_none_or(|scanout| {
                                scanout.output.crtc != output.crtc
                                    || scanout.output.mode != output.mode
                                    || scanout.output.connector != output.connector
                                    || scanout.output.vrr_enabled != output.vrr_enabled
                            })
                    });
                info!(
                    connected_outputs = outputs.len(),
                    changed,
                    resumed = scanout_rebased,
                    forced = kms_reconfigure_requested,
                    resident_geometry = resident_geometry_reconfigure_requested,
                    "completed event-driven DRM topology rescan"
                );
                if changed
                    || scanout_rebased
                    || kms_reconfigure_requested
                    || resident_geometry_reconfigure_requested
                {
                    cancel_active_screenshot(
                        &mut screenshot_manager,
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
                    if !scanout_rebased
                        && (scheduler.has_pending_scanout_work() || resident_targets_busy)
                    {
                        // Finish any ready old-topology batch before creating the
                        // common rollback point used by the hotplug transaction.
                        // A signalled ready fence can enter Volition lookahead;
                        // an unfinished one will wake this loop through calloop.
                        submit_ready_frames(&mut scheduler, swapchain)?;
                        events.topology_dirty = true;
                        events.kms_reconfigure_requested = kms_reconfigure_requested;
                        events.resident_geometry_reconfigure_requested =
                            resident_geometry_reconfigure_requested;
                        let now = Instant::now();
                        let timeout = deadline.map_or(Duration::from_millis(50), |deadline| {
                            Duration::from_millis(50).min(deadline.saturating_duration_since(now))
                        });
                        event_loop.dispatch(timeout, &mut events)?;
                        continue;
                    }
                    if !scanout_rebased {
                        scheduler.prepare_reconfiguration(scanouts, &mut events)?;
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
                            &mut output_configuration,
                            outputs,
                            staged_configuration,
                            flutter_runtime::OutputGeometryTransition::Immediate,
                            &mut events,
                            flutter.as_mut().ok_or(
                                "Flutter runtime disappeared during resident geometry rollback",
                            )?,
                        )?;
                        frame_scheduler.reconfigure(scanouts, Instant::now());
                        events.scanout_rebased = false;
                        continue;
                    }
                    retired_output_flips =
                        retired_output_flips.saturating_add(scheduler.presented_frames());
                    let topology_apply = apply_hotplug_topology(HotplugRequest {
                        renderer,
                        allocator: scanout_allocator,
                        drm,
                        swapchain,
                        scanouts,
                        restore_state,
                        topology,
                        outputs,
                        configuration: &output_configuration,
                        frame_number: raster_frames,
                        event_loop,
                        events: &mut events,
                        flutter: &mut flutter,
                        flutter_launcher: Some(flutter_launcher),
                    });
                    if let Err(error) = topology_apply {
                        if scanout_rebased && flutter.is_some() {
                            // Recovery may reach this transaction while a
                            // monitor is still link-training.  Its synchronous
                            // baseline was accepted, but the transaction's
                            // first event-producing flip can still time out.
                            // Keep the login and retry from a fresh connector
                            // scan instead of returning status 1 to SDDM.
                            warn!(
                                %error,
                                retry_ms = KMS_PRESENTATION_RECOVERY_RETRY.as_millis(),
                                "KMS topology rebuild is waiting for the display hardware"
                            );
                            events.scanout_rebased = true;
                            events.topology_dirty = true;
                            event_loop.dispatch(KMS_PRESENTATION_RECOVERY_RETRY, &mut events)?;
                            continue;
                        }
                        return Err(error);
                    }
                    scheduler = output_scheduler::OutputScheduler::new(
                        drm,
                        volition_event_sender.clone(),
                        scanouts,
                        swapchain
                            .outputs()
                            .ok_or("output scheduler has no physical output pools")?,
                        flutter
                            .as_mut()
                            .ok_or("Flutter runtime was not restarted after topology change")?,
                        &mut events,
                    )?;
                    frame_scheduler =
                        frame_scheduler::FrameScheduler::new(scanouts, Instant::now());
                    if events.flutter_reload_requested {
                        events.flutter_reload_requested = false;
                        info!(
                            generation = flutter_launcher.generation,
                            "loaded the refreshed Flutter bundle during topology restart"
                        );
                    }
                    // A pause/resume serviced inside the topology transaction was
                    // already absorbed by its synchronous candidate commit and the
                    // freshly created scheduler.
                    events.scanout_rebased = false;
                    continue;
                }
            }
        }
        if events.output_control_dirty {
            continue;
        }

        if events.flutter_reload_requested {
            cancel_active_screenshot(
                &mut screenshot_manager,
                flutter
                    .as_mut()
                    .ok_or("Flutter runtime disappeared before bundle refresh")?,
                true,
                "Flutter runtime is refreshing",
            )?;
            if scheduler.has_pending_scanout_work() {
                // Stop servicing the producer while its last output batch reaches
                // every affected CRTC. A ready fence or page flip will wake
                // this loop through calloop, without disturbing clients or
                // the graphical session.
                submit_ready_frames(&mut scheduler, swapchain)?;
                let now = Instant::now();
                let timeout = deadline.map_or(Duration::from_millis(50), |deadline| {
                    Duration::from_millis(50).min(deadline.saturating_duration_since(now))
                });
                event_loop.dispatch(timeout, &mut events)?;
                continue;
            }

            scheduler.prepare_reconfiguration(scanouts, &mut events)?;
            retired_output_flips =
                retired_output_flips.saturating_add(scheduler.presented_frames());
            reload_flutter_runtime(
                renderer,
                swapchain,
                scanouts,
                topology,
                &mut events,
                &mut flutter,
                flutter_launcher,
            )?;
            scheduler = output_scheduler::OutputScheduler::new(
                drm,
                volition_event_sender.clone(),
                scanouts,
                swapchain
                    .outputs()
                    .ok_or("output scheduler has no physical output pools")?,
                flutter
                    .as_mut()
                    .ok_or("Flutter runtime was not restarted after bundle refresh")?,
                &mut events,
            )?;
            frame_scheduler = frame_scheduler::FrameScheduler::new(scanouts, Instant::now());
            events.flutter_reload_requested = false;
            info!(
                generation = flutter_launcher.generation,
                "refreshed Flutter bundle without restarting the compositor session"
            );
            continue;
        }

        let runtime = flutter
            .as_mut()
            .ok_or("Flutter runtime disappeared from event loop")?;
        runtime.process_input_batch(&mut events.flutter_input)?;
        // Drain in place so the callback queue keeps its allocation across
        // frame/engine dispatches. AwaitVSync and platform-task traffic is a
        // steady-state hot path and must not rebuild this Vec every time.
        let flutter_event_batch = events
            .flutter_events
            .len()
            .min(MAX_FLUTTER_EVENTS_PER_ITERATION);
        runtime.process_events(events.flutter_events.drain(..flutter_event_batch))?;
        if background_started.elapsed() >= COMPOSITOR_BACKGROUND_SLICE {
            event_loop.dispatch(Duration::ZERO, &mut events)?;
            continue;
        }
        if flutter_launcher.synchronize_ui_development(runtime)? {
            events.flutter_reload_requested = true;
        }
        synchronize_idle_dpms_configuration(runtime, &mut events);
        synchronize_authentication_boundary(&mut events);
        synchronize_requested_dpms_off(runtime, scanouts, &mut events);
        let screenshot_is_invalid = screenshot_manager.as_ref().is_some_and(|manager| {
            manager.request_id().is_some()
                && (events.secure_session_locked()
                    || manager.topology_epoch() != Some(topology.epoch())
                    || manager.target_output().is_some_and(|output| {
                        scheduler
                            .framebuffer_index_for_output(output, scanouts)
                            .is_none()
                    }))
        });
        if screenshot_is_invalid {
            cancel_active_screenshot(
                &mut screenshot_manager,
                runtime,
                true,
                "screenshot canvas is no longer valid",
            )?;
        }
        synchronize_clipboard(runtime, &mut events)?;
        synchronize_system_control_events(runtime, &mut events)?;
        synchronize_notification_events(runtime, &mut events)?;
        synchronize_xembed_tray(runtime, &mut events)?;
        synchronize_shell_keyboard(runtime, &mut events)?;
        synchronize_settings(runtime, &mut events)?;
        synchronize_system_bar_configuration(runtime, &mut events, Some(flutter_launcher));
        if background_started.elapsed() >= COMPOSITOR_BACKGROUND_SLICE {
            event_loop.dispatch(Duration::ZERO, &mut events)?;
            continue;
        }
        synchronize_flutter_window_management(runtime, &mut events)?;
        synchronize_flutter_scene(runtime, &mut events)?;
        collect_flutter_output_damage(runtime, &mut frame_scheduler);
        synchronize_flutter_input_layout(runtime, &mut events)?;
        synchronize_wayland_cursor(runtime, &mut events)?;
        if background_started.elapsed() >= COMPOSITOR_BACKGROUND_SLICE {
            event_loop.dispatch(Duration::ZERO, &mut events)?;
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
        }

        if let Some(target_output) = events.pending_screenshot_selection.take() {
            if let Some(manager) = screenshot_manager.as_mut() {
                let snapshot = topology.snapshot();
                let atlas = AtlasPlan::for_snapshot(&snapshot)
                    .ok_or("screenshot preparation has no atlas")?;
                if scheduler
                    .framebuffer_index_for_output(target_output, scanouts)
                    .is_none()
                {
                    warn!(?target_output, "screenshot target output is not powered");
                    continue;
                }
                let output_swapchains = swapchain
                    .outputs()
                    .ok_or("screenshot selection has no physical output pools")?;
                let modifier =
                    screenshot_buffer_modifier(&scheduler, output_swapchains, target_output)?;
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
            } else {
                warn!("screenshot selection ignored because the writer is unavailable");
            }
        }

        if let Some(request_id) = screenshot_prepared
            && let Some(manager) = screenshot_manager.as_mut()
            && manager.request_id() == Some(request_id.get())
        {
            let Some(target_output) = manager.target_output() else {
                return Err("prepared screenshot lost its target output".into());
            };
            if scheduler
                .framebuffer_index_for_output(target_output, scanouts)
                .is_none()
            {
                let finished = manager.cancel_selection(runtime, Some(request_id.get()))?;
                if let Some(request_id) = finished {
                    runtime.send_screenshot_action(
                        wire::ShellAction::ScreenshotDone,
                        request_id,
                        None,
                    )?;
                }
                continue;
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
        }

        if let Some(request_id) = screenshot_cancelled
            && let Some(manager) = screenshot_manager.as_mut()
            && let Some(request_id) = manager.cancel_selection(runtime, Some(request_id.get()))?
        {
            runtime.send_screenshot_action(wire::ShellAction::ScreenshotDone, request_id, None)?;
        }

        if let Some(request) = screenshot_request {
            if let Some(manager) = screenshot_manager.as_ref() {
                if request.request_id.is_none() {
                    let snapshot = topology.snapshot();
                    if let Some(atlas) = AtlasPlan::for_snapshot(&snapshot) {
                        let output_swapchains = swapchain
                            .outputs()
                            .ok_or("live screenshot has no physical output pools")?;
                        let mut sources =
                            screenshot_composite_sources(&scheduler, output_swapchains, &atlas)?;
                        let source_output = atlas
                            .outputs
                            .first()
                            .ok_or("live screenshot atlas has no outputs")?
                            .id;
                        let modifier = screenshot_buffer_modifier(
                            &scheduler,
                            output_swapchains,
                            source_output,
                        )?;
                        if let Err(error) = manager.capture_live(
                            renderer,
                            allocator,
                            &atlas,
                            modifier,
                            &mut sources,
                            request,
                        ) {
                            warn!(%error, "screenshot capture failed");
                        }
                    } else {
                        warn!("screenshot capture skipped because the atlas is unavailable");
                    }
                }
            } else {
                warn!("screenshot request ignored because the writer is unavailable");
            }
        }

        if let Some(request) = screenshot_request
            && let Some(request_id) = request.request_id.map(|request_id| request_id.get())
            && let Some(manager) = screenshot_manager.as_mut()
            && manager.request_id() == Some(request_id)
        {
            if let Err(error) = manager.finish_selection(renderer, runtime, request) {
                warn!(%error, request_id, "frozen screenshot capture failed");
            }
            runtime.send_screenshot_action(wire::ShellAction::ScreenshotDone, request_id, None)?;
        }

        let now = Instant::now();
        let mut next_dispatch_timeout =
            frame_scheduler.limit_dispatch_timeout(now, runtime.next_dispatch_timeout());
        next_dispatch_timeout = events
            .idle_dpms
            .limit_dispatch_timeout(now, next_dispatch_timeout);
        if drm.is_active() {
            next_dispatch_timeout =
                scheduler.limit_presentation_watchdog_timeout(now, next_dispatch_timeout);
        }
        if events.flutter_input.has_pending() || !events.flutter_events.is_empty() {
            next_dispatch_timeout = Duration::ZERO;
        }
        if let Some(recheck_at) = events.topology_recheck_at {
            next_dispatch_timeout =
                next_dispatch_timeout.min(recheck_at.saturating_duration_since(now));
        }
        let dispatch_timeout = if let Some(deadline) = deadline {
            if now >= deadline {
                break;
            }
            next_dispatch_timeout.min(deadline.saturating_duration_since(now))
        } else {
            next_dispatch_timeout
        };
        event_loop.dispatch(dispatch_timeout, &mut events)?;
    }

    cancel_active_screenshot(
        &mut screenshot_manager,
        flutter
            .as_mut()
            .ok_or("Flutter runtime disappeared before screenshot teardown")?,
        false,
        "compositor is shutting down",
    )?;
    quiesce_flutter_page_flips(
        flutter
            .as_mut()
            .ok_or("Flutter runtime disappeared before page-flip quiescence")?,
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
    );
    scheduler.shutdown_volition();

    flutter
        .take()
        .ok_or("Flutter runtime disappeared during orderly shutdown")?
        .shutdown()
        .map_err(|error| format!("Flutter engine shutdown failed: {error}"))?;

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
