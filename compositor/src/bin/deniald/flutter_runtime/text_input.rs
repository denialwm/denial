use std::borrow::Cow;
use std::ffi::CStr;
use std::io::Write;

use serde::Deserialize;
use serde_json::{Value, value::RawValue};

#[cfg(test)]
use serde_json::json;

pub const CHANNEL: &CStr = c"flutter/textinput";

const SET_EDITING_STATE: &str = "TextInput.setEditingState";
const CLEAR_CLIENT: &str = "TextInput.clearClient";
const SET_CLIENT: &str = "TextInput.setClient";
const SHOW: &str = "TextInput.show";
const HIDE: &str = "TextInput.hide";
const UPDATE_EDITING_STATE: &str = "TextInputClient.updateEditingState";
const PERFORM_ACTION: &str = "TextInputClient.performAction";
const MULTILINE: &str = "TextInputType.multiline";

const MAX_TEXT_INPUT_PACKET_BYTES: usize = 1024 * 1024;
const MAX_TEXT_UTF16_UNITS: usize = 512 * 1024;
const MAX_METHOD_BYTES: usize = 128;
const MAX_CONFIGURATION_VALUE_BYTES: usize = 256;
const TEXT_EDIT_SLACK_UTF16_UNITS: usize = 32;

const KEY_BACKSPACE: u32 = 14;
const KEY_ENTER: u32 = 28;
const KEY_HOME: u32 = 102;
const KEY_LEFT: u32 = 105;
const KEY_RIGHT: u32 = 106;
const KEY_END: u32 = 107;
const KEY_DELETE: u32 = 111;

pub struct TextInputPlugin {
    client: Option<TextInputClient>,
    client_scratch: Option<TextInputClient>,
    messages: [Vec<u8>; 2],
    text_utf8_scratch: String,
    response_scratch: Vec<u8>,
}

impl Default for TextInputPlugin {
    fn default() -> Self {
        Self {
            client: None,
            client_scratch: None,
            messages: [Vec::with_capacity(512), Vec::with_capacity(128)],
            text_utf8_scratch: String::new(),
            response_scratch: Vec::with_capacity(160),
        }
    }
}

#[derive(Default)]
struct TextInputClient {
    id: i64,
    input_type: String,
    input_action: String,
    model: TextInputModel,
}

#[derive(Deserialize)]
struct TextInputMethodCall<'a> {
    #[serde(borrow)]
    method: Cow<'a, str>,
    #[serde(borrow, default)]
    args: Option<&'a RawValue>,
}

#[derive(Deserialize)]
struct EditingStateFields<'a> {
    #[serde(borrow)]
    text: Option<&'a RawValue>,
    #[serde(rename = "selectionBase", borrow)]
    selection_base: Option<&'a RawValue>,
    #[serde(rename = "selectionExtent", borrow)]
    selection_extent: Option<&'a RawValue>,
}

#[derive(Deserialize)]
struct JsonString<'a>(#[serde(borrow)] Cow<'a, str>);

impl TextInputPlugin {
    pub fn has_client(&self) -> bool {
        self.client.is_some()
    }

    pub fn handle_platform_message(&mut self, data: &[u8]) -> &[u8] {
        if data.len() > MAX_TEXT_INPUT_PACKET_BYTES {
            return &[];
        }
        let Ok(message) = serde_json::from_slice::<TextInputMethodCall<'_>>(data) else {
            return &[];
        };
        let method = message.method.as_ref();
        if method.len() > MAX_METHOD_BYTES {
            return &[];
        }

