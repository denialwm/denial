use super::*;

fn event(value: i16, kind: u8, number: u8) -> [u8; JOYSTICK_EVENT_BYTES] {
    let mut bytes = [0; JOYSTICK_EVENT_BYTES];
    bytes[4..6].copy_from_slice(&value.to_ne_bytes());
    bytes[6] = kind;
    bytes[7] = number;
    bytes
}

#[test]
fn initial_state_and_axis_drift_do_not_fake_activity() {
    let mut axes = JoystickAxes::default();
    assert!(!joystick_events_have_activity(
        &event(1000, JS_EVENT_AXIS | JS_EVENT_INIT, 2),
        &mut axes,
    ));
    assert!(!joystick_events_have_activity(
        &event(1200, JS_EVENT_AXIS, 2),
        &mut axes,
    ));
    assert!(joystick_events_have_activity(
        &event(1700, JS_EVENT_AXIS, 2),
        &mut axes,
    ));
}

#[test]
fn joystick_buttons_are_activity_but_initial_snapshots_are_not() {
    let mut axes = JoystickAxes::default();
    assert!(!joystick_events_have_activity(
        &event(0, JS_EVENT_BUTTON | JS_EVENT_INIT, 0),
        &mut axes,
    ));
    assert!(joystick_events_have_activity(
        &event(1, JS_EVENT_BUTTON, 0),
        &mut axes,
    ));
    assert!(joystick_events_have_activity(
        &event(9000, JS_EVENT_AXIS, 4),
        &mut axes,
    ));
}
