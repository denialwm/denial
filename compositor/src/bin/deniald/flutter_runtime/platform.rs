use std::ffi::CStr;

use serde_json::{Value, json};

use super::super::clipboard::{ClipboardError, ClipboardManager, MAX_TEXT_BYTES};

pub const CHANNEL: &CStr = c"flutter/platform";

const GET_CLIPBOARD_DATA: &str = "Clipboard.getData";
const SET_CLIPBOARD_DATA: &str = "Clipboard.setData";
const HAS_CLIPBOARD_STRINGS: &str = "Clipboard.hasStrings";
const SYSTEM_NAVIGATOR_POP: &str = "SystemNavigator.pop";
const TEXT_PLAIN: &str = "text/plain";
const MAX_PLATFORM_PACKET_BYTES: usize = MAX_TEXT_BYTES + 64 * 1024;

pub(super) struct PlatformPlugin {
    clipboard: ClipboardManager,
}

impl PlatformPlugin {
    pub(super) fn new(clipboard: ClipboardManager) -> Self {
        Self { clipboard }
    }

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
            HAS_CLIPBOARD_STRINGS => self.has_clipboard_strings(),
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
        success(
            self.clipboard
                .current_text()
                .map_or(Value::Null, |text| json!({"text": text})),
        )
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
        if text.len() > MAX_TEXT_BYTES {
            return error(
                "Clipboard data too large",
                "Clipboard text exceeds the supported limit.",
            );
        }
        match self.clipboard.set_text(text) {
            Ok(_) => success(Value::Null),
            Err(ClipboardError::Locked) => error(
                "Clipboard unavailable",
                "Clipboard access is disabled while the session is locked.",
            ),
            Err(ClipboardError::TooLarge) => error(
                "Clipboard data too large",
                "Clipboard text exceeds the supported limit.",
            ),
            Err(_) => error(
                "Unknown clipboard format error",
                "Clipboard text contains unsupported data.",
            ),
        }
    }

    fn has_clipboard_strings(&self) -> Vec<u8> {
        success(json!({"value": self.clipboard.has_strings()}))
    }
}

fn success(value: Value) -> Vec<u8> {
    serde_json::to_vec(&json!([value])).unwrap_or_default()
}

fn error(code: &str, message: &str) -> Vec<u8> {
    serde_json::to_vec(&json!([code, message, null])).unwrap_or_default()
}
