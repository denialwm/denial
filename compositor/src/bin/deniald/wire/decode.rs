//! Verified Flutter-to-native protocol ingress.

use super::*;

impl WireBridge {
    /// Handles one verified Flutter message and returns an ordered response,
    /// when the payload is a request/reply operation.
    pub fn handle(&mut self, bytes: &[u8]) -> Result<Option<&[u8]>, WireError> {
        if !(MIN_ENVELOPE_BYTES..=MAX_MESSAGE_BYTES).contains(&bytes.len()) {
            return Err(WireError::Size(bytes.len()));
        }
        if !fb::envelope_buffer_has_identifier(bytes) {
            return Err(WireError::Identifier);
        }

        let verifier = flatbuffers::VerifierOptions {
            max_depth: 16,
            max_tables: 16_384,
            max_apparent_size: MAX_MESSAGE_BYTES + 1,
            ignore_missing_null_terminator: false,
        };
        let envelope =
            fb::root_as_envelope_with_opts(&verifier, bytes).map_err(WireError::FlatBuffer)?;
        if envelope.protocol_version() != PROTOCOL_VERSION {
            return Err(WireError::Version(envelope.protocol_version()));
        }
        if envelope.sequence() == 0 {
            return Err(WireError::Sequence);
        }

        match envelope.payload_type() {
            fb::Payload::InputLayout => {
                let layout = envelope
                    .payload_as_input_layout()
                    .ok_or(WireError::Payload)?;
                let mut decoded = std::mem::take(&mut self.input_layout_scratch);
                let mut identities = std::mem::take(&mut self.input_layout_identities_scratch);
                let result = decode_input_layout(layout, &mut decoded, &mut identities);
                self.input_layout_identities_scratch = identities;
                if let Err(error) = result {
                    self.input_layout_scratch = decoded;
                    return Err(error);
                }
                if let Some(displaced) = self.pending_input_layout.replace(decoded) {
                    self.input_layout_scratch = displaced;
                }
                Ok(None)
            }
            fb::Payload::KeyboardCommand => {
                let command = envelope
                    .payload_as_keyboard_command()
                    .ok_or(WireError::Payload)?;
                if self.pending_keyboard_commands.len() >= MAX_PENDING_KEYBOARD_COMMANDS {
                    return Err(WireError::Count);
                }
                let command = decode_keyboard_command(command)?;
                self.pending_keyboard_commands.push_back(command);
                Ok(None)
            }
            fb::Payload::DesktopNotificationCommand => {
                let command = envelope
                    .payload_as_desktop_notification_command()
                    .ok_or(WireError::Payload)?;
                if self.pending_notification_commands.len() >= MAX_PENDING_NOTIFICATION_COMMANDS {
                    return Err(WireError::Count);
                }
                let command = decode_notification_command(command)?;
                self.pending_notification_commands.push_back(command);
                Ok(None)
            }
            fb::Payload::XEmbedTrayCommand => {
                let command = envelope
                    .payload_as_xembed_tray_command()
                    .ok_or(WireError::Payload)?;
                if self.pending_xembed_tray_commands.len() >= MAX_PENDING_XEMBED_TRAY_COMMANDS {
                    return Err(WireError::Count);
                }
                self.pending_xembed_tray_commands
                    .push_back(decode_xembed_tray_command(command)?);
                Ok(None)
            }
            fb::Payload::ThemeState => {
                if envelope.request_id() != 0 {
                    return Err(WireError::RequestId);
                }
                let theme = envelope
                    .payload_as_theme_state()
                    .ok_or(WireError::Payload)?;
                let accent = theme.accent_srgb();
                if accent & 0xff00_0000 != 0 {
                    return Err(WireError::Payload);
                }
                self.pending_theme_accent = Some(accent);
                Ok(None)
            }
            fb::Payload::SettingsRequest => {
                if envelope.request_id() == 0 {
                    return Err(WireError::RequestId);
                }
                if self.pending_settings_commands.len() >= MAX_PENDING_SETTINGS_COMMANDS {
                    return Err(WireError::Count);
                }
                let request = envelope
                    .payload_as_settings_request()
                    .ok_or(WireError::Payload)?;
                let command = decode_settings_request(envelope.request_id(), request)?;
                self.pending_settings_commands.push_back(command);
                Ok(None)
            }
            fb::Payload::WindowRequest => {
                let request = envelope
                    .payload_as_window_request()
                    .ok_or(WireError::Payload)?;
                self.handle_window_request(envelope.request_id(), request)
            }
            fb::Payload::NONE => Err(WireError::Payload),
            payload => Err(WireError::Direction(payload)),
        }
    }

