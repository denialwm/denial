//! Bounded calloop dispatch for Flutter, Wayland, KMS, and control-plane events.

use super::kms_pipeline::{
    HotplugRequest, ResidentModeRequest, apply_hotplug_topology, apply_resident_mode_topology,
};
use super::kms_session::{
    log_shutdown, recover_stalled_kms_presentation, service_session_lifecycle,
};
use super::*;
use output_apply::output_properties_changed;
use reconfiguration::{OutputTopologyObservation, take_topology_reconfiguration_request};
use smithay::reexports::calloop::channel::{Event as ChannelEvent, channel};
use smithay::reexports::calloop::ping::make_ping;

#[path = "flutter_event_loop/frames.rs"]
mod frames;
#[path = "flutter_event_loop/output_apply.rs"]
mod output_apply;
#[path = "flutter_event_loop/reconfiguration.rs"]
mod reconfiguration;
#[path = "flutter_event_loop/screenshots.rs"]
mod screenshots;
#[path = "flutter_event_loop/services.rs"]
mod services;

const BACKGROUND_SERVICE_INTERVAL: Duration = Duration::from_nanos(1_000_000_000 / 30);
const BACKGROUND_MAINTENANCE_INTERVAL: Duration = Duration::from_millis(100);

/// Runs a background check after the loop wakes, at most once per interval.
///
/// The loop has no periodic tick: it wakes for its sources, for deadlines it
/// knows of, and for workers through `loop_wake`. Every wake may have queued
/// work for the check, so a wake that comes too soon after the last run owes
/// one more run when the interval ends.
struct Cadence {
    interval: Duration,
    next: Option<Instant>,
    owed: bool,
}

impl Cadence {
    const fn new(interval: Duration) -> Self {
        Self {
            interval,
            next: None,
            owed: false,
        }
    }

    /// Notes a loop iteration and says whether the check runs in it.
    fn turn(&mut self, now: Instant, forced: bool) -> bool {
        let due = forced || self.next.is_none_or(|next| now >= next);
        if due {
            self.next = now.checked_add(self.interval);
        }
        self.owed = !due;
        due
    }

    fn limit_dispatch_timeout(&self, now: Instant, timeout: Duration) -> Duration {
        match self.next {
            Some(next) if self.owed => timeout.min(next.saturating_duration_since(now)),
            _ => timeout,
        }
    }
}

/// Shell services, and the idle and DPMS evaluation.
struct BackgroundCadences {
    services: Cadence,
    maintenance: Cadence,
}

impl BackgroundCadences {
    const fn new() -> Self {
        Self {
            services: Cadence::new(BACKGROUND_SERVICE_INTERVAL),
            maintenance: Cadence::new(BACKGROUND_MAINTENANCE_INTERVAL),
        }
    }

    fn limit_dispatch_timeout(&self, now: Instant, timeout: Duration) -> Duration {
        let timeout = self.services.limit_dispatch_timeout(now, timeout);
        self.maintenance.limit_dispatch_timeout(now, timeout)
    }
}

fn interactive_service_work_pending(events: &RuntimeState) -> bool {
    !events.plugin_actions.pending.is_empty()
        || !events.pending_shell_actions.is_empty()
        || !events.pending_shortcut_launches.is_empty()
        || !events.window_events.pending.is_empty()
}

fn output_transaction_waiting(
    ready_output_apply: bool,
    pending_output_apply: bool,
    resident_geometry_reconfigure_requested: bool,
) -> bool {
    ready_output_apply || pending_output_apply || resident_geometry_reconfigure_requested
}

fn gamma_topology_changed<T: Copy + PartialEq>(
    known: Option<&[T]>,
    current: impl ExactSizeIterator<Item = T>,
) -> bool {
    known.is_none_or(|known| known.len() != current.len() || known.iter().copied().ne(current))
}

fn gamma_work_pending(
    topology_changed: bool,
    internal_request: bool,
    external_request: bool,
    force_reapply: bool,
) -> bool {
    topology_changed || internal_request || external_request || force_reapply
}

