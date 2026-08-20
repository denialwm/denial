use super::{next_presentation_sequence, refresh_interval, timeline_time_from_anchor};
use std::time::{Duration, Instant};

#[test]
fn physical_refresh_is_converted_from_millihertz() {
    let interval = refresh_interval(180_000).expect("valid refresh");
    assert_eq!(interval, Duration::from_nanos(5_555_555));
    assert_eq!(refresh_interval(0), None);
    assert_eq!(refresh_interval(-1), None);
}

#[test]
fn timeline_conversion_uses_one_stable_monotonic_anchor() {
    let instant_anchor = Instant::now();
    let clock_anchor = Duration::from_secs(100);
    assert_eq!(
        timeline_time_from_anchor(
            instant_anchor,
            clock_anchor,
            instant_anchor + Duration::from_millis(4),
        ),
        Duration::from_millis(100_004)
    );
    assert_eq!(
        timeline_time_from_anchor(
            instant_anchor,
            clock_anchor,
            instant_anchor - Duration::from_millis(4),
        ),
        Duration::from_millis(99_996)
    );
}

#[test]
fn presentation_sequence_is_monotonic_modulo_protocol_width() {
    assert_eq!(next_presentation_sequence(41), 42);
    assert_eq!(next_presentation_sequence(u64::MAX), 0);
}
