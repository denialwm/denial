//! Wayland scene and buffer synchronization into Flutter textures.

use super::*;

fn accept_scene_texture_identifier(texture_id: i64, desired: &mut HashSet<i64>) -> bool {
    texture_id > 0 && desired.insert(texture_id)
}

/// Flutter may still be drawing a scene that names a merged native window
/// image, so `removed` keeps such an image only once its grace period has
/// passed; until then it waits in `retiring`. Publishing it again cancels
/// the retirement.
fn defer_native_texture_retirement(
    removed: &mut Vec<i64>,
    retiring: &mut HashMap<i64, Instant>,
    desired: &HashSet<i64>,
    now: Instant,
) {
    retiring.retain(|texture_id, _| !desired.contains(texture_id));
    removed.retain(|texture_id| {
        !renderer::native_window::is_native_window_texture(*texture_id)
            || *retiring
                .entry(*texture_id)
                .or_insert(now + NATIVE_TEXTURE_RETIREMENT_GRACE)
                <= now
    });
}

/// Every texture a window draws (its own, its client's, its surfaces and
/// popups) under the window's app id, for app looks.
fn texture_apps(windows: &[wire::WindowDescription]) -> HashMap<i64, Arc<str>> {
    let mut apps = HashMap::new();
    for window in windows.iter().filter(|window| !window.app_id.is_empty()) {
        let app: Arc<str> = Arc::from(window.app_id.as_str());
        let textures = std::iter::once(window.texture_id)
            .chain(window.client_texture.map(|client| client.texture_id))
            .chain(window.surfaces.iter().map(|surface| surface.texture_id));
        for texture_id in textures.filter(|texture_id| *texture_id > 0) {
            apps.insert(texture_id as i64, Arc::clone(&app));
        }
    }
    apps
}

impl FlutterRuntime {
    /// The textures of an app's windows, to sample again after its look changes.
    pub(crate) fn app_texture_ids(&self, app_id: &str) -> Vec<i64> {
        self.handler.app_texture_ids(app_id)
    }

