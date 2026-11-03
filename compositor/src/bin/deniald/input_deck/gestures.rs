//! Whole-output swipe arbitration for the input deck.
//!
//! Keys and one/two-finger pad input keep their contacts until coordinated
//! movement wins a configured swipe. The shared recognizer owns directions,
//! distances, repeats and continuous scrolling-layout motion.
use std::collections::{BTreeMap, BTreeSet};

use crate::touchpad_gestures::{ActiveSwipe, HorizontalScrollDirections, TouchpadGestureEvent};

const CONTACT_SLOP: f64 = 8.0;

#[derive(Clone, Copy, Debug)]
struct Contact {
    start: (f64, f64),
    position: (f64, f64),
}

struct Candidate {
    slots: Vec<i32>,
    center: (f64, f64),
    swipe: ActiveSwipe,
}

#[derive(Default)]
pub(crate) struct ScreenGestures {
    contacts: BTreeMap<i32, Contact>,
    candidate: Option<Candidate>,
    captured: bool,
    last_time: u64,
    // Flutter may still be processing earlier Down events when native input has
    // already finished a fast swipe. Do not accept their delayed key/button
    // commands until the matching Cancel events have reached the panel.
    pending_cancellations: BTreeSet<i32>,
}

#[derive(Default, Debug)]
pub(crate) struct Update {
    pub(crate) consume: bool,
    pub(crate) claimed_slots: Vec<i32>,
    pub(crate) event: Option<TouchpadGestureEvent>,
}

impl ScreenGestures {
    pub(crate) fn contains(&self, slot: i32) -> bool {
        self.contacts.contains_key(&slot)
    }

    pub(crate) fn blocks_input(&self) -> bool {
        self.captured || !self.pending_cancellations.is_empty()
    }

    pub(crate) fn slots(&self) -> Vec<i32> {
        self.contacts.keys().copied().collect()
    }

    pub(crate) fn await_cancellation(&mut self, slots: impl IntoIterator<Item = i32>) {
        self.pending_cancellations.extend(slots);
    }

    pub(crate) fn acknowledge_cancellation(&mut self, device: i32) {
        if device > 0 {
            self.pending_cancellations.remove(&(device - 1));
        }
    }

    pub(crate) fn down(
        &mut self,
        slot: i32,
        position: (f64, f64),
        directions: HorizontalScrollDirections,
    ) -> Update {
        if self.contacts.contains_key(&slot) || !finite(position) {
            return Update::default();
        }
        let blocked = self.blocks_input();
        self.contacts.insert(
            slot,
            Contact {
                start: position,
                position,
            },
        );
        if blocked {
            self.captured = true;
            return Update {
                consume: true,
                ..Update::default()
            };
        }
        if matches!(self.contacts.len(), 3 | 4) {
            // The fourth finger can promote an unclaimed three-finger candidate.
            for contact in self.contacts.values_mut() {
                contact.start = contact.position;
            }
            let slots = self.slots();
            self.candidate = Some(Candidate {
                center: self.center(&slots).expect("candidate contacts disappeared"),
                swipe: ActiveSwipe::new(slots.len() as u32, directions),
                slots,
            });
        } else {
            self.candidate = None;
        }
        Update::default()
    }

    pub(crate) fn motion(&mut self, slot: i32, position: (f64, f64), time: u64) -> Update {
        let Some(contact) = self.contacts.get_mut(&slot) else {
            return Update::default();
        };
        if !finite(position) {
            return self.cancel(time);
        }
        contact.position = position;
        self.last_time = time;
        let mut update = Update {
            consume: self.captured,
            ..Update::default()
        };
        let Some(mut candidate) = self.candidate.take() else {
            return update;
        };
        if !candidate.slots.contains(&slot) {
            self.candidate = Some(candidate);
            return update;
        }
        let Some(center) = self.center(&candidate.slots) else {
            return update;
        };
        if !self.captured && !self.coherent(&candidate.slots) {
            self.candidate = Some(candidate);
            return update;
        }
        match candidate.swipe.update(
            center.0 - candidate.center.0,
            center.1 - candidate.center.1,
            time,
        ) {
            Ok(event) => {
                candidate.center = center;
                if event.is_some() && !self.captured {
                    self.captured = true;
                    update.claimed_slots = self.slots();
                    update.consume = true;
                }
                update.event = event;
                self.candidate = Some(candidate);
            }
            Err(()) => {
                update.event = candidate.swipe.end_event(true, time);
            }
        }
        update
    }

