use super::*;

fn request(command: u8, payload: impl FnOnce(&mut Encoder)) -> Vec<u8> {
    let mut encoder = Encoder::new();
    encoder.bytes(REQUEST_MAGIC);
    encoder.u16(PROTOCOL_VERSION);
    encoder.u8(command);
    encoder.u8(0);
    payload(&mut encoder);
    encoder.finish()
}

fn response_kind(packet: &[u8]) -> (u8, u8) {
    assert_eq!(&packet[..4], RESPONSE_MAGIC);
    (packet[6], packet[7])
}

fn capture_text(manager: &ClipboardManager, text: &str, origin: ClipboardOrigin) -> u64 {
    let mime_types = vec!["text/plain;charset=utf-8".to_owned()];
    let plan = manager
        .observe_external_selection(origin, &mime_types, None)
        .unwrap();
    manager.finish_capture(
        plan.epoch,
        &plan.representations[0].mime_type,
        Some(text.as_bytes().to_vec()),
    );
    manager.lock().history.front().unwrap().id
}

#[test]
fn text_capture_is_bounded_deduplicated_and_searchable() {
    let manager = ClipboardManager::default();
    let first = capture_text(&manager, "Denial clipboard", ClipboardOrigin::Wayland);
    let duplicate = capture_text(&manager, "Denial clipboard", ClipboardOrigin::X11);
    assert_eq!(first, duplicate);
    assert_eq!(manager.lock().history.len(), 1);

    let packet = request(COMMAND_SNAPSHOT, |encoder| encoder.string_u16("clipboard"));
    let response = manager.handle_control_packet(&packet);
    assert_eq!(response_kind(&response), (RESPONSE_SNAPSHOT, STATUS_OK));
    let count = u16::from_le_bytes(response[33..35].try_into().unwrap());
    assert_eq!(count, 1);

    let packet = request(COMMAND_SNAPSHOT, |encoder| encoder.string_u16("missing"));
    let response = manager.handle_control_packet(&packet);
    let count = u16::from_le_bytes(response[33..35].try_into().unwrap());
    assert_eq!(count, 0);
}

#[test]
fn activation_retains_data_and_clear_queues_selection_release() {
    let manager = ClipboardManager::default();
    let item_id = capture_text(&manager, "persistent", ClipboardOrigin::Wayland);
    let response = manager.handle_control_packet(&request(COMMAND_ACTIVATE, |encoder| {
        encoder.u64(item_id);
    }));
    assert_eq!(response_kind(&response), (RESPONSE_ACK, STATUS_OK));
    let action = manager.take_actions().pop().unwrap();
    let ClipboardAction::Publish {
        epoch,
        item_id: id,
        paste,
    } = action
    else {
        panic!("expected clipboard publish");
    };
    assert_eq!(id, item_id);
    assert!(paste);
    assert_eq!(
        manager
            .retained_data(item_id, "text/plain;charset=utf-8")
            .unwrap()
            .as_ref(),
        b"persistent"
    );
    assert_eq!(
        manager.retained_mime_types(epoch, item_id).unwrap(),
        vec!["text/plain;charset=utf-8"]
    );

    let response = manager.handle_control_packet(&request(COMMAND_CLEAR, |_| {}));
    assert_eq!(response_kind(&response), (RESPONSE_ACK, STATUS_OK));
    assert!(matches!(
        manager.take_actions().as_slice(),
        [ClipboardAction::Clear { .. }]
    ));
    assert!(
        manager
            .retained_data(item_id, "text/plain;charset=utf-8")
            .is_none()
    );
}

#[test]
fn clear_retains_pinned_history_and_active_selection() {
    let manager = ClipboardManager::default();
    capture_text(&manager, "discard me", ClipboardOrigin::Wayland);
    let pinned_id = capture_text(&manager, "keep me", ClipboardOrigin::Wayland);
    manager.set_pinned(pinned_id, true).unwrap();
    manager.activate(pinned_id).unwrap();
    manager.take_actions();

    let response = manager.handle_control_packet(&request(COMMAND_CLEAR, |_| {}));
    assert_eq!(response_kind(&response), (RESPONSE_ACK, STATUS_OK));
    let state = manager.lock();
    assert_eq!(state.history.len(), 1);
    assert_eq!(state.history.front().unwrap().id, pinned_id);
    assert_eq!(state.history_bytes, state.history.front().unwrap().byte_len);
    assert!(matches!(
        state.current,
        CurrentSelection::Managed { item_id, .. } if item_id == pinned_id
    ));
    assert!(state.actions.is_empty());
    drop(state);
    assert_eq!(
        manager
            .retained_data(pinned_id, "text/plain;charset=utf-8")
            .unwrap()
            .as_ref(),
        b"keep me"
    );
}

