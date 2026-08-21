//! Flutter OpenGL embedder callbacks and raster-thread presentation ingress.

use super::*;

impl OpenGlHandler for FlutterGlHandler {
    fn make_current(&self) -> bool {
        let current = lock(&self.render_context).make_current();
        if current && self.begin_raster_frame() {
            debug_assert!(lock(&self.sampled_buffer_release_fence).is_none());
            lock(&self.broker).begin_transaction();
        }
        current
    }

    fn clear_current(&self) -> bool {
        lock(&self.render_context).clear_current()
    }

    fn make_resource_current(&self) -> bool {
        lock(&self.resource_context).make_current()
    }

    fn raster_idle(&self) {
        // The host posts this sentinel behind Flutter's current render work.
        // If present() already sealed the transaction this is idempotent; if
        // the transaction had no present callback it supplies the missing
        // REQUESTED/RASTERIZING -> IDLE transition.
        let ready = lock(&self.broker).finish_transaction();
        let previous = self.finish_producer_frame();
        if !ready.is_empty() {
            let sampled = self.seal_sampled_buffers();
            if let Some(audit) = &self.render_audit {
                lock(audit).record_sampled_textures(sampled.as_ref());
            }
            let release_fence = lock(&self.sampled_buffer_release_fence).take();
            self.publish_sampled_buffer_release(release_fence, sampled);
            self.publish_ready_frames(ready);
        } else {
            lock(&self.sampled_buffer_release_fence).take();
            if let Some(audit) = &self.render_audit {
                lock(audit).record_empty_transaction();
            }
        }
        if matches!(
            previous,
            FlutterProducerState::Requested | FlutterProducerState::Rasterizing
        ) {
            self.rearm_abandoned_samples();
            let batch = self.seal_sampled_buffers();
            if batch.is_some() {
                // The raster transaction returned without present(), so no
                // exportable fence exists. Match the C++ conservative path.
                // SAFETY: the sentinel runs on Flutter's render thread after
                // the abandoned raster task.
                unsafe { (self.gl.finish)() };
                self.publish_sampled_buffer_release(None, batch);
            }
        }
    }

    fn surface_transformation(&self) -> sys::FlutterTransformation {
        // The legacy root surface is never presented. Denial's engine applies
        // the OpenGL Y inversion independently while preparing each physical
        // render view, using that target's native height.
        sys::FlutterTransformation {
            scaleX: 1.0,
            skewX: 0.0,
            transX: 0.0,
            skewY: 0.0,
            scaleY: 1.0,
            transY: 0.0,
            pers0: 0.0,
            pers1: 0.0,
            pers2: 1.0,
        }
    }

    fn framebuffer(&self, width: u32, height: u32) -> u32 {
        debug!(
            width,
            height, "ignored legacy Flutter root-surface FBO request"
        );
        0
    }

    fn create_backing_store(&self, request: BackingStoreRequest) -> Option<CompositorBackingStore> {
        let size = PixelSize::new(
            u32::try_from(request.width).ok()?,
            u32::try_from(request.height).ok()?,
        );
        let framebuffer = match lock(&self.broker).acquire(request.view_id, size) {
            Ok(framebuffer) => framebuffer,
            Err(blocked) => {
                if let Some(audit) = &self.render_audit {
                    lock(audit).record_target_blocked(blocked);
                }
                // Every independently clocked output can temporarily retain a
                // scanning generation, an atomic submission awaiting page flip,
                // and a newer ready generation. Exhaustion remains ordinary
                // producer backpressure if a supported topology reaches its
                // bounded worst case. Flutter accepts FBO 0 as a skipped frame;
                // present() completes that no-op successfully so it returns to
                // AwaitVSync instead of entering a retry storm that could starve
                // the page flip which frees the next target.
                return None;
            }
        };
        // Leave the selected FBO current as required by the embedder OpenGL
        // contract. Denial's versioned engine stack queries the attached
        // level-zero texture and wraps it as borrowed storage; Skia owns the
        // stencil and dynamic-MSAA resources used to render into it.
        // SAFETY: Flutter calls this with the render context current.
        unsafe {
            (self.gl.bind_framebuffer)(gl::FRAMEBUFFER, framebuffer);
            (self.gl.viewport)(0, 0, size.width as i32, size.height as i32);
        }
        Some(CompositorBackingStore {
            framebuffer,
            format: gl::RGBA8,
            // The pool owns the target. This identity makes a malformed or
            // cross-view present observable without allocating a callback
            // baton for every raster pass.
            user_data: framebuffer as usize,
        })
    }

