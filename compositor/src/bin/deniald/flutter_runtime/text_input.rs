use std::borrow::Cow;
use std::ffi::CStr;
use std::io::Write;

use serde::Deserialize;
use serde_json::{Value, value::RawValue};

use super::super::wayland_frontend::input_method::InputMethodTransaction;

#[cfg(test)]
use serde_json::json;

pub const CHANNEL: &CStr = c"flutter/textinput";

const SET_EDITING_STATE: &str = "TextInput.setEditingState";
const CLEAR_CLIENT: &str = "TextInput.clearClient";
const SET_CLIENT: &str = "TextInput.setClient";
const SHOW: &str = "TextInput.show";
const HIDE: &str = "TextInput.hide";
const SET_EDITABLE_SIZE_AND_TRANSFORM: &str = "TextInput.setEditableSizeAndTransform";
const SET_MARKED_TEXT_RECT: &str = "TextInput.setMarkedTextRect";
const SET_CARET_RECT: &str = "TextInput.setCaretRect";
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
    input_panel_visible: bool,
    lifecycle_revision: u64,
    state_revision: u64,
    state_dirty: bool,
    messages: [Vec<u8>; 2],
    text_utf8_scratch: String,
    response_scratch: Vec<u8>,
}

impl Default for TextInputPlugin {
    fn default() -> Self {
        Self {
            client: None,
            client_scratch: None,
            input_panel_visible: false,
            lifecycle_revision: 0,
            state_revision: 0,
            state_dirty: true,
            messages: [Vec::with_capacity(512), Vec::with_capacity(128)],
            text_utf8_scratch: String::new(),
            response_scratch: Vec::with_capacity(160),
        }
    }
}

struct TextInputClient {
    id: i64,
    input_type: String,
    input_action: String,
    obscure_text: bool,
    enable_personalized_learning: bool,
    editable_transform: [f64; 16],
    caret_rect: Option<TextInputRectangle>,
    marked_text_rect: Option<TextInputRectangle>,
    model: TextInputModel,
}

