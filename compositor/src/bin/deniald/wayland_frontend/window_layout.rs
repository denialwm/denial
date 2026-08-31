//! Smithay adapter for pluggable window-layout algorithms.

use std::collections::HashMap;

use denial_core::topology::OutputId;
use smithay::desktop::Window;
use smithay::reexports::wayland_protocols::xdg::shell::server::xdg_toplevel;
use smithay::reexports::wayland_server::Resource;
use smithay::reexports::wayland_server::backend::ObjectId;
use smithay::utils::{Logical, Point, Rectangle, Size};
use smithay::wayland::compositor::with_states;
use smithay::wayland::seat::WaylandFocus;
use smithay::wayland::shell::xdg::SurfaceCachedState;
use smithay::xwayland::xwm::WmWindowType;
use tracing::{info, warn};

use super::super::window_grab::constrain_dimension;
use super::super::window_layout::{
    LayoutDirection, LayoutInsertion, LayoutPlacement, LayoutResizeEdges, LayoutResizeRequest,
    WindowLayoutKind, create_window_layout, directional_neighbor,
};
#[cfg(feature = "flutter")]
use super::shell_content_geometry;
use super::{WaylandFrontend, toplevel_has_state};

impl WaylandFrontend {
    pub(super) fn window_layout_manages_geometry(&self) -> bool {
        self.window_layout.manages_geometry()
    }

    pub(crate) fn window_is_layout_managed(&self, window: &Window) -> bool {
        self.window_root_surface(window)
            .is_some_and(|surface| self.window_layout.contains(&surface.id()))
    }

    fn layout_swap_target_at(&self, location: Point<f64, Logical>) -> Option<Window> {
        if !location.x.is_finite() || !location.y.is_finite() {
            return None;
        }
        let point = Point::<i32, Logical>::from((
            location
                .x
                .floor()
                .clamp(f64::from(i32::MIN), f64::from(i32::MAX)) as i32,
            location
                .y
                .floor()
                .clamp(f64::from(i32::MIN), f64::from(i32::MAX)) as i32,
        ));
        self.space
            .elements()
            .rev()
            .find(|window| {
                self.window_is_layout_managed(window)
                    && !self.window_has_constrained_state(window)
                    && self.window_geometry_target(window).contains(point)
            })
            .cloned()
    }

    pub(crate) fn layout_drop_target_at(
        &self,
        window: &Window,
        location: Point<i32, Logical>,
    ) -> Option<Window> {
        if !self.window_is_layout_managed(window) {
            return None;
        }
        let output = self
            .outputs
            .iter()
            .find(|output| output.logical_geometry.contains(location))?
            .id;
        self.layout_swap_target_at(location.to_f64()).or_else(|| {
            self.space
                .elements()
                .filter(|candidate| {
                    self.window_is_layout_managed(candidate)
                        && !self.window_has_constrained_state(candidate)
                        && self
                            .output_for_geometry(self.window_geometry_target(candidate))
                            .is_some_and(|candidate_output| candidate_output.id == output)
                })
                .min_by(|left, right| {
                    layout_drop_distance(self.window_geometry_target(left), location).total_cmp(
                        &layout_drop_distance(self.window_geometry_target(right), location),
                    )
                })
                .cloned()
        })
    }

    pub(crate) fn layout_neighbor_window(
        &self,
        window: &Window,
        direction: LayoutDirection,
    ) -> Option<Window> {
        let focused = self.window_root_surface(window)?.id();
        let placements = self.current_layout_placements();
        let neighbor = directional_neighbor(&focused, &placements, direction)?;
        self.window_for_layout_id(&neighbor)
    }

