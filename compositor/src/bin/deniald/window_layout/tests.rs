use super::*;

const OUTPUT: LayoutSpace = LayoutSpace::new(OutputId(1), 1);
const SECOND_OUTPUT: LayoutSpace = LayoutSpace::new(OutputId(2), 1);
const SECOND_WORKSPACE: LayoutSpace = LayoutSpace::new(OutputId(1), 2);

fn rect(x: i32, y: i32, width: i32, height: i32) -> Rectangle<i32, Logical> {
    Rectangle::new(Point::from((x, y)), Size::from((width, height)))
}

fn prepare_scrolling(
    layout: &mut ScrollingLayout<u64>,
    work_area: Rectangle<i32, Logical>,
    gap: i32,
    axis: LayoutAxis,
) {
    layout.prepare_arrange(OUTPUT, work_area, gap, axis);
}

#[test]
fn pointer_resize_edges_follow_the_layout_axis_and_pointer_half() {
    let geometry = rect(100, 200, 400, 300);

    assert_eq!(
        LayoutResizeEdges::from_pointer(
            Point::from((150.0, 225.0)),
            geometry,
            Some(LayoutAxis::Horizontal),
        ),
        LayoutResizeEdges {
            left: true,
            ..LayoutResizeEdges::default()
        },
    );
    assert_eq!(
        LayoutResizeEdges::from_pointer(
            Point::from((450.0, 475.0)),
            geometry,
            Some(LayoutAxis::Horizontal),
        ),
        LayoutResizeEdges {
            right: true,
            ..LayoutResizeEdges::default()
        },
    );
    assert_eq!(
        LayoutResizeEdges::from_pointer(
            Point::from((150.0, 225.0)),
            geometry,
            Some(LayoutAxis::Vertical),
        ),
        LayoutResizeEdges {
            top: true,
            ..LayoutResizeEdges::default()
        },
    );
    assert_eq!(
        LayoutResizeEdges::from_pointer(
            Point::from((450.0, 475.0)),
            geometry,
            Some(LayoutAxis::Vertical),
        ),
        LayoutResizeEdges {
            bottom: true,
            ..LayoutResizeEdges::default()
        },
    );
    assert_eq!(
        LayoutResizeEdges::from_pointer(Point::from((150.0, 225.0)), geometry, None),
        LayoutResizeEdges {
            top: true,
            left: true,
            ..LayoutResizeEdges::default()
        },
    );
}

#[test]
fn dwindle_splits_the_focused_leaf_and_uses_parent_aspect_ratio() {
    let mut layout = DwindleLayout::<u64>::default();
    layout.insert(LayoutInsertion {
        window: 1,
        space: OUTPUT,
        anchor: None,
    });
    layout.insert(LayoutInsertion {
        window: 2,
        space: OUTPUT,
        anchor: Some(1),
    });
    layout.insert(LayoutInsertion {
        window: 3,
        space: OUTPUT,
        anchor: Some(2),
    });

    assert_eq!(
        layout.arrange(OUTPUT, rect(10, 20, 1000, 600), 10),
        vec![
            LayoutPlacement {
                window: 1,
                geometry: rect(10, 20, 495, 600),
            },
            LayoutPlacement {
                window: 2,
                geometry: rect(515, 20, 495, 295),
            },
            LayoutPlacement {
                window: 3,
                geometry: rect(515, 325, 495, 295),
            },
        ]
    );
}

#[test]
fn dwindle_respects_minimum_widths_when_they_fit() {
    let mut layout = DwindleLayout::<u64>::default();
    layout.insert(LayoutInsertion {
        window: 1,
        space: OUTPUT,
        anchor: None,
    });
    layout.insert(LayoutInsertion {
        window: 2,
        space: OUTPUT,
        anchor: Some(1),
    });
    assert!(layout.update_minimum_size(&1, Size::from((700, 1))));
    assert!(layout.update_minimum_size(&2, Size::from((200, 1))));

    assert_eq!(
        layout.arrange(OUTPUT, rect(0, 0, 1000, 600), 10),
        vec![
            LayoutPlacement {
                window: 1,
                geometry: rect(0, 0, 700, 600),
            },
            LayoutPlacement {
                window: 2,
                geometry: rect(710, 0, 290, 600),
            },
        ]
    );
}

#[test]
fn dwindle_overflows_instead_of_undersizing_impossible_minima() {
    let mut layout = DwindleLayout::<u64>::default();
    layout.insert(LayoutInsertion {
        window: 1,
        space: OUTPUT,
        anchor: None,
    });
    layout.insert(LayoutInsertion {
        window: 2,
        space: OUTPUT,
        anchor: Some(1),
    });
    assert!(layout.update_minimum_size(&1, Size::from((700, 1))));
    assert!(layout.update_minimum_size(&2, Size::from((600, 1))));

    assert_eq!(
        layout.arrange(OUTPUT, rect(0, 0, 1000, 600), 10),
        vec![
            LayoutPlacement {
                window: 1,
                geometry: rect(0, 0, 700, 600),
            },
            LayoutPlacement {
                window: 2,
                geometry: rect(710, 0, 600, 600),
            },
        ]
    );
}

#[test]
fn removing_a_leaf_collapses_its_parent_without_disturbing_other_outputs() {
    let mut layout = DwindleLayout::<u64>::default();
    for window in 1..=3 {
        layout.insert(LayoutInsertion {
            window,
            space: OUTPUT,
            anchor: (window > 1).then_some(window - 1),
        });
    }
    layout.insert(LayoutInsertion {
        window: 4,
        space: SECOND_OUTPUT,
        anchor: None,
    });

    assert!(layout.remove(&2));
    assert!(!layout.contains(&2));
    assert_eq!(
        layout.arrange(OUTPUT, rect(0, 0, 800, 600), 0),
        vec![
            LayoutPlacement {
                window: 1,
                geometry: rect(0, 0, 400, 600),
            },
            LayoutPlacement {
                window: 3,
                geometry: rect(400, 0, 400, 600),
            },
        ]
    );
    assert_eq!(
        layout.arrange(SECOND_OUTPUT, rect(800, 0, 800, 600), 0),
        vec![LayoutPlacement {
            window: 4,
            geometry: rect(800, 0, 800, 600),
        }]
    );
}

#[test]
fn dwindle_workspace_move_preserves_unrelated_trees_and_same_space_position() {
    let mut layout = DwindleLayout::<u64>::default();
    let third_workspace = LayoutSpace::new(OUTPUT.output, 3);
    let spaces = [OUTPUT, SECOND_WORKSPACE, third_workspace, SECOND_OUTPUT];
    let area = rect(0, 0, 1000, 600);
    for (index, space) in spaces.into_iter().enumerate() {
        let first = index as u64 * 10 + 1;
        for window in first..first + 3 {
            layout.insert(LayoutInsertion {
                window,
                space,
                anchor: None,
            });
        }
        assert!(layout.swap(&first, &(first + 2), false));
        assert!(keyboard_resize(
            &mut layout,
            first + 2,
            area,
            10,
            LayoutAxis::Horizontal,
            LayoutSizeChange::Adjust(100.0),
        ));
    }
    let unrelated =
        [third_workspace, SECOND_OUTPUT].map(|space| (space, layout.arrange(space, area, 10)));
    let destination_before = layout.arrange(SECOND_WORKSPACE, area, 10);

    assert!(layout.move_to_space(&1, SECOND_WORKSPACE));
    assert_eq!(layout.space_for(&1), Some(SECOND_WORKSPACE));
    assert!(
        !layout
            .arrange(OUTPUT, area, 10)
            .iter()
            .any(|p| p.window == 1)
    );
    // Inserting at the destination retains its existing resized root split.
    assert_eq!(
        layout.arrange(SECOND_WORKSPACE, area, 10)[0],
        destination_before[0],
    );
    for (space, before) in &unrelated {
        assert_eq!(layout.arrange(*space, area, 10), *before);
    }

    assert!(layout.move_to_space(&1, OUTPUT));
    assert_eq!(layout.space_for(&1), Some(OUTPUT));
    for (space, before) in &unrelated {
        assert_eq!(layout.arrange(*space, area, 10), *before);
    }
    let before = layout.arrange(OUTPUT, area, 10);
    assert!(!layout.move_to_space(&1, OUTPUT));
    assert!(!layout.move_to_space(&999, SECOND_WORKSPACE));
    assert_eq!(layout.arrange(OUTPUT, area, 10), before);
}

#[test]
fn scrolling_workspace_move_preserves_other_rows_and_the_moved_width() {
    let mut layout = ScrollingLayout::<u64>::default();
    let third_workspace = LayoutSpace::new(OUTPUT.output, 3);
    let spaces = [OUTPUT, SECOND_WORKSPACE, third_workspace, SECOND_OUTPUT];
    let area = rect(0, 0, 1000, 600);
    for (index, space) in spaces.into_iter().enumerate() {
        let first = index as u64 * 10 + 1;
        for window in first..first + 3 {
            layout.insert(LayoutInsertion {
                window,
                space,
                anchor: None,
            });
        }
        assert!(layout.move_beside(&first, &(first + 1), LayoutDirection::Up));
        layout.prepare_arrange(space, area, 10, LayoutAxis::Horizontal);
        assert!(layout.scroll_horizontally(space, area, 10, LayoutAxis::Horizontal, -125.0));
    }
    layout.rows.get_mut(&OUTPUT).unwrap().columns[1].width_fraction = 0.45;
    assert!(layout.update_minimum_size(&3, Size::from((475, 1))));
    let unrelated = [third_workspace, SECOND_OUTPUT].map(|space| {
        let row = &layout.rows[&space];
        (
            space,
            layout.arrange(space, area, 10),
            row.view_start,
            row.scroll_origin,
            row.active,
        )
    });

    for destination in [SECOND_WORKSPACE, OUTPUT] {
        assert!(layout.move_to_space(&3, destination));
        assert_eq!(layout.space_for(&3), Some(destination));
        for space in spaces {
            layout.prepare_arrange(space, area, 10, LayoutAxis::Horizontal);
        }
        let moved = &layout.rows[&destination].columns.last().unwrap();
        assert_eq!(moved.active, 3);
        assert_eq!(moved.width_fraction, 0.45);
        assert_eq!(
            layout
                .arrange(destination, area, 10)
                .iter()
                .find(|p| p.window == 3)
                .unwrap()
                .geometry
                .size
                .w,
            475,
        );
        for (space, before, view_start, scroll_origin, active) in &unrelated {
            assert_eq!(layout.arrange(*space, area, 10), *before);
            let row = &layout.rows[space];
            assert_eq!(row.view_start, *view_start);
            assert_eq!(row.scroll_origin, *scroll_origin);
            assert_eq!(row.active, *active);
        }
    }
    let before = layout.arrange(OUTPUT, area, 10);
    assert!(!layout.move_to_space(&3, OUTPUT));
    assert!(!layout.move_to_space(&999, SECOND_WORKSPACE));
    assert_eq!(layout.arrange(OUTPUT, area, 10), before);
}

