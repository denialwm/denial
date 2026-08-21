//! Ordered native-to-Flutter protocol egress.

use super::*;

impl WireBridge {
    /// Replaces display geometry in place and emits an unsolicited layout
    /// response (`request_id == 0`). The Dart bridge treats that form as a
    /// state update, allowing transform-only changes to keep the engine and
    /// physical render-target pools resident.
    pub fn update_topology(
        &mut self,
        snapshot: &TopologySnapshot,
        atlas: &AtlasPlan,
    ) -> Result<&[u8], WireError> {
        validate_topology(snapshot, atlas)?;
        self.snapshot = snapshot.clone();
        self.atlas = atlas.clone();
        let sequence = self.take_sequence();
        self.outbound_builder.reset();
        encode_display_layout(
            &mut self.outbound_builder,
            sequence,
            0,
            &self.snapshot,
            &self.atlas,
            &self.work_area,
        )?;
        Ok(self.outbound_builder.finished_data())
    }

    /// Updates the authoritative snapshot and returns the displaced storage.
    /// The compositor scene builder uses that vector as its next scratch
    /// generation, keeping application-frame-rate metadata off the allocator.
    pub fn update_windows(
        &mut self,
        mut windows: Vec<WindowDescription>,
        restored_window_ids: &BTreeSet<u64>,
    ) -> Result<(Option<&[u8]>, Vec<WindowDescription>), WireError> {
        let next_restored_window_ids = windows
            .iter()
            .filter_map(|window| {
                restored_window_ids
                    .contains(&window.window_id)
                    .then_some(window.window_id)
            })
            .collect::<Vec<_>>();
        // Buffer-only scene revisions usually keep all metadata unchanged.
        // The stored snapshot has already passed validation, so avoid the
        // validator's hash-table work on this application-frame-rate path.
        if self.windows == windows && self.restored_window_ids == next_restored_window_ids {
            return Ok((None, windows));
        }
        validate_windows(&windows)?;
        std::mem::swap(&mut self.windows, &mut windows);
        self.restored_window_ids = next_restored_window_ids;
        let sequence = self.take_sequence();
        self.outbound_builder.reset();
        encode_windows_update(
            &mut self.outbound_builder,
            sequence,
            &self.windows,
            &self.restored_window_ids,
        )?;
        Ok((Some(self.outbound_builder.finished_data()), windows))
    }
    pub fn encode_window_action(
        &mut self,
        window_id: u64,
        action: WindowAction,
    ) -> Result<&[u8], WireError> {
        if window_id == 0 {
            return Err(WireError::Identity);
        }
        let sequence = self.take_sequence();
        self.outbound_builder.reset();
        encode_window_action(&mut self.outbound_builder, sequence, window_id, action)?;
        Ok(self.outbound_builder.finished_data())
    }

    pub fn encode_window_activated(&mut self, window_id: u64) -> Result<&[u8], WireError> {
        if window_id == 0 {
            return Err(WireError::Identity);
        }
        let sequence = self.take_sequence();
        self.outbound_builder.reset();
        encode_window_event(
            &mut self.outbound_builder,
            sequence,
            fb::WindowEventKind::Activated,
            window_id,
            fb::WindowActionKind::Minimize,
        )?;
        Ok(self.outbound_builder.finished_data())
    }

    pub fn encode_window_placement(
        &mut self,
        placement: WindowPlacement,
    ) -> Result<[u8; WINDOW_PLACEMENT_PACKET_BYTES], WireError> {
        if placement.window_id == 0 {
            return Err(WireError::Identity);
        }
        if placement.monitor_id < 0 || placement.workspace_id == -1 {
            return Err(WireError::Topology("invalid window placement ownership"));
        }
        let geometry = placement.geometry;
        if !geometry.x.is_finite()
            || !geometry.y.is_finite()
            || !geometry.width.is_finite()
            || !geometry.height.is_finite()
            || geometry.width < 1.0
            || geometry.height < 1.0
        {
            return Err(WireError::Geometry);
        }
        let sequence = self.take_sequence();
        Ok(encode_window_placement(sequence, placement))
    }

    pub fn encode_shell_action(
        &mut self,
        action: ShellAction,
        monitor_id: Option<i64>,
    ) -> Result<&[u8], WireError> {
        if monitor_id.is_some_and(|monitor_id| monitor_id < 0) {
            return Err(WireError::Topology("invalid shell action monitor"));
        }
        let sequence = self.take_sequence();
        self.outbound_builder.reset();
        encode_shell_action(
            &mut self.outbound_builder,
            sequence,
            action,
            monitor_id,
            0,
            None,
        )?;
        Ok(self.outbound_builder.finished_data())
    }

    pub fn encode_screenshot_action(
        &mut self,
        action: ShellAction,
        request_id: u64,
        texture_id: Option<i64>,
    ) -> Result<&[u8], WireError> {
        let valid_action = matches!(
            action,
            ShellAction::ScreenshotRegion
                | ShellAction::ScreenshotTextureReady
                | ShellAction::ScreenshotDone
        );
        if !valid_action
            || request_id == 0
            || texture_id.is_some_and(|texture_id| texture_id <= 0)
            || (action == ShellAction::ScreenshotTextureReady) != texture_id.is_some()
        {
            return Err(WireError::Identity);
        }
        let sequence = self.take_sequence();
        self.outbound_builder.reset();
        encode_shell_action(
            &mut self.outbound_builder,
            sequence,
            action,
            None,
            request_id,
            texture_id,
        )?;
        Ok(self.outbound_builder.finished_data())
    }

