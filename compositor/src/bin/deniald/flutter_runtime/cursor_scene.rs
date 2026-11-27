//! The shell declares one fixed texture. Its content, hotspot and destination
//! are a compositor decision, independent of Flutter pointer event routing.
use super::*;
use denial_flutter_engine::ExternalTexturePresentation;
use renderer::native_window::{ClientRect, NativeWindowPlan};
use serde::Deserialize;

pub(super) const WINDOW: u64 = 1 << 61;
pub(super) const TEXTURE: i64 = (1 << 62) | WINDOW as i64;
pub(super) const ARTWORK: i64 = 1 << 60;

#[derive(Deserialize)]
struct Frame {
    path: PathBuf,
    hotspot: [f64; 2],
    delay: u64,
}

#[derive(Deserialize)]
struct Rendition {
    extent: f64,
    frames: Vec<Frame>,
}

#[derive(Deserialize)]
struct Theme {
    root: PathBuf,
    roles: HashMap<String, Vec<Rendition>>,
    canvas: [f64; 2],
    size: f64,
    hidden: bool,
}

pub(super) struct CursorScene {
    assets: PathBuf,
    theme: Option<Theme>,
    state: wire::CursorStateDescription,
    position: Option<(f64, f64)>,
    benchmark_origin: Option<(f64, f64)>,
    scale: f64,
    dirty: bool,
    frame: usize,
    pub(super) deadline: Option<Instant>,
    images: HashMap<PathBuf, ShmTextureFrame>,
    revision: u64,
    // Cursor-local bounds stay fixed throughout ordinary pointer motion.
    geometry: Option<(ClientRect, f64)>,
    pub(super) placement: Option<ExternalTexturePresentation>,
    submitted: HashMap<OutputId, Option<ExternalTexturePresentation>>,
    pub(super) last_update: Option<Instant>,
    plane_image: Option<ShmTextureFrame>,
    client_image: Option<(i64, ShmTextureFrame)>,
    plain_client_texture: Option<i64>,
    /// Outputs whose cursor plane shows the cursor: every output it touches,
    /// or none, when the scene draws it.
    pub(super) plane_outputs: Vec<OutputId>,
    moves: u64,
    renders: u64,
}

impl CursorScene {
    pub(super) fn new(assets: PathBuf) -> Self {
        Self {
            assets,
            theme: None,
            state: wire::CursorStateDescription::named("default"),
            position: None,
            benchmark_origin: None,
            scale: 1.,
            dirty: true,
            frame: 0,
            deadline: None,
            images: HashMap::new(),
            revision: 0,
            geometry: None,
            placement: None,
            submitted: HashMap::new(),
            last_update: None,
            plane_image: None,
            client_image: None,
            plain_client_texture: None,
            plane_outputs: Vec::new(),
            moves: 0,
            renders: 0,
        }
    }

    pub(super) fn configure(&mut self, data: &[u8]) -> Result<(), Box<dyn Error>> {
        let theme: Theme = serde_json::from_slice(data)?;
        if !theme.size.is_finite()
            || !(1.0..=512.0).contains(&theme.size)
            || theme.canvas.iter().any(|x| !x.is_finite() || *x <= 0.)
            || theme.roles.values().flatten().any(|r| {
                !r.extent.is_finite()
                    || r.extent <= 0.
                    || r.frames.is_empty()
                    || r.frames.iter().any(|f| {
                        !f.path
                            .components()
                            .all(|p| matches!(p, std::path::Component::Normal(_)))
                            || f.hotspot.iter().any(|x| !x.is_finite())
                    })
            })
        {
            return Err("invalid cursor geometry or theme frames".into());
        }
        self.images.clear();
        self.theme = Some(theme);
        self.restart();
        Ok(())
    }

    pub(super) fn audit_render(&mut self, framework: bool) {
        self.renders += 1;
        if self.renders <= 4 || self.renders.is_multiple_of(128) {
            info!(
                frames = self.renders,
                motion_updates = self.moves,
                framework,
                visible = self.placement.is_some(),
                "Stagecraft cursor render"
            );
        }
    }

