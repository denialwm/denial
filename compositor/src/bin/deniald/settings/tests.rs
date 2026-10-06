use super::*;
use std::os::unix::fs::symlink;

struct TemporaryDirectory(PathBuf);

impl TemporaryDirectory {
    fn new(label: &str) -> Self {
        let sequence = SETTINGS_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let path =
            std::env::temp_dir().join(format!("denial-{label}-{}-{sequence}", std::process::id()));
        fs::create_dir(&path).expect("create temporary directory");
        Self(path)
    }

    fn settings_path(&self) -> PathBuf {
        self.0.join("denial/settings.json")
    }
}

impl Drop for TemporaryDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn shell_document(value: Value) -> String {
    let mut document = value
        .as_object()
        .cloned()
        .expect("test shell document must be an object");
    if let Some(appearance) = document
        .get_mut("appearance")
        .and_then(Value::as_object_mut)
    {
        appearance
            .entry("allowClientCursorSurfaces")
            .or_insert(Value::Bool(true));
        appearance
            .entry("cursorSize")
            .or_insert(Value::from(DEFAULT_CURSOR_SIZE));
    }
    let layout = document
        .entry("layout")
        .or_insert_with(|| Value::Object(Map::new()))
        .as_object_mut()
        .expect("test shell layout must be an object");
    layout
        .entry("windowLayout")
        .or_insert_with(|| Value::String("stacking".to_owned()));
    layout
        .entry("scrollingLayoutWheelSpeed")
        .or_insert(Value::from(DEFAULT_SCROLLING_LAYOUT_WHEEL_SPEED));
    layout
        .entry("scrollingLayoutWheelUpDirection")
        .or_insert_with(|| Value::String("left".to_owned()));
    layout
        .entry("workspacesEnabled")
        .or_insert(Value::Bool(false));
    layout
        .entry("workspaceCount")
        .or_insert(Value::from(DEFAULT_WORKSPACE_COUNT));
    layout
        .entry("workspaceSwitchingOrientation")
        .or_insert_with(|| Value::String("horizontal".to_owned()));
    document.insert("version".to_owned(), Value::from(SETTINGS_SCHEMA_VERSION));
    serde_json::to_string(&document).expect("test shell document serializes")
}

