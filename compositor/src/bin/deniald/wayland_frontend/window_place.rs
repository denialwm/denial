//! Window places: where the shell says a window is, as a rule this module
//! turns into pixels.
//!
//! The shell never computes a window's rectangle. It names a place (free at a
//! rectangle, a share of an output's work area, fullscreen, or back to the
//! last free place) and is answered with the rectangle that place gives. The
//! frame the shell draws, the window's size limits, the layout and the work
//! area are applied here and nowhere else, and a share is resolved again when
//! the work area changes.
//!
//! Every request is answered by its own number, also when it is refused, so
//! the shell never has to recognise an echo of its own request by its shape.

use smithay::desktop::Window;
use smithay::reexports::wayland_server::Resource;
use smithay::utils::{Logical, Point, Rectangle, Size};
use tracing::warn;

use super::super::RuntimeState;
use super::super::wire::{
    WindowAction, WindowGeometry, WindowPlace, WindowPlaceResult, WindowPlaceStatus,
    WindowPlacementChange, WindowPlacementPhase,
};
use super::managed_window::ManagedWindow;
use super::window_management::{
    ShellFrame, bound_geometry_size, clear_client_geometry_constraints,
    configure_shell_owned_geometry, configured_window_size,
    queue_client_window_placement_for_monitor, queue_local_flutter_window_placement,
    queue_local_window_action, queue_window_placement_for_monitor, shell_content_geometry,
    shell_frame_geometry, toggle_scrolling_layout_maximize, toggle_shell_fullscreen_window,
    toggle_shell_maximize_window, transfer_shell_restore_between_outputs,
};
use super::window_presentation::{AreaShare, ShellFullscreenExit, ShellWindowPresentation};
use super::{WaylandFrontend, WindowGeometryAuthority};

/// Answers never outnumber the requests one frame can carry by much; past
/// this the shell is flooding and the oldest answers are the stale ones.
const MAX_PENDING_PLACE_RESULTS: usize = 4096;

/// A window's outer rectangle and its content, in global logical pixels.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Placed {
    frame: Rectangle<i32, Logical>,
    content: Rectangle<i32, Logical>,
}

impl Placed {
    fn framed(frame: Rectangle<i32, Logical>, margins: ShellFrame) -> Self {
        Self {
            frame,
            content: shell_content_geometry(frame, margins),
        }
    }

    fn around(content: Rectangle<i32, Logical>, margins: ShellFrame) -> Self {
        Self {
            frame: shell_frame_geometry(content, margins),
            content,
        }
    }
}

/// What a place resolves to before anything is applied.
enum Resolved {
    /// The rule gives exactly this.
    Exact(Placed),
    /// The window's own size limits changed the rule's rectangle to this.
    Limited(Placed),
    /// The layout that owns the window, or the client's own state, decides
    /// the rectangle; it is known only once applied.
    OnceApplied,
    /// The window is already there.
    Unchanged,
    Refused,
}

pub(super) fn place_window(
    state: &mut RuntimeState,
    window_id: u64,
    request_id: u64,
    place: WindowPlace,
    apply: bool,
) {
    let local = state
        .wayland
        .as_ref()
        .is_some_and(|frontend| frontend.is_local_flutter_window(window_id));
    let answer = if local {
        place_local_window(state, window_id, place, apply)
    } else {
        let window = state
            .wayland
            .as_ref()
            .and_then(|frontend| frontend.window_for_id(window_id));
        match window {
            Some(window) => place_client_window(state, &window, place, apply),
            None => {
                warn!(window_id, ?place, "refused a place for a stale window");
                None
            }
        }
    };
    let Some((status, placed)) = answer else {
        refuse_place(state, window_id, request_id);
        return;
    };
    let result = {
        let frontend = state.frontend();
        WindowPlaceResult {
            request_id,
            window_id,
            status,
            frame: scene_geometry(frontend, placed.frame),
            geometry: scene_geometry(frontend, placed.content),
            monitor_id: frontend
                .output_for_geometry(placed.content)
                .and_then(|entry| i64::try_from(entry.id.0).ok())
                .unwrap_or(-1),
        }
    };
    queue_place_result(state, result);
}

