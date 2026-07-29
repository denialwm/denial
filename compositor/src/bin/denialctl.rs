#![forbid(unsafe_code)]

use std::env;
use std::error::Error;
use std::ffi::{OsStr, OsString};
use std::fmt;
use std::fs;
use std::io::{BufReader, Read, Write};
use std::os::unix::fs::{FileTypeExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::path::{Component, Path, PathBuf};
use std::process::{Command as ProcessCommand, ExitCode};
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::{Value, json};

const PROTOCOL_VERSION: u32 = 1;
const MAX_RESPONSE_BYTES: usize = 4 * 1024 * 1024;
const IO_TIMEOUT: Duration = Duration::from_secs(25);
const MODE_SWITCH_TIMEOUT: Duration = Duration::from_secs(15);
const POLL_INTERVAL: Duration = Duration::from_millis(75);
const SYSTEM_UI_SOURCE_TEMPLATE: &str = "/usr/share/denial/ui-development/workspace";
const SYSTEM_UI_TOOL: &str = "/usr/bin/denial-ui";
const SYSTEM_GIT: &str = "/usr/bin/git";
const DENIAL_GIT_REMOTE: &str = "https://github.com/denialwm/denial.git";
const UI_SOURCE_MARKER: &str = ".denial-ui-source.json";
const MAX_SOURCE_MARKER_BYTES: usize = 64 * 1024;
const MAX_TOOL_OUTPUT_BYTES: usize = 64 * 1024;
static TEMPORARY_SEQUENCE: AtomicU64 = AtomicU64::new(0);

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("denialctl: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), CliError> {
    let options = Options::parse(env::args_os().skip(1))?;
    if matches!(options.command, Command::Help) {
        print_help();
        return Ok(());
    }
    if matches!(options.command, Command::Version) {
        println!("denialctl {}", denial_core::version());
        return Ok(());
    }

    let socket = resolve_socket_path(options.socket.as_deref())?;
    let mut client = ControlClient::new(socket);
    execute(&mut client, &options)
}

#[derive(Debug)]
struct Options {
    json: bool,
    wait: bool,
    socket: Option<PathBuf>,
    command: Command,
}

#[derive(Debug)]
enum Command {
    Help,
    Version,
    Status,
    Outputs,
    UiStatus,
    UiSetup(Option<PathBuf>),
    UiWorkspace(PathBuf),
    UiLive(bool),
    UiAction {
        method: &'static str,
        expected_mode: Option<&'static str>,
    },
    UiAutoReload(bool),
    UiVmService,
}

impl Options {
    fn parse(arguments: impl IntoIterator<Item = OsString>) -> Result<Self, CliError> {
        let mut arguments = arguments.into_iter().peekable();
        let mut json = false;
        let mut wait = true;
        let mut socket = None;

        while let Some(argument) = arguments.peek() {
            if argument.as_os_str() == OsStr::new("--json") {
                json = true;
                arguments.next();
            } else if argument.as_os_str() == OsStr::new("--no-wait") {
                wait = false;
                arguments.next();
            } else if argument.as_os_str() == OsStr::new("--socket") {
                arguments.next();
                socket =
                    Some(PathBuf::from(arguments.next().ok_or_else(|| {
                        CliError::usage("--socket requires a path")
                    })?));
            } else if argument.as_os_str() == OsStr::new("--help")
                || argument.as_os_str() == OsStr::new("-h")
            {
                return Ok(Self {
                    json,
                    wait,
                    socket,
                    command: Command::Help,
                });
            } else if argument.as_os_str() == OsStr::new("--version")
                || argument.as_os_str() == OsStr::new("-V")
            {
                return Ok(Self {
                    json,
                    wait,
                    socket,
                    command: Command::Version,
                });
            } else if argument.to_string_lossy().starts_with('-') {
                return Err(CliError::usage(format!(
                    "unknown option {}",
                    argument.to_string_lossy()
                )));
            } else {
                break;
            }
        }

        let command = parse_command(arguments.collect())?;
        Ok(Self {
            json,
            wait,
            socket,
            command,
        })
    }
}

fn parse_command(arguments: Vec<OsString>) -> Result<Command, CliError> {
    let words = arguments
        .iter()
        .map(|argument| argument.to_str())
        .collect::<Option<Vec<_>>>()
        .ok_or_else(|| CliError::usage("command arguments must be valid UTF-8"))?;
    match words.as_slice() {
        [] => Err(CliError::usage("a command is required")),
        ["help"] => Ok(Command::Help),
        ["version"] => Ok(Command::Version),
        ["status"] => Ok(Command::Status),
        ["outputs"] | ["output", "status"] => Ok(Command::Outputs),
        ["ui"] | ["ui", "status"] => Ok(Command::UiStatus),
        ["ui", "setup"] => Ok(Command::UiSetup(None)),
        ["ui", "setup", _] => Ok(Command::UiSetup(Some(PathBuf::from(&arguments[2])))),
        ["ui", "workspace", _] => Ok(Command::UiWorkspace(PathBuf::from(&arguments[2]))),
        ["ui", "live", value] | ["ui", "dev", value] => Ok(Command::UiLive(parse_switch(value)?)),
        ["ui", "auto-reload", value] => Ok(Command::UiAutoReload(parse_switch(value)?)),
        ["ui", "reload"] => Ok(Command::UiAction {
            method: "ui.reload",
            expected_mode: None,
        }),
        ["ui", "restart"] => Ok(Command::UiAction {
            method: "ui.restart",
            expected_mode: None,
        }),
        ["ui", "build"] | ["ui", "profile"] => Ok(Command::UiAction {
            method: "ui.build",
            expected_mode: Some("custom_optimized"),
        }),
        ["ui", "restore"] | ["ui", "official"] => Ok(Command::UiAction {
            method: "ui.restore",
            expected_mode: Some("official_optimized"),
        }),
        ["ui", "revert"] => Ok(Command::UiAction {
            method: "ui.revert",
            expected_mode: None,
        }),
        ["ui", "vm-service"] | ["ui", "uri"] => Ok(Command::UiVmService),
        _ => Err(CliError::usage(format!(
            "unknown command {}",
            words.join(" ")
        ))),
    }
}

fn parse_switch(value: &str) -> Result<bool, CliError> {
    match value {
        "on" | "enable" | "enabled" | "true" | "1" => Ok(true),
        "off" | "disable" | "disabled" | "false" | "0" => Ok(false),
        _ => Err(CliError::usage(format!(
            "expected on or off, got {value:?}"
        ))),
    }
}

fn execute(client: &mut ControlClient, options: &Options) -> Result<(), CliError> {
    match &options.command {
        Command::Help | Command::Version => unreachable!("handled before socket discovery"),
        Command::Status => {
            let ui = client.request("ui.get", Value::Null)?;
            let outputs = client.request("outputs.get", Value::Null)?;
            if options.json {
                print_json(&json!({
                    "ui": ui.result,
                    "outputs": outputs.result,
                }))?;
            } else {
                let ui_state = decode_ui_state(&ui.result)?;
                let output_state = decode_output_state(&outputs.result)?;
                print_status(&ui_state, &output_state);
            }
        }
        Command::Outputs => {
            let response = client.request("outputs.get", Value::Null)?;
            if options.json {
                print_json(&response.result)?;
            } else {
                print_outputs(&decode_output_state(&response.result)?);
            }
        }
        Command::UiStatus => {
            let response = client.request("ui.get", Value::Null)?;
            emit_ui_result(&response.result, options.json, false)?;
        }
        Command::UiSetup(destination) => {
            setup_ui_workspace(client, options, destination.as_deref())?;
        }
        Command::UiWorkspace(path) => {
            let workspace = validate_workspace(path)?;
            let response = client.request(
                "ui.workspace.set",
                json!({"path": workspace.to_string_lossy()}),
            )?;
            let result = finish_ui_action(client, response, None, options.json)?;
            emit_ui_result(&result, options.json, true)?;
        }
        Command::UiLive(enabled) => {
            let method = if *enabled {
                "ui.live.enable"
            } else {
                "ui.live.disable"
            };
            let expected = if *enabled {
                "live_development"
            } else {
                "official_optimized"
            };
            let response = client.request(method, Value::Null)?;
            let result = finish_ui_action(
                client,
                response,
                options.wait.then_some(expected),
                options.json,
            )?;
            emit_ui_result(&result, options.json, true)?;
        }
        Command::UiAction {
            method,
            expected_mode,
        } => {
            let response = client.request(method, Value::Null)?;
            let result = finish_ui_action(
                client,
                response,
                options.wait.then_some(*expected_mode).flatten(),
                options.json,
            )?;
            emit_ui_result(&result, options.json, true)?;
        }
        Command::UiAutoReload(enabled) => {
            let response = client.request("ui.auto_reload.set", json!({"enabled": enabled}))?;
            let result = finish_ui_action(client, response, None, options.json)?;
            emit_ui_result(&result, options.json, true)?;
        }
        Command::UiVmService => {
            let response = client.request("ui.get", Value::Null)?;
            let state = decode_ui_state(&response.result)?;
            if state.vm_service_uri.is_empty() {
                return Err(CliError::new(
                    "the live Flutter runtime is not exposing a VM service",
                ));
            }
            if options.json {
                print_json(&json!({"vm_service_uri": state.vm_service_uri}))?;
            } else {
                println!("{}", state.vm_service_uri);
            }
        }
    }
    Ok(())
}

fn setup_ui_workspace(
    client: &mut ControlClient,
    options: &Options,
    destination: Option<&Path>,
) -> Result<(), CliError> {
    let template = env::var_os("DENIAL_UI_SOURCE_TEMPLATE")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(SYSTEM_UI_SOURCE_TEMPLATE));
    let remote = env::var_os("DENIAL_UI_SOURCE_REMOTE")
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| OsString::from(DENIAL_GIT_REMOTE));
    let git = env::var_os("DENIAL_UI_GIT")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(SYSTEM_GIT));
    let destination = resolve_setup_destination(destination)?;
    let (workspace, created) = materialize_ui_source(&template, &git, &remote, &destination)?;

    if !options.json {
        if created {
            println!(
                "Created a version-matched Denial Git checkout at {}.",
                destination.display()
            );
        } else {
            println!(
                "Keeping the existing UI source at {}; no files were overwritten.",
                destination.display()
            );
        }
        println!("Preparing the pinned live-development bundle…");
    }
    prepare_ui_workspace(&workspace, options.json)?;

    let current = client.request("ui.get", Value::Null)?;
    let current_state = decode_ui_state(&current.result)?;
    if current_state.active_mode == "live_development"
        || current_state.desired_mode == "live_development"
    {
        let response = client.request("ui.live.disable", Value::Null)?;
        finish_ui_action(client, response, Some("official_optimized"), false)?;
    }

    let response = client.request(
        "ui.workspace.set",
        json!({"path": workspace.to_string_lossy()}),
    )?;
    finish_ui_action(client, response, None, false)?;

    let response = client.request("ui.live.enable", Value::Null)?;
    let result = finish_ui_action(client, response, Some("live_development"), false)?;
    if options.json {
        print_json(&json!({
            "created": created,
            "source_root": destination,
            "workspace": workspace,
            "ui": result,
        }))?;
    } else {
        println!(
            "\nDenial live UI development is ready.\n  Source: {}\n  Flutter workspace: {}\n\nOpen the Flutter workspace in VSCodium and start “Attach to Denial live UI”.",
            destination.display(),
            workspace.display()
        );
    }
    Ok(())
}

