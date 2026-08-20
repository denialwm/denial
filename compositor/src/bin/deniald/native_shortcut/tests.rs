use super::*;

fn press(shortcut: &mut NativeEscapeShortcut, keycode: u32) -> ShortcutDisposition {
    shortcut.observe(keycode, true)
}

fn release(shortcut: &mut NativeEscapeShortcut, keycode: u32) -> ShortcutDisposition {
    shortcut.observe(keycode, false)
}

fn window_switcher_engine(shortcut: &str) -> NativeEscapeShortcut {
    NativeEscapeShortcut::from_file(&ShortcutFile {
        version: SHORTCUT_SCHEMA_VERSION,
        revision: 1,
        shortcuts: vec![ShortcutBinding {
            shortcut: shortcut.to_owned(),
            target: ShortcutTarget::DenialAction {
                action: ShortcutAction::WindowSwitcher,
            },
        }],
    })
    .expect("window-switcher shortcut must compile")
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
fn super_shift_s_requests_region_capture_and_owns_the_key_lifecycle() {
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
        press(&mut shortcut, KEY_S),
        ShortcutDisposition::RequestScreenshotRegion
    );
    assert_eq!(press(&mut shortcut, KEY_S), ShortcutDisposition::Consume);
    assert_eq!(
        release(&mut shortcut, KEY_LEFT_SHIFT),
        ShortcutDisposition::Forward
    );
    assert_eq!(release(&mut shortcut, KEY_S), ShortcutDisposition::Consume);
    assert_eq!(
        release(&mut shortcut, KEY_LEFT_META),
        ShortcutDisposition::Consume
    );

    assert_eq!(press(&mut shortcut, KEY_S), ShortcutDisposition::Forward);
    assert_eq!(release(&mut shortcut, KEY_S), ShortcutDisposition::Forward);
}

#[test]
fn super_space_cycles_layouts_and_owns_the_key_lifecycle() {
    let mut shortcut = NativeEscapeShortcut::default();

    press(&mut shortcut, KEY_LEFT_META);
    assert_eq!(
        press(&mut shortcut, KEY_SPACE),
        ShortcutDisposition::RequestNextKeyboardLayout
    );
    assert_eq!(
        press(&mut shortcut, KEY_SPACE),
        ShortcutDisposition::Consume
    );
    release(&mut shortcut, KEY_LEFT_META);
    assert_eq!(
        release(&mut shortcut, KEY_SPACE),
        ShortcutDisposition::Consume
    );

    press(&mut shortcut, KEY_RIGHT_SHIFT);
    press(&mut shortcut, KEY_RIGHT_META);
    assert_eq!(
        press(&mut shortcut, KEY_SPACE),
        ShortcutDisposition::RequestPreviousKeyboardLayout
    );
    release(&mut shortcut, KEY_RIGHT_SHIFT);
    assert_eq!(
        release(&mut shortcut, KEY_SPACE),
        ShortcutDisposition::Consume
    );
    assert_eq!(
        release(&mut shortcut, KEY_RIGHT_META),
        ShortcutDisposition::Consume
    );

    assert_eq!(
        press(&mut shortcut, KEY_SPACE),
        ShortcutDisposition::Forward
    );
    assert_eq!(
        release(&mut shortcut, KEY_SPACE),
        ShortcutDisposition::Forward
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
        ShortcutDisposition::RequestWindowSwitcherEnd { forward: false }
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
        ShortcutDisposition::RequestWindowSwitcherEnd { forward: false }
    );
    assert_eq!(
        release(&mut shortcut, KEY_RIGHT_META),
        ShortcutDisposition::Consume
    );
}

#[test]
fn alt_tab_ends_on_alt_release_and_forwards_the_modifier_release() {
    for alt in [KEY_LEFT_ALT, KEY_RIGHT_ALT] {
        let mut shortcut = window_switcher_engine("Alt+Tab");

        assert_eq!(press(&mut shortcut, alt), ShortcutDisposition::Forward);
        assert_eq!(
            press(&mut shortcut, KEY_TAB),
            ShortcutDisposition::RequestWindowSwitcherNext
        );
        assert_eq!(
            release(&mut shortcut, alt),
            ShortcutDisposition::RequestWindowSwitcherEnd { forward: true }
        );
        assert_eq!(
            release(&mut shortcut, KEY_TAB),
            ShortcutDisposition::Consume
        );
    }
}

#[test]
fn window_switcher_ends_only_on_the_first_shortcut_modifier() {
    let mut shortcut = window_switcher_engine("Ctrl+Alt+Tab");

    assert_eq!(
        press(&mut shortcut, KEY_LEFT_CTRL),
        ShortcutDisposition::Forward
    );
    assert_eq!(
        press(&mut shortcut, KEY_LEFT_ALT),
        ShortcutDisposition::Forward
    );
    assert_eq!(
        press(&mut shortcut, KEY_TAB),
        ShortcutDisposition::RequestWindowSwitcherNext
    );
    assert_eq!(
        release(&mut shortcut, KEY_LEFT_ALT),
        ShortcutDisposition::Forward
    );
    assert_eq!(
        release(&mut shortcut, KEY_LEFT_CTRL),
        ShortcutDisposition::RequestWindowSwitcherEnd { forward: true }
    );
    assert_eq!(
        release(&mut shortcut, KEY_TAB),
        ShortcutDisposition::Consume
    );
}

#[test]
fn modifierless_window_switcher_ends_on_the_trigger_release() {
    let mut shortcut = window_switcher_engine("Tab");

    assert_eq!(
        press(&mut shortcut, KEY_TAB),
        ShortcutDisposition::RequestWindowSwitcherNext
    );
    assert_eq!(
        release(&mut shortcut, KEY_TAB),
        ShortcutDisposition::RequestWindowSwitcherEnd { forward: false }
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

#[test]
fn hardware_brightness_keys_are_exact_shortcuts_and_balance_releases() {
    for (key, action) in [
        (
            KEY_BRIGHTNESS_DOWN,
            ShortcutDisposition::RequestBrightnessDown,
        ),
        (KEY_BRIGHTNESS_UP, ShortcutDisposition::RequestBrightnessUp),
    ] {
        let mut shortcut = NativeEscapeShortcut::default();
        assert_eq!(press(&mut shortcut, key), action);
        assert_eq!(press(&mut shortcut, key), action);
        assert_eq!(release(&mut shortcut, key), ShortcutDisposition::Consume);
        assert_eq!(release(&mut shortcut, key), ShortcutDisposition::Forward);

        assert_eq!(
            press(&mut shortcut, KEY_LEFT_META),
            ShortcutDisposition::Consume
        );
        assert_eq!(press(&mut shortcut, key), ShortcutDisposition::Forward);
        assert_eq!(release(&mut shortcut, key), ShortcutDisposition::Forward);
        assert_eq!(
            release(&mut shortcut, KEY_LEFT_META),
            ShortcutDisposition::Consume
        );
    }
}
