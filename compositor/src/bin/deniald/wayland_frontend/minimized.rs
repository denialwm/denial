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
//! The phone's lock screen covers every window: all of them are suspended
//! while the session is locked, so apps stay paused until it unlocks.

use std::collections::HashSet;

use smithay::reexports::wayland_server::Resource;
use smithay::reexports::wayland_server::backend::ObjectId;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;

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

#[derive(Debug, Default)]
pub(super) struct MinimizedWindows {
    /// Paused windows that asked for a frame callback.
    parked: HashSet<ObjectId>,
    /// Restored windows still showing their kept frame.
    thawing: HashSet<ObjectId>,
    /// The textures of frozen windows in the scene last built: they keep
    /// their frame without being given a new one.
    kept_textures: Vec<u64>,
    /// The lock screen covers every window.
    covered: bool,
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
            self.minimized_windows.thawing.remove(root);
            if self.pending_frame_callback_windows.remove(root) {
                self.minimized_windows.parked.insert(root.clone());
            }
        } else {
            self.keep_window_on_phone(root);
            self.minimized_windows.thawing.insert(root.clone());
            if self.minimized_windows.parked.remove(root) {
                self.pending_frame_callback_windows.insert(root.clone());
            }
        }
    }

    /// Whether the lock screen covers every window: they stay suspended.
    pub(super) fn windows_covered(&self) -> bool {
        self.minimized_windows.covered
    }

    /// Follows the phone's session lock: suspends every window while the
    /// lock screen covers it, and gives unlocked windows back their state.
    pub(crate) fn set_windows_covered(&mut self, covered: bool) {
        if !self.mobile_shell || self.minimized_windows.covered == covered {
            return;
        }
        self.minimized_windows.covered = covered;
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
        (self.surface_is_minimized(root) || self.minimized_windows.thawing.contains(root))
            && self.root_on_phone(root)
    }

    /// A surface committed new content: a restored window it belongs to
    /// shows its buffers again from this commit on.
    pub(super) fn thaw_on_visual_commit(&mut self, surface: &WlSurface) {
        if self.minimized_windows.thawing.is_empty() {
            return;
        }
        let Some(root) = self.owning_toplevel_surface(surface) else {
            return;
        };
        if !self.surface_is_minimized(&root.id()) {
            self.minimized_windows.thawing.remove(&root.id());
        }
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