fn create_frame_schedulers(
    drm: &DrmDevice,
    volition_events: &output_scheduler::VolitionEvents,
    scanouts: &[Scanout],
    swapchain: &RenderSwapchains,
    flutter: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
    missing_swapchains: &'static str,
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
        flutter,
        events,
    )?;
    // Refresh this CRTC timing policy at every initial/modeset/recovery
    // scheduler boundary. Unknown CRTCs continue to reject future metadata.
    events.presentation_timings = scanouts
        .iter()
        .filter(|s| s.powered)
        .map(|s| {
            (
                s.output.crtc,
                presentation_clock::mode_timing(&s.output.mode),
            )
        })
        .collect();
    let frame_scheduler = frame_scheduler::FrameScheduler::new(scanouts, Instant::now());
    Ok((scheduler, frame_scheduler))
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
    if runtime.take_native_window_fallback() {
        events.scene_sync.mark_dirty();
    }
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
    synchronize_requested_display_power(runtime, scanouts, events);
    Ok(())
}

fn synchronize_periodic_shell_services(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    synchronize_clipboard(runtime, events)?;
    synchronize_system_control_events(runtime, events)?;
    synchronize_notification_events(runtime, events)?;
    synchronize_xembed_tray(runtime, events)?;
    synchronize_shell_keyboard(runtime, events)?;
    synchronize_settings(runtime, events)?;
    Ok(())
}

fn synchronize_flutter_scene_and_input(
    output_control: &output_control::OutputControlPublisher,
    runtime: &mut flutter_runtime::FlutterRuntime,
    background_services_due: bool,
    frame_scheduler: &mut frame_scheduler::FrameScheduler,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    if background_services_due {
        synchronize_flutter_window_management(runtime, events)?;
    }
    synchronize_flutter_scene(output_control, runtime, events)?;
    collect_flutter_output_damage(runtime, frame_scheduler);
    synchronize_flutter_input_layout(runtime, events)?;
    synchronize_wayland_cursor(runtime, events)?;
    Ok(())
}

fn output_control_publication_deferred(events: &RuntimeState) -> bool {
    events.resident_geometry_reconfigure_requested
}

fn output_control_publication_became_dirty(was_dirty: bool, is_dirty: bool) -> bool {
    !was_dirty && is_dirty
}

/// What the Flutter KMS loop works with for its whole run: the devices and
/// render state it borrows from startup, the frame schedulers, and the output
/// configuration with the requests that change it.
struct Session<'a, 'event_loop> {
    renderer: &'a mut GlesRenderer,
    drm: &'a mut DrmDevice,
    swapchain: &'a mut RenderSwapchains,
    scanouts: &'a mut Vec<Scanout>,
    restore_state: &'a mut RestoreState,
    drm_scanner: &'a mut DrmScanner<SimpleCrtcMapper>,
    allocator: &'a mut GbmAllocator<DrmDeviceFd>,
    scanout_allocator: &'a mut ScanoutAllocator,
    topology: &'a mut TopologyManager,
    event_loop: &'a mut EventLoop<'event_loop, RuntimeState>,
    flutter: &'a mut flutter_runtime::FlutterRuntime,
    flutter_launcher: &'a mut FlutterLauncher,
    events: RuntimeState,
    scheduler: output_scheduler::OutputScheduler,
    frame_scheduler: frame_scheduler::FrameScheduler,
    volition_events: output_scheduler::VolitionEvents,
    screenshot_manager: Option<screenshot::ScreenshotManager>,
    background: BackgroundCadences,
    ui_floor: cpu_scheduling::UiFloor,
    gamma_topology: Option<Vec<(OutputId, crtc::Handle)>>,
    max_outputs: usize,
    output_config: Option<PathBuf>,
    output_control: output_control::OutputControlPublisher,
    output_configuration: RuntimeOutputConfiguration,
    policy_journal: output_policy::OutputPolicyJournal,
    ready_output_apply: Option<(PendingOutputApply, Vec<ConnectedConnector>)>,
    pending_output_success: Option<PendingOutputApply>,
    pending_output_confirmation_success: VecDeque<PendingOutputConfirmation>,
    active_output_confirmation: Option<ActiveOutputConfirmation>,
    pending_sensor_rotation: OutputTransform,
    orientation_sensor: Option<orientation_sensor::OrientationSensor>,
    outputs_disconnected: bool,
    deadline: Option<Instant>,
    frame_limit: Option<u64>,
    raster_frames: u64,
    delivered_vsyncs: u64,
    /// Page flips presented by schedulers that were since replaced.
    retired_output_flips: u64,
}

