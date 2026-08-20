#![deny(unsafe_op_in_unsafe_fn)]
#![deny(clippy::undocumented_unsafe_blocks)]

#[cfg(feature = "flutter")]
#[path = "deniald/authentication.rs"]
mod authentication;
#[path = "deniald/clipboard.rs"]
mod clipboard;
#[path = "deniald/cpu_scheduling.rs"]
mod cpu_scheduling;
#[path = "deniald/egl_context.rs"]
mod egl_context;
#[cfg(feature = "flutter")]
#[path = "deniald/flutter_runtime.rs"]
mod flutter_runtime;
#[cfg(feature = "flutter")]
#[path = "deniald/frame_scheduler.rs"]
mod frame_scheduler;
#[path = "deniald/hotplug_transaction.rs"]
mod hotplug_transaction;
#[cfg(feature = "flutter")]
#[path = "deniald/idle_policy.rs"]
mod idle_policy;
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
#[path = "deniald/scene_sync.rs"]
mod scene_sync;
#[cfg(feature = "flutter")]
#[path = "deniald/screenshot.rs"]
mod screenshot;
#[path = "deniald/settings.rs"]
mod settings;
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

use hotplug_transaction::{
    HotplugProgress, ScanoutKey, ScanoutOrigin, append_quarantined, install_candidate,
    plan_reconcile,
};
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
use scene_sync::SceneSyncState;
#[cfg(feature = "flutter")]
use scene_sync::{WindowEventDisposition, window_event_disposition};
use system_controls::SystemControls;
#[cfg(feature = "flutter")]
use window_events::{PendingWindowEvent, PendingWindowEventQueue};

const COLORS: [Color32F; 4] = [
    Color32F::new(0.16, 0.48, 0.98, 1.0),
    Color32F::new(0.95, 0.24, 0.31, 1.0),
    Color32F::new(0.20, 0.80, 0.48, 1.0),
    Color32F::new(0.72, 0.35, 0.96, 1.0),
];
const DENIAL_SESSION_TARGET: &str = "denial-session.target";
const GRAPHICAL_SESSION_TARGET: &str = "graphical-session.target";
const SYSTEMD_DBUS_NAME: &str = "org.freedesktop.systemd1";

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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct OutputModePreference {
    width: Option<u32>,
    height: Option<u32>,
    refresh_millihz: Option<u32>,
}

#[derive(Clone, Debug)]
struct RuntimeOutputConfiguration {
    positions: BTreeMap<String, LogicalPoint>,
    modes: BTreeMap<String, OutputModePreference>,
    scales_120: BTreeMap<String, u32>,
    transforms: BTreeMap<String, OutputTransform>,
    /// Transient device rotation from iio-sensor-proxy. `transforms` remains
    /// the persistent panel-mount baseline.
    sensor_rotation: OutputTransform,
    vrr_outputs: BTreeSet<String>,
    disabled_outputs: BTreeSet<String>,
}

#[derive(Clone, Debug)]
struct ConnectedConnector {
    info: connector::Info,
    crtc: crtc::Handle,
}

impl RuntimeOutputConfiguration {
    fn from_options(options: &Options) -> Self {
        let mut modes = options
            .refresh_millihz
            .iter()
            .map(|(name, refresh_millihz)| {
                (
                    name.clone(),
                    OutputModePreference {
                        width: None,
                        height: None,
                        refresh_millihz: Some(*refresh_millihz),
                    },
                )
            })
            .collect::<BTreeMap<_, _>>();
        for (name, (width, height)) in &options.mode_sizes {
            let preference = modes.entry(name.clone()).or_insert(OutputModePreference {
                width: None,
                height: None,
                refresh_millihz: None,
            });
            preference.width = Some(*width);
            preference.height = Some(*height);
        }
        Self {
            positions: options.positions.clone(),
            modes,
            scales_120: options.scales_120.clone(),
            transforms: options.transforms.clone(),
            sensor_rotation: OutputTransform::Normal,
            vrr_outputs: options.vrr_outputs.clone(),
            disabled_outputs: options.disabled_outputs.clone(),
        }
    }

    fn effective_transform(&self, name: &str) -> OutputTransform {
        let baseline = self
            .transforms
            .get(name)
            .copied()
            .unwrap_or(OutputTransform::Normal);
        if orientation_sensor_output(name) {
            baseline.rotated_by(self.sensor_rotation)
        } else {
            baseline
        }
    }

    fn baseline_transform(&self, name: &str, effective: OutputTransform) -> OutputTransform {
        if orientation_sensor_output(name) {
            effective.rotated_by(self.sensor_rotation.inverse_rotation())
        } else {
            effective
        }
    }
}

fn orientation_sensor_output(name: &str) -> bool {
    name.starts_with("DSI-") || name.starts_with("eDP-") || name.starts_with("LVDS-")
}

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

fn preserves_predecessor_kms_state(runtime_limit: RuntimeLimit) -> bool {
    runtime_limit != RuntimeLimit::UntilLogout
}

fn run(options: Options) -> Result<(), Box<dyn Error>> {
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
                run_flutter_event_loop(
                    &mut renderer,
                    &mut kms.drm,
                    &mut swapchains,
                    &mut kms.scanouts,
                    &mut restore_state,
                    &mut drm_scanner,
                    &mut allocator,
                    &mut scanout_allocator,
                    &mut topology,
                    options.max_outputs,
                    output_configuration,
                    options.output_config.clone(),
                    output_control
                        .as_ref()
                        .ok_or("Flutter output control was not initialized")?
                        .publisher(),
                    wayland,
                    flutter.ok_or("Flutter runtime was not initialized")?,
                    flutter_launcher
                        .as_mut()
                        .ok_or("Flutter launcher was not initialized")?,
                    duration,
                    frame_limit,
                    frame_event_loop
                        .as_mut()
                        .ok_or("Flutter event loop has no event source")?,
                )
                .map_err(|error| format!("Flutter event loop failed: {error}").into())
            }
            #[cfg(not(feature = "flutter"))]
            return Err("Flutter feature was checked before acquiring DRM".into());
        } else if let RuntimeLimit::Frames(frame_count) = runtime_limit {
            run_frame_loop(
                &mut renderer,
                &mut scanout_allocator,
                &mut kms.drm,
                &mut drm_scanner,
                &mut swapchains,
                &mut kms.scanouts,
                &mut restore_state,
                wayland,
                #[cfg(feature = "flutter")]
                flutter,
                #[cfg(feature = "flutter")]
                flutter_launcher.as_mut(),
                frame_count,
                options.max_outputs,
                &output_configuration,
                options.rescan_at_frame,
                options.simulate_hotplug_at_frame,
                &mut topology,
                layout_transition.as_ref(),
                frame_event_loop
                    .as_mut()
                    .ok_or("frame loop has no event source")?,
            )
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

fn session_activation_environment(
    wayland_display: &OsStr,
    x11_display: &OsStr,
    output_control_socket: Option<&OsStr>,
) -> Result<BTreeMap<&'static str, String>, Box<dyn Error>> {
    let wayland_display = wayland_display
        .to_str()
        .ok_or("Wayland socket name is not valid UTF-8")?;
    let x11_display = x11_display
        .to_str()
        .ok_or("X11 display name is not valid UTF-8")?;
    let mut environment = BTreeMap::from([
        ("DESKTOP_SESSION", String::from("Denial")),
        ("DISPLAY", x11_display.to_owned()),
        ("WAYLAND_DISPLAY", wayland_display.to_owned()),
        ("XDG_CURRENT_DESKTOP", String::from("Denial")),
        ("XDG_SESSION_DESKTOP", String::from("Denial")),
        ("XDG_SESSION_TYPE", String::from("wayland")),
    ]);
    if let Some(socket) = output_control_socket {
        environment.insert(
            "DENIAL_SOCKET",
            socket
                .to_str()
                .ok_or("Denial control socket path is not valid UTF-8")?
                .to_owned(),
        );
    }
    Ok(environment)
}

fn systemd_environment_assignments(environment: &BTreeMap<&'static str, String>) -> Vec<String> {
    environment
        .iter()
        .map(|(name, value)| format!("{name}={value}"))
        .collect()
}

fn update_dbus_activation_environment(
    connection: &zbus::blocking::Connection,
    environment: &BTreeMap<&'static str, String>,
) -> Result<(), zbus::Error> {
    let proxy = zbus::blocking::Proxy::new(
        connection,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
    )?;
    proxy.call("UpdateActivationEnvironment", environment)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SessionActivation {
    Dbus,
    Systemd,
}

impl SessionActivation {
    fn starts_systemd_target(self) -> bool {
        self == Self::Systemd
    }
}

fn systemd_user_manager_runtime_available(runtime_dir: Option<&OsStr>) -> bool {
    let Some(runtime_dir) = runtime_dir else {
        return false;
    };
    let runtime_dir = Path::new(runtime_dir);
    runtime_dir.is_absolute() && runtime_dir.join("systemd").is_dir()
}

fn update_systemd_activation_environment(
    connection: &zbus::blocking::Connection,
    environment: &BTreeMap<&'static str, String>,
) -> Result<(), zbus::Error> {
    let proxy = zbus::blocking::Proxy::new(
        connection,
        SYSTEMD_DBUS_NAME,
        "/org/freedesktop/systemd1",
        "org.freedesktop.systemd1.Manager",
    )?;
    proxy.call(
        "SetEnvironment",
        &systemd_environment_assignments(environment),
    )
}

fn change_systemd_graphical_session(
    connection: &zbus::blocking::Connection,
    method: &'static str,
    target: &'static str,
) -> Result<zbus::zvariant::OwnedObjectPath, zbus::Error> {
    let proxy = zbus::blocking::Proxy::new(
        connection,
        SYSTEMD_DBUS_NAME,
        "/org/freedesktop/systemd1",
        "org.freedesktop.systemd1.Manager",
    )?;
    proxy.call(method, &(target, "replace"))
}

fn start_systemd_graphical_session(
    connection: &zbus::blocking::Connection,
) -> Result<zbus::zvariant::OwnedObjectPath, zbus::Error> {
    change_systemd_graphical_session(connection, "StartUnit", DENIAL_SESSION_TARGET)
}

fn stop_systemd_graphical_session() -> Result<(), Box<dyn Error>> {
    let connection = zbus::blocking::Connection::session()?;
    let _job = change_systemd_graphical_session(&connection, "StopUnit", GRAPHICAL_SESSION_TARGET)?;
    Ok(())
}

fn publish_session_activation_environment(
    wayland_display: &OsStr,
    x11_display: &OsStr,
    output_control_socket: Option<&OsStr>,
) -> Result<SessionActivation, Box<dyn Error>> {
    let environment =
        session_activation_environment(wayland_display, x11_display, output_control_socket)?;
    let connection = zbus::blocking::Connection::session()?;
    update_dbus_activation_environment(&connection, &environment)?;

    if !systemd_user_manager_runtime_available(std::env::var_os("XDG_RUNTIME_DIR").as_deref()) {
        info!(
            wayland_display = ?wayland_display,
            x11_display = ?x11_display,
            "published the compositor session to D-Bus activation; no systemd user manager runtime is available"
        );
        return Ok(SessionActivation::Dbus);
    }

    // NameHasOwner is deliberately not used as a capability test here. The
    // user manager can already be running while its well-known D-Bus name is
    // still activatable or being acquired during an early login. Sending the
    // manager calls directly lets D-Bus synchronize that startup instead of
    // permanently selecting the D-Bus-only path from a transient snapshot.
    update_systemd_activation_environment(&connection, &environment).map_err(|error| {
        format!("could not publish the session environment to systemd: {error}")
    })?;
    let job = start_systemd_graphical_session(&connection).map_err(|error| {
        format!("could not start {DENIAL_SESSION_TARGET} through systemd: {error}")
    })?;
    info!(
        wayland_display = ?wayland_display,
        x11_display = ?x11_display,
        target = DENIAL_SESSION_TARGET,
        job = %job,
        "published the compositor session and queued its graphical-session target"
    );
    Ok(SessionActivation::Systemd)
}

#[cfg(test)]
mod session_activation_tests {
    use super::*;

    #[test]
    fn login_session_handoff_does_not_capture_the_greeter_framebuffer() {
        assert!(!preserves_predecessor_kms_state(RuntimeLimit::UntilLogout));
        assert!(preserves_predecessor_kms_state(RuntimeLimit::TestOnly));
        assert!(preserves_predecessor_kms_state(RuntimeLimit::Frames(1)));
        assert!(preserves_predecessor_kms_state(RuntimeLimit::Duration(
            Duration::from_secs(1)
        )));
    }

    #[test]
    fn activation_environment_uses_the_discovered_session_endpoints() {
        let environment = session_activation_environment(
            OsStr::new("wayland-37"),
            OsStr::new(":42"),
            Some(OsStr::new("/run/user/1000/denial/control.sock")),
        )
        .expect("valid session environment");
        assert_eq!(
            environment.get("WAYLAND_DISPLAY").map(String::as_str),
            Some("wayland-37")
        );
        assert_eq!(environment.get("DISPLAY").map(String::as_str), Some(":42"));
        assert!(!environment.contains_key("XMODIFIERS"));
        assert_eq!(
            environment.get("XDG_SESSION_TYPE").map(String::as_str),
            Some("wayland")
        );
        assert_eq!(
            environment.get("DENIAL_SOCKET").map(String::as_str),
            Some("/run/user/1000/denial/control.sock")
        );
        assert_eq!(
            systemd_environment_assignments(&environment),
            [
                "DENIAL_SOCKET=/run/user/1000/denial/control.sock",
                "DESKTOP_SESSION=Denial",
                "DISPLAY=:42",
                "WAYLAND_DISPLAY=wayland-37",
                "XDG_CURRENT_DESKTOP=Denial",
                "XDG_SESSION_DESKTOP=Denial",
                "XDG_SESSION_TYPE=wayland",
            ]
        );
    }

    #[test]
    fn session_lifecycle_tracks_whether_the_systemd_target_started() {
        assert!(!SessionActivation::Dbus.starts_systemd_target());
        assert!(SessionActivation::Systemd.starts_systemd_target());
    }

    #[test]
    fn systemd_runtime_detection_does_not_depend_on_dbus_name_ownership() {
        let runtime =
            std::env::temp_dir().join(format!("denial-systemd-runtime-{}", std::process::id()));
        let systemd_runtime = runtime.join("systemd");
        std::fs::create_dir_all(&systemd_runtime).expect("create fake systemd runtime");

        assert!(systemd_user_manager_runtime_available(Some(
            runtime.as_os_str()
        )));
        assert!(!systemd_user_manager_runtime_available(None));
        assert!(!systemd_user_manager_runtime_available(Some(OsStr::new(
            "relative/runtime"
        ))));

        std::fs::remove_dir_all(&runtime).expect("remove fake systemd runtime");
    }
}

#[derive(Clone, Copy, Debug)]
#[cfg_attr(not(feature = "flutter"), allow(dead_code))]
struct PageFlipCompletion {
    crtc: crtc::Handle,
    observed_at: Instant,
    presented_at: Option<Duration>,
    sequence: Option<u64>,
}

#[cfg(feature = "flutter")]
#[derive(Clone, Copy, Debug)]
struct PresentedOutput {
    id: OutputId,
    observed_at: Instant,
    presented_at: Option<Duration>,
    sequence: Option<u64>,
    timeline_target: Instant,
}

fn monotonic_now() -> Option<Duration> {
    let mut timestamp = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: `timestamp` points to initialized writable storage and
    // CLOCK_MONOTONIC requires no additional lifetime or ownership contract.
    if unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut timestamp) } != 0 {
        return None;
    }
    let seconds = u64::try_from(timestamp.tv_sec).ok()?;
    let nanoseconds = u32::try_from(timestamp.tv_nsec).ok()?;
    (nanoseconds < 1_000_000_000).then(|| Duration::new(seconds, nanoseconds))
}

fn presentation_instant(
    delivered_at: Instant,
    monotonic_now: Duration,
    presented_at: Duration,
) -> Instant {
    let Some(delivery_delay) = monotonic_now.checked_sub(presented_at) else {
        return delivered_at;
    };
    delivered_at
        .checked_sub(delivery_delay)
        .unwrap_or(delivered_at)
}

#[cfg(test)]
mod presentation_clock_tests {
    use super::*;

    #[test]
    fn kernel_monotonic_timestamp_is_backdated_from_event_delivery() {
        let delivered_at = Instant::now();
        let monotonic_now = Duration::from_secs(20);
        let delay = Duration::from_millis(3);

        assert_eq!(
            presentation_instant(delivered_at, monotonic_now, monotonic_now - delay),
            delivered_at - delay
        );
        assert_eq!(
            presentation_instant(
                delivered_at,
                monotonic_now,
                monotonic_now + Duration::from_nanos(1)
            ),
            delivered_at
        );
    }
}

#[derive(Default)]
struct RuntimeState {
    pending: HashSet<crtc::Handle>,
    completed_page_flips: VecDeque<PageFlipCompletion>,
    scanout_rebased: bool,
    error: Option<String>,
    lifecycle: LifecycleState,
    native_escape_shortcut: NativeEscapeShortcut,
    topology_dirty: bool,
    output_power_requests: BTreeMap<OutputId, bool>,
    #[cfg(feature = "flutter")]
    kms_reconfigure_requested: bool,
    #[cfg(feature = "flutter")]
    resident_geometry_reconfigure_requested: bool,
    device_removed: bool,
    wayland: Option<wayland_frontend::WaylandFrontend>,
    clipboard: clipboard::ClipboardManager,
    clipboard_capture_tokens: Vec<RegistrationToken>,
    clipboard_deferred_capture: Option<wayland_frontend::DeferredClipboardCapture>,
    scene_sync: SceneSyncState,
    system_controls: Option<SystemControls>,
    vblank_events: u64,
    #[cfg(feature = "flutter")]
    flutter_events: Vec<flutter_runtime::RuntimeEvent>,
    #[cfg(feature = "flutter")]
    sampled_buffer_releases: Vec<(Option<OwnedFd>, flutter_runtime::SampledBufferHoldBatch)>,
    #[cfg(feature = "flutter")]
    native_app_plugins: Option<native_app_plugin::NativeAppPluginManager>,
    #[cfg(feature = "flutter")]
    native_plugin_actions: VecDeque<native_app_plugin::NativePluginAction>,
    #[cfg(feature = "flutter")]
    native_release_commands: VecDeque<native_app_plugin::NativeReleaseCommand>,
    #[cfg(feature = "flutter")]
    native_ready_frames: Vec<native_app_plugin::NativeFrameKey>,
    #[cfg(feature = "flutter")]
    native_release_sender: Option<
        smithay::reexports::calloop::channel::Sender<native_app_plugin::NativeReleaseCommand>,
    >,
    #[cfg(feature = "flutter")]
    native_plugin_formats: Vec<native_app_plugin::NativeAppFormatV1>,
    #[cfg(feature = "flutter")]
    native_plugin_default_size: (u32, u32),
    #[cfg(feature = "flutter")]
    ready_fence_signals: Vec<output_scheduler::ReadyFenceSignal>,
    #[cfg(feature = "flutter")]
    volition_events: Vec<denial_core::volition::Event>,
    #[cfg(feature = "flutter")]
    flutter_channel_closed: bool,
    #[cfg(feature = "flutter")]
    flutter_reload_requested: bool,
    #[cfg(feature = "flutter")]
    flutter_active: bool,
    #[cfg(feature = "flutter")]
    authentication: Option<Arc<authentication::AuthenticationController>>,
    #[cfg(feature = "flutter")]
    session_lock_applied: bool,
    #[cfg(feature = "flutter")]
    flutter_input: flutter_runtime::InputQueue,
    #[cfg(feature = "flutter")]
    touchpad_gestures: touchpad_gestures::TouchpadGestureRecognizer,
    #[cfg(feature = "flutter")]
    touchpad_devices: BTreeMap<String, smithay::reexports::input::Device>,
    #[cfg(feature = "flutter")]
    input_device_capabilities_changed: bool,
    #[cfg(feature = "flutter")]
    pending_window_events: PendingWindowEventQueue,
    #[cfg(feature = "flutter")]
    pending_unpublished_window_events: PendingWindowEventQueue,
    #[cfg(feature = "flutter")]
    pending_shell_actions: VecDeque<(wire::ShellAction, Option<i64>)>,
    #[cfg(feature = "flutter")]
    pending_shortcut_launches: VecDeque<native_shortcut::ShortcutTarget>,
    #[cfg(feature = "flutter")]
    pending_screenshot_selection: Option<OutputId>,
    #[cfg(feature = "flutter")]
    published_window_ids: HashSet<u64>,
    #[cfg(feature = "flutter")]
    restored_window_ids: BTreeSet<u64>,
    #[cfg(feature = "flutter")]
    notification_server: Option<NotificationServer>,
    #[cfg(feature = "flutter")]
    pending_notification_events: VecDeque<notification_server::NotificationEvent>,
    #[cfg(feature = "flutter")]
    pending_output_applies: VecDeque<PendingOutputApply>,
    #[cfg(feature = "flutter")]
    pending_output_confirmations: VecDeque<PendingOutputConfirmation>,
    #[cfg(feature = "flutter")]
    pending_orientation: Option<orientation_sensor::Orientation>,
    #[cfg(feature = "flutter")]
    output_control_dirty: bool,
    #[cfg(feature = "flutter")]
    dpms_wake_topology_grace_until: Option<Instant>,
    #[cfg(feature = "flutter")]
    topology_recheck_at: Option<Instant>,
    #[cfg(feature = "flutter")]
    pending_ui_development: VecDeque<PendingUiDevelopment>,
    #[cfg(feature = "flutter")]
    idle_dpms: idle_policy::IdleDpmsPolicy,
}

#[cfg(feature = "flutter")]
impl RuntimeState {
    fn secure_session_locked(&self) -> bool {
        self.session_lock_applied
            || self
                .authentication
                .as_ref()
                .is_some_and(|authentication| authentication.locked())
    }

    fn queue_shell_action(&mut self, action: wire::ShellAction, monitor_id: Option<i64>) {
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

    fn request_screenshot_selection(&mut self, monitor_id: Option<i64>) {
        let output = monitor_id
            .and_then(|monitor_id| u64::try_from(monitor_id).ok())
            .map(OutputId);
        if let Some(output) = output {
            self.pending_screenshot_selection = Some(output);
        } else {
            warn!("screenshot shortcut has no output under the pointer");
        }
    }

    fn compositor_pointer_in_flutter_pixels(&self) -> Option<(f64, f64)> {
        self.wayland
            .as_ref()
            .map(wayland_frontend::WaylandFrontend::flutter_pointer_position_physical)
    }

    /// Makes the Flutter engine's mouse state a projection of the compositor
    /// pointer instead of an independently integrated libinput position.
    fn synchronize_flutter_pointer_position(&mut self) {
        let Some((x, y)) = self.compositor_pointer_in_flutter_pixels() else {
            return;
        };
        self.flutter_input.synchronize_pointer_position(x, y);
    }

    /// Starts a new Flutter generation without making the existing Wayland
    /// scene look newly mapped. The replacement runtime receives this exact
    /// set with its first window snapshot and can suppress entrance effects
    /// without changing lasting animation policy for those windows.
    fn begin_replacement_flutter_generation(&mut self, size: PixelSize) {
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
        }
    }

