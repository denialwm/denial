//! Sudo-launched, stdin/stdout-only fingerprint management session.
//! Never starts a compositor or accepts a target user/command from Settings.
//!
//! The lock PIN opens it: fingerprints need one, so the PIN is the credential
//! that guards them, and sudo's rule for this one command needs no password.
//! The session keeps the PIN until it ends, for each enrollment's Gatekeeper
//! authorization where the reader needs one.
use super::*;
use futures_lite::{StreamExt, future};
use serde_json::{Value, json};
use std::io::{BufReader, Write};
use std::sync::mpsc;
use zbus::blocking::{Proxy, connection::Builder};
use zbus::zvariant::OwnedObjectPath;

const SESSION_LIMIT: Duration = Duration::from_secs(300);
const ENROLL_LIMIT: Duration = Duration::from_secs(120);
const FINGERS: [&str; 10] = [
    "left-thumb",
    "left-index-finger",
    "left-middle-finger",
    "left-ring-finger",
    "left-little-finger",
    "right-thumb",
    "right-index-finger",
    "right-middle-finger",
    "right-ring-finger",
    "right-little-finger",
];

struct SettingsCommand {
    value: Value,
}

fn emit(value: Value) -> io::Result<()> {
    let mut output = io::stdout().lock();
    serde_json::to_writer(&mut output, &value)?;
    writeln!(output)?;
    output.flush()
}

pub(crate) fn run() -> Result<(), Box<dyn Error>> {
    // sudo supplies this identity. A non-root caller cannot enter the helper.
    if unsafe { libc::geteuid() } != 0 {
        return Err("fingerprint settings requires sudo".into());
    }
    let uid: libc::uid_t = std::env::var("SUDO_UID")?.parse()?;
    if uid == 0 {
        return Err("a non-root session user is required".into());
    }
    // Keep effective privilege for fprintd, but take the invoking user as the
    // real UID: the PIN record must belong to it.
    // SAFETY: this branch runs before any process threads are started.
    if unsafe { libc::setresuid(uid, 0, 0) } != 0 {
        return Err(io::Error::last_os_error().into());
    }
    let username = current_username();
    let store = pin::PinStore::for_uid(uid).ok_or("no state directory for the lock PIN")?;
    let Some(record) = store.load()? else {
        emit(json!({"event":"pin-not-configured"}))?;
        return Ok(());
    };
    let mut input = BufReader::new(io::stdin());
    emit(json!({"event":"pin","length":record.length()}))?;
    let mut bytes = read_bounded_line(&mut input)?.ok_or("PIN input closed")?;
    let pin = SecureString::new(&bytes);
    erase_bytes(&mut bytes);
    let checked = pin::check_event(Some(&record), &pin)?;
    drop(record);
    if checked["event"] != "confirmed" {
        emit(checked)?;
        return Ok(());
    }
    // No biometric metadata is queried or emitted until the PIN is right.
    let connection = Builder::system()?
        .method_timeout(Duration::from_secs(3))
        .build()?;
    let manager = Proxy::new(
        &connection,
        "net.reactivated.Fprint",
        "/net/reactivated/Fprint/Manager",
        "net.reactivated.Fprint.Manager",
    )?;
    let _: OwnedObjectPath = manager.call("GetDefaultDevice", &())?;
    let bus = zbus::blocking::fdo::DBusProxy::new(&connection)?;
    let owner = bus.get_name_owner("net.reactivated.Fprint".try_into()?)?;
    let manager = Proxy::new(
        &connection,
        owner.clone(),
        "/net/reactivated/Fprint/Manager",
        "net.reactivated.Fprint.Manager",
    )?;
    let path: OwnedObjectPath = manager.call("GetDefaultDevice", &())?;
    let device = Proxy::new(&connection, owner, path, "net.reactivated.Fprint.Device")?;
    let deadline = Instant::now() + SESSION_LIMIT;
    publish_fingers(&device, &username)?;
    let (commands, receiver) = mpsc::sync_channel(8);
    thread::spawn(move || {
        while let Ok(Some(line)) = read_bounded_line(&mut input) {
            let Ok(value) = serde_json::from_slice::<Value>(&line) else {
                break;
            };
            if commands.send(SettingsCommand { value }).is_err() {
                break;
            }
        }
    });
    while let Some(remaining) = deadline.checked_duration_since(Instant::now()) {
        let command = match receiver.recv_timeout(remaining) {
            Ok(command) => command,
            Err(_) => break,
        };
        match command.value.get("command").and_then(Value::as_str) {
            Some("list") => publish_fingers(&device, &username)?,
            Some("enroll") => {
                let finger = command
                    .value
                    .get("finger")
                    .and_then(Value::as_str)
                    .unwrap_or("");
                if !FINGERS.contains(&finger) {
                    emit(json!({"event":"error","code":"invalid-finger"}))?;
                    continue;
                }
                if list_fingers(&device, &username)?
                    .iter()
                    .any(|existing| existing == finger)
                {
                    emit(json!({"event":"error","code":"already-enrolled"}))?;
                    continue;
                }
                let authorization = if gatekeeper::enabled() {
                    let credential = match store.enrollment_credential() {
                        Ok(credential) => credential,
                        Err(_) => {
                            emit(json!({"event":"error","code":"pin-not-configured"}))?;
                            continue;
                        }
                    };
                    let pin = SecureString::new(pin.as_bytes());
                    Some(gatekeeper::Authorization::start(credential, pin)?)
                } else {
                    None
                };
                if let Err(error) = enroll(&device, &username, finger, &receiver, deadline) {
                    // Only a fixed error code reaches the UI; details stay on stderr.
                    eprintln!("fingerprint enrollment: {error}");
                    emit(json!({"event":"error","code":"enrollment-failed"}))?;
                }
                if let Some(error) = authorization
                    .as_ref()
                    .and_then(gatekeeper::Authorization::error)
                {
                    eprintln!("fingerprint authorization: {error}");
                    let (code, retry_ms) = match error {
                        gatekeeper::Failure::Rejected => ("wrong-pin", 0),
                        gatekeeper::Failure::Throttled(ms) => ("rate-limited", ms),
                        _ => ("pin-authorization-failed", 0),
                    };
                    emit(json!({"event":"error","code":code,"retry_ms":retry_ms}))?;
                }
                drop(authorization);
                publish_fingers(&device, &username)?;
            }
            Some("delete") => {
                let finger = command
                    .value
                    .get("finger")
                    .and_then(Value::as_str)
                    .unwrap_or("");
                if !FINGERS.contains(&finger) {
                    emit(json!({"event":"error","code":"invalid-finger"}))?;
                    continue;
                }
                if let Err(error) = delete(&device, &username, finger) {
                    eprintln!("fingerprint removal: {error}");
                    emit(json!({"event":"error","code":"delete-failed"}))?;
                }
                publish_fingers(&device, &username)?;
            }
            Some("cancel") => {}
            _ => break,
        }
    }
    emit(json!({"event":"expired"}))?;
    Ok(())
}

