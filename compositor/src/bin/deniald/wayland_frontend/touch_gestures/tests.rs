use super::*;

fn geometry() -> WindowGeometry {
    WindowGeometry {
        x: 100.0,
        y: 80.0,
        width: 400.0,
        height: 300.0,
    }
}

fn target(in_gesture_strip: bool) -> TouchWindowTarget {
    TouchWindowTarget {
        window_id: 7,
        geometry: geometry(),
        in_gesture_strip,
        in_move_corner: false,
        geometry_locked: false,
    }
}

fn corner_target() -> TouchWindowTarget {
    TouchWindowTarget {
        in_move_corner: true,
        ..target(false)
    }
}

fn point(x: f64, y: f64) -> Point<f64, Logical> {
    Point::from((x, y))
}

#[test]
fn one_finger_corner_drag_emits_normal_move_phases() {
    let mut gestures = TouchGestureState::default();
    let down = gestures.down(0, point(120.0, 100.0), Some(corner_target()));
    assert!(down.consume);
    assert_eq!(down.captured_slots, [0]);
    assert!(down.actions.is_empty());

    let motion = gestures.motion(0, point(170.0, 140.0));
    assert_eq!(motion.actions.len(), 2);
    assert!(matches!(
        motion.actions[0],
        TouchWindowAction::Placement {
            phase: WindowPlacementPhase::Begin,
            change: WindowPlacementChange::Move,
            ..
        }
    ));
    assert_eq!(
        motion.actions[1],
        TouchWindowAction::Placement {
            window_id: 7,
            phase: WindowPlacementPhase::Update,
            change: WindowPlacementChange::Move,
            geometry: WindowGeometry {
                x: 150.0,
                y: 120.0,
                width: 400.0,
                height: 300.0,
            },
        }
    );
    assert!(matches!(
        gestures.up(0).actions.as_slice(),
        [TouchWindowAction::Placement {
            phase: WindowPlacementPhase::End,
            change: WindowPlacementChange::Move,
            ..
        }]
    ));
}

#[test]
fn one_finger_bottom_strip_drag_remains_with_the_window() {
    let mut gestures = TouchGestureState::default();
    assert!(
        !gestures
            .down(0, point(200.0, 350.0), Some(target(true)))
            .consume
    );
    let motion = gestures.motion(0, point(250.0, 390.0));
    assert!(!motion.consume);
    assert!(motion.actions.is_empty());
}

#[test]
fn directional_pinch_waits_for_intent_then_follows_both_axes() {
    let mut gestures = TouchGestureState::default();
    assert!(
        !gestures
            .down(0, point(150.0, 180.0), Some(target(false)))
            .consume
    );
    let second = gestures.down(1, point(250.0, 180.0), Some(target(false)));
    assert!(!second.consume);
    assert!(second.captured_slots.is_empty());
    assert!(second.actions.is_empty());

    assert!(!gestures.motion(0, point(130.0, 160.0)).consume);
    let motion = gestures.motion(1, point(280.0, 200.0));
    assert!(motion.consume);
    assert_eq!(motion.captured_slots, [0, 1]);
    assert!(matches!(
        motion.actions.first(),
        Some(TouchWindowAction::Placement {
            phase: WindowPlacementPhase::Begin,
            change: WindowPlacementChange::Resize,
            ..
        })
    ));

    assert_eq!(
        motion.actions[1],
        TouchWindowAction::Placement {
            window_id: 7,
            phase: WindowPlacementPhase::Update,
            change: WindowPlacementChange::Resize,
            geometry: WindowGeometry {
                x: 80.0,
                y: 60.0,
                width: 450.0,
                height: 340.0,
            },
        }
    );
    assert!(matches!(
        gestures.up(1).actions.as_slice(),
        [TouchWindowAction::Placement {
            phase: WindowPlacementPhase::End,
            change: WindowPlacementChange::Resize,
            ..
        }]
    ));
    assert!(gestures.up(0).consume);
}

