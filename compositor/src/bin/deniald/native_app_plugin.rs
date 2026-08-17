//! Product-neutral runtime plugin boundary for native application sources.
//!
//! Plugins publish independent application windows rendered into DMA-BUFs
//! allocated and lent by Denial.
//! Denial remains authoritative for window policy, input routing, composition,
//! and release timing. The boundary is a versioned C ABI so plugins can be
//! shipped independently of Denial and never rely on Rust ABI compatibility.

use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::env;
use std::error::Error;
use std::ffi::{c_char, c_void};
use std::fs;
use std::os::fd::{AsRawFd, BorrowedFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::slice;
use std::sync::Arc;
use std::sync::atomic::{AtomicU8, Ordering};

use libloading::Library;
use smithay::backend::allocator::dmabuf::{AsDmabuf, Dmabuf};
use smithay::backend::allocator::gbm::{GbmAllocator, GbmBuffer};
use smithay::backend::allocator::{Allocator, Buffer as AllocatorBuffer, Fourcc, Modifier};
use smithay::backend::drm::DrmDeviceFd;
use smithay::reexports::calloop::channel::Sender;
use tracing::{info, warn};

use super::flutter_runtime::ExternalTextureFrame;
use super::wire::{
    self, SurfaceLayerDescription, SurfaceRoleDescription, WindowContentKind, WindowDescription,
    WindowOpacityClass,
};

pub(super) const ABI_MAJOR: u32 = 1;
pub(super) const ABI_MINOR: u32 = 2;
pub(super) const MAX_PLANES: usize = 4;
pub(super) const MAX_FORMATS: usize = 256;
pub(super) const MAX_PLUGIN_STRING_BYTES: usize = 4096;
pub(super) const MAX_PLUGIN_EVENTS_PER_DISPATCH: usize = 256;
pub(super) const MAX_NATIVE_WINDOWS: usize = 4096;
pub(super) const MAX_PENDING_NATIVE_FRAMES: usize = 4096;
pub(super) const MAX_NATIVE_PLUGINS: usize = 16;
const NATIVE_RENDER_TARGET_POOL_LENGTH: usize = 3;
const ENTRY_SYMBOL: &[u8] = b"denial_native_app_plugin_v1\0";
const PLUGIN_PATH_ENV: &str = "DENIAL_NATIVE_APP_PLUGINS";
const PLUGIN_ID_BASE: u64 = 1_u64 << 62;
const CONTENT_OPAQUE: u32 = 1 << 0;
const CREATE_HEADLESS: u32 = 1 << 31;

pub(super) mod event_kind {
    pub(super) const CREATE_WINDOW: u32 = 1;
    pub(super) const BIND_WINDOW_IDENTITY: u32 = 2;
    pub(super) const DESTROY_WINDOW: u32 = 3;
    pub(super) const PRESENT: u32 = 6;
    pub(super) const SET_CONTENT_STATE: u32 = 7;
    pub(super) const SET_FRAME_RATE: u32 = 8;
}

pub(super) mod command_kind {
    pub(super) const CONFIGURE: u32 = 1;
    pub(super) const VISIBILITY: u32 = 2;
    pub(super) const CLOSE: u32 = 3;
    pub(super) const INPUT: u32 = 4;
    pub(super) const MATERIALIZE_RELEASE: u32 = 5;
    pub(super) const COMPLETE_RELEASE: u32 = 6;
    pub(super) const DISCARD_RELEASE: u32 = 7;
    #[allow(dead_code, reason = "reserved by ABI v1 for KMS presentation timing")]
    pub(super) const PRESENTED: u32 = 8;
    pub(super) const FORMAT_FEEDBACK: u32 = 9;
    pub(super) const REGISTER_RENDER_TARGET: u32 = 10;
    pub(super) const UNREGISTER_RENDER_TARGET: u32 = 11;
}

pub(super) mod input_kind {
    pub(super) const TOUCH: u32 = 1;
    pub(super) const KEY: u32 = 2;
}

pub(super) mod touch_action {
    pub(super) const DOWN: u32 = 0;
    pub(super) const MOTION: u32 = 1;
    pub(super) const UP: u32 = 2;
    pub(super) const CANCEL: u32 = 3;
}

pub(super) mod key_action {
    pub(super) const DOWN: u32 = 0;
    pub(super) const UP: u32 = 1;
}

/// Immutable services Denial lends to a plugin during initialization.
///
/// `drm_fd` is borrowed only for the entry-point call. A plugin that needs the
/// render device after initialization must duplicate it before returning.
#[repr(C)]
#[derive(Clone, Copy)]
pub(super) struct NativeAppHostV1 {
    pub(super) struct_size: u32,
    pub(super) abi_major: u32,
    pub(super) abi_minor: u32,
    pub(super) drm_fd: RawFd,
}

/// One plugin-owned event borrowed by Denial for the duration of `next_event`.
///
/// Nonnegative descriptors transfer to Denial when `next_event` succeeds.
/// Unused descriptor slots must be `-1`. String and damage pointers remain
/// plugin-owned and need only remain valid until `next_event` is called again.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub(super) struct NativeAppEventV1 {
    pub(super) struct_size: u32,
    pub(super) kind: u32,
    pub(super) object_id: u64,
    pub(super) identity: u64,
    pub(super) buffer_id: u64,
    pub(super) frame_id: u64,
    pub(super) serial: u64,
    pub(super) flags: u32,
    pub(super) width: u32,
    pub(super) height: u32,
    pub(super) format: u32,
    pub(super) plane_count: u32,
    pub(super) modifier: u64,
    pub(super) plane_fds: [RawFd; MAX_PLANES],
    pub(super) plane_offsets: [u32; MAX_PLANES],
    pub(super) plane_strides: [u32; MAX_PLANES],
    pub(super) acquire_fence_fd: RawFd,
    pub(super) text_ptr: *const u8,
    pub(super) text_len: usize,
    pub(super) app_id_ptr: *const u8,
    pub(super) app_id_len: usize,
    pub(super) damage_ptr: *const NativeAppDamageV1,
    pub(super) damage_count: usize,
}

