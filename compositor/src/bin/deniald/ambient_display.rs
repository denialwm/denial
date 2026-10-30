//! Always-on display on the mobile shell.
//!
//! A root-owned `/etc/denial/ambient-display.json` names the output whose
//! panel can keep showing its last frame while the output is off, and the
//! panel driver's switch for that:
//!
//! ```json
//! {
//!   "output": "DSI-1",
//!   "switch": "/sys/module/panel_raydium_rm692h5/parameters/ambient",
//!   "brightness": 400,
//!   "settle_ms": 1000
//! }
//! ```
//!
//! Turning that output off while the session locks goes through the lock
//! screen first: the shell fades everything but the always-on picture to
//! black and says when it is on screen, the backlight fades to the
//! `brightness` code beside it, and the output turns off with the switch set.
//! The panel driver then keeps the picture lit its own way. A panel that
//! refreshes as slowly as 1 Hz stays in normal mode at that rate, showing the
//! picture at that code unchanged; one that cannot uses its always-on mode,
//! and the code is the one whose picture looks like that mode's. `settle_ms`
//! keeps the finished picture still that long before the output turns off,
//! for a panel that draws a wave when it changes mode at full rate.
//!
//! Each minute the output lights for one frame, the clock's next minute, and
//! goes off again with the switch still set, so the panel keeps its
//! always-on state. A wake clears the switch, and the shell fades the rest
//! back in beside the backlight.
//!
//! The session must be able to write the switch. An edited profile applies
//! from the next blank.

use std::collections::BTreeSet;
use std::ffi::CStr;
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use denial_core::topology::OutputId;
use serde::Deserialize;
use tracing::{info, warn};

use super::RuntimeState;
use super::flutter_runtime::FlutterRuntime;
use super::kms_state::Scanout;
use super::output_scheduler::OutputScheduler;
use super::system_controls::BrightnessFade;

pub(super) const CHANNEL: &CStr = c"denial/ambient_display";
const PROFILE_PATH: &str = "/etc/denial/ambient-display.json";
const ENTER: u8 = 1;
const LEAVE: u8 = 2;
const READY: u8 = 1;

/// The shell's fade, which the backlight's follows.
const SHELL_FADE: Duration = Duration::from_millis(420);

/// Past this the output turns off anyway.
const FADE_LIMIT: Duration = Duration::from_millis(1200);

/// The shell's clock turns over on the minute; its frame follows.
const REFRESH_LAG: Duration = Duration::from_millis(250);

/// Past this a refresh's output turns off without its frame.
const REFRESH_LIMIT: Duration = Duration::from_secs(2);

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Profile {
    output: String,
    switch: PathBuf,
    brightness: u32,
    #[serde(default)]
    settle_ms: u64,
}

impl Profile {
    fn load(path: &Path) -> Result<Self, String> {
        let metadata = fs::symlink_metadata(path).map_err(|error| error.to_string())?;
        if !metadata.is_file()
            || metadata.uid() != 0
            || metadata.mode() & 0o022 != 0
            || metadata.len() > 4096
        {
            return Err("profile must be a root-owned, protected regular file".into());
        }
        let bytes = fs::read(path).map_err(|error| error.to_string())?;
        serde_json::from_slice(&bytes).map_err(|error| error.to_string())
    }
}

pub(super) fn decode_ready(packet: &[u8]) -> bool {
    packet == [READY]
}

/// An output lit only to draw the next minute.
#[derive(Clone, Copy, Debug)]
struct Refresh {
    output: OutputId,
    started: Instant,
    /// The frame is out and the output's power-off queued.
    shown: bool,
}

#[derive(Debug, Default)]
pub(super) struct AmbientDisplay {
    /// Loaded on use and again whenever the file changes, keyed by its
    /// modification time; None inside when there is no usable profile.
    profile: Option<(Option<SystemTime>, Option<Profile>)>,
    /// What the switch was last set to.
    switched: Option<bool>,
    /// A power-off held while the shell fades, with its deadline.
    held: Option<(OutputId, Instant)>,
    /// The held power-off waits on a still picture, not on the shell.
    settling: bool,
    /// A held power-off the shell let through, until the output is off.
    released: Option<OutputId>,
    /// Outputs whose shell shows the always-on picture.
    entered: BTreeSet<OutputId>,
    /// Entered outputs seen off: lit again by anything but a refresh, they
    /// ask for the rest back.
    dark: BTreeSet<OutputId>,
    /// When the next minute's frame is due.
    refresh_due: Option<Instant>,
    refresh: Option<Refresh>,
}