fn resolve_setup_destination(explicit: Option<&Path>) -> Result<PathBuf, CliError> {
    let destination = if let Some(explicit) = explicit {
        if explicit.as_os_str().is_empty() {
            return Err(CliError::new("UI source destination must not be empty"));
        }
        if explicit.is_absolute() {
            explicit.to_owned()
        } else {
            env::current_dir().map_err(CliError::io)?.join(explicit)
        }
    } else {
        let home = env::var_os("HOME")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .filter(|path| path.is_absolute())
            .ok_or_else(|| {
                CliError::new("HOME must be an absolute path when ui setup has no destination")
            })?;
        home.join("DenialUI")
    };
    lexical_absolute(&destination)
}

fn lexical_absolute(path: &Path) -> Result<PathBuf, CliError> {
    if !path.is_absolute() {
        return Err(CliError::new(format!(
            "path must be absolute: {}",
            path.display()
        )));
    }
    let mut normalized = PathBuf::from("/");
    for component in path.components() {
        match component {
            Component::RootDir => {}
            Component::Normal(value) => normalized.push(value),
            Component::CurDir => {}
            Component::ParentDir => {
                if !normalized.pop() {
                    return Err(CliError::new(format!(
                        "path escapes the filesystem root: {}",
                        path.display()
                    )));
                }
            }
            Component::Prefix(_) => {
                return Err(CliError::new("Windows path prefixes are unsupported"));
            }
        }
    }
    if normalized == Path::new("/") || normalized.file_name().is_none() {
        return Err(CliError::new(
            "UI source destination must name a directory below the filesystem root",
        ));
    }
    Ok(normalized)
}

