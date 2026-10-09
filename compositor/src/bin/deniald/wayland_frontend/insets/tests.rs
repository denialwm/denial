//! Isolated protocol tests; no compositor session, renderer or client UI.

use super::*;
use smithay::reexports::wayland_protocols::xdg::shell::server::xdg_wm_base::XdgWmBase;
use smithay::reexports::wayland_server::backend::ClientData;
use smithay::reexports::wayland_server::protocol::wl_compositor::WlCompositor;
use smithay::wayland::GlobalData;
use smithay::wayland::shell::xdg::XdgWmBaseUserData;
use std::io::{ErrorKind, Read, Write};
use std::os::unix::net::UnixStream;

struct TestCompositor {
    compositor: CompositorState,
    xdg_shell: XdgShellState,
    toplevel: Option<ToplevelSurface>,
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

    fn commit(&mut self, _: &WlSurface) {}
}

impl XdgShellHandler for TestCompositor {
    fn xdg_shell_state(&mut self) -> &mut XdgShellState {
        &mut self.xdg_shell
    }

    fn new_toplevel(&mut self, surface: ToplevelSurface) {
        self.toplevel = Some(surface);
    }

    fn new_popup(&mut self, _: PopupSurface, _: PositionerState) {
        unreachable!()
    }

    fn grab(&mut self, _: PopupSurface, _: wl_seat::WlSeat, _: Serial) {
        unreachable!()
    }

    fn reposition_request(&mut self, _: PopupSurface, _: PositionerState, _: u32) {
        unreachable!()
    }
}

smithay::delegate_dispatch2!(TestCompositor);

struct Fixture {
    display: Display<TestCompositor>,
    state: TestCompositor,
    socket: UnixStream,
    compositor_id: u32,
    shell_id: u32,
}

impl Fixture {
    fn new(version: u32) -> Self {
        let display = Display::new().unwrap();
        let mut handle = display.handle();
        let state = TestCompositor {
            compositor: CompositorState::new::<TestCompositor>(&handle),
            xdg_shell: XdgShellState::new::<TestCompositor>(&handle),
            toplevel: None,
        };
        let (socket, server) = UnixStream::pair().unwrap();
        socket.set_nonblocking(true).unwrap();
        let client = handle
            .insert_client(server, Arc::new(TestClient::default()))
            .unwrap();
        let compositor = client
            .create_resource::<WlCompositor, _, TestCompositor>(&handle, 6, GlobalData)
            .unwrap();
        let shell = client
            .create_resource::<XdgWmBase, _, TestCompositor>(
                &handle,
                version,
                XdgWmBaseUserData::default(),
            )
            .unwrap();
        let mut fixture = Self {
            display,
            state,
            socket,
            compositor_id: compositor.id().protocol_id(),
            shell_id: shell.id().protocol_id(),
        };
        // wl_compositor.create_surface(2), xdg_wm_base.get_xdg_surface(3, 2),
        // xdg_surface.get_toplevel(4). No registry/client library is needed.
        fixture.request(compositor.id().protocol_id(), 0, &[2]);
        fixture.request(shell.id().protocol_id(), 2, &[3, 2]);
        fixture.request(3, 1, &[4]);
        assert!(fixture.state.toplevel.is_some());
        fixture.events();
        fixture
    }

    fn request(&mut self, object: u32, opcode: u32, args: &[u32]) {
        let header = ((8 + args.len() as u32 * 4) << 16) | opcode;
        for word in [object, header].iter().chain(args) {
            self.socket.write_all(&word.to_ne_bytes()).unwrap();
        }
        self.display.dispatch_clients(&mut self.state).unwrap();
    }

    fn toplevel(&self) -> &ToplevelSurface {
        self.state.toplevel.as_ref().unwrap()
    }

    fn configure(&mut self, size: (i32, i32)) -> Vec<Vec<u32>> {
        configure_mobile_toplevel(self.toplevel(), size.into());
        self.events()
    }

    fn events(&mut self) -> Vec<Vec<u32>> {
        self.display.flush_clients().unwrap();
        let mut bytes = Vec::new();
        let mut buffer = [0; 4096];
        loop {
            match self.socket.read(&mut buffer) {
                Ok(0) => break,
                Ok(count) => bytes.extend_from_slice(&buffer[..count]),
                Err(error) if error.kind() == ErrorKind::WouldBlock => break,
                Err(error) => panic!("reading protocol events: {error}"),
            }
        }
        let words: Vec<u32> = bytes
            .chunks_exact(4)
            .map(|word| u32::from_ne_bytes(word.try_into().unwrap()))
            .collect();
        let mut events = Vec::new();
        let mut offset = 0;
        while offset < words.len() {
            let len = (words[offset + 1] >> 16) as usize / 4;
            assert!(len >= 2 && offset + len <= words.len());
            events.push(words[offset..offset + len].to_vec());
            offset += len;
        }
        events
    }
}

const EDGES: [xdg_toplevel::State; 4] = [
    xdg_toplevel::State::TiledLeft,
    xdg_toplevel::State::TiledRight,
    xdg_toplevel::State::TiledTop,
    xdg_toplevel::State::TiledBottom,
];

fn configure_event(events: &[Vec<u32>]) -> &Vec<u32> {
    events
        .iter()
        .find(|event| event[0] == 4 && event[1] & 0xffff == 0)
        .expect("xdg_toplevel.configure")
}

