//! Compositor-owned direct-touch window gestures.
//!
//! Recognition lives here so the ordinary pointer, Wayland-touch and Flutter
//! routes remain unaware of window gesture policy. The input entry point only
//! supplies hit-tested contacts, retires routes when this recognizer wins, and
//! applies the resulting ordinary Denial window actions.

use std::collections::HashMap;

use smithay::desktop::Window;
use smithay::reexports::wayland_protocols::xdg::shell::server::xdg_toplevel;
use smithay::reexports::wayland_server::Resource;
use smithay::utils::{Logical, Point, Rectangle, SERIAL_COUNTER, Size};
use smithay::wayland::compositor::with_states;
use smithay::wayland::shell::xdg::SurfaceCachedState;

use super::super::RuntimeState;
use super::super::native_shortcut::ShortcutGesture;
use super::super::window_grab::constrain_dimension;
use super::super::wire::{WindowGeometry, WindowPlacementChange, WindowPlacementPhase};
use super::window_management;

/// The invisible gesture affordance at the bottom of a normal window.
pub(super) const WINDOW_TOUCH_STRIP_HEIGHT: f64 = 48.0;

const MOVE_SLOP: f64 = 4.0;
const MINIMIZE_SWIPE_DISTANCE: f64 = 96.0;
const PINCH_SLOP: f64 = 16.0;
const PINCH_TRANSLATION_DOMINANCE: f64 = 1.5;
const THREE_FINGER_TAP_SLOP: f64 = 12.0;
const THREE_FINGER_SWIPE_DISTANCE: f64 = 100.0;
const SWIPE_DIRECTION_DOMINANCE: f64 = 1.5;
const MIN_LOCAL_WINDOW_DIMENSION: f64 = 64.0;
const MAX_WINDOW_DIMENSION: f64 = 16_384.0;

#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) struct TouchWindowTarget {
    pub window_id: u64,
    pub geometry: WindowGeometry,
    pub in_gesture_strip: bool,
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
    Gesture(ShortcutGesture),
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
    target: Option<TouchWindowTarget>,
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
    ThreeFinger {
        slots: [i32; 3],
        window_id: u64,
        origin: Point<f64, Logical>,
        tap_to_close: bool,
    },
    /// Keep every participant compositor-owned until all fingers are lifted.
    Blocked { window_id: u64 },
}

