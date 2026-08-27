//! Shell window state, persistent settings, shortcuts, bars, and output geometry.

use super::*;
use serde_json::json;

pub(super) fn synchronize_flutter_window_management(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    if events.secure_session_locked() {
        events.pending_shell_actions.clear();
        events.pending_shortcut_launches.clear();
        while runtime.take_application_launch().is_some() {}
        runtime.drain_window_commands().for_each(drop);
    } else {
        while let Some(target) = events.pending_shortcut_launches.pop_front() {
            let activation_token = events
                .wayland
                .as_mut()
                .map(wayland_frontend::WaylandFrontend::create_launch_activation_token);
            let result = match target {
                native_shortcut::ShortcutTarget::Spawn {
                    command,
                    desktop_file_id,
                } => runtime.start_shortcut_application(
                    command,
                    false,
                    desktop_file_id.as_deref(),
                    activation_token.as_deref(),
                ),
                native_shortcut::ShortcutTarget::SpawnSh { command } => runtime
                    .start_shortcut_application(
                        vec!["sh".to_owned(), "-c".to_owned(), command],
                        true,
                        None,
                        activation_token.as_deref(),
                    ),
                native_shortcut::ShortcutTarget::DenialAction { .. } => continue,
            };
            if let Err(error) = result {
                warn!(%error, "could not launch command requested by shortcut");
            }
        }
        while let Some(launch) = runtime.take_application_launch() {
            let activation_token = events
                .wayland
                .as_mut()
                .map(wayland_frontend::WaylandFrontend::create_launch_activation_token);
            if let Err(error) = runtime.start_application(launch, activation_token.as_deref()) {
                warn!(%error, "could not launch application requested by Flutter shell");
            }
        }
        while let Some((action, monitor_id)) = events.pending_shell_actions.pop_front() {
            runtime.send_shell_action(action, monitor_id)?;
        }
        let commands = runtime.drain_window_commands().collect::<Vec<_>>();
        let mut wayland_commands = Vec::with_capacity(commands.len());
        for command in commands {
            let native_owned = command.window_id().is_some_and(|window_id| {
                events
                    .native_app_plugins
                    .as_ref()
                    .is_some_and(|manager| manager.owns_window(window_id))
            });
            if native_owned {
                if let Some(manager) = events.native_app_plugins.as_mut()
                    && let Err(error) = manager.apply_window_command(&command)
                {
                    warn!(%error, "native application plugin window command failed");
                }
            } else {
                if matches!(command, wire::WindowCommand::Focus { .. })
                    && let Some(manager) = events.native_app_plugins.as_mut()
                    && let Err(error) = manager.clear_focus()
                {
                    warn!(%error, "could not clear native application focus");
                }
                wayland_commands.push(command);
            }
        }
        wayland_frontend::apply_window_commands(events, wayland_commands);
    }
    if events.pending_window_events.is_empty() {
        return Ok(());
    }
    let mut pending = events.pending_window_events.drain_events();
    for event in pending.drain(..) {
        if event.is_activation() {
            // Native focus is last-writer-wins. An activation waiting for an
            // older, bufferless window must not fire after focus moved away.
            events
                .pending_unpublished_window_events
                .remove_activations();
        }
        if events.published_window_ids.contains(&event.window_id()) {
            send_flutter_window_event(runtime, event)?;
        } else {
            events.pending_unpublished_window_events.push(event);
        }
    }
    events.pending_window_events.recycle_drained(pending);
    Ok(())
}

