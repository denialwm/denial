use super::super::super::native_shortcut::ShortcutGesture;
use super::*;

fn target(in_move_corner: bool, geometry_locked: bool) -> TouchWindowTarget {
    TouchWindowTarget {
        window_id: 7,
        geometry: WindowGeometry {
            x: 100.0,
            y: 200.0,
            width: 300.0,
            height: 400.0,
        },
        in_gesture_strip: false,
        in_move_corner,
        geometry_locked,
    }
}

fn begin_desktop_swipe(gestures: &mut TouchGestureState) {
    for slot in 0..2 {
        assert_eq!(
            gestures.down_on_desktop(slot, Point::from((200.0 + f64::from(slot) * 100.0, 400.0))),
            TouchGestureUpdate::default()
        );
    }
    let third = gestures.down_on_desktop(2, Point::from((400.0, 400.0)));
    assert!(third.consume);
    assert_eq!(third.captured_slots, [0, 1, 2]);
    assert!(third.actions.is_empty());
}

fn move_three_contacts(
    gestures: &mut TouchGestureState,
    delta: (f64, f64),
) -> Vec<TouchWindowAction> {
    (0..3)
        .flat_map(|slot| {
            gestures
                .motion(
                    slot,
                    Point::from((200.0 + f64::from(slot) * 100.0 + delta.0, 400.0 + delta.1)),
                )
                .actions
        })
        .collect()
}

fn begin_workspace_swipe(gestures: &mut TouchGestureState, context: usize) {
    for slot in 0..4 {
        let position = Point::from((200.0 + f64::from(slot) * 50.0, 400.0));
        let update = if context == 0 || (context == 2 && slot == 3) {
            gestures.down_on_desktop(slot, position)
        } else {
            let mut window = target(false, true);
            if context == 2 {
                window.window_id += slot as u64;
            }
            gestures.down(slot, position, Some(window))
        };
        if slot == 2 {
            assert_eq!(update.captured_slots, [0, 1, 2]);
        } else if slot == 3 {
            assert_eq!(update.captured_slots, [3]);
        }
        assert!(update.actions.is_empty());
    }
}

fn move_four_contacts(
    gestures: &mut TouchGestureState,
    delta: (f64, f64),
) -> Vec<TouchWindowAction> {
    (0..4)
        .flat_map(|slot| {
            gestures
                .motion_at(
                    slot,
                    Point::from((200.0 + f64::from(slot) * 50.0 + delta.0, 400.0 + delta.1)),
                    10_000 + slot as u64 * 1_000,
                )
                .actions
        })
        .collect()
}

#[test]
fn workspace_swipes_share_touchpad_bindings_on_windows_background_and_across_tiles() {
    use super::super::super::native_shortcut::{ShortcutDisposition, ShortcutEngine};

    for context in 0..3 {
        for (delta, gesture, disposition) in [
            (
                (-120.0, 0.0),
                ShortcutGesture::FourFingerSwipeLeft,
                ShortcutDisposition::RequestNextWorkspace,
            ),
            (
                (120.0, 0.0),
                ShortcutGesture::FourFingerSwipeRight,
                ShortcutDisposition::RequestPreviousWorkspace,
            ),
            (
                (0.0, -120.0),
                ShortcutGesture::FourFingerSwipeUp,
                ShortcutDisposition::RequestNextWorkspace,
            ),
            (
                (0.0, 120.0),
                ShortcutGesture::FourFingerSwipeDown,
                ShortcutDisposition::RequestPreviousWorkspace,
            ),
        ] {
            let mut gestures = TouchGestureState::default();
            begin_workspace_swipe(&mut gestures, context);
            let origin = Point::from((275.0, 400.0));
            assert_eq!(
                move_four_contacts(&mut gestures, delta),
                [TouchWindowAction::Swipe {
                    event: TouchpadGestureEvent::Trigger(gesture),
                    origin,
                }]
            );
            assert_eq!(
                ShortcutEngine::default().observe_gesture(gesture),
                disposition
            );
            assert!(move_four_contacts(&mut gestures, (delta.0 * 3.0, delta.1 * 3.0)).is_empty());
            assert_eq!(
                gestures.up_at(0, 30_000).actions,
                [TouchWindowAction::Swipe {
                    event: TouchpadGestureEvent::End(gesture),
                    origin,
                }]
            );
            for slot in 1..4 {
                let end = gestures.up_at(slot, 31_000 + slot as u64);
                assert!(end.consume);
                assert!(end.actions.is_empty());
            }
            assert!(gestures.gesture.is_none());
            assert!(gestures.contacts.is_empty());
        }
    }
}

