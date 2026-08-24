use super::{
    Format, FormatSet, Fourcc, GbmBufferFlags, Modifier, PixelSize, ScanoutIdentity,
    ScanoutIdentityError, common_xrgb8888_modifiers, compatible_xrgb8888_modifiers,
    inherited_plane_needs_release, scanout_gbm_flags, smithay_opaque_alpha_for_maximum,
    validate_scanout_identities, validate_scanout_pool_allocation,
};
#[cfg(feature = "flutter")]
use super::{
    OUTPUT_POOL_LENGTH, OUTPUT_SCANOUT_ALLOCATION_LENGTH, ensure_resident_jit_engine_matches,
};

#[cfg(feature = "flutter")]
#[test]
fn a_changed_resident_jit_engine_requires_a_session_restart() {
    let first = [0x11; 32];
    let same = [0x11; 32];
    let changed = [0x22; 32];

    assert!(ensure_resident_jit_engine_matches(None, &first).is_ok());
    assert!(ensure_resident_jit_engine_matches(Some(&first), &same).is_ok());
    let error = ensure_resident_jit_engine_matches(Some(&first), &changed)
        .expect_err("changed native JIT engine must be rejected");
    assert!(error.to_string().contains("Restart the Denial session"));
}

#[cfg(feature = "flutter")]
#[test]
fn physical_output_pool_has_exactly_three_ownership_slots() {
    assert_eq!(OUTPUT_POOL_LENGTH, 3);
    assert_eq!(OUTPUT_SCANOUT_ALLOCATION_LENGTH, 4);
}

#[test]
fn scanout_pool_rejects_pathological_dimensions_before_gbm() {
    assert!(validate_scanout_pool_allocation(PixelSize::new(1, 1), 0).is_err());
    assert!(validate_scanout_pool_allocation(PixelSize::new(1, 1), 1).is_err());
    assert!(validate_scanout_pool_allocation(PixelSize::new(1, 1), 5).is_ok());
    assert!(
        validate_scanout_pool_allocation(PixelSize::new(1, 1), super::MAX_SCANOUT_BUFFERS + 1)
            .is_err()
    );
    assert!(validate_scanout_pool_allocation(PixelSize::new(0, 1080), 3).is_err());
    assert!(validate_scanout_pool_allocation(PixelSize::new(16_385, 1080), 3).is_err());
    assert!(validate_scanout_pool_allocation(PixelSize::new(15_360, 4_320), 3).is_ok());
    assert!(validate_scanout_pool_allocation(PixelSize::new(16_384, 8_192), 3).is_err());
    assert!(validate_scanout_pool_allocation(PixelSize::new(1, 1), usize::MAX).is_err());
}

#[test]
fn cross_device_render_target_does_not_require_local_scanout() {
    let local = scanout_gbm_flags(false);
    assert!(local.contains(GbmBufferFlags::RENDERING));
    assert!(local.contains(GbmBufferFlags::SCANOUT));

    let offloaded = scanout_gbm_flags(true);
    assert!(offloaded.contains(GbmBufferFlags::RENDERING));
    assert!(!offloaded.contains(GbmBufferFlags::SCANOUT));
}

#[test]
fn atlas_modifier_intersection_preserves_driver_preference_over_linear() {
    let preferred = Modifier::from(0x0200_0000_0082_0405_u64);
    let unavailable = Modifier::from(0x0200_0000_0042_0405_u64);
    let first = [
        Format {
            code: Fourcc::Xrgb8888,
            modifier: preferred,
        },
        Format {
            code: Fourcc::Xrgb8888,
            modifier: unavailable,
        },
        Format {
            code: Fourcc::Xrgb8888,
            modifier: Modifier::Linear,
        },
        Format {
            code: Fourcc::Xrgb8888,
            modifier: Modifier::Invalid,
        },
    ]
    .into_iter()
    .collect::<FormatSet>();
    let second = [
        Format {
            code: Fourcc::Xrgb8888,
            modifier: Modifier::Linear,
        },
        Format {
            code: Fourcc::Xrgb8888,
            modifier: preferred,
        },
    ]
    .into_iter()
    .collect::<FormatSet>();

    assert_eq!(
        common_xrgb8888_modifiers([&first, &second]),
        vec![preferred, Modifier::Linear]
    );
}

