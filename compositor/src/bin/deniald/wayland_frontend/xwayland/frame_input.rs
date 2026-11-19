//! Input holes of X11 windows inside their window-manager frames.
//!
//! The window manager puts every managed X11 window into a frame window, and
//! Xwayland gives the Wayland surface the frame's input region, not the
//! window's. A window that lets clicks through part of itself with a SHAPE
//! input region (a desktop pet, an on-screen widget) lost those holes. This
//! copies the window's input region onto its frame on the X server itself, on
//! a connection of its own, so pointer motion costs the compositor nothing.

use std::collections::HashMap;
use std::error::Error;
use std::sync::Arc;

use smithay::utils::x11rb::X11Source;
use x11rb::connection::Connection;
use x11rb::errors::ConnectionError;
use x11rb::protocol::shape::{ConnectionExt as _, SK, SO};
use x11rb::protocol::xproto::{
    AtomEnum, ChangeWindowAttributesAux, ConnectionExt as _, CreateWindowAux, EventMask, Window,
    WindowClass,
};
use x11rb::protocol::{ErrorKind, Event};
use x11rb::rust_connection::RustConnection;

/// A managed window and the frame that carries its input region.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Framed {
    frame: Window,
    width: u16,
    height: u16,
}

pub(super) struct FrameInputShapes {
    connection: Arc<RustConnection>,
    windows: HashMap<Window, Framed>,
}

impl FrameInputShapes {
    /// Connects to Xwayland. The returned source delivers this connection's
    /// events and must be inserted into the event loop.
    pub(super) fn connect(display: u32) -> Result<(Self, X11Source), Box<dyn Error>> {
        let (connection, screen) = x11rb::connect(Some(&format!(":{display}")))?;
        let version = connection.shape_query_version()?.reply()?;
        // Input regions arrived with SHAPE 1.1.
        if (version.major_version, version.minor_version) < (1, 1) {
            return Err("Xwayland has no SHAPE input regions".into());
        }
        // The event thread is woken for shutdown by a message to this window.
        let wake = connection.generate_id()?;
        let root = connection.setup().roots[screen].root;
        connection.create_window(
            0,
            wake,
            root,
            0,
            0,
            1,
            1,
            0,
            WindowClass::INPUT_ONLY,
            0,
            &CreateWindowAux::new(),
        )?;
        connection.flush()?;
        let connection = Arc::new(connection);
        let source = X11Source::new(Arc::clone(&connection), wake, AtomEnum::WM_NAME.into());
        Ok((
            Self {
                connection,
                windows: HashMap::new(),
            },
            source,
        ))
    }

    /// Starts following `window`, now mapped inside `frame` at `size`. Sends
    /// requests only: the compositor thread never waits on Xwayland, which
    /// may itself be waiting on the compositor.
    pub(super) fn follow(
        &mut self,
        window: Window,
        frame: Window,
        (width, height): (u16, u16),
    ) -> Result<(), ConnectionError> {
        // Event masks are per connection: this does not change what the
        // window manager or the client itself receives.
        self.connection.shape_select_input(window, true)?;
        self.connection.change_window_attributes(
            window,
            &ChangeWindowAttributesAux::new().event_mask(EventMask::STRUCTURE_NOTIFY),
        )?;
        self.windows.insert(
            window,
            Framed {
                frame,
                width,
                height,
            },
        );
        self.copy(window, frame)
    }

    /// Stops following `window`. Its frame is destroyed on unmap.
    pub(super) fn forget(&mut self, window: Window) {
        self.windows.remove(&window);
    }

    pub(super) fn handle(&mut self, event: Event) -> Result<(), ConnectionError> {
        let window = match event {
            Event::ShapeNotify(event) if matches!(event.shape_kind, SK::INPUT | SK::BOUNDING) => {
                event.affected_window
            }
            // An unshaped window's input region is its whole rectangle, so a
            // copy is out of date once the window changes size. Moves, which
            // also arrive here, change nothing.
            Event::ConfigureNotify(event) => {
                let Some(framed) = self.windows.get_mut(&event.window) else {
                    return Ok(());
                };
                if (framed.width, framed.height) == (event.width, event.height) {
                    return Ok(());
                }
                framed.width = event.width;
                framed.height = event.height;
                event.window
            }
            Event::DestroyNotify(event) => {
                self.forget(event.window);
                return Ok(());
            }
            // The window or its frame can go before a queued copy runs.
            Event::Error(error) if error.error_kind == ErrorKind::Window => return Ok(()),
            Event::Error(error) => {
                tracing::warn!(?error, "an X11 input region copy failed");
                return Ok(());
            }
            _ => return Ok(()),
        };
        match self.windows.get(&window) {
            Some(framed) => self.copy(window, framed.frame),
            None => Ok(()),
        }
    }

    /// The window's effective input region is its input shape clipped by its
    /// bounding shape; the frame gets exactly that.
    fn copy(&self, window: Window, frame: Window) -> Result<(), ConnectionError> {
        self.connection
            .shape_combine(SO::SET, SK::INPUT, SK::INPUT, frame, 0, 0, window)?;
        self.connection.shape_combine(
            SO::INTERSECT,
            SK::INPUT,
            SK::BOUNDING,
            frame,
            0,
            0,
            window,
        )?;
        self.connection.flush()
    }
}
