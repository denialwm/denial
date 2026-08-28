//! Compositor-owned touchpad gesture recognition.
//!
//! Libinput decides whether a hardware sequence is a swipe, pinch, or hold.
//! This module deliberately starts one level above that hardware policy: it
//! turns gesture streams into shortcut triggers. Keeping the recognizer
//! independent from Smithay and the wire protocol makes gestures easy to
//! extend and the state machine deterministic to test.

use std::collections::HashMap;

use super::native_shortcut::ShortcutGesture;

const DIRECTION_DOMINANCE: f64 = 1.5;
const THREE_FINGER_SWIPE_DISTANCE: f64 = 100.0;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SwipeDirection {
    Up,
    Down,
    Left,
    Right,
}

#[derive(Clone, Copy, Debug)]
struct SwipeBinding {
    fingers: u32,
    direction: SwipeDirection,
    minimum_distance: f64,
    gesture: ShortcutGesture,
}

// Adding a supported swipe trigger should normally require only another
// binding here. Its action belongs to the user's shortcut configuration.
// Pinch and hold lifecycles can be added beside `active_swipes` without
// coupling their state to input routing or Flutter serialization.
const SWIPE_BINDINGS: &[SwipeBinding] = &[
    SwipeBinding {
        fingers: 3,
        direction: SwipeDirection::Up,
        minimum_distance: THREE_FINGER_SWIPE_DISTANCE,
        gesture: ShortcutGesture::ThreeFingerSwipeUp,
    },
    SwipeBinding {
        fingers: 3,
        direction: SwipeDirection::Left,
        minimum_distance: THREE_FINGER_SWIPE_DISTANCE,
        gesture: ShortcutGesture::ThreeFingerSwipeLeft,
    },
    SwipeBinding {
        fingers: 3,
        direction: SwipeDirection::Right,
        minimum_distance: THREE_FINGER_SWIPE_DISTANCE,
        gesture: ShortcutGesture::ThreeFingerSwipeRight,
    },
];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum TouchpadGestureEvent {
    Trigger(ShortcutGesture),
    Repeat(ShortcutGesture),
    End(ShortcutGesture),
}

#[derive(Clone, Copy, Debug)]
struct ActiveSwipe {
    fingers: u32,
    delta_x: f64,
    delta_y: f64,
    triggered: Option<ShortcutGesture>,
}

impl ActiveSwipe {
    fn new(fingers: u32) -> Self {
        Self {
            fingers,
            delta_x: 0.0,
            delta_y: 0.0,
            triggered: None,
        }
    }

    fn update(&mut self, delta_x: f64, delta_y: f64) -> Result<Option<TouchpadGestureEvent>, ()> {
        let next_x = self.delta_x + delta_x;
        let next_y = self.delta_y + delta_y;
        if !next_x.is_finite() || !next_y.is_finite() {
            return Err(());
        }
        self.delta_x = next_x;
        self.delta_y = next_y;

        let Some(gesture) = self.recognized_gesture() else {
            return Ok(None);
        };
        let event = if self.triggered.is_none() {
            self.triggered = Some(gesture);
            TouchpadGestureEvent::Trigger(gesture)
        } else if matches!(
            gesture,
            ShortcutGesture::ThreeFingerSwipeLeft | ShortcutGesture::ThreeFingerSwipeRight
        ) {
            TouchpadGestureEvent::Repeat(gesture)
        } else {
            return Ok(None);
        };
        self.delta_x = 0.0;
        self.delta_y = 0.0;
        Ok(Some(event))
    }

    fn direction_and_distance(self) -> Option<(SwipeDirection, f64)> {
        let absolute_x = self.delta_x.abs();
        let absolute_y = self.delta_y.abs();
        let (direction, primary, cross_axis) = if absolute_x > absolute_y {
            let direction = if self.delta_x < 0.0 {
                SwipeDirection::Left
            } else {
                SwipeDirection::Right
            };
            (direction, absolute_x, absolute_y)
        } else {
            let direction = if self.delta_y < 0.0 {
                SwipeDirection::Up
            } else {
                SwipeDirection::Down
            };
            (direction, absolute_y, absolute_x)
        };
        (primary >= cross_axis * DIRECTION_DOMINANCE).then_some((direction, primary))
    }

    fn recognized_gesture(&self) -> Option<ShortcutGesture> {
        let (direction, distance) = self.direction_and_distance()?;
        SWIPE_BINDINGS
            .iter()
            .find(|binding| {
                binding.fingers == self.fingers
                    && binding.direction == direction
                    && distance >= binding.minimum_distance
            })
            .map(|binding| binding.gesture)
    }

    fn end_event(self) -> Option<TouchpadGestureEvent> {
        self.triggered.map(TouchpadGestureEvent::End)
    }
}

#[derive(Debug, Default)]
pub(super) struct TouchpadGestureRecognizer {
    active_swipes: HashMap<String, ActiveSwipe>,
}

impl TouchpadGestureRecognizer {
    pub(super) fn begin_swipe(&mut self, device: &str, fingers: u32) {
        self.active_swipes
            .insert(device.to_owned(), ActiveSwipe::new(fingers));
    }

    pub(super) fn update_swipe(
        &mut self,
        device: &str,
        delta_x: f64,
        delta_y: f64,
    ) -> Option<TouchpadGestureEvent> {
        let update = self.active_swipes.get_mut(device)?.update(delta_x, delta_y);
        match update {
            Ok(event) => event,
            Err(()) => self
                .active_swipes
                .remove(device)
                .and_then(ActiveSwipe::end_event),
        }
    }

    pub(super) fn end_swipe(&mut self, device: &str) -> Option<TouchpadGestureEvent> {
        self.active_swipes
            .remove(device)
            .and_then(ActiveSwipe::end_event)
    }

    pub(super) fn reset(&mut self) {
        self.active_swipes.clear();
    }
}
