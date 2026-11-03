//! A phone with a monitor plugged in.
//!
//! With the mobile shell, the built-in panel stays the phone and every other
//! output is a desk that runs the desktop shell. A window follows the policy
//! of the output it is on: on the phone it fills the panel and pauses when
//! minimized, on a desk it keeps desktop placement and the desktop layouts.
//! Without a built-in panel, or without a desk, the whole session is the
//! phone, as before.

use denial_core::topology::OutputId;
use smithay::desktop::Window;
use smithay::reexports::wayland_server::Resource;
use smithay::reexports::wayland_server::backend::ObjectId;
use smithay::utils::{Logical, Point, Rectangle, Size};

use super::super::output_policy::is_internal_panel;
use super::super::window_placement_store::WindowPlacementState;
use super::insets::configure_desktop_toplevel;
use super::window_management::{shell_content_geometry, shell_draws_server_frame};
use super::{WaylandFrontend, WaylandOutput, WindowGeometryAuthority};

/// Where a window was on a desk, kept while it is on the phone so it can go
/// back to the same place.
#[derive(Clone, Debug)]
pub(super) struct DeskPlacement {
    pub(super) connector: String,
    pub(super) geometry: Rectangle<i32, Logical>,
    pub(super) state: WindowPlacementState,
    /// The desk was unplugged under the window: it goes back when that desk
    /// returns, unless the user opened it on the phone meanwhile.
    pub(super) return_on_replug: bool,
}

impl WaylandFrontend {
    /// The built-in panel that runs the mobile shell.
    pub(super) fn phone_output(&self) -> Option<&WaylandOutput> {
        if !self.mobile_shell {
            return None;
        }
        self.outputs
            .iter()
            .find(|output| is_internal_panel(&output.connector))
    }

    /// Whether `output` is a desk: the mobile shell runs, a built-in panel
    /// carries it, and `output` is another display.
    pub(super) fn output_is_desk(&self, output: &WaylandOutput) -> bool {
        self.mobile_shell && !is_internal_panel(&output.connector) && self.phone_output().is_some()
    }

    /// Whether the phone shares the session with at least one desk.
    pub(crate) fn phone_with_desk(&self) -> bool {
        self.outputs
            .iter()
            .any(|output| self.output_is_desk(output))
    }

    /// The phone's panel, while a desk shares the session.
    pub(crate) fn phone_beside_desk(&self) -> Option<OutputId> {
        self.phone_with_desk()
            .then(|| self.phone_output().map(|output| output.id))
            .flatten()
    }

    /// Whether `window` sits on a desk and keeps desktop policy.
    pub(super) fn window_on_desk(&self, window: &Window) -> bool {
        self.mobile_shell
            && self
                .output_for_geometry(self.window_geometry_target(window))
                .is_some_and(|output| self.output_is_desk(output))
    }

    /// Whether `window` follows the phone's policy.
    pub(super) fn window_on_phone(&self, window: &Window) -> bool {
        self.mobile_shell && !self.window_on_desk(window)
    }

    /// [`Self::window_on_phone`] for the window rooted at `root`.
    pub(super) fn root_on_phone(&self, root: &ObjectId) -> bool {
        if !self.mobile_shell {
            return false;
        }
        if !self.phone_with_desk() {
            return true;
        }
        self.surface_ids
            .get(root)
            .and_then(|id| self.window_for_id(*id))
            .is_none_or(|window| !self.window_on_desk(&window))
    }

    /// Whether a touch or press at `point` lands on the phone.
    pub(super) fn point_on_phone<T: Into<f64> + Copy>(&self, point: Point<T, Logical>) -> bool {
        if !self.mobile_shell {
            return false;
        }
        let point = Point::<i32, Logical>::from((
            point.x.into().floor() as i32,
            point.y.into().floor() as i32,
        ));
        !self
            .outputs
            .iter()
            .any(|output| output.logical_geometry.contains(point) && self.output_is_desk(output))
    }

    /// Where a new window opens: on the output the user last pressed, so an
    /// app launched from the phone opens there and one launched from a desk
    /// opens on that desk.
    pub(super) fn new_window_output_geometry(&self) -> Option<Rectangle<i32, Logical>> {
        if self.phone_with_desk()
            && let Some(output) = self
                .last_press_output
                .and_then(|id| self.outputs.iter().find(|output| output.id == id))
        {
            return Some(output.logical_geometry);
        }
        self.fallback_output_geometry()
    }

    /// Remembers the output under a touch down or button press.
    pub(super) fn note_press_output(&mut self, output: Option<OutputId>) {
        if output.is_some() {
            self.last_press_output = output;
        }
    }

    /// The output that contains `point`.
    pub(super) fn output_id_at(&self, point: Point<f64, Logical>) -> Option<OutputId> {
        let point = Point::<i32, Logical>::from((point.x.floor() as i32, point.y.floor() as i32));
        self.outputs
            .iter()
            .find(|output| output.logical_geometry.contains(point))
            .map(|output| output.id)
    }
}

