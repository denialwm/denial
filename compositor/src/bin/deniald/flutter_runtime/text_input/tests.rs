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