#[cfg(feature = "flutter")]
pub(super) fn synchronize_settings(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    if let Some(accent) = runtime.take_theme_accent() {
        events.resolved_theme_accent = DesktopAccentColor::from_srgb24(accent);
    }
    synchronize_control_settings(runtime, events)?;
    let commands = runtime.drain_settings_commands().collect::<Vec<_>>();
    for command in commands {
        match command {
            wire::SettingsCommand::ReadDocument { request_id } => {
                let (revision, document) = {
                    let settings = &events
                        .wayland
                        .as_ref()
                        .ok_or("settings request has no Wayland frontend")?
                        .settings;
                    (settings.revision(), settings.document_json())
                };
                match document {
                    Ok(document) => runtime.send_settings_document_response(
                        request_id,
                        revision,
                        Some(&document),
                        None,
                    )?,
                    Err(error) => runtime.send_settings_document_response(
                        request_id,
                        revision,
                        None,
                        Some(&error.to_string()),
                    )?,
                }
            }
            wire::SettingsCommand::WriteDocument {
                request_id,
                expected_revision,
                document,
            } => {
                let result = {
                    let frontend = events
                        .wayland
                        .as_mut()
                        .ok_or("settings request has no Wayland frontend")?;
                    frontend
                        .settings
                        .prepare_shell_update(expected_revision, &document)
                        .and_then(|prepared| frontend.settings.commit(prepared))
                };
                let (revision, document) = {
                    let frontend = events.wayland.as_mut().expect("missing Wayland frontend");
                    if result.is_ok() {
                        // The native-owned values are unchanged, but their
                        // revision token advanced with the shared document.
                        frontend.keyboard_configuration_changed = true;
                    }
                    (
                        frontend.settings.revision(),
                        result
                            .as_ref()
                            .ok()
                            .and_then(|()| frontend.settings.document_json().ok()),
                    )
                };
                runtime.send_settings_document_response(
                    request_id,
                    revision,
                    document.as_deref(),
                    result
                        .as_ref()
                        .err()
                        .map(|error| error.to_string())
                        .as_deref(),
                )?;
                if result.is_ok() {
                    events.input_device_capabilities_changed = true;
                }
            }
            wire::SettingsCommand::ReadKeyboard { request_id } => {
                send_keyboard_settings(runtime, events, request_id, None)?;
                if let Some(frontend) = events.wayland.as_mut() {
                    frontend.keyboard_configuration_changed = false;
                }
            }
            wire::SettingsCommand::ReadInputDevices { request_id } => {
                send_input_device_settings(runtime, events, request_id, None)?;
                events.input_device_capabilities_changed = false;
            }
            wire::SettingsCommand::ConfigureKeyboard {
                request_id,
                expected_revision,
                keyboard,
            } => {
                let prepared = events
                    .wayland
                    .as_ref()
                    .ok_or("settings request has no Wayland frontend")?
                    .settings
                    .prepare_keyboard_update(expected_revision, keyboard);
                let result = match prepared {
                    Ok(prepared) => {
                        let previous = events
                            .wayland
                            .as_ref()
                            .expect("missing Wayland frontend")
                            .settings
                            .keyboard()
                            .clone();
                        let next = prepared.keyboard().clone();
                        match wayland_frontend::install_keyboard_settings(events, &next) {
                            Ok(_) => {
                                let commit = events
                                    .wayland
                                    .as_mut()
                                    .expect("missing Wayland frontend")
                                    .settings
                                    .commit(prepared);
                                if let Err(error) = commit {
                                    if let Err(rollback_error) =
                                        wayland_frontend::install_keyboard_settings(
                                            events, &previous,
                                        )
                                    {
                                        return Err(format!(
                                            "keyboard settings commit failed ({error}) and the live keymap rollback failed ({rollback_error})"
                                        )
                                        .into());
                                    }
                                    Err(error)
                                } else {
                                    info!(
                                        revision = events
                                            .wayland
                                            .as_ref()
                                            .expect("missing Wayland frontend")
                                            .settings
                                            .revision(),
                                        layouts = next.layouts.len(),
                                        repeat_rate_hz = next.repeat_rate_hz,
                                        repeat_delay_ms = next.repeat_delay_ms,
                                        "applied persistent keyboard settings"
                                    );
                                    Ok(())
                                }
                            }
                            Err(error) => {
                                warn!(%error, "rejected keyboard configuration after XKB preflight");
                                // Convert the late Smithay error into the same
                                // bounded user-facing response as persistence
                                // failures.
                                send_keyboard_settings(
                                    runtime,
                                    events,
                                    request_id,
                                    Some(&error.to_string()),
                                )?;
                                continue;
                            }
                        }
                    }
                    Err(error) => Err(error),
                };
                send_keyboard_settings(
                    runtime,
                    events,
                    request_id,
                    result
                        .as_ref()
                        .err()
                        .map(|error| error.to_string())
                        .as_deref(),
                )?;
                if result.is_ok() {
                    events.input_device_capabilities_changed = true;
                }
            }
            wire::SettingsCommand::ConfigureTouchpad {
                request_id,
                expected_revision,
                touchpad,
            } => {
                let prepared = events
                    .wayland
                    .as_ref()
                    .ok_or("touchpad update has no Wayland frontend")?
                    .settings
                    .prepare_touchpad_update(expected_revision, touchpad);
                let result = match prepared {
                    Ok(prepared) => {
                        let previous = events
                            .wayland
                            .as_ref()
                            .expect("missing Wayland frontend")
                            .settings
                            .touchpad()
                            .clone();
                        let next = prepared.touchpad().clone();
                        match wayland_frontend::install_touchpad_settings(events, &next) {
                            Ok(()) => {
                                let commit = events
                                    .wayland
                                    .as_mut()
                                    .expect("missing Wayland frontend")
                                    .settings
                                    .commit(prepared);
                                if let Err(error) = commit {
                                    if let Err(rollback_error) =
                                        wayland_frontend::install_touchpad_settings(
                                            events, &previous,
                                        )
                                    {
                                        return Err(format!(
                                            "touchpad settings commit failed ({error}) and the live configuration rollback failed ({rollback_error})"
                                        )
                                        .into());
                                    }
                                    Err(error)
                                } else {
                                    info!(
                                        revision = events
                                            .wayland
                                            .as_ref()
                                            .expect("missing Wayland frontend")
                                            .settings
                                            .revision(),
                                        tap_to_click = next.tap_to_click_enabled,
                                        natural_scroll = next.natural_scroll_enabled,
                                        scroll_speed_factor = next.scroll_speed_factor,
                                        "applied persistent touchpad settings"
                                    );
                                    Ok(())
                                }
                            }
                            Err(error) => {
                                if let Err(rollback_error) =
                                    wayland_frontend::install_touchpad_settings(events, &previous)
                                {
                                    return Err(format!(
                                        "touchpad configuration failed ({error}) and the live configuration rollback failed ({rollback_error})"
                                    )
                                    .into());
                                }
                                send_input_device_settings(
                                    runtime,
                                    events,
                                    request_id,
                                    Some(&error),
                                )?;
                                continue;
                            }
                        }
                    }
                    Err(error) => Err(error),
                };
                send_input_device_settings(
                    runtime,
                    events,
                    request_id,
                    result
                        .as_ref()
                        .err()
                        .map(|error| error.to_string())
                        .as_deref(),
                )?;
                if result.is_ok()
                    && let Some(frontend) = events.wayland.as_mut()
                {
                    frontend.keyboard_configuration_changed = true;
                }
            }
            wire::SettingsCommand::ReadShortcuts { request_id } => {
                send_shortcut_settings(runtime, events, request_id, None)?;
            }
            wire::SettingsCommand::ValidateShortcut {
                request_id,
                shortcut,
                existing_shortcut,
            } => {
                let (revision, validation) = {
                    let manager = &events
                        .wayland
                        .as_ref()
                        .ok_or("shortcut validation has no Wayland frontend")?
                        .shortcuts;
                    (
                        manager.revision(),
                        manager.validate_shortcut(&shortcut, existing_shortcut.as_deref()),
                    )
                };
                runtime.send_shortcut_validation_response(request_id, revision, &validation)?;
            }
            wire::SettingsCommand::AddShortcut {
                request_id,
                expected_revision,
                shortcut,
            } => {
                let prepared = events
                    .wayland
                    .as_ref()
                    .ok_or("shortcut update has no Wayland frontend")?
                    .shortcuts
                    .prepare_add(expected_revision, shortcut);
                apply_shortcut_update(runtime, events, request_id, prepared)?;
            }
            wire::SettingsCommand::UpdateShortcut {
                request_id,
                expected_revision,
                existing_shortcut,
                shortcut,
            } => {
                let prepared = events
                    .wayland
                    .as_ref()
                    .ok_or("shortcut update has no Wayland frontend")?
                    .shortcuts
                    .prepare_update(expected_revision, &existing_shortcut, shortcut);
                apply_shortcut_update(runtime, events, request_id, prepared)?;
            }
            wire::SettingsCommand::RemoveShortcut {
                request_id,
                expected_revision,
                shortcut,
            } => {
                let prepared = events
                    .wayland
                    .as_ref()
                    .ok_or("shortcut removal has no Wayland frontend")?
                    .shortcuts
                    .prepare_remove(expected_revision, &shortcut);
                apply_shortcut_update(runtime, events, request_id, prepared)?;
            }
            wire::SettingsCommand::RestoreShortcuts {
                request_id,
                expected_revision,
            } => {
                let prepared = events
                    .wayland
                    .as_ref()
                    .ok_or("shortcut restore has no Wayland frontend")?
                    .shortcuts
                    .prepare_restore(expected_revision);
                apply_shortcut_update(runtime, events, request_id, prepared)?;
            }
        }
    }

    let changed = events
        .wayland
        .as_mut()
        .is_some_and(|frontend| std::mem::take(&mut frontend.keyboard_configuration_changed));
    if changed {
        send_keyboard_settings(runtime, events, 0, None)?;
    }
    if std::mem::take(&mut events.input_device_capabilities_changed) {
        send_input_device_settings(runtime, events, 0, None)?;
    }
    publish_settings_document(events)?;
    synchronize_committed_theme(runtime, events)?;
    Ok(())
}

