//! Shoulder triggers as touches.
//!
//! A phone's shoulder triggers send KEY_MACRO1 (left) and KEY_MACRO2 (right).
//! They never reach a client as keys: each one presses a finger at the spot
//! the user placed for the app in front, and lifts it on release. The spots
//! live in the settings document, per app id, as fractions of the phone's
//! screen in its current orientation:
//!
//! ```json
//! "phoneTriggers": { "com.example.game": { "left": [0.12, 0.30], "right": [0.88, 0.30] } }
//! ```
//!
//! The finger takes its own touch slot, far above the touchscreen's, so real
//! fingers keep working beside it; to the app it is an ordinary touch.

use smithay::input::touch::{DownEvent, UpEvent};
use smithay::utils::SERIAL_COUNTER;
use smithay::wayland::seat::WaylandFocus;

use super::super::managed_window::ManagedWindow;
use super::*;

/// KEY_MACRO1 and KEY_MACRO2 with the XKB offset: left, then right.
const TRIGGER_KEYS: [u32; 2] = [0x290 + 8, 0x291 + 8];
/// Touch slots of the trigger fingers; libinput's seat slots stay far below.
const TRIGGER_SLOT_BASE: i32 = 0x1000;

/// Which trigger a raw XKB keycode is, if it is one.
pub(super) fn trigger(raw: u32) -> Option<usize> {
    TRIGGER_KEYS.iter().position(|key| *key == raw)
}

/// Presses or lifts the trigger's finger. Returns whether clients need a flush.
pub(super) fn handle(
    state: &mut RuntimeState,
    trigger: usize,
    pressed: bool,
    time: InputTime,
) -> bool {
    let slot = TRIGGER_SLOT_BASE + trigger as i32;
    if !pressed {
        return lift(state, slot, time);
    }
    state.note_user_activity();
    if state.secure_session_locked() || state.frontend().client_touch_routes.contains_key(&slot) {
        return false;
    }
    let Some(position) = trigger_position(state, trigger) else {
        return false;
    };
    // The finger lands where a real one would: on whatever the shell shows
    // there, it presses nothing.
    let InputTarget::Client(route) = state.frontend_mut().input_target(position) else {
        return false;
    };
    let (focus, location) = route.touch_at(position);
    let touch = state
        .frontend()
        .seat
        .get_touch()
        .expect("seat has no touch");
    touch.down(
        state,
        Some(focus),
        &DownEvent {
            slot: Some(slot as u32).into(),
            location,
            serial: SERIAL_COUNTER.next_serial(),
            time,
        },
    );
    touch.frame(state);
    state.frontend_mut().client_touch_routes.insert(slot, route);
    true
}

fn lift(state: &mut RuntimeState, slot: i32, time: InputTime) -> bool {
    // A touch cancel may have ended the contact already.
    if state
        .frontend_mut()
        .client_touch_routes
        .remove(&slot)
        .is_none()
    {
        return false;
    }
    let touch = state
        .frontend()
        .seat
        .get_touch()
        .expect("seat has no touch");
    touch.up(
        state,
        &UpEvent {
            slot: Some(slot as u32).into(),
            serial: SERIAL_COUNTER.next_serial(),
            time,
        },
    );
    touch.frame(state);
    true
}

/// The trigger's spot for the app holding the keyboard focus, in global
/// logical coordinates.
fn trigger_position(state: &RuntimeState, trigger: usize) -> Option<Point<f64, Logical>> {
    let frontend = state.wayland.as_ref()?;
    let focused = frontend.seat.get_keyboard()?.current_focus()?;
    let surface = focused.wl_surface()?;
    let root = frontend.owning_toplevel_surface(&surface)?;
    let window = frontend.window_for_root_surface(&root)?;
    let (_, app_id) = ManagedWindow::new(&window)?.metadata();
    let (x, y) = frontend.settings.trigger_point(&app_id, trigger)?;
    let screen = frontend
        .phone_output()
        .map_or(frontend.touch_bounds, |output| output.logical_geometry)
        .to_f64();
    Some(Point::from((
        screen.loc.x + x * screen.size.w,
        screen.loc.y + y * screen.size.h,
    )))
}
