use super::*;
use denial_core::topology::{PixelSize, SCALE_BASE};

fn atlas() -> AtlasPlan {
    AtlasPlan {
        topology_epoch: 1,
        logical_origin: (0.0, 0.0),
        logical_size: (1920.0, 1080.0),
        engine_scale_120: SCALE_BASE * 2,
        pixel_size: PixelSize::new(3840, 2160),
        outputs: Vec::new(),
    }
}

#[test]
fn projects_logical_regions_into_atlas_pixels() {
    let projected = project_request(
        ScreenshotRequest {
            request_id: None,
            region: Some(
                super::super::flutter_runtime::system_command::ScreenshotRegion {
                    x: 10.0,
                    y: 20.0,
                    width: 300.0,
                    height: 200.0,
                },
            ),
        },
        &atlas(),
    )
    .unwrap();
    assert_eq!(projected.loc.x, 20);
    assert_eq!(projected.loc.y, 40);
    assert_eq!(projected.size.w, 600);
    assert_eq!(projected.size.h, 400);
}

#[test]
fn clips_regions_to_the_canvas_and_rejects_empty_results() {
    let clipped = project_request(
        ScreenshotRequest {
            request_id: None,
            region: Some(
                super::super::flutter_runtime::system_command::ScreenshotRegion {
                    x: 1800.0,
                    y: 1000.0,
                    width: 500.0,
                    height: 500.0,
                },
            ),
        },
        &atlas(),
    )
    .unwrap();
    assert_eq!(clipped.loc.x, 3600);
    assert_eq!(clipped.loc.y, 2000);
    assert_eq!(clipped.size.w, 240);
    assert_eq!(clipped.size.h, 160);

    assert!(
        project_request(
            ScreenshotRequest {
                request_id: None,
                region: Some(
                    super::super::flutter_runtime::system_command::ScreenshotRegion {
                        x: 2000.0,
                        y: 0.0,
                        width: 10.0,
                        height: 10.0,
                    }
                ),
            },
            &atlas(),
        )
        .is_none()
    );
}