#[test]
fn workspace_swipes_reject_short_and_diagonal_motion() {
    for delta in [(90.0, 0.0), (0.0, -90.0), (120.0, 100.0), (-100.0, -120.0)] {
        let mut gestures = TouchGestureState::default();
        begin_workspace_swipe(&mut gestures, 0);
        assert!(move_four_contacts(&mut gestures, delta).is_empty());
        assert!(gestures.cancel_all().is_empty());
    }
}

#[test]
fn horizontal_window_navigation_ends_on_release_or_cancellation() {
    use super::super::super::native_shortcut::{ShortcutDisposition, ShortcutEngine};

    for cancelled in [false, true] {
        for (delta, gesture, disposition) in [
            (
                -120.0,
                ShortcutGesture::ThreeFingerSwipeLeft,
                ShortcutDisposition::RequestWindowSwitcherNext,
            ),
            (
                120.0,
                ShortcutGesture::ThreeFingerSwipeRight,
                ShortcutDisposition::RequestWindowSwitcherPrevious,
            ),
        ] {
            let mut gestures = TouchGestureState::default();
            begin_desktop_swipe(&mut gestures);
            assert_eq!(
                move_three_contacts(&mut gestures, (delta, 0.0)),
                [TouchWindowAction::Swipe {
                    event: TouchpadGestureEvent::Trigger(gesture),
                    origin: Point::from((300.0, 400.0)),
                }]
            );
            let mut shortcuts = ShortcutEngine::default();
            assert_eq!(shortcuts.observe_gesture(gesture), disposition);
            let end = if cancelled {
                gestures.cancel(0)
            } else {
                gestures.up(0)
            };
            assert_eq!(
                end.actions,
                [TouchWindowAction::Swipe {
                    event: TouchpadGestureEvent::End(gesture),
                    origin: Point::from((300.0, 400.0)),
                }]
            );
            assert_eq!(
                shortcuts.end_gesture(gesture),
                ShortcutDisposition::RequestWindowSwitcherEnd { forward: false }
            );
            assert!(move_three_contacts(&mut gestures, (delta * 2.0, 0.0)).is_empty());
            assert!(gestures.cancel_all().is_empty());
        }
    }
}

#[test]
fn scrolling_layout_touch_streams_motion_before_release_and_then_settles() {
    let mut gestures = TouchGestureState::default();
    gestures.set_swipe_directions(HorizontalScrollDirections {
        left: true,
        right: true,
    });
    begin_desktop_swipe(&mut gestures);
    let mut events = Vec::new();
    for slot in 0..3 {
        events.extend(
            gestures
                .motion_at(
                    slot,
                    Point::from((170.0 + f64::from(slot) * 100.0, 400.0)),
                    10_000 + slot as u64 * 10_000,
                )
                .actions,
        );
    }
    let origin = Point::from((300.0, 400.0));
    assert_eq!(
        events,
        [
            TouchWindowAction::Swipe {
                event: TouchpadGestureEvent::HorizontalScrollBegin { delta_x: -10.0 },
                origin
            },
            TouchWindowAction::Swipe {
                event: TouchpadGestureEvent::HorizontalScrollUpdate { delta_x: -10.0 },
                origin
            },
            TouchWindowAction::Swipe {
                event: TouchpadGestureEvent::HorizontalScrollUpdate { delta_x: -10.0 },
                origin
            },
        ]
    );
    assert_eq!(
        gestures.up_at(0, 300_000).actions,
        [TouchWindowAction::Swipe {
            event: TouchpadGestureEvent::HorizontalScrollEnd {
                cancelled: false,
                projected_delta_x: -30.0
            },
            origin,
        }]
    );
    assert!(gestures.cancel_all().is_empty());
}

