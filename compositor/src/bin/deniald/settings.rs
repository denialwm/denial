//! Rust-owned persistent Denial settings.
//!
//! Flutter owns presentation and typed shell models, but it never opens this
//! file.  Every mutation is revision checked and committed by deniald through
//! an fsync/rename transaction so compositor and shell settings cannot race.

use std::collections::BTreeMap;
use std::error::Error;
use std::ffi::OsStr;
use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use smithay::input::keyboard::xkb;
use tracing::warn;

use denial_core::portal_protocol::{DesktopColorSchemePreference, DesktopThemeSnapshot};

use super::window_layout::WindowLayoutKind;

pub(super) const SETTINGS_SCHEMA_VERSION: u64 = 28;
pub(super) const MIN_WORKSPACE_COUNT: u8 = 2;
pub(super) const MAX_WORKSPACE_COUNT: u8 = 9;
pub(super) const DEFAULT_WORKSPACE_COUNT: u8 = 4;
const MAX_SETTINGS_BYTES: usize = 256 * 1024;
const MAX_APPLICATION_ENVIRONMENT_ENTRIES: usize = 256;
const MAX_APPLICATION_ENVIRONMENT_APPLICATIONS: usize = 256;
const MAX_DESKTOP_FILE_ID_BYTES: usize = 4096;
const MAX_APPLICATION_ENVIRONMENT_NAME_BYTES: usize = 256;
const MAX_APPLICATION_ENVIRONMENT_VALUE_BYTES: usize = 16 * 1024;
const MAX_KEYBOARD_LAYOUTS: usize = 8;
const MAX_KEYBOARD_OPTIONS: usize = 32;
const MAX_XKB_NAME_BYTES: usize = 64;
const MIN_REPEAT_DELAY_MS: u32 = 100;
const MAX_REPEAT_DELAY_MS: u32 = 5_000;
const MAX_REPEAT_RATE_HZ: u32 = 100;
const DEFAULT_REPEAT_DELAY_MS: u32 = 600;
const DEFAULT_REPEAT_RATE_HZ: u32 = 25;
pub(super) const MIN_TOUCHPAD_SCROLL_SPEED_FACTOR: f64 = 0.05;
pub(super) const MAX_TOUCHPAD_SCROLL_SPEED_FACTOR: f64 = 5.0;
const DEFAULT_TOUCHPAD_SCROLL_SPEED_FACTOR: f64 = 1.0;
pub(super) const MIN_TOUCHPAD_SCROLLING_LAYOUT_SWIPE_SPEED_FACTOR: f64 = 0.25;
pub(super) const MAX_TOUCHPAD_SCROLLING_LAYOUT_SWIPE_SPEED_FACTOR: f64 = 4.0;
const DEFAULT_TOUCHPAD_SCROLLING_LAYOUT_SWIPE_SPEED_FACTOR: f64 = 1.0;
pub(super) const MIN_SCROLLING_LAYOUT_WHEEL_SPEED: f64 = 0.25;
pub(super) const MAX_SCROLLING_LAYOUT_WHEEL_SPEED: f64 = 4.0;
const DEFAULT_SCROLLING_LAYOUT_WHEEL_SPEED: f64 = 1.0;
pub(super) const MIN_MOUSE_SPEED: f64 = -1.0;
pub(super) const MAX_MOUSE_SPEED: f64 = 1.0;
const DEFAULT_MOUSE_SPEED: f64 = 0.0;
const MIN_CURSOR_SIZE: u32 = 16;
pub(super) const DEFAULT_CURSOR_SIZE: u32 = 32;
const MAX_CURSOR_SIZE: u32 = 64;
static SETTINGS_TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);
// This is a backend policy, not a literal GTK_IM_MODULE value. GTK's Wayland
// backend chooses its built-in input context automatically; Denial publishes
// the X11 arm through XSettings so an Xwayland GTK client sees only `xim`.
#[cfg(any(test, feature = "xwayland"))]
const GTK_INPUT_METHOD_BACKEND_FALLBACK: &str = "wayland:xim";

#[cfg(any(test, feature = "xwayland"))]
pub(super) fn x11_gtk_input_method_backend_fallback() -> &'static str {
    GTK_INPUT_METHOD_BACKEND_FALLBACK
        .split_once(':')
        .map(|(_, x11_backend)| x11_backend)
        .expect("GTK input-method backend fallback must contain Wayland and X11 arms")
}

/// Environment overrides applied only to processes launched by Denial.
///
/// The default map applies to every direct launch. A map keyed by the standard
/// desktop-file ID is layered over it for launches originating from that
/// desktop entry. A string sets a variable (including to the empty string),
/// while `null` removes it from the child environment.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(super) struct ApplicationEnvironment {
    default_overrides: BTreeMap<String, Option<String>>,
    application_overrides: BTreeMap<String, BTreeMap<String, Option<String>>>,
}