        let result = match method {
            SHOW | HIDE => Ok(()),
            CLEAR_CLIENT => {
                if let Some(mut client) = self.client.take() {
                    client.clear();
                    self.client_scratch = Some(client);
                }
                Ok(())
            }
            SET_CLIENT => {
                let arguments = message
                    .args
                    .and_then(|arguments| serde_json::from_str(arguments.get()).ok())
                    .unwrap_or(Value::Null);
                self.set_client(&arguments)
            }
            SET_EDITING_STATE => self.set_editing_state(message.args),
            _ => return &[],
        };
        match result {
            Ok(()) => b"[null]",
            Err((code, message)) => {
                self.response_scratch.clear();
                self.response_scratch.push(b'[');
                serde_json::to_writer(&mut self.response_scratch, code)
                    .expect("writing JSON into a Vec cannot fail");
                self.response_scratch.push(b',');
                serde_json::to_writer(&mut self.response_scratch, message)
                    .expect("writing JSON into a Vec cannot fail");
                self.response_scratch.extend_from_slice(b",null]");
                &self.response_scratch
            }
        }
    }

    pub fn on_key_pressed(&mut self, keycode: u32, code_point: u32) -> &[Vec<u8>] {
        let Some(client) = self.client.as_mut() else {
            return &[];
        };
        let mut message_count = 0;
        let changed = match keycode {
            KEY_LEFT => client.model.move_cursor_back(),
            KEY_RIGHT => client.model.move_cursor_forward(),
            KEY_END => client.model.move_cursor_to_end(),
            KEY_HOME => client.model.move_cursor_to_beginning(),
            KEY_BACKSPACE => client.model.backspace(),
            KEY_DELETE => client.model.delete(),
            KEY_ENTER => {
                if client.input_type == MULTILINE && client.model.add_code_point(u32::from('\n')) {
                    update_editing_state(
                        client,
                        &mut self.text_utf8_scratch,
                        &mut self.messages[message_count],
                    );
                    message_count += 1;
                }
                perform_action(client, &mut self.messages[message_count]);
                message_count += 1;
                false
            }
            _ if code_point != 0 => client.model.add_code_point(code_point),
            _ => false,
        };
        if changed {
            update_editing_state(
                client,
                &mut self.text_utf8_scratch,
                &mut self.messages[message_count],
            );
            message_count += 1;
        }
        &self.messages[..message_count]
    }

    pub fn insert_text(&mut self, text: &str) -> &[Vec<u8>] {
        let Some(client) = self.client.as_mut() else {
            return &[];
        };
        if !client.model.add_text(text) {
            return &[];
        }
        update_editing_state(client, &mut self.text_utf8_scratch, &mut self.messages[0]);
        &self.messages[..1]
    }

    fn set_client(&mut self, arguments: &Value) -> Result<(), (&'static str, &'static str)> {
        let Some(arguments) = arguments
            .as_array()
            .filter(|arguments| arguments.len() >= 2)
        else {
            return Err(("Bad Arguments", "Method invoked without args"));
        };
        let Some(id) = arguments[0].as_i64() else {
            return Err(("Bad Arguments", "Could not set client, ID is invalid."));
        };
        let Some(config) = arguments[1].as_object() else {
            return Err(("Bad Arguments", "Could not set client, missing arguments."));
        };
        let input_action = config
            .get("inputAction")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let input_type = config
            .get("inputType")
            .and_then(Value::as_object)
            .and_then(|input_type| input_type.get("name"))
            .and_then(Value::as_str)
            .unwrap_or_default();
        if input_action.len() > MAX_CONFIGURATION_VALUE_BYTES
            || input_type.len() > MAX_CONFIGURATION_VALUE_BYTES
        {
            return Err(("Bad Arguments", "Text input configuration is too large."));
        }
        let mut client = self
            .client
            .take()
            .or_else(|| self.client_scratch.take())
            .unwrap_or_default();
        client.id = id;
        client.input_type.clear();
        client.input_type.push_str(input_type);
        client.input_action.clear();
        client.input_action.push_str(input_action);
        client.model.clear();
        self.client = Some(client);
        Ok(())
    }

    fn set_editing_state(
        &mut self,
        arguments: Option<&RawValue>,
    ) -> Result<(), (&'static str, &'static str)> {
        let Some(arguments) = arguments.and_then(|arguments| {
            serde_json::from_str::<EditingStateFields<'_>>(arguments.get()).ok()
        }) else {
            return Err(("Bad Arguments", "Method invoked without args"));
        };
        let Some(client) = self.client.as_mut() else {
            // Framework focus changes can enqueue clearClient immediately
            // before an older editing-state update reaches the embedder. The
            // update belongs to the retired client and is safe to acknowledge.
            return Ok(());
        };
        let Some(text) = arguments
            .text
            .and_then(|text| serde_json::from_str::<JsonString<'_>>(text.get()).ok())
            .map(|text| text.0)
        else {
            return Err((
                "Bad Arguments",
                "Set editing state has been invoked, but without text.",
            ));
        };
        let (Some(mut base), Some(mut extent)) = (
            arguments
                .selection_base
                .and_then(|value| serde_json::from_str(value.get()).ok()),
            arguments
                .selection_extent
                .and_then(|value| serde_json::from_str(value.get()).ok()),
        ) else {
            return Err((
                "Internal Consistency Error",
                "Selection base/extent values invalid.",
            ));
        };
        if base == -1 && extent == -1 {
            (base, extent) = (0, 0);
        }
        let (Ok(base), Ok(extent)) = (usize::try_from(base), usize::try_from(extent)) else {
            return Err((
                "Internal Consistency Error",
                "Selection base/extent values invalid.",
            ));
        };
        if !client.model.replace_text(text.as_ref(), base, extent) {
            return Err((
                "Bad Arguments",
                "Text or selection exceeds the supported bounds.",
            ));
        }
        Ok(())
    }
}

