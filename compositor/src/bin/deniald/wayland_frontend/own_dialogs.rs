//! Denial's own dialogs: the Polkit agent's authentication and Access
//! dialogs from denial-apps, which open as windows on the desktop.
//!
//! They open on their own, often from a script the user started a while
//! ago, so they must not take the keyboard from whatever the user is typing
//! into: a dialog's window opens unactivated and takes the keyboard once
//! clicked. It opens pinned above every other window, fullscreen ones
//! included, centered on the screen under the pointer.
//!
//! The dialogs are known by their program, read once per connection: the
//! window opens before it names its application id. Another program of the
//! user's could call itself the same; it would gain a pinned window that
//! opens without the keyboard, nothing more.

use std::path::Path;

use smithay::reexports::wayland_server::Resource;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;

use super::handlers::DenialClientState;

/// The file name of the program the dialogs run from, as `/proc/PID/exe`
/// names it: `/usr/lib/denial-apps/polkit` when installed.
const DIALOG_PROGRAM: &str = "polkit";

/// What the kernel appends to `/proc/PID/exe` once a package update replaced
/// the running program's file. The agent starts its dialogs from its own
/// file, so a dialog may run from a replaced one.
const REPLACED: &str = " (deleted)";

/// Whether the client connecting from `pid` is one of Denial's dialogs.
pub(super) fn is_dialog_program(pid: Option<i32>) -> bool {
    pid.and_then(|pid| std::fs::read_link(format!("/proc/{pid}/exe")).ok())
        .is_some_and(|program| names_dialog_program(&program))
}

/// Whether `surface` belongs to one of Denial's dialogs.
pub(super) fn from_dialog(surface: &WlSurface) -> bool {
    surface
        .client()
        .and_then(|client| {
            client
                .get_data::<DenialClientState>()
                .map(|state| state.own_dialog)
        })
        .unwrap_or(false)
}

fn names_dialog_program(program: &Path) -> bool {
    program.file_name().is_some_and(|name| {
        let name = name.to_string_lossy();
        name.strip_suffix(REPLACED).unwrap_or(&name) == DIALOG_PROGRAM
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_dialog_program_is_known_by_its_file_name() {
        assert!(names_dialog_program(Path::new(
            "/usr/lib/denial-apps/polkit"
        )));
        assert!(names_dialog_program(Path::new(
            "/usr/lib/denial-apps/polkit (deleted)"
        )));
        assert!(!names_dialog_program(Path::new("/usr/bin/pkexec")));
        assert!(!names_dialog_program(Path::new("/usr/lib/polkit-1")));
        assert!(!is_dialog_program(Some(std::process::id() as i32)));
        assert!(!is_dialog_program(None));
    }
}
