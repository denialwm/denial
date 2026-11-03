//! Compositor-owned direct-touch desktop and window gestures.
//!
//! Recognition lives here so the ordinary pointer, Wayland-touch and Flutter
//! routes remain unaware of window gesture policy. The input entry point only
//! supplies hit-tested contacts, retires routes when this recognizer wins, and
//! applies the resulting ordinary Denial window actions.

use std::collections::HashMap;

use smithay::desktop::Window;
use smithay::utils::{Logical, Point, Rectangle, SERIAL_COUNTER, Size};

use super::super::RuntimeState;
use super::super::touchpad_gestures::{
    ActiveSwipe, HorizontalScrollDirections, TouchpadGestureEvent,
};
use super::super::window_grab::{TileMoveGrab, constrain_dimension};
use super::super::window_layout::LayoutResizeEdges;
use super::super::wire::{WindowGeometry, WindowPlacementChange, WindowPlacementPhase};
use super::managed_window::ManagedWindow;
use super::window_management;

/// The invisible gesture affordance at the bottom of a normal window.
pub(super) const WINDOW_TOUCH_STRIP_HEIGHT: f64 = 48.0;
/// The square touch target at each corner used for one-finger movement.
pub(super) const WINDOW_TOUCH_CORNER_SIZE: f64 = 64.0;

const MOVE_SLOP: f64 = 4.0;
const MINIMIZE_SWIPE_DISTANCE: f64 = 96.0;
const PINCH_SLOP: f64 = 16.0;
const PINCH_TRANSLATION_DOMINANCE: f64 = 1.5;
const FOUR_FINGER_INWARD_SLOP: f64 = 8.0;
const FOUR_FINGER_CRUSH_DISTANCE: f64 = 32.0;
const MIN_LOCAL_WINDOW_DIMENSION: f64 = 64.0;
const MAX_WINDOW_DIMENSION: f64 = 16_384.0;

#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) struct TouchWindowTarget {
    pub window_id: u64,
    pub geometry: WindowGeometry,
    pub in_gesture_strip: bool,
    pub in_move_corner: bool,
    pub geometry_locked: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) enum TouchWindowAction {
    Placement {
        window_id: u64,
        phase: WindowPlacementPhase,
        change: WindowPlacementChange,
        geometry: WindowGeometry,
    },
    Minimize {
        window_id: u64,
    },
    Close {
        window_id: u64,
    },
    Swipe {
        event: TouchpadGestureEvent,
        origin: Point<f64, Logical>,
    },
}

#[derive(Debug, Default, PartialEq)]
pub(super) struct TouchGestureUpdate {
    pub consume: bool,
    /// Contacts which may already have entered Flutter or a Wayland client.
    pub captured_slots: Vec<i32>,
    pub actions: Vec<TouchWindowAction>,
}

#[derive(Clone, Copy, Debug)]
struct Contact {
    origin: Point<f64, Logical>,
    position: Point<f64, Logical>,
    app_drag: bool,
    target: Option<TouchWindowTarget>,
    desktop_background: bool,
    captured: bool,
}

#[derive(Clone, Copy, Debug)]
enum Gesture {
    Move {
        slot: i32,
        window_id: u64,
        origin: Point<f64, Logical>,
        initial_geometry: WindowGeometry,
        last_geometry: WindowGeometry,
        started: bool,
        geometry_locked: bool,
    },
    PinchCandidate {
        slots: [i32; 2],
        window_id: u64,
        initial_positions: [Point<f64, Logical>; 2],
        initial_geometry: WindowGeometry,
        moved: [bool; 2],
    },
    Pinch {
        slots: [i32; 2],
        window_id: u64,
        initial_positions: [Point<f64, Logical>; 2],
        initial_geometry: WindowGeometry,
        last_geometry: WindowGeometry,
    },
    MinimizeSwipe {
        slots: [i32; 2],
        window_id: u64,
        origin: Point<f64, Logical>,
    },
    Swipe {
        slots: [i32; 4],
        fingers: usize,
        origin: Point<f64, Logical>,
        last_center: Point<f64, Logical>,
        crush: Option<WindowCrush>,
    },
    /// Keep every participant compositor-owned until all fingers are lifted.
    Blocked { window_id: Option<u64> },
}

#[derive(Clone, Copy, Debug)]
struct WindowCrush {
    window_id: u64,
    center: Point<f64, Logical>,
    initial_distances: [f64; 4],
    moved: [bool; 4],
}

impl Gesture {
    fn window_id(self) -> Option<u64> {
        match self {
            Self::Move { window_id, .. }
            | Self::PinchCandidate { window_id, .. }
            | Self::Pinch { window_id, .. }
            | Self::MinimizeSwipe { window_id, .. } => Some(window_id),
            Self::Swipe { .. } => None,
            Self::Blocked { window_id, .. } => window_id,
        }
    }

    fn includes(self, slot: i32) -> bool {
        match self {
            Self::Move {
                slot: gesture_slot, ..
            } => gesture_slot == slot,
            Self::PinchCandidate { slots, .. }
            | Self::Pinch { slots, .. }
            | Self::MinimizeSwipe { slots, .. } => slots.contains(&slot),
            Self::Swipe { slots, fingers, .. } => slots[..fingers].contains(&slot),
            Self::Blocked { .. } => true,
        }
    }

    fn finish_action(self) -> Option<TouchWindowAction> {
        match self {
            Self::Move {
                window_id,
                last_geometry,
                started: true,
                ..
            } => Some(TouchWindowAction::Placement {
                window_id,
                phase: WindowPlacementPhase::End,
                change: WindowPlacementChange::Move,
                geometry: last_geometry,
            }),
            Self::Pinch {
                window_id,
                last_geometry,
                ..
            } => Some(TouchWindowAction::Placement {
                window_id,
                phase: WindowPlacementPhase::End,
                change: WindowPlacementChange::Resize,
                geometry: last_geometry,
            }),
            _ => None,
        }
    }
}

