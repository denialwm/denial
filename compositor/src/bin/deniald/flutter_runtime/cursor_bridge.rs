//! Atomic client cursor state and acknowledgement-gated texture retirement.

use super::*;

fn take_acknowledged_cursor_retirements(
    retirements: &mut BTreeMap<u64, HashSet<i64>>,
    epoch: u64,
) -> (HashSet<i64>, HashSet<i64>) {
    let retained_later = retirements
        .range((epoch.saturating_add(1))..)
        .flat_map(|(_, ids)| ids.iter().copied())
        .collect::<HashSet<_>>();
    let acknowledged = retirements
        .range(..=epoch)
        .flat_map(|(_, ids)| ids.iter().copied())
        .collect::<HashSet<_>>();
    retirements.retain(|retired_epoch, _| *retired_epoch > epoch);
    (acknowledged, retained_later)
}

impl FlutterRuntime {
    pub fn sync_cursor_state(
        &mut self,
        mut state: wire::CursorStateDescription,
        mut frames: Vec<ExternalTextureFrame>,
        output: Option<OutputId>,
    ) -> Result<(wire::CursorStateDescription, Vec<ExternalTextureFrame>), Box<dyn Error>> {
        let mut desired = HashSet::with_capacity(frames.len());
        for frame in &frames {
            if frame.texture_id <= 0
                || !desired.insert(frame.texture_id)
                || self.scene_texture_ids.contains(&frame.texture_id)
            {
                return Err("cursor texture identifiers must be unique, positive, and outside the window scene".into());
            }
        }

        self.cursor_output = output;
        self.install_cursor_texture_membership(&desired);
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

        let epoch = self.cursor_epoch.wrapping_add(1).max(1);
        self.cursor_epoch = epoch;
        state.epoch = epoch;
        let retired = self
            .cursor_texture_ids
            .difference(&desired)
            .copied()
            .collect::<HashSet<_>>();
        if !retired.is_empty() {
            self.retired_cursor_texture_ids
                .entry(epoch)
                .or_default()
                .extend(retired);
        }

        let engine = self
            .host
            .as_ref()
            .expect("Flutter runtime is shutting down")
            .engine();
        let update = self.wire.encode_cursor_state(&state)?;
        engine.send_platform_message(wire::TO_FLUTTER_CHANNEL, update)?;
        self.cursor_texture_ids = desired;
        Ok((state, frames))
    }

    pub fn sync_cursor_buffers(
        &mut self,
        mut frames: Vec<ExternalTextureFrame>,
    ) -> Result<Vec<ExternalTextureFrame>, Box<dyn Error>> {
        let mut seen = HashSet::with_capacity(frames.len());
        for frame in &frames {
            if frame.texture_id <= 0
                || !self.cursor_texture_ids.contains(&frame.texture_id)
                || !seen.insert(frame.texture_id)
            {
                return Err(
                    "cursor buffer updates must target unique active cursor textures".into(),
                );
            }
        }
        self.changed_texture_scratch.clear();
        self.handler
            .set_external_texture_sources(frames.drain(..), &mut self.changed_texture_scratch);
        self.stage_changed_textures();
        Ok(frames)
    }

    pub fn set_cursor_output(&mut self, output: Option<OutputId>) {
        if self.cursor_output == output {
            return;
        }
        self.cursor_output = output;
        let active = self.cursor_texture_ids.clone();
        self.install_cursor_texture_membership(&active);
    }

    pub(super) fn acknowledge_cursor_epoch(&mut self, epoch: u64) -> Result<bool, Box<dyn Error>> {
        if epoch == 0 || epoch > self.cursor_epoch {
            return Ok(false);
        }
        let (acknowledged, later_retained) =
            take_acknowledged_cursor_retirements(&mut self.retired_cursor_texture_ids, epoch);

        for texture_id in acknowledged {
            if self.cursor_texture_ids.contains(&texture_id)
                || later_retained.contains(&texture_id)
                || self.scene_texture_ids.contains(&texture_id)
                || self.screenshot_texture_id == Some(texture_id)
                || self.window_close_texture_leases.retains_texture(texture_id)
                || !self.registered_external_textures.contains(&texture_id)
            {
                continue;
            }
            self.host()
                .engine()
                .unregister_external_texture(texture_id)?;
            self.handler.remove_external_texture_source(texture_id);
            self.pending_frame_texture_ids
                .retain(|pending| *pending != texture_id);
            self.texture_output_membership.remove(&texture_id);
            self.registered_external_textures.remove(&texture_id);
        }
        Ok(true)
    }

    pub(super) fn retains_cursor_texture(&self, texture_id: i64) -> bool {
        self.cursor_texture_ids.contains(&texture_id)
            || self
                .retired_cursor_texture_ids
                .values()
                .any(|ids| ids.contains(&texture_id))
    }

    pub(super) fn install_cursor_texture_membership(&mut self, ids: &HashSet<i64>) {
        self.texture_output_membership
            .retain(|texture_id, _| !self.cursor_texture_ids.contains(texture_id));
        let Some(output) = self.cursor_output else {
            return;
        };
        let outputs: Arc<[OutputId]> = Arc::from([output]);
        for texture_id in ids {
            self.texture_output_membership
                .insert(*texture_id, Arc::clone(&outputs));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cursor_textures_retire_only_after_their_presented_epoch() {
        let mut retirements =
            BTreeMap::from([(2, HashSet::from([11, 12])), (3, HashSet::from([12, 13]))]);

        let (acknowledged, retained_later) =
            take_acknowledged_cursor_retirements(&mut retirements, 1);
        assert!(acknowledged.is_empty());
        assert_eq!(retained_later, HashSet::from([11, 12, 13]));
        assert_eq!(retirements.len(), 2);

        let (acknowledged, retained_later) =
            take_acknowledged_cursor_retirements(&mut retirements, 2);
        assert_eq!(acknowledged, HashSet::from([11, 12]));
        assert_eq!(retained_later, HashSet::from([12, 13]));
        assert_eq!(retirements, BTreeMap::from([(3, HashSet::from([12, 13]))]));
    }
}
