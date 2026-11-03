//! Optional fprintd verification, independent of the password conversation.
//!
//! Each scan owns a private system-bus connection and is pinned to one daemon
//! owner and one lock epoch. Neither Flutter nor an unsolicited bus signal can
//! supply an authentication result. Dropping the connection also releases the
//! claim if a daemon disappears or a method times out during cleanup.

use super::*;
use crate::wakeup::Wakeup;
use futures_lite::{StreamExt, future};
use std::cell::Cell;
use tracing::debug;
use zbus::blocking::{Connection, Proxy, connection::Builder};
use zbus::zvariant::OwnedObjectPath;

const SERVICE: &str = "net.reactivated.Fprint";
const MANAGER: &str = "/net/reactivated/Fprint/Manager";
const DEVICE_INTERFACE: &str = "net.reactivated.Fprint.Device";
const CALL_TIMEOUT: Duration = Duration::from_secs(3);
const MAX_UNAVAILABLE_RETRY: Duration = Duration::from_secs(30);
const WAKE_SETTLE_DELAY: Duration = Duration::ZERO;
/// A reader that listened this long before failing worked; it was the scan.
const HEALTHY_ARMED: Duration = Duration::from_millis(500);

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
    /// `armed` runs once the reader is listening for a finger. `changed`
    /// wakes whenever the inputs of `cancelled` may have changed.
    fn verify(
        &mut self,
        armed: &dyn Fn(),
        scanning: &dyn Fn(bool),
        cancelled: &dyn Fn() -> bool,
        changed: &Wakeup,
    ) -> Verification;
}

#[derive(Default)]
pub(super) struct FprintBackend {
    /// The reader a verification left claimed, stopped and released off the
    /// result path: fprintd answers VerifyStop only once its driver has
    /// cleaned up.
    releasing: Option<JoinHandle<()>>,
}