    fn handle_window_request(
        &mut self,
        request_id: u64,
        request: fb::WindowRequest<'_>,
    ) -> Result<Option<&[u8]>, WireError> {
        match request.kind() {
            fb::WindowRequestKind::ListWindows => {
                if request_id == 0 {
                    return Err(WireError::RequestId);
                }
                let sequence = self.take_sequence();
                self.outbound_builder.reset();
                encode_windows_response(
                    &mut self.outbound_builder,
                    sequence,
                    request_id,
                    &self.windows,
                    &self.restored_window_ids,
                )?;
                Ok(Some(self.outbound_builder.finished_data()))
            }
            fb::WindowRequestKind::GetDisplayLayout => {
                if request_id == 0 {
                    return Err(WireError::RequestId);
                }
                let sequence = self.take_sequence();
                self.outbound_builder.reset();
                encode_display_layout(
                    &mut self.outbound_builder,
                    sequence,
                    request_id,
                    &self.snapshot,
                    &self.atlas,
                    &self.work_area,
                )?;
                Ok(Some(self.outbound_builder.finished_data()))
            }
            fb::WindowRequestKind::ConfigureSystemBar => {
                if request_id == 0 {
                    return Err(WireError::RequestId);
                }
                let side = match request.system_bar_side() {
                    fb::SystemBarSide::Left => SystemBarSide::Left,
                    fb::SystemBarSide::Right => SystemBarSide::Right,
                    fb::SystemBarSide::Top => SystemBarSide::Top,
                    fb::SystemBarSide::Bottom => SystemBarSide::Bottom,
                    fb::SystemBarSide::Hidden => return Err(WireError::Enumeration),
                    _ => return Err(WireError::Enumeration),
                };
                let monitor_ids = request.system_bar_monitor_ids().ok_or(WireError::Payload)?;
                if monitor_ids.is_empty() || monitor_ids.len() > self.snapshot.outputs.len() {
                    return Err(WireError::Count);
                }
                let mut unique_ids = HashSet::with_capacity(monitor_ids.len());
                let mut outputs = Vec::with_capacity(monitor_ids.len());
                for requested_monitor_id in monitor_ids {
                    if requested_monitor_id < 0 || !unique_ids.insert(requested_monitor_id) {
                        return Err(WireError::Identity);
                    }
                    let output = self
                        .snapshot
                        .outputs
                        .iter()
                        .find(|output| monitor_id(output.id) == Some(requested_monitor_id))
                        .ok_or(WireError::Topology("system bar monitor is not live"))?;
                    outputs.push(output.name.clone());
                }
                self.work_area.system_bar.outputs = outputs;
                self.work_area.system_bar.side = side;
                self.pending_work_area = Some(self.work_area.clone());

                let sequence = self.take_sequence();
                self.outbound_builder.reset();
                encode_display_layout(
                    &mut self.outbound_builder,
                    sequence,
                    request_id,
                    &self.snapshot,
                    &self.atlas,
                    &self.work_area,
                )?;
                Ok(Some(self.outbound_builder.finished_data()))
            }
            kind @ (fb::WindowRequestKind::CloseWindow
            | fb::WindowRequestKind::FocusWindow
            | fb::WindowRequestKind::ConfigureWindow) => {
                if self.pending_window_commands.len() >= MAX_PENDING_WINDOW_COMMANDS {
                    return Err(WireError::Count);
                }
                let window_id = request.window_id();
                if window_id == 0 {
                    return Err(WireError::Identity);
                }
                let command = match kind {
                    fb::WindowRequestKind::CloseWindow => WindowCommand::Close { window_id },
                    fb::WindowRequestKind::FocusWindow => WindowCommand::Focus { window_id },
                    fb::WindowRequestKind::ConfigureWindow => {
                        const EXACT: u32 = 1 << 0;
                        const LAYOUT_DROP: u32 = 1 << 1;
                        const FLAGS_MASK: u32 = EXACT | LAYOUT_DROP;
                        let flags = request.flags();
                        if flags & !FLAGS_MASK != 0 || flags & FLAGS_MASK == FLAGS_MASK {
                            return Err(WireError::Flags);
                        }
                        let geometry =
                            decode_window_geometry(request.geometry().ok_or(WireError::Geometry)?)?;
                        WindowCommand::Configure {
                            window_id,
                            geometry,
                            exact: flags & EXACT != 0,
                            layout_drop: flags & LAYOUT_DROP != 0,
                        }
                    }
                    _ => unreachable!(),
                };
                self.pending_window_commands.push_back(command);
                Ok(None)
            }
            fb::WindowRequestKind::CreateLocalWindow => {
                if request_id != 0 {
                    return Err(WireError::RequestId);
                }
                if self.pending_window_commands.len() >= MAX_PENDING_WINDOW_COMMANDS {
                    return Err(WireError::Count);
                }
                let app_id = request.app_id().ok_or(WireError::Payload)?;
                let title = request.title().ok_or(WireError::Payload)?;
                if app_id.is_empty()
                    || app_id.len() > MAX_LOCAL_APP_ID_BYTES
                    || title.is_empty()
                    || title.len() > MAX_LOCAL_WINDOW_TITLE_BYTES
                    || app_id.contains('\0')
                    || title.contains('\0')
                {
                    return Err(WireError::Payload);
                }
                let geometry =
                    decode_window_geometry(request.geometry().ok_or(WireError::Geometry)?)?;
                self.pending_window_commands
                    .push_back(WindowCommand::CreateLocal {
                        app_id: app_id.to_owned(),
                        title: title.to_owned(),
                        geometry,
                    });
                Ok(None)
            }
            kind => Err(WireError::Request(kind)),
        }
    }
}