impl Default for NativeAppEventV1 {
    fn default() -> Self {
        Self {
            struct_size: u32::try_from(std::mem::size_of::<Self>()).unwrap_or(u32::MAX),
            kind: 0,
            object_id: 0,
            identity: 0,
            buffer_id: 0,
            frame_id: 0,
            serial: 0,
            flags: 0,
            width: 0,
            height: 0,
            format: 0,
            plane_count: 0,
            modifier: 0,
            plane_fds: [-1; MAX_PLANES],
            plane_offsets: [0; MAX_PLANES],
            plane_strides: [0; MAX_PLANES],
            acquire_fence_fd: -1,
            text_ptr: std::ptr::null(),
            text_len: 0,
            app_id_ptr: std::ptr::null(),
            app_id_len: 0,
            damage_ptr: std::ptr::null(),
            damage_count: 0,
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct NativeAppDamageV1 {
    pub(super) x: u32,
    pub(super) y: u32,
    pub(super) width: u32,
    pub(super) height: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct NativeAppFormatV1 {
    pub(super) format: u32,
    pub(super) modifier: u64,
}

/// One synchronous Denial-to-plugin command.
///
/// Any descriptor is borrowed for the duration of the callback. Plugins must
/// duplicate descriptors they retain after returning.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub(super) struct NativeAppCommandV1 {
    pub(super) struct_size: u32,
    pub(super) kind: u32,
    pub(super) object_id: u64,
    pub(super) frame_id: u64,
    pub(super) serial: u64,
    pub(super) timestamp_nanos: u64,
    pub(super) refresh_period_nanos: u64,
    pub(super) sequence: u64,
    pub(super) flags: u32,
    pub(super) width: u32,
    pub(super) height: u32,
    pub(super) scale_numerator: u32,
    pub(super) scale_denominator: u32,
    pub(super) transform: u32,
    pub(super) refresh_millihz: u32,
    pub(super) focused: u32,
    pub(super) descriptor: RawFd,
    pub(super) input_kind: u32,
    pub(super) input_action: u32,
    pub(super) input_code: u32,
    pub(super) input_x_fixed: i32,
    pub(super) input_y_fixed: i32,
    pub(super) input_value: u32,
    pub(super) formats_ptr: *const NativeAppFormatV1,
    pub(super) format_count: usize,
    pub(super) buffer_id: u64,
    pub(super) format: u32,
    pub(super) plane_count: u32,
    pub(super) modifier: u64,
    pub(super) plane_fds: [RawFd; MAX_PLANES],
    pub(super) plane_offsets: [u32; MAX_PLANES],
    pub(super) plane_strides: [u32; MAX_PLANES],
}

impl NativeAppCommandV1 {
    pub(super) fn new(kind: u32, object_id: u64) -> Self {
        Self {
            struct_size: u32::try_from(std::mem::size_of::<Self>()).unwrap_or(u32::MAX),
            kind,
            object_id,
            frame_id: 0,
            serial: 0,
            timestamp_nanos: 0,
            refresh_period_nanos: 0,
            sequence: 0,
            flags: 0,
            width: 0,
            height: 0,
            scale_numerator: 1,
            scale_denominator: 1,
            transform: 0,
            refresh_millihz: 0,
            focused: 0,
            descriptor: -1,
            input_kind: 0,
            input_action: 0,
            input_code: 0,
            input_x_fixed: 0,
            input_y_fixed: 0,
            input_value: 0,
            formats_ptr: std::ptr::null(),
            format_count: 0,
            buffer_id: 0,
            format: 0,
            plane_count: 0,
            modifier: 0,
            plane_fds: [-1; MAX_PLANES],
            plane_offsets: [0; MAX_PLANES],
            plane_strides: [0; MAX_PLANES],
        }
    }
}

type NextEventFn = unsafe extern "C" fn(*mut c_void, *mut NativeAppEventV1) -> i32;
type CommandFn = unsafe extern "C" fn(*mut c_void, *const NativeAppCommandV1) -> i32;
type ShutdownFn = unsafe extern "C" fn(*mut c_void);

/// Function table returned by a plugin entry point.
#[repr(C)]
#[derive(Clone, Copy)]
pub(super) struct NativeAppPluginV1 {
    pub(super) struct_size: u32,
    pub(super) abi_major: u32,
    pub(super) abi_minor: u32,
    pub(super) name_ptr: *const c_char,
    pub(super) name_len: usize,
    pub(super) context: *mut c_void,
    pub(super) poll_fd: RawFd,
    pub(super) next_event: Option<NextEventFn>,
    pub(super) command: Option<CommandFn>,
    pub(super) shutdown: Option<ShutdownFn>,
}

impl Default for NativeAppPluginV1 {
    fn default() -> Self {
        Self {
            struct_size: u32::try_from(std::mem::size_of::<Self>()).unwrap_or(u32::MAX),
            abi_major: 0,
            abi_minor: 0,
            name_ptr: std::ptr::null(),
            name_len: 0,
            context: std::ptr::null_mut(),
            poll_fd: -1,
            next_event: None,
            command: None,
            shutdown: None,
        }
    }
}

type EntryFn = unsafe extern "C" fn(*const NativeAppHostV1, *mut NativeAppPluginV1) -> i32;

#[derive(Debug)]
pub(super) enum NativePluginAction {
    CreateWindow {
        plugin: usize,
        object: u64,
        title: String,
        app_id: String,
        width_hint: u32,
        height_hint: u32,
        flags: u32,
    },
    BindWindowIdentity {
        plugin: usize,
        object: u64,
        identity: u64,
    },
    DestroyWindow {
        plugin: usize,
        object: u64,
    },
    Present {
        plugin: usize,
        object: u64,
        buffer: u64,
        frame: u64,
        serial: u64,
        flags: u32,
        damage: Vec<NativeAppDamageV1>,
        acquire_fence: OwnedFd,
    },
    SetContentState {
        plugin: usize,
        object: u64,
        flags: u32,
    },
    SetFrameRate {
        plugin: usize,
        object: u64,
        millihertz: u32,
    },
}

#[derive(Debug)]
pub(super) enum NativeReleaseCommand {
    Materialize {
        plugin: usize,
        object: u64,
        frame: u64,
        fence: OwnedFd,
    },
    Complete {
        plugin: usize,
        object: u64,
        frame: u64,
    },
    Discard {
        plugin: usize,
        object: u64,
        frame: u64,
    },
}

#[derive(Clone, Debug)]
pub(super) struct NativeBufferRelease {
    inner: Arc<NativeBufferReleaseInner>,
}

#[derive(Debug)]
struct NativeBufferReleaseInner {
    sender: Sender<NativeReleaseCommand>,
    plugin: usize,
    object: u64,
    frame: u64,
    state: AtomicU8,
}

impl NativeBufferRelease {
    const PENDING: u8 = 0;
    const MATERIALIZED: u8 = 1;
    const TERMINAL: u8 = 2;

    pub(super) fn new(
        sender: Sender<NativeReleaseCommand>,
        plugin: usize,
        object: u64,
        frame: u64,
    ) -> Self {
        Self {
            inner: Arc::new(NativeBufferReleaseInner {
                sender,
                plugin,
                object,
                frame,
                state: AtomicU8::new(Self::PENDING),
            }),
        }
    }

    pub(super) fn materialize(&self, fence: BorrowedFd<'_>) -> Result<(), Box<dyn Error>> {
        self.inner
            .state
            .compare_exchange(
                Self::PENDING,
                Self::MATERIALIZED,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .map_err(|_| "native plugin release was materialized more than once")?;
        let fence = match fence.try_clone_to_owned() {
            Ok(fence) => fence,
            Err(error) => {
                self.inner.state.store(Self::PENDING, Ordering::Release);
                return Err(error.into());
            }
        };
        if self
            .inner
            .sender
            .send(NativeReleaseCommand::Materialize {
                plugin: self.inner.plugin,
                object: self.inner.object,
                frame: self.inner.frame,
                fence,
            })
            .is_err()
        {
            self.inner.state.store(Self::PENDING, Ordering::Release);
            return Err("native plugin release channel is closed".into());
        }
        Ok(())
    }

    pub(super) fn complete(&self) -> Result<(), Box<dyn Error>> {
        self.inner
            .state
            .compare_exchange(
                Self::MATERIALIZED,
                Self::TERMINAL,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .map_err(|_| "native plugin release completed before materialization")?;
        self.inner
            .sender
            .send(NativeReleaseCommand::Complete {
                plugin: self.inner.plugin,
                object: self.inner.object,
                frame: self.inner.frame,
            })
            .map_err(|_| "native plugin release channel is closed".into())
    }

    pub(super) fn complete_without_fence(&self) -> Result<(), Box<dyn Error>> {
        self.inner
            .state
            .compare_exchange(
                Self::PENDING,
                Self::TERMINAL,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .map_err(|_| "native plugin release has invalid fence-free completion state")?;
        self.inner
            .sender
            .send(NativeReleaseCommand::Discard {
                plugin: self.inner.plugin,
                object: self.inner.object,
                frame: self.inner.frame,
            })
            .map_err(|_| "native plugin release channel is closed".into())
    }
}

impl Drop for NativeBufferReleaseInner {
    fn drop(&mut self) {
        if self
            .state
            .swap(NativeBufferRelease::TERMINAL, Ordering::AcqRel)
            == NativeBufferRelease::TERMINAL
        {
            return;
        }
        let _ = self.sender.send(NativeReleaseCommand::Discard {
            plugin: self.plugin,
            object: self.object,
            frame: self.frame,
        });
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(super) struct NativeFrameKey {
    plugin: usize,
    object: u64,
    frame: u64,
}

#[derive(Debug)]
pub(super) struct NativeAcquireWatch {
    pub(super) key: NativeFrameKey,
    pub(super) fence: OwnedFd,
}

struct PendingNativeFrame {
    dmabuf: Dmabuf,
    release: NativeBufferRelease,
}

struct CurrentNativeFrame {
    frame: u64,
    dmabuf: Dmabuf,
    release: NativeBufferRelease,
}

struct NativeRenderTarget {
    dmabuf: Dmabuf,
    configure_serial: u64,
    retired: bool,
    _allocation: GbmBuffer,
}

struct NativeWindow {
    plugin: usize,
    object: u64,
    external_identity: Option<u64>,
    host_id: u64,
    title: String,
    app_id: String,
    width: u32,
    height: u32,
    x: f64,
    y: f64,
    configure_serial: u64,
    headless: bool,
    content_flags: u32,
    frame_rate_millihertz: u32,
    visible: bool,
    focused: bool,
    render_targets: BTreeMap<u64, NativeRenderTarget>,
    targets_dirty: bool,
    current: Option<CurrentNativeFrame>,
}

#[derive(Clone, Copy)]
struct NativeTouchRoute {
    plugin: usize,
    object: u64,
    host_id: u64,
    rect: wire::InputRect,
    source_rect: wire::InputRect,
    last_x_fixed: i32,
    last_y_fixed: i32,
    last_timestamp_nanos: u64,
}

#[derive(Clone, Copy)]
struct NativeKeyRoute {
    plugin: usize,
    object: u64,
    repeat: u16,
    last_timestamp_nanos: u64,
}

#[derive(Clone, Copy)]
struct NativeInputCommand {
    plugin: usize,
    object: u64,
    timestamp_nanos: u64,
    kind: u32,
    action: u32,
    code: u32,
    x_fixed: i32,
    y_fixed: i32,
    value: u32,
}

struct LoadedPlugin {
    name: String,
    table: NativeAppPluginV1,
    _library: Library,
}

impl LoadedPlugin {
    fn command(&mut self, command: &NativeAppCommandV1) -> Result<(), Box<dyn Error>> {
        let callback = self
            .table
            .command
            .ok_or("native application plugin has no command callback")?;
        // SAFETY: the table and context were returned by the live library's
        // validated entry point. `command` is borrowed for this call only.
        let status = unsafe { callback(self.table.context, command) };
        if status == 0 {
            Ok(())
        } else {
            Err(format!("plugin {} rejected command with status {status}", self.name).into())
        }
    }
}

impl Drop for LoadedPlugin {
    fn drop(&mut self) {
        if let Some(shutdown) = self.table.shutdown {
            // SAFETY: the context remains owned by this live library until
            // exactly this shutdown call; the table is never used afterward.
            unsafe { shutdown(self.table.context) };
        }
    }
}

pub(super) struct NativeAppPluginManager {
    windows: BTreeMap<u64, NativeWindow>,
    objects: HashMap<(usize, u64), u64>,
    pending_frames: HashMap<NativeFrameKey, PendingNativeFrame>,
    frame_targets: HashMap<NativeFrameKey, u64>,
    next_host_id: u64,
    next_target_id: u64,
    next_input_serial: u64,
    scale_numerator: u32,
    scale_denominator: u32,
    refresh_millihz: u32,
    scene_dirty: bool,
    input_layout: wire::InputLayoutSnapshot,
    touch_routes: HashMap<i32, NativeTouchRoute>,
    retired_touch_slots: HashSet<i32>,
    key_routes: HashMap<u32, NativeKeyRoute>,
    retired_keys: HashSet<u32>,
    plugins: Vec<LoadedPlugin>,
}

impl NativeAppPluginManager {
    pub(super) fn load_configured(
        drm_fd: BorrowedFd<'_>,
        scale_numerator: u32,
        scale_denominator: u32,
        refresh_millihz: u32,
    ) -> Result<Option<Self>, Box<dyn Error>> {
        validate_scale(scale_numerator, scale_denominator)?;
        validate_refresh(refresh_millihz)?;
        let Some(raw_paths) = env::var_os(PLUGIN_PATH_ENV) else {
            return Ok(None);
        };
        let paths = env::split_paths(&raw_paths).collect::<Vec<_>>();
        if paths.is_empty() {
            return Ok(None);
        }
        if paths.len() > MAX_NATIVE_PLUGINS {
            return Err(format!(
                "configured {} native application plugins; limit is {MAX_NATIVE_PLUGINS}",
                paths.len()
            )
            .into());
        }
        let mut plugins = Vec::with_capacity(paths.len());
        for path in paths {
            let plugin = load_plugin(&path, drm_fd)?;
            info!(plugin = plugin.name, path = %path.display(), "loaded native application plugin");
            plugins.push(plugin);
        }
        Ok(Some(Self {
            windows: BTreeMap::new(),
            objects: HashMap::new(),
            pending_frames: HashMap::new(),
            frame_targets: HashMap::new(),
            next_host_id: PLUGIN_ID_BASE,
            next_target_id: 1,
            next_input_serial: 1,
            scale_numerator,
            scale_denominator,
            refresh_millihz,
            scene_dirty: false,
            input_layout: wire::InputLayoutSnapshot::default(),
            touch_routes: HashMap::new(),
            retired_touch_slots: HashSet::new(),
            key_routes: HashMap::new(),
            retired_keys: HashSet::new(),
            plugins,
        }))
    }

    pub(super) fn poll_descriptors(&self) -> Result<Vec<(usize, OwnedFd)>, Box<dyn Error>> {
        self.plugins
            .iter()
            .enumerate()
            .map(|(index, plugin)| {
                // SAFETY: the plugin table has already validated poll_fd as a
                // nonnegative live descriptor. This borrow lasts only through
                // the descriptor duplication operation below.
                let borrowed = unsafe { BorrowedFd::borrow_raw(plugin.table.poll_fd) };
                Ok((index, borrowed.try_clone_to_owned()?))
            })
            .collect()
    }

    pub(super) fn dispatch(
        &mut self,
        plugin_index: usize,
        output: &mut VecDeque<NativePluginAction>,
    ) -> Result<(), Box<dyn Error>> {
        let plugin = self
            .plugins
            .get_mut(plugin_index)
            .ok_or("native application plugin index is stale")?;
        let next_event = plugin
            .table
            .next_event
            .ok_or("native application plugin has no event callback")?;
        for _ in 0..MAX_PLUGIN_EVENTS_PER_DISPATCH {
            let mut raw = NativeAppEventV1::default();
            // SAFETY: the plugin owns its validated context; `raw` points to
            // writable storage and all borrowed payloads are copied below
            // before the next callback invocation.
            let status = unsafe { next_event(plugin.table.context, &raw mut raw) };
            if status == 1 {
                return Ok(());
            }
            if status != 0 {
                close_event_descriptors(&mut raw);
                return Err(format!(
                    "plugin {} event callback failed with status {status}",
                    plugin.name
                )
                .into());
            }
            output.push_back(parse_event(plugin_index, &mut raw)?);
        }
        warn!(
            plugin = plugin.name,
            limit = MAX_PLUGIN_EVENTS_PER_DISPATCH,
            "native application plugin dispatch was bounded"
        );
        Ok(())
    }

    pub(super) fn command(
        &mut self,
        plugin_index: usize,
        command: &NativeAppCommandV1,
    ) -> Result<(), Box<dyn Error>> {
        self.plugins
            .get_mut(plugin_index)
            .ok_or("native application plugin index is stale")?
            .command(command)
    }

    pub(super) const fn scene_dirty(&self) -> bool {
        self.scene_dirty
    }

    pub(super) fn mark_scene_synchronized(&mut self) {
        self.scene_dirty = false;
    }

    /// Publish output scale or refresh changes through fresh configures.
    pub(super) fn set_configure_properties(
        &mut self,
        numerator: u32,
        denominator: u32,
        refresh_millihz: u32,
    ) -> Result<(), Box<dyn Error>> {
        validate_scale(numerator, denominator)?;
        validate_refresh(refresh_millihz)?;
        if (numerator, denominator, refresh_millihz)
            == (
                self.scale_numerator,
                self.scale_denominator,
                self.refresh_millihz,
            )
        {
            return Ok(());
        }
        self.scale_numerator = numerator;
        self.scale_denominator = denominator;
        self.refresh_millihz = refresh_millihz;
        for window in self.windows.values_mut() {
            window.configure_serial = window
                .configure_serial
                .checked_add(1)
                .ok_or("native plugin configure serial exhausted")?;
            window.targets_dirty = true;
        }
        Ok(())
    }

    pub(super) fn owns_window(&self, window_id: u64) -> bool {
        self.windows.contains_key(&window_id)
    }

    pub(super) fn clear_focus(&mut self) -> Result<(), Box<dyn Error>> {
        self.focus_native_window(None)
    }

    pub(super) fn activate_frame(&mut self, key: NativeFrameKey) {
        let Some(pending) = self.pending_frames.remove(&key) else {
            return;
        };
        let Some(host_id) = self.objects.get(&(key.plugin, key.object)).copied() else {
            drop(pending);
            return;
        };
        let Some(window) = self.windows.get_mut(&host_id) else {
            drop(pending);
            return;
        };
        if window.headless {
            // A headless provider surface exists to satisfy an internal
            // producer/display contract. It is never sampled by Denial, so
            // dropping the acquired frame immediately returns its target
            // through the ordinary fence-free discard path.
            drop(pending);
            return;
        }
        window.current = Some(CurrentNativeFrame {
            frame: key.frame,
            dmabuf: pending.dmabuf,
            release: pending.release,
        });
        self.scene_dirty = true;
    }

    pub(super) fn handle_action(
        &mut self,
        action: NativePluginAction,
        default_size: (u32, u32),
        formats: &[NativeAppFormatV1],
        allocator: &mut GbmAllocator<DrmDeviceFd>,
        release_sender: &Sender<NativeReleaseCommand>,
    ) -> Result<Option<NativeAcquireWatch>, Box<dyn Error>> {
        match action {
            NativePluginAction::CreateWindow {
                plugin,
                object,
                title,
                app_id,
                width_hint,
                height_hint,
                flags,
            } => {
                if self.objects.contains_key(&(plugin, object)) {
                    return Err("native plugin repeated a live window object".into());
                }
                if self.windows.len() >= MAX_NATIVE_WINDOWS {
                    return Err(format!(
                        "native application window limit {MAX_NATIVE_WINDOWS} reached"
                    )
                    .into());
                }
                if formats.is_empty() {
                    return Err("Denial renderer exposes no explicit DMA-BUF formats".into());
                }
                let host_id = self.allocate_host_id()?;
                let width = if width_hint == 0 {
                    default_size.0.max(1)
                } else {
                    width_hint
                };
                let height = if height_hint == 0 {
                    default_size.1.max(1)
                } else {
                    height_hint
                };
                let headless = flags & CREATE_HEADLESS != 0;
                self.objects.insert((plugin, object), host_id);
                self.windows.insert(
                    host_id,
                    NativeWindow {
                        plugin,
                        object,
                        external_identity: None,
                        host_id,
                        title,
                        app_id,
                        width,
                        height,
                        x: 0.0,
                        y: 0.0,
                        configure_serial: 1,
                        headless,
                        content_flags: flags & !CREATE_HEADLESS,
                        frame_rate_millihertz: 0,
                        visible: !headless,
                        focused: false,
                        render_targets: BTreeMap::new(),
                        targets_dirty: true,
                        current: None,
                    },
                );
                let mut feedback = NativeAppCommandV1::new(command_kind::FORMAT_FEEDBACK, object);
                feedback.serial = 1;
                feedback.formats_ptr = formats.as_ptr();
                feedback.format_count = formats.len();
                if let Err(error) = self
                    .command(plugin, &feedback)
                    .and_then(|()| self.refresh_target_pool(host_id, formats, allocator))
                {
                    self.objects.remove(&(plugin, object));
                    self.windows.remove(&host_id);
                    return Err(error);
                }
                self.scene_dirty = true;
                Ok(None)
            }
            NativePluginAction::BindWindowIdentity {
                plugin,
                object,
                identity,
            } => {
                let window = self.window_mut(plugin, object)?;
                if window.external_identity.is_some() {
                    return Err("native plugin rebound a window identity".into());
                }
                window.external_identity = Some(identity);
                Ok(None)
            }
            NativePluginAction::DestroyWindow { plugin, object } => {
                let host_id = self
                    .objects
                    .remove(&(plugin, object))
                    .ok_or("native plugin destroyed an unknown window")?;
                self.pending_frames
                    .retain(|key, _| key.plugin != plugin || key.object != object);
                self.frame_targets
                    .retain(|key, _| key.plugin != plugin || key.object != object);
                self.windows.remove(&host_id);
                let touch_slots = self
                    .touch_routes
                    .iter()
                    .filter_map(|(slot, route)| {
                        (route.plugin == plugin && route.object == object).then_some(*slot)
                    })
                    .collect::<Vec<_>>();
                for slot in touch_slots {
                    self.touch_routes.remove(&slot);
                    self.retired_touch_slots.insert(slot);
                }
                let keys = self
                    .key_routes
                    .iter()
                    .filter_map(|(key, route)| {
                        (route.plugin == plugin && route.object == object).then_some(*key)
                    })
                    .collect::<Vec<_>>();
                for key in keys {
                    self.key_routes.remove(&key);
                    self.retired_keys.insert(key);
                }
                self.scene_dirty = true;
                Ok(None)
            }
            NativePluginAction::Present {
                plugin,
                object,
                buffer,
                frame,
                serial,
                flags,
                damage,
                acquire_fence,
            } => {
                if flags != 0 {
                    return Err("native plugin present flags are not defined by ABI v1".into());
                }
                let window = self.window_mut(plugin, object)?;
                if serial != window.configure_serial {
                    return Err("native plugin presented against a stale configure".into());
                }
                let dmabuf = window
                    .render_targets
                    .get(&buffer)
                    .filter(|target| !target.retired && target.configure_serial == serial)
                    .map(|target| target.dmabuf.clone())
                    .ok_or("native plugin presented an unknown or retired render target")?;
                if self.frame_targets.values().any(|target| *target == buffer) {
                    return Err("native plugin reused a render target before release".into());
                }
                let buffer_width = dmabuf.width();
                let buffer_height = dmabuf.height();
                if damage.iter().any(|rect| {
                    rect.width == 0
                        || rect.height == 0
                        || rect
                            .x
                            .checked_add(rect.width)
                            .is_none_or(|right| right > buffer_width)
                        || rect
                            .y
                            .checked_add(rect.height)
                            .is_none_or(|bottom| bottom > buffer_height)
                }) {
                    return Err("native plugin damage exceeds the presented DMA-BUF".into());
                }
                let key = NativeFrameKey {
                    plugin,
                    object,
                    frame,
                };
                let pending = PendingNativeFrame {
                    dmabuf,
                    release: NativeBufferRelease::new(
                        release_sender.clone(),
                        plugin,
                        object,
                        frame,
                    ),
                };
                if self.pending_frames.contains_key(&key) {
                    return Err("native plugin repeated a pending frame identity".into());
                }
                if self.pending_frames.len() >= MAX_PENDING_NATIVE_FRAMES {
                    return Err(format!(
                        "native application pending-frame limit {MAX_PENDING_NATIVE_FRAMES} reached"
                    )
                    .into());
                }
                self.pending_frames.insert(key, pending);
                self.frame_targets.insert(key, buffer);
                Ok(Some(NativeAcquireWatch {
                    key,
                    fence: acquire_fence,
                }))
            }
            NativePluginAction::SetContentState {
                plugin,
                object,
                flags,
            } => {
                self.window_mut(plugin, object)?.content_flags = flags;
                self.scene_dirty = true;
                Ok(None)
            }
            NativePluginAction::SetFrameRate {
                plugin,
                object,
                millihertz,
            } => {
                self.window_mut(plugin, object)?.frame_rate_millihertz = millihertz;
                Ok(None)
            }
        }
    }

    pub(super) fn apply_window_command(
        &mut self,
        command: &wire::WindowCommand,
    ) -> Result<bool, Box<dyn Error>> {
        let Some(window_id) = command.window_id() else {
            return Ok(false);
        };
        if !self.owns_window(window_id) {
            return Ok(false);
        }
        match command {
            wire::WindowCommand::Close { .. } => {
                let window = self.windows.get(&window_id).expect("checked above");
                let close = NativeAppCommandV1::new(command_kind::CLOSE, window.object);
                self.command(window.plugin, &close)?;
            }
            wire::WindowCommand::Focus { .. } => {
                self.focus_native_window(Some(window_id))?;
            }
            wire::WindowCommand::Configure { geometry, .. } => {
                let (width, height) = geometry_dimensions(*geometry)?;
                let window = self.windows.get_mut(&window_id).expect("checked above");
                window.x = geometry.x;
                window.y = geometry.y;
                if window.width != width || window.height != height {
                    window.width = width;
                    window.height = height;
                    window.configure_serial = window
                        .configure_serial
                        .checked_add(1)
                        .ok_or("native plugin configure serial exhausted")?;
                    window.targets_dirty = true;
                }
                self.scene_dirty = true;
            }
            wire::WindowCommand::CreateLocal { .. } => return Ok(false),
        }
        Ok(true)
    }

    pub(super) fn native_window_at(&self, x: f64, y: f64) -> Option<u64> {
        if self.input_layout.exclusive_shell()
            || self
                .input_layout
                .shell_regions
                .iter()
                .chain(&self.input_layout.software_keyboard_regions)
                .any(|region| region.contains(x, y))
        {
            return None;
        }
        self.input_layout
            .windows
            .iter()
            .find(|region| input_region_accepts(region, x, y))
            .and_then(|region| {
                self.windows
                    .contains_key(&region.window_id)
                    .then_some(region.window_id)
            })
    }

    pub(super) fn touch_down(
        &mut self,
        host_id: u64,
        slot: i32,
        x: f64,
        y: f64,
        timestamp_nanos: u64,
    ) -> Result<(), Box<dyn Error>> {
        if self.touch_routes.contains_key(&slot) {
            return Err("native input repeated a live touch slot".into());
        }
        self.retired_touch_slots.remove(&slot);
        let region = self
            .input_layout
            .windows
            .iter()
            .find(|region| input_region_accepts(region, x, y))
            .copied()
            .filter(|region| region.window_id == host_id)
            .ok_or("native touch target changed before routing")?;
        let window = self
            .windows
            .get(&host_id)
            .ok_or("native touch named an unknown host window")?;
        let (plugin, object) = (window.plugin, window.object);
        let (x_fixed, y_fixed) = map_touch_coordinates(region.rect, region.source_rect, x, y);
        self.focus_native_window(Some(host_id))?;
        self.send_input(NativeInputCommand {
            plugin,
            object,
            timestamp_nanos,
            kind: input_kind::TOUCH,
            action: touch_action::DOWN,
            code: u32::try_from(slot).map_err(|_| "native touch slot is negative")?,
            x_fixed,
            y_fixed,
            value: u32::from(u16::MAX),
        })?;
        self.touch_routes.insert(
            slot,
            NativeTouchRoute {
                plugin,
                object,
                host_id,
                rect: region.rect,
                source_rect: region.source_rect,
                last_x_fixed: x_fixed,
                last_y_fixed: y_fixed,
                last_timestamp_nanos: timestamp_nanos,
            },
        );
        Ok(())
    }

    pub(super) fn touch_motion(
        &mut self,
        slot: i32,
        x: f64,
        y: f64,
        timestamp_nanos: u64,
    ) -> Result<bool, Box<dyn Error>> {
        if self.retired_touch_slots.contains(&slot) {
            return Ok(true);
        }
        let Some(route) = self.touch_routes.get(&slot).copied() else {
            return Ok(false);
        };
        let timestamp_nanos = timestamp_nanos.max(route.last_timestamp_nanos);
        let (x_fixed, y_fixed) = map_touch_coordinates(route.rect, route.source_rect, x, y);
        self.send_input(NativeInputCommand {
            plugin: route.plugin,
            object: route.object,
            timestamp_nanos,
            kind: input_kind::TOUCH,
            action: touch_action::MOTION,
            code: u32::try_from(slot).map_err(|_| "native touch slot is negative")?,
            x_fixed,
            y_fixed,
            value: u32::from(u16::MAX),
        })?;
        if let Some(route) = self.touch_routes.get_mut(&slot) {
            route.last_x_fixed = x_fixed;
            route.last_y_fixed = y_fixed;
            route.last_timestamp_nanos = timestamp_nanos;
        }
        Ok(true)
    }

    pub(super) fn touch_up(
        &mut self,
        slot: i32,
        timestamp_nanos: u64,
    ) -> Result<bool, Box<dyn Error>> {
        if self.retired_touch_slots.remove(&slot) {
            return Ok(true);
        }
        let Some(route) = self.touch_routes.remove(&slot) else {
            return Ok(false);
        };
        self.send_touch_terminal(route, slot, timestamp_nanos, touch_action::UP)?;
        Ok(true)
    }

    pub(super) fn touch_cancel(
        &mut self,
        slot: i32,
        timestamp_nanos: u64,
    ) -> Result<bool, Box<dyn Error>> {
        if self.retired_touch_slots.remove(&slot) {
            return Ok(true);
        }
        let Some(route) = self.touch_routes.remove(&slot) else {
            return Ok(false);
        };
        self.send_touch_terminal(route, slot, timestamp_nanos, touch_action::CANCEL)?;
        Ok(true)
    }

    pub(super) fn route_key(
        &mut self,
        keycode: u32,
        pressed: bool,
        timestamp_nanos: u64,
        allow_new: bool,
    ) -> Result<bool, Box<dyn Error>> {
        if !pressed {
            if self.retired_keys.remove(&keycode) {
                return Ok(true);
            }
            let Some(route) = self.key_routes.remove(&keycode) else {
                return Ok(false);
            };
            self.send_key(route, keycode, false, timestamp_nanos)?;
            return Ok(true);
        }

        if let Some(mut route) = self.key_routes.get(&keycode).copied() {
            route.repeat = route.repeat.saturating_add(1);
            route.last_timestamp_nanos = timestamp_nanos.max(route.last_timestamp_nanos);
            self.send_key(route, keycode, true, route.last_timestamp_nanos)?;
            self.key_routes.insert(keycode, route);
            return Ok(true);
        }
        if !allow_new || self.input_layout.keyboard_capture() || self.input_layout.exclusive_shell()
        {
            return Ok(false);
        }
        self.retired_keys.remove(&keycode);
        let Some(window) = self
            .windows
            .values()
            .find(|window| window.focused && window.visible)
        else {
            return Ok(false);
        };
        let route = NativeKeyRoute {
            plugin: window.plugin,
            object: window.object,
            repeat: 0,
            last_timestamp_nanos: timestamp_nanos,
        };
        self.send_key(route, keycode, true, timestamp_nanos)?;
        self.key_routes.insert(keycode, route);
        Ok(true)
    }

    pub(super) fn reset_input(
        &mut self,
        reset_keyboard: bool,
        reset_touch: bool,
    ) -> Result<(), Box<dyn Error>> {
        let mut first_error = None;
        if reset_touch {
            let routes = self.touch_routes.drain().collect::<Vec<_>>();
            for (slot, route) in routes {
                self.retired_touch_slots.insert(slot);
                if let Err(error) = self.send_touch_terminal(
                    route,
                    slot,
                    route.last_timestamp_nanos,
                    touch_action::CANCEL,
                ) {
                    first_error.get_or_insert(error);
                }
            }
        }
        if reset_keyboard {
            let routes = self.key_routes.drain().collect::<Vec<_>>();
            for (keycode, route) in routes {
                self.retired_keys.insert(keycode);
                if let Err(error) = self.send_key(route, keycode, false, route.last_timestamp_nanos)
                {
                    first_error.get_or_insert(error);
                }
            }
        }
        match first_error {
            Some(error) => Err(error),
            None => Ok(()),
        }
    }

    pub(super) fn apply_input_layout(
        &mut self,
        layout: &wire::InputLayoutSnapshot,
    ) -> Result<bool, Box<dyn Error>> {
        self.input_layout.clone_from(layout);
        let visible = layout
            .windows
            .iter()
            .filter(|region| region.visible())
            .map(|region| region.window_id)
            .collect::<HashSet<_>>();
        let mut changes = Vec::new();
        let mut changed = false;
        for window in self.windows.values_mut() {
            let next = visible.contains(&window.host_id);
            if next != window.visible {
                window.visible = next;
                if !next {
                    window.focused = false;
                }
                changed = true;
                changes.push((window.plugin, window.object, next, window.focused));
            }
        }
        for (plugin, object, is_visible, focused) in changes {
            self.send_visibility(plugin, object, is_visible, focused)?;
        }
        if changed {
            self.scene_dirty = true;
        }
        let lost_touch_slots = self
            .touch_routes
            .iter()
            .filter_map(|(slot, route)| {
                (layout.exclusive_shell() || !visible.contains(&route.host_id)).then_some(*slot)
            })
            .collect::<Vec<_>>();
        for slot in lost_touch_slots {
            if let Some(route) = self.touch_routes.remove(&slot) {
                self.retired_touch_slots.insert(slot);
                self.send_touch_terminal(
                    route,
                    slot,
                    route.last_timestamp_nanos,
                    touch_action::CANCEL,
                )?;
            }
        }
        if layout.keyboard_capture()
            || layout.exclusive_shell()
            || !self.windows.values().any(|window| window.focused)
        {
            self.reset_input(true, false)?;
        }
        Ok(changed)
    }

    pub(super) fn scene(&self) -> (Vec<WindowDescription>, Vec<ExternalTextureFrame>) {
        let mut windows = Vec::with_capacity(self.windows.len());
        let mut textures = Vec::with_capacity(self.windows.len());
        for window in self.windows.values() {
            if window.headless {
                continue;
            }
            let Some(current) = window.current.as_ref() else {
                continue;
            };
            let opaque = window.content_flags & CONTENT_OPAQUE != 0;
            let texture_id = i64::try_from(window.host_id).expect("plugin host IDs fit i64");
            textures.push(ExternalTextureFrame::from_native_dmabuf(
                texture_id,
                current.dmabuf.clone(),
                current.release.clone(),
                current.frame,
                window.visible,
            ));
            let width = f64::from(window.width);
            let height = f64::from(window.height);
            windows.push(WindowDescription {
                object_id: window.host_id,
                surface_id: window.host_id,
                window_id: window.host_id,
                texture_id: window.host_id,
                title: window.title.clone(),
                app_id: window.app_id.clone(),
                width: window.width,
                height: window.height,
                surface_x: 0.0,
                surface_y: 0.0,
                surface_width: width,
                surface_height: height,
                texture_source_x: 0.0,
                texture_source_y: 0.0,
                texture_source_width: width,
                texture_source_height: height,
                geometry_x: window.x,
                geometry_y: window.y,
                geometry_width: width,
                geometry_height: height,
                monitor_id: -1,
                transform: 0,
                scale_120: 120,
                content_x: 0.0,
                content_y: 0.0,
                content_width: width,
                content_height: height,
                surfaces: vec![SurfaceLayerDescription {
                    surface_id: window.host_id,
                    parent_surface_id: 0,
                    popup_root_surface_id: 0,
                    role: SurfaceRoleDescription::Root,
                    texture_id: window.host_id,
                    width: window.width,
                    height: window.height,
                    surface_x: 0.0,
                    surface_y: 0.0,
                    surface_width: width,
                    surface_height: height,
                    texture_source_x: 0.0,
                    texture_source_y: 0.0,
                    texture_source_width: width,
                    texture_source_height: height,
                    transform: 0,
                    scale_120: 120,
                    composition_order: 0,
                    opacity: 1.0,
                    opaque,
                }],
                suppress_animations: false,
                server_side_decorated: false,
                opacity: 1.0,
                content_kind: WindowContentKind::SurfaceTree,
                opacity_class: if opaque {
                    WindowOpacityClass::FullyOpaque
                } else {
                    WindowOpacityClass::ContentTranslucent
                },
            });
        }
        (windows, textures)
    }

    pub(super) fn handle_release_command(
        &mut self,
        release: NativeReleaseCommand,
    ) -> Result<(), Box<dyn Error>> {
        let (plugin, command, terminal_key) = match release {
            NativeReleaseCommand::Materialize {
                plugin,
                object,
                frame,
                fence,
            } => {
                let mut command =
                    NativeAppCommandV1::new(command_kind::MATERIALIZE_RELEASE, object);
                command.frame_id = frame;
                command.descriptor = fence.as_raw_fd();
                self.command(plugin, &command)?;
                return Ok(());
            }
            NativeReleaseCommand::Complete {
                plugin,
                object,
                frame,
            } => {
                let mut command = NativeAppCommandV1::new(command_kind::COMPLETE_RELEASE, object);
                command.frame_id = frame;
                (
                    plugin,
                    command,
                    Some(NativeFrameKey {
                        plugin,
                        object,
                        frame,
                    }),
                )
            }
            NativeReleaseCommand::Discard {
                plugin,
                object,
                frame,
            } => {
                let mut command = NativeAppCommandV1::new(command_kind::DISCARD_RELEASE, object);
                command.frame_id = frame;
                (
                    plugin,
                    command,
                    Some(NativeFrameKey {
                        plugin,
                        object,
                        frame,
                    }),
                )
            }
        };
        self.command(plugin, &command)?;
        if let Some(key) = terminal_key {
            self.frame_targets.remove(&key);
        }
        self.retire_unused_targets()
    }

    fn allocate_host_id(&mut self) -> Result<u64, Box<dyn Error>> {
        let id = self.next_host_id;
        self.next_host_id = self
            .next_host_id
            .checked_add(1)
            .filter(|next| *next <= i64::MAX as u64)
            .ok_or("native plugin host identity space exhausted")?;
        Ok(id)
    }

    fn allocate_target_id(&mut self) -> Result<u64, Box<dyn Error>> {
        let id = self.next_target_id;
        self.next_target_id = self
            .next_target_id
            .checked_add(1)
            .ok_or("native render-target identity space exhausted")?;
        Ok(id)
    }

    fn window_mut(
        &mut self,
        plugin: usize,
        object: u64,
    ) -> Result<&mut NativeWindow, Box<dyn Error>> {
        let host_id = self
            .objects
            .get(&(plugin, object))
            .copied()
            .ok_or("native plugin referenced an unknown window")?;
        self.windows
            .get_mut(&host_id)
            .ok_or_else(|| "native plugin window index is inconsistent".into())
    }

    pub(super) fn refresh_dirty_target_pools(
        &mut self,
        formats: &[NativeAppFormatV1],
        allocator: &mut GbmAllocator<DrmDeviceFd>,
    ) -> Result<(), Box<dyn Error>> {
        let dirty = self
            .windows
            .iter()
            .filter_map(|(host_id, window)| window.targets_dirty.then_some(*host_id))
            .collect::<Vec<_>>();
        for host_id in dirty {
            self.refresh_target_pool(host_id, formats, allocator)?;
        }
        Ok(())
    }

    fn refresh_target_pool(
        &mut self,
        host_id: u64,
        formats: &[NativeAppFormatV1],
        allocator: &mut GbmAllocator<DrmDeviceFd>,
    ) -> Result<(), Box<dyn Error>> {
        let (plugin, object, width, height, configure_serial) = {
            let window = self
                .windows
                .get(&host_id)
                .ok_or("native render-target allocation named an unknown window")?;
            (
                window.plugin,
                window.object,
                window.width,
                window.height,
                window.configure_serial,
            )
        };
        let (fourcc, modifiers) = render_target_format(formats)?;
        let mut targets = Vec::with_capacity(NATIVE_RENDER_TARGET_POOL_LENGTH);
        for _ in 0..NATIVE_RENDER_TARGET_POOL_LENGTH {
            let id = self.allocate_target_id()?;
            let allocation = allocator.create_buffer(width, height, fourcc, &modifiers)?;
            let format = AllocatorBuffer::format(&allocation);
            if format.code != fourcc || !modifiers.contains(&format.modifier) {
                return Err(format!(
                    "GBM returned render target {format:?} outside the requested set"
                )
                .into());
            }
            let dmabuf = allocation.export()?;
            targets.push((
                id,
                NativeRenderTarget {
                    dmabuf,
                    configure_serial,
                    retired: false,
                    _allocation: allocation,
                },
            ));
        }

        let mut registered = Vec::new();
        for (id, target) in &targets {
            if let Err(error) = self.send_register_render_target(plugin, object, *id, target) {
                for registered_id in registered {
                    let _ = self.send_unregister_render_target(plugin, object, registered_id);
                }
                return Err(error);
            }
            registered.push(*id);
        }

        let window = self
            .windows
            .get_mut(&host_id)
            .ok_or("native render-target window disappeared")?;
        for target in window.render_targets.values_mut() {
            target.retired = true;
        }
        window.render_targets.extend(targets);
        window.targets_dirty = false;
        self.send_configure(host_id)?;
        self.retire_unused_targets()
    }

    fn send_register_render_target(
        &mut self,
        plugin: usize,
        object: u64,
        buffer_id: u64,
        target: &NativeRenderTarget,
    ) -> Result<(), Box<dyn Error>> {
        let mut command = NativeAppCommandV1::new(command_kind::REGISTER_RENDER_TARGET, object);
        command.buffer_id = buffer_id;
        command.serial = target.configure_serial;
        command.width = target.dmabuf.width();
        command.height = target.dmabuf.height();
        command.format = target.dmabuf.format().code as u32;
        command.modifier = u64::from(target.dmabuf.format().modifier);
        command.plane_count = u32::try_from(target.dmabuf.num_planes())?;
        for (index, ((fd, offset), stride)) in target
            .dmabuf
            .handles()
            .zip(target.dmabuf.offsets())
            .zip(target.dmabuf.strides())
            .enumerate()
        {
            command.plane_fds[index] = fd.as_raw_fd();
            command.plane_offsets[index] = offset;
            command.plane_strides[index] = stride;
        }
        self.command(plugin, &command)
    }

    fn send_unregister_render_target(
        &mut self,
        plugin: usize,
        object: u64,
        buffer_id: u64,
    ) -> Result<(), Box<dyn Error>> {
        let mut command = NativeAppCommandV1::new(command_kind::UNREGISTER_RENDER_TARGET, object);
        command.buffer_id = buffer_id;
        self.command(plugin, &command)
    }

    fn retire_unused_targets(&mut self) -> Result<(), Box<dyn Error>> {
        let busy = self.frame_targets.values().copied().collect::<HashSet<_>>();
        let retired = self
            .windows
            .values()
            .flat_map(|window| {
                window.render_targets.iter().filter_map(|(id, target)| {
                    (target.retired && !busy.contains(id)).then_some((
                        window.host_id,
                        window.plugin,
                        window.object,
                        *id,
                    ))
                })
            })
            .collect::<Vec<_>>();
        for (host_id, plugin, object, id) in retired {
            self.send_unregister_render_target(plugin, object, id)?;
            if let Some(window) = self.windows.get_mut(&host_id) {
                window.render_targets.remove(&id);
            }
        }
        Ok(())
    }

    fn send_configure(&mut self, host_id: u64) -> Result<(), Box<dyn Error>> {
        let window = self
            .windows
            .get(&host_id)
            .ok_or("native plugin configure named an unknown host window")?;
        let command = configure_command(
            window.object,
            window.configure_serial,
            window.width,
            window.height,
            self.scale_numerator,
            self.scale_denominator,
            self.refresh_millihz,
        );
        self.command(window.plugin, &command)
    }

    fn send_visibility(
        &mut self,
        plugin: usize,
        object: u64,
        visible: bool,
        focused: bool,
    ) -> Result<(), Box<dyn Error>> {
        let mut command = NativeAppCommandV1::new(command_kind::VISIBILITY, object);
        command.flags = u32::from(visible);
        command.focused = u32::from(focused);
        self.command(plugin, &command)
    }

    fn focus_native_window(&mut self, focused_host_id: Option<u64>) -> Result<(), Box<dyn Error>> {
        let mut changes = Vec::new();
        for window in self.windows.values_mut() {
            let focused = focused_host_id == Some(window.host_id);
            if focused != window.focused {
                window.focused = focused;
                changes.push((window.plugin, window.object, window.visible, focused));
            }
        }
        for (plugin, object, visible, focused) in changes {
            self.send_visibility(plugin, object, visible, focused)?;
        }
        Ok(())
    }

    fn send_input(&mut self, input: NativeInputCommand) -> Result<(), Box<dyn Error>> {
        let mut command = NativeAppCommandV1::new(command_kind::INPUT, input.object);
        command.serial = self.next_input_serial;
        self.next_input_serial = self
            .next_input_serial
            .checked_add(1)
            .ok_or("native application input serial exhausted")?;
        command.timestamp_nanos = input.timestamp_nanos;
        command.input_kind = input.kind;
        command.input_action = input.action;
        command.input_code = input.code;
        command.input_x_fixed = input.x_fixed;
        command.input_y_fixed = input.y_fixed;
        command.input_value = input.value;
        self.command(input.plugin, &command)
    }

    fn send_touch_terminal(
        &mut self,
        route: NativeTouchRoute,
        slot: i32,
        timestamp_nanos: u64,
        action: u32,
    ) -> Result<(), Box<dyn Error>> {
        self.send_input(NativeInputCommand {
            plugin: route.plugin,
            object: route.object,
            timestamp_nanos: timestamp_nanos.max(route.last_timestamp_nanos),
            kind: input_kind::TOUCH,
            action,
            code: u32::try_from(slot).map_err(|_| "native touch slot is negative")?,
            x_fixed: route.last_x_fixed,
            y_fixed: route.last_y_fixed,
            value: 0,
        })
    }

    fn send_key(
        &mut self,
        route: NativeKeyRoute,
        keycode: u32,
        pressed: bool,
        timestamp_nanos: u64,
    ) -> Result<(), Box<dyn Error>> {
        self.send_input(NativeInputCommand {
            plugin: route.plugin,
            object: route.object,
            timestamp_nanos: timestamp_nanos.max(route.last_timestamp_nanos),
            kind: input_kind::KEY,
            action: if pressed {
                key_action::DOWN
            } else {
                key_action::UP
            },
            code: keycode,
            x_fixed: 0,
            y_fixed: 0,
            value: u32::from(route.repeat),
        })
    }
}

fn render_target_format(
    formats: &[NativeAppFormatV1],
) -> Result<(Fourcc, Vec<Modifier>), Box<dyn Error>> {
    for fourcc in [Fourcc::Argb8888, Fourcc::Xrgb8888] {
        let modifiers = formats
            .iter()
            .filter(|format| format.format == fourcc as u32)
            .map(|format| Modifier::from(format.modifier))
            .collect::<Vec<_>>();
        if !modifiers.is_empty() {
            return Ok((fourcc, modifiers));
        }
    }
    Err("Denial renderer exposes no allocatable AR24 or XR24 render target".into())
}

fn input_region_accepts(region: &wire::InputWindowRegion, x: f64, y: f64) -> bool {
    region.rect.contains(x, y)
        && region.visible()
        && region.hit_test_enabled()
        && region.window_id == region.object_id
}

fn map_touch_coordinates(
    rect: wire::InputRect,
    source: wire::InputRect,
    x: f64,
    y: f64,
) -> (i32, i32) {
    let normalized_x = ((x - rect.x) / rect.width).clamp(0.0, 1.0);
    let normalized_y = ((y - rect.y) / rect.height).clamp(0.0, 1.0);
    let x = fixed_16_16(source.x + normalized_x * source.width);
    let y = fixed_16_16(source.y + normalized_y * source.height);
    let min_x = fixed_16_16(source.x);
    let min_y = fixed_16_16(source.y);
    let max_x = fixed_16_16(source.x + source.width)
        .saturating_sub(1)
        .max(min_x);
    let max_y = fixed_16_16(source.y + source.height)
        .saturating_sub(1)
        .max(min_y);
    (x.clamp(min_x, max_x), y.clamp(min_y, max_y))
}

fn fixed_16_16(value: f64) -> i32 {
    let scaled = (value * 65_536.0).round();
    if scaled <= f64::from(i32::MIN) {
        i32::MIN
    } else if scaled >= f64::from(i32::MAX) {
        i32::MAX
    } else {
        scaled as i32
    }
}

fn geometry_dimensions(geometry: wire::WindowGeometry) -> Result<(u32, u32), Box<dyn Error>> {
    if !geometry.width.is_finite()
        || !geometry.height.is_finite()
        || geometry.width < 1.0
        || geometry.height < 1.0
        || geometry.width > f64::from(u32::MAX)
        || geometry.height > f64::from(u32::MAX)
    {
        return Err("native plugin window configure has invalid dimensions".into());
    }
    Ok((
        geometry.width.round() as u32,
        geometry.height.round() as u32,
    ))
}

fn load_plugin(path: &Path, drm_fd: BorrowedFd<'_>) -> Result<LoadedPlugin, Box<dyn Error>> {
    let canonical = validate_plugin_path(path)?;
    // SAFETY: the path was canonicalized, verified as a trusted regular file,
    // and loading a configured native plugin is the explicitly requested ABI
    // operation. Its lifetime is retained in `LoadedPlugin`.
    let library = unsafe { Library::new(&canonical)? };
    // SAFETY: the symbol name and function signature are the version-1 C ABI.
    // The returned Symbol cannot outlive `library` and is copied immediately.
    let entry = unsafe { library.get::<EntryFn>(ENTRY_SYMBOL)? };
    let host = NativeAppHostV1 {
        struct_size: u32::try_from(std::mem::size_of::<NativeAppHostV1>())?,
        abi_major: ABI_MAJOR,
        abi_minor: ABI_MINOR,
        drm_fd: drm_fd.as_raw_fd(),
    };
    let mut table = NativeAppPluginV1::default();
    // SAFETY: `host` is a valid immutable version-1 table and `table` is
    // writable output storage for exactly one version-1 plugin table.
    let status = unsafe { entry(&raw const host, &raw mut table) };
    if status != 0 {
        return Err(format!("native application plugin entry failed with status {status}").into());
    }
    validate_table(&table)?;
    let name = copy_utf8(table.name_ptr.cast(), table.name_len, "plugin name")?;
    Ok(LoadedPlugin {
        name,
        table,
        _library: library,
    })
}

fn validate_plugin_path(path: &Path) -> Result<PathBuf, Box<dyn Error>> {
    if !path.is_absolute() {
        return Err(format!(
            "native application plugin path must be absolute: {}",
            path.display()
        )
        .into());
    }
    let canonical = fs::canonicalize(path)?;
    let metadata = fs::metadata(&canonical)?;
    if !metadata.is_file() {
        return Err(format!(
            "native application plugin is not a regular file: {}",
            canonical.display()
        )
        .into());
    }
    let effective_uid = {
        // SAFETY: geteuid has no preconditions and no failure return.
        unsafe { libc::geteuid() }
    };
    if metadata.uid() != 0 && metadata.uid() != effective_uid {
        return Err(format!(
            "native application plugin has untrusted owner uid {}: {}",
            metadata.uid(),
            canonical.display()
        )
        .into());
    }
    if metadata.mode() & 0o022 != 0 {
        return Err(format!(
            "native application plugin is group/world writable: {}",
            canonical.display()
        )
        .into());
    }
    Ok(canonical)
}

fn validate_table(table: &NativeAppPluginV1) -> Result<(), Box<dyn Error>> {
    if usize::try_from(table.struct_size)? < std::mem::size_of::<NativeAppPluginV1>() {
        return Err("native application plugin returned a truncated function table".into());
    }
    if table.abi_major != ABI_MAJOR || table.abi_minor != ABI_MINOR {
        return Err(format!(
            "native application plugin ABI {}.{} is incompatible with host {}.{}",
            table.abi_major, table.abi_minor, ABI_MAJOR, ABI_MINOR
        )
        .into());
    }
    if table.context.is_null()
        || table.poll_fd < 0
        || table.next_event.is_none()
        || table.command.is_none()
        || table.shutdown.is_none()
    {
        return Err("native application plugin returned an incomplete function table".into());
    }
    if table.name_ptr.is_null() || table.name_len == 0 || table.name_len > MAX_PLUGIN_STRING_BYTES {
        return Err("native application plugin returned an invalid name".into());
    }
    Ok(())
}

fn parse_event(
    plugin: usize,
    raw: &mut NativeAppEventV1,
) -> Result<NativePluginAction, Box<dyn Error>> {
    if usize::try_from(raw.struct_size)? < std::mem::size_of::<NativeAppEventV1>() {
        close_event_descriptors(raw);
        return Err("native application plugin returned a truncated event".into());
    }
    let result = match raw.kind {
        event_kind::CREATE_WINDOW => Ok(NativePluginAction::CreateWindow {
            plugin,
            object: nonzero(raw.object_id, "plugin window object")?,
            title: copy_utf8(raw.text_ptr, raw.text_len, "window title")?,
            app_id: copy_utf8(raw.app_id_ptr, raw.app_id_len, "application id")?,
            width_hint: raw.width,
            height_hint: raw.height,
            flags: raw.flags,
        }),
        event_kind::BIND_WINDOW_IDENTITY => Ok(NativePluginAction::BindWindowIdentity {
            plugin,
            object: nonzero(raw.object_id, "plugin window object")?,
            identity: nonzero(raw.identity, "external window identity")?,
        }),
        event_kind::DESTROY_WINDOW => Ok(NativePluginAction::DestroyWindow {
            plugin,
            object: nonzero(raw.object_id, "plugin window object")?,
        }),
        event_kind::PRESENT => {
            let acquire_fence = take_fd(&mut raw.acquire_fence_fd)?;
            let damage = copy_damage(raw.damage_ptr, raw.damage_count)?;
            Ok(NativePluginAction::Present {
                plugin,
                object: nonzero(raw.object_id, "plugin window object")?,
                buffer: nonzero(raw.buffer_id, "plugin buffer")?,
                frame: nonzero(raw.frame_id, "plugin frame")?,
                serial: raw.serial,
                flags: raw.flags,
                damage,
                acquire_fence,
            })
        }
        event_kind::SET_CONTENT_STATE => Ok(NativePluginAction::SetContentState {
            plugin,
            object: nonzero(raw.object_id, "plugin window object")?,
            flags: raw.flags,
        }),
        event_kind::SET_FRAME_RATE => Ok(NativePluginAction::SetFrameRate {
            plugin,
            object: nonzero(raw.object_id, "plugin window object")?,
            millihertz: raw.flags,
        }),
        kind => Err(format!("native application plugin returned unknown event kind {kind}").into()),
    };
    close_event_descriptors(raw);
    result
}

fn take_fd(raw: &mut RawFd) -> Result<OwnedFd, Box<dyn Error>> {
    if *raw < 0 {
        return Err("native application plugin omitted a required descriptor".into());
    }
    let fd = *raw;
    *raw = -1;
    // SAFETY: successful plugin events transfer ownership of every
    // nonnegative descriptor exactly once; the slot was reset above.
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

fn close_event_descriptors(raw: &mut NativeAppEventV1) {
    for slot in &mut raw.plane_fds {
        if *slot >= 0 {
            // SAFETY: nonnegative event descriptor slots transfer ownership to
            // Denial. Reconstructing and dropping closes each residual once.
            drop(unsafe { OwnedFd::from_raw_fd(*slot) });
            *slot = -1;
        }
    }
    if raw.acquire_fence_fd >= 0 {
        // SAFETY: ownership follows the same event transfer rule as planes.
        drop(unsafe { OwnedFd::from_raw_fd(raw.acquire_fence_fd) });
        raw.acquire_fence_fd = -1;
    }
}

fn copy_utf8(pointer: *const u8, length: usize, field: &str) -> Result<String, Box<dyn Error>> {
    if pointer.is_null() || length == 0 || length > MAX_PLUGIN_STRING_BYTES {
        return Err(format!("native application plugin returned invalid {field}").into());
    }
    // SAFETY: a successfully loaded plugin promises that borrowed payload
    // ranges remain valid until the next callback. The trusted plugin is in
    // the same address space; the host copies the range immediately.
    let bytes = unsafe { slice::from_raw_parts(pointer, length) };
    Ok(std::str::from_utf8(bytes)?.to_owned())
}

fn copy_damage(
    pointer: *const NativeAppDamageV1,
    count: usize,
) -> Result<Vec<NativeAppDamageV1>, Box<dyn Error>> {
    const MAX_DAMAGE_RECTS: usize = 256;
    if count > MAX_DAMAGE_RECTS || (count > 0 && pointer.is_null()) {
        return Err("native application plugin returned invalid damage".into());
    }
    if count == 0 {
        return Ok(Vec::new());
    }
    // SAFETY: the event ABI promises a live `count`-element borrowed range
    // until the next callback; the validated bound is copied immediately.
    Ok(unsafe { slice::from_raw_parts(pointer, count) }.to_vec())
}

fn nonzero(value: u64, field: &str) -> Result<u64, Box<dyn Error>> {
    if value == 0 {
        Err(format!("native application plugin returned zero {field}").into())
    } else {
        Ok(value)
    }
}

fn validate_scale(numerator: u32, denominator: u32) -> Result<(), Box<dyn Error>> {
    if numerator == 0 || denominator == 0 {
        Err(
            format!("native application scale must be non-zero, got {numerator}/{denominator}")
                .into(),
        )
    } else {
        Ok(())
    }
}

fn validate_refresh(refresh_millihz: u32) -> Result<(), Box<dyn Error>> {
    if refresh_millihz == 0 || refresh_millihz > 1_000_000 {
        Err(format!(
            "native application refresh must be within 1..=1000000 mHz, got {refresh_millihz}"
        )
        .into())
    } else {
        Ok(())
    }
}

fn configure_command(
    object: u64,
    serial: u64,
    width: u32,
    height: u32,
    scale_numerator: u32,
    scale_denominator: u32,
    refresh_millihz: u32,
) -> NativeAppCommandV1 {
    let mut command = NativeAppCommandV1::new(command_kind::CONFIGURE, object);
    command.serial = serial;
    command.width = width;
    command.height = height;
    command.scale_numerator = scale_numerator;
    command.scale_denominator = scale_denominator;
    command.refresh_millihz = refresh_millihz;
    command
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::fd::IntoRawFd;

    #[test]
    fn abi_tables_are_versioned_and_have_explicit_descriptor_sentinels() {
        let event = NativeAppEventV1::default();
        assert_eq!(event.struct_size as usize, std::mem::size_of_val(&event));
        assert_eq!(event.plane_fds, [-1; MAX_PLANES]);
        assert_eq!(event.acquire_fence_fd, -1);

        let command = NativeAppCommandV1::new(command_kind::CONFIGURE, 7);
        assert_eq!(
            command.struct_size as usize,
            std::mem::size_of_val(&command)
        );
        assert_eq!(command.descriptor, -1);
    }

    #[test]
    fn configure_command_carries_logical_to_buffer_scale() {
        let command = configure_command(7, 9, 1264, 2780, 240, 120, 120_000);
        assert_eq!(command.object_id, 7);
        assert_eq!(command.serial, 9);
        assert_eq!(command.width, 1264);
        assert_eq!(command.height, 2780);
        assert_eq!(command.scale_numerator, 240);
        assert_eq!(command.scale_denominator, 120);
        assert_eq!(command.refresh_millihz, 120_000);
        assert!(validate_scale(command.scale_numerator, command.scale_denominator).is_ok());
        assert!(validate_scale(0, 120).is_err());
        assert!(validate_refresh(command.refresh_millihz).is_ok());
        assert!(validate_refresh(0).is_err());
    }

    #[test]
    fn malformed_event_closes_every_transferred_descriptor() {
        let first = fs::File::open("/dev/null").unwrap().into_raw_fd();
        let second = fs::File::open("/dev/null").unwrap().into_raw_fd();
        let mut event = NativeAppEventV1 {
            kind: u32::MAX,
            plane_fds: [first, -1, -1, -1],
            acquire_fence_fd: second,
            ..NativeAppEventV1::default()
        };
        assert!(parse_event(0, &mut event).is_err());
        assert_eq!(event.plane_fds, [-1; MAX_PLANES]);
        assert_eq!(event.acquire_fence_fd, -1);
    }

    #[test]
    fn relative_plugin_paths_are_rejected_before_loading() {
        assert!(validate_plugin_path(Path::new("plugin.so")).is_err());
    }

    #[test]
    fn touch_coordinates_map_and_clamp_to_source_pixels() {
        let rect = wire::InputRect {
            x: 10.0,
            y: 20.0,
            width: 100.0,
            height: 200.0,
        };
        let source = wire::InputRect {
            x: 4.0,
            y: 8.0,
            width: 50.0,
            height: 100.0,
        };
        assert_eq!(
            map_touch_coordinates(rect, source, 60.0, 120.0),
            (29 << 16, 58 << 16)
        );
        let (x, y) = map_touch_coordinates(rect, source, 1_000.0, -1_000.0);
        assert_eq!(x, (54 << 16) - 1);
        assert_eq!(y, 8 << 16);
    }

    #[test]
    fn native_hit_test_requires_visible_root_window_region() {
        let mut region = wire::InputWindowRegion {
            object_id: 7,
            surface_id: 7,
            window_id: 7,
            rect: wire::InputRect {
                x: 0.0,
                y: 0.0,
                width: 100.0,
                height: 100.0,
            },
            source_rect: wire::InputRect {
                x: 0.0,
                y: 0.0,
                width: 100.0,
                height: 100.0,
            },
            z: 1,
            flags: wire::INPUT_WINDOW_VISIBLE,
        };
        assert!(input_region_accepts(&region, 50.0, 50.0));
        region.object_id = 8;
        assert!(!input_region_accepts(&region, 50.0, 50.0));
        region.object_id = 7;
        region.flags |= wire::INPUT_WINDOW_HIT_TEST_DISABLED;
        assert!(!input_region_accepts(&region, 50.0, 50.0));
    }
}
