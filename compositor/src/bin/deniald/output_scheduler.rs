use std::error::Error;
use std::os::fd::{AsFd, OwnedFd};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use denial_core::topology::{OutputId, OutputTransform, PixelRect, PixelSize, RenderViewId};
use denial_core::volition::{self, CommitId, PlaneCommit, PlaneProperties, Submission, Volition};
use smithay::backend::drm::DrmDevice;
use smithay::reexports::calloop::channel::SyncSender as EventSender;
use tracing::info;

use super::flutter_runtime::{FlutterRuntime, ReadyOutputFrame};
use super::frame_scheduler::{FrameTick, OutputFrameRequest};
use super::kms_state::{OutputSwapchains, Scanout};
use super::{PresentedOutput, RuntimeState, cpu_scheduling, render_audit_enabled};

const OUTPUT_SCHEDULER_AUDIT_INTERVAL: Duration = Duration::from_secs(1);
/// A nonblocking atomic commit should retire on the next display edge.  Give
/// slow modesets and scheduler jitter ample room, but never retain a wedged
/// KMS/GPU generation indefinitely.
const PRESENTATION_STALL_TIMEOUT: Duration = Duration::from_secs(2);
/// Synthetic and kernel monotonic clocks can retain a small phase error.  A
/// ready target this close to the edge which just completed is nevertheless
/// unreachable: atomic state can only be latched for a later edge now.
const ELAPSED_READY_TARGET_TOLERANCE: Duration = Duration::from_millis(1);
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
    request: OutputFrameRequest,
    submitted_at: Instant,
}

fn ready_target_elapsed(frame: &OutputFrame, presented_at: Instant) -> bool {
    if frame.screenshot_request_id.is_some() {
        return false;
    }
    let tolerance = ELAPSED_READY_TARGET_TOLERANCE.min(frame.request.tick.interval / 4);
    frame
        .request
        .tick
        .presentation_target
        .saturating_duration_since(presented_at)
        <= tolerance
}

#[derive(Debug)]
struct ScheduledFrame {
    commit: CommitId,
    frame: OutputFrame,
}

#[derive(Debug)]
enum InFlightFrame {
    Scheduled(ScheduledFrame),
    Submitted(OutputFrame),
}

#[derive(Debug)]
enum CompletionRetirement {
    Retired(OutputFrame),
    /// The kernel may report a fast page flip before calloop observes
    /// Volition's userspace submission acknowledgement. Keep that physical
    /// completion until the scheduled generation advances to Submitted.
    Deferred,
    Stale,
}

#[derive(Debug, Default)]
struct OutputPipelineFrames {
    ready: Option<OutputFrame>,
    in_flight: Option<InFlightFrame>,
}

impl OutputPipelineFrames {
    fn render_available(&self) -> bool {
        self.ready.is_none()
    }

    fn install_ready(&mut self, frame: OutputFrame) -> Result<(), &'static str> {
        if self.ready.is_some() {
            return Err("an output successor is already ready");
        }
        self.ready = Some(frame);
        Ok(())
    }

    fn schedule_ready(&mut self, commit: CommitId) -> Result<(), &'static str> {
        if self.in_flight.is_some() {
            return Err("an output generation is already in Volition or KMS");
        }
        let frame = self
            .ready
            .take()
            .ok_or("an output successor is not ready")?;
        self.in_flight = Some(InFlightFrame::Scheduled(ScheduledFrame { commit, frame }));
        Ok(())
    }

    fn scheduled_commit(&self) -> Option<CommitId> {
        match self.in_flight.as_ref() {
            Some(InFlightFrame::Scheduled(frame)) => Some(frame.commit),
            _ => None,
        }
    }

    fn acknowledge_submission(
        &mut self,
        commit: CommitId,
        submitted_at: Instant,
    ) -> Result<usize, &'static str> {
        let in_flight = self.in_flight.take();
        match in_flight {
            Some(InFlightFrame::Scheduled(mut scheduled)) if scheduled.commit == commit => {
                scheduled.frame.submitted_at = submitted_at;
                let index = scheduled.frame.index;
                self.in_flight = Some(InFlightFrame::Submitted(scheduled.frame));
                Ok(index)
            }
            other => {
                self.in_flight = other;
                Err("Volition submission does not match the scheduled output generation")
            }
        }
    }

    fn submitted(&self) -> Option<&OutputFrame> {
        match self.in_flight.as_ref() {
            Some(InFlightFrame::Submitted(frame)) => Some(frame),
            _ => None,
        }
    }

    fn retire_completion(&mut self) -> CompletionRetirement {
        match self.in_flight.as_ref() {
            Some(InFlightFrame::Scheduled(_)) => CompletionRetirement::Deferred,
            Some(InFlightFrame::Submitted(_)) => match self.in_flight.take() {
                Some(InFlightFrame::Submitted(frame)) => CompletionRetirement::Retired(frame),
                _ => unreachable!("checked submitted output generation"),
            },
            None => CompletionRetirement::Stale,
        }
    }

    fn take_ready(&mut self) -> Option<OutputFrame> {
        self.ready.take()
    }

    fn has_work(&self) -> bool {
        self.ready.is_some() || self.in_flight.is_some()
    }
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