    pub(super) fn configured(&self) -> bool {
        self.theme.is_some()
    }

    fn restart(&mut self) {
        self.frame = 0;
        self.deadline = None;
        self.dirty = true;
    }

    pub(super) fn capture_client_image(&mut self, frames: &[ExternalTextureFrame], reset: bool) {
        if reset {
            self.client_image = None;
            // Buffer-only updates inherit the presentation of the full scene.
            // A virtual canvas or a tree stays in Stagecraft until metadata changes.
            self.plain_client_texture = match frames {
                [frame] if frame.presentation.is_none_or(|p| p.width == 0.0) => {
                    Some(frame.texture_id)
                }
                _ => None,
            };
        }
        if let Some(frame) = frames
            .iter()
            .find(|f| Some(f.texture_id) == self.plain_client_texture)
        {
            self.client_image = frame
                .plane_cursor_image()
                .map(|image| (frame.texture_id, image));
        }
        self.dirty |= !frames.is_empty();
    }

    pub(super) fn set_state(&mut self, state: &wire::CursorStateDescription) {
        if self.state.kind != state.kind
            || self.state.shape != state.shape
            || self.state.drag_active != state.drag_active
        {
            self.restart();
        }
        self.state = state.clone();
        self.dirty = true;
    }

    fn layers(
        &mut self,
        now: Instant,
    ) -> Result<(Vec<wire::SurfaceLayerDescription>, Option<ShmTextureFrame>), Box<dyn Error>> {
        let Some(theme) = &self.theme else {
            return Ok((vec![], None));
        };
        let mut layers = self.state.drag_surfaces.clone();
        if theme.hidden
            || self.state.kind == wire::CursorStateKind::Hidden
            || matches!(self.state.shape.as_str(), "none" | "hidden")
        {
            self.deadline = None;
            return Ok((layers, None));
        }
        if self.state.kind == wire::CursorStateKind::Surface && !self.state.drag_active {
            for mut layer in self.state.surfaces.iter().cloned() {
                layer.surface_x -= self.state.hotspot_x;
                layer.surface_y -= self.state.hotspot_y;
                layers.push(layer);
            }
            return Ok((layers, None));
        }
        let role = if self.state.drag_active {
            "normal"
        } else {
            role(&self.state.shape)
        };
        let choices = theme
            .roles
            .get(role)
            .or_else(|| theme.roles.get("normal"))
            .ok_or("missing normal cursor")?;
        let rendition = choices
            .iter()
            .find(|r| theme.size * self.scale <= r.extent + 0.5)
            .or_else(|| choices.last())
            .ok_or("empty cursor role")?;
        let frame = &rendition.frames[self.frame % rendition.frames.len()];
        if rendition.frames.len() > 1 && frame.delay > 0 {
            self.deadline
                .get_or_insert(now + Duration::from_micros(frame.delay.min(60_000_000)));
        } else {
            self.deadline = None;
        }
        let path = self.assets.join(&theme.root).join(&frame.path);
        if !self.images.contains_key(&path) {
            self.revision += 1;
            let image = decode(&path, self.revision)?;
            self.images.insert(path.clone(), image);
        }
        let image = self.images[&path].clone();
        let scale = theme.size / rendition.extent;
        let width = image.width();
        let height = image.height();
        layers.push(wire::SurfaceLayerDescription {
            surface_id: ARTWORK as u64,
            parent_surface_id: 0,
            popup_root_surface_id: 0,
            role: wire::SurfaceRoleDescription::Root,
            texture_id: ARTWORK as u64,
            width,
            height,
            surface_x: -frame.hotspot[0] * scale,
            surface_y: -frame.hotspot[1] * scale,
            surface_width: f64::from(width) * scale,
            surface_height: f64::from(height) * scale,
            texture_source_x: 0.,
            texture_source_y: 0.,
            texture_source_width: width.into(),
            texture_source_height: height.into(),
            transform: 0,
            scale_120: 120,
            composition_order: layers.len() as u32,
            opacity: 1.,
            opaque: false,
            window_geometry: None,
        });
        Ok((layers, Some(image)))
    }

