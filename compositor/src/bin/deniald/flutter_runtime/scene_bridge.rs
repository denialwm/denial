//! Wayland scene and buffer synchronization into Flutter textures.

use super::*;

impl FlutterRuntime {
    pub fn sync_wayland_scene(
        &mut self,
        windows: Vec<wire::WindowDescription>,
        mut frames: Vec<ExternalTextureFrame>,
        restored_window_ids: &BTreeSet<u64>,
    ) -> Result<SyncedWaylandScene, Box<dyn Error>> {
        self.rebuild_texture_output_membership(&windows);
        let mut desired = mem::take(&mut self.scene_texture_ids);
        desired.clear();
        desired.reserve(frames.len());
        for frame in &frames {
            if frame.texture_id <= 0 || !desired.insert(frame.texture_id) {
                return Err("external texture identifiers must be unique and positive".into());
            }
        }

        // Both work collections retain their capacity across client buffer
        // commits; scene synchronization commonly runs at application frame
        // rate even when the window count is unchanged.
        let mut removed = mem::take(&mut self.scene_texture_id_scratch);
        removed.clear();
        removed.reserve(frames.len());
        // Update all sources under one short mutex acquisition. Taking this
        // lock once per surface caused avoidable platform/raster contention
        // for multi-window scenes.
        self.changed_texture_scratch.clear();
        self.handler
            .set_external_texture_sources(frames.drain(..), &mut self.changed_texture_scratch);
        self.stage_changed_textures();
        for texture_id in &desired {
            if self.registered_external_textures.insert(*texture_id) {
                self.host()
                    .engine()
                    .register_external_texture(*texture_id)?;
            }
        }

        // Publish metadata without authorizing a frame. Dart may express its
        // own AwaitVSync demand, while the matching texture sources remain
        // queued until the KMS frame clock collects the complete transaction.
        let (window_snapshot_changed, windows) = {
            let engine = self
                .host
                .as_ref()
                .expect("Flutter runtime is shutting down")
                .engine();
            let (update, recycled_windows) =
                self.wire.update_windows(windows, restored_window_ids)?;
            let changed = if let Some(update) = update {
                engine.send_platform_message(wire::TO_FLUTTER_CHANNEL, update)?;
                true
            } else {
                false
            };
            (changed, recycled_windows)
        };
        if window_snapshot_changed {
            let next_windows = window_texture_map(self.wire.window_descriptions());
            let retired = self
                .window_close_texture_leases
                .publish(next_windows, Instant::now());
            if retired.lease_count > 0 {
                warn!(
                    count = retired.lease_count,
                    limit = MAX_RETAINED_WINDOW_CLOSE_LEASES,
                    "retired old window close-frame leases at the safety limit"
                );
            }
        }
        removed.extend(
            self.registered_external_textures
                .difference(&desired)
                .filter(|texture_id| {
                    self.screenshot_texture_id != Some(**texture_id)
                        && !self
                            .window_close_texture_leases
                            .retains_texture(**texture_id)
                })
                .copied(),
        );
        for texture_id in removed.drain(..) {
            self.host()
                .engine()
                .unregister_external_texture(texture_id)?;
            self.handler.remove_external_texture_source(texture_id);
            self.pending_frame_texture_ids
                .retain(|pending| *pending != texture_id);
            self.registered_external_textures.remove(&texture_id);
        }

        self.scene_texture_ids = desired;
        self.scene_texture_id_scratch = removed;
        Ok(SyncedWaylandScene {
            windows,
            textures: frames,
            window_snapshot_changed,
        })
    }

    /// Replace sources for textures whose published surface layout is
    /// unchanged. Registration and Dart window metadata remain untouched.
    pub fn sync_wayland_buffers(
        &mut self,
        mut frames: Vec<ExternalTextureFrame>,
    ) -> Result<Vec<ExternalTextureFrame>, Box<dyn Error>> {
        let mut texture_ids = mem::take(&mut self.scene_texture_id_scratch);
        texture_ids.clear();
        for frame in &frames {
            if frame.texture_id <= 0
                || !self.scene_texture_ids.contains(&frame.texture_id)
                || texture_ids.contains(&frame.texture_id)
            {
                self.scene_texture_id_scratch = texture_ids;
                return Err(
                    "buffer-only updates must target unique published external textures".into(),
                );
            }
            texture_ids.push(frame.texture_id);
        }

        self.changed_texture_scratch.clear();
        self.handler
            .set_external_texture_sources(frames.drain(..), &mut self.changed_texture_scratch);
        self.stage_changed_textures();
        texture_ids.clear();
        self.scene_texture_id_scratch = texture_ids;
        Ok(frames)
    }

    pub fn synced_window_ids(&self) -> impl Iterator<Item = u64> + '_ {
        self.wire.window_ids()
    }
}
