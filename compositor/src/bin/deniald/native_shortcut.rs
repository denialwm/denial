//! Native compositor shortcuts evaluated before any shell or client routing.

use std::collections::{HashMap, HashSet};
use std::error::Error;
use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use tracing::warn;

const SHORTCUT_SCHEMA_VERSION: u64 = 1;
const MAX_SHORTCUT_FILE_BYTES: usize = 128 * 1024;
pub(super) const MAX_SHORTCUTS: usize = 256;
const MAX_SHORTCUT_EXPRESSION_BYTES: usize = 128;
pub(super) const MAX_SPAWN_ARGUMENTS: usize = 64;
const MAX_SPAWN_ARGUMENT_BYTES: usize = 4096;
const MAX_SHELL_COMMAND_BYTES: usize = 4096;
static SHORTCUT_TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

const KEY_ESCAPE: u32 = 1;
const KEY_BACKSPACE: u32 = 14;
const KEY_TAB: u32 = 15;
#[cfg(test)]
const KEY_A: u32 = 30;
#[cfg(test)]
const KEY_S: u32 = 31;
#[cfg(test)]
const KEY_F: u32 = 33;
#[cfg(test)]
const KEY_K: u32 = 37;
#[cfg(test)]
const KEY_L: u32 = 38;
#[cfg(test)]
const KEY_V: u32 = 47;
#[cfg(test)]
const KEY_M: u32 = 50;
const KEY_SPACE: u32 = 57;
const KEY_UP: u32 = 103;
const KEY_MUTE: u32 = 113;
const KEY_VOLUME_DOWN: u32 = 114;
const KEY_VOLUME_UP: u32 = 115;
const KEY_BRIGHTNESS_DOWN: u32 = 224;
const KEY_BRIGHTNESS_UP: u32 = 225;
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

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
enum Modifier {
    Super,
    Ctrl,
    Alt,
    Shift,
}

impl Modifier {
    const fn flag(self) -> u8 {
        match self {
            Self::Super => 1 << 0,
            Self::Ctrl => 1 << 1,
            Self::Alt => 1 << 2,
            Self::Shift => 1 << 3,
        }
    }

