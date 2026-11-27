//! Cached native client images on Flutter's existing raster GL context.
use super::super::super::native_window::{
    ClientRect, NativeWindowLayer, NativeWindowPlan, NativeWindowRegistry, VersionedWindowPlan,
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
    /// The layers as placed by older buffers, where the plan was not drawn
    /// as it is.
    placed: Option<Vec<NativeWindowLayer>>,
    inputs: Vec<PixelIdentity>,
    presentations: Vec<Option<denial_flutter_engine::ExternalTexturePresentation>>,
    binding: Arc<CachedTextureBinding>,
    storage: Arc<NativeWindowStorage>,
    width: usize,
    height: usize,
}
impl ClientImage {
    fn matches(&self, snapshot: &NativeSnapshot, inputs: &[PixelIdentity]) -> bool {
        self.plan_revision == snapshot.plan.revision
            && self.placed.as_deref() == snapshot.placed.as_ref().map(|plan| &*plan.layers)
            && self.inputs.len() == inputs.len()
            && self.inputs.iter().zip(inputs).all(|(a, b)| a.same(b))
            && self.presentations == snapshot.presentations
    }
}
/// The latest plan with the buffers its layers currently show.
#[derive(Clone)]
pub(in crate::flutter_runtime) struct NativeSnapshot {
    plan: Arc<VersionedWindowPlan>,
    /// The plan with its layers placed as their current buffers were
    /// committed, when a buffer is older than the plan and shows otherwise.
    placed: Option<NativeWindowPlan>,
    /// Current buffers in layer order, for the layers this frame draws.
    inputs: Vec<(i64, ExternalTextureSource)>,
    /// Current buffers of the layers it does not draw: covered, or outside
    /// the window. They are shown as far as they can be.
    covered: Vec<(i64, ExternalTextureSource)>,
    /// Per plan layer: the presentation that advanced with its buffer, or
    /// `None` while the layer has no current buffer.
    presentations: Vec<Option<denial_flutter_engine::ExternalTexturePresentation>>,
    /// What changed between recent buffers, beside `inputs`.
    histories: Vec<DamageHistory>,
}
impl NativeSnapshot {
    /// The plan this frame draws.
    fn shown(&self) -> &NativeWindowPlan {
        self.placed.as_ref().unwrap_or(&self.plan.plan)
    }
}
#[derive(Default)]
pub(super) struct NativeClientState {
    registry: NativeWindowRegistry,
    cursor_placement: Option<denial_flutter_engine::ExternalTexturePresentation>,
    cursor_snapshot: Option<Arc<NativeSnapshot>>,
    pending_cursor_inputs: Option<Arc<NativeSnapshot>>,
    cursor_update: Option<Instant>,
    cursor_submits: u64,
    images: HashMap<i64, ClientImage>,
    pool: Option<Arc<NativeWindowPool>>,
    pass: Option<NativeWindowGl>,
    disabled: HashSet<i64>,
    hits: u64,
    misses: u64,
    draws: u64,
    probe_modifier: Option<Modifier>,
    /// The plan revision each native window's damage was last given for.
    damage_revisions: HashMap<i64, u64>,
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