impl Default for TextInputClient {
    fn default() -> Self {
        let mut editable_transform = [0.0; 16];
        editable_transform[0] = 1.0;
        editable_transform[5] = 1.0;
        editable_transform[10] = 1.0;
        editable_transform[15] = 1.0;
        Self {
            id: 0,
            input_type: String::new(),
            input_action: String::new(),
            obscure_text: false,
            enable_personalized_learning: true,
            editable_transform,
            caret_rect: None,
            marked_text_rect: None,
            model: TextInputModel::default(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct TextInputRectangle {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct TextInputSnapshot {
    pub revision: u64,
    pub lifecycle_revision: u64,
    pub client_id: i64,
    pub active: bool,
    pub input_panel_visible: bool,
    pub secure: bool,
    pub surrounding_text: Option<String>,
    pub cursor: u32,
    pub anchor: u32,
    pub content_hint: u32,
    pub content_purpose: u32,
    pub cursor_rectangle: Option<TextInputRectangle>,
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
    #[serde(rename = "composingBase", borrow)]
    composing_base: Option<&'a RawValue>,
    #[serde(rename = "composingExtent", borrow)]
    composing_extent: Option<&'a RawValue>,
}

#[derive(Deserialize)]
struct EditableGeometry {
    width: f64,
    height: f64,
    transform: Vec<f64>,
}

#[derive(Deserialize)]
struct RectangleFields {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

#[derive(Deserialize)]
struct JsonString<'a>(#[serde(borrow)] Cow<'a, str>);

impl TextInputPlugin {
    pub fn take_state_change(&mut self) -> Option<TextInputSnapshot> {
        if !self.state_dirty {
            return None;
        }
        self.state_dirty = false;
        let Some(client) = self.client.as_ref() else {
            return Some(TextInputSnapshot {
                revision: self.state_revision,
                lifecycle_revision: self.lifecycle_revision,
                client_id: 0,
                active: false,
                input_panel_visible: false,
                secure: false,
                surrounding_text: None,
                cursor: 0,
                anchor: 0,
                content_hint: 0,
                content_purpose: 0,
                cursor_rectangle: None,
            });
        };
        let (surrounding_text, cursor, anchor) = client
            .model
            .surrounding_text(MAX_TEXT_INPUT_PACKET_BYTES.min(4000))
            .map_or((None, 0, 0), |(text, cursor, anchor)| {
                (Some(text), cursor, anchor)
            });
        Some(TextInputSnapshot {
            revision: self.state_revision,
            lifecycle_revision: self.lifecycle_revision,
            client_id: client.id,
            active: true,
            input_panel_visible: self.input_panel_visible,
            secure: client.obscure_text,
            surrounding_text,
            cursor,
            anchor,
            content_hint: client.content_hint(),
            content_purpose: client.content_purpose(),
            cursor_rectangle: client.transformed_cursor_rectangle(),
        })
    }

    fn note_client_change(&mut self) {
        self.lifecycle_revision = self.lifecycle_revision.wrapping_add(1);
        self.note_state_change();
    }

    fn note_state_change(&mut self) {
        self.state_revision = self.state_revision.wrapping_add(1);
        self.state_dirty = true;
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
            SHOW => {
                if self.client.is_some() && !self.input_panel_visible {
                    self.input_panel_visible = true;
                    self.note_state_change();
                }
                Ok(())
            }
            HIDE => {
                if self.input_panel_visible {
                    self.input_panel_visible = false;
                    self.note_state_change();
                }
                Ok(())
            }
            CLEAR_CLIENT => {
                if let Some(mut client) = self.client.take() {
                    client.clear();
                    self.client_scratch = Some(client);
                    self.input_panel_visible = false;
                    self.note_client_change();
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
            SET_EDITABLE_SIZE_AND_TRANSFORM => self.set_editable_size_and_transform(message.args),
            SET_MARKED_TEXT_RECT => self.set_text_rectangle(message.args, false),
            SET_CARET_RECT => self.set_text_rectangle(message.args, true),
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
        if message_count > 0 {
            self.note_state_change();
        }
        &self.messages[..message_count]
    }

    #[cfg(test)]
    pub fn insert_text(&mut self, text: &str) -> &[Vec<u8>] {
        let Some(client) = self.client.as_mut() else {
            return &[];
        };
        if !client.model.add_text(text) {
            return &[];
        }
        update_editing_state(client, &mut self.text_utf8_scratch, &mut self.messages[0]);
        self.note_state_change();
        &self.messages[..1]
    }

    pub fn apply_input_method(
        &mut self,
        client_id: i64,
        transaction: &InputMethodTransaction,
    ) -> &[Vec<u8>] {
        let Some(client) = self.client.as_mut().filter(|client| client.id == client_id) else {
            return &[];
        };
        if !client.model.apply_input_method(transaction) {
            return &[];
        }
        update_editing_state(client, &mut self.text_utf8_scratch, &mut self.messages[0]);
        self.note_state_change();
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
        client.obscure_text = config
            .get("obscureText")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        client.enable_personalized_learning = config
            .get("enableIMEPersonalizedLearning")
            .and_then(Value::as_bool)
            .unwrap_or(true);
        client.reset_geometry();
        client.model.clear();
        self.client = Some(client);
        self.input_panel_visible = false;
        self.note_client_change();
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
        let composing = match (
            arguments
                .composing_base
                .and_then(|value| serde_json::from_str::<i64>(value.get()).ok()),
            arguments
                .composing_extent
                .and_then(|value| serde_json::from_str::<i64>(value.get()).ok()),
        ) {
            (Some(-1), Some(-1)) | (None, None) => None,
            (Some(base), Some(extent)) => {
                let (Ok(base), Ok(extent)) = (usize::try_from(base), usize::try_from(extent))
                else {
                    return Err((
                        "Internal Consistency Error",
                        "Composing range values invalid.",
                    ));
                };
                Some((base, extent))
            }
            _ => {
                return Err((
                    "Internal Consistency Error",
                    "Composing range values invalid.",
                ));
            }
        };
        if !client
            .model
            .replace_editing_state(text.as_ref(), base, extent, composing)
        {
            return Err((
                "Bad Arguments",
                "Text, selection, or composing range exceeds the supported bounds.",
            ));
        }
        self.note_state_change();
        Ok(())
    }

    fn set_editable_size_and_transform(
        &mut self,
        arguments: Option<&RawValue>,
    ) -> Result<(), (&'static str, &'static str)> {
        let Some(arguments) = arguments
            .and_then(|arguments| serde_json::from_str::<EditableGeometry>(arguments.get()).ok())
        else {
            return Err(("Bad Arguments", "Editable geometry is invalid."));
        };
        if !arguments.width.is_finite()
            || !arguments.height.is_finite()
            || arguments.transform.len() != 16
            || arguments.transform.iter().any(|value| !value.is_finite())
        {
            return Err(("Bad Arguments", "Editable geometry is invalid."));
        }
        let Some(client) = self.client.as_mut() else {
            return Ok(());
        };
        client
            .editable_transform
            .copy_from_slice(&arguments.transform);
        self.note_state_change();
        Ok(())
    }

    fn set_text_rectangle(
        &mut self,
        arguments: Option<&RawValue>,
        caret: bool,
    ) -> Result<(), (&'static str, &'static str)> {
        let Some(arguments) = arguments
            .and_then(|arguments| serde_json::from_str::<RectangleFields>(arguments.get()).ok())
        else {
            return Err(("Bad Arguments", "Text input rectangle is invalid."));
        };
        let rectangle = TextInputRectangle {
            x: arguments.x,
            y: arguments.y,
            width: arguments.width,
            height: arguments.height,
        };
        if !rectangle.is_valid() {
            return Err(("Bad Arguments", "Text input rectangle is invalid."));
        }
        let Some(client) = self.client.as_mut() else {
            return Ok(());
        };
        if caret {
            client.caret_rect = Some(rectangle);
        } else {
            client.marked_text_rect = Some(rectangle);
        }
        self.note_state_change();
        Ok(())
    }
}

impl TextInputClient {
    fn clear(&mut self) {
        self.id = 0;
        self.input_type.clear();
        self.input_action.clear();
        self.obscure_text = false;
        self.enable_personalized_learning = true;
        self.reset_geometry();
        self.model.clear();
    }

    fn reset_geometry(&mut self) {
        self.editable_transform.fill(0.0);
        self.editable_transform[0] = 1.0;
        self.editable_transform[5] = 1.0;
        self.editable_transform[10] = 1.0;
        self.editable_transform[15] = 1.0;
        self.caret_rect = None;
        self.marked_text_rect = None;
    }

    fn content_hint(&self) -> u32 {
        const COMPLETION: u32 = 1;
        const SPELLCHECK: u32 = 2;
        const SENSITIVE_DATA: u32 = 128;
        const MULTILINE_HINT: u32 = 512;
        let mut hint = 0;
        if !self.obscure_text {
            hint |= COMPLETION | SPELLCHECK;
        }
        if !self.enable_personalized_learning {
            hint |= SENSITIVE_DATA;
        }
        if self.input_type == MULTILINE {
            hint |= MULTILINE_HINT;
        }
        hint
    }

    fn content_purpose(&self) -> u32 {
        match self.input_type.as_str() {
            "TextInputType.number" => 3,
            "TextInputType.phone" => 4,
            "TextInputType.url" => 5,
            "TextInputType.emailAddress" => 6,
            "TextInputType.name" => 7,
            "TextInputType.visiblePassword" => 8,
            "TextInputType.datetime" => 12,
            _ => 0,
        }
    }

    fn transformed_cursor_rectangle(&self) -> Option<TextInputRectangle> {
        let rectangle = self.caret_rect.or(self.marked_text_rect)?;
        rectangle.transform(&self.editable_transform)
    }
}

impl TextInputRectangle {
    fn is_valid(self) -> bool {
        self.x.is_finite()
            && self.y.is_finite()
            && self.width.is_finite()
            && self.height.is_finite()
            && self.width >= 0.0
            && self.height >= 0.0
    }

    fn transform(self, transform: &[f64; 16]) -> Option<Self> {
        let corners = [
            (self.x, self.y),
            (self.x + self.width, self.y),
            (self.x, self.y + self.height),
            (self.x + self.width, self.y + self.height),
        ];
        let mut min_x = f64::INFINITY;
        let mut min_y = f64::INFINITY;
        let mut max_x = f64::NEG_INFINITY;
        let mut max_y = f64::NEG_INFINITY;
        for (x, y) in corners {
            let w = transform[3] * x + transform[7] * y + transform[15];
            if !w.is_finite() || w.abs() <= f64::EPSILON {
                return None;
            }
            let transformed_x = (transform[0] * x + transform[4] * y + transform[12]) / w;
            let transformed_y = (transform[1] * x + transform[5] * y + transform[13]) / w;
            if !transformed_x.is_finite() || !transformed_y.is_finite() {
                return None;
            }
            min_x = min_x.min(transformed_x);
            min_y = min_y.min(transformed_y);
            max_x = max_x.max(transformed_x);
            max_y = max_y.max(transformed_y);
        }
        Some(Self {
            x: min_x,
            y: min_y,
            width: (max_x - min_x).max(0.0),
            height: (max_y - min_y).max(0.0),
        })
    }
}

fn update_editing_state(
    client: &TextInputClient,
    text_utf8_scratch: &mut String,
    output: &mut Vec<u8>,
) {
    client.model.write_text(text_utf8_scratch);
    output.clear();
    let (composing_base, composing_extent) =
        client
            .model
            .composing
            .map_or((-1_i64, -1_i64), |(base, extent)| {
                (
                    i64::try_from(base).unwrap_or(-1),
                    i64::try_from(extent).unwrap_or(-1),
                )
            });
    write!(
        output,
        r#"{{"method":"{UPDATE_EDITING_STATE}","args":[{},{{"composingBase":{composing_base},"composingExtent":{composing_extent},"selectionAffinity":"TextAffinity.downstream","selectionBase":{},"selectionExtent":{},"selectionIsDirectional":false,"text":"#,
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
    composing: Option<(usize, usize)>,
}

impl TextInputModel {
    fn clear(&mut self) {
        self.text.clear();
        self.replacement_scratch.clear();
        self.selection_base = 0;
        self.selection_extent = 0;
        self.composing = None;
    }

    #[cfg(test)]
    fn replace_text(&mut self, text: &str, base: usize, extent: usize) -> bool {
        self.replace_editing_state(text, base, extent, None)
    }

    fn replace_editing_state(
        &mut self,
        text: &str,
        base: usize,
        extent: usize,
        composing: Option<(usize, usize)>,
    ) -> bool {
        self.replacement_scratch.clear();
        self.replacement_scratch.extend(text.encode_utf16());
        if self.replacement_scratch.len() > MAX_TEXT_UTF16_UNITS
            || !valid_selection_boundary(&self.replacement_scratch, base)
            || !valid_selection_boundary(&self.replacement_scratch, extent)
            || composing.is_some_and(|(base, extent)| {
                !valid_selection_boundary(&self.replacement_scratch, base)
                    || !valid_selection_boundary(&self.replacement_scratch, extent)
            })
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
        self.composing = composing;
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

    fn surrounding_text(&self, max_bytes: usize) -> Option<(String, u32, u32)> {
        let text = String::from_utf16(&self.text).ok()?;
        let cursor = utf16_offset_to_utf8(&self.text, self.selection_extent)?;
        let anchor = utf16_offset_to_utf8(&self.text, self.selection_base)?;
        let low = cursor.min(anchor);
        let high = cursor.max(anchor);
        if high.saturating_sub(low) > max_bytes {
            return None;
        }
        if text.len() <= max_bytes {
            return Some((
                text,
                u32::try_from(cursor).ok()?,
                u32::try_from(anchor).ok()?,
            ));
        }

        let selection_bytes = high - low;
        let spare = max_bytes - selection_bytes;
        let mut start = low.saturating_sub(spare / 2);
        while start > 0 && !text.is_char_boundary(start) {
            start -= 1;
        }
        let mut end = (start + max_bytes).min(text.len());
        while end > high && !text.is_char_boundary(end) {
            end -= 1;
        }
        if end < high {
            end = high;
            start = end.saturating_sub(max_bytes);
            while start < low && !text.is_char_boundary(start) {
                start += 1;
            }
        }
        Some((
            text[start..end].to_owned(),
            u32::try_from(cursor - start).ok()?,
            u32::try_from(anchor - start).ok()?,
        ))
    }

    fn apply_input_method(&mut self, transaction: &InputMethodTransaction) -> bool {
        let has_request = transaction.commit_string.is_some()
            || transaction.preedit_string.is_some()
            || transaction.delete_surrounding.is_some();
        if !has_request && self.composing.is_none() {
            return false;
        }

        let Ok(mut text) = String::from_utf16(&self.text) else {
            return false;
        };
        let mut cursor = if let Some((base, extent)) = self.composing {
            let start = base.min(extent);
            let end = base.max(extent);
            let (Some(start), Some(end)) = (
                utf16_offset_to_utf8(&self.text, start),
                utf16_offset_to_utf8(&self.text, end),
            ) else {
                return false;
            };
            text.replace_range(start..end, "");
            start
        } else {
            let start = self.selection_base.min(self.selection_extent);
            let end = self.selection_base.max(self.selection_extent);
            let (Some(start), Some(end)) = (
                utf16_offset_to_utf8(&self.text, start),
                utf16_offset_to_utf8(&self.text, end),
            ) else {
                return false;
            };
            if has_request && start != end {
                text.replace_range(start..end, "");
            }
            start
        };

        if let Some((before, after)) = transaction.delete_surrounding {
            let (Ok(before), Ok(after)) = (usize::try_from(before), usize::try_from(after)) else {
                return false;
            };
            let Some(start) = cursor.checked_sub(before) else {
                return false;
            };
            let Some(end) = cursor.checked_add(after) else {
                return false;
            };
            if end > text.len() || !text.is_char_boundary(start) || !text.is_char_boundary(end) {
                return false;
            }
            text.replace_range(start..end, "");
            cursor = start;
        }

        if let Some(commit) = transaction.commit_string.as_deref() {
            if commit.contains('\0') {
                return false;
            }
            text.insert_str(cursor, commit);
            cursor += commit.len();
        }

        let mut selection_base_bytes = cursor;
        let mut selection_extent_bytes = cursor;
        let mut composing_bytes = None;
        if let Some((preedit, cursor_begin, cursor_end)) = transaction.preedit_string.as_ref() {
            if preedit.contains('\0') {
                return false;
            }
            let start = cursor;
            text.insert_str(start, preedit);
            let end = start + preedit.len();
            if !preedit.is_empty() {
                composing_bytes = Some((start, end));
            }
            if *cursor_begin >= 0 || *cursor_end >= 0 {
                let (Ok(begin), Ok(end_cursor)) =
                    (usize::try_from(*cursor_begin), usize::try_from(*cursor_end))
                else {
                    return false;
                };
                if begin > preedit.len()
                    || end_cursor > preedit.len()
                    || !preedit.is_char_boundary(begin)
                    || !preedit.is_char_boundary(end_cursor)
                {
                    return false;
                }
                selection_base_bytes = start + begin;
                selection_extent_bytes = start + end_cursor;
            } else if *cursor_begin == -1 && *cursor_end == -1 {
                selection_base_bytes = end;
                selection_extent_bytes = end;
            } else {
                return false;
            }
        }

        let text_utf16 = text.encode_utf16().collect::<Vec<_>>();
        if text_utf16.len() > MAX_TEXT_UTF16_UNITS {
            return false;
        }
        let Some(selection_base) = utf8_offset_to_utf16(&text, selection_base_bytes) else {
            return false;
        };
        let Some(selection_extent) = utf8_offset_to_utf16(&text, selection_extent_bytes) else {
            return false;
        };
        let composing = composing_bytes.and_then(|(base, extent)| {
            Some((
                utf8_offset_to_utf16(&text, base)?,
                utf8_offset_to_utf16(&text, extent)?,
            ))
        });
        self.text = text_utf16;
        self.selection_base = selection_base;
        self.selection_extent = selection_extent;
        self.composing = composing;
        true
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
        self.composing = None;
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
        self.composing = None;
        true
    }

    #[cfg(test)]
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
        self.composing = None;
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
        self.composing = None;
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
        self.composing = None;
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

fn utf16_offset_to_utf8(text: &[u16], offset: usize) -> Option<usize> {
    if !valid_selection_boundary(text, offset) {
        return None;
    }
    let prefix = String::from_utf16(&text[..offset]).ok()?;
    Some(prefix.len())
}

fn utf8_offset_to_utf16(text: &str, offset: usize) -> Option<usize> {
    if offset > text.len() || !text.is_char_boundary(offset) {
        return None;
    }
    Some(text[..offset].encode_utf16().count())
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
        assert!(plugin.client.is_none());
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

        assert!(plugin.client.is_some());
        let messages = plugin.insert_text("after 😀");
        assert_eq!(messages.len(), 1);
        let update: Value = serde_json::from_slice(&messages[0]).unwrap();
        assert_eq!(update["method"], UPDATE_EDITING_STATE);
        assert_eq!(update["args"][1]["text"], "after 😀");
        assert_eq!(update["args"][1]["selectionBase"], 8);
        assert_eq!(update["args"][1]["selectionExtent"], 8);
    }

    #[test]
    fn input_method_preedit_is_replaced_atomically_by_its_commit() {
        let mut model = TextInputModel::default();
        assert!(model.replace_text("", 0, 0));
        assert!(model.apply_input_method(&InputMethodTransaction {
            preedit_string: Some(("ni".to_owned(), 2, 2)),
            ..InputMethodTransaction::default()
        }));
        assert_eq!(model.text(), "ni");
        assert_eq!(model.composing, Some((0, 2)));

        assert!(model.apply_input_method(&InputMethodTransaction {
            commit_string: Some("你".to_owned()),
            preedit_string: Some((String::new(), -1, -1)),
            ..InputMethodTransaction::default()
        }));
        assert_eq!(model.text(), "你");
        assert_eq!(model.selection_base, 1);
        assert_eq!(model.selection_extent, 1);
        assert_eq!(model.composing, None);
    }

    #[test]
    fn input_method_deletion_uses_utf8_bytes_without_splitting_unicode() {
        let mut model = TextInputModel::default();
        assert!(model.replace_text("你好吗", 2, 2));
        assert!(model.apply_input_method(&InputMethodTransaction {
            delete_surrounding: Some((3, 0)),
            ..InputMethodTransaction::default()
        }));
        assert_eq!(model.text(), "你吗");
        assert_eq!(model.selection_extent, 1);

        let before = model.text();
        assert!(!model.apply_input_method(&InputMethodTransaction {
            delete_surrounding: Some((1, 0)),
            ..InputMethodTransaction::default()
        }));
        assert_eq!(model.text(), before);
    }

    #[test]
    fn flutter_editor_snapshot_tracks_security_and_transformed_caret() {
        let mut plugin = TextInputPlugin::default();
        assert_eq!(
            plugin.handle_platform_message(&call(
                SET_CLIENT,
                json!([41, {
                    "obscureText": true,
                    "inputAction": "TextInputAction.done",
                    "inputType": {"name": "TextInputType.text"}
                }]),
            )),
            b"[null]"
        );
        assert_eq!(
            plugin.handle_platform_message(&call(
                SET_EDITABLE_SIZE_AND_TRANSFORM,
                json!({
                    "width": 300.0,
                    "height": 40.0,
                    "transform": [
                        1.0, 0.0, 0.0, 0.0,
                        0.0, 1.0, 0.0, 0.0,
                        0.0, 0.0, 1.0, 0.0,
                        100.0, 50.0, 0.0, 1.0
                    ]
                }),
            )),
            b"[null]"
        );
        assert_eq!(
            plugin.handle_platform_message(&call(
                SET_CARET_RECT,
                json!({"x": 10.0, "y": 5.0, "width": 2.0, "height": 20.0}),
            )),
            b"[null]"
        );
        let snapshot = plugin.take_state_change().expect("dirty editor snapshot");
        assert_eq!(snapshot.client_id, 41);
        assert!(snapshot.secure);
        assert_eq!(
            snapshot.cursor_rectangle,
            Some(TextInputRectangle {
                x: 110.0,
                y: 55.0,
                width: 2.0,
                height: 20.0,
            })
        );
    }

    #[test]
    fn input_method_transaction_cannot_cross_flutter_client_identity() {
        let mut plugin = TextInputPlugin::default();
        assert_eq!(
            plugin.handle_platform_message(&call(
                SET_CLIENT,
                json!([7, {
                    "inputAction": "TextInputAction.done",
                    "inputType": {"name": "TextInputType.text"}
                }]),
            )),
            b"[null]"
        );
        let messages = plugin.apply_input_method(
            8,
            &InputMethodTransaction {
                commit_string: Some("lost".to_owned()),
                ..InputMethodTransaction::default()
            },
        );
        assert!(messages.is_empty());
        assert_eq!(plugin.client.as_ref().unwrap().model.text(), "");
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
    fn editor_state_is_edge_triggered_and_identifies_replacements() {
        let mut plugin = TextInputPlugin::default();
        let snapshot = plugin.take_state_change().unwrap();
        assert_eq!((snapshot.lifecycle_revision, snapshot.active), (0, false));
        assert!(plugin.take_state_change().is_none());

        let configure = |id| {
            call(
                SET_CLIENT,
                json!([id, {
                    "inputAction": "TextInputAction.done",
                    "inputType": {"name": "TextInputType.text"}
                }]),
            )
        };
        assert_eq!(plugin.handle_platform_message(&configure(1)), b"[null]");
        let snapshot = plugin.take_state_change().unwrap();
        assert_eq!((snapshot.lifecycle_revision, snapshot.active), (1, true));
        assert_eq!(plugin.handle_platform_message(&configure(2)), b"[null]");
        let snapshot = plugin.take_state_change().unwrap();
        assert_eq!((snapshot.lifecycle_revision, snapshot.active), (2, true));
        assert_eq!(
            plugin.handle_platform_message(&call(CLEAR_CLIENT, Value::Null)),
            b"[null]"
        );
        let snapshot = plugin.take_state_change().unwrap();
        assert_eq!((snapshot.lifecycle_revision, snapshot.active), (3, false));
        assert!(plugin.take_state_change().is_none());
    }

    #[test]
    fn flutter_show_and_hide_publish_input_panel_visibility() {
        let mut plugin = TextInputPlugin::default();
        plugin.take_state_change();
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
        assert!(!plugin.take_state_change().unwrap().input_panel_visible);

        assert_eq!(
            plugin.handle_platform_message(&call(SHOW, Value::Null)),
            b"[null]"
        );
        assert!(plugin.take_state_change().unwrap().input_panel_visible);

        assert_eq!(
            plugin.handle_platform_message(&call(HIDE, Value::Null)),
            b"[null]"
        );
        assert!(!plugin.take_state_change().unwrap().input_panel_visible);
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
