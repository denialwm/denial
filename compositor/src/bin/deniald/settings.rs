//! Rust-owned persistent Denial settings.
//!
//! Flutter owns presentation and typed shell models, but it never opens this
//! file.  Every mutation is revision checked and committed by deniald through
//! an fsync/rename transaction so compositor and shell settings cannot race.

use std::error::Error;
use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use smithay::input::keyboard::xkb;
use tracing::warn;

pub(super) const SETTINGS_SCHEMA_VERSION: u64 = 9;
const MAX_SETTINGS_BYTES: usize = 256 * 1024;
const MAX_KEYBOARD_LAYOUTS: usize = 8;
const MAX_KEYBOARD_OPTIONS: usize = 32;
const MAX_XKB_NAME_BYTES: usize = 64;
const MIN_REPEAT_DELAY_MS: u32 = 100;
const MAX_REPEAT_DELAY_MS: u32 = 5_000;
const MAX_REPEAT_RATE_HZ: u32 = 100;
const DEFAULT_REPEAT_DELAY_MS: u32 = 600;
const DEFAULT_REPEAT_RATE_HZ: u32 = 25;
static SETTINGS_TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct KeyboardLayout {
    pub(super) layout: String,
    #[serde(default)]
    pub(super) variant: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct KeyboardSettings {
    pub(super) layouts: Vec<KeyboardLayout>,
    #[serde(default)]
    pub(super) options: Vec<String>,
    #[serde(default = "default_repeat_delay_ms")]
    pub(super) repeat_delay_ms: u32,
    #[serde(default = "default_repeat_rate_hz")]
    pub(super) repeat_rate_hz: u32,
}

impl Default for KeyboardSettings {
    fn default() -> Self {
        Self {
            layouts: vec![KeyboardLayout {
                layout: "us".to_owned(),
                variant: String::new(),
            }],
            options: Vec::new(),
            repeat_delay_ms: DEFAULT_REPEAT_DELAY_MS,
            repeat_rate_hz: DEFAULT_REPEAT_RATE_HZ,
        }
    }
}

fn default_repeat_delay_ms() -> u32 {
    DEFAULT_REPEAT_DELAY_MS
}

fn default_repeat_rate_hz() -> u32 {
    DEFAULT_REPEAT_RATE_HZ
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct XkbNames {
    pub(super) layout: String,
    pub(super) variant: String,
    pub(super) options: String,
}

impl KeyboardSettings {
    pub(super) fn validate(&self) -> Result<(), SettingsError> {
        if self.layouts.is_empty() || self.layouts.len() > MAX_KEYBOARD_LAYOUTS {
            return Err(SettingsError::Keyboard(format!(
                "keyboard layouts must contain between 1 and {MAX_KEYBOARD_LAYOUTS} entries"
            )));
        }
        let mut identities = std::collections::HashSet::with_capacity(self.layouts.len());
        for layout in &self.layouts {
            validate_xkb_name(&layout.layout, false, "layout")?;
            validate_xkb_name(&layout.variant, true, "variant")?;
            if !identities.insert((&layout.layout, &layout.variant)) {
                return Err(SettingsError::Keyboard(format!(
                    "duplicate keyboard layout {} ({})",
                    layout.layout, layout.variant
                )));
            }
        }
        if self.options.len() > MAX_KEYBOARD_OPTIONS {
            return Err(SettingsError::Keyboard(format!(
                "keyboard options exceed the limit of {MAX_KEYBOARD_OPTIONS}"
            )));
        }
        let mut options = std::collections::HashSet::with_capacity(self.options.len());
        for option in &self.options {
            validate_xkb_option(option)?;
            if !options.insert(option) {
                return Err(SettingsError::Keyboard(format!(
                    "duplicate keyboard option {option}"
                )));
            }
        }
        if !(MIN_REPEAT_DELAY_MS..=MAX_REPEAT_DELAY_MS).contains(&self.repeat_delay_ms) {
            return Err(SettingsError::Keyboard(format!(
                "keyboard repeat delay must be within {MIN_REPEAT_DELAY_MS}..={MAX_REPEAT_DELAY_MS} ms"
            )));
        }
        if self.repeat_rate_hz > MAX_REPEAT_RATE_HZ {
            return Err(SettingsError::Keyboard(format!(
                "keyboard repeat rate must be within 0..={MAX_REPEAT_RATE_HZ} Hz"
            )));
        }
        Ok(())
    }

    pub(super) fn xkb_names(&self) -> XkbNames {
        XkbNames {
            layout: self
                .layouts
                .iter()
                .map(|layout| layout.layout.as_str())
                .collect::<Vec<_>>()
                .join(","),
            // Empty fields are significant: `us,de` with variants `,nodeadkeys`
            // applies the variant only to the second group.
            variant: self
                .layouts
                .iter()
                .map(|layout| layout.variant.as_str())
                .collect::<Vec<_>>()
                .join(","),
            options: self.options.join(","),
        }
    }

    /// Validates names against the installed XKB rules, not just the JSON
    /// grammar.  A typo must never make the graphical session unstartable.
    pub(super) fn compiled_layout_names(&self) -> Result<Vec<String>, SettingsError> {
        self.validate()?;
        let names = self.xkb_names();
        let context = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
        let keymap = xkb::Keymap::new_from_names(
            &context,
            "evdev",
            "pc105",
            &names.layout,
            &names.variant,
            Some(names.options),
            xkb::KEYMAP_COMPILE_NO_FLAGS,
        )
        .ok_or_else(|| {
            SettingsError::Keyboard("the configured XKB keymap could not be compiled".to_owned())
        })?;
        let layout_names = keymap.layouts().map(str::to_owned).collect::<Vec<_>>();
        if layout_names.len() != self.layouts.len() {
            return Err(SettingsError::Keyboard(format!(
                "XKB compiled {} groups for {} configured layouts",
                layout_names.len(),
                self.layouts.len()
            )));
        }
        Ok(layout_names)
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct TouchpadSettings {
    pub(super) tap_to_click_enabled: bool,
    pub(super) natural_scroll_enabled: bool,
}

impl Default for TouchpadSettings {
    fn default() -> Self {
        Self {
            tap_to_click_enabled: true,
            natural_scroll_enabled: false,
        }
    }
}

fn validate_xkb_name(value: &str, empty_allowed: bool, field: &str) -> Result<(), SettingsError> {
    if (!empty_allowed && value.is_empty())
        || value.len() > MAX_XKB_NAME_BYTES
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'+' | b'-'))
    {
        return Err(SettingsError::Keyboard(format!(
            "invalid XKB {field} name {value:?}"
        )));
    }
    Ok(())
}

fn validate_xkb_option(value: &str) -> Result<(), SettingsError> {
    if value.is_empty()
        || value.len() > MAX_XKB_NAME_BYTES
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'+' | b'-' | b':'))
    {
        return Err(SettingsError::Keyboard(format!(
            "invalid XKB option {value:?}"
        )));
    }
    Ok(())
}

