//! Starts, replaces and reloads the Flutter runtime on the KMS outputs:
//! the official, custom and live-development shells, and the render
//! targets each output lends the engine.

use super::*;
use kms_state::ScanoutBuffer;

fn flutter_render_target_pools(
    swapchains: &OutputSwapchains,
) -> Vec<flutter_runtime::OutputRenderTargetPool<'_>> {
    swapchains
        .outputs
        .iter()
        .map(|pool| flutter_runtime::OutputRenderTargetPool {
            output_id: pool.output_id,
            render_view_id: pool.render_view_id,
            configuration_generation: pool.configuration_generation,
            size: pool.size,
            initial_scanout: pool.current,
            color: pool.color,
            transfers: pool
                .buffers
                .iter()
                .map(ScanoutBuffer::transfer_target)
                .collect(),
            dmabufs: pool
                .buffers
                .iter()
                .map(ScanoutBuffer::flutter_target_dmabufs)
                .collect(),
        })
        .collect()
}

pub(super) struct FlutterLauncher {
    factory: Option<flutter_runtime::FlutterRuntimeFactory>,
    offscreen_blit: bool,
    active_mode: ui_development::UiRuntimeMode,
    resident_jit_engine_fingerprint: Option<[u8; 32]>,
    ui_development: ui_development::UiDevelopmentController,
    events: Sender<flutter_runtime::RuntimeEvent>,
    authentication: Arc<authentication::AuthenticationController>,
    clipboard: clipboard::ClipboardManager,
    wayland_display: Option<OsString>,
    x11_display: Option<OsString>,
    output_control_socket: Option<OsString>,
    work_area: options::WorkAreaOptions,
    pub(super) generation: u64,
}

pub(super) struct FlutterLaunchConfiguration<'a> {
    pub(super) bundle: &'a Path,
    pub(super) offscreen_blit: bool,
    pub(super) debug_bundle: Option<PathBuf>,
    pub(super) ui_workspace: Option<PathBuf>,
}

impl FlutterLauncher {
    pub(super) fn plugin_rebuild_needed(&self) -> bool {
        self.ui_development.plugin_rebuild_needed()
    }

    pub(super) fn ui_development_deadline(&self, now: Instant) -> Option<Instant> {
        self.ui_development.plugin_health_deadline(now)
    }

    pub(super) fn new(
        configuration: FlutterLaunchConfiguration<'_>,
        events: Sender<flutter_runtime::RuntimeEvent>,
        wayland_display: Option<OsString>,
        x11_display: Option<OsString>,
        output_control_socket: Option<OsString>,
        work_area: options::WorkAreaOptions,
        start_locked: bool,
    ) -> Result<Self, Box<dyn Error>> {
        let ui_development = ui_development::UiDevelopmentController::new(
            configuration.bundle,
            configuration.debug_bundle,
            configuration.ui_workspace,
        );
        Ok(Self {
            factory: Some(flutter_runtime::FlutterRuntimeFactory::new(
                configuration.bundle,
                denial_flutter_engine::DartRuntimeMode::Aot,
            )?),
            offscreen_blit: configuration.offscreen_blit,
            active_mode: ui_development::UiRuntimeMode::OfficialOptimized,
            resident_jit_engine_fingerprint: None,
            ui_development,
            events,
            authentication: Arc::new(authentication::AuthenticationController::new(start_locked)?),
            clipboard: clipboard::ClipboardManager::default(),
            wayland_display,
            x11_display,
            output_control_socket,
            work_area,
            generation: 0,
        })
    }

    pub(super) fn uses_offscreen_blit(&self) -> bool {
        self.offscreen_blit
    }

    pub(super) fn prepare_output_targets(
        &self,
        renderer: &GlesRenderer,
        swapchains: &OutputSwapchains,
        desktop_size: PixelSize,
    ) -> Result<flutter_runtime::PreparedFlutterRenderer, Box<dyn Error>> {
        flutter_runtime::PreparedFlutterRenderer::new(
            renderer.egl_context(),
            flutter_render_target_pools(swapchains),
            desktop_size,
            self.offscreen_blit,
            self.events.clone(),
        )
    }