impl Gesture {
    fn window_id(self) -> u64 {
        match self {
            Self::Move { window_id, .. }
            | Self::PinchCandidate { window_id, .. }
            | Self::Pinch { window_id, .. }
            | Self::MinimizeSwipe { window_id, .. }
            | Self::ThreeFinger { window_id, .. }
            | Self::Blocked { window_id, .. } => window_id,
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
            Self::ThreeFinger { slots, .. } => slots.contains(&slot),
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

#[derive(Debug, Default)]
pub(super) struct TouchGestureState {
    contacts: HashMap<i32, Contact>,
    gesture: Option<Gesture>,
}

impl TouchGestureState {
    pub(super) fn down(
        &mut self,
        slot: i32,
        position: Point<f64, Logical>,
        target: Option<TouchWindowTarget>,
    ) -> TouchGestureUpdate {
        self.contacts.insert(
            slot,
            Contact {
                origin: position,
                position,
                target,
                captured: false,
            },
        );
        let Some(target) = target else {
            return TouchGestureUpdate::default();
        };

        if matches!(self.gesture, Some(Gesture::Blocked { window_id }) if window_id == target.window_id)
        {
            return TouchGestureUpdate {
                consume: true,
                captured_slots: self.capture_slots(&[slot]),
                actions: Vec::new(),
            };
        }

        let same_window = self.window_slots(target.window_id);
        if same_window.len() >= 3
            && self
                .gesture
                .is_none_or(|gesture| gesture.window_id() == target.window_id)
        {
            if matches!(self.gesture, Some(Gesture::ThreeFinger { .. })) {
                return TouchGestureUpdate {
                    consume: true,
                    captured_slots: self.capture_slots(&[slot]),
                    actions: Vec::new(),
                };
            }
            return self.begin_three_finger(same_window, target.window_id);
        }

        if let Some(gesture) = self.gesture
            && gesture.window_id() == target.window_id
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
            if target.geometry_locked {
                return TouchGestureUpdate::default();
            }
            return self.begin_pinch_candidate([uncaptured[0], uncaptured[1]], target.geometry);
        }

        if target.in_gesture_strip {
            let captured_slots = self.capture_slots(&[slot]);
            self.gesture = Some(Gesture::Move {
                slot,
                window_id: target.window_id,
                origin: position,
                initial_geometry: target.geometry,
                last_geometry: target.geometry,
                started: false,
                geometry_locked: target.geometry_locked,
            });
            return TouchGestureUpdate {
                consume: true,
                captured_slots,
                actions: Vec::new(),
            };
        }

        TouchGestureUpdate::default()
    }

    pub(super) fn motion(
        &mut self,
        slot: i32,
        position: Point<f64, Logical>,
    ) -> TouchGestureUpdate {
        let Some(contact) = self.contacts.get_mut(&slot) else {
            return TouchGestureUpdate::default();
        };
        contact.position = position;
        let captured = contact.captured;

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
            return TouchGestureUpdate::default();
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
                            window_id: *window_id,
                        };
                    }
                }
            }
            Gesture::ThreeFinger {
                slots,
                window_id,
                origin,
                tap_to_close,
            } if slots.contains(&slot) => {
                if self.contact_travel(slot) > THREE_FINGER_TAP_SLOP {
                    *tap_to_close = false;
                }
                if let Some(center) = self.three_contact_center(*slots) {
                    let delta = center - *origin;
                    let upward = -delta.y;
                    if upward >= THREE_FINGER_SWIPE_DISTANCE
                        && upward >= delta.x.abs() * SWIPE_DIRECTION_DOMINANCE
                    {
                        update.actions.push(TouchWindowAction::Gesture(
                            ShortcutGesture::ThreeFingerSwipeUp,
                        ));
                        gesture = Gesture::Blocked {
                            window_id: *window_id,
                        };
                    }
                }
            }
            _ => {}
        }
        self.gesture = Some(gesture);
        update
    }

    pub(super) fn up(&mut self, slot: i32) -> TouchGestureUpdate {
        self.finish_contact(slot, true)
    }

    pub(super) fn cancel(&mut self, slot: i32) -> TouchGestureUpdate {
        self.finish_contact(slot, false)
    }

    fn finish_contact(&mut self, slot: i32, allow_tap: bool) -> TouchGestureUpdate {
        let Some(contact) = self.contacts.remove(&slot) else {
            return TouchGestureUpdate::default();
        };
        let mut update = TouchGestureUpdate {
            consume: contact.captured,
            ..TouchGestureUpdate::default()
        };
        let Some(gesture) = self.gesture.take() else {
            return update;
        };
        if !gesture.includes(slot) {
            self.gesture = Some(gesture);
            return update;
        }
        if matches!(gesture, Gesture::PinchCandidate { .. }) {
            return update;
        }

        match gesture {
            Gesture::ThreeFinger {
                window_id,
                tap_to_close: true,
                ..
            } if allow_tap => update.actions.push(TouchWindowAction::Close { window_id }),
            _ => {
                if let Some(action) = gesture.finish_action() {
                    update.actions.push(action);
                }
            }
        }
        if self.has_captured_window_contact(gesture.window_id())
            && matches!(
                gesture,
                Gesture::Pinch { .. }
                    | Gesture::MinimizeSwipe { .. }
                    | Gesture::ThreeFinger { .. }
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
        let actions = self
            .gesture
            .take()
            .and_then(Gesture::finish_action)
            .into_iter()
            .collect();
        self.contacts.clear();
        actions
    }

    fn promote_move_to_two_fingers(
        &mut self,
        move_gesture: Gesture,
        mut slots: Vec<i32>,
        target: TouchWindowTarget,
    ) -> TouchGestureUpdate {
        slots.sort_unstable();
        let slots = [slots[0], slots[1]];
        let both_in_gesture_strip = slots.iter().all(|slot| {
            self.contacts
                .get(slot)
                .and_then(|contact| contact.target)
                .is_some_and(|contact_target| contact_target.in_gesture_strip)
        });
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

    fn begin_three_finger(&mut self, mut slots: Vec<i32>, window_id: u64) -> TouchGestureUpdate {
        slots.sort_unstable();
        let slots = [slots[0], slots[1], slots[2]];
        let origin = self
            .three_contact_center(slots)
            .expect("three-finger contacts disappeared");
        let tap_to_close = slots.iter().all(|slot| {
            self.contacts.get(slot).is_some_and(|contact| {
                contact.target.is_some_and(|target| target.in_gesture_strip)
                    && self.contact_travel(*slot) <= THREE_FINGER_TAP_SLOP
            })
        });
        let actions = self
            .gesture
            .take()
            .and_then(Gesture::finish_action)
            .into_iter()
            .collect();
        let captured_slots = self.capture_slots(&slots);
        self.gesture = Some(Gesture::ThreeFinger {
            slots,
            window_id,
            origin,
            tap_to_close,
        });
        TouchGestureUpdate {
            consume: true,
            captured_slots,
            actions,
        }
    }

    fn window_slots(&self, window_id: u64) -> Vec<i32> {
        let mut slots = self
            .contacts
            .iter()
            .filter_map(|(slot, contact)| {
                contact
                    .target
                    .is_some_and(|target| target.window_id == window_id)
                    .then_some(*slot)
            })
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

    fn contact_center(&self, slots: [i32; 2]) -> Option<Point<f64, Logical>> {
        self.contact_positions(slots).map(center_of_two)
    }

    fn contact_positions(&self, slots: [i32; 2]) -> Option<[Point<f64, Logical>; 2]> {
        Some([
            self.contacts.get(&slots[0])?.position,
            self.contacts.get(&slots[1])?.position,
        ])
    }

    fn three_contact_center(&self, slots: [i32; 3]) -> Option<Point<f64, Logical>> {
        let first = self.contacts.get(&slots[0])?.position;
        let second = self.contacts.get(&slots[1])?.position;
        let third = self.contacts.get(&slots[2])?.position;
        Some(Point::from((
            (first.x + second.x + third.x) / 3.0,
            (first.y + second.y + third.y) / 3.0,
        )))
    }

    fn contact_travel(&self, slot: i32) -> f64 {
        self.contacts.get(&slot).map_or(0.0, |contact| {
            let delta = contact.position - contact.origin;
            delta.x.hypot(delta.y)
        })
    }

    fn has_captured_window_contact(&self, window_id: u64) -> bool {
        self.contacts.values().any(|contact| {
            contact.captured
                && contact
                    .target
                    .is_some_and(|target| target.window_id == window_id)
        })
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
    opposing_motion
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
            TouchWindowAction::Gesture(gesture) => {
                let disposition = state.native_escape_shortcut.observe_gesture(gesture);
                super::input::execute_shortcut_disposition(state, disposition);
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
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
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
    if phase == WindowPlacementPhase::Begin {
        let constraints_cleared = release_geometry_constraints(state, &window);
        window_management::activate_window(state, &window, SERIAL_COUNTER.next_serial());
        if constraints_cleared
            && change == WindowPlacementChange::Move
            && let Some(toplevel) = window.toplevel()
        {
            let size = Size::from((rounded_i32(geometry.width), rounded_i32(geometry.height)));
            toplevel.with_pending_state(|pending| pending.size = Some(size));
            toplevel.send_pending_configure();
        }
    }
    let geometry = constrain_client_geometry(&window, geometry, change);
    if change == WindowPlacementChange::Resize {
        configure_client_resize(&window, geometry.size, phase);
    }
    state
        .wayland
        .as_mut()
        .expect("missing Wayland frontend")
        .set_window_geometry_target(&window, geometry);
    window_management::queue_window_placement(state, &window, geometry, phase, change);
    if phase == WindowPlacementPhase::End {
        state.scene_sync.mark_dirty();
    }
}

fn release_geometry_constraints(state: &mut RuntimeState, window: &Window) -> bool {
    let client_cleared = window_management::clear_client_geometry_constraints(window);
    let root = state
        .wayland
        .as_ref()
        .and_then(|frontend| frontend.window_root_surface(window));
    let Some(root) = root else {
        return client_cleared;
    };
    let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
    let surface_id = root.id();
    let shell_maximized = frontend
        .shell_maximize_restore_geometries
        .remove(&surface_id)
        .is_some();
    let shell_fullscreen = frontend
        .shell_fullscreen_restore_geometries
        .remove(&surface_id)
        .is_some();
    let shell_locked = frontend.shell_fullscreen_locks.remove(&surface_id);
    frontend.restore_window_geometries.remove(&surface_id);
    client_cleared || shell_maximized || shell_fullscreen || shell_locked
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
    let requested =
        Size::<i32, Logical>::from((rounded_i32(geometry.width), rounded_i32(geometry.height)));
    let (minimum, maximum) = if let Some(toplevel) = window.toplevel() {
        with_states(toplevel.wl_surface(), |states| {
            let mut cached = states.cached_state.get::<SurfaceCachedState>();
            let current = cached.current();
            (current.min_size, current.max_size)
        })
    } else if let Some(x11) = window.x11_surface() {
        (
            x11.min_size().unwrap_or_else(|| Size::from((1, 1))),
            x11.max_size().unwrap_or_else(|| Size::from((0, 0))),
        )
    } else {
        (Size::from((1, 1)), Size::from((0, 0)))
    };
    let size = Size::from((
        constrain_dimension(requested.w, minimum.w, maximum.w),
        constrain_dimension(requested.h, minimum.h, maximum.h),
    ));
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

fn configure_client_resize(window: &Window, size: Size<i32, Logical>, phase: WindowPlacementPhase) {
    let Some(toplevel) = window.toplevel() else {
        return;
    };
    toplevel.with_pending_state(|pending| {
        if phase == WindowPlacementPhase::End {
            pending.states.unset(xdg_toplevel::State::Resizing);
        } else {
            pending.states.set(xdg_toplevel::State::Resizing);
        }
        pending.size = Some(size);
    });
    toplevel.send_pending_configure();
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
mod tests {
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
            geometry_locked: false,
        }
    }

    fn point(x: f64, y: f64) -> Point<f64, Logical> {
        Point::from((x, y))
    }

    #[test]
    fn one_finger_bottom_strip_drag_emits_normal_move_phases() {
        let mut gestures = TouchGestureState::default();
        let down = gestures.down(0, point(180.0, 350.0), Some(target(true)));
        assert!(down.consume);
        assert_eq!(down.captured_slots, [0]);
        assert!(down.actions.is_empty());

        let motion = gestures.motion(0, point(230.0, 390.0));
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
        gestures.down(0, point(160.0, 350.0), Some(target(true)));
        gestures.down(1, point(240.0, 350.0), Some(target(true)));

        assert!(gestures.motion(0, point(160.0, 430.0)).actions.is_empty());
        assert_eq!(
            gestures.motion(1, point(240.0, 470.0)).actions,
            [TouchWindowAction::Minimize { window_id: 7 }]
        );
        assert!(gestures.motion(0, point(160.0, 520.0)).actions.is_empty());
    }

    #[test]
    fn three_finger_bottom_strip_tap_closes_on_release_once() {
        let mut gestures = TouchGestureState::default();
        gestures.down(0, point(150.0, 350.0), Some(target(true)));
        gestures.down(1, point(250.0, 350.0), Some(target(true)));
        let third = gestures.down(2, point(200.0, 360.0), Some(target(true)));
        assert!(third.consume);
        assert!(third.actions.is_empty());
        let release = gestures.up(2);
        assert!(release.consume);
        assert_eq!(release.actions, [TouchWindowAction::Close { window_id: 7 }]);

        let fourth = gestures.down(3, point(210.0, 360.0), Some(target(true)));
        assert!(fourth.consume);
        assert!(fourth.actions.is_empty());
        assert!(gestures.up(3).consume);
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
    fn canceled_three_finger_contact_never_closes() {
        let mut gestures = TouchGestureState::default();
        gestures.down(0, point(150.0, 350.0), Some(target(true)));
        gestures.down(1, point(250.0, 350.0), Some(target(true)));
        gestures.down(2, point(200.0, 360.0), Some(target(true)));

        assert!(gestures.cancel(2).actions.is_empty());
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
        close_gestures.down(0, point(160.0, 350.0), Some(locked));
        close_gestures.down(1, point(240.0, 350.0), Some(locked));
        close_gestures.down(2, point(200.0, 360.0), Some(locked));
        assert_eq!(
            close_gestures.up(2).actions,
            [TouchWindowAction::Close { window_id: 7 }]
        );
    }
}