    const fn canonical_name(self) -> &'static str {
        match self {
            Self::Super => "Super",
            Self::Ctrl => "Ctrl",
            Self::Alt => "Alt",
            Self::Shift => "Shift",
        }
    }
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
enum TriggerKey {
    Evdev(u32),
    ModifierTap(Modifier),
    Gesture(ShortcutGesture),
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct ShortcutTrigger {
    modifiers: u8,
    key: TriggerKey,
    canonical: String,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(super) enum ShortcutGesture {
    ThreeFingerSwipeUp,
}

impl ShortcutGesture {
    const fn canonical_name(self) -> &'static str {
        match self {
            Self::ThreeFingerSwipeUp => "ThreeFingerSwipeUp",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) enum ShortcutAction {
    Shutdown,
    OpenApplications,
    OpenOverview,
    ToggleVerticalMaximize,
    WindowSwitcher,
    OpenClipboard,
    CaptureRegion,
    CloseWindow,
    MinimizeWindow,
    ToggleMaximize,
    ToggleFullscreen,
    ReleasePointer,
    LockScreen,
    VolumeUp,
    VolumeDown,
    VolumeMute,
    BrightnessUp,
    BrightnessDown,
    NextKeyboardLayout,
    PreviousKeyboardLayout,
}

impl ShortcutAction {
    pub(super) const ALL: [Self; 20] = [
        Self::OpenApplications,
        Self::OpenOverview,
        Self::WindowSwitcher,
        Self::OpenClipboard,
        Self::CaptureRegion,
        Self::CloseWindow,
        Self::MinimizeWindow,
        Self::ToggleVerticalMaximize,
        Self::ToggleMaximize,
        Self::ToggleFullscreen,
        Self::ReleasePointer,
        Self::LockScreen,
        Self::Shutdown,
        Self::VolumeUp,
        Self::VolumeDown,
        Self::VolumeMute,
        Self::BrightnessUp,
        Self::BrightnessDown,
        Self::NextKeyboardLayout,
        Self::PreviousKeyboardLayout,
    ];
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum ShortcutInputKind {
    Key,
    Gesture,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum ShortcutInputCategory {
    Modifier,
    Navigation,
    Editing,
    Punctuation,
    Function,
    Media,
    Hardware,
    Special,
    Gesture,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct ShortcutInputDefinition {
    pub(super) canonical: String,
    pub(super) kind: ShortcutInputKind,
    pub(super) category: ShortcutInputCategory,
    pub(super) aliases: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) enum ShortcutValidation {
    Valid {
        canonical: String,
    },
    Conflict {
        canonical: String,
        binding: ShortcutBinding,
    },
    Invalid {
        error: String,
    },
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase", deny_unknown_fields)]
pub(super) enum ShortcutTarget {
    DenialAction { action: ShortcutAction },
    Spawn { command: Vec<String> },
    SpawnSh { command: String },
}

impl ShortcutTarget {
    fn validate(&self) -> Result<(), ShortcutError> {
        match self {
            Self::DenialAction { .. } => Ok(()),
            Self::Spawn { command } => validate_spawn(command),
            Self::SpawnSh { command } => validate_spawn_sh(command),
        }
    }

    fn repeats(&self) -> bool {
        matches!(
            self,
            Self::DenialAction {
                action: ShortcutAction::VolumeUp
                    | ShortcutAction::VolumeDown
                    | ShortcutAction::BrightnessUp
                    | ShortcutAction::BrightnessDown,
            }
        )
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct ShortcutBinding {
    pub(super) shortcut: String,
    pub(super) target: ShortcutTarget,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct ShortcutFile {
    pub(super) version: u64,
    pub(super) revision: u64,
    pub(super) shortcuts: Vec<ShortcutBinding>,
}

#[derive(Clone, Debug)]
struct CompiledShortcut {
    trigger: ShortcutTrigger,
    target: ShortcutTarget,
}

#[derive(Debug)]
pub(super) enum ShortcutError {
    Path(String),
    Io(std::io::Error),
    Json(serde_json::Error),
    Document(String),
    Revision { expected: u64, actual: u64 },
    Changed,
    Missing(String),
}

impl fmt::Display for ShortcutError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Path(reason) | Self::Document(reason) | Self::Missing(reason) => {
                formatter.write_str(reason)
            }
            Self::Io(error) => write!(formatter, "shortcut file I/O failed: {error}"),
            Self::Json(error) => write!(formatter, "shortcut file JSON is invalid: {error}"),
            Self::Revision { expected, actual } => write!(
                formatter,
                "shortcut revision conflict: expected {expected}, current revision is {actual}"
            ),
            Self::Changed => formatter.write_str(
                "shortcut file changed outside Denial; restart Denial before saving again",
            ),
        }
    }
}

impl Error for ShortcutError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Io(error) => Some(error),
            Self::Json(error) => Some(error),
            Self::Path(_)
            | Self::Document(_)
            | Self::Revision { .. }
            | Self::Changed
            | Self::Missing(_) => None,
        }
    }
}

impl From<std::io::Error> for ShortcutError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<serde_json::Error> for ShortcutError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}

pub(super) struct ShortcutManager {
    path: PathBuf,
    file: ShortcutFile,
    persisted_bytes: Vec<u8>,
}

impl ShortcutManager {
    pub(super) fn load() -> Result<Self, ShortcutError> {
        Self::load_path(shortcut_path()?)
    }

    fn load_path(path: PathBuf) -> Result<Self, ShortcutError> {
        match fs::symlink_metadata(&path) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                write_default_file(&path)?;
            }
            Err(error) => return Err(error.into()),
            Ok(_) => {
                if let Err(error) = read_and_parse(&path) {
                    let moved_to = move_invalid_file_aside(&path)?;
                    warn!(
                        %error,
                        path = %path.display(),
                        moved_to = %moved_to.display(),
                        "moved invalid shortcut file aside and restored Denial defaults"
                    );
                    write_default_file(&path)?;
                }
            }
        }

        let (file, bytes) = read_and_parse(&path)?;
        Ok(Self {
            path,
            file,
            persisted_bytes: bytes,
        })
    }

    pub(super) fn revision(&self) -> u64 {
        self.file.revision
    }

    pub(super) fn file(&self) -> &ShortcutFile {
        &self.file
    }

    pub(super) fn engine(&self) -> ShortcutEngine {
        ShortcutEngine::from_file(&self.file)
            .expect("loaded shortcut file was validated before engine construction")
    }

    pub(super) fn validate_shortcut(
        &self,
        binding: &ShortcutBinding,
        existing_shortcut: Option<&str>,
    ) -> ShortcutValidation {
        if let Err(error) = binding.target.validate() {
            return ShortcutValidation::Invalid {
                error: error.to_string(),
            };
        }
        let trigger = match parse_shortcut(&binding.shortcut) {
            Ok(trigger) => trigger,
            Err(error) => {
                return ShortcutValidation::Invalid {
                    error: error.to_string(),
                };
            }
        };
        let existing = existing_shortcut
            .and_then(|shortcut| parse_shortcut(shortcut).ok())
            .map(|trigger| trigger.canonical);
        let conflict = self.file.shortcuts.iter().find(|binding| {
            let Ok(configured) = parse_shortcut(&binding.shortcut) else {
                return false;
            };
            configured == trigger && existing.as_deref() != Some(configured.canonical.as_str())
        });
        match conflict {
            Some(binding) => ShortcutValidation::Conflict {
                canonical: trigger.canonical,
                binding: binding.clone(),
            },
            None => ShortcutValidation::Valid {
                canonical: trigger.canonical,
            },
        }
    }

    pub(super) fn prepare_add(
        &self,
        expected_revision: u64,
        binding: ShortcutBinding,
    ) -> Result<PreparedShortcutUpdate, ShortcutError> {
        self.check_revision(expected_revision)?;
        let binding = canonical_binding(binding)?;
        let mut file = self.file.clone();
        file.shortcuts.push(binding);
        self.prepare(file)
    }

    pub(super) fn prepare_update(
        &self,
        expected_revision: u64,
        existing_shortcut: &str,
        binding: ShortcutBinding,
    ) -> Result<PreparedShortcutUpdate, ShortcutError> {
        self.check_revision(expected_revision)?;
        let existing = parse_shortcut(existing_shortcut)?.canonical;
        let binding = canonical_binding(binding)?;
        let mut file = self.file.clone();
        let index = file
            .shortcuts
            .iter()
            .position(|configured| configured.shortcut == existing)
            .ok_or_else(|| {
                ShortcutError::Missing(format!("shortcut {existing:?} does not exist"))
            })?;
        file.shortcuts[index] = binding;
        self.prepare(file)
    }

    pub(super) fn prepare_remove(
        &self,
        expected_revision: u64,
        shortcut: &str,
    ) -> Result<PreparedShortcutUpdate, ShortcutError> {
        self.check_revision(expected_revision)?;
        let canonical = parse_shortcut(shortcut)?.canonical;
        let mut file = self.file.clone();
        let index = file
            .shortcuts
            .iter()
            .position(|binding| binding.shortcut == canonical)
            .ok_or_else(|| {
                ShortcutError::Missing(format!("shortcut {canonical:?} does not exist"))
            })?;
        file.shortcuts.remove(index);
        self.prepare(file)
    }

    pub(super) fn prepare_restore(
        &self,
        expected_revision: u64,
    ) -> Result<PreparedShortcutUpdate, ShortcutError> {
        self.check_revision(expected_revision)?;
        self.prepare(default_shortcut_file())
    }

    pub(super) fn commit(
        &mut self,
        mut prepared: PreparedShortcutUpdate,
    ) -> Result<(), ShortcutError> {
        if prepared.target != self.path {
            return Err(ShortcutError::Path(
                "prepared shortcut target does not match the active store".to_owned(),
            ));
        }
        if read_shortcut_bytes(&self.path)? != self.persisted_bytes {
            return Err(ShortcutError::Changed);
        }
        fs::rename(&prepared.temporary, &self.path)?;
        prepared.committed = true;
        self.file = std::mem::replace(&mut prepared.file, empty_shortcut_file());
        self.persisted_bytes = std::mem::take(&mut prepared.bytes);
        if let Err(error) = sync_parent(&self.path) {
            warn!(%error, path = %self.path.display(), "shortcuts were committed but directory fsync failed");
        }
        Ok(())
    }

    fn check_revision(&self, expected: u64) -> Result<(), ShortcutError> {
        if expected != self.file.revision {
            return Err(ShortcutError::Revision {
                expected,
                actual: self.file.revision,
            });
        }
        Ok(())
    }

    fn prepare(&self, mut file: ShortcutFile) -> Result<PreparedShortcutUpdate, ShortcutError> {
        file.version = SHORTCUT_SCHEMA_VERSION;
        file.revision = self
            .file
            .revision
            .checked_add(1)
            .ok_or_else(|| ShortcutError::Document("shortcut revision exhausted".to_owned()))?;
        normalize_and_compile_shortcuts(&mut file)?;
        let bytes = render_shortcut_file(&file)?;
        let temporary = write_temporary(&self.path, &bytes)?;
        let engine = ShortcutEngine::from_file(&file)?;
        Ok(PreparedShortcutUpdate {
            target: self.path.clone(),
            temporary,
            file,
            bytes,
            engine: Some(engine),
            committed: false,
        })
    }
}

pub(super) struct PreparedShortcutUpdate {
    target: PathBuf,
    temporary: PathBuf,
    file: ShortcutFile,
    bytes: Vec<u8>,
    engine: Option<ShortcutEngine>,
    committed: bool,
}

impl PreparedShortcutUpdate {
    pub(super) fn take_engine(&mut self) -> ShortcutEngine {
        self.engine
            .take()
            .expect("prepared shortcut engine was already installed")
    }
}

impl Drop for PreparedShortcutUpdate {
    fn drop(&mut self) {
        if !self.committed {
            let _ = fs::remove_file(&self.temporary);
        }
    }
}

fn empty_shortcut_file() -> ShortcutFile {
    ShortcutFile {
        version: SHORTCUT_SCHEMA_VERSION,
        revision: 1,
        shortcuts: Vec::new(),
    }
}

fn canonical_binding(binding: ShortcutBinding) -> Result<ShortcutBinding, ShortcutError> {
    binding.target.validate()?;
    Ok(ShortcutBinding {
        shortcut: parse_shortcut(&binding.shortcut)?.canonical,
        target: binding.target,
    })
}

fn validate_spawn(arguments: &[String]) -> Result<(), ShortcutError> {
    if arguments.is_empty() || arguments.len() > MAX_SPAWN_ARGUMENTS {
        return Err(ShortcutError::Document(format!(
            "spawn must contain between 1 and {MAX_SPAWN_ARGUMENTS} arguments"
        )));
    }
    for (index, argument) in arguments.iter().enumerate() {
        if argument.len() > MAX_SPAWN_ARGUMENT_BYTES || argument.contains('\0') {
            return Err(ShortcutError::Document(format!(
                "spawn argument {index} must contain at most {MAX_SPAWN_ARGUMENT_BYTES} bytes and no NUL character"
            )));
        }
    }
    if arguments[0].is_empty() {
        return Err(ShortcutError::Document(
            "spawn program must not be empty".to_owned(),
        ));
    }
    Ok(())
}

fn validate_spawn_sh(command: &str) -> Result<(), ShortcutError> {
    if command.is_empty() || command.len() > MAX_SHELL_COMMAND_BYTES || command.contains('\0') {
        return Err(ShortcutError::Document(format!(
            "spawnSh command must contain between 1 and {MAX_SHELL_COMMAND_BYTES} bytes and no NUL character"
        )));
    }
    Ok(())
}

fn read_and_parse(path: &Path) -> Result<(ShortcutFile, Vec<u8>), ShortcutError> {
    let bytes = read_shortcut_bytes(path)?;
    let mut file = serde_json::from_slice::<ShortcutFile>(&bytes)?;
    normalize_and_compile_shortcuts(&mut file)?;
    Ok((file, bytes))
}

fn read_shortcut_bytes(path: &Path) -> Result<Vec<u8>, ShortcutError> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(ShortcutError::Path(format!(
            "shortcut path {} is not a regular file",
            path.display()
        )));
    }
    if metadata.size() > MAX_SHORTCUT_FILE_BYTES as u64 {
        return Err(ShortcutError::Document(format!(
            "shortcut file exceeds {MAX_SHORTCUT_FILE_BYTES} bytes"
        )));
    }
    let mut bytes = Vec::with_capacity(metadata.size() as usize);
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(path)?
        .take((MAX_SHORTCUT_FILE_BYTES + 1) as u64)
        .read_to_end(&mut bytes)?;
    if bytes.len() > MAX_SHORTCUT_FILE_BYTES {
        return Err(ShortcutError::Document(format!(
            "shortcut file exceeds {MAX_SHORTCUT_FILE_BYTES} bytes"
        )));
    }
    Ok(bytes)
}

