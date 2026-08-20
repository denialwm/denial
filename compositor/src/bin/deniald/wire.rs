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
    pending_settings_commands: VecDeque<SettingsCommand>,
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
            restored_window_ids: Vec::new(),
            outbound_builder: FlatBufferBuilder::with_capacity(1024),
            pending_input_layout: None,
            input_layout_scratch: InputLayoutSnapshot::default(),
            input_layout_identities_scratch: HashSet::new(),
            pending_window_commands: VecDeque::new(),
            pending_keyboard_commands: VecDeque::new(),
            pending_notification_commands: VecDeque::new(),
            pending_settings_commands: VecDeque::new(),
            pending_work_area: None,
            next_sequence: 1,
        })
    }

    /// Replaces display geometry in place and emits an unsolicited layout
    /// response (`request_id == 0`). The Dart bridge treats that form as a
    /// state update, allowing transform-only changes to keep the engine and
    /// physical render-target pools resident.
    pub fn update_topology(
        &mut self,
        snapshot: &TopologySnapshot,
        atlas: &AtlasPlan,
    ) -> Result<&[u8], WireError> {
        validate_topology(snapshot, atlas)?;
        self.snapshot = snapshot.clone();
        self.atlas = atlas.clone();
        let sequence = self.take_sequence();
        self.outbound_builder.reset();
        encode_display_layout(
            &mut self.outbound_builder,
            sequence,
            0,
            &self.snapshot,
            &self.atlas,
            &self.work_area,
        )?;
        Ok(self.outbound_builder.finished_data())
    }

    /// Updates the authoritative snapshot and returns the displaced storage.
    /// The compositor scene builder uses that vector as its next scratch
    /// generation, keeping application-frame-rate metadata off the allocator.
    pub fn update_windows(
        &mut self,
        mut windows: Vec<WindowDescription>,
        restored_window_ids: &BTreeSet<u64>,
    ) -> Result<(Option<&[u8]>, Vec<WindowDescription>), WireError> {
        let next_restored_window_ids = windows
            .iter()
            .filter_map(|window| {
                restored_window_ids
                    .contains(&window.window_id)
                    .then_some(window.window_id)
            })
            .collect::<Vec<_>>();
        // Buffer-only scene revisions usually keep all metadata unchanged.
        // The stored snapshot has already passed validation, so avoid the
        // validator's hash-table work on this application-frame-rate path.
        if self.windows == windows && self.restored_window_ids == next_restored_window_ids {
            return Ok((None, windows));
        }
        validate_windows(&windows)?;
        std::mem::swap(&mut self.windows, &mut windows);
        self.restored_window_ids = next_restored_window_ids;
        let sequence = self.take_sequence();
        self.outbound_builder.reset();
        encode_windows_update(
            &mut self.outbound_builder,
            sequence,
            &self.windows,
            &self.restored_window_ids,
        )?;
        Ok((Some(self.outbound_builder.finished_data()), windows))
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

    pub fn drain_settings_commands(&mut self) -> impl Iterator<Item = SettingsCommand> + '_ {
        self.pending_settings_commands.drain(..)
    }

    /// Takes the latest validated system-bar update. Settings changes are
    /// deliberately last-writer-wins so rapid pointer or keyboard input stays
    /// bounded and applies as one compositor transaction.
    pub fn take_work_area_update(&mut self) -> Option<WorkAreaOptions> {
        self.pending_work_area.take()
    }

    pub fn encode_window_action(
        &mut self,
        window_id: u64,
        action: WindowAction,
    ) -> Result<&[u8], WireError> {
        if window_id == 0 {
            return Err(WireError::Identity);
        }
        let sequence = self.take_sequence();
        self.outbound_builder.reset();
        encode_window_action(&mut self.outbound_builder, sequence, window_id, action)?;
        Ok(self.outbound_builder.finished_data())
    }

    pub fn encode_window_activated(&mut self, window_id: u64) -> Result<&[u8], WireError> {
        if window_id == 0 {
            return Err(WireError::Identity);
        }
        let sequence = self.take_sequence();
        self.outbound_builder.reset();
        encode_window_event(
            &mut self.outbound_builder,
            sequence,
            fb::WindowEventKind::Activated,
            window_id,
            fb::WindowActionKind::Minimize,
        )?;
        Ok(self.outbound_builder.finished_data())
    }

    pub fn encode_window_placement(
        &mut self,
        placement: WindowPlacement,
    ) -> Result<[u8; WINDOW_PLACEMENT_PACKET_BYTES], WireError> {
        if placement.window_id == 0 {
            return Err(WireError::Identity);
        }
        if placement.monitor_id < 0 || placement.workspace_id == -1 {
            return Err(WireError::Topology("invalid window placement ownership"));
        }
        let geometry = placement.geometry;
        if !geometry.x.is_finite()
            || !geometry.y.is_finite()
            || !geometry.width.is_finite()
            || !geometry.height.is_finite()
            || geometry.width < 1.0
            || geometry.height < 1.0
        {
            return Err(WireError::Geometry);
        }
        let sequence = self.take_sequence();
        Ok(encode_window_placement(sequence, placement))
    }

    pub fn encode_shell_action(
        &mut self,
        action: ShellAction,
        monitor_id: Option<i64>,
    ) -> Result<&[u8], WireError> {
        if monitor_id.is_some_and(|monitor_id| monitor_id < 0) {
            return Err(WireError::Topology("invalid shell action monitor"));
        }
        let sequence = self.take_sequence();
        self.outbound_builder.reset();
        encode_shell_action(
            &mut self.outbound_builder,
            sequence,
            action,
            monitor_id,
            0,
            None,
        )?;
        Ok(self.outbound_builder.finished_data())
    }

    pub fn encode_screenshot_action(
        &mut self,
        action: ShellAction,
        request_id: u64,
        texture_id: Option<i64>,
    ) -> Result<&[u8], WireError> {
        let valid_action = matches!(
            action,
            ShellAction::ScreenshotRegion
                | ShellAction::ScreenshotTextureReady
                | ShellAction::ScreenshotDone
        );
        if !valid_action
            || request_id == 0
            || texture_id.is_some_and(|texture_id| texture_id <= 0)
            || (action == ShellAction::ScreenshotTextureReady) != texture_id.is_some()
        {
            return Err(WireError::Identity);
        }
        let sequence = self.take_sequence();
        self.outbound_builder.reset();
        encode_shell_action(
            &mut self.outbound_builder,
            sequence,
            action,
            None,
            request_id,
            texture_id,
        )?;
        Ok(self.outbound_builder.finished_data())
    }

    pub fn encode_cursor_shape(&mut self, shape: &str) -> Result<&[u8], WireError> {
        let shape = shape.trim();
        if shape.is_empty() || shape.len() > MAX_STRING_BYTES {
            return Err(WireError::String);
        }
        let sequence = self.take_sequence();
        self.outbound_builder.reset();
        encode_cursor_shape(&mut self.outbound_builder, sequence, shape)?;
        Ok(self.outbound_builder.finished_data())
    }

    pub fn encode_cursor_position(&mut self, x: f64, y: f64) -> Result<&[u8], WireError> {
        if !x.is_finite() || !y.is_finite() {
            return Err(WireError::Geometry);
        }
        let sequence = self.take_sequence();
        self.outbound_builder.reset();
        encode_cursor_position(&mut self.outbound_builder, sequence, x, y)?;
        Ok(self.outbound_builder.finished_data())
    }

    pub fn encode_text_input_state(
        &mut self,
        active: bool,
        input_panel_visible: bool,
        legacy: bool,
        content_hint: u32,
        content_purpose: u32,
    ) -> Result<&[u8], WireError> {
        if input_panel_visible && !active {
            return Err(WireError::Payload);
        }
        let sequence = self.take_sequence();
        self.outbound_builder.reset();
        encode_text_input_state(
            &mut self.outbound_builder,
            sequence,
            active,
            input_panel_visible,
            legacy,
            content_hint,
            content_purpose,
        )?;
        Ok(self.outbound_builder.finished_data())
    }

    pub fn encode_notification_event(
        &mut self,
        event: &NotificationEvent,
    ) -> Result<&[u8], WireError> {
        validate_notification_event(event)?;
        let sequence = self.take_sequence();
        self.outbound_builder.reset();
        encode_notification_event(&mut self.outbound_builder, sequence, event)?;
        Ok(self.outbound_builder.finished_data())
    }

    pub fn encode_settings_document_response(
        &mut self,
        request_id: u64,
        revision: u64,
        document: Option<&str>,
        error: Option<&str>,
    ) -> Result<&[u8], WireError> {
        if request_id == 0 || revision == 0 {
            return Err(WireError::RequestId);
        }
        if document.is_some_and(|document| document.len() > MAX_SETTINGS_DOCUMENT_BYTES)
            || error.is_some_and(|error| error.len() > MAX_STRING_BYTES)
        {
            return Err(WireError::Size(
                document.map_or_else(|| error.map_or(0, str::len), str::len),
            ));
        }
        let sequence = self.take_sequence();
        self.outbound_builder.reset();
        encode_settings_response(
            &mut self.outbound_builder,
            sequence,
            request_id,
            fb::SettingsResponseKind::Document,
            revision,
            document,
            None,
            &[],
            0,
            None,
            None,
            error,
        )?;
        Ok(self.outbound_builder.finished_data())
    }

    pub fn encode_input_device_capabilities_response(
        &mut self,
        request_id: u64,
        revision: u64,
        has_touchpad: bool,
        touchpad: &TouchpadSettings,
        error: Option<&str>,
    ) -> Result<&[u8], WireError> {
        if revision == 0 || error.is_some_and(|error| error.len() > MAX_STRING_BYTES) {
            return Err(WireError::Identity);
        }
        let sequence = self.take_sequence();
        self.outbound_builder.reset();
        let touchpad = fb::TouchpadConfiguration::create(
            &mut self.outbound_builder,
            &fb::TouchpadConfigurationArgs {
                tap_to_click_enabled: touchpad.tap_to_click_enabled,
                natural_scroll_enabled: touchpad.natural_scroll_enabled,
                scroll_speed_factor: touchpad.scroll_speed_factor,
            },
        );
        let input_devices = fb::InputDeviceCapabilities::create(
            &mut self.outbound_builder,
            &fb::InputDeviceCapabilitiesArgs {
                has_touchpad,
                touchpad: Some(touchpad),
            },
        );
        let error = error.map(|error| self.outbound_builder.create_string(error));
        let response = fb::SettingsResponse::create(
            &mut self.outbound_builder,
            &fb::SettingsResponseArgs {
                kind: fb::SettingsResponseKind::InputDevices,
                success: error.is_none(),
                revision,
                error,
                input_devices: Some(input_devices),
                ..Default::default()
            },
        );
        let envelope = fb::Envelope::create(
            &mut self.outbound_builder,
            &fb::EnvelopeArgs {
                protocol_version: PROTOCOL_VERSION,
                sequence,
                request_id,
                payload_type: fb::Payload::SettingsResponse,
                payload: Some(response.as_union_value()),
            },
        );
        fb::finish_envelope_buffer(&mut self.outbound_builder, envelope);
        validate_finished_message(&self.outbound_builder)?;
        Ok(self.outbound_builder.finished_data())
    }

    #[allow(clippy::too_many_arguments)]
    pub fn encode_keyboard_settings_response(
        &mut self,
        request_id: u64,
        revision: u64,
        keyboard: &KeyboardSettings,
        display_names: &[String],
        active_layout: usize,
        error: Option<&str>,
    ) -> Result<&[u8], WireError> {
        if revision == 0 || active_layout >= keyboard.layouts.len() {
            return Err(WireError::Identity);
        }
        if display_names.len() != keyboard.layouts.len()
            || error.is_some_and(|error| error.len() > MAX_STRING_BYTES)
        {
            return Err(WireError::Count);
        }
        let sequence = self.take_sequence();
        self.outbound_builder.reset();
        encode_settings_response(
            &mut self.outbound_builder,
            sequence,
            request_id,
            fb::SettingsResponseKind::Keyboard,
            revision,
            None,
            Some(keyboard),
            display_names,
            active_layout,
            None,
            None,
            error,
        )?;
        Ok(self.outbound_builder.finished_data())
    }

    pub fn encode_shortcut_configuration_response(
        &mut self,
        request_id: u64,
        revision: u64,
        shortcuts: &[ShortcutBinding],
        supported_inputs: &[ShortcutInputDefinition],
        error: Option<&str>,
    ) -> Result<&[u8], WireError> {
        if request_id == 0 || revision == 0 || shortcuts.len() > MAX_SHORTCUTS {
            return Err(WireError::Identity);
        }
        if supported_inputs.len() > MAX_SHORTCUT_INPUTS
            || error.is_some_and(|error| error.len() > MAX_STRING_BYTES)
        {
            return Err(WireError::Count);
        }
        let sequence = self.take_sequence();
        self.outbound_builder.reset();
        encode_settings_response(
            &mut self.outbound_builder,
            sequence,
            request_id,
            fb::SettingsResponseKind::Shortcuts,
            revision,
            None,
            None,
            &[],
            0,
            Some((shortcuts, supported_inputs)),
            None,
            error,
        )?;
        Ok(self.outbound_builder.finished_data())
    }

    pub fn encode_shortcut_validation_response(
        &mut self,
        request_id: u64,
        revision: u64,
        validation: &ShortcutValidation,
    ) -> Result<&[u8], WireError> {
        if request_id == 0 || revision == 0 {
            return Err(WireError::RequestId);
        }
        let sequence = self.take_sequence();
        self.outbound_builder.reset();
        encode_settings_response(
            &mut self.outbound_builder,
            sequence,
            request_id,
            fb::SettingsResponseKind::ShortcutValidation,
            revision,
            None,
            None,
            &[],
            0,
            None,
            Some(validation),
            None,
        )?;
        Ok(self.outbound_builder.finished_data())
    }

    /// Handles one verified Flutter message and returns an ordered response,
    /// when the payload is a request/reply operation.
    pub fn handle(&mut self, bytes: &[u8]) -> Result<Option<&[u8]>, WireError> {
        if !(MIN_ENVELOPE_BYTES..=MAX_MESSAGE_BYTES).contains(&bytes.len()) {
            return Err(WireError::Size(bytes.len()));
        }
        if !fb::envelope_buffer_has_identifier(bytes) {
            return Err(WireError::Identifier);
        }

        let verifier = flatbuffers::VerifierOptions {
            max_depth: 16,
            max_tables: 16_384,
            max_apparent_size: MAX_MESSAGE_BYTES + 1,
            ignore_missing_null_terminator: false,
        };
        let envelope =
            fb::root_as_envelope_with_opts(&verifier, bytes).map_err(WireError::FlatBuffer)?;
        if envelope.protocol_version() != PROTOCOL_VERSION {
            return Err(WireError::Version(envelope.protocol_version()));
        }
        if envelope.sequence() == 0 {
            return Err(WireError::Sequence);
        }

        match envelope.payload_type() {
            fb::Payload::InputLayout => {
                let layout = envelope
                    .payload_as_input_layout()
                    .ok_or(WireError::Payload)?;
                let mut decoded = std::mem::take(&mut self.input_layout_scratch);
                let mut identities = std::mem::take(&mut self.input_layout_identities_scratch);
                let result = decode_input_layout(layout, &mut decoded, &mut identities);
                self.input_layout_identities_scratch = identities;
                if let Err(error) = result {
                    self.input_layout_scratch = decoded;
                    return Err(error);
                }
                if let Some(displaced) = self.pending_input_layout.replace(decoded) {
                    self.input_layout_scratch = displaced;
                }
                Ok(None)
            }
            fb::Payload::KeyboardCommand => {
                let command = envelope
                    .payload_as_keyboard_command()
                    .ok_or(WireError::Payload)?;
                if self.pending_keyboard_commands.len() >= MAX_PENDING_KEYBOARD_COMMANDS {
                    return Err(WireError::Count);
                }
                let command = decode_keyboard_command(command)?;
                self.pending_keyboard_commands.push_back(command);
                Ok(None)
            }
            fb::Payload::DesktopNotificationCommand => {
                let command = envelope
                    .payload_as_desktop_notification_command()
                    .ok_or(WireError::Payload)?;
                if self.pending_notification_commands.len() >= MAX_PENDING_NOTIFICATION_COMMANDS {
                    return Err(WireError::Count);
                }
                let command = decode_notification_command(command)?;
                self.pending_notification_commands.push_back(command);
                Ok(None)
            }
            fb::Payload::SettingsRequest => {
                if envelope.request_id() == 0 {
                    return Err(WireError::RequestId);
                }
                if self.pending_settings_commands.len() >= MAX_PENDING_SETTINGS_COMMANDS {
                    return Err(WireError::Count);
                }
                let request = envelope
                    .payload_as_settings_request()
                    .ok_or(WireError::Payload)?;
                let command = decode_settings_request(envelope.request_id(), request)?;
                self.pending_settings_commands.push_back(command);
                Ok(None)
            }
            fb::Payload::WindowRequest => {
                let request = envelope
                    .payload_as_window_request()
                    .ok_or(WireError::Payload)?;
                self.handle_window_request(envelope.request_id(), request)
            }
            fb::Payload::NONE => Err(WireError::Payload),
            payload => Err(WireError::Direction(payload)),
        }
    }

    fn handle_window_request(
        &mut self,
        request_id: u64,
        request: fb::WindowRequest<'_>,
    ) -> Result<Option<&[u8]>, WireError> {
        match request.kind() {
            fb::WindowRequestKind::ListWindows => {
                if request_id == 0 {
                    return Err(WireError::RequestId);
                }
                let sequence = self.take_sequence();
                self.outbound_builder.reset();
                encode_windows_response(
                    &mut self.outbound_builder,
                    sequence,
                    request_id,
                    &self.windows,
                    &self.restored_window_ids,
                )?;
                Ok(Some(self.outbound_builder.finished_data()))
            }
            fb::WindowRequestKind::GetDisplayLayout => {
                if request_id == 0 {
                    return Err(WireError::RequestId);
                }
                let sequence = self.take_sequence();
                self.outbound_builder.reset();
                encode_display_layout(
                    &mut self.outbound_builder,
                    sequence,
                    request_id,
                    &self.snapshot,
                    &self.atlas,
                    &self.work_area,
                )?;
                Ok(Some(self.outbound_builder.finished_data()))
            }
            fb::WindowRequestKind::ConfigureSystemBar => {
                if request_id == 0 {
                    return Err(WireError::RequestId);
                }
                let side = match request.system_bar_side() {
                    fb::SystemBarSide::Left => SystemBarSide::Left,
                    fb::SystemBarSide::Right => SystemBarSide::Right,
                    fb::SystemBarSide::Top => SystemBarSide::Top,
                    fb::SystemBarSide::Bottom => SystemBarSide::Bottom,
                    fb::SystemBarSide::Hidden => return Err(WireError::Enumeration),
                    _ => return Err(WireError::Enumeration),
                };
                let monitor_ids = request.system_bar_monitor_ids().ok_or(WireError::Payload)?;
                if monitor_ids.is_empty() || monitor_ids.len() > self.snapshot.outputs.len() {
                    return Err(WireError::Count);
                }
                let mut unique_ids = HashSet::with_capacity(monitor_ids.len());
                let mut outputs = Vec::with_capacity(monitor_ids.len());
                for requested_monitor_id in monitor_ids {
                    if requested_monitor_id < 0 || !unique_ids.insert(requested_monitor_id) {
                        return Err(WireError::Identity);
                    }
                    let output = self
                        .snapshot
                        .outputs
                        .iter()
                        .find(|output| monitor_id(output.id) == Some(requested_monitor_id))
                        .ok_or(WireError::Topology("system bar monitor is not live"))?;
                    outputs.push(output.name.clone());
                }
                self.work_area.system_bar.outputs = outputs;
                self.work_area.system_bar.side = side;
                self.pending_work_area = Some(self.work_area.clone());

                let sequence = self.take_sequence();
                self.outbound_builder.reset();
                encode_display_layout(
                    &mut self.outbound_builder,
                    sequence,
                    request_id,
                    &self.snapshot,
                    &self.atlas,
                    &self.work_area,
                )?;
                Ok(Some(self.outbound_builder.finished_data()))
            }
            kind @ (fb::WindowRequestKind::CloseWindow
            | fb::WindowRequestKind::FocusWindow
            | fb::WindowRequestKind::ConfigureWindow) => {
                if self.pending_window_commands.len() >= MAX_PENDING_WINDOW_COMMANDS {
                    return Err(WireError::Count);
                }
                let window_id = request.window_id();
                if window_id == 0 {
                    return Err(WireError::Identity);
                }
                let command = match kind {
                    fb::WindowRequestKind::CloseWindow => WindowCommand::Close { window_id },
                    fb::WindowRequestKind::FocusWindow => WindowCommand::Focus { window_id },
                    fb::WindowRequestKind::ConfigureWindow => {
                        let geometry =
                            decode_window_geometry(request.geometry().ok_or(WireError::Geometry)?)?;
                        WindowCommand::Configure {
                            window_id,
                            geometry,
                            exact: request.flags() & 1 != 0,
                        }
                    }
                    _ => unreachable!(),
                };
                self.pending_window_commands.push_back(command);
                Ok(None)
            }
            fb::WindowRequestKind::CreateLocalWindow => {
                if request_id != 0 {
                    return Err(WireError::RequestId);
                }
                if self.pending_window_commands.len() >= MAX_PENDING_WINDOW_COMMANDS {
                    return Err(WireError::Count);
                }
                let app_id = request.app_id().ok_or(WireError::Payload)?;
                let title = request.title().ok_or(WireError::Payload)?;
                if app_id.is_empty()
                    || app_id.len() > MAX_LOCAL_APP_ID_BYTES
                    || title.is_empty()
                    || title.len() > MAX_LOCAL_WINDOW_TITLE_BYTES
                    || app_id.contains('\0')
                    || title.contains('\0')
                {
                    return Err(WireError::Payload);
                }
                let geometry =
                    decode_window_geometry(request.geometry().ok_or(WireError::Geometry)?)?;
                self.pending_window_commands
                    .push_back(WindowCommand::CreateLocal {
                        app_id: app_id.to_owned(),
                        title: title.to_owned(),
                        geometry,
                    });
                Ok(None)
            }
            kind => Err(WireError::Request(kind)),
        }
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

fn decode_window_geometry(rect: &fb::WireRect) -> Result<WindowGeometry, WireError> {
    let geometry = WindowGeometry {
        x: rect.x(),
        y: rect.y(),
        width: rect.width(),
        height: rect.height(),
    };
    let right = geometry.x + geometry.width;
    let bottom = geometry.y + geometry.height;
    if !geometry.x.is_finite()
        || !geometry.y.is_finite()
        || !geometry.width.is_finite()
        || !geometry.height.is_finite()
        || !right.is_finite()
        || !bottom.is_finite()
        || geometry.x < 0.0
        || geometry.y < 0.0
        || geometry.x > 16_384.0
        || geometry.y > 16_384.0
        || geometry.width < 64.0
        || geometry.height < 64.0
        || geometry.width > 16_384.0
        || geometry.height > 16_384.0
        || right > i32::MAX as f64
        || bottom > i32::MAX as f64
    {
        return Err(WireError::Geometry);
    }
    Ok(geometry)
}

fn validate_required_string(value: Option<&str>) -> Result<(), WireError> {
    match value {
        Some(value) if !value.is_empty() && value.len() <= MAX_STRING_BYTES => Ok(()),
        _ => Err(WireError::String),
    }
}

fn decode_keyboard_command(command: fb::KeyboardCommand<'_>) -> Result<KeyboardCommand, WireError> {
    if command.kind().variant_name().is_none() {
        return Err(WireError::Enumeration);
    }
    if command.flags() & !KEYBOARD_FLAGS_MASK != 0 {
        return Err(WireError::Flags);
    }

    match command.kind() {
        fb::KeyboardCommandKind::Text => {
            if command.flags() != 0 {
                return Err(WireError::Flags);
            }
            let text = command.text();
            validate_required_string(text)?;
            Ok(KeyboardCommand::Text(
                text.expect("validated keyboard text").to_owned(),
            ))
        }
        fb::KeyboardCommandKind::Key => {
            let key = command.key();
            validate_required_string(key)?;
            let phase = match command.flags() & KEYBOARD_PHASE_MASK {
                0 => KeyboardKeyPhase::Tap,
                KEYBOARD_PRESSED => KeyboardKeyPhase::Pressed,
                KEYBOARD_RELEASED => KeyboardKeyPhase::Released,
                _ => return Err(WireError::Flags),
            };
            let ctrl = command.flags() & KEYBOARD_CTRL != 0;
            if ctrl && phase != KeyboardKeyPhase::Tap {
                return Err(WireError::Flags);
            }
            Ok(KeyboardCommand::Key {
                key: key.expect("validated keyboard key").to_owned(),
                ctrl,
                phase,
            })
        }
        _ => Err(WireError::Enumeration),
    }
}

fn decode_settings_request(
    request_id: u64,
    request: fb::SettingsRequest<'_>,
) -> Result<SettingsCommand, WireError> {
    match request.kind() {
        fb::SettingsRequestKind::ReadDocument => {
            if request.expected_revision() != 0
                || request.document().is_some()
                || request.keyboard().is_some()
                || request.shortcut().is_some()
                || request.existing_shortcut().is_some()
                || request.touchpad().is_some()
            {
                return Err(WireError::Payload);
            }
            Ok(SettingsCommand::ReadDocument { request_id })
        }
        fb::SettingsRequestKind::WriteDocument => {
            let document = request.document().ok_or(WireError::String)?;
            if request.expected_revision() == 0
                || document.is_empty()
                || document.len() > MAX_SETTINGS_DOCUMENT_BYTES
                || request.keyboard().is_some()
                || request.shortcut().is_some()
                || request.existing_shortcut().is_some()
                || request.touchpad().is_some()
            {
                return Err(WireError::Payload);
            }
            Ok(SettingsCommand::WriteDocument {
                request_id,
                expected_revision: request.expected_revision(),
                document: document.to_owned(),
            })
        }
        fb::SettingsRequestKind::ReadKeyboard => {
            if request.expected_revision() != 0
                || request.document().is_some()
                || request.keyboard().is_some()
                || request.shortcut().is_some()
                || request.existing_shortcut().is_some()
                || request.touchpad().is_some()
            {
                return Err(WireError::Payload);
            }
            Ok(SettingsCommand::ReadKeyboard { request_id })
        }
        fb::SettingsRequestKind::ConfigureKeyboard => {
            if request.expected_revision() == 0
                || request.document().is_some()
                || request.shortcut().is_some()
                || request.existing_shortcut().is_some()
                || request.touchpad().is_some()
            {
                return Err(WireError::Payload);
            }
            let keyboard = decode_keyboard_settings(request.keyboard().ok_or(WireError::Payload)?)?;
            Ok(SettingsCommand::ConfigureKeyboard {
                request_id,
                expected_revision: request.expected_revision(),
                keyboard,
            })
        }
        fb::SettingsRequestKind::ReadShortcuts => {
            if request.expected_revision() != 0
                || request.document().is_some()
                || request.keyboard().is_some()
                || request.shortcut().is_some()
                || request.existing_shortcut().is_some()
                || request.touchpad().is_some()
            {
                return Err(WireError::Payload);
            }
            Ok(SettingsCommand::ReadShortcuts { request_id })
        }
        fb::SettingsRequestKind::ValidateShortcut => {
            if request.expected_revision() != 0
                || request.document().is_some()
                || request.keyboard().is_some()
                || request.touchpad().is_some()
            {
                return Err(WireError::Payload);
            }
            let shortcut = decode_shortcut_binding(request.shortcut().ok_or(WireError::Payload)?)?;
            let existing_shortcut = request
                .existing_shortcut()
                .map(|shortcut| {
                    if !valid_shortcut_wire_string(shortcut, false) {
                        Err(WireError::String)
                    } else {
                        Ok(shortcut.to_owned())
                    }
                })
                .transpose()?;
            Ok(SettingsCommand::ValidateShortcut {
                request_id,
                shortcut,
                existing_shortcut,
            })
        }
        fb::SettingsRequestKind::AddShortcut => {
            if request.expected_revision() == 0
                || request.document().is_some()
                || request.keyboard().is_some()
                || request.existing_shortcut().is_some()
                || request.touchpad().is_some()
            {
                return Err(WireError::Payload);
            }
            Ok(SettingsCommand::AddShortcut {
                request_id,
                expected_revision: request.expected_revision(),
                shortcut: decode_shortcut_binding(request.shortcut().ok_or(WireError::Payload)?)?,
            })
        }
        fb::SettingsRequestKind::UpdateShortcut => {
            if request.expected_revision() == 0
                || request.document().is_some()
                || request.keyboard().is_some()
                || request.touchpad().is_some()
            {
                return Err(WireError::Payload);
            }
            let existing_shortcut = request
                .existing_shortcut()
                .filter(|shortcut| valid_shortcut_wire_string(shortcut, false))
                .ok_or(WireError::String)?
                .to_owned();
            Ok(SettingsCommand::UpdateShortcut {
                request_id,
                expected_revision: request.expected_revision(),
                existing_shortcut,
                shortcut: decode_shortcut_binding(request.shortcut().ok_or(WireError::Payload)?)?,
            })
        }
        fb::SettingsRequestKind::RemoveShortcut => {
            if request.expected_revision() == 0
                || request.document().is_some()
                || request.keyboard().is_some()
                || request.shortcut().is_some()
                || request.touchpad().is_some()
            {
                return Err(WireError::Payload);
            }
            let shortcut = request
                .existing_shortcut()
                .filter(|shortcut| valid_shortcut_wire_string(shortcut, false))
                .ok_or(WireError::String)?
                .to_owned();
            Ok(SettingsCommand::RemoveShortcut {
                request_id,
                expected_revision: request.expected_revision(),
                shortcut,
            })
        }
        fb::SettingsRequestKind::RestoreShortcuts => {
            if request.expected_revision() == 0
                || request.document().is_some()
                || request.keyboard().is_some()
                || request.shortcut().is_some()
                || request.existing_shortcut().is_some()
                || request.touchpad().is_some()
            {
                return Err(WireError::Payload);
            }
            Ok(SettingsCommand::RestoreShortcuts {
                request_id,
                expected_revision: request.expected_revision(),
            })
        }
        fb::SettingsRequestKind::ReadInputDevices => {
            if request.expected_revision() != 0
                || request.document().is_some()
                || request.keyboard().is_some()
                || request.shortcut().is_some()
                || request.existing_shortcut().is_some()
                || request.touchpad().is_some()
            {
                return Err(WireError::Payload);
            }
            Ok(SettingsCommand::ReadInputDevices { request_id })
        }
        fb::SettingsRequestKind::ConfigureTouchpad => {
            if request.expected_revision() == 0
                || request.document().is_some()
                || request.keyboard().is_some()
                || request.shortcut().is_some()
                || request.existing_shortcut().is_some()
            {
                return Err(WireError::Payload);
            }
            let touchpad = request.touchpad().ok_or(WireError::Payload)?;
            Ok(SettingsCommand::ConfigureTouchpad {
                request_id,
                expected_revision: request.expected_revision(),
                touchpad: TouchpadSettings {
                    tap_to_click_enabled: touchpad.tap_to_click_enabled(),
                    natural_scroll_enabled: touchpad.natural_scroll_enabled(),
                    scroll_speed_factor: touchpad.scroll_speed_factor(),
                },
            })
        }
        _ => Err(WireError::Enumeration),
    }
}

fn decode_shortcut_binding(binding: fb::ShortcutBinding<'_>) -> Result<ShortcutBinding, WireError> {
    let shortcut = binding
        .shortcut()
        .filter(|shortcut| valid_shortcut_wire_string(shortcut, true))
        .ok_or(WireError::String)?;
    let target = match binding.target_type() {
        fb::ShortcutTarget::ShortcutDenialActionTarget => {
            let target = binding
                .target_as_shortcut_denial_action_target()
                .ok_or(WireError::Payload)?;
            ShortcutTarget::DenialAction {
                action: shortcut_action_from_wire(target.action())?,
            }
        }
        fb::ShortcutTarget::ShortcutSpawnTarget => {
            let target = binding
                .target_as_shortcut_spawn_target()
                .ok_or(WireError::Payload)?;
            let command = target.command().ok_or(WireError::Payload)?;
            if command.len() > MAX_SPAWN_ARGUMENTS {
                return Err(WireError::Count);
            }
            let mut arguments = Vec::with_capacity(command.len());
            for argument in command {
                if !valid_shortcut_wire_string(argument, true) {
                    return Err(WireError::String);
                }
                arguments.push(argument.to_owned());
            }
            ShortcutTarget::Spawn { command: arguments }
        }
        fb::ShortcutTarget::ShortcutSpawnShTarget => {
            let target = binding
                .target_as_shortcut_spawn_sh_target()
                .ok_or(WireError::Payload)?;
            let command = target
                .command()
                .filter(|command| valid_shortcut_wire_string(command, true))
                .ok_or(WireError::String)?;
            ShortcutTarget::SpawnSh {
                command: command.to_owned(),
            }
        }
        _ => return Err(WireError::Enumeration),
    };
    Ok(ShortcutBinding {
        shortcut: shortcut.to_owned(),
        target,
    })
}

fn valid_shortcut_wire_string(value: &str, empty_allowed: bool) -> bool {
    (empty_allowed || !value.is_empty()) && value.len() <= MAX_STRING_BYTES && !value.contains('\0')
}

fn shortcut_action_from_wire(action: fb::ShortcutActionKind) -> Result<ShortcutAction, WireError> {
    match action {
        fb::ShortcutActionKind::Shutdown => Ok(ShortcutAction::Shutdown),
        fb::ShortcutActionKind::OpenApplications => Ok(ShortcutAction::OpenApplications),
        fb::ShortcutActionKind::OpenOverview => Ok(ShortcutAction::OpenOverview),
        fb::ShortcutActionKind::ToggleVerticalMaximize => {
            Ok(ShortcutAction::ToggleVerticalMaximize)
        }
        fb::ShortcutActionKind::WindowSwitcher => Ok(ShortcutAction::WindowSwitcher),
        fb::ShortcutActionKind::OpenClipboard => Ok(ShortcutAction::OpenClipboard),
        fb::ShortcutActionKind::CaptureRegion => Ok(ShortcutAction::CaptureRegion),
        fb::ShortcutActionKind::CloseWindow => Ok(ShortcutAction::CloseWindow),
        fb::ShortcutActionKind::MinimizeWindow => Ok(ShortcutAction::MinimizeWindow),
        fb::ShortcutActionKind::ToggleMaximize => Ok(ShortcutAction::ToggleMaximize),
        fb::ShortcutActionKind::ToggleFullscreen => Ok(ShortcutAction::ToggleFullscreen),
        fb::ShortcutActionKind::ReleasePointer => Ok(ShortcutAction::ReleasePointer),
        fb::ShortcutActionKind::LockScreen => Ok(ShortcutAction::LockScreen),
        fb::ShortcutActionKind::VolumeUp => Ok(ShortcutAction::VolumeUp),
        fb::ShortcutActionKind::VolumeDown => Ok(ShortcutAction::VolumeDown),
        fb::ShortcutActionKind::VolumeMute => Ok(ShortcutAction::VolumeMute),
        fb::ShortcutActionKind::BrightnessUp => Ok(ShortcutAction::BrightnessUp),
        fb::ShortcutActionKind::BrightnessDown => Ok(ShortcutAction::BrightnessDown),
        fb::ShortcutActionKind::NextKeyboardLayout => Ok(ShortcutAction::NextKeyboardLayout),
        fb::ShortcutActionKind::PreviousKeyboardLayout => {
            Ok(ShortcutAction::PreviousKeyboardLayout)
        }
        _ => Err(WireError::Enumeration),
    }
}

fn decode_keyboard_settings(
    keyboard: fb::KeyboardConfiguration<'_>,
) -> Result<KeyboardSettings, WireError> {
    let layouts = keyboard.layouts().ok_or(WireError::Payload)?;
    let options = keyboard.options().ok_or(WireError::Payload)?;
    let mut decoded_layouts = Vec::with_capacity(layouts.len());
    for layout in layouts {
        if layout.display_name().is_some_and(|name| !name.is_empty()) {
            return Err(WireError::Payload);
        }
        decoded_layouts.push(KeyboardLayout {
            layout: layout.layout().ok_or(WireError::String)?.to_owned(),
            variant: layout.variant().unwrap_or_default().to_owned(),
        });
    }
    let decoded = KeyboardSettings {
        layouts: decoded_layouts,
        options: options.iter().map(str::to_owned).collect(),
        repeat_delay_ms: keyboard.repeat_delay_ms(),
        repeat_rate_hz: keyboard.repeat_rate_hz(),
    };
    decoded.validate().map_err(|_| WireError::Payload)?;
    Ok(decoded)
}

fn decode_notification_command(
    command: fb::DesktopNotificationCommand<'_>,
) -> Result<NotificationCommand, WireError> {
    if command.kind().variant_name().is_none() {
        return Err(WireError::Enumeration);
    }
    let notification_id = command.notification_id();
    if notification_id == 0 {
        return Err(WireError::Identity);
    }

    match command.kind() {
        fb::DesktopNotificationCommandKind::InvokeAction => {
            validate_required_string(command.action_key())?;
            Ok(NotificationCommand::InvokeAction {
                notification_id,
                action_key: command
                    .action_key()
                    .expect("validated notification action key")
                    .to_owned(),
            })
        }
        fb::DesktopNotificationCommandKind::Dismiss => {
            if command.action_key().is_some_and(|key| !key.is_empty()) {
                Err(WireError::String)
            } else {
                Ok(NotificationCommand::Dismiss { notification_id })
            }
        }
        fb::DesktopNotificationCommandKind::InvokeDefault => {
            if command.action_key().is_some_and(|key| !key.is_empty()) {
                Err(WireError::String)
            } else {
                Ok(NotificationCommand::InvokeDefault { notification_id })
            }
        }
        _ => Err(WireError::Enumeration),
    }
}

fn validate_notification_event(event: &NotificationEvent) -> Result<(), WireError> {
    if event.notification_id == 0 {
        return Err(WireError::Identity);
    }
    match event.kind {
        NotificationEventKind::Closed => {
            if event.notification.is_some() || !(1..=4).contains(&event.close_reason) {
                return Err(WireError::Payload);
            }
        }
        NotificationEventKind::Added | NotificationEventKind::Replaced => {
            let notification = event.notification.as_ref().ok_or(WireError::Payload)?;
            if notification.id != event.notification_id || event.close_reason != 0 {
                return Err(WireError::Identity);
            }
            if notification.actions.len() > 16
                || notification.actions.iter().any(|action| {
                    action.key.is_empty()
                        || action.key.len() > MAX_STRING_BYTES
                        || action.label.len() > MAX_STRING_BYTES
                })
                || [
                    &notification.sender,
                    &notification.app_name,
                    &notification.app_icon,
                    &notification.summary,
                    &notification.body,
                    &notification.category,
                    &notification.desktop_entry,
                    &notification.image_path,
                    &notification.sound_name,
                    &notification.sound_file,
                ]
                .into_iter()
                .any(|value| value.len() > MAX_STRING_BYTES)
            {
                return Err(WireError::String);
            }
            if let Some(image) = notification.image_data.as_ref() {
                let expected_channels = if image.has_alpha { 4 } else { 3 };
                let required = (image.row_stride as usize)
                    .checked_mul(image.height as usize)
                    .ok_or(WireError::Count)?;
                if image.width == 0
                    || image.height == 0
                    || image.width > 4096
                    || image.height > 4096
                    || image.bits_per_sample != 8
                    || image.channels != expected_channels
                    || image.row_stride < image.width.saturating_mul(image.channels.into())
                    || required != image.data.len()
                    || required > 512 * 1024
                {
                    return Err(WireError::Count);
                }
            }
        }
    }
    Ok(())
}

fn decode_input_layout(
    layout: fb::InputLayout<'_>,
    decoded: &mut InputLayoutSnapshot,
    identities: &mut HashSet<u64>,
) -> Result<(), WireError> {
    let shell_regions = layout.shell_regions();
    let software_keyboard_regions = layout.software_keyboard_regions();
    let windows = layout.windows();
    let visible_surface_ids = layout.visible_surface_ids();
    if shell_regions.is_some_and(|regions| regions.len() > MAX_REGIONS)
        || software_keyboard_regions.is_some_and(|regions| regions.len() > MAX_REGIONS)
        || windows.is_some_and(|regions| regions.len() > MAX_REGIONS)
        || visible_surface_ids.is_some_and(|ids| ids.len() > MAX_SURFACES)
    {
        return Err(WireError::Count);
    }

    decoded.epoch = layout.epoch();
    decoded.flags = layout.flags();
    decoded.shell_regions.clear();
    decoded.software_keyboard_regions.clear();
    decoded.windows.clear();
    decoded.visible_surface_ids.clear();
    identities.clear();

    if let Some(regions) = shell_regions {
        decoded.shell_regions.reserve(regions.len());
        for index in 0..regions.len() {
            decoded
                .shell_regions
                .push(decode_input_rect(regions.get(index))?);
        }
    }

    if let Some(regions) = software_keyboard_regions {
        decoded.software_keyboard_regions.reserve(regions.len());
        for index in 0..regions.len() {
            decoded
                .software_keyboard_regions
                .push(decode_input_rect(regions.get(index))?);
        }
    }

    if let Some(windows) = windows {
        decoded.windows.reserve(windows.len());
        identities.reserve(windows.len());
        let mut previous: Option<(i32, u64)> = None;
        for index in 0..windows.len() {
            let window = windows.get(index);
            if window.object_id() == 0 || window.surface_id() == 0 || window.window_id() == 0 {
                return Err(WireError::Identity);
            }
            if !identities.insert(window.surface_id()) {
                return Err(WireError::Identity);
            }
            if previous.is_some_and(|(z, surface_id)| {
                z < window.z() || (z == window.z() && surface_id < window.surface_id())
            }) {
                return Err(WireError::Ordering);
            }
            let rect = decode_input_rect(window.rect())?;
            let source_rect = decode_input_rect(window.source_rect())?;
            decoded.windows.push(InputWindowRegion {
                object_id: window.object_id(),
                surface_id: window.surface_id(),
                window_id: window.window_id(),
                rect,
                source_rect,
                z: window.z(),
                flags: window.flags(),
            });
            previous = Some((window.z(), window.surface_id()));
        }
    }

    identities.clear();
    if let Some(visible_surface_ids) = visible_surface_ids {
        decoded
            .visible_surface_ids
            .reserve(visible_surface_ids.len());
        identities.reserve(visible_surface_ids.len());
        for index in 0..visible_surface_ids.len() {
            let surface_id = visible_surface_ids.get(index);
            if surface_id == 0 || !identities.insert(surface_id) {
                return Err(WireError::Identity);
            }
            decoded.visible_surface_ids.push(surface_id);
        }
    }

    Ok(())
}

fn decode_input_rect(rect: &fb::WireRect) -> Result<InputRect, WireError> {
    let rect = InputRect {
        x: rect.x(),
        y: rect.y(),
        width: rect.width(),
        height: rect.height(),
    };
    if !rect.x.is_finite()
        || !rect.y.is_finite()
        || !rect.width.is_finite()
        || !rect.height.is_finite()
        || rect.width <= 0.0
        || rect.height <= 0.0
    {
        return Err(WireError::Geometry);
    }
    Ok(rect)
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

fn create_window_snapshot<'a>(
    builder: &mut FlatBufferBuilder<'a>,
    descriptions: &[WindowDescription],
    restored_window_ids: &[u64],
) -> WIPOffset<fb::WindowSnapshot<'a>> {
    let mut windows = Vec::with_capacity(descriptions.len());
    for description in descriptions {
        let mut surface_layers = Vec::with_capacity(description.surfaces.len());
        for surface in &description.surfaces {
            surface_layers.push(fb::SurfaceLayer::create(
                builder,
                &fb::SurfaceLayerArgs {
                    surface_id: surface.surface_id,
                    parent_surface_id: surface.parent_surface_id,
                    popup_root_surface_id: surface.popup_root_surface_id,
                    role: surface.role.wire(),
                    texture_id: surface.texture_id,
                    width: surface.width,
                    height: surface.height,
                    surface_x: surface.surface_x,
                    surface_y: surface.surface_y,
                    surface_width: surface.surface_width,
                    surface_height: surface.surface_height,
                    texture_source_x: surface.texture_source_x,
                    texture_source_y: surface.texture_source_y,
                    texture_source_width: surface.texture_source_width,
                    texture_source_height: surface.texture_source_height,
                    transform: surface.transform,
                    scale_120: surface.scale_120,
                    composition_order: surface.composition_order,
                    opacity: surface.opacity,
                    opaque: surface.opaque,
                },
            ));
        }
        let surface_layers = builder.create_vector(&surface_layers);
        let title = builder.create_string(&description.title);
        let app_id = builder.create_string(&description.app_id);
        windows.push(fb::Window::create(
            builder,
            &fb::WindowArgs {
                object_id: description.object_id,
                object_kind: fb::ObjectKind::RootSurface,
                surface_id: description.surface_id,
                window_id: description.window_id,
                texture_id: description.texture_id,
                title: Some(title),
                app_id: Some(app_id),
                width: description.width,
                height: description.height,
                surface_x: description.surface_x,
                surface_y: description.surface_y,
                surface_width: description.surface_width,
                surface_height: description.surface_height,
                texture_source_x: description.texture_source_x,
                texture_source_y: description.texture_source_y,
                texture_source_width: description.texture_source_width,
                texture_source_height: description.texture_source_height,
                geometry_x: description.geometry_x,
                geometry_y: description.geometry_y,
                geometry_width: description.geometry_width,
                geometry_height: description.geometry_height,
                monitor_id: description.monitor_id,
                transform: description.transform,
                scale_120: description.scale_120,
                content_x: description.content_x,
                content_y: description.content_y,
                content_width: description.content_width,
                content_height: description.content_height,
                surfaces: Some(surface_layers),
                suppress_animations: description.suppress_animations,
                server_side_decorated: description.server_side_decorated,
                opacity: description.opacity,
                content_kind: description.content_kind.wire(),
                opacity_class: description.opacity_class.wire(),
                ..Default::default()
            },
        ));
    }
    let windows = builder.create_vector(&windows);
    let restored_window_ids = builder.create_vector(restored_window_ids);
    fb::WindowSnapshot::create(
        builder,
        &fb::WindowSnapshotArgs {
            windows: Some(windows),
            restored_window_ids: Some(restored_window_ids),
        },
    )
}

