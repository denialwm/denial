//! Apps drawn larger than the shell. A Wayland client that connects while
//! the apps scale is above 1 gets its inverse as Smithay's client scale: it
//! sees the screen that many times smaller and draws at that many times the
//! screen's fractional scale, so it fills the same pixels larger. Droidloom
//! keeps the screen's scale; it sizes Android apps by its own density.
//!
//! Smithay converts surfaces, input and outputs by the client scale. XDG
//! sizes, window geometry and popup positions stay in the client's units:
//! Denial converts what it sends and receives here. A client that makes a
//! layer surface is part of the desktop, not an app, and goes back to the
//! screen's scale.

use std::collections::VecDeque;
use std::sync::Mutex;

use smithay::reexports::wayland_server::Client;
use smithay::reexports::wayland_server::Resource;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::utils::{Logical, Point, Rectangle, Size};
use smithay::wayland::compositor::with_states;
use smithay::wayland::shell::xdg::SurfaceCachedState;

use super::handlers::DenialClientState;

/// How many sizes asked of one window are remembered: those still in flight.
const ASKED_SIZES: usize = 4;

/// The scale a client connecting from `pid` draws apps at.
pub(super) fn connection_scale(pid: Option<i32>, apps_scale: f64) -> f64 {
    if apps_scale == 1.0 || pid.is_some_and(is_droidloom) {
        1.0
    } else {
        apps_scale
    }
}

fn is_droidloom(pid: i32) -> bool {
    std::fs::read_link(format!("/proc/{pid}/exe"))
        .ok()
        .and_then(|program| {
            program
                .file_name()
                .map(|name| name.to_string_lossy().starts_with("droidloom"))
        })
        .unwrap_or(false)
}

/// How many logical pixels one of `client`'s own is.
pub(super) fn client_factor(client: &Client) -> f64 {
    client
        .get_data::<DenialClientState>()
        .map_or(1.0, DenialClientState::apps_scale)
}

/// How many logical pixels one of the own pixels of `surface`'s client is.
pub(super) fn factor(surface: &WlSurface) -> f64 {
    surface
        .client()
        .map_or(1.0, |client| client_factor(&client))
}

/// Puts the client of a new layer surface back at the screen's scale.
/// Answers whether it was drawing apps larger, so its outputs need telling.
pub(super) fn leave_apps(surface: &WlSurface) -> bool {
    let Some(client) = surface.client() else {
        return false;
    };
    let Some(data) = client.get_data::<DenialClientState>() else {
        return false;
    };
    if data.apps_scale() == 1.0 {
        return false;
    }
    data.set_apps_scale(1.0);
    true
}

/// The sizes Denial asked of a window, in its client's units and in logical
/// pixels: the size the client commits maps back to exactly the one asked,
/// never to a neighbour that would make Denial ask again.
#[derive(Default)]
struct AskedSizes(Mutex<VecDeque<(Size<i32, Logical>, Size<i32, Logical>)>>);

/// `size`, logical, in the units of `surface`'s client, remembered so its
/// commit maps back to `size`. A zero side stays zero: the client chooses.
pub(super) fn client_size(surface: &WlSurface, size: Size<i32, Logical>) -> Size<i32, Logical> {
    let factor = factor(surface);
    if factor == 1.0 {
        return size;
    }
    let client = scale_size(size, factor.recip());
    with_states(surface, |states| {
        let asked = states
            .data_map
            .get_or_insert_threadsafe(AskedSizes::default);
        let mut asked = asked
            .0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        asked.retain(|&(sent, _)| sent != client);
        if asked.len() == ASKED_SIZES {
            asked.pop_front();
        }
        asked.push_back((client, size));
    });
    client
}

/// `size`, logical, in the units of `surface`'s client, not remembered.
pub(super) fn client_bounds(surface: &WlSurface, size: Size<i32, Logical>) -> Size<i32, Logical> {
    scale_size(size, factor(surface).recip())
}

/// Puts the window geometry and size limits `surface` committed in logical
/// pixels. Smithay replaces them with the client's on every applied commit
/// and calls the commit handler once after, which calls this first.
pub(super) fn convert_committed(surface: &WlSurface) {
    let factor = factor(surface);
    if factor == 1.0 {
        return;
    }
    with_states(surface, |states| {
        let asked = states
            .data_map
            .get::<AskedSizes>()
            .map(|asked| {
                asked
                    .0
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner())
                    .clone()
            })
            .unwrap_or_default();
        let mut cached = states.cached_state.get::<SurfaceCachedState>();
        let current = cached.current();
        if let Some(geometry) = current.geometry.as_mut() {
            geometry.loc = scale_point(geometry.loc, factor);
            geometry.size = asked
                .iter()
                .find(|&&(sent, _)| sent == geometry.size)
                .map_or_else(|| scale_size(geometry.size, factor), |&(_, size)| size);
        }
        current.min_size = scale_size(current.min_size, factor);
        current.max_size = scale_size(current.max_size, factor);
    });
}

/// A point of `surface`'s client, such as a popup's offset, in logical pixels.
pub(super) fn logical_point(
    surface: &WlSurface,
    point: Point<i32, Logical>,
) -> Point<i32, Logical> {
    scale_point(point, factor(surface))
}

/// A rectangle of `client`, such as a text cursor, in logical pixels.
pub(super) fn logical_rectangle(
    client: &Client,
    rectangle: Rectangle<i32, Logical>,
) -> Rectangle<i32, Logical> {
    let factor = client_factor(client);
    Rectangle::new(
        scale_point(rectangle.loc, factor),
        scale_size(rectangle.size, factor),
    )
}

pub(super) fn scale_point(point: Point<i32, Logical>, by: f64) -> Point<i32, Logical> {
    if by == 1.0 {
        return point;
    }
    Point::from((scale(point.x, by), scale(point.y, by)))
}

pub(super) fn scale_size(size: Size<i32, Logical>, by: f64) -> Size<i32, Logical> {
    if by == 1.0 {
        return size;
    }
    let side = |value: i32| {
        if value > 0 {
            scale(value, by).max(1)
        } else {
            value
        }
    };
    Size::from((side(size.w), side(size.h)))
}

fn scale(value: i32, by: f64) -> i32 {
    (f64::from(value) * by)
        .round()
        .clamp(f64::from(i32::MIN), f64::from(i32::MAX)) as i32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_sides_stay_for_the_client_to_choose() {
        assert_eq!(scale_size(Size::from((0, 801)), 0.5), Size::from((0, 401)));
        assert_eq!(scale_size(Size::from((1, 1)), 0.25), Size::from((1, 1)));
    }

    #[test]
    fn points_round_to_the_nearest_pixel() {
        assert_eq!(
            scale_point(Point::from((-3, 7)), 1.5),
            Point::from((-5, 11))
        );
    }
}