impl ApplicationEnvironment {
    fn from_document(document: &Map<String, Value>) -> Result<Self, SettingsError> {
        let Some(value) = document.get("applicationEnvironment") else {
            return Ok(Self::default());
        };
        let object = value.as_object().ok_or_else(|| {
            SettingsError::Document("settings applicationEnvironment must be an object".to_owned())
        })?;
        // Schema 11 stored the default map directly. Accept it here so loading
        // the document performs a lossless migration to the nested schema.
        if object
            .values()
            .all(|value| value.is_string() || value.is_null())
        {
            return Ok(Self {
                default_overrides: parse_environment_overrides(value, "default")?,
                application_overrides: BTreeMap::new(),
            });
        }

        for key in object.keys() {
            if !matches!(key.as_str(), "default" | "applications") {
                return Err(SettingsError::Document(format!(
                    "unknown application environment field {key:?}"
                )));
            }
        }
        let default_overrides = object
            .get("default")
            .map(|value| parse_environment_overrides(value, "default"))
            .transpose()?
            .unwrap_or_default();
        let applications = match object.get("applications") {
            Some(value) => value.as_object().cloned().ok_or_else(|| {
                SettingsError::Document(
                    "settings applicationEnvironment.applications must be an object".to_owned(),
                )
            })?,
            None => Map::new(),
        };
        if applications.len() > MAX_APPLICATION_ENVIRONMENT_APPLICATIONS {
            return Err(SettingsError::Document(format!(
                "application environment contains more than {MAX_APPLICATION_ENVIRONMENT_APPLICATIONS} applications"
            )));
        }
        let mut application_overrides = BTreeMap::new();
        for (desktop_file_id, value) in &applications {
            validate_desktop_file_id(desktop_file_id)?;
            application_overrides.insert(
                desktop_file_id.clone(),
                parse_environment_overrides(value, desktop_file_id)?,
            );
        }
        Ok(Self {
            default_overrides,
            application_overrides,
        })
    }

    fn write_to_document(&self, document: &mut Map<String, Value>) {
        let mut environment = Map::new();
        environment.insert(
            "default".to_owned(),
            serde_json::to_value(&self.default_overrides)
                .expect("validated default application environment serializes"),
        );
        environment.insert(
            "applications".to_owned(),
            serde_json::to_value(&self.application_overrides)
                .expect("validated per-application environments serialize"),
        );
        document.insert(
            "applicationEnvironment".to_owned(),
            Value::Object(environment),
        );
    }

    pub(super) fn allows_discovered_xmodifiers(&self, desktop_file_id: Option<&str>) -> bool {
        self.override_for("XMODIFIERS", desktop_file_id).is_none()
            && std::env::var_os("XMODIFIERS").is_none()
    }

    pub(super) fn apply(
        &self,
        command: &mut Command,
        desktop_file_id: Option<&str>,
        discovered_xmodifiers: Option<&OsStr>,
    ) {
        let inherited_xmodifiers = std::env::var_os("XMODIFIERS");
        apply_environment_overrides(command, &self.default_overrides);
        if let Some(overrides) = desktop_file_id
            .and_then(|desktop_file_id| self.application_overrides.get(desktop_file_id))
        {
            apply_environment_overrides(command, overrides);
        }
        if self.override_for("XMODIFIERS", desktop_file_id).is_none()
            && inherited_xmodifiers.is_none()
            && let Some(discovered_xmodifiers) = discovered_xmodifiers
        {
            command.env("XMODIFIERS", discovered_xmodifiers);
        }
    }

    fn override_for(&self, name: &str, desktop_file_id: Option<&str>) -> Option<&Option<String>> {
        desktop_file_id
            .and_then(|desktop_file_id| self.application_overrides.get(desktop_file_id))
            .and_then(|overrides| overrides.get(name))
            .or_else(|| self.default_overrides.get(name))
    }
}

fn parse_environment_overrides(
    value: &Value,
    scope: &str,
) -> Result<BTreeMap<String, Option<String>>, SettingsError> {
    let object = value.as_object().ok_or_else(|| {
        SettingsError::Document(format!(
            "application environment scope {scope:?} must be an object"
        ))
    })?;
    if object.len() > MAX_APPLICATION_ENVIRONMENT_ENTRIES {
        return Err(SettingsError::Document(format!(
            "application environment scope {scope:?} contains more than {MAX_APPLICATION_ENVIRONMENT_ENTRIES} variables"
        )));
    }
    let mut overrides = BTreeMap::new();
    for (name, value) in object {
        validate_environment_name(name)?;
        let value = match value {
            Value::String(value) => {
                validate_environment_value(name, value)?;
                Some(value.clone())
            }
            Value::Null => None,
            _ => {
                return Err(SettingsError::Document(format!(
                    "application environment variable {name} must be a string or null"
                )));
            }
        };
        overrides.insert(name.clone(), value);
    }
    Ok(overrides)
}

fn apply_environment_overrides(
    command: &mut Command,
    overrides: &BTreeMap<String, Option<String>>,
) {
    for (name, value) in overrides {
        match value {
            Some(value) => {
                command.env(name, value);
            }
            None => {
                command.env_remove(name);
            }
        }
    }
}

pub(super) fn load_application_environment() -> Result<ApplicationEnvironment, SettingsError> {
    let path = settings_path()?;
    let Some(bytes) = read_settings_file(&path)? else {
        return Ok(ApplicationEnvironment::default());
    };
    Ok(parse_document(&bytes)?.application_environment)
}

pub(super) fn load_cursor_size() -> Result<u32, SettingsError> {
    let path = settings_path()?;
    let Some(bytes) = read_settings_file(&path)? else {
        return Ok(DEFAULT_CURSOR_SIZE);
    };
    let parsed = parse_document(&bytes)?;
    parse_cursor_size(&parsed.document)
}

