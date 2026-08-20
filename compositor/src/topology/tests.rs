use super::*;

fn output(
    id: u64,
    name: &str,
    position: (i32, i32),
    mode: (u32, u32),
    scale_120: u32,
    refresh_millihz: u32,
) -> OutputSpec {
    OutputSpec {
        id: OutputId(id),
        name: name.into(),
        position: LogicalPoint::new(position.0, position.1),
        mode: PixelSize::new(mode.0, mode.1),
        scale_120,
        refresh_millihz,
        transform: OutputTransform::Normal,
    }
}

#[test]
fn normalizes_negative_coordinates_without_changing_global_origin() {
    let manager = TopologyManager::new([
        output(1, "left", (-1920, 0), (1920, 1080), 120, 60_000),
        output(2, "main", (0, -360), (2560, 1440), 120, 200_000),
    ])
    .unwrap();

    let snapshot = manager.snapshot();
    assert_eq!(snapshot.logical_bounds.unwrap().x, -1920.0);
    assert_eq!(snapshot.logical_bounds.unwrap().y, -360.0);
    assert_eq!(snapshot.ticker, Some(OutputId(2)));

    let atlas = AtlasPlan::for_snapshot(&snapshot).unwrap();
    assert_eq!(atlas.logical_origin, (-1920.0, -360.0));
    assert_eq!(atlas.pixel_size, PixelSize::new(4480, 1440));
    assert_eq!(atlas.outputs[0].source_rect.x, 0);
    assert_eq!(atlas.outputs[0].source_rect.y, 360);
    assert_eq!(atlas.outputs[1].source_rect.x, 1920);
    assert_eq!(atlas.outputs[1].source_rect.y, 0);
}

#[test]
fn assigns_stable_negative_render_view_ids() {
    assert_eq!(RenderViewId::for_output(OutputId(0)).unwrap().get(), -1);
    assert_eq!(RenderViewId::for_output(OutputId(41)).unwrap().get(), -42);
    assert!(RenderViewId::for_output(OutputId(i64::MAX as u64)).is_none());
}

#[test]
fn derives_native_render_targets_from_the_atlas_geometry() {
    let manager = TopologyManager::new([
        output(0, "left", (0, 0), (1920, 1080), 120, 60_000),
        output(1, "right", (1920, 0), (2560, 1440), 180, 60_000),
    ])
    .unwrap();
    let snapshot = manager.snapshot();
    let atlas = AtlasPlan::for_snapshot(&snapshot).unwrap();
    let outputs = atlas.render_outputs(&snapshot).unwrap();

    assert_eq!(outputs.len(), 2);
    assert_eq!(outputs[0].render_view_id.get(), -1);
    assert_eq!(outputs[0].target_size, PixelSize::new(1920, 1080));
    assert_eq!(outputs[0].scale_120, 120);
    assert_eq!(outputs[1].render_view_id.get(), -2);
    assert_eq!(outputs[1].target_size, PixelSize::new(2560, 1440));
    assert_eq!(outputs[1].scale_120, 180);
    assert_eq!(outputs[1].configuration_generation, snapshot.epoch);
}

#[test]
fn vertical_and_l_shaped_layouts_are_not_special_cases() {
    let manager = TopologyManager::new([
        output(1, "top", (0, -1080), (1920, 1080), 120, 60_000),
        output(2, "main", (0, 0), (2560, 1440), 120, 144_000),
        output(3, "right", (2560, 360), (1920, 1080), 120, 75_000),
    ])
    .unwrap();

    let atlas = AtlasPlan::for_snapshot(&manager.snapshot()).unwrap();
    assert_eq!(atlas.pixel_size, PixelSize::new(4480, 2520));
    assert!(
        atlas
            .outputs
            .iter()
            .all(|output| output.sampling == Sampling::OneToOne)
    );
}

#[test]
fn fractional_and_mixed_scale_are_explicit_in_the_atlas_plan() {
    let manager = TopologyManager::new([
        output(1, "hidpi", (0, 0), (3840, 2160), 240, 120_000),
        output(2, "fractional", (1920, 0), (2560, 1440), 150, 165_000),
    ])
    .unwrap();

    let snapshot = manager.snapshot();
    let atlas = AtlasPlan::for_snapshot(&snapshot).unwrap();
    assert_eq!(atlas.engine_scale_120, 240);
    assert_eq!(atlas.outputs[0].sampling, Sampling::OneToOne);
    assert_eq!(atlas.outputs[1].sampling, Sampling::Scaled);
    assert_eq!(atlas.outputs[1].pixel_size, PixelSize::new(2560, 1440));
}

