//! Flutter-session adapters for fences, screenshots, reload, and shutdown.

use super::kms_render::{physical_rect, smithay_output_transform};
use super::*;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum FlutterReloadOutcome {
    Replaced,
    /// The refreshed bundle failed; the shell was started again instead.
    RolledBack,
    Retained,
}

pub(super) fn install_sampled_buffer_releases(
    event_loop: &mut EventLoop<'_, RuntimeState>,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    for (fence, batch) in events.sampled_buffer_releases.drain(..) {
        let Some(fence) = fence else {
            // The raster thread already used glFinish. Drop the guards here so
            // client releases remain on the compositor thread.
            drop(batch);
            continue;
        };
        let mut batch = Some(batch);
        event_loop.handle().insert_source(
            Generic::new(fence, Interest::READ, PollMode::Level),
            move |_, _, _| {
                // A sync_file becomes readable only after every preceding
                // Flutter sample command has completed on the GPU.
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
    runtime: &flutter_runtime::FlutterRuntime,
    scheduler: &mut output_scheduler::OutputScheduler,
    swapchain: &RenderSwapchains,
    scanouts: &[Scanout],
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    scheduler.submit_ready(
        runtime,
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
                .scene_dmabuf()
                .clone();
            Ok(wayland_frontend::OutputCompositeSource {
                dmabuf,
                destination: physical_rect(output.source_rect)?,
                transform: smithay_output_transform(output.transform),
            })
        })
        .collect()
}
