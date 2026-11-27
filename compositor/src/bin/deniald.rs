#![deny(unsafe_op_in_unsafe_fn)]
#![deny(clippy::undocumented_unsafe_blocks)]

#[cfg(feature = "flutter")]
#[path = "deniald/ambient_display.rs"]
mod ambient_display;
#[path = "deniald/application_theming.rs"]
mod application_theming;
#[cfg(feature = "flutter")]
use denial_authentication as authentication;
use denial_platform::bus;
use denial_kms::client_release;
#[cfg(feature = "flutter")]
use denial_stagecraft::client_visibility;
use denial_clipboard as clipboard;
use denial_color::color_grade;
use denial_color::color_space;
use denial_platform::cpu_scheduling;
#[path = "deniald/open_file_limit.rs"]
mod open_file_limit;
#[cfg(feature = "flutter")]
#[path = "deniald/dpms.rs"]
mod dpms;
use denial_kms::egl_context;
#[cfg(feature = "flutter")]
#[path = "deniald/fingerprint_presentation.rs"]
mod fingerprint_presentation;
#[cfg(feature = "flutter")]
#[path = "deniald/fingerprint_verify.rs"]
mod fingerprint_verify;
#[cfg(feature = "flutter")]
#[path = "deniald/user_verify.rs"]
mod user_verify;
#[cfg(feature = "flutter")]
#[path = "deniald/flutter_event_loop.rs"]
mod flutter_event_loop;
#[cfg(feature = "flutter")]
#[path = "deniald/flutter_launcher.rs"]
mod flutter_launcher;
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
#[path = "deniald/gamma_control.rs"]
mod gamma_control;
#[cfg(feature = "flutter")]
use denial_kms::gpu_transfer;
use denial_kms::hotplug_transaction;
#[cfg(feature = "flutter")]
use denial_system_controls::idle_policy;
#[cfg(feature = "flutter")]
#[path = "deniald/input_deck.rs"]
mod input_deck;
use denial_window_layout::keyboard_resize;
#[path = "deniald/kms_pipeline.rs"]
mod kms_pipeline;
use denial_kms::kms_render;
#[path = "deniald/kms_session.rs"]
mod kms_session;
use denial_kms::kms_state;
#[path = "deniald/lid_switch.rs"]
mod lid_switch;
#[path = "deniald/lifecycle.rs"]
mod lifecycle;
#[cfg(feature = "flutter")]
#[path = "deniald/local_windows.rs"]
mod local_windows;
#[cfg(feature = "flutter")]
use denial_platform::loop_wake;
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
use denial_color::output_color;
#[cfg(feature = "flutter")]
use denial_color::plane_color;
#[cfg(feature = "flutter")]
#[path = "deniald/output_control.rs"]
mod output_control;
#[path = "deniald/output_policy.rs"]
mod output_policy;
#[cfg(feature = "flutter")]
#[path = "deniald/output_scheduler.rs"]
mod output_scheduler;
#[path = "deniald/output_topology.rs"]
mod output_topology;
#[path = "deniald/plugin_actions.rs"]
mod plugin_actions;
#[cfg(feature = "flutter")]
#[path = "deniald/plugin_bundle.rs"]
mod plugin_bundle;
#[path = "deniald/portal_ipc.rs"]
mod portal_ipc;
#[path = "deniald/presentation_clock.rs"]
mod presentation_clock;
#[path = "deniald/runtime_state.rs"]
mod runtime_state;
#[path = "deniald/scene_sync.rs"]
mod scene_sync;
#[cfg(feature = "flutter")]
#[path = "deniald/screen_off_touch.rs"]
mod screen_off_touch;
#[cfg(feature = "flutter")]
#[path = "deniald/screenshot.rs"]
mod screenshot;
#[path = "deniald/session_activation.rs"]
mod session_activation;
#[path = "deniald/session_end.rs"]
mod session_end;
#[path = "deniald/settings.rs"]
mod settings;
#[cfg(feature = "flutter")]
#[path = "deniald/settings_watch.rs"]
mod settings_watch;
#[cfg(feature = "flutter")]
#[path = "deniald/sleep_transition.rs"]
mod sleep_transition;
#[path = "deniald/startup.rs"]
mod startup;
#[cfg(feature = "flutter")]
use denial_stagecraft::surface_feedback;
use denial_system_controls as system_controls;
#[cfg(feature = "flutter")]
#[path = "deniald/text_prediction.rs"]
mod text_prediction;
#[cfg(feature = "flutter")]
#[path = "deniald/touchpad_gestures.rs"]
mod touchpad_gestures;
#[cfg(feature = "flutter")]
#[path = "deniald/ui_development.rs"]
mod ui_development;
#[cfg(feature = "flutter")]
use denial_platform::wakeup;
#[path = "deniald/wayland_frontend.rs"]
mod wayland_frontend;
#[path = "deniald/welcome.rs"]
mod welcome;
#[cfg(feature = "flutter")]
#[path = "deniald/wifi_power_save.rs"]
mod wifi_power_save;
#[cfg(feature = "flutter")]
#[path = "deniald/lights.rs"]
mod lights;
#[cfg(feature = "flutter")]
#[path = "deniald/window_events.rs"]
mod window_events;
#[path = "deniald/window_grab.rs"]
mod window_grab;
use denial_window_layout as window_layout;
#[path = "deniald/window_placement_store.rs"]
mod window_placement_store;
#[cfg(feature = "flutter")]
#[path = "deniald/wire.rs"]
mod wire;
#[cfg(feature = "flutter")]
#[path = "deniald/x11_input_method.rs"]
mod x11_input_method;
#[cfg(feature = "flutter")]
#[path = "deniald/xcursor_sentinel.rs"]
mod xcursor_sentinel;
#[cfg(all(feature = "flutter", feature = "xwayland"))]
#[path = "deniald/xembed_tray.rs"]
mod xembed_tray;
#[cfg(feature = "flutter")]
#[path = "deniald/xembed_tray_protocol.rs"]
mod xembed_tray_protocol;
#[cfg(feature = "xwayland")]
#[path = "deniald/xwayland_exec.rs"]
mod xwayland_exec;

