//! `zwp_idle_inhibit_manager_v1` integration for visible client surfaces.

use std::collections::HashMap;

use smithay::reexports::wayland_server::Resource;
use smithay::reexports::wayland_server::backend::ObjectId;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::wayland::idle_inhibit::{IdleInhibitHandler, IdleInhibitManagerState};

use super::{RuntimeState, WaylandFrontend, window_expects_sample};

#[derive(Debug)]
pub(super) struct IdleInhibitors {
    _manager: IdleInhibitManagerState,
    surfaces: HashMap<ObjectId, InhibitingSurface>,
}

#[derive(Debug)]
struct InhibitingSurface {
    surface: WlSurface,
    count: usize,
}

impl IdleInhibitors {
    pub(super) fn new(display: &smithay::reexports::wayland_server::DisplayHandle) -> Self {
        Self {
            _manager: IdleInhibitManagerState::new::<RuntimeState>(display),
            surfaces: HashMap::new(),
        }
    }

    fn inhibit(&mut self, surface: WlSurface) {
        let object_id = surface.id();
        self.surfaces
            .entry(object_id)
            .and_modify(|entry| entry.count = entry.count.saturating_add(1))
            .or_insert(InhibitingSurface { surface, count: 1 });
    }

    fn uninhibit(&mut self, surface: &WlSurface) {
        let object_id = surface.id();
        let remove = self.surfaces.get_mut(&object_id).is_some_and(|entry| {
            entry.count = entry.count.saturating_sub(1);
            entry.count == 0
        });
        if remove {
            self.surfaces.remove(&object_id);
        }
    }

    pub(super) fn remove_surface(&mut self, surface: &WlSurface) {
        self.surfaces.remove(&surface.id());
    }

    fn prune(&mut self) {
        self.surfaces
            .retain(|_, entry| entry.count > 0 && entry.surface.is_alive());
    }
}

impl WaylandFrontend {
    pub(super) fn invalidate_idle_inhibition(&mut self) {
        self.idle_inhibition_dirty = true;
    }

    /// Whether a mapped, visible client surface currently asks Denial to keep
    /// the displays awake. Hidden/minimized videos do not inhibit DPMS.
    pub(crate) fn idle_inhibited(&mut self) -> bool {
        if !self.idle_inhibition_dirty {
            return self.idle_inhibition_cached;
        }
        self.idle_inhibitors.prune();
        let inhibited = self.idle_inhibitors.surfaces.values().any(|entry| {
            let Some(root) = self.owning_toplevel_surface(&entry.surface) else {
                return false;
            };
            if self.minimized_windows.contains(&root.id()) {
                return false;
            }
            self.surface_id(&root).is_some_and(|window_id| {
                window_expects_sample(
                    self.input_visibility_known,
                    &self.visible_window_ids,
                    window_id,
                )
            })
        });
        self.idle_inhibition_cached = inhibited;
        self.idle_inhibition_dirty = false;
        inhibited
    }
}

impl IdleInhibitHandler for RuntimeState {
    fn inhibit(&mut self, surface: WlSurface) {
        if let Some(frontend) = self.wayland.as_mut() {
            frontend.idle_inhibitors.inhibit(surface);
            frontend.invalidate_idle_inhibition();
        }
    }

    fn uninhibit(&mut self, surface: WlSurface) {
        if let Some(frontend) = self.wayland.as_mut() {
            frontend.idle_inhibitors.uninhibit(&surface);
            frontend.invalidate_idle_inhibition();
        }
    }
}