#[derive(Default)]
pub(super) struct TouchGestureState {
    contacts: HashMap<i32, Contact>,
    gesture: Option<Gesture>,
    placement_transform: Option<(u64, PlacementTransform)>,
    layout_move: Option<TileMoveGrab>,
    swipe: Option<ActiveSwipe>,
    swipe_directions: HorizontalScrollDirections,
    last_timestamp_micros: u64,
}

#[derive(Clone, Copy, Debug)]
struct PlacementTransform {
    source: WindowGeometry,
    restored: WindowGeometry,
}

impl PlacementTransform {
    fn apply(self, geometry: WindowGeometry, change: WindowPlacementChange) -> WindowGeometry {
        if change == WindowPlacementChange::Move {
            return WindowGeometry {
                x: self.restored.x + geometry.x - self.source.x,
                y: self.restored.y + geometry.y - self.source.y,
                ..self.restored
            };
        }
        let width = self.restored.width + geometry.width - self.source.width;
        let height = self.restored.height + geometry.height - self.source.height;
        WindowGeometry {
            x: self.restored.x + geometry.x - self.source.x,
            y: self.restored.y + geometry.y - self.source.y,
            width,
            height,
        }
    }
}

impl TouchGestureState {
    pub(super) fn set_swipe_directions(&mut self, directions: HorizontalScrollDirections) {
        self.swipe_directions = directions;
    }

    pub(super) fn down(
        &mut self,
        slot: i32,
        position: Point<f64, Logical>,
        target: Option<TouchWindowTarget>,
    ) -> TouchGestureUpdate {
        self.down_contact(slot, position, target, false)
    }

    pub(super) fn down_on_desktop(
        &mut self,
        slot: i32,
        position: Point<f64, Logical>,
    ) -> TouchGestureUpdate {
        self.down_contact(slot, position, None, true)
    }

    fn down_contact(
        &mut self,
        slot: i32,
        position: Point<f64, Logical>,
        target: Option<TouchWindowTarget>,
        desktop_background: bool,
    ) -> TouchGestureUpdate {
        self.contacts.insert(
            slot,
            Contact {
                origin: position,
                position,
                app_drag: false,
                target,
                desktop_background,
                captured: false,
            },
        );
        if target.is_none() && !desktop_background {
            return TouchGestureUpdate::default();
        }
        let window_id = target.map(|target| target.window_id);

        if matches!(self.gesture, Some(Gesture::Blocked { window_id: blocked }) if blocked.is_none() || blocked == window_id)
        {
            return TouchGestureUpdate {
                consume: true,
                captured_slots: self.capture_slots(&[slot]),
                actions: Vec::new(),
            };
        }
        if matches!(self.gesture, Some(Gesture::Blocked { .. })) {
            return TouchGestureUpdate::default();
        }

        let desktop_slots = self.desktop_slots();
        if desktop_slots.len() >= 3 {
            if matches!(self.gesture, Some(Gesture::Swipe { fingers: 4, .. }))
                || self.swipe.as_ref().is_some_and(ActiveSwipe::has_started)
                || (desktop_slots.len() == 3 && matches!(self.gesture, Some(Gesture::Swipe { .. })))
            {
                return TouchGestureUpdate {
                    consume: true,
                    captured_slots: self.capture_slots(&[slot]),
                    actions: Vec::new(),
                };
            }
            return self.begin_swipe(desktop_slots, target);
        }

        let same_window = self.window_slots(window_id);
        let Some(target) = target else {
            return TouchGestureUpdate::default();
        };
        if let Some(gesture) = self.gesture
            && gesture.window_id() == window_id
        {
            if matches!(gesture, Gesture::Move { .. }) && same_window.len() == 2 {
                return self.promote_move_to_two_fingers(gesture, same_window, target);
            }
            return TouchGestureUpdate {
                consume: self
                    .contacts
                    .get(&slot)
                    .is_some_and(|contact| contact.captured),
                ..TouchGestureUpdate::default()
            };
        }
        if self.gesture.is_some() {
            return TouchGestureUpdate::default();
        }

        let uncaptured = same_window
            .iter()
            .copied()
            .filter(|candidate| {
                self.contacts
                    .get(candidate)
                    .is_some_and(|contact| !contact.captured)
            })
            .collect::<Vec<_>>();
        if uncaptured.len() == 2 {
            let slots = [uncaptured[0], uncaptured[1]];
            if self.contacts_in_gesture_strip(slots) {
                return self.begin_minimize_swipe(slots, target.window_id);
            }
            if target.geometry_locked || slots.iter().any(|slot| self.contacts[slot].app_drag) {
                // Adding a finger to an established app drag (e.g. joystick
                // plus camera) must not turn it into a window resize. Explicit
                // corner moves and bottom-strip gestures retain their paths.
                return TouchGestureUpdate::default();
            }
            return self.begin_pinch_candidate(slots, target.geometry);
        }

        if target.in_move_corner && !target.geometry_locked {
            self.gesture = Some(Gesture::Move {
                slot,
                window_id: target.window_id,
                origin: position,
                initial_geometry: target.geometry,
                last_geometry: target.geometry,
                started: false,
                geometry_locked: target.geometry_locked,
            });
            return TouchGestureUpdate::default();
        }

        TouchGestureUpdate::default()
    }

    #[cfg(test)]
    fn motion(&mut self, slot: i32, position: Point<f64, Logical>) -> TouchGestureUpdate {
        self.motion_at(slot, position, 0)
    }