impl AmbientDisplay {
    fn profile(&mut self) -> Option<&Profile> {
        let path = Path::new(PROFILE_PATH);
        let modified = fs::symlink_metadata(path)
            .and_then(|metadata| metadata.modified())
            .ok();
        if self
            .profile
            .as_ref()
            .is_none_or(|(key, _)| *key != modified)
        {
            let profile = modified.and_then(|_| match Profile::load(path) {
                Ok(profile) => {
                    info!(output = %profile.output, "always-on display profile loaded");
                    Some(profile)
                }
                Err(error) => {
                    warn!(%error, "always-on display profile rejected");
                    None
                }
            });
            self.profile = Some((modified, profile));
            if self.entered.is_empty() {
                // A switch left set would keep an unlocked blank lit.
                self.switched = None;
                self.set_switch(false);
            }
        }
        self.profile.as_ref()?.1.as_ref()
    }

    fn set_switch(&mut self, on: bool) {
        if self.switched == Some(on) {
            return;
        }
        let Some(path) = self
            .profile
            .as_ref()
            .and_then(|(_, profile)| profile.as_ref())
            .map(|profile| profile.switch.clone())
        else {
            return;
        };
        match fs::write(&path, if on { "Y" } else { "N" }) {
            Ok(()) => self.switched = Some(on),
            Err(error) => {
                warn!(%error, path = %path.display(), "could not set the always-on display switch");
            }
        }
    }

    /// Lit only to draw the next minute: still dark to everything else.
    pub(super) fn refreshing(&self, output: OutputId) -> bool {
        self.refresh.is_some_and(|refresh| refresh.output == output)
    }

    pub(super) fn refresh_under_way(&self) -> bool {
        self.refresh.is_some()
    }

    pub(super) fn limit_dispatch_timeout(&self, now: Instant, timeout: Duration) -> Duration {
        [
            self.held.map(|(_, deadline)| deadline),
            self.refresh_due,
            self.refresh.map(|refresh| refresh.started + REFRESH_LIMIT),
        ]
        .into_iter()
        .flatten()
        .fold(timeout, |timeout, deadline| {
            timeout.min(deadline.saturating_duration_since(now))
        })
    }
}

/// Holds the always-on output's power-off until the shell shows the picture,
/// lets a wake during the fade cancel it, and runs each minute's refresh.
/// Runs before power requests are applied.
pub(super) fn hold_power_off(
    runtime: &mut FlutterRuntime,
    scheduler: &OutputScheduler,
    scanouts: &[Scanout],
    events: &mut RuntimeState,
    now: Instant,
) {
    let ready = runtime.take_ambient_display_ready();
    if refresh(runtime, scheduler, scanouts, events, now) {
        return;
    }
    if let Some((output, deadline)) = events.ambient_display.held {
        match events.output_power_requests.get(&output) {
            Some(true) => {
                // Woken while fading: the output stays lit.
                events.ambient_display.held = None;
                events.ambient_display.settling = false;
                events.ambient_display.entered.remove(&output);
                leave(runtime, events);
                info!("always-on display cancelled by a wake");
            }
            _ if !events.ambient_display.settling && (ready || now >= deadline) => {
                if !ready {
                    warn!("shell did not show the always-on picture in time");
                }
                let settle = events
                    .ambient_display
                    .profile()
                    .map_or(Duration::ZERO, |profile| {
                        Duration::from_millis(profile.settle_ms)
                    });
                events.ambient_display.held = Some((output, now + settle));
                events.ambient_display.settling = true;
                events.output_power_requests.remove(&output);
            }
            _ if events.ambient_display.settling && now >= deadline => {
                events.ambient_display.held = None;
                events.ambient_display.settling = false;
                events.ambient_display.released = Some(output);
                events.ambient_display.set_switch(true);
                events.output_power_requests.insert(output, false);
            }
            _ => {
                events.output_power_requests.remove(&output);
            }
        }
        return;
    }

    if let Some(output) = events
        .ambient_display
        .released
        .filter(|output| events.output_power_requests.get(output) == Some(&true))
    {
        // Woken before the output went off: it stays lit.
        events.ambient_display.released = None;
        events.ambient_display.entered.remove(&output);
        leave(runtime, events);
        return;
    }
    let Some(output) = power_off_to_hold(scanouts, events) else {
        return;
    };
    if events.ambient_display.released == Some(output) {
        return;
    }
    let locked = events
        .authentication
        .as_ref()
        .is_some_and(|authentication| authentication.lock_automatically());
    if !locked {
        // The always-on picture is the lock screen's; without one the
        // output turns off as usual.
        return;
    }
    super::synchronize_authentication_boundary(events);
    events.output_power_requests.remove(&output);
    events.ambient_display.held = Some((output, now + FADE_LIMIT));
    events.ambient_display.entered.insert(output);
    send(runtime, ENTER);
    fade_backlight(events, true);
    info!("always-on display: waiting for the shell's picture");
}