    fn note_user_activity(&mut self) {
        let requests = self.idle_dpms.note_activity(Instant::now());
        self.queue_idle_power_requests(requests);
    }

    fn note_dpms_wake(&mut self, now: Instant) {
        self.dpms_wake_topology_grace_until = Some(now + DPMS_WAKE_TOPOLOGY_GRACE);
    }

    fn service_topology_recheck_deadline(&mut self, now: Instant) {
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

    fn queue_idle_power_requests(
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
    fn client_activation_permitted(&self) -> bool {
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

trait ScanoutFramebufferSource {
    fn plane_state(&self, scanout: &Scanout) -> Result<PlaneState<'static>, Box<dyn Error>>;
}

impl ScanoutFramebufferSource for framebuffer::Handle {
    fn plane_state(&self, scanout: &Scanout) -> Result<PlaneState<'static>, Box<dyn Error>> {
        Ok(plane_state(scanout, *self))
    }
}

impl ScanoutFramebufferSource for RenderSwapchains {
    fn plane_state(&self, scanout: &Scanout) -> Result<PlaneState<'static>, Box<dyn Error>> {
        current_scanout_state(scanout, self).map(|(_, state)| state)
    }
}

fn service_session_lifecycle(
    drm: &mut DrmDevice,
    scanouts: &[Scanout],
    framebuffers: &dyn ScanoutFramebufferSource,
    event_loop: &mut EventLoop<'_, RuntimeState>,
    events: &mut RuntimeState,
    inactive_deadline: Option<Instant>,
) -> Result<(), Box<dyn Error>> {
    loop {
        if events.lifecycle.take_pause_pending() {
            if drm.is_active() {
                drm.pause();
            }
            // A page-flip event queued before libseat revoked the fd is not
            // guaranteed to arrive. The resume commit below establishes a new
            // known scanout state synchronously.
            events.pending.clear();
            events.completed_page_flips.clear();
            if let Some(error) = events.error.take() {
                warn!(error, "discarding DRM event error from the paused session");
            }
            info!("libseat paused the KMS session");
        }

        if events.lifecycle.shutdown_reason().is_some()
            || events.lifecycle.seat_active()
            || events.device_removed
        {
            break;
        }

        // libseat activation, device removal, or a termination signal wakes
        // calloop. Finite callers also wake at their own wall-clock deadline.
        match inactive_dispatch(Instant::now(), inactive_deadline) {
            InactiveDispatch::DeadlineReached => break,
            InactiveDispatch::Wait(timeout) => event_loop.dispatch(timeout, events)?,
        }
    }

    if events.device_removed {
        return Err("the active DRM device was removed while the session was paused".into());
    }
    if events.lifecycle.shutdown_reason().is_some() || !events.lifecycle.seat_active() {
        return Ok(());
    }
    if drm.is_active() {
        return Ok(());
    }

    drm.activate(false)?;
    rebase_kms_scanouts(
        drm,
        scanouts,
        framebuffers,
        events,
        "libseat reactivated the KMS session",
    )
}

/// Establishes a synchronous scanout baseline after the DRM event stream can
/// no longer be trusted.  A DPMS wake can leave an atomic commit accepted by
/// the kernel but without its corresponding page-flip event while a display
/// link is still training.  The Flutter scheduler owns page-flip generations,
/// so it must be rebuilt after this operation.
fn rebase_kms_scanouts(
    drm: &mut DrmDevice,
    scanouts: &[Scanout],
    framebuffers: &dyn ScanoutFramebufferSource,
    events: &mut RuntimeState,
    reason: &'static str,
) -> Result<(), Box<dyn Error>> {
    if !drm.is_active() {
        return Err("cannot rebase scanouts while the DRM device is inactive".into());
    }
    for scanout in scanouts.iter().filter(|scanout| scanout.powered) {
        scanout
            .surface
            .test_state([framebuffers.plane_state(scanout)?], true)?;
    }
    for scanout in scanouts.iter().filter(|scanout| scanout.powered) {
        // Atomic modeset commits are synchronous here. Do not request a
        // vblank event: it would be indistinguishable from the next real
        // page-flip event after `pending` is repopulated and could make that
        // later frame appear complete before KMS actually scans it out.
        scanout
            .surface
            .commit([framebuffers.plane_state(scanout)?], false)?;
    }
    events.pending.clear();
    events.completed_page_flips.clear();
    // Every CRTC now scans the framebuffer supplied by the caller. The
    // independently clocked Flutter scheduler must be recreated before it
    // interprets any later page-flip event using its pre-pause ownership.
    events.scanout_rebased = true;
    events.topology_dirty = true;
    info!(
        outputs = scanouts.iter().filter(|scanout| scanout.powered).count(),
        %reason,
        "rebased KMS scanouts"
    );
    Ok(())
}

#[cfg(feature = "flutter")]
fn recover_stalled_kms_presentation(
    drm: &mut DrmDevice,
    event_loop: &mut EventLoop<'_, RuntimeState>,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    loop {
        if events.lifecycle.shutdown_reason().is_some() {
            return Ok(());
        }
        if events.device_removed {
            return Err("the active DRM device was removed during presentation recovery".into());
        }

        if events.lifecycle.take_pause_pending() {
            if drm.is_active() {
                drm.pause();
            }
            events.pending.clear();
            events.completed_page_flips.clear();
        }

        let recovery = if !events.lifecycle.seat_active() {
            Err("the libseat session is inactive".into())
        } else {
            (|| -> Result<(), Box<dyn Error>> {
                if drm.is_active() {
                    drm.pause();
                }
                // Reset every connector, CRTC, and plane in one synchronous
                // atomic transaction. Re-committing the old per-output state
                // here can wait forever when DPMS wake also removed a
                // connector, which is precisely the failure this path must
                // recover from. The normal topology transaction will rescan
                // and enable only hardware which is actually connected.
                drm.activate(true)?;
                events.pending.clear();
                events.completed_page_flips.clear();
                events.scanout_rebased = true;
                events.topology_dirty = true;
                info!("reset KMS state after a stalled DPMS-wake presentation");
                Ok(())
            })()
        };
        match recovery {
            Ok(()) => return Ok(()),
            Err(error) => {
                // A connector can remain transient for several seconds after
                // its USB hub and display link start waking.  Recovery failure
                // is therefore backpressure, not a session-ending error. Keep
                // resetting the device atomically until the hardware accepts
                // a synchronous all-disabled baseline.
                warn!(
                    %error,
                    retry_ms = KMS_PRESENTATION_RECOVERY_RETRY.as_millis(),
                    "KMS presentation recovery is waiting for the display hardware"
                );
                if let Some(event_error) = events.error.take() {
                    warn!(
                        error = event_error,
                        "discarding DRM event error during presentation recovery"
                    );
                }
                events.pending.clear();
                events.completed_page_flips.clear();
                event_loop.dispatch(KMS_PRESENTATION_RECOVERY_RETRY, events)?;
            }
        }
    }
}

fn log_shutdown(reason: ShutdownReason) {
    info!(
        reason = reason.description(),
        "graceful compositor shutdown requested"
    );
}

fn collect_output_power_requests(events: &mut RuntimeState) {
    let requests = events
        .wayland
        .as_mut()
        .map(wayland_frontend::WaylandFrontend::take_output_power_requests)
        .unwrap_or_default();
    for request in requests {
        #[cfg(feature = "flutter")]
        events
            .idle_dpms
            .note_external_power_request(request.output, request.powered);
        events
            .output_power_requests
            .insert(request.output, request.powered);
    }
}

#[cfg(feature = "flutter")]
fn transient_dpms_output_removal_count(
    grace_until: Option<Instant>,
    now: Instant,
    current: impl IntoIterator<Item = OutputId>,
    observed: impl IntoIterator<Item = OutputId>,
) -> usize {
    if grace_until.is_none_or(|deadline| now >= deadline) {
        return 0;
    }
    let observed = observed.into_iter().collect::<HashSet<_>>();
    current
        .into_iter()
        .filter(|output| !observed.contains(output))
        .count()
}

#[cfg(feature = "flutter")]
fn synchronize_idle_dpms(scanouts: &[Scanout], events: &mut RuntimeState, now: Instant) {
    let inhibited = events
        .wayland
        .as_mut()
        .is_some_and(wayland_frontend::WaylandFrontend::idle_inhibited);
    let requests = events.idle_dpms.evaluate(
        now,
        inhibited,
        scanouts
            .iter()
            .map(|scanout| (scanout.output.id, scanout.powered)),
    );
    events.queue_idle_power_requests(requests);
}

#[cfg(feature = "flutter")]
fn synchronize_idle_dpms_configuration(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) {
    let Some(timeout) = runtime.take_idle_dpms_timeout() else {
        return;
    };
    let requests = events.idle_dpms.configure(timeout, Instant::now());
    events.queue_idle_power_requests(requests);
    if let Some(timeout) = timeout {
        info!(
            timeout_seconds = timeout.as_secs(),
            "configured automatic display power-off"
        );
    } else {
        info!("disabled automatic display power-off");
    }
}

#[cfg(feature = "flutter")]
fn synchronize_requested_dpms_off(
    runtime: &mut flutter_runtime::FlutterRuntime,
    scanouts: &[Scanout],
    events: &mut RuntimeState,
) {
    if !runtime.take_dpms_off_requested() {
        return;
    }
    let requests = events.idle_dpms.blank_now(
        scanouts
            .iter()
            .map(|scanout| (scanout.output.id, scanout.powered)),
    );
    events.queue_idle_power_requests(requests);
    info!("requested immediate compositor-owned display power-off");
}

#[cfg(feature = "flutter")]
fn apply_output_power_requests(
    runtime: &mut flutter_runtime::FlutterRuntime,
    scheduler: &mut output_scheduler::OutputScheduler,
    swapchain: &mut RenderSwapchains,
    scanouts: &mut [Scanout],
    events: &mut RuntimeState,
) -> Result<bool, Box<dyn Error>> {
    let requests = std::mem::take(&mut events.output_power_requests);
    let mut deferred = BTreeMap::new();
    let mut power_off = Vec::new();
    let mut power_on = Vec::new();
    let mut power_changed = false;

    for (output, powered) in requests {
        let Some(scanout_index) = scanouts
            .iter()
            .position(|scanout| scanout.output.id == output)
        else {
            events.idle_dpms.note_power_failure(output, Instant::now());
            if let Some(frontend) = events.wayland.as_mut() {
                frontend.fail_output_power(output);
            }
            continue;
        };
        let current = scanouts[scanout_index].powered;
        if current == powered {
            if powered {
                scheduler.cancel_power_off(output, scanouts);
            }
            if let Some(frontend) = events.wayland.as_mut() {
                frontend.output_power_applied(output, powered);
            }
            continue;
        }

        if powered {
            power_on.push((output, scanout_index));
        } else {
            power_off.push((output, scanout_index));
        }
    }

    // Stop every affected pipeline before clearing any CRTC. This keeps one
    // slow output from turning a multi-output blank into a staggered series of
    // independently visible transitions.
    let mut waiting_for_power_off = false;
    for &(output, _) in &power_off {
        waiting_for_power_off |= scheduler.begin_power_off(runtime, output, scanouts)?;
    }
    if waiting_for_power_off {
        deferred.extend(power_off.iter().map(|(output, _)| (*output, false)));
    } else if !power_off.is_empty() {
        let mut targets = Vec::with_capacity(power_off.len());
        for &(output, scanout_index) in &power_off {
            let framebuffer_index = scheduler
                .scanning_framebuffer_index(output, scanouts)
                .ok_or("DPMS power-off output has no scheduler framebuffer")?;
            targets.push((output, scanout_index, framebuffer_index));
        }

        let mut cleared = Vec::with_capacity(targets.len());
        let mut failure = None;
        for &(output, scanout_index, framebuffer_index) in &targets {
            match scanouts[scanout_index].surface.clear() {
                Ok(()) => cleared.push((output, scanout_index, framebuffer_index)),
                Err(error) => {
                    failure = Some((scanout_index, error.to_string()));
                    break;
                }
            }
        }

        if let Some((failed_index, error)) = failure {
            let mut rollback_failures = Vec::new();
            for &(output, scanout_index, framebuffer_index) in &cleared {
                let pool = swapchain
                    .outputs()
                    .and_then(|outputs| outputs.for_output(output))
                    .ok_or("DPMS rollback output has no physical buffer pool")?;
                let framebuffer = pool
                    .buffers
                    .get(framebuffer_index)
                    .ok_or("DPMS rollback framebuffer exceeds its output pool")?
                    .framebuffer();
                let state = output_plane_state(&scanouts[scanout_index], framebuffer, pool.size);
                let restore = scanouts[scanout_index]
                    .surface
                    .test_state([state.clone()], true)
                    .and_then(|()| scanouts[scanout_index].surface.commit([state], false));
                if let Err(rollback_error) = restore {
                    rollback_failures.push(format!(
                        "{}: {rollback_error}",
                        scanouts[scanout_index].output.name
                    ));
                }
            }
            for &(output, _) in &power_off {
                scheduler.cancel_power_off(output, scanouts);
                events.idle_dpms.note_power_failure(output, Instant::now());
                if let Some(frontend) = events.wayland.as_mut() {
                    frontend.fail_output_power(output);
                }
            }
            warn!(
                output = scanouts[failed_index].output.name,
                %error,
                restored_outputs = cleared.len(),
                requested_outputs = power_off.len(),
                "aborted compositor-owned display power-off batch"
            );
            if !rollback_failures.is_empty() {
                return Err(format!(
                    "DPMS power-off rollback failed after {} rejected the transition ({error}): {}",
                    scanouts[failed_index].output.name,
                    rollback_failures.join("; ")
                )
                .into());
            }
        } else {
            for &(output, scanout_index, _) in &targets {
                scheduler.power_off(runtime, output, scanouts)?;
                scanouts[scanout_index].powered = false;
                power_changed = true;
                events.output_control_dirty = true;
                events.pending.remove(&scanouts[scanout_index].output.crtc);
                info!(
                    output = scanouts[scanout_index].output.name,
                    "powered off KMS output"
                );
                if let Some(frontend) = events.wayland.as_mut() {
                    frontend.output_power_applied(output, false);
                }
            }
        }
    }

    if !power_on.is_empty() {
        let targets = power_on
            .iter()
            .map(|&(output, scanout_index)| {
                let framebuffer_index = scheduler
                    .stable_framebuffer_index(output)
                    .ok_or("DPMS wake output has no parked framebuffer")?;
                let pool = swapchain
                    .outputs()
                    .and_then(|outputs| outputs.for_output(output))
                    .ok_or("DPMS wake output has no physical buffer pool")?;
                let framebuffer = pool
                    .buffers
                    .get(framebuffer_index)
                    .ok_or("DPMS wake framebuffer exceeds its output pool")?
                    .framebuffer();
                Ok::<_, Box<dyn Error>>((
                    output,
                    scanout_index,
                    framebuffer_index,
                    framebuffer,
                    pool.size,
                ))
            })
            .collect::<Result<Vec<_>, _>>()?;
        let mut failure = None;
        for &(_, scanout_index, _, framebuffer, size) in &targets {
            if let Err(error) = scanouts[scanout_index].surface.test_state(
                [output_plane_state(
                    &scanouts[scanout_index],
                    framebuffer,
                    size,
                )],
                true,
            ) {
                failure = Some((scanout_index, error.to_string(), false));
                break;
            }
        }

        let mut committed = Vec::with_capacity(power_on.len());
        if failure.is_none() {
            for &(output, scanout_index, _, framebuffer, size) in &targets {
                if let Err(error) = scanouts[scanout_index].surface.commit(
                    [output_plane_state(
                        &scanouts[scanout_index],
                        framebuffer,
                        size,
                    )],
                    false,
                ) {
                    failure = Some((scanout_index, error.to_string(), true));
                    break;
                }
                committed.push((output, scanout_index));
            }
        }

        if let Some((failed_index, error, commit_failed)) = failure {
            let mut rollback_failures = Vec::new();
            for &(_, scanout_index) in &committed {
                if let Err(rollback_error) = scanouts[scanout_index].surface.clear() {
                    rollback_failures.push(format!(
                        "{}: {rollback_error}",
                        scanouts[scanout_index].output.name
                    ));
                }
            }
            for &(output, _) in &power_on {
                events.idle_dpms.note_power_failure(output, Instant::now());
                if let Some(frontend) = events.wayland.as_mut() {
                    frontend.fail_output_power(output);
                }
            }
            warn!(
                output = scanouts[failed_index].output.name,
                %error,
                phase = if commit_failed { "commit" } else { "test" },
                restored_outputs = committed.len(),
                requested_outputs = power_on.len(),
                "aborted compositor-owned display wake batch"
            );
            if !rollback_failures.is_empty() {
                return Err(format!(
                    "DPMS wake rollback failed after {} rejected the transition ({error}): {}",
                    scanouts[failed_index].output.name,
                    rollback_failures.join("; ")
                )
                .into());
            }
        } else {
            for &(output, scanout_index, framebuffer_index, _, _) in &targets {
                scanouts[scanout_index].powered = true;
                power_changed = true;
                scheduler.power_on(
                    runtime,
                    scanout_index,
                    framebuffer_index,
                    scanouts,
                    swapchain
                        .outputs()
                        .ok_or("DPMS wake has no physical output pools")?,
                )?;
                events.output_control_dirty = true;
                info!(
                    output = scanouts[scanout_index].output.name,
                    "powered on KMS output"
                );
                if let Some(frontend) = events.wayland.as_mut() {
                    frontend.output_power_applied(output, true);
                }
            }
            events.note_dpms_wake(Instant::now());
        }
    }

    runtime.set_outputs_visible(scanouts.iter().any(|scanout| scanout.powered))?;
    events.output_power_requests = deferred;
    Ok(power_changed)
}

fn hold_static_scanout(
    drm: &mut DrmDevice,
    scanouts: &[Scanout],
    framebuffer: framebuffer::Handle,
    duration: Duration,
    event_loop: &mut EventLoop<'_, RuntimeState>,
) -> Result<framebuffer::Handle, Box<dyn Error>> {
    let deadline = Instant::now()
        .checked_add(duration)
        .ok_or("KMS hold duration exceeds the monotonic clock range")?;
    let mut events = RuntimeState::default();

    loop {
        service_session_lifecycle(
            drm,
            scanouts,
            &framebuffer,
            event_loop,
            &mut events,
            Some(deadline),
        )?;
        if let Some(reason) = events.lifecycle.shutdown_reason() {
            log_shutdown(reason);
            break;
        }
        if events.device_removed {
            return Err("the active DRM device was removed during the KMS hold".into());
        }

        let now = Instant::now();
        if now >= deadline {
            break;
        }
        event_loop.dispatch(deadline.saturating_duration_since(now), &mut events)?;
    }

    Ok(framebuffer)
}

#[allow(clippy::too_many_arguments)]
fn run_frame_loop(
    renderer: &mut GlesRenderer,
    scanout_allocator: &mut ScanoutAllocator,
    drm: &mut DrmDevice,
    drm_scanner: &mut DrmScanner<SimpleCrtcMapper>,
    swapchain: &mut RenderSwapchains,
    scanouts: &mut Vec<Scanout>,
    restore_state: &mut RestoreState,
    wayland: Option<wayland_frontend::WaylandFrontend>,
    #[cfg(feature = "flutter")] mut flutter: Option<flutter_runtime::FlutterRuntime>,
    #[cfg(feature = "flutter")] mut flutter_launcher: Option<&mut FlutterLauncher>,
    frame_count: u64,
    max_outputs: usize,
    initial_configuration: &RuntimeOutputConfiguration,
    rescan_at_frame: Option<u64>,
    simulate_hotplug_at_frame: Option<u64>,
    topology: &mut TopologyManager,
    layout_transition: Option<&LayoutTransition>,
    event_loop: &mut EventLoop<'_, RuntimeState>,
) -> Result<framebuffer::Handle, Box<dyn Error>> {
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
            apply_hotplug_topology(
                renderer,
                scanout_allocator,
                drm,
                swapchain,
                scanouts,
                restore_state,
                topology,
                outputs,
                &active_configuration,
                frame_number,
                event_loop,
                &mut events,
                #[cfg(feature = "flutter")]
                &mut flutter,
                #[cfg(feature = "flutter")]
                flutter_launcher.as_deref_mut(),
            )?;
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
                apply_hotplug_topology(
                    renderer,
                    scanout_allocator,
                    drm,
                    swapchain,
                    scanouts,
                    restore_state,
                    topology,
                    outputs,
                    &active_configuration,
                    frame_number,
                    event_loop,
                    &mut events,
                    #[cfg(feature = "flutter")]
                    &mut flutter,
                    #[cfg(feature = "flutter")]
                    flutter_launcher.as_deref_mut(),
                )?;
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

#[cfg(feature = "flutter")]
fn service_native_app_plugins(
    event_loop: &mut EventLoop<'_, RuntimeState>,
    events: &mut RuntimeState,
    allocator: &mut GbmAllocator<DrmDeviceFd>,
) -> Result<(), Box<dyn Error>> {
    let Some(mut manager) = events.native_app_plugins.take() else {
        events.native_plugin_actions.clear();
        events.native_release_commands.clear();
        events.native_ready_frames.clear();
        return Ok(());
    };

    for release in events.native_release_commands.drain(..) {
        if let Err(error) = manager.handle_release_command(release) {
            warn!(%error, "native application plugin release command failed");
        }
    }
    for key in events.native_ready_frames.drain(..) {
        manager.activate_frame(key);
    }

    let default_size = events.native_plugin_default_size;
    let formats = &events.native_plugin_formats;
    manager.refresh_dirty_target_pools(formats, allocator)?;
    let release_sender = events
        .native_release_sender
        .as_ref()
        .ok_or("native application release channel disappeared")?;
    for action in events.native_plugin_actions.drain(..) {
        let watch =
            match manager.handle_action(action, default_size, formats, allocator, release_sender) {
                Ok(watch) => watch,
                Err(error) => {
                    warn!(%error, "rejected native application plugin event");
                    continue;
                }
            };
        let Some(watch) = watch else {
            continue;
        };
        let key = watch.key;
        event_loop.handle().insert_source(
            Generic::new(watch.fence, Interest::READ, PollMode::Level),
            move |_, _, state: &mut RuntimeState| {
                state.native_ready_frames.push(key);
                Ok(PostAction::Remove)
            },
        )?;
    }

    events.native_app_plugins = Some(manager);
    Ok(())
}

#[cfg(feature = "flutter")]
fn install_sampled_buffer_releases(
    event_loop: &mut EventLoop<'_, RuntimeState>,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    for (fence, batch) in events.sampled_buffer_releases.drain(..) {
        let Some(fence) = fence else {
            // The raster thread already used glFinish. Drop the guards here so
            // producer release remains on the compositor thread.
            batch.complete_native_releases_without_fence()?;
            drop(batch);
            continue;
        };
        batch.materialize_native_releases(fence.as_fd())?;
        let mut batch = Some(batch);
        event_loop.handle().insert_source(
            Generic::new(fence, Interest::READ, PollMode::Level),
            move |_, _, _| {
                // A sync_file becomes readable only after every preceding
                // Flutter sample command has completed on the GPU.
                if let Some(batch) = batch.as_ref()
                    && let Err(error) = batch.complete_native_releases()
                {
                    error!(%error, "could not complete a native plugin buffer release");
                }
                drop(batch.take());
                Ok(PostAction::Remove)
            },
        )?;
    }
    Ok(())
}

#[cfg(feature = "flutter")]
fn install_ready_fence_watch(
    event_loop: &mut EventLoop<'_, RuntimeState>,
    watch: output_scheduler::ReadyFenceWatch,
) -> Result<(), Box<dyn Error>> {
    let (fence, signal) = watch.into_parts();
    event_loop.handle().insert_source(
        Generic::new(fence, Interest::READ, PollMode::Level),
        move |_, _, state: &mut RuntimeState| {
            // Readability makes an unconsumed output target reusable and authorizes
            // fence-free Volition lookahead after an earlier KMS submission.
            state.ready_fence_signals.push(signal);
            Ok(PostAction::Remove)
        },
    )?;
    Ok(())
}

#[cfg(feature = "flutter")]
fn submit_ready_frames(
    scheduler: &mut output_scheduler::OutputScheduler,
    swapchain: &RenderSwapchains,
) -> Result<(), Box<dyn Error>> {
    scheduler.submit_ready(
        swapchain
            .outputs()
            .ok_or("ready submission has no physical output pools")?,
    )
}

#[cfg(feature = "flutter")]
#[derive(Debug)]
struct ActiveOutputConfirmation {
    state: output_control::OutputControlConfirmation,
    deadline: Instant,
    rollback_configuration: RuntimeOutputConfiguration,
    rollback_power: BTreeMap<OutputId, bool>,
    prepared_persistence: Option<options::PreparedOutputConfig>,
}

#[cfg(feature = "flutter")]
fn confirmation_deadline_unix_milliseconds(timeout: Duration) -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .saturating_add(timeout)
        .as_millis()
        .try_into()
        .unwrap_or(u64::MAX)
}

