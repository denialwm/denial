#![deny(unsafe_op_in_unsafe_fn)]
#![deny(clippy::undocumented_unsafe_blocks)]

use std::collections::HashMap;
use std::error::Error;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, RwLock};
use std::thread;
use std::time::{Duration, Instant};

use denial_core::portal_protocol::{
    ClientMessage, DesktopThemeSnapshot, MAX_MESSAGE_BYTES, PORTAL_SOCKET_FILE, ServerMessage,
    decode_server_message, encode_client_message,
};
use tracing::info;
use zbus::blocking::Connection;
use zbus::blocking::connection::Builder as ConnectionBuilder;
use zbus::zvariant::{OwnedValue, Structure};

const SERVICE_NAME: &str = "org.freedesktop.impl.portal.desktop.denial";
#[cfg(test)]
const FRONTEND_SERVICE_NAME: &str = "org.freedesktop.portal.Desktop";
const OBJECT_PATH: &str = "/org/freedesktop/portal/desktop";
const INTERFACE_NAME: &str = "org.freedesktop.impl.portal.Settings";
const APPEARANCE_NAMESPACE: &str = "org.freedesktop.appearance";
const COLOR_SCHEME_KEY: &str = "color-scheme";
const ACCENT_COLOR_KEY: &str = "accent-color";
const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);
const RETRY_INTERVAL: Duration = Duration::from_millis(40);

type SettingsValues = HashMap<String, HashMap<String, OwnedValue>>;

#[derive(Clone, Copy)]
struct Cache {
    snapshot: DesktopThemeSnapshot,
}

struct SettingsInterface {
    cache: Arc<RwLock<Cache>>,
}

#[derive(Debug, zbus::DBusError)]
#[zbus(prefix = "org.freedesktop.portal.Error", impl_display = true)]
enum SettingsError {
    NotFound(String),
}

#[zbus::interface(
    name = "org.freedesktop.impl.portal.Settings",
    spawn = false,
    introspection_docs = false
)]
impl SettingsInterface {
    #[zbus(name = "Read", out_args("value"))]
    fn read(&self, namespace: &str, key: &str) -> Result<OwnedValue, SettingsError> {
        if namespace == APPEARANCE_NAMESPACE {
            let snapshot = self.snapshot();
            match key {
                COLOR_SCHEME_KEY => return Ok(OwnedValue::from(snapshot.portal_color_scheme)),
                ACCENT_COLOR_KEY => return Ok(accent_color_value(snapshot.accent_color)),
                _ => {}
            }
        }
        Err(SettingsError::NotFound(format!(
            "unknown setting {namespace}/{key}"
        )))
    }

    #[zbus(name = "ReadAll", out_args("value"))]
    fn read_all(&self, namespaces: Vec<String>) -> SettingsValues {
        if !namespace_matches(&namespaces, APPEARANCE_NAMESPACE) {
            return HashMap::new();
        }
        let snapshot = self.snapshot();
        HashMap::from([(
            APPEARANCE_NAMESPACE.to_owned(),
            HashMap::from([
                (
                    COLOR_SCHEME_KEY.to_owned(),
                    OwnedValue::from(snapshot.portal_color_scheme),
                ),
                (
                    ACCENT_COLOR_KEY.to_owned(),
                    accent_color_value(snapshot.accent_color),
                ),
            ]),
        )])
    }

    #[zbus(property, name = "version")]
    fn version(&self) -> u32 {
        1
    }

    #[zbus(signal, name = "SettingChanged")]
    async fn setting_changed(
        signal_emitter: &zbus::object_server::SignalEmitter<'_>,
        namespace: &str,
        key: &str,
        value: OwnedValue,
    ) -> zbus::Result<()>;
}

impl SettingsInterface {
    fn snapshot(&self) -> DesktopThemeSnapshot {
        self.cache
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .snapshot
    }
}

fn accent_color_value(accent: denial_core::portal_protocol::DesktopAccentColor) -> OwnedValue {
    OwnedValue::try_from(Structure::from(accent.portal_value()))
        .expect("an owned f64 accent structure is always representable")
}