impl TextInputClient {
    fn clear(&mut self) {
        self.id = 0;
        self.input_type.clear();
        self.input_action.clear();
        self.model.clear();
    }
}

fn update_editing_state(
    client: &TextInputClient,
    text_utf8_scratch: &mut String,
    output: &mut Vec<u8>,
) {
    client.model.write_text(text_utf8_scratch);
    output.clear();
    write!(
        output,
        r#"{{"method":"{UPDATE_EDITING_STATE}","args":[{},{{"composingBase":-1,"composingExtent":-1,"selectionAffinity":"TextAffinity.downstream","selectionBase":{},"selectionExtent":{},"selectionIsDirectional":false,"text":"#,
        client.id, client.model.selection_base, client.model.selection_extent,
    )
    .expect("writing JSON into a Vec cannot fail");
    serde_json::to_writer(&mut *output, text_utf8_scratch)
        .expect("writing JSON into a Vec cannot fail");
    output.extend_from_slice(b"}]}");
}

fn perform_action(client: &TextInputClient, output: &mut Vec<u8>) {
    output.clear();
    write!(
        output,
        r#"{{"method":"{PERFORM_ACTION}","args":[{},"#,
        client.id,
    )
    .expect("writing JSON into a Vec cannot fail");
    serde_json::to_writer(&mut *output, &client.input_action)
        .expect("writing JSON into a Vec cannot fail");
    output.extend_from_slice(b"]}");
}

#[derive(Default)]
struct TextInputModel {
    text: Vec<u16>,
    replacement_scratch: Vec<u16>,
    selection_base: usize,
    selection_extent: usize,
}

impl TextInputModel {
    fn clear(&mut self) {
        self.text.clear();
        self.replacement_scratch.clear();
        self.selection_base = 0;
        self.selection_extent = 0;
    }

    fn replace_text(&mut self, text: &str, base: usize, extent: usize) -> bool {
        self.replacement_scratch.clear();
        self.replacement_scratch.extend(text.encode_utf16());
        if self.replacement_scratch.len() > MAX_TEXT_UTF16_UNITS
            || !valid_selection_boundary(&self.replacement_scratch, base)
            || !valid_selection_boundary(&self.replacement_scratch, extent)
        {
            return false;
        }
        std::mem::swap(&mut self.text, &mut self.replacement_scratch);
        self.text.reserve(
            MAX_TEXT_UTF16_UNITS
                .saturating_sub(self.text.len())
                .min(TEXT_EDIT_SLACK_UTF16_UNITS),
        );
        self.selection_base = base;
        self.selection_extent = extent;
        true
    }

