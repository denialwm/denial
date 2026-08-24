//! Surface commit ingestion, snapshot publication, and Flutter scene projection.

use super::*;

impl WaylandFrontend {
    #[cfg(feature = "flutter")]
    pub(super) fn surface_id(&self, surface: &WlSurface) -> Option<u64> {
        self.surface_ids.get(&surface.id()).copied()
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn live_toplevel_ids(&self) -> HashSet<u64> {
        self.space
            .elements()
            .filter_map(|window| self.window_root_surface(window))
            .filter_map(|surface| self.surface_id(&surface))
            .collect()
    }

    pub(super) fn toplevel_candidate_surface(&self, surface: &WlSurface) -> WlSurface {
        let mut tree_root = surface.clone();
        while let Some(parent) = get_parent(&tree_root) {
            tree_root = parent;
        }

        self.popups
            .find_popup(&tree_root)
            .and_then(|popup| find_popup_root_surface(&popup).ok())
            .unwrap_or(tree_root)
    }

    pub(super) fn update_surface_fractional_scale(&self, surface: &WlSurface) {
        let root = self.toplevel_candidate_surface(surface);
        let preferred_scale = self
            .window_for_root_surface(&root)
            .and_then(|window| {
                self.output_for_geometry(self.window_geometry_target(&window))
                    .map(|output| output.output.current_scale().fractional_scale())
            })
            .or_else(|| {
                self.outputs
                    .first()
                    .map(|output| output.output.current_scale().fractional_scale())
            })
            .unwrap_or(1.0);
        let preferred_scale = Self::client_preferred_scale(surface, preferred_scale);
        with_states(surface, |states| {
            with_fractional_scale(states, |fractional_scale| {
                fractional_scale.set_preferred_scale(preferred_scale);
            });
        });
    }

    pub(super) fn client_preferred_scale(surface: &WlSurface, output_scale: f64) -> f64 {
        let client_scale = surface
            .client()
            .and_then(|client| {
                client
                    .get_data::<XWaylandClientData>()
                    .map(|data| data.compositor_state.client_scale())
            })
            .unwrap_or(1.0)
            .max(f64::EPSILON);
        (output_scale / client_scale).max(1.0)
    }

    #[cfg(feature = "flutter")]
    pub(super) fn owning_toplevel_surface(&self, surface: &WlSurface) -> Option<WlSurface> {
        let candidate = self.toplevel_candidate_surface(surface);
        self.space
            .elements()
            .any(|window| self.window_root_surface(window).as_ref() == Some(&candidate))
            .then_some(candidate)
    }

    #[cfg(feature = "flutter")]
    pub(super) fn remove_surface_shm_frame(&mut self, surface_id: &ObjectId) {
        let Some(frame) = self.surface_shm_frames.remove(surface_id) else {
            return;
        };
        let bytes = rgba_payload_len(frame.width(), frame.height())
            .expect("validated SHM frame dimensions must fit usize");
        debug_assert!(bytes <= self.shm_snapshot_bytes);
        self.shm_snapshot_bytes = self.shm_snapshot_bytes.saturating_sub(bytes);
    }

    #[cfg(feature = "flutter")]
    pub(super) fn update_surface_shm_frame(
        &mut self,
        surface: &WlSurface,
        buffer: &wl_buffer::WlBuffer,
    ) {
        let surface_id = surface.id();
        // Drop the previous CPU snapshot before reserving its replacement, so
        // repeated commits cannot transiently grow the owned cache without a
        // bound. Flutter may retain the Arc for its current raster frame only.
        self.remove_surface_shm_frame(&surface_id);
        let available_cache_bytes = self
            .shm_snapshot_budget_bytes
            .saturating_sub(self.shm_snapshot_bytes);
        let revision = self.next_shm_revision;
        match snapshot_shm_buffer(
            buffer,
            revision,
            available_cache_bytes,
            &self.shm_snapshot_pool,
        ) {
            Ok(Some(frame)) => {
                let frame_bytes = rgba_payload_len(frame.width(), frame.height())
                    .expect("validated SHM frame dimensions must fit usize");
                debug_assert!(frame_bytes <= available_cache_bytes);
                self.shm_snapshot_bytes = self
                    .shm_snapshot_bytes
                    .checked_add(frame_bytes)
                    .expect("bounded SHM snapshot accounting must not overflow");
                self.next_shm_revision = revision.wrapping_add(1).max(1);
                self.surface_shm_frames.insert(surface_id, frame);
            }
            Ok(None) => {}
            Err(error) => {
                warn!(
                    %error,
                    surface_id = ?surface_id,
                    buffer_id = ?buffer.id(),
                    cached_bytes = self.shm_snapshot_bytes,
                    cache_budget_bytes = self.shm_snapshot_budget_bytes,
                    "could not snapshot Wayland SHM buffer for Flutter"
                );
            }
        }
    }

    #[cfg(feature = "flutter")]
    pub(super) fn queue_surface_commit(&mut self, surface: &WlSurface, kind: SurfaceCommitKind) {
        self.pending_surface_commits
            .entry(surface.id())
            .and_modify(|pending| *pending = pending.merge(kind))
            .or_insert(kind);
    }

    #[cfg(feature = "flutter")]
    pub(super) fn publish_surface_commits(&mut self, root: &WlSurface) -> PublishedSurfaceCommits {
        let mut committed_surfaces = std::mem::take(&mut self.committed_surfaces_scratch);
        committed_surfaces.clear();
        let mut buffer_surface_ids = std::mem::take(&mut self.published_surface_ids_scratch);
        buffer_surface_ids.clear();
        with_surface_tree_upward(
            root,
            (),
            |_, _, _| TraversalAction::DoChildren(()),
            |surface, _, _| committed_surfaces.push(surface.clone()),
            |_, _, _| true,
        );

        let mut metadata_changed = false;
        for surface in committed_surfaces.drain(..) {
            let Some(kind) = self.pending_surface_commits.remove(&surface.id()) else {
                continue;
            };
            let current_buffer = with_renderer_surface_state(&surface, |state| {
                state.buffer().map(|buffer| (**buffer).clone())
            })
            .flatten();
            if current_buffer
                .as_ref()
                .is_some_and(|buffer| get_dmabuf(buffer).is_ok())
            {
                let revision = self.next_buffer_revision.max(1);
                self.next_buffer_revision = revision.wrapping_add(1).max(1);
                self.surface_buffer_revisions.insert(surface.id(), revision);
                self.pending_shm_snapshots.remove(&surface.id());
                self.remove_surface_shm_frame(&surface.id());
            } else if let Some(buffer) = current_buffer {
                self.surface_buffer_revisions.remove(&surface.id());
                if self.pending_shm_snapshots.remove(&surface.id())
                    || !self.surface_shm_frames.contains_key(&surface.id())
                {
                    self.update_surface_shm_frame(&surface, &buffer);
                }
            } else {
                self.surface_buffer_revisions.remove(&surface.id());
                self.pending_shm_snapshots.remove(&surface.id());
                self.remove_surface_shm_frame(&surface.id());
            }

            // SurfaceAttributes aggregates damage across commits until the
            // compositor consumes it. The renderer helper drains damage when
            // a new buffer is attached, but deliberately leaves damage-only
            // commits untouched. Consume that remainder only after this
            // surface's transaction is published: clearing it in the commit
            // handler would discard synchronized-subsurface damage before the
            // parent transaction can process it, while leaving it here makes
            // later callback-only commits look like fresh visual updates.
            with_states(&surface, |states| {
                let mut attributes = states.cached_state.get::<SurfaceAttributes>();
                attributes.current().damage.clear();
            });

            match kind {
                SurfaceCommitKind::BufferOnly => {
                    let Some(surface_id) = self.surface_id(&surface) else {
                        metadata_changed = true;
                        continue;
                    };
                    // A buffer can take the fast path only after its surface
                    // has appeared in an accepted full scene. This also
                    // excludes pre-map and zero-geometry commits.
                    let owner = self.scene_surface_windows.get(&surface_id).copied();
                    if owner == Some(surface_id)
                        && !self.scene_complex_windows.contains(&surface_id)
                    {
                        buffer_surface_ids.push(surface_id);
                    } else {
                        metadata_changed = true;
                    }
                }
                SurfaceCommitKind::Metadata => metadata_changed = true,
            }
        }
        self.committed_surfaces_scratch = committed_surfaces;
        PublishedSurfaceCommits {
            metadata_changed,
            buffer_surface_ids,
        }
    }

    #[cfg(feature = "flutter")]
    pub(super) fn recycle_published_surface_ids(&mut self, mut surface_ids: Vec<u64>) {
        surface_ids.clear();
        debug_assert!(self.published_surface_ids_scratch.is_empty());
        self.published_surface_ids_scratch = surface_ids;
    }

    pub fn init_renderer(&mut self, renderer: &mut GlesRenderer) -> Result<(), Box<dyn Error>> {
        if self.dmabuf_global.is_some() {
            return Ok(());
        }

        #[cfg(feature = "flutter")]
        self.init_screencopy_worker(renderer)?;

        let render_node = match EGLDevice::device_for_display(renderer.egl_context().display())
            .and_then(|device| device.try_get_render_node())
        {
            Ok(node) => node,
            Err(error) => {
                warn!(%error, "could not identify the EGL render node; advertising linux-dmabuf v3");
                None
            }
        };
        let render_formats =
            <GlesRenderer as Bind<Dmabuf>>::supported_formats(renderer).unwrap_or_default();
        self.set_screencopy_dmabuf_formats(render_formats);
        let formats = renderer.dmabuf_formats();
        let global = if let Some(node) = render_node {
            let feedback = DmabufFeedbackBuilder::new(node.dev_id(), formats).build()?;
            self.dmabuf_render_node = Some(node);
            info!(?node, "advertising linux-dmabuf v4 with renderer feedback");
            self.dmabuf_state
                .create_global_with_default_feedback::<RuntimeState>(
                    &self.display_handle,
                    &feedback,
                )
        } else {
            info!("advertising linux-dmabuf v3 without renderer feedback");
            self.dmabuf_state
                .create_global::<RuntimeState>(&self.display_handle, formats)
        };
        self.dmabuf_global = Some(global);
        Ok(())
    }

    pub fn process_pending_dmabufs(
        &mut self,
        renderer: &mut GlesRenderer,
    ) -> Result<(), Box<dyn Error>> {
        if self.pending_dmabuf_imports.is_empty() {
            return Ok(());
        }
        for (dmabuf, notifier) in self.pending_dmabuf_imports.drain(..) {
            if renderer.import_dmabuf(&dmabuf, None).is_ok() {
                if let Some(node) = self.dmabuf_render_node {
                    dmabuf.set_node(node);
                }
                if notifier.successful::<RuntimeState>().is_err() {
                    warn!("linux-dmabuf client disappeared before import completed");
                }
            } else {
                warn!(
                    planes = dmabuf.num_planes(),
                    "rejected client linux-dmabuf import"
                );
                notifier.failed();
            }
        }
        // Flutter owns steady-state composition, so this Smithay renderer
        // never reaches the render-frame cleanup which normally prunes dead
        // WeakDmabuf cache keys and destroys their EGLImages. Without an
        // explicit cleanup here, every client buffer ever validated remains
        // resident through the renderer's dma-buf cache for the lifetime of
        // the compositor.
        renderer.cleanup_texture_cache()?;
        self.dmabuf_import_queue_saturated = false;
        self.display_handle.flush_clients()?;
        Ok(())
    }

    pub(super) fn queue_dmabuf_import(&mut self, dmabuf: Dmabuf, notifier: ImportNotifier) {
        if !dmabuf_import_queue_has_capacity(self.pending_dmabuf_imports.len()) {
            if !self.dmabuf_import_queue_saturated {
                warn!(
                    limit = MAX_PENDING_DMABUF_IMPORTS,
                    "rejecting client linux-dmabuf imports until the bounded queue is drained"
                );
                self.dmabuf_import_queue_saturated = true;
            }
            notifier.failed();
            return;
        }
        self.pending_dmabuf_imports.push((dmabuf, notifier));
    }

    #[cfg(feature = "flutter")]
    #[allow(clippy::too_many_arguments)]
    pub(super) fn append_surface_tree(
        &self,
        root: &WlSurface,
        origin: Point<i32, Logical>,
        root_role: SurfaceRoleDescription,
        root_parent_surface_id: u64,
        popup_root_surface_id: u64,
        expects_sample: bool,
        composition_order: &mut u32,
        layers: &mut Vec<SurfaceLayerDescription>,
        textures: &mut Vec<ExternalTextureFrame>,
    ) {
        with_surface_tree_upward(
            root,
            SurfaceTreeContext {
                location: origin,
                parent_surface_id: root_parent_surface_id,
            },
            |surface, states, context| {
                let Some(renderer_state) = states.data_map.get::<RendererSurfaceStateUserData>()
                else {
                    return TraversalAction::SkipChildren;
                };
                let renderer_state = renderer_state
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                match renderer_state.view() {
                    Some(view) => {
                        let Some(surface_id) = self.surface_id(surface) else {
                            return TraversalAction::SkipChildren;
                        };
                        TraversalAction::DoChildren(SurfaceTreeContext {
                            location: saturating_point_add(context.location, view.offset),
                            parent_surface_id: surface_id,
                        })
                    }
                    None => TraversalAction::SkipChildren,
                }
            },
            |surface, states, context| {
                let Some(surface_id) = self.surface_id(surface) else {
                    return;
                };
                let Some(renderer_state) = states.data_map.get::<RendererSurfaceStateUserData>()
                else {
                    return;
                };
                let renderer_state = renderer_state
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                let Some(view) = renderer_state.view() else {
                    return;
                };
                if view.dst.w <= 0 || view.dst.h <= 0 {
                    return;
                }

                let location = saturating_point_add(context.location, view.offset);
                let transform = renderer_state.buffer_transform();
                let scale = renderer_state.buffer_scale().max(1);
                let source = renderer_state
                    .buffer_size()
                    .map(|buffer_size| {
                        view.src
                            .to_buffer(f64::from(scale), transform, &buffer_size.to_f64())
                    })
                    .unwrap_or_default();
                let renderer_buffer = renderer_state.buffer();
                let opaque = renderer_state.opaque_regions().is_some_and(|regions| {
                    Rectangle::from_size(view.dst)
                        .subtract_rects(regions.iter().copied())
                        .is_empty()
                });
                let dmabuf = renderer_buffer
                    .and_then(|buffer| get_dmabuf(buffer).ok())
                    .cloned();
                let buffer_guard = dmabuf.as_ref().and_then(|_| renderer_buffer.cloned());
                let (texture_id, width, height) = if let (Some(dmabuf), Some(buffer_guard)) =
                    (dmabuf, buffer_guard)
                {
                    let width = dmabuf.width();
                    let height = dmabuf.height();
                    let Ok(texture_id) = i64::try_from(surface_id) else {
                        return;
                    };
                    let revision = self
                        .surface_buffer_revisions
                        .get(&surface.id())
                        .copied()
                        .unwrap_or_default();
                    textures.push(ExternalTextureFrame::from_dmabuf(
                        texture_id,
                        dmabuf,
                        buffer_guard,
                        revision,
                        expects_sample,
                    ));
                    (surface_id, width, height)
                } else if let Some(frame) = self.surface_shm_frames.get(&surface.id()).cloned() {
                    let width = frame.width();
                    let height = frame.height();
                    let Ok(texture_id) = i64::try_from(surface_id) else {
                        return;
                    };
                    textures.push(ExternalTextureFrame::from_shm(
                        texture_id,
                        frame,
                        expects_sample,
                    ));
                    (surface_id, width, height)
                } else {
                    (0, 0, 0)
                };
                let role = if surface == root {
                    root_role
                } else {
                    SurfaceRoleDescription::Subsurface
                };
                layers.push(SurfaceLayerDescription {
                    surface_id,
                    parent_surface_id: context.parent_surface_id,
                    popup_root_surface_id,
                    role,
                    texture_id,
                    width,
                    height,
                    surface_x: f64::from(location.x),
                    surface_y: f64::from(location.y),
                    surface_width: f64::from(view.dst.w),
                    surface_height: f64::from(view.dst.h),
                    texture_source_x: source.loc.x,
                    texture_source_y: source.loc.y,
                    texture_source_width: source.size.w,
                    texture_source_height: source.size.h,
                    transform: transform_to_wire(transform),
                    scale_120: u32::try_from(scale).unwrap_or(1).saturating_mul(120),
                    composition_order: *composition_order,
                    opacity: 1.0,
                    opaque,
                });
                *composition_order = composition_order.saturating_add(1);
            },
            |_, _, _| true,
        );
    }

    #[cfg(feature = "flutter")]
    pub(super) fn external_texture_frame(
        &self,
        surface_id: u64,
        expects_sample: bool,
    ) -> Option<ExternalTextureFrame> {
        let surface = self.surfaces_by_id.get(&surface_id)?;
        let (renderable, dmabuf_source) = with_renderer_surface_state(surface, |state| {
            let renderable = state
                .view()
                .is_some_and(|view| view.dst.w > 0 && view.dst.h > 0);
            let renderer_buffer = state.buffer();
            let dmabuf = renderer_buffer
                .and_then(|buffer| get_dmabuf(buffer).ok())
                .cloned();
            let buffer_guard = dmabuf.as_ref().and_then(|_| renderer_buffer.cloned());
            (renderable, dmabuf.zip(buffer_guard))
        })?;
        if !renderable {
            return None;
        }
        let texture_id = i64::try_from(surface_id).ok().filter(|id| *id > 0)?;
        if let Some((dmabuf, buffer_guard)) = dmabuf_source {
            let revision = self
                .surface_buffer_revisions
                .get(&surface.id())
                .copied()
                .unwrap_or_default();
            return Some(ExternalTextureFrame::from_dmabuf(
                texture_id,
                dmabuf,
                buffer_guard,
                revision,
                expects_sample,
            ));
        }
        self.surface_shm_frames
            .get(&surface.id())
            .cloned()
            .map(|frame| ExternalTextureFrame::from_shm(texture_id, frame, expects_sample))
    }

    /// Build source updates only for surfaces whose already-published layout
    /// is unchanged. `None` requests a conservative full scene rebuild.
    #[cfg(feature = "flutter")]
    pub fn flutter_dirty_textures(
        &mut self,
        surface_ids: impl IntoIterator<Item = u64>,
    ) -> Option<Vec<ExternalTextureFrame>> {
        let mut textures = std::mem::take(&mut self.scene_textures_scratch);
        textures.clear();
        for surface_id in surface_ids {
            let Some(window_id) = self.scene_surface_windows.get(&surface_id).copied() else {
                self.scene_textures_scratch = textures;
                return None;
            };
            let expects_sample = window_expects_sample(
                self.input_visibility_known,
                &self.visible_window_ids,
                window_id,
            );
            let Some(frame) = self.external_texture_frame(surface_id, expects_sample) else {
                self.scene_textures_scratch = textures;
                return None;
            };
            textures.push(frame);
        }
        Some(textures)
    }

    #[cfg(feature = "flutter")]
    pub fn recycle_flutter_dirty_textures(&mut self, mut textures: Vec<ExternalTextureFrame>) {
        textures.clear();
        debug_assert!(self.scene_textures_scratch.is_empty());
        self.scene_textures_scratch = textures;
    }

    #[cfg(feature = "flutter")]
    pub(super) fn surface_tree_offset(
        &self,
        root: &WlSurface,
        target: &WlSurface,
    ) -> Option<Point<i32, Logical>> {
        let mut target_offset = None;
        with_surface_tree_upward(
            root,
            Point::from((0, 0)),
            |surface, states, location| {
                let Some(renderer_state) = states.data_map.get::<RendererSurfaceStateUserData>()
                else {
                    return TraversalAction::SkipChildren;
                };
                let renderer_state = renderer_state
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                let Some(view) = renderer_state.view() else {
                    return TraversalAction::SkipChildren;
                };
                let location = saturating_point_add(*location, view.offset);
                if surface == target {
                    target_offset = Some(location);
                }
                TraversalAction::DoChildren(location)
            },
            |_, _, _| {},
            |_, _, _| true,
        );
        target_offset
    }

    #[cfg(feature = "flutter")]
    pub(super) fn input_method_editor_rectangle_global(&self) -> Option<Rectangle<i32, Logical>> {
        let editor = self.input_method.active_editor()?;
        let rectangle = editor.cursor_rectangle.unwrap_or_default();
        let origin = match editor.endpoint {
            EditorEndpoint::Flutter { .. } => Point::from((
                self.atlas_origin
                    .x
                    .round()
                    .clamp(f64::from(i32::MIN), f64::from(i32::MAX)) as i32,
                self.atlas_origin
                    .y
                    .round()
                    .clamp(f64::from(i32::MIN), f64::from(i32::MAX)) as i32,
            )),
            EditorEndpoint::Wayland { surface, .. } => {
                let root = self.owning_toplevel_surface(&surface)?;
                let window = self.window_for_root_surface(&root)?;
                let root_origin = saturating_point_sub(
                    self.window_geometry_target(&window).loc,
                    window.geometry().loc,
                );
                let surface_offset = self.surface_tree_offset(&root, &surface)?;
                saturating_point_add(root_origin, surface_offset)
            }
        };
        Some(Rectangle::new(
            saturating_point_add(origin, rectangle.loc),
            rectangle.size,
        ))
    }

    #[cfg(feature = "flutter")]
    pub(super) fn place_input_method_popup(
        &self,
        cursor: Rectangle<i32, Logical>,
        size: Size<i32, Logical>,
    ) -> Rectangle<i32, Logical> {
        let anchor = Rectangle::new(
            Point::from((cursor.loc.x, cursor.loc.y.saturating_add(cursor.size.h))),
            (1, 1).into(),
        );
        let bounds = self
            .output_for_geometry(anchor)
            .map(|output| output.logical_geometry)
            .unwrap_or(self.desktop_bounds);
        let width = size.w.max(1).min(bounds.size.w.max(1));
        let height = size.h.max(1).min(bounds.size.h.max(1));
        let right = bounds
            .loc
            .x
            .saturating_add(bounds.size.w)
            .saturating_sub(width);
        let bottom = bounds
            .loc
            .y
            .saturating_add(bounds.size.h)
            .saturating_sub(height);
        let x = cursor.loc.x.clamp(bounds.loc.x, right.max(bounds.loc.x));
        let below = cursor.loc.y.saturating_add(cursor.size.h);
        let above = cursor.loc.y.saturating_sub(height);
        let y = if below <= bottom { below } else { above }
            .clamp(bounds.loc.y, bottom.max(bounds.loc.y));
        Rectangle::new((x, y).into(), (width, height).into())
    }

    #[cfg(feature = "flutter")]
    pub fn flutter_scene(
        &mut self,
    ) -> Result<(Vec<WindowDescription>, Vec<ExternalTextureFrame>), Box<dyn Error>> {
        let mut windows = std::mem::take(&mut self.scene_windows_scratch);
        let mut textures = std::mem::take(&mut self.scene_textures_scratch);
        textures.clear();
        let mut popups = std::mem::take(&mut self.scene_popups_scratch);
        popups.clear();
        let mut surface_windows = std::mem::take(&mut self.scene_surface_windows_scratch);
        surface_windows.clear();
        let mut complex_windows = std::mem::take(&mut self.scene_complex_windows_scratch);
        complex_windows.clear();
        let input_method_editor_rectangle = self.input_method_editor_rectangle_global();
        let input_method_popups = self.input_method.visible_popups();
        let mut window_count = 0;
        for window in self.space.elements() {
            let Some(surface) = self.window_root_surface(window) else {
                continue;
            };
            let Some(stable_id) = self.surface_id(&surface) else {
                let x11 = window.x11_surface();
                warn!(
                    surface = ?surface.id(),
                    surface_alive = surface.is_alive(),
                    backend = if x11.is_some() { "x11" } else { "wayland" },
                    x11_window = ?x11.as_ref().map(|surface| surface.window_id()),
                    x11_override_redirect = ?x11
                        .as_ref()
                        .map(|surface| surface.is_override_redirect()),
                    "omitting desktop window without a stable surface identifier"
                );
                // TODO: Make surface destruction and desktop-window eviction
                // atomic and idempotent. A wl_surface destruction callback can
                // remove the stable identity before the XDG/Xwayland teardown
                // callback removes its Window from Space, especially during
                // Xwayland override-redirect remaps.
                continue;
            };
            let geometry = self.window_geometry_target(window);
            if geometry.size.w <= 0 || geometry.size.h <= 0 {
                continue;
            }
            let content = window.geometry();
            if content.size.w <= 0 || content.size.h <= 0 {
                continue;
            }
            let (mut title, mut app_id, mut layers) = windows
                .get_mut(window_count)
                .map(|previous| {
                    (
                        std::mem::take(&mut previous.title),
                        std::mem::take(&mut previous.app_id),
                        std::mem::take(&mut previous.surfaces),
                    )
                })
                .unwrap_or_default();
            title.clear();
            app_id.clear();
            layers.clear();
            let x11 = window.x11_surface();
            if window.toplevel().is_some() {
                with_states(&surface, |states| {
                    let Some(attributes) = states.data_map.get::<XdgToplevelSurfaceData>() else {
                        return;
                    };
                    let attributes = attributes
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner());
                    if let Some(value) = &attributes.title {
                        title.push_str(value);
                    }
                    if let Some(value) = &attributes.app_id {
                        app_id.push_str(value);
                    }
                });
            } else if let Some(x11) = x11.as_ref() {
                // Smithay exposes these X11 properties as owned strings.
                title = x11.title();
                app_id = x11.class();
            }
            let mut composition_order = 0;
            // Flutter does not sample a texture after its window leaves the
            // visible scene (for example, once a minimize animation reaches
            // zero opacity). Mailbox those buffers without waiting for a
            // sample so restore begins with the client's latest generation.
            // Until Dart publishes its first visibility snapshot, preserve
            // the conservative sampled-texture lifetime contract.
            let expects_sample = window_expects_sample(
                self.input_visibility_known,
                &self.visible_window_ids,
                stable_id,
            );
            self.append_surface_tree(
                &surface,
                (0, 0).into(),
                SurfaceRoleDescription::Root,
                0,
                0,
                expects_sample,
                &mut composition_order,
                &mut layers,
                &mut textures,
            );

            popups.extend(PopupManager::popups_for_surface(&surface));
            popups.reverse();
            for (popup, popup_location) in popups.drain(..) {
                let popup_surface = popup.wl_surface();
                let Some(popup_surface_id) = self.surface_id(popup_surface) else {
                    continue;
                };
                let parent_surface_id = match &popup {
                    PopupKind::Xdg(popup) => popup
                        .get_parent_surface()
                        .and_then(|parent| self.surface_id(&parent))
                        .unwrap_or(0),
                    PopupKind::InputMethod(_) => 0,
                };
                let popup_origin = saturating_point_sub(
                    saturating_point_add(content.loc, popup_location),
                    popup.geometry().loc,
                );
                self.append_surface_tree(
                    popup_surface,
                    popup_origin,
                    SurfaceRoleDescription::Popup,
                    parent_surface_id,
                    popup_surface_id,
                    expects_sample,
                    &mut composition_order,
                    &mut layers,
                    &mut textures,
                );
            }

            for layer in &layers {
                if layer.texture_id > 0 {
                    surface_windows.insert(layer.surface_id, stable_id);
                }
            }
            if layers.len() != 1 || layers[0].surface_id != stable_id {
                // Smithay exposes no compositor callback for immediate
                // wl_subsurface stacking requests. Keep multi-layer windows
                // on the metadata path so a later buffer commit cannot hide
                // an intervening order change from Flutter.
                complex_windows.insert(stable_id);
            }

            let root_layer = layers.iter().find(|layer| layer.surface_id == stable_id);
            let fallback_width = u32::try_from(content.size.w)?;
            let fallback_height = u32::try_from(content.size.h)?;
            let (
                texture_id,
                root_width,
                root_height,
                texture_source_x,
                texture_source_y,
                texture_source_width,
                texture_source_height,
                transform,
                scale_120,
                opacity,
            ) = root_layer.map_or((0, 0, 0, 0.0, 0.0, 0.0, 0.0, 0, 120, 1.0), |layer| {
                (
                    layer.texture_id,
                    layer.width,
                    layer.height,
                    layer.texture_source_x,
                    layer.texture_source_y,
                    layer.texture_source_width,
                    layer.texture_source_height,
                    layer.transform,
                    layer.scale_120,
                    layer.opacity,
                )
            });
            let width = if root_width > 0 {
                root_width
            } else {
                fallback_width
            };
            let height = if root_height > 0 {
                root_height
            } else {
                fallback_height
            };
            let monitor_id = self
                .output_for_geometry(geometry)
                .and_then(|entry| i64::try_from(entry.id.0).ok())
                .unwrap_or(-1);
            let (suppress_animations, server_side_decorated, window_opacity) = x11
                .as_ref()
                .map(|x11| {
                    let server_side_decorated = shell_draws_x11_server_frame(x11);
                    (
                        !server_side_decorated,
                        server_side_decorated,
                        xwayland::x11_window_opacity(x11),
                    )
                })
                .unwrap_or((false, true, 1.0));
            if window_opacity < 1.0 {
                for layer in &mut layers {
                    layer.opacity *= window_opacity;
                    layer.opaque = false;
                }
            }
            let opacity_class = with_renderer_surface_state(&surface, |state| {
                let Some(view) = state.view() else {
                    return WindowOpacityClass::ContentTranslucent;
                };
                classify_window_opacity(
                    Rectangle::from_size(view.dst),
                    content,
                    state.opaque_regions(),
                    opacity * window_opacity,
                )
            })
            .unwrap_or(WindowOpacityClass::ContentTranslucent);
            let description = WindowDescription {
                object_id: stable_id,
                surface_id: stable_id,
                window_id: stable_id,
                texture_id,
                title,
                app_id,
                width,
                height,
                surface_x: f64::from(content.loc.x),
                surface_y: f64::from(content.loc.y),
                surface_width: f64::from(content.size.w),
                surface_height: f64::from(content.size.h),
                texture_source_x,
                texture_source_y,
                texture_source_width,
                texture_source_height,
                geometry_x: f64::from(geometry.loc.x) - self.atlas_origin.x,
                geometry_y: f64::from(geometry.loc.y) - self.atlas_origin.y,
                geometry_width: f64::from(geometry.size.w),
                geometry_height: f64::from(geometry.size.h),
                monitor_id,
                transform,
                scale_120,
                content_x: f64::from(content.loc.x),
                content_y: f64::from(content.loc.y),
                content_width: f64::from(content.size.w),
                content_height: f64::from(content.size.h),
                suppress_animations,
                server_side_decorated,
                opacity: opacity * window_opacity,
                surfaces: layers,
                content_kind: WindowContentKind::SurfaceTree,
                opacity_class,
            };
            if let Some(previous) = windows.get_mut(window_count) {
                *previous = description;
            } else {
                windows.push(description);
            }
            window_count += 1;
        }
        for local_window in self.local_windows.iter() {
            let width = local_window
                .geometry
                .width
                .round()
                .clamp(1.0, f64::from(u32::MAX)) as u32;
            let height = local_window
                .geometry
                .height
                .round()
                .clamp(1.0, f64::from(u32::MAX)) as u32;
            let global_geometry = Rectangle::<i32, Logical>::new(
                Point::from((
                    local_window
                        .geometry
                        .x
                        .round()
                        .clamp(f64::from(i32::MIN), f64::from(i32::MAX)) as i32,
                    local_window
                        .geometry
                        .y
                        .round()
                        .clamp(f64::from(i32::MIN), f64::from(i32::MAX)) as i32,
                )),
                Size::from((
                    i32::try_from(width).unwrap_or(i32::MAX),
                    i32::try_from(height).unwrap_or(i32::MAX),
                )),
            );
            let monitor_id = self
                .output_for_geometry(global_geometry)
                .and_then(|entry| i64::try_from(entry.id.0).ok())
                .unwrap_or(-1);
            let (mut title, mut app_id, mut surfaces) = windows
                .get_mut(window_count)
                .map(|previous| {
                    (
                        std::mem::take(&mut previous.title),
                        std::mem::take(&mut previous.app_id),
                        std::mem::take(&mut previous.surfaces),
                    )
                })
                .unwrap_or_default();
            title.clear();
            title.push_str(&local_window.title);
            app_id.clear();
            app_id.push_str(&local_window.app_id);
            surfaces.clear();
            let description = WindowDescription {
                object_id: local_window.id,
                surface_id: local_window.id,
                window_id: local_window.id,
                texture_id: 0,
                title,
                app_id,
                width,
                height,
                surface_x: 0.0,
                surface_y: 0.0,
                surface_width: local_window.geometry.width,
                surface_height: local_window.geometry.height,
                texture_source_x: 0.0,
                texture_source_y: 0.0,
                texture_source_width: 0.0,
                texture_source_height: 0.0,
                geometry_x: local_window.geometry.x - self.atlas_origin.x,
                geometry_y: local_window.geometry.y - self.atlas_origin.y,
                geometry_width: local_window.geometry.width,
                geometry_height: local_window.geometry.height,
                monitor_id,
                transform: 0,
                scale_120: 120,
                content_x: 0.0,
                content_y: 0.0,
                content_width: local_window.geometry.width,
                content_height: local_window.geometry.height,
                suppress_animations: false,
                server_side_decorated: true,
                opacity: 1.0,
                surfaces,
                content_kind: WindowContentKind::LocalFlutter,
                opacity_class: WindowOpacityClass::FullyOpaque,
            };
            if let Some(previous) = windows.get_mut(window_count) {
                *previous = description;
            } else {
                windows.push(description);
            }
            window_count += 1;
        }
        if let Some(cursor_rectangle) = input_method_editor_rectangle {
            for popup in input_method_popups {
                let surface = popup.surface();
                let Some(stable_id) = self.surface_id(surface) else {
                    continue;
                };
                let (mut title, mut app_id, mut layers) = windows
                    .get_mut(window_count)
                    .map(|previous| {
                        (
                            std::mem::take(&mut previous.title),
                            std::mem::take(&mut previous.app_id),
                            std::mem::take(&mut previous.surfaces),
                        )
                    })
                    .unwrap_or_default();
                title.clear();
                title.push_str("Input method");
                app_id.clear();
                app_id.push_str("denia-systemui-input-method");
                layers.clear();
                let expects_sample = window_expects_sample(
                    self.input_visibility_known,
                    &self.visible_window_ids,
                    stable_id,
                );
                let mut composition_order = 0;
                self.append_surface_tree(
                    surface,
                    (0, 0).into(),
                    SurfaceRoleDescription::Root,
                    0,
                    0,
                    expects_sample,
                    &mut composition_order,
                    &mut layers,
                    &mut textures,
                );
                if layers.is_empty() {
                    continue;
                }
                let min_x = layers
                    .iter()
                    .map(|layer| layer.surface_x)
                    .fold(f64::INFINITY, f64::min);
                let min_y = layers
                    .iter()
                    .map(|layer| layer.surface_y)
                    .fold(f64::INFINITY, f64::min);
                let max_x = layers
                    .iter()
                    .map(|layer| layer.surface_x + layer.surface_width)
                    .fold(f64::NEG_INFINITY, f64::max);
                let max_y = layers
                    .iter()
                    .map(|layer| layer.surface_y + layer.surface_height)
                    .fold(f64::NEG_INFINITY, f64::max);
                let logical_width = (max_x - min_x).ceil().clamp(1.0, f64::from(i32::MAX)) as i32;
                let logical_height = (max_y - min_y).ceil().clamp(1.0, f64::from(i32::MAX)) as i32;
                let geometry = self.place_input_method_popup(
                    cursor_rectangle,
                    (logical_width, logical_height).into(),
                );
                for layer in &layers {
                    if layer.texture_id > 0 {
                        surface_windows.insert(layer.surface_id, stable_id);
                    }
                }
                if layers.len() != 1 || layers[0].surface_id != stable_id {
                    complex_windows.insert(stable_id);
                }
                let root_layer = layers.iter().find(|layer| layer.surface_id == stable_id);
                let (
                    texture_id,
                    width,
                    height,
                    texture_source_x,
                    texture_source_y,
                    texture_source_width,
                    texture_source_height,
                    transform,
                    scale_120,
                ) = root_layer.map_or((0, 0, 0, 0.0, 0.0, 0.0, 0.0, 0, 120), |layer| {
                    (
                        layer.texture_id,
                        layer.width,
                        layer.height,
                        layer.texture_source_x,
                        layer.texture_source_y,
                        layer.texture_source_width,
                        layer.texture_source_height,
                        layer.transform,
                        layer.scale_120,
                    )
                });
                let monitor_id = self
                    .output_for_geometry(geometry)
                    .and_then(|output| i64::try_from(output.id.0).ok())
                    .unwrap_or(-1);
                let description = WindowDescription {
                    object_id: stable_id,
                    surface_id: stable_id,
                    window_id: stable_id,
                    texture_id,
                    title,
                    app_id,
                    width,
                    height,
                    surface_x: min_x,
                    surface_y: min_y,
                    surface_width: f64::from(logical_width),
                    surface_height: f64::from(logical_height),
                    texture_source_x,
                    texture_source_y,
                    texture_source_width,
                    texture_source_height,
                    geometry_x: f64::from(geometry.loc.x) - self.atlas_origin.x,
                    geometry_y: f64::from(geometry.loc.y) - self.atlas_origin.y,
                    geometry_width: f64::from(geometry.size.w),
                    geometry_height: f64::from(geometry.size.h),
                    monitor_id,
                    transform,
                    scale_120,
                    content_x: min_x,
                    content_y: min_y,
                    content_width: f64::from(logical_width),
                    content_height: f64::from(logical_height),
                    suppress_animations: true,
                    server_side_decorated: false,
                    opacity: 1.0,
                    surfaces: layers,
                    content_kind: WindowContentKind::SurfaceTree,
                    opacity_class: WindowOpacityClass::ContentTranslucent,
                };
                if let Some(previous) = windows.get_mut(window_count) {
                    *previous = description;
                } else {
                    windows.push(description);
                }
                window_count += 1;
            }
        }
        windows.truncate(window_count);
        self.scene_popups_scratch = popups;
        std::mem::swap(&mut self.scene_surface_windows, &mut surface_windows);
        self.scene_surface_windows_scratch = surface_windows;
        std::mem::swap(&mut self.scene_complex_windows, &mut complex_windows);
        self.scene_complex_windows_scratch = complex_windows;
        Ok((windows, textures))
    }

