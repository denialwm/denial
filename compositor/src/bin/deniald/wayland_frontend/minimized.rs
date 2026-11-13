//! How often a minimized window may draw, and what Denial shows meanwhile.
//!
//! On the phone a minimized window gets no frame callbacks: it is paused, and
//! Denial keeps showing its last frame. Some clients draw a transparent
//! buffer once they are suspended; that frame never reaches the scene. The
//! callbacks a paused window asks for are parked and sent once it is
//! restored, and the kept frame stays until the restored window shows a new
//! one. The desktop shell lets minimized windows draw at the output's rate,
//! and so do windows on a desk next to the phone.
//!
//! A restored window that keeps its kept frame for a second reports what its
//! surfaces committed meanwhile: how many commits arrived, how many applied
//! and how many applied while it still counted as minimized. For three
//! seconds after a restore, each of the window's surfaces reports the
//! commits it applied and the buffers it published to the scene.
//!
//! The phone's lock screen covers every window: all of them are suspended
//! while the session is locked, so apps stay paused until it unlocks. The
//! one exception is the calls app's window while its call stands: it shows
//! over the lock screen and keeps running.

use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

use smithay::desktop::Window;
use smithay::reexports::wayland_server::Resource;
use smithay::reexports::wayland_server::backend::ObjectId;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;

use tracing::{info, warn};

use super::WaylandFrontend;
use super::managed_window::ManagedWindow;

/// How often a window gets frame callbacks. Per-app rates for minimized
/// windows go here.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum FramePace {
    /// Every output frame it is on.
    Output,
    /// None until it is restored.
    Paused,
}

/// How long a restored window may show its kept frame before it reports.
const THAW_REPORT: Duration = Duration::from_secs(1);

/// How long Denial follows a restored window's surfaces before it reports.
const RESTORE_WATCH: Duration = Duration::from_secs(3);

/// What one surface of a restored window did since the restore.
#[derive(Debug, Default)]
struct SurfaceTally {
    applied: u32,
    visual: u32,
    published: u32,
}

/// The window restored last, followed for [`RESTORE_WATCH`].
#[derive(Debug)]
struct RestoreWatch {
    root: ObjectId,
    since: Instant,
    /// Publishes skipped because the window was frozen.
    held: u32,
    surfaces: HashMap<ObjectId, SurfaceTally>,
}

/// A restored window still showing its kept frame, and what its surfaces
/// committed since it was restored.
#[derive(Debug)]
struct Thaw {
    since: Instant,
    /// Commits that reached Denial, before any blocker held them.
    arrived: u32,
    /// Commits Denial applied.
    applied: u32,
    /// Applied commits with new content while the window was minimized.
    visual_while_minimized: u32,
    reported: bool,
}

impl Thaw {
    fn new() -> Self {
        Self {
            since: Instant::now(),
            arrived: 0,
            applied: 0,
            visual_while_minimized: 0,
            reported: false,
        }
    }
}

#[derive(Debug, Default)]
pub(super) struct MinimizedWindows {
    /// Paused windows that asked for a frame callback.
    parked: HashSet<ObjectId>,
    /// Restored windows still showing their kept frame.
    thawing: HashMap<ObjectId, Thaw>,
    /// The window restored last, while it is followed.
    watch: Option<RestoreWatch>,
    /// The textures of frozen windows in the scene last built: they keep
    /// their frame without being given a new one.
    kept_textures: Vec<u64>,
    /// The lock screen covers every window.
    covered: bool,
    /// The calls app's window shown over the lock screen, by root surface.
    over_lock: Option<ObjectId>,
}

impl WaylandFrontend {
    fn frame_pace(&self, root: &ObjectId) -> FramePace {
        if self.surface_is_minimized(root) && self.root_on_phone(root) {
            FramePace::Paused
        } else {
            FramePace::Output
        }
    }

    /// Queues the frame callbacks of the window rooted at `root` for the next
    /// output frame, or parks them while the window is paused.
    pub(super) fn queue_window_frame_callbacks(&mut self, root: ObjectId) {
        match self.frame_pace(&root) {
            FramePace::Output => {
                self.pending_frame_callback_windows.insert(root);
            }
            FramePace::Paused => {
                self.minimized_windows.parked.insert(root);
            }
        }
    }