fn materialize_ui_source(
    template: &Path,
    git: &Path,
    remote: &OsStr,
    destination: &Path,
) -> Result<(PathBuf, bool), CliError> {
    let expected_marker = validate_source_template(template)?;
    validate_git_tool(git)?;
    match fs::symlink_metadata(destination) {
        Ok(metadata) => {
            if !metadata.file_type().is_dir() {
                return Err(CliError::new(format!(
                    "UI source destination already exists and is not a directory: {}",
                    destination.display()
                )));
            }
            let workspace = discover_workspace_root(destination, Some(&expected_marker))?;
            validate_git_checkout(git, destination)?;
            return Ok((workspace, false));
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(CliError::io(error)),
    }

    let parent = destination
        .parent()
        .ok_or_else(|| CliError::new("UI source destination has no parent directory"))?;
    fs::create_dir_all(parent).map_err(CliError::io)?;
    let mut staging = SetupTemporaryDirectory::create(parent)?;
    checkout_source_remote(
        git,
        remote,
        staging.path(),
        &expected_marker.source_ref,
        &expected_marker.source_revision,
    )?;
    copy_source_tree(template, staging.path())?;
    validate_git_checkout(git, staging.path())?;
    fs::set_permissions(staging.path(), fs::Permissions::from_mode(0o755)).map_err(CliError::io)?;
    fs::rename(staging.path(), destination).map_err(|error| {
        CliError::new(format!(
            "could not install the editable UI source at {}: {error}",
            destination.display()
        ))
    })?;
    staging.preserve();
    Ok((
        discover_workspace_root(destination, Some(&expected_marker))?,
        true,
    ))
}

fn validate_source_template(path: &Path) -> Result<UiSourceMarker, CliError> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        CliError::new(format!(
            "the version-matched UI source is unavailable at {}: {error}; install denial-ui-development",
            path.display()
        ))
    })?;
    if !metadata.file_type().is_dir() {
        return Err(CliError::new(format!(
            "UI source template is not a directory: {}",
            path.display()
        )));
    }
    let marker = read_source_marker(path)?;
    validate_workspace(&workspace_from_source_marker(path, &marker)?)?;
    Ok(marker)
}

fn discover_workspace_root(
    path: &Path,
    expected_marker: Option<&UiSourceMarker>,
) -> Result<PathBuf, CliError> {
    if path.join(UI_SOURCE_MARKER).is_file() {
        let marker = read_source_marker(path)?;
        if let Some(expected) = expected_marker
            && (marker.ui_development_api != expected.ui_development_api
                || marker.flutter_generation != expected.flutter_generation)
        {
            return Err(CliError::new(format!(
                "existing UI source at {} belongs to an incompatible Denial development generation; choose a new destination and no files will be overwritten",
                path.display()
            )));
        }
        return validate_workspace(&workspace_from_source_marker(path, &marker)?);
    }
    let nested = path.join("dart_shell");
    if workspace_shape_is_valid(&nested) {
        return validate_workspace(&nested);
    }
    if workspace_shape_is_valid(path) {
        return validate_workspace(path);
    }
    Err(CliError::new(format!(
        "existing destination {} is not a Denial UI source tree; no files were changed",
        path.display()
    )))
}