fn main() -> Result<(), Box<dyn Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .with_target(false)
        .init();

    let (socket, initial) = connect_to_compositor(CONNECT_TIMEOUT)?;
    let cache = Arc::new(RwLock::new(Cache { snapshot: initial }));
    let connection = ConnectionBuilder::session()?
        .name(SERVICE_NAME)?
        .serve_at(
            OBJECT_PATH,
            SettingsInterface {
                cache: Arc::clone(&cache),
            },
        )?
        .build()?;
    info!(
        service = SERVICE_NAME,
        revision = initial.revision,
        color_scheme = initial.portal_color_scheme,
        accent = format_args!("#{:06x}", initial.accent_color.srgb24()),
        "Denial Settings portal backend ready"
    );

    receive_updates(socket, &connection, &cache)
}

fn receive_updates(
    socket: OwnedFd,
    connection: &Connection,
    cache: &RwLock<Cache>,
) -> Result<(), Box<dyn Error>> {
    loop {
        let Some(snapshot) = receive_snapshot(socket.as_raw_fd())? else {
            return Err(io::Error::new(
                io::ErrorKind::ConnectionReset,
                "Denial compositor disconnected from portal backend",
            )
            .into());
        };
        let changed = apply_snapshot(cache, snapshot);
        if changed.color_scheme {
            connection.emit_signal(
                None::<&str>,
                OBJECT_PATH,
                INTERFACE_NAME,
                "SettingChanged",
                &(
                    APPEARANCE_NAMESPACE,
                    COLOR_SCHEME_KEY,
                    OwnedValue::from(snapshot.portal_color_scheme),
                ),
            )?;
        }
        if changed.accent_color {
            connection.emit_signal(
                None::<&str>,
                OBJECT_PATH,
                INTERFACE_NAME,
                "SettingChanged",
                &(
                    APPEARANCE_NAMESPACE,
                    ACCENT_COLOR_KEY,
                    accent_color_value(snapshot.accent_color),
                ),
            )?;
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct ChangedSettings {
    color_scheme: bool,
    accent_color: bool,
}

fn apply_snapshot(cache: &RwLock<Cache>, snapshot: DesktopThemeSnapshot) -> ChangedSettings {
    let mut cached = cache
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if snapshot.revision < cached.snapshot.revision {
        return ChangedSettings::default();
    }
    let changed = ChangedSettings {
        color_scheme: snapshot.portal_color_scheme != cached.snapshot.portal_color_scheme,
        accent_color: snapshot.accent_color != cached.snapshot.accent_color,
    };
    cached.snapshot = snapshot;
    changed
}

fn namespace_matches(patterns: &[String], namespace: &str) -> bool {
    patterns.is_empty()
        || patterns.iter().any(|pattern| {
            pattern.is_empty()
                || pattern == namespace
                || pattern
                    .strip_suffix('*')
                    .is_some_and(|prefix| namespace.starts_with(prefix))
        })
}

fn connect_to_compositor(
    timeout: Duration,
) -> Result<(OwnedFd, DesktopThemeSnapshot), Box<dyn Error>> {
    let path = default_socket_path()?;
    let deadline = Instant::now()
        .checked_add(timeout)
        .ok_or("portal connection timeout overflow")?;
    loop {
        match connect_once(&path, deadline) {
            Ok(connection) => return Ok(connection),
            Err(error)
                if Instant::now() < deadline
                    && matches!(
                        error.kind(),
                        io::ErrorKind::NotFound
                            | io::ErrorKind::ConnectionRefused
                            | io::ErrorKind::WouldBlock
                            | io::ErrorKind::TimedOut
                    ) =>
            {
                thread::sleep(RETRY_INTERVAL);
            }
            Err(error) => {
                return Err(format!(
                    "could not connect to Denial portal IPC at {}: {error}",
                    path.display()
                )
                .into());
            }
        }
    }
}

fn connect_once(path: &Path, deadline: Instant) -> io::Result<(OwnedFd, DesktopThemeSnapshot)> {
    let socket = create_seqpacket_socket()?;
    let (address, length) = unix_address(path)?;
    // SAFETY: address is initialized by unix_address and socket remains owned
    // for the duration of the local connect call.
    if unsafe {
        libc::connect(
            socket.as_raw_fd(),
            (&address as *const libc::sockaddr_un).cast(),
            length,
        )
    } < 0
    {
        return Err(io::Error::last_os_error());
    }
    verify_same_user(socket.as_raw_fd())?;
    let hello = encode_client_message(ClientMessage::Hello);
    send_record(socket.as_raw_fd(), &hello)?;
    wait_readable(socket.as_raw_fd(), deadline)?;
    let snapshot = receive_snapshot(socket.as_raw_fd())?.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::ConnectionReset,
            "Denial closed portal IPC during handshake",
        )
    })?;
    Ok((socket, snapshot))
}

