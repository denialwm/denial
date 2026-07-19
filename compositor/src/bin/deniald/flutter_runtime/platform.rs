use std::ffi::CStr;

use serde_json::{Value, json};

pub const CHANNEL: &CStr = c"flutter/platform";

const GET_CLIPBOARD_DATA: &str = "Clipboard.getData";
const SET_CLIPBOARD_DATA: &str = "Clipboard.setData";
const SYSTEM_NAVIGATOR_POP: &str = "SystemNavigator.pop";
const TEXT_PLAIN: &str = "text/plain";
const MAX_PLATFORM_PACKET_BYTES: usize = 1024 * 1024;
const MAX_CLIPBOARD_BYTES: usize = 512 * 1024;

#[derive(Default)]
pub(super) struct PlatformPlugin {
    clipboard: String,
}

impl PlatformPlugin {
    pub(super) fn handle_platform_message(&mut self, data: &[u8]) -> Vec<u8> {
        if data.len() > MAX_PLATFORM_PACKET_BYTES {
            return error(
                "Bad Arguments",
                "Platform message exceeds the supported limit.",
            );
        }
        let Ok(message) = serde_json::from_slice::<Value>(data) else {
            return error("Bad Arguments", "Platform message is not valid JSON.");
        };
        let Some(method) = message.get("method").and_then(Value::as_str) else {
            return error("Bad Arguments", "Platform message has no method.");
        };
        let arguments = message.get("args").unwrap_or(&Value::Null);

        match method {
            GET_CLIPBOARD_DATA => self.get_clipboard(arguments),
            SET_CLIPBOARD_DATA => self.set_clipboard(arguments),
            SYSTEM_NAVIGATOR_POP => success(Value::Null),
            // An empty response is the JSONMethodCodec representation used by
            // Flutter for a method that the platform does not implement.
            _ => Vec::new(),
        }
    }

    fn get_clipboard(&self, arguments: &Value) -> Vec<u8> {
        if arguments.as_str() != Some(TEXT_PLAIN) {
            return error(
                "Unknown clipboard format error",
                "Clipboard API only supports text/plain.",
            );
        }
        success(json!({"text": self.clipboard}))
    }

    fn set_clipboard(&mut self, arguments: &Value) -> Vec<u8> {
        let Some(text) = arguments
            .as_object()
            .and_then(|arguments| arguments.get("text"))
            .and_then(Value::as_str)
        else {
            return error(
                "Unknown clipboard format error",
                "Clipboard data must contain a text string.",
            );
        };
        if text.len() > MAX_CLIPBOARD_BYTES {
            return error(
                "Clipboard data too large",
                "Clipboard text exceeds the supported limit.",
            );
        }
        self.clipboard.clear();
        self.clipboard.push_str(text);
        success(Value::Null)
    }
}

fn success(value: Value) -> Vec<u8> {
    serde_json::to_vec(&json!([value])).unwrap_or_default()
}

fn error(code: &str, message: &str) -> Vec<u8> {
    serde_json::to_vec(&json!([code, message, null])).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(method: &str, arguments: Value) -> Vec<u8> {
        serde_json::to_vec(&json!({"method": method, "args": arguments})).unwrap()
    }

    #[test]
    fn clipboard_round_trip_uses_json_method_envelopes() {
        let mut plugin = PlatformPlugin::default();
        assert_eq!(
            plugin
                .handle_platform_message(&call(SET_CLIPBOARD_DATA, json!({"text": "Denial 🦀"}),)),
            b"[null]"
        );
        let response = plugin.handle_platform_message(&call(GET_CLIPBOARD_DATA, json!(TEXT_PLAIN)));
        let decoded: Value = serde_json::from_slice(&response).unwrap();
        assert_eq!(decoded, json!([{"text": "Denial 🦀"}]));
    }

    #[test]
    fn clipboard_rejects_bad_formats_and_oversized_text_atomically() {
        let mut plugin = PlatformPlugin::default();
        plugin.handle_platform_message(&call(SET_CLIPBOARD_DATA, json!({"text": "preserved"})));

        let bad_format =
            plugin.handle_platform_message(&call(GET_CLIPBOARD_DATA, json!("image/png")));
        assert_eq!(
            serde_json::from_slice::<Value>(&bad_format).unwrap()[0],
            json!("Unknown clipboard format error")
        );
        let oversized = "x".repeat(MAX_CLIPBOARD_BYTES + 1);
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
        let mut plugin = PlatformPlugin::default();
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
        let mut plugin = PlatformPlugin::default();
        let oversized = vec![b'x'; MAX_PLATFORM_PACKET_BYTES + 1];
        for data in [b"{".as_slice(), oversized.as_slice()] {
            let response = plugin.handle_platform_message(data);
            let response = serde_json::from_slice::<Value>(&response).unwrap();
            assert_eq!(response.as_array().unwrap().len(), 3);
            assert_eq!(response[0], json!("Bad Arguments"));
        }
    }
}