#[test]
fn atlas_modifier_selection_falls_back_to_linear_for_implicit_xr24() {
    let plane = [Format {
        code: Fourcc::Xrgb8888,
        modifier: Modifier::Invalid,
    }]
    .into_iter()
    .collect::<FormatSet>();
    let renderer_modifier = Modifier::from(0x0200_0000_0082_0405_u64);
    let renderer = [
        Format {
            code: Fourcc::Xrgb8888,
            modifier: renderer_modifier,
        },
        Format {
            code: Fourcc::Xrgb8888,
            modifier: Modifier::Invalid,
        },
    ]
    .into_iter()
    .collect::<FormatSet>();

    assert_eq!(
        compatible_xrgb8888_modifiers([&plane], &renderer),
        vec![Modifier::Linear]
    );
}

#[test]
fn atlas_modifier_selection_requires_implicit_xr24_from_every_consumer() {
    let implicit = [Format {
        code: Fourcc::Xrgb8888,
        modifier: Modifier::Invalid,
    }]
    .into_iter()
    .collect::<FormatSet>();
    let explicit_only = [Format {
        code: Fourcc::Xrgb8888,
        modifier: Modifier::from(0x0200_0000_0082_0405_u64),
    }]
    .into_iter()
    .collect::<FormatSet>();

    assert!(compatible_xrgb8888_modifiers([&implicit], &explicit_only).is_empty());
    assert!(compatible_xrgb8888_modifiers([&implicit, &explicit_only], &implicit).is_empty());
}

#[test]
fn plane_alpha_uses_an_advertised_narrow_range_only_when_needed() {
    let standard = smithay_opaque_alpha_for_maximum(u16::MAX as u64);
    let eight_bit = smithay_opaque_alpha_for_maximum(u8::MAX as u64);

    assert_eq!(standard, 1.0);
    assert_eq!((standard * u16::MAX as f32).round() as u64, 0xffff);
    assert_eq!((eight_bit * u16::MAX as f32).round() as u64, 0xff);
    assert_eq!(smithay_opaque_alpha_for_maximum(0), 1.0);
    assert_eq!(smithay_opaque_alpha_for_maximum(0x1_0000), 1.0);
}

#[test]
fn inherited_plane_release_selects_only_bound_non_primary_planes() {
    const OVERLAY: u64 = 0;
    const PRIMARY: u64 = 1;
    const CURSOR: u64 = 2;

    assert!(!inherited_plane_needs_release(PRIMARY, 41));
    assert!(!inherited_plane_needs_release(CURSOR, 0));
    assert!(inherited_plane_needs_release(CURSOR, 41));
    assert!(inherited_plane_needs_release(OVERLAY, 42));
}

#[test]
fn scanout_identity_validation_rejects_every_alias_class() {
    let identity = |output, connector, crtc, plane| ScanoutIdentity {
        output,
        connector,
        crtc,
        plane,
    };
    let baseline = identity(1, 1, 10, 20);
    assert!(validate_scanout_identities([baseline]).is_ok());
    assert_eq!(
        validate_scanout_identities([baseline, identity(1, 2, 11, 21)]),
        Err(ScanoutIdentityError::DuplicateOutput(1))
    );
    assert_eq!(
        validate_scanout_identities([baseline, identity(2, 1, 11, 21)]),
        Err(ScanoutIdentityError::DuplicateConnector(1))
    );
    assert_eq!(
        validate_scanout_identities([baseline, identity(2, 2, 10, 21)]),
        Err(ScanoutIdentityError::DuplicateCrtc(10))
    );
    assert_eq!(
        validate_scanout_identities([baseline, identity(2, 2, 11, 20)]),
        Err(ScanoutIdentityError::DuplicatePlane(20))
    );
    assert_eq!(
        validate_scanout_identities([identity(9, 1, 10, 20)]),
        Err(ScanoutIdentityError::OutputConnectorMismatch {
            output: 9,
            connector: 1,
        })
    );
    for zeroed in [
        identity(0, 1, 10, 20),
        identity(1, 0, 10, 20),
        identity(1, 1, 0, 20),
        identity(1, 1, 10, 0),
    ] {
        assert!(matches!(
            validate_scanout_identities([zeroed]),
            Err(ScanoutIdentityError::Zero(_))
        ));
    }
}