fn receive_snapshot(fd: RawFd) -> io::Result<Option<DesktopThemeSnapshot>> {
    let mut bytes = [0u8; MAX_MESSAGE_BYTES + 1];
    // SAFETY: bytes is writable for its full length and fd is a connected
    // seqpacket descriptor owned by this process.
    let received = unsafe { libc::recv(fd, bytes.as_mut_ptr().cast(), bytes.len(), 0) };
    if received == 0 {
        return Ok(None);
    }
    if received < 0 {
        let error = io::Error::last_os_error();
        if error.kind() == io::ErrorKind::Interrupted {
            return receive_snapshot(fd);
        }
        return Err(error);
    }
    match decode_server_message(&bytes[..received as usize])
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?
    {
        ServerMessage::ThemeSnapshot(snapshot) => Ok(Some(snapshot)),
    }
}

fn send_record(fd: RawFd, bytes: &[u8]) -> io::Result<()> {
    // SAFETY: bytes is readable for the supplied length and fd is connected.
    let sent = unsafe { libc::send(fd, bytes.as_ptr().cast(), bytes.len(), libc::MSG_NOSIGNAL) };
    if sent < 0 {
        return Err(io::Error::last_os_error());
    }
    if sent as usize != bytes.len() {
        return Err(io::Error::new(
            io::ErrorKind::WriteZero,
            "partial seqpacket write",
        ));
    }
    Ok(())
}

fn wait_readable(fd: RawFd, deadline: Instant) -> io::Result<()> {
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "Denial portal handshake timed out",
            ));
        }
        let milliseconds = remaining.as_millis().min(i32::MAX as u128) as i32;
        let mut poll_fd = libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: poll_fd is initialized and fd remains owned by the caller.
        let result = unsafe { libc::poll(&mut poll_fd, 1, milliseconds) };
        if result > 0 && poll_fd.revents & libc::POLLIN != 0 {
            return Ok(());
        }
        if result == 0 {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "Denial portal handshake timed out",
            ));
        }
        if result < 0 && io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
            continue;
        }
        return Err(io::Error::last_os_error());
    }
}

fn verify_same_user(fd: RawFd) -> io::Result<()> {
    // SAFETY: zero is a valid initial representation for ucred before the
    // kernel fills it through getsockopt.
    let mut credentials: libc::ucred = unsafe { std::mem::zeroed() };
    let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: both pointers reference writable storage of the advertised size.
    if unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut credentials as *mut libc::ucred).cast(),
            &mut length,
        )
    } < 0
    {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: getuid has no memory or pointer preconditions.
    if credentials.uid != unsafe { libc::getuid() } {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "Denial portal IPC peer belongs to a different user",
        ));
    }
    Ok(())
}

fn create_seqpacket_socket() -> io::Result<OwnedFd> {
    // SAFETY: socket has no pointer arguments and returns unique ownership.
    let raw = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_SEQPACKET | libc::SOCK_CLOEXEC, 0) };
    if raw < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: the successful socket call returned a unique descriptor.
    Ok(unsafe { OwnedFd::from_raw_fd(raw) })
}

