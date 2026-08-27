//! Typed shell service commands and outbound platform messages.

use super::*;

impl FlutterRuntime {
    pub fn send_platform_brightness(
        &mut self,
        brightness: denial_core::portal_protocol::DesktopThemeBrightness,
    ) -> Result<(), Box<dyn Error>> {
        let message = serde_json::to_vec(&serde_json::json!({
            "textScaleFactor": 1.0,
            "alwaysUse24HourFormat": false,
            "platformBrightness": brightness.flutter_name(),
        }))?;
        self.host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine()
            .send_platform_message(FLUTTER_SETTINGS_CHANNEL, &message)?;
        Ok(())
    }

    pub fn take_input_layout_update(&mut self) -> Option<wire::InputLayoutSnapshot> {
        self.wire.take_input_layout_update()
    }

    pub fn recycle_input_layout(&mut self, layout: wire::InputLayoutSnapshot) {
        self.wire.recycle_input_layout(layout);
    }

    pub fn drain_window_commands(&mut self) -> impl Iterator<Item = wire::WindowCommand> + '_ {
        self.wire.drain_window_commands()
    }

    pub fn drain_keyboard_commands(&mut self) -> impl Iterator<Item = wire::KeyboardCommand> + '_ {
        self.wire.drain_keyboard_commands()
    }

    pub fn take_text_input_state(&mut self) -> Option<(u64, TextInputSnapshot)> {
        self.text_input
            .take_state_change()
            .map(|snapshot| (self.generation, snapshot))
    }

    pub fn dispatch_input_method_to_flutter(
        &mut self,
        generation: u64,
        client_id: i64,
        transaction: &InputMethodTransaction,
    ) -> Result<bool, Box<dyn Error>> {
        if generation != self.generation {
            return Ok(false);
        }
        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let messages = self.text_input.apply_input_method(client_id, transaction);
        let delivered = !messages.is_empty();
        for message in messages {
            engine.send_platform_message(text_input::CHANNEL, message)?;
        }
        Ok(delivered)
    }

    pub fn drain_notification_commands(
        &mut self,
    ) -> impl Iterator<Item = wire::NotificationCommand> + '_ {
        self.wire.drain_notification_commands()
    }

    pub fn drain_xembed_tray_commands(
        &mut self,
    ) -> impl Iterator<Item = crate::xembed_tray::XEmbedTrayCommand> + '_ {
        self.wire.drain_xembed_tray_commands()
    }

    pub fn drain_settings_commands(&mut self) -> impl Iterator<Item = wire::SettingsCommand> + '_ {
        self.wire.drain_settings_commands()
    }

    pub fn take_theme_accent(&mut self) -> Option<u32> {
        self.wire.take_theme_accent()
    }

    pub fn take_work_area_update(&mut self) -> Option<crate::options::WorkAreaOptions> {
        self.wire.take_work_area_update()
    }

    pub fn take_logout_requested(&mut self) -> bool {
        self.system_commands.take_logout_requested()
    }

    pub fn take_application_launch(&mut self) -> Option<system_command::PendingApplicationLaunch> {
        self.system_commands.take_application_launch()
    }

    pub fn start_application(
        &mut self,
        launch: system_command::PendingApplicationLaunch,
        activation_token: Option<&str>,
    ) -> Result<(), system_command::DispatchError> {
        self.system_commands
            .start_application(launch, activation_token)
    }

    pub fn start_shortcut_application(
        &mut self,
        arguments: Vec<String>,
        shell: bool,
        desktop_file_id: Option<&str>,
        activation_token: Option<&str>,
    ) -> Result<(), system_command::DispatchError> {
        self.system_commands.start_shortcut_application(
            arguments,
            shell,
            desktop_file_id,
            activation_token,
        )
    }

    pub fn take_screenshot_requested(&mut self) -> Option<system_command::ScreenshotRequest> {
        self.system_commands.take_screenshot_requested()
    }

    pub fn take_screenshot_prepared(&mut self) -> Option<std::num::NonZeroU64> {
        self.system_commands.take_screenshot_prepared()
    }

    pub fn take_screenshot_cancelled(&mut self) -> Option<std::num::NonZeroU64> {
        self.system_commands.take_screenshot_cancelled()
    }

    pub fn take_idle_dpms_timeout(&mut self) -> Option<Option<Duration>> {
        self.pending_idle_dpms_timeout.take()
    }

    pub fn take_dpms_off_requested(&mut self) -> bool {
        std::mem::take(&mut self.pending_dpms_off)
    }

    pub fn take_mouse_cursor_request(&mut self) -> Option<&'static str> {
        self.mouse_cursor.take_request()
    }

    pub fn send_window_action(
        &mut self,
        window_id: u64,
        action: wire::WindowAction,
    ) -> Result<(), Box<dyn Error>> {
        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let event = self.wire.encode_window_action(window_id, action)?;
        engine.send_platform_message(wire::TO_FLUTTER_CHANNEL, event)?;
        Ok(())
    }

    pub fn send_window_activated(&mut self, window_id: u64) -> Result<(), Box<dyn Error>> {
        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let event = self.wire.encode_window_activated(window_id)?;
        engine.send_platform_message(wire::TO_FLUTTER_CHANNEL, event)?;
        Ok(())
    }

    pub fn send_window_placement(
        &mut self,
        placement: wire::WindowPlacement,
    ) -> Result<(), Box<dyn Error>> {
        let event = self.wire.encode_window_placement(placement)?;
        self.host()
            .engine()
            .send_platform_message(wire::TO_FLUTTER_CHANNEL, &event)?;
        Ok(())
    }

    pub fn send_shell_action(
        &mut self,
        action: wire::ShellAction,
        monitor_id: Option<i64>,
    ) -> Result<(), Box<dyn Error>> {
        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let event = self.wire.encode_shell_action(action, monitor_id)?;
        engine.send_platform_message(wire::TO_FLUTTER_CHANNEL, event)?;
        Ok(())
    }

    pub fn register_screenshot_texture(
        &mut self,
        dmabuf: Dmabuf,
        revision: u64,
    ) -> Result<i64, Box<dyn Error>> {
        if self.screenshot_texture_id.is_some() {
            return Err("a screenshot texture is already registered".into());
        }
        let texture_id = (1..=i64::MAX)
            .rev()
            .find(|texture_id| !self.registered_external_textures.contains(texture_id))
            .ok_or("Flutter external texture identifiers are exhausted")?;
        self.host().engine().register_external_texture(texture_id)?;
        self.registered_external_textures.insert(texture_id);
        self.changed_texture_scratch.clear();
        self.handler.set_external_texture_sources(
            [ExternalTextureFrame::from_owned_dmabuf(
                texture_id, dmabuf, revision,
            )],
            &mut self.changed_texture_scratch,
        );
        self.stage_changed_textures();
        self.screenshot_texture_id = Some(texture_id);
        Ok(texture_id)
    }

    pub fn unregister_screenshot_texture(&mut self, texture_id: i64) -> Result<(), Box<dyn Error>> {
        if self.screenshot_texture_id != Some(texture_id) {
            return Err("screenshot texture identity does not match the active texture".into());
        }
        self.host()
            .engine()
            .unregister_external_texture(texture_id)?;
        self.handler.remove_external_texture_source(texture_id);
        self.pending_frame_texture_ids
            .retain(|pending| *pending != texture_id);
        self.registered_external_textures.remove(&texture_id);
        self.screenshot_texture_id = None;
        Ok(())
    }

    pub fn send_screenshot_action(
        &mut self,
        action: wire::ShellAction,
        request_id: u64,
        texture_id: Option<i64>,
    ) -> Result<(), Box<dyn Error>> {
        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let event = self
            .wire
            .encode_screenshot_action(action, request_id, texture_id)?;
        engine.send_platform_message(wire::TO_FLUTTER_CHANNEL, event)?;
        Ok(())
    }

    pub fn send_cursor_shape(&mut self, shape: &str) -> Result<(), Box<dyn Error>> {
        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let update = self.wire.encode_cursor_shape(shape)?;
        engine.send_platform_message(wire::TO_FLUTTER_CHANNEL, update)?;
        Ok(())
    }

    pub fn send_cursor_position(&mut self, x: f64, y: f64) -> Result<(), Box<dyn Error>> {
        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let update = self.wire.encode_cursor_position(x, y)?;
        engine.send_platform_message(wire::TO_FLUTTER_CHANNEL, update)?;
        Ok(())
    }

    pub fn publish_text_input_state(
        &mut self,
        active: bool,
        input_panel_visible: bool,
        legacy: bool,
        content_hint: u32,
        content_purpose: u32,
        activation_serial: u64,
    ) -> Result<(), Box<dyn Error>> {
        let state = (
            active,
            input_panel_visible,
            legacy,
            content_hint,
            content_purpose,
            activation_serial,
        );
        if self.published_text_input_state == Some(state) {
            return Ok(());
        }
        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let update = self.wire.encode_text_input_state(
            active,
            input_panel_visible,
            legacy,
            content_hint,
            content_purpose,
        )?;
        engine.send_platform_message(wire::TO_FLUTTER_CHANNEL, update)?;
        self.published_text_input_state = Some(state);
        Ok(())
    }

    pub fn send_notification_event(
        &mut self,
        event: &crate::notification_server::NotificationEvent,
    ) -> Result<(), Box<dyn Error>> {
        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let update = self.wire.encode_notification_event(event)?;
        engine.send_platform_message(wire::TO_FLUTTER_CHANNEL, update)?;
        Ok(())
    }

    pub fn send_xembed_tray_event(
        &mut self,
        event: &crate::xembed_tray::XEmbedTrayEvent,
    ) -> Result<(), Box<dyn Error>> {
        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let update = self.wire.encode_xembed_tray_event(event)?;
        engine.send_platform_message(wire::TO_FLUTTER_CHANNEL, update)?;
        Ok(())
    }

    pub fn send_settings_document_response(
        &mut self,
        request_id: u64,
        revision: u64,
        document: Option<&str>,
        error: Option<&str>,
    ) -> Result<(), Box<dyn Error>> {
        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let response = self
            .wire
            .encode_settings_document_response(request_id, revision, document, error)?;
        engine.send_platform_message(wire::TO_FLUTTER_CHANNEL, response)?;
        Ok(())
    }

    pub fn send_input_device_capabilities_response(
        &mut self,
        request_id: u64,
        revision: u64,
        has_touchpad: bool,
        touchpad: &crate::settings::TouchpadSettings,
        error: Option<&str>,
    ) -> Result<(), Box<dyn Error>> {
        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let response = self.wire.encode_input_device_capabilities_response(
            request_id,
            revision,
            has_touchpad,
            touchpad,
            error,
        )?;
        engine.send_platform_message(wire::TO_FLUTTER_CHANNEL, response)?;
        Ok(())
    }

    pub fn send_keyboard_settings_response(
        &mut self,
        request_id: u64,
        revision: u64,
        keyboard: &crate::settings::KeyboardSettings,
        display_names: &[String],
        active_layout: usize,
        error: Option<&str>,
    ) -> Result<(), Box<dyn Error>> {
        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let response = self.wire.encode_keyboard_settings_response(
            request_id,
            revision,
            keyboard,
            display_names,
            active_layout,
            error,
        )?;
        engine.send_platform_message(wire::TO_FLUTTER_CHANNEL, response)?;
        Ok(())
    }

    pub fn send_shortcut_configuration_response(
        &mut self,
        request_id: u64,
        revision: u64,
        shortcuts: &[crate::native_shortcut::ShortcutBinding],
        supported_inputs: &[crate::native_shortcut::ShortcutInputDefinition],
        error: Option<&str>,
    ) -> Result<(), Box<dyn Error>> {
        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let response = self.wire.encode_shortcut_configuration_response(
            request_id,
            revision,
            shortcuts,
            supported_inputs,
            error,
        )?;
        engine.send_platform_message(wire::TO_FLUTTER_CHANNEL, response)?;
        Ok(())
    }

    pub fn send_shortcut_validation_response(
        &mut self,
        request_id: u64,
        revision: u64,
        validation: &crate::native_shortcut::ShortcutValidation,
    ) -> Result<(), Box<dyn Error>> {
        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let response = self
            .wire
            .encode_shortcut_validation_response(request_id, revision, validation)?;
        engine.send_platform_message(wire::TO_FLUTTER_CHANNEL, response)?;
        Ok(())
    }

    pub fn send_system_control_event(
        &mut self,
        event: &crate::system_controls::SystemControlEvent,
    ) -> Result<(), Box<dyn Error>> {
        match event {
            crate::system_controls::SystemControlEvent::AudioLevel {
                level,
                request_serial,
            } => {
                let mut packet = [0u8; 5];
                packet[0] = (level.clamp(0.0, 1.0) * 100.0).round() as u8;
                packet[1..].copy_from_slice(&request_serial.to_le_bytes());
                self.host()
                    .engine()
                    .send_platform_message(AUDIO_STATE_CHANNEL, &packet)?;
            }
            crate::system_controls::SystemControlEvent::AudioStreams(streams) => {
                let payload_size = streams.iter().try_fold(size_of::<u32>(), |size, stream| {
                    size.checked_add(8)?.checked_add(stream.name.len())
                });
                let Some(payload_size) = payload_size else {
                    return Err("audio stream-state packet size overflow".into());
                };
                let mut packet = Vec::with_capacity(payload_size);
                packet.extend_from_slice(
                    &u32::try_from(streams.len())
                        .map_err(|_| "too many audio streams for the platform packet")?
                        .to_le_bytes(),
                );
                for stream in streams {
                    let name = stream.name.as_bytes();
                    let name_length = u16::try_from(name.len())
                        .map_err(|_| "audio stream name exceeds the platform packet limit")?;
                    packet.extend_from_slice(&stream.id.to_le_bytes());
                    packet.push(stream.level_percent.min(100));
                    packet.push(u8::from(stream.muted));
                    packet.extend_from_slice(&name_length.to_le_bytes());
                    packet.extend_from_slice(name);
                }
                self.host()
                    .engine()
                    .send_platform_message(AUDIO_STREAMS_STATE_CHANNEL, &packet)?;
            }
            crate::system_controls::SystemControlEvent::BrightnessLevel { monitor_id, level } => {
                let mut packet = [0u8; 9];
                packet[..8].copy_from_slice(&monitor_id.to_le_bytes());
                packet[8] = (level.clamp(0.0, 1.0) * 100.0).round() as u8;
                self.host()
                    .engine()
                    .send_platform_message(BRIGHTNESS_STATE_CHANNEL, &packet)?;
            }
        }
        Ok(())
    }

    pub fn drain_audio_requests(
        &mut self,
    ) -> impl Iterator<Item = crate::system_controls::AudioRequest> + '_ {
        self.pending_audio_requests.drain(..)
    }

    pub fn drain_brightness_requests(
        &mut self,
    ) -> impl Iterator<Item = crate::system_controls::BrightnessRequest> + '_ {
        self.pending_brightness_requests.drain(..)
    }

    pub fn drain_ui_development_commands(
        &mut self,
    ) -> impl Iterator<Item = crate::ui_development::UiDevelopmentCommand> + '_ {
        self.pending_ui_development_commands.drain(..)
    }

    pub fn take_vm_service_uri(&mut self) -> Option<String> {
        self.pending_vm_service_uri.take()
    }

    pub fn publish_ui_development_state(&mut self, packet: &[u8]) -> Result<(), Box<dyn Error>> {
        self.host()
            .engine()
            .send_platform_message(crate::ui_development::STATE_CHANNEL, packet)?;
        Ok(())
    }

    pub fn authentication(&self) -> Arc<crate::authentication::AuthenticationController> {
        Arc::clone(&self.authentication)
    }

    pub fn clipboard(&self) -> crate::clipboard::ClipboardManager {
        self.clipboard.clone()
    }

    pub fn publish_clipboard_state(&mut self) -> Result<(), Box<dyn Error>> {
        let revision = self.clipboard.revision();
        if revision == self.published_clipboard_revision {
            return Ok(());
        }
        let packet = self.clipboard.state_packet();
        self.host()
            .engine()
            .send_platform_message(crate::clipboard::STATE_CHANNEL, &packet)?;
        self.published_clipboard_revision = revision;
        Ok(())
    }
}