    fn collect_backing_store(&self, backing_store: CompositorBackingStore) -> bool {
        // Flutter returns only its temporary render-target borrow. The native
        // target stays in OutputBufferBroker and is recycled after KMS ownership is
        // released, not when the engine destroys its wrapper.
        lock(&self.targets).iter().any(|target| {
            target.render_framebuffer == backing_store.framebuffer
                && backing_store.user_data == backing_store.framebuffer as usize
        })
    }

    fn present_view(&self, view: PresentView<'_>) -> bool {
        let target = lock(&self.targets)
            .iter()
            .find(|target| {
                target.render_view_id.get() == view.view_id
                    && target.render_framebuffer == view.backing_store.framebuffer
            })
            .copied();
        let Some(target) = target else {
            error!(
                view_id = view.view_id,
                framebuffer = view.backing_store.framebuffer,
                "Flutter compositor presented an unknown output backing store"
            );
            return false;
        };
        if view.backing_store.user_data != view.backing_store.framebuffer as usize
            || view.offset_x != 0.0
            || view.offset_y != 0.0
            || view.width != f64::from(target.size.width)
            || view.height != f64::from(target.size.height)
            || !lock(&self.broker).validate_backing_store(
                view.view_id,
                view.backing_store.framebuffer,
                target.size,
            )
        {
            error!(
                view_id = view.view_id,
                framebuffer = view.backing_store.framebuffer,
                offset_x = view.offset_x,
                offset_y = view.offset_y,
                width = view.width,
                height = view.height,
                expected_width = target.size.width,
                expected_height = target.size.height,
                output_id = target.output_id.0,
                configuration_generation = target.configuration_generation,
                buffer_index = target.buffer_index,
                "Flutter compositor presented an invalid physical-output layer"
            );
            return false;
        }
        let mut pending = lock(&self.pending_output_presentation);
        if pending.is_some() {
            error!(view_id = view.view_id, "nested Flutter output presentation");
            return false;
        }
        *pending = Some(PendingOutputPresentation {
            view_id: view.view_id,
            framebuffer: view.backing_store.framebuffer,
        });
        // The external-view callback identifies the physical backing store.
        // Exact frame and buffer damage arrive immediately afterwards through
        // the root SurfaceFrame's standard present-with-info callback.
        true
    }

