//! Small, best-effort adapters for application configuration files.

use std::ffi::OsStr;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Sender};
use std::time::Duration;

use serde_json::{Map, Value};
use tracing::warn;

const BEGIN: &str = "# BEGIN Denial managed appearance";
const END: &str = "# END Denial managed appearance";

pub(super) struct ApplicationTheming(Sender<Theme>);

impl ApplicationTheming {
    pub(super) fn start(document: &Map<String, Value>) -> Option<Self> {
        let config = std::env::var_os("XDG_CONFIG_HOME")
            .filter(|path| Path::new(path).is_absolute())
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")));
        let Some(config) = config else {
            warn!("application theming has no user configuration directory");
            return None;
        };
        let path = std::env::var_os("PATH").unwrap_or_default();
        let (sender, receiver) = mpsc::channel::<Theme>();
        let worker = std::thread::Builder::new()
            .name("application-theming".into())
            .spawn(move || {
                while let Ok(mut theme) = receiver.recv() {
                    // Coalesce slider commits; never perform file IO on the compositor loop.
                    while let Ok(next) = receiver.recv_timeout(Duration::from_millis(150)) {
                        theme = next;
                    }
                    if let Err(error) = sync_kitty(&config.join("kitty/kitty.conf"), &path, theme) {
                        warn!(%error, "could not synchronize Kitty appearance");
                    }
                }
            });
        if let Err(error) = worker {
            warn!(%error, "could not start application theming");
            return None;
        }
        let service = Self(sender);
        service.apply(document);
        Some(service)
    }

    pub(super) fn apply(&self, document: &Map<String, Value>) {
        if let Err(error) = self.0.send(Theme::from_document(document)) {
            warn!(%error, "application theming worker is unavailable");
        }
    }
}

#[derive(Clone, Copy)]
struct Theme {
    enabled: bool,
    opacity: f64,
}

impl Theme {
    fn from_document(document: &Map<String, Value>) -> Self {
        let appearance = document.get("appearance").unwrap_or(&Value::Null);
        Self {
            enabled: appearance["applicationThemingEnabled"]
                .as_bool()
                .unwrap_or(true),
            opacity: window_opacity(appearance),
        }
    }

    fn header(self) -> String {
        // Stable across unrelated settings commits and restarts. Bump the prefix
        // when the adapter's generated settings change; no file-value comparisons.
        format!("{BEGIN}: 1-{:016x}", self.opacity.to_bits())
    }
}

/// The window opacity of the selected transparency mode, as the shell's
/// application theme resolves it. Mirrors the settings defaults and bounds.
fn window_opacity(appearance: &Value) -> f64 {
    let number = |pointer: &str| appearance.pointer(pointer).and_then(Value::as_f64);
    let mode =
        appearance["transparencyMode"]
            .as_str()
            .or_else(|| match appearance["backdropBlurEnabled"].as_bool() {
                Some(true) => Some("blur"),
                Some(false) => Some("off"),
                None => None,
            });
    match mode {
        Some("off") => 1.0,
        Some("blur") => number("/panelOpacity").unwrap_or(0.5).clamp(0.05, 1.0),
        _ => number("/glass/windowOpacity")
            .or_else(|| number("/glass/opacity"))
            .unwrap_or(0.4)
            .clamp(0.0, 1.0),
    }
}

fn sync_kitty(path: &Path, search_path: &OsStr, theme: Theme) -> io::Result<()> {
    // Resolve existing symlinks so dotfile managers keep ownership of the link.
    let target = match fs::symlink_metadata(path) {
        Ok(_) => fs::canonicalize(path)?,
        Err(error) if error.kind() == io::ErrorKind::NotFound => path.to_owned(),
        Err(error) => return Err(error),
    };
    let existing = match fs::read_to_string(&target) {
        Ok(text) => text,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            if !theme.enabled || !executable_on_path("kitty", search_path) {
                return Ok(());
            }
            String::new()
        }
        Err(error) => return Err(error),
    };
    if let Some(updated) = rewrite_kitty(&existing, theme)? {
        write_config(&target, &updated)?;
    }
    Ok(())
}

fn executable_on_path(name: &str, search_path: &OsStr) -> bool {
    std::env::split_paths(search_path).any(|directory| {
        fs::metadata(directory.join(name))
            .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
    })
}

fn rewrite_kitty(existing: &str, theme: Theme) -> io::Result<Option<String>> {
    let header = theme.header();
    if theme.enabled && existing.lines().any(|line| line.trim() == header) {
        return Ok(None);
    }
    let mut result = String::new();
    let mut in_block = false;
    let mut removed_block = false;
    let mut removed_setting = false;
    for line in existing.split_inclusive('\n') {
        let trimmed = line.trim();
        if trimmed
            .strip_prefix(BEGIN)
            .is_some_and(|suffix| suffix.is_empty() || suffix.starts_with(':'))
        {
            in_block = true;
            removed_block = true;
        } else if in_block && trimmed == END {
            in_block = false;
        } else if !in_block {
            if removed_setting && trimmed.starts_with('\\') {
                continue;
            }
            removed_setting =
                theme.enabled && trimmed.split_whitespace().next() == Some("background_opacity");
            if !removed_setting {
                result.push_str(line);
            }
        }
    }
    if in_block {
        // A missing terminator must not cause unrelated user settings to be deleted.
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "unterminated Denial appearance block",
        ));
    }
    if theme.enabled {
        if !result.is_empty() && !result.ends_with('\n') {
            result.push('\n');
        }
        result.push_str(&format!(
            "{header}\n# Changes made to this block will be lost\nbackground_opacity {}\n{END}\n",
            theme.opacity,
        ));
    } else if !removed_block {
        return Ok(None);
    }
    Ok(Some(result))
}

fn write_config(path: &Path, text: &str) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::other("config has no parent"))?;
    fs::create_dir_all(parent)?;
    let temporary = parent.join(format!(".kitty.conf.denial-{}.tmp", std::process::id()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)?;
    let result = (|| {
        if let Ok(metadata) = fs::metadata(path) {
            file.set_permissions(metadata.permissions())?;
        }
        file.write_all(text.as_bytes())?;
        file.sync_all()?;
        fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

#[cfg(test)]
#[path = "application_theming/tests.rs"]
mod tests;
