//! Cached native client images on Flutter's existing raster GL context.
use super::super::super::native_window::{
    ClientRect, NativeWindowPlan, NativeWindowRegistry, VersionedWindowPlan,
    reproduces_presentation,
};
use super::super::super::native_window_gl::{NativeWindowGl, NativeWindowInput};
use super::super::native_window_pool::{NativeWindowPool, NativeWindowStorage};
use super::*;

#[derive(Clone)]
enum PixelIdentity {
    Dmabuf(Dmabuf, u64),
    Shm(Arc<ShmPixelStorage>, u64),
}
impl PixelIdentity {
    fn new(source: &ExternalTextureSource) -> Self {
        match source {
            ExternalTextureSource::Dmabuf {
                dmabuf, revision, ..
            } => Self::Dmabuf(dmabuf.clone(), *revision),
            ExternalTextureSource::Shm(frame) => Self::Shm(Arc::clone(&frame.rgba), frame.revision),
        }
    }
    fn same(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Dmabuf(a, ar), Self::Dmabuf(b, br)) => ar == br && a == b,
            (Self::Shm(a, ar), Self::Shm(b, br)) => ar == br && Arc::ptr_eq(a, b),
            _ => false,
        }
    }
}
struct ClientImage {
    plan_revision: u64,
    inputs: Vec<PixelIdentity>,
    presentations: Vec<Option<denial_flutter_engine::ExternalTexturePresentation>>,
    binding: Arc<CachedTextureBinding>,
    storage: Arc<NativeWindowStorage>,
    width: usize,
    height: usize,
}
impl ClientImage {
    fn matches(
        &self,
        plan_revision: u64,
        inputs: &[PixelIdentity],
        presentations: &[Option<denial_flutter_engine::ExternalTexturePresentation>],
    ) -> bool {
        self.plan_revision == plan_revision
            && self.inputs.len() == inputs.len()
            && self.inputs.iter().zip(inputs).all(|(a, b)| a.same(b))
            && self.presentations == presentations
    }
}
/// The latest plan with the buffers its layers currently show.
struct NativeSnapshot {
    plan: Arc<VersionedWindowPlan>,
    /// Current buffers in layer order, for the layers that have one.
    inputs: Vec<(i64, ExternalTextureSource)>,
    /// Per plan layer: the presentation that advanced with its buffer, or
    /// `None` while the layer has no current buffer.
    presentations: Vec<Option<denial_flutter_engine::ExternalTexturePresentation>>,
}
#[derive(Default)]
pub(super) struct NativeClientState {
    registry: NativeWindowRegistry,
    images: HashMap<i64, ClientImage>,
    pool: Option<Arc<NativeWindowPool>>,
    pass: Option<NativeWindowGl>,
    disabled: HashSet<i64>,
    hits: u64,
    misses: u64,
    draws: u64,
    probe_modifier: Option<Modifier>,
}
pub(in crate::flutter_runtime) struct NativeInputSample {
    texture_id: i64,
    generation: u64,
    feedback: Option<crate::surface_feedback::SurfaceFeedback>,
}

impl NativeClientState {
    pub(super) fn new(
        context: &egl_context::SharedEglContext,
        gl: GlApi,
        display: &Arc<EGLDisplayHandle>,
    ) -> Self {
        let mut pass = None;
        let mut probe_modifier = None;
        let setup = (|| -> Result<Arc<NativeWindowPool>, Box<dyn Error>> {
            let device = smithay::backend::egl::EGLDevice::device_for_display(context.display())?;
            let node = device
                .try_get_render_node()?
                .ok_or("native client EGL device has no render node")?;
            let path = node
                .dev_path()
                .ok_or("native client render node has no path")?;
            let file = std::fs::OpenOptions::new()
                .read(true)
                .write(true)
                .open(&path)?;
            let device = smithay::backend::drm::DrmDeviceFd::new(smithay::utils::DeviceFd::from(
                OwnedFd::from(file),
            ));
            let mut modifiers = context
                .display()
                .dmabuf_render_formats()
                .iter()
                .filter(|format| format.code == Fourcc::Abgr8888)
                .map(|format| format.modifier)
                .collect::<Vec<_>>();
            modifiers.sort_unstable_by_key(|modifier| u64::from(*modifier));
            let pool = NativeWindowPool::new(device, modifiers)?;
            pass = Some(NativeWindowGl::new(|name| unsafe {
                get_proc_address(name.to_str().expect("static GLES symbol"))
            })?);
            let storage = pool
                .acquire([64, 64])?
                .ok_or("native target probe budget")?;
            let image = context
                .display()
                .create_image_from_dmabuf(storage.dmabuf())?;
            let mut name = 0;
            unsafe {
                (gl.gen_textures)(1, &mut name);
                (gl.bind_texture)(gl::TEXTURE_2D, name);
                (gl.image_target_texture)(gl::TEXTURE_2D, image.cast());
            }
            let result = pass.as_mut().unwrap().validate_target(name);
            unsafe {
                (gl.bind_texture)(gl::TEXTURE_2D, 0);
                (gl.delete_textures)(1, &name);
                egl_ffi::egl::DestroyImageKHR(display.handle, image);
            }
            result?;
            probe_modifier = Some(storage.dmabuf().format().modifier);
            info!(node=%path.display(),modifier=?probe_modifier,max_live_bytes=512*1024*1024,"native client composition available: explicit GBM layout, EGL import and FBO probe");
            Ok(pool)
        })();
        match setup {
            Ok(pool) => Self {
                pool: Some(pool),
                pass,
                probe_modifier,
                ..Self::default()
            },
            Err(error) => {
                if let Some(pass) = &mut pass {
                    pass.destroy();
                }
                warn!(%error,"native client composition unavailable; keeping surface trees");
                Self::default()
            }
        }
    }
    pub(super) fn destroy(&mut self) {
        self.images.clear();
        if let Some(pass) = &mut self.pass {
            pass.destroy();
        }
        self.pass = None;
        if let Some(pool) = &self.pool {
            pool.clear_free();
        }
        info!(
            hits = self.hits,
            misses = self.misses,
            draws = self.draws,
            live_bytes = self.pool.as_ref().map_or(0, |p| p.live_bytes()),
            "native client composition totals"
        );
    }
}