#[cfg(feature = "flutter")]
fn publish_settings_document(events: &mut RuntimeState) -> Result<(), Box<dyn Error>> {
    let (Some(publisher), Some(frontend)) =
        (events.output_control.as_ref(), events.wayland.as_ref())
    else {
        return Ok(());
    };
    let revision = frontend.settings.revision();
    if events.published_settings_document_revision == Some(revision) {
        return Ok(());
    }
    if publisher.publish_settings_document(revision, frontend.settings.document_json()?) {
        events.published_settings_document_revision = Some(revision);
    }
    Ok(())
}

#[cfg(feature = "flutter")]
fn synchronize_committed_theme(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    let Some(snapshot) = events.wayland.as_ref().map(|frontend| {
        frontend
            .settings
            .theme_snapshot()
            .with_accent(events.resolved_theme_accent)
    }) else {
        return Ok(());
    };
    if events.published_theme_snapshot == Some(snapshot) {
        return Ok(());
    }
    if let Some(publisher) = events.portal_ipc.as_ref() {
        publisher.publish(snapshot);
    }
    if events
        .published_theme_snapshot
        .is_none_or(|previous| previous.effective_brightness != snapshot.effective_brightness)
    {
        runtime.send_platform_brightness(snapshot.effective_brightness)?;
    }
    events.published_theme_snapshot = Some(snapshot);
    Ok(())
}