    #[cfg(test)]
    fn set_selection(&mut self, base: usize, extent: usize) -> bool {
        if !valid_selection_boundary(&self.text, base)
            || !valid_selection_boundary(&self.text, extent)
        {
            return false;
        }
        self.selection_base = base;
        self.selection_extent = extent;
        true
    }

    #[cfg(test)]
    fn text(&self) -> String {
        String::from_utf16_lossy(&self.text)
    }

    fn write_text(&self, output: &mut String) {
        output.clear();
        output.extend(
            char::decode_utf16(self.text.iter().copied())
                .map(|character| character.unwrap_or(char::REPLACEMENT_CHARACTER)),
        );
    }

    fn selection_start(&self) -> usize {
        self.selection_base.min(self.selection_extent)
    }

    fn selection_end(&self) -> usize {
        self.selection_base.max(self.selection_extent)
    }

    fn delete_selected(&mut self) -> bool {
        let start = self.selection_start();
        let end = self.selection_end();
        if start == end {
            return false;
        }
        self.remove_range(start, end);
        self.selection_base = start;
        self.selection_extent = start;
        true
    }

    fn add_code_point(&mut self, code_point: u32) -> bool {
        let character = char::from_u32(code_point).unwrap_or(char::REPLACEMENT_CHARACTER);
        let mut encoded = [0; 2];
        let encoded = character.encode_utf16(&mut encoded);
        let selected = self.selection_end() - self.selection_start();
        let Some(next_len) = self
            .text
            .len()
            .checked_sub(selected)
            .and_then(|len| len.checked_add(encoded.len()))
        else {
            return false;
        };
        if next_len > MAX_TEXT_UTF16_UNITS {
            return false;
        }
        self.delete_selected();
        let position = self.selection_extent;
        let old_len = self.text.len();
        self.text.resize(next_len, 0);
        self.text
            .copy_within(position..old_len, position + encoded.len());
        self.text[position..position + encoded.len()].copy_from_slice(encoded);
        let position = position + encoded.len();
        self.selection_base = position;
        self.selection_extent = position;
        true
    }

    fn add_text(&mut self, text: &str) -> bool {
        self.replacement_scratch.clear();
        self.replacement_scratch.extend(text.encode_utf16());
        if self.replacement_scratch.is_empty() {
            return false;
        }

        let start = self.selection_start();
        let end = self.selection_end();
        let selected = end - start;
        let Some(next_len) = self
            .text
            .len()
            .checked_sub(selected)
            .and_then(|len| len.checked_add(self.replacement_scratch.len()))
        else {
            return false;
        };
        if next_len > MAX_TEXT_UTF16_UNITS {
            return false;
        }

        if selected != 0 {
            self.text.copy_within(end.., start);
            self.text.truncate(self.text.len() - selected);
        }
        let inserted = self.replacement_scratch.len();
        let old_len = self.text.len();
        self.text.resize(next_len, 0);
        self.text.copy_within(start..old_len, start + inserted);
        self.text[start..start + inserted].copy_from_slice(&self.replacement_scratch);
        self.selection_base = start + inserted;
        self.selection_extent = start + inserted;
        true
    }

    fn backspace(&mut self) -> bool {
        if self.delete_selected() {
            return true;
        }
        let position = self.selection_extent;
        if position == 0 {
            return false;
        }
        let count = if position >= 2
            && is_trailing_surrogate(self.text[position - 1])
            && is_leading_surrogate(self.text[position - 2])
        {
            2
        } else {
            1
        };
        self.remove_range(position - count, position);
        self.selection_base = position - count;
        self.selection_extent = position - count;
        true
    }

    fn delete(&mut self) -> bool {
        if self.delete_selected() {
            return true;
        }
        let position = self.selection_extent;
        if position == self.text.len() {
            return false;
        }
        let count = if position + 1 < self.text.len()
            && is_leading_surrogate(self.text[position])
            && is_trailing_surrogate(self.text[position + 1])
        {
            2
        } else {
            1
        };
        self.remove_range(position, position + count);
        true
    }

