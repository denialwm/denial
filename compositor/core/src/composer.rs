//! Which composer draws output frames.

use std::sync::atomic::AtomicBool;

/// Output frames the Flutter engine can describe are composed with Vulkan
/// instead of the engine's GLES pass, on every GPU rendered in hardware, and
/// the shell renders with Vulkan with them. Where Vulkan cannot open that GPU,
/// or `DENIAL_NO_VULKAN` asks, both stay on GLES.
pub static VULKAN_COMPOSER: AtomicBool = AtomicBool::new(false);