/// Answers a request that changed nothing and has no rectangle to report:
/// its window is gone, or the session is locked.
pub(super) fn refuse_place(state: &mut RuntimeState, window_id: u64, request_id: u64) {
    const NOWHERE: WindowGeometry = WindowGeometry {
        x: 0.0,
        y: 0.0,
        width: 0.0,
        height: 0.0,
    };
    queue_place_result(
        state,
        WindowPlaceResult {
            request_id,
            window_id,
            status: WindowPlaceStatus::Refused,
            frame: NOWHERE,
            geometry: NOWHERE,
            monitor_id: -1,
        },
    );
}

fn queue_place_result(state: &mut RuntimeState, result: WindowPlaceResult) {
    let results = &mut state.window_events.place_results;
    if results.len() >= MAX_PENDING_PLACE_RESULTS {
        results.pop_front();
    }
    results.push_back(result);
}

fn scene_geometry(frontend: &WaylandFrontend, geometry: Rectangle<i32, Logical>) -> WindowGeometry {
    WindowGeometry {
        x: f64::from(geometry.loc.x) - frontend.atlas_origin.x,
        y: f64::from(geometry.loc.y) - frontend.atlas_origin.y,
        width: f64::from(geometry.size.w),
        height: f64::from(geometry.size.h),
    }
}

fn global_geometry(
    frontend: &WaylandFrontend,
    geometry: WindowGeometry,
) -> Rectangle<i32, Logical> {
    let coordinate = |value: f64| {
        value
            .round()
            .clamp(f64::from(i32::MIN), f64::from(i32::MAX)) as i32
    };
    Rectangle::new(
        Point::from((
            coordinate(geometry.x + frontend.atlas_origin.x),
            coordinate(geometry.y + frontend.atlas_origin.y),
        )),
        Size::from((
            coordinate(geometry.width).max(1),
            coordinate(geometry.height).max(1),
        )),
    )
}

impl WaylandFrontend {
    /// The work area and the whole rectangle of the output a place names, or
    /// of the one `current` is on.
    fn place_output(
        &self,
        monitor_id: Option<i64>,
        current: Rectangle<i32, Logical>,
    ) -> Option<(Rectangle<i32, Logical>, Rectangle<i32, Logical>)> {
        let entry = match monitor_id {
            Some(monitor_id) => self
                .outputs
                .iter()
                .find(|entry| i64::try_from(entry.id.0).ok() == Some(monitor_id))?,
            None => self.output_for_geometry(current)?,
        };
        Some((
            self.maximize_work_area(Some(&entry.output), entry.logical_geometry),
            entry.logical_geometry,
        ))
    }

    /// Where `window` is now.
    fn window_placed(&self, window: &Window) -> Placed {
        let presentation = self.managed_window_presentation(window);
        let margins = if presentation.fullscreen {
            ShellFrame::NONE
        } else if presentation.maximized {
            self.maximized_frame_for(window)
        } else {
            self.frame_for(window)
        };
        Placed::around(self.window_geometry_target(window), margins)
    }

    fn window_shell_presentation(&self, window: &Window) -> Option<ShellWindowPresentation> {
        let root = self.window_root_surface(window)?;
        self.window_record_for_surface(&root.id())?
            .shell_presentation
    }