    pub(super) fn motion_at(
        &mut self,
        slot: i32,
        position: Point<f64, Logical>,
        timestamp_micros: u64,
    ) -> TouchGestureUpdate {
        self.last_timestamp_micros = timestamp_micros;
        let Some(contact) = self.contacts.get_mut(&slot) else {
            return TouchGestureUpdate::default();
        };
        contact.position = position;
        let captured = contact.captured;
        if self.gesture.is_none() && !captured {
            let delta = position - contact.origin;
            contact.app_drag |= delta.x * delta.x + delta.y * delta.y >= MOVE_SLOP * MOVE_SLOP;
        }

        if matches!(
            self.gesture,
            Some(Gesture::PinchCandidate { slots, .. }) if slots.contains(&slot)
        ) {
            let Some(Gesture::PinchCandidate {
                slots,
                window_id,
                initial_positions,
                initial_geometry,
                mut moved,
            }) = self.gesture.take()
            else {
                unreachable!();
            };
            let moved_slot = slots
                .iter()
                .position(|candidate| *candidate == slot)
                .expect("pinch candidate lost its moving contact");
            moved[moved_slot] = true;
            let current_positions = self.contact_positions(slots);
            if moved.iter().all(|contact_moved| *contact_moved)
                && current_positions
                    .is_some_and(|current| intentional_pinch(initial_positions, current))
            {
                let current_positions = current_positions.expect("pinch contacts disappeared");
                let geometry = directional_pinch_geometry(
                    initial_geometry,
                    initial_positions,
                    current_positions,
                );
                let captured_slots = self.capture_slots(&slots);
                self.gesture = Some(Gesture::Pinch {
                    slots,
                    window_id,
                    initial_positions,
                    initial_geometry,
                    last_geometry: geometry,
                });
                return TouchGestureUpdate {
                    consume: true,
                    captured_slots,
                    actions: vec![
                        TouchWindowAction::Placement {
                            window_id,
                            phase: WindowPlacementPhase::Begin,
                            change: WindowPlacementChange::Resize,
                            geometry: initial_geometry,
                        },
                        TouchWindowAction::Placement {
                            window_id,
                            phase: WindowPlacementPhase::Update,
                            change: WindowPlacementChange::Resize,
                            geometry,
                        },
                    ],
                };
            }
            self.gesture = Some(Gesture::PinchCandidate {
                slots,
                window_id,
                initial_positions,
                initial_geometry,
                moved,
            });
            return TouchGestureUpdate {
                consume: captured,
                ..TouchGestureUpdate::default()
            };
        }

        if !captured {
            let Some(Gesture::Move {
                slot: gesture_slot,
                window_id,
                origin,
                initial_geometry,
                last_geometry: _,
                started: false,
                geometry_locked: false,
            }) = self.gesture
            else {
                return TouchGestureUpdate::default();
            };
            if gesture_slot != slot {
                return TouchGestureUpdate::default();
            }
            let delta = position - origin;
            if delta.x * delta.x + delta.y * delta.y < MOVE_SLOP * MOVE_SLOP {
                return TouchGestureUpdate::default();
            }
            let last_geometry = WindowGeometry {
                x: initial_geometry.x + delta.x,
                y: initial_geometry.y + delta.y,
                ..initial_geometry
            };
            let captured_slots = self.capture_slots(&[slot]);
            self.gesture = Some(Gesture::Move {
                slot,
                window_id,
                origin,
                initial_geometry,
                last_geometry,
                started: true,
                geometry_locked: false,
            });
            return TouchGestureUpdate {
                consume: true,
                captured_slots,
                actions: vec![
                    TouchWindowAction::Placement {
                        window_id,
                        phase: WindowPlacementPhase::Begin,
                        change: WindowPlacementChange::Move,
                        geometry: initial_geometry,
                    },
                    TouchWindowAction::Placement {
                        window_id,
                        phase: WindowPlacementPhase::Update,
                        change: WindowPlacementChange::Move,
                        geometry: last_geometry,
                    },
                ],
            };
        }

        let mut update = TouchGestureUpdate {
            consume: true,
            ..TouchGestureUpdate::default()
        };
        let Some(mut gesture) = self.gesture.take() else {
            return update;
        };
        match &mut gesture {
            Gesture::Move {
                slot: gesture_slot,
                window_id,
                origin,
                initial_geometry,
                last_geometry,
                started,
                geometry_locked,
            } if *gesture_slot == slot && !*geometry_locked => {
                let delta = position - *origin;
                if *started || delta.x * delta.x + delta.y * delta.y >= MOVE_SLOP * MOVE_SLOP {
                    if !*started {
                        update.actions.push(TouchWindowAction::Placement {
                            window_id: *window_id,
                            phase: WindowPlacementPhase::Begin,
                            change: WindowPlacementChange::Move,
                            geometry: *initial_geometry,
                        });
                        *started = true;
                    }
                    *last_geometry = WindowGeometry {
                        x: initial_geometry.x + delta.x,
                        y: initial_geometry.y + delta.y,
                        ..*initial_geometry
                    };
                    update.actions.push(TouchWindowAction::Placement {
                        window_id: *window_id,
                        phase: WindowPlacementPhase::Update,
                        change: WindowPlacementChange::Move,
                        geometry: *last_geometry,
                    });
                }
            }
            Gesture::Pinch {
                slots,
                window_id,
                initial_positions,
                initial_geometry,
                last_geometry,
            } if slots.contains(&slot) => {
                if let Some(current_positions) = self.contact_positions(*slots) {
                    *last_geometry = directional_pinch_geometry(
                        *initial_geometry,
                        *initial_positions,
                        current_positions,
                    );
                    update.actions.push(TouchWindowAction::Placement {
                        window_id: *window_id,
                        phase: WindowPlacementPhase::Update,
                        change: WindowPlacementChange::Resize,
                        geometry: *last_geometry,
                    });
                }
            }
            Gesture::MinimizeSwipe {
                slots,
                window_id,
                origin,
            } if slots.contains(&slot) => {
                if let Some(center) = self.contact_center(*slots) {
                    let delta = center - *origin;
                    if delta.y >= MINIMIZE_SWIPE_DISTANCE && delta.y >= delta.x.abs() {
                        update.actions.push(TouchWindowAction::Minimize {
                            window_id: *window_id,
                        });
                        gesture = Gesture::Blocked {
                            window_id: Some(*window_id),
                        };
                    }
                }
            }
            Gesture::Swipe {
                slots,
                fingers,
                origin,
                last_center,
                crush,
            } if slots[..*fingers].contains(&slot) => {
                if let Some(center) = self.swipe_center(&slots[..*fingers]) {
                    if let Some(crush) = crush {
                        let moved_slot = slots
                            .iter()
                            .position(|candidate| *candidate == slot)
                            .expect("four-finger gesture lost its moving contact");
                        crush.moved[moved_slot] = true;
                        if crush.moved.iter().all(|moved| *moved)
                            && self.contact_distances(*slots, crush.center).is_some_and(
                                |distances| {
                                    inward_crush(
                                        crush.initial_distances,
                                        distances,
                                        point_distance(*origin, center),
                                    )
                                },
                            )
                            && self.swipe.as_ref().is_none_or(|swipe| !swipe.has_started())
                        {
                            update.actions.push(TouchWindowAction::Close {
                                window_id: crush.window_id,
                            });
                            self.swipe = None;
                            self.gesture = Some(Gesture::Blocked { window_id: None });
                            return update;
                        }
                    }
                    let delta = center - *last_center;
                    *last_center = center;
                    if let Some(swipe) = self.swipe.as_mut() {
                        match swipe.update(delta.x, delta.y, timestamp_micros) {
                            Ok(Some(event)) => update.actions.push(TouchWindowAction::Swipe {
                                event,
                                origin: *origin,
                            }),
                            Ok(None) => {}
                            Err(()) => {
                                self.gesture = Some(gesture);
                                if let Some(action) = self.finish_swipe(true) {
                                    update.actions.push(action);
                                }
                                gesture = Gesture::Blocked { window_id: None };
                            }
                        }
                    }
                }
            }
            _ => {}
        }
        self.gesture = Some(gesture);
        update
    }

