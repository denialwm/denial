use super::*;

#[cfg(test)]
mod axis_scroll_tests {
    use super::*;

    #[test]
    fn scroll_speed_factor_applies_only_to_finger_source() {
        assert_eq!(
            scaled_axis_amount(AxisSource::Finger, Some(3.0), None, 2.5),
            7.5
        );
        assert_eq!(
            scaled_axis_amount(AxisSource::Wheel, Some(15.0), Some(120.0), 5.0),
            15.0
        );
        assert_eq!(
            scaled_axis_amount(AxisSource::Continuous, Some(3.0), None, 5.0),
            3.0
        );
        assert_eq!(
            scaled_axis_amount(AxisSource::Finger, Some(0.0), None, 5.0),
            0.0
        );
    }
}

#[cfg(test)]
mod software_keyboard_touch_tests {
    use super::*;

    #[cfg(feature = "flutter")]
    #[test]
    fn only_published_software_keyboard_regions_preserve_an_editor() {
        let mut layout = InputLayoutSnapshot::default();
        layout.software_keyboard_regions.push(InputRect {
            x: 0.0,
            y: 700.0,
            width: 400.0,
            height: 300.0,
        });

        assert!(software_keyboard_owns_touch(
            Some(&layout),
            Point::from((200.0, 800.0)),
        ));
        assert!(!software_keyboard_owns_touch(
            Some(&layout),
            Point::from((200.0, 100.0)),
        ));
        assert!(!software_keyboard_owns_touch(
            None,
            Point::from((200.0, 800.0)),
        ));
    }
}

#[cfg(test)]
mod native_escape_tests {
    use super::*;

    #[cfg(feature = "flutter")]
    const XKB_ESCAPE: u32 = 1 + 8;
    const XKB_LEFT_CTRL: u32 = 29 + 8;
    const XKB_LEFT_ALT: u32 = 56 + 8;
    const XKB_BACKSPACE: u32 = 14 + 8;
    #[cfg(feature = "flutter")]
    const XKB_TAB: u32 = 15 + 8;
    #[cfg(feature = "flutter")]
    const XKB_A: u32 = 30 + 8;
    #[cfg(feature = "flutter")]
    const XKB_S: u32 = 31 + 8;
    #[cfg(feature = "flutter")]
    const XKB_LEFT_SHIFT: u32 = 42 + 8;
    #[cfg(feature = "flutter")]
    const XKB_LEFT_META: u32 = 125 + 8;

    fn input(runtime: &mut RuntimeState, keycode: u32, state: KeyState) -> bool {
        intercept_native_escape(runtime, keycode, state)
    }

    #[test]
    fn native_escape_requests_graceful_lifecycle_shutdown_and_is_consumed() {
        let mut runtime = RuntimeState {
            native_escape_shortcut: NativeEscapeShortcut::default(),
            lifecycle: LifecycleState::default(),
            ..RuntimeState::default()
        };

        assert!(!input(&mut runtime, XKB_LEFT_CTRL, KeyState::Pressed));
        assert!(!input(&mut runtime, XKB_LEFT_ALT, KeyState::Pressed));
        assert!(input(&mut runtime, XKB_BACKSPACE, KeyState::Pressed));
        assert_eq!(
            runtime.lifecycle.shutdown_reason(),
            Some(ShutdownReason::NativeEscapeShortcut)
        );
    }

    #[test]
    fn ordinary_backspace_remains_available_to_clients() {
        let mut runtime = RuntimeState {
            native_escape_shortcut: NativeEscapeShortcut::default(),
            lifecycle: LifecycleState::default(),
            ..RuntimeState::default()
        };

        assert!(!input(&mut runtime, XKB_BACKSPACE, KeyState::Pressed));
        assert_eq!(runtime.lifecycle.shutdown_reason(), None);
    }

    #[cfg(feature = "flutter")]
    #[test]
    fn super_escape_is_consumed_even_without_an_active_client() {
        let mut runtime = RuntimeState::default();

        assert!(input(&mut runtime, XKB_LEFT_META, KeyState::Pressed));
        assert!(input(&mut runtime, XKB_ESCAPE, KeyState::Pressed));
        assert!(input(&mut runtime, XKB_ESCAPE, KeyState::Pressed));
        assert!(input(&mut runtime, XKB_LEFT_META, KeyState::Released));
        assert!(input(&mut runtime, XKB_ESCAPE, KeyState::Released));
    }