use std::collections::{BTreeMap, BTreeSet, HashSet, VecDeque};
use std::error::Error;
use std::ffi::OsStr;
#[cfg(feature = "flutter")]
use std::ffi::OsString;
use std::fs::OpenOptions;
use std::os::fd::OwnedFd;
use std::os::fd::{AsRawFd, BorrowedFd};
use std::os::unix::fs::MetadataExt;
use std::panic::{AssertUnwindSafe, catch_unwind, resume_unwind};
use std::path::Path;
#[cfg(feature = "flutter")]
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
#[cfg(feature = "flutter")]
use std::time::{SystemTime, UNIX_EPOCH};

use calloop::signals::{Signal, Signals};
#[cfg(feature = "flutter")]
use denial_core::portal_protocol::{DesktopAccentColor, DesktopThemeSnapshot};
use denial_core::topology::{
    AtlasPlan, LogicalPoint, OutputId, OutputSpec, OutputTransform, PixelRect, PixelSize,
    SCALE_BASE, TopologyChange, TopologyManager, TopologySnapshot,
};
use smithay::backend::allocator::gbm::{GbmAllocator, GbmBufferFlags, GbmDevice};
#[cfg(feature = "flutter")]
use smithay::backend::allocator::{Fourcc, Modifier};
use smithay::backend::drm::{
    DrmDevice, DrmDeviceFd, DrmEvent, DrmEventTime, DrmSurface, PlaneState, VrrSupport,
};
use smithay::backend::egl::EGLDisplay;
use smithay::backend::input::AxisSource;
use smithay::backend::renderer::gles::GlesRenderer;
use smithay::backend::session::libseat::{LibSeatSession, LibSeatSessionNotifier};
use smithay::backend::session::{Event as SessionEvent, Session};
use smithay::backend::udev::{UdevBackend, UdevEvent};
use smithay::output::Mode as OutputMode;
#[cfg(feature = "flutter")]
use smithay::reexports::calloop::channel::Sender;
use smithay::reexports::calloop::{Dispatcher, EventLoop, RegistrationToken};
#[cfg(feature = "flutter")]
use smithay::reexports::calloop::{Interest, Mode as PollMode, PostAction, generic::Generic};
use smithay::reexports::drm::control::{
    AtomicCommitFlags, Device as ControlDevice, Mode, ModeTypeFlags, RawResourceHandle,
    atomic::AtomicModeReq, connector, crtc, framebuffer, property,
};
use smithay::reexports::rustix::fs::OFlags;
use smithay::utils::DeviceFd;
use smithay_drm_extras::drm_scanner::{DrmScanEvent, DrmScanner, SimpleCrtcMapper};
use tracing::{debug, error, info, warn};

const DEFAULT_QT_QPA_PLATFORMTHEME: &str = "xdgdesktopportal";