    #[cfg(test)]
    fn up(&mut self, slot: i32) -> TouchGestureUpdate {
        self.up_at(slot, 0)
    }

    pub(super) fn up_at(&mut self, slot: i32, timestamp_micros: u64) -> TouchGestureUpdate {
        self.finish_contact(slot, false, timestamp_micros)
    }

    #[cfg(test)]
    fn cancel(&mut self, slot: i32) -> TouchGestureUpdate {
        self.cancel_at(slot, 0)
    }

    pub(super) fn cancel_at(&mut self, slot: i32, timestamp_micros: u64) -> TouchGestureUpdate {
        self.finish_contact(slot, true, timestamp_micros)
    }

    fn finish_contact(
        &mut self,
        slot: i32,
        cancelled: bool,
        timestamp_micros: u64,
    ) -> TouchGestureUpdate {
        self.last_timestamp_micros = timestamp_micros;
        let Some(contact) = self.contacts.remove(&slot) else {
            return TouchGestureUpdate::default();
        };
        let mut update = TouchGestureUpdate {
            consume: contact.captured,
            ..TouchGestureUpdate::default()
        };
        let Some(gesture) = self.gesture else {
            return update;
        };
        if !gesture.includes(slot) {
            self.gesture = Some(gesture);
            return update;
        }
        if let Some(action) = self.finish_swipe(cancelled) {
            update.actions.push(action);
        }
        self.gesture = None;
        if matches!(gesture, Gesture::PinchCandidate { .. }) {
            return update;
        }

        if let Some(action) = gesture.finish_action() {
            update.actions.push(action);
        }
        if self.has_captured_window_contact(gesture.window_id())
            && matches!(
                gesture,
                Gesture::Pinch { .. }
                    | Gesture::MinimizeSwipe { .. }
                    | Gesture::Swipe { .. }
                    | Gesture::Blocked { .. }
            )
        {
            self.gesture = Some(match gesture {
                Gesture::Blocked { .. } => gesture,
                _ => Gesture::Blocked {
                    window_id: gesture.window_id(),
                },
            });
        }
        update
    }

    pub(super) fn cancel_all(&mut self) -> Vec<TouchWindowAction> {
        let mut actions = self.finish_swipe(true).into_iter().collect::<Vec<_>>();
        actions.extend(self.gesture.take().and_then(Gesture::finish_action));
        self.contacts.clear();
        actions
    }

    fn finish_swipe(&mut self, cancelled: bool) -> Option<TouchWindowAction> {
        let swipe = self.swipe.take()?;
        let Some(Gesture::Swipe { origin, .. }) = self.gesture else {
            return None;
        };
        swipe
            .end_event(cancelled, self.last_timestamp_micros)
            .map(|event| TouchWindowAction::Swipe { event, origin })
    }

