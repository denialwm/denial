//! Atomic hotplug planning, scanout reconciliation, commit, and rollback.

use super::kms_render::{
    current_scanout_state, render_blank_output_swapchains, render_diagnostic_atlas,
};
use super::kms_session::{ScanoutFramebufferSource, service_session_lifecycle};
use super::*;

#[cfg(feature = "flutter")]
pub(super) struct HotplugRequest<'a, 'event_loop> {
    pub(super) renderer: &'a mut GlesRenderer,
    pub(super) allocator: &'a mut ScanoutAllocator,
    pub(super) drm: &'a mut DrmDevice,
    pub(super) swapchain: &'a mut RenderSwapchains,
    pub(super) scanouts: &'a mut Vec<Scanout>,
    pub(super) restore_state: &'a mut RestoreState,
    pub(super) topology: &'a mut TopologyManager,
    pub(super) outputs: Vec<ConnectedOutput>,
    pub(super) configuration: &'a RuntimeOutputConfiguration,
    pub(super) frame_number: u64,
    pub(super) event_loop: &'a mut EventLoop<'event_loop, RuntimeState>,
    pub(super) events: &'a mut RuntimeState,
    pub(super) flutter: &'a mut Option<flutter_runtime::FlutterRuntime>,
    pub(super) flutter_launcher: Option<&'a mut FlutterLauncher>,
}

