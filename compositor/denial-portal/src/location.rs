//! GeoClue agent: Denial asks the user before an app gets its location.
//!
//! GeoClue serves an app only once an agent of the app's user approves it.
//! This agent answers from the portal permission store, table `denial`,
//! entry `location`, by GeoClue's app ID: `yes` for "Always allow", `no` for
//! "Never allow", `ask` once it was asked. Otherwise it shows the Access
//! dialog. The xdg-desktop-portal Location portal asks through that same
//! dialog before it turns to GeoClue, so it is let through.
//!
//! GeoClue starts on demand and leaves after a minute unused, forgetting its
//! agents, so the agent registers again each time GeoClue appears. Without
//! GeoClue installed it waits and does nothing.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use tracing::{debug, info, warn};
use zbus::zvariant::{ObjectPath, OwnedValue, Value};

const GEOCLUE_SERVICE: &str = "org.freedesktop.GeoClue2";
const MANAGER_PATH: &str = "/org/freedesktop/GeoClue2/Manager";
const MANAGER_INTERFACE: &str = "org.freedesktop.GeoClue2.Manager";
const AGENT_PATH: &str = "/org/freedesktop/GeoClue2/Agent";
/// GeoClue takes agents its `[agent] whitelist` names; Denial's package adds
/// this one.
const AGENT_ID: &str = "denial-portal";
/// The Location portal, which asked the user already.
const PORTAL_APP: &str = "xdg-desktop-portal";
/// GeoClue's accuracy levels; exact is the most an app can get.
const ACCURACY_NONE: u32 = 0;
const ACCURACY_EXACT: u32 = 8;

const ACCESS_SERVICE: &str = "org.freedesktop.impl.portal.desktop.denial";
const ACCESS_PATH: &str = "/org/freedesktop/portal/desktop";
const ACCESS_INTERFACE: &str = "org.freedesktop.impl.portal.Access";
const REQUEST_PREFIX: &str = "/org/freedesktop/portal/desktop/request/denial/location";
const PERMISSION_STORE_SERVICE: &str = "org.freedesktop.impl.portal.PermissionStore";
const PERMISSION_STORE_PATH: &str = "/org/freedesktop/impl/portal/PermissionStore";
const PERMISSION_STORE_INTERFACE: &str = "org.freedesktop.impl.portal.PermissionStore";
const PERMISSION_TABLE: &str = "denial";
const PERMISSION_ID: &str = "location";
const PERMISSION_STORE_TIMEOUT: Duration = Duration::from_secs(2);
const REMEMBER_CHOICE: &str = "remember";
const ALLOWED: &str = "yes";
const DENIED: &str = "no";
const ASKED: &str = "ask";

/// Serves the agent on a thread of its own for the rest of the session.
pub(crate) fn spawn() {
    let started = std::thread::Builder::new()
        .name("geoclue-agent".into())
        .spawn(|| {
            if let Err(error) = serve() {
                warn!(%error, "GeoClue agent stopped");
            }
        });
    if let Err(error) = started {
        warn!(%error, "could not start the GeoClue agent");
    }
}

struct Agent {
    requests: AtomicU64,
}

#[zbus::interface(name = "org.freedesktop.GeoClue2.Agent", introspection_docs = false)]
impl Agent {
    /// Whether `desktop_id` may have location, and how exact.
    async fn authorize_app(&self, desktop_id: String, req_accuracy_level: u32) -> (bool, u32) {
        if desktop_id == PORTAL_APP {
            return (true, req_accuracy_level);
        }
        let request = self.requests.fetch_add(1, Ordering::Relaxed);
        // The dialog waits for the user: off the bus connection's executor.
        let (tx, rx) = async_channel::bounded(1);
        let app = desktop_id.clone();
        std::thread::spawn(move || {
            let _ = tx.send_blocking(decide(&app, request));
        });
        let allowed = match rx.recv().await {
            Ok(Ok(allowed)) => allowed,
            Ok(Err(error)) => {
                warn!(%error, app_id = %desktop_id, "could not ask about location");
                false
            }
            Err(_) => false,
        };
        let level = if allowed {
            req_accuracy_level.min(ACCURACY_EXACT)
        } else {
            ACCURACY_NONE
        };
        (allowed, level)
    }

    #[zbus(property)]
    fn max_accuracy_level(&self) -> u32 {
        ACCURACY_EXACT
    }
}

fn serve() -> zbus::Result<()> {
    let system = zbus::blocking::Connection::system()?;
    system.object_server().at(
        AGENT_PATH,
        Agent {
            requests: AtomicU64::new(0),
        },
    )?;
    let bus = zbus::blocking::fdo::DBusProxy::new(&system)?;
    let appearances = bus.receive_name_owner_changed_with_args(&[(0, GEOCLUE_SERVICE)])?;
    let name = zbus::names::BusName::try_from(GEOCLUE_SERVICE)?;
    if bus.name_has_owner(name)? {
        register(&system);
    } else {
        debug!("GeoClue is not running: the agent waits for it");
    }
    for change in appearances {
        if change.args().is_ok_and(|args| args.new_owner().is_some()) {
            register(&system);
        }
    }
    Ok(())
}

fn register(system: &zbus::blocking::Connection) {
    let added = system.call_method(
        Some(GEOCLUE_SERVICE),
        MANAGER_PATH,
        Some(MANAGER_INTERFACE),
        "AddAgent",
        &(AGENT_ID,),
    );
    match added {
        Ok(_) => info!("registered as GeoClue's agent"),
        Err(error) => warn!(%error, "GeoClue did not take Denial as its agent"),
    }
}

