use std::error::Error;

use denial_core::topology::{
    AtlasPlan, LogicalRect, OutputId, OutputSpec, OutputTransform, TopologySnapshot,
};
use smithay::backend::renderer::damage::OutputDamageTracker;
use smithay::desktop::{Window, layer_map_for_output};
use smithay::output::{Mode, Output, PhysicalProperties, Scale, Subpixel};
use smithay::reexports::wayland_server::Resource;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::utils::{Logical, Point, Rectangle, Size, Transform};
use tracing::info;

use super::managed_window::{ClientWindowState, ManagedWindow};
#[cfg(feature = "flutter")]
use super::shm_cache_budget_for_atlas;
use super::{RuntimeState, WaylandFrontend, WaylandOutput};

#[cfg(feature = "flutter")]
#[derive(Debug, Default)]
pub(crate) struct TopologyWindowReconciliation {
    pub(super) layout_membership_changed: bool,
    pub(super) windows_to_minimize: Vec<u64>,
}

#[cfg(feature = "flutter")]
pub(crate) type TopologyUpdate = TopologyWindowReconciliation;
#[cfg(not(feature = "flutter"))]
pub(super) type TopologyUpdate = ();

#[cfg(feature = "flutter")]
fn windows_on_retired_outputs(
    registry: &super::window_registry::WindowRegistry,
    retained_outputs: &std::collections::HashSet<OutputId>,
) -> Vec<u64> {
    let mut windows = registry
        .iter()
        .filter_map(|(id, record)| {
            (!record.minimized
                && record
                    .workspace
                    .is_some_and(|location| !retained_outputs.contains(&location.output)))
            .then_some(id.get())
        })
        .collect::<Vec<_>>();
    windows.sort_unstable();
    windows
}

struct WindowTopologyRecord {
    window: Window,
    root_surface: WlSurface,
    geometry: Rectangle<i32, Logical>,
    restore_geometry: Option<Rectangle<i32, Logical>>,
    fullscreen: bool,
    maximized: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct OutputCandidateScore {
    contains_center: bool,
    overlap: i64,
    distance: i64,
}

fn output_candidate_is_better(candidate: OutputCandidateScore, best: OutputCandidateScore) -> bool {
    (candidate.contains_center && !best.contains_center)
        || (candidate.contains_center == best.contains_center
            && (candidate.overlap > best.overlap
                || (candidate.overlap == best.overlap && candidate.distance < best.distance)))
}

fn output_membership_changed(
    previous: &[(OutputId, Rectangle<i32, Logical>)],
    current: &[(OutputId, Rectangle<i32, Logical>)],
) -> bool {
    previous.len() != current.len()
        || previous
            .iter()
            .any(|(id, _)| !current.iter().any(|(candidate, _)| candidate == id))
}

impl WaylandFrontend {
    pub(super) fn output_index_for_geometry(
        &self,
        geometry: Rectangle<i32, Logical>,
    ) -> Option<usize> {
        let center = rectangle_center(geometry);
        let mut best: Option<(usize, OutputCandidateScore)> = None;
        for (index, entry) in self.outputs.iter().enumerate() {
            let output_geometry = entry.logical_geometry;
            let score = OutputCandidateScore {
                contains_center: output_geometry.contains(center),
                overlap: popup_overlap_area(output_geometry, geometry),
                distance: point_distance_squared(output_geometry, center),
            };
            let replace =
                best.is_none_or(|(_, best_score)| output_candidate_is_better(score, best_score));
            if replace {
                best = Some((index, score));
            }
        }
        best.map(|(index, _)| index)
    }

    pub(super) fn output_for_geometry(
        &self,
        geometry: Rectangle<i32, Logical>,
    ) -> Option<&WaylandOutput> {
        self.output_index_for_geometry(geometry)
            .map(|index| &self.outputs[index])
    }

