//! Flutter-owned touch, pointer, gesture, and axis dispatch.

use super::super::focus::request_keyboard_focus;
use super::*;

#[cfg(feature = "flutter")]
pub(super) fn apply_touch_gesture_update(
    state: &mut RuntimeState,
    update: TouchGestureUpdate,
) -> bool {
    let actions_pending = !update.actions.is_empty();
    let canceled_client_route = cancel_captured_touch_routes(state, &update.captured_slots);
    touch_gestures::apply_actions(state, update.actions);
    canceled_client_route || actions_pending
}

#[cfg(feature = "flutter")]
pub(super) fn cancel_captured_touch_routes(state: &mut RuntimeState, slots: &[i32]) -> bool {
    if slots.is_empty() {
        return false;
    }
    let (flutter_slots, cancel_client, touch) = {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        let flutter_slots = slots
            .iter()
            .copied()
            .filter(|slot| frontend.flutter_touch_slots.remove(slot))
            .collect::<Vec<_>>();
        let cancel_client = slots
            .iter()
            .any(|slot| frontend.client_touch_routes.contains_key(slot));
        if cancel_client {
            frontend.client_touch_routes.clear();
            frontend.client_touch_frame_pending = false;
        }
        let touch = cancel_client.then(|| frontend.seat.get_touch().expect("seat has no touch"));
        (flutter_slots, cancel_client, touch)
    };
    state.flutter_input.cancel_touch_slots(&flutter_slots);
    if let Some(touch) = touch {
        touch.cancel(state);
        if touch.is_grabbed() {
            touch.unset_grab(state);
        }
    }
    cancel_client
}

