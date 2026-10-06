//! Bind a hidden lock layout acknowledgement to subsequently authorized frames.
use super::*;
use std::sync::atomic::AtomicU64;

pub(super) const CHANNEL: &CStr = c"denial/lock_frame";
static NEXT_TOKEN: AtomicU64 = AtomicU64::new(1);

#[derive(Default)]
pub(super) struct LockFrameGate {
    epoch: Option<u64>,
    token: u64,
    acknowledged: bool,
}

impl LockFrameGate {
    fn begin(&mut self, epoch: u64) {
        self.epoch = Some(epoch);
        self.token = NEXT_TOKEN.fetch_add(1, Ordering::Relaxed).max(1);
        self.acknowledged = false;
    }

    fn acknowledge(&mut self, token: u64, epoch: Option<u64>) -> bool {
        if token == 0 || token != self.token || epoch != self.epoch || epoch.is_none() {
            return false;
        }
        self.acknowledged = true;
        true
    }

    pub(super) fn render_token(&self, epoch: Option<u64>) -> u64 {
        if self.acknowledged && self.epoch == epoch && epoch.is_some() {
            self.token
        } else {
            0
        }
    }

    fn permits(&self, token: u64, epoch: Option<u64>) -> bool {
        epoch.is_none() || (token != 0 && token == self.render_token(epoch))
    }
}

impl FlutterRuntime {
    pub(crate) fn prepare_locked_wake(&mut self) -> Result<(), Box<dyn Error>> {
        if let Some(epoch) = self.authentication.locked_epoch() {
            self.lock_frame_gate.begin(epoch);
            self.publish_authentication_events()?;
            self.send_lock_frame_request()?;
        }
        Ok(())
    }

    fn send_lock_frame_request(&self) -> Result<(), Box<dyn Error>> {
        self.host()
            .engine()
            .send_platform_message(CHANNEL, self.lock_frame_gate.token.to_string().as_bytes())?;
        Ok(())
    }

    pub(super) fn synchronize_lock_frame(&mut self) -> Result<(), Box<dyn Error>> {
        if self.lock_frame_gate.token != 0 {
            if let Some(epoch) = self.authentication.locked_epoch() {
                if self.lock_frame_gate.epoch != Some(epoch) {
                    self.prepare_locked_wake()?;
                }
            } else {
                self.lock_frame_gate = LockFrameGate::default();
                self.host().engine().send_platform_message(CHANNEL, b"0")?;
            }
        }
        Ok(())
    }

    pub(super) fn handle_lock_frame_message(&mut self, data: &[u8]) -> Vec<u8> {
        if data == b"sync" {
            return self.lock_frame_gate.token.to_string().into_bytes();
        }
        if data.len() <= 20
            && let Ok(text) = std::str::from_utf8(data)
            && let Ok(token) = text.parse::<u64>()
            && self
                .lock_frame_gate
                .acknowledge(token, self.authentication.locked_epoch())
        {
            info!(token, "Flutter prepared the lock layout for display wake");
        }
        Vec::new()
    }

    pub(crate) fn permits_wake_frame(&self, token: u64) -> bool {
        self.lock_frame_gate
            .permits(token, self.authentication.locked_epoch())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wake_requires_acknowledgement_and_a_subsequently_tagged_frame() {
        let mut gate = LockFrameGate::default();
        gate.begin(7);
        let token = gate.token;
        assert!(!gate.permits(0, Some(7)));
        assert!(!gate.permits(token, Some(7)));
        assert!(!gate.acknowledge(token + 1, Some(7)));
        assert!(gate.acknowledge(token, Some(7)));
        assert!(!gate.permits(0, Some(7))); // An older queued frame stays rejected.
        assert!(gate.permits(gate.render_token(Some(7)), Some(7)));
        assert!(!gate.permits(token, Some(8))); // Re-lock invalidates old content.
        gate.begin(8);
        assert!(!gate.acknowledge(token, Some(8)));
        assert!(gate.permits(0, None)); // Successful authentication may show desktop.
    }

    #[test]
    fn each_wake_and_runtime_gets_a_new_token() {
        let mut gate = LockFrameGate::default();
        gate.begin(1);
        let old = gate.token;
        gate.begin(1);
        assert!(!gate.acknowledge(old, Some(1)));
        let mut replacement = LockFrameGate::default();
        replacement.begin(1);
        assert!(!replacement.acknowledge(gate.token, Some(1)));
    }
}
