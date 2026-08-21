use super::*;

const DEVICE: &str = "event-touchpad";

fn update_swipe(
    recognizer: &mut TouchpadGestureRecognizer,
    fingers: u32,
    delta_x: f64,
    delta_y: f64,
) -> Option<ShortcutGesture> {
    recognizer.begin_swipe(DEVICE, fingers);
    recognizer.update_swipe(DEVICE, delta_x, delta_y)
}

#[test]
fn three_finger_swipe_up_opens_overview_during_cumulative_travel() {
    let mut recognizer = TouchpadGestureRecognizer::default();
    recognizer.begin_swipe(DEVICE, 3);
    assert_eq!(recognizer.update_swipe(DEVICE, 6.0, -45.0), None);

    assert_eq!(
        recognizer.update_swipe(DEVICE, -4.0, -55.0),
        Some(ShortcutGesture::ThreeFingerSwipeUp)
    );
}

#[test]
fn direction_finger_count_and_distance_must_match_a_binding() {
    let mut recognizer = TouchpadGestureRecognizer::default();

    assert_eq!(update_swipe(&mut recognizer, 2, 0.0, -120.0), None);
    assert_eq!(update_swipe(&mut recognizer, 3, 0.0, -99.9), None);
    assert_eq!(update_swipe(&mut recognizer, 3, 0.0, 120.0), None);
    assert_eq!(update_swipe(&mut recognizer, 3, 120.0, 0.0), None);
}

#[test]
fn ambiguous_diagonal_swipe_does_not_trigger() {
    let mut recognizer = TouchpadGestureRecognizer::default();

    assert_eq!(update_swipe(&mut recognizer, 3, 81.0, -120.0), None);
}

#[test]
fn ended_and_invalid_sequences_fail_closed() {
    let mut recognizer = TouchpadGestureRecognizer::default();
    recognizer.begin_swipe(DEVICE, 3);
    assert_eq!(recognizer.update_swipe(DEVICE, 0.0, -80.0), None);
    recognizer.end_swipe(DEVICE);
    assert_eq!(recognizer.update_swipe(DEVICE, 0.0, -40.0), None);

    recognizer.begin_swipe(DEVICE, 3);
    assert_eq!(recognizer.update_swipe(DEVICE, f64::NAN, -120.0), None);
    assert_eq!(recognizer.update_swipe(DEVICE, 0.0, -120.0), None);
}

#[test]
fn devices_have_independent_lifecycles_and_actions_are_one_shot() {
    let mut recognizer = TouchpadGestureRecognizer::default();
    recognizer.begin_swipe("event-a", 3);
    recognizer.begin_swipe("event-b", 3);
    assert_eq!(
        recognizer.update_swipe("event-a", 0.0, -120.0),
        Some(ShortcutGesture::ThreeFingerSwipeUp)
    );
    assert_eq!(recognizer.update_swipe("event-a", 0.0, -120.0), None);
    assert_eq!(recognizer.update_swipe("event-b", 0.0, 120.0), None);
}

#[test]
fn reset_cancels_every_active_device() {
    let mut recognizer = TouchpadGestureRecognizer::default();
    recognizer.begin_swipe("event-a", 3);
    recognizer.begin_swipe("event-b", 3);
    assert_eq!(recognizer.update_swipe("event-a", 0.0, -80.0), None);
    assert_eq!(recognizer.update_swipe("event-b", 0.0, -80.0), None);
    recognizer.reset();

    assert_eq!(recognizer.update_swipe("event-a", 0.0, -40.0), None);
    assert_eq!(recognizer.update_swipe("event-b", 0.0, -40.0), None);
}