#[cfg(feature = "flutter")]
pub(super) fn apply_hotplug_topology(
    request: HotplugRequest<'_, '_>,
) -> Result<(), Box<dyn Error>> {
    let HotplugRequest {
        renderer,
        allocator,
        drm,
        swapchain,
        scanouts,
        restore_state,
        topology,
        outputs,
        configuration,
        frame_number,
        event_loop,
        events,
        flutter,
        mut flutter_launcher,
    } = request;
    if outputs.is_empty() {
        return Err("all DRM outputs were disconnected during the frame loop".into());
    }

    // Topology publication is part of the transaction too: advance the epoch
    // on a clone and only install it after KMS and the Wayland frontend agree.
    let mut staged_topology = topology.clone();
    let snapshot = update_topology_for_outputs(&mut staged_topology, &outputs, configuration)?;
    let atlas = AtlasPlan::for_snapshot(&snapshot).ok_or("hotplug topology produced no atlas")?;
    let old_framebuffers = scanout_rollback_framebuffers(swapchain)?;
    let old_snapshot = topology.snapshot();
    let mut progress = HotplugProgress::default();
    let reconciliation = reconcile_scanouts(drm, scanouts, restore_state, outputs, &atlas)?;
    #[cfg(feature = "flutter")]
    let linear_render_targets = flutter_launcher
        .as_deref()
        .is_some_and(FlutterLauncher::uses_offscreen_blit);

    #[cfg(feature = "flutter")]
    let staged: Result<RenderSwapchains, Box<dyn Error>> = if flutter.is_some() {
        let plans = atlas
            .render_outputs(&snapshot)
            .ok_or_else(|| -> Box<dyn Error> {
                "hotplug topology produced invalid physical render targets".into()
            });
        plans.and_then(|plans| {
            OutputSwapchains::allocate(
                allocator,
                &plans,
                reconciliation.scanouts(),
                renderer.egl_context().dmabuf_render_formats(),
                linear_render_targets,
            )
            .map(|swapchains| RenderSwapchains::Outputs {
                desktop_size: atlas.pixel_size,
                swapchains,
            })
        })
    } else {
        shared_atlas_modifiers(
            reconciliation.scanouts(),
            renderer.egl_context().dmabuf_render_formats(),
        )
        .and_then(|modifiers| {
            AtlasSwapchain::allocate(allocator, atlas.pixel_size, &modifiers)
                .map(RenderSwapchains::Atlas)
        })
    };
    #[cfg(not(feature = "flutter"))]
    let staged = shared_atlas_modifiers(
        reconciliation.scanouts(),
        renderer.egl_context().dmabuf_render_formats(),
    )
    .and_then(|modifiers| {
        AtlasSwapchain::allocate(allocator, atlas.pixel_size, &modifiers)
            .map(RenderSwapchains::Atlas)
    });
    let mut staged = match staged {
        Ok(staged) => staged,
        Err(error) => {
            let failures =
                rollback_hotplug_scanouts(reconciliation, &old_framebuffers, &mut progress, events);
            return Err(hotplug_transaction_error(error.to_string(), failures));
        }
    };

    #[cfg(feature = "flutter")]
    let render_result = if flutter.is_some() {
        render_blank_output_swapchains(
            renderer,
            staged
                .outputs_mut()
                .ok_or("hotplug staging lost its physical output pools")?,
        )
    } else {
        let staged_atlas = staged
            .atlas_mut()
            .ok_or("hotplug diagnostic staging has no atlas swapchain")?;
        render_diagnostic_atlas(
            renderer,
            &mut staged_atlas.buffers[staged_atlas.current].dmabuf,
            staged_atlas.size,
            reconciliation.scanouts(),
            frame_number,
        )
    };
    #[cfg(not(feature = "flutter"))]
    let render_result = {
        let staged_atlas = staged
            .atlas_mut()
            .ok_or("hotplug diagnostic staging has no atlas swapchain")?;
        render_diagnostic_atlas(
            renderer,
            &mut staged_atlas.buffers[staged_atlas.current].dmabuf,
            staged_atlas.size,
            reconciliation.scanouts(),
            frame_number,
        )
    };
    if let Err(error) = render_result {
        let failures =
            rollback_hotplug_scanouts(reconciliation, &old_framebuffers, &mut progress, events);
        return Err(hotplug_transaction_error(error.to_string(), failures));
    }
    for candidate in reconciliation
        .scanouts()
        .iter()
        .filter(|candidate| candidate.powered)
    {
        let output_name = candidate.output.name.clone();
        let state = current_scanout_state(candidate, &staged).map(|(_, state)| state);
        if let Err(error) = state.and_then(|state| {
            candidate
                .surface
                .test_state([state], true)
                .map_err(Into::into)
        }) {
            let failures =
                rollback_hotplug_scanouts(reconciliation, &old_framebuffers, &mut progress, events);
            return Err(hotplug_transaction_error(
                format!("{output_name} TEST_ONLY failed: {error}"),
                failures,
            ));
        }
    }
    progress.mark_validated();

    events.pending.clear();
    for candidate in reconciliation
        .scanouts()
        .iter()
        .filter(|candidate| candidate.powered)
    {
        let state = current_scanout_state(candidate, &staged).map(|(_, state)| state);
        if let Err(error) =
            state.and_then(|state| candidate.surface.commit([state], true).map_err(Into::into))
        {
            let output_name = candidate.output.name.clone();
            let failures =
                rollback_hotplug_scanouts(reconciliation, &old_framebuffers, &mut progress, events);
            return Err(hotplug_transaction_error(
                format!("{output_name} commit failed: {error}"),
                failures,
            ));
        }
        events.pending.insert(candidate.output.crtc);
        progress.record_commit();
    }

    let old_size = swapchain.desktop_size();
    if let Err(error) =
        wait_for_page_flips(drm, reconciliation.scanouts(), &staged, event_loop, events)
    {
        let failures =
            rollback_hotplug_scanouts(reconciliation, &old_framebuffers, &mut progress, events);
        return Err(hotplug_transaction_error(error.to_string(), failures));
    }
    progress.mark_presented();

    #[cfg(feature = "flutter")]
    let restart_flutter = if flutter.is_some() {
        // Shut the old engine down while both its GBM pool and the reversible
        // scanout journal are still alive. From this point onward replacing or
        // unwinding the pool can no longer race EGLImage/target destruction.
        let Some(mut old_runtime) = flutter.take() else {
            return Err("Flutter runtime disappeared during topology restart".into());
        };
        let prepare_restart = (|| -> Result<(), Box<dyn Error>> {
            old_runtime.process_events(events.flutter_events.drain(..))?;
            if let Some(launcher) = flutter_launcher.as_deref_mut()
                && launcher.synchronize_ui_development(&mut old_runtime)?
            {
                events.flutter_reload_requested = true;
            }
            synchronize_authentication_boundary(events);
            synchronize_clipboard(&mut old_runtime, events)?;
            synchronize_system_control_events(&mut old_runtime, events)?;
            synchronize_shell_keyboard(&mut old_runtime, events)?;
            synchronize_settings(&mut old_runtime, events)?;
            synchronize_system_bar_configuration(
                &mut old_runtime,
                events,
                flutter_launcher.as_deref_mut(),
            );
            synchronize_flutter_window_management(&mut old_runtime, events)?;
            synchronize_flutter_input_layout(&mut old_runtime, events)?;
            Ok(())
        })();
        let shutdown = old_runtime.shutdown();
        events.flutter_events.clear();
        let restart_error = match (prepare_restart, shutdown) {
            (Ok(()), Ok(())) => None,
            (Err(error), Ok(())) => Some(format!("Flutter pre-restart drain failed: {error}")),
            (Ok(()), Err(error)) => {
                Some(format!("Flutter shutdown before restart failed: {error}"))
            }
            (Err(prepare_error), Err(shutdown_error)) => Some(format!(
                "Flutter pre-restart drain failed: {prepare_error}; shutdown failed: {shutdown_error}"
            )),
        };
        if let Some(error) = restart_error {
            let failures =
                rollback_hotplug_scanouts(reconciliation, &old_framebuffers, &mut progress, events);
            return Err(hotplug_transaction_error(error, failures));
        }
        true
    } else {
        false
    };

    let retired_clear_failures = reconciliation.clear_retired();
    if !retired_clear_failures.is_empty() {
        let mut failures =
            rollback_hotplug_scanouts(reconciliation, &old_framebuffers, &mut progress, events);
        failures.splice(0..0, retired_clear_failures);
        return Err(hotplug_transaction_error(
            "failed to disable retired CRTCs".into(),
            failures,
        ));
    }

    let frontend_error = events
        .wayland
        .as_mut()
        .and_then(|frontend| frontend.update_topology(&snapshot).err())
        .map(|error| error.to_string());
    if let Some(error) = frontend_error {
        let mut failures =
            rollback_hotplug_scanouts(reconciliation, &old_framebuffers, &mut progress, events);
        if let Some(frontend) = events.wayland.as_mut()
            && let Err(rollback_error) = frontend.update_topology(&old_snapshot)
        {
            failures.push(format!(
                "Wayland topology rollback failed: {rollback_error}"
            ));
        }
        return Err(hotplug_transaction_error(
            format!("Wayland topology publication failed: {error}"),
            failures,
        ));
    }

    let retired_scanouts = reconciliation.commit();
    *topology = staged_topology;
    #[cfg(feature = "flutter")]
    {
        events.output_control_dirty = true;
    }
    let retired = std::mem::replace(swapchain, staged);
    #[cfg(feature = "flutter")]
    {
        let desktop_size = swapchain.desktop_size();
        events.native_plugin_default_size = (desktop_size.width, desktop_size.height);
        if let Some(manager) = events.native_app_plugins.as_mut() {
            manager.set_configure_properties(
                atlas.engine_scale_120,
                SCALE_BASE,
                ticker_refresh_millihz(&snapshot)?,
            )?;
        }
    }
    progress.mark_finalized();
    drop(retired_scanouts);

    #[cfg(feature = "flutter")]
    if restart_flutter {
        drop(retired);
        let launcher = flutter_launcher.ok_or("dynamic Flutter topology has no launcher")?;
        *flutter = Some(
            launcher.start(
                renderer,
                swapchain
                    .outputs()
                    .ok_or("reconfigured Flutter topology has no physical output pools")?,
                scanouts,
                &snapshot,
                &atlas,
            )?,
        );
        events.begin_replacement_flutter_generation(swapchain.desktop_size());
        info!(
            generation = launcher.generation,
            "restarted Flutter with reconfigured native output pools"
        );
    } else {
        drop(retired);
    }
    #[cfg(not(feature = "flutter"))]
    drop(retired);

    info!(
        outputs = scanouts.len(),
        old_width = old_size.width,
        old_height = old_size.height,
        new_width = atlas.pixel_size.width,
        new_height = atlas.pixel_size.height,
        topology_epoch = atlas.topology_epoch,
        "committed hotplug scanout transaction"
    );
    Ok(())
}