fn encode_windows_response(
    builder: &mut FlatBufferBuilder<'_>,
    sequence: u64,
    request_id: u64,
    descriptions: &[WindowDescription],
    restored_window_ids: &[u64],
) -> Result<(), WireError> {
    let snapshot = create_window_snapshot(builder, descriptions, restored_window_ids);
    let response = fb::WindowResponse::create(
        builder,
        &fb::WindowResponseArgs {
            kind: fb::WindowResponseKind::Windows,
            success: true,
            windows: Some(snapshot),
            ..Default::default()
        },
    );
    finish_response(builder, sequence, request_id, response)
}

fn encode_windows_update(
    builder: &mut FlatBufferBuilder<'_>,
    sequence: u64,
    descriptions: &[WindowDescription],
    restored_window_ids: &[u64],
) -> Result<(), WireError> {
    let snapshot = create_window_snapshot(builder, descriptions, restored_window_ids);
    let envelope = fb::Envelope::create(
        builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence,
            request_id: 0,
            payload_type: fb::Payload::WindowSnapshot,
            payload: Some(snapshot.as_union_value()),
        },
    );
    fb::finish_envelope_buffer(builder, envelope);
    validate_finished_message(builder)
}

fn encode_window_action(
    builder: &mut FlatBufferBuilder<'_>,
    sequence: u64,
    window_id: u64,
    action: WindowAction,
) -> Result<(), WireError> {
    encode_window_event(
        builder,
        sequence,
        fb::WindowEventKind::Action,
        window_id,
        action.wire(),
    )
}

