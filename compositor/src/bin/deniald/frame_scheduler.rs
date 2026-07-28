//! The mixed-refresh frame pipeline.
//!
//! App buffers and Flutter only set pending state. They never create a frame.
//! Every powered output owns a clock for its Wayland frame callbacks. The
//! fastest output is the sole render clock and chooses exactly one action:
//!
//! `output clocks -> client callbacks`
//! `render clock -> pending state -> Skip | RequestFlutter | Render`

use std::time::{Duration, Instant};

use denial_core::topology::OutputId;
use smithay::output::Mode as OutputMode;

use super::PresentedOutput;
use super::kms_state::Scanout;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct FrameTick {
    pub(super) output: OutputId,
    pub(super) interval: Duration,
    pub(super) observed_at: Instant,
    pub(super) presented_at: Option<Duration>,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(super) struct PendingFrame {
    pub(super) flutter_requested: bool,
    pub(super) app_textures_updated: bool,
    pub(super) producer_available: bool,
}

impl PendingFrame {
    fn has_work(self) -> bool {
        self.flutter_requested || self.app_textures_updated
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum FrameAction {
    Skip,
    RequestFlutter,
    Render(FrameTick),
}

#[derive(Debug)]
pub(super) struct FrameScheduler {
    outputs: OutputClocks,
    waiting_for_flutter: Option<FrameTick>,
}

impl FrameScheduler {
    pub(super) fn new(scanouts: &[Scanout], now: Instant) -> Self {
        Self {
            outputs: OutputClocks::new(scanouts, now),
            waiting_for_flutter: None,
        }
    }

    pub(super) fn reconfigure(&mut self, scanouts: &[Scanout], now: Instant) {
        self.outputs.reconfigure(scanouts, now);
        if self.outputs.is_parked() {
            // A texture-only tick may have been waiting for Flutter when the
            // final output powered down. Keep any eventual AwaitVSync baton
            // pending for the first fresh output tick after wake instead of
            // rendering against a clock edge which is no longer visible.
            self.waiting_for_flutter = None;
        }
    }

    pub(super) fn observe_presentation(&mut self, presentation: PresentedOutput) {
        self.outputs.observe_presentation(presentation);
    }

    pub(super) fn step(&mut self, now: Instant, pending: PendingFrame) -> FrameAction {
        let render_tick = self.outputs.advance(now);

        if let Some(authorized_tick) = self.waiting_for_flutter {
            if pending.flutter_requested {
                self.waiting_for_flutter = None;
                return FrameAction::Render(authorized_tick);
            }
            return FrameAction::Skip;
        }

        let Some(authorized_tick) = render_tick else {
            return FrameAction::Skip;
        };
        if !pending.producer_available || !pending.has_work() {
            return FrameAction::Skip;
        }
        if pending.flutter_requested {
            return FrameAction::Render(authorized_tick);
        }

        self.waiting_for_flutter = Some(authorized_tick);
        FrameAction::RequestFlutter
    }

    pub(super) fn output_ticks(&self) -> &[FrameTick] {
        self.outputs.ticks()
    }

    pub(super) fn cancel_flutter_request(&mut self) {
        self.waiting_for_flutter = None;
    }

    pub(super) fn limit_dispatch_timeout(&self, now: Instant, timeout: Duration) -> Duration {
        self.outputs.limit_dispatch_timeout(now, timeout)
    }
}

#[derive(Debug)]
struct OutputClocks {
    clocks: Vec<DisplayClock>,
    ticks: Vec<FrameTick>,
    render_output: Option<OutputId>,
}

impl OutputClocks {
    fn new(scanouts: &[Scanout], now: Instant) -> Self {
        let mut clocks = Self {
            clocks: Vec::with_capacity(scanouts.len()),
            ticks: Vec::with_capacity(scanouts.len()),
            render_output: None,
        };
        clocks.replace(scanouts, now);
        clocks
    }

    fn reconfigure(&mut self, scanouts: &[Scanout], now: Instant) {
        let render_output = render_source(scanouts).map(|source| source.output);
        let powered_outputs = scanouts.iter().filter(|scanout| scanout.powered).count();
        let sources_match = self.clocks.len() == powered_outputs
            && scanouts
                .iter()
                .filter(|scanout| scanout.powered)
                .map(clock_source)
                .all(|source| self.clocks.iter().any(|clock| clock.source == source));
        if sources_match && self.render_output == render_output {
            return;
        }
        self.replace(scanouts, now);
    }

    fn replace(&mut self, scanouts: &[Scanout], now: Instant) {
        self.clocks.clear();
        self.clocks.extend(
            scanouts
                .iter()
                .filter(|scanout| scanout.powered)
                .map(|scanout| DisplayClock::new(clock_source(scanout), now)),
        );
        self.ticks.clear();
        self.render_output = render_source(scanouts).map(|source| source.output);
    }

    fn observe_presentation(&mut self, presentation: PresentedOutput) {
        if let Some(clock) = self
            .clocks
            .iter_mut()
            .find(|clock| clock.source.output == presentation.id)
        {
            clock.observe_presentation(presentation);
        }
    }

    /// Advances every physical clock while returning only the tick allowed to
    /// authorize Flutter. Secondary ticks remain visible through `ticks()`.
    fn advance(&mut self, now: Instant) -> Option<FrameTick> {
        self.ticks.clear();
        for clock in &mut self.clocks {
            if let Some(tick) = clock.take_tick(now) {
                self.ticks.push(tick);
            }
        }
        let render_output = self.render_output?;
        self.ticks
            .iter()
            .copied()
            .find(|tick| tick.output == render_output)
    }

    fn ticks(&self) -> &[FrameTick] {
        &self.ticks
    }

    fn is_parked(&self) -> bool {
        self.render_output.is_none()
    }

    fn limit_dispatch_timeout(&self, now: Instant, timeout: Duration) -> Duration {
        if self
            .clocks
            .iter()
            .any(|clock| clock.presented_tick.is_some())
        {
            return Duration::ZERO;
        }
        self.clocks.iter().fold(timeout, |timeout, clock| {
            timeout.min(clock.next_tick.saturating_duration_since(now))
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct ClockSource {
    output: OutputId,
    interval: Duration,
}

#[derive(Debug)]
struct DisplayClock {
    source: ClockSource,
    next_tick: Instant,
    last_tick: Option<Instant>,
    presented_tick: Option<FrameTick>,
}

impl DisplayClock {
    fn new(source: ClockSource, now: Instant) -> Self {
        Self {
            source,
            next_tick: now,
            last_tick: None,
            presented_tick: None,
        }
    }

    fn observe_presentation(&mut self, presentation: PresentedOutput) {
        if presentation.id != self.source.output {
            return;
        }

        let observed_at = presentation.observed_at;
        let same_edge = self.last_tick.is_some_and(|last_tick| {
            instant_distance(last_tick, observed_at) <= self.source.interval / 2
        });
        self.next_tick = observed_at + self.source.interval;

        if !same_edge {
            self.presented_tick = Some(FrameTick {
                output: self.source.output,
                interval: self.source.interval,
                observed_at,
                presented_at: presentation.presented_at,
            });
        }
    }

    fn take_tick(&mut self, now: Instant) -> Option<FrameTick> {
        if let Some(tick) = self.presented_tick.take() {
            self.last_tick = Some(tick.observed_at);
            return Some(tick);
        }
        if now < self.next_tick {
            return None;
        }

        let interval_nanos = self.source.interval.as_nanos().max(1);
        let elapsed_periods =
            now.saturating_duration_since(self.next_tick).as_nanos() / interval_nanos;
        let observed_at = if let Ok(elapsed_periods) = u32::try_from(elapsed_periods) {
            self.next_tick + self.source.interval * elapsed_periods
        } else {
            // A very long suspend has no useful historical phase. Resume
            // with one current edge instead of replaying missed frames.
            now
        };
        self.next_tick = observed_at + self.source.interval;
        self.last_tick = Some(observed_at);
        Some(FrameTick {
            output: self.source.output,
            interval: self.source.interval,
            observed_at,
            presented_at: None,
        })
    }
}

fn render_source(scanouts: &[Scanout]) -> Option<ClockSource> {
    scanouts
        .iter()
        .filter(|scanout| scanout.powered)
        .max_by_key(|scanout| OutputMode::from(scanout.output.mode).refresh)
        .map(clock_source)
}

fn clock_source(scanout: &Scanout) -> ClockSource {
    ClockSource {
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

fn instant_distance(left: Instant, right: Instant) -> Duration {
    if left <= right {
        right.duration_since(left)
    } else {
        left.duration_since(right)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const INTERVAL: Duration = Duration::from_millis(10);
    const FAST_INTERVAL: Duration = Duration::from_millis(5);
    const FAST_OUTPUT: OutputId = OutputId(1);
    const SLOW_OUTPUT: OutputId = OutputId(2);

    fn scheduler(now: Instant) -> FrameScheduler {
        scheduler_with_clocks(now, &[(FAST_OUTPUT, INTERVAL)], FAST_OUTPUT)
    }

    fn mixed_scheduler(now: Instant) -> FrameScheduler {
        scheduler_with_clocks(
            now,
            &[(FAST_OUTPUT, FAST_INTERVAL), (SLOW_OUTPUT, INTERVAL)],
            FAST_OUTPUT,
        )
    }

    fn scheduler_with_clocks(
        now: Instant,
        sources: &[(OutputId, Duration)],
        render_output: OutputId,
    ) -> FrameScheduler {
        FrameScheduler {
            outputs: OutputClocks {
                clocks: sources
                    .iter()
                    .map(|(output, interval)| {
                        DisplayClock::new(
                            ClockSource {
                                output: *output,
                                interval: *interval,
                            },
                            now,
                        )
                    })
                    .collect(),
                ticks: Vec::with_capacity(sources.len()),
                render_output: Some(render_output),
            },
            waiting_for_flutter: None,
        }
    }

    fn pending(
        flutter_requested: bool,
        app_textures_updated: bool,
        producer_available: bool,
    ) -> PendingFrame {
        PendingFrame {
            flutter_requested,
            app_textures_updated,
            producer_available,
        }
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
    fn a_texture_tick_waits_for_flutter_then_renders_the_same_authorization() {
        let now = Instant::now();
        let mut scheduler = scheduler(now);
        let request = scheduler.step(now, pending(false, true, true));
        let authorized_tick = scheduler.output_ticks()[0];
        assert_eq!(request, FrameAction::RequestFlutter);

        let render = scheduler.step(now + Duration::from_millis(1), pending(true, false, false));

        assert!(scheduler.output_ticks().is_empty());
        assert_eq!(render, FrameAction::Render(authorized_tick));
    }

    #[test]
    fn flutter_and_texture_damage_share_one_tick() {
        let now = Instant::now();
        let mut scheduler = scheduler(now);

        let action = scheduler.step(now, pending(true, true, true));

        assert_eq!(action, FrameAction::Render(scheduler.output_ticks()[0]));
    }

    #[test]
    fn the_clock_keeps_ticking_while_every_producer_is_idle() {
        let now = Instant::now();
        let mut scheduler = scheduler(now);
        scheduler.step(now, pending(false, false, true));

        let action = scheduler.step(now + INTERVAL, pending(false, false, true));

        assert_eq!(scheduler.output_ticks()[0].observed_at, now + INTERVAL);
        assert_eq!(action, FrameAction::Skip);
    }

    #[test]
    fn a_real_kms_edge_rephases_but_does_not_duplicate_a_timer_tick() {
        let now = Instant::now();
        let mut scheduler = scheduler(now);
        scheduler.step(now, pending(false, false, true));
        let observed_at = now + Duration::from_millis(1);

        scheduler.observe_presentation(PresentedOutput {
            id: FAST_OUTPUT,
            observed_at,
            presented_at: Some(Duration::from_secs(7)),
            sequence: Some(42),
        });

        scheduler.step(observed_at, pending(false, false, true));
        assert!(scheduler.output_ticks().is_empty());

        scheduler.step(observed_at + INTERVAL, pending(false, false, true));
        assert_eq!(
            scheduler.output_ticks()[0].observed_at,
            observed_at + INTERVAL
        );
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

        assert_eq!(scheduler.output_ticks()[0].observed_at, now + INTERVAL * 4);
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
    fn a_secondary_tick_cannot_authorize_flutter() {
        let now = Instant::now();
        let mut scheduler = mixed_scheduler(now);
        scheduler.step(now, pending(false, false, true));
        scheduler.observe_presentation(PresentedOutput {
            id: SLOW_OUTPUT,
            observed_at: now + Duration::from_millis(2),
            presented_at: None,
            sequence: Some(1),
        });
        scheduler.step(now + FAST_INTERVAL, pending(false, false, true));
        scheduler.step(now + FAST_INTERVAL * 2, pending(false, false, true));

        let action = scheduler.step(now + Duration::from_millis(12), pending(false, true, true));

        assert_eq!(
            scheduler.output_ticks(),
            &[FrameTick {
                output: SLOW_OUTPUT,
                interval: INTERVAL,
                observed_at: now + Duration::from_millis(12),
                presented_at: None,
            }]
        );
        assert_eq!(action, FrameAction::Skip);

        let render_action = scheduler.step(now + FAST_INTERVAL * 3, pending(true, true, true));
        assert!(matches!(render_action, FrameAction::Render(tick) if tick.output == FAST_OUTPUT));
    }

    #[test]
    fn a_secondary_presentation_rephases_only_its_clock() {
        let now = Instant::now();
        let mut scheduler = mixed_scheduler(now);
        scheduler.step(now, pending(false, false, true));
        scheduler.observe_presentation(PresentedOutput {
            id: SLOW_OUTPUT,
            observed_at: now + Duration::from_millis(2),
            presented_at: Some(Duration::from_secs(3)),
            sequence: Some(9),
        });

        scheduler.step(now + FAST_INTERVAL, pending(false, false, true));
        assert_eq!(scheduler.output_ticks()[0].output, FAST_OUTPUT);

        scheduler.step(now + FAST_INTERVAL * 2, pending(false, false, true));
        assert_eq!(scheduler.output_ticks()[0].output, FAST_OUTPUT);

        scheduler.step(now + Duration::from_millis(12), pending(false, false, true));
        assert_eq!(scheduler.output_ticks()[0].output, SLOW_OUTPUT);
    }

    #[test]
    fn output_clocks_keep_ticking_while_flutter_is_late() {
        let now = Instant::now();
        let mut scheduler = mixed_scheduler(now);
        assert_eq!(
            scheduler.step(now, pending(false, true, true)),
            FrameAction::RequestFlutter
        );

        assert_eq!(
            scheduler.step(now + FAST_INTERVAL * 2, pending(false, false, false)),
            FrameAction::Skip
        );
        assert_eq!(scheduler.output_ticks().len(), 2);

        let render = scheduler.step(
            now + FAST_INTERVAL * 2 + Duration::from_millis(1),
            pending(true, false, false),
        );
        assert!(
            matches!(render, FrameAction::Render(tick) if tick.output == FAST_OUTPUT && tick.observed_at == now)
        );
        assert!(scheduler.output_ticks().is_empty());
    }

    #[test]
    fn powering_off_every_output_cancels_stale_frame_authorization() {
        let now = Instant::now();
        let mut scheduler = scheduler(now);
        assert_eq!(
            scheduler.step(now, pending(false, true, true)),
            FrameAction::RequestFlutter
        );

        scheduler.reconfigure(&[], now + Duration::from_millis(1));

        assert_eq!(
            scheduler.step(now + Duration::from_millis(2), pending(true, false, true)),
            FrameAction::Skip
        );
        assert!(scheduler.output_ticks().is_empty());
        assert!(scheduler.waiting_for_flutter.is_none());
    }
}