fn validate_environment_name(name: &str) -> Result<(), SettingsError> {
    let mut bytes = name.bytes();
    let valid = bytes
        .next()
        .is_some_and(|byte| byte == b'_' || byte.is_ascii_alphabetic())
        && bytes.all(|byte| byte == b'_' || byte.is_ascii_alphanumeric());
    if !valid || name.len() > MAX_APPLICATION_ENVIRONMENT_NAME_BYTES {
        return Err(SettingsError::Document(format!(
            "invalid environment variable name {name:?}"
        )));
    }
    Ok(())
}

pub(super) fn validate_desktop_file_id(desktop_file_id: &str) -> Result<(), SettingsError> {
    if desktop_file_id.is_empty()
        || desktop_file_id.len() > MAX_DESKTOP_FILE_ID_BYTES
        || !desktop_file_id.ends_with(".desktop")
        || desktop_file_id.contains('/')
        || desktop_file_id.contains('\0')
    {
        return Err(SettingsError::Document(format!(
            "invalid desktop-file ID {desktop_file_id:?}"
        )));
    }
    Ok(())
}

fn validate_environment_value(name: &str, value: &str) -> Result<(), SettingsError> {
    if value.len() > MAX_APPLICATION_ENVIRONMENT_VALUE_BYTES {
        return Err(SettingsError::Document(format!(
            "environment variable {name} exceeds {MAX_APPLICATION_ENVIRONMENT_VALUE_BYTES} bytes"
        )));
    }
    if value.contains('\0') {
        return Err(SettingsError::Document(format!(
            "environment variable {name} contains NUL"
        )));
    }
    Ok(())
}

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

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct MouseSettings {
    pub(super) speed: f64,
}

impl Default for MouseSettings {
    fn default() -> Self {
        Self {
            speed: DEFAULT_MOUSE_SPEED,
        }
    }
}

