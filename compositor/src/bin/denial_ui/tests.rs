use super::{
    attach_with_browser_devtools, contains_bytes, is_flutter_passthrough_executable,
    lexical_absolute, valid_vm_service_uri,
};
use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};

#[test]
fn normalizes_absolute_paths_without_touching_the_filesystem() {
    assert_eq!(
        lexical_absolute(Path::new("/tmp/a/../b/./bundle")).unwrap(),
        PathBuf::from("/tmp/b/bundle")
    );
}

#[test]
fn accepts_only_authenticated_loopback_service_shapes() {
    assert!(valid_vm_service_uri("http://127.0.0.1:42781/9fR2vM0x=/"));
    assert!(!valid_vm_service_uri("http://0.0.0.0:42781/token/"));
    assert!(!valid_vm_service_uri("http://127.0.0.1:0/token/"));
    assert!(!valid_vm_service_uri("http://127.0.0.1:42/"));
}

#[test]
fn finds_complete_binary_symbols() {
    assert!(contains_bytes(b"before\0symbol\0after", b"symbol\0"));
    assert!(!contains_bytes(b"symbolic", b"symbol\0"));
}

#[test]
fn recognizes_both_installed_flutter_entry_points() {
    assert!(is_flutter_passthrough_executable(OsStr::new(
        "denial-flutter"
    )));
    assert!(is_flutter_passthrough_executable(OsStr::new("flutter")));
    assert!(!is_flutter_passthrough_executable(OsStr::new("denial-ui")));
}

#[test]
fn enables_browser_devtools_for_attach_without_overriding_an_explicit_choice() {
    assert_eq!(
        attach_with_browser_devtools(vec![OsString::from("attach"), OsString::from("--machine"),]),
        vec![
            OsString::from("attach"),
            OsString::from("--devtools"),
            OsString::from("--machine"),
        ]
    );
    assert_eq!(
        attach_with_browser_devtools(vec![
            OsString::from("attach"),
            OsString::from("--no-devtools"),
        ]),
        vec![OsString::from("attach"), OsString::from("--no-devtools"),]
    );
}