    pub(crate) fn resize_layout_window(
        &mut self,
        window: &Window,
        edges: LayoutResizeEdges,
        delta_x: f64,
        delta_y: f64,
    ) -> Vec<(Window, Rectangle<i32, Logical>)> {
        let Some(window_id) = self.window_root_surface(window).map(|root| root.id()) else {
            return Vec::new();
        };
        let geometry = self.window_geometry_target(window);
        let Some(output) = self.output_for_geometry(geometry) else {
            return Vec::new();
        };
        let output_id = output.id;
        let output_handle = output.output.clone();
        let output_geometry = output.logical_geometry;
        let work_area = self.maximize_work_area(Some(&output_handle), output_geometry);
        let gap = self.layout_gap();
        let before = self
            .current_layout_placements()
            .into_iter()
            .map(|placement| (placement.window, placement.geometry))
            .collect::<HashMap<_, _>>();
        if !self.window_layout.resize(LayoutResizeRequest {
            window: window_id,
            work_area,
            gap,
            delta_x,
            delta_y,
            edges,
        }) {
            return Vec::new();
        }
        self.arrange_layout_windows();
        self.current_layout_placements()
            .into_iter()
            .filter(|placement| {
                before.get(&placement.window).copied() != Some(placement.geometry)
                    && self
                        .output_for_geometry(placement.geometry)
                        .is_some_and(|candidate| candidate.id == output_id)
            })
            .filter_map(|placement| {
                self.window_for_layout_id(&placement.window).map(|window| {
                    let geometry = self.window_geometry_target(&window);
                    (window, geometry)
                })
            })
            .collect()
    }

    pub(crate) fn swap_layout_windows(&mut self, first: &Window, second: &Window) -> bool {
        let Some(first) = self.window_root_surface(first).map(|root| root.id()) else {
            return false;
        };
        let Some(second) = self.window_root_surface(second).map(|root| root.id()) else {
            return false;
        };
        if !self.window_layout.swap(&first, &second) {
            return false;
        }
        self.arrange_layout_windows();
        true
    }

    /// Resolve a shell overview drop without surrendering geometry ownership.
    /// A populated destination exchanges leaves; an empty output receives the
    /// existing leaf as a normal layout insertion. Returning false means the
    /// window is floating and the caller should apply ordinary placement.
    pub(crate) fn apply_layout_drop(
        &mut self,
        window: &Window,
        location: Point<i32, Logical>,
    ) -> bool {
        if !self.window_is_layout_managed(window) {
            return false;
        }
        let Some(output) = self
            .outputs
            .iter()
            .find(|output| output.logical_geometry.contains(location))
            .map(|output| output.id)
        else {
            return true;
        };
        let target = self.layout_drop_target_at(window, location);
        if let Some(target) = target {
            if target != *window {
                self.swap_layout_windows(window, &target);
            }
            return true;
        }

        let Some(window_id) = self.window_root_surface(window).map(|root| root.id()) else {
            return true;
        };
        self.window_layout.insert(LayoutInsertion {
            window: window_id,
            output,
            anchor: None,
        });
        self.arrange_layout_windows();
        true
    }

    /// Switch algorithms without exposing protocol or lifecycle details to the
    /// implementation. Floating rectangles survive managed-layout switches and
    /// are restored only when returning to stacking.
    pub(crate) fn set_window_layout_kind(&mut self, kind: WindowLayoutKind) -> bool {
        if self.window_layout.kind() == kind {
            return false;
        }

        self.layout_insertion_anchors.clear();
        let previously_managed = self.window_layout.manages_geometry();
        let next = create_window_layout(kind);
        let next_managed = next.manages_geometry();
        if previously_managed && !next_managed {
            self.restore_stacking_geometries();
        }
        self.window_layout = next;
        if next_managed {
            self.rebuild_window_layout();
        }
        info!(
            layout = kind.settings_name(),
            "changed desktop window layout"
        );
        true
    }