#[test]
fn rotation_swaps_logical_axes_but_keeps_the_native_render_target() {
    let mut portrait = output(1, "portrait", (0, 0), (1080, 1920), 120, 60_000);
    portrait.transform = OutputTransform::Rotate90;
    let manager = TopologyManager::new([portrait]).unwrap();
    let snapshot = manager.snapshot();
    assert_eq!(snapshot.logical_bounds.unwrap().width, 1920.0);
    assert_eq!(snapshot.logical_bounds.unwrap().height, 1080.0);
    let atlas = AtlasPlan::for_snapshot(&snapshot).unwrap();
    assert_eq!(atlas.outputs[0].pixel_size, PixelSize::new(1920, 1080));
    let render = atlas.render_outputs(&snapshot).unwrap();
    assert_eq!(render[0].target_size, PixelSize::new(1080, 1920));
    assert_eq!(
        render[0].source_to_target_transform,
        OutputProjection {
            scale_x: 0.0,
            skew_x: -1.0,
            translate_x: 1080.0,
            skew_y: 1.0,
            scale_y: 0.0,
            translate_y: 0.0,
        }
    );
}

#[test]
fn output_transforms_map_native_absolute_input_back_to_the_scene() {
    assert_eq!(
        OutputTransform::Rotate90.native_to_logical(0.25, 0.75),
        (0.75, 0.75)
    );
    assert_eq!(
        OutputTransform::Rotate270.native_to_logical(0.25, 0.75),
        (0.25, 0.25)
    );
    assert_eq!(
        OutputTransform::Flipped90.native_to_logical(0.25, 0.75),
        (0.75, 0.25)
    );
    assert_eq!(
        OutputTransform::Flipped270.native_to_logical(0.25, 0.75),
        (0.25, 0.75)
    );
}

#[test]
fn sensor_rotation_composes_with_the_fixed_panel_transform() {
    assert_eq!(
        OutputTransform::Rotate90.rotated_by(OutputTransform::Rotate270),
        OutputTransform::Normal
    );
    assert_eq!(
        OutputTransform::Flipped90.rotated_by(OutputTransform::Rotate90),
        OutputTransform::Flipped180
    );
    for rotation in [
        OutputTransform::Normal,
        OutputTransform::Rotate90,
        OutputTransform::Rotate180,
        OutputTransform::Rotate270,
    ] {
        assert_eq!(
            OutputTransform::Flipped270
                .rotated_by(rotation)
                .rotated_by(rotation.inverse_rotation()),
            OutputTransform::Flipped270
        );
    }
}

#[test]
fn hotplug_transaction_is_atomic_and_epoch_only_changes_for_real_work() {
    let mut manager =
        TopologyManager::new([output(1, "main", (0, 0), (2560, 1440), 120, 200_000)]).unwrap();
    let original = manager.snapshot();

    let noop = manager
        .apply([TopologyChange::Upsert(original.outputs[0].clone())])
        .unwrap();
    assert!(noop.is_noop());

    let commit = manager
        .apply([
            TopologyChange::Upsert(output(2, "side", (-1920, 0), (1920, 1080), 120, 60_000)),
            TopologyChange::Upsert(output(1, "main", (0, -100), (2560, 1440), 120, 200_000)),
        ])
        .unwrap();
    assert_eq!(commit.added, vec![OutputId(2)]);
    assert_eq!(commit.changed, vec![OutputId(1)]);
    assert_eq!(commit.epoch, original.epoch + 1);

    let before_invalid = manager.snapshot();
    let invalid = output(3, "side", (0, 0), (1280, 720), 120, 60_000);
    assert!(matches!(
        manager.apply([TopologyChange::Upsert(invalid)]),
        Err(TopologyError::DuplicateName(_))
    ));
    assert_eq!(manager.snapshot(), before_invalid);
}

#[test]
fn removing_the_last_output_is_a_valid_hotplug_state() {
    let mut manager =
        TopologyManager::new([output(1, "main", (0, 0), (1920, 1080), 120, 60_000)]).unwrap();
    manager
        .apply([TopologyChange::Remove(OutputId(1))])
        .unwrap();
    let snapshot = manager.snapshot();
    assert!(snapshot.outputs.is_empty());
    assert!(snapshot.logical_bounds.is_none());
    assert!(snapshot.ticker.is_none());
    assert!(AtlasPlan::for_snapshot(&snapshot).is_none());
}