fn decode_window_geometry(rect: &fb::WireRect) -> Result<WindowGeometry, WireError> {
    let geometry = WindowGeometry {
        x: rect.x(),
        y: rect.y(),
        width: rect.width(),
        height: rect.height(),
    };
    let right = geometry.x + geometry.width;
    let bottom = geometry.y + geometry.height;
    if !geometry.x.is_finite()
        || !geometry.y.is_finite()
        || !geometry.width.is_finite()
        || !geometry.height.is_finite()
        || !right.is_finite()
        || !bottom.is_finite()
        || geometry.x < 0.0
        || geometry.y < 0.0
        || geometry.x > 16_384.0
        || geometry.y > 16_384.0
        || geometry.width < 64.0
        || geometry.height < 64.0
        || geometry.width > 16_384.0
        || geometry.height > 16_384.0
        || right > i32::MAX as f64
        || bottom > i32::MAX as f64
    {
        return Err(WireError::Geometry);
    }
    Ok(geometry)
}

fn validate_required_string(value: Option<&str>) -> Result<(), WireError> {
    match value {
        Some(value) if !value.is_empty() && value.len() <= MAX_STRING_BYTES => Ok(()),
        _ => Err(WireError::String),
    }
}

fn decode_keyboard_command(command: fb::KeyboardCommand<'_>) -> Result<KeyboardCommand, WireError> {
    if command.kind().variant_name().is_none() {
        return Err(WireError::Enumeration);
    }
    if command.flags() & !KEYBOARD_FLAGS_MASK != 0 {
        return Err(WireError::Flags);
    }

    match command.kind() {
        fb::KeyboardCommandKind::Text => {
            if command.flags() != 0 {
                return Err(WireError::Flags);
            }
            let text = command.text();
            validate_required_string(text)?;
            Ok(KeyboardCommand::Text(
                text.expect("validated keyboard text").to_owned(),
            ))
        }
        fb::KeyboardCommandKind::Key => {
            let key = command.key();
            validate_required_string(key)?;
            let phase = match command.flags() & KEYBOARD_PHASE_MASK {
                0 => KeyboardKeyPhase::Tap,
                KEYBOARD_PRESSED => KeyboardKeyPhase::Pressed,
                KEYBOARD_RELEASED => KeyboardKeyPhase::Released,
                _ => return Err(WireError::Flags),
            };
            let ctrl = command.flags() & KEYBOARD_CTRL != 0;
            if ctrl && phase != KeyboardKeyPhase::Tap {
                return Err(WireError::Flags);
            }
            Ok(KeyboardCommand::Key {
                key: key.expect("validated keyboard key").to_owned(),
                ctrl,
                phase,
            })
        }
        _ => Err(WireError::Enumeration),
    }
}

