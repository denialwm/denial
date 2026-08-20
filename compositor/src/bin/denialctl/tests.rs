use super::*;
use std::io::BufRead;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_DIRECTORY: AtomicU64 = AtomicU64::new(1);

fn parse(arguments: &[&str]) -> Options {
    Options::parse(arguments.iter().map(OsString::from)).expect("parse command")
}

fn socket_path() -> (PathBuf, PathBuf) {
    let suffix = NEXT_DIRECTORY.fetch_add(1, Ordering::Relaxed);
    let directory = env::temp_dir().join(format!("denialctl-test-{}-{suffix}", std::process::id()));
    fs::create_dir(&directory).expect("create test directory");
    let socket = directory.join("control.sock");
    (directory, socket)
}

fn write_ui_source_fixture(root: &Path) {
    fs::create_dir_all(root.join("dart_shell/lib")).expect("create fixture shell");
    fs::create_dir_all(root.join("protocol/generated/dart"))
        .expect("create fixture protocol package");
    fs::write(
        root.join(".gitignore"),
        format!("/{UI_SOURCE_MARKER}\n").as_bytes(),
    )
    .expect("write fixture ignore file");
    fs::write(root.join("dart_shell/pubspec.yaml"), b"name: denial_ui\n")
        .expect("write fixture pubspec");
    fs::write(root.join("dart_shell/lib/main.dart"), b"void main() {}\n")
        .expect("write fixture entrypoint");
    fs::write(
        root.join("protocol/generated/dart/pubspec.yaml"),
        b"name: denial_wire_protocol\n",
    )
    .expect("write fixture protocol pubspec");
}

