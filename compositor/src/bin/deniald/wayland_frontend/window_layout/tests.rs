use smithay::utils::{Point, Size};

use super::*;

fn rect(x: i32, y: i32, width: i32, height: i32) -> Rectangle<i32, Logical> {
    Rectangle::new(Point::from((x, y)), Size::from((width, height)))
}

#[test]
fn stacking_restore_keeps_the_location_but_never_restores_an_unknown_size() {
    assert_eq!(
        visible_stacking_restore(rect(80, 60, 0, 0), rect(10, 10, 900, 700)),
        rect(80, 60, 900, 700)
    );
    assert_eq!(
        visible_stacking_restore(rect(80, 60, 640, 480), rect(10, 10, 900, 700)),
        rect(80, 60, 640, 480)
    );
}

#[test]
fn dwindle_drop_uses_center_for_swap_and_edges_for_directional_splits() {
    let geometry = rect(100, 200, 1000, 600);
    assert_eq!(
        layout_drop_mode(geometry, Point::from((600, 500)), None),
        LayoutDropMode::Swap,
    );
    assert_eq!(
        layout_drop_mode(geometry, Point::from((110, 500)), None),
        LayoutDropMode::Split(LayoutDirection::Left),
    );
    assert_eq!(
        layout_drop_mode(geometry, Point::from((1090, 500)), None),
        LayoutDropMode::Split(LayoutDirection::Right),
    );
    assert_eq!(
        layout_drop_mode(geometry, Point::from((600, 210)), None),
        LayoutDropMode::Split(LayoutDirection::Up),
    );
    assert_eq!(
        layout_drop_mode(geometry, Point::from((600, 790)), None),
        LayoutDropMode::Split(LayoutDirection::Down),
    );
}

#[test]
fn dwindle_drop_hysteresis_stabilizes_center_and_edge_previews() {
    let geometry = rect(0, 0, 1000, 1000);
    let near_left_boundary = Point::from((260, 500));
    assert_eq!(
        layout_drop_mode(geometry, near_left_boundary, None),
        LayoutDropMode::Split(LayoutDirection::Left),
    );
    assert_eq!(
        layout_drop_mode(geometry, near_left_boundary, Some(LayoutDropMode::Swap),),
        LayoutDropMode::Swap,
    );

    let near_center_boundary = Point::from((300, 500));
    assert_eq!(
        layout_drop_mode(geometry, near_center_boundary, None),
        LayoutDropMode::Swap,
    );
    assert_eq!(
        layout_drop_mode(
            geometry,
            near_center_boundary,
            Some(LayoutDropMode::Split(LayoutDirection::Left)),
        ),
        LayoutDropMode::Split(LayoutDirection::Left),
    );
}

#[test]
fn scrolling_uses_directional_drop_zones_while_stacking_remains_swap_only() {
    let geometry = rect(0, 0, 1000, 600);
    let top_edge = Point::from((500, 10));
    assert_eq!(
        layout_drop_mode_for_kind(
            WindowLayoutKind::Scrolling,
            LayoutAxis::Horizontal,
            geometry,
            top_edge,
            None
        ),
        LayoutDropMode::Split(LayoutDirection::Up),
    );
    assert_eq!(
        layout_drop_mode_for_kind(
            WindowLayoutKind::Stacking,
            LayoutAxis::Horizontal,
            geometry,
            top_edge,
            None
        ),
        LayoutDropMode::Swap,
    );
}

#[test]
fn scrolling_drop_swaps_on_the_strip_axis_and_splits_across_it() {
    let geometry = rect(100, 200, 1000, 600);
    for axis in [LayoutAxis::Horizontal, LayoutAxis::Vertical] {
        for (point, direction, edge_axis) in [
            ((110, 500), LayoutDirection::Left, LayoutAxis::Horizontal),
            ((1090, 500), LayoutDirection::Right, LayoutAxis::Horizontal),
            ((600, 210), LayoutDirection::Up, LayoutAxis::Vertical),
            ((600, 790), LayoutDirection::Down, LayoutAxis::Vertical),
        ] {
            for previous in [
                None,
                Some(LayoutDropMode::Swap),
                Some(LayoutDropMode::Split(direction)),
                Some(LayoutDropMode::InsertColumn { before: true }),
            ] {
                assert_eq!(
                    layout_drop_mode_for_kind(
                        WindowLayoutKind::Scrolling,
                        axis,
                        geometry,
                        Point::from(point),
                        previous
                    ),
                    if axis == edge_axis {
                        LayoutDropMode::Swap
                    } else {
                        LayoutDropMode::Split(direction)
                    },
                );
                assert_eq!(
                    layout_drop_mode_for_kind(
                        WindowLayoutKind::Dwindle,
                        axis,
                        geometry,
                        Point::from(point),
                        previous
                    ),
                    LayoutDropMode::Split(direction),
                );
            }
        }
        assert_eq!(
            layout_drop_mode_for_kind(
                WindowLayoutKind::Scrolling,
                axis,
                geometry,
                Point::from((600, 500)),
                None
            ),
            LayoutDropMode::Swap,
        );
    }
}