#[cfg(feature = "flutter")]
pub(super) fn ticker_refresh_millihz(snapshot: &TopologySnapshot) -> Result<u32, Box<dyn Error>> {
    let ticker = snapshot
        .ticker
        .ok_or("native application timing has no ticker output")?;
    snapshot
        .outputs
        .iter()
        .find(|output| output.id == ticker)
        .map(|output| output.refresh_millihz)
        .filter(|refresh| *refresh > 0 && *refresh <= 1_000_000)
        .ok_or_else(|| "native application ticker output has an invalid refresh rate".into())
}

pub(super) fn reconcile_scanouts<'a>(
    drm: &mut DrmDevice,
    scanouts: &'a mut Vec<Scanout>,
    restore_state: &mut RestoreState,
    outputs: Vec<ConnectedOutput>,
    atlas: &AtlasPlan,
) -> Result<ScanoutReconciliation<'a>, Box<dyn Error>> {
    let current_keys = scanouts
        .iter()
        .map(|scanout| ScanoutKey {
            output: scanout.output.id.0,
            crtc: u32::from(scanout.output.crtc),
        })
        .collect::<Vec<_>>();
    let desired_keys = outputs
        .iter()
        .map(|output| ScanoutKey {
            output: output.id.0,
            crtc: u32::from(output.crtc),
        })
        .collect::<Vec<_>>();
    let plan = plan_reconcile(&current_keys, &desired_keys)?;
    let source_rects = outputs
        .iter()
        .map(|output| {
            atlas
                .outputs
                .iter()
                .find(|planned| planned.id == output.id)
                .map(|planned| planned.source_rect)
                .ok_or_else(|| format!("{} is missing from the hotplug atlas", output.name))
        })
        .collect::<Result<Vec<_>, _>>()?;

    for (output, origin) in outputs.iter().zip(&plan) {
        match origin {
            ScanoutOrigin::Reuse(_) => {}
            ScanoutOrigin::Create => {
                if scanouts
                    .iter()
                    .any(|scanout| scanout.output.crtc == output.crtc)
                {
                    return Err(format!(
                        "{} needs CRTC reassignment; retaining the current scanout instead of dropping it before validation",
                        output.name
                    )
                    .into());
                }
                if drm.get_crtc(output.crtc)?.mode().is_some() {
                    return Err(format!(
                        "{} is assigned to an active foreign CRTC; refusing a destructive hotplug probe",
                        output.name
                    )
                    .into());
                }
            }
        }
    }

    // New surfaces are created only on CRTCs verified inactive above. Their
    // destructor is therefore harmless if a later preparation step fails.
    let mut created = BTreeMap::new();
    for (desired_index, ((output, source_rect), origin)) in
        outputs.iter().zip(&source_rects).zip(&plan).enumerate()
    {
        if *origin == ScanoutOrigin::Create {
            let original_mode = restore_state
                .original_mode(output.id)
                .unwrap_or(output.mode);
            let surface = drm.create_surface(output.crtc, output.mode, &[output.connector])?;
            stage_output_vrr(&surface, output)?;
            let plane_properties = AtlasPlaneProperties::load(drm, surface.plane())?;
            created.insert(
                desired_index,
                Scanout {
                    output: output.clone(),
                    surface,
                    plane_properties,
                    source_rect: *source_rect,
                    original_mode,
                    powered: scanouts
                        .iter()
                        .find(|scanout| scanout.output.id == output.id)
                        .is_none_or(|scanout| scanout.powered),
                },
            );
        }
    }
    // Registration happens before any real KMS commit. If rollback cannot
    // clear a newly created surface, the RAII guard transfers it back to the
    // destination and the outer teardown knows it must be disabled.
    for scanout in created.values() {
        restore_state.register_inactive_scanout(scanout);
    }

    // Pending modes and VRR state are reversible and do not touch hardware.
    // Roll them back before returning if any reusable surface rejects either.
    let mut changed_states: Vec<(usize, Mode, bool)> = Vec::new();
    for (output, origin) in outputs.iter().zip(&plan) {
        let ScanoutOrigin::Reuse(index) = *origin else {
            continue;
        };
        let previous_mode = scanouts[index].surface.pending_mode();
        let previous_vrr = scanouts[index].surface.vrr_enabled();
        if previous_mode == output.mode && previous_vrr == output.vrr_enabled {
            continue;
        }
        changed_states.push((index, previous_mode, previous_vrr));
        let staged = scanouts[index]
            .surface
            .use_mode(output.mode)
            .map_err(|error| format!("mode staging failed: {error}"))
            .and_then(|()| {
                stage_output_vrr(&scanouts[index].surface, output)
                    .map_err(|error| error.to_string())
            });
        if let Err(error) = staged {
            let mut rollback_failures = Vec::new();
            for (changed_index, mode, vrr) in changed_states.into_iter().rev() {
                if let Err(rollback_error) = scanouts[changed_index].surface.use_vrr(vrr) {
                    rollback_failures.push(format!(
                        "{} pending-VRR rollback failed: {rollback_error}",
                        scanouts[changed_index].output.name
                    ));
                }
                if let Err(rollback_error) = scanouts[changed_index].surface.use_mode(mode) {
                    rollback_failures.push(format!(
                        "{} pending-mode rollback failed: {rollback_error}",
                        scanouts[changed_index].output.name
                    ));
                }
            }
            if rollback_failures.is_empty() {
                return Err(format!("{} state staging failed: {error}", output.name).into());
            }
            return Err(format!(
                "{} state staging failed: {error}; rollback failures: {}",
                output.name,
                rollback_failures.join("; ")
            )
            .into());
        }
    }

    // Every fallible operation is complete. Transfer ownership into the
    // journal without dropping the old-only surfaces.
    let mut retired = std::mem::take(scanouts)
        .into_iter()
        .map(Some)
        .collect::<Vec<_>>();
    let mut candidate = Vec::with_capacity(outputs.len());
    let mut origins = Vec::with_capacity(outputs.len());
    for (desired_index, ((output, source_rect), origin)) in
        outputs.into_iter().zip(source_rects).zip(plan).enumerate()
    {
        match origin {
            ScanoutOrigin::Reuse(index) => {
                let mut scanout = retired[index]
                    .take()
                    .expect("reconcile planner reused a scanout twice");
                let previous = PreviousScanoutState {
                    index,
                    output: scanout.output,
                    source_rect: scanout.source_rect,
                    pending_mode: changed_states
                        .iter()
                        .find_map(|(changed_index, mode, _)| {
                            (*changed_index == index).then_some(*mode)
                        })
                        .unwrap_or_else(|| scanout.surface.pending_mode()),
                    pending_vrr: changed_states
                        .iter()
                        .find_map(|(changed_index, _, vrr)| {
                            (*changed_index == index).then_some(*vrr)
                        })
                        .unwrap_or_else(|| scanout.surface.vrr_enabled()),
                };
                scanout.output = output;
                scanout.source_rect = source_rect;
                candidate.push(scanout);
                origins.push(ReconciledScanoutOrigin::Reused(Box::new(previous)));
            }
            ScanoutOrigin::Create => {
                candidate.push(
                    created
                        .remove(&desired_index)
                        .expect("prepared scanout missing from reconcile journal"),
                );
                origins.push(ReconciledScanoutOrigin::Created);
            }
        }
    }
    debug_assert!(created.is_empty());
    Ok(ScanoutReconciliation {
        destination: scanouts,
        candidate,
        retired,
        origins,
        resolved: false,
    })
}

