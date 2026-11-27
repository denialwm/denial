#![deny(unsafe_op_in_unsafe_fn)]
#![deny(clippy::undocumented_unsafe_blocks)]

pub mod client_release;
pub mod hotplug_transaction;
pub mod kms_state;
pub mod kms_render;
#[cfg(feature = "flutter")]
pub mod gpu_transfer;
#[cfg(feature = "flutter")]
pub mod drm_vulkan;
pub mod egl_context;
