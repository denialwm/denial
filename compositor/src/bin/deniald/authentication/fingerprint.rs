//! Optional fprintd verification, independent of the password conversation.
//!
//! Each scan owns a private system-bus connection and is pinned to one daemon
//! owner and one lock epoch. Neither Flutter nor an unsolicited bus signal can
//! supply an authentication result. Dropping the connection also releases the
//! claim if a daemon disappears or a method times out during cleanup.

use super::*;
use futures_lite::{StreamExt, future};
use tracing::debug;
use zbus::blocking::{Connection, Proxy, connection::Builder};
use zbus::zvariant::OwnedObjectPath;

const SERVICE: &str = "net.reactivated.Fprint";
const MANAGER: &str = "/net/reactivated/Fprint/Manager";
const DEVICE_INTERFACE: &str = "net.reactivated.Fprint.Device";
const CALL_TIMEOUT: Duration = Duration::from_secs(3);
const CANCEL_INTERVAL: Duration = Duration::from_millis(100);
const MAX_UNAVAILABLE_RETRY: Duration = Duration::from_secs(30);
const WAKE_SETTLE_DELAY: Duration = Duration::from_millis(150);

#[derive(Clone, Copy)]
pub(super) enum PendingUnlock {
    Validated,
    Waking,
    Settling(Instant),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum Verification {
    Match,
    NoMatch,
    Cancelled,
    Unavailable,
}

pub(super) trait FingerprintBackend {
    /// Match includes successful PAM account validation, not just a scan.
    fn verify(&mut self, cancelled: &dyn Fn() -> bool) -> Verification;
}

pub(super) struct FprintBackend;

impl FingerprintBackend for FprintBackend {
    fn verify(&mut self, cancelled: &dyn Fn() -> bool) -> Verification {
        let result = (|| {
            let connection = Builder::system()?.method_timeout(CALL_TIMEOUT).build()?;
            let result = verify_connection(&connection, cancelled);
            // A separate connection per operation prevents old signals from
            // crossing a retry and ensures any abandoned claim is released.
            let _ = connection.close();
            result
        })();
        match result {
            Ok(Verification::Match) if !cancelled() => {
                match PamBackend::load().and_then(|backend| backend.validate_account()) {
                    Ok(()) if !cancelled() => Verification::Match,
                    result => {
                        debug!(?result, "fingerprint account validation did not complete");
                        Verification::Unavailable
                    }
                }
            }
            Ok(result) => result,
            Err(error) => {
                debug!(%error, "fingerprint verification is unavailable");
                Verification::Unavailable
            }
        }
    }
}

fn verify_connection(
    connection: &Connection,
    cancelled: &dyn Fn() -> bool,
) -> zbus::Result<Verification> {
    if cancelled() {
        return Ok(Verification::Cancelled);
    }
    let manager = Proxy::new(
        connection,
        SERVICE,
        MANAGER,
        "net.reactivated.Fprint.Manager",
    )?;
    // Activate fprintd before resolving its unique bus owner.
    let _: Vec<OwnedObjectPath> = manager.call("GetDevices", &())?;
    let bus = zbus::blocking::fdo::DBusProxy::new(connection)?;
    let owner = bus.get_name_owner(SERVICE.try_into()?)?;
    let manager = Proxy::new(
        connection,
        owner.clone(),
        MANAGER,
        "net.reactivated.Fprint.Manager",
    )?;
    let devices: Vec<OwnedObjectPath> = manager.call("GetDevices", &())?;
    for path in devices {
        if cancelled() {
            return Ok(Verification::Cancelled);
        }
        let device = Proxy::new(connection, owner.clone(), path, DEVICE_INTERFACE)?;
        // An empty username selects the authenticated bus caller, never an
        // environment variable or a username supplied by the shell.
        let fingers: Vec<String> = match device.call("ListEnrolledFingers", &("",)) {
            Ok(fingers) => fingers,
            Err(error) => {
                debug!(%error, "could not query fingerprint enrollment");
                continue;
            }
        };
        if fingers.is_empty() {
            continue;
        }
        device.call::<_, _, ()>("Claim", &("",))?;
        let result = verify_claimed_device(&device, cancelled);
        // Always stop/release, including cancellation, no-match, malformed
        // signals and VerifyStart failure. Connection close is the fallback.
        let _ = device.call::<_, _, ()>("VerifyStop", &());
        let _ = device.call::<_, _, ()>("Release", &());
        return result;
    }
    Ok(Verification::Unavailable)
}

fn verify_claimed_device(
    device: &Proxy<'_>,
    cancelled: &dyn Fn() -> bool,
) -> zbus::Result<Verification> {
    // Subscribe before starting, to retain even an immediate match. The proxy
    // filters sender, object path, interface and member against the pinned owner.
    let mut statuses = future::block_on(device.inner().receive_signal("VerifyStatus"))?;
    let mut owner_changes = future::block_on(device.inner().receive_owner_changed())?;
    if cancelled() {
        return Ok(Verification::Cancelled);
    }
    device.call::<_, _, ()>("VerifyStart", &("any",))?;
    info!("Denial fingerprint reader is ready");
    loop {
        if cancelled() {
            return Ok(Verification::Cancelled);
        }
        let status = future::block_on(future::race(
            future::race(async { Some(statuses.next().await) }, async {
                owner_changes.next().await;
                Some(None)
            }),
            async {
                async_io::Timer::after(CANCEL_INTERVAL).await;
                None
            },
        ));
        match status {
            Some(Some(message)) => {
                let (status, done): (String, bool) = message.body().deserialize()?;
                if let Some(result) = classify_status(&status, done) {
                    return Ok(result);
                }
            }
            Some(None) => return Ok(Verification::Unavailable),
            None => {}
        }
    }
}

fn classify_status(status: &str, done: bool) -> Option<Verification> {
    match (status, done) {
        ("verify-match", true) => Some(Verification::Match),
        ("verify-no-match", true) => Some(Verification::NoMatch),
        (
            "verify-retry-scan"
            | "verify-swipe-too-short"
            | "verify-finger-not-centered"
            | "verify-remove-and-retry"
            | "verify-too-fast",
            false,
        ) => None,
        // Unknown statuses and inconsistent completion flags fail closed.
        _ => Some(Verification::Unavailable),
    }
}

fn cancelled(shared: &SharedAuthentication, epoch: u64) -> bool {
    let state = lock_unpoisoned(&shared.state);
    state.stopping || state.lock_epoch != epoch || !shared.locked.load(Ordering::Acquire)
}

pub(super) fn run_worker(
    shared: &Arc<SharedAuthentication>,
    backend: &mut impl FingerprintBackend,
) {
    let mut previous_epoch = None;
    let mut failures = 0u32;
    let mut unavailable_attempts = 0u32;
    loop {
        let epoch = {
            let mut state = lock_unpoisoned(&shared.state);
            while !state.stopping
                && (!shared.locked.load(Ordering::Acquire) || state.fingerprint_unlock.is_some())
            {
                state = shared
                    .condition
                    .wait(state)
                    .unwrap_or_else(|error| error.into_inner());
            }
            if state.stopping {
                return;
            }
            state.lock_epoch
        };
        if previous_epoch != Some(epoch) {
            failures = 0;
            unavailable_attempts = 0;
            previous_epoch = Some(epoch);
        }
        let result = backend.verify(&|| cancelled(shared, epoch));
        if result == Verification::Match && complete_match(shared, epoch) {
            info!("Denial fingerprint validated; waiting for display readiness");
            continue;
        }
        if cancelled(shared, epoch) {
            continue;
        }
        let delay = if result == Verification::NoMatch {
            unavailable_attempts = 0;
            publish_no_match(shared, epoch);
            failures = failures.saturating_add(1);
            fingerprint_retry(failures)
        } else {
            unavailable_attempts = unavailable_attempts.saturating_add(1);
            unavailable_retry(unavailable_attempts)
        };
        // Password actions do not reset fingerprint backoff; a new lock does.
        let state = lock_unpoisoned(&shared.state);
        let _ = shared
            .condition
            .wait_timeout_while(state, delay, |state| {
                !state.stopping
                    && state.lock_epoch == epoch
                    && shared.locked.load(Ordering::Acquire)
            })
            .unwrap_or_else(|error| error.into_inner());
    }
}

fn fingerprint_retry(failures: u32) -> Duration {
    if failures <= 4 {
        Duration::from_millis(150)
    } else {
        cooldown_for(failures - 4)
    }
}

fn unavailable_retry(attempts: u32) -> Duration {
    // The first attempt can precede logind/PolicyKit session activation.
    // Recover promptly from startup races without continuously polling hosts
    // that have no usable reader. This is independent of rejected-scan backoff.
    Duration::from_secs(1u64 << attempts.saturating_sub(1).min(5)).min(MAX_UNAVAILABLE_RETRY)
}

fn publish_no_match(shared: &SharedAuthentication, epoch: u64) {
    let state = lock_unpoisoned(&shared.state);
    if state.stopping || state.lock_epoch != epoch || !shared.locked.load(Ordering::Acquire) {
        return;
    }
    // Queue the haptic at the trusted, epoch-checked result boundary. This
    // also works while the screen is off and never waits for D-Bus here.
    if let Some(haptics) = shared.haptics.get() {
        haptics.fingerprint_rejected();
    }
    // Advisory feedback must not end or replace a concurrent PAM conversation.
    shared.push_event(AuthenticationEvent {
        kind: AuthenticationEventKind::FingerprintFeedback,
        state: snapshot_locked(shared, &state, Instant::now()),
        message: "no-match".into(),
    });
}

fn complete_match(shared: &SharedAuthentication, epoch: u64) -> bool {
    let mut state = lock_unpoisoned(&shared.state);
    if state.stopping || state.lock_epoch != epoch || !shared.locked.load(Ordering::Acquire) {
        return false;
    }
    // Cancel any password prompt and invalidate its eventual result before
    // publishing success. The compositor still owns the input security gate.
    state.generation = state.generation.wrapping_add(1);
    state.lock_epoch = state.lock_epoch.wrapping_add(1);
    state.cancel_requested = state.busy;
    state.prompt = None;
    state.response = None;
    state.failure_count = 0;
    state.cooldown_until = None;
    state.fingerprint_unlock = Some(PendingUnlock::Validated);
    shared.condition.notify_all();
    true
}

pub(super) fn advance_pending_unlock(
    shared: &SharedAuthentication,
    now: Instant,
    outputs_ready: bool,
) -> bool {
    let mut state = lock_unpoisoned(&shared.state);
    if state.stopping || !shared.locked.load(Ordering::Acquire) {
        state.fingerprint_unlock = None;
        return false;
    }
    let Some(pending) = state.fingerprint_unlock else {
        return false;
    };
    if !outputs_ready {
        state.fingerprint_unlock = Some(PendingUnlock::Waking);
        return true;
    }
    match pending {
        PendingUnlock::Waking => {
            // Start the delay only after the wake frame reaches the display,
            // not when a DPMS request is merely queued.
            state.fingerprint_unlock = Some(PendingUnlock::Settling(now + WAKE_SETTLE_DELAY));
            return false;
        }
        PendingUnlock::Settling(deadline) if now < deadline => return false,
        PendingUnlock::Validated | PendingUnlock::Settling(_) => {}
    }
    state.fingerprint_unlock = None;
    shared.locked.store(false, Ordering::Release);
    shared.push_event(AuthenticationEvent {
        kind: AuthenticationEventKind::Result {
            success: true,
            cancelled: false,
        },
        state: snapshot_locked(shared, &state, Instant::now()),
        message: "Fingerprint recognized".into(),
    });
    shared.condition.notify_all();
    info!("Denial unlocked through fingerprint authentication");
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;
    use std::sync::mpsc;

    fn controller(locked: bool) -> AuthenticationController {
        AuthenticationController::with_backend(
            Box::new(UnavailableBackend {
                reason: "test".into(),
            }),
            locked,
        )
        .unwrap()
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
    fn screen_off_match_waits_for_wake_frame_then_settles_before_unlock() {
        let controller = controller(true);
        let now = Instant::now();
        // No match means no wake, even with the screen off.
        assert!(!controller.advance_fingerprint_unlock(now, false));
        assert!(complete_match(&controller.shared, 0));
        assert!(controller.advance_fingerprint_unlock(now, false));
        assert!(controller.locked());
        assert!(controller.security_gate_locked());
        assert!(controller.try_event().is_none());
        let presented = now + Duration::from_secs(1);
        assert!(controller.advance_fingerprint_unlock(presented, false));
        assert!(!controller.advance_fingerprint_unlock(presented, true));
        controller.advance_fingerprint_unlock(presented + WAKE_SETTLE_DELAY / 2, true);
        assert!(controller.locked());
        assert!(controller.try_event().is_none());
        controller.advance_fingerprint_unlock(presented + WAKE_SETTLE_DELAY, true);
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
        controller.advance_fingerprint_unlock(now, true);
        controller.lock();
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
        fn verify(&mut self, cancelled: &dyn Fn() -> bool) -> Verification {
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
    fn unavailable_backoff_is_bounded_and_independent_of_rejected_scans() {
        assert_eq!(unavailable_retry(1), Duration::from_secs(1));
        assert_eq!(unavailable_retry(2), Duration::from_secs(2));
        assert_eq!(unavailable_retry(3), Duration::from_secs(4));
        assert_eq!(unavailable_retry(6), MAX_UNAVAILABLE_RETRY);
        assert_eq!(unavailable_retry(u32::MAX), MAX_UNAVAILABLE_RETRY);
        assert_eq!(fingerprint_retry(1), Duration::from_millis(150));
        assert_eq!(fingerprint_retry(4), Duration::from_millis(150));
        assert_eq!(fingerprint_retry(5), Duration::from_millis(750));
        assert_eq!(fingerprint_retry(u32::MAX), Duration::from_secs(30));
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
            AuthenticationController::with_backend(Box::new(PasswordBackend), true).unwrap();
        controller.begin();
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
            let result = verify_connection(&client, &|| {
                signal == "silent" && start.elapsed() > Duration::from_millis(200)
            });
            match expected {
                Some(expected) => assert_eq!(result.unwrap(), expected),
                None => assert!(result.is_err()),
            }
            assert_eq!(stops.load(Ordering::SeqCst), index + 1);
            assert_eq!(releases.load(Ordering::SeqCst), index + 1);
            client.close().unwrap();
        }
        *lock_unpoisoned(&status) = "silent".into();
        let (finished, result) = mpsc::channel();
        let worker = thread::spawn(move || {
            let client = Builder::session()
                .unwrap()
                .method_timeout(CALL_TIMEOUT)
                .build()
                .unwrap();
            let result = verify_connection(&client, &|| false);
            client.close().unwrap();
            finished.send(result).unwrap();
        });
        let deadline = Instant::now() + Duration::from_secs(2);
        while starts.load(Ordering::SeqCst) != 6 {
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
}