#[test]
fn scrolling_workspace_move_retains_maximize_and_retires_only_the_empty_row() {
    let mut layout = ScrollingLayout::<u64>::default();
    let area = rect(0, 0, 1000, 600);
    for (window, space) in [(1, OUTPUT), (2, SECOND_WORKSPACE)] {
        layout.insert(LayoutInsertion {
            window,
            space,
            anchor: None,
        });
        layout.prepare_arrange(space, area, 10, LayoutAxis::Horizontal);
    }
    layout.rows.get_mut(&OUTPUT).unwrap().columns[0].width_fraction = 0.4;
    assert!(layout.set_maximized(&1, true));

    assert!(layout.move_to_space(&1, SECOND_WORKSPACE));
    assert!(!layout.rows.contains_key(&OUTPUT));
    assert!(layout.is_maximized(&1));
    layout.prepare_arrange(SECOND_WORKSPACE, area, 10, LayoutAxis::Horizontal);
    assert_eq!(
        layout.arrange(SECOND_WORKSPACE, area, 10)[1]
            .geometry
            .size
            .w,
        1000
    );
    assert!(layout.set_maximized(&1, false));
    assert_eq!(
        layout.arrange(SECOND_WORKSPACE, area, 10)[1]
            .geometry
            .size
            .w,
        400
    );
    assert_eq!(layout.space_for(&2), Some(SECOND_WORKSPACE));
}

#[test]
fn stacking_explicitly_leaves_geometry_unmanaged() {
    let mut layout = create_window_layout::<u64>(WindowLayoutKind::Stacking);
    layout.insert(LayoutInsertion {
        window: 1,
        space: OUTPUT,
        anchor: None,
    });
    assert!(!layout.manages_geometry());
    assert!(layout.arrange(OUTPUT, rect(0, 0, 800, 600), 10).is_empty());
}

#[test]
fn dwindle_swaps_leaves_without_rebuilding_the_tree() {
    let mut layout = DwindleLayout::<u64>::default();
    for window in 1..=3 {
        layout.insert(LayoutInsertion {
            window,
            space: OUTPUT,
            anchor: (window > 1).then_some(window - 1),
        });
    }

    assert!(layout.swap(&1, &3, true));
    assert_eq!(
        layout.arrange(OUTPUT, rect(0, 0, 1000, 600), 0),
        vec![
            LayoutPlacement {
                window: 3,
                geometry: rect(0, 0, 500, 600),
            },
            LayoutPlacement {
                window: 2,
                geometry: rect(500, 0, 500, 300),
            },
            LayoutPlacement {
                window: 1,
                geometry: rect(500, 300, 500, 300),
            },
        ]
    );
}

#[test]
fn dwindle_edge_drop_places_the_moved_leaf_on_the_promised_side() {
    for direction in [
        LayoutDirection::Left,
        LayoutDirection::Right,
        LayoutDirection::Up,
        LayoutDirection::Down,
    ] {
        let mut layout = DwindleLayout::<u64>::default();
        for window in 1..=3 {
            layout.insert(LayoutInsertion {
                window,
                space: OUTPUT,
                anchor: (window > 1).then_some(window - 1),
            });
        }

        assert!(layout.move_beside(&1, &3, direction));
        let placements = layout.arrange(OUTPUT, rect(0, 0, 1000, 600), 10);
        let moved = placements
            .iter()
            .find(|placement| placement.window == 1)
            .expect("moved leaf remains arranged")
            .geometry;
        let target = placements
            .iter()
            .find(|placement| placement.window == 3)
            .expect("target leaf remains arranged")
            .geometry;
        match direction {
            LayoutDirection::Left => {
                assert!(moved.loc.x.saturating_add(moved.size.w) <= target.loc.x)
            }
            LayoutDirection::Right => {
                assert!(target.loc.x.saturating_add(target.size.w) <= moved.loc.x)
            }
            LayoutDirection::Up => {
                assert!(moved.loc.y.saturating_add(moved.size.h) <= target.loc.y)
            }
            LayoutDirection::Down => {
                assert!(target.loc.y.saturating_add(target.size.h) <= moved.loc.y)
            }
        }
    }
}

#[test]
fn dwindle_edge_drop_preserves_the_moved_leaf_minimum_size() {
    let mut layout = DwindleLayout::<u64>::default();
    layout.insert(LayoutInsertion {
        window: 1,
        space: OUTPUT,
        anchor: None,
    });
    layout.insert(LayoutInsertion {
        window: 2,
        space: OUTPUT,
        anchor: Some(1),
    });
    assert!(layout.update_minimum_size(&1, Size::from((320, 240))));

    assert!(layout.move_beside(&1, &2, LayoutDirection::Down));
    assert_eq!(
        layout_minimum_size(&layout.minimum_sizes, &1),
        Size::from((320, 240)),
    );
}

#[test]
fn dwindle_cross_space_swap_exchanges_authoritative_ownership() {
    let mut layout = DwindleLayout::<u64>::default();
    layout.insert(LayoutInsertion {
        window: 1,
        space: OUTPUT,
        anchor: None,
    });
    layout.insert(LayoutInsertion {
        window: 2,
        space: SECOND_WORKSPACE,
        anchor: None,
    });

    assert!(layout.swap(&1, &2, true));
    assert_eq!(layout.space_for(&1), Some(SECOND_WORKSPACE));
    assert_eq!(layout.space_for(&2), Some(OUTPUT));
    assert_eq!(layout.arrange(OUTPUT, rect(0, 0, 800, 600), 0)[0].window, 2);
    assert_eq!(
        layout.arrange(SECOND_WORKSPACE, rect(0, 0, 800, 600), 0)[0].window,
        1
    );
}

#[test]
fn directional_navigation_prefers_aligned_tiles() {
    let placements = vec![
        LayoutPlacement {
            window: 1,
            geometry: rect(0, 0, 500, 600),
        },
        LayoutPlacement {
            window: 2,
            geometry: rect(500, 0, 500, 300),
        },
        LayoutPlacement {
            window: 3,
            geometry: rect(500, 300, 500, 300),
        },
    ];

    assert_eq!(
        directional_neighbor(&1, &placements, LayoutDirection::Right),
        Some(2)
    );
    assert_eq!(
        directional_neighbor(&2, &placements, LayoutDirection::Down),
        Some(3)
    );
    assert_eq!(
        directional_neighbor(&3, &placements, LayoutDirection::Up),
        Some(2)
    );
    assert_eq!(
        directional_neighbor(&2, &placements, LayoutDirection::Left),
        Some(1)
    );
}

fn keyboard_resize(
    layout: &mut dyn WindowLayout<u64>,
    window: u64,
    work_area: Rectangle<i32, Logical>,
    gap: i32,
    axis: LayoutAxis,
    change: LayoutSizeChange,
) -> bool {
    layout.resize_from_keyboard(LayoutKeyboardResizeRequest {
        window,
        work_area,
        gap,
        axis,
        change,
    })
}

#[test]
fn dwindle_keyboard_resize_grows_the_focused_side_on_both_axes() {
    let area = rect(-1000, 40, 1000, 600);
    for (window, axis, delta, expected) in [
        (
            1,
            LayoutAxis::Horizontal,
            100.0,
            vec![
                rect(-1000, 40, 600, 600),
                rect(-400, 40, 400, 300),
                rect(-400, 340, 400, 300),
            ],
        ),
        (
            2,
            LayoutAxis::Horizontal,
            100.0,
            vec![
                rect(-1000, 40, 400, 600),
                rect(-600, 40, 600, 300),
                rect(-600, 340, 600, 300),
            ],
        ),
        (
            2,
            LayoutAxis::Vertical,
            60.0,
            vec![
                rect(-1000, 40, 500, 600),
                rect(-500, 40, 500, 360),
                rect(-500, 400, 500, 240),
            ],
        ),
        (
            3,
            LayoutAxis::Vertical,
            60.0,
            vec![
                rect(-1000, 40, 500, 600),
                rect(-500, 40, 500, 240),
                rect(-500, 280, 500, 360),
            ],
        ),
    ] {
        let mut layout = DwindleLayout::<u64>::default();
        for id in 1..=3 {
            layout.insert(LayoutInsertion {
                window: id,
                space: OUTPUT,
                anchor: (id > 1).then_some(id - 1),
            });
        }
        layout.insert(LayoutInsertion {
            window: 4,
            space: SECOND_WORKSPACE,
            anchor: None,
        });
        let before = layout.arrange(OUTPUT, area, 0);
        assert!(keyboard_resize(
            &mut layout,
            window,
            area,
            0,
            axis,
            LayoutSizeChange::Adjust(delta)
        ));
        assert_eq!(
            layout
                .arrange(OUTPUT, area, 0)
                .iter()
                .map(|p| p.geometry)
                .collect::<Vec<_>>(),
            expected
        );
        assert_eq!(layout.arrange(SECOND_WORKSPACE, area, 0)[0].geometry, area);
        assert!(keyboard_resize(
            &mut layout,
            window,
            area,
            0,
            axis,
            LayoutSizeChange::Adjust(-delta)
        ));
        assert_eq!(layout.arrange(OUTPUT, area, 0), before);
    }
}

#[test]
fn dwindle_keyboard_resize_uses_actual_constrained_sizes_and_stops_at_nearest_split() {
    let mut layout = DwindleLayout::<u64>::default();
    let area = rect(0, 0, 1000, 600);
    layout.roots.insert(
        OUTPUT,
        DwindleNode::Split {
            axis: Some(LayoutAxis::Horizontal),
            ratio: 0.5,
            first: Box::new(DwindleNode::Window(1)),
            second: Box::new(DwindleNode::Split {
                axis: Some(LayoutAxis::Horizontal),
                ratio: 0.5,
                first: Box::new(DwindleNode::Window(2)),
                second: Box::new(DwindleNode::Window(3)),
            }),
        },
    );
    layout.update_minimum_size(&2, Size::from((300, 1)));
    layout.update_minimum_size(&3, Size::from((100, 1)));
    // The inner 500px split starts at 300/200 due to the client minimum.
    assert!(!keyboard_resize(
        &mut layout,
        2,
        area,
        0,
        LayoutAxis::Horizontal,
        LayoutSizeChange::Adjust(-50.0)
    ));
    assert!(keyboard_resize(
        &mut layout,
        2,
        area,
        0,
        LayoutAxis::Horizontal,
        LayoutSizeChange::Adjust(50.0)
    ));
    let placements = layout.arrange(OUTPUT, area, 0);
    assert_eq!(placements[0].geometry.size.w, 500);
    assert_eq!(placements[1].geometry.size.w, 350);
    assert_eq!(placements[2].geometry.size.w, 150);
    assert!(keyboard_resize(
        &mut layout,
        2,
        area,
        0,
        LayoutAxis::Horizontal,
        LayoutSizeChange::Adjust(500.0)
    ));
    let limited = layout.arrange(OUTPUT, area, 0);
    assert_eq!(limited[1].geometry.size.w, 400);
    assert_eq!(limited[2].geometry.size.w, 100);
    assert!(!keyboard_resize(
        &mut layout,
        2,
        area,
        0,
        LayoutAxis::Horizontal,
        LayoutSizeChange::Adjust(50.0)
    ));
    assert_eq!(layout.arrange(OUTPUT, area, 0), limited);
    assert!(keyboard_resize(
        &mut layout,
        2,
        area,
        0,
        LayoutAxis::Horizontal,
        LayoutSizeChange::Adjust(-50.0)
    ));
    assert_eq!(layout.arrange(OUTPUT, area, 0), placements);
}