    fn remove_range(&mut self, start: usize, end: usize) {
        debug_assert!(start <= end && end <= self.text.len());
        let old_len = self.text.len();
        self.text.copy_within(end..old_len, start);
        self.text.truncate(old_len - (end - start));
    }

    fn move_cursor_back(&mut self) -> bool {
        if self.selection_base != self.selection_extent {
            let position = self.selection_start();
            self.selection_base = position;
            self.selection_extent = position;
            return true;
        }
        let position = self.selection_extent;
        if position == 0 {
            return false;
        }
        let count = if position >= 2
            && is_trailing_surrogate(self.text[position - 1])
            && is_leading_surrogate(self.text[position - 2])
        {
            2
        } else {
            1
        };
        self.selection_base = position - count;
        self.selection_extent = position - count;
        true
    }

    fn move_cursor_forward(&mut self) -> bool {
        if self.selection_base != self.selection_extent {
            let position = self.selection_end();
            self.selection_base = position;
            self.selection_extent = position;
            return true;
        }
        let position = self.selection_extent;
        if position == self.text.len() {
            return false;
        }
        let count = if position + 1 < self.text.len()
            && is_leading_surrogate(self.text[position])
            && is_trailing_surrogate(self.text[position + 1])
        {
            2
        } else {
            1
        };
        self.selection_base = position + count;
        self.selection_extent = position + count;
        true
    }

    fn move_cursor_to_beginning(&mut self) -> bool {
        if self.selection_base == 0 && self.selection_extent == 0 {
            return false;
        }
        self.selection_base = 0;
        self.selection_extent = 0;
        true
    }

    fn move_cursor_to_end(&mut self) -> bool {
        let end = self.text.len();
        if self.selection_base == end && self.selection_extent == end {
            return false;
        }
        self.selection_base = end;
        self.selection_extent = end;
        true
    }
}

fn valid_selection_boundary(text: &[u16], position: usize) -> bool {
    if position > text.len() {
        return false;
    }
    position == 0
        || position == text.len()
        || !(is_leading_surrogate(text[position - 1]) && is_trailing_surrogate(text[position]))
}

fn is_leading_surrogate(code_unit: u16) -> bool {
    (0xd800..=0xdbff).contains(&code_unit)
}