    fn promote_move_to_two_fingers(
        &mut self,
        move_gesture: Gesture,
        mut slots: Vec<i32>,
        target: TouchWindowTarget,
    ) -> TouchGestureUpdate {
        slots.sort_unstable();
        let slots = [slots[0], slots[1]];
        let both_in_gesture_strip = self.contacts_in_gesture_strip(slots);
        if !both_in_gesture_strip && target.geometry_locked {
            return TouchGestureUpdate::default();
        }
        let actions = move_gesture.finish_action().into_iter().collect::<Vec<_>>();
        if both_in_gesture_strip {
            let origin = self
                .contact_center(slots)
                .expect("two contacts disappeared");
            self.gesture = Some(Gesture::MinimizeSwipe {
                slots,
                window_id: target.window_id,
                origin,
            });
            TouchGestureUpdate {
                consume: true,
                captured_slots: self.capture_slots(&slots),
                actions,
            }
        } else {
            let initial_geometry = match move_gesture {
                Gesture::Move { last_geometry, .. } => last_geometry,
                _ => unreachable!(),
            };
            self.begin_pinch_candidate(slots, initial_geometry);
            TouchGestureUpdate {
                actions,
                ..TouchGestureUpdate::default()
            }
        }
    }

    fn begin_minimize_swipe(&mut self, mut slots: [i32; 2], window_id: u64) -> TouchGestureUpdate {
        slots.sort_unstable();
        let origin = self
            .contact_center(slots)
            .expect("two bottom-strip contacts disappeared");
        self.gesture = Some(Gesture::MinimizeSwipe {
            slots,
            window_id,
            origin,
        });
        TouchGestureUpdate {
            consume: true,
            captured_slots: self.capture_slots(&slots),
            actions: Vec::new(),
        }
    }

    fn begin_pinch_candidate(
        &mut self,
        mut slots: [i32; 2],
        initial_geometry: WindowGeometry,
    ) -> TouchGestureUpdate {
        slots.sort_unstable();
        let Some(initial_positions) = self.contact_positions(slots) else {
            return TouchGestureUpdate::default();
        };
        let window_id = self.contacts[&slots[0]]
            .target
            .expect("pinch contact lost its window")
            .window_id;
        self.gesture = Some(Gesture::PinchCandidate {
            slots,
            window_id,
            initial_positions,
            initial_geometry,
            moved: [false; 2],
        });
        TouchGestureUpdate::default()
    }

    fn begin_swipe(
        &mut self,
        slots: Vec<i32>,
        newest_target: Option<TouchWindowTarget>,
    ) -> TouchGestureUpdate {
        let fingers = slots.len().min(4);
        let mut swipe_slots = [0; 4];
        swipe_slots[..fingers].copy_from_slice(&slots[..fingers]);
        let origin = self
            .swipe_center(&slots[..fingers])
            .expect("swipe contacts disappeared");
        let mut actions = self.finish_swipe(true).into_iter().collect::<Vec<_>>();
        actions.extend(self.gesture.take().and_then(Gesture::finish_action));
        // Closing is a window gesture: every contact must start on that window.
        // Translation is handled by the shared touchpad swipe recognizer.
        let crush = (fingers == 4)
            .then(|| {
                let target = newest_target?;
                if !slots[..fingers]
                    .iter()
                    .all(|slot| self.contacts[slot].belongs_to(Some(target.window_id)))
                {
                    return None;
                }
                let center = Point::from((
                    target.geometry.x + target.geometry.width * 0.5,
                    target.geometry.y + target.geometry.height * 0.5,
                ));
                Some(WindowCrush {
                    window_id: target.window_id,
                    center,
                    initial_distances: self.contact_distances(swipe_slots, center)?,
                    moved: [false; 4],
                })
            })
            .flatten();
        self.swipe = Some(ActiveSwipe::new(fingers as u32, self.swipe_directions));
        self.gesture = Some(Gesture::Swipe {
            slots: swipe_slots,
            fingers,
            origin,
            last_center: origin,
            crush,
        });
        TouchGestureUpdate {
            consume: true,
            captured_slots: self.capture_slots(&slots),
            actions,
        }
    }

    fn desktop_slots(&self) -> Vec<i32> {
        let mut slots = self
            .contacts
            .iter()
            .filter_map(|(slot, contact)| {
                (contact.target.is_some() || contact.desktop_background).then_some(*slot)
            })
            .collect::<Vec<_>>();
        slots.sort_unstable();
        slots
    }

    fn window_slots(&self, window_id: Option<u64>) -> Vec<i32> {
        let mut slots = self
            .contacts
            .iter()
            .filter_map(|(slot, contact)| contact.belongs_to(window_id).then_some(*slot))
            .collect::<Vec<_>>();
        slots.sort_unstable();
        slots
    }

    fn capture_slots(&mut self, slots: &[i32]) -> Vec<i32> {
        slots
            .iter()
            .copied()
            .filter(|slot| {
                let Some(contact) = self.contacts.get_mut(slot) else {
                    return false;
                };
                let newly_captured = !contact.captured;
                contact.captured = true;
                newly_captured
            })
            .collect()
    }

    fn contacts_in_gesture_strip(&self, slots: [i32; 2]) -> bool {
        slots.iter().all(|slot| {
            self.contacts
                .get(slot)
                .and_then(|contact| contact.target)
                .is_some_and(|target| target.in_gesture_strip)
        })
    }

    fn contact_center(&self, slots: [i32; 2]) -> Option<Point<f64, Logical>> {
        self.contact_positions(slots).map(center_of_two)
    }

    fn contact_positions(&self, slots: [i32; 2]) -> Option<[Point<f64, Logical>; 2]> {
        Some([
            self.contacts.get(&slots[0])?.position,
            self.contacts.get(&slots[1])?.position,
        ])
    }

    fn swipe_center(&self, slots: &[i32]) -> Option<Point<f64, Logical>> {
        let mut center = Point::from((0.0, 0.0));
        for slot in slots {
            let position = self.contacts.get(slot)?.position;
            center.x += position.x;
            center.y += position.y;
        }
        center.x /= slots.len() as f64;
        center.y /= slots.len() as f64;
        Some(center)
    }

