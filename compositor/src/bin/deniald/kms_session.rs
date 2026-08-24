//! KMS activation, pause/resume recovery, shutdown, and finite scanout holds.

use super::*;

pub(super) trait ScanoutFramebufferSource {
    fn plane_state(&self, scanout: &Scanout) -> Result<PlaneState<'static>, Box<dyn Error>>;
}

impl ScanoutFramebufferSource for framebuffer::Handle {
    fn plane_state(&self, scanout: &Scanout) -> Result<PlaneState<'static>, Box<dyn Error>> {
        Ok(plane_state(scanout, *self))
    }
}

impl ScanoutFramebufferSource for RenderSwapchains {
    fn plane_state(&self, scanout: &Scanout) -> Result<PlaneState<'static>, Box<dyn Error>> {
        current_scanout_state(scanout, self).map(|(_, state)| state)
    }
}

pub(super) fn service_session_lifecycle(
    drm: &mut DrmDevice,
    scanouts: &[Scanout],
    framebuffers: &dyn ScanoutFramebufferSource,
    event_loop: &mut EventLoop<'_, RuntimeState>,
    events: &mut RuntimeState,
    inactive_deadline: Option<Instant>,
) -> Result<(), Box<dyn Error>> {
    loop {
        if events.lifecycle.take_pause_pending() {
            if drm.is_active() {
                drm.pause();
            }
            // A page-flip event queued before libseat revoked the fd is not
            // guaranteed to arrive. The resume commit below establishes a new
            // known scanout state synchronously.
            events.pending.clear();
            events.completed_page_flips.clear();
            if let Some(error) = events.error.take() {
                warn!(error, "discarding DRM event error from the paused session");
            }
            info!("libseat paused the KMS session");
        }

        if events.lifecycle.shutdown_reason().is_some()
            || events.lifecycle.seat_active()
            || events.device_removed
        {
            break;
        }

        // libseat activation, device removal, or a termination signal wakes
        // calloop. Finite callers also wake at their own wall-clock deadline.
        match inactive_dispatch(Instant::now(), inactive_deadline) {
            InactiveDispatch::DeadlineReached => break,
            InactiveDispatch::Wait(timeout) => event_loop.dispatch(timeout, events)?,
        }
    }

    if events.device_removed {
        return Err("the active DRM device was removed while the session was paused".into());
    }
    if events.lifecycle.shutdown_reason().is_some() || !events.lifecycle.seat_active() {
        return Ok(());
    }
    if drm.is_active() {
        return Ok(());
    }

    drm.activate(false)?;
    rebase_kms_scanouts(
        drm,
        scanouts,
        framebuffers,
        events,
        "libseat reactivated the KMS session",
    )
}

/// Establishes a synchronous scanout baseline after the DRM event stream can
/// no longer be trusted. The Flutter scheduler owns page-flip generations, so
/// it must be rebuilt after this operation.
pub(super) fn rebase_kms_scanouts(
    drm: &mut DrmDevice,
    scanouts: &[Scanout],
    framebuffers: &dyn ScanoutFramebufferSource,
    events: &mut RuntimeState,
    reason: &'static str,
) -> Result<(), Box<dyn Error>> {
    if !drm.is_active() {
        return Err("cannot rebase scanouts while the DRM device is inactive".into());
    }
    for scanout in scanouts.iter().filter(|scanout| scanout.powered) {
        scanout
            .surface
            .test_state([framebuffers.plane_state(scanout)?], true)?;
    }
    for scanout in scanouts.iter().filter(|scanout| scanout.powered) {
        // Atomic modeset commits are synchronous here. Do not request a
        // vblank event: it would be indistinguishable from the next real
        // page-flip event after `pending` is repopulated and could make that
        // later frame appear complete before KMS actually scans it out.
        scanout
            .surface
            .commit([framebuffers.plane_state(scanout)?], false)?;
    }
    events.pending.clear();
    events.completed_page_flips.clear();
    // Every CRTC now scans the framebuffer supplied by the caller. The
    // independently clocked Flutter scheduler must be recreated before it
    // interprets any later page-flip event using its pre-pause ownership.
    events.scanout_rebased = true;
    events.topology_dirty = true;
    info!(
        outputs = scanouts.iter().filter(|scanout| scanout.powered).count(),
        %reason,
        "rebased KMS scanouts"
    );
    Ok(())
}

