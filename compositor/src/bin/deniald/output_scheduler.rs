use std::collections::VecDeque;
use std::error::Error;
use std::os::fd::{AsFd, OwnedFd};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use denial_core::topology::OutputId;
use denial_core::volition::{self, CommitId, PlaneCommit, PlaneProperties, Submission, Volition};
use smithay::backend::drm::DrmDevice;
use smithay::backend::renderer::gles::GlesRenderer;
use smithay::output::Mode as OutputMode;
use smithay::reexports::calloop::channel::SyncSender as EventSender;
use tracing::info;

use super::flutter_runtime::{FlutterRuntime, ReadyFrame};
use super::frame_scheduler::FrameTick;
use super::kms_state::{AtlasSwapchain, Scanout};
use super::{PresentedOutput, RuntimeState, cpu_scheduling, render_audit_enabled};

const OUTPUT_SCHEDULER_AUDIT_INTERVAL: Duration = Duration::from_secs(1);
const VOLITION_SUBMIT_LEAD: Duration = Duration::from_micros(400);
/// A nonblocking atomic commit should retire on the next display edge.  Give
/// slow modesets and scheduler jitter ample room, but never retain a wedged
/// KMS/GPU generation indefinitely.
const PRESENTATION_STALL_TIMEOUT: Duration = Duration::from_secs(2);
static NEXT_READY_FENCE_TOKEN: AtomicU64 = AtomicU64::new(1);

fn next_ready_fence_token() -> u64 {
    loop {
        let token = NEXT_READY_FENCE_TOKEN.fetch_add(1, Ordering::Relaxed);
        if token != 0 {
            return token;
        }
    }
}

#[derive(Debug)]
struct OutputFrame {
    index: usize,
    screenshot_request_id: Option<u64>,
    submitted_at: Instant,
}

#[derive(Debug)]
struct LookaheadFrame {
    commit: CommitId,
    frame: OutputFrame,
}

#[derive(Clone, Copy, Debug)]
pub(super) struct PresentationStall {
    pub(super) scanout_index: usize,
    pub(super) framebuffer_index: usize,
    pub(super) pending_frames: usize,
    pub(super) elapsed: Duration,
}

fn presentation_stall_age(submitted_at: Instant, now: Instant) -> Option<Duration> {
    let elapsed = now.saturating_duration_since(submitted_at);
    (elapsed >= PRESENTATION_STALL_TIMEOUT).then_some(elapsed)
}

fn presentation_watchdog_remaining(submitted_at: Instant, now: Instant) -> Duration {
    PRESENTATION_STALL_TIMEOUT.saturating_sub(now.saturating_duration_since(submitted_at))
}

#[derive(Debug, Default)]
struct ReadyFenceSlot {
    fence: Option<OwnedFd>,
    users: usize,
    token: u64,
    signaled: bool,
    discard_users_on_signal: usize,
}

impl ReadyFenceSlot {
    fn is_available(&self) -> bool {
        self.users == 0
            && self.fence.is_none()
            && self.token == 0
            && !self.signaled
            && self.discard_users_on_signal == 0
    }

    fn claim(
        &mut self,
        fence: Option<OwnedFd>,
        users: usize,
        token: u64,
    ) -> Result<(), &'static str> {
        if users == 0 || token == 0 || !self.is_available() {
            return Err("Flutter fence slot is already claimed or has no users");
        }
        self.signaled = fence.is_none();
        self.fence = fence;
        self.users = users;
        self.token = token;
        Ok(())
    }

    fn mark_signaled(&mut self, token: u64) -> bool {
        if token == 0 || token != self.token || self.users == 0 {
            return false;
        }
        self.signaled = true;
        true
    }

    fn can_submit_immediately(&self) -> bool {
        self.users > 0
    }

    fn discard_user_when_signaled(&mut self) -> Result<(), &'static str> {
        if self.signaled || self.discard_users_on_signal >= self.users {
            return Err("Flutter fence discard does not reference a pending GPU user");
        }
        self.discard_users_on_signal += 1;
        Ok(())
    }

    fn release_user(&mut self) -> Result<(), &'static str> {
        self.users = self
            .users
            .checked_sub(1)
            .ok_or("Flutter frame has no pending fence user")?;
        if self.users == 0 {
            self.fence = None;
            self.token = 0;
            self.signaled = false;
            self.discard_users_on_signal = 0;
        }
        Ok(())
    }
}

