//! Validate optional DRM metadata before using it as physical display feedback.

use std::time::Duration;

// A completion this old cannot usefully train the live output clock. Keep
// processing its buffer retirement, but label its timing as an estimate.
const MAX_EVENT_AGE: Duration = Duration::from_secs(1);

#[derive(Debug, Default)]
pub(crate) struct FeedbackClock {
    last_timestamp: Option<Duration>,
    last_sequence: Option<u32>,
}

#[derive(Debug)]
pub(crate) struct ValidatedFeedback {
    pub(crate) timestamp: Option<Duration>,
    pub(crate) sequence: Option<u64>,
    pub(crate) timestamp_status: &'static str,
}

impl FeedbackClock {
    pub(crate) fn observe(
        &mut self,
        now: Option<Duration>,
        timestamp: Option<Duration>,
        sequence: Option<u32>,
    ) -> ValidatedFeedback {
        let status = match (now, timestamp) {
            (_, None) => "missing_or_non_monotonic_clock",
            (None, _) => "clock_unavailable",
            (_, Some(timestamp)) if timestamp.is_zero() => "zero",
            (Some(now), Some(timestamp)) if timestamp > now => "future",
            (Some(now), Some(timestamp)) if now - timestamp > MAX_EVENT_AGE => "stale",
            (_, Some(timestamp)) if self.last_timestamp.is_some_and(|last| timestamp <= last) => {
                "nonadvancing"
            }
            _ => "physical",
        };
        let timestamp = timestamp.filter(|_| status == "physical");
        if timestamp.is_some() {
            self.last_timestamp = timestamp;
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
            sequence: valid_sequence.map(u64::from),
            timestamp_status: status,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(n: u64) -> Duration {
        Duration::from_millis(n)
    }

    #[test]
    fn zero_driver_metadata_never_becomes_physical_feedback() {
        let mut clock = FeedbackClock::default();
        for now in [10_000, 20_000, 240_000] {
            let feedback = clock.observe(Some(ms(now)), Some(Duration::ZERO), Some(0));
            assert_eq!(feedback.timestamp_status, "zero");
            assert_eq!(feedback.timestamp, None);
            assert_eq!(feedback.sequence, None);
        }
    }

    #[test]
    fn accepts_delayed_physical_edges_but_rejects_bad_clocks() {
        let mut clock = FeedbackClock::default();
        let good = clock.observe(Some(ms(10_000)), Some(ms(9_950)), Some(42));
        assert_eq!(good.timestamp, Some(ms(9_950)));
        assert_eq!(good.sequence, Some(42));
        for (timestamp, status) in [
            (9_950, "nonadvancing"),
            (9_940, "nonadvancing"),
            (1, "stale"),
            (10_001, "future"),
        ] {
            let result = clock.observe(Some(ms(10_000)), Some(ms(timestamp)), None);
            assert_eq!(result.timestamp_status, status);
            assert_eq!(result.timestamp, None);
        }
        assert_eq!(clock.observe(None, Some(ms(10_000)), None).timestamp, None);
        assert_eq!(
            clock
                .observe(Some(ms(10_010)), Some(ms(10_000)), Some(43))
                .timestamp,
            Some(ms(10_000))
        );
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
            assert_eq!(clock.observe(None, None, Some(raw)).sequence, accepted);
        }
    }
}
