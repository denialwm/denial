//! Laptop lid position for the runtime display policy.
//!
//! libinput reports each lid toggle as it happens, but it withholds the
//! initial position of switches it does not trust, and a session away from its
//! VT receives no toggles. logind reads the switch itself. It supplies the
//! position at startup, and again whenever libinput may have missed a change:
//! after the session returns to its VT and after system sleep.

#[cfg(feature = "flutter")]
use smithay::reexports::calloop::channel::Sender;
#[cfg(feature = "flutter")]
use tracing::warn;
use tracing::{debug, info};

const LOGIND: &str = "org.freedesktop.login1";
const LOGIND_PATH: &str = "/org/freedesktop/login1";
const LOGIND_MANAGER: &str = "org.freedesktop.login1.Manager";

/// Reads whether the lid is closed. logind reports a machine without a lid
/// as open.
pub(super) fn read_closed() -> zbus::Result<bool> {
    let connection = crate::bus::blocking_system()?;
    let reply = connection.call_method(
        Some(LOGIND),
        LOGIND_PATH,
        Some("org.freedesktop.DBus.Properties"),
        "Get",
        &(LOGIND_MANAGER, "LidClosed"),
    )?;
    let value = reply.body().deserialize::<zbus::zvariant::OwnedValue>()?;
    Ok(bool::try_from(value)?)
}

/// Reads the lid position at startup. Without logind the lid counts as open,
/// so the built-in panel behaves as it would on a machine without a lid.
pub(super) fn startup_closed() -> bool {
    match read_closed() {
        Ok(closed) => {
            if closed {
                info!("the lid is closed at startup");
            }
            closed
        }
        Err(error) => {
            debug!(%error, "could not read the lid position from logind; assuming it is open");
            false
        }
    }
}

/// A logind reading, tagged with the libinput toggle it follows.
#[cfg(feature = "flutter")]
pub(super) struct LidReading {
    generation: u64,
    closed: bool,
}

/// Lid observations waiting for the compositor loop to apply them.
#[cfg(feature = "flutter")]
#[derive(Default)]
pub(super) struct LidSwitch {
    pending: Option<bool>,
    /// Advances with every libinput toggle, so a logind reading requested
    /// before a newer toggle cannot overwrite it.
    generation: u64,
    readings: Option<Sender<LidReading>>,
}

#[cfg(feature = "flutter")]
impl LidSwitch {
    pub(super) fn new(readings: Sender<LidReading>) -> Self {
        Self {
            readings: Some(readings),
            ..Self::default()
        }
    }

    pub(super) fn note_toggle(&mut self, closed: bool) {
        self.generation = self.generation.wrapping_add(1);
        self.pending = Some(closed);
    }

    /// Asks logind for the current position without blocking the compositor
    /// thread. The answer arrives through [`Self::note_reading`].
    pub(super) fn request_reading(&self) {
        let Some(readings) = self.readings.clone() else {
            return;
        };
        let generation = self.generation;
        let reader = std::thread::Builder::new()
            .name("denial-lid".to_owned())
            .spawn(move || {
                crate::cpu_scheduling::normalize_current_worker("lid");
                match read_closed() {
                    Ok(closed) => {
                        // The compositor may already be shutting down.
                        let _ = readings.send(LidReading { generation, closed });
                    }
                    Err(error) => debug!(%error, "could not refresh the lid position from logind"),
                }
            });
        if let Err(error) = reader {
            warn!(%error, "could not start the lid position reader");
        }
    }

    pub(super) fn note_reading(&mut self, reading: LidReading) {
        if reading.generation == self.generation {
            self.pending = Some(reading.closed);
        }
    }

    pub(super) fn take_pending(&mut self) -> Option<bool> {
        self.pending.take()
    }
}

#[cfg(all(test, feature = "flutter"))]
mod tests {
    use super::*;

    #[test]
    fn a_logind_reading_never_overwrites_a_newer_toggle() {
        let mut lid = LidSwitch::default();
        let requested_at = lid.generation;
        lid.note_toggle(false);
        assert_eq!(lid.take_pending(), Some(false));

        lid.note_reading(LidReading {
            generation: requested_at,
            closed: true,
        });
        assert_eq!(lid.take_pending(), None);

        lid.note_reading(LidReading {
            generation: lid.generation,
            closed: true,
        });
        assert_eq!(lid.take_pending(), Some(true));
    }
}
