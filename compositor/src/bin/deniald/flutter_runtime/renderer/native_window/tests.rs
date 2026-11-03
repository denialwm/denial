use super::*;
use crate::wire::SurfaceRoleDescription;

fn surface(id: u64, rect: ClientRect, buffer: [u32; 2]) -> SurfaceLayerDescription {
    SurfaceLayerDescription {
        surface_id: id,
        parent_surface_id: if id == 1 { 0 } else { 1 },
        popup_root_surface_id: 0,
        role: if id == 1 {
            SurfaceRoleDescription::Root
        } else {
            SurfaceRoleDescription::Subsurface
        },
        texture_id: id,
        width: buffer[0],
        height: buffer[1],
        surface_x: rect.x,
        surface_y: rect.y,
        surface_width: rect.width,
        surface_height: rect.height,
        texture_source_x: 0.0,
        texture_source_y: 0.0,
        texture_source_width: f64::from(buffer[0]),
        texture_source_height: f64::from(buffer[1]),
        transform: 0,
        scale_120: 240,
        composition_order: id as u32,
        opacity: 1.0,
        opaque: false,
        window_geometry: None,
    }
}

fn firefox_plan() -> NativeWindowPlan {
    let canvas = ClientRect::new(26.0, 23.0, 1678.0, 1130.0).unwrap();
    NativeWindowPlan::new(
        1,
        canvas,
        2.0,
        &[
            surface(
                1,
                ClientRect::new(0.0, 0.0, 1730.0, 1182.0).unwrap(),
                [3460, 2364],
            ),
            surface(2, canvas, [3356, 2260]),
        ],
    )
    .unwrap()
}

fn close(actual: f32, expected: f64) {
    assert!(
        (f64::from(actual) - expected).abs() < 0.00001,
        "{actual} != {expected}"
    );
}

#[test]
fn firefox_layers_merge_in_client_space_without_shadow_padding() {
    let plan = firefox_plan();
    assert_eq!((plan.width, plan.height), (3356, 2260));
    assert_eq!(
        plan.layers
            .iter()
            .map(|layer| layer.texture_id)
            .collect::<Vec<_>>(),
        [1, 2]
    );
    let root = plan.vertices(&plan.layers[0], [3460, 2364]).unwrap();
    assert_eq!(root[0].position, [0.0, 0.0]);
    assert_eq!(root[3].position, [3356.0, 2260.0]);
    close(root[0].uv[0], 52.0 / 3460.0);
    close(root[0].uv[1], 46.0 / 2364.0);
    let child = plan.vertices(&plan.layers[1], [3356, 2260]).unwrap();
    assert_eq!(child[0].uv, [0.0, 0.0]);
    assert_eq!(child[3].uv, [1.0, 1.0]);
}

#[test]
fn all_buffer_orientations_preserve_cropped_corner_order() {
    let mut layer = firefox_plan().layers[1].clone();
    layer.destination = ClientRect::new(4.0, 7.0, 60.0, 40.0).unwrap();
    layer.source = ClientRect::new(8.0, 12.0, 40.0, 20.0).unwrap();
    let corner_order = [
        [0, 1, 2, 3],
        [2, 0, 3, 1],
        [3, 2, 1, 0],
        [1, 3, 0, 2],
        [1, 0, 3, 2],
        [0, 2, 1, 3],
        [2, 3, 0, 1],
        [3, 1, 2, 0],
    ];
    let source = [[8.0, 12.0], [48.0, 12.0], [8.0, 32.0], [48.0, 32.0]];
    let points = [[4.0, 7.0], [64.0, 7.0], [4.0, 47.0], [64.0, 47.0]];
    for (transform, expected) in corner_order.iter().enumerate() {
        layer.transform = transform as u32;
        for (point, corner) in points.iter().zip(expected) {
            let actual = layer.uv_at(*point, [100, 80]).unwrap();
            close(actual[0], source[*corner][0] / 100.0);
            close(actual[1], source[*corner][1] / 80.0);
        }
    }
}

#[test]
fn strict_sampler_limits_handle_subtexel_crop_and_older_resize_buffer() {
    let mut layer = firefox_plan().layers[1].clone();
    layer.source = ClientRect::new(8.0, 12.0, 0.25, 0.75).unwrap();
    let limits = layer.sample_limits([100, 80]).unwrap();
    assert_eq!(limits[0], limits[2]);
    assert_eq!(limits[1], limits[3]);
    layer.source = ClientRect::new(20.0, 10.0, 80.0, 70.0).unwrap();
    let limits = layer.sample_limits([60, 40]).unwrap();
    close(limits[2], 59.5 / 60.0);
    close(limits[3], 39.5 / 40.0);
    assert!(layer.sample_limits([0, 40]).is_none());
}