#[test]
fn scrolling_keyboard_resize_changes_only_selected_extent_on_either_strip_axis() {
    for axis in [LayoutAxis::Horizontal, LayoutAxis::Vertical] {
        let mut layout = ScrollingLayout::<u64>::default();
        let area = rect(1000, 40, 1000, 1000);
        for window in 1..=2 {
            layout.insert(LayoutInsertion {
                window,
                space: OUTPUT,
                anchor: None,
            });
        }
        prepare_scrolling(&mut layout, area, 10, axis);
        assert!(keyboard_resize(
            &mut layout,
            1,
            area,
            10,
            axis,
            LayoutSizeChange::Adjust(-100.0)
        ));
        prepare_scrolling(&mut layout, area, 10, axis);
        let sizes = |layout: &ScrollingLayout<u64>| {
            layout
                .arrange(OUTPUT, area, 10)
                .iter()
                .map(|p| axis.main_extent(p.geometry))
                .collect::<Vec<_>>()
        };
        assert_eq!(sizes(&layout), vec![500, 600]);
        assert!(keyboard_resize(
            &mut layout,
            1,
            area,
            10,
            axis,
            LayoutSizeChange::Adjust(100.0)
        ));
        assert_eq!(sizes(&layout), vec![600, 600]);
        let cross = if axis == LayoutAxis::Horizontal {
            LayoutAxis::Vertical
        } else {
            LayoutAxis::Horizontal
        };
        assert!(keyboard_resize(
            &mut layout,
            1,
            area,
            10,
            cross,
            LayoutSizeChange::Adjust(-100.0)
        ));
        assert!(layout.set_maximized(&1, true));
        assert!(!keyboard_resize(
            &mut layout,
            1,
            area,
            10,
            axis,
            LayoutSizeChange::Adjust(-100.0)
        ));
    }
}

#[test]
fn scrolling_keyboard_resize_respects_minima_without_accumulating_hidden_steps() {
    let mut layout = ScrollingLayout::<u64>::default();
    let area = rect(0, 0, 1000, 600);
    layout.insert(LayoutInsertion {
        window: 1,
        space: OUTPUT,
        anchor: None,
    });
    layout.update_minimum_size(&1, Size::from((800, 1)));
    prepare_scrolling(&mut layout, area, 10, LayoutAxis::Horizontal);
    assert!(!keyboard_resize(
        &mut layout,
        1,
        area,
        10,
        LayoutAxis::Horizontal,
        LayoutSizeChange::Adjust(-100.0)
    ));
    assert!(keyboard_resize(
        &mut layout,
        1,
        area,
        10,
        LayoutAxis::Horizontal,
        LayoutSizeChange::Adjust(100.0)
    ));
    assert_eq!(layout.arrange(OUTPUT, area, 10)[0].geometry.size.w, 900);
    assert!(keyboard_resize(
        &mut layout,
        1,
        area,
        10,
        LayoutAxis::Horizontal,
        LayoutSizeChange::Adjust(1000.0)
    ));
    assert_eq!(layout.arrange(OUTPUT, area, 10)[0].geometry.size.w, 1000);
    assert!(!keyboard_resize(
        &mut layout,
        1,
        area,
        10,
        LayoutAxis::Horizontal,
        LayoutSizeChange::Adjust(100.0)
    ));
}

#[test]
fn scrolling_keyboard_resize_prefers_internal_splits_and_reset_equalizes_height() {
    let area = rect(0, 0, 1000, 600);
    for (direction, axis) in [
        (LayoutDirection::Down, LayoutAxis::Vertical),
        (LayoutDirection::Right, LayoutAxis::Horizontal),
    ] {
        let mut layout = ScrollingLayout::<u64>::default();
        for window in 1..=2 {
            layout.insert(LayoutInsertion {
                window,
                space: OUTPUT,
                anchor: None,
            });
        }
        prepare_scrolling(&mut layout, area, 10, LayoutAxis::Horizontal);
        assert!(layout.move_beside(&1, &2, direction));
        prepare_scrolling(&mut layout, area, 10, LayoutAxis::Horizontal);
        let before = layout.arrange(OUTPUT, area, 10);
        assert!(keyboard_resize(
            &mut layout,
            1,
            area,
            10,
            axis,
            LayoutSizeChange::Adjust(60.0)
        ));
        let after = layout.arrange(OUTPUT, area, 10);
        assert_eq!(axis.main_extent(after[0].geometry), 235);
        assert_eq!(axis.main_extent(after[1].geometry), 355);
        assert_eq!(
            layout.rows[&OUTPUT].columns[0].width_fraction,
            DEFAULT_SCROLLING_COLUMN_FRACTION
        );
        assert!(keyboard_resize(
            &mut layout,
            1,
            area,
            10,
            axis,
            LayoutSizeChange::Reset
        ));
        assert_eq!(layout.arrange(OUTPUT, area, 10), before);
        assert!(!keyboard_resize(
            &mut layout,
            1,
            area,
            10,
            axis,
            LayoutSizeChange::Reset
        ));
    }
}

#[test]
fn keyboard_height_reset_restores_split_or_vertical_scrolling_default() {
    let area = rect(0, 0, 600, 1000);
    let mut layout = DwindleLayout::<u64>::default();
    for window in 1..=2 {
        layout.insert(LayoutInsertion {
            window,
            space: OUTPUT,
            anchor: None,
        });
    }
    let before = layout.arrange(OUTPUT, area, 10);
    assert!(keyboard_resize(
        &mut layout,
        2,
        area,
        10,
        LayoutAxis::Vertical,
        LayoutSizeChange::Adjust(100.0)
    ));
    assert!(keyboard_resize(
        &mut layout,
        2,
        area,
        10,
        LayoutAxis::Vertical,
        LayoutSizeChange::Reset
    ));
    assert_eq!(layout.arrange(OUTPUT, area, 10), before);
    let mut scrolling = ScrollingLayout::<u64>::default();
    scrolling.insert(LayoutInsertion {
        window: 1,
        space: OUTPUT,
        anchor: None,
    });
    prepare_scrolling(&mut scrolling, area, 10, LayoutAxis::Vertical);
    assert!(keyboard_resize(
        &mut scrolling,
        1,
        area,
        10,
        LayoutAxis::Vertical,
        LayoutSizeChange::Adjust(100.0)
    ));
    assert!(keyboard_resize(
        &mut scrolling,
        1,
        area,
        10,
        LayoutAxis::Vertical,
        LayoutSizeChange::Reset
    ));
    assert_eq!(scrolling.arrange(OUTPUT, area, 10)[0].geometry.size.h, 600);
    assert!(!keyboard_resize(
        &mut scrolling,
        1,
        area,
        10,
        LayoutAxis::Vertical,
        LayoutSizeChange::Reset
    ));
    for delta in [f64::NAN, f64::INFINITY, 0.0] {
        assert!(!keyboard_resize(
            &mut scrolling,
            1,
            area,
            10,
            LayoutAxis::Vertical,
            LayoutSizeChange::Adjust(delta)
        ));
    }
    assert!(!keyboard_resize(
        &mut scrolling,
        99,
        area,
        10,
        LayoutAxis::Vertical,
        LayoutSizeChange::Adjust(100.0)
    ));
}

#[test]
fn dwindle_resizes_the_nearest_matching_split() {
    let mut layout = DwindleLayout::<u64>::default();
    for window in 1..=3 {
        layout.insert(LayoutInsertion {
            window,
            space: OUTPUT,
            anchor: (window > 1).then_some(window - 1),
        });
    }

    assert!(layout.resize(LayoutResizeRequest {
        window: 2,
        work_area: rect(0, 0, 1000, 600),
        gap: 0,
        delta_x: 0.0,
        delta_y: 60.0,
        edges: LayoutResizeEdges {
            bottom: true,
            ..LayoutResizeEdges::default()
        },
    }));
    assert_eq!(
        layout.arrange(OUTPUT, rect(0, 0, 1000, 600), 0),
        vec![
            LayoutPlacement {
                window: 1,
                geometry: rect(0, 0, 500, 600),
            },
            LayoutPlacement {
                window: 2,
                geometry: rect(500, 0, 500, 360),
            },
            LayoutPlacement {
                window: 3,
                geometry: rect(500, 360, 500, 240),
            },
        ]
    );
}

#[test]
fn scrolling_column_width_respects_the_window_minimum() {
    let mut layout = ScrollingLayout::<u64>::default();
    let work_area = rect(0, 0, 1000, 600);
    layout.insert(LayoutInsertion {
        window: 1,
        space: OUTPUT,
        anchor: None,
    });
    assert!(layout.update_minimum_size(&1, Size::from((800, 700))));
    prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);

    let placement = layout.arrange(OUTPUT, work_area, 10).remove(0);
    assert_eq!(placement.geometry.size, Size::from((800, 700)));
}

#[test]
fn scrolling_cross_axis_drop_splits_only_the_target_tile() {
    let mut layout = ScrollingLayout::<u64>::default();
    let work_area = rect(0, 0, 1000, 600);
    for window in 1..=3 {
        layout.insert(LayoutInsertion {
            window,
            space: OUTPUT,
            anchor: (window > 1).then_some(window - 1),
        });
        prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    }

    assert!(layout.move_beside(&1, &3, LayoutDirection::Up));
    prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    let row = &layout.rows[&OUTPUT];
    assert_eq!(row.columns.len(), 2);
    assert_eq!(row.columns[1].root.window_ids(), vec![1, 3]);

    let placements = layout.arrange(OUTPUT, work_area, 10);
    let moved = placements
        .iter()
        .find(|placement| placement.window == 1)
        .expect("moved tile remains arranged")
        .geometry;
    let target = placements
        .iter()
        .find(|placement| placement.window == 3)
        .expect("target tile remains arranged")
        .geometry;
    assert_eq!(moved.size.h, 295);
    assert_eq!(target.size.h, 295);
    assert_eq!(moved.loc.x, target.loc.x);
    assert_eq!(moved.size.w, target.size.w);
    assert_eq!(moved.loc.y.saturating_add(moved.size.h + 10), target.loc.y);
}

#[test]
fn scrolling_repeated_cross_axis_drops_split_only_the_target_branch() {
    let mut layout = ScrollingLayout::<u64>::default();
    let work_area = rect(0, 0, 1000, 600);
    for window in 1..=3 {
        layout.insert(LayoutInsertion {
            window,
            space: OUTPUT,
            anchor: (window > 1).then_some(window - 1),
        });
        prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    }

    assert!(layout.move_beside(&1, &2, LayoutDirection::Down));
    assert!(layout.move_beside(&3, &2, LayoutDirection::Down));
    prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    let column = &layout.rows[&OUTPUT].columns[0];
    assert_eq!(column.root.window_ids(), vec![2, 3, 1]);
    let placements = layout.arrange(OUTPUT, work_area, 10);
    let heights = [2, 3, 1].map(|window| {
        placements
            .iter()
            .find(|placement| placement.window == window)
            .expect("stacked tile remains arranged")
            .geometry
            .size
            .h
    });
    assert_eq!(heights, [143, 142, 295]);
}

