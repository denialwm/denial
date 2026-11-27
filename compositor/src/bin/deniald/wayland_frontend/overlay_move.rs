//! Denial's own overlays, the `dev.denial.*` layer surfaces such as the
//! Polkit and Access dialogs, move with Super and the left button as windows
//! do. The layer keeps its own anchors and margins; Denial shows it shifted
//! by how far the user dragged it, kept on its screen, until it unmaps. The
//! client never hears of it, so it cannot move itself.

use std::sync::{Mutex, PoisonError};

use super::*;
use smithay::wayland::shell::wlr_layer::Layer as WlrLayer;

/// The namespaces of the overlays that move: Denial's own.
const MOVABLE_NAMESPACE: &str = "dev.denial.";

/// How far the user moved an overlay, kept in its surface's data map.
#[derive(Default)]
struct OverlayShift(Mutex<Point<f64, Logical>>);

fn shift_of(surface: &WlSurface) -> Point<f64, Logical> {
    if !surface.is_alive() {
        return Point::default();
    }
    with_states(surface, |states| {
        states
            .data_map
            .get::<OverlayShift>()
            .map(|shift| *shift.0.lock().unwrap_or_else(PoisonError::into_inner))
            .unwrap_or_default()
    })
}

/// `shift` such that `arranged` moved by it stays within `screen`: none
/// along an axis where it does not fit.
pub(super) fn kept_on_screen(
    arranged: Rectangle<i32, Logical>,
    screen: Rectangle<i32, Logical>,
    shift: Point<f64, Logical>,
) -> Point<f64, Logical> {
    let axis = |at: i32, size: i32, start: i32, length: i32, by: f64| {
        let low = f64::from(start) - f64::from(at);
        let high = f64::from(start + length) - f64::from(at + size);
        if low > high { 0.0 } else { by.clamp(low, high) }
    };
    Point::from((
        axis(
            arranged.loc.x,
            arranged.size.w,
            screen.loc.x,
            screen.size.w,
            shift.x,
        ),
        axis(
            arranged.loc.y,
            arranged.size.h,
            screen.loc.y,
            screen.size.h,
            shift.y,
        ),
    ))
}

impl WaylandFrontend {
    /// The overlay `surface` belongs to, if it is one of Denial's own: its
    /// root, where its anchors and margins put it, and its screen, global.
    fn movable_overlay(
        &self,
        surface: &WlSurface,
    ) -> Option<(WlSurface, Rectangle<i32, Logical>, Rectangle<i32, Logical>)> {
        let (root, output_id) = self.layer_root_surface(surface)?;
        let output = self.outputs.iter().find(|entry| entry.id == output_id)?;
        let map = layer_map_for_output(&output.output);
        let layer = map.layer_for_surface(&root, WindowSurfaceType::TOPLEVEL)?;
        if layer.layer() != WlrLayer::Overlay || !layer.namespace().starts_with(MOVABLE_NAMESPACE) {
            return None;
        }
        let mut arranged = map.layer_geometry(layer)?;
        arranged.loc = saturating_point_add(output.logical_geometry.loc, arranged.loc);
        Some((root, arranged, output.logical_geometry))
    }

    /// How far to show `layer` from where its anchors and margins put it,
    /// `arranged`, global. Zero for every layer but a moved overlay.
    pub(super) fn overlay_shift(
        &self,
        layer: &DesktopLayerSurface,
        arranged: Rectangle<i32, Logical>,
    ) -> Point<f64, Logical> {
        let shift = shift_of(layer.wl_surface());
        if shift == Point::default() {
            return shift;
        }
        let screen = self
            .outputs
            .iter()
            .map(|entry| entry.logical_geometry)
            .find(|screen| screen.contains(arranged.loc))
            .unwrap_or(arranged);
        kept_on_screen(arranged, screen, shift)
    }

    /// The user takes hold of the overlay `surface` belongs to: its root and
    /// how far it is moved already. None for anything else.
    pub(crate) fn lift_overlay(
        &self,
        surface: &WlSurface,
    ) -> Option<(WlSurface, Point<f64, Logical>)> {
        let (root, arranged, screen) = self.movable_overlay(surface)?;
        let shift = kept_on_screen(arranged, screen, shift_of(&root));
        Some((root, shift))
    }

    /// The user drags the overlay `root` to `shift` from where its anchors
    /// and margins put it. Gives its id for the scene, unless it is gone.
    pub(crate) fn drag_overlay(
        &mut self,
        root: &WlSurface,
        shift: Point<f64, Logical>,
    ) -> Option<u64> {
        let (_, arranged, screen) = self.movable_overlay(root)?;
        let shift = kept_on_screen(arranged, screen, shift);
        with_states(root, |states| {
            states
                .data_map
                .insert_if_missing_threadsafe(OverlayShift::default);
            let stored = states.data_map.get::<OverlayShift>()?;
            *stored.0.lock().unwrap_or_else(PoisonError::into_inner) = shift;
            Some(())
        })?;
        self.surface_id(root)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rect(x: i32, y: i32, w: i32, h: i32) -> Rectangle<i32, Logical> {
        Rectangle::new((x, y).into(), (w, h).into())
    }

    #[test]
    fn a_moved_overlay_stays_on_its_screen() {
        let screen = rect(0, 0, 1920, 1080);
        let dialog = rect(660, 280, 600, 520);
        let kept = kept_on_screen(dialog, screen, Point::from((-2000.0, 50.0)));
        assert_eq!(kept, Point::from((-660.0, 50.0)));
        let kept = kept_on_screen(dialog, screen, Point::from((0.0, 900.0)));
        assert_eq!(kept, Point::from((0.0, 280.0)));
    }

    #[test]
    fn an_overlay_larger_than_its_screen_stays_put() {
        let screen = rect(0, 0, 400, 800);
        let dialog = rect(-100, 100, 600, 520);
        let kept = kept_on_screen(dialog, screen, Point::from((30.0, 10.0)));
        assert_eq!(kept, Point::from((0.0, 10.0)));
    }
}