    pub fn encode_cursor_shape(&mut self, shape: &str) -> Result<&[u8], WireError> {
        let shape = shape.trim();
        if shape.is_empty() || shape.len() > MAX_STRING_BYTES {
            return Err(WireError::String);
        }
        let sequence = self.take_sequence();
        self.outbound_builder.reset();
        encode_cursor_shape(&mut self.outbound_builder, sequence, shape)?;
        Ok(self.outbound_builder.finished_data())
    }

    pub fn encode_cursor_position(&mut self, x: f64, y: f64) -> Result<&[u8], WireError> {
        if !x.is_finite() || !y.is_finite() {
            return Err(WireError::Geometry);
        }
        let sequence = self.take_sequence();
        self.outbound_builder.reset();
        encode_cursor_position(&mut self.outbound_builder, sequence, x, y)?;
        Ok(self.outbound_builder.finished_data())
    }

    pub fn encode_text_input_state(
        &mut self,
        active: bool,
        input_panel_visible: bool,
        legacy: bool,
        content_hint: u32,
        content_purpose: u32,
    ) -> Result<&[u8], WireError> {
        if input_panel_visible && !active {
            return Err(WireError::Payload);
        }
        let sequence = self.take_sequence();
        self.outbound_builder.reset();
        encode_text_input_state(
            &mut self.outbound_builder,
            sequence,
            active,
            input_panel_visible,
            legacy,
            content_hint,
            content_purpose,
        )?;
        Ok(self.outbound_builder.finished_data())
    }

    pub fn encode_notification_event(
        &mut self,
        event: &NotificationEvent,
    ) -> Result<&[u8], WireError> {
        validate_notification_event(event)?;
        let sequence = self.take_sequence();
        self.outbound_builder.reset();
        encode_notification_event(&mut self.outbound_builder, sequence, event)?;
        Ok(self.outbound_builder.finished_data())
    }

    pub fn encode_xembed_tray_event(
        &mut self,
        event: &XEmbedTrayEvent,
    ) -> Result<&[u8], WireError> {
        if event.window_id == 0
            || event.icon.as_ref().is_some_and(|icon| {
                icon.window_id != event.window_id
                    || icon.title.len() > MAX_STRING_BYTES
                    || icon.width == 0
                    || icon.height == 0
                    || icon.width > 512
                    || icon.height > 512
                    || icon.rgba.len()
                        != (icon.width as usize)
                            .saturating_mul(icon.height as usize)
                            .saturating_mul(4)
                    || icon.rgba.len() > 512 * 1024
            })
            || (event.kind == XEmbedTrayEventKind::Removed) != event.icon.is_none()
        {
            return Err(WireError::Payload);
        }
        let sequence = self.take_sequence();
        self.outbound_builder.reset();
        encode_xembed_tray_event(&mut self.outbound_builder, sequence, event)?;
        Ok(self.outbound_builder.finished_data())
    }

    pub fn encode_settings_document_response(
        &mut self,
        request_id: u64,
        revision: u64,
        document: Option<&str>,
        error: Option<&str>,
    ) -> Result<&[u8], WireError> {
        if request_id == 0 || revision == 0 {
            return Err(WireError::RequestId);
        }
        if document.is_some_and(|document| document.len() > MAX_SETTINGS_DOCUMENT_BYTES)
            || error.is_some_and(|error| error.len() > MAX_STRING_BYTES)
        {
            return Err(WireError::Size(
                document.map_or_else(|| error.map_or(0, str::len), str::len),
            ));
        }
        let sequence = self.take_sequence();
        self.outbound_builder.reset();
        encode_settings_response(
            &mut self.outbound_builder,
            sequence,
            request_id,
            fb::SettingsResponseKind::Document,
            revision,
            document,
            None,
            &[],
            0,
            None,
            None,
            error,
        )?;
        Ok(self.outbound_builder.finished_data())
    }

    pub fn encode_input_device_capabilities_response(
        &mut self,
        request_id: u64,
        revision: u64,
        has_touchpad: bool,
        touchpad: &TouchpadSettings,
        error: Option<&str>,
    ) -> Result<&[u8], WireError> {
        if revision == 0 || error.is_some_and(|error| error.len() > MAX_STRING_BYTES) {
            return Err(WireError::Identity);
        }
        let sequence = self.take_sequence();
        self.outbound_builder.reset();
        let touchpad = fb::TouchpadConfiguration::create(
            &mut self.outbound_builder,
            &fb::TouchpadConfigurationArgs {
                tap_to_click_enabled: touchpad.tap_to_click_enabled,
                natural_scroll_enabled: touchpad.natural_scroll_enabled,
                scroll_speed_factor: touchpad.scroll_speed_factor,
            },
        );
        let input_devices = fb::InputDeviceCapabilities::create(
            &mut self.outbound_builder,
            &fb::InputDeviceCapabilitiesArgs {
                has_touchpad,
                touchpad: Some(touchpad),
            },
        );
        let error = error.map(|error| self.outbound_builder.create_string(error));
        let response = fb::SettingsResponse::create(
            &mut self.outbound_builder,
            &fb::SettingsResponseArgs {
                kind: fb::SettingsResponseKind::InputDevices,
                success: error.is_none(),
                revision,
                error,
                input_devices: Some(input_devices),
                ..Default::default()
            },
        );
        let envelope = fb::Envelope::create(
            &mut self.outbound_builder,
            &fb::EnvelopeArgs {
                protocol_version: PROTOCOL_VERSION,
                sequence,
                request_id,
                payload_type: fb::Payload::SettingsResponse,
                payload: Some(response.as_union_value()),
            },
        );
        fb::finish_envelope_buffer(&mut self.outbound_builder, envelope);
        validate_finished_message(&self.outbound_builder)?;
        Ok(self.outbound_builder.finished_data())
    }