#[test]
fn scrolling_right_drop_splits_the_target_inside_its_column() {
    let mut layout = ScrollingLayout::<u64>::default();
    let work_area = rect(0, 0, 1000, 600);
    for window in 1..=3 {
        layout.insert(LayoutInsertion {
            window,
            space: OUTPUT,
            anchor: (window > 1).then_some(window - 1),
        });
        prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    }

    assert!(layout.move_beside(&1, &2, LayoutDirection::Down));
    assert!(layout.move_beside(&1, &3, LayoutDirection::Right));
    prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    let row = &layout.rows[&OUTPUT];
    assert_eq!(row.columns.len(), 2);
    assert_eq!(row.columns[0].root.window_ids(), vec![2]);
    assert_eq!(row.columns[1].root.window_ids(), vec![3, 1]);

    let placements = layout.arrange(OUTPUT, work_area, 10);
    let target = placements
        .iter()
        .find(|placement| placement.window == 3)
        .expect("target tile remains arranged")
        .geometry;
    let moved = placements
        .iter()
        .find(|placement| placement.window == 1)
        .expect("moved tile remains arranged")
        .geometry;
    assert_eq!(target.size, Size::from((295, 600)));
    assert_eq!(moved.size, Size::from((295, 600)));
    assert_eq!(target.loc.y, moved.loc.y);
    assert_eq!(target.loc.x.saturating_add(target.size.w + 10), moved.loc.x);
}

#[test]
fn scrolling_column_gap_targets_follow_the_strip_axis() {
    for axis in [LayoutAxis::Horizontal, LayoutAxis::Vertical] {
        let mut layout = ScrollingLayout::<u64>::default();
        let work_area = rect(-1200, 40, 1000, 1000);
        for window in 1..=3 {
            layout.insert(LayoutInsertion {
                window,
                space: OUTPUT,
                anchor: None,
            });
            prepare_scrolling(&mut layout, work_area, 10, axis);
        }
        let cross_direction = match axis {
            LayoutAxis::Horizontal => LayoutDirection::Down,
            LayoutAxis::Vertical => LayoutDirection::Right,
        };
        assert!(layout.move_beside(&1, &2, cross_direction));
        layout.activate(&3);
        prepare_scrolling(&mut layout, work_area, 10, axis);
        let placements = layout.arrange(OUTPUT, work_area, 10);
        let target = placements.iter().find(|p| p.window == 3).unwrap().geometry;
        let gap_point = match axis {
            LayoutAxis::Horizontal => Point::from((target.loc.x - 5, work_area.loc.y + 500)),
            LayoutAxis::Vertical => Point::from((work_area.loc.x + 500, target.loc.y - 5)),
        };
        assert_eq!(
            layout.column_insertion_target(OUTPUT, &1, work_area, 10, gap_point),
            Some((3, true))
        );
        // The anchor must never be the dragged window itself.
        assert_eq!(
            layout.column_insertion_target(OUTPUT, &3, work_area, 10, gap_point),
            Some((2, false))
        );
        assert_eq!(
            layout.column_insertion_target(SECOND_OUTPUT, &1, work_area, 10, gap_point),
            None
        );
        assert_eq!(
            layout.column_insertion_target(OUTPUT, &1, work_area, 0, gap_point),
            None
        );
        assert_eq!(
            layout.column_insertion_target(OUTPUT, &1, work_area, 10, target.loc),
            None
        );
        let first = placements.iter().find(|p| p.window == 2).unwrap().geometry;
        let internal_gap = match axis {
            LayoutAxis::Horizontal => Point::from((
                first.loc.x + first.size.w / 2,
                first.loc.y + first.size.h + 5,
            )),
            LayoutAxis::Vertical => Point::from((
                first.loc.x + first.size.w + 5,
                first.loc.y + first.size.h / 2,
            )),
        };
        assert_eq!(
            layout.column_insertion_target(OUTPUT, &3, work_area, 10, internal_gap),
            None
        );
    }
}

#[test]
fn scrolling_column_drop_extracts_a_leaf_and_preview_matches_commit() {
    for axis in [LayoutAxis::Horizontal, LayoutAxis::Vertical] {
        for before in [false, true] {
            let mut layout = ScrollingLayout::<u64>::default();
            let work_area = rect(100, 40, 1000, 1000);
            for window in 1..=3 {
                layout.insert(LayoutInsertion {
                    window,
                    space: OUTPUT,
                    anchor: None,
                });
                prepare_scrolling(&mut layout, work_area, 10, axis);
            }
            assert!(layout.move_beside(
                &1,
                &2,
                match axis {
                    LayoutAxis::Horizontal => LayoutDirection::Down,
                    LayoutAxis::Vertical => LayoutDirection::Right,
                }
            ));
            layout.update_minimum_size(&1, Size::from((350, 350)));
            let original = layout.arrange(OUTPUT, work_area, 10);
            let mut preview = layout.snapshot();
            assert!(preview.move_to_column(&1, &3, before));
            preview.activate(&1);
            preview.prepare_arrange(OUTPUT, work_area, 10, axis);
            assert_eq!(layout.arrange(OUTPUT, work_area, 10), original);
            assert!(layout.move_to_column(&1, &3, before));
            layout.activate(&1);
            prepare_scrolling(&mut layout, work_area, 10, axis);
            assert_eq!(
                preview.arrange(OUTPUT, work_area, 10),
                layout.arrange(OUTPUT, work_area, 10)
            );
            let row = &layout.rows[&OUTPUT];
            assert_eq!(
                row.columns
                    .iter()
                    .map(|c| c.root.window_ids())
                    .collect::<Vec<_>>(),
                if before {
                    vec![vec![2], vec![1], vec![3]]
                } else {
                    vec![vec![2], vec![3], vec![1]]
                }
            );
            assert!(
                layout
                    .minimum_sizes
                    .iter()
                    .any(|(id, size)| *id == 1 && *size == Size::from((350, 350)))
            );
            assert!(!layout.move_to_column(&1, &3, before));
            assert!(!layout.move_to_column(&1, &1, before));
            assert!(!layout.move_to_column(&99, &1, before));
            assert!(!layout.move_to_column(&1, &99, before));
        }
    }
}

#[test]
fn scrolling_column_drop_reorders_columns_and_moves_between_spaces() {
    let mut layout = ScrollingLayout::<u64>::default();
    for window in 1..=3 {
        layout.insert(LayoutInsertion {
            window,
            space: OUTPUT,
            anchor: None,
        });
    }
    layout.rows.get_mut(&OUTPUT).unwrap().columns[0].width_fraction = 0.4;
    assert!(layout.move_to_column(&1, &3, false));
    assert_eq!(
        layout.rows[&OUTPUT]
            .columns
            .iter()
            .map(|c| c.active)
            .collect::<Vec<_>>(),
        vec![2, 3, 1]
    );
    assert_eq!(layout.rows[&OUTPUT].columns[2].width_fraction, 0.4);
    assert!(layout.move_to_column(&1, &2, true));
    assert_eq!(
        layout.rows[&OUTPUT]
            .columns
            .iter()
            .map(|c| c.active)
            .collect::<Vec<_>>(),
        vec![1, 2, 3]
    );
    layout.insert(LayoutInsertion {
        window: 4,
        space: SECOND_OUTPUT,
        anchor: None,
    });
    assert!(layout.move_to_column(&4, &2, true));
    assert!(!layout.rows.contains_key(&SECOND_OUTPUT));
    assert_eq!(layout.space_for(&4), Some(OUTPUT));
    assert_eq!(
        layout.rows[&OUTPUT]
            .columns
            .iter()
            .map(|c| c.active)
            .collect::<Vec<_>>(),
        vec![1, 4, 2, 3]
    );
}

#[test]
fn scrolling_drop_preview_keeps_the_hovered_column_under_the_pointer() {
    let mut layout = ScrollingLayout::<u64>::default();
    let work_area = rect(0, 0, 1000, 600);
    for window in 1..=3 {
        layout.insert(LayoutInsertion {
            window,
            space: OUTPUT,
            anchor: (window > 1).then_some(window - 1),
        });
        prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    }
    assert!(layout.activate(&1));
    prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    let before = layout.arrange(OUTPUT, work_area, 10);
    let before_target = before
        .iter()
        .find(|placement| placement.window == 2)
        .expect("hovered tile starts arranged")
        .geometry;
    let before_sibling = before
        .iter()
        .find(|placement| placement.window == 3)
        .expect("following column starts arranged")
        .geometry;

    assert!(layout.move_beside_for_preview(
        &1,
        &2,
        LayoutDirection::Right,
        work_area,
        10,
        LayoutAxis::Horizontal,
    ));
    layout.activate(&1);
    prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    let preview = layout.arrange(OUTPUT, work_area, 10);
    let preview_target = preview
        .iter()
        .find(|placement| placement.window == 2)
        .expect("hovered tile remains arranged")
        .geometry;
    let preview_sibling = preview
        .iter()
        .find(|placement| placement.window == 3)
        .expect("following column remains arranged")
        .geometry;

    assert_eq!(preview_target.loc, before_target.loc);
    assert_eq!(preview_sibling, before_sibling);
    assert_eq!(preview_target.size, Size::from((295, 600)));
    assert!(layout.rows[&OUTPUT].preview_view_locked);
    assert_eq!(layout.rows[&OUTPUT].view_start, Some(-610.0));
}

#[test]
fn scrolling_right_drop_splits_a_tile_inside_an_existing_stack() {
    let mut layout = ScrollingLayout::<u64>::default();
    let work_area = rect(0, 0, 1000, 600);
    for window in 1..=3 {
        layout.insert(LayoutInsertion {
            window,
            space: OUTPUT,
            anchor: (window > 1).then_some(window - 1),
        });
        prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    }

    assert!(layout.move_beside(&1, &2, LayoutDirection::Down));
    assert!(layout.move_beside(&3, &2, LayoutDirection::Right));
    prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);

    let row = &layout.rows[&OUTPUT];
    assert_eq!(row.columns.len(), 1);
    assert_eq!(row.columns[0].root.window_ids(), vec![2, 3, 1]);
    let placements = layout.arrange(OUTPUT, work_area, 10);
    let geometry = |window| {
        placements
            .iter()
            .find(|placement| placement.window == window)
            .expect("nested scrolling tile remains arranged")
            .geometry
    };
    let target = geometry(2);
    let moved = geometry(3);
    let sibling = geometry(1);
    assert_eq!(target.size, Size::from((295, 295)));
    assert_eq!(moved.size, Size::from((295, 295)));
    assert_eq!(sibling.size, Size::from((600, 295)));
    assert_eq!(target.loc.x.saturating_add(target.size.w + 10), moved.loc.x);
    assert_eq!(target.loc.y, moved.loc.y);
    assert_eq!(
        target.loc.y.saturating_add(target.size.h + 10),
        sibling.loc.y
    );
}

