//! Monitor-local virtual workspace ownership.
//!
//! A normal window belongs to exactly one `(output, workspace)` pair. A
//! minimized window belongs to no workspace and remembers only its preferred
//! output, so restoring it attaches it to that output's currently active
//! workspace.

use denial_core::topology::OutputId;

use super::super::settings::WorkspaceSettings;
use super::WaylandFrontend;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct WorkspaceLocation {
    pub(super) output: OutputId,
    pub(super) workspace: u8,
}

impl WaylandFrontend {
    pub(super) fn workspaces_enabled(&self) -> bool {
        self.workspaces_enabled
    }

    pub(super) fn workspace_count(&self) -> u8 {
        self.workspace_count
    }

    pub(super) fn active_workspace(&self, output: OutputId) -> u8 {
        self.active_workspaces.get(&output).copied().unwrap_or(1)
    }

    pub(super) fn active_workspace_for_monitor(&self, monitor_id: i64) -> Option<u8> {
        let output = u64::try_from(monitor_id).ok().map(OutputId)?;
        self.outputs
            .iter()
            .any(|candidate| candidate.id == output)
            .then(|| self.active_workspace(output))
    }

    pub(super) fn workspace_location(&self, window_id: u64) -> Option<WorkspaceLocation> {
        self.window_workspaces.get(&window_id).copied()
    }

    pub(super) fn reconcile_workspace_assignment(
        &mut self,
        window_id: u64,
        output: OutputId,
        minimized: bool,
    ) -> Option<WorkspaceLocation> {
        if !self.outputs.iter().any(|candidate| candidate.id == output) {
            return None;
        }
        if minimized {
            if let Some(previous) = self.window_workspaces.remove(&window_id) {
                self.minimized_window_outputs
                    .insert(window_id, previous.output);
            } else {
                self.minimized_window_outputs
                    .entry(window_id)
                    .or_insert(output);
            }
            return None;
        }

        self.minimized_window_outputs.remove(&window_id);
        let active = self.active_workspace(output);
        let location = self
            .window_workspaces
            .entry(window_id)
            .or_insert(WorkspaceLocation {
                output,
                workspace: active,
            });
        // Crossing an output boundary always joins the destination's visible
        // workspace. Geometry movement within one output retains membership.
        if location.output != output {
            *location = WorkspaceLocation {
                output,
                workspace: active,
            };
        }
        Some(*location)
    }

    pub(super) fn mark_window_minimized(&mut self, window_id: u64, fallback: OutputId) {
        self.workspace_focus_history
            .retain(|_, focused| *focused != window_id);
        let preferred = self
            .window_workspaces
            .remove(&window_id)
            .map(|location| location.output)
            .unwrap_or(fallback);
        self.minimized_window_outputs.insert(window_id, preferred);
    }

    pub(super) fn restore_window_workspace(&mut self, window_id: u64) -> Option<WorkspaceLocation> {
        if let Some(location) = self.window_workspaces.get(&window_id).copied() {
            self.minimized_window_outputs.remove(&window_id);
            return Some(location);
        }
        let output = self
            .minimized_window_outputs
            .remove(&window_id)
            .filter(|output| self.outputs.iter().any(|candidate| candidate.id == *output))
            .or(self.ticker_output)
            .or_else(|| self.outputs.first().map(|output| output.id))?;
        let location = WorkspaceLocation {
            output,
            workspace: self.active_workspace(output),
        };
        self.window_workspaces.insert(window_id, location);
        Some(location)
    }

    pub(super) fn forget_window_workspace(&mut self, window_id: u64) {
        self.window_workspaces.remove(&window_id);
        self.minimized_window_outputs.remove(&window_id);
        self.workspace_focus_history
            .retain(|_, focused| *focused != window_id);
    }

    pub(super) fn record_workspace_focus(&mut self, window_id: u64) {
        if let Some(location) = self.workspace_location(window_id) {
            self.workspace_focus_history
                .insert((location.output, location.workspace), window_id);
        }
    }

    pub(super) fn remembered_workspace_focus(&self, monitor_id: i64, workspace: u8) -> Option<u64> {
        let output = u64::try_from(monitor_id).ok().map(OutputId)?;
        self.workspace_focus_history
            .get(&(output, workspace))
            .copied()
    }

    pub(super) fn window_is_on_active_workspace(&self, window_id: u64) -> bool {
        if !self.workspaces_enabled {
            return true;
        }
        self.window_workspaces
            .get(&window_id)
            .is_some_and(|location| location.workspace == self.active_workspace(location.output))
    }

