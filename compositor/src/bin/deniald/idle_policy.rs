//! Compositor-owned idle timeout and automatic display-power policy.
//!
//! Flutter publishes one bounded timeout value. Physical input and visible
//! Wayland idle inhibitors remain native concerns, so the policy keeps working
//! while the shell is busy, restarting, or all outputs are powered down.

use std::collections::BTreeSet;
use std::error::Error;
use std::ffi::CStr;
use std::fmt;
use std::time::{Duration, Instant};

use denial_core::topology::OutputId;

pub(super) const CHANNEL: &CStr = c"denial/idle_policy";
pub(super) const DISPLAY_POWER_CHANNEL: &CStr = c"denial/display_power";

const PACKET_BYTES: usize = size_of::<u64>();
const DISPLAY_POWER_OFF: u8 = 1;
const MAX_TIMEOUT: Duration = Duration::from_secs(7 * 24 * 60 * 60);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct IdlePowerRequest {
    pub(super) output: OutputId,
    pub(super) powered: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum IdlePolicyPacketError {
    InvalidSize(usize),
    TimeoutTooLarge(u64),
}

impl fmt::Display for IdlePolicyPacketError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidSize(size) => write!(
                formatter,
                "idle policy packet has {size} bytes; expected {PACKET_BYTES}"
            ),
            Self::TimeoutTooLarge(milliseconds) => write!(
                formatter,
                "idle timeout {milliseconds} ms exceeds the seven-day limit"
            ),
        }
    }
}

impl Error for IdlePolicyPacketError {}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum DisplayPowerPacketError {
    InvalidPacket,
}

impl fmt::Display for DisplayPowerPacketError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("display power packet must contain the one-byte DPMS-off command")
    }
}

impl Error for DisplayPowerPacketError {}

pub(super) fn decode_display_power_off(packet: &[u8]) -> Result<(), DisplayPowerPacketError> {
    if packet == [DISPLAY_POWER_OFF] {
        Ok(())
    } else {
        Err(DisplayPowerPacketError::InvalidPacket)
    }
}

pub(super) fn decode_timeout(packet: &[u8]) -> Result<Option<Duration>, IdlePolicyPacketError> {
    let bytes: [u8; PACKET_BYTES] = packet
        .try_into()
        .map_err(|_| IdlePolicyPacketError::InvalidSize(packet.len()))?;
    let milliseconds = u64::from_le_bytes(bytes);
    if milliseconds == 0 {
        return Ok(None);
    }
    let timeout = Duration::from_millis(milliseconds);
    if timeout > MAX_TIMEOUT {
        return Err(IdlePolicyPacketError::TimeoutTooLarge(milliseconds));
    }
    Ok(Some(timeout))
}

#[derive(Debug)]
pub(super) struct IdleDpmsPolicy {
    timeout: Option<Duration>,
    last_activity: Instant,
    inhibited: bool,
    blanked_outputs: BTreeSet<OutputId>,
}

impl Default for IdleDpmsPolicy {
    fn default() -> Self {
        Self {
            // Remain disabled until the persisted Flutter setting reaches the
            // compositor. This avoids applying a transient default while the
            // shell restores its settings file.
            timeout: None,
            last_activity: Instant::now(),
            inhibited: false,
            blanked_outputs: BTreeSet::new(),
        }
    }
}

impl IdleDpmsPolicy {
    /// Blanks every powered output explicitly while retaining native
    /// input-to-wake semantics independently of the configured idle timeout.
    pub(super) fn blank_now(
        &mut self,
        outputs: impl IntoIterator<Item = (OutputId, bool)>,
    ) -> Vec<IdlePowerRequest> {
        let mut requests = Vec::new();
        for (output, powered) in outputs {
            if powered && self.blanked_outputs.insert(output) {
                requests.push(IdlePowerRequest {
                    output,
                    powered: false,
                });
            }
        }
        requests
    }

    pub(super) fn configure(
        &mut self,
        timeout: Option<Duration>,
        now: Instant,
    ) -> Vec<IdlePowerRequest> {
        if self.timeout == timeout {
            return Vec::new();
        }
        self.timeout = timeout;
        self.last_activity = now;
        if timeout.is_none() {
            return self.wake_blanked_outputs();
        }
        Vec::new()
    }

    pub(super) fn note_activity(&mut self, now: Instant) -> Vec<IdlePowerRequest> {
        self.last_activity = now;
        self.wake_blanked_outputs()
    }

    pub(super) fn evaluate(
        &mut self,
        now: Instant,
        inhibited: bool,
        outputs: impl IntoIterator<Item = (OutputId, bool)>,
    ) -> Vec<IdlePowerRequest> {
        let outputs = outputs.into_iter().collect::<Vec<_>>();
        let live_outputs = outputs
            .iter()
            .map(|(output, _)| *output)
            .collect::<BTreeSet<_>>();
        self.blanked_outputs
            .retain(|output| live_outputs.contains(output));

        if inhibited {
            self.inhibited = true;
            self.last_activity = now;
            // If playback starts remotely or between the timeout edge and the
            // KMS transition, honor it immediately rather than requiring a
            // separate physical input event.
            return self.wake_blanked_outputs();
        }
        if std::mem::replace(&mut self.inhibited, false) {
            // Give the user a full configured interval after playback ends.
            self.last_activity = now;
        }

        let Some(timeout) = self.timeout else {
            return Vec::new();
        };
        if !self.blanked_outputs.is_empty()
            || now.saturating_duration_since(self.last_activity) < timeout
        {
            return Vec::new();
        }

        let mut requests = Vec::new();
        for (output, powered) in outputs {
            if powered && self.blanked_outputs.insert(output) {
                requests.push(IdlePowerRequest {
                    output,
                    powered: false,
                });
            }
        }
        requests
    }

