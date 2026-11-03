//! Desktop-session environment publication and systemd target lifecycle.

use super::*;

const DENIAL_SESSION_TARGET: &str = "denial-session.target";
const GRAPHICAL_SESSION_TARGET: &str = "graphical-session.target";
const SYSTEMD_DBUS_NAME: &str = "org.freedesktop.systemd1";

pub(super) fn preserves_predecessor_kms_state(
    runtime_limit: RuntimeLimit,
    no_predecessor: bool,
) -> bool {
    !no_predecessor && runtime_limit != RuntimeLimit::UntilLogout
}

fn session_activation_environment(
    wayland_display: &OsStr,
    x11_display: Option<&OsStr>,
    output_control_socket: Option<&OsStr>,
    qt_platform_theme: Option<&OsStr>,
    polkit_agent: bool,
) -> Result<BTreeMap<&'static str, String>, Box<dyn Error>> {
    let wayland_display = wayland_display
        .to_str()
        .ok_or("Wayland socket name is not valid UTF-8")?;
    let qt_platform_theme = qt_platform_theme
        .unwrap_or_else(|| OsStr::new(DEFAULT_QT_QPA_PLATFORMTHEME))
        .to_str()
        .ok_or("QT_QPA_PLATFORMTHEME is not valid UTF-8")?;
    let mut environment = BTreeMap::from([
        ("DESKTOP_SESSION", String::from("Denial")),
        ("QT_QPA_PLATFORMTHEME", qt_platform_theme.to_owned()),
        ("WAYLAND_DISPLAY", wayland_display.to_owned()),
        ("XDG_CURRENT_DESKTOP", String::from("Denial")),
        ("XDG_SESSION_DESKTOP", String::from("Denial")),
        ("XDG_SESSION_TYPE", String::from("wayland")),
    ]);
    if !polkit_agent {
        // The session's agent service reads this and leaves PolicyKit to
        // whatever else the user runs.
        environment.insert("DENIAL_POLKIT_AGENT", String::from("0"));
    }
    if let Some(x11_display) = x11_display {
        environment.insert(
            "DISPLAY",
            x11_display
                .to_str()
                .ok_or("X11 display name is not valid UTF-8")?
                .to_owned(),
        );
    }
    if let Some(socket) = output_control_socket {
        environment.insert(
            "DENIAL_SOCKET",
            socket
                .to_str()
                .ok_or("Denial control socket path is not valid UTF-8")?
                .to_owned(),
        );
    }
    #[cfg(feature = "flutter")]
    if let Some(cursor_environment) = crate::xcursor_sentinel::environment() {
        environment.extend(
            cursor_environment
                .into_iter()
                .map(|(name, value)| (name, value.to_owned())),
        );
    }
    Ok(environment)
}

fn systemd_environment_assignments(environment: &BTreeMap<&'static str, String>) -> Vec<String> {
    environment
        .iter()
        .map(|(name, value)| format!("{name}={value}"))
        .collect()
}

#[derive(Debug, Eq, PartialEq)]
pub(super) struct SystemdEnvironmentRestore {
    names: Vec<String>,
    assignments: Vec<String>,
}

fn systemd_environment_restore(
    published_environment: &BTreeMap<&'static str, String>,
    manager_environment: &[String],
) -> SystemdEnvironmentRestore {
    let names = published_environment
        .keys()
        .map(|name| (*name).to_owned())
        .collect();
    let assignments = manager_environment
        .iter()
        .filter(|assignment| {
            assignment
                .split_once('=')
                .is_some_and(|(name, _)| published_environment.contains_key(name))
        })
        .cloned()
        .collect();
    SystemdEnvironmentRestore { names, assignments }
}

fn update_dbus_activation_environment(
    connection: &zbus::blocking::Connection,
    environment: &BTreeMap<&'static str, String>,
) -> Result<(), zbus::Error> {
    let proxy = zbus::blocking::Proxy::new(
        connection,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
    )?;
    proxy.call("UpdateActivationEnvironment", environment)
}

#[derive(Debug, Eq, PartialEq)]
pub(super) enum SessionActivation {
    Dbus,
    Systemd(SystemdEnvironmentRestore),
}

impl SessionActivation {
    pub(super) fn into_systemd_restore(self) -> Option<SystemdEnvironmentRestore> {
        match self {
            Self::Dbus => None,
            Self::Systemd(restore) => Some(restore),
        }
    }
}

fn systemd_user_manager_runtime_available(runtime_dir: Option<&OsStr>) -> bool {
    let Some(runtime_dir) = runtime_dir else {
        return false;
    };
    let runtime_dir = Path::new(runtime_dir);
    runtime_dir.is_absolute() && runtime_dir.join("systemd").is_dir()
}

