//! DRM presentation timestamps translated onto the compositor's `Instant` clock.

use super::*;

#[derive(Clone, Copy, Debug)]
#[cfg_attr(not(feature = "flutter"), allow(dead_code))]
pub(super) struct PageFlipCompletion {
    pub(super) crtc: crtc::Handle,
    pub(super) observed_at: Instant,
    pub(super) presented_at: Option<Duration>,
    pub(super) sequence: Option<u64>,
}

#[cfg(feature = "flutter")]
#[derive(Clone, Copy, Debug)]
pub(super) struct PresentedOutput {
    pub(super) id: OutputId,
    pub(super) observed_at: Instant,
    pub(super) presented_at: Option<Duration>,
    pub(super) sequence: Option<u64>,
    pub(super) timeline_target: Instant,
}

pub(super) fn monotonic_now() -> Option<Duration> {
    let mut timestamp = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: `timestamp` points to initialized writable storage and
    // CLOCK_MONOTONIC requires no additional lifetime or ownership contract.
    if unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut timestamp) } != 0 {
        return None;
    }
    let seconds = u64::try_from(timestamp.tv_sec).ok()?;
    let nanoseconds = u32::try_from(timestamp.tv_nsec).ok()?;
    (nanoseconds < 1_000_000_000).then(|| Duration::new(seconds, nanoseconds))
}

pub(super) fn presentation_instant(
    delivered_at: Instant,
    monotonic_now: Duration,
    presented_at: Duration,
) -> Instant {
    let Some(delivery_delay) = monotonic_now.checked_sub(presented_at) else {
        return delivered_at;
    };
    delivered_at
        .checked_sub(delivery_delay)
        .unwrap_or(delivered_at)
}