fn unix_address(path: &Path) -> io::Result<(libc::sockaddr_un, libc::socklen_t)> {
    let bytes = path.as_os_str().as_bytes();
    // SAFETY: zero initialization is the required base representation.
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    if bytes.len() >= address.sun_path.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "portal IPC socket path is too long",
        ));
    }
    address.sun_family = libc::AF_UNIX as libc::sa_family_t;
    // SAFETY: the checked destination has enough space and remains NUL-ended.
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

fn default_socket_path() -> Result<PathBuf, Box<dyn Error>> {
    let runtime = std::env::var_os("XDG_RUNTIME_DIR")
        .ok_or("XDG_RUNTIME_DIR is required for Denial portal IPC")?;
    let runtime = PathBuf::from(runtime);
    if !runtime.is_absolute() {
        return Err("XDG_RUNTIME_DIR must be an absolute path".into());
    }
    Ok(runtime.join("denial").join(PORTAL_SOCKET_FILE))
}

#[cfg(test)]
mod tests {
    use super::*;
    use denial_core::portal_protocol::{DesktopAccentColor, DesktopColorSchemePreference};
    use std::fs;
    use std::process::{Child, Command, Stdio};
    use std::sync::atomic::{AtomicU64, Ordering};

    #[zbus::proxy(
        interface = "org.freedesktop.impl.portal.Settings",
        default_service = "org.freedesktop.impl.portal.desktop.denial",
        default_path = "/org/freedesktop/portal/desktop"
    )]
    trait SettingsTest {
        #[zbus(name = "Read")]
        fn read(&self, namespace: &str, key: &str) -> zbus::Result<OwnedValue>;

        #[zbus(name = "ReadAll")]
        fn read_all(&self, namespaces: Vec<String>) -> zbus::Result<SettingsValues>;

        #[zbus(signal, name = "SettingChanged")]
        fn setting_changed(
            &self,
            namespace: &str,
            key: &str,
            value: OwnedValue,
        ) -> zbus::Result<()>;
    }

    #[zbus::proxy(
        interface = "org.freedesktop.portal.Settings",
        default_service = "org.freedesktop.portal.Desktop",
        default_path = "/org/freedesktop/portal/desktop"
    )]
    trait SettingsFrontendTest {
        #[zbus(name = "ReadOne")]
        fn read_one(&self, namespace: &str, key: &str) -> zbus::Result<OwnedValue>;
    }

    #[test]
    fn stale_snapshots_are_ignored_and_unchanged_values_do_not_signal() {
        let cache = RwLock::new(Cache {
            snapshot: DesktopThemeSnapshot::new(10, DesktopColorSchemePreference::PreferDark),
        });

        assert_eq!(
            apply_snapshot(
                &cache,
                DesktopThemeSnapshot::new(9, DesktopColorSchemePreference::PreferLight)
            ),
            ChangedSettings::default()
        );
        assert_eq!(
            apply_snapshot(
                &cache,
                DesktopThemeSnapshot::new(11, DesktopColorSchemePreference::PreferDark)
            ),
            ChangedSettings::default()
        );
        assert_eq!(
            apply_snapshot(
                &cache,
                DesktopThemeSnapshot::new(12, DesktopColorSchemePreference::NoPreference)
            ),
            ChangedSettings {
                color_scheme: true,
                accent_color: false,
            }
        );
        assert_eq!(
            apply_snapshot(
                &cache,
                DesktopThemeSnapshot::new(12, DesktopColorSchemePreference::NoPreference)
                    .with_accent(DesktopAccentColor::new(0x12, 0x34, 0x56))
            ),
            ChangedSettings {
                color_scheme: false,
                accent_color: true,
            }
        );
        assert_eq!(
            cache
                .read()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .snapshot
                .portal_color_scheme,
            0
        );
    }

    #[test]
    fn serves_the_exact_settings_contract_on_a_private_bus() {
        if std::env::var_os("DENIAL_PORTAL_TEST_BUS").is_none() {
            return;
        }
        let cache = Arc::new(RwLock::new(Cache {
            snapshot: DesktopThemeSnapshot::new(17, DesktopColorSchemePreference::NoPreference),
        }));
        let server = ConnectionBuilder::session()
            .and_then(|builder| builder.name(SERVICE_NAME))
            .and_then(|builder| {
                builder.serve_at(
                    OBJECT_PATH,
                    SettingsInterface {
                        cache: Arc::clone(&cache),
                    },
                )
            })
            .and_then(ConnectionBuilder::build)
            .expect("serve Settings on private bus");
        let client = Connection::session().expect("connect Settings client");
        let proxy = SettingsTestProxyBlocking::new(&client).expect("build Settings proxy");
        let mut changes = proxy
            .receive_setting_changed()
            .expect("subscribe to setting changes");

        let value = proxy
            .read(APPEARANCE_NAMESPACE, COLOR_SCHEME_KEY)
            .expect("read known setting");
        assert_eq!(u32::try_from(value).expect("unsigned variant"), 0);
        let all = proxy
            .read_all(vec!["org.freedesktop.*".to_owned()])
            .expect("read matching namespace");
        assert_eq!(
            u32::try_from(
                all[APPEARANCE_NAMESPACE][COLOR_SCHEME_KEY]
                    .try_clone()
                    .expect("clone D-Bus value")
            )
            .expect("unsigned variant"),
            0
        );
        let error = proxy
            .read("org.example", "missing")
            .expect_err("unknown setting must return a portal error");
        match error {
            zbus::Error::MethodError(name, _, _) => {
                assert_eq!(name.as_str(), "org.freedesktop.portal.Error.NotFound");
            }
            other => panic!("unexpected unknown-setting error: {other}"),
        }
        assert_eq!(
            proxy
                .inner()
                .get_property::<u32>("version")
                .expect("read interface version"),
            1
        );

        server
            .emit_signal(
                None::<&str>,
                OBJECT_PATH,
                INTERFACE_NAME,
                "SettingChanged",
                &(
                    APPEARANCE_NAMESPACE,
                    COLOR_SCHEME_KEY,
                    OwnedValue::from(2u32),
                ),
            )
            .expect("emit setting change");
        let change = changes.next().expect("receive setting change");
        let arguments = change.args().expect("decode setting change arguments");
        assert_eq!(*arguments.namespace(), APPEARANCE_NAMESPACE);
        assert_eq!(*arguments.key(), COLOR_SCHEME_KEY);
        assert_eq!(
            u32::try_from(
                arguments
                    .value()
                    .try_clone()
                    .expect("clone setting change value")
            )
            .expect("unsigned setting change value"),
            2
        );

        verify_real_frontend_contract(&server, &client, &cache);
    }

    fn verify_real_frontend_contract(
        backend: &Connection,
        client: &Connection,
        cache: &Arc<RwLock<Cache>>,
    ) {
        let Some(frontend_binary) = std::env::var_os("DENIAL_PORTAL_FRONTEND_TEST") else {
            return;
        };
        let directory = TestDirectory::new();
        let config_root = directory.path.join("config");
        let data_root = directory.path.join("data");
        fs::create_dir_all(config_root.join("xdg-desktop-portal"))
            .expect("create private portal config directory");
        fs::create_dir_all(data_root.join("xdg-desktop-portal/portals"))
            .expect("create private portal descriptor directory");
        fs::write(
            config_root.join("xdg-desktop-portal/denial-portals.conf"),
            include_str!("../../../packaging/arch/denial-portals.conf"),
        )
        .expect("write private portal routing");
        fs::write(
            data_root.join("xdg-desktop-portal/portals/denial.portal"),
            include_str!("../../../packaging/arch/denial.portal"),
        )
        .expect("write private portal descriptor");

        let child = Command::new(frontend_binary)
            .arg("--replace")
            .env("XDG_CURRENT_DESKTOP", "Denial")
            .env("XDG_CONFIG_HOME", &config_root)
            .env("XDG_CONFIG_DIRS", &config_root)
            .env("XDG_DATA_HOME", &data_root)
            .env(
                "XDG_DATA_DIRS",
                format!("{}:/usr/share", data_root.display()),
            )
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("start real xdg-desktop-portal frontend");
        let _frontend = ChildGuard(child);
        wait_for_frontend_owner(client);
        let proxy = SettingsFrontendTestProxyBlocking::new(client)
            .expect("build real Settings frontend proxy");

        let initial = wait_for_frontend_value(&proxy, APPEARANCE_NAMESPACE, COLOR_SCHEME_KEY, 0);
        assert_eq!(initial, 0);
        assert_eq!(busctl_read_one(), "v u 0");
        for (preference, expected) in [
            (DesktopColorSchemePreference::PreferDark, 1),
            (DesktopColorSchemePreference::PreferLight, 2),
            (DesktopColorSchemePreference::NoPreference, 0),
        ] {
            publish_frontend_test_value(backend, cache, preference, expected);
            assert_eq!(
                wait_for_frontend_value(&proxy, APPEARANCE_NAMESPACE, COLOR_SCHEME_KEY, expected,),
                expected
            );
            assert_eq!(busctl_read_one(), format!("v u {expected}"));
        }
    }

    fn publish_frontend_test_value(
        backend: &Connection,
        cache: &Arc<RwLock<Cache>>,
        preference: DesktopColorSchemePreference,
        portal_value: u32,
    ) {
        {
            let mut cached = cache
                .write()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            cached.snapshot = DesktopThemeSnapshot::new(cached.snapshot.revision + 1, preference);
        }
        backend
            .emit_signal(
                None::<&str>,
                OBJECT_PATH,
                INTERFACE_NAME,
                "SettingChanged",
                &(
                    APPEARANCE_NAMESPACE,
                    COLOR_SCHEME_KEY,
                    OwnedValue::from(portal_value),
                ),
            )
            .expect("send live update through real frontend");
    }

    fn busctl_read_one() -> String {
        let output = Command::new("busctl")
            .args([
                "--user",
                "call",
                FRONTEND_SERVICE_NAME,
                OBJECT_PATH,
                "org.freedesktop.portal.Settings",
                "ReadOne",
                "ss",
                APPEARANCE_NAMESPACE,
                COLOR_SCHEME_KEY,
            ])
            .output()
            .expect("run busctl against private Settings frontend");
        assert!(
            output.status.success(),
            "busctl ReadOne failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout)
            .expect("busctl output is UTF-8")
            .trim()
            .to_owned()
    }

    fn wait_for_frontend_value(
        proxy: &SettingsFrontendTestProxyBlocking<'_>,
        namespace: &str,
        key: &str,
        expected: u32,
    ) -> u32 {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let detail = match proxy.read_one(namespace, key) {
                Ok(value) => {
                    let value = u32::try_from(value).expect("unsigned frontend variant");
                    if value == expected {
                        return value;
                    }
                    format!("last value was {value}")
                }
                Err(error) => error.to_string(),
            };
            assert!(
                Instant::now() < deadline,
                "real Settings frontend did not report {expected}: {detail}"
            );
            thread::sleep(Duration::from_millis(25));
        }
    }

    fn wait_for_frontend_owner(client: &Connection) {
        let bus = zbus::blocking::fdo::DBusProxy::new(client).expect("build D-Bus daemon proxy");
        let name: zbus::names::BusName<'_> = FRONTEND_SERVICE_NAME
            .try_into()
            .expect("valid frontend bus name");
        let deadline = Instant::now() + Duration::from_secs(5);
        while !bus
            .name_has_owner(name.clone())
            .expect("query frontend owner")
        {
            assert!(
                Instant::now() < deadline,
                "real xdg-desktop-portal did not acquire its bus name"
            );
            thread::sleep(Duration::from_millis(25));
        }
    }

    struct ChildGuard(Child);

    impl Drop for ChildGuard {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    struct TestDirectory {
        path: PathBuf,
    }

    impl TestDirectory {
        fn new() -> Self {
            static SERIAL: AtomicU64 = AtomicU64::new(0);
            let path = std::env::temp_dir().join(format!(
                "denial-portal-frontend-{}-{}",
                std::process::id(),
                SERIAL.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&path).expect("create private portal test directory");
            Self { path }
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }
}
