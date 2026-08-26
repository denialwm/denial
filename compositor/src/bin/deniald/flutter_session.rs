//! Flutter-session adapters for plugins, fences, screenshots, reload, and shutdown.

use super::kms_render::{physical_rect, smithay_output_transform};
use super::kms_session::service_session_lifecycle;
use super::*;

pub(super) fn native_app_plugins_require_service(events: &RuntimeState) -> bool {
    !events.native_release_commands.is_empty()
        || !events.native_ready_frames.is_empty()
        || !events.native_plugin_actions.is_empty()
        || events
            .native_app_plugins
            .as_ref()
            .is_some_and(native_app_plugin::NativeAppPluginManager::has_dirty_target_pools)
}

pub(super) fn service_native_app_plugins(
    event_loop: &mut EventLoop<'_, RuntimeState>,
    events: &mut RuntimeState,
    allocator: &mut GbmAllocator<DrmDeviceFd>,
) -> Result<(), Box<dyn Error>> {
    let Some(mut manager) = events.native_app_plugins.take() else {
        events.native_plugin_actions.clear();
        events.native_release_commands.clear();
        events.native_ready_frames.clear();
        return Ok(());
    };

    for release in events.native_release_commands.drain(..) {
        if let Err(error) = manager.handle_release_command(release) {
            warn!(%error, "native application plugin release command failed");
        }
    }
    for key in events.native_ready_frames.drain(..) {
        manager.activate_frame(key);
    }

    let default_size = events.native_plugin_default_size;
    let formats = &events.native_plugin_formats;
    manager.refresh_dirty_target_pools(formats, allocator)?;
    let release_sender = events
        .native_release_sender
        .as_ref()
        .ok_or("native application release channel disappeared")?;
    for action in events.native_plugin_actions.drain(..) {
        let watch =
            match manager.handle_action(action, default_size, formats, allocator, release_sender) {
                Ok(watch) => watch,
                Err(error) => {
                    warn!(%error, "rejected native application plugin event");
                    continue;
                }
            };
        let Some(watch) = watch else {
            continue;
        };
        let key = watch.key;
        event_loop.handle().insert_source(
            Generic::new(watch.fence, Interest::READ, PollMode::Level),
            move |_, _, state: &mut RuntimeState| {
                state.native_ready_frames.push(key);
                Ok(PostAction::Remove)
            },
        )?;
    }

    events.native_app_plugins = Some(manager);
    Ok(())
}
pub(super) fn install_sampled_buffer_releases(
    event_loop: &mut EventLoop<'_, RuntimeState>,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    for (fence, batch) in events.sampled_buffer_releases.drain(..) {
        let Some(fence) = fence else {
            // The raster thread already used glFinish. Drop the guards here so
            // producer release remains on the compositor thread.
            batch.complete_native_releases_without_fence()?;
            drop(batch);
            continue;
        };
        batch.materialize_native_releases(fence.as_fd())?;
        let mut batch = Some(batch);
        event_loop.handle().insert_source(
            Generic::new(fence, Interest::READ, PollMode::Level),
            move |_, _, _| {
                // A sync_file becomes readable only after every preceding
                // Flutter sample command has completed on the GPU.
                if let Some(batch) = batch.as_ref()
                    && let Err(error) = batch.complete_native_releases()
                {
                    error!(%error, "could not complete a native plugin buffer release");
                }
                drop(batch.take());
                Ok(PostAction::Remove)
            },
        )?;
    }
    Ok(())
}

#[cfg(feature = "flutter")]
pub(super) fn install_ready_fence_watch(
    event_loop: &mut EventLoop<'_, RuntimeState>,
    watch: output_scheduler::ReadyFenceWatch,
) -> Result<(), Box<dyn Error>> {
    let (fence, signal) = watch.into_parts();
    event_loop.handle().insert_source(
        Generic::new(fence, Interest::READ, PollMode::Level),
        move |_, _, state: &mut RuntimeState| {
            // Readability makes an unconsumed output target reusable and authorizes
            // fence-free Volition lookahead after an earlier KMS submission.
            state.ready_fence_signals.push(signal);
            Ok(PostAction::Remove)
        },
    )?;
    Ok(())
}

#[cfg(feature = "flutter")]
pub(super) fn submit_ready_frames(
    scheduler: &mut output_scheduler::OutputScheduler,
    swapchain: &RenderSwapchains,
    scanouts: &[Scanout],
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    scheduler.submit_ready(
        swapchain
            .outputs()
            .ok_or("ready submission has no physical output pools")?,
        scanouts,
        events,
    )
}

