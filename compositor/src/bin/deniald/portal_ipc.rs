//! Non-blocking publication of committed desktop theme state.
//!
//! The compositor owns a private `SOCK_SEQPACKET` listener. A worker handles
//! peer authentication and I/O so a missing or stalled portal backend can
//! never delay input, rendering, or settings commits.

use std::error::Error;
use std::fs::{self, DirBuilder, File, OpenOptions, Permissions};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use denial_core::portal_protocol::{
    ClientMessage, DesktopAccentColor, DesktopThemeSnapshot, MAX_MESSAGE_BYTES, PORTAL_SOCKET_FILE,
    ServerMessage, decode_client_message, encode_server_message,
};
use tracing::{info, warn};

const SOCKET_DIRECTORY: &str = "denial";
const ACCENT_STATE_FILE: &str = "accent-color-v1";
const ACCENT_STATE_MAGIC: [u8; 8] = *b"DENACNT\0";
const ACCENT_STATE_BYTES: usize = 12;
const ACCENT_STATE_PERSIST_DEBOUNCE: Duration = Duration::from_millis(350);
static ACCENT_STATE_TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Clone)]
pub(super) struct PortalIpcPublisher {
    state: Arc<PublisherState>,
}

struct PublisherState {
    snapshot: Mutex<DesktopThemeSnapshot>,
    accent_state_generation: AtomicU64,
    stopping: AtomicBool,
    wake: OwnedFd,
}

impl PortalIpcPublisher {
    /// Replace the complete cached state. Only a portal-visible change wakes
    /// an established subscriber; unrelated revisions remain available to the
    /// next subscriber without producing a redundant update.
    pub(super) fn publish(&self, snapshot: DesktopThemeSnapshot) {
        let (changed, accent_changed) = {
            let mut current = self
                .state
                .snapshot
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if snapshot.revision < current.revision {
                return;
            }
            let accent_changed = snapshot.accent_color != current.accent_color;
            let changed =
                snapshot.portal_color_scheme != current.portal_color_scheme || accent_changed;
            *current = snapshot;
            (changed, accent_changed)
        };
        if accent_changed {
            self.state
                .accent_state_generation
                .fetch_add(1, Ordering::Release);
        }
        if changed {
            wake_worker(self.state.wake.as_raw_fd());
        }
    }