    pub(crate) fn up(&mut self, slot: i32, cancelled: bool, time: u64) -> Update {
        if self.contacts.remove(&slot).is_none() {
            return Update::default();
        }
        self.last_time = time;
        let mut update = Update {
            consume: self.captured,
            ..Update::default()
        };
        if self
            .candidate
            .as_ref()
            .is_some_and(|candidate| candidate.slots.contains(&slot))
        {
            update.event = self
                .candidate
                .take()
                .and_then(|candidate| candidate.swipe.end_event(cancelled, time));
        }
        // Keep the remaining fingers owned; a finished swipe must not become a
        // two-finger scroll, key release tap or drag on the same contact stream.
        if self.contacts.is_empty() {
            self.captured = false;
        }
        update
    }

    pub(crate) fn cancel_all(&mut self) -> Update {
        self.cancel(self.last_time)
    }

    pub(crate) fn cancel(&mut self, time: u64) -> Update {
        let update = Update {
            consume: self.captured,
            claimed_slots: self.slots(),
            event: self
                .candidate
                .take()
                .and_then(|candidate| candidate.swipe.end_event(true, time)),
        };
        self.contacts.clear();
        self.pending_cancellations.clear();
        self.captured = false;
        update
    }

    fn center(&self, slots: &[i32]) -> Option<(f64, f64)> {
        let mut sum = (0.0, 0.0);
        for slot in slots {
            let point = self.contacts.get(slot)?.position;
            sum.0 += point.0;
            sum.1 += point.1;
        }
        Some((sum.0 / slots.len() as f64, sum.1 / slots.len() as f64))
    }

    fn coherent(&self, slots: &[i32]) -> bool {
        let deltas = slots
            .iter()
            .map(|slot| {
                let contact = &self.contacts[slot];
                (
                    contact.position.0 - contact.start.0,
                    contact.position.1 - contact.start.1,
                )
            })
            .collect::<Vec<_>>();
        let mean = deltas
            .iter()
            .fold((0.0, 0.0), |sum, delta| (sum.0 + delta.0, sum.1 + delta.1));
        let horizontal = mean.0.abs() >= mean.1.abs();
        deltas.iter().all(|delta| {
            let (along, across, direction) = if horizontal {
                (delta.0, delta.1, mean.0)
            } else {
                (delta.1, delta.0, mean.1)
            };
            along.abs() >= CONTACT_SLOP && along * direction > 0.0 && along.abs() >= across.abs()
        })
    }
}