fn update_systemd_activation_environment(
    connection: &zbus::blocking::Connection,
    environment: &BTreeMap<&'static str, String>,
) -> Result<(), zbus::Error> {
    let proxy = zbus::blocking::Proxy::new(
        connection,
        SYSTEMD_DBUS_NAME,
        "/org/freedesktop/systemd1",
        "org.freedesktop.systemd1.Manager",
    )?;
    proxy.call(
        "SetEnvironment",
        &systemd_environment_assignments(environment),
    )
}

fn current_systemd_activation_environment(
    connection: &zbus::blocking::Connection,
) -> Result<Vec<String>, zbus::Error> {
    let proxy = zbus::blocking::Proxy::new(
        connection,
        SYSTEMD_DBUS_NAME,
        "/org/freedesktop/systemd1",
        "org.freedesktop.systemd1.Manager",
    )?;
    proxy.get_property("Environment")
}

fn restore_systemd_activation_environment(
    connection: &zbus::blocking::Connection,
    restore: &SystemdEnvironmentRestore,
) -> Result<(), zbus::Error> {
    let proxy = zbus::blocking::Proxy::new(
        connection,
        SYSTEMD_DBUS_NAME,
        "/org/freedesktop/systemd1",
        "org.freedesktop.systemd1.Manager",
    )?;
    proxy.call(
        "UnsetAndSetEnvironment",
        &(restore.names.as_slice(), restore.assignments.as_slice()),
    )
}

fn change_systemd_graphical_session(
    connection: &zbus::blocking::Connection,
    method: &'static str,
    target: &'static str,
) -> Result<zbus::zvariant::OwnedObjectPath, zbus::Error> {
    let proxy = zbus::blocking::Proxy::new(
        connection,
        SYSTEMD_DBUS_NAME,
        "/org/freedesktop/systemd1",
        "org.freedesktop.systemd1.Manager",
    )?;
    proxy.call(method, &(target, "replace"))
}

fn start_systemd_graphical_session(
    connection: &zbus::blocking::Connection,
) -> Result<zbus::zvariant::OwnedObjectPath, zbus::Error> {
    change_systemd_graphical_session(connection, "StartUnit", DENIAL_SESSION_TARGET)
}

pub(super) fn stop_systemd_graphical_session(
    restore: &SystemdEnvironmentRestore,
) -> Result<(), Box<dyn Error>> {
    let connection = zbus::blocking::Connection::session()?;
    let stop = change_systemd_graphical_session(&connection, "StopUnit", GRAPHICAL_SESSION_TARGET);
    let restore = restore_systemd_activation_environment(&connection, restore);
    match (stop, restore) {
        (Ok(_), Ok(())) => Ok(()),
        (Err(stop), Ok(())) => Err(format!(
            "could not stop {GRAPHICAL_SESSION_TARGET} through systemd: {stop}"
        )
        .into()),
        (Ok(_), Err(restore)) => {
            Err(format!("could not restore the pre-Denial systemd environment: {restore}").into())
        }
        (Err(stop), Err(restore)) => Err(format!(
            "could not stop {GRAPHICAL_SESSION_TARGET} through systemd: {stop}; could not restore the pre-Denial systemd environment: {restore}"
        )
        .into()),
    }
}