fn encode_window_placement(
    sequence: u64,
    placement: WindowPlacement,
) -> [u8; WINDOW_PLACEMENT_PACKET_BYTES] {
    let mut bytes = [0; WINDOW_PLACEMENT_PACKET_BYTES];
    bytes[0..4].copy_from_slice(b"DENP");
    bytes[4..6].copy_from_slice(&PROTOCOL_VERSION.to_le_bytes());
    bytes[6..8].copy_from_slice(&2u16.to_le_bytes());
    bytes[8..12].copy_from_slice(&(WINDOW_PLACEMENT_PACKET_BYTES as u32).to_le_bytes());
    bytes[12..20].copy_from_slice(&sequence.to_le_bytes());
    bytes[20..28].copy_from_slice(&placement.window_id.to_le_bytes());
    bytes[28..36].copy_from_slice(&placement.monitor_id.to_le_bytes());
    bytes[36..44].copy_from_slice(&placement.workspace_id.to_le_bytes());
    bytes[44] = placement.phase as u8;
    bytes[45] = placement.change as u8;
    bytes[48..56].copy_from_slice(&placement.geometry.x.to_le_bytes());
    bytes[56..64].copy_from_slice(&placement.geometry.y.to_le_bytes());
    bytes[64..72].copy_from_slice(&placement.geometry.width.to_le_bytes());
    bytes[72..80].copy_from_slice(&placement.geometry.height.to_le_bytes());
    bytes
}

