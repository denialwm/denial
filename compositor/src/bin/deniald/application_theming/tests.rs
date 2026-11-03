use super::*;
use std::os::unix::fs::{MetadataExt, symlink};
use std::sync::atomic::{AtomicU64, Ordering};

const ENABLED: Theme = Theme {
    enabled: true,
    opacity: 0.6,
};
const DISABLED: Theme = Theme {
    enabled: false,
    ..ENABLED
};

struct Fixture(PathBuf);

impl Fixture {
    fn new() -> Self {
        static SEQUENCE: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "denial-theming-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed),
        ));
        fs::create_dir_all(path.join("bin")).unwrap();
        Self(path)
    }

    fn config(&self) -> PathBuf {
        self.0.join("config/kitty/kitty.conf")
    }
    fn bin(&self) -> PathBuf {
        self.0.join("bin")
    }

    fn sync(&self, theme: Theme) {
        sync_kitty(&self.config(), self.bin().as_os_str(), theme).unwrap();
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn takes_ownership_of_duplicate_keys_and_preserves_other_lines() {
    let input = "# background_opacity 0.2\r\nfont_size 13\r\nbackground_opacity 0.7\r\n  background_opacity 0.8\r\ninclude colors.conf";
    let result = rewrite_kitty(input, ENABLED).unwrap().unwrap();
    assert!(
        result.starts_with("# background_opacity 0.2\r\nfont_size 13\r\ninclude colors.conf\n")
    );
    assert!(result.ends_with("# Changes made to this block will be lost\nbackground_opacity 0.6\n# END Denial managed appearance\n"));
    assert_eq!(
        result
            .lines()
            .filter(|line| line.starts_with("background_opacity "))
            .count(),
        1
    );
}

#[test]
fn current_id_skips_even_an_edited_block_without_reading_its_values() {
    let edited = format!(
        "{}\nbackground_opacity edited-by-user\n{END}\n",
        ENABLED.header()
    );
    assert!(rewrite_kitty(&edited, ENABLED).unwrap().is_none());
}

#[test]
fn changed_theme_replaces_the_entire_block_and_removes_outside_duplicates() {
    let old = format!(
        "{}\nuser edits\n{END}\nbackground_opacity 0.9\nfont_size 12\n",
        ENABLED.header()
    );
    let changed = Theme {
        opacity: 0.4,
        ..ENABLED
    };
    let result = rewrite_kitty(&old, changed).unwrap().unwrap();
    assert_eq!(
        result,
        rewrite_kitty("font_size 12\n", changed).unwrap().unwrap()
    );
    assert!(result.contains("background_opacity 0.4\n"));
}

#[test]
fn disabling_removes_only_managed_blocks_and_missing_blocks_are_a_noop() {
    let input = format!(
        "font_size 12\n{BEGIN}\nanything\n{END}\nbackground_opacity 0.9\n{BEGIN}: old\nanything else\n{END}\n"
    );
    assert_eq!(
        rewrite_kitty(&input, DISABLED).unwrap().unwrap(),
        "font_size 12\nbackground_opacity 0.9\n"
    );
    assert!(rewrite_kitty("font_size 12\n", DISABLED).unwrap().is_none());
    assert!(rewrite_kitty("", DISABLED).unwrap().is_none());
}

#[test]
fn unterminated_block_does_not_delete_unrelated_settings() {
    let input = format!("{BEGIN}: old\nbackground_opacity 0.3\nfont_size 12\n");
    assert!(rewrite_kitty(&input, ENABLED).is_err());
    assert!(rewrite_kitty(&input, DISABLED).is_err());
}

#[test]
fn removes_continuations_of_owned_settings() {
    let result = rewrite_kitty("background_opacity\n  \\ 0.3\nfont_size 12\n", ENABLED)
        .unwrap()
        .unwrap();
    assert!(result.starts_with("font_size 12\n"));
    assert!(!result.contains("\\ 0.3"));
}

#[test]
fn discovery_requires_existing_config_or_a_path_executable_and_reapply_rediscovers() {
    let fixture = Fixture::new();
    fixture.sync(ENABLED);
    assert!(!fixture.0.join("config").exists());
    let executable = fixture.bin().join("kitty");
    fs::write(&executable, "").unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o600)).unwrap();
    fixture.sync(ENABLED);
    assert!(!fixture.config().exists());
    fs::remove_file(&executable).unwrap();
    fs::create_dir(&executable).unwrap();
    fixture.sync(ENABLED);
    assert!(!fixture.config().exists());
    fs::remove_dir(&executable).unwrap();
    fs::write(&executable, "").unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    fixture.sync(DISABLED);
    assert!(!fixture.config().exists());
    fixture.sync(ENABLED);
    assert!(
        fs::read_to_string(fixture.config())
            .unwrap()
            .contains("background_opacity 0.6")
    );
    let original = fs::metadata(fixture.config()).unwrap();
    fixture.sync(ENABLED);
    let current = fs::metadata(fixture.config()).unwrap();
    assert_eq!(original.ino(), current.ino());
    assert_eq!(original.modified().unwrap(), current.modified().unwrap());
    fs::remove_file(executable).unwrap();
    fixture.sync(DISABLED);
    assert_eq!(fs::read_to_string(fixture.config()).unwrap(), "");
}

