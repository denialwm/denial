//! Versioned, compositor-owned control IPC.
//!
//! The socket carries output transactions and shell-independent Flutter UI
//! lifecycle/recovery commands. It deliberately exposes Denial's own model
//! instead of impersonating another compositor. Clients connect to
//! `DENIAL_SOCKET` and send one newline-delimited JSON request. Ordinary
//! commands receive one response and close; explicit subscriptions remain
//! open and receive revisioned snapshots as state changes.

use std::error::Error;
use std::ffi::OsString;
use std::fs::{self, DirBuilder, Permissions};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::Shutdown;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, RwLock, mpsc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use smithay::reexports::calloop::channel::{Channel, SyncSender, sync_channel};
use tracing::{info, warn};

use super::ui_development::{
    CommandKind as UiDevelopmentCommandKind, UiDevelopmentCommand, UiDevelopmentState,
};
use super::{
    native_shortcut::ShortcutBinding,
    settings::{KeyboardSettings, TouchpadSettings},
    system_controls::{AudioRequest, BrightnessRequest},
};

pub(super) const PROTOCOL_VERSION: u32 = 1;

const SOCKET_DIRECTORY: &str = "denial";
const SOCKET_FILE: &str = "control.sock";
const EVENT_QUEUE_CAPACITY: usize = 8;
const MAX_CLIENT_WORKERS: usize = 32;
const MAX_REQUEST_BYTES: usize = 256 * 1024;
const CLIENT_IO_TIMEOUT: Duration = Duration::from_secs(3);
const SUBSCRIBER_HEALTH_POLL_INTERVAL: Duration = Duration::from_millis(250);
const APPLY_TIMEOUT: Duration = Duration::from_secs(15);
const SHELL_COMMAND_TIMEOUT: Duration = Duration::from_secs(5);
const SETTINGS_COMMAND_TIMEOUT: Duration = Duration::from_secs(5);
const SYSTEM_CONTROL_TIMEOUT: Duration = Duration::from_secs(5);
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
    pub(super) monitor_id: i64,
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
    pub(super) adaptive_sync_supported: bool,
    pub(super) adaptive_sync: bool,
    pub(super) current_mode: Option<OutputControlMode>,
    pub(super) modes: Vec<OutputControlMode>,
}

#[derive(Clone, Debug, PartialEq)]
pub(super) struct OutputControlState {
    pub(super) capabilities: OutputControlCapabilities,
    pub(super) primary_output: Option<String>,
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
    pub(super) primary_output: Option<String>,
    pub(super) outputs: Vec<OutputControlOutput>,
    pub(super) pending_confirmation: Option<OutputControlConfirmation>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
struct SettingsDocumentSnapshot {
    revision: u64,
    document: String,
}

#[derive(Clone)]
struct SettingsDocumentPublisher {
    state: Arc<(Mutex<SettingsDocumentSnapshot>, Condvar)>,
}

enum SettingsDocumentWait {
    Changed(SettingsDocumentSnapshot),
    TimedOut,
    Stopped,
}

impl SettingsDocumentPublisher {
    fn new(revision: u64, document: String) -> Self {
        Self {
            state: Arc::new((
                Mutex::new(SettingsDocumentSnapshot { revision, document }),
                Condvar::new(),
            )),
        }
    }