#[derive(Deserialize)]
struct UiSourceMarker {
    schema_version: u32,
    ui_development_api: u32,
    flutter_generation: String,
    source_ref: String,
    source_revision: String,
    workspace: String,
}

fn read_source_marker(root: &Path) -> Result<UiSourceMarker, CliError> {
    let marker_path = root.join(UI_SOURCE_MARKER);
    let metadata = fs::symlink_metadata(&marker_path).map_err(|error| {
        CliError::new(format!(
            "UI source template marker is missing at {}: {error}",
            marker_path.display()
        ))
    })?;
    if !metadata.file_type().is_file() || metadata.len() > MAX_SOURCE_MARKER_BYTES as u64 {
        return Err(CliError::new(format!(
            "UI source template marker is not a bounded regular file: {}",
            marker_path.display()
        )));
    }
    let marker: UiSourceMarker = serde_json::from_slice(
        &fs::read(&marker_path).map_err(CliError::io)?,
    )
    .map_err(|error| CliError::new(format!("invalid UI source template marker: {error}")))?;
    if marker.schema_version != 1 {
        return Err(CliError::new(format!(
            "unsupported UI source template schema {}",
            marker.schema_version
        )));
    }
    if marker.ui_development_api != 1 || marker.flutter_generation.is_empty() {
        return Err(CliError::new(
            "UI source template marker identifies an unsupported development generation",
        ));
    }
    if marker.source_revision.len() != 40
        || !marker
            .source_revision
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit())
    {
        return Err(CliError::new(
            "UI source template marker contains an invalid Git revision",
        ));
    }
    if marker.source_ref.is_empty()
        || marker.source_ref.len() > 255
        || marker.source_ref.starts_with('-')
        || !marker
            .source_ref
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'/' | b'-'))
    {
        return Err(CliError::new(
            "UI source template marker contains an invalid Git ref",
        ));
    }
    Ok(marker)
}

fn workspace_from_source_marker(root: &Path, marker: &UiSourceMarker) -> Result<PathBuf, CliError> {
    let relative = Path::new(&marker.workspace);
    if relative.as_os_str().is_empty()
        || relative.is_absolute()
        || relative
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        return Err(CliError::new(
            "UI source template marker contains an unsafe workspace path",
        ));
    }
    Ok(root.join(relative))
}

fn workspace_shape_is_valid(path: &Path) -> bool {
    path.is_dir() && path.join("pubspec.yaml").is_file() && path.join("lib/main.dart").is_file()
}

fn validate_git_tool(git: &Path) -> Result<(), CliError> {
    let metadata = fs::symlink_metadata(git).map_err(|error| {
        CliError::new(format!(
            "Git is unavailable at {}: {error}; install denial-ui-development",
            git.display()
        ))
    })?;
    if !metadata.file_type().is_file() || metadata.permissions().mode() & 0o111 == 0 {
        return Err(CliError::new(format!(
            "Git is not an executable regular file: {}",
            git.display()
        )));
    }
    Ok(())
}

fn checkout_source_remote(
    git: &Path,
    remote: &OsStr,
    destination: &Path,
    source_ref: &str,
    revision: &str,
) -> Result<(), CliError> {
    let mut clone = git_command(git);
    clone
        .args(["clone", "--quiet", "--no-checkout", "--branch"])
        .arg(source_ref)
        .args(["--template=", "--"])
        .arg(remote)
        .arg(destination);
    run_git(
        &mut clone,
        "could not clone the version-matched Denial source",
    )?;

    let mut checkout = git_command(git);
    checkout
        .arg("-C")
        .arg(destination)
        .args(["checkout", "--quiet", "-B", "main", revision]);
    run_git(
        &mut checkout,
        "could not check out the version-matched Denial revision",
    )?;

    for (key, value) in [
        ("branch.main.remote", "origin"),
        ("branch.main.merge", "refs/heads/main"),
    ] {
        let mut config = git_command(git);
        config
            .arg("-C")
            .arg(destination)
            .args(["config", "--local", key, value]);
        run_git(&mut config, "could not configure the Denial Git checkout")?;
    }

    let mut head = git_command(git);
    head.arg("-C")
        .arg(destination)
        .args(["rev-parse", "--verify", "HEAD"]);
    let actual = run_git(&mut head, "could not verify the Denial Git checkout")?;
    if actual.trim() != revision {
        return Err(CliError::new(format!(
            "cloned Denial checkout resolved to {}, expected {revision}",
            actual.trim()
        )));
    }
    Ok(())
}

fn validate_git_checkout(git: &Path, root: &Path) -> Result<(), CliError> {
    let mut command = git_command(git);
    command
        .arg("-C")
        .arg(root)
        .args(["rev-parse", "--show-toplevel"]);
    let top_level = run_git(&mut command, "UI source is not a valid Git checkout")?;
    let top_level = fs::canonicalize(top_level.trim()).map_err(CliError::io)?;
    let expected = fs::canonicalize(root).map_err(CliError::io)?;
    if top_level != expected {
        return Err(CliError::new(format!(
            "UI source at {} is nested inside a different Git checkout; no files were changed",
            root.display()
        )));
    }
    Ok(())
}

fn git_command(git: &Path) -> ProcessCommand {
    let mut command = ProcessCommand::new(git);
    command
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .env_remove("GIT_OBJECT_DIRECTORY")
        .env_remove("GIT_ALTERNATE_OBJECT_DIRECTORIES")
        .env_remove("GIT_COMMON_DIR");
    command
}