fn test_git(repository: &Path, arguments: &[&str]) -> String {
    let output = ProcessCommand::new(SYSTEM_GIT)
        .arg("-C")
        .arg(repository)
        .args(arguments)
        .output()
        .expect("start fixture Git");
    assert!(
        output.status.success(),
        "fixture Git failed: {}\n{}",
        output.status,
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}

#[test]
fn parses_recovery_and_machine_output_options() {
    let options = parse(&["--json", "--no-wait", "ui", "restore"]);
    assert!(options.json);
    assert!(!options.wait);
    assert!(matches!(
        options.command,
        Command::UiAction {
            method: "ui.restore",
            expected_mode: Some("official_optimized")
        }
    ));
}

#[test]
fn parses_live_mode_switches() {
    assert!(matches!(
        parse(&["ui", "live", "on"]).command,
        Command::UiLive(true)
    ));
    assert!(matches!(
        parse(&["ui", "dev", "disable"]).command,
        Command::UiLive(false)
    ));
}

#[test]
fn parses_aot_profile_activation() {
    for command in [["ui", "profile"], ["ui", "build"]] {
        assert!(matches!(
            parse(&command).command,
            Command::UiAction {
                method: "ui.build",
                expected_mode: Some("custom_optimized")
            }
        ));
    }
}

#[test]
fn parses_ui_setup_with_optional_destination() {
    assert!(matches!(
        parse(&["ui", "setup"]).command,
        Command::UiSetup(None)
    ));
    assert!(matches!(
        parse(&["ui", "setup", "/tmp/DenialUI"]).command,
        Command::UiSetup(Some(path)) if path == Path::new("/tmp/DenialUI")
    ));
}

#[test]
fn materializes_ui_source_without_overwriting_existing_edits() {
    let (directory, _) = socket_path();
    let repository = directory.join("repository");
    let template = directory.join("template");
    let destination = directory.join("DenialUI");
    fs::create_dir(&repository).expect("create fixture repository");
    fs::create_dir(&template).expect("create fixture template");
    write_ui_source_fixture(&repository);
    write_ui_source_fixture(&template);

    test_git(&repository, &["init", "--initial-branch=main"]);
    test_git(&repository, &["config", "user.name", "Denial Test"]);
    test_git(
        &repository,
        &["config", "user.email", "denial-test@invalid"],
    );
    test_git(&repository, &["add", "."]);
    test_git(&repository, &["commit", "--quiet", "-m", "UI fixture"]);
    let revision = test_git(&repository, &["rev-parse", "HEAD"]);
    fs::write(
        template.join(UI_SOURCE_MARKER),
        format!(
            r#"{{"schema_version":1,"ui_development_api":1,"flutter_generation":"3.44.7.denial1","source_ref":"main","source_revision":"{revision}","workspace":"dart_shell"}}"#
        ),
    )
    .expect("write source marker");

    let (workspace, created) = materialize_ui_source(
        &template,
        Path::new(SYSTEM_GIT),
        repository.as_os_str(),
        &destination,
    )
    .expect("materialize source");
    assert!(created);
    assert_eq!(workspace, destination.join("dart_shell"));
    assert!(destination.join(".git").is_dir());
    assert_eq!(
        test_git(&destination, &["remote", "get-url", "origin"]),
        repository.to_string_lossy()
    );
    assert_eq!(
        test_git(&destination, &["branch", "--show-current"]),
        "main"
    );
    assert_eq!(
        test_git(&destination, &["config", "--get", "branch.main.remote"]),
        "origin"
    );
    assert_eq!(
        test_git(&destination, &["config", "--get", "branch.main.merge"]),
        "refs/heads/main"
    );
    assert_eq!(test_git(&destination, &["rev-parse", "HEAD"]), revision);
    assert_eq!(test_git(&destination, &["status", "--porcelain"]), "");
    fs::write(
        destination.join("dart_shell/lib/main.dart"),
        b"void main() => print('custom');\n",
    )
    .expect("customize source");

    let (_, created) = materialize_ui_source(
        &template,
        Path::new(SYSTEM_GIT),
        repository.as_os_str(),
        &destination,
    )
    .expect("reuse source");
    assert!(!created);
    assert_eq!(
        fs::read_to_string(destination.join("dart_shell/lib/main.dart"))
            .expect("read customized source"),
        "void main() => print('custom');\n"
    );
    fs::write(
        destination.join(UI_SOURCE_MARKER),
        format!(
            r#"{{"schema_version":1,"ui_development_api":1,"flutter_generation":"future","source_ref":"main","source_revision":"{revision}","workspace":"dart_shell"}}"#
        ),
    )
    .expect("replace source marker");
    let error = materialize_ui_source(
        &template,
        Path::new(SYSTEM_GIT),
        repository.as_os_str(),
        &destination,
    )
    .expect_err("incompatible source must be rejected");
    assert!(error.to_string().contains("incompatible"));
    assert_eq!(
        fs::read_to_string(destination.join("dart_shell/lib/main.dart"))
            .expect("read preserved source"),
        "void main() => print('custom');\n"
    );

    fs::remove_dir_all(directory).expect("remove test directory");
}

#[test]
fn rejects_unknown_commands() {
    let error = Options::parse([OsString::from("explode")]).expect_err("unknown command must fail");
    assert!(error.to_string().contains("denialctl --help"));
}

#[test]
fn socket_discovery_prefers_the_explicit_path() {
    let path = resolve_socket_path(Some(Path::new("/tmp/denial.sock"))).unwrap();
    assert_eq!(path, Path::new("/tmp/denial.sock"));
}

#[test]
fn rejects_non_private_control_sockets() {
    let (directory, socket) = socket_path();
    let listener = UnixListener::bind(&socket).expect("bind test socket");
    fs::set_permissions(&socket, fs::Permissions::from_mode(0o660))
        .expect("set unsafe permissions");

    let error = validate_socket(&socket).expect_err("shared socket must be rejected");
    assert!(error.to_string().contains("unsafe permissions"));

    drop(listener);
    fs::remove_file(socket).expect("remove test socket");
    fs::remove_dir(directory).expect("remove test directory");
}

#[test]
fn sends_versioned_requests_and_validates_responses() {
    let (directory, socket) = socket_path();
    let listener = UnixListener::bind(&socket).expect("bind test socket");
    fs::set_permissions(&socket, fs::Permissions::from_mode(0o600))
        .expect("set private permissions");
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept client");
        let mut line = String::new();
        BufReader::new(stream.try_clone().expect("clone test stream"))
            .read_line(&mut line)
            .expect("read request");
        let request: Value = serde_json::from_str(&line).expect("decode request");
        assert_eq!(request["version"], PROTOCOL_VERSION);
        assert_eq!(request["id"], 1);
        assert_eq!(request["method"], "ui.get");
        assert!(request["params"].is_null());
        serde_json::to_writer(
            &mut stream,
            &json!({
                "version": PROTOCOL_VERSION,
                "id": 1,
                "ok": true,
                "result": {"active_mode": "official_optimized"},
            }),
        )
        .expect("write response");
        stream.write_all(b"\n").expect("terminate response");
    });

    let mut client = ControlClient::new(socket.clone());
    let response = client
        .request("ui.get", Value::Null)
        .expect("perform control request");
    assert_eq!(response.id, 1);
    assert_eq!(response.result["active_mode"], "official_optimized");

    server.join().expect("join test server");
    fs::remove_file(socket).expect("remove test socket");
    fs::remove_dir(directory).expect("remove test directory");
}