    fn snapshot(&self) -> SettingsDocumentSnapshot {
        self.state
            .0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    fn revision(&self) -> u64 {
        self.state
            .0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .revision
    }

    fn publish(&self, revision: u64, document: String) -> bool {
        let (state, changed) = &*self.state;
        let mut snapshot = state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if revision <= snapshot.revision {
            return false;
        }
        *snapshot = SettingsDocumentSnapshot { revision, document };
        changed.notify_all();
        true
    }

    fn wait_for_change(&self, revision: u64, stopping: &AtomicBool) -> SettingsDocumentWait {
        let (state, changed) = &*self.state;
        let snapshot = state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if snapshot.revision > revision {
            return SettingsDocumentWait::Changed(snapshot.clone());
        }
        if stopping.load(Ordering::Acquire) {
            return SettingsDocumentWait::Stopped;
        }
        let (snapshot, _) = changed
            .wait_timeout(snapshot, SUBSCRIBER_HEALTH_POLL_INTERVAL)
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if stopping.load(Ordering::Acquire) {
            SettingsDocumentWait::Stopped
        } else if snapshot.revision > revision {
            SettingsDocumentWait::Changed(snapshot.clone())
        } else {
            SettingsDocumentWait::TimedOut
        }
    }

    fn wake_all(&self) {
        self.state.1.notify_all();
    }
}

struct ActiveControlClient {
    count: Arc<AtomicUsize>,
}

impl ActiveControlClient {
    fn acquire(count: &Arc<AtomicUsize>) -> Option<Self> {
        count
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |active| {
                (active < MAX_CLIENT_WORKERS).then_some(active + 1)
            })
            .ok()?;
        Some(Self {
            count: Arc::clone(count),
        })
    }
}

impl Drop for ActiveControlClient {
    fn drop(&mut self) {
        self.count.fetch_sub(1, Ordering::AcqRel);
    }
}

impl OutputControlSnapshot {
    fn new(state: OutputControlState) -> Self {
        Self {
            serial: initial_serial(),
            capabilities: state.capabilities,
            primary_output: state.primary_output,
            outputs: state.outputs,
            pending_confirmation: state.pending_confirmation,
        }
    }

    fn same_state(&self, state: &OutputControlState) -> bool {
        self.capabilities == state.capabilities
            && self.primary_output == state.primary_output
            && self.outputs == state.outputs
            && self.pending_confirmation == state.pending_confirmation
    }
}

// Output-control identifiers cross a JSON boundary into Dart. Keep them in
// the integer range that every JSON consumer, including JavaScript-backed
// Dart runtimes, can represent exactly.
const MAX_EXACT_JSON_INTEGER: u64 = (1_u64 << 53) - 1;

fn initial_serial() -> u64 {
    let wall_clock = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or_default();
    let mixed = wall_clock
        .rotate_left(17)
        .wrapping_add(u64::from(std::process::id()));
    mixed % MAX_EXACT_JSON_INTEGER + 1
}

pub(super) fn next_serial(serial: u64) -> u64 {
    if serial >= MAX_EXACT_JSON_INTEGER {
        1
    } else {
        serial + 1
    }
}

#[derive(Clone)]
pub(super) struct OutputControlPublisher {
    snapshot: Arc<RwLock<OutputControlSnapshot>>,
    settings_documents: SettingsDocumentPublisher,
}

impl OutputControlPublisher {
    #[cfg(test)]
    fn new(initial: OutputControlState) -> Self {
        Self::with_settings(initial, 1, "{}".to_owned())
    }