impl Session<'_, '_> {
    /// Installs fresh schedulers for the current scanouts, keeping the count of
    /// page flips the old one presented.
    fn replace_frame_schedulers(
        &mut self,
        missing_swapchains: &'static str,
    ) -> Result<(), Box<dyn Error>> {
        self.retired_output_flips = self
            .retired_output_flips
            .saturating_add(self.scheduler.presented_frames());
        (self.scheduler, self.frame_scheduler) = create_frame_schedulers(
            self.drm,
            &self.volition_events,
            self.scanouts,
            self.swapchain,
            self.flutter,
            &mut self.events,
            missing_swapchains,
        )?;
        Ok(())
    }

    fn drain_frames_before_reconfiguration(&mut self) -> Result<(), Box<dyn Error>> {
        let Self {
            flutter,
            scheduler,
            swapchain,
            scanouts,
            events,
            event_loop,
            deadline,
            ..
        } = self;
        let deadline = *deadline;
        submit_ready_frames(flutter, scheduler, swapchain, scanouts, events)?;
        let now = Instant::now();
        let timeout = deadline.map_or(Duration::from_millis(50), |deadline| {
            Duration::from_millis(50).min(deadline.saturating_duration_since(now))
        });
        event_loop.dispatch(timeout, events)?;
        Ok(())
    }

    fn handle_ui_development_requests(&mut self) {
        let Self {
            scheduler,
            events,
            flutter,
            flutter_launcher,
            ..
        } = self;
        while let Some(request) = events.control.ui_development.pop_front() {
            let runtime = &mut **flutter;
            let is_query = request.command.kind() == ui_development::CommandKind::Query;
            let (reload_requested, state) =
                flutter_launcher.handle_external_ui_development(runtime, request.command.clone());
            if reload_requested {
                events.flutter_reload_requested = true;
            }
            // The plugin manager applies a rebuilt composition only while the
            // user is not in the middle of something.
            let state = state.with_session_activity(ui_development::SessionActivity {
                locked: events.secure_session_locked(),
                input_idle_ms: u64::try_from(
                    events.idle_policy.idle_for(Instant::now()).as_millis(),
                )
                .unwrap_or(u64::MAX),
                shell_captures_keyboard: events.frontend().shell_captures_keyboard(),
                idle_inhibited: events.frontend_mut().idle_inhibited(),
            });
            let state =
                state.with_native_client_composition(runtime.native_client_composition_stats());
            let state = if is_query {
                state.with_output_frame_delivery(scheduler.delivery_trace_snapshot())
            } else {
                state
            };
            if !is_query && let Some(error) = state.error_message() {
                request.reply(Err(output_control::OutputControlFailure::new(
                    "rejected", error,
                )));
            } else {
                request.reply(Ok(state));
            }
        }
    }

    /// Whether anything consumes the next output tick. Otherwise the loop sleeps
    /// through output edges instead of waking at every refresh with nothing to
    /// render or deliver.
    fn output_ticks_wanted(&self) -> bool {
        let Self {
            flutter: runtime,
            frame_scheduler,
            screenshot_manager,
            events,
            ..
        } = self;
        frame_scheduler.wants_ticks()
            || runtime.wants_output_ticks()
            || events.scene_sync.pending_metadata_revision().is_some()
            || events.scene_sync.pending_buffer_revision().is_some()
            || screenshot_manager
                .as_ref()
                .is_some_and(|manager| manager.request_id().is_some())
            || events.frontend().wants_frame_ticks()
    }