    pub(super) fn snapshot(&self) -> DesktopThemeSnapshot {
        *self
            .state
            .snapshot
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

pub(super) struct PortalIpcServer {
    socket_path: PathBuf,
    socket_device: u64,
    socket_inode: u64,
    publisher: PortalIpcPublisher,
    worker: Option<JoinHandle<()>>,
}

impl PortalIpcServer {
    pub(super) fn start(initial: DesktopThemeSnapshot) -> Result<Self, Box<dyn Error>> {
        let socket_path = default_socket_path()?;
        let accent_state_path = default_accent_state_path();
        let initial = match accent_state_path.as_deref().map(load_accent_state) {
            Some(Ok(Some(accent))) => initial.with_accent(accent),
            Some(Ok(None)) | None => initial,
            Some(Err(error)) => {
                warn!(%error, "could not load cached Denial accent; using the brand fallback");
                initial
            }
        };
        Self::start_at_with_state(socket_path, initial, accent_state_path)
    }

    #[cfg(test)]
    fn start_at(
        socket_path: PathBuf,
        initial: DesktopThemeSnapshot,
    ) -> Result<Self, Box<dyn Error>> {
        Self::start_at_with_state(socket_path, initial, None)
    }

    fn start_at_with_state(
        socket_path: PathBuf,
        initial: DesktopThemeSnapshot,
        accent_state_path: Option<PathBuf>,
    ) -> Result<Self, Box<dyn Error>> {
        prepare_socket_path(&socket_path)?;
        let listener = bind_seqpacket_listener(&socket_path)?;
        fs::set_permissions(&socket_path, Permissions::from_mode(0o600))?;
        let metadata = fs::symlink_metadata(&socket_path)?;
        let wake = create_eventfd()?;
        let state = Arc::new(PublisherState {
            snapshot: Mutex::new(initial),
            accent_state_generation: AtomicU64::new(0),
            stopping: AtomicBool::new(false),
            wake,
        });
        let publisher = PortalIpcPublisher {
            state: Arc::clone(&state),
        };
        let worker = thread::Builder::new()
            .name("denial-portal-ipc".into())
            .spawn(move || {
                crate::cpu_scheduling::normalize_current_worker("portal-ipc");
                serve(listener, state, accent_state_path);
            })?;
        info!(
            path = %socket_path.display(),
            "Denial portal IPC listening"
        );
        Ok(Self {
            socket_path,
            socket_device: metadata.dev(),
            socket_inode: metadata.ino(),
            publisher,
            worker: Some(worker),
        })
    }

    pub(super) fn publisher(&self) -> PortalIpcPublisher {
        self.publisher.clone()
    }
}

impl Drop for PortalIpcServer {
    fn drop(&mut self) {
        self.publisher.state.stopping.store(true, Ordering::Release);
        wake_worker(self.publisher.state.wake.as_raw_fd());
        if let Some(worker) = self.worker.take()
            && worker.join().is_err()
        {
            warn!("Denial portal IPC worker panicked during shutdown");
        }
        let owned_socket = fs::symlink_metadata(&self.socket_path)
            .ok()
            .is_some_and(|metadata| {
                metadata.file_type().is_socket()
                    && metadata.dev() == self.socket_device
                    && metadata.ino() == self.socket_inode
            });
        if owned_socket
            && let Err(error) = fs::remove_file(&self.socket_path)
            && error.kind() != io::ErrorKind::NotFound
        {
            warn!(path = %self.socket_path.display(), %error, "could not remove portal IPC socket");
        }
    }
}

fn serve(listener: OwnedFd, state: Arc<PublisherState>, accent_state_path: Option<PathBuf>) {
    let mut client: Option<Client> = None;
    // Generation zero is the persisted baseline established at startup. Do
    // not sample the current generation here: publishers may win the worker
    // startup race, and their first burst must still schedule a durable write.
    let mut observed_accent_generation = 0;
    let mut accent_persist_deadline: Option<Instant> = None;
    loop {
        let mut poll_fds = [
            libc::pollfd {
                fd: listener.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: state.wake.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: client.as_ref().map_or(-1, |client| client.fd.as_raw_fd()),
                events: libc::POLLIN
                    | if client.as_ref().is_some_and(|client| client.pending) {
                        libc::POLLOUT
                    } else {
                        0
                    },
                revents: 0,
            },
        ];
        // SAFETY: the array contains initialized pollfd records and every
        // non-negative descriptor remains owned for the duration of the call.
        let timeout = accent_persist_deadline.map_or(-1, |deadline| {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                0
            } else {
                remaining.as_millis().clamp(1, i32::MAX as u128) as i32
            }
        });
        let ready = unsafe {
            libc::poll(
                poll_fds.as_mut_ptr(),
                poll_fds.len() as libc::nfds_t,
                timeout,
            )
        };
        if ready < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            warn!(%error, "portal IPC poll failed");
            break;
        }
        if poll_fds[1].revents != 0 {
            drain_eventfd(state.wake.as_raw_fd());
            if let Some(client) = client.as_mut()
                && client.ready
            {
                client.pending = true;
            }
        }
        let accent_generation = state.accent_state_generation.load(Ordering::Acquire);
        if accent_generation != observed_accent_generation {
            observed_accent_generation = accent_generation;
            accent_persist_deadline = Some(Instant::now() + ACCENT_STATE_PERSIST_DEBOUNCE);
        }
        if state.stopping.load(Ordering::Acquire) {
            if accent_persist_deadline.is_some() {
                persist_current_accent(&state, accent_state_path.as_deref());
            }
            break;
        }
        if accent_persist_deadline.is_some_and(|deadline| Instant::now() >= deadline) {
            let accent_generation = state.accent_state_generation.load(Ordering::Acquire);
            if accent_generation == observed_accent_generation {
                persist_current_accent(&state, accent_state_path.as_deref());
                accent_persist_deadline = None;
            } else {
                observed_accent_generation = accent_generation;
                accent_persist_deadline = Some(Instant::now() + ACCENT_STATE_PERSIST_DEBOUNCE);
            }
        }
        let client_revents = poll_fds[2].revents;
        if client_revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0 {
            client = None;
            continue;
        }
        if client_revents & libc::POLLIN != 0
            && let Some(active) = client.as_mut()
        {
            match receive_client_message(active.fd.as_raw_fd()) {
                Ok(ClientMessage::Hello) if !active.ready => {
                    active.ready = true;
                    active.pending = true;
                }
                Ok(_) => client = None,
                Err(error) => {
                    warn!(%error, "portal IPC client sent an invalid message");
                    client = None;
                }
            }
        }
        // Process the established peer before accepting another connection.
        // D-Bus activation can briefly launch two helpers; a late connection
        // must never steal the authenticated stream from the name owner.
        if poll_fds[0].revents & libc::POLLIN != 0 {
            match accept_same_user(listener.as_raw_fd()) {
                Ok(Some(fd)) if client.is_none() => client = Some(Client::new(fd)),
                Ok(Some(_)) => warn!("ignored duplicate Denial portal IPC connection"),
                Ok(None) => {}
                Err(error) => warn!(%error, "rejected portal IPC connection"),
            }
        }
        if client_revents & libc::POLLOUT != 0
            || client.as_ref().is_some_and(|client| client.pending)
        {
            let snapshot = *state
                .snapshot
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if let Some(active) = client.as_mut()
                && active.ready
            {
                match send_snapshot(active.fd.as_raw_fd(), snapshot) {
                    Ok(true) => active.pending = false,
                    Ok(false) => active.pending = true,
                    Err(error) => {
                        warn!(%error, "portal IPC client disconnected during publication");
                        client = None;
                    }
                }
            }
        }
    }
}

