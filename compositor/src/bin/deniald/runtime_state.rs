//! Shared calloop state and bounded cross-stage event queues.

use super::*;

#[derive(Default)]
pub(super) struct RuntimeState {
    pub(super) pending: HashSet<crtc::Handle>,
    pub(super) completed_page_flips: VecDeque<PageFlipCompletion>,
    pub(super) scanout_rebased: bool,
    pub(super) error: Option<String>,
    pub(super) lifecycle: LifecycleState,
    pub(super) native_escape_shortcut: NativeEscapeShortcut,
    pub(super) topology_dirty: bool,
    pub(super) output_power_requests: BTreeMap<OutputId, bool>,
    #[cfg(feature = "flutter")]
    pub(super) kms_reconfigure_requested: bool,
    #[cfg(feature = "flutter")]
    pub(super) resident_geometry_reconfigure_requested: bool,
    pub(super) device_removed: bool,
    pub(super) wayland: Option<wayland_frontend::WaylandFrontend>,
    pub(super) clipboard: clipboard::ClipboardManager,
    pub(super) clipboard_capture_tokens: Vec<RegistrationToken>,
    pub(super) clipboard_deferred_capture: Option<wayland_frontend::DeferredClipboardCapture>,
    pub(super) scene_sync: SceneSyncState,
    pub(super) system_controls: Option<SystemControls>,
    pub(super) vblank_events: u64,
    #[cfg(feature = "flutter")]
    pub(super) flutter_events: Vec<flutter_runtime::RuntimeEvent>,
    #[cfg(feature = "flutter")]
    pub(super) sampled_buffer_releases:
        Vec<(Option<OwnedFd>, flutter_runtime::SampledBufferHoldBatch)>,
    #[cfg(feature = "flutter")]
    pub(super) native_app_plugins: Option<native_app_plugin::NativeAppPluginManager>,
    #[cfg(feature = "flutter")]
    pub(super) native_plugin_actions: VecDeque<native_app_plugin::NativePluginAction>,
    #[cfg(feature = "flutter")]
    pub(super) native_release_commands: VecDeque<native_app_plugin::NativeReleaseCommand>,
    #[cfg(feature = "flutter")]
    pub(super) native_ready_frames: Vec<native_app_plugin::NativeFrameKey>,
    #[cfg(feature = "flutter")]
    pub(super) native_release_sender: Option<
        smithay::reexports::calloop::channel::Sender<native_app_plugin::NativeReleaseCommand>,
    >,
    #[cfg(feature = "flutter")]
    pub(super) native_plugin_formats: Vec<native_app_plugin::NativeAppFormatV1>,
    #[cfg(feature = "flutter")]
    pub(super) native_plugin_default_size: (u32, u32),
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
    pub(super) keyboard_devices: BTreeMap<String, smithay::reexports::input::Device>,
    #[cfg(feature = "flutter")]
    pub(super) touchpad_devices: BTreeMap<String, smithay::reexports::input::Device>,
    #[cfg(feature = "flutter")]
    pub(super) input_device_capabilities_changed: bool,
    #[cfg(feature = "flutter")]
    pub(super) pending_window_events: PendingWindowEventQueue,
    #[cfg(feature = "flutter")]
    pub(super) pending_unpublished_window_events: PendingWindowEventQueue,
    #[cfg(feature = "flutter")]
    pub(super) pending_shell_actions: VecDeque<(wire::ShellAction, Option<i64>)>,
    #[cfg(feature = "flutter")]
    pub(super) pending_shortcut_launches: VecDeque<native_shortcut::ShortcutTarget>,
    #[cfg(feature = "flutter")]
    pub(super) pending_screenshot_selection: Option<OutputId>,
    #[cfg(feature = "flutter")]
    pub(super) published_window_ids: HashSet<u64>,
    #[cfg(feature = "flutter")]
    pub(super) restored_window_ids: BTreeSet<u64>,
    #[cfg(feature = "flutter")]
    pub(super) notification_server: Option<NotificationServer>,
    #[cfg(feature = "flutter")]
    pub(super) pending_notification_events: VecDeque<notification_server::NotificationEvent>,
    #[cfg(feature = "flutter")]
    pub(super) pending_output_applies: VecDeque<PendingOutputApply>,
    #[cfg(feature = "flutter")]
    pub(super) pending_output_confirmations: VecDeque<PendingOutputConfirmation>,
    #[cfg(feature = "flutter")]
    pub(super) pending_orientation: Option<orientation_sensor::Orientation>,
    #[cfg(feature = "flutter")]
    pub(super) output_control_dirty: bool,
    #[cfg(feature = "flutter")]
    pub(super) dpms_wake_topology_grace_until: Option<Instant>,
    #[cfg(feature = "flutter")]
    pub(super) topology_recheck_at: Option<Instant>,
    #[cfg(feature = "flutter")]
    pub(super) pending_ui_development: VecDeque<PendingUiDevelopment>,
    #[cfg(feature = "flutter")]
    pub(super) idle_dpms: idle_policy::IdleDpmsPolicy,
}

#[cfg(feature = "flutter")]
impl RuntimeState {
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
            self.pending_shell_actions.push_back((action, monitor_id));
        } else {
            warn!(
                limit = MAX_PENDING_SHELL_ACTIONS,
                "dropping excess native shell shortcut"
            );
        }
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
        self.restored_window_ids.clear();
        self.restored_window_ids
            .extend(self.published_window_ids.drain());
        self.flutter_input.resize(size);
        if let Some(frontend) = self.wayland.as_mut() {
            frontend.reset_flutter_input_generation();
        }
        self.synchronize_flutter_pointer_position();
        self.flutter_channel_closed = false;
        self.scene_sync.invalidate_runtime();
        self.pending_window_events.clear();
        self.pending_unpublished_window_events.clear();
        if let Some(frontend) = self.wayland.as_ref() {
            self.pending_window_events
                .extend(frontend.replay_window_state_events());
            if let Some(tray) = frontend.xembed_tray.as_ref() {
                tray.request_replay();
            }
        }
    }

    pub(super) fn note_user_activity(&mut self) {
        let requests = self.idle_dpms.note_activity(Instant::now());
        self.queue_idle_power_requests(requests);
    }

    pub(super) fn note_dpms_wake(&mut self, now: Instant) {
        self.dpms_wake_topology_grace_until = Some(now + DPMS_WAKE_TOPOLOGY_GRACE);
    }

    pub(super) fn service_topology_recheck_deadline(&mut self, now: Instant) {
        if self
            .topology_recheck_at
            .is_some_and(|deadline| now >= deadline)
        {
            self.topology_recheck_at = None;
            self.topology_dirty = true;
        }
        if self
            .dpms_wake_topology_grace_until
            .is_some_and(|deadline| now >= deadline)
        {
            self.dpms_wake_topology_grace_until = None;
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

impl RuntimeState {
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
