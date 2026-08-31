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
    window_request_with_flags(kind, request_id, window_id, geometry, sequence, 0)
}

fn window_request_with_flags(
    kind: fb::WindowRequestKind,
    request_id: u64,
    window_id: u64,
    geometry: Option<fb::WireRect>,
    sequence: u64,
    flags: u32,
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
            flags,
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

#[test]
fn configure_window_distinguishes_layout_drops_from_exact_geometry() {
    let geometry = fb::WireRect::new(100.0, 200.0, 800.0, 600.0);
    let mut bridge = bridge();
    assert!(
        bridge
            .handle(&window_request_with_flags(
                fb::WindowRequestKind::ConfigureWindow,
                0,
                42,
                Some(geometry),
                4,
                2,
            ))
            .unwrap()
            .is_none()
    );
    assert_eq!(
        bridge.drain_window_commands().collect::<Vec<_>>(),
        vec![WindowCommand::Configure {
            window_id: 42,
            geometry: WindowGeometry {
                x: 100.0,
                y: 200.0,
                width: 800.0,
                height: 600.0,
            },
            exact: false,
            layout_drop: true,
        }]
    );

    assert!(matches!(
        bridge.handle(&window_request_with_flags(
            fb::WindowRequestKind::ConfigureWindow,
            0,
            42,
            Some(geometry),
            5,
            3,
        )),
        Err(WireError::Flags)
    ));
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
