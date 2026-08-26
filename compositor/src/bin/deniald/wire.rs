//! Denial's versioned FlatBuffers bridge between the Flutter shell and Rust.
//!
//! The schema is shared with the current runtime.  Incoming data is always
//! bounded and verified before it is inspected; generated unchecked accessors
//! never see bytes supplied directly by Flutter.

use std::collections::{BTreeSet, HashSet, VecDeque};
use std::error::Error;
use std::ffi::CStr;
use std::fmt;

use denial_core::topology::{AtlasPlan, OutputId, SCALE_BASE, TopologySnapshot};
use flatbuffers::{FlatBufferBuilder, WIPOffset};

use super::native_shortcut::{
    MAX_SHORTCUTS, MAX_SPAWN_ARGUMENTS, ShortcutAction, ShortcutBinding, ShortcutInputCategory,
    ShortcutInputDefinition, ShortcutInputKind, ShortcutTarget, ShortcutValidation,
};
use super::notification_server::{
    Notification, NotificationEvent, NotificationEventKind, NotificationUrgency,
};
use super::options::{SystemBarOptions, SystemBarSide, WorkAreaOptions};
use super::settings::{KeyboardLayout, KeyboardSettings, TouchpadSettings};
use super::xembed_tray::{
    XEmbedTrayAction, XEmbedTrayCommand, XEmbedTrayEvent, XEmbedTrayEventKind,
};

#[allow(
    clippy::all,
    clippy::undocumented_unsafe_blocks,
    dead_code,
    deprecated,
    non_camel_case_types,
    non_snake_case,
    non_upper_case_globals,
    mismatched_lifetime_syntaxes,
    unsafe_op_in_unsafe_fn,
    unused_imports
)]
mod generated {
    include!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../protocol/generated/rust/denial_generated.rs"
    ));
}

use generated::denial::wire as fb;

#[path = "wire/decode.rs"]
mod decode;
#[path = "wire/encode.rs"]
mod encode;

use decode::validate_notification_event;
use encode::{encode_display_layout, encode_windows_response};

pub const TO_NATIVE_CHANNEL: &str = "denial/wire/to_native";
pub const TO_FLUTTER_CHANNEL: &CStr = c"denial/wire/to_flutter";

const PROTOCOL_VERSION: u16 = 1;
const MAX_MESSAGE_BYTES: usize = 1024 * 1024;
const MIN_ENVELOPE_BYTES: usize = 12;
const MAX_STRING_BYTES: usize = 4096;
const MAX_WINDOWS: usize = 4096;
const MAX_REGIONS: usize = 8192;
const MAX_SURFACES: usize = 32768;
const MAX_PENDING_WINDOW_COMMANDS: usize = 4096;
const MAX_PENDING_KEYBOARD_COMMANDS: usize = 256;
const MAX_PENDING_NOTIFICATION_COMMANDS: usize = 256;
const MAX_PENDING_XEMBED_TRAY_COMMANDS: usize = 256;
const MAX_PENDING_SETTINGS_COMMANDS: usize = 64;
const MAX_SETTINGS_DOCUMENT_BYTES: usize = 256 * 1024;
const MAX_LOCAL_APP_ID_BYTES: usize = 256;
const MAX_LOCAL_WINDOW_TITLE_BYTES: usize = 1024;
const MAX_SHORTCUT_INPUTS: usize = 256;
const WINDOW_PLACEMENT_PACKET_BYTES: usize = 80;
const KEYBOARD_CTRL: u32 = 1 << 0;
const KEYBOARD_PRESSED: u32 = 1 << 1;
const KEYBOARD_RELEASED: u32 = 1 << 2;
const KEYBOARD_PHASE_MASK: u32 = KEYBOARD_PRESSED | KEYBOARD_RELEASED;
const KEYBOARD_FLAGS_MASK: u32 = KEYBOARD_CTRL | KEYBOARD_PHASE_MASK;

