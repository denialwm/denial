//! Draw records for the composer's shaders (`shaders/draw.glsl`): what each
//! scene entry samples, where it lands and how it is clipped. Pure math, no
//! Vulkan. Coordinates follow the engine's composition exactly:
//!
//! - Target pixels are Impeller's for the output's wrapped FBO, which renders
//!   without the GLES offscreen flip: target row `y` is memory row `H - y`.
//!   Vulkan addresses memory rows directly, so every record maps through
//!   `ndc_from_target`, which carries that flip.
//! - Slice storage is in Impeller slice coordinates; `bottom_up` storage was
//!   rendered like the output (row `y` at memory row `Hs - y`), other storage
//!   top-down.
//! - Client buffers are top-down.

use denial_flutter_engine::scene::{
    Clip, EntryLocal, Material, Matrix3, Rect, SliceBlit, WindowStyle,
};

pub(super) const KIND_SLICE: u32 = 0;
pub(super) const KIND_TEXTURE: u32 = 1;
pub(super) const KIND_WINDOW: u32 = 2;

/// One clip; std430 layout of `Clip` in `shaders/clip.glsl`. A frame's
/// clips live in their own buffer, and each draw or glass record names its
/// run of them with a `ClipSpan`.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub(super) struct ClipRecord {
    m0: [f32; 4],
    m1: [f32; 4],
    m2: [f32; 4],
    rect: [f32; 4],
    radii_top: [f32; 4],
    radii_bottom: [f32; 4],
    /// A path clip: its first edge, edge count, 1 for even-odd, 1 for a
    /// path. Zeros for a rectangle.
    path: [u32; 4],
}

/// One draw; std430 layout of `Draw` in `shaders/draw.glsl`.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub(super) struct Draw {
    ndc: [[f32; 4]; 3],
    scene: [[f32; 4]; 3],
    quad: [f32; 4],
    uv_x: [f32; 4],
    uv_y: [f32; 4],
    limits: [f32; 4],
    coverage: [f32; 4],
    window: [f32; 4],
    content: [f32; 4],
    frame: [f32; 4],
    params: [f32; 4],
    flags: [u32; 4],
    /// The first of the draw's `flags[1]` clips in the frame's clip buffer.
    clip_first: u32,
    _pad: [u32; 3],
}

const _: () = assert!(std::mem::size_of::<Draw>() == 272);

/// A run of a frame's clip records: `count` from `first`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) struct ClipSpan {
    pub(super) first: u32,
    pub(super) count: u32,
}

impl ClipSpan {
    pub(super) fn is_empty(self) -> bool {
        self.count == 0
    }
}

/// Appends `clips` to a frame's clip records, or reuses the run `last`
/// names when it holds the same records (consecutive draws of one subtree
/// share their clips).
pub(super) fn intern_clips(
    clips: &[Clip],
    last: ClipSpan,
    records: &mut Vec<ClipRecord>,
) -> ClipSpan {
    if clips.is_empty() {
        return ClipSpan::default();
    }
    let first = records.len();
    records.extend(clips.iter().map(clip_record));
    let previous = last.first as usize..(last.first + last.count) as usize;
    if last.count as usize == clips.len() && records[previous.clone()] == records[first..] {
        records.truncate(first);
        return last;
    }
    ClipSpan {
        first: first as u32,
        count: clips.len() as u32,
    }
}

impl Draw {
    /// A window drawn over its material: `glass` indexes the material's
    /// record (window_glass.frag).
    /// Its client is graded through an app look (window.glsl).
    pub(super) fn with_look(mut self, look: bool) -> Self {
        self.params[3] = if look { 1.0 } else { 0.0 };
        self
    }

    pub(super) fn with_glass(mut self, glass: u32) -> Self {
        self.flags[3] = glass;
        self
    }
}

fn rows(m: &Matrix3) -> [[f32; 4]; 3] {
    let m = &m.0;
    [
        [m[0], m[1], m[2], 0.0],
        [m[3], m[4], m[5], 0.0],
        [m[6], m[7], m[8], 0.0],
    ]
}

fn ltrb(rect: &Rect) -> [f32; 4] {
    [rect.left, rect.top, rect.right, rect.bottom]
}

/// Target pixels to Vulkan normalized device coordinates.
pub(super) fn ndc_from_target(width: u32, height: u32) -> Matrix3 {
    let (w, h) = (width as f32, height as f32);
    // x' = 2x/W - 1; Vulkan row H - y, so y' = 2(H - y)/H - 1 = 1 - 2y/H.
    Matrix3([2.0 / w, 0.0, -1.0, 0.0, -2.0 / h, 1.0, 0.0, 0.0, 1.0])
}

/// Normalized coordinates of a texel rectangle, inset by half a texel (at
/// most half its extent) when sampling is strict, as Impeller's SourceLimits.
fn texel_limits(source: [f32; 4], size: (f32, f32), strict: bool) -> [f32; 4] {
    let [mut l, mut t, mut r, mut b] = source;
    if strict {
        let hx = (0.5f32).min((r - l) * 0.5);
        let hy = (0.5f32).min((b - t) * 0.5);
        (l, t, r, b) = (l + hx, t + hy, r - hx, b - hy);
    }
    [l / size.0, t / size.1, r / size.0, b / size.1]
}

/// One rectangle of a slice: `blit.destination` in target pixels sampling
/// `blit.source` in slice coordinates, nearest and strict, as the engine's
/// slice blit.
pub(super) fn slice_blit(
    blit: &SliceBlit,
    storage: (u32, u32),
    bottom_up: bool,
    ndc_from_target: &Matrix3,
) -> Draw {
    let (ws, hs) = (storage.0 as f32, storage.1 as f32);
    let [dl, dt, dr, db] = blit.destination.map(|value| value as f32);
    let [sl, st, sr, sb] = blit.source.map(|value| value as f32);
    // u = (x - dl + sl) / Ws; row = y - dt + st, flipped in bottom-up storage.
    let uv_x = [1.0 / ws, 0.0, (sl - dl) / ws, 0.0];
    let (uv_y, row_top, row_bottom) = if bottom_up {
        ([0.0, -1.0 / hs, (hs + dt - st) / hs, 0.0], hs - sb, hs - st)
    } else {
        ([0.0, 1.0 / hs, (st - dt) / hs, 0.0], st, sb)
    };
    let limits = texel_limits([sl, row_top, sr, row_bottom], (ws, hs), true);
    Draw {
        ndc: rows(ndc_from_target),
        scene: rows(&Matrix3::IDENTITY),
        quad: [dl, dt, dr, db],
        uv_x,
        uv_y,
        limits,
        params: [0.0, 1.0, 0.0, 0.0],
        flags: [KIND_SLICE, 0, 0, 0],
        ..Draw::default()
    }
}