fn encode_window_event(
    builder: &mut FlatBufferBuilder<'_>,
    sequence: u64,
    kind: fb::WindowEventKind,
    window_id: u64,
    action: fb::WindowActionKind,
) -> Result<(), WireError> {
    let event = fb::WindowEvent::create(
        builder,
        &fb::WindowEventArgs {
            kind,
            window_id,
            action,
        },
    );
    let envelope = fb::Envelope::create(
        builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence,
            request_id: 0,
            payload_type: fb::Payload::WindowEvent,
            payload: Some(event.as_union_value()),
        },
    );
    fb::finish_envelope_buffer(builder, envelope);
    validate_finished_message(builder)
}

fn encode_shell_action(
    builder: &mut FlatBufferBuilder<'_>,
    sequence: u64,
    action: ShellAction,
    monitor_id: Option<i64>,
    request_id: u64,
    texture_id: Option<i64>,
) -> Result<(), WireError> {
    let action = fb::ShellAction::create(
        builder,
        &fb::ShellActionArgs {
            action: action.wire(),
            monitor_id: monitor_id.unwrap_or(-1),
            has_monitor_id: monitor_id.is_some(),
            texture_id: texture_id.unwrap_or(0),
        },
    );
    let envelope = fb::Envelope::create(
        builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence,
            request_id,
            payload_type: fb::Payload::ShellAction,
            payload: Some(action.as_union_value()),
        },
    );
    fb::finish_envelope_buffer(builder, envelope);
    validate_finished_message(builder)
}

fn encode_cursor_shape(
    builder: &mut FlatBufferBuilder<'_>,
    sequence: u64,
    shape: &str,
) -> Result<(), WireError> {
    let shape = builder.create_string(shape);
    let cursor = fb::CursorShape::create(builder, &fb::CursorShapeArgs { shape: Some(shape) });
    let envelope = fb::Envelope::create(
        builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence,
            request_id: 0,
            payload_type: fb::Payload::CursorShape,
            payload: Some(cursor.as_union_value()),
        },
    );
    fb::finish_envelope_buffer(builder, envelope);
    validate_finished_message(builder)
}

fn encode_cursor_position(
    builder: &mut FlatBufferBuilder<'_>,
    sequence: u64,
    x: f64,
    y: f64,
) -> Result<(), WireError> {
    let cursor = fb::CursorPosition::create(builder, &fb::CursorPositionArgs { x, y });
    let envelope = fb::Envelope::create(
        builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence,
            request_id: 0,
            payload_type: fb::Payload::CursorPosition,
            payload: Some(cursor.as_union_value()),
        },
    );
    fb::finish_envelope_buffer(builder, envelope);
    validate_finished_message(builder)
}

fn encode_text_input_state(
    builder: &mut FlatBufferBuilder<'_>,
    sequence: u64,
    active: bool,
    input_panel_visible: bool,
    legacy: bool,
    content_hint: u32,
    content_purpose: u32,
) -> Result<(), WireError> {
    let state = fb::TextInputState::create(
        builder,
        &fb::TextInputStateArgs {
            active,
            input_panel_visible,
            legacy,
            content_hint,
            content_purpose,
        },
    );
    let envelope = fb::Envelope::create(
        builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence,
            request_id: 0,
            payload_type: fb::Payload::TextInputState,
            payload: Some(state.as_union_value()),
        },
    );
    fb::finish_envelope_buffer(builder, envelope);
    validate_finished_message(builder)
}

#[allow(clippy::too_many_arguments)]
fn encode_settings_response(
    builder: &mut FlatBufferBuilder<'_>,
    sequence: u64,
    request_id: u64,
    kind: fb::SettingsResponseKind,
    revision: u64,
    document: Option<&str>,
    keyboard: Option<&KeyboardSettings>,
    display_names: &[String],
    active_layout: usize,
    shortcut_configuration: Option<(&[ShortcutBinding], &[ShortcutInputDefinition])>,
    shortcut_validation: Option<&ShortcutValidation>,
    error: Option<&str>,
) -> Result<(), WireError> {
    let document = document.map(|document| builder.create_string(document));
    let error = error.map(|error| builder.create_string(error));
    let keyboard = keyboard.map(|keyboard| {
        let mut layouts = Vec::with_capacity(keyboard.layouts.len());
        for (layout, display_name) in keyboard.layouts.iter().zip(display_names) {
            let name = builder.create_string(&layout.layout);
            let variant = builder.create_string(&layout.variant);
            let display_name = builder.create_string(display_name);
            layouts.push(fb::KeyboardLayout::create(
                builder,
                &fb::KeyboardLayoutArgs {
                    layout: Some(name),
                    variant: Some(variant),
                    display_name: Some(display_name),
                },
            ));
        }
        let layouts = builder.create_vector(&layouts);
        let options = keyboard
            .options
            .iter()
            .map(|option| builder.create_string(option))
            .collect::<Vec<_>>();
        let options = builder.create_vector(&options);
        fb::KeyboardConfiguration::create(
            builder,
            &fb::KeyboardConfigurationArgs {
                layouts: Some(layouts),
                options: Some(options),
                repeat_delay_ms: keyboard.repeat_delay_ms,
                repeat_rate_hz: keyboard.repeat_rate_hz,
                active_layout: u32::try_from(active_layout).unwrap_or(u32::MAX),
            },
        )
    });
    let shortcuts = shortcut_configuration.map(|(bindings, inputs)| {
        let bindings = bindings
            .iter()
            .map(|binding| encode_shortcut_binding(builder, binding))
            .collect::<Vec<_>>();
        let bindings = builder.create_vector(&bindings);
        let actions = ShortcutAction::ALL.map(shortcut_action_to_wire);
        let actions = builder.create_vector(&actions);
        let inputs = inputs
            .iter()
            .map(|input| {
                let canonical = builder.create_string(&input.canonical);
                let aliases = input
                    .aliases
                    .iter()
                    .map(|alias| builder.create_string(alias))
                    .collect::<Vec<_>>();
                let aliases = builder.create_vector(&aliases);
                fb::ShortcutInput::create(
                    builder,
                    &fb::ShortcutInputArgs {
                        canonical: Some(canonical),
                        kind: shortcut_input_kind_to_wire(input.kind),
                        category: shortcut_input_category_to_wire(input.category),
                        aliases: Some(aliases),
                    },
                )
            })
            .collect::<Vec<_>>();
        let inputs = builder.create_vector(&inputs);
        fb::ShortcutConfiguration::create(
            builder,
            &fb::ShortcutConfigurationArgs {
                shortcuts: Some(bindings),
                supported_actions: Some(actions),
                supported_inputs: Some(inputs),
            },
        )
    });
    let shortcut_validation = shortcut_validation.map(|validation| {
        let (kind, canonical, conflict, validation_error) = match validation {
            ShortcutValidation::Valid { canonical } => (
                fb::ShortcutValidationKind::Valid,
                Some(canonical.as_str()),
                None,
                None,
            ),
            ShortcutValidation::Conflict { canonical, binding } => (
                fb::ShortcutValidationKind::Conflict,
                Some(canonical.as_str()),
                Some(binding),
                None,
            ),
            ShortcutValidation::Invalid { error } => (
                fb::ShortcutValidationKind::Invalid,
                None,
                None,
                Some(error.as_str()),
            ),
        };
        let canonical = canonical.map(|canonical| builder.create_string(canonical));
        let conflict = conflict.map(|binding| encode_shortcut_binding(builder, binding));
        let validation_error = validation_error.map(|error| builder.create_string(error));
        fb::ShortcutValidation::create(
            builder,
            &fb::ShortcutValidationArgs {
                kind,
                canonical,
                conflict,
                error: validation_error,
            },
        )
    });
    let response = fb::SettingsResponse::create(
        builder,
        &fb::SettingsResponseArgs {
            kind,
            success: error.is_none(),
            revision,
            document,
            keyboard,
            error,
            shortcuts,
            shortcut_validation,
            input_devices: None,
        },
    );
    let envelope = fb::Envelope::create(
        builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence,
            request_id,
            payload_type: fb::Payload::SettingsResponse,
            payload: Some(response.as_union_value()),
        },
    );
    fb::finish_envelope_buffer(builder, envelope);
    validate_finished_message(builder)
}

fn encode_shortcut_binding<'a>(
    builder: &mut FlatBufferBuilder<'a>,
    binding: &ShortcutBinding,
) -> WIPOffset<fb::ShortcutBinding<'a>> {
    let shortcut = builder.create_string(&binding.shortcut);
    let (target_type, target) = match &binding.target {
        ShortcutTarget::DenialAction { action } => {
            let target = fb::ShortcutDenialActionTarget::create(
                builder,
                &fb::ShortcutDenialActionTargetArgs {
                    action: shortcut_action_to_wire(*action),
                },
            );
            (
                fb::ShortcutTarget::ShortcutDenialActionTarget,
                target.as_union_value(),
            )
        }
        ShortcutTarget::Spawn { command } => {
            let command = command
                .iter()
                .map(|argument| builder.create_string(argument))
                .collect::<Vec<_>>();
            let command = builder.create_vector(&command);
            let target = fb::ShortcutSpawnTarget::create(
                builder,
                &fb::ShortcutSpawnTargetArgs {
                    command: Some(command),
                },
            );
            (
                fb::ShortcutTarget::ShortcutSpawnTarget,
                target.as_union_value(),
            )
        }
        ShortcutTarget::SpawnSh { command } => {
            let command = builder.create_string(command);
            let target = fb::ShortcutSpawnShTarget::create(
                builder,
                &fb::ShortcutSpawnShTargetArgs {
                    command: Some(command),
                },
            );
            (
                fb::ShortcutTarget::ShortcutSpawnShTarget,
                target.as_union_value(),
            )
        }
    };
    fb::ShortcutBinding::create(
        builder,
        &fb::ShortcutBindingArgs {
            shortcut: Some(shortcut),
            target_type,
            target: Some(target),
        },
    )
}

fn shortcut_action_to_wire(action: ShortcutAction) -> fb::ShortcutActionKind {
    match action {
        ShortcutAction::Shutdown => fb::ShortcutActionKind::Shutdown,
        ShortcutAction::OpenApplications => fb::ShortcutActionKind::OpenApplications,
        ShortcutAction::OpenOverview => fb::ShortcutActionKind::OpenOverview,
        ShortcutAction::ToggleVerticalMaximize => fb::ShortcutActionKind::ToggleVerticalMaximize,
        ShortcutAction::WindowSwitcher => fb::ShortcutActionKind::WindowSwitcher,
        ShortcutAction::OpenClipboard => fb::ShortcutActionKind::OpenClipboard,
        ShortcutAction::CaptureRegion => fb::ShortcutActionKind::CaptureRegion,
        ShortcutAction::CloseWindow => fb::ShortcutActionKind::CloseWindow,
        ShortcutAction::MinimizeWindow => fb::ShortcutActionKind::MinimizeWindow,
        ShortcutAction::ToggleMaximize => fb::ShortcutActionKind::ToggleMaximize,
        ShortcutAction::ToggleFullscreen => fb::ShortcutActionKind::ToggleFullscreen,
        ShortcutAction::ReleasePointer => fb::ShortcutActionKind::ReleasePointer,
        ShortcutAction::LockScreen => fb::ShortcutActionKind::LockScreen,
        ShortcutAction::VolumeUp => fb::ShortcutActionKind::VolumeUp,
        ShortcutAction::VolumeDown => fb::ShortcutActionKind::VolumeDown,
        ShortcutAction::VolumeMute => fb::ShortcutActionKind::VolumeMute,
        ShortcutAction::BrightnessUp => fb::ShortcutActionKind::BrightnessUp,
        ShortcutAction::BrightnessDown => fb::ShortcutActionKind::BrightnessDown,
        ShortcutAction::NextKeyboardLayout => fb::ShortcutActionKind::NextKeyboardLayout,
        ShortcutAction::PreviousKeyboardLayout => fb::ShortcutActionKind::PreviousKeyboardLayout,
    }
}

fn shortcut_input_kind_to_wire(kind: ShortcutInputKind) -> fb::ShortcutInputKind {
    match kind {
        ShortcutInputKind::Key => fb::ShortcutInputKind::Key,
        ShortcutInputKind::Gesture => fb::ShortcutInputKind::Gesture,
    }
}

fn shortcut_input_category_to_wire(category: ShortcutInputCategory) -> fb::ShortcutInputCategory {
    match category {
        ShortcutInputCategory::Modifier => fb::ShortcutInputCategory::Modifier,
        ShortcutInputCategory::Navigation => fb::ShortcutInputCategory::Navigation,
        ShortcutInputCategory::Editing => fb::ShortcutInputCategory::Editing,
        ShortcutInputCategory::Punctuation => fb::ShortcutInputCategory::Punctuation,
        ShortcutInputCategory::Function => fb::ShortcutInputCategory::Function,
        ShortcutInputCategory::Media => fb::ShortcutInputCategory::Media,
        ShortcutInputCategory::Hardware => fb::ShortcutInputCategory::Hardware,
        ShortcutInputCategory::Special => fb::ShortcutInputCategory::Special,
        ShortcutInputCategory::Gesture => fb::ShortcutInputCategory::Gesture,
    }
}

fn encode_notification_event(
    builder: &mut FlatBufferBuilder<'_>,
    sequence: u64,
    event: &NotificationEvent,
) -> Result<(), WireError> {
    let notification = event
        .notification
        .as_ref()
        .map(|notification| encode_notification(builder, notification));
    let kind = match event.kind {
        NotificationEventKind::Added => fb::DesktopNotificationEventKind::Added,
        NotificationEventKind::Replaced => fb::DesktopNotificationEventKind::Replaced,
        NotificationEventKind::Closed => fb::DesktopNotificationEventKind::Closed,
    };
    let event = fb::DesktopNotificationEvent::create(
        builder,
        &fb::DesktopNotificationEventArgs {
            kind,
            notification,
            notification_id: event.notification_id,
            close_reason: event.close_reason,
        },
    );
    let envelope = fb::Envelope::create(
        builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence,
            request_id: 0,
            payload_type: fb::Payload::DesktopNotificationEvent,
            payload: Some(event.as_union_value()),
        },
    );
    fb::finish_envelope_buffer(builder, envelope);
    validate_finished_message(builder)
}

fn encode_notification<'a>(
    builder: &mut FlatBufferBuilder<'a>,
    notification: &Notification,
) -> WIPOffset<fb::DesktopNotification<'a>> {
    let mut action_offsets = Vec::with_capacity(notification.actions.len());
    for action in &notification.actions {
        let key = builder.create_string(&action.key);
        let label = builder.create_string(&action.label);
        action_offsets.push(fb::DesktopNotificationAction::create(
            builder,
            &fb::DesktopNotificationActionArgs {
                key: Some(key),
                label: Some(label),
            },
        ));
    }
    let actions = builder.create_vector(&action_offsets);
    let image_data = notification.image_data.as_ref().map(|image| {
        let data = builder.create_vector(&image.data);
        fb::DesktopNotificationImageData::create(
            builder,
            &fb::DesktopNotificationImageDataArgs {
                width: image.width,
                height: image.height,
                row_stride: image.row_stride,
                has_alpha: image.has_alpha,
                bits_per_sample: image.bits_per_sample,
                channels: image.channels,
                data: Some(data),
            },
        )
    });
    let sender = builder.create_string(&notification.sender);
    let app_name = builder.create_string(&notification.app_name);
    let app_icon = builder.create_string(&notification.app_icon);
    let summary = builder.create_string(&notification.summary);
    let body = builder.create_string(&notification.body);
    let category = builder.create_string(&notification.category);
    let desktop_entry = builder.create_string(&notification.desktop_entry);
    let image_path = builder.create_string(&notification.image_path);
    let sound_name = builder.create_string(&notification.sound_name);
    let sound_file = builder.create_string(&notification.sound_file);
    let urgency = match notification.urgency {
        NotificationUrgency::Low => fb::DesktopNotificationUrgency::Low,
        NotificationUrgency::Normal => fb::DesktopNotificationUrgency::Normal,
        NotificationUrgency::Critical => fb::DesktopNotificationUrgency::Critical,
    };
    fb::DesktopNotification::create(
        builder,
        &fb::DesktopNotificationArgs {
            id: notification.id,
            sender: Some(sender),
            app_name: Some(app_name),
            app_icon: Some(app_icon),
            summary: Some(summary),
            body: Some(body),
            actions: Some(actions),
            urgency,
            category: Some(category),
            desktop_entry: Some(desktop_entry),
            image_path: Some(image_path),
            image_data,
            resident: notification.resident,
            transient: notification.transient,
            suppress_sound: notification.suppress_sound,
            action_icons: notification.action_icons,
            sound_name: Some(sound_name),
            sound_file: Some(sound_file),
            x: notification.x,
            y: notification.y,
            has_position: notification.has_position,
            progress: notification.progress,
            has_progress: notification.has_progress,
            expire_timeout_ms: notification.expire_timeout_ms,
        },
    )
}

