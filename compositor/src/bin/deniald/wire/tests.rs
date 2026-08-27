//! Protocol boundary tests and malformed-input corpus.

use super::*;
use denial_core::topology::{
    LogicalPoint, OutputSpec, OutputTransform, PixelSize, TopologyManager,
};

fn bridge() -> WireBridge {
    let topology = TopologyManager::new([
        OutputSpec {
            id: OutputId(7),
            name: "left".into(),
            position: LogicalPoint::new(-1920, 0),
            mode: PixelSize::new(1920, 1080),
            scale_120: 120,
            refresh_millihz: 60_000,
            transform: OutputTransform::Normal,
        },
        OutputSpec {
            id: OutputId(9),
            name: "main".into(),
            position: LogicalPoint::new(0, 0),
            mode: PixelSize::new(2560, 1440),
            scale_120: 120,
            refresh_millihz: 180_000,
            transform: OutputTransform::Normal,
        },
    ])
    .unwrap();
    let snapshot = topology.snapshot();
    let atlas = AtlasPlan::for_snapshot(&snapshot).unwrap();
    WireBridge::new(&snapshot, &atlas, WorkAreaOptions::default()).unwrap()
}

fn request(kind: fb::WindowRequestKind, request_id: u64) -> Vec<u8> {
    window_request(kind, request_id, 0, None)
}

fn theme_state(accent_srgb: u32, request_id: u64) -> Vec<u8> {
    let mut builder = FlatBufferBuilder::new();
    let theme = fb::ThemeState::create(&mut builder, &fb::ThemeStateArgs { accent_srgb });
    let envelope = fb::Envelope::create(
        &mut builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence: 4,
            request_id,
            payload_type: fb::Payload::ThemeState,
            payload: Some(theme.as_union_value()),
        },
    );
    fb::finish_envelope_buffer(&mut builder, envelope);
    builder.finished_data().to_vec()
}

fn window_request(
    kind: fb::WindowRequestKind,
    request_id: u64,
    window_id: u64,
    geometry: Option<fb::WireRect>,
) -> Vec<u8> {
    window_request_with_sequence(kind, request_id, window_id, geometry, 4)
}

fn window_request_with_sequence(
    kind: fb::WindowRequestKind,
    request_id: u64,
    window_id: u64,
    geometry: Option<fb::WireRect>,
    sequence: u64,
) -> Vec<u8> {
    let mut builder = FlatBufferBuilder::new();
    let request = fb::WindowRequest::create(
        &mut builder,
        &fb::WindowRequestArgs {
            kind,
            window_id,
            geometry: geometry.as_ref(),
            app_id: None,
            title: None,
            ..Default::default()
        },
    );
    let envelope = fb::Envelope::create(
        &mut builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence,
            request_id,
            payload_type: fb::Payload::WindowRequest,
            payload: Some(request.as_union_value()),
        },
    );
    fb::finish_envelope_buffer(&mut builder, envelope);
    builder.finished_data().to_vec()
}

fn exact_window_request(window_id: u64, geometry: fb::WireRect) -> Vec<u8> {
    let mut builder = FlatBufferBuilder::new();
    let request = fb::WindowRequest::create(
        &mut builder,
        &fb::WindowRequestArgs {
            kind: fb::WindowRequestKind::ConfigureWindow,
            window_id,
            geometry: Some(&geometry),
            flags: 1,
            ..Default::default()
        },
    );
    let envelope = fb::Envelope::create(
        &mut builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence: 4,
            request_id: 0,
            payload_type: fb::Payload::WindowRequest,
            payload: Some(request.as_union_value()),
        },
    );
    fb::finish_envelope_buffer(&mut builder, envelope);
    builder.finished_data().to_vec()
}

fn create_local_window_request(
    request_id: u64,
    app_id: &str,
    title: &str,
    geometry: fb::WireRect,
) -> Vec<u8> {
    let mut builder = FlatBufferBuilder::new();
    let app_id = builder.create_string(app_id);
    let title = builder.create_string(title);
    let request = fb::WindowRequest::create(
        &mut builder,
        &fb::WindowRequestArgs {
            kind: fb::WindowRequestKind::CreateLocalWindow,
            window_id: 0,
            geometry: Some(&geometry),
            app_id: Some(app_id),
            title: Some(title),
            ..Default::default()
        },
    );
    let envelope = fb::Envelope::create(
        &mut builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence: 4,
            request_id,
            payload_type: fb::Payload::WindowRequest,
            payload: Some(request.as_union_value()),
        },
    );
    fb::finish_envelope_buffer(&mut builder, envelope);
    builder.finished_data().to_vec()
}

fn configure_system_bar_request(
    request_id: u64,
    side: fb::SystemBarSide,
    monitor_ids: &[i64],
) -> Vec<u8> {
    let mut builder = FlatBufferBuilder::new();
    let monitor_ids = builder.create_vector(monitor_ids);
    let request = fb::WindowRequest::create(
        &mut builder,
        &fb::WindowRequestArgs {
            kind: fb::WindowRequestKind::ConfigureSystemBar,
            system_bar_side: side,
            system_bar_monitor_ids: Some(monitor_ids),
            ..Default::default()
        },
    );
    let envelope = fb::Envelope::create(
        &mut builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence: 5,
            request_id,
            payload_type: fb::Payload::WindowRequest,
            payload: Some(request.as_union_value()),
        },
    );
    fb::finish_envelope_buffer(&mut builder, envelope);
    builder.finished_data().to_vec()
}

fn input_layout(
    shell_regions: &[fb::WireRect],
    windows: &[fb::InputWindowRegion],
    flags: u32,
) -> Vec<u8> {
    input_layout_with_visible(shell_regions, windows, &[], flags)
}

fn input_layout_with_visible(
    shell_regions: &[fb::WireRect],
    windows: &[fb::InputWindowRegion],
    visible_surface_ids: &[u64],
    flags: u32,
) -> Vec<u8> {
    let mut builder = FlatBufferBuilder::new();
    let shell_regions = builder.create_vector(shell_regions);
    let windows = builder.create_vector(windows);
    let visible_surface_ids = builder.create_vector(visible_surface_ids);
    let layout = fb::InputLayout::create(
        &mut builder,
        &fb::InputLayoutArgs {
            epoch: 7,
            flags,
            shell_regions: Some(shell_regions),
            windows: Some(windows),
            visible_surface_ids: Some(visible_surface_ids),
            software_keyboard_regions: None,
        },
    );
    let envelope = fb::Envelope::create(
        &mut builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence: 9,
            payload_type: fb::Payload::InputLayout,
            payload: Some(layout.as_union_value()),
            ..Default::default()
        },
    );
    fb::finish_envelope_buffer(&mut builder, envelope);
    builder.finished_data().to_vec()
}

fn keyboard_command(
    kind: fb::KeyboardCommandKind,
    text: Option<&str>,
    key: Option<&str>,
    flags: u32,
) -> Vec<u8> {
    let mut builder = FlatBufferBuilder::new();
    let text = text.map(|value| builder.create_string(value));
    let key = key.map(|value| builder.create_string(value));
    let command = fb::KeyboardCommand::create(
        &mut builder,
        &fb::KeyboardCommandArgs {
            kind,
            text,
            key,
            flags,
        },
    );
    let envelope = fb::Envelope::create(
        &mut builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence: 11,
            payload_type: fb::Payload::KeyboardCommand,
            payload: Some(command.as_union_value()),
            ..Default::default()
        },
    );
    fb::finish_envelope_buffer(&mut builder, envelope);
    builder.finished_data().to_vec()
}

type KeyboardRequest<'a> = (&'a [(&'a str, &'a str)], &'a [&'a str], u32, u32);

fn settings_request(
    kind: fb::SettingsRequestKind,
    request_id: u64,
    expected_revision: u64,
    document: Option<&str>,
    keyboard: Option<KeyboardRequest<'_>>,
) -> Vec<u8> {
    let mut builder = FlatBufferBuilder::new();
    let document = document.map(|value| builder.create_string(value));
    let keyboard = keyboard.map(|(layouts, options, delay, rate)| {
        let layouts = layouts
            .iter()
            .map(|(layout, variant)| {
                let layout = builder.create_string(layout);
                let variant = builder.create_string(variant);
                fb::KeyboardLayout::create(
                    &mut builder,
                    &fb::KeyboardLayoutArgs {
                        layout: Some(layout),
                        variant: Some(variant),
                        display_name: None,
                    },
                )
            })
            .collect::<Vec<_>>();
        let layouts = builder.create_vector(&layouts);
        let options = options
            .iter()
            .map(|option| builder.create_string(option))
            .collect::<Vec<_>>();
        let options = builder.create_vector(&options);
        fb::KeyboardConfiguration::create(
            &mut builder,
            &fb::KeyboardConfigurationArgs {
                layouts: Some(layouts),
                options: Some(options),
                repeat_delay_ms: delay,
                repeat_rate_hz: rate,
                active_layout: 0,
            },
        )
    });
    let request = fb::SettingsRequest::create(
        &mut builder,
        &fb::SettingsRequestArgs {
            kind,
            expected_revision,
            document,
            keyboard,
            ..Default::default()
        },
    );
    let envelope = fb::Envelope::create(
        &mut builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence: 12,
            request_id,
            payload_type: fb::Payload::SettingsRequest,
            payload: Some(request.as_union_value()),
        },
    );
    fb::finish_envelope_buffer(&mut builder, envelope);
    builder.finished_data().to_vec()
}