    /// Reconcile a mapped window after its role and size hints are final.
    /// Layout algorithms only ever see regular, resizable toplevels; protocol
    /// policy for dialogs and auxiliary surfaces stays isolated in this adapter.
    pub(super) fn reconcile_window_layout(&mut self, window: &Window) -> bool {
        if !self.window_layout.manages_geometry() {
            return false;
        }
        let Some(root) = self.window_root_surface(window) else {
            return false;
        };
        let window_id = root.id();
        let remembered_anchor = self.layout_insertion_anchors.remove(&window_id);
        if !self.window_layout_eligible(window) {
            let removed = self.window_layout.remove(&window_id);
            if removed {
                self.restore_detached_window_geometry(window, &window_id);
                self.arrange_layout_windows();
            } else {
                self.layout_restore_geometries.remove(&window_id);
            }
            return removed;
        }
        if self.window_layout.contains(&window_id) {
            return false;
        }
        let geometry = self.window_geometry_target(window);
        let restore = self
            .layout_restore_geometries
            .get(&window_id)
            .copied()
            .filter(|geometry| has_visible_size(*geometry))
            .unwrap_or_else(|| self.stacking_geometry_for_layout(window, geometry));
        let Some(output) = self
            .output_for_geometry(restore)
            .map(|output| output.id)
            .or(self.ticker_output)
            .or_else(|| self.outputs.first().map(|output| output.id))
        else {
            return false;
        };
        if has_visible_size(restore) {
            self.layout_restore_geometries
                .entry(window_id.clone())
                .or_insert(restore);
        }
        let anchor = remembered_anchor
            .or_else(|| self.focused_layout_window())
            .filter(|anchor| self.window_layout.contains(anchor));
        self.window_layout.insert(LayoutInsertion {
            window: window_id,
            output,
            anchor,
        });
        self.arrange_layout_windows();
        true
    }

    /// XDG activates a new toplevel before its initial commit finalizes parent
    /// metadata. Remember the previously focused leaf so insertion still
    /// follows the user's focus, as Dwindle does, once the window is eligible.
    pub(super) fn remember_layout_insertion_anchor(&mut self, window: &Window) {
        if !self.window_layout.manages_geometry() {
            return;
        }
        let Some(window_id) = self.window_root_surface(window).map(|root| root.id()) else {
            return;
        };
        let Some(anchor) = self
            .focused_layout_window()
            .filter(|anchor| self.window_layout.contains(anchor))
        else {
            return;
        };
        self.layout_insertion_anchors.insert(window_id, anchor);
    }

    /// Detach a window and collapse its layout node. `forget_restore` is false
    /// for minimization so activation can re-enroll the same floating identity.
    pub(super) fn remove_window_from_layout(
        &mut self,
        window: &Window,
        forget_restore: bool,
    ) -> bool {
        let Some(window_id) = self.window_root_surface(window).map(|root| root.id()) else {
            return false;
        };
        let removed = self.window_layout.remove(&window_id);
        if forget_restore {
            self.layout_restore_geometries.remove(&window_id);
        }
        if removed {
            self.arrange_layout_windows();
        }
        removed
    }

    /// Rebuild output membership after hotplug/rotation while preserving each
    /// window's original stacking rectangle.
    pub(super) fn rebuild_window_layout(&mut self) -> bool {
        if !self.window_layout.manages_geometry() {
            return false;
        }
        let windows = self
            .space
            .elements()
            .filter_map(|window| {
                if !self.window_layout_eligible(window) {
                    return None;
                }
                let root = self.window_root_surface(window)?;
                let geometry = self.window_geometry_target(window);
                let restore = self.stacking_geometry_for_layout(window, geometry);
                let output = self
                    .output_for_geometry(restore)
                    .map(|output| output.id)
                    .or(self.ticker_output)
                    .or_else(|| self.outputs.first().map(|output| output.id))?;
                Some((root.id(), output, restore))
            })
            .collect::<Vec<_>>();
        self.window_layout.clear();
        let mut previous_by_output = HashMap::<OutputId, ObjectId>::new();
        for (window, output, geometry) in windows {
            if has_visible_size(geometry) {
                self.layout_restore_geometries
                    .entry(window.clone())
                    .or_insert(geometry);
            }
            let anchor = previous_by_output.insert(output, window.clone());
            self.window_layout.insert(LayoutInsertion {
                window,
                output,
                anchor,
            });
        }
        self.arrange_layout_windows()
    }