impl FingerprintBackend for FprintBackend {
    fn verify(
        &mut self,
        armed: &dyn Fn(),
        scanning: &dyn Fn(bool),
        cancelled: &dyn Fn() -> bool,
        changed: &Wakeup,
    ) -> Verification {
        // The next scan claims the reader only once the last one let it go.
        if let Some(releasing) = self.releasing.take() {
            let _ = releasing.join();
        }
        let result = (|| {
            let connection = Builder::system()?.method_timeout(CALL_TIMEOUT).build()?;
            let result = verify_connection(&connection, armed, scanning, cancelled, changed);
            // A separate connection per operation prevents old signals from
            // crossing a retry and ensures any abandoned claim is released.
            match result {
                Ok((verification, Some(device))) => {
                    let releasing = thread::Builder::new()
                        .name("fingerprint-release".into())
                        .spawn(move || {
                            stop_and_release(&device);
                            let _ = connection.close();
                        });
                    self.releasing = releasing.ok();
                    Ok(verification)
                }
                result => {
                    let _ = connection.close();
                    result.map(|(verification, _)| verification)
                }
            }
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

/// The verification, and the reader still claimed when it was reached: the
/// unlock or the rejection goes first and the reader is let go after it.
fn verify_connection(
    connection: &Connection,
    armed: &dyn Fn(),
    scanning: &dyn Fn(bool),
    cancelled: &dyn Fn() -> bool,
    changed: &Wakeup,
) -> zbus::Result<(Verification, Option<Proxy<'static>>)> {
    if cancelled() {
        return Ok((Verification::Cancelled, None));
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
            return Ok((Verification::Cancelled, None));
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
        // Always stop/release, including cancellation, no-match, malformed
        // signals and VerifyStart failure. Connection close is the fallback.
        return match verify_claimed_device(&device, armed, scanning, cancelled, changed) {
            Ok(verification) => Ok((verification, Some(device))),
            Err(error) => {
                stop_and_release(&device);
                Err(error)
            }
        };
    }
    Ok((Verification::Unavailable, None))
}

fn stop_and_release(device: &Proxy<'_>) {
    let _ = device.call::<_, _, ()>("VerifyStop", &());
    let _ = device.call::<_, _, ()>("Release", &());
}

fn verify_claimed_device(
    device: &Proxy<'_>,
    armed: &dyn Fn(),
    scanning: &dyn Fn(bool),
    cancelled: &dyn Fn() -> bool,
    changed: &Wakeup,
) -> zbus::Result<Verification> {
    // Subscribe before starting, to retain even an immediate match. The proxy
    // filters sender, object path, interface and member against the pinned owner.
    let mut statuses = future::block_on(device.inner().receive_signal("VerifyStatus"))?;
    // Proxy properties are cached lazily; the stream is inert until the
    // first read initializes the cache. Older daemons may lack this property.
    let _ = device.get_property::<bool>("finger-present");
    let mut fingers = future::block_on(
        device
            .inner()
            .receive_property_changed::<bool>("finger-present"),
    );
    let mut owner_changes = future::block_on(device.inner().receive_owner_changed())?;
    if cancelled() {
        return Ok(Verification::Cancelled);
    }
    device.call::<_, _, ()>("VerifyStart", &("any",))?;
    info!("Denial fingerprint reader is ready");
    armed();
    loop {
        if cancelled() {
            return Ok(Verification::Cancelled);
        }
        enum ScanEvent {
            Status(Option<zbus::Message>),
            Owner,
            Finger(Option<bool>),
            Changed,
        }
        let event = future::block_on(future::race(
            future::race(async { ScanEvent::Status(statuses.next().await) }, async {
                owner_changes.next().await;
                ScanEvent::Owner
            }),
            future::race(
                async {
                    let value = match fingers.next().await {
                        Some(change) => change.get().await.ok(),
                        None => None,
                    };
                    ScanEvent::Finger(value)
                },
                async {
                    changed.wait().await;
                    ScanEvent::Changed
                },
            ),
        ));
        match event {
            ScanEvent::Status(Some(message)) => {
                let (status, done): (String, bool) = message.body().deserialize()?;
                if let Some(result) = classify_status(&status, done) {
                    return Ok(result);
                }
            }
            ScanEvent::Status(None) | ScanEvent::Owner | ScanEvent::Finger(None) => {
                return Ok(Verification::Unavailable);
            }
            ScanEvent::Finger(Some(present)) => scanning(present),
            ScanEvent::Changed => {}
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
    state.stopping
        || state.lock_epoch != epoch
        || !state.fingerprint_offered
        || !state.fingerprint_allowed()
        || !shared.locked.load(Ordering::Acquire)
}

pub(super) fn run_worker(
    shared: &Arc<SharedAuthentication>,
    backend: &mut impl FingerprintBackend,
) {
    let mut previous_epoch = None;
    let mut unavailable_attempts = 0u32;
    lock_unpoisoned(&shared.state).fingerprint_sensor = sensor_rect();
    loop {
        let epoch = {
            let mut state = lock_unpoisoned(&shared.state);
            while !state.stopping
                && (!shared.locked.load(Ordering::Acquire)
                    || state.fingerprint_unlock.is_some()
                    || !state.fingerprint_offered
                    || !state.fingerprint_allowed())
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
            unavailable_attempts = 0;
            previous_epoch = Some(epoch);
        }
        let armed_at = Cell::new(None);
        let touch_at = Cell::new(None::<Instant>);
        let result = backend.verify(
            &|| {
                armed_at.set(Some(Instant::now()));
                publish_readiness(shared, true);
            },
            &|active| {
                if active && !cancelled(shared, epoch) {
                    touch_at.set(Some(Instant::now()));
                }
                publish_scanning(shared, active && !cancelled(shared, epoch));
            },
            &|| cancelled(shared, epoch),
            &shared.fingerprint_changed,
        );
        if let Some(touch) = touch_at.get() {
            info!(
                elapsed_ms = touch.elapsed().as_millis() as u64,
                ?result,
                "fingerprint touch through account validation"
            );
        }
        publish_scanning(shared, false);
        // Between scans the reader is not listening; the lock screen shows
        // that until the next attempt arms it.
        publish_readiness(shared, false);
        if result == Verification::Match && complete_match(shared, epoch) {
            info!("Denial fingerprint validated; waiting for display readiness");
            continue;
        }
        if cancelled(shared, epoch) {
            continue;
        }
        // A rejected scan, or a reader that listened before it failed (a
        // finger lifted too early), arms again at once: the user retries
        // without a cooldown. Only a reader that fails before listening backs
        // off, so a host without a usable one is not polled continuously.
        let delay = match result {
            Verification::NoMatch => {
                publish_no_match(shared, epoch);
                unavailable_attempts = 0;
                continue;
            }
            _ if armed_at
                .get()
                .is_some_and(|armed| armed.elapsed() >= HEALTHY_ARMED) =>
            {
                unavailable_attempts = 0;
                continue;
            }
            _ => {
                unavailable_attempts = unavailable_attempts.saturating_add(1);
                unavailable_retry(unavailable_attempts)
            }
        };
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

/// The lock screen marks the sensor once a reader with enrolled prints has
/// armed, and shows whether it is listening right now.
fn publish_readiness(shared: &SharedAuthentication, ready: bool) {
    let mut state = lock_unpoisoned(&shared.state);
    if state.fingerprint_ready != ready || (ready && !state.fingerprint_known) {
        state.fingerprint_ready = ready;
        state.fingerprint_known |= ready;
        shared.push_event(credential_event(shared, &state));
    }
}

/// Contact feedback is advisory; it never grants authentication.
fn publish_scanning(shared: &SharedAuthentication, scanning: bool) {
    let mut state = lock_unpoisoned(&shared.state);
    if state.fingerprint_scanning != scanning {
        state.fingerprint_scanning = scanning;
        shared.push_event(credential_event(shared, &state));
    }
}

/// The under-display sensor as fractions of its panel, from the profile the
/// fingerprint presentation also reads. Hosts without one get no location.
fn sensor_rect() -> Option<[f64; 4]> {
    #[derive(serde::Deserialize)]
    struct Profile {
        panel_width: u32,
        panel_height: u32,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
    }
    let text = std::fs::read_to_string("/etc/denial/fingerprint.json").ok()?;
    let profile: Profile = serde_json::from_str(&text).ok()?;
    let (panel_width, panel_height) = (
        f64::from(profile.panel_width),
        f64::from(profile.panel_height),
    );
    (profile.width > 0
        && profile.height > 0
        && profile
            .x
            .checked_add(profile.width)
            .is_some_and(|right| right <= profile.panel_width)
        && profile
            .y
            .checked_add(profile.height)
            .is_some_and(|bottom| bottom <= profile.panel_height))
    .then(|| {
        [
            f64::from(profile.x) / panel_width,
            f64::from(profile.y) / panel_height,
            f64::from(profile.width) / panel_width,
            f64::from(profile.height) / panel_height,
        ]
    })
}

fn unavailable_retry(attempts: u32) -> Duration {
    // The first attempt can precede logind/PolicyKit session activation.
    // Recover promptly from startup races without continuously polling hosts
    // that have no usable reader.
    if attempts <= 1 {
        return Duration::ZERO;
    }
    Duration::from_secs(1u64 << attempts.saturating_sub(2).min(5)).min(MAX_UNAVAILABLE_RETRY)
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
    shared
        .fingerprint_unlock_pending
        .store(true, Ordering::Release);
    shared.notify();
    crate::loop_wake::wake();
    true
}

pub(super) fn advance_pending_unlock(
    shared: &SharedAuthentication,
    now: Instant,
    outputs_ready: bool,
) -> bool {
    if !shared.fingerprint_unlock_pending.load(Ordering::Acquire) {
        return false;
    }
    let mut state = lock_unpoisoned(&shared.state);
    if state.stopping || !shared.locked.load(Ordering::Acquire) {
        state.fingerprint_unlock = None;
        shared
            .fingerprint_unlock_pending
            .store(false, Ordering::Release);
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
        PendingUnlock::Waking if !WAKE_SETTLE_DELAY.is_zero() => {
            // Start the delay only after the wake frame reaches the display,
            // not when a DPMS request is merely queued.
            state.fingerprint_unlock = Some(PendingUnlock::Settling(now + WAKE_SETTLE_DELAY));
            return false;
        }
        PendingUnlock::Settling(deadline) if now < deadline => return false,
        PendingUnlock::Validated | PendingUnlock::Waking | PendingUnlock::Settling(_) => {}
    }
    state.fingerprint_unlock = None;
    shared
        .fingerprint_unlock_pending
        .store(false, Ordering::Release);
    shared.locked.store(false, Ordering::Release);
    shared.push_event(AuthenticationEvent {
        kind: AuthenticationEventKind::Result {
            success: true,
            cancelled: false,
        },
        state: snapshot_locked(shared, &state, Instant::now()),
        message: "Fingerprint recognized".into(),
    });
    shared.notify();
    info!("Denial unlocked through fingerprint authentication");
    false
}

#[cfg(test)]
#[path = "fingerprint/tests.rs"]
mod tests;
