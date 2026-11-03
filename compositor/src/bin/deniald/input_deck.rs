//! Embedded input deck protocol. Never exposed on the public control socket.
use std::collections::{BTreeMap, BTreeSet, VecDeque};

use serde::{Deserialize, Serialize};

#[path = "input_deck/gestures.rs"]
mod gestures;
pub(super) use gestures::{ScreenGestures, Update as ScreenGestureUpdate};

pub(super) const CONTROL_CHANNEL: &str = "denial/input_deck";
pub(super) const STATE_CHANNEL: &std::ffi::CStr = c"denial/input_deck_state";

#[derive(Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub(super) enum Command {
    Read,
    Configure {
        output: Option<String>,
    },
    Motion {
        dx: f64,
        dy: f64,
    },
    Button {
        button: u32,
        pressed: bool,
        #[serde(default)]
        source: u8,
    },
    Scroll {
        dx: f64,
        dy: f64,
        stop: bool,
    },
    Key {
        keycode: u32,
        pressed: bool,
        #[serde(default)]
        cancelled: bool,
    },
    CancelContact {
        device: i32,
    },
    Release,
}

impl Command {
    fn valid(&self) -> bool {
        match self {
            Self::Configure { output: Some(name) } => {
                !name.is_empty() && name.len() <= 256 && !name.contains('\0')
            }
            Self::Motion { dx, dy } | Self::Scroll { dx, dy, .. } => {
                dx.is_finite() && dy.is_finite() && dx.abs() <= 8192.0 && dy.abs() <= 8192.0
            }
            Self::Button { button, source, .. } => (0x110..=0x112).contains(button) && *source <= 1,
            // Exclude power/suspend/media keys; the deck supplies ordinary typing keys.
            Self::Key { keycode, .. } => {
                (1..=83).contains(keycode)
                    || (86..=88).contains(keycode)
                    || (96..=111).contains(keycode)
                    || (125..=127).contains(keycode)
            }
            Self::CancelContact { device } => *device > 0,
            _ => true,
        }
    }
}

pub(super) fn enqueue(queue: &mut VecDeque<Command>, bytes: &[u8]) {
    let command = (bytes.len() <= 1024)
        .then(|| serde_json::from_slice::<Command>(bytes).ok())
        .flatten();
    let Some(command) = command.filter(Command::valid) else {
        return;
    };
    // Overflow cancels ownership instead of losing a terminal key/button release.
    if queue.len() >= 512 {
        queue.clear();
        queue.push_back(Command::Release);
        return;
    }
    queue.push_back(command);
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub(super) struct Snapshot {
    pub(super) touch_output: Option<String>,
    pub(super) touch_outputs: Vec<String>,
    pub(super) key_labels: BTreeMap<u32, String>,
    pub(super) available: bool,
    pub(super) locked: bool,
    pub(super) active_output: Option<String>,
}

#[derive(Default)]
pub(super) struct Controller {
    pub(super) screen_gestures: ScreenGestures,
    pub(super) scrolling: bool,
    pub(super) keys: BTreeSet<u32>,
    pub(super) buttons: BTreeSet<(u32, u8)>,
    pub(super) legend_signature: Option<(u32, u32, u32, u32, u64)>,
    pub(super) last_window_revision: Option<u64>,
}

impl Controller {
    pub(super) fn button_transition(
        &mut self,
        button: u32,
        source: u8,
        pressed: bool,
        seat_held: bool,
    ) -> Option<bool> {
        let held = self.buttons.iter().any(|(code, _)| *code == button);
        if pressed {
            if (seat_held && !held) || !self.buttons.insert((button, source)) {
                return None;
            }
            (!held).then_some(true)
        } else {
            if !self.buttons.remove(&(button, source)) {
                return None;
            }
            (!self.buttons.iter().any(|(code, _)| *code == button)).then_some(false)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn overlapping_pad_taps_do_not_release_the_held_click_button() {
        let mut controller = Controller::default();
        assert_eq!(
            controller.button_transition(0x110, 1, true, false),
            Some(true)
        );
        assert_eq!(controller.button_transition(0x110, 0, true, true), None);
        assert_eq!(controller.button_transition(0x110, 0, false, true), None);
        assert_eq!(
            controller.button_transition(0x110, 1, false, true),
            Some(false)
        );
    }

    #[test]
    fn invalid_events_cannot_hold_system_keys_or_inject_nonfinite_motion() {
        let mut queue = VecDeque::new();
        for packet in [
            r#"{"kind":"key","keycode":116,"pressed":true}"#,
            r#"{"kind":"motion","dx":1e100,"dy":0}"#,
            r#"{"kind":"button","button":1,"pressed":true}"#,
        ] {
            enqueue(&mut queue, packet.as_bytes());
        }
        assert!(queue.is_empty());
    }

    #[test]
    fn overflow_balances_owned_input_instead_of_dropping_a_release() {
        let mut queue = VecDeque::new();
        for _ in 0..513 {
            enqueue(&mut queue, br#"{"kind":"read"}"#);
        }
        assert!(matches!(queue.pop_front(), Some(Command::Release)));
        assert!(queue.is_empty());
    }
}