#[test]
fn an_empty_existing_config_is_enough_and_symlinks_and_permissions_survive() {
    let fixture = Fixture::new();
    let dotfile = fixture.0.join("dotfile");
    fs::write(&dotfile, "").unwrap();
    fs::set_permissions(&dotfile, fs::Permissions::from_mode(0o640)).unwrap();
    fs::create_dir_all(fixture.config().parent().unwrap()).unwrap();
    symlink(&dotfile, fixture.config()).unwrap();
    fixture.sync(ENABLED);
    assert_eq!(fs::read_link(fixture.config()).unwrap(), dotfile);
    assert_eq!(
        fs::metadata(&dotfile).unwrap().permissions().mode() & 0o777,
        0o640
    );
    assert!(
        fs::read_to_string(&dotfile)
            .unwrap()
            .contains("background_opacity 0.6")
    );
    fixture.sync(DISABLED);
    assert_eq!(fs::read_to_string(&dotfile).unwrap(), "");
}

#[test]
fn theme_id_tracks_only_supported_values_and_defaults_to_enabled() {
    let mut document = serde_json::json!({"appearance": {"applicationThemingEnabled": true, "glass": {"windowOpacity": 0.6}}}).as_object().unwrap().clone();
    let first = Theme::from_document(&document);
    assert!(first.enabled);
    assert_eq!(first.header(), ENABLED.header());
    document.insert("revision".into(), Value::from(400));
    document.get_mut("appearance").unwrap()["fontFamily"] = Value::from("another font");
    assert_eq!(Theme::from_document(&document).header(), first.header());
    let defaults = Theme::from_document(&Map::new());
    assert!(defaults.enabled);
    assert_eq!(defaults.opacity, 0.4);
    document.get_mut("appearance").unwrap()["applicationThemingEnabled"] = Value::from(false);
    assert!(!Theme::from_document(&document).enabled);
    document.get_mut("appearance").unwrap()["glass"] = serde_json::json!({"opacity": 0.4});
    assert_eq!(Theme::from_document(&document).opacity, 0.4);
}

#[test]
fn opacity_follows_the_selected_transparency_mode() {
    let opacity = |appearance: Value| {
        let document = serde_json::json!({ "appearance": appearance });
        Theme::from_document(document.as_object().unwrap()).opacity
    };
    let glass = serde_json::json!({"windowOpacity": 0.6});
    assert_eq!(
        opacity(
            serde_json::json!({"transparencyMode": "glass", "panelOpacity": 0.3, "glass": glass})
        ),
        0.6
    );
    assert_eq!(
        opacity(
            serde_json::json!({"transparencyMode": "blur", "panelOpacity": 0.3, "glass": glass})
        ),
        0.3
    );
    assert_eq!(
        opacity(serde_json::json!({"transparencyMode": "blur"})),
        0.5
    );
    assert_eq!(
        opacity(serde_json::json!({"transparencyMode": "blur", "panelOpacity": 0.0})),
        0.05
    );
    assert_eq!(
        opacity(serde_json::json!({"transparencyMode": "off", "glass": glass})),
        1.0
    );
    assert_eq!(
        opacity(serde_json::json!({"backdropBlurEnabled": true, "panelOpacity": 0.3})),
        0.3
    );
    assert_eq!(
        opacity(serde_json::json!({"backdropBlurEnabled": false})),
        1.0
    );
}
