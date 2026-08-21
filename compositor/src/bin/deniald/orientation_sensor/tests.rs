use super::Orientation;
use denial_core::topology::OutputTransform;

#[test]
fn iio_orientations_follow_the_desktop_transform_convention() {
    assert_eq!(
        Orientation::parse("normal").output_rotation(),
        OutputTransform::Normal
    );
    assert_eq!(
        Orientation::parse("bottom-up").output_rotation(),
        OutputTransform::Rotate180
    );
    assert_eq!(
        Orientation::parse("left-up").output_rotation(),
        OutputTransform::Rotate270
    );
    assert_eq!(
        Orientation::parse("right-up").output_rotation(),
        OutputTransform::Rotate90
    );
    assert_eq!(
        Orientation::parse("undefined").output_rotation(),
        OutputTransform::Normal
    );
}
