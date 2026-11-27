//! The processes behind the session's windows and Wayland connections, which
//! `session_end` asks to quit before the display goes away.

use smithay::reexports::calloop::LoopHandle;
use smithay::reexports::wayland_server::backend::ClientId;

use super::{RuntimeState, WaylandFrontend};

impl WaylandFrontend {
    /// Every Wayland client's process except Xwayland's, and the process each
    /// mapped X11 window names. May repeat a process.
    pub(crate) fn session_app_pids(&self) -> Vec<i32> {
        let backend = self.display_handle.backend_handle();
        let xwayland = self.xwayland.client_id();
        let mut clients = Vec::<ClientId>::new();
        // The closure runs under the backend lock: only collect here.
        backend.with_all_clients(|client| clients.push(client));
        let pids = clients
            .into_iter()
            .filter(|client| Some(client) != xwayland.as_ref())
            .filter_map(|client| backend.get_client_credentials(client).ok())
            .map(|credentials| credentials.pid)
            .collect::<Vec<_>>();
        #[cfg(feature = "xwayland")]
        let pids = {
            let mut pids = pids;
            pids.extend(
                self.space
                    .elements()
                    .filter_map(|window| window.x11_surface()?.pid())
                    .filter_map(|pid| i32::try_from(pid).ok()),
            );
            pids
        };
        pids
    }

    pub(crate) fn loop_handle(&self) -> &LoopHandle<'static, RuntimeState> {
        &self.loop_handle
    }
}
