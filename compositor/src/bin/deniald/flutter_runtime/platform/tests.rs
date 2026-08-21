use super::*;

fn call(method: &str, arguments: Value) -> Vec<u8> {
    serde_json::to_vec(&json!({"method": method, "args": arguments})).unwrap()
}

#[test]
fn clipboard_round_trip_uses_json_method_envelopes() {
    let mut plugin = PlatformPlugin::new(ClipboardManager::default());
    assert_eq!(
        plugin.handle_platform_message(&call(SET_CLIPBOARD_DATA, json!({"text": "Denial 🦀"}),)),
        b"[null]"
    );
    let response = plugin.handle_platform_message(&call(GET_CLIPBOARD_DATA, json!(TEXT_PLAIN)));
    let decoded: Value = serde_json::from_slice(&response).unwrap();
    assert_eq!(decoded, json!([{"text": "Denial 🦀"}]));
}

#[test]
fn clipboard_rejects_bad_formats_and_oversized_text_atomically() {
    let mut plugin = PlatformPlugin::new(ClipboardManager::default());
    plugin.handle_platform_message(&call(SET_CLIPBOARD_DATA, json!({"text": "preserved"})));

    let bad_format = plugin.handle_platform_message(&call(GET_CLIPBOARD_DATA, json!("image/png")));
    assert_eq!(
        serde_json::from_slice::<Value>(&bad_format).unwrap()[0],
        json!("Unknown clipboard format error")
    );
    let oversized = "x".repeat(MAX_TEXT_BYTES + 1);
    let response =
        plugin.handle_platform_message(&call(SET_CLIPBOARD_DATA, json!({"text": oversized})));
    assert_eq!(
        serde_json::from_slice::<Value>(&response).unwrap()[0],
        json!("Clipboard data too large")
    );
    let response = plugin.handle_platform_message(&call(GET_CLIPBOARD_DATA, json!(TEXT_PLAIN)));
    assert_eq!(
        serde_json::from_slice::<Value>(&response).unwrap(),
        json!([{"text": "preserved"}])
    );
}

#[test]
fn system_navigator_is_acknowledged_and_unknown_methods_are_not_implemented() {
    let mut plugin = PlatformPlugin::new(ClipboardManager::default());
    assert_eq!(
        plugin.handle_platform_message(&call(SYSTEM_NAVIGATOR_POP, Value::Null)),
        b"[null]"
    );
    assert!(
        plugin
            .handle_platform_message(&call("SystemChrome.unknown", Value::Null))
            .is_empty()
    );
}

#[test]
fn malformed_and_oversized_packets_return_bounded_error_envelopes() {
    let mut plugin = PlatformPlugin::new(ClipboardManager::default());
    let oversized = vec![b'x'; MAX_PLATFORM_PACKET_BYTES + 1];
    for data in [b"{".as_slice(), oversized.as_slice()] {
        let response = plugin.handle_platform_message(data);
        let response = serde_json::from_slice::<Value>(&response).unwrap();
        assert_eq!(response.as_array().unwrap().len(), 3);
        assert_eq!(response[0], json!("Bad Arguments"));
    }
}

#[test]
fn has_strings_tracks_native_clipboard_state() {
    let mut plugin = PlatformPlugin::new(ClipboardManager::default());
    let response = plugin.handle_platform_message(&call(HAS_CLIPBOARD_STRINGS, Value::Null));
    assert_eq!(
        serde_json::from_slice::<Value>(&response).unwrap(),
        json!([{"value": false}])
    );
    plugin.handle_platform_message(&call(SET_CLIPBOARD_DATA, json!({"text": "available"})));
    let response = plugin.handle_platform_message(&call(HAS_CLIPBOARD_STRINGS, Value::Null));
    assert_eq!(
        serde_json::from_slice::<Value>(&response).unwrap(),
        json!([{"value": true}])
    );
}