#[cfg(feature = "flutter")]
use dpms::{
    apply_output_power_requests, collect_output_power_requests, synchronize_idle_dpms,
    synchronize_idle_dpms_configuration, synchronize_power_button,
    synchronize_requested_display_power,
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
    synchronize_fingerprint_display_wake, synchronize_notification_events,
    synchronize_shell_keyboard, synchronize_system_control_events, synchronize_xembed_tray,
};
#[cfg(feature = "flutter")]
use flutter_session::{
    ActiveOutputConfirmation, FlutterReloadOutcome, begin_output_confirmation,
    cancel_active_screenshot, install_ready_fence_watch, install_sampled_buffer_releases,
    screenshot_buffer_modifier, screenshot_composite_sources, submit_ready_frames,
};
#[cfg(feature = "flutter")]
use flutter_settings_sync::{
    ResidentGeometry, apply_automatic_orientation, apply_resident_output_geometry,
    send_flutter_window_event, synchronize_fingerprint_unlock, synchronize_flutter_window_commands,
    synchronize_flutter_window_management, synchronize_resident_flutter_geometry_state,
    synchronize_settings, synchronize_system_bar_configuration,
};
use frame_loop::{FrameLoopContext, run_frame_loop};
use hotplug_transaction::{
    HotplugProgress, ScanoutKey, ScanoutOrigin, plan_reconcile,
};
use kms_render::{current_scanout_state, plane_state, render_diagnostic_atlas};
use kms_session::hold_static_scanout;
use kms_state::{
    AtlasPlaneProperties, AtlasSwapchain, ConnectedOutput, KmsContext, LayoutTransition,
    PreviousScanoutState, ReconciledScanoutOrigin, RenderSwapchains, RestoreState, Scanout,
    ScanoutAllocator, ScanoutReconciliation, ScanoutRollbackFramebuffers, scanout_gbm_flags,
    shared_atlas_format,
};
#[cfg(feature = "flutter")]
use flutter_launcher::{FlutterLaunchConfiguration, FlutterLauncher};
#[cfg(feature = "flutter")]
use kms_state::OutputSwapchains;
use lifecycle::{InactiveDispatch, LifecycleState, ShutdownReason, inactive_dispatch};
use native_shortcut::{NativeEscapeShortcut, ShortcutManager};
#[cfg(feature = "flutter")]
use notification_server::NotificationServer;
use options::{Options, RuntimeLimit, SIMULATED_HOTPLUG_GAP_FRAMES};
#[cfg(feature = "flutter")]
use output_control::{
    ControlEvent, OutputConfirmationAction, OutputControlFailure, OutputControlServer,
    PendingOutputApply, PendingOutputConfirmation, PendingSettingsControl, PendingSoftwareDimming,
    PendingSystemControl, PendingSystemControlWait, PendingUiDevelopment, SettingsControlCommand,
    ShellControlCommand, SystemControlCommand, SystemControlWaitKind,
};
use output_topology::{
    ConfiguredOutputs, ConnectedConnector, RuntimeOutputConfiguration, configured_outputs,
    connected_outputs, scan_connected_connectors, stage_output_vrr, topology_for_outputs,
    update_topology_for_outputs,
};
#[cfg(feature = "flutter")]
use output_topology::{
    configuration_from_output_request, output_control_state, output_request_changes_only_transforms,
};
#[cfg(feature = "flutter")]
use portal_ipc::PortalIpcServer;
#[cfg(feature = "flutter")]
use presentation_clock::PresentedOutput;
use presentation_clock::{PageFlipCompletion, monotonic_now, presentation_instant};
use runtime_state::RuntimeState;
use scene_sync::SceneSyncState;
#[cfg(feature = "flutter")]
use scene_sync::{WindowEventDisposition, window_event_disposition};
use session_activation::{
    finish_previous_graphical_session, preserves_predecessor_kms_state,
    publish_session_activation_environment, stop_systemd_graphical_session,
};
#[cfg(feature = "flutter")]
use sleep_transition::{release_sleep_delay_if_ready, synchronize_sleep_transition};
use startup::run;
use system_controls::SystemControls;
#[cfg(feature = "flutter")]
use window_events::{PendingWindowEvent, PendingWindowEventQueue};

const WHEEL_ANGLE_PER_STEP: f64 = 15.0;
const V120_UNITS_PER_WHEEL_STEP: f64 = 120.0;

/// Returns the logical axis distance delivered to a Wayland application.
///
/// Libinput normally supplies both a physical wheel angle and a normalized
/// v120 value. Prefer the native amount, using v120 only for backends which do
/// not provide one, and apply Denial's touchpad speed setting only to finger
/// scrolling.
fn logical_axis_scroll_delta(
    source: AxisSource,
    amount: Option<f64>,
    v120: Option<f64>,
    scroll_speed_factor: f64,
) -> f64 {
    let amount = amount
        .unwrap_or_else(|| v120.unwrap_or(0.0) * WHEEL_ANGLE_PER_STEP / V120_UNITS_PER_WHEEL_STEP);
    if source == AxisSource::Finger {
        amount * scroll_speed_factor
    } else {
        amount
    }
}

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
use denial_core::environment::render_audit_enabled;