#[cfg(feature = "flutter")]
pub(super) fn process_flutter_input_event(
    state: &mut RuntimeState,
    event: InputEvent<LibinputInputBackend>,
) -> bool {
    debug_assert!(!matches!(&event, InputEvent::Keyboard { .. }));
    let secure_locked = state.secure_session_locked();
    match &event {
        InputEvent::PointerMotion { event: motion, .. } => {
            let flutter_captured = state.flutter_input.pointer_captured();
            let delta = motion.delta();
            let delta_unaccel = motion.delta_unaccel();
            let (position, target, relative) = {
                let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                frontend.set_pointer_cursor_visible(true);
                let scale = frontend.atlas_scale.max(f64::EPSILON);
                let delta = Point::from((delta.x / scale, delta.y / scale));
                let position = frontend.clamp_pointer(frontend.pointer_location + delta);
                let target =
                    if secure_locked || (flutter_captured && !frontend.clipboard_drag_active) {
                        PointerMotionTarget::FLUTTER
                    } else if let Some(route) = frontend.client_pointer_capture.as_ref() {
                        PointerMotionTarget::client(route, position)
                    } else {
                        frontend.pointer_motion_target(position)
                    };
                let relative = RelativeMotionEvent {
                    delta,
                    delta_unaccel: Point::from((delta_unaccel.x / scale, delta_unaccel.y / scale)),
                    utime: motion.time_usec(),
                };
                (position, target, relative)
            };
            route_pointer_motion(state, position, target, motion.time_msec(), Some(relative))
        }
        InputEvent::PointerMotionAbsolute { event: motion, .. } => {
            let flutter_captured = state.flutter_input.pointer_captured();
            let (position, target) = {
                let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                frontend.set_pointer_cursor_visible(true);
                let local = motion.position_transformed(frontend.desktop_bounds.size);
                let position = frontend.clamp_pointer(local + frontend.desktop_bounds.loc.to_f64());
                let target =
                    if secure_locked || (flutter_captured && !frontend.clipboard_drag_active) {
                        PointerMotionTarget::FLUTTER
                    } else if let Some(route) = frontend.client_pointer_capture.as_ref() {
                        PointerMotionTarget::client(route, position)
                    } else {
                        frontend.pointer_motion_target(position)
                    };
                (position, target)
            };
            route_pointer_motion(state, position, target, motion.time_msec(), None)
        }
        InputEvent::PointerButton { event: button, .. } => {
            let serial = SERIAL_COUNTER.next_serial();
            let button_code = button.button_code();
            state
                .wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .set_pointer_cursor_visible(true);
            state
                .native_escape_shortcut
                .note_pointer_button(button.state() == ButtonState::Pressed);
            if retired_pointer_button_consumes_transition(
                &mut state
                    .wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .retired_pointer_buttons,
                button_code,
                button.state(),
            ) {
                return true;
            }
            let pointer = state
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .seat
                .get_pointer()
                .expect("seat has no pointer");
            let pointer_grabbed = pointer.is_grabbed();
            let flutter_captured = state.flutter_input.pointer_captured();
            let clipboard_drag_active = state
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .clipboard_drag_active;
            let (target, local_window_region) = {
                let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                let target =
                    if secure_locked || (flutter_captured && !frontend.clipboard_drag_active) {
                        InputTarget::Flutter
                    } else if let Some(route) = frontend.client_pointer_capture.clone() {
                        InputTarget::Client(route)
                    } else {
                        let position = frontend.pointer_location;
                        frontend.input_target(position)
                    };
                let local_window_region = if !secure_locked
                    && !flutter_captured
                    && matches!(&target, InputTarget::Flutter)
                {
                    frontend.local_flutter_window_region_at(frontend.pointer_location)
                } else {
                    None
                };
                (target, local_window_region)
            };
            if button.state() == ButtonState::Released {
                state
                    .wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .forget_client_pointer_button(button_code);
            }
            // SUPER is compositor-owned and deliberately never enters the
            // client-facing seat state. Use the native physical-key tracker
            // for compositor pointer chords instead of Smithay's modifiers.
            let logo = state.native_escape_shortcut.super_pressed();
            let super_action = super_pointer_action(logo, button_code);
            let began_super_grab = if !pointer_grabbed
                && button.state() == ButtonState::Pressed
                && let Some(action) = super_action
            {
                match (&target, local_window_region) {
                    (InputTarget::Client(route), _) => {
                        begin_super_pointer_grab(state, route, action, button_code, serial)
                    }
                    (InputTarget::Flutter, Some(region)) => {
                        begin_local_super_pointer_grab(state, region, action, button_code, serial)
                    }
                    _ => false,
                }
            } else {
                false
            };
            if began_super_grab {
                update_pressed_buttons(
                    &mut state
                        .wayland
                        .as_mut()
                        .expect("missing Wayland frontend")
                        .wayland_pointer_buttons,
                    button_code,
                    ButtonState::Pressed,
                );
                pointer.button(
                    state,
                    &ButtonEvent {
                        button: button_code,
                        state: ButtonState::Pressed,
                        serial,
                        time: button.time_msec(),
                    },
                );
                pointer.frame(state);
                state.scene_sync.mark_dirty();
                return true;
            }
            if !logo
                && button.state() == ButtonState::Pressed
                && let InputTarget::Client(route) = &target
                && state
                    .wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .resume_pointer_constraint_for_route(route)
            {
                state.scene_sync.mark_dirty();
            }
            let mut scene_changed = false;
            if button.state() == ButtonState::Pressed
                && matches!(&target, InputTarget::Client(_))
                && state
                    .wayland
                    .as_ref()
                    .and_then(|frontend| frontend.input_layout.as_ref())
                    .is_some_and(InputLayoutSnapshot::observes_client_pointer_presses)
            {
                state.queue_shell_action(
                    super::super::super::wire::ShellAction::ClientPointerPressed,
                    None,
                );
            }
            if matches!(&target, InputTarget::Flutter) {
                let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                match button.state() {
                    ButtonState::Pressed if button_code == BTN_LEFT => {
                        frontend.flutter_pointer_press = Some(FlutterPointerPress {
                            button: button_code,
                            serial,
                            time: button.time_msec(),
                            location: frontend.pointer_location,
                        });
                    }
                    ButtonState::Released
                        if frontend
                            .flutter_pointer_press
                            .is_some_and(|press| press.button == button_code) =>
                    {
                        frontend.flutter_pointer_press = None;
                    }
                    _ => {}
                }
            }
            if clipboard_drag_active && button.state() == ButtonState::Released {
                // A compositor-owned DnD grab still mirrors the terminal
                // release into Flutter. This completes the original shell
                // gesture so its card preview can settle instead of being
                // abandoned when Smithay receives the actual drop.
                state.synchronize_flutter_pointer_position();
                state.flutter_input.handle(&event);
                state
                    .wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .set_clipboard_drag_active(false);
            }
            match target {
                InputTarget::Flutter if secure_locked || !pointer_grabbed => {
                    state.synchronize_flutter_pointer_position();
                    state.flutter_input.handle(&event);
                    false
                }
                target => {
                    if button.state() == ButtonState::Pressed
                        && let InputTarget::Client(route) = &target
                    {
                        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                        frontend.remember_client_pointer_press(route, serial, button_code);
                        if !pointer_grabbed {
                            frontend.client_pointer_capture = Some(route.clone());
                            frontend.client_pointer_buttons.insert(button_code);
                            scene_changed = activate_client_route(state, route, serial);
                        }
                    }
                    update_pressed_buttons(
                        &mut state
                            .wayland
                            .as_mut()
                            .expect("missing Wayland frontend")
                            .wayland_pointer_buttons,
                        button_code,
                        button.state(),
                    );
                    pointer.button(
                        state,
                        &ButtonEvent {
                            button: button_code,
                            state: button.state(),
                            serial,
                            time: button.time_msec(),
                        },
                    );
                    pointer.frame(state);
                    if button.state() == ButtonState::Released {
                        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                        frontend.client_pointer_buttons.remove(&button_code);
                        if frontend.client_pointer_buttons.is_empty() && !pointer.is_grabbed() {
                            frontend.client_pointer_capture = None;
                        }
                    }
                    if scene_changed {
                        state.scene_sync.mark_dirty();
                    }
                    true
                }
            }
        }
        InputEvent::PointerAxis { event: axis, .. } => {
            state
                .wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .set_pointer_cursor_visible(true);
            let pointer_grabbed = state
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .seat
                .get_pointer()
                .expect("seat has no pointer")
                .is_grabbed();
            let flutter_captured = state.flutter_input.pointer_captured();
            let flutter_target = {
                let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                if secure_locked || flutter_captured {
                    true
                } else if frontend.client_pointer_capture.is_some() {
                    false
                } else {
                    let position = frontend.pointer_location;
                    frontend.input_route(position).is_none()
                }
            };
            if flutter_target && (secure_locked || !pointer_grabbed) {
                state.synchronize_flutter_pointer_position();
                let scroll_speed_factor = state
                    .wayland
                    .as_ref()
                    .expect("missing Wayland frontend")
                    .settings
                    .touchpad()
                    .scroll_speed_factor;
                state
                    .flutter_input
                    .handle_with_scroll_speed_factor(&event, scroll_speed_factor);
                false
            } else {
                state.flutter_input.finish_touchpad_pan();
                route_pointer_axis(state, axis);
                true
            }
        }
        InputEvent::TouchDown {
            event: touch_event, ..
        } => {
            let serial = SERIAL_COUNTER.next_serial();
            let slot = i32::from(touch_event.slot());
            let (position, scene_position, software_keyboard_touch) = {
                let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                frontend.set_pointer_cursor_visible(false);
                let position = output_bound_absolute_position(
                    touch_event,
                    frontend.touch_bounds,
                    frontend.touch_transform,
                );
                let scene_position = position - frontend.atlas_origin;
                (
                    position,
                    scene_position,
                    software_keyboard_owns_touch(frontend.input_layout.as_ref(), scene_position),
                )
            };
            let gesture = {
                let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                let target = (!secure_locked)
                    .then(|| frontend.touch_window_target_at(position))
                    .flatten();
                frontend.touch_gestures.down(slot, position, target)
            };
            let gesture_consumed = gesture.consume;
            let flush_clients = apply_touch_gesture_update(state, gesture);
            if gesture_consumed {
                return flush_clients;
            }
            let target = if secure_locked {
                InputTarget::Flutter
            } else {
                state
                    .wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .input_target(position)
            };
            match target {
                InputTarget::Flutter => {
                    let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                    if !software_keyboard_touch {
                        frontend.text_input.note_flutter_touch();
                    }
                    frontend.flutter_touch_slots.insert(slot);
                    let scale = frontend.atlas_scale;
                    state.flutter_input.handle_touch_at(
                        &event,
                        scene_position.x * scale,
                        scene_position.y * scale,
                    );
                    false
                }
                InputTarget::Client(route) => {
                    let scene_changed = activate_client_route(state, &route, serial);
                    state
                        .wayland
                        .as_mut()
                        .expect("missing Wayland frontend")
                        .text_input
                        .note_client_touch();
                    let focus = route.focus_at(position);
                    let touch = state
                        .wayland
                        .as_ref()
                        .expect("missing Wayland frontend")
                        .seat
                        .get_touch()
                        .expect("seat has no touch");
                    touch.down(
                        state,
                        Some(focus),
                        &DownEvent {
                            slot: touch_event.slot(),
                            location: position,
                            serial,
                            time: touch_event.time_msec(),
                        },
                    );
                    state
                        .wayland
                        .as_mut()
                        .expect("missing Wayland frontend")
                        .client_touch_routes
                        .insert(slot, route);
                    state
                        .wayland
                        .as_mut()
                        .expect("missing Wayland frontend")
                        .client_touch_frame_pending = true;
                    if scene_changed {
                        state.scene_sync.mark_dirty();
                    }
                    true
                }
            }
        }
        InputEvent::TouchMotion {
            event: touch_event, ..
        } => {
            let slot = i32::from(touch_event.slot());
            let (position, scene_position) = {
                let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
                let position = output_bound_absolute_position(
                    touch_event,
                    frontend.touch_bounds,
                    frontend.touch_transform,
                );
                (position, position - frontend.atlas_origin)
            };
            let gesture = state
                .wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .touch_gestures
                .motion(slot, position);
            let gesture_consumed = gesture.consume;
            let flush_clients = apply_touch_gesture_update(state, gesture);
            if gesture_consumed {
                return flush_clients;
            }
            let flutter_target = state
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .flutter_touch_slots
                .contains(&slot);
            if flutter_target {
                let scale = state
                    .wayland
                    .as_ref()
                    .expect("missing Wayland frontend")
                    .atlas_scale;
                state.flutter_input.handle_touch_at(
                    &event,
                    scene_position.x * scale,
                    scene_position.y * scale,
                );
                return false;
            }
            let focus = {
                let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
                frontend
                    .client_touch_routes
                    .get(&slot)
                    .map(|route| route.focus_at(position))
            };
            if let Some(focus) = focus {
                let touch = state
                    .wayland
                    .as_ref()
                    .expect("missing Wayland frontend")
                    .seat
                    .get_touch()
                    .expect("seat has no touch");
                touch.motion(
                    state,
                    Some(focus),
                    &TouchMotionEvent {
                        slot: touch_event.slot(),
                        location: position,
                        time: touch_event.time_msec(),
                    },
                );
                state
                    .wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .client_touch_frame_pending = true;
                true
            } else {
                false
            }
        }
        InputEvent::TouchUp {
            event: touch_event, ..
        } => {
            let slot = i32::from(touch_event.slot());
            let gesture = state
                .wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .touch_gestures
                .up(slot);
            let gesture_consumed = gesture.consume;
            let flush_clients = apply_touch_gesture_update(state, gesture);
            if gesture_consumed {
                return flush_clients;
            }
            let flutter_target = state
                .wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .flutter_touch_slots
                .remove(&slot);
            if flutter_target {
                state.flutter_input.handle(&event);
                return false;
            }
            let client_target = state
                .wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .client_touch_routes
                .remove(&slot)
                .is_some();
            if client_target {
                let touch = state
                    .wayland
                    .as_ref()
                    .expect("missing Wayland frontend")
                    .seat
                    .get_touch()
                    .expect("seat has no touch");
                touch.up(
                    state,
                    &UpEvent {
                        slot: touch_event.slot(),
                        serial: SERIAL_COUNTER.next_serial(),
                        time: touch_event.time_msec(),
                    },
                );
                state
                    .wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .client_touch_frame_pending = true;
            }
            client_target
        }
        InputEvent::TouchFrame { .. }
            if std::mem::take(
                &mut state
                    .wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .client_touch_frame_pending,
            ) =>
        {
            let touch = state
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .seat
                .get_touch()
                .expect("seat has no touch");
            touch.frame(state);
            true
        }
        InputEvent::TouchFrame { .. } => false,
        InputEvent::TouchCancel {
            event: touch_event, ..
        } => {
            let slot = i32::from(touch_event.slot());
            let gesture = state
                .wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .touch_gestures
                .cancel(slot);
            let gesture_consumed = gesture.consume;
            let flush_clients = apply_touch_gesture_update(state, gesture);
            if gesture_consumed {
                return flush_clients;
            }
            let flutter_target = state
                .wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .flutter_touch_slots
                .remove(&slot);
            if flutter_target {
                state.flutter_input.handle(&event);
                false
            } else if state
                .wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .client_touch_routes
                .remove(&slot)
                .is_some()
            {
                let touch = state
                    .wayland
                    .as_ref()
                    .expect("missing Wayland frontend")
                    .seat
                    .get_touch()
                    .expect("seat has no touch");
                touch.cancel(state);
                let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                frontend.client_touch_routes.clear();
                frontend.client_touch_frame_pending = false;
                true
            } else {
                false
            }
        }
        _ => false,
    }
}