#[derive(Debug)]
pub(super) enum SettingsError {
    Path(String),
    Io(std::io::Error),
    Json(serde_json::Error),
    Document(String),
    Keyboard(String),
    Revision { expected: u64, actual: u64 },
    Conflict,
}

impl fmt::Display for SettingsError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Path(reason) | Self::Document(reason) | Self::Keyboard(reason) => {
                formatter.write_str(reason)
            }
            Self::Io(error) => write!(formatter, "settings I/O failed: {error}"),
            Self::Json(error) => write!(formatter, "settings JSON is invalid: {error}"),
            Self::Revision { expected, actual } => write!(
                formatter,
                "settings revision conflict: expected {expected}, current revision is {actual}"
            ),
            Self::Conflict => formatter
                .write_str("settings file changed outside Denial; reload it before saving again"),
        }
    }
}

impl Error for SettingsError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Io(error) => Some(error),
            Self::Json(error) => Some(error),
            _ => None,
        }
    }
}

impl From<std::io::Error> for SettingsError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<serde_json::Error> for SettingsError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}

pub(super) struct SettingsManager {
    path: PathBuf,
    document: Map<String, Value>,
    revision: u64,
    keyboard: KeyboardSettings,
    touchpad: TouchpadSettings,
    /// Exact bytes last observed or committed by deniald. This catches an
    /// editor changing the file while the session is live, even if it forgets
    /// to update the human-visible revision field.
    persisted_bytes: Option<Vec<u8>>,
}