    #[allow(clippy::too_many_arguments)]
    pub fn encode_keyboard_settings_response(
        &mut self,
        request_id: u64,
        revision: u64,
        keyboard: &KeyboardSettings,
        display_names: &[String],
        active_layout: usize,
        error: Option<&str>,
    ) -> Result<&[u8], WireError> {
        if revision == 0 || active_layout >= keyboard.layouts.len() {
            return Err(WireError::Identity);
        }
        if display_names.len() != keyboard.layouts.len()
            || error.is_some_and(|error| error.len() > MAX_STRING_BYTES)
        {
            return Err(WireError::Count);
        }
        let sequence = self.take_sequence();
        self.outbound_builder.reset();
        encode_settings_response(
            &mut self.outbound_builder,
            sequence,
            request_id,
            fb::SettingsResponseKind::Keyboard,
            revision,
            None,
            Some(keyboard),
            display_names,
            active_layout,
            None,
            None,
            error,
        )?;
        Ok(self.outbound_builder.finished_data())
    }

    pub fn encode_shortcut_configuration_response(
        &mut self,
        request_id: u64,
        revision: u64,
        shortcuts: &[ShortcutBinding],
        supported_inputs: &[ShortcutInputDefinition],
        error: Option<&str>,
    ) -> Result<&[u8], WireError> {
        if request_id == 0 || revision == 0 || shortcuts.len() > MAX_SHORTCUTS {
            return Err(WireError::Identity);
        }
        if supported_inputs.len() > MAX_SHORTCUT_INPUTS
            || error.is_some_and(|error| error.len() > MAX_STRING_BYTES)
        {
            return Err(WireError::Count);
        }
        let sequence = self.take_sequence();
        self.outbound_builder.reset();
        encode_settings_response(
            &mut self.outbound_builder,
            sequence,
            request_id,
            fb::SettingsResponseKind::Shortcuts,
            revision,
            None,
            None,
            &[],
            0,
            Some((shortcuts, supported_inputs)),
            None,
            error,
        )?;
        Ok(self.outbound_builder.finished_data())
    }

    pub fn encode_shortcut_validation_response(
        &mut self,
        request_id: u64,
        revision: u64,
        validation: &ShortcutValidation,
    ) -> Result<&[u8], WireError> {
        if request_id == 0 || revision == 0 {
            return Err(WireError::RequestId);
        }
        let sequence = self.take_sequence();
        self.outbound_builder.reset();
        encode_settings_response(
            &mut self.outbound_builder,
            sequence,
            request_id,
            fb::SettingsResponseKind::ShortcutValidation,
            revision,
            None,
            None,
            &[],
            0,
            None,
            Some(validation),
            None,
        )?;
        Ok(self.outbound_builder.finished_data())
    }
}

fn create_window_snapshot<'a>(
    builder: &mut FlatBufferBuilder<'a>,
    descriptions: &[WindowDescription],
    restored_window_ids: &[u64],
) -> WIPOffset<fb::WindowSnapshot<'a>> {
    let mut windows = Vec::with_capacity(descriptions.len());
    for description in descriptions {
        let mut surface_layers = Vec::with_capacity(description.surfaces.len());
        for surface in &description.surfaces {
            surface_layers.push(fb::SurfaceLayer::create(
                builder,
                &fb::SurfaceLayerArgs {
                    surface_id: surface.surface_id,
                    parent_surface_id: surface.parent_surface_id,
                    popup_root_surface_id: surface.popup_root_surface_id,
                    role: surface.role.wire(),
                    texture_id: surface.texture_id,
                    width: surface.width,
                    height: surface.height,
                    surface_x: surface.surface_x,
                    surface_y: surface.surface_y,
                    surface_width: surface.surface_width,
                    surface_height: surface.surface_height,
                    texture_source_x: surface.texture_source_x,
                    texture_source_y: surface.texture_source_y,
                    texture_source_width: surface.texture_source_width,
                    texture_source_height: surface.texture_source_height,
                    transform: surface.transform,
                    scale_120: surface.scale_120,
                    composition_order: surface.composition_order,
                    opacity: surface.opacity,
                    opaque: surface.opaque,
                },
            ));
        }
        let surface_layers = builder.create_vector(&surface_layers);
        let title = builder.create_string(&description.title);
        let app_id = builder.create_string(&description.app_id);
        windows.push(fb::Window::create(
            builder,
            &fb::WindowArgs {
                object_id: description.object_id,
                object_kind: fb::ObjectKind::RootSurface,
                surface_id: description.surface_id,
                window_id: description.window_id,
                texture_id: description.texture_id,
                title: Some(title),
                app_id: Some(app_id),
                width: description.width,
                height: description.height,
                surface_x: description.surface_x,
                surface_y: description.surface_y,
                surface_width: description.surface_width,
                surface_height: description.surface_height,
                texture_source_x: description.texture_source_x,
                texture_source_y: description.texture_source_y,
                texture_source_width: description.texture_source_width,
                texture_source_height: description.texture_source_height,
                geometry_x: description.geometry_x,
                geometry_y: description.geometry_y,
                geometry_width: description.geometry_width,
                geometry_height: description.geometry_height,
                monitor_id: description.monitor_id,
                transform: description.transform,
                scale_120: description.scale_120,
                content_x: description.content_x,
                content_y: description.content_y,
                content_width: description.content_width,
                content_height: description.content_height,
                surfaces: Some(surface_layers),
                suppress_animations: description.suppress_animations,
                server_side_decorated: description.server_side_decorated,
                opacity: description.opacity,
                content_kind: description.content_kind.wire(),
                opacity_class: description.opacity_class.wire(),
                ..Default::default()
            },
        ));
    }
    let windows = builder.create_vector(&windows);
    let restored_window_ids = builder.create_vector(restored_window_ids);
    fb::WindowSnapshot::create(
        builder,
        &fb::WindowSnapshotArgs {
            windows: Some(windows),
            restored_window_ids: Some(restored_window_ids),
        },
    )
}