    fn destination(&self) -> Option<ExternalTexturePresentation> {
        let (rect, scale) = self.geometry?;
        let (x, y) = self.position?;
        let [width, height] = self.theme.as_ref()?.canvas;
        let (x, y) = (x + rect.x, y + rect.y);
        let left = x.max(0.);
        let top = y.max(0.);
        // Clip in cursor-local coordinates. Subtracting two atlas positions
        // can grow an uncut source by one ULP at fractional pointer positions,
        // which makes a valid full-image crop exceed the Vulkan image.
        let source_x = (-x).max(0.);
        let source_y = (-y).max(0.);
        let w = (rect.width - source_x).min(width - left);
        let h = (rect.height - source_y).min(height - top);
        // The input position can be the f64 immediately inside the atlas
        // edge. Both ends then project onto the same f32 scene coordinate.
        if (left + w) as f32 <= left as f32 || (top + h) as f32 <= top as f32 {
            return None;
        }
        Some(ExternalTexturePresentation {
            width,
            height,
            source: [source_x * scale, source_y * scale, w * scale, h * scale],
            destination: [left, top, w, h],
            struct_size: mem::size_of::<ExternalTexturePresentation>(),
            ..Default::default()
        })
    }

    // Damage is relative to the fixed texture that spans the logical atlas.
    // Remember the last submitted position independently for each output.
    pub(super) fn damage(&mut self, outputs: impl Iterator<Item = OutputId>) -> Vec<[f64; 4]> {
        let mut damage = Vec::new();
        for output in outputs {
            let placement = self.placement.filter(|_| self.plane_outputs.is_empty());
            let previous = self.submitted.insert(output, placement).flatten();
            for p in [previous, placement].into_iter().flatten() {
                let [x, y, w, h] = p.destination;
                let left = ((x - 1.) / p.width).max(0.);
                let top = ((y - 1.) / p.height).max(0.);
                let rect = [
                    left,
                    top,
                    ((x + w + 1.) / p.width).min(1.) - left,
                    ((y + h + 1.) / p.height).min(1.) - top,
                ];
                if !damage.contains(&rect) {
                    damage.push(rect);
                }
            }
        }
        damage
    }
}

// Both corners already include the hotspot. Keep negative coordinates so KMS
// clips the artwork at the panel edge without shifting the pointer.
fn native_cursor_rect(output: &RuntimeRenderOutput, rect: ClientRect) -> (i32, i32, u32, u32) {
    let left = (rect.x - output.logical_x) / output.logical_width;
    let top = (rect.y - output.logical_y) / output.logical_height;
    let width = rect.width / output.logical_width;
    let height = rect.height / output.logical_height;
    let first = output.transform.logical_to_native(left, top);
    let last = output
        .transform
        .logical_to_native(left + width, top + height);
    let (width, height) = if output.transform.swaps_axes() {
        (height, width)
    } else {
        (width, height)
    };
    let panel_width = f64::from(output.target_size.width);
    let panel_height = f64::from(output.target_size.height);
    (
        (first.0.min(last.0) * panel_width).round() as i32,
        (first.1.min(last.1) * panel_height).round() as i32,
        (width * panel_width).round() as u32,
        (height * panel_height).round() as u32,
    )
}

impl FlutterRuntime {
    /// The cursor image placed on every output it touches, partly beyond the
    /// edge of each where it crosses a seam. Empty when no plane may show it.
    pub(crate) fn plane_cursors(&self) -> Vec<crate::output_scheduler::CursorSprite> {
        let cursor = &self.cursor_scene;
        let (Some(image), Some((rect, _)), Some((px, py))) = (
            cursor.plane_image.as_ref(),
            cursor.geometry,
            cursor.position,
        ) else {
            return Vec::new();
        };
        if self.output_rotation_animation_active() || self.authentication.locked_epoch().is_some() {
            return Vec::new();
        }
        let (x, y) = (px + rect.x, py + rect.y);
        self.render_outputs
            .iter()
            .filter(|o| o.intersects(x, y, rect.width, rect.height))
            .map(|output| {
                let (x, y, width, height) = native_cursor_rect(output, ClientRect { x, y, ..rect });
                crate::output_scheduler::CursorSprite {
                    output: output.output_id,
                    transform: output.transform,
                    image: image.clone(),
                    x,
                    y,
                    width,
                    height,
                }
            })
            .collect()
    }