fn run_git(command: &mut ProcessCommand, context: &str) -> Result<String, CliError> {
    let output = command
        .output()
        .map_err(|error| CliError::new(format!("{context}: {error}")))?;
    if output.status.success() {
        return Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned());
    }
    let details = bounded_tool_output(&output.stderr, &output.stdout);
    Err(CliError::new(format!(
        "{context}: {}{}",
        output.status,
        if details.is_empty() {
            String::new()
        } else {
            format!(": {details}")
        }
    )))
}

fn copy_source_tree(source: &Path, destination: &Path) -> Result<(), CliError> {
    let metadata = fs::symlink_metadata(source).map_err(CliError::io)?;
    if metadata.file_type().is_symlink() {
        return Err(CliError::new(format!(
            "UI source template contains a symbolic link: {}",
            source.display()
        )));
    }
    if metadata.file_type().is_dir() {
        if let Ok(target) = fs::symlink_metadata(destination)
            && !target.file_type().is_dir()
        {
            return Err(CliError::new(format!(
                "Git checkout contains an unsafe source target: {}",
                destination.display()
            )));
        }
        fs::create_dir_all(destination).map_err(CliError::io)?;
        fs::set_permissions(destination, fs::Permissions::from_mode(0o755))
            .map_err(CliError::io)?;
        let mut entries = fs::read_dir(source)
            .map_err(CliError::io)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(CliError::io)?;
        entries.sort_by_key(|entry| entry.file_name());
        for entry in entries {
            copy_source_tree(&entry.path(), &destination.join(entry.file_name()))?;
        }
        return Ok(());
    }
    if !metadata.file_type().is_file() {
        return Err(CliError::new(format!(
            "UI source template contains a special file: {}",
            source.display()
        )));
    }
    let parent = destination
        .parent()
        .ok_or_else(|| CliError::new("UI source copy destination has no parent directory"))?;
    fs::create_dir_all(parent).map_err(CliError::io)?;
    if let Ok(target) = fs::symlink_metadata(destination)
        && !target.file_type().is_file()
    {
        return Err(CliError::new(format!(
            "Git checkout contains an unsafe source target: {}",
            destination.display()
        )));
    }
    fs::copy(source, destination).map_err(CliError::io)?;
    let mode = if metadata.permissions().mode() & 0o111 == 0 {
        0o644
    } else {
        0o755
    };
    fs::set_permissions(destination, fs::Permissions::from_mode(mode)).map_err(CliError::io)
}

fn prepare_ui_workspace(workspace: &Path, capture_output: bool) -> Result<(), CliError> {
    let tool = env::var_os("DENIAL_UI_TOOL")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(SYSTEM_UI_TOOL));
    let metadata = fs::symlink_metadata(&tool).map_err(|error| {
        CliError::new(format!(
            "Denial UI development tool is unavailable at {}: {error}; install denial-ui-development",
            tool.display()
        ))
    })?;
    if !metadata.file_type().is_file() || metadata.permissions().mode() & 0o111 == 0 {
        return Err(CliError::new(format!(
            "Denial UI development tool is not an executable regular file: {}",
            tool.display()
        )));
    }
    let mut command = ProcessCommand::new(tool);
    command.arg("prepare").arg(workspace);
    if capture_output {
        let output = command
            .output()
            .map_err(|error| CliError::new(format!("could not start denial-ui: {error}")))?;
        if output.status.success() {
            return Ok(());
        }
        let details = bounded_tool_output(&output.stderr, &output.stdout);
        return Err(CliError::new(format!(
            "denial-ui prepare failed with {}{}",
            output.status,
            if details.is_empty() {
                String::new()
            } else {
                format!(": {details}")
            }
        )));
    }
    let status = command
        .status()
        .map_err(|error| CliError::new(format!("could not start denial-ui: {error}")))?;
    if status.success() {
        Ok(())
    } else {
        Err(CliError::new(format!(
            "denial-ui prepare failed with {status}"
        )))
    }
}

fn bounded_tool_output(primary: &[u8], fallback: &[u8]) -> String {
    let bytes = if primary.iter().any(|byte| !byte.is_ascii_whitespace()) {
        primary
    } else {
        fallback
    };
    let start = bytes.len().saturating_sub(MAX_TOOL_OUTPUT_BYTES);
    String::from_utf8_lossy(&bytes[start..]).trim().to_owned()
}

fn finish_ui_action(
    client: &mut ControlClient,
    response: ControlResult,
    expected_mode: Option<&str>,
    json_output: bool,
) -> Result<Value, CliError> {
    let initial = decode_ui_state(&response.result)?;
    validate_acknowledgement(response.id, &initial)?;
    if !initial.error.is_empty() {
        if json_output {
            print_json(&response.result)?;
        }
        return Err(CliError::new(initial.error));
    }
    let Some(expected_mode) = expected_mode else {
        return Ok(response.result);
    };
    if initial.active_mode == expected_mode && initial.operation == "idle" {
        return Ok(response.result);
    }

    let deadline = Instant::now() + MODE_SWITCH_TIMEOUT;
    loop {
        if Instant::now() >= deadline {
            return Err(CliError::new(format!(
                "timed out waiting for UI runtime mode {expected_mode}"
            )));
        }
        thread::sleep(POLL_INTERVAL);
        let current = client.request("ui.get", Value::Null)?;
        let state = decode_ui_state(&current.result)?;
        if !state.error.is_empty() {
            if json_output {
                print_json(&current.result)?;
            }
            return Err(CliError::new(state.error));
        }
        if state.active_mode == expected_mode && state.operation == "idle" {
            return Ok(current.result);
        }
    }
}