pub(super) fn encode_windows_response(
    builder: &mut FlatBufferBuilder<'_>,
    sequence: u64,
    request_id: u64,
    descriptions: &[WindowDescription],
    restored_window_ids: &[u64],
) -> Result<(), WireError> {
    let snapshot = create_window_snapshot(builder, descriptions, restored_window_ids);
    let response = fb::WindowResponse::create(
        builder,
        &fb::WindowResponseArgs {
            kind: fb::WindowResponseKind::Windows,
            success: true,
            windows: Some(snapshot),
            ..Default::default()
        },
    );
    finish_response(builder, sequence, request_id, response)
}

fn encode_windows_update(
    builder: &mut FlatBufferBuilder<'_>,
    sequence: u64,
    descriptions: &[WindowDescription],
    restored_window_ids: &[u64],
) -> Result<(), WireError> {
    let snapshot = create_window_snapshot(builder, descriptions, restored_window_ids);
    let envelope = fb::Envelope::create(
        builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence,
            request_id: 0,
            payload_type: fb::Payload::WindowSnapshot,
            payload: Some(snapshot.as_union_value()),
        },
    );
    fb::finish_envelope_buffer(builder, envelope);
    validate_finished_message(builder)
}

fn encode_window_action(
    builder: &mut FlatBufferBuilder<'_>,
    sequence: u64,
    window_id: u64,
    action: WindowAction,
) -> Result<(), WireError> {
    encode_window_event(
        builder,
        sequence,
        fb::WindowEventKind::Action,
        window_id,
        action.wire(),
    )
}

fn encode_window_placement(
    sequence: u64,
    placement: WindowPlacement,
) -> [u8; WINDOW_PLACEMENT_PACKET_BYTES] {
    let mut bytes = [0; WINDOW_PLACEMENT_PACKET_BYTES];
    bytes[0..4].copy_from_slice(b"DENP");
    bytes[4..6].copy_from_slice(&PROTOCOL_VERSION.to_le_bytes());
    bytes[6..8].copy_from_slice(&2u16.to_le_bytes());
    bytes[8..12].copy_from_slice(&(WINDOW_PLACEMENT_PACKET_BYTES as u32).to_le_bytes());
    bytes[12..20].copy_from_slice(&sequence.to_le_bytes());
    bytes[20..28].copy_from_slice(&placement.window_id.to_le_bytes());
    bytes[28..36].copy_from_slice(&placement.monitor_id.to_le_bytes());
    bytes[36..44].copy_from_slice(&placement.workspace_id.to_le_bytes());
    bytes[44] = placement.phase as u8;
    bytes[45] = placement.change as u8;
    bytes[48..56].copy_from_slice(&placement.geometry.x.to_le_bytes());
    bytes[56..64].copy_from_slice(&placement.geometry.y.to_le_bytes());
    bytes[64..72].copy_from_slice(&placement.geometry.width.to_le_bytes());
    bytes[72..80].copy_from_slice(&placement.geometry.height.to_le_bytes());
    bytes
}

fn encode_window_event(
    builder: &mut FlatBufferBuilder<'_>,
    sequence: u64,
    kind: fb::WindowEventKind,
    window_id: u64,
    action: fb::WindowActionKind,
) -> Result<(), WireError> {
    let event = fb::WindowEvent::create(
        builder,
        &fb::WindowEventArgs {
            kind,
            window_id,
            action,
        },
    );
    let envelope = fb::Envelope::create(
        builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence,
            request_id: 0,
            payload_type: fb::Payload::WindowEvent,
            payload: Some(event.as_union_value()),
        },
    );
    fb::finish_envelope_buffer(builder, envelope);
    validate_finished_message(builder)
}

fn encode_shell_action(
    builder: &mut FlatBufferBuilder<'_>,
    sequence: u64,
    action: ShellAction,
    monitor_id: Option<i64>,
    request_id: u64,
    texture_id: Option<i64>,
) -> Result<(), WireError> {
    let action = fb::ShellAction::create(
        builder,
        &fb::ShellActionArgs {
            action: action.wire(),
            monitor_id: monitor_id.unwrap_or(-1),
            has_monitor_id: monitor_id.is_some(),
            texture_id: texture_id.unwrap_or(0),
        },
    );
    let envelope = fb::Envelope::create(
        builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence,
            request_id,
            payload_type: fb::Payload::ShellAction,
            payload: Some(action.as_union_value()),
        },
    );
    fb::finish_envelope_buffer(builder, envelope);
    validate_finished_message(builder)
}

