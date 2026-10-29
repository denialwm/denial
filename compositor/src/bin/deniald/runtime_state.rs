//! Shared calloop state and bounded cross-stage event queues.

use super::*;
use std::collections::HashMap;

/// Requests from the control socket, each waiting for its stage of the loop.
#[cfg(feature = "flutter")]
#[derive(Default)]
pub(super) struct ControlRequests {
    pub(super) output_applies: VecDeque<PendingOutputApply>,
    pub(super) output_confirmations: VecDeque<PendingOutputConfirmation>,
    pub(super) settings: VecDeque<PendingSettingsControl>,
    pub(super) system: VecDeque<PendingSystemControl>,
    /// System controls that answer once the state they set is observed.
    pub(super) system_waits: VecDeque<PendingSystemControlWait>,
    pub(super) software_dimming: VecDeque<PendingSoftwareDimming>,
    pub(super) ui_development: VecDeque<PendingUiDevelopment>,
    /// Every output draws a new frame on the next pass.
    pub(super) repaint_outputs: bool,
    /// Apps whose windows are sampled again on the next pass.
    pub(super) repaint_apps: Vec<String>,
}

/// Window events on their way to Flutter, and the windows its scene knows.
#[cfg(feature = "flutter")]
#[derive(Default)]
pub(super) struct WindowEventState {
    pub(super) pending: PendingWindowEventQueue,
    /// Events held until their window reaches Flutter's scene.
    pub(super) unpublished: PendingWindowEventQueue,
    pub(super) published_ids: HashSet<u64>,
    /// Windows a replacement Flutter generation receives as already mapped.
    pub(super) restored_ids: BTreeSet<u64>,
}

/// libinput devices by sysname, for each kind deniald configures or reads.
#[derive(Default)]
pub(super) struct InputDevices {
    #[cfg(feature = "flutter")]
    pub(super) touchscreens: BTreeMap<String, smithay::reexports::input::Device>,
    pub(super) keyboards: BTreeMap<String, smithay::reexports::input::Device>,
    #[cfg(feature = "flutter")]
    pub(super) mice: BTreeMap<String, smithay::reexports::input::Device>,
    #[cfg(feature = "flutter")]
    pub(super) touchpads: BTreeMap<String, smithay::reexports::input::Device>,
}

impl InputDevices {
    /// Whether a touchpad and a mouse are present; the shell's pointer
    /// settings depend on both.
    #[cfg(feature = "flutter")]
    pub(super) fn pointer_kinds(&self) -> (bool, bool) {
        (!self.touchpads.is_empty(), !self.mice.is_empty())
    }

    pub(super) fn remove(&mut self, sysname: &str) {
        self.keyboards.remove(sysname);
        #[cfg(feature = "flutter")]
        {
            self.touchscreens.remove(sysname);
            self.mice.remove(sysname);
            self.touchpads.remove(sysname);
        }
    }
}