impl WaylandFrontend {
    /// Moves a client window between the phone and a desk. A window that
    /// comes to the phone fills it and remembers where it was on the desk; one
    /// that goes to a desk gets that place back, or a centered default.
    /// Returns whether the window moved.
    pub(super) fn move_window_between_phone_and_desk(
        &mut self,
        window: &Window,
        destination: OutputId,
    ) -> bool {
        let Some(root) = self.window_root_surface(window) else {
            return false;
        };
        let Some(output) = self.outputs.iter().find(|output| output.id == destination) else {
            return false;
        };
        let to_desk = self.output_is_desk(output);
        let from_desk = self.window_on_desk(window);
        if !self.phone_with_desk() || to_desk == from_desk {
            return false;
        }
        let output_geometry = output.logical_geometry;
        let connector = output.connector.clone();
        if to_desk {
            let bounds = self.maximize_work_area(Some(&output.output), output_geometry);
            let bounds = shell_content_geometry(bounds, shell_draws_server_frame(window));
            let saved = self
                .window_record_for_surface_mut(&root.id())
                .and_then(|record| record.desk_placement.take())
                .filter(|placement| {
                    placement.connector == connector && bounds.contains_rect(placement.geometry)
                });
            let (target, state) = saved.map_or_else(
                || {
                    (
                        default_desk_geometry(bounds),
                        WindowPlacementState::default(),
                    )
                },
                |placement| (placement.geometry, placement.state),
            );
            if let Some(toplevel) = window.toplevel() {
                configure_desktop_toplevel(toplevel, target.size, state);
            }
            self.set_window_geometry_target_with_authority(
                window,
                target,
                WindowGeometryAuthority::Pending,
            );
            self.reconcile_window_layout(window);
        } else {
            let current = self.window_geometry_target(window);
            let placement = self
                .output_for_geometry(current)
                .map(|output| DeskPlacement {
                    connector: output.connector.clone(),
                    geometry: current,
                    state: self.window_placement_state(window),
                    return_on_replug: false,
                });
            if let Some(record) = self.ensure_window_record_for_surface(&root.id()) {
                record.desk_placement = placement;
            }
            // Land on the phone first, so the mobile policy finds it there.
            self.set_window_geometry_target_with_authority(
                window,
                output_geometry,
                WindowGeometryAuthority::Pending,
            );
            self.configure_mobile_window(window);
            self.reconcile_window_layout(window);
        }
        self.update_window_output_membership(window);
        self.arrange_layout_windows();
        tracing::info!(
            window = ?root.id(),
            output = connector,
            to_desk,
            "moved window between phone and desk"
        );
        true
    }
}

impl WaylandFrontend {
    /// Before desks go away: remembers where their windows were, so they go
    /// back when the same desk returns. `retained` names the outputs that stay.
    pub(super) fn remember_windows_of_leaving_desks(&mut self, retained: &[(OutputId, &str)]) {
        if !self.phone_with_desk() {
            return;
        }
        let windows = self.space.elements().cloned().collect::<Vec<_>>();
        for window in windows {
            let geometry = self.window_geometry_target(&window);
            let Some(output) = self.output_for_geometry(geometry) else {
                continue;
            };
            if !self.output_is_desk(output)
                || retained
                    .iter()
                    .any(|(id, name)| *id == output.id && *name == output.connector)
            {
                continue;
            }
            let placement = DeskPlacement {
                connector: output.connector.clone(),
                geometry,
                state: self.window_placement_state(&window),
                return_on_replug: true,
            };
            if let Some(root) = self.window_root_surface(&window)
                && let Some(record) = self.ensure_window_record_for_surface(&root.id())
            {
                record.desk_placement = Some(placement);
            }
        }
    }

    /// Windows that left with a desk now plugged in again as `added`.
    pub(super) fn windows_returning_to_desks(&self, added: &[OutputId]) -> Vec<(u64, OutputId)> {
        let desks = self
            .outputs
            .iter()
            .filter(|output| added.contains(&output.id) && self.output_is_desk(output))
            .collect::<Vec<_>>();
        if desks.is_empty() {
            return Vec::new();
        }
        self.space
            .elements()
            .filter(|window| self.window_on_phone(window))
            .filter_map(|window| {
                let root = self.window_root_surface(window)?;
                let placement = self
                    .window_record_for_surface(&root.id())?
                    .desk_placement
                    .as_ref()?;
                let desk = desks.iter().find(|desk| {
                    placement.return_on_replug && desk.connector == placement.connector
                })?;
                Some((*self.surface_ids.get(&root.id())?, desk.id))
            })
            .collect()
    }

    /// The user opened the window on the phone: it stays there when its desk
    /// returns.
    pub(super) fn keep_window_on_phone(&mut self, root: &ObjectId) {
        if let Some(placement) = self
            .window_record_for_surface_mut(root)
            .and_then(|record| record.desk_placement.as_mut())
        {
            placement.return_on_replug = false;
        }
    }
}

/// A window new to a desk takes most of its work area, centered.
fn default_desk_geometry(bounds: Rectangle<i32, Logical>) -> Rectangle<i32, Logical> {
    let size = Size::from((
        (bounds.size.w * 3 / 5).max(1),
        (bounds.size.h * 7 / 10).max(1),
    ));
    Rectangle::new(
        Point::from((
            bounds.loc.x + (bounds.size.w - size.w) / 2,
            bounds.loc.y + (bounds.size.h - size.h) / 2,
        )),
        size,
    )
}
