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

    /// Target pixels of `rect` (the draw's local frame), as the corners
    /// the vertex shader places; None when the draw projects them.
    fn target_rect(&self, rect: [f32; 4], (width, height): (u32, u32)) -> Option<[f32; 4]> {
        let [x, y, w] = self.ndc;
        if w[0] != 0.0 || w[1] != 0.0 || w[2] <= 0.0 {
            return None;
        }
        let corner = |cx: f32, cy: f32| {
            let ndc = |row: [f32; 4]| (row[0] * cx + row[1] * cy + row[2]) / w[2];
            (
                (ndc(x) + 1.0) * width as f32 * 0.5,
                (1.0 - ndc(y)) * height as f32 * 0.5,
            )
        };
        let (x0, y0) = corner(rect[0], rect[1]);
        let (x1, y1) = corner(rect[2], rect[3]);
        Some([x0.min(x1), y0.min(y1), x0.max(x1), y0.max(y1)])
    }

    /// Target pixels the draw can change, rounded out; the whole target
    /// when it projects its quad.
    pub(super) fn bounds(&self, size: (u32, u32)) -> [i32; 4] {
        const SLACK: f32 = 1e-3;
        match self.target_rect(self.quad, size) {
            Some([l, t, r, b]) => [
                (l + SLACK).floor() as i32,
                (t + SLACK).floor() as i32,
                (r - SLACK).ceil() as i32,
                (b - SLACK).ceil() as i32,
            ],
            None => [i32::MIN, i32::MIN, i32::MAX, i32::MAX],
        }
    }

    /// Whole target pixels `rect` (local) covers when the draw maps it
    /// without rotation or projection.
    fn covered(&self, rect: [f32; 4], size: (u32, u32)) -> Option<[i32; 4]> {
        const SLACK: f32 = 1e-3;
        let [x, y, _] = self.ndc;
        let aligned = (x[1] == 0.0 && y[0] == 0.0) || (x[0] == 0.0 && y[1] == 0.0);
        if !aligned {
            return None;
        }
        let [l, t, r, b] = self.target_rect(rect, size)?;
        let covered = [
            (l - SLACK).ceil() as i32,
            (t - SLACK).ceil() as i32,
            (r + SLACK).floor() as i32,
            (b + SLACK).floor() as i32,
        ];
        (!pixels_empty(covered)).then_some(covered)
    }

    /// Target pixels this draw paints opaque, for a client image whose
    /// alpha is one: a texture or window drawn whole, without clips.
    /// `surface` is where a window's client lies in its local frame. A
    /// window's rounded corners leave two rectangles. Its antialiased edges
    /// cover a pixel whole once its centre is half a pixel inside
    /// (`edge` in clip_coverage.glsl), so whole pixels inside are covered.
    pub(super) fn opaque(
        &self,
        surface: Option<[f32; 4]>,
        size: (u32, u32),
    ) -> [Option<[i32; 4]>; 2] {
        let whole = self.flags[1] == 0 && self.params[1] == 1.0;
        match self.flags[0] {
            KIND_TEXTURE if whole && self.flags[2] == 0 => [self.covered(self.quad, size), None],
            KIND_WINDOW if whole && self.params[2] == 1.0 && self.flags[2] == 1 => {
                let Some(surface) = surface else {
                    return [None, None];
                };
                let [l, t, r, b] = [self.window, self.content, surface].into_iter().fold(
                    [f32::MIN, f32::MIN, f32::MAX, f32::MAX],
                    |a, b| {
                        [
                            a[0].max(b[0]),
                            a[1].max(b[1]),
                            a[2].min(b[2]),
                            a[3].min(b[3]),
                        ]
                    },
                );
                let radius = self.params[0].max(0.0);
                if radius == 0.0 {
                    return [self.covered([l, t, r, b], size), None];
                }
                [
                    self.covered([l + radius, t, r - radius, b], size),
                    self.covered([l, t + radius, r, b - radius], size),
                ]
            }
            _ => [None, None],
        }
    }

    /// Diagnostic: why the draw makes no cover over the target, in the
    /// order `opaque` checks; None when it covers.
    pub(super) fn why_no_cover(
        &self,
        opaque_client: bool,
        surface: Option<[f32; 4]>,
        size: (u32, u32),
    ) -> Option<&'static str> {
        if !opaque_client {
            return Some("client image has alpha and no opaque region, or is not imported");
        }
        if self.flags[1] != 0 {
            return Some("clipped");
        }
        if self.params[1] != 1.0 {
            return Some("drawn with opacity");
        }
        match self.flags[0] {
            KIND_TEXTURE if self.flags[2] != 0 => return Some("merged layer"),
            KIND_TEXTURE => {}
            KIND_WINDOW if self.params[2] != 1.0 => return Some("surface opacity"),
            KIND_WINDOW if self.flags[2] != 1 => return Some("window without surface"),
            KIND_WINDOW if surface.is_none() => return Some("surface turned or projected"),
            KIND_WINDOW => {}
            _ => return Some("slice"),
        }
        let whole = [0, 0, size.0 as i32, size.1 as i32];
        match self.opaque(surface, size) {
            [None, None] => Some("turned or projected"),
            covers if covers.iter().flatten().any(|&c| pixels_contain(c, whole)) => None,
            _ => Some("opaque part short of the target"),
        }
    }

    /// Draws nothing: a quad without area.
    pub(super) fn hide(&mut self) {
        self.quad = [0.0; 4];
    }

    /// Whether `hide` left it out.
    pub(super) fn hidden(&self) -> bool {
        self.quad == [0.0; 4]
    }

    /// The slice or client texture's quad in target pixels, when it maps
    /// onto the target by scale and translation alone; None for windows and
    /// turned or projected draws.
    pub(super) fn flat_rect(&self, size: (u32, u32)) -> Option<[f32; 4]> {
        let [x, y, _] = self.ndc;
        let flat = self.flags[0] != KIND_WINDOW
            && !self.hidden()
            && x[1] == 0.0
            && y[0] == 0.0
            && x[0] != 0.0
            && y[1] != 0.0;
        flat.then(|| self.target_rect(self.quad, size)).flatten()
    }

    /// This draw limited to `rect`, target pixels within `flat_rect`: the
    /// same pixels there, nothing elsewhere. Every per-pixel value follows
    /// the local position, so pieces of one draw sharing an edge meet
    /// exactly.
    pub(super) fn piece(&self, rect: [f32; 4], (width, height): (u32, u32)) -> Self {
        let [x, y, w] = self.ndc;
        let local_x = |px: f32| ((px / width as f32 * 2.0 - 1.0) * w[2] - x[2]) / x[0];
        let local_y = |py: f32| ((1.0 - py / height as f32 * 2.0) * w[2] - y[2]) / y[1];
        let (x0, x1) = (local_x(rect[0]), local_x(rect[2]));
        let (y0, y1) = (local_y(rect[1]), local_y(rect[3]));
        let mut piece = *self;
        piece.quad = [x0.min(x1), y0.min(y1), x0.max(x1), y0.max(y1)];
        piece
    }
}