/// An Access dialog choice: id, label, options (id, label), initial value.
type Choice<'a> = (&'a str, &'a str, Vec<(&'a str, &'a str)>, &'a str);

/// The stored answer, else the user's answer from the Access dialog.
fn decide(app_id: &str, request: u64) -> zbus::Result<bool> {
    // `Ok(None)`: the app has no stored answer yet.
    let mut stored = Err(());
    match stored_answer(app_id) {
        Ok(Some(value)) if value == ALLOWED || value == DENIED => return Ok(value == ALLOWED),
        Ok(value) => stored = Ok(value),
        Err(error) => debug!(%error, "could not read stored location answers"),
    }
    let name = app_name(app_id);
    let title = format!("Let {name} use your location?");
    let subtitle = "It learns where this device is, as exactly as its GPS can tell.";
    // Denial's dialog shows it as "Always allow" and "Never allow" buttons.
    let choices: Vec<Choice<'_>> =
        vec![(REMEMBER_CHOICE, "Remember this answer", Vec::new(), "false")];
    let mut options: HashMap<&str, Value<'_>> = HashMap::new();
    options.insert("modal", Value::from(true));
    options.insert("choices", Value::from(choices));
    let handle = format!("{REQUEST_PREFIX}_{request}");
    let reply = zbus::blocking::Connection::session()?.call_method(
        Some(ACCESS_SERVICE),
        ACCESS_PATH,
        Some(ACCESS_INTERFACE),
        "AccessDialog",
        &(
            ObjectPath::try_from(handle.as_str())?,
            app_id,
            "",
            title.as_str(),
            subtitle,
            "",
            options,
        ),
    )?;
    let (response, results): (u32, HashMap<String, OwnedValue>) = reply.body().deserialize()?;
    let allowed = response == 0;
    let remember = results
        .get("choices")
        .and_then(|choices| Vec::<(String, String)>::try_from(choices.clone()).ok())
        .is_some_and(|choices| {
            choices
                .iter()
                .any(|(id, value)| id == REMEMBER_CHOICE && value == "true")
        });
    info!(app_id, allowed, remember, "location prompt answered");
    // An asked app is listed in Settings, whatever the answer was.
    let store = if remember {
        Some(if allowed { ALLOWED } else { DENIED })
    } else if stored == Ok(None) {
        Some(ASKED)
    } else {
        None
    };
    if let Some(value) = store
        && let Err(error) = store_answer(app_id, value)
    {
        warn!(%error, app_id, "could not store an app's location answer");
    }
    Ok(allowed)
}

/// The app's name from its desktop file, else its ID.
fn app_name(app_id: &str) -> String {
    let dirs = ["/usr/share/applications", "/usr/local/share/applications"];
    dirs.iter()
        .filter_map(|dir| std::fs::read_to_string(format!("{dir}/{app_id}.desktop")).ok())
        .find_map(|text| desktop_name(&text))
        .unwrap_or_else(|| app_id.to_owned())
}

/// `Name=` of the `[Desktop Entry]` group.
fn desktop_name(text: &str) -> Option<String> {
    let mut in_entry = false;
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_entry = line == "[Desktop Entry]";
        } else if in_entry && let Some(name) = line.strip_prefix("Name=") {
            return Some(name.trim().to_owned()).filter(|n| !n.is_empty());
        }
    }
    None
}

fn permission_store() -> zbus::Result<zbus::blocking::Connection> {
    zbus::blocking::connection::Builder::session()?
        .method_timeout(PERMISSION_STORE_TIMEOUT)
        .build()
}

/// The app's stored answer: `yes`, `no`, `ask`, or another value to ask on.
fn stored_answer(app_id: &str) -> zbus::Result<Option<String>> {
    let reply = permission_store()?.call_method(
        Some(PERMISSION_STORE_SERVICE),
        PERMISSION_STORE_PATH,
        Some(PERMISSION_STORE_INTERFACE),
        "Lookup",
        &(PERMISSION_TABLE, PERMISSION_ID),
    );
    let reply = match reply {
        Ok(reply) => reply,
        // The entry exists once something was stored in it.
        Err(zbus::Error::MethodError(name, _, _))
            if name.as_str() == "org.freedesktop.portal.Error.NotFound" =>
        {
            return Ok(None);
        }
        Err(error) => return Err(error),
    };
    let (permissions, _data): (HashMap<String, Vec<String>>, OwnedValue) =
        reply.body().deserialize()?;
    Ok(permissions
        .get(app_id)
        .and_then(|values| values.first().cloned()))
}

fn store_answer(app_id: &str, value: &str) -> zbus::Result<()> {
    permission_store()?.call_method(
        Some(PERMISSION_STORE_SERVICE),
        PERMISSION_STORE_PATH,
        Some(PERMISSION_STORE_INTERFACE),
        "SetPermission",
        &(PERMISSION_TABLE, true, PERMISSION_ID, app_id, vec![value]),
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_entry_name() {
        let text = "[Desktop Entry]\nType=Application\nName=Firefox\n\
                    [Desktop Action new-window]\nName=New Window\n";
        assert_eq!(desktop_name(text), Some("Firefox".into()));
        let action_first = "[Desktop Action x]\nName=Other\n[Desktop Entry]\nName=Maps\n";
        assert_eq!(desktop_name(action_first), Some("Maps".into()));
        assert_eq!(desktop_name("[Desktop Entry]\nName=\n"), None);
    }
}
