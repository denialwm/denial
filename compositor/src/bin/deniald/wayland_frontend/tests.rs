#[cfg(feature = "flutter")]
use super::OutputWindowMembership;
#[cfg(feature = "flutter")]
use super::{
    CursorImageStatus, RoutedPointerTarget, ShellFullscreenTransition,
    accepted_flutter_cursor_shape, classify_window_opacity, cursor_position_for_modality,
    cursor_shape_for_modality, input_routing_changed, input_visibility_changed,
    shell_fullscreen_transition, software_cursor_shape, window_expects_sample,
};
use super::{
    InitialXdgPlacementPolicy, MAX_PENDING_DMABUF_IMPORTS, dmabuf_import_queue_has_capacity,
    initial_xdg_placement_policy,
};
use super::{RuntimeState, ViewporterState, XdgActivationState};
use crate::window_placement_store::WindowPlacementState;
#[cfg(feature = "flutter")]
use crate::wire::{InputLayoutSnapshot, InputRect, WindowOpacityClass};
#[cfg(feature = "flutter")]
use denial_core::topology::OutputId;
#[cfg(feature = "flutter")]
use smithay::input::pointer::CursorIcon;
use smithay::reexports::wayland_server::Display;
#[cfg(feature = "flutter")]
use smithay::utils::{Logical, Rectangle};
#[cfg(feature = "flutter")]
use std::collections::HashSet;

#[cfg(feature = "flutter")]
#[test]
fn window_opacity_distinguishes_content_from_client_decoration_alpha() {
    let surface = Rectangle::<i32, Logical>::from_size((2572, 1438).into());
    let content = Rectangle::<i32, Logical>::new((16, 18).into(), (2540, 1396).into());
    let chromium_regions = [
        Rectangle::new((24, 10).into(), (2524, 8).into()),
        Rectangle::new((16, 18).into(), (2540, 1388).into()),
    ];

    assert_eq!(
        classify_window_opacity(surface, content, Some(&chromium_regions), 1.0),
        WindowOpacityClass::BorderAlphaOnly
    );
    assert_eq!(
        classify_window_opacity(surface, content, Some(&[content]), 1.0),
        WindowOpacityClass::FullyOpaque
    );
    assert_eq!(
        classify_window_opacity(surface, content, Some(&chromium_regions), 0.0),
        WindowOpacityClass::ContentTranslucent
    );
}

#[cfg(feature = "flutter")]
#[test]
fn alpha_reaching_the_window_interior_remains_content_translucent() {
    let surface = Rectangle::<i32, Logical>::from_size((1000, 1000).into());
    let opaque = [Rectangle::new((0, 0).into(), (1000, 940).into())];

    assert_eq!(
        classify_window_opacity(surface, surface, Some(&opaque), 1.0),
        WindowOpacityClass::ContentTranslucent
    );
    assert_eq!(
        classify_window_opacity(surface, surface, None, 1.0),
        WindowOpacityClass::ContentTranslucent
    );
}

#[test]
fn advertises_wp_viewporter_version_one() {
    let display = Display::<RuntimeState>::new().expect("Wayland display should initialize");
    let display_handle = display.handle();
    let viewporter = ViewporterState::new::<RuntimeState>(&display_handle);
    let global = display_handle
        .backend_handle()
        .global_info(viewporter.global())
        .expect("wp_viewporter global should remain registered");

    assert_eq!(global.interface.name, "wp_viewporter");
    assert_eq!(global.version, 1);
    assert!(!global.disabled);
}

#[test]
fn advertises_xdg_activation_version_one() {
    let display = Display::<RuntimeState>::new().expect("Wayland display should initialize");
    let display_handle = display.handle();
    let activation = XdgActivationState::new::<RuntimeState>(&display_handle);
    let global = display_handle
        .backend_handle()
        .global_info(activation.global())
        .expect("xdg_activation_v1 global should remain registered");

    assert_eq!(global.interface.name, "xdg_activation_v1");
    assert_eq!(global.version, 1);
    assert!(!global.disabled);
}

#[test]
fn dmabuf_import_queue_enforces_its_exact_boundary() {
    assert!(dmabuf_import_queue_has_capacity(
        MAX_PENDING_DMABUF_IMPORTS - 1
    ));
    assert!(!dmabuf_import_queue_has_capacity(
        MAX_PENDING_DMABUF_IMPORTS
    ));
    assert!(!dmabuf_import_queue_has_capacity(usize::MAX));
}

#[cfg(feature = "flutter")]
#[test]
fn output_window_membership_moves_without_duplicates_and_removes_cleanly() {
    let first = OutputId(1);
    let second = OutputId(2);
    let mut membership = OutputWindowMembership::<u64, &'static str>::default();

    assert!(membership.update(10, "first", Some(first)));
    assert!(membership.update(20, "second", Some(first)));
    assert!(!membership.update(10, "first", Some(first)));
    assert_eq!(
        membership.windows(first).copied().collect::<Vec<_>>(),
        vec!["first", "second"]
    );

    assert!(membership.update(10, "first", Some(second)));
    assert_eq!(
        membership.windows(first).copied().collect::<Vec<_>>(),
        vec!["second"]
    );
    assert_eq!(
        membership.windows(second).copied().collect::<Vec<_>>(),
        vec!["first"]
    );

    assert_eq!(membership.remove(&10), Some("first"));
    assert_eq!(membership.remove(&10), None);
    assert_eq!(membership.windows(second).count(), 0);
    membership.clear();
    assert_eq!(membership.windows(first).count(), 0);
}