/// Where a window's client lies in the window's local frame: its
/// placement through `texture_transform`, when that keeps it a rectangle.
pub(super) fn window_surface(
    texture_transform: &Matrix3,
    placement: &Placement,
) -> Option<[f32; 4]> {
    let [a, b, c, d, e, f, g, h, i] = texture_transform.0;
    let aligned = (b == 0.0 && d == 0.0) || (a == 0.0 && e == 0.0);
    if g != 0.0 || h != 0.0 || i <= 0.0 || !aligned {
        return None;
    }
    let map = |x: f32, y: f32| ((a * x + b * y + c) / i, (d * x + e * y + f) / i);
    let rect = &placement.destination;
    let (x0, y0) = map(rect.left, rect.top);
    let (x1, y1) = map(rect.right, rect.bottom);
    Some([x0.min(x1), y0.min(y1), x0.max(x1), y0.max(y1)])
}

/// What of `rect` lies outside `hole`: up to four rectangles.
pub(super) fn rect_subtract(rect: [f32; 4], hole: [f32; 4], out: &mut Vec<[f32; 4]>) {
    let [l, t, r, b] = rect;
    if hole[0] >= r || hole[2] <= l || hole[1] >= b || hole[3] <= t {
        out.push(rect);
        return;
    }
    if hole[1] > t {
        out.push([l, t, r, hole[1]]);
    }
    if hole[3] < b {
        out.push([l, hole[3], r, b]);
    }
    let (top, bottom) = (t.max(hole[1]), b.min(hole[3]));
    if hole[0] > l {
        out.push([l, top, hole[0], bottom]);
    }
    if hole[2] < r {
        out.push([hole[2], top, r, bottom]);
    }
}

/// The pixels both hold; empty when they share none.
pub(super) fn pixels_intersect(a: [i32; 4], b: [i32; 4]) -> [i32; 4] {
    [
        a[0].max(b[0]),
        a[1].max(b[1]),
        a[2].min(b[2]),
        a[3].min(b[3]),
    ]
}

