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
const LEGACY_CONFIGURATION_PACKET_VERSION: u8 = 1;
const SUSPEND_MODE_CONFIGURATION_PACKET_VERSION: u8 = 2;
const POWER_BUTTON_CONFIGURATION_PACKET_VERSION: u8 = 3;
const PACKET_VERSION: u8 = 4;
const LOCK_ENABLED: u8 = 1 << 0;
const DPMS_ENABLED: u8 = 1 << 1;
const SUSPEND_ENABLED: u8 = 1 << 2;
const SCREEN_OFF_LOCK_ENABLED: u8 = 1 << 3;
const ENABLED_MASK: u8 = LOCK_ENABLED | DPMS_ENABLED | SUSPEND_ENABLED;
const DISPLAY_POWER_OFF: u8 = 1;
const DISPLAY_POWER_ON: u8 = 2;
const MAX_TIMEOUT: Duration = Duration::from_secs(7 * 24 * 60 * 60);
const LOCK_AFTER_DPMS_DELAY: Duration = Duration::from_secs(5);

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
    pub(super) suspend_mode: SuspendMode,
    pub(super) power_button_action: PowerButtonAction,
    /// How long a session stays unlocked once its screen goes dark, by the
    /// power button or by the idle timeout. None locks at once on the power
    /// button, unless idle locking is off too, and leaves idle locking to
    /// `lock_timeout`.
    pub(super) lock_after_screen_off: Option<Duration>,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
#[repr(u8)]
pub(super) enum PowerButtonAction {
    #[default]
    Dpms = 0,
    Suspend = 1,
    Hibernate = 2,
    PowerOff = 3,
}

impl PowerButtonAction {
    fn decode(value: u8) -> Option<Self> {
        match value {
            0 => Some(Self::Dpms),
            1 => Some(Self::Suspend),
            2 => Some(Self::Hibernate),
            3 => Some(Self::PowerOff),
            _ => None,
        }
    }

