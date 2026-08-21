//! Finite diagnostic and non-Flutter shared-atlas frame loop.

use super::kms_pipeline::{
    HotplugRequest, apply_hotplug_topology, queue_atlas_page_flip, restore_source_rects,
    source_rects_for_atlas, test_atlas_page_flip,
};
use super::kms_render::render_diagnostic_atlas;
use super::kms_session::{log_shutdown, service_session_lifecycle};
use super::*;

pub(super) struct FrameLoopContext<'a, 'event_loop> {
    pub(super) renderer: &'a mut GlesRenderer,
    pub(super) scanout_allocator: &'a mut ScanoutAllocator,
    pub(super) drm: &'a mut DrmDevice,
    pub(super) drm_scanner: &'a mut DrmScanner<SimpleCrtcMapper>,
    pub(super) swapchain: &'a mut RenderSwapchains,
    pub(super) scanouts: &'a mut Vec<Scanout>,
    pub(super) restore_state: &'a mut RestoreState,
    pub(super) wayland: Option<wayland_frontend::WaylandFrontend>,
    #[cfg(feature = "flutter")]
    pub(super) flutter: Option<flutter_runtime::FlutterRuntime>,
    #[cfg(feature = "flutter")]
    pub(super) flutter_launcher: Option<&'a mut FlutterLauncher>,
    pub(super) frame_count: u64,
    pub(super) max_outputs: usize,
    pub(super) initial_configuration: &'a RuntimeOutputConfiguration,
    pub(super) rescan_at_frame: Option<u64>,
    pub(super) simulate_hotplug_at_frame: Option<u64>,
    pub(super) topology: &'a mut TopologyManager,
    pub(super) layout_transition: Option<&'a LayoutTransition>,
    pub(super) event_loop: &'a mut EventLoop<'event_loop, RuntimeState>,
}