#[test]
fn scrolling_horizontal_split_resize_moves_only_the_internal_boundary() {
    let mut layout = ScrollingLayout::<u64>::default();
    let work_area = rect(0, 0, 1000, 600);
    for window in 1..=2 {
        layout.insert(LayoutInsertion {
            window,
            space: OUTPUT,
            anchor: (window > 1).then_some(window - 1),
        });
        prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    }
    assert!(layout.move_beside(&1, &2, LayoutDirection::Right));
    prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    let width_fraction = layout.rows[&OUTPUT].columns[0].width_fraction;

    assert!(layout.resize(LayoutResizeRequest {
        window: 2,
        work_area,
        gap: 10,
        delta_x: 60.0,
        delta_y: 0.0,
        edges: LayoutResizeEdges {
            right: true,
            ..LayoutResizeEdges::default()
        },
    }));
    assert_eq!(
        layout.rows[&OUTPUT].columns[0].width_fraction,
        width_fraction,
    );
    let placements = layout.arrange(OUTPUT, work_area, 10);
    assert_eq!(placements[0].window, 2);
    assert_eq!(placements[0].geometry.size.w, 355);
    assert_eq!(placements[1].window, 1);
    assert_eq!(placements[1].geometry.size.w, 235);
}

fn lone_scrolling(axis: LayoutAxis) -> (ScrollingLayout<u64>, Rectangle<i32, Logical>) {
    let mut layout = ScrollingLayout::<u64>::default();
    let area = rect(100, 40, 1000, 600);
    layout.insert(LayoutInsertion {
        window: 1,
        space: OUTPUT,
        anchor: None,
    });
    prepare_scrolling(&mut layout, area, 10, axis);
    (layout, area)
}

#[test]
fn scrolling_lone_cross_resize_is_fixed_leading_aligned_and_resettable() {
    for axis in [LayoutAxis::Horizontal, LayoutAxis::Vertical] {
        let (mut layout, area) = lone_scrolling(axis);
        let cross = ScrollingColumn::<u64>::cross_axis(axis);
        let full = layout.arrange(OUTPUT, area, 10)[0].geometry;
        assert!(keyboard_resize(
            &mut layout,
            1,
            area,
            10,
            cross,
            LayoutSizeChange::Adjust(-150.0)
        ));
        let reduced = layout.arrange(OUTPUT, area, 10)[0].geometry;
        assert_eq!(reduced.loc, full.loc);
        assert_eq!(axis.main_extent(reduced), axis.main_extent(full));
        assert_eq!(cross.main_extent(reduced), cross.main_extent(full) - 150);
        let larger_area = rect(100, 40, 1500, 900);
        prepare_scrolling(&mut layout, larger_area, 10, axis);
        assert_eq!(
            cross.main_extent(layout.arrange(OUTPUT, larger_area, 10)[0].geometry),
            cross.main_extent(reduced)
        );
        assert!(keyboard_resize(
            &mut layout,
            1,
            larger_area,
            10,
            cross,
            LayoutSizeChange::Reset
        ));
        assert_eq!(
            cross.main_extent(layout.arrange(OUTPUT, larger_area, 10)[0].geometry),
            cross.main_extent(larger_area)
        );
        assert!(!keyboard_resize(
            &mut layout,
            1,
            larger_area,
            10,
            cross,
            LayoutSizeChange::Reset
        ));
    }
}

#[test]
fn scrolling_lone_pointer_cross_resize_accepts_only_trailing_edge() {
    for axis in [LayoutAxis::Horizontal, LayoutAxis::Vertical] {
        let (mut layout, area) = lone_scrolling(axis);
        let cross = ScrollingColumn::<u64>::cross_axis(axis);
        let original = layout.arrange(OUTPUT, area, 10);
        let mut request = LayoutResizeRequest {
            window: 1,
            work_area: area,
            gap: 10,
            delta_x: -120.0,
            delta_y: -120.0,
            edges: if axis == LayoutAxis::Horizontal {
                LayoutResizeEdges {
                    top: true,
                    ..Default::default()
                }
            } else {
                LayoutResizeEdges {
                    left: true,
                    ..Default::default()
                }
            },
        };
        assert!(!layout.resize(request.clone()));
        assert_eq!(layout.arrange(OUTPUT, area, 10), original);
        request.edges = if axis == LayoutAxis::Horizontal {
            LayoutResizeEdges {
                bottom: true,
                ..Default::default()
            }
        } else {
            LayoutResizeEdges {
                right: true,
                ..Default::default()
            }
        };
        assert!(layout.resize(request));
        let resized = layout.arrange(OUTPUT, area, 10)[0].geometry;
        assert_eq!(resized.loc, original[0].geometry.loc);
        assert_eq!(
            cross.main_extent(resized),
            cross.main_extent(original[0].geometry) - 120
        );
    }
}

#[test]
fn scrolling_lone_cross_constraints_bound_geometry_and_do_not_hide_steps() {
    for axis in [LayoutAxis::Horizontal, LayoutAxis::Vertical] {
        let (mut layout, area) = lone_scrolling(axis);
        let cross = ScrollingColumn::<u64>::cross_axis(axis);
        let size = |extent| {
            if axis == LayoutAxis::Horizontal {
                Size::from((1, extent))
            } else {
                Size::from((extent, 1))
            }
        };
        layout.update_minimum_size(&1, size(200));
        layout.update_maximum_size(&1, size(400));
        assert_eq!(
            cross.main_extent(layout.arrange(OUTPUT, area, 10)[0].geometry),
            400
        );
        assert!(keyboard_resize(
            &mut layout,
            1,
            area,
            10,
            cross,
            LayoutSizeChange::Adjust(-10000.0)
        ));
        assert_eq!(
            cross.main_extent(layout.arrange(OUTPUT, area, 10)[0].geometry),
            200
        );
        assert!(!keyboard_resize(
            &mut layout,
            1,
            area,
            10,
            cross,
            LayoutSizeChange::Adjust(-10000.0)
        ));
        assert!(keyboard_resize(
            &mut layout,
            1,
            area,
            10,
            cross,
            LayoutSizeChange::Adjust(20.0)
        ));
        assert_eq!(
            cross.main_extent(layout.arrange(OUTPUT, area, 10)[0].geometry),
            220
        );
        for delta in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, 0.0] {
            assert!(!keyboard_resize(
                &mut layout,
                1,
                area,
                10,
                cross,
                LayoutSizeChange::Adjust(delta)
            ));
        }
        assert!(layout.resize(LayoutResizeRequest {
            window: 1,
            work_area: area,
            gap: 10,
            delta_x: 10000.0,
            delta_y: 10000.0,
            edges: if axis == LayoutAxis::Horizontal {
                LayoutResizeEdges {
                    bottom: true,
                    ..Default::default()
                }
            } else {
                LayoutResizeEdges {
                    right: true,
                    ..Default::default()
                }
            },
        }));
        assert_eq!(
            cross.main_extent(layout.arrange(OUTPUT, area, 10)[0].geometry),
            400
        );
        assert_eq!(layout.rows[&OUTPUT].columns[0].cross_extent, Some(400));
        layout.update_maximum_size(&1, size(100)); // Conflicting hints: minimum wins.
        assert_eq!(
            cross.main_extent(layout.arrange(OUTPUT, area, 10)[0].geometry),
            200
        );
        layout.update_minimum_size(&1, size(2000)); // Impossible work-area minimum.
        assert_eq!(
            cross.main_extent(layout.arrange(OUTPUT, area, 10)[0].geometry),
            2000
        );
    }
}

#[cfg(feature = "flutter")]
#[test]
fn scrolling_keyboard_width_reset_clears_rotated_cross_size_without_remapping_height_reset() {
    use super::super::keyboard_resize::{KeyboardResize, ResizeStep};
    let (mut layout, area) = lone_scrolling(LayoutAxis::Vertical);
    assert!(keyboard_resize(
        &mut layout,
        1,
        area,
        10,
        LayoutAxis::Horizontal,
        LayoutSizeChange::Adjust(-150.0)
    ));
    assert!(keyboard_resize(
        &mut layout,
        1,
        area,
        10,
        LayoutAxis::Vertical,
        LayoutSizeChange::Adjust(-60.0)
    ));
    let (axis, change) = KeyboardResize::ResetHeight.layout_change(area, ResizeStep::default());
    assert!(keyboard_resize(&mut layout, 1, area, 10, axis, change));
    assert_eq!(
        layout.arrange(OUTPUT, area, 10)[0].geometry.size,
        Size::from((850, 360))
    );
    let (axis, change) = KeyboardResize::ResetWidth.layout_change(area, ResizeStep::default());
    assert!(keyboard_resize(&mut layout, 1, area, 10, axis, change));
    assert_eq!(
        layout.arrange(OUTPUT, area, 10)[0].geometry.size,
        Size::from((1000, 360))
    );
    assert!(!keyboard_resize(&mut layout, 1, area, 10, axis, change));
}

#[test]
fn scrolling_lone_cross_extent_rotates_and_maximize_restores_it() {
    let (mut layout, area) = lone_scrolling(LayoutAxis::Horizontal);
    assert!(keyboard_resize(
        &mut layout,
        1,
        area,
        10,
        LayoutAxis::Vertical,
        LayoutSizeChange::Adjust(-150.0)
    ));
    let reduced = layout.arrange(OUTPUT, area, 10);
    let preview = layout.snapshot();
    assert!(layout.set_maximized(&1, true));
    assert_eq!(layout.arrange(OUTPUT, area, 10)[0].geometry, area);
    assert!(!keyboard_resize(
        &mut layout,
        1,
        area,
        10,
        LayoutAxis::Vertical,
        LayoutSizeChange::Reset
    ));
    assert!(layout.set_maximized(&1, false));
    prepare_scrolling(&mut layout, area, 10, LayoutAxis::Horizontal);
    assert_eq!(layout.arrange(OUTPUT, area, 10), reduced);
    assert_eq!(preview.arrange(OUTPUT, area, 10), reduced);
    prepare_scrolling(&mut layout, area, 10, LayoutAxis::Vertical);
    assert_eq!(layout.arrange(OUTPUT, area, 10)[0].geometry.size.w, 450);
    prepare_scrolling(
        &mut layout,
        rect(100, 40, 300, 600),
        10,
        LayoutAxis::Vertical,
    );
    assert_eq!(
        layout.arrange(OUTPUT, rect(100, 40, 300, 600), 10)[0]
            .geometry
            .size
            .w,
        300
    );
    prepare_scrolling(&mut layout, area, 10, LayoutAxis::Vertical);
    assert_eq!(layout.arrange(OUTPUT, area, 10)[0].geometry.size.w, 450);
}