#[test]
fn initial_configure_sets_exact_size_and_all_tiled_edges() {
    let mut fixture = Fixture::new(2);
    let events = fixture.configure((360, 752));
    let event = configure_event(&events);
    assert_eq!(&event[2..5], &[360, 752, 16]);
    assert_eq!(&event[5..], &EDGES.map(|edge| edge as u32));
}

#[test]
fn unchanged_size_repairs_states_and_preserves_unrelated_pending_bits() {
    let mut fixture = Fixture::new(2);
    let toplevel = fixture.toplevel();
    toplevel.with_pending_state(|pending| {
        pending.size = Some((360, 752).into());
        pending.states.set(xdg_toplevel::State::Fullscreen);
        pending.states.set(xdg_toplevel::State::Maximized);
        pending.states.set(xdg_toplevel::State::Activated);
    });
    toplevel.send_pending_configure().unwrap();
    fixture.events();
    fixture.toplevel().with_pending_state(|pending| {
        pending.states.set(xdg_toplevel::State::Resizing);
        pending.bounds = Some((400, 800).into());
    });
    let events = fixture.configure((360, 752));
    let event = configure_event(&events);
    assert_eq!(&event[2..4], &[360, 752]);
    let states = &event[5..];
    for state in EDGES.into_iter().chain([
        xdg_toplevel::State::Activated,
        xdg_toplevel::State::Resizing,
    ]) {
        assert!(states.contains(&(state as u32)));
    }
    assert!(!states.contains(&(xdg_toplevel::State::Fullscreen as u32)));
    assert!(!states.contains(&(xdg_toplevel::State::Maximized as u32)));
    fixture.toplevel().with_pending_state(|pending| {
        assert_eq!(pending.bounds, Some((400, 800).into()));
    });
    assert!(fixture.configure((360, 752)).is_empty());
}

#[test]
fn correct_sent_pending_and_acked_states_do_not_churn() {
    let mut fixture = Fixture::new(2);
    let events = fixture.configure((360, 752));
    let serial = events.iter().find(|event| event[0] == 3).unwrap()[2];
    // Correct last-sent state, even before ACK, needs no repeated configure.
    assert!(fixture.configure((360, 752)).is_empty());
    // with_pending_state may leave an equal server_pending behind; it must
    // still compare equal and never force another configure.
    assert!(fixture.configure((360, 752)).is_empty());
    fixture.request(3, 4, &[serial]);
    assert!(fixture.configure((360, 752)).is_empty());
    // Also exercise pending-but-not-sent mobile state on an existing client.
    fixture.toplevel().with_pending_state(|pending| {
        pending.states.unset(xdg_toplevel::State::TiledTop);
    });
    fixture.toplevel().send_pending_configure().unwrap();
    fixture.events();
    fixture.toplevel().with_pending_state(|pending| {
        for edge in EDGES {
            pending.states.set(edge);
        }
    });
    configure_event(&fixture.configure((360, 752)));
    assert!(fixture.configure((360, 752)).is_empty());
}

#[test]
fn legacy_client_filters_tiled_edges_without_configure_churn() {
    let mut fixture = Fixture::new(1);
    fixture.toplevel().with_pending_state(|pending| {
        pending.states.set(xdg_toplevel::State::Activated);
    });
    let events = fixture.configure((360, 752));
    let event = configure_event(&events);
    assert_eq!(&event[2..5], &[360, 752, 4]);
    assert_eq!(&event[5..], &[xdg_toplevel::State::Activated as u32]);
    // Internally the complete state is retained; filtering only affects wire
    // encoding, so legacy clients do not cause perpetual reconciliation.
    assert!(fixture.configure((360, 752)).is_empty());
}

#[test]
fn self_managed_inset_size_is_not_reduced_by_state_reconciliation() {
    let mut fixture = Fixture::new(2);
    let root = fixture.toplevel().wl_surface();
    with_states(root, |states| {
        states
            .data_map
            .insert_if_missing_threadsafe(|| SelfManagedInsets);
    });
    assert!(self_managed(root));
    let events = fixture.configure((360, 800));
    let event = configure_event(&events);
    assert_eq!(&event[2..4], &[360, 800]);
    assert_eq!(&event[5..], &EDGES.map(|edge| edge as u32));
}

#[test]
fn dialog_keeps_parent_and_receives_mobile_states_and_size() {
    let mut fixture = Fixture::new(2);
    let parent = fixture.toplevel().clone();
    fixture.request(fixture.compositor_id, 0, &[5]);
    fixture.request(fixture.shell_id, 2, &[6, 5]);
    fixture.request(6, 1, &[7]);
    fixture.request(7, 1, &[4]); // xdg_toplevel.set_parent
    let dialog = fixture.toplevel();
    assert_eq!(dialog.parent().as_ref(), Some(parent.wl_surface()));
    configure_mobile_toplevel(dialog, (360, 752).into());
    assert_eq!(dialog.parent().as_ref(), Some(parent.wl_surface()));
    let events = fixture.events();
    let event = events.iter().find(|event| event[0] == 7).unwrap();
    assert_eq!(&event[2..4], &[360, 752]);
    assert_eq!(&event[5..], &EDGES.map(|edge| edge as u32));
    assert!(fixture.configure((360, 752)).is_empty());
}
