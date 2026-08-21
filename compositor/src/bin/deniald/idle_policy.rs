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
        if inhibited {
            if !std::mem::replace(&mut self.inhibited, true) {
                self.last_activity = now;
            }
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
        if !self.blanked_outputs.is_empty() {
            let live_outputs = outputs
                .into_iter()
                .map(|(output, _)| output)
                .collect::<BTreeSet<_>>();
            self.blanked_outputs
                .retain(|output| live_outputs.contains(output));
            return Vec::new();
        }
        if now.saturating_duration_since(self.last_activity) < timeout {
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

    /// The next instant at which inactivity can change display power.
    ///
    /// Input, inhibitor, configuration, and explicit power events wake the
    /// compositor independently. Between those edges the idle policy needs no
    /// polling; this deadline is the only timer it contributes.
    pub(super) fn next_deadline(&self) -> Option<Instant> {
        let timeout = self.timeout?;
        (!self.inhibited && self.blanked_outputs.is_empty()).then(|| self.last_activity + timeout)
    }

    pub(super) fn limit_dispatch_timeout(&self, now: Instant, timeout: Duration) -> Duration {
        self.next_deadline().map_or(timeout, |deadline| {
            timeout.min(deadline.saturating_duration_since(now))
        })
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
#[path = "idle_policy/tests.rs"]
mod tests;