pub(super) fn publish_session_activation_environment(
    wayland_display: &OsStr,
    x11_display: Option<&OsStr>,
    output_control_socket: Option<&OsStr>,
    polkit_agent: bool,
) -> Result<SessionActivation, Box<dyn Error>> {
    let qt_platform_theme = std::env::var_os("QT_QPA_PLATFORMTHEME");
    let mut environment = session_activation_environment(
        wayland_display,
        x11_display,
        output_control_socket,
        qt_platform_theme.as_deref(),
        polkit_agent,
    )?;
    // Session programs that look different on a phone, such as the
    // authentication prompt, follow the shell's profile. Always set, so a
    // desktop session does not inherit a phone's.
    environment.insert(
        "DENIAL_SHELL_PROFILE",
        denial_core::environment::var("DENIAL_SHELL_PROFILE")
            .unwrap_or_else(|_| String::from("desktop")),
    );
    let connection = zbus::blocking::Connection::session()?;
    update_dbus_activation_environment(&connection, &environment)?;

    if !systemd_user_manager_runtime_available(std::env::var_os("XDG_RUNTIME_DIR").as_deref()) {
        info!(
            wayland_display = ?wayland_display,
            x11_display = ?x11_display,
            "published the compositor session to D-Bus activation; no systemd user manager runtime is available"
        );
        return Ok(SessionActivation::Dbus);
    }

    // NameHasOwner is deliberately not used as a capability test here. The
    // user manager can already be running while its well-known D-Bus name is
    // still activatable or being acquired during an early login. Sending the
    // manager calls directly lets D-Bus synchronize that startup instead of
    // permanently selecting the D-Bus-only path from a transient snapshot.
    let manager_environment =
        current_systemd_activation_environment(&connection).map_err(|error| {
            format!("could not snapshot the pre-Denial systemd environment: {error}")
        })?;
    let restore = systemd_environment_restore(&environment, &manager_environment);
    update_systemd_activation_environment(&connection, &environment).map_err(|error| {
        format!("could not publish the session environment to systemd: {error}")
    })?;
    let job = match start_systemd_graphical_session(&connection) {
        Ok(job) => job,
        Err(start_error) => {
            let message = match restore_systemd_activation_environment(&connection, &restore) {
                Ok(()) => {
                    format!(
                        "could not start {DENIAL_SESSION_TARGET} through systemd: {start_error}"
                    )
                }
                Err(restore_error) => format!(
                    "could not start {DENIAL_SESSION_TARGET} through systemd: {start_error}; could not restore the pre-Denial systemd environment: {restore_error}"
                ),
            };
            return Err(message.into());
        }
    };
    info!(
        wayland_display = ?wayland_display,
        x11_display = ?x11_display,
        target = DENIAL_SESSION_TARGET,
        job = %job,
        "published the compositor session and queued its graphical-session target"
    );
    Ok(SessionActivation::Systemd(restore))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_is_published_only_when_xwayland_is_active() {
        let wayland = OsStr::new("wayland-7");
        let x11 = OsStr::new(":3");
        let with_xwayland =
            session_activation_environment(wayland, Some(x11), None, None, true).unwrap();
        let without_xwayland =
            session_activation_environment(wayland, None, None, None, true).unwrap();

        assert_eq!(with_xwayland.get("DISPLAY").map(String::as_str), Some(":3"));
        assert!(!without_xwayland.contains_key("DISPLAY"));
        assert!(!without_xwayland.contains_key("DENIAL_POLKIT_AGENT"));
        let no_agent = session_activation_environment(wayland, None, None, None, false).unwrap();
        assert_eq!(
            no_agent.get("DENIAL_POLKIT_AGENT").map(String::as_str),
            Some("0")
        );
        assert_eq!(
            without_xwayland.get("WAYLAND_DISPLAY").map(String::as_str),
            Some("wayland-7")
        );
    }

    #[test]
    fn systemd_restore_replaces_only_the_environment_denial_publishes() {
        let published = BTreeMap::from([
            ("QT_QPA_PLATFORMTHEME", String::from("xdgdesktopportal")),
            ("WAYLAND_DISPLAY", String::from("wayland-7")),
            ("XDG_CURRENT_DESKTOP", String::from("Denial")),
        ]);
        let manager = vec![
            String::from("HOME=/home/test"),
            String::from("QT_QPA_PLATFORMTHEME=kde"),
            String::from("WAYLAND_DISPLAY=wayland-2"),
            String::from("XDG_CURRENT_DESKTOP=KDE"),
            String::from("UNCHANGED=value=with=equals"),
        ];

        assert_eq!(
            systemd_environment_restore(&published, &manager),
            SystemdEnvironmentRestore {
                names: vec![
                    String::from("QT_QPA_PLATFORMTHEME"),
                    String::from("WAYLAND_DISPLAY"),
                    String::from("XDG_CURRENT_DESKTOP"),
                ],
                assignments: vec![
                    String::from("QT_QPA_PLATFORMTHEME=kde"),
                    String::from("WAYLAND_DISPLAY=wayland-2"),
                    String::from("XDG_CURRENT_DESKTOP=KDE"),
                ],
            }
        );
    }

    #[test]
    fn systemd_restore_unsets_published_names_that_were_previously_absent() {
        let published = BTreeMap::from([
            ("QT_QPA_PLATFORMTHEME", String::from("xdgdesktopportal")),
            ("XDG_CURRENT_DESKTOP", String::from("Denial")),
        ]);
        let manager = vec![String::from("HOME=/home/test")];

        assert_eq!(
            systemd_environment_restore(&published, &manager),
            SystemdEnvironmentRestore {
                names: vec![
                    String::from("QT_QPA_PLATFORMTHEME"),
                    String::from("XDG_CURRENT_DESKTOP"),
                ],
                assignments: Vec::new(),
            }
        );
    }
}
