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
        false,
    )
    .unwrap();
    controller.lock();
    controller.begin();
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
        false,
    )
    .unwrap();
    controller.lock();
    controller.begin();
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
    controller.begin();
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
        false,
    )
    .unwrap();
    controller.lock();
    controller.begin();
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