fn write_default_file(path: &Path) -> Result<(), ShortcutError> {
    let bytes = render_shortcut_file(&default_shortcut_file())?;
    let temporary = write_temporary(path, &bytes)?;
    match fs::rename(&temporary, path) {
        Ok(()) => sync_parent(path),
        Err(error) => {
            let _ = fs::remove_file(&temporary);
            Err(error.into())
        }
    }
}

fn render_shortcut_file(file: &ShortcutFile) -> Result<Vec<u8>, ShortcutError> {
    let mut bytes = serde_json::to_vec_pretty(file)?;
    bytes.push(b'\n');
    if bytes.len() > MAX_SHORTCUT_FILE_BYTES {
        return Err(ShortcutError::Document(format!(
            "shortcut file exceeds {MAX_SHORTCUT_FILE_BYTES} bytes"
        )));
    }
    Ok(bytes)
}

fn write_temporary(target: &Path, bytes: &[u8]) -> Result<PathBuf, ShortcutError> {
    let parent = target.parent().ok_or_else(|| {
        ShortcutError::Path(format!("shortcut path {} has no parent", target.display()))
    })?;
    fs::create_dir_all(parent)?;
    fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
    let file_name = target
        .file_name()
        .ok_or_else(|| ShortcutError::Path("shortcut path has no file name".to_owned()))?;
    for _ in 0..64 {
        let sequence = SHORTCUT_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
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
            Ok(mut output) => {
                if let Err(error) = output.write_all(bytes).and_then(|()| output.sync_all()) {
                    let _ = fs::remove_file(&temporary);
                    return Err(error.into());
                }
                return Ok(temporary);
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error.into()),
        }
    }
    Err(ShortcutError::Path(
        "could not allocate a unique shortcut transaction file".to_owned(),
    ))
}

