//! Raw touchscreen contacts do not wake a powered-off display, nor reach one
//! lit only to draw the always-on clock. Remember their slots through a later
//! independent wake so an orphan motion/up cannot enter UI.
use std::collections::HashSet;

#[derive(Clone, Copy)]
pub(super) enum Event {
    Down(i32),
    Motion(i32),
    Up(i32),
    Cancel,
    Frame,
}

#[derive(Default)]
pub(super) struct Filter {
    held: HashSet<(String, i32)>,
    /// A display lit only to draw the always-on clock.
    dark: bool,
}

impl Filter {
    pub(super) fn remove_device(&mut self, device: &str) {
        self.held.retain(|(name, _)| name != device);
    }

    pub(super) fn set_dark(&mut self, dark: bool) {
        self.dark = dark;
    }

    pub(super) fn suppress(&mut self, device: &str, event: Event, powered: bool) -> bool {
        let powered = powered && !self.dark;
        let blocked = self.held.iter().any(|(name, _)| name == device);
        match event {
            Event::Down(slot) | Event::Motion(slot) => {
                if !powered || blocked {
                    self.held.insert((device.to_owned(), slot));
                    true
                } else {
                    false
                }
            }
            Event::Up(slot) => self.held.remove(&(device.to_owned(), slot)) || !powered,
            Event::Cancel => {
                self.remove_device(device);
                blocked || !powered
            }
            Event::Frame => blocked || !powered,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn screen_off_contact_stays_quarantined_after_power_button_wake() {
        let mut f = Filter::default();
        assert!(f.suppress("touch", Event::Down(0), false));
        assert!(f.suppress("touch", Event::Motion(0), true));
        assert!(f.suppress("touch", Event::Frame, true));
        assert!(f.suppress("touch", Event::Up(0), true));
        assert!(!f.suppress("touch", Event::Down(0), true));
    }
    #[test]
    fn contact_during_an_always_on_refresh_stays_quarantined() {
        let mut f = Filter::default();
        f.set_dark(true);
        assert!(f.suppress("touch", Event::Down(0), true));
        f.set_dark(false);
        assert!(f.suppress("touch", Event::Motion(0), true));
        assert!(f.suppress("touch", Event::Up(0), true));
        assert!(!f.suppress("touch", Event::Down(0), true));
    }
    #[test]
    fn lit_touchscreen_is_independent_of_another_sleeping_touchscreen() {
        let mut f = Filter::default();
        assert!(f.suppress("sleep", Event::Down(0), false));
        assert!(!f.suppress("lit", Event::Down(0), true));
        assert!(!f.suppress("lit", Event::Up(0), true));
        assert!(f.suppress("sleep", Event::Up(0), false));
    }
    #[test]
    fn multitouch_removal_and_cancel_reset_only_the_relevant_device() {
        let mut f = Filter::default();
        assert!(f.suppress("a", Event::Down(0), false));
        assert!(f.suppress("a", Event::Down(1), true));
        assert!(f.suppress("b", Event::Down(0), false));
        assert!(f.suppress("a", Event::Up(0), true));
        assert!(f.suppress("a", Event::Up(1), true));
        assert!(!f.suppress("a", Event::Down(2), true));
        assert!(f.suppress("b", Event::Cancel, true));
        assert!(!f.suppress("b", Event::Down(1), true));
        f.remove_device("a");
        assert!(!f.suppress("a", Event::Down(0), true));
    }
}