#[test]
fn drag_request_retains_every_mime_representation() {
    let manager = ClipboardManager::default();
    let item_id = capture_text(&manager, "drag me", ClipboardOrigin::Wayland);

    let response = manager.handle_control_packet(&request(COMMAND_START_DRAG, |encoder| {
        encoder.u64(item_id);
    }));
    assert_eq!(response_kind(&response), (RESPONSE_ACK, STATUS_OK));
    assert!(matches!(
        manager.take_actions().as_slice(),
        [ClipboardAction::StartDrag { item_id: queued }] if *queued == item_id
    ));
    let payload = manager.drag_payload(item_id).unwrap();
    assert_eq!(payload.item_id, item_id);
    assert_eq!(payload.representations.len(), 1);
    assert_eq!(payload.representations[0].0, "text/plain;charset=utf-8");
    assert_eq!(payload.representations[0].1.as_ref(), b"drag me");
}

#[test]
fn pause_suppresses_capture_but_not_flutter_clipboard_ownership() {
    let manager = ClipboardManager::default();
    manager.handle_control_packet(&request(COMMAND_SET_PAUSED, |encoder| encoder.u8(1)));
    assert!(
        manager
            .observe_external_selection(ClipboardOrigin::Wayland, &["text/plain".to_owned()], None,)
            .is_none()
    );
    assert!(manager.lock().history.is_empty());

    let item_id = manager.set_text("from shell").unwrap();
    assert_eq!(manager.current_text().as_deref(), Some("from shell"));
    assert!(manager.lock().history.is_empty());
    assert!(
        manager
            .retained_data(item_id, "text/plain;charset=utf-8")
            .is_some()
    );
}

#[test]
fn shell_png_becomes_the_managed_image_selection() {
    let manager = ClipboardManager::default();
    let mut png = Vec::from(b"\x89PNG\r\n\x1a\n".as_slice());
    png.extend_from_slice(&13u32.to_be_bytes());
    png.extend_from_slice(b"IHDR");
    png.extend_from_slice(&2u32.to_be_bytes());
    png.extend_from_slice(&3u32.to_be_bytes());
    png.extend_from_slice(&[8, 6, 0, 0, 0]);
    png.extend_from_slice(&0u32.to_be_bytes());
    png.extend_from_slice(&0u32.to_be_bytes());
    png.extend_from_slice(b"IEND");
    png.extend_from_slice(&0u32.to_be_bytes());

    let item_id = manager.set_image_png(png.clone()).unwrap();
    let action = manager.take_actions().pop().unwrap();
    let ClipboardAction::Publish {
        epoch,
        item_id: published,
        paste,
    } = action
    else {
        panic!("expected clipboard publish");
    };
    assert_eq!(published, item_id);
    assert!(!paste);
    assert_eq!(
        manager.retained_mime_types(epoch, item_id).unwrap(),
        vec!["image/png"]
    );
    assert_eq!(
        manager
            .retained_data(item_id, "image/png")
            .unwrap()
            .as_ref(),
        png
    );
}

#[test]
fn locked_snapshots_are_redacted_and_controls_fail_closed() {
    let manager = ClipboardManager::default();
    let item_id = capture_text(&manager, "secret", ClipboardOrigin::Wayland);
    manager.set_locked(true);
    let response = manager.handle_control_packet(&request(COMMAND_SNAPSHOT, |encoder| {
        encoder.string_u16("");
    }));
    assert_eq!(response_kind(&response), (RESPONSE_SNAPSHOT, STATUS_OK));
    assert_ne!(response[32] & SNAPSHOT_LOCKED, 0);
    assert_eq!(u16::from_le_bytes(response[33..35].try_into().unwrap()), 0);

    let response = manager.handle_control_packet(&request(COMMAND_READ, |encoder| {
        encoder.u64(item_id);
        encoder.string_u16("text/plain;charset=utf-8");
    }));
    assert_eq!(response_kind(&response), (RESPONSE_ERROR, STATUS_LOCKED));
    assert!(manager.current_text().is_none());
}

#[test]
fn malformed_and_oversized_representations_are_rejected() {
    let manager = ClipboardManager::default();
    let plan = manager
        .observe_external_selection(
            ClipboardOrigin::Wayland,
            &["text/plain".to_owned(), "image/png".to_owned()],
            None,
        )
        .unwrap();
    for representation in plan.representations {
        let data = if representation.mime_type == "text/plain" {
            vec![0xff, 0xfe]
        } else {
            b"not a png".to_vec()
        };
        manager.finish_capture(plan.epoch, &representation.mime_type, Some(data));
    }
    assert!(manager.lock().history.is_empty());

    let oversized = vec![b'x'; MAX_TEXT_BYTES + 1];
    assert!(
        validate_representation("text/plain", oversized).is_none(),
        "oversized text must not enter history"
    );
}