/// Whether `outer` holds every pixel of `inner`.
pub(super) fn pixels_contain(outer: [i32; 4], inner: [i32; 4]) -> bool {
    outer[0] <= inner[0] && outer[1] <= inner[1] && outer[2] >= inner[2] && outer[3] >= inner[3]
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
/// are target pixels; `shape` and `radii` are in the material's own frame
/// (`to_material`), physical pixels along its axes.
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
    /// Target pixels to the frame `shape` and `radii` are in, rows of a
    /// 2x3 affine (`Affine::to_material`), and material normals back to
    /// target pixels (`Affine::normal_transform`).
    to_material0: [f32; 4],
    to_material1: [f32; 4],
    normal_transform: [f32; 4],
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
    /// A blur turned off the target's axes: it covers `shape` in its own
    /// frame, not all of `quad`.
    shaped_blur: u32,
    _pad: [u32; 2],
}

const _: () = assert!(std::mem::size_of::<Glass>() == 336);

/// How a material's frost is made: `region` of the target is copied and
/// halved `halvings` times (each a 2x2 box), then blurred along each axis
/// with a Gaussian of `sigma` texels of the result, cut at `radius` texels.
///
/// The strength is the engine's (Impeller's Gaussian blur): the same scaled
/// sigma, kernel reach and downscale, so a frame the engine composes frosts
/// alike. The grid is the target's: a moving material samples the same
/// texels and does not shimmer.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) struct FrostPlan {
    /// Target pixels: left, top, right, bottom.
    pub(super) region: [i32; 4],
    pub(super) halvings: u32,
    pub(super) sigma: [f32; 2],
    pub(super) radius: [f32; 2],
}

/// Impeller's ScaleSigma: a requested sigma as the engine blurs it (Skia's
/// apparent strength).
pub(super) fn scale_sigma(sigma: f32) -> f32 {
    let clamped = sigma.min(500.0);
    clamped * (1.0 - 3.4e-3 * clamped + 3.4e-6 * clamped * clamped)
}

/// Impeller's kernel reach for `sigma`, in the same pixels.
fn blur_radius(sigma: f32) -> f32 {
    if sigma > 0.5 {
        (sigma - 0.5) * 1.732_050_8
    } else {
        0.0
    }
}

/// Impeller's CalculateScale as halvings: none up to sigma 4, then the power
/// of two that leaves about two texels per sigma, at most 1/16, kept at 1/8
/// while that kernel stays within 41 taps.
fn frost_halvings(sigma: f32) -> u32 {
    if sigma <= 4.0 {
        return 0;
    }
    let exponent = (2.0 / sigma).log2().round().max(-4.0);
    let exponent = if exponent < -3.0 && 2.0 * (blur_radius(sigma) * 0.125).round() + 1.0 <= 41.0 {
        exponent + 1.0
    } else {
        exponent
    };
    (-exponent).max(0.0) as u32
}