#[cfg(feature = "flutter")]
pub(super) fn deliver_routed_flutter_pointer_motion(
    state: &mut RuntimeState,
    target: RoutedPointerTarget,
) {
    let position = state.compositor_pointer_in_flutter_pixels();
    let Some((x, y)) = position else {
        return;
    };
    match target {
        RoutedPointerTarget::Flutter => state.flutter_input.handle_pointer_motion_at(x, y),
        RoutedPointerTarget::Client(_) => {
            if let Some(frontend) = state.wayland.as_mut() {
                frontend.queue_cursor_position();
            }
            // This is intentionally retried for every client-routed sample.
            // A Flutter-owned drag keeps its Down lifecycle until drop, so the
            // first eligible Remove can occur after the route itself changed.
            state.flutter_input.handle_pointer_leave_at(x, y);
        }
    }
}

#[cfg(feature = "flutter")]
pub(super) fn route_pointer_motion(
    state: &mut RuntimeState,
    position: Point<f64, Logical>,
    target: PointerMotionTarget,
    time: u32,
    relative: Option<RelativeMotionEvent>,
) -> bool {
    let PointerMotionTarget {
        routed: routed_target,
        focus: under,
    } = target;
    super::super::clipboard_io::release_deferred_clipboard_capture(
        state,
        under.as_ref().map(|(surface, _)| surface),
    );
    let pointer = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .seat
        .get_pointer()
        .expect("seat has no pointer");
    if under.is_none() && pointer.current_focus().is_none() && !pointer.is_grabbed() {
        // Flutter owns this part of the scene and no Wayland client can
        // observe relative or absolute pointer traffic here. Once the leave
        // edge has cleared Smithay's focus, keep cursor state current without
        // constructing protocol events or consuming a serial per sample.
        {
            let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
            frontend.pointer_location = position;
            frontend.set_routed_pointer_target(routed_target);
        }
        deliver_routed_flutter_pointer_motion(state, routed_target);
        return false;
    }
    let blocked = pointer_constraint_blocks_motion(
        &pointer,
        &under,
        position,
        pointer_constraint_reactivation_suppressed(state, &pointer),
    );
    if let Some(relative) = relative {
        let relative_focus = if blocked {
            pointer
                .current_focus()
                .map(|surface| (surface, Point::from((0.0, 0.0))))
        } else {
            under.clone()
        };
        pointer.relative_motion(state, relative_focus, &relative);
    }
    if blocked {
        pointer.frame(state);
        return true;
    }
    {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        frontend.pointer_location = position;
        frontend.set_routed_pointer_target(routed_target);
    }
    pointer.motion(
        state,
        under,
        &MotionEvent {
            location: position,
            serial: SERIAL_COUNTER.next_serial(),
            time,
        },
    );
    pointer.frame(state);
    deliver_routed_flutter_pointer_motion(state, routed_target);
    true
}