#[cfg(feature = "flutter")]
fn synchronize_control_settings(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    while let Some(request) = events.pending_settings_controls.pop_front() {
        let (command, reply) = request.into_parts();
        let result = match command {
            SettingsControlCommand::ReadDocument => {
                let result = events
                    .wayland
                    .as_ref()
                    .ok_or_else(|| {
                        OutputControlFailure::new(
                            "unavailable",
                            "settings request has no Wayland frontend",
                        )
                    })
                    .and_then(|frontend| {
                        frontend
                            .settings
                            .document_json()
                            .map(|document| {
                                json!({
                                    "revision": frontend.settings.revision(),
                                    "document": document,
                                })
                            })
                            .map_err(|error| OutputControlFailure::new("failed", error.to_string()))
                    });
                result
            }
            SettingsControlCommand::WriteDocument {
                expected_revision,
                document,
            } => {
                let result = events
                    .wayland
                    .as_mut()
                    .ok_or_else(|| {
                        OutputControlFailure::new(
                            "unavailable",
                            "settings request has no Wayland frontend",
                        )
                    })
                    .and_then(|frontend| {
                        frontend
                            .settings
                            .prepare_shell_update(expected_revision, &document)
                            .and_then(|prepared| frontend.settings.commit(prepared))
                            .map_err(|error| {
                                OutputControlFailure::new("conflict", error.to_string())
                            })?;
                        frontend.keyboard_configuration_changed = true;
                        frontend
                            .settings
                            .document_json()
                            .map(|document| (frontend.settings.revision(), document))
                            .map_err(|error| OutputControlFailure::new("failed", error.to_string()))
                    });
                match result {
                    Ok((revision, document)) => {
                        events.input_device_capabilities_changed = true;
                        if let Err(error) = runtime.send_settings_document_response(
                            0,
                            revision,
                            Some(&document),
                            None,
                        ) {
                            warn!(%error, "could not notify the embedded shell of a settings update");
                        }
                        Ok(json!({
                            "revision": revision,
                            "document": document,
                        }))
                    }
                    Err(error) => Err(error),
                }
            }
            SettingsControlCommand::ReadKeyboard => control_keyboard_snapshot(events),
            SettingsControlCommand::WriteKeyboard {
                expected_revision,
                keyboard,
            } => apply_control_keyboard(events, expected_revision, keyboard),
            SettingsControlCommand::ReadInputDevices => control_input_snapshot(events),
            SettingsControlCommand::WriteTouchpad {
                expected_revision,
                touchpad,
            } => apply_control_touchpad(events, expected_revision, touchpad),
            SettingsControlCommand::ReadShortcuts => control_shortcut_snapshot(events),
            SettingsControlCommand::ValidateShortcut {
                shortcut,
                existing_shortcut,
            } => control_shortcut_validation(events, &shortcut, existing_shortcut.as_deref()),
            SettingsControlCommand::AddShortcut {
                expected_revision,
                shortcut,
            } => match events.wayland.as_ref() {
                Some(frontend) => {
                    let prepared = frontend.shortcuts.prepare_add(expected_revision, shortcut);
                    apply_control_shortcut_update(events, prepared)
                }
                None => Err(control_unavailable("shortcut update")),
            },
            SettingsControlCommand::UpdateShortcut {
                expected_revision,
                existing_shortcut,
                shortcut,
            } => match events.wayland.as_ref() {
                Some(frontend) => {
                    let prepared = frontend.shortcuts.prepare_update(
                        expected_revision,
                        &existing_shortcut,
                        shortcut,
                    );
                    apply_control_shortcut_update(events, prepared)
                }
                None => Err(control_unavailable("shortcut update")),
            },
            SettingsControlCommand::RemoveShortcut {
                expected_revision,
                shortcut,
            } => match events.wayland.as_ref() {
                Some(frontend) => {
                    let prepared = frontend
                        .shortcuts
                        .prepare_remove(expected_revision, &shortcut);
                    apply_control_shortcut_update(events, prepared)
                }
                None => Err(control_unavailable("shortcut removal")),
            },
            SettingsControlCommand::RestoreShortcuts { expected_revision } => {
                match events.wayland.as_ref() {
                    Some(frontend) => {
                        let prepared = frontend.shortcuts.prepare_restore(expected_revision);
                        apply_control_shortcut_update(events, prepared)
                    }
                    None => Err(control_unavailable("shortcut restore")),
                }
            }
        };
        let _ = reply.send(result);
    }
    Ok(())
}