#[cfg(feature = "flutter")]
fn begin_output_confirmation(
    serial: u64,
    timeout: Duration,
    rollback_configuration: RuntimeOutputConfiguration,
    rollback_power: BTreeMap<OutputId, bool>,
    prepared_persistence: Option<options::PreparedOutputConfig>,
) -> ActiveOutputConfirmation {
    ActiveOutputConfirmation {
        state: output_control::OutputControlConfirmation {
            token: output_control::next_serial(serial),
            deadline_unix_milliseconds: confirmation_deadline_unix_milliseconds(timeout),
        },
        deadline: Instant::now() + timeout,
        rollback_configuration,
        rollback_power,
        prepared_persistence,
    }
}

#[cfg(feature = "flutter")]
#[allow(clippy::too_many_arguments)]
fn run_flutter_event_loop(
    renderer: &mut GlesRenderer,
    drm: &mut DrmDevice,
    swapchain: &mut RenderSwapchains,
    scanouts: &mut Vec<Scanout>,
    restore_state: &mut RestoreState,
    drm_scanner: &mut DrmScanner<SimpleCrtcMapper>,
    allocator: &mut GbmAllocator<DrmDeviceFd>,
    scanout_allocator: &mut ScanoutAllocator,
    topology: &mut TopologyManager,
    max_outputs: usize,
    mut output_configuration: RuntimeOutputConfiguration,
    output_config: Option<PathBuf>,
    output_control: output_control::OutputControlPublisher,
    wayland: Option<wayland_frontend::WaylandFrontend>,
    flutter: flutter_runtime::FlutterRuntime,
    flutter_launcher: &mut FlutterLauncher,
    duration: Option<Duration>,
    frame_limit: Option<u64>,
    event_loop: &mut EventLoop<'_, RuntimeState>,
) -> Result<framebuffer::Handle, Box<dyn Error>> {
    use smithay::reexports::calloop::channel::{Event as ChannelEvent, channel, sync_channel};

    let persistence_available = output_config.is_some();
    let native_app_snapshot = topology.snapshot();
    let native_app_atlas = AtlasPlan::for_snapshot(&native_app_snapshot)
        .ok_or("native application plugin initialization has no output atlas")?;
    let native_app_refresh_millihz = ticker_refresh_millihz(&native_app_snapshot)?;
    let native_app_plugins = native_app_plugin::NativeAppPluginManager::load_configured(
        drm.as_fd(),
        native_app_atlas.engine_scale_120,
        SCALE_BASE,
        native_app_refresh_millihz,
    )?;
    let native_plugin_poll_descriptors = native_app_plugins
        .as_ref()
        .map(native_app_plugin::NativeAppPluginManager::poll_descriptors)
        .transpose()?
        .unwrap_or_default();
    let native_plugin_formats = renderer
        .dmabuf_formats()
        .iter()
        .filter(|format| format.modifier != Modifier::Invalid)
        .take(native_app_plugin::MAX_FORMATS)
        .map(|format| native_app_plugin::NativeAppFormatV1 {
            format: format.code as u32,
            modifier: u64::from(format.modifier),
        })
        .collect::<Vec<_>>();
    let (native_release_sender, native_release_source) = channel();
    let started = Instant::now();
    let deadline = duration
        .map(|duration| {
            started
                .checked_add(duration)
                .ok_or("Flutter session duration exceeds the monotonic clock range")
        })
        .transpose()?;
    let system_controls = wayland
        .as_ref()
        .map(|_| SystemControls::new())
        .transpose()?;
    let (notification_sender, notification_source) =
        sync_channel(NOTIFICATION_EVENT_QUEUE_CAPACITY);
    let notification_server = match NotificationServer::start(move |mut event, stopping| {
        loop {
            match notification_sender.try_send(event) {
                Ok(()) => break,
                Err(std::sync::mpsc::TrySendError::Full(returned))
                    if !stopping.load(Ordering::Acquire) =>
                {
                    event = returned;
                    std::thread::sleep(Duration::from_millis(1));
                }
                Err(_) => break,
            }
        }
    }) {
        Ok(server) => {
            event_loop.handle().insert_source(
                notification_source,
                |event, _, state: &mut RuntimeState| {
                    if let ChannelEvent::Msg(event) = event {
                        state.pending_notification_events.push_back(event);
                    }
                },
            )?;
            Some(server)
        }
        Err(notification_error) => {
            error!(%notification_error, "Denial could not start its notification service");
            None
        }
    };
    let authentication = Some(flutter.authentication());
    let clipboard = flutter.clipboard();
    let native_escape_shortcut = wayland
        .as_ref()
        .map(|frontend| frontend.shortcuts.engine())
        .unwrap_or_default();
    let mut events = RuntimeState {
        wayland,
        native_escape_shortcut,
        clipboard,
        system_controls,
        notification_server,
        authentication,
        flutter_active: true,
        flutter_input: flutter_runtime::InputQueue::new(swapchain.desktop_size()),
        native_app_plugins,
        native_release_sender: Some(native_release_sender),
        native_plugin_formats,
        native_plugin_default_size: (
            swapchain.desktop_size().width,
            swapchain.desktop_size().height,
        ),
        ..RuntimeState::default()
    };
    let _orientation_sensor = match orientation_sensor::OrientationSensor::start() {
        Ok((sensor, source)) => {
            event_loop
                .handle()
                .insert_source(source, |event, _, state: &mut RuntimeState| {
                    if let ChannelEvent::Msg(orientation) = event {
                        state.pending_orientation = Some(orientation);
                    }
                })?;
            Some(sensor)
        }
        Err(error) => {
            warn!(%error, "could not start the orientation sensor worker");
            None
        }
    };
    event_loop.handle().insert_source(
        native_release_source,
        |event, _, state: &mut RuntimeState| {
            if let ChannelEvent::Msg(command) = event {
                state.native_release_commands.push_back(command);
            }
        },
    )?;
    for (plugin_index, descriptor) in native_plugin_poll_descriptors {
        event_loop.handle().insert_source(
            Generic::new(descriptor, Interest::READ, PollMode::Level),
            move |_, _, state: &mut RuntimeState| {
                let mut actions = std::mem::take(&mut state.native_plugin_actions);
                let result = match state.native_app_plugins.as_mut() {
                    Some(manager) => manager
                        .dispatch(plugin_index, &mut actions)
                        .map_err(|error| error.to_string()),
                    None => Err("native application plugin manager disappeared".to_owned()),
                };
                state.native_plugin_actions = actions;
                if let Err(error) = result {
                    warn!(plugin_index, %error, "disabled failed native application plugin event source");
                    return Ok(PostAction::Remove);
                }
                Ok(PostAction::Continue)
            },
        )?;
    }
    let (volition_event_sender, volition_event_source) = sync_channel(8);
    event_loop.handle().insert_source(
        volition_event_source,
        |event, _, state: &mut RuntimeState| {
            if let ChannelEvent::Msg(event) = event {
                state.volition_events.push(event);
            }
        },
    )?;
    events.synchronize_flutter_pointer_position();
    let mut raster_frames = 0u64;
    let mut delivered_vsyncs = 0u64;
    let mut retired_output_flips = 0u64;
    let mut flutter = Some(flutter);
    let mut scheduler = output_scheduler::OutputScheduler::new(
        drm,
        volition_event_sender.clone(),
        scanouts,
        swapchain
            .outputs()
            .ok_or("output scheduler has no physical output pools")?,
        flutter
            .as_mut()
            .ok_or("Flutter runtime disappeared before output scheduling")?,
        &mut events,
    )?;
    flutter
        .as_mut()
        .ok_or("Flutter runtime disappeared during initial visibility publication")?
        .set_outputs_visible(scanouts.iter().any(|scanout| scanout.powered))?;
    let mut frame_scheduler = frame_scheduler::FrameScheduler::new(scanouts, Instant::now());
    let mut screenshot_manager = match screenshot::ScreenshotManager::new(events.clipboard.clone())
    {
        Ok(manager) => Some(manager),
        Err(error) => {
            warn!(%error, "screenshot writer is unavailable");
            None
        }
    };
    let mut ready_output_apply: Option<(PendingOutputApply, Vec<ConnectedConnector>)> = None;
    let mut pending_output_success: Option<PendingOutputApply> = None;
    let mut pending_output_confirmation_success: VecDeque<PendingOutputConfirmation> =
        VecDeque::new();
    let mut active_output_confirmation: Option<ActiveOutputConfirmation> = None;
    let mut pending_sensor_rotation = output_configuration.sensor_rotation;

    // Any native helper inadvertently created by an elevated Flutter thread
    // is normalized before the compositor itself becomes realtime.
    cpu_scheduling::contain_unregistered_priority_threads();
    cpu_scheduling::promote_compositor_thread();

    loop {
        service_session_lifecycle(drm, scanouts, swapchain, event_loop, &mut events, deadline)?;
        service_native_app_plugins(event_loop, &mut events, allocator)?;
        let iteration_now = Instant::now();
        if let Some(orientation) = events.pending_orientation.take() {
            pending_sensor_rotation = orientation.output_rotation();
            debug!(?orientation, rotation = ?pending_sensor_rotation, "observed device orientation");
        }
        events.service_topology_recheck_deadline(iteration_now);
        install_sampled_buffer_releases(event_loop, &mut events)?;
        scheduler.acknowledge_ready_fences(
            flutter
                .as_ref()
                .ok_or("Flutter runtime disappeared during fence acknowledgement")?,
            events.ready_fence_signals.drain(..),
        )?;
        let volition_events = std::mem::take(&mut events.volition_events);
        if let Some(stall) =
            scheduler.acknowledge_volition_events(volition_events, scanouts, &mut events)?
        {
            let commit = stall.commit();
            error!(
                stream = commit.stream,
                framebuffer_index = commit.frame,
                %stall,
                "KMS lookahead remained busy; rebuilding the DRM and render stack in this session"
            );
            scheduler.shutdown_volition();
            recover_stalled_kms_presentation(drm, event_loop, &mut events)?;
            continue;
        }
        let orientation_targets_idle = flutter.as_ref().is_some_and(|runtime| {
            !runtime.output_rotation_animation_active()
                && scanouts
                    .iter()
                    .all(|scanout| runtime.output_target_available(scanout.output.id))
        });
        if pending_sensor_rotation != output_configuration.sensor_rotation
            && !scheduler.has_pending_scanout_work()
            && orientation_targets_idle
        {
            scheduler.prepare_reconfiguration(scanouts, &mut events)?;
            apply_automatic_orientation(
                scanouts,
                swapchain,
                topology,
                &mut output_configuration,
                pending_sensor_rotation,
                &mut events,
                flutter
                    .as_mut()
                    .ok_or("Flutter runtime disappeared during automatic orientation")?,
            )?;
            if let Some(pending) = active_output_confirmation.as_mut() {
                pending.rollback_configuration.sensor_rotation = pending_sensor_rotation;
            }
            frame_scheduler.reconfigure(scanouts, iteration_now);
        }
        if active_output_confirmation
            .as_ref()
            .is_some_and(|pending| iteration_now >= pending.deadline)
        {
            let pending = active_output_confirmation
                .take()
                .expect("expired output confirmation exists");
            output_configuration = pending.rollback_configuration;
            events.output_power_requests.extend(pending.rollback_power);
            events.resident_geometry_reconfigure_requested = true;
            events.output_control_dirty = true;
            info!(
                token = pending.state.token,
                "rolling back unconfirmed output configuration"
            );
        }
        let needs_output_snapshot =
            ready_output_apply.is_some() || pending_output_success.is_some();
        let mut current_output_snapshot =
            output_control.publish_if_dirty(&mut events.output_control_dirty, || {
                output_control_state(
                    drm_scanner,
                    scanouts,
                    topology,
                    &output_configuration,
                    persistence_available,
                    active_output_confirmation
                        .as_ref()
                        .map(|pending| pending.state),
                )
            })?;
        if needs_output_snapshot && current_output_snapshot.is_none() {
            current_output_snapshot = Some(output_control.snapshot());
        }
        if let Some(request) = pending_output_success.take() {
            request.reply(Ok(current_output_snapshot
                .as_ref()
                .expect("successful output apply has a publication snapshot")
                .clone()));
        }
        while let Some(request) = pending_output_confirmation_success.pop_front() {
            request.reply(Ok(()));
        }
        if let Some(reason) = events.lifecycle.shutdown_reason() {
            log_shutdown(reason);
            break;
        }
        if deadline.is_some_and(|deadline| iteration_now >= deadline) {
            break;
        }
        if frame_limit.is_some_and(|limit| raster_frames >= limit) {
            break;
        }
        if events.device_removed {
            return Err("the active DRM device was removed in Flutter event loop".into());
        }

        let scanout_rebased = events.scanout_rebased;
        events.scanout_rebased = false;
        if scanout_rebased && let Some(runtime) = flutter.as_mut() {
            cancel_active_screenshot(
                &mut screenshot_manager,
                runtime,
                true,
                "scanout state changed",
            )?;
        }
        if !scanout_rebased {
            let runtime = flutter
                .as_mut()
                .ok_or("Flutter runtime disappeared during page-flip completion")?;
            scheduler.handle_completions(
                runtime,
                swapchain
                    .outputs_mut()
                    .ok_or("page-flip completion has no physical output pools")?,
                scanouts,
                &mut events,
            )?;
            for presented in scheduler
                .presented_outputs()
                .iter()
                .filter(|presented| presented.presented_at.is_some())
            {
                frame_scheduler.observe_presentation(
                    presented.id,
                    presented.timeline_target,
                    presented.observed_at,
                );
            }
            if drm.is_active()
                && let Some(stall) = scheduler.presentation_stall(iteration_now)
            {
                let output = scanouts
                    .get(stall.scanout_index)
                    .map(|scanout| scanout.output.name.as_str())
                    .unwrap_or("unknown");
                error!(
                    output,
                    framebuffer_index = stall.framebuffer_index,
                    pending_frames = stall.pending_frames,
                    stalled_ms = stall.elapsed.as_millis(),
                    "KMS presentation stopped making progress; rebuilding the DRM and render stack in this session"
                );
                // A monitor waking from DPMS can accept an atomic commit while
                // its link is still training, then withhold the matching
                // page-flip event.  Do not return an error here: a display
                // manager interprets the compositor's non-zero exit as an
                // ordinary ended session and drops the user onto a getty.
                // Reset to a synchronous KMS baseline instead; the topology
                // branch below rescans the connectors and recreates Flutter
                // and its per-output scheduler.
                scheduler.shutdown_volition();
                recover_stalled_kms_presentation(drm, event_loop, &mut events)?;
                continue;
            }
            // Deadline-critical lane. Raster completion is published before
            // its callback wakeup, so retire that wakeup without servicing
            // unrelated Flutter messages and transfer the finished output
            // batch before the sole output-timeline decision below. Physical
            // presentations retire resources but never authorize rendering.
            // Input and compositor bookkeeping deliberately run afterward.
            runtime.observe_frame_ready_events(&mut events.flutter_events);

            // A page flip can retire the sole submitted generation while its
            // following frame already occupies Ready. Move that frame into
            // the now-free Volition slot before the timer decision, exposing
            // the third pool entry for exactly one new raster lookahead.
            submit_ready_frames(&mut scheduler, swapchain)?;

            loop {
                let Some(ready) =
                    runtime.take_ready_frame(|output| scheduler.ready_handoff_available(output))
                else {
                    break;
                };
                let output = ready.output_id;
                let dirty_serial = ready.request.dirty_serial;
                if let Some(watch) = scheduler.publish_ready(runtime, ready)? {
                    install_ready_fence_watch(event_loop, watch)?;
                }
                frame_scheduler.complete_render(output, dirty_serial);
                raster_frames = raster_frames.saturating_add(1);
            }

            // A Wayland buffer commit can wake calloop immediately before an
            // output deadline. Publish that already-committed source before
            // consuming the tick, so the timer observes the app's dirty state
            // in the same iteration. Metadata rebuilds remain in the
            // background lane below; this is only the steady-state buffer
            // handoff required by the central scheduling decision.
            try_synchronize_flutter_buffers(runtime, &mut events)?;
            let frame_now = Instant::now();
            if runtime.output_rotation_animation_active()
                && frame_scheduler.output_tick_due(frame_now)
            {
                let advance = runtime.advance_output_rotation_animation(frame_now)?;
                if advance.advanced {
                    // Projection-only frames reuse Flutter's retained scene.
                    // No Dart vsync, external-texture advance or buffer
                    // allocation is needed before the late geometry handoff.
                    frame_scheduler.mark_all_dirty();
                }
                if advance.geometry_published {
                    let snapshot = topology.snapshot();
                    let atlas = AtlasPlan::for_snapshot(&snapshot)
                        .ok_or("animated output resize produced no Flutter desktop geometry")?;
                    synchronize_resident_flutter_geometry_state(&mut events, &atlas);
                }
            }
            collect_flutter_output_damage(runtime, &mut frame_scheduler);

            let output_apply_waiting =
                ready_output_apply.is_some() || !events.pending_output_applies.is_empty();
            if !output_apply_waiting && frame_limit.is_none_or(|limit| raster_frames < limit) {
                let frame_action = frame_scheduler.step_with_output_availability(
                    frame_now,
                    runtime.pending_frame(),
                    |output| {
                        scheduler.render_available(output)
                            && runtime.output_target_available(output)
                    },
                );
                match frame_action {
                    frame_scheduler::FrameAction::Skip => {}
                    frame_scheduler::FrameAction::Render { flutter_output } => {
                        if runtime.render_authorized_outputs(
                            frame_scheduler.render_requests(),
                            frame_scheduler.render_texture_ids(),
                            flutter_output,
                        )? {
                            frame_scheduler.flutter_frame_dispatched();
                            delivered_vsyncs = delivered_vsyncs.saturating_add(1);
                        }
                    }
                }
            }

            // Queue any output targets which were complete when this iteration began.
            // This remains ahead of input, Wayland traversal, and background
            // shell synchronization, but follows frame-clock authorization so
            // those tasks cannot perturb Flutter's animation timestamp.
            submit_ready_frames(&mut scheduler, swapchain)?;
            for tick in frame_scheduler.output_ticks().iter().copied() {
                if let Some(frontend) = events.wayland.as_mut() {
                    frontend.frame_tick(tick)?;
                }
                scheduler.process_screencopies_at_tick(
                    tick,
                    renderer,
                    swapchain
                        .outputs_mut()
                        .ok_or("screencopy has no physical output pools")?,
                    scanouts,
                    &mut events,
                )?;
            }

            // Freeze a tagged output batch as soon as its page-flip completion
            // makes it visible. Waiting for a later timeline tick would let
            // another frame replace the tagged scanout first.
            if let Some(manager) = screenshot_manager.as_mut()
                && let Some(target_output) = manager.target_output()
                && let Some(request_id) = manager.request_id()
                && scheduler
                    .screenshot_framebuffer_for_output(target_output, request_id, scanouts)
                    .is_some()
            {
                let snapshot = topology.snapshot();
                let atlas = AtlasPlan::for_snapshot(&snapshot)
                    .ok_or("prepared screenshot has no desktop atlas")?;
                let mut sources = screenshot_composite_sources(
                    &scheduler,
                    swapchain
                        .outputs()
                        .ok_or("prepared screenshot has no physical output pools")?,
                    &atlas,
                )?;
                match manager.capture_prepared_frame(renderer, runtime, target_output, &mut sources)
                {
                    Ok(Some((request_id, texture_id))) => runtime.send_screenshot_action(
                        wire::ShellAction::ScreenshotTextureReady,
                        request_id,
                        Some(texture_id),
                    )?,
                    Ok(None) => {}
                    Err(error) => {
                        warn!(%error, "could not freeze the screenshot selection canvas");
                        if let Some(request_id) = manager.cancel_selection(runtime, None)? {
                            runtime.send_screenshot_action(
                                wire::ShellAction::ScreenshotDone,
                                request_id,
                                None,
                            )?;
                        }
                    }
                }
            }
        }
        if let Some(error) = events.error.take() {
            return Err(format!("DRM event error in Flutter event loop: {error}").into());
        }

        let background_started = Instant::now();

        collect_output_power_requests(&mut events);
        synchronize_idle_dpms(scanouts, &mut events, background_started);
        // The synchronous VT-resume commit invalidated the old scheduler's
        // per-output buffer ownership. Preserve requests until the topology
        // path below recreates that scheduler.
        if !scanout_rebased && !events.output_power_requests.is_empty() {
            let power_changed = apply_output_power_requests(
                flutter
                    .as_mut()
                    .ok_or("Flutter runtime disappeared during DPMS dispatch")?,
                &mut scheduler,
                swapchain,
                scanouts,
                &mut events,
            )?;
            if power_changed {
                frame_scheduler.reconfigure(scanouts, Instant::now());
            }
        }
        if events.output_control_dirty {
            // Publish DPMS changes at the single loop-boundary gate above
            // before processing more compositor or Flutter work.
            continue;
        }

        while let Some(request) = events.pending_ui_development.pop_front() {
            let Some(runtime) = flutter.as_mut() else {
                request.reply(Err(output_control::OutputControlFailure::new(
                    "unavailable",
                    "the Flutter runtime is unavailable",
                )));
                continue;
            };
            let is_query = request.command.kind() == ui_development::CommandKind::Query;
            let (reload_requested, state) =
                flutter_launcher.handle_external_ui_development(runtime, request.command.clone());
            if reload_requested {
                events.flutter_reload_requested = true;
            }
            if !is_query && let Some(error) = state.error_message() {
                request.reply(Err(output_control::OutputControlFailure::new(
                    "rejected", error,
                )));
            } else {
                request.reply(Ok(state));
            }
        }

        let mut output_confirmation_handled = false;
        while let Some(request) = events.pending_output_confirmations.pop_front() {
            let Some(pending) = active_output_confirmation.take() else {
                request.reply(Err(output_control::OutputControlFailure::new(
                    "stale_confirmation",
                    "there is no output configuration awaiting confirmation",
                )));
                continue;
            };
            if request.token != pending.state.token {
                active_output_confirmation = Some(pending);
                request.reply(Err(output_control::OutputControlFailure::new(
                    "stale_confirmation",
                    "the output confirmation token is stale",
                )));
                continue;
            }

            output_confirmation_handled = true;
            match request.action {
                OutputConfirmationAction::Keep => {
                    if let Some(prepared) = pending.prepared_persistence
                        && let Err(error) = prepared.commit()
                    {
                        output_configuration = pending.rollback_configuration;
                        events.output_power_requests.extend(pending.rollback_power);
                        events.resident_geometry_reconfigure_requested = true;
                        events.output_control_dirty = true;
                        warn!(%error, "could not persist confirmed output configuration; rolling it back");
                        request.reply(Err(output_control::OutputControlFailure::new(
                            "persistence_failed",
                            error,
                        )));
                        continue;
                    }
                    events.output_control_dirty = true;
                    info!(token = pending.state.token, "kept output configuration");
                    pending_output_confirmation_success.push_back(request);
                }
                OutputConfirmationAction::Rollback => {
                    output_configuration = pending.rollback_configuration;
                    events.output_power_requests.extend(pending.rollback_power);
                    events.resident_geometry_reconfigure_requested = true;
                    events.output_control_dirty = true;
                    info!(
                        token = pending.state.token,
                        "rolling back output configuration on request"
                    );
                    pending_output_confirmation_success.push_back(request);
                }
            }
        }
        if output_confirmation_handled {
            continue;
        }

        if scanout_rebased && let Some((request, _)) = ready_output_apply.take() {
            // A VT resume invalidates the scheduler and any connector view
            // prepared against it. Re-scan the request after topology repair.
            events.pending_output_applies.push_front(request);
        }

        if !scanout_rebased
            && ready_output_apply.is_none()
            && let Some(request) = events.pending_output_applies.pop_front()
        {
            if active_output_confirmation.is_some() {
                request.reply(Err(output_control::OutputControlFailure::new(
                    "confirmation_pending",
                    "keep or roll back the current output configuration before applying another",
                )));
                continue;
            }
            if scheduler.has_pending_scanout_work() {
                submit_ready_frames(&mut scheduler, swapchain)?;
                events.pending_output_applies.push_front(request);
                let now = Instant::now();
                let timeout = deadline.map_or(Duration::from_millis(50), |deadline| {
                    Duration::from_millis(50).min(deadline.saturating_duration_since(now))
                });
                event_loop.dispatch(timeout, &mut events)?;
                continue;
            }

            let connectors = match scan_connected_connectors(drm_scanner, drm) {
                Ok(connectors) => connectors,
                Err(error) => {
                    request.reply(Err(output_control::OutputControlFailure::new(
                        "apply_failed",
                        format!("DRM connector scan failed: {error}"),
                    )));
                    events.topology_dirty = true;
                    continue;
                }
            };
            // A direct apply request performs a fresh connector scan. Route
            // that observation through the same boundary publication as udev
            // topology and mode changes before validating its serial.
            events.output_control_dirty = true;
            ready_output_apply = Some((request, connectors));
            continue;
        }

        if !scanout_rebased && let Some((request, connectors)) = ready_output_apply.take() {
            let scanout_work_pending = scheduler.has_pending_scanout_work();
            let resident_targets_idle = flutter.as_ref().is_some_and(|runtime| {
                scanouts
                    .iter()
                    .all(|scanout| runtime.output_target_available(scanout.output.id))
            });
            if scanout_work_pending || !resident_targets_idle {
                // Connector discovery deliberately spans an event-loop
                // iteration. A Flutter frame which was already in flight can
                // become ready or submitted during that boundary. Keep the
                // prepared request as a render barrier and drain that final
                // old-geometry frame instead of treating normal scheduler
                // ownership as a fatal reconfiguration error.
                ready_output_apply = Some((request, connectors));
                submit_ready_frames(&mut scheduler, swapchain)?;
                let now = Instant::now();
                let timeout = deadline.map_or(Duration::from_millis(50), |deadline| {
                    Duration::from_millis(50).min(deadline.saturating_duration_since(now))
                });
                event_loop.dispatch(timeout, &mut events)?;
                continue;
            }
            let current_snapshot = current_output_snapshot
                .as_ref()
                .expect("prepared output apply has a publication snapshot");
            if request.configuration.serial != current_snapshot.serial {
                let message = format!(
                    "configuration serial {} is stale; current serial is {}",
                    request.configuration.serial, current_snapshot.serial
                );
                request.reply(Err(output_control::OutputControlFailure::new(
                    "stale_configuration",
                    message,
                )));
                events.topology_dirty = true;
                continue;
            }
            let transform_only_request = output_request_changes_only_transforms(
                &current_snapshot.outputs,
                &request.configuration.outputs,
            );
            let confirmation_rollback = request
                .configuration
                .confirmation_timeout_milliseconds
                .map(|timeout_milliseconds| {
                    let rollback_power = scanouts
                        .iter()
                        .map(|scanout| (scanout.output.id, scanout.powered))
                        .collect::<BTreeMap<_, _>>();
                    (
                        output_configuration.clone(),
                        rollback_power,
                        Duration::from_millis(timeout_milliseconds),
                    )
                });
            let (staged_configuration, desired_power) = match configuration_from_output_request(
                &request.configuration,
                &connectors,
                max_outputs,
                &output_configuration,
                persistence_available,
            ) {
                Ok(configuration) => configuration,
                Err(error) => {
                    request.reply(Err(error));
                    continue;
                }
            };
            let outputs = match configured_outputs(connectors, max_outputs, &staged_configuration) {
                Ok(outputs) => outputs,
                Err(error) => {
                    request.reply(Err(output_control::OutputControlFailure::new(
                        "invalid_configuration",
                        error.to_string(),
                    )));
                    continue;
                }
            };
            let preview = (|| -> Result<TopologySnapshot, Box<dyn Error>> {
                let mut preview_topology = topology.clone();
                let preview_snapshot = update_topology_for_outputs(
                    &mut preview_topology,
                    &outputs,
                    &staged_configuration,
                )?;
                AtlasPlan::for_snapshot(&preview_snapshot)
                    .ok_or("output configuration produced no scanout atlas")?;
                Ok(preview_snapshot)
            })();
            let preview = match preview {
                Ok(preview) => preview,
                Err(error) => {
                    request.reply(Err(output_control::OutputControlFailure::new(
                        "invalid_configuration",
                        error.to_string(),
                    )));
                    continue;
                }
            };
            let prepared_persistence = if request.configuration.persistent {
                let path = output_config
                    .as_deref()
                    .expect("persistent requests were rejected without --output-config");
                let persisted_outputs = request
                    .configuration
                    .outputs
                    .iter()
                    .map(|output| options::PersistedOutput {
                        name: output.name.clone(),
                        enabled: output.enabled,
                        x: output.x,
                        y: output.y,
                        width: output.mode.width,
                        height: output.mode.height,
                        refresh_millihz: output.mode.refresh_millihz,
                        scale_120: (output.scale * f64::from(SCALE_BASE)).round() as u32,
                        transform: staged_configuration
                            .transforms
                            .get(&output.name)
                            .copied()
                            .unwrap_or(OutputTransform::Normal),
                        adaptive_sync: output.adaptive_sync,
                    })
                    .collect::<Vec<_>>();
                match options::prepare_output_config_persistence(path, &persisted_outputs) {
                    Ok(prepared) => Some(prepared),
                    Err(error) => {
                        request.reply(Err(output_control::OutputControlFailure::new(
                            "persistence_failed",
                            &error,
                        )));
                        warn!(%error, path = %path.display(), "could not prepare persistent output configuration");
                        continue;
                    }
                }
            } else {
                None
            };
            let hardware_changed = outputs.len() != scanouts.len()
                || outputs.iter().any(|output| {
                    scanouts
                        .iter()
                        .find(|scanout| scanout.output.id == output.id)
                        .is_none_or(|scanout| {
                            scanout.output.crtc != output.crtc
                                || scanout.output.mode != output.mode
                                || scanout.output.connector != output.connector
                                || scanout.output.vrr_enabled != output.vrr_enabled
                        })
                });
            let topology_changed = preview.outputs != topology.snapshot().outputs;
            if !scanout_rebased && !hardware_changed && !topology_changed {
                output_configuration = staged_configuration;
                events.output_control_dirty = true;
                events.output_power_requests.extend(desired_power);
                let power_changed = apply_output_power_requests(
                    flutter
                        .as_mut()
                        .ok_or("Flutter runtime disappeared during output power application")?,
                    &mut scheduler,
                    swapchain,
                    scanouts,
                    &mut events,
                )?;
                if power_changed {
                    frame_scheduler.reconfigure(scanouts, Instant::now());
                }
                if let Some((rollback_configuration, rollback_power, timeout)) =
                    confirmation_rollback
                {
                    active_output_confirmation = Some(begin_output_confirmation(
                        current_snapshot.serial,
                        timeout,
                        rollback_configuration,
                        rollback_power,
                        prepared_persistence,
                    ));
                } else if let Some(prepared) = prepared_persistence {
                    events.output_control_dirty = true;
                    if let Err(error) = prepared.commit() {
                        request.reply(Err(output_control::OutputControlFailure::new(
                            "persistence_failed",
                            &error,
                        )));
                        warn!(%error, "output configuration applied but could not be persisted");
                        continue;
                    }
                }
                pending_output_success = Some(request);
                continue;
            }

            if !scanout_rebased && !hardware_changed {
                scheduler.prepare_reconfiguration(scanouts, &mut events)?;
                // Output transforms on resident Flutter pools are compositor
                // projections, never KMS plane rotations. Give Settings the
                // same retained-layer transition used by sensor orientation;
                // mixed layout, scale and mode transactions remain immediate.
                let transition = if transform_only_request {
                    flutter_runtime::OutputGeometryTransition::AnimatedRotation
                } else {
                    flutter_runtime::OutputGeometryTransition::Immediate
                };
                let apply = apply_resident_output_geometry(
                    scanouts,
                    swapchain,
                    topology,
                    &mut output_configuration,
                    outputs,
                    staged_configuration,
                    transition,
                    &mut events,
                    flutter.as_mut().ok_or(
                        "Flutter runtime disappeared during resident output reconfiguration",
                    )?,
                );
                if let Err(error) = apply {
                    let message = error.to_string();
                    events.output_control_dirty = true;
                    request.reply(Err(output_control::OutputControlFailure::new(
                        "apply_failed",
                        &message,
                    )));
                    warn!(%message, "rejected resident output reconfiguration");
                    continue;
                }
                frame_scheduler.reconfigure(scanouts, Instant::now());
                events.output_power_requests.extend(desired_power);
                let power_changed = apply_output_power_requests(
                    flutter
                        .as_mut()
                        .ok_or("Flutter runtime disappeared during output power application")?,
                    &mut scheduler,
                    swapchain,
                    scanouts,
                    &mut events,
                )?;
                if power_changed {
                    frame_scheduler.reconfigure(scanouts, Instant::now());
                }
                if let Some((rollback_configuration, rollback_power, timeout)) =
                    confirmation_rollback
                {
                    active_output_confirmation = Some(begin_output_confirmation(
                        current_snapshot.serial,
                        timeout,
                        rollback_configuration,
                        rollback_power,
                        prepared_persistence,
                    ));
                } else if let Some(prepared) = prepared_persistence {
                    events.output_control_dirty = true;
                    if let Err(error) = prepared.commit() {
                        request.reply(Err(output_control::OutputControlFailure::new(
                            "persistence_failed",
                            &error,
                        )));
                        warn!(%error, "output configuration applied but could not be persisted");
                        continue;
                    }
                }
                pending_output_success = Some(request);
                continue;
            }

            if !scanout_rebased {
                scheduler.prepare_reconfiguration(scanouts, &mut events)?;
            }
            let apply = apply_hotplug_topology(
                renderer,
                scanout_allocator,
                drm,
                swapchain,
                scanouts,
                restore_state,
                topology,
                outputs,
                &staged_configuration,
                raster_frames,
                event_loop,
                &mut events,
                &mut flutter,
                Some(flutter_launcher),
            );
            if let Err(error) = apply {
                let message = error.to_string();
                events.output_control_dirty = true;
                request.reply(Err(output_control::OutputControlFailure::new(
                    "apply_failed",
                    &message,
                )));
                if flutter.is_none() {
                    return Err(format!(
                        "output-control transaction failed after Flutter shutdown: {message}"
                    )
                    .into());
                }
                warn!(%message, "rejected output-control transaction");
                continue;
            }

            retired_output_flips =
                retired_output_flips.saturating_add(scheduler.presented_frames());
            output_configuration = staged_configuration;
            events.output_control_dirty = true;
            scheduler = output_scheduler::OutputScheduler::new(
                drm,
                volition_event_sender.clone(),
                scanouts,
                swapchain
                    .outputs()
                    .ok_or("output scheduler has no physical output pools")?,
                flutter
                    .as_mut()
                    .ok_or("Flutter runtime was not restarted after output reconfiguration")?,
                &mut events,
            )?;
            frame_scheduler = frame_scheduler::FrameScheduler::new(scanouts, Instant::now());
            events.output_power_requests.extend(desired_power);
            let power_changed = apply_output_power_requests(
                flutter
                    .as_mut()
                    .ok_or("Flutter runtime disappeared during output power application")?,
                &mut scheduler,
                swapchain,
                scanouts,
                &mut events,
            )?;
            if power_changed {
                frame_scheduler.reconfigure(scanouts, Instant::now());
            }
            if let Some((rollback_configuration, rollback_power, timeout)) = confirmation_rollback {
                active_output_confirmation = Some(begin_output_confirmation(
                    current_snapshot.serial,
                    timeout,
                    rollback_configuration,
                    rollback_power,
                    prepared_persistence,
                ));
            } else if let Some(prepared) = prepared_persistence {
                events.output_control_dirty = true;
                if let Err(error) = prepared.commit() {
                    request.reply(Err(output_control::OutputControlFailure::new(
                        "persistence_failed",
                        &error,
                    )));
                    warn!(%error, "output configuration applied but could not be persisted");
                    events.scanout_rebased = false;
                    continue;
                }
            }
            pending_output_success = Some(request);
            events.scanout_rebased = false;
            continue;
        }

        let kms_reconfigure_requested = events.kms_reconfigure_requested;
        events.kms_reconfigure_requested = false;
        let resident_geometry_reconfigure_requested =
            events.resident_geometry_reconfigure_requested;
        events.resident_geometry_reconfigure_requested = false;
        if events.topology_dirty
            || scanout_rebased
            || kms_reconfigure_requested
            || resident_geometry_reconfigure_requested
        {
            events.topology_dirty = false;
            let outputs = connected_outputs(drm_scanner, drm, max_outputs, &output_configuration)?;
            let now = Instant::now();
            let transient_removals = if !scanout_rebased && !kms_reconfigure_requested {
                transient_dpms_output_removal_count(
                    events.dpms_wake_topology_grace_until,
                    now,
                    scanouts.iter().map(|scanout| scanout.output.id),
                    outputs.iter().map(|output| output.id),
                )
            } else {
                0
            };
            if transient_removals > 0 {
                let recheck_at = events
                    .dpms_wake_topology_grace_until
                    .expect("transient DPMS removal has an active grace deadline");
                let first_observation = events.topology_recheck_at.replace(recheck_at).is_none();
                if first_observation {
                    info!(
                        missing_outputs = transient_removals,
                        grace_ms = recheck_at.saturating_duration_since(now).as_millis(),
                        "deferred transient connector removal during DPMS wake"
                    );
                }
            } else {
                if events.topology_recheck_at.take().is_some() {
                    info!("cancelled deferred connector removal after DPMS topology recovered");
                }
                events.output_control_dirty = true;
                let changed = outputs.len() != scanouts.len()
                    || outputs.iter().any(|output| {
                        scanouts
                            .iter()
                            .find(|scanout| scanout.output.id == output.id)
                            .is_none_or(|scanout| {
                                scanout.output.crtc != output.crtc
                                    || scanout.output.mode != output.mode
                                    || scanout.output.connector != output.connector
                                    || scanout.output.vrr_enabled != output.vrr_enabled
                            })
                    });
                info!(
                    connected_outputs = outputs.len(),
                    changed,
                    resumed = scanout_rebased,
                    forced = kms_reconfigure_requested,
                    resident_geometry = resident_geometry_reconfigure_requested,
                    "completed event-driven DRM topology rescan"
                );
                if changed
                    || scanout_rebased
                    || kms_reconfigure_requested
                    || resident_geometry_reconfigure_requested
                {
                    cancel_active_screenshot(
                        &mut screenshot_manager,
                        flutter
                            .as_mut()
                            .ok_or("Flutter runtime disappeared before topology change")?,
                        true,
                        "display topology changed",
                    )?;
                    let resident_targets_busy = resident_geometry_reconfigure_requested
                        && !changed
                        && !kms_reconfigure_requested
                        && flutter.as_ref().is_none_or(|runtime| {
                            scanouts
                                .iter()
                                .any(|scanout| !runtime.output_target_available(scanout.output.id))
                        });
                    if !scanout_rebased
                        && (scheduler.has_pending_scanout_work() || resident_targets_busy)
                    {
                        // Finish any ready old-topology batch before creating the
                        // common rollback point used by the hotplug transaction.
                        // A signalled ready fence can enter Volition lookahead;
                        // an unfinished one will wake this loop through calloop.
                        submit_ready_frames(&mut scheduler, swapchain)?;
                        events.topology_dirty = true;
                        events.kms_reconfigure_requested = kms_reconfigure_requested;
                        events.resident_geometry_reconfigure_requested =
                            resident_geometry_reconfigure_requested;
                        let now = Instant::now();
                        let timeout = deadline.map_or(Duration::from_millis(50), |deadline| {
                            Duration::from_millis(50).min(deadline.saturating_duration_since(now))
                        });
                        event_loop.dispatch(timeout, &mut events)?;
                        continue;
                    }
                    if !scanout_rebased {
                        scheduler.prepare_reconfiguration(scanouts, &mut events)?;
                    }
                    if resident_geometry_reconfigure_requested
                        && !changed
                        && !scanout_rebased
                        && !kms_reconfigure_requested
                    {
                        let staged_configuration = output_configuration.clone();
                        apply_resident_output_geometry(
                            scanouts,
                            swapchain,
                            topology,
                            &mut output_configuration,
                            outputs,
                            staged_configuration,
                            flutter_runtime::OutputGeometryTransition::Immediate,
                            &mut events,
                            flutter.as_mut().ok_or(
                                "Flutter runtime disappeared during resident geometry rollback",
                            )?,
                        )?;
                        frame_scheduler.reconfigure(scanouts, Instant::now());
                        events.scanout_rebased = false;
                        continue;
                    }
                    retired_output_flips =
                        retired_output_flips.saturating_add(scheduler.presented_frames());
                    let topology_apply = apply_hotplug_topology(
                        renderer,
                        scanout_allocator,
                        drm,
                        swapchain,
                        scanouts,
                        restore_state,
                        topology,
                        outputs,
                        &output_configuration,
                        raster_frames,
                        event_loop,
                        &mut events,
                        &mut flutter,
                        Some(flutter_launcher),
                    );
                    if let Err(error) = topology_apply {
                        if scanout_rebased && flutter.is_some() {
                            // Recovery may reach this transaction while a
                            // monitor is still link-training.  Its synchronous
                            // baseline was accepted, but the transaction's
                            // first event-producing flip can still time out.
                            // Keep the login and retry from a fresh connector
                            // scan instead of returning status 1 to SDDM.
                            warn!(
                                %error,
                                retry_ms = KMS_PRESENTATION_RECOVERY_RETRY.as_millis(),
                                "KMS topology rebuild is waiting for the display hardware"
                            );
                            events.scanout_rebased = true;
                            events.topology_dirty = true;
                            event_loop.dispatch(KMS_PRESENTATION_RECOVERY_RETRY, &mut events)?;
                            continue;
                        }
                        return Err(error);
                    }
                    scheduler = output_scheduler::OutputScheduler::new(
                        drm,
                        volition_event_sender.clone(),
                        scanouts,
                        swapchain
                            .outputs()
                            .ok_or("output scheduler has no physical output pools")?,
                        flutter
                            .as_mut()
                            .ok_or("Flutter runtime was not restarted after topology change")?,
                        &mut events,
                    )?;
                    frame_scheduler =
                        frame_scheduler::FrameScheduler::new(scanouts, Instant::now());
                    if events.flutter_reload_requested {
                        events.flutter_reload_requested = false;
                        info!(
                            generation = flutter_launcher.generation,
                            "loaded the refreshed Flutter bundle during topology restart"
                        );
                    }
                    // A pause/resume serviced inside the topology transaction was
                    // already absorbed by its synchronous candidate commit and the
                    // freshly created scheduler.
                    events.scanout_rebased = false;
                    continue;
                }
            }
        }
        if events.output_control_dirty {
            continue;
        }

        if events.flutter_reload_requested {
            cancel_active_screenshot(
                &mut screenshot_manager,
                flutter
                    .as_mut()
                    .ok_or("Flutter runtime disappeared before bundle refresh")?,
                true,
                "Flutter runtime is refreshing",
            )?;
            if scheduler.has_pending_scanout_work() {
                // Stop servicing the producer while its last output batch reaches
                // every affected CRTC. A ready fence or page flip will wake
                // this loop through calloop, without disturbing clients or
                // the graphical session.
                submit_ready_frames(&mut scheduler, swapchain)?;
                let now = Instant::now();
                let timeout = deadline.map_or(Duration::from_millis(50), |deadline| {
                    Duration::from_millis(50).min(deadline.saturating_duration_since(now))
                });
                event_loop.dispatch(timeout, &mut events)?;
                continue;
            }

            scheduler.prepare_reconfiguration(scanouts, &mut events)?;
            retired_output_flips =
                retired_output_flips.saturating_add(scheduler.presented_frames());
            reload_flutter_runtime(
                renderer,
                swapchain,
                scanouts,
                topology,
                &mut events,
                &mut flutter,
                flutter_launcher,
            )?;
            scheduler = output_scheduler::OutputScheduler::new(
                drm,
                volition_event_sender.clone(),
                scanouts,
                swapchain
                    .outputs()
                    .ok_or("output scheduler has no physical output pools")?,
                flutter
                    .as_mut()
                    .ok_or("Flutter runtime was not restarted after bundle refresh")?,
                &mut events,
            )?;
            frame_scheduler = frame_scheduler::FrameScheduler::new(scanouts, Instant::now());
            events.flutter_reload_requested = false;
            info!(
                generation = flutter_launcher.generation,
                "refreshed Flutter bundle without restarting the compositor session"
            );
            continue;
        }

        let runtime = flutter
            .as_mut()
            .ok_or("Flutter runtime disappeared from event loop")?;
        runtime.process_input_batch(&mut events.flutter_input)?;
        // Drain in place so the callback queue keeps its allocation across
        // frame/engine dispatches. AwaitVSync and platform-task traffic is a
        // steady-state hot path and must not rebuild this Vec every time.
        let flutter_event_batch = events
            .flutter_events
            .len()
            .min(MAX_FLUTTER_EVENTS_PER_ITERATION);
        runtime.process_events(events.flutter_events.drain(..flutter_event_batch))?;
        if background_started.elapsed() >= COMPOSITOR_BACKGROUND_SLICE {
            event_loop.dispatch(Duration::ZERO, &mut events)?;
            continue;
        }
        if flutter_launcher.synchronize_ui_development(runtime)? {
            events.flutter_reload_requested = true;
        }
        synchronize_idle_dpms_configuration(runtime, &mut events);
        synchronize_authentication_boundary(&mut events);
        synchronize_requested_dpms_off(runtime, scanouts, &mut events);
        let screenshot_is_invalid = screenshot_manager.as_ref().is_some_and(|manager| {
            manager.request_id().is_some()
                && (events.secure_session_locked()
                    || manager.topology_epoch() != Some(topology.epoch())
                    || manager.target_output().is_some_and(|output| {
                        scheduler
                            .framebuffer_index_for_output(output, scanouts)
                            .is_none()
                    }))
        });
        if screenshot_is_invalid {
            cancel_active_screenshot(
                &mut screenshot_manager,
                runtime,
                true,
                "screenshot canvas is no longer valid",
            )?;
        }
        synchronize_clipboard(runtime, &mut events)?;
        synchronize_system_control_events(runtime, &mut events)?;
        synchronize_notification_events(runtime, &mut events)?;
        synchronize_shell_keyboard(runtime, &mut events)?;
        synchronize_settings(runtime, &mut events)?;
        synchronize_system_bar_configuration(runtime, &mut events, Some(flutter_launcher));
        if background_started.elapsed() >= COMPOSITOR_BACKGROUND_SLICE {
            event_loop.dispatch(Duration::ZERO, &mut events)?;
            continue;
        }
        synchronize_flutter_window_management(runtime, &mut events)?;
        synchronize_flutter_scene(runtime, &mut events)?;
        collect_flutter_output_damage(runtime, &mut frame_scheduler);
        synchronize_flutter_input_layout(runtime, &mut events)?;
        synchronize_wayland_cursor(runtime, &mut events)?;
        if background_started.elapsed() >= COMPOSITOR_BACKGROUND_SLICE {
            event_loop.dispatch(Duration::ZERO, &mut events)?;
            continue;
        }
        let screenshot_prepared = runtime.take_screenshot_prepared();
        let screenshot_cancelled = runtime.take_screenshot_cancelled();
        let screenshot_request = runtime.take_screenshot_requested();
        if runtime.take_logout_requested() {
            info!("Flutter requested session logout");
            break;
        }
        if events.flutter_channel_closed {
            return Err("Flutter callback channel closed while the engine was running".into());
        }
        if let Some(frontend) = events.wayland.as_mut() {
            frontend.process_pending_dmabufs(renderer)?;
        }

        if let Some(target_output) = events.pending_screenshot_selection.take() {
            if let Some(manager) = screenshot_manager.as_mut() {
                let snapshot = topology.snapshot();
                let atlas = AtlasPlan::for_snapshot(&snapshot)
                    .ok_or("screenshot preparation has no atlas")?;
                if scheduler
                    .framebuffer_index_for_output(target_output, scanouts)
                    .is_none()
                {
                    warn!(?target_output, "screenshot target output is not powered");
                    continue;
                }
                let output_swapchains = swapchain
                    .outputs()
                    .ok_or("screenshot selection has no physical output pools")?;
                let modifier =
                    screenshot_buffer_modifier(&scheduler, output_swapchains, target_output)?;
                match manager.begin_selection(allocator, target_output, atlas, modifier) {
                    Ok(Some(request_id)) => {
                        if let Err(error) = runtime.send_screenshot_action(
                            wire::ShellAction::ScreenshotRegion,
                            request_id,
                            None,
                        ) {
                            let _ = manager.cancel_selection(runtime, Some(request_id));
                            return Err(error);
                        }
                    }
                    Ok(None) => debug!("ignored repeated screenshot selection shortcut"),
                    Err(error) => warn!(%error, "could not allocate screenshot selection buffer"),
                }
            } else {
                warn!("screenshot selection ignored because the writer is unavailable");
            }
        }

        if let Some(request_id) = screenshot_prepared
            && let Some(manager) = screenshot_manager.as_mut()
            && manager.request_id() == Some(request_id.get())
        {
            let Some(target_output) = manager.target_output() else {
                return Err("prepared screenshot lost its target output".into());
            };
            if scheduler
                .framebuffer_index_for_output(target_output, scanouts)
                .is_none()
            {
                let finished = manager.cancel_selection(runtime, Some(request_id.get()))?;
                if let Some(request_id) = finished {
                    runtime.send_screenshot_action(
                        wire::ShellAction::ScreenshotDone,
                        request_id,
                        None,
                    )?;
                }
                continue;
            }
            if manager.prepared(request_id.get()) {
                runtime.arm_screenshot_frame(target_output, request_id.get())?;
                frame_scheduler.mark_output_dirty(target_output);
            } else {
                warn!(
                    request_id = request_id.get(),
                    "ignored stale screenshot preparation"
                );
            }
        }

        if let Some(request_id) = screenshot_cancelled
            && let Some(manager) = screenshot_manager.as_mut()
            && let Some(request_id) = manager.cancel_selection(runtime, Some(request_id.get()))?
        {
            runtime.send_screenshot_action(wire::ShellAction::ScreenshotDone, request_id, None)?;
        }

        if let Some(request) = screenshot_request {
            if let Some(manager) = screenshot_manager.as_ref() {
                if request.request_id.is_none() {
                    let snapshot = topology.snapshot();
                    if let Some(atlas) = AtlasPlan::for_snapshot(&snapshot) {
                        let output_swapchains = swapchain
                            .outputs()
                            .ok_or("live screenshot has no physical output pools")?;
                        let mut sources =
                            screenshot_composite_sources(&scheduler, output_swapchains, &atlas)?;
                        let source_output = atlas
                            .outputs
                            .first()
                            .ok_or("live screenshot atlas has no outputs")?
                            .id;
                        let modifier = screenshot_buffer_modifier(
                            &scheduler,
                            output_swapchains,
                            source_output,
                        )?;
                        if let Err(error) = manager.capture_live(
                            renderer,
                            allocator,
                            &atlas,
                            modifier,
                            &mut sources,
                            request,
                        ) {
                            warn!(%error, "screenshot capture failed");
                        }
                    } else {
                        warn!("screenshot capture skipped because the atlas is unavailable");
                    }
                }
            } else {
                warn!("screenshot request ignored because the writer is unavailable");
            }
        }

        if let Some(request) = screenshot_request
            && let Some(request_id) = request.request_id.map(|request_id| request_id.get())
            && let Some(manager) = screenshot_manager.as_mut()
            && manager.request_id() == Some(request_id)
        {
            if let Err(error) = manager.finish_selection(renderer, runtime, request) {
                warn!(%error, request_id, "frozen screenshot capture failed");
            }
            runtime.send_screenshot_action(wire::ShellAction::ScreenshotDone, request_id, None)?;
        }

        let now = Instant::now();
        let mut next_dispatch_timeout =
            frame_scheduler.limit_dispatch_timeout(now, runtime.next_dispatch_timeout());
        next_dispatch_timeout = events
            .idle_dpms
            .limit_dispatch_timeout(now, next_dispatch_timeout);
        if drm.is_active() {
            next_dispatch_timeout =
                scheduler.limit_presentation_watchdog_timeout(now, next_dispatch_timeout);
        }
        if events.flutter_input.has_pending() || !events.flutter_events.is_empty() {
            next_dispatch_timeout = Duration::ZERO;
        }
        if let Some(recheck_at) = events.topology_recheck_at {
            next_dispatch_timeout =
                next_dispatch_timeout.min(recheck_at.saturating_duration_since(now));
        }
        let dispatch_timeout = if let Some(deadline) = deadline {
            if now >= deadline {
                break;
            }
            next_dispatch_timeout.min(deadline.saturating_duration_since(now))
        } else {
            next_dispatch_timeout
        };
        event_loop.dispatch(dispatch_timeout, &mut events)?;
    }

    cancel_active_screenshot(
        &mut screenshot_manager,
        flutter
            .as_mut()
            .ok_or("Flutter runtime disappeared before screenshot teardown")?,
        false,
        "compositor is shutting down",
    )?;
    quiesce_flutter_page_flips(
        flutter
            .as_mut()
            .ok_or("Flutter runtime disappeared before page-flip quiescence")?,
        &mut scheduler,
        drm,
        swapchain,
        scanouts,
        event_loop,
        &mut events,
        // A real login session hands KMS ownership back to its display
        // manager. Restoring the framebuffer captured before Denial started is
        // both unnecessary and dangerous here: an atomic commit can wait
        // forever on a fence owned by the compositor which is currently
        // tearing down. Finite KMS tests still restore their captured state
        // after a successful drain.
        duration.is_none(),
    );
    scheduler.shutdown_volition();

    flutter
        .take()
        .ok_or("Flutter runtime disappeared during orderly shutdown")?
        .shutdown()
        .map_err(|error| format!("Flutter engine shutdown failed: {error}"))?;

    let elapsed = started.elapsed();
    let output_page_flips = retired_output_flips.saturating_add(scheduler.presented_frames());
    info!(
        raster_frames,
        output_page_flips,
        delivered_vsyncs,
        elapsed_ms = elapsed.as_secs_f64() * 1_000.0,
        raster_frames_per_second = raster_frames as f64 / elapsed.as_secs_f64(),
        finite = duration.is_some(),
        "independently clocked Flutter KMS session complete"
    );
    Ok(swapchain.representative_framebuffer())
}