fn persist_current_accent(state: &PublisherState, path: Option<&Path>) {
    let Some(path) = path else {
        return;
    };
    let accent = state
        .snapshot
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .accent_color;
    if let Err(error) = persist_accent_state(path, accent) {
        warn!(%error, path = %path.display(), "could not cache Denial accent");
    }
}

struct Client {
    fd: OwnedFd,
    ready: bool,
    pending: bool,
}

impl Client {
    fn new(fd: OwnedFd) -> Self {
        Self {
            fd,
            ready: false,
            pending: false,
        }
    }
}

fn receive_client_message(fd: RawFd) -> io::Result<ClientMessage> {
    let mut bytes = [0u8; MAX_MESSAGE_BYTES + 1];
    // SAFETY: `bytes` is writable for its full length and `fd` is an owned
    // connected seqpacket descriptor held by the worker.
    let received = unsafe {
        libc::recv(
            fd,
            bytes.as_mut_ptr().cast(),
            bytes.len(),
            libc::MSG_DONTWAIT,
        )
    };
    if received == 0 {
        return Err(io::Error::new(
            io::ErrorKind::ConnectionReset,
            "portal peer closed",
        ));
    }
    if received < 0 {
        return Err(io::Error::last_os_error());
    }
    decode_client_message(&bytes[..received as usize])
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

fn send_snapshot(fd: RawFd, snapshot: DesktopThemeSnapshot) -> io::Result<bool> {
    let bytes = encode_server_message(ServerMessage::ThemeSnapshot(snapshot));
    // SAFETY: the encoded record is readable for its full length and `fd` is
    // a connected seqpacket descriptor. MSG_NOSIGNAL contains peer teardown.
    let sent = unsafe {
        libc::send(
            fd,
            bytes.as_ptr().cast(),
            bytes.len(),
            libc::MSG_DONTWAIT | libc::MSG_NOSIGNAL,
        )
    };
    if sent < 0 {
        let error = io::Error::last_os_error();
        if error.kind() == io::ErrorKind::WouldBlock {
            return Ok(false);
        }
        return Err(error);
    }
    if sent as usize != bytes.len() {
        return Err(io::Error::new(
            io::ErrorKind::WriteZero,
            "partial seqpacket write",
        ));
    }
    Ok(true)
}

fn accept_same_user(listener: RawFd) -> io::Result<Option<OwnedFd>> {
    // SAFETY: `listener` is a live listening descriptor. accept4 returns a new
    // owned descriptor on success.
    let raw = unsafe {
        libc::accept4(
            listener,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC,
        )
    };
    if raw < 0 {
        let error = io::Error::last_os_error();
        if error.kind() == io::ErrorKind::WouldBlock {
            return Ok(None);
        }
        return Err(error);
    }
    // SAFETY: accept4 returned a unique descriptor which this OwnedFd adopts.
    let fd = unsafe { OwnedFd::from_raw_fd(raw) };
    let credentials = peer_credentials(fd.as_raw_fd())?;
    // SAFETY: getuid has no preconditions and does not mutate memory.
    let current_uid = unsafe { libc::getuid() };
    if credentials.uid != current_uid {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "portal IPC peer belongs to a different user",
        ));
    }
    Ok(Some(fd))
}