#[cfg(feature = "flutter")]
pub(super) fn flutter_pointer_endpoint_is_synchronized(
    current: RoutedPointerTarget,
    desired: RoutedPointerTarget,
    lifecycle_active: bool,
    flutter_capture_active: bool,
) -> bool {
    if current != desired {
        return false;
    }
    match desired {
        RoutedPointerTarget::Flutter => lifecycle_active,
        RoutedPointerTarget::Client(_) => !lifecycle_active || flutter_capture_active,
    }
}

#[cfg(feature = "flutter")]
pub(crate) fn reconcile_flutter_pointer_route(state: &mut RuntimeState) {
    if !state.flutter_active {
        return;
    }
    let pointer = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .seat
        .get_pointer()
        .expect("seat has no pointer");
    if pointer.is_grabbed() {
        return;
    }
    let secure_locked = state.secure_session_locked();
    let flutter_captured = state.flutter_input.pointer_captured();
    let lifecycle_active = state.flutter_input.mouse_lifecycle_active();
    let (position, target, current_target, time) = {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        let position = frontend.pointer_location;
        let target = if secure_locked || (flutter_captured && !frontend.clipboard_drag_active) {
            PointerMotionTarget::FLUTTER
        } else if let Some(route) = frontend.client_pointer_capture.as_ref() {
            PointerMotionTarget::client(route, position)
        } else {
            frontend.pointer_motion_target(position)
        };
        (
            position,
            target,
            frontend.routed_pointer_target,
            frontend.start_time.elapsed().as_millis() as u32,
        )
    };
    if flutter_pointer_endpoint_is_synchronized(
        current_target,
        target.routed,
        lifecycle_active,
        flutter_captured,
    ) {
        return;
    }
    route_pointer_motion(state, position, target, time, None);
}