fn touchpad_settings_request(
    request_id: u64,
    expected_revision: u64,
    tap_to_click_enabled: bool,
    natural_scroll_enabled: bool,
    scroll_speed_factor: f64,
) -> Vec<u8> {
    let mut builder = FlatBufferBuilder::new();
    let touchpad = fb::TouchpadConfiguration::create(
        &mut builder,
        &fb::TouchpadConfigurationArgs {
            tap_to_click_enabled,
            natural_scroll_enabled,
            scroll_speed_factor,
        },
    );
    let request = fb::SettingsRequest::create(
        &mut builder,
        &fb::SettingsRequestArgs {
            kind: fb::SettingsRequestKind::ConfigureTouchpad,
            expected_revision,
            touchpad: Some(touchpad),
            ..Default::default()
        },
    );
    let envelope = fb::Envelope::create(
        &mut builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence: 13,
            request_id,
            payload_type: fb::Payload::SettingsRequest,
            payload: Some(request.as_union_value()),
        },
    );
    fb::finish_envelope_buffer(&mut builder, envelope);
    builder.finished_data().to_vec()
}

fn notification_command(
    kind: fb::DesktopNotificationCommandKind,
    notification_id: u32,
    action_key: Option<&str>,
) -> Vec<u8> {
    let mut builder = FlatBufferBuilder::new();
    let action_key = action_key.map(|value| builder.create_string(value));
    let command = fb::DesktopNotificationCommand::create(
        &mut builder,
        &fb::DesktopNotificationCommandArgs {
            kind,
            notification_id,
            action_key,
        },
    );
    let envelope = fb::Envelope::create(
        &mut builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence: 12,
            payload_type: fb::Payload::DesktopNotificationCommand,
            payload: Some(command.as_union_value()),
            ..Default::default()
        },
    );
    fb::finish_envelope_buffer(&mut builder, envelope);
    builder.finished_data().to_vec()
}

fn xembed_tray_command(kind: fb::XEmbedTrayCommandKind, window_id: u32, x: i32, y: i32) -> Vec<u8> {
    let mut builder = FlatBufferBuilder::new();
    let command = fb::XEmbedTrayCommand::create(
        &mut builder,
        &fb::XEmbedTrayCommandArgs {
            kind,
            window_id,
            x,
            y,
        },
    );
    let envelope = fb::Envelope::create(
        &mut builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence: 14,
            payload_type: fb::Payload::XEmbedTrayCommand,
            payload: Some(command.as_union_value()),
            ..Default::default()
        },
    );
    fb::finish_envelope_buffer(&mut builder, envelope);
    builder.finished_data().to_vec()
}

fn envelope_without_payload(payload_type: fb::Payload) -> Vec<u8> {
    let mut builder = FlatBufferBuilder::new();
    let envelope = fb::Envelope::create(
        &mut builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence: 13,
            payload_type,
            payload: None,
            ..Default::default()
        },
    );
    fb::finish_envelope_buffer(&mut builder, envelope);
    builder.finished_data().to_vec()
}

#[test]
fn answers_window_list_with_an_empty_snapshot() {
    let mut bridge = bridge();
    let bytes = bridge
        .handle(&request(fb::WindowRequestKind::ListWindows, 41))
        .unwrap()
        .unwrap();
    let envelope = fb::root_as_envelope(bytes).unwrap();
    let response = envelope.payload_as_window_response().unwrap();
    assert_eq!(envelope.sequence(), 1);
    assert_eq!(envelope.request_id(), 41);
    assert_eq!(response.kind(), fb::WindowResponseKind::Windows);
    assert!(response.success());
    assert_eq!(response.windows().unwrap().windows().unwrap().len(), 0);
}

#[test]
fn publishes_and_answers_with_the_current_wayland_window() {
    let window = WindowDescription {
        object_id: 11,
        surface_id: 11,
        window_id: 11,
        texture_id: 11,
        title: "Terminal".into(),
        app_id: "foot".into(),
        width: 1120,
        height: 700,
        surface_x: 0.0,
        surface_y: 0.0,
        surface_width: 1120.0,
        surface_height: 700.0,
        texture_source_x: 0.0,
        texture_source_y: 0.0,
        texture_source_width: 1120.0,
        texture_source_height: 700.0,
        geometry_x: 96.0,
        geometry_y: 72.0,
        geometry_width: 1120.0,
        geometry_height: 700.0,
        monitor_id: 9,
        transform: 0,
        scale_120: 120,
        content_x: 0.0,
        content_y: 0.0,
        content_width: 1120.0,
        content_height: 700.0,
        surfaces: vec![
            SurfaceLayerDescription {
                surface_id: 11,
                parent_surface_id: 0,
                popup_root_surface_id: 0,
                role: SurfaceRoleDescription::Root,
                texture_id: 11,
                width: 1120,
                height: 700,
                surface_x: 0.0,
                surface_y: 0.0,
                surface_width: 1120.0,
                surface_height: 700.0,
                texture_source_x: 0.0,
                texture_source_y: 0.0,
                texture_source_width: 1120.0,
                texture_source_height: 700.0,
                transform: 0,
                scale_120: 120,
                composition_order: 0,
                opacity: 1.0,
                opaque: true,
            },
            SurfaceLayerDescription {
                surface_id: 12,
                parent_surface_id: 11,
                popup_root_surface_id: 12,
                role: SurfaceRoleDescription::Popup,
                texture_id: 12,
                width: 280,
                height: 180,
                surface_x: 500.0,
                surface_y: 40.0,
                surface_width: 280.0,
                surface_height: 180.0,
                texture_source_x: 0.0,
                texture_source_y: 0.0,
                texture_source_width: 280.0,
                texture_source_height: 180.0,
                transform: 0,
                scale_120: 120,
                composition_order: 1,
                opacity: 1.0,
                opaque: false,
            },
        ],
        suppress_animations: false,
        server_side_decorated: true,
        opacity: 1.0,
        content_kind: WindowContentKind::SurfaceTree,
        opacity_class: WindowOpacityClass::FullyOpaque,
    };
    let mut bridge = bridge();
    let restored_window_ids = BTreeSet::from([window.window_id]);
    let (update, recycled) = bridge
        .update_windows(1, vec![window.clone()], &restored_window_ids)
        .unwrap();
    assert!(recycled.is_empty());
    let update = update.unwrap();
    let envelope = fb::root_as_envelope(update).unwrap();
    let snapshot = envelope.payload_as_window_snapshot().unwrap();
    let encoded = snapshot.windows().unwrap().get(0);
    assert_eq!(
        snapshot
            .restored_window_ids()
            .unwrap()
            .iter()
            .collect::<Vec<_>>(),
        [11]
    );

    assert_eq!(envelope.sequence(), 1);
    assert_eq!(envelope.request_id(), 0);
    assert_eq!(encoded.object_id(), 11);
    assert_eq!(encoded.texture_id(), 11);
    assert_eq!(encoded.title(), Some("Terminal"));
    assert_eq!(encoded.app_id(), Some("foot"));
    assert_eq!(encoded.geometry_x(), 96.0);
    assert!(!encoded.suppress_animations());
    assert!(encoded.server_side_decorated());
    assert_eq!(encoded.opacity_class(), fb::WindowOpacityClass::FullyOpaque);
    let surfaces = encoded.surfaces().unwrap();
    assert_eq!(surfaces.len(), 2);
    assert_eq!(surfaces.get(0).role(), fb::SurfaceRole::Root);
    assert!(surfaces.get(0).opaque());
    assert_eq!(surfaces.get(1).role(), fb::SurfaceRole::Popup);
    assert!(!surfaces.get(1).opaque());
    assert_eq!(surfaces.get(1).parent_surface_id(), 11);
    let mut misordered = window.clone();
    misordered.surfaces.reverse();
    assert!(matches!(
        validate_windows(&[misordered]),
        Err(WireError::Ordering)
    ));
    assert_eq!(bridge.window_ids().collect::<Vec<_>>(), [11]);
    let (update, unchanged) = bridge
        .update_windows(1, vec![window.clone()], &restored_window_ids)
        .unwrap();
    assert!(update.is_none());
    assert_eq!(unchanged.len(), 1);

    let (update, _) = bridge
        .update_windows(2, vec![window], &BTreeSet::new())
        .unwrap();
    let envelope = fb::root_as_envelope(update.unwrap()).unwrap();
    assert!(
        envelope
            .payload_as_window_snapshot()
            .unwrap()
            .restored_window_ids()
            .unwrap()
            .is_empty()
    );

    let response = bridge
        .handle(&request(fb::WindowRequestKind::ListWindows, 53))
        .unwrap()
        .unwrap();
    let envelope = fb::root_as_envelope(response).unwrap();
    let response = envelope.payload_as_window_response().unwrap();
    assert_eq!(envelope.sequence(), 3);
    assert_eq!(
        response
            .windows()
            .unwrap()
            .windows()
            .unwrap()
            .get(0)
            .window_id(),
        11
    );
}

