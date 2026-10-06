use std::borrow::Cow;

use smithay::backend::input::KeyState;
use smithay::desktop::PopupKind;
use smithay::input::keyboard::{KeyboardHandle, KeyboardTarget, KeysymHandle, ModifiersState};
use smithay::input::{Seat, SeatHandler};
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::utils::{IsAlive, Serial};
use smithay::wayland::compositor::with_states;
use smithay::wayland::seat::WaylandFocus;
use smithay::wayland::shell::xdg::XdgToplevelSurfaceData;
#[cfg(feature = "xwayland")]
use smithay::xwayland::X11Surface;

use super::super::RuntimeState;

/// A keyboard target must preserve the X11 identity of Xwayland windows.
///
/// Forwarding keyboard focus directly to the associated `wl_surface` is
/// enough for `wl_keyboard`, but bypasses `X11Surface::enter` and therefore
/// never performs the ICCCM `SetInputFocus`/`WM_TAKE_FOCUS` handshake.
///
/// Flutter is compositor-owned rather than a Wayland client, but it is still
/// a seat keyboard target. Keeping it in the same focus graph is important:
/// input-method grabs can then return unhandled keys through the seat instead
/// of relying on a parallel focusless delivery path.
#[derive(Clone, Debug, PartialEq)]
#[allow(clippy::large_enum_variant)]
pub(crate) enum KeyboardFocusTarget {
    Wayland(WlSurface),
    #[cfg(feature = "xwayland")]
    X11(X11Surface),
    #[cfg(feature = "flutter")]
    Flutter,
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

impl KeyboardFocusTarget {
    pub(super) fn seat_focus_kind(&self) -> super::SeatFocusKind {
        match self {
            Self::Wayland(_) => super::SeatFocusKind::Wayland,
            #[cfg(feature = "xwayland")]
            Self::X11(_) => super::SeatFocusKind::Xwayland,
            #[cfg(feature = "flutter")]
            Self::Flutter => super::SeatFocusKind::None,
        }
    }