impl FrostPlan {
    /// The frost of `source` (target pixels) blurred by `sigma` target
    /// pixels (already scaled as the engine scales it) and sampled up to
    /// `reach` pixels beyond it, within a `target`-sized output. None when
    /// nothing of it is inside the output.
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
        let halvings = frost_halvings(sigma[0].max(sigma[1]));
        let kernel = sigma.map(blur_radius);
        let cell = if exact { 1 } else { 1i32 << halvings };
        // What the blurred texel nearest the edge reads: the kernel's taps
        // on the last level, one more texel the glass's linear read reaches,
        // and half a texel to its centre, in target pixels; then two pixels
        // for the antialiased edge, as the engine's input bounds. The
        // region starts on the halvings' grid, so a moving material samples
        // the same texels and does not shimmer.
        let margin = |axis: usize| {
            if exact {
                return 0.0;
            }
            let taps = (kernel[axis] / cell as f32).round();
            ((taps + 1.5) * cell as f32 + reach[axis]).ceil() + 2.0
        };
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
            radius: [0.0; 2],
        };
        let [left, top, right, bottom] = plan.covered();
        let (last_width, last_height) = plan.level_size(plan.levels() - 1);
        let scale = [
            last_width as f32 / (right - left),
            last_height as f32 / (bottom - top),
        ];
        for axis in 0..2 {
            plan.sigma[axis] = sigma[axis] * scale[axis];
            // The engine drops the outermost pair of a long kernel, where it
            // carries under 1.6% of the weight.
            let radius = (kernel[axis] * scale[axis]).round();
            plan.radius[axis] = if radius >= 16.0 { radius - 1.0 } else { radius };
        }
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
    /// Every halving is an exact 2x2 box of the texels it covers: an odd
    /// last row or column is left out, never stretched across the level.
    pub(super) fn level_size(&self, level: u32) -> (u32, u32) {
        let (width, height) = self.base_size();
        ((width >> level).max(1), (height >> level).max(1))
    }

    fn base_size(&self) -> (u32, u32) {
        let (width, height) = self.region_size();
        if self.halvings == 0 {
            (width, height)
        } else {
            ((width / 2).max(1), (height / 2).max(1))
        }
    }

    /// Pixels of the region one level covers, as `level_size` texels:
    /// `extent` of the level before, halved exactly where it can be.
    pub(super) fn covered_extent(from: (u32, u32), to: (u32, u32)) -> (u32, u32) {
        ((to.0 * 2).min(from.0), (to.1 * 2).min(from.1))
    }

    /// Target pixels the finished frost covers (left, top, right, bottom):
    /// the region less the rows and columns no halving reached. The glass
    /// clamps past it to the frost's edge texels.
    pub(super) fn covered(&self) -> [f32; 4] {
        let mut extent = self.region_size();
        if self.halvings > 0 {
            let mut from = extent;
            for level in 0..self.levels() {
                let size = self.level_size(level);
                // What this level covers of the one before, in its pixels.
                let (width, height) = Self::covered_extent(from, size);
                extent = (extent.0.min(width << level), extent.1.min(height << level));
                from = size;
            }
        }
        let [left, top, ..] = self.region.map(|value| value as f32);
        [left, top, left + extent.0 as f32, top + extent.1 as f32]
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

/// Local coordinates to target pixels without perspective: the frame
/// Impeller's glass resolves a material in (`ResolveGlassMaterialDraw`).
/// Rotation, flips, skew and non-uniform scale all keep the surface exact:
/// it is evaluated in the material's own frame and its normals are mapped
/// back to target pixels.
struct Affine {
    /// Rows of the 2x3 transform: `[a, b, tx, c, d, ty]`.
    m: [f32; 6],
    /// Target pixels per local unit along local x and y (Impeller's
    /// `GetBasisScaleXY`).
    sx: f32,
    sy: f32,
    /// The inverse's linear part, rows.
    inverse: [f32; 4],
}

impl Affine {
    fn new(m: &Matrix3) -> Option<Self> {
        let m = m.0;
        if m[6] != 0.0 || m[7] != 0.0 || m[8] == 0.0 || !m[8].is_finite() {
            return None;
        }
        let w = m[8];
        let m = [m[0] / w, m[1] / w, m[2] / w, m[3] / w, m[4] / w, m[5] / w];
        let determinant = m[0] * m[4] - m[1] * m[3];
        if !determinant.is_finite() || determinant == 0.0 {
            return None;
        }
        let inverse = [
            m[4] / determinant,
            -m[1] / determinant,
            -m[3] / determinant,
            m[0] / determinant,
        ];
        let sx = m[0].hypot(m[3]);
        let sy = m[1].hypot(m[4]);
        (sx > 0.0 && sy > 0.0 && inverse.iter().all(|v| v.is_finite())).then_some(Self {
            m,
            sx,
            sy,
            inverse,
        })
    }

    fn point(&self, x: f32, y: f32) -> [f32; 2] {
        let m = &self.m;
        [m[0] * x + m[1] * y + m[2], m[3] * x + m[4] * y + m[5]]
    }

    /// `rect`'s target bounds: left, top, right, bottom.
    fn map(&self, rect: &Rect) -> [f32; 4] {
        let corners = [
            self.point(rect.left, rect.top),
            self.point(rect.right, rect.top),
            self.point(rect.right, rect.bottom),
            self.point(rect.left, rect.bottom),
        ];
        corners.iter().fold(
            [f32::MAX, f32::MAX, f32::MIN, f32::MIN],
            |[l, t, r, b], [x, y]| [l.min(*x), t.min(*y), r.max(*x), b.max(*y)],
        )
    }

    /// `rect`'s size in the material frame: local lengths scaled by the
    /// basis lengths.
    fn material_size(&self, rect: &Rect) -> [f32; 2] {
        [
            (rect.right - rect.left) * self.sx,
            (rect.bottom - rect.top) * self.sy,
        ]
    }

    /// Target pixels to the material frame of `rect`: its upper left
    /// corner at the origin, local axes scaled by the basis lengths. Rows
    /// `[a, b, c, 0]`: material = (a, b) · target + c.
    fn to_material(&self, rect: &Rect) -> [[f32; 4]; 2] {
        let i = &self.inverse;
        let (sx, sy) = (self.sx, self.sy);
        let basis = [sx * i[0], sx * i[1], sy * i[2], sy * i[3]];
        let (tx, ty) = (self.m[2], self.m[5]);
        [
            [
                basis[0],
                basis[1],
                -(basis[0] * tx + basis[1] * ty) - sx * rect.left,
                0.0,
            ],
            [
                basis[2],
                basis[3],
                -(basis[2] * tx + basis[3] * ty) - sy * rect.top,
                0.0,
            ],
        ]
    }

    /// A material-frame direction to target pixels as a distance-field
    /// gradient moves: the transpose of `to_material`'s linear part, as
    /// Impeller's `normal_transform` (`xy` multiplies normal x, `zw` y).
    fn normal_transform(&self) -> [f32; 4] {
        let i = &self.inverse;
        let (sx, sy) = (self.sx, self.sy);
        [sx * i[0], sx * i[1], sy * i[2], sy * i[3]]
    }

    /// Material-frame lengths along its x and y as target extents: the
    /// bounds of those lengths turned into target pixels.
    fn target_extents(&self, [x, y]: [f32; 2]) -> [f32; 2] {
        let m = &self.m;
        let (ux, uy) = (x / self.sx, y / self.sy);
        [
            (m[0] * ux).abs() + (m[1] * uy).abs(),
            (m[3] * ux).abs() + (m[4] * uy).abs(),
        ]
    }

    /// A Gaussian of local standard deviations `sigma` as target pixels
    /// along target x and y: exact for scale, flips and quarter turns and
    /// for an even blur under any rotation; an uneven blur under rotation
    /// takes the axis-aligned deviations of its turned ellipse.
    fn target_sigma(&self, [x, y]: [f32; 2]) -> [f32; 2] {
        let m = &self.m;
        [(m[0] * x).hypot(m[1] * y), (m[3] * x).hypot(m[4] * y)]
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
/// (a perspective or singular transform); Ok(None) when nothing of it is
/// visible. The surface is evaluated in the material's own frame, as
/// Impeller's glass: a target that flips y (an output buffer, bottom-up) or
/// a turned window keeps its corners, and the light stays in target
/// pixels.
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
    let affine = Affine::new(&target_from_local).ok_or("material transform")?;
    let (sx, sy) = (affine.sx, affine.sy);
    let map = |rect: &Rect| affine.map(rect);
    let scene_from_target = output_from_scene.inverse().ok_or("output transform")?;
    let ndc_from_target = ndc_from_target(target.0, target.1);
    let screen = [0.0, 0.0, target.0 as f32, target.1 as f32];
    let whole = map(&material.bounds);
    let Some(bounds) = intersect(whole, screen) else {
        return Ok(None);
    };
    // Turned off the target's axes, the material's rectangle no longer
    // fills its target bounds: draws cover it in its own frame.
    let axis_aligned = {
        let m = &affine.m;
        (m[1] == 0.0 && m[3] == 0.0) || (m[0] == 0.0 && m[4] == 0.0)
    };
    let [bounds_width, bounds_height] = affine.material_size(&material.bounds);
    let [to_material0, to_material1] = affine.to_material(&material.bounds);
    let mut record = Glass {
        ndc: rows(&ndc_from_target),
        scene: rows(&scene_from_target),
        opacity: local.opacity,
        clip_count: clips.count,
        clip_first: clips.first,
        mode: MODE_BLUR,
        shape: [0.0, 0.0, bounds_width, bounds_height],
        to_material0,
        to_material1,
        normal_transform: affine.normal_transform(),
        shaped_blur: u32::from(!window && !axis_aligned),
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
            let [width, height] = affine.material_size(&glass.shape);
            let half_extent = width.min(height) * 0.5;
            // Physical sizes, as GlassFilterContents resolves them.
            let thickness = (glass.thickness * (sx + sy) * 0.5).min(half_extent);
            record.mode = MODE_GLASS;
            // The surface in its own frame: corners keep their identities
            // under any flip or turn, and the normals map back to target
            // pixels (`normal_transform`).
            record.shape = [0.0, 0.0, width, height];
            [record.to_material0, record.to_material1] = affine.to_material(&glass.shape);
            record.radii = glass.radii.map(|[rx, ry]| (rx * sx).min(ry * sy));
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
            let reach = affine
                .target_extents([(ray - width * 0.5).max(0.0), (ray - height * 0.5).max(0.0)]);
            // A window's frost is its bounds' scene.
            (quad, if window { bounds } else { shape }, reach)
        }
    };
    // Only an exact window frost reads no more than the engine's input
    // (its content bounds): a blur's region adds padding and rounds out to
    // its halving grid.
    let tracked = window && clips.is_empty() && bounds == whole;
    record.quad = quad;
    let sigma = affine.target_sigma(material.sigma.map(scale_sigma));
    let Some(plan) = FrostPlan::new(source, sigma, reach, window, target) else {
        return Ok(None);
    };
    record.frost = plan.covered();
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

    /// Where target pixel `target` lies in the record's material frame.
    fn material_at(glass: &Glass, [x, y]: [f32; 2]) -> [f32; 2] {
        let [r0, r1] = [glass.to_material0, glass.to_material1];
        [r0[0] * x + r0[1] * y + r0[2], r1[0] * x + r1[1] * y + r1[2]]
    }

    fn close(a: [f32; 2], b: [f32; 2]) -> bool {
        (a[0] - b[0]).abs() < 1e-3 && (a[1] - b[1]).abs() < 1e-3
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
        // The surface in its own frame, corners in scene order either way.
        assert_eq!(upright.glass.shape, [0.0, 0.0, 176.0, 88.0]);
        assert_eq!(flipped.glass.shape, [0.0, 0.0, 176.0, 88.0]);
        assert_eq!(upright.glass.radii, [30.0, 20.0, 10.0, 0.0]);
        assert_eq!(flipped.glass.radii, [30.0, 20.0, 10.0, 0.0]);
        assert_eq!(upright.glass.quad, [40.0, 20.0, 216.0, 108.0]);
        assert_eq!(flipped.glass.quad, [40.0, 20.0, 216.0, 108.0]);
        // The scene's upper left: target row 20 upright, 108 flipped.
        assert!(close(material_at(&upright.glass, [40.0, 20.0]), [0.0, 0.0]));
        assert!(close(
            material_at(&flipped.glass, [40.0, 108.0]),
            [0.0, 0.0]
        ));
        // Normals turn with the flip.
        assert_eq!(upright.glass.normal_transform, [1.0, 0.0, 0.0, 1.0]);
        assert_eq!(flipped.glass.normal_transform, [1.0, 0.0, 0.0, -1.0]);
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
    fn quarter_turn_keeps_corners_and_swaps_blur_axes() {
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
        assert_eq!(draw.glass.quad, [20.0, 40.0, 108.0, 216.0]);
        assert_eq!(draw.glass.shape, [0.0, 0.0, 176.0, 88.0]);
        assert_eq!(draw.glass.radii, [30.0, 20.0, 10.0, 0.0]);
        // The scene's upper left lands at the target's upper right.
        assert!(close(material_at(&draw.glass, [108.0, 40.0]), [0.0, 0.0]));
        assert!(close(
            material_at(&draw.glass, [20.0, 216.0]),
            [176.0, 88.0]
        ));
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
        assert_eq!(draw.glass.shaped_blur, 0);
    }

    /// A window turned and shrunk as the close animation does: its glass is
    /// drawn in its own frame, scaled, within the turned shape's bounds.
    #[test]
    fn turned_glass_is_drawn_in_its_own_frame() {
        let radii = [[30.0; 2], [20.0; 2], [10.0; 2], [0.0; 2]];
        let mut material = glass_material([40.0, 20.0, 216.0, 108.0], radii);
        material.sigma = [6.0, 6.0];
        let (angle, scale) = (0.035f32, 0.8f32);
        let (c, s) = (angle.cos() * scale, angle.sin() * scale);
        let local = EntryLocal {
            scene_from_local: Matrix3([c, -s, 30.0, s, c, 10.0, 0.0, 0.0, 1.0]),
            ..plain_local()
        };
        let draw = super::material(
            &material,
            &local,
            ClipSpan::default(),
            &Matrix3::IDENTITY,
            (256, 128),
        )
        .expect("a turned material is drawn")
        .expect("visible");
        let glass = &draw.glass;
        assert_eq!(glass.mode, MODE_GLASS);
        assert!(close(
            [glass.shape[2], glass.shape[3]],
            [176.0 * scale, 88.0 * scale]
        ));
        assert!(close(
            [glass.radii[0], glass.radii[1]],
            [30.0 * scale, 20.0 * scale]
        ));
        // Each local corner lands on its material corner.
        let target = |x: f32, y: f32| [c * x - s * y + 30.0, s * x + c * y + 10.0];
        for ((x, y), expected) in [
            ((40.0, 20.0), [0.0, 0.0]),
            ((216.0, 20.0), [176.0 * scale, 0.0]),
            ((216.0, 108.0), [176.0 * scale, 88.0 * scale]),
            ((40.0, 108.0), [0.0, 88.0 * scale]),
        ] {
            assert!(close(material_at(glass, target(x, y)), expected));
        }
        // The quad bounds the turned corners.
        let corners =
            [(40.0, 20.0), (216.0, 20.0), (216.0, 108.0), (40.0, 108.0)].map(|(x, y)| target(x, y));
        let left = corners.iter().map(|p| p[0]).fold(f32::MAX, f32::min);
        let bottom = corners.iter().map(|p| p[1]).fold(f32::MIN, f32::max);
        assert!((glass.quad[0] - left).abs() < 1e-3);
        assert!((glass.quad[3] - bottom).abs() < 1e-3);
        // Normals map as the inverse transpose: under a rotation, the
        // material's x normal points along the turned x axis, its y normal
        // along the turned y axis.
        let unit = |v: [f32; 2]| {
            let length = v[0].hypot(v[1]);
            [v[0] / length, v[1] / length]
        };
        let nt = glass.normal_transform;
        assert!(close(unit([nt[0], nt[1]]), [angle.cos(), angle.sin()]));
        assert!(close(unit([nt[2], nt[3]]), [-angle.sin(), angle.cos()]));
        // An even blur keeps its scale under the turn: the same frost as the
        // window shrunk without turning.
        let shrunk = EntryLocal {
            scene_from_local: Matrix3([scale, 0.0, 30.0, 0.0, scale, 10.0, 0.0, 0.0, 1.0]),
            ..plain_local()
        };
        let unturned = super::material(
            &material,
            &shrunk,
            ClipSpan::default(),
            &Matrix3::IDENTITY,
            (256, 128),
        )
        .unwrap()
        .unwrap();
        assert!(close(draw.plan.sigma, unturned.plan.sigma));
        assert_eq!(draw.plan.halvings, unturned.plan.halvings);
    }

    #[test]
    fn a_turned_blur_covers_its_own_rectangle() {
        let mut material = glass_material([40.0, 20.0, 216.0, 108.0], [[0.0; 2]; 4]);
        material.glass = None;
        let turned = EntryLocal {
            scene_from_local: Matrix3([
                0.035f32.cos(),
                -0.035f32.sin(),
                0.0,
                0.035f32.sin(),
                0.035f32.cos(),
                0.0,
                0.0,
                0.0,
                1.0,
            ]),
            ..plain_local()
        };
        let draw = |local: &EntryLocal| {
            super::material(
                &material,
                local,
                ClipSpan::default(),
                &Matrix3::IDENTITY,
                (256, 128),
            )
            .unwrap()
            .unwrap()
        };
        assert_eq!(draw(&plain_local()).glass.shaped_blur, 0);
        let turned = draw(&turned);
        assert_eq!(turned.glass.shaped_blur, 1);
        assert!(close(
            [turned.glass.shape[2], turned.glass.shape[3]],
            [176.0, 88.0]
        ));
    }

    #[test]
    fn perspective_is_declined() {
        let material = glass_material([40.0, 20.0, 216.0, 108.0], [[0.0; 2]; 4]);
        let perspective = Matrix3([1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.001, 0.0, 1.0]);
        assert!(
            super::material(
                &material,
                &plain_local(),
                ClipSpan::default(),
                &perspective,
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
    fn frost_strength_is_the_engines() {
        // The shell's glass: sigma 18 blurs as 16.92, at 1/8 with a
        // four-texel kernel; sigma 10 as 9.66 at 1/4.
        let plan = |sigma: f32| {
            let sigma = scale_sigma(sigma);
            FrostPlan::new(
                [800.0, 400.0, 1000.0, 440.0],
                [sigma; 2],
                [0.0; 2],
                false,
                (1920, 1200),
            )
            .unwrap()
        };
        let glass = plan(18.0);
        assert!((scale_sigma(18.0) - 16.918).abs() < 1e-2);
        assert_eq!(glass.halvings, 3);
        assert_eq!(glass.radius, [4.0; 2]);
        assert_eq!(glass.region[0] % 8, 0);
        let pill = plan(10.0);
        assert_eq!((pill.halvings, pill.radius), (2, [4.0; 2]));
        // Small blurs stay at full size. Past a 41-tap kernel at 1/8 the
        // engine goes to 1/16, which its scaled sigmas never reach.
        assert_eq!(plan(4.0).halvings, 0);
        assert_eq!(plan(500.0).halvings, 3);
        assert_eq!(frost_halvings(120.0), 4);
    }

    #[test]
    fn frost_mips_are_sized_as_vulkan_sizes_them() {
        let plan = FrostPlan {
            region: [0, 0, 1366, 9],
            halvings: 3,
            sigma: [0.0; 2],
            radius: [0.0; 2],
        };
        assert_eq!(plan.levels(), 3);
        assert_eq!(plan.level_size(0), (683, 4));
        // 170 texels of 8x8 pixels; the ninth row is left out.
        assert_eq!(plan.covered(), [0.0, 0.0, 1360.0, 8.0]);
        assert_eq!(plan.level_size(1), (341, 2));
        assert_eq!(plan.level_size(2), (170, 1));
        // Too small to halve three times: one texel is the last level.
        let tiny = FrostPlan {
            region: [0, 0, 4, 2],
            halvings: 3,
            sigma: [0.0; 2],
            radius: [0.0; 2],
        };
        assert_eq!(tiny.levels(), 2);
        assert_eq!(tiny.level_size(1), (1, 1));
        let plain = FrostPlan {
            region: [0, 0, 7, 3],
            halvings: 0,
            sigma: [0.0; 2],
            radius: [0.0; 2],
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

    fn rect(left: f32, top: f32, right: f32, bottom: f32) -> Rect {
        Rect {
            left,
            top,
            right,
            bottom,
        }
    }

    fn whole(opacity: f32) -> EntryLocal {
        EntryLocal {
            scene_from_local: Matrix3::IDENTITY,
            opacity,
            clips: 0..0,
            sampling: denial_flutter_engine::scene::Sampling::Linear,
            freeze: false,
        }
    }

    #[test]
    fn opaque_draws_cover_whole_pixels_and_bounds_round_out() {
        // Scene to target at scale 2.
        let ndc =
            ndc_from_target(200, 100).then(&Matrix3([2.0, 0.0, 0.0, 0.0, 2.0, 0.0, 0.0, 0.0, 1.0]));
        let placement = Placement {
            source: [0.0, 0.0, 64.0, 64.0],
            destination: rect(10.25, 5.0, 60.0, 30.5),
            strict: false,
        };
        let draw = texture(&whole(1.0), ClipSpan::default(), &ndc, &placement, (64, 64)).unwrap();
        assert_eq!(draw.bounds((200, 100)), [20, 10, 120, 61]);
        assert_eq!(
            draw.opaque(None, (200, 100)),
            [Some([21, 10, 120, 61]), None]
        );
        let faded = texture(&whole(0.5), ClipSpan::default(), &ndc, &placement, (64, 64)).unwrap();
        assert_eq!(faded.opaque(None, (200, 100)), [None, None]);
        let clipped = texture(
            &whole(1.0),
            ClipSpan { first: 0, count: 1 },
            &ndc,
            &placement,
            (64, 64),
        )
        .unwrap();
        assert_eq!(clipped.opaque(None, (200, 100)), [None, None]);
        // Turned a quarter: still a rectangle.
        let quarter = ndc_from_target(200, 100)
            .then(&Matrix3([0.0, -1.0, 100.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0]));
        let turned = texture(
            &whole(1.0),
            ClipSpan::default(),
            &quarter,
            &placement,
            (64, 64),
        )
        .unwrap();
        assert_eq!(
            turned.opaque(None, (200, 100)),
            [Some([70, 11, 95, 60]), None]
        );
        // Turned by another angle: no cover.
        let (sin, cos) = 0.3f32.sin_cos();
        let tilted = ndc_from_target(200, 100)
            .then(&Matrix3([cos, -sin, 50.0, sin, cos, 0.0, 0.0, 0.0, 1.0]));
        let tilted = texture(
            &whole(1.0),
            ClipSpan::default(),
            &tilted,
            &placement,
            (64, 64),
        )
        .unwrap();
        assert_eq!(tilted.opaque(None, (200, 100)), [None, None]);
    }

    #[test]
    fn an_opaque_window_covers_its_client_inside_its_corners() {
        let style = WindowStyle {
            bounds: rect(0.0, 0.0, 100.0, 100.0),
            content_bounds: rect(0.0, 0.0, 100.0, 100.0),
            material_bounds: None,
            radius: 8.0,
            frame_color: 0xff000000,
            direct_texture: true,
        };
        let placement = Placement {
            source: [0.0, 0.0, 100.0, 90.0],
            destination: rect(0.0, 0.0, 100.0, 90.0),
            strict: false,
        };
        let ndc = ndc_from_target(100, 100);
        let draw = |surface_opacity: f32| {
            window(
                &whole(1.0),
                ClipSpan::default(),
                &ndc,
                &style,
                &Matrix3::IDENTITY,
                surface_opacity,
                Some((&placement, (100, 90))),
            )
            .unwrap()
        };
        let surface = window_surface(&Matrix3::IDENTITY, &placement);
        assert_eq!(surface, Some([0.0, 0.0, 100.0, 90.0]));
        // The quad reaches one past the window for its antialiased edge.
        assert_eq!(draw(1.0).bounds((100, 100)), [-1, -1, 101, 101]);
        assert_eq!(
            draw(1.0).opaque(surface, (100, 100)),
            [Some([8, 0, 92, 90]), Some([0, 8, 100, 82])]
        );
        assert_eq!(draw(0.5).opaque(surface, (100, 100)), [None, None]);
        assert_eq!(draw(1.0).opaque(None, (100, 100)), [None, None]);
    }
}
