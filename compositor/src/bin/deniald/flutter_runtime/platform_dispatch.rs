//! Inbound platform-message dispatch, scheduled tasks, and engine shutdown.

use super::*;

impl FlutterRuntime {
    pub(super) fn retire_window_close_textures(
        &mut self,
        texture_ids: impl IntoIterator<Item = i64>,
    ) -> Result<(), Box<dyn Error>> {
        for texture_id in texture_ids {
            if self.scene_texture_ids.contains(&texture_id)
                || self.retains_cursor_texture(texture_id)
                || self.screenshot_texture_id == Some(texture_id)
                || self.window_close_texture_leases.retains_texture(texture_id)
                || !self.registered_external_textures.contains(&texture_id)
            {
                continue;
            }
            self.host()
                .engine()
                .unregister_external_texture(texture_id)?;
            self.handler.remove_external_texture_source(texture_id);
            self.pending_frame_texture_ids
                .retain(|pending| *pending != texture_id);
            self.registered_external_textures.remove(&texture_id);
        }
        Ok(())
    }

    pub(super) fn expire_window_close_texture_leases(&mut self) -> Result<(), Box<dyn Error>> {
        let retired = self.window_close_texture_leases.expire(Instant::now());
        if retired.lease_count == 0 {
            return Ok(());
        }
        warn!(
            count = retired.lease_count,
            timeout_ms = WINDOW_CLOSE_LEASE_TIMEOUT.as_millis(),
            "released window close-frame leases after Flutter acknowledgement timeout"
        );
        self.retire_window_close_textures(retired.texture_ids)
    }

    pub(super) fn run_due_tasks(&mut self) -> Result<(), Box<dyn Error>> {
        if self.scheduled_tasks.is_empty() {
            return Ok(());
        }
        // Evaluate one due-set per calloop turn. Tasks which mature while an
        // earlier task runs are picked up by the next zero-timeout turn; this
        // both bounds clock FFI traffic and gives input/DRM sources a fair
        // dispatch edge between long platform-task bursts.
        let now = self.host().engine().current_time_nanos();
        for _ in 0..MAX_PLATFORM_TASKS_PER_DISPATCH {
            let Some(queued) = take_next_due_platform_task(&mut self.scheduled_tasks, now) else {
                break;
            };
            // Release queue capacity before entering Flutter. Running a task
            // may synchronously cause the engine to post another task.
            let QueuedPlatformTask { task, permit, .. } = queued;
            drop(permit);
            self.host().run_scheduled_task(task)?;
        }
        // If more tasks are already due, next_dispatch_timeout() returns zero
        // and calloop gets another turn. This prevents a timer flood from
        // starving input, DRM/session events or graceful shutdown.
        Ok(())
    }