    pub(super) fn start(
        &mut self,
        renderer: &GlesRenderer,
        output_swapchains: &OutputSwapchains,
        scanouts: &[Scanout],
        snapshot: &TopologySnapshot,
        atlas: &AtlasPlan,
    ) -> Result<flutter_runtime::FlutterRuntime, Box<dyn Error>> {
        self.start_with_targets(renderer, output_swapchains, scanouts, snapshot, atlas, None)
    }

    pub(super) fn start_with_targets(
        &mut self,
        renderer: &GlesRenderer,
        output_swapchains: &OutputSwapchains,
        scanouts: &[Scanout],
        snapshot: &TopologySnapshot,
        atlas: &AtlasPlan,
        prepared: Option<flutter_runtime::PreparedFlutterRenderer>,
    ) -> Result<flutter_runtime::FlutterRuntime, Box<dyn Error>> {
        self.generation = self.generation.wrapping_add(1).max(1);
        if let Err(error) = self.activate_requested_factory() {
            let failed_mode = self.ui_development.desired_mode();
            if failed_mode == ui_development::UiRuntimeMode::OfficialOptimized {
                return Err(error);
            }
            self.ui_development
                .runtime_failed(failed_mode, error.as_ref());
            warn!(
                %error,
                ?failed_mode,
                "could not prepare custom Flutter runtime; restoring the packaged shell"
            );
            self.replace_factory(ui_development::UiRuntimeMode::OfficialOptimized)?;
        }
        let using_prepared = prepared.is_some();
        let runtime = self.start_with_current_factory(
            renderer,
            output_swapchains,
            scanouts,
            snapshot,
            atlas,
            prepared,
        );
        let mut runtime = match runtime {
            Ok(runtime) => runtime,
            Err(error) if self.active_mode != ui_development::UiRuntimeMode::OfficialOptimized => {
                let failed_mode = self.active_mode;
                self.ui_development
                    .runtime_failed(failed_mode, error.as_ref());
                warn!(
                    %error,
                    ?failed_mode,
                    "custom Flutter runtime failed; selecting the packaged shell"
                );
                self.replace_factory(ui_development::UiRuntimeMode::OfficialOptimized)?;
                if using_prepared {
                    // The failed engine consumed this preparation. Let the
                    // topology transaction restore its prepared rollback
                    // renderer; never reimport targets after old-engine teardown.
                    return Err(error);
                }
                self.start_with_current_factory(
                    renderer,
                    output_swapchains,
                    scanouts,
                    snapshot,
                    atlas,
                    None,
                )?
            }
            Err(error) => return Err(error),
        };
        self.ui_development
            .runtime_started(self.active_mode, self.generation);
        self.publish_ui_development_state(&mut runtime)?;
        Ok(runtime)
    }

    fn start_with_current_factory(
        &self,
        renderer: &GlesRenderer,
        output_swapchains: &OutputSwapchains,
        scanouts: &[Scanout],
        snapshot: &TopologySnapshot,
        atlas: &AtlasPlan,
        prepared: Option<flutter_runtime::PreparedFlutterRenderer>,
    ) -> Result<flutter_runtime::FlutterRuntime, Box<dyn Error>> {
        if let Some(scanout) = scanouts
            .iter()
            .find(|scanout| scanout.plane_properties.in_fence_fd.is_none())
        {
            return Err(format!(
                "{} primary KMS plane does not advertise IN_FENCE_FD; Denial requires explicit scanout fencing",
                scanout.output.name
            )
            .into());
        }
        let refresh_millihz = scanouts
            .iter()
            .map(|scanout| OutputMode::from(scanout.output.mode).refresh)
            .max()
            .ok_or("Flutter runtime has no output refresh")?;
        let launch = flutter_runtime::FlutterLaunch {
            factory: self
                .factory
                .as_ref()
                .ok_or("Flutter launcher has no active runtime factory")?,
            generation: self.generation,
            offscreen_blit: self.offscreen_blit,
            events: self.events.clone(),
            authentication: Arc::clone(&self.authentication),
            clipboard: self.clipboard.clone(),
            work_area: self.work_area.clone(),
            wayland_display: self.wayland_display.clone(),
            x11_display: self.x11_display.clone(),
            output_control_socket: self.output_control_socket.clone(),
        };
        flutter_runtime::FlutterRuntime::start(
            launch,
            renderer.egl_context(),
            flutter_render_target_pools(output_swapchains),
            snapshot,
            atlas,
            u32::try_from(refresh_millihz)?,
            prepared,
        )
    }

