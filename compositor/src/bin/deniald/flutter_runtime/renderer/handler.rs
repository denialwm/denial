//! Flutter embedder callbacks and the renderer's runtime-facing handler.

use super::*;

#[path = "handler/open_gl.rs"]
mod open_gl;

#[derive(Clone, Copy, Debug)]
struct PendingOutputPresentation {
    view_id: i64,
    framebuffer: u32,
}

pub(in crate::flutter_runtime) struct FlutterGlHandler {
    render_context: Mutex<ContextBinding>,
    resource_context: Mutex<ContextBinding>,
    display: Arc<EGLDisplayHandle>,
    gl: GlApi,
    targets: Mutex<Vec<GlTarget>>,
    shader_blit: Mutex<Option<ShaderBlit>>,
    depth_stencils: Mutex<Vec<u32>>,
    broker: Mutex<OutputBufferBroker>,
    pending_output_presentation: Mutex<Option<PendingOutputPresentation>>,
    external_texture_sources: Mutex<HashMap<i64, ExternalTextureSlot>>,
    raster_sampled_buffers: Mutex<Vec<SampledBufferHold>>,
    sampled_buffer_release_fence: Mutex<Option<OwnedFd>>,
    sampled_buffer_batch_pool: Arc<SampledBufferBatchPool>,
    dmabuf_texture_cache: Mutex<PartitionedRecencyCache<i64, Dmabuf, Arc<CachedTextureBinding>>>,
    retained_native_texture_cache:
        Mutex<PartitionedRecencyCache<i64, u64, Arc<CachedTextureBinding>>>,
    shm_texture_cache: Mutex<RecencyCache<(i64, u64), Arc<CachedTextureBinding>>>,
    retired_external_bindings: Arc<RetiredExternalBindingQueue>,
    retired_external_binding_scratch: Mutex<Vec<ExternalTextureBinding>>,
    external_texture_lease_pool: Arc<ExternalTextureLeasePool>,
    prepared_external_texture: Mutex<Option<PreparedExternalTexture>>,
    external_texture_resource_budget: Arc<ExternalTextureResourceBudget>,
    pending_vsync_batons: Mutex<PendingVsyncBatons>,
    platform_task_budget: Arc<PlatformTaskBudget>,
    platform_tasks: CoalescedInbox<PendingPlatformTask>,
    ready_frames: Mutex<VecDeque<ReadyOutputFrame>>,
    frame_ready_wakeup: CoalescedWakeup,
    queue_overflow_wakeup: CoalescedWakeup,
    pub(in crate::flutter_runtime) render_audit: Option<Mutex<RenderDamageAudit>>,
    gpu_timing: Option<Mutex<GpuTimingState>>,
    events: Sender<RuntimeEvent>,
    generation: u64,
    desktop_size: PixelSize,
    producer: ProducerArbiter,
}

