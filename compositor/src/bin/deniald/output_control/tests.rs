use super::*;
use smithay::reexports::calloop::EventLoop;
use smithay::reexports::calloop::channel::Event as ChannelEvent;
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_DIRECTORY: AtomicU64 = AtomicU64::new(1);

fn state(name: &str) -> OutputControlState {
    OutputControlState {
        capabilities: OutputControlCapabilities::default(),
        primary_output: None,
        outputs: vec![OutputControlOutput {
            monitor_id: 1,
            name: name.into(),
            description: name.into(),
            connected: true,
            enabled: true,
            powered: true,
            x: 0,
            y: 0,
            logical_width: 1920,
            logical_height: 1080,
            physical_width_mm: Some(600),
            physical_height_mm: Some(340),
            scale: 1.0,
            transform: OutputTransformName::Normal,
            adaptive_sync_supported: false,
            adaptive_sync: false,
            current_mode: Some(OutputControlMode {
                width: 1920,
                height: 1080,
                refresh_millihz: 60_000,
                preferred: true,
            }),
            modes: vec![OutputControlMode {
                width: 1920,
                height: 1080,
                refresh_millihz: 60_000,
                preferred: true,
            }],
        }],
        pending_confirmation: None,
    }
}

fn socket_path() -> PathBuf {
    let suffix = NEXT_DIRECTORY.fetch_add(1, Ordering::Relaxed);
    let directory = std::env::temp_dir().join(format!(
        "denial-control-test-{}-{suffix}",
        std::process::id()
    ));
    fs::create_dir(&directory).expect("create test socket directory");
    directory.join("control.sock")
}

#[test]
fn publisher_changes_serial_only_when_public_state_changes() {
    let publisher = OutputControlPublisher::new(state("DP-1"));
    let initial = publisher.snapshot().serial;
    assert_ne!(initial, 0);
    assert!(initial <= MAX_EXACT_JSON_INTEGER);
    assert_eq!(publisher.publish(state("DP-1")).serial, initial);
    assert_eq!(
        publisher.publish(state("DP-2")).serial,
        next_serial(initial)
    );
}

#[test]
fn serials_wrap_within_the_exact_json_integer_range() {
    assert_eq!(
        next_serial(MAX_EXACT_JSON_INTEGER - 1),
        MAX_EXACT_JSON_INTEGER
    );
    assert_eq!(next_serial(MAX_EXACT_JSON_INTEGER), 1);
    assert_eq!(next_serial(u64::MAX), 1);
}

#[test]
fn control_client_slots_are_bounded_and_released() {
    let active = Arc::new(AtomicUsize::new(MAX_CLIENT_WORKERS - 1));
    let slot = ActiveControlClient::acquire(&active).expect("reserve final client slot");
    assert_eq!(active.load(Ordering::Acquire), MAX_CLIENT_WORKERS);
    assert!(ActiveControlClient::acquire(&active).is_none());

    drop(slot);
    assert_eq!(active.load(Ordering::Acquire), MAX_CLIENT_WORKERS - 1);
    assert!(ActiveControlClient::acquire(&active).is_some());
}

#[test]
fn dirty_publication_builds_once_and_clean_iterations_do_no_work() {
    let publisher = OutputControlPublisher::new(state("DP-1"));
    let mut dirty = false;
    let mut builds = 0;

    let clean = publisher
        .publish_if_dirty(&mut dirty, || {
            builds += 1;
            Ok::<_, ()>(state("DP-2"))
        })
        .expect("clean publication");
    assert!(clean.is_none());
    assert_eq!(builds, 0);

    let mark_dirty = |dirty: &mut bool| *dirty = true;
    // Repeated mutations before the publication boundary coalesce into
    // the same flag.
    mark_dirty(&mut dirty);
    mark_dirty(&mut dirty);
    let published = publisher
        .publish_if_dirty(&mut dirty, || {
            builds += 1;
            Ok::<_, ()>(state("DP-2"))
        })
        .expect("dirty publication")
        .expect("dirty state must publish");
    assert_eq!(published.outputs[0].name, "DP-2");
    assert_eq!(builds, 1);
    assert!(!dirty);

    assert!(
        publisher
            .publish_if_dirty(&mut dirty, || {
                builds += 1;
                Ok::<_, ()>(state("DP-3"))
            })
            .expect("second clean publication")
            .is_none()
    );
    assert_eq!(builds, 1);
}