    pub(super) fn logind_method(self) -> Option<&'static str> {
        match self {
            Self::Dpms => None,
            Self::Suspend => Some("Suspend"),
            Self::Hibernate => Some("Hibernate"),
            Self::PowerOff => Some("PowerOff"),
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
#[repr(u8)]
pub(super) enum SuspendMode {
    #[default]
    SystemDefault = 0,
    S2Idle = 1,
    Shallow = 2,
    Deep = 3,
}

impl SuspendMode {
    fn decode(value: u8) -> Option<Self> {
        match value {
            0 => Some(Self::SystemDefault),
            1 => Some(Self::S2Idle),
            2 => Some(Self::Shallow),
            3 => Some(Self::Deep),
            _ => None,
        }
    }

    pub(super) fn kernel_value(self) -> Option<&'static str> {
        match self {
            Self::SystemDefault => None,
            Self::S2Idle => Some("s2idle"),
            Self::Shallow => Some("shallow"),
            Self::Deep => Some("deep"),
        }
    }
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
    InvalidSuspendMode(u8),
    InvalidPowerButtonAction(u8),
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
            Self::InvalidSuspendMode(mode) => {
                write!(
                    formatter,
                    "idle policy packet has invalid suspend mode {mode}"
                )
            }
            Self::InvalidPowerButtonAction(action) => {
                write!(
                    formatter,
                    "idle policy packet has invalid power button action {action}"
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
        formatter.write_str("display power packet must contain a one-byte DPMS command")
    }
}

impl Error for DisplayPowerPacketError {}

/// What the shell asks of the displays.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum DisplayPowerRequest {
    /// The screen goes dark as the power button turns it off.
    Off,
    /// The dark displays light up, as an input would light them: a
    /// notification arrived.
    On,
}

pub(super) fn decode_display_power(
    packet: &[u8],
) -> Result<DisplayPowerRequest, DisplayPowerPacketError> {
    match packet {
        [DISPLAY_POWER_OFF] => Ok(DisplayPowerRequest::Off),
        [DISPLAY_POWER_ON] => Ok(DisplayPowerRequest::On),
        _ => Err(DisplayPowerPacketError::InvalidPacket),
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
    let mut lock_after_screen_off = None;
    let mut enabled_mask = ENABLED_MASK;
    let (suspend_mode, power_button_action) = match packet[0] {
        LEGACY_CONFIGURATION_PACKET_VERSION => {
            if packet[2..8].iter().any(|byte| *byte != 0) {
                return Err(IdlePolicyPacketError::NonZeroReservedBytes);
            }
            (SuspendMode::SystemDefault, PowerButtonAction::Dpms)
        }
        SUSPEND_MODE_CONFIGURATION_PACKET_VERSION => {
            if packet[3..8].iter().any(|byte| *byte != 0) {
                return Err(IdlePolicyPacketError::NonZeroReservedBytes);
            }
            (
                SuspendMode::decode(packet[2])
                    .ok_or(IdlePolicyPacketError::InvalidSuspendMode(packet[2]))?,
                PowerButtonAction::Dpms,
            )
        }
        POWER_BUTTON_CONFIGURATION_PACKET_VERSION => {
            if packet[4..8].iter().any(|byte| *byte != 0) {
                return Err(IdlePolicyPacketError::NonZeroReservedBytes);
            }
            (
                SuspendMode::decode(packet[2])
                    .ok_or(IdlePolicyPacketError::InvalidSuspendMode(packet[2]))?,
                PowerButtonAction::decode(packet[3])
                    .ok_or(IdlePolicyPacketError::InvalidPowerButtonAction(packet[3]))?,
            )
        }
        PACKET_VERSION => {
            enabled_mask |= SCREEN_OFF_LOCK_ENABLED;
            let milliseconds = u32::from_le_bytes(
                packet[4..8]
                    .try_into()
                    .expect("screen-off lock delay has a fixed packet width"),
            );
            if packet[1] & SCREEN_OFF_LOCK_ENABLED != 0 {
                lock_after_screen_off =
                    Some(decode_timeout("screen-off lock", u64::from(milliseconds))?);
            } else if milliseconds != 0 {
                return Err(IdlePolicyPacketError::NonZeroReservedBytes);
            }
            (
                SuspendMode::decode(packet[2])
                    .ok_or(IdlePolicyPacketError::InvalidSuspendMode(packet[2]))?,
                PowerButtonAction::decode(packet[3])
                    .ok_or(IdlePolicyPacketError::InvalidPowerButtonAction(packet[3]))?,
            )
        }
        version => return Err(IdlePolicyPacketError::UnsupportedVersion(version)),
    };
    let flags = packet[1];
    if flags & !enabled_mask != 0 {
        return Err(IdlePolicyPacketError::InvalidFlags(flags));
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
        suspend_mode,
        power_button_action,
        lock_after_screen_off,
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

/// Physical power keys are consumed before ordinary input-to-wake handling.
/// Releases and duplicate presses must never reverse the requested transition.
/// With `chords` (the mobile shell), Power and Volume Down together, in
/// either order, take a screenshot instead.
#[derive(Default)]
pub(super) struct PowerButton {
    held_devices: BTreeSet<String>,
    toggle_pending: bool,
    volume_down_held: bool,
    /// Volume Down's press waits for Power, which may follow at once.
    volume_down_held_back: bool,
    /// Volume Down's press went to a screenshot, so its release does too.
    volume_down_taken: bool,
    screenshot_requested: bool,
}

/// Where a Volume Down transition goes.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum VolumeDownRoute {
    /// To the seat, as usual.
    Deliver,
    /// Nowhere: it is part of a screenshot.
    Take,
    /// Nowhere yet: Power may follow. Deliver the press once
    /// `take_held_volume_down` says it still waits.
    HoldBack,
    /// A release while the press waited: deliver the press, then this.
    DeliverHeldPress,
}

impl PowerButton {
    pub(super) fn note_key(&mut self, device: &str, pressed: bool, chords: bool) {
        if pressed {
            if self.held_devices.insert(device.to_owned()) {
                if chords && self.volume_down_held {
                    self.screenshot_requested = true;
                    // A press that still waits never reaches the seat.
                    self.volume_down_taken = std::mem::take(&mut self.volume_down_held_back);
                } else {
                    self.toggle_pending = !self.toggle_pending;
                }
            }
        } else {
            self.held_devices.remove(device);
        }
    }

    pub(super) fn note_volume_down(&mut self, pressed: bool, chords: bool) -> VolumeDownRoute {
        if !pressed {
            self.volume_down_held = false;
            if std::mem::take(&mut self.volume_down_taken) {
                return VolumeDownRoute::Take;
            }
            if std::mem::take(&mut self.volume_down_held_back) {
                return VolumeDownRoute::DeliverHeldPress;
            }
            return VolumeDownRoute::Deliver;
        }
        self.volume_down_held = true;
        if !chords {
            return VolumeDownRoute::Deliver;
        }
        if !self.held_devices.is_empty() {
            // Power's toggle waits for its release; the chord cancels it.
            self.toggle_pending = false;
            self.screenshot_requested = true;
            self.volume_down_taken = true;
            return VolumeDownRoute::Take;
        }
        self.volume_down_held_back = true;
        VolumeDownRoute::HoldBack
    }

    /// Power did not follow: whether the held press still waits, now to be
    /// delivered.
    pub(super) fn take_held_volume_down(&mut self) -> bool {
        std::mem::take(&mut self.volume_down_held_back)
    }

    pub(super) fn remove_device(&mut self, device: &str) {
        self.held_devices.remove(device);
    }

    /// The toggle a press asked for. With `wait_for_release` it comes only
    /// once the button is up, so Volume Down can still turn it into a
    /// screenshot.
    pub(super) fn take_toggle(&mut self, wait_for_release: bool) -> bool {
        if wait_for_release && !self.held_devices.is_empty() {
            return false;
        }
        std::mem::take(&mut self.toggle_pending)
    }

    pub(super) fn take_screenshot(&mut self) -> bool {
        std::mem::take(&mut self.screenshot_requested)
    }
}

/// While a desk shares the session, the phone's panel keeps its own idle
/// clock: it goes dark when nobody touches it, and the power button turns
/// only it off and on, without locking.
#[derive(Debug)]
struct PhoneScreen {
    output: OutputId,
    last_touch: Instant,
    dpms_triggered: bool,
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
    manually_blanked: bool,
    /// When the dark screen locks, while `lock_after_screen_off` counts.
    screen_off_lock_at: Option<Instant>,
    phone: Option<PhoneScreen>,
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
            manually_blanked: false,
            screen_off_lock_at: None,
            phone: None,
        }
    }
}

impl IdlePolicy {
    pub(super) fn power_button_action(&self) -> PowerButtonAction {
        self.configuration.power_button_action
    }

