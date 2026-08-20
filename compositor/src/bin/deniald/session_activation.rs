//! Desktop-session environment publication and systemd target lifecycle.

use super::*;

const DENIAL_SESSION_TARGET: &str = "denial-session.target";
const GRAPHICAL_SESSION_TARGET: &str = "graphical-session.target";
const SYSTEMD_DBUS_NAME: &str = "org.freedesktop.systemd1";

pub(super) fn preserves_predecessor_kms_state(runtime_limit: RuntimeLimit) -> bool {
    runtime_limit != RuntimeLimit::UntilLogout
}

fn session_activation_environment(
    wayland_display: &OsStr,
    x11_display: &OsStr,
    output_control_socket: Option<&OsStr>,
) -> Result<BTreeMap<&'static str, String>, Box<dyn Error>> {
    let wayland_display = wayland_display
        .to_str()
        .ok_or("Wayland socket name is not valid UTF-8")?;
    let x11_display = x11_display
        .to_str()
        .ok_or("X11 display name is not valid UTF-8")?;
    let mut environment = BTreeMap::from([
        ("DESKTOP_SESSION", String::from("Denial")),
        ("DISPLAY", x11_display.to_owned()),
        ("WAYLAND_DISPLAY", wayland_display.to_owned()),
        ("XDG_CURRENT_DESKTOP", String::from("Denial")),
        ("XDG_SESSION_DESKTOP", String::from("Denial")),
        ("XDG_SESSION_TYPE", String::from("wayland")),
    ]);
    if let Some(socket) = output_control_socket {
        environment.insert(
            "DENIAL_SOCKET",
            socket
                .to_str()
                .ok_or("Denial control socket path is not valid UTF-8")?
                .to_owned(),
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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum SessionActivation {
    Dbus,
    Systemd,
}

impl SessionActivation {
    pub(super) fn starts_systemd_target(self) -> bool {
        self == Self::Systemd
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

pub(super) fn stop_systemd_graphical_session() -> Result<(), Box<dyn Error>> {
    let connection = zbus::blocking::Connection::session()?;
    let _job = change_systemd_graphical_session(&connection, "StopUnit", GRAPHICAL_SESSION_TARGET)?;
    Ok(())
}

pub(super) fn publish_session_activation_environment(
    wayland_display: &OsStr,
    x11_display: &OsStr,
    output_control_socket: Option<&OsStr>,
) -> Result<SessionActivation, Box<dyn Error>> {
    let environment =
        session_activation_environment(wayland_display, x11_display, output_control_socket)?;
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
    update_systemd_activation_environment(&connection, &environment).map_err(|error| {
        format!("could not publish the session environment to systemd: {error}")
    })?;
    let job = start_systemd_graphical_session(&connection).map_err(|error| {
        format!("could not start {DENIAL_SESSION_TARGET} through systemd: {error}")
    })?;
    info!(
        wayland_display = ?wayland_display,
        x11_display = ?x11_display,
        target = DENIAL_SESSION_TARGET,
        job = %job,
        "published the compositor session and queued its graphical-session target"
    );
    Ok(SessionActivation::Systemd)
}

#[cfg(test)]
#[path = "session_activation/tests.rs"]
mod tests;
