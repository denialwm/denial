use super::*;
use std::sync::atomic::{AtomicUsize, Ordering};

struct FakeBackend {
    result: BackendResult,
    calls: Arc<AtomicUsize>,
}

impl AuthenticationBackend for FakeBackend {
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
        _username: &str,
        conversation: &mut dyn FnMut(PromptStyle, &str) -> Option<SecureString>,
        cancelled: &dyn Fn() -> bool,
    ) -> BackendResult {
        self.calls.fetch_add(1, Ordering::Relaxed);
        let Some(mut response) = conversation(PromptStyle::EchoOff, "Password:") else {
            return BackendResult::Cancelled;
        };
        let matches = response.as_bytes() == b"correct horse";
        response.clear();
        if cancelled() {
            BackendResult::Cancelled
        } else if self.result == BackendResult::Success && matches {
            BackendResult::Success
        } else {
            self.result
        }
    }
}

fn packet(kind: u8, attempt_id: u64, argument: u32, payload: &[u8]) -> Vec<u8> {
    let mut packet = vec![0u8; HEADER_SIZE + payload.len()];
    packet[..4].copy_from_slice(MAGIC);
    packet[4..6].copy_from_slice(&VERSION.to_le_bytes());
    packet[6] = kind;
    packet[8..16].copy_from_slice(&attempt_id.to_le_bytes());
    packet[16..20].copy_from_slice(&argument.to_le_bytes());
    packet[20..24].copy_from_slice(&(payload.len() as u32).to_le_bytes());
    packet[HEADER_SIZE..].copy_from_slice(payload);
    packet
}

fn wait_for_event(
    controller: &AuthenticationController,
    predicate: impl Fn(&AuthenticationEvent) -> bool,
) -> AuthenticationEvent {
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        if let Some(event) = controller.try_event()
            && predicate(&event)
        {
            return event;
        }
        assert!(Instant::now() < deadline, "authentication event timed out");
        thread::yield_now();
    }
}

#[test]
fn protocol_rejects_malformed_metadata_and_moves_credentials() {
    let response_packet = packet(KIND_RESPOND, 7, 3, b"secret");
    let AuthenticationCommand::Respond {
        attempt_id,
        prompt_sequence,
        response,
    } = decode(&response_packet).unwrap()
    else {
        panic!("expected response command");
    };
    assert_eq!(attempt_id, 7);
    assert_eq!(prompt_sequence, 3);
    assert_eq!(response.as_bytes(), b"secret");
    assert_eq!(
        decode(&response_packet[..response_packet.len() - 1])
            .err()
            .unwrap(),
        AuthenticationDecodeError::InvalidPayloadLength(6)
    );
    assert_eq!(
        decode(&packet(KIND_LOCK, 1, 0, b"")).err().unwrap(),
        AuthenticationDecodeError::UnexpectedMetadata
    );
    assert_eq!(
        decode(&packet(KIND_RESPOND, 1, 1, b"a\0b")).err().unwrap(),
        AuthenticationDecodeError::EmbeddedNul
    );
}

#[test]
fn initial_lock_closes_the_security_gate_before_flutter_synchronizes() {
    let controller = AuthenticationController::with_backend(
        Box::new(FakeBackend {
            result: BackendResult::Success,
            calls: Arc::new(AtomicUsize::new(0)),
        }),
        None,
        true,
    )
    .unwrap();

    assert!(controller.locked());
    assert!(controller.security_gate_locked());

    controller.synchronize();
    let state = controller
        .try_event()
        .expect("initial authentication state");
    assert!(matches!(state.kind, AuthenticationEventKind::State));
    assert!(state.state.locked);
}

#[test]
fn successful_current_conversation_unlocks_exactly_once() {
    let calls = Arc::new(AtomicUsize::new(0));
    let controller = AuthenticationController::with_backend(
        Box::new(FakeBackend {
            result: BackendResult::Success,
            calls: Arc::clone(&calls),
        }),
        None,
        false,
    )
    .unwrap();
    controller.lock();
    controller.begin(false);
    let prompt = wait_for_event(&controller, |event| {
        matches!(event.kind, AuthenticationEventKind::Prompt { .. })
    });
    let AuthenticationEventKind::Prompt { sequence, .. } = prompt.kind else {
        unreachable!();
    };
    assert!(controller.respond(
        prompt.state.attempt_id,
        sequence,
        SecureString::new(b"correct horse")
    ));
    let result = wait_for_event(&controller, |event| {
        matches!(
            event.kind,
            AuthenticationEventKind::Result { success: true, .. }
        )
    });
    assert!(!result.state.locked);
    assert!(!controller.locked());
    assert!(controller.security_gate_locked());
    controller.acknowledge_unlocked_boundary();
    assert!(!controller.security_gate_locked());
    assert_eq!(calls.load(Ordering::Relaxed), 1);
    assert!(!controller.respond(
        prompt.state.attempt_id,
        sequence,
        SecureString::new(b"duplicate")
    ));
}

