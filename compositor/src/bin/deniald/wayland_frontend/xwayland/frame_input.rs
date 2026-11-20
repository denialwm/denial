//! Input holes of X11 windows inside their window-manager frames.
//!
//! The window manager puts every managed X11 window into a frame window, and
//! Xwayland gives the Wayland surface the frame's input region, not the
//! window's. A window that lets clicks through part of itself with a SHAPE
//! input region (a desktop pet, an on-screen widget) lost those holes. This
//! copies the window's input region onto its frame on the X server itself, on
//! a connection of its own, so pointer motion costs the compositor nothing.
//!
//! The frame's shape notifications then tell whether that region leaves part
//! of the window's rectangle to what is below. Such a window gets no frame.

use std::collections::HashMap;
use std::error::Error;
use std::sync::Arc;

use smithay::utils::x11rb::X11Source;
use x11rb::connection::{Connection, SequenceNumber};
use x11rb::errors::ConnectionError;
use x11rb::protocol::shape::{ConnectionExt as _, NotifyEvent, SK, SO};
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
    /// The request that finishes the latest copy. The frame's shape
    /// notification for it carries the window's final input region; the one
    /// before it, for the first half of the copy, does not.
    last_copy: SequenceNumber,
    /// The input region leaves part of the window's rectangle uncovered.
    click_through: bool,
}

/// A window whose input region now leaves part of its rectangle to what is
/// below, or no longer does.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct ClickThroughChange {
    pub(super) window: Window,
    pub(super) click_through: bool,
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
        self.connection.shape_select_input(frame, true)?;
        self.connection.change_window_attributes(
            window,
            &ChangeWindowAttributesAux::new().event_mask(EventMask::STRUCTURE_NOTIFY),
        )?;
        let mut framed = Framed {
            frame,
            width,
            height,
            last_copy: 0,
            click_through: false,
        };
        copy(&self.connection, window, &mut framed)?;
        self.windows.insert(window, framed);
        Ok(())
    }

    /// Stops following `window`. Its frame is destroyed on unmap.
    pub(super) fn forget(&mut self, window: Window) {
        self.windows.remove(&window);
    }

    /// Handles one event of this connection. Returns the window whose
    /// click-through state it changed, if any.
    pub(super) fn handle(
        &mut self,
        event: Event,
    ) -> Result<Option<ClickThroughChange>, ConnectionError> {
        let window = match event {
            Event::ShapeNotify(event)
                if event.shape_kind == SK::INPUT
                    && !self.windows.contains_key(&event.affected_window) =>
            {
                return Ok(self.frame_shaped(&event));
            }
            Event::ShapeNotify(event) if matches!(event.shape_kind, SK::INPUT | SK::BOUNDING) => {
                event.affected_window
            }
            // An unshaped window's input region is its whole rectangle, so a
            // copy is out of date once the window changes size. Moves, which
            // also arrive here, change nothing.
            Event::ConfigureNotify(event) => {
                let Some(framed) = self.windows.get_mut(&event.window) else {
                    return Ok(None);
                };
                if (framed.width, framed.height) == (event.width, event.height) {
                    return Ok(None);
                }
                framed.width = event.width;
                framed.height = event.height;
                event.window
            }
            Event::DestroyNotify(event) => {
                self.forget(event.window);
                return Ok(None);
            }
            // The window or its frame can go before a queued copy runs.
            Event::Error(error) if error.error_kind == ErrorKind::Window => return Ok(None),
            Event::Error(error) => {
                tracing::warn!(?error, "an X11 input region copy failed");
                return Ok(None);
            }
            _ => return Ok(None),
        };
        if let Some(framed) = self.windows.get_mut(&window) {
            copy(&self.connection, window, framed)?;
        }
        Ok(None)
    }

    /// A frame's input region changed. Only the notification for the end of
    /// the latest copy carries the window's region.
    fn frame_shaped(&mut self, event: &NotifyEvent) -> Option<ClickThroughChange> {
        let (&window, framed) = self
            .windows
            .iter_mut()
            .find(|(_, framed)| framed.frame == event.affected_window)?;
        // Events carry the low 16 bits of the last request the server read.
        if event.sequence != framed.last_copy as u16 {
            return None;
        }
        let click_through = !covers_window(event, framed.width, framed.height);
        if click_through == framed.click_through {
            return None;
        }
        framed.click_through = click_through;
        Some(ClickThroughChange {
            window,
            click_through,
        })
    }
}

/// The window's effective input region is its input shape clipped by its
/// bounding shape; the frame gets exactly that.
fn copy(
    connection: &RustConnection,
    window: Window,
    framed: &mut Framed,
) -> Result<(), ConnectionError> {
    connection.shape_combine(SO::SET, SK::INPUT, SK::INPUT, framed.frame, 0, 0, window)?;
    let last = connection.shape_combine(
        SO::INTERSECT,
        SK::INPUT,
        SK::BOUNDING,
        framed.frame,
        0,
        0,
        window,
    )?;
    framed.last_copy = last.sequence_number();
    connection.flush()
}

/// Whether a shape whose notification is `event` reaches every edge of a
/// `width` by `height` window. Its extents are the bounds only: a region with
/// a hole inside them still counts as covering.
fn covers_window(event: &NotifyEvent, width: u16, height: u16) -> bool {
    if !event.shaped {
        return true;
    }
    let left = i32::from(event.extents_x);
    let top = i32::from(event.extents_y);
    left <= 0
        && top <= 0
        && left + i32::from(event.extents_width) >= i32::from(width)
        && top + i32::from(event.extents_height) >= i32::from(height)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn notify(shaped: bool, (x, y, width, height): (i16, i16, u16, u16)) -> NotifyEvent {
        NotifyEvent {
            response_type: 0,
            shape_kind: SK::INPUT,
            sequence: 0,
            affected_window: 0,
            extents_x: x,
            extents_y: y,
            extents_width: width,
            extents_height: height,
            server_time: 0,
            shaped,
        }
    }

    #[test]
    fn a_region_short_of_any_edge_lets_clicks_through() {
        assert!(covers_window(&notify(false, (0, 0, 0, 0)), 800, 600));
        assert!(covers_window(&notify(true, (0, 0, 800, 600)), 800, 600));
        assert!(covers_window(&notify(true, (-4, -4, 808, 608)), 800, 600));
        // A desktop pet: only its body takes clicks.
        assert!(!covers_window(&notify(true, (300, 200, 96, 96)), 800, 600));
        assert!(!covers_window(&notify(true, (0, 0, 800, 599)), 800, 600));
        assert!(!covers_window(&notify(true, (1, 0, 799, 600)), 800, 600));
        // An empty region: every click passes through.
        assert!(!covers_window(&notify(true, (0, 0, 0, 0)), 800, 600));
    }
}