    pub(super) fn arrange_layout_windows(&mut self) -> bool {
        if !self.window_layout.manages_geometry() {
            return false;
        }
        let placements = self.current_layout_placements();

        let mut changed = false;
        for LayoutPlacement {
            window: window_id,
            geometry: frame,
        } in placements
        {
            let window = self.space.elements().find_map(|window| {
                (self.window_root_surface(window).map(|root| root.id()) == Some(window_id.clone()))
                    .then(|| window.clone())
            });
            let Some(window) = window else {
                continue;
            };
            // Fullscreen/maximized windows temporarily overlay their retained
            // tree node. Exiting that state returns them to the next arrangement.
            if self.window_has_constrained_state(&window) {
                continue;
            }
            #[cfg(feature = "flutter")]
            let target = shell_content_geometry(frame, super::shell_draws_server_frame(&window));
            #[cfg(not(feature = "flutter"))]
            let target = frame;
            let previous = self.window_geometry_target(&window);
            if let Some(toplevel) = window.toplevel() {
                let committed_size = window.geometry().size;
                let client_maximized = toplevel_has_state(toplevel, xdg_toplevel::State::Maximized);
                toplevel.with_pending_state(|pending| {
                    pending.states.unset(xdg_toplevel::State::Resizing);
                    pending.states.unset(xdg_toplevel::State::Maximized);
                    pending.size = Some(target.size);
                });
                if toplevel.is_initial_configure_sent()
                    && (client_maximized
                        || layout_resize_required(previous, committed_size, target))
                {
                    // A cached/acked target can already equal `target` while
                    // the client's committed buffer is still the old tile
                    // size. `send_pending_configure` suppresses that state as
                    // unchanged; force a fresh serial for the real resize.
                    toplevel.send_configure();
                }
            } else if let Some(x11) = window.x11_surface()
                && x11.is_maximized()
                && let Err(error) = x11.set_maximized(false)
            {
                warn!(%error, window = x11.window_id(), "could not clear maximize state for tiled X11 window");
            }
            self.set_window_geometry_target(&window, target);
            changed |= previous != target;
        }
        changed
    }

    fn current_layout_placements(&self) -> Vec<LayoutPlacement<ObjectId>> {
        let gap = self.layout_gap();
        self.outputs
            .iter()
            .flat_map(|output| {
                let work_area =
                    self.maximize_work_area(Some(&output.output), output.logical_geometry);
                self.window_layout.arrange(output.id, work_area, gap)
            })
            .collect()
    }

    fn layout_gap(&self) -> i32 {
        if self.work_area.maximize_padding.is_finite() {
            self.work_area.maximize_padding.round().max(0.0) as i32
        } else {
            0
        }
    }

    fn window_for_layout_id(&self, window_id: &ObjectId) -> Option<Window> {
        self.space.elements().find_map(|window| {
            (self.window_root_surface(window).map(|root| root.id()) == Some(window_id.clone()))
                .then(|| window.clone())
        })
    }

    fn restore_stacking_geometries(&mut self) {
        self.window_layout.clear();
        let restores = std::mem::take(&mut self.layout_restore_geometries);
        for (window_id, saved_restore) in restores {
            let window = self.space.elements().find_map(|window| {
                (self.window_root_surface(window).map(|root| root.id()) == Some(window_id.clone()))
                    .then(|| window.clone())
            });
            let Some(window) = window else {
                continue;
            };
            let restore =
                visible_stacking_restore(saved_restore, self.window_geometry_target(&window));
            if self.window_has_constrained_state(&window) {
                self.restore_window_geometries
                    .insert(window_id.clone(), restore);
                #[cfg(feature = "flutter")]
                {
                    if let Some(shell_restore) =
                        self.shell_maximize_restore_geometries.get_mut(&window_id)
                    {
                        *shell_restore = restore;
                    }
                    if let Some(shell_restore) =
                        self.shell_fullscreen_restore_geometries.get_mut(&window_id)
                    {
                        *shell_restore = restore;
                    }
                }
                continue;
            }
            if let Some(toplevel) = window.toplevel() {
                toplevel.with_pending_state(|pending| pending.size = Some(restore.size));
                if toplevel.is_initial_configure_sent() {
                    toplevel.send_pending_configure();
                }
            }
            self.set_window_geometry_target(&window, restore);
        }
    }

    fn restore_detached_window_geometry(&mut self, window: &Window, window_id: &ObjectId) {
        let current = self.window_geometry_target(window);
        let mut restore = self
            .layout_restore_geometries
            .remove(window_id)
            .map(|saved| visible_stacking_restore(saved, current))
            .unwrap_or(current);
        let (minimum, maximum) = self.window_size_constraints(window);
        restore.size = Size::from((
            constrain_dimension(restore.size.w, minimum.w, maximum.w),
            constrain_dimension(restore.size.h, minimum.h, maximum.h),
        ));
        if let Some(toplevel) = window.toplevel() {
            toplevel.with_pending_state(|pending| pending.size = Some(restore.size));
            if toplevel.is_initial_configure_sent() {
                toplevel.send_configure();
            }
        }
        self.set_window_geometry_target(window, restore);
    }

