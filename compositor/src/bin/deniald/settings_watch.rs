//! Filesystem notification source for live settings edits.

use std::error::Error;
use std::mem::MaybeUninit;
use std::os::fd::AsFd;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

use smithay::reexports::calloop::{Interest, LoopHandle, Mode, PostAction, generic::Generic};
use smithay::reexports::rustix::{
    fs::inotify::{self, CreateFlags, WatchFlags},
    io::Errno,
};
use tracing::{info, warn};

use super::RuntimeState;

/// Watches the containing directory rather than the file itself because most
/// editors save by renaming a temporary file over the original inode.
pub(super) fn install(
    handle: &LoopHandle<'_, RuntimeState>,
    settings_path: &Path,
) -> Result<(), Box<dyn Error>> {
    let parent = settings_path
        .parent()
        .ok_or("settings path has no parent directory")?;
    let file_name = settings_path
        .file_name()
        .ok_or("settings path has no file name")?
        .as_bytes()
        .to_vec();
    let watcher = inotify::init(CreateFlags::CLOEXEC | CreateFlags::NONBLOCK)?;
    inotify::add_watch(
        &watcher,
        parent,
        WatchFlags::CLOSE_WRITE | WatchFlags::MOVED_TO | WatchFlags::DELETE,
    )?;
    handle.insert_source(
        Generic::new(watcher, Interest::READ, Mode::Level),
        move |_, watcher, state: &mut RuntimeState| {
            let mut buffer = [MaybeUninit::uninit(); 4096];
            let mut reader = inotify::Reader::new(watcher.as_fd(), &mut buffer);
            loop {
                match reader.next() {
                    Ok(event) => {
                        // A nameless event includes queue overflow. Reconcile
                        // from disk rather than trusting that no edit occurred.
                        if event
                            .file_name()
                            .is_none_or(|name| name.to_bytes() == file_name)
                        {
                            state.settings_external_change_pending = true;
                        }
                    }
                    Err(Errno::AGAIN) => break,
                    Err(Errno::INTR) => continue,
                    Err(error) => {
                        warn!(%error, "settings filesystem watch failed");
                        return Ok(PostAction::Remove);
                    }
                }
            }
            Ok(PostAction::Continue)
        },
    )?;
    info!(path = %settings_path.display(), "watching Denial settings for external edits");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use smithay::reexports::calloop::EventLoop;
    use std::fs;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::Duration;

    static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

    struct TemporaryDirectory(std::path::PathBuf);

    impl TemporaryDirectory {
        fn new() -> Self {
            let sequence = TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "denial-settings-watch-{}-{sequence}",
                std::process::id()
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for TemporaryDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn watches_in_place_and_atomic_editor_saves() {
        let temporary = TemporaryDirectory::new();
        let directory = temporary.0.join("denial");
        let settings_path = directory.join("settings.json");
        fs::create_dir(&directory).unwrap();
        fs::write(&settings_path, b"{}\n").unwrap();
        let mut event_loop = EventLoop::<RuntimeState>::try_new().unwrap();
        install(&event_loop.handle(), &settings_path).unwrap();
        let mut state = RuntimeState::default();

        fs::write(&settings_path, b"{\"inPlace\":true}\n").unwrap();
        event_loop
            .dispatch(Some(Duration::from_secs(1)), &mut state)
            .unwrap();
        assert!(std::mem::take(&mut state.settings_external_change_pending));

        let replacement = directory.join("editor-save.tmp");
        fs::write(&replacement, b"{\"renamed\":true}\n").unwrap();
        fs::rename(&replacement, &settings_path).unwrap();
        event_loop
            .dispatch(Some(Duration::from_secs(1)), &mut state)
            .unwrap();
        assert!(state.settings_external_change_pending);
    }
}
