//! The handler's side of the Vulkan scene composer: what each client texture
//! shows, and the composed present.

use super::composer::{
    Client, ConvertKey, Decline, FrameDamage, Image, Placement, ProducerWait, Resolve,
    SampledClient, SceneComposer, Staged, Submitted,
};
use super::*;
use denial_flutter_engine::scene::{Rect, SceneSource, SliceKey};

/// The composer when Vulkan opens the raster context's GPU: the shell then
/// renders with Vulkan too. Otherwise everything renders with GLES.
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
        let modifiers = |code| {
            context
                .display()
                .dmabuf_render_formats()
                .iter()
                .filter(|format| format.code == code)
                .map(|format| format.modifier)
                .collect::<Vec<_>>()
        };
        Ok(SceneComposer::new(
            device,
            &modifiers(Fourcc::Abgr8888),
            &modifiers(Fourcc::Abgr16161616f),
        )?)
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

    /// The engine samples composer storage with GLES, after every
    /// submission.
    pub(super) fn composer_prepare_gles_read(&self) -> bool {
        self.gles_catch_up();
        if let Some(composer) = &self.scene_composer {
            composer.prepare_gles_read();
        }
        true
    }

    fn gles_wait_on(display: &smithay::backend::egl::EGLDisplay, fence: OwnedFd) -> bool {
        match EGLFence::import(display, fence).and_then(|fence| fence.wait(display)) {
            Ok(()) => true,
            Err(error) => {
                error!(%error, "GLES could not wait for the Vulkan composer");
                false
            }
        }
    }

    /// Queues the waits `gles_owed` holds, so the raster context's next
    /// commands run after every composer submission. Before any GLES command
    /// or fence on the raster context that touches composer storage, an
    /// output buffer or a client buffer the composer samples. Raster context
    /// current.
    pub(super) fn gles_catch_up(&self) {
        if lock(&self.gles_owed).is_empty() {
            return;
        }
        let context = lock(&self.render_context);
        self.gles_catch_up_on(context.context.display());
    }

    /// `gles_catch_up` with the render context's lock already held.
    pub(super) fn gles_catch_up_on(&self, display: &smithay::backend::egl::EGLDisplay) {
        let owed = std::mem::take(&mut *lock(&self.gles_owed));
        for fence in owed {
            if !super::composer::signalled(&fence) && !Self::gles_wait_on(display, fence) {
                self.composer_wait_idle();
            }
        }
    }

    /// `glFinish`, which also waits for every composer submission.
    pub(super) fn gles_finish(&self) {
        for fence in std::mem::take(&mut *lock(&self.gles_owed)) {
            super::composer::wait_completion(&fence);
        }
        // SAFETY: callers run on the render thread with the raster context
        // current.
        unsafe { (self.gl.finish)() };
    }

    pub(super) fn composer_stage(&self, source: SceneSource<'_>) -> bool {
        let Some(composer) = &self.scene_composer else {
            return false;
        };
        let view_id = source.view_id();
        if forced_fallback(&source) {
            composer.declined("forced engine composition");
            return false;
        }
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
        let mut resolver = StageResolver {
            handler: self,
            slots: HashMap::new(),
        };
        match composer.stage(source, size, copyable, &mut resolver) {
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
    /// What `texture_id` shows within `bounds`, from its slot as `slots`
    /// first saw it in this stage: a texture drawn twice shows one buffer.
    fn composer_client(
        &self,
        texture_id: i64,
        bounds: Rect,
        slots: &mut HashMap<i64, Option<SlotView>>,
    ) -> Result<Client, Decline> {
        if self.uses_native_window_texture(texture_id) {
            return self.composer_merged_client(texture_id, bounds);
        }
        // Source, presentation and grade from one look at the slot, as the
        // engine resolves them together.
        let slot = slots.entry(texture_id).or_insert_with(|| {
            let (source, presentation) = {
                let sources = lock(&self.external_texture_sources);
                let slot = sources.get(&texture_id)?;
                (
                    slot.current.clone()?,
                    (slot.presentation.width > 0.0).then_some(slot.presentation),
                )
            };
            // What grade_external_texture grades for the GLES pass.
            let look = self.app_look(texture_id);
            let color = source.color();
            let transform = color
                .as_deref()
                .and_then(|color| color.transform(crate::output_color::scene_encoding()));
            let alpha = color
                .as_deref()
                .map_or_else(Default::default, |color| color.alpha);
            let grade = (look.is_some() || transform.is_some() || alpha != Default::default())
                .then_some(Grade {
                    transform,
                    alpha,
                    look,
                });
            Some((source, presentation, grade))
        });
        let Some((source, presentation, grade)) = slot.clone() else {
            return Ok(Client::Missing);
        };
        let (size, owned_native) = match &source {
            ExternalTextureSource::Dmabuf {
                dmabuf,
                buffer_guard,
                ..
            } => (
                (dmabuf.width() as u32, dmabuf.height() as u32),
                buffer_guard
                    .as_ref()
                    .is_some_and(|guard| guard.owned_native().is_some()),
            ),
            // Copied into an image of the texture's own as it is drawn.
            ExternalTextureSource::Shm(frame) => ((frame.width(), frame.height()), false),
        };
        let placement = Placement::new(bounds, size, presentation.as_ref())
            .ok_or("presentation with a background strip")?;
        let sampled = SampledClient {
            texture_id,
            generation: source.generation(),
            source,
        };
        // Graded the way the GLES pass grades it, before the composer
        // filters it. A buffer the compositor writes is copied too: GLES
        // orders that copy after its writes.
        if grade.is_none() && !owned_native {
            return Ok(Client::Image {
                look: None,
                placement,
                sampled,
            });
        }
        Ok(match self.composer_convert(&sampled, grade)? {
            Some(image) => Client::Converted {
                placement,
                sampled,
                image,
            },
            None => Client::Omitted(sampled),
        })
    }

    /// GLES draws `sampled` through `grade` (None: an exact copy) into an
    /// image the composer samples; None when GLES cannot read the buffer,
    /// which the GLES pass then leaves out too. Raster context current.
    fn composer_convert(
        &self,
        sampled: &SampledClient,
        grade: Option<Grade>,
    ) -> Result<Option<Arc<Image>>, Decline> {
        let composer = self.scene_composer.as_ref().ok_or("no composer")?;
        let display = {
            let context = lock(&self.render_context);
            if !context.context.is_current() {
                return Err("client conversion without the raster context");
            }
            context.context.display().clone()
        };
        // GLES draws into images the composer may still read.
        self.gles_catch_up();
        let shader_blit = (*lock(&self.shader_blit)).ok_or("client conversion program")?;
        let Some(prepared) =
            self.prepare_source_with_gl(sampled.texture_id, sampled.source.clone())
        else {
            return Ok(None);
        };
        let size = (
            u32::try_from(prepared.width).map_err(|_| "client size")?,
            u32::try_from(prepared.height).map_err(|_| "client size")?,
        );
        // As the GLES pass: a grade keeps half floats for converted HDR; a
        // copy keeps the source's depth.
        let float = grade
            .as_ref()
            .map_or_else(|| deep_source(&sampled.source), Grade::float);
        let look = match grade.as_ref().and_then(|grade| grade.look.as_ref()) {
            Some(look) => lock(&self.window_grades)
                .look_texture(self.gl, look)
                .map_err(|_| "app look texture")?,
            None => 0,
        };
        // alpha 0: the copy passes every channel through unchanged.
        let color = grade
            .as_ref()
            .map_or_else(CopyColor::default, |grade| grade.copy_color(look));
        let key = ConvertKey::new(sampled, size, float, grade);
        let image = composer.converted(sampled, key, &self.gl, &display, |target| {
            self.draw_graded(
                prepared.name,
                target,
                PixelSize {
                    width: size.0,
                    height: size.1,
                },
                shader_blit,
                color,
            )
        })?;
        // The lease may go: GL keeps what its queued commands read. Looks
        // no grade holds any more go too.
        drop(prepared);
        lock(&self.window_grades).prune_looks(self.gl);
        Ok(Some(image))
    }

    /// Client buffers GLES read for conversions go back once a GLES fence
    /// placed now signals. End of every raster task.
    pub(super) fn composer_release_converted_reads(&self) {
        let Some(composer) = &self.scene_composer else {
            return;
        };
        if !composer.has_converted_reads() {
            return;
        }
        let mut render_context = lock(&self.render_context);
        let bound = !render_context.context.is_current();
        if bound && !render_context.make_current() {
            // Kept until a later raster task can fence them.
            return;
        }
        let holds = composer
            .take_converted_reads()
            .into_iter()
            .filter_map(|client| match client.source {
                ExternalTextureSource::Dmabuf {
                    buffer_guard: Some(guard),
                    ..
                } => Some(SampledBufferHold {
                    texture_id: client.texture_id,
                    generation: client.generation,
                    _buffer_guard: guard,
                }),
                // SHM pixels were copied as GLES uploaded them.
                _ => None,
            })
            .collect::<Vec<_>>();
        if !holds.is_empty() {
            self.gles_catch_up_on(render_context.context.display());
            let fence = EGLFence::create(render_context.context.display()).and_then(|fence| {
                // SAFETY: the render context is current on this thread.
                unsafe { (self.gl.flush)() };
                fence.export()
            });
            let fence = match fence {
                Ok(fence) => Some(fence),
                Err(error) => {
                    warn!(%error, "converted client fence failed; finishing GLES instead");
                    self.gles_finish();
                    None
                }
            };
            self.publish_sampled_buffer_release(
                fence,
                Some(SampledBufferHoldBatch {
                    holds: Some(holds),
                    pool: Arc::downgrade(&self.sampled_buffer_batch_pool),
                }),
            );
        }
        if bound {
            render_context.clear_current();
        }
    }

    /// Releases what finished composer work held. Raster context current.
    pub(super) fn composer_reap(&self) {
        if let Some(composer) = &self.scene_composer {
            composer.reap(&self.gl, &self.display);
            // Looks only expired conversions held.
            lock(&self.window_grades).prune_looks(self.gl);
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
        let wait = match composer.producer_wait() {
            ProducerWait::None => None,
            ProducerWait::Existing(fence) => Some(fence),
            ProducerWait::Fresh => {
                let context = lock(&self.render_context);
                self.gles_catch_up_on(context.context.display());
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
                    self.composer_gles_owe(completion);
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
                for client in staged.omitted {
                    self.mark_external_texture_sampled(client.texture_id, client.generation);
                }
                Ok(submitted)
            }
            Err(error) => {
                if composer.broken() {
                    error!(%error, "Vulkan composer device lost; it draws no more frames");
                } else {
                    error!(%error, "Vulkan composer submission failed; frame not drawn");
                }
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

    /// A view's present failed: its next composed frame redraws whole.
    pub(super) fn composer_frame_lost(&self, view_id: i64) {
        if let Some(composer) = &self.scene_composer {
            composer.frame_lost(view_id);
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

    /// Orders the raster context's later commands after `completion`: the
    /// wait is kept in `gles_owed` until the next GLES command.
    fn composer_gles_owe(&self, completion: &OwnedFd) {
        match completion.try_clone() {
            Ok(fence) => {
                let mut owed = lock(&self.gles_owed);
                owed.retain(|fence| !super::composer::signalled(fence));
                owed.push(fence);
            }
            Err(error) => {
                warn!(%error, "could not keep a composed frame's fence");
                super::composer::wait_completion(completion);
            }
        }
    }

    /// `texture_id` as the GLES pass would paint it (prepared and graded
    /// the same way), copied exactly into an image the engine samples while
    /// it composes `ticket` itself. Raster context current.
    pub(super) fn composer_resolve_texture_vk(
        &self,
        ticket: u64,
        texture_id: i64,
    ) -> Option<denial_flutter_engine::scene::TextureImageVk> {
        let composer = self.scene_composer.as_ref()?;
        let display = {
            let context = lock(&self.render_context);
            if !context.context.is_current() {
                return None;
            }
            context.context.display().clone()
        };
        // GLES copies into images the composer may still read.
        self.gles_catch_up();
        let shader_blit = (*lock(&self.shader_blit))?;
        // Native windows are ABGR8888: an 8-bit copy keeps them exactly.
        let (prepared, deep) = if self.uses_native_window_texture(texture_id) {
            (self.prepare_native_with_gl(texture_id)?, false)
        } else {
            let source = self.current_external_texture(texture_id)?;
            let deep = deep_source(&source);
            (self.prepare_source_with_gl(texture_id, source)?, deep)
        };
        let ungraded = prepared.name;
        let mut prepared = self.grade_external_texture(prepared);
        // A grade keeps half floats for converted HDR, a copy the source's
        // depth, as the GLES pass's textures do.
        let float = if prepared.name == ungraded {
            deep
        } else {
            lock(&self.window_grades)
                .graded
                .get(&texture_id)
                .filter(|graded| graded.binding.texture() == prepared.name)
                .is_some_and(|graded| graded.float)
        };
        let size = (
            u32::try_from(prepared.width).ok(),
            u32::try_from(prepared.height).ok(),
        );
        let image = match size {
            (Some(width), Some(height)) => composer
                .fallback_image(
                    ticket,
                    (width, height),
                    float,
                    &self.gl,
                    &display,
                    |target| {
                        self.draw_graded(
                            prepared.name,
                            target,
                            PixelSize { width, height },
                            shader_blit,
                            CopyColor::default(),
                        )
                    },
                )
                .ok(),
            _ => None,
        };
        // What the GLES pass records for a painted texture: its buffer goes
        // back with this frame's fence, which follows the copy. A client
        // that could not be copied is not shown, so not credited.
        if let Some(buffer) = prepared.sampled_buffer.take() {
            self.record_sampled_buffer(texture_id, prepared.source_generation, buffer);
        }
        if image.is_some() {
            self.record_sampled_feedback(prepared.feedback.take());
            self.mark_external_texture_sampled(texture_id, prepared.source_generation);
            self.finish_native_samples(std::mem::take(&mut prepared.native_samples));
        }
        // GL keeps what its queued copy reads.
        drop(prepared);
        let (image, image_view, format, (width, height)) = image?.lent();
        let presentation = {
            let sources = lock(&self.external_texture_sources);
            sources
                .get(&texture_id)
                .map(|slot| slot.presentation)
                .filter(|presentation| presentation.width > 0.0)
        };
        Some(denial_flutter_engine::scene::TextureImageVk {
            image,
            image_view,
            format,
            width,
            height,
            has_presentation: presentation.is_some(),
            presentation: presentation.unwrap_or_default(),
            ..Default::default()
        })
    }

    /// Lends `ticket`'s copies to the engine's renderer once GLES wrote
    /// them. False: the engine skips the frame.
    pub(super) fn composer_lend_textures_vk(&self, ticket: u64) -> bool {
        let Some(composer) = &self.scene_composer else {
            return false;
        };
        let context = lock(&self.render_context);
        if !context.context.is_current() {
            return false;
        }
        self.gles_catch_up_on(context.context.display());
        let fence = EGLFence::create(context.context.display()).and_then(|fence| {
            // SAFETY: the raster context is current on this thread.
            unsafe { (self.gl.flush)() };
            fence.export()
        });
        drop(context);
        match fence {
            Ok(fence) => composer.lend_fallback(ticket, Some(fence)),
            Err(error) => {
                error!(%error, "could not fence client copies for the engine");
                false
            }
        }
    }

    /// The engine submitted its composition of `ticket` or gave it up.
    pub(super) fn composer_return_textures_vk(&self, ticket: u64) {
        if let Some(composer) = &self.scene_composer {
            composer.return_fallback(ticket);
        }
    }

    /// Whether the engine renders with Vulkan: exactly when the composer
    /// runs. It then composes a frame the composer cannot stage itself from
    /// client copies the composer lends.
    pub(super) fn composer_lends_textures(&self) -> bool {
        self.scene_composer.is_some()
    }

    /// Render-thread shutdown, raster context current.
    pub(super) fn composer_shutdown(&self) {
        if let Some(composer) = &self.scene_composer {
            composer.shutdown(&self.gl, &self.display);
        }
    }
}

/// A texture's buffer, presentation and grade as a stage first saw them.
type SlotView = (
    ExternalTextureSource,
    Option<denial_flutter_engine::ExternalTexturePresentation>,
    Option<Grade>,
);

/// The handler's side of one `stage`.
struct StageResolver<'a> {
    handler: &'a FlutterGlHandler,
    slots: HashMap<i64, Option<SlotView>>,
}

impl Resolve for StageResolver<'_> {
    fn client(&mut self, texture_id: i64, bounds: Rect) -> Result<Client, Decline> {
        self.handler
            .composer_client(texture_id, bounds, &mut self.slots)
    }

    fn copy(&mut self, sampled: &SampledClient) -> Result<Option<Arc<Image>>, Decline> {
        self.handler.composer_convert(sampled, None)
    }
}

/// `DENIAL_VULKAN_FORCE_FALLBACK=N`: every Nth scene of the Vulkan shell is
/// declined, so the engine composes it itself. A debugging switch for that
/// path, which real frames take only when the composer cannot draw one.
fn forced_fallback(source: &SceneSource<'_>) -> bool {
    use std::sync::OnceLock;
    use std::sync::atomic::{AtomicU64, Ordering};
    static EVERY: OnceLock<u64> = OnceLock::new();
    static SCENES: AtomicU64 = AtomicU64::new(0);
    let every = *EVERY.get_or_init(|| {
        std::env::var("DENIAL_VULKAN_FORCE_FALLBACK")
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(0)
    });
    every != 0 && !source.engine_composed() && SCENES.fetch_add(1, Ordering::Relaxed) % every == 0
}

/// Whether an exact copy of a client's buffer needs half floats: anything
/// but 8-bit RGB channels (deeper or shallower channels, YUV) would change
/// in an RGBA8 copy.
fn deep_source(source: &ExternalTextureSource) -> bool {
    let ExternalTextureSource::Dmabuf { dmabuf, .. } = source else {
        return false;
    };
    !matches!(
        dmabuf.format().code,
        Fourcc::Argb8888
            | Fourcc::Xrgb8888
            | Fourcc::Abgr8888
            | Fourcc::Xbgr8888
            | Fourcc::Rgba8888
            | Fourcc::Rgbx8888
            | Fourcc::Bgra8888
            | Fourcc::Bgrx8888
            | Fourcc::Rgb888
            | Fourcc::Bgr888
            | Fourcc::R8
            | Fourcc::Gr88
            | Fourcc::Rg88
    )
}