/// Puts a slice draw inside a material: the material's clips (scene
/// coordinates, which `scene_from_target` maps target pixels to) and opacity.
pub(super) fn inside_material(
    draw: &mut Draw,
    clips: ClipSpan,
    opacity: f32,
    scene_from_target: &Matrix3,
) {
    draw.scene = rows(scene_from_target);
    draw.flags[1] = clips.count;
    draw.clip_first = clips.first;
    draw.params[1] = opacity;
}

/// Where a client image lands: its source texels, the local destination and
/// whether sampling is strict (a crop-only presentation).
#[derive(Clone, Copy, Debug, PartialEq)]
pub(in crate::flutter_runtime) struct Placement {
    pub(super) source: [f32; 4],
    pub(super) destination: Rect,
    pub(super) strict: bool,
}

impl Placement {
    /// The image drawn into `bounds`, or a crop-only presentation projected
    /// into them (EmbedderExternalTextureGL::Paint). None for a presentation
    /// with a backing strip, which the composer does not draw.
    pub(in crate::flutter_runtime) fn new(
        bounds: Rect,
        image: (u32, u32),
        presentation: Option<&denial_flutter_engine::ExternalTexturePresentation>,
    ) -> Option<Self> {
        let full = [0.0, 0.0, image.0 as f32, image.1 as f32];
        let Some(presentation) = presentation.filter(|p| p.width > 0.0) else {
            return Some(Self {
                source: full,
                destination: bounds,
                strict: false,
            });
        };
        let finite = |rect: &[f64; 4]| {
            rect.iter().all(|value| value.is_finite()) && rect[2] >= 0.0 && rect[3] >= 0.0
        };
        let (source, destination, background) = (
            &presentation.source,
            &presentation.destination,
            &presentation.background,
        );
        if !finite(source) || !finite(destination) {
            return None;
        }
        let crop_only = (background[2] <= 0.0 || background[3] <= 0.0)
            && source[2] > 0.0
            && source[3] > 0.0
            && destination[2] > 0.0
            && destination[3] > 0.0
            && source[0] >= 0.0
            && source[1] >= 0.0
            && source[0] + source[2] <= f64::from(image.0)
            && source[1] + source[3] <= f64::from(image.1)
            && destination[0] >= 0.0
            && destination[1] >= 0.0
            && destination[0] + destination[2] <= presentation.width
            && destination[1] + destination[3] <= presentation.height;
        if !crop_only {
            return None;
        }
        let sx = f64::from(bounds.right - bounds.left) / presentation.width;
        let sy = f64::from(bounds.bottom - bounds.top) / presentation.height;
        let left = f64::from(bounds.left) + destination[0] * sx;
        let top = f64::from(bounds.top) + destination[1] * sy;
        Some(Self {
            source: [
                source[0] as f32,
                source[1] as f32,
                (source[0] + source[2]) as f32,
                (source[1] + source[3]) as f32,
            ],
            destination: Rect {
                left: left as f32,
                top: top as f32,
                right: (left + destination[2] * sx) as f32,
                bottom: (top + destination[3] * sy) as f32,
            },
            strict: true,
        })
    }

    /// Local (after `local_to_input`) to normalized texture coordinates.
    fn uv(&self, image: (u32, u32), input_from_local: &Matrix3) -> Option<([f32; 4], [f32; 4])> {
        let m = &input_from_local.0;
        if m[6] != 0.0 || m[7] != 0.0 || m[8] != 1.0 {
            return None;
        }
        let (wt, ht) = (image.0 as f32, image.1 as f32);
        let d = &self.destination;
        let (dw, dh) = (d.right - d.left, d.bottom - d.top);
        if dw <= 0.0 || dh <= 0.0 {
            return None;
        }
        let kx = (self.source[2] - self.source[0]) / (dw * wt);
        let ky = (self.source[3] - self.source[1]) / (dh * ht);
        // u = kx (q.x - d.left) + source.left / W, q = input_from_local * p.
        let uv_x = [
            kx * m[0],
            kx * m[1],
            kx * (m[2] - d.left) + self.source[0] / wt,
            0.0,
        ];
        let uv_y = [
            ky * m[3],
            ky * m[4],
            ky * (m[5] - d.top) + self.source[1] / ht,
            0.0,
        ];
        Some((uv_x, uv_y))
    }
}

/// `clips` as few as the shaders need, into `out`: hard-edged rectangles
/// whose space is scale and translation of the scene intersect exactly into
/// one, dropped when it holds all of `screen` (scene coordinates). Rounded
/// and rotated clips are kept as they are.
pub(super) fn reduce_clips(clips: &[Clip], screen: Option<[f32; 4]>, out: &mut Vec<Clip>) {
    out.clear();
    let mut merged: Option<[f32; 4]> = None;
    for clip in clips {
        let m = &clip.scene_to_clip.0;
        let hard = clip.path.is_none() && clip.radii.iter().all(|[x, y]| *x <= 0.0 || *y <= 0.0);
        let axis_aligned = m[1] == 0.0
            && m[3] == 0.0
            && m[6] == 0.0
            && m[7] == 0.0
            && m[8] == 1.0
            && m[0] != 0.0
            && m[4] != 0.0;
        if !(hard && axis_aligned) {
            out.push(*clip);
            continue;
        }
        // Clip space to scene: x = (x' - m[2]) / m[0].
        let (x0, x1) = (
            (clip.rect.left - m[2]) / m[0],
            (clip.rect.right - m[2]) / m[0],
        );
        let (y0, y1) = (
            (clip.rect.top - m[5]) / m[4],
            (clip.rect.bottom - m[5]) / m[4],
        );
        let rect = [x0.min(x1), y0.min(y1), x0.max(x1), y0.max(y1)];
        merged = Some(match merged {
            None => rect,
            Some(m) => [
                m[0].max(rect[0]),
                m[1].max(rect[1]),
                m[2].min(rect[2]),
                m[3].min(rect[3]),
            ],
        });
    }
    let Some(rect) = merged else {
        return;
    };
    let covers_screen = screen.is_some_and(|screen| {
        rect[0] <= screen[0] && rect[1] <= screen[1] && rect[2] >= screen[2] && rect[3] >= screen[3]
    });
    if !covers_screen {
        out.push(Clip {
            scene_to_clip: Matrix3::IDENTITY,
            rect: Rect {
                left: rect[0],
                top: rect[1],
                right: rect[2],
                bottom: rect[3],
            },
            radii: [[0.0; 2]; 4],
            path: None,
        });
    }
}

/// The scene rectangle `output_from_scene` shows in a `target`-sized output,
/// when it is a scale and translation.
pub(super) fn screen_in_scene(output_from_scene: &Matrix3, target: (u32, u32)) -> Option<[f32; 4]> {
    let m = &output_from_scene.inverse()?.0;
    if m[1] != 0.0 || m[3] != 0.0 || m[6] != 0.0 || m[7] != 0.0 || m[8] != 1.0 {
        return None;
    }
    let (x0, x1) = (m[2], m[0] * target.0 as f32 + m[2]);
    let (y0, y1) = (m[5], m[4] * target.1 as f32 + m[5]);
    Some([x0.min(x1), y0.min(y1), x0.max(x1), y0.max(y1)])
}