/// Lights a dark always-on output for each minute's frame, and turns it off
/// again once the frame is out. True while one is under way.
fn refresh(
    runtime: &mut FlutterRuntime,
    scheduler: &OutputScheduler,
    scanouts: &[Scanout],
    events: &mut RuntimeState,
    now: Instant,
) -> bool {
    let state = &mut events.ambient_display;
    if let Some(mut refresh) = state.refresh {
        let output = refresh.output;
        let Some(scanout) = scanouts.iter().find(|scanout| scanout.output.id == output) else {
            state.refresh = None;
            return false;
        };
        if events.output_power_requests.get(&output) == Some(&true) {
            // Woken meanwhile: the panel leaves its always-on state lit.
            state.refresh = None;
            state.dark.remove(&output);
            state.entered.remove(&output);
            leave(runtime, events);
            info!("always-on display woken during a refresh");
            return false;
        }
        if refresh.shown {
            if !scanout.powered {
                state.refresh = None;
                state.refresh_due = Some(next_minute(now));
            }
        } else if scanout.powered && !scheduler.power_on_pending(output)
            || now >= refresh.started + REFRESH_LIMIT
        {
            if now >= refresh.started + REFRESH_LIMIT {
                warn!("always-on refresh frame did not come in time");
            }
            refresh.shown = true;
            state.refresh = Some(refresh);
            events.output_power_requests.insert(output, false);
        }
        return true;
    }

    if state.held.is_some() || state.refresh_due.is_none_or(|due| now < due) {
        return false;
    }
    state.refresh_due = None;
    let Some(output) = state.dark.first().copied() else {
        return false;
    };
    let dark = scanouts
        .iter()
        .any(|scanout| scanout.output.id == output && !scanout.powered);
    if !dark || events.output_power_requests.contains_key(&output) {
        return false;
    }
    state.refresh = Some(Refresh {
        output,
        started: now,
        shown: false,
    });
    events.output_power_requests.insert(output, true);
    true
}

/// The instant the shell's clock shows the next minute.
fn next_minute(now: Instant) -> Instant {
    let into = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(Duration::ZERO, |since| {
            Duration::from_millis((since.as_millis() % 60_000) as u64)
        });
    now + (Duration::from_secs(60) - into) + REFRESH_LAG
}

/// The lit output whose power-off the always-on display takes over.
fn power_off_to_hold(scanouts: &[Scanout], events: &mut RuntimeState) -> Option<OutputId> {
    let mobile = events
        .wayland
        .as_ref()
        .is_some_and(|frontend| frontend.mobile_shell());
    if !mobile {
        return None;
    }
    let name = events.ambient_display.profile()?.output.clone();
    let scanout = scanouts
        .iter()
        .find(|scanout| scanout.output.name == name && scanout.powered)?;
    let output = scanout.output.id;
    (events.output_power_requests.get(&output) == Some(&false)).then_some(output)
}

/// Asks the shell for the rest of the lock screen once the output is lit
/// again, and keeps touches out of a refresh. Runs after power requests are
/// applied.
pub(super) fn synchronize_wake(
    runtime: &mut FlutterRuntime,
    scanouts: &[Scanout],
    events: &mut RuntimeState,
) {
    let state = &mut events.ambient_display;
    let mut woke = false;
    for scanout in scanouts {
        let output = scanout.output.id;
        if !state.entered.contains(&output) || state.refreshing(output) {
            continue;
        }
        if !scanout.powered {
            if state.dark.insert(output) {
                state.refresh_due = Some(next_minute(Instant::now()));
            }
            if state.released == Some(output) {
                state.released = None;
            }
        } else if state.dark.remove(&output) {
            state.entered.remove(&output);
            woke = true;
        }
    }
    if woke {
        leave(runtime, events);
    }
    let refreshing = events.ambient_display.refresh.is_some();
    events.screen_off_touch.set_dark(refreshing);
}

/// Asks the shell for the rest of the lock screen, the panel for its usual
/// state and the backlight for its level.
fn leave(runtime: &mut FlutterRuntime, events: &mut RuntimeState) {
    let state = &mut events.ambient_display;
    state.refresh_due = None;
    state.refresh = None;
    state.set_switch(false);
    send(runtime, LEAVE);
    fade_backlight(events, false);
}

/// Fades the always-on output's backlight to the picture's code, or back.
fn fade_backlight(events: &mut RuntimeState, dim: bool) {
    let Some(profile) = events.ambient_display.profile() else {
        return;
    };
    let toward = if dim {
        BrightnessFade::Dim {
            raw: profile.brightness,
            duration: SHELL_FADE,
        }
    } else {
        BrightnessFade::Restore {
            duration: SHELL_FADE,
        }
    };
    let output = profile.output.clone();
    if let Some(controls) = &events.system_controls {
        controls.fade_brightness(output, toward);
    }
}

fn send(runtime: &mut FlutterRuntime, command: u8) {
    if let Err(error) = runtime.send_ambient_display(command) {
        warn!(%error, "could not tell the shell about the always-on display");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn next_minute_lands_just_after_the_minute() {
        let now = Instant::now();
        let wait = next_minute(now) - now;
        assert!(wait > REFRESH_LAG && wait <= Duration::from_secs(60) + REFRESH_LAG);
    }
}