    /// Follows the window rooted at `root` being minimized or restored.
    pub(super) fn minimized_changed(&mut self, root: &ObjectId, minimized: bool) {
        if !self.root_on_phone(root) {
            return;
        }
        if minimized {
            if let Some(thaw) = self.minimized_windows.thawing.remove(root)
                && !thaw.reported
                && thaw.since.elapsed() >= THAW_REPORT
            {
                warn!(
                    surface_id = ?root,
                    frozen_ms = thaw.since.elapsed().as_millis() as u64,
                    arrived = thaw.arrived,
                    applied = thaw.applied,
                    visual_while_minimized = thaw.visual_while_minimized,
                    "restored window minimized again while still showing its kept frame"
                );
            }
            if self.pending_frame_callback_windows.remove(root) {
                self.minimized_windows.parked.insert(root.clone());
            }
        } else {
            self.keep_window_on_phone(root);
            self.minimized_windows
                .thawing
                .insert(root.clone(), Thaw::new());
            self.report_restore_watch();
            info!(surface_id = ?root, "window restored");
            self.minimized_windows.watch = Some(RestoreWatch {
                root: root.clone(),
                since: Instant::now(),
                held: 0,
                surfaces: HashMap::new(),
            });
            if self.minimized_windows.parked.remove(root) {
                self.pending_frame_callback_windows.insert(root.clone());
            }
        }
    }

    /// Whether the lock screen covers every window: they stay suspended.
    pub(super) fn windows_covered(&self) -> bool {
        self.minimized_windows.covered
    }

    /// Whether the lock screen keeps `window` suspended: every window but the
    /// one shown over it.
    pub(super) fn window_covered(&self, window: &Window) -> bool {
        self.minimized_windows.covered && !self.window_over_lock(window)
    }

    pub(super) fn window_over_lock(&self, window: &Window) -> bool {
        self.minimized_windows
            .over_lock
            .as_ref()
            .is_some_and(|over_lock| {
                self.window_root_surface(window)
                    .is_some_and(|root| root.id() == *over_lock)
            })
    }

    /// Shows the window of `app_id` over the lock screen and lets it run, or
    /// none with `None`. Returns the window when it newly shows there.
    #[cfg(feature = "flutter")]
    pub(crate) fn set_over_lock_app(&mut self, app_id: Option<&str>) -> Option<Window> {
        let window = app_id
            .filter(|_| self.mobile_shell && self.minimized_windows.covered)
            .and_then(|app_id| {
                self.space
                    .elements()
                    .find(|window| {
                        ManagedWindow::new(window)
                            .and_then(|managed| managed.identity())
                            .is_some_and(|identity| identity.app_id() == app_id)
                    })
                    .cloned()
            });
        let root = window
            .as_ref()
            .and_then(|window| self.window_root_surface(window))
            .map(|root| root.id());
        if root == self.minimized_windows.over_lock {
            return None;
        }
        let previous = std::mem::replace(&mut self.minimized_windows.over_lock, root);
        if let Some(previous) = previous
            && let Some(managed) = self
                .space
                .elements()
                .find(|window| {
                    self.window_root_surface(window)
                        .is_some_and(|root| root.id() == previous)
                })
                .and_then(ManagedWindow::new)
        {
            managed
                .prepare_suspended(self.windows_covered() || self.surface_is_minimized(&previous));
        }
        let window = window?;
        if let Some(managed) = ManagedWindow::new(&window) {
            managed.prepare_suspended(false);
        }
        Some(window)
    }

