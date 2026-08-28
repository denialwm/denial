use super::*;

fn output(id: u64) -> OutputId {
    OutputId(id)
}

#[test]
fn packet_is_exact_bounded_and_zero_disables() {
    assert_eq!(decode_timeout(&0u64.to_le_bytes()).unwrap(), None);
    assert_eq!(
        decode_timeout(&60_000u64.to_le_bytes()).unwrap(),
        Some(Duration::from_secs(60))
    );
    assert!(matches!(
        decode_timeout(&[0; 7]),
        Err(IdlePolicyPacketError::InvalidSize(7))
    ));
    let too_large = u64::try_from(MAX_TIMEOUT.as_millis()).unwrap() + 1;
    assert!(matches!(
        decode_timeout(&too_large.to_le_bytes()),
        Err(IdlePolicyPacketError::TimeoutTooLarge(value)) if value == too_large
    ));
}

#[test]
fn explicit_blank_uses_native_input_to_wake_without_an_idle_timeout() {
    let started = Instant::now();
    let mut policy = IdleDpmsPolicy::default();
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
fn inactivity_blanks_only_powered_outputs_and_activity_restores_them() {
    let started = Instant::now();
    let mut policy = IdleDpmsPolicy::default();
    assert!(
        policy
            .configure(Some(Duration::from_secs(60)), started)
            .is_empty()
    );
    assert!(
        policy
            .evaluate(
                started + Duration::from_secs(59),
                false,
                [(output(1), true), (output(2), false)],
            )
            .is_empty()
    );
    assert_eq!(
        policy.evaluate(
            started + Duration::from_secs(60),
            false,
            [(output(1), true), (output(2), false)],
        ),
        [IdlePowerRequest {
            output: output(1),
            powered: false,
        }]
    );
    assert_eq!(
        policy.note_activity(started + Duration::from_secs(61)),
        [IdlePowerRequest {
            output: output(1),
            powered: true,
        }]
    );
}

#[test]
fn inhibition_resets_the_full_timeout_and_can_wake_a_blanked_output() {
    let started = Instant::now();
    let mut policy = IdleDpmsPolicy::default();
    policy.configure(Some(Duration::from_secs(10)), started);
    assert!(
        !policy.evaluate(
            started + Duration::from_secs(10),
            false,
            [(output(7), true)],
        )[0]
        .powered
    );
    assert_eq!(
        policy.evaluate(
            started + Duration::from_secs(11),
            true,
            [(output(7), false)],
        ),
        [IdlePowerRequest {
            output: output(7),
            powered: true,
        }]
    );
    assert!(
        policy
            .evaluate(started + Duration::from_secs(50), true, [(output(7), true)],)
            .is_empty()
    );
    assert!(
        policy
            .evaluate(
                started + Duration::from_secs(51),
                false,
                [(output(7), true)],
            )
            .is_empty()
    );
    assert!(
        policy
            .evaluate(
                started + Duration::from_secs(60),
                false,
                [(output(7), true)],
            )
            .is_empty()
    );
    assert!(
        !policy.evaluate(
            started + Duration::from_secs(61),
            false,
            [(output(7), true)],
        )[0]
        .powered
    );
}

#[test]
fn manual_power_request_is_not_undone_by_activity() {
    let started = Instant::now();
    let mut policy = IdleDpmsPolicy::default();
    policy.configure(Some(Duration::from_secs(1)), started);
    policy.evaluate(started + Duration::from_secs(1), false, [(output(3), true)]);
    policy.note_external_power_request(output(3), false);
    assert!(
        policy
            .note_activity(started + Duration::from_secs(2))
            .is_empty()
    );
}