#[test]
fn scrolling_layout_touch_honors_enabled_directions_and_cancels_on_device_reset() {
    let mut gestures = TouchGestureState::default();
    gestures.set_swipe_directions(HorizontalScrollDirections {
        left: false,
        right: true,
    });
    begin_desktop_swipe(&mut gestures);
    assert!(move_three_contacts(&mut gestures, (-30.0, 0.0)).is_empty());
    let events = move_three_contacts(&mut gestures, (-120.0, 0.0));
    assert!(matches!(
        events.as_slice(),
        [TouchWindowAction::Swipe {
            event: TouchpadGestureEvent::Trigger(ShortcutGesture::ThreeFingerSwipeLeft),
            ..
        }]
    ));
    gestures.cancel_all();

    begin_desktop_swipe(&mut gestures);
    assert!(!move_three_contacts(&mut gestures, (30.0, 0.0)).is_empty());
    assert!(matches!(
        gestures.cancel_all().as_slice(),
        [TouchWindowAction::Swipe {
            event: TouchpadGestureEvent::HorizontalScrollEnd {
                cancelled: true,
                ..
            },
            ..
        }]
    ));
    assert!(gestures.contacts.is_empty());
    assert!(gestures.gesture.is_none());
    assert!(gestures.swipe.is_none());
}

#[test]
fn global_swipe_keeps_mixed_contacts_captured_until_every_finger_is_lifted() {
    let mut gestures = TouchGestureState::default();
    begin_workspace_swipe(&mut gestures, 2);
    move_four_contacts(&mut gestures, (-120.0, 0.0));
    assert!(gestures.up(3).consume);
    let extra = gestures.down(4, Point::from((500.0, 400.0)), Some(target(false, true)));
    assert!(extra.consume);
    assert_eq!(extra.captured_slots, [4]);
    for slot in 0..3 {
        assert!(gestures.up(slot).consume);
    }
    assert!(gestures.gesture.is_some());
    assert!(gestures.up(4).consume);
    assert!(gestures.gesture.is_none());
    assert!(gestures.contacts.is_empty());
}

#[test]
fn holding_one_finger_with_sensor_jitter_does_not_capture_the_other_fingers_drag() {
    for jitter in [0.0, 0.25, 1.0] {
        let mut gestures = TouchGestureState::default();
        let window = target(false, false);
        gestures.down(0, Point::from((200.0, 300.0)), Some(window));
        gestures.down(1, Point::from((400.0, 300.0)), Some(window));
        assert_eq!(
            gestures.motion(0, Point::from((200.0 + jitter, 300.0))),
            TouchGestureUpdate::default()
        );
        assert_eq!(
            gestures.motion(1, Point::from((360.0, 300.0))),
            TouchGestureUpdate::default(),
            "a resting contact with {jitter} pixels of jitter is not a pinch"
        );
        assert_eq!(gestures.up(1), TouchGestureUpdate::default());
        assert_eq!(gestures.up(0), TouchGestureUpdate::default());
    }
}

