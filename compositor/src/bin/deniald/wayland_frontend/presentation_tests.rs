use super::*;
use smithay::reexports::wayland_server::backend::ClientData;
use smithay::reexports::wayland_server::protocol::wl_compositor::WlCompositor;
use smithay::reexports::wayland_server::{Client, Display, Resource};
use smithay::wayland::GlobalData;
use smithay::wayland::compositor::{
    CompositorClientState, CompositorHandler, CompositorState, with_surface_tree_upward,
};
use std::io::Write;
use std::os::unix::net::UnixStream;
use std::sync::{Arc, mpsc};

struct TestCompositor {
    compositor: CompositorState,
    surface: Option<WlSurface>,
}

#[derive(Default)]
struct TestClient(CompositorClientState);
impl ClientData for TestClient {}

impl CompositorHandler for TestCompositor {
    fn compositor_state(&mut self) -> &mut CompositorState {
        &mut self.compositor
    }

    fn client_compositor_state<'a>(&self, client: &'a Client) -> &'a CompositorClientState {
        &client.get_data::<TestClient>().unwrap().0
    }

    fn new_surface(&mut self, surface: &WlSurface) {
        self.surface = Some(surface.clone());
    }

    fn commit(&mut self, _: &WlSurface) {}
}

smithay::delegate_dispatch2!(TestCompositor);

#[test]
fn feedback_lookup_completes_inside_a_locked_surface_tree_traversal() {
    let (done, result) = mpsc::channel();
    let worker = std::thread::spawn(move || {
        // An isolated protocol connection exercises Smithay's real surface
        // locks without a compositor session, display, or rendered content.
        let mut display = Display::<TestCompositor>::new().unwrap();
        let mut handle = display.handle();
        let mut state = TestCompositor {
            compositor: CompositorState::new::<TestCompositor>(&handle),
            surface: None,
        };
        let (mut writer, reader) = UnixStream::pair().unwrap();
        let client = handle
            .insert_client(reader, Arc::new(TestClient::default()))
            .unwrap();
        let compositor = client
            .create_resource::<WlCompositor, _, TestCompositor>(&handle, 6, GlobalData)
            .unwrap();
        // wl_compositor.create_surface(new_id=2), using the server resource
        // directly so this test needs no client library or registry roundtrip.
        for word in [compositor.id().protocol_id(), 12_u32 << 16, 2] {
            writer.write_all(&word.to_ne_bytes()).unwrap();
        }
        display.dispatch_clients(&mut state).unwrap();
        let surface = state
            .surface
            .as_ref()
            .expect("create_surface was dispatched");
        capture_surface_feedback(surface);
        let mut visited = false;
        with_surface_tree_upward(
            surface,
            (),
            |_, _, _| TraversalAction::DoChildren(()),
            |_, states, _| {
                assert!(surface_feedback(states).is_none());
                visited = true;
            },
            |_, _, _| true,
        );
        assert!(visited);
        done.send(()).unwrap();
    });
    result
        .recv_timeout(Duration::from_secs(2))
        .expect("feedback lookup deadlocked while the surface tree held its lock");
    worker.join().unwrap();
}