pub(super) fn scanout_rollback_framebuffers(
    swapchain: &RenderSwapchains,
) -> Result<ScanoutRollbackFramebuffers, Box<dyn Error>> {
    #[cfg(feature = "flutter")]
    if let Some(swapchains) = swapchain.outputs() {
        let outputs = swapchains
            .outputs
            .iter()
            .map(|pool| {
                let framebuffer = pool
                    .buffers
                    .get(pool.current)
                    .ok_or("physical output rollback index exceeds its pool")?
                    .framebuffer();
                Ok((pool.output_id, (framebuffer, pool.size)))
            })
            .collect::<Result<BTreeMap<_, _>, Box<dyn Error>>>()?;
        return Ok(ScanoutRollbackFramebuffers::Outputs(outputs));
    }
    Ok(ScanoutRollbackFramebuffers::Atlas(
        swapchain
            .atlas()
            .ok_or("diagnostic rollback has no atlas swapchain")?
            .current_framebuffer(),
    ))
}

pub(super) fn rollback_hotplug_scanouts(
    reconciliation: ScanoutReconciliation<'_>,
    old_framebuffers: &ScanoutRollbackFramebuffers,
    progress: &mut HotplugProgress,
    events: &mut RuntimeState,
) -> Vec<String> {
    events.pending.clear();
    let hardware = progress.rollback_required();
    let failures = reconciliation.rollback(old_framebuffers, hardware);
    if hardware {
        progress.mark_rolled_back();
    }
    failures
}