/// The target pixels a scene rectangle (left, top, right, bottom) touches,
/// clamped to the target, in the same form. Empty when right <= left or
/// bottom <= top. A transform that sends a corner behind the eye covers the
/// whole target.
pub(super) fn target_pixels(
    output_from_scene: &Matrix3,
    rect: [f64; 4],
    target: (u32, u32),
) -> [i32; 4] {
    let whole = [0, 0, target.0 as i32, target.1 as i32];
    let Some(bounds) = map_bounds(output_from_scene, rect) else {
        return whole;
    };
    let clamp = |value: f64, limit: i32| value.clamp(0.0, f64::from(limit)) as i32;
    [
        clamp(bounds[0].floor(), whole[2]),
        clamp(bounds[1].floor(), whole[3]),
        clamp(bounds[2].ceil(), whole[2]),
        clamp(bounds[3].ceil(), whole[3]),
    ]
}

/// The bounds of `rect` (left, top, right, bottom) mapped through `m`; None
/// when a corner lands behind the eye or at infinity.
pub(super) fn map_bounds(m: &Matrix3, rect: [f64; 4]) -> Option<[f64; 4]> {
    let m = m.0.map(f64::from);
    let mut bounds = [
        f64::INFINITY,
        f64::INFINITY,
        f64::NEG_INFINITY,
        f64::NEG_INFINITY,
    ];
    for (x, y) in [
        (rect[0], rect[1]),
        (rect[2], rect[1]),
        (rect[2], rect[3]),
        (rect[0], rect[3]),
    ] {
        let w = m[6] * x + m[7] * y + m[8];
        if !(w > 0.0) {
            return None;
        }
        let tx = (m[0] * x + m[1] * y + m[2]) / w;
        let ty = (m[3] * x + m[4] * y + m[5]) / w;
        bounds = [
            bounds[0].min(tx),
            bounds[1].min(ty),
            bounds[2].max(tx),
            bounds[3].max(ty),
        ];
    }
    bounds
        .iter()
        .all(|value| value.is_finite())
        .then_some(bounds)
}

/// Whether a pixel rectangle (left, top, right, bottom) holds no pixel.
pub(super) fn pixels_empty(rect: [i32; 4]) -> bool {
    rect[2] <= rect[0] || rect[3] <= rect[1]
}

/// Whether two pixel rectangles share a pixel.
pub(super) fn pixels_overlap(a: [i32; 4], b: [i32; 4]) -> bool {
    a[0] < b[2] && b[0] < a[2] && a[1] < b[3] && b[1] < a[3]
}

/// The smallest pixel rectangle holding both.
pub(super) fn pixels_union(a: [i32; 4], b: [i32; 4]) -> [i32; 4] {
    if pixels_empty(a) {
        return b;
    }
    if pixels_empty(b) {
        return a;
    }
    [
        a[0].min(b[0]),
        a[1].min(b[1]),
        a[2].max(b[2]),
        a[3].max(b[3]),
    ]
}

/// `radii` (upper-left, upper-right, lower-right, lower-left) scaled so no
/// two adjacent corners overlap, as Impeller's RoundingRadii::Scaled.
fn fitted_radii(rect: &Rect, radii: [[f32; 2]; 4]) -> [[f32; 2]; 4] {
    let mut radii = radii.map(|[x, y]| {
        // A flat or negative corner is square.
        if x > 0.0 && y > 0.0 {
            [x, y]
        } else {
            [0.0, 0.0]
        }
    });
    let [ul, ur, lr, ll] = radii;
    let (width, height) = (
        (rect.right - rect.left).abs(),
        (rect.bottom - rect.top).abs(),
    );
    let mut scale = 1.0f32;
    for (first, second, side) in [
        (ul[0], ur[0], width),
        (ll[0], lr[0], width),
        (ul[1], ll[1], height),
        (ur[1], lr[1], height),
    ] {
        if first + second > side {
            scale = scale.min(side / (first + second));
        }
    }
    if scale < 1.0 {
        for corner in &mut radii {
            *corner = corner.map(|value| value * scale);
        }
    }
    radii
}

fn clip_record(clip: &Clip) -> ClipRecord {
    let [m0, m1, m2] = rows(&clip.scene_to_clip);
    let [ul, ur, lr, ll] = fitted_radii(&clip.rect, clip.radii);
    ClipRecord {
        m0,
        m1,
        m2,
        rect: ltrb(&clip.rect),
        radii_top: [ul[0], ul[1], ur[0], ur[1]],
        radii_bottom: [lr[0], lr[1], ll[0], ll[1]],
        path: clip.path.map_or([0; 4], |path| {
            [path.first, path.count, u32::from(path.even_odd), 1]
        }),
    }
}

fn local_draw(
    local: &EntryLocal,
    clips: ClipSpan,
    ndc_from_scene: &Matrix3,
    quad: [f32; 4],
    kind: u32,
) -> Draw {
    Draw {
        ndc: rows(&ndc_from_scene.then(&local.scene_from_local)),
        scene: rows(&local.scene_from_local),
        quad,
        flags: [kind, clips.count, 0, 0],
        clip_first: clips.first,
        ..Draw::default()
    }
}

/// A client image drawn into its bounds (a texture cut).
pub(super) fn texture(
    local: &EntryLocal,
    clips: ClipSpan,
    ndc_from_scene: &Matrix3,
    placement: &Placement,
    image: (u32, u32),
) -> Option<Draw> {
    let mut draw = local_draw(
        local,
        clips,
        ndc_from_scene,
        ltrb(&placement.destination),
        KIND_TEXTURE,
    );
    (draw.uv_x, draw.uv_y) = placement.uv(image, &Matrix3::IDENTITY)?;
    draw.limits = if placement.strict {
        texel_limits(placement.source, (image.0 as f32, image.1 as f32), true)
    } else {
        [0.0, 0.0, 1.0, 1.0]
    };
    draw.params = [0.0, local.opacity, 1.0, 0.0];
    Some(draw)
}

