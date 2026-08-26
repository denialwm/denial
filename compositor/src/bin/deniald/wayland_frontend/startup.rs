//! Wayland protocol globals, seat construction, and listener startup.

use super::*;

impl WaylandFrontend {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        event_loop: &mut EventLoop<'static, RuntimeState>,
        snapshot: &TopologySnapshot,
        session: LibSeatSession,
        seat_name: &str,
        drm_device: DrmDeviceFd,
        work_area: crate::options::WorkAreaOptions,
        settings: SettingsManager,
        shortcuts: ShortcutManager,
    ) -> Result<Self, Box<dyn Error>> {
        let display = Display::<RuntimeState>::new()?;
        let display_handle = display.handle();
        let loop_handle = event_loop.handle();
        let compositor_state = CompositorState::new::<RuntimeState>(&display_handle);
        let xdg_shell_state = XdgShellState::new::<RuntimeState>(&display_handle);
        let xdg_activation_state = XdgActivationState::new::<RuntimeState>(&display_handle);
        let xwayland_shell_state = XWaylandShellState::new::<RuntimeState>(&display_handle);
        let xwayland_keyboard_grab_state =
            XWaylandKeyboardGrabState::new::<RuntimeState>(&display_handle);
        let relative_pointer_manager_state =
            RelativePointerManagerState::new::<RuntimeState>(&display_handle);
        let pointer_constraints_state =
            PointerConstraintsState::new::<RuntimeState>(&display_handle);
        let viewporter_state = ViewporterState::new::<RuntimeState>(&display_handle);
        let fractional_scale_manager_state =
            FractionalScaleManagerState::new::<RuntimeState>(&display_handle);
        let xdg_decoration_state = XdgDecorationState::new::<RuntimeState>(&display_handle);
        let cursor_shape_state = CursorShapeManagerState::new::<RuntimeState>(&display_handle);
        let tablet_manager_state = TabletManagerState::new::<RuntimeState>(&display_handle);
        let presentation = presentation::PresentationTracker::new(&display_handle);
        #[cfg(feature = "flutter")]
        let idle_inhibitors = IdleInhibitors::new(&display_handle);
        let output_power = OutputPowerManager::new(&display_handle);
        let screencopy = screencopy::ScreencopyManager::new(&display_handle);
        let text_input = TextInputManager::new(&display_handle);
        let input_method = InputMethodManager::new(&display_handle);
        let shm_state = ShmState::new::<RuntimeState>(&display_handle, vec![]);
        let dmabuf_state = DmabufState::new();
        let drm_syncobj_state = if supports_syncobj_eventfd(&drm_device) {
            info!("advertising linux-drm-syncobj-v1 explicit synchronization");
            Some(DrmSyncobjState::new::<RuntimeState>(
                &display_handle,
                drm_device,
            ))
        } else {
            warn!("DRM syncobj eventfd is unavailable; retaining implicit DMA-BUF synchronization");
            None
        };
        let output_manager_state =
            OutputManagerState::new_with_xdg_output::<RuntimeState>(&display_handle);
        let data_device_state = DataDeviceState::new::<RuntimeState>(&display_handle);
        let mut seat_state = SeatState::new();
        let mut seat = seat_state.new_wl_seat(&display_handle, "seat0");
        let keyboard = settings.keyboard();
        let keyboard_layout_names = keyboard.compiled_layout_names()?;
        let xkb_names = keyboard.xkb_names();
        #[cfg(feature = "flutter")]
        let flutter_compose = flutter_compose_state();
        // Supplying every field explicitly makes the compositor configuration
        // independent of XKB_DEFAULT_* inherited from a display manager.
        seat.add_keyboard(
            XkbConfig {
                rules: "evdev",
                model: "pc105",
                layout: &xkb_names.layout,
                variant: &xkb_names.variant,
                options: Some(xkb_names.options),
            },
            i32::try_from(keyboard.repeat_delay_ms)?,
            i32::try_from(keyboard.repeat_rate_hz)?,
        )?;
        seat.add_pointer();
        seat.add_touch();
        let popups = PopupManager::default();
        let mut space = Space::default();

        let logical_bounds = snapshot.logical_bounds.ok_or("Wayland topology is empty")?;
        let desktop_bounds = smithay::utils::Rectangle::new(
            (
                logical_bounds.x.round() as i32,
                logical_bounds.y.round() as i32,
            )
                .into(),
            (
                logical_bounds.width.round().max(1.0) as i32,
                logical_bounds.height.round().max(1.0) as i32,
            )
                .into(),
        );
        let initial_pointer_location = Point::from((
            f64::from(desktop_bounds.loc.x) + f64::from(desktop_bounds.size.w) / 2.0,
            f64::from(desktop_bounds.loc.y) + f64::from(desktop_bounds.size.h) / 2.0,
        ));
        let touch_bounds = snapshot
            .outputs
            .first()
            .map(|output| {
                let rect = output.logical_rect();
                Rectangle::new(
                    (rect.x.round() as i32, rect.y.round() as i32).into(),
                    (
                        rect.width.round().max(1.0) as i32,
                        rect.height.round().max(1.0) as i32,
                    )
                        .into(),
                )
            })
            .unwrap_or(desktop_bounds);
        let touch_transform = snapshot
            .outputs
            .first()
            .map(|output| output.transform)
            .unwrap_or(OutputTransform::Normal);

        let atlas = AtlasPlan::for_snapshot(snapshot).ok_or("Wayland topology has no atlas")?;
        let mut outputs = Vec::with_capacity(snapshot.outputs.len());
        for spec in &snapshot.outputs {
            let capture = atlas
                .outputs
                .iter()
                .find(|output| output.id == spec.id)
                .ok_or("Wayland output is missing from the atlas plan")?;
            let output = Output::new(
                spec.name.clone(),
                PhysicalProperties {
                    size: (0, 0).into(),
                    subpixel: Subpixel::Unknown,
                    make: "Denial".into(),
                    model: spec.name.clone(),
                    serial_number: format!("connector-{}", spec.id.0),
                },
            );
            configure_output(&output, spec)?;
            let global = output.create_global::<RuntimeState>(&display_handle);
            space.map_output(&output, (spec.position.x, spec.position.y));
            outputs.push(WaylandOutput {
                id: spec.id,
                connector: spec.name.clone(),
                transform: spec.transform,
                output,
                global,
                logical_geometry: output_logical_bounds(spec),
                capture_source: Rectangle::from_size(
                    (
                        i32::try_from(capture.pixel_size.width)?,
                        i32::try_from(capture.pixel_size.height)?,
                    )
                        .into(),
                ),
                capture_size: (
                    i32::try_from(capture.pixel_size.width)?,
                    i32::try_from(capture.pixel_size.height)?,
                )
                    .into(),
                powered: true,
                #[cfg(feature = "flutter")]
                presentation_batch: presentation::OutputPresentationBatch::new(),
                #[cfg(feature = "flutter")]
                submitted_this_batch: false,
            });
        }
        let pointer_location = super::scene_input::constrain_pointer_to_outputs(
            initial_pointer_location,
            outputs.iter().map(|output| output.logical_geometry),
        )
        .ok_or("Wayland topology has no pointer-accessible output")?;

        #[cfg(feature = "flutter")]
        let shm_snapshot_budget_bytes =
            shm_cache_budget_for_atlas(atlas.pixel_size.width, atlas.pixel_size.height);
        let atlas_mode = Mode {
            size: (
                i32::try_from(atlas.pixel_size.width)?,
                i32::try_from(atlas.pixel_size.height)?,
            )
                .into(),
            refresh: snapshot
                .outputs
                .iter()
                .map(|output| output.refresh_millihz)
                .max()
                .map(i32::try_from)
                .transpose()?
                .unwrap_or(60_000),
        };
        let atlas_output = Output::new(
            "denial-atlas".into(),
            PhysicalProperties {
                size: (0, 0).into(),
                subpixel: Subpixel::Unknown,
                make: "Denial".into(),
                model: "Shared scene atlas".into(),
                serial_number: "internal".into(),
            },
        );
        atlas_output.change_current_state(
            Some(atlas_mode),
            Some(Transform::Normal),
            Some(Scale::Fractional(
                atlas.engine_scale_120 as f64 / denial_core::topology::SCALE_BASE as f64,
            )),
            Some(
                (
                    atlas.logical_origin.0.round() as i32,
                    atlas.logical_origin.1.round() as i32,
                )
                    .into(),
            ),
        );
        atlas_output.set_preferred(atlas_mode);
        space.map_output(
            &atlas_output,
            (
                atlas.logical_origin.0.round() as i32,
                atlas.logical_origin.1.round() as i32,
            ),
        );
        let damage_tracker = OutputDamageTracker::from_output(&atlas_output);
        let atlas_origin = Point::from(atlas.logical_origin);
        let atlas_scale = atlas.engine_scale_120 as f64 / denial_core::topology::SCALE_BASE as f64;
        let atlas_size = Size::from((
            i32::try_from(atlas.pixel_size.width)?,
            i32::try_from(atlas.pixel_size.height)?,
        ));

        let client_budget = Arc::new(WaylandClientBudget::default());
        let socket_name = init_listener(display, event_loop, client_budget)?;
        let xwayland_scale_mode = xwayland::scale_mode_from_environment();
        let xwayland_scale_120 =
            xwayland::scale_for_engine(atlas.engine_scale_120, xwayland_scale_mode);
        let xwayland_dpi = xwayland::dpi(xwayland_scale_120);
        let xwayland_args = ["-dpi".to_owned(), xwayland_dpi.to_string()];
        let (xwayland, xwayland_client) = XWayland::spawn(
            &display_handle,
            None,
            std::iter::empty::<(String, String)>(),
            xwayland_args,
            true,
            Stdio::null(),
            Stdio::null(),
            |_| {},
        )?;
        xwayland_client
            .get_data::<XWaylandClientData>()
            .expect("Xwayland client is missing compositor state")
            .compositor_state
            .set_client_scale(xwayland::client_scale(xwayland_scale_120));
        let xdisplay = xwayland.display_number();
        let window_placement_path = default_state_path();
        let window_placements = match WindowPlacementStore::load(window_placement_path.clone()) {
            Ok(store) => store,
            Err(error) => {
                warn!(
                    %error,
                    path = ?window_placement_path,
                    "could not load saved window placements; starting with an empty store"
                );
                WindowPlacementStore::empty(window_placement_path)
            }
        };
        if window_placements.len() > 0 {
            info!(
                placements = window_placements.len(),
                "loaded saved window placements"
            );
        }
        let xwm_loop_handle = event_loop.handle();
        let xwm_display_handle = display_handle.clone();
        let xwm_client = xwayland_client.clone();
        event_loop
            .handle()
            .insert_source(xwayland, move |event, _, state| match event {
                XWaylandEvent::Ready {
                    x11_socket,
                    display_number,
                } => match X11Wm::start_wm(
                    xwm_loop_handle.clone(),
                    &xwm_display_handle,
                    x11_socket,
                    xwm_client.clone(),
                ) {
                    Ok(mut xwm) => {
                        let Some(frontend) = state.wayland.as_mut() else {
                            error!(
                                display_number,
                                "Xwayland became ready without Wayland frontend state"
                            );
                            return;
                        };
                        if let Err(error) =
                            xwayland::publish_dpi(&mut xwm, frontend.xwayland_scale_120)
                        {
                            error!(%error, "could not publish Xwayland DPI settings");
                        }
                        frontend.xwm = Some(xwm);
                        match super::super::xembed_tray::XEmbedTray::start(frontend.xdisplay_name())
                        {
                            Ok(tray) => frontend.xembed_tray = Some(tray),
                            Err(error) => {
                                warn!(%error, "could not start the XEmbed tray host")
                            }
                        }
                        info!(
                            display = %format_args!(":{display_number}"),
                            scale = xwayland::client_scale(frontend.xwayland_scale_120),
                            scale_mode = ?frontend.xwayland_scale_mode,
                            dpi = xwayland::dpi(frontend.xwayland_scale_120),
                            "Xwayland is ready"
                        );
                        state.scene_sync.mark_dirty();
                    }
                    Err(error) => {
                        error!(
                            %error,
                            display_number,
                            "could not start the Xwayland window manager"
                        );
                    }
                },
                XWaylandEvent::Error => {
                    error!(
                        display = %format_args!(":{xdisplay}"),
                        "Xwayland exited during startup"
                    );
                }
            })?;
        init_libinput(event_loop, session, seat_name)?;
        Ok(Self {
            start_time: Instant::now(),
            socket_name,
            loop_handle,
            display_handle,
            space,
            compositor_state,
            xdg_shell_state,
            xdg_activation_state,
            xwayland_shell_state,
            _xwayland_keyboard_grab_state: xwayland_keyboard_grab_state,
            _relative_pointer_manager_state: relative_pointer_manager_state,
            _pointer_constraints_state: pointer_constraints_state,
            _viewporter_state: viewporter_state,
            _fractional_scale_manager_state: fractional_scale_manager_state,
            xwm: None,
            #[cfg(feature = "flutter")]
            xembed_tray: None,
            xwayland_client,
            xwayland_scale_mode,
            xwayland_scale_120,
            xdisplay,
            _xdg_decoration_state: xdg_decoration_state,
            _cursor_shape_state: cursor_shape_state,
            _tablet_manager_state: tablet_manager_state,
            shm_state,
            dmabuf_state,
            drm_syncobj_state,
            dmabuf_global: None,
            dmabuf_render_node: None,
            pending_dmabuf_imports: Vec::new(),
            dmabuf_import_queue_saturated: false,
            surface_buffers: HashMap::new(),
            #[cfg(feature = "flutter")]
            surface_shm_frames: HashMap::new(),
            #[cfg(feature = "flutter")]
            shm_snapshot_pool: Arc::new(ShmSnapshotPool::new()),
            #[cfg(feature = "flutter")]
            shm_snapshot_bytes: 0,
            #[cfg(feature = "flutter")]
            shm_snapshot_budget_bytes,
            #[cfg(feature = "flutter")]
            next_shm_revision: 1,
            #[cfg(feature = "flutter")]
            pending_surface_commits: HashMap::new(),
            #[cfg(feature = "flutter")]
            committed_surfaces_scratch: Vec::new(),
            #[cfg(feature = "flutter")]
            published_surface_ids_scratch: Vec::new(),
            #[cfg(feature = "flutter")]
            scene_windows_scratch: Vec::new(),
            #[cfg(feature = "flutter")]
            scene_textures_scratch: Vec::new(),
            #[cfg(feature = "flutter")]
            scene_popups_scratch: Vec::new(),
            #[cfg(feature = "flutter")]
            scene_surface_windows: HashMap::new(),
            #[cfg(feature = "flutter")]
            scene_surface_windows_scratch: HashMap::new(),
            #[cfg(feature = "flutter")]
            scene_complex_windows: HashSet::new(),
            #[cfg(feature = "flutter")]
            scene_complex_windows_scratch: HashSet::new(),
            window_membership_scratch: Vec::new(),
            #[cfg(feature = "flutter")]
            output_window_membership: OutputWindowMembership::default(),
            #[cfg(feature = "flutter")]
            pending_frame_callback_windows: HashSet::new(),
            #[cfg(feature = "flutter")]
            pending_input_method_frame_callbacks: HashSet::new(),
            #[cfg(feature = "flutter")]
            local_windows: LocalFlutterWindows::default(),
            #[cfg(feature = "flutter")]
            pending_shm_snapshots: HashSet::new(),
            #[cfg(feature = "flutter")]
            surface_buffer_revisions: HashMap::new(),
            #[cfg(feature = "flutter")]
            next_buffer_revision: 1,
            surface_ids: HashMap::new(),
            surfaces_by_id: HashMap::new(),
            next_surface_id: 1,
            configured_window_geometries: HashMap::new(),
            exact_window_geometries: HashMap::new(),
            restore_window_geometries: HashMap::new(),
            #[cfg(feature = "flutter")]
            shell_maximize_restore_geometries: HashMap::new(),
            #[cfg(feature = "flutter")]
            shell_fullscreen_restore_geometries: HashMap::new(),
            #[cfg(feature = "flutter")]
            shell_vertical_restore_geometries: HashMap::new(),
            #[cfg(feature = "flutter")]
            local_vertical_restore_geometries: HashMap::new(),
            #[cfg(feature = "flutter")]
            input_layout: None,
            #[cfg(feature = "flutter")]
            shell_fullscreen_locks: HashSet::new(),
            #[cfg(feature = "flutter")]
            visible_window_ids: HashSet::new(),
            #[cfg(feature = "flutter")]
            input_root_ids: HashMap::new(),
            #[cfg(feature = "flutter")]
            input_visibility_known: false,
            #[cfg(feature = "flutter")]
            client_input_route_cache: None,
            #[cfg(feature = "flutter")]
            client_pointer_capture: None,
            #[cfg(feature = "flutter")]
            pointer_constraint_escape: input::PointerConstraintEscape::default(),
            #[cfg(feature = "flutter")]
            client_pointer_buttons: HashSet::new(),
            #[cfg(feature = "flutter")]
            retired_pointer_buttons: HashSet::new(),
            #[cfg(feature = "flutter")]
            client_pointer_presses: Vec::new(),
            #[cfg(feature = "flutter")]
            flutter_pointer_press: None,
            #[cfg(feature = "flutter")]
            clipboard_drag_active: false,
            wayland_pointer_buttons: HashSet::new(),
            #[cfg(feature = "flutter")]
            routed_pointer_target: RoutedPointerTarget::Flutter,
            #[cfg(feature = "flutter")]
            pointer_cursor_visible: false,
            #[cfg(feature = "flutter")]
            pending_cursor_shape: Some("none"),
            #[cfg(feature = "flutter")]
            published_cursor_shape: None,
            #[cfg(feature = "flutter")]
            pending_cursor_position: None,
            #[cfg(feature = "flutter")]
            flutter_touch_slots: HashSet::new(),
            #[cfg(feature = "flutter")]
            client_touch_routes: HashMap::new(),
            #[cfg(feature = "flutter")]
            client_touch_frame_pending: false,
            #[cfg(feature = "flutter")]
            touch_gestures: touch_gestures::TouchGestureState::default(),
            #[cfg(feature = "flutter")]
            flutter_keyboard_keys: HashSet::new(),
            #[cfg(feature = "flutter")]
            flutter_input_method_keys: HashSet::new(),
            #[cfg(feature = "flutter")]
            shell_keyboard_keys: HashSet::new(),
            #[cfg(feature = "flutter")]
            flutter_compose,
            #[cfg(feature = "flutter")]
            flutter_repeat_key: None,
            #[cfg(feature = "flutter")]
            flutter_repeat_generation: 0,
            #[cfg(feature = "flutter")]
            flutter_repeat_token: None,
            retired_keyboard_keys: HashSet::new(),
            #[cfg(feature = "flutter")]
            retired_input_method_keys: HashSet::new(),
            #[cfg(feature = "flutter")]
            minimized_windows: HashSet::new(),
            window_placements,
            restored_window_positions: HashSet::new(),
            client_geometry_state_requests: HashSet::new(),
            pending_client_sized_placements: HashMap::new(),
            _output_manager_state: output_manager_state,
            seat_state,
            data_device_state,
            popups,
            seat,
            settings,
            shortcuts,
            keyboard_layout_names,
            active_keyboard_layout: 0,
            keyboard_configuration_changed: false,
            presentation,
            #[cfg(feature = "flutter")]
            idle_inhibitors,
            #[cfg(feature = "flutter")]
            idle_inhibition_dirty: true,
            #[cfg(feature = "flutter")]
            idle_inhibition_cached: false,
            output_power,
            screencopy,
            text_input,
            input_method,
            outputs,
            work_area,
            ticker_output: snapshot.ticker,
            atlas_output,
            damage_tracker,
            next_window_offset: 48,
            desktop_bounds,
            touch_bounds,
            touch_transform,
            tablet_output_mappings: HashMap::new(),
            pointer_location,
            cursor_status: CursorImageStatus::default_named(),
            atlas_origin,
            atlas_scale,
            atlas_size,
        })
    }
}