    #[cfg(feature = "flutter")]
    #[test]
    fn native_shell_chords_queue_the_cpp_equivalent_actions() {
        let mut runtime = RuntimeState::default();

        assert!(input(&mut runtime, XKB_LEFT_META, KeyState::Pressed));
        assert!(input(&mut runtime, XKB_A, KeyState::Pressed));
        assert!(input(&mut runtime, XKB_A, KeyState::Released));
        assert!(input(&mut runtime, XKB_LEFT_META, KeyState::Released));
        assert_eq!(
            runtime.pending_shell_actions.pop_front(),
            Some((
                super::super::super::super::wire::ShellAction::Overview,
                None
            ))
        );

        assert!(!input(&mut runtime, XKB_LEFT_SHIFT, KeyState::Pressed));
        assert!(input(&mut runtime, XKB_LEFT_META, KeyState::Pressed));
        assert!(input(&mut runtime, XKB_S, KeyState::Pressed));
        assert!(input(&mut runtime, XKB_S, KeyState::Released));
        assert!(input(&mut runtime, XKB_LEFT_META, KeyState::Released));
        assert!(!input(&mut runtime, XKB_LEFT_SHIFT, KeyState::Released));
        assert!(runtime.pending_shell_actions.is_empty());
        assert_eq!(runtime.pending_screenshot_selection, None);
        runtime.request_screenshot_selection(Some(12));
        assert_eq!(
            runtime.pending_screenshot_selection,
            Some(denial_core::topology::OutputId(12))
        );
        runtime.pending_screenshot_selection = None;

        assert!(input(&mut runtime, XKB_LEFT_META, KeyState::Pressed));
        assert!(input(&mut runtime, XKB_TAB, KeyState::Pressed));
        assert!(input(&mut runtime, XKB_TAB, KeyState::Released));
        assert!(input(&mut runtime, XKB_TAB, KeyState::Pressed));
        assert!(input(&mut runtime, XKB_LEFT_META, KeyState::Released));
        assert!(input(&mut runtime, XKB_TAB, KeyState::Pressed));
        assert!(input(&mut runtime, XKB_TAB, KeyState::Released));
        assert_eq!(
            runtime.pending_shell_actions.pop_front(),
            Some((
                super::super::super::super::wire::ShellAction::WindowSwitcherNext,
                None,
            ))
        );
        assert_eq!(
            runtime.pending_shell_actions.pop_front(),
            Some((
                super::super::super::super::wire::ShellAction::WindowSwitcherNext,
                None,
            ))
        );
        assert_eq!(
            runtime.pending_shell_actions.pop_front(),
            Some((
                super::super::super::super::wire::ShellAction::WindowSwitcherEnd,
                None,
            ))
        );
        assert!(runtime.pending_shell_actions.is_empty());
    }
}

#[cfg(all(test, feature = "flutter"))]
mod pointer_constraint_escape_tests {
    use super::*;

    #[test]
    fn only_a_click_on_the_released_window_allows_recapture() {
        let mut escape = PointerConstraintEscape::default();
        escape.release_window(41);

        assert!(escape.suppresses_window(41));
        assert!(!escape.resume_window(99));
        assert!(escape.suppresses_window(41));
        assert!(escape.resume_window(41));
        assert!(!escape.suppresses_window(41));
    }

    #[test]
    fn cancelled_pointer_button_release_is_consumed_once() {
        let mut retired = HashSet::from([BTN_LEFT]);

        assert!(retired_pointer_button_consumes_transition(
            &mut retired,
            BTN_LEFT,
            ButtonState::Pressed,
        ));
        assert!(retired_pointer_button_consumes_transition(
            &mut retired,
            BTN_LEFT,
            ButtonState::Released,
        ));
        assert!(!retired_pointer_button_consumes_transition(
            &mut retired,
            BTN_LEFT,
            ButtonState::Released,
        ));
    }
}

#[cfg(all(test, feature = "flutter"))]
mod compositor_pointer_binding_tests {
    use super::*;

    #[test]
    fn shell_keyboard_maps_its_visual_us_layout_to_evdev_strokes() {
        assert_eq!(
            shell_text_key_stroke('a'),
            Some(ShellKeyStroke {
                evdev_keycode: 30,
                shift: false,
            })
        );
        assert_eq!(
            shell_text_key_stroke('A'),
            Some(ShellKeyStroke {
                evdev_keycode: 30,
                shift: true,
            })
        );
        assert_eq!(
            shell_text_key_stroke('?'),
            Some(ShellKeyStroke {
                evdev_keycode: 53,
                shift: true,
            })
        );
        assert_eq!(
            shell_named_key_stroke("BackSpace"),
            Some(ShellKeyStroke {
                evdev_keycode: 14,
                shift: false,
            })
        );
        assert_eq!(shell_text_key_stroke('😀'), None);
        assert_eq!(shell_named_key_stroke("unsupported"), None);
    }

