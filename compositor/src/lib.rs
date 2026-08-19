#![forbid(unsafe_code)]

use std::{fs, path::PathBuf, sync::OnceLock};

pub mod topology;
#[cfg(feature = "kms")]
pub mod volition;

/// The identity compiled into a candidate binary.
///
/// Public release versions are deliberately not compiled into Denial. A
/// production candidate is built on `main` before its version tag exists, then
/// promotion installs the tag-derived version beside the unchanged binaries.
pub const BUILD_IDENTITY: &str = match option_env!("DENIAL_BUILD_VERSION") {
    Some(version) => version,
    None => "development",
};

/// Flutter Engine generation accepted by this compositor build.
pub const FLUTTER_ENGINE_ABI: &str = "3.44.7.denial1";

static RUNTIME_VERSION: OnceLock<String> = OnceLock::new();

/// Return the externally visible Denial version.
///
/// Installed packages carry `share/denial/version` below the executable's
/// prefix. Source and candidate binaries have no such file and report their
/// compiled build identity instead.
pub fn version() -> &'static str {
    RUNTIME_VERSION
        .get_or_init(|| {
            installed_version_path()
                .and_then(|path| fs::read_to_string(path).ok())
                .map(|contents| contents.trim().to_owned())
                .filter(|value| valid_release_version(value))
                .unwrap_or_else(|| BUILD_IDENTITY.to_owned())
        })
        .as_str()
}

fn installed_version_path() -> Option<PathBuf> {
    let executable = std::env::current_exe().ok()?;
    let prefix = executable.parent()?.parent()?;
    Some(prefix.join("share/denial/version"))
}

fn valid_release_version(value: &str) -> bool {
    let mut components = value.split('.');
    let valid_component = |component: &str| {
        !component.is_empty() && component.bytes().all(|byte| byte.is_ascii_digit())
    };
    matches!(
        (
            components.next(),
            components.next(),
            components.next(),
            components.next(),
        ),
        (Some(major), Some(minor), Some(patch), None)
            if valid_component(major)
                && valid_component(minor)
                && valid_component(patch)
    )
}

#[cfg(test)]
mod tests {
    use super::valid_release_version;

    #[test]
    fn accepts_only_numeric_three_component_release_versions() {
        assert!(valid_release_version("0.2.3"));
        assert!(valid_release_version("12.0.104"));
        assert!(!valid_release_version("v0.2.3"));
        assert!(!valid_release_version("0.2"));
        assert!(!valid_release_version("0.2.3-dev"));
        assert!(!valid_release_version(""));
    }
}
