//! Device discovery, renderer construction, initial modeset, and runtime launch.

use super::*;

pub(super) fn run(options: Options) -> Result<(), Box<dyn Error>> {
    #[cfg(not(feature = "flutter"))]
    if options.flutter_bundle.is_some() {
        return Err("this deniald binary was built without the `flutter` Cargo feature".into());
    }

    let runtime_limit = options.runtime_limit();
    let output_configuration = RuntimeOutputConfiguration::from_options(&options);
    let mut settings = options
        .wayland
        .then(settings::SettingsManager::load)
        .transpose()?;
    let mut shortcuts = options.wayland.then(ShortcutManager::load).transpose()?;
    if let Some(settings) = settings.as_mut()
        && let Err(error) = settings.keyboard().compiled_layout_names()
    {
        warn!(
            %error,
            path = %settings.path().display(),
            "configured keyboard is unavailable; using the safe US keymap without overwriting the file"
        );
        settings.replace_invalid_keyboard_with_default();
    }

    // calloop's signal source masks only the thread that creates it. Create it
    // before libseat, RTKit, graphics drivers, or any Denial worker can spawn
    // threads so every descendant inherits the mask and process-directed
    // control signals cannot retain their default terminating behavior.
    let signal_source = if runtime_limit != RuntimeLimit::TestOnly {
        Some(Signals::new(&[
            Signal::SIGINT,
            Signal::SIGTERM,
            #[cfg(feature = "flutter")]
            Signal::SIGUSR1,
            #[cfg(feature = "flutter")]
            Signal::SIGUSR2,
        ])?)
    } else {
        None
    };

    let (mut session, session_notifier) = LibSeatSession::new()?;
    if !session.is_active() {
        return Err("libseat did not activate the current TTY session".into());
    }
    // RTKit grants priority only to active local sessions. Prepare the policy
    // after libseat activation, but keep this thread ordinary until Flutter,
    // graphics drivers, and persistent compositor workers have initialized.
    cpu_scheduling::initialize();
    let seat_name = session.seat();
    let drm_device_id = std::fs::metadata(&options.device)?.rdev();

    let owned_fd = session.open(
        Path::new(&options.device),
        OFlags::RDWR | OFlags::CLOEXEC | OFlags::NOCTTY | OFlags::NONBLOCK,
    )?;
    let drm_fd = DrmDeviceFd::new(DeviceFd::from(owned_fd));
    let render_device = options.render_device.as_deref().unwrap_or(&options.device);
    let render_fd = if render_device == options.device {
        drm_fd.clone()
    } else {
        // Render nodes carry no KMS state and require neither DRM master nor
        // seat activation. Passing one through libseat asks logind to manage
        // it as a seat device, which rejects valid render nodes on systemd.
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .open(render_device)
            .map_err(|error| {
                format!(
                    "could not open independent render device {}: {error}",
                    render_device.display()
                )
            })?;
        let owned_fd: OwnedFd = file.into();
        DrmDeviceFd::new(DeviceFd::from(owned_fd))
    };
    let (drm, drm_notifier) = DrmDevice::new(drm_fd.clone(), false)?;
    if !drm.is_atomic() {
        return Err("the selected DRM device does not expose atomic modesetting".into());
    }
    if !preserves_predecessor_kms_state(runtime_limit) {
        // A display manager can leave cursor or overlay planes latched when it
        // releases DRM master. Denial composites its cursor into the Flutter
        // scene, so take ownership of those planes before the first Denial
        // commit. Bounded diagnostics keep every predecessor plane untouched
        // because their restore snapshot owns primary planes only.
        kms_state::release_inherited_planes(&drm);
    }
    let mut kms = KmsContext::new(drm);
    let mut frame_event_loop = if runtime_limit != RuntimeLimit::TestOnly {
        let event_loop = EventLoop::<RuntimeState>::try_new()?;
        event_loop
            .handle()
            .insert_source(drm_notifier, |event, metadata, state| match event {
                DrmEvent::VBlank(crtc) => {
                    state.pending.remove(&crtc);
                    state.vblank_events += 1;
                    // Preserve the physical edge before any other ready
                    // calloop source, Wayland traversal, or Flutter platform
                    // task is serviced.  The C++ runtime forwards the KMS
                    // presentation timestamp to Flutter; reducing the event
                    // to a bare CRTC here made the later OnVsync timestamp
                    // depend on batching latency instead.
                    let delivered_at = Instant::now();
                    let presented_at = metadata.as_ref().and_then(|metadata| match metadata.time {
                        DrmEventTime::Monotonic(timestamp) => Some(timestamp),
                        DrmEventTime::Realtime(_) => None,
                    });
                    // A DRM event can spend several milliseconds waiting in
                    // the event loop on a busy mobile compositor. Compare its
                    // physical edge with the synthetic display clock, not its
                    // userspace delivery time, or one edge can be mistaken for
                    // a second Flutter vsync. Linux Instant and DRM monotonic
                    // timestamps use the same clock rate; translate only the
                    // elapsed duration so their private epochs need not match.
                    let observed_at = presented_at
                        .and_then(|presented_at| {
                            monotonic_now().map(|monotonic_now| {
                                presentation_instant(delivered_at, monotonic_now, presented_at)
                            })
                        })
                        .unwrap_or(delivered_at);
                    let sequence = metadata
                        .as_ref()
                        .map(|metadata| u64::from(metadata.sequence));
                    state.completed_page_flips.push_back(PageFlipCompletion {
                        crtc,
                        observed_at,
                        presented_at,
                        sequence,
                    });
                }
                DrmEvent::Error(error) => state.error = Some(error.to_string()),
            })?;
        event_loop
            .handle()
            .insert_source(session_notifier, |event, _, state| match event {
                SessionEvent::PauseSession => {
                    wayland_frontend::reset_all_input_devices(state);
                    state.lifecycle.pause_session();
                }
                SessionEvent::ActivateSession => state.lifecycle.activate_session(),
            })?;
        event_loop.handle().insert_source(
            signal_source.ok_or("signal source was not prepared before worker startup")?,
            |event, _, state| {
                let reason = match event.signal() {
                    Signal::SIGINT => ShutdownReason::Interrupt,
                    Signal::SIGTERM => ShutdownReason::Terminate,
                    #[cfg(feature = "flutter")]
                    Signal::SIGUSR1 => {
                        state.flutter_reload_requested = true;
                        return;
                    }
                    #[cfg(feature = "flutter")]
                    Signal::SIGUSR2 => {
                        state.kms_reconfigure_requested = true;
                        state.topology_dirty = true;
                        info!("live KMS reconfiguration requested");
                        return;
                    }
                    _ => return,
                };
                state.lifecycle.request_shutdown(reason);
            },
        )?;
        event_loop.handle().insert_source(
            UdevBackend::new(&seat_name)?,
            move |event, _, state| match event {
                UdevEvent::Added { device_id, .. } | UdevEvent::Changed { device_id }
                    if device_id == drm_device_id =>
                {
                    state.topology_dirty = true;
                }
                UdevEvent::Removed { device_id } if device_id == drm_device_id => {
                    state.device_removed = true;
                }
                _ => {}
            },
        )?;
        Some(event_loop)
    } else {
        None
    };

    let mut drm_scanner: DrmScanner<SimpleCrtcMapper> = DrmScanner::new();
    let outputs = connected_outputs(
        &mut drm_scanner,
        &kms.drm,
        options.max_outputs,
        &output_configuration,
    )?;
    if outputs.is_empty() {
        return Err(format!("no connected outputs found on {}", options.device.display()).into());
    }

    let mut topology = topology_for_outputs(&outputs, &output_configuration)?;
    let snapshot = topology.snapshot();
    let atlas = AtlasPlan::for_snapshot(&snapshot).ok_or("topology produced no atlas")?;
    let mut wayland = if options.wayland {
        let event_loop = frame_event_loop
            .as_mut()
            .ok_or("Wayland frontend has no event loop")?;
        let frontend = wayland_frontend::WaylandFrontend::new(
            event_loop,
            &snapshot,
            session.clone(),
            &seat_name,
            drm_fd.clone(),
            options.work_area.clone(),
            settings
                .take()
                .expect("Wayland settings were loaded before frontend startup"),
            shortcuts
                .take()
                .expect("Wayland shortcuts were loaded before frontend startup"),
        )?;
        let x11_display = frontend.xdisplay_name();
        info!(
            wayland_display = ?frontend.socket_name(),
            x11_display = ?x11_display,
            "Wayland frontend listening"
        );
        Some(frontend)
    } else {
        None
    };
    let layout_transition = if let Some(at_frame) = options.reconfigure_at_frame {
        let mut configuration = output_configuration.clone();
        configuration.positions.extend(
            options
                .next_positions
                .iter()
                .map(|(name, position)| (name.clone(), *position)),
        );
        let staged_topology = topology_for_outputs(&outputs, &configuration)?;
        AtlasPlan::for_snapshot(&staged_topology.snapshot())
            .ok_or("reconfigured topology produced no atlas")?;
        Some(LayoutTransition {
            at_frame,
            positions: configuration.positions,
        })
    } else {
        None
    };
    kms.scanouts.reserve(outputs.len());

    for output in outputs {
        let original_mode = match kms.drm.get_crtc(output.crtc)?.mode() {
            Some(mode) => mode,
            None if !preserves_predecessor_kms_state(runtime_limit) => {
                info!(
                    output = output.name,
                    crtc = ?output.crtc,
                    "display-manager handoff supplied an inactive CRTC"
                );
                output.mode
            }
            None => return Err(format!("{:?} has no active mode", output.crtc).into()),
        };
        let surface = kms
            .drm
            .create_surface(output.crtc, output.mode, &[output.connector])?;
        stage_output_vrr(&surface, &output)?;
        let plane_properties = AtlasPlaneProperties::load(&kms.drm, surface.plane())?;
        let source_rect = atlas
            .outputs
            .iter()
            .find(|planned| planned.id == output.id)
            .ok_or("output missing from atlas plan")?
            .source_rect;

        kms.scanouts.push(Scanout {
            output,
            surface,
            plane_properties,
            source_rect,
            original_mode,
            powered: true,
        });
    }

    let cross_device_rendering = render_device != options.device;
    let gbm = GbmDevice::new(render_fd.clone()).map_err(|error| {
        format!(
            "could not create GBM device for {}: {error}",
            render_device.display()
        )
    })?;
    let gbm_flags = GbmBufferFlags::RENDERING | GbmBufferFlags::SCANOUT;
    let mut allocator = GbmAllocator::new(gbm.clone(), gbm_flags);
    let mut scanout_allocator = ScanoutAllocator::gbm(
        GbmAllocator::new(gbm.clone(), scanout_gbm_flags(cross_device_rendering)),
        drm_fd.clone(),
        cross_device_rendering,
    );
    // SAFETY: the GBM device outlives the EGL display, context, renderer and
    // every imported dmabuf created below. All of them are dropped in this
    // function before `gbm`, `render_fd`, and `drm_fd`.
    let egl_display = unsafe { EGLDisplay::new(gbm.clone()) }.map_err(|error| {
        format!(
            "could not create EGL display for {}: {error}",
            render_device.display()
        )
    })?;
    let mut swapchains = if options.flutter_bundle.is_some() {
        #[cfg(feature = "flutter")]
        {
            let render_outputs = atlas
                .render_outputs(&snapshot)
                .ok_or("initial Flutter output plans do not match topology")?;
            RenderSwapchains::Outputs {
                desktop_size: atlas.pixel_size,
                swapchains: OutputSwapchains::allocate(
                    &mut scanout_allocator,
                    &render_outputs,
                    &kms.scanouts,
                    egl_display.dmabuf_render_formats(),
                    options.flutter_offscreen_blit,
                )?,
            }
        }
        #[cfg(not(feature = "flutter"))]
        return Err("Flutter feature was checked before allocating scanout buffers".into());
    } else {
        let atlas_modifiers =
            shared_atlas_modifiers(&kms.scanouts, egl_display.dmabuf_render_formats())?;
        let atlas_swapchain = AtlasSwapchain::allocate(
            &mut scanout_allocator,
            atlas.pixel_size,
            &atlas_modifiers,
        )
        .map_err(|error| {
            format!(
                "could not allocate diagnostic atlas on render device {} for KMS device {}: {error}",
                render_device.display(),
                options.device.display()
            )
        })?;
        RenderSwapchains::Atlas(atlas_swapchain)
    };
    let egl_context = egl_context::create_render_context(&egl_display)?;
    // SAFETY: `egl_context` is current only through this renderer and remains
    // alive for the renderer's entire lifetime.
    let mut renderer = unsafe { GlesRenderer::new(egl_context)? };
    if let Some(frontend) = wayland.as_mut() {
        frontend.init_renderer(&mut renderer)?;
    }
    if options.flutter_bundle.is_some() {
        #[cfg(feature = "flutter")]
        for pool in &mut swapchains
            .outputs_mut()
            .ok_or("Flutter output pools were not allocated")?
            .outputs
        {
            render_blank_target(
                &mut renderer,
                &mut pool.buffers[pool.current].dmabuf,
                pool.size,
            )?;
        }
    } else {
        let atlas_swapchain = swapchains
            .atlas_mut()
            .ok_or("diagnostic rendering has no atlas swapchain")?;
        render_diagnostic_atlas(
            &mut renderer,
            &mut atlas_swapchain.buffers[atlas_swapchain.current].dmabuf,
            atlas_swapchain.size,
            &kms.scanouts,
            0,
        )?;
    }

    let fb = swapchains.representative_framebuffer();

    info!(
        device = %options.device.display(),
        render_device = %render_device.display(),
        outputs = kms.scanouts.len(),
        atlas_width = atlas.pixel_size.width,
        atlas_height = atlas.pixel_size.height,
        presentation = if options.flutter_bundle.is_some() {
            "native-output-pools"
        } else {
            "diagnostic-atlas"
        },
        "testing initial atomic scanout state"
    );

    let mut restore_state = if !preserves_predecessor_kms_state(runtime_limit) {
        // The display manager/logind may disable its CRTC between libseat
        // activation and this point. A real login session hands KMS back by
        // releasing DRM master; it must not depend on cloning a greeter
        // framebuffer that may already have disappeared.
        let state = RestoreState::for_session_handoff(&kms.scanouts)?;
        info!("using display-manager KMS handoff without predecessor restore");
        state
    } else {
        let state = RestoreState::capture(&kms.drm, &kms.scanouts)?;
        state.test(&kms.drm)?;
        info!(
            properties = state.property_count(),
            framebuffer_aliases = state.owned_framebuffer_count(),
            "pre-Denial KMS state is atomically restorable"
        );
        state
    };

    for scanout in &kms.scanouts {
        let (framebuffer, state) = current_scanout_state(scanout, &swapchains)?;
        scanout.surface.test_state([state], true)?;
        let mode: OutputMode = scanout.output.mode.into();
        info!(
            output = scanout.output.name,
            crtc = ?scanout.output.crtc,
            plane = ?scanout.surface.plane(),
            source = ?scanout.source_rect,
            ?framebuffer,
            refresh_millihz = mode.refresh,
            "atomic TEST_ONLY accepted"
        );
    }

    #[cfg(feature = "flutter")]
    let output_control = if options.flutter_bundle.is_some() {
        use smithay::reexports::calloop::channel::Event as ChannelEvent;

        let initial = output_control_state(
            &drm_scanner,
            &kms.scanouts,
            &topology,
            &output_configuration,
            options.output_config.is_some(),
            None,
        )?;
        let (server, source) = OutputControlServer::start(initial)?;
        frame_event_loop
            .as_mut()
            .ok_or("output control has no event loop")?
            .handle()
            .insert_source(source, |event, _, state: &mut RuntimeState| {
                if let ChannelEvent::Msg(request) = event {
                    match request {
                        ControlEvent::OutputApply(request) => {
                            state.pending_output_applies.push_back(request);
                        }
                        ControlEvent::OutputConfirmation(request) => {
                            state.pending_output_confirmations.push_back(request);
                        }
                        ControlEvent::Shell(request) => {
                            let result = if state.secure_session_locked() {
                                Err(OutputControlFailure::new(
                                    "locked",
                                    "shell commands are unavailable while the secure session is locked",
                                ))
                            } else {
                                match request.command {
                                    ShellControlCommand::OpenWallpaper => state.queue_shell_action(
                                        wire::ShellAction::Wallpaper,
                                        None,
                                    ),
                                }
                                Ok(())
                            };
                            request.reply(result);
                        }
                        ControlEvent::Settings(request) => {
                            state.pending_settings_controls.push_back(request);
                        }
                        ControlEvent::SystemControl(request) => {
                            state.pending_system_controls.push_back(request);
                        }
                        ControlEvent::UiDevelopment(request) => {
                            state.pending_ui_development.push_back(request);
                        }
                    }
                }
            })?;
        Some(server)
    } else {
        None
    };

    #[cfg(feature = "flutter")]
    let mut flutter_launcher = if let Some(bundle) = options.flutter_bundle.as_deref() {
        use smithay::reexports::calloop::channel::{Event as ChannelEvent, channel};

        let event_loop = frame_event_loop
            .as_mut()
            .ok_or("Flutter runtime has no event loop")?;
        let (sender, source) = channel();
        event_loop.handle().insert_source(
            source,
            |event, _, state: &mut RuntimeState| match event {
                ChannelEvent::Msg(flutter_runtime::RuntimeEvent::SampledBuffersReady {
                    fence,
                    batch,
                }) => state.sampled_buffer_releases.push((fence, batch)),
                ChannelEvent::Msg(event) => state.flutter_events.push(event),
                ChannelEvent::Closed => state.flutter_channel_closed = true,
            },
        )?;
        Some(FlutterLauncher::new(
            FlutterLaunchConfiguration {
                bundle,
                renderer_backend: options.flutter_renderer,
                offscreen_blit: options.flutter_offscreen_blit,
                debug_bundle: options.flutter_debug_bundle.clone(),
                ui_workspace: options.flutter_ui_workspace.clone(),
            },
            sender,
            wayland
                .as_ref()
                .map(|frontend| frontend.socket_name().to_os_string()),
            wayland.as_ref().map(|frontend| frontend.xdisplay_name()),
            output_control
                .as_ref()
                .map(OutputControlServer::socket_path_os_string),
            options.work_area.clone(),
            options.start_locked,
        )?)
    } else {
        None
    };
    #[cfg(feature = "flutter")]
    let flutter = if let Some(launcher) = flutter_launcher.as_mut() {
        Some(
            launcher.start(
                &renderer,
                swapchains
                    .outputs()
                    .ok_or("Flutter launcher has no physical output pools")?,
                &kms.scanouts,
                &snapshot,
                &atlas,
            )?,
        )
    } else {
        None
    };

    if runtime_limit == RuntimeLimit::TestOnly {
        kms.pause();
        info!("TEST_ONLY complete; scanout was not changed and surface teardown is inert");
        return Ok(());
    }

    let mut graphical_session_started = false;
    let runtime_outcome = catch_unwind(AssertUnwindSafe(|| -> Result<_, Box<dyn Error>> {
        for scanout in &kms.scanouts {
            let (_, state) = current_scanout_state(scanout, &swapchains)?;
            scanout
                .surface
                .commit([state], false)
                .map_err(|error| format!("initial KMS commit failed: {error}"))?;
        }
        // A display manager, D-Bus activated desktop services, and optional
        // session managers must only observe Denial after the shell is alive
        // and every initial scanout has accepted a real commit. Publishing at
        // this boundary makes the standard activation environment double as
        // the compositor's readiness signal without coupling it to a launcher.
        if let Some(frontend) = wayland.as_ref() {
            match publish_session_activation_environment(
                frontend.socket_name(),
                frontend.xdisplay_name().as_os_str(),
                #[cfg(feature = "flutter")]
                output_control
                    .as_ref()
                    .map(|server| server.socket_path().as_os_str()),
                #[cfg(not(feature = "flutter"))]
                None,
            ) {
                Ok(activation) => graphical_session_started = activation.starts_systemd_target(),
                Err(error) => {
                    warn!(%error, "could not activate the compositor session environment")
                }
            }
        }
        if options.flutter_bundle.is_some() {
            #[cfg(feature = "flutter")]
            {
                let (duration, frame_limit) = match runtime_limit {
                    RuntimeLimit::Frames(frame_count) => (None, Some(frame_count)),
                    RuntimeLimit::Duration(duration) => (Some(duration), None),
                    RuntimeLimit::UntilLogout => (None, None),
                    _ => {
                        return Err(
                            "Flutter loop selected with an incompatible runtime limit".into()
                        );
                    }
                };
                run_flutter_event_loop(FlutterEventLoopContext {
                    renderer: &mut renderer,
                    drm: &mut kms.drm,
                    swapchain: &mut swapchains,
                    scanouts: &mut kms.scanouts,
                    restore_state: &mut restore_state,
                    drm_scanner: &mut drm_scanner,
                    allocator: &mut allocator,
                    scanout_allocator: &mut scanout_allocator,
                    topology: &mut topology,
                    max_outputs: options.max_outputs,
                    output_configuration,
                    output_config: options.output_config.clone(),
                    output_control: output_control
                        .as_ref()
                        .ok_or("Flutter output control was not initialized")?
                        .publisher(),
                    wayland,
                    flutter: flutter.ok_or("Flutter runtime was not initialized")?,
                    flutter_launcher: flutter_launcher
                        .as_mut()
                        .ok_or("Flutter launcher was not initialized")?,
                    duration,
                    frame_limit,
                    event_loop: frame_event_loop
                        .as_mut()
                        .ok_or("Flutter event loop has no event source")?,
                })
                .map_err(|error| format!("Flutter event loop failed: {error}").into())
            }
            #[cfg(not(feature = "flutter"))]
            return Err("Flutter feature was checked before acquiring DRM".into());
        } else if let RuntimeLimit::Frames(frame_count) = runtime_limit {
            run_frame_loop(FrameLoopContext {
                renderer: &mut renderer,
                scanout_allocator: &mut scanout_allocator,
                drm: &mut kms.drm,
                drm_scanner: &mut drm_scanner,
                swapchain: &mut swapchains,
                scanouts: &mut kms.scanouts,
                restore_state: &mut restore_state,
                wayland,
                #[cfg(feature = "flutter")]
                flutter,
                #[cfg(feature = "flutter")]
                flutter_launcher: flutter_launcher.as_mut(),
                frame_count,
                max_outputs: options.max_outputs,
                initial_configuration: &output_configuration,
                rescan_at_frame: options.rescan_at_frame,
                simulate_hotplug_at_frame: options.simulate_hotplug_at_frame,
                topology: &mut topology,
                layout_transition: layout_transition.as_ref(),
                event_loop: frame_event_loop
                    .as_mut()
                    .ok_or("frame loop has no event source")?,
            })
            .map_err(|error| format!("frame loop failed: {error}").into())
        } else {
            let RuntimeLimit::Duration(duration) = runtime_limit else {
                return Err("finite KMS hold selected with an incompatible runtime limit".into());
            };
            info!(
                seconds = duration.as_secs(),
                "shared atlas committed to hardware; holding scanout"
            );
            hold_static_scanout(
                &mut kms.drm,
                &kms.scanouts,
                fb,
                duration,
                frame_event_loop
                    .as_mut()
                    .ok_or("KMS hold has no event source")?,
            )
        }
    }));

    let current_fb = runtime_outcome
        .as_ref()
        .ok()
        .and_then(|result| result.as_ref().ok())
        .copied()
        .unwrap_or_else(|| swapchains.representative_framebuffer());

    if runtime_limit == RuntimeLimit::UntilLogout {
        // This is the last-resort teardown boundary for a real login session.
        // The orderly path already drains pending flips and releases master,
        // but an error or panic can leave the Flutter loop before reaching
        // that code. Never let such an exceptional exit fall through to the
        // synchronous atomic restore below: the display manager owns the next
        // modeset.
        kms.pause();
    }
    let restore = kms.restore_once(&restore_state, current_fb);
    let restored = restore.restored;
    let restore_failures = restore.failures;

    if graphical_session_started && let Err(error) = stop_systemd_graphical_session() {
        warn!(%error, "could not stop the Denial graphical-session target");
    }

    match runtime_outcome {
        Ok(Ok(_)) if restore_failures.is_empty() => {}
        Ok(Ok(_)) => return Err(restore_failures.join("; ").into()),
        Ok(Err(runtime_error)) => {
            let mut failures = vec![runtime_error.to_string()];
            failures.extend(restore_failures);
            return Err(failures.join("; ").into());
        }
        Err(payload) => {
            if !restore_failures.is_empty() {
                error!(
                    failures = ?restore_failures,
                    "KMS restore reported failures while containing a Rust panic"
                );
            }
            resume_unwind(payload);
        }
    }

    if restored {
        info!("KMS hold complete; original atomic state restored");
    } else {
        info!("KMS hold complete; DRM ownership released without atomic restore");
    }
    Ok(())
}