pub(super) fn run_frame_loop(
    context: FrameLoopContext<'_, '_>,
) -> Result<framebuffer::Handle, Box<dyn Error>> {
    let FrameLoopContext {
        renderer,
        scanout_allocator,
        drm,
        drm_scanner,
        swapchain,
        scanouts,
        restore_state,
        wayland,
        #[cfg(feature = "flutter")]
        mut flutter,
        #[cfg(feature = "flutter")]
        mut flutter_launcher,
        frame_count,
        max_outputs,
        initial_configuration,
        rescan_at_frame,
        simulate_hotplug_at_frame,
        topology,
        layout_transition,
        event_loop,
    } = context;
    let started = Instant::now();
    let mut total_render = Duration::ZERO;
    let mut longest_render = Duration::ZERO;
    let mut total_wait = Duration::ZERO;
    let mut longest_wait = Duration::ZERO;
    let system_controls = wayland
        .as_ref()
        .map(|_| SystemControls::new())
        .transpose()?;
    let native_escape_shortcut = wayland
        .as_ref()
        .map(|frontend| frontend.shortcuts.engine())
        .unwrap_or_default();
    let mut events = RuntimeState {
        wayland,
        native_escape_shortcut,
        #[cfg(feature = "flutter")]
        clipboard: Default::default(),
        system_controls,
        #[cfg(feature = "flutter")]
        authentication: None,
        #[cfg(feature = "flutter")]
        flutter_active: false,
        #[cfg(feature = "flutter")]
        flutter_input: flutter_runtime::InputQueue::new(swapchain.desktop_size()),
        ..RuntimeState::default()
    };
    #[cfg(feature = "flutter")]
    events.synchronize_flutter_pointer_position();
    let mut active_configuration = initial_configuration.clone();

    for frame_number in 1..=frame_count {
        service_session_lifecycle(drm, scanouts, swapchain, event_loop, &mut events, None)?;
        if let Some(reason) = events.lifecycle.shutdown_reason() {
            log_shutdown(reason);
            return Ok(swapchain.representative_framebuffer());
        }
        let render_started = Instant::now();
        let mut normal_next = None;
        let mut staged_swapchain = None;
        let layout_change =
            layout_transition.filter(|transition| transition.at_frame == frame_number);
        let mut planned_layout = None;
        if let Some(transition) = layout_change {
            let mut transitioned_configuration = active_configuration.clone();
            transitioned_configuration
                .positions
                .clone_from(&transition.positions);
            let outputs = scanouts
                .iter()
                .map(|scanout| scanout.output.clone())
                .collect::<Vec<_>>();
            let snapshot =
                update_topology_for_outputs(topology, &outputs, &transitioned_configuration)?;
            let atlas = AtlasPlan::for_snapshot(&snapshot)
                .ok_or("reconfigured topology produced no atlas")?;
            planned_layout = Some((snapshot, atlas));
        }
        let framebuffer = if let Some((_, transition_atlas)) = planned_layout.as_ref() {
            let source_rects = source_rects_for_atlas(transition_atlas, scanouts)?;
            let atlas_modifiers =
                shared_atlas_modifiers(scanouts, renderer.egl_context().dmabuf_render_formats())?;
            let previous_rects = scanouts
                .iter()
                .map(|scanout| scanout.source_rect)
                .collect::<Vec<_>>();
            for (scanout, source_rect) in scanouts.iter_mut().zip(source_rects) {
                scanout.source_rect = source_rect;
            }

            let mut staged = match AtlasSwapchain::allocate(
                scanout_allocator,
                transition_atlas.pixel_size,
                &atlas_modifiers,
            ) {
                Ok(staged) => staged,
                Err(error) => {
                    restore_source_rects(scanouts, &previous_rects);
                    return Err(error);
                }
            };
            if let Err(error) = render_diagnostic_atlas(
                renderer,
                &mut staged.buffers[staged.current].dmabuf,
                staged.size,
                scanouts,
                frame_number,
            ) {
                restore_source_rects(scanouts, &previous_rects);
                return Err(error);
            }
            let framebuffer = staged.current_framebuffer();
            if let Err(error) = test_atlas_page_flip(drm, scanouts, framebuffer) {
                restore_source_rects(scanouts, &previous_rects);
                return Err(error);
            }
            staged_swapchain = Some((staged, previous_rects));
            framebuffer
        } else {
            let atlas_swapchain = swapchain
                .atlas_mut()
                .ok_or("diagnostic frame loop lost its atlas swapchain")?;
            let next = atlas_swapchain.next_index();
            if let Some(frontend) = events.wayland.as_mut() {
                frontend.process_pending_dmabufs(renderer)?;
                frontend.render(renderer, &mut atlas_swapchain.buffers[next].dmabuf)?;
            } else {
                render_diagnostic_atlas(
                    renderer,
                    &mut atlas_swapchain.buffers[next].dmabuf,
                    atlas_swapchain.size,
                    scanouts,
                    frame_number,
                )?;
            }
            normal_next = Some(next);
            atlas_swapchain.buffers[next].framebuffer()
        };
        let rendered = render_started.elapsed();
        total_render += rendered;
        longest_render = longest_render.max(rendered);

        events.pending.clear();
        for scanout in scanouts.iter() {
            events.pending.insert(scanout.output.crtc);
        }
        let render_fence = None;
        if let Err(error) = queue_atlas_page_flip(drm, scanouts, framebuffer, render_fence) {
            if let Some((_, previous_rects)) = staged_swapchain {
                restore_source_rects(scanouts, &previous_rects);
            }
            return Err(error);
        }
        if let Some(frontend) = events.wayland.as_mut() {
            // Give clients the whole in-flight KMS interval to produce their
            // next buffer. Waiting until the vblank completion here forced
            // the client -> Flutter -> KMS pipeline onto every other refresh.
            frontend.frame_submitted()?;
        }

        let retired_swapchain = if let Some((staged, _)) = staged_swapchain {
            let old_size = swapchain.desktop_size();
            let new_size = staged.size;
            let retired = std::mem::replace(swapchain, RenderSwapchains::Atlas(staged));
            info!(
                frame = frame_number,
                old_width = old_size.width,
                old_height = old_size.height,
                new_width = new_size.width,
                new_height = new_size.height,
                "queued atomic atlas layout transition"
            );
            Some(retired)
        } else {
            None
        };

        let wait_started = Instant::now();
        let deadline = wait_started + Duration::from_secs(2);
        while !events.pending.is_empty() {
            event_loop.dispatch(Duration::from_millis(100), &mut events)?;
            service_session_lifecycle(
                drm,
                scanouts,
                &framebuffer,
                event_loop,
                &mut events,
                Some(deadline),
            )?;
            if let Some(error) = events.error.take() {
                return Err(format!("DRM event error: {error}").into());
            }
            if events.device_removed {
                return Err("the active DRM device was removed during the frame loop".into());
            }
            if !events.pending.is_empty() && Instant::now() >= deadline {
                return Err(format!("timed out waiting for vblank on {:?}", events.pending).into());
            }
        }

        let waited = wait_started.elapsed();
        drop(retired_swapchain);
        total_wait += waited;
        longest_wait = longest_wait.max(waited);
        if let Some(next) = normal_next {
            swapchain
                .atlas_mut()
                .ok_or("diagnostic frame loop lost its atlas after presentation")?
                .present(next);
        } else if let Some((transition_snapshot, _)) = planned_layout.as_ref() {
            let transition = layout_change
                .ok_or("internal topology error: a planned layout has no matching transition")?;
            active_configuration
                .positions
                .clone_from(&transition.positions);
            if let Some(frontend) = events.wayland.as_mut() {
                frontend.update_topology(transition_snapshot)?;
            }
        }
        if let Some(frontend) = events.wayland.as_mut() {
            frontend.after_present()?;
        }
        if let Some(reason) = events.lifecycle.shutdown_reason() {
            log_shutdown(reason);
            return Ok(swapchain.representative_framebuffer());
        }

        let simulated_disconnect = simulate_hotplug_at_frame == Some(frame_number);
        let simulated_reconnect = simulate_hotplug_at_frame
            .and_then(|frame| frame.checked_add(SIMULATED_HOTPLUG_GAP_FRAMES))
            == Some(frame_number);
        if simulated_disconnect || simulated_reconnect {
            let mut outputs =
                connected_outputs(drm_scanner, drm, max_outputs, &active_configuration)?;
            if simulated_disconnect {
                if outputs.len() < 2 {
                    return Err("simulated hotplug needs at least two connected outputs".into());
                }
                let removed = outputs
                    .pop()
                    .ok_or("simulated hotplug lost its removable output")?;
                info!(
                    output = removed.name,
                    reconnect_after_frames = SIMULATED_HOTPLUG_GAP_FRAMES,
                    "simulating output removal through the hotplug transaction"
                );
            } else {
                info!(
                    outputs = outputs.len(),
                    "simulating output reconnection through the hotplug transaction"
                );
            }
            apply_hotplug_topology(HotplugRequest {
                renderer,
                allocator: scanout_allocator,
                drm,
                swapchain,
                scanouts,
                restore_state,
                topology,
                outputs,
                configuration: &active_configuration,
                frame_number,
                event_loop,
                events: &mut events,
                flutter: &mut flutter,
                flutter_launcher: flutter_launcher.as_deref_mut(),
            })?;
        }

        let forced_rescan = rescan_at_frame == Some(frame_number);
        if forced_rescan {
            events.topology_dirty = true;
        }
        if events.topology_dirty {
            events.topology_dirty = false;
            let outputs = connected_outputs(drm_scanner, drm, max_outputs, &active_configuration)?;
            let changed = outputs.len() != scanouts.len()
                || outputs.iter().any(|output| {
                    scanouts
                        .iter()
                        .find(|scanout| scanout.output.id == output.id)
                        .is_none_or(|scanout| {
                            scanout.output.crtc != output.crtc
                                || scanout.output.mode != output.mode
                                || scanout.output.connector != output.connector
                                || scanout.output.transform != output.transform
                                || scanout.output.vrr_enabled != output.vrr_enabled
                        })
                });
            info!(
                connected_outputs = outputs.len(),
                changed,
                forced = forced_rescan,
                "completed frame-boundary DRM topology rescan"
            );
            if changed || forced_rescan {
                apply_hotplug_topology(HotplugRequest {
                    renderer,
                    allocator: scanout_allocator,
                    drm,
                    swapchain,
                    scanouts,
                    restore_state,
                    topology,
                    outputs,
                    configuration: &active_configuration,
                    frame_number,
                    event_loop,
                    events: &mut events,
                    flutter: &mut flutter,
                    flutter_launcher: flutter_launcher.as_deref_mut(),
                })?;
            }
        }
    }

    let elapsed = started.elapsed();
    let presented_hz = frame_count as f64 / elapsed.as_secs_f64();
    let average_render_ms = total_render.as_secs_f64() * 1_000.0 / frame_count as f64;
    let average_wait_ms = total_wait.as_secs_f64() * 1_000.0 / frame_count as f64;
    info!(
        frames = frame_count,
        vblank_events = events.vblank_events,
        elapsed_ms = elapsed.as_secs_f64() * 1_000.0,
        presented_hz,
        average_render_ms,
        longest_render_ms = longest_render.as_secs_f64() * 1_000.0,
        average_wait_ms,
        longest_wait_ms = longest_wait.as_secs_f64() * 1_000.0,
        "vblank-driven shared-atlas frame loop complete"
    );

    Ok(swapchain.representative_framebuffer())
}
