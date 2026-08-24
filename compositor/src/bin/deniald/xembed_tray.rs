//! Legacy freedesktop XEmbed system-tray host for Xwayland applications.
//!
//! The X11 host stays off-screen. Its child icons are sampled into bounded
//! premultiplied RGBA snapshots for Flutter, and shell clicks are translated
//! back into ordinary X button events.

use std::collections::{BTreeMap, BTreeSet};
use std::error::Error;
use std::ffi::OsString;
use std::fmt;
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender, TryRecvError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use tracing::{info, warn};
use x11rb::connection::Connection;
use x11rb::protocol::Event;
use x11rb::protocol::composite::{ConnectionExt as _, Redirect};
use x11rb::protocol::xproto::{
    Atom, AtomEnum, BUTTON_PRESS_EVENT, BUTTON_RELEASE_EVENT, ButtonIndex, ButtonPressEvent,
    ChangeWindowAttributesAux, ClientMessageEvent, Colormap, ColormapAlloc, ConfigureWindowAux,
    ConnectionExt as _, CreateWindowAux, EventMask, ImageFormat, ImageOrder, KeyButMask, PropMode,
    SetMode, VisualClass, Window, WindowClass,
};
use x11rb::rust_connection::RustConnection;
use x11rb::wrapper::ConnectionExt as _;
use x11rb::{COPY_DEPTH_FROM_PARENT, COPY_FROM_PARENT, CURRENT_TIME, NONE};

