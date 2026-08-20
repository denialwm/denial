#![deny(unsafe_op_in_unsafe_fn)]
#![deny(clippy::undocumented_unsafe_blocks)]

#[cfg(feature = "flutter")]
#[path = "deniald/authentication.rs"]
mod authentication;
#[path = "deniald/clipboard.rs"]
mod clipboard;
#[path = "deniald/cpu_scheduling.rs"]
mod cpu_scheduling;
#[cfg(feature = "flutter")]
#[path = "deniald/dpms.rs"]
mod dpms;
#[path = "deniald/egl_context.rs"]
mod egl_context;
#[cfg(feature = "flutter")]
#[path = "deniald/flutter_event_loop.rs"]
mod flutter_event_loop;
#[cfg(feature = "flutter")]
#[path = "deniald/flutter_runtime.rs"]
mod flutter_runtime;
#[cfg(feature = "flutter")]
#[path = "deniald/flutter_scene_sync.rs"]
mod flutter_scene_sync;
#[cfg(feature = "flutter")]
#[path = "deniald/flutter_service_sync.rs"]
mod flutter_service_sync;
#[cfg(feature = "flutter")]
#[path = "deniald/flutter_session.rs"]
mod flutter_session;
#[cfg(feature = "flutter")]
#[path = "deniald/flutter_settings_sync.rs"]
mod flutter_settings_sync;
#[path = "deniald/frame_loop.rs"]
mod frame_loop;
#[cfg(feature = "flutter")]
#[path = "deniald/frame_scheduler.rs"]
mod frame_scheduler;
#[path = "deniald/hotplug_transaction.rs"]
mod hotplug_transaction;
#[cfg(feature = "flutter")]
#[path = "deniald/idle_policy.rs"]
mod idle_policy;
#[path = "deniald/kms_pipeline.rs"]
mod kms_pipeline;
#[path = "deniald/kms_render.rs"]
mod kms_render;
#[path = "deniald/kms_session.rs"]
mod kms_session;
#[path = "deniald/kms_state.rs"]
mod kms_state;
#[path = "deniald/lifecycle.rs"]
mod lifecycle;
#[cfg(feature = "flutter")]
#[path = "deniald/local_windows.rs"]
mod local_windows;
#[cfg(feature = "flutter")]
#[path = "deniald/native_app_plugin.rs"]
mod native_app_plugin;
#[path = "deniald/native_shortcut.rs"]
mod native_shortcut;
#[cfg(feature = "flutter")]
#[path = "deniald/notification_server.rs"]
mod notification_server;
#[path = "deniald/options.rs"]
mod options;
#[cfg(feature = "flutter")]
#[path = "deniald/orientation_sensor.rs"]
mod orientation_sensor;
#[cfg(feature = "flutter")]
#[path = "deniald/output_control.rs"]
mod output_control;
#[cfg(feature = "flutter")]
#[path = "deniald/output_scheduler.rs"]
mod output_scheduler;
#[path = "deniald/output_topology.rs"]
mod output_topology;
#[path = "deniald/presentation_clock.rs"]
mod presentation_clock;
#[path = "deniald/runtime_state.rs"]
mod runtime_state;
#[path = "deniald/scene_sync.rs"]
mod scene_sync;
#[cfg(feature = "flutter")]
#[path = "deniald/screenshot.rs"]
mod screenshot;
#[path = "deniald/session_activation.rs"]
mod session_activation;
#[path = "deniald/settings.rs"]
mod settings;
#[path = "deniald/startup.rs"]
mod startup;
#[path = "deniald/system_controls.rs"]
mod system_controls;
#[cfg(feature = "flutter")]
#[path = "deniald/touchpad_gestures.rs"]
mod touchpad_gestures;
#[cfg(feature = "flutter")]
#[path = "deniald/ui_development.rs"]
mod ui_development;
#[path = "deniald/wayland_frontend.rs"]
mod wayland_frontend;
#[cfg(feature = "flutter")]
#[path = "deniald/window_events.rs"]
mod window_events;
#[path = "deniald/window_grab.rs"]
mod window_grab;
#[path = "deniald/window_placement_store.rs"]
mod window_placement_store;
#[cfg(feature = "flutter")]
#[path = "deniald/wire.rs"]
mod wire;