#[cfg(feature = "flutter")]
fn cancel_active_screenshot(
    manager: &mut Option<screenshot::ScreenshotManager>,
    runtime: &mut flutter_runtime::FlutterRuntime,
    notify_flutter: bool,
    reason: &'static str,
) -> Result<(), Box<dyn Error>> {
    let Some(manager) = manager.as_mut() else {
        return Ok(());
    };
    let Some(request_id) = manager.cancel_selection(runtime, None)? else {
        return Ok(());
    };
    if notify_flutter {
        runtime.send_screenshot_action(wire::ShellAction::ScreenshotDone, request_id, None)?;
    }
    info!(request_id, reason, "cancelled screenshot selection");
    Ok(())
}

#[cfg(feature = "flutter")]
fn screenshot_buffer_modifier(
    scheduler: &output_scheduler::OutputScheduler,
    swapchains: &OutputSwapchains,
    output: OutputId,
) -> Result<Modifier, Box<dyn Error>> {
    let index = scheduler
        .stable_framebuffer_index(output)
        .ok_or("screenshot output has no stable framebuffer")?;
    swapchains
        .for_output(output)
        .and_then(|pool| pool.buffers.get(index))
        .map(|buffer| buffer.format().modifier)
        .ok_or_else(|| "screenshot output buffer exceeds its native pool".into())
}

