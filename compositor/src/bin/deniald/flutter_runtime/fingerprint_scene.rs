//! Flutter owns fingerprint pixels; native only authorizes their presentation.
use super::*;

pub(super) const CHANNEL: &CStr = c"denial/fingerprint_scene";

#[derive(Default)]
pub(super) struct FingerprintScene {
    pub(super) output: Option<OutputId>,
    pub(super) epoch: u64,
    pub(super) acknowledged: bool,
    message: Vec<u8>,
    pub(super) texture: Option<i64>,
}

impl FingerprintScene {
    fn acknowledge(&mut self, epoch: u64) {
        if epoch != 0 && epoch == self.epoch {
            self.acknowledged = true;
        }
    }
    pub(super) fn render_epoch(&self, output: OutputId) -> u64 {
        if self.acknowledged && self.output == Some(output) {
            self.epoch
        } else {
            0
        }
    }
}

impl FlutterRuntime {
    pub(crate) fn fingerprint_scene_epoch(&self) -> u64 {
        self.fingerprint_scene.epoch
    }

    // One compositor-owned presentation image is cached across cleanup and
    // authentication. Replacing it uses the normal Flutter texture leases;
    // neither scanout memory nor a released client DMA-BUF is retained here.
    pub(crate) fn register_fingerprint_texture(
        &mut self,
        image: ShmTextureFrame,
    ) -> Result<i64, Box<dyn Error>> {
        let id = if let Some(id) = self.fingerprint_scene.texture {
            id
        } else {
            let id = (1..=i64::MAX)
                .rev()
                .find(|id| !self.registered_external_textures.contains(id))
                .ok_or("external texture identifiers exhausted")?;
            self.host().engine().register_external_texture(id)?;
            self.registered_external_textures.insert(id);
            self.fingerprint_scene.texture = Some(id);
            id
        };
        self.changed_texture_scratch.clear();
        self.handler.set_external_texture_sources(
            [ExternalTextureFrame::from_shm(id, image, false)],
            &mut self.changed_texture_scratch,
        );
        self.stage_changed_textures();
        Ok(id)
    }

    pub(crate) fn set_fingerprint_scene(
        &mut self,
        output: OutputId,
        epoch: u64,
        black: bool,
        image: bool,
        reveal: bool,
        fade: bool,
        rectangle: [f64; 4],
        panel: [f64; 2],
    ) -> Result<(), Box<dyn Error>> {
        let geometry = self
            .render_outputs
            .iter()
            .find(|o| o.output_id == output)
            .ok_or("fingerprint render output disappeared")?;
        // Rotation needs a corresponding physical-to-logical image transform.
        // Reject unsupported geometry rather than illuminate the wrong pixels.
        if geometry.transform != OutputTransform::Normal {
            return Err("rotated fingerprint output is unsupported".into());
        }
        let sx = geometry.logical_width / panel[0];
        let sy = geometry.logical_height / panel[1];
        let message = serde_json::to_vec(&serde_json::json!({
            "epoch": epoch, "black": black, "reveal": reveal, "fade": fade,
            "texture": if image { self.fingerprint_scene.texture } else { None },
            "x": geometry.logical_x + rectangle[0] * sx,
            "y": geometry.logical_y + rectangle[1] * sy,
            "width": rectangle[2] * sx, "height": rectangle[3] * sy,
            "outputX": geometry.logical_x, "outputY": geometry.logical_y,
            "outputWidth": geometry.logical_width, "outputHeight": geometry.logical_height,
        }))?;
        self.fingerprint_scene.output = Some(output);
        self.fingerprint_scene.epoch = epoch;
        self.fingerprint_scene.acknowledged = false;
        self.fingerprint_scene.message = message;
        self.host()
            .engine()
            .send_platform_message(CHANNEL, &self.fingerprint_scene.message)?;
        Ok(())
    }

    pub(super) fn handle_fingerprint_scene(&mut self, data: &[u8]) -> Vec<u8> {
        if data == b"sync" {
            return self.fingerprint_scene.message.clone();
        }
        if data.len() <= 20
            && let Ok(text) = std::str::from_utf8(data)
            && let Ok(epoch) = text.parse::<u64>()
        {
            self.fingerprint_scene.acknowledge(epoch);
        }
        Vec::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn stale_layout_acknowledgement_cannot_authorize_capture_or_cleanup() {
        let mut scene = FingerprintScene::default();
        scene.epoch = 7;
        scene.acknowledge(6);
        assert!(!scene.acknowledged);
        scene.acknowledge(7);
        assert!(scene.acknowledged);
        scene.epoch = 8;
        scene.acknowledged = false;
        scene.acknowledge(7);
        assert!(!scene.acknowledged);
        scene.acknowledge(0);
        assert!(!scene.acknowledged);
        scene.acknowledge(8);
        assert!(scene.acknowledged);
    }
}
