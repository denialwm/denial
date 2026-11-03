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
use std::sync::{Arc, Mutex, RwLock, mpsc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use smithay::reexports::calloop::channel::{Channel, SyncSender, sync_channel};
use tracing::{info, warn};

use super::output_topology::ScrollingLayoutAxis;
use super::ui_development::{
    CommandKind as UiDevelopmentCommandKind, UiDevelopmentCommand, UiDevelopmentState,
};
use super::{
    gamma_control::SoftwareDimmingRequest,
    native_shortcut::ShortcutBinding,
    settings::{ColorChange, ColorSettings, KeyboardSettings, MouseSettings, TouchpadSettings},
    system_controls::{AudioRequest, BrightnessRequest},
};

pub(super) const PROTOCOL_VERSION: u32 = 1;

const SOCKET_DIRECTORY: &str = "denial";
const SOCKET_FILE: &str = "control.sock";
const EVENT_QUEUE_CAPACITY: usize = 8;
const MAX_CLIENT_WORKERS: usize = 32;
const MAX_REQUEST_BYTES: usize = 256 * 1024;
const CLIENT_IO_TIMEOUT: Duration = Duration::from_secs(3);
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
    pub(super) scrolling_layout_axis: bool,
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
            scrolling_layout_axis: true,
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
    pub(super) scrolling_layout_axis: ScrollingLayoutAxis,
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

/// The shared settings document, and a wake pipe per streaming subscriber.
#[derive(Clone)]
struct SettingsDocumentPublisher {
    state: Arc<Mutex<SettingsDocumentState>>,
}

struct SettingsDocumentState {
    snapshot: SettingsDocumentSnapshot,
    subscribers: Vec<UnixStream>,
}

impl SettingsDocumentPublisher {
    fn new(revision: u64, document: String) -> Self {
        Self {
            state: Arc::new(Mutex::new(SettingsDocumentState {
                snapshot: SettingsDocumentSnapshot { revision, document },
                subscribers: Vec::new(),
            })),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, SettingsDocumentState> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn snapshot(&self) -> SettingsDocumentSnapshot {
        self.lock().snapshot.clone()
    }

    fn revision(&self) -> u64 {
        self.lock().snapshot.revision
    }

    /// A pipe that turns readable after each publication and at shutdown.
    /// It closes the subscription when dropped.
    fn subscribe(&self) -> io::Result<UnixStream> {
        let (sender, receiver) = UnixStream::pair()?;
        sender.set_nonblocking(true)?;
        receiver.set_nonblocking(true)?;
        let mut state = self.lock();
        // A spare wake costs the others one snapshot check, and it drops the
        // pipes of subscribers that left since the last publication.
        wake_subscribers(&mut state.subscribers);
        state.subscribers.push(sender);
        Ok(receiver)
    }

    fn publish(&self, revision: u64, document: String) -> bool {
        let mut state = self.lock();
        if revision <= state.snapshot.revision {
            return false;
        }
        state.snapshot = SettingsDocumentSnapshot { revision, document };
        wake_subscribers(&mut state.subscribers);
        true
    }

    fn wake_all(&self) {
        wake_subscribers(&mut self.lock().subscribers);
    }
}

/// A full pipe already holds a wake; a closed one lost its subscriber.
fn wake_subscribers(subscribers: &mut Vec<UnixStream>) {
    subscribers.retain(|mut subscriber| match subscriber.write(&[1]) {
        Ok(_) => true,
        Err(error) => error.kind() == io::ErrorKind::WouldBlock,
    });
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

#[cfg(feature = "flutter")]
fn is_wallpaper_layer(
    kind: super::wire::WindowContentKind,
    size: (f64, f64),
    output_size: Option<(u32, u32)>,
) -> bool {
    use super::wire::WindowContentKind;
    match kind {
        WindowContentKind::LayerShellBackground => true,
        // Bottom-layer docks are not wallpapers. Only output-sized clients
        // belong here. Surface coordinates are local, not desktop coordinates.
        WindowContentKind::LayerShellBottom => output_size.is_some_and(|(width, height)| {
            width > 0 && height > 0 && size.0 >= f64::from(width) && size.1 >= f64::from(height)
        }),
        _ => false,
    }
}

#[cfg(all(test, feature = "flutter"))]
mod wallpaper_status_tests {
    use super::is_wallpaper_layer;
    use crate::wire::WindowContentKind::*;

    #[test]
    fn wallpapers_exclude_docks_and_fullscreen_application_windows() {
        let output = Some((1920, 1080));
        assert!(is_wallpaper_layer(
            LayerShellBackground,
            (1920.0, 1080.0),
            output
        ));
        assert!(is_wallpaper_layer(
            LayerShellBottom,
            (1920.0, 1080.0),
            output
        ));
        assert!(!is_wallpaper_layer(
            LayerShellBottom,
            (1920.0, 48.0),
            output
        ));
        assert!(!is_wallpaper_layer(SurfaceTree, (1920.0, 1080.0), output));
        assert!(!is_wallpaper_layer(
            LayerShellOverlay,
            (1920.0, 1080.0),
            output
        ));
        assert!(!is_wallpaper_layer(
            LayerShellBottom,
            (1920.0, 1080.0),
            None
        ));
    }
}

/// A mapped desktop background supplied by a Wayland client. This can be a
/// still-image client too; the protocol deliberately does not claim animation.
#[derive(Clone, Debug, Serialize)]
struct WallpaperSurface {
    monitor_id: i64,
    app_id: String,
}

#[derive(Clone)]
pub(super) struct OutputControlPublisher {
    snapshot: Arc<RwLock<OutputControlSnapshot>>,
    settings_documents: SettingsDocumentPublisher,
    wallpaper: Arc<RwLock<Option<Vec<WallpaperSurface>>>>,
}

impl OutputControlPublisher {
    fn with_settings(
        initial: OutputControlState,
        settings_revision: u64,
        settings_document: String,
    ) -> Self {
        Self {
            snapshot: Arc::new(RwLock::new(OutputControlSnapshot::new(initial))),
            wallpaper: Arc::new(RwLock::new(None)),
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

    /// Metadata only: never copy or capture wallpaper pixels for Settings.
    #[cfg(feature = "flutter")]
    pub(super) fn publish_wallpaper(&self, windows: &[super::wire::WindowDescription]) {
        let outputs = self
            .snapshot
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let surfaces = windows
            .iter()
            .filter(|window| {
                let output_size = outputs
                    .outputs
                    .iter()
                    .find(|output| output.monitor_id == window.monitor_id)
                    .map(|output| (output.logical_width, output.logical_height));
                is_wallpaper_layer(
                    window.content_kind,
                    (window.surface_width, window.surface_height),
                    output_size,
                ) && !window.minimized
                    && window.opacity > 0.0
            })
            .map(|window| WallpaperSurface {
                monitor_id: window.monitor_id,
                app_id: window.app_id.clone(),
            })
            .collect();
        *self
            .wallpaper
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(surfaces);
    }

    fn wallpaper_status(&self) -> Value {
        let surfaces = self
            .wallpaper
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        json!({"available": surfaces.is_some(), "surfaces": surfaces.as_deref().unwrap_or_default()})
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
    #[serde(default)]
    pub(super) scrolling_layout_axis: Option<ScrollingLayoutAxis>,
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
    WriteMouse {
        expected_revision: u64,
        mouse: MouseSettings,
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

#[derive(Debug)]
pub(super) struct PendingSoftwareDimming {
    pub(super) command: SoftwareDimmingRequest,
    reply: SystemControlReplySender,
}

impl PendingSoftwareDimming {
    pub(super) fn into_parts(self) -> (SoftwareDimmingRequest, SystemControlReplySender) {
        (self.command, self.reply)
    }
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

    pub(super) const fn expires_at(&self) -> Instant {
        self.expires_at
    }
}

#[derive(Debug)]
pub(super) enum ControlEvent {
    OutputApply(PendingOutputApply),
    OutputConfirmation(PendingOutputConfirmation),
    Shell(PendingShellControl),
    Settings(PendingSettingsControl),
    SystemControl(PendingSystemControl),
    SoftwareDimming(PendingSoftwareDimming),
    UiDevelopment(PendingUiDevelopment),
    /// Something every output shows changed outside the scene.
    RepaintOutputs,
    /// Output pools must be rebuilt for the same displays.
    RebuildOutputs,
    /// An app's look changed: its windows are sampled again.
    RepaintApp(String),
    /// A display color change to keep for the next start.
    SaveColor(ColorChange),
    /// Show the color tuning editor.
    OpenColorTuning,
    /// Show it again once the shell restarted for the desktop look.
    ReopenColorTuning,
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
struct ColorCorrectionParams {
    enabled: bool,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct HdrParams {
    output: String,
    enabled: bool,
    /// SDR white in cd/m²; the default when absent.
    #[serde(default)]
    white: Option<f64>,
    #[serde(default)]
    primaries: super::output_color::SignalPrimaries,
}

fn hdr_state() -> Value {
    let outputs = super::output_color::hdr_displays()
        .into_iter()
        .map(|display| {
            json!({
                "output": display.name,
                "max_luminance": display.display.max_luminance,
                "max_frame_average": display.display.max_frame_average,
                "min_luminance": display.display.min_luminance,
                "active": display.active.is_some(),
                "white": display.active.map(|mode| mode.white),
                "primaries": display.active.map(|mode| mode.primaries.name()),
                "requested_white": super::output_color::hdr_request(&display.name)
                    .map(|mode| mode.white),
            })
        })
        .collect::<Vec<_>>();
    json!({"outputs": outputs})
}

fn change_hdr(
    params: HdrParams,
    events: &SyncSender<ControlEvent>,
) -> Result<Value, (&'static str, String)> {
    if !super::output_color::hdr_displays()
        .iter()
        .any(|display| display.name == params.output)
    {
        return Err((
            "invalid_params",
            format!("{} is not a connected HDR display", params.output),
        ));
    }
    let white = match (params.enabled, params.white) {
        (false, _) => None,
        (true, None) => Some(super::output_color::DEFAULT_SDR_WHITE),
        (true, Some(white)) if super::output_color::SDR_WHITE_RANGE.contains(&white) => Some(white),
        (true, Some(white)) => {
            let range = super::output_color::SDR_WHITE_RANGE;
            return Err((
                "invalid_params",
                format!(
                    "SDR white {white} is outside {}..={} cd/m²",
                    range.start(),
                    range.end()
                ),
            ));
        }
    };
    let mode = white.map(|white| super::output_color::HdrMode {
        white,
        primaries: params.primaries,
    });
    if super::output_color::hdr_request(&params.output) != mode {
        super::output_color::set_hdr_request(&params.output, mode);
        // The signal, the scene format and Flutter's targets all change.
        let _ = events.try_send(ControlEvent::RebuildOutputs);
        save_color(events, ColorChange::Hdr(params.output, mode));
    }
    Ok(hdr_state())
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ColorLutParams {
    path: PathBuf,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct AppLutParams {
    app_id: String,
    #[serde(default)]
    path: Option<PathBuf>,
}

fn app_luts_state() -> Value {
    let apps = super::output_color::app_luts()
        .into_iter()
        .map(|(app_id, lut)| json!({"app_id": app_id, "size": lut.size, "title": lut.title}))
        .collect::<Vec<_>>();
    json!({"apps": apps})
}

/// The largest `.cube` file read: a 65³ LUT in plain decimals.
const MAX_CUBE_BYTES: u64 = 16 * 1024 * 1024;

fn desktop_lut_state() -> Value {
    let lut = super::output_color::desktop_lut();
    json!({"lut": lut.map(|lut| json!({"size": lut.size, "title": lut.title}))})
}

/// Gaining or losing a look rebuilds the output pools, so every output
/// renders off-screen exactly while one is loaded; swapping looks repaints.
fn change_desktop_lut(lut: Option<super::output_color::Lut>, events: &SyncSender<ControlEvent>) {
    let had_look = super::output_color::desktop_lut().is_some();
    let has_look = lut.is_some();
    super::output_color::set_desktop_lut(lut);
    let event = if had_look == has_look {
        ControlEvent::RepaintOutputs
    } else {
        ControlEvent::RebuildOutputs
    };
    // A full queue already holds work that draws a new frame.
    let _ = events.try_send(event);
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct GradeTarget {
    /// The desktop when absent.
    #[serde(default)]
    app_id: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct GradeParams {
    #[serde(default)]
    app_id: Option<String>,
    grade: super::color_grade::Grade,
    /// False while a control is still moving: the change shows, the save
    /// waits for the release.
    #[serde(default = "saves_by_default")]
    save: bool,
}

fn saves_by_default() -> bool {
    true
}

fn grade_state(app_id: Option<&str>) -> Value {
    let look = match app_id {
        Some(app_id) => super::color_grade::app_look(app_id),
        None => super::color_grade::desktop_look(),
    };
    json!({
        "app_id": app_id,
        "grade": look.grade,
        "base": look.base.as_ref().and_then(|base| base.title.clone()),
    })
}

fn change_grade(
    params: GradeParams,
    events: &SyncSender<ControlEvent>,
) -> Result<Value, (&'static str, String)> {
    params
        .grade
        .validate()
        .map_err(|error| ("invalid_params", error))?;
    let saved = Some(params.grade).filter(|grade| !grade.is_neutral());
    match params.app_id.as_deref() {
        Some("") => return Err(("invalid_params", "app_id is empty".to_owned())),
        Some(app_id) => {
            change_app_look(app_id, |look| look.grade = params.grade);
            // A full queue already holds work that draws a new frame.
            let _ = events.try_send(ControlEvent::RepaintApp(app_id.to_owned()));
            if params.save {
                save_color(events, ColorChange::AppGrade(app_id.to_owned(), saved));
            }
        }
        None => {
            change_desktop_look(|look| look.grade = params.grade, events);
            if params.save {
                save_color(events, ColorChange::DesktopGrade(saved));
            }
        }
    }
    Ok(grade_state(params.app_id.as_deref()))
}

fn change_desktop_look(
    change: impl FnOnce(&mut super::color_grade::Look),
    events: &SyncSender<ControlEvent>,
) {
    super::color_grade::change_desktop_look(change, |lut| change_desktop_lut(lut, events));
}

fn change_app_look(app_id: &str, change: impl FnOnce(&mut super::color_grade::Look)) {
    super::color_grade::change_app_look(app_id, change, |lut| {
        super::output_color::set_app_lut(app_id, lut);
    });
}

fn save_color(events: &SyncSender<ControlEvent>, change: ColorChange) {
    if let Err(error) = events.try_send(ControlEvent::SaveColor(change)) {
        warn!(%error, "display color change applies but was not saved");
    }
}

/// The LUT path to save: the one the file was read from.
fn saved_lut_path(path: &Path) -> PathBuf {
    fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

/// Applies the saved display color before the first outputs are built. A LUT
/// that no longer reads is skipped and stays saved.
pub(super) fn restore_color(color: &ColorSettings) {
    super::output_color::set_correction(color.correction);
    let base = |path: Option<&PathBuf>, app_id: Option<&str>| {
        let path = path?;
        match load_cube(path) {
            Ok(lut) => Some(Arc::new(lut)),
            Err((_, error)) => {
                warn!(%error, app_id, "saved LUT is unavailable");
                None
            }
        }
    };
    super::color_grade::change_desktop_look(
        |look| {
            look.base = base(color.desktop_lut.as_ref(), None);
            look.grade = color.desktop_grade.unwrap_or_default();
        },
        super::output_color::set_desktop_lut,
    );
    let apps = color
        .app_luts
        .keys()
        .chain(color.app_grades.keys())
        .collect::<std::collections::BTreeSet<_>>();
    for app_id in apps {
        change_app_look(app_id, |look| {
            look.base = base(color.app_luts.get(app_id), Some(app_id));
            look.grade = color.app_grades.get(app_id).copied().unwrap_or_default();
        });
    }
    for (output, mode) in &color.hdr {
        super::output_color::set_hdr_request(output, Some(*mode));
    }
}

fn load_cube(path: &Path) -> Result<super::output_color::Lut, (&'static str, String)> {
    let file =
        fs::File::open(path).map_err(|error| ("io", format!("{}: {error}", path.display())))?;
    let mut text = String::new();
    file.take(MAX_CUBE_BYTES + 1)
        .read_to_string(&mut text)
        .map_err(|error| ("io", format!("{}: {error}", path.display())))?;
    if text.len() as u64 > MAX_CUBE_BYTES {
        return Err((
            "invalid_lut",
            format!("{} is larger than 16 MiB", path.display()),
        ));
    }
    let mut lut = super::output_color::parse_cube(&text)
        .map_err(|error| ("invalid_lut", format!("{}: {error}", path.display())))?;
    // Without a TITLE line, a look goes by its file name.
    if lut.title.is_none() {
        lut.title = path
            .file_stem()
            .map(|stem| stem.to_string_lossy().into_owned());
    }
    Ok(lut)
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
struct MouseWriteParams {
    expected_revision: u64,
    mouse: MouseSettings,
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

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct SoftwareDimmingParams {
    monitor_id: i64,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct SoftwareDimmingLevelParams {
    monitor_id: i64,
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
                        crate::cpu_scheduling::normalize_current_worker("control-client");
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
        "wallpaper.status" => success_response(request.id, publisher.wallpaper_status()),
        "color.correction.get" => success_response(
            request.id,
            json!({"enabled": super::output_color::correction_enabled()}),
        ),
        "color.lut.get" => success_response(request.id, desktop_lut_state()),
        "color.hdr.get" => success_response(request.id, hdr_state()),
        "color.hdr.set" => match serde_json::from_value::<HdrParams>(request.params) {
            Ok(params) => match change_hdr(params, events) {
                Ok(state) => success_response(request.id, state),
                Err((code, message)) => error_response(Some(request.id), code, message),
            },
            Err(error) => error_response(Some(request.id), "invalid_params", error.to_string()),
        },
        "color.app.lut.get" => success_response(request.id, app_luts_state()),
        "color.grade.get" => match serde_json::from_value::<GradeTarget>(request.params) {
            Ok(target) => success_response(request.id, grade_state(target.app_id.as_deref())),
            Err(error) => error_response(Some(request.id), "invalid_params", error.to_string()),
        },
        "color.grade.set" => match serde_json::from_value::<GradeParams>(request.params) {
            Ok(params) => match change_grade(params, events) {
                Ok(state) => success_response(request.id, state),
                Err((code, message)) => error_response(Some(request.id), code, message),
            },
            Err(error) => error_response(Some(request.id), "invalid_params", error.to_string()),
        },
        "color.tune.prepare" => {
            super::color_grade::keep_desktop_look();
            let ready = super::output_color::desktop_lut().is_some();
            if !ready {
                change_desktop_look(|_| {}, events);
                let _ = events.try_send(ControlEvent::ReopenColorTuning);
            }
            success_response(request.id, json!({"ready": ready}))
        }
        "color.tune.open" => match events.try_send(ControlEvent::OpenColorTuning) {
            Ok(()) => success_response(request.id, json!({})),
            Err(error) => error_response(Some(request.id), "busy", error.to_string()),
        },
        "color.app.lut.load" | "color.app.lut.clear" => {
            match serde_json::from_value::<AppLutParams>(request.params) {
                Ok(AppLutParams { app_id, .. }) if app_id.is_empty() => {
                    error_response(Some(request.id), "invalid_params", "app_id is empty")
                }
                Ok(AppLutParams { app_id, path }) => {
                    let params_path = path.clone();
                    let lut = match (request.method.as_str(), path) {
                        ("color.app.lut.load", Some(path)) => match load_cube(&path) {
                            Ok(lut) => Ok(Some(lut)),
                            Err(error) => Err(error),
                        },
                        ("color.app.lut.load", None) => {
                            Err(("invalid_params", "path is required".to_owned()))
                        }
                        _ => Ok(None),
                    };
                    match lut {
                        Ok(lut) => {
                            let saved = params_path
                                .filter(|_| lut.is_some())
                                .map(|path| saved_lut_path(&path));
                            change_app_look(&app_id, |look| look.base = lut.map(Arc::new));
                            save_color(events, ColorChange::AppLut(app_id.clone(), saved));
                            // A full queue already holds work that draws a new frame.
                            let _ = events.try_send(ControlEvent::RepaintApp(app_id));
                            success_response(request.id, app_luts_state())
                        }
                        Err((code, message)) => error_response(Some(request.id), code, message),
                    }
                }
                Err(error) => error_response(Some(request.id), "invalid_params", error.to_string()),
            }
        }
        "color.lut.load" => match serde_json::from_value::<ColorLutParams>(request.params) {
            Ok(params) => match load_cube(&params.path) {
                Ok(lut) => {
                    change_desktop_look(|look| look.base = Some(Arc::new(lut)), events);
                    save_color(
                        events,
                        ColorChange::DesktopLut(Some(saved_lut_path(&params.path))),
                    );
                    success_response(request.id, desktop_lut_state())
                }
                Err((code, message)) => error_response(Some(request.id), code, message),
            },
            Err(error) => error_response(Some(request.id), "invalid_params", error.to_string()),
        },
        "color.lut.clear" => {
            change_desktop_look(|look| look.base = None, events);
            save_color(events, ColorChange::DesktopLut(None));
            success_response(request.id, desktop_lut_state())
        }
        "color.correction.set" => {
            match serde_json::from_value::<ColorCorrectionParams>(request.params) {
                Ok(params) => {
                    super::output_color::set_correction(params.enabled);
                    // A full queue already holds work that draws a new frame.
                    let _ = events.try_send(ControlEvent::RepaintOutputs);
                    save_color(events, ColorChange::Correction(params.enabled));
                    success_response(request.id, json!({"enabled": params.enabled}))
                }
                Err(error) => error_response(Some(request.id), "invalid_params", error.to_string()),
            }
        }
        "denial.version" => success_response(
            request.id,
            json!({
                "version": denial_core::version(),
                "build": denial_core::BUILD_IDENTITY,
            }),
        ),
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
        "settings.mouse.apply" => {
            let parameters =
                match parse_settings_params::<MouseWriteParams>(request.id, request.params) {
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
                SettingsControlCommand::WriteMouse {
                    expected_revision: parameters.expected_revision,
                    mouse: parameters.mouse,
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
        "software_dimming.get" => {
            let parameters =
                match parse_settings_params::<SoftwareDimmingParams>(request.id, request.params) {
                    Ok(parameters) if parameters.monitor_id > 0 => parameters,
                    Ok(_) => {
                        return write_response(
                            &mut stream,
                            &error_response(
                                Some(request.id),
                                "invalid_params",
                                "software dimming requires a positive monitor ID",
                            ),
                        );
                    }
                    Err(response) => return write_response(&mut stream, &response),
                };
            queue_software_dimming(
                request.id,
                SoftwareDimmingRequest::Read {
                    output: denial_core::topology::OutputId(parameters.monitor_id as u64),
                },
                events,
            )
        }
        "software_dimming.set" => {
            let parameters = match parse_settings_params::<SoftwareDimmingLevelParams>(
                request.id,
                request.params,
            ) {
                Ok(parameters) if parameters.monitor_id > 0 && parameters.percent <= 100 => {
                    parameters
                }
                Ok(_) => {
                    return write_response(
                        &mut stream,
                        &error_response(
                            Some(request.id),
                            "invalid_params",
                            "software dimming requires percent 0-100 and a positive monitor ID",
                        ),
                    );
                }
                Err(response) => return write_response(&mut stream, &response),
            };
            queue_software_dimming(
                request.id,
                SoftwareDimmingRequest::Set {
                    output: denial_core::topology::OutputId(parameters.monitor_id as u64),
                    level: f64::from(parameters.percent) / 100.0,
                },
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
        "ui.activate" => {
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
                UiDevelopmentCommandKind::ActivatePluginBundle,
                Some(parameters.path),
                false,
                events,
            )
        }
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

fn queue_software_dimming(
    id: u64,
    command: SoftwareDimmingRequest,
    events: &SyncSender<ControlEvent>,
) -> Value {
    let (reply, result) = mpsc::sync_channel(1);
    let pending = PendingSoftwareDimming { command, reply };
    match events.try_send(ControlEvent::SoftwareDimming(pending)) {
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
                "the compositor did not process the software-dimming request in time",
            ),
            Err(mpsc::RecvTimeoutError::Disconnected) => error_response(
                Some(id),
                "unavailable",
                "the compositor stopped before processing the software-dimming request",
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
    // Subscribe before the first snapshot so no publication falls between.
    let mut wake = publisher.settings_documents.subscribe()?;
    let initial = publisher.settings_documents.snapshot();
    write_response(stream, &success_response(request_id, &initial))?;
    let mut revision = initial.revision;
    loop {
        let snapshot = publisher.settings_documents.snapshot();
        if snapshot.revision > revision {
            write_response(stream, &success_response(request_id, &snapshot))?;
            revision = snapshot.revision;
        }
        if stopping.load(Ordering::Acquire) || !wait_for_publication(stream, &mut wake)? {
            return Ok(());
        }
    }
}

/// Sleeps until the next publication or shutdown wake. False once the client
/// has hung up; anything it sends while subscribed is ignored.
fn wait_for_publication(stream: &UnixStream, wake: &mut UnixStream) -> io::Result<bool> {
    let mut poll_fds = [
        libc::pollfd {
            fd: stream.as_raw_fd(),
            events: libc::POLLRDHUP,
            revents: 0,
        },
        libc::pollfd {
            fd: wake.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        },
    ];
    loop {
        // SAFETY: `poll_fds` points to two initialized pollfd values whose
        // client stream and wake pipe outlive this call.
        let ready =
            unsafe { libc::poll(poll_fds.as_mut_ptr(), poll_fds.len() as libc::nfds_t, -1) };
        if ready >= 0 {
            break;
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
    if poll_fds[0].revents != 0 {
        return Ok(false);
    }
    let mut drained = [0_u8; 64];
    loop {
        match wake.read(&mut drained) {
            Ok(0) => return Ok(false),
            Ok(_) => {}
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(true),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
}

fn write_response(stream: &mut UnixStream, response: &Value) -> io::Result<()> {
    serde_json::to_writer(&mut *stream, response)?;
    stream.write_all(b"\n")?;
    stream.flush()
}