#[cfg(feature = "flutter")]
#[derive(Debug)]
pub(super) struct ActiveOutputConfirmation {
    pub(super) state: output_control::OutputControlConfirmation,
    pub(super) deadline: Instant,
    pub(super) rollback_configuration: RuntimeOutputConfiguration,
    pub(super) rollback_power: BTreeMap<OutputId, bool>,
    pub(super) prepared_persistence: Option<options::PreparedOutputConfig>,
}
pub(super) fn confirmation_deadline_unix_milliseconds(timeout: Duration) -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .saturating_add(timeout)
        .as_millis()
        .try_into()
        .unwrap_or(u64::MAX)
}

#[cfg(feature = "flutter")]
pub(super) fn begin_output_confirmation(
    serial: u64,
    timeout: Duration,
    rollback_configuration: RuntimeOutputConfiguration,
    rollback_power: BTreeMap<OutputId, bool>,
    prepared_persistence: Option<options::PreparedOutputConfig>,
) -> ActiveOutputConfirmation {
    ActiveOutputConfirmation {
        state: output_control::OutputControlConfirmation {
            token: output_control::next_serial(serial),
            deadline_unix_milliseconds: confirmation_deadline_unix_milliseconds(timeout),
        },
        deadline: Instant::now() + timeout,
        rollback_configuration,
        rollback_power,
        prepared_persistence,
    }
}

#[cfg(feature = "flutter")]
#[allow(clippy::too_many_arguments)]
pub(super) fn cancel_active_screenshot(
    manager: &mut Option<screenshot::ScreenshotManager>,
    runtime: &mut flutter_runtime::FlutterRuntime,
    notify_flutter: bool,
    reason: &'static str,
) -> Result<(), Box<dyn Error>> {
    let Some(manager) = manager.as_mut() else {
        return Ok(());
    };
    let Some(request_id) = manager.cancel_selection(runtime, None)? else {
        return Ok(());
    };
    if notify_flutter {
        runtime.send_screenshot_action(wire::ShellAction::ScreenshotDone, request_id, None)?;
    }
    info!(request_id, reason, "cancelled screenshot selection");
    Ok(())
}

#[cfg(feature = "flutter")]
pub(super) fn screenshot_buffer_modifier(
    scheduler: &output_scheduler::OutputScheduler,
    swapchains: &OutputSwapchains,
    output: OutputId,
) -> Result<Modifier, Box<dyn Error>> {
    let index = scheduler
        .stable_framebuffer_index(output)
        .ok_or("screenshot output has no stable framebuffer")?;
    swapchains
        .for_output(output)
        .and_then(|pool| pool.buffers.get(index))
        .map(|buffer| buffer.format().modifier)
        .ok_or_else(|| "screenshot output buffer exceeds its native pool".into())
}

#[cfg(feature = "flutter")]
pub(super) fn screenshot_composite_sources(
    scheduler: &output_scheduler::OutputScheduler,
    swapchains: &OutputSwapchains,
    atlas: &AtlasPlan,
) -> Result<Vec<wayland_frontend::OutputCompositeSource>, Box<dyn Error>> {
    atlas
        .outputs
        .iter()
        .map(|output| {
            let index = scheduler
                .stable_framebuffer_index(output.id)
                .ok_or("screenshot output has no stable framebuffer")?;
            let dmabuf = swapchains
                .for_output(output.id)
                .and_then(|pool| pool.buffers.get(index))
                .ok_or("screenshot output buffer exceeds its native pool")?
                .dmabuf
                .clone();
            Ok(wayland_frontend::OutputCompositeSource {
                dmabuf,
                destination: physical_rect(output.source_rect)?,
                transform: smithay_output_transform(output.transform),
            })
        })
        .collect()
}

