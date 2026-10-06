//! Compositor-owned touchpad gesture recognition.
//!
//! Libinput decides whether a hardware sequence is a swipe, pinch, or hold.
//! This module deliberately starts one level above that hardware policy: it
//! turns gesture streams into shortcut triggers or continuous motion phases.
//! Keeping the recognizer independent from Smithay and the wire protocol makes
//! gestures easy to extend and the state machine deterministic to test.

use std::collections::{HashMap, VecDeque};

use super::native_shortcut::ShortcutGesture;

const DIRECTION_DOMINANCE: f64 = 1.5;
const HORIZONTAL_SCROLL_SLOP: f64 = 8.0;
const HORIZONTAL_SCROLL_VELOCITY_HISTORY_MICROS: u64 = 150_000;
const HORIZONTAL_SCROLL_DECELERATION: f64 = 0.997;
const THREE_FINGER_SWIPE_DISTANCE: f64 = 100.0;
const FOUR_FINGER_SWIPE_DISTANCE: f64 = 100.0;

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
    SwipeBinding {
        fingers: 4,
        direction: SwipeDirection::Up,
        minimum_distance: FOUR_FINGER_SWIPE_DISTANCE,
        gesture: ShortcutGesture::FourFingerSwipeUp,
    },
    SwipeBinding {
        fingers: 4,
        direction: SwipeDirection::Down,
        minimum_distance: FOUR_FINGER_SWIPE_DISTANCE,
        gesture: ShortcutGesture::FourFingerSwipeDown,
    },
    SwipeBinding {
        fingers: 4,
        direction: SwipeDirection::Left,
        minimum_distance: FOUR_FINGER_SWIPE_DISTANCE,
        gesture: ShortcutGesture::FourFingerSwipeLeft,
    },
    SwipeBinding {
        fingers: 4,
        direction: SwipeDirection::Right,
        minimum_distance: FOUR_FINGER_SWIPE_DISTANCE,
        gesture: ShortcutGesture::FourFingerSwipeRight,
    },
];

#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) enum TouchpadGestureEvent {
    Trigger(ShortcutGesture),
    Repeat(ShortcutGesture),
    End(ShortcutGesture),
    HorizontalScrollBegin {
        delta_x: f64,
    },
    HorizontalScrollUpdate {
        delta_x: f64,
    },
    HorizontalScrollEnd {
        cancelled: bool,
        projected_delta_x: f64,
    },
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(super) struct HorizontalScrollDirections {
    pub(super) left: bool,
    pub(super) right: bool,
}

impl HorizontalScrollDirections {
    fn contains(self, direction: SwipeDirection) -> bool {
        match direction {
            SwipeDirection::Left => self.left,
            SwipeDirection::Right => self.right,
            SwipeDirection::Up | SwipeDirection::Down => false,
        }
    }
}

#[derive(Clone, Copy, Debug)]
struct HorizontalScrollSample {
    delta_x: f64,
    timestamp_micros: u64,
}

#[derive(Debug, Default)]
struct HorizontalScrollTracker {
    history: VecDeque<HorizontalScrollSample>,
    delta_x: f64,
}

impl HorizontalScrollTracker {
    fn push(&mut self, delta_x: f64, timestamp_micros: u64) {
        if self
            .history
            .back()
            .is_some_and(|sample| timestamp_micros < sample.timestamp_micros)
        {
            return;
        }
        self.history.push_back(HorizontalScrollSample {
            delta_x,
            timestamp_micros,
        });
        self.delta_x += delta_x;
        while self.history.front().is_some_and(|sample| {
            timestamp_micros.saturating_sub(sample.timestamp_micros)
                > HORIZONTAL_SCROLL_VELOCITY_HISTORY_MICROS
        }) {
            self.history.pop_front();
        }
    }

    fn velocity(&self) -> f64 {
        let (Some(first), Some(last)) = (self.history.front(), self.history.back()) else {
            return 0.0;
        };
        let elapsed_micros = last.timestamp_micros.saturating_sub(first.timestamp_micros);
        if elapsed_micros == 0 {
            return 0.0;
        }
        let delta_x = self
            .history
            .iter()
            .map(|sample| sample.delta_x)
            .sum::<f64>();
        delta_x / (elapsed_micros as f64 / 1_000_000.0)
    }

    fn projected_delta_x(&self) -> f64 {
        let projected =
            self.delta_x - self.velocity() / (1_000.0 * HORIZONTAL_SCROLL_DECELERATION.ln());
        if projected.is_finite() {
            projected
        } else {
            self.delta_x
        }
    }
}

#[derive(Debug)]
struct ActiveSwipe {
    fingers: u32,
    delta_x: f64,
    delta_y: f64,
    triggered: Option<ShortcutGesture>,
    horizontal_scroll_directions: HorizontalScrollDirections,
    horizontal_scrolling: bool,
    horizontal_scroll_tracker: HorizontalScrollTracker,
}