#[cfg(feature = "flutter")]
fn screenshot_composite_sources(
    scheduler: &output_scheduler::OutputScheduler,
    swapchains: &OutputSwapchains,
    atlas: &AtlasPlan,
) -> Result<Vec<wayland_frontend::OutputCompositeSource>, Box<dyn Error>> {
    atlas
        .outputs
        .iter()
        .map(|output| {
            let index = scheduler
                .stable_framebuffer_index(output.id)
                .ok_or("screenshot output has no stable framebuffer")?;
            let dmabuf = swapchains
                .for_output(output.id)
                .and_then(|pool| pool.buffers.get(index))
                .ok_or("screenshot output buffer exceeds its native pool")?
                .dmabuf
                .clone();
            Ok(wayland_frontend::OutputCompositeSource {
                dmabuf,
                destination: physical_rect(output.source_rect)?,
                transform: smithay_output_transform(output.transform),
            })
        })
        .collect()
}

#[cfg(feature = "flutter")]
#[allow(clippy::too_many_arguments)]
fn reload_flutter_runtime(
    renderer: &mut GlesRenderer,
    swapchain: &RenderSwapchains,
    scanouts: &[Scanout],
    topology: &TopologyManager,
    events: &mut RuntimeState,
    flutter: &mut Option<flutter_runtime::FlutterRuntime>,
    flutter_launcher: &mut FlutterLauncher,
) -> Result<(), Box<dyn Error>> {
    let snapshot = topology.snapshot();
    let atlas = AtlasPlan::for_snapshot(&snapshot)
        .ok_or("current topology produced no atlas during Flutter bundle refresh")?;
    let Some(mut old_runtime) = flutter.take() else {
        return Err("Flutter runtime disappeared during bundle refresh".into());
    };
    let prepare_restart = (|| -> Result<(), Box<dyn Error>> {
        old_runtime.process_events(events.flutter_events.drain(..))?;
        let _ = flutter_launcher.synchronize_ui_development(&mut old_runtime)?;
        synchronize_authentication_boundary(events);
        synchronize_clipboard(&mut old_runtime, events)?;
        synchronize_system_control_events(&mut old_runtime, events)?;
        synchronize_shell_keyboard(&mut old_runtime, events)?;
        synchronize_settings(&mut old_runtime, events)?;
        synchronize_system_bar_configuration(&mut old_runtime, events, Some(flutter_launcher));
        synchronize_flutter_window_management(&mut old_runtime, events)?;
        synchronize_flutter_input_layout(&mut old_runtime, events)?;
        Ok(())
    })();
    let shutdown = old_runtime.shutdown();
    events.flutter_events.clear();
    match (prepare_restart, shutdown) {
        (Ok(()), Ok(())) => {}
        (Err(error), Ok(())) => {
            return Err(format!("Flutter pre-refresh drain failed: {error}").into());
        }
        (Ok(()), Err(error)) => {
            return Err(format!("Flutter shutdown before refresh failed: {error}").into());
        }
        (Err(prepare_error), Err(shutdown_error)) => {
            return Err(format!(
                "Flutter pre-refresh drain failed: {prepare_error}; shutdown failed: {shutdown_error}"
            )
            .into());
        }
    }

    *flutter = Some(
        flutter_launcher.start(
            renderer,
            swapchain
                .outputs()
                .ok_or("Flutter bundle refresh has no physical output pools")?,
            scanouts,
            &snapshot,
            &atlas,
        )?,
    );
    events.begin_replacement_flutter_generation(swapchain.desktop_size());
    Ok(())
}

#[cfg(feature = "flutter")]
#[allow(clippy::too_many_arguments)]
fn quiesce_flutter_page_flips(
    runtime: &mut flutter_runtime::FlutterRuntime,
    scheduler: &mut output_scheduler::OutputScheduler,
    drm: &mut DrmDevice,
    swapchain: &mut RenderSwapchains,
    scanouts: &[Scanout],
    event_loop: &mut EventLoop<'_, RuntimeState>,
    events: &mut RuntimeState,
    release_drm_master: bool,
) {
    const PAGE_FLIP_DRAIN_TIMEOUT: Duration = Duration::from_millis(250);
    const MAX_DISPATCH_SLICE: Duration = Duration::from_millis(20);

    let deadline = Instant::now() + PAGE_FLIP_DRAIN_TIMEOUT;
    while scheduler.has_submitted() && drm.is_active() {
        let now = Instant::now();
        if now >= deadline {
            warn!(
                timeout_ms = PAGE_FLIP_DRAIN_TIMEOUT.as_millis(),
                "KMS page flips did not quiesce during shutdown; releasing DRM master without atomic restore"
            );
            drm.pause();
            break;
        }

        if let Err(error) = event_loop.dispatch(
            MAX_DISPATCH_SLICE.min(deadline.saturating_duration_since(now)),
            events,
        ) {
            warn!(
                %error,
                "event dispatch failed while draining shutdown page flips; releasing DRM master"
            );
            drm.pause();
            return;
        }
        if let Err(error) =
            service_session_lifecycle(drm, scanouts, swapchain, event_loop, events, Some(deadline))
        {
            warn!(
                %error,
                "session transition failed while draining shutdown page flips; releasing DRM master"
            );
            drm.pause();
            return;
        }
        if let Err(error) = install_sampled_buffer_releases(event_loop, events) {
            warn!(%error, "could not install sampled-buffer release fence during shutdown");
            drm.pause();
            return;
        }
        if !drm.is_active() {
            break;
        }
        if events.scanout_rebased {
            // Resume establishes a synchronous scanout state and invalidates
            // every pre-pause scheduler ownership record. Teardown does not
            // need to rebuild the runtime: release master and let the next
            // compositor establish its own modeset.
            warn!("KMS session was rebased during shutdown; skipping atomic restore");
            drm.pause();
            break;
        }
        if let Some(error) = events.error.take() {
            warn!(
                error,
                "DRM event failed while draining shutdown page flips; skipping atomic restore"
            );
            drm.pause();
            break;
        }
        let Some(output_swapchains) = swapchain.outputs_mut() else {
            warn!("shutdown retirement lost its physical output pools");
            drm.pause();
            return;
        };
        if let Err(error) =
            scheduler.retire_completions_for_shutdown(runtime, output_swapchains, scanouts, events)
        {
            warn!(
                %error,
                "page-flip retirement failed during shutdown; releasing DRM master"
            );
            drm.pause();
            return;
        }
    }

    if release_drm_master && drm.is_active() {
        // Closing a full display-manager session is an ownership handoff,
        // not a temporary KMS experiment. Release the device before Flutter
        // destroys its contexts and buffers; the display manager will
        // establish its own mode when logind activates it.
        // KmsContext::restore_once observes the inactive device and deliberately
        // skips every blocking atomic ioctl.
        drm.pause();
        info!("released DRM master for graphical-session handoff");
    }
}

#[cfg(feature = "flutter")]
fn collect_flutter_output_damage(
    runtime: &mut flutter_runtime::FlutterRuntime,
    scheduler: &mut frame_scheduler::FrameScheduler,
) {
    let updates = runtime.take_output_updates();
    for (output, texture_ids) in &updates {
        scheduler.mark_app_dirty(*output, texture_ids.iter().copied());
    }
    runtime.recycle_output_updates(updates);
}

#[cfg(feature = "flutter")]
fn try_synchronize_flutter_buffers(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) -> Result<bool, Box<dyn Error>> {
    if events.scene_sync.pending_metadata_revision().is_some()
        || events
            .native_app_plugins
            .as_ref()
            .is_some_and(native_app_plugin::NativeAppPluginManager::scene_dirty)
    {
        return Ok(false);
    }

    let Some(buffer_revision) = events.scene_sync.pending_buffer_revision() else {
        return Ok(true);
    };
    let textures = if let Some(frontend) = events.wayland.as_mut() {
        let scene_sync = &events.scene_sync;
        frontend.flutter_dirty_textures(scene_sync.dirty_surface_ids(buffer_revision))
    } else {
        None
    };
    let Some(textures) = textures else {
        return Ok(false);
    };

    let textures = runtime.sync_wayland_buffers(textures)?;
    if let Some(frontend) = events.wayland.as_mut() {
        frontend.recycle_flutter_dirty_textures(textures);
    }
    events.scene_sync.mark_buffers_synchronized(buffer_revision);
    Ok(true)
}