#[test]
fn failed_dirty_publication_remains_dirty_for_retry() {
    let publisher = OutputControlPublisher::new(state("DP-1"));
    let mut dirty = true;
    let result = publisher.publish_if_dirty(&mut dirty, || {
        Err::<OutputControlState, _>("snapshot failed")
    });

    assert_eq!(
        result.expect_err("publication must fail"),
        "snapshot failed"
    );
    assert!(dirty);
}

#[test]
fn query_is_versioned_and_returns_the_current_snapshot() {
    let path = socket_path();
    let directory = path.parent().expect("test socket has parent").to_owned();
    let (server, _source) =
        OutputControlServer::start_at(path.clone(), state("DP-4")).expect("start server");
    let mut stream = UnixStream::connect(&path).expect("connect to server");
    stream
        .write_all(b"{\"version\":1,\"id\":17,\"method\":\"outputs.get\"}\n")
        .expect("write request");
    let mut response = String::new();
    BufReader::new(stream)
        .read_to_string(&mut response)
        .expect("read response");
    let response: Value = serde_json::from_str(&response).expect("decode response");

    assert_eq!(response["version"], 1);
    assert_eq!(response["id"], 17);
    assert_eq!(response["ok"], true);
    assert!(
        response["result"]["serial"]
            .as_u64()
            .is_some_and(|serial| serial != 0)
    );
    assert_eq!(response["result"]["outputs"][0]["name"], "DP-4");
    assert_eq!(response["result"]["outputs"][0]["monitor_id"], 1);
    assert_eq!(
        response["result"]["outputs"][0]["adaptive_sync_supported"],
        false
    );

    drop(server);
    fs::remove_dir(directory).expect("remove test socket directory");
}

#[test]
fn settings_subscription_starts_with_a_snapshot_and_streams_new_revisions() {
    let path = socket_path();
    let directory = path.parent().expect("test socket has parent").to_owned();
    let (server, _source) =
        OutputControlServer::start_at(path.clone(), state("DP-4")).expect("start server");
    let publisher = server.publisher();
    let mut subscription = UnixStream::connect(&path).expect("connect subscription");
    subscription
        .write_all(b"{\"version\":1,\"id\":18,\"method\":\"settings.document.subscribe\"}\n")
        .expect("write subscription request");
    let mut subscription = BufReader::new(subscription);
    let mut line = String::new();
    subscription
        .read_line(&mut line)
        .expect("read initial settings snapshot");
    let initial: Value = serde_json::from_str(&line).expect("decode initial snapshot");
    assert_eq!(initial["id"], 18);
    assert_eq!(initial["result"]["revision"], 1);
    assert_eq!(initial["result"]["document"], "{}");

    assert!(publisher.publish_settings_document(2, "{\"version\":10}".to_owned()));
    line.clear();
    subscription
        .read_line(&mut line)
        .expect("read changed settings snapshot");
    let changed: Value = serde_json::from_str(&line).expect("decode changed snapshot");
    assert_eq!(changed["result"]["revision"], 2);
    assert_eq!(changed["result"]["document"], "{\"version\":10}");

    // A persistent subscriber must not serialize unrelated control clients
    // behind itself.
    let mut query = UnixStream::connect(&path).expect("connect parallel query");
    query
        .write_all(b"{\"version\":1,\"id\":19,\"method\":\"outputs.get\"}\n")
        .expect("write parallel query");
    let mut response = String::new();
    BufReader::new(query)
        .read_to_string(&mut response)
        .expect("read parallel query response");
    let response: Value = serde_json::from_str(&response).expect("decode parallel response");
    assert_eq!(response["id"], 19);
    assert_eq!(response["ok"], true);

    drop(subscription);
    drop(server);
    fs::remove_dir(directory).expect("remove test socket directory");
}