    pub(super) fn window_metadata(&self) -> Option<(String, String)> {
        match self {
            Self::Wayland(surface) => with_states(surface, |states| {
                let attributes = states.data_map.get::<XdgToplevelSurfaceData>()?;
                let attributes = attributes
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                Some((
                    attributes.title.clone().unwrap_or_default(),
                    attributes.app_id.clone().unwrap_or_default(),
                ))
            }),
            #[cfg(feature = "xwayland")]
            Self::X11(surface) => Some((surface.title(), surface.class())),
            #[cfg(feature = "flutter")]
            Self::Flutter => None,
        }
    }
}

// Smithay's popup-grab API requires the pointer focus type to be infallibly
// constructible from the keyboard focus type. Popup grabs only contain
// client-owned targets; the compositor-owned Flutter target never crosses
// that boundary.
impl From<KeyboardFocusTarget> for WlSurface {
    fn from(target: KeyboardFocusTarget) -> Self {
        match target {
            KeyboardFocusTarget::Wayland(surface) => surface,
            #[cfg(feature = "xwayland")]
            KeyboardFocusTarget::X11(surface) => surface
                .wl_surface()
                .expect("focused X11 window has no associated wl_surface"),
            #[cfg(feature = "flutter")]
            KeyboardFocusTarget::Flutter => {
                unreachable!("Flutter keyboard focus cannot become a client popup focus")
            }
        }
    }
}

impl IsAlive for KeyboardFocusTarget {
    fn alive(&self) -> bool {
        match self {
            Self::Wayland(surface) => surface.alive(),
            #[cfg(feature = "xwayland")]
            Self::X11(surface) => surface.alive(),
            #[cfg(feature = "flutter")]
            Self::Flutter => true,
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
        match self {
            Self::Wayland(surface) => KeyboardTarget::enter(surface, seat, data, keys, serial),
            #[cfg(feature = "xwayland")]
            Self::X11(surface) => KeyboardTarget::enter(surface, seat, data, keys, serial),
            #[cfg(feature = "flutter")]
            Self::Flutter => {}
        }
    }

    fn leave(&self, seat: &Seat<RuntimeState>, data: &mut RuntimeState, serial: Serial) {
        match self {
            Self::Wayland(surface) => KeyboardTarget::leave(surface, seat, data, serial),
            #[cfg(feature = "xwayland")]
            Self::X11(surface) => KeyboardTarget::leave(surface, seat, data, serial),
            #[cfg(feature = "flutter")]
            Self::Flutter => super::input::leave_focused_flutter_keyboard(data),
        }
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
        match self {
            Self::Wayland(surface) => surface.key(seat, data, key, state, serial, time),
            #[cfg(feature = "xwayland")]
            Self::X11(surface) => surface.key(seat, data, key, state, serial, time),
            #[cfg(feature = "flutter")]
            Self::Flutter => super::input::dispatch_focused_flutter_key(data, key, state),
        }
    }

    fn modifiers(
        &self,
        seat: &Seat<RuntimeState>,
        data: &mut RuntimeState,
        modifiers: ModifiersState,
        serial: Serial,
    ) {
        match self {
            Self::Wayland(surface) => surface.modifiers(seat, data, modifiers, serial),
            #[cfg(feature = "xwayland")]
            Self::X11(surface) => surface.modifiers(seat, data, modifiers, serial),
            #[cfg(feature = "flutter")]
            Self::Flutter => {}
        }
    }
}

impl WaylandFocus for KeyboardFocusTarget {
    fn wl_surface(&self) -> Option<Cow<'_, WlSurface>> {
        match self {
            Self::Wayland(surface) => Some(Cow::Borrowed(surface)),
            #[cfg(feature = "xwayland")]
            Self::X11(surface) => surface.wl_surface().map(Cow::Owned),
            #[cfg(feature = "flutter")]
            Self::Flutter => None,
        }
    }
}

/// Clear the keyboard focus and publish the transition to seat-owned state.
///
/// Smithay reports focus replacements through `SeatHandler::focus_changed`,
/// but an explicit transition to `None` only sends `wl_keyboard.leave`.
/// Denial's text-input broker and data-device focus still need that transition.
pub(super) fn clear_keyboard_focus(
    state: &mut RuntimeState,
    keyboard: &KeyboardHandle<RuntimeState>,
    serial: Serial,
) {
    let had_focus = keyboard.current_focus().is_some();
    keyboard.set_focus(state, None, serial);
    if had_focus && keyboard.current_focus().is_none() {
        let seat = state
            .wayland
            .as_ref()
            .expect("missing Wayland frontend")
            .seat
            .clone();
        <RuntimeState as SeatHandler>::focus_changed(state, &seat, None);
    }
}

/// Request a client keyboard target without violating shell ownership.
///
/// Window activation can race the Flutter layout update which releases an
/// overlay. While the shell still captures the keyboard, retain the newest
/// client target for the handoff instead of sending it an early `enter`.
pub(super) fn request_keyboard_focus(
    state: &mut RuntimeState,
    keyboard: &KeyboardHandle<RuntimeState>,
    focus: Option<KeyboardFocusTarget>,
    serial: Serial,
) {
    #[cfg(feature = "flutter")]
    if state
        .wayland
        .as_ref()
        .is_some_and(|frontend| frontend.text_input.shell_captures_keyboard())
    {
        state
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .shell_keyboard_focus = focus;
        return;
    }
    keyboard.set_focus(state, focus, serial);
}

#[cfg(feature = "flutter")]
pub(in super::super) fn suspend_keyboard_focus_for_shell(state: &mut RuntimeState) {
    let keyboard = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .seat
        .get_keyboard()
        .expect("seat has no keyboard");
    let focus = keyboard
        .current_focus()
        .filter(|focus| focus.alive() && !matches!(focus, KeyboardFocusTarget::Flutter));
    state
        .wayland
        .as_mut()
        .expect("missing Wayland frontend")
        .shell_keyboard_focus = focus;

    keyboard.set_focus(
        state,
        Some(KeyboardFocusTarget::Flutter),
        smithay::utils::SERIAL_COUNTER.next_serial(),
    );
    if keyboard.current_focus() != Some(KeyboardFocusTarget::Flutter) {
        // Popup grabs intentionally reject ordinary focus changes. Shell
        // capture is a compositor focus transfer, so retire such a grab and
        // complete the same seat-focus transition.
        keyboard.unset_grab(state);
        keyboard.set_focus(
            state,
            Some(KeyboardFocusTarget::Flutter),
            smithay::utils::SERIAL_COUNTER.next_serial(),
        );
    }
}

#[cfg(feature = "flutter")]
pub(in super::super) fn restore_shell_keyboard_focus(state: &mut RuntimeState) {
    let keyboard = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .seat
        .get_keyboard()
        .expect("seat has no keyboard");
    let focus = state
        .wayland
        .as_mut()
        .expect("missing Wayland frontend")
        .shell_keyboard_focus
        .take()
        .filter(IsAlive::alive);
    if matches!(
        keyboard.current_focus(),
        None | Some(KeyboardFocusTarget::Flutter)
    ) {
        request_keyboard_focus(
            state,
            &keyboard,
            focus,
            smithay::utils::SERIAL_COUNTER.next_serial(),
        );
    }
}