    fn with_settings(
        initial: OutputControlState,
        settings_revision: u64,
        settings_document: String,
    ) -> Self {
        Self {
            snapshot: Arc::new(RwLock::new(OutputControlSnapshot::new(initial))),
            settings_documents: SettingsDocumentPublisher::new(
                settings_revision,
                settings_document,
            ),
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
            snapshot.serial = next_serial(snapshot.serial);
            snapshot.capabilities = state.capabilities;
            snapshot.primary_output = state.primary_output;
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

    pub(super) fn settings_document_revision(&self) -> u64 {
        self.settings_documents.revision()
    }

    pub(super) fn publish_settings_document(&self, revision: u64, document: String) -> bool {
        self.settings_documents.publish(revision, document)
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
    pub(super) primary_output: Option<String>,
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

pub(super) type ShellControlReply = Result<(), OutputControlFailure>;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum ShellControlCommand {
    OpenWallpaper,
}

#[derive(Debug)]
pub(super) struct PendingShellControl {
    pub(super) command: ShellControlCommand,
    reply: mpsc::SyncSender<ShellControlReply>,
}

impl PendingShellControl {
    pub(super) fn reply(self, result: ShellControlReply) {
        let _ = self.reply.send(result);
    }
}

pub(super) type SettingsReply = Result<Value, OutputControlFailure>;

#[derive(Debug)]
pub(super) enum SettingsControlCommand {
    ReadDocument,
    WriteDocument {
        expected_revision: u64,
        document: String,
    },
    ReadKeyboard,
    WriteKeyboard {
        expected_revision: u64,
        keyboard: KeyboardSettings,
    },
    ReadInputDevices,
    WriteTouchpad {
        expected_revision: u64,
        touchpad: TouchpadSettings,
    },
    ReadShortcuts,
    ValidateShortcut {
        shortcut: ShortcutBinding,
        existing_shortcut: Option<String>,
    },
    AddShortcut {
        expected_revision: u64,
        shortcut: ShortcutBinding,
    },
    UpdateShortcut {
        expected_revision: u64,
        existing_shortcut: String,
        shortcut: ShortcutBinding,
    },
    RemoveShortcut {
        expected_revision: u64,
        shortcut: String,
    },
    RestoreShortcuts {
        expected_revision: u64,
    },
}

#[derive(Debug)]
pub(super) struct PendingSettingsControl {
    pub(super) command: SettingsControlCommand,
    reply: mpsc::SyncSender<SettingsReply>,
}

impl PendingSettingsControl {
    pub(super) fn into_parts(self) -> (SettingsControlCommand, mpsc::SyncSender<SettingsReply>) {
        (self.command, self.reply)
    }
}

pub(super) type SystemControlReply = Result<Value, OutputControlFailure>;
pub(super) type SystemControlReplySender = mpsc::SyncSender<SystemControlReply>;

#[derive(Debug)]
pub(super) enum SystemControlCommand {
    Audio(AudioRequest),
    Brightness(BrightnessRequest),
}

#[derive(Debug)]
pub(super) struct PendingSystemControl {
    pub(super) command: SystemControlCommand,
    reply: SystemControlReplySender,
}

impl PendingSystemControl {
    pub(super) fn into_parts(self) -> (SystemControlCommand, SystemControlReplySender) {
        (self.command, self.reply)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum SystemControlWaitKind {
    AudioLevel,
    AudioStreams,
    AudioDevices,
    Brightness(i64),
}

#[derive(Debug)]
pub(super) struct PendingSystemControlWait {
    pub(super) kind: SystemControlWaitKind,
    pub(super) reply: SystemControlReplySender,
    expires_at: Instant,
}

impl PendingSystemControlWait {
    pub(super) fn new(kind: SystemControlWaitKind, reply: SystemControlReplySender) -> Self {
        Self {
            kind,
            reply,
            expires_at: Instant::now() + SYSTEM_CONTROL_TIMEOUT,
        }
    }

    pub(super) fn expired(&self, now: Instant) -> bool {
        self.expires_at <= now
    }
}

#[derive(Debug)]
pub(super) enum ControlEvent {
    OutputApply(PendingOutputApply),
    OutputConfirmation(PendingOutputConfirmation),
    Shell(PendingShellControl),
    Settings(PendingSettingsControl),
    SystemControl(PendingSystemControl),
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

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct SettingsDocumentWriteParams {
    expected_revision: u64,
    document: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct KeyboardWriteParams {
    expected_revision: u64,
    keyboard: KeyboardSettings,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct TouchpadWriteParams {
    expected_revision: u64,
    touchpad: TouchpadSettings,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ShortcutValidationParams {
    shortcut: ShortcutBinding,
    #[serde(default)]
    existing_shortcut: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ShortcutWriteParams {
    expected_revision: u64,
    shortcut: ShortcutBinding,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ShortcutUpdateParams {
    expected_revision: u64,
    existing_shortcut: String,
    shortcut: ShortcutBinding,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ShortcutRemoveParams {
    expected_revision: u64,
    shortcut: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RevisionParams {
    expected_revision: u64,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct AudioLevelParams {
    percent: u8,
    #[serde(default)]
    request_serial: u32,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct AudioStreamLevelParams {
    stream_id: u32,
    percent: u8,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct AudioDeviceParams {
    name: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct BrightnessParams {
    monitor_id: i64,
    connector: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct BrightnessLevelParams {
    monitor_id: i64,
    connector: String,
    percent: u8,
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
        settings_revision: u64,
        settings_document: String,
    ) -> Result<(Self, Channel<ControlEvent>), Box<dyn Error>> {
        let path = default_socket_path()?;
        Self::start_at_with_settings(path, initial, settings_revision, settings_document)
    }

    #[cfg(test)]
    fn start_at(
        socket_path: PathBuf,
        initial: OutputControlState,
    ) -> Result<(Self, Channel<ControlEvent>), Box<dyn Error>> {
        Self::start_at_with_settings(socket_path, initial, 1, "{}".to_owned())
    }

    fn start_at_with_settings(
        socket_path: PathBuf,
        initial: OutputControlState,
        settings_revision: u64,
        settings_document: String,
    ) -> Result<(Self, Channel<ControlEvent>), Box<dyn Error>> {
        prepare_socket_path(&socket_path)?;
        let listener = UnixListener::bind(&socket_path)?;
        fs::set_permissions(&socket_path, Permissions::from_mode(0o600))?;
        let metadata = fs::symlink_metadata(&socket_path)?;
        listener.set_nonblocking(true)?;

        let publisher =
            OutputControlPublisher::with_settings(initial, settings_revision, settings_document);
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
        self.publisher.settings_documents.wake_all();
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
    let active_clients = Arc::new(AtomicUsize::new(0));
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
                let Some(client_slot) = ActiveControlClient::acquire(&active_clients) else {
                    let _ = stream.shutdown(Shutdown::Both);
                    continue;
                };
                let connection_publisher = publisher.clone();
                let connection_events = events.clone();
                let connection_stopping = Arc::clone(&stopping);
                let spawn = thread::Builder::new()
                    .name("denial-control-client".into())
                    .spawn(move || {
                        let _client_slot = client_slot;
                        let result = handle_connection(
                            stream,
                            &connection_publisher,
                            &connection_events,
                            &connection_stopping,
                        );
                        if let Err(error) = result {
                            warn!(%error, "Denial control client request failed");
                        }
                    });
                if let Err(error) = spawn {
                    warn!(%error, "could not start Denial control client worker");
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
    stopping: &AtomicBool,
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

    if request.method == "settings.document.subscribe" {
        return stream_settings_documents(&mut stream, request.id, publisher, stopping);
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
        "shell.wallpaper.open" => {
            queue_shell_control(request.id, ShellControlCommand::OpenWallpaper, events)
        }
        "settings.document.get" => {
            queue_settings(request.id, SettingsControlCommand::ReadDocument, events)
        }
        "settings.document.apply" => {
            let parameters = match serde_json::from_value::<SettingsDocumentWriteParams>(
                request.params,
            ) {
                Ok(parameters)
                    if parameters.expected_revision != 0
                        && !parameters.document.is_empty()
                        && parameters.document.len() <= MAX_REQUEST_BYTES =>
                {
                    parameters
                }
                Ok(_) => {
                    return write_response(
                        &mut stream,
                        &error_response(
                            Some(request.id),
                            "invalid_params",
                            "settings revision must be nonzero and the document must be nonempty",
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
            queue_settings(
                request.id,
                SettingsControlCommand::WriteDocument {
                    expected_revision: parameters.expected_revision,
                    document: parameters.document,
                },
                events,
            )
        }
        "settings.keyboard.get" => {
            queue_settings(request.id, SettingsControlCommand::ReadKeyboard, events)
        }
        "settings.keyboard.apply" => {
            let parameters =
                match parse_settings_params::<KeyboardWriteParams>(request.id, request.params) {
                    Ok(parameters) if parameters.expected_revision != 0 => parameters,
                    Ok(_) => {
                        return write_response(
                            &mut stream,
                            &error_response(
                                Some(request.id),
                                "invalid_params",
                                "settings revision must be nonzero",
                            ),
                        );
                    }
                    Err(response) => return write_response(&mut stream, &response),
                };
            queue_settings(
                request.id,
                SettingsControlCommand::WriteKeyboard {
                    expected_revision: parameters.expected_revision,
                    keyboard: parameters.keyboard,
                },
                events,
            )
        }
        "settings.input.get" => {
            queue_settings(request.id, SettingsControlCommand::ReadInputDevices, events)
        }
        "settings.touchpad.apply" => {
            let parameters =
                match parse_settings_params::<TouchpadWriteParams>(request.id, request.params) {
                    Ok(parameters) if parameters.expected_revision != 0 => parameters,
                    Ok(_) => {
                        return write_response(
                            &mut stream,
                            &error_response(
                                Some(request.id),
                                "invalid_params",
                                "settings revision must be nonzero",
                            ),
                        );
                    }
                    Err(response) => return write_response(&mut stream, &response),
                };
            queue_settings(
                request.id,
                SettingsControlCommand::WriteTouchpad {
                    expected_revision: parameters.expected_revision,
                    touchpad: parameters.touchpad,
                },
                events,
            )
        }
        "settings.shortcuts.get" => {
            queue_settings(request.id, SettingsControlCommand::ReadShortcuts, events)
        }
        "settings.shortcuts.validate" => {
            let parameters =
                match parse_settings_params::<ShortcutValidationParams>(request.id, request.params)
                {
                    Ok(parameters) => parameters,
                    Err(response) => return write_response(&mut stream, &response),
                };
            queue_settings(
                request.id,
                SettingsControlCommand::ValidateShortcut {
                    shortcut: parameters.shortcut,
                    existing_shortcut: parameters.existing_shortcut,
                },
                events,
            )
        }
        "settings.shortcuts.add" => {
            let parameters =
                match parse_settings_params::<ShortcutWriteParams>(request.id, request.params) {
                    Ok(parameters) if parameters.expected_revision != 0 => parameters,
                    Ok(_) => return write_response(&mut stream, &invalid_revision(request.id)),
                    Err(response) => return write_response(&mut stream, &response),
                };
            queue_settings(
                request.id,
                SettingsControlCommand::AddShortcut {
                    expected_revision: parameters.expected_revision,
                    shortcut: parameters.shortcut,
                },
                events,
            )
        }
        "settings.shortcuts.update" => {
            let parameters =
                match parse_settings_params::<ShortcutUpdateParams>(request.id, request.params) {
                    Ok(parameters)
                        if parameters.expected_revision != 0
                            && !parameters.existing_shortcut.is_empty() =>
                    {
                        parameters
                    }
                    Ok(_) => return write_response(&mut stream, &invalid_revision(request.id)),
                    Err(response) => return write_response(&mut stream, &response),
                };
            queue_settings(
                request.id,
                SettingsControlCommand::UpdateShortcut {
                    expected_revision: parameters.expected_revision,
                    existing_shortcut: parameters.existing_shortcut,
                    shortcut: parameters.shortcut,
                },
                events,
            )
        }
        "settings.shortcuts.remove" => {
            let parameters =
                match parse_settings_params::<ShortcutRemoveParams>(request.id, request.params) {
                    Ok(parameters)
                        if parameters.expected_revision != 0 && !parameters.shortcut.is_empty() =>
                    {
                        parameters
                    }
                    Ok(_) => return write_response(&mut stream, &invalid_revision(request.id)),
                    Err(response) => return write_response(&mut stream, &response),
                };
            queue_settings(
                request.id,
                SettingsControlCommand::RemoveShortcut {
                    expected_revision: parameters.expected_revision,
                    shortcut: parameters.shortcut,
                },
                events,
            )
        }
        "settings.shortcuts.restore" => {
            let parameters =
                match parse_settings_params::<RevisionParams>(request.id, request.params) {
                    Ok(parameters) if parameters.expected_revision != 0 => parameters,
                    Ok(_) => return write_response(&mut stream, &invalid_revision(request.id)),
                    Err(response) => return write_response(&mut stream, &response),
                };
            queue_settings(
                request.id,
                SettingsControlCommand::RestoreShortcuts {
                    expected_revision: parameters.expected_revision,
                },
                events,
            )
        }
        "audio.get" => queue_system_control(
            request.id,
            SystemControlCommand::Audio(AudioRequest::ReadLevel),
            events,
        ),
        "audio.set" => {
            let parameters =
                match parse_settings_params::<AudioLevelParams>(request.id, request.params) {
                    Ok(parameters) if parameters.percent <= 100 => parameters,
                    Ok(_) => {
                        return write_response(
                            &mut stream,
                            &error_response(
                                Some(request.id),
                                "invalid_params",
                                "audio percent must be between 0 and 100",
                            ),
                        );
                    }
                    Err(response) => return write_response(&mut stream, &response),
                };
            queue_system_control(
                request.id,
                SystemControlCommand::Audio(AudioRequest::SetLevel {
                    level: f64::from(parameters.percent) / 100.0,
                    request_serial: parameters.request_serial,
                }),
                events,
            )
        }
        "audio.streams.get" => queue_system_control(
            request.id,
            SystemControlCommand::Audio(AudioRequest::RequestStreams),
            events,
        ),
        "audio.stream.set" => {
            let parameters =
                match parse_settings_params::<AudioStreamLevelParams>(request.id, request.params) {
                    Ok(parameters) if parameters.percent <= 100 => parameters,
                    Ok(_) => {
                        return write_response(
                            &mut stream,
                            &error_response(
                                Some(request.id),
                                "invalid_params",
                                "audio percent must be between 0 and 100",
                            ),
                        );
                    }
                    Err(response) => return write_response(&mut stream, &response),
                };
            queue_system_control(
                request.id,
                SystemControlCommand::Audio(AudioRequest::SetStreamLevel {
                    stream_id: parameters.stream_id,
                    level: f64::from(parameters.percent) / 100.0,
                }),
                events,
            )
        }
        "audio.devices.get" => queue_system_control(
            request.id,
            SystemControlCommand::Audio(AudioRequest::RequestDevices),
            events,
        ),
        "audio.device.set" => {
            let parameters =
                match parse_settings_params::<AudioDeviceParams>(request.id, request.params) {
                    Ok(parameters)
                        if !parameters.name.is_empty()
                            && parameters.name.len() <= 1024
                            && !parameters.name.contains('\0') =>
                    {
                        parameters
                    }
                    Ok(_) => {
                        return write_response(
                            &mut stream,
                            &error_response(
                                Some(request.id),
                                "invalid_params",
                                "audio device name must be between 1 and 1024 bytes",
                            ),
                        );
                    }
                    Err(response) => return write_response(&mut stream, &response),
                };
            queue_system_control(
                request.id,
                SystemControlCommand::Audio(AudioRequest::SetDevice {
                    name: parameters.name,
                }),
                events,
            )
        }
        "brightness.get" => {
            let parameters =
                match parse_settings_params::<BrightnessParams>(request.id, request.params) {
                    Ok(parameters) if valid_brightness_target(&parameters) => parameters,
                    Ok(_) => {
                        return write_response(
                            &mut stream,
                            &error_response(
                                Some(request.id),
                                "invalid_params",
                                "brightness requires a valid monitor ID and connector",
                            ),
                        );
                    }
                    Err(response) => return write_response(&mut stream, &response),
                };
            queue_system_control(
                request.id,
                SystemControlCommand::Brightness(BrightnessRequest::Read {
                    connector: parameters.connector,
                    monitor_id: parameters.monitor_id,
                }),
                events,
            )
        }
        "brightness.set" => {
            let parameters =
                match parse_settings_params::<BrightnessLevelParams>(request.id, request.params) {
                    Ok(parameters)
                        if parameters.percent <= 100
                            && valid_brightness_values(
                                parameters.monitor_id,
                                &parameters.connector,
                            ) =>
                    {
                        parameters
                    }
                    Ok(_) => {
                        return write_response(
                            &mut stream,
                            &error_response(
                                Some(request.id),
                                "invalid_params",
                                "brightness requires percent 0-100 and a valid output",
                            ),
                        );
                    }
                    Err(response) => return write_response(&mut stream, &response),
                };
            queue_system_control(
                request.id,
                SystemControlCommand::Brightness(BrightnessRequest::Set {
                    connector: parameters.connector,
                    monitor_id: parameters.monitor_id,
                    level: f64::from(parameters.percent) / 100.0,
                }),
                events,
            )
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

fn parse_settings_params<T: for<'de> Deserialize<'de>>(id: u64, params: Value) -> Result<T, Value> {
    serde_json::from_value(params)
        .map_err(|error| error_response(Some(id), "invalid_params", error.to_string()))
}

fn invalid_revision(id: u64) -> Value {
    error_response(
        Some(id),
        "invalid_params",
        "settings revision and shortcut identity must be nonempty",
    )
}

fn valid_brightness_target(parameters: &BrightnessParams) -> bool {
    valid_brightness_values(parameters.monitor_id, &parameters.connector)
}

fn valid_brightness_values(monitor_id: i64, connector: &str) -> bool {
    monitor_id >= 0 && !connector.is_empty() && connector.len() <= 128 && !connector.contains('\0')
}

fn queue_settings(
    id: u64,
    command: SettingsControlCommand,
    events: &SyncSender<ControlEvent>,
) -> Value {
    let (reply, result) = mpsc::sync_channel(1);
    let pending = PendingSettingsControl { command, reply };
    match events.try_send(ControlEvent::Settings(pending)) {
        Err(mpsc::TrySendError::Full(_)) => {
            error_response(Some(id), "busy", "the compositor control queue is full")
        }
        Err(mpsc::TrySendError::Disconnected(_)) => error_response(
            Some(id),
            "unavailable",
            "the compositor control queue is unavailable",
        ),
        Ok(()) => match result.recv_timeout(SETTINGS_COMMAND_TIMEOUT) {
            Ok(Ok(document)) => success_response(id, document),
            Ok(Err(error)) => error_response(Some(id), &error.code, error.message),
            Err(mpsc::RecvTimeoutError::Timeout) => error_response(
                Some(id),
                "timeout",
                "the compositor did not process the settings request in time",
            ),
            Err(mpsc::RecvTimeoutError::Disconnected) => error_response(
                Some(id),
                "unavailable",
                "the compositor stopped before processing the settings request",
            ),
        },
    }
}

fn queue_shell_control(
    id: u64,
    command: ShellControlCommand,
    events: &SyncSender<ControlEvent>,
) -> Value {
    let (reply, result) = mpsc::sync_channel(1);
    let pending = PendingShellControl { command, reply };
    match events.try_send(ControlEvent::Shell(pending)) {
        Err(mpsc::TrySendError::Full(_)) => {
            error_response(Some(id), "busy", "the compositor control queue is full")
        }
        Err(mpsc::TrySendError::Disconnected(_)) => error_response(
            Some(id),
            "unavailable",
            "the compositor control queue is unavailable",
        ),
        Ok(()) => match result.recv_timeout(SHELL_COMMAND_TIMEOUT) {
            Ok(Ok(())) => success_response(id, json!({})),
            Ok(Err(error)) => error_response(Some(id), &error.code, error.message),
            Err(mpsc::RecvTimeoutError::Timeout) => error_response(
                Some(id),
                "timeout",
                "the compositor did not process the shell command in time",
            ),
            Err(mpsc::RecvTimeoutError::Disconnected) => error_response(
                Some(id),
                "unavailable",
                "the compositor stopped before processing the shell command",
            ),
        },
    }
}

fn queue_system_control(
    id: u64,
    command: SystemControlCommand,
    events: &SyncSender<ControlEvent>,
) -> Value {
    let (reply, result) = mpsc::sync_channel(1);
    let pending = PendingSystemControl { command, reply };
    match events.try_send(ControlEvent::SystemControl(pending)) {
        Err(mpsc::TrySendError::Full(_)) => {
            error_response(Some(id), "busy", "the compositor control queue is full")
        }
        Err(mpsc::TrySendError::Disconnected(_)) => error_response(
            Some(id),
            "unavailable",
            "the compositor control queue is unavailable",
        ),
        Ok(()) => match result.recv_timeout(SYSTEM_CONTROL_TIMEOUT) {
            Ok(Ok(state)) => success_response(id, state),
            Ok(Err(error)) => error_response(Some(id), &error.code, error.message),
            Err(mpsc::RecvTimeoutError::Timeout) => error_response(
                Some(id),
                "timeout",
                "the compositor did not process the system-control request in time",
            ),
            Err(mpsc::RecvTimeoutError::Disconnected) => error_response(
                Some(id),
                "unavailable",
                "the compositor stopped before processing the system-control request",
            ),
        },
    }
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

fn stream_settings_documents(
    stream: &mut UnixStream,
    request_id: u64,
    publisher: &OutputControlPublisher,
    stopping: &AtomicBool,
) -> io::Result<()> {
    let initial = publisher.settings_documents.snapshot();
    write_response(stream, &success_response(request_id, &initial))?;
    let mut revision = initial.revision;
    loop {
        if peer_disconnected(stream)? {
            return Ok(());
        }
        match publisher
            .settings_documents
            .wait_for_change(revision, stopping)
        {
            SettingsDocumentWait::Changed(snapshot) => {
                write_response(stream, &success_response(request_id, &snapshot))?;
                revision = snapshot.revision;
            }
            SettingsDocumentWait::TimedOut => {}
            SettingsDocumentWait::Stopped => return Ok(()),
        }
    }
}

fn peer_disconnected(stream: &UnixStream) -> io::Result<bool> {
    let mut byte = [0_u8; 1];
    loop {
        // SAFETY: `byte` is valid writable storage for one byte and `stream`
        // owns a live Unix socket for the duration of this nonblocking peek.
        let read = unsafe {
            libc::recv(
                stream.as_raw_fd(),
                byte.as_mut_ptr().cast(),
                byte.len(),
                libc::MSG_DONTWAIT | libc::MSG_PEEK,
            )
        };
        if read > 0 {
            return Ok(false);
        }
        if read == 0 {
            return Ok(true);
        }
        let error = io::Error::last_os_error();
        match error.kind() {
            io::ErrorKind::WouldBlock => return Ok(false),
            io::ErrorKind::Interrupted => {}
            io::ErrorKind::BrokenPipe
            | io::ErrorKind::ConnectionAborted
            | io::ErrorKind::ConnectionReset => return Ok(true),
            _ => return Err(error),
        }
    }
}

fn write_response(stream: &mut UnixStream, response: &Value) -> io::Result<()> {
    serde_json::to_writer(&mut *stream, response)?;
    stream.write_all(b"\n")?;
    stream.flush()
}

#[cfg(test)]
#[path = "output_control/tests.rs"]
mod tests;