fn move_invalid_file_aside(path: &Path) -> Result<PathBuf, ShortcutError> {
    let parent = path.parent().ok_or_else(|| {
        ShortcutError::Path(format!("shortcut path {} has no parent", path.display()))
    })?;
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    for sequence in 0..1_000u16 {
        let suffix = if sequence == 0 {
            String::new()
        } else {
            format!("-{sequence}")
        };
        let candidate = parent.join(format!(
            "shortcuts.invalid-{timestamp}-{}{}.json",
            std::process::id(),
            suffix
        ));
        if fs::symlink_metadata(&candidate).is_ok() {
            continue;
        }
        fs::rename(path, &candidate)?;
        sync_parent(path)?;
        return Ok(candidate);
    }
    Err(ShortcutError::Path(
        "could not choose a unique invalid shortcut backup name".to_owned(),
    ))
}

fn sync_parent(path: &Path) -> Result<(), ShortcutError> {
    let parent = path.parent().ok_or_else(|| {
        ShortcutError::Path(format!("shortcut path {} has no parent", path.display()))
    })?;
    File::open(parent)?.sync_all()?;
    Ok(())
}

fn shortcut_path() -> Result<PathBuf, ShortcutError> {
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
            ShortcutError::Path(
                "cannot resolve shortcut path: XDG_CONFIG_HOME and HOME are unavailable".to_owned(),
            )
        })?;
    Ok(config_home.join("denial/shortcuts.json"))
}

fn default_shortcut_file() -> ShortcutFile {
    let definitions = [
        ("Ctrl+Alt+Backspace", ShortcutAction::Shutdown),
        ("Super", ShortcutAction::OpenApplications),
        ("Super+A", ShortcutAction::OpenOverview),
        ("ThreeFingerSwipeUp", ShortcutAction::OpenOverview),
        ("Super+Shift+Up", ShortcutAction::ToggleVerticalMaximize),
        ("Super+Tab", ShortcutAction::WindowSwitcher),
        ("Super+V", ShortcutAction::OpenClipboard),
        ("Super+Shift+S", ShortcutAction::CaptureRegion),
        ("Super+M", ShortcutAction::MinimizeWindow),
        ("Super+Up", ShortcutAction::ToggleMaximize),
        ("Super+F", ShortcutAction::ToggleFullscreen),
        ("Super+Escape", ShortcutAction::ReleasePointer),
        ("Super+K", ShortcutAction::CloseWindow),
        ("Super+L", ShortcutAction::LockScreen),
        ("VolumeUp", ShortcutAction::VolumeUp),
        ("VolumeDown", ShortcutAction::VolumeDown),
        ("VolumeMute", ShortcutAction::VolumeMute),
        ("BrightnessUp", ShortcutAction::BrightnessUp),
        ("BrightnessDown", ShortcutAction::BrightnessDown),
        ("Super+VolumeUp", ShortcutAction::BrightnessUp),
        ("Super+VolumeDown", ShortcutAction::BrightnessDown),
        ("Super+Space", ShortcutAction::NextKeyboardLayout),
        ("Super+Shift+Space", ShortcutAction::PreviousKeyboardLayout),
    ];
    ShortcutFile {
        version: SHORTCUT_SCHEMA_VERSION,
        revision: 1,
        shortcuts: definitions
            .into_iter()
            .map(|(shortcut, action)| ShortcutBinding {
                shortcut: shortcut.to_owned(),
                target: ShortcutTarget::DenialAction { action },
            })
            .collect(),
    }
}

fn normalize_and_compile_shortcuts(
    file: &mut ShortcutFile,
) -> Result<Vec<CompiledShortcut>, ShortcutError> {
    let compiled = compile_shortcuts(file)?;
    for (binding, compiled) in file.shortcuts.iter_mut().zip(&compiled) {
        binding.shortcut.clone_from(&compiled.trigger.canonical);
    }
    Ok(compiled)
}

fn compile_shortcuts(file: &ShortcutFile) -> Result<Vec<CompiledShortcut>, ShortcutError> {
    if file.version != SHORTCUT_SCHEMA_VERSION {
        return Err(ShortcutError::Document(format!(
            "shortcut version {} is not supported; expected {SHORTCUT_SCHEMA_VERSION}",
            file.version
        )));
    }
    if file.revision == 0 {
        return Err(ShortcutError::Document(
            "shortcut revision must be greater than zero".to_owned(),
        ));
    }
    if file.shortcuts.len() > MAX_SHORTCUTS {
        return Err(ShortcutError::Document(format!(
            "shortcut count exceeds {MAX_SHORTCUTS}"
        )));
    }
    let mut triggers = HashSet::with_capacity(file.shortcuts.len());
    let mut compiled = Vec::with_capacity(file.shortcuts.len());
    for binding in &file.shortcuts {
        let trigger = parse_shortcut(&binding.shortcut)?;
        if !triggers.insert(trigger.clone()) {
            return Err(ShortcutError::Document(format!(
                "duplicate shortcut {:?}",
                trigger.canonical
            )));
        }
        compiled.push(CompiledShortcut {
            trigger,
            target: {
                binding.target.validate()?;
                binding.target.clone()
            },
        });
    }
    Ok(compiled)
}