#[test]
fn parallel_two_finger_scroll_is_not_captured_as_a_pinch() {
    let mut gestures = TouchGestureState::default();
    assert!(
        !gestures
            .down(0, point(150.0, 180.0), Some(target(false)))
            .consume
    );
    assert!(
        !gestures
            .down(1, point(250.0, 180.0), Some(target(false)))
            .consume
    );

    assert!(!gestures.motion(0, point(150.0, 220.0)).consume);
    assert!(!gestures.motion(1, point(250.0, 220.0)).consume);
    assert!(!gestures.up(0).consume);
    assert!(!gestures.up(1).consume);
}

#[test]
fn uneven_parallel_scroll_is_not_captured_between_contact_updates() {
    let mut gestures = TouchGestureState::default();
    gestures.down(0, point(200.0, 150.0), Some(target(false)));
    gestures.down(1, point(200.0, 250.0), Some(target(false)));

    assert!(!gestures.motion(0, point(200.0, 210.0)).consume);
    let update = gestures.motion(1, point(200.0, 255.0));
    assert!(!update.consume);
    assert!(update.captured_slots.is_empty());
    assert!(update.actions.is_empty());
}

#[test]
fn two_bottom_strip_contacts_minimize_only_after_a_downward_swipe() {
    let mut gestures = TouchGestureState::default();
    assert!(
        !gestures
            .down(0, point(160.0, 350.0), Some(target(true)))
            .consume
    );
    assert!(
        gestures
            .down(1, point(240.0, 350.0), Some(target(true)))
            .consume
    );

    assert!(gestures.motion(0, point(160.0, 430.0)).actions.is_empty());
    assert_eq!(
        gestures.motion(1, point(240.0, 470.0)).actions,
        [TouchWindowAction::Minimize { window_id: 7 }]
    );
    assert!(gestures.motion(0, point(160.0, 520.0)).actions.is_empty());
}

#[test]
fn three_finger_tap_never_closes() {
    let mut gestures = TouchGestureState::default();
    gestures.down(0, point(150.0, 350.0), Some(target(true)));
    gestures.down(1, point(250.0, 350.0), Some(target(true)));
    let third = gestures.down(2, point(200.0, 360.0), Some(target(true)));
    assert!(third.consume);
    assert!(third.actions.is_empty());
    let release = gestures.up(2);
    assert!(release.consume);
    assert!(release.actions.is_empty());
    assert!(gestures.up(1).consume);
    assert!(gestures.up(0).consume);
}

#[test]
fn three_finger_body_tap_does_not_close() {
    let mut gestures = TouchGestureState::default();
    gestures.down(0, point(150.0, 180.0), Some(target(false)));
    gestures.down(1, point(250.0, 180.0), Some(target(false)));
    let third = gestures.down(2, point(200.0, 250.0), Some(target(false)));
    assert!(third.consume);
    assert_eq!(third.captured_slots, [0, 1, 2]);
    assert!(gestures.up(2).actions.is_empty());
}

#[test]
fn three_finger_swipe_up_emits_the_touchpad_gesture() {
    let mut gestures = TouchGestureState::default();
    gestures.down(0, point(150.0, 250.0), Some(target(false)));
    gestures.down(1, point(250.0, 250.0), Some(target(false)));
    gestures.down(2, point(200.0, 250.0), Some(target(false)));

    assert!(gestures.motion(0, point(150.0, 130.0)).actions.is_empty());
    assert!(gestures.motion(1, point(250.0, 130.0)).actions.is_empty());
    assert_eq!(
        gestures.motion(2, point(200.0, 130.0)).actions,
        [TouchWindowAction::Gesture(
            ShortcutGesture::ThreeFingerSwipeUp
        )]
    );
    assert!(gestures.up(2).actions.is_empty());
}

