//! `ext_idle_notifier_v1`: clients learn when the user has been idle for a
//! timeout they choose, and when activity resumes. Activity is the same user
//! input that resets Denial's own inactivity policy. Idle notifications honor
//! visible idle inhibitors; input-idle notifications (version 2) do not.

use smithay::wayland::idle_notify::{IdleNotifierHandler, IdleNotifierState};

use super::{RuntimeState, WaylandFrontend};

impl WaylandFrontend {
    /// The user acted: running idle timeouts restart, and idle clients resume.
    pub(crate) fn note_idle_activity(&mut self) {
        self.idle_notifier.notify_activity(&self.seat);
    }
}

impl IdleNotifierHandler for RuntimeState {
    fn idle_notifier_state(&mut self) -> &mut IdleNotifierState<Self> {
        &mut self
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .idle_notifier
    }
}

pub(super) fn new(
    display: &smithay::reexports::wayland_server::DisplayHandle,
    loop_handle: smithay::reexports::calloop::LoopHandle<'static, RuntimeState>,
) -> IdleNotifierState<RuntimeState> {
    IdleNotifierState::new(display, loop_handle)
}
