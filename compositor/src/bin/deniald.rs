#![deny(unsafe_op_in_unsafe_fn)]
#![deny(clippy::undocumented_unsafe_blocks)]

#[cfg(feature = "flutter")]
#[path = "deniald/authentication.rs"]
mod authentication;
#[path = "deniald/egl_context.rs"]
mod egl_context;
#[cfg(feature = "flutter")]
#[path = "deniald/flutter_runtime.rs"]
mod flutter_runtime;
#[path = "deniald/hotplug_transaction.rs"]
mod hotplug_transaction;
#[path = "deniald/kms_state.rs"]
mod kms_state;
#[path = "deniald/lifecycle.rs"]
mod lifecycle;
#[cfg(feature = "flutter")]
#[path = "deniald/local_windows.rs"]
mod local_windows;
#[path = "deniald/native_shortcut.rs"]
mod native_shortcut;
#[cfg(feature = "flutter")]
#[path = "deniald/notification_server.rs"]
mod notification_server;
#[path = "deniald/options.rs"]
mod options;
#[cfg(feature = "flutter")]
#[path = "deniald/output_scheduler.rs"]
mod output_scheduler;
#[path = "deniald/scene_sync.rs"]
mod scene_sync;
#[path = "deniald/system_controls.rs"]
mod system_controls;
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
#[cfg(feature = "flutter")]
use std::os::fd::{AsFd, OwnedFd};
use std::os::fd::{AsRawFd, BorrowedFd};
use std::os::unix::fs::MetadataExt;
use std::panic::{AssertUnwindSafe, catch_unwind, resume_unwind};
use std::path::Path;
use std::process::Command;
#[cfg(feature = "flutter")]
use std::sync::Arc;
#[cfg(feature = "flutter")]
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use calloop::signals::{Signal, Signals};
use denial_core::topology::{
    AtlasPlan, LogicalPoint, OutputId, OutputSpec, OutputTransform, PixelRect, PixelSize,
    TopologyChange, TopologyManager, TopologySnapshot,
};
use smithay::backend::allocator::dmabuf::{AsDmabuf, Dmabuf};
use smithay::backend::allocator::format::FormatSet;
use smithay::backend::allocator::gbm::{GbmAllocator, GbmBuffer, GbmBufferFlags, GbmDevice};
use smithay::backend::allocator::{Allocator, Format, Fourcc, Modifier};
use smithay::backend::drm::gbm::{GbmFramebuffer, framebuffer_from_bo};
use smithay::backend::drm::{
    DrmDevice, DrmDeviceFd, DrmEvent, DrmEventTime, DrmSurface, PlaneConfig, PlaneState, VrrSupport,
};
use smithay::backend::egl::EGLDisplay;
use smithay::backend::renderer::gles::GlesRenderer;
use smithay::backend::renderer::{Bind, Color32F, Frame, Renderer};
use smithay::backend::session::libseat::LibSeatSession;
use smithay::backend::session::{Event as SessionEvent, Session};
use smithay::backend::udev::{UdevBackend, UdevEvent};
use smithay::output::Mode as OutputMode;
use smithay::reexports::calloop::EventLoop;
#[cfg(feature = "flutter")]
use smithay::reexports::calloop::channel::Sender;
#[cfg(feature = "flutter")]
use smithay::reexports::calloop::{Interest, Mode as PollMode, PostAction, generic::Generic};
use smithay::reexports::drm::buffer::{
    DrmFourcc, DrmModifier, Handle as BufferHandle, PlanarBuffer,
};
use smithay::reexports::drm::control::{
    AtomicCommitFlags, Device as ControlDevice, Mode, ModeTypeFlags, RawResourceHandle,
    ResourceHandle, atomic::AtomicModeReq, connector, crtc, framebuffer, from_u32, plane, property,
};
use smithay::reexports::rustix::fs::OFlags;
use smithay::utils::{Buffer, DeviceFd, Physical, Rectangle, Transform};
use smithay_drm_extras::drm_scanner::{DrmScanEvent, DrmScanner, SimpleCrtcMapper};
use tracing::{error, info, warn};

use hotplug_transaction::{
    HotplugProgress, ScanoutKey, ScanoutOrigin, append_quarantined, install_candidate,
    plan_reconcile,
};
use kms_state::{
    AtlasPlaneProperties, AtlasSwapchain, ConnectedOutput, KmsContext, LayoutTransition,
    PreviousScanoutState, ReconciledScanoutOrigin, RestoreState, Scanout, ScanoutReconciliation,
    shared_atlas_modifiers,
};
#[cfg(feature = "flutter")]
use kms_state::{FlutterLauncher, flutter_pool_length};
use lifecycle::{
    InactiveDispatch, LifecycleState, ShutdownReason, TeardownGate, inactive_dispatch,
};
use native_shortcut::NativeEscapeShortcut;
#[cfg(feature = "flutter")]
use notification_server::NotificationServer;
use options::{Options, RuntimeLimit, SIMULATED_HOTPLUG_GAP_FRAMES};
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

#[cfg(feature = "flutter")]
const NOTIFICATION_EVENT_QUEUE_CAPACITY: usize = 512;