#[test]
fn failure_stays_locked_and_immediate_retry_is_rate_limited() {
    let calls = Arc::new(AtomicUsize::new(0));
    let controller = AuthenticationController::with_backend(
        Box::new(FakeBackend {
            result: BackendResult::Failure,
            calls: Arc::clone(&calls),
        }),
        None,
        false,
    )
    .unwrap();
    controller.lock();
    controller.begin(false);
    let prompt = wait_for_event(&controller, |event| {
        matches!(event.kind, AuthenticationEventKind::Prompt { .. })
    });
    let AuthenticationEventKind::Prompt { sequence, .. } = prompt.kind else {
        unreachable!();
    };
    assert!(controller.respond(
        prompt.state.attempt_id,
        sequence,
        SecureString::new(b"wrong")
    ));
    let result = wait_for_event(&controller, |event| {
        matches!(
            event.kind,
            AuthenticationEventKind::Result {
                success: false,
                cancelled: false
            }
        )
    });
    assert!(result.state.locked);
    assert!(result.state.cooldown_ms > 0);
    controller.begin(false);
    assert_eq!(calls.load(Ordering::Relaxed), 1);
}

#[test]
fn cancellation_invalidates_late_success() {
    let calls = Arc::new(AtomicUsize::new(0));
    let controller = AuthenticationController::with_backend(
        Box::new(FakeBackend {
            result: BackendResult::Success,
            calls,
        }),
        None,
        false,
    )
    .unwrap();
    controller.lock();
    controller.begin(false);
    let prompt = wait_for_event(&controller, |event| {
        matches!(event.kind, AuthenticationEventKind::Prompt { .. })
    });
    controller.cancel(prompt.state.attempt_id);
    let result = wait_for_event(&controller, |event| {
        matches!(
            event.kind,
            AuthenticationEventKind::Result {
                cancelled: true,
                ..
            }
        )
    });
    assert!(result.state.locked);
    assert!(controller.locked());
    assert!(controller.security_gate_locked());
}

#[test]
fn account_without_credentials_locks_and_unlocks_with_a_swipe() {
    let calls = Arc::new(AtomicUsize::new(0));
    let controller = AuthenticationController::with_backend(
        Box::new(FakeBackend {
            result: BackendResult::Success,
            calls: Arc::clone(&calls),
        }),
        None,
        false,
    )
    .unwrap();
    lock_unpoisoned(&controller.shared.state).account_credential =
        lock_capability::Capability::Unavailable;
    assert!(controller.lock_automatically());
    assert!(controller.security_gate_locked());
    controller.begin(false);
    let result = wait_for_event(&controller, |event| {
        matches!(event.kind, AuthenticationEventKind::Result { .. })
    });
    assert!(matches!(
        result.kind,
        AuthenticationEventKind::Result { success: true, .. }
    ));
    assert!(!controller.locked());
    assert_eq!(calls.load(Ordering::Relaxed), 0);
}

#[test]
fn swipe_unlock_needs_an_established_absence_of_credentials() {
    for capability in [
        lock_capability::Capability::Pending,
        lock_capability::Capability::Unknown,
        lock_capability::Capability::Available,
    ] {
        let controller = AuthenticationController::with_backend(
            Box::new(FakeBackend {
                result: BackendResult::Success,
                calls: Arc::new(AtomicUsize::new(0)),
            }),
            None,
            false,
        )
        .unwrap();
        lock_unpoisoned(&controller.shared.state).account_credential = capability;
        assert!(controller.lock_automatically());
        controller.begin(false);
        wait_for_event(&controller, |event| {
            matches!(event.kind, AuthenticationEventKind::Prompt { .. })
        });
        assert!(controller.locked());
    }
}

#[test]
fn swipe_unlock_never_bypasses_a_pin_record() {
    for readable in [true, false] {
        let store = temporary_pin_store("swipe");
        write_quick_record(&store, "1234");
        if !readable {
            std::fs::write(store.path(), b"not a record").unwrap();
        }
        let path = store.path().to_owned();
        let controller = AuthenticationController::with_backend(
            Box::new(FakeBackend {
                result: BackendResult::Success,
                calls: Arc::new(AtomicUsize::new(0)),
            }),
            Some(store),
            false,
        )
        .unwrap();
        lock_unpoisoned(&controller.shared.state).account_credential =
            lock_capability::Capability::Unavailable;
        controller.lock();
        controller.begin(false);
        wait_for_event(&controller, |event| {
            matches!(event.kind, AuthenticationEventKind::Prompt { .. })
        });
        assert!(controller.locked());
        remove_pin_store(&pin::PinStore::at(path));
    }
}

