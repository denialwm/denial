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
use super::super::window_grab::constrain_dimension;
use super::super::wire::{WindowGeometry, WindowPlacementChange, WindowPlacementPhase};
use super::window_management;

/// The invisible gesture affordance at the top of a normal window.
pub(super) const WINDOW_TOUCH_STRIP_HEIGHT: f64 = 48.0;

const MOVE_SLOP: f64 = 4.0;
const MINIMIZE_SWIPE_DISTANCE: f64 = 96.0;
const MIN_LOCAL_WINDOW_DIMENSION: f64 = 64.0;
const MAX_WINDOW_DIMENSION: f64 = 16_384.0;

#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) struct TouchWindowTarget {
    pub window_id: u64,
    pub geometry: WindowGeometry,
    pub in_top_strip: bool,
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
    Pinch {
        slots: [i32; 2],
        window_id: u64,
        initial_distance: f64,
        initial_geometry: WindowGeometry,
        last_geometry: WindowGeometry,
    },
    MinimizeSwipe {
        slots: [i32; 2],
        window_id: u64,
        origin: Point<f64, Logical>,
    },
    /// Keep every participant compositor-owned until all fingers are lifted.
    Blocked { window_id: u64, close_emitted: bool },
}

impl Gesture {
    fn window_id(self) -> u64 {
        match self {
            Self::Move { window_id, .. }
            | Self::Pinch { window_id, .. }
            | Self::MinimizeSwipe { window_id, .. }
            | Self::Blocked { window_id, .. } => window_id,
        }
    }

    fn includes(self, slot: i32) -> bool {
        match self {
            Self::Move {
                slot: gesture_slot, ..
            } => gesture_slot == slot,
            Self::Pinch { slots, .. } | Self::MinimizeSwipe { slots, .. } => slots.contains(&slot),
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
                position,
                target,
                captured: false,
            },
        );
        let Some(target) = target else {
            return TouchGestureUpdate::default();
        };

        if matches!(
            self.gesture,
            Some(Gesture::Blocked {
                window_id,
                close_emitted: true,
            }) if window_id == target.window_id
        ) {
            return TouchGestureUpdate {
                consume: true,
                captured_slots: self.capture_slots(&[slot]),
                actions: Vec::new(),
            };
        }

        let same_window = self.window_slots(target.window_id);
        if same_window.len() >= 3 {
            let mut update = TouchGestureUpdate {
                consume: true,
                captured_slots: self.capture_slots(&same_window),
                actions: Vec::with_capacity(2),
            };
            if let Some(gesture) = self.gesture.take()
                && let Some(action) = gesture.finish_action()
            {
                update.actions.push(action);
            }
            update.actions.push(TouchWindowAction::Close {
                window_id: target.window_id,
            });
            self.gesture = Some(Gesture::Blocked {
                window_id: target.window_id,
                close_emitted: true,
            });
            return update;
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
            return self.begin_pinch([uncaptured[0], uncaptured[1]], target.geometry);
        }