#[cfg(feature = "flutter")]
fn synchronize_flutter_scene(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    let mut metadata_revision = events.scene_sync.pending_metadata_revision();
    let pending_buffer_revision = events.scene_sync.pending_buffer_revision();
    let native_scene_dirty = events
        .native_app_plugins
        .as_ref()
        .is_some_and(native_app_plugin::NativeAppPluginManager::scene_dirty);
    if native_scene_dirty && metadata_revision.is_none() {
        events.scene_sync.mark_dirty();
        metadata_revision = events.scene_sync.pending_metadata_revision();
    }
    if metadata_revision.is_none() && pending_buffer_revision.is_none() && !native_scene_dirty {
        return Ok(());
    }

    if metadata_revision.is_none() && try_synchronize_flutter_buffers(runtime, events)? {
        return Ok(());
    }

    if metadata_revision.is_none() {
        // The surface index changed before this queued source could be
        // resolved. Fall back within the same dispatch and repair both the
        // metadata snapshot and texture registration set.
        events.scene_sync.mark_dirty();
        metadata_revision = events.scene_sync.pending_metadata_revision();
    }

    let revision = metadata_revision.expect("metadata fallback must be pending");
    let buffer_revision = events.scene_sync.buffer_revision();
    // Building the live-ID set walks every toplevel. It is only needed to
    // classify events which arrived before their first renderable buffer;
    // the steady-state scene publication normally has none.
    let live_window_ids = (!events.pending_unpublished_window_events.is_empty()).then(|| {
        events
            .wayland
            .as_ref()
            .map(wayland_frontend::WaylandFrontend::live_toplevel_ids)
            .unwrap_or_default()
    });
    let (mut windows, mut textures) = events
        .wayland
        .as_mut()
        .map(wayland_frontend::WaylandFrontend::flutter_scene)
        .transpose()?
        .unwrap_or_default();
    if let Some(manager) = events.native_app_plugins.as_ref() {
        let (native_windows, native_textures) = manager.scene();
        windows.extend(native_windows);
        textures.extend(native_textures);
    }
    let flutter_runtime::SyncedWaylandScene {
        windows,
        textures,
        window_snapshot_changed,
    } = runtime.sync_wayland_scene(windows, textures, &events.restored_window_ids)?;
    if window_snapshot_changed {
        // Buffer-only revisions leave WireBridge's metadata snapshot equal.
        // Rehash IDs only when that authoritative snapshot actually changes.
        let mut published_window_ids = std::mem::take(&mut events.published_window_ids);
        published_window_ids.clear();
        published_window_ids.extend(runtime.synced_window_ids());
        events.published_window_ids = published_window_ids;
        let published_window_ids = &events.published_window_ids;
        events
            .restored_window_ids
            .retain(|window_id| published_window_ids.contains(window_id));
    }
    if let Some(frontend) = events.wayland.as_mut() {
        frontend.recycle_flutter_scene(windows, textures);
    }
    if let Some(manager) = events.native_app_plugins.as_mut() {
        manager.mark_scene_synchronized();
    }
    // A later Wayland commit has a newer revision, so acknowledging this
    // captured revision cannot erase work that arrived while Flutter/KMS was
    // processing the previous frame.
    events
        .scene_sync
        .mark_metadata_synchronized(revision, buffer_revision);
    if events.pending_unpublished_window_events.is_empty() {
        return Ok(());
    }
    // Events for a freshly mapped window were deferred because Dart could not
    // resolve that ID before this snapshot. Preserve their FIFO order and
    // discard only windows that disappeared before they were ever published.
    let mut unpublished = events.pending_unpublished_window_events.drain_events();
    for event in unpublished.drain(..) {
        match window_event_disposition(
            events.published_window_ids.contains(&event.window_id()),
            live_window_ids
                .as_ref()
                .is_some_and(|window_ids| window_ids.contains(&event.window_id())),
        ) {
            WindowEventDisposition::Send => send_flutter_window_event(runtime, event)?,
            // A newly mapped toplevel can legitimately have no renderable
            // buffer yet. Keep its ordered events until a later commit makes
            // it publishable; discard only IDs that are no longer alive.
            WindowEventDisposition::Retain => {
                events.pending_unpublished_window_events.push(event);
            }
            WindowEventDisposition::Drop => {}
        }
    }
    events
        .pending_unpublished_window_events
        .recycle_drained(unpublished);
    Ok(())
}

#[cfg(feature = "flutter")]
fn synchronize_flutter_input_layout(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    let Some(layout) = runtime.take_input_layout_update() else {
        return Ok(());
    };
    if let Some(manager) = events.native_app_plugins.as_mut()
        && let Err(error) = manager.apply_input_layout(&layout)
    {
        warn!(%error, "could not apply native plugin input visibility");
    }
    let Some(frontend) = events.wayland.as_mut() else {
        runtime.recycle_input_layout(layout);
        return Ok(());
    };
    let (previous, sampling_changed, routing_changed) = frontend.install_input_layout(layout);
    if let Some(previous) = previous {
        runtime.recycle_input_layout(previous);
    }
    if sampling_changed {
        // `expects_sample` is part of the external-texture mailbox contract,
        // not the Dart window metadata. Republish the scene when a window
        // enters or leaves Flutter's sampled set even if no client committed
        // another buffer during the visibility transition.
        events.scene_sync.mark_dirty();
    }
    if routing_changed {
        wayland_frontend::reconcile_flutter_pointer_route(events);
    }
    // InputLayout owns shell keyboard capture. Publish again after applying
    // it so releasing a local Flutter surface exposes an already-active
    // Wayland editor in this iteration instead of waiting for unrelated input.
    publish_software_keyboard_state(runtime, events)
}

#[cfg(feature = "flutter")]
fn synchronize_wayland_cursor(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    if let Some(shape) = runtime.take_mouse_cursor_request()
        && let Some(frontend) = events.wayland.as_mut()
    {
        frontend.request_flutter_cursor_shape(shape);
    }
    let (shape, position) = events.wayland.as_mut().map_or((None, None), |frontend| {
        (
            frontend.take_cursor_shape_update(),
            frontend.take_cursor_position_update(),
        )
    });
    if let Some(shape) = shape {
        runtime.send_cursor_shape(shape)?;
    }
    if let Some((x, y)) = position {
        runtime.send_cursor_position(x, y)?;
    }
    Ok(())
}

#[cfg(feature = "flutter")]
fn synchronize_authentication_boundary(events: &mut RuntimeState) {
    let locked = events
        .authentication
        .as_ref()
        .is_some_and(|authentication| authentication.locked());
    if locked == events.session_lock_applied {
        return;
    }

    // Balance every client-visible press and cancel every active pointer,
    // touch or keyboard grab before changing the routing boundary. On unlock,
    // this also prevents the Enter used for PAM submission from leaking into
    // the previously focused application.
    wayland_frontend::reset_all_input_devices(events);
    events.session_lock_applied = locked;
    if events
        .wayland
        .as_mut()
        .is_some_and(|frontend| frontend.set_input_method_blocked(locked))
    {
        events.scene_sync.mark_dirty();
    }
    if locked {
        events.pending_shell_actions.clear();
    } else if let Some(authentication) = events.authentication.as_ref() {
        authentication.acknowledge_unlocked_boundary();
    }
    // The security boundary changes routing, not Wayland scene metadata. The
    // input-method branch above dirties the scene when blocking it actually
    // changes a visible popup; forcing an unconditional full scene traversal
    // here would put unrelated synchronous work on the first lock/unlock frame.
    info!(locked, "Denial native session security state changed");
}

#[cfg(feature = "flutter")]
fn synchronize_clipboard(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    let locked = events.secure_session_locked();
    events.clipboard.set_locked(locked);
    if locked || !events.clipboard.has_pending_capture() {
        wayland_frontend::cancel_clipboard_captures(events);
    }
    if locked {
        events.clipboard.take_actions();
    } else {
        let actions = events.clipboard.take_actions();
        wayland_frontend::apply_clipboard_actions(events, actions);
    }
    runtime.publish_clipboard_state()
}

#[cfg(feature = "flutter")]
fn synchronize_system_control_events(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    let audio_requests = runtime.drain_audio_requests().collect::<Vec<_>>();
    let brightness_requests = runtime.drain_brightness_requests().collect::<Vec<_>>();
    let Some(controls) = events.system_controls.as_ref() else {
        return Ok(());
    };
    if !events.secure_session_locked() {
        for request in audio_requests {
            controls.handle_audio_request(request);
        }
        for request in brightness_requests {
            controls.handle_brightness_request(request);
        }
    }
    while let Some(event) = controls.try_event() {
        runtime.send_system_control_event(&event)?;
    }
    Ok(())
}

#[cfg(feature = "flutter")]
fn synchronize_notification_events(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    while let Some(event) = events.pending_notification_events.pop_front() {
        runtime.send_notification_event(&event)?;
    }

    let commands = runtime.drain_notification_commands().collect::<Vec<_>>();
    if events.secure_session_locked() {
        return Ok(());
    }
    let Some(server) = events.notification_server.as_ref() else {
        return Ok(());
    };
    for command in commands {
        let (notification_id, queued) = match command {
            wire::NotificationCommand::Dismiss { notification_id } => {
                (notification_id, server.dismiss(notification_id))
            }
            wire::NotificationCommand::InvokeAction {
                notification_id,
                action_key,
            } => (
                notification_id,
                server.invoke_action(notification_id, action_key),
            ),
            wire::NotificationCommand::InvokeDefault { notification_id } => {
                (notification_id, server.invoke_default(notification_id))
            }
        };
        if !queued {
            warn!(
                notification_id,
                "could not queue Flutter notification command"
            );
        }
    }
    Ok(())
}

