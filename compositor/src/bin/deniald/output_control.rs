//! Versioned, compositor-owned output-management IPC.
//!
//! The protocol deliberately exposes Denial's output model instead of
//! impersonating another compositor. Clients connect to `DENIAL_SOCKET`, send
//! one newline-delimited JSON request, read one response, and close.

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

pub(super) const PROTOCOL_VERSION: u32 = 1;

const SOCKET_DIRECTORY: &str = "denial";
const SOCKET_FILE: &str = "control.sock";
const EVENT_QUEUE_CAPACITY: usize = 8;
const MAX_REQUEST_BYTES: usize = 256 * 1024;
const CLIENT_IO_TIMEOUT: Duration = Duration::from_secs(3);
const APPLY_TIMEOUT: Duration = Duration::from_secs(15);

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
            // Denial's topology understands transforms, but the shared-atlas
            // scanout path does not yet rotate pixels. Do not advertise a
            // control until the complete render/KMS path implements it.
            transform: false,
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
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub(super) struct OutputControlSnapshot {
    pub(super) serial: u64,
    pub(super) capabilities: OutputControlCapabilities,
    pub(super) outputs: Vec<OutputControlOutput>,
}

impl OutputControlSnapshot {
    fn new(state: OutputControlState) -> Self {
        Self {
            serial: initial_serial(),
            capabilities: state.capabilities,
            outputs: state.outputs,
        }
    }

    fn same_state(&self, state: &OutputControlState) -> bool {
        self.capabilities == state.capabilities && self.outputs == state.outputs
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
        }
        snapshot.clone()
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

#[derive(Debug, Deserialize)]
struct RequestEnvelope {
    version: u32,
    id: u64,
    method: String,
    #[serde(default)]
    params: Value,
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
    ) -> Result<(Self, Channel<PendingOutputApply>), Box<dyn Error>> {
        let path = default_socket_path()?;
        Self::start_at(path, initial)
    }

    fn start_at(
        socket_path: PathBuf,
        initial: OutputControlState,
    ) -> Result<(Self, Channel<PendingOutputApply>), Box<dyn Error>> {
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
            .name("denial-output-control".into())
            .spawn(move || {
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
            "output-control socket listening"
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
            warn!("output-control worker panicked during shutdown");
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
                "could not remove output-control socket"
            ),
        }
    }
}

fn default_socket_path() -> Result<PathBuf, Box<dyn Error>> {
    let runtime = std::env::var_os("XDG_RUNTIME_DIR")
        .ok_or("XDG_RUNTIME_DIR is required for Denial output control")?;
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
            "refusing to replace non-socket output-control path {}",
            path.display()
        )
        .into());
    }

    match UnixStream::connect(path) {
        Ok(_) => Err(format!(
            "another Denial output-control server is already listening at {}",
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
    events: SyncSender<PendingOutputApply>,
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
            warn!(%error, "output-control listener poll failed");
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
                    warn!(%error, "output-control client request failed");
                }
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => {
                warn!(%error, "output-control listener failed");
                break;
            }
        }
    }
}

fn handle_connection(
    mut stream: UnixStream,
    publisher: &OutputControlPublisher,
    events: &SyncSender<PendingOutputApply>,
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
            match events.try_send(pending) {
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
        _ => error_response(
            Some(request.id),
            "unknown_method",
            format!("unknown output-control method {:?}", request.method),
        ),
    };
    write_response(&mut stream, &response)
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
        }
    }

    fn socket_path() -> PathBuf {
        let suffix = NEXT_DIRECTORY.fetch_add(1, Ordering::Relaxed);
        let directory = std::env::temp_dir().join(format!(
            "denial-output-control-test-{}-{suffix}",
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
                if let ChannelEvent::Msg(request) = event {
                    assert_eq!(request.configuration.serial, serial);
                    assert_eq!(request.configuration.outputs[0].name, "DP-4");
                    request.reply(Ok(publisher.snapshot()));
                }
            })
            .expect("insert output-control source");

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
        let response = client.join().expect("join output-control client");
        assert_eq!(response["id"], 23);
        assert_eq!(response["ok"], true);
        assert_eq!(response["result"]["outputs"][0]["name"], "DP-4");

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
        assert!(error.to_string().contains("refusing to replace non-socket"));
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