fn parse_shortcut(expression: &str) -> Result<ShortcutTrigger, ShortcutError> {
    if expression.is_empty() || expression.len() > MAX_SHORTCUT_EXPRESSION_BYTES {
        return Err(ShortcutError::Document(format!(
            "shortcut expression must contain between 1 and {MAX_SHORTCUT_EXPRESSION_BYTES} bytes"
        )));
    }
    let tokens = expression.split('+').map(str::trim).collect::<Vec<_>>();
    if tokens.is_empty() || tokens.iter().any(|token| token.is_empty()) {
        return Err(ShortcutError::Document(format!(
            "invalid shortcut expression {expression:?}"
        )));
    }
    if tokens.len() == 1
        && let Some(gesture) = parse_gesture(tokens[0])
    {
        return Ok(ShortcutTrigger {
            modifiers: 0,
            key: TriggerKey::Gesture(gesture),
            canonical: gesture.canonical_name().to_owned(),
        });
    }
    if tokens.len() == 1
        && let Some(modifier) = parse_modifier(tokens[0])
    {
        if modifier != Modifier::Super {
            return Err(ShortcutError::Document(format!(
                "modifier-only shortcut {expression:?} is not supported"
            )));
        }
        return Ok(ShortcutTrigger {
            modifiers: 0,
            key: TriggerKey::ModifierTap(modifier),
            canonical: modifier.canonical_name().to_owned(),
        });
    }

    let (key_name, modifier_names) = tokens
        .split_last()
        .ok_or_else(|| ShortcutError::Document("shortcut is empty".to_owned()))?;
    let mut modifiers = 0u8;
    for name in modifier_names {
        let modifier = parse_modifier(name).ok_or_else(|| {
            ShortcutError::Document(format!("unrecognized shortcut modifier {name:?}"))
        })?;
        let flag = modifier.flag();
        if modifiers & flag != 0 {
            return Err(ShortcutError::Document(format!(
                "duplicate shortcut modifier {}",
                modifier.canonical_name()
            )));
        }
        modifiers |= flag;
    }
    if parse_modifier(key_name).is_some() {
        return Err(ShortcutError::Document(format!(
            "shortcut {expression:?} needs a non-modifier key"
        )));
    }
    let (keycode, canonical_key) = parse_key(key_name).ok_or_else(|| {
        ShortcutError::Document(format!("unrecognized shortcut key {key_name:?}"))
    })?;
    let mut canonical = Vec::new();
    for modifier in [
        Modifier::Super,
        Modifier::Ctrl,
        Modifier::Alt,
        Modifier::Shift,
    ] {
        if modifiers & modifier.flag() != 0 {
            canonical.push(modifier.canonical_name().to_owned());
        }
    }
    canonical.push(canonical_key);
    Ok(ShortcutTrigger {
        modifiers,
        key: TriggerKey::Evdev(keycode),
        canonical: canonical.join("+"),
    })
}

fn parse_gesture(name: &str) -> Option<ShortcutGesture> {
    match name
        .to_ascii_lowercase()
        .replace([' ', '-', '_'], "")
        .as_str()
    {
        "threefingerswipeup" | "3fingerswipeup" => Some(ShortcutGesture::ThreeFingerSwipeUp),
        _ => None,
    }
}

fn parse_modifier(name: &str) -> Option<Modifier> {
    match name.to_ascii_lowercase().as_str() {
        "super" | "meta" | "win" => Some(Modifier::Super),
        "ctrl" | "control" => Some(Modifier::Ctrl),
        "alt" => Some(Modifier::Alt),
        "shift" => Some(Modifier::Shift),
        _ => None,
    }
}

struct NamedKeyDefinition {
    keycode: u32,
    canonical: &'static str,
    aliases: &'static [&'static str],
    category: ShortcutInputCategory,
}