#[cfg(feature = "flutter")]
#[allow(clippy::too_many_arguments)]
pub(super) fn reload_flutter_runtime(
    renderer: &mut GlesRenderer,
    swapchain: &RenderSwapchains,
    scanouts: &[Scanout],
    topology: &TopologyManager,
    events: &mut RuntimeState,
    flutter: &mut Option<flutter_runtime::FlutterRuntime>,
    flutter_launcher: &mut FlutterLauncher,
) -> Result<(), Box<dyn Error>> {
    let snapshot = topology.snapshot();
    let atlas = AtlasPlan::for_snapshot(&snapshot)
        .ok_or("current topology produced no atlas during Flutter bundle refresh")?;
    let Some(mut old_runtime) = flutter.take() else {
        return Err("Flutter runtime disappeared during bundle refresh".into());
    };
    let prepare_restart = (|| -> Result<(), Box<dyn Error>> {
        old_runtime.process_events(events.flutter_events.drain(..))?;
        let _ = flutter_launcher.synchronize_ui_development(&mut old_runtime)?;
        synchronize_authentication_boundary(events);
        synchronize_clipboard(&mut old_runtime, events)?;
        synchronize_system_control_events(&mut old_runtime, events)?;
        synchronize_shell_keyboard(&mut old_runtime, events)?;
        synchronize_settings(&mut old_runtime, events)?;
        synchronize_system_bar_configuration(&mut old_runtime, events, Some(flutter_launcher));
        synchronize_flutter_window_management(&mut old_runtime, events)?;
        synchronize_flutter_input_layout(&mut old_runtime, events)?;
        Ok(())
    })();
    let shutdown = old_runtime.shutdown();
    events.flutter_events.clear();
    match (prepare_restart, shutdown) {
        (Ok(()), Ok(())) => {}
        (Err(error), Ok(())) => {
            return Err(format!("Flutter pre-refresh drain failed: {error}").into());
        }
        (Ok(()), Err(error)) => {
            return Err(format!("Flutter shutdown before refresh failed: {error}").into());
        }
        (Err(prepare_error), Err(shutdown_error)) => {
            return Err(format!(
                "Flutter pre-refresh drain failed: {prepare_error}; shutdown failed: {shutdown_error}"
            )
            .into());
        }
    }

    *flutter = Some(
        flutter_launcher.start(
            renderer,
            swapchain
                .outputs()
                .ok_or("Flutter bundle refresh has no physical output pools")?,
            scanouts,
            &snapshot,
            &atlas,
        )?,
    );
    events.begin_replacement_flutter_generation(swapchain.desktop_size());
    Ok(())
}

#[cfg(feature = "flutter")]
#[allow(clippy::too_many_arguments)]
pub(super) fn quiesce_flutter_page_flips(
    runtime: &mut flutter_runtime::FlutterRuntime,
    scheduler: &mut output_scheduler::OutputScheduler,
    drm: &mut DrmDevice,
    swapchain: &mut RenderSwapchains,
    scanouts: &[Scanout],
    event_loop: &mut EventLoop<'_, RuntimeState>,
    events: &mut RuntimeState,
    release_drm_master: bool,
) {
    const PAGE_FLIP_DRAIN_TIMEOUT: Duration = Duration::from_millis(250);
    const MAX_DISPATCH_SLICE: Duration = Duration::from_millis(20);

    let deadline = Instant::now() + PAGE_FLIP_DRAIN_TIMEOUT;
    while scheduler.has_submitted() && drm.is_active() {
        let now = Instant::now();
        if now >= deadline {
            warn!(
                timeout_ms = PAGE_FLIP_DRAIN_TIMEOUT.as_millis(),
                "KMS page flips did not quiesce during shutdown; releasing DRM master without atomic restore"
            );
            drm.pause();
            break;
        }

        if let Err(error) = event_loop.dispatch(
            MAX_DISPATCH_SLICE.min(deadline.saturating_duration_since(now)),
            events,
        ) {
            warn!(
                %error,
                "event dispatch failed while draining shutdown page flips; releasing DRM master"
            );
            drm.pause();
            return;
        }
        if let Err(error) =
            service_session_lifecycle(drm, scanouts, swapchain, event_loop, events, Some(deadline))
        {
            warn!(
                %error,
                "session transition failed while draining shutdown page flips; releasing DRM master"
            );
            drm.pause();
            return;
        }
        if let Err(error) = install_sampled_buffer_releases(event_loop, events) {
            warn!(%error, "could not install sampled-buffer release fence during shutdown");
            drm.pause();
            return;
        }
        if !drm.is_active() {
            break;
        }
        if events.scanout_rebased {
            // Resume establishes a synchronous scanout state and invalidates
            // every pre-pause scheduler ownership record. Teardown does not
            // need to rebuild the runtime: release master and let the next
            // compositor establish its own modeset.
            warn!("KMS session was rebased during shutdown; skipping atomic restore");
            drm.pause();
            break;
        }
        if let Some(error) = events.error.take() {
            warn!(
                error,
                "DRM event failed while draining shutdown page flips; skipping atomic restore"
            );
            drm.pause();
            break;
        }
        let Some(output_swapchains) = swapchain.outputs_mut() else {
            warn!("shutdown retirement lost its physical output pools");
            drm.pause();
            return;
        };
        if let Err(error) =
            scheduler.retire_completions_for_shutdown(runtime, output_swapchains, scanouts, events)
        {
            warn!(
                %error,
                "page-flip retirement failed during shutdown; releasing DRM master"
            );
            drm.pause();
            return;
        }
    }

    if release_drm_master && drm.is_active() {
        // Closing a full display-manager session is an ownership handoff,
        // not a temporary KMS experiment. Release the device before Flutter
        // destroys its contexts and buffers; the display manager will
        // establish its own mode when logind activates it.
        // KmsContext::restore_once observes the inactive device and deliberately
        // skips every blocking atomic ioctl.
        drm.pause();
        info!("released DRM master for graphical-session handoff");
    }
}
