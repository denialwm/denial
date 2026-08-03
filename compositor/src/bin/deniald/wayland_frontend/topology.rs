use std::error::Error;

use denial_core::topology::{
    AtlasPlan, LogicalRect, OutputId, OutputSpec, OutputTransform, TopologySnapshot,
};
use smithay::backend::renderer::damage::OutputDamageTracker;
use smithay::desktop::Window;
use smithay::output::{Mode, Output, PhysicalProperties, Scale, Subpixel};
use smithay::reexports::wayland_protocols::xdg::shell::server::xdg_toplevel;
use smithay::reexports::wayland_server::Resource;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::utils::{Logical, Point, Rectangle, Size, Transform};
use tracing::info;

#[cfg(feature = "flutter")]
use super::shm_cache_budget_for_atlas;
use super::window_management::toplevel_has_state;
use super::{RuntimeState, WaylandFrontend, WaylandOutput};

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

    /// `geometry` minus the shell system-bar strip when the given output (or,
    /// with `output` unknown, the output whose logical rect equals `geometry`)
    /// hosts the bar, and minus the configured maximize padding on every
    /// bar-free edge. Mirrors the Dart shell's `DisplayLayout.workAreaOf`
    /// so a client-requested maximize configure lands on the same rect the
    /// shell places maximized windows into. True fullscreen keeps the full
    /// output geometry and must not call this.
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
        self.work_area = work_area;
    }

    pub fn update_topology(&mut self, snapshot: &TopologySnapshot) -> Result<(), Box<dyn Error>> {
        self.ticker_output = snapshot.ticker;
        let desktop_bounds = logical_bounds(snapshot)?;
        let atlas = AtlasPlan::for_snapshot(snapshot).ok_or("Wayland topology has no atlas")?;
        // A queued request identifies pixels in the old atlas. Never let it
        // read from a replacement allocation after a hotplug transaction.
        self.fail_all_screencopies();
        let old_output_geometries = self
            .outputs
            .iter()
            .map(|entry| (entry.id, entry.logical_geometry))
            .collect::<Vec<_>>();
        let window_records = self
            .space
            .elements()
            .filter_map(|window| {
                let root_surface = self.window_root_surface(window)?;
                let (fullscreen, maximized) = if let Some(toplevel) = window.toplevel() {
                    (
                        toplevel_has_state(toplevel, xdg_toplevel::State::Fullscreen),
                        toplevel_has_state(toplevel, xdg_toplevel::State::Maximized),
                    )
                } else if let Some(x11) = window.x11_surface() {
                    (x11.is_fullscreen(), x11.is_maximized())
                } else {
                    (false, false)
                };
                Some(WindowTopologyRecord {
                    window: window.clone(),
                    root_surface: root_surface.clone(),
                    geometry: self.window_geometry_target(window),
                    restore_geometry: self
                        .restore_window_geometries
                        .get(&root_surface.id())
                        .copied(),
                    fullscreen,
                    maximized,
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
            self.fail_screencopies_for_output(removed_id);
            let removed = self.outputs.swap_remove(index);
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
            let capture_source = Rectangle::new(
                (
                    i32::try_from(capture.source_rect.x)?,
                    i32::try_from(capture.source_rect.y)?,
                )
                    .into(),
                (
                    i32::try_from(capture.source_rect.width)?,
                    i32::try_from(capture.source_rect.height)?,
                )
                    .into(),
            );
            let capture_size = Size::from((
                i32::try_from(capture.scanout_size.width)?,
                i32::try_from(capture.scanout_size.height)?,
            ));
            if let Some(existing) = self.outputs.iter_mut().find(|entry| entry.id == spec.id) {
                configure_output(&existing.output, spec)?;
                self.space
                    .map_output(&existing.output, (spec.position.x, spec.position.y));
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
                output,
                global,
                logical_geometry: output_logical_bounds(spec),
                capture_source,
                capture_size,
                powered: true,
                #[cfg(feature = "flutter")]
                presentation_batch: super::presentation::OutputPresentationBatch::new(),
                #[cfg(feature = "flutter")]
                submitted_this_batch: false,
            });
        }
        self.outputs.sort_by_key(|entry| entry.id);

        let new_output_geometries = self
            .outputs
            .iter()
            .map(|entry| (entry.id, entry.logical_geometry))
            .collect::<Vec<_>>();
        let mut migrated_windows = 0usize;
        for record in window_records {
            let surface_id = record.root_surface.id();
            if let Some(restore) = record.restore_geometry {
                let restore = migrate_window_geometry(
                    restore,
                    &old_output_geometries,
                    &new_output_geometries,
                );
                self.restore_window_geometries
                    .insert(surface_id.clone(), restore);
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
            self.set_window_geometry_target(&record.window, target);
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
        #[cfg(feature = "flutter")]
        self.rebuild_window_output_membership();
        self.space.refresh();
        info!(
            epoch = snapshot.epoch,
            outputs = self.outputs.len(),
            migrated_windows,
            atlas_width = atlas.pixel_size.width,
            atlas_height = atlas.pixel_size.height,
            "updated live Wayland topology"
        );
        Ok(())
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
    fn output_score_prefers_center_then_overlap_then_distance_stably() {
        let baseline = OutputCandidateScore {
            contains_center: false,
            overlap: 100,
            distance: 50,
        };
        assert!(output_candidate_is_better(
            OutputCandidateScore {
                contains_center: true,
                overlap: 1,
                distance: 500,
            },
            baseline,
        ));
        assert!(output_candidate_is_better(
            OutputCandidateScore {
                overlap: 101,
                ..baseline
            },
            baseline,
        ));
        assert!(output_candidate_is_better(
            OutputCandidateScore {
                distance: 49,
                ..baseline
            },
            baseline,
        ));
        assert!(!output_candidate_is_better(baseline, baseline));
    }

    #[test]
    fn popup_anchor_selects_the_monitor_it_belongs_to() {
        let left = Rectangle::new((0, 0).into(), (1920, 1080).into());
        let right = Rectangle::new((1920, 0).into(), (2560, 1440).into());
        let desired = Rectangle::new((1800, 100).into(), (400, 300).into());

        assert_eq!(
            choose_popup_output([left, right], (2000, 200).into(), desired),
            Some(right),
        );
    }

    #[test]
    fn popup_without_an_on_screen_anchor_prefers_visible_overlap() {
        let left = Rectangle::new((0, 0).into(), (1920, 1080).into());
        let right = Rectangle::new((1920, 0).into(), (2560, 1440).into());
        let desired = Rectangle::new((2100, 100).into(), (400, 300).into());

        assert_eq!(
            choose_popup_output([left, right], (-100, -100).into(), desired),
            Some(right),
        );
    }

    #[test]
    fn popup_output_distance_saturates_for_extreme_client_coordinates() {
        let output = Rectangle::new((0, 0).into(), (1920, 1080).into());
        assert_eq!(
            point_distance_squared(output, Point::from((i32::MIN, i32::MIN))),
            i64::MAX
        );
        let positive_extreme = point_distance_squared(output, Point::from((i32::MAX, i32::MAX)));
        assert!(positive_extreme > 0);
        assert!(positive_extreme < i64::MAX);
    }

    #[test]
    fn moves_a_window_from_a_removed_output_onto_a_survivor() {
        let left = Rectangle::new((0, 0).into(), (1920, 1080).into());
        let right = Rectangle::new((1920, 0).into(), (2560, 1440).into());
        let window = Rectangle::new((2200, 120).into(), (800, 600).into());

        assert_eq!(
            migrate_window_geometry(
                window,
                &[(OutputId(1), left), (OutputId(2), right)],
                &[(OutputId(1), left)],
            ),
            Rectangle::new((280, 120).into(), (800, 600).into()),
        );
    }

    #[test]
    fn extreme_window_coordinates_do_not_overflow_monitor_selection_or_migration() {
        let old = Rectangle::new((i32::MIN, i32::MIN).into(), (1920, 1080).into());
        let destination = Rectangle::new(
            (i32::MAX - 1919, i32::MAX - 1079).into(),
            (1920, 1080).into(),
        );
        let window = Rectangle::new((i32::MIN, i32::MIN).into(), (i32::MAX, i32::MAX).into());

        assert_eq!(
            choose_output_geometry(&[(OutputId(1), old)], window).map(|candidate| candidate.0),
            Some(OutputId(1))
        );
        assert_eq!(
            migrate_window_geometry(window, &[(OutputId(1), old)], &[(OutputId(1), destination)],)
                .loc,
            destination.loc
        );
    }
}