    fn present(&self, frame: PresentFrame<'_>) -> bool {
        let Some(pending) = lock(&self.pending_output_presentation).take() else {
            if frame.framebuffer == 0 {
                // A raster task with no compositor layer still submits its
                // otherwise unused root SurfaceFrame.
                return true;
            }
            error!(
                framebuffer = frame.framebuffer,
                "legacy Flutter surface attempted to bypass output compositor"
            );
            return false;
        };
        if frame.framebuffer != 0 {
            error!(
                view_id = pending.view_id,
                framebuffer = frame.framebuffer,
                "Flutter output damage bypassed the root presentation handoff"
            );
            return false;
        }
        let view_id = pending.view_id;
        let framebuffer = pending.framebuffer;
        self.begin_present();
        (|| {
            // Surface removal and cache eviction can happen on the platform
            // thread, where issuing GL/EGL destruction calls is forbidden. A
            // raster present owns the render context, so reclaim those queued
            // resources even when no further external texture is populated.
            self.destroy_retired_external_bindings();
            if !self.blit_to_scanout(framebuffer) {
                let sampled = self.seal_sampled_buffers();
                // A failed copy cannot produce a KMS fence. Finish Flutter's
                // sampling before releasing client buffers, then let the next
                // acquisition invalidate and recycle this rendering slot.
                // SAFETY: present runs with the raster context current.
                unsafe { (self.gl.finish)() };
                let _ = self.publish_sampled_buffer_release(None, sampled);
                return false;
            }
            let context = lock(&self.render_context);
            let fence = match EGLFence::create(context.context.display()) {
                Ok(fence) => {
                    // The fence follows Flutter's render commands. Flushing
                    // publishes the native sync_file without waiting for GPU
                    // completion on the raster thread.
                    // SAFETY: present runs with the raster context current.
                    unsafe { (self.gl.flush)() };
                    match fence.export() {
                        Ok(fence) => Some(fence),
                        Err(error) => {
                            let reason = format!(
                                "could not export the required Flutter native fence: {error}"
                            );
                            error!(%error, "required Flutter native fence export failed");
                            // Complete outstanding sampling only so teardown
                            // can release imported client buffers safely. This
                            // frame is not published as an unfenced fallback.
                            // SAFETY: present runs with the raster context current.
                            unsafe { (self.gl.finish)() };
                            let sampled = self.seal_sampled_buffers();
                            let _ = self.publish_sampled_buffer_release(None, sampled);
                            let _ = self.events.send(RuntimeEvent::FatalRender {
                                generation: self.generation,
                                reason,
                            });
                            return false;
                        }
                    }
                }
                Err(error) => {
                    let reason =
                        format!("could not create the required Flutter native fence: {error}");
                    error!(%error, "required Flutter native fence creation failed");
                    // Complete outstanding sampling only so teardown can
                    // release imported client buffers safely. This frame is
                    // not published as an unfenced fallback.
                    // SAFETY: present runs with the raster context current.
                    unsafe { (self.gl.finish)() };
                    let sampled = self.seal_sampled_buffers();
                    let _ = self.publish_sampled_buffer_release(None, sampled);
                    let _ = self.events.send(RuntimeEvent::FatalRender {
                        generation: self.generation,
                        reason,
                    });
                    return false;
                }
            };
            if let Some(audit) = &self.render_audit {
                lock(audit).record_present(
                    view_id,
                    lock(&self.targets)
                        .iter()
                        .find(|target| target.render_framebuffer == framebuffer)
                        .map_or(self.desktop_size, |target| target.size),
                    frame.frame_damage,
                    frame.buffer_damage,
                );
            }
            let release_fence = match fence.as_ref() {
                Some(fence) => match fence.as_fd().try_clone_to_owned() {
                    Ok(fence) => Some(fence),
                    Err(error) => {
                        warn!(%error, "could not duplicate Flutter render fence; using glFinish for sampled buffers");
                        // SAFETY: present runs with the raster context current.
                        unsafe { (self.gl.finish)() };
                        None
                    }
                },
                None => {
                    // Fence-less output presentation is only reachable after
                    // a synchronous GL completion fallback.
                    // SAFETY: present runs with the raster context current.
                    unsafe { (self.gl.finish)() };
                    None
                }
            };
            *lock(&self.sampled_buffer_release_fence) = release_fence;
            let rendered_at = self.render_audit.as_ref().map(|_| Instant::now());
            if !lock(&self.broker).mark_ready(
                view_id,
                framebuffer,
                frame.frame_damage,
                frame.buffer_damage,
                fence,
                rendered_at,
            ) {
                error!(
                    view_id,
                    framebuffer, "Flutter presented an output FBO that was not rendering"
                );
                return false;
            }
            true
        })()
    }