    #[cfg(feature = "flutter")]
    pub fn recycle_flutter_scene(
        &mut self,
        windows: Vec<WindowDescription>,
        textures: Vec<ExternalTextureFrame>,
    ) {
        debug_assert!(self.scene_windows_scratch.is_empty());
        debug_assert!(self.scene_textures_scratch.is_empty());
        self.scene_windows_scratch = windows;
        self.scene_textures_scratch = textures;
    }

    #[cfg(feature = "flutter")]
    pub fn install_input_layout(
        &mut self,
        layout: InputLayoutSnapshot,
    ) -> (Option<InputLayoutSnapshot>, bool, bool) {
        self.text_input
            .set_shell_capture(layout.keyboard_capture() || layout.exclusive_shell());
        let input_method_changed = self.synchronize_input_method();
        let first_generation_layout = self.input_layout.is_none();
        let routing_changed = input_routing_changed(self.input_layout.as_ref(), &layout);
        let visibility_changed = input_visibility_changed(self.input_layout.as_ref(), &layout);
        if visibility_changed {
            let mut visible_window_ids = std::mem::take(&mut self.visible_window_ids);
            visible_window_ids.clear();
            for surface_id in &layout.visible_surface_ids {
                let Some(surface) = self.surfaces_by_id.get(surface_id) else {
                    continue;
                };
                let root = self.toplevel_candidate_surface(surface);
                if let Some(window_id) = self.input_root_ids.get(&root.id()).copied() {
                    visible_window_ids.insert(window_id);
                }
            }
            self.visible_window_ids = visible_window_ids;
            self.invalidate_idle_inhibition();
        }
        self.input_visibility_known = true;
        let previous = self.input_layout.replace(layout);
        if routing_changed {
            self.client_input_route_cache = None;
        }
        if first_generation_layout {
            // InputLayout is published from the live widget tree, after the
            // replacement Dart bridge has subscribed to cursor updates.
            self.queue_cursor_state_for_flutter_generation();
        }
        (
            previous,
            visibility_changed || input_method_changed,
            routing_changed,
        )
    }
}