fn validate_acknowledgement(id: u64, state: &UiState) -> Result<(), CliError> {
    if u64::from(state.acknowledged_request_id) != id {
        return Err(CliError::new(format!(
            "compositor acknowledged UI request {}, expected {id}",
            state.acknowledged_request_id
        )));
    }
    Ok(())
}

fn validate_workspace(path: &Path) -> Result<PathBuf, CliError> {
    if path.as_os_str().is_empty() {
        return Err(CliError::new("Flutter workspace path must not be empty"));
    }
    let path = if path.is_absolute() {
        path.to_owned()
    } else {
        env::current_dir()
            .map_err(|error| CliError::new(format!("could not read current directory: {error}")))?
            .join(path)
    };
    let path = fs::canonicalize(&path).map_err(|error| {
        CliError::new(format!(
            "could not resolve Flutter workspace {}: {error}",
            path.display()
        ))
    })?;
    if path.to_str().is_none_or(|path| path.len() > 4096) {
        return Err(CliError::new(
            "Flutter workspace path must be valid UTF-8 and at most 4,096 bytes",
        ));
    }
    for required in ["pubspec.yaml", "lib/main.dart"] {
        let required = path.join(required);
        if !required.is_file() {
            return Err(CliError::new(format!(
                "Flutter workspace is missing {}",
                required.display()
            )));
        }
    }
    Ok(path)
}

struct ControlClient {
    socket: PathBuf,
    next_id: u32,
}

struct ControlResult {
    id: u64,
    result: Value,
}

impl ControlClient {
    fn new(socket: PathBuf) -> Self {
        Self { socket, next_id: 1 }
    }

    fn request(&mut self, method: &str, params: Value) -> Result<ControlResult, CliError> {
        validate_socket(&self.socket)?;
        let id = self.next_id;
        self.next_id = self.next_id.wrapping_add(1).max(1);
        let request = json!({
            "version": PROTOCOL_VERSION,
            "id": id,
            "method": method,
            "params": params,
        });
        let mut stream = UnixStream::connect(&self.socket).map_err(|error| {
            CliError::new(format!(
                "could not connect to {}: {error}",
                self.socket.display()
            ))
        })?;
        stream
            .set_read_timeout(Some(IO_TIMEOUT))
            .map_err(CliError::io)?;
        stream
            .set_write_timeout(Some(IO_TIMEOUT))
            .map_err(CliError::io)?;
        serde_json::to_writer(&mut stream, &request)
            .map_err(|error| CliError::new(format!("could not encode request: {error}")))?;
        stream.write_all(b"\n").map_err(CliError::io)?;
        stream.flush().map_err(CliError::io)?;

        let mut bytes = Vec::new();
        BufReader::new(stream)
            .take((MAX_RESPONSE_BYTES + 1) as u64)
            .read_to_end(&mut bytes)
            .map_err(CliError::io)?;
        if bytes.len() > MAX_RESPONSE_BYTES {
            return Err(CliError::new(
                "compositor response exceeds the 4 MiB safety limit",
            ));
        }
        let response: ResponseEnvelope = serde_json::from_slice(&bytes)
            .map_err(|error| CliError::new(format!("invalid compositor response: {error}")))?;
        if response.version != PROTOCOL_VERSION {
            return Err(CliError::new(format!(
                "compositor returned protocol version {}, expected {}",
                response.version, PROTOCOL_VERSION
            )));
        }
        if response.id != Some(u64::from(id)) {
            return Err(CliError::new(format!(
                "compositor returned response id {:?}, expected {id}",
                response.id
            )));
        }
        if !response.ok {
            let error = response.error.unwrap_or(ControlFailure {
                code: "unknown".to_owned(),
                message: "the compositor rejected the request without details".to_owned(),
            });
            return Err(CliError::new(format!("{}: {}", error.code, error.message)));
        }
        let result = response
            .result
            .ok_or_else(|| CliError::new("successful compositor response has no result"))?;
        Ok(ControlResult {
            id: u64::from(id),
            result,
        })
    }
}

#[derive(Deserialize)]
struct ResponseEnvelope {
    version: u32,
    id: Option<u64>,
    ok: bool,
    result: Option<Value>,
    error: Option<ControlFailure>,
}

#[derive(Deserialize)]
struct ControlFailure {
    code: String,
    message: String,
}

#[derive(Deserialize)]
struct UiState {
    active_mode: String,
    desired_mode: String,
    operation: String,
    developer_components_available: bool,
    workspace_valid: bool,
    auto_reload: bool,
    auto_reload_supported: bool,
    can_hot_reload: bool,
    can_hot_restart: bool,
    can_build_optimized: bool,
    can_revert: bool,
    vm_service_uri: String,
    generation: u64,
    revision: u64,
    acknowledged_request_id: u32,
    workspace: String,
    status: String,
    error: String,
    diagnostics: Vec<UiDiagnostic>,
    progress_basis_points: Option<u16>,
}

#[derive(Deserialize)]
struct UiDiagnostic {
    severity: String,
    message: String,
    path: String,
    line: u32,
    column: u32,
}

