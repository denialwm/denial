//! Validate optional DRM metadata before using it as physical display feedback.

use std::time::Duration;

// A completion this old cannot usefully train the live output clock. Keep
// processing its buffer retirement, but label its timing as an estimate.
const MAX_EVENT_AGE: Duration = Duration::from_secs(1);

/// DRM's scanout-position helper timestamps the end of vertical blanking.
/// At a vblank IRQ that edge may still be ahead of the current monotonic time.
/// Bound that lead by the active progressive mode, never by a generic allowance.
pub(super) fn blanking_lead_limit(
    clock_khz: u32,
    horizontal_total: u16,
    vertical_total: u16,
    vertical_active: u16,
) -> Option<Duration> {
    let blank_lines = vertical_total.checked_sub(vertical_active)?;
    if clock_khz == 0 || horizontal_total == 0 || vertical_active == 0 || blank_lines == 0 {
        return None;
    }
    let nanos = u64::from(blank_lines)
        .checked_mul(u64::from(horizontal_total))?
        .checked_mul(1_000_000)?
        .div_ceil(u64::from(clock_khz));
    Some(Duration::from_nanos(nanos))
}

/// One refresh of a progressive mode: total pixels over the pixel clock.
pub(super) fn refresh_period(
    clock_khz: u32,
    horizontal_total: u16,
    vertical_total: u16,
) -> Option<Duration> {
    if clock_khz == 0 || horizontal_total == 0 || vertical_total == 0 {
        return None;
    }
    let nanos = u64::from(horizontal_total)
        .checked_mul(u64::from(vertical_total))?
        .checked_mul(1_000_000)?
        / u64::from(clock_khz);
    Some(Duration::from_nanos(nanos))
}

/// What the active mode says about a CRTC's refresh edges.
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct ModeTiming {
    pub(crate) blanking_limit: Duration,
    pub(crate) refresh: Option<Duration>,
}

#[derive(Debug, Default)]
pub(crate) struct FeedbackClock {
    last_timestamp: Option<Duration>,
    last_edge: Option<Duration>,
    last_sequence: Option<u32>,
}

#[derive(Debug)]
pub(crate) struct ValidatedFeedback {
    pub(crate) timestamp: Option<Duration>,
    /// The refresh edge clients are told: the physical timestamp, or for an
    /// unusable one the first edge on the last physical timestamp's grid that
    /// the completion could have reached. Only the physical timestamp trains
    /// the output clock.
    pub(crate) edge: Option<Duration>,
    pub(crate) sequence: Option<u64>,
    pub(crate) timestamp_status: &'static str,
}

impl FeedbackClock {
    pub(crate) fn observe(
        &mut self,
        now: Option<Duration>,
        timestamp: Option<Duration>,
        sequence: Option<u32>,
        timing: ModeTiming,
    ) -> ValidatedFeedback {
        let blanking_limit = timing.blanking_limit;
        let status = match (now, timestamp) {
            (_, None) => "missing_or_non_monotonic_clock",
            (None, _) => "clock_unavailable",
            (_, Some(timestamp)) if timestamp.is_zero() => "zero",
            (Some(now), Some(timestamp)) if timestamp.saturating_sub(now) > blanking_limit => {
                "future"
            }
            (Some(now), Some(timestamp)) if now.saturating_sub(timestamp) > MAX_EVENT_AGE => {
                "stale"
            }
            (_, Some(timestamp)) if self.last_timestamp.is_some_and(|last| timestamp <= last) => {
                "nonadvancing"
            }
            (Some(now), Some(timestamp)) if timestamp > now => "physical_blanking",
            _ => "physical",
        };
        let timestamp = timestamp.filter(|_| matches!(status, "physical" | "physical_blanking"));
        if timestamp.is_some() {
            self.last_timestamp = timestamp;
        }
        let edge = timestamp.or_else(|| self.estimated_edge(now?, timing));
        if edge.is_some() {
            self.last_edge = edge;
        }
        // Zero can be a legitimate u32 wrap. A repeated value or a reset is
        // not a vblank delta. Rebase after an invalid sample so recovery does
        // not turn a counter reset into billions of missed refreshes.
        let valid_sequence = sequence.filter(|current| match self.last_sequence {
            Some(last) => {
                let delta = current.wrapping_sub(last);
                delta > 0 && delta <= i32::MAX as u32
            }
            None => *current != 0,
        });
        self.last_sequence = sequence;
        ValidatedFeedback {
            timestamp,
            edge,
            sequence: valid_sequence.map(u64::from),
            timestamp_status: status,
        }
    }
}