const NAMED_KEYS: &[NamedKeyDefinition] = &[
    NamedKeyDefinition {
        keycode: KEY_ESCAPE,
        canonical: "Escape",
        aliases: &["Esc"],
        category: ShortcutInputCategory::Editing,
    },
    NamedKeyDefinition {
        keycode: KEY_BACKSPACE,
        canonical: "Backspace",
        aliases: &[],
        category: ShortcutInputCategory::Editing,
    },
    NamedKeyDefinition {
        keycode: KEY_TAB,
        canonical: "Tab",
        aliases: &[],
        category: ShortcutInputCategory::Editing,
    },
    NamedKeyDefinition {
        keycode: 28,
        canonical: "Enter",
        aliases: &["Return"],
        category: ShortcutInputCategory::Editing,
    },
    NamedKeyDefinition {
        keycode: KEY_SPACE,
        canonical: "Space",
        aliases: &[],
        category: ShortcutInputCategory::Editing,
    },
    NamedKeyDefinition {
        keycode: 12,
        canonical: "Minus",
        aliases: &[],
        category: ShortcutInputCategory::Punctuation,
    },
    NamedKeyDefinition {
        keycode: 13,
        canonical: "Equal",
        aliases: &[],
        category: ShortcutInputCategory::Punctuation,
    },
    NamedKeyDefinition {
        keycode: 26,
        canonical: "BracketLeft",
        aliases: &["LeftBracket"],
        category: ShortcutInputCategory::Punctuation,
    },
    NamedKeyDefinition {
        keycode: 27,
        canonical: "BracketRight",
        aliases: &["RightBracket"],
        category: ShortcutInputCategory::Punctuation,
    },
    NamedKeyDefinition {
        keycode: 39,
        canonical: "Semicolon",
        aliases: &[],
        category: ShortcutInputCategory::Punctuation,
    },
    NamedKeyDefinition {
        keycode: 40,
        canonical: "Apostrophe",
        aliases: &[],
        category: ShortcutInputCategory::Punctuation,
    },
    NamedKeyDefinition {
        keycode: 41,
        canonical: "Grave",
        aliases: &[],
        category: ShortcutInputCategory::Punctuation,
    },
    NamedKeyDefinition {
        keycode: 43,
        canonical: "Backslash",
        aliases: &[],
        category: ShortcutInputCategory::Punctuation,
    },
    NamedKeyDefinition {
        keycode: 51,
        canonical: "Comma",
        aliases: &[],
        category: ShortcutInputCategory::Punctuation,
    },
    NamedKeyDefinition {
        keycode: 52,
        canonical: "Period",
        aliases: &["Dot"],
        category: ShortcutInputCategory::Punctuation,
    },
    NamedKeyDefinition {
        keycode: 53,
        canonical: "Slash",
        aliases: &[],
        category: ShortcutInputCategory::Punctuation,
    },
    NamedKeyDefinition {
        keycode: 58,
        canonical: "CapsLock",
        aliases: &[],
        category: ShortcutInputCategory::Special,
    },
    NamedKeyDefinition {
        keycode: 69,
        canonical: "NumLock",
        aliases: &[],
        category: ShortcutInputCategory::Special,
    },
    NamedKeyDefinition {
        keycode: 70,
        canonical: "ScrollLock",
        aliases: &[],
        category: ShortcutInputCategory::Special,
    },
    NamedKeyDefinition {
        keycode: 102,
        canonical: "Home",
        aliases: &[],
        category: ShortcutInputCategory::Navigation,
    },
    NamedKeyDefinition {
        keycode: KEY_UP,
        canonical: "Up",
        aliases: &[],
        category: ShortcutInputCategory::Navigation,
    },
    NamedKeyDefinition {
        keycode: 104,
        canonical: "PageUp",
        aliases: &["PgUp"],
        category: ShortcutInputCategory::Navigation,
    },
    NamedKeyDefinition {
        keycode: 105,
        canonical: "Left",
        aliases: &[],
        category: ShortcutInputCategory::Navigation,
    },
    NamedKeyDefinition {
        keycode: 106,
        canonical: "Right",
        aliases: &[],
        category: ShortcutInputCategory::Navigation,
    },
    NamedKeyDefinition {
        keycode: 107,
        canonical: "End",
        aliases: &[],
        category: ShortcutInputCategory::Navigation,
    },
    NamedKeyDefinition {
        keycode: 108,
        canonical: "Down",
        aliases: &[],
        category: ShortcutInputCategory::Navigation,
    },
    NamedKeyDefinition {
        keycode: 109,
        canonical: "PageDown",
        aliases: &["PgDown"],
        category: ShortcutInputCategory::Navigation,
    },
    NamedKeyDefinition {
        keycode: 110,
        canonical: "Insert",
        aliases: &[],
        category: ShortcutInputCategory::Editing,
    },
    NamedKeyDefinition {
        keycode: 111,
        canonical: "Delete",
        aliases: &[],
        category: ShortcutInputCategory::Editing,
    },
    NamedKeyDefinition {
        keycode: KEY_MUTE,
        canonical: "VolumeMute",
        aliases: &["AudioMute", "XF86AudioMute"],
        category: ShortcutInputCategory::Media,
    },
    NamedKeyDefinition {
        keycode: KEY_VOLUME_DOWN,
        canonical: "VolumeDown",
        aliases: &["AudioDown", "XF86AudioLowerVolume"],
        category: ShortcutInputCategory::Media,
    },
    NamedKeyDefinition {
        keycode: KEY_VOLUME_UP,
        canonical: "VolumeUp",
        aliases: &["AudioUp", "XF86AudioRaiseVolume"],
        category: ShortcutInputCategory::Media,
    },
    NamedKeyDefinition {
        keycode: KEY_BRIGHTNESS_DOWN,
        canonical: "BrightnessDown",
        aliases: &["XF86MonBrightnessDown"],
        category: ShortcutInputCategory::Hardware,
    },
    NamedKeyDefinition {
        keycode: KEY_BRIGHTNESS_UP,
        canonical: "BrightnessUp",
        aliases: &["XF86MonBrightnessUp"],
        category: ShortcutInputCategory::Hardware,
    },
    NamedKeyDefinition {
        keycode: 99,
        canonical: "PrintScreen",
        aliases: &["Print", "SysRq"],
        category: ShortcutInputCategory::Special,
    },
    NamedKeyDefinition {
        keycode: 119,
        canonical: "Pause",
        aliases: &[],
        category: ShortcutInputCategory::Special,
    },
    NamedKeyDefinition {
        keycode: 139,
        canonical: "Menu",
        aliases: &[],
        category: ShortcutInputCategory::Special,
    },
    NamedKeyDefinition {
        keycode: 165,
        canonical: "PreviousTrack",
        aliases: &["XF86AudioPrev"],
        category: ShortcutInputCategory::Media,
    },
    NamedKeyDefinition {
        keycode: 163,
        canonical: "NextTrack",
        aliases: &["XF86AudioNext"],
        category: ShortcutInputCategory::Media,
    },
    NamedKeyDefinition {
        keycode: 164,
        canonical: "PlayPause",
        aliases: &["XF86AudioPlay"],
        category: ShortcutInputCategory::Media,
    },
    NamedKeyDefinition {
        keycode: 166,
        canonical: "StopMedia",
        aliases: &["XF86AudioStop"],
        category: ShortcutInputCategory::Media,
    },
    NamedKeyDefinition {
        keycode: 229,
        canonical: "KeyboardBrightnessDown",
        aliases: &["XF86KbdBrightnessDown"],
        category: ShortcutInputCategory::Hardware,
    },
    NamedKeyDefinition {
        keycode: 230,
        canonical: "KeyboardBrightnessUp",
        aliases: &["XF86KbdBrightnessUp"],
        category: ShortcutInputCategory::Hardware,
    },
];