#[test]
fn display_layout_matches_the_shared_atlas() {
    let mut bridge = bridge();
    let bytes = bridge
        .handle(&request(fb::WindowRequestKind::GetDisplayLayout, 52))
        .unwrap()
        .unwrap();
    let envelope = fb::root_as_envelope(bytes).unwrap();
    let response = envelope.payload_as_window_response().unwrap();
    let layout = response.display_layout().unwrap();
    let outputs = layout.outputs().unwrap();

    assert_eq!(response.kind(), fb::WindowResponseKind::DisplayLayout);
    assert_eq!(layout.global_origin().unwrap().x(), -1920.0);
    assert_eq!(layout.logical_size().unwrap().width(), 4480.0);
    assert_eq!(layout.pixel_size().unwrap().width(), 4480.0);
    assert_eq!(layout.ticker_monitor_id(), 9);
    assert_eq!(layout.system_bar_monitor_id(), 9);
    assert_eq!(layout.system_bar_side(), fb::SystemBarSide::Top);
    assert_eq!(layout.system_bar_thickness(), 32.0);
    assert_eq!(outputs.len(), 2);
    assert_eq!(outputs.get(0).logical_rect().unwrap().x(), 0.0);
    assert_eq!(outputs.get(1).logical_rect().unwrap().x(), 1920.0);
    assert_eq!(outputs.get(1).source_rect().unwrap().x(), 1920.0);
}

#[test]
fn system_bar_resolves_named_outputs_and_hides_cleanly() {
    fn layout_fields(system_bar: SystemBarOptions) -> (i64, Vec<i64>, fb::SystemBarSide, f64, f64) {
        let topology = TopologyManager::new([
            OutputSpec {
                id: OutputId(7),
                name: "left".into(),
                position: LogicalPoint::new(-1920, 0),
                mode: PixelSize::new(1920, 1080),
                scale_120: 120,
                refresh_millihz: 60_000,
                transform: OutputTransform::Normal,
            },
            OutputSpec {
                id: OutputId(9),
                name: "main".into(),
                position: LogicalPoint::new(0, 0),
                mode: PixelSize::new(2560, 1440),
                scale_120: 120,
                refresh_millihz: 180_000,
                transform: OutputTransform::Normal,
            },
        ])
        .unwrap();
        let snapshot = topology.snapshot();
        let atlas = AtlasPlan::for_snapshot(&snapshot).unwrap();
        let mut bridge = WireBridge::new(
            &snapshot,
            &atlas,
            WorkAreaOptions {
                system_bar,
                maximize_padding: 10.0,
            },
        )
        .unwrap();
        let bytes = bridge
            .handle(&request(fb::WindowRequestKind::GetDisplayLayout, 61))
            .unwrap()
            .unwrap();
        let envelope = fb::root_as_envelope(bytes).unwrap();
        let layout = envelope
            .payload_as_window_response()
            .unwrap()
            .display_layout()
            .unwrap();
        (
            layout.system_bar_monitor_id(),
            layout.system_bar_monitor_ids().unwrap().iter().collect(),
            layout.system_bar_side(),
            layout.system_bar_thickness(),
            layout.maximize_padding(),
        )
    }

    let named = layout_fields(SystemBarOptions {
        outputs: vec!["left".to_owned()],
        side: super::SystemBarSide::Bottom,
        thickness: 40.0,
    });
    assert_eq!(named, (7, vec![7], fb::SystemBarSide::Bottom, 40.0, 10.0));

    let absent = layout_fields(SystemBarOptions {
        outputs: vec!["unplugged".to_owned()],
        side: super::SystemBarSide::Top,
        thickness: 32.0,
    });
    assert_eq!(absent, (9, vec![9], fb::SystemBarSide::Top, 32.0, 10.0));

    let hidden = layout_fields(SystemBarOptions::hidden());
    assert_eq!(
        hidden,
        (-1, Vec::new(), fb::SystemBarSide::Hidden, 0.0, 10.0)
    );
}

#[test]
fn configures_cloned_system_bars_as_one_validated_transaction() {
    let mut bridge = bridge();
    let bytes = bridge
        .handle(&configure_system_bar_request(
            62,
            fb::SystemBarSide::Left,
            &[7, 9],
        ))
        .unwrap()
        .unwrap();
    let envelope = fb::root_as_envelope(bytes).unwrap();
    let layout = envelope
        .payload_as_window_response()
        .unwrap()
        .display_layout()
        .unwrap();
    assert_eq!(layout.system_bar_monitor_id(), 9);
    assert_eq!(
        layout
            .system_bar_monitor_ids()
            .unwrap()
            .iter()
            .collect::<Vec<_>>(),
        vec![7, 9]
    );
    assert_eq!(layout.system_bar_side(), fb::SystemBarSide::Left);

    let update = bridge.take_work_area_update().unwrap();
    assert_eq!(update.system_bar.outputs, vec!["left", "main"]);
    assert_eq!(update.system_bar.side, SystemBarSide::Left);
    assert!(bridge.take_work_area_update().is_none());

    for request in [
        configure_system_bar_request(63, fb::SystemBarSide::Top, &[]),
        configure_system_bar_request(64, fb::SystemBarSide::Top, &[7, 7]),
        configure_system_bar_request(65, fb::SystemBarSide::Top, &[77]),
        configure_system_bar_request(66, fb::SystemBarSide::Hidden, &[7]),
    ] {
        assert!(bridge.handle(&request).is_err());
    }
}

#[test]
fn validates_queries_and_queues_window_commands() {
    let mut bridge = bridge();
    let mut unidentified = request(fb::WindowRequestKind::ListWindows, 1);
    unidentified[4] = b'X';
    assert!(matches!(
        bridge.handle(&unidentified),
        Err(WireError::Identifier)
    ));
    assert!(matches!(
        bridge.handle(&request(fb::WindowRequestKind::ListWindows, 0)),
        Err(WireError::RequestId)
    ));
    assert!(matches!(
        bridge.handle(&window_request(
            fb::WindowRequestKind::CloseWindow,
            0,
            0,
            None,
        )),
        Err(WireError::Identity)
    ));

    bridge
        .handle(&window_request(
            fb::WindowRequestKind::CloseWindow,
            0,
            41,
            None,
        ))
        .unwrap();
    bridge
        .handle(&window_request(
            fb::WindowRequestKind::FocusWindow,
            0,
            42,
            None,
        ))
        .unwrap();
    bridge
        .handle(&window_request(
            fb::WindowRequestKind::ConfigureWindow,
            0,
            43,
            Some(fb::WireRect::new(96.0, 72.0, 1120.0, 700.0)),
        ))
        .unwrap();
    assert_eq!(
        bridge.drain_window_commands().collect::<Vec<_>>(),
        vec![
            WindowCommand::Close { window_id: 41 },
            WindowCommand::Focus { window_id: 42 },
            WindowCommand::Configure {
                window_id: 43,
                geometry: WindowGeometry {
                    x: 96.0,
                    y: 72.0,
                    width: 1120.0,
                    height: 700.0,
                },
                exact: false,
            },
        ]
    );
    bridge
        .handle(&exact_window_request(
            43,
            fb::WireRect::new(0.0, 48.0, 632.0, 1342.0),
        ))
        .unwrap();
    assert!(matches!(
        bridge.drain_window_commands().next(),
        Some(WindowCommand::Configure {
            window_id: 43,
            exact: true,
            ..
        })
    ));
    assert!(matches!(
        bridge.handle(&window_request(
            fb::WindowRequestKind::ConfigureWindow,
            0,
            43,
            Some(fb::WireRect::new(0.0, 0.0, 0.0, 700.0)),
        )),
        Err(WireError::Geometry)
    ));
    for geometry in [
        fb::WireRect::new(-1.0, 0.0, 640.0, 480.0),
        fb::WireRect::new(0.0, 0.0, 63.0, 480.0),
        fb::WireRect::new(16_385.0, 0.0, 640.0, 480.0),
        fb::WireRect::new(0.0, 0.0, 16_385.0, 480.0),
        fb::WireRect::new(f64::NAN, 0.0, 640.0, 480.0),
        fb::WireRect::new(0.0, 0.0, f64::INFINITY, 480.0),
        fb::WireRect::new(f64::MAX, 0.0, f64::MAX, 480.0),
    ] {
        assert!(matches!(
            bridge.handle(&window_request(
                fb::WindowRequestKind::ConfigureWindow,
                0,
                43,
                Some(geometry),
            )),
            Err(WireError::Geometry)
        ));
    }
    bridge
        .handle(&window_request(
            fb::WindowRequestKind::ConfigureWindow,
            0,
            43,
            Some(fb::WireRect::new(0.0, 0.0, 64.0, 64.0)),
        ))
        .unwrap();
    bridge
        .handle(&window_request(
            fb::WindowRequestKind::ConfigureWindow,
            0,
            43,
            Some(fb::WireRect::new(16_384.0, 16_384.0, 16_384.0, 16_384.0)),
        ))
        .unwrap();
    let boundary = bridge.drain_window_commands().last().unwrap();
    let WindowCommand::Configure { geometry, .. } = boundary else {
        panic!("last boundary command was not Configure");
    };
    assert_eq!(geometry.width as i32, 16_384);
    assert_eq!(geometry.height as i32, 16_384);
}