/// As published by `cropped_buffer_canvas` for an integral viewport crop.
fn crop(source: [f64; 4]) -> ExternalTexturePresentation {
    ExternalTexturePresentation {
        struct_size: std::mem::size_of::<ExternalTexturePresentation>(),
        width: source[2],
        height: source[3],
        source,
        destination: [0.0, 0.0, source[2], source[3]],
        ..Default::default()
    }
}

#[test]
fn cropped_inputs_sample_their_crop_origin_instead_of_the_buffer_corner() {
    // The child shows the (200, 120) 200x150 crop of a 1000x800 buffer.
    // Its description carries only the virtual 200x150 canvas.
    let canvas = ClientRect::new(0.0, 0.0, 400.0, 300.0).unwrap();
    let child = ClientRect::new(50.0, 40.0, 200.0, 150.0).unwrap();
    let plan = NativeWindowPlan::new(
        1,
        canvas,
        1.0,
        &[
            surface(1, canvas, [400, 300]),
            surface(2, child, [200, 150]),
        ],
    )
    .unwrap();
    let presented = plan
        .presented(&[
            Some(ExternalTexturePresentation::default()),
            Some(crop([200.0, 120.0, 200.0, 150.0])),
        ])
        .unwrap();
    assert_eq!(presented.layers[0], plan.layers[0]);
    let layer = &presented.layers[1];
    assert_eq!(
        layer.source,
        ClientRect::new(200.0, 120.0, 200.0, 150.0).unwrap()
    );
    let vertices = presented.vertices(layer, [1000, 800]).unwrap();
    assert_eq!(vertices[0].position, [50.0, 40.0]);
    close(vertices[0].uv[0], 200.0 / 1000.0);
    close(vertices[0].uv[1], 120.0 / 800.0);
    close(vertices[3].uv[0], 400.0 / 1000.0);
    close(vertices[3].uv[1], 270.0 / 800.0);
    let limits = layer.sample_limits([1000, 800]).unwrap();
    close(limits[0], 200.5 / 1000.0);
    close(limits[1], 120.5 / 800.0);
    close(limits[2], 399.5 / 1000.0);
    close(limits[3], 269.5 / 800.0);
}

#[test]
fn presentations_other_than_crops_keep_the_surface_tree() {
    let plan = firefox_plan();
    let none = ExternalTexturePresentation::default();
    assert!(reproduces_presentation(&none));
    assert!(plan.presented(&[Some(none), Some(none)]).is_some());
    assert!(plan.presented(&[Some(none)]).is_none());
    // Mobile inset canvas: the image is placed below a background strip.
    let mut inset = crop([0.0, 0.0, 3460.0, 2364.0]);
    inset.height += 96.0;
    inset.destination[1] = 96.0;
    inset.background = [0.0, 0.0, 3460.0, 96.0];
    assert!(!reproduces_presentation(&inset));
    assert!(plan.presented(&[Some(inset), Some(none)]).is_none());
    let mut strip = crop([0.0, 0.0, 3460.0, 2364.0]);
    strip.background = [0.0, 0.0, 3460.0, 96.0];
    assert!(!reproduces_presentation(&strip));
    let mut invalid = crop([0.0, 0.0, 3460.0, 2364.0]);
    invalid.source[0] = f64::NAN;
    assert!(!reproduces_presentation(&invalid));
}

#[test]
fn layers_without_a_current_buffer_wait_instead_of_failing_the_window() {
    // A tooltip subsurface mapped since the last tick: the plan already
    // lists it, but its first buffer has not advanced.
    let plan = firefox_plan();
    let none = ExternalTexturePresentation::default();
    let presented = plan.presented(&[Some(none), None]).unwrap();
    assert_eq!(presented.layers, [plan.layers[0].clone()]);
    assert_eq!(
        (presented.texture_id, presented.width, presented.height),
        (plan.texture_id, plan.width, plan.height)
    );
    assert!(plan.presented(&[None, None]).unwrap().layers.is_empty());
}

#[test]
fn popups_single_images_and_fully_covered_roots_keep_existing_routes() {
    let plan = firefox_plan();
    let mut surfaces = vec![
        surface(1, plan.canvas, [3356, 2260]),
        surface(2, plan.canvas, [3356, 2260]),
    ];
    surfaces[1].popup_root_surface_id = 2;
    assert!(NativeWindowPlan::new(1, plan.canvas, 2.0, &surfaces).is_none());
    surfaces[1].popup_root_surface_id = 0;
    surfaces[1].opaque = true;
    assert!(NativeWindowPlan::new(1, plan.canvas, 2.0, &surfaces).is_none());
    surfaces[1].opacity = 0.5;
    assert_eq!(
        NativeWindowPlan::new(1, plan.canvas, 2.0, &surfaces)
            .unwrap()
            .layers
            .len(),
        2
    );
}

