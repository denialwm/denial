//! Compositor-owned inactivity policy for locking, display power, and suspend.
//!
//! Flutter publishes one bounded, versioned configuration packet. Physical
//! input and visible Wayland idle inhibitors remain native concerns, so the
//! policy keeps working while the shell is busy, restarting, or all outputs
//! are powered down.

use std::collections::BTreeSet;
use std::error::Error;
use std::ffi::CStr;
use std::fmt;
use std::time::{Duration, Instant};

use denial_core::topology::OutputId;

pub(super) const CHANNEL: &CStr = c"denial/idle_policy";
pub(super) const DISPLAY_POWER_CHANNEL: &CStr = c"denial/display_power";

const LEGACY_PACKET_BYTES: usize = size_of::<u64>();
const PACKET_BYTES: usize = 32;
const PACKET_VERSION: u8 = 1;
const LOCK_ENABLED: u8 = 1 << 0;
const DPMS_ENABLED: u8 = 1 << 1;
const SUSPEND_ENABLED: u8 = 1 << 2;
const ENABLED_MASK: u8 = LOCK_ENABLED | DPMS_ENABLED | SUSPEND_ENABLED;
const DISPLAY_POWER_OFF: u8 = 1;
const MAX_TIMEOUT: Duration = Duration::from_secs(7 * 24 * 60 * 60);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct IdlePowerRequest {
    pub(super) output: OutputId,
    pub(super) powered: bool,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(super) struct IdlePolicyConfiguration {
    pub(super) lock_timeout: Option<Duration>,
    pub(super) dpms_timeout: Option<Duration>,
    pub(super) suspend_timeout: Option<Duration>,
}

#[derive(Debug, Default, Eq, PartialEq)]
pub(super) struct IdlePolicyActions {
    pub(super) power_requests: Vec<IdlePowerRequest>,
    pub(super) lock: bool,
    pub(super) suspend: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum IdlePolicyPacketError {
    InvalidSize(usize),
    UnsupportedVersion(u8),
    InvalidFlags(u8),
    NonZeroReservedBytes,
    ZeroTimeout(&'static str),
    TimeoutTooLarge {
        action: &'static str,
        milliseconds: u64,
    },
    TimeoutAfterSuspend(&'static str),
}

impl fmt::Display for IdlePolicyPacketError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidSize(size) => write!(
                formatter,
                "idle policy packet has {size} bytes; expected {LEGACY_PACKET_BYTES} or {PACKET_BYTES}"
            ),
            Self::UnsupportedVersion(version) => {
                write!(
                    formatter,
                    "unsupported idle policy packet version {version}"
                )
            }
            Self::InvalidFlags(flags) => {
                write!(
                    formatter,
                    "idle policy packet has invalid flags {flags:#04x}"
                )
            }
            Self::NonZeroReservedBytes => {
                formatter.write_str("idle policy packet reserved bytes must be zero")
            }
            Self::ZeroTimeout(action) => {
                write!(formatter, "idle {action} timeout must be greater than zero")
            }
            Self::TimeoutTooLarge {
                action,
                milliseconds,
            } => write!(
                formatter,
                "idle {action} timeout {milliseconds} ms exceeds the seven-day limit"
            ),
            Self::TimeoutAfterSuspend(action) => write!(
                formatter,
                "idle {action} timeout must not exceed the suspend timeout"
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

pub(super) fn decode_configuration(
    packet: &[u8],
) -> Result<IdlePolicyConfiguration, IdlePolicyPacketError> {
    if packet.len() == LEGACY_PACKET_BYTES {
        let milliseconds = u64::from_le_bytes(
            packet
                .try_into()
                .expect("legacy idle policy packet size was checked"),
        );
        return Ok(IdlePolicyConfiguration {
            dpms_timeout: (milliseconds != 0)
                .then(|| decode_timeout("display power-off", milliseconds))
                .transpose()?,
            ..IdlePolicyConfiguration::default()
        });
    }
    if packet.len() != PACKET_BYTES {
        return Err(IdlePolicyPacketError::InvalidSize(packet.len()));
    }
    if packet[0] != PACKET_VERSION {
        return Err(IdlePolicyPacketError::UnsupportedVersion(packet[0]));
    }
    let flags = packet[1];
    if flags & !ENABLED_MASK != 0 {
        return Err(IdlePolicyPacketError::InvalidFlags(flags));
    }
    if packet[2..8].iter().any(|byte| *byte != 0) {
        return Err(IdlePolicyPacketError::NonZeroReservedBytes);
    }

    let lock_timeout = decode_packet_timeout("lock", &packet[8..16])?;
    let dpms_timeout = decode_packet_timeout("display power-off", &packet[16..24])?;
    let suspend_timeout = decode_packet_timeout("suspend", &packet[24..32])?;
    if lock_timeout > suspend_timeout {
        return Err(IdlePolicyPacketError::TimeoutAfterSuspend("lock"));
    }
    if dpms_timeout > suspend_timeout {
        return Err(IdlePolicyPacketError::TimeoutAfterSuspend(
            "display power-off",
        ));
    }

    Ok(IdlePolicyConfiguration {
        lock_timeout: (flags & LOCK_ENABLED != 0).then_some(lock_timeout),
        dpms_timeout: (flags & DPMS_ENABLED != 0).then_some(dpms_timeout),
        suspend_timeout: (flags & SUSPEND_ENABLED != 0).then_some(suspend_timeout),
    })
}

fn decode_packet_timeout(
    action: &'static str,
    bytes: &[u8],
) -> Result<Duration, IdlePolicyPacketError> {
    let milliseconds = u64::from_le_bytes(
        bytes
            .try_into()
            .expect("idle policy timeout has a fixed packet width"),
    );
    if milliseconds == 0 {
        return Err(IdlePolicyPacketError::ZeroTimeout(action));
    }
    decode_timeout(action, milliseconds)
}

fn decode_timeout(
    action: &'static str,
    milliseconds: u64,
) -> Result<Duration, IdlePolicyPacketError> {
    let timeout = Duration::from_millis(milliseconds);
    if timeout > MAX_TIMEOUT {
        return Err(IdlePolicyPacketError::TimeoutTooLarge {
            action,
            milliseconds,
        });
    }
    Ok(timeout)
}

#[derive(Debug)]
pub(super) struct IdlePolicy {
    configuration: IdlePolicyConfiguration,
    last_activity: Instant,
    inhibited: bool,
    lock_triggered: bool,
    dpms_triggered: bool,
    suspend_triggered: bool,
    blanked_outputs: BTreeSet<OutputId>,
}

impl Default for IdlePolicy {
    fn default() -> Self {
        Self {
            // Remain disabled until the persisted Flutter setting reaches the
            // compositor. This avoids applying a transient default while the
            // shell restores its settings file.
            configuration: IdlePolicyConfiguration::default(),
            last_activity: Instant::now(),
            inhibited: false,
            lock_triggered: false,
            dpms_triggered: false,
            suspend_triggered: false,
            blanked_outputs: BTreeSet::new(),
        }
    }
}

impl IdlePolicy {
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
        configuration: IdlePolicyConfiguration,
        now: Instant,
    ) -> Vec<IdlePowerRequest> {
        if self.configuration == configuration {
            return Vec::new();
        }
        self.configuration = configuration;
        self.reset_idle_interval(now);
        if configuration.dpms_timeout.is_none() {
            return self.wake_blanked_outputs();
        }
        Vec::new()
    }

    pub(super) fn note_activity(&mut self, now: Instant) -> Vec<IdlePowerRequest> {
        self.reset_idle_interval(now);
        self.wake_blanked_outputs()
    }

    pub(super) fn evaluate(
        &mut self,
        now: Instant,
        inhibited: bool,
        outputs: impl IntoIterator<Item = (OutputId, bool)>,
    ) -> IdlePolicyActions {
        if inhibited {
            if !std::mem::replace(&mut self.inhibited, true) {
                self.reset_idle_interval(now);
            }
            // If playback starts remotely or between the timeout edge and the
            // KMS transition, honor it immediately rather than requiring a
            // separate physical input event.
            return IdlePolicyActions {
                power_requests: self.wake_blanked_outputs(),
                ..IdlePolicyActions::default()
            };
        }
        if std::mem::replace(&mut self.inhibited, false) {
            // Give the user a full configured interval after playback ends.
            self.reset_idle_interval(now);
        }

        let outputs = outputs.into_iter().collect::<Vec<_>>();
        let live_outputs = outputs
            .iter()
            .map(|(output, _)| *output)
            .collect::<BTreeSet<_>>();
        self.blanked_outputs
            .retain(|output| live_outputs.contains(output));
        let elapsed = now.saturating_duration_since(self.last_activity);
        let mut actions = IdlePolicyActions::default();

        if !self.lock_triggered
            && self
                .configuration
                .lock_timeout
                .is_some_and(|timeout| elapsed >= timeout)
        {
            self.lock_triggered = true;
            actions.lock = true;
        }

        if !self.dpms_triggered
            && self
                .configuration
                .dpms_timeout
                .is_some_and(|timeout| elapsed >= timeout)
        {
            self.dpms_triggered = true;
            for (output, powered) in outputs {
                if powered && self.blanked_outputs.insert(output) {
                    actions.power_requests.push(IdlePowerRequest {
                        output,
                        powered: false,
                    });
                }
            }
        }

        // If display-off and suspend share a threshold, give the compositor
        // one dispatch boundary to commit DPMS before logind suspends.
        if actions.power_requests.is_empty()
            && !self.suspend_triggered
            && self
                .configuration
                .suspend_timeout
                .is_some_and(|timeout| elapsed >= timeout)
        {
            self.suspend_triggered = true;
            actions.suspend = true;
        }
        actions
    }

    /// The next instant at which inactivity can trigger an action.
    ///
    /// Input, inhibitor, configuration, and explicit power events wake the
    /// compositor independently. Between those edges the idle policy needs no
    /// polling; this deadline is the only timer it contributes.
    pub(super) fn next_deadline(&self) -> Option<Instant> {
        if self.inhibited {
            return None;
        }
        let mut deadline = None;
        if !self.lock_triggered {
            deadline = earlier(deadline, self.configuration.lock_timeout);
        }
        if !self.dpms_triggered {
            deadline = earlier(deadline, self.configuration.dpms_timeout);
        }
        if !self.suspend_triggered {
            deadline = earlier(deadline, self.configuration.suspend_timeout);
        }
        deadline.map(|timeout| self.last_activity + timeout)
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

    pub(super) fn note_power_failure(&mut self, output: OutputId, _now: Instant) {
        self.blanked_outputs.remove(&output);
        // `dpms_triggered` remains set so a rejected KMS transition does not
        // retry every event-loop turn or postpone later suspend.
    }

    fn reset_idle_interval(&mut self, now: Instant) {
        self.last_activity = now;
        self.lock_triggered = false;
        self.dpms_triggered = false;
        self.suspend_triggered = false;
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

fn earlier(current: Option<Duration>, candidate: Option<Duration>) -> Option<Duration> {
    match (current, candidate) {
        (Some(current), Some(candidate)) => Some(current.min(candidate)),
        (current, candidate) => current.or(candidate),
    }
}

#[cfg(test)]
#[path = "idle_policy/tests.rs"]
mod tests;