/// One layer of a merged native window, drawn into the window's own
/// top-down image of `size` pixels: `quad` there, sampling the layer's
/// image at `uv` (one per quad corner: upper left, upper right, lower
/// left) clamped to `limits`, times `opacity`, as the GLES merge pass.
pub(super) fn merged_layer(
    size: (u32, u32),
    quad: [f32; 4],
    uv: [[f32; 2]; 3],
    limits: [f32; 4],
    opacity: f32,
) -> Option<Draw> {
    let [left, top, right, bottom] = quad;
    let (width, height) = (right - left, bottom - top);
    if !(width > 0.0 && height > 0.0) {
        return None;
    }
    // Affine in the layer: a quarter turn makes u follow y, so each
    // coordinate gets both slopes.
    let row = |axis: usize| {
        let along_x = (uv[1][axis] - uv[0][axis]) / width;
        let along_y = (uv[2][axis] - uv[0][axis]) / height;
        [
            along_x,
            along_y,
            uv[0][axis] - along_x * left - along_y * top,
            0.0,
        ]
    };
    // Top-down image: row y is memory row y.
    let (w, h) = (size.0 as f32, size.1 as f32);
    let ndc = Matrix3([2.0 / w, 0.0, -1.0, 0.0, 2.0 / h, -1.0, 0.0, 0.0, 1.0]);
    Some(Draw {
        ndc: rows(&ndc),
        scene: rows(&Matrix3::IDENTITY),
        quad,
        uv_x: row(0),
        uv_y: row(1),
        limits,
        params: [0.0, opacity, 1.0, 0.0],
        // Nothing past the buffer's edge (compose.frag).
        flags: [KIND_TEXTURE, 0, 1, 0],
        ..Draw::default()
    })
}

/// Premultiplied components of a non-premultiplied 0xAARRGGBB color.
fn premultiplied(argb: u32) -> [f32; 4] {
    let channel = |shift: u32| ((argb >> shift) & 0xff) as f32 / 255.0;
    let alpha = channel(24);
    [
        channel(16) * alpha,
        channel(8) * alpha,
        channel(0) * alpha,
        alpha,
    ]
}

/// A window without a backdrop: its frame and the client image the direct
/// window plan samples (Canvas's direct WindowSurfaceContents). `surface` is
/// None when the texture is gone; the frame is still drawn.
pub(super) fn window(
    local: &EntryLocal,
    clips: ClipSpan,
    ndc_from_scene: &Matrix3,
    style: &WindowStyle,
    texture_transform: &Matrix3,
    surface_opacity: f32,
    surface: Option<(&Placement, (u32, u32))>,
) -> Option<Draw> {
    let b = &style.bounds;
    // Window bounds expanded by one, as WindowSurfaceContents' geometry.
    let quad = [b.left - 1.0, b.top - 1.0, b.right + 1.0, b.bottom + 1.0];
    let mut draw = local_draw(local, clips, ndc_from_scene, quad, KIND_WINDOW);
    draw.window = ltrb(&style.bounds);
    draw.content = ltrb(&style.content_bounds);
    draw.frame = premultiplied(style.frame_color);
    draw.params = [style.radius, local.opacity, surface_opacity, 0.0];
    if let Some((placement, image)) = surface {
        let input_from_window = texture_transform.inverse()?;
        (draw.uv_x, draw.uv_y) = placement.uv(image, &input_from_window)?;
        let size = (image.0 as f32, image.1 as f32);
        draw.coverage = texel_limits(placement.source, size, false);
        draw.limits = texel_limits(placement.source, size, placement.strict);
        draw.flags[2] = 1;
    }
    Some(draw)
}

pub(super) const MODE_BLUR: u32 = 0;
pub(super) const MODE_GLASS: u32 = 1;

/// One material; std430 layout of `Glass` in `shaders/glass.glsl`. Lengths
/// are target pixels.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub(super) struct Glass {
    ndc: [[f32; 4]; 3],
    scene: [[f32; 4]; 3],
    quad: [f32; 4],
    shape: [f32; 4],
    radii: [f32; 4],
    frost: [f32; 4],
    frost_limits: [f32; 4],
    tint: [f32; 4],
    thickness: f32,
    refractive_index: f32,
    dispersion: f32,
    bevel_width_scale: f32,
    refraction_depth_scale: f32,
    light_angle: f32,
    light_intensity: f32,
    edge_strength: f32,
    rim_width: f32,
    rim_falloff: f32,
    opposite_light_strength: f32,
    saturation: f32,
    tint_strength: f32,
    brightness: f32,
    opacity: f32,
    mode: u32,
    clip_count: u32,
    /// Window materials: the target's height (fragment rows to target
    /// pixels), the client alpha the material needs, and whether `quad`
    /// holds material bounds (window-local) that confine it.
    target_height: f32,
    alpha_threshold: f32,
    has_material_bounds: u32,
    /// The first of the `clip_count` clips in the frame's clip buffer.
    clip_first: u32,
    _pad: [u32; 3],
}

const _: () = assert!(std::mem::size_of::<Glass>() == 288);

/// How a material's frost is made: `region` of the target is copied and
/// halved `halvings` times (each a 2x2 box), then blurred with `sigma`
/// texels of the result.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) struct FrostPlan {
    /// Target pixels: left, top, right, bottom.
    pub(super) region: [i32; 4],
    pub(super) halvings: u32,
    pub(super) sigma: [f32; 2],
}

impl FrostPlan {
    /// The frost of `source` (target pixels) blurred by `sigma` target
    /// pixels and sampled up to `reach` pixels beyond it, within a
    /// `target`-sized output. None when nothing of it is inside the output.
    ///
    /// An `exact` frost covers `source` only, clamped at its edges, as a
    /// window's backdrop: the scene beyond the window is not its input.
    fn new(
        source: [f32; 4],
        sigma: [f32; 2],
        reach: [f32; 2],
        exact: bool,
        target: (u32, u32),
    ) -> Option<Self> {
        // Blur at the smallest power-of-two scale that keeps at least two
        // texels per standard deviation, at most 1/8 (sigma 6 at 1/2, 10 at
        // 1/4, 18 at 1/8).
        let finest = match (sigma[0] > 0.0, sigma[1] > 0.0) {
            (true, true) => sigma[0].min(sigma[1]),
            (false, false) => 0.0,
            _ => sigma[0].max(sigma[1]),
        };
        let mut halvings = 0;
        while halvings < 3 && finest / f32::from(2u8 << halvings) >= 2.0 {
            halvings += 1;
        }
        // Three standard deviations carry 99.7% of the kernel; two more
        // pixels cover the antialiased edge, as the engine's input bounds.
        // The region starts on the halvings' grid, so a moving material
        // samples the same texels and does not shimmer.
        let margin = |axis: usize| {
            if exact {
                0.0
            } else {
                (3.0 * sigma[axis] + reach[axis]).ceil() + 2.0
            }
        };
        let cell = if exact { 1 } else { 1i32 << halvings };
        let down = |value: f32| (value.floor() as i32).div_euclid(cell) * cell;
        let up = |value: f32| -(-(value.ceil() as i32)).div_euclid(cell) * cell;
        let region = [
            down(source[0] - margin(0)).max(0),
            down(source[1] - margin(1)).max(0),
            up(source[2] + margin(0)).min(target.0 as i32),
            up(source[3] + margin(1)).min(target.1 as i32),
        ];
        if region[2] <= region[0] || region[3] <= region[1] {
            return None;
        }
        let mut plan = Self {
            region,
            halvings,
            sigma: [0.0; 2],
        };
        let (width, height) = plan.region_size();
        let (last_width, last_height) = plan.level_size(plan.levels() - 1);
        plan.sigma = [
            sigma[0] * last_width as f32 / width as f32,
            sigma[1] * last_height as f32 / height as f32,
        ];
        Some(plan)
    }