#[test]
fn validates_and_coalesces_resolved_theme_accents() {
    let mut bridge = bridge();
    bridge.handle(&theme_state(0x12_34_56, 0)).unwrap();
    bridge.handle(&theme_state(0xab_cd_ef, 0)).unwrap();
    assert_eq!(bridge.take_theme_accent(), Some(0xab_cd_ef));
    assert!(bridge.take_theme_accent().is_none());
    assert!(matches!(
        bridge.handle(&theme_state(0xff_12_34_56, 0)),
        Err(WireError::Payload)
    ));
    assert!(matches!(
        bridge.handle(&theme_state(0x12_34_56, 9)),
        Err(WireError::RequestId)
    ));
}

#[test]
fn validates_and_queues_generic_local_window_creation() {
    let mut bridge = bridge();
    bridge
        .handle(&create_local_window_request(
            0,
            "dev.denial.notes",
            "Notes",
            fb::WireRect::new(120.0, 80.0, 900.0, 640.0),
        ))
        .unwrap();
    assert_eq!(
        bridge.drain_window_commands().collect::<Vec<_>>(),
        vec![WindowCommand::CreateLocal {
            app_id: "dev.denial.notes".into(),
            title: "Notes".into(),
            geometry: WindowGeometry {
                x: 120.0,
                y: 80.0,
                width: 900.0,
                height: 640.0,
            },
        }]
    );

    assert!(matches!(
        bridge.handle(&create_local_window_request(
            1,
            "dev.denial.notes",
            "Notes",
            fb::WireRect::new(120.0, 80.0, 900.0, 640.0),
        )),
        Err(WireError::RequestId)
    ));
    assert!(matches!(
        bridge.handle(&create_local_window_request(
            0,
            "",
            "Notes",
            fb::WireRect::new(120.0, 80.0, 900.0, 640.0),
        )),
        Err(WireError::Payload)
    ));
    assert!(matches!(
        bridge.handle(&create_local_window_request(
            0,
            "dev.denial.notes",
            "Notes",
            fb::WireRect::new(120.0, 80.0, 32.0, 640.0),
        )),
        Err(WireError::Geometry)
    ));
}

#[test]
fn validates_sequences_and_wraps_outgoing_sequence_without_zero() {
    let mut bridge = bridge();
    assert!(matches!(
        bridge.handle(&window_request_with_sequence(
            fb::WindowRequestKind::ListWindows,
            1,
            0,
            None,
            0,
        )),
        Err(WireError::Sequence)
    ));

    bridge.next_sequence = i64::MAX as u64;
    let at_limit = fb::root_as_envelope(bridge.encode_window_activated(1).unwrap())
        .unwrap()
        .sequence();
    let wrapped = fb::root_as_envelope(bridge.encode_window_activated(1).unwrap())
        .unwrap()
        .sequence();
    assert_eq!(at_limit, i64::MAX as u64);
    assert_eq!(wrapped, 1);
}

#[test]
fn validates_keyboard_and_notification_command_payloads() {
    let mut bridge = bridge();
    bridge
        .handle(&keyboard_command(
            fb::KeyboardCommandKind::Text,
            Some("hello"),
            None,
            0,
        ))
        .unwrap();
    bridge
        .handle(&keyboard_command(
            fb::KeyboardCommandKind::Key,
            None,
            Some("Backspace"),
            KEYBOARD_CTRL,
        ))
        .unwrap();
    assert_eq!(
        bridge.drain_keyboard_commands().collect::<Vec<_>>(),
        vec![
            KeyboardCommand::Text("hello".into()),
            KeyboardCommand::Key {
                key: "Backspace".into(),
                ctrl: true,
                phase: KeyboardKeyPhase::Tap,
            },
        ]
    );
    bridge
        .handle(&keyboard_command(
            fb::KeyboardCommandKind::Key,
            None,
            Some("BackSpace"),
            KEYBOARD_PRESSED,
        ))
        .unwrap();
    bridge
        .handle(&keyboard_command(
            fb::KeyboardCommandKind::Key,
            None,
            Some("BackSpace"),
            KEYBOARD_RELEASED,
        ))
        .unwrap();
    assert_eq!(
        bridge.drain_keyboard_commands().collect::<Vec<_>>(),
        vec![
            KeyboardCommand::Key {
                key: "BackSpace".into(),
                ctrl: false,
                phase: KeyboardKeyPhase::Pressed,
            },
            KeyboardCommand::Key {
                key: "BackSpace".into(),
                ctrl: false,
                phase: KeyboardKeyPhase::Released,
            },
        ]
    );
    for invalid_flags in [
        KEYBOARD_PRESSED | KEYBOARD_RELEASED,
        KEYBOARD_CTRL | KEYBOARD_PRESSED,
    ] {
        assert!(matches!(
            bridge.handle(&keyboard_command(
                fb::KeyboardCommandKind::Key,
                None,
                Some("BackSpace"),
                invalid_flags,
            )),
            Err(WireError::Flags)
        ));
    }
    assert!(matches!(
        bridge.handle(&keyboard_command(
            fb::KeyboardCommandKind(255),
            Some("hello"),
            None,
            0,
        )),
        Err(WireError::Enumeration)
    ));
    assert!(matches!(
        bridge.handle(&keyboard_command(
            fb::KeyboardCommandKind::Text,
            Some("hello"),
            None,
            1 << 31,
        )),
        Err(WireError::Flags)
    ));
    let oversized = "x".repeat(MAX_STRING_BYTES + 1);
    for value in [None, Some(""), Some(oversized.as_str())] {
        assert!(matches!(
            bridge.handle(&keyboard_command(
                fb::KeyboardCommandKind::Text,
                value,
                None,
                0,
            )),
            Err(WireError::String)
        ));
    }

    bridge
        .handle(&notification_command(
            fb::DesktopNotificationCommandKind::Dismiss,
            9,
            None,
        ))
        .unwrap();
    bridge
        .handle(&notification_command(
            fb::DesktopNotificationCommandKind::InvokeAction,
            9,
            Some("open"),
        ))
        .unwrap();
    bridge
        .handle(&notification_command(
            fb::DesktopNotificationCommandKind::InvokeDefault,
            10,
            None,
        ))
        .unwrap();
    assert_eq!(
        bridge.drain_notification_commands().collect::<Vec<_>>(),
        vec![
            NotificationCommand::Dismiss { notification_id: 9 },
            NotificationCommand::InvokeAction {
                notification_id: 9,
                action_key: "open".into(),
            },
            NotificationCommand::InvokeDefault {
                notification_id: 10,
            },
        ]
    );
    assert!(matches!(
        bridge.handle(&notification_command(
            fb::DesktopNotificationCommandKind(255),
            9,
            None,
        )),
        Err(WireError::Enumeration)
    ));
    assert!(matches!(
        bridge.handle(&notification_command(
            fb::DesktopNotificationCommandKind::Dismiss,
            0,
            None,
        )),
        Err(WireError::Identity)
    ));
    for action_key in [None, Some("")] {
        assert!(matches!(
            bridge.handle(&notification_command(
                fb::DesktopNotificationCommandKind::InvokeAction,
                9,
                action_key,
            )),
            Err(WireError::String)
        ));
    }
    assert!(matches!(
        bridge.handle(&notification_command(
            fb::DesktopNotificationCommandKind::InvokeDefault,
            9,
            Some("unexpected"),
        )),
        Err(WireError::String)
    ));

    for payload_type in [
        fb::Payload::KeyboardCommand,
        fb::Payload::DesktopNotificationCommand,
    ] {
        assert!(matches!(
            bridge.handle(&envelope_without_payload(payload_type)),
            Err(WireError::Payload | WireError::FlatBuffer(_))
        ));
    }
}

#[test]
fn validates_xembed_tray_commands() {
    let mut bridge = bridge();
    for (kind, action) in [
        (
            fb::XEmbedTrayCommandKind::Activate,
            XEmbedTrayAction::Activate,
        ),
        (
            fb::XEmbedTrayCommandKind::SecondaryActivate,
            XEmbedTrayAction::SecondaryActivate,
        ),
        (
            fb::XEmbedTrayCommandKind::ContextMenu,
            XEmbedTrayAction::ContextMenu,
        ),
    ] {
        bridge
            .handle(&xembed_tray_command(kind, 42, -320, 1440))
            .unwrap();
        assert_eq!(
            bridge.drain_xembed_tray_commands().collect::<Vec<_>>(),
            vec![XEmbedTrayCommand {
                action,
                window_id: 42,
                x: -320,
                y: 1440,
            }]
        );
    }
    assert!(matches!(
        bridge.handle(&xembed_tray_command(
            fb::XEmbedTrayCommandKind::Activate,
            0,
            0,
            0,
        )),
        Err(WireError::Identity)
    ));
    assert!(matches!(
        bridge.handle(&xembed_tray_command(
            fb::XEmbedTrayCommandKind(255),
            42,
            0,
            0,
        )),
        Err(WireError::Identity | WireError::Enumeration)
    ));
    assert!(matches!(
        bridge.handle(&envelope_without_payload(fb::Payload::XEmbedTrayCommand)),
        Err(WireError::Payload | WireError::FlatBuffer(_))
    ));
}