impl FlutterGlHandler {
    #[allow(clippy::too_many_arguments)]
    pub(in crate::flutter_runtime) fn new<'a>(
        render_context: egl_context::SharedEglContext,
        resource_context: egl_context::SharedEglContext,
        output_pools: impl IntoIterator<Item = OutputRenderTargetPool<'a>>,
        desktop_size: PixelSize,
        renderer_backend: RendererBackend,
        offscreen_blit: bool,
        events: Sender<RuntimeEvent>,
        generation: u64,
    ) -> Result<Arc<Self>, Box<dyn Error>> {
        let display = render_context.display().get_display_handle();
        // SAFETY: this context was just created and has never been current on
        // another thread. It is unbound before ownership reaches Flutter.
        unsafe { render_context.make_current()? };
        let gl = GlApi::load()?;
        let render_audit_active = render_audit_enabled();
        let gpu_timing = render_audit_active.then(GpuTimingState::load).flatten();
        let needs_depth_stencil = renderer_backend == RendererBackend::ImpellerGles;
        let mut depth_stencils = Vec::new();
        info!(
            %renderer_backend,
            offscreen_blit,
            "creating Flutter physical-output texture targets"
        );
        let mut targets = Vec::new();
        let mut broker_descriptors = Vec::new();

        for pool in output_pools {
            let width =
                i32::try_from(pool.size.width).map_err(|_| "Flutter output width exceeds GLES")?;
            let height = i32::try_from(pool.size.height)
                .map_err(|_| "Flutter output height exceeds GLES")?;
            let mut depth_stencil = 0;
            if needs_depth_stencil {
                // Impeller wraps Denial's supplied FBO. One packed attachment can
                // be shared by one output's rotating FBOs because the raster
                // runner is serial and clears it for each render pass.
                // SAFETY: this new GLES context is current and the arguments and
                // output pointer are valid.
                unsafe {
                    let _ = (gl.get_error)();
                    (gl.gen_renderbuffers)(1, &mut depth_stencil);
                    (gl.bind_renderbuffer)(gl::RENDERBUFFER, depth_stencil);
                    (gl.renderbuffer_storage)(
                        gl::RENDERBUFFER,
                        gl::DEPTH24_STENCIL8,
                        width,
                        height,
                    );
                }
                // SAFETY: the same GLES context remains current.
                let allocation_error = unsafe { (gl.get_error)() };
                depth_stencils.push(depth_stencil);
                if depth_stencil == 0 || allocation_error != gl::NO_ERROR {
                    warn!(
                        renderbuffer = depth_stencil,
                        error = format_args!("{allocation_error:#x}"),
                        "Impeller GLES depth/stencil allocation failed"
                    );
                    destroy_depth_stencils(gl, &mut depth_stencils);
                    destroy_targets(gl, &display, &mut targets);
                    render_context.unbind()?;
                    return Err("could not allocate Impeller GLES depth/stencil storage".into());
                }
            }

            let target_start = targets.len();
            for (buffer_index, (scanout_dmabuf, render_dmabuf)) in
                pool.dmabufs.into_iter().enumerate()
            {
                let image = match render_context
                    .display()
                    .create_image_from_dmabuf(scanout_dmabuf)
                {
                    Ok(image) => image,
                    Err(error) => {
                        destroy_targets(gl, &display, &mut targets);
                        destroy_depth_stencils(gl, &mut depth_stencils);
                        render_context.unbind()?;
                        return Err(error.into());
                    }
                };
                let mut target = GlTarget {
                    output_id: pool.output_id,
                    render_view_id: pool.render_view_id,
                    configuration_generation: pool.configuration_generation,
                    size: pool.size,
                    buffer_index,
                    scanout_image: image as usize,
                    render_image: 0,
                    scanout_texture: 0,
                    scanout_framebuffer: 0,
                    render_texture: 0,
                    render_framebuffer: 0,
                };
                // SAFETY: a compatible GLES context is current and all output
                // pointers reference live local integers.
                unsafe {
                    (gl.gen_textures)(1, &mut target.scanout_texture);
                    (gl.bind_texture)(gl::TEXTURE_2D, target.scanout_texture);
                    (gl.tex_parameter_i)(
                        gl::TEXTURE_2D,
                        gl::TEXTURE_MIN_FILTER,
                        gl::NEAREST as i32,
                    );
                    (gl.tex_parameter_i)(
                        gl::TEXTURE_2D,
                        gl::TEXTURE_MAG_FILTER,
                        gl::NEAREST as i32,
                    );
                    (gl.tex_parameter_i)(
                        gl::TEXTURE_2D,
                        gl::TEXTURE_WRAP_S,
                        gl::CLAMP_TO_EDGE as i32,
                    );
                    (gl.tex_parameter_i)(
                        gl::TEXTURE_2D,
                        gl::TEXTURE_WRAP_T,
                        gl::CLAMP_TO_EDGE as i32,
                    );
                    (gl.image_target_texture)(gl::TEXTURE_2D, image.cast());
                    (gl.gen_framebuffers)(1, &mut target.scanout_framebuffer);
                    (gl.bind_framebuffer)(gl::FRAMEBUFFER, target.scanout_framebuffer);
                    (gl.framebuffer_texture_2d)(
                        gl::FRAMEBUFFER,
                        gl::COLOR_ATTACHMENT0,
                        gl::TEXTURE_2D,
                        target.scanout_texture,
                        0,
                    );
                    if !offscreen_blit && depth_stencil != 0 {
                        (gl.framebuffer_renderbuffer)(
                            gl::FRAMEBUFFER,
                            gl::DEPTH_STENCIL_ATTACHMENT,
                            gl::RENDERBUFFER,
                            depth_stencil,
                        );
                    }
                }
                // Direct mode exposes this imported texture to Flutter. Offscreen
                // mode keeps it only as the destination of the final native-size
                // copy, so effects and partial repaint never need to read it.
                let mut actual_samples = 0;
                let mut actual_stencil_bits = 0;
                // SAFETY: the same compatible GLES context remains current, the
                // newly created framebuffer is still bound, and the output
                // pointer references a live local integer.
                let framebuffer_status = unsafe {
                    let status = (gl.check_framebuffer_status)(gl::FRAMEBUFFER);
                    (gl.get_integer_v)(gl::SAMPLES, &mut actual_samples);
                    if needs_depth_stencil {
                        (gl.get_integer_v)(gl::STENCIL_BITS, &mut actual_stencil_bits);
                    }
                    status
                };
                if target.scanout_texture == 0
                    || target.scanout_framebuffer == 0
                    || framebuffer_status != gl::FRAMEBUFFER_COMPLETE
                    || (!offscreen_blit && actual_samples > 1)
                    || (!offscreen_blit && needs_depth_stencil && actual_stencil_bits < 8)
                {
                    warn!(
                        texture = target.scanout_texture,
                        framebuffer = target.scanout_framebuffer,
                        status = framebuffer_status,
                        actual_samples,
                        actual_stencil_bits,
                        "Flutter output scanout FBO creation failed"
                    );
                    let mut failed = vec![target];
                    destroy_targets(gl, &display, &mut failed);
                    destroy_targets(gl, &display, &mut targets);
                    destroy_depth_stencils(gl, &mut depth_stencils);
                    render_context.unbind()?;
                    return Err("a Flutter output scanout framebuffer is incomplete".into());
                }

                if offscreen_blit {
                    let Some(render_dmabuf) = render_dmabuf else {
                        let mut failed = vec![target];
                        destroy_targets(gl, &display, &mut failed);
                        destroy_targets(gl, &display, &mut targets);
                        destroy_depth_stencils(gl, &mut depth_stencils);
                        render_context.unbind()?;
                        return Err(
                            "offscreen blit target is missing its linear render DMA-BUF".into()
                        );
                    };
                    let render_format = AllocatorBuffer::format(render_dmabuf);
                    if render_format.code != Fourcc::Xrgb8888
                        || render_format.modifier != Modifier::Linear
                    {
                        let mut failed = vec![target];
                        destroy_targets(gl, &display, &mut failed);
                        destroy_targets(gl, &display, &mut targets);
                        destroy_depth_stencils(gl, &mut depth_stencils);
                        render_context.unbind()?;
                        return Err(format!(
                            "offscreen Flutter render target is not linear XR24: {render_format:?}"
                        )
                        .into());
                    }
                    let render_image = match render_context
                        .display()
                        .create_image_from_dmabuf(render_dmabuf)
                    {
                        Ok(image) => image,
                        Err(error) => {
                            let mut failed = vec![target];
                            destroy_targets(gl, &display, &mut failed);
                            destroy_targets(gl, &display, &mut targets);
                            destroy_depth_stencils(gl, &mut depth_stencils);
                            render_context.unbind()?;
                            return Err(error.into());
                        }
                    };
                    target.render_image = render_image as usize;
                    // Flutter's root target is an explicitly LINEAR GBM DMA-BUF.
                    // Backdrop reads therefore cannot inherit UBWC compression
                    // from either Mesa's ordinary texture allocator or scanout.
                    // SAFETY: the compatible GLES context remains current and all
                    // names and attachment dimensions belong to this handler.
                    unsafe {
                        let _ = (gl.get_error)();
                        (gl.gen_textures)(1, &mut target.render_texture);
                        (gl.bind_texture)(gl::TEXTURE_2D, target.render_texture);
                        (gl.tex_parameter_i)(
                            gl::TEXTURE_2D,
                            gl::TEXTURE_MIN_FILTER,
                            gl::NEAREST as i32,
                        );
                        (gl.tex_parameter_i)(
                            gl::TEXTURE_2D,
                            gl::TEXTURE_MAG_FILTER,
                            gl::NEAREST as i32,
                        );
                        (gl.tex_parameter_i)(
                            gl::TEXTURE_2D,
                            gl::TEXTURE_WRAP_S,
                            gl::CLAMP_TO_EDGE as i32,
                        );
                        (gl.tex_parameter_i)(
                            gl::TEXTURE_2D,
                            gl::TEXTURE_WRAP_T,
                            gl::CLAMP_TO_EDGE as i32,
                        );
                        (gl.image_target_texture)(gl::TEXTURE_2D, render_image.cast());
                        (gl.gen_framebuffers)(1, &mut target.render_framebuffer);
                        (gl.bind_framebuffer)(gl::FRAMEBUFFER, target.render_framebuffer);
                        (gl.framebuffer_texture_2d)(
                            gl::FRAMEBUFFER,
                            gl::COLOR_ATTACHMENT0,
                            gl::TEXTURE_2D,
                            target.render_texture,
                            0,
                        );
                        if depth_stencil != 0 {
                            (gl.framebuffer_renderbuffer)(
                                gl::FRAMEBUFFER,
                                gl::DEPTH_STENCIL_ATTACHMENT,
                                gl::RENDERBUFFER,
                                depth_stencil,
                            );
                        }
                    }
                    actual_samples = 0;
                    actual_stencil_bits = 0;
                    // SAFETY: the newly created render framebuffer is still bound
                    // in the current compatible GLES context.
                    let render_status = unsafe {
                        let status = (gl.check_framebuffer_status)(gl::FRAMEBUFFER);
                        (gl.get_integer_v)(gl::SAMPLES, &mut actual_samples);
                        if needs_depth_stencil {
                            (gl.get_integer_v)(gl::STENCIL_BITS, &mut actual_stencil_bits);
                        }
                        status
                    };
                    // SAFETY: querying the current context's error queue has no
                    // additional pointer or object-lifetime requirements.
                    let render_error = unsafe { (gl.get_error)() };
                    if target.render_texture == 0
                        || target.render_framebuffer == 0
                        || render_status != gl::FRAMEBUFFER_COMPLETE
                        || render_error != gl::NO_ERROR
                        || actual_samples > 1
                        || (needs_depth_stencil && actual_stencil_bits < 8)
                    {
                        warn!(
                            texture = target.render_texture,
                            framebuffer = target.render_framebuffer,
                            status = render_status,
                            error = format_args!("{render_error:#x}"),
                            actual_samples,
                            actual_stencil_bits,
                            "Flutter offscreen output FBO creation failed"
                        );
                        let mut failed = vec![target];
                        destroy_targets(gl, &display, &mut failed);
                        destroy_targets(gl, &display, &mut targets);
                        destroy_depth_stencils(gl, &mut depth_stencils);
                        render_context.unbind()?;
                        return Err("a Flutter offscreen output framebuffer is incomplete".into());
                    }
                } else {
                    target.render_framebuffer = target.scanout_framebuffer;
                }
                targets.push(target);
            }
            let framebuffers = targets[target_start..]
                .iter()
                .map(|target| target.render_framebuffer)
                .collect::<Vec<_>>();
            broker_descriptors.push((
                pool.output_id,
                pool.render_view_id,
                pool.configuration_generation,
                pool.size,
                pool.initial_scanout,
                framebuffers,
            ));
        }
        let mut shader_blit = match create_shader_blit(gl) {
            Ok(pipeline) => Some(pipeline),
            Err(error) => {
                destroy_targets(gl, &display, &mut targets);
                destroy_depth_stencils(gl, &mut depth_stencils);
                render_context.unbind()?;
                return Err(error);
            }
        };
        // SAFETY: zero is the default GLES object and the context is current.
        unsafe {
            (gl.use_program)(0);
            (gl.bind_framebuffer)(gl::FRAMEBUFFER, 0);
            (gl.bind_texture)(gl::TEXTURE_2D, 0);
            (gl.bind_renderbuffer)(gl::RENDERBUFFER, 0);
        }
        render_context.unbind()?;

        if targets.len() < 3 {
            // SAFETY: Flutter does not own this context yet.
            unsafe { render_context.make_current()? };
            destroy_shader_blit(gl, &mut shader_blit);
            destroy_targets(gl, &display, &mut targets);
            destroy_depth_stencils(gl, &mut depth_stencils);
            render_context.unbind()?;
            return Err("Flutter presentation needs physical output buffer pools".into());
        }
        let broker = match OutputBufferBroker::new(broker_descriptors.iter().map(
            |(output_id, render_view_id, configuration_generation, size, initial, framebuffers)| {
                OutputPoolDescriptor {
                    output_id: *output_id,
                    render_view_id: *render_view_id,
                    configuration_generation: *configuration_generation,
                    size: *size,
                    initial_scanout: *initial,
                    framebuffers,
                }
            },
        )) {
            Ok(broker) => broker,
            Err(error) => {
                // Keep the constructor's new validation path leak-free: GL
                // targets do not own automatic destructors.
                // SAFETY: target construction has finished, the render
                // context is unbound, and Flutter does not own it yet.
                unsafe { render_context.make_current()? };
                destroy_shader_blit(gl, &mut shader_blit);
                destroy_targets(gl, &display, &mut targets);
                destroy_depth_stencils(gl, &mut depth_stencils);
                render_context.unbind()?;
                return Err(error.into());
            }
        };
        info!(
            outputs = broker.pools.len(),
            buffers = targets.len(),
            offscreen_blit,
            render_modifier = ?offscreen_blit.then_some(Modifier::Linear),
            "imported native output pools into Flutter EGL context"
        );
        let render_audit = render_audit_active.then(|| {
            info!(
                target: "deniald::render_audit",
                width = desktop_size.width,
                height = desktop_size.height,
                gpu_timestamps = gpu_timing.is_some(),
                "Flutter physical-output render audit enabled"
            );
            Mutex::new(RenderDamageAudit::new())
        });

        Ok(Arc::new(Self {
            render_context: Mutex::new(ContextBinding::new(render_context)),
            resource_context: Mutex::new(ContextBinding::new(resource_context)),
            display,
            gl,
            targets: Mutex::new(targets),
            shader_blit: Mutex::new(shader_blit),
            depth_stencils: Mutex::new(depth_stencils),
            broker: Mutex::new(broker),
            pending_output_presentation: Mutex::new(None),
            external_texture_sources: Mutex::new(HashMap::new()),
            raster_sampled_buffers: Mutex::new(Vec::new()),
            sampled_buffer_release_fence: Mutex::new(None),
            sampled_buffer_batch_pool: Arc::new(Mutex::new(Vec::with_capacity(
                MAX_RECYCLED_SAMPLED_BUFFER_BATCHES,
            ))),
            dmabuf_texture_cache: Mutex::new(PartitionedRecencyCache::new(
                MAX_CACHED_DMABUF_BINDINGS_PER_TEXTURE,
            )),
            retained_native_texture_cache: Mutex::new(PartitionedRecencyCache::new(
                MAX_CACHED_DMABUF_BINDINGS_PER_TEXTURE,
            )),
            shm_texture_cache: Mutex::new(RecencyCache::new(MAX_CACHED_SHM_BINDINGS)),
            retired_external_bindings: Arc::new(RetiredExternalBindingQueue::new()),
            retired_external_binding_scratch: Mutex::new(Vec::new()),
            external_texture_lease_pool: Arc::new(Mutex::new(Vec::with_capacity(
                MAX_CACHED_EXTERNAL_TEXTURE_LEASES,
            ))),
            prepared_external_texture: Mutex::new(None),
            external_texture_resource_budget: Arc::new(ExternalTextureResourceBudget::default()),
            pending_vsync_batons: Mutex::new(PendingVsyncBatons::default()),
            platform_task_budget: Arc::new(PlatformTaskBudget::default()),
            platform_tasks: CoalescedInbox::with_capacity(INITIAL_PLATFORM_TASK_BATCH_CAPACITY),
            ready_frames: Mutex::new(VecDeque::with_capacity(8)),
            frame_ready_wakeup: CoalescedWakeup::default(),
            queue_overflow_wakeup: CoalescedWakeup::default(),
            render_audit,
            gpu_timing: gpu_timing.map(Mutex::new),
            events,
            generation,
            desktop_size,
            producer: ProducerArbiter::new(),
        }))
    }

    pub(in crate::flutter_runtime) fn take_ready_frame(
        &self,
        mut output_available: impl FnMut(OutputId) -> bool,
    ) -> Option<ReadyOutputFrame> {
        let mut frames = lock(&self.ready_frames);
        let index = frames
            .iter()
            .position(|frame| output_available(frame.output_id))?;
        frames.remove(index)
    }

    pub(in crate::flutter_runtime) fn has_ready_frames(&self) -> bool {
        !lock(&self.ready_frames).is_empty()
    }

    pub(in crate::flutter_runtime) fn publish_output(
        &self,
        output: &ReadyOutputFrame,
    ) -> Result<(), &'static str> {
        lock(&self.broker).publish(output)
    }

    pub(in crate::flutter_runtime) fn authorize_outputs(
        &self,
        requests: &[OutputFrameRequest],
        views: &mut Vec<i64>,
    ) {
        views.clear();
        let mut broker = lock(&self.broker);
        let now = Instant::now();
        for request in requests {
            if let Some(view) = broker.authorize(*request, now) {
                views.push(view);
            }
        }
    }

    pub(in crate::flutter_runtime) fn output_target_available(&self, output: OutputId) -> bool {
        lock(&self.broker).target_available(output)
    }

    pub(in crate::flutter_runtime) fn with_output_target_availability<T>(
        &self,
        now: Instant,
        action: impl FnOnce(&mut dyn FnMut(OutputId) -> bool) -> T,
    ) -> (T, usize) {
        let mut broker = lock(&self.broker);
        let expired = broker.expire_authorizations(now);
        let mut target_available = |output| broker.target_available(output);
        (action(&mut target_available), expired)
    }

    pub(in crate::flutter_runtime) fn cancel_output_authorizations(&self, render_view_ids: &[i64]) {
        lock(&self.broker).cancel_authorizations(render_view_ids);
    }

    pub(in crate::flutter_runtime) fn release_output(
        &self,
        output: OutputId,
        index: usize,
    ) -> Result<(), &'static str> {
        lock(&self.broker).release_output(output, index)
    }

    pub(in crate::flutter_runtime) fn retain_output(
        &self,
        output: OutputId,
        index: usize,
    ) -> Result<(), &'static str> {
        lock(&self.broker).retain_output(output, index)
    }

    pub(in crate::flutter_runtime) fn tag_next_frame_for_screenshot(
        &self,
        output: OutputId,
        request_id: u64,
    ) -> Result<(), &'static str> {
        lock(&self.broker).tag_next_frame_for_screenshot(output, request_id)
    }

    pub(in crate::flutter_runtime) fn cancel_screenshot_frame(&self, request_id: u64) {
        lock(&self.broker).cancel_screenshot_frame(request_id);
    }

    pub(in crate::flutter_runtime) fn set_external_texture_sources(
        &self,
        frames: impl IntoIterator<Item = ExternalTextureFrame>,
        changed: &mut Vec<i64>,
    ) {
        let mut sources = lock(&self.external_texture_sources);
        for ExternalTextureFrame {
            texture_id,
            source,
            expects_sample,
        } in frames
        {
            if sources
                .entry(texture_id)
                .or_default()
                .queue(source, expects_sample)
            {
                changed.push(texture_id);
            }
        }
    }

    pub(in crate::flutter_runtime) fn advance_external_texture_sources(
        &self,
        texture_ids: &[i64],
        deferred: &mut Vec<i64>,
    ) {
        let mut sources = lock(&self.external_texture_sources);
        for texture_id in texture_ids {
            if let Some(slot) = sources.get_mut(texture_id) {
                slot.advance();
                if slot.has_queued() {
                    deferred.push(*texture_id);
                }
            }
        }
    }

    pub(in crate::flutter_runtime) fn advance_all_external_texture_sources(
        &self,
        changed: &mut Vec<i64>,
    ) {
        let mut sources = lock(&self.external_texture_sources);
        for (texture_id, slot) in sources.iter_mut() {
            if slot.advance() {
                changed.push(*texture_id);
            }
        }
    }

    pub(in crate::flutter_runtime) fn current_external_texture(
        &self,
        texture_id: i64,
    ) -> Option<ExternalTextureSource> {
        lock(&self.external_texture_sources)
            .get(&texture_id)?
            .current
            .clone()
    }

    pub(in crate::flutter_runtime) fn mark_external_texture_sampled(
        &self,
        texture_id: i64,
        generation: u64,
    ) {
        let mut sources = lock(&self.external_texture_sources);
        let Some(slot) = sources.get_mut(&texture_id) else {
            return;
        };
        if slot
            .current
            .as_ref()
            .is_some_and(|source| source.generation() == generation)
        {
            slot.current_sampled = true;
        }
    }

    pub(in crate::flutter_runtime) fn record_sampled_buffer(
        &self,
        texture_id: i64,
        generation: u64,
        buffer_guard: ExternalBufferGuard,
    ) {
        let mut sampled = lock(&self.raster_sampled_buffers);
        if sampled
            .iter()
            .any(|hold| hold.texture_id == texture_id && hold.generation == generation)
        {
            return;
        }
        sampled.push(SampledBufferHold {
            texture_id,
            generation,
            buffer_guard,
        });
    }

    pub(in crate::flutter_runtime) fn seal_sampled_buffers(
        &self,
    ) -> Option<SampledBufferHoldBatch> {
        let mut sampled = lock(&self.raster_sampled_buffers);
        if sampled.is_empty() {
            return None;
        }
        let mut replacement = lock(&self.sampled_buffer_batch_pool)
            .pop()
            .unwrap_or_default();
        debug_assert!(replacement.is_empty());
        mem::swap(&mut *sampled, &mut replacement);
        Some(SampledBufferHoldBatch {
            holds: Some(replacement),
            pool: Arc::downgrade(&self.sampled_buffer_batch_pool),
        })
    }

    pub(in crate::flutter_runtime) fn rearm_abandoned_samples(&self) {
        let sampled = lock(&self.raster_sampled_buffers);
        if sampled.is_empty() {
            return;
        }
        let mut sources = lock(&self.external_texture_sources);
        for hold in sampled.iter() {
            let Some(slot) = sources.get_mut(&hold.texture_id) else {
                continue;
            };
            if slot
                .current
                .as_ref()
                .is_some_and(|source| source.generation() == hold.generation)
            {
                slot.current_sampled = false;
            }
        }
    }

    pub(in crate::flutter_runtime) fn publish_sampled_buffer_release(
        &self,
        fence: Option<OwnedFd>,
        batch: Option<SampledBufferHoldBatch>,
    ) -> bool {
        let Some(batch) = batch else {
            return true;
        };
        match self
            .events
            .send(RuntimeEvent::SampledBuffersReady { fence, batch })
        {
            Ok(()) => true,
            Err(error) => {
                // The event-loop owner disappeared before it could watch the
                // sync_file. Complete the command stream before retaining the
                // orphaned event through process teardown.
                // SAFETY: this helper is called only by render-thread
                // callbacks while Flutter's GLES context is current.
                unsafe { (self.gl.finish)() };
                // The compositor receiver no longer exists, so there is no
                // sound Wayland thread on which to release these guards.
                // Preserve them through process teardown instead of running
                // wl_buffer.release from Flutter's raster thread.
                mem::forget(error);
                false
            }
        }
    }

    pub(in crate::flutter_runtime) fn remove_external_texture_source(&self, texture_id: i64) {
        lock(&self.external_texture_sources).remove(&texture_id);
        let retired_dmabufs = lock(&self.dmabuf_texture_cache).remove(&texture_id);
        let retired_native = lock(&self.retained_native_texture_cache).remove(&texture_id);
        let retired_shm =
            lock(&self.shm_texture_cache).remove_where(|(owner, _)| *owner == texture_id);
        // Dropping a cache reference never issues GL calls. If no Flutter
        // lease still references the binding, its Drop queues destruction for
        // the next callback with the raster context current.
        drop((retired_dmabufs, retired_native, retired_shm));
    }

    pub(in crate::flutter_runtime) fn cached_dmabuf_binding(
        &self,
        texture_id: i64,
        dmabuf: &Dmabuf,
    ) -> Option<Arc<CachedTextureBinding>> {
        lock(&self.dmabuf_texture_cache).get_by(&texture_id, |cached| cached == dmabuf)
    }

    pub(in crate::flutter_runtime) fn cache_dmabuf_binding(
        &self,
        texture_id: i64,
        dmabuf: Dmabuf,
        binding: Arc<CachedTextureBinding>,
    ) {
        let retired = lock(&self.dmabuf_texture_cache).insert(texture_id, dmabuf, binding);
        drop(retired);
    }

    pub(in crate::flutter_runtime) fn cached_retained_native_binding(
        &self,
        texture_id: i64,
        revision: u64,
    ) -> Option<Arc<CachedTextureBinding>> {
        lock(&self.retained_native_texture_cache)
            .get_by(&texture_id, |cached_revision| *cached_revision == revision)
    }

    pub(in crate::flutter_runtime) fn cache_retained_native_binding(
        &self,
        texture_id: i64,
        revision: u64,
        binding: Arc<CachedTextureBinding>,
    ) {
        let retired =
            lock(&self.retained_native_texture_cache).insert(texture_id, revision, binding);
        drop(retired);
    }

    pub(in crate::flutter_runtime) fn cached_shm_binding(
        &self,
        texture_id: i64,
        revision: u64,
    ) -> Option<Arc<CachedTextureBinding>> {
        lock(&self.shm_texture_cache)
            .get_by(|(owner, cached_revision)| *owner == texture_id && *cached_revision == revision)
    }

    pub(in crate::flutter_runtime) fn cache_shm_binding(
        &self,
        texture_id: i64,
        revision: u64,
        binding: Arc<CachedTextureBinding>,
    ) {
        let retired = lock(&self.shm_texture_cache).insert((texture_id, revision), binding);
        drop(retired);
    }

    pub(in crate::flutter_runtime) fn lease_external_texture(
        &self,
        resource: ExternalTextureLeaseResource,
    ) -> Box<ExternalTextureLease> {
        let mut lease = lock(&self.external_texture_lease_pool)
            .pop()
            .unwrap_or_else(|| {
                Box::new(ExternalTextureLease {
                    resource: None,
                    pool: Arc::downgrade(&self.external_texture_lease_pool),
                })
            });
        debug_assert!(lease.resource.is_none());
        lease.resource = Some(resource);
        lease
    }

    pub(in crate::flutter_runtime) fn complete_vsync(&self, baton: isize) {
        lock(&self.pending_vsync_batons).complete(baton);
    }

    pub(in crate::flutter_runtime) fn take_pending_vsync_batons(&self) -> VecDeque<isize> {
        lock(&self.pending_vsync_batons).take_all()
    }

    pub(in crate::flutter_runtime) fn take_next_vsync(&self) -> (Option<isize>, bool) {
        let mut pending = lock(&self.pending_vsync_batons);
        let baton = pending.take_next();
        (baton, pending.has_pending())
    }

    pub(in crate::flutter_runtime) fn restore_vsync(&self, baton: isize) {
        lock(&self.pending_vsync_batons).restore_front(baton);
    }

    pub(in crate::flutter_runtime) fn has_pending_vsync(&self) -> bool {
        lock(&self.pending_vsync_batons).has_pending()
    }

    pub(in crate::flutter_runtime) fn try_request_frame(&self) -> bool {
        self.producer.try_request(Instant::now())
    }

    pub(in crate::flutter_runtime) fn cancel_requested_frame(&self) {
        self.producer.cancel_request();
    }

    pub(in crate::flutter_runtime) fn begin_raster_frame(&self) -> bool {
        self.producer.begin_raster()
    }

    pub(in crate::flutter_runtime) fn begin_present(&self) {
        self.producer.begin_present();
    }

    pub(in crate::flutter_runtime) fn finish_producer_frame(&self) -> FlutterProducerState {
        self.producer.finish()
    }

    pub(in crate::flutter_runtime) fn acknowledge_frame_ready(&self) {
        self.frame_ready_wakeup.acknowledge();
    }

    pub(in crate::flutter_runtime) fn publish_ready_frames(
        &self,
        frames: Vec<ReadyOutputFrame>,
    ) -> bool {
        if frames.is_empty() {
            return true;
        }
        lock(&self.ready_frames).extend(frames);
        if !self.frame_ready_wakeup.begin() {
            return true;
        }
        let sent = self
            .events
            .send(RuntimeEvent::FrameReady {
                generation: self.generation,
            })
            .is_ok();
        if !sent {
            self.frame_ready_wakeup.acknowledge();
        }
        sent
    }

    pub(in crate::flutter_runtime) fn take_platform_tasks(
        &self,
        output: &mut Vec<PendingPlatformTask>,
    ) {
        self.platform_tasks.take_into(output);
    }

    pub(in crate::flutter_runtime) fn report_queue_overflow(&self, queue: &'static str) {
        if !self.queue_overflow_wakeup.begin() {
            return;
        }
        if self
            .events
            .send(RuntimeEvent::QueueOverflow {
                generation: self.generation,
                queue,
            })
            .is_err()
        {
            self.queue_overflow_wakeup.acknowledge();
        }
    }

    pub(in crate::flutter_runtime) fn blit_to_scanout(&self, render_framebuffer: u32) -> bool {
        let target = lock(&self.targets)
            .iter()
            .find(|target| target.render_framebuffer == render_framebuffer)
            .copied();
        let Some(target) = target else {
            error!(
                framebuffer = render_framebuffer,
                "Flutter presented an unknown physical-output target"
            );
            return false;
        };
        if !target.needs_blit() {
            return true;
        }

        let Some(shader_blit) = *lock(&self.shader_blit) else {
            error!("offscreen Flutter target has no shader-copy pipeline");
            return false;
        };

        // The raster commands and this draw share one GLES context, so command
        // ordering makes the completed LINEAR scene texture available without
        // a CPU wait. Use ordinary texture sampling into the compressed KMS
        // target instead of glBlitFramebuffer: the latter enters a faulty CP
        // copy path on this Adreno and eventually faults while reading IOVA 0.
        let width = target.size.width as i32;
        let height = target.size.height as i32;
        let mut previous_draw_framebuffer = 0;
        let mut previous_program = 0;
        let mut previous_active_texture = 0;
        let mut previous_texture_2d = 0;
        let mut previous_viewport = [0; 4];
        let mut previous_color_mask = [gl::FALSE; 4];
        let mut previous_capabilities = [false; 5];
        // SAFETY: Flutter invokes present with this handler's render context
        // current, and every GL object below remains live in this handler.
        unsafe {
            for _ in 0..8 {
                if (self.gl.get_error)() == gl::NO_ERROR {
                    break;
                }
            }
            (self.gl.get_integer_v)(gl::DRAW_FRAMEBUFFER_BINDING, &mut previous_draw_framebuffer);
            (self.gl.get_integer_v)(gl::CURRENT_PROGRAM, &mut previous_program);
            (self.gl.get_integer_v)(gl::ACTIVE_TEXTURE, &mut previous_active_texture);
            (self.gl.get_integer_v)(gl::VIEWPORT, previous_viewport.as_mut_ptr());
            (self.gl.get_boolean_v)(gl::COLOR_WRITEMASK, previous_color_mask.as_mut_ptr());
            for (saved, capability) in previous_capabilities.iter_mut().zip([
                gl::BLEND,
                gl::CULL_FACE,
                gl::DEPTH_TEST,
                gl::SCISSOR_TEST,
                gl::STENCIL_TEST,
            ]) {
                *saved = (self.gl.is_enabled)(capability) == gl::TRUE;
            }
            (self.gl.active_texture)(gl::TEXTURE0);
            (self.gl.get_integer_v)(gl::TEXTURE_BINDING_2D, &mut previous_texture_2d);

            (self.gl.bind_framebuffer)(gl::DRAW_FRAMEBUFFER, target.scanout_framebuffer);
            (self.gl.viewport)(0, 0, width, height);
            (self.gl.disable)(gl::BLEND);
            (self.gl.disable)(gl::CULL_FACE);
            (self.gl.disable)(gl::DEPTH_TEST);
            (self.gl.disable)(gl::SCISSOR_TEST);
            (self.gl.disable)(gl::STENCIL_TEST);
            (self.gl.color_mask)(gl::TRUE, gl::TRUE, gl::TRUE, gl::TRUE);
            (self.gl.use_program)(shader_blit.program);
            (self.gl.active_texture)(gl::TEXTURE0);
            (self.gl.bind_texture)(gl::TEXTURE_2D, target.render_texture);
            (self.gl.uniform_1i)(shader_blit.source_uniform, 0);
            (self.gl.draw_arrays)(gl::TRIANGLES, 0, 3);
        }
        // SAFETY: the same render context remains current after the blit.
        let draw_error = unsafe { (self.gl.get_error)() };
        // Skia caches GLES state across frames. Restore every binding and
        // fixed-function value touched by the copy so the following Flutter
        // frame cannot inherit a stale program, texture, mask, or capability.
        // SAFETY: all values were queried from this same current context.
        unsafe {
            (self.gl.use_program)(previous_program as u32);
            (self.gl.bind_texture)(gl::TEXTURE_2D, previous_texture_2d as u32);
            (self.gl.active_texture)(previous_active_texture as u32);
            (self.gl.bind_framebuffer)(gl::DRAW_FRAMEBUFFER, previous_draw_framebuffer as u32);
            (self.gl.viewport)(
                previous_viewport[0],
                previous_viewport[1],
                previous_viewport[2],
                previous_viewport[3],
            );
            (self.gl.color_mask)(
                previous_color_mask[0],
                previous_color_mask[1],
                previous_color_mask[2],
                previous_color_mask[3],
            );
            for (enabled, capability) in previous_capabilities.into_iter().zip([
                gl::BLEND,
                gl::CULL_FACE,
                gl::DEPTH_TEST,
                gl::SCISSOR_TEST,
                gl::STENCIL_TEST,
            ]) {
                if enabled {
                    (self.gl.enable)(capability);
                } else {
                    (self.gl.disable)(capability);
                }
            }
        }
        // SAFETY: the same render context remains current after restoration.
        let restore_error = unsafe { (self.gl.get_error)() };
        let error = if draw_error != gl::NO_ERROR {
            draw_error
        } else {
            restore_error
        };
        if error != gl::NO_ERROR {
            error!(
                framebuffer = render_framebuffer,
                scanout_framebuffer = target.scanout_framebuffer,
                error = format_args!("{error:#x}"),
                "Flutter scene-to-scanout shader copy failed"
            );
            return false;
        }
        true
    }

    pub(in crate::flutter_runtime) fn retain_native_texture(
        &self,
        source_texture: u32,
        width: u32,
        height: u32,
    ) -> Result<Arc<CachedTextureBinding>, Box<dyn Error>> {
        let width_i32 = i32::try_from(width).map_err(|_| "native snapshot width exceeds GLES")?;
        let height_i32 =
            i32::try_from(height).map_err(|_| "native snapshot height exceeds GLES")?;
        if source_texture == 0 || width_i32 <= 0 || height_i32 <= 0 {
            return Err("native snapshot has invalid texture or dimensions".into());
        }
        let binding_permit = self
            .external_texture_resource_budget
            .try_acquire()
            .ok_or("native snapshot exceeded the external texture resource limit")?;
        let shader_blit = lock(&self.shader_blit)
            .as_ref()
            .copied()
            .ok_or("native snapshot has no GLES copy pipeline")?;

        let mut previous_draw_framebuffer = 0;
        let mut previous_program = 0;
        let mut previous_active_texture = 0;
        let mut previous_texture_2d = 0;
        let mut previous_viewport = [0; 4];
        let mut previous_color_mask = [gl::FALSE; 4];
        let mut previous_capabilities = [false; 5];
        let mut texture = 0;
        let mut framebuffer = 0;
        let framebuffer_status;
        let draw_error;

        // The callback owns Flutter's current GLES context. Save and restore
        // every state touched by the private copy so Skia cannot observe the
        // snapshot operation in the surrounding external-texture callback.
        // SAFETY: all queried pointers are valid local storage and every GL
        // object is created, used, and either retained or deleted in this call.
        unsafe {
            for _ in 0..8 {
                if (self.gl.get_error)() == gl::NO_ERROR {
                    break;
                }
            }
            (self.gl.get_integer_v)(gl::DRAW_FRAMEBUFFER_BINDING, &mut previous_draw_framebuffer);
            (self.gl.get_integer_v)(gl::CURRENT_PROGRAM, &mut previous_program);
            (self.gl.get_integer_v)(gl::ACTIVE_TEXTURE, &mut previous_active_texture);
            (self.gl.get_integer_v)(gl::VIEWPORT, previous_viewport.as_mut_ptr());
            (self.gl.get_boolean_v)(gl::COLOR_WRITEMASK, previous_color_mask.as_mut_ptr());
            for (saved, capability) in previous_capabilities.iter_mut().zip([
                gl::BLEND,
                gl::CULL_FACE,
                gl::DEPTH_TEST,
                gl::SCISSOR_TEST,
                gl::STENCIL_TEST,
            ]) {
                *saved = (self.gl.is_enabled)(capability) == gl::TRUE;
            }
            (self.gl.active_texture)(gl::TEXTURE0);
            (self.gl.get_integer_v)(gl::TEXTURE_BINDING_2D, &mut previous_texture_2d);

            (self.gl.gen_textures)(1, &mut texture);
            (self.gl.bind_texture)(gl::TEXTURE_2D, texture);
            (self.gl.tex_parameter_i)(gl::TEXTURE_2D, gl::TEXTURE_MIN_FILTER, gl::LINEAR as i32);
            (self.gl.tex_parameter_i)(gl::TEXTURE_2D, gl::TEXTURE_MAG_FILTER, gl::LINEAR as i32);
            (self.gl.tex_parameter_i)(gl::TEXTURE_2D, gl::TEXTURE_WRAP_S, gl::CLAMP_TO_EDGE as i32);
            (self.gl.tex_parameter_i)(gl::TEXTURE_2D, gl::TEXTURE_WRAP_T, gl::CLAMP_TO_EDGE as i32);
            (self.gl.tex_image_2d)(
                gl::TEXTURE_2D,
                0,
                gl::RGBA8 as i32,
                width_i32,
                height_i32,
                0,
                gl::RGBA,
                gl::UNSIGNED_BYTE,
                ptr::null(),
            );
            (self.gl.gen_framebuffers)(1, &mut framebuffer);
            (self.gl.bind_framebuffer)(gl::DRAW_FRAMEBUFFER, framebuffer);
            (self.gl.framebuffer_texture_2d)(
                gl::DRAW_FRAMEBUFFER,
                gl::COLOR_ATTACHMENT0,
                gl::TEXTURE_2D,
                texture,
                0,
            );
            framebuffer_status = (self.gl.check_framebuffer_status)(gl::DRAW_FRAMEBUFFER);
            if texture != 0 && framebuffer != 0 && framebuffer_status == gl::FRAMEBUFFER_COMPLETE {
                (self.gl.viewport)(0, 0, width_i32, height_i32);
                (self.gl.disable)(gl::BLEND);
                (self.gl.disable)(gl::CULL_FACE);
                (self.gl.disable)(gl::DEPTH_TEST);
                (self.gl.disable)(gl::SCISSOR_TEST);
                (self.gl.disable)(gl::STENCIL_TEST);
                (self.gl.color_mask)(gl::TRUE, gl::TRUE, gl::TRUE, gl::TRUE);
                (self.gl.use_program)(shader_blit.program);
                (self.gl.active_texture)(gl::TEXTURE0);
                (self.gl.bind_texture)(gl::TEXTURE_2D, source_texture);
                (self.gl.uniform_1i)(shader_blit.source_uniform, 0);
                (self.gl.draw_arrays)(gl::TRIANGLES, 0, 3);
            }
            draw_error = (self.gl.get_error)();

            (self.gl.use_program)(previous_program as u32);
            (self.gl.bind_texture)(gl::TEXTURE_2D, previous_texture_2d as u32);
            (self.gl.active_texture)(previous_active_texture as u32);
            (self.gl.bind_framebuffer)(gl::DRAW_FRAMEBUFFER, previous_draw_framebuffer as u32);
            (self.gl.viewport)(
                previous_viewport[0],
                previous_viewport[1],
                previous_viewport[2],
                previous_viewport[3],
            );
            (self.gl.color_mask)(
                previous_color_mask[0],
                previous_color_mask[1],
                previous_color_mask[2],
                previous_color_mask[3],
            );
            for (enabled, capability) in previous_capabilities.into_iter().zip([
                gl::BLEND,
                gl::CULL_FACE,
                gl::DEPTH_TEST,
                gl::SCISSOR_TEST,
                gl::STENCIL_TEST,
            ]) {
                if enabled {
                    (self.gl.enable)(capability);
                } else {
                    (self.gl.disable)(capability);
                }
            }
            if framebuffer != 0 {
                (self.gl.delete_framebuffers)(1, &framebuffer);
            }
        }
        // SAFETY: the same render context remains current after restoration.
        let restore_error = unsafe { (self.gl.get_error)() };
        if texture == 0
            || framebuffer == 0
            || framebuffer_status != gl::FRAMEBUFFER_COMPLETE
            || draw_error != gl::NO_ERROR
            || restore_error != gl::NO_ERROR
        {
            // SAFETY: an allocated texture remains owned by this context and
            // has not escaped on the failure path.
            unsafe {
                if texture != 0 {
                    (self.gl.delete_textures)(1, &texture);
                }
            }
            return Err(format!(
                "native snapshot copy failed: framebuffer={framebuffer} status={framebuffer_status:#x} draw={draw_error:#x} restore={restore_error:#x}"
            )
            .into());
        }
        Ok(Arc::new(CachedTextureBinding {
            binding: Some(ExternalTextureBinding {
                dmabuf_image: None,
                texture,
                _resource_permit: binding_permit,
            }),
            retirements: Arc::clone(&self.retired_external_bindings),
        }))
    }

    pub(in crate::flutter_runtime) fn destroy_targets(&self) {
        let mut targets = lock(&self.targets);
        let mut shader_blit = lock(&self.shader_blit);
        let mut depth_stencils = lock(&self.depth_stencils);
        if targets.is_empty() && shader_blit.is_none() && depth_stencils.is_empty() {
            return;
        }
        let mut context = lock(&self.render_context);
        // SAFETY: EngineHost has already shut down and joined its raster
        // thread, so this context is no longer current anywhere else.
        if let Err(error) = unsafe { context.context.make_current() } {
            error!(%error, "could not bind Flutter context for output-target cleanup");
            return;
        }
        context.owner = Some(thread::current().id());
        let cached_dmabufs = lock(&self.dmabuf_texture_cache).drain();
        let cached_native = lock(&self.retained_native_texture_cache).drain();
        let cached_shm = lock(&self.shm_texture_cache).drain();
        drop((cached_dmabufs, cached_native, cached_shm));
        self.destroy_retired_external_bindings();
        if let Some(gpu_timing) = &self.gpu_timing {
            lock(gpu_timing).clear();
        }
        destroy_shader_blit(self.gl, &mut shader_blit);
        destroy_targets(self.gl, &self.display, &mut targets);
        destroy_depth_stencils(self.gl, &mut depth_stencils);
        let _ = context.clear_current();
    }

    pub(in crate::flutter_runtime) fn destroy_retired_external_bindings(&self) {
        // The flag is a hint in front of the mutex-protected queue. Missing a
        // concurrent transition here only defers reclamation to the next
        // callback; it cannot lose the queued binding or clear the flag.
        if !self
            .retired_external_bindings
            .pending
            .load(Ordering::Relaxed)
        {
            return;
        }
        if !self
            .retired_external_bindings
            .pending
            .swap(false, Ordering::Relaxed)
        {
            return;
        }
        let mut retired = lock(&self.retired_external_binding_scratch);
        debug_assert!(retired.is_empty());
        {
            let mut pending = lock(&self.retired_external_bindings.bindings);
            mem::swap(&mut *retired, &mut *pending);
        }
        for binding in retired.drain(..) {
            // SAFETY: this is called only with the Flutter render context
            // current, and every object was created by that context.
            unsafe {
                if binding.texture != 0 {
                    (self.gl.delete_textures)(1, &binding.texture);
                }
                if let Some((_dmabuf, image)) = binding.dmabuf_image
                    && image != 0
                {
                    egl_ffi::egl::DestroyImageKHR(
                        self.display.handle,
                        image as egl_ffi::egl::types::EGLImageKHR,
                    );
                }
            }
        }
    }

    /// Reserves a cache hit for the immediately following Flutter texture
    /// callback without issuing GL calls. Holding the binding and Wayland
    /// guard here closes the race between the engine's preflight and callback.
    pub(in crate::flutter_runtime) fn prepare_external_texture_without_gl(
        &self,
        texture_id: i64,
    ) -> bool {
        let mut prepared_slot = lock(&self.prepared_external_texture);
        if prepared_slot.take().is_some() {
            return false;
        }
        if self
            .retired_external_bindings
            .pending
            .load(Ordering::Relaxed)
        {
            return false;
        }
        let Some(source) = self.current_external_texture(texture_id) else {
            return false;
        };
        let source_generation = source.generation();
        let Some(lease_permit) = self.external_texture_resource_budget.try_acquire() else {
            return false;
        };
        let (width, height, binding, resource, sampled_buffer) = match source {
            ExternalTextureSource::Dmabuf {
                dmabuf,
                buffer_guard,
                revision,
            } => {
                let dmabuf_width = dmabuf.width();
                let dmabuf_height = dmabuf.height();
                let width = usize::try_from(dmabuf_width).unwrap_or_default();
                let height = usize::try_from(dmabuf_height).unwrap_or_default();
                if buffer_guard
                    .as_ref()
                    .is_some_and(ExternalBufferGuard::is_native)
                {
                    let Some(binding) = self.cached_retained_native_binding(texture_id, revision)
                    else {
                        return false;
                    };
                    let resource = ExternalTextureLeaseResource::Retained {
                        _binding: Arc::clone(&binding),
                        _resource_permit: lease_permit,
                    };
                    (width, height, binding, resource, None)
                } else {
                    let Some(binding) = self.cached_dmabuf_binding(texture_id, &dmabuf) else {
                        return false;
                    };
                    let sampled_buffer = buffer_guard.clone();
                    let resource = ExternalTextureLeaseResource::Dmabuf {
                        _binding: Arc::clone(&binding),
                        _buffer_guard: buffer_guard,
                        _resource_permit: lease_permit,
                    };
                    (width, height, binding, resource, sampled_buffer)
                }
            }
            ExternalTextureSource::Shm(frame) => {
                let width = usize::try_from(frame.width).unwrap_or_default();
                let height = usize::try_from(frame.height).unwrap_or_default();
                let Some(binding) = self.cached_shm_binding(texture_id, frame.revision) else {
                    return false;
                };
                let resource = ExternalTextureLeaseResource::Shm {
                    _binding: Arc::clone(&binding),
                    _resource_permit: lease_permit,
                };
                (width, height, binding, resource, None)
            }
        };
        let name = binding.texture();
        if width == 0 || height == 0 || name == 0 {
            return false;
        }
        *prepared_slot = Some(PreparedExternalTexture {
            texture_id,
            source_generation,
            width,
            height,
            name,
            resource,
            sampled_buffer,
        });
        true
    }

    /// Drain the bounded GLES error queue while the Flutter render context is
    /// current. Returning the first error lets callers reject a partially
    /// created texture without caching or publishing it to Flutter.
    pub(in crate::flutter_runtime) fn take_gl_error(&self) -> Option<u32> {
        const GL_NO_ERROR: u32 = 0;
        const MAX_DRAINED_ERRORS: usize = 16;

        let mut first = None;
        for _ in 0..MAX_DRAINED_ERRORS {
            // SAFETY: every caller runs from a Flutter callback with this
            // handler's render context current.
            let error = unsafe { (self.gl.get_error)() };
            if error == GL_NO_ERROR {
                break;
            }
            first.get_or_insert(error);
        }
        first
    }
}

pub(in crate::flutter_runtime) fn vm_service_uri_from_log(message: &str) -> Option<&str> {
    const MAX_VM_SERVICE_URI_BYTES: usize = 2048;
    const ANNOUNCEMENT: &str = "The Dart VM service is listening on ";
    const LOOPBACK_PREFIX: &str = "http://127.0.0.1:";
    let start = message
        .find(ANNOUNCEMENT)?
        .checked_add(ANNOUNCEMENT.len())?;
    let uri = message[start..]
        .split_ascii_whitespace()
        .next()?
        .trim_end_matches(['.', ',', ';']);
    if uri.len() > MAX_VM_SERVICE_URI_BYTES {
        return None;
    }
    let authority_and_path = uri.strip_prefix(LOOPBACK_PREFIX)?;
    let (port, authentication_path) = authority_and_path.split_once('/')?;
    if port.parse::<u16>().ok().is_none_or(|port| port == 0)
        || authentication_path.is_empty()
        || !authentication_path
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'/' | b'=' | b'_' | b'-'))
    {
        return None;
    }
    Some(uri)
}
