use super::*;

#[test]
fn maps_xdg_resize_edges_without_accepting_none() {
    let top_left = ResizeEdges::from_xdg(xdg_toplevel::ResizeEdge::TopLeft).unwrap();
    assert!(top_left.top);
    assert!(top_left.left);
    assert!(!top_left.bottom);
    assert!(!top_left.right);
    assert!(ResizeEdges::from_xdg(xdg_toplevel::ResizeEdge::None).is_none());
}

#[test]
fn hostile_xdg_size_hints_cannot_invert_the_constraint_range() {
    assert_eq!(constrain_dimension(500, 1_000, 100), 1_000);
    assert_eq!(constrain_dimension(500, -10, -20), 1);
    assert_eq!(constrain_dimension(i32::MAX, 1, 4_096), 4_096);
    assert_eq!(constrain_dimension(i32::MIN, 0, 0), 1);
    assert_eq!(
        constrain_dimension(i32::MAX, i32::MAX, 0),
        MAX_WINDOW_DIMENSION
    );
    assert_eq!(
        constrain_dimension(i32::MAX, 1, i32::MAX),
        MAX_WINDOW_DIMENSION
    );
    for requested in [i32::MIN, -1, 0, 1, MAX_WINDOW_DIMENSION, i32::MAX] {
        for minimum in [i32::MIN, -1, 0, 1, MAX_WINDOW_DIMENSION, i32::MAX] {
            for maximum in [i32::MIN, -1, 0, 1, MAX_WINDOW_DIMENSION, i32::MAX] {
                let result = constrain_dimension(requested, minimum, maximum);
                assert!((1..=MAX_WINDOW_DIMENSION).contains(&result));
            }
        }
    }
}

#[test]
fn resize_arithmetic_saturates_without_losing_the_fixed_edge() {
    assert_eq!(requested_resize_dimension(640, f64::MAX, true), i32::MAX);
    assert_eq!(requested_resize_dimension(640, f64::INFINITY, true), 640);
    assert_eq!(requested_resize_dimension(640, f64::NAN, false), 640);
    assert_eq!(
        anchored_resize_origin(i32::MAX, i32::MAX, i32::MAX),
        i32::MAX
    );
    assert_eq!(anchored_resize_origin(i32::MIN, 1, i32::MAX), i32::MIN);
}

#[cfg(feature = "flutter")]
#[test]
fn local_flutter_grab_uses_anchored_move_and_resize_geometry() {
    let start = GrabStartData {
        focus: None,
        button: 0x110,
        location: Point::from((200.0, 160.0)),
    };
    let initial = WindowGeometry {
        x: 100.0,
        y: 80.0,
        width: 800.0,
        height: 600.0,
    };
    let mut moving = LocalFlutterWindowGrab::new_move(start.clone(), 91, initial);
    moving.update_geometry(Point::from((235.4, 139.6)));
    assert_eq!(
        moving.last_geometry,
        WindowGeometry {
            x: 135.0,
            y: 60.0,
            ..initial
        }
    );

    let mut resizing = LocalFlutterWindowGrab::new_resize(
        start,
        91,
        initial,
        ResizeEdges::new(true, false, true, false),
    );
    resizing.update_geometry(Point::from((250.0, 200.0)));
    assert_eq!(
        resizing.last_geometry,
        WindowGeometry {
            x: 150.0,
            y: 120.0,
            width: 750.0,
            height: 560.0,
        }
    );
}