#[test]
fn migrates_existing_shell_document_without_losing_sections() {
    let temporary = TemporaryDirectory::new("settings-migrate");
    let path = temporary.settings_path();
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(&path, br#"{"version":7,"appearance":{"windowRadius":31}}"#).unwrap();

    let manager = SettingsManager::load_path(path.clone()).unwrap();
    assert_eq!(manager.revision(), 1);
    assert_eq!(manager.keyboard(), &KeyboardSettings::default());
    assert_eq!(manager.mouse(), &MouseSettings::default());
    assert_eq!(manager.touchpad(), &TouchpadSettings::default());
    let document: Value = serde_json::from_str(&manager.document_json().unwrap()).unwrap();
    assert_eq!(document["version"], SETTINGS_SCHEMA_VERSION);
    assert_eq!(document["appearance"]["windowRadius"], 31);
    assert_eq!(
        document["appearance"]["colorSchemePreference"],
        "preferDark"
    );
    assert_eq!(document["appearance"]["allowClientCursorSurfaces"], true);
    assert_eq!(document["appearance"]["cursorSize"], DEFAULT_CURSOR_SIZE);
    assert_eq!(document["layout"]["windowLayout"], "stacking");
    assert_eq!(
        document["layout"]["scrollingLayoutWheelSpeed"],
        DEFAULT_SCROLLING_LAYOUT_WHEEL_SPEED
    );
    assert_eq!(
        document["layout"]["scrollingLayoutWheelUpDirection"],
        "left"
    );
    assert_eq!(document["layout"]["workspacesEnabled"], false);
    assert_eq!(document["layout"]["workspaceCount"], 4);
    assert_eq!(
        document["layout"]["workspaceSwitchingOrientation"],
        "horizontal"
    );
    assert_eq!(manager.workspace_settings(), WorkspaceSettings::default());
    assert_eq!(manager.window_layout_kind(), WindowLayoutKind::Stacking);
    assert!(manager.allow_client_cursor_surfaces());
    assert_eq!(
        manager.theme_snapshot(),
        DesktopThemeSnapshot::new(manager.revision(), DesktopColorSchemePreference::PreferDark,)
    );
    assert!(document.get("keyboard").is_some());
    assert!(document.get("mouse").is_some());
    assert!(document.get("touchpad").is_some());
    assert_eq!(
        document["applicationEnvironment"],
        serde_json::json!({"default": {}, "applications": {}})
    );
    assert_eq!(
        fs::metadata(path).unwrap().permissions().mode() & 0o777,
        0o600
    );
}

#[test]
fn malformed_document_is_never_overwritten_during_startup() {
    let temporary = TemporaryDirectory::new("settings-malformed");
    let path = temporary.settings_path();
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let malformed = b"{ this is not settings JSON\n";
    fs::write(&path, malformed).unwrap();

    let manager = SettingsManager::load_path(path.clone()).unwrap();
    assert_eq!(manager.keyboard(), &KeyboardSettings::default());
    assert_eq!(manager.mouse(), &MouseSettings::default());
    assert_eq!(manager.touchpad(), &TouchpadSettings::default());
    assert_eq!(fs::read(path).unwrap(), malformed);
}

#[test]
fn shell_update_preserves_native_keyboard_and_checks_revision() {
    let temporary = TemporaryDirectory::new("settings-shell-update");
    let mut manager = SettingsManager::load_path(temporary.settings_path()).unwrap();
    let configured = KeyboardSettings {
        layouts: vec![KeyboardLayout {
            layout: "de".to_owned(),
            variant: "nodeadkeys".to_owned(),
        }],
        options: vec!["compose:menu".to_owned()],
        repeat_delay_ms: 450,
        repeat_rate_hz: 30,
    };
    let update = manager
        .prepare_keyboard_update(manager.revision(), configured.clone())
        .unwrap();
    manager.commit(update).unwrap();
    let configured_mouse = MouseSettings { speed: 0.35 };
    let update = manager
        .prepare_mouse_update(manager.revision(), configured_mouse.clone())
        .unwrap();
    manager.commit(update).unwrap();
    let old_revision = manager.revision();
    let shell_update = shell_document(serde_json::json!({
        "appearance": {
            "colorSchemePreference": "preferLight",
            "allowClientCursorSurfaces": false,
            "cursorSize": 48
        },
        "applicationEnvironment": {
            "default": {"MOZ_ENABLE_WAYLAND": "1", "DISPLAY": null},
            "applications": {
                "org.mozilla.firefox.desktop": {"MOZ_ENABLE_WAYLAND": "0"}
            }
        },
        "revision": 999,
        "keyboard": {"layouts": []},
        "mouse": {"speed": -0.8},
        "touchpad": {"tapToClickEnabled": false},
        "power": {"idleDpmsEnabled": false}
    }));
    let update = manager
        .prepare_shell_update(old_revision, &shell_update)
        .unwrap();
    manager.commit(update).unwrap();
    assert_eq!(manager.keyboard(), &configured);
    assert_eq!(manager.mouse(), &configured_mouse);
    assert_eq!(manager.revision(), old_revision + 1);
    assert_eq!(manager.cursor_size(), 48);
    let document: Value = serde_json::from_str(&manager.document_json().unwrap()).unwrap();
    assert_eq!(
        document["applicationEnvironment"]["default"]["MOZ_ENABLE_WAYLAND"],
        "1"
    );
    assert_eq!(
        document["applicationEnvironment"]["default"]["DISPLAY"],
        Value::Null
    );
    assert_eq!(
        document["applicationEnvironment"]["applications"]["org.mozilla.firefox.desktop"]["MOZ_ENABLE_WAYLAND"],
        "0"
    );
    assert_eq!(
        manager.theme_snapshot().configured_preference,
        DesktopColorSchemePreference::PreferLight
    );
    assert!(!manager.allow_client_cursor_surfaces());
    let stale_update = shell_document(serde_json::json!({
        "appearance": {"colorSchemePreference": "preferDark"}
    }));
    assert!(matches!(
        manager.prepare_shell_update(old_revision, &stale_update),
        Err(SettingsError::Revision { .. })
    ));
}

#[test]
fn shell_update_rejects_missing_or_unknown_color_scheme() {
    let temporary = TemporaryDirectory::new("settings-color-scheme");
    let manager = SettingsManager::load_path(temporary.settings_path()).unwrap();
    for document in [
        shell_document(serde_json::json!({})),
        shell_document(serde_json::json!({"appearance": {}})),
        shell_document(serde_json::json!({
            "appearance": {"colorSchemePreference": "automatic"}
        })),
    ] {
        assert!(matches!(
            manager.prepare_shell_update(manager.revision(), &document),
            Err(SettingsError::Document(_))
        ));
    }
}

#[test]
fn window_layout_is_validated_and_persisted() {
    let temporary = TemporaryDirectory::new("settings-window-layout");
    let path = temporary.settings_path();
    let mut manager = SettingsManager::load_path(path.clone()).unwrap();
    let update = manager
        .prepare_shell_update(
            manager.revision(),
            &shell_document(serde_json::json!({
                "appearance": {"colorSchemePreference": "preferDark"},
                "layout": {"windowLayout": "dwindle"}
            })),
        )
        .unwrap();
    manager.commit(update).unwrap();

    assert_eq!(manager.window_layout_kind(), WindowLayoutKind::Dwindle);
    assert_eq!(
        SettingsManager::load_path(path)
            .unwrap()
            .window_layout_kind(),
        WindowLayoutKind::Dwindle
    );

    let update = manager
        .prepare_shell_update(
            manager.revision(),
            &shell_document(serde_json::json!({
                "appearance": {"colorSchemePreference": "preferDark"},
                "layout": {"windowLayout": "scrolling"}
            })),
        )
        .unwrap();
    manager.commit(update).unwrap();
    assert_eq!(manager.window_layout_kind(), WindowLayoutKind::Scrolling);

    for window_layout in [Value::String("columns".to_owned()), Value::Bool(true)] {
        let document = shell_document(serde_json::json!({
            "appearance": {"colorSchemePreference": "preferDark"},
            "layout": {"windowLayout": window_layout}
        }));
        assert!(matches!(
            manager.prepare_shell_update(manager.revision(), &document),
            Err(SettingsError::Document(_))
        ));
    }
}

#[test]
fn scrolling_layout_wheel_settings_are_validated_and_persisted() {
    let temporary = TemporaryDirectory::new("settings-scrolling-layout-wheel");
    let path = temporary.settings_path();
    let mut manager = SettingsManager::load_path(path.clone()).unwrap();
    let update = manager
        .prepare_shell_update(
            manager.revision(),
            &shell_document(serde_json::json!({
                "appearance": {"colorSchemePreference": "preferDark"},
                "layout": {
                    "scrollingLayoutWheelSpeed": 2.25,
                    "scrollingLayoutWheelUpDirection": "right"
                }
            })),
        )
        .unwrap();
    manager.commit(update).unwrap();

    let configured = ScrollingLayoutWheelSettings {
        speed: 2.25,
        up_direction: ScrollingLayoutWheelUpDirection::Right,
    };
    assert_eq!(manager.scrolling_layout_wheel_settings(), configured);
    assert_eq!(
        SettingsManager::load_path(path)
            .unwrap()
            .scrolling_layout_wheel_settings(),
        configured
    );

    for speed in [0.249, 4.001] {
        let document = shell_document(serde_json::json!({
            "appearance": {"colorSchemePreference": "preferDark"},
            "layout": {"scrollingLayoutWheelSpeed": speed}
        }));
        assert!(matches!(
            manager.prepare_shell_update(manager.revision(), &document),
            Err(SettingsError::Document(_))
        ));
    }
    let invalid_direction = shell_document(serde_json::json!({
        "appearance": {"colorSchemePreference": "preferDark"},
        "layout": {"scrollingLayoutWheelUpDirection": "up"}
    }));
    assert!(matches!(
        manager.prepare_shell_update(manager.revision(), &invalid_direction),
        Err(SettingsError::Document(_))
    ));
}

#[test]
fn touchpad_update_is_persistent_and_revisioned() {
    let temporary = TemporaryDirectory::new("settings-touchpad-update");
    let path = temporary.settings_path();
    let mut manager = SettingsManager::load_path(path.clone()).unwrap();
    let configured = TouchpadSettings {
        tap_to_click_enabled: false,
        natural_scroll_enabled: true,
        scroll_speed_factor: 2.5,
        scrolling_layout_swipe_speed_factor: 1.75,
    };
    let old_revision = manager.revision();
    let update = manager
        .prepare_touchpad_update(old_revision, configured.clone())
        .unwrap();
    manager.commit(update).unwrap();

    assert_eq!(manager.revision(), old_revision + 1);
    assert_eq!(manager.touchpad(), &configured);
    let reloaded = SettingsManager::load_path(path).unwrap();
    assert_eq!(reloaded.revision(), old_revision + 1);
    assert_eq!(reloaded.touchpad(), &configured);
}

#[test]
fn rejects_touchpad_scroll_speed_outside_supported_range() {
    let temporary = TemporaryDirectory::new("settings-touchpad-scroll-speed");
    let manager = SettingsManager::load_path(temporary.settings_path()).unwrap();
    for scroll_speed_factor in [0.049, 5.001, f64::NAN] {
        let configured = TouchpadSettings {
            scroll_speed_factor,
            ..TouchpadSettings::default()
        };
        assert!(matches!(
            manager.prepare_touchpad_update(manager.revision(), configured),
            Err(SettingsError::Touchpad(_))
        ));
    }
}

#[test]
fn rejects_touchpad_scrolling_layout_swipe_speed_outside_supported_range() {
    let temporary = TemporaryDirectory::new("settings-touchpad-scrolling-layout-swipe-speed");
    let manager = SettingsManager::load_path(temporary.settings_path()).unwrap();
    for scrolling_layout_swipe_speed_factor in [0.249, 4.001, f64::NAN] {
        let configured = TouchpadSettings {
            scrolling_layout_swipe_speed_factor,
            ..TouchpadSettings::default()
        };
        assert!(matches!(
            manager.prepare_touchpad_update(manager.revision(), configured),
            Err(SettingsError::Touchpad(_))
        ));
    }
}

#[test]
fn mouse_update_is_persistent_and_revisioned() {
    let temporary = TemporaryDirectory::new("settings-mouse-update");
    let path = temporary.settings_path();
    let mut manager = SettingsManager::load_path(path.clone()).unwrap();
    let configured = MouseSettings { speed: 0.55 };
    let old_revision = manager.revision();
    let update = manager
        .prepare_mouse_update(old_revision, configured.clone())
        .unwrap();
    manager.commit(update).unwrap();

    assert_eq!(manager.revision(), old_revision + 1);
    assert_eq!(manager.mouse(), &configured);
    let reloaded = SettingsManager::load_path(path).unwrap();
    assert_eq!(reloaded.revision(), old_revision + 1);
    assert_eq!(reloaded.mouse(), &configured);
}

#[test]
fn rejects_mouse_speed_outside_supported_range() {
    let temporary = TemporaryDirectory::new("settings-mouse-speed");
    let manager = SettingsManager::load_path(temporary.settings_path()).unwrap();
    for speed in [-1.001, 1.001, f64::NAN] {
        assert!(matches!(
            manager.prepare_mouse_update(manager.revision(), MouseSettings { speed }),
            Err(SettingsError::Mouse(_))
        ));
    }
}

#[test]
fn rejects_external_edits_before_commit() {
    let temporary = TemporaryDirectory::new("settings-conflict");
    let path = temporary.settings_path();
    let mut manager = SettingsManager::load_path(path.clone()).unwrap();
    let shell_update = shell_document(serde_json::json!({
        "appearance": {"colorSchemePreference": "preferDark"}
    }));
    let prepared = manager
        .prepare_shell_update(manager.revision(), &shell_update)
        .unwrap();
    let external_edit = shell_document(serde_json::json!({"revision": 77}));
    fs::write(&path, format!("{external_edit}\n")).unwrap();
    assert!(matches!(
        manager.commit(prepared),
        Err(SettingsError::Conflict)
    ));
}

#[test]
fn reloads_external_edit_with_an_authoritative_revision() {
    let temporary = TemporaryDirectory::new("settings-external-reload");
    let path = temporary.settings_path();
    let mut manager = SettingsManager::load_path(path.clone()).unwrap();
    let old_revision = manager.revision();
    let external_edit = shell_document(serde_json::json!({
        "revision": 9000,
        "appearance": {
            "colorSchemePreference": "preferLight",
            "cursorSize": 48
        },
        "externalEditorMarker": true
    }));
    fs::write(&path, format!("{external_edit}\n")).unwrap();

    let prepared = manager
        .prepare_external_reload()
        .unwrap()
        .expect("external bytes should produce a transaction");
    manager.commit(prepared).unwrap();

    assert_eq!(manager.revision(), old_revision + 1);
    assert_eq!(manager.cursor_size(), 48);
    let document: Value = serde_json::from_str(&manager.document_json().unwrap()).unwrap();
    assert_eq!(document["revision"], old_revision + 1);
    assert_eq!(
        document["appearance"]["colorSchemePreference"],
        "preferLight"
    );
    assert_eq!(document["externalEditorMarker"], true);
    assert!(manager.prepare_external_reload().unwrap().is_none());

    let update = manager
        .prepare_mouse_update(manager.revision(), MouseSettings { speed: 0.25 })
        .unwrap();
    manager.commit(update).unwrap();
}

#[test]
fn external_removal_restores_and_recreates_defaults() {
    let temporary = TemporaryDirectory::new("settings-external-removal");
    let path = temporary.settings_path();
    let mut manager = SettingsManager::load_path(path.clone()).unwrap();
    let update = manager
        .prepare_mouse_update(manager.revision(), MouseSettings { speed: 0.75 })
        .unwrap();
    manager.commit(update).unwrap();
    let old_revision = manager.revision();
    fs::remove_file(&path).unwrap();

    let prepared = manager
        .prepare_external_reload()
        .unwrap()
        .expect("removal should produce a default-settings transaction");
    manager.commit(prepared).unwrap();

    assert_eq!(manager.revision(), old_revision + 1);
    assert_eq!(manager.mouse(), &MouseSettings::default());
    assert!(path.is_file());
}

#[test]
fn invalid_external_edit_stays_on_disk_without_changing_live_state() {
    let temporary = TemporaryDirectory::new("settings-invalid-external-reload");
    let path = temporary.settings_path();
    let manager = SettingsManager::load_path(path.clone()).unwrap();
    let old_revision = manager.revision();
    fs::write(&path, b"{ invalid json\n").unwrap();

    assert!(matches!(
        manager.prepare_external_reload(),
        Err(SettingsError::Json(_))
    ));
    assert_eq!(manager.revision(), old_revision);
    assert_eq!(fs::read(&path).unwrap(), b"{ invalid json\n");
}

#[test]
fn rejects_a_second_external_edit_during_reload() {
    let temporary = TemporaryDirectory::new("settings-external-reload-race");
    let path = temporary.settings_path();
    let mut manager = SettingsManager::load_path(path.clone()).unwrap();
    let first = shell_document(serde_json::json!({
        "appearance": {"colorSchemePreference": "preferLight"}
    }));
    fs::write(&path, format!("{first}\n")).unwrap();
    let prepared = manager
        .prepare_external_reload()
        .unwrap()
        .expect("first external edit should prepare");
    let second = shell_document(serde_json::json!({
        "appearance": {"colorSchemePreference": "noPreference"}
    }));
    fs::write(&path, format!("{second}\n")).unwrap();

    assert!(matches!(
        manager.commit(prepared),
        Err(SettingsError::Conflict)
    ));
}

#[test]
fn rejects_symlink_target() {
    let temporary = TemporaryDirectory::new("settings-symlink");
    let path = temporary.settings_path();
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let target = temporary.0.join("target");
    fs::write(&target, b"{}\n").unwrap();
    symlink(&target, &path).unwrap();
    assert!(matches!(
        SettingsManager::load_path(path),
        Err(SettingsError::Path(_))
    ));
}

#[test]
fn validates_keyboard_bounds_and_installed_keymaps() {
    let defaults = KeyboardSettings::default();
    assert_eq!(defaults.compiled_layout_names().unwrap().len(), 1);

    let mut invalid = defaults.clone();
    invalid.layouts[0].layout = "not,a,layout".to_owned();
    assert!(matches!(
        invalid.validate(),
        Err(SettingsError::Keyboard(_))
    ));

    let mut missing = defaults;
    missing.layouts[0].layout = "denial_missing_layout".to_owned();
    assert!(matches!(
        missing.compiled_layout_names(),
        Err(SettingsError::Keyboard(_))
    ));
}

#[test]
fn validates_application_environment_before_writing() {
    let temporary = TemporaryDirectory::new("settings-application-environment");
    let manager = SettingsManager::load_path(temporary.settings_path()).unwrap();
    let valid_document = shell_document(serde_json::json!({
        "appearance": {"colorSchemePreference": "preferDark"},
        "applicationEnvironment": {
            "default": {"EMPTY": "", "REMOVE_ME": null},
            "applications": {"org.example.App.desktop": {"APP_ONLY": "1"}}
        }
    }));
    let valid = manager
        .prepare_shell_update(manager.revision(), &valid_document)
        .expect("valid application environment");
    drop(valid);

    for document in [
        shell_document(serde_json::json!({
            "appearance": {"colorSchemePreference": "preferDark"},
            "applicationEnvironment": []
        })),
        shell_document(serde_json::json!({
            "appearance": {"colorSchemePreference": "preferDark"},
            "applicationEnvironment": {
                "default": {"invalid-name": "value"}, "applications": {}
            }
        })),
        shell_document(serde_json::json!({
            "appearance": {"colorSchemePreference": "preferDark"},
            "applicationEnvironment": {
                "default": {"VALID": 3}, "applications": {}
            }
        })),
        shell_document(serde_json::json!({
            "appearance": {"colorSchemePreference": "preferDark"},
            "applicationEnvironment": {
                "default": {},
                "applications": {"not/a.desktop": {"VALID": "1"}}
            }
        })),
    ] {
        assert!(matches!(
            manager.prepare_shell_update(manager.revision(), &document),
            Err(SettingsError::Document(_))
        ));
    }
}

#[test]
fn gtk_input_method_policy_is_split_by_display_backend() {
    fn environment(value: serde_json::Value) -> ApplicationEnvironment {
        let document = serde_json::json!({"applicationEnvironment": value});
        ApplicationEnvironment::from_document(document.as_object().unwrap()).unwrap()
    }

    assert_eq!(GTK_INPUT_METHOD_BACKEND_FALLBACK, "wayland:xim");
    assert_eq!(x11_gtk_input_method_backend_fallback(), "xim");

    let configured = environment(serde_json::json!({
        "default": {"XMODIFIERS": "@im=fcitx"},
        "applications": {}
    }));
    let mut command = Command::new("true");
    configured.apply(&mut command, None, None);
    let child_environment = command.get_envs().collect::<BTreeMap<_, _>>();
    assert_eq!(
        child_environment.get(OsStr::new("XMODIFIERS")),
        Some(&Some(OsStr::new("@im=fcitx")))
    );
    assert!(!child_environment.contains_key(OsStr::new("GTK_IM_MODULE")));
}
