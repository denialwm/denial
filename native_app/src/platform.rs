use denial_flutter_engine::{EngineError, RunningEngine};

// Reuse these implementations verbatim. They are private Denial modules, so
// this prototype deliberately builds from the same checkout as its host crate.
#[allow(dead_code)]
#[path = "../../compositor/src/bin/deniald/flutter_runtime/mouse_cursor.rs"]
mod mouse_cursor;
#[allow(dead_code)]
#[path = "../../compositor/src/bin/deniald/flutter_runtime/text_input.rs"]
pub(crate) mod text_input;

#[derive(Default)]
pub struct Platform {
    text_input: text_input::TextInputPlugin,
    mouse_cursor: mouse_cursor::MouseCursorPlugin,
}

pub struct Reply {
    pub data: Vec<u8>,
    pub cursor: Option<&'static str>,
    pub close: bool,
}

impl Platform {
    pub fn handle(&mut self, channel: &str, data: &[u8]) -> Reply {
        let mut reply = Reply {
            data: Vec::new(),
            cursor: None,
            close: false,
        };
        match channel {
            "denial/settings_activation" => {
                if let Ok(call) = serde_json::from_slice::<serde_json::Value>(data) {
                    match call["method"].as_str() {
                        Some("closeWindow") => {
                            reply.close = true;
                            reply.data = b"[null]".to_vec();
                        }
                        Some("openUrl") => {
                            let uri = call["args"].as_str().and_then(|s| url::Url::parse(s).ok());
                            reply.data = match uri.filter(|u| {
                                matches!(u.scheme(), "https" | "http") && u.host_str().is_some()
                            }) {
                                Some(uri) => match std::process::Command::new("xdg-open")
                                    .arg(uri.as_str())
                                    .stdin(std::process::Stdio::null())
                                    .stdout(std::process::Stdio::null())
                                    .spawn()
                                {
                                    Ok(mut child) => {
                                        std::thread::spawn(move || {
                                            let _ = child.wait();
                                        });
                                        b"[null]".to_vec()
                                    }
                                    Err(_) => b"[\"open-url\",\"Could not open the web URL\",null]"
                                        .to_vec(),
                                },
                                None => b"[\"invalid-url\",\"Expected a web URL\",null]".to_vec(),
                            };
                        }
                        _ => {}
                    }
                }
            }
            "flutter/textinput" => reply
                .data
                .extend_from_slice(self.text_input.handle_platform_message(data)),
            "flutter/mousecursor" => {
                reply.data = self.mouse_cursor.handle_platform_message(data);
                reply.cursor = self.mouse_cursor.take_request();
            }
            "flutter/platform" => {
                if let Ok(call) = serde_json::from_slice::<serde_json::Value>(data) {
                    match call.get("method").and_then(|m| m.as_str()) {
                        Some("SystemNavigator.pop") => {
                            reply.close = true;
                            reply.data = b"[null]".to_vec();
                        }
                        Some(
                            "SystemChrome.setApplicationSwitcherDescription"
                            | "SystemChrome.setEnabledSystemUIMode"
                            | "SystemChrome.setSystemUIOverlayStyle",
                        ) => reply.data = b"[null]".to_vec(),
                        _ => {}
                    }
                }
            }
            _ => {} // Empty response means MethodNotImplemented, not success.
        }
        reply
    }

    /// What changed in the focused field since the last call.
    pub fn text_input_change(&mut self) -> Option<text_input::TextInputSnapshot> {
        self.text_input.take_state_change()
    }

    /// Applies the on-screen keyboard's edit to Flutter's `client`.
    pub fn input_method(
        &mut self,
        engine: &RunningEngine,
        client: i64,
        transaction: &crate::wayland_frontend::input_method::InputMethodTransaction,
    ) -> Result<(), EngineError> {
        for message in self.text_input.apply_input_method(client, transaction) {
            engine.send_platform_message(text_input::CHANNEL, message)?;
        }
        Ok(())
    }

    pub fn text_key(
        &mut self,
        engine: &RunningEngine,
        code: u32,
        text: Option<&str>,
    ) -> Result<(), EngineError> {
        let mut characters = text.unwrap_or("").chars();
        let first = characters.next().map(u32::from).unwrap_or(0);
        for message in self.text_input.on_key_pressed(code, first) {
            engine.send_platform_message(text_input::CHANNEL, message)?;
        }
        for character in characters {
            for message in self.text_input.on_key_pressed(0, u32::from(character)) {
                engine.send_platform_message(text_input::CHANNEL, message)?;
            }
        }
        Ok(())
    }
}
