//! On the audio worker, route a volume key to the modem while its voice path
//! is active. The hardware control has its own discrete scale.
use super::{SystemControlEvent, SystemControlEventSender};
use std::time::Duration;
use zbus::blocking::{Connection, fdo::DBusProxy};
use zbus::proxy::CacheProperties;

#[zbus::proxy(
    interface = "org.callaudio.CallAudio1",
    default_service = "org.callaudio",
    default_path = "/org/callaudio",
    gen_async = false
)]
trait CallAudio {
    #[zbus(property)]
    fn active(&self) -> zbus::Result<bool>;
    #[zbus(property)]
    fn volume_max(&self) -> zbus::Result<u32>;
    #[zbus(property)]
    fn volume(&self) -> zbus::Result<u32>;
    #[zbus(property)]
    fn set_volume(&self, step: u32) -> zbus::Result<()>;
}

pub(super) enum Change {
    Step(bool),
    Set(u32),
}

#[derive(Default)]
pub(super) struct CallVolume {
    bus: Option<Connection>,
}

impl CallVolume {
    /// False allows an ordinary volume key through to the media mixer.
    pub(super) fn handle(&mut self, change: Change, events: &SystemControlEventSender) -> bool {
        if self.bus.as_ref().is_none_or(Connection::is_closed) {
            self.bus = zbus::blocking::connection::Builder::session()
                .and_then(|builder| builder.method_timeout(Duration::from_millis(500)).build())
                .ok();
        }
        let Some(bus) = &self.bus else { return false };
        match Self::change(bus, change) {
            Ok(Some(event)) => {
                events.try_send(event);
                true
            }
            Ok(None) => false,
            Err(error) => {
                tracing::warn!(%error, "could not adjust call volume");
                true
            }
        }
    }

    fn change(bus: &Connection, change: Change) -> zbus::Result<Option<SystemControlEvent>> {
        // A card without a voice profile never takes the name. Address the
        // actual owner so a key cannot activate a service waiting for a card.
        let owner = match DBusProxy::new(bus)?.get_name_owner("org.callaudio".try_into()?) {
            Ok(owner) => owner,
            Err(zbus::fdo::Error::NameHasNoOwner(_)) => return Ok(None),
            Err(error) => return Err(error.into()),
        };
        let call = CallAudioProxy::builder(bus)
            .destination(owner)?
            .cache_properties(CacheProperties::No)
            .build()?;
        if !call.active()? {
            return Ok(None);
        }
        let maximum = call.volume_max()?;
        let previous = call.volume()?;
        if maximum == 0 || previous > maximum {
            return Err(zbus::Error::Failure("invalid call volume range".into()));
        }
        let wanted = match change {
            Change::Step(true) => previous.saturating_add(1),
            Change::Step(false) => previous.saturating_sub(1),
            Change::Set(step) => step,
        }
        .min(maximum);
        if wanted != previous {
            call.set_volume(wanted)?;
        }
        let step = call.volume()?;
        Ok(Some(SystemControlEvent::CallVolume {
            previous,
            step,
            maximum,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Mixer {
        active: bool,
        step: u32,
    }

    #[zbus::interface(name = "org.callaudio.CallAudio1")]
    impl Mixer {
        #[zbus(property)]
        fn active(&self) -> bool {
            self.active
        }
        #[zbus(property)]
        fn volume_max(&self) -> u32 {
            9
        }
        #[zbus(property)]
        fn volume(&self) -> u32 {
            self.step
        }
        #[zbus(property)]
        fn set_volume(&mut self, step: u32) {
            self.step = step;
        }
    }

    #[test]
    fn keys_and_slider_follow_the_active_voice_path() {
        // compositor-test runs the bus services on a private session bus.
        if std::env::var_os("DENIAL_NOTIFICATION_TEST_BUS").is_none() {
            return;
        }
        let bus = Connection::session().unwrap();
        let adjust = |change| CallVolume::change(&bus, change).unwrap();
        assert_eq!(adjust(Change::Step(true)), None);
        let service = zbus::blocking::connection::Builder::session()
            .unwrap()
            .serve_at(
                "/org/callaudio",
                Mixer {
                    active: false,
                    step: 5,
                },
            )
            .unwrap()
            .name("org.callaudio")
            .unwrap()
            .build()
            .unwrap();
        let object = service
            .object_server()
            .interface::<_, Mixer>("/org/callaudio")
            .unwrap();
        assert_eq!(adjust(Change::Step(true)), None);
        object.get_mut().active = true;
        for (change, previous, step) in [
            (Change::Step(true), 5, 6),
            (Change::Step(false), 6, 5),
            (Change::Set(9), 5, 9),
            (Change::Step(true), 9, 9),
            (Change::Set(0), 9, 0),
            (Change::Step(false), 0, 0),
        ] {
            assert_eq!(
                adjust(change),
                Some(SystemControlEvent::CallVolume {
                    previous,
                    step,
                    maximum: 9
                })
            );
        }
        object.get_mut().active = false;
        assert_eq!(adjust(Change::Set(8)), None);
        assert_eq!(object.get().step, 0);
        assert_eq!(adjust(Change::Step(false)), None);
    }
}
