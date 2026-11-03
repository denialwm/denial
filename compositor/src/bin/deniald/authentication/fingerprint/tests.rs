use super::*;
use std::sync::atomic::AtomicUsize;
use std::sync::mpsc;

/// A controller whose account has a PIN, which fingerprint unlock needs;
/// its first credential event is already taken.
fn controller(locked: bool) -> AuthenticationController {
    static STORE: std::sync::OnceLock<pin::PinStore> = std::sync::OnceLock::new();
    let store = STORE.get_or_init(|| {
        let store = super::super::tests::temporary_pin_store("fingerprint");
        super::super::tests::write_quick_record(&store, "482916");
        store
    });
    let controller = controller_with(Some(store.clone()), locked);
    let deadline = Instant::now() + Duration::from_secs(5);
    while lock_unpoisoned(&controller.shared.state).pin_length == 0 {
        assert!(Instant::now() < deadline, "the PIN record was not read");
        thread::sleep(Duration::from_millis(1));
    }
    while controller.try_event().is_some() {}
    controller
}

fn controller_with(pin_store: Option<pin::PinStore>, locked: bool) -> AuthenticationController {
    AuthenticationController::with_backend(
        Box::new(UnavailableBackend {
            reason: "test".into(),
        }),
        pin_store,
        locked,
    )
    .unwrap()
}

#[test]
fn without_a_pin_the_reader_stays_off() {
    let controller = controller_with(None, true);
    publish_readiness(&controller.shared, true);
    while let Some(event) = controller.try_event() {
        assert!(event.message.is_empty());
    }
    assert!(cancelled(&controller.shared, 0));
}

#[test]
fn only_completed_match_authenticates() {
    assert_eq!(
        classify_status("verify-match", true),
        Some(Verification::Match)
    );
    assert_eq!(
        classify_status("verify-match", false),
        Some(Verification::Unavailable)
    );
    assert_eq!(
        classify_status("verify-no-match", true),
        Some(Verification::NoMatch)
    );
    for status in [
        "verify-disconnected",
        "verify-unknown-error",
        "enroll-completed",
        "",
        "match",
    ] {
        assert_eq!(
            classify_status(status, true),
            Some(Verification::Unavailable)
        );
    }
    assert_eq!(classify_status("verify-retry-scan", false), None);
    assert_eq!(
        classify_status("verify-retry-scan", true),
        Some(Verification::Unavailable)
    );
}

#[test]
fn rejection_feedback_is_advisory_and_stale_epochs_are_ignored() {
    let controller = controller(true);
    let (haptics, requests) = crate::haptics::HapticsClient::recording();
    assert!(controller.shared.haptics.set(haptics).is_ok());
    let before = {
        let state = lock_unpoisoned(&controller.shared.state);
        (state.generation, state.busy, state.failure_count)
    };
    publish_no_match(&controller.shared, 0);
    let event = controller.try_event().unwrap();
    assert_eq!(event.kind, AuthenticationEventKind::FingerprintFeedback);
    assert_eq!(event.encode()[6], KIND_FINGERPRINT_FEEDBACK);
    assert_eq!(event.message, "no-match");
    assert_eq!(
        requests.try_recv().unwrap().kind,
        crate::haptics::Kind::FingerprintRejected
    );
    assert!(controller.locked());
    let state = lock_unpoisoned(&controller.shared.state);
    assert_eq!((state.generation, state.busy, state.failure_count), before);
    drop(state);
    controller.lock();
    while controller.try_event().is_some() {}
    publish_no_match(&controller.shared, 0);
    assert!(controller.try_event().is_none());
    assert!(requests.try_recv().is_err());
}

