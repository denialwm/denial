//! The mixed-refresh frame pipeline.
//!
//! App buffers and Flutter only set pending state. They never create a frame.
//! Every powered output owns one timeline for Wayland callbacks, raster
//! deadlines, and presentation targets. The fastest powered output is also the
//! sole clock for the one Dart scene; slower outputs directly replay its latest
//! retained projection. Physical presentations never authorize rendering;
//! monotonic KMS timestamps only apply a bounded phase correction to a future
//! edge of the same output timeline. All due outputs are coalesced into one
//! linear decision:
//!
//! `output timelines -> client callbacks`
//! `due dirty outputs -> Skip | Render`

use std::collections::{BTreeMap, BTreeSet};
use std::time::{Duration, Instant};

use denial_core::topology::OutputId;
use smithay::output::Mode as OutputMode;
use tracing::info;

use super::kms_state::Scanout;

const FRAME_SCHEDULER_AUDIT_INTERVAL: Duration = Duration::from_secs(1);
const PHASE_LOCK_DEADBAND: Duration = Duration::from_micros(50);
const PHASE_LOCK_MAX_ADJUSTMENT: Duration = Duration::from_micros(250);
const PHASE_LOCK_GAIN_DIVISOR: i128 = 8;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct FrameTick {
    pub(super) output: OutputId,
    pub(super) sequence: u64,
    pub(super) interval: Duration,
    pub(super) render_deadline: Instant,
    pub(super) presentation_target: Instant,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(super) struct PendingFrame {
    pub(super) flutter_requested: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum FrameAction {
    Skip,
    Render { flutter_output: Option<OutputId> },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct OutputFrameRequest {
    pub(super) tick: FrameTick,
    pub(super) dirty_serial: u64,
}

#[derive(Debug, Default)]
struct DirtyOutput {
    serial: u64,
    texture_ids: BTreeSet<i64>,
}

#[derive(Debug)]
pub(super) struct FrameScheduler {
    outputs: OutputTimelines,
    configured_outputs: BTreeSet<OutputId>,
    dirty_outputs: BTreeMap<OutputId, DirtyOutput>,
    render_requests: Vec<OutputFrameRequest>,
    render_texture_ids: BTreeSet<i64>,
    available_outputs: Vec<OutputId>,
    next_dirty_serial: u64,
    flutter_request_latched: bool,
    flutter_outputs_dirty: bool,
    flutter_tick: Option<FrameTick>,
    last_flutter_target: Option<Instant>,
    audit: Option<FrameSchedulerAudit>,
}

#[derive(Debug)]
struct FrameSchedulerAudit {
    interval_started: Instant,
    dirty_updates: u64,
    output_ticks: u64,
    dirty_output_ticks: u64,
    unavailable_output_ticks: u64,
    render_requests: u64,
}

impl FrameSchedulerAudit {
    fn new() -> Self {
        Self {
            interval_started: Instant::now(),
            dirty_updates: 0,
            output_ticks: 0,
            dirty_output_ticks: 0,
            unavailable_output_ticks: 0,
            render_requests: 0,
        }
    }

    fn record_step(&mut self, output_ticks: usize, dirty_ticks: usize, unavailable_ticks: usize) {
        self.output_ticks = self.output_ticks.saturating_add(output_ticks as u64);
        self.dirty_output_ticks = self.dirty_output_ticks.saturating_add(dirty_ticks as u64);
        self.unavailable_output_ticks = self
            .unavailable_output_ticks
            .saturating_add(unavailable_ticks as u64);
    }

    fn maybe_report(&mut self) {
        let elapsed = self.interval_started.elapsed();
        if elapsed < FRAME_SCHEDULER_AUDIT_INTERVAL {
            return;
        }
        info!(
            target: "deniald::render_audit",
            source = "frame_scheduler",
            interval_ms = elapsed.as_secs_f64() * 1_000.0,
            dirty_updates = self.dirty_updates,
            output_ticks = self.output_ticks,
            dirty_output_ticks = self.dirty_output_ticks,
            unavailable_output_ticks = self.unavailable_output_ticks,
            render_requests = self.render_requests,
            "Denial output-timeline decision audit"
        );
        self.interval_started = Instant::now();
        self.dirty_updates = 0;
        self.output_ticks = 0;
        self.dirty_output_ticks = 0;
        self.unavailable_output_ticks = 0;
        self.render_requests = 0;
    }
}

impl FrameScheduler {
    pub(super) fn new(scanouts: &[Scanout], now: Instant) -> Self {
        Self {
            outputs: OutputTimelines::new(scanouts, now),
            configured_outputs: scanouts.iter().map(|scanout| scanout.output.id).collect(),
            dirty_outputs: BTreeMap::new(),
            render_requests: Vec::with_capacity(scanouts.len()),
            render_texture_ids: BTreeSet::new(),
            available_outputs: Vec::with_capacity(scanouts.len()),
            next_dirty_serial: 0,
            flutter_request_latched: false,
            flutter_outputs_dirty: false,
            flutter_tick: None,
            last_flutter_target: None,
            audit: super::render_audit_enabled().then(FrameSchedulerAudit::new),
        }
    }

    pub(super) fn reconfigure(&mut self, scanouts: &[Scanout], now: Instant) {
        let configured_outputs = scanouts.iter().map(|scanout| scanout.output.id).collect();
        let powered_sources = scanouts
            .iter()
            .filter(|scanout| scanout.powered)
            .map(timeline_source)
            .collect();
        self.reconfigure_sources(configured_outputs, powered_sources, now);
    }

    fn reconfigure_sources(
        &mut self,
        configured_outputs: BTreeSet<OutputId>,
        powered_sources: Vec<TimelineSource>,
        now: Instant,
    ) {
        let activated_outputs = powered_sources
            .iter()
            .filter(|source| !self.outputs.contains(source.output))
            .map(|source| source.output)
            .collect::<Vec<_>>();
        self.configured_outputs = configured_outputs;
        self.outputs.reconfigure(&powered_sources, now);
        self.dirty_outputs
            .retain(|output, _| self.configured_outputs.contains(output));
        for output in activated_outputs {
            // The stable framebuffer restored by DPMS may predate a source
            // already queued while this output was parked. Force one fresh
            // projection even when no client submits another buffer after
            // wake; any retained texture damage remains attached below.
            self.mark_output_dirty(output);
        }
        if self.outputs.is_parked() {
            self.flutter_request_latched = false;
            self.flutter_outputs_dirty = false;
            self.flutter_tick = None;
        }
    }

    pub(super) fn mark_app_dirty(
        &mut self,
        output: OutputId,
        texture_ids: impl IntoIterator<Item = i64>,
    ) {
        if !self.configured_outputs.contains(&output) {
            return;
        }
        let serial = self.allocate_dirty_serial();
        let dirty = self.dirty_outputs.entry(output).or_default();
        dirty.serial = serial;
        dirty.texture_ids.extend(texture_ids);
        if let Some(audit) = self.audit.as_mut() {
            audit.dirty_updates = audit.dirty_updates.saturating_add(1);
        }
    }

    pub(super) fn mark_output_dirty(&mut self, output: OutputId) {
        self.mark_app_dirty(output, std::iter::empty());
    }

    pub(super) fn mark_all_dirty(&mut self) {
        for index in 0..self.outputs.timelines.len() {
            let output = self.outputs.timelines[index].source.output;
            let serial = self.allocate_dirty_serial();
            self.dirty_outputs.entry(output).or_default().serial = serial;
        }
    }

    pub(super) fn complete_render(&mut self, output: OutputId, dirty_serial: u64) {
        if self
            .dirty_outputs
            .get(&output)
            .is_some_and(|dirty| dirty.serial == dirty_serial)
        {
            self.dirty_outputs.remove(&output);
        }
    }

    pub(super) fn observe_presentation(
        &mut self,
        output: OutputId,
        presentation_target: Instant,
        presented_at: Instant,
    ) {
        self.outputs
            .observe_presentation(output, presentation_target, presented_at);
    }

    pub(super) fn flutter_frame_dispatched(&mut self) {
        let tick = self
            .flutter_tick
            .take()
            .expect("a dispatched Flutter frame must retain its clock tick");
        debug_assert!(
            self.last_flutter_target
                .is_none_or(|target| tick.presentation_target > target)
        );
        self.last_flutter_target = Some(tick.presentation_target);
        self.flutter_request_latched = false;
        self.flutter_outputs_dirty = false;
    }

    fn allocate_dirty_serial(&mut self) -> u64 {
        self.next_dirty_serial = self.next_dirty_serial.wrapping_add(1).max(1);
        self.next_dirty_serial
    }

    pub(super) fn step_with_output_availability(
        &mut self,
        now: Instant,
        pending: PendingFrame,
        mut output_available: impl FnMut(OutputId) -> bool,
    ) -> FrameAction {
        if pending.flutter_requested && !self.flutter_request_latched {
            self.flutter_request_latched = true;
        }

        self.outputs.advance(now);
        self.render_requests.clear();
        self.render_texture_ids.clear();
        self.available_outputs.clear();
        self.available_outputs.extend(
            self.outputs
                .ticks()
                .iter()
                .map(|tick| tick.output)
                .filter(|output| output_available(*output)),
        );
        self.flutter_tick = None;
        let flutter_tick = self.outputs.flutter_tick().filter(|tick| {
            self.flutter_request_latched
                && self.available_outputs.contains(&tick.output)
                && self
                    .last_flutter_target
                    .is_none_or(|target| tick.presentation_target > target)
        });
        if flutter_tick.is_some() && !self.flutter_outputs_dirty {
            self.mark_all_dirty();
            self.flutter_outputs_dirty = true;
        }
        let dirty_ticks = self
            .outputs
            .ticks()
            .iter()
            .filter(|tick| self.dirty_outputs.contains_key(&tick.output))
            .count();
        let unavailable_ticks = self
            .outputs
            .ticks()
            .iter()
            .filter(|tick| {
                self.dirty_outputs.contains_key(&tick.output)
                    && !self.available_outputs.contains(&tick.output)
            })
            .count();

        for tick in self.outputs.ticks().iter().copied() {
            if !self.available_outputs.contains(&tick.output) {
                continue;
            }
            let Some(dirty) = self.dirty_outputs.get(&tick.output) else {
                continue;
            };
            self.render_requests.push(OutputFrameRequest {
                tick,
                dirty_serial: dirty.serial,
            });
            self.render_texture_ids
                .extend(dirty.texture_ids.iter().copied());
        }
        if let Some(audit) = self.audit.as_mut() {
            audit.record_step(self.outputs.ticks().len(), dirty_ticks, unavailable_ticks);
            audit.render_requests = audit
                .render_requests
                .saturating_add(self.render_requests.len() as u64);
            audit.maybe_report();
        }

        if self.render_requests.is_empty() {
            FrameAction::Skip
        } else {
            self.flutter_tick = flutter_tick.filter(|tick| {
                self.render_requests
                    .iter()
                    .any(|request| request.tick.output == tick.output)
            });
            FrameAction::Render {
                flutter_output: self.flutter_tick.map(|tick| tick.output),
            }
        }
    }

    pub(super) fn output_ticks(&self) -> &[FrameTick] {
        self.outputs.ticks()
    }

    pub(super) fn output_tick_due(&self, now: Instant) -> bool {
        self.outputs
            .timelines
            .iter()
            .any(|timeline| now >= timeline.next_tick)
    }

    pub(super) fn render_requests(&self) -> &[OutputFrameRequest] {
        &self.render_requests
    }

    pub(super) fn render_texture_ids(&self) -> impl Iterator<Item = i64> + '_ {
        self.render_texture_ids.iter().copied()
    }

    pub(super) fn limit_dispatch_timeout(&self, now: Instant, timeout: Duration) -> Duration {
        self.outputs.limit_dispatch_timeout(now, timeout)
    }
}

#[derive(Debug)]
struct OutputTimelines {
    timelines: Vec<OutputTimeline>,
    ticks: Vec<FrameTick>,
    flutter_output: Option<OutputId>,
}

impl OutputTimelines {
    fn new(scanouts: &[Scanout], now: Instant) -> Self {
        let mut timelines = Self {
            timelines: Vec::with_capacity(scanouts.len()),
            ticks: Vec::with_capacity(scanouts.len()),
            flutter_output: None,
        };
        let powered_sources = scanouts
            .iter()
            .filter(|scanout| scanout.powered)
            .map(timeline_source)
            .collect::<Vec<_>>();
        timelines.replace(&powered_sources, now);
        timelines
    }

    fn reconfigure(&mut self, sources: &[TimelineSource], now: Instant) {
        let sources_match = self.timelines.len() == sources.len()
            && sources.iter().all(|source| {
                self.timelines
                    .iter()
                    .any(|timeline| timeline.source == *source)
            });
        if sources_match {
            return;
        }
        self.replace(sources, now);
    }

    fn replace(&mut self, sources: &[TimelineSource], now: Instant) {
        self.timelines.clear();
        self.timelines.extend(
            sources
                .iter()
                .copied()
                .map(|source| OutputTimeline::new(source, now)),
        );
        self.flutter_output = self
            .timelines
            .iter()
            .map(|timeline| timeline.source)
            .min_by_key(|source| (source.interval, source.output))
            .map(|source| source.output);
        self.ticks.clear();
    }

    fn advance(&mut self, now: Instant) {
        self.ticks.clear();
        for timeline in &mut self.timelines {
            if let Some(tick) = timeline.take_tick(now) {
                self.ticks.push(tick);
            }
        }
    }

    fn ticks(&self) -> &[FrameTick] {
        &self.ticks
    }

    fn flutter_tick(&self) -> Option<FrameTick> {
        let output = self.flutter_output?;
        self.ticks
            .iter()
            .copied()
            .find(|tick| tick.output == output)
    }

    fn is_parked(&self) -> bool {
        self.timelines.is_empty()
    }

    fn contains(&self, output: OutputId) -> bool {
        self.timelines
            .iter()
            .any(|timeline| timeline.source.output == output)
    }

    fn observe_presentation(
        &mut self,
        output: OutputId,
        presentation_target: Instant,
        presented_at: Instant,
    ) {
        if let Some(timeline) = self
            .timelines
            .iter_mut()
            .find(|timeline| timeline.source.output == output)
        {
            timeline.observe_presentation(presentation_target, presented_at);
        }
    }

    fn limit_dispatch_timeout(&self, now: Instant, timeout: Duration) -> Duration {
        self.timelines.iter().fold(timeout, |timeout, timeline| {
            timeout.min(timeline.next_tick.saturating_duration_since(now))
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct TimelineSource {
    output: OutputId,
    interval: Duration,
}

#[derive(Debug)]
struct OutputTimeline {
    source: TimelineSource,
    next_tick: Instant,
    next_sequence: u64,
    pending_phase_adjustment_nanos: i64,
}

impl OutputTimeline {
    fn new(source: TimelineSource, now: Instant) -> Self {
        Self {
            source,
            next_tick: now,
            next_sequence: 1,
            pending_phase_adjustment_nanos: 0,
        }
    }

    fn observe_presentation(&mut self, presentation_target: Instant, presented_at: Instant) {
        let phase_error = nearest_phase_error(
            signed_instant_delta(presented_at, presentation_target),
            self.source.interval,
        );
        if phase_error.unsigned_abs() <= PHASE_LOCK_DEADBAND.as_nanos() {
            return;
        }

        let limit = PHASE_LOCK_MAX_ADJUSTMENT.as_nanos() as i128;
        let correction = (phase_error / PHASE_LOCK_GAIN_DIVISOR).clamp(-limit, limit);
        let pending = i128::from(self.pending_phase_adjustment_nanos) + correction;
        self.pending_phase_adjustment_nanos = pending.clamp(-limit, limit) as i64;
    }

    fn take_tick(&mut self, now: Instant) -> Option<FrameTick> {
        if now < self.next_tick {
            return None;
        }

        let interval_nanos = self.source.interval.as_nanos().max(1);
        let missed_periods =
            now.saturating_duration_since(self.next_tick).as_nanos() / interval_nanos;
        let render_deadline =
            advance_deadline(self.next_tick, self.source.interval, missed_periods);
        let sequence = self.next_sequence.wrapping_add(missed_periods as u64);
        let nominal_next_tick = render_deadline + self.source.interval;
        self.next_tick = shift_instant(
            nominal_next_tick,
            std::mem::take(&mut self.pending_phase_adjustment_nanos),
        );
        self.next_sequence = sequence.wrapping_add(1);
        let presentation_target = self.next_tick;
        Some(FrameTick {
            output: self.source.output,
            sequence,
            interval: presentation_target.saturating_duration_since(render_deadline),
            render_deadline,
            presentation_target,
        })
    }
}

fn signed_instant_delta(lhs: Instant, rhs: Instant) -> i128 {
    if lhs >= rhs {
        lhs.duration_since(rhs).as_nanos() as i128
    } else {
        -(rhs.duration_since(lhs).as_nanos() as i128)
    }
}

fn nearest_phase_error(delta_nanos: i128, interval: Duration) -> i128 {
    let period = interval.as_nanos().max(1) as i128;
    let mut error = delta_nanos % period;
    let half_period = period / 2;
    if error > half_period {
        error -= period;
    } else if error < -half_period {
        error += period;
    }
    error
}

fn shift_instant(instant: Instant, adjustment_nanos: i64) -> Instant {
    if adjustment_nanos >= 0 {
        instant + Duration::from_nanos(adjustment_nanos as u64)
    } else {
        instant - Duration::from_nanos(adjustment_nanos.unsigned_abs())
    }
}

fn advance_deadline(mut deadline: Instant, interval: Duration, mut periods: u128) -> Instant {
    while periods > 0 {
        let chunk = periods.min(u128::from(u32::MAX)) as u32;
        deadline += interval * chunk;
        periods -= u128::from(chunk);
    }
    deadline
}

fn timeline_source(scanout: &Scanout) -> TimelineSource {
    TimelineSource {
        output: scanout.output.id,
        interval: refresh_interval(scanout),
    }
}

fn refresh_interval(scanout: &Scanout) -> Duration {
    let refresh_millihz = u64::try_from(OutputMode::from(scanout.output.mode).refresh)
        .ok()
        .filter(|refresh| *refresh > 0)
        .unwrap_or(60_000);
    Duration::from_nanos(1_000_000_000_000 / refresh_millihz)
}
