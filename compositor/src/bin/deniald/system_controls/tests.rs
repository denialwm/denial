use super::*;

#[test]
fn worker_events_publish_a_coalesced_nonempty_signal() {
    let (raw_sender, receiver) = mpsc::sync_channel(2);
    let pending = Arc::new(AtomicBool::new(false));
    let sender = SystemControlEventSender::new(raw_sender, Arc::clone(&pending));

    sender.try_send(SystemControlEvent::AudioLevel {
        level: 0.5,
        request_serial: 7,
    });
    assert!(pending.swap(false, Ordering::AcqRel));
    assert_eq!(
        receiver.try_recv().unwrap(),
        SystemControlEvent::AudioLevel {
            level: 0.5,
            request_serial: 7,
        }
    );
    assert!(!pending.load(Ordering::Acquire));
}

#[test]
fn flutter_audio_packets_decode_strictly_and_clamp_percentages() {
    assert_eq!(decode_audio_request(&[0]).unwrap(), AudioRequest::ReadLevel);
    assert_eq!(
        decode_audio_request(&[1, 140, 0x78, 0x56, 0x34, 0x12]).unwrap(),
        AudioRequest::SetLevel {
            level: 1.0,
            request_serial: 0x1234_5678,
        }
    );
    assert_eq!(
        decode_audio_request(&[2]).unwrap(),
        AudioRequest::RequestStreams
    );
    assert_eq!(
        decode_audio_request(&[3, 7, 0, 0, 0, 25]).unwrap(),
        AudioRequest::SetStreamLevel {
            stream_id: 7,
            level: 0.25,
        }
    );
    assert_eq!(
        decode_audio_request(&[1, 50]).unwrap_err(),
        AudioRequestDecodeError::InvalidSize(2)
    );
    assert_eq!(
        decode_audio_request(&[9]).unwrap_err(),
        AudioRequestDecodeError::UnsupportedCommand(9)
    );
}

#[test]
fn flutter_brightness_packets_target_one_monitor_strictly() {
    let mut packet = vec![1, 0, 0, 0, 0, 0, 0, 0, 0, 125, 4, 0];
    packet.extend_from_slice(b"DP-4");
    assert_eq!(
        decode_brightness_request(&packet).unwrap(),
        BrightnessRequest::Set {
            connector: "DP-4".into(),
            monitor_id: 0,
            level: 1.0,
        }
    );

    packet[0] = 0;
    assert_eq!(
        decode_brightness_request(&packet).unwrap(),
        BrightnessRequest::Read {
            connector: "DP-4".into(),
            monitor_id: 0,
        }
    );
    assert_eq!(
        decode_brightness_request(&packet[..12]).unwrap_err(),
        BrightnessRequestDecodeError::InvalidSize(12)
    );
    packet[0] = 9;
    assert_eq!(
        decode_brightness_request(&packet).unwrap_err(),
        BrightnessRequestDecodeError::UnsupportedCommand(9)
    );
}