fn decode_settings_request(
    request_id: u64,
    request: fb::SettingsRequest<'_>,
) -> Result<SettingsCommand, WireError> {
    match request.kind() {
        fb::SettingsRequestKind::ReadDocument => {
            if request.expected_revision() != 0
                || request.document().is_some()
                || request.keyboard().is_some()
                || request.shortcut().is_some()
                || request.existing_shortcut().is_some()
                || request.touchpad().is_some()
                || request.mouse().is_some()
            {
                return Err(WireError::Payload);
            }
            Ok(SettingsCommand::ReadDocument { request_id })
        }
        fb::SettingsRequestKind::WriteDocument => {
            let document = request.document().ok_or(WireError::String)?;
            if request.expected_revision() == 0
                || document.is_empty()
                || document.len() > MAX_SETTINGS_DOCUMENT_BYTES
                || request.keyboard().is_some()
                || request.shortcut().is_some()
                || request.existing_shortcut().is_some()
                || request.touchpad().is_some()
                || request.mouse().is_some()
            {
                return Err(WireError::Payload);
            }
            Ok(SettingsCommand::WriteDocument {
                request_id,
                expected_revision: request.expected_revision(),
                document: document.to_owned(),
            })
        }
        fb::SettingsRequestKind::ReadKeyboard => {
            if request.expected_revision() != 0
                || request.document().is_some()
                || request.keyboard().is_some()
                || request.shortcut().is_some()
                || request.existing_shortcut().is_some()
                || request.touchpad().is_some()
                || request.mouse().is_some()
            {
                return Err(WireError::Payload);
            }
            Ok(SettingsCommand::ReadKeyboard { request_id })
        }
        fb::SettingsRequestKind::ConfigureKeyboard => {
            if request.expected_revision() == 0
                || request.document().is_some()
                || request.shortcut().is_some()
                || request.existing_shortcut().is_some()
                || request.touchpad().is_some()
                || request.mouse().is_some()
            {
                return Err(WireError::Payload);
            }
            let keyboard = decode_keyboard_settings(request.keyboard().ok_or(WireError::Payload)?)?;
            Ok(SettingsCommand::ConfigureKeyboard {
                request_id,
                expected_revision: request.expected_revision(),
                keyboard,
            })
        }
        fb::SettingsRequestKind::ReadShortcuts => {
            if request.expected_revision() != 0
                || request.document().is_some()
                || request.keyboard().is_some()
                || request.shortcut().is_some()
                || request.existing_shortcut().is_some()
                || request.touchpad().is_some()
                || request.mouse().is_some()
            {
                return Err(WireError::Payload);
            }
            Ok(SettingsCommand::ReadShortcuts { request_id })
        }
        fb::SettingsRequestKind::ValidateShortcut => {
            if request.expected_revision() != 0
                || request.document().is_some()
                || request.keyboard().is_some()
                || request.touchpad().is_some()
                || request.mouse().is_some()
            {
                return Err(WireError::Payload);
            }
            let shortcut = decode_shortcut_binding(request.shortcut().ok_or(WireError::Payload)?)?;
            let existing_shortcut = request
                .existing_shortcut()
                .map(|shortcut| {
                    if !valid_shortcut_wire_string(shortcut, false) {
                        Err(WireError::String)
                    } else {
                        Ok(shortcut.to_owned())
                    }
                })
                .transpose()?;
            Ok(SettingsCommand::ValidateShortcut {
                request_id,
                shortcut,
                existing_shortcut,
            })
        }
        fb::SettingsRequestKind::AddShortcut => {
            if request.expected_revision() == 0
                || request.document().is_some()
                || request.keyboard().is_some()
                || request.existing_shortcut().is_some()
                || request.touchpad().is_some()
                || request.mouse().is_some()
            {
                return Err(WireError::Payload);
            }
            Ok(SettingsCommand::AddShortcut {
                request_id,
                expected_revision: request.expected_revision(),
                shortcut: decode_shortcut_binding(request.shortcut().ok_or(WireError::Payload)?)?,
            })
        }
        fb::SettingsRequestKind::UpdateShortcut => {
            if request.expected_revision() == 0
                || request.document().is_some()
                || request.keyboard().is_some()
                || request.touchpad().is_some()
                || request.mouse().is_some()
            {
                return Err(WireError::Payload);
            }
            let existing_shortcut = request
                .existing_shortcut()
                .filter(|shortcut| valid_shortcut_wire_string(shortcut, false))
                .ok_or(WireError::String)?
                .to_owned();
            Ok(SettingsCommand::UpdateShortcut {
                request_id,
                expected_revision: request.expected_revision(),
                existing_shortcut,
                shortcut: decode_shortcut_binding(request.shortcut().ok_or(WireError::Payload)?)?,
            })
        }
        fb::SettingsRequestKind::RemoveShortcut => {
            if request.expected_revision() == 0
                || request.document().is_some()
                || request.keyboard().is_some()
                || request.shortcut().is_some()
                || request.touchpad().is_some()
                || request.mouse().is_some()
            {
                return Err(WireError::Payload);
            }
            let shortcut = request
                .existing_shortcut()
                .filter(|shortcut| valid_shortcut_wire_string(shortcut, false))
                .ok_or(WireError::String)?
                .to_owned();
            Ok(SettingsCommand::RemoveShortcut {
                request_id,
                expected_revision: request.expected_revision(),
                shortcut,
            })
        }
        fb::SettingsRequestKind::RestoreShortcuts => {
            if request.expected_revision() == 0
                || request.document().is_some()
                || request.keyboard().is_some()
                || request.shortcut().is_some()
                || request.existing_shortcut().is_some()
                || request.touchpad().is_some()
                || request.mouse().is_some()
            {
                return Err(WireError::Payload);
            }
            Ok(SettingsCommand::RestoreShortcuts {
                request_id,
                expected_revision: request.expected_revision(),
            })
        }
        fb::SettingsRequestKind::ReadInputDevices => {
            if request.expected_revision() != 0
                || request.document().is_some()
                || request.keyboard().is_some()
                || request.shortcut().is_some()
                || request.existing_shortcut().is_some()
                || request.touchpad().is_some()
                || request.mouse().is_some()
            {
                return Err(WireError::Payload);
            }
            Ok(SettingsCommand::ReadInputDevices { request_id })
        }
        fb::SettingsRequestKind::ConfigureTouchpad => {
            if request.expected_revision() == 0
                || request.document().is_some()
                || request.keyboard().is_some()
                || request.shortcut().is_some()
                || request.existing_shortcut().is_some()
                || request.mouse().is_some()
            {
                return Err(WireError::Payload);
            }
            let touchpad = request.touchpad().ok_or(WireError::Payload)?;
            Ok(SettingsCommand::ConfigureTouchpad {
                request_id,
                expected_revision: request.expected_revision(),
                touchpad: TouchpadSettings {
                    tap_to_click_enabled: touchpad.tap_to_click_enabled(),
                    natural_scroll_enabled: touchpad.natural_scroll_enabled(),
                    scroll_speed_factor: touchpad.scroll_speed_factor(),
                },
            })
        }
        fb::SettingsRequestKind::ConfigureMouse => {
            if request.expected_revision() == 0
                || request.document().is_some()
                || request.keyboard().is_some()
                || request.shortcut().is_some()
                || request.existing_shortcut().is_some()
                || request.touchpad().is_some()
            {
                return Err(WireError::Payload);
            }
            let mouse = request.mouse().ok_or(WireError::Payload)?;
            Ok(SettingsCommand::ConfigureMouse {
                request_id,
                expected_revision: request.expected_revision(),
                mouse: MouseSettings {
                    speed: mouse.speed(),
                },
            })
        }
        _ => Err(WireError::Enumeration),
    }
}

