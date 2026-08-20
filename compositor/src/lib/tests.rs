use super::valid_release_version;

#[test]
fn accepts_only_numeric_three_component_release_versions() {
    assert!(valid_release_version("0.2.3"));
    assert!(valid_release_version("12.0.104"));
    assert!(!valid_release_version("v0.2.3"));
    assert!(!valid_release_version("0.2"));
    assert!(!valid_release_version("0.2.3-dev"));
    assert!(!valid_release_version(""));
}