pub(super) fn pointer_constraint_blocks_motion(
    pointer: &PointerHandle<RuntimeState>,
    proposed_focus: &Option<(WlSurface, Point<f64, Logical>)>,
    proposed_location: Point<f64, Logical>,
    reactivation_suppressed: bool,
) -> bool {
    let Some(current_focus) = pointer.current_focus() else {
        return false;
    };
    with_pointer_constraint(&current_focus, pointer, |constraint| {
        let Some(constraint) = constraint else {
            return false;
        };
        if reactivation_suppressed {
            // SUPER+Escape is an explicit user override. Even if Xwayland
            // replaces its constraint before the pointer leaves the game,
            // keep it inactive until a plain click acknowledges re-entry.
            constraint.deactivate();
            return false;
        }
        if !constraint.is_active() {
            // SUPER+A/TAB deliberately deactivates the client's constraint
            // before the shell overlay takes the pointer. Do not immediately
            // reactivate it while motion is trying to leave that surface.
            let remains_on_focused_surface = proposed_focus
                .as_ref()
                .is_some_and(|(surface, _)| surface == &current_focus);
            if !remains_on_focused_surface {
                return false;
            }
            constraint.activate();
        }
        match &*constraint {
            PointerConstraint::Locked(_) => true,
            PointerConstraint::Confined(_) => {
                let Some((surface, origin)) = proposed_focus else {
                    return true;
                };
                if surface != &current_focus {
                    return true;
                }
                constraint.region().is_some_and(|region| {
                    !region.contains((proposed_location - *origin).to_i32_round())
                })
            }
        }
    })
}

