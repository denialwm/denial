use super::*;

#[test]
fn clips_logical_regions_and_projects_both_atlas_and_scanout_edges() {
    let target = project_capture_region(
        OutputId(7),
        Rectangle::new((100, 200).into(), (3840, 2160).into()),
        (1920, 1080).into(),
        (1920, 1080).into(),
        Some(Rectangle::new((-100, 100).into(), (1060, 540).into())),
        Transform::Normal,
        false,
    )
    .unwrap();

    assert_eq!(
        target.source,
        Rectangle::new((100, 400).into(), (1920, 1080).into())
    );
    assert_eq!(target.size, (960, 540).into());
}

#[test]
fn rejects_empty_or_fully_clipped_capture_regions() {
    let source = Rectangle::new((0, 0).into(), (1920, 1080).into());
    let scanout = Size::from((1920, 1080));
    let logical = Size::from((1920, 1080));
    assert!(
        project_capture_region(
            OutputId(1),
            source,
            scanout,
            logical,
            Some(Rectangle::new((50, 50).into(), (0, 100).into())),
            Transform::Normal,
            false,
        )
        .is_none()
    );
    assert!(
        project_capture_region(
            OutputId(1),
            source,
            scanout,
            logical,
            Some(Rectangle::new((2000, 0).into(), (100, 100).into())),
            Transform::Normal,
            false,
        )
        .is_none()
    );
}

#[test]
fn maps_logical_capture_regions_back_into_rotated_scanout_buffers() {
    let target = project_capture_region(
        OutputId(1),
        Rectangle::from_size((1920, 1200).into()),
        (1920, 1200).into(),
        (1920, 1200).into(),
        Some(Rectangle::new((100, 200).into(), (300, 400).into())),
        Transform::_90,
        false,
    )
    .unwrap();

    assert_eq!(
        capture_source_rect(target, (1200, 1920).into()),
        Some(Rectangle::new((600, 100).into(), (400, 300).into()))
    );
}

#[test]
fn validates_the_last_shm_row_without_overflow() {
    assert!(pool_range_is_valid(400, 0, 40, 10, 10));
    assert!(pool_range_is_valid(416, 16, 40, 10, 10));
    assert!(!pool_range_is_valid(415, 16, 40, 10, 10));
    assert!(!pool_range_is_valid(usize::MAX, -1, 40, 10, 10));
    assert!(!pool_range_is_valid(400, 0, -1, 10, 10));
}

#[test]
fn framebuffer_sources_keep_atlas_top_left_coordinates() {
    let source = Rectangle::new((100, 200).into(), (640, 480).into());
    assert_eq!(
        framebuffer_source_rect(source, (1920, 1080).into()),
        Some(source)
    );
    assert_eq!(
        framebuffer_source_rect(
            Rectangle::new((1500, 700).into(), (640, 480).into()),
            (1920, 1080).into(),
        ),
        None
    );
}
