use super::{SceneSyncState, WindowEventDisposition, window_event_disposition};

#[test]
fn initial_scene_is_published_exactly_once() {
    let mut state = SceneSyncState::default();
    let initial = state
        .pending_metadata_revision()
        .expect("initial publication");
    state.mark_metadata_synchronized(initial, 0);

    assert_eq!(state.pending_metadata_revision(), None);
    assert_eq!(state.pending_buffer_revision(), None);
}

#[test]
fn change_after_snapshot_is_not_acknowledged_by_older_sync() {
    let mut state = SceneSyncState::default();
    let snapshot = state
        .pending_metadata_revision()
        .expect("initial publication");
    state.mark_dirty();
    state.mark_metadata_synchronized(snapshot, 0);

    assert_eq!(state.pending_metadata_revision(), Some(1));
}

#[test]
fn runtime_restart_republishes_an_unchanged_scene() {
    let mut state = SceneSyncState::default();
    let initial = state
        .pending_metadata_revision()
        .expect("initial publication");
    state.mark_metadata_synchronized(initial, 0);
    state.invalidate_runtime();

    assert_eq!(state.pending_metadata_revision(), Some(initial));
}

#[test]
fn buffer_only_changes_do_not_republish_metadata() {
    let mut state = SceneSyncState::default();
    state.mark_metadata_synchronized(0, 0);
    state.mark_surfaces_dirty([7, 9]);

    assert_eq!(state.pending_metadata_revision(), None);
    assert_eq!(state.pending_buffer_revision(), Some(1));
    let mut dirty = state.dirty_surface_ids(1).collect::<Vec<_>>();
    dirty.sort_unstable();
    assert_eq!(dirty, [7, 9]);

    state.mark_buffers_synchronized(1);
    assert_eq!(state.pending_buffer_revision(), None);
    assert_eq!(state.dirty_surface_ids(1).count(), 0);
}

#[test]
fn older_buffer_acknowledgement_keeps_newer_surface_work() {
    let mut state = SceneSyncState::default();
    state.mark_metadata_synchronized(0, 0);
    state.mark_surfaces_dirty([7]);
    let snapshot = state.pending_buffer_revision().unwrap();
    state.mark_surfaces_dirty([9]);
    state.mark_buffers_synchronized(snapshot);

    assert_eq!(state.pending_buffer_revision(), Some(2));
    assert_eq!(state.dirty_surface_ids(2).collect::<Vec<_>>(), [9]);
}

#[test]
fn pre_buffer_window_events_wait_for_the_first_published_snapshot() {
    assert_eq!(
        window_event_disposition(false, true),
        WindowEventDisposition::Retain
    );
    assert_eq!(
        window_event_disposition(true, true),
        WindowEventDisposition::Send
    );
}

#[test]
fn only_events_for_destroyed_toplevels_are_dropped() {
    assert_eq!(
        window_event_disposition(false, false),
        WindowEventDisposition::Drop
    );
}