#[cfg(feature = "flutter")]
fn control_unavailable(operation: &str) -> OutputControlFailure {
    OutputControlFailure::new(
        "unavailable",
        format!("{operation} has no Wayland frontend"),
    )
}

#[cfg(feature = "flutter")]
fn control_failed(error: impl std::fmt::Display) -> OutputControlFailure {
    OutputControlFailure::new("failed", error.to_string())
}

#[cfg(feature = "flutter")]
fn control_conflict(error: impl std::fmt::Display) -> OutputControlFailure {
    OutputControlFailure::new("conflict", error.to_string())
}

#[cfg(feature = "flutter")]
fn control_keyboard_snapshot(
    events: &RuntimeState,
) -> Result<serde_json::Value, OutputControlFailure> {
    let frontend = events
        .wayland
        .as_ref()
        .ok_or_else(|| control_unavailable("keyboard settings"))?;
    let keyboard = frontend.settings.keyboard();
    Ok(json!({
        "revision": frontend.settings.revision(),
        "layouts": keyboard.layouts.iter().enumerate().map(|(index, layout)| json!({
            "layout": layout.layout,
            "variant": layout.variant,
            "display_name": frontend.keyboard_layout_names.get(index).cloned().unwrap_or_default(),
        })).collect::<Vec<_>>(),
        "options": keyboard.options,
        "repeat_delay_ms": keyboard.repeat_delay_ms,
        "repeat_rate_hz": keyboard.repeat_rate_hz,
        "active_layout": frontend.active_keyboard_layout,
    }))
}

#[cfg(feature = "flutter")]
fn control_input_snapshot(
    events: &RuntimeState,
) -> Result<serde_json::Value, OutputControlFailure> {
    let frontend = events
        .wayland
        .as_ref()
        .ok_or_else(|| control_unavailable("input settings"))?;
    let touchpad = frontend.settings.touchpad();
    Ok(json!({
        "revision": frontend.settings.revision(),
        "has_touchpad": !events.touchpad_devices.is_empty(),
        "tap_to_click_enabled": touchpad.tap_to_click_enabled,
        "natural_scroll_enabled": touchpad.natural_scroll_enabled,
        "scroll_speed_factor": touchpad.scroll_speed_factor,
    }))
}

#[cfg(feature = "flutter")]
fn apply_control_keyboard(
    events: &mut RuntimeState,
    expected_revision: u64,
    keyboard: settings::KeyboardSettings,
) -> Result<serde_json::Value, OutputControlFailure> {
    let prepared = events
        .wayland
        .as_ref()
        .ok_or_else(|| control_unavailable("keyboard update"))?
        .settings
        .prepare_keyboard_update(expected_revision, keyboard)
        .map_err(control_conflict)?;
    let previous = events
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .settings
        .keyboard()
        .clone();
    let next = prepared.keyboard().clone();
    wayland_frontend::install_keyboard_settings(events, &next).map_err(control_failed)?;
    if let Err(error) = events
        .wayland
        .as_mut()
        .expect("missing Wayland frontend")
        .settings
        .commit(prepared)
    {
        wayland_frontend::install_keyboard_settings(events, &previous).map_err(control_failed)?;
        return Err(control_failed(error));
    }
    events.input_device_capabilities_changed = true;
    control_keyboard_snapshot(events)
}

#[cfg(feature = "flutter")]
fn apply_control_touchpad(
    events: &mut RuntimeState,
    expected_revision: u64,
    touchpad: settings::TouchpadSettings,
) -> Result<serde_json::Value, OutputControlFailure> {
    let prepared = events
        .wayland
        .as_ref()
        .ok_or_else(|| control_unavailable("touchpad update"))?
        .settings
        .prepare_touchpad_update(expected_revision, touchpad)
        .map_err(control_conflict)?;
    let previous = events
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .settings
        .touchpad()
        .clone();
    let next = prepared.touchpad().clone();
    wayland_frontend::install_touchpad_settings(events, &next).map_err(control_failed)?;
    if let Err(error) = events
        .wayland
        .as_mut()
        .expect("missing Wayland frontend")
        .settings
        .commit(prepared)
    {
        wayland_frontend::install_touchpad_settings(events, &previous).map_err(control_failed)?;
        return Err(control_failed(error));
    }
    if let Some(frontend) = events.wayland.as_mut() {
        frontend.keyboard_configuration_changed = true;
    }
    control_input_snapshot(events)
}