fn is_trailing_surrogate(code_unit: u16) -> bool {
    (0xdc00..=0xdfff).contains(&code_unit)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(method: &str, arguments: Value) -> Vec<u8> {
        serde_json::to_vec(&json!({"method": method, "args": arguments})).unwrap()
    }

    #[test]
    fn text_model_moves_and_deletes_utf16_code_points() {
        let mut model = TextInputModel::default();
        assert!(model.replace_text("a😀b", 3, 3));
        assert!(model.move_cursor_back());
        assert_eq!(model.selection_extent, 1);
        assert!(model.delete());
        assert_eq!(model.text(), "ab");
        assert!(model.backspace());
        assert_eq!(model.text(), "b");
    }

    #[test]
    fn text_model_rejects_split_surrogates_and_bounded_growth_atomically() {
        let mut model = TextInputModel::default();
        assert!(model.replace_text("safe", 4, 4));
        assert!(!model.replace_text("😀", 1, 1));
        assert_eq!(model.text(), "safe");

        model.text = vec![u16::from(b'a'); MAX_TEXT_UTF16_UNITS];
        model.selection_base = model.text.len();
        model.selection_extent = model.text.len();
        assert!(!model.add_code_point(u32::from('b')));
        assert_eq!(model.text.len(), MAX_TEXT_UTF16_UNITS);

        assert!(model.set_selection(MAX_TEXT_UTF16_UNITS - 1, MAX_TEXT_UTF16_UNITS));
        assert!(model.add_code_point(u32::from('b')));
        assert_eq!(model.text.len(), MAX_TEXT_UTF16_UNITS);
    }

    #[test]
    fn plugin_accepts_client_and_publishes_editing_updates() {
        let mut plugin = TextInputPlugin::default();
        let response = plugin.handle_platform_message(&call(
            SET_CLIENT,
            json!([7, {
                "inputAction": "TextInputAction.search",
                "inputType": {"name": "TextInputType.text"}
            }]),
        ));
        assert_eq!(response, b"[null]");
        let response = plugin.handle_platform_message(&call(
            SET_EDITING_STATE,
            json!({"text": "ab", "selectionBase": 2, "selectionExtent": 2}),
        ));
        assert_eq!(response, b"[null]");

        let messages = plugin.on_key_pressed(30, u32::from('à'));
        assert_eq!(messages.len(), 1);
        let update: Value = serde_json::from_slice(&messages[0]).unwrap();
        assert_eq!(update["method"], UPDATE_EDITING_STATE);
        assert_eq!(update["args"][1]["text"], "abà");
        assert_eq!(update["args"][1]["selectionBase"], 3);
    }

    #[test]
    fn shell_keyboard_text_replaces_the_active_flutter_selection() {
        let mut plugin = TextInputPlugin::default();
        assert!(!plugin.has_client());
        assert_eq!(
            plugin.handle_platform_message(&call(
                SET_CLIENT,
                json!([9, {
                    "inputAction": "TextInputAction.done",
                    "inputType": {"name": "TextInputType.text"}
                }]),
            )),
            b"[null]"
        );
        assert_eq!(
            plugin.handle_platform_message(&call(
                SET_EDITING_STATE,
                json!({"text": "before", "selectionBase": 0, "selectionExtent": 6}),
            )),
            b"[null]"
        );

        assert!(plugin.has_client());
        let messages = plugin.insert_text("after 😀");
        assert_eq!(messages.len(), 1);
        let update: Value = serde_json::from_slice(&messages[0]).unwrap();
        assert_eq!(update["method"], UPDATE_EDITING_STATE);
        assert_eq!(update["args"][1]["text"], "after 😀");
        assert_eq!(update["args"][1]["selectionBase"], 8);
        assert_eq!(update["args"][1]["selectionExtent"], 8);
    }

    #[test]
    fn key_updates_reuse_buffers_and_escape_text_without_a_json_dom() {
        let mut plugin = TextInputPlugin::default();
        assert_eq!(
            plugin.handle_platform_message(&call(
                SET_CLIENT,
                json!([17, {
                    "inputAction": "TextInputAction.newline\"quoted",
                    "inputType": {"name": MULTILINE}
                }]),
            )),
            b"[null]"
        );
        assert_eq!(
            plugin.handle_platform_message(&call(
                SET_EDITING_STATE,
                json!({
                    "text": "quote: \" slash: \\ emoji: 😀",
                    "selectionBase": 27,
                    "selectionExtent": 27
                }),
            )),
            b"[null]"
        );

        let (first_pointer, first_capacity) = {
            let messages = plugin.on_key_pressed(30, u32::from('!'));
            assert_eq!(messages.len(), 1);
            let update: Value = serde_json::from_slice(&messages[0]).unwrap();
            assert_eq!(update["args"][1]["text"], "quote: \" slash: \\ emoji: 😀!");
            (messages[0].as_ptr(), messages[0].capacity())
        };
        let messages = plugin.on_key_pressed(KEY_BACKSPACE, 0);
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].as_ptr(), first_pointer);
        assert_eq!(messages[0].capacity(), first_capacity);

        let messages = plugin.on_key_pressed(KEY_ENTER, u32::from('\n'));
        assert_eq!(messages.len(), 2);
        let update: Value = serde_json::from_slice(&messages[0]).unwrap();
        let action: Value = serde_json::from_slice(&messages[1]).unwrap();
        assert_eq!(update["method"], UPDATE_EDITING_STATE);
        assert_eq!(update["args"][1]["text"], "quote: \" slash: \\ emoji: 😀\n");
        assert_eq!(action["method"], PERFORM_ACTION);
        assert_eq!(action["args"][1], "TextInputAction.newline\"quoted");
    }

    #[test]
    fn normal_editing_state_json_borrows_method_and_text() {
        let bytes = r#"{"method":"TextInput.setEditingState","args":{"text":"plain utf8 à","selectionBase":12,"selectionExtent":12}}"#
            .as_bytes();
        let message = serde_json::from_slice::<TextInputMethodCall<'_>>(bytes).unwrap();
        assert!(matches!(message.method, Cow::Borrowed(_)));
        let fields =
            serde_json::from_str::<EditingStateFields<'_>>(message.args.unwrap().get()).unwrap();
        let text = serde_json::from_str::<JsonString<'_>>(fields.text.unwrap().get())
            .unwrap()
            .0;
        assert!(matches!(text, Cow::Borrowed("plain utf8 à")));
    }

    #[test]
    fn cleared_clients_reuse_text_and_configuration_storage() {
        let mut plugin = TextInputPlugin::default();
        let configure = || {
            call(
                SET_CLIENT,
                json!([31, {
                    "inputAction": "TextInputAction.search",
                    "inputType": {"name": "TextInputType.text"}
                }]),
            )
        };
        assert_eq!(plugin.handle_platform_message(&configure()), b"[null]");
        assert_eq!(
            plugin.handle_platform_message(&call(
                SET_EDITING_STATE,
                json!({
                    "text": "a moderately sized retained input buffer",
                    "selectionBase": 40,
                    "selectionExtent": 40
                }),
            )),
            b"[null]"
        );
        let client = plugin.client.as_ref().unwrap();
        let text_pointer = client.model.text.as_ptr();
        let text_capacity = client.model.text.capacity();
        let action_pointer = client.input_action.as_ptr();

        assert_eq!(
            plugin.handle_platform_message(&call(CLEAR_CLIENT, Value::Null)),
            b"[null]"
        );
        assert_eq!(plugin.handle_platform_message(&configure()), b"[null]");
        let client = plugin.client.as_ref().unwrap();
        assert_eq!(client.model.text.as_ptr(), text_pointer);
        assert_eq!(client.model.text.capacity(), text_capacity);
        assert_eq!(client.input_action.as_ptr(), action_pointer);
    }

    #[test]
    fn stale_editing_state_after_clear_is_acknowledged() {
        let mut plugin = TextInputPlugin::default();
        let response = plugin.handle_platform_message(&call(
            SET_EDITING_STATE,
            json!({"text": "stale", "selectionBase": 5, "selectionExtent": 5}),
        ));
        assert_eq!(response, b"[null]");
    }

    #[test]
    fn hostile_json_and_invalid_utf16_selections_are_rejected() {
        let mut plugin = TextInputPlugin::default();
        assert!(
            plugin
                .handle_platform_message(&vec![b' '; MAX_TEXT_INPUT_PACKET_BYTES + 1])
                .is_empty()
        );
        assert_eq!(
            plugin.handle_platform_message(&call(
                SET_CLIENT,
                json!([1, {
                    "inputAction": "TextInputAction.done",
                    "inputType": {"name": "TextInputType.text"}
                }]),
            )),
            b"[null]"
        );

        let response = plugin.handle_platform_message(&call(
            SET_EDITING_STATE,
            json!({"text": "😀", "selectionBase": 1, "selectionExtent": 1}),
        ));
        let response: Value = serde_json::from_slice(response).expect("JSON error response");
        assert_eq!(response[0], "Bad Arguments");
        assert_eq!(plugin.client.as_ref().unwrap().model.text(), "");

        let response = plugin.handle_platform_message(&call(
            SET_EDITING_STATE,
            json!({"text": "ok", "selectionBase": -2, "selectionExtent": 0}),
        ));
        let response: Value = serde_json::from_slice(response).expect("JSON error response");
        assert_eq!(response[0], "Internal Consistency Error");
        assert_eq!(plugin.client.as_ref().unwrap().model.text(), "");
    }
}
