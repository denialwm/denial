//! Authentication, clipboard, controls, notifications, and software-keyboard synchronization.

use super::*;
use serde_json::json;

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
    expire_system_control_waits(events);
    let control_requests = events.pending_system_controls.drain(..).collect::<Vec<_>>();
    let Some(controls) = events.system_controls.as_ref() else {
        for request in control_requests {
            let (_, reply) = request.into_parts();
            let _ = reply.send(Err(OutputControlFailure::new(
                "unavailable",
                "native system controls are unavailable",
            )));
        }
        return Ok(());
    };
    if events.secure_session_locked() {
        for request in control_requests {
            let (_, reply) = request.into_parts();
            let _ = reply.send(Err(OutputControlFailure::new(
                "locked",
                "system controls are unavailable while the session is locked",
            )));
        }
    } else {
        for request in audio_requests {
            controls.handle_audio_request(request);
        }
        for request in brightness_requests {
            controls.handle_brightness_request(request);
        }
        for request in control_requests {
            let (command, reply) = request.into_parts();
            let (accepted, wait) = match command {
                SystemControlCommand::Audio(request) => {
                    let wait = match request {
                        system_controls::AudioRequest::ReadLevel => {
                            Some(SystemControlWaitKind::AudioLevel)
                        }
                        system_controls::AudioRequest::RequestStreams => {
                            Some(SystemControlWaitKind::AudioStreams)
                        }
                        system_controls::AudioRequest::SetLevel { .. }
                        | system_controls::AudioRequest::SetStreamLevel { .. } => None,
                    };
                    (controls.handle_audio_request(request), wait)
                }
                SystemControlCommand::Brightness(request) => {
                    let wait = match &request {
                        system_controls::BrightnessRequest::Read { monitor_id, .. } => {
                            Some(SystemControlWaitKind::Brightness(*monitor_id))
                        }
                        system_controls::BrightnessRequest::Set { .. } => None,
                    };
                    (controls.handle_brightness_request(request), wait)
                }
            };
            if !accepted {
                let _ = reply.send(Err(OutputControlFailure::new(
                    "busy",
                    "the native system-control queue is full",
                )));
            } else if let Some(kind) = wait {
                const MAX_PENDING_SYSTEM_CONTROL_WAITS: usize = 64;
                if events.pending_system_control_waits.len() >= MAX_PENDING_SYSTEM_CONTROL_WAITS {
                    let _ = reply.send(Err(OutputControlFailure::new(
                        "busy",
                        "too many system-control reads are pending",
                    )));
                } else {
                    events
                        .pending_system_control_waits
                        .push_back(PendingSystemControlWait::new(kind, reply));
                }
            } else {
                let _ = reply.send(Ok(json!({"accepted": true})));
            }
        }
    }
    let system_updates = std::iter::from_fn(|| controls.try_event()).collect::<Vec<_>>();
    for event in system_updates {
        resolve_system_control_waits(events, &event);
        runtime.send_system_control_event(&event)?;
    }
    Ok(())
}

#[cfg(feature = "flutter")]
fn expire_system_control_waits(events: &mut RuntimeState) {
    let now = Instant::now();
    let pending = events.pending_system_control_waits.len();
    for _ in 0..pending {
        let Some(wait) = events.pending_system_control_waits.pop_front() else {
            break;
        };
        if wait.expired(now) {
            let _ = wait.reply.send(Err(OutputControlFailure::new(
                "timeout",
                "the native system-control worker did not answer in time",
            )));
        } else {
            events.pending_system_control_waits.push_back(wait);
        }
    }
}

#[cfg(feature = "flutter")]
fn resolve_system_control_waits(
    events: &mut RuntimeState,
    update: &system_controls::SystemControlEvent,
) {
    let (kind, result) = match update {
        system_controls::SystemControlEvent::AudioLevel {
            level,
            request_serial,
        } => (
            SystemControlWaitKind::AudioLevel,
            json!({
                "level": level.clamp(0.0, 1.0),
                "request_serial": request_serial,
            }),
        ),
        system_controls::SystemControlEvent::AudioStreams(streams) => (
            SystemControlWaitKind::AudioStreams,
            json!({
                "streams": streams.iter().map(|stream| json!({
                    "id": stream.id,
                    "name": stream.name,
                    "level": f64::from(stream.level_percent.min(100)) / 100.0,
                    "muted": stream.muted,
                })).collect::<Vec<_>>(),
            }),
        ),
        system_controls::SystemControlEvent::BrightnessLevel { monitor_id, level } => (
            SystemControlWaitKind::Brightness(*monitor_id),
            json!({
                "monitor_id": monitor_id,
                "level": level.clamp(0.0, 1.0),
            }),
        ),
    };
    let pending = events.pending_system_control_waits.len();
    for _ in 0..pending {
        let Some(wait) = events.pending_system_control_waits.pop_front() else {
            break;
        };
        if wait.kind == kind {
            let _ = wait.reply.send(Ok(result.clone()));
        } else {
            events.pending_system_control_waits.push_back(wait);
        }
    }
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
pub(super) fn synchronize_xembed_tray(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    if let Some(tray) = events
        .wayland
        .as_ref()
        .and_then(|frontend| frontend.xembed_tray.as_ref())
    {
        while let Some(event) = tray.try_event() {
            if let Err(error) = runtime.send_xembed_tray_event(&event) {
                warn!(
                    %error,
                    window = event.window_id,
                    kind = ?event.kind,
                    "dropping XEmbed tray event that Flutter could not accept"
                );
            }
        }
    }

    let commands = runtime.drain_xembed_tray_commands().collect::<Vec<_>>();
    if events.secure_session_locked() {
        return Ok(());
    }
    let Some(tray) = events
        .wayland
        .as_ref()
        .and_then(|frontend| frontend.xembed_tray.as_ref())
    else {
        return Ok(());
    };
    for command in commands {
        if !tray.invoke(command) {
            warn!(
                window = command.window_id,
                "could not queue Flutter XEmbed tray command"
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