    fn next_dispatch_timeout(&self, now: Instant) -> Option<Duration> {
        let Self {
            flutter: runtime,
            frame_scheduler,
            background,
            events,
            drm,
            scheduler,
            deadline,
            ..
        } = self;
        let deadline = *deadline;
        let mut timeout =
            frame_scheduler.limit_dispatch_timeout(now, runtime.next_dispatch_timeout(now));
        timeout = background.limit_dispatch_timeout(now, timeout);
        timeout = events.idle_policy.limit_dispatch_timeout(now, timeout);
        timeout = events.dpms_topology.limit_dispatch_timeout(now, timeout);
        timeout = events.ambient_display.limit_dispatch_timeout(now, timeout);
        if let Some(expiry) = events
            .control
            .system_waits
            .iter()
            .map(PendingSystemControlWait::expires_at)
            .min()
        {
            timeout = timeout.min(expiry.saturating_duration_since(now));
        }
        // A fingerprint unlock settles on a short delay after the display wakes.
        if events.fingerprint.active()
            || events
                .authentication
                .as_ref()
                .is_some_and(|authentication| authentication.fingerprint_unlock_pending())
        {
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

    /// Runs until the session ends: a shutdown request, the shell logging
    /// out, or the finite run's deadline or frame limit.
    fn run(&mut self) -> Result<(), Box<dyn Error>> {
        loop {
            if self.service_kms_lifecycle()? {
                continue;
            }
            self.synchronize_software_dimming()?;
            self.events.frontend_mut().reap_capture_source_reads();
            let iteration_now = Instant::now();
            if self.events.dpms_topology.service_deadline(iteration_now) {
                self.events.topology_dirty = true;
                info!("DPMS wake topology grace expired; applying the observed connector state");
            }
            let flutter_background_event = self
                .events
                .flutter_events
                .iter()
                .any(flutter_runtime::RuntimeEvent::queues_background_service_work);
            let background_services_due = self.background.services.turn(
                iteration_now,
                flutter_background_event || interactive_service_work_pending(&self.events),
            );
            let background_maintenance_due = self.background.maintenance.turn(
                iteration_now,
                self.events
                    .idle_policy
                    .next_deadline()
                    .is_some_and(|deadline| iteration_now >= deadline),
            );
            self.events.frontend_mut().settings.current_sensor_rotation =
                self.output_configuration.sensor_rotation;
            if let Some(orientation) = self.events.pending_orientation.take() {
                orientation.update_rotation(&mut self.pending_sensor_rotation);
                debug!(?orientation, rotation = ?self.pending_sensor_rotation, "observed device orientation");
            }
            if self.acknowledge_render_events()? {
                continue;
            }
            self.apply_pending_sensor_orientation(iteration_now)?;
            self.synchronize_orientation_demand();
            self.apply_pending_lid_position();
            self.expire_output_confirmation(iteration_now);
            let current_output_snapshot = self.publish_output_control_updates()?;
            if let Some(reason) = self.events.lifecycle.shutdown_reason() {
                log_shutdown(reason);
                return Ok(());
            }
            if self
                .deadline
                .is_some_and(|deadline| iteration_now >= deadline)
            {
                return Ok(());
            }
            if self
                .frame_limit
                .is_some_and(|limit| self.raster_frames >= limit)
            {
                return Ok(());
            }
            if self.events.device_removed {
                return Err("the active DRM device was removed in Flutter event loop".into());
            }

            // A presenting scanout whose connector vanished has no valid target,
            // so keep its old scheduler quiescent until a fresh scan can rebuild
            // it. Blanked scanouts stay outside the scheduler while retaining
            // their trained connector and CRTC state.
            let scanout_rebased = self.events.scanout_rebased
                || (self.outputs_disconnected
                    && self.scanouts.iter().any(|scanout| scanout.powered));
            // Keep this as a level-triggered recovery latch until the topology
            // transaction installs a fresh scheduler. Consuming it here lets an
            // unrelated publication boundary skip topology repair for one
            // iteration; the stale scheduler then immediately redetects the same
            // submitted frame and can spin in KMS recovery with every CRTC off.
            if scanout_rebased {
                cancel_active_screenshot(
                    &mut self.screenshot_manager,
                    self.flutter,
                    true,
                    "scanout state changed",
                )?;
            } else {
                if self.service_page_flip_completions(iteration_now)? {
                    continue;
                }
                self.publish_completed_flutter_frames()?;

                // The output timeline is driven by its own dispatch deadline.
                // An unrelated Wayland, input, or acquire-fence wake cannot
                // produce a tick, and frame readiness remains latched until one.
                if self.frame_scheduler.output_tick_due(Instant::now()) {
                    self.schedule_next_flutter_frame()?;
                    self.dispatch_output_ticks()?;
                }
                self.freeze_prepared_screenshot_frame()?;
            }
            if let Some(error) = self.events.error.take() {
                return Err(format!("DRM event error in Flutter event loop: {error}").into());
            }

            let background_started = Instant::now();
            if self.synchronize_power_policy(
                background_services_due,
                background_maintenance_due,
                scanout_rebased,
                background_started,
            )? {
                // Publish DPMS changes at the single loop-boundary gate above
                // before processing more compositor or Flutter work.
                continue;
            }

            self.handle_ui_development_requests();

            if self.handle_output_confirmation_requests() {
                continue;
            }
            if self.acquire_pending_output_apply(scanout_rebased)? {
                continue;
            }
            if self.service_ready_output_apply(scanout_rebased, current_output_snapshot.as_ref())? {
                continue;
            }

            if let Some(request) =
                take_topology_reconfiguration_request(scanout_rebased, &mut self.events)
            {
                match self.observe_output_topology(request)? {
                    OutputTopologyObservation::Stable => {
                        // EDID may arrive late or change with no mode/CRTC change.
                        // Publish it without rebuilding KMS/Flutter scanouts.
                        let frontend = self.events.frontend_mut();
                        if frontend.output_metadata_changed() {
                            frontend.update_topology(&self.topology.snapshot())?;
                        }
                    }
                    OutputTopologyObservation::WaitingForOutputs => continue,
                    OutputTopologyObservation::Reconfigure(observed) => {
                        self.apply_observed_output_topology(request, observed)?;
                        continue;
                    }
                }
            }
            if self.events.output_control_dirty {
                continue;
            }

            if self.service_flutter_reload()? {
                continue;
            }

            // Close/focus/configure are interactive commands, not periodic service
            // work. Drain them before a spent background slice can defer them;
            // otherwise busy frames can indefinitely postpone an app's close.
            process_flutter_event_batch(self.flutter, &mut self.events)?;
            // Apply scene work-area changes before its input layout can switch
            // native presentation and restore desktop window geometry. This is
            // interactive state, so it must not wait for periodic shell services.
            synchronize_system_bar_configuration(
                self.flutter,
                &mut self.events,
                Some(&mut *self.flutter_launcher),
            );
            if dispatch_when_background_slice_expires(
                background_started,
                self.event_loop,
                &mut self.events,
            )? {
                continue;
            }
            if background_services_due {
                synchronize_periodic_power_configuration(
                    self.flutter,
                    self.flutter_launcher,
                    self.scanouts,
                    &mut self.events,
                )?;
            }
            self.cancel_invalid_screenshot_selection()?;
            if background_services_due {
                synchronize_periodic_shell_services(self.flutter, &mut self.events)?;
            }
            if dispatch_when_background_slice_expires(
                background_started,
                self.event_loop,
                &mut self.events,
            )? {
                continue;
            }
            synchronize_flutter_scene_and_input(
                &self.output_control,
                self.flutter,
                background_services_due,
                &mut self.frame_scheduler,
                &mut self.events,
            )?;
            if dispatch_when_background_slice_expires(
                background_started,
                self.event_loop,
                &mut self.events,
            )? {
                continue;
            }
            let screenshot_prepared = self.flutter.take_screenshot_prepared();
            let screenshot_cancelled = self.flutter.take_screenshot_cancelled();
            let screenshot_request = self.flutter.take_screenshot_requested().or_else(|| {
                std::mem::take(&mut self.events.screenshot_requested).then_some(
                    flutter_runtime::system_command::ScreenshotRequest {
                        request_id: None,
                        region: None,
                    },
                )
            });
            if self.flutter.take_logout_requested() {
                info!("Flutter requested session logout");
                return Ok(());
            }
            if self.events.flutter_channel_closed {
                return Err("Flutter callback channel closed while the engine was running".into());
            }
            let frontend = self.events.frontend_mut();
            frontend.process_pending_dmabufs(self.renderer)?;
            frontend.process_toplevel_screencopies(self.renderer)?;

            if self.begin_pending_screenshot_selection()?
                || self.handle_prepared_screenshot(screenshot_prepared)?
            {
                continue;
            }
            self.handle_cancelled_screenshot(screenshot_cancelled)?;
            self.handle_screenshot_request(screenshot_request)?;

            let frames_wanted = self.output_ticks_wanted();
            self.frame_scheduler.idle_ticks(!frames_wanted);
            let now = Instant::now();
            // Frame requests stay pending while every display is powered off, but
            // nothing can present then, so they do not hold the UI floor raised.
            self.ui_floor.update(
                frames_wanted && self.scanouts.iter().any(|scanout| scanout.powered),
                now,
            );
            let Some(dispatch_timeout) = self.next_dispatch_timeout(now) else {
                return Ok(());
            };
            let mut dispatch_timeout = self.ui_floor.limit_dispatch_timeout(now, dispatch_timeout);
            // An unconfirmed output configuration rolls back at its deadline even
            // if nothing else happens.
            for deadline in self
                .active_output_confirmation
                .as_ref()
                .map(|confirmation| confirmation.deadline)
                .into_iter()
                .chain(self.flutter_launcher.ui_development_deadline(now))
            {
                dispatch_timeout = dispatch_timeout.min(deadline.saturating_duration_since(now));
            }
            self.event_loop
                .dispatch(dispatch_timeout, &mut self.events)?;
            self.frame_scheduler.resume_ticks(Instant::now());
        }
    }

    fn shutdown(&mut self, restore_framebuffer: bool) -> Result<(), Box<dyn Error>> {
        cancel_active_screenshot(
            &mut self.screenshot_manager,
            self.flutter,
            false,
            "compositor is shutting down",
        )?;
        if self.drm.is_active() {
            let failures = self
                .events
                .gamma_control
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .restore_all(self.drm);
            for error in failures {
                warn!(%error, "could not restore DRM gamma state during shutdown");
            }
        }
        self.quiesce_flutter_page_flips(restore_framebuffer);
        self.scheduler.shutdown_volition();
        self.flutter
            .shutdown()
            .map_err(|error| format!("Flutter engine shutdown failed: {error}"))?;
        Ok(())
    }

    /// Drains submitted page flips before teardown, then hands DRM master
    /// back when `release_drm_master` asks for it.
    fn quiesce_flutter_page_flips(&mut self, release_drm_master: bool) {
        let Self {
            flutter: runtime,
            scheduler,
            drm,
            swapchain,
            scanouts,
            event_loop,
            events,
            ..
        } = self;
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
            if let Err(error) = service_session_lifecycle(
                drm,
                scanouts,
                &**swapchain,
                event_loop,
                events,
                Some(deadline),
            ) {
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
            if let Err(error) = scheduler.retire_completions_for_shutdown(
                runtime,
                output_swapchains,
                scanouts,
                events,
            ) {
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
    pub(super) output_policy_journal: output_policy::OutputPolicyJournal,
    pub(super) output_config: Option<PathBuf>,
    pub(super) output_control: output_control::OutputControlPublisher,
    pub(super) portal_ipc: Option<portal_ipc::PortalIpcPublisher>,
    pub(super) wayland: wayland_frontend::WaylandFrontend,
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
        output_configuration,
        output_policy_journal: policy_journal,
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
    let started = Instant::now();
    let deadline = duration
        .map(|duration| {
            started
                .checked_add(duration)
                .ok_or("Flutter session duration exceeds the monotonic clock range")
        })
        .transpose()?;
    let system_controls = Some(SystemControls::new()?);
    let notification_server = services::start_notification_server(event_loop)?;
    // The startup boundary owns the runtime; it stays alive for the whole
    // loop. A replacement that cannot start, nor restart the old shell,
    // shuts it down and ends the loop.
    let flutter = flutter
        .as_mut()
        .ok_or("Flutter runtime was not initialized")?;
    let initial_runtime = &*flutter;
    let authentication = Some(initial_runtime.authentication());
    let clipboard = initial_runtime.clipboard();
    let native_escape_shortcut = wayland.shortcuts.engine();
    let settings_path = wayland.settings.path().to_path_buf();
    let initial_theme_snapshot = portal_ipc.as_ref().map(|publisher| publisher.snapshot());
    let initial_settings_document_revision = output_control.settings_document_revision();
    let mut events = RuntimeState {
        wayland: Some(wayland),
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
    synchronize_fingerprint_unlock(&events);
    if let Err(error) = settings_watch::install(&event_loop.handle(), &settings_path) {
        warn!(%error, path = %settings_path.display(), "could not watch Denial settings for external edits");
    }
    let orientation_sensor = services::start_orientation_sensor(event_loop)?;
    events.text_prediction = services::start_text_prediction(event_loop)?;
    let (volition_wake, volition_wake_source) = make_ping()?;
    // Queued Volition records are acknowledged at the top of each iteration.
    event_loop
        .handle()
        .insert_source(volition_wake_source, |(), _, _: &mut RuntimeState| {})?;
    let volition_events = output_scheduler::VolitionEvents::new(volition_wake);
    let (loop_wake, loop_wake_source) = make_ping()?;
    // Workers publish shared state and then ping; the next iteration reads it.
    event_loop
        .handle()
        .insert_source(loop_wake_source, |(), _, _: &mut RuntimeState| {})?;
    crate::loop_wake::install(loop_wake);
    let (lid_readings, lid_reading_source) = channel();
    event_loop.handle().insert_source(
        lid_reading_source,
        |event, _, state: &mut RuntimeState| {
            if let ChannelEvent::Msg(reading) = event {
                state.lid.note_reading(reading);
            }
        },
    )?;
    events.lid = lid_switch::LidSwitch::new(lid_readings);
    events.synchronize_flutter_pointer_position();
    let (scheduler, frame_scheduler) = create_frame_schedulers(
        drm,
        &volition_events,
        scanouts,
        swapchain,
        flutter,
        &mut events,
        "output scheduler has no physical output pools",
    )?;
    flutter.set_outputs_visible(scanouts.iter().any(|scanout| scanout.powered))?;
    let screenshot_manager = match screenshot::ScreenshotManager::new(events.clipboard.clone()) {
        Ok(manager) => Some(manager),
        Err(error) => {
            warn!(%error, "screenshot writer is unavailable");
            None
        }
    };
    let pending_sensor_rotation = output_configuration.sensor_rotation;
    let background = BackgroundCadences::new();
    let ui_floor = cpu_scheduling::UiFloor::new(Instant::now());

    // Any native helper inadvertently created by an elevated Flutter thread
    // is normalized before the compositor itself becomes realtime.
    cpu_scheduling::contain_unregistered_priority_threads();
    cpu_scheduling::promote_compositor_thread();

    let mut session = Session {
        renderer,
        drm,
        swapchain,
        scanouts,
        restore_state,
        drm_scanner,
        allocator,
        scanout_allocator,
        topology,
        event_loop,
        flutter,
        flutter_launcher,
        events,
        scheduler,
        frame_scheduler,
        volition_events,
        screenshot_manager,
        background,
        ui_floor,
        gamma_topology: None,
        max_outputs,
        output_config,
        output_control,
        output_configuration,
        policy_journal,
        ready_output_apply: None,
        pending_output_success: None,
        pending_output_confirmation_success: VecDeque::new(),
        active_output_confirmation: None,
        pending_sensor_rotation,
        orientation_sensor,
        outputs_disconnected: false,
        deadline,
        frame_limit,
        raster_frames: 0,
        delivered_vsyncs: 0,
        retired_output_flips: 0,
    };
    session.run()?;
    // A real login session hands KMS ownership back to its display manager.
    // Restoring the framebuffer captured before Denial started is both
    // unnecessary and dangerous here: an atomic commit can wait forever on a
    // fence owned by the compositor which is currently tearing down. Finite
    // KMS tests still restore their captured state after a successful drain.
    session.shutdown(duration.is_none())?;

    let elapsed = started.elapsed();
    let output_page_flips = session
        .retired_output_flips
        .saturating_add(session.scheduler.presented_frames());
    info!(
        raster_frames = session.raster_frames,
        output_page_flips,
        delivered_vsyncs = session.delivered_vsyncs,
        elapsed_ms = elapsed.as_secs_f64() * 1_000.0,
        raster_frames_per_second = session.raster_frames as f64 / elapsed.as_secs_f64(),
        finite = duration.is_some(),
        "independently clocked Flutter KMS session complete"
    );
    Ok(session.swapchain.representative_framebuffer())
}

#[cfg(test)]
mod tests {
    use super::{
        RuntimeState, gamma_topology_changed, gamma_work_pending,
        output_control_publication_became_dirty, output_control_publication_deferred,
        output_transaction_waiting,
    };

    #[test]
    fn gamma_gate_runs_at_initialization_and_only_for_new_work() {
        assert!(gamma_topology_changed::<u8>(None, [].into_iter()));
        assert!(!gamma_topology_changed(Some(&[1, 2]), [1, 2].into_iter()));
        assert!(gamma_topology_changed(Some(&[1, 2]), [2, 1].into_iter()));
        assert!(gamma_topology_changed(Some(&[1, 2]), [1, 3].into_iter()));
        assert!(!gamma_work_pending(false, false, false, false));
        assert!(gamma_work_pending(false, true, false, false));
        assert!(gamma_work_pending(false, false, true, false));
        assert!(gamma_work_pending(false, false, false, true));
        assert!(gamma_work_pending(true, false, false, false));
    }

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