#[derive(Deserialize)]
struct OutputState {
    serial: u64,
    outputs: Vec<Output>,
}

#[derive(Deserialize)]
struct Output {
    name: String,
    description: String,
    connected: bool,
    enabled: bool,
    powered: bool,
    x: i32,
    y: i32,
    scale: f64,
    current_mode: Option<OutputMode>,
}

#[derive(Deserialize)]
struct OutputMode {
    width: u32,
    height: u32,
    refresh_millihz: u32,
}

fn decode_ui_state(value: &Value) -> Result<UiState, CliError> {
    serde_json::from_value(value.clone())
        .map_err(|error| CliError::new(format!("invalid UI state from compositor: {error}")))
}

fn decode_output_state(value: &Value) -> Result<OutputState, CliError> {
    serde_json::from_value(value.clone())
        .map_err(|error| CliError::new(format!("invalid output state from compositor: {error}")))
}

fn print_status(ui: &UiState, outputs: &OutputState) {
    let active_outputs = outputs
        .outputs
        .iter()
        .filter(|output| output.enabled && output.powered)
        .count();
    println!("Denial");
    println!("  UI runtime       {}", mode_label(&ui.active_mode));
    if ui.desired_mode != ui.active_mode {
        println!("  Desired runtime  {}", mode_label(&ui.desired_mode));
    }
    println!("  Generation       {}", ui.generation);
    println!(
        "  Live development {}",
        if ui.developer_components_available && ui.workspace_valid {
            "ready"
        } else {
            "needs setup"
        }
    );
    println!(
        "  Outputs          {active_outputs}/{} active (serial {})",
        outputs.outputs.len(),
        outputs.serial
    );
    if !ui.status.is_empty() {
        println!("  Status           {}", ui.status);
    }
    if !ui.error.is_empty() {
        println!("  Error            {}", ui.error);
    }
}

fn print_outputs(state: &OutputState) {
    println!("Output configuration serial {}", state.serial);
    if state.outputs.is_empty() {
        println!("  No connected outputs");
        return;
    }
    for output in &state.outputs {
        let state = if !output.connected {
            "disconnected"
        } else if !output.enabled {
            "disabled"
        } else if !output.powered {
            "powered off"
        } else {
            "active"
        };
        let description = if output.description == output.name {
            String::new()
        } else {
            format!(" ({})", output.description)
        };
        match output.current_mode.as_ref() {
            Some(mode) => println!(
                "  {}{}: {} — {}×{} @ {:.3} Hz, scale {:.3}, position {},{}",
                output.name,
                description,
                state,
                mode.width,
                mode.height,
                f64::from(mode.refresh_millihz) / 1000.0,
                output.scale,
                output.x,
                output.y
            ),
            None => println!("  {}{}: {}", output.name, description, state),
        }
    }
}

fn emit_ui_result(value: &Value, json_output: bool, reject_error: bool) -> Result<(), CliError> {
    let state = decode_ui_state(value)?;
    if json_output {
        print_json(value)?;
    } else {
        print_ui(&state);
    }
    if reject_error && !state.error.is_empty() {
        return Err(CliError::new(state.error));
    }
    Ok(())
}

fn print_ui(state: &UiState) {
    println!("Flutter shell");
    println!("  Active mode      {}", mode_label(&state.active_mode));
    println!("  Desired mode     {}", mode_label(&state.desired_mode));
    println!("  Operation        {}", operation_label(&state.operation));
    println!("  Generation       {}", state.generation);
    println!("  State revision   {}", state.revision);
    println!(
        "  Workspace        {}",
        if state.workspace.is_empty() {
            "not selected"
        } else {
            &state.workspace
        }
    );
    println!(
        "  Workspace state  {}",
        if state.workspace_valid {
            "valid"
        } else {
            "not ready"
        }
    );
    println!(
        "  JIT components   {}",
        if state.developer_components_available {
            "ready"
        } else {
            "unavailable"
        }
    );
    println!(
        "  Automatic reload {}{}",
        if state.auto_reload { "on" } else { "off" },
        if state.auto_reload_supported {
            ""
        } else {
            " (not supported by this build)"
        }
    );
    println!(
        "  Actions          reload={} restart={} build={} revert={}",
        yes_no(state.can_hot_reload),
        yes_no(state.can_hot_restart),
        yes_no(state.can_build_optimized),
        yes_no(state.can_revert)
    );
    if let Some(progress) = state.progress_basis_points {
        println!("  Progress         {:.2}%", f64::from(progress) / 100.0);
    }
    if !state.vm_service_uri.is_empty() {
        println!("  VM service       {}", state.vm_service_uri);
    }
    if !state.status.is_empty() {
        println!("  Status           {}", state.status);
    }
    if !state.error.is_empty() {
        println!("  Error            {}", state.error);
    }
    for diagnostic in &state.diagnostics {
        let location = if diagnostic.path.is_empty() {
            String::new()
        } else if diagnostic.line == 0 {
            format!(" ({})", diagnostic.path)
        } else {
            format!(
                " ({}:{}:{})",
                diagnostic.path, diagnostic.line, diagnostic.column
            )
        };
        println!(
            "  Diagnostic       {}: {}{}",
            diagnostic.severity, diagnostic.message, location
        );
    }
}

fn mode_label(mode: &str) -> &str {
    match mode {
        "official_optimized" => "Official optimized",
        "custom_optimized" => "Custom optimized",
        "live_development" => "Live development",
        "unavailable" => "Unavailable",
        other => other,
    }
}

