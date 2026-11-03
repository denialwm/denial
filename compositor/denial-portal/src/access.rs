//! `org.freedesktop.impl.portal.Access`: Denial's "allow or deny" dialog.
//!
//! The xdg-desktop-portal frontend asks through it for camera, microphone and
//! location access, and deniald for apps that want all keyboard shortcuts.
//! Callers keep the answer; this backend only asks. Each request runs the
//! native dialog of `polkit_app` in its access mode, as a centered overlay,
//! and talks to it over a private socket.
//!
//! Dialog IPC, schema 1: UTF-8 JSON lines, at most 16 KiB each.
//!
//! | Direction | Type | Fields |
//! | --- | --- | --- |
//! | UI → backend | `hello` | `token` |
//! | Backend → UI | `request` | `schema`, `appId`, `title`, `subtitle`, `body`, `grantLabel`, `denyLabel`, `choices: [{id, label, options: [{id, label}], initial}]` |
//! | UI → backend | `answer` | `grant`, `choices: {id: value}` |
//! | UI → backend | `cancel` | no other fields |
//!
//! A choice without options is a boolean, `"true"` or `"false"`.

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::{Value as Json, json};
use tracing::{info, warn};
use zbus::object_server::ObjectServer;
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};

const SCHEMA: u32 = 1;
const MAX_MESSAGE_BYTES: usize = 16_384;
/// The dialog connects within moments of starting. The bound only ends a
/// request whose dialog never came up.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(30);
const POLL_INTERVAL: Duration = Duration::from_millis(100);

const RESPONSE_GRANTED: u32 = 0;
const RESPONSE_DENIED: u32 = 1;
const RESPONSE_ENDED: u32 = 2;

/// Where the dialog bundle lives. Its runner and engine sit at fixed places
/// inside it.
#[derive(Clone)]
pub(crate) struct DialogBundle(pub(crate) PathBuf);

impl DialogBundle {
    fn runner(&self) -> PathBuf {
        self.0.join("denial-app")
    }

    fn engine(&self) -> PathBuf {
        self.0.join("lib/libflutter_engine.so")
    }
}

pub(crate) struct AccessInterface {
    pub(crate) bundle: DialogBundle,
}

type Choice = (String, String, Vec<(String, String)>, String);

#[zbus::interface(
    name = "org.freedesktop.impl.portal.Access",
    introspection_docs = false
)]
impl AccessInterface {
    #[allow(clippy::too_many_arguments)]
    #[zbus(name = "AccessDialog", out_args("response", "results"))]
    async fn access_dialog(
        &self,
        #[zbus(object_server)] server: &ObjectServer,
        handle: OwnedObjectPath,
        app_id: String,
        _parent_window: String,
        title: String,
        subtitle: String,
        body: String,
        options: HashMap<String, OwnedValue>,
    ) -> (u32, HashMap<String, OwnedValue>) {
        let text = |key: &str| {
            options
                .get(key)
                .and_then(|value| String::try_from(value.clone()).ok())
                .unwrap_or_default()
        };
        let choices: Vec<Choice> = options
            .get("choices")
            .and_then(|value| Vec::<Choice>::try_from(value.clone()).ok())
            .unwrap_or_default();
        let request = json!({
            "type": "request",
            "schema": SCHEMA,
            "appId": app_id,
            "title": title,
            "subtitle": subtitle,
            "body": body,
            "grantLabel": text("grant_label"),
            "denyLabel": text("deny_label"),
            "choices": choices.iter().map(|(id, label, options, initial)| json!({
                "id": id,
                "label": label,
                "options": options.iter().map(|(id, label)| json!({"id": id, "label": label})).collect::<Vec<_>>(),
                "initial": initial,
            })).collect::<Vec<_>>(),
        });

        let (closed, close_requested) = async_channel::bounded(1);
        let (answered, answer) = async_channel::bounded(1);
        if let Err(error) = server.at(&handle, RequestInterface { closed }).await {
            warn!(%error, handle = %handle, "could not export the access request");
            return (RESPONSE_ENDED, HashMap::new());
        }
        let bundle = self.bundle.clone();
        let worker = std::thread::Builder::new()
            .name("access-dialog".to_owned())
            .spawn(move || {
                let outcome = ask(&bundle, &request, &close_requested).unwrap_or_else(|error| {
                    warn!(%error, "access dialog failed");
                    Outcome::Ended
                });
                let _ = answered.send_blocking(outcome);
            });
        let outcome = match worker {
            Ok(_) => answer.recv().await.unwrap_or(Outcome::Ended),
            Err(error) => {
                warn!(%error, "could not start the access dialog");
                Outcome::Ended
            }
        };
        let _ = server.remove::<RequestInterface, _>(&handle).await;

        let Outcome::Answered { granted, selected } = outcome else {
            return (RESPONSE_ENDED, HashMap::new());
        };
        info!(app_id = %app_id, granted, "access answered");
        // Report every choice the caller offered, as the user left it, on a
        // denial too: "remember" then means "never".
        let reported: Vec<(String, String)> = choices
            .into_iter()
            .map(|(id, _, _, initial)| {
                let value = selected.get(&id).cloned().unwrap_or(initial);
                (id, value)
            })
            .collect();
        let mut results = HashMap::new();
        if let Ok(value) = OwnedValue::try_from(Value::from(reported)) {
            results.insert("choices".to_owned(), value);
        }
        let response = if granted {
            RESPONSE_GRANTED
        } else {
            RESPONSE_DENIED
        };
        (response, results)
    }