fn list_fingers(device: &Proxy<'_>, username: &str) -> zbus::Result<Vec<String>> {
    match device.call("ListEnrolledFingers", &(username,)) {
        Err(zbus::Error::MethodError(name, _, _))
            if name.as_str() == "net.reactivated.Fprint.Error.NoEnrolledPrints" =>
        {
            Ok(vec![])
        }
        result => result,
    }
}

fn publish_fingers(device: &Proxy<'_>, username: &str) -> Result<(), Box<dyn Error>> {
    let fingers = list_fingers(device, username)?;
    emit(json!({"event":"ready","fingers":fingers}))?;
    Ok(())
}

fn delete(device: &Proxy<'_>, username: &str, finger: &str) -> zbus::Result<()> {
    device.call::<_, _, ()>("Claim", &(username,))?;
    let result = match device.call::<_, _, ()>("DeleteEnrolledFinger", &(finger,)) {
        // fprintd forgets the finger even when the reader keeps it.
        Err(zbus::Error::MethodError(name, _, _))
            if name.as_str() == "net.reactivated.Fprint.Error.PrintsNotDeletedFromDevice" =>
        {
            Ok(())
        }
        result => result,
    };
    let _ = device.call::<_, _, ()>("Release", &());
    result
}

fn enroll(
    device: &Proxy<'_>,
    username: &str,
    finger: &str,
    commands: &mpsc::Receiver<SettingsCommand>,
    session_deadline: Instant,
) -> Result<(), Box<dyn Error>> {
    device.call::<_, _, ()>("Claim", &(username,))?;
    let result = enroll_claimed(device, finger, commands, session_deadline);
    let _ = device.call::<_, _, ()>("EnrollStop", &());
    let _ = device.call::<_, _, ()>("Release", &());
    result
}