use std::collections::{BTreeMap, BTreeSet, HashSet, VecDeque};
use std::error::Error;
use std::ffi::OsStr;
#[cfg(feature = "flutter")]
use std::ffi::OsString;
use std::fs::OpenOptions;
use std::os::fd::{AsFd, OwnedFd};
use std::os::fd::{AsRawFd, BorrowedFd};
use std::os::unix::fs::MetadataExt;
use std::panic::{AssertUnwindSafe, catch_unwind, resume_unwind};
use std::path::Path;
#[cfg(feature = "flutter")]
use std::path::PathBuf;
#[cfg(feature = "flutter")]
use std::sync::atomic::Ordering;
#[cfg(feature = "flutter")]
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use calloop::signals::{Signal, Signals};
use denial_core::topology::{
    AtlasPlan, LogicalPoint, OutputId, OutputSpec, OutputTransform, PixelRect, PixelSize,
    SCALE_BASE, TopologyChange, TopologyManager, TopologySnapshot,
};
use smithay::backend::allocator::dmabuf::{AsDmabuf, Dmabuf};
use smithay::backend::allocator::format::FormatSet;
use smithay::backend::allocator::gbm::{GbmAllocator, GbmBuffer, GbmBufferFlags, GbmDevice};
use smithay::backend::allocator::{Allocator, Buffer as AllocatorBuffer, Format, Fourcc, Modifier};
use smithay::backend::drm::gbm::{GbmFramebuffer, framebuffer_from_bo};
use smithay::backend::drm::{
    DrmDevice, DrmDeviceFd, DrmEvent, DrmEventTime, DrmSurface, PlaneConfig, PlaneState, VrrSupport,
};
use smithay::backend::egl::EGLDisplay;
use smithay::backend::renderer::gles::GlesRenderer;
use smithay::backend::renderer::{Bind, Color32F, Frame, ImportDma, Renderer};
use smithay::backend::session::libseat::LibSeatSession;
use smithay::backend::session::{Event as SessionEvent, Session};
use smithay::backend::udev::{UdevBackend, UdevEvent};
use smithay::output::Mode as OutputMode;
#[cfg(feature = "flutter")]
use smithay::reexports::calloop::channel::Sender;
use smithay::reexports::calloop::{EventLoop, RegistrationToken};
#[cfg(feature = "flutter")]
use smithay::reexports::calloop::{Interest, Mode as PollMode, PostAction, generic::Generic};
use smithay::reexports::drm::buffer::{
    DrmFourcc, DrmModifier, Handle as BufferHandle, PlanarBuffer,
};
use smithay::reexports::drm::control::{
    AtomicCommitFlags, Device as ControlDevice, FbCmd2Flags, Mode, ModeTypeFlags, PlaneType,
    RawResourceHandle, ResourceHandle, atomic::AtomicModeReq, connector, crtc, framebuffer,
    from_u32, plane, property,
};
use smithay::reexports::rustix::fs::OFlags;
use smithay::utils::{Buffer, DeviceFd, Physical, Rectangle, Transform};
use smithay_drm_extras::drm_scanner::{DrmScanEvent, DrmScanner, SimpleCrtcMapper};
use tracing::{debug, error, info, warn};