    /// The inset working area used by ordinary managed layouts and legacy
    /// shell-owned maximize. The system bar consumes its edge; configured
    /// layout padding consumes every bar-free edge.
    pub(super) fn maximize_work_area(
        &self,
        output: Option<&Output>,
        geometry: Rectangle<i32, Logical>,
    ) -> Rectangle<i32, Logical> {
        use crate::options::SystemBarSide;
        let bar = &self.work_area.system_bar;
        // Every present configured connector hosts its own bar. If the
        // configuration is automatic, or all named connectors are currently
        // unplugged, the bar follows the render ticker output so it never
        // disappears during hotplug.
        let has_configured_host = self
            .outputs
            .iter()
            .any(|entry| bar.outputs.contains(&entry.connector));
        let hosts_bar = bar.side != SystemBarSide::Hidden
            && bar.thickness > 0.0
            && self.outputs.iter().any(|entry| {
                let configured = has_configured_host && bar.outputs.contains(&entry.connector);
                let automatic = !has_configured_host && Some(entry.id) == self.ticker_output;
                (configured || automatic)
                    && match output {
                        Some(output) => entry.output == *output,
                        None => entry.logical_geometry == geometry,
                    }
            });
        let bar_side = hosts_bar.then_some(bar.side);
        let padding = self.work_area.maximize_padding;
        let padding = if padding.is_finite() {
            (padding.ceil() as i32).max(0)
        } else {
            0
        };
        let bar_thickness = (bar.thickness.ceil() as i32).max(0);
        let inset = |side: SystemBarSide| {
            if bar_side == Some(side) {
                bar_thickness
            } else {
                padding
            }
        };
        let mut top = inset(SystemBarSide::Top);
        let mut bottom = inset(SystemBarSide::Bottom);
        let mut left = inset(SystemBarSide::Left);
        let mut right = inset(SystemBarSide::Right);
        // Misconfigured insets must never consume the whole output.
        let height_budget = (geometry.size.h - 1).max(0);
        top = top.min(height_budget);
        bottom = bottom.min(height_budget - top);
        let width_budget = (geometry.size.w - 1).max(0);
        left = left.min(width_budget);
        right = right.min(width_budget - left);
        let mut area = geometry;
        area.loc.x += left;
        area.loc.y += top;
        area.size.w -= left + right;
        area.size.h -= top + bottom;
        area
    }

    pub(crate) fn set_work_area(&mut self, work_area: crate::options::WorkAreaOptions) {
        if self.work_area == work_area {
            return;
        }
        self.work_area = work_area;
        self.arrange_layout_windows();
    }

