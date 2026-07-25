use std::borrow::Cow;

use smithay::backend::input::KeyState;
use smithay::desktop::PopupKind;
use smithay::input::Seat;
use smithay::input::keyboard::{KeyboardTarget, KeysymHandle, ModifiersState};
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::utils::{IsAlive, Serial};
use smithay::wayland::seat::WaylandFocus;
use smithay::xwayland::X11Surface;

use super::super::RuntimeState;

/// A keyboard target must preserve the X11 identity of Xwayland windows.
///
/// Forwarding keyboard focus directly to the associated `wl_surface` is
/// enough for `wl_keyboard`, but bypasses `X11Surface::enter` and therefore
/// never performs the ICCCM `SetInputFocus`/`WM_TAKE_FOCUS` handshake.
#[derive(Clone, Debug, PartialEq)]
#[allow(clippy::large_enum_variant)]
pub(crate) enum KeyboardFocusTarget {
    Wayland(WlSurface),
    X11(X11Surface),
}

impl From<WlSurface> for KeyboardFocusTarget {
    fn from(surface: WlSurface) -> Self {
        Self::Wayland(surface)
    }
}

impl From<PopupKind> for KeyboardFocusTarget {
    fn from(popup: PopupKind) -> Self {
        Self::Wayland(popup.wl_surface().clone())
    }
}

impl From<KeyboardFocusTarget> for WlSurface {
    fn from(target: KeyboardFocusTarget) -> Self {
        match target {
            KeyboardFocusTarget::Wayland(surface) => surface,
            KeyboardFocusTarget::X11(surface) => surface
                .wl_surface()
                .expect("focused X11 window has no associated wl_surface"),
        }
    }
}

impl IsAlive for KeyboardFocusTarget {
    fn alive(&self) -> bool {
        match self {
            Self::Wayland(surface) => surface.alive(),
            Self::X11(surface) => surface.alive(),
        }
    }
}

impl KeyboardFocusTarget {
    fn inner(&self) -> &dyn KeyboardTarget<RuntimeState> {
        match self {
            Self::Wayland(surface) => surface,
            Self::X11(surface) => surface,
        }
    }
}

impl KeyboardTarget<RuntimeState> for KeyboardFocusTarget {
    fn enter(
        &self,
        seat: &Seat<RuntimeState>,
        data: &mut RuntimeState,
        keys: Vec<KeysymHandle<'_>>,
        serial: Serial,
    ) {
        self.inner().enter(seat, data, keys, serial);
    }

    fn leave(&self, seat: &Seat<RuntimeState>, data: &mut RuntimeState, serial: Serial) {
        self.inner().leave(seat, data, serial);
    }

    fn key(
        &self,
        seat: &Seat<RuntimeState>,
        data: &mut RuntimeState,
        key: KeysymHandle<'_>,
        state: KeyState,
        serial: Serial,
        time: u32,
    ) {
        self.inner().key(seat, data, key, state, serial, time);
    }

    fn modifiers(
        &self,
        seat: &Seat<RuntimeState>,
        data: &mut RuntimeState,
        modifiers: ModifiersState,
        serial: Serial,
    ) {
        self.inner().modifiers(seat, data, modifiers, serial);
    }
}

impl WaylandFocus for KeyboardFocusTarget {
    fn wl_surface(&self) -> Option<Cow<'_, WlSurface>> {
        match self {
            Self::Wayland(surface) => Some(Cow::Borrowed(surface)),
            Self::X11(surface) => surface.wl_surface().map(Cow::Owned),
        }
    }
}
