//! Versioned, compositor-owned control IPC.
//!
//! The socket carries output transactions and shell-independent Flutter UI
//! lifecycle/recovery commands. It deliberately exposes Denial's own model
//! instead of impersonating another compositor. Clients connect to
//! `DENIAL_SOCKET`, send one newline-delimited JSON request, read one response,
//! and close.

use std::error::Error;
use std::ffi::OsString;
use std::fs::{self, DirBuilder, Permissions};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::Shutdown;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, RwLock, mpsc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use smithay::reexports::calloop::channel::{Channel, SyncSender, sync_channel};
use tracing::{info, warn};

use super::ui_development::{
    CommandKind as UiDevelopmentCommandKind, UiDevelopmentCommand, UiDevelopmentState,
};

pub(super) const PROTOCOL_VERSION: u32 = 1;

const SOCKET_DIRECTORY: &str = "denial";
const SOCKET_FILE: &str = "control.sock";
const EVENT_QUEUE_CAPACITY: usize = 8;
const MAX_REQUEST_BYTES: usize = 256 * 1024;
const CLIENT_IO_TIMEOUT: Duration = Duration::from_secs(3);
const APPLY_TIMEOUT: Duration = Duration::from_secs(15);
const UI_COMMAND_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub(super) struct OutputControlCapabilities {
    pub(super) apply: bool,
    pub(super) enable: bool,
    pub(super) position: bool,
    pub(super) mode: bool,
    pub(super) scale: bool,
    pub(super) transform: bool,
    pub(super) adaptive_sync: bool,
    pub(super) dpms: bool,
    pub(super) mirror: bool,
    pub(super) ten_bit: bool,
    pub(super) persistent: bool,
}