    pub(super) fn region_size(&self) -> (u32, u32) {
        (
            (self.region[2] - self.region[0]) as u32,
            (self.region[3] - self.region[1]) as u32,
        )
    }

    /// Mip levels of the frost tile; the last one is blurred and sampled.
    /// A tile too small to halve that often stops at one texel.
    pub(super) fn levels(&self) -> u32 {
        let (width, height) = self.base_size();
        self.halvings.max(1).min(width.max(height).ilog2() + 1)
    }

    /// Level 0 is the region halved once (or as is, without halvings);
    /// further levels are sized as Vulkan sizes mips: halved, rounded down.
    pub(super) fn level_size(&self, level: u32) -> (u32, u32) {
        let (width, height) = self.base_size();
        ((width >> level).max(1), (height >> level).max(1))
    }

    fn base_size(&self) -> (u32, u32) {
        let (width, height) = self.region_size();
        if self.halvings == 0 {
            (width, height)
        } else {
            (width.div_ceil(2), height.div_ceil(2))
        }
    }
}

/// How far refraction can move a sample, target pixels: the engine's
/// MaximumGlassDisplacement for a `thickness`-pixel surface.
fn maximum_displacement(glass: &denial_flutter_engine::scene::Glass, thickness: f32) -> f32 {
    let index = 1.0 + glass.refraction * 0.2;
    let depth = if glass.bevel_width_scale == 1.0 {
        8.0
    } else {
        9.0
    };
    thickness
        * depth
        * glass.refraction_depth_scale
        * (index * index - 1.0).max(0.0).sqrt()
        * (1.0 + glass.dispersion * 0.5)
}

fn straight(argb: u32) -> [f32; 4] {
    let channel = |shift: u32| ((argb >> shift) & 0xff) as f32 / 255.0;
    [channel(16), channel(8), channel(0), channel(24)]
}

fn intersect(a: [f32; 4], b: [f32; 4]) -> Option<[f32; 4]> {
    let rect = [
        a[0].max(b[0]),
        a[1].max(b[1]),
        a[2].min(b[2]),
        a[3].min(b[3]),
    ];
    (rect[2] > rect[0] && rect[3] > rect[1]).then_some(rect)
}

/// A transform that keeps rectangles axis-aligned: scale and translation,
/// with a flip or a quarter turn (a bottom-up or rotated output).
struct Axial {
    m: [f32; 9],
    /// Local x runs along target y.
    swap: bool,
    /// Target pixels per local unit along local x and y.
    sx: f32,
    sy: f32,
}

impl Axial {
    fn new(m: &Matrix3) -> Option<Self> {
        let m = m.0;
        if m[6] != 0.0 || m[7] != 0.0 || m[8] != 1.0 {
            return None;
        }
        let swap = if m[1] == 0.0 && m[3] == 0.0 {
            false
        } else if m[0] == 0.0 && m[4] == 0.0 {
            true
        } else {
            return None;
        };
        let sx = m[0].hypot(m[3]);
        let sy = m[1].hypot(m[4]);
        (sx > 0.0 && sy > 0.0).then_some(Self { m, swap, sx, sy })
    }

    fn point(&self, x: f32, y: f32) -> [f32; 2] {
        let m = &self.m;
        [m[0] * x + m[1] * y + m[2], m[3] * x + m[4] * y + m[5]]
    }

    /// `rect`'s target pixels: left, top, right, bottom.
    fn map(&self, rect: &Rect) -> [f32; 4] {
        let a = self.point(rect.left, rect.top);
        let b = self.point(rect.right, rect.bottom);
        [
            a[0].min(b[0]),
            a[1].min(b[1]),
            a[0].max(b[0]),
            a[1].max(b[1]),
        ]
    }

    /// Local lengths along local x and y as target lengths along target x
    /// and y.
    fn target_lengths(&self, [x, y]: [f32; 2]) -> [f32; 2] {
        let (x, y) = (x * self.sx, y * self.sy);
        if self.swap { [y, x] } else { [x, y] }
    }

    /// Corner radii (x, y) of local `shape` (upper left, upper right, lower
    /// right, lower left) as target pixels at the target corners they land
    /// on, in the same order; `target` is the mapped shape.
    fn corner_radii(&self, shape: &Rect, radii: &[[f32; 2]; 4], target: [f32; 4]) -> [f32; 4] {
        let corners = [
            (shape.left, shape.top),
            (shape.right, shape.top),
            (shape.right, shape.bottom),
            (shape.left, shape.bottom),
        ];
        let centre = [(target[0] + target[2]) * 0.5, (target[1] + target[3]) * 0.5];
        let mut out = [0.0; 4];
        for ((x, y), [rx, ry]) in corners.into_iter().zip(radii) {
            let [px, py] = self.point(x, y);
            let slot = match (py < centre[1], px < centre[0]) {
                (true, true) => 0,
                (true, false) => 1,
                (false, false) => 2,
                (false, true) => 3,
            };
            out[slot] = (rx * self.sx).min(ry * self.sy);
        }
        out
    }
}

/// A material as the composer draws it.
pub(super) struct MaterialDraw {
    pub(super) glass: Glass,
    pub(super) plan: FrostPlan,
    /// Whether the frost covers no more than the engine reads back for the
    /// material, so its backdrop token says when the frost is stale. A
    /// clipped or cropped material refracts and blurs from beyond what the
    /// engine tracks.
    pub(super) tracked: bool,
    /// Target pixels its draw can change (left, top, right, bottom): what
    /// changes when its frost is made again.
    pub(super) output: [i32; 4],
}

/// A material's record and frost plan. Err when the composer cannot draw it
/// (a transform other than scale and translation, or one that mirrors x);
/// Ok(None) when nothing of it is visible. A target that flips y (an output
/// buffer, bottom-up) keeps the glass upright: corners and light follow the
/// flip, lengths use its magnitude.
pub(super) fn material(
    material: &Material,
    local: &EntryLocal,
    clips: ClipSpan,
    output_from_scene: &Matrix3,
    target: (u32, u32),
) -> Result<Option<MaterialDraw>, &'static str> {
    material_over(material, local, clips, output_from_scene, target, false)
}