    /// The rectangle `place` gives `window`, with nothing applied.
    fn resolve_client_place(&self, window: &Window, place: WindowPlace) -> Resolved {
        let Some(managed) = ManagedWindow::new(window) else {
            return Resolved::Refused;
        };
        let facts = managed.facts();
        // The phone gives every window its whole screen, and an unmanaged
        // X11 window places itself.
        if facts.override_redirect || self.mobile_window_geometry(window).is_some() {
            return Resolved::Refused;
        }
        let layout_managed = self.window_is_layout_managed(window);
        let presentation = self.managed_window_presentation(window);
        let current = self.window_geometry_target(window);
        match place {
            WindowPlace::Free(frame) => {
                // A layout owns the rectangle of every window it tiles.
                if layout_managed || facts.client_state.resizing {
                    return Resolved::Refused;
                }
                let margins = self.frame_for(window);
                let asked = Placed::framed(global_geometry(self, frame), margins);
                let size = configured_window_size(
                    asked.content.size,
                    facts.minimum_size,
                    facts.maximum_size,
                    false,
                );
                if size == asked.content.size {
                    Resolved::Exact(asked)
                } else {
                    Resolved::Limited(Placed::around(
                        Rectangle::new(asked.content.loc, size),
                        margins,
                    ))
                }
            }
            WindowPlace::Area { monitor_id, share } => {
                let share = AreaShare::from_fractions(share.x, share.y, share.width, share.height);
                if share.is_whole() && self.window_is_scrolling_layout_managed(window) {
                    return Resolved::OnceApplied;
                }
                // Only maximize means anything inside a layout.
                if !share.is_whole() && layout_managed {
                    return Resolved::Refused;
                }
                if !presentation.fullscreen && self.window_geometry_locked(window) {
                    return Resolved::Refused;
                }
                let Some((work_area, _)) = self.place_output(monitor_id, current) else {
                    return Resolved::Refused;
                };
                let margins = self.frame_at(window, work_area, share.is_whole());
                Resolved::Exact(Placed::framed(share.of(work_area), margins))
            }
            WindowPlace::Fullscreen { monitor_id } => {
                if !presentation.fullscreen && self.exact_window_geometry(window).is_some() {
                    return Resolved::Refused;
                }
                if presentation.fullscreen {
                    return Resolved::Unchanged;
                }
                // A tiled window goes fullscreen on its tile's output.
                let monitor_id = self
                    .managed_layout_space(window)
                    .and_then(|space| i64::try_from(space.output.0).ok())
                    .or(monitor_id);
                let Some((_, output)) = self.place_output(monitor_id, current) else {
                    return Resolved::Refused;
                };
                Resolved::Exact(Placed::around(output, ShellFrame::NONE))
            }
            WindowPlace::Restore => {
                let shell = self.window_shell_presentation(window);
                let normal = self.frame_for(window);
                if presentation.fullscreen {
                    return match shell.and_then(ShellWindowPresentation::exit_fullscreen) {
                        Some(ShellFullscreenExit::Normal { geometry })
                        | Some(ShellFullscreenExit::Area { geometry, .. }) => {
                            Resolved::Exact(Placed::around(bound_geometry_size(geometry), normal))
                        }
                        Some(ShellFullscreenExit::Maximized { geometry, .. }) => {
                            Resolved::Exact(Placed::around(
                                bound_geometry_size(geometry),
                                self.maximized_frame_for(window),
                            ))
                        }
                        // The client made itself fullscreen; what it returns
                        // to is known once it has left.
                        None => Resolved::OnceApplied,
                    };
                }
                if layout_managed && self.window_is_layout_maximized(window) {
                    return Resolved::OnceApplied;
                }
                match shell {
                    Some(shell) => Resolved::Exact(Placed::around(
                        bound_geometry_size(shell.normal_geometry()),
                        normal,
                    )),
                    None if presentation.maximized => Resolved::OnceApplied,
                    None => Resolved::Unchanged,
                }
            }
        }
    }

    /// Declares the frames the shell draws, on every output or with
    /// `monitor_id` on that one only, and returns whether they changed. The
    /// frames for every output forget those of single outputs, which the
    /// shell declares after them. Every rectangle that depends on a frame is
    /// placed again.
    pub(super) fn set_shell_frames(
        &mut self,
        monitor_id: Option<i64>,
        frames: super::window_management::ShellFrames,
    ) -> bool {
        self.shell_frames_declared = true;
        match monitor_id {
            None => self.apply_shell_frames(frames),
            Some(monitor_id) => {
                if self.output_shell_frames.get(&monitor_id) == Some(&frames) {
                    return false;
                }
                self.output_shell_frames.insert(monitor_id, frames);
                self.arrange_layout_windows();
                self.replace_shell_placed_windows();
                true
            }
        }
    }

    /// Called once a replacement shell is up: one that declared no frame
    /// draws the default one, not its predecessor's.
    pub(in super::super) fn settle_shell_frames(&mut self) -> bool {
        !self.shell_frames_declared
            && self.apply_shell_frames(super::window_management::ShellFrames::default())
    }

    fn apply_shell_frames(&mut self, frames: super::window_management::ShellFrames) -> bool {
        let had_output_frames = !self.output_shell_frames.is_empty();
        self.output_shell_frames.clear();
        if self.shell_frames == frames && !had_output_frames {
            return false;
        }
        self.shell_frames = frames;
        self.arrange_layout_windows();
        self.replace_shell_placed_windows();
        true
    }