#[test]
fn automatic_lock_requires_native_authentication() {
    let controller = AuthenticationController::with_backend(
        Box::new(UnavailableBackend {
            reason: "no PAM".into(),
        }),
        None,
        false,
    )
    .unwrap();
    lock_unpoisoned(&controller.shared.state).account_credential =
        lock_capability::Capability::Available;
    assert!(!controller.lock_automatically());
    assert!(!controller.locked());
    let controller = AuthenticationController::with_backend(
        Box::new(FakeBackend {
            result: BackendResult::Success,
            calls: Arc::new(AtomicUsize::new(0)),
        }),
        None,
        false,
    )
    .unwrap();
    assert!(controller.lock_automatically());
    assert!(controller.security_gate_locked());
}

pub(super) fn temporary_pin_store(name: &str) -> pin::PinStore {
    let directory = std::env::temp_dir().join(format!(
        "deniald-pin-{name}-{}-{:?}",
        std::process::id(),
        Instant::now()
    ));
    pin::PinStore::at(directory.join("denial/lock-pin"))
}

/// A record hashed with minimal Argon2 cost, so debug-build attempts finish
/// well inside `wait_for_event`'s deadline. Verification reads the cost from
/// the record, exactly as it does for records Settings writes.
pub(super) fn write_quick_record(store: &pin::PinStore, pin: &str) {
    use argon2::password_hash::{PasswordHasher, SaltString};
    let params = argon2::Params::new(8, 1, 1, None).unwrap();
    let hash = argon2::Argon2::new(argon2::Algorithm::Argon2id, argon2::Version::V0x13, params)
        .hash_password(
            pin.as_bytes(),
            &SaltString::encode_b64(b"denial-test-salt").unwrap(),
        )
        .unwrap()
        .to_string();
    std::fs::create_dir_all(store.path().parent().unwrap()).unwrap();
    std::fs::write(
        store.path(),
        serde_json::json!({"version": 1, "length": pin.len(), "hash": hash}).to_string(),
    )
    .unwrap();
}

fn remove_pin_store(store: &pin::PinStore) {
    let _ = std::fs::remove_dir_all(store.path().parent().unwrap().parent().unwrap());
}

#[test]
fn begin_selects_the_password_only_on_request() {
    assert!(matches!(
        decode(&packet(KIND_BEGIN, 0, 0, b"")).unwrap(),
        AuthenticationCommand::Begin {
            password_only: false
        }
    ));
    assert!(matches!(
        decode(&packet(KIND_BEGIN, 0, BEGIN_PASSWORD, b"")).unwrap(),
        AuthenticationCommand::Begin {
            password_only: true
        }
    ));
    assert_eq!(
        decode(&packet(KIND_BEGIN, 0, 2, b"")).err().unwrap(),
        AuthenticationDecodeError::UnexpectedMetadata
    );
}

#[test]
fn pin_store_round_trips_private_records_and_rejects_bad_pins() {
    use std::os::unix::fs::PermissionsExt;
    let store = temporary_pin_store("store");
    assert!(store.load().unwrap().is_none());
    for invalid in [&b"123"[..], b"12a4", b"1234567890123", b""] {
        assert!(!pin::valid_pin(invalid));
        assert!(store.save(invalid).is_err());
    }
    // A PIN set before may have 4 to 12 digits; a new one has six.
    assert!(pin::valid_pin(b"1234") && store.save(b"1234").is_err());
    assert_eq!(store.save(b"482916").unwrap(), 6);
    let mode = std::fs::metadata(store.path())
        .unwrap()
        .permissions()
        .mode();
    assert_eq!(mode & 0o777, 0o600);
    let record = store.load().unwrap().expect("saved record");
    assert_eq!(record.length(), 6);
    assert!(record.verify(b"482916"));
    assert!(!record.verify(b"482917"));
    assert!(!record.verify(b"4829160"));
    store.clear().unwrap();
    assert!(store.load().unwrap().is_none());
    store.clear().unwrap();

    std::fs::write(
        store.path(),
        b"{\"version\":1,\"length\":6,\"hash\":\"plain\"}",
    )
    .unwrap();
    assert!(store.load().is_err());
    remove_pin_store(&store);
}