#[derive(Default)]
pub(super) struct RuntimeState {
    #[cfg(feature = "flutter")]
    pub(super) fingerprint: fingerprint_presentation::Controller,
    #[cfg(feature = "flutter")]
    pub(super) screen_off_touch: screen_off_touch::Filter,
    #[cfg(feature = "flutter")]
    pub(super) wifi_power_save: wifi_power_save::WifiPowerSave,
    pub(super) pending: HashSet<crtc::Handle>,
    pub(super) completed_page_flips: VecDeque<PageFlipCompletion>,
    pub(super) presentation_timings: HashMap<crtc::Handle, presentation_clock::ModeTiming>,
    pub(super) scanout_rebased: bool,
    pub(super) error: Option<String>,
    pub(super) lifecycle: LifecycleState,
    pub(super) native_escape_shortcut: NativeEscapeShortcut,
    pub(super) topology_dirty: bool,
    pub(super) output_power_requests: BTreeMap<OutputId, bool>,
    #[cfg(feature = "flutter")]
    pub(super) kms_reconfigure_requested: bool,
    #[cfg(feature = "flutter")]
    pub(super) kms_presentation_recovery_requested: bool,
    #[cfg(feature = "flutter")]
    pub(super) resident_geometry_reconfigure_requested: bool,
    pub(super) device_removed: bool,
    pub(super) wayland: Option<wayland_frontend::WaylandFrontend>,
    pub(super) clipboard: clipboard::ClipboardManager,
    pub(super) clipboard_capture_tokens: Vec<RegistrationToken>,
    pub(super) clipboard_deferred_capture: Option<wayland_frontend::DeferredClipboardCapture>,
    pub(super) scene_sync: SceneSyncState,
    pub(super) system_controls: Option<SystemControls>,
    pub(super) gamma_control: Arc<Mutex<gamma_control::GammaController>>,
    pub(super) gamma_reapply_requested: bool,
    pub(super) vblank_events: u64,
    #[cfg(feature = "flutter")]
    pub(super) flutter_events: Vec<flutter_runtime::RuntimeEvent>,
    #[cfg(feature = "flutter")]
    pub(super) sampled_buffer_releases:
        Vec<(Option<OwnedFd>, flutter_runtime::SampledBufferHoldBatch)>,
    #[cfg(feature = "flutter")]
    pub(super) ready_fence_signals: Vec<output_scheduler::ReadyFenceSignal>,
    #[cfg(feature = "flutter")]
    pub(super) volition_events: Vec<denial_core::volition::Event>,
    #[cfg(feature = "flutter")]
    pub(super) flutter_channel_closed: bool,
    #[cfg(feature = "flutter")]
    pub(super) flutter_reload_requested: bool,
    #[cfg(feature = "flutter")]
    pub(super) flutter_active: bool,
    #[cfg(feature = "flutter")]
    pub(super) authentication: Option<Arc<authentication::AuthenticationController>>,
    #[cfg(feature = "flutter")]
    pub(super) session_lock_applied: bool,
    #[cfg(feature = "flutter")]
    pub(super) flutter_input: flutter_runtime::InputQueue,
    #[cfg(feature = "flutter")]
    pub(super) touchpad_gestures: touchpad_gestures::TouchpadGestureRecognizer,
    #[cfg(feature = "flutter")]
    pub(super) input_deck: input_deck::Controller,
    pub(super) input_devices: InputDevices,
    #[cfg(feature = "flutter")]
    pub(super) input_device_capabilities_changed: bool,
    #[cfg(feature = "flutter")]
    pub(super) settings_external_change_pending: bool,
    #[cfg(feature = "flutter")]
    pub(super) window_events: WindowEventState,
    #[cfg(feature = "flutter")]
    pub(super) pending_shell_actions: VecDeque<PendingShellAction>,
    pub(super) plugin_actions: plugin_actions::ActionCatalog,
    /// The color tuning editor shows again once the restarted shell
    /// publishes its actions.
    #[cfg(feature = "flutter")]
    pub(super) reopen_color_tuning: bool,
    #[cfg(feature = "flutter")]
    pub(super) pending_shortcut_launches: VecDeque<native_shortcut::ShortcutTarget>,
    #[cfg(feature = "flutter")]
    pub(super) pending_screenshot_selection: Option<OutputId>,
    #[cfg(feature = "flutter")]
    pub(super) replacement_flutter_rehydration_pending: bool,
    #[cfg(feature = "flutter")]
    pub(super) notification_server: Option<NotificationServer>,
    #[cfg(feature = "flutter")]
    pub(super) portal_ipc: Option<portal_ipc::PortalIpcPublisher>,
    #[cfg(feature = "flutter")]
    pub(super) published_theme_snapshot: Option<DesktopThemeSnapshot>,
    #[cfg(feature = "flutter")]
    pub(super) published_settings_document_revision: Option<u64>,
    #[cfg(feature = "flutter")]
    pub(super) resolved_theme_accent: DesktopAccentColor,
    #[cfg(feature = "flutter")]
    pub(super) pending_notification_events: VecDeque<notification_server::NotificationEvent>,
    #[cfg(feature = "flutter")]
    pub(super) control: ControlRequests,
    #[cfg(feature = "flutter")]
    pub(super) pending_orientation: Option<orientation_sensor::Orientation>,
    /// Power plus Volume Down asked for a full-screen screenshot.
    #[cfg(feature = "flutter")]
    pub(super) screenshot_requested: bool,
    #[cfg(feature = "flutter")]
    pub(super) text_prediction: Option<text_prediction::TextPredictionService>,
    #[cfg(feature = "flutter")]
    pub(super) pending_text_prediction: Option<wire::TextPrediction>,
    #[cfg(feature = "flutter")]
    pub(super) lid: lid_switch::LidSwitch,
    #[cfg(feature = "flutter")]
    pub(super) output_control_dirty: bool,
    #[cfg(feature = "flutter")]
    pub(super) output_control: Option<output_control::OutputControlPublisher>,
    #[cfg(feature = "flutter")]
    pub(super) dpms_topology: dpms::DpmsTopologyGuard,
    #[cfg(feature = "flutter")]
    pub(super) sleep_transition: sleep_transition::SleepTransitionState,
    #[cfg(feature = "flutter")]
    pub(super) idle_policy: idle_policy::IdlePolicy,
    #[cfg(feature = "flutter")]
    pub(super) power_button: idle_policy::PowerButton,
    #[cfg(feature = "flutter")]
    pub(super) wake_gesture_outputs: BTreeSet<String>,
}

