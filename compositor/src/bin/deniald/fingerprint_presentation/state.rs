//! Hardware-independent contact lifecycle for privileged fingerprint presentation.
//!
//! A matching scanout completion and illumination settling are separate gates.
//! The epoch accompanies native output frames, including the black presentation guard.

use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum Phase {
    Preparing,
    Presented,
    Settling(Instant),
    Ready,
    Stopping,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum StopReason {
    Released,
    Timeout,
    Unavailable,
    Revoked,
}

#[derive(Debug)]
pub(super) struct Contact {
    pub(super) serial: u32,
    pub(super) epoch: u64,
    pub(super) phase: Phase,
    pub(super) deadline: Instant,
    pub(super) restore_off: bool,
    pub(super) illumination_enabled: bool,
    pub(super) stop_reason: Option<StopReason>,
}

#[derive(Debug, Default)]
pub(super) struct Session {
    last_serial: u32,
    epoch: u64,
    pub(super) contact: Option<Contact>,
}

impl Session {
    pub(super) fn new_client(&mut self) -> Result<(), &'static str> {
        if self.contact.is_some() {
            return Err("previous contact is still stopping");
        }
        self.last_serial = 0;
        Ok(())
    }

    pub(super) fn begin(
        &mut self,
        serial: u32,
        now: Instant,
        duration: Duration,
        initially_off: bool,
    ) -> Result<u64, &'static str> {
        if self.contact.is_some() {
            return Err("a contact is already active");
        }
        if serial == 0 || serial <= self.last_serial {
            return Err("contact serial is zero, stale or reused");
        }
        if duration.is_zero() || duration > Duration::from_secs(30) {
            return Err("presentation duration must be within 30 seconds");
        }
        self.epoch = self
            .epoch
            .checked_add(1)
            .ok_or("presentation epoch exhausted")?;
        self.last_serial = serial;
        self.contact = Some(Contact {
            serial,
            epoch: self.epoch,
            phase: Phase::Preparing,
            deadline: now + duration,
            restore_off: initially_off,
            illumination_enabled: false,
            stop_reason: None,
        });
        Ok(self.epoch)
    }

    pub(super) fn epoch(&self) -> u64 {
        self.contact.as_ref().map_or(0, |contact| contact.epoch)
    }

    /// Called only for a physical page flip of a frame painted for this epoch.
    pub(super) fn presented(&mut self, epoch: u64) {
        if let Some(contact) = self.contact.as_mut()
            && contact.epoch == epoch
            && contact.phase == Phase::Preparing
        {
            contact.phase = Phase::Presented;
        }
    }

    pub(super) fn illumination_enabled(&mut self, now: Instant, settle: Duration) -> bool {
        let Some(contact) = self.contact.as_mut() else {
            return false;
        };
        if contact.phase != Phase::Presented || now >= contact.deadline {
            return false;
        }
        contact.illumination_enabled = true;
        contact.phase = Phase::Settling(now + settle);
        true
    }

    /// Returns a serial once, after both the scanout and hardware gates passed.
    pub(super) fn ready(&mut self, now: Instant) -> Option<u32> {
        let contact = self.contact.as_mut()?;
        if now >= contact.deadline {
            self.stop(StopReason::Timeout);
            return None;
        }
        if let Phase::Settling(deadline) = contact.phase
            && now >= deadline
            && contact.illumination_enabled
        {
            contact.phase = Phase::Ready;
            return Some(contact.serial);
        }
        None
    }

    pub(super) fn withdraw(&mut self, serial: u32) -> Result<(), &'static str> {
        if serial == 0 || serial > self.last_serial {
            return Err("withdraw references a serial that was never presented");
        }
        if self
            .contact
            .as_ref()
            .is_some_and(|contact| contact.serial == serial)
        {
            self.stop(StopReason::Released);
        }
        Ok(())
    }

    pub(super) fn stop(&mut self, reason: StopReason) {
        let Some(contact) = self.contact.as_mut() else {
            return;
        };
        if contact.phase == Phase::Stopping {
            return;
        }
        // Revoke all prepared acquisition frames. The UI may retain owned pixels.
        self.epoch = self
            .epoch
            .checked_add(1)
            .expect("bounded session epoch exhausted");
        contact.epoch = self.epoch;
        contact.phase = Phase::Stopping;
        contact.stop_reason = Some(reason);
    }

    pub(super) fn independent_wake(&mut self) {
        if let Some(contact) = self.contact.as_mut() {
            contact.restore_off = false;
        }
    }

    /// Keep the black presentation guard until local illumination is confirmed
    /// off and a required power-off has completed. Never assume an ioctl worked.
    pub(super) fn finish(
        &mut self,
        illumination_off: bool,
        output_off: bool,
    ) -> Option<(u32, StopReason)> {
        let contact = self.contact.as_ref()?;
        if contact.phase != Phase::Stopping
            || !illumination_off
            || (contact.restore_off && !output_off)
        {
            return None;
        }
        let contact = self.contact.take().expect("checked active contact");
        Some((
            contact.serial,
            contact.stop_reason.expect("stopping contact has a reason"),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn acquisition_waits_for_matching_physical_frame_and_settling() {
        let now = Instant::now();
        let mut session = Session::default();
        let epoch = session.begin(1, now, Duration::from_secs(5), true).unwrap();
        assert!(!session.illumination_enabled(now, Duration::ZERO));
        session.presented(epoch + 1);
        assert!(!session.illumination_enabled(now, Duration::ZERO));
        session.presented(epoch);
        assert!(session.illumination_enabled(now, Duration::from_millis(100)));
        assert_eq!(session.ready(now + Duration::from_millis(99)), None);
        assert_eq!(session.ready(now + Duration::from_millis(100)), Some(1));
        assert_eq!(session.ready(now + Duration::from_millis(101)), None);
    }

    #[test]
    fn release_before_scanout_revokes_queued_image_and_keeps_black_until_off() {
        let now = Instant::now();
        let mut session = Session::default();
        let epoch = session.begin(1, now, Duration::from_secs(5), true).unwrap();
        session.withdraw(1).unwrap();
        assert_ne!(session.epoch(), epoch);
        session.presented(epoch);
        assert_eq!(session.ready(now), None);
        assert_eq!(session.finish(false, true), None);
        assert_eq!(session.finish(true, false), None);
        assert_eq!(session.finish(true, true), Some((1, StopReason::Released)));
        assert_eq!(session.epoch(), 0);
    }

    #[test]
    fn stale_release_cannot_cancel_a_new_contact_and_serials_cannot_repeat() {
        let now = Instant::now();
        let mut session = Session::default();
        session
            .begin(3, now, Duration::from_secs(5), false)
            .unwrap();
        session.withdraw(3).unwrap();
        session.finish(true, false).unwrap();
        assert!(
            session
                .begin(3, now, Duration::from_secs(5), false)
                .is_err()
        );
        session
            .begin(4, now, Duration::from_secs(5), false)
            .unwrap();
        session.withdraw(3).unwrap();
        assert_eq!(session.contact.as_ref().unwrap().phase, Phase::Preparing);
        assert!(session.withdraw(5).is_err());
    }

    #[test]
    fn timeout_wins_over_simultaneous_ready_and_independent_wake_is_preserved() {
        let now = Instant::now();
        let mut session = Session::default();
        let epoch = session.begin(1, now, Duration::from_secs(1), true).unwrap();
        session.presented(epoch);
        session.illumination_enabled(now, Duration::from_secs(1));
        assert_eq!(session.ready(now + Duration::from_secs(1)), None);
        session.independent_wake();
        assert_eq!(session.finish(true, false), Some((1, StopReason::Timeout)));
    }
}