fn enroll_claimed(
    device: &Proxy<'_>,
    finger: &str,
    commands: &mpsc::Receiver<SettingsCommand>,
    session_deadline: Instant,
) -> Result<(), Box<dyn Error>> {
    let mut statuses = future::block_on(device.inner().receive_signal("EnrollStatus"))?;
    let mut owner_changes = future::block_on(device.inner().receive_owner_changed())?;
    let total = device
        .get_property::<i32>("num-enroll-stages")?
        .clamp(1, 100);
    let mut completed = 0;
    device.call::<_, _, ()>("EnrollStart", &(finger,))?;
    emit(json!({"event":"enrollment","status":"started","completed":0,"total":total}))?;
    let deadline = (Instant::now() + ENROLL_LIMIT).min(session_deadline);
    loop {
        match commands.try_recv() {
            Ok(_) | Err(mpsc::TryRecvError::Disconnected) => {
                emit(json!({"event":"enrollment","status":"cancelled"}))?;
                return Ok(());
            }
            Err(mpsc::TryRecvError::Empty) => {}
        }
        if Instant::now() >= deadline {
            return Err("enrollment timed out".into());
        }
        let status = future::block_on(future::race(
            future::race(async { Some(statuses.next().await) }, async {
                owner_changes.next().await;
                Some(None)
            }),
            async {
                async_io::Timer::after(Duration::from_millis(100)).await;
                None
            },
        ));
        match status {
            Some(Some(message)) => {
                let (status, done): (String, bool) = message.body().deserialize()?;
                if status == "enroll-stage-passed" {
                    completed = (completed + 1).min(total);
                }
                if status == "enroll-completed" && done {
                    completed = total;
                }
                emit(
                    json!({"event":"enrollment","status":status,"completed":completed,"total":total}),
                )?;
                if done {
                    return Ok(());
                }
            }
            Some(None) => return Err("fingerprint device disconnected".into()),
            None => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    struct EnrollmentDevice {
        stops: Arc<std::sync::atomic::AtomicUsize>,
        releases: Arc<std::sync::atomic::AtomicUsize>,
        mode: Arc<Mutex<String>>,
    }
    #[zbus::interface(name = "net.reactivated.Fprint.Device")]
    impl EnrollmentDevice {
        fn claim(&self, username: &str) {
            assert_eq!(username, "test-user");
        }
        #[zbus(property, name = "num-enroll-stages")]
        fn num_enroll_stages(&self) -> i32 {
            2
        }
        async fn enroll_start(
            &self,
            finger: &str,
            #[zbus(signal_emitter)] emitter: zbus::object_server::SignalEmitter<'_>,
        ) -> zbus::fdo::Result<()> {
            assert_eq!(finger, "left-thumb");
            let mode = lock_unpoisoned(&self.mode).clone();
            if mode == "error" {
                return Err(zbus::fdo::Error::Failed("test".into()));
            }
            if mode == "complete" {
                Self::enroll_status(&emitter, "enroll-stage-passed", false).await?;
                Self::enroll_status(&emitter, "enroll-completed", true).await?;
            }
            Ok(())
        }
        fn enroll_stop(&self) {
            self.stops.fetch_add(1, Ordering::SeqCst);
        }
        fn release(&self) {
            self.releases.fetch_add(1, Ordering::SeqCst);
        }
        #[zbus(signal)]
        async fn enroll_status(
            emitter: &zbus::object_server::SignalEmitter<'_>,
            status: &str,
            done: bool,
        ) -> zbus::Result<()>;
    }

    #[test]
    fn enrollment_completes_and_cleans_up_on_cancel_and_start_failure() {
        if std::env::var_os("DENIAL_FPRINT_TEST_BUS").is_none() {
            return;
        }
        let stops = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let releases = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let mode = Arc::new(Mutex::new("complete".into()));
        let server = Builder::session()
            .unwrap()
            .serve_at(
                "/test/reader",
                EnrollmentDevice {
                    stops: Arc::clone(&stops),
                    releases: Arc::clone(&releases),
                    mode: Arc::clone(&mode),
                },
            )
            .unwrap()
            .build()
            .unwrap();
        let client = Builder::session().unwrap().build().unwrap();
        let device = Proxy::new(
            &client,
            server.unique_name().unwrap(),
            "/test/reader",
            "net.reactivated.Fprint.Device",
        )
        .unwrap();
        let (sender, receiver) = mpsc::sync_channel(1);
        let deadline = Instant::now() + Duration::from_secs(2);
        enroll(&device, "test-user", "left-thumb", &receiver, deadline).unwrap();
        *lock_unpoisoned(&mode) = "silent".into();
        sender
            .send(SettingsCommand {
                value: json!({"command":"cancel"}),
            })
            .unwrap();
        enroll(&device, "test-user", "left-thumb", &receiver, deadline).unwrap();
        *lock_unpoisoned(&mode) = "error".into();
        assert!(enroll(&device, "test-user", "left-thumb", &receiver, deadline).is_err());
        assert_eq!(stops.load(Ordering::SeqCst), 3);
        assert_eq!(releases.load(Ordering::SeqCst), 3);
    }

    #[test]
    fn input_is_bounded_and_preserves_command_boundaries() {
        let mut input = &b"482916\n{\"command\":\"list\"}\n"[..];
        assert_eq!(read_bounded_line(&mut input).unwrap().unwrap(), b"482916");
        assert_eq!(
            read_bounded_line(&mut input).unwrap().unwrap(),
            b"{\"command\":\"list\"}"
        );
        assert!(read_bounded_line(&mut &vec![b'x'; 4097][..]).is_err());
        assert!(read_bounded_line(&mut &b"unterminated"[..]).is_err());
    }
}