    /// Follows a desk joining the phone (`phone` names the phone's panel) or
    /// leaving it. Returns whether to lock: the phone's panel went dark at the
    /// desk without locking, and it is now the only screen.
    pub(super) fn set_phone_with_desk(&mut self, phone: Option<OutputId>, now: Instant) -> bool {
        let current = self.phone.as_ref().map(|screen| screen.output);
        if current == phone {
            return false;
        }
        self.phone = phone.map(|output| PhoneScreen {
            output,
            last_touch: now,
            dpms_triggered: false,
        });
        match (current, phone) {
            (Some(output), None) if self.blanked_outputs.contains(&output) => {
                self.manually_blanked = true;
                self.screen_went_off(now)
                    .unwrap_or(self.configuration.lock_timeout.is_some())
            }
            _ => false,
        }
    }

    /// Whether the phone's panel keeps its own idle clock.
    pub(super) fn phone_output(&self) -> Option<OutputId> {
        self.phone.as_ref().map(|screen| screen.output)
    }

    /// A finger touched the phone's panel.
    pub(super) fn note_phone_touch(&mut self, now: Instant) {
        if let Some(phone) = self.phone.as_mut() {
            phone.last_touch = now;
            phone.dpms_triggered = false;
        }
    }

    /// The phone's panel goes dark once nobody touched it for the display
    /// timeout, while the desk keeps its own. A visible inhibitor on the
    /// phone holds it lit.
    pub(super) fn evaluate_phone(
        &mut self,
        now: Instant,
        inhibited: bool,
        powered: bool,
    ) -> Option<IdlePowerRequest> {
        let timeout = self.configuration.dpms_timeout;
        let phone = self.phone.as_mut()?;
        if inhibited {
            phone.last_touch = now;
            phone.dpms_triggered = false;
            return None;
        }
        if phone.dpms_triggered
            || !powered
            || timeout.is_none_or(|timeout| now.saturating_duration_since(phone.last_touch) < timeout)
        {
            return None;
        }
        phone.dpms_triggered = true;
        self.blanked_outputs.insert(phone.output);
        Some(IdlePowerRequest {
            output: phone.output,
            powered: false,
        })
    }