    fn window_layout_eligible(&self, window: &Window) -> bool {
        let Some(root) = self.window_root_surface(window) else {
            return false;
        };
        #[cfg(feature = "flutter")]
        let minimized = self.minimized_windows.contains(&root.id());
        #[cfg(not(feature = "flutter"))]
        let minimized = false;
        let x11 = window.x11_surface();
        let auxiliary = x11.as_ref().is_some_and(|surface| {
            !matches!(surface.window_type(), None | Some(WmWindowType::Normal))
        });
        let override_redirect = x11
            .as_ref()
            .is_some_and(|surface| surface.is_override_redirect());
        let (minimum, maximum) = self.window_size_constraints(window);
        let already_managed = self.window_layout.contains(&root.id());
        LayoutWindowProperties {
            alive: root.is_alive(),
            transient: self.window_has_transient_parent(window),
            auxiliary,
            override_redirect,
            minimized,
            rigid_size: has_rigid_dimension(minimum, maximum),
        }
        .is_tiling_candidate(already_managed)
    }

    fn window_size_constraints(&self, window: &Window) -> (Size<i32, Logical>, Size<i32, Logical>) {
        if let Some(toplevel) = window.toplevel() {
            return with_states(toplevel.wl_surface(), |states| {
                let mut cached = states.cached_state.get::<SurfaceCachedState>();
                let current = cached.current();
                (current.min_size, current.max_size)
            });
        }
        window.x11_surface().map_or_else(
            || (Size::from((0, 0)), Size::from((0, 0))),
            |surface| {
                (
                    surface.min_size().unwrap_or_else(|| Size::from((0, 0))),
                    surface.max_size().unwrap_or_else(|| Size::from((0, 0))),
                )
            },
        )
    }

    fn window_has_constrained_state(&self, window: &Window) -> bool {
        #[cfg(feature = "flutter")]
        {
            let root = self.window_root_surface(window);
            if root.as_ref().is_some_and(|root| {
                let id = root.id();
                self.shell_fullscreen_locks.contains(&id)
                    || self.shell_maximize_restore_geometries.contains_key(&id)
                    || self.exact_window_geometries.contains_key(&id)
            }) {
                return true;
            }
        }
        if let Some(toplevel) = window.toplevel() {
            return toplevel_has_state(toplevel, xdg_toplevel::State::Fullscreen);
        }
        window
            .x11_surface()
            .is_some_and(|surface| surface.is_fullscreen())
    }

    fn stacking_geometry_for_layout(
        &self,
        window: &Window,
        fallback: Rectangle<i32, Logical>,
    ) -> Rectangle<i32, Logical> {
        let Some(root) = self.window_root_surface(window) else {
            return fallback;
        };
        #[cfg(feature = "flutter")]
        if let Some(restore) = self
            .shell_maximize_restore_geometries
            .get(&root.id())
            .or_else(|| self.shell_fullscreen_restore_geometries.get(&root.id()))
            .copied()
        {
            return restore;
        }
        self.restore_window_geometries
            .get(&root.id())
            .copied()
            .unwrap_or(fallback)
    }

