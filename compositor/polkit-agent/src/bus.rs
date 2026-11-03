//! Only polkitd may drive this interface. Registration is scoped to our logind session.
use std::{
    collections::HashMap,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc::{Sender, channel},
    },
};
use zbus::{
    blocking::{Connection, Proxy},
    message::Header,
    zvariant::{OwnedObjectPath, OwnedValue},
};

use crate::{Event, Request};

fn session_path(
    connection: &Connection,
    logind: &Proxy<'_>,
) -> Result<OwnedObjectPath, Box<dyn std::error::Error>> {
    if let Ok(path) =
        logind.call::<_, _, OwnedObjectPath>("GetSessionByPID", &(std::process::id(),))
    {
        return Ok(path);
    }
    // User-manager services are outside logind session cgroups. The Wayland
    // compositor's authenticated socket peer supplies the session's PID instead.
    use std::os::{fd::AsRawFd, unix::net::UnixStream};
    let display = std::env::var_os("WAYLAND_DISPLAY").ok_or("WAYLAND_DISPLAY is required")?;
    let mut path = std::path::PathBuf::from(display);
    if !path.is_absolute() {
        path = std::path::PathBuf::from(
            std::env::var_os("XDG_RUNTIME_DIR").ok_or("XDG_RUNTIME_DIR is required")?,
        )
        .join(path);
    }
    let socket = UnixStream::connect(path)?;
    // SAFETY: credentials and length are initialized writable buffers of the
    // exact Linux SO_PEERCRED ABI, and the socket descriptor is live.
    let credentials = unsafe {
        let mut credentials: libc::ucred = std::mem::zeroed();
        let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
        if libc::getsockopt(
            socket.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut credentials as *mut libc::ucred).cast(),
            &mut length,
        ) != 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        if length as usize != std::mem::size_of::<libc::ucred>()
            || credentials.uid != libc::getuid()
            || credentials.pid <= 0
        {
            return Err("Invalid Wayland compositor credentials".into());
        }
        credentials
    };
    let path: OwnedObjectPath = logind.call("GetSessionByPID", &(credentials.pid as u32,))?;
    let session = Proxy::new(
        connection,
        "org.freedesktop.login1",
        path.clone(),
        "org.freedesktop.login1.Session",
    )?;
    let (uid, _): (u32, OwnedObjectPath) = session.get_property("User")?;
    // SAFETY: getuid has no pointer arguments or side effects.
    if uid != unsafe { libc::getuid() } {
        return Err("Login session belongs to another user".into());
    }
    Ok(path)
}

const AUTHORITY: &str = "org.freedesktop.PolicyKit1";
const PATH: &str = "/org/freedesktop/PolicyKit1/AuthenticationAgent";
type Identity = (String, HashMap<String, OwnedValue>);

#[derive(Debug, zbus::DBusError)]
#[zbus(prefix = "org.freedesktop.PolicyKit1.Error")]
pub enum AgentError {
    Failed(String),
    Cancelled(String),
}

struct Agent {
    authority_owner: String,
    events: Sender<Event>,
    locked: Arc<AtomicBool>,
}

const PKEXEC_ACTION: &str = "org.freedesktop.policykit.exec";

/// The command and target account from a pkexec command line (NUL-separated
/// arguments), for display only. Unrecognized shapes show nothing.
fn pkexec_command(cmdline: &[u8]) -> Option<(Option<String>, Option<String>)> {
    let mut args = cmdline
        .split(|b| *b == 0)
        .map(|a| String::from_utf8_lossy(a).into_owned())
        .collect::<Vec<_>>();
    while args.last().is_some_and(String::is_empty) {
        args.pop();
    }
    let mut args = args.into_iter().skip(1).peekable();
    let mut user = None;
    while let Some(arg) = args.peek() {
        match arg.as_str() {
            "--disable-internal-agent" | "--keep-cwd" => {
                args.next();
            }
            "--user" | "-u" => {
                args.next();
                user = args.next();
            }
            "--" => {
                args.next();
                break;
            }
            other if other.starts_with("--user=") => {
                user = Some(other["--user=".len()..].to_owned());
                args.next();
            }
            other if other.starts_with('-') => return None,
            _ => break,
        }
    }
    let quoted: Vec<String> = args
        .map(|a| {
            let plain = !a.is_empty()
                && a.chars()
                    .all(|c| c.is_alphanumeric() || "/._-+=:,@%".contains(c));
            if plain {
                a
            } else {
                format!("'{}'", a.replace('\'', "'\\''"))
            }
        })
        .collect();
    let command = (!quoted.is_empty())
        .then(|| quoted.join(" "))
        .and_then(|c| detail(&HashMap::from([("c".to_owned(), c)]), "c"));
    Some((command, user))
}

/// A caller-supplied detail for display only. Control characters become
/// spaces so it stays one line; unusually long values are not shown.
fn detail(details: &HashMap<String, String>, key: &str) -> Option<String> {
    let value = details.get(key)?;
    if value.len() > 4096 {
        return None;
    }
    let value: String = value
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    let value = value.trim();
    (!value.is_empty()).then(|| value.to_owned())
}