pub(super) fn hotplug_transaction_error(
    cause: String,
    rollback_failures: Vec<String>,
) -> Box<dyn Error> {
    if rollback_failures.is_empty() {
        format!("hotplug transaction aborted: {cause}; previous scanout restored").into()
    } else {
        format!(
            "hotplug transaction aborted: {cause}; rollback failures: {}",
            rollback_failures.join("; ")
        )
        .into()
    }
}

pub(super) fn wait_for_page_flips(
    drm: &mut DrmDevice,
    scanouts: &[Scanout],
    framebuffers: &dyn ScanoutFramebufferSource,
    event_loop: &mut EventLoop<'_, RuntimeState>,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    let deadline = Instant::now() + Duration::from_secs(2);
    while !events.pending.is_empty() {
        event_loop.dispatch(Duration::from_millis(100), events)?;
        service_session_lifecycle(
            drm,
            scanouts,
            framebuffers,
            event_loop,
            events,
            Some(deadline),
        )?;
        if let Some(error) = events.error.take() {
            return Err(format!("DRM event error: {error}").into());
        }
        if events.device_removed {
            return Err("the active DRM device was removed during a page flip".into());
        }
        if !events.pending.is_empty() && Instant::now() >= deadline {
            return Err(format!("timed out waiting for vblank on {:?}", events.pending).into());
        }
    }
    // Synchronous/global callers consume completion as a set through
    // `pending`; only the independent Flutter scheduler needs the ordered CRTC
    // queue, and it does not use this helper in steady state.
    events.completed_page_flips.clear();
    Ok(())
}

