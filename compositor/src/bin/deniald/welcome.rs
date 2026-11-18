//! Built-in onboarding startup and initial placement policy.
//!
//! Welcome is Settings, the GPUI application from denial-apps, started with
//! `--welcome`: it names its window by this application id.

pub(super) const APP_ID: &str = "org.denialwm.Welcome";

#[cfg(feature = "flutter")]
pub(super) fn launch_arguments() -> Option<Vec<String>> {
    let config = std::env::var_os("XDG_CONFIG_HOME")
        .map(std::path::PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| {
            std::env::var_os("HOME").map(|home| std::path::PathBuf::from(home).join(".config"))
        });
    if config.is_some_and(|root| root.join("denial/welcome").is_file()) {
        return None;
    }
    Some(vec![
        std::env::var("DENIAL_SETTINGS_BINARY")
            .ok()
            .filter(|path| !path.is_empty())
            .unwrap_or_else(|| "denial-settings".to_owned()),
        "--welcome".to_owned(),
        "--autostart".to_owned(),
    ])
}

pub(super) fn centers_on_open(app_id: &str, tiled: bool, has_parent: bool) -> bool {
    app_id == APP_ID && !tiled && !has_parent
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn welcome_centers_only_as_a_stacking_toplevel() {
        assert!(centers_on_open(APP_ID, false, false));
        assert!(!centers_on_open(APP_ID, true, false));
        assert!(!centers_on_open(APP_ID, false, true));
        assert!(!centers_on_open("org.denialwm.Settings", false, false));
    }
}