pub(super) fn pointer_constraint_reactivation_suppressed(
    state: &RuntimeState,
    pointer: &PointerHandle<RuntimeState>,
) -> bool {
    #[cfg(feature = "flutter")]
    {
        let Some(surface) = pointer.current_focus() else {
            return false;
        };
        state
            .wayland
            .as_ref()
            .is_some_and(|frontend| frontend.pointer_constraint_released_for_surface(&surface))
    }
    #[cfg(not(feature = "flutter"))]
    {
        let _ = (state, pointer);
        false
    }
}

#[cfg(feature = "flutter")]
fn route_super_scrolling_layout_wheel<E: PointerAxisEvent<LibinputInputBackend>>(
    state: &mut RuntimeState,
    event: &E,
) -> bool {
    if event.source() != AxisSource::Wheel
        || !state.flutter_active
        || state.secure_session_locked()
        || !state.native_escape_shortcut.super_pressed()
    {
        return false;
    }
    let shell_owns_scene = state
        .wayland
        .as_ref()
        .and_then(|frontend| frontend.input_layout.as_ref())
        .is_some_and(InputLayoutSnapshot::exclusive_shell);
    if shell_owns_scene {
        return false;
    }
    let vertical_delta = logical_axis_scroll_delta(
        AxisSource::Wheel,
        event.amount(Axis::Vertical),
        event.amount_v120(Axis::Vertical),
        1.0,
    );
    if vertical_delta == 0.0
        || !state
            .wayland
            .as_ref()
            .is_some_and(WaylandFrontend::can_scroll_layout_horizontally)
    {
        return false;
    }

    state.native_escape_shortcut.note_pointer_axis();
    update_mouse_wheel_layout_scroll(state, vertical_delta);
    finish_horizontal_layout_scroll(state, false, None);
    true
}

pub(super) fn route_pointer_axis<E: PointerAxisEvent<LibinputInputBackend>>(
    state: &mut RuntimeState,
    event: &E,
) {
    #[cfg(feature = "flutter")]
    if route_super_scrolling_layout_wheel(state, event) {
        return;
    }
    let source = event.source();
    let horizontal_amount = event.amount(Axis::Horizontal);
    let vertical_amount = event.amount(Axis::Vertical);
    let horizontal_v120 = event.amount_v120(Axis::Horizontal);
    let vertical_v120 = event.amount_v120(Axis::Vertical);
    let scroll_speed_factor = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .settings
        .touchpad()
        .scroll_speed_factor;
    let horizontal = logical_axis_scroll_delta(
        source,
        horizontal_amount,
        horizontal_v120,
        scroll_speed_factor,
    );
    let vertical =
        logical_axis_scroll_delta(source, vertical_amount, vertical_v120, scroll_speed_factor);
    let mut frame = AxisFrame::new(event.time_msec()).source(source);
    if horizontal != 0.0 {
        frame = frame.value(Axis::Horizontal, horizontal);
        if let Some(v120) = horizontal_v120 {
            frame = frame.v120(Axis::Horizontal, v120 as i32);
        }
    }
    if vertical != 0.0 {
        frame = frame.value(Axis::Vertical, vertical);
        if let Some(v120) = vertical_v120 {
            frame = frame.v120(Axis::Vertical, v120 as i32);
        }
    }
    if source == AxisSource::Finger {
        if horizontal_amount == Some(0.0) {
            frame = frame.stop(Axis::Horizontal);
        }
        if vertical_amount == Some(0.0) {
            frame = frame.stop(Axis::Vertical);
        }
    }
    let pointer = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .seat
        .get_pointer()
        .expect("seat has no pointer");
    pointer.axis(state, frame);
    pointer.frame(state);
}

