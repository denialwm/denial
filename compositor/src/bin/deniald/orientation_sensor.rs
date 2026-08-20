//! Low-frequency device-orientation input from iio-sensor-proxy.
//!
//! D-Bus is deliberately isolated on a helper thread. The compositor receives
//! only already-classified cardinal changes through calloop, so sensor service
//! activation, reconnects and property reads can never delay a render tick.

use std::thread::{self, JoinHandle};
use std::time::Duration;

use denial_core::topology::OutputTransform;
use smithay::reexports::calloop::channel::{Channel, Sender, channel};
use tracing::{debug, info, warn};
use zbus::blocking::{Connection, Proxy};

const SENSOR_SERVICE: &str = "net.hadess.SensorProxy";
const SENSOR_PATH: &str = "/net/hadess/SensorProxy";
const SENSOR_INTERFACE: &str = "net.hadess.SensorProxy";
const RECONNECT_DELAY: Duration = Duration::from_secs(2);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum Orientation {
    Undefined,
    Normal,
    BottomUp,
    LeftUp,
    RightUp,
}

impl Orientation {
    pub(super) const fn output_rotation(self) -> OutputTransform {
        match self {
            Self::Undefined | Self::Normal => OutputTransform::Normal,
            Self::BottomUp => OutputTransform::Rotate180,
            // iio-sensor-proxy names the physical edge which points upward.
            // The desktop must turn in the opposite direction to remain
            // upright in panel coordinates.
            Self::LeftUp => OutputTransform::Rotate270,
            Self::RightUp => OutputTransform::Rotate90,
        }
    }

    fn parse(value: &str) -> Self {
        match value {
            "normal" => Self::Normal,
            "bottom-up" => Self::BottomUp,
            "left-up" => Self::LeftUp,
            "right-up" => Self::RightUp,
            _ => Self::Undefined,
        }
    }
}

pub(super) struct OrientationSensor {
    _worker: JoinHandle<()>,
}

impl OrientationSensor {
    pub(super) fn start() -> Result<(Self, Channel<Orientation>), std::io::Error> {
        let (events, source) = channel();
        let worker = thread::Builder::new()
            .name("denial-orientation".to_owned())
            .spawn(move || monitor(events))?;
        Ok((Self { _worker: worker }, source))
    }
}

fn monitor(events: Sender<Orientation>) {
    let mut published = None;
    loop {
        match monitor_connection(&events, &mut published) {
            MonitorResult::Closed => return,
            MonitorResult::Disconnected(error) => {
                if publish(&events, &mut published, Orientation::Undefined).is_err() {
                    return;
                }
                debug!(%error, "orientation sensor service is unavailable");
                thread::sleep(RECONNECT_DELAY);
            }
        }
    }
}

enum MonitorResult {
    Closed,
    Disconnected(String),
}

fn monitor_connection(
    events: &Sender<Orientation>,
    published: &mut Option<Orientation>,
) -> MonitorResult {
    let connection = match Connection::system() {
        Ok(connection) => connection,
        Err(error) => return MonitorResult::Disconnected(error.to_string()),
    };
    let proxy = match Proxy::new(&connection, SENSOR_SERVICE, SENSOR_PATH, SENSOR_INTERFACE) {
        Ok(proxy) => proxy,
        Err(error) => return MonitorResult::Disconnected(error.to_string()),
    };
    let mut changes = proxy.receive_property_changed::<String>("AccelerometerOrientation");
    if let Err(error) = proxy.call::<_, _, ()>("ClaimAccelerometer", &()) {
        return MonitorResult::Disconnected(error.to_string());
    }

    let has_accelerometer = proxy
        .get_property::<bool>("HasAccelerometer")
        .unwrap_or(false);
    let initial = if has_accelerometer {
        proxy
            .get_property::<String>("AccelerometerOrientation")
            .map(|value| Orientation::parse(&value))
            .unwrap_or(Orientation::Undefined)
    } else {
        Orientation::Undefined
    };
    if publish(events, published, initial).is_err() {
        drop(changes);
        let _ = proxy.call::<_, _, ()>("ReleaseAccelerometer", &());
        return MonitorResult::Closed;
    }
    if initial != Orientation::Undefined {
        info!(orientation = ?initial, "claimed the system orientation sensor");
    }

    for change in &mut changes {
        let orientation = match change.get() {
            Ok(value) => Orientation::parse(&value),
            Err(error) => {
                warn!(%error, "could not read orientation sensor update");
                break;
            }
        };
        if publish(events, published, orientation).is_err() {
            drop(changes);
            let _ = proxy.call::<_, _, ()>("ReleaseAccelerometer", &());
            return MonitorResult::Closed;
        }
    }

    drop(changes);
    let _ = proxy.call::<_, _, ()>("ReleaseAccelerometer", &());
    MonitorResult::Disconnected("orientation sensor signal stream ended".to_owned())
}

fn publish(
    events: &Sender<Orientation>,
    published: &mut Option<Orientation>,
    orientation: Orientation,
) -> Result<(), ()> {
    if *published == Some(orientation) {
        return Ok(());
    }
    events.send(orientation).map_err(|_| ())?;
    *published = Some(orientation);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::Orientation;
    use denial_core::topology::OutputTransform;

    #[test]
    fn iio_orientations_follow_the_desktop_transform_convention() {
        assert_eq!(
            Orientation::parse("normal").output_rotation(),
            OutputTransform::Normal
        );
        assert_eq!(
            Orientation::parse("bottom-up").output_rotation(),
            OutputTransform::Rotate180
        );
        assert_eq!(
            Orientation::parse("left-up").output_rotation(),
            OutputTransform::Rotate270
        );
        assert_eq!(
            Orientation::parse("right-up").output_rotation(),
            OutputTransform::Rotate90
        );
        assert_eq!(
            Orientation::parse("undefined").output_rotation(),
            OutputTransform::Normal
        );
    }
}