impl Default for OutputControlCapabilities {
    fn default() -> Self {
        Self {
            apply: true,
            enable: true,
            position: true,
            mode: true,
            scale: true,
            transform: true,
            adaptive_sync: true,
            dpms: true,
            mirror: false,
            ten_bit: false,
            persistent: false,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub(super) struct OutputControlMode {
    pub(super) width: u32,
    pub(super) height: u32,
    pub(super) refresh_millihz: u32,
    pub(super) preferred: bool,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub(super) struct RequestedOutputMode {
    pub(super) width: u32,
    pub(super) height: u32,
    pub(super) refresh_millihz: u32,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub(super) enum OutputTransformName {
    #[serde(rename = "normal")]
    Normal,
    #[serde(rename = "90")]
    Rotate90,
    #[serde(rename = "180")]
    Rotate180,
    #[serde(rename = "270")]
    Rotate270,
    #[serde(rename = "flipped")]
    Flipped,
    #[serde(rename = "flipped-90")]
    Flipped90,
    #[serde(rename = "flipped-180")]
    Flipped180,
    #[serde(rename = "flipped-270")]
    Flipped270,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub(super) struct OutputControlOutput {
    pub(super) name: String,
    pub(super) description: String,
    pub(super) connected: bool,
    pub(super) enabled: bool,
    pub(super) powered: bool,
    pub(super) x: i32,
    pub(super) y: i32,
    pub(super) logical_width: u32,
    pub(super) logical_height: u32,
    pub(super) physical_width_mm: Option<u32>,
    pub(super) physical_height_mm: Option<u32>,
    pub(super) scale: f64,
    pub(super) transform: OutputTransformName,
    pub(super) adaptive_sync: bool,
    pub(super) current_mode: Option<OutputControlMode>,
    pub(super) modes: Vec<OutputControlMode>,
}

#[derive(Clone, Debug, PartialEq)]
pub(super) struct OutputControlState {
    pub(super) capabilities: OutputControlCapabilities,
    pub(super) outputs: Vec<OutputControlOutput>,
    pub(super) pending_confirmation: Option<OutputControlConfirmation>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub(super) struct OutputControlConfirmation {
    pub(super) token: u64,
    pub(super) deadline_unix_milliseconds: u64,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub(super) struct OutputControlSnapshot {
    pub(super) serial: u64,
    pub(super) capabilities: OutputControlCapabilities,
    pub(super) outputs: Vec<OutputControlOutput>,
    pub(super) pending_confirmation: Option<OutputControlConfirmation>,
}

impl OutputControlSnapshot {
    fn new(state: OutputControlState) -> Self {
        Self {
            serial: initial_serial(),
            capabilities: state.capabilities,
            outputs: state.outputs,
            pending_confirmation: state.pending_confirmation,
        }
    }

    fn same_state(&self, state: &OutputControlState) -> bool {
        self.capabilities == state.capabilities
            && self.outputs == state.outputs
            && self.pending_confirmation == state.pending_confirmation
    }
}

fn initial_serial() -> u64 {
    let wall_clock = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or_default();
    wall_clock
        .rotate_left(17)
        .wrapping_add(u64::from(std::process::id()))
        .max(1)
}

#[derive(Clone)]
pub(super) struct OutputControlPublisher {
    snapshot: Arc<RwLock<OutputControlSnapshot>>,
}

impl OutputControlPublisher {
    fn new(initial: OutputControlState) -> Self {
        Self {
            snapshot: Arc::new(RwLock::new(OutputControlSnapshot::new(initial))),
        }
    }

    pub(super) fn snapshot(&self) -> OutputControlSnapshot {
        self.snapshot
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    pub(super) fn publish(&self, state: OutputControlState) -> OutputControlSnapshot {
        let mut snapshot = self
            .snapshot
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if !snapshot.same_state(&state) {
            snapshot.serial = snapshot.serial.wrapping_add(1).max(1);
            snapshot.capabilities = state.capabilities;
            snapshot.outputs = state.outputs;
            snapshot.pending_confirmation = state.pending_confirmation;
        }
        snapshot.clone()
    }

    pub(super) fn publish_if_dirty<E>(
        &self,
        dirty: &mut bool,
        build_state: impl FnOnce() -> Result<OutputControlState, E>,
    ) -> Result<Option<OutputControlSnapshot>, E> {
        if !*dirty {
            return Ok(None);
        }
        let snapshot = self.publish(build_state()?);
        *dirty = false;
        Ok(Some(snapshot))
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub(super) struct RequestedOutput {
    pub(super) name: String,
    pub(super) enabled: bool,
    pub(super) powered: bool,
    pub(super) x: i32,
    pub(super) y: i32,
    pub(super) mode: RequestedOutputMode,
    pub(super) scale: f64,
    pub(super) transform: OutputTransformName,
    pub(super) adaptive_sync: bool,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub(super) struct ApplyOutputConfiguration {
    pub(super) serial: u64,
    #[serde(default)]
    pub(super) persistent: bool,
    #[serde(default)]
    pub(super) confirmation_timeout_milliseconds: Option<u64>,
    pub(super) outputs: Vec<RequestedOutput>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub(super) struct OutputControlFailure {
    pub(super) code: String,
    pub(super) message: String,
}

impl OutputControlFailure {
    pub(super) fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }
}

pub(super) type ApplyOutputReply = Result<OutputControlSnapshot, OutputControlFailure>;

#[derive(Debug)]
pub(super) struct PendingOutputApply {
    pub(super) configuration: ApplyOutputConfiguration,
    reply: mpsc::SyncSender<ApplyOutputReply>,
}

impl PendingOutputApply {
    pub(super) fn reply(self, result: ApplyOutputReply) {
        let _ = self.reply.send(result);
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum OutputConfirmationAction {
    Keep,
    Rollback,
}

pub(super) type OutputConfirmationReply = Result<(), OutputControlFailure>;

#[derive(Debug)]
pub(super) struct PendingOutputConfirmation {
    pub(super) token: u64,
    pub(super) action: OutputConfirmationAction,
    reply: mpsc::SyncSender<OutputConfirmationReply>,
}

impl PendingOutputConfirmation {
    pub(super) fn reply(self, result: OutputConfirmationReply) {
        let _ = self.reply.send(result);
    }
}

pub(super) type UiDevelopmentReply = Result<UiDevelopmentState, OutputControlFailure>;

#[derive(Debug)]
pub(super) struct PendingUiDevelopment {
    pub(super) command: UiDevelopmentCommand,
    reply: mpsc::SyncSender<UiDevelopmentReply>,
}

impl PendingUiDevelopment {
    pub(super) fn reply(self, result: UiDevelopmentReply) {
        let _ = self.reply.send(result);
    }
}

#[derive(Debug)]
pub(super) enum ControlEvent {
    OutputApply(PendingOutputApply),
    OutputConfirmation(PendingOutputConfirmation),
    UiDevelopment(PendingUiDevelopment),
}

#[derive(Debug, Deserialize)]
struct RequestEnvelope {
    version: u32,
    id: u64,
    method: String,
    #[serde(default)]
    params: Value,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct UiWorkspaceParams {
    path: PathBuf,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct UiAutoReloadParams {
    enabled: bool,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct OutputConfirmationParams {
    token: u64,
}

pub(super) struct OutputControlServer {
    socket_path: PathBuf,
    socket_device: u64,
    socket_inode: u64,
    publisher: OutputControlPublisher,
    stopping: Arc<AtomicBool>,
    shutdown: UnixStream,
    worker: Option<JoinHandle<()>>,
}

impl OutputControlServer {
    pub(super) fn start(
        initial: OutputControlState,
    ) -> Result<(Self, Channel<ControlEvent>), Box<dyn Error>> {
        let path = default_socket_path()?;
        Self::start_at(path, initial)
    }

    fn start_at(
        socket_path: PathBuf,
        initial: OutputControlState,
    ) -> Result<(Self, Channel<ControlEvent>), Box<dyn Error>> {
        prepare_socket_path(&socket_path)?;
        let listener = UnixListener::bind(&socket_path)?;
        fs::set_permissions(&socket_path, Permissions::from_mode(0o600))?;
        let metadata = fs::symlink_metadata(&socket_path)?;
        listener.set_nonblocking(true)?;

        let publisher = OutputControlPublisher::new(initial);
        let worker_publisher = publisher.clone();
        let stopping = Arc::new(AtomicBool::new(false));
        let worker_stopping = Arc::clone(&stopping);
        let (shutdown, worker_shutdown) = UnixStream::pair()?;
        let (events, source) = sync_channel(EVENT_QUEUE_CAPACITY);
        let worker = thread::Builder::new()
            .name("denial-control".into())
            .spawn(move || {
                crate::cpu_scheduling::normalize_current_worker("output-control");
                serve(
                    listener,
                    worker_shutdown,
                    worker_publisher,
                    events,
                    worker_stopping,
                );
            })?;

        info!(
            path = %socket_path.display(),
            protocol_version = PROTOCOL_VERSION,
            "Denial control socket listening"
        );
        Ok((
            Self {
                socket_path,
                socket_device: metadata.dev(),
                socket_inode: metadata.ino(),
                publisher,
                stopping,
                shutdown,
                worker: Some(worker),
            },
            source,
        ))
    }

    pub(super) fn socket_path(&self) -> &Path {
        &self.socket_path
    }

    pub(super) fn socket_path_os_string(&self) -> OsString {
        self.socket_path.as_os_str().to_os_string()
    }

    pub(super) fn publisher(&self) -> OutputControlPublisher {
        self.publisher.clone()
    }
}

impl Drop for OutputControlServer {
    fn drop(&mut self) {
        self.stopping.store(true, Ordering::Release);
        let _ = self.shutdown.shutdown(Shutdown::Both);
        if let Some(worker) = self.worker.take()
            && worker.join().is_err()
        {
            warn!("Denial control worker panicked during shutdown");
        }
        let owned_socket = fs::symlink_metadata(&self.socket_path)
            .ok()
            .is_some_and(|metadata| {
                metadata.file_type().is_socket()
                    && metadata.dev() == self.socket_device
                    && metadata.ino() == self.socket_inode
            });
        if !owned_socket {
            return;
        }
        match fs::remove_file(&self.socket_path) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => warn!(
                path = %self.socket_path.display(),
                %error,
                "could not remove Denial control socket"
            ),
        }
    }
}

fn default_socket_path() -> Result<PathBuf, Box<dyn Error>> {
    let runtime = std::env::var_os("XDG_RUNTIME_DIR")
        .ok_or("XDG_RUNTIME_DIR is required for Denial control")?;
    let runtime = PathBuf::from(runtime);
    if !runtime.is_absolute() {
        return Err("XDG_RUNTIME_DIR must be an absolute path".into());
    }
    let directory = runtime.join(SOCKET_DIRECTORY);
    match fs::symlink_metadata(&directory) {
        Ok(metadata) if metadata.file_type().is_dir() => {
            fs::set_permissions(&directory, Permissions::from_mode(0o700))?;
        }
        Ok(_) => {
            return Err(format!("{} exists but is not a directory", directory.display()).into());
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            DirBuilder::new().mode(0o700).create(&directory)?;
        }
        Err(error) => return Err(error.into()),
    }
    Ok(directory.join(SOCKET_FILE))
}

fn prepare_socket_path(path: &Path) -> Result<(), Box<dyn Error>> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.into()),
    };
    if !metadata.file_type().is_socket() {
        return Err(format!(
            "refusing to replace non-socket Denial control path {}",
            path.display()
        )
        .into());
    }

    match UnixStream::connect(path) {
        Ok(_) => Err(format!(
            "another Denial control server is already listening at {}",
            path.display()
        )
        .into()),
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::ConnectionRefused | io::ErrorKind::NotFound
            ) =>
        {
            fs::remove_file(path)?;
            Ok(())
        }
        Err(error) => Err(format!(
            "could not determine whether {} is stale: {error}",
            path.display()
        )
        .into()),
    }
}

fn serve(
    listener: UnixListener,
    shutdown: UnixStream,
    publisher: OutputControlPublisher,
    events: SyncSender<ControlEvent>,
    stopping: Arc<AtomicBool>,
) {
    let mut poll_fds = [
        libc::pollfd {
            fd: listener.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        },
        libc::pollfd {
            fd: shutdown.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        },
    ];
    while !stopping.load(Ordering::Acquire) {
        // SAFETY: `poll_fds` points to two initialized pollfd values whose
        // backing listener and shutdown stream remain alive for this loop.
        let ready =
            unsafe { libc::poll(poll_fds.as_mut_ptr(), poll_fds.len() as libc::nfds_t, -1) };
        if ready < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            warn!(%error, "Denial control listener poll failed");
            break;
        }
        if poll_fds[1].revents != 0 || stopping.load(Ordering::Acquire) {
            break;
        }
        if poll_fds[0].revents == 0 {
            continue;
        }
        match listener.accept() {
            Ok((stream, _)) => {
                let result = handle_connection(stream, &publisher, &events);
                if let Err(error) = result {
                    warn!(%error, "Denial control client request failed");
                }
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => {
                warn!(%error, "Denial control listener failed");
                break;
            }
        }
    }
}

fn handle_connection(
    mut stream: UnixStream,
    publisher: &OutputControlPublisher,
    events: &SyncSender<ControlEvent>,
) -> io::Result<()> {
    stream.set_nonblocking(false)?;
    stream.set_read_timeout(Some(CLIENT_IO_TIMEOUT))?;
    stream.set_write_timeout(Some(CLIENT_IO_TIMEOUT))?;

    let request = match read_request(&stream) {
        Ok(request) => request,
        Err(error) => {
            return write_response(
                &mut stream,
                &error_response(None, "invalid_request", error.to_string()),
            );
        }
    };
    if request.version != PROTOCOL_VERSION {
        return write_response(
            &mut stream,
            &error_response(
                Some(request.id),
                "unsupported_version",
                format!(
                    "protocol version {} is unsupported; Denial provides version {}",
                    request.version, PROTOCOL_VERSION
                ),
            ),
        );
    }

    let response = match request.method.as_str() {
        "outputs.get" => success_response(request.id, publisher.snapshot()),
        "outputs.apply" => {
            let configuration =
                match serde_json::from_value::<ApplyOutputConfiguration>(request.params) {
                    Ok(configuration) => configuration,
                    Err(error) => {
                        return write_response(
                            &mut stream,
                            &error_response(Some(request.id), "invalid_params", error.to_string()),
                        );
                    }
                };
            let (reply, result) = mpsc::sync_channel(1);
            let pending = PendingOutputApply {
                configuration,
                reply,
            };
            match events.try_send(ControlEvent::OutputApply(pending)) {
                Err(mpsc::TrySendError::Full(_)) => error_response(
                    Some(request.id),
                    "busy",
                    "the compositor output transaction queue is full",
                ),
                Err(mpsc::TrySendError::Disconnected(_)) => error_response(
                    Some(request.id),
                    "unavailable",
                    "the compositor output transaction queue is unavailable",
                ),
                Ok(()) => match result.recv_timeout(APPLY_TIMEOUT) {
                    Ok(Ok(snapshot)) => success_response(request.id, snapshot),
                    Ok(Err(error)) => error_response(Some(request.id), &error.code, error.message),
                    Err(mpsc::RecvTimeoutError::Timeout) => error_response(
                        Some(request.id),
                        "timeout",
                        "the compositor did not finish the output transaction in time",
                    ),
                    Err(mpsc::RecvTimeoutError::Disconnected) => error_response(
                        Some(request.id),
                        "unavailable",
                        "the compositor stopped before finishing the output transaction",
                    ),
                },
            }
        }
        "outputs.confirm" | "outputs.rollback" => {
            let parameters =
                match serde_json::from_value::<OutputConfirmationParams>(request.params) {
                    Ok(parameters) if parameters.token != 0 => parameters,
                    Ok(_) => {
                        return write_response(
                            &mut stream,
                            &error_response(
                                Some(request.id),
                                "invalid_params",
                                "output confirmation token must be nonzero",
                            ),
                        );
                    }
                    Err(error) => {
                        return write_response(
                            &mut stream,
                            &error_response(Some(request.id), "invalid_params", error.to_string()),
                        );
                    }
                };
            let action = if request.method == "outputs.confirm" {
                OutputConfirmationAction::Keep
            } else {
                OutputConfirmationAction::Rollback
            };
            queue_output_confirmation(request.id, parameters.token, action, events)
        }
        "ui.get" => queue_ui_development(
            request.id,
            UiDevelopmentCommandKind::Query,
            None,
            false,
            events,
        ),
        "ui.live.enable" => queue_ui_development(
            request.id,
            UiDevelopmentCommandKind::EnableLiveDevelopment,
            None,
            false,
            events,
        ),
        "ui.live.disable" => queue_ui_development(
            request.id,
            UiDevelopmentCommandKind::DisableLiveDevelopment,
            None,
            false,
            events,
        ),
        "ui.workspace.set" => {
            let parameters = match serde_json::from_value::<UiWorkspaceParams>(request.params) {
                Ok(parameters) => parameters,
                Err(error) => {
                    return write_response(
                        &mut stream,
                        &error_response(Some(request.id), "invalid_params", error.to_string()),
                    );
                }
            };
            queue_ui_development(
                request.id,
                UiDevelopmentCommandKind::SetWorkspace,
                Some(parameters.path),
                false,
                events,
            )
        }
        "ui.reload" => queue_ui_development(
            request.id,
            UiDevelopmentCommandKind::HotReload,
            None,
            false,
            events,
        ),
        "ui.restart" => queue_ui_development(
            request.id,
            UiDevelopmentCommandKind::HotRestart,
            None,
            false,
            events,
        ),
        "ui.build" => queue_ui_development(
            request.id,
            UiDevelopmentCommandKind::BuildAndActivateOptimized,
            None,
            false,
            events,
        ),
        "ui.restore" => queue_ui_development(
            request.id,
            UiDevelopmentCommandKind::RestoreOfficial,
            None,
            false,
            events,
        ),
        "ui.revert" => queue_ui_development(
            request.id,
            UiDevelopmentCommandKind::RevertLastWorking,
            None,
            false,
            events,
        ),
        "ui.auto_reload.set" => {
            let parameters = match serde_json::from_value::<UiAutoReloadParams>(request.params) {
                Ok(parameters) => parameters,
                Err(error) => {
                    return write_response(
                        &mut stream,
                        &error_response(Some(request.id), "invalid_params", error.to_string()),
                    );
                }
            };
            queue_ui_development(
                request.id,
                UiDevelopmentCommandKind::SetAutoReload,
                None,
                parameters.enabled,
                events,
            )
        }
        _ => error_response(
            Some(request.id),
            "unknown_method",
            format!("unknown Denial control method {:?}", request.method),
        ),
    };
    write_response(&mut stream, &response)
}

fn queue_output_confirmation(
    id: u64,
    token: u64,
    action: OutputConfirmationAction,
    events: &SyncSender<ControlEvent>,
) -> Value {
    let (reply, result) = mpsc::sync_channel(1);
    let pending = PendingOutputConfirmation {
        token,
        action,
        reply,
    };
    match events.try_send(ControlEvent::OutputConfirmation(pending)) {
        Err(mpsc::TrySendError::Full(_)) => {
            error_response(Some(id), "busy", "the compositor control queue is full")
        }
        Err(mpsc::TrySendError::Disconnected(_)) => error_response(
            Some(id),
            "unavailable",
            "the compositor control queue is unavailable",
        ),
        Ok(()) => match result.recv_timeout(APPLY_TIMEOUT) {
            Ok(Ok(())) => success_response(id, json!({})),
            Ok(Err(error)) => error_response(Some(id), &error.code, error.message),
            Err(mpsc::RecvTimeoutError::Timeout) => error_response(
                Some(id),
                "timeout",
                "the compositor did not process the output confirmation in time",
            ),
            Err(mpsc::RecvTimeoutError::Disconnected) => error_response(
                Some(id),
                "unavailable",
                "the compositor stopped before processing the output confirmation",
            ),
        },
    }
}

fn queue_ui_development(
    id: u64,
    kind: UiDevelopmentCommandKind,
    workspace: Option<PathBuf>,
    auto_reload: bool,
    events: &SyncSender<ControlEvent>,
) -> Value {
    let request_id = match u32::try_from(id).ok().filter(|id| *id != 0) {
        Some(request_id) => request_id,
        None => {
            return error_response(
                Some(id),
                "invalid_request",
                "UI-development request IDs must fit a nonzero uint32",
            );
        }
    };
    let command = match UiDevelopmentCommand::from_control(kind, request_id, workspace, auto_reload)
    {
        Ok(command) => command,
        Err(error) => {
            return error_response(Some(id), "invalid_params", error.to_string());
        }
    };
    let (reply, result) = mpsc::sync_channel(1);
    let pending = PendingUiDevelopment { command, reply };
    match events.try_send(ControlEvent::UiDevelopment(pending)) {
        Err(mpsc::TrySendError::Full(_)) => {
            error_response(Some(id), "busy", "the compositor control queue is full")
        }
        Err(mpsc::TrySendError::Disconnected(_)) => error_response(
            Some(id),
            "unavailable",
            "the compositor control queue is unavailable",
        ),
        Ok(()) => match result.recv_timeout(UI_COMMAND_TIMEOUT) {
            Ok(Ok(snapshot)) => success_response(id, snapshot),
            Ok(Err(error)) => error_response(Some(id), &error.code, error.message),
            Err(mpsc::RecvTimeoutError::Timeout) => error_response(
                Some(id),
                "timeout",
                "the compositor did not process the UI-development command in time",
            ),
            Err(mpsc::RecvTimeoutError::Disconnected) => error_response(
                Some(id),
                "unavailable",
                "the compositor stopped before processing the UI-development command",
            ),
        },
    }
}

fn read_request(stream: &UnixStream) -> io::Result<RequestEnvelope> {
    let mut reader = BufReader::new(stream);
    let mut bytes = Vec::new();
    let read = reader
        .by_ref()
        .take((MAX_REQUEST_BYTES + 1) as u64)
        .read_until(b'\n', &mut bytes)?;
    if read == 0 {
        return Err(io::Error::new(
            io::ErrorKind::UnexpectedEof,
            "empty request",
        ));
    }
    if bytes.len() > MAX_REQUEST_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "request exceeds the 256 KiB limit",
        ));
    }
    while matches!(bytes.last(), Some(b'\n' | b'\r')) {
        bytes.pop();
    }
    serde_json::from_slice(&bytes)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

fn success_response(id: u64, result: impl Serialize) -> Value {
    json!({
        "version": PROTOCOL_VERSION,
        "id": id,
        "ok": true,
        "result": result,
    })
}

fn error_response(id: Option<u64>, code: &str, message: impl Into<String>) -> Value {
    json!({
        "version": PROTOCOL_VERSION,
        "id": id,
        "ok": false,
        "error": {
            "code": code,
            "message": message.into(),
        },
    })
}

fn write_response(stream: &mut UnixStream, response: &Value) -> io::Result<()> {
    serde_json::to_writer(&mut *stream, response)?;
    stream.write_all(b"\n")?;
    stream.flush()
}

#[cfg(test)]
mod tests {
    use super::*;
    use smithay::reexports::calloop::EventLoop;
    use smithay::reexports::calloop::channel::Event as ChannelEvent;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_DIRECTORY: AtomicU64 = AtomicU64::new(1);

    fn state(name: &str) -> OutputControlState {
        OutputControlState {
            capabilities: OutputControlCapabilities::default(),
            outputs: vec![OutputControlOutput {
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
        assert_eq!(publisher.publish(state("DP-1")).serial, initial);
        assert_eq!(
            publisher.publish(state("DP-2")).serial,
            initial.wrapping_add(1).max(1)
        );
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
                    assert_eq!(request.configuration.outputs[0].name, "DP-4");
                    request.reply(Ok(publisher.snapshot()));
                }
            })
            .expect("insert Denial control source");

        let client = thread::spawn(move || {
            let mut stream = UnixStream::connect(&path).expect("connect to server");
            let request = format!(
                "{{\"version\":1,\"id\":23,\"method\":\"outputs.apply\",\"params\":{{\"serial\":{serial},\"outputs\":[{{\"name\":\"DP-4\",\"enabled\":true,\"powered\":true,\"x\":0,\"y\":0,\"mode\":{{\"width\":1920,\"height\":1080,\"refresh_millihz\":60000}},\"scale\":1.0,\"transform\":\"normal\",\"adaptive_sync\":false}}]}}}}\n"
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
}
