use std::borrow::Cow;

use smithay::backend::input::{InputTime, KeyState};
use smithay::desktop::PopupKind;
use smithay::input::dnd::{DndFocus, OfferData, Source};
use smithay::input::keyboard::{KeyboardHandle, KeyboardTarget, KeysymHandle, ModifiersState};
use smithay::input::pointer::{
    AxisFrame, ButtonEvent, GestureHoldBeginEvent, GestureHoldEndEvent, GesturePinchBeginEvent,
    GesturePinchEndEvent, GesturePinchUpdateEvent, GestureSwipeBeginEvent, GestureSwipeEndEvent,
    GestureSwipeUpdateEvent, MotionEvent, PointerTarget, RelativeMotionEvent,
};
use smithay::input::touch::{
    DownEvent, FrameMarker, MotionEvent as TouchMotionEvent, OrientationEvent, ShapeEvent,
    TouchTarget, UpEvent,
};
use smithay::input::{Seat, SeatHandler};
use smithay::reexports::wayland_server::DisplayHandle;
use smithay::reexports::wayland_server::Resource;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::utils::{IsAlive, Serial};
use smithay::utils::{Logical, Point};
use smithay::wayland::compositor::with_states;
use smithay::wayland::seat::WaylandFocus;
use smithay::wayland::shell::xdg::XdgToplevelSurfaceData;
#[cfg(feature = "xwayland")]
use smithay::xwayland::X11Surface;
#[cfg(feature = "xwayland")]
use smithay::xwayland::xwm::XwmOfferData;
use std::sync::Arc;