    fn contact_distances(&self, slots: [i32; 4], center: Point<f64, Logical>) -> Option<[f64; 4]> {
        let mut distances = [0.0; 4];
        for (index, slot) in slots.into_iter().enumerate() {
            distances[index] = point_distance(self.contacts.get(&slot)?.position, center);
        }
        Some(distances)
    }

    fn has_captured_window_contact(&self, window_id: Option<u64>) -> bool {
        self.contacts.values().any(|contact| {
            contact.captured && (window_id.is_none() || contact.belongs_to(window_id))
        })
    }
}

impl Contact {
    fn belongs_to(self, window_id: Option<u64>) -> bool {
        match window_id {
            Some(window_id) => self
                .target
                .is_some_and(|target| target.window_id == window_id),
            None => self.desktop_background,
        }
    }
}

fn intentional_pinch(initial: [Point<f64, Logical>; 2], current: [Point<f64, Logical>; 2]) -> bool {
    let first_motion = current[0] - initial[0];
    let second_motion = current[1] - initial[1];
    let opposing_motion =
        first_motion.x * second_motion.x + first_motion.y * second_motion.y <= 0.0;
    let initial_distance = point_distance(initial[0], initial[1]);
    let current_distance = point_distance(current[0], current[1]);
    let separation_change = (current_distance - initial_distance).abs();
    let translation = center_of_two(current) - center_of_two(initial);
    // A stationary contact may still emit motion events (including identical
    // coordinates). Both fingers must move beyond jitter before taking the
    // sequence away from the app; a moved-event boolean cannot establish intent.
    first_motion.x.hypot(first_motion.y) >= PINCH_SLOP * 0.5
        && second_motion.x.hypot(second_motion.y) >= PINCH_SLOP * 0.5
        && opposing_motion
        && separation_change >= PINCH_SLOP
        && separation_change >= translation.x.hypot(translation.y) * PINCH_TRANSLATION_DOMINANCE
}

fn directional_pinch_geometry(
    geometry: WindowGeometry,
    initial: [Point<f64, Logical>; 2],
    current: [Point<f64, Logical>; 2],
) -> WindowGeometry {
    let initial_center = center_of_two(initial);
    let current_center = center_of_two(current);
    let center_delta = current_center - initial_center;
    let initial_separation = initial[1] - initial[0];
    let current_separation = current[1] - current[0];
    let width = finite_dimension(
        geometry.width + current_separation.x.abs() - initial_separation.x.abs(),
        MIN_LOCAL_WINDOW_DIMENSION,
    );
    let height = finite_dimension(
        geometry.height + current_separation.y.abs() - initial_separation.y.abs(),
        MIN_LOCAL_WINDOW_DIMENSION,
    );
    let center_x = geometry.x + geometry.width * 0.5 + center_delta.x;
    let center_y = geometry.y + geometry.height * 0.5 + center_delta.y;
    WindowGeometry {
        x: center_x - width * 0.5,
        y: center_y - height * 0.5,
        width,
        height,
    }
}

fn center_of_two(points: [Point<f64, Logical>; 2]) -> Point<f64, Logical> {
    Point::from((
        (points[0].x + points[1].x) * 0.5,
        (points[0].y + points[1].y) * 0.5,
    ))
}

fn point_distance(first: Point<f64, Logical>, second: Point<f64, Logical>) -> f64 {
    (second.x - first.x).hypot(second.y - first.y)
}

fn inward_crush(initial: [f64; 4], current: [f64; 4], translation: f64) -> bool {
    let mut total_inward_travel = 0.0;
    for (initial_distance, current_distance) in initial.into_iter().zip(current) {
        let inward_travel = initial_distance - current_distance;
        if inward_travel < FOUR_FINGER_INWARD_SLOP {
            return false;
        }
        total_inward_travel += inward_travel;
    }
    let inward = total_inward_travel / 4.0;
    inward >= FOUR_FINGER_CRUSH_DISTANCE && inward >= translation * PINCH_TRANSLATION_DOMINANCE
}

pub(super) fn apply_actions(
    state: &mut RuntimeState,
    actions: impl IntoIterator<Item = TouchWindowAction>,
) {
    for action in actions {
        match action {
            TouchWindowAction::Placement {
                window_id,
                phase,
                change,
                geometry,
            } => apply_placement(state, window_id, phase, change, geometry),
            TouchWindowAction::Minimize { window_id } => {
                window_management::minimize_toplevel_by_id(state, window_id);
            }
            TouchWindowAction::Close { window_id } => {
                window_management::close_toplevel_by_id(state, window_id);
            }
            TouchWindowAction::Swipe { event, origin } => {
                super::input::dispatch_swipe_gesture(state, event, Some(origin));
            }
        }
    }
}

