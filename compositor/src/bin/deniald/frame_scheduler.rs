//! The mixed-refresh frame pipeline.
//!
//! App buffers and Flutter only set pending state. They never create a frame.
//! Every powered output owns one timeline for Wayland callbacks, raster
//! deadlines, and presentation targets. The fastest powered output is also the
//! sole clock for the one Dart scene; slower outputs directly replay its latest
//! retained projection. Physical presentations are feedback; they never
//! authorize or rephase rendering. All due outputs are coalesced into one
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
        self.outputs.reconfigure(scanouts, now);
        self.dirty_outputs
            .retain(|output, _| self.outputs.contains(*output));
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
        if !self.outputs.contains(output) {
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

    #[cfg(test)]
    fn step(&mut self, now: Instant, pending: PendingFrame) -> FrameAction {
        self.step_with_output_availability(now, pending, |_| true)
    }

    pub(super) fn output_ticks(&self) -> &[FrameTick] {
        self.outputs.ticks()
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
        timelines.replace(scanouts, now);
        timelines
    }

    fn reconfigure(&mut self, scanouts: &[Scanout], now: Instant) {
        let powered_outputs = scanouts.iter().filter(|scanout| scanout.powered).count();
        let sources_match = self.timelines.len() == powered_outputs
            && scanouts
                .iter()
                .filter(|scanout| scanout.powered)
                .map(timeline_source)
                .all(|source| {
                    self.timelines
                        .iter()
                        .any(|timeline| timeline.source == source)
                });
        if sources_match {
            return;
        }
        self.replace(scanouts, now);
    }

    fn replace(&mut self, scanouts: &[Scanout], now: Instant) {
        self.timelines.clear();
        self.timelines.extend(
            scanouts
                .iter()
                .filter(|scanout| scanout.powered)
                .map(|scanout| OutputTimeline::new(timeline_source(scanout), now)),
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
}

impl OutputTimeline {
    fn new(source: TimelineSource, now: Instant) -> Self {
        Self {
            source,
            next_tick: now,
            next_sequence: 1,
        }
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
        self.next_tick = render_deadline + self.source.interval;
        self.next_sequence = sequence.wrapping_add(1);
        Some(FrameTick {
            output: self.source.output,
            sequence,
            interval: self.source.interval,
            render_deadline,
            presentation_target: self.next_tick,
        })
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

#[cfg(test)]
mod tests {
    use super::*;

    const INTERVAL: Duration = Duration::from_millis(10);
    const FAST_INTERVAL: Duration = Duration::from_millis(5);
    const FAST_OUTPUT: OutputId = OutputId(1);
    const SLOW_OUTPUT: OutputId = OutputId(2);

    fn scheduler(now: Instant) -> FrameScheduler {
        scheduler_with_timelines(now, &[(FAST_OUTPUT, INTERVAL)])
    }

    fn mixed_scheduler(now: Instant) -> FrameScheduler {
        scheduler_with_timelines(
            now,
            &[(FAST_OUTPUT, FAST_INTERVAL), (SLOW_OUTPUT, INTERVAL)],
        )
    }

    fn non_harmonic_mixed_scheduler(now: Instant) -> FrameScheduler {
        scheduler_with_timelines(
            now,
            &[
                (FAST_OUTPUT, Duration::from_millis(4)),
                (SLOW_OUTPUT, INTERVAL),
            ],
        )
    }

    fn scheduler_with_timelines(now: Instant, sources: &[(OutputId, Duration)]) -> FrameScheduler {
        let flutter_output = sources
            .iter()
            .copied()
            .min_by_key(|(output, interval)| (*interval, *output))
            .map(|(output, _)| output);
        FrameScheduler {
            outputs: OutputTimelines {
                timelines: sources
                    .iter()
                    .map(|(output, interval)| {
                        OutputTimeline::new(
                            TimelineSource {
                                output: *output,
                                interval: *interval,
                            },
                            now,
                        )
                    })
                    .collect(),
                ticks: Vec::with_capacity(sources.len()),
                flutter_output,
            },
            dirty_outputs: BTreeMap::new(),
            render_requests: Vec::with_capacity(sources.len()),
            render_texture_ids: BTreeSet::new(),
            available_outputs: Vec::with_capacity(sources.len()),
            next_dirty_serial: 0,
            flutter_request_latched: false,
            flutter_outputs_dirty: false,
            flutter_tick: None,
            last_flutter_target: None,
            audit: None,
        }
    }

    fn pending(
        flutter_requested: bool,
        _app_textures_updated: bool,
        _producer_available: bool,
    ) -> PendingFrame {
        PendingFrame { flutter_requested }
    }

    #[test]
    fn idle_display_ticks_without_rendering() {
        let now = Instant::now();
        let mut scheduler = scheduler(now);

        let action = scheduler.step(now, pending(false, false, true));

        assert_eq!(scheduler.output_ticks().len(), 1);
        assert_eq!(action, FrameAction::Skip);
    }

    #[test]
    fn app_or_flutter_events_cannot_create_an_early_tick() {
        let now = Instant::now();
        let mut scheduler = scheduler(now);
        scheduler.step(now, pending(false, false, true));

        let action = scheduler.step(now + Duration::from_millis(1), pending(true, true, true));

        assert!(scheduler.output_ticks().is_empty());
        assert_eq!(action, FrameAction::Skip);
    }

    #[test]
    fn app_damage_waits_for_its_output_tick() {
        let now = Instant::now();
        let mut scheduler = scheduler(now);
        scheduler.step(now, pending(false, false, true));
        scheduler.mark_app_dirty(FAST_OUTPUT, [7]);

        assert_eq!(
            scheduler.step(now + Duration::from_millis(1), pending(false, false, true)),
            FrameAction::Skip
        );
        let render = scheduler.step(now + INTERVAL, pending(false, false, true));

        assert_eq!(
            render,
            FrameAction::Render {
                flutter_output: None
            }
        );
        assert_eq!(scheduler.render_requests().len(), 1);
        assert_eq!(scheduler.render_requests()[0].tick.output, FAST_OUTPUT);
        assert_eq!(scheduler.render_texture_ids().collect::<Vec<_>>(), vec![7]);
    }

    #[test]
    fn flutter_and_texture_damage_share_one_tick() {
        let now = Instant::now();
        let mut scheduler = scheduler(now);
        scheduler.mark_app_dirty(FAST_OUTPUT, [11]);

        let action = scheduler.step(now, pending(true, true, true));

        assert_eq!(
            action,
            FrameAction::Render {
                flutter_output: Some(FAST_OUTPUT)
            }
        );
        assert_eq!(scheduler.render_requests().len(), 1);
        assert_eq!(scheduler.render_texture_ids().collect::<Vec<_>>(), vec![11]);
    }

    #[test]
    fn an_older_completion_cannot_clear_newer_output_damage() {
        let now = Instant::now();
        let mut scheduler = scheduler(now);
        scheduler.mark_app_dirty(FAST_OUTPUT, [7]);
        assert_eq!(
            scheduler.step(now, pending(false, false, true)),
            FrameAction::Render {
                flutter_output: None
            }
        );
        let old_serial = scheduler.render_requests()[0].dirty_serial;

        scheduler.mark_app_dirty(FAST_OUTPUT, [9]);
        scheduler.complete_render(FAST_OUTPUT, old_serial);

        assert!(scheduler.dirty_outputs.contains_key(&FAST_OUTPUT));
        assert_eq!(
            scheduler
                .dirty_outputs
                .get(&FAST_OUTPUT)
                .unwrap()
                .texture_ids
                .iter()
                .copied()
                .collect::<Vec<_>>(),
            vec![7, 9]
        );
    }

    #[test]
    fn the_timeline_keeps_ticking_while_every_producer_is_idle() {
        let now = Instant::now();
        let mut scheduler = scheduler(now);
        scheduler.step(now, pending(false, false, true));

        let action = scheduler.step(now + INTERVAL, pending(false, false, true));

        assert_eq!(scheduler.output_ticks()[0].render_deadline, now + INTERVAL);
        assert_eq!(action, FrameAction::Skip);
    }

    #[test]
    fn an_early_flutter_baton_waits_for_its_output_reservation() {
        let now = Instant::now();
        let mut scheduler = scheduler(now);

        assert_eq!(
            scheduler.step_with_output_availability(now, pending(true, true, false), |_| false),
            FrameAction::Skip
        );
        let action = scheduler.step_with_output_availability(
            now + INTERVAL,
            pending(true, true, true),
            |_| true,
        );

        assert_eq!(
            action,
            FrameAction::Render {
                flutter_output: Some(FAST_OUTPUT)
            }
        );
    }

    #[test]
    fn each_tick_targets_the_following_absolute_edge() {
        let now = Instant::now();
        let mut scheduler = scheduler(now);
        scheduler.step(now + Duration::from_millis(1), pending(false, false, true));

        let tick = scheduler.output_ticks()[0];
        assert_eq!(tick.sequence, 1);
        assert_eq!(tick.render_deadline, now);
        assert_eq!(tick.presentation_target, now + INTERVAL);
    }

    #[test]
    fn missed_intervals_collapse_to_the_latest_tick() {
        let now = Instant::now();
        let mut scheduler = scheduler(now);
        scheduler.step(now, pending(false, false, true));

        scheduler.step(
            now + INTERVAL * 4 + Duration::from_millis(1),
            pending(false, false, true),
        );

        let tick = scheduler.output_ticks()[0];
        assert_eq!(tick.sequence, 5);
        assert_eq!(tick.render_deadline, now + INTERVAL * 4);
        assert_eq!(tick.presentation_target, now + INTERVAL * 5);
    }

    #[test]
    fn mixed_refresh_outputs_tick_at_their_own_rates() {
        let now = Instant::now();
        let mut scheduler = mixed_scheduler(now);
        let mut fast_ticks = 0;
        let mut slow_ticks = 0;

        for step in 0..=4 {
            scheduler.step(now + FAST_INTERVAL * step, pending(false, false, true));
            fast_ticks += scheduler
                .output_ticks()
                .iter()
                .filter(|tick| tick.output == FAST_OUTPUT)
                .count();
            slow_ticks += scheduler
                .output_ticks()
                .iter()
                .filter(|tick| tick.output == SLOW_OUTPUT)
                .count();
        }

        assert_eq!(fast_ticks, 5);
        assert_eq!(slow_ticks, 3);
    }

    #[test]
    fn a_slower_output_cannot_dispatch_the_flutter_frame() {
        let now = Instant::now();
        let mut scheduler = non_harmonic_mixed_scheduler(now);
        scheduler.step(now, pending(false, false, true));
        scheduler.step(now + Duration::from_millis(4), pending(false, false, true));
        scheduler.step(now + Duration::from_millis(8), pending(false, false, true));

        assert_eq!(
            scheduler.step(now + INTERVAL, pending(true, false, true)),
            FrameAction::Skip
        );
        assert!(scheduler.dirty_outputs.is_empty());

        assert_eq!(
            scheduler.step(now + Duration::from_millis(12), pending(true, false, true),),
            FrameAction::Render {
                flutter_output: Some(FAST_OUTPUT)
            }
        );
        assert_eq!(scheduler.render_requests().len(), 1);
        assert_eq!(scheduler.render_requests()[0].tick.output, FAST_OUTPUT);
    }

    #[test]
    fn continuous_flutter_uses_only_the_fastest_output_clock() {
        let now = Instant::now();
        let mut scheduler = non_harmonic_mixed_scheduler(now);
        let mut flutter_targets = Vec::new();
        let mut fast_renders = 0;
        let mut slow_renders = 0;

        for millisecond in 0..=40 {
            let action = scheduler.step(
                now + Duration::from_millis(millisecond),
                pending(true, false, true),
            );
            if let FrameAction::Render { flutter_output } = action {
                let completed = scheduler
                    .render_requests()
                    .iter()
                    .map(|request| (request.tick.output, request.dirty_serial))
                    .collect::<Vec<_>>();
                fast_renders += completed
                    .iter()
                    .filter(|(output, _)| *output == FAST_OUTPUT)
                    .count();
                slow_renders += completed
                    .iter()
                    .filter(|(output, _)| *output == SLOW_OUTPUT)
                    .count();
                for (output, serial) in completed {
                    scheduler.complete_render(output, serial);
                }
                if flutter_output.is_some() {
                    flutter_targets.push(
                        scheduler
                            .flutter_tick
                            .expect("Flutter action retains its tick")
                            .presentation_target,
                    );
                    scheduler.flutter_frame_dispatched();
                }
            }
        }

        assert_eq!(flutter_targets.len(), 11);
        assert_eq!(fast_renders, 11);
        assert_eq!(slow_renders, 5);
        assert!(flutter_targets.windows(2).all(|pair| pair[0] < pair[1]));
    }

    #[test]
    fn changing_the_fastest_output_cannot_move_flutter_time_backwards() {
        let now = Instant::now();
        let mut scheduler = scheduler(now);
        assert_eq!(
            scheduler.step(now, pending(true, false, true)),
            FrameAction::Render {
                flutter_output: Some(FAST_OUTPUT)
            }
        );
        let completed = scheduler.render_requests()[0];
        scheduler.complete_render(completed.tick.output, completed.dirty_serial);
        let first_target = scheduler
            .flutter_tick
            .expect("Flutter action retains its tick")
            .presentation_target;
        scheduler.flutter_frame_dispatched();

        scheduler.outputs = OutputTimelines {
            timelines: vec![OutputTimeline::new(
                TimelineSource {
                    output: FAST_OUTPUT,
                    interval: Duration::from_millis(1),
                },
                now + Duration::from_millis(1),
            )],
            ticks: Vec::with_capacity(1),
            flutter_output: Some(FAST_OUTPUT),
        };

        assert_eq!(
            scheduler.step(now + Duration::from_millis(1), pending(true, false, true),),
            FrameAction::Skip
        );
        assert_eq!(scheduler.last_flutter_target, Some(first_target));

        assert_eq!(
            scheduler.step(now + INTERVAL, pending(true, false, true)),
            FrameAction::Render {
                flutter_output: Some(FAST_OUTPUT)
            }
        );
        assert!(
            scheduler
                .flutter_tick
                .expect("Flutter action retains its tick")
                .presentation_target
                > first_target
        );
    }

    #[test]
    fn each_output_authorizes_only_its_own_dirty_tick() {
        let now = Instant::now();
        let mut scheduler = mixed_scheduler(now);
        scheduler.step(now, pending(false, false, true));
        scheduler.mark_app_dirty(SLOW_OUTPUT, [23]);
        assert_eq!(
            scheduler.step(now + FAST_INTERVAL, pending(false, false, true)),
            FrameAction::Skip
        );

        let action = scheduler.step(now + INTERVAL, pending(false, true, true));

        assert_eq!(scheduler.output_ticks().len(), 2);
        assert_eq!(
            action,
            FrameAction::Render {
                flutter_output: None
            }
        );
        assert_eq!(scheduler.render_requests().len(), 1);
        assert_eq!(scheduler.render_requests()[0].tick.output, SLOW_OUTPUT);
        assert_eq!(scheduler.render_texture_ids().collect::<Vec<_>>(), vec![23]);
    }

    #[test]
    fn unavailable_output_stays_dirty_without_blocking_another_output() {
        let now = Instant::now();
        let mut scheduler = mixed_scheduler(now);
        scheduler.mark_app_dirty(FAST_OUTPUT, [11]);
        scheduler.mark_app_dirty(SLOW_OUTPUT, [22]);

        let action =
            scheduler.step_with_output_availability(now, pending(false, true, true), |output| {
                output == SLOW_OUTPUT
            });
        assert_eq!(
            action,
            FrameAction::Render {
                flutter_output: None
            }
        );
        assert_eq!(scheduler.render_requests().len(), 1);
        assert_eq!(scheduler.render_requests()[0].tick.output, SLOW_OUTPUT);
        let slow = scheduler.render_requests()[0];
        scheduler.complete_render(slow.tick.output, slow.dirty_serial);
        assert!(scheduler.dirty_outputs.contains_key(&FAST_OUTPUT));
        assert!(!scheduler.dirty_outputs.contains_key(&SLOW_OUTPUT));

        let action = scheduler.step_with_output_availability(
            now + FAST_INTERVAL,
            pending(false, false, true),
            |_| true,
        );
        assert_eq!(
            action,
            FrameAction::Render {
                flutter_output: None
            }
        );
        assert_eq!(scheduler.render_requests().len(), 1);
        assert_eq!(scheduler.render_requests()[0].tick.output, FAST_OUTPUT);
    }

    #[test]
    fn unavailable_flutter_clock_defers_scene_damage_until_it_can_render() {
        let now = Instant::now();
        let mut scheduler = mixed_scheduler(now);

        let action =
            scheduler.step_with_output_availability(now, pending(true, false, true), |output| {
                output == SLOW_OUTPUT
            });
        assert_eq!(action, FrameAction::Skip);
        assert!(scheduler.dirty_outputs.is_empty());
        assert!(scheduler.flutter_request_latched);

        let action = scheduler.step_with_output_availability(
            now + FAST_INTERVAL,
            pending(true, false, true),
            |_| true,
        );
        assert_eq!(
            action,
            FrameAction::Render {
                flutter_output: Some(FAST_OUTPUT)
            }
        );
        assert!(scheduler.dirty_outputs.contains_key(&FAST_OUTPUT));
        assert!(scheduler.dirty_outputs.contains_key(&SLOW_OUTPUT));
    }

    #[test]
    fn independent_outputs_can_be_authorized_in_one_raster_queue_batch() {
        let now = Instant::now();
        let mut scheduler = mixed_scheduler(now);
        scheduler.mark_all_dirty();
        assert_eq!(
            scheduler.step(now, pending(false, true, false)),
            FrameAction::Render {
                flutter_output: None
            }
        );
        assert_eq!(scheduler.render_requests().len(), 2);
        assert_eq!(
            scheduler
                .render_requests()
                .iter()
                .map(|request| request.tick.output)
                .collect::<BTreeSet<_>>(),
            BTreeSet::from([FAST_OUTPUT, SLOW_OUTPUT])
        );
    }

    #[test]
    fn powering_off_every_output_drops_stale_dirty_state() {
        let now = Instant::now();
        let mut scheduler = scheduler(now);
        scheduler.mark_app_dirty(FAST_OUTPUT, [9]);

        scheduler.reconfigure(&[], now + Duration::from_millis(1));

        assert_eq!(
            scheduler.step(now + Duration::from_millis(2), pending(true, false, true)),
            FrameAction::Skip
        );
        assert!(scheduler.output_ticks().is_empty());
        assert!(scheduler.dirty_outputs.is_empty());
    }
}