pub const INPUT_LAYOUT_KEYBOARD_CAPTURE: u32 = 1 << 0;
pub const INPUT_LAYOUT_EXCLUSIVE_SHELL: u32 = 1 << 1;
pub const INPUT_LAYOUT_OBSERVE_CLIENT_POINTER_PRESSES: u32 = 1 << 2;
pub const INPUT_WINDOW_VISIBLE: u32 = 1 << 0;
pub const INPUT_WINDOW_HIT_TEST_DISABLED: u32 = 1 << 1;
pub const INPUT_WINDOW_GEOMETRY_LOCKED: u32 = 1 << 2;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct InputRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WindowGeometry {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Clone, Debug, PartialEq)]
pub enum WindowCommand {
    CreateLocal {
        app_id: String,
        title: String,
        geometry: WindowGeometry,
    },
    Close {
        window_id: u64,
    },
    Focus {
        window_id: u64,
    },
    Configure {
        window_id: u64,
        geometry: WindowGeometry,
        exact: bool,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum KeyboardKeyPhase {
    Tap,
    Pressed,
    Released,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum KeyboardCommand {
    Text(String),
    Key {
        key: String,
        ctrl: bool,
        phase: KeyboardKeyPhase,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub enum SettingsCommand {
    ReadDocument {
        request_id: u64,
    },
    WriteDocument {
        request_id: u64,
        expected_revision: u64,
        document: String,
    },
    ReadKeyboard {
        request_id: u64,
    },
    ConfigureKeyboard {
        request_id: u64,
        expected_revision: u64,
        keyboard: KeyboardSettings,
    },
    ReadShortcuts {
        request_id: u64,
    },
    ValidateShortcut {
        request_id: u64,
        shortcut: ShortcutBinding,
        existing_shortcut: Option<String>,
    },
    AddShortcut {
        request_id: u64,
        expected_revision: u64,
        shortcut: ShortcutBinding,
    },
    UpdateShortcut {
        request_id: u64,
        expected_revision: u64,
        existing_shortcut: String,
        shortcut: ShortcutBinding,
    },
    RemoveShortcut {
        request_id: u64,
        expected_revision: u64,
        shortcut: String,
    },
    RestoreShortcuts {
        request_id: u64,
        expected_revision: u64,
    },
    ReadInputDevices {
        request_id: u64,
    },
    ConfigureTouchpad {
        request_id: u64,
        expected_revision: u64,
        touchpad: TouchpadSettings,
    },
}

impl WindowCommand {
    pub fn window_id(&self) -> Option<u64> {
        match self {
            Self::CreateLocal { .. } => None,
            Self::Close { window_id }
            | Self::Focus { window_id }
            | Self::Configure { window_id, .. } => Some(*window_id),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WindowAction {
    Minimize,
    Maximize,
    Restore,
    // Retained for wire compatibility and explicit UI toggles. Native
    // shortcuts use idempotent Maximize/Restore transitions.
    #[allow(dead_code)]
    ToggleMaximize,
    ToggleFullscreen,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ShellAction {
    Applications,
    #[allow(dead_code)]
    Overview,
    #[allow(dead_code)]
    WindowSwitcherNext,
    #[allow(dead_code)]
    WindowSwitcherEnd,
    Clipboard,
    ScreenshotRegion,
    ScreenshotTextureReady,
    ScreenshotDone,
    ClientPointerPressed,
    Wallpaper,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum NotificationCommand {
    Dismiss {
        notification_id: u32,
    },
    InvokeAction {
        notification_id: u32,
        action_key: String,
    },
    InvokeDefault {
        notification_id: u32,
    },
}

impl ShellAction {
    fn wire(self) -> fb::ShellActionKind {
        match self {
            Self::Applications => fb::ShellActionKind::Applications,
            Self::Overview => fb::ShellActionKind::Overview,
            Self::WindowSwitcherNext => fb::ShellActionKind::WindowSwitcherNext,
            Self::WindowSwitcherEnd => fb::ShellActionKind::WindowSwitcherEnd,
            Self::Clipboard => fb::ShellActionKind::Clipboard,
            Self::ScreenshotRegion => fb::ShellActionKind::ScreenshotRegion,
            Self::ScreenshotTextureReady => fb::ShellActionKind::ScreenshotTextureReady,
            Self::ScreenshotDone => fb::ShellActionKind::ScreenshotDone,
            Self::ClientPointerPressed => fb::ShellActionKind::ClientPointerPressed,
            Self::Wallpaper => fb::ShellActionKind::Wallpaper,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum WindowPlacementPhase {
    Begin = 0,
    Update = 1,
    End = 2,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum WindowPlacementChange {
    Move = 0,
    Resize = 1,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WindowPlacement {
    pub window_id: u64,
    pub monitor_id: i64,
    pub workspace_id: i64,
    pub phase: WindowPlacementPhase,
    pub change: WindowPlacementChange,
    pub geometry: WindowGeometry,
}

impl WindowAction {
    fn wire(self) -> fb::WindowActionKind {
        match self {
            Self::Minimize => fb::WindowActionKind::Minimize,
            Self::Maximize => fb::WindowActionKind::Maximize,
            Self::Restore => fb::WindowActionKind::Restore,
            Self::ToggleMaximize => fb::WindowActionKind::ToggleMaximize,
            Self::ToggleFullscreen => fb::WindowActionKind::ToggleFullscreen,
        }
    }
}

impl InputRect {
    pub fn contains(self, x: f64, y: f64) -> bool {
        x >= self.x && y >= self.y && x < self.x + self.width && y < self.y + self.height
    }

    pub fn map_to(self, target: Self, x: f64, y: f64) -> (f64, f64) {
        let normalized_x = (x - self.x) / self.width;
        let normalized_y = (y - self.y) / self.height;
        (
            target.x + normalized_x * target.width,
            target.y + normalized_y * target.height,
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct InputWindowRegion {
    pub object_id: u64,
    pub surface_id: u64,
    pub window_id: u64,
    pub rect: InputRect,
    pub source_rect: InputRect,
    pub z: i32,
    pub flags: u32,
}

impl InputWindowRegion {
    pub fn visible(&self) -> bool {
        self.flags & INPUT_WINDOW_VISIBLE != 0
    }

    pub fn hit_test_enabled(&self) -> bool {
        self.flags & INPUT_WINDOW_HIT_TEST_DISABLED == 0
    }

    /// Flutter owns the window's current geometry (shell fullscreen). Native
    /// move/resize bindings must not tear that state down behind the shell.
    pub fn geometry_locked(&self) -> bool {
        self.flags & INPUT_WINDOW_GEOMETRY_LOCKED != 0
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct InputLayoutSnapshot {
    pub epoch: u64,
    pub flags: u32,
    pub shell_regions: Vec<InputRect>,
    pub software_keyboard_regions: Vec<InputRect>,
    pub windows: Vec<InputWindowRegion>,
    pub visible_surface_ids: Vec<u64>,
}

impl InputLayoutSnapshot {
    pub fn keyboard_capture(&self) -> bool {
        self.flags & INPUT_LAYOUT_KEYBOARD_CAPTURE != 0
    }

    pub fn exclusive_shell(&self) -> bool {
        self.flags & INPUT_LAYOUT_EXCLUSIVE_SHELL != 0
    }

    pub fn observes_client_pointer_presses(&self) -> bool {
        self.flags & INPUT_LAYOUT_OBSERVE_CLIENT_POINTER_PRESSES != 0
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct SurfaceLayerDescription {
    pub surface_id: u64,
    pub parent_surface_id: u64,
    pub popup_root_surface_id: u64,
    pub role: SurfaceRoleDescription,
    pub texture_id: u64,
    pub width: u32,
    pub height: u32,
    pub surface_x: f64,
    pub surface_y: f64,
    pub surface_width: f64,
    pub surface_height: f64,
    pub texture_source_x: f64,
    pub texture_source_y: f64,
    pub texture_source_width: f64,
    pub texture_source_height: f64,
    pub transform: u32,
    pub scale_120: u32,
    pub composition_order: u32,
    pub opacity: f32,
    pub opaque: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SurfaceRoleDescription {
    Root,
    Subsurface,
    Popup,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WindowContentKind {
    SurfaceTree,
    LocalFlutter,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WindowOpacityClass {
    ContentTranslucent,
    BorderAlphaOnly,
    FullyOpaque,
}

impl WindowContentKind {
    fn wire(self) -> fb::WindowContentKind {
        match self {
            Self::SurfaceTree => fb::WindowContentKind::SurfaceTree,
            Self::LocalFlutter => fb::WindowContentKind::LocalFlutter,
        }
    }
}

impl WindowOpacityClass {
    fn wire(self) -> fb::WindowOpacityClass {
        match self {
            Self::ContentTranslucent => fb::WindowOpacityClass::ContentTranslucent,
            Self::BorderAlphaOnly => fb::WindowOpacityClass::BorderAlphaOnly,
            Self::FullyOpaque => fb::WindowOpacityClass::FullyOpaque,
        }
    }
}

impl SurfaceRoleDescription {
    fn wire(self) -> fb::SurfaceRole {
        match self {
            Self::Root => fb::SurfaceRole::Root,
            Self::Subsurface => fb::SurfaceRole::Subsurface,
            Self::Popup => fb::SurfaceRole::Popup,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct WindowDescription {
    pub object_id: u64,
    pub surface_id: u64,
    pub window_id: u64,
    pub texture_id: u64,
    pub title: String,
    pub app_id: String,
    pub width: u32,
    pub height: u32,
    pub surface_x: f64,
    pub surface_y: f64,
    pub surface_width: f64,
    pub surface_height: f64,
    pub texture_source_x: f64,
    pub texture_source_y: f64,
    pub texture_source_width: f64,
    pub texture_source_height: f64,
    pub geometry_x: f64,
    pub geometry_y: f64,
    pub geometry_width: f64,
    pub geometry_height: f64,
    pub monitor_id: i64,
    pub transform: u32,
    pub scale_120: u32,
    pub content_x: f64,
    pub content_y: f64,
    pub content_width: f64,
    pub content_height: f64,
    pub surfaces: Vec<SurfaceLayerDescription>,
    pub suppress_animations: bool,
    pub server_side_decorated: bool,
    pub opacity: f32,
    pub content_kind: WindowContentKind,
    pub opacity_class: WindowOpacityClass,
}

#[derive(Debug)]
pub enum WireError {
    Size(usize),
    Identifier,
    FlatBuffer(flatbuffers::InvalidFlatbuffer),
    Version(u16),
    Sequence,
    RequestId,
    Payload,
    Enumeration,
    Flags,
    String,
    Count,
    Identity,
    Geometry,
    Ordering,
    Direction(fb::Payload),
    Request(fb::WindowRequestKind),
    Topology(&'static str),
}

impl fmt::Display for WireError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Size(size) => write!(formatter, "invalid Denial wire message size {size}"),
            Self::Identifier => formatter.write_str("Denial wire identifier is not DENW"),
            Self::FlatBuffer(error) => write!(formatter, "invalid Denial FlatBuffer: {error}"),
            Self::Version(version) => {
                write!(formatter, "unsupported Denial wire version {version}")
            }
            Self::Sequence => formatter.write_str("Denial wire sequence must be non-zero"),
            Self::RequestId => formatter.write_str("Denial request id must be non-zero"),
            Self::Payload => formatter.write_str("Denial wire payload is missing"),
            Self::Enumeration => formatter.write_str("Denial wire enum value is invalid"),
            Self::Flags => formatter.write_str("Denial wire flags contain unknown bits"),
            Self::String => formatter.write_str("Denial wire string is missing or invalid"),
            Self::Count => formatter.write_str("Denial wire collection exceeds its limit"),
            Self::Identity => {
                formatter.write_str("Denial wire identity must be non-zero and unique")
            }
            Self::Geometry => formatter.write_str("Denial wire geometry is invalid"),
            Self::Ordering => formatter.write_str("Denial input regions are not topmost-first"),
            Self::Direction(payload) => {
                write!(
                    formatter,
                    "unexpected Flutter-to-native payload {payload:?}"
                )
            }
            Self::Request(kind) => write!(formatter, "unsupported window request {kind:?}"),
            Self::Topology(reason) => write!(formatter, "invalid display topology: {reason}"),
        }
    }
}

impl Error for WireError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::FlatBuffer(error) => Some(error),
            _ => None,
        }
    }
}

/// State for the ordered native-to-Flutter stream.
pub struct WireBridge {
    snapshot: TopologySnapshot,
    atlas: AtlasPlan,
    work_area: WorkAreaOptions,
    windows: Vec<WindowDescription>,
    windows_revision: Option<u64>,
    restored_window_ids: Vec<u64>,
    // Flutter copies platform-channel payloads during the synchronous engine
    // call. Keep one builder alive here and lend its finished tail until the
    // next mutable bridge operation, eliminating both builder churn and the
    // former finished_data().to_vec() copy.
    outbound_builder: FlatBufferBuilder<'static>,
    pending_input_layout: Option<InputLayoutSnapshot>,
    input_layout_scratch: InputLayoutSnapshot,
    input_layout_identities_scratch: HashSet<u64>,
    pending_window_commands: VecDeque<WindowCommand>,
    pending_keyboard_commands: VecDeque<KeyboardCommand>,
    pending_notification_commands: VecDeque<NotificationCommand>,
    pending_xembed_tray_commands: VecDeque<XEmbedTrayCommand>,
    pending_settings_commands: VecDeque<SettingsCommand>,
    pending_theme_accent: Option<u32>,
    pending_work_area: Option<WorkAreaOptions>,
    next_sequence: u64,
}

impl WireBridge {
    pub fn new(
        snapshot: &TopologySnapshot,
        atlas: &AtlasPlan,
        work_area: WorkAreaOptions,
    ) -> Result<Self, WireError> {
        validate_topology(snapshot, atlas)?;
        Ok(Self {
            snapshot: snapshot.clone(),
            atlas: atlas.clone(),
            work_area,
            windows: Vec::new(),
            windows_revision: None,
            restored_window_ids: Vec::new(),
            outbound_builder: FlatBufferBuilder::with_capacity(1024),
            pending_input_layout: None,
            input_layout_scratch: InputLayoutSnapshot::default(),
            input_layout_identities_scratch: HashSet::new(),
            pending_window_commands: VecDeque::new(),
            pending_keyboard_commands: VecDeque::new(),
            pending_notification_commands: VecDeque::new(),
            pending_xembed_tray_commands: VecDeque::new(),
            pending_settings_commands: VecDeque::new(),
            pending_theme_accent: None,
            pending_work_area: None,
            next_sequence: 1,
        })
    }

    pub fn window_ids(&self) -> impl Iterator<Item = u64> + '_ {
        self.windows.iter().map(|window| window.window_id)
    }

    pub fn window_descriptions(&self) -> &[WindowDescription] {
        &self.windows
    }

    pub fn take_input_layout_update(&mut self) -> Option<InputLayoutSnapshot> {
        self.pending_input_layout.take()
    }

    pub fn recycle_input_layout(&mut self, layout: InputLayoutSnapshot) {
        self.input_layout_scratch = layout;
    }

    pub fn drain_window_commands(&mut self) -> impl Iterator<Item = WindowCommand> + '_ {
        self.pending_window_commands.drain(..)
    }

    pub fn drain_keyboard_commands(&mut self) -> impl Iterator<Item = KeyboardCommand> + '_ {
        self.pending_keyboard_commands.drain(..)
    }

    pub fn drain_notification_commands(
        &mut self,
    ) -> impl Iterator<Item = NotificationCommand> + '_ {
        self.pending_notification_commands.drain(..)
    }

    pub fn drain_xembed_tray_commands(&mut self) -> impl Iterator<Item = XEmbedTrayCommand> + '_ {
        self.pending_xembed_tray_commands.drain(..)
    }

    pub fn drain_settings_commands(&mut self) -> impl Iterator<Item = SettingsCommand> + '_ {
        self.pending_settings_commands.drain(..)
    }

    /// Takes the latest resolved shell accent. Theme state is intentionally
    /// last-writer-wins: wallpaper extraction and setting changes may finish
    /// in the same event-loop turn, and only the final color is observable.
    pub fn take_theme_accent(&mut self) -> Option<u32> {
        self.pending_theme_accent.take()
    }

    /// Takes the latest validated system-bar update. Settings changes are
    /// deliberately last-writer-wins so rapid pointer or keyboard input stays
    /// bounded and applies as one compositor transaction.
    pub fn take_work_area_update(&mut self) -> Option<WorkAreaOptions> {
        self.pending_work_area.take()
    }

    fn take_sequence(&mut self) -> u64 {
        let sequence = self.next_sequence.max(1);
        self.next_sequence = if sequence >= i64::MAX as u64 {
            1
        } else {
            sequence + 1
        };
        sequence
    }
}

fn validate_topology(snapshot: &TopologySnapshot, atlas: &AtlasPlan) -> Result<(), WireError> {
    if snapshot.outputs.is_empty() || snapshot.logical_bounds.is_none() {
        return Err(WireError::Topology("no active outputs"));
    }
    if snapshot.epoch != atlas.topology_epoch {
        return Err(WireError::Topology("snapshot and atlas epochs differ"));
    }
    if atlas.pixel_size.width == 0
        || atlas.pixel_size.height == 0
        || atlas.logical_size.0 <= 0.0
        || atlas.logical_size.1 <= 0.0
        || atlas.engine_scale_120 == 0
    {
        return Err(WireError::Topology("atlas has invalid dimensions"));
    }
    if snapshot.outputs.iter().any(|output| {
        output.name.len() > MAX_STRING_BYTES
            || !atlas.outputs.iter().any(|planned| planned.id == output.id)
            || monitor_id(output.id).is_none()
    }) {
        return Err(WireError::Topology("an output cannot be represented"));
    }
    Ok(())
}

fn validate_windows(windows: &[WindowDescription]) -> Result<(), WireError> {
    if windows.len() > MAX_WINDOWS {
        return Err(WireError::Count);
    }

    let mut surface_count = 0usize;
    let mut snapshot_surface_ids = HashSet::new();
    let mut window_surface_ids = HashSet::new();
    for window in windows {
        surface_count = surface_count
            .checked_add(window.surfaces.len())
            .ok_or(WireError::Count)?;
        if surface_count > MAX_SURFACES {
            return Err(WireError::Count);
        }
        if window.object_id == 0
            || window.surface_id == 0
            || window.window_id == 0
            || window.width == 0
            || window.height == 0
            || window.title.len() > MAX_STRING_BYTES
            || window.app_id.len() > MAX_STRING_BYTES
            || window.scale_120 == 0
            || window.transform > 7
            || !valid_opacity(window.opacity)
            || [
                window.surface_x,
                window.surface_y,
                window.surface_width,
                window.surface_height,
                window.texture_source_x,
                window.texture_source_y,
                window.texture_source_width,
                window.texture_source_height,
                window.geometry_x,
                window.geometry_y,
                window.geometry_width,
                window.geometry_height,
                window.content_x,
                window.content_y,
                window.content_width,
                window.content_height,
            ]
            .iter()
            .any(|value| !value.is_finite())
            || (window.texture_id > 0
                && (window.texture_source_width <= 0.0 || window.texture_source_height <= 0.0))
            || (!window.surfaces.is_empty()
                && (window.content_width <= 0.0 || window.content_height <= 0.0))
        {
            return Err(WireError::Payload);
        }
        if window.content_kind == WindowContentKind::LocalFlutter
            && (window.texture_id != 0 || !window.surfaces.is_empty())
        {
            return Err(WireError::Payload);
        }

        window_surface_ids.clear();
        window_surface_ids.reserve(window.surfaces.len());
        snapshot_surface_ids.reserve(window.surfaces.len());
        if window.surfaces.iter().any(|surface| {
            surface.surface_id == 0
                || !window_surface_ids.insert(surface.surface_id)
                || !snapshot_surface_ids.insert(surface.surface_id)
        }) {
            return Err(WireError::Identity);
        }

        let mut previous_order = None;
        for surface in &window.surfaces {
            if previous_order.is_some_and(|order| surface.composition_order < order) {
                return Err(WireError::Ordering);
            }
            previous_order = Some(surface.composition_order);

            if surface.transform > 7
                || surface.scale_120 == 0
                || !valid_opacity(surface.opacity)
                || [
                    surface.surface_x,
                    surface.surface_y,
                    surface.surface_width,
                    surface.surface_height,
                    surface.texture_source_x,
                    surface.texture_source_y,
                    surface.texture_source_width,
                    surface.texture_source_height,
                ]
                .iter()
                .any(|value| !value.is_finite())
                || surface.surface_width <= 0.0
                || surface.surface_height <= 0.0
                || (surface.texture_id > 0
                    && (surface.width == 0
                        || surface.height == 0
                        || surface.texture_source_width <= 0.0
                        || surface.texture_source_height <= 0.0))
                || (surface.parent_surface_id != 0
                    && !window_surface_ids.contains(&surface.parent_surface_id))
                || (surface.popup_root_surface_id != 0
                    && !window_surface_ids.contains(&surface.popup_root_surface_id))
            {
                return Err(WireError::Payload);
            }

            match surface.role {
                SurfaceRoleDescription::Root => {
                    if surface.surface_id != window.surface_id
                        || surface.parent_surface_id != 0
                        || surface.popup_root_surface_id != 0
                    {
                        return Err(WireError::Identity);
                    }
                }
                SurfaceRoleDescription::Popup => {
                    if surface.popup_root_surface_id != surface.surface_id {
                        return Err(WireError::Identity);
                    }
                }
                SurfaceRoleDescription::Subsurface => {
                    if surface.parent_surface_id == 0 {
                        return Err(WireError::Identity);
                    }
                }
            }
        }
    }
    Ok(())
}

fn valid_opacity(opacity: f32) -> bool {
    opacity.is_finite() && (0.0..=1.0).contains(&opacity)
}

fn validate_finished_message(builder: &FlatBufferBuilder<'_>) -> Result<(), WireError> {
    if builder.finished_data().len() > MAX_MESSAGE_BYTES {
        return Err(WireError::Size(builder.finished_data().len()));
    }
    Ok(())
}

fn monitor_id(id: OutputId) -> Option<i64> {
    i64::try_from(id.0).ok()
}

/// Resolves the configured system bar against the live topology. A configured
/// connector that is currently absent falls back to the ticker output so the
/// bar survives hotplug instead of disappearing with its monitor.
fn resolve_system_bar(
    snapshot: &TopologySnapshot,
    system_bar: &SystemBarOptions,
    ticker: i64,
) -> (Vec<i64>, fb::SystemBarSide, f64) {
    if system_bar.side == SystemBarSide::Hidden || system_bar.thickness <= 0.0 {
        return (Vec::new(), fb::SystemBarSide::Hidden, 0.0);
    }
    let mut configured = snapshot
        .outputs
        .iter()
        .filter(|output| system_bar.outputs.contains(&output.name))
        .filter_map(|output| monitor_id(output.id))
        .collect::<Vec<_>>();
    if configured.is_empty() && ticker >= 0 {
        configured.push(ticker);
    }
    let side = match system_bar.side {
        SystemBarSide::Left => fb::SystemBarSide::Left,
        SystemBarSide::Right => fb::SystemBarSide::Right,
        SystemBarSide::Top => fb::SystemBarSide::Top,
        SystemBarSide::Bottom => fb::SystemBarSide::Bottom,
        SystemBarSide::Hidden => unreachable!("hidden side returned above"),
    };
    (configured, side, system_bar.thickness)
}

#[cfg(test)]
#[path = "wire/tests.rs"]
mod tests;