fn encode_cursor_shape(
    builder: &mut FlatBufferBuilder<'_>,
    sequence: u64,
    shape: &str,
) -> Result<(), WireError> {
    let shape = builder.create_string(shape);
    let cursor = fb::CursorShape::create(builder, &fb::CursorShapeArgs { shape: Some(shape) });
    let envelope = fb::Envelope::create(
        builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence,
            request_id: 0,
            payload_type: fb::Payload::CursorShape,
            payload: Some(cursor.as_union_value()),
        },
    );
    fb::finish_envelope_buffer(builder, envelope);
    validate_finished_message(builder)
}

fn encode_cursor_position(
    builder: &mut FlatBufferBuilder<'_>,
    sequence: u64,
    x: f64,
    y: f64,
) -> Result<(), WireError> {
    let cursor = fb::CursorPosition::create(builder, &fb::CursorPositionArgs { x, y });
    let envelope = fb::Envelope::create(
        builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence,
            request_id: 0,
            payload_type: fb::Payload::CursorPosition,
            payload: Some(cursor.as_union_value()),
        },
    );
    fb::finish_envelope_buffer(builder, envelope);
    validate_finished_message(builder)
}

fn encode_text_input_state(
    builder: &mut FlatBufferBuilder<'_>,
    sequence: u64,
    active: bool,
    input_panel_visible: bool,
    legacy: bool,
    content_hint: u32,
    content_purpose: u32,
) -> Result<(), WireError> {
    let state = fb::TextInputState::create(
        builder,
        &fb::TextInputStateArgs {
            active,
            input_panel_visible,
            legacy,
            content_hint,
            content_purpose,
        },
    );
    let envelope = fb::Envelope::create(
        builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence,
            request_id: 0,
            payload_type: fb::Payload::TextInputState,
            payload: Some(state.as_union_value()),
        },
    );
    fb::finish_envelope_buffer(builder, envelope);
    validate_finished_message(builder)
}

#[allow(clippy::too_many_arguments)]
fn encode_settings_response(
    builder: &mut FlatBufferBuilder<'_>,
    sequence: u64,
    request_id: u64,
    kind: fb::SettingsResponseKind,
    revision: u64,
    document: Option<&str>,
    keyboard: Option<&KeyboardSettings>,
    display_names: &[String],
    active_layout: usize,
    shortcut_configuration: Option<(&[ShortcutBinding], &[ShortcutInputDefinition])>,
    shortcut_validation: Option<&ShortcutValidation>,
    error: Option<&str>,
) -> Result<(), WireError> {
    let document = document.map(|document| builder.create_string(document));
    let error = error.map(|error| builder.create_string(error));
    let keyboard = keyboard.map(|keyboard| {
        let mut layouts = Vec::with_capacity(keyboard.layouts.len());
        for (layout, display_name) in keyboard.layouts.iter().zip(display_names) {
            let name = builder.create_string(&layout.layout);
            let variant = builder.create_string(&layout.variant);
            let display_name = builder.create_string(display_name);
            layouts.push(fb::KeyboardLayout::create(
                builder,
                &fb::KeyboardLayoutArgs {
                    layout: Some(name),
                    variant: Some(variant),
                    display_name: Some(display_name),
                },
            ));
        }
        let layouts = builder.create_vector(&layouts);
        let options = keyboard
            .options
            .iter()
            .map(|option| builder.create_string(option))
            .collect::<Vec<_>>();
        let options = builder.create_vector(&options);
        fb::KeyboardConfiguration::create(
            builder,
            &fb::KeyboardConfigurationArgs {
                layouts: Some(layouts),
                options: Some(options),
                repeat_delay_ms: keyboard.repeat_delay_ms,
                repeat_rate_hz: keyboard.repeat_rate_hz,
                active_layout: u32::try_from(active_layout).unwrap_or(u32::MAX),
            },
        )
    });
    let shortcuts = shortcut_configuration.map(|(bindings, inputs)| {
        let bindings = bindings
            .iter()
            .map(|binding| encode_shortcut_binding(builder, binding))
            .collect::<Vec<_>>();
        let bindings = builder.create_vector(&bindings);
        let actions = ShortcutAction::ALL.map(shortcut_action_to_wire);
        let actions = builder.create_vector(&actions);
        let inputs = inputs
            .iter()
            .map(|input| {
                let canonical = builder.create_string(&input.canonical);
                let aliases = input
                    .aliases
                    .iter()
                    .map(|alias| builder.create_string(alias))
                    .collect::<Vec<_>>();
                let aliases = builder.create_vector(&aliases);
                fb::ShortcutInput::create(
                    builder,
                    &fb::ShortcutInputArgs {
                        canonical: Some(canonical),
                        kind: shortcut_input_kind_to_wire(input.kind),
                        category: shortcut_input_category_to_wire(input.category),
                        aliases: Some(aliases),
                    },
                )
            })
            .collect::<Vec<_>>();
        let inputs = builder.create_vector(&inputs);
        fb::ShortcutConfiguration::create(
            builder,
            &fb::ShortcutConfigurationArgs {
                shortcuts: Some(bindings),
                supported_actions: Some(actions),
                supported_inputs: Some(inputs),
            },
        )
    });
    let shortcut_validation = shortcut_validation.map(|validation| {
        let (kind, canonical, conflict, validation_error) = match validation {
            ShortcutValidation::Valid { canonical } => (
                fb::ShortcutValidationKind::Valid,
                Some(canonical.as_str()),
                None,
                None,
            ),
            ShortcutValidation::Conflict { canonical, binding } => (
                fb::ShortcutValidationKind::Conflict,
                Some(canonical.as_str()),
                Some(binding),
                None,
            ),
            ShortcutValidation::Invalid { error } => (
                fb::ShortcutValidationKind::Invalid,
                None,
                None,
                Some(error.as_str()),
            ),
        };
        let canonical = canonical.map(|canonical| builder.create_string(canonical));
        let conflict = conflict.map(|binding| encode_shortcut_binding(builder, binding));
        let validation_error = validation_error.map(|error| builder.create_string(error));
        fb::ShortcutValidation::create(
            builder,
            &fb::ShortcutValidationArgs {
                kind,
                canonical,
                conflict,
                error: validation_error,
            },
        )
    });
    let response = fb::SettingsResponse::create(
        builder,
        &fb::SettingsResponseArgs {
            kind,
            success: error.is_none(),
            revision,
            document,
            keyboard,
            error,
            shortcuts,
            shortcut_validation,
            input_devices: None,
        },
    );
    let envelope = fb::Envelope::create(
        builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence,
            request_id,
            payload_type: fb::Payload::SettingsResponse,
            payload: Some(response.as_union_value()),
        },
    );
    fb::finish_envelope_buffer(builder, envelope);
    validate_finished_message(builder)
}