/// The material behind a window: its frost covers the material's bounds
/// only, as Impeller clamps a window backdrop's input to the window. The
/// window draw (window_glass.frag) applies the clips and opacity.
pub(super) fn window_material(
    material: &Material,
    material_bounds: Option<&Rect>,
    local: &EntryLocal,
    clips: ClipSpan,
    output_from_scene: &Matrix3,
    target: (u32, u32),
) -> Result<Option<MaterialDraw>, &'static str> {
    let Some(mut draw) = material_over(material, local, clips, output_from_scene, target, true)?
    else {
        return Ok(None);
    };
    let glass = &mut draw.glass;
    glass.quad = material_bounds.map_or([0.0; 4], ltrb);
    glass.has_material_bounds = u32::from(material_bounds.is_some());
    glass.alpha_threshold = material.alpha_threshold;
    glass.target_height = target.1 as f32;
    glass.opacity = 1.0;
    glass.clip_count = 0;
    Ok(Some(draw))
}

fn material_over(
    material: &Material,
    local: &EntryLocal,
    clips: ClipSpan,
    output_from_scene: &Matrix3,
    target: (u32, u32),
    window: bool,
) -> Result<Option<MaterialDraw>, &'static str> {
    let target_from_local = output_from_scene.then(&local.scene_from_local);
    let axial = Axial::new(&target_from_local).ok_or("material transform")?;
    let (sx, sy) = (axial.sx, axial.sy);
    let map = |rect: &Rect| axial.map(rect);
    let scene_from_target = output_from_scene.inverse().ok_or("output transform")?;
    let ndc_from_target = ndc_from_target(target.0, target.1);
    let screen = [0.0, 0.0, target.0 as f32, target.1 as f32];
    let whole = map(&material.bounds);
    let Some(bounds) = intersect(whole, screen) else {
        return Ok(None);
    };
    let mut record = Glass {
        ndc: rows(&ndc_from_target),
        scene: rows(&scene_from_target),
        opacity: local.opacity,
        clip_count: clips.count,
        clip_first: clips.first,
        mode: MODE_BLUR,
        ..Glass::default()
    };
    // Refraction looks inward across the whole surface, so glass frosts its
    // full shape even where a clip hides part of it.
    // The frost covers `source`, plus `reach` where refraction looks
    // farther than the shape's own half extent.
    let (quad, source, reach) = match &material.glass {
        None => (bounds, bounds, [0.0; 2]),
        Some(glass) => {
            let shape = map(&glass.shape);
            let Some(quad) = intersect(shape, bounds) else {
                return Ok(None);
            };
            let (width, height) = (shape[2] - shape[0], shape[3] - shape[1]);
            let half_extent = width.min(height) * 0.5;
            // Physical sizes, as GlassFilterContents resolves them.
            let thickness = (glass.thickness * (sx + sy) * 0.5).min(half_extent);
            record.mode = MODE_GLASS;
            record.shape = shape;
            record.radii = axial.corner_radii(&glass.shape, &glass.radii, shape);
            record.tint = straight(glass.tint);
            record.thickness = thickness;
            record.refractive_index = 1.0 + glass.refraction.clamp(0.0, 1.0) * 0.2;
            record.dispersion = glass.dispersion;
            record.bevel_width_scale = glass
                .bevel_width_scale
                .min(half_extent / thickness.max(0.0001));
            record.refraction_depth_scale = glass.refraction_depth_scale;
            // The light stays in target pixels, as Impeller keeps it: on a
            // flipped or rotated output GLES lights the same target edge,
            // and so does this.
            record.light_angle = glass.light_angle;
            record.light_intensity = glass.light_intensity;
            record.edge_strength = glass.edge_strength;
            record.rim_width = glass.rim_width;
            record.rim_falloff = glass.rim_falloff;
            record.opposite_light_strength = glass.opposite_light_strength;
            record.saturation = glass.saturation;
            record.tint_strength = glass.tint_strength;
            record.brightness = glass.brightness;
            // Refraction moves samples inward, at most `ray` from where they
            // start: past the opposite edge only when the shape is thinner
            // than that (DlGlassImageFilter's inward input bounds).
            let ray = maximum_displacement(glass, thickness) * 9.0 / 8.0;
            let reach = [(ray - width * 0.5).max(0.0), (ray - height * 0.5).max(0.0)];
            // A window's frost is its bounds' scene.
            (quad, if window { bounds } else { shape }, reach)
        }
    };
    // Only an exact window frost reads no more than the engine's input
    // (its content bounds): a blur's region adds padding and rounds out to
    // its halving grid.
    let tracked = window && clips.is_empty() && bounds == whole;
    record.quad = quad;
    let sigma = axial.target_lengths(material.sigma);
    let Some(plan) = FrostPlan::new(source, sigma, reach, window, target) else {
        return Ok(None);
    };
    let [l, t, r, b] = plan.region.map(|value| value as f32);
    record.frost = [l, t, r, b];
    let (width, height) = plan.level_size(plan.levels() - 1);
    let (hx, hy) = (0.5 / width as f32, 0.5 / height as f32);
    record.frost_limits = [hx, hy, 1.0 - hx, 1.0 - hy];
    // A window draws over its bounds (its quad may be window-local material
    // bounds); a blur or glass within its quad, antialiased.
    let drawn = if window { bounds } else { quad };
    let output = [
        (drawn[0].floor() as i32 - 1).max(0),
        (drawn[1].floor() as i32 - 1).max(0),
        (drawn[2].ceil() as i32 + 1).min(target.0 as i32),
        (drawn[3].ceil() as i32 + 1).min(target.1 as i32),
    ];
    Ok(Some(MaterialDraw {
        glass: record,
        plan,
        tracked,
        output,
    }))
}

#[cfg(test)]
pub(super) mod tests {
    use super::*;

    #[test]
    fn consecutive_equal_clips_share_one_run() {
        let clip = |left: f32| Clip {
            scene_to_clip: Matrix3::IDENTITY,
            rect: Rect {
                left,
                top: 0.0,
                right: 10.0,
                bottom: 10.0,
            },
            radii: [[2.0; 2]; 4],
            path: None,
        };
        let mut records = Vec::new();
        assert_eq!(
            intern_clips(&[], ClipSpan::default(), &mut records),
            ClipSpan::default()
        );
        let a = intern_clips(&[clip(0.0), clip(1.0)], ClipSpan::default(), &mut records);
        assert_eq!(a, ClipSpan { first: 0, count: 2 });
        assert_eq!(intern_clips(&[clip(0.0), clip(1.0)], a, &mut records), a);
        assert_eq!(records.len(), 2);
        let b = intern_clips(&[clip(0.0)], a, &mut records);
        assert_eq!((b, records.len()), (ClipSpan { first: 2, count: 1 }, 3));
        let c = intern_clips(&[clip(5.0)], b, &mut records);
        assert_eq!((c, records.len()), (ClipSpan { first: 3, count: 1 }, 4));
    }

