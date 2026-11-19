//! Starts Xwayland with an empty signal mask.
//!
//! calloop's signalfd blocks the control signals (SIGINT, SIGTERM, SIGUSR1,
//! SIGUSR2) in every compositor thread, and a fork keeps the mask through
//! exec. Smithay spawns Xwayland itself and offers no pre-exec hook, so
//! Xwayland would run with those signals blocked and ignore a plain `kill`.
//! Unblocking them in a compositor thread around the spawn is no answer: a
//! control signal arriving then would take its default action and end the
//! session.
//!
//! Smithay runs `Xwayland` found on the PATH it is given. That PATH starts
//! with a folder whose `Xwayland` leads back to this program, which clears the
//! mask, puts the PATH back and becomes the real Xwayland. The link points at
//! `/proc/self/exe`, so it reaches the running compositor's own binary even
//! after a rebuild replaced the file.

use std::ffi::OsString;
use std::io;
use std::mem::MaybeUninit;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::{env, fs};

/// The name Smithay runs, and the name this program answers to.
const PROGRAM: &str = "Xwayland";
/// The PATH the compositor had, for the real Xwayland to be found on.
const PATH_ENV: &str = "DENIAL_XWAYLAND_PATH";
/// Where the link resolves: the binary of the process that runs it.
const SELF_EXE: &str = "/proc/self/exe";

/// Becomes the real Xwayland when this program was started as `Xwayland`.
/// Runs first in `main`, before any thread or signal setup.
pub(super) fn run_if_requested() {
    let started_as = env::args_os().next().map(PathBuf::from);
    if started_as
        .as_deref()
        .and_then(Path::file_name)
        .is_some_and(|name| name == PROGRAM)
    {
        let error = exec_xwayland();
        eprintln!("deniald: could not start Xwayland: {error}");
        std::process::exit(127);
    }
}

fn exec_xwayland() -> io::Error {
    // SAFETY: this runs on the only thread, before anything else in main.
    unsafe {
        let mut signals = MaybeUninit::<libc::sigset_t>::uninit();
        if libc::sigemptyset(signals.as_mut_ptr()) != 0 {
            return io::Error::last_os_error();
        }
        let result =
            libc::pthread_sigmask(libc::SIG_SETMASK, signals.as_ptr(), std::ptr::null_mut());
        if result != 0 {
            return io::Error::from_raw_os_error(result);
        }
        // The Rust runtime ignores SIGPIPE; a spawned program starts with
        // the default, as Rust's own spawns give it.
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
    }
    let Some(path) = env::var_os(PATH_ENV) else {
        return io::Error::other(format!("{PATH_ENV} is not set"));
    };
    // SAFETY: still the only thread.
    unsafe {
        env::remove_var(PATH_ENV);
        env::set_var("PATH", &path);
    }
    Command::new(PROGRAM).args(env::args_os().skip(1)).exec()
}

/// Prepares the folder holding the `Xwayland` link and returns the
/// environment that makes Smithay start Xwayland through it.
pub(super) fn environment() -> io::Result<[(OsString, OsString); 2]> {
    let runtime = env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .filter(|runtime| runtime.is_absolute())
        .ok_or_else(|| io::Error::other("XDG_RUNTIME_DIR must be an absolute path"))?;
    let folder = runtime.join("denial").join("xwayland-exec");
    fs::create_dir_all(&folder)?;
    fs::set_permissions(&folder, fs::Permissions::from_mode(0o700))?;
    let link = folder.join(PROGRAM);
    if fs::read_link(&link).ok().as_deref() != Some(Path::new(SELF_EXE)) {
        let _ = fs::remove_file(&link);
        symlink(SELF_EXE, &link)?;
    }
    let path = env::var_os("PATH").unwrap_or_default();
    Ok([
        (OsString::from("PATH"), search_path(&folder, &path)),
        (OsString::from(PATH_ENV), path),
    ])
}

fn search_path(folder: &Path, path: &OsString) -> OsString {
    let mut search = folder.as_os_str().to_owned();
    if !path.is_empty() {
        search.push(":");
        search.push(path);
    }
    search
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_link_folder_comes_first_on_the_path() {
        let folder = Path::new("/run/user/1000/denial/xwayland-exec");
        assert_eq!(
            search_path(folder, &OsString::from("/usr/bin:/bin")),
            OsString::from("/run/user/1000/denial/xwayland-exec:/usr/bin:/bin")
        );
        assert_eq!(
            search_path(folder, &OsString::new()),
            OsString::from("/run/user/1000/denial/xwayland-exec")
        );
    }
}