#[test]
fn scrolling_lone_group_and_ungroup_clear_overrides_but_keep_shared_boundary_resize() {
    let (mut layout, area) = lone_scrolling(LayoutAxis::Horizontal);
    layout.insert(LayoutInsertion {
        window: 2,
        space: OUTPUT,
        anchor: None,
    });
    prepare_scrolling(&mut layout, area, 10, LayoutAxis::Horizontal);
    for window in [1, 2] {
        assert!(keyboard_resize(
            &mut layout,
            window,
            area,
            10,
            LayoutAxis::Vertical,
            LayoutSizeChange::Adjust(-150.0)
        ));
    }
    assert!(layout.move_beside(&2, &1, LayoutDirection::Down));
    assert_eq!(layout.arrange(OUTPUT, area, 10)[0].geometry.size.h, 295);
    assert!(keyboard_resize(
        &mut layout,
        1,
        area,
        10,
        LayoutAxis::Vertical,
        LayoutSizeChange::Adjust(60.0)
    ));
    let grouped = layout.arrange(OUTPUT, area, 10);
    assert_eq!(grouped[0].geometry.size.h, 355);
    assert_eq!(grouped[1].geometry.size.h, 235);
    assert!(layout.move_to_column(&2, &1, false));
    assert!(
        layout
            .arrange(OUTPUT, area, 10)
            .iter()
            .all(|p| p.geometry.size.h == 600)
    );
    assert!(layout.move_beside(&2, &1, LayoutDirection::Right));
    assert!(layout.remove(&2));
    assert_eq!(layout.arrange(OUTPUT, area, 10)[0].geometry.size.h, 600);
}

#[test]
fn scrolling_lone_reorder_and_rebuild_preserve_override_but_workspace_move_resets() {
    let (mut layout, area) = lone_scrolling(LayoutAxis::Horizontal);
    for window in [2, 3] {
        layout.insert(LayoutInsertion {
            window,
            space: OUTPUT,
            anchor: None,
        });
    }
    prepare_scrolling(&mut layout, area, 10, LayoutAxis::Horizontal);
    assert!(keyboard_resize(
        &mut layout,
        1,
        area,
        10,
        LayoutAxis::Vertical,
        LayoutSizeChange::Adjust(-150.0)
    ));
    assert!(layout.move_to_column(&1, &3, false));
    let height = |layout: &ScrollingLayout<u64>, space| {
        layout
            .arrange(space, area, 10)
            .into_iter()
            .find(|p| p.window == 1)
            .unwrap()
            .geometry
            .size
            .h
    };
    assert_eq!(height(&layout, OUTPUT), 450);
    layout.rebuild(
        [1, 2, 3]
            .into_iter()
            .map(|window| LayoutInsertion {
                window,
                space: OUTPUT,
                anchor: None,
            })
            .collect(),
    );
    assert_eq!(height(&layout, OUTPUT), 450);
    assert!(!layout.move_to_space(&1, OUTPUT));
    assert_eq!(height(&layout, OUTPUT), 450);
    assert!(layout.move_to_space(&1, SECOND_OUTPUT));
    layout.prepare_arrange(SECOND_OUTPUT, area, 10, LayoutAxis::Horizontal);
    assert_eq!(height(&layout, SECOND_OUTPUT), 600);
    assert!(layout.remove(&1));
    layout.insert(LayoutInsertion {
        window: 1,
        space: SECOND_OUTPUT,
        anchor: None,
    });
    assert_eq!(height(&layout, SECOND_OUTPUT), 600);
}

#[test]
fn scrolling_cross_axis_resize_moves_only_the_shared_boundary() {
    let mut layout = ScrollingLayout::<u64>::default();
    let work_area = rect(0, 0, 1000, 600);
    for window in 1..=2 {
        layout.insert(LayoutInsertion {
            window,
            space: OUTPUT,
            anchor: (window > 1).then_some(window - 1),
        });
        prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    }
    assert!(layout.move_beside(&1, &2, LayoutDirection::Down));
    prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);

    assert!(layout.resize(LayoutResizeRequest {
        window: 2,
        work_area,
        gap: 10,
        delta_x: 0.0,
        delta_y: 60.0,
        edges: LayoutResizeEdges {
            bottom: true,
            ..LayoutResizeEdges::default()
        },
    }));
    let placements = layout.arrange(OUTPUT, work_area, 10);
    assert_eq!(placements[0].window, 2);
    assert_eq!(placements[0].geometry.size.h, 355);
    assert_eq!(placements[1].window, 1);
    assert_eq!(placements[1].geometry.size.h, 235);
}

#[test]
fn scrolling_rotated_strip_stacks_on_the_physical_cross_axis() {
    let mut layout = ScrollingLayout::<u64>::default();
    let work_area = rect(100, 20, 600, 1000);
    for window in 1..=2 {
        layout.insert(LayoutInsertion {
            window,
            space: OUTPUT,
            anchor: (window > 1).then_some(window - 1),
        });
        prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Vertical);
    }

    assert!(layout.move_beside(&1, &2, LayoutDirection::Left));
    prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Vertical);
    let placements = layout.arrange(OUTPUT, work_area, 10);
    assert_eq!(layout.rows[&OUTPUT].columns.len(), 1);
    assert_eq!(placements[0].window, 1);
    assert_eq!(placements[1].window, 2);
    assert_eq!(placements[0].geometry.size.w, 295);
    assert_eq!(placements[1].geometry.size.w, 295);
    assert_eq!(placements[0].geometry.loc.y, placements[1].geometry.loc.y);
}

#[test]
fn scrolling_rebuild_preserves_multi_window_columns() {
    let mut layout = ScrollingLayout::<u64>::default();
    layout.insert(LayoutInsertion {
        window: 1,
        space: OUTPUT,
        anchor: None,
    });
    layout.insert(LayoutInsertion {
        window: 2,
        space: OUTPUT,
        anchor: Some(1),
    });
    assert!(layout.move_beside(&1, &2, LayoutDirection::Down));

    layout.rebuild(vec![
        LayoutInsertion {
            window: 1,
            space: OUTPUT,
            anchor: None,
        },
        LayoutInsertion {
            window: 2,
            space: OUTPUT,
            anchor: Some(1),
        },
    ]);
    let row = &layout.rows[&OUTPUT];
    assert_eq!(row.columns.len(), 1);
    assert_eq!(row.columns[0].root.window_ids(), vec![2, 1]);
}

#[test]
fn scrolling_stack_preserves_impossible_cross_axis_minimums() {
    let mut layout = ScrollingLayout::<u64>::default();
    let work_area = rect(0, 0, 1000, 600);
    layout.insert(LayoutInsertion {
        window: 1,
        space: OUTPUT,
        anchor: None,
    });
    layout.insert(LayoutInsertion {
        window: 2,
        space: OUTPUT,
        anchor: Some(1),
    });
    assert!(layout.update_minimum_size(&1, Size::from((1, 400))));
    assert!(layout.update_minimum_size(&2, Size::from((1, 300))));
    prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);

    assert!(layout.move_beside(&1, &2, LayoutDirection::Down));
    prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    let placements = layout.arrange(OUTPUT, work_area, 10);
    assert_eq!(placements[0].window, 2);
    assert_eq!(placements[0].geometry.size.h, 300);
    assert_eq!(placements[1].window, 1);
    assert_eq!(placements[1].geometry.size.h, 400);
}

#[test]
fn scrolling_cross_space_stack_preserves_source_and_minimum_metadata() {
    let mut layout = ScrollingLayout::<u64>::default();
    let work_area = rect(0, 0, 1000, 600);
    layout.insert(LayoutInsertion {
        window: 1,
        space: OUTPUT,
        anchor: None,
    });
    layout.insert(LayoutInsertion {
        window: 2,
        space: OUTPUT,
        anchor: Some(1),
    });
    layout.insert(LayoutInsertion {
        window: 3,
        space: SECOND_OUTPUT,
        anchor: None,
    });
    assert!(layout.update_minimum_size(&1, Size::from((320, 240))));
    prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    layout.prepare_arrange(SECOND_OUTPUT, work_area, 10, LayoutAxis::Horizontal);
    assert!(layout.move_beside(&1, &2, LayoutDirection::Down));

    assert!(layout.move_beside(&1, &3, LayoutDirection::Down));
    assert_eq!(layout.space_for(&1), Some(SECOND_OUTPUT));
    assert_eq!(layout.rows[&OUTPUT].columns[0].root.window_ids(), vec![2]);
    assert_eq!(
        layout.rows[&SECOND_OUTPUT].columns[0].root.window_ids(),
        vec![3, 1],
    );
    assert_eq!(
        layout_minimum_size(&layout.minimum_sizes, &1),
        Size::from((320, 240)),
    );
}

#[test]
fn scrolling_true_maximize_stays_in_strip_and_restores_the_view() {
    let mut layout = ScrollingLayout::<u64>::default();
    let work_area = rect(10, 30, 980, 560);
    let maximize_area = rect(0, 20, 1000, 580);
    for window in 1..=3 {
        layout.insert(LayoutInsertion {
            window,
            space: OUTPUT,
            anchor: (window > 1).then_some(window - 1),
        });
        layout.set_maximize_area(OUTPUT, maximize_area);
        prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    }
    assert!(layout.activate(&2));
    prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);

    assert!(layout.set_maximized(&2, true));
    prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    assert_eq!(
        layout.arrange(OUTPUT, work_area, 10),
        vec![
            LayoutPlacement {
                window: 1,
                geometry: rect(-598, 30, 588, 560),
            },
            LayoutPlacement {
                window: 2,
                geometry: maximize_area,
            },
            LayoutPlacement {
                window: 3,
                geometry: rect(1010, 30, 588, 560),
            },
        ]
    );

    assert!(layout.set_maximized(&2, false));
    prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    let restored = layout.arrange(OUTPUT, work_area, 10);
    assert_eq!(restored[1].geometry, rect(10, 30, 588, 560));
}

#[test]
fn scrolling_true_maximize_extracts_a_window_from_a_stack() {
    let mut layout = ScrollingLayout::<u64>::default();
    let work_area = rect(0, 0, 1000, 600);
    for window in 1..=2 {
        layout.insert(LayoutInsertion {
            window,
            space: OUTPUT,
            anchor: (window > 1).then_some(window - 1),
        });
        prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    }
    assert!(layout.move_beside(&1, &2, LayoutDirection::Down));
    assert_eq!(layout.rows[&OUTPUT].columns.len(), 1);

    assert!(layout.set_maximized(&1, true));
    let row = &layout.rows[&OUTPUT];
    assert_eq!(row.columns.len(), 2);
    assert_eq!(row.columns[0].root.window_ids(), vec![2]);
    assert_eq!(row.columns[1].root.window_ids(), vec![1]);
    assert!(row.columns[1].maximized);
}

#[test]
fn scrolling_reveals_inserted_and_activated_tiles_with_minimum_viewport_motion() {
    let mut layout = ScrollingLayout::<u64>::default();
    let work_area = rect(100, 20, 1000, 600);
    for window in 1..=3 {
        layout.insert(LayoutInsertion {
            window,
            space: OUTPUT,
            anchor: (window > 1).then_some(window - 1),
        });
        prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    }

    assert_eq!(
        layout.arrange(OUTPUT, work_area, 10),
        vec![
            LayoutPlacement {
                window: 1,
                geometry: rect(-720, 20, 600, 600),
            },
            LayoutPlacement {
                window: 2,
                geometry: rect(-110, 20, 600, 600),
            },
            LayoutPlacement {
                window: 3,
                geometry: rect(500, 20, 600, 600),
            },
        ]
    );

    assert!(layout.activate(&2));
    prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    assert_eq!(
        layout.arrange(OUTPUT, work_area, 10),
        vec![
            LayoutPlacement {
                window: 1,
                geometry: rect(-510, 20, 600, 600),
            },
            LayoutPlacement {
                window: 2,
                geometry: rect(100, 20, 600, 600),
            },
            LayoutPlacement {
                window: 3,
                geometry: rect(710, 20, 600, 600),
            },
        ]
    );

    layout.rebuild(
        (1..=3)
            .rev()
            .map(|window| LayoutInsertion {
                window,
                space: OUTPUT,
                anchor: (window < 3).then_some(window + 1),
            })
            .collect(),
    );
    prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    assert_eq!(
        layout.arrange(OUTPUT, work_area, 10),
        vec![
            LayoutPlacement {
                window: 1,
                geometry: rect(-510, 20, 600, 600),
            },
            LayoutPlacement {
                window: 2,
                geometry: rect(100, 20, 600, 600),
            },
            LayoutPlacement {
                window: 3,
                geometry: rect(710, 20, 600, 600),
            },
        ]
    );
}

