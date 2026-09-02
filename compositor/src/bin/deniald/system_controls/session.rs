use super::*;
use std::fs::OpenOptions;
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::sync::atomic::{AtomicU64, Ordering};

const SUSPEND_MODE_DIRECTORY: &str = "denial";
static SUSPEND_MODE_TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

pub(super) fn run_session_worker(commands: Receiver<SessionCommand>) {
    while let Ok(command) = commands.recv() {
        match command {
            SessionCommand::SetSuspendMode(mode) => {
                if let Err(error) = synchronize_suspend_mode(mode) {
                    warn!(%error, "could not publish the selected suspend mode");
                }
            }
            SessionCommand::Suspend => {
                if let Err(error) = suspend() {
                    warn!(%error, "automatic system suspend failed");
                }
            }
            SessionCommand::Stop => {
                if let Err(error) = remove_suspend_mode_marker() {
                    warn!(%error, "could not remove the suspend mode marker");
                }
                return;
            }
        }
    }
}

fn synchronize_suspend_mode(mode: crate::idle_policy::SuspendMode) -> Result<(), String> {
    let path = suspend_mode_path()?;
    synchronize_suspend_mode_at(&path, mode)
}

fn remove_suspend_mode_marker() -> Result<(), String> {
    let path = suspend_mode_path()?;
    remove_suspend_mode_marker_at(&path)
}

fn suspend_mode_path() -> Result<PathBuf, String> {
    let runtime = std::env::var_os("XDG_RUNTIME_DIR")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .ok_or_else(|| "XDG_RUNTIME_DIR is required for suspend mode selection".to_owned())?;
    if !runtime.is_absolute() {
        return Err("XDG_RUNTIME_DIR must be absolute for suspend mode selection".to_owned());
    }
    let session = std::env::var("XDG_SESSION_ID")
        .map_err(|_| "XDG_SESSION_ID is required for suspend mode selection".to_owned())?;
    if session.is_empty()
        || !session
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
    {
        return Err("XDG_SESSION_ID is invalid for suspend mode selection".to_owned());
    }
    Ok(runtime
        .join(SUSPEND_MODE_DIRECTORY)
        .join(format!("suspend-mode-{session}")))
}

fn synchronize_suspend_mode_at(
    path: &Path,
    mode: crate::idle_policy::SuspendMode,
) -> Result<(), String> {
    let Some(value) = mode.kernel_value() else {
        return remove_suspend_mode_marker_at(path);
    };
    let parent = path
        .parent()
        .ok_or_else(|| "suspend mode marker has no parent directory".to_owned())?;
    match fs::symlink_metadata(parent) {
        Ok(metadata) if metadata.file_type().is_dir() => {}
        Ok(_) => {
            return Err(format!(
                "suspend mode marker parent {} is not a directory",
                parent.display()
            ));
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            fs::create_dir(parent).map_err(|error| {
                format!(
                    "could not create suspend mode marker directory {}: {error}",
                    parent.display()
                )
            })?
        }
        Err(error) => {
            return Err(format!(
                "could not inspect suspend mode marker directory {}: {error}",
                parent.display()
            ));
        }
    }
    fs::set_permissions(parent, fs::Permissions::from_mode(0o700)).map_err(|error| {
        format!(
            "could not secure suspend mode marker directory {}: {error}",
            parent.display()
        )
    })?;
    if fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_dir()) {
        return Err(format!(
            "suspend mode marker {} is a directory",
            path.display()
        ));
    }
    let sequence = SUSPEND_MODE_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let temporary = parent.join(format!(
        ".suspend-mode-{}-{sequence}.tmp",
        std::process::id()
    ));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)
        .map_err(|error| {
            format!(
                "could not create temporary suspend mode marker {}: {error}",
                temporary.display()
            )
        })?;
    let result = (|| -> io::Result<()> {
        writeln!(file, "{value}")?;
        file.sync_data()?;
        fs::rename(&temporary, path)
    })();
    if let Err(error) = result {
        let _ = fs::remove_file(&temporary);
        return Err(format!(
            "could not commit suspend mode marker {}: {error}",
            path.display()
        ));
    }
    Ok(())
}

fn remove_suspend_mode_marker_at(path: &Path) -> Result<(), String> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_dir() => Err(format!(
            "suspend mode marker {} is a directory",
            path.display()
        )),
        Ok(_) => fs::remove_file(path).map_err(|error| {
            format!(
                "could not remove suspend mode marker {}: {error}",
                path.display()
            )
        }),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!(
            "could not inspect suspend mode marker {}: {error}",
            path.display()
        )),
    }
}

fn suspend() -> Result<(), String> {
    let connection = zbus::blocking::Connection::system()
        .map_err(|error| format!("could not connect to the system bus: {error}"))?;
    let manager = zbus::blocking::Proxy::new(
        &connection,
        "org.freedesktop.login1",
        "/org/freedesktop/login1",
        "org.freedesktop.login1.Manager",
    )
    .map_err(|error| format!("could not open the logind manager: {error}"))?;
    let _: () = manager
        .call("Suspend", &false)
        .map_err(|error| format!("logind Suspend failed: {error}"))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn explicit_suspend_mode_is_published_and_system_default_removes_it() {
        let root = std::env::temp_dir().join(format!(
            "denial-suspend-mode-{}-{}",
            std::process::id(),
            SUSPEND_MODE_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&root).unwrap();
        let marker = root.join("denial/suspend-mode-test");

        synchronize_suspend_mode_at(&marker, crate::idle_policy::SuspendMode::Deep).unwrap();
        assert_eq!(fs::read_to_string(&marker).unwrap(), "deep\n");
        assert_eq!(
            fs::metadata(marker.parent().unwrap())
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );

        synchronize_suspend_mode_at(&marker, crate::idle_policy::SuspendMode::SystemDefault)
            .unwrap();
        assert!(!marker.exists());
        fs::remove_dir_all(root).unwrap();
    }
}
