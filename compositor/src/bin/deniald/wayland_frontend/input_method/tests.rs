use super::*;

fn flutter_editor(client_id: i64, purpose: u32) -> EditorSnapshot {
    EditorSnapshot {
        endpoint: EditorEndpoint::Flutter {
            generation: 4,
            lifecycle: 7,
            client_id,
        },
        surrounding_text: Some(("ni".to_owned(), 2, 2)),
        change_cause: 0,
        content_hint: 3,
        content_purpose: purpose,
        cursor_rectangle: Some(Rectangle::new((10, 20).into(), (1, 18).into())),
    }
}

#[test]
fn endpoint_identity_separates_flutter_replacements_from_state_updates() {
    let first = flutter_editor(1, 0).endpoint;
    let same = flutter_editor(1, 0).endpoint;
    let replacement = flutter_editor(2, 0).endpoint;
    assert!(first.same_editor(&same));
    assert!(!first.same_editor(&replacement));
}

#[test]
fn password_and_pin_purposes_never_activate_an_external_engine() {
    assert!(flutter_editor(1, 0).permits_external_input_method());
    assert!(!flutter_editor(1, PASSWORD_PURPOSE).permits_external_input_method());
    assert!(!flutter_editor(1, PIN_PURPOSE).permits_external_input_method());
}

#[test]
fn preedit_cursor_validation_uses_utf8_byte_boundaries() {
    let text = "你a";
    let valid = |cursor: i32| {
        cursor >= 0
            && usize::try_from(cursor)
                .is_ok_and(|cursor| cursor <= text.len() && text.is_char_boundary(cursor))
    };
    assert!(valid(0));
    assert!(valid(3));
    assert!(valid(4));
    assert!(!valid(1));
    assert!(!valid(2));
}

#[test]
fn virtual_keyboard_accepts_only_wayland_key_states() {
    assert_eq!(virtual_key_state(0), Some(KeyState::Released));
    assert_eq!(virtual_key_state(1), Some(KeyState::Pressed));
    assert_eq!(virtual_key_state(2), None);
    assert_eq!(virtual_key_state(u32::MAX), None);
}