#[test]
fn switched_off_fingerprint_hides_the_sensor_and_stops_the_reader() {
    let controller = controller(true);
    publish_readiness(&controller.shared, true);
    while controller.try_event().is_some() {}
    assert!(!cancelled(&controller.shared, 0));
    controller.enable_fingerprint(false);
    let event = controller.try_event().unwrap();
    assert!(matches!(
        event.kind,
        AuthenticationEventKind::Credential { .. }
    ));
    assert!(event.message.is_empty());
    assert!(cancelled(&controller.shared, 0));
    controller.enable_fingerprint(false);
    assert!(controller.try_event().is_none());
    controller.enable_fingerprint(true);
    assert!(
        controller
            .try_event()
            .unwrap()
            .message
            .contains("fingerprint")
    );
}

#[test]
fn idle_unlock_check_does_not_lock_authentication_state() {
    let controller = controller(true);
    let state = lock_unpoisoned(&controller.shared.state);
    assert!(!controller.advance_fingerprint_unlock(Instant::now(), false));
    drop(state);
}

#[test]
fn match_unlocks_once_and_preserves_compositor_gate() {
    let controller = controller(true);
    assert!(complete_match(&controller.shared, 0));
    assert!(controller.locked());
    assert!(controller.try_event().is_none());
    assert!(!controller.advance_fingerprint_unlock(Instant::now(), true));
    assert!(!controller.locked());
    assert!(controller.security_gate_locked());
    assert!(!complete_match(&controller.shared, 0));
    controller.acknowledge_unlocked_boundary();
    assert!(!controller.security_gate_locked());
}

#[test]
fn screen_off_match_unlocks_with_the_wake_frame() {
    let controller = controller(true);
    let now = Instant::now();
    assert!(!controller.fingerprint_unlock_pending());
    // No match means no wake, even with the screen off.
    assert!(!controller.advance_fingerprint_unlock(now, false));
    assert!(complete_match(&controller.shared, 0));
    assert!(controller.fingerprint_unlock_pending());
    assert!(controller.advance_fingerprint_unlock(now, false));
    assert!(controller.locked());
    assert!(controller.security_gate_locked());
    assert!(controller.try_event().is_none());
    let presented = now + Duration::from_secs(1);
    assert!(controller.advance_fingerprint_unlock(presented, false));
    assert!(controller.locked());
    assert!(!controller.advance_fingerprint_unlock(presented, true));
    assert!(!controller.fingerprint_unlock_pending());
    assert!(!controller.locked());
    assert!(controller.security_gate_locked());
    let event = controller.try_event().unwrap();
    assert_eq!(
        event.kind,
        AuthenticationEventKind::Result {
            success: true,
            cancelled: false
        }
    );
    controller.advance_fingerprint_unlock(presented + Duration::from_secs(2), true);
    assert!(controller.try_event().is_none());
}

#[test]
fn relock_invalidates_a_validated_match_during_display_wake() {
    let controller = controller(true);
    let now = Instant::now();
    assert!(complete_match(&controller.shared, 0));
    assert!(controller.advance_fingerprint_unlock(now, false));
    controller.lock();
    assert!(!controller.fingerprint_unlock_pending());
    while controller.try_event().is_some() {}
    controller.advance_fingerprint_unlock(now + Duration::from_secs(1), true);
    assert!(controller.locked());
    assert!(controller.security_gate_locked());
    assert!(controller.try_event().is_none());
}

#[test]
fn relock_and_shutdown_reject_late_match() {
    let controller = controller(true);
    controller.lock();
    assert!(!complete_match(&controller.shared, 0));
    assert!(controller.locked());
    lock_unpoisoned(&controller.shared.state).stopping = true;
    assert!(!complete_match(&controller.shared, 1));
    assert!(controller.locked());
}

struct ControlledBackend {
    started: mpsc::Sender<()>,
    result: mpsc::Receiver<Verification>,
}