    /// A physical power press overrides the current output power state, even
    /// when an external power client originally switched the displays off.
    /// With a desk, it turns only the phone's panel off and on and never
    /// locks: the user goes on at the desk.
    pub(super) fn toggle_now(
        &mut self,
        outputs: impl IntoIterator<Item = (OutputId, bool)>,
        now: Instant,
    ) -> IdlePolicyActions {
        self.reset_idle_interval(now);
        let outputs = outputs.into_iter().collect::<Vec<_>>();
        if let Some(phone) = self.phone.as_mut() {
            let output = phone.output;
            let powered = outputs
                .iter()
                .any(|(candidate, powered)| *candidate == output && *powered);
            if powered {
                phone.dpms_triggered = true;
                self.blanked_outputs.insert(output);
            } else {
                phone.last_touch = now;
                phone.dpms_triggered = false;
                self.blanked_outputs.remove(&output);
            }
            return IdlePolicyActions {
                power_requests: vec![IdlePowerRequest {
                    output,
                    powered: !powered,
                }],
                ..IdlePolicyActions::default()
            };
        }
        if outputs.iter().any(|(_, powered)| *powered) {
            IdlePolicyActions {
                power_requests: self.blank_now(outputs),
                lock: self
                    .screen_went_off(now)
                    .unwrap_or(self.configuration.lock_timeout.is_some()),
                ..IdlePolicyActions::default()
            }
        } else {
            self.blanked_outputs.clear();
            self.manually_blanked = false;
            self.screen_off_lock_at = None;
            IdlePolicyActions {
                power_requests: outputs
                    .into_iter()
                    .map(|(output, _)| IdlePowerRequest {
                        output,
                        powered: true,
                    })
                    .collect(),
                ..IdlePolicyActions::default()
            }
        }
    }

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
        self.manually_blanked |= !requests.is_empty();
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

    /// A hardware wake gesture targets one display, including an externally
    /// blanked display. It can never toggle a lit display off or unlock.
    pub(super) fn wake_output_now(&mut self, output: OutputId, now: Instant) -> IdlePowerRequest {
        self.reset_idle_interval(now);
        if let Some(phone) = self.phone.as_mut().filter(|phone| phone.output == output) {
            phone.last_touch = now;
            phone.dpms_triggered = false;
        }
        self.blanked_outputs.remove(&output);
        self.manually_blanked &= !self.blanked_outputs.is_empty();
        self.screen_off_lock_at = None;
        IdlePowerRequest {
            output,
            powered: true,
        }
    }

    /// How long the user has not touched any input device.
    pub(super) fn idle_for(&self, now: Instant) -> Duration {
        now.saturating_duration_since(self.last_activity)
    }

    pub(super) fn note_activity(&mut self, now: Instant) -> Vec<IdlePowerRequest> {
        self.reset_idle_interval(now);
        self.wake_blanked_outputs()
    }

