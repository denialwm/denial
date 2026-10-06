//! Denial environment-variable compatibility helpers.

use std::env::{self, VarError};

const CANONICAL_PREFIX: &str = "DENIAL_";
const LEGACY_PREFIX: &str = "DENIA_";

/// Read a canonical `DENIAL_*` variable with its transitional `DENIA_*`
/// spelling as a fallback.
pub fn var(name: &str) -> Result<String, VarError> {
    match env::var(name) {
        Err(VarError::NotPresent) => {
            legacy_name(name).map_or_else(|| Err(VarError::NotPresent), |legacy| env::var(legacy))
        }
        result => result,
    }
}

/// Read a Denial boolean flag. The canonical spelling takes precedence.
pub fn flag(name: &str) -> bool {
    var(name).is_ok_and(|value| parse_flag(&value))
}

fn legacy_name(name: &str) -> Option<String> {
    name.strip_prefix(CANONICAL_PREFIX)
        .map(|suffix| format!("{LEGACY_PREFIX}{suffix}"))
}

fn parse_flag(value: &str) -> bool {
    matches!(
        value.trim().to_ascii_lowercase().as_str(),
        "1" | "true" | "yes" | "on"
    )
}