    #[zbus(property, name = "version")]
    fn version(&self) -> u32 {
        1
    }
}

/// `org.freedesktop.impl.portal.Request` at the caller's handle, so the
/// caller can withdraw a question the user has not answered yet.
struct RequestInterface {
    closed: async_channel::Sender<()>,
}

#[zbus::interface(
    name = "org.freedesktop.impl.portal.Request",
    introspection_docs = false
)]
impl RequestInterface {
    #[zbus(name = "Close")]
    fn close(&self) {
        let _ = self.closed.try_send(());
    }
}

enum Outcome {
    Answered {
        granted: bool,
        selected: HashMap<String, String>,
    },
    /// Closed by the caller, or the dialog went away without an answer.
    Ended,
}

/// Runs one dialog to its answer. Blocks; called on a worker thread.
fn ask(
    bundle: &DialogBundle,
    request: &Json,
    close_requested: &async_channel::Receiver<()>,
) -> io::Result<Outcome> {
    let runtime = std::env::var_os("XDG_RUNTIME_DIR")
        .ok_or_else(|| io::Error::other("XDG_RUNTIME_DIR is required"))?;
    let directory = tempfile::Builder::new()
        .prefix("denial-access-")
        .tempdir_in(runtime)?;
    fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700))?;
    let path = directory.path().join("ui.sock");
    let listener = UnixListener::bind(&path)?;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
    listener.set_nonblocking(true)?;
    let mut random = [0u8; 32];
    File::open("/dev/urandom")?.read_exact(&mut random)?;
    let token: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
    let child = Command::new(bundle.runner())
        .arg("--bundle")
        .arg(&bundle.0)
        .arg("--engine")
        .arg(bundle.engine())
        .args([
            "--app-id",
            "dev.denial.Access",
            "--title",
            "Permission",
            // A centered, undecorated overlay with exclusive keyboard focus.
            // The dialog draws its card inside this transparent canvas.
            "--overlay",
            "--width",
            "600",
            "--height",
            "500",
        ])
        .env("DENIAL_ACCESS_SOCKET", &path)
        .env("DENIAL_ACCESS_TOKEN", &token)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()
        .map_err(|error| io::Error::other(format!("could not start the access dialog: {error}")))?;
    let mut dialog = Dialog(child);
    let closed = || close_requested.try_recv().is_ok();

    let deadline = Instant::now() + HANDSHAKE_TIMEOUT;
    let stream = loop {
        if closed() || dialog.exited() || Instant::now() >= deadline {
            return Ok(Outcome::Ended);
        }
        match listener.accept() {
            Ok((stream, _)) => break stream,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(20));
            }
            Err(error) => return Err(error),
        }
    };
    stream.set_read_timeout(Some(POLL_INTERVAL))?;
    stream.set_write_timeout(Some(POLL_INTERVAL))?;
    let mut writer = stream.try_clone()?;
    let mut reader = Lines::new(stream);
    let mut greeted = false;
    loop {
        if closed() {
            return Ok(Outcome::Ended);
        }
        if !greeted && Instant::now() >= deadline {
            return Ok(Outcome::Ended);
        }
        let message = match reader.next() {
            Ok(Some(message)) => message,
            Ok(None) => continue,
            // Closed without an answer.
            Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => {
                return Ok(Outcome::Ended);
            }
            Err(error) => return Err(error),
        };
        match (greeted, message["type"].as_str()) {
            (false, Some("hello")) if message["token"].as_str() == Some(token.as_str()) => {
                greeted = true;
                serde_json::to_writer(&mut writer, request)?;
                writer.write_all(b"\n")?;
            }
            (false, _) => return Err(io::Error::other("invalid access dialog handshake")),
            (true, Some("answer")) => {
                let selected = message["choices"]
                    .as_object()
                    .map(|choices| {
                        choices
                            .iter()
                            .filter_map(|(id, value)| {
                                Some((id.clone(), value.as_str()?.to_owned()))
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                return Ok(Outcome::Answered {
                    granted: message["grant"].as_bool() == Some(true),
                    selected,
                });
            }
            (true, Some("cancel")) => {
                return Ok(Outcome::Answered {
                    granted: false,
                    selected: HashMap::new(),
                });
            }
            (true, _) => return Err(io::Error::other("invalid access dialog message")),
        }
    }
}

/// The dialog process. Ends with the request, whichever way it ends.
struct Dialog(Child);

impl Dialog {
    fn exited(&mut self) -> bool {
        self.0.try_wait().map_or(true, |status| status.is_some())
    }
}

impl Drop for Dialog {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// Bounded JSON lines, kept whole across read timeouts.
struct Lines {
    reader: BufReader<UnixStream>,
    buffer: Vec<u8>,
}

impl Lines {
    fn new(stream: UnixStream) -> Self {
        Self {
            reader: BufReader::new(stream),
            buffer: Vec::new(),
        }
    }

    /// The next whole message, `None` while one is still arriving.
    fn next(&mut self) -> io::Result<Option<Json>> {
        let available = match self.reader.fill_buf() {
            Ok(available) => available,
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) =>
            {
                return Ok(None);
            }
            Err(error) => return Err(error),
        };
        if available.is_empty() {
            return Err(io::ErrorKind::UnexpectedEof.into());
        }
        let count = available
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(available.len(), |index| index + 1);
        if self.buffer.len() + count > MAX_MESSAGE_BYTES {
            return Err(io::Error::other("access dialog message exceeds limit"));
        }
        self.buffer.extend_from_slice(&available[..count]);
        self.reader.consume(count);
        if self.buffer.last() != Some(&b'\n') {
            return Ok(None);
        }
        let message = serde_json::from_slice(&self.buffer)
            .map_err(|_| io::Error::other("invalid access dialog message"));
        self.buffer.clear();
        message.map(Some)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lines(bytes: &[u8]) -> (Lines, UnixStream) {
        let (ours, theirs) = UnixStream::pair().unwrap();
        ours.set_read_timeout(Some(Duration::from_millis(20)))
            .unwrap();
        (&theirs).write_all(bytes).unwrap();
        (Lines::new(ours), theirs)
    }

    #[test]
    fn a_message_split_across_reads_is_read_whole() {
        let (mut reader, mut theirs) = lines(b"{\"type\":\"ans");
        assert!(reader.next().unwrap().is_none());
        theirs.write_all(b"wer\",\"grant\":true}\n").unwrap();
        let message = reader.next().unwrap().unwrap();
        assert_eq!(message["type"], "answer");
        assert_eq!(message["grant"], true);
        drop(theirs);
        assert_eq!(
            reader.next().unwrap_err().kind(),
            io::ErrorKind::UnexpectedEof
        );
    }

    const TEST_SERVICE: &str = "org.freedesktop.impl.portal.desktop.denial.test";
    const TEST_APP: &str = "org.example.App";

    /// Stands in for the dialog: the Access test starts this test binary as
    /// the bundle's runner. It answers "Always allow", or "Never allow" when
    /// `DENIAL_TEST_GRANT` is `false`.
    #[test]
    fn stand_in_dialog() {
        let (Some(path), Some(token)) = (
            std::env::var_os("DENIAL_ACCESS_SOCKET"),
            std::env::var("DENIAL_ACCESS_TOKEN").ok(),
        ) else {
            return;
        };
        let mut stream = UnixStream::connect(path).unwrap();
        writeln!(stream, "{}", json!({"type": "hello", "token": token})).unwrap();
        let mut request = String::new();
        BufReader::new(stream.try_clone().unwrap())
            .read_line(&mut request)
            .unwrap();
        let request: Json = serde_json::from_str(&request).unwrap();
        assert_eq!(request["appId"], TEST_APP);
        assert_eq!(request["choices"][0]["id"], "remember");
        writeln!(
            stream,
            "{}",
            json!({
                "type": "answer",
                "grant": std::env::var("DENIAL_TEST_GRANT").as_deref() != Ok("false"),
                "choices": {"remember": "true"},
            })
        )
        .unwrap();
        // The backend ends this process once it has the answer.
        let _ = stream.read(&mut [0; 1]);
    }

    #[test]
    fn asks_through_the_dialog_and_reports_its_choices() {
        if std::env::var_os("DENIAL_PORTAL_TEST_BUS").is_none() {
            return;
        }
        let bundle = tempfile::tempdir().unwrap();
        let runner = bundle.path().join("denial-app");
        let _server = zbus::blocking::connection::Builder::session()
            .and_then(|builder| builder.name(TEST_SERVICE))
            .and_then(|builder| {
                builder.serve_at(
                    "/org/freedesktop/portal/desktop",
                    AccessInterface {
                        bundle: DialogBundle(bundle.path().to_owned()),
                    },
                )
            })
            .and_then(zbus::blocking::connection::Builder::build)
            .expect("serve Access on the private bus");
        let client = zbus::blocking::Connection::session().unwrap();
        // "Always allow", then "Never allow": a denial reports its choices too.
        for (grant, expected) in [(true, RESPONSE_GRANTED), (false, RESPONSE_DENIED)] {
            fs::write(
                &runner,
                format!(
                    "#!/bin/sh\nDENIAL_TEST_GRANT={grant} exec '{}' --exact access::tests::stand_in_dialog --nocapture\n",
                    std::env::current_exe().unwrap().display()
                ),
            )
            .unwrap();
            fs::set_permissions(&runner, fs::Permissions::from_mode(0o755)).unwrap();
            let choices = vec![(
                "remember",
                "Remember this answer",
                Vec::<(&str, &str)>::new(),
                "false",
            )];
            let options = HashMap::from([("choices", Value::from(choices))]);
            let handle = format!("/org/freedesktop/portal/desktop/request/test/access{grant}");
            let reply = client
                .call_method(
                    Some(TEST_SERVICE),
                    "/org/freedesktop/portal/desktop",
                    Some("org.freedesktop.impl.portal.Access"),
                    "AccessDialog",
                    &(
                        zbus::zvariant::ObjectPath::try_from(handle.as_str()).unwrap(),
                        TEST_APP,
                        "",
                        "Title",
                        "Subtitle",
                        "Body",
                        options,
                    ),
                )
                .expect("ask through the Access dialog");
            let (response, results): (u32, HashMap<String, OwnedValue>) =
                reply.body().deserialize().unwrap();
            assert_eq!(response, expected);
            let choices = Vec::<(String, String)>::try_from(results["choices"].clone()).unwrap();
            assert_eq!(choices, [("remember".to_owned(), "true".to_owned())]);
        }
    }

    #[test]
    fn an_oversized_message_is_refused() {
        let (mut reader, _theirs) = lines(&vec![b'x'; MAX_MESSAGE_BYTES + 1]);
        let result = (0..4).find_map(|_| reader.next().err());
        assert!(result.is_some());
    }
}
