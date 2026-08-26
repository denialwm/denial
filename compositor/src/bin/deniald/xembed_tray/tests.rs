use super::*;
use x11rb::protocol::xproto::MapState;

#[test]
fn worker_events_publish_a_coalesced_nonempty_signal() {
    let (raw_sender, receiver) = mpsc::sync_channel(2);
    let pending = Arc::new(AtomicBool::new(false));
    let sender = XEmbedEventSender {
        sender: raw_sender,
        pending: Arc::clone(&pending),
    };

    assert!(sender.try_send(XEmbedTrayEvent {
        kind: XEmbedTrayEventKind::Removed,
        window_id: 42,
        icon: None,
    }));
    assert!(pending.swap(false, Ordering::AcqRel));
    assert_eq!(receiver.try_recv().unwrap().window_id, 42);
    assert!(!pending.load(Ordering::Acquire));
}

#[test]
fn extracts_arbitrary_x11_color_masks() {
    assert_eq!(extract_channel(0x00ab_0000, 0x00ff_0000), 0xab);
    assert_eq!(extract_channel(0x0000_7c00, 0x0000_f800), 123);
    assert_eq!(extract_channel(0xffff_ffff, 0), 0);
}

#[test]
fn hosts_and_activates_an_xembed_icon() {
    let Some(display) = std::env::var_os("DENIAL_XEMBED_TEST_DISPLAY") else {
        return;
    };
    let tray = XEmbedTray::start(display.clone()).unwrap();
    let display = display.into_string().unwrap();
    let (client, screen_index) = x11rb::connect(Some(&display)).unwrap();
    let screen = &client.setup().roots[screen_index];
    let selection = intern(&client, "_NET_SYSTEM_TRAY_S0").unwrap();
    let opcode = intern(&client, "_NET_SYSTEM_TRAY_OPCODE").unwrap();
    let net_wm_name = intern(&client, "_NET_WM_NAME").unwrap();
    let utf8_string = intern(&client, "UTF8_STRING").unwrap();
    let xembed = intern(&client, "_XEMBED").unwrap();
    let xembed_info = intern(&client, "_XEMBED_INFO").unwrap();
    let tray_visual_atom = intern(&client, "_NET_SYSTEM_TRAY_VISUAL").unwrap();
    let owner = client
        .get_selection_owner(selection)
        .unwrap()
        .reply()
        .unwrap()
        .owner;
    assert_ne!(owner, NONE);

    let icon_visual = client
        .get_property(false, owner, tray_visual_atom, AtomEnum::VISUALID, 0, 1)
        .unwrap()
        .reply()
        .unwrap()
        .value32()
        .unwrap()
        .next()
        .unwrap();
    let icon_depth = screen
        .allowed_depths
        .iter()
        .find(|depth| {
            depth
                .visuals
                .iter()
                .any(|visual| visual.visual_id == icon_visual)
        })
        .unwrap()
        .depth;
    let icon_colormap = client.generate_id().unwrap();
    client
        .create_colormap(ColormapAlloc::NONE, icon_colormap, screen.root, icon_visual)
        .unwrap();

    let icon = client.generate_id().unwrap();
    client
        .create_window(
            icon_depth,
            icon,
            screen.root,
            0,
            0,
            16,
            16,
            0,
            WindowClass::INPUT_OUTPUT,
            icon_visual,
            &CreateWindowAux::new()
                .background_pixel(u32::MAX)
                .border_pixel(0)
                .colormap(icon_colormap)
                .event_mask(EventMask::BUTTON_PRESS | EventMask::BUTTON_RELEASE),
        )
        .unwrap()
        .check()
        .unwrap();
    client
        .change_property8(
            PropMode::REPLACE,
            icon,
            net_wm_name,
            utf8_string,
            b"XEmbed test icon",
        )
        .unwrap()
        .check()
        .unwrap();
    client
        .change_property32(
            PropMode::REPLACE,
            icon,
            xembed_info,
            xembed_info,
            &[7, XEMBED_MAPPED],
        )
        .unwrap()
        .check()
        .unwrap();
    for _ in 0..MAX_REJECTED_ICONS {
        let invalid = client.generate_id().unwrap();
        client
            .send_event(
                false,
                owner,
                EventMask::NO_EVENT,
                ClientMessageEvent::new(
                    32,
                    owner,
                    opcode,
                    [CURRENT_TIME, SYSTEM_TRAY_REQUEST_DOCK, invalid, 0, 0],
                ),
            )
            .unwrap();
    }
    client
        .send_event(
            false,
            owner,
            EventMask::NO_EVENT,
            ClientMessageEvent::new(
                32,
                owner,
                opcode,
                [CURRENT_TIME, SYSTEM_TRAY_REQUEST_DOCK, icon, 0, 0],
            ),
        )
        .unwrap();
    client.flush().unwrap();

    let added = wait_until(Duration::from_secs(5), || {
        tray.try_event()
            .filter(|event| event.kind == XEmbedTrayEventKind::Added)
    })
    .unwrap_or_else(|| {
        let current_owner = client
            .get_selection_owner(selection)
            .unwrap()
            .reply()
            .unwrap()
            .owner;
        let parent = client.query_tree(icon).unwrap().reply().unwrap().parent;
        let map_state = client
            .get_window_attributes(icon)
            .unwrap()
            .reply()
            .unwrap()
            .map_state;
        panic!(
            "XEmbed tray did not publish the icon: owner={current_owner}, parent={parent}, map_state={map_state:?}",
        );
    });
    assert_eq!(added.kind, XEmbedTrayEventKind::Added);
    assert_eq!(added.window_id, icon);
    let added_icon = added.icon.unwrap();
    assert_eq!(added_icon.title, "XEmbed test icon");
    assert_eq!((added_icon.width, added_icon.height), (32, 32));
    assert_eq!(added_icon.rgba.len(), 32 * 32 * 4);

    let embedded = wait_until(Duration::from_secs(3), || {
        client
            .poll_for_event()
            .unwrap()
            .and_then(|event| match event {
                Event::ClientMessage(event) if event.type_ == xembed => Some(event),
                _ => None,
            })
    })
    .expect("XEmbed client did not receive EMBEDDED_NOTIFY");
    assert_eq!(embedded.data.as_data32()[1], XEMBED_EMBEDDED_NOTIFY);
    assert_eq!(embedded.data.as_data32()[4], XEMBED_VERSION);

    client
        .configure_window(icon, &ConfigureWindowAux::new().width(8).height(7))
        .unwrap()
        .check()
        .unwrap();
    client.flush().unwrap();
    let resized = wait_until(Duration::from_secs(3), || {
        tray.try_event()
            .filter(|event| event.kind == XEmbedTrayEventKind::Updated)
    })
    .expect("resized XEmbed icon did not publish a new snapshot");
    let resized_icon = resized.icon.unwrap();
    assert_eq!((resized_icon.width, resized_icon.height), (8, 7));
    assert_eq!(resized_icon.rgba.len(), 8 * 7 * 4);

    client
        .change_property32(PropMode::REPLACE, icon, xembed_info, xembed_info, &[7, 0])
        .unwrap()
        .check()
        .unwrap();
    client.flush().unwrap();
    let hidden = wait_until(Duration::from_secs(3), || {
        tray.try_event()
            .filter(|event| event.kind == XEmbedTrayEventKind::Removed)
    })
    .expect("hidden XEmbed icon was not removed from Flutter");
    assert_eq!(hidden.window_id, icon);
    assert_eq!(
        client
            .get_window_attributes(icon)
            .unwrap()
            .reply()
            .unwrap()
            .map_state,
        MapState::UNMAPPED,
    );

    client
        .change_property32(
            PropMode::REPLACE,
            icon,
            xembed_info,
            xembed_info,
            &[7, XEMBED_MAPPED],
        )
        .unwrap()
        .check()
        .unwrap();
    client.flush().unwrap();
    let remapped = wait_until(Duration::from_secs(3), || {
        tray.try_event()
            .filter(|event| event.kind == XEmbedTrayEventKind::Added)
    })
    .expect("remapped XEmbed icon was not restored to Flutter");
    assert_eq!(remapped.window_id, icon);
    assert_eq!(
        client
            .get_window_attributes(icon)
            .unwrap()
            .reply()
            .unwrap()
            .map_state,
        MapState::VIEWABLE,
    );

    tray.request_replay();
    let replayed = wait_until(Duration::from_secs(3), || {
        tray.try_event()
            .filter(|event| event.kind == XEmbedTrayEventKind::Added)
    })
    .expect("XEmbed icon snapshot was not replayed");
    assert_eq!(replayed.window_id, icon);

    for (action, button) in [
        (XEmbedTrayAction::Activate, ButtonIndex::M1),
        (XEmbedTrayAction::SecondaryActivate, ButtonIndex::M2),
        (XEmbedTrayAction::ContextMenu, ButtonIndex::M3),
    ] {
        assert!(tray.invoke(XEmbedTrayCommand {
            action,
            window_id: icon,
            x: 40,
            y: 24,
        }));
        let event = wait_until(Duration::from_secs(3), || {
            client
                .poll_for_event()
                .unwrap()
                .and_then(|event| match event {
                    Event::ButtonPress(event) => Some(event),
                    _ => None,
                })
        })
        .unwrap();
        assert_eq!(event.detail, u8::from(button));
        assert_eq!(event.root_x, 40);
        assert_eq!(event.root_y, 24);
    }

    drop(tray);
    client.destroy_window(icon).unwrap();
    client.free_colormap(icon_colormap).unwrap();
    client.flush().unwrap();
}

fn wait_until<T>(timeout: Duration, mut poll: impl FnMut() -> Option<T>) -> Option<T> {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if let Some(value) = poll() {
            return Some(value);
        }
        thread::sleep(Duration::from_millis(10));
    }
    None
}