#[test]
fn adding_a_finger_to_an_established_app_drag_keeps_both_contacts_in_the_app() {
    let mut gestures = TouchGestureState::default();
    let window = target(false, false);
    gestures.down(0, Point::from((200.0, 300.0)), Some(window));
    assert_eq!(
        gestures.motion(0, Point::from((180.0, 300.0))),
        TouchGestureUpdate::default()
    );
    gestures.down(1, Point::from((400.0, 300.0)), Some(window));
    for (slot, position) in [(0, (160.0, 300.0)), (1, (420.0, 300.0))] {
        assert_eq!(
            gestures.motion(slot, Point::from(position)),
            TouchGestureUpdate::default()
        );
    }
    assert_eq!(gestures.up(0), TouchGestureUpdate::default());
    assert_eq!(gestures.up(1), TouchGestureUpdate::default());
    // Releasing the app gesture permits a new deliberate window pinch.
    gestures.down(0, Point::from((200.0, 300.0)), Some(window));
    gestures.down(1, Point::from((400.0, 300.0)), Some(window));
    assert!(!gestures.motion(0, Point::from((180.0, 300.0))).consume);
    let resize = gestures.motion(1, Point::from((420.0, 300.0)));
    assert!(resize.consume);
    assert_eq!(resize.captured_slots, [0, 1]);
}

#[test]
fn third_contact_promotes_an_active_window_resize_and_finishes_its_placement() {
    let mut gestures = TouchGestureState::default();
    let window = target(false, false);
    gestures.down(0, Point::from((200.0, 300.0)), Some(window));
    gestures.down(1, Point::from((300.0, 500.0)), Some(window));
    assert!(!gestures.motion(0, Point::from((180.0, 280.0))).consume);
    let resize = gestures.motion(1, Point::from((320.0, 520.0)));
    assert!(resize.consume);
    assert_eq!(resize.captured_slots, [0, 1]);
    assert!(matches!(
        resize.actions.as_slice(),
        [
            TouchWindowAction::Placement {
                phase: WindowPlacementPhase::Begin,
                change: WindowPlacementChange::Resize,
                ..
            },
            TouchWindowAction::Placement {
                phase: WindowPlacementPhase::Update,
                change: WindowPlacementChange::Resize,
                ..
            },
        ]
    ));
    let third = gestures.down_on_desktop(2, Point::from((400.0, 400.0)));
    assert!(third.consume);
    assert_eq!(third.captured_slots, [2]);
    assert!(matches!(
        third.actions.as_slice(),
        [TouchWindowAction::Placement {
            window_id: 7,
            phase: WindowPlacementPhase::End,
            change: WindowPlacementChange::Resize,
            ..
        }]
    ));
    let mut actions = Vec::new();
    for (slot, position) in [
        (0, (180.0, 130.0)),
        (1, (320.0, 370.0)),
        (2, (400.0, 250.0)),
    ] {
        actions.extend(gestures.motion(slot, Point::from(position)).actions);
    }
    assert!(matches!(
        actions.as_slice(),
        [TouchWindowAction::Swipe {
            event: TouchpadGestureEvent::Trigger(ShortcutGesture::ThreeFingerSwipeUp),
            ..
        }]
    ));
}

#[test]
fn an_extra_contact_does_not_promote_a_swipe_after_it_has_triggered() {
    let mut gestures = TouchGestureState::default();
    begin_desktop_swipe(&mut gestures);
    move_three_contacts(&mut gestures, (120.0, 0.0));
    let extra = gestures.down_on_desktop(3, Point::from((500.0, 400.0)));
    assert_eq!(extra.captured_slots, [3]);
    assert!(extra.actions.is_empty());
    assert!(gestures.up(3).actions.is_empty());
    assert!(matches!(
        gestures.up(0).actions.as_slice(),
        [TouchWindowAction::Swipe {
            event: TouchpadGestureEvent::End(ShortcutGesture::ThreeFingerSwipeRight),
            ..
        }]
    ));
}