    pub(crate) fn select_cursor_planes(&mut self, outputs: Vec<OutputId>) {
        if self.cursor_scene.plane_outputs == outputs {
            return;
        }
        let previous = std::mem::replace(&mut self.cursor_scene.plane_outputs, outputs);
        let composed = self.cursor_scene.plane_outputs.is_empty();
        let changed = previous
            .iter()
            .chain(&self.cursor_scene.plane_outputs)
            .copied()
            .collect::<std::collections::BTreeSet<_>>();
        for id in changed {
            let updates = self.pending_output_updates.entry(id).or_default();
            updates.insert(TEXTURE);
            updates.insert(ARTWORK);
            if composed {
                updates.extend(self.cursor_texture_ids.iter().copied());
            }
        }
    }

    pub(crate) fn has_stagecraft_cursor(&self) -> bool {
        self.cursor_scene.configured()
    }

    /// Lab-only motion moves the artwork through its normal native path,
    /// without dispatching application input or waking the shell framework.
    pub(super) fn benchmark_cursor(&mut self, data: &[u8]) -> Result<bool, Box<dyn Error>> {
        if std::env::var_os("DENIAL_CURSOR_BENCHMARK_SOCKET").is_none() {
            return Ok(false);
        }
        let available =
            self.cursor_scene.placement.is_some() && !self.cursor_scene.state.drag_active;
        match data {
            b"status" => Ok(available),
            b"begin" if available && self.cursor_scene.benchmark_origin.is_none() => {
                self.cursor_scene.benchmark_origin = self.cursor_scene.position;
                Ok(true)
            }
            b"restore" => {
                if let Some(origin) = self.cursor_scene.benchmark_origin.take() {
                    self.update_cursor_scene(Some(origin))?;
                }
                Ok(true)
            }
            _ if available && self.cursor_scene.benchmark_origin.is_some() => {
                let Ok((x, y)) = serde_json::from_slice::<(f64, f64)>(data) else {
                    return Ok(false);
                };
                let origin = self.cursor_scene.benchmark_origin;
                self.update_cursor_scene(Some((x, y)))?;
                self.cursor_scene.benchmark_origin = origin;
                Ok(true)
            }
            _ => Ok(false),
        }
    }