    /// Resolves again every window the shell placed by a rule that depends on
    /// the work area or the frame: maximized ones outside a scrolling layout,
    /// and shares of the work area. The scene snapshot carries the result.
    pub(super) fn replace_shell_placed_windows(&mut self) {
        let windows = self.space.elements().cloned().collect::<Vec<_>>();
        for window in windows {
            let Some(shell) = self.window_shell_presentation(&window) else {
                continue;
            };
            if self.mobile_window_geometry(&window).is_some()
                || self.window_is_scrolling_layout_managed(&window)
            {
                continue;
            }
            let (share, margins) = match shell {
                ShellWindowPresentation::Maximized { .. } => (
                    AreaShare::from_fractions(0.0, 0.0, 1.0, 1.0),
                    self.maximized_frame_for(&window),
                ),
                ShellWindowPresentation::Area { share, .. } => (share, self.frame_for(&window)),
                // Fullscreen is the output itself, which a topology change
                // already reconciles.
                ShellWindowPresentation::Fullscreen { .. } => continue,
            };
            let current = self.window_geometry_target(&window);
            let Some((work_area, _)) = self.place_output(None, current) else {
                continue;
            };
            let target = shell_content_geometry(share.of(work_area), margins);
            if target == current {
                continue;
            }
            clear_client_geometry_constraints(&window);
            if let Some(managed) = ManagedWindow::new(&window) {
                managed.prepare_shell_geometry(target);
            }
            self.set_window_geometry_target_with_authority(
                &window,
                target,
                WindowGeometryAuthority::Shell,
            );
        }
    }
}

fn place_client_window(
    state: &mut RuntimeState,
    window: &Window,
    place: WindowPlace,
    apply: bool,
) -> Option<(WindowPlaceStatus, Placed)> {
    let (resolved, before) = {
        let frontend = state.frontend();
        (
            frontend.resolve_client_place(window, place),
            frontend.window_placed(window),
        )
    };
    if !apply {
        return Some(match resolved {
            Resolved::Exact(placed) => (WindowPlaceStatus::Applied, placed),
            Resolved::Limited(placed) => (WindowPlaceStatus::Adjusted, placed),
            Resolved::Unchanged => (WindowPlaceStatus::Applied, before),
            // Not knowable without doing it: say so rather than guess.
            Resolved::OnceApplied | Resolved::Refused => (WindowPlaceStatus::Refused, before),
        });
    }

    let expected = match resolved {
        Resolved::Refused => return Some((WindowPlaceStatus::Refused, before)),
        Resolved::Unchanged => return Some((WindowPlaceStatus::Applied, before)),
        Resolved::Exact(placed) | Resolved::Limited(placed) => Some(placed),
        Resolved::OnceApplied => None,
    };
    match place {
        WindowPlace::Free(_) => {
            apply_free_place(
                state,
                window,
                expected.expect("a free place resolves").content,
            );
        }
        WindowPlace::Area { share, .. } => {
            let share = AreaShare::from_fractions(share.x, share.y, share.width, share.height);
            if share.is_whole() {
                apply_maximized_place(state, window, expected.map(|placed| placed.content));
            } else {
                apply_area_place(
                    state,
                    window,
                    share,
                    expected.expect("a share resolves").content,
                );
            }
        }
        WindowPlace::Fullscreen { .. } => {
            toggle_shell_fullscreen_window(state, window, expected.map(|placed| placed.content));
        }
        WindowPlace::Restore => apply_restore_place(state, window),
    }

    let after = state.frontend().window_placed(window);
    let status = match expected {
        Some(expected) if after.content == expected.content => {
            if matches!(resolved, Resolved::Limited(_)) {
                WindowPlaceStatus::Adjusted
            } else {
                WindowPlaceStatus::Applied
            }
        }
        // The layout or the client's own state decided the rectangle.
        None if after != before => WindowPlaceStatus::Applied,
        _ if after == before => WindowPlaceStatus::Refused,
        _ => WindowPlaceStatus::Adjusted,
    };
    Some((status, after))
}

/// Lets a window float at `content`, ending any maximize, share or fullscreen
/// it had. The free place it would have restored to is forgotten: this is
/// its free place now.
fn apply_free_place(state: &mut RuntimeState, window: &Window, content: Rectangle<i32, Logical>) {
    let fullscreen = state
        .frontend()
        .managed_window_presentation(window)
        .fullscreen;
    if fullscreen {
        // Leave fullscreen through its own transition, which tells the shell
        // and the client in the order they expect.
        toggle_shell_fullscreen_window(state, window, None);
    }
    let Some(root) = state.frontend().window_root_surface(window) else {
        return;
    };
    let was_presented = {
        let frontend = state.frontend_mut();
        let surface_id = root.id();
        let presented = frontend.take_shell_presentation(&surface_id).is_some();
        frontend.clear_restore_geometry(&surface_id);
        presented
    };
    configure_shell_owned_geometry(state, window, content, WindowGeometryAuthority::Pending);
    if was_presented {
        queue_window_action_restore(state, window);
    }
    queue_window_placement_for_monitor(
        state,
        window,
        content,
        content,
        WindowPlacementPhase::End,
        WindowPlacementChange::Resize,
    );
    state.scene_sync.mark_dirty();
}