const COMMAND_CAPACITY: usize = 64;
const EVENT_CAPACITY: usize = 128;
const MAX_ICONS: usize = 64;
const MAX_REJECTED_ICONS: usize = 64;
const ICON_SIZE: u16 = 32;
const SNAPSHOT_INTERVAL: Duration = Duration::from_millis(250);
const REJECTION_TTL: Duration = Duration::from_secs(5);
const MAX_ICON_BYTES: usize = 512 * 1024;
const SYSTEM_TRAY_REQUEST_DOCK: u32 = 0;
const XEMBED_EMBEDDED_NOTIFY: u32 = 0;
const XEMBED_VERSION: u32 = 0;
const XEMBED_MAPPED: u32 = 1;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum XEmbedTrayEventKind {
    Added,
    Updated,
    Removed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct XEmbedTrayIcon {
    pub(super) window_id: u32,
    pub(super) title: String,
    pub(super) width: u32,
    pub(super) height: u32,
    pub(super) rgba: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct XEmbedTrayEvent {
    pub(super) kind: XEmbedTrayEventKind,
    pub(super) window_id: u32,
    pub(super) icon: Option<XEmbedTrayIcon>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum XEmbedTrayAction {
    Activate,
    SecondaryActivate,
    ContextMenu,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct XEmbedTrayCommand {
    pub(super) action: XEmbedTrayAction,
    pub(super) window_id: u32,
    pub(super) x: i32,
    pub(super) y: i32,
}

#[derive(Debug)]
pub(super) struct XEmbedTrayError(String);

impl fmt::Display for XEmbedTrayError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl Error for XEmbedTrayError {}

pub(super) struct XEmbedTray {
    commands: SyncSender<WorkerCommand>,
    events: Receiver<XEmbedTrayEvent>,
    stopping: Arc<AtomicBool>,
    replay_requested: Arc<AtomicBool>,
    wake: UnixStream,
    worker: Option<JoinHandle<()>>,
}

impl XEmbedTray {
    pub(super) fn start(display: OsString) -> Result<Self, XEmbedTrayError> {
        let display = display
            .into_string()
            .map_err(|_| XEmbedTrayError("Xwayland display name is not UTF-8".into()))?;
        let (commands, command_rx) = mpsc::sync_channel(COMMAND_CAPACITY);
        let (event_tx, events) = mpsc::sync_channel(EVENT_CAPACITY);
        let (ready_tx, ready_rx) = mpsc::sync_channel(1);
        let (wake, worker_wake) = UnixStream::pair().map_err(|error| {
            XEmbedTrayError(format!("could not create worker wake pipe: {error}"))
        })?;
        wake.set_nonblocking(true).map_err(|error| {
            XEmbedTrayError(format!("could not configure worker wake pipe: {error}"))
        })?;
        worker_wake.set_nonblocking(true).map_err(|error| {
            XEmbedTrayError(format!("could not configure worker wake pipe: {error}"))
        })?;
        let stopping = Arc::new(AtomicBool::new(false));
        let replay_requested = Arc::new(AtomicBool::new(false));
        let worker = thread::Builder::new()
            .name("denial-xembed-tray".into())
            .spawn({
                let stopping = Arc::clone(&stopping);
                let replay_requested = Arc::clone(&replay_requested);
                move || {
                    crate::cpu_scheduling::normalize_current_worker("xembed tray");
                    match Worker::connect(
                        &display,
                        command_rx,
                        event_tx,
                        stopping,
                        replay_requested,
                        worker_wake,
                    ) {
                        Ok(worker) => {
                            let _ = ready_tx.send(Ok(()));
                            if let Err(error) = worker.run() {
                                warn!(%error, "XEmbed tray worker stopped");
                            }
                        }
                        Err(error) => {
                            let _ = ready_tx.send(Err(error));
                        }
                    }
                }
            })
            .map_err(|error| XEmbedTrayError(format!("could not spawn XEmbed worker: {error}")))?;

        match ready_rx.recv_timeout(Duration::from_secs(3)) {
            Ok(Ok(())) => Ok(Self {
                commands,
                events,
                stopping,
                replay_requested,
                wake,
                worker: Some(worker),
            }),
            Ok(Err(error)) => {
                let _ = worker.join();
                Err(error)
            }
            Err(error) => {
                stopping.store(true, Ordering::Release);
                wake_worker(&wake);
                let _ = worker.join();
                Err(XEmbedTrayError(format!(
                    "XEmbed worker stopped during startup: {error}"
                )))
            }
        }
    }

    pub(super) fn try_event(&self) -> Option<XEmbedTrayEvent> {
        self.events.try_recv().ok()
    }

    pub(super) fn invoke(&self, command: XEmbedTrayCommand) -> bool {
        if command.window_id == 0
            || self
                .commands
                .try_send(WorkerCommand::Invoke(command))
                .is_err()
        {
            return false;
        }
        wake_worker(&self.wake);
        true
    }

    pub(super) fn request_replay(&self) {
        self.replay_requested.store(true, Ordering::Release);
        wake_worker(&self.wake);
    }
}

impl Drop for XEmbedTray {
    fn drop(&mut self) {
        self.stopping.store(true, Ordering::Release);
        wake_worker(&self.wake);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

enum WorkerCommand {
    Invoke(XEmbedTrayCommand),
}

fn wake_worker(wake: &UnixStream) {
    // A full nonblocking socket already contains a wake byte, so either a
    // successful write or WouldBlock guarantees that poll() will return.
    let _ = (&*wake).write(&[1]);
}

struct Atoms {
    manager: Atom,
    selection: Atom,
    opcode: Atom,
    orientation: Atom,
    visual: Atom,
    xembed: Atom,
    xembed_info: Atom,
    net_wm_name: Atom,
    utf8_string: Atom,
    wm_class: Atom,
}

impl Atoms {
    fn load(connection: &RustConnection) -> Result<Self, XEmbedTrayError> {
        Ok(Self {
            manager: intern(connection, "MANAGER")?,
            selection: intern(connection, "_NET_SYSTEM_TRAY_S0")?,
            opcode: intern(connection, "_NET_SYSTEM_TRAY_OPCODE")?,
            orientation: intern(connection, "_NET_SYSTEM_TRAY_ORIENTATION")?,
            visual: intern(connection, "_NET_SYSTEM_TRAY_VISUAL")?,
            xembed: intern(connection, "_XEMBED")?,
            xembed_info: intern(connection, "_XEMBED_INFO")?,
            net_wm_name: intern(connection, "_NET_WM_NAME")?,
            utf8_string: intern(connection, "UTF8_STRING")?,
            wm_class: intern(connection, "WM_CLASS")?,
        })
    }
}

struct HostedIcon {
    container: Window,
    colormap: Colormap,
    title: String,
    mapped: bool,
    published: bool,
    last_snapshot: Option<XEmbedTrayIcon>,
}

#[derive(Clone, Copy)]
struct XEmbedInfo {
    version: u32,
    mapped: bool,
}

impl Default for XEmbedInfo {
    fn default() -> Self {
        Self {
            version: XEMBED_VERSION,
            mapped: false,
        }
    }
}

struct Worker {
    connection: RustConnection,
    screen_index: usize,
    host: Window,
    atoms: Atoms,
    commands: Receiver<WorkerCommand>,
    events: SyncSender<XEmbedTrayEvent>,
    stopping: Arc<AtomicBool>,
    replay_requested: Arc<AtomicBool>,
    wake: UnixStream,
    icons: BTreeMap<Window, HostedIcon>,
    rejected: BTreeMap<Window, Instant>,
    pending_removals: BTreeSet<Window>,
    pending_replays: BTreeSet<Window>,
    next_snapshot: Instant,
}

impl Worker {
    fn connect(
        display_name: &str,
        commands: Receiver<WorkerCommand>,
        events: SyncSender<XEmbedTrayEvent>,
        stopping: Arc<AtomicBool>,
        replay_requested: Arc<AtomicBool>,
        wake: UnixStream,
    ) -> Result<Self, XEmbedTrayError> {
        let (connection, screen_index) = x11rb::connect(Some(display_name)).map_err(|error| {
            XEmbedTrayError(format!("could not connect to {display_name}: {error}"))
        })?;
        connection
            .composite_query_version(0, 4)
            .map_err(x11_error("could not query the X Composite extension"))?
            .reply()
            .map_err(x11_error("X Composite is unavailable"))?;
        let atoms = Atoms::load(&connection)?;
        let screen = &connection.setup().roots[screen_index];
        let host = connection
            .generate_id()
            .map_err(|error| XEmbedTrayError(format!("could not allocate tray window: {error}")))?;
        connection
            .create_window(
                COPY_DEPTH_FROM_PARENT,
                host,
                screen.root,
                i16::MIN,
                i16::MIN,
                ICON_SIZE,
                ICON_SIZE,
                0,
                WindowClass::INPUT_OUTPUT,
                COPY_FROM_PARENT,
                &CreateWindowAux::new().override_redirect(1).event_mask(
                    EventMask::STRUCTURE_NOTIFY
                        | EventMask::SUBSTRUCTURE_NOTIFY
                        | EventMask::PROPERTY_CHANGE,
                ),
            )
            .map_err(x11_error("could not create XEmbed tray window"))?
            .check()
            .map_err(x11_error("X server rejected the XEmbed tray window"))?;
        connection
            .change_property8(
                PropMode::REPLACE,
                host,
                atoms.net_wm_name,
                atoms.utf8_string,
                b"Denial XEmbed tray",
            )
            .map_err(x11_error("could not name XEmbed tray window"))?
            .check()
            .map_err(x11_error("X server rejected the XEmbed tray name"))?;
        connection
            .change_property8(
                PropMode::REPLACE,
                host,
                atoms.wm_class,
                AtomEnum::STRING,
                b"denial-xembed-tray\0denial-xembed-tray\0",
            )
            .map_err(x11_error("could not classify XEmbed tray window"))?
            .check()
            .map_err(x11_error("X server rejected the XEmbed tray class"))?;
        connection
            .change_property32(
                PropMode::REPLACE,
                host,
                atoms.orientation,
                AtomEnum::CARDINAL,
                &[0],
            )
            .map_err(x11_error("could not publish tray orientation"))?
            .check()
            .map_err(x11_error("X server rejected the tray orientation"))?;
        connection
            .change_property32(
                PropMode::REPLACE,
                host,
                atoms.visual,
                AtomEnum::VISUALID,
                &[preferred_tray_visual(screen)],
            )
            .map_err(x11_error("could not publish tray visual"))?
            .check()
            .map_err(x11_error("X server rejected the tray visual"))?;
        connection
            .set_selection_owner(host, atoms.selection, CURRENT_TIME)
            .map_err(x11_error("could not claim XEmbed tray selection"))?
            .check()
            .map_err(x11_error("X server rejected the tray selection owner"))?;
        connection
            .map_window(host)
            .map_err(x11_error("could not map XEmbed tray window"))?
            .check()
            .map_err(x11_error("X server rejected the XEmbed tray map"))?;
        connection
            .flush()
            .map_err(x11_error("could not flush XEmbed tray setup"))?;
        let owner = connection
            .get_selection_owner(atoms.selection)
            .map_err(x11_error("could not query XEmbed tray selection"))?
            .reply()
            .map_err(x11_error("could not read XEmbed tray selection"))?
            .owner;
        if owner != host {
            return Err(XEmbedTrayError(
                "another XEmbed tray manager already owns screen 0".into(),
            ));
        }
        connection
            .send_event(
                false,
                screen.root,
                EventMask::STRUCTURE_NOTIFY,
                ClientMessageEvent::new(
                    32,
                    screen.root,
                    atoms.manager,
                    [CURRENT_TIME, atoms.selection, host, 0, 0],
                ),
            )
            .map_err(x11_error("could not announce XEmbed tray manager"))?
            .check()
            .map_err(x11_error("X server rejected the tray manager announcement"))?;
        connection
            .flush()
            .map_err(x11_error("could not flush XEmbed tray announcement"))?;
        info!(display_name, window = host, "XEmbed tray host is ready");
        Ok(Self {
            connection,
            screen_index,
            host,
            atoms,
            commands,
            events,
            stopping,
            replay_requested,
            wake,
            icons: BTreeMap::new(),
            rejected: BTreeMap::new(),
            pending_removals: BTreeSet::new(),
            pending_replays: BTreeSet::new(),
            next_snapshot: Instant::now(),
        })
    }

    fn run(mut self) -> Result<(), XEmbedTrayError> {
        let result = self.run_loop();
        self.withdraw_icons();
        result
    }

    fn run_loop(&mut self) -> Result<(), XEmbedTrayError> {
        while !self.stopping.load(Ordering::Acquire) {
            self.flush_pending_removals();
            if self.replay_requested.swap(false, Ordering::AcqRel) {
                self.pending_replays.extend(
                    self.icons
                        .iter()
                        .filter_map(|(window, icon)| icon.mapped.then_some(*window)),
                );
            }
            self.flush_pending_replays();
            self.drain_x11_events()?;
            if Instant::now() >= self.next_snapshot {
                self.refresh_snapshots();
                self.next_snapshot = Instant::now() + SNAPSHOT_INTERVAL;
            }
            if !self.wait_for_activity()? {
                break;
            }
        }
        Ok(())
    }

    fn wait_for_activity(&mut self) -> Result<bool, XEmbedTrayError> {
        let timeout = self.next_snapshot.saturating_duration_since(Instant::now());
        let timeout_ms = if timeout.is_zero() {
            0
        } else {
            timeout.as_millis().saturating_add(1).min(i32::MAX as u128) as i32
        };
        let mut descriptors = [
            libc::pollfd {
                fd: self.connection.stream().as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: self.wake.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
        ];
        loop {
            let result = unsafe {
                libc::poll(
                    descriptors.as_mut_ptr(),
                    descriptors.len() as libc::nfds_t,
                    timeout_ms,
                )
            };
            if result >= 0 {
                break;
            }
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(XEmbedTrayError(format!(
                    "could not wait for XEmbed activity: {error}"
                )));
            }
        }

        if descriptors[1].revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0 {
            let mut bytes = [0_u8; 64];
            loop {
                match self.wake.read(&mut bytes) {
                    Ok(0) => break,
                    Ok(_) => {}
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                    Err(error) => {
                        return Err(XEmbedTrayError(format!(
                            "could not drain XEmbed worker wake pipe: {error}"
                        )));
                    }
                }
            }
        }

        loop {
            match self.commands.try_recv() {
                Ok(WorkerCommand::Invoke(command)) => self.invoke(command),
                Err(TryRecvError::Empty) => return Ok(true),
                Err(TryRecvError::Disconnected) => return Ok(false),
            }
        }
    }

    fn drain_x11_events(&mut self) -> Result<(), XEmbedTrayError> {
        loop {
            let event = self
                .connection
                .poll_for_event()
                .map_err(x11_error("could not poll XEmbed events"))?;
            let Some(event) = event else { break };
            match event {
                Event::ClientMessage(message)
                    if message.window == self.host && message.type_ == self.atoms.opcode =>
                {
                    let data = message.data.as_data32();
                    if data[1] == SYSTEM_TRAY_REQUEST_DOCK {
                        self.dock(data[2]);
                    }
                }
                Event::DestroyNotify(event) => self.remove(event.window, true),
                Event::ReparentNotify(event)
                    if self
                        .icons
                        .get(&event.window)
                        .is_some_and(|icon| event.parent != icon.container) =>
                {
                    self.remove(event.window, false);
                }
                Event::PropertyNotify(event) if self.icons.contains_key(&event.window) => {
                    if event.atom == self.atoms.xembed_info {
                        self.refresh_xembed_info(event.window);
                    } else if event.atom == self.atoms.net_wm_name
                        || event.atom == u32::from(AtomEnum::WM_NAME)
                    {
                        self.refresh_title(event.window);
                    }
                }
                Event::SelectionClear(event) if event.selection == self.atoms.selection => {
                    return Err(XEmbedTrayError(
                        "another XEmbed tray manager claimed screen 0".into(),
                    ));
                }
                _ => {}
            }
        }
        Ok(())
    }

    fn dock(&mut self, window: Window) {
        let now = Instant::now();
        self.rejected.retain(|_, expires_at| *expires_at > now);
        if window == NONE
            || self.icons.contains_key(&window)
            || self.rejected.contains_key(&window)
            || self.icons.len() >= MAX_ICONS
        {
            return;
        }
        let title = self.read_title(window);
        let xembed_info = self.read_xembed_info(window);
        self.pending_removals.remove(&window);
        let mut container_resource = None;
        let mut colormap_resource = None;
        let mut in_save_set = false;
        let mut redirected = false;
        let mut reparented = false;
        let result = (|| -> Result<(), XEmbedTrayError> {
            let attributes = self
                .connection
                .get_window_attributes(window)
                .map_err(x11_error("could not inspect XEmbed icon visual"))?
                .reply()
                .map_err(x11_error("could not read XEmbed icon visual"))?;
            let depth = self
                .connection
                .setup()
                .roots
                .get(self.screen_index)
                .and_then(|screen| {
                    screen
                        .allowed_depths
                        .iter()
                        .find(|depth| {
                            depth
                                .visuals
                                .iter()
                                .any(|visual| visual.visual_id == attributes.visual)
                        })
                        .map(|entry| entry.depth)
                })
                .ok_or_else(|| XEmbedTrayError("XEmbed icon uses an unknown visual".into()))?;
            let root = self.connection.setup().roots[self.screen_index].root;
            let container = self
                .connection
                .generate_id()
                .map_err(x11_error("could not allocate an XEmbed icon container"))?;
            let colormap = self
                .connection
                .generate_id()
                .map_err(x11_error("could not allocate an XEmbed icon colormap"))?;
            self.connection
                .create_colormap(ColormapAlloc::NONE, colormap, root, attributes.visual)
                .map_err(x11_error("could not create an XEmbed icon colormap"))?
                .check()
                .map_err(x11_error("X server rejected the XEmbed icon colormap"))?;
            colormap_resource = Some(colormap);
            self.connection
                .create_window(
                    depth,
                    container,
                    self.host,
                    (self.icons.len() as i16).saturating_mul(ICON_SIZE as i16),
                    0,
                    ICON_SIZE,
                    ICON_SIZE,
                    0,
                    WindowClass::INPUT_OUTPUT,
                    attributes.visual,
                    &CreateWindowAux::new()
                        .override_redirect(1)
                        .background_pixel(0)
                        .border_pixel(0)
                        .colormap(colormap)
                        .event_mask(EventMask::STRUCTURE_NOTIFY | EventMask::EXPOSURE),
                )
                .map_err(x11_error("could not create an XEmbed icon container"))?
                .check()
                .map_err(x11_error("X server rejected the XEmbed icon container"))?;
            container_resource = Some(container);
            self.connection
                .change_save_set(SetMode::INSERT, window)
                .map_err(x11_error("could not add XEmbed icon to save-set"))?
                .check()
                .map_err(x11_error("X server rejected the XEmbed icon save-set"))?;
            in_save_set = true;
            self.connection
                .change_window_attributes(
                    window,
                    &ChangeWindowAttributesAux::new().event_mask(
                        EventMask::STRUCTURE_NOTIFY
                            | EventMask::PROPERTY_CHANGE
                            | EventMask::EXPOSURE,
                    ),
                )
                .map_err(x11_error("could not select XEmbed icon events"))?
                .check()
                .map_err(x11_error("X server rejected the XEmbed icon event mask"))?;
            self.connection
                .composite_redirect_window(window, Redirect::AUTOMATIC)
                .map_err(x11_error("could not redirect the XEmbed icon"))?
                .check()
                .map_err(x11_error("could not activate XEmbed icon redirection"))?;
            redirected = true;
            self.connection
                .reparent_window(window, container, 0, 0)
                .map_err(x11_error("could not embed XEmbed icon"))?
                .check()
                .map_err(x11_error("X server rejected XEmbed icon reparenting"))?;
            reparented = true;
            self.connection
                .configure_window(
                    window,
                    &ConfigureWindowAux::new()
                        .x(0)
                        .y(0)
                        .width(u32::from(ICON_SIZE))
                        .height(u32::from(ICON_SIZE)),
                )
                .map_err(x11_error("could not size XEmbed icon"))?
                .check()
                .map_err(x11_error("X server rejected the XEmbed icon size"))?;
            let width = u32::from(ICON_SIZE).saturating_mul((self.icons.len() + 1) as u32);
            self.connection
                .configure_window(
                    self.host,
                    &ConfigureWindowAux::new()
                        .width(width)
                        .height(u32::from(ICON_SIZE)),
                )
                .map_err(x11_error("could not resize XEmbed tray host"))?
                .check()
                .map_err(x11_error("X server rejected the XEmbed tray size"))?;
            self.connection
                .map_window(container)
                .map_err(x11_error("could not map XEmbed icon container"))?
                .check()
                .map_err(x11_error("X server rejected the XEmbed container map"))?;
            self.connection
                .send_event(
                    false,
                    window,
                    EventMask::NO_EVENT,
                    ClientMessageEvent::new(
                        32,
                        window,
                        self.atoms.xembed,
                        [
                            CURRENT_TIME,
                            XEMBED_EMBEDDED_NOTIFY,
                            0,
                            container,
                            xembed_info.version.min(XEMBED_VERSION),
                        ],
                    ),
                )
                .map_err(x11_error("could not notify embedded X11 client"))?
                .check()
                .map_err(x11_error("X server rejected the XEmbed notification"))?;
            if xembed_info.mapped {
                self.connection
                    .map_window(window)
                    .map_err(x11_error("could not map XEmbed icon"))?
                    .check()
                    .map_err(x11_error("X server rejected the XEmbed icon map"))?;
            } else {
                self.connection
                    .unmap_window(window)
                    .map_err(x11_error("could not unmap hidden XEmbed icon"))?
                    .check()
                    .map_err(x11_error("X server rejected the XEmbed icon unmap"))?;
            }
            self.connection
                .flush()
                .map_err(x11_error("could not flush XEmbed docking"))?;
            Ok(())
        })();
        if let Err(error) = result {
            if redirected {
                let _ = self
                    .connection
                    .composite_unredirect_window(window, Redirect::AUTOMATIC);
            }
            if in_save_set {
                let _ = self.connection.change_save_set(SetMode::DELETE, window);
            }
            if reparented {
                let _ = self.connection.reparent_window(
                    window,
                    self.connection.setup().roots[self.screen_index].root,
                    0,
                    0,
                );
            }
            if let Some(container) = container_resource {
                let _ = self.connection.destroy_window(container);
            }
            if let Some(colormap) = colormap_resource {
                let _ = self.connection.free_colormap(colormap);
            }
            let _ = self.connection.flush();
            self.reject(window);
            warn!(%error, window, "could not dock XEmbed tray icon");
            return;
        }
        let Some(container) = container_resource else {
            return;
        };
        let Some(colormap) = colormap_resource else {
            return;
        };
        self.icons.insert(
            window,
            HostedIcon {
                container,
                colormap,
                title,
                mapped: xembed_info.mapped,
                published: false,
                last_snapshot: None,
            },
        );
        if xembed_info.mapped {
            self.publish_snapshot(window, XEmbedTrayEventKind::Added);
        }
        info!(window, "docked XEmbed tray icon");
    }

    fn reject(&mut self, window: Window) {
        if self.rejected.len() >= MAX_REJECTED_ICONS
            && let Some(oldest) = self
                .rejected
                .iter()
                .min_by_key(|(_, expires_at)| *expires_at)
                .map(|(window, _)| *window)
        {
            self.rejected.remove(&oldest);
        }
        self.rejected.insert(window, Instant::now() + REJECTION_TTL);
    }

    fn remove(&mut self, window: Window, destroyed: bool) {
        self.rejected.remove(&window);
        self.pending_replays.remove(&window);
        if let Some(icon) = self.icons.remove(&window) {
            if !destroyed {
                let _ = self
                    .connection
                    .composite_unredirect_window(window, Redirect::AUTOMATIC);
                let _ = self.connection.change_save_set(SetMode::DELETE, window);
            }
            let _ = self.connection.destroy_window(icon.container);
            let _ = self.connection.free_colormap(icon.colormap);
            let _ = self.connection.flush();
            if icon.published {
                self.publish_removed(window);
            }
            info!(window, "removed XEmbed tray icon");
        }
    }

    fn publish_removed(&mut self, window: Window) {
        if self
            .events
            .try_send(XEmbedTrayEvent {
                kind: XEmbedTrayEventKind::Removed,
                window_id: window,
                icon: None,
            })
            .is_err()
        {
            self.pending_removals.insert(window);
        }
    }

    fn flush_pending_removals(&mut self) {
        self.pending_removals.retain(|window| {
            self.events
                .try_send(XEmbedTrayEvent {
                    kind: XEmbedTrayEventKind::Removed,
                    window_id: *window,
                    icon: None,
                })
                .is_err()
        });
    }

    fn flush_pending_replays(&mut self) {
        let windows = self.pending_replays.iter().copied().collect::<Vec<_>>();
        for window in windows {
            let Some(mapped) = self.icons.get(&window).map(|icon| icon.mapped) else {
                self.pending_replays.remove(&window);
                continue;
            };
            if !mapped {
                self.pending_replays.remove(&window);
                continue;
            }
            let snapshot = self
                .icons
                .get(&window)
                .and_then(|icon| icon.last_snapshot.clone())
                .or_else(|| self.capture_snapshot(window));
            let Some(snapshot) = snapshot else {
                continue;
            };
            if self
                .events
                .try_send(XEmbedTrayEvent {
                    kind: XEmbedTrayEventKind::Added,
                    window_id: window,
                    icon: Some(snapshot.clone()),
                })
                .is_ok()
            {
                if let Some(hosted) = self.icons.get_mut(&window) {
                    hosted.published = true;
                    hosted.last_snapshot = Some(snapshot);
                }
                self.pending_replays.remove(&window);
            }
        }
    }

    fn withdraw_icons(&mut self) {
        let windows = std::mem::take(&mut self.icons);
        for (window, icon) in windows {
            let _ = self
                .connection
                .composite_unredirect_window(window, Redirect::AUTOMATIC);
            let _ = self.connection.change_save_set(SetMode::DELETE, window);
            let _ = self.connection.reparent_window(
                window,
                self.connection.setup().roots[self.screen_index].root,
                0,
                0,
            );
            let _ = self.connection.destroy_window(icon.container);
            let _ = self.connection.free_colormap(icon.colormap);
            let _ = self.events.try_send(XEmbedTrayEvent {
                kind: XEmbedTrayEventKind::Removed,
                window_id: window,
                icon: None,
            });
        }
        let _ = self.connection.flush();
    }

    fn refresh_snapshots(&mut self) {
        let windows = self
            .icons
            .iter()
            .filter_map(|(window, icon)| icon.mapped.then_some(*window))
            .collect::<Vec<_>>();
        for window in windows {
            self.publish_snapshot(window, XEmbedTrayEventKind::Updated);
        }
    }

    fn publish_snapshot(&mut self, window: Window, requested_kind: XEmbedTrayEventKind) {
        let Some(snapshot) = self.capture_snapshot(window) else {
            return;
        };
        let Some(hosted) = self.icons.get_mut(&window) else {
            return;
        };
        if !hosted.mapped {
            return;
        }
        let changed = hosted.last_snapshot.as_ref() != Some(&snapshot);
        if requested_kind == XEmbedTrayEventKind::Updated && !changed {
            return;
        }
        let kind = if hosted.published {
            requested_kind
        } else {
            XEmbedTrayEventKind::Added
        };
        let published = self
            .events
            .try_send(XEmbedTrayEvent {
                kind,
                window_id: window,
                icon: Some(snapshot.clone()),
            })
            .is_ok();
        if published {
            hosted.published = true;
            hosted.last_snapshot = Some(snapshot);
        } else if kind == XEmbedTrayEventKind::Added {
            self.pending_replays.insert(window);
        }
    }

    fn capture_snapshot(&self, window: Window) -> Option<XEmbedTrayIcon> {
        let title = self.icons.get(&window)?.title.clone();
        let (width, height, rgba) = self.read_pixels(window)?;
        Some(XEmbedTrayIcon {
            window_id: window,
            title,
            width,
            height,
            rgba,
        })
    }

    fn read_pixels(&self, window: Window) -> Option<(u32, u32, Vec<u8>)> {
        let geometry = self.connection.get_geometry(window).ok()?.reply().ok()?;
        let attributes = self
            .connection
            .get_window_attributes(window)
            .ok()?
            .reply()
            .ok()?;
        let width = geometry.width.min(ICON_SIZE);
        let height = geometry.height.min(ICON_SIZE);
        if width == 0
            || height == 0
            || usize::from(width) * usize::from(height) * 4 > MAX_ICON_BYTES
        {
            return None;
        }
        let pixmap = self.connection.generate_id().ok()?;
        let image = (|| {
            self.connection
                .composite_name_window_pixmap(window, pixmap)
                .ok()?
                .check()
                .ok()?;
            self.connection
                .get_image(ImageFormat::Z_PIXMAP, pixmap, 0, 0, width, height, u32::MAX)
                .ok()?
                .reply()
                .ok()
        })();
        if let Ok(cookie) = self.connection.free_pixmap(pixmap) {
            let _ = cookie.check();
        }
        let image = image?;
        let rgba = rgba_from_ximage(
            &self.connection,
            self.screen_index,
            attributes.visual,
            geometry.depth,
            width,
            height,
            &image.data,
        )?;
        Some((u32::from(width), u32::from(height), rgba))
    }

    fn refresh_title(&mut self, window: Window) {
        let title = self.read_title(window);
        if let Some(hosted) = self.icons.get_mut(&window)
            && hosted.title != title
        {
            hosted.title = title;
            hosted.last_snapshot = None;
        }
    }

    fn refresh_xembed_info(&mut self, window: Window) {
        let mapped = self.read_xembed_info(window).mapped;
        let Some(previous) = self.icons.get(&window).map(|icon| icon.mapped) else {
            return;
        };
        if mapped == previous {
            return;
        }
        let request = if mapped {
            self.connection.map_window(window)
        } else {
            self.connection.unmap_window(window)
        };
        let result = request
            .map_err(x11_error("could not update XEmbed mapped state"))
            .and_then(|cookie| {
                cookie
                    .check()
                    .map_err(x11_error("X server rejected the XEmbed mapped state"))
            });
        if let Err(error) = result {
            warn!(%error, window, mapped, "could not apply XEmbed mapped state");
            return;
        }
        let _ = self.connection.flush();
        if mapped {
            self.pending_removals.remove(&window);
            if let Some(hosted) = self.icons.get_mut(&window) {
                hosted.mapped = true;
                hosted.last_snapshot = None;
            }
            self.publish_snapshot(window, XEmbedTrayEventKind::Added);
        } else {
            self.pending_replays.remove(&window);
            let published = if let Some(hosted) = self.icons.get_mut(&window) {
                hosted.mapped = false;
                hosted.published
            } else {
                false
            };
            if published {
                self.publish_removed(window);
            }
            if let Some(hosted) = self.icons.get_mut(&window) {
                hosted.published = false;
            }
        }
    }

    fn read_xembed_info(&self, window: Window) -> XEmbedInfo {
        let Some(reply) = self
            .connection
            .get_property(
                false,
                window,
                self.atoms.xembed_info,
                self.atoms.xembed_info,
                0,
                2,
            )
            .ok()
            .and_then(|cookie| cookie.reply().ok())
        else {
            return XEmbedInfo::default();
        };
        let Some(mut values) = reply.value32() else {
            return XEmbedInfo::default();
        };
        let Some(version) = values.next() else {
            return XEmbedInfo::default();
        };
        let Some(flags) = values.next() else {
            return XEmbedInfo::default();
        };
        XEmbedInfo {
            version,
            mapped: flags & XEMBED_MAPPED != 0,
        }
    }

    fn read_title(&self, window: Window) -> String {
        for (property, kind) in [
            (self.atoms.net_wm_name, self.atoms.utf8_string),
            (AtomEnum::WM_NAME.into(), AtomEnum::STRING.into()),
        ] {
            if let Ok(cookie) = self
                .connection
                .get_property(false, window, property, kind, 0, 1024)
                && let Ok(reply) = cookie.reply()
                && !reply.value.is_empty()
            {
                return String::from_utf8_lossy(&reply.value)
                    .trim_matches(char::from(0))
                    .chars()
                    .take(256)
                    .collect();
            }
        }
        "X11 tray icon".into()
    }

    fn invoke(&self, command: XEmbedTrayCommand) {
        if !self
            .icons
            .get(&command.window_id)
            .is_some_and(|icon| icon.mapped)
        {
            return;
        }
        let button = match command.action {
            XEmbedTrayAction::Activate => ButtonIndex::M1,
            XEmbedTrayAction::SecondaryActivate => ButtonIndex::M2,
            XEmbedTrayAction::ContextMenu => ButtonIndex::M3,
        };
        let screen = &self.connection.setup().roots[self.screen_index];
        let root_x = command.x.clamp(i16::MIN.into(), i16::MAX.into()) as i16;
        let root_y = command.y.clamp(i16::MIN.into(), i16::MAX.into()) as i16;
        for (response_type, mask) in [
            (BUTTON_PRESS_EVENT, EventMask::BUTTON_PRESS),
            (BUTTON_RELEASE_EVENT, EventMask::BUTTON_RELEASE),
        ] {
            let event = ButtonPressEvent {
                response_type,
                detail: button.into(),
                sequence: 0,
                time: CURRENT_TIME,
                root: screen.root,
                event: command.window_id,
                child: NONE,
                root_x,
                root_y,
                event_x: (ICON_SIZE / 2) as i16,
                event_y: (ICON_SIZE / 2) as i16,
                state: KeyButMask::default(),
                same_screen: true,
            };
            if let Err(error) = self
                .connection
                .send_event(false, command.window_id, mask, event)
            {
                warn!(%error, window = command.window_id, "could not forward XEmbed click");
                return;
            }
        }
        let _ = self.connection.flush();
    }
}

fn intern(connection: &RustConnection, name: &str) -> Result<Atom, XEmbedTrayError> {
    connection
        .intern_atom(false, name.as_bytes())
        .map_err(x11_error("could not intern XEmbed atom"))?
        .reply()
        .map(|reply| reply.atom)
        .map_err(x11_error("could not read XEmbed atom"))
}

fn preferred_tray_visual(screen: &x11rb::protocol::xproto::Screen) -> u32 {
    screen
        .allowed_depths
        .iter()
        .find(|depth| depth.depth == 32)
        .and_then(|depth| {
            depth
                .visuals
                .iter()
                .find(|visual| visual.class == VisualClass::TRUE_COLOR)
        })
        .map_or(screen.root_visual, |visual| visual.visual_id)
}

fn x11_error<E: fmt::Display>(context: &'static str) -> impl FnOnce(E) -> XEmbedTrayError {
    move |error| XEmbedTrayError(format!("{context}: {error}"))
}

#[allow(clippy::too_many_arguments)]
fn rgba_from_ximage(
    connection: &RustConnection,
    screen_index: usize,
    visual_id: u32,
    depth: u8,
    width: u16,
    height: u16,
    data: &[u8],
) -> Option<Vec<u8>> {
    let setup = connection.setup();
    let screen = setup.roots.get(screen_index)?;
    let visual = screen
        .allowed_depths
        .iter()
        .flat_map(|entry| entry.visuals.iter())
        .find(|visual| visual.visual_id == visual_id)?;
    let format = setup
        .pixmap_formats
        .iter()
        .find(|format| format.depth == depth)?;
    let bits_per_pixel = usize::from(format.bits_per_pixel);
    if bits_per_pixel != 24 && bits_per_pixel != 32 {
        return None;
    }
    let row_bits = usize::from(width).checked_mul(bits_per_pixel)?;
    let pad = usize::from(format.scanline_pad);
    let row_stride = row_bits.div_ceil(pad).checked_mul(pad)?.div_ceil(8);
    if data.len() < row_stride.checked_mul(usize::from(height))? {
        return None;
    }
    let alpha_mask = if depth == 32 {
        !(visual.red_mask | visual.green_mask | visual.blue_mask)
    } else {
        0
    };
    let mut output = vec![0; usize::from(width) * usize::from(height) * 4];
    let mut any_alpha = false;
    for y in 0..usize::from(height) {
        for x in 0..usize::from(width) {
            let source = y * row_stride + x * bits_per_pixel / 8;
            let pixel = match (bits_per_pixel, setup.image_byte_order) {
                (32, ImageOrder::LSB_FIRST) => {
                    u32::from_le_bytes(data[source..source + 4].try_into().ok()?)
                }
                (32, _) => u32::from_be_bytes(data[source..source + 4].try_into().ok()?),
                (24, ImageOrder::LSB_FIRST) => {
                    u32::from_le_bytes([data[source], data[source + 1], data[source + 2], 0])
                }
                (24, _) => {
                    u32::from_be_bytes([0, data[source], data[source + 1], data[source + 2]])
                }
                _ => return None,
            };
            let target = (y * usize::from(width) + x) * 4;
            output[target] = extract_channel(pixel, visual.red_mask);
            output[target + 1] = extract_channel(pixel, visual.green_mask);
            output[target + 2] = extract_channel(pixel, visual.blue_mask);
            output[target + 3] = if alpha_mask == 0 {
                u8::MAX
            } else {
                extract_channel(pixel, alpha_mask)
            };
            any_alpha |= output[target + 3] != 0;
        }
    }
    if alpha_mask != 0 && !any_alpha {
        for alpha in output.iter_mut().skip(3).step_by(4) {
            *alpha = u8::MAX;
        }
    }
    Some(output)
}

fn extract_channel(pixel: u32, mask: u32) -> u8 {
    if mask == 0 {
        return 0;
    }
    let shift = mask.trailing_zeros();
    let maximum = mask >> shift;
    let value = (pixel & mask) >> shift;
    ((value * u32::from(u8::MAX) + maximum / 2) / maximum) as u8
}

#[cfg(test)]
#[path = "xembed_tray/tests.rs"]
mod tests;
