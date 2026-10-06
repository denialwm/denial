//! Optional hapticd client. No hardware access or D-Bus waits on the UI thread.
use std::{
    io,
    sync::mpsc::{self, Receiver, SyncSender},
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};
use tracing::{debug, info};
use zbus::blocking::{Connection, Proxy, connection::Builder};

const SERVICE: &str = "org.hapticd";
const PATH: &str = "/org/hapticd/Haptics";
const INTERFACE: &str = "org.hapticd.Haptics1";
const CALL_TIMEOUT: Duration = Duration::from_millis(250);
const MAX_AGE: Duration = Duration::from_millis(200);
const TAP_GAP: Duration = Duration::from_millis(18);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Kind {
    Prewarm,
    Tap,
    FingerprintRejected,
}

pub(crate) struct Request {
    pub kind: Kind,
    created: Instant,
}

pub(crate) struct HapticsClient {
    sender: Option<SyncSender<Request>>,
    worker: Option<JoinHandle<()>>,
}

impl HapticsClient {
    pub(crate) fn new() -> io::Result<Self> {
        let (sender, receiver) = mpsc::sync_channel(4);
        let worker = thread::Builder::new()
            .name("denial-haptics".into())
            .spawn(move || {
                crate::cpu_scheduling::normalize_current_worker("haptics");
                run(receiver);
            })?;
        let client = Self {
            sender: Some(sender),
            worker: Some(worker),
        };
        client.submit(Kind::Prewarm);
        Ok(client)
    }

    pub(crate) fn handle_packet(&self, packet: &[u8]) -> Result<(), &'static str> {
        self.submit(decode(packet)?);
        Ok(())
    }

    pub(crate) fn fingerprint_rejected(&self) {
        self.submit(Kind::FingerprintRejected);
    }

    fn submit(&self, kind: Kind) {
        if let Some(sender) = &self.sender {
            // Dropping feedback under overload is preferable to delayed taps.
            let _ = sender.try_send(Request {
                kind,
                created: Instant::now(),
            });
        }
    }

    #[cfg(test)]
    pub(crate) fn recording() -> (Self, Receiver<Request>) {
        let (sender, receiver) = mpsc::sync_channel(4);
        (
            Self {
                sender: Some(sender),
                worker: None,
            },
            receiver,
        )
    }
}

impl Drop for HapticsClient {
    fn drop(&mut self) {
        self.sender.take();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

fn decode(packet: &[u8]) -> Result<Kind, &'static str> {
    match packet {
        [0] => Ok(Kind::Prewarm),
        [1] => Ok(Kind::Tap),
        _ => Err("haptics expects one byte: prewarm=0 or tap=1"),
    }
}

fn pattern(kind: Kind) -> &'static [(u32, f64)] {
    match kind {
        Kind::Prewarm => &[],
        Kind::Tap => &[(15, 0.3)],
        Kind::FingerprintRejected => &[(35, 0.7), (60, 0.0), (35, 0.7)],
    }
}

fn run(receiver: Receiver<Request>) {
    let mut connection: Option<Connection> = None;
    let mut retry_after = Instant::now();
    let mut last_tap = None;
    let mut rejection_until = None;
    while let Ok(request) = receiver.recv() {
        let now = Instant::now();
        if now < retry_after
            || (request.kind != Kind::Prewarm && now.duration_since(request.created) > MAX_AGE)
        {
            continue;
        }
        if request.kind == Kind::Tap
            && (last_tap.is_some_and(|last| now.duration_since(last) < TAP_GAP)
                || rejection_until.is_some_and(|until| now < until))
        {
            continue;
        }
        let result = (|| -> zbus::Result<()> {
            if connection.is_none() {
                connection = Some(Builder::system()?.method_timeout(CALL_TIMEOUT).build()?);
            }
            let proxy = Proxy::new(connection.as_ref().unwrap(), SERVICE, PATH, INTERFACE)?;
            if request.kind == Kind::Prewarm {
                // A harmless property read also activates the optional daemon.
                let _: u32 = proxy.get_property("MaxDurationMs")?;
            } else if request.created.elapsed() <= MAX_AGE {
                let id: u64 = proxy.call("PlayPattern", &("", pattern(request.kind)))?;
                if request.kind == Kind::FingerprintRejected {
                    rejection_until = Some(Instant::now() + Duration::from_millis(130));
                    info!(effect_id = id, "fingerprint rejection haptic accepted");
                } else {
                    last_tap = Some(Instant::now());
                }
            }
            Ok(())
        })();
        if let Err(error) = result {
            debug!(%error, "optional hapticd service unavailable");
            connection = None;
            retry_after = Instant::now() + Duration::from_secs(1);
        }
    }
    // Dropping the persistent connection cancels effects owned by this client.
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_valid_shell_packets_request_taps() {
        let (client, receiver) = HapticsClient::recording();
        for invalid in [&[][..], &[2][..], &[1, 0][..]] {
            assert!(client.handle_packet(invalid).is_err());
        }
        assert!(receiver.try_recv().is_err());
        client.handle_packet(&[0]).unwrap();
        client.handle_packet(&[1]).unwrap();
        assert_eq!(receiver.recv().unwrap().kind, Kind::Prewarm);
        assert_eq!(receiver.recv().unwrap().kind, Kind::Tap);
    }
    #[test]
    fn feedback_is_bounded_and_rejection_has_two_pulses() {
        let (client, receiver) = HapticsClient::recording();
        for _ in 0..1000 {
            client.fingerprint_rejected();
        }
        assert_eq!(receiver.try_iter().count(), 4);
        assert_eq!(
            pattern(Kind::FingerprintRejected),
            &[(35, 0.7), (60, 0.0), (35, 0.7)]
        );
        assert!(pattern(Kind::Tap).iter().map(|s| s.0).sum::<u32>() < 20);
    }
}
