//! DRM presentation timestamps translated onto the compositor's `Instant` clock.

use super::*;

#[path = "presentation_clock/feedback.rs"]
mod feedback;
pub(super) use feedback::{FeedbackClock, ModeTiming};

pub(super) fn mode_timing(mode: &Mode) -> ModeTiming {
    use smithay::reexports::drm::control::ModeFlags;
    if mode
        .flags()
        .intersects(ModeFlags::INTERLACE | ModeFlags::DBLSCAN)
        || mode.vscan() > 1
    {
        return ModeTiming::default();
    }
    let (clock, horizontal, vertical) = (mode.clock(), mode.hsync().2, mode.vsync().2);
    ModeTiming {
        blanking_limit: feedback::blanking_lead_limit(clock, horizontal, vertical, mode.size().1)
            .unwrap_or_default(),
        refresh: feedback::refresh_period(clock, horizontal, vertical),
    }
}

#[derive(Clone, Copy, Debug)]
#[cfg_attr(not(feature = "flutter"), allow(dead_code))]
pub(super) struct PageFlipCompletion {
    pub(super) crtc: crtc::Handle,
    pub(super) observed_at: Instant,
    pub(super) presented_at: Option<Duration>,
    /// The refresh edge clients are told about.
    pub(super) edge: Option<Duration>,
    pub(super) sequence: Option<u64>,
}

#[cfg(feature = "flutter")]
#[derive(Clone, Copy, Debug)]
pub(super) struct PresentedOutput {
    pub(super) id: OutputId,
    pub(super) logical_sequence: u64,
    pub(super) observed_at: Instant,
    pub(super) presented_at: Option<Duration>,
    pub(super) edge: Option<Duration>,
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
    // A validated end-of-blank edge can be ahead of notification delivery.
    // Preserve that edge on Instant as well; mapping it to receipt time loses
    // the phase information which the output timeline needs to train.
    if let Some(delivery_delay) = monotonic_now.checked_sub(presented_at) {
        delivered_at
            .checked_sub(delivery_delay)
            .unwrap_or(delivered_at)
    } else {
        delivered_at
            .checked_add(presented_at - monotonic_now)
            .unwrap_or(delivered_at)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn translates_delayed_and_blanking_edges_on_the_same_instant_clock() {
        let delivered = Instant::now();
        let now = Duration::from_secs(10);
        let delta = Duration::from_micros(700);
        assert_eq!(
            presentation_instant(delivered, now, now - delta),
            delivered - delta
        );
        assert_eq!(
            presentation_instant(delivered, now, now + delta),
            delivered + delta
        );
        assert_eq!(presentation_instant(delivered, now, now), delivered);
    }
}