impl FingerprintBackend for ControlledBackend {
    fn verify(
        &mut self,
        _armed: &dyn Fn(),
        _scanning: &dyn Fn(bool),
        cancelled: &dyn Fn() -> bool,
        _changed: &Wakeup,
    ) -> Verification {
        self.started.send(()).unwrap();
        loop {
            if cancelled() {
                return Verification::Cancelled;
            }
            match self.result.recv_timeout(Duration::from_millis(10)) {
                Ok(result) => return result,
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(_) => return Verification::Unavailable,
            }
        }
    }
}

#[test]
fn worker_is_idle_unlocked_and_failures_do_not_unlock() {
    let controller = controller(false);
    let (started, starts) = mpsc::channel();
    let (results, result) = mpsc::channel();
    let shared = Arc::clone(&controller.shared);
    let worker =
        thread::spawn(move || run_worker(&shared, &mut ControlledBackend { started, result }));
    *lock_unpoisoned(&controller.fingerprint_worker) = Some(worker);
    assert!(starts.recv_timeout(Duration::from_millis(50)).is_err());
    controller.lock();
    starts.recv_timeout(Duration::from_secs(2)).unwrap();
    results.send(Verification::NoMatch).unwrap();
    // The real worker must finish the rejected scan before retrying.
    starts.recv_timeout(Duration::from_secs(2)).unwrap();
    assert!(controller.locked());
    // An unusable reader is tried again once at once, then backs off.
    results.send(Verification::Unavailable).unwrap();
    starts.recv_timeout(Duration::from_secs(2)).unwrap();
    results.send(Verification::Unavailable).unwrap();
    assert!(starts.recv_timeout(Duration::from_millis(100)).is_err());
    assert!(controller.locked());
    controller.lock();
    starts.recv_timeout(Duration::from_secs(2)).unwrap();
    results.send(Verification::Match).unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    while controller.locked() {
        assert!(Instant::now() < deadline);
        controller.advance_fingerprint_unlock(Instant::now(), true);
        thread::yield_now();
    }
    assert!(starts.recv_timeout(Duration::from_millis(50)).is_err());
    // Drop joins the worker, covering cancellation and waking idle waits.
}

#[test]
fn reader_answers_only_while_the_lock_screen_offers_it() {
    let controller = controller(false);
    let (started, starts) = mpsc::channel();
    let (results, result) = mpsc::channel();
    let shared = Arc::clone(&controller.shared);
    let worker =
        thread::spawn(move || run_worker(&shared, &mut ControlledBackend { started, result }));
    *lock_unpoisoned(&controller.fingerprint_worker) = Some(worker);
    // Ignored while unlocked: every lock opens on the fingerprint face.
    controller.offer_fingerprint(false);
    controller.lock();
    starts.recv_timeout(Duration::from_secs(2)).unwrap();
    // A typed credential cancels the armed reader and keeps it idle, also
    // across a repeated lock.
    controller.offer_fingerprint(false);
    controller.lock();
    assert!(starts.recv_timeout(Duration::from_millis(100)).is_err());
    // Back on the fingerprint face the reader arms again.
    controller.offer_fingerprint(true);
    starts.recv_timeout(Duration::from_secs(2)).unwrap();
    results.send(Verification::NoMatch).unwrap();
    starts.recv_timeout(Duration::from_secs(2)).unwrap();
}

