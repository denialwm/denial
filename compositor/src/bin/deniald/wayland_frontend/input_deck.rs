//! Touch-output reservation and virtual input through Denial's normal seat routers.
use std::error::Error;

use smithay::backend::input::{Axis, AxisSource, ButtonState, InputTime, KeyState};
use smithay::input::keyboard::Keycode;
use smithay::input::pointer::{AxisFrame, RelativeMotionEvent};
use smithay::utils::Point;

use crate::input_deck::{Command, ScreenGestureUpdate, Snapshot};
use crate::{RuntimeState, flutter_runtime::FlutterRuntime};

use super::input::{self, PointerMotionTarget};

pub(in super::super) fn snapshot(state: &RuntimeState) -> Snapshot {
    let Some(frontend) = state.wayland.as_ref() else {
        return Snapshot::default();
    };
    let touch_outputs = state
        .input_devices
        .touchscreens
        .values()
        .filter_map(|device| input::touch_output_for_device(frontend, device))
        .filter(|output| output.powered)
        .map(|output| output.connector.clone())
        .collect::<std::collections::BTreeSet<_>>()
        .into_iter()
        .collect::<Vec<_>>();
    Snapshot {
        touch_output: touch_outputs.first().cloned(),
        available: !touch_outputs.is_empty()
            && frontend
                .outputs
                .iter()
                .filter(|output| output.powered)
                .count()
                > 1,
        touch_outputs,
        key_labels: Default::default(),
        locked: state.secure_session_locked(),
        active_output: frontend
            .input_deck_output
            .and_then(|id| frontend.outputs.iter().find(|output| output.id == id))
            .map(|output| output.connector.clone()),
    }
}

fn release(state: &mut RuntimeState) {
    if state.input_deck.keys.is_empty()
        && state.input_deck.buttons.is_empty()
        && !state.input_deck.scrolling
    {
        return;
    }
    state.native_escape_shortcut.cancel_modifier_tap();
    state.input_deck.scrolling = false;
    let keys = std::mem::take(&mut state.input_deck.keys);
    let buttons = std::mem::take(&mut state.input_deck.buttons);
    let Some(frontend) = state.wayland.as_ref() else {
        return;
    };
    let keyboard = frontend.seat.get_keyboard().expect("seat has no keyboard");
    let time = InputTime::now();
    for keycode in keys {
        input::inject_shell_key_transition(
            state,
            &keyboard,
            input::ShellKeyStroke {
                evdev_keycode: keycode,
                shift: false,
            },
            KeyState::Released,
            time,
        );
    }
    for button in buttons
        .into_iter()
        .map(|(button, _)| button)
        .collect::<std::collections::BTreeSet<_>>()
    {
        input::flutter_route::route_pointer_button(state, button, ButtonState::Released, time);
    }
    state.flutter_input.finish_touchpad_pan();
    let pointer = state
        .wayland
        .as_ref()
        .and_then(|frontend| frontend.seat.get_pointer());
    if let Some(pointer) = pointer {
        pointer.axis(
            state,
            AxisFrame::new(time)
                .source(AxisSource::Finger)
                .stop(Axis::Horizontal)
                .stop(Axis::Vertical),
        );
        pointer.frame(state);
    }
}

