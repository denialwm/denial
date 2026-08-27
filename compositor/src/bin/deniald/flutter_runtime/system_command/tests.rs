use super::*;

fn packet(command: u8, request_id: u64, arguments: &[&[u8]]) -> Vec<u8> {
    let mut packet = vec![command];
    packet.extend_from_slice(&request_id.to_le_bytes());
    packet.extend_from_slice(&(arguments.len() as u32).to_le_bytes());
    for argument in arguments {
        packet.extend_from_slice(&(argument.len() as u32).to_le_bytes());
        packet.extend_from_slice(argument);
    }
    packet
}

#[test]
fn decodes_launch_screenshot_and_logout_packets() {
    assert_eq!(
        decode(&packet(
            LAUNCH_APPLICATION,
            42,
            &[b"foot", b"--title", "è".as_bytes()]
        )),
        Ok(Request::LaunchApplication {
            arguments: vec!["foot".into(), "--title".into(), "è".into()],
            desktop_file_id: None,
            launch_request_id: NonZeroU64::new(42),
        })
    );
    assert_eq!(
        decode(&packet(
            LAUNCH_DESKTOP_APPLICATION,
            43,
            &[b"org.example.Terminal.desktop", b"foot"]
        )),
        Ok(Request::LaunchApplication {
            arguments: vec!["foot".into()],
            desktop_file_id: Some("org.example.Terminal.desktop".into()),
            launch_request_id: NonZeroU64::new(43),
        })
    );
    assert_eq!(
        decode(&packet(TAKE_SCREENSHOT, 0, &[])),
        Ok(Request::Screenshot(ScreenshotRequest {
            request_id: None,
            region: None,
        }))
    );
    assert_eq!(
        decode(&packet(
            TAKE_SCREENSHOT,
            77,
            &[b"12.5", b"4", b"800.25", b"600"]
        )),
        Ok(Request::Screenshot(ScreenshotRequest {
            request_id: NonZeroU64::new(77),
            region: Some(ScreenshotRegion {
                x: 12.5,
                y: 4.0,
                width: 800.25,
                height: 600.0,
            }),
        }))
    );
    assert_eq!(
        decode(&packet(SCREENSHOT_PREPARED, 77, &[])),
        Ok(Request::ScreenshotPrepared(NonZeroU64::new(77).unwrap()))
    );
    assert_eq!(
        decode(&packet(CANCEL_SCREENSHOT, 77, &[])),
        Ok(Request::CancelScreenshot(NonZeroU64::new(77).unwrap()))
    );
    assert_eq!(decode(&packet(LOGOUT, 0, &[])), Ok(Request::Logout));
}

#[test]
fn queues_launch_until_the_compositor_can_attach_an_activation_token() {
    let mut handler = SystemCommandHandler::new(
        Some(OsString::from("wayland-7")),
        Some(OsString::from(":42")),
        None,
    );
    handler
        .handle(&packet(
            LAUNCH_APPLICATION,
            19,
            &[b"foot", b"--title", b"queued"],
        ))
        .unwrap();

    assert_eq!(
        handler.take_application_launch(),
        Some(PendingApplicationLaunch {
            arguments: vec!["foot".into(), "--title".into(), "queued".into()],
            desktop_file_id: None,
            launch_request_id: NonZeroU64::new(19),
        })
    );
    assert_eq!(handler.take_application_launch(), None);
}

#[test]
fn rejects_unbounded_or_structurally_invalid_packets() {
    assert_eq!(decode(&[]), Err(DecodeError::InvalidPacketSize(0)));
    assert_eq!(
        decode(&vec![0; MAX_PACKET_SIZE + 1]),
        Err(DecodeError::InvalidPacketSize(MAX_PACKET_SIZE + 1))
    );

    let mut too_many = packet(LAUNCH_APPLICATION, 0, &[]);
    too_many[9..13].copy_from_slice(&((MAX_ARGUMENTS + 1) as u32).to_le_bytes());
    assert_eq!(
        decode(&too_many),
        Err(DecodeError::TooManyArguments((MAX_ARGUMENTS + 1) as u32))
    );

    let mut truncated = packet(LAUNCH_APPLICATION, 0, &[b"foot"]);
    truncated.pop();
    assert_eq!(
        decode(&truncated),
        Err(DecodeError::TruncatedArgument { index: 0 })
    );

    let mut trailing = packet(LOGOUT, 0, &[]);
    trailing.push(0);
    assert_eq!(decode(&trailing), Err(DecodeError::TrailingBytes));
}