fn peer_credentials(fd: RawFd) -> io::Result<libc::ucred> {
    // SAFETY: zero is a valid initial representation for ucred before the
    // kernel overwrites it through getsockopt.
    let mut credentials: libc::ucred = unsafe { std::mem::zeroed() };
    let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: both pointers reference writable initialized storage with the
    // exact length supplied to getsockopt.
    let result = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut credentials as *mut libc::ucred).cast(),
            &mut length,
        )
    };
    if result < 0 {
        return Err(io::Error::last_os_error());
    }
    if length as usize != std::mem::size_of::<libc::ucred>() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "unexpected peer credential size",
        ));
    }
    Ok(credentials)
}

fn create_eventfd() -> io::Result<OwnedFd> {
    // SAFETY: eventfd has no pointer arguments; flags request nonblocking
    // close-on-exec ownership.
    let raw = unsafe { libc::eventfd(0, libc::EFD_NONBLOCK | libc::EFD_CLOEXEC) };
    if raw < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: eventfd returned a unique descriptor which this OwnedFd adopts.
    Ok(unsafe { OwnedFd::from_raw_fd(raw) })
}

fn wake_worker(fd: RawFd) {
    let value = 1u64.to_ne_bytes();
    // SAFETY: `value` is readable for eight bytes and fd is an eventfd. A full
    // counter already represents the required wakeup, so errors are harmless.
    let _ = unsafe { libc::write(fd, value.as_ptr().cast(), value.len()) };
}

fn drain_eventfd(fd: RawFd) {
    let mut value = [0u8; 8];
    loop {
        // SAFETY: `value` is writable for eight bytes and fd is an eventfd.
        let read = unsafe { libc::read(fd, value.as_mut_ptr().cast(), value.len()) };
        if read < 0 && io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
            continue;
        }
        break;
    }
}

fn bind_seqpacket_listener(path: &Path) -> io::Result<OwnedFd> {
    let fd = create_seqpacket_socket()?;
    let (address, length) = unix_address(path)?;
    // SAFETY: address points to a fully initialized sockaddr_un and length
    // covers the family, pathname bytes, and terminating NUL.
    if unsafe {
        libc::bind(
            fd.as_raw_fd(),
            (&address as *const libc::sockaddr_un).cast(),
            length,
        )
    } < 0
    {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: fd is a bound seqpacket socket; the backlog is bounded.
    if unsafe { libc::listen(fd.as_raw_fd(), 4) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(fd)
}

fn create_seqpacket_socket() -> io::Result<OwnedFd> {
    // SAFETY: socket has no pointer arguments. The returned descriptor is
    // uniquely owned on success.
    let raw = unsafe {
        libc::socket(
            libc::AF_UNIX,
            libc::SOCK_SEQPACKET | libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC,
            0,
        )
    };
    if raw < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: socket returned a unique descriptor which this OwnedFd adopts.
    Ok(unsafe { OwnedFd::from_raw_fd(raw) })
}

fn unix_address(path: &Path) -> io::Result<(libc::sockaddr_un, libc::socklen_t)> {
    let bytes = path.as_os_str().as_bytes();
    // SAFETY: zero initialization is the required starting representation for
    // sockaddr_un; all fields read by bind are filled below.
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    if bytes.len() >= address.sun_path.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "portal IPC socket path is too long",
        ));
    }
    address.sun_family = libc::AF_UNIX as libc::sa_family_t;
    // SAFETY: the length check above proves the destination has enough room;
    // the zeroed trailing byte provides pathname termination.
    unsafe {
        std::ptr::copy_nonoverlapping(
            bytes.as_ptr(),
            address.sun_path.as_mut_ptr().cast(),
            bytes.len(),
        );
    }
    let length = std::mem::offset_of!(libc::sockaddr_un, sun_path) + bytes.len() + 1;
    Ok((address, length as libc::socklen_t))
}

