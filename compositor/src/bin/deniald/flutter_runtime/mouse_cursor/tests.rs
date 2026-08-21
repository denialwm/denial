use super::*;

fn call(method: &str, device: i64, kind: &str) -> Vec<u8> {
    let mut request = Vec::new();
    write_string_value(&mut request, method);
    request.extend_from_slice(&[VALUE_MAP, 2]);
    write_string_value(&mut request, "device");
    if let Ok(device) = i32::try_from(device) {
        request.push(VALUE_INT32);
        request.extend_from_slice(&device.to_ne_bytes());
    } else {
        request.push(VALUE_INT64);
        request.extend_from_slice(&device.to_ne_bytes());
    }
    write_string_value(&mut request, "kind");
    write_string_value(&mut request, kind);
    request
}

#[test]
fn accepts_flutter_standard_method_codec_requests_and_replies() {
    let mut plugin = MouseCursorPlugin::default();
    let request = b"\x07\x14activateSystemCursor\
        \x0d\x02\
        \x07\x06device\x03\x00\x00\x00\x00\
        \x07\x04kind\x07\x05click";

    assert_eq!(
        plugin.handle_platform_message(request),
        [SUCCESS_ENVELOPE, VALUE_NULL]
    );
    assert_eq!(plugin.take_request(), Some("pointer"));
}

#[test]
fn accepts_standard_and_shell_cursor_requests_last_writer_wins() {
    let mut plugin = MouseCursorPlugin::default();

    assert_eq!(
        plugin.handle_platform_message(&call(ACTIVATE_SYSTEM_CURSOR, 0, "click")),
        [SUCCESS_ENVELOPE, VALUE_NULL]
    );
    assert_eq!(
        plugin.handle_platform_message(&call(ACTIVATE_SYSTEM_CURSOR, 0, "handwriting")),
        [SUCCESS_ENVELOPE, VALUE_NULL]
    );
    assert_eq!(plugin.take_request(), Some("handwriting"));
    assert_eq!(plugin.take_request(), None);
}

#[test]
fn normalizes_flutter_resize_names_to_protocol_cursor_shapes() {
    assert_eq!(
        cursor_shape_for_flutter_kind("resizeUpLeftDownRight"),
        Some("nwse-resize")
    );
    assert_eq!(
        cursor_shape_for_flutter_kind("resizeColumn"),
        Some("col-resize")
    );
}

#[test]
fn rejects_invalid_cursor_requests_without_replacing_pending_state() {
    let mut plugin = MouseCursorPlugin::default();
    plugin.handle_platform_message(&call(ACTIVATE_SYSTEM_CURSOR, 0, "text"));

    let mut trailing = call(ACTIVATE_SYSTEM_CURSOR, 0, "click");
    trailing.push(0);
    for request in [
        call(ACTIVATE_SYSTEM_CURSOR, -1, "click"),
        call(ACTIVATE_SYSTEM_CURSOR, 0, "unknown"),
        trailing,
        b"{\"method\":\"activateSystemCursor\"}".to_vec(),
    ] {
        let response = plugin.handle_platform_message(&request);
        assert_eq!(response.first(), Some(&ERROR_ENVELOPE));
        assert_ne!(response, b"[\"Bad Arguments\"]");
    }
    assert_eq!(plugin.take_request(), Some("text"));
}

#[test]
fn unknown_methods_remain_unimplemented() {
    let mut plugin = MouseCursorPlugin::default();
    assert!(
        plugin
            .handle_platform_message(&call("MouseCursor.unknown", 0, "basic"))
            .is_empty()
    );
}