#[test]
fn apply_is_handed_to_the_compositor_event_loop_and_replies_once() {
    let path = socket_path();
    let directory = path.parent().expect("test socket has parent").to_owned();
    let (server, source) =
        OutputControlServer::start_at(path.clone(), state("DP-4")).expect("start server");
    let publisher = server.publisher();
    let serial = publisher.snapshot().serial;
    let mut event_loop = EventLoop::<()>::try_new().expect("create event loop");
    event_loop
        .handle()
        .insert_source(source, move |event, _, _| {
            if let ChannelEvent::Msg(ControlEvent::OutputApply(request)) = event {
                assert_eq!(request.configuration.serial, serial);
                assert_eq!(
                    request.configuration.primary_output.as_deref(),
                    Some("DP-4")
                );
                assert_eq!(request.configuration.outputs[0].name, "DP-4");
                request.reply(Ok(publisher.snapshot()));
            }
        })
        .expect("insert Denial control source");

    let client = thread::spawn(move || {
        let mut stream = UnixStream::connect(&path).expect("connect to server");
        let request = format!(
            "{{\"version\":1,\"id\":23,\"method\":\"outputs.apply\",\"params\":{{\"serial\":{serial},\"primary_output\":\"DP-4\",\"outputs\":[{{\"name\":\"DP-4\",\"enabled\":true,\"powered\":true,\"x\":0,\"y\":0,\"mode\":{{\"width\":1920,\"height\":1080,\"refresh_millihz\":60000}},\"scale\":1.0,\"transform\":\"normal\",\"adaptive_sync\":false}}]}}}}\n"
        );
        stream
            .write_all(request.as_bytes())
            .expect("write apply request");
        let mut response = String::new();
        BufReader::new(stream)
            .read_to_string(&mut response)
            .expect("read apply response");
        serde_json::from_str::<Value>(&response).expect("decode apply response")
    });

    event_loop
        .dispatch(Duration::from_secs(1), &mut ())
        .expect("dispatch output apply");
    let response = client.join().expect("join Denial control client");
    assert_eq!(response["id"], 23);
    assert_eq!(response["ok"], true);
    assert_eq!(response["result"]["outputs"][0]["name"], "DP-4");

    drop(server);
    fs::remove_dir(directory).expect("remove test socket directory");
}

#[test]
fn output_confirmation_is_handed_to_the_compositor_event_loop() {
    let path = socket_path();
    let directory = path.parent().expect("test socket has parent").to_owned();
    let (server, source) =
        OutputControlServer::start_at(path.clone(), state("DP-4")).expect("start server");
    let mut event_loop = EventLoop::<()>::try_new().expect("create event loop");
    event_loop
        .handle()
        .insert_source(source, move |event, _, _| {
            if let ChannelEvent::Msg(ControlEvent::OutputConfirmation(request)) = event {
                assert_eq!(request.token, 41);
                assert_eq!(request.action, OutputConfirmationAction::Keep);
                request.reply(Ok(()));
            }
        })
        .expect("insert Denial control source");

    let client = thread::spawn(move || {
        let mut stream = UnixStream::connect(&path).expect("connect to server");
        stream
            .write_all(
                b"{\"version\":1,\"id\":24,\"method\":\"outputs.confirm\",\"params\":{\"token\":41}}\n",
            )
            .expect("write confirmation request");
        let mut response = String::new();
        BufReader::new(stream)
            .read_to_string(&mut response)
            .expect("read confirmation response");
        serde_json::from_str::<Value>(&response).expect("decode confirmation response")
    });

    event_loop
        .dispatch(Duration::from_secs(1), &mut ())
        .expect("dispatch output confirmation");
    let response = client.join().expect("join Denial control client");
    assert_eq!(response["id"], 24);
    assert_eq!(response["ok"], true);

    drop(server);
    fs::remove_dir(directory).expect("remove test socket directory");
}

#[test]
fn wallpaper_open_is_handed_to_the_compositor_event_loop() {
    let path = socket_path();
    let directory = path.parent().expect("test socket has parent").to_owned();
    let (server, source) =
        OutputControlServer::start_at(path.clone(), state("DP-4")).expect("start server");
    let mut event_loop = EventLoop::<()>::try_new().expect("create event loop");
    event_loop
        .handle()
        .insert_source(source, move |event, _, _| {
            if let ChannelEvent::Msg(ControlEvent::Shell(request)) = event {
                assert_eq!(request.command, ShellControlCommand::OpenWallpaper);
                request.reply(Ok(()));
            }
        })
        .expect("insert Denial control source");

    let client = thread::spawn(move || {
        let mut stream = UnixStream::connect(&path).expect("connect to server");
        stream
            .write_all(b"{\"version\":1,\"id\":25,\"method\":\"shell.wallpaper.open\"}\n")
            .expect("write wallpaper request");
        let mut response = String::new();
        BufReader::new(stream)
            .read_to_string(&mut response)
            .expect("read wallpaper response");
        serde_json::from_str::<Value>(&response).expect("decode wallpaper response")
    });

    event_loop
        .dispatch(Duration::from_secs(1), &mut ())
        .expect("dispatch wallpaper request");
    let response = client.join().expect("join Denial control client");
    assert_eq!(response["id"], 25);
    assert_eq!(response["ok"], true);
    assert_eq!(response["result"], json!({}));

    drop(server);
    fs::remove_dir(directory).expect("remove test socket directory");
}