fn default_accent_state_path() -> Option<PathBuf> {
    let root = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| {
            std::env::var_os("HOME")
                .map(PathBuf::from)
                .filter(|path| path.is_absolute())
                .map(|home| home.join(".local/state"))
        })?;
    Some(root.join(SOCKET_DIRECTORY).join(ACCENT_STATE_FILE))
}

fn load_accent_state(path: &Path) -> io::Result<Option<DesktopAccentColor>> {
    let file = match File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    let mut bytes = Vec::with_capacity(ACCENT_STATE_BYTES + 1);
    file.take((ACCENT_STATE_BYTES + 1) as u64)
        .read_to_end(&mut bytes)?;
    if bytes.len() != ACCENT_STATE_BYTES || bytes[..8] != ACCENT_STATE_MAGIC || bytes[8] != 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid Denial accent state",
        ));
    }
    Ok(Some(DesktopAccentColor::new(
        bytes[9], bytes[10], bytes[11],
    )))
}

fn persist_accent_state(path: &Path, accent: DesktopAccentColor) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "accent state has no parent"))?;
    match fs::symlink_metadata(parent) {
        Ok(metadata) if metadata.file_type().is_dir() => {
            fs::set_permissions(parent, Permissions::from_mode(0o700))?;
        }
        Ok(_) => {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "accent state parent is not a directory",
            ));
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(parent)?;
        }
        Err(error) => return Err(error),
    }

    let mut bytes = [0u8; ACCENT_STATE_BYTES];
    bytes[..8].copy_from_slice(&ACCENT_STATE_MAGIC);
    bytes[8] = 1;
    bytes[9] = accent.red;
    bytes[10] = accent.green;
    bytes[11] = accent.blue;

    let sequence = ACCENT_STATE_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let temp = parent.join(format!(
        ".{ACCENT_STATE_FILE}.{}-{sequence}.tmp",
        std::process::id()
    ));
    let result = (|| -> io::Result<()> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temp)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        fs::rename(&temp, path)?;
        File::open(parent)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}

fn default_socket_path() -> Result<PathBuf, Box<dyn Error>> {
    let runtime = std::env::var_os("XDG_RUNTIME_DIR")
        .ok_or("XDG_RUNTIME_DIR is required for Denial portal IPC")?;
    let runtime = PathBuf::from(runtime);
    if !runtime.is_absolute() {
        return Err("XDG_RUNTIME_DIR must be an absolute path".into());
    }
    let directory = runtime.join(SOCKET_DIRECTORY);
    match fs::symlink_metadata(&directory) {
        Ok(metadata) if metadata.file_type().is_dir() => {
            fs::set_permissions(&directory, Permissions::from_mode(0o700))?;
        }
        Ok(_) => return Err(format!("{} is not a directory", directory.display()).into()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            DirBuilder::new().mode(0o700).create(&directory)?;
        }
        Err(error) => return Err(error.into()),
    }
    Ok(directory.join(PORTAL_SOCKET_FILE))
}