fn encode_shortcut_binding<'a>(
    builder: &mut FlatBufferBuilder<'a>,
    binding: &ShortcutBinding,
) -> WIPOffset<fb::ShortcutBinding<'a>> {
    let shortcut = builder.create_string(&binding.shortcut);
    let (target_type, target) = match &binding.target {
        ShortcutTarget::DenialAction { action } => {
            let target = fb::ShortcutDenialActionTarget::create(
                builder,
                &fb::ShortcutDenialActionTargetArgs {
                    action: shortcut_action_to_wire(*action),
                },
            );
            (
                fb::ShortcutTarget::ShortcutDenialActionTarget,
                target.as_union_value(),
            )
        }
        ShortcutTarget::Spawn { command } => {
            let command = command
                .iter()
                .map(|argument| builder.create_string(argument))
                .collect::<Vec<_>>();
            let command = builder.create_vector(&command);
            let target = fb::ShortcutSpawnTarget::create(
                builder,
                &fb::ShortcutSpawnTargetArgs {
                    command: Some(command),
                },
            );
            (
                fb::ShortcutTarget::ShortcutSpawnTarget,
                target.as_union_value(),
            )
        }
        ShortcutTarget::SpawnSh { command } => {
            let command = builder.create_string(command);
            let target = fb::ShortcutSpawnShTarget::create(
                builder,
                &fb::ShortcutSpawnShTargetArgs {
                    command: Some(command),
                },
            );
            (
                fb::ShortcutTarget::ShortcutSpawnShTarget,
                target.as_union_value(),
            )
        }
    };
    fb::ShortcutBinding::create(
        builder,
        &fb::ShortcutBindingArgs {
            shortcut: Some(shortcut),
            target_type,
            target: Some(target),
        },
    )
}

fn shortcut_action_to_wire(action: ShortcutAction) -> fb::ShortcutActionKind {
    match action {
        ShortcutAction::Shutdown => fb::ShortcutActionKind::Shutdown,
        ShortcutAction::OpenApplications => fb::ShortcutActionKind::OpenApplications,
        ShortcutAction::OpenOverview => fb::ShortcutActionKind::OpenOverview,
        ShortcutAction::ToggleVerticalMaximize => fb::ShortcutActionKind::ToggleVerticalMaximize,
        ShortcutAction::WindowSwitcher => fb::ShortcutActionKind::WindowSwitcher,
        ShortcutAction::OpenClipboard => fb::ShortcutActionKind::OpenClipboard,
        ShortcutAction::CaptureRegion => fb::ShortcutActionKind::CaptureRegion,
        ShortcutAction::CloseWindow => fb::ShortcutActionKind::CloseWindow,
        ShortcutAction::MinimizeWindow => fb::ShortcutActionKind::MinimizeWindow,
        ShortcutAction::ToggleMaximize => fb::ShortcutActionKind::ToggleMaximize,
        ShortcutAction::ToggleFullscreen => fb::ShortcutActionKind::ToggleFullscreen,
        ShortcutAction::ReleasePointer => fb::ShortcutActionKind::ReleasePointer,
        ShortcutAction::LockScreen => fb::ShortcutActionKind::LockScreen,
        ShortcutAction::VolumeUp => fb::ShortcutActionKind::VolumeUp,
        ShortcutAction::VolumeDown => fb::ShortcutActionKind::VolumeDown,
        ShortcutAction::VolumeMute => fb::ShortcutActionKind::VolumeMute,
        ShortcutAction::BrightnessUp => fb::ShortcutActionKind::BrightnessUp,
        ShortcutAction::BrightnessDown => fb::ShortcutActionKind::BrightnessDown,
        ShortcutAction::NextKeyboardLayout => fb::ShortcutActionKind::NextKeyboardLayout,
        ShortcutAction::PreviousKeyboardLayout => fb::ShortcutActionKind::PreviousKeyboardLayout,
    }
}

fn shortcut_input_kind_to_wire(kind: ShortcutInputKind) -> fb::ShortcutInputKind {
    match kind {
        ShortcutInputKind::Key => fb::ShortcutInputKind::Key,
        ShortcutInputKind::Gesture => fb::ShortcutInputKind::Gesture,
    }
}