fn operation_label(operation: &str) -> &str {
    match operation {
        "idle" => "Idle",
        "validating_workspace" => "Validating workspace",
        "switching_runtime" => "Switching runtime",
        "hot_reloading" => "Hot reloading",
        "hot_restarting" => "Hot restarting",
        "building_optimized" => "Building optimized",
        "reverting" => "Reverting",
        other => other,
    }
}

fn yes_no(value: bool) -> &'static str {
    if value { "yes" } else { "no" }
}

fn print_json(value: &Value) -> Result<(), CliError> {
    serde_json::to_writer_pretty(std::io::stdout().lock(), value)
        .map_err(|error| CliError::new(format!("could not write JSON output: {error}")))?;
    println!();
    Ok(())
}

fn resolve_socket_path(explicit: Option<&Path>) -> Result<PathBuf, CliError> {
    let path = if let Some(explicit) = explicit {
        explicit.to_owned()
    } else if let Some(socket) = env::var_os("DENIAL_SOCKET") {
        PathBuf::from(socket)
    } else {
        let runtime = env::var_os("XDG_RUNTIME_DIR")
            .ok_or_else(|| CliError::new("DENIAL_SOCKET and XDG_RUNTIME_DIR are both unset"))?;
        PathBuf::from(runtime).join("denial/control.sock")
    };
    if !path.is_absolute() {
        return Err(CliError::new(format!(
            "control socket path must be absolute: {}",
            path.display()
        )));
    }
    Ok(path)
}

fn validate_socket(path: &Path) -> Result<(), CliError> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        CliError::new(format!(
            "Denial control socket is unavailable at {}: {error}",
            path.display()
        ))
    })?;
    if !metadata.file_type().is_socket() {
        return Err(CliError::new(format!(
            "Denial control path is not a Unix socket: {}",
            path.display()
        )));
    }
    if metadata.permissions().mode() & 0o077 != 0 {
        return Err(CliError::new(format!(
            "Denial control socket has unsafe permissions: {}",
            path.display()
        )));
    }
    Ok(())
}

struct SetupTemporaryDirectory {
    path: PathBuf,
    remove: bool,
}

impl SetupTemporaryDirectory {
    fn create(parent: &Path) -> Result<Self, CliError> {
        fs::create_dir_all(parent).map_err(CliError::io)?;
        for _ in 0..128 {
            let sequence = TEMPORARY_SEQUENCE.fetch_add(1, Ordering::Relaxed);
            let path = parent.join(format!(
                ".denial-ui-setup.{}.{}",
                std::process::id(),
                sequence
            ));
            match fs::create_dir(&path) {
                Ok(()) => {
                    fs::set_permissions(&path, fs::Permissions::from_mode(0o700))
                        .map_err(CliError::io)?;
                    return Ok(Self { path, remove: true });
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
                Err(error) => return Err(CliError::io(error)),
            }
        }
        Err(CliError::new(format!(
            "could not allocate a temporary UI source directory below {}",
            parent.display()
        )))
    }

    fn path(&self) -> &Path {
        &self.path
    }

    fn preserve(&mut self) {
        self.remove = false;
    }
}

impl Drop for SetupTemporaryDirectory {
    fn drop(&mut self) {
        if self.remove {
            let _ = fs::remove_dir_all(&self.path);
        }
    }
}

#[derive(Debug)]
struct CliError {
    message: String,
}

impl CliError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }

    fn usage(message: impl Into<String>) -> Self {
        Self::new(format!("{}; run 'denialctl --help'", message.into()))
    }

    fn io(error: std::io::Error) -> Self {
        Self::new(error.to_string())
    }
}

impl fmt::Display for CliError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.message.fmt(formatter)
    }
}

impl Error for CliError {}

fn print_help() {
    println!(
        "\
Usage: denialctl [--json] [--no-wait] [--socket PATH] COMMAND

Commands:
  status                         Show compositor, Flutter UI and output status
  outputs                        List the current output state
  ui status                      Show detailed Flutter runtime state
  ui setup [PATH]                Create, prepare and start an editable Denial UI
  ui workspace PATH              Select a Flutter source workspace
  ui live on|off                 Enter or leave JIT live-development mode
  ui reload                      Request a Dart hot reload when supported
  ui restart                     Request a Dart hot restart when supported
  ui profile                     Activate the prepared AOT profile UI
  ui build                       Alias for 'ui profile'
  ui restore                     Restore the packaged optimized UI
  ui revert                      Restore the last working custom UI
  ui auto-reload on|off          Configure native source watching
  ui vm-service                  Print the authenticated loopback VM-service URI

Options:
  --json                         Emit stable machine-readable JSON
  --no-wait                      Return after a runtime switch is accepted
  --socket PATH                  Override DENIAL_SOCKET
  -h, --help                     Show this help
  -V, --version                  Show the denialctl version

The socket defaults to DENIAL_SOCKET, then
$XDG_RUNTIME_DIR/denial/control.sock. Commands never require Flutter UI
cooperation; 'denialctl ui restore' is the native recovery path.

'ui setup' defaults to $HOME/DenialUI, clones and verifies the version-matched
revision recorded by denial-ui-development, and never overwrites an existing
tree."
    );
}

#[cfg(test)]
mod tests {
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
        let directory =
            env::temp_dir().join(format!("denialctl-test-{}-{suffix}", std::process::id()));
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
        let error =
            Options::parse([OsString::from("explode")]).expect_err("unknown command must fail");
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
}