#[test]
fn ui_query_is_handed_to_the_compositor_event_loop() {
    let path = socket_path();
    let directory = path.parent().expect("test socket has parent").to_owned();
    let (server, source) =
        OutputControlServer::start_at(path.clone(), state("DP-4")).expect("start server");
    let mut controller = super::super::ui_development::UiDevelopmentController::new(
        Path::new("/packaged/ui"),
        None,
        None,
    );
    let mut event_loop = EventLoop::<()>::try_new().expect("create event loop");
    event_loop
        .handle()
        .insert_source(source, move |event, _, _| {
            if let ChannelEvent::Msg(ControlEvent::UiDevelopment(request)) = event {
                assert_eq!(
                    controller.handle_command(request.command.clone()),
                    super::super::ui_development::UiDevelopmentEffect::None
                );
                request.reply(Ok(controller.state_snapshot()));
            }
        })
        .expect("insert Denial control source");

    let client = thread::spawn(move || {
        let mut stream = UnixStream::connect(&path).expect("connect to server");
        stream
            .write_all(b"{\"version\":1,\"id\":29,\"method\":\"ui.get\"}\n")
            .expect("write UI query");
        let mut response = String::new();
        BufReader::new(stream)
            .read_to_string(&mut response)
            .expect("read UI response");
        serde_json::from_str::<Value>(&response).expect("decode UI response")
    });

    event_loop
        .dispatch(Duration::from_secs(1), &mut ())
        .expect("dispatch UI query");
    let response = client.join().expect("join Denial control client");
    assert_eq!(response["id"], 29);
    assert_eq!(response["ok"], true);
    assert_eq!(response["result"]["active_mode"], "official_optimized");

    drop(server);
    fs::remove_dir(directory).expect("remove test socket directory");
}

#[test]
fn settings_query_is_handed_to_the_compositor_event_loop() {
    let path = socket_path();
    let directory = path.parent().expect("test socket has parent").to_owned();
    let (server, source) =
        OutputControlServer::start_at(path.clone(), state("DP-4")).expect("start server");
    let mut event_loop = EventLoop::<()>::try_new().expect("create event loop");
    event_loop
        .handle()
        .insert_source(source, move |event, _, _| {
            if let ChannelEvent::Msg(ControlEvent::Settings(request)) = event {
                let (command, reply) = request.into_parts();
                assert!(matches!(command, SettingsControlCommand::ReadDocument));
                reply
                    .send(Ok(json!({"revision": 4, "document": "{}"})))
                    .expect("reply to settings query");
            }
        })
        .expect("insert Denial control source");

    let client = thread::spawn(move || {
        let mut stream = UnixStream::connect(&path).expect("connect to server");
        stream
            .write_all(b"{\"version\":1,\"id\":30,\"method\":\"settings.document.get\"}\n")
            .expect("write settings query");
        let mut response = String::new();
        BufReader::new(stream)
            .read_to_string(&mut response)
            .expect("read settings response");
        serde_json::from_str::<Value>(&response).expect("decode settings response")
    });

    event_loop
        .dispatch(Duration::from_secs(1), &mut ())
        .expect("dispatch settings query");
    let response = client.join().expect("join Denial control client");
    assert_eq!(response["id"], 30);
    assert_eq!(response["ok"], true);
    assert_eq!(response["result"]["revision"], 4);

    drop(server);
    fs::remove_dir(directory).expect("remove test socket directory");
}

