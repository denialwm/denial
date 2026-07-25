//! Native compositor shortcuts evaluated before any shell or client routing.

const KEY_ESCAPE: u32 = 1;
const KEY_BACKSPACE: u32 = 14;
const KEY_TAB: u32 = 15;
const KEY_A: u32 = 30;
const KEY_F: u32 = 33;
const KEY_K: u32 = 37;
const KEY_L: u32 = 38;
const KEY_V: u32 = 47;
const KEY_M: u32 = 50;
const KEY_UP: u32 = 103;
const KEY_MUTE: u32 = 113;
const KEY_VOLUME_DOWN: u32 = 114;
const KEY_VOLUME_UP: u32 = 115;
const KEY_LEFT_CTRL: u32 = 29;
const KEY_LEFT_ALT: u32 = 56;
const KEY_RIGHT_CTRL: u32 = 97;
const KEY_RIGHT_ALT: u32 = 100;
const KEY_LEFT_META: u32 = 125;
const KEY_RIGHT_META: u32 = 126;
const KEY_LEFT_SHIFT: u32 = 42;
const KEY_RIGHT_SHIFT: u32 = 54;

const LEFT_MODIFIER: u8 = 1 << 0;
const RIGHT_MODIFIER: u8 = 1 << 1;
const CAPTURED_MINIMIZE: u16 = 1 << 0;
const CAPTURED_FULLSCREEN: u16 = 1 << 1;
const CAPTURED_CLOSE: u16 = 1 << 2;
const CAPTURED_OVERVIEW: u16 = 1 << 3;
const CAPTURED_WINDOW_SWITCHER: u16 = 1 << 4;
const CAPTURED_LOCK: u16 = 1 << 5;
const CAPTURED_POINTER_RELEASE: u16 = 1 << 6;
const CAPTURED_MAXIMIZE: u16 = 1 << 7;
const CAPTURED_CLIPBOARD: u16 = 1 << 8;
const CAPTURED_VERTICAL_MAXIMIZE: u16 = 1 << 9;
const CAPTURED_MUTE: u8 = 1 << 0;
const CAPTURED_VOLUME_DOWN: u8 = 1 << 1;
const CAPTURED_VOLUME_UP: u8 = 1 << 2;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum ShortcutDisposition {
    Forward,
    Consume,
    RequestShutdown,
    RequestApplications,
    RequestOverview,
    RequestToggleVerticalMaximize,
    RequestWindowSwitcherNext,
    RequestWindowSwitcherEnd,
    RequestClipboard,
    RequestClose,
    RequestMinimize,
    RequestToggleMaximize,
    RequestToggleFullscreen,
    RequestReleasePointer,
    RequestLock,
    RequestVolumeUp,
    RequestVolumeDown,
    RequestMute,
    RequestBrightnessUp,
    RequestBrightnessDown,
}

#[derive(Debug, Default)]
pub(super) struct NativeEscapeShortcut {
    ctrl_keys: u8,
    alt_keys: u8,
    shift_keys: u8,
    logo_keys: u8,
    logo_chorded: bool,
    window_switcher_active: bool,
    captured_logo_actions: u16,
    captured_media_actions: u8,
    captured_backspace: bool,
}

