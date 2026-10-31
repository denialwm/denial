//! Flutter embedder callbacks and the renderer's runtime-facing handler.

use super::*;

#[path = "handler/gpu_deadline.rs"]
mod gpu_deadline;
#[path = "handler/native_client.rs"]
pub(super) mod native_client;
#[path = "handler/open_gl.rs"]
mod open_gl;
use native_client::NativeClientState;

/// Window grading on the render thread: one 3D texture per app look, and
/// the graded copy of each window texture that needs one.
#[derive(Default)]
struct WindowGrades {
    looks: Vec<(Arc<crate::output_color::Lut>, u32)>,
    graded: HashMap<i64, GradedTexture>,
}

/// What a window texture's copy does: the surface's own conversion into the
/// scene and its alpha mode, then its app's look.
#[derive(Clone)]
struct Grade {
    transform: Option<crate::color_space::SurfaceTransform>,
    alpha: crate::color_space::AlphaMode,
    look: Option<Arc<crate::output_color::Lut>>,
}

impl Grade {
    fn same(&self, other: &Self) -> bool {
        self.transform == other.transform
            && self.alpha == other.alpha
            && match (&self.look, &other.look) {
                (Some(a), Some(b)) => Arc::ptr_eq(a, b),
                (None, None) => true,
                _ => false,
            }
    }

    /// Converted HDR or extended content keeps more than 8 bits.
    fn float(&self) -> bool {
        self.transform.is_some_and(|transform| transform.float)
    }

    fn conversion(&self) -> Option<Conversion> {
        match self.transform {
            Some(transform) => Some(Conversion {
                decode: transform.decode,
                params: transform.params,
                matrix: transform.matrix,
                luma: transform.luma,
                tone: transform.tone,
            }),
            // Alpha premultiplied in light needs the decode even when the
            // pixels are the scene encoding.
            None if self.alpha == crate::color_space::AlphaMode::PremultipliedOptical => {
                Some(Conversion {
                    decode: 0,
                    params: [2.2, 0.0, 0.0, 0.0],
                    matrix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
                    luma: [0.2126, 0.7152, 0.0722],
                    tone: [1.0, 1.0, 1.0, 0.0],
                })
            }
            None => None,
        }
    }
}

struct GradedTexture {
    /// The source texture name and generation this copy was graded from.
    source: (u32, u64),
    grade: Grade,
    size: (usize, usize),
    float: bool,
    binding: Arc<CachedTextureBinding>,
    /// Earlier copies of this size and format; one the engine has let go is
    /// regraded instead of allocating, since the engine holds the last image
    /// while the next buffer is graded.
    spares: Vec<Arc<CachedTextureBinding>>,
}

const MAX_GRADED_SPARES: usize = 2;

impl WindowGrades {
    fn look_texture(
        &mut self,
        gl: GlApi,
        look: &Arc<crate::output_color::Lut>,
    ) -> Result<u32, u32> {
        if let Some((_, texture)) = self.looks.iter().find(|(held, _)| Arc::ptr_eq(held, look)) {
            return Ok(*texture);
        }
        let texture = create_look_texture(gl, &look.texels, look.size)?;
        self.looks.push((Arc::clone(look), texture));
        Ok(texture)
    }

    /// Delete looks no app and no graded copy holds any more.
    fn prune_looks(&mut self, gl: GlApi) {
        self.looks.retain(|(look, texture)| {
            let held = Arc::strong_count(look) > 1;
            if !held {
                delete_look_texture(gl, *texture);
            }
            held
        });
    }

    fn clear(&mut self, gl: GlApi) {
        self.graded.clear();
        for (_, texture) in self.looks.drain(..) {
            delete_look_texture(gl, texture);
        }
    }
}

#[derive(Clone, Copy, Debug)]
struct PendingOutputPresentation {
    view_id: i64,
    framebuffer: u32,
    presentation_time_nanos: u64,
}

