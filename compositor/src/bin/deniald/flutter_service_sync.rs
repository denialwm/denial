//! Authentication, clipboard, controls, notifications, and software-keyboard synchronization.

use super::*;

pub(super) fn synchronize_authentication_boundary(events: &mut RuntimeState) {
    let locked = events
        .authentication
        .as_ref()
        .is_some_and(|authentication| authentication.locked());
    if locked == events.session_lock_applied {
        return;
    }

    // Balance every client-visible press and cancel every active pointer,
    // touch or keyboard grab before changing the routing boundary. On unlock,
    // this also prevents the Enter used for PAM submission from leaking into
    // the previously focused application.
    wayland_frontend::reset_all_input_devices(events);
    events.session_lock_applied = locked;
    if events
        .wayland
        .as_mut()
        .is_some_and(|frontend| frontend.set_input_method_blocked(locked))
    {
        events.scene_sync.mark_dirty();
    }
    if locked {
        events.pending_shell_actions.clear();
    } else if let Some(authentication) = events.authentication.as_ref() {
        authentication.acknowledge_unlocked_boundary();
    }
    // The security boundary changes routing, not Wayland scene metadata. The
    // input-method branch above dirties the scene when blocking it actually
    // changes a visible popup; forcing an unconditional full scene traversal
    // here would put unrelated synchronous work on the first lock/unlock frame.
    info!(locked, "Denial native session security state changed");
}

#[cfg(feature = "flutter")]
pub(super) fn synchronize_clipboard(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    let locked = events.secure_session_locked();
    events.clipboard.set_locked(locked);
    if locked || !events.clipboard.has_pending_capture() {
        wayland_frontend::cancel_clipboard_captures(events);
    }
    if locked {
        events.clipboard.take_actions();
    } else {
        let actions = events.clipboard.take_actions();
        wayland_frontend::apply_clipboard_actions(events, actions);
    }
    runtime.publish_clipboard_state()
}

#[cfg(feature = "flutter")]
pub(super) fn synchronize_system_control_events(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    let audio_requests = runtime.drain_audio_requests().collect::<Vec<_>>();
    let brightness_requests = runtime.drain_brightness_requests().collect::<Vec<_>>();
    let Some(controls) = events.system_controls.as_ref() else {
        return Ok(());
    };
    if !events.secure_session_locked() {
        for request in audio_requests {
            controls.handle_audio_request(request);
        }
        for request in brightness_requests {
            controls.handle_brightness_request(request);
        }
    }
    while let Some(event) = controls.try_event() {
        runtime.send_system_control_event(&event)?;
    }
    Ok(())
}

#[cfg(feature = "flutter")]
pub(super) fn synchronize_notification_events(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    while let Some(event) = events.pending_notification_events.pop_front() {
        runtime.send_notification_event(&event)?;
    }

    let commands = runtime.drain_notification_commands().collect::<Vec<_>>();
    if events.secure_session_locked() {
        return Ok(());
    }
    let Some(server) = events.notification_server.as_ref() else {
        return Ok(());
    };
    for command in commands {
        let (notification_id, queued) = match command {
            wire::NotificationCommand::Dismiss { notification_id } => {
                (notification_id, server.dismiss(notification_id))
            }
            wire::NotificationCommand::InvokeAction {
                notification_id,
                action_key,
            } => (
                notification_id,
                server.invoke_action(notification_id, action_key),
            ),
            wire::NotificationCommand::InvokeDefault { notification_id } => {
                (notification_id, server.invoke_default(notification_id))
            }
        };
        if !queued {
            warn!(
                notification_id,
                "could not queue Flutter notification command"
            );
        }
    }
    Ok(())
}

#[cfg(feature = "flutter")]
pub(super) fn synchronize_shell_keyboard(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    if let Some((generation, snapshot)) = runtime.take_text_input_state()
        && events
            .wayland
            .as_mut()
            .is_some_and(|frontend| frontend.observe_flutter_text_editor(generation, snapshot))
    {
        events.scene_sync.mark_dirty();
    }

    let input_method_transactions = events
        .wayland
        .as_mut()
        .map(|frontend| {
            frontend
                .drain_flutter_input_method_transactions()
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    if !events.secure_session_locked() {
        for (generation, client_id, transaction) in input_method_transactions {
            if !runtime.dispatch_input_method_to_flutter(generation, client_id, &transaction)? {
                debug!(
                    generation,
                    client_id, "input-method transaction lost its Flutter editor"
                );
            }
        }
    }
    if let Some((generation, snapshot)) = runtime.take_text_input_state()
        && events
            .wayland
            .as_mut()
            .is_some_and(|frontend| frontend.observe_flutter_text_editor(generation, snapshot))
    {
        events.scene_sync.mark_dirty();
    }
    publish_software_keyboard_state(runtime, events)?;
    let commands = runtime.drain_keyboard_commands().collect::<Vec<_>>();
    // The OSK is a virtual keyboard source. Rust converts each intent into
    // complete key transitions and feeds the same focus/XKB/seat-or-Flutter
    // router used by libinput; there is no separate text-delivery path.
    let mut flush_wayland_clients = false;
    for command in commands {
        let delivered = wayland_frontend::dispatch_shell_keyboard(events, &command);
        flush_wayland_clients |= delivered;
        if !delivered {
            warn!(
                ?command,
                "virtual keyboard could not produce this key transition"
            );
        }
    }
    if flush_wayland_clients && let Some(frontend) = events.wayland.as_mut() {
        frontend.display_handle.flush_clients()?;
    }
    Ok(())
}

#[cfg(feature = "flutter")]
pub(super) fn publish_software_keyboard_state(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &RuntimeState,
) -> Result<(), Box<dyn Error>> {
    let keyboard = events
        .wayland
        .as_ref()
        .map(|frontend| frontend.software_keyboard_state())
        .unwrap_or_default();
    runtime.publish_text_input_state(
        keyboard.active,
        keyboard.input_panel_visible,
        keyboard.legacy,
        keyboard.content_hint,
        keyboard.content_purpose,
        keyboard.activation_serial,
    )
}