fn decode_shortcut_binding(binding: fb::ShortcutBinding<'_>) -> Result<ShortcutBinding, WireError> {
    let shortcut = binding
        .shortcut()
        .filter(|shortcut| valid_shortcut_wire_string(shortcut, true))
        .ok_or(WireError::String)?;
    let target = match binding.target_type() {
        fb::ShortcutTarget::ShortcutDenialActionTarget => {
            let target = binding
                .target_as_shortcut_denial_action_target()
                .ok_or(WireError::Payload)?;
            ShortcutTarget::DenialAction {
                action: shortcut_action_from_wire(target.action())?,
            }
        }
        fb::ShortcutTarget::ShortcutSpawnTarget => {
            let target = binding
                .target_as_shortcut_spawn_target()
                .ok_or(WireError::Payload)?;
            let command = target.command().ok_or(WireError::Payload)?;
            if command.len() > MAX_SPAWN_ARGUMENTS {
                return Err(WireError::Count);
            }
            let mut arguments = Vec::with_capacity(command.len());
            for argument in command {
                if !valid_shortcut_wire_string(argument, true) {
                    return Err(WireError::String);
                }
                arguments.push(argument.to_owned());
            }
            let desktop_file_id = target.desktop_file_id().map(str::to_owned);
            if desktop_file_id.as_deref().is_some_and(|desktop_file_id| {
                crate::settings::validate_desktop_file_id(desktop_file_id).is_err()
            }) {
                return Err(WireError::String);
            }
            ShortcutTarget::Spawn {
                command: arguments,
                desktop_file_id,
            }
        }
        fb::ShortcutTarget::ShortcutSpawnShTarget => {
            let target = binding
                .target_as_shortcut_spawn_sh_target()
                .ok_or(WireError::Payload)?;
            let command = target
                .command()
                .filter(|command| valid_shortcut_wire_string(command, true))
                .ok_or(WireError::String)?;
            ShortcutTarget::SpawnSh {
                command: command.to_owned(),
            }
        }
        _ => return Err(WireError::Enumeration),
    };
    Ok(ShortcutBinding {
        shortcut: shortcut.to_owned(),
        target,
    })
}