impl Agent {
    fn authenticate_sender(&self, header: &Header<'_>) -> Result<(), AgentError> {
        if header.sender().map(|s| s.as_str()) != Some(self.authority_owner.as_str()) {
            return Err(AgentError::Failed(
                "Only the registered Polkit authority may call this agent".into(),
            ));
        }
        Ok(())
    }
}

#[zbus::interface(name = "org.freedesktop.PolicyKit1.AuthenticationAgent")]
impl Agent {
    #[allow(clippy::too_many_arguments)] // The public Polkit D-Bus signature.
    async fn begin_authentication(
        &self,
        action_id: String,
        message: String,
        icon_name: String,
        details: HashMap<String, String>,
        cookie: String,
        identities: Vec<Identity>,
        #[zbus(header)] header: Header<'_>,
    ) -> Result<(), AgentError> {
        self.authenticate_sender(&header)?;
        if self.locked.load(Ordering::Acquire) {
            return Err(AgentError::Cancelled(
                "Session is locked or inactive".into(),
            ));
        }
        if cookie.is_empty()
            || cookie.len() > 4096
            || cookie.contains('\0')
            || message.len() > 16_384
            || action_id.len() > 4096
            || icon_name.len() > 4096
            || details.len() > 64
            || identities.is_empty()
            || identities.len() > 16
        {
            return Err(AgentError::Failed("Invalid authentication request".into()));
        }
        let uids = identities
            .into_iter()
            .map(|(kind, mut fields)| {
                if kind != "unix-user" {
                    return Err(AgentError::Failed("Unsupported Polkit identity".into()));
                }
                let uid = fields
                    .remove("uid")
                    .and_then(|v| u32::try_from(v).ok())
                    .filter(|uid| *uid <= i32::MAX as u32)
                    .ok_or_else(|| AgentError::Failed("Invalid Unix identity".into()))?;
                Ok(uid)
            })
            .collect::<Result<Vec<_>, _>>()?;
        // Polkit forwards only process IDs, so pkexec's own command line is
        // the source of what will run and as whom.
        let (command, run_as) = (action_id == PKEXEC_ACTION)
            .then(|| details.get("polkit.caller-pid"))
            .flatten()
            .and_then(|pid| pid.parse::<u32>().ok())
            .and_then(|pid| {
                std::fs::read(format!("/proc/{pid}/comm"))
                    .ok()
                    .zip(std::fs::read(format!("/proc/{pid}/cmdline")).ok())
            })
            .filter(|(comm, _)| comm.trim_ascii() == b"pkexec")
            .and_then(|(_, cmdline)| pkexec_command(&cmdline))
            .unwrap_or_default();
        let command = command
            .or_else(|| detail(&details, "command_line"))
            .or_else(|| detail(&details, "program"));
        let run_as = run_as.or_else(|| detail(&details, "user"));
        let (done, result) = async_channel::bounded(1);
        self.events
            .send(Event::Begin(Request {
                action_id,
                message,
                icon_name,
                command,
                run_as,
                cookie,
                uids,
                done,
            }))
            .map_err(|_| AgentError::Failed("Agent is shutting down".into()))?;
        result
            .recv()
            .await
            .map_err(|_| AgentError::Cancelled("Agent stopped".into()))?
    }

    fn cancel_authentication(
        &self,
        cookie: String,
        #[zbus(header)] header: Header<'_>,
    ) -> Result<(), AgentError> {
        self.authenticate_sender(&header)?;
        if cookie.len() > 4096 {
            return Err(AgentError::Failed("Invalid authentication cookie".into()));
        }
        self.events
            .send(Event::Cancel(cookie))
            .map_err(|_| AgentError::Failed("Agent stopped".into()))
    }
}