#[test]
fn scrolling_swaps_preserve_independent_tile_sizes_when_enabled() {
    for axis in [LayoutAxis::Horizontal, LayoutAxis::Vertical] {
        for preserve_sizes in [false, true] {
            for (first, second) in [(1, 2), (2, 1)] {
                let mut layout = ScrollingLayout::<u64>::default();
                let work_area = rect(0, 0, 1000, 1000);
                for window in 1..=2 {
                    layout.insert(LayoutInsertion {
                        window,
                        space: OUTPUT,
                        anchor: (window > 1).then_some(window - 1),
                    });
                    prepare_scrolling(&mut layout, work_area, 10, axis);
                }
                assert!(layout.resize(LayoutResizeRequest {
                    window: 1,
                    work_area,
                    gap: 10,
                    delta_x: 100.0,
                    delta_y: 100.0,
                    edges: LayoutResizeEdges {
                        right: axis == LayoutAxis::Horizontal,
                        bottom: axis == LayoutAxis::Vertical,
                        ..LayoutResizeEdges::default()
                    },
                }));
                let before = layout.arrange(OUTPUT, work_area, 10);
                assert_ne!(before[0].geometry.size, before[1].geometry.size);
                // Preview and commit must use the same size policy.
                let mut preview = layout.snapshot();
                assert!(preview.swap(&first, &second, preserve_sizes));
                assert!(layout.swap(&first, &second, preserve_sizes));
                preview.activate(&first);
                layout.activate(&first);
                let after = layout.arrange(OUTPUT, work_area, 10);
                assert_eq!(preview.arrange(OUTPUT, work_area, 10), after);
                assert_eq!(after[0].window, 2);
                assert_eq!(after[1].window, 1);
                for (index, placement) in after.iter().enumerate() {
                    let original = if preserve_sizes { 1 - index } else { index };
                    assert_eq!(placement.geometry.size, before[original].geometry.size);
                }
                let focused = after.iter().find(|p| p.window == first).unwrap().geometry;
                assert!(work_area.contains_rect(focused));
                assert!(!layout.swap(&first, &first, preserve_sizes));
                assert!(!layout.swap(&first, &99, preserve_sizes));
                assert_eq!(layout.arrange(OUTPUT, work_area, 10), after);
            }
        }
    }
}

#[test]
fn scrolling_swaps_involving_split_columns_retain_slot_sizes() {
    let mut layout = ScrollingLayout::<u64>::default();
    let work_area = rect(0, 0, 1000, 600);
    for window in 1..=3 {
        layout.insert(LayoutInsertion {
            window,
            space: OUTPUT,
            anchor: (window > 1).then_some(window - 1),
        });
        prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    }
    assert!(layout.move_beside(&1, &3, LayoutDirection::Up));
    assert!(layout.resize(LayoutResizeRequest {
        window: 2,
        work_area,
        gap: 10,
        delta_x: 100.0,
        delta_y: 0.0,
        edges: LayoutResizeEdges {
            right: true,
            ..LayoutResizeEdges::default()
        },
    }));
    for (first, second) in [(1, 3), (1, 2)] {
        let mut preserve = layout.snapshot();
        let mut slots = layout.snapshot();
        assert!(preserve.swap(&first, &second, true));
        assert!(slots.swap(&first, &second, false));
        assert_eq!(
            preserve.arrange(OUTPUT, work_area, 10),
            slots.arrange(OUTPUT, work_area, 10)
        );
    }
}

#[test]
fn scrolling_cross_space_swap_keeps_active_ids_in_their_rows() {
    let mut layout = ScrollingLayout::<u64>::default();
    layout.insert(LayoutInsertion {
        window: 1,
        space: OUTPUT,
        anchor: None,
    });
    layout.insert(LayoutInsertion {
        window: 2,
        space: SECOND_OUTPUT,
        anchor: None,
    });

    assert!(layout.swap(&1, &2, true));
    assert_eq!(layout.space_for(&1), Some(SECOND_OUTPUT));
    assert_eq!(layout.space_for(&2), Some(OUTPUT));
    for row in layout.rows.values() {
        assert!(
            row.active
                .as_ref()
                .is_some_and(|active| row.position(active).is_some())
        );
    }
    assert!(layout.activate(&1) || layout.rows[&SECOND_OUTPUT].active == Some(1));
    assert_eq!(layout.rows[&SECOND_OUTPUT].active, Some(1));
}

#[test]
fn scrolling_navigation_keeps_every_tile_inside_once_their_existing_sizes_fit() {
    let mut layout = ScrollingLayout::<u64>::default();
    let work_area = rect(0, 0, 1000, 600);
    for window in 1..=2 {
        layout.insert(LayoutInsertion {
            window,
            space: OUTPUT,
            anchor: (window > 1).then_some(window - 1),
        });
        prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    }
    for window in 1..=2 {
        assert!(layout.resize(LayoutResizeRequest {
            window,
            work_area,
            gap: 10,
            delta_x: -200.0,
            delta_y: 0.0,
            edges: LayoutResizeEdges {
                right: true,
                ..LayoutResizeEdges::default()
            },
        }));
        prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    }

    // Resizing retains the opposite border even at the strip boundary.
    // Navigation can then bring the whole strip back into the viewport.
    layout.activate(&2);
    prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    assert_eq!(
        layout.arrange(OUTPUT, work_area, 10),
        vec![
            LayoutPlacement {
                window: 1,
                geometry: rect(0, 0, 400, 600),
            },
            LayoutPlacement {
                window: 2,
                geometry: rect(410, 0, 400, 600),
            },
        ]
    );
}

#[test]
fn scrolling_uses_full_width_tiles_on_a_vertical_axis() {
    let mut layout = ScrollingLayout::<u64>::default();
    let work_area = rect(100, 20, 600, 1000);
    for window in 1..=3 {
        layout.insert(LayoutInsertion {
            window,
            space: OUTPUT,
            anchor: (window > 1).then_some(window - 1),
        });
        prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Vertical);
    }

    assert_eq!(
        layout.arrange(OUTPUT, work_area, 10),
        vec![
            LayoutPlacement {
                window: 1,
                geometry: rect(100, -800, 600, 600),
            },
            LayoutPlacement {
                window: 2,
                geometry: rect(100, -190, 600, 600),
            },
            LayoutPlacement {
                window: 3,
                geometry: rect(100, 420, 600, 600),
            },
        ]
    );
}

#[test]
fn scrolling_resize_changes_only_the_selected_column_width() {
    let mut layout = ScrollingLayout::<u64>::default();
    let work_area = rect(0, 0, 1000, 600);
    for window in 1..=2 {
        layout.insert(LayoutInsertion {
            window,
            space: OUTPUT,
            anchor: (window > 1).then_some(window - 1),
        });
        prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    }

    assert!(layout.resize(LayoutResizeRequest {
        window: 2,
        work_area,
        gap: 10,
        delta_x: 100.0,
        delta_y: 0.0,
        edges: LayoutResizeEdges {
            right: true,
            ..LayoutResizeEdges::default()
        },
    }));
    prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    assert_eq!(
        layout.arrange(OUTPUT, work_area, 10),
        vec![
            LayoutPlacement {
                window: 1,
                geometry: rect(-210, 0, 600, 600),
            },
            LayoutPlacement {
                window: 2,
                geometry: rect(400, 0, 700, 600),
            },
        ]
    );

    layout.rebuild(vec![
        LayoutInsertion {
            window: 2,
            space: OUTPUT,
            anchor: None,
        },
        LayoutInsertion {
            window: 1,
            space: OUTPUT,
            anchor: Some(2),
        },
    ]);
    prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    assert_eq!(
        layout.arrange(OUTPUT, work_area, 10),
        vec![
            LayoutPlacement {
                window: 1,
                geometry: rect(-310, 0, 600, 600),
            },
            LayoutPlacement {
                window: 2,
                geometry: rect(300, 0, 700, 600),
            },
        ]
    );
}

#[test]
fn scrolling_pointer_resize_keeps_the_opposite_border_fixed() {
    for axis in [LayoutAxis::Horizontal, LayoutAxis::Vertical] {
        for count in [1, 3] {
            for window in 1..=count {
                for leading in [false, true] {
                    let mut layout = ScrollingLayout::<u64>::default();
                    let work_area = rect(-1200, 40, 1000, 1000);
                    for id in 1..=count {
                        layout.insert(LayoutInsertion {
                            window: id,
                            space: OUTPUT,
                            anchor: None,
                        });
                        prepare_scrolling(&mut layout, work_area, 10, axis);
                    }
                    layout.activate(&window);
                    prepare_scrolling(&mut layout, work_area, 10, axis);
                    let geometry = |layout: &ScrollingLayout<u64>| {
                        layout
                            .arrange(OUTPUT, work_area, 10)
                            .into_iter()
                            .find(|p| p.window == window)
                            .unwrap()
                            .geometry
                    };
                    let initial = geometry(&layout);
                    // Grow, reverse, and hit both size limits. Arrangement
                    // passes between pointer events must retain the anchor.
                    for delta in [100.0, -200.0, 1000.0, -1000.0, 50.0] {
                        let before = geometry(&layout);
                        layout.resize(LayoutResizeRequest {
                            window,
                            work_area,
                            gap: 10,
                            delta_x: delta,
                            delta_y: delta,
                            edges: LayoutResizeEdges {
                                left: axis == LayoutAxis::Horizontal && leading,
                                right: axis == LayoutAxis::Horizontal && !leading,
                                top: axis == LayoutAxis::Vertical && leading,
                                bottom: axis == LayoutAxis::Vertical && !leading,
                            },
                        });
                        for _ in 0..3 {
                            prepare_scrolling(&mut layout, work_area, 10, axis);
                            let after = geometry(&layout);
                            let fixed = |r| {
                                axis.main_location(r)
                                    + if leading { axis.main_extent(r) } else { 0 }
                            };
                            assert_eq!(
                                fixed(after),
                                fixed(initial),
                                "axis={axis:?}, count={count}, window={window}, leading={leading}, delta={delta}"
                            );
                            let expected_extent = (f64::from(axis.main_extent(before))
                                + if leading { -delta } else { delta })
                            .clamp(250.0, 1000.0)
                                as i32;
                            assert_eq!(axis.main_extent(after), expected_extent);
                            match axis {
                                LayoutAxis::Horizontal => {
                                    assert_eq!(after.loc.y, initial.loc.y);
                                    assert_eq!(after.size.h, initial.size.h);
                                }
                                LayoutAxis::Vertical => {
                                    assert_eq!(after.loc.x, initial.loc.x);
                                    assert_eq!(after.size.w, initial.size.w);
                                }
                            }
                        }
                    }
                    // Explicit focus navigation restores the normal reveal policy.
                    layout.activate(&window);
                    prepare_scrolling(&mut layout, work_area, 10, axis);
                    assert!(work_area.contains_rect(geometry(&layout)));
                }
            }
        }
    }
}