#[cfg(feature = "flutter")]
pub(super) fn activate_client_route(
    state: &mut RuntimeState,
    route: &ClientInputRoute,
    serial: Serial,
) -> bool {
    let Some(target_window) = route.window.as_ref() else {
        if let Some(layer_root) = route.layer_root.as_ref() {
            let keyboard_focus = state
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .layer_keyboard_focus_for_surface(layer_root);
            if let Some(keyboard_focus) = keyboard_focus {
                let keyboard = state
                    .wayland
                    .as_ref()
                    .expect("missing Wayland frontend")
                    .seat
                    .get_keyboard()
                    .expect("seat has no keyboard");
                if keyboard.current_focus().as_ref() != Some(&keyboard_focus) {
                    request_keyboard_focus(state, &keyboard, Some(keyboard_focus), serial);
                }
            }
        }
        // Input-method candidate surfaces receive pointer/touch input without
        // stealing the keyboard focus from the editor they serve. Layer-shell
        // surfaces use their committed keyboard-interactivity mode above.
        return false;
    };
    let keyboard = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .seat
        .get_keyboard()
        .expect("seat has no keyboard");
    let Some(keyboard_focus) = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .keyboard_focus_for_window(target_window)
    else {
        // Client-owned popup windows still receive the pointer/touch event,
        // but must not replace their managed owner's activation or focus.
        return false;
    };
    let scene_changed = {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        let mut changed = frontend.space.elements().next_back() != Some(target_window);
        // Always offer the raise to XWM too: Space may already be correct
        // while Xwayland's independent X stack is stale.
        frontend.raise_window(target_window, true);
        for window in frontend.space.elements() {
            let activation_changed = window.set_activated(window == target_window);
            changed |= activation_changed;
            if activation_changed && let Some(toplevel) = window.toplevel() {
                toplevel.send_pending_configure();
            }
        }
        changed
    };
    if keyboard.current_focus().as_ref() != Some(&keyboard_focus) {
        request_keyboard_focus(state, &keyboard, Some(keyboard_focus), serial);
        state
            .pending_window_events
            .push(PendingWindowEvent::Activated(route.region.window_id));
    }
    scene_changed
}

#[cfg(feature = "flutter")]
pub(super) fn release_client_geometry_for_shell_grab(
    state: &mut RuntimeState,
    window: &smithay::desktop::Window,
) {
    let client_constraints_cleared =
        super::super::window_management::clear_client_geometry_constraints(window);

    let target = {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        let root = frontend.window_root_surface(window);
        let (restore, shell_owned) = root.as_ref().map_or((None, false), |surface| {
            let surface_id = surface.id();
            let presentation = frontend.take_shell_presentation(&surface_id);
            let shell_owned = presentation.is_some();
            let restore = presentation
                .map(|presentation| presentation.normal_geometry())
                .or_else(|| {
                    frontend
                        .window_record_for_surface(&surface_id)
                        .and_then(|record| record.layout_restore_geometry)
                })
                .or_else(|| frontend.take_restore_geometry(&surface_id));
            (restore, shell_owned)
        });
        if let Some(restore) = restore {
            frontend.set_window_geometry_target(window, restore);
            Some(restore)
        } else if client_constraints_cleared || shell_owned {
            Some(frontend.window_geometry_target(window))
        } else {
            None
        }
    };
    let Some(target) = target else {
        return;
    };
    if let Some(window) = super::super::managed_window::ManagedWindow::new(window) {
        window.prepare_shell_geometry(target);
    }
    if state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .window_is_layout_managed(window)
    {
        state
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .arrange_layout_windows();
    }
    state.scene_sync.mark_dirty();
}

#[cfg(feature = "flutter")]
pub(super) fn begin_local_super_pointer_grab(
    state: &mut RuntimeState,
    region: InputWindowRegion,
    action: SuperPointerAction,
    button: u32,
    serial: Serial,
) -> bool {
    if region.geometry_locked() {
        return false;
    }
    let Some((position, geometry)) = state.wayland.as_ref().and_then(|frontend| {
        frontend
            .local_flutter_window_geometry(region.window_id)
            .map(|geometry| (frontend.pointer_location, geometry))
    }) else {
        return false;
    };
    if !super::super::window_management::activate_local_flutter_window(state, region.window_id) {
        return false;
    }
    super::super::window_management::queue_local_flutter_window_placement(
        state,
        region.window_id,
        WindowPlacementPhase::Begin,
        match action {
            SuperPointerAction::Move => WindowPlacementChange::Move,
            SuperPointerAction::Resize => WindowPlacementChange::Resize,
        },
    );
    let start_data = GrabStartData {
        focus: None,
        button,
        location: position,
    };
    let grab = match action {
        SuperPointerAction::Move => {
            LocalFlutterWindowGrab::new_move(start_data, region.window_id, geometry)
        }
        SuperPointerAction::Resize => {
            let global_geometry = Rectangle::new(
                Point::from((geometry.x.round() as i32, geometry.y.round() as i32)),
                (
                    geometry.width.round() as i32,
                    geometry.height.round() as i32,
                )
                    .into(),
            );
            let edge = resize_edge_for_geometry(position, global_geometry);
            let edges = ResizeEdges::from_xdg(edge).expect("corner is a valid resize edge");
            LocalFlutterWindowGrab::new_resize(start_data, region.window_id, geometry, edges)
        }
    };
    state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .seat
        .get_pointer()
        .expect("seat has no pointer")
        .set_grab(state, grab, serial, Focus::Clear);
    true
}

