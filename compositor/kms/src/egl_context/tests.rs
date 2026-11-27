use super::*;

#[test]
fn production_contexts_request_hardware_gles_without_msaa_or_vsync() {
    let attributes = attributes(PREFERRED_GLES_VERSION);
    let requirements = pixel_format_requirements();

    assert_eq!(attributes.version, (3, 2));
    assert!(!attributes.debug);
    assert!(!attributes.vsync);
    assert_eq!(requirements.hardware_accelerated, Some(true));
    assert_eq!(requirements.multisampling, Some(0));
}