fn valid_shortcut_wire_string(value: &str, empty_allowed: bool) -> bool {
    (empty_allowed || !value.is_empty()) && value.len() <= MAX_STRING_BYTES && !value.contains('\0')
}

fn shortcut_action_from_wire(action: fb::ShortcutActionKind) -> Result<ShortcutAction, WireError> {
    match action {
        fb::ShortcutActionKind::Shutdown => Ok(ShortcutAction::Shutdown),
        fb::ShortcutActionKind::OpenApplications => Ok(ShortcutAction::OpenApplications),
        fb::ShortcutActionKind::OpenDashboard => Ok(ShortcutAction::OpenDashboard),
        fb::ShortcutActionKind::OpenOverview => Ok(ShortcutAction::OpenOverview),
        fb::ShortcutActionKind::ToggleVerticalMaximize => {
            Ok(ShortcutAction::ToggleVerticalMaximize)
        }
        fb::ShortcutActionKind::WindowSwitcher => Ok(ShortcutAction::WindowSwitcher),
        fb::ShortcutActionKind::OpenClipboard => Ok(ShortcutAction::OpenClipboard),
        fb::ShortcutActionKind::CaptureRegion => Ok(ShortcutAction::CaptureRegion),
        fb::ShortcutActionKind::CloseWindow => Ok(ShortcutAction::CloseWindow),
        fb::ShortcutActionKind::MinimizeWindow => Ok(ShortcutAction::MinimizeWindow),
        fb::ShortcutActionKind::MinimizeAllWindows => Ok(ShortcutAction::MinimizeAllWindows),
        fb::ShortcutActionKind::ToggleMaximize => Ok(ShortcutAction::ToggleMaximize),
        fb::ShortcutActionKind::ToggleFullscreen => Ok(ShortcutAction::ToggleFullscreen),
        fb::ShortcutActionKind::ReleasePointer => Ok(ShortcutAction::ReleasePointer),
        fb::ShortcutActionKind::LockScreen => Ok(ShortcutAction::LockScreen),
        fb::ShortcutActionKind::VolumeUp => Ok(ShortcutAction::VolumeUp),
        fb::ShortcutActionKind::VolumeDown => Ok(ShortcutAction::VolumeDown),
        fb::ShortcutActionKind::VolumeMute => Ok(ShortcutAction::VolumeMute),
        fb::ShortcutActionKind::BrightnessUp => Ok(ShortcutAction::BrightnessUp),
        fb::ShortcutActionKind::BrightnessDown => Ok(ShortcutAction::BrightnessDown),
        fb::ShortcutActionKind::NextKeyboardLayout => Ok(ShortcutAction::NextKeyboardLayout),
        fb::ShortcutActionKind::PreviousKeyboardLayout => {
            Ok(ShortcutAction::PreviousKeyboardLayout)
        }
        fb::ShortcutActionKind::OpenSettings => Ok(ShortcutAction::OpenSettings),
        fb::ShortcutActionKind::FocusLeft => Ok(ShortcutAction::FocusLeft),
        fb::ShortcutActionKind::FocusRight => Ok(ShortcutAction::FocusRight),
        fb::ShortcutActionKind::FocusUp => Ok(ShortcutAction::FocusUp),
        fb::ShortcutActionKind::FocusDown => Ok(ShortcutAction::FocusDown),
        fb::ShortcutActionKind::SwapLeft => Ok(ShortcutAction::SwapLeft),
        fb::ShortcutActionKind::SwapRight => Ok(ShortcutAction::SwapRight),
        fb::ShortcutActionKind::SwapUp => Ok(ShortcutAction::SwapUp),
        fb::ShortcutActionKind::SwapDown => Ok(ShortcutAction::SwapDown),
        _ => Err(WireError::Enumeration),
    }
}