    fn activate_requested_factory(&mut self) -> Result<(), Box<dyn Error>> {
        let requested = self.ui_development.desired_mode();
        if requested == self.active_mode
            && self
                .factory
                .as_ref()
                .is_some_and(|f| Some(f.bundle()) == self.ui_development.bundle_for(requested))
        {
            if requested == ui_development::UiRuntimeMode::LiveDevelopment {
                let bundle = self
                    .ui_development
                    .bundle_for(requested)
                    .ok_or("live development has no configured Flutter bundle")?;
                let prepared = flutter_runtime::bundle_engine_fingerprint(bundle)?;
                ensure_resident_jit_engine_matches(
                    self.resident_jit_engine_fingerprint.as_ref(),
                    &prepared,
                )?;
            }
            return Ok(());
        }
        self.replace_factory(requested)
    }

    fn replace_factory(
        &mut self,
        requested: ui_development::UiRuntimeMode,
    ) -> Result<(), Box<dyn Error>> {
        let bundle = self
            .ui_development
            .bundle_for(requested)
            .ok_or_else(|| format!("{requested:?} has no configured Flutter bundle"))?
            .to_owned();
        let runtime = match requested {
            ui_development::UiRuntimeMode::OfficialOptimized => {
                denial_flutter_engine::DartRuntimeMode::Aot
            }
            ui_development::UiRuntimeMode::CustomOptimized => {
                if self.ui_development.uses_release_plugins() {
                    denial_flutter_engine::DartRuntimeMode::Aot
                } else {
                    denial_flutter_engine::DartRuntimeMode::AotProfile
                }
            }
            ui_development::UiRuntimeMode::LiveDevelopment => {
                denial_flutter_engine::DartRuntimeMode::Jit
            }
            ui_development::UiRuntimeMode::Unavailable => {
                return Err("cannot launch an unavailable Flutter runtime".into());
            }
        };
        let jit_engine_fingerprint = (requested == ui_development::UiRuntimeMode::LiveDevelopment)
            .then(|| flutter_runtime::bundle_engine_fingerprint(&bundle))
            .transpose()?;
        if let Some(prepared) = jit_engine_fingerprint.as_ref() {
            ensure_resident_jit_engine_matches(
                self.resident_jit_engine_fingerprint.as_ref(),
                prepared,
            )?;
        }

        // AOT and JIT Flutter libraries each own process-global Dart state.
        // The old runtime is shut down before this method is reached; release
        // its library before loading the other runtime mode.
        self.factory = None;
        self.factory = Some(
            if requested == ui_development::UiRuntimeMode::CustomOptimized
                && self.ui_development.uses_release_plugins()
            {
                flutter_runtime::FlutterRuntimeFactory::with_engine(
                    &bundle,
                    self.ui_development
                        .bundle_for(ui_development::UiRuntimeMode::OfficialOptimized)
                        .expect("packaged recovery bundle"),
                    runtime,
                )?
            } else {
                flutter_runtime::FlutterRuntimeFactory::new(&bundle, runtime)?
            },
        );
        if let Some(fingerprint) = jit_engine_fingerprint {
            self.resident_jit_engine_fingerprint = Some(fingerprint);
        }
        self.active_mode = requested;
        Ok(())
    }