#[cfg(feature = "flutter")]
fn control_shortcut_snapshot(
    events: &RuntimeState,
) -> Result<serde_json::Value, OutputControlFailure> {
    let manager = &events
        .wayland
        .as_ref()
        .ok_or_else(|| control_unavailable("shortcut settings"))?
        .shortcuts;
    let inputs = native_shortcut::supported_inputs();
    Ok(json!({
        "revision": manager.revision(),
        "shortcuts": manager.file().shortcuts,
        "supported_actions": native_shortcut::ShortcutAction::ALL,
        "supported_inputs": inputs.into_iter().map(|input| json!({
            "canonical": input.canonical,
            "kind": shortcut_input_kind_name(input.kind),
            "category": shortcut_input_category_name(input.category),
            "aliases": input.aliases,
        })).collect::<Vec<_>>(),
    }))
}

#[cfg(feature = "flutter")]
fn control_shortcut_validation(
    events: &RuntimeState,
    shortcut: &native_shortcut::ShortcutBinding,
    existing_shortcut: Option<&str>,
) -> Result<serde_json::Value, OutputControlFailure> {
    let manager = &events
        .wayland
        .as_ref()
        .ok_or_else(|| control_unavailable("shortcut validation"))?
        .shortcuts;
    let revision = manager.revision();
    Ok(
        match manager.validate_shortcut(shortcut, existing_shortcut) {
            native_shortcut::ShortcutValidation::Valid { canonical } => json!({
                "revision": revision,
                "kind": "valid",
                "canonical": canonical,
            }),
            native_shortcut::ShortcutValidation::Conflict { canonical, binding } => json!({
                "revision": revision,
                "kind": "conflict",
                "canonical": canonical,
                "conflict": binding,
            }),
            native_shortcut::ShortcutValidation::Invalid { error } => json!({
                "revision": revision,
                "kind": "invalid",
                "error": error,
            }),
        },
    )
}

#[cfg(feature = "flutter")]
fn apply_control_shortcut_update(
    events: &mut RuntimeState,
    prepared: Result<native_shortcut::PreparedShortcutUpdate, native_shortcut::ShortcutError>,
) -> Result<serde_json::Value, OutputControlFailure> {
    let mut prepared = prepared.map_err(control_conflict)?;
    let candidate_engine = prepared.take_engine();
    let previous_engine = std::mem::replace(&mut events.native_escape_shortcut, candidate_engine);
    if let Err(error) = events
        .wayland
        .as_mut()
        .ok_or_else(|| control_unavailable("shortcut update"))?
        .shortcuts
        .commit(prepared)
    {
        events.native_escape_shortcut = previous_engine;
        return Err(control_failed(error));
    }
    control_shortcut_snapshot(events)
}

#[cfg(feature = "flutter")]
const fn shortcut_input_kind_name(kind: native_shortcut::ShortcutInputKind) -> &'static str {
    match kind {
        native_shortcut::ShortcutInputKind::Key => "key",
        native_shortcut::ShortcutInputKind::Gesture => "gesture",
    }
}

#[cfg(feature = "flutter")]
const fn shortcut_input_category_name(
    category: native_shortcut::ShortcutInputCategory,
) -> &'static str {
    match category {
        native_shortcut::ShortcutInputCategory::Modifier => "modifier",
        native_shortcut::ShortcutInputCategory::Navigation => "navigation",
        native_shortcut::ShortcutInputCategory::Editing => "editing",
        native_shortcut::ShortcutInputCategory::Punctuation => "punctuation",
        native_shortcut::ShortcutInputCategory::Function => "function",
        native_shortcut::ShortcutInputCategory::Media => "media",
        native_shortcut::ShortcutInputCategory::Hardware => "hardware",
        native_shortcut::ShortcutInputCategory::Special => "special",
        native_shortcut::ShortcutInputCategory::Gesture => "gesture",
    }
}