    pub(crate) fn update_cursor_scene(
        &mut self,
        position: Option<(f64, f64)>,
    ) -> Result<(), Box<dyn Error>> {
        let cursor = &mut self.cursor_scene;
        if let Some(p) = position {
            cursor.benchmark_origin = None;
            cursor.position = Some(p);
        }
        let now = Instant::now();
        if cursor.deadline.is_some_and(|t| now >= t) {
            cursor.frame = cursor.frame.wrapping_add(1);
            cursor.deadline = None;
            cursor.dirty = true;
        }
        if let Some((x, y)) = cursor.position
            && let Some(output) = self
                .render_outputs
                .iter()
                .find(|o| o.intersects(x, y, 0.001, 0.001))
        {
            let width = if output.transform.swaps_axes() {
                output.target_size.height
            } else {
                output.target_size.width
            };
            let scale = (f64::from(width) / output.logical_width).max(0.125);
            if (scale - cursor.scale).abs() > 0.001 {
                cursor.scale = scale;
                cursor.dirty = true;
            }
        }
        let changed = mem::take(&mut cursor.dirty);
        if !changed && position.is_none() {
            return Ok(());
        }
        if changed {
            let (layers, image) = cursor.layers(now).unwrap_or_else(|error| {
                warn!(%error, "Stagecraft cursor artwork unavailable");
                (Vec::new(), None)
            });
            cursor.plane_image = match layers.as_slice() {
                [l] if !cursor.state.drag_active && l.transform == 0 && l.opacity == 1. => {
                    image.clone().or_else(|| {
                        let (id, image) = cursor.client_image.as_ref()?;
                        (*id == l.texture_id as i64
                            && l.texture_source_x == 0.
                            && l.texture_source_y == 0.
                            && l.texture_source_width == f64::from(image.width())
                            && l.texture_source_height == f64::from(image.height()))
                        .then(|| image.clone())
                    })
                }
                _ => None,
            };
            if let Some(image) = image {
                self.changed_texture_scratch.clear();
                self.handler.stage_texture_sources(
                    [ExternalTextureFrame::from_shm(ARTWORK, image, false)],
                    &mut self.changed_texture_scratch,
                    !cursor.plane_outputs.is_empty(),
                );
            }
            let bounds = layers.iter().filter(|l| l.texture_id > 0).fold(
                None,
                |bounds: Option<[f64; 4]>, l| {
                    let [x, y, r, b] = [
                        l.surface_x,
                        l.surface_y,
                        l.surface_x + l.surface_width,
                        l.surface_y + l.surface_height,
                    ];
                    Some(bounds.map_or([x, y, r, b], |a| {
                        [x.min(a[0]), y.min(a[1]), r.max(a[2]), b.max(a[3])]
                    }))
                },
            );
            let scale = cursor.scale.clamp(1., 8.);
            let plan = bounds.and_then(|[x, y, r, b]| {
                NativeWindowPlan::new(WINDOW, ClientRect::new(x, y, r - x, b - y)?, scale, &layers)
            });
            cursor.geometry = plan.as_ref().map(|p| (p.canvas, p.scale));
            self.handler.stage_cursor_plan(plan);
        }
        let previous = cursor.placement;
        let next = cursor.destination();
        if next == previous && !changed {
            return Ok(());
        }
        cursor.placement = next;
        for output in &self.render_outputs {
            if !cursor.plane_outputs.contains(&output.output_id)
                && [previous, next].into_iter().flatten().any(|p| {
                    let [x, y, w, h] = p.destination;
                    output.intersects(x, y, w, h)
                })
            {
                let updates = self
                    .pending_output_updates
                    .entry(output.output_id)
                    .or_default();
                updates.insert(TEXTURE);
                if changed {
                    updates.insert(ARTWORK);
                }
            }
        }
        cursor.last_update = Some(now);
        cursor.moves += 1;
        if cursor.moves == 1 || cursor.moves.is_multiple_of(256) {
            debug!(
                updates = cursor.moves,
                visible = next.is_some(),
                "Stagecraft cursor updated"
            );
        }
        Ok(())
    }
}

fn decode(path: &Path, revision: u64) -> Result<ShmTextureFrame, Box<dyn Error>> {
    let file = std::io::BufReader::new(std::fs::File::open(path)?);
    let mut decoder = png::Decoder::new(file);
    decoder.set_transformations(png::Transformations::normalize_to_color8());
    let mut reader = decoder.read_info()?;
    let (w, h) = reader.info().size();
    if w > 512 || h > 512 {
        return Err("cursor PNG exceeds 512 pixels".into());
    }
    let mut data = vec![0; reader.output_buffer_size().ok_or("invalid PNG size")?];
    let info = reader.next_frame(&mut data)?;
    let mut pixels = Vec::with_capacity(w as usize * h as usize * 4);
    use png::ColorType::*;
    for p in data[..info.buffer_size()].chunks_exact(info.color_type.samples()) {
        let (r, g, b, a) = match info.color_type {
            Rgba => (p[0], p[1], p[2], p[3]),
            Rgb => (p[0], p[1], p[2], 255),
            GrayscaleAlpha => (p[0], p[0], p[0], p[1]),
            Grayscale => (p[0], p[0], p[0], 255),
            Indexed => return Err("unexpanded PNG palette".into()),
        };
        let premul = |v| ((u16::from(v) * u16::from(a) + 127) / 255) as u8;
        pixels.extend_from_slice(&[premul(r), premul(g), premul(b), a]);
    }
    Ok(ShmTextureFrame::new_owned(w, h, revision, pixels)?)
}