#[test]
fn validated_image_formats_publish_dimensions_without_decoding_pixels() {
    let mut png = Vec::from(b"\x89PNG\r\n\x1a\n".as_slice());
    png.extend_from_slice(&13u32.to_be_bytes());
    png.extend_from_slice(b"IHDR");
    png.extend_from_slice(&2u32.to_be_bytes());
    png.extend_from_slice(&3u32.to_be_bytes());
    png.extend_from_slice(&[8, 6, 0, 0, 0]);
    png.extend_from_slice(&0u32.to_be_bytes());
    png.extend_from_slice(&0u32.to_be_bytes());
    png.extend_from_slice(b"IEND");
    png.extend_from_slice(&0u32.to_be_bytes());
    assert_eq!(
        validate_representation("image/png", png)
            .unwrap()
            .dimensions,
        Some((2, 3))
    );

    let jpeg = vec![
        0xff, 0xd8, 0xff, 0xc0, 0x00, 0x11, 8, 0x00, 0x03, 0x00, 0x02, 3, 1, 0x11, 0, 2, 0x11, 0,
        3, 0x11, 0, 0xff, 0xd9,
    ];
    assert_eq!(
        validate_representation("image/jpeg", jpeg)
            .unwrap()
            .dimensions,
        Some((2, 3))
    );

    let mut webp = Vec::from(b"RIFF".as_slice());
    webp.extend_from_slice(&22u32.to_le_bytes());
    webp.extend_from_slice(b"WEBPVP8X");
    webp.extend_from_slice(&10u32.to_le_bytes());
    webp.extend_from_slice(&[0, 0, 0, 0, 1, 0, 0, 2, 0, 0]);
    assert_eq!(
        validate_representation("image/webp", webp)
            .unwrap()
            .dimensions,
        Some((2, 3))
    );
}

#[test]
fn item_count_pin_and_delete_controls_remain_bounded() {
    let manager = ClipboardManager::default();
    for index in 0..(MAX_HISTORY_ITEMS + 5) {
        capture_text(
            &manager,
            &format!("entry {index}"),
            ClipboardOrigin::Wayland,
        );
    }
    assert_eq!(manager.lock().history.len(), MAX_HISTORY_ITEMS);
    let newest = manager.lock().history.front().unwrap().id;
    let response = manager.handle_control_packet(&request(COMMAND_SET_PINNED, |encoder| {
        encoder.u64(newest);
        encoder.u8(1);
    }));
    assert_eq!(response_kind(&response), (RESPONSE_ACK, STATUS_OK));
    assert!(manager.lock().history.front().unwrap().pinned);

    let response = manager.handle_control_packet(&request(COMMAND_DELETE, |encoder| {
        encoder.u64(newest);
    }));
    assert_eq!(response_kind(&response), (RESPONSE_ACK, STATUS_OK));
    assert_eq!(manager.lock().history.len(), MAX_HISTORY_ITEMS - 1);
    assert!(manager.lock().history_item(newest).is_none());
}

#[test]
fn pins_never_weaken_hard_retention_limits() {
    let manager = ClipboardManager::default();
    for index in 0..3 {
        let item_id = capture_text(
            &manager,
            &format!("pinned entry {index}"),
            ClipboardOrigin::Wayland,
        );
        manager.set_pinned(item_id, true).unwrap();
    }
    let newest_ids = manager
        .lock()
        .history
        .iter()
        .take(2)
        .map(|item| item.id)
        .collect::<Vec<_>>();

    let mut state = manager.lock();
    state.enforce_limits_to(2, usize::MAX);
    assert_eq!(state.history.len(), 2);
    assert_eq!(
        state.history.iter().map(|item| item.id).collect::<Vec<_>>(),
        newest_ids
    );
}

#[test]
fn protocol_rejects_trailing_bytes_invalid_ids_and_unknown_versions() {
    let manager = ClipboardManager::default();
    let mut trailing = request(COMMAND_CLEAR, |_| {});
    trailing.push(0);
    assert_eq!(
        response_kind(&manager.handle_control_packet(&trailing)),
        (RESPONSE_ERROR, STATUS_BAD_REQUEST)
    );
    assert_eq!(
        response_kind(
            &manager.handle_control_packet(&request(COMMAND_ACTIVATE, |encoder| encoder.u64(0),))
        ),
        (RESPONSE_ERROR, STATUS_BAD_REQUEST)
    );
    let mut wrong_version = request(COMMAND_CLEAR, |_| {});
    wrong_version[4] = 2;
    assert_eq!(
        response_kind(&manager.handle_control_packet(&wrong_version)),
        (RESPONSE_ERROR, STATUS_BAD_REQUEST)
    );
}