impl FeedbackClock {
    /// A completion delivered at `now` landed on the latest edge it can have
    /// reached, counting the blanking lead, and after any edge already
    /// reported. Without a recent physical edge there is no grid to stand on.
    fn estimated_edge(&self, now: Duration, timing: ModeTiming) -> Option<Duration> {
        let last = self.last_timestamp?;
        let period = timing.refresh.filter(|period| !period.is_zero())?;
        let since = now
            .saturating_add(timing.blanking_limit)
            .checked_sub(last)?;
        if since > MAX_EVENT_AGE {
            return None;
        }
        let latest = (since.as_nanos() / period.as_nanos()).max(1);
        let after_reported = self.last_edge.map_or(1, |reported| {
            reported.saturating_sub(last).as_nanos() / period.as_nanos() + 1
        });
        let refreshes = u32::try_from(latest.max(after_reported)).ok()?;
        last.checked_add(period.checked_mul(refreshes)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(n: u64) -> Duration {
        Duration::from_millis(n)
    }

    fn bounded(blanking_limit: Duration) -> ModeTiming {
        ModeTiming {
            blanking_limit,
            refresh: None,
        }
    }

    fn us(n: u64) -> Duration {
        Duration::from_micros(n)
    }

    #[test]
    fn zero_driver_metadata_never_becomes_physical_feedback() {
        let mut clock = FeedbackClock::default();
        for now in [10_000, 20_000, 240_000] {
            let feedback = clock.observe(
                Some(ms(now)),
                Some(Duration::ZERO),
                Some(0),
                ModeTiming::default(),
            );
            assert_eq!(feedback.timestamp_status, "zero");
            assert_eq!(feedback.timestamp, None);
            assert_eq!(feedback.sequence, None);
        }
    }

    #[test]
    fn accepts_delayed_physical_edges_but_rejects_bad_clocks() {
        let mut clock = FeedbackClock::default();
        let good = clock.observe(
            Some(ms(10_000)),
            Some(ms(9_950)),
            Some(42),
            ModeTiming::default(),
        );
        assert_eq!(good.timestamp, Some(ms(9_950)));
        assert_eq!(good.sequence, Some(42));
        for (timestamp, status) in [
            (9_950, "nonadvancing"),
            (9_940, "nonadvancing"),
            (1, "stale"),
            (10_001, "future"),
        ] {
            let result = clock.observe(
                Some(ms(10_000)),
                Some(ms(timestamp)),
                None,
                ModeTiming::default(),
            );
            assert_eq!(result.timestamp_status, status);
            assert_eq!(result.timestamp, None);
        }
        assert_eq!(
            clock
                .observe(None, Some(ms(10_000)), None, ModeTiming::default())
                .timestamp,
            None
        );
        assert_eq!(
            clock
                .observe(
                    Some(ms(10_010)),
                    Some(ms(10_000)),
                    Some(43),
                    ModeTiming::default()
                )
                .timestamp,
            Some(ms(10_000))
        );
    }

    #[test]
    fn blanking_budget_comes_from_mode_and_rejects_invalid_timings() {
        assert_eq!(
            blanking_lead_limit(1_185_840, 3660, 2700, 2400),
            Some(Duration::from_nanos(925_926))
        );
        for timing in [
            (0, 3660, 2700, 2400),
            (1, 0, 2700, 2400),
            (1, 1, 2400, 2700),
            (1, 1, 2400, 2400),
            (1, 1, 1, 0),
        ] {
            assert_eq!(
                blanking_lead_limit(timing.0, timing.1, timing.2, timing.3),
                None
            );
        }
    }

    #[test]
    fn accepts_only_mode_bounded_future_edges_without_changing_metadata() {
        let now = Duration::from_secs(10);
        let limit = blanking_lead_limit(1_185_840, 3660, 2700, 2400).unwrap();
        let mut clock = FeedbackClock::default();
        let timestamp = now + Duration::from_micros(700);
        let feedback = clock.observe(Some(now), Some(timestamp), Some(42), bounded(limit));
        assert_eq!(feedback.timestamp, Some(timestamp));
        assert_eq!(feedback.timestamp_status, "physical_blanking");
        assert_eq!(feedback.sequence, Some(42));
        let feedback = clock.observe(Some(now), Some(now + limit), Some(43), bounded(limit));
        assert_eq!(feedback.timestamp, Some(now + limit));
        let feedback = clock.observe(
            Some(now),
            Some(now + limit + Duration::from_nanos(1)),
            Some(44),
            bounded(limit),
        );
        assert_eq!(feedback.timestamp, None);
        assert_eq!(feedback.timestamp_status, "future");
        let feedback = clock.observe(Some(now), Some(timestamp), Some(45), bounded(limit));
        assert_eq!(feedback.timestamp, None);
        assert_eq!(feedback.timestamp_status, "nonadvancing");
    }

    #[test]
    fn counter_wrap_is_valid_but_stalls_and_resets_are_not() {
        let mut clock = FeedbackClock::default();
        for (raw, accepted) in [
            (u32::MAX, Some(u64::from(u32::MAX))),
            (0, Some(0)),
            (1, Some(1)),
            (1, None),
            (2, Some(2)),
            (0, None),
            (1, Some(1)),
        ] {
            assert_eq!(
                clock
                    .observe(None, None, Some(raw), ModeTiming::default())
                    .sequence,
                accepted
            );
        }
    }

    #[test]
    fn refresh_period_comes_from_the_mode_totals() {
        assert_eq!(
            refresh_period(1_185_840, 3660, 2700),
            Some(Duration::from_nanos(8_333_333))
        );
        assert_eq!(refresh_period(0, 3660, 2700), None);
        assert_eq!(refresh_period(1_185_840, 0, 2700), None);
    }

    #[test]
    fn a_rejected_timestamp_reports_the_edge_the_completion_reached() {
        let timing = ModeTiming {
            blanking_limit: us(193),
            refresh: Some(us(8_000)),
        };
        let mut clock = FeedbackClock::default();
        let physical = clock.observe(Some(us(100_010)), Some(us(100_000)), Some(1), timing);
        assert_eq!(physical.edge, Some(us(100_000)));
        // The driver repeats the last edge; delivery 120 us after the next.
        let repeated = clock.observe(Some(us(108_120)), Some(us(100_000)), Some(1), timing);
        assert_eq!(repeated.timestamp_status, "nonadvancing");
        assert_eq!(repeated.timestamp, None);
        assert_eq!(repeated.edge, Some(us(108_000)));
        // Delivered within the blanking lead of the edge after that.
        let early = clock.observe(Some(us(115_900)), Some(us(100_000)), Some(1), timing);
        assert_eq!(early.edge, Some(us(116_000)));
        // Never the same edge twice, never behind one already reported.
        let crowded = clock.observe(Some(us(116_050)), Some(us(100_000)), Some(1), timing);
        assert_eq!(crowded.edge, Some(us(124_000)));
        let next = clock.observe(Some(us(132_010)), Some(us(132_000)), Some(5), timing);
        assert_eq!(next.edge, Some(us(132_000)));
    }

    #[test]
    fn no_edge_is_made_up_without_a_recent_physical_one() {
        let timing = ModeTiming {
            blanking_limit: us(193),
            refresh: Some(us(8_000)),
        };
        let mut clock = FeedbackClock::default();
        assert_eq!(clock.observe(Some(ms(10)), None, None, timing).edge, None);
        clock.observe(Some(ms(10)), Some(ms(10)), Some(1), timing);
        assert_eq!(
            clock
                .observe(Some(ms(10) + MAX_EVENT_AGE + ms(1)), None, None, timing)
                .edge,
            None
        );
        assert_eq!(
            clock
                .observe(Some(ms(20)), None, None, bounded(us(193)))
                .edge,
            None
        );
    }
}