#[test]
fn four_finger_translation_toward_window_center_switches_workspace_instead_of_closing() {
    let mut gestures = TouchGestureState::default();
    for slot in 0..4 {
        gestures.down(
            slot,
            Point::from((120.0 + f64::from(slot) * 10.0, 280.0)),
            Some(target(false, true)),
        );
    }
    let mut actions = Vec::new();
    for slot in 0..4 {
        actions.extend(
            gestures
                .motion(slot, Point::from((240.0 + f64::from(slot) * 10.0, 280.0)))
                .actions,
        );
    }
    assert!(matches!(
        actions.as_slice(),
        [TouchWindowAction::Swipe {
            event: TouchpadGestureEvent::Trigger(ShortcutGesture::FourFingerSwipeRight),
            ..
        }]
    ));
}

#[test]
fn empty_desktop_swipe_emits_the_same_overview_shortcut_as_a_window_swipe() {
    use super::super::super::native_shortcut::{ShortcutDisposition, ShortcutEngine};

    for on_desktop in [true, false] {
        let mut gestures = TouchGestureState::default();
        if on_desktop {
            begin_desktop_swipe(&mut gestures);
        } else {
            for slot in 0..3 {
                gestures.down(
                    slot,
                    Point::from((200.0 + f64::from(slot) * 100.0, 400.0)),
                    Some(target(false, false)),
                );
            }
        }
        let actions = move_three_contacts(&mut gestures, (0.0, -150.0));
        assert_eq!(
            actions,
            [TouchWindowAction::Swipe {
                event: TouchpadGestureEvent::Trigger(ShortcutGesture::ThreeFingerSwipeUp),
                origin: Point::from((300.0, 400.0)),
            }]
        );
        let mut shortcuts = ShortcutEngine::default();
        assert_eq!(
            shortcuts.observe_gesture(ShortcutGesture::ThreeFingerSwipeUp),
            ShortcutDisposition::RequestOverview
        );
    }
}

#[test]
fn desktop_swipe_fires_once_and_releases_every_captured_contact() {
    let mut gestures = TouchGestureState::default();
    begin_desktop_swipe(&mut gestures);
    assert_eq!(move_three_contacts(&mut gestures, (0.0, -150.0)).len(), 1);
    assert!(move_three_contacts(&mut gestures, (0.0, -300.0)).is_empty());
    assert!(gestures.up(0).consume);
    let extra = gestures.down_on_desktop(3, Point::from((500.0, 250.0)));
    assert!(extra.consume);
    assert_eq!(extra.captured_slots, [3]);
    assert!(gestures.cancel(1).consume);
    assert!(
        gestures
            .motion(2, Point::from((400.0, 0.0)))
            .actions
            .is_empty()
    );
    assert!(gestures.up(2).consume);
    assert!(gestures.up(3).consume);
    assert!(gestures.gesture.is_none());
    assert!(gestures.contacts.is_empty());

    begin_desktop_swipe(&mut gestures);
    assert_eq!(move_three_contacts(&mut gestures, (0.0, -150.0)).len(), 1);
}

#[test]
fn desktop_single_and_two_finger_input_still_reaches_flutter() {
    let mut gestures = TouchGestureState::default();
    for slot in 0..2 {
        assert_eq!(
            gestures.down_on_desktop(slot, Point::from((200.0 + f64::from(slot) * 100.0, 400.0))),
            TouchGestureUpdate::default()
        );
        assert_eq!(
            gestures.motion(slot, Point::from((250.0, 200.0))),
            TouchGestureUpdate::default()
        );
    }
    assert_eq!(gestures.up(0), TouchGestureUpdate::default());
    assert_eq!(gestures.up(1), TouchGestureUpdate::default());
}

#[test]
fn desktop_swipe_rejects_short_diagonal_and_unsupported_motion() {
    for delta in [(0.0, -90.0), (0.0, 150.0), (150.0, -120.0)] {
        let mut gestures = TouchGestureState::default();
        begin_desktop_swipe(&mut gestures);
        assert!(move_three_contacts(&mut gestures, delta).is_empty());
    }
}