#[test]
fn decorated_layout_maximum_preserves_unconstrained_dimensions() {
    assert_eq!(
        layout_frame_maximum_size(Size::from((800, 0)), true),
        Size::from((802, 0))
    );
    assert_eq!(
        layout_frame_maximum_size(Size::from((0, 600)), false),
        Size::from((0, 600))
    );
    assert_eq!(
        layout_frame_maximum_size(Size::from((i32::MAX, 0)), true),
        Size::from((i32::MAX, 0))
    );
}

#[test]
fn decorated_layout_minimum_includes_the_server_frame() {
    assert_eq!(
        layout_frame_minimum_size(Size::from((800, 600)), true),
        Size::from((802, 602)),
    );
    assert_eq!(
        layout_frame_minimum_size(Size::from((0, 0)), false),
        Size::from((1, 1)),
    );
}

#[cfg(feature = "flutter")]
#[test]
fn touchpad_scrolling_delta_applies_the_configured_travel_scale() {
    assert_eq!(
        touchpad_scrolling_layout_delta(125.0, 1_000, 10, 1.0),
        610.0
    );
    assert_eq!(
        touchpad_scrolling_layout_delta(-62.5, 1_000, 10, 0.5),
        -152.5
    );
    assert_eq!(
        touchpad_scrolling_layout_delta(100.0, 1_000, 10, 2.0),
        976.0
    );
}

#[cfg(feature = "flutter")]
#[test]
fn mouse_wheel_scrolling_delta_applies_speed_and_direction() {
    assert_eq!(
        mouse_wheel_scrolling_layout_delta(
            -15.0,
            1_000,
            10,
            1.0,
            ScrollingLayoutWheelUpDirection::Left,
        ),
        610.0
    );
    assert_eq!(
        mouse_wheel_scrolling_layout_delta(
            -15.0,
            1_000,
            10,
            2.0,
            ScrollingLayoutWheelUpDirection::Right,
        ),
        -1_220.0
    );
    assert_eq!(
        mouse_wheel_scrolling_layout_delta(
            7.5,
            1_000,
            10,
            0.5,
            ScrollingLayoutWheelUpDirection::Left,
        ),
        -152.5
    );
}

#[test]
fn quarter_turned_outputs_use_the_vertical_scrolling_axis() {
    assert_eq!(
        scrolling_layout_axis(
            ScrollingLayoutAxis::Auto,
            super::super::OutputTransform::Normal,
        ),
        LayoutAxis::Horizontal
    );
    assert_eq!(
        scrolling_layout_axis(
            ScrollingLayoutAxis::Auto,
            super::super::OutputTransform::Rotate180,
        ),
        LayoutAxis::Horizontal
    );
    for transform in [
        super::super::OutputTransform::Rotate90,
        super::super::OutputTransform::Rotate270,
        super::super::OutputTransform::Flipped90,
        super::super::OutputTransform::Flipped270,
    ] {
        assert_eq!(
            scrolling_layout_axis(ScrollingLayoutAxis::Auto, transform),
            LayoutAxis::Vertical,
        );
    }
}

#[test]
fn explicit_scrolling_axis_overrides_the_output_transform() {
    assert_eq!(
        scrolling_layout_axis(
            ScrollingLayoutAxis::Horizontal,
            super::super::OutputTransform::Rotate90,
        ),
        LayoutAxis::Horizontal,
    );
    assert_eq!(
        scrolling_layout_axis(
            ScrollingLayoutAxis::Vertical,
            super::super::OutputTransform::Normal,
        ),
        LayoutAxis::Vertical,
    );
}

#[test]
fn only_regular_resizable_toplevels_enter_managed_layouts() {
    let regular = LayoutWindowProperties {
        alive: true,
        transient: false,
        auxiliary: false,
        override_redirect: false,
        minimized: false,
        pinned: false,
        rigid_size: false,
    };
    assert!(regular.is_tiling_candidate(false));
    assert!(
        !LayoutWindowProperties {
            rigid_size: true,
            ..regular
        }
        .is_tiling_candidate(false)
    );
    assert!(
        LayoutWindowProperties {
            rigid_size: true,
            ..regular
        }
        .is_tiling_candidate(true)
    );
    assert!(
        !LayoutWindowProperties {
            auxiliary: true,
            ..regular
        }
        .is_tiling_candidate(false)
    );
    assert!(
        !LayoutWindowProperties {
            transient: true,
            ..regular
        }
        .is_tiling_candidate(false)
    );
    assert!(
        !LayoutWindowProperties {
            pinned: true,
            ..regular
        }
        .is_tiling_candidate(false)
    );

    assert!(has_rigid_dimension(
        Size::from((420, 300)),
        Size::from((420, 300))
    ));
    assert!(has_rigid_dimension(
        Size::from((420, 0)),
        Size::from((400, 0))
    ));
    assert!(!has_rigid_dimension(
        Size::from((320, 200)),
        Size::from((0, 1200))
    ));
}