#[test]
fn rapid_keyboard_commands_remain_individual_and_ordered() {
    let mut bridge = bridge();
    let expected = "thequickbrownfox";

    for character in expected.chars() {
        let text = character.to_string();
        bridge
            .handle(&keyboard_command(
                fb::KeyboardCommandKind::Text,
                Some(&text),
                None,
                0,
            ))
            .unwrap();
    }

    let delivered = bridge
        .drain_keyboard_commands()
        .map(|command| match command {
            KeyboardCommand::Text(text) => text,
            KeyboardCommand::Key { .. } => panic!("text burst produced a named key"),
        })
        .collect::<Vec<_>>();
    assert_eq!(delivered.len(), expected.chars().count());
    assert_eq!(delivered.concat(), expected);
}

#[test]
fn settings_requests_are_typed_bounded_and_revisioned() {
    let mut bridge = bridge();
    bridge
        .handle(&settings_request(
            fb::SettingsRequestKind::ReadDocument,
            41,
            0,
            None,
            None,
        ))
        .unwrap();
    bridge
        .handle(&settings_request(
            fb::SettingsRequestKind::WriteDocument,
            42,
            7,
            Some(r#"{"version":9}"#),
            None,
        ))
        .unwrap();
    bridge
        .handle(&settings_request(
            fb::SettingsRequestKind::ConfigureKeyboard,
            43,
            8,
            None,
            Some((
                &[("us", ""), ("de", "nodeadkeys")],
                &["compose:menu"],
                450,
                30,
            )),
        ))
        .unwrap();
    bridge
        .handle(&touchpad_settings_request(45, 9, false, true, 2.5))
        .unwrap();
    bridge
        .handle(&settings_request(
            fb::SettingsRequestKind::ReadInputDevices,
            44,
            0,
            None,
            None,
        ))
        .unwrap();
    assert_eq!(
        bridge.drain_settings_commands().collect::<Vec<_>>(),
        vec![
            SettingsCommand::ReadDocument { request_id: 41 },
            SettingsCommand::WriteDocument {
                request_id: 42,
                expected_revision: 7,
                document: r#"{"version":9}"#.to_owned(),
            },
            SettingsCommand::ConfigureKeyboard {
                request_id: 43,
                expected_revision: 8,
                keyboard: KeyboardSettings {
                    layouts: vec![
                        KeyboardLayout {
                            layout: "us".to_owned(),
                            variant: String::new(),
                        },
                        KeyboardLayout {
                            layout: "de".to_owned(),
                            variant: "nodeadkeys".to_owned(),
                        },
                    ],
                    options: vec!["compose:menu".to_owned()],
                    repeat_delay_ms: 450,
                    repeat_rate_hz: 30,
                },
            },
            SettingsCommand::ConfigureTouchpad {
                request_id: 45,
                expected_revision: 9,
                touchpad: TouchpadSettings {
                    tap_to_click_enabled: false,
                    natural_scroll_enabled: true,
                    scroll_speed_factor: 2.5,
                },
            },
            SettingsCommand::ReadInputDevices { request_id: 44 },
        ]
    );

    for request in [
        settings_request(fb::SettingsRequestKind::ReadKeyboard, 0, 0, None, None),
        settings_request(
            fb::SettingsRequestKind::WriteDocument,
            44,
            0,
            Some("{}"),
            None,
        ),
        settings_request(
            fb::SettingsRequestKind::ConfigureKeyboard,
            45,
            9,
            None,
            Some((&[("not,a,layout", "")], &[], 600, 25)),
        ),
    ] {
        assert!(bridge.handle(&request).is_err());
    }
}

#[test]
fn settings_responses_preserve_document_and_keyboard_metadata() {
    let mut bridge = bridge();
    let bytes = bridge
        .encode_settings_document_response(51, 9, Some("{\n  \"version\": 8\n}\n"), None)
        .unwrap();
    let envelope = fb::root_as_envelope(bytes).unwrap();
    let response = envelope.payload_as_settings_response().unwrap();
    assert_eq!(envelope.request_id(), 51);
    assert_eq!(response.kind(), fb::SettingsResponseKind::Document);
    assert!(response.success());
    assert_eq!(response.revision(), 9);
    assert_eq!(response.document(), Some("{\n  \"version\": 8\n}\n"));

    let bytes = bridge
        .encode_settings_document_response(0, 10, Some("{\n  \"version\": 9\n}\n"), None)
        .unwrap();
    let envelope = fb::root_as_envelope(bytes).unwrap();
    let response = envelope.payload_as_settings_response().unwrap();
    assert_eq!(envelope.request_id(), 0);
    assert_eq!(response.kind(), fb::SettingsResponseKind::Document);
    assert!(response.success());
    assert_eq!(response.revision(), 10);

    let keyboard = KeyboardSettings {
        layouts: vec![
            KeyboardLayout {
                layout: "us".to_owned(),
                variant: String::new(),
            },
            KeyboardLayout {
                layout: "de".to_owned(),
                variant: "nodeadkeys".to_owned(),
            },
        ],
        options: vec!["compose:menu".to_owned()],
        repeat_delay_ms: 450,
        repeat_rate_hz: 30,
    };
    let bytes = bridge
        .encode_keyboard_settings_response(
            52,
            10,
            &keyboard,
            &["English (US)".to_owned(), "German".to_owned()],
            1,
            Some("revision conflict"),
        )
        .unwrap();
    let envelope = fb::root_as_envelope(bytes).unwrap();
    let response = envelope.payload_as_settings_response().unwrap();
    let encoded = response.keyboard().unwrap();
    assert!(!response.success());
    assert_eq!(response.error(), Some("revision conflict"));
    assert_eq!(encoded.active_layout(), 1);
    assert_eq!(encoded.repeat_delay_ms(), 450);
    assert_eq!(encoded.repeat_rate_hz(), 30);
    let layouts = encoded.layouts().unwrap();
    assert_eq!(layouts.get(1).layout(), Some("de"));
    assert_eq!(layouts.get(1).variant(), Some("nodeadkeys"));
    assert_eq!(layouts.get(1).display_name(), Some("German"));
    assert_eq!(encoded.options().unwrap().get(0), "compose:menu");

    let bytes = bridge
        .encode_input_device_capabilities_response(
            0,
            11,
            true,
            &TouchpadSettings {
                tap_to_click_enabled: false,
                natural_scroll_enabled: true,
                scroll_speed_factor: 2.5,
            },
            None,
        )
        .unwrap();
    let envelope = fb::root_as_envelope(bytes).unwrap();
    let response = envelope.payload_as_settings_response().unwrap();
    assert_eq!(envelope.request_id(), 0);
    assert_eq!(response.kind(), fb::SettingsResponseKind::InputDevices);
    assert!(response.success());
    assert_eq!(response.revision(), 11);
    let input_devices = response.input_devices().unwrap();
    assert!(input_devices.has_touchpad());
    let touchpad = input_devices.touchpad().unwrap();
    assert!(!touchpad.tap_to_click_enabled());
    assert!(touchpad.natural_scroll_enabled());
    assert_eq!(touchpad.scroll_speed_factor(), 2.5);
}

#[test]
fn shortcut_wire_preserves_desktop_application_identity() {
    let mut builder = FlatBufferBuilder::new();
    let program = builder.create_string("foot");
    let command = builder.create_vector(&[program]);
    let desktop_file_id = builder.create_string("org.example.Terminal.desktop");
    let target = fb::ShortcutSpawnTarget::create(
        &mut builder,
        &fb::ShortcutSpawnTargetArgs {
            command: Some(command),
            desktop_file_id: Some(desktop_file_id),
        },
    );
    let shortcut = builder.create_string("Super+T");
    let binding = fb::ShortcutBinding::create(
        &mut builder,
        &fb::ShortcutBindingArgs {
            shortcut: Some(shortcut),
            target_type: fb::ShortcutTarget::ShortcutSpawnTarget,
            target: Some(target.as_union_value()),
        },
    );
    let request = fb::SettingsRequest::create(
        &mut builder,
        &fb::SettingsRequestArgs {
            kind: fb::SettingsRequestKind::AddShortcut,
            expected_revision: 4,
            shortcut: Some(binding),
            ..Default::default()
        },
    );
    let envelope = fb::Envelope::create(
        &mut builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence: 12,
            request_id: 71,
            payload_type: fb::Payload::SettingsRequest,
            payload: Some(request.as_union_value()),
        },
    );
    fb::finish_envelope_buffer(&mut builder, envelope);

    let mut bridge = bridge();
    bridge.handle(builder.finished_data()).unwrap();
    assert_eq!(
        bridge.drain_settings_commands().next(),
        Some(SettingsCommand::AddShortcut {
            request_id: 71,
            expected_revision: 4,
            shortcut: ShortcutBinding {
                shortcut: "Super+T".to_owned(),
                target: ShortcutTarget::Spawn {
                    command: vec!["foot".to_owned()],
                    desktop_file_id: Some("org.example.Terminal.desktop".to_owned()),
                },
            },
        })
    );

    let binding = ShortcutBinding {
        shortcut: "Super+T".to_owned(),
        target: ShortcutTarget::Spawn {
            command: vec!["foot".to_owned()],
            desktop_file_id: Some("org.example.Terminal.desktop".to_owned()),
        },
    };
    let bytes = bridge
        .encode_shortcut_configuration_response(72, 5, &[binding], &[], None)
        .unwrap();
    let response = fb::root_as_envelope(bytes)
        .unwrap()
        .payload_as_settings_response()
        .unwrap();
    let target = response
        .shortcuts()
        .unwrap()
        .shortcuts()
        .unwrap()
        .get(0)
        .target_as_shortcut_spawn_target()
        .unwrap();
    assert_eq!(
        target.desktop_file_id(),
        Some("org.example.Terminal.desktop")
    );
}