impl NativeEscapeShortcut {
    /// Observe a Linux evdev keycode before it enters Smithay's seat state.
    pub(super) fn observe(&mut self, evdev_keycode: u32, pressed: bool) -> ShortcutDisposition {
        let logo_modifier = match evdev_keycode {
            KEY_LEFT_META => Some(LEFT_MODIFIER),
            KEY_RIGHT_META => Some(RIGHT_MODIFIER),
            _ => None,
        };
        if let Some(bit) = logo_modifier {
            if pressed {
                if self.logo_keys == 0 {
                    self.logo_chorded = false;
                }
                self.logo_keys |= bit;
                return ShortcutDisposition::Consume;
            }

            self.logo_keys &= !bit;
            if self.window_switcher_active {
                self.window_switcher_active = false;
                if self.logo_keys == 0 {
                    self.logo_chorded = false;
                }
                return ShortcutDisposition::RequestWindowSwitcherEnd;
            }
            if self.logo_keys == 0 {
                let open_applications = !std::mem::take(&mut self.logo_chorded);
                return if open_applications {
                    ShortcutDisposition::RequestApplications
                } else {
                    ShortcutDisposition::Consume
                };
            }
            return ShortcutDisposition::Consume;
        }

        if pressed && self.logo_keys != 0 {
            self.logo_chorded = true;
        }

        let media_action = match evdev_keycode {
            KEY_VOLUME_UP => Some((
                CAPTURED_VOLUME_UP,
                ShortcutDisposition::RequestVolumeUp,
                Some(ShortcutDisposition::RequestBrightnessUp),
            )),
            KEY_VOLUME_DOWN => Some((
                CAPTURED_VOLUME_DOWN,
                ShortcutDisposition::RequestVolumeDown,
                Some(ShortcutDisposition::RequestBrightnessDown),
            )),
            KEY_MUTE => Some((CAPTURED_MUTE, ShortcutDisposition::RequestMute, None)),
            _ => None,
        };
        if let Some((capture, plain, with_logo)) = media_action {
            if pressed {
                if self.logo_keys != 0 {
                    let Some(disposition) = with_logo else {
                        return ShortcutDisposition::Forward;
                    };
                    self.captured_media_actions |= capture;
                    return disposition;
                }
                self.captured_media_actions |= capture;
                return plain;
            }
            if self.captured_media_actions & capture != 0 {
                self.captured_media_actions &= !capture;
                return ShortcutDisposition::Consume;
            }
            return ShortcutDisposition::Forward;
        }

        if evdev_keycode == KEY_UP {
            if pressed {
                if self.logo_keys == 0 {
                    return ShortcutDisposition::Forward;
                }
                let (capture, disposition) = if self.shift_keys != 0 {
                    (
                        CAPTURED_VERTICAL_MAXIMIZE,
                        ShortcutDisposition::RequestToggleVerticalMaximize,
                    )
                } else {
                    (
                        CAPTURED_MAXIMIZE,
                        ShortcutDisposition::RequestToggleMaximize,
                    )
                };
                if self.captured_logo_actions & (CAPTURED_MAXIMIZE | CAPTURED_VERTICAL_MAXIMIZE)
                    != 0
                {
                    return ShortcutDisposition::Consume;
                }
                self.captured_logo_actions |= capture;
                return disposition;
            }
            for capture in [CAPTURED_VERTICAL_MAXIMIZE, CAPTURED_MAXIMIZE] {
                if self.captured_logo_actions & capture != 0 {
                    self.captured_logo_actions &= !capture;
                    return ShortcutDisposition::Consume;
                }
            }
            return ShortcutDisposition::Forward;
        }

        let logo_action = match evdev_keycode {
            KEY_ESCAPE => Some((
                CAPTURED_POINTER_RELEASE,
                ShortcutDisposition::RequestReleasePointer,
            )),
            KEY_A => Some((CAPTURED_OVERVIEW, ShortcutDisposition::RequestOverview)),
            KEY_TAB => Some((
                CAPTURED_WINDOW_SWITCHER,
                ShortcutDisposition::RequestWindowSwitcherNext,
            )),
            KEY_M => Some((CAPTURED_MINIMIZE, ShortcutDisposition::RequestMinimize)),
            KEY_F => Some((
                CAPTURED_FULLSCREEN,
                ShortcutDisposition::RequestToggleFullscreen,
            )),
            KEY_K => Some((CAPTURED_CLOSE, ShortcutDisposition::RequestClose)),
            KEY_L => Some((CAPTURED_LOCK, ShortcutDisposition::RequestLock)),
            KEY_V => Some((CAPTURED_CLIPBOARD, ShortcutDisposition::RequestClipboard)),
            _ => None,
        };
        if let Some((capture, disposition)) = logo_action {
            if pressed {
                if self.captured_logo_actions & capture != 0 {
                    return ShortcutDisposition::Consume;
                }
                if self.logo_keys == 0 {
                    return ShortcutDisposition::Forward;
                }
                self.captured_logo_actions |= capture;
                if evdev_keycode == KEY_TAB {
                    self.window_switcher_active = true;
                }
                return disposition;
            }
            if self.captured_logo_actions & capture != 0 {
                self.captured_logo_actions &= !capture;
                return ShortcutDisposition::Consume;
            }
            return ShortcutDisposition::Forward;
        }

        let modifier = match evdev_keycode {
            KEY_LEFT_CTRL => Some((&mut self.ctrl_keys, LEFT_MODIFIER)),
            KEY_RIGHT_CTRL => Some((&mut self.ctrl_keys, RIGHT_MODIFIER)),
            KEY_LEFT_ALT => Some((&mut self.alt_keys, LEFT_MODIFIER)),
            KEY_RIGHT_ALT => Some((&mut self.alt_keys, RIGHT_MODIFIER)),
            KEY_LEFT_SHIFT => Some((&mut self.shift_keys, LEFT_MODIFIER)),
            KEY_RIGHT_SHIFT => Some((&mut self.shift_keys, RIGHT_MODIFIER)),
            _ => None,
        };
        if let Some((keys, bit)) = modifier {
            if pressed {
                *keys |= bit;
            } else {
                *keys &= !bit;
            }
            return ShortcutDisposition::Forward;
        }

        if evdev_keycode != KEY_BACKSPACE {
            return ShortcutDisposition::Forward;
        }
        if !pressed {
            return if std::mem::take(&mut self.captured_backspace) {
                ShortcutDisposition::Consume
            } else {
                ShortcutDisposition::Forward
            };
        }
        if self.ctrl_keys == 0 || self.alt_keys == 0 {
            return ShortcutDisposition::Forward;
        }

        self.captured_backspace = true;
        ShortcutDisposition::RequestShutdown
    }

