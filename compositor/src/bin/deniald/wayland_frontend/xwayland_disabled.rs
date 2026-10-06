//! Compile-time-empty Xwayland facade.
//!
//! The rest of the compositor retains one stable interface while this build
//! contains no Smithay Xwayland types, X11 protocol code, or X11 dependency.

use std::ffi::OsString;
use std::os::fd::OwnedFd;

use smithay::desktop::Window;
use smithay::reexports::calloop::EventLoop;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::reexports::wayland_server::{Client, DisplayHandle};
use smithay::wayland::compositor::CompositorClientState;
use smithay::wayland::selection::SelectionTarget;

use super::super::RuntimeState;

#[derive(Default)]
pub(crate) struct XWaylandState;

impl XWaylandState {
    pub(super) fn start(
        _enabled: bool,
        _event_loop: &mut EventLoop<'static, RuntimeState>,
        _display_handle: &DisplayHandle,
        _engine_scale_120: u32,
        _settings: &super::SettingsManager,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        Ok(Self)
    }

    pub(super) fn display_name(&self) -> Option<OsString> {
        None
    }

    pub(super) fn raise_windows(&mut self, _windows: &[Window]) {}

    pub(super) fn publish_selection(
        &mut self,
        _selection: SelectionTarget,
        _mime_types: Option<Vec<String>>,
    ) -> Result<(), String> {
        Ok(())
    }

    pub(super) fn send_selection(
        &mut self,
        _selection: SelectionTarget,
        _mime_type: String,
        _fd: OwnedFd,
    ) -> Result<(), String> {
        Err("Xwayland support is not compiled in".to_owned())
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn take_xembed_event_signal(&self) -> bool {
        false
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn try_xembed_event(&self) -> Option<crate::xembed_tray_protocol::XEmbedTrayEvent> {
        None
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn invoke_xembed(
        &self,
        _command: crate::xembed_tray_protocol::XEmbedTrayCommand,
    ) -> bool {
        false
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn request_xembed_replay(&self) {}
}

pub(super) fn client_compositor_state(_client: &Client) -> Option<&CompositorClientState> {
    None
}

pub(super) fn is_client(_client: &Client) -> bool {
    false
}

pub(super) fn surface_client_scale(_surface: &WlSurface) -> Option<f64> {
    None
}

impl super::WaylandFrontend {
    pub(super) fn set_xwayland_scale(
        &mut self,
        _engine_scale_120: u32,
    ) -> Result<bool, Box<dyn std::error::Error>> {
        Ok(false)
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn publish_xwayland_settings(&mut self) -> Result<(), Box<dyn std::error::Error>> {
        Ok(())
    }

    pub(super) fn reconfigure_x11_for_scale(&self) -> Result<(), Box<dyn std::error::Error>> {
        Ok(())
    }
}