    pub(super) fn evaluate<I>(
        &mut self,
        now: Instant,
        inhibited: bool,
        outputs: I,
    ) -> IdlePolicyActions
    where
        I: IntoIterator<Item = (OutputId, bool)>,
        I::IntoIter: Clone,
    {
        // The dark screen locks on time even while playback holds idling
        // off: the user chose to turn it off.
        let screen_off_lock = self.screen_off_lock_at.is_some_and(|at| now >= at);
        if screen_off_lock {
            self.screen_off_lock_at = None;
        }
        if inhibited {
            if !std::mem::replace(&mut self.inhibited, true) {
                self.reset_idle_interval(now);
            }
            // If playback starts remotely or between the timeout edge and the
            // KMS transition, honor it immediately rather than requiring a
            // separate physical input event.
            return IdlePolicyActions {
                // Inhibitors prevent automatic sleep; they cannot undo the
                // user's power button or explicit screen-off request.
                power_requests: if self.manually_blanked {
                    Vec::new()
                } else {
                    self.wake_blanked_outputs()
                },
                lock: screen_off_lock,
                ..IdlePolicyActions::default()
            };
        }
        if std::mem::replace(&mut self.inhibited, false) {
            // Give the user a full configured interval after playback ends.
            self.reset_idle_interval(now);
        }

        let outputs = outputs.into_iter();
        self.blanked_outputs
            .retain(|blanked| outputs.clone().any(|(output, _)| output == *blanked));
        let elapsed = now.saturating_duration_since(self.last_activity);
        let mut actions = IdlePolicyActions {
            lock: screen_off_lock,
            ..IdlePolicyActions::default()
        };

        if !self.lock_triggered
            && self
                .effective_lock_timeout()
                .is_some_and(|timeout| elapsed >= timeout)
        {
            self.lock_triggered = true;
            actions.lock = true;
        }

        let phone = self.phone_output();
        if !self.dpms_triggered
            && self
                .configuration
                .dpms_timeout
                .is_some_and(|timeout| elapsed >= timeout)
        {
            self.dpms_triggered = true;
            // The phone's panel keeps its own clock beside a desk.
            for (output, powered) in outputs.clone().filter(|(output, _)| Some(*output) != phone) {
                if powered && self.blanked_outputs.insert(output) {
                    actions.power_requests.push(IdlePowerRequest {
                        output,
                        powered: false,
                    });
                }
            }
            if !actions.power_requests.is_empty() && self.screen_went_off(now) == Some(true) {
                actions.lock = true;
            }
        }

        // If display-off and suspend share a threshold, give the compositor
        // one dispatch boundary to commit DPMS before logind suspends.
        // Beside a desk, nothing suspends while a screen is still lit.
        if actions.power_requests.is_empty()
            && (phone.is_none() || !outputs.clone().any(|(_, powered)| powered))
            && !self.suspend_triggered
            && self
                .effective_suspend_timeout()
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
        let phone = self.phone.as_ref().and_then(|phone| {
            (!phone.dpms_triggered)
                .then_some(self.configuration.dpms_timeout?)
                .map(|timeout| phone.last_touch + timeout)
        });
        let idle = match (self.next_idle_deadline(), phone) {
            (Some(idle), Some(phone)) => Some(idle.min(phone)),
            (idle, phone) => idle.or(phone),
        };
        match (idle, self.screen_off_lock_at) {
            (Some(idle), Some(lock)) => Some(idle.min(lock)),
            (idle, lock) => idle.or(lock),
        }
    }

    fn next_idle_deadline(&self) -> Option<Instant> {
        if self.inhibited {
            return None;
        }
        let mut deadline = None;
        if !self.lock_triggered {
            deadline = earlier(deadline, self.effective_lock_timeout());
        }
        if !self.dpms_triggered {
            deadline = earlier(deadline, self.configuration.dpms_timeout);
        }
        if !self.suspend_triggered {
            deadline = earlier(deadline, self.effective_suspend_timeout());
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

    /// The screen just went dark: with a screen-off delay configured,
    /// whether to lock now, else when, kept for `evaluate`. None when no
    /// delay is configured.
    fn screen_went_off(&mut self, now: Instant) -> Option<bool> {
        let delay = self.configuration.lock_after_screen_off?;
        if delay.is_zero() {
            return Some(true);
        }
        self.screen_off_lock_at.get_or_insert(now + delay);
        Some(false)
    }

    fn effective_lock_timeout(&self) -> Option<Duration> {
        self.configuration.lock_timeout.map(|timeout| {
            if self.configuration.dpms_timeout == Some(timeout) {
                timeout + LOCK_AFTER_DPMS_DELAY
            } else {
                timeout
            }
        })
    }

    fn effective_suspend_timeout(&self) -> Option<Duration> {
        self.configuration.suspend_timeout.map(|timeout| {
            self.effective_lock_timeout()
                .map_or(timeout, |lock_timeout| timeout.max(lock_timeout))
        })
    }

    /// Beside a desk, the phone's dark panel stays dark: only its power
    /// button, a wake gesture or a touch on it light it.
    fn wake_blanked_outputs(&mut self) -> Vec<IdlePowerRequest> {
        self.manually_blanked = false;
        self.screen_off_lock_at = None;
        let mut blanked = std::mem::take(&mut self.blanked_outputs);
        if let Some(phone) = self.phone_output()
            && blanked.remove(&phone)
        {
            self.blanked_outputs.insert(phone);
        }
        blanked
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
