use super::*;

#[cfg(feature = "flutter")]
fn flutter_snapshot(revision: u64, active: bool) -> TextInputSnapshot {
    TextInputSnapshot {
        revision,
        lifecycle_revision: revision,
        client_id: 17,
        active,
        input_panel_visible: active,
        secure: false,
        surrounding_text: Some("ni".to_owned()),
        cursor: 2,
        anchor: 2,
        content_hint: 0,
        content_purpose: 0,
        cursor_rectangle: None,
    }
}

fn focused_sessions() -> SessionState<u64, u64, u64> {
    let mut sessions = SessionState::default();
    sessions.set_focus(Some(Focus {
        surface: 10,
        client: 1,
    }));
    sessions.register(100, 1, 2);
    sessions.register(200, 2, 2);
    sessions
}

#[test]
fn focus_enters_every_object_for_the_client_and_leave_clears_activation() {
    let mut sessions = focused_sessions();
    assert!(sessions.is_entered(&100));
    assert!(!sessions.is_entered(&200));
    sessions.request_enablement(&100, true);
    assert_eq!(sessions.commit(&100), CommitEffect::Activated);

    let transition = sessions.set_focus(Some(Focus {
        surface: 20,
        client: 2,
    }));
    assert_eq!(transition.left, vec![100]);
    assert_eq!(transition.entered, vec![200]);
    assert!(sessions.active_serial().is_none());
}

#[test]
fn commits_are_double_buffered_and_serials_include_ignored_commits() {
    let mut sessions = focused_sessions();
    sessions.set_content_type(&100, 7, 8);
    assert_eq!(sessions.commit(&100), CommitEffect::Ignored);
    assert_eq!(sessions.instance(&100).unwrap().serial, 1);
    assert!(
        sessions
            .instance(&100)
            .unwrap()
            .current
            .content_type
            .is_none()
    );

    sessions.request_enablement(&100, true);
    sessions.set_content_type(&100, 3, 4);
    assert_eq!(sessions.commit(&100), CommitEffect::Activated);
    assert_eq!(sessions.instance(&100).unwrap().serial, 2);
    assert_eq!(
        sessions.instance(&100).unwrap().current.content_type,
        Some((3, 4))
    );
}

#[test]
fn client_touch_requires_fresh_editor_state_to_reopen_the_panel() {
    let mut sessions = focused_sessions();
    sessions.request_enablement(&100, true);
    sessions.set_surrounding(
        &100,
        SurroundingText {
            text: "first".into(),
            cursor: 5,
            anchor: 5,
        },
    );
    assert_eq!(sessions.commit(&100), CommitEffect::Activated);
    assert!(sessions.instance(&100).unwrap().touch_dismissed);

    assert!(sessions.begin_touch_authorization());
    assert!(sessions.instance(&100).unwrap().touch_dismissed);

    // An inert client area may still issue a no-op commit. That must not
    // reinterpret the touch as selecting an editor.
    assert_eq!(sessions.commit(&100), CommitEffect::Updated);
    assert!(sessions.instance(&100).unwrap().touch_dismissed);

    assert!(sessions.begin_touch_authorization());
    sessions.set_surrounding(
        &100,
        SurroundingText {
            text: "second".into(),
            cursor: 6,
            anchor: 6,
        },
    );
    assert_eq!(sessions.commit(&100), CommitEffect::Updated);
    assert!(!sessions.instance(&100).unwrap().touch_dismissed);
}

#[test]
fn a_second_object_cannot_replace_the_active_editor() {
    let mut sessions = focused_sessions();
    sessions.register(101, 1, 2);
    sessions.request_enablement(&100, true);
    assert_eq!(sessions.commit(&100), CommitEffect::Activated);
    sessions.request_enablement(&101, true);
    assert_eq!(sessions.commit(&101), CommitEffect::Ignored);
    assert_eq!(sessions.active_serial(), Some((100, 1)));
}

#[test]
fn version_two_cursor_rectangles_apply_with_the_surface_commit() {
    let mut sessions = focused_sessions();
    let rectangle = CursorRectangle {
        x: 2,
        y: 3,
        width: 4,
        height: 5,
    };
    sessions.request_enablement(&100, true);
    sessions.set_cursor_rectangle(&100, rectangle);
    sessions.commit(&100);
    assert_eq!(
        sessions.instance(&100).unwrap().current.cursor_rectangle,
        None
    );
    sessions.surface_committed(&10);
    assert_eq!(
        sessions.instance(&100).unwrap().current.cursor_rectangle,
        Some(rectangle)
    );
}