    fn populate_existing_damage(&self, framebuffer: isize, damage: &mut Vec<sys::FlutterRect>) {
        if framebuffer == 0 {
            return;
        }
        if !lock(&self.broker).populate_existing_damage(framebuffer, damage) {
            // Flutter should only ask about an FBO returned by framebuffer().
            // Unknown IDs still degrade safely instead of declaring no damage.
            warn!(
                framebuffer,
                "Flutter requested damage for an unknown output FBO"
            );
            let size = lock(&self.targets)
                .iter()
                .find(|target| target.render_framebuffer as isize == framebuffer)
                .map_or(self.desktop_size, |target| target.size);
            damage.push(sys::FlutterRect {
                left: 0.0,
                top: 0.0,
                right: f64::from(size.width),
                bottom: f64::from(size.height),
            });
        }
    }

    fn resolve_proc(&self, name: &CStr) -> *mut c_void {
        let Ok(name) = name.to_str() else {
            return ptr::null_mut();
        };
        // SAFETY: Flutter asks for procedures while one of our EGL contexts is
        // current on the calling engine thread.
        unsafe { get_proc_address(name).cast_mut() }
    }

    fn external_texture_callback_may_modify_gl(&self, texture_id: i64) -> bool {
        !self.prepare_external_texture_without_gl(texture_id)
    }