    pub(super) fn switch_workspace(&mut self, monitor_id: i64, workspace: u8) -> bool {
        if !self.workspaces_enabled || !(1..=self.workspace_count).contains(&workspace) {
            return false;
        }
        let Some(output) = u64::try_from(monitor_id)
            .ok()
            .map(OutputId)
            .filter(|output| self.outputs.iter().any(|candidate| candidate.id == *output))
        else {
            return false;
        };
        let active = self.active_workspaces.entry(output).or_insert(1);
        if *active == workspace {
            return false;
        }
        *active = workspace;
        self.invalidate_idle_inhibition();
        true
    }

    pub(super) fn adjacent_workspace(&self, monitor_id: i64, delta: i8) -> Option<u8> {
        if !self.workspaces_enabled {
            return None;
        }
        let current = self.active_workspace_for_monitor(monitor_id)?;
        let count = i16::from(self.workspace_count);
        let zero_based = (i16::from(current) - 1 + i16::from(delta)).rem_euclid(count);
        u8::try_from(zero_based + 1).ok()
    }

    pub(super) fn move_window_to_workspace(
        &mut self,
        window_id: u64,
        output: Option<OutputId>,
        workspace: u8,
    ) -> Option<WorkspaceLocation> {
        if !self.workspaces_enabled || !(1..=self.workspace_count).contains(&workspace) {
            return None;
        }
        if output.is_some_and(|output| !self.outputs.iter().any(|candidate| candidate.id == output))
        {
            return None;
        }
        self.workspace_focus_history
            .retain(|_, focused| *focused != window_id);
        let location = self.window_workspaces.get_mut(&window_id)?;
        if let Some(output) = output {
            location.output = output;
        }
        location.workspace = workspace;
        Some(*location)
    }

    /// Applies a live settings change without discarding applications.
    /// Removed workspaces merge into the highest remaining workspace on their
    /// current output; disabling merges everything into workspace one.
    pub(crate) fn set_workspace_settings(&mut self, settings: WorkspaceSettings) -> bool {
        if self.workspaces_enabled == settings.enabled && self.workspace_count == settings.count {
            return false;
        }
        self.workspaces_enabled = settings.enabled;
        self.workspace_count = settings.count;
        for workspace in self.active_workspaces.values_mut() {
            *workspace = if settings.enabled {
                (*workspace).min(settings.count)
            } else {
                1
            };
        }
        for location in self.window_workspaces.values_mut() {
            location.workspace = if settings.enabled {
                location.workspace.min(settings.count)
            } else {
                1
            };
        }
        self.invalidate_idle_inhibition();
        true
    }

    pub(crate) fn workspace_state_snapshot(&self) -> Vec<(i64, u8)> {
        self.outputs
            .iter()
            .filter_map(|output| {
                i64::try_from(output.id.0)
                    .ok()
                    .map(|monitor_id| (monitor_id, self.active_workspace(output.id)))
            })
            .collect()
    }

    /// Migrates all ownership away from disconnected outputs while leaving
    /// surviving monitors on their current workspace. Reconnected outputs are
    /// deliberately new session state and start on workspace one.
    pub(super) fn reconcile_workspace_outputs(&mut self) {
        let present = self
            .outputs
            .iter()
            .map(|output| output.id)
            .collect::<std::collections::HashSet<_>>();
        let fallback = self
            .ticker_output
            .filter(|output| present.contains(output))
            .or_else(|| self.outputs.first().map(|output| output.id));

        self.active_workspaces
            .retain(|output, _| present.contains(output));
        let migrated_focus = self
            .workspace_focus_history
            .iter()
            .filter_map(|(&(output, workspace), &window_id)| {
                (!present.contains(&output)).then_some((workspace, window_id))
            })
            .collect::<Vec<_>>();
        self.workspace_focus_history
            .retain(|(output, _), _| present.contains(output));
        for output in &present {
            self.active_workspaces.entry(*output).or_insert(1);
        }
        let Some(fallback) = fallback else {
            self.window_workspaces.clear();
            self.minimized_window_outputs.clear();
            self.workspace_focus_history.clear();
            return;
        };
        for (workspace, window_id) in migrated_focus {
            self.workspace_focus_history
                .entry((fallback, workspace.min(self.workspace_count).max(1)))
                .or_insert(window_id);
        }
        for location in self.window_workspaces.values_mut() {
            if !present.contains(&location.output) {
                location.output = fallback;
            }
            location.workspace = location.workspace.min(self.workspace_count).max(1);
        }
        for output in self.minimized_window_outputs.values_mut() {
            if !present.contains(output) {
                *output = fallback;
            }
        }
    }
}