#[test]
fn armed_reader_is_announced_once_and_stays_marked_between_scans() {
    let controller = controller(true);
    publish_readiness(&controller.shared, false);
    assert!(controller.try_event().is_none());
    publish_readiness(&controller.shared, true);
    publish_readiness(&controller.shared, true);
    let event = controller.try_event().expect("readiness event");
    assert!(matches!(
        event.kind,
        AuthenticationEventKind::Credential { pin_length: 6 }
    ));
    assert!(event.message.starts_with(r#"{"fingerprint":"#));
    assert!(event.message.contains(r#""ready":true"#));
    assert!(controller.try_event().is_none());
    publish_readiness(&controller.shared, false);
    let event = controller.try_event().expect("re-arming");
    assert!(event.message.contains(r#""ready":false"#));
}

#[test]
fn scan_feedback_is_advisory_and_clears() {
    let controller = controller(true);
    publish_readiness(&controller.shared, true);
    while controller.try_event().is_some() {}
    publish_scanning(&controller.shared, true);
    let event = controller.try_event().expect("scan start");
    assert!(event.message.contains(r#""scanning":true"#));
    assert!(controller.locked());
    publish_scanning(&controller.shared, false);
    let event = controller.try_event().expect("scan end");
    assert!(event.message.contains(r#""scanning":false"#));
    assert!(controller.locked());
}

#[test]
fn unavailable_reader_retries_promptly_without_a_new_lock() {
    let controller = controller(true);
    let (started, starts) = mpsc::channel();
    let (results, result) = mpsc::channel();
    let shared = Arc::clone(&controller.shared);
    let worker =
        thread::spawn(move || run_worker(&shared, &mut ControlledBackend { started, result }));
    *lock_unpoisoned(&controller.fingerprint_worker) = Some(worker);
    starts.recv_timeout(Duration::from_secs(2)).unwrap();
    results.send(Verification::Unavailable).unwrap();
    starts.recv_timeout(Duration::from_secs(2)).unwrap();
    assert!(controller.locked());
    assert!(controller.security_gate_locked());
    assert!(controller.try_event().is_none());
    // The second attempt is already listening; no relock or input needed.
    results.send(Verification::Match).unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    while controller.locked() {
        assert!(Instant::now() < deadline);
        controller.advance_fingerprint_unlock(Instant::now(), true);
        thread::yield_now();
    }
    assert!(starts.recv_timeout(Duration::from_millis(50)).is_err());
}

#[test]
fn unavailable_backoff_is_bounded() {
    assert_eq!(unavailable_retry(1), Duration::ZERO);
    assert_eq!(unavailable_retry(2), Duration::from_secs(1));
    assert_eq!(unavailable_retry(3), Duration::from_secs(2));
    assert_eq!(unavailable_retry(7), MAX_UNAVAILABLE_RETRY);
    assert_eq!(unavailable_retry(u32::MAX), MAX_UNAVAILABLE_RETRY);
    assert_eq!(cooldown_for(1), Duration::from_millis(750));
    assert_eq!(cooldown_for(u32::MAX), Duration::from_secs(30));
}

struct PasswordBackend;
impl AuthenticationBackend for PasswordBackend {
    fn available(&self) -> bool {
        true
    }
    fn unavailable_reason(&self) -> String {
        String::new()
    }
    fn validate_account(&self) -> Result<(), String> {
        Ok(())
    }
    fn authenticate(
        &mut self,
        _: &str,
        conversation: &mut dyn FnMut(PromptStyle, &str) -> Option<SecureString>,
        _: &dyn Fn() -> bool,
    ) -> BackendResult {
        let _ = conversation(PromptStyle::EchoOff, "Password:");
        // Deliberately late success must be invalidated by fingerprint unlock.
        BackendResult::Success
    }
}

#[test]
fn fingerprint_cancels_password_prompt_and_invalidates_its_late_success() {
    let controller =
        AuthenticationController::with_backend(Box::new(PasswordBackend), None, true).unwrap();
    controller.begin(false);
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        if lock_unpoisoned(&controller.shared.state).prompt.is_some() {
            break;
        }
        assert!(Instant::now() < deadline);
        thread::yield_now();
    }
    assert!(complete_match(&controller.shared, 0));
    controller.lock();
    loop {
        if !lock_unpoisoned(&controller.shared.state).busy {
            break;
        }
        assert!(Instant::now() < deadline);
        thread::yield_now();
    }
    assert!(controller.locked());
    assert!(controller.security_gate_locked());
    assert!(lock_unpoisoned(&controller.shared.state).prompt.is_none());
}

struct MockManager;
#[zbus::interface(name = "net.reactivated.Fprint.Manager")]
impl MockManager {
    fn get_devices(&self) -> Vec<OwnedObjectPath> {
        vec![OwnedObjectPath::try_from("/net/reactivated/Fprint/Device/0").unwrap()]
    }
}

struct MockDevice {
    status: Arc<Mutex<String>>,
    starts: Arc<AtomicUsize>,
    stops: Arc<AtomicUsize>,
    releases: Arc<AtomicUsize>,
}
#[zbus::interface(name = "net.reactivated.Fprint.Device")]
impl MockDevice {
    fn list_enrolled_fingers(&self, username: &str) -> Vec<String> {
        assert_eq!(username, "");
        vec!["right-index-finger".into()]
    }
    fn claim(&self, username: &str) {
        assert_eq!(username, "");
    }
    #[zbus(property, name = "finger-present")]
    fn finger_present(&self) -> bool {
        false
    }
    async fn verify_start(
        &self,
        finger: &str,
        #[zbus(signal_emitter)] emitter: zbus::object_server::SignalEmitter<'_>,
    ) -> zbus::fdo::Result<()> {
        assert_eq!(finger, "any");
        self.starts.fetch_add(1, Ordering::SeqCst);
        let status = lock_unpoisoned(&self.status).clone();
        if status == "start-error" {
            return Err(zbus::fdo::Error::Failed("test start failure".into()));
        }
        if status != "silent" {
            Self::verify_status(&emitter, &status, true).await?;
        }
        Ok(())
    }
    fn verify_stop(&self) {
        self.stops.fetch_add(1, Ordering::SeqCst);
    }
    fn release(&self) {
        self.releases.fetch_add(1, Ordering::SeqCst);
    }
    #[zbus(signal)]
    async fn verify_status(
        emitter: &zbus::object_server::SignalEmitter<'_>,
        status: &str,
        done: bool,
    ) -> zbus::Result<()>;
}

#[test]
fn private_bus_verification_and_cleanup() {
    // Run explicitly inside dbus-run-session; never reach a real sensor.
    if std::env::var_os("DENIAL_FPRINT_TEST_BUS").is_none() {
        return;
    }
    let status = Arc::new(Mutex::new("verify-match".into()));
    let starts = Arc::new(AtomicUsize::new(0));
    let stops = Arc::new(AtomicUsize::new(0));
    let releases = Arc::new(AtomicUsize::new(0));
    let server = Builder::session()
        .unwrap()
        .name(SERVICE)
        .unwrap()
        .serve_at(MANAGER, MockManager)
        .unwrap()
        .serve_at(
            "/net/reactivated/Fprint/Device/0",
            MockDevice {
                status: Arc::clone(&status),
                starts: Arc::clone(&starts),
                stops: Arc::clone(&stops),
                releases: Arc::clone(&releases),
            },
        )
        .unwrap()
        .build()
        .unwrap();
    for (index, (signal, expected)) in [
        ("verify-match", Some(Verification::Match)),
        ("verify-no-match", Some(Verification::NoMatch)),
        ("verify-unknown-error", Some(Verification::Unavailable)),
        ("silent", Some(Verification::Cancelled)),
        ("start-error", None),
    ]
    .into_iter()
    .enumerate()
    {
        *lock_unpoisoned(&status) = signal.into();
        let client = Builder::session()
            .unwrap()
            .method_timeout(CALL_TIMEOUT)
            .build()
            .unwrap();
        let start = Instant::now();
        let changed = Wakeup::new().unwrap();
        // A cancellation always comes with a wake, as SharedAuthentication::notify sends.
        let result = thread::scope(|scope| {
            if signal == "silent" {
                scope.spawn(|| {
                    thread::sleep(Duration::from_millis(250));
                    changed.wake();
                });
            }
            verify_connection(
                &client,
                &|| {},
                &|_| {},
                &|| signal == "silent" && start.elapsed() > Duration::from_millis(200),
                &changed,
            )
        });
        match expected {
            Some(expected) => {
                // A result leaves the reader claimed for the caller to
                // release after acting on it.
                let (verification, device) = result.unwrap();
                assert_eq!(verification, expected);
                assert_eq!(stops.load(Ordering::SeqCst), index);
                stop_and_release(&device.unwrap());
            }
            None => assert!(result.is_err()),
        }
        assert_eq!(stops.load(Ordering::SeqCst), index + 1);
        assert_eq!(releases.load(Ordering::SeqCst), index + 1);
        client.close().unwrap();
    }
    // The fprintd property is advisory: it must reach the UI callback,
    // while only the following VerifyStatus can complete authentication.
    *lock_unpoisoned(&status) = "silent".into();
    let client = Builder::session()
        .unwrap()
        .method_timeout(CALL_TIMEOUT)
        .build()
        .unwrap();
    let changed = Wakeup::new().unwrap();
    let seen = std::sync::atomic::AtomicBool::new(false);
    let before = starts.load(Ordering::SeqCst);
    let result = thread::scope(|scope| {
        scope.spawn(|| {
            let deadline = Instant::now() + Duration::from_secs(3);
            while starts.load(Ordering::SeqCst) == before {
                assert!(Instant::now() < deadline);
                thread::yield_now();
            }
            let mut values = std::collections::HashMap::new();
            values.insert("finger-present", zbus::zvariant::Value::from(true));
            server
                .emit_signal(
                    None::<&str>,
                    "/net/reactivated/Fprint/Device/0",
                    "org.freedesktop.DBus.Properties",
                    "PropertiesChanged",
                    &(DEVICE_INTERFACE, values, Vec::<&str>::new()),
                )
                .unwrap();
            while !seen.load(Ordering::SeqCst) && Instant::now() < deadline {
                thread::sleep(Duration::from_millis(5));
            }
            server
                .emit_signal(
                    None::<&str>,
                    "/net/reactivated/Fprint/Device/0",
                    DEVICE_INTERFACE,
                    "VerifyStatus",
                    &("verify-match", true),
                )
                .unwrap();
        });
        verify_connection(
            &client,
            &|| {},
            &|active| {
                seen.store(active, Ordering::SeqCst);
            },
            &|| false,
            &changed,
        )
    });
    let (verification, device) = result.unwrap();
    assert_eq!(verification, Verification::Match);
    stop_and_release(&device.unwrap());
    assert!(seen.load(Ordering::SeqCst));
    client.close().unwrap();

    *lock_unpoisoned(&status) = "silent".into();
    let (finished, result) = mpsc::channel();
    let worker = thread::spawn(move || {
        let client = Builder::session()
            .unwrap()
            .method_timeout(CALL_TIMEOUT)
            .build()
            .unwrap();
        let changed = Wakeup::new().unwrap();
        let result = verify_connection(&client, &|| {}, &|_| {}, &|| false, &changed)
            .map(|(verification, _)| verification);
        client.close().unwrap();
        finished.send(result).unwrap();
    });
    let deadline = Instant::now() + Duration::from_secs(2);
    while starts.load(Ordering::SeqCst) != 7 {
        assert!(Instant::now() < deadline);
        thread::yield_now();
    }
    // A different bus peer cannot forge fprintd's successful result.
    let attacker = Connection::session().unwrap();
    attacker
        .emit_signal(
            None::<&str>,
            "/net/reactivated/Fprint/Device/0",
            DEVICE_INTERFACE,
            "VerifyStatus",
            &("verify-match", true),
        )
        .unwrap();
    assert!(result.recv_timeout(Duration::from_millis(150)).is_err());
    attacker.close().unwrap();
    // Losing the pinned daemon must terminate a silent scan, not hang.
    server.close().unwrap();
    assert_eq!(
        result
            .recv_timeout(Duration::from_secs(2))
            .unwrap()
            .unwrap(),
        Verification::Unavailable
    );
    worker.join().unwrap();
}