#[test]
fn enforces_message_collection_and_command_queue_limits() {
    let mut bridge = bridge();
    assert!(matches!(
        bridge.handle(&vec![0; MAX_MESSAGE_BYTES + 1]),
        Err(WireError::Size(size)) if size == MAX_MESSAGE_BYTES + 1
    ));

    let rect = fb::WireRect::new(0.0, 0.0, 1.0, 1.0);
    let shell_regions = vec![rect; MAX_REGIONS + 1];
    assert!(matches!(
        bridge.handle(&input_layout(&shell_regions, &[], 0)),
        Err(WireError::Count)
    ));

    bridge.pending_window_commands =
        vec![WindowCommand::Close { window_id: 1 }; MAX_PENDING_WINDOW_COMMANDS]
            .into_iter()
            .collect();
    assert!(matches!(
        bridge.handle(&window_request(
            fb::WindowRequestKind::CloseWindow,
            0,
            1,
            None,
        )),
        Err(WireError::Count)
    ));

    bridge.pending_keyboard_commands =
        vec![KeyboardCommand::Text("a".into()); MAX_PENDING_KEYBOARD_COMMANDS]
            .into_iter()
            .collect();
    assert!(matches!(
        bridge.handle(&keyboard_command(
            fb::KeyboardCommandKind::Text,
            Some("a"),
            None,
            0,
        )),
        Err(WireError::Count)
    ));

    bridge.pending_notification_commands = vec![
        NotificationCommand::Dismiss { notification_id: 1 };
        MAX_PENDING_NOTIFICATION_COMMANDS
    ]
    .into_iter()
    .collect();
    assert!(matches!(
        bridge.handle(&notification_command(
            fb::DesktopNotificationCommandKind::Dismiss,
            1,
            None,
        )),
        Err(WireError::Count)
    ));

    bridge.pending_xembed_tray_commands = vec![
        XEmbedTrayCommand {
            action: XEmbedTrayAction::Activate,
            window_id: 1,
            x: 0,
            y: 0,
        };
        MAX_PENDING_XEMBED_TRAY_COMMANDS
    ]
    .into_iter()
    .collect();
    assert!(matches!(
        bridge.handle(&xembed_tray_command(
            fb::XEmbedTrayCommandKind::Activate,
            1,
            0,
            0,
        )),
        Err(WireError::Count)
    ));
}

#[test]
fn encodes_notification_events_for_flutter() {
    let mut bridge = bridge();
    let notification = Notification {
        id: 17,
        sender: ":1.42".into(),
        app_name: "Mail".into(),
        app_icon: "mail-unread".into(),
        summary: "New message".into(),
        body: "Hello".into(),
        actions: vec![super::super::notification_server::NotificationAction {
            key: "default".into(),
            label: "Open".into(),
        }],
        urgency: NotificationUrgency::Normal,
        category: "email.arrived".into(),
        desktop_entry: "mail".into(),
        image_path: String::new(),
        image_data: None,
        resident: true,
        transient: false,
        suppress_sound: true,
        action_icons: false,
        sound_name: String::new(),
        sound_file: String::new(),
        x: 12,
        y: 24,
        has_position: true,
        progress: 50,
        has_progress: true,
        expire_timeout_ms: 7000,
    };
    let event = NotificationEvent {
        kind: NotificationEventKind::Added,
        notification: Some(notification),
        notification_id: 17,
        close_reason: 0,
    };
    let envelope = fb::root_as_envelope(bridge.encode_notification_event(&event).unwrap()).unwrap();
    let encoded = envelope.payload_as_desktop_notification_event().unwrap();
    let value = encoded.notification().unwrap();
    assert_eq!(
        envelope.payload_type(),
        fb::Payload::DesktopNotificationEvent
    );
    assert_eq!(encoded.kind(), fb::DesktopNotificationEventKind::Added);
    assert_eq!(encoded.notification_id(), 17);
    assert_eq!(value.summary(), Some("New message"));
    assert_eq!(value.actions().unwrap().get(0).key(), Some("default"));
    assert_eq!(value.progress(), 50);
    assert!(value.has_progress());

    let closed = NotificationEvent {
        kind: NotificationEventKind::Closed,
        notification: None,
        notification_id: 17,
        close_reason: 2,
    };
    let envelope =
        fb::root_as_envelope(bridge.encode_notification_event(&closed).unwrap()).unwrap();
    let encoded = envelope.payload_as_desktop_notification_event().unwrap();
    assert_eq!(encoded.kind(), fb::DesktopNotificationEventKind::Closed);
    assert!(encoded.notification().is_none());
    assert_eq!(encoded.close_reason(), 2);
}

#[test]
fn encodes_xembed_tray_events_for_flutter() {
    let mut bridge = bridge();
    let added = XEmbedTrayEvent {
        kind: XEmbedTrayEventKind::Added,
        window_id: 42,
        icon: Some(super::super::xembed_tray::XEmbedTrayIcon {
            window_id: 42,
            title: "Steam".into(),
            width: 1,
            height: 1,
            rgba: vec![10, 20, 30, 255],
        }),
    };
    let envelope = fb::root_as_envelope(bridge.encode_xembed_tray_event(&added).unwrap()).unwrap();
    let encoded = envelope.payload_as_xembed_tray_event().unwrap();
    let icon = encoded.icon().unwrap();
    assert_eq!(envelope.payload_type(), fb::Payload::XEmbedTrayEvent);
    assert_eq!(encoded.kind(), fb::XEmbedTrayEventKind::Added);
    assert_eq!(encoded.window_id(), 42);
    assert_eq!(icon.title(), Some("Steam"));
    assert_eq!(icon.rgba().unwrap().bytes(), &[10, 20, 30, 255]);

    let removed = XEmbedTrayEvent {
        kind: XEmbedTrayEventKind::Removed,
        window_id: 42,
        icon: None,
    };
    let envelope =
        fb::root_as_envelope(bridge.encode_xembed_tray_event(&removed).unwrap()).unwrap();
    let encoded = envelope.payload_as_xembed_tray_event().unwrap();
    assert_eq!(encoded.kind(), fb::XEmbedTrayEventKind::Removed);
    assert!(encoded.icon().is_none());

    let malformed = XEmbedTrayEvent {
        kind: XEmbedTrayEventKind::Updated,
        window_id: 42,
        icon: Some(super::super::xembed_tray::XEmbedTrayIcon {
            window_id: 42,
            title: "bad".into(),
            width: 2,
            height: 2,
            rgba: vec![0; 4],
        }),
    };
    assert!(matches!(
        bridge.encode_xembed_tray_event(&malformed),
        Err(WireError::Payload)
    ));
}

#[test]
fn encodes_window_management_events_for_flutter() {
    let mut bridge = bridge();
    let bytes = bridge
        .encode_window_action(77, WindowAction::ToggleFullscreen)
        .unwrap();
    let envelope = fb::root_as_envelope(bytes).unwrap();
    let event = envelope.payload_as_window_event().unwrap();
    assert_eq!(envelope.sequence(), 1);
    assert_eq!(envelope.request_id(), 0);
    assert_eq!(event.kind(), fb::WindowEventKind::Action);
    assert_eq!(event.window_id(), 77);
    assert_eq!(event.action(), fb::WindowActionKind::ToggleFullscreen);

    let bytes = bridge.encode_window_activated(78).unwrap();
    let envelope = fb::root_as_envelope(bytes).unwrap();
    let event = envelope.payload_as_window_event().unwrap();
    assert_eq!(envelope.sequence(), 2);
    assert_eq!(event.kind(), fb::WindowEventKind::Activated);
    assert_eq!(event.window_id(), 78);

    let bytes = bridge
        .encode_window_placement(WindowPlacement {
            window_id: 78,
            monitor_id: 4,
            workspace_id: 1,
            phase: WindowPlacementPhase::Update,
            change: WindowPlacementChange::Resize,
            geometry: WindowGeometry {
                x: 1920.0,
                y: 40.0,
                width: 800.0,
                height: 600.0,
            },
        })
        .unwrap();
    assert_eq!(bytes.len(), WINDOW_PLACEMENT_PACKET_BYTES);
    assert_eq!(&bytes[0..4], b"DENP");
    assert_eq!(u64::from_le_bytes(bytes[12..20].try_into().unwrap()), 3);
    assert_eq!(u64::from_le_bytes(bytes[20..28].try_into().unwrap()), 78);
    assert_eq!(i64::from_le_bytes(bytes[28..36].try_into().unwrap()), 4);
    assert_eq!(bytes[44], WindowPlacementPhase::Update as u8);
    assert_eq!(bytes[45], WindowPlacementChange::Resize as u8);
    assert_eq!(f64::from_le_bytes(bytes[64..72].try_into().unwrap()), 800.0);
}

