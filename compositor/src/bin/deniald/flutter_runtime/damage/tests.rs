use super::*;

fn covers(rect: &sys::FlutterRect, x: f64, y: f64) -> bool {
    rect.left <= x && x < rect.right && rect.top <= y && y < rect.bottom
}

fn assert_covers_expected(region: &DamageRegion, expected: &[bool], width: usize, height: usize) {
    let mut actual = Vec::new();
    region.write_flutter(&mut actual);
    for rect in &actual {
        assert!(rect.left >= 0.0 && rect.top >= 0.0);
        assert!(rect.right <= width as f64 && rect.bottom <= height as f64);
    }
    for y in 0..height {
        for x in 0..width {
            if expected[y * width + x] {
                assert!(
                    actual
                        .iter()
                        .any(|rect| covers(rect, x as f64 + 0.5, y as f64 + 0.5)),
                    "damage did not cover ({x}, {y}): {actual:?}"
                );
            }
        }
    }
}

#[test]
fn clipping_and_bounded_coalescing_are_conservative() {
    const WIDTH: usize = 17;
    const HEIGHT: usize = 13;
    let mut inputs = Vec::new();
    let mut expected = vec![false; WIDTH * HEIGHT];

    // Deterministic property-like corpus: negative coordinates, rectangles
    // crossing every edge, overlaps and enough islands to hit the cap.
    for index in 0..96_i32 {
        let left = (index * 37 % 29) - 8;
        let top = (index * 19 % 23) - 6;
        let right = left + 1 + (index * 11 % 7);
        let bottom = top + 1 + (index * 5 % 6);
        inputs.push(sys::FlutterRect {
            left: f64::from(left),
            top: f64::from(top),
            right: f64::from(right),
            bottom: f64::from(bottom),
        });
        for y in 0..HEIGHT {
            for x in 0..WIDTH {
                if left <= x as i32 && (x as i32) < right && top <= y as i32 && (y as i32) < bottom
                {
                    expected[y * WIDTH + x] = true;
                }
            }
        }
    }

    let region = DamageRegion::from_flutter(WIDTH as u32, HEIGHT as u32, &inputs);
    assert_covers_expected(&region, &expected, WIDTH, HEIGHT);

    let islands = (0..=MAX_DAMAGE_RECTS)
        .map(|index| {
            let left = (index % 11) as f64 * 3.0;
            let top = (index / 11) as f64 * 3.0;
            sys::FlutterRect {
                left,
                top,
                right: left + 1.0,
                bottom: top + 1.0,
            }
        })
        .collect::<Vec<_>>();
    let bounded = DamageRegion::from_flutter(40, 20, &islands);
    let mut bounded_rects = Vec::new();
    bounded.write_flutter(&mut bounded_rects);
    assert_eq!(bounded_rects.len(), MAX_DAMAGE_RECTS);
    assert!(!bounded.is_full());
    assert_eq!(bounded.damaged_area(), 35.0);
    assert!(!bounded.intersects_pixel_rect(4, 0, 1, 1));

    let invalid = DamageRegion::from_flutter(
        WIDTH as u32,
        HEIGHT as u32,
        &[sys::FlutterRect {
            left: f64::NAN,
            top: 0.0,
            right: 1.0,
            bottom: 1.0,
        }],
    );
    let mut invalid_rects = Vec::new();
    invalid.write_flutter(&mut invalid_rects);
    assert_eq!(invalid_rects.len(), 1);
    assert_eq!(invalid_rects[0].right, WIDTH as f64);
    assert_eq!(invalid_rects[0].bottom, HEIGHT as f64);
}

#[test]
fn audit_summary_uses_the_normalized_damage_region() {
    let region = DamageRegion::from_flutter(
        100,
        80,
        &[
            sys::FlutterRect {
                left: 10.0,
                top: 12.0,
                right: 30.0,
                bottom: 32.0,
            },
            sys::FlutterRect {
                left: 30.0,
                top: 12.0,
                right: 50.0,
                bottom: 32.0,
            },
        ],
    );

    expect_damage_summary(&region, 1, 800.0, "10,12-50,32");
    assert!(!region.is_full());
    assert!(!region.is_empty());
}

#[test]
fn touching_l_shape_does_not_fill_its_bounding_box() {
    let region = DamageRegion::from_flutter(
        100,
        80,
        &[
            sys::FlutterRect {
                left: 0.0,
                top: 0.0,
                right: 40.0,
                bottom: 80.0,
            },
            sys::FlutterRect {
                left: 40.0,
                top: 0.0,
                right: 100.0,
                bottom: 30.0,
            },
            sys::FlutterRect {
                left: 40.0,
                top: 50.0,
                right: 100.0,
                bottom: 80.0,
            },
        ],
    );

    assert_eq!(region.rect_count(), 3);
    assert!(!region.is_full());
    assert!(region.intersects_pixel_rect(5, 35, 1, 1));
    assert!(!region.intersects_pixel_rect(50, 35, 1, 1));
}

#[test]
fn complex_frame_region_stays_partial_when_added_to_buffer_history() {
    let frame = DamageRegion::from_flutter(
        100,
        80,
        &[
            sys::FlutterRect {
                left: 0.0,
                top: 0.0,
                right: 40.0,
                bottom: 80.0,
            },
            sys::FlutterRect {
                left: 40.0,
                top: 0.0,
                right: 100.0,
                bottom: 30.0,
            },
            sys::FlutterRect {
                left: 40.0,
                top: 50.0,
                right: 100.0,
                bottom: 80.0,
            },
        ],
    );
    let mut history = DamageRegion::empty(100, 80);

    history.union(&frame);

    assert_eq!(history.rect_count(), 3);
    assert!(!history.is_full());
    assert!(!history.intersects_pixel_rect(50, 35, 1, 1));
}

#[test]
fn identical_and_rectangular_neighbors_coalesce_without_growth() {
    let mut region = DamageRegion::from_flutter(
        100,
        80,
        &[
            sys::FlutterRect {
                left: 10.0,
                top: 12.0,
                right: 30.0,
                bottom: 32.0,
            },
            sys::FlutterRect {
                left: 30.0,
                top: 12.0,
                right: 50.0,
                bottom: 32.0,
            },
        ],
    );
    let identical = region.clone();

    for _ in 0..100 {
        region.union(&identical);
    }

    expect_damage_summary(&region, 1, 800.0, "10,12-50,32");
}

fn expect_damage_summary(region: &DamageRegion, rect_count: usize, area: f64, description: &str) {
    assert_eq!(region.rect_count(), rect_count);
    assert_eq!(region.damaged_area(), area);
    assert_eq!(region.compact_description(), description);
}

#[test]
fn cross_generation_union_degrades_to_full_local_damage() {
    let mut current = DamageRegion::from_flutter(
        20,
        10,
        &[sys::FlutterRect {
            left: 1.0,
            top: 1.0,
            right: 2.0,
            bottom: 2.0,
        }],
    );
    let stale_generation = DamageRegion::from_flutter(
        30,
        15,
        &[sys::FlutterRect {
            left: 25.0,
            top: 12.0,
            right: 29.0,
            bottom: 14.0,
        }],
    );

    current.union(&stale_generation);
    let mut output = Vec::new();
    current.write_flutter(&mut output);
    assert_eq!(output.len(), 1);
    assert_eq!(output[0].left, 0.0);
    assert_eq!(output[0].top, 0.0);
    assert_eq!(output[0].right, 20.0);
    assert_eq!(output[0].bottom, 10.0);
}
