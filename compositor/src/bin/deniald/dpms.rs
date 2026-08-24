//! Display-power request collection, idle policy, and atomic KMS transitions.

use super::kms_render::output_plane_state;
use super::*;

pub(super) fn collect_output_power_requests(events: &mut RuntimeState) {
    let requests = events
        .wayland
        .as_mut()
        .map(wayland_frontend::WaylandFrontend::take_output_power_requests)
        .unwrap_or_default();
    for request in requests {
        #[cfg(feature = "flutter")]
        events
            .idle_dpms
            .note_external_power_request(request.output, request.powered);
        events
            .output_power_requests
            .insert(request.output, request.powered);
    }
}

#[cfg(feature = "flutter")]
pub(super) fn synchronize_idle_dpms(scanouts: &[Scanout], events: &mut RuntimeState, now: Instant) {
    let inhibited = events
        .wayland
        .as_mut()
        .is_some_and(wayland_frontend::WaylandFrontend::idle_inhibited);
    let requests = events.idle_dpms.evaluate(
        now,
        inhibited,
        scanouts
            .iter()
            .map(|scanout| (scanout.output.id, scanout.powered)),
    );
    events.queue_idle_power_requests(requests);
}

#[cfg(feature = "flutter")]
pub(super) fn synchronize_idle_dpms_configuration(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) {
    let Some(timeout) = runtime.take_idle_dpms_timeout() else {
        return;
    };
    let requests = events.idle_dpms.configure(timeout, Instant::now());
    events.queue_idle_power_requests(requests);
    if let Some(timeout) = timeout {
        info!(
            timeout_seconds = timeout.as_secs(),
            "configured automatic display power-off"
        );
    } else {
        info!("disabled automatic display power-off");
    }
}

#[cfg(feature = "flutter")]
pub(super) fn synchronize_requested_dpms_off(
    runtime: &mut flutter_runtime::FlutterRuntime,
    scanouts: &[Scanout],
    events: &mut RuntimeState,
) {
    if !runtime.take_dpms_off_requested() {
        return;
    }
    let requests = events.idle_dpms.blank_now(
        scanouts
            .iter()
            .map(|scanout| (scanout.output.id, scanout.powered)),
    );
    events.queue_idle_power_requests(requests);
    info!("requested immediate compositor-owned display power-off");
}