pub(in crate::flutter_runtime) struct FlutterGlHandler {
    render_context: Mutex<ContextBinding>,
    resource_context: Mutex<ContextBinding>,
    display: Arc<EGLDisplayHandle>,
    gl: GlApi,
    targets: Mutex<Vec<GlTarget>>,
    transfers: HashMap<u32, Arc<crate::gpu_transfer::TransferTarget>>,
    pub(in crate::flutter_runtime) completion_owner: Mutex<Weak<FlutterGlHandler>>,
    shader_blit: Mutex<Option<ShaderBlit>>,
    /// App ids by external texture, for app looks.
    texture_apps: Mutex<HashMap<i64, Arc<str>>>,
    window_grades: Mutex<WindowGrades>,
    depth_stencils: Mutex<Vec<u32>>,
    broker: Mutex<OutputBufferBroker>,
    pending_output_presentation: Mutex<Option<PendingOutputPresentation>>,
    gpu_deadline_hints: gpu_deadline::GpuDeadlineHints,
    external_texture_sources: Mutex<HashMap<i64, ExternalTextureSlot>>,
    native_clients: Mutex<NativeClientState>,
    native_fallback_pending: AtomicBool,
    raster_sampled_buffers: Mutex<Vec<SampledBufferHold>>,
    raster_sampled_feedback: Mutex<Vec<crate::surface_feedback::SurfaceFeedback>>,
    sampled_buffer_release_fence: Mutex<Option<OwnedFd>>,
    sampled_buffer_batch_pool: Arc<SampledBufferBatchPool>,
    dmabuf_texture_cache: Mutex<PartitionedRecencyCache<i64, Dmabuf, Arc<CachedTextureBinding>>>,
    shm_texture_cache: Mutex<RecencyCache<(i64, u64), Arc<CachedTextureBinding>>>,
    retired_external_bindings: Arc<RetiredExternalBindingQueue>,
    retired_external_binding_scratch: Mutex<Vec<ExternalTextureBinding>>,
    external_texture_lease_pool: Arc<ExternalTextureLeasePool>,
    leased_buffers: Mutex<HashMap<i64, Vec<Weak<LeasedBuffer>>>>,
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
    shutdown_started: AtomicBool,
}

impl FlutterGlHandler {
    pub(in crate::flutter_runtime) fn assign_generation(&mut self, generation: u64) {
        self.generation = generation;
    }

    pub(in crate::flutter_runtime) fn new<'a>(
        render_context: egl_context::SharedEglContext,
        resource_context: egl_context::SharedEglContext,
        output_pools: impl IntoIterator<Item = OutputRenderTargetPool<'a>>,
        desktop_size: PixelSize,
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
        let mut depth_stencils = Vec::new();
        info!(
            offscreen_blit,
            "creating Flutter physical-output texture targets"
        );
        let mut targets = Vec::new();
        let mut broker_descriptors = Vec::new();
        let mut transfers = HashMap::new();