fn apply_placement(
    state: &mut RuntimeState,
    window_id: u64,
    phase: WindowPlacementPhase,
    change: WindowPlacementChange,
    geometry: WindowGeometry,
) {
    let local = state
        .wayland
        .as_ref()
        .is_some_and(|frontend| frontend.is_local_flutter_window(window_id));
    if local {
        if phase == WindowPlacementPhase::Begin {
            window_management::activate_local_flutter_window(state, window_id);
        }
        let geometry = constrain_local_geometry(geometry, change);
        state
            .frontend_mut()
            .set_local_flutter_window_global_geometry(window_id, geometry);
        window_management::queue_local_flutter_window_placement(state, window_id, phase, change);
        if phase == WindowPlacementPhase::End {
            state.scene_sync.mark_dirty();
        }
        return;
    }

    let Some(window) = state
        .wayland
        .as_ref()
        .and_then(|frontend| frontend.window_for_id(window_id))
    else {
        return;
    };
    let layout_managed = state
        .wayland
        .as_ref()
        .is_some_and(|frontend| frontend.window_is_layout_managed(&window));
    if layout_managed {
        match change {
            WindowPlacementChange::Move => apply_layout_move_placement(state, &window, phase),
            WindowPlacementChange::Resize => {
                apply_layout_resize_placement(state, &window, phase, geometry)
            }
            WindowPlacementChange::LayoutPreview => {
                unreachable!("touch gestures do not emit layout previews")
            }
        }
        return;
    }
    if phase == WindowPlacementPhase::Begin {
        // Use the same restore/state handshake as SUPER+LMB/RMB. Otherwise a
        // maximized or mobile target can survive until the next client commit.
        super::input::release_client_geometry_for_shell_grab(state, &window);
        window_management::activate_window(state, &window, SERIAL_COUNTER.next_serial());
        let frontend = state.frontend_mut();
        let restored = frontend.window_geometry_target(&window);
        frontend.touch_gestures.placement_transform = Some((
            window_id,
            PlacementTransform {
                source: geometry,
                restored: WindowGeometry {
                    x: f64::from(restored.loc.x),
                    y: f64::from(restored.loc.y),
                    width: f64::from(restored.size.w),
                    height: f64::from(restored.size.h),
                },
            },
        ));
    }
    let frontend = state.frontend_mut();
    let geometry = frontend
        .touch_gestures
        .placement_transform
        .filter(|(id, _)| *id == window_id)
        .map_or(geometry, |(_, transform)| transform.apply(geometry, change));
    if phase == WindowPlacementPhase::End {
        frontend.touch_gestures.placement_transform = None;
    }
    let geometry = constrain_client_geometry(&window, geometry, change);
    if change == WindowPlacementChange::Resize {
        state.frontend().prepare_window_interactive_resize(
            &window,
            geometry.size,
            phase == WindowPlacementPhase::End,
        );
    }
    state
        .frontend_mut()
        .set_window_geometry_target(&window, geometry);
    window_management::queue_window_placement(state, &window, geometry, phase, change);
    if phase == WindowPlacementPhase::End {
        state.scene_sync.mark_dirty();
    }
}

fn apply_layout_move_placement(
    state: &mut RuntimeState,
    window: &Window,
    phase: WindowPlacementPhase,
) {
    let position = {
        let frontend = state.frontend();
        match frontend.touch_gestures.gesture {
            Some(Gesture::Move { slot, origin, .. }) => {
                if phase == WindowPlacementPhase::Begin {
                    Some(origin)
                } else {
                    frontend
                        .touch_gestures
                        .contacts
                        .get(&slot)
                        .map(|contact| contact.position)
                }
            }
            _ => None,
        }
    };
    if phase == WindowPlacementPhase::Begin {
        let Some(position) = position else {
            return;
        };
        super::input::release_client_geometry_for_shell_grab(state, window);
        window_management::activate_window(state, window, SERIAL_COUNTER.next_serial());
        let frontend = state.frontend_mut();
        let geometry = frontend.window_geometry_target(window);
        frontend.touch_gestures.layout_move = Some(TileMoveGrab::new(
            smithay::input::pointer::GrabStartData {
                focus: None,
                button: 0,
                location: position,
            },
            window.clone(),
            geometry,
        ));
        window_management::queue_transient_window_placement(
            state,
            window,
            geometry,
            phase,
            WindowPlacementChange::Move,
        );
        return;
    }
    let Some(mut grab) = state.frontend_mut().touch_gestures.layout_move.take() else {
        return;
    };
    if phase == WindowPlacementPhase::End
        || position.is_some_and(|position| !grab.update(state, position))
    {
        grab.finish(state);
    } else {
        state.frontend_mut().touch_gestures.layout_move = Some(grab);
    }
}

fn apply_layout_resize_placement(
    state: &mut RuntimeState,
    window: &Window,
    phase: WindowPlacementPhase,
    geometry: WindowGeometry,
) {
    match phase {
        WindowPlacementPhase::Begin => {
            super::input::release_client_geometry_for_shell_grab(state, window);
            window_management::activate_window(state, window, SERIAL_COUNTER.next_serial());
            let geometry = state.frontend().window_geometry_target(window);
            window_management::queue_transient_window_placement(
                state,
                window,
                geometry,
                WindowPlacementPhase::Begin,
                WindowPlacementChange::Resize,
            );
        }
        WindowPlacementPhase::Update => {
            // Layouts deliberately override client size hints, just like the
            // pointer-driven tile resize path. The pinch size supplies a
            // preferred boundary delta; the layout remains the final size
            // authority and ignores translation of the gesture center.
            let target = layout_pinch_target_size(geometry);
            let affected = resize_layout_window_toward(state, window, target);
            let placements = {
                let frontend = state.frontend();
                affected
                    .into_iter()
                    .map(|window| {
                        let geometry = frontend.window_geometry_target(&window);
                        (window, geometry)
                    })
                    .collect::<Vec<_>>()
            };
            for (affected_window, geometry) in placements {
                window_management::queue_transient_window_placement(
                    state,
                    &affected_window,
                    geometry,
                    WindowPlacementPhase::Update,
                    WindowPlacementChange::Resize,
                );
            }
        }
        WindowPlacementPhase::End => {
            let placements = state.frontend().layout_window_geometries(window);
            for (affected_window, geometry) in placements {
                window_management::queue_transient_window_placement(
                    state,
                    &affected_window,
                    geometry,
                    WindowPlacementPhase::End,
                    WindowPlacementChange::Resize,
                );
            }
        }
    }
    state.scene_sync.mark_dirty();
}