#[test]
fn destroying_the_active_object_removes_the_editor() {
    let mut sessions = focused_sessions();
    sessions.request_enablement(&100, true);
    sessions.commit(&100);
    assert!(sessions.remove(&100));
    assert!(sessions.active_serial().is_none());
    assert!(sessions.instance(&100).is_none());
}

#[test]
fn surrounding_offsets_are_utf8_byte_boundaries() {
    let valid = valid_surrounding_text("a中b".to_owned(), 4, 1).unwrap();
    assert_eq!(valid.cursor, 4);
    assert!(valid_surrounding_text("a中b".to_owned(), 2, 1).is_none());
    assert!(valid_surrounding_text("hello".to_owned(), -1, 0).is_none());
    assert!(valid_surrounding_text("x".repeat(4001), 0, 0).is_none());
}

#[test]
fn broker_opens_the_seat_fallback_only_without_a_protocol_editor() {
    let mut broker = TextSessionBroker::default();
    broker.set_seat_focus(SeatFocusKind::Wayland);
    broker.note_client_touch(false);
    assert!(broker.legacy_touch_keyboard);
    let first_activation = broker.activation_serial;

    broker.note_client_touch(false);
    assert!(broker.activation_serial > first_activation);

    broker.note_client_touch(true);
    assert!(!broker.legacy_touch_keyboard);

    broker.set_seat_focus(SeatFocusKind::Xwayland);
    broker.note_client_touch(false);
    assert!(broker.legacy_touch_keyboard);

    broker.note_flutter_touch();
    assert!(!broker.legacy_touch_keyboard);
}

#[test]
fn flutter_keyboard_visibility_requires_a_current_touch() {
    let mut broker = TextSessionBroker::default();
    assert!(broker.observe_flutter_editor(4, flutter_snapshot(1, true)));
    assert!(!broker.flutter_panel_authorized);

    broker.note_flutter_touch();
    assert!(broker.observe_flutter_editor(4, flutter_snapshot(2, true)));
    assert!(broker.flutter_panel_authorized);
    let first_activation = broker.activation_serial;

    broker.note_flutter_touch();
    assert!(broker.observe_flutter_editor(4, flutter_snapshot(3, true)));
    assert!(broker.activation_serial > first_activation);

    assert!(broker.observe_flutter_editor(4, flutter_snapshot(4, false)));
    assert!(!broker.flutter_panel_authorized);
}

#[test]
fn stale_flutter_lifecycle_updates_cannot_revive_an_editor() {
    let mut broker = TextSessionBroker::default();
    assert!(broker.observe_flutter_editor(8, flutter_snapshot(3, false)));
    assert!(!broker.observe_flutter_editor(8, flutter_snapshot(2, true)));
    assert!(!broker.observe_flutter_editor(7, flutter_snapshot(99, true)));
    assert!(!broker.flutter_editor_active());
    broker.retire_flutter_generation();
    assert!(broker.observe_flutter_editor(9, flutter_snapshot(0, true)));
    assert!(broker.flutter_editor_active());
}

#[test]
fn available_actions_reject_none_duplicates_and_malformed_arrays() {
    let bytes = [1_u32.to_ne_bytes(), 2_u32.to_ne_bytes()].concat();
    assert_eq!(parse_available_actions(&bytes), Some(vec![1, 2]));
    assert!(parse_available_actions(&0_u32.to_ne_bytes()).is_none());
    assert!(parse_available_actions(&[1, 2, 3]).is_none());
    let duplicate = [1_u32.to_ne_bytes(), 1_u32.to_ne_bytes()].concat();
    assert!(parse_available_actions(&duplicate).is_none());
}

#[test]
fn advertises_the_complete_version_two_text_input_interface() {
    let display = smithay::reexports::wayland_server::Display::<RuntimeState>::new()
        .expect("Wayland display should initialize");
    let display_handle = display.handle();
    let manager = TextInputManager::new(&display_handle);
    let global = display_handle
        .backend_handle()
        .global_info(manager._global.clone())
        .expect("text-input manager global should remain registered");

    assert_eq!(global.interface.name, "zwp_text_input_manager_v3");
    assert_eq!(global.version, 2);
    assert!(!global.disabled);
}

#[test]
fn requests_queued_before_enter_cannot_activate_after_focus_returns() {
    let mut sessions = SessionState::<u64, u64, u64>::default();
    sessions.register(100, 1, 2);
    sessions.request_enablement(&100, true);
    assert_eq!(sessions.commit(&100), CommitEffect::Ignored);

    sessions.set_focus(Some(Focus {
        surface: 10,
        client: 1,
    }));
    assert_eq!(sessions.commit(&100), CommitEffect::Ignored);
    assert!(sessions.active_serial().is_none());
}
