//! Wayland scene snapshots, texture damage, input layout, and cursor synchronization.

use super::*;

pub(super) fn collect_flutter_output_damage(
    runtime: &mut flutter_runtime::FlutterRuntime,
    scheduler: &mut frame_scheduler::FrameScheduler,
) {
    let updates = runtime.take_output_updates();
    for (output, texture_ids) in &updates {
        scheduler.mark_app_dirty(*output, texture_ids.iter().copied());
    }
    runtime.recycle_output_updates(updates);
}

#[cfg(feature = "flutter")]
pub(super) fn try_synchronize_flutter_buffers(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) -> Result<bool, Box<dyn Error>> {
    if events.scene_sync.pending_metadata_revision().is_some()
        || events
            .native_app_plugins
            .as_ref()
            .is_some_and(native_app_plugin::NativeAppPluginManager::scene_dirty)
    {
        return Ok(false);
    }

    let Some(buffer_revision) = events.scene_sync.pending_buffer_revision() else {
        return Ok(true);
    };
    let textures = if let Some(frontend) = events.wayland.as_mut() {
        let scene_sync = &events.scene_sync;
        frontend.flutter_dirty_textures(scene_sync.dirty_surface_ids(buffer_revision))
    } else {
        None
    };
    let Some(textures) = textures else {
        return Ok(false);
    };

    let textures = runtime.sync_wayland_buffers(textures)?;
    if let Some(frontend) = events.wayland.as_mut() {
        frontend.recycle_flutter_dirty_textures(textures);
    }
    events.scene_sync.mark_buffers_synchronized(buffer_revision);
    Ok(true)
}

#[cfg(feature = "flutter")]
pub(super) fn synchronize_flutter_scene(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    let mut metadata_revision = events.scene_sync.pending_metadata_revision();
    let pending_buffer_revision = events.scene_sync.pending_buffer_revision();
    let native_scene_dirty = events
        .native_app_plugins
        .as_ref()
        .is_some_and(native_app_plugin::NativeAppPluginManager::scene_dirty);
    if native_scene_dirty && metadata_revision.is_none() {
        events.scene_sync.mark_dirty();
        metadata_revision = events.scene_sync.pending_metadata_revision();
    }
    if metadata_revision.is_none() && pending_buffer_revision.is_none() && !native_scene_dirty {
        return Ok(());
    }

    if metadata_revision.is_none() && try_synchronize_flutter_buffers(runtime, events)? {
        return Ok(());
    }

    if metadata_revision.is_none() {
        // The surface index changed before this queued source could be
        // resolved. Fall back within the same dispatch and repair both the
        // metadata snapshot and texture registration set.
        events.scene_sync.mark_dirty();
        metadata_revision = events.scene_sync.pending_metadata_revision();
    }

    let revision = metadata_revision.expect("metadata fallback must be pending");
    let buffer_revision = events.scene_sync.buffer_revision();
    // Building the live-ID set walks every toplevel. It is only needed to
    // classify events which arrived before their first renderable buffer;
    // the steady-state scene publication normally has none.
    let live_window_ids = (!events.pending_unpublished_window_events.is_empty()).then(|| {
        events
            .wayland
            .as_ref()
            .map(wayland_frontend::WaylandFrontend::live_toplevel_ids)
            .unwrap_or_default()
    });
    let (mut windows, mut textures) = events
        .wayland
        .as_mut()
        .map(wayland_frontend::WaylandFrontend::flutter_scene)
        .transpose()?
        .unwrap_or_default();
    if let Some(manager) = events.native_app_plugins.as_ref() {
        let (native_windows, native_textures) = manager.scene();
        windows.extend(native_windows);
        textures.extend(native_textures);
    }
    let flutter_runtime::SyncedWaylandScene {
        windows,
        textures,
        window_snapshot_changed,
    } = runtime.sync_wayland_scene(revision, windows, textures, &events.restored_window_ids)?;
    if window_snapshot_changed {
        // Buffer-only commits take the texture-source fast path above. Rehash
        // IDs only after accepting a new authoritative metadata revision.
        let mut published_window_ids = std::mem::take(&mut events.published_window_ids);
        published_window_ids.clear();
        published_window_ids.extend(runtime.synced_window_ids());
        events.published_window_ids = published_window_ids;
        let published_window_ids = &events.published_window_ids;
        events
            .restored_window_ids
            .retain(|window_id| published_window_ids.contains(window_id));
    }
    if let Some(frontend) = events.wayland.as_mut() {
        frontend.recycle_flutter_scene(windows, textures);
    }
    if let Some(manager) = events.native_app_plugins.as_mut() {
        manager.mark_scene_synchronized();
    }
    // A later Wayland commit has a newer revision, so acknowledging this
    // captured revision cannot erase work that arrived while Flutter/KMS was
    // processing the previous frame.
    events
        .scene_sync
        .mark_metadata_synchronized(revision, buffer_revision);
    if events.pending_unpublished_window_events.is_empty() {
        return Ok(());
    }
    // Events for a freshly mapped window were deferred because Dart could not
    // resolve that ID before this snapshot. Preserve their FIFO order and
    // discard only windows that disappeared before they were ever published.
    let mut unpublished = events.pending_unpublished_window_events.drain_events();
    for event in unpublished.drain(..) {
        match window_event_disposition(
            events.published_window_ids.contains(&event.window_id()),
            live_window_ids
                .as_ref()
                .is_some_and(|window_ids| window_ids.contains(&event.window_id())),
        ) {
            WindowEventDisposition::Send => send_flutter_window_event(runtime, event)?,
            // A newly mapped toplevel can legitimately have no renderable
            // buffer yet. Keep its ordered events until a later commit makes
            // it publishable; discard only IDs that are no longer alive.
            WindowEventDisposition::Retain => {
                events.pending_unpublished_window_events.push(event);
            }
            WindowEventDisposition::Drop => {}
        }
    }
    events
        .pending_unpublished_window_events
        .recycle_drained(unpublished);
    Ok(())
}