fn role(shape: &str) -> &'static str {
    match shape {
        "help" | "question-arrow" | "dnd-ask" => "help",
        "pointer" | "hand" | "hand1" | "hand2" | "click" => "link",
        "progress" | "working" | "left-ptr-watch" => "working",
        "wait" | "watch" | "busy" => "busy",
        "cell" | "crosshair" | "precise" | "precision" | "zoom-in" | "zoom-out" | "zoomin"
        | "zoomout" => "precision",
        "text" | "vertical-text" | "verticaltext" | "xterm" => "text",
        "handwriting" | "pencil" | "nwpen" => "handwriting",
        "invalid" | "no-drop" | "nodrop" | "not-allowed" | "notallowed" | "forbidden"
        | "unavailable" => "unavailable",
        "n-resize" | "s-resize" | "ns-resize" | "row-resize" | "top-side" | "bottom-side"
        | "resizeupdown" | "resizeup" | "resizedown" | "resizerow" => "verticalResize",
        "e-resize" | "w-resize" | "ew-resize" | "col-resize" | "left-side" | "right-side"
        | "resizeleftright" | "resizeleft" | "resizeright" | "resizecolumn" => "horizontalResize",
        "nw-resize"
        | "se-resize"
        | "nwse-resize"
        | "top-left-corner"
        | "bottom-right-corner"
        | "resizeupleftdownright"
        | "resizeupleft"
        | "resizedownright" => "diagonalNwSeResize",
        "ne-resize"
        | "sw-resize"
        | "nesw-resize"
        | "top-right-corner"
        | "bottom-left-corner"
        | "resizeuprightdownleft"
        | "resizeupright"
        | "resizedownleft" => "diagonalNeSwResize",
        "move" | "grab" | "grabbing" | "all-scroll" | "allscroll" | "all-resize" | "allresize" => {
            "move"
        }
        "alias" | "copy" | "alternate" | "up-arrow" | "uparrow" => "alternate",
        "person" => "person",
        "pin" | "location" | "loc" => "pin",
        _ => "normal",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_cursor_rect_respects_hotspot_scale_origin_and_output_transform() {
        use OutputTransform::*;
        let native_size = PixelSize::new(200, 120);
        for (transform, expected) in [
            (Normal, (15, -5, 20, 10)),
            (Rotate90, (-5, 85, 10, 20)),
            (Rotate180, (165, 115, 20, 10)),
            (Rotate270, (195, 15, 10, 20)),
            (Flipped, (165, -5, 20, 10)),
            (Flipped90, (-5, 15, 10, 20)),
            (Flipped180, (15, 115, 20, 10)),
            (Flipped270, (195, 85, 10, 20)),
        ] {
            let output_id = OutputId(7);
            let (width, height) = if transform.swaps_axes() {
                (120., 200.)
            } else {
                (200., 120.)
            };
            let output = RuntimeRenderOutput {
                output_id,
                render_view_id: RenderViewId::for_output(output_id).unwrap(),
                configuration_generation: 1,
                target_size: native_size,
                transform,
                logical_x: 256.5,
                logical_y: 12.25,
                logical_width: width / 1.25,
                logical_height: height / 1.25,
            };
            // Pointer at local (16, 2), hotspot (4, 6). The art crosses the top edge.
            let rect = ClientRect::new(
                output.logical_x + 16. - 4.,
                output.logical_y + 2. - 6.,
                16.,
                8.,
            )
            .unwrap();
            assert_eq!(native_cursor_rect(&output, rect), expected, "{transform:?}");
        }
    }

    fn cursor() -> CursorScene {
        let assets =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../packages/denial_flutter_sdk/assets");
        let mut cursor = CursorScene::new(assets);
        cursor.configure(br#"{"root":"cursors/bibata_modern_ice","roles":{"normal":[{"extent":32,"frames":[{"path":"normal/00.png","hotspot":[6,2],"delay":10000},{"path":"help/00.png","hotspot":[5,10],"delay":30000}]},{"extent":64,"frames":[{"path":"normal/64/00.png","hotspot":[13,4],"delay":0}]}]},"canvas":[200,100],"size":32,"hidden":false}"#).unwrap();
        cursor
    }

    #[test]
    fn artwork_uses_output_scale_and_each_animation_frames_hotspot_and_delay() {
        let mut cursor = cursor();
        let now = Instant::now();
        let (layers, _) = cursor.layers(now).unwrap();
        assert_eq!((layers[0].surface_x, layers[0].surface_y), (-6., -2.));
        assert_eq!(cursor.deadline, Some(now + Duration::from_millis(10)));
        cursor.frame = 1;
        cursor.deadline = None;
        let (layers, _) = cursor.layers(now).unwrap();
        assert_eq!((layers[0].surface_x, layers[0].surface_y), (-5., -10.));
        assert_eq!(cursor.deadline, Some(now + Duration::from_millis(30)));
        cursor.scale = 2.;
        let (layers, _) = cursor.layers(now).unwrap();
        assert_eq!(
            (
                layers[0].width,
                layers[0].surface_width,
                layers[0].surface_x
            ),
            (64, 32., -6.5)
        );
        assert!(cursor.deadline.is_none());
    }

    #[test]
    fn application_hotspot_moves_its_tree_and_does_not_apply_theme_size() {
        let mut cursor = cursor();
        let now = Instant::now();
        let (mut layers, _) = cursor.layers(now).unwrap();
        layers[0].surface_x = 0.;
        layers[0].surface_y = 2.;
        cursor.state.surfaces = layers;
        cursor.state.kind = wire::CursorStateKind::Surface;
        cursor.state.hotspot_x = 9.;
        cursor.state.hotspot_y = 7.;
        cursor.theme.as_mut().unwrap().size = 64.;
        let (layers, image) = cursor.layers(now).unwrap();
        assert!(image.is_none());
        assert_eq!(
            (
                layers[0].surface_x,
                layers[0].surface_y,
                layers[0].surface_width
            ),
            (-9., -5., 32.)
        );
    }

    #[test]
    fn fractional_motion_preserves_unclipped_source_extent() {
        let mut cursor = cursor();
        cursor.geometry = Some((ClientRect::new(0., 0., 40., 40.).unwrap(), 1.25));
        for i in 0..10000 {
            let position = f64::from(i) / 179.;
            cursor.position = Some((position, position));
            let p = cursor.destination().unwrap();
            assert_eq!(p.source, [0., 0., 50., 50.]);
            assert_eq!(p.destination, [position, position, 40., 40.]);
        }
    }

    #[test]
    fn cursor_clipped_to_an_empty_scene_quad_is_omitted() {
        let mut cursor = cursor();
        cursor.geometry = Some((ClientRect::new(0., 0., 40., 40.).unwrap(), 1.));
        for p in [(200_f64.next_down(), 30.), (20., 100_f64.next_down())] {
            cursor.position = Some(p);
            assert!(cursor.destination().is_none());
        }
        cursor.position = Some((199.75, 30.));
        let visible = cursor.destination().unwrap();
        assert_eq!(visible.destination, [199.75, 30., 0.25, 40.]);
    }

    #[test]
    fn moving_and_hiding_damage_the_previous_position_on_each_output() {
        let mut cursor = cursor();
        cursor.position = Some((0., 0.));
        cursor.geometry = Some((ClientRect::new(-6., -2., 32., 32.).unwrap(), 2.));
        cursor.placement = cursor.destination();
        let first = cursor.placement.unwrap();
        assert_eq!(first.destination, [0., 0., 26., 30.]);
        assert_eq!(first.source, [12., 4., 52., 60.]);
        let outputs = [OutputId(1), OutputId(2)];
        assert_eq!(cursor.damage(outputs.into_iter()).len(), 1);
        cursor.position = Some((194., 99.));
        cursor.placement = cursor.destination();
        let next = cursor.placement.unwrap();
        assert_eq!(next.destination, [188., 97., 12., 3.]);
        assert_eq!(cursor.damage([outputs[0]].into_iter()).len(), 2);
        cursor.placement = None;
        let first_output = cursor.damage([outputs[0]].into_iter());
        let second_output = cursor.damage([outputs[1]].into_iter());
        assert_eq!(first_output.len(), 1);
        assert_eq!(second_output.len(), 1);
        assert_ne!(first_output, second_output);
    }
}