    pub(crate) fn published_window_descriptions(&self) -> &[wire::WindowDescription] {
        self.wire.window_descriptions()
    }
    pub fn sync_wayland_scene(
        &mut self,
        metadata_revision: u64,
        mut windows: Vec<wire::WindowDescription>,
        mut frames: Vec<ExternalTextureFrame>,
        kept_texture_ids: &[u64],
        restored_window_ids: &BTreeSet<u64>,
    ) -> Result<SyncedWaylandScene, Box<dyn Error>> {
        self.changed_texture_scratch.clear();
        self.handler.update_native_window_plans(
            &mut windows,
            &frames,
            &mut self.changed_texture_scratch,
        );
        self.rebuild_texture_output_membership(&windows);
        self.reinstall_cursor_texture_membership();
        let mut desired = mem::take(&mut self.scene_texture_ids);
        desired.clear();
        desired.reserve(frames.len());
        let supplied_frame_count = frames.len();
        frames.retain(|frame| {
            if !accept_scene_texture_identifier(frame.texture_id, &mut desired) {
                if frame.texture_id <= 0 {
                    warn!(
                        texture_id = frame.texture_id,
                        "discarded a Wayland scene frame with an invalid texture identifier"
                    );
                } else {
                    warn!(
                        texture_id = frame.texture_id,
                        "discarded a duplicate Wayland scene texture frame"
                    );
                }
                return false;
            }
            true
        });
        if frames.len() != supplied_frame_count {
            warn!(
                supplied = supplied_frame_count,
                accepted = frames.len(),
                "recovered from invalid Wayland scene texture bookkeeping"
            );
        }

        for window in &windows {
            if let Some(client) = window.client_texture {
                desired.insert(client.texture_id as i64);
            }
        }
        // Frozen windows keep the frame their textures hold.
        desired.extend(kept_texture_ids.iter().map(|texture_id| *texture_id as i64));
        // Both work collections retain their capacity across client buffer
        // commits; scene synchronization commonly runs at application frame
        // rate even when the window count is unchanged.
        let mut removed = mem::take(&mut self.scene_texture_id_scratch);
        removed.clear();
        removed.reserve(frames.len());
        // Update all sources under one short mutex acquisition. Taking this
        // lock once per surface caused avoidable platform/raster contention
        // for multi-window scenes.
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
                self.wire
                    .update_windows(metadata_revision, windows, restored_window_ids)?;
            let changed = if let Some(update) = update {
                engine.send_platform_message(wire::TO_FLUTTER_CHANNEL, update)?;
                true
            } else {
                false
            };
            (changed, recycled_windows)
        };
        if window_snapshot_changed {
            self.handler
                .set_texture_apps(texture_apps(self.wire.window_descriptions()));
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
                        && self.fingerprint_scene.texture != Some(**texture_id)
                        && !self.retains_cursor_texture(**texture_id)
                        && !self
                            .window_close_texture_leases
                            .retains_texture(**texture_id)
                })
                .copied(),
        );
        defer_native_texture_retirement(
            &mut removed,
            &mut self.retiring_native_textures,
            &desired,
            Instant::now(),
        );
        for texture_id in removed.drain(..) {
            self.retiring_native_textures.remove(&texture_id);
            self.unregister_scene_texture(texture_id)?;
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

    fn unregister_scene_texture(&mut self, texture_id: i64) -> Result<(), Box<dyn Error>> {
        self.unregister_external_texture(texture_id)?;
        self.pending_frame_texture_ids
            .retain(|pending| *pending != texture_id);
        self.registered_external_textures.remove(&texture_id);
        Ok(())
    }

    /// Unregisters the retiring merged native window images whose grace
    /// period has passed and which the scene has not published again.
    pub(super) fn expire_retiring_native_textures(
        &mut self,
        now: Instant,
    ) -> Result<(), Box<dyn Error>> {
        if !self
            .retiring_native_textures
            .values()
            .any(|deadline| *deadline <= now)
        {
            return Ok(());
        }
        let due = self
            .retiring_native_textures
            .iter()
            .filter(|(_, deadline)| **deadline <= now)
            .map(|(texture_id, _)| *texture_id)
            .collect::<Vec<_>>();
        for texture_id in due {
            self.retiring_native_textures.remove(&texture_id);
            if self.scene_texture_ids.contains(&texture_id)
                || !self.registered_external_textures.contains(&texture_id)
                || self.window_close_texture_leases.retains_texture(texture_id)
            {
                continue;
            }
            self.unregister_scene_texture(texture_id)?;
        }
        Ok(())
    }

    pub(crate) fn native_client_composition_stats(&self) -> serde_json::Value {
        self.handler.native_client_composition_stats()
    }

    pub(crate) fn take_native_window_fallback(&self) -> bool {
        self.handler.take_native_window_fallback()
    }

    pub fn synced_window_ids(&self) -> impl Iterator<Item = u64> + '_ {
        self.wire.window_ids()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scene_texture_identifiers_reject_non_positive_and_duplicate_values() {
        let mut desired = HashSet::new();
        assert!(!accept_scene_texture_identifier(-1, &mut desired));
        assert!(!accept_scene_texture_identifier(0, &mut desired));
        assert!(accept_scene_texture_identifier(37, &mut desired));
        assert!(accept_scene_texture_identifier(39, &mut desired));
        assert!(!accept_scene_texture_identifier(39, &mut desired));
        assert!(accept_scene_texture_identifier(41, &mut desired));
        assert_eq!(desired, HashSet::from([37, 39, 41]));
    }

    #[test]
    fn merged_native_images_retire_after_the_grace_period() {
        const MERGED: i64 = (1 << 62) | 26;
        const SURFACE: i64 = 41;
        let start = Instant::now();
        let mut retiring = HashMap::new();

        // A surface texture leaves at once; the merged image waits.
        let mut removed = vec![SURFACE, MERGED];
        defer_native_texture_retirement(&mut removed, &mut retiring, &HashSet::new(), start);
        assert_eq!(removed, [SURFACE]);
        assert!(retiring.contains_key(&MERGED));

        // Later scene syncs inside the grace period keep it.
        let mut removed = vec![MERGED];
        let early = start + NATIVE_TEXTURE_RETIREMENT_GRACE / 2;
        defer_native_texture_retirement(&mut removed, &mut retiring, &HashSet::new(), early);
        assert!(removed.is_empty());

        let mut removed = vec![MERGED];
        let due = start + NATIVE_TEXTURE_RETIREMENT_GRACE;
        defer_native_texture_retirement(&mut removed, &mut retiring, &HashSet::new(), due);
        assert_eq!(removed, [MERGED]);
    }

    #[test]
    fn republishing_a_merged_native_image_cancels_its_retirement() {
        const MERGED: i64 = (1 << 62) | 26;
        let start = Instant::now();
        let mut retiring = HashMap::new();
        let mut removed = vec![MERGED];
        defer_native_texture_retirement(&mut removed, &mut retiring, &HashSet::new(), start);
        assert!(retiring.contains_key(&MERGED));

        let mut removed = Vec::new();
        let desired = HashSet::from([MERGED]);
        defer_native_texture_retirement(&mut removed, &mut retiring, &desired, start);
        assert!(retiring.is_empty());

        // Leaving again starts a new grace period.
        let later = start + NATIVE_TEXTURE_RETIREMENT_GRACE;
        let mut removed = vec![MERGED];
        defer_native_texture_retirement(&mut removed, &mut retiring, &HashSet::new(), later);
        assert!(removed.is_empty());
    }
}
