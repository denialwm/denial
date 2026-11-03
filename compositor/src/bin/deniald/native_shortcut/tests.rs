use super::*;

#[test]
fn v11_migrates_only_launcher_targets_preserving_user_deletions() {
    let mut file = ShortcutFile {
        version: 10,
        revision: 25,
        shortcuts: vec![
            ShortcutBinding {
                shortcut: "Super+A".into(),
                target: ShortcutTarget::DenialAction {
                    action: ShortcutAction::OpenApplications,
                },
            },
            ShortcutBinding {
                shortcut: "Super+Alt+P".into(),
                target: ShortcutTarget::SpawnSh {
                    command: "custom".into(),
                },
            },
        ],
    };
    assert_eq!(migrate_shortcut_file(&mut file).unwrap(), Some(1));
    assert_eq!(file.revision, 26);
    assert_eq!(file.shortcuts.len(), 2);
    assert_eq!(file.shortcuts[0].shortcut, "Super+A");
    assert_eq!(
        file.shortcuts[0].target,
        ShortcutTarget::PluginAction {
            id: crate::plugin_actions::LEGACY_LAUNCHER_ACTION.into(),
        }
    );
    assert_eq!(migrate_shortcut_file(&mut file).unwrap(), None);
    file.version = 10;
    file.shortcuts.clear();
    migrate_shortcut_file(&mut file).unwrap();
    assert_eq!(file.shortcuts.len(), SHORTCUT_V12_PLUGIN_ADDITIONS.len());
}

#[test]
fn v12_adds_color_tuning_only_where_the_trigger_is_free() {
    let color_tuning = ShortcutTarget::PluginAction {
        id: crate::plugin_actions::COLOR_TUNING_ACTION.into(),
    };
    let mut file = ShortcutFile {
        version: 11,
        revision: 4,
        shortcuts: Vec::new(),
    };
    assert_eq!(migrate_shortcut_file(&mut file).unwrap(), Some(1));
    assert_eq!(file.revision, 5);
    assert_eq!(file.shortcuts.len(), 1);
    assert_eq!(file.shortcuts[0].shortcut, "Super+Alt+P");
    assert_eq!(file.shortcuts[0].target, color_tuning);
    assert!(compile_shortcuts(&file).is_ok());
    // A deletion after the migration stays deleted.
    file.shortcuts.clear();
    assert_eq!(migrate_shortcut_file(&mut file).unwrap(), None);
    assert!(file.shortcuts.is_empty());

    let custom = ShortcutBinding {
        shortcut: "Super+Alt+P".into(),
        target: ShortcutTarget::SpawnSh {
            command: "custom".into(),
        },
    };
    let mut file = ShortcutFile {
        version: 11,
        revision: 4,
        shortcuts: vec![custom.clone()],
    };
    assert_eq!(migrate_shortcut_file(&mut file).unwrap(), Some(0));
    assert_eq!(file.shortcuts, vec![custom]);
    assert!(
        default_shortcut_file()
            .shortcuts
            .iter()
            .any(|binding| binding.shortcut == "Super+Alt+P" && binding.target == color_tuning)
    );
}

