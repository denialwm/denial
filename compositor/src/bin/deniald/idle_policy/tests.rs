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
        power_button_action: PowerButtonAction::Dpms,
        lock_after_screen_off: None,
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
    selected_mode[3] = PowerButtonAction::Hibernate as u8;
    assert_eq!(
        decode_configuration(&selected_mode)
            .unwrap()
            .power_button_action,
        PowerButtonAction::Hibernate
    );
    let mut suspend_mode_configuration = selected_mode;
    suspend_mode_configuration[0] = SUSPEND_MODE_CONFIGURATION_PACKET_VERSION;
    suspend_mode_configuration[3] = 0;
    assert_eq!(
        decode_configuration(&suspend_mode_configuration)
            .unwrap()
            .power_button_action,
        PowerButtonAction::Dpms
    );
    let mut legacy_configuration = selected_mode;
    legacy_configuration[0] = LEGACY_CONFIGURATION_PACKET_VERSION;
    legacy_configuration[2] = 0;
    legacy_configuration[3] = 0;
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
    selected_mode[2] = SuspendMode::SystemDefault as u8;
    selected_mode[3] = 99;
    assert!(matches!(
        decode_configuration(&selected_mode),
        Err(IdlePolicyPacketError::InvalidPowerButtonAction(99))
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
fn display_power_packet_is_one_known_byte() {
    assert_eq!(decode_display_power(&[1]), Ok(DisplayPowerRequest::Off));
    assert_eq!(decode_display_power(&[2]), Ok(DisplayPowerRequest::On));
    for packet in [&[][..], &[0], &[3], &[1, 0]] {
        assert_eq!(
            decode_display_power(packet),
            Err(DisplayPowerPacketError::InvalidPacket)
        );
    }
}

#[test]
fn power_button_system_actions_map_to_logind_methods() {
    assert_eq!(PowerButtonAction::Dpms.logind_method(), None);
    assert_eq!(PowerButtonAction::Suspend.logind_method(), Some("Suspend"));
    assert_eq!(
        PowerButtonAction::Hibernate.logind_method(),
        Some("Hibernate")
    );
    assert_eq!(
        PowerButtonAction::PowerOff.logind_method(),
        Some("PowerOff")
    );
}

#[test]
fn power_button_toggles_once_per_press_and_consumes_release() {
    let mut button = PowerButton::default();
    button.note_key("pmic", true, false);
    assert!(button.take_toggle(false));
    button.note_key("pmic", true, false);
    button.note_key("pmic", false, false);
    assert!(!button.take_toggle(false));
    button.note_key("pmic", true, false);
    assert!(button.take_toggle(false));
    button.remove_device("pmic");
    button.note_key("pmic", true, false);
    assert!(button.take_toggle(false));
}

#[test]
fn two_power_presses_in_one_dispatch_leave_power_unchanged() {
    let mut button = PowerButton::default();
    for _ in 0..2 {
        button.note_key("pmic", true, false);
        button.note_key("pmic", false, false);
    }
    assert!(!button.take_toggle(false));
}

#[test]
fn power_then_volume_down_takes_a_screenshot_instead_of_the_toggle() {
    let mut button = PowerButton::default();
    button.note_key("pmic", true, true);
    assert!(!button.take_toggle(true), "waits for the release");
    assert_eq!(button.note_volume_down(true, true), VolumeDownRoute::Take);
    assert!(button.take_screenshot());
    button.note_key("pmic", false, true);
    assert!(!button.take_toggle(true));
    assert_eq!(button.note_volume_down(false, true), VolumeDownRoute::Take);
    assert!(!button.take_screenshot());
}

#[test]
fn volume_down_then_power_takes_a_screenshot_and_no_volume_step() {
    let mut button = PowerButton::default();
    assert_eq!(
        button.note_volume_down(true, true),
        VolumeDownRoute::HoldBack
    );
    button.note_key("pmic", true, true);
    assert!(button.take_screenshot());
    assert!(
        !button.take_held_volume_down(),
        "the press never reaches the seat"
    );
    button.note_key("pmic", false, true);
    assert!(!button.take_toggle(true));
    assert_eq!(button.note_volume_down(false, true), VolumeDownRoute::Take);
}

#[test]
fn held_back_volume_down_is_delivered_when_power_does_not_follow() {
    let mut button = PowerButton::default();
    assert_eq!(
        button.note_volume_down(true, true),
        VolumeDownRoute::HoldBack
    );
    assert!(button.take_held_volume_down());
    assert_eq!(
        button.note_volume_down(false, true),
        VolumeDownRoute::Deliver
    );

    // A quick tap releases before the wait ends.
    assert_eq!(
        button.note_volume_down(true, true),
        VolumeDownRoute::HoldBack
    );
    assert_eq!(
        button.note_volume_down(false, true),
        VolumeDownRoute::DeliverHeldPress
    );
    assert!(!button.take_held_volume_down());

    // Power after the press went through: a screenshot, the keys stay volume.
    assert_eq!(
        button.note_volume_down(true, true),
        VolumeDownRoute::HoldBack
    );
    assert!(button.take_held_volume_down());
    button.note_key("pmic", true, true);
    assert!(button.take_screenshot());
    button.note_key("pmic", false, true);
    assert_eq!(
        button.note_volume_down(false, true),
        VolumeDownRoute::Deliver
    );
}

#[test]
fn power_alone_toggles_on_release_with_chords_and_volume_stays_volume() {
    let mut button = PowerButton::default();
    button.note_key("pmic", true, true);
    button.note_key("pmic", false, true);
    assert!(button.take_toggle(true));
    assert!(!button.take_screenshot());

    // Without chords, Volume Down never waits or joins Power.
    button.note_key("pmic", true, false);
    assert_eq!(
        button.note_volume_down(true, false),
        VolumeDownRoute::Deliver
    );
    assert!(button.take_toggle(false));
    assert!(!button.take_screenshot());
    assert_eq!(
        button.note_volume_down(false, false),
        VolumeDownRoute::Deliver
    );
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
    policy.configure(
        configuration(Some(Duration::from_secs(300)), None, None),
        now,
    );
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
fn power_button_does_not_lock_when_locking_is_off() {
    let now = Instant::now();
    let mut policy = IdlePolicy::default();
    policy.configure(configuration(None, None, None), now);
    let sleep = policy.toggle_now([(output(1), true)], now);
    assert!(!sleep.lock);
    assert!(!sleep.power_requests[0].powered);
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
fn equal_lock_and_dpms_thresholds_delay_lock_until_after_display_off() {
    let started = Instant::now();
    let mut policy = IdlePolicy::default();
    policy.configure(
        configuration(
            Some(Duration::from_secs(10)),
            Some(Duration::from_secs(10)),
            None,
        ),
        started,
    );

    let display_off = policy.evaluate(
        started + Duration::from_secs(10),
        false,
        [(output(1), true)],
    );
    assert!(!display_off.lock);
    assert_eq!(
        display_off.power_requests,
        [IdlePowerRequest {
            output: output(1),
            powered: false,
        }]
    );
    assert_eq!(
        policy.next_deadline(),
        Some(started + Duration::from_secs(15))
    );
    assert!(
        policy
            .evaluate(
                started + Duration::from_secs(14),
                false,
                [(output(1), false)],
            )
            .eq(&IdlePolicyActions::default())
    );

    let lock = policy.evaluate(
        started + Duration::from_secs(15),
        false,
        [(output(1), false)],
    );
    assert!(lock.lock);
    assert!(lock.power_requests.is_empty());
}

#[test]
fn equal_suspend_threshold_waits_for_the_delayed_lock() {
    let started = Instant::now();
    let mut policy = IdlePolicy::default();
    policy.configure(
        configuration(
            Some(Duration::from_secs(10)),
            Some(Duration::from_secs(10)),
            Some(Duration::from_secs(10)),
        ),
        started,
    );

    let display_off = policy.evaluate(
        started + Duration::from_secs(10),
        false,
        [(output(1), true)],
    );
    assert!(!display_off.lock);
    assert!(!display_off.suspend);
    assert_eq!(display_off.power_requests.len(), 1);
    assert_eq!(
        policy.next_deadline(),
        Some(started + Duration::from_secs(15))
    );

    let lock_and_suspend = policy.evaluate(
        started + Duration::from_secs(15),
        false,
        [(output(1), false)],
    );
    assert!(lock_and_suspend.lock);
    assert!(lock_and_suspend.suspend);
    assert!(lock_and_suspend.power_requests.is_empty());
}

#[test]
fn disabled_dpms_does_not_delay_an_equal_configured_lock_timeout() {
    let started = Instant::now();
    let mut policy = IdlePolicy::default();
    policy.configure(
        configuration(Some(Duration::from_secs(10)), None, None),
        started,
    );

    assert!(
        policy
            .evaluate(
                started + Duration::from_secs(10),
                false,
                [(output(1), true)],
            )
            .lock
    );
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

#[test]
fn hardware_wake_is_one_way_targets_one_output_and_resets_idle() {
    let now = Instant::now();
    let mut policy = IdlePolicy::default();
    policy.configure(configuration(None, Some(Duration::from_secs(1)), None), now);
    policy.blank_now([(output(1), true), (output(2), true)]);
    policy.note_external_power_request(output(1), false);
    let request = policy.wake_output_now(output(1), now + Duration::from_secs(2));
    assert_eq!(
        request,
        IdlePowerRequest {
            output: output(1),
            powered: true
        }
    );
    assert!(policy.blanked_outputs.contains(&output(2)));
    assert_eq!(
        policy.wake_output_now(output(1), now + Duration::from_secs(2)),
        request
    );
    assert!(
        policy
            .evaluate(
                now + Duration::from_millis(2500),
                false,
                [(output(1), true), (output(2), false)]
            )
            .power_requests
            .is_empty()
    );
}

#[test]
fn screen_off_lock_delay_is_a_version_four_flag() {
    let mut delayed = packet(
        DPMS_ENABLED | SCREEN_OFF_LOCK_ENABLED,
        60_000,
        30_000,
        60_000,
    );
    delayed[4..8].copy_from_slice(&5_000u32.to_le_bytes());
    assert_eq!(
        decode_configuration(&delayed)
            .unwrap()
            .lock_after_screen_off,
        Some(Duration::from_secs(5))
    );
    let mut at_once = delayed;
    at_once[4..8].fill(0);
    assert_eq!(
        decode_configuration(&at_once)
            .unwrap()
            .lock_after_screen_off,
        Some(Duration::ZERO)
    );
    let mut stray = delayed;
    stray[1] = DPMS_ENABLED;
    assert_eq!(
        decode_configuration(&stray),
        Err(IdlePolicyPacketError::NonZeroReservedBytes)
    );
    let mut older = at_once;
    older[0] = POWER_BUTTON_CONFIGURATION_PACKET_VERSION;
    assert_eq!(
        decode_configuration(&older),
        Err(IdlePolicyPacketError::InvalidFlags(
            DPMS_ENABLED | SCREEN_OFF_LOCK_ENABLED
        ))
    );
}

#[test]
fn power_button_locks_after_the_screen_off_delay_unless_woken() {
    let now = Instant::now();
    let mut policy = IdlePolicy::default();
    policy.configure(
        IdlePolicyConfiguration {
            lock_after_screen_off: Some(Duration::from_secs(5)),
            ..configuration(None, None, None)
        },
        now,
    );
    let sleep = policy.toggle_now([(output(1), true)], now);
    assert!(!sleep.lock);
    assert_eq!(policy.next_deadline(), Some(now + Duration::from_secs(5)));
    // Playback holds idling off, not the lock of a screen turned off.
    assert!(
        !policy
            .evaluate(now + Duration::from_secs(4), true, [(output(1), false)])
            .lock
    );
    assert!(
        policy
            .evaluate(now + Duration::from_secs(5), true, [(output(1), false)])
            .lock
    );
    assert_eq!(policy.next_deadline(), None);

    policy.toggle_now([(output(1), false)], now);
    policy.toggle_now([(output(1), true)], now);
    policy.toggle_now([(output(1), false)], now + Duration::from_secs(1));
    assert_eq!(policy.next_deadline(), None);
    assert!(
        !policy
            .evaluate(now + Duration::from_secs(9), false, [(output(1), true)])
            .lock
    );
}

#[test]
fn idle_screen_off_starts_the_lock_delay_and_zero_locks_with_it() {
    let now = Instant::now();
    let dpms = Duration::from_secs(30);
    let mut policy = IdlePolicy::default();
    policy.configure(
        IdlePolicyConfiguration {
            lock_after_screen_off: Some(Duration::from_secs(10)),
            ..configuration(None, Some(dpms), None)
        },
        now,
    );
    let off = policy.evaluate(now + dpms, false, [(output(1), true)]);
    assert!(!off.power_requests[0].powered);
    assert!(!off.lock);
    assert_eq!(
        policy.next_deadline(),
        Some(now + dpms + Duration::from_secs(10))
    );
    assert!(
        policy
            .evaluate(
                now + dpms + Duration::from_secs(10),
                false,
                [(output(1), false)]
            )
            .lock
    );

    let mut policy = IdlePolicy::default();
    policy.configure(
        IdlePolicyConfiguration {
            lock_after_screen_off: Some(Duration::ZERO),
            ..configuration(None, Some(dpms), None)
        },
        now,
    );
    assert!(policy.evaluate(now + dpms, false, [(output(1), true)]).lock);
    let mut policy = IdlePolicy::default();
    policy.configure(
        IdlePolicyConfiguration {
            lock_after_screen_off: Some(Duration::ZERO),
            ..configuration(None, None, None)
        },
        now,
    );
    assert!(policy.toggle_now([(output(1), true)], now).lock);
}

fn phone_beside_desk(now: Instant) -> IdlePolicy {
    let mut policy = IdlePolicy::default();
    policy.configure(
        configuration(
            Some(Duration::from_secs(300)),
            Some(Duration::from_secs(30)),
            Some(Duration::from_secs(600)),
        ),
        now,
    );
    assert!(!policy.set_phone_with_desk(Some(output(1)), now));
    policy
}

#[test]
fn power_button_beside_a_desk_toggles_only_the_phone_and_never_locks() {
    let now = Instant::now();
    let mut policy = phone_beside_desk(now);
    let off = policy.toggle_now([(output(1), true), (output(2), true)], now);
    assert_eq!(
        off.power_requests,
        vec![IdlePowerRequest {
            output: output(1),
            powered: false,
        }]
    );
    assert!(!off.lock);
    // Typing at the desk does not light the phone again.
    assert!(policy.note_activity(now + Duration::from_secs(1)).is_empty());
    let on = policy.toggle_now([(output(1), false), (output(2), true)], now);
    assert_eq!(
        on.power_requests,
        vec![IdlePowerRequest {
            output: output(1),
            powered: true,
        }]
    );
}

#[test]
fn phone_panel_idles_on_its_own_clock_beside_a_desk() {
    let now = Instant::now();
    let mut policy = phone_beside_desk(now);
    let later = now + Duration::from_secs(31);
    // The desk was in use the whole time; the phone was not touched.
    policy.note_activity(later - Duration::from_secs(1));
    assert_eq!(
        policy.evaluate_phone(later, false, true),
        Some(IdlePowerRequest {
            output: output(1),
            powered: false,
        })
    );
    let actions = policy.evaluate(later, false, [(output(1), true), (output(2), true)]);
    assert!(actions.power_requests.is_empty());
    assert!(!actions.lock && !actions.suspend);
    // A phone video holds its panel lit.
    let mut policy = phone_beside_desk(now);
    assert_eq!(policy.evaluate_phone(later, true, true), None);
}

#[test]
fn desk_idle_leaves_the_phone_to_its_own_clock_and_never_suspends_while_lit() {
    let now = Instant::now();
    let mut policy = phone_beside_desk(now);
    policy.note_phone_touch(now + Duration::from_secs(29));
    let actions = policy.evaluate(
        now + Duration::from_secs(31),
        false,
        [(output(1), true), (output(2), true)],
    );
    assert_eq!(
        actions.power_requests,
        vec![IdlePowerRequest {
            output: output(2),
            powered: false,
        }]
    );
    let actions = policy.evaluate(
        now + Duration::from_secs(700),
        false,
        [(output(1), true), (output(2), false)],
    );
    assert!(!actions.suspend);
}

#[test]
fn desk_leaving_a_dark_phone_locks_it() {
    let now = Instant::now();
    let mut policy = phone_beside_desk(now);
    policy.toggle_now([(output(1), true), (output(2), true)], now);
    assert!(policy.set_phone_with_desk(None, now));
    let mut policy = phone_beside_desk(now);
    assert!(!policy.set_phone_with_desk(None, now));
}