pub(super) fn supported_inputs() -> Vec<ShortcutInputDefinition> {
    let mut inputs = vec![
        input_definition("Super", ShortcutInputCategory::Modifier, &["Meta", "Win"]),
        input_definition("Ctrl", ShortcutInputCategory::Modifier, &["Control"]),
        input_definition("Alt", ShortcutInputCategory::Modifier, &[]),
        input_definition("Shift", ShortcutInputCategory::Modifier, &[]),
    ];
    inputs.extend(NAMED_KEYS.iter().map(|key| {
        ShortcutInputDefinition {
            canonical: key.canonical.to_owned(),
            kind: ShortcutInputKind::Key,
            category: key.category,
            aliases: key
                .aliases
                .iter()
                .map(|alias| (*alias).to_owned())
                .collect(),
        }
    }));
    inputs.extend((1..=24).map(|number| ShortcutInputDefinition {
        canonical: format!("F{number}"),
        kind: ShortcutInputKind::Key,
        category: ShortcutInputCategory::Function,
        aliases: Vec::new(),
    }));
    inputs.push(ShortcutInputDefinition {
        canonical: ShortcutGesture::ThreeFingerSwipeUp
            .canonical_name()
            .to_owned(),
        kind: ShortcutInputKind::Gesture,
        category: ShortcutInputCategory::Gesture,
        aliases: vec!["3FingerSwipeUp".to_owned()],
    });
    inputs
}

fn input_definition(
    canonical: &str,
    category: ShortcutInputCategory,
    aliases: &[&str],
) -> ShortcutInputDefinition {
    ShortcutInputDefinition {
        canonical: canonical.to_owned(),
        kind: ShortcutInputKind::Key,
        category,
        aliases: aliases.iter().map(|alias| (*alias).to_owned()).collect(),
    }
}

fn parse_key(name: &str) -> Option<(u32, String)> {
    let lower = name.to_ascii_lowercase();
    if lower.len() == 1 {
        let byte = lower.as_bytes()[0];
        if byte.is_ascii_lowercase() {
            let keycodes = [
                30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50, 49, 24, 25, 16, 19, 31, 20, 22,
                47, 17, 45, 21, 44,
            ];
            return Some((
                keycodes[usize::from(byte - b'a')],
                char::from(byte).to_ascii_uppercase().to_string(),
            ));
        }
        if byte.is_ascii_digit() {
            let keycode = if byte == b'0' {
                11
            } else {
                u32::from(byte - b'0') + 1
            };
            return Some((keycode, char::from(byte).to_string()));
        }
    }
    if let Some(function) = lower
        .strip_prefix('f')
        .and_then(|value| value.parse::<u32>().ok())
    {
        let keycode = match function {
            1..=10 => 58 + function,
            11 => 87,
            12 => 88,
            13..=24 => 170 + function,
            _ => return None,
        };
        return Some((keycode, format!("F{function}")));
    }
    NAMED_KEYS.iter().find_map(|key| {
        (key.canonical.eq_ignore_ascii_case(&lower)
            || key
                .aliases
                .iter()
                .any(|alias| alias.eq_ignore_ascii_case(&lower)))
        .then(|| (key.keycode, key.canonical.to_owned()))
    })
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) enum ShortcutDisposition {
    Forward,
    Consume,
    RequestShutdown,
    RequestApplications,
    RequestOverview,
    RequestToggleVerticalMaximize,
    RequestWindowSwitcherNext,
    RequestWindowSwitcherEnd { forward: bool },
    RequestClipboard,
    RequestScreenshotRegion,
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
    RequestNextKeyboardLayout,
    RequestPreviousKeyboardLayout,
    Spawn(Vec<String>),
    SpawnSh(String),
}

#[derive(Clone, Copy, Debug)]
enum WindowSwitcherRelease {
    Modifier(Modifier),
    Key(u32),
}

#[derive(Clone, Debug)]
pub(super) struct ShortcutEngine {
    bindings: Vec<CompiledShortcut>,
    ctrl_keys: u8,
    alt_keys: u8,
    shift_keys: u8,
    logo_keys: u8,
    logo_chorded: bool,
    window_switcher_release: Option<WindowSwitcherRelease>,
    captured_keys: HashMap<u32, ShortcutTarget>,
}

impl Default for ShortcutEngine {
    fn default() -> Self {
        Self::from_file(&default_shortcut_file()).expect("default shortcuts must be valid")
    }
}

impl ShortcutEngine {
    fn from_file(file: &ShortcutFile) -> Result<Self, ShortcutError> {
        Ok(Self {
            bindings: compile_shortcuts(file)?,
            ctrl_keys: 0,
            alt_keys: 0,
            shift_keys: 0,
            logo_keys: 0,
            logo_chorded: false,
            window_switcher_release: None,
            captured_keys: HashMap::new(),
        })
    }

    fn active_modifiers(&self) -> u8 {
        let mut modifiers = 0;
        if self.logo_keys != 0 {
            modifiers |= Modifier::Super.flag();
        }
        if self.ctrl_keys != 0 {
            modifiers |= Modifier::Ctrl.flag();
        }
        if self.alt_keys != 0 {
            modifiers |= Modifier::Alt.flag();
        }
        if self.shift_keys != 0 {
            modifiers |= Modifier::Shift.flag();
        }
        modifiers
    }

    pub(super) fn observe_gesture(&self, gesture: ShortcutGesture) -> ShortcutDisposition {
        self.bindings
            .iter()
            .find(|binding| {
                binding.trigger.modifiers == 0
                    && binding.trigger.key == TriggerKey::Gesture(gesture)
            })
            .map(|binding| binding.target.clone().into())
            .unwrap_or(ShortcutDisposition::Forward)
    }

    fn target_for_key(&self, evdev_keycode: u32) -> Option<(ShortcutTarget, u8)> {
        let modifiers = self.active_modifiers();
        self.bindings.iter().find_map(|binding| {
            (binding.trigger.modifiers == modifiers
                && binding.trigger.key == TriggerKey::Evdev(evdev_keycode))
            .then(|| (binding.target.clone(), binding.trigger.modifiers))
        })
    }

