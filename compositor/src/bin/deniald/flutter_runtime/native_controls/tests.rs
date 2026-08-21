use super::*;
use std::collections::VecDeque;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Event {
    Prewarm,
    Tap,
    Reset,
}

#[derive(Default)]
struct FakeTransport {
    events: Vec<Event>,
    results: VecDeque<io::Result<()>>,
}

impl HapticsTransport for FakeTransport {
    fn prewarm(&mut self) -> io::Result<()> {
        self.events.push(Event::Prewarm);
        self.results.pop_front().unwrap_or(Ok(()))
    }

    fn tap(&mut self) -> io::Result<()> {
        self.events.push(Event::Tap);
        self.results.pop_front().unwrap_or(Ok(()))
    }

    fn reset(&mut self) {
        self.events.push(Event::Reset);
    }
}

#[test]
fn validates_commands_and_rate_limits_taps_at_the_exact_boundary() {
    let mut handler = HapticsHandler::with_transport(FakeTransport::default());
    assert_eq!(
        handler.handle_at(&[0], Duration::ZERO).unwrap(),
        HapticsOutcome::Prewarmed
    );
    assert_eq!(
        handler.handle_at(&[1], Duration::ZERO).unwrap(),
        HapticsOutcome::Tapped
    );
    assert_eq!(
        handler
            .handle_at(&[1], Duration::from_micros(17_999))
            .unwrap(),
        HapticsOutcome::RateLimited
    );
    assert_eq!(
        handler
            .handle_at(&[1], Duration::from_micros(18_000))
            .unwrap(),
        HapticsOutcome::Tapped
    );
    assert!(matches!(
        handler.handle_at(&[], Duration::ZERO),
        Err(HapticsError::InvalidPacketSize(0))
    ));
    assert!(matches!(
        handler.handle_at(&[2], Duration::ZERO),
        Err(HapticsError::UnsupportedCommand(2))
    ));
}

#[test]
fn transport_failure_resets_and_recovers_without_log_flooding() {
    let failure = || Err(io::Error::new(io::ErrorKind::ConnectionRefused, "offline"));
    let transport = FakeTransport {
        events: Vec::new(),
        results: VecDeque::from([failure(), failure(), Ok(()), failure()]),
    };
    let mut handler = HapticsHandler::with_transport(transport);

    assert!(matches!(
        handler.handle_at(&[1], Duration::ZERO),
        Err(HapticsError::Transport {
            operation: "tap",
            ..
        })
    ));
    assert_eq!(
        handler.handle_at(&[1], Duration::from_millis(18)).unwrap(),
        HapticsOutcome::TransportUnavailable
    );
    assert_eq!(
        handler.handle_at(&[1], Duration::from_millis(36)).unwrap(),
        HapticsOutcome::Tapped
    );
    assert!(matches!(
        handler.handle_at(&[1], Duration::from_millis(54)),
        Err(HapticsError::Transport {
            operation: "tap",
            ..
        })
    ));
    assert_eq!(
        handler.transport.events,
        [
            Event::Tap,
            Event::Reset,
            Event::Tap,
            Event::Reset,
            Event::Tap,
            Event::Tap,
            Event::Reset,
        ]
    );
}