fn queue_window_action_restore(state: &mut RuntimeState, window: &Window) {
    super::window_management::queue_window_action_for_window(state, window, WindowAction::Restore);
}

/// Maximizes a window, on another output when `content` names one. Maximize
/// itself is the transition the shortcut uses.
fn apply_maximized_place(
    state: &mut RuntimeState,
    window: &Window,
    content: Option<Rectangle<i32, Logical>>,
) {
    let (presentation, scrolling, layout_maximized) = {
        let frontend = state.frontend();
        (
            frontend.managed_window_presentation(window),
            frontend.window_is_scrolling_layout_managed(window),
            frontend.window_is_layout_maximized(window),
        )
    };
    if scrolling {
        if presentation.fullscreen || !layout_maximized {
            toggle_scrolling_layout_maximize(state, window);
        }
        return;
    }
    if presentation.fullscreen || !presentation.maximized {
        toggle_shell_maximize_window(state, window);
    }
    // The transition maximizes on the window's own output.
    let Some(content) = content else {
        return;
    };
    let (current, root, layout_managed) = {
        let frontend = state.frontend();
        (
            frontend.window_geometry_target(window),
            frontend.window_root_surface(window),
            frontend.window_is_layout_managed(window),
        )
    };
    let Some(root) = root else {
        return;
    };
    if current == content || layout_managed {
        return;
    }
    transfer_shell_restore_between_outputs(state.frontend_mut(), &root, current, content);
    configure_shell_owned_geometry(state, window, content, WindowGeometryAuthority::Shell);
    state.frontend_mut().remember_window_placement(window);
    state.scene_sync.mark_dirty();
}

/// Gives a window a share of the work area and keeps its free place to
/// restore.
fn apply_area_place(
    state: &mut RuntimeState,
    window: &Window,
    share: AreaShare,
    content: Rectangle<i32, Logical>,
) {
    if state
        .frontend()
        .managed_window_presentation(window)
        .fullscreen
    {
        toggle_shell_fullscreen_window(state, window, None);
    }
    let Some(root) = state.frontend().window_root_surface(window) else {
        return;
    };
    let was_maximized = {
        let frontend = state.frontend_mut();
        let surface_id = root.id();
        let was_maximized = frontend.managed_window_presentation(window).maximized;
        let previous = frontend.take_shell_presentation(&surface_id);
        let normal_geometry = previous
            .map(ShellWindowPresentation::normal_geometry)
            .or_else(|| frontend.take_restore_geometry(&surface_id))
            .unwrap_or_else(|| bound_geometry_size(frontend.window_geometry_target(window)));
        frontend.set_shell_presentation(
            &surface_id,
            ShellWindowPresentation::Area {
                normal_geometry,
                share,
            },
        );
        was_maximized
    };
    configure_shell_owned_geometry(state, window, content, WindowGeometryAuthority::Shell);
    state.frontend_mut().remember_window_placement(window);
    if was_maximized {
        queue_window_action_restore(state, window);
    }
    queue_client_window_placement_for_monitor(
        state,
        window,
        content,
        content,
        WindowPlacementPhase::End,
        WindowPlacementChange::Resize,
    );
    state.scene_sync.mark_dirty();
}