#[test]
fn pin_unlocks_without_the_password_backend_and_password_stays_available() {
    let store = temporary_pin_store("unlock");
    write_quick_record(&store, "2580");
    let calls = Arc::new(AtomicUsize::new(0));
    let controller = AuthenticationController::with_backend(
        Box::new(FakeBackend {
            result: BackendResult::Success,
            calls: Arc::clone(&calls),
        }),
        Some(store.clone()),
        false,
    )
    .unwrap();
    controller.lock();
    let credential = wait_for_event(&controller, |event| {
        matches!(event.kind, AuthenticationEventKind::Credential { .. })
    });
    assert_eq!(
        credential.kind,
        AuthenticationEventKind::Credential { pin_length: 4 }
    );
    assert_eq!(credential.encode()[6], KIND_CREDENTIAL);

    // The password path ignores the PIN entirely.
    controller.begin(true);
    let prompt = wait_for_event(&controller, |event| {
        matches!(event.kind, AuthenticationEventKind::Prompt { .. })
    });
    assert!(matches!(
        prompt.kind,
        AuthenticationEventKind::Prompt {
            style: PromptStyle::EchoOff,
            ..
        }
    ));
    controller.cancel(prompt.state.attempt_id);
    wait_for_event(&controller, |event| {
        matches!(
            event.kind,
            AuthenticationEventKind::Result {
                cancelled: true,
                ..
            }
        )
    });
    assert_eq!(calls.load(Ordering::Relaxed), 1);

    controller.begin(false);
    let prompt = wait_for_event(&controller, |event| {
        matches!(event.kind, AuthenticationEventKind::Prompt { .. })
    });
    let AuthenticationEventKind::Prompt {
        style: PromptStyle::Pin,
        sequence,
    } = prompt.kind
    else {
        panic!("expected a PIN prompt, got {:?}", prompt.kind);
    };
    assert_eq!(
        prompt.encode()[7] >> PROMPT_STYLE_SHIFT,
        PromptStyle::Pin as u8
    );
    assert!(controller.respond(
        prompt.state.attempt_id,
        sequence,
        SecureString::new(b"2580")
    ));
    let result = wait_for_event(&controller, |event| {
        matches!(event.kind, AuthenticationEventKind::Result { .. })
    });
    assert_eq!(
        result.kind,
        AuthenticationEventKind::Result {
            success: true,
            cancelled: false
        }
    );
    assert!(!controller.locked());
    assert_eq!(calls.load(Ordering::Relaxed), 1);
    remove_pin_store(&store);
}

#[test]
fn wrong_pin_fails_and_rate_limits_like_a_wrong_password() {
    let store = temporary_pin_store("wrong");
    write_quick_record(&store, "2580");
    let controller = AuthenticationController::with_backend(
        Box::new(FakeBackend {
            result: BackendResult::Success,
            calls: Arc::new(AtomicUsize::new(0)),
        }),
        Some(store.clone()),
        false,
    )
    .unwrap();
    controller.lock();
    controller.begin(false);
    let prompt = wait_for_event(&controller, |event| {
        matches!(
            event.kind,
            AuthenticationEventKind::Prompt {
                style: PromptStyle::Pin,
                ..
            }
        )
    });
    let AuthenticationEventKind::Prompt { sequence, .. } = prompt.kind else {
        unreachable!();
    };
    assert!(controller.respond(
        prompt.state.attempt_id,
        sequence,
        SecureString::new(b"0000")
    ));
    let result = wait_for_event(&controller, |event| {
        matches!(event.kind, AuthenticationEventKind::Result { .. })
    });
    assert_eq!(
        result.kind,
        AuthenticationEventKind::Result {
            success: false,
            cancelled: false
        }
    );
    assert!(result.state.locked);
    assert!(result.state.cooldown_ms > 0);
    remove_pin_store(&store);
}

#[test]
fn the_pin_check_confirms_only_the_pin() {
    let store = temporary_pin_store("check");
    let pin = |text: &str| SecureString::new(text.as_bytes());
    assert_eq!(
        pin::check_event(store.load().unwrap().as_ref(), &pin("482916")).unwrap()["event"],
        "wrong-pin"
    );
    write_quick_record(&store, "482916");
    let record = store.load().unwrap();
    for (attempt, event) in [
        ("482916", "confirmed"),
        ("482917", "wrong-pin"),
        ("4829", "wrong-pin"),
    ] {
        assert_eq!(
            pin::check_event(record.as_ref(), &pin(attempt)).unwrap()["event"],
            event
        );
    }
    remove_pin_store(&store);
}