fn encode_display_layout(
    builder: &mut FlatBufferBuilder<'_>,
    sequence: u64,
    request_id: u64,
    snapshot: &TopologySnapshot,
    atlas: &AtlasPlan,
    work_area: &WorkAreaOptions,
) -> Result<(), WireError> {
    let mut ordered = snapshot.outputs.iter().collect::<Vec<_>>();
    ordered.sort_by(|left, right| {
        (left.position.x, left.position.y, left.name.as_str()).cmp(&(
            right.position.x,
            right.position.y,
            right.name.as_str(),
        ))
    });

    let mut outputs = Vec::with_capacity(ordered.len());
    for output in ordered {
        let planned = atlas
            .outputs
            .iter()
            .find(|planned| planned.id == output.id)
            .ok_or(WireError::Topology("output is absent from atlas"))?;
        let name = builder.create_string(&output.name);
        let logical = fb::WireRect::new(
            planned.logical_rect.x - atlas.logical_origin.0,
            planned.logical_rect.y - atlas.logical_origin.1,
            planned.logical_rect.width,
            planned.logical_rect.height,
        );
        let pixels = fb::WireSize::new(
            f64::from(planned.pixel_size.width),
            f64::from(planned.pixel_size.height),
        );
        let source = fb::WireRect::new(
            f64::from(planned.source_rect.x),
            f64::from(planned.source_rect.y),
            f64::from(planned.source_rect.width),
            f64::from(planned.source_rect.height),
        );
        outputs.push(fb::DisplayOutput::create(
            builder,
            &fb::DisplayOutputArgs {
                monitor_id: monitor_id(output.id)
                    .ok_or(WireError::Topology("monitor id exceeds i64"))?,
                name: Some(name),
                logical_rect: Some(&logical),
                pixel_size: Some(&pixels),
                source_rect: Some(&source),
                scale: f64::from(output.scale_120) / f64::from(SCALE_BASE),
                refresh_rate: f64::from(output.refresh_millihz) / 1_000.0,
            },
        ));
    }

    let outputs = builder.create_vector(&outputs);
    let origin = fb::WirePoint::new(atlas.logical_origin.0, atlas.logical_origin.1);
    let logical_size = fb::WireSize::new(atlas.logical_size.0, atlas.logical_size.1);
    let pixel_size = fb::WireSize::new(
        f64::from(atlas.pixel_size.width),
        f64::from(atlas.pixel_size.height),
    );
    let ticker = snapshot.ticker.and_then(monitor_id).unwrap_or(-1);
    let (system_bar_monitor_ids, system_bar_side, system_bar_thickness) =
        resolve_system_bar(snapshot, &work_area.system_bar, ticker);
    let system_bar_monitor_id = if system_bar_monitor_ids.contains(&ticker) {
        ticker
    } else {
        system_bar_monitor_ids.first().copied().unwrap_or(-1)
    };
    let system_bar_monitor_ids = builder.create_vector(&system_bar_monitor_ids);
    let maximize_padding = if work_area.maximize_padding.is_finite() {
        work_area.maximize_padding.max(0.0)
    } else {
        0.0
    };
    let layout = fb::DisplayLayout::create(
        builder,
        &fb::DisplayLayoutArgs {
            epoch: snapshot.epoch,
            global_origin: Some(&origin),
            logical_size: Some(&logical_size),
            pixel_size: Some(&pixel_size),
            engine_scale: f64::from(atlas.engine_scale_120) / f64::from(SCALE_BASE),
            ticker_monitor_id: ticker,
            system_bar_monitor_id,
            system_bar_side,
            system_bar_thickness,
            maximize_padding,
            system_bar_monitor_ids: Some(system_bar_monitor_ids),
            outputs: Some(outputs),
        },
    );
    let response = fb::WindowResponse::create(
        builder,
        &fb::WindowResponseArgs {
            kind: fb::WindowResponseKind::DisplayLayout,
            success: true,
            display_layout: Some(layout),
            ..Default::default()
        },
    );
    finish_response(builder, sequence, request_id, response)
}