        for pool in output_pools {
            let width =
                i32::try_from(pool.size.width).map_err(|_| "Flutter output width exceeds GLES")?;
            let height = i32::try_from(pool.size.height)
                .map_err(|_| "Flutter output height exceeds GLES")?;
            let mut depth_stencil = 0;
            // Impeller wraps Denial's supplied FBO. One packed attachment can
            // be shared by one output's rotating FBOs because the raster
            // runner is serial and clears it for each render pass.
            // SAFETY: this new GLES context is current and the arguments and
            // output pointer are valid.
            unsafe {
                let _ = (gl.get_error)();
                (gl.gen_renderbuffers)(1, &mut depth_stencil);
                (gl.bind_renderbuffer)(gl::RENDERBUFFER, depth_stencil);
                (gl.renderbuffer_storage)(gl::RENDERBUFFER, gl::DEPTH24_STENCIL8, width, height);
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

            let target_start = targets.len();
            for (buffer_index, (scanout_dmabuf, render_dmabuf)) in
                pool.dmabufs.into_iter().enumerate()
            {
                let scanout_format = AllocatorBuffer::format(scanout_dmabuf);
                // Gamut-corrected outputs render off-screen even when the
                // rest of the session renders straight into scanout.
                let offscreen = offscreen_blit || render_dmabuf.is_some();
                let image = match render_view(scanout_dmabuf).and_then(|view| {
                    Ok(render_context.display().create_image_from_dmabuf(&view)?)
                }) {
                    Ok(image) => image,
                    Err(error) => {
                        destroy_targets(gl, &display, &mut targets);
                        destroy_depth_stencils(gl, &mut depth_stencils);
                        render_context.unbind()?;
                        return Err(error);
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
                    gl_format: match render_dmabuf
                        .map(|dmabuf| AllocatorBuffer::format(dmabuf).code)
                    {
                        Some(Fourcc::Abgr16161616f) => gl::RGBA16F,
                        _ if scanout_format.code == Fourcc::Xrgb2101010 => gl::RGB10_A2,
                        _ => gl::RGBA8,
                    },
                    gamut: pool.color.map(|color| color.matrix),
                    pq_white: pool.color.map_or(0.0, |color| color.pq_white),
                };
                let import_error;
                // SAFETY: a compatible GLES context is current and all output
                // pointers reference live local integers.
                unsafe {
                    // Attribute a driver error to this import, not to a prior
                    // output or depth/stencil allocation.
                    let _ = (gl.get_error)();
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
                    import_error = (gl.get_error)();
                    (gl.gen_framebuffers)(1, &mut target.scanout_framebuffer);
                    (gl.bind_framebuffer)(gl::FRAMEBUFFER, target.scanout_framebuffer);
                    (gl.framebuffer_texture_2d)(
                        gl::FRAMEBUFFER,
                        gl::COLOR_ATTACHMENT0,
                        gl::TEXTURE_2D,
                        target.scanout_texture,
                        0,
                    );
                    if !offscreen && depth_stencil != 0 {
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
                let (framebuffer_status, attachment_error) = unsafe {
                    let attachment_error = (gl.get_error)();
                    let status = (gl.check_framebuffer_status)(gl::FRAMEBUFFER);
                    (gl.get_integer_v)(gl::SAMPLES, &mut actual_samples);
                    (gl.get_integer_v)(gl::STENCIL_BITS, &mut actual_stencil_bits);
                    (status, attachment_error)
                };
                if target.scanout_texture == 0
                    || target.scanout_framebuffer == 0
                    || import_error != gl::NO_ERROR
                    || attachment_error != gl::NO_ERROR
                    || framebuffer_status != gl::FRAMEBUFFER_COMPLETE
                    || (!offscreen && actual_samples > 1)
                    || (!offscreen && actual_stencil_bits < 8)
                {
                    warn!(
                        output = ?pool.output_id,
                        buffer_index,
                        width,
                        height,
                        format = ?scanout_dmabuf.format(),
                        import_error = format_args!("{import_error:#x}"),
                        attachment_error = format_args!("{attachment_error:#x}"),
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
                    return Err(format!(
                        "Flutter output {:?} buffer {buffer_index} ({width}x{height}, {:?}) scanout framebuffer failed: status={framebuffer_status:#x}, import_error={import_error:#x}, attachment_error={attachment_error:#x}",
                        pool.output_id, scanout_dmabuf.format(),
                    ).into());
                }

                if offscreen {
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
                    // The scene matches scanout, or is half float for an HDR
                    // output whose copy encodes PQ.
                    let render_format = AllocatorBuffer::format(render_dmabuf);
                    if (render_format.code != scanout_format.code
                        && render_format.code != Fourcc::Abgr16161616f)
                        || render_format.modifier != Modifier::Linear
                    {
                        let mut failed = vec![target];
                        destroy_targets(gl, &display, &mut failed);
                        destroy_targets(gl, &display, &mut targets);
                        destroy_depth_stencils(gl, &mut depth_stencils);
                        render_context.unbind()?;
                        return Err(format!(
                            "offscreen Flutter render target is not linear {:?}: {render_format:?}",
                            scanout_format.code
                        )
                        .into());
                    }
                    let render_image = match render_view(render_dmabuf).and_then(|view| {
                        Ok(render_context.display().create_image_from_dmabuf(&view)?)
                    }) {
                        Ok(image) => image,
                        Err(error) => {
                            let mut failed = vec![target];
                            destroy_targets(gl, &display, &mut failed);
                            destroy_targets(gl, &display, &mut targets);
                            destroy_depth_stencils(gl, &mut depth_stencils);
                            render_context.unbind()?;
                            return Err(error);
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
                        (gl.get_integer_v)(gl::STENCIL_BITS, &mut actual_stencil_bits);
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
                        || actual_stencil_bits < 8
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
                if let Some(Some(transfer)) = pool.transfers.get(buffer_index) {
                    transfers.insert(target.render_framebuffer, Arc::clone(transfer));
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

        // Capability probing happens before Flutter owns this context. Later
        // composition uses this same raster context and its reader fences.
        unsafe { render_context.make_current()? };
        let mut native_clients = NativeClientState::new(&render_context, gl, &display);
        if let Err(error) = render_context.unbind() {
            native_clients.destroy();
            return Err(error.into());
        }
        Ok(Arc::new(Self {
            render_context: Mutex::new(ContextBinding::new(render_context)),
            resource_context: Mutex::new(ContextBinding::new(resource_context)),
            display,
            gl,
            targets: Mutex::new(targets),
            transfers,
            completion_owner: Mutex::new(Weak::new()),
            shader_blit: Mutex::new(shader_blit),
            texture_apps: Mutex::new(HashMap::new()),
            window_grades: Mutex::new(WindowGrades::default()),
            depth_stencils: Mutex::new(depth_stencils),
            broker: Mutex::new(broker),
            pending_output_presentation: Mutex::new(None),
            gpu_deadline_hints: gpu_deadline::GpuDeadlineHints::default(),
            external_texture_sources: Mutex::new(HashMap::new()),
            native_clients: Mutex::new(native_clients),
            native_fallback_pending: AtomicBool::new(false),
            raster_sampled_buffers: Mutex::new(Vec::new()),
            raster_sampled_feedback: Mutex::new(Vec::new()),
            sampled_buffer_release_fence: Mutex::new(None),
            sampled_buffer_batch_pool: Arc::new(Mutex::new(Vec::with_capacity(
                MAX_RECYCLED_SAMPLED_BUFFER_BATCHES,
            ))),
            dmabuf_texture_cache: Mutex::new(PartitionedRecencyCache::new(
                MAX_CACHED_DMABUF_BINDINGS_PER_TEXTURE,
            )),
            shm_texture_cache: Mutex::new(RecencyCache::new(MAX_CACHED_SHM_BINDINGS)),
            retired_external_bindings: Arc::new(RetiredExternalBindingQueue::new()),
            retired_external_binding_scratch: Mutex::new(Vec::new()),
            external_texture_lease_pool: Arc::new(Mutex::new(Vec::with_capacity(
                MAX_CACHED_EXTERNAL_TEXTURE_LEASES,
            ))),
            leased_buffers: Mutex::new(HashMap::new()),
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
            shutdown_started: AtomicBool::new(false),
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
        lock_frame_token: u64,
        completion_id: Option<u64>,
    ) {
        views.clear();
        let mut broker = lock(&self.broker);
        let now = Instant::now();
        for request in requests {
            let mut request = *request;
            request.lock_frame_token = lock_frame_token;
            if let Some(view) = broker.authorize(request, now, completion_id) {
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

    pub(in crate::flutter_runtime) fn begin_output_authorization(&self, completion_id: u64) {
        lock(&self.broker).begin_authorization(completion_id);
    }

    pub(in crate::flutter_runtime) fn complete_output_authorization(&self, completion_id: u64) {
        if lock(&self.broker).complete_authorization(completion_id) > 0 {
            // A no-scene or skipped request has no present callback to wake the
            // event loop. Keep its dirty work pending for the next output tick.
            self.notify_frame_ready();
        }
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
        let now = Instant::now();
        let mut sources = lock(&self.external_texture_sources);
        for ExternalTextureFrame {
            texture_id,
            source,
            expects_sample,
            presentation,
        } in frames
        {
            let slot = sources.entry(texture_id).or_default();
            let latest_only = slot.latest_only;
            if slot.queue(source, expects_sample, presentation, now) {
                changed.push(texture_id);
            }
            if slot.latest_only != latest_only {
                debug!(
                    texture_id,
                    latest_only = slot.latest_only,
                    "external texture client pace changed"
                );
            }
        }
    }

    pub(in crate::flutter_runtime) fn advance_external_texture_sources(
        &self,
        texture_ids: &[i64],
        output_interval: Duration,
        deferred: &mut Vec<i64>,
    ) {
        let mut sources = lock(&self.external_texture_sources);
        for texture_id in texture_ids {
            if let Some(slot) = sources.get_mut(texture_id) {
                slot.advance(output_interval);
                if slot.has_queued() {
                    deferred.push(*texture_id);
                }
            }
        }
    }

    pub(in crate::flutter_runtime) fn advance_all_external_texture_sources(
        &self,
        output_interval: Duration,
        changed: &mut Vec<i64>,
    ) {
        let mut sources = lock(&self.external_texture_sources);
        for (texture_id, slot) in sources.iter_mut() {
            if slot.advance(output_interval) {
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

    fn record_sampled_feedback(&self, feedback: Option<crate::surface_feedback::SurfaceFeedback>) {
        if let Some(feedback) = feedback.filter(|token| token.pending()) {
            let mut sampled = lock(&self.raster_sampled_feedback);
            if !sampled.iter().any(|token| token.same(&feedback)) {
                sampled.push(feedback);
            }
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
            _buffer_guard: buffer_guard,
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
        let Some(mut batch) = batch else {
            return true;
        };
        if let Some(fence) = &fence {
            // Without a duplicate the batch keeps the releases until the
            // event loop sees the fence.
            match fence.try_clone() {
                Ok(shared) => batch.sampled_by(&Arc::new(shared)),
                Err(error) => warn!(%error, "could not share a sampled-buffer fence"),
            }
        }
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
        self.remove_native_window(texture_id);
        lock(&self.external_texture_sources).remove(&texture_id);
        let retired_dmabufs = lock(&self.dmabuf_texture_cache).remove(&texture_id);
        let retired_shm =
            lock(&self.shm_texture_cache).remove_where(|(owner, _)| *owner == texture_id);
        let retired_grade = lock(&self.window_grades).graded.remove(&texture_id);
        // Dropping a cache reference never issues GL calls. If no Flutter
        // lease still references the binding, its Drop queues destruction for
        // the next callback with the raster context current.
        drop((retired_dmabufs, retired_shm, retired_grade));
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
        let (retired, obsolete) = {
            let mut cache = lock(&self.shm_texture_cache);
            let retired = cache.insert((texture_id, revision), binding);
            let obsolete = cache
                .trim_matching_to(MAX_CACHED_SHM_REVISIONS_PER_TEXTURE, |(owner, _)| {
                    *owner == texture_id
                });
            (retired, obsolete)
        };
        // Eviction releases only the cache's Arc. Flutter's live image leases
        // still own their bindings; GL deletion remains deferred until their
        // final release and a callback with the render context current.
        drop((retired, obsolete));
    }

    pub(in crate::flutter_runtime) fn lease_external_texture(
        &self,
        texture_id: i64,
        generation: u64,
        mut resource: ExternalTextureLeaseResource,
    ) -> Box<ExternalTextureLease> {
        let mut lease = lock(&self.external_texture_lease_pool)
            .pop()
            .unwrap_or_else(|| {
                Box::new(ExternalTextureLease {
                    resource: None,
                    buffer: None,
                    pool: Arc::downgrade(&self.external_texture_lease_pool),
                })
            });
        debug_assert!(lease.resource.is_none() && lease.buffer.is_none());
        lease.buffer = resource.take_buffer_guard().map(|guard| {
            let buffer = Arc::new(Mutex::new(Some(SampledBufferHold {
                texture_id,
                generation,
                _buffer_guard: guard,
            })));
            let mut leased = lock(&self.leased_buffers);
            let buffers = leased.entry(texture_id).or_default();
            buffers.retain(|leased| leased.strong_count() > 0);
            buffers.push(Arc::downgrade(&buffer));
            buffer
        });
        lease.resource = Some(resource);
        lease
    }

    /// Detaches the buffers of an unregistered texture from the engine images
    /// which still hold them. Release them with `release_unregistered_buffers`
    /// on the render thread.
    pub(in crate::flutter_runtime) fn take_leased_buffers(
        &self,
        texture_id: i64,
    ) -> Vec<Weak<LeasedBuffer>> {
        let mut buffers = lock(&self.leased_buffers)
            .remove(&texture_id)
            .unwrap_or_default();
        buffers.retain(|leased| leased.strong_count() > 0);
        buffers
    }

    /// Runs on the render thread after the engine unregistered the texture
    /// that owned `buffers`, so no later frame can sample them. A fence placed
    /// here follows every frame which could, and the buffers then take the
    /// ordinary sampled-buffer release path.
    pub(in crate::flutter_runtime) fn release_unregistered_buffers(
        &self,
        buffers: Vec<Weak<LeasedBuffer>>,
    ) {
        let mut render_context = lock(&self.render_context);
        let bound = !render_context.context.is_current();
        if bound && !render_context.make_current() {
            // The engine images keep their buffers until Flutter retires them.
            return;
        }
        let holds = buffers
            .iter()
            .filter_map(Weak::upgrade)
            .filter_map(|leased| lock(&leased).take())
            .collect::<Vec<_>>();
        if !holds.is_empty() {
            let fence = match EGLFence::create(render_context.context.display()) {
                Ok(fence) => {
                    // SAFETY: the render context is current on this thread.
                    unsafe { (self.gl.flush)() };
                    fence
                        .export()
                        .inspect_err(
                            |error| warn!(%error, "unregistered texture fence export failed"),
                        )
                        .ok()
                }
                Err(error) => {
                    warn!(%error, "unregistered texture fence creation failed");
                    None
                }
            };
            if fence.is_none() {
                // SAFETY: the render context is current on this thread.
                unsafe { (self.gl.finish)() };
            }
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
        self.notify_frame_ready()
    }

    fn notify_frame_ready(&self) -> bool {
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

        let mut shader_blit_slot = lock(&self.shader_blit);
        let Some(shader_blit) = shader_blit_slot.as_mut() else {
            error!("offscreen Flutter target has no shader-copy pipeline");
            return false;
        };
        let look_generation = crate::output_color::desktop_lut_generation();
        if shader_blit.look_generation != look_generation {
            let lut = crate::output_color::desktop_lut();
            let texels = lut.as_deref().map(|lut| (lut.texels.as_slice(), lut.size));
            if let Err(error) = replace_desktop_look(self.gl, shader_blit, texels, look_generation)
            {
                error!(
                    error = format_args!("{error:#x}"),
                    "could not upload the desktop look; showing the scene without it"
                );
            }
        }
        let shader_blit = *shader_blit;
        drop(shader_blit_slot);

        if let Err(error) = copy_to_scanout(
            self.gl,
            target.render_texture,
            target.scanout_framebuffer,
            target.size,
            shader_blit,
            CopyColor {
                look: shader_blit.look_texture,
                alpha: 0,
                convert: None,
                // The switch compares a display with and without correction;
                // a PQ display always needs its BT.2020 matrix.
                gamut: target
                    .gamut
                    .filter(|_| target.pq_white > 0.0 || crate::output_color::correction_enabled()),
                pq_white: target.pq_white,
            },
        ) {
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

    pub(in crate::flutter_runtime) fn set_texture_apps(&self, apps: HashMap<i64, Arc<str>>) {
        *lock(&self.texture_apps) = apps;
    }

    pub(in crate::flutter_runtime) fn app_texture_ids(&self, app_id: &str) -> Vec<i64> {
        lock(&self.texture_apps)
            .iter()
            .filter(|(_, app)| &***app == app_id)
            .map(|(texture_id, _)| *texture_id)
            .collect()
    }

    fn app_look(&self, texture_id: i64) -> Option<Arc<crate::output_color::Lut>> {
        if !crate::output_color::app_luts_active() {
            return None;
        }
        let app = lock(&self.texture_apps).get(&texture_id).cloned()?;
        crate::output_color::app_lut(&app)
    }

    /// Give Flutter the graded copy of a window texture: converted from the
    /// surface's own colors and graded with its app's look. A copy is graded
    /// once per client buffer and grade; the engine image holds it.
    fn grade_external_texture(
        &self,
        mut prepared: PreparedExternalTexture,
    ) -> PreparedExternalTexture {
        let look = self.app_look(prepared.texture_id);
        let color = prepared.color.as_deref();
        let transform =
            color.and_then(|color| color.transform(crate::output_color::scene_encoding()));
        let alpha = color.map_or_else(Default::default, |color| color.alpha);
        let mut grades = lock(&self.window_grades);
        if look.is_none() && transform.is_none() && alpha == Default::default() {
            if grades.graded.remove(&prepared.texture_id).is_some() {
                grades.prune_looks(self.gl);
            }
            return prepared;
        }
        let grade = Grade {
            transform,
            alpha,
            look,
        };
        let source = (prepared.name, prepared.source_generation);
        let size = (prepared.width, prepared.height);
        let current = grades
            .graded
            .get(&prepared.texture_id)
            .filter(|graded| {
                graded.source == source && graded.size == size && graded.grade.same(&grade)
            })
            .map(|graded| Arc::clone(&graded.binding));
        let binding = match current {
            Some(binding) => binding,
            None => match self.render_grade(&mut grades, &prepared, grade) {
                Ok(binding) => binding,
                Err(error) => {
                    warn!(
                        texture_id = prepared.texture_id,
                        error = format_args!("{error:#x}"),
                        "could not grade a window; showing its pixels unconverted"
                    );
                    return prepared;
                }
            },
        };
        prepared.name = binding.texture();
        prepared.resource = ExternalTextureLeaseResource::Graded {
            _source: Box::new(prepared.resource),
            _graded: binding,
        };
        prepared
    }

    fn render_grade(
        &self,
        grades: &mut WindowGrades,
        prepared: &PreparedExternalTexture,
        grade: Grade,
    ) -> Result<Arc<CachedTextureBinding>, u32> {
        let shader_blit = (*lock(&self.shader_blit)).ok_or(gl::INVALID_OPERATION)?;
        let look_texture = match &grade.look {
            Some(look) => grades.look_texture(self.gl, look)?,
            None => 0,
        };
        let size = (prepared.width, prepared.height);
        let float = grade.float();
        let pixel_size = PixelSize {
            width: u32::try_from(size.0).map_err(|_| gl::INVALID_VALUE)?,
            height: u32::try_from(size.1).map_err(|_| gl::INVALID_VALUE)?,
        };
        // Overwrite a copy no engine image samples any more; otherwise
        // allocate one. Copies of another size or format are dropped.
        let mut spares = match grades.graded.remove(&prepared.texture_id) {
            Some(previous) if previous.size == size && previous.float == float => {
                let mut spares = previous.spares;
                spares.push(previous.binding);
                spares
            }
            _ => Vec::new(),
        };
        let target = match spares
            .iter()
            .position(|spare| Arc::strong_count(spare) == 1)
        {
            Some(free) => spares.swap_remove(free),
            None => self.create_graded_texture(pixel_size, float)?,
        };
        while spares.len() > MAX_GRADED_SPARES {
            spares.remove(0);
        }
        let mut previous_framebuffer = 0;
        let mut framebuffer = 0;
        // SAFETY: Flutter runs this callback with its render context current;
        // the graded texture belongs to that context.
        let status = unsafe {
            (self.gl.get_integer_v)(gl::DRAW_FRAMEBUFFER_BINDING, &mut previous_framebuffer);
            (self.gl.gen_framebuffers)(1, &mut framebuffer);
            (self.gl.bind_framebuffer)(gl::DRAW_FRAMEBUFFER, framebuffer);
            (self.gl.framebuffer_texture_2d)(
                gl::DRAW_FRAMEBUFFER,
                gl::COLOR_ATTACHMENT0,
                gl::TEXTURE_2D,
                target.texture(),
                0,
            );
            let status = (self.gl.check_framebuffer_status)(gl::DRAW_FRAMEBUFFER);
            (self.gl.bind_framebuffer)(gl::DRAW_FRAMEBUFFER, previous_framebuffer as u32);
            status
        };
        let copied = if status == gl::FRAMEBUFFER_COMPLETE {
            copy_to_scanout(
                self.gl,
                prepared.name,
                framebuffer,
                pixel_size,
                shader_blit,
                CopyColor {
                    look: look_texture,
                    alpha: grade.alpha as i32 + 1,
                    convert: grade.conversion(),
                    gamut: None,
                    pq_white: 0.0,
                },
            )
        } else {
            Err(status)
        };
        // SAFETY: the framebuffer was created above in the current context.
        unsafe { (self.gl.delete_framebuffers)(1, &framebuffer) };
        copied?;
        grades.graded.insert(
            prepared.texture_id,
            GradedTexture {
                source: (prepared.name, prepared.source_generation),
                grade,
                size,
                float,
                binding: Arc::clone(&target),
                spares,
            },
        );
        grades.prune_looks(self.gl);
        Ok(target)
    }

    fn create_graded_texture(
        &self,
        size: PixelSize,
        float: bool,
    ) -> Result<Arc<CachedTextureBinding>, u32> {
        let (internal_format, kind) = if float {
            (gl::RGBA16F, gl::HALF_FLOAT)
        } else {
            (gl::RGBA8, gl::UNSIGNED_BYTE)
        };
        let permit = self
            .external_texture_resource_budget
            .try_acquire()
            .ok_or(gl::OUT_OF_MEMORY)?;
        let mut texture = 0;
        let mut previous_texture = 0;
        // SAFETY: the render context is current; no pixels are read.
        let error = unsafe {
            (self.gl.get_integer_v)(gl::TEXTURE_BINDING_2D, &mut previous_texture);
            (self.gl.gen_textures)(1, &mut texture);
            (self.gl.bind_texture)(gl::TEXTURE_2D, texture);
            for (name, value) in [
                (gl::TEXTURE_MIN_FILTER, gl::LINEAR),
                (gl::TEXTURE_MAG_FILTER, gl::LINEAR),
                (gl::TEXTURE_WRAP_S, gl::CLAMP_TO_EDGE),
                (gl::TEXTURE_WRAP_T, gl::CLAMP_TO_EDGE),
            ] {
                (self.gl.tex_parameter_i)(gl::TEXTURE_2D, name, value as i32);
            }
            (self.gl.tex_image_2d)(
                gl::TEXTURE_2D,
                0,
                internal_format as i32,
                size.width as i32,
                size.height as i32,
                0,
                gl::RGBA,
                kind,
                ptr::null(),
            );
            let error = (self.gl.get_error)();
            (self.gl.bind_texture)(gl::TEXTURE_2D, previous_texture as u32);
            error
        };
        if texture == 0 || error != gl::NO_ERROR {
            // SAFETY: the texture, when made, has not escaped this call.
            unsafe { (self.gl.delete_textures)(1, &texture) };
            return Err(if error == gl::NO_ERROR {
                gl::OUT_OF_MEMORY
            } else {
                error
            });
        }
        Ok(Arc::new(CachedTextureBinding {
            binding: Some(ExternalTextureBinding {
                dmabuf_image: None,
                _owned_shm: None,
                _owned_native: None,
                texture,
                _resource_permit: permit,
            }),
            retirements: Arc::clone(&self.retired_external_bindings),
        }))
    }

    pub(in crate::flutter_runtime) fn destroy_targets(&self) -> bool {
        let mut targets = lock(&self.targets);
        let mut shader_blit = lock(&self.shader_blit);
        let mut depth_stencils = lock(&self.depth_stencils);
        if targets.is_empty() && shader_blit.is_none() && depth_stencils.is_empty() {
            return true;
        }
        let mut context = lock(&self.render_context);
        // SAFETY: either no engine has received this handler, or EngineHost
        // has shut down and joined its workers. A failed shutdown leaks its
        // callback-state Arc, preventing the final handler drop and cleanup.
        if let Err(error) = unsafe { context.context.make_current() } {
            error!(%error, "could not bind Flutter context for output-target cleanup");
            return false;
        }
        context.owner = Some(thread::current().id());
        lock(&self.native_clients).destroy();
        let cached_dmabufs = lock(&self.dmabuf_texture_cache).drain();
        let cached_shm = lock(&self.shm_texture_cache).drain();
        drop((cached_dmabufs, cached_shm));
        self.destroy_retired_external_bindings();
        if let Some(gpu_timing) = &self.gpu_timing {
            lock(gpu_timing).clear();
        }
        lock(&self.window_grades).clear(self.gl);
        self.destroy_retired_external_bindings();
        destroy_shader_blit(self.gl, &mut shader_blit);
        destroy_targets(self.gl, &self.display, &mut targets);
        destroy_depth_stencils(self.gl, &mut depth_stencils);
        context.clear_current()
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
        let shutting_down = self.shutdown_started.load(Ordering::Acquire);
        if shutting_down
            && retired
                .iter()
                .any(|binding| binding._owned_native.is_some())
        {
            // Teardown only: no future present can supply a reader fence.
            unsafe { (self.gl.finish)() };
        }
        for binding in retired.drain(..) {
            if !shutting_down && let Some(storage) = &binding._owned_native {
                // The engine can release an image after its last draw was
                // queued. Delay BO reuse until a fence after that last reader,
                // even if its initial composition fence completed long ago.
                self.record_sampled_buffer(
                    i64::MIN,
                    storage.allocation_id,
                    ExternalBufferGuard::OwnedNative {
                        storage: Arc::clone(storage),
                    },
                );
            }
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
        // Grading draws, so an app look always takes the GL path.
        if self.app_look(texture_id).is_some() {
            return false;
        }
        if self
            .retired_external_bindings
            .pending
            .load(Ordering::Relaxed)
        {
            return false;
        }
        if self.uses_native_window_texture(texture_id) {
            *prepared_slot = self.prepare_native_without_gl(texture_id);
            return prepared_slot.is_some();
        }
        let Some(source) = self.current_external_texture(texture_id) else {
            return false;
        };
        let color = source.color();
        // So does a surface whose pixels need converting.
        if color
            .as_deref()
            .is_some_and(|color| color.needs_pass(crate::output_color::scene_encoding()))
        {
            return false;
        }
        let source_generation = source.generation();
        let feedback = source.feedback();
        let Some(lease_permit) = self.external_texture_resource_budget.try_acquire() else {
            return false;
        };
        let (width, height, binding, resource, sampled_buffer) = match source {
            ExternalTextureSource::Dmabuf {
                dmabuf,
                buffer_guard,
                revision: _,
                feedback: _,
                color: _,
            } => {
                let dmabuf_width = dmabuf.width();
                let dmabuf_height = dmabuf.height();
                let width = usize::try_from(dmabuf_width).unwrap_or_default();
                let height = usize::try_from(dmabuf_height).unwrap_or_default();
                let cached = if buffer_guard
                    .as_ref()
                    .and_then(ExternalBufferGuard::owned_shm)
                    .is_some()
                {
                    self.cached_shm_binding(texture_id, source_generation)
                } else {
                    self.cached_dmabuf_binding(texture_id, &dmabuf)
                };
                let Some(binding) = cached else {
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
            feedback,
            color,
            width,
            height,
            name,
            resource,
            sampled_buffer,
            native_samples: Vec::new(),
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

impl Drop for FlutterGlHandler {
    fn drop(&mut self) {
        // Also covers abandoned preparations and startup failures. Successful
        // runtime shutdown already drains the targets; cleanup is idempotent.
        let _ = self.destroy_targets();
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