impl FlutterGlHandler {
    pub(in crate::flutter_runtime) fn native_client_composition_stats(&self) -> serde_json::Value {
        let state = lock(&self.native_clients);
        let mut disabled = state.disabled.iter().copied().collect::<Vec<_>>();
        disabled.sort_unstable();
        let mut images = state
            .images
            .iter()
            .map(|(id, image)| {
                let modifier = image.storage.dmabuf().format().modifier;
                serde_json::json!({"texture_id":id,"width":image.width,"height":image.height,
                "modifier":format!("{modifier:?}"),"modifier_code":u64::from(modifier)})
            })
            .collect::<Vec<_>>();
        images.sort_unstable_by_key(|image| image["texture_id"].as_i64());
        serde_json::json!({"enabled":state.pass.is_some(), "cache_hits":state.hits,
            "compositions":state.misses,"layer_draws":state.draws,"cached_windows":state.images.len(),
            "cached_images":images,"probe_modifier":state.probe_modifier.map(|m|format!("{m:?}")),
            "disabled_texture_ids":disabled,"live_allocation_bytes":state.pool.as_ref().map_or(0,|pool|pool.live_bytes())})
    }

    pub(in crate::flutter_runtime) fn update_native_window_plans(
        &self,
        windows: &mut [wire::WindowDescription],
        frames: &[ExternalTextureFrame],
        changed: &mut Vec<i64>,
    ) {
        let scene = crate::output_color::scene_encoding();
        let mut state = lock(&self.native_clients);
        for window in windows {
            window.client_texture = None;
            if state.pass.is_none()
                || state.disabled.len() >= 32
                || window.content_kind != wire::WindowContentKind::SurfaceTree
            {
                continue;
            }
            let Some(canvas) = ClientRect::new(
                window.surface_x,
                window.surface_y,
                window.surface_width,
                window.surface_height,
            ) else {
                continue;
            };
            let Some(plan) = NativeWindowPlan::new(
                window.window_id,
                canvas,
                f64::from(window.scale_120) / 120.0,
                &window.surfaces,
            ) else {
                continue;
            };
            if state.disabled.contains(&plan.texture_id) {
                continue;
            }
            // The pass maps crops only; other canvases need the engine.
            if plan.layers.iter().any(|layer| {
                frames
                    .iter()
                    .find(|frame| frame.texture_id == layer.texture_id)
                    .and_then(|frame| frame.presentation.as_ref())
                    .is_some_and(|presentation| !reproduces_presentation(presentation))
            }) {
                continue;
            }
            // The pass copies pixels as they are; converted ones need the engine.
            if plan.layers.iter().any(|layer| {
                frames
                    .iter()
                    .find(|frame| frame.texture_id == layer.texture_id)
                    .and_then(ExternalTextureFrame::color)
                    .is_some_and(|color| color.needs_pass(scene))
            }) {
                continue;
            }
            let previous = state.registry.get(plan.texture_id).map(|p| p.revision);
            let Some(versioned) = state.registry.upsert(plan) else {
                continue;
            };
            let plan = &versioned.plan;
            window.client_texture = Some(wire::ClientTextureDescription {
                texture_id: plan.texture_id as u64,
                width: plan.width,
                height: plan.height,
                source_width: plan.canvas.width * plan.scale,
                source_height: plan.canvas.height * plan.scale,
            });
            if previous != Some(versioned.revision) && !changed.contains(&plan.texture_id) {
                changed.push(plan.texture_id);
            }
        }
    }
    pub(in crate::flutter_runtime) fn expand_native_texture_changes(&self, changed: &mut Vec<i64>) {
        lock(&self.native_clients)
            .registry
            .include_dependents(changed);
    }
    pub(in crate::flutter_runtime) fn remove_native_window(&self, texture_id: i64) {
        let mut state = lock(&self.native_clients);
        state.registry.remove(texture_id);
        state.images.remove(&texture_id);
    }
    pub(in crate::flutter_runtime) fn take_native_window_fallback(&self) -> bool {
        self.native_fallback_pending.swap(false, Ordering::AcqRel)
    }
    pub(super) fn uses_native_window_texture(&self, texture_id: i64) -> bool {
        texture_id >= (1_i64 << 62)
            && lock(&self.native_clients)
                .registry
                .handles_texture(texture_id)
    }
    /// Plans follow each scene commit at once, while a newly mapped
    /// subsurface's first buffer becomes current only at the next frame
    /// tick. Until then that layer is not drawn, as in the surface tree.
    fn native_snapshot(&self, texture_id: i64) -> Option<NativeSnapshot> {
        let plan = lock(&self.native_clients).registry.get(texture_id)?;
        let sources = lock(&self.external_texture_sources);
        let mut inputs = Vec::with_capacity(plan.plan.layers.len());
        let mut presentations = Vec::with_capacity(plan.plan.layers.len());
        for layer in &plan.plan.layers {
            let slot = sources
                .get(&layer.texture_id)
                .filter(|slot| slot.current.is_some());
            presentations.push(slot.map(|slot| slot.presentation));
            if let Some(source) = slot.and_then(|slot| slot.current.clone()) {
                inputs.push((layer.texture_id, source));
            }
        }
        Some(NativeSnapshot {
            plan,
            inputs,
            presentations,
        })
    }
    fn native_samples(inputs: &[(i64, ExternalTextureSource)]) -> Vec<NativeInputSample> {
        inputs
            .iter()
            .map(|(texture_id, source)| NativeInputSample {
                texture_id: *texture_id,
                generation: source.generation(),
                feedback: source.feedback(),
            })
            .collect()
    }
    pub(super) fn prepare_native_without_gl(
        &self,
        texture_id: i64,
    ) -> Option<PreparedExternalTexture> {
        let snapshot = self.native_snapshot(texture_id)?;
        let keys = snapshot
            .inputs
            .iter()
            .map(|(_, source)| PixelIdentity::new(source))
            .collect::<Vec<_>>();
        let mut state = lock(&self.native_clients);
        let image = state.images.get(&texture_id)?;
        if !image.matches(snapshot.plan.revision, &keys, &snapshot.presentations) {
            return None;
        }
        let permit = self.external_texture_resource_budget.try_acquire()?;
        let buffer = ExternalBufferGuard::OwnedNative {
            storage: Arc::clone(&image.storage),
        };
        let prepared = PreparedExternalTexture {
            texture_id,
            source_generation: image.storage.allocation_id,
            feedback: None,
            color: None,
            width: image.width,
            height: image.height,
            name: image.binding.texture(),
            resource: ExternalTextureLeaseResource::Dmabuf {
                _binding: Arc::clone(&image.binding),
                _buffer_guard: Some(buffer.clone()),
                _resource_permit: permit,
            },
            sampled_buffer: Some(buffer),
            native_samples: Self::native_samples(&snapshot.inputs),
        };
        state.hits = state.hits.saturating_add(1);
        if state.hits == 1 {
            info!(
                texture_id,
                "native client merged image reused without GLES work"
            );
        }
        Some(prepared)
    }
    pub(super) fn prepare_native_with_gl(
        &self,
        texture_id: i64,
    ) -> Option<PreparedExternalTexture> {
        if let Some(prepared) = self.prepare_native_without_gl(texture_id) {
            return Some(prepared);
        }
        // The window left native composition after this frame was scheduled.
        let NativeSnapshot {
            plan,
            inputs,
            presentations,
        } = self.native_snapshot(texture_id)?;
        let result = (|| -> Result<PreparedExternalTexture, String> {
            let presented = plan
                .plan
                .presented(&presentations)
                .ok_or("native client input presentation is not a crop")?;
            let (pool, disabled) = {
                let state = lock(&self.native_clients);
                (
                    state.pool.clone().ok_or("native pool unavailable")?,
                    state.disabled.contains(&texture_id),
                )
            };
            if disabled {
                return Err("native window already disabled".into());
            }
            // Reclaim retired output BOs only after their final EGL/image
            // owner, then retain their storage through the next reader fence.
            self.destroy_retired_external_bindings();
            let storage = pool
                .acquire([plan.plan.width, plan.plan.height])
                .map_err(|e| e.to_string())?
                .ok_or("native target byte budget exhausted")?;
            let source = ExternalTextureSource::Dmabuf {
                dmabuf: storage.dmabuf().clone(),
                buffer_guard: Some(ExternalBufferGuard::OwnedNative {
                    storage: Arc::clone(&storage),
                }),
                revision: storage.allocation_id,
                feedback: None,
                color: None,
            };
            let mut output = self
                .prepare_source_with_gl(texture_id, source)
                .ok_or("native output EGL import failed")?;
            let keys = inputs
                .iter()
                .map(|(_, source)| PixelIdentity::new(source))
                .collect::<Vec<_>>();
            let scene = crate::output_color::scene_encoding();
            if inputs
                .iter()
                .any(|(_, source)| source.color().is_some_and(|color| color.needs_pass(scene)))
            {
                return Err("a native client input needs color conversion".into());
            }
            let mut prepared_inputs = Vec::with_capacity(inputs.len());
            let mut draw_inputs = Vec::with_capacity(inputs.len());
            for (input_texture_id, source) in inputs {
                let input = self
                    .prepare_source_with_gl(input_texture_id, source)
                    .ok_or("native client input import failed")?;
                draw_inputs.push(NativeWindowInput {
                    texture_id: input_texture_id,
                    name: input.name,
                    size: [input.width as u32, input.height as u32],
                });
                prepared_inputs.push(input);
            }
            // A failing pass may have submitted partial GPU reads/writes.
            // Pin all sources and the destination before any drawing starts.
            for input in prepared_inputs.iter().chain(std::iter::once(&output)) {
                if let Some(buffer) = &input.sampled_buffer {
                    self.record_sampled_buffer(
                        input.texture_id,
                        input.source_generation,
                        buffer.clone(),
                    );
                }
            }
            let draws = {
                let mut state = lock(&self.native_clients);
                state
                    .pass
                    .as_mut()
                    .ok_or("native GLES pass unavailable")?
                    .render(&presented, &draw_inputs, output.name)?
            };
            let binding = output.resource.binding();
            output.native_samples = prepared_inputs
                .iter()
                .map(|input| NativeInputSample {
                    texture_id: input.texture_id,
                    generation: input.source_generation,
                    feedback: input.feedback.clone(),
                })
                .collect();
            let modifier = storage.dmabuf().format().modifier;
            let mut state = lock(&self.native_clients);
            state.images.insert(
                texture_id,
                ClientImage {
                    plan_revision: plan.revision,
                    inputs: keys,
                    presentations,
                    binding,
                    storage,
                    width: output.width,
                    height: output.height,
                },
            );
            state.misses = state.misses.saturating_add(1);
            state.draws = state.draws.saturating_add(draws as u64);
            if state.misses == 1 {
                info!(
                    texture_id,
                    width = output.width,
                    height = output.height,
                    draws,
                    ?modifier,
                    live_bytes = pool.live_bytes(),
                    "native client surface tree merged on raster context"
                );
            }
            Ok(output)
        })();
        match result {
            Ok(output) => Some(output),
            Err(reason) => {
                let mut state = lock(&self.native_clients);
                if state.disabled.insert(texture_id) {
                    warn!(texture_id,%reason,"native client composition disabled for window; republishing original surface tree");
                    self.native_fallback_pending.store(true, Ordering::Release);
                    drop(state);
                    self.notify_frame_ready();
                }
                None
            }
        }
    }
    pub(super) fn finish_native_samples(&self, samples: Vec<NativeInputSample>) {
        for sample in samples {
            self.record_sampled_feedback(sample.feedback);
            self.mark_external_texture_sampled(sample.texture_id, sample.generation);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn equal_revision_on_different_shm_storage_does_not_reuse_pixels() {
        let a = ShmTextureFrame::new_owned(1, 1, 7, vec![1, 2, 3, 4]).unwrap();
        let b = ShmTextureFrame::new_owned(1, 1, 7, vec![4, 3, 2, 1]).unwrap();
        let key = PixelIdentity::new(&ExternalTextureSource::Shm(a.clone()));
        assert!(key.same(&PixelIdentity::new(&ExternalTextureSource::Shm(a.clone()))));
        assert!(!key.same(&PixelIdentity::new(&ExternalTextureSource::Shm(b))));
        let mut revised = a;
        revised.revision += 1;
        assert!(!key.same(&PixelIdentity::new(&ExternalTextureSource::Shm(revised))));
    }
}
