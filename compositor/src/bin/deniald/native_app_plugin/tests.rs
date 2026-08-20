use super::*;
use std::os::fd::IntoRawFd;

#[test]
fn abi_tables_are_versioned_and_have_explicit_descriptor_sentinels() {
    let event = NativeAppEventV1::default();
    assert_eq!(event.struct_size as usize, std::mem::size_of_val(&event));
    assert_eq!(event.plane_fds, [-1; MAX_PLANES]);
    assert_eq!(event.acquire_fence_fd, -1);

    let command = NativeAppCommandV1::new(command_kind::CONFIGURE, 7);
    assert_eq!(
        command.struct_size as usize,
        std::mem::size_of_val(&command)
    );
    assert_eq!(command.descriptor, -1);
}

#[test]
fn configure_command_carries_logical_to_buffer_scale() {
    let command = configure_command(7, 9, 1264, 2780, 240, 120, 120_000);
    assert_eq!(command.object_id, 7);
    assert_eq!(command.serial, 9);
    assert_eq!(command.width, 1264);
    assert_eq!(command.height, 2780);
    assert_eq!(command.scale_numerator, 240);
    assert_eq!(command.scale_denominator, 120);
    assert_eq!(command.refresh_millihz, 120_000);
    assert!(validate_scale(command.scale_numerator, command.scale_denominator).is_ok());
    assert!(validate_scale(0, 120).is_err());
    assert!(validate_refresh(command.refresh_millihz).is_ok());
    assert!(validate_refresh(0).is_err());
}

#[test]
fn malformed_event_closes_every_transferred_descriptor() {
    let first = fs::File::open("/dev/null").unwrap().into_raw_fd();
    let second = fs::File::open("/dev/null").unwrap().into_raw_fd();
    let mut event = NativeAppEventV1 {
        kind: u32::MAX,
        plane_fds: [first, -1, -1, -1],
        acquire_fence_fd: second,
        ..NativeAppEventV1::default()
    };
    assert!(parse_event(0, &mut event).is_err());
    assert_eq!(event.plane_fds, [-1; MAX_PLANES]);
    assert_eq!(event.acquire_fence_fd, -1);
}

#[test]
fn relative_plugin_paths_are_rejected_before_loading() {
    assert!(validate_plugin_path(Path::new("plugin.so")).is_err());
}

#[test]
fn touch_coordinates_map_and_clamp_to_source_pixels() {
    let rect = wire::InputRect {
        x: 10.0,
        y: 20.0,
        width: 100.0,
        height: 200.0,
    };
    let source = wire::InputRect {
        x: 4.0,
        y: 8.0,
        width: 50.0,
        height: 100.0,
    };
    assert_eq!(
        map_touch_coordinates(rect, source, 60.0, 120.0),
        (29 << 16, 58 << 16)
    );
    let (x, y) = map_touch_coordinates(rect, source, 1_000.0, -1_000.0);
    assert_eq!(x, (54 << 16) - 1);
    assert_eq!(y, 8 << 16);
}

#[test]
fn native_hit_test_requires_visible_root_window_region() {
    let mut region = wire::InputWindowRegion {
        object_id: 7,
        surface_id: 7,
        window_id: 7,
        rect: wire::InputRect {
            x: 0.0,
            y: 0.0,
            width: 100.0,
            height: 100.0,
        },
        source_rect: wire::InputRect {
            x: 0.0,
            y: 0.0,
            width: 100.0,
            height: 100.0,
        },
        z: 1,
        flags: wire::INPUT_WINDOW_VISIBLE,
    };
    assert!(input_region_accepts(&region, 50.0, 50.0));
    region.object_id = 8;
    assert!(!input_region_accepts(&region, 50.0, 50.0));
    region.object_id = 7;
    region.flags |= wire::INPUT_WINDOW_HIT_TEST_DISABLED;
    assert!(!input_region_accepts(&region, 50.0, 50.0));
}