#[test]
fn outbound_flatbuffer_storage_is_reused_between_synchronous_sends() {
    let mut bridge = bridge();
    let (first_pointer, first_len) = {
        let bytes = bridge.encode_window_activated(71).unwrap();
        (bytes.as_ptr(), bytes.len())
    };
    let bytes = bridge.encode_window_activated(71).unwrap();
    assert_eq!(bytes.len(), first_len);
    assert_eq!(bytes.as_ptr(), first_pointer);
}

#[test]
fn encodes_shell_actions_with_optional_monitor_and_ordered_sequence() {
    let mut bridge = bridge();

    let bytes = bridge
        .encode_shell_action(ShellAction::Applications, None)
        .unwrap();
    let envelope = fb::root_as_envelope(bytes).unwrap();
    let action = envelope.payload_as_shell_action().unwrap();
    assert_eq!(envelope.protocol_version(), PROTOCOL_VERSION);
    assert_eq!(envelope.sequence(), 1);
    assert_eq!(envelope.request_id(), 0);
    assert_eq!(envelope.payload_type(), fb::Payload::ShellAction);
    assert_eq!(action.action(), fb::ShellActionKind::Applications);
    assert!(!action.has_monitor_id());
    assert_eq!(action.monitor_id(), -1);

    let bytes = bridge
        .encode_shell_action(ShellAction::Overview, Some(9))
        .unwrap();
    let envelope = fb::root_as_envelope(bytes).unwrap();
    let action = envelope.payload_as_shell_action().unwrap();
    assert_eq!(envelope.sequence(), 2);
    assert_eq!(envelope.request_id(), 0);
    assert_eq!(envelope.payload_type(), fb::Payload::ShellAction);
    assert_eq!(action.action(), fb::ShellActionKind::Overview);
    assert!(action.has_monitor_id());
    assert_eq!(action.monitor_id(), 9);

    let bytes = bridge
        .encode_shell_action(ShellAction::WindowSwitcherPrevious, Some(9))
        .unwrap();
    let envelope = fb::root_as_envelope(bytes).unwrap();
    let action = envelope.payload_as_shell_action().unwrap();
    assert_eq!(envelope.sequence(), 3);
    assert_eq!(action.action(), fb::ShellActionKind::WindowSwitcherPrevious);
    assert!(action.has_monitor_id());
    assert_eq!(action.monitor_id(), 9);

    let bytes = bridge
        .encode_shell_action(ShellAction::ScreenshotRegion, None)
        .unwrap();
    let envelope = fb::root_as_envelope(bytes).unwrap();
    let action = envelope.payload_as_shell_action().unwrap();
    assert_eq!(envelope.sequence(), 4);
    assert_eq!(action.action(), fb::ShellActionKind::ScreenshotRegion);
    assert!(!action.has_monitor_id());

    let bytes = bridge
        .encode_shell_action(ShellAction::ClientPointerPressed, None)
        .unwrap();
    let envelope = fb::root_as_envelope(bytes).unwrap();
    let action = envelope.payload_as_shell_action().unwrap();
    assert_eq!(envelope.sequence(), 5);
    assert_eq!(action.action(), fb::ShellActionKind::ClientPointerPressed);

    let bytes = bridge
        .encode_shell_action(ShellAction::Wallpaper, None)
        .unwrap();
    let envelope = fb::root_as_envelope(bytes).unwrap();
    let action = envelope.payload_as_shell_action().unwrap();
    assert_eq!(envelope.sequence(), 6);
    assert_eq!(action.action(), fb::ShellActionKind::Wallpaper);

    let bytes = bridge
        .encode_shell_action(ShellAction::OpenSettings, None)
        .unwrap();
    let envelope = fb::root_as_envelope(bytes).unwrap();
    let action = envelope.payload_as_shell_action().unwrap();
    assert_eq!(envelope.sequence(), 7);
    assert_eq!(action.action(), fb::ShellActionKind::OpenSettings);

    let bytes = bridge
        .encode_shell_action(ShellAction::Dashboard, None)
        .unwrap();
    let envelope = fb::root_as_envelope(bytes).unwrap();
    let action = envelope.payload_as_shell_action().unwrap();
    assert_eq!(envelope.sequence(), 8);
    assert_eq!(action.action(), fb::ShellActionKind::Dashboard);
}

#[test]
fn screenshot_actions_carry_the_workflow_identity_and_texture() {
    let mut bridge = bridge();
    let bytes = bridge
        .encode_screenshot_action(ShellAction::ScreenshotTextureReady, 41, Some(9001))
        .unwrap();
    let envelope = fb::root_as_envelope(bytes).unwrap();
    let action = envelope.payload_as_shell_action().unwrap();
    assert_eq!(envelope.request_id(), 41);
    assert_eq!(action.action(), fb::ShellActionKind::ScreenshotTextureReady);
    assert_eq!(action.texture_id(), 9001);

    assert!(
        bridge
            .encode_screenshot_action(ShellAction::ScreenshotTextureReady, 41, None)
            .is_err()
    );
    assert!(
        bridge
            .encode_screenshot_action(ShellAction::ScreenshotDone, 0, None)
            .is_err()
    );
}

#[test]
fn encodes_atomic_cursor_states_and_rejects_invalid_values_without_sequence_gaps() {
    let mut bridge = bridge();
    let invalid_named = CursorStateDescription {
        epoch: 1,
        kind: CursorStateKind::Named,
        shape: " \t\n ".into(),
        hotspot_x: 0.0,
        hotspot_y: 0.0,
        surfaces: Vec::new(),
    };
    assert!(matches!(
        bridge.encode_cursor_state(&invalid_named),
        Err(WireError::Payload)
    ));

    let state = CursorStateDescription {
        epoch: 27,
        kind: CursorStateKind::Surface,
        shape: String::new(),
        hotspot_x: 4.5,
        hotspot_y: 7.25,
        surfaces: vec![SurfaceLayerDescription {
            surface_id: 91,
            parent_surface_id: 0,
            popup_root_surface_id: 0,
            role: SurfaceRoleDescription::Root,
            texture_id: 501,
            width: 32,
            height: 48,
            surface_x: 0.0,
            surface_y: 0.0,
            surface_width: 16.0,
            surface_height: 24.0,
            texture_source_x: 0.0,
            texture_source_y: 0.0,
            texture_source_width: 32.0,
            texture_source_height: 48.0,
            transform: 0,
            scale_120: 240,
            composition_order: 0,
            opacity: 1.0,
            opaque: false,
        }],
    };
    let bytes = bridge.encode_cursor_state(&state).unwrap();
    let envelope = fb::root_as_envelope(bytes).unwrap();
    let cursor = envelope.payload_as_cursor_state().unwrap();
    let hotspot = cursor.hotspot().unwrap();
    let surface = cursor.surfaces().unwrap().get(0);
    assert_eq!(envelope.protocol_version(), PROTOCOL_VERSION);
    assert_eq!(envelope.sequence(), 1);
    assert_eq!(envelope.request_id(), 0);
    assert_eq!(envelope.payload_type(), fb::Payload::CursorState);
    assert_eq!(cursor.epoch(), 27);
    assert_eq!(cursor.kind(), fb::CursorStateKind::Surface);
    assert_eq!((hotspot.x(), hotspot.y()), (4.5, 7.25));
    assert_eq!(surface.surface_id(), 91);
    assert_eq!(surface.texture_id(), 501);
    assert_eq!(surface.scale_120(), 240);

    let named = CursorStateDescription {
        epoch: 28,
        ..CursorStateDescription::named("text")
    };
    let bytes = bridge.encode_cursor_state(&named).unwrap();
    let envelope = fb::root_as_envelope(bytes).unwrap();
    assert_eq!(envelope.sequence(), 2);
    assert_eq!(
        envelope.payload_as_cursor_state().unwrap().shape(),
        Some("text")
    );
}

#[test]
fn encodes_finite_cursor_positions_without_consuming_rejected_sequences() {
    let mut bridge = bridge();

    assert!(matches!(
        bridge.encode_cursor_position(f64::NAN, 4.0),
        Err(WireError::Geometry)
    ));
    assert!(matches!(
        bridge.encode_cursor_position(4.0, f64::INFINITY),
        Err(WireError::Geometry)
    ));

    let bytes = bridge.encode_cursor_position(713.25, 419.75).unwrap();
    let envelope = fb::root_as_envelope(bytes).unwrap();
    let cursor = envelope.payload_as_cursor_position().unwrap();
    assert_eq!(envelope.protocol_version(), PROTOCOL_VERSION);
    assert_eq!(envelope.sequence(), 1);
    assert_eq!(envelope.request_id(), 0);
    assert_eq!(envelope.payload_type(), fb::Payload::CursorPosition);
    assert_eq!(cursor.x(), 713.25);
    assert_eq!(cursor.y(), 419.75);
}