#[derive(Debug)]
struct OutputReadyFences {
    output_id: OutputId,
    render_view_id: RenderViewId,
    configuration_generation: u64,
    size: PixelSize,
    slots: Vec<ReadyFenceSlot>,
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
    output: OutputId,
    ready_fences: &mut [ReadyFenceSlot],
    frame: OutputFrame,
) -> Result<(), Box<dyn Error>> {
    let slot = ready_fences
        .get_mut(frame.index)
        .ok_or("discarded Flutter frame exceeds the fence pool")?;
    if slot.signaled {
        runtime.release_output(output, frame.index)?;
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
    output: OutputId,
    index: usize,
    token: u64,
}

#[derive(Debug)]
pub(super) struct ReadyFenceWatch {
    fence: OwnedFd,
    signal: ReadyFenceSignal,
}

impl ReadyFenceWatch {
    pub(super) fn into_parts(self) -> (OwnedFd, ReadyFenceSignal) {
        (self.fence, self.signal)
    }
}

fn plane_commit(scanout: &Scanout, size: PixelSize) -> Result<PlaneCommit, Box<dyn Error>> {
    let properties = scanout.plane_properties;
    Ok(PlaneCommit::new(
        scanout.surface.plane(),
        PlaneProperties {
            framebuffer: properties.framebuffer,
            source_x: properties.source_x,
            source_y: properties.source_y,
            source_width: properties.source_width,
            source_height: properties.source_height,
            rotation: scanout.rotation_property(OutputTransform::Normal)?,
            in_fence_fd: properties.in_fence_fd,
        },
        PixelRect {
            x: 0,
            y: 0,
            width: size.width,
            height: size.height,
        },
    ))
}

#[derive(Debug)]
struct OutputPipeline {
    output_id: OutputId,
    scanout_index: usize,
    scanning: usize,
    scanning_screenshot_request_id: Option<u64>,
    frames: OutputPipelineFrames,
    powering_off: bool,
    request: PlaneCommit,
}

#[derive(Debug)]
struct OutputSchedulerAudit {
    interval_started: Instant,
    output_ids: Vec<OutputId>,
    ready_tokens: Vec<u64>,
    ready_published_at: Vec<Option<Instant>>,
    fence_signaled_at: Vec<Option<Instant>>,
    render_deadlines: Vec<Option<Instant>>,
    last_sequences: Vec<Option<u32>>,
    last_presented_at: Vec<Option<Instant>>,
    submitted_at: Vec<Option<Instant>>,
    ready_published: u64,
    ready_with_fence: u64,
    fence_signals: u64,
    real_submissions: u64,
    volition_scheduled_submissions: u64,
    presentations: u64,
    sequence_samples: u64,
    sequence_delta_total: u64,
    sequence_delta_max: u32,
    missed_vblanks: u64,
    stale_ready_drops: u64,
    missed_vblanks_by_output: Vec<u64>,
    ready_to_fence: AuditLatency,
    fence_to_submit: AuditLatency,
    ready_to_submit: AuditLatency,
    render_to_publish: AuditLatency,
    presentation_delivery: AuditLatency,
    presentation_to_submit: AuditLatency,
    submit_to_presentation: AuditLatency,
    target_to_presentation: AuditLatency,
    presentation_interval: AuditLatency,
    deadline_to_ready: AuditLatency,
    deadline_to_fence: AuditLatency,
    deadline_to_submit: AuditLatency,
    deadline_to_presentation: AuditLatency,
    target_to_presentation_by_output: Vec<AuditLatency>,
    deadline_to_presentation_by_output: Vec<AuditLatency>,
    presentation_interval_by_output: Vec<AuditLatency>,
}

#[derive(Debug, Default)]
struct AuditLatency {
    samples: u64,
    total: Duration,
    max: Duration,
    values: Vec<Duration>,
}

#[derive(Clone, Copy, Debug, Default)]
struct AuditLatencySummary {
    average_us: f64,
    p50_us: f64,
    p95_us: f64,
    p99_us: f64,
    max_us: f64,
}

impl AuditLatency {
    fn record(&mut self, duration: Duration) {
        self.samples = self.samples.saturating_add(1);
        self.total = self.total.saturating_add(duration);
        self.max = self.max.max(duration);
        self.values.push(duration);
    }

    fn average_us(&self) -> f64 {
        if self.samples == 0 {
            return 0.0;
        }
        self.total.as_secs_f64() * 1_000_000.0 / self.samples as f64
    }

    fn summary(&self) -> AuditLatencySummary {
        if self.samples == 0 {
            return AuditLatencySummary::default();
        }
        let mut values = self.values.clone();
        values.sort_unstable();
        AuditLatencySummary {
            average_us: self.average_us(),
            p50_us: audit_percentile_us(&values, 50),
            p95_us: audit_percentile_us(&values, 95),
            p99_us: audit_percentile_us(&values, 99),
            max_us: self.max.as_secs_f64() * 1_000_000.0,
        }
    }
}

fn audit_percentile_us(values: &[Duration], percentile: usize) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let rank = (values.len().saturating_mul(percentile).saturating_add(99) / 100)
        .saturating_sub(1)
        .min(values.len() - 1);
    values[rank].as_secs_f64() * 1_000_000.0
}

impl OutputSchedulerAudit {
    fn new(buffer_count: usize, output_ids: Vec<OutputId>) -> Self {
        let output_count = output_ids.len();
        Self {
            interval_started: Instant::now(),
            output_ids,
            ready_tokens: vec![0; buffer_count],
            ready_published_at: vec![None; buffer_count],
            fence_signaled_at: vec![None; buffer_count],
            render_deadlines: vec![None; buffer_count],
            last_sequences: vec![None; output_count],
            last_presented_at: vec![None; output_count],
            submitted_at: vec![None; output_count],
            ready_published: 0,
            ready_with_fence: 0,
            fence_signals: 0,
            real_submissions: 0,
            volition_scheduled_submissions: 0,
            presentations: 0,
            sequence_samples: 0,
            sequence_delta_total: 0,
            sequence_delta_max: 0,
            missed_vblanks: 0,
            stale_ready_drops: 0,
            missed_vblanks_by_output: vec![0; output_count],
            ready_to_fence: AuditLatency::default(),
            fence_to_submit: AuditLatency::default(),
            ready_to_submit: AuditLatency::default(),
            render_to_publish: AuditLatency::default(),
            presentation_delivery: AuditLatency::default(),
            presentation_to_submit: AuditLatency::default(),
            submit_to_presentation: AuditLatency::default(),
            target_to_presentation: AuditLatency::default(),
            presentation_interval: AuditLatency::default(),
            deadline_to_ready: AuditLatency::default(),
            deadline_to_fence: AuditLatency::default(),
            deadline_to_submit: AuditLatency::default(),
            deadline_to_presentation: AuditLatency::default(),
            target_to_presentation_by_output: std::iter::repeat_with(AuditLatency::default)
                .take(output_count)
                .collect(),
            deadline_to_presentation_by_output: std::iter::repeat_with(AuditLatency::default)
                .take(output_count)
                .collect(),
            presentation_interval_by_output: std::iter::repeat_with(AuditLatency::default)
                .take(output_count)
                .collect(),
        }
    }

