#[cfg(feature = "flutter")]
use super::ensure_resident_jit_engine_matches;
use super::{
    AtlasFormat, SCANOUT_FOURCCS, ScanoutIdentity, ScanoutIdentityError, compatible_scanout_format,
    framebuffer_from_property_value, validate_scanout_identities,
};
use smithay::backend::allocator::{Format, Fourcc, Modifier, format::FormatSet};

fn formats(entries: &[(Fourcc, Modifier)]) -> FormatSet {
    entries
        .iter()
        .map(|&(code, modifier)| Format { code, modifier })
        .collect()
}

#[test]
fn the_atlas_prefers_ten_bits_when_planes_and_renderer_share_it() {
    let compressed = Modifier::Qcom_compressed;
    let plane = formats(&[
        (Fourcc::Xrgb2101010, compressed),
        (Fourcc::Xrgb2101010, Modifier::Linear),
        (Fourcc::Xrgb8888, compressed),
        (Fourcc::Xrgb8888, Modifier::Linear),
    ]);
    let renderer = formats(&[
        (Fourcc::Xrgb2101010, compressed),
        (Fourcc::Xrgb8888, compressed),
        (Fourcc::Xrgb8888, Modifier::Linear),
    ]);
    assert_eq!(
        compatible_scanout_format(&SCANOUT_FOURCCS, &[&plane], &renderer),
        Some(AtlasFormat {
            code: Fourcc::Xrgb2101010,
            modifiers: vec![compressed],
        })
    );
}

#[test]
fn the_atlas_keeps_eight_bits_when_any_plane_lacks_ten() {
    let ten = formats(&[
        (Fourcc::Xrgb2101010, Modifier::Linear),
        (Fourcc::Xrgb8888, Modifier::Linear),
    ]);
    let eight = formats(&[(Fourcc::Xrgb8888, Modifier::Linear)]);
    assert_eq!(
        compatible_scanout_format(&SCANOUT_FOURCCS, &[&ten, &eight], &ten),
        Some(AtlasFormat {
            code: Fourcc::Xrgb8888,
            modifiers: vec![Modifier::Linear],
        })
    );
    assert_eq!(
        compatible_scanout_format(&SCANOUT_FOURCCS[1..], &[&ten], &ten).map(|f| f.code),
        Some(Fourcc::Xrgb8888)
    );
}

#[test]
fn zero_framebuffer_property_means_no_predecessor_scanout() {
    assert_eq!(framebuffer_from_property_value(0).unwrap(), None);
}

#[test]
fn nonzero_framebuffer_property_identifies_predecessor_scanout() {
    let framebuffer = framebuffer_from_property_value(17)
        .unwrap()
        .expect("nonzero FB_ID should produce a framebuffer handle");

    assert_eq!(u32::from(framebuffer), 17);
}

#[test]
fn oversized_framebuffer_property_is_rejected() {
    assert!(framebuffer_from_property_value(u64::MAX).is_err());
}

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
