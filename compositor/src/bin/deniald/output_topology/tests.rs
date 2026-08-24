use super::*;

#[cfg(test)]
mod output_mode_tests {
    use super::{HorizontalOutputPlacement, LogicalPoint, select_refresh_millihz};

    #[test]
    fn configured_refresh_selects_the_nearest_nominal_drm_mode() {
        let refreshes = [60_000, 179_998, 199_998, 280_000];

        assert_eq!(
            select_refresh_millihz(refreshes, Some(200_000)),
            Some(199_998)
        );
        assert_eq!(
            select_refresh_millihz(refreshes, Some(180_000)),
            Some(179_998)
        );
        assert_eq!(select_refresh_millihz(refreshes, None), Some(280_000));
    }

    #[test]
    fn configured_refresh_falls_back_to_the_nearest_available_rate() {
        assert_eq!(
            select_refresh_millihz([60_000, 180_000, 280_000], Some(200_000)),
            Some(180_000)
        );
    }

    #[test]
    fn unconfigured_outputs_cascade_after_the_existing_layout() {
        let mut placement = HorizontalOutputPlacement::default();
        let internal = placement.resolve(Some(LogicalPoint::new(0, 0)));
        placement.include(internal, 1920).unwrap();

        let external = placement.resolve(None);

        assert_eq!(external, LogicalPoint::new(1920, 0));
    }
}

#[cfg(all(test, feature = "flutter"))]
mod output_rotation_request_tests {
    use super::{output_control, output_request_changes_only_transforms};

    fn mode() -> output_control::OutputControlMode {
        output_control::OutputControlMode {
            width: 1920,
            height: 1080,
            refresh_millihz: 60_000,
            preferred: true,
        }
    }

    fn current() -> output_control::OutputControlOutput {
        output_control::OutputControlOutput {
            monitor_id: 1,
            name: "eDP-1".to_owned(),
            description: "eDP-1".to_owned(),
            connected: true,
            enabled: true,
            powered: true,
            x: 0,
            y: 0,
            logical_width: 1920,
            logical_height: 1080,
            physical_width_mm: None,
            physical_height_mm: None,
            scale: 1.0,
            transform: output_control::OutputTransformName::Normal,
            adaptive_sync_supported: false,
            adaptive_sync: false,
            current_mode: Some(mode()),
            modes: vec![mode()],
        }
    }

    fn requested(
        transform: output_control::OutputTransformName,
    ) -> output_control::RequestedOutput {
        output_control::RequestedOutput {
            name: "eDP-1".to_owned(),
            enabled: true,
            powered: true,
            x: 0,
            y: 0,
            mode: output_control::RequestedOutputMode {
                width: 1920,
                height: 1080,
                refresh_millihz: 60_000,
            },
            scale: 1.0,
            transform,
            adaptive_sync: false,
        }
    }

    #[test]
    fn settings_rotation_uses_the_sensor_animation_path() {
        assert!(output_request_changes_only_transforms(
            &[current()],
            &[requested(output_control::OutputTransformName::Rotate90)],
        ));
    }

    #[test]
    fn mixed_geometry_change_is_not_a_rotation_transition() {
        let mut request = requested(output_control::OutputTransformName::Rotate90);
        request.scale = 2.0;
        assert!(!output_request_changes_only_transforms(
            &[current()],
            &[request],
        ));
    }

    #[test]
    fn unchanged_transform_does_not_start_a_rotation_transition() {
        assert!(!output_request_changes_only_transforms(
            &[current()],
            &[requested(output_control::OutputTransformName::Normal)],
        ));
    }
}