#[cfg(feature = "flutter")]
impl RuntimeState {
    /// Takes one control-socket request. Shell commands are answered at
    /// once; the rest wait for the loop stage that serves them.
    pub(super) fn receive_control(&mut self, event: ControlEvent) {
        let control = &mut self.control;
        match event {
            ControlEvent::OutputApply(request) => control.output_applies.push_back(request),
            ControlEvent::OutputConfirmation(request) => {
                control.output_confirmations.push_back(request);
            }
            ControlEvent::Settings(request) => control.settings.push_back(request),
            ControlEvent::SystemControl(request) => control.system.push_back(request),
            ControlEvent::SoftwareDimming(request) => control.software_dimming.push_back(request),
            ControlEvent::UiDevelopment(request) => control.ui_development.push_back(request),
            ControlEvent::RepaintOutputs => control.repaint_outputs = true,
            ControlEvent::RepaintApp(app_id) => control.repaint_apps.push(app_id),
            ControlEvent::RebuildOutputs => {
                info!("rebuilding output pools for a display color change");
                self.kms_reconfigure_requested = true;
                self.topology_dirty = true;
            }
            ControlEvent::OpenColorTuning => {
                if !self
                    .plugin_actions
                    .queue(output_control::COLOR_TUNING_ACTION.to_owned(), None)
                {
                    warn!("the shell has no color tuning editor");
                }
            }
            ControlEvent::ReopenColorTuning => self.reopen_color_tuning = true,
            ControlEvent::SaveColor(change) => {
                let settings = &mut self.frontend_mut().settings;
                let color = settings.color().clone().with(change);
                if color != *settings.color()
                    && let Err(error) = settings
                        .prepare_color_update(settings.revision(), color)
                        .and_then(|prepared| settings.commit(prepared))
                {
                    warn!(%error, "could not save the display color settings");
                }
            }
            ControlEvent::Shell(request) => {
                let result = if self.secure_session_locked() {
                    Err(OutputControlFailure::new(
                        "locked",
                        "shell commands are unavailable while the secure session is locked",
                    ))
                } else {
                    match request.command {
                        ShellControlCommand::OpenWallpaper => {
                            self.queue_shell_action(wire::ShellAction::Wallpaper, None)
                        }
                    }
                    Ok(())
                };
                request.reply(result);
            }
        }
    }

    pub(super) fn secure_session_locked(&self) -> bool {
        self.session_lock_applied
            || self
                .authentication
                .as_ref()
                .is_some_and(|authentication| authentication.locked())
    }

    pub(super) fn queue_shell_action(
        &mut self,
        action: wire::ShellAction,
        monitor_id: Option<i64>,
    ) {
        const MAX_PENDING_SHELL_ACTIONS: usize = 64;
        if self.pending_shell_actions.len() < MAX_PENDING_SHELL_ACTIONS {
            self.pending_shell_actions.push_back(PendingShellAction {
                action,
                monitor_id,
                workspace_id: None,
            });
        } else {
            warn!(
                limit = MAX_PENDING_SHELL_ACTIONS,
                "dropping excess native shell shortcut"
            );
        }
    }

    pub(super) fn queue_workspace_action(&mut self, monitor_id: i64, workspace_id: u8) {
        const MAX_PENDING_SHELL_ACTIONS: usize = 64;
        if self.pending_shell_actions.len() < MAX_PENDING_SHELL_ACTIONS {
            self.pending_shell_actions.push_back(PendingShellAction {
                action: wire::ShellAction::WorkspaceChanged,
                monitor_id: Some(monitor_id),
                workspace_id: Some(workspace_id),
            });
        } else {
            warn!(
                limit = MAX_PENDING_SHELL_ACTIONS,
                "dropping excess workspace state update"
            );
        }
    }

    pub(super) fn install_workspace_snapshot(
        &self,
        runtime: &mut flutter_runtime::FlutterRuntime,
    ) -> Result<(), Box<dyn Error>> {
        runtime.set_active_workspaces(
            self.wayland
                .as_ref()
                .map(wayland_frontend::WaylandFrontend::workspace_state_snapshot)
                .unwrap_or_default(),
        )
    }

    pub(super) fn request_screenshot_selection(&mut self, monitor_id: Option<i64>) {
        let output = monitor_id
            .and_then(|monitor_id| u64::try_from(monitor_id).ok())
            .map(OutputId);
        if let Some(output) = output {
            self.pending_screenshot_selection = Some(output);
        } else {
            warn!("screenshot shortcut has no output under the pointer");
        }
    }

    pub(super) fn compositor_pointer_in_flutter_pixels(&self) -> Option<(f64, f64)> {
        self.wayland
            .as_ref()
            .map(wayland_frontend::WaylandFrontend::flutter_pointer_position_physical)
    }