impl SettingsManager {
    pub(super) fn load() -> Result<Self, SettingsError> {
        Self::load_path(settings_path()?)
    }

    fn load_path(path: PathBuf) -> Result<Self, SettingsError> {
        let existing = read_settings_file(&path)?;
        if let Some(bytes) = existing.as_deref() {
            match parse_document(bytes) {
                Ok(parsed) => {
                    let mut manager = Self {
                        path,
                        document: parsed.document,
                        revision: parsed.revision,
                        keyboard: parsed.keyboard,
                        touchpad: parsed.touchpad,
                        persisted_bytes: existing,
                    };
                    if parsed.migrated
                        && let Err(error) = manager.persist_current()
                    {
                        warn!(%error, path = %manager.path.display(), "could not persist migrated Denial settings");
                    }
                    return Ok(manager);
                }
                Err(error) => {
                    warn!(%error, path = %path.display(), "using safe settings defaults without overwriting the invalid file");
                }
            }
        }

        let (document, revision, keyboard, touchpad) = default_document();
        let mut manager = Self {
            path,
            document,
            revision,
            keyboard,
            touchpad,
            persisted_bytes: existing,
        };
        if manager.persisted_bytes.is_none()
            && let Err(error) = manager.persist_current()
        {
            warn!(%error, path = %manager.path.display(), "could not create Denial settings; continuing with in-memory defaults");
        }
        Ok(manager)
    }

    pub(super) fn path(&self) -> &Path {
        &self.path
    }

    pub(super) fn revision(&self) -> u64 {
        self.revision
    }

    pub(super) fn keyboard(&self) -> &KeyboardSettings {
        &self.keyboard
    }

    pub(super) fn touchpad(&self) -> &TouchpadSettings {
        &self.touchpad
    }

    pub(super) fn document_json(&self) -> Result<String, SettingsError> {
        let bytes = render_document(&self.document)?;
        String::from_utf8(bytes)
            .map_err(|_| SettingsError::Document("settings JSON was not UTF-8".to_owned()))
    }

    pub(super) fn replace_invalid_keyboard_with_default(&mut self) {
        let keyboard = KeyboardSettings::default();
        self.document.insert(
            "keyboard".to_owned(),
            serde_json::to_value(&keyboard).expect("default keyboard settings serialize"),
        );
        self.keyboard = keyboard;
    }

    pub(super) fn prepare_shell_update(
        &self,
        expected_revision: u64,
        shell_json: &str,
    ) -> Result<PreparedSettingsUpdate, SettingsError> {
        self.check_revision(expected_revision)?;
        if shell_json.len() > MAX_SETTINGS_BYTES {
            return Err(SettingsError::Document(format!(
                "settings document exceeds {MAX_SETTINGS_BYTES} bytes"
            )));
        }
        let mut incoming = serde_json::from_str::<Value>(shell_json)?
            .as_object()
            .cloned()
            .ok_or_else(|| SettingsError::Document("settings root must be an object".to_owned()))?;
        let version = incoming
            .get("version")
            .and_then(Value::as_u64)
            .ok_or_else(|| SettingsError::Document("settings version is missing".to_owned()))?;
        if version != SETTINGS_SCHEMA_VERSION {
            return Err(SettingsError::Document(format!(
                "settings version {version} is not supported; expected {SETTINGS_SCHEMA_VERSION}"
            )));
        }

        // Native-owned fields can be echoed by Flutter but can never be
        // replaced through the shell-document request.
        incoming.remove("revision");
        incoming.remove("keyboard");
        incoming.remove("touchpad");
        incoming.insert("version".to_owned(), Value::from(SETTINGS_SCHEMA_VERSION));
        incoming.insert("revision".to_owned(), Value::from(self.next_revision()?));
        incoming.insert(
            "keyboard".to_owned(),
            serde_json::to_value(&self.keyboard).expect("validated keyboard settings serialize"),
        );
        incoming.insert(
            "touchpad".to_owned(),
            serde_json::to_value(&self.touchpad).expect("validated touchpad settings serialize"),
        );
        self.prepare(incoming, self.keyboard.clone(), self.touchpad.clone())
    }

