//! Flutter engine startup, input ingress, lifecycle, and task reception.

use super::*;

impl FlutterRuntime {
    #[allow(clippy::too_many_arguments)]
    pub fn start<'a>(
        shared_context: &EGLContext,
        output_pools: impl IntoIterator<Item = OutputRenderTargetPool<'a>>,
        snapshot: &TopologySnapshot,
        atlas: &AtlasPlan,
        refresh_millihz: u32,
        offscreen_blit: bool,
        factory: &FlutterRuntimeFactory,
        events: Sender<RuntimeEvent>,
        authentication: Arc<crate::authentication::AuthenticationController>,
        clipboard: crate::clipboard::ClipboardManager,
        work_area: crate::options::WorkAreaOptions,
        generation: u64,
        wayland_display: Option<OsString>,
        x11_display: Option<OsString>,
        output_control_socket: Option<OsString>,
    ) -> Result<Self, Box<dyn Error>> {
        let wire = WireBridge::new(snapshot, atlas, work_area)?;
        let render_outputs = atlas
            .render_outputs(snapshot)
            .ok_or("Flutter render outputs do not match the topology snapshot")?;
        let runtime_render_outputs = render_outputs
            .iter()
            .map(|output| {
                let atlas_output = atlas
                    .outputs
                    .iter()
                    .find(|candidate| candidate.id == output.output_id)
                    .expect("validated render output is absent from its atlas");
                let snapshot_output = snapshot
                    .outputs
                    .iter()
                    .find(|candidate| candidate.id == output.output_id)
                    .expect("validated render output is absent from its topology");
                RuntimeRenderOutput {
                    output_id: output.output_id,
                    render_view_id: output.render_view_id,
                    configuration_generation: output.configuration_generation,
                    target_size: output.target_size,
                    transform: snapshot_output.transform,
                    logical_x: atlas_output.logical_rect.x - atlas.logical_origin.0,
                    logical_y: atlas_output.logical_rect.y - atlas.logical_origin.1,
                    logical_width: atlas_output.logical_rect.width,
                    logical_height: atlas_output.logical_rect.height,
                }
            })
            .collect::<Vec<_>>();
        let render_context = egl_context::create_shared_context("Flutter raster", shared_context)?;
        let resource_context =
            egl_context::create_shared_context("Flutter resource", shared_context)?;
        let handler = FlutterGlHandler::new(
            render_context,
            resource_context,
            output_pools,
            atlas.pixel_size,
            factory.project.renderer_backend,
            offscreen_blit,
            events,
            generation,
        )?;
        let host = EngineHost::start_with_library_and_priority_setter(
            &factory.project,
            handler.clone(),
            Arc::clone(&factory.library),
            Some(crate::cpu_scheduling::set_flutter_thread_priority),
        )?;
        if let Some(locale) = locale_from_environment(|name| std::env::var(name).ok()) {
            host.engine()
                .update_locales(std::slice::from_ref(&locale))?;
        }
        let refresh_hz = f64::from(refresh_millihz) / 1_000.0;
        let device_pixel_ratio = f64::from(atlas.engine_scale_120) / f64::from(SCALE_BASE);
        host.engine().notify_displays(
            sys::FlutterEngineDisplaysUpdateType_kFlutterEngineDisplaysUpdateTypeStartup,
            &[sys::FlutterEngineDisplay {
                struct_size: mem::size_of::<sys::FlutterEngineDisplay>(),
                display_id: 0,
                single_display: true,
                refresh_rate: refresh_hz,
                width: atlas.pixel_size.width as usize,
                height: atlas.pixel_size.height as usize,
                device_pixel_ratio,
            }],
        )?;
        host.engine()
            .send_window_metrics(&sys::FlutterWindowMetricsEvent {
                struct_size: mem::size_of::<sys::FlutterWindowMetricsEvent>(),
                width: atlas.pixel_size.width as usize,
                height: atlas.pixel_size.height as usize,
                pixel_ratio: device_pixel_ratio,
                display_id: 0,
                view_id: 0,
                ..sys::FlutterWindowMetricsEvent::default()
            })?;
        let render_outputs = render_outputs
            .into_iter()
            .map(|output| RenderOutput {
                render_view_id: output.render_view_id.get(),
                configuration_generation: output.configuration_generation,
                source_physical_x: f64::from(output.source_rect.x),
                source_physical_y: f64::from(output.source_rect.y),
                source_physical_width: f64::from(output.source_rect.width),
                source_physical_height: f64::from(output.source_rect.height),
                target_width: output.target_size.width as usize,
                target_height: output.target_size.height as usize,
                scale_120: output.scale_120,
                source_to_target_transform: RenderOutputTransform {
                    scale_x: output.source_to_target_transform.scale_x,
                    skew_x: output.source_to_target_transform.skew_x,
                    translate_x: output.source_to_target_transform.translate_x,
                    skew_y: output.source_to_target_transform.skew_y,
                    scale_y: output.source_to_target_transform.scale_y,
                    translate_y: output.source_to_target_transform.translate_y,
                },
            })
            .collect::<Vec<_>>();
        host.engine().set_render_outputs(&render_outputs)?;
        let render_output_count = render_outputs.len();
        let frame_interval = Duration::from_secs_f64(1.0 / refresh_hz.max(1.0));
        info!(
            bundle = %factory.bundle.display(),
            refresh_hz,
            width = atlas.pixel_size.width,
            height = atlas.pixel_size.height,
            device_pixel_ratio,
            native_fence = true,
            resource_cache_max_mib =
                factory.project.resource_cache_max_bytes_threshold / (1024 * 1024),
            output_targets = render_outputs.len(),
            "started Rust Flutter embedder with native physical-output raster targets"
        );
        Ok(Self {
            host: Some(host),
            handler,
            wire,
            text_input: text_input::TextInputPlugin::default(),
            platform: platform::PlatformPlugin::new(clipboard.clone()),
            mouse_cursor: mouse_cursor::MouseCursorPlugin::default(),
            clipboard,
            published_clipboard_revision: 0,
            system_commands: system_command::SystemCommandHandler::new(
                wayland_display,
                x11_display,
                output_control_socket,
            ),
            authentication,
            pending_audio_requests: VecDeque::with_capacity(16),
            pending_brightness_requests: VecDeque::with_capacity(16),
            pending_ui_development_commands: VecDeque::with_capacity(8),
            pending_idle_dpms_timeout: None,
            pending_dpms_off: false,
            pending_vm_service_uri: None,
            generation,
            scheduled_tasks: BinaryHeap::with_capacity(INITIAL_PLATFORM_TASK_BATCH_CAPACITY),
            platform_task_scratch: Vec::with_capacity(INITIAL_PLATFORM_TASK_BATCH_CAPACITY),
            next_platform_task_order: 0,
            registered_external_textures: HashSet::new(),
            scene_texture_ids: HashSet::new(),
            render_outputs: runtime_render_outputs,
            render_output_configuration: render_outputs,
            output_rotation_animation: None,
            pending_output_geometry: None,
            render_output_ffi_scratch: RenderOutputFfiScratch::with_capacity(render_output_count),
            texture_output_membership: HashMap::new(),
            pending_output_updates: BTreeMap::new(),
            changed_texture_scratch: Vec::new(),
            render_view_scratch: Vec::with_capacity(render_output_count),
            render_texture_scratch: Vec::new(),
            screenshot_texture_id: None,
            pending_screenshot_frame: None,
            scene_texture_id_scratch: Vec::new(),
            window_close_texture_leases: WindowCloseTextureLeases::default(),
            pending_frame_texture_ids: Vec::new(),
            pointer_event_scratch: Vec::with_capacity(64),
            key_event_scratch: Vec::with_capacity(160),
            device_pixel_ratio,
            frame_interval,
            kms_frame_clock_enabled: false,
            outputs_visible: None,
            published_text_input_state: None,
            frame_ready_observed: false,
            last_pointer_timestamp_micros: 0,
        })
    }

    /// Delivers one bounded input batch and leaves the rest queued in order.
    /// Motion is already latest-only within each semantic tail; limiting the
    /// batch keeps an input flood from monopolizing the compositor between
    /// physical display deadlines without dropping transitions.
    pub fn process_input_batch(&mut self, input: &mut InputQueue) -> Result<bool, Box<dyn Error>> {
        if input.events.is_empty() {
            return Ok(false);
        }
        let engine_now = usize::try_from(self.host().engine().current_time_nanos() / 1_000)
            .unwrap_or(usize::MAX);
        let mut timestamp = engine_now.max(self.last_pointer_timestamp_micros.saturating_add(1));
        // The engine consumes this slice synchronously. Reuse its backing
        // allocation because libinput commonly wakes us once per pointer
        // sample, which otherwise causes one allocator round-trip per event.
        let mut pointer_events = mem::take(&mut self.pointer_event_scratch);
        pointer_events.clear();
        pointer_events.reserve(
            input
                .events
                .len()
                .min(MAX_INPUT_EVENTS_PER_COMPOSITOR_ITERATION),
        );
        let mut key_message = mem::take(&mut self.key_event_scratch);
        for _ in 0..MAX_INPUT_EVENTS_PER_COMPOSITOR_ITERATION {
            let Some(event) = input.events.pop_front() else {
                break;
            };
            match event {
                InputRecord::Pointer(event) => {
                    pointer_events.push(sys::FlutterPointerEvent {
                        struct_size: mem::size_of::<sys::FlutterPointerEvent>(),
                        phase: event.phase,
                        timestamp,
                        x: event.x,
                        y: event.y,
                        device: event.device,
                        signal_kind: event.signal_kind,
                        scroll_delta_x: flutter_physical_scroll_delta(
                            event.scroll_x,
                            self.device_pixel_ratio,
                        ),
                        scroll_delta_y: flutter_physical_scroll_delta(
                            event.scroll_y,
                            self.device_pixel_ratio,
                        ),
                        pan_x: flutter_physical_scroll_delta(event.pan_x, self.device_pixel_ratio),
                        pan_y: flutter_physical_scroll_delta(event.pan_y, self.device_pixel_ratio),
                        scale: event.scale,
                        rotation: event.rotation,
                        device_kind: event.device_kind,
                        buttons: event.buttons,
                        view_id: 0,
                        ..sys::FlutterPointerEvent::default()
                    });
                    self.last_pointer_timestamp_micros = timestamp;
                    timestamp = timestamp.saturating_add(1);
                }
                InputRecord::Keyboard(event) => {
                    self.flush_pointer_events(&mut pointer_events)?;
                    self.send_flutter_keyboard_record(event, &mut key_message)?;
                }
            }
        }
        self.flush_pointer_events(&mut pointer_events)?;
        self.pointer_event_scratch = pointer_events;
        self.key_event_scratch = key_message;
        Ok(!input.events.is_empty())
    }

    /// Retires raster-completion wakeups before ordinary Flutter messages.
    /// The raster thread publishes the completed target before sending this
    /// event, so observing it here makes that target available to the KMS lane
    /// without running platform tasks, settings, or other callback traffic.
    pub fn observe_frame_ready_events(&mut self, events: &mut Vec<RuntimeEvent>) {
        let generation = self.generation;
        let mut observed = false;
        events.retain(|event| match event {
            RuntimeEvent::FrameReady {
                generation: event_generation,
            } if *event_generation == generation => {
                observed = true;
                false
            }
            _ => true,
        });
        if observed {
            self.handler.acknowledge_frame_ready();
            self.frame_ready_observed = true;
        }
    }

    pub(super) fn send_flutter_keyboard_record(
        &mut self,
        event: KeyboardRecord,
        key_message: &mut Vec<u8>,
    ) -> Result<(), Box<dyn Error>> {
        encode_key_event(event, key_message);
        self.host()
            .engine()
            .send_platform_message(FLUTTER_KEY_EVENT_CHANNEL, key_message)?;
        if event.pressed
            && !(event.unicode != 0 && event.modifiers & (GLFW_MOD_CONTROL | GLFW_MOD_ALT) != 0)
        {
            let engine = self
                .host
                .as_ref()
                .expect("Flutter runtime is shutting down")
                .engine();
            let text_messages = self.text_input.on_key_pressed(event.keycode, event.unicode);
            for message in text_messages {
                engine.send_platform_message(text_input::CHANNEL, message)?;
            }
        }
        Ok(())
    }

    pub(super) fn flush_pointer_events(
        &self,
        events: &mut Vec<sys::FlutterPointerEvent>,
    ) -> Result<(), EngineError> {
        if !events.is_empty() {
            self.host().engine().send_pointer_events(events)?;
            events.clear();
        }
        Ok(())
    }

    pub fn process_events(
        &mut self,
        events: impl IntoIterator<Item = RuntimeEvent>,
    ) -> Result<(), Box<dyn Error>> {
        for event in events {
            match event {
                RuntimeEvent::PlatformTasksReady { generation }
                    if generation == self.generation =>
                {
                    self.receive_platform_tasks()?;
                }
                RuntimeEvent::Engine {
                    generation,
                    event: EngineEvent::Vsync(baton),
                } if generation == self.generation => {
                    if !self.kms_frame_clock_enabled {
                        if !self.handler.try_request_frame() {
                            return Err(
                                "Flutter requested a timed vsync while its producer was busy"
                                    .into(),
                            );
                        }
                        self.collect_external_texture_updates();
                        if let Err(error) = self.publish_external_texture_transaction() {
                            self.handler.cancel_requested_frame();
                            return Err(error);
                        }
                        if let Err(error) = self
                            .host()
                            .engine()
                            .on_vsync_after(baton, self.frame_interval)
                        {
                            self.handler.cancel_requested_frame();
                            return Err(error.into());
                        }
                        self.handler.complete_vsync(baton);
                    }
                }
                RuntimeEvent::Engine {
                    generation,
                    event: EngineEvent::PlatformMessage(message),
                } if generation == self.generation => {
                    self.handle_platform_message(message)?;
                }
                RuntimeEvent::FrameReady { generation } if generation == self.generation => {
                    self.handler.acknowledge_frame_ready();
                    self.frame_ready_observed = true;
                }
                RuntimeEvent::QueueOverflow { generation, queue }
                    if generation == self.generation =>
                {
                    return Err(format!("Flutter {queue} queue exceeded its safety limit").into());
                }
                RuntimeEvent::FatalRender { generation, reason }
                    if generation == self.generation =>
                {
                    return Err(reason.into());
                }
                RuntimeEvent::VmServiceUri { generation, uri } if generation == self.generation => {
                    self.pending_vm_service_uri = Some(uri);
                }
                RuntimeEvent::Engine { .. }
                | RuntimeEvent::PlatformTasksReady { .. }
                | RuntimeEvent::QueueOverflow { .. }
                | RuntimeEvent::FatalRender { .. }
                | RuntimeEvent::VmServiceUri { .. }
                | RuntimeEvent::FrameReady { .. }
                | RuntimeEvent::SampledBuffersReady { .. } => {}
            }
        }
        self.run_due_tasks()?;
        if !self.window_close_texture_leases.is_empty() {
            self.expire_window_close_texture_leases()?;
        }
        if self.authentication.has_pending_events() {
            self.publish_authentication_events()?;
        }
        Ok(())
    }

    pub(super) fn publish_authentication_events(&mut self) -> Result<(), Box<dyn Error>> {
        while let Some(event) = self.authentication.try_event() {
            self.host()
                .engine()
                .send_platform_message(crate::authentication::STATE_CHANNEL, &event.encode())?;
        }
        Ok(())
    }

    pub(super) fn receive_platform_tasks(&mut self) -> Result<(), Box<dyn Error>> {
        self.handler
            .take_platform_tasks(&mut self.platform_task_scratch);
        for PendingPlatformTask { task, permit } in self.platform_task_scratch.drain(..) {
            let order = self.next_platform_task_order;
            self.next_platform_task_order = order
                .checked_add(1)
                .ok_or("Flutter platform task ordering sequence exhausted")?;
            self.scheduled_tasks.push(QueuedPlatformTask {
                task,
                permit,
                order,
            });
        }
        Ok(())
    }

    pub fn next_dispatch_timeout(&self) -> Duration {
        if self.scheduled_tasks.is_empty() {
            return PLATFORM_TASK_MAX_DISPATCH_TIMEOUT;
        }
        let now = self.host().engine().current_time_nanos();
        platform_task_dispatch_timeout(&self.scheduled_tasks, now)
    }

    pub fn take_ready_frame(
        &mut self,
        output_available: impl FnMut(OutputId) -> bool,
    ) -> Option<ReadyOutputFrame> {
        if !self.frame_ready_observed {
            return None;
        }
        let ready = self.handler.take_ready_frame(output_available);
        self.frame_ready_observed = self.handler.has_ready_frames();
        ready
    }

    pub fn enable_kms_frame_clock(&mut self) {
        self.kms_frame_clock_enabled = true;
    }

    /// Mirrors physical desktop visibility into Flutter's standard lifecycle.
    ///
    /// A desktop whose outputs are all powered off is equivalent to a hidden
    /// desktop window: the framework retains widget state and timers while
    /// disabling frame production until visibility is restored.
    pub fn set_outputs_visible(&mut self, visible: bool) -> Result<(), Box<dyn Error>> {
        if self.outputs_visible == Some(visible) {
            return Ok(());
        }
        let state = if visible {
            FLUTTER_LIFECYCLE_RESUMED
        } else {
            FLUTTER_LIFECYCLE_HIDDEN
        };
        self.host()
            .engine()
            .send_platform_message(FLUTTER_LIFECYCLE_CHANNEL, state)?;
        self.outputs_visible = Some(visible);
        info!(
            visible,
            lifecycle = std::str::from_utf8(state).unwrap_or("unknown"),
            "synchronized Flutter desktop visibility"
        );
        Ok(())
    }
}
