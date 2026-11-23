//! App-specific performance improvements: behaviour Denial gives one
//! program because that program, not Denial, is wrong. Each entry says what
//! the program does, what Denial does about it and when to remove it.
//!
//! **Chromium-based browsers draw no backdrop.** A Chromium browser that
//! draws its own frame withdraws its opaque region (`set_opaque_region(nil)`)
//! when the session's desktop portal offers a file chooser, which every
//! desktop's portal does (Chromium 156). Its window is opaque apart from its
//! two rounded top corners, but without the region Denial cannot know it
//! and blurs the whole area behind it on every frame, unseen. A Chromium
//! browser root surface that declares no opaque region therefore counts as
//! fully opaque: the shell draws no backdrop for it, and the few corner
//! pixels show what is behind unblurred. Nothing else changes: the composer
//! still covers only what the client declares opaque. With "Use system title
//! bar and borders" Chromium declares its whole window opaque and this never
//! applies. Remove it once Chromium declares its region again.

/// Program file names of Chromium-based browsers, as `/proc/PID/exe` names
/// them for the process that connects to Wayland.
const CHROMIUM_BROWSERS: &[&str] = &[
    "chromium",
    "chrome",
    "brave",
    "msedge",
    "vivaldi-bin",
    "opera",
    "thorium",
];

/// Whether the client connecting from `pid` is a Chromium-based browser.
/// Read once per connection.
pub(super) fn is_chromium_browser(pid: Option<i32>) -> bool {
    pid.and_then(|pid| std::fs::read_link(format!("/proc/{pid}/exe")).ok())
        .and_then(|program| {
            program
                .file_name()
                .map(|name| CHROMIUM_BROWSERS.contains(&&*name.to_string_lossy()))
        })
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn this_test_is_no_chromium_browser() {
        assert!(!is_chromium_browser(Some(std::process::id() as i32)));
        assert!(!is_chromium_browser(None));
    }
}
