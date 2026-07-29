#![forbid(unsafe_code)]

pub mod topology;

/// The externally visible build identity.
///
/// Cargo requires a manifest version even though Denial releases are versioned
/// by their signed Git tag. Packaging sets `DENIAL_BUILD_VERSION` from that
/// tag; ordinary source builds deliberately identify themselves as
/// development builds.
pub const VERSION: &str = match option_env!("DENIAL_BUILD_VERSION") {
    Some(version) => version,
    None => "development",
};