#[cfg(feature = "flutter")]
fn synchronize_shell_keyboard(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    if let Some((generation, snapshot)) = runtime.take_text_input_state()
        && events
            .wayland
            .as_mut()
            .is_some_and(|frontend| frontend.observe_flutter_text_editor(generation, snapshot))
    {
        events.scene_sync.mark_dirty();
    }

    let input_method_transactions = events
        .wayland
        .as_mut()
        .map(|frontend| {
            frontend
                .drain_flutter_input_method_transactions()
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    if !events.secure_session_locked() {
        for (generation, client_id, transaction) in input_method_transactions {
            if !runtime.dispatch_input_method_to_flutter(generation, client_id, &transaction)? {
                debug!(
                    generation,
                    client_id, "input-method transaction lost its Flutter editor"
                );
            }
        }
    }
    if let Some((generation, snapshot)) = runtime.take_text_input_state()
        && events
            .wayland
            .as_mut()
            .is_some_and(|frontend| frontend.observe_flutter_text_editor(generation, snapshot))
    {
        events.scene_sync.mark_dirty();
    }
    publish_software_keyboard_state(runtime, events)?;
    let commands = runtime.drain_keyboard_commands().collect::<Vec<_>>();
    // The OSK is a virtual keyboard source. Rust converts each intent into
    // complete key transitions and feeds the same focus/XKB/seat-or-Flutter
    // router used by libinput; there is no separate text-delivery path.
    let mut flush_wayland_clients = false;
    for command in commands {
        let delivered = wayland_frontend::dispatch_shell_keyboard(events, &command);
        flush_wayland_clients |= delivered;
        if !delivered {
            warn!(
                ?command,
                "virtual keyboard could not produce this key transition"
            );
        }
    }
    if flush_wayland_clients && let Some(frontend) = events.wayland.as_mut() {
        frontend.display_handle.flush_clients()?;
    }
    Ok(())
}

#[cfg(feature = "flutter")]
fn publish_software_keyboard_state(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &RuntimeState,
) -> Result<(), Box<dyn Error>> {
    let keyboard = events
        .wayland
        .as_ref()
        .map(|frontend| frontend.software_keyboard_state())
        .unwrap_or_default();
    runtime.publish_text_input_state(
        keyboard.active,
        keyboard.input_panel_visible,
        keyboard.legacy,
        keyboard.content_hint,
        keyboard.content_purpose,
        keyboard.activation_serial,
    )
}

#[cfg(feature = "flutter")]
fn synchronize_flutter_window_management(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    if events.secure_session_locked() {
        events.pending_shell_actions.clear();
        events.pending_shortcut_launches.clear();
        while runtime.take_application_launch().is_some() {}
        runtime.drain_window_commands().for_each(drop);
    } else {
        while let Some(target) = events.pending_shortcut_launches.pop_front() {
            let activation_token = events
                .wayland
                .as_mut()
                .map(wayland_frontend::WaylandFrontend::create_launch_activation_token);
            let result = match target {
                native_shortcut::ShortcutTarget::Spawn { command } => {
                    runtime.start_shortcut_application(command, false, activation_token.as_deref())
                }
                native_shortcut::ShortcutTarget::SpawnSh { command } => runtime
                    .start_shortcut_application(
                        vec!["sh".to_owned(), "-c".to_owned(), command],
                        true,
                        activation_token.as_deref(),
                    ),
                native_shortcut::ShortcutTarget::DenialAction { .. } => continue,
            };
            if let Err(error) = result {
                warn!(%error, "could not launch command requested by shortcut");
            }
        }
        while let Some(launch) = runtime.take_application_launch() {
            let activation_token = events
                .wayland
                .as_mut()
                .map(wayland_frontend::WaylandFrontend::create_launch_activation_token);
            if let Err(error) = runtime.start_application(launch, activation_token.as_deref()) {
                warn!(%error, "could not launch application requested by Flutter shell");
            }
        }
        while let Some((action, monitor_id)) = events.pending_shell_actions.pop_front() {
            runtime.send_shell_action(action, monitor_id)?;
        }
        let commands = runtime.drain_window_commands().collect::<Vec<_>>();
        let mut wayland_commands = Vec::with_capacity(commands.len());
        for command in commands {
            let native_owned = command.window_id().is_some_and(|window_id| {
                events
                    .native_app_plugins
                    .as_ref()
                    .is_some_and(|manager| manager.owns_window(window_id))
            });
            if native_owned {
                if let Some(manager) = events.native_app_plugins.as_mut()
                    && let Err(error) = manager.apply_window_command(&command)
                {
                    warn!(%error, "native application plugin window command failed");
                }
            } else {
                if matches!(command, wire::WindowCommand::Focus { .. })
                    && let Some(manager) = events.native_app_plugins.as_mut()
                    && let Err(error) = manager.clear_focus()
                {
                    warn!(%error, "could not clear native application focus");
                }
                wayland_commands.push(command);
            }
        }
        wayland_frontend::apply_window_commands(events, wayland_commands);
    }
    if events.pending_window_events.is_empty() {
        return Ok(());
    }
    let mut pending = events.pending_window_events.drain_events();
    for event in pending.drain(..) {
        if event.is_activation() {
            // Native focus is last-writer-wins. An activation waiting for an
            // older, bufferless window must not fire after focus moved away.
            events
                .pending_unpublished_window_events
                .remove_activations();
        }
        if events.published_window_ids.contains(&event.window_id()) {
            send_flutter_window_event(runtime, event)?;
        } else {
            events.pending_unpublished_window_events.push(event);
        }
    }
    events.pending_window_events.recycle_drained(pending);
    Ok(())
}

#[cfg(feature = "flutter")]
fn synchronize_settings(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    let commands = runtime.drain_settings_commands().collect::<Vec<_>>();
    for command in commands {
        match command {
            wire::SettingsCommand::ReadDocument { request_id } => {
                let (revision, document) = {
                    let settings = &events
                        .wayland
                        .as_ref()
                        .ok_or("settings request has no Wayland frontend")?
                        .settings;
                    (settings.revision(), settings.document_json())
                };
                match document {
                    Ok(document) => runtime.send_settings_document_response(
                        request_id,
                        revision,
                        Some(&document),
                        None,
                    )?,
                    Err(error) => runtime.send_settings_document_response(
                        request_id,
                        revision,
                        None,
                        Some(&error.to_string()),
                    )?,
                }
            }
            wire::SettingsCommand::WriteDocument {
                request_id,
                expected_revision,
                document,
            } => {
                let result = {
                    let frontend = events
                        .wayland
                        .as_mut()
                        .ok_or("settings request has no Wayland frontend")?;
                    frontend
                        .settings
                        .prepare_shell_update(expected_revision, &document)
                        .and_then(|prepared| frontend.settings.commit(prepared))
                };
                let (revision, document) = {
                    let frontend = events.wayland.as_mut().expect("missing Wayland frontend");
                    if result.is_ok() {
                        // The native-owned values are unchanged, but their
                        // revision token advanced with the shared document.
                        frontend.keyboard_configuration_changed = true;
                    }
                    (
                        frontend.settings.revision(),
                        result
                            .as_ref()
                            .ok()
                            .and_then(|()| frontend.settings.document_json().ok()),
                    )
                };
                runtime.send_settings_document_response(
                    request_id,
                    revision,
                    document.as_deref(),
                    result
                        .as_ref()
                        .err()
                        .map(|error| error.to_string())
                        .as_deref(),
                )?;
                if result.is_ok() {
                    events.input_device_capabilities_changed = true;
                }
            }
            wire::SettingsCommand::ReadKeyboard { request_id } => {
                send_keyboard_settings(runtime, events, request_id, None)?;
                if let Some(frontend) = events.wayland.as_mut() {
                    frontend.keyboard_configuration_changed = false;
                }
            }
            wire::SettingsCommand::ReadInputDevices { request_id } => {
                send_input_device_settings(runtime, events, request_id, None)?;
                events.input_device_capabilities_changed = false;
            }
            wire::SettingsCommand::ConfigureKeyboard {
                request_id,
                expected_revision,
                keyboard,
            } => {
                let prepared = events
                    .wayland
                    .as_ref()
                    .ok_or("settings request has no Wayland frontend")?
                    .settings
                    .prepare_keyboard_update(expected_revision, keyboard);
                let result = match prepared {
                    Ok(prepared) => {
                        let previous = events
                            .wayland
                            .as_ref()
                            .expect("missing Wayland frontend")
                            .settings
                            .keyboard()
                            .clone();
                        let next = prepared.keyboard().clone();
                        match wayland_frontend::install_keyboard_settings(events, &next) {
                            Ok(_) => {
                                let commit = events
                                    .wayland
                                    .as_mut()
                                    .expect("missing Wayland frontend")
                                    .settings
                                    .commit(prepared);
                                if let Err(error) = commit {
                                    if let Err(rollback_error) =
                                        wayland_frontend::install_keyboard_settings(
                                            events, &previous,
                                        )
                                    {
                                        return Err(format!(
                                            "keyboard settings commit failed ({error}) and the live keymap rollback failed ({rollback_error})"
                                        )
                                        .into());
                                    }
                                    Err(error)
                                } else {
                                    info!(
                                        revision = events
                                            .wayland
                                            .as_ref()
                                            .expect("missing Wayland frontend")
                                            .settings
                                            .revision(),
                                        layouts = next.layouts.len(),
                                        repeat_rate_hz = next.repeat_rate_hz,
                                        repeat_delay_ms = next.repeat_delay_ms,
                                        "applied persistent keyboard settings"
                                    );
                                    Ok(())
                                }
                            }
                            Err(error) => {
                                warn!(%error, "rejected keyboard configuration after XKB preflight");
                                // Convert the late Smithay error into the same
                                // bounded user-facing response as persistence
                                // failures.
                                send_keyboard_settings(
                                    runtime,
                                    events,
                                    request_id,
                                    Some(&error.to_string()),
                                )?;
                                continue;
                            }
                        }
                    }
                    Err(error) => Err(error),
                };
                send_keyboard_settings(
                    runtime,
                    events,
                    request_id,
                    result
                        .as_ref()
                        .err()
                        .map(|error| error.to_string())
                        .as_deref(),
                )?;
                if result.is_ok() {
                    events.input_device_capabilities_changed = true;
                }
            }
            wire::SettingsCommand::ConfigureTouchpad {
                request_id,
                expected_revision,
                touchpad,
            } => {
                let prepared = events
                    .wayland
                    .as_ref()
                    .ok_or("touchpad update has no Wayland frontend")?
                    .settings
                    .prepare_touchpad_update(expected_revision, touchpad);
                let result = match prepared {
                    Ok(prepared) => {
                        let previous = events
                            .wayland
                            .as_ref()
                            .expect("missing Wayland frontend")
                            .settings
                            .touchpad()
                            .clone();
                        let next = prepared.touchpad().clone();
                        match wayland_frontend::install_touchpad_settings(events, &next) {
                            Ok(()) => {
                                let commit = events
                                    .wayland
                                    .as_mut()
                                    .expect("missing Wayland frontend")
                                    .settings
                                    .commit(prepared);
                                if let Err(error) = commit {
                                    if let Err(rollback_error) =
                                        wayland_frontend::install_touchpad_settings(
                                            events, &previous,
                                        )
                                    {
                                        return Err(format!(
                                            "touchpad settings commit failed ({error}) and the live configuration rollback failed ({rollback_error})"
                                        )
                                        .into());
                                    }
                                    Err(error)
                                } else {
                                    info!(
                                        revision = events
                                            .wayland
                                            .as_ref()
                                            .expect("missing Wayland frontend")
                                            .settings
                                            .revision(),
                                        tap_to_click = next.tap_to_click_enabled,
                                        natural_scroll = next.natural_scroll_enabled,
                                        scroll_speed_factor = next.scroll_speed_factor,
                                        "applied persistent touchpad settings"
                                    );
                                    Ok(())
                                }
                            }
                            Err(error) => {
                                if let Err(rollback_error) =
                                    wayland_frontend::install_touchpad_settings(events, &previous)
                                {
                                    return Err(format!(
                                        "touchpad configuration failed ({error}) and the live configuration rollback failed ({rollback_error})"
                                    )
                                    .into());
                                }
                                send_input_device_settings(
                                    runtime,
                                    events,
                                    request_id,
                                    Some(&error),
                                )?;
                                continue;
                            }
                        }
                    }
                    Err(error) => Err(error),
                };
                send_input_device_settings(
                    runtime,
                    events,
                    request_id,
                    result
                        .as_ref()
                        .err()
                        .map(|error| error.to_string())
                        .as_deref(),
                )?;
                if result.is_ok()
                    && let Some(frontend) = events.wayland.as_mut()
                {
                    frontend.keyboard_configuration_changed = true;
                }
            }
            wire::SettingsCommand::ReadShortcuts { request_id } => {
                send_shortcut_settings(runtime, events, request_id, None)?;
            }
            wire::SettingsCommand::ValidateShortcut {
                request_id,
                shortcut,
                existing_shortcut,
            } => {
                let (revision, validation) = {
                    let manager = &events
                        .wayland
                        .as_ref()
                        .ok_or("shortcut validation has no Wayland frontend")?
                        .shortcuts;
                    (
                        manager.revision(),
                        manager.validate_shortcut(&shortcut, existing_shortcut.as_deref()),
                    )
                };
                runtime.send_shortcut_validation_response(request_id, revision, &validation)?;
            }
            wire::SettingsCommand::AddShortcut {
                request_id,
                expected_revision,
                shortcut,
            } => {
                let prepared = events
                    .wayland
                    .as_ref()
                    .ok_or("shortcut update has no Wayland frontend")?
                    .shortcuts
                    .prepare_add(expected_revision, shortcut);
                apply_shortcut_update(runtime, events, request_id, prepared)?;
            }
            wire::SettingsCommand::UpdateShortcut {
                request_id,
                expected_revision,
                existing_shortcut,
                shortcut,
            } => {
                let prepared = events
                    .wayland
                    .as_ref()
                    .ok_or("shortcut update has no Wayland frontend")?
                    .shortcuts
                    .prepare_update(expected_revision, &existing_shortcut, shortcut);
                apply_shortcut_update(runtime, events, request_id, prepared)?;
            }
            wire::SettingsCommand::RemoveShortcut {
                request_id,
                expected_revision,
                shortcut,
            } => {
                let prepared = events
                    .wayland
                    .as_ref()
                    .ok_or("shortcut removal has no Wayland frontend")?
                    .shortcuts
                    .prepare_remove(expected_revision, &shortcut);
                apply_shortcut_update(runtime, events, request_id, prepared)?;
            }
            wire::SettingsCommand::RestoreShortcuts {
                request_id,
                expected_revision,
            } => {
                let prepared = events
                    .wayland
                    .as_ref()
                    .ok_or("shortcut restore has no Wayland frontend")?
                    .shortcuts
                    .prepare_restore(expected_revision);
                apply_shortcut_update(runtime, events, request_id, prepared)?;
            }
        }
    }

    let changed = events
        .wayland
        .as_mut()
        .is_some_and(|frontend| std::mem::take(&mut frontend.keyboard_configuration_changed));
    if changed {
        send_keyboard_settings(runtime, events, 0, None)?;
    }
    if std::mem::take(&mut events.input_device_capabilities_changed) {
        send_input_device_settings(runtime, events, 0, None)?;
    }
    Ok(())
}

#[cfg(feature = "flutter")]
fn apply_shortcut_update(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
    request_id: u64,
    prepared: Result<native_shortcut::PreparedShortcutUpdate, native_shortcut::ShortcutError>,
) -> Result<(), Box<dyn Error>> {
    let result = match prepared {
        Ok(mut prepared) => {
            let candidate_engine = prepared.take_engine();
            let previous_engine =
                std::mem::replace(&mut events.native_escape_shortcut, candidate_engine);
            let result = events
                .wayland
                .as_mut()
                .ok_or("shortcut commit has no Wayland frontend")?
                .shortcuts
                .commit(prepared);
            if result.is_err() {
                events.native_escape_shortcut = previous_engine;
            } else {
                info!(
                    revision = events
                        .wayland
                        .as_ref()
                        .expect("missing Wayland frontend")
                        .shortcuts
                        .revision(),
                    "applied persistent shortcut configuration"
                );
            }
            result
        }
        Err(error) => Err(error),
    };
    send_shortcut_settings(
        runtime,
        events,
        request_id,
        result
            .as_ref()
            .err()
            .map(|error| error.to_string())
            .as_deref(),
    )
}

#[cfg(feature = "flutter")]
fn send_shortcut_settings(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &RuntimeState,
    request_id: u64,
    error: Option<&str>,
) -> Result<(), Box<dyn Error>> {
    let manager = &events
        .wayland
        .as_ref()
        .ok_or("shortcut response has no Wayland frontend")?
        .shortcuts;
    let supported_inputs = native_shortcut::supported_inputs();
    runtime.send_shortcut_configuration_response(
        request_id,
        manager.revision(),
        &manager.file().shortcuts,
        &supported_inputs,
        error,
    )
}

#[cfg(feature = "flutter")]
fn send_keyboard_settings(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &RuntimeState,
    request_id: u64,
    error: Option<&str>,
) -> Result<(), Box<dyn Error>> {
    let frontend = events
        .wayland
        .as_ref()
        .ok_or("keyboard settings response has no Wayland frontend")?;
    runtime.send_keyboard_settings_response(
        request_id,
        frontend.settings.revision(),
        frontend.settings.keyboard(),
        &frontend.keyboard_layout_names,
        frontend.active_keyboard_layout,
        error,
    )
}

#[cfg(feature = "flutter")]
fn send_input_device_settings(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &RuntimeState,
    request_id: u64,
    error: Option<&str>,
) -> Result<(), Box<dyn Error>> {
    let frontend = events
        .wayland
        .as_ref()
        .ok_or("touchpad settings response has no Wayland frontend")?;
    runtime.send_input_device_capabilities_response(
        request_id,
        frontend.settings.revision(),
        !events.touchpad_devices.is_empty(),
        frontend.settings.touchpad(),
        error,
    )
}

#[cfg(feature = "flutter")]
fn synchronize_system_bar_configuration(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
    flutter_launcher: Option<&mut FlutterLauncher>,
) {
    let Some(work_area) = runtime.take_work_area_update() else {
        return;
    };
    if let Some(frontend) = events.wayland.as_mut() {
        frontend.set_work_area(work_area.clone());
    }
    if let Some(launcher) = flutter_launcher {
        launcher.set_work_area(work_area);
    }
    events.scene_sync.mark_dirty();
}

#[cfg(feature = "flutter")]
fn send_flutter_window_event(
    runtime: &mut flutter_runtime::FlutterRuntime,
    event: PendingWindowEvent,
) -> Result<(), Box<dyn Error>> {
    match event {
        PendingWindowEvent::Activated(window_id) => runtime.send_window_activated(window_id),
        PendingWindowEvent::Action(window_id, action) => {
            runtime.send_window_action(window_id, action)
        }
        PendingWindowEvent::Placement(placement) => runtime.send_window_placement(placement),
    }
}

#[cfg(feature = "flutter")]
fn apply_automatic_orientation(
    scanouts: &mut [Scanout],
    swapchain: &mut RenderSwapchains,
    topology: &mut TopologyManager,
    configuration: &mut RuntimeOutputConfiguration,
    rotation: OutputTransform,
    events: &mut RuntimeState,
    flutter: &mut flutter_runtime::FlutterRuntime,
) -> Result<(), Box<dyn Error>> {
    let mut staged_configuration = configuration.clone();
    staged_configuration.sensor_rotation = rotation;
    let outputs = scanouts
        .iter()
        .map(|scanout| {
            let mut output = scanout.output.clone();
            output.transform = staged_configuration.effective_transform(&output.name);
            output
        })
        .collect::<Vec<_>>();
    if outputs
        .iter()
        .zip(scanouts.iter())
        .all(|(output, scanout)| output.transform == scanout.output.transform)
    {
        configuration.sensor_rotation = rotation;
        return Ok(());
    }

    apply_resident_output_geometry(
        scanouts,
        swapchain,
        topology,
        configuration,
        outputs,
        staged_configuration,
        flutter_runtime::OutputGeometryTransition::AnimatedRotation,
        events,
        flutter,
    )?;
    info!(
        ?rotation,
        "applied automatic orientation to resident Flutter output pools"
    );
    Ok(())
}

#[cfg(feature = "flutter")]
#[allow(clippy::too_many_arguments)]
fn apply_resident_output_geometry(
    scanouts: &mut [Scanout],
    swapchain: &mut RenderSwapchains,
    topology: &mut TopologyManager,
    configuration: &mut RuntimeOutputConfiguration,
    outputs: Vec<ConnectedOutput>,
    staged_configuration: RuntimeOutputConfiguration,
    transition: flutter_runtime::OutputGeometryTransition,
    events: &mut RuntimeState,
    flutter: &mut flutter_runtime::FlutterRuntime,
) -> Result<(), Box<dyn Error>> {
    let previous_snapshot = topology.snapshot();
    let previous_atlas = AtlasPlan::for_snapshot(&previous_snapshot)
        .ok_or("resident output rollback has no previous Flutter desktop geometry")?;
    let mut staged_topology = topology.clone();
    let snapshot =
        update_topology_for_outputs(&mut staged_topology, &outputs, &staged_configuration)?;
    let atlas = AtlasPlan::for_snapshot(&snapshot)
        .ok_or("resident reconfiguration produced no Flutter desktop geometry")?;
    let plans = atlas
        .render_outputs(&snapshot)
        .ok_or("resident reconfiguration produced invalid render projections")?;
    let pools = swapchain
        .outputs()
        .ok_or("resident reconfiguration has no physical Flutter output pools")?;
    if plans.len() != pools.outputs.len()
        || plans.iter().any(|plan| {
            pools
                .for_output(plan.output_id)
                .is_none_or(|pool| pool.size != plan.target_size)
        })
    {
        return Err("resident reconfiguration changed a native output target".into());
    }
    let staged_scanouts = scanouts
        .iter()
        .map(|scanout| {
            let output = outputs
                .iter()
                .find(|output| output.id == scanout.output.id)
                .cloned()
                .ok_or("resident reconfiguration omitted a scanout")?;
            let source_rect = atlas
                .outputs
                .iter()
                .find(|planned| planned.id == output.id)
                .map(|planned| planned.source_rect)
                .ok_or("resident reconfiguration omitted an atlas output")?;
            Ok((output, source_rect))
        })
        .collect::<Result<Vec<_>, Box<dyn Error>>>()?;

    if let Some(frontend) = events.wayland.as_mut()
        && let Err(error) = frontend.update_topology(&snapshot)
    {
        if let Err(rollback_error) = frontend.update_topology(&previous_snapshot) {
            return Err(format!(
                "resident Wayland geometry update failed ({error}); rollback failed: {rollback_error}"
            )
            .into());
        }
        return Err(error);
    }
    if let Err(error) = flutter.reconfigure_output_geometry(&snapshot, &atlas, transition) {
        let flutter_rollback = flutter.reconfigure_output_geometry(
            &previous_snapshot,
            &previous_atlas,
            flutter_runtime::OutputGeometryTransition::Immediate,
        );
        let wayland_rollback = events
            .wayland
            .as_mut()
            .map(|frontend| frontend.update_topology(&previous_snapshot))
            .transpose();
        if let Err(rollback_error) = flutter_rollback {
            return Err(format!(
                "resident Flutter geometry update failed ({error}); Flutter rollback failed: {rollback_error}"
            )
            .into());
        }
        if let Err(rollback_error) = wayland_rollback {
            return Err(format!(
                "resident Flutter geometry update failed ({error}); Wayland rollback failed: {rollback_error}"
            )
            .into());
        }
        return Err(error);
    }

    for (scanout, (output, source_rect)) in scanouts.iter_mut().zip(staged_scanouts) {
        scanout.output = output;
        scanout.source_rect = source_rect;
    }
    swapchain.set_desktop_size(atlas.pixel_size)?;
    let animation_started = flutter.output_rotation_animation_active();
    if !animation_started {
        synchronize_resident_flutter_geometry_state(events, &atlas);
    }
    events.output_control_dirty = true;
    *topology = staged_topology;
    *configuration = staged_configuration;
    info!(
        outputs = scanouts.len(),
        width = atlas.pixel_size.width,
        height = atlas.pixel_size.height,
        topology_epoch = atlas.topology_epoch,
        animated = animation_started,
        "updated Flutter output geometry without reallocating native buffers"
    );
    Ok(())
}

#[cfg(feature = "flutter")]
fn synchronize_resident_flutter_geometry_state(events: &mut RuntimeState, atlas: &AtlasPlan) {
    events
        .flutter_input
        .resize_preserving_state(atlas.pixel_size);
    events.native_plugin_default_size = (atlas.pixel_size.width, atlas.pixel_size.height);
    events.synchronize_flutter_pointer_position();
    events.scene_sync.mark_dirty();
}

#[allow(clippy::too_many_arguments)]
fn apply_hotplug_topology(
    renderer: &mut GlesRenderer,
    allocator: &mut ScanoutAllocator,
    drm: &mut DrmDevice,
    swapchain: &mut RenderSwapchains,
    scanouts: &mut Vec<Scanout>,
    restore_state: &mut RestoreState,
    topology: &mut TopologyManager,
    outputs: Vec<ConnectedOutput>,
    configuration: &RuntimeOutputConfiguration,
    frame_number: u64,
    event_loop: &mut EventLoop<'_, RuntimeState>,
    events: &mut RuntimeState,
    #[cfg(feature = "flutter")] flutter: &mut Option<flutter_runtime::FlutterRuntime>,
    #[cfg(feature = "flutter")] mut flutter_launcher: Option<&mut FlutterLauncher>,
) -> Result<(), Box<dyn Error>> {
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
fn ticker_refresh_millihz(snapshot: &TopologySnapshot) -> Result<u32, Box<dyn Error>> {
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

fn reconcile_scanouts<'a>(
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

fn scanout_rollback_framebuffers(
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

fn rollback_hotplug_scanouts(
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

fn hotplug_transaction_error(cause: String, rollback_failures: Vec<String>) -> Box<dyn Error> {
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

fn wait_for_page_flips(
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

fn source_rects_for_atlas(
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

fn restore_source_rects(scanouts: &mut [Scanout], source_rects: &[PixelRect]) {
    for (scanout, source_rect) in scanouts.iter_mut().zip(source_rects) {
        scanout.source_rect = *source_rect;
    }
}

fn queue_atlas_page_flip(
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

fn test_atlas_page_flip(
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

fn atlas_plane_request(
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

fn connected_outputs(
    scanner: &mut DrmScanner<SimpleCrtcMapper>,
    drm: &DrmDevice,
    max_outputs: usize,
    configuration: &RuntimeOutputConfiguration,
) -> Result<Vec<ConnectedOutput>, Box<dyn Error>> {
    let connected = scan_connected_connectors(scanner, drm)?;
    configured_outputs(connected, max_outputs, configuration)
}

fn scan_connected_connectors(
    scanner: &mut DrmScanner<SimpleCrtcMapper>,
    drm: &DrmDevice,
) -> Result<Vec<ConnectedConnector>, Box<dyn Error>> {
    let scan = scanner.scan_connectors(drm)?;
    for event in scan.iter() {
        match event {
            DrmScanEvent::Connected { connector, crtc } => info!(
                connector = %format!("{}-{}", connector.interface().as_str(), connector.interface_id()),
                ?crtc,
                "DRM connector added"
            ),
            DrmScanEvent::Disconnected { connector, crtc } => info!(
                connector = %format!("{}-{}", connector.interface().as_str(), connector.interface_id()),
                ?crtc,
                "DRM connector removed"
            ),
            DrmScanEvent::Changed { connector, crtc } => info!(
                connector = %format!("{}-{}", connector.interface().as_str(), connector.interface_id()),
                ?crtc,
                "DRM connector modes changed"
            ),
        }
    }
    Ok(current_connected_connectors(scanner))
}

fn current_connected_connectors(scanner: &DrmScanner<SimpleCrtcMapper>) -> Vec<ConnectedConnector> {
    let mut connected = scanner
        .crtcs()
        .filter(|(connector, _)| connector.state() == connector::State::Connected)
        .map(|(connector, crtc)| ConnectedConnector {
            info: connector.clone(),
            crtc,
        })
        .collect::<Vec<_>>();

    connected.sort_by_key(|connector| {
        (
            connector.info.interface().as_str().to_owned(),
            connector.info.interface_id(),
        )
    });
    connected
}

fn configured_outputs(
    mut connected: Vec<ConnectedConnector>,
    max_outputs: usize,
    configuration: &RuntimeOutputConfiguration,
) -> Result<Vec<ConnectedOutput>, Box<dyn Error>> {
    connected.retain(|connector| {
        let name = format!(
            "{}-{}",
            connector.info.interface().as_str(),
            connector.info.interface_id()
        );
        if configuration.disabled_outputs.contains(&name) {
            info!(output = name, "ignoring disabled KMS output");
            false
        } else {
            true
        }
    });
    connected.truncate(max_outputs);

    connected
        .into_iter()
        .map(|connector| {
            let name = format!(
                "{}-{}",
                connector.info.interface().as_str(),
                connector.info.interface_id()
            );
            let vrr_enabled = configuration.vrr_outputs.contains(&name);
            let mode_preference = configuration.modes.get(&name).copied();
            let mode = select_output_mode(&connector.info, mode_preference).ok_or_else(|| {
                mode_preference.map_or_else(
                    || format!("{name} has no usable native mode"),
                    |preference| {
                        let size = preference.width.zip(preference.height).map_or_else(
                            || "native resolution".to_owned(),
                            |(width, height)| format!("{width}x{height}"),
                        );
                        let refresh = preference.refresh_millihz.map_or_else(
                            || "the highest available refresh".to_owned(),
                            |refresh| format!("{} mHz", refresh),
                        );
                        format!("{name} has no mode compatible with {size} at {refresh}")
                    },
                )
            })?;
            let output_mode: OutputMode = mode.into();
            let configured_refresh_millihz =
                mode_preference.and_then(|preference| preference.refresh_millihz);
            if let (Some(configured), Ok(selected)) = (
                configured_refresh_millihz,
                u32::try_from(output_mode.refresh),
            ) && selected.abs_diff(configured) > REFRESH_FALLBACK_WARNING_MILLIHERTZ
            {
                warn!(
                    output = name,
                    requested_refresh_millihz = configured,
                    selected_refresh_millihz = selected,
                    "requested refresh is unavailable; using the closest mode"
                );
            }
            info!(
                output = name,
                crtc = ?connector.crtc,
                width = output_mode.size.w,
                height = output_mode.size.h,
                refresh_millihz = output_mode.refresh,
                configured_refresh_millihz,
                vrr_enabled,
                "connected KMS output"
            );
            let transform = configuration.effective_transform(&name);
            Ok(ConnectedOutput {
                id: OutputId(u64::from(u32::from(connector.info.handle()))),
                name,
                connector: connector.info.handle(),
                crtc: connector.crtc,
                mode,
                transform,
                vrr_enabled,
            })
        })
        .collect()
}

#[cfg(feature = "flutter")]
fn output_control_state(
    scanner: &DrmScanner<SimpleCrtcMapper>,
    scanouts: &[Scanout],
    topology: &TopologyManager,
    configuration: &RuntimeOutputConfiguration,
    persistence_available: bool,
    pending_confirmation: Option<output_control::OutputControlConfirmation>,
) -> Result<output_control::OutputControlState, Box<dyn Error>> {
    let snapshot = topology.snapshot();
    let mut outputs = Vec::new();
    for connector in current_connected_connectors(scanner) {
        let name = format!(
            "{}-{}",
            connector.info.interface().as_str(),
            connector.info.interface_id()
        );
        let id = OutputId(u64::from(u32::from(connector.info.handle())));
        let scanout = scanouts.iter().find(|scanout| scanout.output.id == id);
        let spec = snapshot.outputs.iter().find(|output| output.id == id);
        let enabled = scanout.is_some();
        let scale_120 = spec
            .map(|output| output.scale_120)
            .or_else(|| configuration.scales_120.get(&name).copied())
            .unwrap_or(SCALE_BASE);
        let transform = spec
            .map(|output| output.transform)
            .unwrap_or_else(|| configuration.effective_transform(&name));
        let position = spec
            .map(|output| output.position)
            .or_else(|| configuration.positions.get(&name).copied())
            .unwrap_or(LogicalPoint::new(0, 0));
        let modes = output_control_modes(&connector.info);
        let current_mode =
            scanout.and_then(|scanout| output_control_mode(&connector.info, scanout.output.mode));
        let fallback_mode = current_mode.or_else(|| {
            select_output_mode(&connector.info, configuration.modes.get(&name).copied())
                .and_then(|mode| output_control_mode(&connector.info, mode))
                .or_else(|| modes.first().copied())
        });
        let (logical_width, logical_height) = fallback_mode.map_or((0, 0), |mode| {
            logical_size_for_control(mode, scale_120, transform)
        });
        let (physical_width_mm, physical_height_mm) = connector
            .info
            .size()
            .map_or((None, None), |(width, height)| (Some(width), Some(height)));

        outputs.push(output_control::OutputControlOutput {
            name: name.clone(),
            description: name.clone(),
            connected: true,
            enabled,
            powered: scanout.is_some_and(|scanout| scanout.powered),
            x: position.x,
            y: position.y,
            logical_width,
            logical_height,
            physical_width_mm,
            physical_height_mm,
            scale: f64::from(scale_120) / f64::from(SCALE_BASE),
            transform: output_transform_name(transform),
            adaptive_sync: scanout
                .map(|scanout| scanout.output.vrr_enabled)
                .unwrap_or_else(|| configuration.vrr_outputs.contains(&name)),
            current_mode,
            modes,
        });
    }
    let capabilities = output_control::OutputControlCapabilities {
        persistent: persistence_available,
        ..Default::default()
    };
    Ok(output_control::OutputControlState {
        capabilities,
        outputs,
        pending_confirmation,
    })
}

#[cfg(feature = "flutter")]
fn output_control_modes(connector: &connector::Info) -> Vec<output_control::OutputControlMode> {
    let mut modes = BTreeMap::new();
    for mode in connector.modes() {
        let output_mode: OutputMode = (*mode).into();
        let Ok(width) = u32::try_from(output_mode.size.w) else {
            continue;
        };
        let Ok(height) = u32::try_from(output_mode.size.h) else {
            continue;
        };
        let Ok(refresh_millihz) = u32::try_from(output_mode.refresh) else {
            continue;
        };
        let preferred = mode.mode_type().contains(ModeTypeFlags::PREFERRED);
        modes
            .entry((width, height, refresh_millihz))
            .and_modify(|existing| *existing |= preferred)
            .or_insert(preferred);
    }
    let mut modes = modes
        .into_iter()
        .map(
            |((width, height, refresh_millihz), preferred)| output_control::OutputControlMode {
                width,
                height,
                refresh_millihz,
                preferred,
            },
        )
        .collect::<Vec<_>>();
    modes.sort_by_key(|mode| {
        (
            std::cmp::Reverse(mode.preferred),
            std::cmp::Reverse(u64::from(mode.width) * u64::from(mode.height)),
            std::cmp::Reverse(mode.refresh_millihz),
        )
    });
    modes
}

#[cfg(feature = "flutter")]
fn output_control_mode(
    connector: &connector::Info,
    mode: Mode,
) -> Option<output_control::OutputControlMode> {
    let output_mode: OutputMode = mode.into();
    Some(output_control::OutputControlMode {
        width: u32::try_from(output_mode.size.w).ok()?,
        height: u32::try_from(output_mode.size.h).ok()?,
        refresh_millihz: u32::try_from(output_mode.refresh).ok()?,
        preferred: connector.modes().iter().any(|candidate| {
            candidate.size() == mode.size()
                && OutputMode::from(*candidate).refresh == output_mode.refresh
                && candidate.mode_type().contains(ModeTypeFlags::PREFERRED)
        }),
    })
}

#[cfg(feature = "flutter")]
fn logical_size_for_control(
    mode: output_control::OutputControlMode,
    scale_120: u32,
    transform: OutputTransform,
) -> (u32, u32) {
    if scale_120 == 0 {
        return (0, 0);
    }
    let (width, height) = if transform.swaps_axes() {
        (mode.height, mode.width)
    } else {
        (mode.width, mode.height)
    };
    let scaled = |value: u32| {
        let numerator = u64::from(value) * u64::from(SCALE_BASE);
        u32::try_from((numerator + u64::from(scale_120) / 2) / u64::from(scale_120))
            .unwrap_or(u32::MAX)
    };
    (scaled(width), scaled(height))
}

#[cfg(feature = "flutter")]
fn output_transform_name(transform: OutputTransform) -> output_control::OutputTransformName {
    match transform {
        OutputTransform::Normal => output_control::OutputTransformName::Normal,
        OutputTransform::Rotate90 => output_control::OutputTransformName::Rotate90,
        OutputTransform::Rotate180 => output_control::OutputTransformName::Rotate180,
        OutputTransform::Rotate270 => output_control::OutputTransformName::Rotate270,
        OutputTransform::Flipped => output_control::OutputTransformName::Flipped,
        OutputTransform::Flipped90 => output_control::OutputTransformName::Flipped90,
        OutputTransform::Flipped180 => output_control::OutputTransformName::Flipped180,
        OutputTransform::Flipped270 => output_control::OutputTransformName::Flipped270,
    }
}

#[cfg(feature = "flutter")]
fn output_transform_from_name(transform: output_control::OutputTransformName) -> OutputTransform {
    match transform {
        output_control::OutputTransformName::Normal => OutputTransform::Normal,
        output_control::OutputTransformName::Rotate90 => OutputTransform::Rotate90,
        output_control::OutputTransformName::Rotate180 => OutputTransform::Rotate180,
        output_control::OutputTransformName::Rotate270 => OutputTransform::Rotate270,
        output_control::OutputTransformName::Flipped => OutputTransform::Flipped,
        output_control::OutputTransformName::Flipped90 => OutputTransform::Flipped90,
        output_control::OutputTransformName::Flipped180 => OutputTransform::Flipped180,
        output_control::OutputTransformName::Flipped270 => OutputTransform::Flipped270,
    }
}

#[cfg(feature = "flutter")]
fn output_request_changes_only_transforms(
    current: &[output_control::OutputControlOutput],
    requested: &[output_control::RequestedOutput],
) -> bool {
    if current.len() != requested.len() {
        return false;
    }

    let mut transform_changed = false;
    for requested in requested {
        let Some(current) = current
            .iter()
            .find(|current| current.name == requested.name)
        else {
            return false;
        };
        let Some(mode) = current.current_mode else {
            return false;
        };
        if current.enabled != requested.enabled
            || current.powered != requested.powered
            || current.x != requested.x
            || current.y != requested.y
            || mode.width != requested.mode.width
            || mode.height != requested.mode.height
            || mode.refresh_millihz != requested.mode.refresh_millihz
            || current.scale != requested.scale
            || current.adaptive_sync != requested.adaptive_sync
        {
            return false;
        }
        transform_changed |= current.transform != requested.transform;
    }
    transform_changed
}

#[cfg(feature = "flutter")]
fn configuration_from_output_request(
    request: &output_control::ApplyOutputConfiguration,
    connectors: &[ConnectedConnector],
    max_outputs: usize,
    current: &RuntimeOutputConfiguration,
    persistence_available: bool,
) -> Result<
    (RuntimeOutputConfiguration, BTreeMap<OutputId, bool>),
    output_control::OutputControlFailure,
> {
    const MIN_SCALE: f64 = 0.25;
    const MAX_SCALE: f64 = 8.0;
    const MIN_CONFIRMATION_TIMEOUT_MILLISECONDS: u64 = 1_000;
    const MAX_CONFIRMATION_TIMEOUT_MILLISECONDS: u64 = 60_000;

    if request.persistent && !persistence_available {
        return Err(output_control::OutputControlFailure::new(
            "unsupported",
            "persistent output configuration requires deniald --output-config",
        ));
    }
    if request
        .confirmation_timeout_milliseconds
        .is_some_and(|timeout| {
            !(MIN_CONFIRMATION_TIMEOUT_MILLISECONDS..=MAX_CONFIRMATION_TIMEOUT_MILLISECONDS)
                .contains(&timeout)
        })
    {
        return Err(output_control::OutputControlFailure::new(
            "invalid_configuration",
            format!(
                "output confirmation timeout must be within [{MIN_CONFIRMATION_TIMEOUT_MILLISECONDS}, {MAX_CONFIRMATION_TIMEOUT_MILLISECONDS}] milliseconds"
            ),
        ));
    }
    if request.outputs.len() != connectors.len() {
        return Err(output_control::OutputControlFailure::new(
            "invalid_configuration",
            format!(
                "a complete configuration for {} connected outputs is required, received {}",
                connectors.len(),
                request.outputs.len()
            ),
        ));
    }

    let mut requested_by_name = BTreeMap::new();
    for output in &request.outputs {
        if requested_by_name
            .insert(output.name.as_str(), output)
            .is_some()
        {
            return Err(output_control::OutputControlFailure::new(
                "invalid_configuration",
                format!("output {} appears more than once", output.name),
            ));
        }
    }
    let connected_names = connectors
        .iter()
        .map(|connector| {
            format!(
                "{}-{}",
                connector.info.interface().as_str(),
                connector.info.interface_id()
            )
        })
        .collect::<BTreeSet<_>>();
    let requested_names = requested_by_name
        .keys()
        .map(|name| (*name).to_owned())
        .collect::<BTreeSet<_>>();
    if connected_names != requested_names {
        let missing = connected_names
            .difference(&requested_names)
            .cloned()
            .collect::<Vec<_>>();
        let unknown = requested_names
            .difference(&connected_names)
            .cloned()
            .collect::<Vec<_>>();
        return Err(output_control::OutputControlFailure::new(
            "invalid_configuration",
            format!(
                "output set does not match connected hardware; missing={missing:?}, unknown={unknown:?}"
            ),
        ));
    }

    let enabled_count = request
        .outputs
        .iter()
        .filter(|output| output.enabled)
        .count();
    if enabled_count == 0 {
        return Err(output_control::OutputControlFailure::new(
            "invalid_configuration",
            "at least one connected output must remain enabled",
        ));
    }
    if enabled_count > max_outputs {
        return Err(output_control::OutputControlFailure::new(
            "invalid_configuration",
            format!(
                "{enabled_count} enabled outputs exceed Denial's configured limit of {max_outputs}"
            ),
        ));
    }

    let mut staged = current.clone();
    let mut power = BTreeMap::new();
    for connector in connectors {
        let name = format!(
            "{}-{}",
            connector.info.interface().as_str(),
            connector.info.interface_id()
        );
        let output = requested_by_name[&name.as_str()];
        if !output.enabled && output.powered {
            return Err(output_control::OutputControlFailure::new(
                "invalid_configuration",
                format!("disabled output {name} cannot be powered on"),
            ));
        }
        if !output.scale.is_finite() || !(MIN_SCALE..=MAX_SCALE).contains(&output.scale) {
            return Err(output_control::OutputControlFailure::new(
                "invalid_configuration",
                format!("{name} scale must be finite and within [{MIN_SCALE}, {MAX_SCALE}]"),
            ));
        }
        let mode = OutputModePreference {
            width: Some(output.mode.width),
            height: Some(output.mode.height),
            refresh_millihz: Some(output.mode.refresh_millihz),
        };
        if select_output_mode(&connector.info, Some(mode)).is_none() {
            return Err(output_control::OutputControlFailure::new(
                "invalid_configuration",
                format!(
                    "{} does not advertise {}x{} at {} mHz",
                    name, output.mode.width, output.mode.height, output.mode.refresh_millihz
                ),
            ));
        }

        let scale_120 = (output.scale * f64::from(SCALE_BASE)).round() as u32;
        staged
            .positions
            .insert(name.clone(), LogicalPoint::new(output.x, output.y));
        staged.modes.insert(name.clone(), mode);
        staged.scales_120.insert(name.clone(), scale_120);
        let effective_transform = output_transform_from_name(output.transform);
        staged.transforms.insert(
            name.clone(),
            current.baseline_transform(&name, effective_transform),
        );
        if output.enabled {
            staged.disabled_outputs.remove(&name);
            power.insert(
                OutputId(u64::from(u32::from(connector.info.handle()))),
                output.powered,
            );
        } else {
            staged.disabled_outputs.insert(name.clone());
            power.remove(&OutputId(u64::from(u32::from(connector.info.handle()))));
        }
        if output.adaptive_sync {
            staged.vrr_outputs.insert(name);
        } else {
            staged.vrr_outputs.remove(&name);
        }
    }
    Ok((staged, power))
}

fn stage_output_vrr(surface: &DrmSurface, output: &ConnectedOutput) -> Result<(), Box<dyn Error>> {
    if output.vrr_enabled {
        let support = surface.vrr_supported(output.connector)?;
        if support == VrrSupport::NotSupported {
            return Err(format!("{} does not advertise VRR support", output.name).into());
        }
        if surface.vrr_enabled() {
            return Ok(());
        }
        info!(
            output = output.name,
            ?support,
            "enabling variable refresh rate"
        );
    } else {
        if !surface.vrr_enabled() {
            return Ok(());
        }
        info!(output = output.name, "disabling variable refresh rate");
    }
    surface
        .use_vrr(output.vrr_enabled)
        .map_err(|error| format!("{} VRR staging failed: {error}", output.name).into())
}

const REFRESH_FALLBACK_WARNING_MILLIHERTZ: u32 = 1_000;

fn select_output_mode(
    connector: &connector::Info,
    preference: Option<OutputModePreference>,
) -> Option<Mode> {
    let preferred = connector
        .modes()
        .iter()
        .find(|mode| mode.mode_type().contains(ModeTypeFlags::PREFERRED))
        .or_else(|| connector.modes().first())?;
    let selected_size = match preference {
        Some(OutputModePreference {
            width: Some(width),
            height: Some(height),
            ..
        }) => (u16::try_from(width).ok()?, u16::try_from(height).ok()?),
        Some(OutputModePreference {
            width: None,
            height: None,
            ..
        })
        | None => preferred.size(),
        Some(_) => return None,
    };
    let configured_refresh_millihz = preference.and_then(|preference| preference.refresh_millihz);

    let matching_modes = connector
        .modes()
        .iter()
        .filter(|mode| mode.size() == selected_size)
        .filter_map(|mode| {
            let refresh = u32::try_from(OutputMode::from(*mode).refresh).ok()?;
            Some((*mode, refresh))
        })
        .collect::<Vec<_>>();
    let selected_refresh = select_refresh_millihz(
        matching_modes.iter().map(|(_, refresh)| *refresh),
        configured_refresh_millihz,
    )?;
    matching_modes
        .into_iter()
        .find_map(|(mode, refresh)| (refresh == selected_refresh).then_some(mode))
}

fn select_refresh_millihz(
    refreshes: impl IntoIterator<Item = u32>,
    configured_refresh_millihz: Option<u32>,
) -> Option<u32> {
    let refreshes = refreshes.into_iter();
    match configured_refresh_millihz {
        Some(configured) => refreshes
            .min_by_key(|refresh| (refresh.abs_diff(configured), std::cmp::Reverse(*refresh))),
        None => refreshes.max(),
    }
}

#[cfg(all(test, feature = "flutter"))]
mod dpms_topology_tests {
    use super::{DPMS_WAKE_TOPOLOGY_GRACE, transient_dpms_output_removal_count};
    use denial_core::topology::OutputId;
    use std::time::Instant;

    #[test]
    fn missing_output_is_deferred_only_inside_dpms_wake_grace() {
        let now = Instant::now();
        let grace_until = now + DPMS_WAKE_TOPOLOGY_GRACE;
        let current = [OutputId(4), OutputId(5)];

        assert_eq!(
            transient_dpms_output_removal_count(Some(grace_until), now, current, [OutputId(5)]),
            1
        );
        assert_eq!(
            transient_dpms_output_removal_count(
                Some(grace_until),
                grace_until,
                current,
                [OutputId(5)]
            ),
            0
        );
        assert_eq!(
            transient_dpms_output_removal_count(None, now, current, [OutputId(5)]),
            0
        );
    }

    #[test]
    fn recovered_or_additive_topology_is_never_deferred() {
        let now = Instant::now();
        let grace_until = now + DPMS_WAKE_TOPOLOGY_GRACE;

        assert_eq!(
            transient_dpms_output_removal_count(
                Some(grace_until),
                now,
                [OutputId(4), OutputId(5)],
                [OutputId(4), OutputId(5)]
            ),
            0
        );
        assert_eq!(
            transient_dpms_output_removal_count(
                Some(grace_until),
                now,
                [OutputId(5)],
                [OutputId(4), OutputId(5)]
            ),
            0
        );
    }
}

#[cfg(test)]
mod output_mode_tests {
    use super::select_refresh_millihz;

    #[test]
    fn configured_refresh_selects_the_nearest_nominal_drm_mode() {
        let refreshes = [60_000, 179_998, 199_998, 280_000];

        assert_eq!(
            select_refresh_millihz(refreshes, Some(200_000)),
            Some(199_998)
        );
        assert_eq!(
            select_refresh_millihz(refreshes, Some(180_000)),
            Some(179_998)
        );
        assert_eq!(select_refresh_millihz(refreshes, None), Some(280_000));
    }

    #[test]
    fn configured_refresh_falls_back_to_the_nearest_available_rate() {
        assert_eq!(
            select_refresh_millihz([60_000, 180_000, 280_000], Some(200_000)),
            Some(180_000)
        );
    }
}

#[cfg(all(test, feature = "flutter"))]
mod output_rotation_request_tests {
    use super::{output_control, output_request_changes_only_transforms};

    fn mode() -> output_control::OutputControlMode {
        output_control::OutputControlMode {
            width: 1920,
            height: 1080,
            refresh_millihz: 60_000,
            preferred: true,
        }
    }

    fn current() -> output_control::OutputControlOutput {
        output_control::OutputControlOutput {
            name: "eDP-1".to_owned(),
            description: "eDP-1".to_owned(),
            connected: true,
            enabled: true,
            powered: true,
            x: 0,
            y: 0,
            logical_width: 1920,
            logical_height: 1080,
            physical_width_mm: None,
            physical_height_mm: None,
            scale: 1.0,
            transform: output_control::OutputTransformName::Normal,
            adaptive_sync: false,
            current_mode: Some(mode()),
            modes: vec![mode()],
        }
    }

    fn requested(
        transform: output_control::OutputTransformName,
    ) -> output_control::RequestedOutput {
        output_control::RequestedOutput {
            name: "eDP-1".to_owned(),
            enabled: true,
            powered: true,
            x: 0,
            y: 0,
            mode: output_control::RequestedOutputMode {
                width: 1920,
                height: 1080,
                refresh_millihz: 60_000,
            },
            scale: 1.0,
            transform,
            adaptive_sync: false,
        }
    }

    #[test]
    fn settings_rotation_uses_the_sensor_animation_path() {
        assert!(output_request_changes_only_transforms(
            &[current()],
            &[requested(output_control::OutputTransformName::Rotate90)],
        ));
    }

    #[test]
    fn mixed_geometry_change_is_not_a_rotation_transition() {
        let mut request = requested(output_control::OutputTransformName::Rotate90);
        request.scale = 2.0;
        assert!(!output_request_changes_only_transforms(
            &[current()],
            &[request],
        ));
    }

    #[test]
    fn unchanged_transform_does_not_start_a_rotation_transition() {
        assert!(!output_request_changes_only_transforms(
            &[current()],
            &[requested(output_control::OutputTransformName::Normal)],
        ));
    }
}

fn topology_for_outputs(
    outputs: &[ConnectedOutput],
    configuration: &RuntimeOutputConfiguration,
) -> Result<TopologyManager, Box<dyn Error>> {
    Ok(TopologyManager::new(output_specs(outputs, configuration)?)?)
}

fn update_topology_for_outputs(
    topology: &mut TopologyManager,
    outputs: &[ConnectedOutput],
    configuration: &RuntimeOutputConfiguration,
) -> Result<TopologySnapshot, Box<dyn Error>> {
    let specs = output_specs(outputs, configuration)?;
    let desired = specs.iter().map(|output| output.id).collect::<HashSet<_>>();
    let mut changes = topology
        .snapshot()
        .outputs
        .into_iter()
        .filter(|output| !desired.contains(&output.id))
        .map(|output| TopologyChange::Remove(output.id))
        .collect::<Vec<_>>();
    changes.extend(specs.into_iter().map(TopologyChange::Upsert));
    topology.apply(changes)?;
    Ok(topology.snapshot())
}

fn output_specs(
    outputs: &[ConnectedOutput],
    configuration: &RuntimeOutputConfiguration,
) -> Result<Vec<OutputSpec>, Box<dyn Error>> {
    let mut default_x = 0i32;
    let mut specs = Vec::with_capacity(outputs.len());

    for output in outputs {
        let mode: OutputMode = output.mode.into();
        let width = u32::try_from(mode.size.w)?;
        let height = u32::try_from(mode.size.h)?;
        let position = configuration
            .positions
            .get(&output.name)
            .copied()
            .unwrap_or_else(|| LogicalPoint::new(default_x, 0));
        let scale_120 = configuration
            .scales_120
            .get(&output.name)
            .copied()
            .unwrap_or(SCALE_BASE);
        let spec = OutputSpec {
            id: output.id,
            name: output.name.clone(),
            position,
            mode: PixelSize::new(width, height),
            scale_120,
            refresh_millihz: u32::try_from(mode.refresh)?,
            transform: output.transform,
        };
        let logical_width = spec.logical_rect().width.ceil();
        specs.push(spec);
        default_x = default_x.max(
            position
                .x
                .checked_add(i32::try_from(logical_width as i64)?)
                .ok_or("output layout overflow")?,
        );
    }

    Ok(specs)
}

fn render_diagnostic_atlas(
    renderer: &mut GlesRenderer,
    dmabuf: &mut Dmabuf,
    atlas_size: PixelSize,
    scanouts: &[Scanout],
    frame_number: u64,
) -> Result<(), Box<dyn Error>> {
    let render_size = (
        i32::try_from(atlas_size.width)?,
        i32::try_from(atlas_size.height)?,
    )
        .into();
    let mut framebuffer = renderer.bind(dmabuf)?;
    let mut frame = renderer.render(&mut framebuffer, render_size, Transform::Normal)?;
    frame.clear(
        Color32F::new(0.015, 0.02, 0.035, 1.0),
        &[Rectangle::from_size(render_size)],
    )?;

    for (index, scanout) in scanouts.iter().enumerate() {
        let rect = physical_rect(scanout.source_rect)?;
        frame.clear(COLORS[index % COLORS.len()], &[rect])?;

        let marker_size = (
            (rect.size.w / 7).clamp(24, 240),
            (rect.size.h / 9).clamp(24, 180),
        );
        let travel = rect
            .size
            .w
            .saturating_sub(marker_size.0)
            .saturating_sub(64)
            .max(1);
        let phase = ((frame_number.saturating_mul(12) + index as u64 * 97)
            % u64::try_from(travel.saturating_mul(2))?) as i32;
        let offset = if phase <= travel {
            phase
        } else {
            travel.saturating_mul(2) - phase
        };
        let marker = Rectangle::new(
            (rect.loc.x + 32 + offset, rect.loc.y + 32).into(),
            marker_size.into(),
        );
        frame.clear(Color32F::new(0.96, 0.98, 1.0, 1.0), &[marker])?;
    }

    frame.finish()?.wait()?;
    Ok(())
}

fn render_blank_target(
    renderer: &mut GlesRenderer,
    dmabuf: &mut Dmabuf,
    target_size: PixelSize,
) -> Result<(), Box<dyn Error>> {
    let render_size = (
        i32::try_from(target_size.width)?,
        i32::try_from(target_size.height)?,
    )
        .into();
    let mut framebuffer = renderer.bind(dmabuf)?;
    let mut frame = renderer.render(&mut framebuffer, render_size, Transform::Normal)?;
    frame.clear(
        Color32F::new(0.0, 0.0, 0.0, 1.0),
        &[Rectangle::from_size(render_size)],
    )?;
    frame.finish()?.wait()?;
    Ok(())
}

#[cfg(feature = "flutter")]
fn render_blank_output_swapchains(
    renderer: &mut GlesRenderer,
    swapchains: &mut OutputSwapchains,
) -> Result<(), Box<dyn Error>> {
    for pool in &mut swapchains.outputs {
        let buffer = pool
            .buffers
            .get_mut(pool.current)
            .ok_or("physical output's initial scanout index exceeds its pool")?;
        render_blank_target(renderer, &mut buffer.dmabuf, pool.size)?;
    }
    Ok(())
}

fn plane_state(
    scanout: &Scanout,
    framebuffer: smithay::reexports::drm::control::framebuffer::Handle,
) -> PlaneState<'static> {
    plane_state_for_mode_and_source(
        scanout,
        framebuffer,
        scanout.output.mode,
        scanout.source_rect,
        smithay_output_transform(scanout.output.transform),
    )
}

fn current_scanout_state(
    scanout: &Scanout,
    swapchain: &RenderSwapchains,
) -> Result<(framebuffer::Handle, PlaneState<'static>), Box<dyn Error>> {
    #[cfg(feature = "flutter")]
    if let Some(outputs) = swapchain.outputs() {
        let pool = outputs
            .for_output(scanout.output.id)
            .ok_or("scanout has no physical Flutter buffer pool")?;
        let framebuffer = pool
            .buffers
            .get(pool.current)
            .ok_or("physical Flutter scanout index exceeds its pool")?
            .framebuffer();
        return Ok((
            framebuffer,
            output_plane_state(scanout, framebuffer, pool.size),
        ));
    }
    let framebuffer = swapchain
        .atlas()
        .ok_or("diagnostic scanout has no atlas swapchain")?
        .current_framebuffer();
    Ok((framebuffer, plane_state(scanout, framebuffer)))
}

#[cfg(feature = "flutter")]
fn output_plane_state(
    scanout: &Scanout,
    framebuffer: framebuffer::Handle,
    size: PixelSize,
) -> PlaneState<'static> {
    plane_state_for_mode_and_source(
        scanout,
        framebuffer,
        scanout.output.mode,
        PixelRect {
            x: 0,
            y: 0,
            width: size.width,
            height: size.height,
        },
        Transform::Normal,
    )
}

fn plane_state_for_mode(
    scanout: &Scanout,
    framebuffer: framebuffer::Handle,
    mode: Mode,
) -> PlaneState<'static> {
    plane_state_for_mode_and_source(
        scanout,
        framebuffer,
        mode,
        scanout.source_rect,
        smithay_output_transform(scanout.output.transform),
    )
}

fn plane_state_for_mode_and_source(
    scanout: &Scanout,
    framebuffer: framebuffer::Handle,
    mode: Mode,
    source: PixelRect,
    transform: Transform,
) -> PlaneState<'static> {
    let (width, height) = mode.size();
    PlaneState {
        handle: scanout.surface.plane(),
        config: Some(PlaneConfig {
            src: Rectangle::<f64, Buffer>::new(
                (source.x as f64, source.y as f64).into(),
                (source.width as f64, source.height as f64).into(),
            ),
            dst: Rectangle::<i32, Physical>::from_size(
                (i32::from(width), i32::from(height)).into(),
            ),
            transform,
            alpha: scanout.plane_properties.smithay_opaque_alpha,
            damage_clips: None,
            fb: framebuffer,
            fence: None,
        }),
    }
}

fn physical_rect(rect: PixelRect) -> Result<Rectangle<i32, Physical>, Box<dyn Error>> {
    Ok(Rectangle::new(
        (i32::try_from(rect.x)?, i32::try_from(rect.y)?).into(),
        (i32::try_from(rect.width)?, i32::try_from(rect.height)?).into(),
    ))
}

fn smithay_output_transform(transform: OutputTransform) -> Transform {
    match transform {
        OutputTransform::Normal => Transform::Normal,
        OutputTransform::Rotate90 => Transform::_90,
        OutputTransform::Rotate180 => Transform::_180,
        OutputTransform::Rotate270 => Transform::_270,
        OutputTransform::Flipped => Transform::Flipped,
        OutputTransform::Flipped90 => Transform::Flipped90,
        OutputTransform::Flipped180 => Transform::Flipped180,
        OutputTransform::Flipped270 => Transform::Flipped270,
    }
}