#[cfg(feature = "flutter")]
pub(super) fn recover_stalled_kms_presentation(
    drm: &mut DrmDevice,
    event_loop: &mut EventLoop<'_, RuntimeState>,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    loop {
        if events.lifecycle.shutdown_reason().is_some() {
            return Ok(());
        }
        if events.device_removed {
            return Err("the active DRM device was removed during presentation recovery".into());
        }

        if events.lifecycle.take_pause_pending() {
            if drm.is_active() {
                drm.pause();
            }
            events.pending.clear();
            events.completed_page_flips.clear();
        }

        let recovery = if !events.lifecycle.seat_active() {
            Err("the libseat session is inactive".into())
        } else {
            (|| -> Result<(), Box<dyn Error>> {
                if drm.is_active() {
                    drm.pause();
                }
                // Reset every connector, CRTC, and plane in one synchronous
                // atomic transaction. Re-committing the old per-output state
                // here can wait forever after a connector or device reset,
                // which is precisely the failure this path must recover from.
                // The normal topology transaction will rescan and enable only
                // hardware which is actually connected.
                drm.activate(true)?;
                events.pending.clear();
                events.completed_page_flips.clear();
                events.scanout_rebased = true;
                events.topology_dirty = true;
                info!("reset KMS state after a recoverable presentation failure");
                Ok(())
            })()
        };
        match recovery {
            Ok(()) => return Ok(()),
            Err(error) => {
                // A connector can remain transient for several seconds after
                // its USB hub and display link start waking.  Recovery failure
                // is therefore backpressure, not a session-ending error. Keep
                // resetting the device atomically until the hardware accepts
                // a synchronous all-disabled baseline.
                warn!(
                    %error,
                    retry_ms = KMS_PRESENTATION_RECOVERY_RETRY.as_millis(),
                    "KMS presentation recovery is waiting for the display hardware"
                );
                if let Some(event_error) = events.error.take() {
                    warn!(
                        error = event_error,
                        "discarding DRM event error during presentation recovery"
                    );
                }
                events.pending.clear();
                events.completed_page_flips.clear();
                event_loop.dispatch(KMS_PRESENTATION_RECOVERY_RETRY, events)?;
            }
        }
    }
}

pub(super) fn log_shutdown(reason: ShutdownReason) {
    info!(
        reason = reason.description(),
        "graceful compositor shutdown requested"
    );
}

pub(super) fn hold_static_scanout(
    drm: &mut DrmDevice,
    scanouts: &[Scanout],
    framebuffer: framebuffer::Handle,
    duration: Duration,
    event_loop: &mut EventLoop<'_, RuntimeState>,
) -> Result<framebuffer::Handle, Box<dyn Error>> {
    let deadline = Instant::now()
        .checked_add(duration)
        .ok_or("KMS hold duration exceeds the monotonic clock range")?;
    let mut events = RuntimeState::default();

    loop {
        service_session_lifecycle(
            drm,
            scanouts,
            &framebuffer,
            event_loop,
            &mut events,
            Some(deadline),
        )?;
        if let Some(reason) = events.lifecycle.shutdown_reason() {
            log_shutdown(reason);
            break;
        }
        if events.device_removed {
            return Err("the active DRM device was removed during the KMS hold".into());
        }

        let now = Instant::now();
        if now >= deadline {
            break;
        }
        event_loop.dispatch(deadline.saturating_duration_since(now), &mut events)?;
    }

    Ok(framebuffer)
}