        if target.in_top_strip {
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
        if !contact.captured {
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
                initial_distance,
                initial_geometry,
                last_geometry,
            } if slots.contains(&slot) => {
                if let Some(distance) = self.contact_distance(*slots) {
                    let scale = (distance / *initial_distance).clamp(0.05, 20.0);
                    *last_geometry = scaled_about_center(*initial_geometry, scale);
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
                            close_emitted: false,
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
        let Some(contact) = self.contacts.remove(&slot) else {
            return TouchGestureUpdate::default();
        };
        if !contact.captured {
            return TouchGestureUpdate::default();
        }

        let mut update = TouchGestureUpdate {
            consume: true,
            ..TouchGestureUpdate::default()
        };
        let Some(gesture) = self.gesture.take() else {
            return update;
        };
        if !gesture.includes(slot) {
            self.gesture = Some(gesture);
            return update;
        }
        if let Some(action) = gesture.finish_action() {
            update.actions.push(action);
        }
        if matches!(
            gesture,
            Gesture::Pinch { .. } | Gesture::MinimizeSwipe { .. }
        ) || matches!(gesture, Gesture::Blocked { .. })
            && self.has_captured_window_contact(gesture.window_id())
        {
            self.gesture = Some(match gesture {
                Gesture::Blocked { .. } => gesture,
                _ => Gesture::Blocked {
                    window_id: gesture.window_id(),
                    close_emitted: false,
                },
            });
        }
        update
    }

    pub(super) fn cancel(&mut self, slot: i32) -> TouchGestureUpdate {
        self.up(slot)
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
        let both_in_top_strip = slots.iter().all(|slot| {
            self.contacts
                .get(slot)
                .and_then(|contact| contact.target)
                .is_some_and(|contact_target| contact_target.in_top_strip)
        });
        if !both_in_top_strip && target.geometry_locked {
            return TouchGestureUpdate::default();
        }
        let captured_slots = self.capture_slots(&slots);
        let mut actions = move_gesture.finish_action().into_iter().collect::<Vec<_>>();
        if both_in_top_strip {
            let origin = self
                .contact_center(slots)
                .expect("two contacts disappeared");
            self.gesture = Some(Gesture::MinimizeSwipe {
                slots,
                window_id: target.window_id,
                origin,
            });
        } else {
            let initial_geometry = match move_gesture {
                Gesture::Move { last_geometry, .. } => last_geometry,
                _ => unreachable!(),
            };
            let mut pinch = self.begin_pinch(slots, initial_geometry);
            actions.append(&mut pinch.actions);
        }
        TouchGestureUpdate {
            consume: true,
            captured_slots,
            actions,
        }
    }

    fn begin_pinch(
        &mut self,
        mut slots: [i32; 2],
        initial_geometry: WindowGeometry,
    ) -> TouchGestureUpdate {
        slots.sort_unstable();
        let Some(initial_distance) = self
            .contact_distance(slots)
            .filter(|distance| *distance > 0.0)
        else {
            return TouchGestureUpdate::default();
        };
        let window_id = self.contacts[&slots[0]]
            .target
            .expect("pinch contact lost its window")
            .window_id;
        let captured_slots = self.capture_slots(&slots);
        self.gesture = Some(Gesture::Pinch {
            slots,
            window_id,
            initial_distance,
            initial_geometry,
            last_geometry: initial_geometry,
        });
        TouchGestureUpdate {
            consume: true,
            captured_slots,
            actions: vec![TouchWindowAction::Placement {
                window_id,
                phase: WindowPlacementPhase::Begin,
                change: WindowPlacementChange::Resize,
                geometry: initial_geometry,
            }],
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
        let first = self.contacts.get(&slots[0])?.position;
        let second = self.contacts.get(&slots[1])?.position;
        Some(Point::from((
            (first.x + second.x) * 0.5,
            (first.y + second.y) * 0.5,
        )))
    }

    fn contact_distance(&self, slots: [i32; 2]) -> Option<f64> {
        let first = self.contacts.get(&slots[0])?.position;
        let second = self.contacts.get(&slots[1])?.position;
        Some((second.x - first.x).hypot(second.y - first.y))
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

fn scaled_about_center(geometry: WindowGeometry, scale: f64) -> WindowGeometry {
    let width = geometry.width * scale;
    let height = geometry.height * scale;
    WindowGeometry {
        x: geometry.x + (geometry.width - width) * 0.5,
        y: geometry.y + (geometry.height - height) * 0.5,
        width,
        height,
    }
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

    fn target(in_top_strip: bool) -> TouchWindowTarget {
        TouchWindowTarget {
            window_id: 7,
            geometry: geometry(),
            in_top_strip,
            geometry_locked: false,
        }
    }

    fn point(x: f64, y: f64) -> Point<f64, Logical> {
        Point::from((x, y))
    }

    #[test]
    fn one_finger_top_strip_drag_emits_normal_move_phases() {
        let mut gestures = TouchGestureState::default();
        let down = gestures.down(0, point(180.0, 90.0), Some(target(true)));
        assert!(down.consume);
        assert_eq!(down.captured_slots, [0]);
        assert!(down.actions.is_empty());

        let motion = gestures.motion(0, point(230.0, 130.0));
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
    fn two_body_contacts_capture_the_existing_route_and_pinch_from_the_center() {
        let mut gestures = TouchGestureState::default();
        assert!(
            !gestures
                .down(0, point(150.0, 180.0), Some(target(false)))
                .consume
        );
        let second = gestures.down(1, point(250.0, 180.0), Some(target(false)));
        assert!(second.consume);
        assert_eq!(second.captured_slots, [0, 1]);
        assert!(matches!(
            second.actions.as_slice(),
            [TouchWindowAction::Placement {
                phase: WindowPlacementPhase::Begin,
                change: WindowPlacementChange::Resize,
                ..
            }]
        ));

        let motion = gestures.motion(1, point(350.0, 180.0));
        assert_eq!(
            motion.actions,
            [TouchWindowAction::Placement {
                window_id: 7,
                phase: WindowPlacementPhase::Update,
                change: WindowPlacementChange::Resize,
                geometry: WindowGeometry {
                    x: -100.0,
                    y: -70.0,
                    width: 800.0,
                    height: 600.0,
                },
            }]
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
    fn two_top_strip_contacts_minimize_only_after_a_downward_swipe() {
        let mut gestures = TouchGestureState::default();
        gestures.down(0, point(160.0, 90.0), Some(target(true)));
        gestures.down(1, point(240.0, 90.0), Some(target(true)));

        assert!(gestures.motion(0, point(160.0, 170.0)).actions.is_empty());
        assert_eq!(
            gestures.motion(1, point(240.0, 210.0)).actions,
            [TouchWindowAction::Minimize { window_id: 7 }]
        );
        assert!(gestures.motion(0, point(160.0, 260.0)).actions.is_empty());
    }

    #[test]
    fn third_contact_closes_the_touched_window_once() {
        let mut gestures = TouchGestureState::default();
        gestures.down(0, point(150.0, 180.0), Some(target(false)));
        gestures.down(1, point(250.0, 180.0), Some(target(false)));
        let third = gestures.down(2, point(200.0, 250.0), Some(target(false)));
        assert!(third.consume);
        assert!(matches!(
            third.actions.as_slice(),
            [
                TouchWindowAction::Placement {
                    phase: WindowPlacementPhase::End,
                    change: WindowPlacementChange::Resize,
                    ..
                },
                TouchWindowAction::Close { window_id: 7 }
            ]
        ));
        assert!(gestures.up(2).consume);
        let fourth = gestures.down(3, point(210.0, 240.0), Some(target(false)));
        assert!(fourth.consume);
        assert!(fourth.actions.is_empty());
        assert!(gestures.up(3).consume);
        assert!(gestures.up(1).consume);
        assert!(gestures.up(0).consume);
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
        assert!(same_other_window.consume);
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
        gestures.down(0, point(160.0, 90.0), Some(locked));
        assert!(gestures.motion(0, point(220.0, 140.0)).actions.is_empty());
        gestures.down(1, point(240.0, 90.0), Some(locked));
        gestures.motion(0, point(160.0, 270.0));
        assert_eq!(
            gestures.motion(1, point(240.0, 270.0)).actions,
            [TouchWindowAction::Minimize { window_id: 7 }]
        );
    }
}