/// Returns a window to the place it had before fullscreen, maximize or a
/// share, one step at a time: fullscreen first, then what lay under it.
fn apply_restore_place(state: &mut RuntimeState, window: &Window) {
    let (presentation, scrolling, shell) = {
        let frontend = state.frontend();
        (
            frontend.managed_window_presentation(window),
            frontend.window_is_scrolling_layout_managed(window),
            frontend.window_shell_presentation(window),
        )
    };
    if presentation.fullscreen {
        toggle_shell_fullscreen_window(state, window, None);
        return;
    }
    if scrolling {
        if state.frontend().window_is_layout_maximized(window) {
            toggle_scrolling_layout_maximize(state, window);
        }
        return;
    }
    let Some(ShellWindowPresentation::Area {
        normal_geometry, ..
    }) = shell
    else {
        if presentation.maximized {
            toggle_shell_maximize_window(state, window);
        }
        return;
    };
    let Some(root) = state.frontend().window_root_surface(window) else {
        return;
    };
    state.frontend_mut().take_shell_presentation(&root.id());
    let content = bound_geometry_size(normal_geometry);
    configure_shell_owned_geometry(state, window, content, WindowGeometryAuthority::Pending);
    queue_window_placement_for_monitor(
        state,
        window,
        content,
        content,
        WindowPlacementPhase::End,
        WindowPlacementChange::Resize,
    );
    state.scene_sync.mark_dirty();
}

/// A window the shell draws itself keeps its maximize and fullscreen state
/// in the shell. Its rectangle is set here; those states are asked of the
/// shell, and the answer is the rectangle the rule gives.
fn place_local_window(
    state: &mut RuntimeState,
    window_id: u64,
    place: WindowPlace,
    apply: bool,
) -> Option<(WindowPlaceStatus, Placed)> {
    let (before, resolved, action) = {
        let frontend = state.frontend();
        let current = frontend.local_flutter_window_geometry(window_id)?;
        let current = global_geometry(
            frontend,
            WindowGeometry {
                x: current.x - frontend.atlas_origin.x,
                y: current.y - frontend.atlas_origin.y,
                ..current
            },
        );
        let margins = frontend.shell_frames_at(current).window(true);
        let before = Placed::around(current, margins);
        let (resolved, action) = match place {
            WindowPlace::Free(frame) => (
                Some(Placed::framed(global_geometry(frontend, frame), margins)),
                None,
            ),
            WindowPlace::Area { monitor_id, share } => {
                let share = AreaShare::from_fractions(share.x, share.y, share.width, share.height);
                let (work_area, _) = frontend.place_output(monitor_id, current)?;
                if share.is_whole() {
                    let margins = frontend
                        .shell_frames_at(work_area)
                        .maximized_window(true, frontend.window_layout_manages_geometry());
                    (
                        Some(Placed::framed(work_area, margins)),
                        Some(WindowAction::Maximize),
                    )
                } else {
                    (Some(Placed::framed(share.of(work_area), margins)), None)
                }
            }
            WindowPlace::Fullscreen { monitor_id } => {
                let (_, output) = frontend.place_output(monitor_id, current)?;
                (
                    Some(Placed::around(output, ShellFrame::NONE)),
                    Some(WindowAction::Fullscreen),
                )
            }
            // Only the shell knows what this window restores to.
            WindowPlace::Restore => (None, Some(WindowAction::Restore)),
        };
        (before, resolved, action)
    };
    if !apply {
        return Some(match resolved {
            Some(placed) => (WindowPlaceStatus::Applied, placed),
            None => (WindowPlaceStatus::Refused, before),
        });
    }
    if let Some(action) = action {
        queue_local_window_action(state, window_id, action);
        return Some((WindowPlaceStatus::Applied, resolved.unwrap_or(before)));
    }
    let placed = resolved?;
    let geometry = scene_geometry(state.frontend(), placed.content);
    state
        .frontend_mut()
        .configure_local_flutter_window(window_id, geometry);
    queue_local_flutter_window_placement(
        state,
        window_id,
        WindowPlacementPhase::End,
        WindowPlacementChange::Resize,
    );
    state.scene_sync.mark_dirty();
    Some((WindowPlaceStatus::Applied, placed))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rect(x: i32, y: i32, width: i32, height: i32) -> Rectangle<i32, Logical> {
        Rectangle::new(Point::from((x, y)), Size::from((width, height)))
    }

    #[test]
    fn a_place_names_the_frame_and_the_content_follows_from_the_margins() {
        let title_bar = ShellFrame {
            left: 1,
            top: 32,
            right: 1,
            bottom: 1,
        };
        let work_area = rect(0, 40, 1920, 1040);
        let left_half = AreaShare::from_fractions(0.0, 0.0, 0.5, 1.0).of(work_area);
        let placed = Placed::framed(left_half, title_bar);

        assert_eq!(placed.frame, rect(0, 40, 960, 1040));
        assert_eq!(placed.content, rect(1, 72, 958, 1007));
        assert_eq!(Placed::around(placed.content, title_bar), placed);
    }
}