fn prepare_socket_path(path: &Path) -> Result<(), Box<dyn Error>> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.into()),
    };
    if !metadata.file_type().is_socket() {
        return Err(format!("refusing to replace non-socket path {}", path.display()).into());
    }
    let probe = create_seqpacket_socket()?;
    let (address, length) = unix_address(path)?;
    // SAFETY: address is initialized by unix_address and probe remains alive.
    let result = unsafe {
        libc::connect(
            probe.as_raw_fd(),
            (&address as *const libc::sockaddr_un).cast(),
            length,
        )
    };
    if result == 0 {
        return Err(format!(
            "another portal IPC server is listening at {}",
            path.display()
        )
        .into());
    }
    let error = io::Error::last_os_error();
    if matches!(
        error.kind(),
        io::ErrorKind::ConnectionRefused | io::ErrorKind::NotFound
    ) {
        fs::remove_file(path)?;
        Ok(())
    } else {
        Err(format!("could not inspect stale portal socket: {error}").into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use denial_core::portal_protocol::{
        DesktopAccentColor, DesktopColorSchemePreference, decode_server_message,
        encode_client_message,
    };
    use std::sync::atomic::AtomicU64;

    static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

    struct TemporaryDirectory(PathBuf);

    impl TemporaryDirectory {
        fn new() -> Self {
            let sequence = TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "denial-portal-ipc-test-{}-{sequence}",
                std::process::id()
            ));
            fs::create_dir(&path).expect("create temporary portal directory");
            Self(path)
        }
    }

    impl Drop for TemporaryDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn subscriber_receives_initial_and_coalesced_relevant_snapshots() {
        let temporary = TemporaryDirectory::new();
        let path = temporary.0.join("portal.sock");
        let server = PortalIpcServer::start_at(
            path.clone(),
            DesktopThemeSnapshot::new(1, DesktopColorSchemePreference::PreferDark),
        )
        .expect("start portal IPC server");
        let client = connect_client(&path);
        let hello = encode_client_message(ClientMessage::Hello);
        send_test_record(client.as_raw_fd(), &hello);
        assert_eq!(
            receive_test_snapshot(client.as_raw_fd()),
            DesktopThemeSnapshot::new(1, DesktopColorSchemePreference::PreferDark)
        );

        // Opening a second peer is sufficient to exercise the duplicate
        // connection path. The worker may reject it before it can send a
        // record, which is the expected behavior and not a test failure.
        let _duplicate = connect_client(&path);

        let publisher = server.publisher();
        let accented = DesktopThemeSnapshot::new(1, DesktopColorSchemePreference::PreferDark)
            .with_accent(DesktopAccentColor::new(0x12, 0x34, 0x56));
        publisher.publish(accented);
        assert_eq!(receive_test_snapshot(client.as_raw_fd()), accented);

        publisher.publish(DesktopThemeSnapshot::new(
            2,
            DesktopColorSchemePreference::PreferLight,
        ));
        assert_eq!(
            receive_test_snapshot(client.as_raw_fd()),
            DesktopThemeSnapshot::new(2, DesktopColorSchemePreference::PreferLight)
        );

        publisher.publish(DesktopThemeSnapshot::new(
            3,
            DesktopColorSchemePreference::PreferLight,
        ));
        assert!(!poll_readable(client.as_raw_fd(), 40));

        publisher.publish(DesktopThemeSnapshot::new(
            4,
            DesktopColorSchemePreference::NoPreference,
        ));
        assert_eq!(
            receive_test_snapshot(client.as_raw_fd()),
            DesktopThemeSnapshot::new(4, DesktopColorSchemePreference::NoPreference)
        );

        drop(client);
        let replacement = connect_client(&path);
        send_test_record(replacement.as_raw_fd(), &hello);
        assert_eq!(
            receive_test_snapshot(replacement.as_raw_fd()),
            DesktopThemeSnapshot::new(4, DesktopColorSchemePreference::NoPreference)
        );
        publisher.publish(DesktopThemeSnapshot::new(
            5,
            DesktopColorSchemePreference::PreferDark,
        ));
        assert_eq!(
            receive_test_snapshot(replacement.as_raw_fd()),
            DesktopThemeSnapshot::new(5, DesktopColorSchemePreference::PreferDark)
        );

        drop(server);
        assert!(!path.exists());
    }

    #[test]
    fn accent_state_round_trips_through_the_bounded_atomic_cache() {
        let temporary = TemporaryDirectory::new();
        let path = temporary.0.join("state/accent");
        let accent = DesktopAccentColor::new(0xab, 0xcd, 0xef);
        persist_accent_state(&path, accent).expect("persist accent state");
        assert_eq!(
            load_accent_state(&path).expect("load accent state"),
            Some(accent)
        );
    }

    #[test]
    fn accent_state_writes_are_debounced_and_shutdown_flushes_the_latest_value() {
        let temporary = TemporaryDirectory::new();
        let socket_path = temporary.0.join("portal.sock");
        let state_path = temporary.0.join("state/accent");
        let server = PortalIpcServer::start_at_with_state(
            socket_path,
            DesktopThemeSnapshot::new(1, DesktopColorSchemePreference::PreferDark),
            Some(state_path.clone()),
        )
        .expect("start portal IPC server");
        let publisher = server.publisher();
        publisher.publish(
            DesktopThemeSnapshot::new(2, DesktopColorSchemePreference::PreferDark)
                .with_accent(DesktopAccentColor::new(0x12, 0x34, 0x56)),
        );
        publisher.publish(
            DesktopThemeSnapshot::new(3, DesktopColorSchemePreference::PreferDark)
                .with_accent(DesktopAccentColor::new(0xab, 0xcd, 0xef)),
        );

        thread::sleep(Duration::from_millis(40));
        assert!(
            !state_path.exists(),
            "accent cache was written before debounce"
        );

        drop(server);
        assert_eq!(
            load_accent_state(&state_path).expect("load shutdown-flushed accent state"),
            Some(DesktopAccentColor::new(0xab, 0xcd, 0xef))
        );
    }

    fn connect_client(path: &Path) -> OwnedFd {
        let client = create_seqpacket_socket().expect("create seqpacket client");
        let (address, length) = unix_address(path).expect("build Unix address");
        // SAFETY: address is initialized and client remains owned by the test.
        let result = unsafe {
            libc::connect(
                client.as_raw_fd(),
                (&address as *const libc::sockaddr_un).cast(),
                length,
            )
        };
        assert_eq!(
            result,
            0,
            "connect portal test client: {}",
            io::Error::last_os_error()
        );
        client
    }

    fn send_test_record(fd: RawFd, bytes: &[u8]) {
        assert!(
            poll_writable(fd, 1000),
            "portal client never became writable"
        );
        loop {
            // SAFETY: bytes is readable and fd is a connected test socket.
            let sent =
                unsafe { libc::send(fd, bytes.as_ptr().cast(), bytes.len(), libc::MSG_NOSIGNAL) };
            if sent >= 0 {
                assert_eq!(sent as usize, bytes.len());
                return;
            }
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            panic!("send portal test record: {error}");
        }
    }

    fn receive_test_snapshot(fd: RawFd) -> DesktopThemeSnapshot {
        assert!(poll_readable(fd, 1000), "portal snapshot timed out");
        let mut bytes = [0u8; MAX_MESSAGE_BYTES];
        // SAFETY: bytes is writable and fd is a connected test socket.
        let received = unsafe { libc::recv(fd, bytes.as_mut_ptr().cast(), bytes.len(), 0) };
        assert!(received > 0, "receive portal snapshot");
        match decode_server_message(&bytes[..received as usize]).expect("decode portal snapshot") {
            ServerMessage::ThemeSnapshot(snapshot) => snapshot,
        }
    }

    fn poll_readable(fd: RawFd, timeout_milliseconds: i32) -> bool {
        let mut poll_fd = libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: poll_fd is initialized and fd remains owned by the test.
        let ready = unsafe { libc::poll(&mut poll_fd, 1, timeout_milliseconds) };
        ready > 0 && poll_fd.revents & libc::POLLIN != 0
    }

    fn poll_writable(fd: RawFd, timeout_milliseconds: i32) -> bool {
        let mut poll_fd = libc::pollfd {
            fd,
            events: libc::POLLOUT,
            revents: 0,
        };
        // SAFETY: poll_fd is initialized and fd remains owned by the test.
        let ready = unsafe { libc::poll(&mut poll_fd, 1, timeout_milliseconds) };
        ready > 0 && poll_fd.revents & libc::POLLOUT != 0
    }
}