#[test]
fn rejects_unsafe_argument_encodings() {
    assert_eq!(
        decode(&packet(LAUNCH_APPLICATION, 0, &[b""])),
        Err(DecodeError::InvalidArgumentSize { index: 0, size: 0 })
    );
    assert_eq!(
        decode(&packet(LAUNCH_APPLICATION, 0, &[b"bad\0argument"])),
        Err(DecodeError::ArgumentContainsNul(0))
    );
    assert_eq!(
        decode(&packet(LAUNCH_APPLICATION, 0, &[&[0xff]])),
        Err(DecodeError::ArgumentIsNotUtf8(0))
    );
}

#[test]
fn validates_command_specific_fields() {
    assert_eq!(
        decode(&packet(LAUNCH_APPLICATION, 0, &[])),
        Err(DecodeError::LaunchHasNoArguments)
    );
    assert_eq!(
        decode(&packet(LAUNCH_DESKTOP_APPLICATION, 0, &[])),
        Err(DecodeError::DesktopLaunchHasNoIdentity)
    );
    assert_eq!(
        decode(&packet(
            LAUNCH_DESKTOP_APPLICATION,
            0,
            &[b"not/a.desktop", b"foot"]
        )),
        Err(DecodeError::InvalidDesktopFileId)
    );
    assert_eq!(
        decode(&packet(LOGOUT, 1, &[])),
        Err(DecodeError::UnexpectedLaunchMetadata)
    );
    assert_eq!(
        decode(&packet(LOGOUT, 0, &[b"extra"])),
        Err(DecodeError::UnexpectedLaunchMetadata)
    );
    assert_eq!(
        decode(&packet(TAKE_SCREENSHOT, 0, &[b"0", b"0", b"10"])),
        Err(DecodeError::ScreenshotArgumentCount(3))
    );
    assert_eq!(
        decode(&packet(TAKE_SCREENSHOT, 0, &[b"0", b"0", b"10", b"20"])),
        Err(DecodeError::InvalidScreenshotRequestId)
    );
    assert_eq!(
        decode(&packet(SCREENSHOT_PREPARED, 0, &[])),
        Err(DecodeError::InvalidScreenshotRequestId)
    );
    assert_eq!(
        decode(&packet(TAKE_SCREENSHOT, 0, &[b"0", b"0", b"-10", b"20"])),
        Err(DecodeError::InvalidScreenshotRegion)
    );
    assert_eq!(
        decode(&packet(99, 0, &[])),
        Err(DecodeError::UnsupportedCommand(99))
    );
}

#[test]
fn launch_limiter_holds_capacity_until_permits_are_dropped() {
    let limiter = LaunchLimiter::new(2);
    let first = limiter.try_acquire().expect("first launch fits");
    let second = limiter.try_acquire().expect("second launch fits");
    assert!(limiter.try_acquire().is_none());
    assert_eq!(limiter.active.load(Ordering::Acquire), 2);

    drop(first);
    let replacement = limiter.try_acquire().expect("reaped launch frees capacity");
    assert_eq!(limiter.active.load(Ordering::Acquire), 2);
    drop((second, replacement));
    assert_eq!(limiter.active.load(Ordering::Acquire), 0);
}

#[test]
fn stale_reaper_failure_cannot_invalidate_a_replacement() {
    let (sender, _receiver) = mpsc::channel::<TrackedChild>();
    let mut slot = ReaperSlot {
        next_generation: 8,
        active: Some(ReaperSender {
            generation: 8,
            sender,
        }),
    };
    slot.invalidate(7);
    assert_eq!(
        slot.active.as_ref().map(|sender| sender.generation),
        Some(8)
    );
    slot.invalidate(8);
    assert!(slot.active.is_none());
}