    fn record_ready(
        &mut self,
        index: usize,
        token: u64,
        has_fence: bool,
        rendered_at: Option<Instant>,
        render_deadline: Instant,
    ) {
        self.maybe_report();
        self.ready_published = self.ready_published.saturating_add(1);
        if has_fence {
            self.ready_with_fence = self.ready_with_fence.saturating_add(1);
        }
        let now = Instant::now();
        self.deadline_to_ready
            .record(now.saturating_duration_since(render_deadline));
        if !has_fence {
            self.deadline_to_fence
                .record(now.saturating_duration_since(render_deadline));
        }
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
        if let Some(deadline) = self.render_deadlines.get_mut(index) {
            *deadline = Some(render_deadline);
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
        if let Some(Some(render_deadline)) = self.render_deadlines.get(index) {
            self.deadline_to_fence
                .record(now.saturating_duration_since(*render_deadline));
        }
        if let Some(signaled_at) = self.fence_signaled_at.get_mut(index) {
            *signaled_at = Some(now);
        }
    }

    fn record_real_submission(
        &mut self,
        output_index: usize,
        buffer_index: usize,
        submitted_at: Instant,
    ) {
        self.maybe_report();
        self.real_submissions = self.real_submissions.saturating_add(1);
        self.volition_scheduled_submissions = self.volition_scheduled_submissions.saturating_add(1);
        if let Some(Some(presented_at)) = self.last_presented_at.get(output_index) {
            self.presentation_to_submit
                .record(submitted_at.saturating_duration_since(*presented_at));
        }
        if let Some(pending) = self.submitted_at.get_mut(output_index) {
            debug_assert!(pending.is_none());
            *pending = Some(submitted_at);
        }
        if let Some(published_at) = self
            .ready_published_at
            .get(buffer_index)
            .and_then(|published_at| *published_at)
        {
            self.ready_to_submit
                .record(submitted_at.saturating_duration_since(published_at));
        }
        if let Some(signaled_at) = self
            .fence_signaled_at
            .get(buffer_index)
            .and_then(|signaled_at| *signaled_at)
        {
            self.fence_to_submit
                .record(submitted_at.saturating_duration_since(signaled_at));
        }
        if let Some(render_deadline) = self
            .render_deadlines
            .get(buffer_index)
            .and_then(|deadline| *deadline)
        {
            self.deadline_to_submit
                .record(submitted_at.saturating_duration_since(render_deadline));
        }
    }

    fn record_presentation(
        &mut self,
        output_index: usize,
        observed_at: Instant,
        render_deadline: Instant,
        presentation_target: Instant,
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
            .and_then(Option::take)
        {
            self.submit_to_presentation
                .record(observed_at.saturating_duration_since(submitted_at));
        }
        self.target_to_presentation
            .record(observed_at.saturating_duration_since(presentation_target));
        self.deadline_to_presentation
            .record(observed_at.saturating_duration_since(render_deadline));
        if let Some(latency) = self.target_to_presentation_by_output.get_mut(output_index) {
            latency.record(observed_at.saturating_duration_since(presentation_target));
        }
        if let Some(latency) = self
            .deadline_to_presentation_by_output
            .get_mut(output_index)
        {
            latency.record(observed_at.saturating_duration_since(render_deadline));
        }
        if let Some(presented_at) = self.last_presented_at.get_mut(output_index) {
            if let Some(previous) = *presented_at {
                let interval = observed_at.saturating_duration_since(previous);
                self.presentation_interval.record(interval);
                if let Some(latency) = self.presentation_interval_by_output.get_mut(output_index) {
                    latency.record(interval);
                }
            }
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
            if let Some(missed) = self.missed_vblanks_by_output.get_mut(output_index) {
                *missed = missed.saturating_add(u64::from(delta.saturating_sub(1)));
            }
        }
        *last_sequence = Some(sequence);
    }

    fn per_output_timing_description(&self) -> String {
        if self.output_ids.is_empty() {
            return "-".to_owned();
        }
        self.output_ids
            .iter()
            .enumerate()
            .map(|(index, output)| {
                let interval = self
                    .presentation_interval_by_output
                    .get(index)
                    .map_or_else(AuditLatencySummary::default, AuditLatency::summary);
                let deadline = self
                    .deadline_to_presentation_by_output
                    .get(index)
                    .map_or_else(AuditLatencySummary::default, AuditLatency::summary);
                let target = self
                    .target_to_presentation_by_output
                    .get(index)
                    .map_or_else(AuditLatencySummary::default, AuditLatency::summary);
                let missed = self
                    .missed_vblanks_by_output
                    .get(index)
                    .copied()
                    .unwrap_or_default();
                format!(
                    "{}:interval_p50={:.0}/p95={:.0}/p99={:.0}/max={:.0};deadline_p99={:.0};target_late_p99={:.0};missed={missed}",
                    output.0,
                    interval.p50_us,
                    interval.p95_us,
                    interval.p99_us,
                    interval.max_us,
                    deadline.p99_us,
                    target.p99_us,
                )
            })
            .collect::<Vec<_>>()
            .join(",")
    }

    fn maybe_report(&mut self) {
        let elapsed = self.interval_started.elapsed();
        if elapsed < OUTPUT_SCHEDULER_AUDIT_INTERVAL {
            return;
        }

        let ready_to_fence = self.ready_to_fence.summary();
        let fence_to_submit = self.fence_to_submit.summary();
        let ready_to_submit = self.ready_to_submit.summary();
        let render_to_publish = self.render_to_publish.summary();
        let presentation_delivery = self.presentation_delivery.summary();
        let presentation_to_submit = self.presentation_to_submit.summary();
        let submit_to_presentation = self.submit_to_presentation.summary();
        let target_to_presentation = self.target_to_presentation.summary();
        let presentation_interval = self.presentation_interval.summary();
        let deadline_to_ready = self.deadline_to_ready.summary();
        let deadline_to_fence = self.deadline_to_fence.summary();
        let deadline_to_submit = self.deadline_to_submit.summary();
        let deadline_to_presentation = self.deadline_to_presentation.summary();
        let per_output_timing = self.per_output_timing_description();

        info!(
            target: "deniald::render_audit",
            source = "output_scheduler",
            interval_ms = elapsed.as_secs_f64() * 1_000.0,
            ready_published = self.ready_published,
            ready_with_fence = self.ready_with_fence,
            fence_signals = self.fence_signals,
            real_submissions = self.real_submissions,
            volition_scheduled_submissions = self.volition_scheduled_submissions,
            presentations = self.presentations,
            sequence_samples = self.sequence_samples,
            sequence_delta_avg = if self.sequence_samples == 0 {
                0.0
            } else {
                self.sequence_delta_total as f64 / self.sequence_samples as f64
            },
            sequence_delta_max = self.sequence_delta_max,
            missed_vblanks = self.missed_vblanks,
            stale_ready_drops = self.stale_ready_drops,
            per_output_timing = %per_output_timing,
            ready_to_fence_avg_us = ready_to_fence.average_us,
            ready_to_fence_p95_us = ready_to_fence.p95_us,
            ready_to_fence_p99_us = ready_to_fence.p99_us,
            ready_to_fence_max_us = ready_to_fence.max_us,
            fence_to_submit_avg_us = fence_to_submit.average_us,
            fence_to_submit_p95_us = fence_to_submit.p95_us,
            fence_to_submit_p99_us = fence_to_submit.p99_us,
            fence_to_submit_max_us = fence_to_submit.max_us,
            ready_to_submit_avg_us = ready_to_submit.average_us,
            ready_to_submit_p95_us = ready_to_submit.p95_us,
            ready_to_submit_p99_us = ready_to_submit.p99_us,
            ready_to_submit_max_us = ready_to_submit.max_us,
            render_to_publish_avg_us = render_to_publish.average_us,
            render_to_publish_p95_us = render_to_publish.p95_us,
            render_to_publish_p99_us = render_to_publish.p99_us,
            render_to_publish_max_us = render_to_publish.max_us,
            presentation_delivery_avg_us = presentation_delivery.average_us,
            presentation_delivery_p95_us = presentation_delivery.p95_us,
            presentation_delivery_p99_us = presentation_delivery.p99_us,
            presentation_delivery_max_us = presentation_delivery.max_us,
            presentation_to_submit_avg_us = presentation_to_submit.average_us,
            presentation_to_submit_p95_us = presentation_to_submit.p95_us,
            presentation_to_submit_p99_us = presentation_to_submit.p99_us,
            presentation_to_submit_max_us = presentation_to_submit.max_us,
            submit_to_presentation_avg_us = submit_to_presentation.average_us,
            submit_to_presentation_p95_us = submit_to_presentation.p95_us,
            submit_to_presentation_p99_us = submit_to_presentation.p99_us,
            submit_to_presentation_max_us = submit_to_presentation.max_us,
            target_to_presentation_avg_us = target_to_presentation.average_us,
            target_to_presentation_p50_us = target_to_presentation.p50_us,
            target_to_presentation_p95_us = target_to_presentation.p95_us,
            target_to_presentation_p99_us = target_to_presentation.p99_us,
            target_to_presentation_max_us = target_to_presentation.max_us,
            presentation_interval_avg_us = presentation_interval.average_us,
            presentation_interval_p50_us = presentation_interval.p50_us,
            presentation_interval_p95_us = presentation_interval.p95_us,
            presentation_interval_p99_us = presentation_interval.p99_us,
            presentation_interval_max_us = presentation_interval.max_us,
            deadline_to_ready_avg_us = deadline_to_ready.average_us,
            deadline_to_ready_p50_us = deadline_to_ready.p50_us,
            deadline_to_ready_p95_us = deadline_to_ready.p95_us,
            deadline_to_ready_p99_us = deadline_to_ready.p99_us,
            deadline_to_ready_max_us = deadline_to_ready.max_us,
            deadline_to_fence_avg_us = deadline_to_fence.average_us,
            deadline_to_fence_p50_us = deadline_to_fence.p50_us,
            deadline_to_fence_p95_us = deadline_to_fence.p95_us,
            deadline_to_fence_p99_us = deadline_to_fence.p99_us,
            deadline_to_fence_max_us = deadline_to_fence.max_us,
            deadline_to_submit_avg_us = deadline_to_submit.average_us,
            deadline_to_submit_p50_us = deadline_to_submit.p50_us,
            deadline_to_submit_p95_us = deadline_to_submit.p95_us,
            deadline_to_submit_p99_us = deadline_to_submit.p99_us,
            deadline_to_submit_max_us = deadline_to_submit.max_us,
            deadline_to_presentation_avg_us = deadline_to_presentation.average_us,
            deadline_to_presentation_p50_us = deadline_to_presentation.p50_us,
            deadline_to_presentation_p95_us = deadline_to_presentation.p95_us,
            deadline_to_presentation_p99_us = deadline_to_presentation.p99_us,
            deadline_to_presentation_max_us = deadline_to_presentation.max_us,
            "Denial/Volition output scheduler audit"
        );

        self.interval_started = Instant::now();
        self.ready_published = 0;
        self.ready_with_fence = 0;
        self.fence_signals = 0;
        self.real_submissions = 0;
        self.volition_scheduled_submissions = 0;
        self.presentations = 0;
        self.sequence_samples = 0;
        self.sequence_delta_total = 0;
        self.sequence_delta_max = 0;
        self.missed_vblanks = 0;
        self.stale_ready_drops = 0;
        self.missed_vblanks_by_output.fill(0);
        self.ready_to_fence = AuditLatency::default();
        self.fence_to_submit = AuditLatency::default();
        self.ready_to_submit = AuditLatency::default();
        self.render_to_publish = AuditLatency::default();
        self.presentation_delivery = AuditLatency::default();
        self.presentation_to_submit = AuditLatency::default();
        self.submit_to_presentation = AuditLatency::default();
        self.target_to_presentation = AuditLatency::default();
        self.presentation_interval = AuditLatency::default();
        self.deadline_to_ready = AuditLatency::default();
        self.deadline_to_fence = AuditLatency::default();
        self.deadline_to_submit = AuditLatency::default();
        self.deadline_to_presentation = AuditLatency::default();
        for latency in &mut self.target_to_presentation_by_output {
            *latency = AuditLatency::default();
        }
        for latency in &mut self.deadline_to_presentation_by_output {
            *latency = AuditLatency::default();
        }
        for latency in &mut self.presentation_interval_by_output {
            *latency = AuditLatency::default();
        }
    }
}

pub(super) struct OutputScheduler {
    volition: Volition,
    pipelines: Vec<OutputPipeline>,
    /// Outputs whose KMS commit succeeded in the current submit pass. Keeping
    /// this allocation lets the Wayland frontend route every window once and
    /// flush clients once, even when one raster batch touches several CRTCs.
    submitted_outputs: Vec<OutputId>,
    /// Page flips retired by one calloop dispatch, published to Wayland as one
    /// batch so Space refresh and socket flushing do not scale with outputs.
    presented_outputs: Vec<PresentedOutput>,
    /// One Flutter render fence per native output slot. Pipelines borrow it only
    /// for their synchronous atomic ioctl; no Arc allocation or refcount is
    /// needed to fan a frame out across independently clocked outputs.
    ready_fences: Vec<OutputReadyFences>,
    audit_stride: usize,
    audit: Option<OutputSchedulerAudit>,
    /// Buffer ownership retained while every physical output is DPMS-off.
    /// Flutter's independent-scanout broker requires one initial owner, and
    /// parking it also gives the first waking output a truthful framebuffer.
    parked: Vec<(OutputId, usize)>,
    presented_frames: u64,
}

impl OutputScheduler {
    pub(super) fn new(
        drm: &DrmDevice,
        volition_events: EventSender<volition::Event>,
        scanouts: &[Scanout],
        swapchains: &OutputSwapchains,
        runtime: &mut FlutterRuntime,
        events: &mut RuntimeState,
    ) -> Result<Self, Box<dyn Error>> {
        let powered_outputs = scanouts.iter().filter(|scanout| scanout.powered).count();
        runtime.enable_kms_frame_clock();
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
                let pool = swapchains
                    .for_output(scanout.output.id)
                    .ok_or("output scheduler has no native framebuffer pool")?;
                Ok(OutputPipeline {
                    output_id: scanout.output.id,
                    scanout_index,
                    scanning: pool.current,
                    scanning_screenshot_request_id: None,
                    frames: OutputPipelineFrames::default(),
                    powering_off: false,
                    request: plane_commit(scanout, pool.size)?,
                })
            })
            .collect::<Result<Vec<_>, Box<dyn Error>>>()?;
        let parked = scanouts
            .iter()
            .filter(|scanout| !scanout.powered)
            .map(|scanout| {
                swapchains
                    .for_output(scanout.output.id)
                    .map(|pool| (scanout.output.id, pool.current))
                    .ok_or("powered-off output has no native framebuffer pool")
            })
            .collect::<Result<Vec<_>, _>>()?;
        let audit_stride = swapchains
            .outputs
            .iter()
            .map(|pool| pool.buffers.len())
            .max()
            .unwrap_or(1);
        let ready_fences = swapchains
            .outputs
            .iter()
            .map(|pool| OutputReadyFences {
                output_id: pool.output_id,
                render_view_id: pool.render_view_id,
                configuration_generation: pool.configuration_generation,
                size: pool.size,
                slots: std::iter::repeat_with(ReadyFenceSlot::default)
                    .take(pool.buffers.len())
                    .collect(),
            })
            .collect();
        events.pending.clear();
        events.completed_page_flips.clear();
        if powered_outputs > 0 {
            info!(
                powered_outputs,
                pool_outputs = scanouts.len(),
                "enabled native output pipelines"
            );
        } else {
            info!(
                pool_outputs = scanouts.len(),
                "parked native output buffers while every output is powered off"
            );
        }
        let audit = render_audit_enabled().then(|| {
            OutputSchedulerAudit::new(
                audit_stride * scanouts.len(),
                pipelines
                    .iter()
                    .map(|pipeline| pipeline.output_id)
                    .collect(),
            )
        });
        Ok(Self {
            volition: presentation,
            pipelines,
            submitted_outputs: Vec::with_capacity(scanouts.len()),
            presented_outputs: Vec::with_capacity(scanouts.len()),
            ready_fences,
            audit_stride,
            audit,
            parked,
            presented_frames: 0,
        })
    }

    pub(super) fn publish_ready(
        &mut self,
        runtime: &FlutterRuntime,
        output: ReadyOutputFrame,
    ) -> Result<Option<ReadyFenceWatch>, Box<dyn Error>> {
        let fence_pool_index = self
            .ready_fences
            .iter()
            .position(|pool| pool.output_id == output.output_id)
            .ok_or("Flutter published a frame for an unknown output")?;
        let pool = &self.ready_fences[fence_pool_index];
        if output.configuration_generation == 0
            || output.configuration_generation != pool.configuration_generation
            || output.render_view_id != pool.render_view_id
            || !output
                .damage
                .matches_size(pool.size.width, pool.size.height)
            || pool
                .slots
                .get(output.index)
                .is_none_or(|slot| !slot.is_available())
            || output.request.tick.output != output.output_id
            || output.request.tick.presentation_target
                != output.request.tick.render_deadline + output.request.tick.interval
        {
            return Err("Flutter output metadata does not match its native pool".into());
        }
        if self
            .pipelines
            .iter()
            .find(|pipeline| pipeline.output_id == output.output_id)
            .is_some_and(|pipeline| !pipeline.frames.render_available())
        {
            return Err("cannot replace an unconsumed Flutter output frame".into());
        }

        let pipeline_index = self
            .pipelines
            .iter()
            .position(|pipeline| pipeline.output_id == output.output_id && !pipeline.powering_off);
        let token = next_ready_fence_token();
        let watch = output
            .fence
            .as_ref()
            .map(|fence| fence.as_fd().try_clone_to_owned())
            .transpose()?
            .map(|fence| ReadyFenceWatch {
                fence,
                signal: ReadyFenceSignal {
                    output: output.output_id,
                    index: output.index,
                    token,
                },
            });

        runtime.publish_output(&output)?;
        let ReadyOutputFrame {
            output_id,
            render_view_id: _,
            configuration_generation: _,
            index,
            fence,
            damage: _,
            screenshot_request_id,
            rendered_at,
            request,
        } = output;
        if let Some(audit) = self.audit.as_mut() {
            let audit_index = fence_pool_index * self.audit_stride + index;
            audit.record_ready(
                audit_index,
                token,
                fence.is_some(),
                rendered_at,
                request.tick.render_deadline,
            );
        }

        let slot = &mut self.ready_fences[fence_pool_index].slots[index];
        slot.claim(fence, 1, token)
            .expect("prevalidated Flutter fence slot changed during publication");
        if let Some(pipeline_index) = pipeline_index {
            let pipeline = &mut self.pipelines[pipeline_index];
            pipeline
                .frames
                .install_ready(OutputFrame {
                    index,
                    screenshot_request_id,
                    request,
                    submitted_at: Instant::now(),
                })
                .expect("prevalidated output Ready slot changed during publication");
        } else if slot.signaled {
            runtime.release_output(output_id, index)?;
            slot.release_user()?;
        } else {
            slot.discard_user_when_signaled()?;
        }
        Ok(watch)
    }

    pub(super) fn acknowledge_ready_fences(
        &mut self,
        runtime: &FlutterRuntime,
        signals: impl IntoIterator<Item = ReadyFenceSignal>,
    ) -> Result<(), Box<dyn Error>> {
        for signal in signals {
            let Some(pool_index) = self
                .ready_fences
                .iter()
                .position(|pool| pool.output_id == signal.output)
            else {
                continue;
            };
            let audit_index = pool_index * self.audit_stride + signal.index;
            if let Some(audit) = self.audit.as_mut() {
                audit.record_fence_signal(audit_index, signal.token);
            }
            if let Some(slot) = self.ready_fences[pool_index].slots.get_mut(signal.index) {
                let signaled = slot.mark_signaled(signal.token);
                if signaled {
                    let discard_users = slot.discard_users_on_signal;
                    slot.discard_users_on_signal = 0;
                    for _ in 0..discard_users {
                        runtime.release_output(signal.output, signal.index)?;
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
                        .position(|pipeline| pipeline.frames.scheduled_commit() == Some(commit))
                        .ok_or("Volition accepted a commit with no pending output frame")?;
                    let output_id = self.pipelines[pipeline_index].output_id;
                    let frame_index = self.pipelines[pipeline_index]
                        .frames
                        .acknowledge_submission(commit, submitted_at)?;
                    let audit_buffer_index = self
                        .ready_fences
                        .iter()
                        .position(|pool| pool.output_id == output_id)
                        .ok_or("submitted output lost its render-fence pool")?
                        * self.audit_stride
                        + frame_index;
                    let scanout = &scanouts[self.pipelines[pipeline_index].scanout_index];
                    events.pending.insert(scanout.output.crtc);
                    if let Some(audit) = self.audit.as_mut() {
                        audit.record_real_submission(
                            pipeline_index,
                            audit_buffer_index,
                            submitted_at,
                        );
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
        swapchains: &OutputSwapchains,
    ) -> Result<(), Box<dyn Error>> {
        let (pipelines, ready_fences, presentation) = (
            &mut self.pipelines,
            &mut self.ready_fences,
            &mut self.volition,
        );
        for (pipeline_index, pipeline) in pipelines.iter_mut().enumerate() {
            if pipeline.powering_off
                || pipeline.frames.in_flight.is_some()
                || pipeline.frames.ready.is_none()
            {
                continue;
            }
            let frame = pipeline
                .frames
                .ready
                .as_ref()
                .expect("checked ready output frame");
            let frame_index = frame.index;
            let fence_pool_index = ready_fences
                .iter()
                .position(|pool| pool.output_id == pipeline.output_id)
                .ok_or("output pipeline lost its render-fence pool")?;
            let ready_fence = ready_fences[fence_pool_index]
                .slots
                .get_mut(frame_index)
                .ok_or("ready frame exceeds its output fence pool")?;
            if !ready_fence.signaled {
                // Volition enters KMS close to the timeline target without an
                // input fence, so rendering must be complete before the frame
                // crosses this ownership boundary.
                continue;
            }
            let framebuffer = swapchains
                .framebuffer(pipeline.output_id, frame_index)
                .ok_or("ready frame exceeds its native output pool")?;
            let commit = CommitId {
                stream: pipeline_index,
                frame: frame_index,
            };
            let submission = presentation.submit_for_target(
                commit,
                &pipeline.request,
                framebuffer,
                frame.request.tick.presentation_target,
            )?;
            if submission == Submission::Queued {
                pipeline.frames.schedule_ready(commit)?;
                ready_fence.release_user()?;
                if ready_fence.users == 0 {
                    debug_assert!(ready_fence.fence.is_none());
                }
            }
        }
        Ok(())
    }

    /// The per-output pipeline is the sole authority for successor production.
    /// An output may raster one following frame only while it has no completed
    /// successor waiting for Volition. A scheduled or submitted generation does
    /// not block raster: the third pool entry is reserved for that lookahead.
    pub(super) fn render_available(&self, output: OutputId) -> bool {
        self.pipelines.iter().any(|pipeline| {
            pipeline.output_id == output
                && !pipeline.powering_off
                && pipeline.frames.render_available()
        })
    }

    /// A frame already completed by Flutter must always be drained when an
    /// output disappeared or entered power-off, so its buffer can be released.
    /// Active outputs accept it only when their unique Ready slot is empty.
    pub(super) fn ready_handoff_available(&self, output: OutputId) -> bool {
        self.pipelines
            .iter()
            .find(|pipeline| pipeline.output_id == output)
            .is_none_or(|pipeline| pipeline.powering_off || pipeline.frames.render_available())
    }

    pub(super) fn handle_completions(
        &mut self,
        runtime: &mut FlutterRuntime,
        swapchains: &mut OutputSwapchains,
        scanouts: &[Scanout],
        events: &mut RuntimeState,
    ) -> Result<(), Box<dyn Error>> {
        self.handle_completions_inner(runtime, swapchains, scanouts, events)
    }

    pub(super) fn retire_completions_for_shutdown(
        &mut self,
        runtime: &mut FlutterRuntime,
        swapchains: &mut OutputSwapchains,
        scanouts: &[Scanout],
        events: &mut RuntimeState,
    ) -> Result<(), Box<dyn Error>> {
        self.handle_completions_inner(runtime, swapchains, scanouts, events)?;
        Ok(())
    }

    fn handle_completions_inner(
        &mut self,
        runtime: &mut FlutterRuntime,
        swapchains: &mut OutputSwapchains,
        scanouts: &[Scanout],
        events: &mut RuntimeState,
    ) -> Result<(), Box<dyn Error>> {
        self.presented_outputs.clear();
        let mut processing_error = None;
        // Process only the completions present when this pass began. A
        // completion deferred behind Volition's independent Submitted channel
        // must remain queued for the next calloop dispatch instead of being
        // popped and retried forever in this pass.
        let queued_completions = events.completed_page_flips.len();
        for _ in 0..queued_completions {
            let completion = events
                .completed_page_flips
                .pop_front()
                .expect("counted page-flip completion disappeared");
            let Some(pipeline_index) = self.pipelines.iter().position(|pipeline| {
                scanouts[pipeline.scanout_index].output.crtc == completion.crtc
            }) else {
                continue;
            };
            let pipeline = &mut self.pipelines[pipeline_index];
            let presented = match pipeline.frames.retire_completion() {
                CompletionRetirement::Retired(frame) => frame,
                CompletionRetirement::Deferred => {
                    events.completed_page_flips.push_back(completion);
                    continue;
                }
                CompletionRetirement::Stale => continue,
            };
            events.pending.remove(&completion.crtc);
            let previous = pipeline.scanning;
            pipeline.scanning = presented.index;
            pipeline.scanning_screenshot_request_id = presented.screenshot_request_id;
            if let Err(error) = runtime.release_output(pipeline.output_id, previous) {
                processing_error = Some(error);
                break;
            }
            swapchains.present(pipeline.output_id, presented.index)?;

            // A missed edge can leave the already-rendered successor targeting
            // the edge which just completed.  Submitting that generation now
            // would miss again and keep a one-frame-late stream permanently
            // serialized.  Drop only the unreachable off-screen successor so
            // the due output tick can render directly for the next edge.
            if pipeline
                .frames
                .ready
                .as_ref()
                .is_some_and(|ready| ready_target_elapsed(ready, completion.observed_at))
            {
                let stale = pipeline
                    .frames
                    .take_ready()
                    .expect("checked elapsed output successor disappeared");
                let fences = self
                    .ready_fences
                    .iter_mut()
                    .find(|pool| pool.output_id == pipeline.output_id)
                    .ok_or("elapsed output successor lost its render-fence pool")?;
                discard_ready_frame(runtime, pipeline.output_id, &mut fences.slots, stale)?;
                if let Some(audit) = self.audit.as_mut() {
                    audit.stale_ready_drops = audit.stale_ready_drops.saturating_add(1);
                }
            }

            let presentation = PresentedOutput {
                id: scanouts[pipeline.scanout_index].output.id,
                observed_at: completion.observed_at,
                presented_at: completion.presented_at,
                sequence: completion.sequence,
                timeline_target: presented.request.tick.presentation_target,
            };
            if let Some(audit) = self.audit.as_mut() {
                audit.record_presentation(
                    pipeline_index,
                    completion.observed_at,
                    presented.request.tick.render_deadline,
                    presented.request.tick.presentation_target,
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

    pub(super) fn process_screencopies_at_tick(
        &self,
        tick: FrameTick,
        runtime: &FlutterRuntime,
        swapchains: &OutputSwapchains,
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
        let timestamp = frontend.screencopy_clock_now();
        let buffer = swapchains
            .for_output(tick.output)
            .and_then(|pool| pool.buffers.get(buffer_index))
            .ok_or("screencopy output buffer exceeds its native pool")?;
        frontend.process_screencopies(&buffer.dmabuf, tick.output, timestamp, || {
            runtime.retain_output(tick.output, buffer_index)
        })
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
            .any(|pipeline| pipeline.frames.submitted().is_some())
    }

    /// Reports a commit which entered KMS but produced no page-flip event.
    /// The compositor can then drop every DRM/render fd and let its supervisor
    /// start a fresh graphics stack instead of displaying one frozen frame.
    pub(super) fn presentation_stall(&self, now: Instant) -> Option<PresentationStall> {
        self.pipelines.iter().find_map(|pipeline| {
            let frame = pipeline.frames.submitted()?;
            let elapsed = presentation_stall_age(frame.submitted_at, now)?;
            Some(PresentationStall {
                scanout_index: pipeline.scanout_index,
                framebuffer_index: frame.index,
                pending_frames: 1,
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
            .filter_map(|pipeline| pipeline.frames.submitted())
            .map(|frame| presentation_watchdog_remaining(frame.submitted_at, now))
            .fold(timeout, Duration::min)
    }

    pub(super) fn shutdown_volition(&mut self) {
        self.volition.shutdown();
    }

    pub(super) fn has_pending_scanout_work(&self) -> bool {
        self.pipelines
            .iter()
            .any(|pipeline| pipeline.frames.has_work())
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
        if let Some(ready) = pipeline.frames.take_ready() {
            let fences = self
                .ready_fences
                .iter_mut()
                .find(|pool| pool.output_id == output)
                .ok_or("power-off output lost its render-fence pool")?;
            discard_ready_frame(runtime, output, &mut fences.slots, ready)?;
        }
        let submitted = pipeline.frames.in_flight.is_some();
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
        if self.pipelines[index].frames.in_flight.is_some() {
            return Err("cannot power off an output with pending scanout work".into());
        }

        let mut pipeline = self.pipelines.remove(index);
        if let Some(ready) = pipeline.frames.take_ready() {
            let fences = self
                .ready_fences
                .iter_mut()
                .find(|pool| pool.output_id == output)
                .ok_or("power-off output lost its render-fence pool")?;
            discard_ready_frame(runtime, output, &mut fences.slots, ready)?;
        }
        self.parked.push((output, pipeline.scanning));
        Ok(())
    }

    pub(super) fn stable_framebuffer_index(&self, output: OutputId) -> Option<usize> {
        self.pipelines
            .iter()
            .find(|pipeline| pipeline.output_id == output)
            .map(|pipeline| pipeline.scanning)
            .or_else(|| {
                self.parked
                    .iter()
                    .find_map(|(candidate, index)| (*candidate == output).then_some(*index))
            })
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
        swapchains: &OutputSwapchains,
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

        let parked = self
            .parked
            .iter()
            .position(|(candidate, index)| {
                *candidate == output.output.id && *index == framebuffer_index
            })
            .ok_or("DPMS wake disagrees with the parked output buffer")?;
        self.parked.swap_remove(parked);
        let pool = swapchains
            .for_output(output.output.id)
            .ok_or("DPMS wake output has no native framebuffer pool")?;
        if pool.current != framebuffer_index {
            return Err("DPMS wake pool disagrees with scheduler scanout".into());
        }
        self.pipelines.push(OutputPipeline {
            output_id: output.output.id,
            scanout_index,
            scanning: framebuffer_index,
            scanning_screenshot_request_id: None,
            frames: OutputPipelineFrames::default(),
            powering_off: false,
            request: plane_commit(output, pool.size)?,
        });
        let _ = runtime;
        Ok(())
    }

    /// Establishes an idle ownership boundary before replacing render pools
    /// or their Flutter runtime. Each output keeps its own current native
    /// framebuffer; the topology transaction snapshots those exact states for
    /// rollback instead of forcing all outputs through a convergence frame.
    pub(super) fn prepare_reconfiguration(
        &mut self,
        scanouts: &[Scanout],
        events: &mut RuntimeState,
    ) -> Result<(), Box<dyn Error>> {
        if self.has_pending_scanout_work() {
            return Err("cannot converge outputs while a frame is ready or submitted".into());
        }
        if self.pipelines.len() != scanouts.iter().filter(|scanout| scanout.powered).count() {
            return Err("output scheduler topology no longer matches KMS scanouts".into());
        }

        if self.pipelines.is_empty() {
            events.pending.clear();
            events.completed_page_flips.clear();
            return Ok(());
        }
        events.pending.clear();
        events.completed_page_flips.clear();
        Ok(())
    }

    pub(super) fn presented_frames(&self) -> u64 {
        self.presented_frames
    }

    pub(super) fn presented_outputs(&self) -> &[PresentedOutput] {
        &self.presented_outputs
    }
}

#[cfg(test)]
#[path = "output_scheduler/tests.rs"]
mod tests;