fn decode_keyboard_settings(
    keyboard: fb::KeyboardConfiguration<'_>,
) -> Result<KeyboardSettings, WireError> {
    let layouts = keyboard.layouts().ok_or(WireError::Payload)?;
    let options = keyboard.options().ok_or(WireError::Payload)?;
    let mut decoded_layouts = Vec::with_capacity(layouts.len());
    for layout in layouts {
        if layout.display_name().is_some_and(|name| !name.is_empty()) {
            return Err(WireError::Payload);
        }
        decoded_layouts.push(KeyboardLayout {
            layout: layout.layout().ok_or(WireError::String)?.to_owned(),
            variant: layout.variant().unwrap_or_default().to_owned(),
        });
    }
    let decoded = KeyboardSettings {
        layouts: decoded_layouts,
        options: options.iter().map(str::to_owned).collect(),
        repeat_delay_ms: keyboard.repeat_delay_ms(),
        repeat_rate_hz: keyboard.repeat_rate_hz(),
    };
    decoded.validate().map_err(|_| WireError::Payload)?;
    Ok(decoded)
}

fn decode_notification_command(
    command: fb::DesktopNotificationCommand<'_>,
) -> Result<NotificationCommand, WireError> {
    if command.kind().variant_name().is_none() {
        return Err(WireError::Enumeration);
    }
    let notification_id = command.notification_id();
    if notification_id == 0 {
        return Err(WireError::Identity);
    }

    match command.kind() {
        fb::DesktopNotificationCommandKind::InvokeAction => {
            validate_required_string(command.action_key())?;
            Ok(NotificationCommand::InvokeAction {
                notification_id,
                action_key: command
                    .action_key()
                    .expect("validated notification action key")
                    .to_owned(),
            })
        }
        fb::DesktopNotificationCommandKind::Dismiss => {
            if command.action_key().is_some_and(|key| !key.is_empty()) {
                Err(WireError::String)
            } else {
                Ok(NotificationCommand::Dismiss { notification_id })
            }
        }
        fb::DesktopNotificationCommandKind::InvokeDefault => {
            if command.action_key().is_some_and(|key| !key.is_empty()) {
                Err(WireError::String)
            } else {
                Ok(NotificationCommand::InvokeDefault { notification_id })
            }
        }
        _ => Err(WireError::Enumeration),
    }
}

fn decode_xembed_tray_command(
    command: fb::XEmbedTrayCommand<'_>,
) -> Result<XEmbedTrayCommand, WireError> {
    if command.kind().variant_name().is_none() || command.window_id() == 0 {
        return Err(WireError::Identity);
    }
    let action = match command.kind() {
        fb::XEmbedTrayCommandKind::Activate => XEmbedTrayAction::Activate,
        fb::XEmbedTrayCommandKind::SecondaryActivate => XEmbedTrayAction::SecondaryActivate,
        fb::XEmbedTrayCommandKind::ContextMenu => XEmbedTrayAction::ContextMenu,
        _ => return Err(WireError::Enumeration),
    };
    Ok(XEmbedTrayCommand {
        action,
        window_id: command.window_id(),
        x: command.x(),
        y: command.y(),
    })
}

pub(super) fn validate_notification_event(event: &NotificationEvent) -> Result<(), WireError> {
    if event.notification_id == 0 {
        return Err(WireError::Identity);
    }
    match event.kind {
        NotificationEventKind::Closed => {
            if event.notification.is_some() || !(1..=4).contains(&event.close_reason) {
                return Err(WireError::Payload);
            }
        }
        NotificationEventKind::Added | NotificationEventKind::Replaced => {
            let notification = event.notification.as_ref().ok_or(WireError::Payload)?;
            if notification.id != event.notification_id || event.close_reason != 0 {
                return Err(WireError::Identity);
            }
            if notification.actions.len() > 16
                || notification.actions.iter().any(|action| {
                    action.key.is_empty()
                        || action.key.len() > MAX_STRING_BYTES
                        || action.label.len() > MAX_STRING_BYTES
                })
                || [
                    &notification.sender,
                    &notification.app_name,
                    &notification.app_icon,
                    &notification.summary,
                    &notification.body,
                    &notification.category,
                    &notification.desktop_entry,
                    &notification.image_path,
                    &notification.sound_name,
                    &notification.sound_file,
                ]
                .into_iter()
                .any(|value| value.len() > MAX_STRING_BYTES)
            {
                return Err(WireError::String);
            }
            if let Some(image) = notification.image_data.as_ref() {
                let expected_channels = if image.has_alpha { 4 } else { 3 };
                let required = (image.row_stride as usize)
                    .checked_mul(image.height as usize)
                    .ok_or(WireError::Count)?;
                if image.width == 0
                    || image.height == 0
                    || image.width > 4096
                    || image.height > 4096
                    || image.bits_per_sample != 8
                    || image.channels != expected_channels
                    || image.row_stride < image.width.saturating_mul(image.channels.into())
                    || required != image.data.len()
                    || required > 512 * 1024
                {
                    return Err(WireError::Count);
                }
            }
        }
    }
    Ok(())
}