    fn modifier_tap_target(&self, modifier: Modifier) -> Option<ShortcutTarget> {
        self.bindings.iter().find_map(|binding| {
            (binding.trigger.key == TriggerKey::ModifierTap(modifier))
                .then(|| binding.target.clone())
        })
    }

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
            if matches!(
                self.window_switcher_release,
                Some(WindowSwitcherRelease::Modifier(Modifier::Super))
            ) {
                self.window_switcher_release = None;
                if self.logo_keys == 0 {
                    self.logo_chorded = false;
                }
                return ShortcutDisposition::RequestWindowSwitcherEnd { forward: false };
            }
            if self.logo_keys == 0 {
                let chorded = std::mem::take(&mut self.logo_chorded);
                if !chorded && let Some(target) = self.modifier_tap_target(Modifier::Super) {
                    return target.into();
                }
            }
            return ShortcutDisposition::Consume;
        }

        if pressed && self.logo_keys != 0 {
            self.logo_chorded = true;
        }

        let modifier = match evdev_keycode {
            KEY_LEFT_CTRL => Some((Modifier::Ctrl, LEFT_MODIFIER)),
            KEY_RIGHT_CTRL => Some((Modifier::Ctrl, RIGHT_MODIFIER)),
            KEY_LEFT_ALT => Some((Modifier::Alt, LEFT_MODIFIER)),
            KEY_RIGHT_ALT => Some((Modifier::Alt, RIGHT_MODIFIER)),
            KEY_LEFT_SHIFT => Some((Modifier::Shift, LEFT_MODIFIER)),
            KEY_RIGHT_SHIFT => Some((Modifier::Shift, RIGHT_MODIFIER)),
            _ => None,
        };
        if let Some((modifier, bit)) = modifier {
            let keys = match modifier {
                Modifier::Ctrl => &mut self.ctrl_keys,
                Modifier::Alt => &mut self.alt_keys,
                Modifier::Shift => &mut self.shift_keys,
                Modifier::Super => unreachable!("SUPER modifiers are handled above"),
            };
            if pressed {
                *keys |= bit;
            } else {
                *keys &= !bit;
            }
            if !pressed
                && matches!(
                    self.window_switcher_release,
                    Some(WindowSwitcherRelease::Modifier(owner)) if owner == modifier
                )
            {
                self.window_switcher_release = None;
                return ShortcutDisposition::RequestWindowSwitcherEnd { forward: true };
            }
            return ShortcutDisposition::Forward;
        }
        if !pressed {
            let captured = self.captured_keys.remove(&evdev_keycode).is_some();
            if matches!(
                self.window_switcher_release,
                Some(WindowSwitcherRelease::Key(owner)) if owner == evdev_keycode
            ) {
                self.window_switcher_release = None;
                return ShortcutDisposition::RequestWindowSwitcherEnd { forward: false };
            }
            return if captured {
                ShortcutDisposition::Consume
            } else {
                ShortcutDisposition::Forward
            };
        }

        if let Some(target) = self.captured_keys.get(&evdev_keycode) {
            return if target.repeats() {
                target.clone().into()
            } else {
                ShortcutDisposition::Consume
            };
        }
        let Some((target, modifiers)) = self.target_for_key(evdev_keycode) else {
            return ShortcutDisposition::Forward;
        };

        self.captured_keys.insert(evdev_keycode, target.clone());
        if target
            == (ShortcutTarget::DenialAction {
                action: ShortcutAction::WindowSwitcher,
            })
            && self.window_switcher_release.is_none()
        {
            self.window_switcher_release = Some(
                [
                    Modifier::Super,
                    Modifier::Ctrl,
                    Modifier::Alt,
                    Modifier::Shift,
                ]
                .into_iter()
                .find(|modifier| modifiers & modifier.flag() != 0)
                .map_or(
                    WindowSwitcherRelease::Key(evdev_keycode),
                    WindowSwitcherRelease::Modifier,
                ),
            );
        }
        target.into()
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
        self.ctrl_keys = 0;
        self.alt_keys = 0;
        self.shift_keys = 0;
        self.logo_keys = 0;
        self.logo_chorded = false;
        self.window_switcher_release = None;
        self.captured_keys.clear();
    }
}

impl From<ShortcutAction> for ShortcutDisposition {
    fn from(action: ShortcutAction) -> Self {
        match action {
            ShortcutAction::Shutdown => Self::RequestShutdown,
            ShortcutAction::OpenApplications => Self::RequestApplications,
            ShortcutAction::OpenOverview => Self::RequestOverview,
            ShortcutAction::ToggleVerticalMaximize => Self::RequestToggleVerticalMaximize,
            ShortcutAction::WindowSwitcher => Self::RequestWindowSwitcherNext,
            ShortcutAction::OpenClipboard => Self::RequestClipboard,
            ShortcutAction::CaptureRegion => Self::RequestScreenshotRegion,
            ShortcutAction::CloseWindow => Self::RequestClose,
            ShortcutAction::MinimizeWindow => Self::RequestMinimize,
            ShortcutAction::ToggleMaximize => Self::RequestToggleMaximize,
            ShortcutAction::ToggleFullscreen => Self::RequestToggleFullscreen,
            ShortcutAction::ReleasePointer => Self::RequestReleasePointer,
            ShortcutAction::LockScreen => Self::RequestLock,
            ShortcutAction::VolumeUp => Self::RequestVolumeUp,
            ShortcutAction::VolumeDown => Self::RequestVolumeDown,
            ShortcutAction::VolumeMute => Self::RequestMute,
            ShortcutAction::BrightnessUp => Self::RequestBrightnessUp,
            ShortcutAction::BrightnessDown => Self::RequestBrightnessDown,
            ShortcutAction::NextKeyboardLayout => Self::RequestNextKeyboardLayout,
            ShortcutAction::PreviousKeyboardLayout => Self::RequestPreviousKeyboardLayout,
        }
    }
}

impl From<ShortcutTarget> for ShortcutDisposition {
    fn from(target: ShortcutTarget) -> Self {
        match target {
            ShortcutTarget::DenialAction { action } => action.into(),
            ShortcutTarget::Spawn { command } => Self::Spawn(command),
            ShortcutTarget::SpawnSh { command } => Self::SpawnSh(command),
        }
    }
}

pub(super) type NativeEscapeShortcut = ShortcutEngine;

#[cfg(test)]
mod tests {
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
}