#[test]
fn normal_xdg_toplevels_keep_saved_location_but_choose_their_size() {
    assert_eq!(
        initial_xdg_placement_policy(
            false,
            false,
            false,
            false,
            WindowPlacementState::default(),
            WindowPlacementState::default(),
        ),
        InitialXdgPlacementPolicy::ClientSized
    );
}

#[test]
fn explicit_client_state_wins_over_saved_shell_state() {
    let saved_fullscreen = WindowPlacementState {
        maximized: false,
        fullscreen: true,
    };
    assert_eq!(
        initial_xdg_placement_policy(
            false,
            false,
            false,
            true,
            WindowPlacementState::default(),
            saved_fullscreen,
        ),
        InitialXdgPlacementPolicy::ClientSized
    );
    assert_eq!(
        initial_xdg_placement_policy(
            false,
            false,
            false,
            true,
            saved_fullscreen,
            WindowPlacementState::default(),
        ),
        InitialXdgPlacementPolicy::SkipSaved
    );
}

#[test]
fn only_primary_unparented_toplevels_restore_shell_owned_state() {
    let saved_maximized = WindowPlacementState {
        maximized: true,
        fullscreen: false,
    };
    assert_eq!(
        initial_xdg_placement_policy(
            false,
            false,
            false,
            false,
            WindowPlacementState::default(),
            saved_maximized,
        ),
        InitialXdgPlacementPolicy::RestoreShellState
    );
    for (has_parent, has_sibling, configured) in [
        (true, false, false),
        (false, true, false),
        (false, false, true),
    ] {
        assert_eq!(
            initial_xdg_placement_policy(
                has_parent,
                has_sibling,
                configured,
                false,
                WindowPlacementState::default(),
                saved_maximized,
            ),
            InitialXdgPlacementPolicy::SkipSaved
        );
    }
}

#[cfg(feature = "flutter")]
#[test]
fn wayland_cursor_names_and_visibility_map_to_shell_shapes() {
    assert_eq!(
        software_cursor_shape(&CursorImageStatus::Named(CursorIcon::Text)),
        "text"
    );
    assert_eq!(
        software_cursor_shape(&CursorImageStatus::Named(CursorIcon::NwseResize)),
        "nwse-resize"
    );
    assert_eq!(software_cursor_shape(&CursorImageStatus::Hidden), "none");
}

#[cfg(feature = "flutter")]
#[test]
fn only_the_flutter_pointer_owner_can_request_a_shell_cursor() {
    assert_eq!(
        accepted_flutter_cursor_shape(RoutedPointerTarget::Flutter, "text"),
        Some("text")
    );
    assert_eq!(
        accepted_flutter_cursor_shape(RoutedPointerTarget::Client(42), "text"),
        None
    );
}

#[cfg(feature = "flutter")]
#[test]
fn touch_modality_suppresses_replayed_cursor_shape_and_position() {
    assert_eq!(cursor_shape_for_modality(false, "text"), "none");
    assert_eq!(cursor_position_for_modality(false, (32.0, 64.0)), None);
    assert_eq!(cursor_shape_for_modality(true, "text"), "text");
    assert_eq!(
        cursor_position_for_modality(true, (32.0, 64.0)),
        Some((32.0, 64.0))
    );
}

#[cfg(feature = "flutter")]
#[test]
fn input_route_survives_epoch_and_visibility_only_layout_updates() {
    let current = InputLayoutSnapshot::default();
    let mut next = current.clone();
    next.epoch = 9;
    next.visible_surface_ids.push(42);
    assert!(!input_routing_changed(Some(&current), &next));
    assert!(input_visibility_changed(Some(&current), &next));

    next.shell_regions.push(InputRect {
        x: 0.0,
        y: 0.0,
        width: 10.0,
        height: 10.0,
    });
    assert!(input_routing_changed(Some(&current), &next));
    assert!(input_routing_changed(None, &next));
}

#[cfg(feature = "flutter")]
#[test]
fn only_visible_windows_wait_for_flutter_texture_samples() {
    let visible = HashSet::from([42]);

    assert!(window_expects_sample(false, &visible, 7));
    assert!(window_expects_sample(true, &visible, 42));
    assert!(!window_expects_sample(true, &visible, 7));
}

#[cfg(feature = "flutter")]
#[test]
fn client_fullscreen_shortcut_exits_across_input_layout_races() {
    use ShellFullscreenTransition::{EnterShell, ExitClient, ExitShell};

    assert_eq!(shell_fullscreen_transition(true, false, true), ExitClient);
    assert_eq!(shell_fullscreen_transition(true, false, false), ExitClient);
    assert_eq!(shell_fullscreen_transition(true, true, true), ExitClient);
    assert_eq!(shell_fullscreen_transition(false, true, true), ExitShell);
    assert_eq!(shell_fullscreen_transition(false, false, false), EnterShell);
}