    pub(super) fn note_external_power_request(&mut self, output: OutputId, _powered: bool) {
        // Explicit clients own their choice. In particular, an output which
        // wlopm leaves off must not be revived by the next activity edge.
        self.blanked_outputs.remove(&output);
    }

    pub(super) fn note_power_failure(&mut self, output: OutputId, now: Instant) {
        if self.blanked_outputs.remove(&output) {
            // Avoid retrying a rejected KMS transition every event-loop turn.
            self.last_activity = now;
        }
    }

    fn wake_blanked_outputs(&mut self) -> Vec<IdlePowerRequest> {
        std::mem::take(&mut self.blanked_outputs)
            .into_iter()
            .map(|output| IdlePowerRequest {
                output,
                powered: true,
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn output(id: u64) -> OutputId {
        OutputId(id)
    }

    #[test]
    fn packet_is_exact_bounded_and_zero_disables() {
        assert_eq!(decode_timeout(&0u64.to_le_bytes()).unwrap(), None);
        assert_eq!(
            decode_timeout(&60_000u64.to_le_bytes()).unwrap(),
            Some(Duration::from_secs(60))
        );
        assert!(matches!(
            decode_timeout(&[0; 7]),
            Err(IdlePolicyPacketError::InvalidSize(7))
        ));
        let too_large = u64::try_from(MAX_TIMEOUT.as_millis()).unwrap() + 1;
        assert!(matches!(
            decode_timeout(&too_large.to_le_bytes()),
            Err(IdlePolicyPacketError::TimeoutTooLarge(value)) if value == too_large
        ));
    }

    #[test]
    fn display_power_packet_accepts_only_the_exact_off_command() {
        assert_eq!(decode_display_power_off(&[DISPLAY_POWER_OFF]), Ok(()));
        assert_eq!(
            decode_display_power_off(&[]),
            Err(DisplayPowerPacketError::InvalidPacket)
        );
        assert_eq!(
            decode_display_power_off(&[0]),
            Err(DisplayPowerPacketError::InvalidPacket)
        );
        assert_eq!(
            decode_display_power_off(&[DISPLAY_POWER_OFF, 0]),
            Err(DisplayPowerPacketError::InvalidPacket)
        );
    }

    #[test]
    fn explicit_blank_uses_native_input_to_wake_without_an_idle_timeout() {
        let started = Instant::now();
        let mut policy = IdleDpmsPolicy::default();
        assert_eq!(
            policy.blank_now([(output(1), true), (output(2), false)]),
            [IdlePowerRequest {
                output: output(1),
                powered: false,
            }]
        );
        assert_eq!(
            policy.note_activity(started),
            [IdlePowerRequest {
                output: output(1),
                powered: true,
            }]
        );
    }

    #[test]
    fn inactivity_blanks_only_powered_outputs_and_activity_restores_them() {
        let started = Instant::now();
        let mut policy = IdleDpmsPolicy::default();
        assert!(
            policy
                .configure(Some(Duration::from_secs(60)), started)
                .is_empty()
        );
        assert!(
            policy
                .evaluate(
                    started + Duration::from_secs(59),
                    false,
                    [(output(1), true), (output(2), false)],
                )
                .is_empty()
        );
        assert_eq!(
            policy.evaluate(
                started + Duration::from_secs(60),
                false,
                [(output(1), true), (output(2), false)],
            ),
            [IdlePowerRequest {
                output: output(1),
                powered: false,
            }]
        );
        assert_eq!(
            policy.note_activity(started + Duration::from_secs(61)),
            [IdlePowerRequest {
                output: output(1),
                powered: true,
            }]
        );
    }

    #[test]
    fn inhibition_resets_the_full_timeout_and_can_wake_a_blanked_output() {
        let started = Instant::now();
        let mut policy = IdleDpmsPolicy::default();
        policy.configure(Some(Duration::from_secs(10)), started);
        assert!(
            !policy.evaluate(
                started + Duration::from_secs(10),
                false,
                [(output(7), true)],
            )[0]
            .powered
        );
        assert_eq!(
            policy.evaluate(
                started + Duration::from_secs(11),
                true,
                [(output(7), false)],
            ),
            [IdlePowerRequest {
                output: output(7),
                powered: true,
            }]
        );
        assert!(
            policy
                .evaluate(started + Duration::from_secs(50), true, [(output(7), true)],)
                .is_empty()
        );
        assert!(
            policy
                .evaluate(
                    started + Duration::from_secs(51),
                    false,
                    [(output(7), true)],
                )
                .is_empty()
        );
        assert!(
            policy
                .evaluate(
                    started + Duration::from_secs(60),
                    false,
                    [(output(7), true)],
                )
                .is_empty()
        );
        assert!(
            !policy.evaluate(
                started + Duration::from_secs(61),
                false,
                [(output(7), true)],
            )[0]
            .powered
        );
    }

    #[test]
    fn manual_power_request_is_not_undone_by_activity() {
        let started = Instant::now();
        let mut policy = IdleDpmsPolicy::default();
        policy.configure(Some(Duration::from_secs(1)), started);
        policy.evaluate(started + Duration::from_secs(1), false, [(output(3), true)]);
        policy.note_external_power_request(output(3), false);
        assert!(
            policy
                .note_activity(started + Duration::from_secs(2))
                .is_empty()
        );
    }
}
