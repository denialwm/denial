use super::*;

#[test]
fn pending_window_focus_is_last_writer_wins() {
    let mut queue = PendingWindowEventQueue::default();
    queue.push(PendingWindowEvent::Activated(11));
    queue.push(PendingWindowEvent::Action(11, wire::WindowAction::Maximize));
    queue.push(PendingWindowEvent::Activated(22));

    assert_eq!(
        queue.as_slice(),
        &[
            PendingWindowEvent::Action(11, wire::WindowAction::Maximize),
            PendingWindowEvent::Activated(22),
        ]
    );
}

#[test]
fn pending_window_updates_and_safe_actions_are_compacted() {
    let placement = |x| {
        PendingWindowEvent::Placement(wire::WindowPlacement {
            window_id: 7,
            monitor_id: 1,
            workspace_id: 1,
            phase: wire::WindowPlacementPhase::Update,
            change: wire::WindowPlacementChange::Move,
            geometry: wire::WindowGeometry {
                x,
                y: 0.0,
                width: 640.0,
                height: 480.0,
            },
        })
    };
    let mut queue = PendingWindowEventQueue::default();
    queue.push(placement(10.0));
    queue.push(placement(20.0));
    queue.push(PendingWindowEvent::Action(7, wire::WindowAction::Maximize));
    queue.push(PendingWindowEvent::Action(7, wire::WindowAction::Maximize));
    queue.push(PendingWindowEvent::Action(
        7,
        wire::WindowAction::ToggleMaximize,
    ));
    queue.push(PendingWindowEvent::Action(
        7,
        wire::WindowAction::ToggleMaximize,
    ));
    queue.push(PendingWindowEvent::Action(
        7,
        wire::WindowAction::ToggleFullscreen,
    ));
    queue.push(PendingWindowEvent::Action(
        7,
        wire::WindowAction::ToggleFullscreen,
    ));

    assert_eq!(
        queue.as_slice(),
        &[
            placement(20.0),
            PendingWindowEvent::Action(7, wire::WindowAction::Maximize),
        ]
    );
}

#[test]
fn pending_window_queue_has_a_hard_memory_bound() {
    let mut queue = PendingWindowEventQueue::default();
    for window_id in 0..=MAX_PENDING_WINDOW_EVENTS as u64 {
        queue.push(PendingWindowEvent::Action(
            window_id,
            wire::WindowAction::Restore,
        ));
    }

    assert_eq!(queue.as_slice().len(), MAX_PENDING_WINDOW_EVENTS);
    assert!(queue.overflow_reported);
    assert_eq!(queue.drain_events().len(), MAX_PENDING_WINDOW_EVENTS);
    assert!(!queue.overflow_reported);
}

#[test]
fn drained_window_event_storage_returns_to_the_producer() {
    let mut queue = PendingWindowEventQueue::default();
    queue.push(PendingWindowEvent::Activated(11));
    let allocation = queue.events.as_ptr();

    let mut drained = queue.drain_events();
    assert_eq!(drained.as_ptr(), allocation);
    drained.clear();
    queue.recycle_drained(drained);

    queue.push(PendingWindowEvent::Activated(12));
    assert_eq!(queue.events.as_ptr(), allocation);
}