    pub(super) fn handle_platform_message(
        &mut self,
        mut message: PlatformMessage,
    ) -> Result<(), Box<dyn Error>> {
        // Authentication can change earlier in this same engine-event batch.
        // Refresh the clipboard gate before serving any synchronous reply so
        // a lock request cannot be followed by one last unredacted read.
        self.clipboard
            .set_locked(self.authentication.security_gate_locked());
        if message.channel.as_bytes() == text_input::CHANNEL.to_bytes() {
            let host = self
                .host
                .as_ref()
                .expect("Flutter runtime is shutting down");
            let response = self.text_input.handle_platform_message(&message.data);
            host.respond(&mut message, response)?;
            return Ok(());
        }
        if message.channel.as_bytes() == platform::CHANNEL.to_bytes() {
            let response = self.platform.handle_platform_message(&message.data);
            self.host().respond(&mut message, &response)?;
            return Ok(());
        }
        if message.channel.as_bytes() == mouse_cursor::CHANNEL.to_bytes() {
            let response = self.mouse_cursor.handle_platform_message(&message.data);
            self.host().respond(&mut message, &response)?;
            return Ok(());
        }
        if message.channel == crate::clipboard::CONTROL_CHANNEL {
            let response = self.clipboard.handle_control_packet(&message.data);
            self.host().respond(&mut message, &response)?;
            return Ok(());
        }

        // Release Flutter's request handle before dispatching any
        // asynchronous Denial response. The shell receives request/reply
        // data on its dedicated ordered native-to-Flutter channel.
        self.host().respond(&mut message, &[])?;
        if message.channel.as_bytes() == crate::authentication::CHANNEL.to_bytes() {
            let result = self.authentication.handle_packet(&message.data);
            // Authentication responses can contain credentials. The
            // controller has moved them into its scrub-on-drop buffer, so
            // erase the engine-owned copy before releasing this message.
            message.data.fill(0);
            if let Err(error) = result {
                warn!(%error, "rejected Denial authentication request from Flutter");
            }
        } else if message.channel == wire::TO_NATIVE_CHANNEL {
            let host = self
                .host
                .as_ref()
                .expect("Flutter runtime is shutting down");
            match self.wire.handle(&message.data) {
                Ok(Some(response)) => {
                    host.engine()
                        .send_platform_message(wire::TO_FLUTTER_CHANNEL, response)?;
                }
                Ok(None) => {}
                Err(error) => warn!(%error, "rejected Denial wire message from Flutter"),
            }
        } else if message.channel.as_bytes() == system_command::CHANNEL.to_bytes() {
            if self.authentication.security_gate_locked() {
                warn!("rejected Denial system command while the session is locked");
            } else if let Err(error) = self.system_commands.handle(&message.data) {
                warn!(%error, "rejected Denial system command from Flutter");
            }
        } else if message.channel.as_bytes() == AUDIO_CHANNEL.to_bytes() {
            match crate::system_controls::decode_audio_request(&message.data) {
                Ok(request) if self.pending_audio_requests.len() < MAX_PENDING_AUDIO_REQUESTS => {
                    self.pending_audio_requests.push_back(request);
                }
                Ok(_) => warn!(
                    limit = MAX_PENDING_AUDIO_REQUESTS,
                    "dropped excess Denial audio request from Flutter"
                ),
                Err(error) => warn!(%error, "rejected Denial audio request from Flutter"),
            }
        } else if message.channel.as_bytes() == BRIGHTNESS_CHANNEL.to_bytes() {
            match crate::system_controls::decode_brightness_request(&message.data) {
                Ok(request)
                    if self.pending_brightness_requests.len() < MAX_PENDING_BRIGHTNESS_REQUESTS =>
                {
                    self.pending_brightness_requests.push_back(request);
                }
                Ok(_) => warn!(
                    limit = MAX_PENDING_BRIGHTNESS_REQUESTS,
                    "dropped excess Denial brightness request from Flutter"
                ),
                Err(error) => warn!(%error, "rejected Denial brightness request from Flutter"),
            }
        } else if message.channel.as_bytes() == crate::ui_development::CONTROL_CHANNEL.to_bytes() {
            match crate::ui_development::decode_control_packet(&message.data) {
                Ok(command)
                    if self.pending_ui_development_commands.len()
                        < MAX_PENDING_UI_DEVELOPMENT_COMMANDS =>
                {
                    self.pending_ui_development_commands.push_back(command);
                }
                Ok(_) => warn!(
                    limit = MAX_PENDING_UI_DEVELOPMENT_COMMANDS,
                    "dropped excess Denial UI development command from Flutter"
                ),
                Err(error) => {
                    warn!(%error, "rejected Denial UI development command from Flutter");
                }
            }
        } else if message.channel.as_bytes() == idle_policy::CHANNEL.to_bytes() {
            match idle_policy::decode_timeout(&message.data) {
                Ok(timeout) => self.pending_idle_dpms_timeout = Some(timeout),
                Err(error) => warn!(%error, "rejected Denial idle policy from Flutter"),
            }
        } else if message.channel.as_bytes() == idle_policy::DISPLAY_POWER_CHANNEL.to_bytes() {
            match idle_policy::decode_display_power_off(&message.data) {
                Ok(()) => self.pending_dpms_off = true,
                Err(error) => warn!(%error, "rejected Denial display-power request from Flutter"),
            }
        } else if message.channel.as_bytes() == WINDOW_CLOSE_COMPLETE_CHANNEL.to_bytes() {
            match decode_window_close_complete(&message.data) {
                Some(window_id) => {
                    let retired = self.window_close_texture_leases.complete(window_id);
                    self.retire_window_close_textures(retired.texture_ids)?;
                }
                None => warn!("rejected malformed window close completion from Flutter"),
            }
        } else if message.channel.as_bytes() == CURSOR_PRESENTED_CHANNEL.to_bytes() {
            match decode_cursor_presented(&message.data) {
                Some(epoch) if self.acknowledge_cursor_epoch(epoch)? => {}
                Some(epoch) => warn!(epoch, "rejected future cursor presentation epoch"),
                None => warn!("rejected malformed cursor presentation acknowledgement"),
            }
        }
        Ok(())
    }

    pub(super) fn host(&self) -> &EngineHost {
        // shutdown() consumes FlutterRuntime, and shutdown_engine() is only
        // called by that consuming path or Drop. Engine callbacks retain the
        // separate FlutterGlHandler Arc and never call this accessor, so a
        // late callback cannot observe the transient host=None state.
        self.host
            .as_ref()
            .expect("Flutter runtime is shutting down")
    }

    pub fn shutdown(mut self) -> Result<(), EngineError> {
        self.shutdown_engine()
    }

    pub(super) fn shutdown_engine(&mut self) -> Result<(), EngineError> {
        // No queued task may be run once host shutdown begins. Dropping the
        // permits also releases the producer-side bound before engine joins.
        self.scheduled_tasks.clear();
        let Some(host) = self.host.take() else {
            return Ok(());
        };
        for texture_id in self.registered_external_textures.drain() {
            match host.engine().unregister_external_texture(texture_id) {
                Ok(()) => self.handler.remove_external_texture_source(texture_id),
                Err(error) => {
                    // Keep the source alive until engine shutdown. If that
                    // also fails, EngineHost deliberately retains its
                    // callback Arc and this resource with it.
                    error!(%error, texture_id, "failed to unregister Flutter external texture");
                }
            }
        }
        let pending_batons = self.handler.take_pending_vsync_batons();
        if !pending_batons.is_empty() {
            let now = host.engine().current_time_nanos();
            let interval = u64::try_from(self.frame_interval.as_nanos()).unwrap_or(u64::MAX);
            for baton in &pending_batons {
                if let Err(error) =
                    host.engine()
                        .on_vsync(*baton, now, now.saturating_add(interval))
                {
                    error!(%error, baton, "failed to fulfil Flutter vsync during shutdown");
                }
            }
            debug!(
                count = pending_batons.len(),
                "fulfilled pending Flutter vsync batons before shutdown"
            );
        }
        let result = host.shutdown();
        if result.is_ok() {
            self.handler.destroy_targets();
        } else {
            // The leaked EngineHost owns another Arc to this handler. Do not
            // destroy GL targets or external texture sources that an engine
            // worker may still reach after a failed shutdown.
            error!("retaining Flutter GL resources after failed engine shutdown");
        }
        result
    }
}