#[cfg(feature = "flutter")]
use dpms::{
    apply_output_power_requests, collect_output_power_requests, synchronize_idle_dpms,
    synchronize_idle_dpms_configuration, synchronize_requested_dpms_off,
    transient_dpms_output_removal_count,
};
#[cfg(feature = "flutter")]
use flutter_event_loop::{FlutterEventLoopContext, run_flutter_event_loop};
#[cfg(feature = "flutter")]
use flutter_scene_sync::{
    collect_flutter_output_damage, synchronize_flutter_input_layout, synchronize_flutter_scene,
    synchronize_wayland_cursor, try_synchronize_flutter_buffers,
};
#[cfg(feature = "flutter")]
use flutter_service_sync::{
    publish_software_keyboard_state, synchronize_authentication_boundary, synchronize_clipboard,
    synchronize_notification_events, synchronize_shell_keyboard, synchronize_system_control_events,
};
#[cfg(feature = "flutter")]
use flutter_session::{
    ActiveOutputConfirmation, begin_output_confirmation, cancel_active_screenshot,
    install_ready_fence_watch, install_sampled_buffer_releases, quiesce_flutter_page_flips,
    reload_flutter_runtime, screenshot_buffer_modifier, screenshot_composite_sources,
    service_native_app_plugins, submit_ready_frames,
};
#[cfg(feature = "flutter")]
use flutter_settings_sync::{
    apply_automatic_orientation, apply_resident_output_geometry, send_flutter_window_event,
    synchronize_flutter_window_management, synchronize_resident_flutter_geometry_state,
    synchronize_settings, synchronize_system_bar_configuration,
};
use frame_loop::{FrameLoopContext, run_frame_loop};
use hotplug_transaction::{
    HotplugProgress, ScanoutKey, ScanoutOrigin, append_quarantined, install_candidate,
    plan_reconcile,
};
use kms_render::{
    current_scanout_state, plane_state, render_blank_target, render_diagnostic_atlas,
};
use kms_session::hold_static_scanout;
use kms_state::{
    AtlasPlaneProperties, AtlasSwapchain, ConnectedOutput, KmsContext, LayoutTransition,
    PreviousScanoutState, ReconciledScanoutOrigin, RenderSwapchains, RestoreState, Scanout,
    ScanoutAllocator, ScanoutReconciliation, ScanoutRollbackFramebuffers, scanout_gbm_flags,
    shared_atlas_modifiers,
};
#[cfg(feature = "flutter")]
use kms_state::{FlutterLaunchConfiguration, FlutterLauncher, OutputSwapchains};
use lifecycle::{
    InactiveDispatch, LifecycleState, ShutdownReason, TeardownGate, inactive_dispatch,
};
use native_shortcut::{NativeEscapeShortcut, ShortcutManager};
#[cfg(feature = "flutter")]
use notification_server::NotificationServer;
use options::{Options, RuntimeLimit, SIMULATED_HOTPLUG_GAP_FRAMES};
#[cfg(feature = "flutter")]
use output_control::{
    ControlEvent, OutputConfirmationAction, OutputControlServer, PendingOutputApply,
    PendingOutputConfirmation, PendingUiDevelopment,
};
use output_topology::{
    ConnectedConnector, RuntimeOutputConfiguration, configured_outputs, connected_outputs,
    scan_connected_connectors, stage_output_vrr, topology_for_outputs, update_topology_for_outputs,
};
#[cfg(feature = "flutter")]
use output_topology::{
    configuration_from_output_request, output_control_state, output_request_changes_only_transforms,
};
#[cfg(feature = "flutter")]
use presentation_clock::PresentedOutput;
use presentation_clock::{PageFlipCompletion, monotonic_now, presentation_instant};
use runtime_state::RuntimeState;
use scene_sync::SceneSyncState;
#[cfg(feature = "flutter")]
use scene_sync::{WindowEventDisposition, window_event_disposition};
use session_activation::{
    preserves_predecessor_kms_state, publish_session_activation_environment,
    stop_systemd_graphical_session,
};
use startup::run;
use system_controls::SystemControls;
#[cfg(feature = "flutter")]
use window_events::{PendingWindowEvent, PendingWindowEventQueue};

const COLORS: [Color32F; 4] = [
    Color32F::new(0.16, 0.48, 0.98, 1.0),
    Color32F::new(0.95, 0.24, 0.31, 1.0),
    Color32F::new(0.20, 0.80, 0.48, 1.0),
    Color32F::new(0.72, 0.35, 0.96, 1.0),
];

#[cfg(feature = "flutter")]
const NOTIFICATION_EVENT_QUEUE_CAPACITY: usize = 512;
#[cfg(feature = "flutter")]
const DPMS_WAKE_TOPOLOGY_GRACE: Duration = Duration::from_secs(5);
#[cfg(feature = "flutter")]
const KMS_PRESENTATION_RECOVERY_RETRY: Duration = Duration::from_millis(250);
#[cfg(feature = "flutter")]
const COMPOSITOR_BACKGROUND_SLICE: Duration = Duration::from_millis(2);
#[cfg(feature = "flutter")]
const MAX_FLUTTER_EVENTS_PER_ITERATION: usize = 128;

#[cfg(feature = "flutter")]
fn render_audit_enabled() -> bool {
    static ENABLED: OnceLock<bool> = OnceLock::new();
    *ENABLED.get_or_init(|| {
        matches!(
            std::env::var("DENIA_RENDER_AUDIT")
                .ok()
                .as_deref()
                .map(str::trim)
                .map(str::to_ascii_lowercase)
                .as_deref(),
            Some("1" | "true" | "yes" | "on")
        )
    })
}

fn main() {
    if let Err(error) = denial_main() {
        // Returning Result::Err from main becomes status 1, which display
        // managers can mistake for an orderly session exit. Preserve the
        // abnormal-termination distinction (and a usable core dump) for the
        // failures which cannot be recovered inside the compositor.
        eprintln!("deniald: fatal error: {error}");
        std::process::abort();
    }
}

fn denial_main() -> Result<(), Box<dyn Error>> {
    let options = Options::parse()?;
    if options.start_locked {
        // SAFETY: option parsing happens on the process's only thread, before
        // libseat, authentication, Flutter, or any other worker is started.
        // Dart reads this once to make its very first visual state match the
        // already-locked native security gate.
        unsafe {
            std::env::set_var("DENIA_START_LOCKED", "1");
        }
    }

    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "denial_kms=info,smithay=info".into()),
        )
        .init();

    if options.max_outputs == 0 {
        return Ok(());
    }
    run(options)
}