#[test]
fn allocation_and_input_limits_reject_invalid_client_geometry() {
    let plan = firefox_plan();
    let layers = [
        surface(1, plan.canvas, [3356, 2260]),
        surface(2, plan.canvas, [3356, 2260]),
    ];
    assert!(
        NativeWindowPlan::new(NATIVE_WINDOW_TEXTURE_NAMESPACE, plan.canvas, 2.0, &layers).is_none()
    );
    assert!(NativeWindowPlan::new(1, plan.canvas, f64::NAN, &layers).is_none());
    assert!(
        NativeWindowPlan::new(
            1,
            ClientRect::new(0.0, 0.0, 9000.0, 9000.0).unwrap(),
            1.0,
            &layers
        )
        .is_none()
    );
    let mut invalid = layers.clone();
    invalid[1].transform = 8;
    assert!(NativeWindowPlan::new(1, plan.canvas, 2.0, &invalid).is_none());
    invalid[1].transform = 0;
    invalid[1].texture_source_width = 4000.0;
    assert!(NativeWindowPlan::new(1, plan.canvas, 2.0, &invalid).is_none());
}

#[test]
fn fractional_scale_retains_exact_source_extent_inside_rounded_allocation() {
    let mut plan = firefox_plan();
    let layers = [
        surface(1, plan.canvas, [3356, 2260]),
        surface(2, plan.canvas, [3356, 2260]),
    ];
    plan = NativeWindowPlan::new(1, plan.canvas, 1.25, &layers).unwrap();
    assert_eq!((plan.width, plan.height), (2098, 1413));
    let vertices = plan.vertices(&plan.layers[0], [3356, 2260]).unwrap();
    assert_eq!(vertices[3].position, [2097.5, 1412.5]);
}

#[test]
fn registry_reuses_geometry_and_routes_each_input_update_to_one_window() {
    let mut registry = NativeWindowRegistry::default();
    let first = registry.upsert(firefox_plan()).unwrap();
    let again = registry.upsert(firefox_plan()).unwrap();
    assert!(Arc::ptr_eq(&first, &again));
    let mut changed = vec![2, 1, 2];
    registry.include_dependents(&mut changed);
    assert_eq!(
        changed
            .iter()
            .filter(|id| **id == first.plan.texture_id)
            .count(),
        1
    );
    let mut resized = firefox_plan();
    resized.layers[1].source.width -= 1.0;
    let next = registry.upsert(resized).unwrap();
    assert!(next.revision > first.revision);
    assert_eq!(first.plan.layers[1].source.width, 3356.0);
    assert_eq!(
        registry.get(next.plan.texture_id).unwrap().revision,
        next.revision
    );
    registry.remove(next.plan.texture_id);
    let mut changed = vec![1, 2];
    registry.include_dependents(&mut changed);
    assert_eq!(changed, [1, 2]);
}

#[test]
fn native_routing_preserves_reserved_system_images() {
    let mut registry = NativeWindowRegistry::default();
    let id = firefox_plan().texture_id;
    assert!(!registry.handles_texture(id));
    registry.upsert(firefox_plan()).unwrap();
    assert!(registry.handles_texture(id));
    for source in [0, 1, -1, i64::MAX, i64::MAX - 1, id + 1] {
        assert!(!registry.handles_texture(source), "source ID {source}");
    }
    registry.remove(id);
    assert!(!registry.handles_texture(id));
}

#[test]
fn registry_bounds_live_plans_and_never_wraps_geometry_revision() {
    let mut registry = NativeWindowRegistry::default();
    for id in 1..=MAX_NATIVE_WINDOW_PLANS as u64 {
        let mut plan = firefox_plan();
        plan.window_id = id;
        plan.texture_id = (NATIVE_WINDOW_TEXTURE_NAMESPACE | id) as i64;
        assert!(registry.upsert(plan).is_some());
    }
    let mut extra = firefox_plan();
    extra.window_id = 500;
    extra.texture_id = (NATIVE_WINDOW_TEXTURE_NAMESPACE | 500) as i64;
    assert!(registry.upsert(extra.clone()).is_none());
    registry.remove((NATIVE_WINDOW_TEXTURE_NAMESPACE | 1) as i64);
    registry.next_revision = u64::MAX;
    assert!(registry.upsert(extra).is_none());
}