    pub(super) fn prepare_keyboard_update(
        &self,
        expected_revision: u64,
        keyboard: KeyboardSettings,
    ) -> Result<PreparedSettingsUpdate, SettingsError> {
        self.check_revision(expected_revision)?;
        keyboard.compiled_layout_names()?;
        let mut document = self.document.clone();
        document.insert("revision".to_owned(), Value::from(self.next_revision()?));
        document.insert(
            "keyboard".to_owned(),
            serde_json::to_value(&keyboard).expect("validated keyboard settings serialize"),
        );
        self.prepare(document, keyboard, self.touchpad.clone())
    }

    pub(super) fn prepare_touchpad_update(
        &self,
        expected_revision: u64,
        touchpad: TouchpadSettings,
    ) -> Result<PreparedSettingsUpdate, SettingsError> {
        self.check_revision(expected_revision)?;
        let mut document = self.document.clone();
        document.insert("revision".to_owned(), Value::from(self.next_revision()?));
        document.insert(
            "touchpad".to_owned(),
            serde_json::to_value(&touchpad).expect("validated touchpad settings serialize"),
        );
        self.prepare(document, self.keyboard.clone(), touchpad)
    }

    pub(super) fn commit(
        &mut self,
        mut prepared: PreparedSettingsUpdate,
    ) -> Result<(), SettingsError> {
        if prepared.target != self.path {
            return Err(SettingsError::Path(
                "prepared settings target does not match the active store".to_owned(),
            ));
        }
        if read_settings_file(&self.path)? != self.persisted_bytes {
            return Err(SettingsError::Conflict);
        }
        fs::rename(&prepared.temporary, &self.path)?;
        prepared.committed = true;
        self.document = std::mem::take(&mut prepared.document);
        self.revision = prepared.revision;
        self.keyboard = std::mem::take(&mut prepared.keyboard);
        self.touchpad = std::mem::take(&mut prepared.touchpad);
        self.persisted_bytes = Some(std::mem::take(&mut prepared.bytes));
        // Rename is the transaction's point of no return. Keep memory and the
        // live keyboard aligned with the renamed file even on filesystems
        // which reject directory fsync; reporting a failed commit here would
        // cause the caller to roll back a configuration that is on disk.
        if let Err(error) = sync_parent(&self.path) {
            warn!(%error, path = %self.path.display(), "settings were committed but directory fsync failed");
        }
        Ok(())
    }

    fn check_revision(&self, expected: u64) -> Result<(), SettingsError> {
        if expected != self.revision {
            return Err(SettingsError::Revision {
                expected,
                actual: self.revision,
            });
        }
        Ok(())
    }

    fn next_revision(&self) -> Result<u64, SettingsError> {
        self.revision
            .checked_add(1)
            .ok_or_else(|| SettingsError::Document("settings revision exhausted".to_owned()))
    }

    fn prepare(
        &self,
        document: Map<String, Value>,
        keyboard: KeyboardSettings,
        touchpad: TouchpadSettings,
    ) -> Result<PreparedSettingsUpdate, SettingsError> {
        let revision = document
            .get("revision")
            .and_then(Value::as_u64)
            .ok_or_else(|| SettingsError::Document("settings revision is missing".to_owned()))?;
        let bytes = render_document(&document)?;
        let temporary = write_temporary(&self.path, &bytes)?;
        Ok(PreparedSettingsUpdate {
            target: self.path.clone(),
            temporary,
            document,
            revision,
            keyboard,
            touchpad,
            bytes,
            committed: false,
        })
    }

    fn persist_current(&mut self) -> Result<(), SettingsError> {
        let bytes = render_document(&self.document)?;
        let temporary = write_temporary(&self.path, &bytes)?;
        if read_settings_file(&self.path)? != self.persisted_bytes {
            let _ = fs::remove_file(&temporary);
            return Err(SettingsError::Conflict);
        }
        fs::rename(&temporary, &self.path)?;
        self.persisted_bytes = Some(bytes);
        if let Err(error) = sync_parent(&self.path) {
            warn!(%error, path = %self.path.display(), "settings were committed but directory fsync failed");
        }
        Ok(())
    }
}