use super::super::RuntimeState;
use super::input_timestamps::{self, InputDevice};

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
        time: InputTime,
    ) {
        match self {
            Self::Wayland(surface) => {
                input_timestamps::send(data, seat, InputDevice::Keyboard, surface, time);
                surface.key(seat, data, key, state, serial, time);
            }
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

/// The pointer and touch focus: a client surface.
///
/// Smithay writes `wl_pointer` and `wl_touch` events for a `WlSurface`
/// itself. This wrapper sends the `zwp_input_timestamps_v1` time first, to
/// the same client, and then forwards to Smithay.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct ClientSurface(pub(crate) WlSurface);

impl ClientSurface {
    fn is_xwayland(&self) -> bool {
        self.0
            .client()
            .is_some_and(|client| super::xwayland::is_client(&client))
    }
}

impl From<WlSurface> for ClientSurface {
    fn from(surface: WlSurface) -> Self {
        Self(surface)
    }
}

impl From<KeyboardFocusTarget> for ClientSurface {
    fn from(target: KeyboardFocusTarget) -> Self {
        Self(target.into())
    }
}

impl std::ops::Deref for ClientSurface {
    type Target = WlSurface;

    fn deref(&self) -> &WlSurface {
        &self.0
    }
}

impl IsAlive for ClientSurface {
    fn alive(&self) -> bool {
        self.0.alive()
    }
}

impl WaylandFocus for ClientSurface {
    fn wl_surface(&self) -> Option<Cow<'_, WlSurface>> {
        Some(Cow::Borrowed(&self.0))
    }
}

impl PointerTarget<RuntimeState> for ClientSurface {
    fn enter(&self, seat: &Seat<RuntimeState>, data: &mut RuntimeState, event: &MotionEvent) {
        PointerTarget::enter(&self.0, seat, data, event);
    }

    fn motion(&self, seat: &Seat<RuntimeState>, data: &mut RuntimeState, event: &MotionEvent) {
        input_timestamps::send(data, seat, InputDevice::Pointer, &self.0, event.time);
        if !pointer_frame_has_relative(data) && self.is_xwayland() {
            // Xwayland feeds X11 from two pointer devices: a relative one for
            // frames that carry relative motion, an absolute one for frames
            // that carry a position alone. One such frame at the end of an
            // X11 drag left its master pointer describing absolute axes while
            // it delivered relative steps, and a game reading raw input took
            // every step for a screen position. So a position never reaches
            // Xwayland alone: it gets a relative step of zero first.
            PointerTarget::relative_motion(
                self,
                seat,
                data,
                &RelativeMotionEvent {
                    delta: Point::default(),
                    delta_unaccel: Point::default(),
                    time: event.time,
                },
            );
        }
        PointerTarget::motion(&self.0, seat, data, event);
    }

    fn relative_motion(
        &self,
        seat: &Seat<RuntimeState>,
        data: &mut RuntimeState,
        event: &RelativeMotionEvent,
    ) {
        set_pointer_frame_has_relative(data, true);
        PointerTarget::relative_motion(&self.0, seat, data, event);
    }

    fn button(&self, seat: &Seat<RuntimeState>, data: &mut RuntimeState, event: &ButtonEvent) {
        input_timestamps::send(data, seat, InputDevice::Pointer, &self.0, event.time);
        PointerTarget::button(&self.0, seat, data, event);
    }

    fn axis(&self, seat: &Seat<RuntimeState>, data: &mut RuntimeState, frame: AxisFrame) {
        // The timestamp belongs to the frame's first timed event.
        input_timestamps::send(data, seat, InputDevice::Pointer, &self.0, frame.time);
        PointerTarget::axis(&self.0, seat, data, frame);
    }

    fn frame(&self, seat: &Seat<RuntimeState>, data: &mut RuntimeState) {
        set_pointer_frame_has_relative(data, false);
        PointerTarget::frame(&self.0, seat, data);
    }

    fn gesture_swipe_begin(
        &self,
        seat: &Seat<RuntimeState>,
        data: &mut RuntimeState,
        event: &GestureSwipeBeginEvent,
    ) {
        PointerTarget::gesture_swipe_begin(&self.0, seat, data, event);
    }

    fn gesture_swipe_update(
        &self,
        seat: &Seat<RuntimeState>,
        data: &mut RuntimeState,
        event: &GestureSwipeUpdateEvent,
    ) {
        PointerTarget::gesture_swipe_update(&self.0, seat, data, event);
    }

    fn gesture_swipe_end(
        &self,
        seat: &Seat<RuntimeState>,
        data: &mut RuntimeState,
        event: &GestureSwipeEndEvent,
    ) {
        PointerTarget::gesture_swipe_end(&self.0, seat, data, event);
    }

    fn gesture_pinch_begin(
        &self,
        seat: &Seat<RuntimeState>,
        data: &mut RuntimeState,
        event: &GesturePinchBeginEvent,
    ) {
        PointerTarget::gesture_pinch_begin(&self.0, seat, data, event);
    }

    fn gesture_pinch_update(
        &self,
        seat: &Seat<RuntimeState>,
        data: &mut RuntimeState,
        event: &GesturePinchUpdateEvent,
    ) {
        PointerTarget::gesture_pinch_update(&self.0, seat, data, event);
    }

    fn gesture_pinch_end(
        &self,
        seat: &Seat<RuntimeState>,
        data: &mut RuntimeState,
        event: &GesturePinchEndEvent,
    ) {
        PointerTarget::gesture_pinch_end(&self.0, seat, data, event);
    }

    fn gesture_hold_begin(
        &self,
        seat: &Seat<RuntimeState>,
        data: &mut RuntimeState,
        event: &GestureHoldBeginEvent,
    ) {
        PointerTarget::gesture_hold_begin(&self.0, seat, data, event);
    }

    fn gesture_hold_end(
        &self,
        seat: &Seat<RuntimeState>,
        data: &mut RuntimeState,
        event: &GestureHoldEndEvent,
    ) {
        PointerTarget::gesture_hold_end(&self.0, seat, data, event);
    }

    fn leave(
        &self,
        seat: &Seat<RuntimeState>,
        data: &mut RuntimeState,
        serial: Serial,
        time: InputTime,
    ) {
        set_pointer_frame_has_relative(data, false);
        PointerTarget::leave(&self.0, seat, data, serial, time);
    }
}

fn pointer_frame_has_relative(state: &RuntimeState) -> bool {
    state
        .wayland
        .as_ref()
        .is_some_and(|frontend| frontend.pointer_frame_has_relative)
}

fn set_pointer_frame_has_relative(state: &mut RuntimeState, value: bool) {
    if let Some(frontend) = state.wayland.as_mut() {
        frontend.pointer_frame_has_relative = value;
    }
}

impl TouchTarget<RuntimeState> for ClientSurface {
    fn down(&self, seat: &Seat<RuntimeState>, data: &mut RuntimeState, event: &DownEvent) {
        input_timestamps::send(data, seat, InputDevice::Touch, &self.0, event.time);
        TouchTarget::down(&self.0, seat, data, event);
    }

    fn up(&self, seat: &Seat<RuntimeState>, data: &mut RuntimeState, event: &UpEvent) {
        input_timestamps::send(data, seat, InputDevice::Touch, &self.0, event.time);
        TouchTarget::up(&self.0, seat, data, event);
    }

    fn motion(&self, seat: &Seat<RuntimeState>, data: &mut RuntimeState, event: &TouchMotionEvent) {
        input_timestamps::send(data, seat, InputDevice::Touch, &self.0, event.time);
        TouchTarget::motion(&self.0, seat, data, event);
    }

    fn frame(&self, seat: &Seat<RuntimeState>, data: &mut RuntimeState, marker: FrameMarker) {
        TouchTarget::frame(&self.0, seat, data, marker);
    }

    fn cancel(&self, seat: &Seat<RuntimeState>, data: &mut RuntimeState, marker: FrameMarker) {
        TouchTarget::cancel(&self.0, seat, data, marker);
    }

    fn shape(&self, seat: &Seat<RuntimeState>, data: &mut RuntimeState, event: &ShapeEvent) {
        TouchTarget::shape(&self.0, seat, data, event);
    }

    fn orientation(
        &self,
        seat: &Seat<RuntimeState>,
        data: &mut RuntimeState,
        event: &OrientationEvent,
    ) {
        TouchTarget::orientation(&self.0, seat, data, event);
    }

    fn last_frame(
        &self,
        seat: &Seat<RuntimeState>,
        data: &mut RuntimeState,
    ) -> Option<FrameMarker> {
        TouchTarget::last_frame(&self.0, seat, data)
    }
}

/// The offer a drag makes to a client surface: a `wl_data_offer`, or XDND
/// messages when the surface is an X11 window's.
pub(crate) enum ClientOffer<S: Source> {
    Wayland(<WlSurface as DndFocus<RuntimeState>>::OfferData<S>),
    #[cfg(feature = "xwayland")]
    X11(X11Surface, XwmOfferData<S>),
}

impl<S: Source> OfferData for ClientOffer<S> {
    fn disable(&self) {
        match self {
            Self::Wayland(offer) => offer.disable(),
            #[cfg(feature = "xwayland")]
            Self::X11(_, offer) => offer.disable(),
        }
    }

    fn drop(&self) {
        match self {
            Self::Wayland(offer) => OfferData::drop(offer),
            #[cfg(feature = "xwayland")]
            Self::X11(_, offer) => OfferData::drop(offer),
        }
    }

    fn validated(&self) -> bool {
        match self {
            Self::Wayland(offer) => offer.validated(),
            #[cfg(feature = "xwayland")]
            Self::X11(_, offer) => offer.validated(),
        }
    }
}

/// The X11 window whose surface this is, if any.
///
/// Pointer events reach an X11 window through its `wl_surface`, and Xwayland
/// turns them into X11 events. A drag cannot go that way: an X11 window takes
/// drops only through XDND, which Smithay speaks for an `X11Surface`. It also
/// keeps an X11 client's own drag going: Smithay covers the X11 screen while
/// such a drag is over a Wayland window, and uncovers it when the drag enters
/// an `X11Surface`.
#[cfg(feature = "xwayland")]
fn x11_window(state: &RuntimeState, surface: &WlSurface) -> Option<X11Surface> {
    state.wayland.as_ref()?.space.elements().find_map(|window| {
        let x11 = window.x11_surface()?;
        (x11.wl_surface().as_ref() == Some(surface)).then(|| x11.clone())
    })
}

impl DndFocus<RuntimeState> for ClientSurface {
    type OfferData<S: Source> = ClientOffer<S>;

    fn enter<S: Source>(
        &self,
        data: &mut RuntimeState,
        dh: &DisplayHandle,
        source: Arc<S>,
        seat: &Seat<RuntimeState>,
        location: Point<f64, Logical>,
        serial: &Serial,
    ) -> Option<Self::OfferData<S>> {
        // A drag that an X11 app starts begins inside the X11 window manager,
        // with no request Denial sees: the first window it enters, the one it
        // began in, is where Denial learns of it.
        #[cfg(feature = "flutter")]
        if let Some(frontend) = data.wayland.as_mut() {
            frontend.release_pointer_capture_for_drag();
        }
        #[cfg(feature = "xwayland")]
        if let Some(x11) = x11_window(data, &self.0) {
            return DndFocus::enter(&x11, data, dh, source, seat, location, serial)
                .map(|offer| ClientOffer::X11(x11, offer));
        }
        DndFocus::enter(&self.0, data, dh, source, seat, location, serial).map(ClientOffer::Wayland)
    }

    fn motion<S: Source>(
        &self,
        data: &mut RuntimeState,
        offer: Option<&mut Self::OfferData<S>>,
        seat: &Seat<RuntimeState>,
        location: Point<f64, Logical>,
        time: InputTime,
    ) {
        match offer {
            Some(ClientOffer::Wayland(offer)) => {
                DndFocus::motion(&self.0, data, Some(offer), seat, location, time);
            }
            #[cfg(feature = "xwayland")]
            Some(ClientOffer::X11(x11, offer)) => {
                DndFocus::motion(&*x11, data, Some(offer), seat, location, time);
            }
            None => {
                #[cfg(feature = "xwayland")]
                if let Some(x11) = x11_window(data, &self.0) {
                    DndFocus::motion::<S>(&x11, data, None, seat, location, time);
                    return;
                }
                DndFocus::motion::<S>(&self.0, data, None, seat, location, time);
            }
        }
    }

    fn leave<S: Source>(
        &self,
        data: &mut RuntimeState,
        offer: Option<&mut Self::OfferData<S>>,
        seat: &Seat<RuntimeState>,
    ) {
        match offer {
            Some(ClientOffer::Wayland(offer)) => DndFocus::leave(&self.0, data, Some(offer), seat),
            #[cfg(feature = "xwayland")]
            Some(ClientOffer::X11(x11, offer)) => DndFocus::leave(&*x11, data, Some(offer), seat),
            None => {
                #[cfg(feature = "xwayland")]
                if let Some(x11) = x11_window(data, &self.0) {
                    DndFocus::leave::<S>(&x11, data, None, seat);
                    return;
                }
                DndFocus::leave::<S>(&self.0, data, None, seat);
            }
        }
    }

    fn drop<S: Source>(
        &self,
        data: &mut RuntimeState,
        offer: Option<&mut Self::OfferData<S>>,
        seat: &Seat<RuntimeState>,
    ) {
        match offer {
            Some(ClientOffer::Wayland(offer)) => DndFocus::drop(&self.0, data, Some(offer), seat),
            #[cfg(feature = "xwayland")]
            Some(ClientOffer::X11(x11, offer)) => DndFocus::drop(&*x11, data, Some(offer), seat),
            None => {
                #[cfg(feature = "xwayland")]
                if let Some(x11) = x11_window(data, &self.0) {
                    DndFocus::drop::<S>(&x11, data, None, seat);
                    return;
                }
                DndFocus::drop::<S>(&self.0, data, None, seat);
            }
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
        let seat = state.frontend().seat.clone();
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
        state.frontend_mut().shell_keyboard_focus = focus;
        return;
    }
    keyboard.set_focus(state, focus, serial);
}

#[cfg(feature = "flutter")]
pub(in super::super) fn suspend_keyboard_focus_for_shell(state: &mut RuntimeState) {
    let keyboard = state
        .frontend()
        .seat
        .get_keyboard()
        .expect("seat has no keyboard");
    let focus = keyboard
        .current_focus()
        .filter(|focus| focus.alive() && !matches!(focus, KeyboardFocusTarget::Flutter));
    state.frontend_mut().shell_keyboard_focus = focus;

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
        .frontend()
        .seat
        .get_keyboard()
        .expect("seat has no keyboard");
    let focus = state
        .frontend_mut()
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