#[test]
fn unavailable_contacts_never_join_a_desktop_swipe() {
    let mut gestures = TouchGestureState::default();
    for slot in 0..3 {
        assert_eq!(
            gestures.down(slot, Point::from((200.0, 400.0)), None),
            TouchGestureUpdate::default()
        );
    }
    assert!(move_three_contacts(&mut gestures, (0.0, -150.0)).is_empty());
    gestures.cancel_all();

    gestures.down_on_desktop(0, Point::from((200.0, 400.0)));
    gestures.down_on_desktop(1, Point::from((300.0, 400.0)));
    assert_eq!(
        gestures.down(2, Point::from((400.0, 400.0)), None),
        TouchGestureUpdate::default()
    );
    assert!(gestures.gesture.is_none());
    let third = gestures.down_on_desktop(3, Point::from((500.0, 400.0)));
    assert_eq!(third.captured_slots, [0, 1, 3]);
    assert_eq!(gestures.up(2), TouchGestureUpdate::default());
    gestures.cancel_all();
    assert!(gestures.gesture.is_none());
    assert!(gestures.contacts.is_empty());
}

#[test]
fn four_finger_window_crush_keeps_its_window_target() {
    let mut gestures = TouchGestureState::default();
    let positions = [
        (150.0, 300.0),
        (350.0, 300.0),
        (150.0, 500.0),
        (350.0, 500.0),
    ];
    for (slot, position) in positions.into_iter().enumerate() {
        gestures.down(
            slot as i32,
            Point::from(position),
            Some(target(false, false)),
        );
    }
    let mut actions = Vec::new();
    for (slot, (x, y)) in positions.into_iter().enumerate() {
        actions.extend(
            gestures
                .motion(
                    slot as i32,
                    Point::from((250.0 + (x - 250.0) * 0.5, 400.0 + (y - 400.0) * 0.5)),
                )
                .actions,
        );
    }
    assert_eq!(actions, [TouchWindowAction::Close { window_id: 7 }]);
    for slot in 0..4 {
        assert!(gestures.up(slot).consume);
    }
    assert!(gestures.gesture.is_none());
}

#[test]
fn tiled_pinch_maps_each_requested_edge_to_its_layout_boundary_delta() {
    let current = Size::from((300, 400));
    let target = Size::from((340, 460));

    assert_eq!(
        layout_pinch_delta(LayoutPinchEdge::Left, current, target),
        (-40.0, 0.0)
    );
    assert_eq!(
        layout_pinch_delta(LayoutPinchEdge::Right, current, target),
        (40.0, 0.0)
    );
    assert_eq!(
        layout_pinch_delta(LayoutPinchEdge::Top, current, target),
        (0.0, -60.0)
    );
    assert_eq!(
        layout_pinch_delta(LayoutPinchEdge::Bottom, current, target),
        (0.0, 60.0)
    );
}

#[test]
fn stationary_corner_contact_remains_a_client_tap() {
    let mut gestures = TouchGestureState::default();
    let down = gestures.down(1, Point::from((110.0, 210.0)), Some(target(true, false)));
    assert_eq!(down, TouchGestureUpdate::default());

    let up = gestures.up(1);
    assert_eq!(up, TouchGestureUpdate::default());
}

#[test]
fn corner_move_keeps_its_size_through_release_despite_client_size_hints() {
    let mut gestures = TouchGestureState::default();
    let target = target(true, false);
    gestures.down(0, Point::from((110.0, 210.0)), Some(target));
    let begin = gestures.motion(0, Point::from((150.0, 250.0)));
    let update = gestures.motion(0, Point::from((180.0, 290.0)));
    let end = gestures.up(0);
    assert!(end.consume);
    assert!(matches!(
        end.actions.as_slice(),
        [TouchWindowAction::Placement {
            phase: WindowPlacementPhase::End,
            change: WindowPlacementChange::Move,
            ..
        }]
    ));
    for action in begin
        .actions
        .into_iter()
        .chain(update.actions)
        .chain(end.actions)
    {
        let TouchWindowAction::Placement {
            geometry, change, ..
        } = action
        else {
            panic!("corner movement emitted a non-placement action");
        };
        for (minimum, maximum) in [
            (Size::from((1920, 1080)), Size::from((1920, 1080))),
            (Size::from((1, 1)), Size::from((200, 200))),
        ] {
            let constrained = client_geometry_with_constraints(geometry, change, minimum, maximum);
            assert_eq!(constrained.size, Size::from((300, 400)));
            assert_eq!(
                constrained.loc,
                Point::from((rounded_i32(geometry.x), rounded_i32(geometry.y)))
            );
        }
    }
}

