//! The handler's side of the Vulkan scene composer: what each client texture
//! shows, and the composed present.

use super::composer::{
    Client, Decline, FrameDamage, Placement, ProducerWait, SampledClient, SceneComposer, Staged,
    Submitted,
};
use super::*;
use denial_flutter_engine::scene::{Rect, SceneSource, SliceKey, SliceWriter};

/// The composer when `--vulkan-composer` asks for it and the raster
/// context's GPU supports it; otherwise frames stay on GLES.
pub(super) fn create_scene_composer(
    context: &egl_context::SharedEglContext,
) -> Option<SceneComposer> {
    if !super::composer::requested() {
        return None;
    }
    let created = (|| -> Result<SceneComposer, Box<dyn Error>> {
        let device = smithay::backend::egl::EGLDevice::device_for_display(context.display())?;
        let node = device
            .try_get_render_node()?
            .ok_or("the raster EGL device has no render node")?;
        let path = node.dev_path().ok_or("the render node has no path")?;
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&path)?;
        let device = smithay::backend::drm::DrmDeviceFd::new(smithay::utils::DeviceFd::from(
            OwnedFd::from(file),
        ));
        let modifiers = context
            .display()
            .dmabuf_render_formats()
            .iter()
            .filter(|format| format.code == Fourcc::Abgr8888)
            .map(|format| format.modifier)
            .collect::<Vec<_>>();
        Ok(SceneComposer::new(device, &modifiers)?)
    })();
    match created {
        Ok(composer) => {
            info!("Vulkan scene composer enabled");
            Some(composer)
        }
        Err(error) => {
            warn!(%error, "Vulkan scene composer unavailable; composing with GLES");
            None
        }
    }
}

impl FlutterGlHandler {
    pub(super) fn composer_begin(&self, view_id: i64) -> u64 {
        self.scene_composer
            .as_ref()
            .map_or(0, |composer| composer.begin(view_id))
    }

    pub(super) fn composer_acquire_writer(&self, width: u32, height: u32) -> Option<SliceWriter> {
        let composer = self.scene_composer.as_ref()?;
        let context = lock(&self.render_context);
        composer.acquire_writer(width, height, &self.gl, context.context.display())
    }

    pub(super) fn composer_drop_engine_ref(&self, key: SliceKey) {
        if let Some(composer) = &self.scene_composer {
            composer.drop_engine_ref(key);
        }
    }

    pub(super) fn composer_cancel(&self, ticket: u64) {
        if let Some(composer) = &self.scene_composer {
            composer.cancel(ticket);
        }
    }

    /// The engine samples composer storage with GLES; GLES already waits
    /// for every submission.
    pub(super) fn composer_prepare_gles_read(&self) -> bool {
        if let Some(composer) = &self.scene_composer {
            composer.prepare_gles_read();
        }
        true
    }

    /// Queues a GPU-side wait for `fence` on the raster context.
    fn gles_wait(&self, fence: OwnedFd) -> bool {
        let context = lock(&self.render_context);
        let display = context.context.display();
        match EGLFence::import(display, fence).and_then(|fence| fence.wait(display)) {
            Ok(()) => true,
            Err(error) => {
                error!(%error, "GLES could not wait for the Vulkan composer");
                false
            }
        }
    }

    pub(super) fn composer_stage(&self, source: SceneSource<'_>) -> bool {
        let Some(composer) = &self.scene_composer else {
            return false;
        };
        let view_id = source.view_id();
        let (size, copyable) = {
            let targets = lock(&self.targets);
            let mut size = None;
            let framebuffers = targets
                .iter()
                .filter(|target| target.render_view_id.get() == view_id)
                .inspect(|target| size = Some((target.size.width, target.size.height)))
                .map(|target| target.render_framebuffer)
                .collect::<Vec<_>>();
            let Some(copyable) = composer.targets_copyable(framebuffers) else {
                return false;
            };
            (size, copyable)
        };
        let Some(size) = size else {
            return false;
        };
        match composer.stage(source, size, copyable, |texture_id, bounds| {
            self.composer_client(texture_id, bounds)
        }) {
            Ok(()) => true,
            Err(reason) => {
                // Counted in the composer's tally; the first few also say
                // which view.
                composer.declined(reason);
                static LOGGED: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
                if LOGGED.fetch_add(1, std::sync::atomic::Ordering::Relaxed) < 4 {
                    info!(view_id, reason, "output frame stays on GLES composition");
                }
                false
            }
        }
    }