    fn apply(m: &Matrix3, x: f32, y: f32) -> (f32, f32) {
        let m = &m.0;
        let w = m[6] * x + m[7] * y + m[8];
        (
            (m[0] * x + m[1] * y + m[2]) / w,
            (m[3] * x + m[4] * y + m[5]) / w,
        )
    }

    fn uv(draw: &Draw, x: f32, y: f32) -> (f32, f32) {
        (
            draw.uv_x[0] * x + draw.uv_x[1] * y + draw.uv_x[2],
            draw.uv_y[0] * x + draw.uv_y[1] * y + draw.uv_y[2],
        )
    }

    #[test]
    fn target_top_is_the_first_memory_row() {
        let ndc = ndc_from_target(100, 50);
        // Target y = H is memory row 0, Vulkan's top (y' = -1).
        assert_eq!(apply(&ndc, 0.0, 50.0), (-1.0, -1.0));
        assert_eq!(apply(&ndc, 100.0, 0.0), (1.0, 1.0));
    }

    #[test]
    fn bottom_up_slice_maps_rows_upside_down() {
        let blit = SliceBlit {
            source: [0.0, 0.0, 10.0, 4.0],
            destination: [20.0, 30.0, 30.0, 34.0],
        };
        let draw = slice_blit(&blit, (64, 64), true, &ndc_from_target(100, 100));
        // Target row 30 (slice row 0) sits at storage memory row 64 - 0.
        let (u, v) = uv(&draw, 20.0, 30.0);
        assert!((u - 0.0).abs() < 1e-6 && (v - 1.0).abs() < 1e-6);
        let (_, v) = uv(&draw, 20.0, 34.0);
        assert!((v - 60.0 / 64.0).abs() < 1e-6);
        // Strict limits: half a texel inside rows 60..64.
        assert!((draw.limits[1] - 60.5 / 64.0).abs() < 1e-6);
        assert!((draw.limits[3] - 63.5 / 64.0).abs() < 1e-6);
    }

    #[test]
    fn top_down_slice_keeps_row_order() {
        let blit = SliceBlit {
            source: [5.0, 2.0, 15.0, 6.0],
            destination: [20.0, 30.0, 30.0, 34.0],
        };
        let draw = slice_blit(&blit, (64, 32), false, &ndc_from_target(100, 100));
        let (u, v) = uv(&draw, 20.0, 30.0);
        assert!((u - 5.0 / 64.0).abs() < 1e-6 && (v - 2.0 / 32.0).abs() < 1e-6);
    }

    #[test]
    fn crop_presentation_projects_into_bounds() {
        let presentation = denial_flutter_engine::ExternalTexturePresentation {
            struct_size: 0,
            width: 200.0,
            height: 100.0,
            source: [10.0, 0.0, 100.0, 50.0],
            destination: [0.0, 0.0, 200.0, 100.0],
            background: [0.0; 4],
            background_argb: 0,
        };
        let bounds = Rect {
            left: 0.0,
            top: 0.0,
            right: 400.0,
            bottom: 200.0,
        };
        let placement = Placement::new(bounds, (128, 64), Some(&presentation)).unwrap();
        assert!(placement.strict);
        assert_eq!(placement.destination, bounds);
        let with_strip = denial_flutter_engine::ExternalTexturePresentation {
            background: [0.0, 0.0, 10.0, 10.0],
            ..presentation
        };
        assert!(Placement::new(bounds, (128, 64), Some(&with_strip)).is_none());
    }

    #[test]
    fn window_samples_through_the_inverse_texture_transform() {
        let local = EntryLocal {
            scene_from_local: Matrix3::IDENTITY,
            opacity: 1.0,
            clips: 0..0,
            sampling: denial_flutter_engine::scene::Sampling::Linear,
            freeze: false,
        };
        let style = WindowStyle {
            bounds: Rect {
                left: 0.0,
                top: 0.0,
                right: 100.0,
                bottom: 100.0,
            },
            content_bounds: Rect {
                left: 0.0,
                top: 0.0,
                right: 100.0,
                bottom: 100.0,
            },
            material_bounds: None,
            radius: 8.0,
            frame_color: 0x80ff0000,
            direct_texture: true,
        };
        // The texture is drawn at half scale, offset by 10.
        let transform = Matrix3([0.5, 0.0, 10.0, 0.0, 0.5, 10.0, 0.0, 0.0, 1.0]);
        let placement = Placement {
            source: [0.0, 0.0, 200.0, 200.0],
            destination: Rect {
                left: 0.0,
                top: 0.0,
                right: 200.0,
                bottom: 200.0,
            },
            strict: false,
        };
        let draw = window(
            &local,
            ClipSpan::default(),
            &Matrix3::IDENTITY,
            &style,
            &transform,
            1.0,
            Some((&placement, (200, 200))),
        )
        .unwrap();
        // Window (10, 10) is texture-local (0, 0); window (60, 60) its middle.
        let (u, v) = uv(&draw, 10.0, 10.0);
        assert!(u.abs() < 1e-6 && v.abs() < 1e-6);
        let (u, v) = uv(&draw, 60.0, 60.0);
        assert!((u - 0.5).abs() < 1e-6 && (v - 0.5).abs() < 1e-6);
        assert_eq!(draw.frame[3], 128.0 / 255.0);
        assert!((draw.frame[0] - 128.0 / 255.0).abs() < 1e-6);
    }

    pub(in crate::flutter_runtime) fn glass_material(
        shape: [f32; 4],
        radii: [[f32; 2]; 4],
    ) -> Material {
        let rect = Rect {
            left: shape[0],
            top: shape[1],
            right: shape[2],
            bottom: shape[3],
        };
        Material {
            glass: Some(denial_flutter_engine::scene::Glass {
                shape: rect,
                radii,
                thickness: 10.0,
                refraction: 0.0,
                dispersion: 0.0,
                saturation: 1.0,
                tint: 0xff00_0000,
                tint_strength: 1.0,
                brightness: 0.0,
                light_angle: 0.5,
                light_intensity: 0.0,
                edge_strength: 0.0,
                bevel_width_scale: 1.0,
                refraction_depth_scale: 1.0,
                rim_width: 1.0,
                rim_falloff: 1.0,
                opposite_light_strength: 0.0,
            }),
            sigma: [6.0; 2],
            blend_mode: denial_flutter_engine::scene::BLEND_SRC_OVER,
            bounds: rect,
            content_clip: None,
            backdrop_token: Some(1),
            alpha_threshold: 0.0,
        }
    }

    pub(in crate::flutter_runtime) fn plain_local() -> EntryLocal {
        EntryLocal {
            scene_from_local: Matrix3::IDENTITY,
            opacity: 1.0,
            clips: 0..0,
            sampling: denial_flutter_engine::scene::Sampling::Linear,
            freeze: false,
        }
    }