#[test]
fn plugin_actions_follow_catalog_for_keys_taps_and_gestures() {
    let id = "third_party.anyAction";
    let file = ShortcutFile {
        version: SHORTCUT_SCHEMA_VERSION,
        revision: 1,
        shortcuts: ["A", "Super", "FourFingerSwipeUp"]
            .into_iter()
            .map(|shortcut| ShortcutBinding {
                shortcut: shortcut.into(),
                target: ShortcutTarget::PluginAction { id: id.into() },
            })
            .collect(),
    };
    let mut engine = ShortcutEngine::from_file(&file).unwrap();
    let catalog = crate::plugin_actions::ActionCatalog::decode(5,
            r#"[{"id":"third_party.anyAction","label":"Any action","description":"","provider":"Third party"}]"#).unwrap();
    assert_eq!(engine.observe(30, true), ShortcutDisposition::Forward);
    assert_eq!(engine.observe(30, false), ShortcutDisposition::Forward);
    assert_eq!(
        engine.observe_gesture(ShortcutGesture::FourFingerSwipeUp),
        ShortcutDisposition::Forward
    );
    engine.set_plugin_actions(&catalog);
    assert_eq!(
        engine.observe(30, true),
        ShortcutDisposition::PluginAction(id.into())
    );
    assert_eq!(engine.observe(30, true), ShortcutDisposition::Consume);
    // Disabling a provider during a captured key still consumes its release.
    engine.set_plugin_actions(&crate::plugin_actions::ActionCatalog::default());
    assert_eq!(engine.observe(30, false), ShortcutDisposition::Consume);
    engine.observe(KEY_LEFT_META, true);
    assert_eq!(
        engine.observe(KEY_LEFT_META, false),
        ShortcutDisposition::Consume
    );
    engine.set_plugin_actions(&catalog);
    engine.observe(KEY_LEFT_META, true);
    assert_eq!(
        engine.observe(KEY_LEFT_META, false),
        ShortcutDisposition::PluginAction(id.into())
    );
    assert_eq!(
        engine.observe_gesture(ShortcutGesture::FourFingerSwipeUp),
        ShortcutDisposition::PluginAction(id.into())
    );
}

#[test]
fn an_app_holding_the_shortcuts_gets_super_but_not_the_way_out() {
    const KEY_A: u32 = 30;
    let mut engine = ShortcutEngine::from_file(&default_shortcut_file()).unwrap();
    let super_press = engine.observe(KEY_LEFT_META, true);
    assert!(!super_press.survives_shortcuts_inhibit());
    let overview = engine.observe(KEY_A, true);
    assert_eq!(overview, ShortcutDisposition::RequestOverview);
    assert!(!overview.survives_shortcuts_inhibit());
    engine.pass_through_key(KEY_A);
    let release_pointer = engine.observe(KEY_ESCAPE, true);
    assert_eq!(release_pointer, ShortcutDisposition::RequestReleasePointer);
    assert!(release_pointer.survives_shortcuts_inhibit());
    engine.observe(KEY_ESCAPE, false);
    engine.observe(KEY_LEFT_META, false);
    assert!(
        engine
            .observe(KEY_VOLUME_UP, true)
            .survives_shortcuts_inhibit()
    );
    assert!(
        ShortcutDisposition::RequestShutdown.survives_shortcuts_inhibit()
            && !ShortcutDisposition::RequestLock.survives_shortcuts_inhibit()
    );
}

#[test]
fn reset_width_roundtrips_binds_without_defaults_and_does_not_repeat() {
    let action: ShortcutAction = serde_json::from_str("\"resetWindowWidth\"").unwrap();
    assert_eq!(action, ShortcutAction::ResetWindowWidth);
    assert_eq!(
        serde_json::to_string(&action).unwrap(),
        "\"resetWindowWidth\""
    );
    assert!(ShortcutAction::ALL.contains(&action));
    let target = ShortcutTarget::DenialAction { action };
    let defaults = default_shortcut_file();
    assert!(
        !defaults
            .shortcuts
            .iter()
            .any(|binding| binding.target == target)
    );
    let mut file = defaults;
    file.shortcuts.push(ShortcutBinding {
        shortcut: "Super+R".into(),
        target,
    });
    let mut engine = ShortcutEngine::from_file(&file).unwrap();
    engine.observe(KEY_LEFT_META, true);
    assert_eq!(
        engine.observe(19, true),
        ShortcutDisposition::RequestResize(KeyboardResize::ResetWidth)
    );
    assert_eq!(engine.observe(19, false), ShortcutDisposition::Consume);
    assert!(!ShortcutDisposition::RequestResize(KeyboardResize::ResetWidth).repeats_with_timer());
    let encoded = serde_json::to_string(&file).unwrap();
    let mut decoded: ShortcutFile = serde_json::from_str(&encoded).unwrap();
    assert_eq!(migrate_shortcut_file(&mut decoded).unwrap(), None);
    assert_eq!(decoded.shortcuts, file.shortcuts);
}

#[test]
fn resize_defaults_repeat_and_capture_releases() {
    for (keycode, shift, action) in [
        (12, false, KeyboardResize::ShrinkWidth),
        (13, false, KeyboardResize::GrowWidth),
        (12, true, KeyboardResize::ShrinkHeight),
        (13, true, KeyboardResize::GrowHeight),
    ] {
        let mut engine = ShortcutEngine::from_file(&default_shortcut_file()).unwrap();
        engine.observe(KEY_LEFT_META, true);
        if shift {
            engine.observe(KEY_LEFT_SHIFT, true);
        }
        let expected = ShortcutDisposition::RequestResize(action);
        assert_eq!(engine.observe(keycode, true), expected);
        assert_eq!(engine.observe(keycode, true), expected);
        assert!(expected.repeats_with_timer());
        assert_eq!(engine.observe(keycode, false), ShortcutDisposition::Consume);
    }
    assert!(!ShortcutDisposition::RequestResize(KeyboardResize::ResetHeight).repeats_with_timer());
}

#[test]
fn v10_migration_preserves_custom_bindings_and_runs_only_once() {
    let custom = ShortcutBinding {
        shortcut: "Super+Minus".to_owned(),
        target: ShortcutTarget::SpawnSh {
            command: "custom".to_owned(),
        },
    };
    let mut file = ShortcutFile {
        version: 9,
        revision: 12,
        shortcuts: vec![custom.clone()],
    };
    assert_eq!(migrate_shortcut_file(&mut file).unwrap(), Some(4));
    assert_eq!(file.revision, 13);
    assert_eq!(file.shortcuts[0], custom);
    assert_eq!(file.shortcuts.len(), 5);
    assert!(compile_shortcuts(&file).is_ok());
    file.shortcuts.pop();
    assert_eq!(migrate_shortcut_file(&mut file).unwrap(), None);
    assert_eq!(file.shortcuts.len(), 4);
}

#[test]
fn level_shortcuts_repeat_while_the_key_remains_pressed() {
    for (keycode, expected) in [
        (KEY_VOLUME_UP, ShortcutDisposition::RequestVolumeUp),
        (KEY_VOLUME_DOWN, ShortcutDisposition::RequestVolumeDown),
        (KEY_BRIGHTNESS_UP, ShortcutDisposition::RequestBrightnessUp),
        (
            KEY_BRIGHTNESS_DOWN,
            ShortcutDisposition::RequestBrightnessDown,
        ),
    ] {
        let mut engine = ShortcutEngine::from_file(&default_shortcut_file()).unwrap();

        assert_eq!(engine.observe(keycode, true), expected.clone());
        let repeated = engine.observe(keycode, true);
        assert_eq!(repeated, expected);
        assert!(repeated.repeats_system_control());
        assert_eq!(engine.observe(keycode, false), ShortcutDisposition::Consume);
    }
}

#[test]
fn ctrl_alt_function_keys_request_vt_switch_and_capture_their_lifecycle() {
    for vt in 1..=12 {
        let keycode = match vt {
            1..=10 => KEY_F1 + vt - 1,
            11 => KEY_F11,
            12 => KEY_F12,
            _ => unreachable!(),
        };
        let mut engine = ShortcutEngine::from_file(&default_shortcut_file()).unwrap();

        assert_eq!(
            engine.observe(KEY_LEFT_CTRL, true),
            ShortcutDisposition::Forward
        );
        assert_eq!(
            engine.observe(KEY_RIGHT_ALT, true),
            ShortcutDisposition::Forward
        );
        assert_eq!(
            engine.observe(keycode, true),
            ShortcutDisposition::RequestVtSwitch(vt as i32)
        );
        assert_eq!(engine.observe(keycode, true), ShortcutDisposition::Consume);
        assert_eq!(engine.observe(keycode, false), ShortcutDisposition::Consume);
    }
}

#[test]
fn vt_switch_requires_exactly_ctrl_and_alt() {
    let mut engine = ShortcutEngine::from_file(&default_shortcut_file()).unwrap();

    assert_eq!(
        engine.observe(KEY_LEFT_CTRL, true),
        ShortcutDisposition::Forward
    );
    assert_eq!(engine.observe(KEY_F1, true), ShortcutDisposition::Forward);
    assert_eq!(engine.observe(KEY_F1, false), ShortcutDisposition::Forward);
    assert_eq!(
        engine.observe(KEY_LEFT_ALT, true),
        ShortcutDisposition::Forward
    );
    assert_eq!(
        engine.observe(KEY_LEFT_SHIFT, true),
        ShortcutDisposition::Forward
    );
    assert_eq!(engine.observe(KEY_F1, true), ShortcutDisposition::Forward);
}

#[test]
fn v4_migration_relocates_the_legacy_maximize_binding_for_navigation() {
    let mut file = ShortcutFile {
        version: 3,
        revision: 1,
        shortcuts: vec![ShortcutBinding {
            shortcut: "Super+Up".to_owned(),
            target: ShortcutTarget::DenialAction {
                action: ShortcutAction::ToggleMaximize,
            },
        }],
    };

    assert_eq!(
        migrate_shortcut_file(&mut file).unwrap(),
        Some(
            1 + SHORTCUT_V4_ADDITIONS.len()
                + SHORTCUT_V5_ADDITIONS.len()
                + SHORTCUT_V6_ADDITIONS.len()
                + SHORTCUT_V9_ADDITIONS.len()
                + SHORTCUT_V10_ADDITIONS.len()
                + SHORTCUT_V12_PLUGIN_ADDITIONS.len()
        )
    );
    assert_eq!(file.version, SHORTCUT_SCHEMA_VERSION);
    let action_for = |shortcut: &str| {
        file.shortcuts
            .iter()
            .find(|binding| binding.shortcut == shortcut)
            .and_then(|binding| match binding.target {
                ShortcutTarget::DenialAction { action } => Some(action),
                _ => None,
            })
    };
    assert_eq!(action_for("Super+W"), Some(ShortcutAction::ToggleMaximize));
    assert_eq!(action_for("Super+Up"), Some(ShortcutAction::FocusUp));
    assert_eq!(
        action_for("Super+Ctrl+Right"),
        Some(ShortcutAction::SwapRight)
    );
}

#[test]
fn v5_migration_adds_workspace_defaults_without_overwriting_user_bindings() {
    let mut file = ShortcutFile {
        version: 4,
        revision: 7,
        shortcuts: vec![ShortcutBinding {
            shortcut: "Super+1".to_owned(),
            target: ShortcutTarget::SpawnSh {
                command: "custom-command".to_owned(),
            },
        }],
    };

    assert!(migrate_shortcut_file(&mut file).unwrap().is_some());
    assert_eq!(file.version, SHORTCUT_SCHEMA_VERSION);
    assert!(file.shortcuts.iter().any(|binding| {
        binding.shortcut == "Super+1"
            && matches!(
                &binding.target,
                ShortcutTarget::SpawnSh { command } if command == "custom-command"
            )
    }));
    assert!(
        !file
            .shortcuts
            .iter()
            .any(|binding| binding.shortcut == "Super+S")
    );
}

#[test]
fn v7_migration_removes_the_retired_workspace_overview_action() {
    let mut document = serde_json::json!({
        "version": 6,
        "revision": 12,
        "shortcuts": [
            {
                "shortcut": "Super+S",
                "target": {
                    "type": "denialAction",
                    "action": "openWorkspaces"
                }
            },
            {
                "shortcut": "Super+Alt+Right",
                "target": {
                    "type": "denialAction",
                    "action": "nextWorkspace"
                }
            }
        ]
    });

    assert_eq!(remove_retired_shortcut_actions(&mut document), 1);
    let mut file = serde_json::from_value::<ShortcutFile>(document).unwrap();
    assert_eq!(
        migrate_shortcut_file(&mut file).unwrap(),
        Some(2 + SHORTCUT_V10_ADDITIONS.len() + SHORTCUT_V12_PLUGIN_ADDITIONS.len())
    );
    assert_eq!(file.version, SHORTCUT_SCHEMA_VERSION);
    assert_eq!(file.revision, 13);
    assert_eq!(
        file.shortcuts.len(),
        3 + SHORTCUT_V10_ADDITIONS.len() + SHORTCUT_V12_PLUGIN_ADDITIONS.len()
    );
    assert_eq!(file.shortcuts[0].shortcut, "Super+Alt+Right");
}

#[test]
fn v6_migration_adds_workspace_swipes_without_overwriting_user_bindings() {
    let mut file = ShortcutFile {
        version: 5,
        revision: 11,
        shortcuts: vec![ShortcutBinding {
            shortcut: "FourFingerSwipeRight".to_owned(),
            target: ShortcutTarget::SpawnSh {
                command: "custom-command".to_owned(),
            },
        }],
    };

    assert_eq!(
        migrate_shortcut_file(&mut file).unwrap(),
        Some(3 + SHORTCUT_V10_ADDITIONS.len() + SHORTCUT_V12_PLUGIN_ADDITIONS.len())
    );
    assert_eq!(file.version, SHORTCUT_SCHEMA_VERSION);
    assert_eq!(file.revision, 12);
    assert!(file.shortcuts.iter().any(|binding| {
        binding.shortcut == "FourFingerSwipeRight"
            && matches!(
                &binding.target,
                ShortcutTarget::SpawnSh { command } if command == "custom-command"
            )
    }));
    assert!(file.shortcuts.iter().any(|binding| {
        binding.shortcut == "FourFingerSwipeLeft"
            && matches!(
                &binding.target,
                ShortcutTarget::DenialAction {
                    action: ShortcutAction::NextWorkspace
                }
            )
    }));
}

#[test]
fn v8_migration_inverts_only_the_saved_default_workspace_swipes() {
    let mut file = ShortcutFile {
        version: 7,
        revision: 14,
        shortcuts: vec![
            ShortcutBinding {
                shortcut: "FourFingerSwipeRight".to_owned(),
                target: ShortcutTarget::SpawnSh {
                    command: "custom-command".to_owned(),
                },
            },
            ShortcutBinding {
                shortcut: "FourFingerSwipeLeft".to_owned(),
                target: ShortcutTarget::DenialAction {
                    action: ShortcutAction::PreviousWorkspace,
                },
            },
        ],
    };

    assert_eq!(
        migrate_shortcut_file(&mut file).unwrap(),
        Some(3 + SHORTCUT_V10_ADDITIONS.len() + SHORTCUT_V12_PLUGIN_ADDITIONS.len())
    );
    assert_eq!(file.version, SHORTCUT_SCHEMA_VERSION);
    assert_eq!(file.revision, 15);
    assert!(matches!(
        &file.shortcuts[0].target,
        ShortcutTarget::SpawnSh { command } if command == "custom-command"
    ));
    assert_eq!(
        file.shortcuts[1].target,
        ShortcutTarget::DenialAction {
            action: ShortcutAction::NextWorkspace
        }
    );
}

#[test]
fn four_finger_swipe_defaults_follow_requested_workspace_direction() {
    let mut engine = ShortcutEngine::from_file(&default_shortcut_file()).unwrap();

    assert_eq!(
        engine.observe_gesture(ShortcutGesture::FourFingerSwipeRight),
        ShortcutDisposition::RequestPreviousWorkspace
    );
    assert_eq!(
        engine.observe_gesture(ShortcutGesture::FourFingerSwipeLeft),
        ShortcutDisposition::RequestNextWorkspace
    );
    assert_eq!(
        engine.observe_gesture(ShortcutGesture::FourFingerSwipeDown),
        ShortcutDisposition::RequestPreviousWorkspace
    );
    assert_eq!(
        engine.observe_gesture(ShortcutGesture::FourFingerSwipeUp),
        ShortcutDisposition::RequestNextWorkspace
    );
}

#[test]
fn declined_contextual_workspace_shortcut_forwards_its_release() {
    let file = default_shortcut_file();
    let mut engine = ShortcutEngine::from_file(&file).unwrap();
    assert_eq!(
        engine.observe(KEY_LEFT_META, true),
        ShortcutDisposition::Consume
    );
    assert_eq!(
        engine.observe(2, true),
        ShortcutDisposition::RequestSwitchWorkspace(1)
    );
    engine.pass_through_key(2);
    assert_eq!(engine.observe(2, false), ShortcutDisposition::Forward);
}

#[test]
fn super_pointer_axis_suppresses_the_modifier_tap_action() {
    let mut engine = ShortcutEngine::from_file(&default_shortcut_file()).unwrap();

    assert_eq!(
        engine.observe(KEY_LEFT_META, true),
        ShortcutDisposition::Consume
    );
    engine.note_pointer_axis();
    assert_eq!(
        engine.observe(KEY_LEFT_META, false),
        ShortcutDisposition::Consume
    );
}
#[test]
fn cancelling_a_virtual_modifier_hold_does_not_invoke_its_tap_action() {
    let mut file = default_shortcut_file();
    file.shortcuts = vec![ShortcutBinding {
        shortcut: "Super".into(),
        target: ShortcutTarget::DenialAction {
            action: ShortcutAction::OpenOverview,
        },
    }];
    let mut engine = ShortcutEngine::from_file(&file).unwrap();
    engine.observe(KEY_LEFT_META, true);
    assert_eq!(
        engine.observe(KEY_LEFT_META, false),
        ShortcutDisposition::RequestOverview
    );
    engine.observe(KEY_LEFT_META, true);
    engine.cancel_modifier_tap();
    assert_eq!(
        engine.observe(KEY_LEFT_META, false),
        ShortcutDisposition::Consume
    );
}