    /// Follows the phone's session lock: suspends every window while the
    /// lock screen covers it, and gives unlocked windows back their state.
    pub(crate) fn set_windows_covered(&mut self, covered: bool) {
        if !self.mobile_shell || self.minimized_windows.covered == covered {
            return;
        }
        self.minimized_windows.covered = covered;
        self.minimized_windows.over_lock = None;
        for window in self.space.elements() {
            let Some(managed) = ManagedWindow::new(window) else {
                continue;
            };
            let minimized = self
                .window_root_surface(window)
                .is_some_and(|root| self.surface_is_minimized(&root.id()));
            managed.prepare_suspended(covered || minimized);
        }
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn mobile_shell(&self) -> bool {
        self.mobile_shell
    }

    /// Whether the window rooted at `root` shows its kept frame instead of
    /// its committed buffers.
    pub(super) fn window_frozen(&self, root: &ObjectId) -> bool {
        (self.surface_is_minimized(root) || self.minimized_windows.thawing.contains_key(root))
            && self.root_on_phone(root)
    }

    /// A commit reached a surface, before any blocker holds it.
    pub(super) fn note_thawing_commit_arrived(&mut self, surface: &WlSurface) {
        if self.minimized_windows.thawing.is_empty() {
            return;
        }
        let Some(root) = self.owning_toplevel_surface(surface) else {
            return;
        };
        let root = root.id();
        if let Some(thaw) = self.minimized_windows.thawing.get_mut(&root) {
            thaw.arrived += 1;
            self.report_long_thaw(&root);
        }
    }

    /// A surface's commit applied. One with new content makes a restored
    /// window it belongs to show its buffers again from this commit on.
    pub(super) fn thaw_on_commit(&mut self, surface: &WlSurface, visual: bool) {
        if let Some(tally) = self.watched_surface(surface) {
            tally.applied += 1;
            tally.visual += u32::from(visual);
        }
        if self
            .minimized_windows
            .watch
            .as_ref()
            .is_some_and(|watch| watch.since.elapsed() >= RESTORE_WATCH)
        {
            self.report_restore_watch();
        }
        if self.minimized_windows.thawing.is_empty() {
            return;
        }
        let Some(root) = self.owning_toplevel_surface(surface) else {
            return;
        };
        let root = root.id();
        let minimized = self.surface_is_minimized(&root);
        let Some(thaw) = self.minimized_windows.thawing.get_mut(&root) else {
            return;
        };
        thaw.applied += 1;
        if !visual {
            self.report_long_thaw(&root);
            return;
        }
        if minimized {
            thaw.visual_while_minimized += 1;
            self.report_long_thaw(&root);
            return;
        }
        let thaw = self
            .minimized_windows
            .thawing
            .remove(&root)
            .expect("thawing window exists");
        info!(
            surface_id = ?root,
            by = ?surface.id(),
            frozen_ms = thaw.since.elapsed().as_millis() as u64,
            arrived = thaw.arrived,
            applied = thaw.applied,
            "restored window shows new frames again"
        );
    }

    /// The tally of `surface` when it belongs to the followed window.
    fn watched_surface(&mut self, surface: &WlSurface) -> Option<&mut SurfaceTally> {
        let watched = self.minimized_windows.watch.as_ref()?.root.clone();
        let root = self.owning_toplevel_surface(surface)?;
        if root.id() != watched {
            return None;
        }
        Some(
            self.minimized_windows
                .watch
                .as_mut()?
                .surfaces
                .entry(surface.id())
                .or_default(),
        )
    }

    /// A publish of the window rooted at `root` waited for it to thaw.
    pub(super) fn note_held_publish(&mut self, root: &ObjectId) {
        if let Some(watch) = self.minimized_windows.watch.as_mut()
            && watch.root == *root
        {
            watch.held += 1;
        }
    }

    /// `surface`'s applied commit reached the scene.
    pub(super) fn note_published(&mut self, surface: &WlSurface) {
        if let Some(tally) = self.watched_surface(surface) {
            tally.published += 1;
        }
    }

    fn report_restore_watch(&mut self) {
        let Some(watch) = self.minimized_windows.watch.take() else {
            return;
        };
        info!(
            surface_id = ?watch.root,
            watched_ms = watch.since.elapsed().as_millis() as u64,
            held = watch.held,
            minimized = self.surface_is_minimized(&watch.root),
            frozen = self.window_frozen(&watch.root),
            surfaces = watch.surfaces.len(),
            "restored window after the restore"
        );
        for (surface, tally) in &watch.surfaces {
            let stable_id = self.surface_ids.get(surface).copied();
            info!(
                root = ?watch.root,
                surface_id = ?surface,
                stable_id,
                in_scene = stable_id.is_some_and(|id| self.scene_surface_windows.contains_key(&id)),
                applied = tally.applied,
                visual = tally.visual,
                published = tally.published,
                "restored window surface"
            );
        }
    }

    fn report_long_thaw(&mut self, root: &ObjectId) {
        let minimized = self.surface_is_minimized(root);
        let Some(thaw) = self.minimized_windows.thawing.get_mut(root) else {
            return;
        };
        if thaw.reported || thaw.since.elapsed() < THAW_REPORT {
            return;
        }
        thaw.reported = true;
        warn!(
            surface_id = ?root,
            frozen_ms = thaw.since.elapsed().as_millis() as u64,
            arrived = thaw.arrived,
            applied = thaw.applied,
            visual_while_minimized = thaw.visual_while_minimized,
            minimized,
            "restored window still shows its kept frame"
        );
    }

    pub(super) fn clear_kept_textures(&mut self) {
        self.minimized_windows.kept_textures.clear();
    }

    pub(super) fn keep_texture(&mut self, texture_id: u64) {
        self.minimized_windows.kept_textures.push(texture_id);
    }

    /// The textures of frozen windows in the scene last built.
    pub fn kept_texture_ids(&self) -> &[u64] {
        &self.minimized_windows.kept_textures
    }

    pub(super) fn forget_minimized_window(&mut self, root: &ObjectId) {
        self.minimized_windows.parked.remove(root);
        self.minimized_windows.thawing.remove(root);
    }
}
