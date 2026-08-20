use super::*;

#[test]
fn login_session_handoff_does_not_capture_the_greeter_framebuffer() {
    assert!(!preserves_predecessor_kms_state(RuntimeLimit::UntilLogout));
    assert!(preserves_predecessor_kms_state(RuntimeLimit::TestOnly));
    assert!(preserves_predecessor_kms_state(RuntimeLimit::Frames(1)));
    assert!(preserves_predecessor_kms_state(RuntimeLimit::Duration(
        Duration::from_secs(1)
    )));
}

#[test]
fn activation_environment_uses_the_discovered_session_endpoints() {
    let environment = session_activation_environment(
        OsStr::new("wayland-37"),
        OsStr::new(":42"),
        Some(OsStr::new("/run/user/1000/denial/control.sock")),
    )
    .expect("valid session environment");
    assert_eq!(
        environment.get("WAYLAND_DISPLAY").map(String::as_str),
        Some("wayland-37")
    );
    assert_eq!(environment.get("DISPLAY").map(String::as_str), Some(":42"));
    assert!(!environment.contains_key("XMODIFIERS"));
    assert_eq!(
        environment.get("XDG_SESSION_TYPE").map(String::as_str),
        Some("wayland")
    );
    assert_eq!(
        environment.get("DENIAL_SOCKET").map(String::as_str),
        Some("/run/user/1000/denial/control.sock")
    );
    assert_eq!(
        systemd_environment_assignments(&environment),
        [
            "DENIAL_SOCKET=/run/user/1000/denial/control.sock",
            "DESKTOP_SESSION=Denial",
            "DISPLAY=:42",
            "WAYLAND_DISPLAY=wayland-37",
            "XDG_CURRENT_DESKTOP=Denial",
            "XDG_SESSION_DESKTOP=Denial",
            "XDG_SESSION_TYPE=wayland",
        ]
    );
}

#[test]
fn session_lifecycle_tracks_whether_the_systemd_target_started() {
    assert!(!SessionActivation::Dbus.starts_systemd_target());
    assert!(SessionActivation::Systemd.starts_systemd_target());
}

#[test]
fn systemd_runtime_detection_does_not_depend_on_dbus_name_ownership() {
    let runtime =
        std::env::temp_dir().join(format!("denial-systemd-runtime-{}", std::process::id()));
    let systemd_runtime = runtime.join("systemd");
    std::fs::create_dir_all(&systemd_runtime).expect("create fake systemd runtime");

    assert!(systemd_user_manager_runtime_available(Some(
        runtime.as_os_str()
    )));
    assert!(!systemd_user_manager_runtime_available(None));
    assert!(!systemd_user_manager_runtime_available(Some(OsStr::new(
        "relative/runtime"
    ))));

    std::fs::remove_dir_all(&runtime).expect("remove fake systemd runtime");
}
