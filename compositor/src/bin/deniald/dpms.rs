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
            .idle_policy
            .note_external_power_request(request.output, request.powered);
        events
            .output_power_requests
            .insert(request.output, request.powered);
    }
}

#[derive(Debug, Default)]
pub(super) struct DpmsTopologyGuard {
    parked_outputs: BTreeSet<OutputId>,
    waking_outputs: BTreeSet<OutputId>,
    wake_grace_until: Option<Instant>,
    deferred_removal: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct DeferredDpmsTopology {
    pub(super) missing_outputs: usize,
    pub(super) grace_until: Option<Instant>,
    pub(super) first_observation: bool,
}

impl DpmsTopologyGuard {
    pub(super) fn note_powered_off(&mut self, output: OutputId) {
        self.waking_outputs.remove(&output);
        self.parked_outputs.insert(output);
        if self.waking_outputs.is_empty() {
            self.wake_grace_until = None;
        }
    }

    pub(super) fn note_wake(&mut self, output: OutputId, now: Instant) {
        self.parked_outputs.remove(&output);
        self.waking_outputs.insert(output);
        self.wake_grace_until = Some(now + DPMS_WAKE_TOPOLOGY_GRACE);
    }

    pub(super) fn defer_missing_outputs(
        &mut self,
        now: Instant,
        current: impl IntoIterator<Item = OutputId>,
        observed: impl IntoIterator<Item = OutputId>,
    ) -> Option<DeferredDpmsTopology> {
        self.expire_wake_grace(now);
        let current = current.into_iter().collect::<BTreeSet<_>>();
        let observed = observed.into_iter().collect::<BTreeSet<_>>();
        let missing = current
            .iter()
            .copied()
            .filter(|output| !observed.contains(output))
            .collect::<Vec<_>>();

        if missing.is_empty() {
            // A connector can briefly report connected before another link
            // training event makes it disappear. Keep the output eligible for
            // debounce through the complete wake interval, but cancel any
            // pending removal now that the expected topology was observed.
            self.deferred_removal = false;
            return None;
        }
        if observed.iter().any(|output| !current.contains(output))
            || missing.iter().any(|output| {
                !self.parked_outputs.contains(output) && !self.waking_outputs.contains(output)
            })
        {
            self.cancel();
            return None;
        }

        let grace_until = missing
            .iter()
            .any(|output| self.waking_outputs.contains(output))
            .then_some(self.wake_grace_until)
            .flatten();
        let first_observation = !std::mem::replace(&mut self.deferred_removal, true);
        Some(DeferredDpmsTopology {
            missing_outputs: missing.len(),
            grace_until,
            first_observation,
        })
    }

    pub(super) fn service_deadline(&mut self, now: Instant) -> bool {
        if self.wake_grace_until.is_none_or(|deadline| now < deadline) {
            return false;
        }
        self.waking_outputs.clear();
        self.wake_grace_until = None;
        std::mem::take(&mut self.deferred_removal)
    }

    pub(super) fn limit_dispatch_timeout(&self, now: Instant, timeout: Duration) -> Duration {
        if !self.deferred_removal {
            return timeout;
        }
        self.wake_grace_until.map_or(timeout, |deadline| {
            timeout.min(deadline.saturating_duration_since(now))
        })
    }

    pub(super) fn cancel(&mut self) {
        *self = Self::default();
    }

    fn expire_wake_grace(&mut self, now: Instant) {
        if self
            .wake_grace_until
            .is_some_and(|deadline| now >= deadline)
        {
            self.waking_outputs.clear();
            self.wake_grace_until = None;
            self.deferred_removal = false;
        }
    }
}

#[cfg(feature = "flutter")]
pub(super) fn synchronize_idle_dpms(scanouts: &[Scanout], events: &mut RuntimeState, now: Instant) {
    let inhibited = events
        .wayland
        .as_mut()
        .is_some_and(wayland_frontend::WaylandFrontend::idle_inhibited);
    let idle_policy::IdlePolicyActions {
        power_requests,
        lock,
        suspend,
    } = events.idle_policy.evaluate(
        now,
        inhibited,
        scanouts
            .iter()
            .map(|scanout| (scanout.output.id, scanout.powered)),
    );
    events.queue_idle_power_requests(power_requests);
    if lock {
        if let Some(authentication) = events.authentication.as_ref() {
            authentication.lock();
            info!("locked the session after inactivity");
        } else {
            warn!("could not lock the session after inactivity: authentication is unavailable");
        }
    }
    if suspend {
        if events
            .system_controls
            .as_ref()
            .is_some_and(system_controls::SystemControls::suspend)
        {
            info!("requested system suspend after inactivity");
        } else {
            warn!("could not request system suspend after inactivity");
        }
    }
}

#[cfg(feature = "flutter")]
pub(super) fn synchronize_idle_dpms_configuration(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) {
    let Some(configuration) = runtime.take_idle_policy() else {
        return;
    };
    let requests = events.idle_policy.configure(configuration, Instant::now());
    events.queue_idle_power_requests(requests);
    info!(
        lock_timeout_seconds = configuration.lock_timeout.map(|timeout| timeout.as_secs()),
        dpms_timeout_seconds = configuration.dpms_timeout.map(|timeout| timeout.as_secs()),
        suspend_timeout_seconds = configuration
            .suspend_timeout
            .map(|timeout| timeout.as_secs()),
        "configured automatic inactivity policy"
    );
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
    let requests = events.idle_policy.blank_now(
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
            events
                .idle_policy
                .note_power_failure(output, Instant::now());
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
                events
                    .idle_policy
                    .note_power_failure(output, Instant::now());
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
                events.dpms_topology.note_powered_off(output);
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
            events.dpms_topology.note_wake(output, Instant::now());
            events.topology_dirty = true;
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

#[cfg(test)]
#[path = "dpms/tests.rs"]
mod tests;