    /// `scale` is the engine's device pixel ratio: the merged image replaces
    /// the surface tree at the resolution Flutter draws it. A root's buffer
    /// scale says nothing about its subsurfaces, and is 1 for clients that
    /// size buffers through wp_viewporter.
    pub(in crate::flutter_runtime) fn update_native_window_plans(
        &self,
        windows: &mut [wire::WindowDescription],
        frames: &mut [ExternalTextureFrame],
        scale: f64,
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
            let Some(plan) =
                NativeWindowPlan::new(window.window_id, canvas, scale, &window.surfaces)
            else {
                continue;
            };
            if state.disabled.contains(&plan.texture_id) {
                continue;
            }
            // The pass maps crops only and copies pixels as they are: other
            // canvases and converted pixels need the engine.
            if plan.layers.iter().any(|layer| {
                frames
                    .iter()
                    .find(|frame| frame.texture_id == layer.texture_id)
                    .is_some_and(|frame| {
                        frame
                            .presentation
                            .as_ref()
                            .is_some_and(|presentation| !reproduces_presentation(presentation))
                            || frame.color().is_some_and(|color| color.needs_pass(scene))
                    })
            }) {
                continue;
            }
            let previous = state.registry.get(plan.texture_id).map(|p| p.revision);
            let Some(versioned) = state.registry.upsert(plan) else {
                continue;
            };
            let plan = &versioned.plan;
            // Each buffer keeps the placement of its own commit until the
            // next one is drawn.
            for layer in &plan.layers {
                if let Some(frame) = frames
                    .iter_mut()
                    .find(|frame| frame.texture_id == layer.texture_id)
                {
                    frame.layer = Some(layer.placement());
                }
            }
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
    pub(in crate::flutter_runtime) fn stage_cursor_plan(&self, plan: Option<NativeWindowPlan>) {
        let mut state = lock(&self.native_clients);
        state.pending_cursor_inputs = None;
        if let Some(plan) = plan {
            state.registry.upsert(plan);
        } else {
            state
                .registry
                .remove(crate::flutter_runtime::cursor_scene::TEXTURE);
        }
    }

    /// Motion and unrelated shell frames share the immutable source buffers.
    /// Only the platform thread prepares these. Raster holds its own Arc.
    pub(in crate::flutter_runtime) fn cursor_inputs(
        &self,
        refresh: bool,
    ) -> Option<Arc<NativeSnapshot>> {
        let mut state = lock(&self.native_clients);
        if !refresh && let Some(snapshot) = &state.pending_cursor_inputs {
            return Some(snapshot.clone());
        }
        drop(state);
        let snapshot = self
            .snapshot_inputs(crate::flutter_runtime::cursor_scene::TEXTURE)
            .map(Arc::new);
        state = lock(&self.native_clients);
        state.pending_cursor_inputs = snapshot.clone();
        snapshot
    }

    pub(in crate::flutter_runtime) fn place_cursor(
        &self,
        placement: Option<denial_flutter_engine::ExternalTexturePresentation>,
        snapshot: Option<Arc<NativeSnapshot>>,
        update: Option<Instant>,
    ) {
        let mut state = lock(&self.native_clients);
        state.cursor_placement = placement;
        state.cursor_snapshot = snapshot;
        state.cursor_update = update;
    }

    pub(super) fn record_cursor_submit(&self) {
        let mut state = lock(&self.native_clients);
        let Some(update) = state.cursor_update.take() else {
            return;
        };
        state.cursor_submits += 1;
        if state.cursor_submits <= 4 || state.cursor_submits.is_multiple_of(128) {
            info!(
                submissions = state.cursor_submits,
                update_to_submit_us = update.elapsed().as_micros() as u64,
                "Stagecraft submitted the visible cursor with Vulkan"
            );
        }
    }

    pub(super) fn cursor_placement(
        &self,
    ) -> Option<denial_flutter_engine::ExternalTexturePresentation> {
        lock(&self.native_clients).cursor_placement
    }

    /// A single unrotated cursor image can be sampled directly, including
    /// when only part of it is visible at the atlas edge. Keep the tree
    /// merge for rotated, translucent or multi-surface cursors.
    pub(super) fn direct_cursor(
        &self,
    ) -> Option<(
        i64,
        ExternalTextureSource,
        denial_flutter_engine::ExternalTexturePresentation,
    )> {
        let (snapshot, mut placement) = {
            let state = lock(&self.native_clients);
            (state.cursor_snapshot.clone()?, state.cursor_placement?)
        };
        let [(id, source)] = snapshot.inputs.as_slice() else {
            return None;
        };
        let [layer] = snapshot.plan.plan.layers.as_slice() else {
            return None;
        };
        if layer.transform != 0
            || layer.opacity != 1.
            || layer.destination != snapshot.plan.plan.canvas
        {
            return None;
        }
        let input = snapshot.presentations.first()?.as_ref()?;
        if !reproduces_presentation(input) {
            return None;
        }
        let rect = layer.source;
        let [sx, sy, sw, sh] = crate::wayland_frontend::canvas_rect_to_buffer(
            Some(input),
            [rect.x, rect.y, rect.width, rect.height],
        );
        let [x, y, w, h] = placement.source;
        let width = snapshot.plan.plan.canvas.width * snapshot.plan.plan.scale;
        let height = snapshot.plan.plan.canvas.height * snapshot.plan.plan.scale;
        placement.source = [
            sx + x / width * sw,
            sy + y / height * sh,
            w / width * sw,
            h / height * sh,
        ];
        Some((*id, source.clone(), placement))
    }

    pub(super) fn cursor_image_placement(
        &self,
    ) -> Option<denial_flutter_engine::ExternalTexturePresentation> {
        self.direct_cursor()
            .map(|(_, _, p)| p)
            .or_else(|| self.cursor_placement())
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
        state.damage_revisions.remove(&texture_id);
        drop(state);
        if let Some(composer) = &self.scene_composer {
            composer.forget_texture(texture_id);
        }
    }
    pub(in crate::flutter_runtime) fn take_native_window_fallback(&self) -> bool {
        self.native_fallback_pending.swap(false, Ordering::AcqRel)
    }
    /// The plans of the native windows among `texture_ids`: None for one
    /// whose plan changed since its damage was last given, which changed
    /// whole.
    pub(super) fn native_window_plans(
        &self,
        texture_ids: &[i64],
    ) -> Vec<(i64, Option<Arc<VersionedWindowPlan>>)> {
        let mut state = lock(&self.native_clients);
        let state = &mut *state;
        texture_ids
            .iter()
            .filter_map(|texture_id| {
                let plan = state.registry.get(*texture_id)?;
                let previous = state.damage_revisions.insert(*texture_id, plan.revision);
                Some((
                    *texture_id,
                    (previous == Some(plan.revision)).then_some(plan),
                ))
            })
            .collect()
    }
    /// What changed in a native window's merged image: where its layers'
    /// inputs changed. None when that is not known, so it changed whole: an
    /// input changed outside this frame's textures or has no image.
    pub(super) fn native_window_damage(
        plan: &VersionedWindowPlan,
        taken: &HashMap<i64, Option<(Vec<[f64; 4]>, [f64; 2])>>,
        moved: &[i64],
        sources: &HashMap<i64, ExternalTextureSlot>,
    ) -> Option<Vec<[f64; 4]>> {
        let plan = &plan.plan;
        let mut rects = Vec::new();
        for layer in &plan.layers {
            // A buffer the plan does not place, or one placed anew, shows
            // elsewhere than the plan says.
            if moved.contains(&layer.texture_id)
                || sources.get(&layer.texture_id).is_some_and(|slot| {
                    slot.layer_changed()
                        || slot
                            .layer
                            .is_some_and(|placement| placement != layer.placement())
                })
            {
                return None;
            }
            match taken.get(&layer.texture_id) {
                Some(Some((changed, [width, height]))) => {
                    rects.extend(changed.iter().filter_map(|[x, y, w, h]| {
                        plan.window_damage(
                            layer,
                            Some([x * width, y * height, w * width, h * height]),
                        )
                    }));
                }
                Some(None) => rects.extend(plan.window_damage(layer, None)),
                None => {
                    let slot = sources.get(&layer.texture_id)?;
                    if slot.current.is_none() || slot.has_unreported_damage() {
                        return None;
                    }
                }
            }
        }
        Some(rects)
    }
    pub(super) fn uses_native_window_texture(&self, texture_id: i64) -> bool {
        texture_id == crate::flutter_runtime::cursor_scene::TEXTURE
            || texture_id >= (1_i64 << 62)
                && lock(&self.native_clients)
                    .registry
                    .handles_texture(texture_id)
    }
    /// Plans follow each scene commit at once, while buffers become current
    /// a frame tick or two later. A newly mapped subsurface has none until
    /// then and is not drawn, as in the surface tree. A buffer older than
    /// the plan is drawn as its own commit placed it. Either way the layers
    /// it does not cover are drawn.
    fn native_snapshot(&self, texture_id: i64) -> Option<NativeSnapshot> {
        if texture_id == crate::flutter_runtime::cursor_scene::TEXTURE {
            return lock(&self.native_clients)
                .cursor_snapshot
                .as_deref()
                .cloned();
        }
        self.snapshot_inputs(texture_id)
    }

    fn snapshot_inputs(&self, texture_id: i64) -> Option<NativeSnapshot> {
        let plan = lock(&self.native_clients).registry.get(texture_id)?;
        let sources = lock(&self.external_texture_sources);
        let slots = plan
            .plan
            .layers
            .iter()
            .map(|layer| {
                sources
                    .get(&layer.texture_id)
                    .filter(|slot| slot.current.is_some())
            })
            .collect::<Vec<_>>();
        let mut placed = None;
        let mut current = Vec::with_capacity(slots.len());
        for (index, (layer, slot)) in plan.plan.layers.iter().zip(&slots).enumerate() {
            current.push(match slot {
                None => false,
                Some(slot) => match slot
                    .layer
                    .filter(|placement| *placement != layer.placement())
                {
                    None => true,
                    Some(placement) => placed
                        .get_or_insert_with(|| plan.plan.clone())
                        .place(index, placement),
                },
            });
        }
        let drawn = placed.as_ref().unwrap_or(&plan.plan).drawn(&current);
        let mut inputs = Vec::with_capacity(plan.plan.layers.len());
        let mut covered = Vec::new();
        let mut presentations = Vec::with_capacity(plan.plan.layers.len());
        let mut histories = Vec::with_capacity(plan.plan.layers.len());
        for ((layer, slot), drawn) in plan.plan.layers.iter().zip(slots).zip(drawn) {
            let source = slot.and_then(|slot| slot.current.clone());
            let slot = slot.filter(|_| drawn);
            presentations.push(slot.map(|slot| slot.presentation));
            match (slot, source) {
                (Some(slot), Some(source)) => {
                    inputs.push((layer.texture_id, source));
                    histories.push(slot.history.clone());
                }
                (None, Some(source)) => covered.push((layer.texture_id, source)),
                _ => {}
            }
        }
        Some(NativeSnapshot {
            plan,
            placed,
            inputs,
            covered,
            presentations,
            histories,
        })
    }
    /// A native window for the Vulkan composer: the layers the GLES pass
    /// would draw from the same snapshot, mapped into the window's image.
    pub(super) fn composer_merged_client(
        &self,
        texture_id: i64,
        bounds: denial_flutter_engine::scene::Rect,
    ) -> Result<super::stagecraft::Client, super::stagecraft::Decline> {
        use super::stagecraft::{Client, MergedClient, MergedLayer, Placement, SampledClient};
        let cursor = texture_id == crate::flutter_runtime::cursor_scene::TEXTURE;
        if cursor && let Some((id, source, presentation)) = self.direct_cursor() {
            let size = match &source {
                ExternalTextureSource::Dmabuf { dmabuf, .. } => {
                    (dmabuf.width() as u32, dmabuf.height() as u32)
                }
                ExternalTextureSource::Shm(frame) => (frame.width(), frame.height()),
            };
            let Some(placement) = Placement::new(bounds, size, Some(&presentation)) else {
                // The first few say which numbers the check refused.
                static LOGGED: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
                if LOGGED.fetch_add(1, std::sync::atomic::Ordering::Relaxed) < 8 {
                    warn!(
                        ?bounds,
                        image = ?size,
                        ?presentation,
                        "cursor placement refused"
                    );
                }
                return Err("cursor placement");
            };
            let sampled = SampledClient {
                texture_id: id,
                generation: source.generation(),
                source,
            };
            let color = sampled.source.color();
            let needs_conversion = color
                .as_deref()
                .is_some_and(|c| c.needs_pass(crate::output_color::scene_encoding()));
            if !needs_conversion
                && !matches!(&sampled.source, ExternalTextureSource::Dmabuf {buffer_guard:Some(guard),..} if guard.owned_native().is_some())
            {
                return Ok(Client::Image {
                    placement,
                    sampled,
                    look: None,
                });
            }
            let grade = color.as_deref().map(|c| Grade {
                transform: c.transform(crate::output_color::scene_encoding()),
                alpha: c.alpha,
                look: None,
            });
            return Ok(match self.composer_convert(&sampled, grade)? {
                Some(image) => Client::Converted {
                    placement,
                    sampled,
                    image,
                },
                None => Client::Omitted(sampled),
            });
        }
        let placement = cursor.then(|| self.cursor_placement()).flatten();
        if cursor && placement.is_none() {
            return Ok(Client::Missing);
        }
        let snapshot = self
            .native_snapshot(texture_id)
            .ok_or("native window plan")?;
        // Layers that are not drawn are left out of both.
        let presented = snapshot
            .shown()
            .presented(&snapshot.presentations)
            .ok_or("native window presentation")?;
        let NativeSnapshot {
            inputs,
            covered,
            histories,
            ..
        } = snapshot;
        if presented.layers.len() != inputs.len() {
            return Err("native window inputs");
        }
        let scene = crate::output_color::scene_encoding();
        let size = (presented.width, presented.height);
        let mut layers = Vec::with_capacity(inputs.len());
        // A covered layer waits for no sample: its buffer counts as shown.
        let mut unseen = covered
            .into_iter()
            .map(|(texture_id, source)| SampledClient {
                texture_id,
                generation: source.generation(),
                source,
            })
            .collect::<Vec<_>>();
        for ((layer, (input_id, source)), history) in
            presented.layers.iter().zip(inputs).zip(histories)
        {
            if source.color().is_some_and(|color| {
                color.transform(scene).is_some() || color.alpha != Default::default()
            }) {
                return Err("color conversion");
            }
            let buffer = match &source {
                ExternalTextureSource::Dmabuf { dmabuf, .. } => {
                    [dmabuf.width() as u32, dmabuf.height() as u32]
                }
                ExternalTextureSource::Shm(frame) => [frame.width(), frame.height()],
            };
            let sampled = SampledClient {
                texture_id: input_id,
                generation: source.generation(),
                source,
            };
            // As the GLES pass: a layer it cannot place is not drawn, and
            // its buffer still counts as shown.
            let (Some(vertices), Some(limits)) = (
                presented.vertices(layer, buffer),
                layer.sample_limits(buffer),
            ) else {
                unseen.push(sampled);
                continue;
            };
            let [upper_left, upper_right, lower_left, lower_right] = vertices;
            layers.push(MergedLayer {
                sampled,
                quad: [
                    upper_left.position[0],
                    upper_left.position[1],
                    lower_right.position[0],
                    lower_right.position[1],
                ],
                uv: [upper_left.uv, upper_right.uv, lower_left.uv],
                limits,
                opacity: layer.opacity,
                history,
            });
        }
        Ok(Client::Merged {
            placement: Placement::new(bounds, size, placement.as_ref())
                .ok_or("native window placement")?,
            merged: MergedClient {
                texture_id,
                size,
                layers,
                unseen,
            },
            look: self.app_look(texture_id),
        })
    }
    /// What a merged image owes the buffers it shows: those drawn into it
    /// and those its opaque layers cover, which wait for no sample of
    /// their own.
    fn native_samples(buffers: &[(i64, ExternalTextureSource)]) -> Vec<NativeInputSample> {
        buffers
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
        if texture_id == crate::flutter_runtime::cursor_scene::TEXTURE
            && self.direct_cursor().is_some()
        {
            return None;
        }
        self.cached_native(texture_id, &self.native_snapshot(texture_id)?)
    }
    /// The merged image of `snapshot`, when the last merge drew exactly it.
    fn cached_native(
        &self,
        texture_id: i64,
        snapshot: &NativeSnapshot,
    ) -> Option<PreparedExternalTexture> {
        let keys = snapshot
            .inputs
            .iter()
            .map(|(_, source)| PixelIdentity::new(source))
            .collect::<Vec<_>>();
        let mut state = lock(&self.native_clients);
        let image = state.images.get(&texture_id)?;
        if !image.matches(snapshot, &keys) {
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
            native_samples: Self::native_samples(&snapshot.inputs)
                .into_iter()
                .chain(Self::native_samples(&snapshot.covered))
                .collect(),
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
        if texture_id == crate::flutter_runtime::cursor_scene::TEXTURE
            && let Some((id, source, _)) = self.direct_cursor()
        {
            let mut prepared = self.prepare_source_with_gl(id, source)?;
            prepared.native_samples.push(NativeInputSample {
                texture_id: id,
                generation: prepared.source_generation,
                feedback: prepared.feedback.take(),
            });
            prepared.texture_id = texture_id;
            return Some(prepared);
        }
        // None: the window left native composition after this frame was
        // scheduled.
        let snapshot = self.native_snapshot(texture_id)?;
        if let Some(prepared) = self.cached_native(texture_id, &snapshot) {
            return Some(prepared);
        }
        let covered = Self::native_samples(&snapshot.covered);
        let presented = snapshot.shown().presented(&snapshot.presentations);
        let NativeSnapshot {
            plan,
            placed,
            inputs,
            presentations,
            ..
        } = snapshot;
        let result = (|| -> Result<PreparedExternalTexture, String> {
            let presented = presented.ok_or("native client input presentation is not a crop")?;
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
                opaque: false,
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
                .chain(covered)
                .collect();
            let modifier = storage.dmabuf().format().modifier;
            let mut state = lock(&self.native_clients);
            state.images.insert(
                texture_id,
                ClientImage {
                    plan_revision: plan.revision,
                    placed: placed.map(|plan| plan.layers),
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