#[test]
fn builds_a_direct_process_with_denial_wayland_environment() {
    let arguments = vec!["foot".into(), "--title".into(), "hello world".into()];
    let command = application_command(
        &arguments,
        NonZeroU64::new(17),
        Some("denial-test-activation"),
        OsStr::new("wayland-7"),
        Some(OsStr::new(":42")),
        Some(OsStr::new("/run/user/1000/denial/control.sock")),
        None,
        &ApplicationEnvironment::default(),
        None,
    );
    assert_eq!(command.get_program(), OsStr::new("foot"));
    assert_eq!(
        command.get_args().collect::<Vec<_>>(),
        [OsStr::new("--title"), OsStr::new("hello world")]
    );
    let environment = command
        .get_envs()
        .map(|(key, value)| (key.to_owned(), value.map(OsStr::to_owned)))
        .collect::<std::collections::BTreeMap<_, _>>();
    assert_eq!(
        environment.get(OsStr::new("WAYLAND_DISPLAY")),
        Some(&Some(OsString::from("wayland-7")))
    );
    assert_eq!(
        environment.get(OsStr::new("DISPLAY")),
        Some(&Some(OsString::from(":42")))
    );
    assert_eq!(
        environment.get(OsStr::new("XDG_CURRENT_DESKTOP")),
        Some(&Some(OsString::from("Denial")))
    );
    assert_eq!(
        environment.get(OsStr::new("QT_QPA_PLATFORMTHEME")),
        Some(&Some(OsString::from("xdgdesktopportal")))
    );
    assert!(!environment.contains_key(OsStr::new("XMODIFIERS")));
    assert_eq!(
        environment.get(OsStr::new("DENIAL_SOCKET")),
        Some(&Some(OsString::from("/run/user/1000/denial/control.sock")))
    );
    assert_eq!(
        environment.get(OsStr::new("DENIA_LAUNCH_REQUEST_ID")),
        Some(&Some(OsString::from("17")))
    );
    assert_eq!(
        environment.get(OsStr::new("XDG_ACTIVATION_TOKEN")),
        Some(&Some(OsString::from("denial-test-activation")))
    );
    assert_eq!(environment.get(OsStr::new("AQ_DRM_DEVICES")), Some(&None));
    assert_eq!(
        environment.get(OsStr::new("__EGL_VENDOR_LIBRARY_FILENAMES")),
        Some(&None)
    );
    assert_eq!(environment.get(OsStr::new("NO_COLOR")), Some(&None));
    for inherited in [
        "PATH",
        "LANG",
        "LC_ALL",
        "TERM",
        "COLORTERM",
        "HOME",
        "XMODIFIERS",
    ] {
        assert_eq!(
            environment.get(OsStr::new(inherited)),
            None,
            "{inherited} must be inherited from the user session"
        );
    }
    for variable in APPLICATION_ENVIRONMENT_REMOVALS
        .iter()
        .copied()
        .filter(|variable| {
            !matches!(
                *variable,
                "DENIA_LAUNCH_REQUEST_ID" | "DENIAL_SOCKET" | "DISPLAY" | "XDG_ACTIVATION_TOKEN"
            )
        })
    {
        assert_eq!(
            environment.get(OsStr::new(variable)),
            Some(&None),
            "{variable} leaked into the application command"
        );
    }
}

#[test]
fn launch_without_output_control_removes_an_inherited_stale_socket() {
    let command = application_command(
        &["foot".into()],
        None,
        None,
        OsStr::new("wayland-7"),
        None,
        None,
        Some(OsStr::new("kde")),
        &ApplicationEnvironment::default(),
        None,
    );
    let environment = command
        .get_envs()
        .map(|(key, value)| (key.to_owned(), value.map(OsStr::to_owned)))
        .collect::<std::collections::BTreeMap<_, _>>();

    assert_eq!(environment.get(OsStr::new("DENIAL_SOCKET")), Some(&None));
    assert_eq!(
        environment.get(OsStr::new("XDG_ACTIVATION_TOKEN")),
        Some(&None)
    );
    assert_eq!(
        environment.get(OsStr::new("QT_QPA_PLATFORMTHEME")),
        Some(&Some(OsString::from("kde")))
    );
}