pub(super) struct PreparedSettingsUpdate {
    target: PathBuf,
    temporary: PathBuf,
    document: Map<String, Value>,
    revision: u64,
    keyboard: KeyboardSettings,
    touchpad: TouchpadSettings,
    bytes: Vec<u8>,
    committed: bool,
}

impl PreparedSettingsUpdate {
    pub(super) fn keyboard(&self) -> &KeyboardSettings {
        &self.keyboard
    }

    pub(super) fn touchpad(&self) -> &TouchpadSettings {
        &self.touchpad
    }
}

impl Drop for PreparedSettingsUpdate {
    fn drop(&mut self) {
        if !self.committed {
            let _ = fs::remove_file(&self.temporary);
        }
    }
}

struct ParsedSettingsDocument {
    document: Map<String, Value>,
    revision: u64,
    keyboard: KeyboardSettings,
    touchpad: TouchpadSettings,
    migrated: bool,
}

fn parse_document(bytes: &[u8]) -> Result<ParsedSettingsDocument, SettingsError> {
    if bytes.len() > MAX_SETTINGS_BYTES {
        return Err(SettingsError::Document(format!(
            "settings document exceeds {MAX_SETTINGS_BYTES} bytes"
        )));
    }
    let mut document = serde_json::from_slice::<Value>(bytes)?
        .as_object()
        .cloned()
        .ok_or_else(|| SettingsError::Document("settings root must be an object".to_owned()))?;
    let version = document
        .get("version")
        .and_then(Value::as_u64)
        .ok_or_else(|| SettingsError::Document("settings version is missing".to_owned()))?;
    if version == 0 || version > SETTINGS_SCHEMA_VERSION {
        return Err(SettingsError::Document(format!(
            "settings version {version} is not supported"
        )));
    }
    let revision = document
        .get("revision")
        .and_then(Value::as_u64)
        .filter(|revision| *revision > 0)
        .unwrap_or(1);
    let keyboard = match document.get("keyboard") {
        Some(value) => serde_json::from_value::<KeyboardSettings>(value.clone())?,
        None => KeyboardSettings::default(),
    };
    keyboard.validate()?;
    let touchpad = match document.get("touchpad") {
        Some(value) => serde_json::from_value::<TouchpadSettings>(value.clone())?,
        None => TouchpadSettings::default(),
    };
    let migrated = version != SETTINGS_SCHEMA_VERSION
        || !document.contains_key("revision")
        || !document.contains_key("keyboard")
        || !document.contains_key("touchpad");
    document.insert("version".to_owned(), Value::from(SETTINGS_SCHEMA_VERSION));
    document.insert("revision".to_owned(), Value::from(revision));
    document.insert(
        "keyboard".to_owned(),
        serde_json::to_value(&keyboard).expect("validated keyboard settings serialize"),
    );
    document.insert(
        "touchpad".to_owned(),
        serde_json::to_value(&touchpad).expect("validated touchpad settings serialize"),
    );
    Ok(ParsedSettingsDocument {
        document,
        revision,
        keyboard,
        touchpad,
        migrated,
    })
}

fn default_document() -> (Map<String, Value>, u64, KeyboardSettings, TouchpadSettings) {
    let revision = 1;
    let keyboard = KeyboardSettings::default();
    let touchpad = TouchpadSettings::default();
    let mut document = Map::new();
    document.insert("version".to_owned(), Value::from(SETTINGS_SCHEMA_VERSION));
    document.insert("revision".to_owned(), Value::from(revision));
    document.insert(
        "keyboard".to_owned(),
        serde_json::to_value(&keyboard).expect("default keyboard settings serialize"),
    );
    document.insert(
        "touchpad".to_owned(),
        serde_json::to_value(&touchpad).expect("default touchpad settings serialize"),
    );
    (document, revision, keyboard, touchpad)
}

fn settings_path() -> Result<PathBuf, SettingsError> {
    let config_home = std::env::var_os("XDG_CONFIG_HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| {
            std::env::var_os("HOME")
                .filter(|value| !value.is_empty())
                .map(PathBuf::from)
                .filter(|path| path.is_absolute())
                .map(|home| home.join(".config"))
        })
        .ok_or_else(|| {
            SettingsError::Path(
                "cannot resolve settings path: XDG_CONFIG_HOME and HOME are unavailable".to_owned(),
            )
        })?;
    Ok(config_home.join("denial/settings.json"))
}

