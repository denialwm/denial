//! Client-owned Wayland input dispatch.

use super::super::focus::{clear_keyboard_focus, request_keyboard_focus};
use super::flutter_route::{
    pointer_constraint_blocks_motion, pointer_constraint_reactivation_suppressed,
    process_wayland_keyboard_transition, route_pointer_axis,
};
use super::*;

fn activate_surface_at(
    state: &mut RuntimeState,
    position: Point<f64, Logical>,
    serial: smithay::utils::Serial,
) {
    let (keyboard, surface, window, layer_focus) = {
        let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
        let surface = frontend.surface_under(position).map(|(surface, _)| surface);
        let window = surface.as_ref().and_then(|surface| {
            frontend
                .owning_toplevel_surface(surface)
                .and_then(|root| frontend.window_for_root_surface(&root))
        });
        let layer_focus = surface
            .as_ref()
            .and_then(|surface| frontend.layer_keyboard_focus_for_surface(surface));
        (
            frontend.seat.get_keyboard().expect("seat has no keyboard"),
            surface,
            window,
            layer_focus,
        )
    };

    if let Some(window) = window {
        #[cfg(feature = "flutter")]
        {
            let window_id = state
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .window_root_surface(&window)
                .and_then(|surface| {
                    state
                        .wayland
                        .as_ref()
                        .expect("missing Wayland frontend")
                        .surface_id(&surface)
                });
            if let Some(window_id) = window_id {
                state
                    .wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .pointer_constraint_escape
                    .resume_window(window_id);
            }
        }
        let focus = state
            .wayland
            .as_ref()
            .expect("missing Wayland frontend")
            .keyboard_focus_for_window(&window);
        if let Some(focus) = focus {
            let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
            frontend.raise_window(&window, true);
            for candidate in frontend.space.elements() {
                let changed = candidate.set_activated(candidate == &window);
                if changed && let Some(toplevel) = candidate.toplevel() {
                    toplevel.send_pending_configure();
                }
            }
            request_keyboard_focus(state, &keyboard, Some(focus), serial);
        }
    } else if let Some(focus) = layer_focus {
        request_keyboard_focus(state, &keyboard, Some(focus), serial);
    } else if surface.is_none() {
        clear_keyboard_focus(state, &keyboard, serial);
    }
}

pub(super) fn process_wayland_input_event(
    state: &mut RuntimeState,
    event: InputEvent<LibinputInputBackend>,
) {
    match event {
        InputEvent::Keyboard { event, .. } => process_wayland_keyboard_transition(
            state,
            event.key_code(),
            event.state(),
            event.time_msec(),
        ),
        InputEvent::PointerMotion { event, .. } => {
            let (position, under) = {
                let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                let position = frontend.clamp_pointer(frontend.pointer_location + event.delta());
                (position, frontend.surface_under(position))
            };
            let pointer = state
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .seat
                .get_pointer()
                .expect("seat has no pointer");
            let blocked = pointer_constraint_blocks_motion(
                &pointer,
                &under,
                position,
                pointer_constraint_reactivation_suppressed(state, &pointer),
            );
            pointer.relative_motion(
                state,
                if blocked {
                    pointer
                        .current_focus()
                        .map(|surface| (surface, Point::from((0.0, 0.0))))
                } else {
                    under.clone()
                },
                &RelativeMotionEvent {
                    delta: event.delta(),
                    delta_unaccel: event.delta_unaccel(),
                    utime: event.time_usec(),
                },
            );
            if blocked {
                pointer.frame(state);
                return;
            }
            state
                .wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .pointer_location = position;
            pointer.motion(
                state,
                under,
                &MotionEvent {
                    location: position,
                    serial: SERIAL_COUNTER.next_serial(),
                    time: event.time_msec(),
                },
            );
            pointer.frame(state);
        }
        InputEvent::PointerMotionAbsolute { event, .. } => {
            let (position, under) = {
                let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                let local = event.position_transformed(frontend.desktop_bounds.size);
                let position = frontend.clamp_pointer(local + frontend.desktop_bounds.loc.to_f64());
                (position, frontend.surface_under(position))
            };
            let pointer = state
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .seat
                .get_pointer()
                .expect("seat has no pointer");
            if pointer_constraint_blocks_motion(
                &pointer,
                &under,
                position,
                pointer_constraint_reactivation_suppressed(state, &pointer),
            ) {
                pointer.frame(state);
                return;
            }
            state
                .wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .pointer_location = position;
            pointer.motion(
                state,
                under,
                &MotionEvent {
                    location: position,
                    serial: SERIAL_COUNTER.next_serial(),
                    time: event.time_msec(),
                },
            );
            pointer.frame(state);
        }
        InputEvent::PointerButton { event, .. } => {
            let serial = SERIAL_COUNTER.next_serial();
            #[cfg(feature = "flutter")]
            if retired_pointer_button_consumes_transition(
                &mut state
                    .wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .retired_pointer_buttons,
                event.button_code(),
                event.state(),
            ) {
                return;
            }
            let pointer = state
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .seat
                .get_pointer()
                .expect("seat has no pointer");
            if event.state() == ButtonState::Pressed && !pointer.is_grabbed() {
                activate_surface_at(state, pointer.current_location(), serial);
            }

            update_pressed_buttons(
                &mut state
                    .wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .wayland_pointer_buttons,
                event.button_code(),
                event.state(),
            );
            pointer.button(
                state,
                &ButtonEvent {
                    button: event.button_code(),
                    state: event.state(),
                    serial,
                    time: event.time_msec(),
                },
            );
            pointer.frame(state);
            state.scene_sync.mark_dirty();
        }
        InputEvent::PointerAxis { event, .. } => route_pointer_axis(state, &event),
        InputEvent::TouchDown { event, .. } => {
            let serial = SERIAL_COUNTER.next_serial();
            let position = {
                let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
                output_bound_absolute_position(
                    &event,
                    frontend.touch_bounds,
                    frontend.touch_transform,
                )
            };
            let touch = {
                let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
                frontend.seat.get_touch().expect("seat has no touch")
            };
            activate_surface_at(state, position, serial);

            let under = state
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .surface_under(position);
            touch.down(
                state,
                under,
                &DownEvent {
                    slot: event.slot(),
                    location: position,
                    serial,
                    time: event.time_msec(),
                },
            );
            state.scene_sync.mark_dirty();
        }
        InputEvent::TouchMotion { event, .. } => {
            let (position, under) = {
                let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
                let position = output_bound_absolute_position(
                    &event,
                    frontend.touch_bounds,
                    frontend.touch_transform,
                );
                (position, frontend.surface_under(position))
            };
            let touch = state
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .seat
                .get_touch()
                .expect("seat has no touch");
            touch.motion(
                state,
                under,
                &TouchMotionEvent {
                    slot: event.slot(),
                    location: position,
                    time: event.time_msec(),
                },
            );
        }
        InputEvent::TouchUp { event, .. } => {
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
                    slot: event.slot(),
                    serial: SERIAL_COUNTER.next_serial(),
                    time: event.time_msec(),
                },
            );
        }
        InputEvent::TouchFrame { .. } => {
            let touch = state
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .seat
                .get_touch()
                .expect("seat has no touch");
            touch.frame(state);
        }
        InputEvent::TouchCancel { .. } => {
            let touch = state
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .seat
                .get_touch()
                .expect("seat has no touch");
            touch.cancel(state);
        }
        _ => {}
    }
}