#[test]
fn scrolling_pointer_resize_anchors_the_leaf_in_a_split_column() {
    for axis in [LayoutAxis::Horizontal, LayoutAxis::Vertical] {
        for leading in [false, true] {
            let mut layout = ScrollingLayout::<u64>::default();
            let work_area = rect(100, 40, 1000, 1000);
            for window in 1..=2 {
                layout.insert(LayoutInsertion {
                    window,
                    space: OUTPUT,
                    anchor: None,
                });
            }
            let direction = match (axis, leading) {
                (LayoutAxis::Horizontal, true) => LayoutDirection::Left,
                (LayoutAxis::Horizontal, false) => LayoutDirection::Right,
                (LayoutAxis::Vertical, true) => LayoutDirection::Up,
                (LayoutAxis::Vertical, false) => LayoutDirection::Down,
            };
            assert!(layout.move_beside(&1, &2, direction));
            prepare_scrolling(&mut layout, work_area, 10, axis);
            let geometry = |layout: &ScrollingLayout<u64>| {
                layout
                    .arrange(OUTPUT, work_area, 10)
                    .into_iter()
                    .find(|p| p.window == 1)
                    .unwrap()
                    .geometry
            };
            let before = geometry(&layout);
            assert!(layout.resize(LayoutResizeRequest {
                window: 1,
                work_area,
                gap: 10,
                delta_x: 100.0,
                delta_y: 100.0,
                edges: LayoutResizeEdges {
                    left: axis == LayoutAxis::Horizontal && leading,
                    right: axis == LayoutAxis::Horizontal && !leading,
                    top: axis == LayoutAxis::Vertical && leading,
                    bottom: axis == LayoutAxis::Vertical && !leading,
                },
            }));
            prepare_scrolling(&mut layout, work_area, 10, axis);
            let after = geometry(&layout);
            let fixed = |r| axis.main_location(r) + if leading { axis.main_extent(r) } else { 0 };
            assert_eq!(fixed(after), fixed(before));
            assert_ne!(axis.main_extent(after), axis.main_extent(before));
        }
    }
}

#[test]
fn scrolling_leading_edge_resize_inverts_delta_on_the_strip_axis() {
    let mut horizontal = ScrollingLayout::<u64>::default();
    let horizontal_area = rect(0, 0, 1000, 600);
    horizontal.insert(LayoutInsertion {
        window: 1,
        space: OUTPUT,
        anchor: None,
    });
    prepare_scrolling(&mut horizontal, horizontal_area, 10, LayoutAxis::Horizontal);
    assert!(horizontal.resize(LayoutResizeRequest {
        window: 1,
        work_area: horizontal_area,
        gap: 10,
        delta_x: 100.0,
        delta_y: 500.0,
        edges: LayoutResizeEdges {
            left: true,
            ..LayoutResizeEdges::default()
        },
    }));
    assert_eq!(
        horizontal.arrange(OUTPUT, horizontal_area, 10)[0]
            .geometry
            .size,
        Size::from((500, 600)),
    );

    let mut vertical = ScrollingLayout::<u64>::default();
    let vertical_area = rect(0, 0, 600, 1000);
    vertical.insert(LayoutInsertion {
        window: 1,
        space: OUTPUT,
        anchor: None,
    });
    prepare_scrolling(&mut vertical, vertical_area, 10, LayoutAxis::Vertical);
    assert!(vertical.resize(LayoutResizeRequest {
        window: 1,
        work_area: vertical_area,
        gap: 10,
        delta_x: 500.0,
        delta_y: 100.0,
        edges: LayoutResizeEdges {
            top: true,
            ..LayoutResizeEdges::default()
        },
    }));
    assert_eq!(
        vertical.arrange(OUTPUT, vertical_area, 10)[0].geometry.size,
        Size::from((600, 500)),
    );
}

#[test]
fn scrolling_gesture_tracks_motion_and_settles_to_nearest_column() {
    let mut layout = ScrollingLayout::<u64>::default();
    let work_area = rect(0, 0, 1000, 600);
    for window in 1..=3 {
        layout.insert(LayoutInsertion {
            window,
            space: OUTPUT,
            anchor: (window > 1).then_some(window - 1),
        });
        prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    }
    assert!(layout.activate(&2));

    assert!(layout.scroll_horizontally(OUTPUT, work_area, 10, LayoutAxis::Horizontal, -400.0,));
    assert_eq!(
        layout.arrange(OUTPUT, rect(0, 0, 1000, 600), 10),
        vec![
            LayoutPlacement {
                window: 1,
                geometry: rect(-820, 0, 600, 600),
            },
            LayoutPlacement {
                window: 2,
                geometry: rect(-210, 0, 600, 600),
            },
            LayoutPlacement {
                window: 3,
                geometry: rect(400, 0, 600, 600),
            },
        ]
    );
    assert_eq!(
        layout
            .finish_horizontal_scroll(OUTPUT, work_area, 10, LayoutAxis::Horizontal, false, None,),
        Some(3)
    );
    assert_eq!(
        layout.arrange(OUTPUT, rect(0, 0, 1000, 600), 10),
        vec![
            LayoutPlacement {
                window: 1,
                geometry: rect(-820, 0, 600, 600),
            },
            LayoutPlacement {
                window: 2,
                geometry: rect(-210, 0, 600, 600),
            },
            LayoutPlacement {
                window: 3,
                geometry: rect(400, 0, 600, 600),
            },
        ]
    );
}

#[test]
fn removing_another_outputs_scrolling_row_preserves_the_surviving_view() {
    let mut layout = ScrollingLayout::<u64>::default();
    let work_area = rect(0, 0, 1000, 600);
    for window in 1..=3 {
        layout.insert(LayoutInsertion {
            window,
            space: OUTPUT,
            anchor: (window > 1).then_some(window - 1),
        });
        prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    }
    assert!(layout.activate(&2));
    assert!(layout.scroll_horizontally(OUTPUT, work_area, 10, LayoutAxis::Horizontal, -400.0,));
    assert_eq!(
        layout
            .finish_horizontal_scroll(OUTPUT, work_area, 10, LayoutAxis::Horizontal, false, None,),
        Some(3),
    );
    let surviving_before = layout.arrange(OUTPUT, work_area, 10);
    let view_before = layout.rows[&OUTPUT].view_start;

    for window in 10..=11 {
        layout.insert(LayoutInsertion {
            window,
            space: SECOND_OUTPUT,
            anchor: (window > 10).then_some(window - 1),
        });
        layout.prepare_arrange(SECOND_OUTPUT, work_area, 10, LayoutAxis::Horizontal);
    }
    assert!(layout.remove(&10));
    assert!(layout.remove(&11));

    assert_eq!(layout.arrange(OUTPUT, work_area, 10), surviving_before);
    assert_eq!(layout.rows[&OUTPUT].view_start, view_before);
}

#[test]
fn scrolling_flick_is_capped_to_one_column_despite_high_velocity() {
    let mut layout = ScrollingLayout::<u64>::default();
    let work_area = rect(0, 0, 1000, 600);
    for window in 1..=7 {
        layout.insert(LayoutInsertion {
            window,
            space: OUTPUT,
            anchor: (window > 1).then_some(window - 1),
        });
        prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    }
    assert!(layout.activate(&4));

    // The tracked distance alone is below the nearest-column threshold,
    // while an intentionally extreme release projection crosses several.
    assert!(layout.scroll_horizontally(OUTPUT, work_area, 10, LayoutAxis::Horizontal, -100.0,));
    assert_eq!(
        layout.finish_horizontal_scroll(
            OUTPUT,
            work_area,
            10,
            LayoutAxis::Horizontal,
            false,
            Some(-10_000.0),
        ),
        Some(5)
    );
}

#[test]
fn continued_scrolling_settles_by_travel_without_extra_fling() {
    let mut layout = ScrollingLayout::<u64>::default();
    let work_area = rect(0, 0, 1000, 600);
    for window in 1..=5 {
        layout.insert(LayoutInsertion {
            window,
            space: OUTPUT,
            anchor: (window > 1).then_some(window - 1),
        });
        prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    }
    assert!(layout.activate(&2));

    assert!(layout.scroll_horizontally(OUTPUT, work_area, 10, LayoutAxis::Horizontal, -1_300.0,));
    assert_eq!(
        layout.finish_horizontal_scroll(
            OUTPUT,
            work_area,
            10,
            LayoutAxis::Horizontal,
            false,
            Some(-10_000.0),
        ),
        Some(4)
    );
}

#[test]
fn cancelled_scrolling_gesture_returns_to_original_column() {
    let mut layout = ScrollingLayout::<u64>::default();
    let work_area = rect(0, 0, 1000, 600);
    for window in 1..=2 {
        layout.insert(LayoutInsertion {
            window,
            space: OUTPUT,
            anchor: (window > 1).then_some(window - 1),
        });
        prepare_scrolling(&mut layout, work_area, 10, LayoutAxis::Horizontal);
    }

    assert!(layout.scroll_horizontally(OUTPUT, work_area, 10, LayoutAxis::Horizontal, 250.0,));
    assert_eq!(
        layout.finish_horizontal_scroll(OUTPUT, work_area, 10, LayoutAxis::Horizontal, true, None,),
        Some(2)
    );
    assert_eq!(
        layout.arrange(OUTPUT, rect(0, 0, 1000, 600), 10),
        vec![
            LayoutPlacement {
                window: 1,
                geometry: rect(-210, 0, 600, 600),
            },
            LayoutPlacement {
                window: 2,
                geometry: rect(400, 0, 600, 600),
            },
        ]
    );
}

#[test]
fn scrolling_removal_returns_focus_to_the_left_neighbor() {
    let mut layout = ScrollingLayout::<u64>::default();
    let work_area = rect(0, 0, 1000, 600);
    for window in 1..=3 {
        layout.insert(LayoutInsertion {
            window,
            space: OUTPUT,
            anchor: (window > 1).then_some(window - 1),
        });
        prepare_scrolling(&mut layout, work_area, 0, LayoutAxis::Horizontal);
    }

    assert!(layout.remove(&3));
    prepare_scrolling(&mut layout, work_area, 0, LayoutAxis::Horizontal);
    assert_eq!(
        layout.arrange(OUTPUT, rect(0, 0, 1000, 600), 0),
        vec![
            LayoutPlacement {
                window: 1,
                geometry: rect(-200, 0, 600, 600),
            },
            LayoutPlacement {
                window: 2,
                geometry: rect(400, 0, 600, 600),
            },
        ]
    );
}
