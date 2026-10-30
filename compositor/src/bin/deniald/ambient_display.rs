//! Always-on display on the mobile shell.
//!
//! A root-owned `/etc/denial/ambient-display.json` names the output whose
//! panel keeps showing its last frame while the output is off, and the file
//! that says whether it does now:
//!
//! ```json
//! { "output": "DSI-1", "switch": "/sys/module/panel_raydium_rm692h5/parameters/ambient" }
//! ```
//!
//! While the switch reads `Y` or `1`, turning that output off goes through
//! the lock screen first: the session locks, the shell fades everything but
//! the always-on picture to black and says when it is on screen, and only
//! then does the output turn off. Once the output is lit again the shell
//! fades the rest back in.

use std::collections::BTreeSet;
use std::ffi::CStr;
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use denial_core::topology::OutputId;
use serde::Deserialize;
use tracing::{info, warn};

use super::RuntimeState;
use super::flutter_runtime::FlutterRuntime;
use super::kms_state::Scanout;

pub(super) const CHANNEL: &CStr = c"denial/ambient_display";
const PROFILE_PATH: &str = "/etc/denial/ambient-display.json";
const ENTER: u8 = 1;
const LEAVE: u8 = 2;
const READY: u8 = 1;

/// The shell's fade is 420 ms; past this the output turns off anyway.
const FADE_LIMIT: Duration = Duration::from_millis(1200);

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Profile {
    output: String,
    switch: PathBuf,
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

    fn armed(&self) -> bool {
        fs::read_to_string(&self.switch).is_ok_and(|value| matches!(value.trim(), "Y" | "y" | "1"))
    }
}

pub(super) fn decode_ready(packet: &[u8]) -> bool {
    packet == [READY]
}

#[derive(Debug, Default)]
pub(super) struct AmbientDisplay {
    /// Loaded on first use; None inside when there is no usable profile.
    profile: Option<Option<Profile>>,
    /// A power-off held while the shell fades, with its deadline.
    held: Option<(OutputId, Instant)>,
    /// A held power-off the shell let through, until the output is off.
    released: Option<OutputId>,
    /// Outputs whose shell shows the always-on picture.
    entered: BTreeSet<OutputId>,
    /// Entered outputs seen off: lit again, they ask for the rest back.
    dark: BTreeSet<OutputId>,
}

impl AmbientDisplay {
    fn profile(&mut self) -> Option<&Profile> {
        self.profile
            .get_or_insert_with(|| {
                let path = Path::new(PROFILE_PATH);
                if !path.exists() {
                    return None;
                }
                match Profile::load(path) {
                    Ok(profile) => {
                        info!(output = %profile.output, "always-on display profile loaded");
                        Some(profile)
                    }
                    Err(error) => {
                        warn!(%error, "always-on display profile rejected");
                        None
                    }
                }
            })
            .as_ref()
    }

    pub(super) fn limit_dispatch_timeout(&self, now: Instant, timeout: Duration) -> Duration {
        self.held.map_or(timeout, |(_, deadline)| {
            timeout.min(deadline.saturating_duration_since(now))
        })
    }
}

/// Holds the always-on output's power-off until the shell shows the picture,
/// and lets a wake during the fade cancel it. Runs before power requests
/// are applied.
pub(super) fn hold_power_off(
    runtime: &mut FlutterRuntime,
    scanouts: &[Scanout],
    events: &mut RuntimeState,
    now: Instant,
) {
    let ready = runtime.take_ambient_display_ready();
    if let Some((output, deadline)) = events.ambient_display.held {
        match events.output_power_requests.get(&output) {
            Some(true) => {
                // Woken while fading: the output stays lit.
                events.ambient_display.held = None;
                events.ambient_display.entered.remove(&output);
                send(runtime, LEAVE);
                info!("always-on display cancelled by a wake");
            }
            _ if ready || now >= deadline => {
                events.ambient_display.held = None;
                events.ambient_display.released = Some(output);
                events.output_power_requests.insert(output, false);
                if !ready {
                    warn!("shell did not show the always-on picture in time");
                }
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
        send(runtime, LEAVE);
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
    info!("always-on display: waiting for the shell's picture");
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
    let (name, armed) = {
        let profile = events.ambient_display.profile()?;
        (profile.output.clone(), profile.armed())
    };
    let scanout = scanouts
        .iter()
        .find(|scanout| scanout.output.name == name && scanout.powered)?;
    let output = scanout.output.id;
    (armed && events.output_power_requests.get(&output) == Some(&false)).then_some(output)
}

/// Asks the shell for the rest of the lock screen once the output is lit
/// again. Runs after power requests are applied.
pub(super) fn synchronize_wake(
    runtime: &mut FlutterRuntime,
    scanouts: &[Scanout],
    events: &mut RuntimeState,
) {
    let state = &mut events.ambient_display;
    let mut woke = false;
    for scanout in scanouts {
        let output = scanout.output.id;
        if !state.entered.contains(&output) {
            continue;
        }
        if !scanout.powered {
            state.dark.insert(output);
            if state.released == Some(output) {
                state.released = None;
            }
        } else if state.dark.remove(&output) {
            state.entered.remove(&output);
            woke = true;
        }
    }
    if woke {
        send(runtime, LEAVE);
    }
}

fn send(runtime: &mut FlutterRuntime, command: u8) {
    if let Err(error) = runtime.send_ambient_display(command) {
        warn!(%error, "could not tell the shell about the always-on display");
    }
}