#[test]
fn parses_set_empty_and_remove_application_environment_overrides() {
    let environment = ApplicationEnvironment::parse(
        br#"{
            "MOZ_ENABLE_WAYLAND": "1",
            "GTK_THEME": "",
            "DISPLAY": null
        }"#,
    )
    .expect("valid application environment");

    assert_eq!(environment.value("MOZ_ENABLE_WAYLAND"), Some(Some("1")));
    assert_eq!(environment.value("GTK_THEME"), Some(Some("")));
    assert_eq!(environment.value("DISPLAY"), Some(None));
    assert_eq!(environment.value("MISSING"), None);

    let error = ApplicationEnvironment::parse(br#"{"invalid-name": "value"}"#)
        .expect_err("invalid environment name");
    assert!(
        error
            .to_string()
            .contains("invalid environment variable name")
    );
    assert!(
        ApplicationEnvironment::parse(br#"{"VALID": 3}"#).is_err(),
        "non-string environment values must be rejected"
    );

    let layered = ApplicationEnvironment::parse(
        br#"{
            "default": {"MODE": "global"},
            "applications": {
                "org.example.App.desktop": {"MODE": "app", "GLOBAL_ONLY": null}
            }
        }"#,
    )
    .expect("layered application environment");
    assert_eq!(layered.value("MODE"), Some(Some("global")));
    assert_eq!(
        layered.application_value("org.example.App.desktop", "MODE"),
        Some(Some("app"))
    );
    assert_eq!(
        layered.application_value("org.example.App.desktop", "GLOBAL_ONLY"),
        Some(None)
    );
}

#[test]
fn desktop_application_environment_layers_over_the_default_scope() {
    let application_environment = ApplicationEnvironment::parse(
        br#"{
            "default": {"DEFAULT_ONLY": "1", "MODE": "global", "REMOVE_ME": "set"},
            "applications": {
                "org.example.App.desktop": {
                    "MODE": "app",
                    "REMOVE_ME": null,
                    "APP_ONLY": "2"
                }
            }
        }"#,
    )
    .expect("layered application environment");
    let command = application_command(
        &["foot".into()],
        None,
        None,
        OsStr::new("wayland-7"),
        None,
        None,
        None,
        &application_environment,
        Some("org.example.App.desktop"),
    );
    let environment = command
        .get_envs()
        .map(|(key, value)| (key.to_owned(), value.map(OsStr::to_owned)))
        .collect::<std::collections::BTreeMap<_, _>>();

    assert_eq!(
        environment.get(OsStr::new("DEFAULT_ONLY")),
        Some(&Some(OsString::from("1")))
    );
    assert_eq!(
        environment.get(OsStr::new("MODE")),
        Some(&Some(OsString::from("app")))
    );
    assert_eq!(environment.get(OsStr::new("REMOVE_ME")), Some(&None));
    assert_eq!(
        environment.get(OsStr::new("APP_ONLY")),
        Some(&Some(OsString::from("2")))
    );
}

#[test]
fn application_environment_overrides_defaults_but_not_launch_metadata() {
    let application_environment = ApplicationEnvironment::parse(
        br#"{
            "DISPLAY": null,
            "QT_QPA_PLATFORMTHEME": "kde",
            "NO_COLOR": "1",
            "XDG_ACTIVATION_TOKEN": "stale",
            "DENIA_LAUNCH_REQUEST_ID": "999"
        }"#,
    )
    .expect("valid application environment");
    let command = application_command(
        &["foot".into()],
        NonZeroU64::new(17),
        Some("fresh-token"),
        OsStr::new("wayland-7"),
        Some(OsStr::new(":42")),
        Some(OsStr::new("/run/user/1000/denial/control.sock")),
        None,
        &application_environment,
        None,
    );
    let environment = command
        .get_envs()
        .map(|(key, value)| (key.to_owned(), value.map(OsStr::to_owned)))
        .collect::<std::collections::BTreeMap<_, _>>();

    assert_eq!(environment.get(OsStr::new("DISPLAY")), Some(&None));
    assert_eq!(
        environment.get(OsStr::new("QT_QPA_PLATFORMTHEME")),
        Some(&Some(OsString::from("kde")))
    );
    assert_eq!(
        environment.get(OsStr::new("NO_COLOR")),
        Some(&Some(OsString::from("1")))
    );
    assert_eq!(
        environment.get(OsStr::new("XDG_ACTIVATION_TOKEN")),
        Some(&Some(OsString::from("fresh-token")))
    );
    assert_eq!(
        environment.get(OsStr::new("DENIA_LAUNCH_REQUEST_ID")),
        Some(&Some(OsString::from("17")))
    );
}
