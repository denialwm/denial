#![deny(unsafe_op_in_unsafe_fn)]
#![deny(clippy::undocumented_unsafe_blocks)]

//! Standalone Wayland Flutter host with optional native application extensions.
//! Existing applications use [`run`] and allocate no external textures.

mod app;
mod config;
mod egl;
mod file_chooser;
mod ime;
mod platform;
mod renderer;
mod texture;
mod touch;

use std::sync::Arc;

pub use config::Config;
pub use denial_flutter_engine;
pub use texture::{RgbaFrame, RgbaTexture};

/// Handles an application's own platform channels. Return `None` for channels
/// or methods the application does not implement. Built-in plugins run first.
/// Calls run on the window event loop: enqueue work instead of blocking it.
pub trait PlatformMessageHandler: Send + Sync + 'static {
    fn handle(&self, channel: &str, data: &[u8]) -> Option<Vec<u8>>;
}

#[derive(Default)]
pub struct AppExtension {
    pub textures: Vec<RgbaTexture>,
    pub platform_handler: Option<Arc<dyn PlatformMessageHandler>>,
}

pub fn run(config: Config) -> Result<(), Box<dyn std::error::Error>> {
    run_with_extension(config, AppExtension::default())
}

pub fn run_with_extension(
    config: Config,
    extension: AppExtension,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut ids = std::collections::HashSet::new();
    for texture in &extension.textures {
        if !ids.insert(texture.id()) {
            return Err(format!("duplicate external texture ID {}", texture.id()).into());
        }
    }
    app::run(config, extension)
}

/// Apply the runner's process-local Mesa workaround before starting graphics.
///
/// # Safety
/// Call before starting any threads, Flutter, EGL, or other graphics libraries.
pub unsafe fn prepare_graphics_environment() {
    let mut extensions = std::env::var_os("MESA_EXTENSION_OVERRIDE").unwrap_or_default();
    extensions.push(" -GL_EXT_shader_framebuffer_fetch");
    // SAFETY: the caller guarantees there are no concurrent environment readers.
    unsafe { std::env::set_var("MESA_EXTENSION_OVERRIDE", extensions) };
}

// Read-only reuse of Denial's text editor needs this small value-type adapter.
mod wayland_frontend {
    pub(crate) mod input_method {
        #[derive(Clone, Debug, Default, Eq, PartialEq)]
        pub(crate) struct InputMethodTransaction {
            pub commit_string: Option<String>,
            pub preedit_string: Option<(String, i32, i32)>,
            pub delete_surrounding: Option<(u32, u32)>,
        }
    }
}
