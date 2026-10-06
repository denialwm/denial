//! Stable window identity and compositor-owned per-window state.
//!
//! Protocol objects are adapters at the edge. Once a surface becomes a window,
//! policy is keyed by `WindowId` so the rest of the compositor does not need to
//! care whether the client arrived through XDG shell or Xwayland.

use std::collections::HashMap;

use super::*;

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub(super) struct WindowId(u64);

impl WindowId {
    pub(super) fn new(raw: u64) -> Self {
        debug_assert_ne!(raw, 0);
        Self(raw)
    }

    #[cfg(any(feature = "flutter", feature = "xwayland"))]
    pub(super) const fn get(self) -> u64 {
        self.0
    }
}

#[derive(Default)]
pub(super) struct WindowRecord {
    pub(super) geometry_intent: Option<WindowGeometryIntent>,
    pub(super) layout_preview_size: Option<Size<i32, Logical>>,
    pub(super) restore_geometry: Option<Rectangle<i32, Logical>>,
    pub(super) layout_restore_geometry: Option<Rectangle<i32, Logical>>,
    pub(super) layout_insertion_anchor: Option<ObjectId>,
    pub(super) restored_position: bool,
    pub(super) client_geometry_state_requested: bool,
    pub(super) pending_client_sized_placement: Option<PendingClientSizedPlacement>,
    pub(super) pending_auxiliary_toplevel_placement: Option<PendingAuxiliaryToplevelPlacement>,
    pub(super) placed_transient_parent: Option<ObjectId>,
    pub(super) placed_transient_parent_geometry: Option<Rectangle<i32, Logical>>,
    #[cfg(feature = "flutter")]
    pub(super) shell_presentation: Option<window_presentation::ShellWindowPresentation>,
    #[cfg(feature = "flutter")]
    pub(super) vertical_restore_geometry: Option<(f64, f64)>,
    #[cfg(feature = "flutter")]
    pub(super) minimized: bool,
    #[cfg(feature = "flutter")]
    pub(super) pinned: bool,
    #[cfg(feature = "flutter")]
    pub(super) visible: bool,
    #[cfg(feature = "flutter")]
    pub(super) workspace: Option<workspace::WorkspaceLocation>,
    #[cfg(feature = "flutter")]
    pub(super) minimized_output: Option<OutputId>,
}

#[derive(Default)]
pub(super) struct WindowRegistry {
    windows: HashMap<WindowId, WindowRecord>,
}

impl WindowRegistry {
    pub(super) fn ensure(&mut self, id: WindowId) -> &mut WindowRecord {
        self.windows.entry(id).or_default()
    }

    pub(super) fn get(&self, id: WindowId) -> Option<&WindowRecord> {
        self.windows.get(&id)
    }

    pub(super) fn get_mut(&mut self, id: WindowId) -> Option<&mut WindowRecord> {
        self.windows.get_mut(&id)
    }

    pub(super) fn remove(&mut self, id: WindowId) -> Option<WindowRecord> {
        self.windows.remove(&id)
    }

    pub(super) fn values_mut(&mut self) -> impl Iterator<Item = &mut WindowRecord> {
        self.windows.values_mut()
    }

    #[cfg(feature = "flutter")]
    pub(super) fn iter(&self) -> impl Iterator<Item = (WindowId, &WindowRecord)> {
        self.windows.iter().map(|(&id, record)| (id, record))
    }
}

impl WaylandFrontend {
    pub(super) fn window_id_for_surface(&self, surface: &ObjectId) -> Option<WindowId> {
        self.surface_ids.get(surface).copied().map(WindowId::new)
    }

    #[cfg(feature = "flutter")]
    pub(super) fn window_record(&self, id: u64) -> Option<&WindowRecord> {
        self.window_registry.get(WindowId::new(id))
    }

    #[cfg(feature = "flutter")]
    pub(super) fn window_record_mut(&mut self, id: u64) -> Option<&mut WindowRecord> {
        self.window_registry.get_mut(WindowId::new(id))
    }

    pub(super) fn window_record_for_surface(&self, surface: &ObjectId) -> Option<&WindowRecord> {
        self.window_registry
            .get(self.window_id_for_surface(surface)?)
    }

    pub(super) fn window_record_for_surface_mut(
        &mut self,
        surface: &ObjectId,
    ) -> Option<&mut WindowRecord> {
        let id = self.window_id_for_surface(surface)?;
        self.window_registry.get_mut(id)
    }

    pub(super) fn ensure_window_record_for_surface(
        &mut self,
        surface: &ObjectId,
    ) -> Option<&mut WindowRecord> {
        let id = self.window_id_for_surface(surface)?;
        Some(self.window_registry.ensure(id))
    }

    pub(super) fn register_window(&mut self, surface: &WlSurface) -> WindowId {
        let id = WindowId::new(self.register_surface(surface));
        self.window_registry.ensure(id);
        id
    }

    #[cfg(feature = "flutter")]
    pub(super) fn window_is_minimized(&self, id: u64) -> bool {
        self.window_record(id)
            .is_some_and(|record| record.minimized)
    }

    #[cfg(feature = "flutter")]
    pub(super) fn surface_is_minimized(&self, surface: &ObjectId) -> bool {
        self.window_record_for_surface(surface)
            .is_some_and(|record| record.minimized)
    }

    #[cfg(feature = "flutter")]
    pub(super) fn window_id_is_pinned(&self, id: u64) -> bool {
        self.window_record(id).is_some_and(|record| record.pinned)
    }

    #[cfg(feature = "flutter")]
    pub(super) fn window_id_is_visible(&self, id: u64) -> bool {
        self.window_record(id).is_some_and(|record| record.visible)
    }

    #[cfg(feature = "flutter")]
    pub(super) fn window_expects_sample(&self, id: u64) -> bool {
        !self.input_visibility_known || self.window_id_is_visible(id)
    }

    #[cfg(feature = "flutter")]
    pub(super) fn clear_visible_windows(&mut self) {
        for record in self.window_registry.values_mut() {
            record.visible = false;
        }
    }

    #[cfg(feature = "flutter")]
    pub(super) fn take_shell_presentation(
        &mut self,
        surface: &ObjectId,
    ) -> Option<window_presentation::ShellWindowPresentation> {
        self.window_record_for_surface_mut(surface)?
            .shell_presentation
            .take()
    }

    #[cfg(feature = "flutter")]
    pub(super) fn set_shell_presentation(
        &mut self,
        surface: &ObjectId,
        presentation: window_presentation::ShellWindowPresentation,
    ) {
        if let Some(record) = self.ensure_window_record_for_surface(surface) {
            record.shell_presentation = Some(presentation);
        }
    }

    pub(super) fn take_restore_geometry(
        &mut self,
        surface: &ObjectId,
    ) -> Option<Rectangle<i32, Logical>> {
        self.window_record_for_surface_mut(surface)?
            .restore_geometry
            .take()
    }

    #[cfg(feature = "flutter")]
    pub(super) fn clear_restore_geometry(&mut self, surface: &ObjectId) {
        if let Some(record) = self.window_record_for_surface_mut(surface) {
            record.restore_geometry = None;
        }
    }
}