    #[test]
    fn held_shell_keys_are_balanced_and_never_claim_physical_keys() {
        let mut held = HashSet::new();
        let backspace = 22;

        assert!(route_shell_key_transition(
            &mut held,
            backspace,
            KeyState::Pressed,
            false,
        ));
        assert!(!route_shell_key_transition(
            &mut held,
            backspace,
            KeyState::Pressed,
            true,
        ));
        assert!(route_shell_key_transition(
            &mut held,
            backspace,
            KeyState::Released,
            true,
        ));
        assert!(!route_shell_key_transition(
            &mut held,
            backspace,
            KeyState::Released,
            false,
        ));

        assert!(!route_shell_key_transition(
            &mut held,
            backspace,
            KeyState::Pressed,
            true,
        ));
        assert!(held.is_empty());
    }

    #[test]
    fn super_left_moves_and_super_right_resizes() {
        assert_eq!(
            super_pointer_action(true, BTN_LEFT),
            Some(SuperPointerAction::Move)
        );
        assert_eq!(
            super_pointer_action(true, BTN_RIGHT),
            Some(SuperPointerAction::Resize)
        );
        assert_eq!(super_pointer_action(false, BTN_LEFT), None);
        assert_eq!(super_pointer_action(true, 0x112), None);
    }

    #[test]
    fn resize_corner_follows_pointer_quadrant() {
        let geometry = Rectangle::new((100, 200).into(), (800, 600).into());
        assert_eq!(
            resize_edge_for_geometry((101.0, 201.0).into(), geometry),
            xdg_toplevel::ResizeEdge::TopLeft
        );
        assert_eq!(
            resize_edge_for_geometry((899.0, 201.0).into(), geometry),
            xdg_toplevel::ResizeEdge::TopRight
        );
        assert_eq!(
            resize_edge_for_geometry((101.0, 799.0).into(), geometry),
            xdg_toplevel::ResizeEdge::BottomLeft
        );
        assert_eq!(
            resize_edge_for_geometry((899.0, 799.0).into(), geometry),
            xdg_toplevel::ResizeEdge::BottomRight
        );
    }
}

#[cfg(all(test, feature = "flutter"))]
mod flutter_pointer_endpoint_tests {
    use super::*;

    #[test]
    fn route_identity_alone_cannot_mask_a_missing_flutter_lifecycle() {
        assert!(!flutter_pointer_endpoint_is_synchronized(
            RoutedPointerTarget::Flutter,
            RoutedPointerTarget::Flutter,
            false,
            false,
        ));
        assert!(flutter_pointer_endpoint_is_synchronized(
            RoutedPointerTarget::Flutter,
            RoutedPointerTarget::Flutter,
            true,
            false,
        ));
    }

    #[test]
    fn client_routes_remove_flutter_after_capture_releases() {
        let client = RoutedPointerTarget::Client(42);
        assert!(flutter_pointer_endpoint_is_synchronized(
            client, client, true, true,
        ));
        assert!(!flutter_pointer_endpoint_is_synchronized(
            client, client, true, false,
        ));
        assert!(flutter_pointer_endpoint_is_synchronized(
            client, client, false, false,
        ));
    }
}

#[cfg(all(test, feature = "flutter"))]
mod input_device_capability_tests {
    use super::*;

    #[test]
    fn touchpad_presence_changes_only_at_empty_set_boundaries() {
        assert!(touchpad_presence_changed(0, 1));
        assert!(!touchpad_presence_changed(1, 2));
        assert!(!touchpad_presence_changed(2, 1));
        assert!(touchpad_presence_changed(1, 0));
        assert!(!touchpad_presence_changed(0, 0));
    }
}

#[cfg(all(test, feature = "flutter"))]
mod flutter_key_lifecycle_tests {
    use super::*;

    #[test]
    fn repeated_flutter_key_preserves_the_retained_xkb_keycode() {
        const XKB_BACKSPACE: u32 = 22;

        let keycode = retained_flutter_xkb_keycode(XKB_BACKSPACE);

        assert_eq!(keycode.raw(), XKB_BACKSPACE);
        assert_eq!(keycode.raw().saturating_sub(8), 14);
    }