#[test]
fn encodes_native_text_input_state_and_rejects_impossible_visibility() {
    let mut bridge = bridge();

    assert!(matches!(
        bridge.encode_text_input_state(false, true, false, 0, 0),
        Err(WireError::Payload)
    ));

    let bytes = bridge
        .encode_text_input_state(true, true, true, 3, 6)
        .unwrap();
    let envelope = fb::root_as_envelope(bytes).unwrap();
    let state = envelope.payload_as_text_input_state().unwrap();
    assert_eq!(envelope.protocol_version(), PROTOCOL_VERSION);
    assert_eq!(envelope.sequence(), 1);
    assert_eq!(envelope.request_id(), 0);
    assert_eq!(envelope.payload_type(), fb::Payload::TextInputState);
    assert!(state.active());
    assert!(state.input_panel_visible());
    assert!(state.legacy());
    assert_eq!(state.content_hint(), 3);
    assert_eq!(state.content_purpose(), 6);
}

#[test]
fn accepts_dart_input_layout_goldens_with_strict_alignment() {
    let mut bridge = bridge();
    for (bytes, expected_count, expected_flags) in [
        (
            include_bytes!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../protocol/golden/dart_input_empty.denw"
            ))
            .as_slice(),
            0,
            0,
        ),
        (
            include_bytes!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../protocol/golden/dart_input_one.denw"
            ))
            .as_slice(),
            1,
            INPUT_LAYOUT_KEYBOARD_CAPTURE,
        ),
        (
            include_bytes!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../protocol/golden/dart_input_eight.denw"
            ))
            .as_slice(),
            8,
            0,
        ),
        (
            include_bytes!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../protocol/golden/dart_input_many.denw"
            ))
            .as_slice(),
            32,
            INPUT_LAYOUT_EXCLUSIVE_SHELL,
        ),
    ] {
        assert!(bridge.handle(bytes).unwrap().is_none());
        let layout = bridge.take_input_layout_update().unwrap();
        assert_eq!(layout.windows.len(), expected_count);
        assert_eq!(layout.flags, expected_flags);
        if let Some(window) = layout.windows.first() {
            assert!(window.visible());
            assert!(window.rect.contains(window.rect.x, window.rect.y));
            assert_eq!(
                window
                    .rect
                    .map_to(window.source_rect, window.rect.x, window.rect.y),
                (window.source_rect.x, window.source_rect.y)
            );
        }
    }
}

#[test]
fn accepts_dart_system_bar_golden_with_strict_alignment() {
    let mut bridge = bridge();
    let bytes = include_bytes!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../protocol/golden/dart_system_bar.denw"
    ));
    let response = bridge.handle(bytes).unwrap().unwrap();
    let envelope = fb::root_as_envelope(response).unwrap();
    assert_eq!(envelope.request_id(), 41);
    let layout = envelope
        .payload_as_window_response()
        .unwrap()
        .display_layout()
        .unwrap();
    assert_eq!(layout.system_bar_side(), fb::SystemBarSide::Right);
    assert_eq!(
        layout
            .system_bar_monitor_ids()
            .unwrap()
            .iter()
            .collect::<Vec<_>>(),
        vec![7, 9]
    );
    let update = bridge.take_work_area_update().unwrap();
    assert_eq!(update.system_bar.outputs, vec!["left", "main"]);
}

#[test]
fn input_layout_decode_reuses_frontend_storage() {
    let rect = fb::WireRect::new(10.0, 20.0, 300.0, 200.0);
    let window = fb::InputWindowRegion::new(1, 11, 1, &rect, &rect, 0, INPUT_WINDOW_VISIBLE);
    let bytes = input_layout_with_visible(&[rect], &[window], &[11], 0);
    let mut bridge = bridge();

    bridge.handle(&bytes).unwrap();
    let layout = bridge.take_input_layout_update().unwrap();
    let shell_storage = layout.shell_regions.as_ptr();
    let window_storage = layout.windows.as_ptr();
    let visible_storage = layout.visible_surface_ids.as_ptr();
    bridge.recycle_input_layout(layout);

    bridge.handle(&bytes).unwrap();
    let layout = bridge.take_input_layout_update().unwrap();
    assert_eq!(layout.shell_regions.as_ptr(), shell_storage);
    assert_eq!(layout.windows.as_ptr(), window_storage);
    assert_eq!(layout.visible_surface_ids.as_ptr(), visible_storage);
}

#[test]
fn validates_owned_input_geometry_identity_and_ordering() {
    let rect = fb::WireRect::new(10.0, 20.0, 0.25, 0.5);
    let top = fb::InputWindowRegion::new(1, 11, 21, &rect, &rect, 3, u32::MAX);
    let lower = fb::InputWindowRegion::new(2, 12, 22, &rect, &rect, 2, INPUT_WINDOW_VISIBLE);
    let mut bridge = bridge();
    bridge
        .handle(&input_layout(&[rect], &[top, lower], u32::MAX))
        .unwrap();
    let layout = bridge.take_input_layout_update().unwrap();
    assert_eq!(layout.epoch, 7);
    assert_eq!(layout.windows.len(), 2);
    assert!(!layout.windows[0].hit_test_enabled());
    assert!(layout.windows[0].geometry_locked());
    assert!(!layout.windows[1].geometry_locked());

    let reversed = input_layout(&[], &[lower, top], 0);
    assert!(matches!(bridge.handle(&reversed), Err(WireError::Ordering)));

    let empty = fb::WireRect::new(0.0, 0.0, 0.0, 1.0);
    assert!(matches!(
        bridge.handle(&input_layout(&[empty], &[], 0)),
        Err(WireError::Geometry)
    ));

    let unidentified = fb::InputWindowRegion::new(0, 11, 21, &rect, &rect, 0, 0);
    assert!(matches!(
        bridge.handle(&input_layout(&[], &[unidentified], 0)),
        Err(WireError::Identity)
    ));

    let duplicate_surface = fb::InputWindowRegion::new(2, 11, 22, &rect, &rect, 2, 0);
    assert!(matches!(
        bridge.handle(&input_layout(&[], &[top, duplicate_surface], 0)),
        Err(WireError::Identity)
    ));
    assert!(matches!(
        bridge.handle(&input_layout_with_visible(&[], &[], &[11, 11], 0)),
        Err(WireError::Identity)
    ));

    // Input routing intentionally accepts every finite positive rect,
    // including one whose mathematical far edge is outside f64. The
    // routing helpers must still avoid integer overflow or panics.
    let extreme_extent = fb::WireRect::new(f64::MAX, 0.0, f64::MAX, 1.0);
    bridge
        .handle(&input_layout(&[extreme_extent], &[], 0))
        .unwrap();
    let extreme = bridge.take_input_layout_update().unwrap().shell_regions[0];
    assert!(extreme.contains(f64::MAX, 0.0));
    assert_eq!(extreme.map_to(extreme, f64::MAX, 0.0), (f64::MAX, 0.0));
    let wide = InputRect {
        x: 0.0,
        y: 0.0,
        width: f64::MAX,
        height: 1.0,
    };
    assert_eq!(wide.map_to(wide, f64::MAX / 2.0, 0.0).0, f64::MAX / 2.0);
}

#[test]
fn malformed_truncated_and_mutated_corpus_never_panics() {
    fn exercise(bytes: &[u8]) {
        let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let mut bridge = bridge();
            bridge
                .handle(bytes)
                .map(|response| response.map(<[u8]>::len))
        }));
        match outcome {
            Ok(Ok(Some(response_len))) => assert!(response_len <= MAX_MESSAGE_BYTES),
            Ok(_) => {}
            Err(_) => panic!("wire handler panicked for {} input bytes", bytes.len()),
        }
    }

    let seeds = [
        request(fb::WindowRequestKind::ListWindows, 41),
        input_layout(&[fb::WireRect::new(0.0, 0.0, 10.0, 10.0)], &[], 0),
        keyboard_command(fb::KeyboardCommandKind::Text, Some("corpus"), None, 0),
    ];
    for seed in &seeds {
        for end in 0..seed.len() {
            exercise(&seed[..end]);
        }
        for index in 0..seed.len() {
            let mut mutated = seed.clone();
            mutated[index] ^= 0xa5;
            exercise(&mutated);
        }
    }

    let mut state = 0x4d59_5df4_d0f3_3173_u64;
    for case in 0..256_usize {
        let len = (state as usize ^ case.wrapping_mul(131)) % 2048;
        let mut bytes = vec![0_u8; len];
        for byte in &mut bytes {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            *byte = state as u8;
        }
        if case % 2 == 0 && bytes.len() >= 8 {
            bytes[4..8].copy_from_slice(b"DENW");
        }
        exercise(&bytes);
    }
}