impl MouseSettings {
    pub(super) fn validate(&self) -> Result<(), SettingsError> {
        if !self.speed.is_finite() || !(MIN_MOUSE_SPEED..=MAX_MOUSE_SPEED).contains(&self.speed) {
            return Err(SettingsError::Mouse(format!(
                "mouse speed must be within {MIN_MOUSE_SPEED}..={MAX_MOUSE_SPEED}"
            )));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct TouchpadSettings {
    pub(super) tap_to_click_enabled: bool,
    pub(super) natural_scroll_enabled: bool,
    pub(super) scroll_speed_factor: f64,
    pub(super) scrolling_layout_swipe_speed_factor: f64,
}

impl Default for TouchpadSettings {
    fn default() -> Self {
        Self {
            tap_to_click_enabled: true,
            natural_scroll_enabled: false,
            scroll_speed_factor: DEFAULT_TOUCHPAD_SCROLL_SPEED_FACTOR,
            scrolling_layout_swipe_speed_factor:
                DEFAULT_TOUCHPAD_SCROLLING_LAYOUT_SWIPE_SPEED_FACTOR,
        }
    }
}

impl TouchpadSettings {
    pub(super) fn validate(&self) -> Result<(), SettingsError> {
        if !self.scroll_speed_factor.is_finite()
            || !(MIN_TOUCHPAD_SCROLL_SPEED_FACTOR..=MAX_TOUCHPAD_SCROLL_SPEED_FACTOR)
                .contains(&self.scroll_speed_factor)
        {
            return Err(SettingsError::Touchpad(format!(
                "touchpad scroll speed factor must be within {MIN_TOUCHPAD_SCROLL_SPEED_FACTOR}..={MAX_TOUCHPAD_SCROLL_SPEED_FACTOR}"
            )));
        }
        if !self.scrolling_layout_swipe_speed_factor.is_finite()
            || !(MIN_TOUCHPAD_SCROLLING_LAYOUT_SWIPE_SPEED_FACTOR
                ..=MAX_TOUCHPAD_SCROLLING_LAYOUT_SWIPE_SPEED_FACTOR)
                .contains(&self.scrolling_layout_swipe_speed_factor)
        {
            return Err(SettingsError::Touchpad(format!(
                "touchpad scrolling-layout swipe speed factor must be within {MIN_TOUCHPAD_SCROLLING_LAYOUT_SWIPE_SPEED_FACTOR}..={MAX_TOUCHPAD_SCROLLING_LAYOUT_SWIPE_SPEED_FACTOR}"
            )));
        }
        Ok(())
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
    Mouse(String),
    Touchpad(String),
    Revision { expected: u64, actual: u64 },
    Conflict,
}

impl fmt::Display for SettingsError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Path(reason)
            | Self::Document(reason)
            | Self::Keyboard(reason)
            | Self::Mouse(reason)
            | Self::Touchpad(reason) => formatter.write_str(reason),
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
    mouse: MouseSettings,
    touchpad: TouchpadSettings,
    color_scheme_preference: DesktopColorSchemePreference,
    allow_client_cursor_surfaces: bool,
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
                        mouse: parsed.mouse,
                        touchpad: parsed.touchpad,
                        color_scheme_preference: parsed.color_scheme_preference,
                        allow_client_cursor_surfaces: parsed.allow_client_cursor_surfaces,
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

        let (
            document,
            revision,
            keyboard,
            mouse,
            touchpad,
            color_scheme_preference,
            allow_client_cursor_surfaces,
        ) = default_document();
        let mut manager = Self {
            path,
            document,
            revision,
            keyboard,
            mouse,
            touchpad,
            color_scheme_preference,
            allow_client_cursor_surfaces,
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

    pub(super) fn mouse(&self) -> &MouseSettings {
        &self.mouse
    }

    pub(super) fn touchpad(&self) -> &TouchpadSettings {
        &self.touchpad
    }

    pub(super) fn theme_snapshot(&self) -> DesktopThemeSnapshot {
        DesktopThemeSnapshot::new(self.revision, self.color_scheme_preference)
    }

    pub(super) fn allow_client_cursor_surfaces(&self) -> bool {
        self.allow_client_cursor_surfaces
    }

    pub(super) fn cursor_size(&self) -> u32 {
        parse_cursor_size(&self.document).unwrap_or(DEFAULT_CURSOR_SIZE)
    }

    pub(super) fn window_layout_kind(&self) -> WindowLayoutKind {
        // Authoritative documents are validated before load/commit. Keep the
        // fallback defensive for the safe in-memory defaults used after an
        // invalid file is deliberately left untouched.
        parse_window_layout_kind(&self.document).unwrap_or_default()
    }

    pub(super) fn scrolling_layout_wheel_settings(&self) -> ScrollingLayoutWheelSettings {
        parse_scrolling_layout_wheel_settings(&self.document).unwrap_or_default()
    }

    pub(super) fn workspace_settings(&self) -> WorkspaceSettings {
        parse_workspace_settings(&self.document).unwrap_or_default()
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
        incoming.remove("mouse");
        incoming.remove("touchpad");
        incoming.insert("version".to_owned(), Value::from(SETTINGS_SCHEMA_VERSION));
        incoming.insert("revision".to_owned(), Value::from(self.next_revision()?));
        incoming.insert(
            "keyboard".to_owned(),
            serde_json::to_value(&self.keyboard).expect("validated keyboard settings serialize"),
        );
        incoming.insert(
            "mouse".to_owned(),
            serde_json::to_value(&self.mouse).expect("validated mouse settings serialize"),
        );
        incoming.insert(
            "touchpad".to_owned(),
            serde_json::to_value(&self.touchpad).expect("validated touchpad settings serialize"),
        );
        let color_scheme_preference = parse_color_scheme_preference(&incoming)?;
        let allow_client_cursor_surfaces = parse_allow_client_cursor_surfaces(&incoming)?;
        parse_cursor_size(&incoming)?;
        parse_window_layout_kind(&incoming)?;
        parse_scrolling_layout_wheel_settings(&incoming)?;
        parse_workspace_settings(&incoming)?;
        self.prepare(
            incoming,
            self.keyboard.clone(),
            self.mouse.clone(),
            self.touchpad.clone(),
            color_scheme_preference,
            allow_client_cursor_surfaces,
        )
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
        self.prepare(
            document,
            keyboard,
            self.mouse.clone(),
            self.touchpad.clone(),
            self.color_scheme_preference,
            self.allow_client_cursor_surfaces,
        )
    }

    pub(super) fn prepare_touchpad_update(
        &self,
        expected_revision: u64,
        touchpad: TouchpadSettings,
    ) -> Result<PreparedSettingsUpdate, SettingsError> {
        self.check_revision(expected_revision)?;
        touchpad.validate()?;
        let mut document = self.document.clone();
        document.insert("revision".to_owned(), Value::from(self.next_revision()?));
        document.insert(
            "touchpad".to_owned(),
            serde_json::to_value(&touchpad).expect("validated touchpad settings serialize"),
        );
        self.prepare(
            document,
            self.keyboard.clone(),
            self.mouse.clone(),
            touchpad,
            self.color_scheme_preference,
            self.allow_client_cursor_surfaces,
        )
    }

    pub(super) fn prepare_mouse_update(
        &self,
        expected_revision: u64,
        mouse: MouseSettings,
    ) -> Result<PreparedSettingsUpdate, SettingsError> {
        self.check_revision(expected_revision)?;
        mouse.validate()?;
        let mut document = self.document.clone();
        document.insert("revision".to_owned(), Value::from(self.next_revision()?));
        document.insert(
            "mouse".to_owned(),
            serde_json::to_value(&mouse).expect("validated mouse settings serialize"),
        );
        self.prepare(
            document,
            self.keyboard.clone(),
            mouse,
            self.touchpad.clone(),
            self.color_scheme_preference,
            self.allow_client_cursor_surfaces,
        )
    }

    /// Builds a normal settings transaction from a document changed outside
    /// deniald. The revision stored in an editor's copy is deliberately
    /// ignored: revisions serialize live writers, so only the active manager
    /// may allocate the next one.
    ///
    /// Removing the document is treated as restoring defaults. Invalid files
    /// remain untouched and the caller keeps the last known-good live state.
    pub(super) fn prepare_external_reload(
        &self,
    ) -> Result<Option<PreparedSettingsUpdate>, SettingsError> {
        let observed = read_settings_file(&self.path)?;
        if observed == self.persisted_bytes {
            return Ok(None);
        }

        let (
            mut document,
            keyboard,
            mouse,
            touchpad,
            color_scheme_preference,
            allow_client_cursor_surfaces,
        ) = match observed.as_deref() {
            Some(bytes) => {
                let parsed = parse_document(bytes)?;
                (
                    parsed.document,
                    parsed.keyboard,
                    parsed.mouse,
                    parsed.touchpad,
                    parsed.color_scheme_preference,
                    parsed.allow_client_cursor_surfaces,
                )
            }
            None => {
                let (
                    document,
                    _,
                    keyboard,
                    mouse,
                    touchpad,
                    color_scheme_preference,
                    allow_client_cursor_surfaces,
                ) = default_document();
                (
                    document,
                    keyboard,
                    mouse,
                    touchpad,
                    color_scheme_preference,
                    allow_client_cursor_surfaces,
                )
            }
        };
        // Grammar validation is not enough for an external keymap edit. Do
        // the installed-XKB preflight before any live input state is changed.
        keyboard.compiled_layout_names()?;
        document.insert("version".to_owned(), Value::from(SETTINGS_SCHEMA_VERSION));
        document.insert("revision".to_owned(), Value::from(self.next_revision()?));
        self.prepare_against(
            document,
            keyboard,
            mouse,
            touchpad,
            color_scheme_preference,
            allow_client_cursor_surfaces,
            observed,
        )
        .map(Some)
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
        if read_settings_file(&self.path)? != prepared.expected_disk_bytes {
            return Err(SettingsError::Conflict);
        }
        fs::rename(&prepared.temporary, &self.path)?;
        prepared.committed = true;
        self.document = std::mem::take(&mut prepared.document);
        self.revision = prepared.revision;
        self.keyboard = std::mem::take(&mut prepared.keyboard);
        self.mouse = std::mem::take(&mut prepared.mouse);
        self.touchpad = std::mem::take(&mut prepared.touchpad);
        self.color_scheme_preference = prepared.color_scheme_preference;
        self.allow_client_cursor_surfaces = prepared.allow_client_cursor_surfaces;
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
        mouse: MouseSettings,
        touchpad: TouchpadSettings,
        color_scheme_preference: DesktopColorSchemePreference,
        allow_client_cursor_surfaces: bool,
    ) -> Result<PreparedSettingsUpdate, SettingsError> {
        self.prepare_against(
            document,
            keyboard,
            mouse,
            touchpad,
            color_scheme_preference,
            allow_client_cursor_surfaces,
            self.persisted_bytes.clone(),
        )
    }

    fn prepare_against(
        &self,
        mut document: Map<String, Value>,
        keyboard: KeyboardSettings,
        mouse: MouseSettings,
        touchpad: TouchpadSettings,
        color_scheme_preference: DesktopColorSchemePreference,
        allow_client_cursor_surfaces: bool,
        expected_disk_bytes: Option<Vec<u8>>,
    ) -> Result<PreparedSettingsUpdate, SettingsError> {
        let application_environment = ApplicationEnvironment::from_document(&document)?;
        application_environment.write_to_document(&mut document);
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
            mouse,
            touchpad,
            color_scheme_preference,
            allow_client_cursor_surfaces,
            bytes,
            expected_disk_bytes,
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
    mouse: MouseSettings,
    touchpad: TouchpadSettings,
    color_scheme_preference: DesktopColorSchemePreference,
    allow_client_cursor_surfaces: bool,
    bytes: Vec<u8>,
    expected_disk_bytes: Option<Vec<u8>>,
    committed: bool,
}

impl PreparedSettingsUpdate {
    pub(super) fn keyboard(&self) -> &KeyboardSettings {
        &self.keyboard
    }

    pub(super) fn mouse(&self) -> &MouseSettings {
        &self.mouse
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
    mouse: MouseSettings,
    touchpad: TouchpadSettings,
    color_scheme_preference: DesktopColorSchemePreference,
    allow_client_cursor_surfaces: bool,
    application_environment: ApplicationEnvironment,
    migrated: bool,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(super) enum ScrollingLayoutWheelUpDirection {
    #[default]
    Left,
    Right,
}

impl ScrollingLayoutWheelUpDirection {
    fn from_settings_name(value: &str) -> Option<Self> {
        match value {
            "left" => Some(Self::Left),
            "right" => Some(Self::Right),
            _ => None,
        }
    }

    fn settings_name(self) -> &'static str {
        match self {
            Self::Left => "left",
            Self::Right => "right",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) struct ScrollingLayoutWheelSettings {
    pub(super) speed: f64,
    pub(super) up_direction: ScrollingLayoutWheelUpDirection,
}

impl Default for ScrollingLayoutWheelSettings {
    fn default() -> Self {
        Self {
            speed: DEFAULT_SCROLLING_LAYOUT_WHEEL_SPEED,
            up_direction: ScrollingLayoutWheelUpDirection::Left,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct WorkspaceSettings {
    pub(super) enabled: bool,
    pub(super) count: u8,
    pub(super) switching_orientation: WorkspaceSwitchingOrientation,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(super) enum WorkspaceSwitchingOrientation {
    #[default]
    Horizontal,
    Vertical,
}

impl WorkspaceSwitchingOrientation {
    fn from_settings_name(value: &str) -> Option<Self> {
        match value {
            "horizontal" => Some(Self::Horizontal),
            "vertical" => Some(Self::Vertical),
            _ => None,
        }
    }

    fn settings_name(self) -> &'static str {
        match self {
            Self::Horizontal => "horizontal",
            Self::Vertical => "vertical",
        }
    }
}

impl Default for WorkspaceSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            count: DEFAULT_WORKSPACE_COUNT,
            switching_orientation: WorkspaceSwitchingOrientation::Horizontal,
        }
    }
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
    let mouse = match document.get("mouse") {
        Some(value) => serde_json::from_value::<MouseSettings>(value.clone())?,
        None => MouseSettings::default(),
    };
    mouse.validate()?;
    let touchpad = match document.get("touchpad") {
        Some(value) => serde_json::from_value::<TouchpadSettings>(value.clone())?,
        None => TouchpadSettings::default(),
    };
    touchpad.validate()?;
    let had_application_environment = document.contains_key("applicationEnvironment");
    let application_environment = ApplicationEnvironment::from_document(&document)?;
    application_environment.write_to_document(&mut document);
    let had_color_scheme_preference = document
        .get("appearance")
        .and_then(Value::as_object)
        .is_some_and(|appearance| appearance.contains_key("colorSchemePreference"));
    let color_scheme_preference = if had_color_scheme_preference {
        parse_color_scheme_preference(&document)?
    } else {
        DesktopColorSchemePreference::PreferDark
    };
    set_color_scheme_preference(&mut document, color_scheme_preference)?;
    let had_allow_client_cursor_surfaces = document
        .get("appearance")
        .and_then(Value::as_object)
        .is_some_and(|appearance| appearance.contains_key("allowClientCursorSurfaces"));
    let allow_client_cursor_surfaces = if had_allow_client_cursor_surfaces {
        parse_allow_client_cursor_surfaces(&document)?
    } else {
        true
    };
    set_allow_client_cursor_surfaces(&mut document, allow_client_cursor_surfaces)?;
    let had_cursor_size = document
        .get("appearance")
        .and_then(Value::as_object)
        .is_some_and(|appearance| appearance.contains_key("cursorSize"));
    let cursor_size = if had_cursor_size {
        parse_cursor_size(&document)?
    } else {
        DEFAULT_CURSOR_SIZE
    };
    set_cursor_size(&mut document, cursor_size)?;
    let had_window_layout = document
        .get("layout")
        .and_then(Value::as_object)
        .is_some_and(|layout| layout.contains_key("windowLayout"));
    let window_layout = if had_window_layout {
        parse_window_layout_kind(&document)?
    } else {
        WindowLayoutKind::Stacking
    };
    set_window_layout_kind(&mut document, window_layout)?;
    let had_scrolling_layout_wheel_settings = document
        .get("layout")
        .and_then(Value::as_object)
        .is_some_and(|layout| {
            layout.contains_key("scrollingLayoutWheelSpeed")
                && layout.contains_key("scrollingLayoutWheelUpDirection")
        });
    let scrolling_layout_wheel_settings = if had_scrolling_layout_wheel_settings {
        parse_scrolling_layout_wheel_settings(&document)?
    } else {
        ScrollingLayoutWheelSettings::default()
    };
    set_scrolling_layout_wheel_settings(&mut document, scrolling_layout_wheel_settings)?;
    let had_workspace_settings = document
        .get("layout")
        .and_then(Value::as_object)
        .is_some_and(|layout| {
            layout.contains_key("workspacesEnabled")
                && layout.contains_key("workspaceCount")
                && layout.contains_key("workspaceSwitchingOrientation")
        });
    let workspace_settings = if had_workspace_settings {
        parse_workspace_settings(&document)?
    } else {
        WorkspaceSettings::default()
    };
    set_workspace_settings(&mut document, workspace_settings)?;
    let migrated = version != SETTINGS_SCHEMA_VERSION
        || !document.contains_key("revision")
        || !document.contains_key("keyboard")
        || !document.contains_key("mouse")
        || !document.contains_key("touchpad")
        || !had_application_environment
        || !had_color_scheme_preference
        || !had_allow_client_cursor_surfaces
        || !had_cursor_size
        || !had_window_layout
        || !had_scrolling_layout_wheel_settings
        || !had_workspace_settings;
    document.insert("version".to_owned(), Value::from(SETTINGS_SCHEMA_VERSION));
    document.insert("revision".to_owned(), Value::from(revision));
    document.insert(
        "keyboard".to_owned(),
        serde_json::to_value(&keyboard).expect("validated keyboard settings serialize"),
    );
    document.insert(
        "mouse".to_owned(),
        serde_json::to_value(&mouse).expect("validated mouse settings serialize"),
    );
    document.insert(
        "touchpad".to_owned(),
        serde_json::to_value(&touchpad).expect("validated touchpad settings serialize"),
    );
    Ok(ParsedSettingsDocument {
        document,
        revision,
        keyboard,
        mouse,
        touchpad,
        color_scheme_preference,
        allow_client_cursor_surfaces,
        application_environment,
        migrated,
    })
}

fn default_document() -> (
    Map<String, Value>,
    u64,
    KeyboardSettings,
    MouseSettings,
    TouchpadSettings,
    DesktopColorSchemePreference,
    bool,
) {
    let revision = 1;
    let keyboard = KeyboardSettings::default();
    let mouse = MouseSettings::default();
    let touchpad = TouchpadSettings::default();
    let color_scheme_preference = DesktopColorSchemePreference::PreferDark;
    let allow_client_cursor_surfaces = true;
    let mut document = Map::new();
    document.insert("version".to_owned(), Value::from(SETTINGS_SCHEMA_VERSION));
    document.insert("revision".to_owned(), Value::from(revision));
    document.insert(
        "keyboard".to_owned(),
        serde_json::to_value(&keyboard).expect("default keyboard settings serialize"),
    );
    document.insert(
        "mouse".to_owned(),
        serde_json::to_value(&mouse).expect("default mouse settings serialize"),
    );
    document.insert(
        "touchpad".to_owned(),
        serde_json::to_value(&touchpad).expect("default touchpad settings serialize"),
    );
    ApplicationEnvironment::default().write_to_document(&mut document);
    set_color_scheme_preference(&mut document, color_scheme_preference)
        .expect("default appearance settings serialize");
    set_allow_client_cursor_surfaces(&mut document, allow_client_cursor_surfaces)
        .expect("default cursor surface setting serializes");
    set_cursor_size(&mut document, DEFAULT_CURSOR_SIZE).expect("default cursor size serializes");
    set_window_layout_kind(&mut document, WindowLayoutKind::Stacking)
        .expect("default window layout setting serializes");
    set_scrolling_layout_wheel_settings(&mut document, ScrollingLayoutWheelSettings::default())
        .expect("default scrolling-layout wheel settings serialize");
    set_workspace_settings(&mut document, WorkspaceSettings::default())
        .expect("default workspace settings serialize");
    // Seed only new documents; existing automatic panel placement stays intact.
    document
        .get_mut("layout")
        .and_then(Value::as_object_mut)
        .expect("default layout is an object")
        .insert("systemBarSide".to_owned(), Value::String("top".to_owned()));
    (
        document,
        revision,
        keyboard,
        mouse,
        touchpad,
        color_scheme_preference,
        allow_client_cursor_surfaces,
    )
}

fn parse_color_scheme_preference(
    document: &Map<String, Value>,
) -> Result<DesktopColorSchemePreference, SettingsError> {
    let value = document
        .get("appearance")
        .and_then(Value::as_object)
        .and_then(|appearance| appearance.get("colorSchemePreference"))
        .and_then(Value::as_str)
        .ok_or_else(|| {
            SettingsError::Document(
                "appearance.colorSchemePreference is missing or is not a string".to_owned(),
            )
        })?;
    DesktopColorSchemePreference::from_settings_name(value).ok_or_else(|| {
        SettingsError::Document(format!(
            "unsupported appearance.colorSchemePreference {value:?}"
        ))
    })
}

fn set_color_scheme_preference(
    document: &mut Map<String, Value>,
    preference: DesktopColorSchemePreference,
) -> Result<(), SettingsError> {
    if !document.contains_key("appearance") {
        document.insert("appearance".to_owned(), Value::Object(Map::new()));
    }
    let appearance = document
        .get_mut("appearance")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| {
            SettingsError::Document("settings appearance must be an object".to_owned())
        })?;
    appearance.insert(
        "colorSchemePreference".to_owned(),
        Value::String(preference.settings_name().to_owned()),
    );
    Ok(())
}

fn parse_allow_client_cursor_surfaces(
    document: &Map<String, Value>,
) -> Result<bool, SettingsError> {
    document
        .get("appearance")
        .and_then(Value::as_object)
        .and_then(|appearance| appearance.get("allowClientCursorSurfaces"))
        .and_then(Value::as_bool)
        .ok_or_else(|| {
            SettingsError::Document(
                "appearance.allowClientCursorSurfaces is missing or is not a boolean".to_owned(),
            )
        })
}

fn set_allow_client_cursor_surfaces(
    document: &mut Map<String, Value>,
    allowed: bool,
) -> Result<(), SettingsError> {
    if !document.contains_key("appearance") {
        document.insert("appearance".to_owned(), Value::Object(Map::new()));
    }
    let appearance = document
        .get_mut("appearance")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| {
            SettingsError::Document("settings appearance must be an object".to_owned())
        })?;
    appearance.insert("allowClientCursorSurfaces".to_owned(), Value::Bool(allowed));
    Ok(())
}

fn parse_cursor_size(document: &Map<String, Value>) -> Result<u32, SettingsError> {
    let value = document
        .get("appearance")
        .and_then(Value::as_object)
        .and_then(|appearance| appearance.get("cursorSize"))
        .and_then(Value::as_f64)
        .filter(|value| value.is_finite())
        .ok_or_else(|| {
            SettingsError::Document(
                "appearance.cursorSize is missing or is not a finite number".to_owned(),
            )
        })?;
    if !(f64::from(MIN_CURSOR_SIZE)..=f64::from(MAX_CURSOR_SIZE)).contains(&value) {
        return Err(SettingsError::Document(format!(
            "appearance.cursorSize must be between {MIN_CURSOR_SIZE} and {MAX_CURSOR_SIZE}"
        )));
    }
    Ok(value.round() as u32)
}

fn set_cursor_size(
    document: &mut Map<String, Value>,
    cursor_size: u32,
) -> Result<(), SettingsError> {
    if !document.contains_key("appearance") {
        document.insert("appearance".to_owned(), Value::Object(Map::new()));
    }
    let appearance = document
        .get_mut("appearance")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| {
            SettingsError::Document("settings appearance must be an object".to_owned())
        })?;
    appearance.insert("cursorSize".to_owned(), Value::from(cursor_size));
    Ok(())
}

fn parse_window_layout_kind(
    document: &Map<String, Value>,
) -> Result<WindowLayoutKind, SettingsError> {
    let value = document
        .get("layout")
        .and_then(Value::as_object)
        .and_then(|layout| layout.get("windowLayout"))
        .and_then(Value::as_str)
        .ok_or_else(|| {
            SettingsError::Document("layout.windowLayout is missing or is not a string".to_owned())
        })?;
    WindowLayoutKind::from_settings_name(value).ok_or_else(|| {
        SettingsError::Document(format!("unsupported layout.windowLayout {value:?}"))
    })
}

fn set_window_layout_kind(
    document: &mut Map<String, Value>,
    kind: WindowLayoutKind,
) -> Result<(), SettingsError> {
    if !document.contains_key("layout") {
        document.insert("layout".to_owned(), Value::Object(Map::new()));
    }
    let layout = document
        .get_mut("layout")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| SettingsError::Document("settings layout must be an object".to_owned()))?;
    layout.insert(
        "windowLayout".to_owned(),
        Value::String(kind.settings_name().to_owned()),
    );
    Ok(())
}

fn parse_scrolling_layout_wheel_settings(
    document: &Map<String, Value>,
) -> Result<ScrollingLayoutWheelSettings, SettingsError> {
    let layout = document
        .get("layout")
        .and_then(Value::as_object)
        .ok_or_else(|| SettingsError::Document("settings layout must be an object".to_owned()))?;
    let speed = layout
        .get("scrollingLayoutWheelSpeed")
        .and_then(Value::as_f64)
        .filter(|speed| {
            speed.is_finite()
                && (MIN_SCROLLING_LAYOUT_WHEEL_SPEED..=MAX_SCROLLING_LAYOUT_WHEEL_SPEED)
                    .contains(speed)
        })
        .ok_or_else(|| {
            SettingsError::Document(format!(
                "layout.scrollingLayoutWheelSpeed must be within {MIN_SCROLLING_LAYOUT_WHEEL_SPEED}..={MAX_SCROLLING_LAYOUT_WHEEL_SPEED}"
            ))
        })?;
    let up_direction = layout
        .get("scrollingLayoutWheelUpDirection")
        .and_then(Value::as_str)
        .and_then(ScrollingLayoutWheelUpDirection::from_settings_name)
        .ok_or_else(|| {
            SettingsError::Document(
                "layout.scrollingLayoutWheelUpDirection must be left or right".to_owned(),
            )
        })?;
    Ok(ScrollingLayoutWheelSettings {
        speed,
        up_direction,
    })
}

fn set_scrolling_layout_wheel_settings(
    document: &mut Map<String, Value>,
    settings: ScrollingLayoutWheelSettings,
) -> Result<(), SettingsError> {
    if !document.contains_key("layout") {
        document.insert("layout".to_owned(), Value::Object(Map::new()));
    }
    let layout = document
        .get_mut("layout")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| SettingsError::Document("settings layout must be an object".to_owned()))?;
    layout.insert(
        "scrollingLayoutWheelSpeed".to_owned(),
        Value::from(settings.speed),
    );
    layout.insert(
        "scrollingLayoutWheelUpDirection".to_owned(),
        Value::String(settings.up_direction.settings_name().to_owned()),
    );
    Ok(())
}

fn parse_workspace_settings(
    document: &Map<String, Value>,
) -> Result<WorkspaceSettings, SettingsError> {
    let layout = document
        .get("layout")
        .and_then(Value::as_object)
        .ok_or_else(|| SettingsError::Document("settings layout must be an object".to_owned()))?;
    let enabled = layout
        .get("workspacesEnabled")
        .and_then(Value::as_bool)
        .ok_or_else(|| {
            SettingsError::Document(
                "layout.workspacesEnabled is missing or is not a boolean".to_owned(),
            )
        })?;
    let count = layout
        .get("workspaceCount")
        .and_then(Value::as_u64)
        .and_then(|value| u8::try_from(value).ok())
        .filter(|value| (MIN_WORKSPACE_COUNT..=MAX_WORKSPACE_COUNT).contains(value))
        .ok_or_else(|| {
            SettingsError::Document(format!(
                "layout.workspaceCount must be within {MIN_WORKSPACE_COUNT}..={MAX_WORKSPACE_COUNT}"
            ))
        })?;
    let switching_orientation = layout
        .get("workspaceSwitchingOrientation")
        .and_then(Value::as_str)
        .and_then(WorkspaceSwitchingOrientation::from_settings_name)
        .ok_or_else(|| {
            SettingsError::Document(
                "layout.workspaceSwitchingOrientation must be horizontal or vertical".to_owned(),
            )
        })?;
    Ok(WorkspaceSettings {
        enabled,
        count,
        switching_orientation,
    })
}

fn set_workspace_settings(
    document: &mut Map<String, Value>,
    workspaces: WorkspaceSettings,
) -> Result<(), SettingsError> {
    if !document.contains_key("layout") {
        document.insert("layout".to_owned(), Value::Object(Map::new()));
    }
    let layout = document
        .get_mut("layout")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| SettingsError::Document("settings layout must be an object".to_owned()))?;
    layout.insert(
        "workspacesEnabled".to_owned(),
        Value::Bool(workspaces.enabled),
    );
    layout.insert("workspaceCount".to_owned(), Value::from(workspaces.count));
    layout.insert(
        "workspaceSwitchingOrientation".to_owned(),
        Value::String(workspaces.switching_orientation.settings_name().to_owned()),
    );
    Ok(())
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
#[path = "settings/tests.rs"]
mod tests;