#[test]
fn pinch_still_honors_size_hints_around_its_center() {
    let geometry = client_geometry_with_constraints(
        target(false, false).geometry,
        WindowPlacementChange::Resize,
        Size::from((320, 240)),
        Size::from((1000, 350)),
    );
    assert_eq!(geometry.size, Size::from((320, 350)));
    assert_eq!(geometry.loc, Point::from((90, 225)));
}

#[test]
fn corner_move_captures_only_after_crossing_slop() {
    let mut gestures = TouchGestureState::default();
    let origin = Point::from((110.0, 210.0));
    assert_eq!(
        gestures.down(3, origin, Some(target(true, false))),
        TouchGestureUpdate::default()
    );
    assert_eq!(
        gestures.motion(3, Point::from((112.0, 210.0))),
        TouchGestureUpdate::default()
    );

    let captured = gestures.motion(3, Point::from((115.0, 210.0)));
    assert!(captured.consume);
    assert_eq!(captured.captured_slots, vec![3]);
    assert_eq!(captured.actions.len(), 2);
    assert!(matches!(
        captured.actions[0],
        TouchWindowAction::Placement {
            phase: WindowPlacementPhase::Begin,
            change: WindowPlacementChange::Move,
            ..
        }
    ));
    assert!(matches!(
        captured.actions[1],
        TouchWindowAction::Placement {
            phase: WindowPlacementPhase::Update,
            change: WindowPlacementChange::Move,
            geometry: WindowGeometry { x: 105.0, .. },
            ..
        }
    ));
}

#[test]
fn geometry_locked_corner_never_becomes_a_move_candidate() {
    let mut gestures = TouchGestureState::default();
    assert_eq!(
        gestures.down(5, Point::from((110.0, 210.0)), Some(target(true, true)),),
        TouchGestureUpdate::default()
    );
    assert_eq!(
        gestures.motion(5, Point::from((150.0, 250.0))),
        TouchGestureUpdate::default()
    );
    assert_eq!(gestures.up(5), TouchGestureUpdate::default());
}

#[test]
fn touch_move_uses_the_super_grab_restored_size_and_location() {
    let transform = PlacementTransform {
        source: WindowGeometry {
            x: 0.0,
            y: 0.0,
            width: 1920.0,
            height: 1080.0,
        },
        restored: WindowGeometry {
            x: 100.0,
            y: 200.0,
            width: 900.0,
            height: 620.0,
        },
    };
    for delta in [0.0, 40.0, 120.0] {
        let geometry = transform.apply(
            WindowGeometry {
                x: delta,
                y: delta * 0.5,
                ..transform.source
            },
            WindowPlacementChange::Move,
        );
        assert_eq!((geometry.width, geometry.height), (900.0, 620.0));
        assert_eq!(
            (geometry.x, geometry.y),
            (100.0 + delta, 200.0 + delta * 0.5)
        );
    }
    let resized = transform.apply(
        WindowGeometry {
            x: -20.0,
            y: -10.0,
            width: 1960.0,
            height: 1100.0,
        },
        WindowPlacementChange::Resize,
    );
    assert_eq!(
        resized,
        WindowGeometry {
            x: 80.0,
            y: 190.0,
            width: 940.0,
            height: 640.0
        }
    );
}