fn main() -> Result<(), Box<dyn Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "denial_kms=info,smithay=info".into()),
        )
        .init();

    let options = Options::parse()?;
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

    let (mut session, session_notifier) = LibSeatSession::new()?;
    if !session.is_active() {
        return Err("libseat did not activate the current TTY session".into());
    }
    let seat_name = session.seat();
    let drm_device_id = std::fs::metadata(&options.device)?.rdev();

    let owned_fd = session.open(
        Path::new(&options.device),
        OFlags::RDWR | OFlags::CLOEXEC | OFlags::NOCTTY | OFlags::NONBLOCK,
    )?;
    let drm_fd = DrmDeviceFd::new(DeviceFd::from(owned_fd));
    let (drm, drm_notifier) = DrmDevice::new(drm_fd.clone(), false)?;
    if !drm.is_atomic() {
        return Err("the selected DRM device does not expose atomic modesetting".into());
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
                    let observed_at = Instant::now();
                    let presented_at = metadata.as_ref().and_then(|metadata| match metadata.time {
                        DrmEventTime::Monotonic(timestamp) => Some(timestamp),
                        DrmEventTime::Realtime(_) => None,
                    });
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
            Signals::new(&[
                Signal::SIGINT,
                Signal::SIGTERM,
                #[cfg(feature = "flutter")]
                Signal::SIGUSR1,
            ])?,
            |event, _, state| {
                let reason = match event.signal() {
                    Signal::SIGINT => ShutdownReason::Interrupt,
                    Signal::SIGTERM => ShutdownReason::Terminate,
                    #[cfg(feature = "flutter")]
                    Signal::SIGUSR1 => {
                        state.flutter_reload_requested = true;
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
        &options.refresh_millihz,
        &options.vrr_outputs,
    )?;
    if outputs.is_empty() {
        return Err(format!("no connected outputs found on {}", options.device.display()).into());
    }

    let mut topology = topology_for_outputs(&outputs, &options.positions)?;
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
        )?;
        info!(
            wayland_display = ?frontend.socket_name(),
            x11_display = ?frontend.xdisplay_name(),
            "Wayland frontend listening"
        );
        Some(frontend)
    } else {
        None
    };
    let layout_transition = if let Some(at_frame) = options.reconfigure_at_frame {
        let mut positions = options.positions.clone();
        positions.extend(
            options
                .next_positions
                .iter()
                .map(|(name, position)| (name.clone(), *position)),
        );
        let staged_topology = topology_for_outputs(&outputs, &positions)?;
        AtlasPlan::for_snapshot(&staged_topology.snapshot())
            .ok_or("reconfigured topology produced no atlas")?;
        Some(LayoutTransition {
            at_frame,
            positions,
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
        });
    }

    let gbm = GbmDevice::new(drm_fd.clone())?;
    let mut allocator = GbmAllocator::new(
        gbm.clone(),
        GbmBufferFlags::RENDERING | GbmBufferFlags::SCANOUT,
    );
    // SAFETY: the GBM device outlives the EGL display, context, renderer and
    // every imported dmabuf created below. All of them are dropped in this
    // function before `gbm` and `drm_fd`.
    let egl_display = unsafe { EGLDisplay::new(gbm.clone())? };
    let atlas_modifiers =
        shared_atlas_modifiers(&kms.scanouts, egl_display.dmabuf_render_formats())?;
    let atlas_pool_length = if options.flutter_bundle.is_some() {
        #[cfg(feature = "flutter")]
        {
            flutter_pool_length(kms.scanouts.len())?
        }
        #[cfg(not(feature = "flutter"))]
        {
            return Err("Flutter feature was checked before acquiring DRM".into());
        }
    } else {
        2
    };
    let mut atlas_swapchain = AtlasSwapchain::allocate_pool(
        &mut allocator,
        &drm_fd,
        atlas.pixel_size,
        atlas_pool_length,
        &atlas_modifiers,
    )?;
    let egl_context = egl_context::create_render_context(&egl_display)?;
    // SAFETY: `egl_context` is current only through this renderer and remains
    // alive for the renderer's entire lifetime.
    let mut renderer = unsafe { GlesRenderer::new(egl_context)? };
    if let Some(frontend) = wayland.as_mut() {
        frontend.init_renderer(&mut renderer)?;
    }
    render_atlas(
        &mut renderer,
        &mut atlas_swapchain.buffers[atlas_swapchain.current].dmabuf,
        atlas_swapchain.size,
        &kms.scanouts,
        0,
    )?;

    let fb = atlas_swapchain.current_framebuffer();

    info!(
        device = %options.device.display(),
        outputs = kms.scanouts.len(),
        atlas_width = atlas.pixel_size.width,
        atlas_height = atlas.pixel_size.height,
        framebuffer = ?fb,
        modifiers = ?atlas_swapchain
            .buffers
            .iter()
            .map(|buffer| buffer.format().modifier)
            .collect::<Vec<_>>(),
        "testing shared-atlas atomic state"
    );

    let mut restore_state = if !preserves_predecessor_kms_state(runtime_limit) {
        // SDDM/logind may disable its CRTC between libseat activation and this
        // point. A real login session hands KMS back by releasing DRM master;
        // it must not depend on cloning a greeter framebuffer that may already
        // have disappeared.
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
        let state = plane_state(scanout, fb);
        scanout.surface.test_state([state], true)?;
        let mode: OutputMode = scanout.output.mode.into();
        info!(
            output = scanout.output.name,
            crtc = ?scanout.output.crtc,
            plane = ?scanout.surface.plane(),
            source = ?scanout.source_rect,
            refresh_millihz = mode.refresh,
            "atomic TEST_ONLY accepted"
        );
    }

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
            bundle,
            sender,
            wayland
                .as_ref()
                .map(|frontend| frontend.socket_name().to_os_string()),
            wayland.as_ref().map(|frontend| frontend.xdisplay_name()),
            options.work_area.clone(),
        )?)
    } else {
        None
    };
    #[cfg(feature = "flutter")]
    let flutter = if let Some(launcher) = flutter_launcher.as_mut() {
        Some(launcher.start(
            &renderer,
            &atlas_swapchain,
            &kms.scanouts,
            &snapshot,
            &atlas,
        )?)
    } else {
        None
    };

    if runtime_limit == RuntimeLimit::TestOnly {
        kms.pause();
        info!("TEST_ONLY complete; scanout was not changed and surface teardown is inert");
        return Ok(());
    }

    let runtime_outcome = catch_unwind(AssertUnwindSafe(|| -> Result<_, Box<dyn Error>> {
        for scanout in &kms.scanouts {
            scanout
                .surface
                .commit([plane_state(scanout, fb)], false)
                .map_err(|error| format!("initial KMS commit failed: {error}"))?;
        }
        if let Some(frontend) = wayland.as_ref() {
            // READY means the full session is usable: Flutter has started and
            // every connected output accepted its first real KMS commit. A
            // finalization failure remains inside the restore boundary.
            finalize_uwsm_session(frontend.socket_name(), &frontend.xdisplay_name())?;
        }

        if let RuntimeLimit::Frames(frame_count) = runtime_limit {
            run_frame_loop(
                &mut renderer,
                &mut allocator,
                &drm_fd,
                &mut kms.drm,
                &mut drm_scanner,
                &mut atlas_swapchain,
                &mut kms.scanouts,
                &mut restore_state,
                wayland,
                #[cfg(feature = "flutter")]
                flutter,
                #[cfg(feature = "flutter")]
                flutter_launcher.as_mut(),
                frame_count,
                options.max_outputs,
                &options.refresh_millihz,
                &options.vrr_outputs,
                options.rescan_at_frame,
                options.simulate_hotplug_at_frame,
                &options.positions,
                &mut topology,
                layout_transition.as_ref(),
                frame_event_loop
                    .as_mut()
                    .ok_or("frame loop has no event source")?,
            )
            .map_err(|error| format!("frame loop failed: {error}").into())
        } else if options.flutter_bundle.is_some() {
            #[cfg(feature = "flutter")]
            {
                let duration = match runtime_limit {
                    RuntimeLimit::Duration(duration) => Some(duration),
                    RuntimeLimit::UntilLogout => None,
                    _ => {
                        return Err(
                            "Flutter loop selected with an incompatible runtime limit".into()
                        );
                    }
                };
                run_flutter_event_loop(
                    &mut renderer,
                    &mut kms.drm,
                    &mut atlas_swapchain,
                    &mut kms.scanouts,
                    &mut restore_state,
                    &mut drm_scanner,
                    &mut allocator,
                    &drm_fd,
                    &mut topology,
                    options.max_outputs,
                    &options.refresh_millihz,
                    &options.vrr_outputs,
                    &options.positions,
                    wayland,
                    flutter.ok_or("Flutter runtime was not initialized")?,
                    flutter_launcher
                        .as_mut()
                        .ok_or("Flutter launcher was not initialized")?,
                    duration,
                    frame_event_loop
                        .as_mut()
                        .ok_or("Flutter event loop has no event source")?,
                )
                .map_err(|error| format!("Flutter event loop failed: {error}").into())
            }
            #[cfg(not(feature = "flutter"))]
            return Err("Flutter feature was checked before acquiring DRM".into());
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
        .unwrap_or_else(|| atlas_swapchain.current_framebuffer());

    if runtime_limit == RuntimeLimit::UntilLogout {
        // This is the last-resort teardown boundary for a real login session.
        // The orderly path already drains pending flips and releases master,
        // but an error or panic can leave the Flutter loop before reaching
        // that code. Never let such an exceptional exit fall through to the
        // synchronous atomic restore below: SDDM owns the next modeset.
        kms.pause();
    }
    let restore = kms.restore_once(&restore_state, current_fb);
    let restored = restore.restored;
    let restore_failures = restore.failures;

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

fn finalize_uwsm_session(
    wayland_display: &OsStr,
    x11_display: &OsStr,
) -> Result<(), Box<dyn Error>> {
    if std::env::var_os("DENIA_UWSM_FINALIZE").as_deref() != Some(OsStr::new("1")) {
        return Ok(());
    }

    // The SDDM entry intentionally follows the existing, reliable UWSM
    // session envelope. Once the caller has brought Smithay, Flutter and the
    // real KMS scanouts up, export the listener's actual auto-selected name
    // and complete the compositor unit handshake.
    // Direct TTY/KMS test runs never set DENIA_UWSM_FINALIZE and remain fully
    // independent from the user's graphical-session manager.
    let status = uwsm_finalize_command(wayland_display, x11_display).status()?;
    if !status.success() {
        return Err(format!("uwsm finalize failed with {status}").into());
    }
    info!(
        wayland_display = ?wayland_display,
        x11_display = ?x11_display,
        "finalized UWSM Wayland session"
    );
    Ok(())
}

fn uwsm_finalize_command(wayland_display: &OsStr, x11_display: &OsStr) -> Command {
    let mut command = Command::new("uwsm");
    command
        .arg("finalize")
        .args([
            "XDG_CURRENT_DESKTOP",
            "XDG_SESSION_DESKTOP",
            "XDG_SESSION_TYPE",
            "DESKTOP_SESSION",
            "DISPLAY",
        ])
        .env("WAYLAND_DISPLAY", wayland_display)
        .env("DISPLAY", x11_display);
    command
}

#[cfg(test)]
mod uwsm_tests {
    use super::*;
    use std::ffi::OsString;

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
    fn finalize_command_exports_the_real_smithay_socket_and_desktop_identity() {
        let command = uwsm_finalize_command(OsStr::new("wayland-37"), OsStr::new(":42"));
        assert_eq!(command.get_program(), OsStr::new("uwsm"));
        assert_eq!(
            command.get_args().collect::<Vec<_>>(),
            [
                OsStr::new("finalize"),
                OsStr::new("XDG_CURRENT_DESKTOP"),
                OsStr::new("XDG_SESSION_DESKTOP"),
                OsStr::new("XDG_SESSION_TYPE"),
                OsStr::new("DESKTOP_SESSION"),
                OsStr::new("DISPLAY"),
            ]
        );
        let environment = command
            .get_envs()
            .map(|(key, value)| (key.to_owned(), value.map(OsStr::to_owned)))
            .collect::<BTreeMap<_, _>>();
        assert_eq!(
            environment.get(OsStr::new("WAYLAND_DISPLAY")),
            Some(&Some(OsString::from("wayland-37")))
        );
        assert_eq!(
            environment.get(OsStr::new("DISPLAY")),
            Some(&Some(OsString::from(":42")))
        );
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
    device_removed: bool,
    wayland: Option<wayland_frontend::WaylandFrontend>,
    scene_sync: SceneSyncState,
    system_controls: Option<SystemControls>,
    vblank_events: u64,
    #[cfg(feature = "flutter")]
    flutter_events: Vec<flutter_runtime::RuntimeEvent>,
    #[cfg(feature = "flutter")]
    sampled_buffer_releases: Vec<(Option<OwnedFd>, flutter_runtime::SampledBufferHoldBatch)>,
    #[cfg(feature = "flutter")]
    ready_fence_signals: Vec<output_scheduler::ReadyFenceSignal>,
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
    frame_callback_demand: bool,
    #[cfg(feature = "flutter")]
    flutter_input: flutter_runtime::InputQueue,
    #[cfg(feature = "flutter")]
    pending_window_events: PendingWindowEventQueue,
    #[cfg(feature = "flutter")]
    pending_unpublished_window_events: PendingWindowEventQueue,
    #[cfg(feature = "flutter")]
    pending_shell_actions: VecDeque<(wire::ShellAction, Option<i64>)>,
    #[cfg(feature = "flutter")]
    published_window_ids: HashSet<u64>,
    #[cfg(feature = "flutter")]
    notification_server: Option<NotificationServer>,
    #[cfg(feature = "flutter")]
    pending_notification_events: VecDeque<notification_server::NotificationEvent>,
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

    fn compositor_pointer_in_flutter_pixels(&self) -> Option<(f64, f64)> {
        self.wayland
            .as_ref()
            .map(wayland_frontend::WaylandFrontend::flutter_pointer_position)
    }

    /// Makes the Flutter engine's mouse state a projection of the compositor
    /// pointer instead of an independently integrated libinput position.
    fn synchronize_flutter_pointer_position(&mut self) {
        let Some((x, y)) = self.compositor_pointer_in_flutter_pixels() else {
            return;
        };
        self.flutter_input.synchronize_pointer_position(x, y);
    }

    fn queue_authoritative_flutter_pointer_motion(&mut self) {
        let Some((x, y)) = self.compositor_pointer_in_flutter_pixels() else {
            return;
        };
        self.flutter_input.handle_pointer_motion_at(x, y);
    }
}

fn service_session_lifecycle(
    drm: &mut DrmDevice,
    scanouts: &[Scanout],
    framebuffer: framebuffer::Handle,
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
    for scanout in scanouts {
        scanout
            .surface
            .test_state([plane_state(scanout, framebuffer)], true)?;
    }
    for scanout in scanouts {
        // Atomic modeset commits are synchronous here. Do not request a
        // vblank event: it would be indistinguishable from the next real
        // page-flip event after `pending` is repopulated and could make that
        // later frame appear complete before KMS actually scans it out.
        scanout
            .surface
            .commit([plane_state(scanout, framebuffer)], false)?;
    }
    events.pending.clear();
    events.completed_page_flips.clear();
    // Every CRTC now scans the framebuffer supplied by the caller. The
    // independently clocked Flutter scheduler must be recreated before it
    // interprets any later page-flip event using its pre-pause ownership.
    events.scanout_rebased = true;
    events.topology_dirty = true;
    info!(
        outputs = scanouts.len(),
        "libseat reactivated the KMS session"
    );
    Ok(())
}

fn log_shutdown(reason: ShutdownReason) {
    info!(
        reason = reason.description(),
        "graceful compositor shutdown requested"
    );
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
            framebuffer,
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
    allocator: &mut GbmAllocator<DrmDeviceFd>,
    drm_fd: &DrmDeviceFd,
    drm: &mut DrmDevice,
    drm_scanner: &mut DrmScanner<SimpleCrtcMapper>,
    swapchain: &mut AtlasSwapchain,
    scanouts: &mut Vec<Scanout>,
    restore_state: &mut RestoreState,
    wayland: Option<wayland_frontend::WaylandFrontend>,
    #[cfg(feature = "flutter")] mut flutter: Option<flutter_runtime::FlutterRuntime>,
    #[cfg(feature = "flutter")] mut flutter_launcher: Option<&mut FlutterLauncher>,
    frame_count: u64,
    max_outputs: usize,
    refresh_millihz: &BTreeMap<String, u32>,
    vrr_outputs: &BTreeSet<String>,
    rescan_at_frame: Option<u64>,
    simulate_hotplug_at_frame: Option<u64>,
    initial_positions: &BTreeMap<String, LogicalPoint>,
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
    #[cfg(feature = "flutter")]
    let authentication = flutter
        .as_ref()
        .map(flutter_runtime::FlutterRuntime::authentication);
    let mut events = RuntimeState {
        wayland,
        system_controls,
        #[cfg(feature = "flutter")]
        authentication,
        #[cfg(feature = "flutter")]
        flutter_active: flutter.is_some(),
        #[cfg(feature = "flutter")]
        flutter_input: flutter_runtime::InputQueue::new(swapchain.size),
        ..RuntimeState::default()
    };
    #[cfg(feature = "flutter")]
    events.synchronize_flutter_pointer_position();
    let mut active_positions = initial_positions.clone();

    for frame_number in 1..=frame_count {
        service_session_lifecycle(
            drm,
            scanouts,
            swapchain.current_framebuffer(),
            event_loop,
            &mut events,
            None,
        )?;
        if let Some(reason) = events.lifecycle.shutdown_reason() {
            log_shutdown(reason);
            return Ok(swapchain.current_framebuffer());
        }
        let render_started = Instant::now();
        let mut normal_next = None;
        let mut staged_swapchain = None;
        let layout_change =
            layout_transition.filter(|transition| transition.at_frame == frame_number);
        let mut planned_layout = None;
        if let Some(transition) = layout_change {
            #[cfg(feature = "flutter")]
            if flutter.is_some() {
                let outputs = scanouts
                    .iter()
                    .map(|scanout| scanout.output.clone())
                    .collect();
                apply_hotplug_topology(
                    renderer,
                    allocator,
                    drm_fd,
                    drm,
                    swapchain,
                    scanouts,
                    restore_state,
                    topology,
                    outputs,
                    &transition.positions,
                    frame_number,
                    event_loop,
                    &mut events,
                    &mut flutter,
                    flutter_launcher.as_deref_mut(),
                )?;
                active_positions.clone_from(&transition.positions);
            } else {
                let outputs = scanouts
                    .iter()
                    .map(|scanout| scanout.output.clone())
                    .collect::<Vec<_>>();
                let snapshot =
                    update_topology_for_outputs(topology, &outputs, &transition.positions)?;
                let atlas = AtlasPlan::for_snapshot(&snapshot)
                    .ok_or("reconfigured topology produced no atlas")?;
                planned_layout = Some((snapshot, atlas));
            }
            #[cfg(not(feature = "flutter"))]
            {
                let outputs = scanouts
                    .iter()
                    .map(|scanout| scanout.output.clone())
                    .collect::<Vec<_>>();
                let snapshot =
                    update_topology_for_outputs(topology, &outputs, &transition.positions)?;
                let atlas = AtlasPlan::for_snapshot(&snapshot)
                    .ok_or("reconfigured topology produced no atlas")?;
                planned_layout = Some((snapshot, atlas));
            }
        }
        #[cfg(feature = "flutter")]
        let flutter_ready = if let Some(runtime) = flutter.as_mut() {
            if let Some(frontend) = events.wayland.as_mut() {
                frontend.process_pending_dmabufs(renderer)?;
            }
            let Some(frame) = wait_for_flutter_frame(
                runtime,
                frame_number,
                drm,
                scanouts,
                swapchain.current_framebuffer(),
                event_loop,
                &mut events,
                flutter_launcher.as_deref_mut(),
            )?
            else {
                return Ok(swapchain.current_framebuffer());
            };
            Some(frame)
        } else {
            None
        };
        #[cfg(feature = "flutter")]
        let flutter_next = flutter_ready.as_ref().map(|frame| frame.index);
        #[cfg(not(feature = "flutter"))]
        let flutter_next: Option<usize> = None;
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
                allocator,
                drm_fd,
                transition_atlas.pixel_size,
                &atlas_modifiers,
            ) {
                Ok(staged) => staged,
                Err(error) => {
                    restore_source_rects(scanouts, &previous_rects);
                    return Err(error);
                }
            };
            if let Err(error) = render_atlas(
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
        } else if let Some(next) = flutter_next {
            normal_next = Some(next);
            swapchain.buffers[next].framebuffer()
        } else {
            let next = swapchain.next_index();
            if let Some(frontend) = events.wayland.as_mut() {
                frontend.process_pending_dmabufs(renderer)?;
                frontend.render(renderer, &mut swapchain.buffers[next].dmabuf)?;
            } else {
                render_atlas(
                    renderer,
                    &mut swapchain.buffers[next].dmabuf,
                    swapchain.size,
                    scanouts,
                    frame_number,
                )?;
            }
            normal_next = Some(next);
            swapchain.buffers[next].framebuffer()
        };
        let rendered = render_started.elapsed();
        total_render += rendered;
        longest_render = longest_render.max(rendered);

        events.pending.clear();
        for scanout in scanouts.iter() {
            events.pending.insert(scanout.output.crtc);
        }
        #[cfg(feature = "flutter")]
        let render_fence = flutter_ready
            .as_ref()
            .and_then(|frame| frame.fence.as_ref().map(AsFd::as_fd));
        #[cfg(not(feature = "flutter"))]
        let render_fence = None;
        if let Err(error) = queue_atlas_page_flip(drm, scanouts, framebuffer, render_fence) {
            #[cfg(feature = "flutter")]
            if let Some(index) = flutter_next
                && let Some(runtime) = flutter.as_ref()
            {
                runtime.cancel_flip(index);
            }
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
            let old_size = swapchain.size;
            let new_size = staged.size;
            let retired = std::mem::replace(swapchain, staged);
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
                framebuffer,
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
            #[cfg(feature = "flutter")]
            let previous = swapchain.current;
            swapchain.present(next);
            #[cfg(feature = "flutter")]
            if flutter_next == Some(next)
                && let Some(runtime) = flutter.as_ref()
            {
                runtime.complete_flip(previous, next)?;
            }
        } else if let Some((transition_snapshot, _)) = planned_layout.as_ref() {
            let transition = layout_change
                .ok_or("internal topology error: a planned layout has no matching transition")?;
            active_positions.clone_from(&transition.positions);
            if let Some(frontend) = events.wayland.as_mut() {
                frontend.update_topology(transition_snapshot)?;
            }
        }
        if let Some(frontend) = events.wayland.as_mut() {
            frontend.after_present()?;
        }
        if let Some(reason) = events.lifecycle.shutdown_reason() {
            log_shutdown(reason);
            return Ok(swapchain.current_framebuffer());
        }

        let simulated_disconnect = simulate_hotplug_at_frame == Some(frame_number);
        let simulated_reconnect = simulate_hotplug_at_frame
            .and_then(|frame| frame.checked_add(SIMULATED_HOTPLUG_GAP_FRAMES))
            == Some(frame_number);
        if simulated_disconnect || simulated_reconnect {
            let mut outputs =
                connected_outputs(drm_scanner, drm, max_outputs, refresh_millihz, vrr_outputs)?;
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
                allocator,
                drm_fd,
                drm,
                swapchain,
                scanouts,
                restore_state,
                topology,
                outputs,
                &active_positions,
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
            let outputs =
                connected_outputs(drm_scanner, drm, max_outputs, refresh_millihz, vrr_outputs)?;
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
                forced = forced_rescan,
                "completed frame-boundary DRM topology rescan"
            );
            if changed || forced_rescan {
                apply_hotplug_topology(
                    renderer,
                    allocator,
                    drm_fd,
                    drm,
                    swapchain,
                    scanouts,
                    restore_state,
                    topology,
                    outputs,
                    &active_positions,
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

    Ok(swapchain.current_framebuffer())
}

#[cfg(feature = "flutter")]
fn install_sampled_buffer_releases(
    event_loop: &mut EventLoop<'_, RuntimeState>,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    for (fence, batch) in events.sampled_buffer_releases.drain(..) {
        let Some(fence) = fence else {
            // The raster thread already used glFinish. Drop the guards here so
            // wl_buffer.release remains on the compositor/Wayland thread.
            drop(batch);
            continue;
        };
        let mut batch = Some(batch);
        event_loop.handle().insert_source(
            Generic::new(fence, Interest::READ, PollMode::Level),
            move |_, _, _| {
                // A sync_file becomes readable only after every preceding
                // Flutter sample command has completed on the GPU.
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
            // sync_file readability means the atlas is complete. Wake the
            // compositor and let the scheduler target the following vblank;
            // never occupy KMS's pending slot with unfinished GPU work.
            state.ready_fence_signals.push(signal);
            Ok(PostAction::Remove)
        },
    )?;
    Ok(())
}

#[cfg(feature = "flutter")]
#[allow(clippy::too_many_arguments)]
fn run_flutter_event_loop(
    renderer: &mut GlesRenderer,
    drm: &mut DrmDevice,
    swapchain: &mut AtlasSwapchain,
    scanouts: &mut Vec<Scanout>,
    restore_state: &mut RestoreState,
    drm_scanner: &mut DrmScanner<SimpleCrtcMapper>,
    allocator: &mut GbmAllocator<DrmDeviceFd>,
    drm_fd: &DrmDeviceFd,
    topology: &mut TopologyManager,
    max_outputs: usize,
    refresh_millihz: &BTreeMap<String, u32>,
    vrr_outputs: &BTreeSet<String>,
    positions: &BTreeMap<String, LogicalPoint>,
    wayland: Option<wayland_frontend::WaylandFrontend>,
    flutter: flutter_runtime::FlutterRuntime,
    flutter_launcher: &mut FlutterLauncher,
    duration: Option<Duration>,
    event_loop: &mut EventLoop<'_, RuntimeState>,
) -> Result<framebuffer::Handle, Box<dyn Error>> {
    use smithay::reexports::calloop::channel::{Event as ChannelEvent, sync_channel};

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
    let mut events = RuntimeState {
        wayland,
        system_controls,
        notification_server,
        authentication,
        flutter_active: true,
        flutter_input: flutter_runtime::InputQueue::new(swapchain.size),
        ..RuntimeState::default()
    };
    events.synchronize_flutter_pointer_position();
    let mut raster_frames = 0u64;
    let mut delivered_vsyncs = 0u64;
    let mut retired_output_flips = 0u64;
    let mut retired_repeated_flips = 0u64;
    let mut retired_superseded_ready_frames = 0u64;
    let mut flutter = Some(flutter);
    let mut scheduler = output_scheduler::OutputScheduler::new(
        scanouts,
        swapchain.current,
        swapchain.buffers.len(),
        flutter
            .as_mut()
            .ok_or("Flutter runtime disappeared before output scheduling")?,
        &mut events,
    )?;

    loop {
        service_session_lifecycle(
            drm,
            scanouts,
            swapchain.current_framebuffer(),
            event_loop,
            &mut events,
            deadline,
        )?;
        install_sampled_buffer_releases(event_loop, &mut events)?;
        scheduler.acknowledge_ready_fences(events.ready_fence_signals.drain(..));
        if let Some(reason) = events.lifecycle.shutdown_reason() {
            log_shutdown(reason);
            break;
        }
        if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
            break;
        }
        if events.device_removed {
            return Err("the active DRM device was removed in Flutter event loop".into());
        }

        let scanout_rebased = events.scanout_rebased;
        events.scanout_rebased = false;
        let physical_vsync = if !scanout_rebased {
            scheduler.handle_completions(
                flutter
                    .as_mut()
                    .ok_or("Flutter runtime disappeared during page-flip completion")?,
                swapchain,
                scanouts,
                &mut events,
            )?
        } else {
            None
        };
        if let Some(error) = events.error.take() {
            return Err(format!("DRM event error in Flutter event loop: {error}").into());
        }

        if events.topology_dirty || scanout_rebased {
            events.topology_dirty = false;
            let outputs =
                connected_outputs(drm_scanner, drm, max_outputs, refresh_millihz, vrr_outputs)?;
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
                "completed event-driven DRM topology rescan"
            );
            if changed || scanout_rebased {
                if !scanout_rebased && scheduler.has_pending_scanout_work() {
                    // Finish any ready old-topology atlas before creating the
                    // common rollback point used by the hotplug transaction.
                    // A signalled userspace fence can be submitted now; an
                    // unfinished one will wake this loop through calloop.
                    scheduler.submit_ready(drm, swapchain, scanouts, &mut events)?;
                    events.topology_dirty = true;
                    let now = Instant::now();
                    let timeout = deadline.map_or(Duration::from_millis(50), |deadline| {
                        Duration::from_millis(50).min(deadline.saturating_duration_since(now))
                    });
                    event_loop.dispatch(timeout, &mut events)?;
                    continue;
                }
                if !scanout_rebased {
                    scheduler.converge_for_topology(
                        flutter
                            .as_ref()
                            .ok_or("Flutter runtime disappeared before topology convergence")?,
                        drm,
                        swapchain,
                        scanouts,
                        &mut events,
                    )?;
                }
                retired_output_flips =
                    retired_output_flips.saturating_add(scheduler.presented_frames());
                retired_repeated_flips =
                    retired_repeated_flips.saturating_add(scheduler.repeated_frames());
                retired_superseded_ready_frames = retired_superseded_ready_frames
                    .saturating_add(scheduler.superseded_ready_frames());
                apply_hotplug_topology(
                    renderer,
                    allocator,
                    drm_fd,
                    drm,
                    swapchain,
                    scanouts,
                    restore_state,
                    topology,
                    outputs,
                    positions,
                    raster_frames,
                    event_loop,
                    &mut events,
                    &mut flutter,
                    Some(flutter_launcher),
                )?;
                scheduler = output_scheduler::OutputScheduler::new(
                    scanouts,
                    swapchain.current,
                    swapchain.buffers.len(),
                    flutter
                        .as_mut()
                        .ok_or("Flutter runtime was not restarted after topology change")?,
                    &mut events,
                )?;
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

        if events.flutter_reload_requested {
            if scheduler.has_pending_scanout_work() {
                // Stop servicing the producer while its last atlas reaches
                // every affected CRTC. A ready fence or page flip will wake
                // this loop through calloop, without disturbing clients or
                // the graphical session.
                scheduler.submit_ready(drm, swapchain, scanouts, &mut events)?;
                let now = Instant::now();
                let timeout = deadline.map_or(Duration::from_millis(50), |deadline| {
                    Duration::from_millis(50).min(deadline.saturating_duration_since(now))
                });
                event_loop.dispatch(timeout, &mut events)?;
                continue;
            }

            scheduler.converge_for_topology(
                flutter
                    .as_ref()
                    .ok_or("Flutter runtime disappeared before bundle refresh")?,
                drm,
                swapchain,
                scanouts,
                &mut events,
            )?;
            retired_output_flips =
                retired_output_flips.saturating_add(scheduler.presented_frames());
            retired_repeated_flips =
                retired_repeated_flips.saturating_add(scheduler.repeated_frames());
            retired_superseded_ready_frames =
                retired_superseded_ready_frames.saturating_add(scheduler.superseded_ready_frames());
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
                scanouts,
                swapchain.current,
                swapchain.buffers.len(),
                flutter
                    .as_mut()
                    .ok_or("Flutter runtime was not restarted after bundle refresh")?,
                &mut events,
            )?;
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
        runtime.process_input(&mut events.flutter_input)?;
        // Drain in place so the callback queue keeps its allocation across
        // frame/engine dispatches. AwaitVSync and platform-task traffic is a
        // steady-state hot path and must not rebuild this Vec every time.
        runtime.process_events(events.flutter_events.drain(..))?;
        synchronize_authentication_boundary(&mut events);
        synchronize_system_control_events(runtime, &mut events)?;
        synchronize_notification_events(runtime, &mut events)?;
        synchronize_system_bar_configuration(runtime, &mut events, Some(flutter_launcher));
        synchronize_flutter_window_management(runtime, &mut events)?;
        synchronize_flutter_scene(runtime, &mut events)?;
        synchronize_flutter_input_layout(runtime, &mut events);
        synchronize_wayland_cursor(runtime, &mut events)?;
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

        if let Some(ready) = runtime.take_ready() {
            if let Some(watch) = scheduler.publish_ready(runtime, ready, scanouts)? {
                install_ready_fence_watch(event_loop, watch)?;
            }
            raster_frames = raster_frames.saturating_add(1);
        }
        scheduler.submit_ready(drm, swapchain, scanouts, &mut events)?;
        scheduler.ensure_output_pulses(runtime, drm, swapchain, scanouts, &mut events)?;
        // The C++ scheduler first retires the physical edge, releases client
        // frame callbacks, and arms the following output commit. Only then
        // does it hand Flutter the timestamped pulse for the next producer
        // transaction. Keeping that order prevents Flutter from running one
        // frame ahead of an atlas which was still merely READY.
        if let Some(physical_vsync) = physical_vsync
            && runtime.deliver_physical_vsync(
                physical_vsync.interval,
                physical_vsync.observed_at,
                physical_vsync.presented_at,
            )?
        {
            delivered_vsyncs = delivered_vsyncs.saturating_add(1);
        }

        let next_dispatch_timeout = runtime.next_dispatch_timeout();
        let dispatch_timeout = if let Some(deadline) = deadline {
            let now = Instant::now();
            if now >= deadline {
                break;
            }
            next_dispatch_timeout.min(deadline.saturating_duration_since(now))
        } else {
            next_dispatch_timeout
        };
        event_loop.dispatch(dispatch_timeout, &mut events)?;
    }

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
        // A real login session hands KMS ownership back to SDDM. Restoring
        // the framebuffer captured before Denial started is both unnecessary
        // and dangerous here: an atomic commit can wait forever on a fence
        // owned by the compositor which is currently tearing down. Finite KMS
        // tests still restore their captured state after a successful drain.
        duration.is_none(),
    );

    let deferred_physical_vsyncs = flutter
        .as_ref()
        .map_or(0, flutter_runtime::FlutterRuntime::deferred_physical_vsyncs);
    flutter
        .take()
        .ok_or("Flutter runtime disappeared during orderly shutdown")?
        .shutdown()
        .map_err(|error| format!("Flutter engine shutdown failed: {error}"))?;

    let elapsed = started.elapsed();
    let output_page_flips = retired_output_flips.saturating_add(scheduler.presented_frames());
    let repeated_output_page_flips =
        retired_repeated_flips.saturating_add(scheduler.repeated_frames());
    let superseded_ready_frames =
        retired_superseded_ready_frames.saturating_add(scheduler.superseded_ready_frames());
    info!(
        raster_frames,
        output_page_flips,
        repeated_output_page_flips,
        superseded_ready_frames,
        deferred_physical_vsyncs,
        delivered_vsyncs,
        elapsed_ms = elapsed.as_secs_f64() * 1_000.0,
        raster_frames_per_second = raster_frames as f64 / elapsed.as_secs_f64(),
        finite = duration.is_some(),
        "independently clocked Flutter KMS session complete"
    );
    Ok(swapchain.current_framebuffer())
}

#[cfg(feature = "flutter")]
#[allow(clippy::too_many_arguments)]
fn reload_flutter_runtime(
    renderer: &mut GlesRenderer,
    swapchain: &AtlasSwapchain,
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
        synchronize_authentication_boundary(events);
        synchronize_system_control_events(&mut old_runtime, events)?;
        synchronize_system_bar_configuration(&mut old_runtime, events, Some(flutter_launcher));
        synchronize_flutter_window_management(&mut old_runtime, events)?;
        synchronize_flutter_input_layout(&mut old_runtime, events);
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

    *flutter = Some(flutter_launcher.start(renderer, swapchain, scanouts, &snapshot, &atlas)?);
    events.flutter_input.resize(swapchain.size);
    if let Some(frontend) = events.wayland.as_mut() {
        frontend.reset_flutter_input_generation();
    }
    events.synchronize_flutter_pointer_position();
    events.flutter_channel_closed = false;
    events.scene_sync.invalidate_runtime();
    events.published_window_ids.clear();
    events.pending_window_events.clear();
    events.pending_unpublished_window_events.clear();
    if let Some(frontend) = events.wayland.as_ref() {
        events
            .pending_window_events
            .extend(frontend.replay_window_state_events());
    }
    Ok(())
}

#[cfg(feature = "flutter")]
#[allow(clippy::too_many_arguments)]
fn quiesce_flutter_page_flips(
    runtime: &mut flutter_runtime::FlutterRuntime,
    scheduler: &mut output_scheduler::OutputScheduler,
    drm: &mut DrmDevice,
    swapchain: &mut AtlasSwapchain,
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
        if let Err(error) = service_session_lifecycle(
            drm,
            scanouts,
            swapchain.current_framebuffer(),
            event_loop,
            events,
            Some(deadline),
        ) {
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
        if let Err(error) =
            scheduler.retire_completions_for_shutdown(runtime, swapchain, scanouts, events)
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
        // Closing a full SDDM/UWSM compositor session is an ownership handoff,
        // not a temporary KMS experiment. Release the device before Flutter
        // destroys its contexts and buffers; SDDM will establish its own mode
        // when logind activates it. KmsContext::restore_once observes the
        // inactive device and deliberately skips every blocking atomic ioctl.
        drm.pause();
        info!("released DRM master for graphical-session handoff");
    }
}

#[cfg(feature = "flutter")]
// The wait loop coordinates independent Flutter, DRM, calloop, and launcher
// state; keeping those borrows explicit is clearer than hiding them in a
// single-use context wrapper.
#[allow(clippy::too_many_arguments)]
fn wait_for_flutter_frame(
    runtime: &mut flutter_runtime::FlutterRuntime,
    frame_number: u64,
    drm: &mut DrmDevice,
    scanouts: &[Scanout],
    framebuffer: framebuffer::Handle,
    event_loop: &mut EventLoop<'_, RuntimeState>,
    events: &mut RuntimeState,
    mut flutter_launcher: Option<&mut FlutterLauncher>,
) -> Result<Option<flutter_runtime::ReadyFrame>, Box<dyn Error>> {
    let timeout = if frame_number == 1 {
        Duration::from_secs(15)
    } else {
        Duration::from_secs(3)
    };
    let deadline = Instant::now() + timeout;

    loop {
        service_session_lifecycle(
            drm,
            scanouts,
            framebuffer,
            event_loop,
            events,
            Some(deadline),
        )?;
        install_sampled_buffer_releases(event_loop, events)?;
        if let Some(reason) = events.lifecycle.shutdown_reason() {
            log_shutdown(reason);
            return Ok(None);
        }
        if events.device_removed {
            return Err("the active DRM device was removed while waiting for Flutter".into());
        }
        if !events.lifecycle.seat_active() {
            return Err(format!(
                "timed out after {timeout:?} waiting for the KMS seat while awaiting Flutter frame {frame_number}"
            )
            .into());
        }
        runtime.process_input(&mut events.flutter_input)?;
        runtime.process_events(events.flutter_events.drain(..))?;
        synchronize_authentication_boundary(events);
        synchronize_system_control_events(runtime, events)?;
        synchronize_notification_events(runtime, events)?;
        synchronize_system_bar_configuration(runtime, events, flutter_launcher.as_deref_mut());
        synchronize_flutter_window_management(runtime, events)?;
        synchronize_flutter_scene(runtime, events)?;
        synchronize_flutter_input_layout(runtime, events);
        synchronize_wayland_cursor(runtime, events)?;
        if let Some(index) = runtime.take_ready() {
            return Ok(Some(index));
        }
        if events.flutter_channel_closed {
            return Err("Flutter callback channel closed while the engine was running".into());
        }
        if let Some(error) = events.error.take() {
            return Err(format!("DRM event error while waiting for Flutter: {error}").into());
        }

        let now = Instant::now();
        if now >= deadline {
            return Err(format!(
                "timed out after {timeout:?} waiting for Flutter raster frame {frame_number}"
            )
            .into());
        }
        let dispatch_timeout = runtime
            .next_dispatch_timeout()
            .min(deadline.saturating_duration_since(now));
        event_loop.dispatch(dispatch_timeout, events)?;
    }
}

#[cfg(feature = "flutter")]
fn synchronize_flutter_scene(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    let Some(revision) = events.scene_sync.pending_revision() else {
        return Ok(());
    };
    let Some(frontend) = events.wayland.as_ref() else {
        return Ok(());
    };
    // Building the live-ID set walks every toplevel. It is only needed to
    // classify events which arrived before their first renderable buffer;
    // the steady-state scene publication normally has none.
    let live_window_ids = (!events.pending_unpublished_window_events.is_empty())
        .then(|| frontend.live_toplevel_ids());
    let (windows, textures) = events
        .wayland
        .as_mut()
        .expect("Wayland frontend was present above")
        .flutter_scene()?;
    let flutter_runtime::SyncedWaylandScene {
        windows,
        textures,
        window_snapshot_changed,
    } = runtime.sync_wayland_scene(windows, textures)?;
    if window_snapshot_changed {
        // Buffer-only revisions leave WireBridge's metadata snapshot equal.
        // Rehash IDs only when that authoritative snapshot actually changes.
        let mut published_window_ids = std::mem::take(&mut events.published_window_ids);
        published_window_ids.clear();
        published_window_ids.extend(runtime.synced_window_ids());
        events.published_window_ids = published_window_ids;
    }
    events
        .wayland
        .as_mut()
        .expect("Wayland frontend cannot disappear while synchronizing")
        .recycle_flutter_scene(windows, textures);
    // A later Wayland commit has a newer revision, so acknowledging this
    // captured revision cannot erase work that arrived while Flutter/KMS was
    // processing the previous frame.
    events.scene_sync.mark_synchronized(revision);
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
) {
    let Some(layout) = runtime.take_input_layout_update() else {
        return;
    };
    let Some(frontend) = events.wayland.as_mut() else {
        return;
    };
    let (previous, sampling_changed) = frontend.install_input_layout(layout);
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
}

#[cfg(feature = "flutter")]
fn synchronize_wayland_cursor(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    let Some(shape) = events
        .wayland
        .as_mut()
        .and_then(wayland_frontend::WaylandFrontend::take_cursor_shape_update)
    else {
        return Ok(());
    };
    runtime.send_cursor_shape(shape)
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
    if locked {
        events.pending_shell_actions.clear();
    } else if let Some(authentication) = events.authentication.as_ref() {
        authentication.acknowledge_unlocked_boundary();
    }
    events.scene_sync.mark_dirty();
    info!(locked, "Denial native session security state changed");
}

#[cfg(feature = "flutter")]
fn synchronize_system_control_events(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    let requests = runtime.drain_audio_requests().collect::<Vec<_>>();
    let Some(controls) = events.system_controls.as_ref() else {
        return Ok(());
    };
    if !events.secure_session_locked() {
        for request in requests {
            controls.handle_audio_request(request);
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
fn synchronize_flutter_window_management(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    if events.secure_session_locked() {
        events.pending_shell_actions.clear();
        runtime.drain_window_commands().for_each(drop);
    } else {
        while let Some((action, monitor_id)) = events.pending_shell_actions.pop_front() {
            runtime.send_shell_action(action, monitor_id)?;
        }
        wayland_frontend::apply_window_commands(events, runtime.drain_window_commands());
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

#[allow(clippy::too_many_arguments)]
fn apply_hotplug_topology(
    renderer: &mut GlesRenderer,
    allocator: &mut GbmAllocator<DrmDeviceFd>,
    drm_fd: &DrmDeviceFd,
    drm: &mut DrmDevice,
    swapchain: &mut AtlasSwapchain,
    scanouts: &mut Vec<Scanout>,
    restore_state: &mut RestoreState,
    topology: &mut TopologyManager,
    outputs: Vec<ConnectedOutput>,
    positions: &BTreeMap<String, LogicalPoint>,
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
    let snapshot = update_topology_for_outputs(&mut staged_topology, &outputs, positions)?;
    let atlas = AtlasPlan::for_snapshot(&snapshot).ok_or("hotplug topology produced no atlas")?;
    let pool_length = 2;
    #[cfg(feature = "flutter")]
    let pool_length = if flutter.is_some() {
        flutter_pool_length(outputs.len())?
    } else {
        pool_length
    };
    let old_framebuffer = swapchain.current_framebuffer();
    let old_snapshot = topology.snapshot();
    let mut progress = HotplugProgress::default();
    let reconciliation = reconcile_scanouts(drm, scanouts, restore_state, outputs, &atlas)?;
    let atlas_modifiers = match shared_atlas_modifiers(
        reconciliation.scanouts(),
        renderer.egl_context().dmabuf_render_formats(),
    ) {
        Ok(modifiers) => modifiers,
        Err(error) => {
            let failures =
                rollback_hotplug_scanouts(reconciliation, old_framebuffer, &mut progress, events);
            return Err(hotplug_transaction_error(error.to_string(), failures));
        }
    };
    let mut staged = match AtlasSwapchain::allocate_pool(
        allocator,
        drm_fd,
        atlas.pixel_size,
        pool_length,
        &atlas_modifiers,
    ) {
        Ok(staged) => staged,
        Err(error) => {
            let failures =
                rollback_hotplug_scanouts(reconciliation, old_framebuffer, &mut progress, events);
            return Err(hotplug_transaction_error(error.to_string(), failures));
        }
    };

    if let Err(error) = render_atlas(
        renderer,
        &mut staged.buffers[staged.current].dmabuf,
        staged.size,
        reconciliation.scanouts(),
        frame_number,
    ) {
        let failures =
            rollback_hotplug_scanouts(reconciliation, old_framebuffer, &mut progress, events);
        return Err(hotplug_transaction_error(error.to_string(), failures));
    }
    let framebuffer = staged.current_framebuffer();
    for candidate in reconciliation.scanouts() {
        let output_name = candidate.output.name.clone();
        if let Err(error) = candidate
            .surface
            .test_state([plane_state(candidate, framebuffer)], true)
        {
            let failures =
                rollback_hotplug_scanouts(reconciliation, old_framebuffer, &mut progress, events);
            return Err(hotplug_transaction_error(
                format!("{output_name} TEST_ONLY failed: {error}"),
                failures,
            ));
        }
    }
    progress.mark_validated();

    events.pending.clear();
    for candidate in reconciliation.scanouts() {
        if let Err(error) = candidate
            .surface
            .commit([plane_state(candidate, framebuffer)], true)
        {
            let output_name = candidate.output.name.clone();
            let failures =
                rollback_hotplug_scanouts(reconciliation, old_framebuffer, &mut progress, events);
            return Err(hotplug_transaction_error(
                format!("{output_name} commit failed: {error}"),
                failures,
            ));
        }
        events.pending.insert(candidate.output.crtc);
        progress.record_commit();
    }

    let old_size = swapchain.size;
    if let Err(error) = wait_for_page_flips(
        drm,
        reconciliation.scanouts(),
        framebuffer,
        event_loop,
        events,
    ) {
        let failures =
            rollback_hotplug_scanouts(reconciliation, old_framebuffer, &mut progress, events);
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
            synchronize_authentication_boundary(events);
            synchronize_system_control_events(&mut old_runtime, events)?;
            synchronize_system_bar_configuration(
                &mut old_runtime,
                events,
                flutter_launcher.as_deref_mut(),
            );
            synchronize_flutter_window_management(&mut old_runtime, events)?;
            synchronize_flutter_input_layout(&mut old_runtime, events);
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
                rollback_hotplug_scanouts(reconciliation, old_framebuffer, &mut progress, events);
            return Err(hotplug_transaction_error(error, failures));
        }
        true
    } else {
        false
    };

    let retired_clear_failures = reconciliation.clear_retired();
    if !retired_clear_failures.is_empty() {
        let mut failures =
            rollback_hotplug_scanouts(reconciliation, old_framebuffer, &mut progress, events);
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
            rollback_hotplug_scanouts(reconciliation, old_framebuffer, &mut progress, events);
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
    let retired = std::mem::replace(swapchain, staged);
    progress.mark_finalized();
    drop(retired_scanouts);

    #[cfg(feature = "flutter")]
    if restart_flutter {
        drop(retired);
        let launcher = flutter_launcher.ok_or("dynamic Flutter topology has no launcher")?;
        *flutter = Some(launcher.start(renderer, swapchain, scanouts, &snapshot, &atlas)?);
        events.flutter_input.resize(swapchain.size);
        if let Some(frontend) = events.wayland.as_mut() {
            frontend.reset_flutter_input_generation();
        }
        events.synchronize_flutter_pointer_position();
        events.flutter_channel_closed = false;
        events.scene_sync.invalidate_runtime();
        events.published_window_ids.clear();
        events.pending_window_events.clear();
        events.pending_unpublished_window_events.clear();
        if let Some(frontend) = events.wayland.as_ref() {
            events
                .pending_window_events
                .extend(frontend.replay_window_state_events());
        }
        info!(
            generation = launcher.generation,
            "restarted Flutter on the reconfigured KMS atlas"
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
        "committed hotplug atlas transaction"
    );
    Ok(())
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

fn rollback_hotplug_scanouts(
    reconciliation: ScanoutReconciliation<'_>,
    old_framebuffer: framebuffer::Handle,
    progress: &mut HotplugProgress,
    events: &mut RuntimeState,
) -> Vec<String> {
    events.pending.clear();
    let hardware = progress.rollback_required();
    let failures = reconciliation.rollback(old_framebuffer, hardware);
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
    framebuffer: framebuffer::Handle,
    event_loop: &mut EventLoop<'_, RuntimeState>,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    let deadline = Instant::now() + Duration::from_secs(2);
    while !events.pending.is_empty() {
        event_loop.dispatch(Duration::from_millis(100), events)?;
        service_session_lifecycle(
            drm,
            scanouts,
            framebuffer,
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
        atlas_plane_request(scanouts, framebuffer, fence),
    )?;
    Ok(())
}

#[cfg(feature = "flutter")]
fn commit_atlas_now(
    drm: &DrmDevice,
    scanouts: &[Scanout],
    framebuffer: framebuffer::Handle,
) -> Result<(), Box<dyn Error>> {
    drm.atomic_commit(
        AtomicCommitFlags::empty(),
        atlas_plane_request(scanouts, framebuffer, None),
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
        atlas_plane_request(scanouts, framebuffer, None),
    )?;
    Ok(())
}

fn atlas_plane_request(
    scanouts: &[Scanout],
    framebuffer: framebuffer::Handle,
    fence: Option<BorrowedFd<'_>>,
) -> AtomicModeReq {
    let mut request = AtomicModeReq::new();
    for scanout in scanouts {
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
        if let Some(property) = properties.in_fence_fd {
            let value = fence
                .map(|fence| (i64::from(fence.as_raw_fd())) as u64)
                .unwrap_or(u64::MAX);
            request.add_raw_property(plane, property, value);
        }
    }
    request
}

fn connected_outputs(
    scanner: &mut DrmScanner<SimpleCrtcMapper>,
    drm: &DrmDevice,
    max_outputs: usize,
    refresh_millihz: &BTreeMap<String, u32>,
    vrr_outputs: &BTreeSet<String>,
) -> Result<Vec<ConnectedOutput>, Box<dyn Error>> {
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
    let mut connected = scanner
        .crtcs()
        .filter(|(connector, _)| connector.state() == connector::State::Connected)
        .map(|(connector, crtc)| (connector.clone(), crtc))
        .collect::<Vec<_>>();

    connected.sort_by_key(|(connector, _)| {
        (
            connector.interface().as_str().to_owned(),
            connector.interface_id(),
        )
    });
    connected.truncate(max_outputs);

    connected
        .into_iter()
        .map(|(connector, crtc)| {
            let name = format!(
                "{}-{}",
                connector.interface().as_str(),
                connector.interface_id()
            );
            let vrr_enabled = vrr_outputs.contains(&name);
            let configured_refresh_millihz = refresh_millihz.get(&name).copied();
            let mode =
                select_native_mode(&connector, configured_refresh_millihz).ok_or_else(|| {
                    configured_refresh_millihz.map_or_else(
                        || format!("{name} has no usable native mode"),
                        |refresh| {
                            format!(
                                "{name} has no native mode compatible with configured {} Hz",
                                refresh / 1_000
                            )
                        },
                    )
                })?;
            let output_mode: OutputMode = mode.into();
            info!(
                output = name,
                crtc = ?crtc,
                width = output_mode.size.w,
                height = output_mode.size.h,
                refresh_millihz = output_mode.refresh,
                configured_refresh_millihz,
                vrr_enabled,
                "connected KMS output"
            );
            Ok(ConnectedOutput {
                id: OutputId(u64::from(u32::from(connector.handle()))),
                name,
                connector: connector.handle(),
                crtc,
                mode,
                vrr_enabled,
            })
        })
        .collect()
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

const CONFIGURED_REFRESH_TOLERANCE_MILLIHZ: u32 = 1_000;

fn select_native_mode(
    connector: &connector::Info,
    configured_refresh_millihz: Option<u32>,
) -> Option<Mode> {
    let preferred = connector
        .modes()
        .iter()
        .find(|mode| mode.mode_type().contains(ModeTypeFlags::PREFERRED))
        .or_else(|| connector.modes().first())?;
    let native_size = preferred.size();

    let native_modes = connector
        .modes()
        .iter()
        .filter(|mode| mode.size() == native_size)
        .filter_map(|mode| {
            let refresh = u32::try_from(OutputMode::from(*mode).refresh).ok()?;
            Some((*mode, refresh))
        })
        .collect::<Vec<_>>();
    let selected_refresh = select_refresh_millihz(
        native_modes.iter().map(|(_, refresh)| *refresh),
        configured_refresh_millihz,
    )?;
    native_modes
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
            .min_by_key(|refresh| (refresh.abs_diff(configured), std::cmp::Reverse(*refresh)))
            .filter(|refresh| refresh.abs_diff(configured) <= CONFIGURED_REFRESH_TOLERANCE_MILLIHZ),
        None => refreshes.max(),
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
    fn configured_refresh_does_not_silently_fall_back_to_another_rate() {
        assert_eq!(
            select_refresh_millihz([60_000, 180_000, 280_000], Some(200_000)),
            None
        );
    }
}

fn topology_for_outputs(
    outputs: &[ConnectedOutput],
    positions: &BTreeMap<String, LogicalPoint>,
) -> Result<TopologyManager, Box<dyn Error>> {
    Ok(TopologyManager::new(output_specs(outputs, positions)?)?)
}

fn update_topology_for_outputs(
    topology: &mut TopologyManager,
    outputs: &[ConnectedOutput],
    positions: &BTreeMap<String, LogicalPoint>,
) -> Result<TopologySnapshot, Box<dyn Error>> {
    let specs = output_specs(outputs, positions)?;
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
    positions: &BTreeMap<String, LogicalPoint>,
) -> Result<Vec<OutputSpec>, Box<dyn Error>> {
    let mut default_x = 0i32;
    let mut specs = Vec::with_capacity(outputs.len());

    for output in outputs {
        let mode: OutputMode = output.mode.into();
        let width = u32::try_from(mode.size.w)?;
        let height = u32::try_from(mode.size.h)?;
        let position = positions
            .get(&output.name)
            .copied()
            .unwrap_or_else(|| LogicalPoint::new(default_x, 0));
        specs.push(OutputSpec {
            id: output.id,
            name: output.name.clone(),
            position,
            mode: PixelSize::new(width, height),
            scale_120: 120,
            refresh_millihz: u32::try_from(mode.refresh)?,
            transform: OutputTransform::Normal,
        });
        default_x = default_x.max(
            position
                .x
                .checked_add(mode.size.w)
                .ok_or("output layout overflow")?,
        );
    }

    Ok(specs)
}

fn render_atlas(
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

fn plane_state(
    scanout: &Scanout,
    framebuffer: smithay::reexports::drm::control::framebuffer::Handle,
) -> PlaneState<'static> {
    plane_state_for_mode(scanout, framebuffer, scanout.output.mode)
}

fn plane_state_for_mode(
    scanout: &Scanout,
    framebuffer: smithay::reexports::drm::control::framebuffer::Handle,
    mode: Mode,
) -> PlaneState<'static> {
    let (width, height) = mode.size();
    PlaneState {
        handle: scanout.surface.plane(),
        config: Some(PlaneConfig {
            src: Rectangle::<f64, Buffer>::new(
                (scanout.source_rect.x as f64, scanout.source_rect.y as f64).into(),
                (
                    scanout.source_rect.width as f64,
                    scanout.source_rect.height as f64,
                )
                    .into(),
            ),
            dst: Rectangle::<i32, Physical>::from_size(
                (i32::from(width), i32::from(height)).into(),
            ),
            transform: Transform::Normal,
            alpha: 1.0,
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