    fn populate_external_texture(
        &self,
        texture_id: i64,
        _width: usize,
        _height: usize,
        texture: &mut sys::FlutterOpenGLTexture,
    ) -> bool {
        let prepared = lock(&self.prepared_external_texture).take();
        if let Some(prepared) = prepared {
            if prepared.texture_id != texture_id {
                // The engine extension promises that this callback immediately
                // follows the preflight for the same texture. Refuse the frame
                // without touching GL if a mismatched engine violates it.
                error!(
                    texture_id,
                    prepared_texture_id = prepared.texture_id,
                    "external texture preflight did not match Flutter callback"
                );
                return false;
            }
            let lease = self.lease_external_texture(prepared.resource);
            *texture = sys::FlutterOpenGLTexture {
                target: gl::TEXTURE_2D,
                name: prepared.name,
                format: gl::RGBA8,
                user_data: Box::into_raw(lease).cast(),
                destruction_callback: Some(retire_external_texture),
                width: prepared.width,
                height: prepared.height,
            };
            if let Some(buffer_guard) = prepared.sampled_buffer {
                self.record_sampled_buffer(texture_id, prepared.source_generation, buffer_guard);
            }
            self.mark_external_texture_sampled(texture_id, prepared.source_generation);
            return true;
        }
        // Flutter invokes this callback with the render context current. Drain
        // leases released by earlier engine frames before allocating the next
        // direct EGLImage binding.
        self.destroy_retired_external_bindings();
        let Some(source) = self.current_external_texture(texture_id) else {
            return false;
        };
        let source_generation = source.generation();
        let Some(lease_permit) = self.external_texture_resource_budget.try_acquire() else {
            warn!(
                texture_id,
                limit = MAX_LIVE_EXTERNAL_TEXTURE_RESOURCES,
                "rejected Flutter external texture lease after resource limit"
            );
            return false;
        };
        let (width, height, name, lease, sampled_buffer) = match source {
            ExternalTextureSource::Dmabuf {
                dmabuf,
                buffer_guard,
                revision,
            } => {
                let dmabuf_width = dmabuf.width();
                let dmabuf_height = dmabuf.height();
                let width = usize::try_from(dmabuf_width).unwrap_or_default();
                let height = usize::try_from(dmabuf_height).unwrap_or_default();
                if width == 0 || height == 0 {
                    return false;
                }
                let cached = self.cached_dmabuf_binding(texture_id, &dmabuf);
                let binding = if let Some(binding) = cached {
                    binding
                } else {
                    let Some(binding_permit) = self.external_texture_resource_budget.try_acquire()
                    else {
                        warn!(
                            texture_id,
                            limit = MAX_LIVE_EXTERNAL_TEXTURE_RESOURCES,
                            "rejected dma-buf EGLImage after external texture resource limit"
                        );
                        return false;
                    };
                    let context = lock(&self.render_context);
                    let image = match context.context.display().create_image_from_dmabuf(&dmabuf) {
                        Ok(image) => image,
                        Err(error) => {
                            warn!(%error, texture_id, "could not import Wayland dma-buf for Flutter");
                            return false;
                        }
                    };
                    drop(context);
                    let mut name = 0;
                    if let Some(error) = self.take_gl_error() {
                        warn!(
                            error = format_args!("{error:#x}"),
                            texture_id, "discarded stale GLES error before dma-buf import"
                        );
                    }
                    // SAFETY: the Flutter render context is current on this callback thread.
                    unsafe {
                        (self.gl.gen_textures)(1, &mut name);
                        (self.gl.bind_texture)(gl::TEXTURE_2D, name);
                        (self.gl.tex_parameter_i)(
                            gl::TEXTURE_2D,
                            gl::TEXTURE_MIN_FILTER,
                            gl::LINEAR as i32,
                        );
                        (self.gl.tex_parameter_i)(
                            gl::TEXTURE_2D,
                            gl::TEXTURE_MAG_FILTER,
                            gl::LINEAR as i32,
                        );
                        (self.gl.tex_parameter_i)(
                            gl::TEXTURE_2D,
                            gl::TEXTURE_WRAP_S,
                            gl::CLAMP_TO_EDGE as i32,
                        );
                        (self.gl.tex_parameter_i)(
                            gl::TEXTURE_2D,
                            gl::TEXTURE_WRAP_T,
                            gl::CLAMP_TO_EDGE as i32,
                        );
                        (self.gl.image_target_texture)(gl::TEXTURE_2D, image.cast());
                    }
                    let gl_error = self.take_gl_error();
                    if name == 0 || gl_error.is_some() {
                        // SAFETY: the texture, when allocated, belongs to the
                        // current render context and has not escaped this call.
                        unsafe {
                            if name != 0 {
                                (self.gl.delete_textures)(1, &name);
                            }
                        }
                        // SAFETY: the image was created on this EGL display and
                        // has not been installed in a cache entry.
                        unsafe {
                            egl_ffi::egl::DestroyImageKHR(self.display.handle, image);
                        }
                        if let Some(error) = gl_error {
                            warn!(
                                error = format_args!("{error:#x}"),
                                texture_id, "rejected Wayland dma-buf after GLES import failure"
                            );
                        }
                        return false;
                    }
                    let binding = Arc::new(CachedTextureBinding {
                        binding: Some(ExternalTextureBinding {
                            dmabuf_image: Some((dmabuf.clone(), image as usize)),
                            texture: name,
                            _resource_permit: binding_permit,
                        }),
                        retirements: Arc::clone(&self.retired_external_bindings),
                    });
                    self.cache_dmabuf_binding(texture_id, dmabuf, Arc::clone(&binding));
                    // An insertion can evict an inactive LRU entry. Its Drop
                    // only queued GL objects, and this callback owns a current
                    // render context, so reclaim them immediately.
                    self.destroy_retired_external_bindings();
                    binding
                };
                let name = binding.texture();
                if name == 0 {
                    return false;
                }
                if buffer_guard
                    .as_ref()
                    .is_some_and(ExternalBufferGuard::is_native)
                {
                    let (retained, copied) = if let Some(retained) =
                        self.cached_retained_native_binding(texture_id, revision)
                    {
                        (retained, false)
                    } else {
                        let retained =
                            match self.retain_native_texture(name, dmabuf_width, dmabuf_height) {
                                Ok(retained) => retained,
                                Err(error) => {
                                    warn!(
                                        %error,
                                        texture_id,
                                        revision,
                                        "could not retain native dma-buf for Flutter"
                                    );
                                    return false;
                                }
                            };
                        self.cache_retained_native_binding(
                            texture_id,
                            revision,
                            Arc::clone(&retained),
                        );
                        self.destroy_retired_external_bindings();
                        (retained, true)
                    };
                    let name = retained.texture();
                    if name == 0 {
                        return false;
                    }
                    let sampled_buffer = copied.then(|| buffer_guard.clone()).flatten();
                    (
                        width,
                        height,
                        name,
                        ExternalTextureLeaseResource::Retained {
                            _binding: retained,
                            _resource_permit: lease_permit,
                        },
                        sampled_buffer,
                    )
                } else {
                    let sampled_buffer = buffer_guard.clone();
                    (
                        width,
                        height,
                        name,
                        ExternalTextureLeaseResource::Dmabuf {
                            _binding: binding,
                            _buffer_guard: buffer_guard,
                            _resource_permit: lease_permit,
                        },
                        sampled_buffer,
                    )
                }
            }
            ExternalTextureSource::Shm(frame) => {
                let width = usize::try_from(frame.width).unwrap_or_default();
                let height = usize::try_from(frame.height).unwrap_or_default();
                if width == 0 || height == 0 {
                    return false;
                }
                let Ok(width_i32) = i32::try_from(frame.width) else {
                    return false;
                };
                let Ok(height_i32) = i32::try_from(frame.height) else {
                    return false;
                };
                let binding = if let Some(binding) =
                    self.cached_shm_binding(texture_id, frame.revision)
                {
                    binding
                } else {
                    let Some(binding_permit) = self.external_texture_resource_budget.try_acquire()
                    else {
                        warn!(
                            texture_id,
                            limit = MAX_LIVE_EXTERNAL_TEXTURE_RESOURCES,
                            "rejected SHM upload after external texture resource limit"
                        );
                        return false;
                    };
                    let mut name = 0;
                    if let Some(error) = self.take_gl_error() {
                        warn!(
                            error = format_args!("{error:#x}"),
                            texture_id, "discarded stale GLES error before SHM upload"
                        );
                    }
                    // SHM snapshots are tightly packed RGBA8, so the default
                    // four-byte unpack alignment is valid for every row.
                    // SAFETY: Flutter invokes this callback with the render
                    // context current; `frame.pixels()` contains the complete
                    // validated width-by-height RGBA payload.
                    unsafe {
                        (self.gl.gen_textures)(1, &mut name);
                        (self.gl.bind_texture)(gl::TEXTURE_2D, name);
                        (self.gl.tex_parameter_i)(
                            gl::TEXTURE_2D,
                            gl::TEXTURE_MIN_FILTER,
                            gl::LINEAR as i32,
                        );
                        (self.gl.tex_parameter_i)(
                            gl::TEXTURE_2D,
                            gl::TEXTURE_MAG_FILTER,
                            gl::LINEAR as i32,
                        );
                        (self.gl.tex_parameter_i)(
                            gl::TEXTURE_2D,
                            gl::TEXTURE_WRAP_S,
                            gl::CLAMP_TO_EDGE as i32,
                        );
                        (self.gl.tex_parameter_i)(
                            gl::TEXTURE_2D,
                            gl::TEXTURE_WRAP_T,
                            gl::CLAMP_TO_EDGE as i32,
                        );
                        (self.gl.tex_image_2d)(
                            gl::TEXTURE_2D,
                            0,
                            gl::RGBA as i32,
                            width_i32,
                            height_i32,
                            0,
                            gl::RGBA,
                            gl::UNSIGNED_BYTE,
                            frame.pixels().as_ptr().cast(),
                        );
                    }
                    let gl_error = self.take_gl_error();
                    if name == 0 || gl_error.is_some() {
                        // SAFETY: the texture, when allocated, belongs to the
                        // current render context and has not escaped this call.
                        unsafe {
                            if name != 0 {
                                (self.gl.delete_textures)(1, &name);
                            }
                        }
                        if let Some(error) = gl_error {
                            warn!(
                                error = format_args!("{error:#x}"),
                                texture_id,
                                "rejected Wayland SHM texture after GLES upload failure"
                            );
                        }
                        return false;
                    }
                    let revision = frame.revision;
                    let binding = Arc::new(CachedTextureBinding {
                        binding: Some(ExternalTextureBinding {
                            dmabuf_image: None,
                            texture: name,
                            _resource_permit: binding_permit,
                        }),
                        retirements: Arc::clone(&self.retired_external_bindings),
                    });
                    self.cache_shm_binding(texture_id, revision, Arc::clone(&binding));
                    self.destroy_retired_external_bindings();
                    binding
                };
                let name = binding.texture();
                if name == 0 {
                    return false;
                }
                (
                    width,
                    height,
                    name,
                    ExternalTextureLeaseResource::Shm {
                        _binding: binding,
                        _resource_permit: lease_permit,
                    },
                    None,
                )
            }
        };
        if width == 0 || height == 0 {
            drop(lease);
            return false;
        }
        let lease = self.lease_external_texture(lease);
        *texture = sys::FlutterOpenGLTexture {
            target: gl::TEXTURE_2D,
            name,
            format: gl::RGBA8,
            user_data: Box::into_raw(lease).cast(),
            destruction_callback: Some(retire_external_texture),
            width,
            height,
        };
        if let Some(buffer_guard) = sampled_buffer {
            self.record_sampled_buffer(texture_id, source_generation, buffer_guard);
        }
        self.mark_external_texture_sampled(texture_id, source_generation);
        true
    }

