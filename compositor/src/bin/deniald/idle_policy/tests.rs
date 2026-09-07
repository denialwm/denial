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
        suspend_mode: SuspendMode::SystemDefault,
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
    let mut selected_mode = packet(0, 1, 1, 1);
    selected_mode[2] = SuspendMode::Deep as u8;
    assert_eq!(
        decode_configuration(&selected_mode).unwrap().suspend_mode,
        SuspendMode::Deep
    );
    let mut legacy_configuration = selected_mode;
    legacy_configuration[0] = LEGACY_CONFIGURATION_PACKET_VERSION;
    legacy_configuration[2] = 0;
    assert_eq!(
        decode_configuration(&legacy_configuration)
            .unwrap()
            .suspend_mode,
        SuspendMode::SystemDefault
    );
    selected_mode[2] = 99;
    assert!(matches!(
        decode_configuration(&selected_mode),
        Err(IdlePolicyPacketError::InvalidSuspendMode(99))
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
fn power_button_toggles_once_per_press_and_consumes_release() {
    let mut button = PowerButton::default();
    button.note_key("pmic", true);
    assert!(button.take_toggle());
    button.note_key("pmic", true);
    button.note_key("pmic", false);
    assert!(!button.take_toggle());
    button.note_key("pmic", true);
    assert!(button.take_toggle());
    button.remove_device("pmic");
    button.note_key("pmic", true);
    assert!(button.take_toggle());
}

#[test]
fn two_power_presses_in_one_dispatch_leave_power_unchanged() {
    let mut button = PowerButton::default();
    for _ in 0..2 {
        button.note_key("pmic", true);
        button.note_key("pmic", false);
    }
    assert!(!button.take_toggle());
}

#[test]
fn power_button_wakes_double_tap_and_external_blank_and_resets_idle() {
    let now = Instant::now();
    let mut policy = IdlePolicy::default();
    policy.blank_now([(output(1), true)]);
    assert_eq!(
        policy.toggle_now([(output(1), false)], now).power_requests,
        [IdlePowerRequest {
            output: output(1),
            powered: true,
        }]
    );
    assert!(policy.note_activity(now).is_empty());
    assert_eq!(
        policy.toggle_now([(output(1), true)], now).power_requests,
        [IdlePowerRequest {
            output: output(1),
            powered: false,
        }]
    );
    policy.note_external_power_request(output(1), false);
    assert_eq!(
        policy.toggle_now([(output(1), false)], now).power_requests,
        [IdlePowerRequest {
            output: output(1),
            powered: true,
        }]
    );
    assert_eq!(policy.last_activity, now);
}

#[test]
fn idle_inhibitor_cannot_undo_a_power_button_blank() {
    let now = Instant::now();
    let mut policy = IdlePolicy::default();
    policy.toggle_now([(output(1), true)], now);
    assert!(
        policy
            .evaluate(now, true, [(output(1), false)])
            .power_requests
            .is_empty()
    );
    assert_eq!(
        policy.toggle_now([(output(1), false)], now).power_requests,
        [IdlePowerRequest {
            output: output(1),
            powered: true,
        }]
    );
}

#[test]
fn power_button_locks_when_blanking_but_does_not_relock_on_wake() {
    let now = Instant::now();
    let mut policy = IdlePolicy::default();
    let sleep = policy.toggle_now([(output(1), true)], now);
    assert!(sleep.lock);
    assert!(!sleep.suspend);
    assert!(!sleep.power_requests[0].powered);

    let wake = policy.toggle_now([(output(1), false)], now);
    assert!(!wake.lock);
    assert!(!wake.suspend);
    assert!(wake.power_requests[0].powered);
    assert!(!policy.toggle_now([], now).lock);
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