    fn focused_layout_window(&self) -> Option<ObjectId> {
        let focus = self.seat.get_keyboard()?.current_focus()?;
        let surface = focus.wl_surface()?;
        let root = self
            .owning_toplevel_surface(&surface)
            .unwrap_or_else(|| surface.into_owned());
        Some(root.id())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct LayoutWindowProperties {
    alive: bool,
    transient: bool,
    auxiliary: bool,
    override_redirect: bool,
    minimized: bool,
    rigid_size: bool,
}

impl LayoutWindowProperties {
    fn is_tiling_candidate(self, already_managed: bool) -> bool {
        self.alive
            && !self.transient
            && !self.auxiliary
            && !self.override_redirect
            && !self.minimized
            // Startup dialogs advertise rigid constraints before enrollment.
            // Once a regular toplevel owns a leaf, later hint churn must not
            // let clients such as Electron escape and re-enter the tree.
            && (!self.rigid_size || already_managed)
    }
}

fn has_rigid_dimension(minimum: Size<i32, Logical>, maximum: Size<i32, Logical>) -> bool {
    let rigid = |minimum: i32, maximum: i32| minimum > 0 && maximum > 0 && maximum <= minimum;
    rigid(minimum.w, maximum.w) || rigid(minimum.h, maximum.h)
}

fn layout_drop_distance(geometry: Rectangle<i32, Logical>, location: Point<i32, Logical>) -> f64 {
    let center_x = f64::from(geometry.loc.x) + f64::from(geometry.size.w) / 2.0;
    let center_y = f64::from(geometry.loc.y) + f64::from(geometry.size.h) / 2.0;
    (center_x - f64::from(location.x)).powi(2) + (center_y - f64::from(location.y)).powi(2)
}

fn has_visible_size(geometry: Rectangle<i32, Logical>) -> bool {
    geometry.size.w > 1 && geometry.size.h > 1
}

fn visible_stacking_restore(
    mut saved: Rectangle<i32, Logical>,
    current: Rectangle<i32, Logical>,
) -> Rectangle<i32, Logical> {
    if !has_visible_size(saved) && has_visible_size(current) {
        // XDG toplevels can enter the layout before their first natural size
        // exists. Keep the intended floating location, but never restore the
        // resulting 0x0 placeholder; the live tile is a safe visible size.
        saved.size = current.size;
    }
    saved
}

fn layout_resize_required(
    previous_target: Rectangle<i32, Logical>,
    committed_size: smithay::utils::Size<i32, Logical>,
    next_target: Rectangle<i32, Logical>,
) -> bool {
    previous_target.size != next_target.size || committed_size != next_target.size
}

#[cfg(test)]
mod tests {
    use smithay::utils::{Point, Size};

    use super::*;

    fn rect(x: i32, y: i32, width: i32, height: i32) -> Rectangle<i32, Logical> {
        Rectangle::new(Point::from((x, y)), Size::from((width, height)))
    }

    #[test]
    fn stacking_restore_keeps_the_location_but_never_restores_an_unknown_size() {
        assert_eq!(
            visible_stacking_restore(rect(80, 60, 0, 0), rect(10, 10, 900, 700)),
            rect(80, 60, 900, 700)
        );
        assert_eq!(
            visible_stacking_restore(rect(80, 60, 640, 480), rect(10, 10, 900, 700)),
            rect(80, 60, 640, 480)
        );
    }

    #[test]
    fn layout_resize_uses_committed_client_size_even_when_the_target_cache_is_current() {
        let target = rect(400, 0, 800, 900);
        assert!(layout_resize_required(
            target,
            Size::from((600, 900)),
            target
        ));
        assert!(!layout_resize_required(
            rect(20, 30, 800, 900),
            Size::from((800, 900)),
            target
        ));
    }

    #[test]
    fn fixed_size_or_auxiliary_windows_stay_outside_managed_layouts() {
        let regular = LayoutWindowProperties {
            alive: true,
            transient: false,
            auxiliary: false,
            override_redirect: false,
            minimized: false,
            rigid_size: false,
        };
        assert!(regular.is_tiling_candidate(false));
        assert!(
            !LayoutWindowProperties {
                rigid_size: true,
                ..regular
            }
            .is_tiling_candidate(false)
        );
        assert!(
            LayoutWindowProperties {
                rigid_size: true,
                ..regular
            }
            .is_tiling_candidate(true)
        );
        assert!(
            !LayoutWindowProperties {
                auxiliary: true,
                ..regular
            }
            .is_tiling_candidate(false)
        );
        assert!(
            !LayoutWindowProperties {
                transient: true,
                ..regular
            }
            .is_tiling_candidate(false)
        );

        assert!(has_rigid_dimension(
            Size::from((420, 300)),
            Size::from((420, 300))
        ));
        assert!(has_rigid_dimension(
            Size::from((420, 0)),
            Size::from((400, 0))
        ));
        assert!(!has_rigid_dimension(
            Size::from((320, 200)),
            Size::from((0, 1200))
        ));
    }
}