    /// What a client texture shows this frame, as the engine would paint it.
    fn composer_client(&self, texture_id: i64, bounds: Rect) -> Result<Client, Decline> {
        if self.uses_native_window_texture(texture_id) {
            return self.composer_merged_client(texture_id, bounds);
        }
        // Source and presentation from one look at the slot, as the engine
        // resolves them together.
        let (source, presentation) = {
            let sources = lock(&self.external_texture_sources);
            let Some(slot) = sources.get(&texture_id) else {
                return Ok(Client::Missing);
            };
            let Some(source) = slot.current.clone() else {
                return Ok(Client::Missing);
            };
            (
                source,
                (slot.presentation.width > 0.0).then_some(slot.presentation),
            )
        };
        let size = match &source {
            ExternalTextureSource::Dmabuf {
                dmabuf,
                buffer_guard,
                ..
            } => {
                // Mapped SHM snapshots sample like client buffers: written
                // before they are published, kept by the guard until the
                // composer finished.
                if buffer_guard
                    .as_ref()
                    .is_some_and(|guard| guard.owned_native().is_some())
                {
                    return Err("compositor-owned buffer");
                }
                (dmabuf.width() as u32, dmabuf.height() as u32)
            }
            // Copied into an image of the texture's own as it is drawn.
            ExternalTextureSource::Shm(frame) => (frame.width(), frame.height()),
        };
        if let Some(color) = source.color()
            && (color
                .transform(crate::output_color::scene_encoding())
                .is_some()
                || color.alpha != Default::default())
        {
            return Err("color conversion");
        }
        let placement = Placement::new(bounds, size, presentation.as_ref())
            .ok_or("presentation with a background strip")?;
        Ok(Client::Image {
            look: self.app_look(texture_id),
            placement,
            sampled: SampledClient {
                texture_id,
                generation: source.generation(),
                source: source.clone(),
            },
        })
    }

    /// Releases what finished composer work held. Raster context current.
    pub(super) fn composer_reap(&self) {
        if let Some(composer) = &self.scene_composer {
            composer.reap(&self.gl, &self.display);
        }
    }

    /// The staged scene for this view's root present, if the composer
    /// draws it.
    pub(super) fn composer_take_staged(&self, view_id: i64) -> Option<Staged> {
        self.scene_composer.as_ref()?.take_staged(view_id)
    }

    /// Draws a staged frame into `framebuffer`: its completion fence (None
    /// when it already completed), or Err when the frame is lost.
    pub(super) fn composer_submit(
        &self,
        mut staged: Staged,
        framebuffer: u32,
        damage: FrameDamage<'_>,
    ) -> Result<Submitted, ()> {
        let composer: &SceneComposer = self.scene_composer.as_ref().ok_or(())?;
        let wait = match composer.producer_wait(&staged) {
            ProducerWait::None => None,
            ProducerWait::Existing(fence) => Some(fence),
            ProducerWait::Fresh => {
                let context = lock(&self.render_context);
                let exported = EGLFence::create(context.context.display()).and_then(|fence| {
                    // SAFETY: present runs with the raster context current.
                    unsafe { (self.gl.flush)() };
                    fence.export()
                });
                match exported {
                    Ok(fence) => Some(fence),
                    Err(error) => {
                        error!(%error, "could not fence GLES work for the Vulkan composer");
                        return Err(());
                    }
                }
            }
        };
        match composer.submit(&mut staged, framebuffer, damage, wait) {
            Ok(submitted) => {
                // Every later GLES command, whatever it samples (cached
                // client images included) and whichever output it renders,
                // runs after this submission: one GPU-side wait.
                if let Some(completion) = &submitted.completion {
                    self.composer_gles_wait_for(completion);
                }
                for client in staged.clients {
                    if let ExternalTextureSource::Dmabuf {
                        buffer_guard: Some(guard),
                        ..
                    } = &client.source
                    {
                        self.record_sampled_buffer(
                            client.texture_id,
                            client.generation,
                            guard.clone(),
                        );
                    }
                    self.record_sampled_feedback(client.source.feedback());
                    self.mark_external_texture_sampled(client.texture_id, client.generation);
                }
                // Merged windows shown again from their image: their inputs
                // reach the screen, but the GPU read them earlier.
                for client in staged.credits {
                    self.record_sampled_feedback(client.source.feedback());
                    self.mark_external_texture_sampled(client.texture_id, client.generation);
                }
                Ok(submitted)
            }
            Err(error) => {
                error!(%error, "Vulkan composer submission failed; composing with GLES from now on");
                Err(())
            }
        }
    }

    /// A frame GLES composed while the composer is on; counted for output
    /// views (negative IDs) only.
    pub(super) fn composer_gles_presented(&self, view_id: i64) {
        if view_id < 0
            && let Some(composer) = &self.scene_composer
        {
            composer.gles_presented(view_id);
        }
    }

    /// The GLES present's fence: the next submission waits for it.
    pub(super) fn composer_gles_fenced(&self, fence: &OwnedFd) {
        if let Some(composer) = &self.scene_composer {
            composer.gles_fenced(fence);
        }
    }

    /// Blocks until all composer work completed. Failure paths only.
    pub(super) fn composer_wait_idle(&self) {
        if let Some(composer) = &self.scene_composer {
            composer.wait_idle();
        }
    }

    /// Orders the raster context's later commands after `completion`: a
    /// GPU-side wait, or a CPU wait when that cannot be queued.
    fn composer_gles_wait_for(&self, completion: &OwnedFd) {
        let queued = match completion.try_clone() {
            Ok(fence) => self.gles_wait(fence),
            Err(error) => {
                warn!(%error, "could not share a composed frame's fence");
                false
            }
        };
        if !queued {
            super::composer::wait_completion(completion);
        }
    }

    /// Render-thread shutdown, raster context current.
    pub(super) fn composer_shutdown(&self) {
        if let Some(composer) = &self.scene_composer {
            composer.shutdown(&self.gl, &self.display);
        }
    }
}