fn finish_response<'a>(
    builder: &mut FlatBufferBuilder<'a>,
    sequence: u64,
    request_id: u64,
    response: WIPOffset<fb::WindowResponse<'a>>,
) -> Result<(), WireError> {
    let envelope = fb::Envelope::create(
        builder,
        &fb::EnvelopeArgs {
            protocol_version: PROTOCOL_VERSION,
            sequence,
            request_id,
            payload_type: fb::Payload::WindowResponse,
            payload: Some(response.as_union_value()),
        },
    );
    fb::finish_envelope_buffer(builder, envelope);
    validate_finished_message(builder)
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
mod tests {
    use super::*;
    use denial_core::topology::{
        LogicalPoint, OutputSpec, OutputTransform, PixelSize, TopologyManager,
    };

    fn bridge() -> WireBridge {
        let topology = TopologyManager::new([
            OutputSpec {
                id: OutputId(7),
                name: "left".into(),
                position: LogicalPoint::new(-1920, 0),
                mode: PixelSize::new(1920, 1080),
                scale_120: 120,
                refresh_millihz: 60_000,
                transform: OutputTransform::Normal,
            },
            OutputSpec {
                id: OutputId(9),
                name: "main".into(),
                position: LogicalPoint::new(0, 0),
                mode: PixelSize::new(2560, 1440),
                scale_120: 120,
                refresh_millihz: 180_000,
                transform: OutputTransform::Normal,
            },
        ])
        .unwrap();
        let snapshot = topology.snapshot();
        let atlas = AtlasPlan::for_snapshot(&snapshot).unwrap();
        WireBridge::new(&snapshot, &atlas, WorkAreaOptions::default()).unwrap()
    }

    fn request(kind: fb::WindowRequestKind, request_id: u64) -> Vec<u8> {
        window_request(kind, request_id, 0, None)
    }

    fn window_request(
        kind: fb::WindowRequestKind,
        request_id: u64,
        window_id: u64,
        geometry: Option<fb::WireRect>,
    ) -> Vec<u8> {
        window_request_with_sequence(kind, request_id, window_id, geometry, 4)
    }

    fn window_request_with_sequence(
        kind: fb::WindowRequestKind,
        request_id: u64,
        window_id: u64,
        geometry: Option<fb::WireRect>,
        sequence: u64,
    ) -> Vec<u8> {
        let mut builder = FlatBufferBuilder::new();
        let request = fb::WindowRequest::create(
            &mut builder,
            &fb::WindowRequestArgs {
                kind,
                window_id,
                geometry: geometry.as_ref(),
                app_id: None,
                title: None,
                ..Default::default()
            },
        );
        let envelope = fb::Envelope::create(
            &mut builder,
            &fb::EnvelopeArgs {
                protocol_version: PROTOCOL_VERSION,
                sequence,
                request_id,
                payload_type: fb::Payload::WindowRequest,
                payload: Some(request.as_union_value()),
            },
        );
        fb::finish_envelope_buffer(&mut builder, envelope);
        builder.finished_data().to_vec()
    }

    fn exact_window_request(window_id: u64, geometry: fb::WireRect) -> Vec<u8> {
        let mut builder = FlatBufferBuilder::new();
        let request = fb::WindowRequest::create(
            &mut builder,
            &fb::WindowRequestArgs {
                kind: fb::WindowRequestKind::ConfigureWindow,
                window_id,
                geometry: Some(&geometry),
                flags: 1,
                ..Default::default()
            },
        );
        let envelope = fb::Envelope::create(
            &mut builder,
            &fb::EnvelopeArgs {
                protocol_version: PROTOCOL_VERSION,
                sequence: 4,
                request_id: 0,
                payload_type: fb::Payload::WindowRequest,
                payload: Some(request.as_union_value()),
            },
        );
        fb::finish_envelope_buffer(&mut builder, envelope);
        builder.finished_data().to_vec()
    }

    fn create_local_window_request(
        request_id: u64,
        app_id: &str,
        title: &str,
        geometry: fb::WireRect,
    ) -> Vec<u8> {
        let mut builder = FlatBufferBuilder::new();
        let app_id = builder.create_string(app_id);
        let title = builder.create_string(title);
        let request = fb::WindowRequest::create(
            &mut builder,
            &fb::WindowRequestArgs {
                kind: fb::WindowRequestKind::CreateLocalWindow,
                window_id: 0,
                geometry: Some(&geometry),
                app_id: Some(app_id),
                title: Some(title),
                ..Default::default()
            },
        );
        let envelope = fb::Envelope::create(
            &mut builder,
            &fb::EnvelopeArgs {
                protocol_version: PROTOCOL_VERSION,
                sequence: 4,
                request_id,
                payload_type: fb::Payload::WindowRequest,
                payload: Some(request.as_union_value()),
            },
        );
        fb::finish_envelope_buffer(&mut builder, envelope);
        builder.finished_data().to_vec()
    }

    fn configure_system_bar_request(
        request_id: u64,
        side: fb::SystemBarSide,
        monitor_ids: &[i64],
    ) -> Vec<u8> {
        let mut builder = FlatBufferBuilder::new();
        let monitor_ids = builder.create_vector(monitor_ids);
        let request = fb::WindowRequest::create(
            &mut builder,
            &fb::WindowRequestArgs {
                kind: fb::WindowRequestKind::ConfigureSystemBar,
                system_bar_side: side,
                system_bar_monitor_ids: Some(monitor_ids),
                ..Default::default()
            },
        );
        let envelope = fb::Envelope::create(
            &mut builder,
            &fb::EnvelopeArgs {
                protocol_version: PROTOCOL_VERSION,
                sequence: 5,
                request_id,
                payload_type: fb::Payload::WindowRequest,
                payload: Some(request.as_union_value()),
            },
        );
        fb::finish_envelope_buffer(&mut builder, envelope);
        builder.finished_data().to_vec()
    }

    fn input_layout(
        shell_regions: &[fb::WireRect],
        windows: &[fb::InputWindowRegion],
        flags: u32,
    ) -> Vec<u8> {
        input_layout_with_visible(shell_regions, windows, &[], flags)
    }

    fn input_layout_with_visible(
        shell_regions: &[fb::WireRect],
        windows: &[fb::InputWindowRegion],
        visible_surface_ids: &[u64],
        flags: u32,
    ) -> Vec<u8> {
        let mut builder = FlatBufferBuilder::new();
        let shell_regions = builder.create_vector(shell_regions);
        let windows = builder.create_vector(windows);
        let visible_surface_ids = builder.create_vector(visible_surface_ids);
        let layout = fb::InputLayout::create(
            &mut builder,
            &fb::InputLayoutArgs {
                epoch: 7,
                flags,
                shell_regions: Some(shell_regions),
                windows: Some(windows),
                visible_surface_ids: Some(visible_surface_ids),
                software_keyboard_regions: None,
            },
        );
        let envelope = fb::Envelope::create(
            &mut builder,
            &fb::EnvelopeArgs {
                protocol_version: PROTOCOL_VERSION,
                sequence: 9,
                payload_type: fb::Payload::InputLayout,
                payload: Some(layout.as_union_value()),
                ..Default::default()
            },
        );
        fb::finish_envelope_buffer(&mut builder, envelope);
        builder.finished_data().to_vec()
    }

    fn keyboard_command(
        kind: fb::KeyboardCommandKind,
        text: Option<&str>,
        key: Option<&str>,
        flags: u32,
    ) -> Vec<u8> {
        let mut builder = FlatBufferBuilder::new();
        let text = text.map(|value| builder.create_string(value));
        let key = key.map(|value| builder.create_string(value));
        let command = fb::KeyboardCommand::create(
            &mut builder,
            &fb::KeyboardCommandArgs {
                kind,
                text,
                key,
                flags,
            },
        );
        let envelope = fb::Envelope::create(
            &mut builder,
            &fb::EnvelopeArgs {
                protocol_version: PROTOCOL_VERSION,
                sequence: 11,
                payload_type: fb::Payload::KeyboardCommand,
                payload: Some(command.as_union_value()),
                ..Default::default()
            },
        );
        fb::finish_envelope_buffer(&mut builder, envelope);
        builder.finished_data().to_vec()
    }

    fn settings_request(
        kind: fb::SettingsRequestKind,
        request_id: u64,
        expected_revision: u64,
        document: Option<&str>,
        keyboard: Option<(&[(&str, &str)], &[&str], u32, u32)>,
    ) -> Vec<u8> {
        let mut builder = FlatBufferBuilder::new();
        let document = document.map(|value| builder.create_string(value));
        let keyboard = keyboard.map(|(layouts, options, delay, rate)| {
            let layouts = layouts
                .iter()
                .map(|(layout, variant)| {
                    let layout = builder.create_string(layout);
                    let variant = builder.create_string(variant);
                    fb::KeyboardLayout::create(
                        &mut builder,
                        &fb::KeyboardLayoutArgs {
                            layout: Some(layout),
                            variant: Some(variant),
                            display_name: None,
                        },
                    )
                })
                .collect::<Vec<_>>();
            let layouts = builder.create_vector(&layouts);
            let options = options
                .iter()
                .map(|option| builder.create_string(option))
                .collect::<Vec<_>>();
            let options = builder.create_vector(&options);
            fb::KeyboardConfiguration::create(
                &mut builder,
                &fb::KeyboardConfigurationArgs {
                    layouts: Some(layouts),
                    options: Some(options),
                    repeat_delay_ms: delay,
                    repeat_rate_hz: rate,
                    active_layout: 0,
                },
            )
        });
        let request = fb::SettingsRequest::create(
            &mut builder,
            &fb::SettingsRequestArgs {
                kind,
                expected_revision,
                document,
                keyboard,
                ..Default::default()
            },
        );
        let envelope = fb::Envelope::create(
            &mut builder,
            &fb::EnvelopeArgs {
                protocol_version: PROTOCOL_VERSION,
                sequence: 12,
                request_id,
                payload_type: fb::Payload::SettingsRequest,
                payload: Some(request.as_union_value()),
            },
        );
        fb::finish_envelope_buffer(&mut builder, envelope);
        builder.finished_data().to_vec()
    }

    fn touchpad_settings_request(
        request_id: u64,
        expected_revision: u64,
        tap_to_click_enabled: bool,
        natural_scroll_enabled: bool,
        scroll_speed_factor: f64,
    ) -> Vec<u8> {
        let mut builder = FlatBufferBuilder::new();
        let touchpad = fb::TouchpadConfiguration::create(
            &mut builder,
            &fb::TouchpadConfigurationArgs {
                tap_to_click_enabled,
                natural_scroll_enabled,
                scroll_speed_factor,
            },
        );
        let request = fb::SettingsRequest::create(
            &mut builder,
            &fb::SettingsRequestArgs {
                kind: fb::SettingsRequestKind::ConfigureTouchpad,
                expected_revision,
                touchpad: Some(touchpad),
                ..Default::default()
            },
        );
        let envelope = fb::Envelope::create(
            &mut builder,
            &fb::EnvelopeArgs {
                protocol_version: PROTOCOL_VERSION,
                sequence: 13,
                request_id,
                payload_type: fb::Payload::SettingsRequest,
                payload: Some(request.as_union_value()),
            },
        );
        fb::finish_envelope_buffer(&mut builder, envelope);
        builder.finished_data().to_vec()
    }

    fn notification_command(
        kind: fb::DesktopNotificationCommandKind,
        notification_id: u32,
        action_key: Option<&str>,
    ) -> Vec<u8> {
        let mut builder = FlatBufferBuilder::new();
        let action_key = action_key.map(|value| builder.create_string(value));
        let command = fb::DesktopNotificationCommand::create(
            &mut builder,
            &fb::DesktopNotificationCommandArgs {
                kind,
                notification_id,
                action_key,
            },
        );
        let envelope = fb::Envelope::create(
            &mut builder,
            &fb::EnvelopeArgs {
                protocol_version: PROTOCOL_VERSION,
                sequence: 12,
                payload_type: fb::Payload::DesktopNotificationCommand,
                payload: Some(command.as_union_value()),
                ..Default::default()
            },
        );
        fb::finish_envelope_buffer(&mut builder, envelope);
        builder.finished_data().to_vec()
    }

    fn envelope_without_payload(payload_type: fb::Payload) -> Vec<u8> {
        let mut builder = FlatBufferBuilder::new();
        let envelope = fb::Envelope::create(
            &mut builder,
            &fb::EnvelopeArgs {
                protocol_version: PROTOCOL_VERSION,
                sequence: 13,
                payload_type,
                payload: None,
                ..Default::default()
            },
        );
        fb::finish_envelope_buffer(&mut builder, envelope);
        builder.finished_data().to_vec()
    }

    #[test]
    fn answers_window_list_with_an_empty_snapshot() {
        let mut bridge = bridge();
        let bytes = bridge
            .handle(&request(fb::WindowRequestKind::ListWindows, 41))
            .unwrap()
            .unwrap();
        let envelope = fb::root_as_envelope(bytes).unwrap();
        let response = envelope.payload_as_window_response().unwrap();
        assert_eq!(envelope.sequence(), 1);
        assert_eq!(envelope.request_id(), 41);
        assert_eq!(response.kind(), fb::WindowResponseKind::Windows);
        assert!(response.success());
        assert_eq!(response.windows().unwrap().windows().unwrap().len(), 0);
    }

    #[test]
    fn publishes_and_answers_with_the_current_wayland_window() {
        let window = WindowDescription {
            object_id: 11,
            surface_id: 11,
            window_id: 11,
            texture_id: 11,
            title: "Terminal".into(),
            app_id: "foot".into(),
            width: 1120,
            height: 700,
            surface_x: 0.0,
            surface_y: 0.0,
            surface_width: 1120.0,
            surface_height: 700.0,
            texture_source_x: 0.0,
            texture_source_y: 0.0,
            texture_source_width: 1120.0,
            texture_source_height: 700.0,
            geometry_x: 96.0,
            geometry_y: 72.0,
            geometry_width: 1120.0,
            geometry_height: 700.0,
            monitor_id: 9,
            transform: 0,
            scale_120: 120,
            content_x: 0.0,
            content_y: 0.0,
            content_width: 1120.0,
            content_height: 700.0,
            surfaces: vec![
                SurfaceLayerDescription {
                    surface_id: 11,
                    parent_surface_id: 0,
                    popup_root_surface_id: 0,
                    role: SurfaceRoleDescription::Root,
                    texture_id: 11,
                    width: 1120,
                    height: 700,
                    surface_x: 0.0,
                    surface_y: 0.0,
                    surface_width: 1120.0,
                    surface_height: 700.0,
                    texture_source_x: 0.0,
                    texture_source_y: 0.0,
                    texture_source_width: 1120.0,
                    texture_source_height: 700.0,
                    transform: 0,
                    scale_120: 120,
                    composition_order: 0,
                    opacity: 1.0,
                    opaque: true,
                },
                SurfaceLayerDescription {
                    surface_id: 12,
                    parent_surface_id: 11,
                    popup_root_surface_id: 12,
                    role: SurfaceRoleDescription::Popup,
                    texture_id: 12,
                    width: 280,
                    height: 180,
                    surface_x: 500.0,
                    surface_y: 40.0,
                    surface_width: 280.0,
                    surface_height: 180.0,
                    texture_source_x: 0.0,
                    texture_source_y: 0.0,
                    texture_source_width: 280.0,
                    texture_source_height: 180.0,
                    transform: 0,
                    scale_120: 120,
                    composition_order: 1,
                    opacity: 1.0,
                    opaque: false,
                },
            ],
            suppress_animations: false,
            server_side_decorated: true,
            opacity: 1.0,
            content_kind: WindowContentKind::SurfaceTree,
            opacity_class: WindowOpacityClass::FullyOpaque,
        };
        let mut bridge = bridge();
        let restored_window_ids = BTreeSet::from([window.window_id]);
        let (update, recycled) = bridge
            .update_windows(vec![window.clone()], &restored_window_ids)
            .unwrap();
        assert!(recycled.is_empty());
        let update = update.unwrap();
        let envelope = fb::root_as_envelope(update).unwrap();
        let snapshot = envelope.payload_as_window_snapshot().unwrap();
        let encoded = snapshot.windows().unwrap().get(0);
        assert_eq!(
            snapshot
                .restored_window_ids()
                .unwrap()
                .iter()
                .collect::<Vec<_>>(),
            [11]
        );

        assert_eq!(envelope.sequence(), 1);
        assert_eq!(envelope.request_id(), 0);
        assert_eq!(encoded.object_id(), 11);
        assert_eq!(encoded.texture_id(), 11);
        assert_eq!(encoded.title(), Some("Terminal"));
        assert_eq!(encoded.app_id(), Some("foot"));
        assert_eq!(encoded.geometry_x(), 96.0);
        assert!(!encoded.suppress_animations());
        assert!(encoded.server_side_decorated());
        assert_eq!(encoded.opacity_class(), fb::WindowOpacityClass::FullyOpaque);
        let surfaces = encoded.surfaces().unwrap();
        assert_eq!(surfaces.len(), 2);
        assert_eq!(surfaces.get(0).role(), fb::SurfaceRole::Root);
        assert!(surfaces.get(0).opaque());
        assert_eq!(surfaces.get(1).role(), fb::SurfaceRole::Popup);
        assert!(!surfaces.get(1).opaque());
        assert_eq!(surfaces.get(1).parent_surface_id(), 11);
        let mut misordered = window.clone();
        misordered.surfaces.reverse();
        assert!(matches!(
            validate_windows(&[misordered]),
            Err(WireError::Ordering)
        ));
        assert_eq!(bridge.window_ids().collect::<Vec<_>>(), [11]);
        let (update, unchanged) = bridge
            .update_windows(vec![window.clone()], &restored_window_ids)
            .unwrap();
        assert!(update.is_none());
        assert_eq!(unchanged.len(), 1);

        let (update, _) = bridge
            .update_windows(vec![window], &BTreeSet::new())
            .unwrap();
        let envelope = fb::root_as_envelope(update.unwrap()).unwrap();
        assert!(
            envelope
                .payload_as_window_snapshot()
                .unwrap()
                .restored_window_ids()
                .unwrap()
                .is_empty()
        );

        let response = bridge
            .handle(&request(fb::WindowRequestKind::ListWindows, 53))
            .unwrap()
            .unwrap();
        let envelope = fb::root_as_envelope(response).unwrap();
        let response = envelope.payload_as_window_response().unwrap();
        assert_eq!(envelope.sequence(), 3);
        assert_eq!(
            response
                .windows()
                .unwrap()
                .windows()
                .unwrap()
                .get(0)
                .window_id(),
            11
        );
    }

    #[test]
    fn display_layout_matches_the_shared_atlas() {
        let mut bridge = bridge();
        let bytes = bridge
            .handle(&request(fb::WindowRequestKind::GetDisplayLayout, 52))
            .unwrap()
            .unwrap();
        let envelope = fb::root_as_envelope(bytes).unwrap();
        let response = envelope.payload_as_window_response().unwrap();
        let layout = response.display_layout().unwrap();
        let outputs = layout.outputs().unwrap();

        assert_eq!(response.kind(), fb::WindowResponseKind::DisplayLayout);
        assert_eq!(layout.global_origin().unwrap().x(), -1920.0);
        assert_eq!(layout.logical_size().unwrap().width(), 4480.0);
        assert_eq!(layout.pixel_size().unwrap().width(), 4480.0);
        assert_eq!(layout.ticker_monitor_id(), 9);
        assert_eq!(layout.system_bar_monitor_id(), 9);
        assert_eq!(layout.system_bar_side(), fb::SystemBarSide::Top);
        assert_eq!(layout.system_bar_thickness(), 32.0);
        assert_eq!(outputs.len(), 2);
        assert_eq!(outputs.get(0).logical_rect().unwrap().x(), 0.0);
        assert_eq!(outputs.get(1).logical_rect().unwrap().x(), 1920.0);
        assert_eq!(outputs.get(1).source_rect().unwrap().x(), 1920.0);
    }

    #[test]
    fn system_bar_resolves_named_outputs_and_hides_cleanly() {
        fn layout_fields(
            system_bar: SystemBarOptions,
        ) -> (i64, Vec<i64>, fb::SystemBarSide, f64, f64) {
            let topology = TopologyManager::new([
                OutputSpec {
                    id: OutputId(7),
                    name: "left".into(),
                    position: LogicalPoint::new(-1920, 0),
                    mode: PixelSize::new(1920, 1080),
                    scale_120: 120,
                    refresh_millihz: 60_000,
                    transform: OutputTransform::Normal,
                },
                OutputSpec {
                    id: OutputId(9),
                    name: "main".into(),
                    position: LogicalPoint::new(0, 0),
                    mode: PixelSize::new(2560, 1440),
                    scale_120: 120,
                    refresh_millihz: 180_000,
                    transform: OutputTransform::Normal,
                },
            ])
            .unwrap();
            let snapshot = topology.snapshot();
            let atlas = AtlasPlan::for_snapshot(&snapshot).unwrap();
            let mut bridge = WireBridge::new(
                &snapshot,
                &atlas,
                WorkAreaOptions {
                    system_bar,
                    maximize_padding: 10.0,
                },
            )
            .unwrap();
            let bytes = bridge
                .handle(&request(fb::WindowRequestKind::GetDisplayLayout, 61))
                .unwrap()
                .unwrap();
            let envelope = fb::root_as_envelope(bytes).unwrap();
            let layout = envelope
                .payload_as_window_response()
                .unwrap()
                .display_layout()
                .unwrap();
            (
                layout.system_bar_monitor_id(),
                layout.system_bar_monitor_ids().unwrap().iter().collect(),
                layout.system_bar_side(),
                layout.system_bar_thickness(),
                layout.maximize_padding(),
            )
        }

        let named = layout_fields(SystemBarOptions {
            outputs: vec!["left".to_owned()],
            side: super::SystemBarSide::Bottom,
            thickness: 40.0,
        });
        assert_eq!(named, (7, vec![7], fb::SystemBarSide::Bottom, 40.0, 10.0));

        let absent = layout_fields(SystemBarOptions {
            outputs: vec!["unplugged".to_owned()],
            side: super::SystemBarSide::Top,
            thickness: 32.0,
        });
        assert_eq!(absent, (9, vec![9], fb::SystemBarSide::Top, 32.0, 10.0));

        let hidden = layout_fields(SystemBarOptions::hidden());
        assert_eq!(
            hidden,
            (-1, Vec::new(), fb::SystemBarSide::Hidden, 0.0, 10.0)
        );
    }

    #[test]
    fn configures_cloned_system_bars_as_one_validated_transaction() {
        let mut bridge = bridge();
        let bytes = bridge
            .handle(&configure_system_bar_request(
                62,
                fb::SystemBarSide::Left,
                &[7, 9],
            ))
            .unwrap()
            .unwrap();
        let envelope = fb::root_as_envelope(bytes).unwrap();
        let layout = envelope
            .payload_as_window_response()
            .unwrap()
            .display_layout()
            .unwrap();
        assert_eq!(layout.system_bar_monitor_id(), 9);
        assert_eq!(
            layout
                .system_bar_monitor_ids()
                .unwrap()
                .iter()
                .collect::<Vec<_>>(),
            vec![7, 9]
        );
        assert_eq!(layout.system_bar_side(), fb::SystemBarSide::Left);

        let update = bridge.take_work_area_update().unwrap();
        assert_eq!(update.system_bar.outputs, vec!["left", "main"]);
        assert_eq!(update.system_bar.side, SystemBarSide::Left);
        assert!(bridge.take_work_area_update().is_none());

        for request in [
            configure_system_bar_request(63, fb::SystemBarSide::Top, &[]),
            configure_system_bar_request(64, fb::SystemBarSide::Top, &[7, 7]),
            configure_system_bar_request(65, fb::SystemBarSide::Top, &[77]),
            configure_system_bar_request(66, fb::SystemBarSide::Hidden, &[7]),
        ] {
            assert!(bridge.handle(&request).is_err());
        }
    }

    #[test]
    fn validates_queries_and_queues_window_commands() {
        let mut bridge = bridge();
        let mut unidentified = request(fb::WindowRequestKind::ListWindows, 1);
        unidentified[4] = b'X';
        assert!(matches!(
            bridge.handle(&unidentified),
            Err(WireError::Identifier)
        ));
        assert!(matches!(
            bridge.handle(&request(fb::WindowRequestKind::ListWindows, 0)),
            Err(WireError::RequestId)
        ));
        assert!(matches!(
            bridge.handle(&window_request(
                fb::WindowRequestKind::CloseWindow,
                0,
                0,
                None,
            )),
            Err(WireError::Identity)
        ));

        bridge
            .handle(&window_request(
                fb::WindowRequestKind::CloseWindow,
                0,
                41,
                None,
            ))
            .unwrap();
        bridge
            .handle(&window_request(
                fb::WindowRequestKind::FocusWindow,
                0,
                42,
                None,
            ))
            .unwrap();
        bridge
            .handle(&window_request(
                fb::WindowRequestKind::ConfigureWindow,
                0,
                43,
                Some(fb::WireRect::new(96.0, 72.0, 1120.0, 700.0)),
            ))
            .unwrap();
        assert_eq!(
            bridge.drain_window_commands().collect::<Vec<_>>(),
            vec![
                WindowCommand::Close { window_id: 41 },
                WindowCommand::Focus { window_id: 42 },
                WindowCommand::Configure {
                    window_id: 43,
                    geometry: WindowGeometry {
                        x: 96.0,
                        y: 72.0,
                        width: 1120.0,
                        height: 700.0,
                    },
                    exact: false,
                },
            ]
        );
        bridge
            .handle(&exact_window_request(
                43,
                fb::WireRect::new(0.0, 48.0, 632.0, 1342.0),
            ))
            .unwrap();
        assert!(matches!(
            bridge.drain_window_commands().next(),
            Some(WindowCommand::Configure {
                window_id: 43,
                exact: true,
                ..
            })
        ));
        assert!(matches!(
            bridge.handle(&window_request(
                fb::WindowRequestKind::ConfigureWindow,
                0,
                43,
                Some(fb::WireRect::new(0.0, 0.0, 0.0, 700.0)),
            )),
            Err(WireError::Geometry)
        ));
        for geometry in [
            fb::WireRect::new(-1.0, 0.0, 640.0, 480.0),
            fb::WireRect::new(0.0, 0.0, 63.0, 480.0),
            fb::WireRect::new(16_385.0, 0.0, 640.0, 480.0),
            fb::WireRect::new(0.0, 0.0, 16_385.0, 480.0),
            fb::WireRect::new(f64::NAN, 0.0, 640.0, 480.0),
            fb::WireRect::new(0.0, 0.0, f64::INFINITY, 480.0),
            fb::WireRect::new(f64::MAX, 0.0, f64::MAX, 480.0),
        ] {
            assert!(matches!(
                bridge.handle(&window_request(
                    fb::WindowRequestKind::ConfigureWindow,
                    0,
                    43,
                    Some(geometry),
                )),
                Err(WireError::Geometry)
            ));
        }
        bridge
            .handle(&window_request(
                fb::WindowRequestKind::ConfigureWindow,
                0,
                43,
                Some(fb::WireRect::new(0.0, 0.0, 64.0, 64.0)),
            ))
            .unwrap();
        bridge
            .handle(&window_request(
                fb::WindowRequestKind::ConfigureWindow,
                0,
                43,
                Some(fb::WireRect::new(16_384.0, 16_384.0, 16_384.0, 16_384.0)),
            ))
            .unwrap();
        let boundary = bridge.drain_window_commands().last().unwrap();
        let WindowCommand::Configure { geometry, .. } = boundary else {
            panic!("last boundary command was not Configure");
        };
        assert_eq!(geometry.width as i32, 16_384);
        assert_eq!(geometry.height as i32, 16_384);
    }

    #[test]
    fn validates_and_queues_generic_local_window_creation() {
        let mut bridge = bridge();
        bridge
            .handle(&create_local_window_request(
                0,
                "dev.denial.notes",
                "Notes",
                fb::WireRect::new(120.0, 80.0, 900.0, 640.0),
            ))
            .unwrap();
        assert_eq!(
            bridge.drain_window_commands().collect::<Vec<_>>(),
            vec![WindowCommand::CreateLocal {
                app_id: "dev.denial.notes".into(),
                title: "Notes".into(),
                geometry: WindowGeometry {
                    x: 120.0,
                    y: 80.0,
                    width: 900.0,
                    height: 640.0,
                },
            }]
        );

        assert!(matches!(
            bridge.handle(&create_local_window_request(
                1,
                "dev.denial.notes",
                "Notes",
                fb::WireRect::new(120.0, 80.0, 900.0, 640.0),
            )),
            Err(WireError::RequestId)
        ));
        assert!(matches!(
            bridge.handle(&create_local_window_request(
                0,
                "",
                "Notes",
                fb::WireRect::new(120.0, 80.0, 900.0, 640.0),
            )),
            Err(WireError::Payload)
        ));
        assert!(matches!(
            bridge.handle(&create_local_window_request(
                0,
                "dev.denial.notes",
                "Notes",
                fb::WireRect::new(120.0, 80.0, 32.0, 640.0),
            )),
            Err(WireError::Geometry)
        ));
    }

    #[test]
    fn validates_sequences_and_wraps_outgoing_sequence_without_zero() {
        let mut bridge = bridge();
        assert!(matches!(
            bridge.handle(&window_request_with_sequence(
                fb::WindowRequestKind::ListWindows,
                1,
                0,
                None,
                0,
            )),
            Err(WireError::Sequence)
        ));

        bridge.next_sequence = i64::MAX as u64;
        let at_limit = fb::root_as_envelope(bridge.encode_window_activated(1).unwrap())
            .unwrap()
            .sequence();
        let wrapped = fb::root_as_envelope(bridge.encode_window_activated(1).unwrap())
            .unwrap()
            .sequence();
        assert_eq!(at_limit, i64::MAX as u64);
        assert_eq!(wrapped, 1);
    }

    #[test]
    fn validates_keyboard_and_notification_command_payloads() {
        let mut bridge = bridge();
        bridge
            .handle(&keyboard_command(
                fb::KeyboardCommandKind::Text,
                Some("hello"),
                None,
                0,
            ))
            .unwrap();
        bridge
            .handle(&keyboard_command(
                fb::KeyboardCommandKind::Key,
                None,
                Some("Backspace"),
                KEYBOARD_CTRL,
            ))
            .unwrap();
        assert_eq!(
            bridge.drain_keyboard_commands().collect::<Vec<_>>(),
            vec![
                KeyboardCommand::Text("hello".into()),
                KeyboardCommand::Key {
                    key: "Backspace".into(),
                    ctrl: true,
                    phase: KeyboardKeyPhase::Tap,
                },
            ]
        );
        bridge
            .handle(&keyboard_command(
                fb::KeyboardCommandKind::Key,
                None,
                Some("BackSpace"),
                KEYBOARD_PRESSED,
            ))
            .unwrap();
        bridge
            .handle(&keyboard_command(
                fb::KeyboardCommandKind::Key,
                None,
                Some("BackSpace"),
                KEYBOARD_RELEASED,
            ))
            .unwrap();
        assert_eq!(
            bridge.drain_keyboard_commands().collect::<Vec<_>>(),
            vec![
                KeyboardCommand::Key {
                    key: "BackSpace".into(),
                    ctrl: false,
                    phase: KeyboardKeyPhase::Pressed,
                },
                KeyboardCommand::Key {
                    key: "BackSpace".into(),
                    ctrl: false,
                    phase: KeyboardKeyPhase::Released,
                },
            ]
        );
        for invalid_flags in [
            KEYBOARD_PRESSED | KEYBOARD_RELEASED,
            KEYBOARD_CTRL | KEYBOARD_PRESSED,
        ] {
            assert!(matches!(
                bridge.handle(&keyboard_command(
                    fb::KeyboardCommandKind::Key,
                    None,
                    Some("BackSpace"),
                    invalid_flags,
                )),
                Err(WireError::Flags)
            ));
        }
        assert!(matches!(
            bridge.handle(&keyboard_command(
                fb::KeyboardCommandKind(255),
                Some("hello"),
                None,
                0,
            )),
            Err(WireError::Enumeration)
        ));
        assert!(matches!(
            bridge.handle(&keyboard_command(
                fb::KeyboardCommandKind::Text,
                Some("hello"),
                None,
                1 << 31,
            )),
            Err(WireError::Flags)
        ));
        let oversized = "x".repeat(MAX_STRING_BYTES + 1);
        for value in [None, Some(""), Some(oversized.as_str())] {
            assert!(matches!(
                bridge.handle(&keyboard_command(
                    fb::KeyboardCommandKind::Text,
                    value,
                    None,
                    0,
                )),
                Err(WireError::String)
            ));
        }

        bridge
            .handle(&notification_command(
                fb::DesktopNotificationCommandKind::Dismiss,
                9,
                None,
            ))
            .unwrap();
        bridge
            .handle(&notification_command(
                fb::DesktopNotificationCommandKind::InvokeAction,
                9,
                Some("open"),
            ))
            .unwrap();
        bridge
            .handle(&notification_command(
                fb::DesktopNotificationCommandKind::InvokeDefault,
                10,
                None,
            ))
            .unwrap();
        assert_eq!(
            bridge.drain_notification_commands().collect::<Vec<_>>(),
            vec![
                NotificationCommand::Dismiss { notification_id: 9 },
                NotificationCommand::InvokeAction {
                    notification_id: 9,
                    action_key: "open".into(),
                },
                NotificationCommand::InvokeDefault {
                    notification_id: 10,
                },
            ]
        );
        assert!(matches!(
            bridge.handle(&notification_command(
                fb::DesktopNotificationCommandKind(255),
                9,
                None,
            )),
            Err(WireError::Enumeration)
        ));
        assert!(matches!(
            bridge.handle(&notification_command(
                fb::DesktopNotificationCommandKind::Dismiss,
                0,
                None,
            )),
            Err(WireError::Identity)
        ));
        for action_key in [None, Some("")] {
            assert!(matches!(
                bridge.handle(&notification_command(
                    fb::DesktopNotificationCommandKind::InvokeAction,
                    9,
                    action_key,
                )),
                Err(WireError::String)
            ));
        }
        assert!(matches!(
            bridge.handle(&notification_command(
                fb::DesktopNotificationCommandKind::InvokeDefault,
                9,
                Some("unexpected"),
            )),
            Err(WireError::String)
        ));

        for payload_type in [
            fb::Payload::KeyboardCommand,
            fb::Payload::DesktopNotificationCommand,
        ] {
            assert!(matches!(
                bridge.handle(&envelope_without_payload(payload_type)),
                Err(WireError::Payload | WireError::FlatBuffer(_))
            ));
        }
    }

    #[test]
    fn rapid_keyboard_commands_remain_individual_and_ordered() {
        let mut bridge = bridge();
        let expected = "thequickbrownfox";

        for character in expected.chars() {
            let text = character.to_string();
            bridge
                .handle(&keyboard_command(
                    fb::KeyboardCommandKind::Text,
                    Some(&text),
                    None,
                    0,
                ))
                .unwrap();
        }

        let delivered = bridge
            .drain_keyboard_commands()
            .map(|command| match command {
                KeyboardCommand::Text(text) => text,
                KeyboardCommand::Key { .. } => panic!("text burst produced a named key"),
            })
            .collect::<Vec<_>>();
        assert_eq!(delivered.len(), expected.chars().count());
        assert_eq!(delivered.concat(), expected);
    }

    #[test]
    fn settings_requests_are_typed_bounded_and_revisioned() {
        let mut bridge = bridge();
        bridge
            .handle(&settings_request(
                fb::SettingsRequestKind::ReadDocument,
                41,
                0,
                None,
                None,
            ))
            .unwrap();
        bridge
            .handle(&settings_request(
                fb::SettingsRequestKind::WriteDocument,
                42,
                7,
                Some(r#"{"version":9}"#),
                None,
            ))
            .unwrap();
        bridge
            .handle(&settings_request(
                fb::SettingsRequestKind::ConfigureKeyboard,
                43,
                8,
                None,
                Some((
                    &[("us", ""), ("de", "nodeadkeys")],
                    &["compose:menu"],
                    450,
                    30,
                )),
            ))
            .unwrap();
        bridge
            .handle(&touchpad_settings_request(45, 9, false, true, 2.5))
            .unwrap();
        bridge
            .handle(&settings_request(
                fb::SettingsRequestKind::ReadInputDevices,
                44,
                0,
                None,
                None,
            ))
            .unwrap();
        assert_eq!(
            bridge.drain_settings_commands().collect::<Vec<_>>(),
            vec![
                SettingsCommand::ReadDocument { request_id: 41 },
                SettingsCommand::WriteDocument {
                    request_id: 42,
                    expected_revision: 7,
                    document: r#"{"version":9}"#.to_owned(),
                },
                SettingsCommand::ConfigureKeyboard {
                    request_id: 43,
                    expected_revision: 8,
                    keyboard: KeyboardSettings {
                        layouts: vec![
                            KeyboardLayout {
                                layout: "us".to_owned(),
                                variant: String::new(),
                            },
                            KeyboardLayout {
                                layout: "de".to_owned(),
                                variant: "nodeadkeys".to_owned(),
                            },
                        ],
                        options: vec!["compose:menu".to_owned()],
                        repeat_delay_ms: 450,
                        repeat_rate_hz: 30,
                    },
                },
                SettingsCommand::ConfigureTouchpad {
                    request_id: 45,
                    expected_revision: 9,
                    touchpad: TouchpadSettings {
                        tap_to_click_enabled: false,
                        natural_scroll_enabled: true,
                        scroll_speed_factor: 2.5,
                    },
                },
                SettingsCommand::ReadInputDevices { request_id: 44 },
            ]
        );

        for request in [
            settings_request(fb::SettingsRequestKind::ReadKeyboard, 0, 0, None, None),
            settings_request(
                fb::SettingsRequestKind::WriteDocument,
                44,
                0,
                Some("{}"),
                None,
            ),
            settings_request(
                fb::SettingsRequestKind::ConfigureKeyboard,
                45,
                9,
                None,
                Some((&[("not,a,layout", "")], &[], 600, 25)),
            ),
        ] {
            assert!(bridge.handle(&request).is_err());
        }
    }

    #[test]
    fn settings_responses_preserve_document_and_keyboard_metadata() {
        let mut bridge = bridge();
        let bytes = bridge
            .encode_settings_document_response(51, 9, Some("{\n  \"version\": 8\n}\n"), None)
            .unwrap();
        let envelope = fb::root_as_envelope(bytes).unwrap();
        let response = envelope.payload_as_settings_response().unwrap();
        assert_eq!(envelope.request_id(), 51);
        assert_eq!(response.kind(), fb::SettingsResponseKind::Document);
        assert!(response.success());
        assert_eq!(response.revision(), 9);
        assert_eq!(response.document(), Some("{\n  \"version\": 8\n}\n"));

        let keyboard = KeyboardSettings {
            layouts: vec![
                KeyboardLayout {
                    layout: "us".to_owned(),
                    variant: String::new(),
                },
                KeyboardLayout {
                    layout: "de".to_owned(),
                    variant: "nodeadkeys".to_owned(),
                },
            ],
            options: vec!["compose:menu".to_owned()],
            repeat_delay_ms: 450,
            repeat_rate_hz: 30,
        };
        let bytes = bridge
            .encode_keyboard_settings_response(
                52,
                10,
                &keyboard,
                &["English (US)".to_owned(), "German".to_owned()],
                1,
                Some("revision conflict"),
            )
            .unwrap();
        let envelope = fb::root_as_envelope(bytes).unwrap();
        let response = envelope.payload_as_settings_response().unwrap();
        let encoded = response.keyboard().unwrap();
        assert!(!response.success());
        assert_eq!(response.error(), Some("revision conflict"));
        assert_eq!(encoded.active_layout(), 1);
        assert_eq!(encoded.repeat_delay_ms(), 450);
        assert_eq!(encoded.repeat_rate_hz(), 30);
        let layouts = encoded.layouts().unwrap();
        assert_eq!(layouts.get(1).layout(), Some("de"));
        assert_eq!(layouts.get(1).variant(), Some("nodeadkeys"));
        assert_eq!(layouts.get(1).display_name(), Some("German"));
        assert_eq!(encoded.options().unwrap().get(0), "compose:menu");

        let bytes = bridge
            .encode_input_device_capabilities_response(
                0,
                11,
                true,
                &TouchpadSettings {
                    tap_to_click_enabled: false,
                    natural_scroll_enabled: true,
                    scroll_speed_factor: 2.5,
                },
                None,
            )
            .unwrap();
        let envelope = fb::root_as_envelope(bytes).unwrap();
        let response = envelope.payload_as_settings_response().unwrap();
        assert_eq!(envelope.request_id(), 0);
        assert_eq!(response.kind(), fb::SettingsResponseKind::InputDevices);
        assert!(response.success());
        assert_eq!(response.revision(), 11);
        let input_devices = response.input_devices().unwrap();
        assert!(input_devices.has_touchpad());
        let touchpad = input_devices.touchpad().unwrap();
        assert!(!touchpad.tap_to_click_enabled());
        assert!(touchpad.natural_scroll_enabled());
        assert_eq!(touchpad.scroll_speed_factor(), 2.5);
    }

    #[test]
    fn enforces_message_collection_and_command_queue_limits() {
        let mut bridge = bridge();
        assert!(matches!(
            bridge.handle(&vec![0; MAX_MESSAGE_BYTES + 1]),
            Err(WireError::Size(size)) if size == MAX_MESSAGE_BYTES + 1
        ));

        let rect = fb::WireRect::new(0.0, 0.0, 1.0, 1.0);
        let shell_regions = vec![rect; MAX_REGIONS + 1];
        assert!(matches!(
            bridge.handle(&input_layout(&shell_regions, &[], 0)),
            Err(WireError::Count)
        ));

        bridge.pending_window_commands =
            vec![WindowCommand::Close { window_id: 1 }; MAX_PENDING_WINDOW_COMMANDS]
                .into_iter()
                .collect();
        assert!(matches!(
            bridge.handle(&window_request(
                fb::WindowRequestKind::CloseWindow,
                0,
                1,
                None,
            )),
            Err(WireError::Count)
        ));

        bridge.pending_keyboard_commands =
            vec![KeyboardCommand::Text("a".into()); MAX_PENDING_KEYBOARD_COMMANDS]
                .into_iter()
                .collect();
        assert!(matches!(
            bridge.handle(&keyboard_command(
                fb::KeyboardCommandKind::Text,
                Some("a"),
                None,
                0,
            )),
            Err(WireError::Count)
        ));

        bridge.pending_notification_commands =
            vec![
                NotificationCommand::Dismiss { notification_id: 1 };
                MAX_PENDING_NOTIFICATION_COMMANDS
            ]
            .into_iter()
            .collect();
        assert!(matches!(
            bridge.handle(&notification_command(
                fb::DesktopNotificationCommandKind::Dismiss,
                1,
                None,
            )),
            Err(WireError::Count)
        ));
    }

    #[test]
    fn encodes_notification_events_for_flutter() {
        let mut bridge = bridge();
        let notification = Notification {
            id: 17,
            sender: ":1.42".into(),
            app_name: "Mail".into(),
            app_icon: "mail-unread".into(),
            summary: "New message".into(),
            body: "Hello".into(),
            actions: vec![super::super::notification_server::NotificationAction {
                key: "default".into(),
                label: "Open".into(),
            }],
            urgency: NotificationUrgency::Normal,
            category: "email.arrived".into(),
            desktop_entry: "mail".into(),
            image_path: String::new(),
            image_data: None,
            resident: true,
            transient: false,
            suppress_sound: true,
            action_icons: false,
            sound_name: String::new(),
            sound_file: String::new(),
            x: 12,
            y: 24,
            has_position: true,
            progress: 50,
            has_progress: true,
            expire_timeout_ms: 7000,
        };
        let event = NotificationEvent {
            kind: NotificationEventKind::Added,
            notification: Some(notification),
            notification_id: 17,
            close_reason: 0,
        };
        let envelope =
            fb::root_as_envelope(bridge.encode_notification_event(&event).unwrap()).unwrap();
        let encoded = envelope.payload_as_desktop_notification_event().unwrap();
        let value = encoded.notification().unwrap();
        assert_eq!(
            envelope.payload_type(),
            fb::Payload::DesktopNotificationEvent
        );
        assert_eq!(encoded.kind(), fb::DesktopNotificationEventKind::Added);
        assert_eq!(encoded.notification_id(), 17);
        assert_eq!(value.summary(), Some("New message"));
        assert_eq!(value.actions().unwrap().get(0).key(), Some("default"));
        assert_eq!(value.progress(), 50);
        assert!(value.has_progress());

        let closed = NotificationEvent {
            kind: NotificationEventKind::Closed,
            notification: None,
            notification_id: 17,
            close_reason: 2,
        };
        let envelope =
            fb::root_as_envelope(bridge.encode_notification_event(&closed).unwrap()).unwrap();
        let encoded = envelope.payload_as_desktop_notification_event().unwrap();
        assert_eq!(encoded.kind(), fb::DesktopNotificationEventKind::Closed);
        assert!(encoded.notification().is_none());
        assert_eq!(encoded.close_reason(), 2);
    }

    #[test]
    fn encodes_window_management_events_for_flutter() {
        let mut bridge = bridge();
        let bytes = bridge
            .encode_window_action(77, WindowAction::ToggleFullscreen)
            .unwrap();
        let envelope = fb::root_as_envelope(bytes).unwrap();
        let event = envelope.payload_as_window_event().unwrap();
        assert_eq!(envelope.sequence(), 1);
        assert_eq!(envelope.request_id(), 0);
        assert_eq!(event.kind(), fb::WindowEventKind::Action);
        assert_eq!(event.window_id(), 77);
        assert_eq!(event.action(), fb::WindowActionKind::ToggleFullscreen);

        let bytes = bridge.encode_window_activated(78).unwrap();
        let envelope = fb::root_as_envelope(bytes).unwrap();
        let event = envelope.payload_as_window_event().unwrap();
        assert_eq!(envelope.sequence(), 2);
        assert_eq!(event.kind(), fb::WindowEventKind::Activated);
        assert_eq!(event.window_id(), 78);

        let bytes = bridge
            .encode_window_placement(WindowPlacement {
                window_id: 78,
                monitor_id: 4,
                workspace_id: 1,
                phase: WindowPlacementPhase::Update,
                change: WindowPlacementChange::Resize,
                geometry: WindowGeometry {
                    x: 1920.0,
                    y: 40.0,
                    width: 800.0,
                    height: 600.0,
                },
            })
            .unwrap();
        assert_eq!(bytes.len(), WINDOW_PLACEMENT_PACKET_BYTES);
        assert_eq!(&bytes[0..4], b"DENP");
        assert_eq!(u64::from_le_bytes(bytes[12..20].try_into().unwrap()), 3);
        assert_eq!(u64::from_le_bytes(bytes[20..28].try_into().unwrap()), 78);
        assert_eq!(i64::from_le_bytes(bytes[28..36].try_into().unwrap()), 4);
        assert_eq!(bytes[44], WindowPlacementPhase::Update as u8);
        assert_eq!(bytes[45], WindowPlacementChange::Resize as u8);
        assert_eq!(f64::from_le_bytes(bytes[64..72].try_into().unwrap()), 800.0);
    }

    #[test]
    fn outbound_flatbuffer_storage_is_reused_between_synchronous_sends() {
        let mut bridge = bridge();
        let (first_pointer, first_len) = {
            let bytes = bridge.encode_window_activated(71).unwrap();
            (bytes.as_ptr(), bytes.len())
        };
        let bytes = bridge.encode_window_activated(71).unwrap();
        assert_eq!(bytes.len(), first_len);
        assert_eq!(bytes.as_ptr(), first_pointer);
    }

    #[test]
    fn encodes_shell_actions_with_optional_monitor_and_ordered_sequence() {
        let mut bridge = bridge();

        let bytes = bridge
            .encode_shell_action(ShellAction::Applications, None)
            .unwrap();
        let envelope = fb::root_as_envelope(bytes).unwrap();
        let action = envelope.payload_as_shell_action().unwrap();
        assert_eq!(envelope.protocol_version(), PROTOCOL_VERSION);
        assert_eq!(envelope.sequence(), 1);
        assert_eq!(envelope.request_id(), 0);
        assert_eq!(envelope.payload_type(), fb::Payload::ShellAction);
        assert_eq!(action.action(), fb::ShellActionKind::Applications);
        assert!(!action.has_monitor_id());
        assert_eq!(action.monitor_id(), -1);

        let bytes = bridge
            .encode_shell_action(ShellAction::Overview, Some(9))
            .unwrap();
        let envelope = fb::root_as_envelope(bytes).unwrap();
        let action = envelope.payload_as_shell_action().unwrap();
        assert_eq!(envelope.sequence(), 2);
        assert_eq!(envelope.request_id(), 0);
        assert_eq!(envelope.payload_type(), fb::Payload::ShellAction);
        assert_eq!(action.action(), fb::ShellActionKind::Overview);
        assert!(action.has_monitor_id());
        assert_eq!(action.monitor_id(), 9);

        let bytes = bridge
            .encode_shell_action(ShellAction::ScreenshotRegion, None)
            .unwrap();
        let envelope = fb::root_as_envelope(bytes).unwrap();
        let action = envelope.payload_as_shell_action().unwrap();
        assert_eq!(envelope.sequence(), 3);
        assert_eq!(action.action(), fb::ShellActionKind::ScreenshotRegion);
        assert!(!action.has_monitor_id());
    }

    #[test]
    fn screenshot_actions_carry_the_workflow_identity_and_texture() {
        let mut bridge = bridge();
        let bytes = bridge
            .encode_screenshot_action(ShellAction::ScreenshotTextureReady, 41, Some(9001))
            .unwrap();
        let envelope = fb::root_as_envelope(bytes).unwrap();
        let action = envelope.payload_as_shell_action().unwrap();
        assert_eq!(envelope.request_id(), 41);
        assert_eq!(action.action(), fb::ShellActionKind::ScreenshotTextureReady);
        assert_eq!(action.texture_id(), 9001);

        assert!(
            bridge
                .encode_screenshot_action(ShellAction::ScreenshotTextureReady, 41, None)
                .is_err()
        );
        assert!(
            bridge
                .encode_screenshot_action(ShellAction::ScreenshotDone, 0, None)
                .is_err()
        );
    }

    #[test]
    fn encodes_cursor_shapes_and_rejects_invalid_values_without_sequence_gaps() {
        let mut bridge = bridge();
        let oversized = "x".repeat(MAX_STRING_BYTES + 1);

        assert!(matches!(
            bridge.encode_cursor_shape(" \t\n "),
            Err(WireError::String)
        ));
        assert!(matches!(
            bridge.encode_cursor_shape(&oversized),
            Err(WireError::String)
        ));

        let bytes = bridge.encode_cursor_shape("  text  ").unwrap();
        let envelope = fb::root_as_envelope(bytes).unwrap();
        let cursor = envelope.payload_as_cursor_shape().unwrap();
        assert_eq!(envelope.protocol_version(), PROTOCOL_VERSION);
        assert_eq!(envelope.sequence(), 1);
        assert_eq!(envelope.request_id(), 0);
        assert_eq!(envelope.payload_type(), fb::Payload::CursorShape);
        assert_eq!(cursor.shape(), Some("text"));

        let bytes = bridge.encode_cursor_shape("pointer").unwrap();
        let envelope = fb::root_as_envelope(bytes).unwrap();
        assert_eq!(envelope.sequence(), 2);
        assert_eq!(
            envelope.payload_as_cursor_shape().unwrap().shape(),
            Some("pointer")
        );
    }

    #[test]
    fn encodes_finite_cursor_positions_without_consuming_rejected_sequences() {
        let mut bridge = bridge();

        assert!(matches!(
            bridge.encode_cursor_position(f64::NAN, 4.0),
            Err(WireError::Geometry)
        ));
        assert!(matches!(
            bridge.encode_cursor_position(4.0, f64::INFINITY),
            Err(WireError::Geometry)
        ));

        let bytes = bridge.encode_cursor_position(713.25, 419.75).unwrap();
        let envelope = fb::root_as_envelope(bytes).unwrap();
        let cursor = envelope.payload_as_cursor_position().unwrap();
        assert_eq!(envelope.protocol_version(), PROTOCOL_VERSION);
        assert_eq!(envelope.sequence(), 1);
        assert_eq!(envelope.request_id(), 0);
        assert_eq!(envelope.payload_type(), fb::Payload::CursorPosition);
        assert_eq!(cursor.x(), 713.25);
        assert_eq!(cursor.y(), 419.75);
    }

    #[test]
    fn encodes_native_text_input_state_and_rejects_impossible_visibility() {
        let mut bridge = bridge();

        assert!(matches!(
            bridge.encode_text_input_state(false, true, false, 0, 0),
            Err(WireError::Payload)
        ));

        let bytes = bridge
            .encode_text_input_state(true, true, true, 3, 6)
            .unwrap();
        let envelope = fb::root_as_envelope(bytes).unwrap();
        let state = envelope.payload_as_text_input_state().unwrap();
        assert_eq!(envelope.protocol_version(), PROTOCOL_VERSION);
        assert_eq!(envelope.sequence(), 1);
        assert_eq!(envelope.request_id(), 0);
        assert_eq!(envelope.payload_type(), fb::Payload::TextInputState);
        assert!(state.active());
        assert!(state.input_panel_visible());
        assert!(state.legacy());
        assert_eq!(state.content_hint(), 3);
        assert_eq!(state.content_purpose(), 6);
    }

    #[test]
    fn accepts_dart_input_layout_goldens_with_strict_alignment() {
        let mut bridge = bridge();
        for (bytes, expected_count, expected_flags) in [
            (
                include_bytes!(concat!(
                    env!("CARGO_MANIFEST_DIR"),
                    "/../protocol/golden/dart_input_empty.denw"
                ))
                .as_slice(),
                0,
                0,
            ),
            (
                include_bytes!(concat!(
                    env!("CARGO_MANIFEST_DIR"),
                    "/../protocol/golden/dart_input_one.denw"
                ))
                .as_slice(),
                1,
                INPUT_LAYOUT_KEYBOARD_CAPTURE,
            ),
            (
                include_bytes!(concat!(
                    env!("CARGO_MANIFEST_DIR"),
                    "/../protocol/golden/dart_input_eight.denw"
                ))
                .as_slice(),
                8,
                0,
            ),
            (
                include_bytes!(concat!(
                    env!("CARGO_MANIFEST_DIR"),
                    "/../protocol/golden/dart_input_many.denw"
                ))
                .as_slice(),
                32,
                INPUT_LAYOUT_EXCLUSIVE_SHELL,
            ),
        ] {
            assert!(bridge.handle(bytes).unwrap().is_none());
            let layout = bridge.take_input_layout_update().unwrap();
            assert_eq!(layout.windows.len(), expected_count);
            assert_eq!(layout.flags, expected_flags);
            if let Some(window) = layout.windows.first() {
                assert!(window.visible());
                assert!(window.rect.contains(window.rect.x, window.rect.y));
                assert_eq!(
                    window
                        .rect
                        .map_to(window.source_rect, window.rect.x, window.rect.y),
                    (window.source_rect.x, window.source_rect.y)
                );
            }
        }
    }

    #[test]
    fn accepts_dart_system_bar_golden_with_strict_alignment() {
        let mut bridge = bridge();
        let bytes = include_bytes!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../protocol/golden/dart_system_bar.denw"
        ));
        let response = bridge.handle(bytes).unwrap().unwrap();
        let envelope = fb::root_as_envelope(response).unwrap();
        assert_eq!(envelope.request_id(), 41);
        let layout = envelope
            .payload_as_window_response()
            .unwrap()
            .display_layout()
            .unwrap();
        assert_eq!(layout.system_bar_side(), fb::SystemBarSide::Right);
        assert_eq!(
            layout
                .system_bar_monitor_ids()
                .unwrap()
                .iter()
                .collect::<Vec<_>>(),
            vec![7, 9]
        );
        let update = bridge.take_work_area_update().unwrap();
        assert_eq!(update.system_bar.outputs, vec!["left", "main"]);
    }

    #[test]
    fn input_layout_decode_reuses_frontend_storage() {
        let rect = fb::WireRect::new(10.0, 20.0, 300.0, 200.0);
        let window = fb::InputWindowRegion::new(1, 11, 1, &rect, &rect, 0, INPUT_WINDOW_VISIBLE);
        let bytes = input_layout_with_visible(&[rect], &[window], &[11], 0);
        let mut bridge = bridge();

        bridge.handle(&bytes).unwrap();
        let layout = bridge.take_input_layout_update().unwrap();
        let shell_storage = layout.shell_regions.as_ptr();
        let window_storage = layout.windows.as_ptr();
        let visible_storage = layout.visible_surface_ids.as_ptr();
        bridge.recycle_input_layout(layout);

        bridge.handle(&bytes).unwrap();
        let layout = bridge.take_input_layout_update().unwrap();
        assert_eq!(layout.shell_regions.as_ptr(), shell_storage);
        assert_eq!(layout.windows.as_ptr(), window_storage);
        assert_eq!(layout.visible_surface_ids.as_ptr(), visible_storage);
    }

    #[test]
    fn validates_owned_input_geometry_identity_and_ordering() {
        let rect = fb::WireRect::new(10.0, 20.0, 0.25, 0.5);
        let top = fb::InputWindowRegion::new(1, 11, 21, &rect, &rect, 3, u32::MAX);
        let lower = fb::InputWindowRegion::new(2, 12, 22, &rect, &rect, 2, INPUT_WINDOW_VISIBLE);
        let mut bridge = bridge();
        bridge
            .handle(&input_layout(&[rect], &[top, lower], u32::MAX))
            .unwrap();
        let layout = bridge.take_input_layout_update().unwrap();
        assert_eq!(layout.epoch, 7);
        assert_eq!(layout.windows.len(), 2);
        assert!(!layout.windows[0].hit_test_enabled());
        assert!(layout.windows[0].geometry_locked());
        assert!(!layout.windows[1].geometry_locked());

        let reversed = input_layout(&[], &[lower, top], 0);
        assert!(matches!(bridge.handle(&reversed), Err(WireError::Ordering)));

        let empty = fb::WireRect::new(0.0, 0.0, 0.0, 1.0);
        assert!(matches!(
            bridge.handle(&input_layout(&[empty], &[], 0)),
            Err(WireError::Geometry)
        ));

        let unidentified = fb::InputWindowRegion::new(0, 11, 21, &rect, &rect, 0, 0);
        assert!(matches!(
            bridge.handle(&input_layout(&[], &[unidentified], 0)),
            Err(WireError::Identity)
        ));

        let duplicate_surface = fb::InputWindowRegion::new(2, 11, 22, &rect, &rect, 2, 0);
        assert!(matches!(
            bridge.handle(&input_layout(&[], &[top, duplicate_surface], 0)),
            Err(WireError::Identity)
        ));
        assert!(matches!(
            bridge.handle(&input_layout_with_visible(&[], &[], &[11, 11], 0)),
            Err(WireError::Identity)
        ));

        // Input routing intentionally accepts every finite positive rect,
        // including one whose mathematical far edge is outside f64. The
        // routing helpers must still avoid integer overflow or panics.
        let extreme_extent = fb::WireRect::new(f64::MAX, 0.0, f64::MAX, 1.0);
        bridge
            .handle(&input_layout(&[extreme_extent], &[], 0))
            .unwrap();
        let extreme = bridge.take_input_layout_update().unwrap().shell_regions[0];
        assert!(extreme.contains(f64::MAX, 0.0));
        assert_eq!(extreme.map_to(extreme, f64::MAX, 0.0), (f64::MAX, 0.0));
        let wide = InputRect {
            x: 0.0,
            y: 0.0,
            width: f64::MAX,
            height: 1.0,
        };
        assert_eq!(wide.map_to(wide, f64::MAX / 2.0, 0.0).0, f64::MAX / 2.0);
    }

    #[test]
    fn malformed_truncated_and_mutated_corpus_never_panics() {
        fn exercise(bytes: &[u8]) {
            let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                let mut bridge = bridge();
                bridge
                    .handle(bytes)
                    .map(|response| response.map(<[u8]>::len))
            }));
            match outcome {
                Ok(Ok(Some(response_len))) => assert!(response_len <= MAX_MESSAGE_BYTES),
                Ok(_) => {}
                Err(_) => panic!("wire handler panicked for {} input bytes", bytes.len()),
            }
        }

        let seeds = [
            request(fb::WindowRequestKind::ListWindows, 41),
            input_layout(&[fb::WireRect::new(0.0, 0.0, 10.0, 10.0)], &[], 0),
            keyboard_command(fb::KeyboardCommandKind::Text, Some("corpus"), None, 0),
        ];
        for seed in &seeds {
            for end in 0..seed.len() {
                exercise(&seed[..end]);
            }
            for index in 0..seed.len() {
                let mut mutated = seed.clone();
                mutated[index] ^= 0xa5;
                exercise(&mutated);
            }
        }

        let mut state = 0x4d59_5df4_d0f3_3173_u64;
        for case in 0..256_usize {
            let len = (state as usize ^ case.wrapping_mul(131)) % 2048;
            let mut bytes = vec![0_u8; len];
            for byte in &mut bytes {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                *byte = state as u8;
            }
            if case % 2 == 0 && bytes.len() >= 8 {
                bytes[4..8].copy_from_slice(b"DENW");
            }
            exercise(&bytes);
        }
    }
}