fn discard_ready_frame(
    runtime: &FlutterRuntime,
    ready_fences: &mut [ReadyFenceSlot],
    frame: OutputFrame,
) -> Result<(), Box<dyn Error>> {
    let slot = ready_fences
        .get_mut(frame.index)
        .ok_or("discarded Flutter frame exceeds the fence pool")?;
    if slot.signaled {
        runtime.release_output(frame.index)?;
        slot.release_user()?;
    } else {
        // The output no longer needs this generation, but Flutter must not
        // render into its storage until the GPU has finished producing it.
        slot.discard_user_when_signaled()?;
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct ReadyFenceSignal {
    index: usize,
    token: u64,
}

#[derive(Debug)]
pub(super) struct ReadyFenceWatch {
    fence: OwnedFd,
    signal: ReadyFenceSignal,
}

#[derive(Debug, Default)]
pub(super) struct ReadySubmission {
    pub(super) submitted: usize,
}

impl ReadyFenceWatch {
    pub(super) fn into_parts(self) -> (OwnedFd, ReadyFenceSignal) {
        (self.fence, self.signal)
    }
}

fn plane_commit(scanout: &Scanout) -> PlaneCommit {
    let properties = scanout.plane_properties;
    PlaneCommit::new(
        scanout.surface.plane(),
        PlaneProperties {
            framebuffer: properties.framebuffer,
            source_x: properties.source_x,
            source_y: properties.source_y,
            source_width: properties.source_width,
            source_height: properties.source_height,
            in_fence_fd: properties.in_fence_fd,
        },
        scanout.source_rect,
    )
}

fn refresh_interval(scanout: &Scanout) -> Duration {
    let refresh_millihz = u64::try_from(OutputMode::from(scanout.output.mode).refresh)
        .ok()
        .filter(|refresh| *refresh > 0)
        .unwrap_or(60_000);
    Duration::from_nanos(1_000_000_000_000 / refresh_millihz)
}

#[derive(Debug)]
struct OutputPipeline {
    scanout_index: usize,
    scanning: usize,
    scanning_screenshot_request_id: Option<u64>,
    ready: Option<OutputFrame>,
    submitted: VecDeque<OutputFrame>,
    lookahead_pending: Option<LookaheadFrame>,
    powering_off: bool,
    request: PlaneCommit,
    refresh_interval: Duration,
    next_presentation_at: Instant,
}

#[derive(Debug)]
struct OutputSchedulerAudit {
    interval_started: Instant,
    ready_tokens: Vec<u64>,
    ready_published_at: Vec<Option<Instant>>,
    fence_signaled_at: Vec<Option<Instant>>,
    last_sequences: Vec<Option<u32>>,
    last_presented_at: Vec<Option<Instant>>,
    submitted_at: Vec<VecDeque<Instant>>,
    ready_published: u64,
    ready_with_fence: u64,
    fence_signals: u64,
    real_submissions: u64,
    volition_lookahead_submissions: u64,
    presentations: u64,
    sequence_samples: u64,
    sequence_delta_total: u64,
    sequence_delta_max: u32,
    missed_vblanks: u64,
    ready_to_fence: AuditLatency,
    fence_to_submit: AuditLatency,
    ready_to_submit: AuditLatency,
    render_to_publish: AuditLatency,
    presentation_delivery: AuditLatency,
    presentation_to_submit: AuditLatency,
    submit_to_presentation: AuditLatency,
}

#[derive(Debug, Default)]
struct AuditLatency {
    samples: u64,
    total: Duration,
    max: Duration,
}

impl AuditLatency {
    fn record(&mut self, duration: Duration) {
        self.samples = self.samples.saturating_add(1);
        self.total = self.total.saturating_add(duration);
        self.max = self.max.max(duration);
    }

    fn average_us(&self) -> f64 {
        if self.samples == 0 {
            return 0.0;
        }
        self.total.as_secs_f64() * 1_000_000.0 / self.samples as f64
    }
}

impl OutputSchedulerAudit {
    fn new(buffer_count: usize, output_count: usize) -> Self {
        Self {
            interval_started: Instant::now(),
            ready_tokens: vec![0; buffer_count],
            ready_published_at: vec![None; buffer_count],
            fence_signaled_at: vec![None; buffer_count],
            last_sequences: vec![None; output_count],
            last_presented_at: vec![None; output_count],
            submitted_at: std::iter::repeat_with(VecDeque::new)
                .take(output_count)
                .collect(),
            ready_published: 0,
            ready_with_fence: 0,
            fence_signals: 0,
            real_submissions: 0,
            volition_lookahead_submissions: 0,
            presentations: 0,
            sequence_samples: 0,
            sequence_delta_total: 0,
            sequence_delta_max: 0,
            missed_vblanks: 0,
            ready_to_fence: AuditLatency::default(),
            fence_to_submit: AuditLatency::default(),
            ready_to_submit: AuditLatency::default(),
            render_to_publish: AuditLatency::default(),
            presentation_delivery: AuditLatency::default(),
            presentation_to_submit: AuditLatency::default(),
            submit_to_presentation: AuditLatency::default(),
        }
    }

    fn record_ready(
        &mut self,
        index: usize,
        token: u64,
        has_fence: bool,
        rendered_at: Option<Instant>,
    ) {
        self.maybe_report();
        self.ready_published = self.ready_published.saturating_add(1);
        if has_fence {
            self.ready_with_fence = self.ready_with_fence.saturating_add(1);
        }
        let now = Instant::now();
        if let Some(rendered_at) = rendered_at {
            self.render_to_publish
                .record(now.saturating_duration_since(rendered_at));
        }
        if let Some(published_at) = self.ready_published_at.get_mut(index) {
            *published_at = Some(now);
        }
        if let Some(ready_token) = self.ready_tokens.get_mut(index) {
            *ready_token = token;
        }
        if let Some(signaled_at) = self.fence_signaled_at.get_mut(index) {
            *signaled_at = (!has_fence).then_some(now);
        }
    }

    fn record_fence_signal(&mut self, index: usize, token: u64) {
        if self.ready_tokens.get(index).copied() != Some(token)
            || self
                .fence_signaled_at
                .get(index)
                .is_none_or(Option::is_some)
        {
            return;
        }
        self.maybe_report();
        self.fence_signals = self.fence_signals.saturating_add(1);
        let now = Instant::now();
        if let Some(Some(published_at)) = self.ready_published_at.get(index) {
            self.ready_to_fence
                .record(now.duration_since(*published_at));
        }
        if let Some(signaled_at) = self.fence_signaled_at.get_mut(index) {
            *signaled_at = Some(now);
        }
    }

    fn record_real_submission(
        &mut self,
        output_index: usize,
        buffer_index: usize,
        volition_lookahead: bool,
    ) {
        self.maybe_report();
        self.real_submissions = self.real_submissions.saturating_add(1);
        if volition_lookahead {
            self.volition_lookahead_submissions =
                self.volition_lookahead_submissions.saturating_add(1);
        }
        let now = Instant::now();
        if let Some(Some(presented_at)) = self.last_presented_at.get(output_index) {
            self.presentation_to_submit
                .record(now.saturating_duration_since(*presented_at));
        }
        if let Some(submitted_at) = self.submitted_at.get_mut(output_index) {
            submitted_at.push_back(now);
        }
        if let Some(published_at) = self
            .ready_published_at
            .get(buffer_index)
            .and_then(|published_at| *published_at)
        {
            self.ready_to_submit
                .record(now.duration_since(published_at));
        }
        if let Some(signaled_at) = self
            .fence_signaled_at
            .get(buffer_index)
            .and_then(|signaled_at| *signaled_at)
        {
            self.fence_to_submit.record(now.duration_since(signaled_at));
        }
    }

    fn record_presentation(
        &mut self,
        output_index: usize,
        observed_at: Instant,
        sequence: Option<u64>,
    ) {
        self.maybe_report();
        self.presentations = self.presentations.saturating_add(1);
        let delivered_at = Instant::now();
        self.presentation_delivery
            .record(delivered_at.saturating_duration_since(observed_at));
        if let Some(submitted_at) = self
            .submitted_at
            .get_mut(output_index)
            .and_then(VecDeque::pop_front)
        {
            self.submit_to_presentation
                .record(observed_at.saturating_duration_since(submitted_at));
        }
        if let Some(presented_at) = self.last_presented_at.get_mut(output_index) {
            *presented_at = Some(observed_at);
        }
        let Some(sequence) = sequence.map(|sequence| sequence as u32) else {
            return;
        };
        let Some(last_sequence) = self.last_sequences.get_mut(output_index) else {
            return;
        };
        if let Some(previous) = *last_sequence {
            let delta = sequence.wrapping_sub(previous);
            self.sequence_samples = self.sequence_samples.saturating_add(1);
            self.sequence_delta_total = self.sequence_delta_total.saturating_add(u64::from(delta));
            self.sequence_delta_max = self.sequence_delta_max.max(delta);
            self.missed_vblanks = self
                .missed_vblanks
                .saturating_add(u64::from(delta.saturating_sub(1)));
        }
        *last_sequence = Some(sequence);
    }

    fn maybe_report(&mut self) {
        let elapsed = self.interval_started.elapsed();
        if elapsed < OUTPUT_SCHEDULER_AUDIT_INTERVAL {
            return;
        }

        info!(
            target: "deniald::render_audit",
            source = "output_scheduler",
            interval_ms = elapsed.as_secs_f64() * 1_000.0,
            ready_published = self.ready_published,
            ready_with_fence = self.ready_with_fence,
            fence_signals = self.fence_signals,
            real_submissions = self.real_submissions,
            volition_lookahead_submissions = self.volition_lookahead_submissions,
            presentations = self.presentations,
            sequence_samples = self.sequence_samples,
            sequence_delta_avg = if self.sequence_samples == 0 {
                0.0
            } else {
                self.sequence_delta_total as f64 / self.sequence_samples as f64
            },
            sequence_delta_max = self.sequence_delta_max,
            missed_vblanks = self.missed_vblanks,
            ready_to_fence_avg_us = self.ready_to_fence.average_us(),
            ready_to_fence_max_us = self.ready_to_fence.max.as_secs_f64() * 1_000_000.0,
            fence_to_submit_avg_us = self.fence_to_submit.average_us(),
            fence_to_submit_max_us = self.fence_to_submit.max.as_secs_f64() * 1_000_000.0,
            ready_to_submit_avg_us = self.ready_to_submit.average_us(),
            ready_to_submit_max_us = self.ready_to_submit.max.as_secs_f64() * 1_000_000.0,
            render_to_publish_avg_us = self.render_to_publish.average_us(),
            render_to_publish_max_us = self.render_to_publish.max.as_secs_f64() * 1_000_000.0,
            presentation_delivery_avg_us = self.presentation_delivery.average_us(),
            presentation_delivery_max_us = self.presentation_delivery.max.as_secs_f64() * 1_000_000.0,
            presentation_to_submit_avg_us = self.presentation_to_submit.average_us(),
            presentation_to_submit_max_us = self.presentation_to_submit.max.as_secs_f64() * 1_000_000.0,
            submit_to_presentation_avg_us = self.submit_to_presentation.average_us(),
            submit_to_presentation_max_us = self.submit_to_presentation.max.as_secs_f64() * 1_000_000.0,
            "Denial/Volition output scheduler audit"
        );

        self.interval_started = Instant::now();
        self.ready_published = 0;
        self.ready_with_fence = 0;
        self.fence_signals = 0;
        self.real_submissions = 0;
        self.volition_lookahead_submissions = 0;
        self.presentations = 0;
        self.sequence_samples = 0;
        self.sequence_delta_total = 0;
        self.sequence_delta_max = 0;
        self.missed_vblanks = 0;
        self.ready_to_fence = AuditLatency::default();
        self.fence_to_submit = AuditLatency::default();
        self.ready_to_submit = AuditLatency::default();
        self.render_to_publish = AuditLatency::default();
        self.presentation_delivery = AuditLatency::default();
        self.presentation_to_submit = AuditLatency::default();
        self.submit_to_presentation = AuditLatency::default();
    }
}

pub(super) struct OutputScheduler {
    volition: Volition,
    pipelines: Vec<OutputPipeline>,
    /// Reused damage fan-out scratch. Flutter can raster faster than the
    /// slowest CRTC, so allocating this list for every ready atlas would put
    /// allocator traffic directly in the frame handoff path.
    affected_pipelines: Vec<usize>,
    /// Outputs whose KMS commit succeeded in the current submit pass. Keeping
    /// this allocation lets the Wayland frontend route every window once and
    /// flush clients once, even when one atlas frame touches several CRTCs.
    submitted_outputs: Vec<OutputId>,
    /// Page flips retired by one calloop dispatch, published to Wayland as one
    /// batch so Space refresh and socket flushing do not scale with outputs.
    presented_outputs: Vec<PresentedOutput>,
    /// One Flutter render fence per atlas slot. Pipelines borrow the fd only
    /// for their synchronous atomic ioctl; no Arc allocation or refcount is
    /// needed to fan a frame out across independently clocked outputs.
    ready_fences: Vec<ReadyFenceSlot>,
    audit: Option<OutputSchedulerAudit>,
    /// Buffer ownership retained while every physical output is DPMS-off.
    /// Flutter's independent-scanout broker requires one initial owner, and
    /// parking it also gives the first waking output a truthful framebuffer.
    parked: Option<usize>,
    latest_index: usize,
    presented_frames: u64,
}

impl OutputScheduler {
    pub(super) fn new(
        drm: &DrmDevice,
        volition_events: EventSender<volition::Event>,
        scanouts: &[Scanout],
        initial_index: usize,
        buffer_count: usize,
        runtime: &mut FlutterRuntime,
        events: &mut RuntimeState,
    ) -> Result<Self, Box<dyn Error>> {
        if initial_index >= buffer_count {
            return Err("initial atlas index exceeds the scheduler buffer pool".into());
        }
        let powered_outputs = scanouts.iter().filter(|scanout| scanout.powered).count();
        let broker_index = runtime.enable_independent_scanout(powered_outputs.max(1))?;
        if broker_index != initial_index {
            return Err("Flutter and KMS disagree about the initial atlas buffer".into());
        }
        runtime.set_outputs_visible(powered_outputs > 0)?;
        let presentation = Volition::new(
            drm.as_fd(),
            scanouts.len().max(1),
            cpu_scheduling::promote_volition_thread,
            move |event| {
                let _ = volition_events.send(event);
            },
        )?;
        let pipelines = scanouts
            .iter()
            .enumerate()
            .filter(|(_, scanout)| scanout.powered)
            .map(|(scanout_index, scanout)| {
                let refresh_interval = refresh_interval(scanout);
                Ok(OutputPipeline {
                    scanout_index,
                    scanning: initial_index,
                    scanning_screenshot_request_id: None,
                    ready: None,
                    submitted: VecDeque::with_capacity(volition::MAX_IN_FLIGHT_COMMITS_PER_STREAM),
                    lookahead_pending: None,
                    powering_off: false,
                    request: plane_commit(scanout),
                    refresh_interval,
                    next_presentation_at: Instant::now() + refresh_interval,
                })
            })
            .collect::<Result<Vec<_>, Box<dyn Error>>>()?;
        events.pending.clear();
        events.completed_page_flips.clear();
        if powered_outputs > 0 {
            info!(
                powered_outputs,
                pool_outputs = scanouts.len(),
                "enabled atlas output pipelines"
            );
        } else {
            info!(
                pool_outputs = scanouts.len(),
                "parked Flutter atlas while every output is powered off"
            );
        }
        Ok(Self {
            volition: presentation,
            pipelines,
            affected_pipelines: Vec::with_capacity(scanouts.len()),
            submitted_outputs: Vec::with_capacity(scanouts.len()),
            presented_outputs: Vec::with_capacity(scanouts.len()),
            ready_fences: std::iter::repeat_with(ReadyFenceSlot::default)
                .take(buffer_count)
                .collect(),
            audit: render_audit_enabled()
                .then(|| OutputSchedulerAudit::new(buffer_count, powered_outputs)),
            parked: (powered_outputs == 0).then_some(initial_index),
            latest_index: initial_index,
            presented_frames: 0,
        })
    }

    pub(super) fn publish_ready(
        &mut self,
        runtime: &FlutterRuntime,
        ready: ReadyFrame,
        scanouts: &[Scanout],
    ) -> Result<Option<ReadyFenceWatch>, Box<dyn Error>> {
        let ReadyFrame {
            index,
            fence,
            damage,
            screenshot_request_id,
            rendered_at,
        } = ready;
        if self
            .ready_fences
            .get(index)
            .is_none_or(|slot| !slot.is_available())
        {
            return Err("Flutter published an atlas slot still awaiting KMS submission".into());
        }
        let token = next_ready_fence_token();
        if let Some(audit) = self.audit.as_mut() {
            audit.record_ready(index, token, fence.is_some(), rendered_at);
        }
        self.affected_pipelines.clear();
        self.affected_pipelines
            .extend(
                self.pipelines
                    .iter()
                    .enumerate()
                    .filter_map(|(pipeline_index, pipeline)| {
                        if pipeline.powering_off {
                            return None;
                        }
                        let rect = scanouts[pipeline.scanout_index].source_rect;
                        damage
                            .intersects_pixel_rect(rect.x, rect.y, rect.width, rect.height)
                            .then_some(pipeline_index)
                    }),
            );
        if self.affected_pipelines.is_empty() {
            let Some(fence) = fence else {
                // The raster thread completed this atlas synchronously, so a
                // frame which touches no powered output can be recycled now.
                runtime.publish_to_outputs(index, 0)?;
                return Ok(None);
            };
            let watch_fence = fence.as_fd().try_clone_to_owned()?;
            // Keep the buffer out of Flutter's free list until its GPU fence
            // signals even though no KMS pipeline will consume it.
            runtime.publish_to_outputs(index, 1)?;
            self.ready_fences[index].claim(Some(fence), 1, token)?;
            self.ready_fences[index].discard_user_when_signaled()?;
            return Ok(Some(ReadyFenceWatch {
                fence: watch_fence,
                signal: ReadyFenceSignal { index, token },
            }));
        }
        if self
            .affected_pipelines
            .iter()
            .filter_map(|pipeline_index| self.pipelines[*pipeline_index].ready.as_ref())
            .any(|frame| frame.screenshot_request_id.is_some())
        {
            return Err("cannot replace a screenshot-tagged Flutter output frame".into());
        }
        runtime.publish_to_outputs(index, self.affected_pipelines.len())?;
        self.latest_index = index;

        let fence_watch = fence
            .as_ref()
            .map(|fence| fence.as_fd().try_clone_to_owned())
            .transpose()?
            .map(|fence| ReadyFenceWatch {
                fence,
                signal: ReadyFenceSignal { index, token },
            });
        self.ready_fences[index].claim(fence, self.affected_pipelines.len(), token)?;
        for pipeline_index in self.affected_pipelines.iter().copied() {
            let pipeline = &mut self.pipelines[pipeline_index];
            if let Some(replaced) = pipeline.ready.take() {
                discard_ready_frame(runtime, &mut self.ready_fences, replaced)?;
            }
            pipeline.ready = Some(OutputFrame {
                index,
                screenshot_request_id,
                // Reset when the frame actually enters KMS.  Initializing it
                // here keeps the ownership type total while it is Ready.
                submitted_at: Instant::now(),
            });
        }
        // Every affected plane advertised IN_FENCE_FD before Flutter enabled
        // native fences. Keep observing the fence for lookahead scheduling and
        // buffer reuse while the immediate KMS path receives it directly.
        Ok(fence_watch)
    }

    pub(super) fn acknowledge_ready_fences(
        &mut self,
        runtime: &FlutterRuntime,
        signals: impl IntoIterator<Item = ReadyFenceSignal>,
    ) -> Result<(), Box<dyn Error>> {
        for signal in signals {
            if let Some(audit) = self.audit.as_mut() {
                audit.record_fence_signal(signal.index, signal.token);
            }
            if let Some(slot) = self.ready_fences.get_mut(signal.index) {
                let signaled = slot.mark_signaled(signal.token);
                if signaled {
                    let discard_users = slot.discard_users_on_signal;
                    slot.discard_users_on_signal = 0;
                    for _ in 0..discard_users {
                        runtime.release_output(signal.index)?;
                        slot.release_user()?;
                    }
                }
            }
        }
        Ok(())
    }

    pub(super) fn acknowledge_volition_events(
        &mut self,
        volition_events: impl IntoIterator<Item = volition::Event>,
        scanouts: &[Scanout],
        events: &mut RuntimeState,
    ) -> Result<Option<volition::Failure>, Box<dyn Error>> {
        self.submitted_outputs.clear();
        let mut stalled = None;
        for event in volition_events {
            if !self.volition.owns(&event) {
                continue;
            }
            match event {
                volition::Event::Submitted {
                    commit,
                    submitted_at,
                    ..
                } => {
                    let pipeline_index = self
                        .pipelines
                        .iter()
                        .position(|pipeline| {
                            pipeline
                                .lookahead_pending
                                .as_ref()
                                .is_some_and(|pending| pending.commit == commit)
                        })
                        .ok_or("Volition accepted a commit with no pending output frame")?;
                    let pipeline = &mut self.pipelines[pipeline_index];
                    let mut pending = pipeline
                        .lookahead_pending
                        .take()
                        .expect("located pending Volition frame");
                    pending.frame.submitted_at = submitted_at;
                    pipeline.submitted.push_back(pending.frame);
                    let scanout = &scanouts[pipeline.scanout_index];
                    events.pending.insert(scanout.output.crtc);
                    if let Some(audit) = self.audit.as_mut() {
                        audit.record_real_submission(pipeline_index, commit.frame, true);
                    }
                    self.submitted_outputs.push(scanout.output.id);
                }
                volition::Event::Stalled(failure) => {
                    // Keep the pending frame and its Flutter ownership intact.
                    // The caller will invalidate this entire scheduler only
                    // after establishing a synchronous KMS baseline.
                    if stalled.is_none() {
                        stalled = Some(failure);
                    }
                }
                volition::Event::Failed(failure) => return Err(Box::new(failure)),
            }
        }
        if let Some(frontend) = events.wayland.as_mut() {
            frontend.outputs_submitted(&self.submitted_outputs)?;
        }
        Ok(stalled)
    }

    pub(super) fn submit_ready(
        &mut self,
        swapchain: &AtlasSwapchain,
        scanouts: &[Scanout],
        events: &mut RuntimeState,
    ) -> Result<ReadySubmission, Box<dyn Error>> {
        self.submitted_outputs.clear();
        let mut queue_error = None;
        let (pipelines, ready_fences, audit, presentation) = (
            &mut self.pipelines,
            &mut self.ready_fences,
            &mut self.audit,
            &mut self.volition,
        );
        for (pipeline_index, pipeline) in pipelines.iter_mut().enumerate() {
            let retained_generations =
                pipeline.submitted.len() + usize::from(pipeline.lookahead_pending.is_some());
            if pipeline.powering_off
                || retained_generations >= volition::MAX_IN_FLIGHT_COMMITS_PER_STREAM
                || pipeline.lookahead_pending.is_some()
                || pipeline.ready.is_none()
            {
                continue;
            }
            let scanout = &scanouts[pipeline.scanout_index];
            let frame = pipeline.ready.as_ref().expect("checked ready output frame");
            let frame_index = frame.index;
            let volition_lookahead = !pipeline.submitted.is_empty();
            if (volition_lookahead && !ready_fences[frame_index].signaled)
                || (!volition_lookahead && !ready_fences[frame_index].can_submit_immediately())
            {
                // Kernel submission can queue an unfinished sync_file directly.
                // Volition lookahead waits until the same file is readable
                // before entering the atomic ioctl without a fence.
                continue;
            }
            let framebuffer = swapchain.buffers[frame_index].framebuffer();
            if volition_lookahead {
                let commit = CommitId {
                    stream: pipeline_index,
                    frame: frame_index,
                };
                let now = Instant::now();
                let not_before = pipeline
                    .next_presentation_at
                    .checked_sub(VOLITION_SUBMIT_LEAD)
                    .unwrap_or(now)
                    .max(now);
                let submission = presentation.submit_lookahead(
                    commit,
                    &pipeline.request,
                    framebuffer,
                    not_before,
                )?;
                if submission == Submission::Queued {
                    let frame = pipeline.ready.take().expect("checked ready output frame");
                    pipeline.lookahead_pending = Some(LookaheadFrame { commit, frame });
                    ready_fences[frame_index].release_user()?;
                    if ready_fences[frame_index].users == 0 {
                        debug_assert!(ready_fences[frame_index].fence.is_none());
                    }
                }
                continue;
            }

            let fence = ready_fences[frame_index].fence.as_ref().map(AsFd::as_fd);
            if let Err(error) =
                presentation.submit_immediate(&mut pipeline.request, framebuffer, fence)
            {
                queue_error = Some(format!(
                    "KMS rejected immediate plane commit for {} (IN_FENCE_FD={}): {error}",
                    scanout.output.name,
                    fence.is_some()
                ));
                break;
            }
            let submitted_at = Instant::now();
            pipeline.next_presentation_at = submitted_at + pipeline.refresh_interval;
            events.pending.insert(scanout.output.crtc);
            let mut frame = pipeline.ready.take().expect("checked ready output frame");
            frame.submitted_at = submitted_at;
            pipeline.submitted.push_back(frame);
            if let Some(audit) = audit.as_mut() {
                audit.record_real_submission(pipeline_index, frame_index, false);
            }
            ready_fences[frame_index].release_user()?;
            if ready_fences[frame_index].users == 0 {
                // The immediate ioctl has copied its fence fd, so the slot can
                // close it after its final output user enters KMS.
                debug_assert!(ready_fences[frame_index].fence.is_none());
            }
            self.submitted_outputs.push(scanout.output.id);
        }
        if let Some(frontend) = events.wayland.as_mut() {
            frontend.outputs_submitted(&self.submitted_outputs)?;
        }
        if let Some(error) = queue_error {
            return Err(error.into());
        }
        Ok(ReadySubmission {
            submitted: self.submitted_outputs.len(),
        })
    }

    /// Screenshot-tagged frames are exact handoffs and cannot be superseded.
    /// Ordinary frames are latest-value mailbox entries per output: publishing
    /// a newer generation replaces an older unsubmitted generation while its
    /// GPU fence continues to protect the discarded buffer independently.
    pub(super) fn can_accept_ready(&self) -> bool {
        self.pipelines.iter().all(|pipeline| {
            pipeline
                .ready
                .as_ref()
                .is_none_or(|frame| frame.screenshot_request_id.is_none())
        })
    }

    pub(super) fn handle_completions(
        &mut self,
        runtime: &mut FlutterRuntime,
        swapchain: &mut AtlasSwapchain,
        scanouts: &[Scanout],
        events: &mut RuntimeState,
    ) -> Result<(), Box<dyn Error>> {
        self.handle_completions_inner(runtime, swapchain, scanouts, events)
    }

    pub(super) fn retire_completions_for_shutdown(
        &mut self,
        runtime: &mut FlutterRuntime,
        swapchain: &mut AtlasSwapchain,
        scanouts: &[Scanout],
        events: &mut RuntimeState,
    ) -> Result<(), Box<dyn Error>> {
        self.handle_completions_inner(runtime, swapchain, scanouts, events)?;
        Ok(())
    }

    fn handle_completions_inner(
        &mut self,
        runtime: &mut FlutterRuntime,
        swapchain: &mut AtlasSwapchain,
        scanouts: &[Scanout],
        events: &mut RuntimeState,
    ) -> Result<(), Box<dyn Error>> {
        self.presented_outputs.clear();
        let mut processing_error = None;
        while let Some(completion) = events.completed_page_flips.pop_front() {
            let Some(pipeline_index) = self.pipelines.iter().position(|pipeline| {
                scanouts[pipeline.scanout_index].output.crtc == completion.crtc
            }) else {
                continue;
            };
            let pipeline = &mut self.pipelines[pipeline_index];
            let Some(presented) = pipeline.submitted.pop_front() else {
                continue;
            };
            if pipeline.submitted.is_empty() {
                events.pending.remove(&completion.crtc);
            } else {
                events.pending.insert(completion.crtc);
            }
            let previous = pipeline.scanning;
            pipeline.scanning = presented.index;
            pipeline.scanning_screenshot_request_id = presented.screenshot_request_id;
            pipeline.next_presentation_at = completion.observed_at + pipeline.refresh_interval;
            if let Err(error) = runtime.release_output(previous) {
                processing_error = Some(error);
                break;
            }
            swapchain.present(presented.index);
            self.latest_index = presented.index;

            let presentation = PresentedOutput {
                id: scanouts[pipeline.scanout_index].output.id,
                observed_at: completion.observed_at,
                presented_at: completion.presented_at,
                sequence: completion.sequence,
            };
            if let Some(audit) = self.audit.as_mut() {
                audit.record_presentation(
                    pipeline_index,
                    completion.observed_at,
                    completion.sequence,
                );
            }
            self.presented_outputs.push(presentation);
            self.presented_frames = self.presented_frames.saturating_add(1);
        }
        if let Some(frontend) = events.wayland.as_mut() {
            frontend.outputs_presented(&self.presented_outputs)?;
        }
        if let Some(error) = processing_error {
            return Err(error);
        }
        Ok(())
    }

    pub(super) fn presented_outputs(&self) -> &[PresentedOutput] {
        &self.presented_outputs
    }

    pub(super) fn process_screencopies_at_tick(
        &self,
        tick: FrameTick,
        renderer: &mut GlesRenderer,
        swapchain: &mut AtlasSwapchain,
        scanouts: &[Scanout],
        events: &mut RuntimeState,
    ) -> Result<(), Box<dyn Error>> {
        let Some(buffer_index) = self.framebuffer_index_for_output(tick.output, scanouts) else {
            return Ok(());
        };
        let Some(frontend) = events.wayland.as_mut() else {
            return Ok(());
        };
        if !frontend.has_pending_screencopy_for_output(tick.output) {
            return Ok(());
        }
        let timestamp = tick
            .presented_at
            .unwrap_or_else(|| frontend.screencopy_clock_now());
        frontend.process_screencopies(
            renderer,
            &mut swapchain.buffers[buffer_index].dmabuf,
            tick.output,
            timestamp,
        )
    }

    pub(super) fn framebuffer_index_for_output(
        &self,
        output: OutputId,
        scanouts: &[Scanout],
    ) -> Option<usize> {
        self.pipelines
            .iter()
            .find(|pipeline| {
                !pipeline.powering_off && scanouts[pipeline.scanout_index].output.id == output
            })
            .map(|pipeline| pipeline.scanning)
    }

    pub(super) fn screenshot_framebuffer_for_output(
        &self,
        output: OutputId,
        request_id: u64,
        scanouts: &[Scanout],
    ) -> Option<usize> {
        self.pipelines
            .iter()
            .find(|pipeline| {
                !pipeline.powering_off
                    && scanouts[pipeline.scanout_index].output.id == output
                    && pipeline.scanning_screenshot_request_id == Some(request_id)
            })
            .map(|pipeline| pipeline.scanning)
    }

    pub(super) fn has_submitted(&self) -> bool {
        self.pipelines
            .iter()
            .any(|pipeline| !pipeline.submitted.is_empty())
    }

    /// Reports a commit which entered KMS but produced no page-flip event.
    /// The compositor can then drop every DRM/render fd and let its supervisor
    /// start a fresh graphics stack instead of displaying one frozen frame.
    pub(super) fn presentation_stall(&self, now: Instant) -> Option<PresentationStall> {
        self.pipelines.iter().find_map(|pipeline| {
            let frame = pipeline.submitted.front()?;
            let elapsed = presentation_stall_age(frame.submitted_at, now)?;
            Some(PresentationStall {
                scanout_index: pipeline.scanout_index,
                framebuffer_index: frame.index,
                pending_frames: pipeline.submitted.len(),
                elapsed,
            })
        })
    }

    /// Ensures calloop wakes when the oldest accepted commit reaches the
    /// watchdog deadline even if the kernel never sends another DRM event.
    pub(super) fn limit_presentation_watchdog_timeout(
        &self,
        now: Instant,
        timeout: Duration,
    ) -> Duration {
        self.pipelines
            .iter()
            .filter_map(|pipeline| pipeline.submitted.front())
            .map(|frame| presentation_watchdog_remaining(frame.submitted_at, now))
            .fold(timeout, Duration::min)
    }

    pub(super) fn shutdown_volition(&mut self) {
        self.volition.shutdown();
    }

    pub(super) fn has_pending_scanout_work(&self) -> bool {
        self.pipelines.iter().any(|pipeline| {
            pipeline.ready.is_some()
                || pipeline.lookahead_pending.is_some()
                || !pipeline.submitted.is_empty()
        })
    }

    pub(super) fn begin_power_off(
        &mut self,
        runtime: &FlutterRuntime,
        output: OutputId,
        scanouts: &[Scanout],
    ) -> Result<bool, Box<dyn Error>> {
        let Some(pipeline) = self
            .pipelines
            .iter_mut()
            .find(|pipeline| scanouts[pipeline.scanout_index].output.id == output)
        else {
            return Ok(false);
        };
        pipeline.powering_off = true;
        if let Some(ready) = pipeline.ready.take() {
            discard_ready_frame(runtime, &mut self.ready_fences, ready)?;
        }
        let submitted = !pipeline.submitted.is_empty() || pipeline.lookahead_pending.is_some();
        self.repair_latest_index();
        Ok(submitted)
    }

    pub(super) fn cancel_power_off(&mut self, output: OutputId, scanouts: &[Scanout]) {
        if let Some(pipeline) = self
            .pipelines
            .iter_mut()
            .find(|pipeline| scanouts[pipeline.scanout_index].output.id == output)
        {
            pipeline.powering_off = false;
        }
    }

    pub(super) fn power_off(
        &mut self,
        runtime: &FlutterRuntime,
        output: OutputId,
        scanouts: &[Scanout],
    ) -> Result<(), Box<dyn Error>> {
        let Some(index) = self
            .pipelines
            .iter()
            .position(|pipeline| scanouts[pipeline.scanout_index].output.id == output)
        else {
            return Ok(());
        };
        if !self.pipelines[index].submitted.is_empty()
            || self.pipelines[index].lookahead_pending.is_some()
        {
            return Err("cannot power off an output with pending scanout work".into());
        }

        let pipeline = self.pipelines.remove(index);
        if let Some(ready) = pipeline.ready {
            discard_ready_frame(runtime, &mut self.ready_fences, ready)?;
        }
        if self.pipelines.is_empty() {
            debug_assert!(self.parked.is_none());
            self.parked = Some(pipeline.scanning);
            self.latest_index = pipeline.scanning;
        } else {
            runtime.release_output(pipeline.scanning)?;
            self.repair_latest_index();
        }
        Ok(())
    }

    pub(super) fn stable_framebuffer_index(&self) -> usize {
        self.parked
            .or_else(|| self.pipelines.first().map(|pipeline| pipeline.scanning))
            .unwrap_or(self.latest_index)
    }

    pub(super) fn scanning_framebuffer_index(
        &self,
        output: OutputId,
        scanouts: &[Scanout],
    ) -> Option<usize> {
        self.pipelines
            .iter()
            .find(|pipeline| scanouts[pipeline.scanout_index].output.id == output)
            .map(|pipeline| pipeline.scanning)
    }

    pub(super) fn power_on(
        &mut self,
        runtime: &FlutterRuntime,
        scanout_index: usize,
        framebuffer_index: usize,
        scanouts: &[Scanout],
    ) -> Result<(), Box<dyn Error>> {
        let output = scanouts
            .get(scanout_index)
            .ok_or("DPMS wake references a missing scanout")?;
        if self
            .pipelines
            .iter()
            .any(|pipeline| pipeline.scanout_index == scanout_index)
        {
            return Ok(());
        }

        if self.pipelines.is_empty() {
            if self.parked != Some(framebuffer_index) {
                return Err("DPMS wake disagrees with the parked Flutter buffer".into());
            }
            self.parked = None;
        } else {
            runtime.retain_outputs(framebuffer_index, 1)?;
        }
        let refresh_interval = refresh_interval(output);
        self.pipelines.push(OutputPipeline {
            scanout_index,
            scanning: framebuffer_index,
            scanning_screenshot_request_id: None,
            ready: None,
            submitted: VecDeque::with_capacity(volition::MAX_IN_FLIGHT_COMMITS_PER_STREAM),
            lookahead_pending: None,
            powering_off: false,
            request: plane_commit(output),
            refresh_interval,
            next_presentation_at: Instant::now() + refresh_interval,
        });
        self.latest_index = framebuffer_index;
        Ok(())
    }

    fn repair_latest_index(&mut self) {
        let still_owned = self.parked == Some(self.latest_index)
            || self.pipelines.iter().any(|pipeline| {
                pipeline.scanning == self.latest_index
                    || pipeline
                        .ready
                        .as_ref()
                        .is_some_and(|frame| frame.index == self.latest_index)
                    || pipeline
                        .submitted
                        .iter()
                        .any(|frame| frame.index == self.latest_index)
                    || pipeline
                        .lookahead_pending
                        .as_ref()
                        .is_some_and(|pending| pending.frame.index == self.latest_index)
            });
        if !still_owned
            && let Some(scanning) = self
                .parked
                .or_else(|| self.pipelines.first().map(|pipeline| pipeline.scanning))
        {
            self.latest_index = scanning;
        }
    }

    /// Brings every CRTC onto one complete atlas generation before a topology
    /// transaction. The steady-state path is deliberately per-output; the
    /// temporary convergence gives the existing rollback journal one truthful
    /// framebuffer to restore if hotplug validation fails.
    pub(super) fn converge_for_topology(
        &mut self,
        runtime: &FlutterRuntime,
        drm: &DrmDevice,
        swapchain: &mut AtlasSwapchain,
        scanouts: &[Scanout],
        events: &mut RuntimeState,
    ) -> Result<usize, Box<dyn Error>> {
        if self.has_pending_scanout_work() {
            return Err("cannot converge outputs while a frame is ready or submitted".into());
        }
        if self.pipelines.len() != scanouts.iter().filter(|scanout| scanout.powered).count() {
            return Err("output scheduler topology no longer matches KMS scanouts".into());
        }

        if self.pipelines.is_empty() {
            events.pending.clear();
            events.completed_page_flips.clear();
            return self
                .parked
                .ok_or_else(|| "powered-off scheduler lost its parked atlas".into());
        }

        let converged = self.latest_index;
        runtime.retain_outputs(converged, self.pipelines.len())?;
        let framebuffer = swapchain.buffers[converged].framebuffer();
        if let Err(error) = super::commit_atlas_now(drm, scanouts, framebuffer) {
            for _ in 0..self.pipelines.len() {
                runtime.release_output(converged)?;
            }
            return Err(error);
        }

        for pipeline in &mut self.pipelines {
            if let Some(ready) = pipeline.ready.take() {
                runtime.release_output(ready.index)?;
            }
            runtime.release_output(pipeline.scanning)?;
            pipeline.scanning = converged;
        }
        self.ready_fences.fill_with(ReadyFenceSlot::default);
        swapchain.present(converged);
        events.pending.clear();
        events.completed_page_flips.clear();
        Ok(converged)
    }

    pub(super) fn presented_frames(&self) -> u64 {
        self.presented_frames
    }
}

#[cfg(test)]
mod tests {
    use std::os::unix::net::UnixStream;
    use std::time::{Duration, Instant};

    use super::{
        OutputSchedulerAudit, PRESENTATION_STALL_TIMEOUT, ReadyFenceSlot, presentation_stall_age,
        presentation_watchdog_remaining,
    };

    #[test]
    fn ready_fence_slot_closes_only_after_its_last_pipeline_user() {
        let mut slot = ReadyFenceSlot::default();
        assert!(slot.is_available());
        slot.claim(None, 2, 11).unwrap();
        assert!(!slot.is_available());
        assert!(slot.can_submit_immediately());
        assert!(slot.claim(None, 1, 12).is_err());

        slot.release_user().unwrap();
        assert_eq!(slot.users, 1);
        slot.release_user().unwrap();
        assert!(slot.is_available());
        assert!(slot.release_user().is_err());
        assert!(slot.claim(None, 0, 13).is_err());
        assert!(slot.claim(None, 1, 0).is_err());
    }

    #[test]
    fn ready_fence_slot_ignores_stale_signals() {
        let mut slot = ReadyFenceSlot::default();
        let (fence, _peer) = UnixStream::pair().unwrap();
        slot.claim(Some(fence.into()), 1, 21).unwrap();
        assert!(slot.can_submit_immediately());
        assert!(!slot.mark_signaled(20));
        assert!(slot.can_submit_immediately());
        assert!(slot.mark_signaled(21));
        assert!(slot.can_submit_immediately());

        slot.release_user().unwrap();
        assert!(!slot.mark_signaled(21));
        assert!(slot.is_available());
    }

    #[test]
    fn discarded_gpu_frame_is_not_reusable_until_its_fence_user_retires() {
        let mut slot = ReadyFenceSlot::default();
        let (fence, _peer) = UnixStream::pair().unwrap();
        slot.claim(Some(fence.into()), 2, 31).unwrap();
        slot.discard_user_when_signaled().unwrap();
        slot.discard_user_when_signaled().unwrap();
        assert!(slot.discard_user_when_signaled().is_err());

        assert!(!slot.is_available());
        assert!(slot.mark_signaled(31));
        let discard_users = slot.discard_users_on_signal;
        slot.discard_users_on_signal = 0;
        assert_eq!(discard_users, 2);
        for _ in 0..discard_users {
            slot.release_user().unwrap();
        }
        assert!(slot.is_available());
        assert!(slot.release_user().is_err());
    }

    #[test]
    fn scheduler_audit_counts_wrapped_drm_sequence_gaps() {
        let mut audit = OutputSchedulerAudit::new(4, 1);
        let now = Instant::now();
        audit.record_presentation(0, now, Some(u64::from(u32::MAX - 1)));
        audit.record_presentation(0, now, Some(1));

        assert_eq!(audit.presentations, 2);
        assert_eq!(audit.sequence_samples, 1);
        assert_eq!(audit.sequence_delta_total, 3);
        assert_eq!(audit.sequence_delta_max, 3);
        assert_eq!(audit.missed_vblanks, 2);
    }

    #[test]
    fn scheduler_audit_tracks_kernel_owned_fence_after_submission() {
        let mut audit = OutputSchedulerAudit::new(4, 1);
        audit.record_ready(0, 41, true, None);
        audit.record_real_submission(0, 0, false);

        audit.record_fence_signal(0, 40);
        assert_eq!(audit.fence_signals, 0);
        audit.record_fence_signal(0, 41);
        assert_eq!(audit.fence_signals, 1);
        assert_eq!(audit.ready_to_fence.samples, 1);

        audit.record_fence_signal(0, 41);
        assert_eq!(audit.fence_signals, 1);
    }

    #[test]
    fn scheduler_audit_retires_lookahead_submissions_in_order() {
        let mut audit = OutputSchedulerAudit::new(4, 1);
        audit.record_ready(0, 51, false, None);
        audit.record_real_submission(0, 0, false);
        audit.record_ready(1, 52, false, None);
        audit.record_real_submission(0, 1, true);
        assert_eq!(audit.volition_lookahead_submissions, 1);
        assert_eq!(audit.submitted_at[0].len(), 2);

        let now = Instant::now();
        audit.record_presentation(0, now, Some(1));
        assert_eq!(audit.submitted_at[0].len(), 1);
        audit.record_presentation(0, now, Some(2));
        assert!(audit.submitted_at[0].is_empty());
        assert_eq!(audit.submit_to_presentation.samples, 2);
    }

    #[test]
    fn presentation_watchdog_trips_at_its_deadline() {
        let submitted_at = Instant::now();
        let before = submitted_at + PRESENTATION_STALL_TIMEOUT - Duration::from_nanos(1);
        let deadline = submitted_at + PRESENTATION_STALL_TIMEOUT;

        assert_eq!(presentation_stall_age(submitted_at, before), None);
        assert_eq!(
            presentation_watchdog_remaining(submitted_at, before),
            Duration::from_nanos(1)
        );
        assert_eq!(
            presentation_stall_age(submitted_at, deadline),
            Some(PRESENTATION_STALL_TIMEOUT)
        );
        assert_eq!(
            presentation_watchdog_remaining(submitted_at, deadline),
            Duration::ZERO
        );
    }
}