    fn event(&self, event: EngineEvent) {
        if let EngineEvent::PlatformTask(task) = &event {
            let Some(permit) = self.platform_task_budget.try_acquire() else {
                error!(
                    runner = task.runner,
                    task = task.task,
                    limit = MAX_PENDING_PLATFORM_TASKS,
                    "dropped Flutter platform task after pending task limit"
                );
                self.report_queue_overflow("platform task");
                return;
            };
            if !self.platform_tasks.push(PendingPlatformTask {
                task: *task,
                permit,
            }) {
                return;
            }
            if self
                .events
                .send(RuntimeEvent::PlatformTasksReady {
                    generation: self.generation,
                })
                .is_err()
            {
                self.platform_tasks.discard_after_failed_wakeup();
            }
            return;
        }
        // AwaitVSync batons are one-shot obligations owned by the embedder.
        // Keep an independent record before handing the event to calloop so a
        // topology restart can fulfil batons that have not reached the main
        // thread yet. Flutter shutdown may otherwise race a blocked animator.
        if let EngineEvent::Vsync(baton) = &event {
            match lock(&self.pending_vsync_batons).register(*baton) {
                VsyncRegistration::Accepted => {}
                VsyncRegistration::Duplicate => {
                    warn!(baton, "ignored duplicate pending Flutter vsync baton");
                    return;
                }
                VsyncRegistration::AtCapacity => {
                    error!(
                        baton,
                        limit = MAX_PENDING_VSYNC_BATONS,
                        "dropped Flutter vsync request after pending baton limit"
                    );
                    self.report_queue_overflow("vsync baton");
                    return;
                }
            }
        }
        let _ = self.events.send(RuntimeEvent::Engine {
            generation: self.generation,
            event,
        });
    }

    fn log(&self, tag: &str, message: &str) {
        if tag.is_empty() {
            eprintln!("flutter: {message}");
        } else {
            eprintln!("flutter[{tag}]: {message}");
        }
        let Some(uri) = vm_service_uri_from_log(message) else {
            return;
        };
        let _ = self.events.send(RuntimeEvent::VmServiceUri {
            generation: self.generation,
            uri: uri.to_owned(),
        });
    }
}