    pub fn update_topology(
        &mut self,
        snapshot: &TopologySnapshot,
    ) -> Result<TopologyUpdate, Box<dyn Error>> {
        // Geometry, mode, transform, and output membership all invalidate the
        // meaning of outstanding exact frame opportunities as one operation.
        #[cfg(feature = "flutter")]
        self.invalidate_frame_timeline();
        self.ticker_output = snapshot.ticker;
        let desktop_bounds = logical_bounds(snapshot)?;
        let atlas = AtlasPlan::for_snapshot(snapshot).ok_or("Wayland topology has no atlas")?;
        let xwayland_scale_changed = self.set_xwayland_scale(atlas.engine_scale_120)?;
        // A queued request identifies pixels in the old atlas. Never let it
        // read from a replacement allocation after a hotplug transaction.
        self.fail_all_screencopies();
        let old_output_geometries = self
            .outputs
            .iter()
            .map(|entry| (entry.id, entry.logical_geometry))
            .collect::<Vec<_>>();
        #[cfg(feature = "flutter")]
        let windows_to_minimize = {
            let retained_outputs = snapshot
                .outputs
                .iter()
                .map(|output| output.id)
                .collect::<std::collections::HashSet<_>>();
            windows_on_retired_outputs(&self.window_registry, &retained_outputs)
        };
        let window_records = self
            .space
            .elements()
            .filter_map(|window| {
                let root_surface = self.window_root_surface(window)?;
                let client = ManagedWindow::new(window)
                    .map(|window| window.facts().client_state)
                    .unwrap_or_else(ClientWindowState::default);
                Some(WindowTopologyRecord {
                    window: window.clone(),
                    root_surface: root_surface.clone(),
                    geometry: self.window_geometry_target(window),
                    restore_geometry: self
                        .window_record_for_surface(&root_surface.id())
                        .and_then(|record| record.restore_geometry),
                    fullscreen: client.fullscreen,
                    maximized: client.maximized,
                })
            })
            .collect::<Vec<_>>();

        let mut index = 0;
        while index < self.outputs.len() {
            let current = &self.outputs[index];
            let retained = snapshot
                .outputs
                .iter()
                .any(|spec| spec.id == current.id && spec.name == current.connector);
            if retained {
                index += 1;
                continue;
            }

            let removed_id = current.id;
            self.fail_output_power(removed_id);
            self.gamma_control_failed(removed_id);
            self.fail_screencopies_for_output(removed_id);
            let removed = self.outputs.swap_remove(index);
            {
                let mut map = layer_map_for_output(&removed.output);
                let layers = map.layers().cloned().collect::<Vec<_>>();
                for layer in layers {
                    map.unmap_layer(&layer);
                    layer.layer_surface().send_close();
                }
            }
            removed.output.leave_all();
            self.space.unmap_output(&removed.output);
            self.display_handle
                .remove_global::<RuntimeState>(removed.global);
            info!(output = removed.output.name(), "removed Wayland output");
        }

        for spec in &snapshot.outputs {
            let capture = atlas
                .outputs
                .iter()
                .find(|output| output.id == spec.id)
                .ok_or("Wayland output is missing from the atlas plan")?;
            let capture_size = Size::from((
                i32::try_from(capture.pixel_size.width)?,
                i32::try_from(capture.pixel_size.height)?,
            ));
            let capture_source = Rectangle::from_size(capture_size);
            if let Some(existing) = self.outputs.iter_mut().find(|entry| entry.id == spec.id) {
                configure_output(&existing.output, spec)?;
                self.space
                    .map_output(&existing.output, (spec.position.x, spec.position.y));
                existing.transform = spec.transform;
                existing.logical_geometry = output_logical_bounds(spec);
                existing.capture_source = capture_source;
                existing.capture_size = capture_size;
                continue;
            }

            let output = Output::new(
                spec.name.clone(),
                PhysicalProperties {
                    size: (0, 0).into(),
                    subpixel: Subpixel::Unknown,
                    make: "Denial".into(),
                    model: spec.name.clone(),
                    serial_number: format!("connector-{}", spec.id.0),
                },
            );
            configure_output(&output, spec)?;
            let global = output.create_global::<RuntimeState>(&self.display_handle);
            self.space
                .map_output(&output, (spec.position.x, spec.position.y));
            info!(output = spec.name, "added Wayland output");
            self.outputs.push(WaylandOutput {
                id: spec.id,
                connector: spec.name.clone(),
                transform: spec.transform,
                output,
                global,
                logical_geometry: output_logical_bounds(spec),
                capture_source,
                capture_size,
                powered: true,
            });
        }
        self.outputs.sort_by_key(|entry| entry.id);
        for output in &self.outputs {
            layer_map_for_output(&output.output).arrange();
        }
        #[cfg(feature = "flutter")]
        self.reconcile_workspace_outputs();

        let new_output_geometries = self
            .outputs
            .iter()
            .map(|entry| (entry.id, entry.logical_geometry))
            .collect::<Vec<_>>();
        let layout_membership_changed =
            output_membership_changed(&old_output_geometries, &new_output_geometries);
        let mut migrated_windows = 0usize;
        for record in window_records {
            let surface_id = record.root_surface.id();
            if let Some(restore) = record.restore_geometry {
                let restore = migrate_window_geometry(
                    restore,
                    &old_output_geometries,
                    &new_output_geometries,
                );
                self.ensure_window_record_for_surface(&surface_id)
                    .expect("managed window has no stable id")
                    .restore_geometry = Some(restore);
            }

            let target = if record.fullscreen || record.maximized {
                let previous_output =
                    choose_output_geometry(&old_output_geometries, record.geometry)
                        .map(|(id, _)| id);
                previous_output
                    .and_then(|id| {
                        new_output_geometries
                            .iter()
                            .find(|(candidate, _)| *candidate == id)
                            .map(|(_, geometry)| *geometry)
                    })
                    .or_else(|| {
                        choose_output_geometry(&new_output_geometries, record.geometry)
                            .map(|(_, geometry)| geometry)
                    })
                    .unwrap_or(record.geometry)
            } else {
                migrate_window_geometry(
                    record.geometry,
                    &old_output_geometries,
                    &new_output_geometries,
                )
            };
            if target == record.geometry {
                continue;
            }

            if (target.size != record.geometry.size || record.fullscreen || record.maximized)
                && let Some(toplevel) = record.window.toplevel()
            {
                toplevel.with_pending_state(|pending| {
                    pending.size = Some(target.size);
                    if record.fullscreen {
                        pending.fullscreen_output = None;
                    }
                });
                if toplevel.is_initial_configure_sent() {
                    toplevel.send_configure();
                } else {
                    toplevel.send_pending_configure();
                }
            }
            self.set_window_geometry_target_preserving_authority(&record.window, target);
            migrated_windows += 1;
        }

        let atlas_mode = Mode {
            size: (
                i32::try_from(atlas.pixel_size.width)?,
                i32::try_from(atlas.pixel_size.height)?,
            )
                .into(),
            refresh: snapshot
                .outputs
                .iter()
                .map(|output| output.refresh_millihz)
                .max()
                .map(i32::try_from)
                .transpose()?
                .unwrap_or(60_000),
        };
        for mode in self.atlas_output.modes() {
            if mode != atlas_mode {
                self.atlas_output.delete_mode(mode);
            }
        }
        self.atlas_output.change_current_state(
            Some(atlas_mode),
            Some(Transform::Normal),
            Some(Scale::Fractional(
                atlas.engine_scale_120 as f64 / denial_core::topology::SCALE_BASE as f64,
            )),
            Some(
                (
                    atlas.logical_origin.0.round() as i32,
                    atlas.logical_origin.1.round() as i32,
                )
                    .into(),
            ),
        );
        self.atlas_output.set_preferred(atlas_mode);
        self.space.map_output(
            &self.atlas_output,
            (
                atlas.logical_origin.0.round() as i32,
                atlas.logical_origin.1.round() as i32,
            ),
        );
        self.damage_tracker = OutputDamageTracker::from_output(&self.atlas_output);
        self.desktop_bounds = desktop_bounds;
        self.touch_bounds = snapshot
            .outputs
            .first()
            .map(output_logical_bounds)
            .unwrap_or(desktop_bounds);
        self.touch_transform = snapshot
            .outputs
            .first()
            .map(|output| output.transform)
            .unwrap_or(OutputTransform::Normal);
        self.atlas_origin = Point::from(atlas.logical_origin);
        self.atlas_scale = atlas.engine_scale_120 as f64 / denial_core::topology::SCALE_BASE as f64;
        self.atlas_size = Size::from((
            i32::try_from(atlas.pixel_size.width)?,
            i32::try_from(atlas.pixel_size.height)?,
        ));
        #[cfg(feature = "flutter")]
        {
            self.shm_snapshot_budget_bytes =
                shm_cache_budget_for_atlas(atlas.pixel_size.width, atlas.pixel_size.height);
        }
        self.pointer_location = self.clamp_pointer(self.pointer_location);
        self.rebuild_window_output_membership();
        if xwayland_scale_changed {
            self.reconfigure_x11_for_scale()?;
        }
        if !layout_membership_changed {
            // Rotation, scale, position, and mode changes leave every layout
            // leaf in the same output/workspace. Preserve the layout's tree,
            // ratios, ordering, maximized leaf, and scrolling viewport; only
            // arrange that model inside the new work areas.
            self.arrange_layout_windows();
        }
        #[cfg(not(feature = "flutter"))]
        if layout_membership_changed {
            self.rebuild_window_layout();
        }
        self.space.refresh();
        self.refresh_image_copy_constraints();
        info!(
            epoch = snapshot.epoch,
            outputs = self.outputs.len(),
            migrated_windows,
            atlas_width = atlas.pixel_size.width,
            atlas_height = atlas.pixel_size.height,
            "updated live Wayland topology"
        );
        #[cfg(feature = "flutter")]
        {
            Ok(TopologyWindowReconciliation {
                layout_membership_changed,
                windows_to_minimize,
            })
        }
        #[cfg(not(feature = "flutter"))]
        {
            Ok(())
        }
    }
}

pub(super) fn choose_popup_output(
    outputs: impl IntoIterator<Item = Rectangle<i32, Logical>>,
    anchor: Point<i32, Logical>,
    desired: Rectangle<i32, Logical>,
) -> Option<Rectangle<i32, Logical>> {
    let outputs = outputs.into_iter().collect::<Vec<_>>();
    outputs
        .iter()
        .copied()
        .filter(|geometry| geometry.contains(anchor))
        .max_by_key(|geometry| popup_overlap_area(*geometry, desired))
        .or_else(|| {
            outputs
                .iter()
                .copied()
                .max_by_key(|geometry| popup_overlap_area(*geometry, desired))
                .filter(|geometry| popup_overlap_area(*geometry, desired) > 0)
        })
        .or_else(|| {
            outputs
                .into_iter()
                .min_by_key(|geometry| point_distance_squared(*geometry, anchor))
        })
}

pub(super) fn popup_overlap_area(
    output: Rectangle<i32, Logical>,
    desired: Rectangle<i32, Logical>,
) -> i64 {
    output.intersection(desired).map_or(0, |overlap| {
        i64::from(overlap.size.w) * i64::from(overlap.size.h)
    })
}

fn point_distance_squared(geometry: Rectangle<i32, Logical>, point: Point<i32, Logical>) -> i64 {
    let left = i64::from(geometry.loc.x);
    let top = i64::from(geometry.loc.y);
    let right = left.saturating_add(i64::from(geometry.size.w));
    let bottom = top.saturating_add(i64::from(geometry.size.h));
    let point_x = i64::from(point.x);
    let point_y = i64::from(point.y);
    let dx = if point_x < left {
        left - point_x
    } else if point_x > right {
        point_x - right
    } else {
        0
    };
    let dy = if point_y < top {
        top - point_y
    } else if point_y > bottom {
        point_y - bottom
    } else {
        0
    };
    dx.saturating_mul(dx).saturating_add(dy.saturating_mul(dy))
}

pub(crate) fn saturating_point_add(
    left: Point<i32, Logical>,
    right: Point<i32, Logical>,
) -> Point<i32, Logical> {
    Point::from((
        left.x.saturating_add(right.x),
        left.y.saturating_add(right.y),
    ))
}

pub(super) fn saturating_point_sub(
    left: Point<i32, Logical>,
    right: Point<i32, Logical>,
) -> Point<i32, Logical> {
    Point::from((
        left.x.saturating_sub(right.x),
        left.y.saturating_sub(right.y),
    ))
}

fn rectangle_center(geometry: Rectangle<i32, Logical>) -> Point<i32, Logical> {
    saturating_point_add(
        geometry.loc,
        Point::from((geometry.size.w / 2, geometry.size.h / 2)),
    )
}

fn migrate_point_between_origins(
    point: Point<i32, Logical>,
    old_origin: Point<i32, Logical>,
    new_origin: Point<i32, Logical>,
) -> Point<i32, Logical> {
    fn migrate_axis(point: i32, old_origin: i32, new_origin: i32) -> i32 {
        (i64::from(new_origin) + i64::from(point) - i64::from(old_origin))
            .clamp(i64::from(i32::MIN), i64::from(i32::MAX)) as i32
    }

    Point::from((
        migrate_axis(point.x, old_origin.x, new_origin.x),
        migrate_axis(point.y, old_origin.y, new_origin.y),
    ))
}

pub(super) fn choose_output_geometry(
    outputs: &[(OutputId, Rectangle<i32, Logical>)],
    desired: Rectangle<i32, Logical>,
) -> Option<(OutputId, Rectangle<i32, Logical>)> {
    #[derive(Clone, Copy)]
    struct Candidate {
        id: OutputId,
        geometry: Rectangle<i32, Logical>,
        score: OutputCandidateScore,
    }

    let center = rectangle_center(desired);
    let mut best: Option<Candidate> = None;
    for (id, geometry) in outputs.iter().copied() {
        let score = OutputCandidateScore {
            contains_center: geometry.contains(center),
            overlap: popup_overlap_area(geometry, desired),
            distance: point_distance_squared(geometry, center),
        };
        let replace = best.is_none_or(|best| output_candidate_is_better(score, best.score));
        if replace {
            best = Some(Candidate {
                id,
                geometry,
                score,
            });
        }
    }
    best.map(|candidate| (candidate.id, candidate.geometry))
}

pub(super) fn clamp_window_geometry(
    geometry: Rectangle<i32, Logical>,
    output: Rectangle<i32, Logical>,
) -> Rectangle<i32, Logical> {
    let maximum_x = if geometry.size.w >= output.size.w {
        output.loc.x
    } else {
        output.loc.x.saturating_add(output.size.w - geometry.size.w)
    };
    let maximum_y = if geometry.size.h >= output.size.h {
        output.loc.y
    } else {
        output.loc.y.saturating_add(output.size.h - geometry.size.h)
    };
    Rectangle::new(
        Point::from((
            geometry.loc.x.clamp(output.loc.x, maximum_x),
            geometry.loc.y.clamp(output.loc.y, maximum_y),
        )),
        geometry.size,
    )
}

/// Centers a client-sized transient over its parent and keeps its origin on
/// the parent's output.
///
/// Oversized clients retain their chosen dimensions and align to the output's
/// leading edge. Size negotiation remains a protocol concern; placement must
/// not silently turn into a resize.
pub(super) fn centered_transient_geometry(
    size: Size<i32, Logical>,
    parent: Rectangle<i32, Logical>,
    output: Rectangle<i32, Logical>,
) -> Rectangle<i32, Logical> {
    let centered = Rectangle::new(
        Point::from((
            parent
                .loc
                .x
                .saturating_add(parent.size.w.saturating_sub(size.w) / 2),
            parent
                .loc
                .y
                .saturating_add(parent.size.h.saturating_sub(size.h) / 2),
        )),
        size,
    );
    clamp_window_geometry(centered, output)
}

pub(super) fn migrate_window_geometry(
    geometry: Rectangle<i32, Logical>,
    old_outputs: &[(OutputId, Rectangle<i32, Logical>)],
    new_outputs: &[(OutputId, Rectangle<i32, Logical>)],
) -> Rectangle<i32, Logical> {
    let old_output = choose_output_geometry(old_outputs, geometry);
    let destination = old_output
        .and_then(|(old_id, _)| {
            new_outputs
                .iter()
                .copied()
                .find(|(new_id, _)| *new_id == old_id)
        })
        .or_else(|| choose_output_geometry(new_outputs, geometry));
    let Some((_, destination)) = destination else {
        return geometry;
    };
    let migrated = if let Some((_, old_output)) = old_output {
        Rectangle::new(
            migrate_point_between_origins(geometry.loc, old_output.loc, destination.loc),
            geometry.size,
        )
    } else {
        geometry
    };
    clamp_window_geometry(migrated, destination)
}

pub(super) fn logical_bounds(
    snapshot: &TopologySnapshot,
) -> Result<Rectangle<i32, Logical>, Box<dyn Error>> {
    let bounds = snapshot.logical_bounds.ok_or("Wayland topology is empty")?;
    Ok(rounded_logical_bounds(bounds))
}

pub(super) fn output_logical_bounds(spec: &OutputSpec) -> Rectangle<i32, Logical> {
    rounded_logical_bounds(spec.logical_rect())
}

fn rounded_logical_bounds(bounds: LogicalRect) -> Rectangle<i32, Logical> {
    Rectangle::new(
        (bounds.x.round() as i32, bounds.y.round() as i32).into(),
        (
            bounds.width.round().max(1.0) as i32,
            bounds.height.round().max(1.0) as i32,
        )
            .into(),
    )
}

pub(super) fn configure_output(output: &Output, spec: &OutputSpec) -> Result<(), Box<dyn Error>> {
    let mode = Mode {
        size: (
            i32::try_from(spec.mode.width)?,
            i32::try_from(spec.mode.height)?,
        )
            .into(),
        refresh: i32::try_from(spec.refresh_millihz)?,
    };
    for previous in output.modes() {
        if previous != mode {
            output.delete_mode(previous);
        }
    }
    output.change_current_state(
        Some(mode),
        Some(output_transform(spec.transform)),
        Some(Scale::Fractional(
            spec.scale_120 as f64 / denial_core::topology::SCALE_BASE as f64,
        )),
        Some((spec.position.x, spec.position.y).into()),
    );
    output.set_preferred(mode);
    Ok(())
}

fn output_transform(transform: OutputTransform) -> Transform {
    match transform {
        OutputTransform::Normal => Transform::Normal,
        OutputTransform::Rotate90 => Transform::_90,
        OutputTransform::Rotate180 => Transform::_180,
        OutputTransform::Rotate270 => Transform::_270,
        OutputTransform::Flipped => Transform::Flipped,
        OutputTransform::Flipped90 => Transform::Flipped90,
        OutputTransform::Flipped180 => Transform::Flipped180,
        OutputTransform::Flipped270 => Transform::Flipped270,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transient_geometry_centers_over_parent() {
        let output = Rectangle::new((0, 0).into(), (1920, 1080).into());
        let parent = Rectangle::new((100, 50).into(), (800, 600).into());

        assert_eq!(
            centered_transient_geometry((300, 200).into(), parent, output),
            Rectangle::new((350, 250).into(), (300, 200).into()),
        );
    }

    #[test]
    fn transient_geometry_follows_parent_resize() {
        let output = Rectangle::new((0, 0).into(), (1920, 1080).into());
        let resized_parent = Rectangle::new((100, 50).into(), (1200, 800).into());

        assert_eq!(
            centered_transient_geometry((300, 200).into(), resized_parent, output),
            Rectangle::new((550, 350).into(), (300, 200).into()),
        );
    }

    #[test]
    fn transient_geometry_stays_on_parent_output() {
        let output = Rectangle::new((0, 0).into(), (1920, 1080).into());
        let parent = Rectangle::new((1800, 900).into(), (400, 300).into());

        assert_eq!(
            centered_transient_geometry((500, 400).into(), parent, output),
            Rectangle::new((1420, 680).into(), (500, 400).into()),
        );
    }

    #[test]
    fn oversized_transient_keeps_client_size() {
        let output = Rectangle::new((100, 200).into(), (1920, 1080).into());
        let parent = Rectangle::new((400, 500).into(), (800, 600).into());

        assert_eq!(
            centered_transient_geometry((2200, 1200).into(), parent, output),
            Rectangle::new((100, 200).into(), (2200, 1200).into()),
        );
    }

    #[test]
    fn output_geometry_changes_preserve_layout_membership() {
        let before = [
            (
                OutputId(1),
                Rectangle::new((0, 0).into(), (1920, 1080).into()),
            ),
            (
                OutputId(2),
                Rectangle::new((1920, 0).into(), (2560, 1440).into()),
            ),
        ];
        let rotated = [
            (
                OutputId(1),
                Rectangle::new((0, 0).into(), (1080, 1920).into()),
            ),
            (
                OutputId(2),
                Rectangle::new((1080, 0).into(), (2560, 1440).into()),
            ),
        ];

        assert!(!output_membership_changed(&before, &rotated));
    }

    #[test]
    fn output_replacement_changes_layout_membership() {
        let before = [(
            OutputId(1),
            Rectangle::new((0, 0).into(), (1920, 1080).into()),
        )];
        let replaced = [(
            OutputId(2),
            Rectangle::new((0, 0).into(), (1920, 1080).into()),
        )];

        assert!(output_membership_changed(&before, &replaced));
    }

    #[cfg(feature = "flutter")]
    #[test]
    fn retired_outputs_select_every_non_minimized_workspace_window() {
        use std::collections::HashSet;

        use super::super::window_registry::{WindowId, WindowRegistry};
        use super::super::workspace::WorkspaceLocation;

        let mut registry = WindowRegistry::default();
        registry.ensure(WindowId::new(30)).workspace = Some(WorkspaceLocation {
            output: OutputId(2),
            workspace: 3,
        });
        registry.ensure(WindowId::new(10)).workspace = Some(WorkspaceLocation {
            output: OutputId(1),
            workspace: 1,
        });
        registry.ensure(WindowId::new(20)).workspace = Some(WorkspaceLocation {
            output: OutputId(2),
            workspace: 1,
        });
        let minimized = registry.ensure(WindowId::new(40));
        minimized.minimized = true;
        minimized.minimized_output = Some(OutputId(2));

        assert_eq!(
            windows_on_retired_outputs(&registry, &HashSet::from([OutputId(1)])),
            vec![20, 30],
        );
    }
}