#[cfg(feature = "flutter")]
pub(super) fn apply_shortcut_update(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
    request_id: u64,
    prepared: Result<native_shortcut::PreparedShortcutUpdate, native_shortcut::ShortcutError>,
) -> Result<(), Box<dyn Error>> {
    let result = match prepared {
        Ok(mut prepared) => {
            let candidate_engine = prepared.take_engine();
            let previous_engine =
                std::mem::replace(&mut events.native_escape_shortcut, candidate_engine);
            let result = events
                .wayland
                .as_mut()
                .ok_or("shortcut commit has no Wayland frontend")?
                .shortcuts
                .commit(prepared);
            if result.is_err() {
                events.native_escape_shortcut = previous_engine;
            } else {
                info!(
                    revision = events
                        .wayland
                        .as_ref()
                        .expect("missing Wayland frontend")
                        .shortcuts
                        .revision(),
                    "applied persistent shortcut configuration"
                );
            }
            result
        }
        Err(error) => Err(error),
    };
    send_shortcut_settings(
        runtime,
        events,
        request_id,
        result
            .as_ref()
            .err()
            .map(|error| error.to_string())
            .as_deref(),
    )
}

#[cfg(feature = "flutter")]
pub(super) fn send_shortcut_settings(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &RuntimeState,
    request_id: u64,
    error: Option<&str>,
) -> Result<(), Box<dyn Error>> {
    let manager = &events
        .wayland
        .as_ref()
        .ok_or("shortcut response has no Wayland frontend")?
        .shortcuts;
    let supported_inputs = native_shortcut::supported_inputs();
    runtime.send_shortcut_configuration_response(
        request_id,
        manager.revision(),
        &manager.file().shortcuts,
        &supported_inputs,
        error,
    )
}

#[cfg(feature = "flutter")]
pub(super) fn send_keyboard_settings(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &RuntimeState,
    request_id: u64,
    error: Option<&str>,
) -> Result<(), Box<dyn Error>> {
    let frontend = events
        .wayland
        .as_ref()
        .ok_or("keyboard settings response has no Wayland frontend")?;
    runtime.send_keyboard_settings_response(
        request_id,
        frontend.settings.revision(),
        frontend.settings.keyboard(),
        &frontend.keyboard_layout_names,
        frontend.active_keyboard_layout,
        error,
    )
}

#[cfg(feature = "flutter")]
pub(super) fn send_input_device_settings(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &RuntimeState,
    request_id: u64,
    error: Option<&str>,
) -> Result<(), Box<dyn Error>> {
    let frontend = events
        .wayland
        .as_ref()
        .ok_or("touchpad settings response has no Wayland frontend")?;
    runtime.send_input_device_capabilities_response(
        request_id,
        frontend.settings.revision(),
        !events.touchpad_devices.is_empty(),
        frontend.settings.touchpad(),
        error,
    )
}

#[cfg(feature = "flutter")]
pub(super) fn synchronize_system_bar_configuration(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
    flutter_launcher: Option<&mut FlutterLauncher>,
) {
    let Some(work_area) = runtime.take_work_area_update() else {
        return;
    };
    if let Some(frontend) = events.wayland.as_mut() {
        frontend.set_work_area(work_area.clone());
    }
    if let Some(launcher) = flutter_launcher {
        launcher.set_work_area(work_area);
    }
    events.scene_sync.mark_dirty();
}

#[cfg(feature = "flutter")]
pub(super) fn send_flutter_window_event(
    runtime: &mut flutter_runtime::FlutterRuntime,
    event: PendingWindowEvent,
) -> Result<(), Box<dyn Error>> {
    match event {
        PendingWindowEvent::Activated(window_id) => runtime.send_window_activated(window_id),
        PendingWindowEvent::Action(window_id, action) => {
            runtime.send_window_action(window_id, action)
        }
        PendingWindowEvent::Placement(placement) => runtime.send_window_placement(placement),
    }
}

#[cfg(feature = "flutter")]
pub(super) fn apply_automatic_orientation(
    scanouts: &mut [Scanout],
    swapchain: &mut RenderSwapchains,
    topology: &mut TopologyManager,
    configuration: &mut RuntimeOutputConfiguration,
    rotation: OutputTransform,
    events: &mut RuntimeState,
    flutter: &mut flutter_runtime::FlutterRuntime,
) -> Result<(), Box<dyn Error>> {
    let mut staged_configuration = configuration.clone();
    staged_configuration.sensor_rotation = rotation;
    let outputs = scanouts
        .iter()
        .map(|scanout| {
            let mut output = scanout.output.clone();
            output.transform = staged_configuration.effective_transform(&output.name);
            output
        })
        .collect::<Vec<_>>();
    if outputs
        .iter()
        .zip(scanouts.iter())
        .all(|(output, scanout)| output.transform == scanout.output.transform)
    {
        configuration.sensor_rotation = rotation;
        return Ok(());
    }

    apply_resident_output_geometry(
        scanouts,
        swapchain,
        topology,
        configuration,
        outputs,
        staged_configuration,
        flutter_runtime::OutputGeometryTransition::AnimatedRotation,
        events,
        flutter,
    )?;
    info!(
        ?rotation,
        "applied automatic orientation to resident Flutter output pools"
    );
    Ok(())
}