#[cfg(feature = "flutter")]
pub(super) fn begin_super_pointer_grab(
    state: &mut RuntimeState,
    route: &ClientInputRoute,
    action: SuperPointerAction,
    button: u32,
    serial: Serial,
) -> bool {
    let Some(window) = route.window.clone() else {
        return false;
    };
    // The published fullscreen state suppresses SUPER+LMB/RMB. Every other
    // client or shell geometry constraint is released before selecting the
    // common managed-layout or floating grab implementation.
    if route.region.geometry_locked() {
        return false;
    }
    release_client_geometry_for_shell_grab(state, &window);
    let layout_managed = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .window_is_layout_managed(&window);
    if layout_managed {
        let (position, geometry, scrolling_resize_axis) = {
            let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
            (
                frontend.pointer_location,
                frontend.window_geometry_target(&window),
                frontend.scrolling_resize_axis_for_window(&window),
            )
        };
        let start_data = GrabStartData {
            focus: Some(route.focus_at(position)),
            button,
            location: position,
        };
        activate_client_route(state, route, serial);
        state
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .set_compositor_pointer_grab_active(true);
        super::super::queue_transient_window_placement(
            state,
            &window,
            geometry,
            WindowPlacementPhase::Begin,
            match action {
                SuperPointerAction::Move => WindowPlacementChange::Move,
                SuperPointerAction::Resize => WindowPlacementChange::Resize,
            },
        );
        let pointer = state
            .wayland
            .as_ref()
            .expect("missing Wayland frontend")
            .seat
            .get_pointer()
            .expect("seat has no pointer");
        match action {
            SuperPointerAction::Move => pointer.set_grab(
                state,
                TileMoveGrab::new(start_data, window, geometry),
                serial,
                Focus::Clear,
            ),
            SuperPointerAction::Resize => {
                let edges =
                    LayoutResizeEdges::from_pointer(position, geometry, scrolling_resize_axis);
                pointer.set_grab(
                    state,
                    TileResizeGrab::new(start_data, window, edges),
                    serial,
                    Focus::Clear,
                );
            }
        }
        return true;
    }
    let (position, initial_location, geometry) = {
        let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
        (
            frontend.pointer_location,
            frontend.space.element_location(&window).unwrap_or_default(),
            frontend.window_geometry_target(&window),
        )
    };
    let start_data = GrabStartData {
        focus: Some(route.focus_at(position)),
        button,
        location: position,
    };

    activate_client_route(state, route, serial);
    state
        .wayland
        .as_mut()
        .expect("missing Wayland frontend")
        .set_compositor_pointer_grab_active(true);
    let pointer = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .seat
        .get_pointer()
        .expect("seat has no pointer");
    match action {
        SuperPointerAction::Move => {
            super::super::queue_window_placement(
                state,
                &window,
                geometry,
                WindowPlacementPhase::Begin,
                WindowPlacementChange::Move,
            );
            pointer.set_grab(
                state,
                MoveSurfaceGrab::new_compositor(start_data, window, initial_location),
                serial,
                Focus::Clear,
            );
        }
        SuperPointerAction::Resize => {
            let edge = resize_edge_for_geometry(position, geometry);
            let edges = ResizeEdges::from_xdg(edge).expect("corner is a valid resize edge");
            super::super::queue_window_placement(
                state,
                &window,
                geometry,
                WindowPlacementPhase::Begin,
                WindowPlacementChange::Resize,
            );
            let prepared = state.wayland.as_ref().is_some_and(|frontend| {
                if !frontend.window_accepts_grab_updates(&window) {
                    return false;
                }
                frontend.prepare_window_interactive_resize(&window, geometry.size, false);
                true
            });
            if !prepared {
                state
                    .wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .set_compositor_pointer_grab_active(false);
                return false;
            }
            pointer.set_grab(
                state,
                ResizeSurfaceGrab::new_compositor(
                    start_data,
                    window,
                    edges,
                    initial_location,
                    geometry.size,
                ),
                serial,
                Focus::Clear,
            );
        }
    }
    true
}

pub(super) fn process_wayland_keyboard_transition(
    state: &mut RuntimeState,
    keycode: Keycode,
    key_state: KeyState,
    time: u32,
) {
    #[cfg(not(feature = "flutter"))]
    focus_exclusive_layer_for_keyboard_event(state);
    let keyboard = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .seat
        .get_keyboard()
        .expect("seat has no keyboard");
    let consume_retired = retired_key_consumes_transition(
        &mut state
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .retired_keyboard_keys,
        keycode.raw(),
        key_state,
    );
    keyboard.input::<(), _>(
        state,
        keycode,
        key_state,
        SERIAL_COUNTER.next_serial(),
        time,
        move |_, _, _| {
            if consume_retired {
                FilterResult::Intercept(())
            } else {
                FilterResult::Forward
            }
        },
    );
    #[cfg(feature = "flutter")]
    synchronize_active_keyboard_layout(state, &keyboard);
}
