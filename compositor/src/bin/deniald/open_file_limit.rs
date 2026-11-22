//! deniald holds a descriptor for every client buffer plane, fence, import
//! and connection, so the soft limit systemd starts it with (1024, or the
//! session's) is too low. Like sway, niri, KWin and mutter, it raises the
//! soft limit to the hard limit at startup. Applications it launches get the
//! original soft limit back: some still use select(), which cannot see
//! descriptors above 1023.

use std::io;
use std::sync::atomic::{AtomicU64, Ordering};

use tracing::{info, warn};

/// The soft limit deniald started with; `u64::MAX` while it was not raised.
static ORIGINAL_SOFT: AtomicU64 = AtomicU64::new(u64::MAX);

fn current() -> io::Result<libc::rlimit> {
    let mut limit = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    // SAFETY: getrlimit writes one rlimit into the valid pointer.
    if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(limit)
}

/// Raises the soft limit to the hard limit. Startup, before any spawn.
pub(super) fn raise() {
    let limit = match current() {
        Ok(limit) => limit,
        Err(error) => {
            warn!(%error, "could not read the open file limit");
            return;
        }
    };
    if limit.rlim_cur >= limit.rlim_max {
        return;
    }
    let raised = libc::rlimit {
        rlim_cur: limit.rlim_max,
        rlim_max: limit.rlim_max,
    };
    // SAFETY: setrlimit reads one rlimit from the valid pointer.
    if unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &raised) } != 0 {
        let error = io::Error::last_os_error();
        warn!(%error, soft = limit.rlim_cur, "could not raise the open file limit");
        return;
    }
    ORIGINAL_SOFT.store(limit.rlim_cur, Ordering::Release);
    info!(
        from = limit.rlim_cur,
        to = limit.rlim_max,
        "raised the open file limit"
    );
}

/// Puts the original soft limit back. Runs in a launched application's
/// child between fork and exec: syscalls only, no allocation.
pub(super) fn restore_in_child() -> io::Result<()> {
    let soft = ORIGINAL_SOFT.load(Ordering::Acquire);
    if soft == u64::MAX {
        return Ok(());
    }
    let mut limit = current()?;
    limit.rlim_cur = soft.min(limit.rlim_max);
    // SAFETY: setrlimit reads one rlimit from the valid pointer.
    if unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &limit) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::os::unix::process::CommandExt;
    use std::process::Command;

    use super::*;

    /// The compositor runs at the hard limit; a launched child is back at
    /// the soft limit the compositor started with.
    #[test]
    fn raised_here_restored_in_children() {
        let before = current().unwrap();
        raise();
        let raised = current().unwrap();
        assert_eq!(raised.rlim_cur, raised.rlim_max);
        let mut command = Command::new("sh");
        command.args(["-c", "ulimit -Sn"]);
        // SAFETY: the hook makes syscalls only.
        unsafe { command.pre_exec(restore_in_child) };
        let output = command.output().unwrap();
        let soft = String::from_utf8(output.stdout).unwrap();
        assert_eq!(soft.trim(), before.rlim_cur.to_string());
    }
}
