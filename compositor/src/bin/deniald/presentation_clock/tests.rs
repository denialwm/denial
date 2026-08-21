use super::*;

#[test]
fn kernel_monotonic_timestamp_is_backdated_from_event_delivery() {
    let delivered_at = Instant::now();
    let monotonic_now = Duration::from_secs(20);
    let delay = Duration::from_millis(3);

    assert_eq!(
        presentation_instant(delivered_at, monotonic_now, monotonic_now - delay),
        delivered_at - delay
    );
    assert_eq!(
        presentation_instant(
            delivered_at,
            monotonic_now,
            monotonic_now + Duration::from_nanos(1)
        ),
        delivered_at
    );
}