    /// Makes the Flutter engine's mouse state a projection of the compositor
    /// pointer instead of an independently integrated libinput position.
    pub(super) fn synchronize_flutter_pointer_position(&mut self) {
        let Some((x, y)) = self.compositor_pointer_in_flutter_pixels() else {
            return;
        };
        self.flutter_input.synchronize_pointer_position(x, y);
    }

    /// Starts a new Flutter generation without making the existing Wayland
    /// scene look newly mapped. The replacement runtime receives this exact
    /// set with its first window snapshot and can suppress entrance effects
    /// without changing lasting animation policy for those windows.
    pub(super) fn begin_replacement_flutter_generation(&mut self, size: PixelSize) {
        let windows = &mut self.window_events;
        windows.restored_ids.clear();
        windows.restored_ids.extend(windows.published_ids.drain());
        self.flutter_input.resize(size);
        let restore_shell_focus = self
            .wayland
            .as_mut()
            .is_some_and(|frontend| frontend.reset_flutter_input_generation());
        if restore_shell_focus {
            wayland_frontend::restore_shell_keyboard_focus(self);
        }
        self.synchronize_flutter_pointer_position();
        self.flutter_channel_closed = false;
        self.scene_sync.invalidate_runtime();
        self.window_events.pending.clear();
        self.window_events.unpublished.clear();
        // The replacement engine can accept platform messages before its
        // widget tree has subscribed to broadcast event streams. The first
        // fresh InputLayout is the generation-ready acknowledgement: it is
        // published after the shell and its event coordinators have mounted.
        self.replacement_flutter_rehydration_pending = true;
    }

    pub(super) fn queue_replacement_flutter_rehydration_if_ready(
        &mut self,
        first_generation_layout: bool,
    ) {
        if !first_generation_layout
            || !std::mem::take(&mut self.replacement_flutter_rehydration_pending)
        {
            return;
        }
        let (window_focus, workspace_states) = self.wayland.as_ref().map_or_else(
            || (None, Vec::new()),
            |frontend| {
                frontend.xwayland.request_xembed_replay();
                (
                    frontend.replay_window_focus_event(),
                    frontend.workspace_state_snapshot(),
                )
            },
        );
        if let Some(window_focus) = window_focus {
            self.window_events.pending.push(window_focus);
        }
        if let Some(server) = &self.notification_server
            && !server.replay()
        {
            warn!("could not queue the notification replay for the new shell");
        }
        for (monitor_id, workspace_id) in workspace_states {
            self.queue_workspace_action(monitor_id, workspace_id);
        }
    }

    pub(super) fn note_user_activity(&mut self) {
        crate::cpu_scheduling::note_interaction();
        let requests = self.idle_policy.note_activity(Instant::now());
        self.queue_idle_power_requests(requests);
        if let Some(frontend) = self.wayland.as_mut() {
            frontend.note_idle_activity();
        }
    }

    pub(super) fn queue_idle_power_requests(
        &mut self,
        requests: impl IntoIterator<Item = idle_policy::IdlePowerRequest>,
    ) {
        for request in requests {
            self.output_power_requests
                .insert(request.output, request.powered);
        }
    }
}

#[cfg(feature = "flutter")]
pub(super) struct PendingShellAction {
    pub(super) action: wire::ShellAction,
    pub(super) monitor_id: Option<i64>,
    pub(super) workspace_id: Option<u8>,
}

impl RuntimeState {
    /// The Wayland frontend, for code that only runs once it exists: Wayland
    /// requests and the work they cause.
    pub(super) fn frontend(&self) -> &wayland_frontend::WaylandFrontend {
        self.wayland.as_ref().expect("missing Wayland frontend")
    }

    pub(super) fn frontend_mut(&mut self) -> &mut wayland_frontend::WaylandFrontend {
        self.wayland.as_mut().expect("missing Wayland frontend")
    }

    pub(super) fn client_activation_permitted(&self) -> bool {
        #[cfg(feature = "flutter")]
        {
            !self.secure_session_locked()
        }
        #[cfg(not(feature = "flutter"))]
        {
            true
        }
    }
}

#[cfg(all(test, feature = "flutter"))]
mod tests {
    use super::*;

    #[test]
    fn replacement_rehydration_waits_for_the_first_input_layout() {
        let mut state = RuntimeState {
            replacement_flutter_rehydration_pending: true,
            ..RuntimeState::default()
        };

        state.queue_replacement_flutter_rehydration_if_ready(false);
        assert!(state.replacement_flutter_rehydration_pending);

        state.queue_replacement_flutter_rehydration_if_ready(true);
        assert!(!state.replacement_flutter_rehydration_pending);
    }
}