fn shortcut_input_category_to_wire(category: ShortcutInputCategory) -> fb::ShortcutInputCategory {
    match category {
        ShortcutInputCategory::Modifier => fb::ShortcutInputCategory::Modifier,
        ShortcutInputCategory::Navigation => fb::ShortcutInputCategory::Navigation,
        ShortcutInputCategory::Editing => fb::ShortcutInputCategory::Editing,
        ShortcutInputCategory::Punctuation => fb::ShortcutInputCategory::Punctuation,
        ShortcutInputCategory::Function => fb::ShortcutInputCategory::Function,
        ShortcutInputCategory::Media => fb::ShortcutInputCategory::Media,
        ShortcutInputCategory::Hardware => fb::ShortcutInputCategory::Hardware,
        ShortcutInputCategory::Special => fb::ShortcutInputCategory::Special,
        ShortcutInputCategory::Gesture => fb::ShortcutInputCategory::Gesture,
    }
}

fn encode_notification_event(
    builder: &mut FlatBufferBuilder<'_>,
    sequence: u64,
    event: &NotificationEvent,
) -> Result<(), WireError> {
    let notification = event
        .notification
        .as_ref()
        .map(|notification| encode_notification(builder, notification));
    let kind = match event.kind {
        NotificationEventKind::Added => fb::DesktopNotificationEventKind::Added,
        NotificationEventKind::Replaced => fb::DesktopNotificationEventKind::Replaced,
        NotificationEventKind::Closed => fb::DesktopNotificationEventKind::Closed,
    };
    let event = fb::DesktopNotificationEvent::create(
        builder,
        &fb::DesktopNotificationEventArgs {
            kind,
            notification,
            notification_id: event.notification_id,
            close_reason: event.close_reason,
        },
    );
    let envelope = fb::Envelope::create(
        builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence,
            request_id: 0,
            payload_type: fb::Payload::DesktopNotificationEvent,
            payload: Some(event.as_union_value()),
        },
    );
    fb::finish_envelope_buffer(builder, envelope);
    validate_finished_message(builder)
}

fn encode_xembed_tray_event(
    builder: &mut FlatBufferBuilder<'_>,
    sequence: u64,
    event: &XEmbedTrayEvent,
) -> Result<(), WireError> {
    let icon = event.icon.as_ref().map(|source| {
        let title = builder.create_string(&source.title);
        let rgba = builder.create_vector(&source.rgba);
        fb::XEmbedTrayIcon::create(
            builder,
            &fb::XEmbedTrayIconArgs {
                window_id: source.window_id,
                title: Some(title),
                width: source.width,
                height: source.height,
                rgba: Some(rgba),
            },
        )
    });
    let kind = match event.kind {
        XEmbedTrayEventKind::Added => fb::XEmbedTrayEventKind::Added,
        XEmbedTrayEventKind::Updated => fb::XEmbedTrayEventKind::Updated,
        XEmbedTrayEventKind::Removed => fb::XEmbedTrayEventKind::Removed,
    };
    let event = fb::XEmbedTrayEvent::create(
        builder,
        &fb::XEmbedTrayEventArgs {
            kind,
            window_id: event.window_id,
            icon,
        },
    );
    let envelope = fb::Envelope::create(
        builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence,
            request_id: 0,
            payload_type: fb::Payload::XEmbedTrayEvent,
            payload: Some(event.as_union_value()),
        },
    );
    fb::finish_envelope_buffer(builder, envelope);
    validate_finished_message(builder)
}

fn encode_notification<'a>(
    builder: &mut FlatBufferBuilder<'a>,
    notification: &Notification,
) -> WIPOffset<fb::DesktopNotification<'a>> {
    let mut action_offsets = Vec::with_capacity(notification.actions.len());
    for action in &notification.actions {
        let key = builder.create_string(&action.key);
        let label = builder.create_string(&action.label);
        action_offsets.push(fb::DesktopNotificationAction::create(
            builder,
            &fb::DesktopNotificationActionArgs {
                key: Some(key),
                label: Some(label),
            },
        ));
    }
    let actions = builder.create_vector(&action_offsets);
    let image_data = notification.image_data.as_ref().map(|image| {
        let data = builder.create_vector(&image.data);
        fb::DesktopNotificationImageData::create(
            builder,
            &fb::DesktopNotificationImageDataArgs {
                width: image.width,
                height: image.height,
                row_stride: image.row_stride,
                has_alpha: image.has_alpha,
                bits_per_sample: image.bits_per_sample,
                channels: image.channels,
                data: Some(data),
            },
        )
    });
    let sender = builder.create_string(&notification.sender);
    let app_name = builder.create_string(&notification.app_name);
    let app_icon = builder.create_string(&notification.app_icon);
    let summary = builder.create_string(&notification.summary);
    let body = builder.create_string(&notification.body);
    let category = builder.create_string(&notification.category);
    let desktop_entry = builder.create_string(&notification.desktop_entry);
    let image_path = builder.create_string(&notification.image_path);
    let sound_name = builder.create_string(&notification.sound_name);
    let sound_file = builder.create_string(&notification.sound_file);
    let urgency = match notification.urgency {
        NotificationUrgency::Low => fb::DesktopNotificationUrgency::Low,
        NotificationUrgency::Normal => fb::DesktopNotificationUrgency::Normal,
        NotificationUrgency::Critical => fb::DesktopNotificationUrgency::Critical,
    };
    fb::DesktopNotification::create(
        builder,
        &fb::DesktopNotificationArgs {
            id: notification.id,
            sender: Some(sender),
            app_name: Some(app_name),
            app_icon: Some(app_icon),
            summary: Some(summary),
            body: Some(body),
            actions: Some(actions),
            urgency,
            category: Some(category),
            desktop_entry: Some(desktop_entry),
            image_path: Some(image_path),
            image_data,
            resident: notification.resident,
            transient: notification.transient,
            suppress_sound: notification.suppress_sound,
            action_icons: notification.action_icons,
            sound_name: Some(sound_name),
            sound_file: Some(sound_file),
            x: notification.x,
            y: notification.y,
            has_position: notification.has_position,
            progress: notification.progress,
            has_progress: notification.has_progress,
            expire_timeout_ms: notification.expire_timeout_ms,
        },
    )
}