fn decode_input_layout(
    layout: fb::InputLayout<'_>,
    decoded: &mut InputLayoutSnapshot,
    identities: &mut HashSet<u64>,
) -> Result<(), WireError> {
    let shell_regions = layout.shell_regions();
    let software_keyboard_regions = layout.software_keyboard_regions();
    let windows = layout.windows();
    let visible_surface_ids = layout.visible_surface_ids();
    if shell_regions.is_some_and(|regions| regions.len() > MAX_REGIONS)
        || software_keyboard_regions.is_some_and(|regions| regions.len() > MAX_REGIONS)
        || windows.is_some_and(|regions| regions.len() > MAX_REGIONS)
        || visible_surface_ids.is_some_and(|ids| ids.len() > MAX_SURFACES)
    {
        return Err(WireError::Count);
    }

    decoded.epoch = layout.epoch();
    decoded.flags = layout.flags();
    decoded.shell_regions.clear();
    decoded.software_keyboard_regions.clear();
    decoded.windows.clear();
    decoded.visible_surface_ids.clear();
    identities.clear();

    if let Some(regions) = shell_regions {
        decoded.shell_regions.reserve(regions.len());
        for index in 0..regions.len() {
            decoded
                .shell_regions
                .push(decode_input_rect(regions.get(index))?);
        }
    }

    if let Some(regions) = software_keyboard_regions {
        decoded.software_keyboard_regions.reserve(regions.len());
        for index in 0..regions.len() {
            decoded
                .software_keyboard_regions
                .push(decode_input_rect(regions.get(index))?);
        }
    }

    if let Some(windows) = windows {
        decoded.windows.reserve(windows.len());
        identities.reserve(windows.len());
        let mut previous: Option<(i32, u64)> = None;
        for index in 0..windows.len() {
            let window = windows.get(index);
            if window.object_id() == 0 || window.surface_id() == 0 || window.window_id() == 0 {
                return Err(WireError::Identity);
            }
            if !identities.insert(window.surface_id()) {
                return Err(WireError::Identity);
            }
            if previous.is_some_and(|(z, surface_id)| {
                z < window.z() || (z == window.z() && surface_id < window.surface_id())
            }) {
                return Err(WireError::Ordering);
            }
            let rect = decode_input_rect(window.rect())?;
            let source_rect = decode_input_rect(window.source_rect())?;
            decoded.windows.push(InputWindowRegion {
                object_id: window.object_id(),
                surface_id: window.surface_id(),
                window_id: window.window_id(),
                rect,
                source_rect,
                z: window.z(),
                flags: window.flags(),
            });
            previous = Some((window.z(), window.surface_id()));
        }
    }

    identities.clear();
    if let Some(visible_surface_ids) = visible_surface_ids {
        decoded
            .visible_surface_ids
            .reserve(visible_surface_ids.len());
        identities.reserve(visible_surface_ids.len());
        for index in 0..visible_surface_ids.len() {
            let surface_id = visible_surface_ids.get(index);
            if surface_id == 0 || !identities.insert(surface_id) {
                return Err(WireError::Identity);
            }
            decoded.visible_surface_ids.push(surface_id);
        }
    }

    Ok(())
}

fn decode_input_rect(rect: &fb::WireRect) -> Result<InputRect, WireError> {
    let rect = InputRect {
        x: rect.x(),
        y: rect.y(),
        width: rect.width(),
        height: rect.height(),
    };
    if !rect.x.is_finite()
        || !rect.y.is_finite()
        || !rect.width.is_finite()
        || !rect.height.is_finite()
        || rect.width <= 0.0
        || rect.height <= 0.0
    {
        return Err(WireError::Geometry);
    }
    Ok(rect)
}