pub(super) fn apply_screen_gesture_update(
    state: &mut RuntimeState,
    update: ScreenGestureUpdate,
) -> bool {
    let claimed = !update.claimed_slots.is_empty();
    if claimed {
        let flutter_slots = state
            .wayland
            .as_ref()
            .map(|frontend| {
                update
                    .claimed_slots
                    .iter()
                    .copied()
                    .filter(|slot| frontend.flutter_touch_slots.contains(slot))
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        state
            .input_deck
            .screen_gestures
            .await_cancellation(flutter_slots);
        input::flutter_route::cancel_captured_touch_routes(state, &update.claimed_slots);
        release(state);
    }
    // Match a physical touchpad: gestures target the desktop under the pointer,
    // independent of the source touch screen's own output/workspace.
    update
        .event
        .is_some_and(|event| input::dispatch_swipe_gesture(state, event, None))
        || claimed
}

pub(super) fn cancel_screen_gestures(state: &mut RuntimeState) {
    let update = state.input_deck.screen_gestures.cancel_all();
    input::flutter_route::cancel_captured_touch_routes(state, &update.claimed_slots);
    release(state);
    if let Some(event) = update.event {
        input::dispatch_swipe_gesture(state, event, None);
    }
}

pub(in super::super) fn synchronize_input_deck(
    runtime: &mut FlutterRuntime,
    state: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    // A replacement shell must explicitly select its own input surface. A
    // composition without this feature cannot inherit an invisible reservation.
    if runtime.input_deck_snapshot.is_none() {
        cancel_screen_gestures(state);
        if let Some(frontend) = state.wayland.as_mut() {
            frontend.input_deck_output = None;
        }
        state.input_deck.legend_signature = None;
        state.input_deck.last_window_revision = None;
    }
    let mut current = snapshot(state);
    let locked = state.secure_session_locked();
    if current.active_output.is_some()
        && (!current.available
            || !current
                .active_output
                .as_ref()
                .is_some_and(|name| current.touch_outputs.contains(name))
            || !state.flutter_active)
    {
        cancel_screen_gestures(state);
        if let Some(frontend) = state.wayland.as_mut() {
            frontend.input_deck_output = None;
        }
        current = snapshot(state);
    }
    if locked {
        cancel_screen_gestures(state);
    }
    let mut requested = false;
    while let Some(command) = runtime.input_deck_commands.pop_front() {
        match command {
            Command::Read => requested = true,
            Command::Release => {
                cancel_screen_gestures(state);
            }
            Command::CancelContact { device } => state
                .input_deck
                .screen_gestures
                .acknowledge_cancellation(device),
            Command::Configure { output } => {
                let allowed = output.is_none()
                    || (!locked
                        && current.available
                        && output
                            .as_ref()
                            .is_some_and(|name| current.touch_outputs.contains(name)));
                if !allowed {
                    requested = true;
                    continue;
                }
                if current.active_output != output {
                    cancel_screen_gestures(state);
                    let frontend = state.frontend_mut();
                    frontend.input_deck_output = output
                        .as_ref()
                        .and_then(|name| {
                            frontend
                                .outputs
                                .iter()
                                .find(|entry| &entry.connector == name)
                        })
                        .map(|entry| entry.id);
                    frontend.pointer_location = frontend.clamp_pointer(frontend.pointer_location);
                    state.scene_sync.mark_dirty();
                    current = snapshot(state);
                }
                requested = true;
            }
            _ if locked
                || current.active_output.is_none()
                || state.input_deck.screen_gestures.blocks_input() => {}
            command => {
                state.note_user_activity();
                let frontend = state.frontend();
                let time = InputTime::now();
                match command {
                    Command::Motion { dx, dy } => {
                        let captured = state.flutter_input.pointer_captured();
                        let frontend = state.frontend_mut();
                        frontend.set_pointer_cursor_visible(true);
                        let delta = Point::from((dx, dy));
                        let position = frontend.clamp_pointer(frontend.pointer_location + delta);
                        let target = if captured {
                            PointerMotionTarget::FLUTTER
                        } else if let Some(route) = frontend.client_pointer_capture.as_ref() {
                            PointerMotionTarget::client(route, position)
                        } else {
                            frontend.pointer_motion_target(position)
                        };
                        input::flutter_route::route_pointer_motion(
                            state,
                            position,
                            target,
                            time,
                            Some(RelativeMotionEvent {
                                delta,
                                delta_unaccel: delta,
                                time,
                            }),
                        );
                    }
                    Command::Button {
                        button,
                        pressed,
                        source,
                    } => {
                        let seat_held = frontend.wayland_pointer_buttons.contains(&button)
                            || state.flutter_input.pointer_button_held(button);
                        if let Some(pressed) = state
                            .input_deck
                            .button_transition(button, source, pressed, seat_held)
                        {
                            input::flutter_route::route_pointer_button(
                                state,
                                button,
                                if pressed {
                                    ButtonState::Pressed
                                } else {
                                    ButtonState::Released
                                },
                                time,
                            );
                        }
                    }
                    Command::Key {
                        keycode,
                        pressed,
                        cancelled,
                    } => {
                        let keyboard = frontend.seat.get_keyboard().expect("seat has no keyboard");
                        let seat_held =
                            keyboard.pressed_keys().contains(&Keycode::new(keycode + 8));
                        let accepted = if pressed {
                            !seat_held && state.input_deck.keys.insert(keycode)
                        } else {
                            state.input_deck.keys.remove(&keycode)
                        };
                        if accepted {
                            if cancelled && !pressed {
                                state.native_escape_shortcut.cancel_modifier_tap();
                            }
                            input::inject_shell_key_transition(
                                state,
                                &keyboard,
                                input::ShellKeyStroke {
                                    evdev_keycode: keycode,
                                    shift: false,
                                },
                                if pressed {
                                    KeyState::Pressed
                                } else {
                                    KeyState::Released
                                },
                                time,
                            );
                        }
                    }
                    Command::Scroll { dx, dy, stop } => {
                        let pointer_location = frontend.pointer_location;
                        let pointer_grabbed = frontend
                            .seat
                            .get_pointer()
                            .is_some_and(|pointer| pointer.is_grabbed());
                        let client_capture = frontend.client_pointer_capture.is_some();
                        let captured = state.flutter_input.pointer_captured();
                        let flutter_target = !pointer_grabbed
                            && (captured
                                || (!client_capture
                                    && state
                                        .frontend_mut()
                                        .input_route(pointer_location)
                                        .is_none()));
                        state.input_deck.scrolling = !stop;
                        let frontend = state.frontend();
                        let speed = frontend.settings.touchpad().scroll_speed_factor;
                        if flutter_target {
                            state.synchronize_flutter_pointer_position();
                            state.flutter_input.handle_touchpad_pan_sample(
                                Some(if stop { 0.0 } else { dx }),
                                Some(if stop { 0.0 } else { dy }),
                                speed,
                            );
                        } else {
                            let pointer = frontend.seat.get_pointer().expect("seat has no pointer");
                            state.flutter_input.finish_touchpad_pan();
                            let frame = if stop {
                                AxisFrame::new(time)
                                    .source(AxisSource::Finger)
                                    .stop(Axis::Horizontal)
                                    .stop(Axis::Vertical)
                            } else {
                                AxisFrame::new(time)
                                    .source(AxisSource::Finger)
                                    .value(Axis::Horizontal, dx * speed)
                                    .value(Axis::Vertical, dy * speed)
                            };
                            pointer.axis(state, frame);
                            pointer.frame(state);
                        }
                    }
                    _ => unreachable!(),
                }
            }
        }
    }
    // Keep ordinary application windows on desktop outputs, including newly mapped
    // clients. Existing hotplug reconciliation brings them back when undocked.
    if let Some(frontend) = state.wayland.as_ref()
        && let Some(source) = frontend.input_deck_output
        && state.input_deck.last_window_revision != Some(state.scene_sync.metadata_revision())
    {
        let destination = frontend
            .outputs
            .iter()
            .find(|output| output.id != source && output.powered)
            .map(|output| output.id);
        let source_workspace = frontend.active_workspace(source);
        let desktop_workspace = destination
            .map(|output| frontend.active_workspace(output))
            .unwrap_or(source_workspace);
        let windows = frontend
            .window_registry
            .iter()
            .filter_map(|(id, record)| {
                record
                    .workspace
                    .filter(|location| location.output == source)
                    .map(|location| {
                        (
                            id.get(),
                            if location.workspace == source_workspace {
                                desktop_workspace
                            } else {
                                location.workspace
                            },
                        )
                    })
            })
            .collect::<Vec<_>>();
        if let Some(destination) = destination {
            for (window, workspace) in windows {
                super::window_management::move_window_to_workspace(
                    state,
                    window,
                    i64::try_from(destination.0).ok(),
                    workspace,
                    false,
                );
            }
        }
    }
    if let Some(frontend) = state.wayland.as_mut() {
        frontend.display_handle.flush_clients()?;
    }
    state.input_deck.last_window_revision = state
        .wayland
        .as_ref()
        .and_then(|frontend| frontend.input_deck_output)
        .map(|_| state.scene_sync.metadata_revision());
    current = snapshot(state);
    let keyboard = state
        .wayland
        .as_ref()
        .and_then(|frontend| frontend.seat.get_keyboard());
    let signature = current
        .active_output
        .as_ref()
        .and_then(|_| keyboard.as_ref())
        .map(|keyboard| {
            let mods = keyboard.modifier_state().serialized;
            (
                mods.depressed,
                mods.latched,
                mods.locked,
                mods.layout_effective,
                state.frontend().settings.revision(),
            )
        });
    let changed = runtime.input_deck_snapshot.as_ref().is_none_or(|previous| {
        previous.touch_outputs != current.touch_outputs
            || previous.available != current.available
            || previous.active_output != current.active_output
            || previous.locked != current.locked
    });
    if requested || changed || state.input_deck.legend_signature != signature {
        if current.active_output.is_some()
            && let Some(keyboard) = keyboard
        {
            current.key_labels = keyboard.with_xkb_state(state, |context| {
                let xkb = context.xkb().lock().unwrap();
                // SAFETY: the borrowed state does not outlive this XKB mutex guard.
                let xkb_state = unsafe { xkb.state() };
                (2..=53)
                    .chain(std::iter::once(86))
                    .filter_map(|code| {
                        let character = xkb_state
                            .key_get_one_sym(Keycode::new(code + 8))
                            .key_char()?;
                        (!character.is_control() && !character.is_whitespace())
                            .then(|| (code, character.to_string()))
                    })
                    .collect()
            });
        }
        runtime.publish_input_deck(&current)?;
        runtime.input_deck_snapshot = Some(current);
        state.input_deck.legend_signature = signature;
    }
    Ok(())
}
