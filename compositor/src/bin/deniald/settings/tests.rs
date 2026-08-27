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
    }
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
    assert_eq!(manager.touchpad(), &TouchpadSettings::default());
    let document: Value = serde_json::from_str(&manager.document_json().unwrap()).unwrap();
    assert_eq!(document["version"], SETTINGS_SCHEMA_VERSION);
    assert_eq!(document["appearance"]["windowRadius"], 31);
    assert_eq!(
        document["appearance"]["colorSchemePreference"],
        "preferDark"
    );
    assert_eq!(document["appearance"]["allowClientCursorSurfaces"], true);
    assert!(manager.allow_client_cursor_surfaces());
    assert_eq!(
        manager.theme_snapshot(),
        DesktopThemeSnapshot::new(manager.revision(), DesktopColorSchemePreference::PreferDark,)
    );
    assert!(document.get("keyboard").is_some());
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
    let old_revision = manager.revision();
    let shell_update = shell_document(serde_json::json!({
        "appearance": {
            "colorSchemePreference": "preferLight",
            "allowClientCursorSurfaces": false
        },
        "applicationEnvironment": {
            "default": {"MOZ_ENABLE_WAYLAND": "1", "DISPLAY": null},
            "applications": {
                "org.mozilla.firefox.desktop": {"MOZ_ENABLE_WAYLAND": "0"}
            }
        },
        "revision": 999,
        "keyboard": {"layouts": []},
        "touchpad": {"tapToClickEnabled": false},
        "power": {"idleDpmsEnabled": false}
    }));
    let update = manager
        .prepare_shell_update(old_revision, &shell_update)
        .unwrap();
    manager.commit(update).unwrap();
    assert_eq!(manager.keyboard(), &configured);
    assert_eq!(manager.revision(), old_revision + 1);
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
fn touchpad_update_is_persistent_and_revisioned() {
    let temporary = TemporaryDirectory::new("settings-touchpad-update");
    let path = temporary.settings_path();
    let mut manager = SettingsManager::load_path(path.clone()).unwrap();
    let configured = TouchpadSettings {
        tap_to_click_enabled: false,
        natural_scroll_enabled: true,
        scroll_speed_factor: 2.5,
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