fn main() {
    #[cfg(feature = "xwayland")]
    xwayland_exec::run_if_requested();
    #[cfg(feature = "flutter")]
    if std::env::args_os()
        .skip(1)
        .eq([std::ffi::OsString::from("--fingerprint-settings")])
    {
        if let Err(error) = authentication::fingerprint_settings::run() {
            println!("{}", serde_json::json!({"event":"unavailable"}));
            eprintln!("deniald fingerprint settings: {error}");
            std::process::exit(1);
        }
        return;
    }
    #[cfg(feature = "flutter")]
    if std::env::args_os()
        .skip(1)
        .eq([std::ffi::OsString::from("--lock-pin")])
    {
        if let Err(error) = authentication::pin::run_settings() {
            println!("{}", serde_json::json!({"event":"unavailable"}));
            eprintln!("deniald lock PIN: {error}");
            std::process::exit(1);
        }
        return;
    }

    let result = denial_main();
    #[cfg(feature = "flutter")]
    let result = result.and_then(|()| gpu_transfer::finish_process_workers().map_err(Into::into));
    if let Err(error) = result {
        // Returning Result::Err from main becomes status 1, which display
        // managers can mistake for an orderly session exit. Preserve the
        // abnormal-termination distinction (and a usable core dump) for the
        // failures which cannot be recovered inside the compositor.
        eprintln!("deniald: fatal error: {error}");
        std::process::abort();
    }
    if lifecycle::restart_requested() {
        std::process::exit(lifecycle::RESTART_EXIT_STATUS);
    }
}

fn denial_main() -> Result<(), Box<dyn Error>> {
    install_legacy_denial_environment_aliases();
    let options = Options::parse()?;
    if options.software_rendering {
        // SAFETY: option parsing happens on the process's only thread, before
        // libseat, Mesa, Flutter, or any Denial worker is initialized. Mesa
        // reads these overrides while constructing the first GBM/EGL display.
        // The driver override is required on GBM backends such as vmwgfx,
        // where LIBGL_ALWAYS_SOFTWARE alone can retain the hardware DRI driver.
        unsafe {
            std::env::set_var("LIBGL_ALWAYS_SOFTWARE", "1");
            std::env::set_var("MESA_LOADER_DRIVER_OVERRIDE", "kms_swrast");
        }
    }
    #[cfg(feature = "flutter")]
    if options.wayland && options.flutter_bundle.is_some() {
        xcursor_sentinel::install()?;
    }
    if options.start_locked {
        // SAFETY: option parsing happens on the process's only thread, before
        // libseat, authentication, Flutter, or any other worker is started.
        // Dart reads this once to make its very first visual state match the
        // already-locked native security gate.
        unsafe {
            std::env::set_var("DENIAL_START_LOCKED", "1");
            std::env::set_var("DENIA_START_LOCKED", "1");
        }
    }

    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "denial=info,smithay=info".into()),
        )
        .init();

    if options.software_rendering {
        info!(driver = "kms_swrast", "using Mesa software rendering");
    }

    if options.max_outputs == 0 {
        return Ok(());
    }
    // Before any thread or spawn: Xwayland and every worker inherit it.
    open_file_limit::raise();
    let application_cpus = cpu_scheduling::initialize_placement();
    // SAFETY: still the sole startup thread, before run() creates any native,
    // driver or engine workers. Dart's direct tool-spawn path inherits this
    // original domain; native application launches remove the metadata.
    unsafe {
        match application_cpus {
            Some(cpus) => std::env::set_var(denial_core::cpu_affinity::APPLICATION_CPUS_ENV, cpus),
            None => std::env::remove_var(denial_core::cpu_affinity::APPLICATION_CPUS_ENV),
        }
    }
    run(options)
}

fn install_legacy_denial_environment_aliases() {
    let aliases = std::env::vars_os()
        .filter_map(|(name, value)| {
            let suffix = name.to_str()?.strip_prefix("DENIAL_")?;
            Some((format!("DENIA_{suffix}"), value))
        })
        .collect::<Vec<_>>();
    // SAFETY: denial_main calls this before option parsing starts libseat,
    // Flutter, graphics drivers, or any worker thread. Canonical values win
    // so the pinned engine's legacy getenv calls observe the same setting.
    unsafe {
        for (legacy, value) in aliases {
            std::env::set_var(legacy, value);
        }
    }
}