#[test]
fn system_control_query_is_handed_to_the_compositor_event_loop() {
    let path = socket_path();
    let directory = path.parent().expect("test socket has parent").to_owned();
    let (server, source) =
        OutputControlServer::start_at(path.clone(), state("DP-4")).expect("start server");
    let mut event_loop = EventLoop::<()>::try_new().expect("create event loop");
    event_loop
        .handle()
        .insert_source(source, move |event, _, _| {
            if let ChannelEvent::Msg(ControlEvent::SystemControl(request)) = event {
                let (command, reply) = request.into_parts();
                assert!(matches!(
                    command,
                    SystemControlCommand::Audio(AudioRequest::ReadLevel)
                ));
                reply
                    .send(Ok(json!({"level": 0.65, "request_serial": 0})))
                    .expect("reply to system-control query");
            }
        })
        .expect("insert Denial control source");

    let client = thread::spawn(move || {
        let mut stream = UnixStream::connect(&path).expect("connect to server");
        stream
            .write_all(b"{\"version\":1,\"id\":32,\"method\":\"audio.get\"}\n")
            .expect("write audio query");
        let mut response = String::new();
        BufReader::new(stream)
            .read_to_string(&mut response)
            .expect("read audio response");
        serde_json::from_str::<Value>(&response).expect("decode audio response")
    });

    event_loop
        .dispatch(Duration::from_secs(1), &mut ())
        .expect("dispatch audio query");
    let response = client.join().expect("join Denial control client");
    assert_eq!(response["id"], 32);
    assert_eq!(response["ok"], true);
    assert_eq!(response["result"]["level"], 0.65);

    drop(server);
    fs::remove_dir(directory).expect("remove test socket directory");
}

#[test]
fn unsupported_versions_fail_without_entering_the_apply_queue() {
    let path = socket_path();
    let directory = path.parent().expect("test socket has parent").to_owned();
    let (server, _source) =
        OutputControlServer::start_at(path.clone(), state("DP-4")).expect("start server");
    let mut stream = UnixStream::connect(&path).expect("connect to server");
    stream
        .write_all(b"{\"version\":99,\"id\":31,\"method\":\"outputs.get\"}\n")
        .expect("write request");
    let mut response = String::new();
    BufReader::new(stream)
        .read_to_string(&mut response)
        .expect("read response");
    let response: Value = serde_json::from_str(&response).expect("decode response");

    assert_eq!(response["id"], 31);
    assert_eq!(response["ok"], false);
    assert_eq!(response["error"]["code"], "unsupported_version");

    drop(server);
    fs::remove_dir(directory).expect("remove test socket directory");
}

#[test]
fn request_decoder_accepts_the_nwg_facing_transform_names() {
    let request = serde_json::from_value::<ApplyOutputConfiguration>(json!({
        "serial": 9,
        "outputs": [{
            "name": "DP-4",
            "enabled": true,
            "powered": true,
            "x": 0,
            "y": 0,
            "mode": {
                "width": 2560,
                "height": 1440,
                "refresh_millihz": 199998
            },
            "scale": 1.0,
            "transform": "flipped-90",
            "adaptive_sync": true
        }]
    }))
    .expect("decode apply request");

    assert_eq!(request.serial, 9);
    assert_eq!(request.outputs[0].transform, OutputTransformName::Flipped90);
}

#[test]
fn stale_non_socket_paths_are_never_replaced() {
    let path = socket_path();
    fs::File::create(&path).expect("create sentinel");
    let error = prepare_socket_path(&path).expect_err("regular file must be preserved");
    assert!(
        error
            .to_string()
            .contains("refusing to replace non-socket Denial control")
    );
    assert!(path.is_file());

    fs::remove_file(&path).expect("remove sentinel");
    fs::remove_dir(path.parent().expect("test socket has parent"))
        .expect("remove test socket directory");
}

#[test]
fn shutdown_never_unlinks_a_replacement_path() {
    let path = socket_path();
    let directory = path.parent().expect("test socket has parent").to_owned();
    let displaced = directory.join("displaced.sock");
    let (server, _source) =
        OutputControlServer::start_at(path.clone(), state("DP-4")).expect("start server");
    fs::rename(&path, &displaced).expect("move owned socket");
    fs::File::create(&path).expect("create replacement sentinel");

    drop(server);

    assert!(path.is_file());
    fs::remove_file(path).expect("remove replacement sentinel");
    fs::remove_file(displaced).expect("remove displaced socket");
    fs::remove_dir(directory).expect("remove test socket directory");
}