#[cfg(feature = "flutter")]
pub(super) fn synchronize_flutter_input_layout(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    let Some(layout) = runtime.take_input_layout_update() else {
        return Ok(());
    };
    if let Some(manager) = events.native_app_plugins.as_mut()
        && let Err(error) = manager.apply_input_layout(&layout)
    {
        warn!(%error, "could not apply native plugin input visibility");
    }
    let Some(frontend) = events.wayland.as_mut() else {
        runtime.recycle_input_layout(layout);
        return Ok(());
    };
    let (previous, sampling_changed, routing_changed) = frontend.install_input_layout(layout);
    if let Some(previous) = previous {
        runtime.recycle_input_layout(previous);
    }
    if sampling_changed {
        // `expects_sample` is part of the external-texture mailbox contract,
        // not the Dart window metadata. Republish the scene when a window
        // enters or leaves Flutter's sampled set even if no client committed
        // another buffer during the visibility transition.
        events.scene_sync.mark_dirty();
    }
    if routing_changed {
        wayland_frontend::reconcile_flutter_pointer_route(events);
    }
    // InputLayout owns shell keyboard capture. Publish again after applying
    // it so releasing a local Flutter surface exposes an already-active
    // Wayland editor in this iteration instead of waiting for unrelated input.
    publish_software_keyboard_state(runtime, events)
}

#[cfg(feature = "flutter")]
pub(super) fn synchronize_wayland_cursor(
    runtime: &mut flutter_runtime::FlutterRuntime,
    events: &mut RuntimeState,
) -> Result<(), Box<dyn Error>> {
    if let Some(shape) = runtime.take_mouse_cursor_request()
        && let Some(frontend) = events.wayland.as_mut()
    {
        frontend.request_flutter_cursor_shape(shape);
    }
    let (shape, position) = events.wayland.as_mut().map_or((None, None), |frontend| {
        (
            frontend.take_cursor_shape_update(),
            frontend.take_cursor_position_update(),
        )
    });
    if let Some(shape) = shape {
        runtime.send_cursor_shape(shape)?;
    }
    if let Some((x, y)) = position {
        runtime.send_cursor_position(x, y)?;
    }
    Ok(())
}