#[cfg(feature = "flutter")]
pub(super) fn apply_output_power_requests(
    runtime: &mut flutter_runtime::FlutterRuntime,
    scheduler: &mut output_scheduler::OutputScheduler,
    swapchain: &mut RenderSwapchains,
    scanouts: &mut [Scanout],
    events: &mut RuntimeState,
) -> Result<bool, Box<dyn Error>> {
    let requests = std::mem::take(&mut events.output_power_requests);
    let mut deferred = BTreeMap::new();
    let mut power_off = Vec::new();
    let mut power_on = Vec::new();
    let mut power_changed = false;

    for (output, powered) in requests {
        let Some(scanout_index) = scanouts
            .iter()
            .position(|scanout| scanout.output.id == output)
        else {
            events.idle_dpms.note_power_failure(output, Instant::now());
            if let Some(frontend) = events.wayland.as_mut() {
                frontend.fail_output_power(output);
            }
            continue;
        };
        let current = scanouts[scanout_index].powered;
        if current == powered {
            if powered {
                scheduler.cancel_power_off(output, scanouts);
            }
            if !powered || !scheduler.power_on_pending(output) {
                if let Some(frontend) = events.wayland.as_mut() {
                    frontend.output_power_applied(output, powered);
                }
            }
            continue;
        }

        if powered {
            power_on.push((output, scanout_index));
        } else {
            power_off.push((output, scanout_index));
        }
    }

    // Stop every affected pipeline before disabling any CRTC. This is real
    // DRM DPMS: `clear()` turns off the connector, CRTC, and planes. Like
    // Niri, wake does not recommit this parked framebuffer. The output is
    // re-enabled only after Flutter produces a fresh frame below.
    let mut waiting_for_power_off = false;
    for &(output, _) in &power_off {
        waiting_for_power_off |= scheduler.begin_power_off(runtime, output, scanouts)?;
    }
    if waiting_for_power_off {
        deferred.extend(power_off.iter().map(|(output, _)| (*output, false)));
    } else if !power_off.is_empty() {
        let mut targets = Vec::with_capacity(power_off.len());
        for &(output, scanout_index) in &power_off {
            let framebuffer_index = scheduler
                .scanning_framebuffer_index(output, scanouts)
                .ok_or("DPMS power-off output has no scheduler framebuffer")?;
            targets.push((output, scanout_index, framebuffer_index));
        }

        let mut cleared = Vec::with_capacity(targets.len());
        let mut failure = None;
        for &(output, scanout_index, framebuffer_index) in &targets {
            match scanouts[scanout_index].surface.clear() {
                Ok(()) => cleared.push((output, scanout_index, framebuffer_index)),
                Err(error) => {
                    failure = Some((scanout_index, error.to_string()));
                    break;
                }
            }
        }

        if let Some((failed_index, error)) = failure {
            let mut rollback_failures = Vec::new();
            for &(output, scanout_index, framebuffer_index) in &cleared {
                let pool = swapchain
                    .outputs()
                    .and_then(|outputs| outputs.for_output(output))
                    .ok_or("DPMS rollback output has no physical buffer pool")?;
                let framebuffer = pool
                    .buffers
                    .get(framebuffer_index)
                    .ok_or("DPMS rollback framebuffer exceeds its output pool")?
                    .framebuffer();
                let state = output_plane_state(&scanouts[scanout_index], framebuffer, pool.size);
                let restore = scanouts[scanout_index]
                    .surface
                    .test_state([state.clone()], true)
                    .and_then(|()| scanouts[scanout_index].surface.commit([state], false));
                if let Err(rollback_error) = restore {
                    rollback_failures.push(format!(
                        "{}: {rollback_error}",
                        scanouts[scanout_index].output.name
                    ));
                }
            }
            for &(output, _) in &power_off {
                scheduler.cancel_power_off(output, scanouts);
                events.idle_dpms.note_power_failure(output, Instant::now());
                if let Some(frontend) = events.wayland.as_mut() {
                    frontend.fail_output_power(output);
                }
            }
            warn!(
                output = scanouts[failed_index].output.name,
                %error,
                restored_outputs = cleared.len(),
                requested_outputs = power_off.len(),
                "aborted compositor-owned display power-off batch"
            );
            if !rollback_failures.is_empty() {
                events.kms_presentation_recovery_requested = true;
                warn!(
                    failures = rollback_failures.join("; "),
                    "DPMS power-off rollback needs in-session KMS recovery"
                );
            }
        } else {
            for &(output, scanout_index, _) in &targets {
                scheduler.power_off(runtime, output, scanouts)?;
                scanouts[scanout_index].powered = false;
                power_changed = true;
                events.output_control_dirty = true;
                events.pending.remove(&scanouts[scanout_index].output.crtc);
                info!(
                    output = scanouts[scanout_index].output.name,
                    "powered off KMS output through DRM DPMS"
                );
                if let Some(frontend) = events.wayland.as_mut() {
                    frontend.output_power_applied(output, false);
                }
            }
        }
    }

    if !power_on.is_empty() {
        for &(output, scanout_index) in &power_on {
            let framebuffer_index = scheduler
                .stable_framebuffer_index(output)
                .ok_or("DPMS wake output has no parked framebuffer")?;
            scheduler.power_on(
                runtime,
                scanout_index,
                framebuffer_index,
                scanouts,
                swapchain
                    .outputs()
                    .ok_or("DPMS wake has no physical output pools")?,
            )?;
            scanouts[scanout_index].powered = true;
            power_changed = true;
            events.output_control_dirty = true;
            info!(
                output = scanouts[scanout_index].output.name,
                "queued a fresh frame to power on the KMS output"
            );
        }
    }

    runtime.set_outputs_visible(scanouts.iter().any(|scanout| scanout.powered))?;
    events.output_power_requests = deferred;
    Ok(power_changed)
}