fn resize_layout_window_toward(
    state: &mut RuntimeState,
    window: &Window,
    target: Size<i32, Logical>,
) -> Vec<Window> {
    let mut affected = Vec::new();
    for edge in [
        LayoutPinchEdge::Right,
        LayoutPinchEdge::Left,
        LayoutPinchEdge::Bottom,
        LayoutPinchEdge::Top,
    ] {
        let changed = {
            let frontend = state.frontend_mut();
            let current = frontend.window_geometry_target(window);
            let (delta_x, delta_y) = layout_pinch_delta(edge, current.size, target);
            if delta_x == 0.0 && delta_y == 0.0 {
                Vec::new()
            } else {
                frontend.resize_layout_window(window, edge.layout_edges(), delta_x, delta_y)
            }
        };
        for (changed_window, _) in changed {
            if !affected
                .iter()
                .any(|candidate| candidate == &changed_window)
            {
                affected.push(changed_window);
            }
        }
    }
    affected
}

fn layout_pinch_target_size(geometry: WindowGeometry) -> Size<i32, Logical> {
    let geometry = constrain_local_geometry(geometry, WindowPlacementChange::Resize);
    Size::from((
        rounded_i32(geometry.width).max(1),
        rounded_i32(geometry.height).max(1),
    ))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum LayoutPinchEdge {
    Left,
    Right,
    Top,
    Bottom,
}

impl LayoutPinchEdge {
    const fn layout_edges(self) -> LayoutResizeEdges {
        match self {
            Self::Left => LayoutResizeEdges {
                top: false,
                bottom: false,
                left: true,
                right: false,
            },
            Self::Right => LayoutResizeEdges {
                top: false,
                bottom: false,
                left: false,
                right: true,
            },
            Self::Top => LayoutResizeEdges {
                top: true,
                bottom: false,
                left: false,
                right: false,
            },
            Self::Bottom => LayoutResizeEdges {
                top: false,
                bottom: true,
                left: false,
                right: false,
            },
        }
    }
}

fn layout_pinch_delta(
    edge: LayoutPinchEdge,
    current: Size<i32, Logical>,
    target: Size<i32, Logical>,
) -> (f64, f64) {
    match edge {
        LayoutPinchEdge::Left => (f64::from(current.w) - f64::from(target.w), 0.0),
        LayoutPinchEdge::Right => (f64::from(target.w) - f64::from(current.w), 0.0),
        LayoutPinchEdge::Top => (0.0, f64::from(current.h) - f64::from(target.h)),
        LayoutPinchEdge::Bottom => (0.0, f64::from(target.h) - f64::from(current.h)),
    }
}

fn constrain_local_geometry(
    geometry: WindowGeometry,
    change: WindowPlacementChange,
) -> WindowGeometry {
    let width = finite_dimension(geometry.width, MIN_LOCAL_WINDOW_DIMENSION);
    let height = finite_dimension(geometry.height, MIN_LOCAL_WINDOW_DIMENSION);
    if change == WindowPlacementChange::Resize {
        centered_geometry(geometry, width, height)
    } else {
        WindowGeometry {
            width,
            height,
            ..geometry
        }
    }
}

fn constrain_client_geometry(
    window: &Window,
    geometry: WindowGeometry,
    change: WindowPlacementChange,
) -> Rectangle<i32, Logical> {
    let (minimum, maximum): (Size<i32, Logical>, Size<i32, Logical>) = ManagedWindow::new(window)
        .map_or_else(
            || (Size::from((1, 1)), Size::from((0, 0))),
            |managed| {
                let facts = managed.facts();
                (
                    Size::from((facts.minimum_size.w.max(1), facts.minimum_size.h.max(1))),
                    facts.maximum_size,
                )
            },
        );
    client_geometry_with_constraints(geometry, change, minimum, maximum)
}

fn client_geometry_with_constraints(
    geometry: WindowGeometry,
    change: WindowPlacementChange,
    minimum: Size<i32, Logical>,
    maximum: Size<i32, Logical>,
) -> Rectangle<i32, Logical> {
    let requested = Size::<i32, Logical>::from((
        rounded_i32(geometry.width).max(1),
        rounded_i32(geometry.height).max(1),
    ));
    // A corner drag only translates the existing window. Client size hints
    // may disagree with that size (for example after a maximize/restore), but
    // must not turn movement into a resize when the final placement settles.
    let size = if change == WindowPlacementChange::Resize {
        Size::from((
            constrain_dimension(requested.w, minimum.w, maximum.w),
            constrain_dimension(requested.h, minimum.h, maximum.h),
        ))
    } else {
        requested
    };
    let location = if change == WindowPlacementChange::Resize {
        Point::from((
            rounded_i32(geometry.x + (geometry.width - f64::from(size.w)) * 0.5),
            rounded_i32(geometry.y + (geometry.height - f64::from(size.h)) * 0.5),
        ))
    } else {
        Point::from((rounded_i32(geometry.x), rounded_i32(geometry.y)))
    };
    Rectangle::new(location, size)
}

fn centered_geometry(geometry: WindowGeometry, width: f64, height: f64) -> WindowGeometry {
    WindowGeometry {
        x: geometry.x + (geometry.width - width) * 0.5,
        y: geometry.y + (geometry.height - height) * 0.5,
        width,
        height,
    }
}

fn finite_dimension(value: f64, minimum: f64) -> f64 {
    if value.is_finite() {
        value.round().clamp(minimum, MAX_WINDOW_DIMENSION)
    } else {
        minimum
    }
}

fn rounded_i32(value: f64) -> i32 {
    if value.is_nan() {
        0
    } else {
        value
            .round()
            .clamp(f64::from(i32::MIN), f64::from(i32::MAX)) as i32
    }
}

#[cfg(test)]
#[path = "touch_gestures/tests.rs"]
mod tests;