fn finite(point: (f64, f64)) -> bool {
    point.0.is_finite() && point.1.is_finite()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::native_shortcut::ShortcutGesture;

    fn down(gestures: &mut ScreenGestures, fingers: i32) {
        for slot in 0..fingers {
            assert!(
                !gestures
                    .down(
                        slot,
                        (100.0 * f64::from(slot), 500.0),
                        HorizontalScrollDirections::default()
                    )
                    .consume
            );
        }
    }

    fn move_all(gestures: &mut ScreenGestures, fingers: i32, dx: f64, dy: f64) -> Update {
        let mut last = Update::default();
        for slot in 0..fingers {
            last = gestures.motion(
                slot,
                (100.0 * f64::from(slot) + dx, 500.0 + dy),
                100_000 + slot as u64,
            );
        }
        last
    }

    #[test]
    fn three_finger_keyboard_chords_and_one_moving_pad_finger_do_not_claim_a_swipe() {
        let mut gestures = ScreenGestures::default();
        down(&mut gestures, 3);
        assert!(!gestures.motion(2, (500.0, 500.0), 100_000).consume);
        assert!(!gestures.blocks_input());
        for slot in 0..3 {
            assert!(!gestures.up(slot, false, 200_000).consume);
        }
    }

    #[test]
    fn coordinated_motion_uses_the_existing_three_finger_binding() {
        let mut gestures = ScreenGestures::default();
        down(&mut gestures, 3);
        let update = move_all(&mut gestures, 3, 0.0, -110.0);
        assert_eq!(
            update.event,
            Some(TouchpadGestureEvent::Trigger(
                ShortcutGesture::ThreeFingerSwipeUp
            ))
        );
        assert_eq!(update.claimed_slots, [0, 1, 2]);
        assert!(gestures.blocks_input());
    }

    #[test]
    fn four_fingers_promote_before_recognition_and_reuse_workspace_bindings() {
        let mut gestures = ScreenGestures::default();
        down(&mut gestures, 4);
        let update = move_all(&mut gestures, 4, -110.0, 0.0);
        assert_eq!(
            update.event,
            Some(TouchpadGestureEvent::Trigger(
                ShortcutGesture::FourFingerSwipeLeft
            ))
        );
        assert_eq!(update.claimed_slots, [0, 1, 2, 3]);
        assert_eq!(
            gestures.up(0, false, 200_000).event,
            Some(TouchpadGestureEvent::End(
                ShortcutGesture::FourFingerSwipeLeft
            ))
        );
        assert!(gestures.motion(3, (600.0, 500.0), 210_000).consume);
        for slot in 1..4 {
            assert!(gestures.up(slot, false, 220_000).consume);
        }
        assert!(!gestures.blocks_input());
    }

    #[test]
    fn delayed_flutter_commands_stay_blocked_until_cancel_delivery() {
        let mut gestures = ScreenGestures::default();
        down(&mut gestures, 3);
        move_all(&mut gestures, 3, 0.0, -110.0);
        gestures.await_cancellation([0, 1, 2]);
        for slot in 0..3 {
            gestures.up(slot, false, 200_000);
        }
        assert!(gestures.blocks_input());
        gestures.acknowledge_cancellation(1);
        gestures.acknowledge_cancellation(2);
        assert!(gestures.blocks_input());
        gestures.acknowledge_cancellation(3);
        assert!(!gestures.blocks_input());
        assert!(
            !gestures
                .down(0, (10.0, 10.0), HorizontalScrollDirections::default())
                .consume
        );
    }

    #[test]
    fn continuous_scrolling_uses_the_same_begin_update_and_cancel_as_a_touchpad() {
        let mut gestures = ScreenGestures::default();
        let directions = HorizontalScrollDirections {
            left: true,
            right: true,
        };
        for slot in 0..3 {
            gestures.down(slot, (100.0 * f64::from(slot), 500.0), directions);
        }
        assert!(matches!(
            move_all(&mut gestures, 3, 12.0, 0.0).event,
            Some(TouchpadGestureEvent::HorizontalScrollBegin { .. })
        ));
        assert!(matches!(
            move_all(&mut gestures, 3, 24.0, 0.0).event,
            Some(TouchpadGestureEvent::HorizontalScrollUpdate { .. })
        ));
        assert!(matches!(
            gestures.cancel(200_000).event,
            Some(TouchpadGestureEvent::HorizontalScrollEnd {
                cancelled: true,
                ..
            })
        ));
        assert!(!gestures.blocks_input());
    }

    #[test]
    fn five_finger_typing_and_diagonal_motion_do_not_become_shortcuts() {
        let mut gestures = ScreenGestures::default();
        down(&mut gestures, 5);
        assert!(move_all(&mut gestures, 5, 150.0, 0.0).event.is_none());
        gestures.cancel(200_000);
        down(&mut gestures, 4);
        assert!(move_all(&mut gestures, 4, 150.0, 150.0).event.is_none());
        assert!(!gestures.blocks_input());
    }
    #[test]
    fn a_late_fourth_finger_does_not_change_an_owned_three_finger_gesture() {
        let mut gestures = ScreenGestures::default();
        down(&mut gestures, 3);
        move_all(&mut gestures, 3, 0.0, -110.0);
        assert!(
            gestures
                .down(3, (300.0, 390.0), HorizontalScrollDirections::default())
                .consume
        );
        assert!(gestures.motion(3, (300.0, 100.0), 150_000).event.is_none());
        assert_eq!(
            gestures.up(0, false, 200_000).event,
            Some(TouchpadGestureEvent::End(
                ShortcutGesture::ThreeFingerSwipeUp
            ))
        );
        for slot in 1..4 {
            assert!(gestures.up(slot, false, 220_000).consume);
        }
        assert!(!gestures.blocks_input());
    }
}