    pub(super) fn synchronize_ui_development(
        &mut self,
        runtime: &mut flutter_runtime::FlutterRuntime,
    ) -> Result<bool, Box<dyn Error>> {
        let health = self
            .ui_development
            .poll_plugin_health(runtime.has_produced_frame());
        let vm_service_uri = runtime.take_vm_service_uri();
        let vm_service_changed = vm_service_uri.is_some();
        let commands = runtime.drain_ui_development_commands().collect::<Vec<_>>();
        if let Some(uri) = vm_service_uri {
            self.ui_development.set_vm_service_uri(uri);
        }
        if commands.is_empty() && !vm_service_changed && health.is_none() {
            return Ok(false);
        }
        let mut reload_requested =
            matches!(health, Some(ui_development::UiDevelopmentEffect::Reload(_)));
        for command in commands {
            if let ui_development::UiDevelopmentEffect::Reload(requested_mode) =
                self.ui_development.handle_command(command)
            {
                debug_assert_eq!(self.ui_development.desired_mode(), requested_mode);
                reload_requested = true;
            }
        }
        let publication = self.publish_ui_development_state(runtime);
        resolve_ui_development_publication(reload_requested, publication)?;
        Ok(reload_requested)
    }

    pub(super) fn handle_external_ui_development(
        &mut self,
        runtime: &mut flutter_runtime::FlutterRuntime,
        command: ui_development::UiDevelopmentCommand,
    ) -> (bool, ui_development::UiDevelopmentState) {
        let (effect, reply) = self.ui_development.handle_external_command(command);
        let reload_requested = matches!(effect, ui_development::UiDevelopmentEffect::Reload(_));
        // denialctl is the recovery path when Flutter itself is unavailable
        // or unhealthy. Updating the shell is useful, but it must never be a
        // prerequisite for accepting an external restore command.
        if let Err(error) = self.publish_ui_development_state(runtime) {
            warn!(%error, "could not publish denialctl UI state to Flutter");
        }
        (reload_requested, reply)
    }

    pub(super) fn retain_runtime_after_switch_failure(
        &mut self,
        runtime: &mut flutter_runtime::FlutterRuntime,
        error: &dyn std::fmt::Display,
    ) {
        let failed_mode = self.ui_development.desired_mode();
        self.ui_development
            .runtime_switch_failed_preserving_active(failed_mode, error);
        if let Err(publication_error) = self.publish_ui_development_state(runtime) {
            warn!(
                %publication_error,
                %error,
                ?failed_mode,
                "could not publish retained Flutter runtime after runtime switch failure"
            );
        }
    }

    fn publish_ui_development_state(
        &self,
        runtime: &mut flutter_runtime::FlutterRuntime,
    ) -> Result<(), Box<dyn Error>> {
        let packet = self.ui_development.state_packet()?;
        runtime.publish_ui_development_state(&packet)
    }

    pub(super) fn set_work_area(&mut self, work_area: options::WorkAreaOptions) {
        self.work_area = work_area;
    }
}

fn resolve_ui_development_publication(
    reload_requested: bool,
    publication: Result<(), Box<dyn Error>>,
) -> Result<(), Box<dyn Error>> {
    match publication {
        Err(error) if reload_requested => {
            // A runtime-mode switch replaces the Flutter engine in process. The
            // retiring engine can reject this final state message, but start()
            // publishes the complete state again after its replacement is up.
            warn!(
                %error,
                "could not publish UI development state before Flutter runtime refresh"
            );
            Ok(())
        }
        publication => publication,
    }
}

fn ensure_resident_jit_engine_matches(
    resident: Option<&[u8; 32]>,
    prepared: &[u8; 32],
) -> Result<(), Box<dyn Error>> {
    if resident.is_some_and(|resident| resident != prepared) {
        return Err(
            "The prepared JIT Flutter engine changed after this Denial session loaded its native development runtime. Restart the Denial session before enabling live UI development."
                .into(),
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::ensure_resident_jit_engine_matches;

    #[test]
    fn a_changed_resident_jit_engine_requires_a_session_restart() {
        let first = [0x11; 32];
        let same = [0x11; 32];
        let changed = [0x22; 32];

        assert!(ensure_resident_jit_engine_matches(None, &first).is_ok());
        assert!(ensure_resident_jit_engine_matches(Some(&first), &same).is_ok());
        let error = ensure_resident_jit_engine_matches(Some(&first), &changed)
            .expect_err("changed native JIT engine must be rejected");
        assert!(error.to_string().contains("Restart the Denial session"));
    }
}