pub(super) fn encode_display_layout(
    builder: &mut FlatBufferBuilder<'_>,
    sequence: u64,
    request_id: u64,
    snapshot: &TopologySnapshot,
    atlas: &AtlasPlan,
    work_area: &WorkAreaOptions,
) -> Result<(), WireError> {
    let mut ordered = snapshot.outputs.iter().collect::<Vec<_>>();
    ordered.sort_by(|left, right| {
        (left.position.x, left.position.y, left.name.as_str()).cmp(&(
            right.position.x,
            right.position.y,
            right.name.as_str(),
        ))
    });

    let mut outputs = Vec::with_capacity(ordered.len());
    for output in ordered {
        let planned = atlas
            .outputs
            .iter()
            .find(|planned| planned.id == output.id)
            .ok_or(WireError::Topology("output is absent from atlas"))?;
        let name = builder.create_string(&output.name);
        let logical = fb::WireRect::new(
            planned.logical_rect.x - atlas.logical_origin.0,
            planned.logical_rect.y - atlas.logical_origin.1,
            planned.logical_rect.width,
            planned.logical_rect.height,
        );
        let pixels = fb::WireSize::new(
            f64::from(planned.pixel_size.width),
            f64::from(planned.pixel_size.height),
        );
        let source = fb::WireRect::new(
            f64::from(planned.source_rect.x),
            f64::from(planned.source_rect.y),
            f64::from(planned.source_rect.width),
            f64::from(planned.source_rect.height),
        );
        outputs.push(fb::DisplayOutput::create(
            builder,
            &fb::DisplayOutputArgs {
                monitor_id: monitor_id(output.id)
                    .ok_or(WireError::Topology("monitor id exceeds i64"))?,
                name: Some(name),
                logical_rect: Some(&logical),
                pixel_size: Some(&pixels),
                source_rect: Some(&source),
                scale: f64::from(output.scale_120) / f64::from(SCALE_BASE),
                refresh_rate: f64::from(output.refresh_millihz) / 1_000.0,
            },
        ));
    }

    let outputs = builder.create_vector(&outputs);
    let origin = fb::WirePoint::new(atlas.logical_origin.0, atlas.logical_origin.1);
    let logical_size = fb::WireSize::new(atlas.logical_size.0, atlas.logical_size.1);
    let pixel_size = fb::WireSize::new(
        f64::from(atlas.pixel_size.width),
        f64::from(atlas.pixel_size.height),
    );
    let ticker = snapshot.ticker.and_then(monitor_id).unwrap_or(-1);
    let (system_bar_monitor_ids, system_bar_side, system_bar_thickness) =
        resolve_system_bar(snapshot, &work_area.system_bar, ticker);
    let system_bar_monitor_id = if system_bar_monitor_ids.contains(&ticker) {
        ticker
    } else {
        system_bar_monitor_ids.first().copied().unwrap_or(-1)
    };
    let system_bar_monitor_ids = builder.create_vector(&system_bar_monitor_ids);
    let maximize_padding = if work_area.maximize_padding.is_finite() {
        work_area.maximize_padding.max(0.0)
    } else {
        0.0
    };
    let layout = fb::DisplayLayout::create(
        builder,
        &fb::DisplayLayoutArgs {
            epoch: snapshot.epoch,
            global_origin: Some(&origin),
            logical_size: Some(&logical_size),
            pixel_size: Some(&pixel_size),
            engine_scale: f64::from(atlas.engine_scale_120) / f64::from(SCALE_BASE),
            ticker_monitor_id: ticker,
            system_bar_monitor_id,
            system_bar_side,
            system_bar_thickness,
            maximize_padding,
            system_bar_monitor_ids: Some(system_bar_monitor_ids),
            outputs: Some(outputs),
        },
    );
    let response = fb::WindowResponse::create(
        builder,
        &fb::WindowResponseArgs {
            kind: fb::WindowResponseKind::DisplayLayout,
            success: true,
            display_layout: Some(layout),
            ..Default::default()
        },
    );
    finish_response(builder, sequence, request_id, response)
}

fn finish_response<'a>(
    builder: &mut FlatBufferBuilder<'a>,
    sequence: u64,
    request_id: u64,
    response: WIPOffset<fb::WindowResponse<'a>>,
) -> Result<(), WireError> {
    let envelope = fb::Envelope::create(
        builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence,
            request_id,
            payload_type: fb::Payload::WindowResponse,
            payload: Some(response.as_union_value()),
        },
    );
    fb::finish_envelope_buffer(builder, envelope);
    validate_finished_message(builder)
}