    /// A pointer chord such as SUPER+LMB/RMB must suppress the standalone
    /// SUPER-release launcher action.
    #[cfg(any(feature = "flutter", test))]
    pub(super) fn note_pointer_button(&mut self, pressed: bool) {
        if pressed && self.logo_keys != 0 {
            self.logo_chorded = true;
        }
    }

    /// Whether either physical SUPER key is currently compositor-owned.
    #[cfg(any(feature = "flutter", test))]
    pub(super) fn super_pressed(&self) -> bool {
        self.logo_keys != 0
    }

    pub(super) fn reset(&mut self) {
        *self = Self::default();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn press(shortcut: &mut NativeEscapeShortcut, keycode: u32) -> ShortcutDisposition {
        shortcut.observe(keycode, true)
    }

    fn release(shortcut: &mut NativeEscapeShortcut, keycode: u32) -> ShortcutDisposition {
        shortcut.observe(keycode, false)
    }

    #[test]
    fn either_side_of_both_modifiers_activates_the_escape() {
        for ctrl in [KEY_LEFT_CTRL, KEY_RIGHT_CTRL] {
            for alt in [KEY_LEFT_ALT, KEY_RIGHT_ALT] {
                let mut shortcut = NativeEscapeShortcut::default();

                assert_eq!(press(&mut shortcut, ctrl), ShortcutDisposition::Forward);
                assert_eq!(press(&mut shortcut, alt), ShortcutDisposition::Forward);
                assert_eq!(
                    press(&mut shortcut, KEY_BACKSPACE),
                    ShortcutDisposition::RequestShutdown
                );
            }
        }
    }

    #[test]
    fn backspace_without_both_modifiers_is_forwarded() {
        let mut shortcut = NativeEscapeShortcut::default();

        assert_eq!(
            press(&mut shortcut, KEY_BACKSPACE),
            ShortcutDisposition::Forward
        );
        press(&mut shortcut, KEY_LEFT_CTRL);
        assert_eq!(
            press(&mut shortcut, KEY_BACKSPACE),
            ShortcutDisposition::Forward
        );
    }

    #[test]
    fn captured_backspace_release_is_not_leaked_after_modifier_releases() {
        let mut shortcut = NativeEscapeShortcut::default();

        press(&mut shortcut, KEY_LEFT_CTRL);
        press(&mut shortcut, KEY_LEFT_ALT);
        press(&mut shortcut, KEY_BACKSPACE);
        release(&mut shortcut, KEY_LEFT_ALT);
        release(&mut shortcut, KEY_LEFT_CTRL);

        assert_eq!(
            release(&mut shortcut, KEY_BACKSPACE),
            ShortcutDisposition::Consume
        );
        assert_eq!(
            release(&mut shortcut, KEY_BACKSPACE),
            ShortcutDisposition::Forward
        );
    }

    #[test]
    fn releasing_one_ctrl_does_not_clear_the_other_ctrl() {
        let mut shortcut = NativeEscapeShortcut::default();

        press(&mut shortcut, KEY_LEFT_CTRL);
        press(&mut shortcut, KEY_RIGHT_CTRL);
        release(&mut shortcut, KEY_LEFT_CTRL);
        press(&mut shortcut, KEY_LEFT_ALT);

        assert_eq!(
            press(&mut shortcut, KEY_BACKSPACE),
            ShortcutDisposition::RequestShutdown
        );
    }

    #[test]
    fn reset_drops_modifier_and_capture_state() {
        let mut shortcut = NativeEscapeShortcut::default();

        press(&mut shortcut, KEY_LEFT_CTRL);
        press(&mut shortcut, KEY_LEFT_ALT);
        press(&mut shortcut, KEY_BACKSPACE);
        shortcut.reset();

        assert_eq!(
            release(&mut shortcut, KEY_BACKSPACE),
            ShortcutDisposition::Forward
        );
        assert_eq!(
            press(&mut shortcut, KEY_BACKSPACE),
            ShortcutDisposition::Forward
        );
    }

    #[test]
    fn standalone_super_release_requests_applications() {
        for key in [KEY_LEFT_META, KEY_RIGHT_META] {
            let mut shortcut = NativeEscapeShortcut::default();
            assert_eq!(press(&mut shortcut, key), ShortcutDisposition::Consume);
            assert_eq!(
                release(&mut shortcut, key),
                ShortcutDisposition::RequestApplications
            );
        }
    }

    #[test]
    fn keyboard_and_pointer_chords_suppress_super_release_action() {
        let mut shortcut = NativeEscapeShortcut::default();
        press(&mut shortcut, KEY_LEFT_META);
        press(&mut shortcut, 31);
        release(&mut shortcut, 31);
        assert_eq!(
            release(&mut shortcut, KEY_LEFT_META),
            ShortcutDisposition::Consume
        );

        press(&mut shortcut, KEY_LEFT_META);
        shortcut.note_pointer_button(true);
        assert_eq!(
            release(&mut shortcut, KEY_LEFT_META),
            ShortcutDisposition::Consume
        );
    }

    #[test]
    fn both_super_keys_trigger_only_after_the_last_release() {
        let mut shortcut = NativeEscapeShortcut::default();
        assert!(!shortcut.super_pressed());
        press(&mut shortcut, KEY_LEFT_META);
        assert!(shortcut.super_pressed());
        press(&mut shortcut, KEY_RIGHT_META);
        assert!(shortcut.super_pressed());
        assert_eq!(
            release(&mut shortcut, KEY_LEFT_META),
            ShortcutDisposition::Consume
        );
        assert!(shortcut.super_pressed());
        assert_eq!(
            release(&mut shortcut, KEY_RIGHT_META),
            ShortcutDisposition::RequestApplications
        );
        assert!(!shortcut.super_pressed());
    }

    #[test]
    fn super_window_chords_request_native_actions_once() {
        for (key, request) in [
            (KEY_M, ShortcutDisposition::RequestMinimize),
            (KEY_UP, ShortcutDisposition::RequestToggleMaximize),
            (KEY_F, ShortcutDisposition::RequestToggleFullscreen),
            (KEY_K, ShortcutDisposition::RequestClose),
            (KEY_L, ShortcutDisposition::RequestLock),
            (KEY_V, ShortcutDisposition::RequestClipboard),
        ] {
            let mut shortcut = NativeEscapeShortcut::default();
            assert_eq!(
                press(&mut shortcut, KEY_LEFT_META),
                ShortcutDisposition::Consume
            );
            assert_eq!(press(&mut shortcut, key), request);
            assert_eq!(press(&mut shortcut, key), ShortcutDisposition::Consume);
            assert_eq!(release(&mut shortcut, key), ShortcutDisposition::Consume);
            assert_eq!(
                release(&mut shortcut, KEY_LEFT_META),
                ShortcutDisposition::Consume
            );
        }
    }

    #[test]
    fn super_escape_releases_pointer_without_leaking_escape() {
        let mut shortcut = NativeEscapeShortcut::default();

        assert_eq!(
            press(&mut shortcut, KEY_LEFT_META),
            ShortcutDisposition::Consume
        );
        assert_eq!(
            press(&mut shortcut, KEY_ESCAPE),
            ShortcutDisposition::RequestReleasePointer
        );
        assert_eq!(
            press(&mut shortcut, KEY_ESCAPE),
            ShortcutDisposition::Consume
        );
        assert_eq!(
            release(&mut shortcut, KEY_LEFT_META),
            ShortcutDisposition::Consume
        );
        assert_eq!(
            release(&mut shortcut, KEY_ESCAPE),
            ShortcutDisposition::Consume
        );
    }

    #[test]
    fn super_a_requests_overview_once_and_owns_the_key_lifecycle() {
        let mut shortcut = NativeEscapeShortcut::default();

        assert_eq!(
            press(&mut shortcut, KEY_LEFT_META),
            ShortcutDisposition::Consume
        );
        assert_eq!(
            press(&mut shortcut, KEY_A),
            ShortcutDisposition::RequestOverview
        );
        assert_eq!(press(&mut shortcut, KEY_A), ShortcutDisposition::Consume);
        assert_eq!(release(&mut shortcut, KEY_A), ShortcutDisposition::Consume);
        assert_eq!(
            release(&mut shortcut, KEY_LEFT_META),
            ShortcutDisposition::Consume
        );
    }

    #[test]
    fn super_shift_up_toggles_vertical_maximize_without_replacing_super_up() {
        let mut shortcut = NativeEscapeShortcut::default();

        assert_eq!(
            press(&mut shortcut, KEY_LEFT_SHIFT),
            ShortcutDisposition::Forward
        );
        assert_eq!(
            press(&mut shortcut, KEY_LEFT_META),
            ShortcutDisposition::Consume
        );
        assert_eq!(
            press(&mut shortcut, KEY_UP),
            ShortcutDisposition::RequestToggleVerticalMaximize
        );
        assert_eq!(press(&mut shortcut, KEY_UP), ShortcutDisposition::Consume);
        // The Up lifecycle remains compositor-owned even if Shift is released
        // first, so no unmatched key release reaches the focused client.
        assert_eq!(
            release(&mut shortcut, KEY_LEFT_SHIFT),
            ShortcutDisposition::Forward
        );
        assert_eq!(release(&mut shortcut, KEY_UP), ShortcutDisposition::Consume);
        assert_eq!(
            release(&mut shortcut, KEY_LEFT_META),
            ShortcutDisposition::Consume
        );

        assert_eq!(
            press(&mut shortcut, KEY_LEFT_META),
            ShortcutDisposition::Consume
        );
        assert_eq!(
            press(&mut shortcut, KEY_UP),
            ShortcutDisposition::RequestToggleMaximize
        );
    }

    #[test]
    fn super_tab_advances_per_press_and_super_release_ends_the_session() {
        let mut shortcut = NativeEscapeShortcut::default();

        press(&mut shortcut, KEY_LEFT_META);
        assert_eq!(
            press(&mut shortcut, KEY_TAB),
            ShortcutDisposition::RequestWindowSwitcherNext
        );
        assert_eq!(press(&mut shortcut, KEY_TAB), ShortcutDisposition::Consume);
        assert_eq!(
            release(&mut shortcut, KEY_TAB),
            ShortcutDisposition::Consume
        );
        assert_eq!(
            press(&mut shortcut, KEY_TAB),
            ShortcutDisposition::RequestWindowSwitcherNext
        );
        assert_eq!(
            release(&mut shortcut, KEY_LEFT_META),
            ShortcutDisposition::RequestWindowSwitcherEnd
        );
        assert_eq!(press(&mut shortcut, KEY_TAB), ShortcutDisposition::Consume);
        assert_eq!(
            release(&mut shortcut, KEY_TAB),
            ShortcutDisposition::Consume
        );
    }

    #[test]
    fn releasing_either_super_key_ends_a_window_switch_session_only_once() {
        let mut shortcut = NativeEscapeShortcut::default();

        press(&mut shortcut, KEY_LEFT_META);
        press(&mut shortcut, KEY_RIGHT_META);
        press(&mut shortcut, KEY_TAB);
        release(&mut shortcut, KEY_TAB);
        assert_eq!(
            release(&mut shortcut, KEY_LEFT_META),
            ShortcutDisposition::RequestWindowSwitcherEnd
        );
        assert_eq!(
            release(&mut shortcut, KEY_RIGHT_META),
            ShortcutDisposition::Consume
        );
    }

    #[test]
    fn window_action_keys_without_super_remain_client_keys() {
        for key in [
            KEY_ESCAPE, KEY_A, KEY_TAB, KEY_M, KEY_F, KEY_K, KEY_L, KEY_V,
        ] {
            let mut shortcut = NativeEscapeShortcut::default();
            assert_eq!(press(&mut shortcut, key), ShortcutDisposition::Forward);
            assert_eq!(release(&mut shortcut, key), ShortcutDisposition::Forward);
        }
    }

    #[test]
    fn captured_logo_action_release_is_consumed_after_super_releases() {
        let mut shortcut = NativeEscapeShortcut::default();
        press(&mut shortcut, KEY_LEFT_META);
        assert_eq!(
            press(&mut shortcut, KEY_F),
            ShortcutDisposition::RequestToggleFullscreen
        );
        assert_eq!(
            release(&mut shortcut, KEY_LEFT_META),
            ShortcutDisposition::Consume
        );
        assert_eq!(release(&mut shortcut, KEY_F), ShortcutDisposition::Consume);
    }

    #[test]
    fn volume_wheel_controls_audio_and_super_changes_it_to_brightness() {
        for (key, audio, brightness) in [
            (
                KEY_VOLUME_UP,
                ShortcutDisposition::RequestVolumeUp,
                ShortcutDisposition::RequestBrightnessUp,
            ),
            (
                KEY_VOLUME_DOWN,
                ShortcutDisposition::RequestVolumeDown,
                ShortcutDisposition::RequestBrightnessDown,
            ),
        ] {
            let mut shortcut = NativeEscapeShortcut::default();
            assert_eq!(press(&mut shortcut, key), audio);
            assert_eq!(release(&mut shortcut, key), ShortcutDisposition::Consume);

            assert_eq!(
                press(&mut shortcut, KEY_LEFT_META),
                ShortcutDisposition::Consume
            );
            assert_eq!(press(&mut shortcut, key), brightness);
            assert_eq!(press(&mut shortcut, key), brightness);
            assert_eq!(
                release(&mut shortcut, KEY_LEFT_META),
                ShortcutDisposition::Consume
            );
            assert_eq!(release(&mut shortcut, key), ShortcutDisposition::Consume);
        }
    }

    #[test]
    fn mute_is_native_without_super_but_super_mute_is_forwarded() {
        let mut shortcut = NativeEscapeShortcut::default();
        assert_eq!(
            press(&mut shortcut, KEY_MUTE),
            ShortcutDisposition::RequestMute
        );
        assert_eq!(
            release(&mut shortcut, KEY_MUTE),
            ShortcutDisposition::Consume
        );

        press(&mut shortcut, KEY_LEFT_META);
        assert_eq!(press(&mut shortcut, KEY_MUTE), ShortcutDisposition::Forward);
        assert_eq!(
            release(&mut shortcut, KEY_MUTE),
            ShortcutDisposition::Forward
        );
        assert_eq!(
            release(&mut shortcut, KEY_LEFT_META),
            ShortcutDisposition::Consume
        );
    }
}
