//! Shell window state, persistent settings, shortcuts, bars, and output geometry.

use super::*;

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
                native_shortcut::ShortcutTarget::Spawn { command } => {
                    runtime.start_shortcut_application(command, false, activation_token.as_deref())
                }
                native_shortcut::ShortcutTarget::SpawnSh { command } => runtime
                    .start_shortcut_application(
                        vec!["sh".to_owned(), "-c".to_owned(), command],
                        true,
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
    Ok(())
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
