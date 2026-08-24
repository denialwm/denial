use super::*;

#[test]
fn fractional_xwayland_scale_preserves_engine_density() {
    assert_eq!(scale_for_engine(150, XWaylandScaleMode::Fractional), 150);
    assert_eq!(client_scale(150), 1.25);
    assert_eq!(dpi(150), 120);
    assert_eq!(gdk_window_scale(150), 1);
    assert_eq!(gdk_unscaled_dpi(150), 120);
}

#[test]
fn integer_xwayland_mode_retains_the_compatibility_fallback() {
    assert_eq!(scale_for_engine(150, XWaylandScaleMode::Integer), 240);
    assert_eq!(client_scale(240), 2.0);
    assert_eq!(dpi(240), 192);
    assert_eq!(gdk_window_scale(240), 2);
    assert_eq!(gdk_unscaled_dpi(240), 96);
}

#[test]
fn xwayland_xsettings_split_integer_and_fractional_density() {
    assert_eq!(dpi(300), 240);
    assert_eq!(gdk_window_scale(300), 2);
    assert_eq!(gdk_unscaled_dpi(300), 120);
}

#[test]
fn xwayland_scale_mode_parser_defaults_to_fractional() {
    assert_eq!(
        XWaylandScaleMode::parse(None),
        Some(XWaylandScaleMode::Fractional)
    );
    assert_eq!(
        XWaylandScaleMode::parse(Some(OsStr::new("fractional"))),
        Some(XWaylandScaleMode::Fractional)
    );
    assert_eq!(
        XWaylandScaleMode::parse(Some(OsStr::new("integer"))),
        Some(XWaylandScaleMode::Integer)
    );
    assert_eq!(XWaylandScaleMode::parse(Some(OsStr::new("nearest"))), None);
}

#[test]
fn managed_x11_window_cannot_start_across_multiple_outputs() {
    let output = Rectangle::new((2560, 0).into(), (2560, 1440).into());
    let requested = Rectangle::new((0, 0).into(), (5120, 1440).into());

    assert_eq!(
        initial_managed_x11_geometry(requested, output, output),
        output
    );
}

#[test]
fn managed_x11_window_is_centered_inside_its_selected_output() {
    let output = Rectangle::new((-1920, 200).into(), (1920, 1080).into());
    let requested = Rectangle::new((0, 0).into(), (800, 600).into());

    assert_eq!(
        initial_managed_x11_geometry(requested, output, output),
        Rectangle::new((-1360, 440).into(), (800, 600).into())
    );
}

#[test]
fn managed_x11_transient_is_centered_on_parent_and_clamped_to_output() {
    let output = Rectangle::new((0, 0).into(), (1920, 1080).into());
    let parent = Rectangle::new((1500, 800).into(), (400, 240).into());
    let requested = Rectangle::new((0, 0).into(), (640, 480).into());

    assert_eq!(
        initial_managed_x11_geometry(requested, output, parent),
        Rectangle::new((1280, 600).into(), (640, 480).into())
    );
}

#[test]
fn x11_opacity_is_normalized_to_the_wire_range() {
    assert_eq!(normalized_x11_opacity(None), 1.0);
    assert_eq!(normalized_x11_opacity(Some(0)), 0.0);
    assert_eq!(normalized_x11_opacity(Some(u32::MAX)), 1.0);
    assert!((normalized_x11_opacity(Some(u32::MAX / 2)) - 0.5).abs() < 0.000_001);
}

#[test]
fn later_x11_configure_is_bounded_to_one_output() {
    let output = Rectangle::new((0, 0).into(), (1920, 1080).into());
    let requested = Rectangle::new((32, 64).into(), (16_384, 8_000).into());

    assert_eq!(
        constrain_x11_size_to_output(requested, output),
        Rectangle::new((32, 64).into(), (1920, 1080).into())
    );
}

#[test]
fn x11_fullscreen_target_is_a_physical_monitor_not_the_flutter_atlas() {
    let left = Rectangle::new((0, 0).into(), (1920, 1080).into());
    let right = Rectangle::new((1920, 0).into(), (2560, 1440).into());
    let flutter_atlas = Rectangle::new((0, 0).into(), (4480, 1440).into());
    let window = Rectangle::new((2300, 200).into(), (1280, 720).into());

    let target = x11_monitor_geometry(window, [left, right]);

    assert_eq!(target, Some(right));
    assert_ne!(target, Some(flutter_atlas));
}