fn read_settings_file(path: &Path) -> Result<Option<Vec<u8>>, SettingsError> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(SettingsError::Path(format!(
            "refusing non-regular settings file {}",
            path.display()
        )));
    }
    if metadata.size() > MAX_SETTINGS_BYTES as u64 {
        return Err(SettingsError::Document(format!(
            "settings document exceeds {MAX_SETTINGS_BYTES} bytes"
        )));
    }
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(path)?;
    let mut bytes = Vec::with_capacity(metadata.size() as usize);
    file.take((MAX_SETTINGS_BYTES + 1) as u64)
        .read_to_end(&mut bytes)?;
    if bytes.len() > MAX_SETTINGS_BYTES {
        return Err(SettingsError::Document(format!(
            "settings document exceeds {MAX_SETTINGS_BYTES} bytes"
        )));
    }
    Ok(Some(bytes))
}

fn render_document(document: &Map<String, Value>) -> Result<Vec<u8>, SettingsError> {
    let mut bytes = serde_json::to_vec_pretty(document)?;
    bytes.push(b'\n');
    if bytes.len() > MAX_SETTINGS_BYTES {
        return Err(SettingsError::Document(format!(
            "settings document exceeds {MAX_SETTINGS_BYTES} bytes"
        )));
    }
    Ok(bytes)
}

fn write_temporary(target: &Path, bytes: &[u8]) -> Result<PathBuf, SettingsError> {
    let parent = target.parent().ok_or_else(|| {
        SettingsError::Path(format!("settings path {} has no parent", target.display()))
    })?;
    fs::create_dir_all(parent)?;
    // The settings include lock-screen and shell preferences. They are not
    // credentials, but there is no reason to expose them to other users.
    fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
    let file_name = target
        .file_name()
        .ok_or_else(|| SettingsError::Path("settings path has no file name".to_owned()))?;
    for _ in 0..64 {
        let sequence = SETTINGS_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let temporary = parent.join(format!(
            ".{}.{}.{}.tmp",
            file_name.to_string_lossy(),
            std::process::id(),
            sequence
        ));
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(&temporary)
        {
            Ok(mut file) => {
                if let Err(error) = file.write_all(bytes).and_then(|()| file.sync_all()) {
                    let _ = fs::remove_file(&temporary);
                    return Err(error.into());
                }
                return Ok(temporary);
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error.into()),
        }
    }
    Err(SettingsError::Path(
        "could not allocate a unique settings transaction file".to_owned(),
    ))
}

fn sync_parent(path: &Path) -> Result<(), SettingsError> {
    let parent = path.parent().ok_or_else(|| {
        SettingsError::Path(format!("settings path {} has no parent", path.display()))
    })?;
    File::open(parent)?.sync_all()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    struct TemporaryDirectory(PathBuf);

    impl TemporaryDirectory {
        fn new(label: &str) -> Self {
            let sequence = SETTINGS_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir()
                .join(format!("denial-{label}-{}-{sequence}", std::process::id()));
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
        assert!(document.get("keyboard").is_some());
        assert!(document.get("touchpad").is_some());
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
        let update = manager
            .prepare_shell_update(
                old_revision,
                r#"{"version":9,"revision":999,"keyboard":{"layouts":[]},"touchpad":{"tapToClickEnabled":false},"power":{"idleDpmsEnabled":false}}"#,
            )
            .unwrap();
        manager.commit(update).unwrap();
        assert_eq!(manager.keyboard(), &configured);
        assert_eq!(manager.revision(), old_revision + 1);
        assert!(matches!(
            manager.prepare_shell_update(old_revision, r#"{"version":9}"#),
            Err(SettingsError::Revision { .. })
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
    fn rejects_external_edits_before_commit() {
        let temporary = TemporaryDirectory::new("settings-conflict");
        let path = temporary.settings_path();
        let mut manager = SettingsManager::load_path(path.clone()).unwrap();
        let prepared = manager
            .prepare_shell_update(manager.revision(), r#"{"version":9}"#)
            .unwrap();
        fs::write(&path, b"{\"version\":9,\"revision\":77}\n").unwrap();
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
}