    /// The output buffer's root flip: target y = height - scene y.
    pub(in crate::flutter_runtime) fn flip(height: u32) -> Matrix3 {
        Matrix3([1.0, 0.0, 0.0, 0.0, -1.0, height as f32, 0.0, 0.0, 1.0])
    }

    #[test]
    fn flipped_glass_keeps_its_corners_and_light() {
        let radii = [[30.0; 2], [20.0; 2], [10.0; 2], [0.0; 2]];
        let material = glass_material([40.0, 20.0, 216.0, 108.0], radii);
        let upright = super::material(
            &material,
            &plain_local(),
            ClipSpan::default(),
            &Matrix3::IDENTITY,
            (256, 128),
        )
        .unwrap()
        .unwrap();
        let flipped = super::material(
            &material,
            &plain_local(),
            ClipSpan::default(),
            &flip(128),
            (256, 128),
        )
        .unwrap()
        .unwrap();
        assert_eq!(upright.glass.shape, [40.0, 20.0, 216.0, 108.0]);
        assert_eq!(flipped.glass.shape, [40.0, 20.0, 216.0, 108.0]);
        assert_eq!(upright.glass.radii, [30.0, 20.0, 10.0, 0.0]);
        // Target rows run bottom-up: the scene's lower corners come first.
        assert_eq!(flipped.glass.radii, [0.0, 10.0, 20.0, 30.0]);
        assert_eq!(flipped.glass.light_angle, 0.5);
        assert_eq!(flipped.glass.thickness, upright.glass.thickness);
        assert_eq!(flipped.plan.sigma, upright.plan.sigma);
        // A blur's frost reads past what the engine tracks.
        assert!(!upright.tracked && !flipped.tracked);
    }

    #[test]
    fn strong_refraction_widens_a_thin_bars_frost() {
        let mut material = glass_material([0.0, 40.0, 256.0, 80.0], [[0.0; 2]; 4]);
        let glass = material.glass.as_mut().unwrap();
        glass.thickness = 20.0;
        glass.refraction = 1.0;
        material.sigma = [0.0; 2];
        let draw = super::material(
            &material,
            &plain_local(),
            ClipSpan::default(),
            &Matrix3::IDENTITY,
            (256, 128),
        )
        .unwrap()
        .unwrap();
        // 20 * 8 * sqrt(1.2² - 1) * 9/8 ≈ 119 px of ray against a 20 px half
        // height: about 99 px more above and below, within the target.
        assert_eq!(draw.plan.region[1], 0);
        assert_eq!(draw.plan.region[3], 128);
        assert!(!draw.tracked);
    }

    #[test]
    fn quarter_turn_moves_corners_and_swaps_blur_axes() {
        let radii = [[30.0; 2], [20.0; 2], [10.0; 2], [0.0; 2]];
        let mut material = glass_material([40.0, 20.0, 216.0, 108.0], radii);
        material.sigma = [6.0, 12.0];
        // A 90° clockwise output: scene (x, y) lands on target (H - y, x).
        let turn = Matrix3([0.0, -1.0, 128.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0]);
        let draw = super::material(
            &material,
            &plain_local(),
            ClipSpan::default(),
            &turn,
            (128, 256),
        )
        .unwrap()
        .unwrap();
        assert_eq!(draw.glass.shape, [20.0, 40.0, 108.0, 216.0]);
        // Scene upper left lands at target upper right, and so on.
        assert_eq!(draw.glass.radii, [0.0, 30.0, 20.0, 10.0]);
        let upright = super::material(
            &material,
            &plain_local(),
            ClipSpan::default(),
            &Matrix3::IDENTITY,
            (256, 128),
        )
        .unwrap()
        .unwrap();
        assert_eq!(
            draw.plan.sigma,
            [upright.plan.sigma[1], upright.plan.sigma[0]]
        );
    }

    #[test]
    fn skew_is_declined() {
        let material = glass_material([40.0, 20.0, 216.0, 108.0], [[0.0; 2]; 4]);
        let skew = Matrix3([1.0, 0.5, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]);
        assert!(
            super::material(
                &material,
                &plain_local(),
                ClipSpan::default(),
                &skew,
                (256, 128)
            )
            .is_err()
        );
    }

    #[test]
    fn cropped_glass_is_untracked() {
        let mut material = glass_material([40.0, 20.0, 216.0, 108.0], [[0.0; 2]; 4]);
        material.bounds.right = 100.0;
        let draw = super::material(
            &material,
            &plain_local(),
            ClipSpan::default(),
            &Matrix3::IDENTITY,
            (256, 128),
        )
        .unwrap()
        .unwrap();
        assert!(!draw.tracked);
        assert_eq!(draw.glass.quad, [40.0, 20.0, 100.0, 108.0]);
        // Partly off screen counts as cropped too.
        let material = glass_material([200.0, 20.0, 300.0, 108.0], [[0.0; 2]; 4]);
        let draw = super::material(
            &material,
            &plain_local(),
            ClipSpan::default(),
            &Matrix3::IDENTITY,
            (256, 128),
        )
        .unwrap()
        .unwrap();
        assert!(!draw.tracked);
    }

    #[test]
    fn frost_mips_are_sized_as_vulkan_sizes_them() {
        let plan = FrostPlan {
            region: [0, 0, 1366, 9],
            halvings: 3,
            sigma: [0.0; 2],
        };
        assert_eq!(plan.levels(), 3);
        assert_eq!(plan.level_size(0), (683, 5));
        assert_eq!(plan.level_size(1), (341, 2));
        assert_eq!(plan.level_size(2), (170, 1));
        // Too small to halve three times: one texel is the last level.
        let tiny = FrostPlan {
            region: [0, 0, 4, 2],
            halvings: 3,
            sigma: [0.0; 2],
        };
        assert_eq!(tiny.levels(), 2);
        assert_eq!(tiny.level_size(1), (1, 1));
        let plain = FrostPlan {
            region: [0, 0, 7, 3],
            halvings: 0,
            sigma: [0.0; 2],
        };
        assert_eq!((plain.levels(), plain.level_size(0)), (1, (7, 3)));
    }

    #[test]
    fn radii_fit_as_impeller_scales_them() {
        let rect = Rect {
            left: 0.0,
            top: 0.0,
            right: 300.0,
            bottom: 40.0,
        };
        // A pill asked for with a huge radius: every corner becomes 20.
        let pill = fitted_radii(&rect, [[999.0; 2]; 4]);
        for corner in pill {
            assert!((corner[0] - 20.0).abs() < 1e-3 && (corner[1] - 20.0).abs() < 1e-3);
        }
        // Radii that fit are kept, uneven ones included.
        let uneven = [[70.0, 10.0], [10.0, 10.0], [0.0, 0.0], [5.0, 5.0]];
        assert_eq!(fitted_radii(&rect, uneven), uneven);
    }
}