impl ActiveSwipe {
    fn new(fingers: u32, horizontal_scroll_directions: HorizontalScrollDirections) -> Self {
        Self {
            fingers,
            delta_x: 0.0,
            delta_y: 0.0,
            triggered: None,
            horizontal_scroll_directions,
            horizontal_scrolling: false,
            horizontal_scroll_tracker: HorizontalScrollTracker::default(),
        }
    }

    fn update(
        &mut self,
        delta_x: f64,
        delta_y: f64,
        timestamp_micros: u64,
    ) -> Result<Option<TouchpadGestureEvent>, ()> {
        if !delta_x.is_finite() || !delta_y.is_finite() {
            return Err(());
        }
        if !(self.horizontal_scroll_tracker.delta_x + delta_x).is_finite() {
            return Err(());
        }
        self.horizontal_scroll_tracker
            .push(delta_x, timestamp_micros);
        if self.horizontal_scrolling {
            return Ok((delta_x != 0.0)
                .then_some(TouchpadGestureEvent::HorizontalScrollUpdate { delta_x }));
        }

        let next_x = self.delta_x + delta_x;
        let next_y = self.delta_y + delta_y;
        if !next_x.is_finite() || !next_y.is_finite() {
            return Err(());
        }
        self.delta_x = next_x;
        self.delta_y = next_y;

        if self.fingers == 3
            && let Some((direction, distance)) = self.direction_and_distance()
            && distance >= HORIZONTAL_SCROLL_SLOP
            && self.horizontal_scroll_directions.contains(direction)
        {
            self.horizontal_scrolling = true;
            let delta_x = std::mem::take(&mut self.delta_x);
            self.delta_y = 0.0;
            return Ok(Some(TouchpadGestureEvent::HorizontalScrollBegin {
                delta_x,
            }));
        }

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

    fn direction_and_distance(&self) -> Option<(SwipeDirection, f64)> {
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

    fn end_event(mut self, cancelled: bool, timestamp_micros: u64) -> Option<TouchpadGestureEvent> {
        if self.horizontal_scrolling {
            // Treat time spent stationary before release as zero motion so a
            // deliberate slow stop does not inherit stale fling velocity.
            self.horizontal_scroll_tracker.push(0.0, timestamp_micros);
            Some(TouchpadGestureEvent::HorizontalScrollEnd {
                cancelled,
                projected_delta_x: self.horizontal_scroll_tracker.projected_delta_x(),
            })
        } else {
            self.triggered.map(TouchpadGestureEvent::End)
        }
    }
}

#[derive(Debug, Default)]
pub(super) struct TouchpadGestureRecognizer {
    active_swipes: HashMap<String, ActiveSwipe>,
}

impl TouchpadGestureRecognizer {
    pub(super) fn begin_swipe(
        &mut self,
        device: &str,
        fingers: u32,
        horizontal_scroll_directions: HorizontalScrollDirections,
    ) {
        self.active_swipes.insert(
            device.to_owned(),
            ActiveSwipe::new(fingers, horizontal_scroll_directions),
        );
    }

    pub(super) fn update_swipe(
        &mut self,
        device: &str,
        delta_x: f64,
        delta_y: f64,
        timestamp_micros: u64,
    ) -> Option<TouchpadGestureEvent> {
        let update = self
            .active_swipes
            .get_mut(device)?
            .update(delta_x, delta_y, timestamp_micros);
        match update {
            Ok(event) => event,
            Err(()) => self
                .active_swipes
                .remove(device)
                .and_then(|swipe| swipe.end_event(true, timestamp_micros)),
        }
    }

    pub(super) fn end_swipe(
        &mut self,
        device: &str,
        cancelled: bool,
        timestamp_micros: u64,
    ) -> Option<TouchpadGestureEvent> {
        self.active_swipes
            .remove(device)
            .and_then(|swipe| swipe.end_event(cancelled, timestamp_micros))
    }

    pub(super) fn reset(&mut self) -> bool {
        let horizontal_scrolling = self
            .active_swipes
            .values()
            .any(|swipe| swipe.horizontal_scrolling);
        self.active_swipes.clear();
        horizontal_scrolling
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn four_finger_workspace_swipes_support_both_axes() {
        let mut recognizer = TouchpadGestureRecognizer::default();

        recognizer.begin_swipe("touchpad", 4, HorizontalScrollDirections::default());
        assert_eq!(recognizer.update_swipe("touchpad", 60.0, 2.0, 10_000), None);
        assert_eq!(
            recognizer.update_swipe("touchpad", 41.0, 1.0, 20_000),
            Some(TouchpadGestureEvent::Trigger(
                ShortcutGesture::FourFingerSwipeRight
            ))
        );
        assert_eq!(
            recognizer.update_swipe("touchpad", 120.0, 0.0, 30_000),
            None
        );
        assert_eq!(
            recognizer.end_swipe("touchpad", false, 40_000),
            Some(TouchpadGestureEvent::End(
                ShortcutGesture::FourFingerSwipeRight
            ))
        );

        recognizer.begin_swipe("touchpad", 4, HorizontalScrollDirections::default());
        assert_eq!(
            recognizer.update_swipe("touchpad", -101.0, 0.0, 50_000),
            Some(TouchpadGestureEvent::Trigger(
                ShortcutGesture::FourFingerSwipeLeft
            ))
        );

        recognizer.begin_swipe("touchpad", 4, HorizontalScrollDirections::default());
        assert_eq!(
            recognizer.update_swipe("touchpad", 0.0, -101.0, 60_000),
            Some(TouchpadGestureEvent::Trigger(
                ShortcutGesture::FourFingerSwipeUp
            ))
        );

        recognizer.begin_swipe("touchpad", 4, HorizontalScrollDirections::default());
        assert_eq!(
            recognizer.update_swipe("touchpad", 0.0, 101.0, 70_000),
            Some(TouchpadGestureEvent::Trigger(
                ShortcutGesture::FourFingerSwipeDown
            ))
        );
    }

    #[test]
    fn four_finger_diagonal_motion_does_not_trigger_a_workspace_swipe() {
        let mut recognizer = TouchpadGestureRecognizer::default();
        recognizer.begin_swipe("touchpad", 4, HorizontalScrollDirections::default());

        assert_eq!(
            recognizer.update_swipe("touchpad", 110.0, 90.0, 10_000),
            None
        );
        assert_eq!(recognizer.end_swipe("touchpad", false, 20_000), None);
    }

    #[test]
    fn enabled_three_finger_horizontal_swipe_streams_raw_motion() {
        let mut recognizer = TouchpadGestureRecognizer::default();
        recognizer.begin_swipe(
            "touchpad",
            3,
            HorizontalScrollDirections {
                left: true,
                right: true,
            },
        );

        assert_eq!(recognizer.update_swipe("touchpad", -4.0, 0.0, 10_000), None);
        assert_eq!(
            recognizer.update_swipe("touchpad", -5.0, 1.0, 20_000),
            Some(TouchpadGestureEvent::HorizontalScrollBegin { delta_x: -9.0 })
        );
        assert_eq!(
            recognizer.update_swipe("touchpad", -2.5, 30.0, 30_000),
            Some(TouchpadGestureEvent::HorizontalScrollUpdate { delta_x: -2.5 })
        );
        assert_eq!(
            recognizer.end_swipe("touchpad", false, 300_000),
            Some(TouchpadGestureEvent::HorizontalScrollEnd {
                cancelled: false,
                projected_delta_x: -11.5,
            })
        );
    }

    #[test]
    fn quick_horizontal_swipe_projects_past_the_next_tile_threshold() {
        let mut recognizer = TouchpadGestureRecognizer::default();
        recognizer.begin_swipe(
            "touchpad",
            3,
            HorizontalScrollDirections {
                left: true,
                right: true,
            },
        );

        assert_eq!(recognizer.update_swipe("touchpad", -4.0, 0.0, 10_000), None);
        assert_eq!(
            recognizer.update_swipe("touchpad", -5.0, 0.0, 20_000),
            Some(TouchpadGestureEvent::HorizontalScrollBegin { delta_x: -9.0 })
        );
        assert_eq!(
            recognizer.update_swipe("touchpad", -2.5, 0.0, 30_000),
            Some(TouchpadGestureEvent::HorizontalScrollUpdate { delta_x: -2.5 })
        );
        let Some(TouchpadGestureEvent::HorizontalScrollEnd {
            cancelled: false,
            projected_delta_x,
        }) = recognizer.end_swipe("touchpad", false, 40_000)
        else {
            panic!("quick swipe did not finish as horizontal scrolling");
        };
        assert!(projected_delta_x < -100.0);
        assert!(projected_delta_x > -200.0);
    }

    #[test]
    fn disabled_horizontal_direction_keeps_the_shortcut_threshold() {
        let mut recognizer = TouchpadGestureRecognizer::default();
        recognizer.begin_swipe(
            "touchpad",
            3,
            HorizontalScrollDirections {
                left: false,
                right: true,
            },
        );

        assert_eq!(
            recognizer.update_swipe("touchpad", -20.0, 0.0, 10_000),
            None
        );
        assert_eq!(
            recognizer.update_swipe("touchpad", -81.0, 0.0, 20_000),
            Some(TouchpadGestureEvent::Trigger(
                ShortcutGesture::ThreeFingerSwipeLeft
            ))
        );
    }
}