#[test]
fn four_finger_inward_crush_closes_once() {
    let mut gestures = TouchGestureState::default();
    gestures.down(0, point(150.0, 130.0), Some(target(false)));
    gestures.down(1, point(450.0, 130.0), Some(target(false)));
    gestures.down(2, point(150.0, 330.0), Some(target(false)));
    let fourth = gestures.down(3, point(450.0, 330.0), Some(target(false)));
    assert!(fourth.consume);
    assert_eq!(fourth.captured_slots, [3]);
    assert!(fourth.actions.is_empty());

    assert!(gestures.motion(0, point(190.0, 160.0)).actions.is_empty());
    assert!(gestures.motion(1, point(410.0, 160.0)).actions.is_empty());
    assert!(gestures.motion(2, point(190.0, 300.0)).actions.is_empty());
    assert_eq!(
        gestures.motion(3, point(410.0, 300.0)).actions,
        [TouchWindowAction::Close { window_id: 7 }]
    );
    assert!(gestures.motion(0, point(210.0, 180.0)).actions.is_empty());
}

#[test]
fn four_finger_tap_and_translation_do_not_close() {
    let mut gestures = TouchGestureState::default();
    gestures.down(0, point(150.0, 130.0), Some(target(false)));
    gestures.down(1, point(450.0, 130.0), Some(target(false)));
    gestures.down(2, point(150.0, 330.0), Some(target(false)));
    gestures.down(3, point(450.0, 330.0), Some(target(false)));

    assert!(gestures.motion(0, point(190.0, 130.0)).actions.is_empty());
    assert!(gestures.motion(1, point(490.0, 130.0)).actions.is_empty());
    assert!(gestures.motion(2, point(190.0, 330.0)).actions.is_empty());
    assert!(gestures.motion(3, point(490.0, 330.0)).actions.is_empty());
    assert!(gestures.up(3).actions.is_empty());
}

#[test]
fn canceled_four_finger_contact_never_closes() {
    let mut gestures = TouchGestureState::default();
    gestures.down(0, point(150.0, 130.0), Some(target(false)));
    gestures.down(1, point(450.0, 130.0), Some(target(false)));
    gestures.down(2, point(150.0, 330.0), Some(target(false)));
    gestures.down(3, point(450.0, 330.0), Some(target(false)));

    assert!(gestures.cancel(3).actions.is_empty());
}

#[test]
fn contacts_on_different_windows_do_not_combine() {
    let mut gestures = TouchGestureState::default();
    gestures.down(0, point(150.0, 180.0), Some(target(false)));
    let other = TouchWindowTarget {
        window_id: 8,
        ..target(false)
    };
    assert!(!gestures.down(1, point(650.0, 180.0), Some(other)).consume);
    let same_other_window = gestures.down(2, point(700.0, 220.0), Some(other));
    assert!(!same_other_window.consume);
    assert!(
        !same_other_window
            .actions
            .iter()
            .any(|action| matches!(action, TouchWindowAction::Close { .. }))
    );
}

#[test]
fn locked_geometry_still_allows_minimize_and_close_gestures() {
    let locked = TouchWindowTarget {
        geometry_locked: true,
        ..target(true)
    };
    let mut gestures = TouchGestureState::default();
    gestures.down(0, point(160.0, 350.0), Some(locked));
    assert!(gestures.motion(0, point(220.0, 400.0)).actions.is_empty());
    gestures.down(1, point(240.0, 350.0), Some(locked));
    gestures.motion(0, point(160.0, 530.0));
    assert_eq!(
        gestures.motion(1, point(240.0, 530.0)).actions,
        [TouchWindowAction::Minimize { window_id: 7 }]
    );

    let mut close_gestures = TouchGestureState::default();
    close_gestures.down(0, point(150.0, 130.0), Some(locked));
    close_gestures.down(1, point(450.0, 130.0), Some(locked));
    close_gestures.down(2, point(150.0, 330.0), Some(locked));
    close_gestures.down(3, point(450.0, 330.0), Some(locked));
    close_gestures.motion(0, point(190.0, 160.0));
    close_gestures.motion(1, point(410.0, 160.0));
    close_gestures.motion(2, point(190.0, 300.0));
    assert_eq!(
        close_gestures.motion(3, point(410.0, 300.0)).actions,
        [TouchWindowAction::Close { window_id: 7 }]
    );
}