/// Runs separately from GLib. A daemon restart disconnects all conversations;
/// the user service can restart us and obtain a fresh, verified authority owner.
pub fn run(
    events: Sender<Event>,
    locked: Arc<AtomicBool>,
) -> Result<(), Box<dyn std::error::Error>> {
    let connection = Connection::system()?;
    let dbus = Proxy::new(
        &connection,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
    )?;
    let _: u32 = dbus.call("StartServiceByName", &(AUTHORITY, 0u32))?;
    let owner: String = dbus.call("GetNameOwner", &(AUTHORITY,))?;
    let logind = Proxy::new(
        &connection,
        "org.freedesktop.login1",
        "/org/freedesktop/login1",
        "org.freedesktop.login1.Manager",
    )?;
    let session_path = session_path(&connection, &logind)?;
    let session = Proxy::new(
        &connection,
        "org.freedesktop.login1",
        session_path,
        "org.freedesktop.login1.Session",
    )?;
    let session_id: String = session.get_property("Id")?;
    let is_locked = || -> Result<bool, zbus::Error> {
        Ok(session.get_property::<bool>("LockedHint")?
            || !session.get_property::<bool>("Active")?)
    };
    locked.store(is_locked()?, Ordering::Release);
    connection.object_server().at(
        PATH,
        Agent {
            authority_owner: owner.clone(),
            events: events.clone(),
            locked: locked.clone(),
        },
    )?;
    // Pin calls to the same unique owner accepted by our D-Bus interface.
    let authority = Proxy::new(
        &connection,
        owner.as_str(),
        "/org/freedesktop/PolicyKit1/Authority",
        "org.freedesktop.PolicyKit1.Authority",
    )?;
    let mut fields = HashMap::new();
    fields.insert(
        "session-id",
        OwnedValue::from(zbus::zvariant::Str::from(session_id)),
    );
    let subject = ("unix-session", fields);
    let locale = std::env::var("LC_ALL")
        .ok()
        .filter(|v| !v.is_empty())
        .or_else(|| std::env::var("LC_MESSAGES").ok().filter(|v| !v.is_empty()))
        .or_else(|| std::env::var("LANG").ok())
        .unwrap_or_else(|| "C".into());
    let result: Result<(), zbus::Error> =
        authority.call("RegisterAuthenticationAgent", &(&subject, &locale, PATH));
    if let Err(error) = result {
        // This is polkitd's registration answer, not a process-name heuristic.
        if matches!(&error, zbus::Error::MethodError(name, Some(message), _)
            if name.as_str() == "org.freedesktop.PolicyKit1.Error.Failed"
            && message.contains("An authentication agent already exists"))
        {
            eprintln!(
                "denial-polkit-agent: warning: another PolicyKit authentication agent is already \
                 registered for this session; leaving it in charge"
            );
            let _ = events.send(Event::Exit(None));
            return Ok(());
        }
        return Err(error.into());
    }
    eprintln!("denial-polkit-agent: registered for the current login session");
    // Check again only when the authority's owner or the session's lock or
    // activity changes. Subscribe before the first check so no change is missed.
    let (wake, woken) = channel();
    forward(
        zbus::blocking::fdo::DBusProxy::new(&connection)?
            .receive_name_owner_changed_with_args(&[(0, AUTHORITY)])?,
        wake.clone(),
    );
    forward(
        session.receive_property_changed::<bool>("LockedHint"),
        wake.clone(),
    );
    forward(session.receive_property_changed::<bool>("Active"), wake);
    loop {
        let current_owner: String = dbus.call("GetNameOwner", &(AUTHORITY,))?;
        if current_owner != owner {
            return Err("Polkit authority restarted".into());
        }
        let value = is_locked()?;
        if locked.swap(value, Ordering::AcqRel) != value && value {
            events.send(Event::Lock)?;
        }
        woken.recv()?;
    }
}

fn forward<I: Iterator + Send + 'static>(signals: I, wake: Sender<()>) {
    std::thread::spawn(move || {
        for _ in signals {
            if wake.send(()).is_err() {
                break;
            }
        }
    });
}

#[cfg(test)]
mod tests {
    #[test]
    fn pkexec_command_lines_are_recovered() {
        let line = |a: &[&str]| a.join("\0").into_bytes();
        assert_eq!(
            super::pkexec_command(&line(&["pkexec", "true"])),
            Some((Some("true".into()), None))
        );
        assert_eq!(
            super::pkexec_command(&line(&[
                "pkexec",
                "--user",
                "bob",
                "--keep-cwd",
                "ls",
                "-la",
                "my dir"
            ])),
            Some((Some("ls -la 'my dir'".into()), Some("bob".into())))
        );
        assert_eq!(
            super::pkexec_command(&line(&["pkexec", "--user=bob", "--", "-x"])),
            Some((Some("-x".into()), Some("bob".into())))
        );
        assert_eq!(super::pkexec_command(&line(&["pkexec", "--bogus"])), None);
        assert_eq!(
            super::pkexec_command(&line(&["pkexec"])),
            Some((None, None))
        );
    }
    #[test]
    fn display_details_are_single_line_and_bounded() {
        let mut details = std::collections::HashMap::new();
        details.insert("a".to_owned(), " /bin/x\n--flag\t1 ".to_owned());
        details.insert("b".to_owned(), "x".repeat(5000));
        details.insert("c".to_owned(), "  ".to_owned());
        assert_eq!(
            super::detail(&details, "a").as_deref(),
            Some("/bin/x --flag 1")
        );
        assert_eq!(super::detail(&details, "b"), None);
        assert_eq!(super::detail(&details, "c"), None);
        assert_eq!(super::detail(&details, "missing"), None);
    }
    use super::*;
    #[test]
    fn unauthenticated_call_is_rejected() {
        let (events, _) = std::sync::mpsc::channel();
        let agent = Agent {
            authority_owner: ":1.42".into(),
            events,
            locked: Arc::new(AtomicBool::new(false)),
        };
        let message = zbus::Message::method_call(PATH, "CancelAuthentication")
            .unwrap()
            .sender(":1.99")
            .unwrap()
            .build(&())
            .unwrap();
        assert!(agent.authenticate_sender(&message.header()).is_err());
        let message = zbus::Message::method_call(PATH, "CancelAuthentication")
            .unwrap()
            .sender(":1.42")
            .unwrap()
            .build(&())
            .unwrap();
        assert!(agent.authenticate_sender(&message.header()).is_ok());
    }
}