#[cfg(feature = "flutter")]
#[allow(clippy::too_many_arguments)]
pub(super) fn apply_resident_output_geometry(
    scanouts: &mut [Scanout],
    swapchain: &mut RenderSwapchains,
    topology: &mut TopologyManager,
    configuration: &mut RuntimeOutputConfiguration,
    outputs: Vec<ConnectedOutput>,
    staged_configuration: RuntimeOutputConfiguration,
    transition: flutter_runtime::OutputGeometryTransition,
    events: &mut RuntimeState,
    flutter: &mut flutter_runtime::FlutterRuntime,
) -> Result<(), Box<dyn Error>> {
    let previous_snapshot = topology.snapshot();
    let previous_atlas = AtlasPlan::for_snapshot(&previous_snapshot)
        .ok_or("resident output rollback has no previous Flutter desktop geometry")?;
    let mut staged_topology = topology.clone();
    let snapshot =
        update_topology_for_outputs(&mut staged_topology, &outputs, &staged_configuration)?;
    let atlas = AtlasPlan::for_snapshot(&snapshot)
        .ok_or("resident reconfiguration produced no Flutter desktop geometry")?;
    let plans = atlas
        .render_outputs(&snapshot)
        .ok_or("resident reconfiguration produced invalid render projections")?;
    let pools = swapchain
        .outputs()
        .ok_or("resident reconfiguration has no physical Flutter output pools")?;
    if plans.len() != pools.outputs.len()
        || plans.iter().any(|plan| {
            pools
                .for_output(plan.output_id)
                .is_none_or(|pool| pool.size != plan.target_size)
        })
    {
        return Err("resident reconfiguration changed a native output target".into());
    }
    let staged_scanouts = scanouts
        .iter()
        .map(|scanout| {
            let output = outputs
                .iter()
                .find(|output| output.id == scanout.output.id)
                .cloned()
                .ok_or("resident reconfiguration omitted a scanout")?;
            let source_rect = atlas
                .outputs
                .iter()
                .find(|planned| planned.id == output.id)
                .map(|planned| planned.source_rect)
                .ok_or("resident reconfiguration omitted an atlas output")?;
            Ok((output, source_rect))
        })
        .collect::<Result<Vec<_>, Box<dyn Error>>>()?;

    if let Some(frontend) = events.wayland.as_mut()
        && let Err(error) = frontend.update_topology(&snapshot)
    {
        if let Err(rollback_error) = frontend.update_topology(&previous_snapshot) {
            return Err(format!(
                "resident Wayland geometry update failed ({error}); rollback failed: {rollback_error}"
            )
            .into());
        }
        return Err(error);
    }
    if let Err(error) = flutter.reconfigure_output_geometry(&snapshot, &atlas, transition) {
        let flutter_rollback = flutter.reconfigure_output_geometry(
            &previous_snapshot,
            &previous_atlas,
            flutter_runtime::OutputGeometryTransition::Immediate,
        );
        let wayland_rollback = events
            .wayland
            .as_mut()
            .map(|frontend| frontend.update_topology(&previous_snapshot))
            .transpose();
        if let Err(rollback_error) = flutter_rollback {
            return Err(format!(
                "resident Flutter geometry update failed ({error}); Flutter rollback failed: {rollback_error}"
            )
            .into());
        }
        if let Err(rollback_error) = wayland_rollback {
            return Err(format!(
                "resident Flutter geometry update failed ({error}); Wayland rollback failed: {rollback_error}"
            )
            .into());
        }
        return Err(error);
    }

    for (scanout, (output, source_rect)) in scanouts.iter_mut().zip(staged_scanouts) {
        scanout.output = output;
        scanout.source_rect = source_rect;
    }
    swapchain.set_desktop_size(atlas.pixel_size)?;
    let animation_started = flutter.output_rotation_animation_active();
    if !animation_started {
        synchronize_resident_flutter_geometry_state(events, &atlas);
    }
    events.output_control_dirty = true;
    *topology = staged_topology;
    *configuration = staged_configuration;
    info!(
        outputs = scanouts.len(),
        width = atlas.pixel_size.width,
        height = atlas.pixel_size.height,
        topology_epoch = atlas.topology_epoch,
        animated = animation_started,
        "updated Flutter output geometry without reallocating native buffers"
    );
    Ok(())
}

#[cfg(feature = "flutter")]
pub(super) fn synchronize_resident_flutter_geometry_state(
    events: &mut RuntimeState,
    atlas: &AtlasPlan,
) {
    events
        .flutter_input
        .resize_preserving_state(atlas.pixel_size);
    events.native_plugin_default_size = (atlas.pixel_size.width, atlas.pixel_size.height);
    events.synchronize_flutter_pointer_position();
    events.scene_sync.mark_dirty();
}