pub(super) fn source_rects_for_atlas(
    atlas: &AtlasPlan,
    scanouts: &[Scanout],
) -> Result<Vec<PixelRect>, Box<dyn Error>> {
    if atlas.outputs.len() != scanouts.len() {
        return Err("atlas/output count mismatch during layout transition".into());
    }
    scanouts
        .iter()
        .map(|scanout| {
            atlas
                .outputs
                .iter()
                .find(|output| output.id == scanout.output.id)
                .map(|output| output.source_rect)
                .ok_or_else(|| {
                    format!(
                        "{} is missing from the reconfigured atlas",
                        scanout.output.name
                    )
                    .into()
                })
        })
        .collect()
}

pub(super) fn restore_source_rects(scanouts: &mut [Scanout], source_rects: &[PixelRect]) {
    for (scanout, source_rect) in scanouts.iter_mut().zip(source_rects) {
        scanout.source_rect = *source_rect;
    }
}

pub(super) fn queue_atlas_page_flip(
    drm: &DrmDevice,
    scanouts: &[Scanout],
    framebuffer: framebuffer::Handle,
    fence: Option<BorrowedFd<'_>>,
) -> Result<(), Box<dyn Error>> {
    drm.atomic_commit(
        AtomicCommitFlags::PAGE_FLIP_EVENT | AtomicCommitFlags::NONBLOCK,
        atlas_plane_request(scanouts, framebuffer, fence)?,
    )?;
    Ok(())
}

pub(super) fn test_atlas_page_flip(
    drm: &DrmDevice,
    scanouts: &[Scanout],
    framebuffer: framebuffer::Handle,
) -> Result<(), Box<dyn Error>> {
    drm.atomic_commit(
        AtomicCommitFlags::TEST_ONLY,
        atlas_plane_request(scanouts, framebuffer, None)?,
    )?;
    Ok(())
}

pub(super) fn atlas_plane_request(
    scanouts: &[Scanout],
    framebuffer: framebuffer::Handle,
    fence: Option<BorrowedFd<'_>>,
) -> Result<AtomicModeReq, Box<dyn Error>> {
    let mut request = AtomicModeReq::new();
    for scanout in scanouts.iter().filter(|scanout| scanout.powered) {
        let properties = scanout.plane_properties;
        let plane: RawResourceHandle = scanout.surface.plane().into();
        request.add_raw_property(
            plane,
            properties.framebuffer,
            u64::from(u32::from(framebuffer)),
        );
        request.add_raw_property(
            plane,
            properties.source_x,
            u64::from(scanout.source_rect.x) << 16,
        );
        request.add_raw_property(
            plane,
            properties.source_y,
            u64::from(scanout.source_rect.y) << 16,
        );
        request.add_raw_property(
            plane,
            properties.source_width,
            u64::from(scanout.source_rect.width) << 16,
        );
        request.add_raw_property(
            plane,
            properties.source_height,
            u64::from(scanout.source_rect.height) << 16,
        );
        if let Some((property, value)) = scanout.rotation_property(scanout.output.transform)? {
            request.add_raw_property(plane, property, value);
        }
        if let Some(property) = properties.in_fence_fd {
            let value = fence
                .map(|fence| (i64::from(fence.as_raw_fd())) as u64)
                .unwrap_or(u64::MAX);
            request.add_raw_property(plane, property, value);
        }
    }
    Ok(request)
}