    #[test]
    fn compose_and_dead_keys_emit_only_the_completed_unicode_scalar() {
        let context = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
        let table = xkb::compose::Table::new_from_locale(
            &context,
            std::ffi::OsStr::new("C.UTF-8"),
            xkb::compose::COMPILE_NO_FLAGS,
        )
        .expect("C.UTF-8 Compose table");
        let mut compose = xkb::compose::State::new(&table, xkb::compose::STATE_NO_FLAGS);

        assert_eq!(
            flutter_unicode_for_keysym(
                Some(&mut compose),
                xkb::Keysym::new(xkb::keysyms::KEY_dead_acute),
            ),
            0
        );
        assert_eq!(
            flutter_unicode_for_keysym(Some(&mut compose), xkb::Keysym::new(xkb::keysyms::KEY_e),),
            u32::from('é')
        );
    }

    #[test]
    fn retired_generation_consumes_repeat_and_release_before_reuse() {
        let mut active = HashSet::new();
        let mut retired = HashSet::new();
        let keycode = 38;

        assert_eq!(
            route_flutter_key_transition(
                &mut active,
                &mut retired,
                keycode,
                KeyState::Pressed,
                true,
            ),
            FlutterKeyDisposition::Dispatch
        );
        retire_flutter_generation_keys(&mut active, &mut retired);
        assert!(active.is_empty());
        assert!(retired.contains(&keycode));

        assert_eq!(
            route_flutter_key_transition(
                &mut active,
                &mut retired,
                keycode,
                KeyState::Pressed,
                false,
            ),
            FlutterKeyDisposition::ConsumeRetired
        );
        assert_eq!(
            route_flutter_key_transition(
                &mut active,
                &mut retired,
                keycode,
                KeyState::Released,
                false,
            ),
            FlutterKeyDisposition::ConsumeRetired
        );
        assert!(retired.is_empty());
        assert_eq!(
            route_flutter_key_transition(
                &mut active,
                &mut retired,
                keycode,
                KeyState::Pressed,
                false,
            ),
            FlutterKeyDisposition::Forward
        );
    }

    #[test]
    fn current_generation_keeps_key_ownership_until_release() {
        let mut active = HashSet::new();
        let mut retired = HashSet::new();
        let keycode = 38;

        assert_eq!(
            route_flutter_key_transition(
                &mut active,
                &mut retired,
                keycode,
                KeyState::Pressed,
                true,
            ),
            FlutterKeyDisposition::Dispatch
        );
        assert_eq!(
            route_flutter_key_transition(
                &mut active,
                &mut retired,
                keycode,
                KeyState::Pressed,
                false,
            ),
            FlutterKeyDisposition::Dispatch
        );
        assert_eq!(
            route_flutter_key_transition(
                &mut active,
                &mut retired,
                keycode,
                KeyState::Released,
                false,
            ),
            FlutterKeyDisposition::Dispatch
        );
        assert!(active.is_empty());
    }

    #[test]
    fn returned_input_method_key_stays_with_its_flutter_press() {
        let mut flutter_keys = HashSet::new();
        let mut retired_flutter_keys = HashSet::new();
        let mut input_method_keys = HashSet::new();
        let mut retired_input_method_keys = HashSet::new();
        let backspace = 22;

        assert_eq!(
            route_input_method_key_transition(
                &mut input_method_keys,
                &mut retired_input_method_keys,
                backspace,
                KeyState::Pressed,
                true,
            ),
            FlutterKeyDisposition::Dispatch
        );
        assert_eq!(
            route_flutter_key_transition(
                &mut flutter_keys,
                &mut retired_flutter_keys,
                backspace,
                KeyState::Released,
                false,
            ),
            FlutterKeyDisposition::Forward
        );
        assert_eq!(
            route_input_method_key_transition(
                &mut input_method_keys,
                &mut retired_input_method_keys,
                backspace,
                KeyState::Released,
                false,
            ),
            FlutterKeyDisposition::Dispatch
        );
        assert!(input_method_keys.is_empty());

        assert_eq!(
            route_input_method_key_transition(
                &mut input_method_keys,
                &mut retired_input_method_keys,
                backspace,
                KeyState::Pressed,
                false,
            ),
            FlutterKeyDisposition::Forward
        );
    }
}
