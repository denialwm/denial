use super::*;

fn output(id: u64) -> OutputId {
    OutputId(id)
}

fn configuration(
    lock_timeout: Option<Duration>,
    dpms_timeout: Option<Duration>,
    suspend_timeout: Option<Duration>,
) -> IdlePolicyConfiguration {
    IdlePolicyConfiguration {
        lock_timeout,
        dpms_timeout,
        suspend_timeout,
    }
}

fn packet(flags: u8, lock_ms: u64, dpms_ms: u64, suspend_ms: u64) -> [u8; PACKET_BYTES] {
    let mut packet = [0; PACKET_BYTES];
    packet[0] = PACKET_VERSION;
    packet[1] = flags;
    packet[8..16].copy_from_slice(&lock_ms.to_le_bytes());
    packet[16..24].copy_from_slice(&dpms_ms.to_le_bytes());
    packet[24..32].copy_from_slice(&suspend_ms.to_le_bytes());
    packet
}

#[test]
fn packet_is_versioned_bounded_ordered_and_preserves_optional_actions() {
    assert_eq!(
        decode_configuration(&packet(
            LOCK_ENABLED | DPMS_ENABLED,
            60_000,
            120_000,
            180_000
        ))
        .unwrap(),
        configuration(
            Some(Duration::from_secs(60)),
            Some(Duration::from_secs(120)),
            None,
        )
    );
    assert_eq!(
        decode_configuration(&0u64.to_le_bytes()).unwrap(),
        IdlePolicyConfiguration::default()
    );
    assert_eq!(
        decode_configuration(&60_000u64.to_le_bytes()).unwrap(),
        configuration(None, Some(Duration::from_secs(60)), None)
    );
    assert!(matches!(
        decode_configuration(&[0; 7]),
        Err(IdlePolicyPacketError::InvalidSize(7))
    ));
    assert!(matches!(
        decode_configuration(&packet(0x80, 1, 1, 1)),
        Err(IdlePolicyPacketError::InvalidFlags(0x80))
    ));
    assert!(matches!(
        decode_configuration(&packet(0, 0, 1, 1)),
        Err(IdlePolicyPacketError::ZeroTimeout("lock"))
    ));
    assert!(matches!(
        decode_configuration(&packet(0, 2, 1, 1)),
        Err(IdlePolicyPacketError::TimeoutAfterSuspend("lock"))
    ));
    let too_large = u64::try_from(MAX_TIMEOUT.as_millis()).unwrap() + 1;
    assert!(matches!(
        decode_configuration(&packet(0, 1, 1, too_large)),
        Err(IdlePolicyPacketError::TimeoutTooLarge {
            action: "suspend",
            milliseconds,
        }) if milliseconds == too_large
    ));
}

#[test]
fn explicit_blank_uses_native_input_to_wake_without_an_idle_timeout() {
    let started = Instant::now();
    let mut policy = IdlePolicy::default();
    assert_eq!(
        policy.blank_now([(output(1), true), (output(2), false)]),
        [IdlePowerRequest {
            output: output(1),
            powered: false,
        }]
    );
    assert_eq!(
        policy.note_activity(started),
        [IdlePowerRequest {
            output: output(1),
            powered: true,
        }]
    );
}

#[test]
fn inactivity_triggers_lock_dpms_and_suspend_once_in_threshold_order() {
    let started = Instant::now();
    let mut policy = IdlePolicy::default();
    policy.configure(
        configuration(
            Some(Duration::from_secs(5)),
            Some(Duration::from_secs(10)),
            Some(Duration::from_secs(15)),
        ),
        started,
    );

    let lock = policy.evaluate(
        started + Duration::from_secs(5),
        false,
        [(output(1), true), (output(2), false)],
    );
    assert!(lock.lock);
    assert!(!lock.suspend);
    assert!(lock.power_requests.is_empty());

    let dpms = policy.evaluate(
        started + Duration::from_secs(10),
        false,
        [(output(1), true), (output(2), false)],
    );
    assert!(!dpms.lock);
    assert!(!dpms.suspend);
    assert_eq!(
        dpms.power_requests,
        [IdlePowerRequest {
            output: output(1),
            powered: false,
        }]
    );

    let suspend = policy.evaluate(
        started + Duration::from_secs(15),
        false,
        [(output(1), false), (output(2), false)],
    );
    assert!(!suspend.lock);
    assert!(suspend.suspend);
    assert!(suspend.power_requests.is_empty());
    assert!(
        policy
            .evaluate(
                started + Duration::from_secs(20),
                false,
                [(output(1), false)],
            )
            .eq(&IdlePolicyActions::default())
    );

    assert_eq!(
        policy.note_activity(started + Duration::from_secs(21)),
        [IdlePowerRequest {
            output: output(1),
            powered: true,
        }]
    );
    assert!(
        policy
            .evaluate(
                started + Duration::from_secs(26),
                false,
                [(output(1), true)],
            )
            .lock
    );
}

#[test]
fn equal_dpms_and_suspend_thresholds_commit_display_off_first() {
    let started = Instant::now();
    let mut policy = IdlePolicy::default();
    policy.configure(
        configuration(
            None,
            Some(Duration::from_secs(10)),
            Some(Duration::from_secs(10)),
        ),
        started,
    );

    let first = policy.evaluate(
        started + Duration::from_secs(10),
        false,
        [(output(1), true)],
    );
    assert!(!first.suspend);
    assert_eq!(first.power_requests.len(), 1);
    assert_eq!(
        policy.next_deadline(),
        Some(started + Duration::from_secs(10))
    );

    let second = policy.evaluate(
        started + Duration::from_secs(10),
        false,
        [(output(1), false)],
    );
    assert!(second.suspend);
    assert!(second.power_requests.is_empty());
}

#[test]
fn inhibition_resets_every_action_and_can_wake_a_blanked_output() {
    let started = Instant::now();
    let mut policy = IdlePolicy::default();
    policy.configure(
        configuration(
            Some(Duration::from_secs(5)),
            Some(Duration::from_secs(10)),
            Some(Duration::from_secs(15)),
        ),
        started,
    );
    assert!(
        !policy
            .evaluate(
                started + Duration::from_secs(10),
                false,
                [(output(7), true)],
            )
            .power_requests[0]
            .powered
    );
    assert_eq!(
        policy
            .evaluate(
                started + Duration::from_secs(11),
                true,
                [(output(7), false)],
            )
            .power_requests,
        [IdlePowerRequest {
            output: output(7),
            powered: true,
        }]
    );
    assert!(
        policy
            .evaluate(started + Duration::from_secs(50), true, [(output(7), true)],)
            .eq(&IdlePolicyActions::default())
    );
    assert!(
        policy
            .evaluate(
                started + Duration::from_secs(51),
                false,
                [(output(7), true)],
            )
            .eq(&IdlePolicyActions::default())
    );
    assert!(
        policy
            .evaluate(
                started + Duration::from_secs(56),
                false,
                [(output(7), true)],
            )
            .lock
    );
}

#[test]
fn manual_power_request_is_not_undone_by_activity() {
    let started = Instant::now();
    let mut policy = IdlePolicy::default();
    policy.configure(
        configuration(None, Some(Duration::from_secs(1)), None),
        started,
    );
    policy.evaluate(started + Duration::from_secs(1), false, [(output(3), true)]);
    policy.note_external_power_request(output(3), false);
    assert!(
        policy
            .note_activity(started + Duration::from_secs(2))
            .is_empty()
    );
}
