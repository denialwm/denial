use super::*;
use smithay::utils::Point;

#[test]
fn restore_geometry_keeps_location_but_bounds_hostile_extents() {
    let bounded = bound_geometry_size(Rectangle::new(
        Point::from((i32::MIN, i32::MAX)),
        Size::from((i32::MAX, 0)),
    ));
    assert_eq!(bounded.loc, Point::from((i32::MIN, i32::MAX)));
    assert_eq!(bounded.size, Size::from((16_384, 1)));
}

#[test]
fn pre_map_client_state_never_invents_a_restore_size() {
    let natural = Rectangle::new(Point::from((100, 120)), Size::from((1280, 720)));
    let unknown = Rectangle::new(Point::from((100, 120)), Size::from((0, 0)));

    assert_eq!(client_restore_geometry(false, natural), None);
    assert_eq!(client_restore_geometry(true, unknown), None);
    assert_eq!(client_restore_geometry(true, natural), Some(natural));
}

#[test]
fn shell_frame_inset_keeps_native_content_inside_the_flutter_frame() {
    let frame = Rectangle::new(Point::from((10, 32)), Size::from((1900, 1038)));
    assert_eq!(
        shell_content_geometry(frame, true),
        Rectangle::new(Point::from((11, 33)), Size::from((1898, 1036)))
    );
    assert_eq!(shell_content_geometry(frame, false), frame);
}

#[test]
fn client_fullscreen_survives_flutter_echo_of_its_authoritative_geometry() {
    let fullscreen = Rectangle::new(Point::from((1920, 0)), Size::from((2560, 1440)));
    let moved = Rectangle::new(Point::from((0, 0)), Size::from((1920, 1080)));

    assert!(preserves_client_fullscreen_geometry(
        true, fullscreen, fullscreen
    ));
    assert!(!preserves_client_fullscreen_geometry(
        false, fullscreen, fullscreen
    ));
    assert!(!preserves_client_fullscreen_geometry(
        true, fullscreen, moved
    ));
}

#[cfg(feature = "flutter")]
#[test]
fn exact_mobile_viewport_ignores_client_size_hints() {
    let requested = Size::from((632, 1342));
    let minimum = Size::from((900, 700));
    let maximum = Size::from((1200, 1000));

    assert_eq!(
        configured_window_size(requested, minimum, maximum, true),
        requested
    );
    assert_eq!(
        configured_window_size(requested, minimum, maximum, false),
        Size::from((900, 1000))
    );
}

#[test]
fn constrained_restore_geometry_follows_an_output_transfer() {
    let source = Rectangle::new(Point::from((0, 0)), Size::from((2560, 1440)));
    let destination = Rectangle::new(Point::from((2560, -180)), Size::from((1920, 1080)));
    let work_area = Rectangle::new(Point::from((2560, -148)), Size::from((1920, 1048)));
    let restore = Rectangle::new(Point::from((2100, 1200)), Size::from((800, 600)));

    assert_eq!(
        transfer_restore_geometry(restore, source, destination, work_area),
        Rectangle::new(Point::from((3680, 300)), Size::from((800, 600)))
    );
}
