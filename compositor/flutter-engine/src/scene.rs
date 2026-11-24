//! Denial's scene composer extension: the engine renders shell slices into
//! storage the embedder provides and hands each output frame's ordered entry
//! list to the embedder, which composes it. Mirrors `DenialFlutterScene*` in
//! the fork's `embedder.h`; kept out of the bindings generated from upstream.

use std::ffi::c_void;

use crate::sys;

/// One immutable version of a slice's storage.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct SliceKey {
    pub allocation: u64,
    pub generation: u64,
}

/// Writable slice storage the embedder bound on the raster context.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct SliceWriter {
    pub struct_size: usize,
    pub key: SliceKey,
    pub gl_name: u32,
    pub width: u32,
    pub height: u32,
}

/// Slice storage the engine renders with Impeller Vulkan on the embedder's
/// queue: a VkImage and a view of all of it, in `layout`.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct SliceWriterVk {
    pub struct_size: usize,
    pub key: SliceKey,
    pub image: u64,
    pub image_view: u64,
    /// VkFormat; R8G8B8A8_UNORM.
    pub format: u32,
    /// VkImageLayout.
    pub layout: u32,
    pub width: u32,
    pub height: u32,
}

/// `DenialFlutterTextureImageVK`: a client image lent to the engine while it
/// composes a frame the composer could not stage.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct TextureImageVk {
    pub struct_size: usize,
    pub image: u64,
    pub image_view: u64,
    /// VkFormat: R8G8B8A8_UNORM, B8G8R8A8_UNORM or R16G16B16A16_SFLOAT.
    pub format: u32,
    pub width: u32,
    pub height: u32,
    pub has_presentation: bool,
    pub presentation: crate::ExternalTexturePresentation,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SliceBlit {
    /// Left, top, right, bottom in storage pixels (`FlutterRect` layout).
    pub source: [f64; 4],
    /// Left, top, right, bottom in target pixels.
    pub destination: [f64; 4],
}

pub const ENTRY_SLICE: u32 = 1;
pub const ENTRY_TEXTURE: u32 = 2;
pub const ENTRY_WINDOW: u32 = 3;
pub const ENTRY_MATERIAL_BEGIN: u32 = 4;
pub const ENTRY_MATERIAL_END: u32 = 5;
pub const ENTRY_WINDOW_MATERIAL: u32 = 6;

/// `kDenialFlutterPlatformViewMutationTypeClipPath`.
const MUTATION_CLIP_PATH: sys::FlutterPlatformViewMutationType = 0x4450_0001;
/// `kDenialFlutterClipPathFillEvenOdd`.
const CLIP_PATH_FILL_EVEN_ODD: u32 = 1;

const MATERIAL_BLUR: u32 = 1;
const MATERIAL_GLASS: u32 = 2;

/// `DlBlendMode::kSrc`.
pub const BLEND_SRC: u32 = 1;
/// `DlBlendMode::kSrcOver`.
pub const BLEND_SRC_OVER: u32 = 3;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Sampling {
    Nearest,
    Linear,
    MipmapLinear,
    Cubic,
}

impl Sampling {
    fn from_raw(raw: u32) -> Self {
        match raw {
            0 => Self::Nearest,
            2 => Self::MipmapLinear,
            3 => Self::Cubic,
            _ => Self::Linear,
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub(crate) struct RawEntry {
    pub struct_size: usize,
    pub kind: u32,
    pub slice: SliceKey,
    pub slice_bottom_up: bool,
    pub slice_storage_width: u32,
    pub slice_storage_height: u32,
    pub blit_count: usize,
    pub blits: *const SliceBlit,
    pub texture_id: i64,
    pub texture_bounds: sys::FlutterRect,
    pub texture_transform: sys::FlutterTransformation,
    pub sampling: u32,
    pub surface_opacity: f64,
    pub freeze: bool,
    pub window_bounds: sys::FlutterRect,
    pub content_bounds: sys::FlutterRect,
    pub has_material_bounds: bool,
    pub material_bounds: sys::FlutterRect,
    pub radius: f64,
    pub frame_color: u32,
    pub direct_texture: bool,
    pub mutation_count: usize,
    pub mutations: *const sys::FlutterPlatformViewMutation,
    pub material: *const RawMaterial,
    pub clip_path_count: usize,
    pub clip_paths: *const RawClipPath,
}

/// `DenialFlutterClipPath`.
#[repr(C)]
#[derive(Clone, Copy)]
pub(crate) struct RawClipPath {
    pub fill: u32,
    pub point_count: usize,
    pub points: *const sys::FlutterPoint,
    pub contour_count: usize,
    pub contour_ends: *const u32,
}

/// `DenialFlutterMaterial`.
#[repr(C)]
#[derive(Clone, Copy)]
pub(crate) struct RawMaterial {
    pub struct_size: usize,
    pub filter: u32,
    pub blend_mode: u32,
    pub bounds: sys::FlutterRect,
    pub has_content_clip: bool,
    pub content_clip: sys::FlutterRect,
    pub has_backdrop_token: bool,
    pub backdrop_token: i64,
    pub sigma_x: f64,
    pub sigma_y: f64,
    pub shape: sys::FlutterRoundedRect,
    pub thickness: f64,
    pub refraction: f64,
    pub dispersion: f64,
    pub saturation: f64,
    pub tint: u32,
    pub tint_strength: f64,
    pub brightness: f64,
    pub light_angle: f64,
    pub light_intensity: f64,
    pub edge_strength: f64,
    pub bevel_width_scale: f64,
    pub refraction_depth_scale: f64,
    pub rim_width: f64,
    pub rim_falloff: f64,
    pub opposite_light_strength: f64,
    pub alpha_threshold: f64,
    pub has_frozen_frost: bool,
    pub frozen_frost: SliceKey,
    pub frozen_frost_bottom_up: bool,
    pub frozen_frost_storage_width: u32,
    pub frozen_frost_storage_height: u32,
    pub frozen_frost_width: u32,
    pub frozen_frost_height: u32,
    pub frozen_frost_rect: sys::FlutterRect,
    pub frozen_overlay: [f64; 4],
    pub frozen_opacity: f64,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub(crate) struct RawScene {
    pub struct_size: usize,
    pub view_id: i64,
    pub ticket: u64,
    pub scene_revision: u64,
    pub width: u32,
    pub height: u32,
    pub output_from_scene: sys::FlutterTransformation,
    pub entry_count: usize,
    pub entries: *const RawEntry,
    pub rewritten_count: usize,
    pub rewritten: *const SliceKey,
}

#[repr(C)]
pub(crate) struct RawComposer {
    pub struct_size: usize,
    pub user_data: *mut c_void,
    pub begin: unsafe extern "C" fn(*mut c_void, i64) -> u64,
    pub acquire_writer: unsafe extern "C" fn(*mut c_void, u64, u32, u32, *mut SliceWriter) -> bool,
    pub stage: unsafe extern "C" fn(*mut c_void, *const RawScene) -> bool,
    pub drop_engine_ref: unsafe extern "C" fn(*mut c_void, SliceKey),
    pub cancel: unsafe extern "C" fn(*mut c_void, u64),
    pub prepare_gles_read: unsafe extern "C" fn(*mut c_void, i64) -> bool,
    pub pin_backdrop: unsafe extern "C" fn(*mut c_void, u64, i64) -> bool,
    pub acquire_writer_vk:
        unsafe extern "C" fn(*mut c_void, u64, u32, u32, *mut SliceWriterVk) -> bool,
    pub resolve_texture_vk:
        Option<unsafe extern "C" fn(*mut c_void, u64, i64, *mut TextureImageVk) -> bool>,
    pub lend_textures_vk: Option<unsafe extern "C" fn(*mut c_void, u64) -> bool>,
    pub return_textures_vk: Option<unsafe extern "C" fn(*mut c_void, u64)>,
}

/// A 2D projective transform, row-major: `[x', y', w'] = M * [x, y, 1]`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Matrix3(pub [f32; 9]);

impl Matrix3 {
    pub const IDENTITY: Self = Self([1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]);

    pub fn from_flutter(t: &sys::FlutterTransformation) -> Self {
        Self([
            t.scaleX as f32,
            t.skewX as f32,
            t.transX as f32,
            t.skewY as f32,
            t.scaleY as f32,
            t.transY as f32,
            t.pers0 as f32,
            t.pers1 as f32,
            t.pers2 as f32,
        ])
    }

    /// `self * other`: applies `other` first.
    pub fn then(&self, other: &Self) -> Self {
        let a = &self.0;
        let b = &other.0;
        let mut out = [0.0; 9];
        for row in 0..3 {
            for column in 0..3 {
                out[row * 3 + column] = (0..3).map(|k| a[row * 3 + k] * b[k * 3 + column]).sum();
            }
        }
        Self(out)
    }

    pub fn inverse(&self) -> Option<Self> {
        let m = &self.0;
        let cofactor = [
            m[4] * m[8] - m[5] * m[7],
            m[2] * m[7] - m[1] * m[8],
            m[1] * m[5] - m[2] * m[4],
            m[5] * m[6] - m[3] * m[8],
            m[0] * m[8] - m[2] * m[6],
            m[2] * m[3] - m[0] * m[5],
            m[3] * m[7] - m[4] * m[6],
            m[1] * m[6] - m[0] * m[7],
            m[0] * m[4] - m[1] * m[3],
        ];
        let determinant = m[0] * cofactor[0] + m[1] * cofactor[3] + m[2] * cofactor[6];
        if !determinant.is_finite() || determinant == 0.0 {
            return None;
        }
        let inverse = cofactor.map(|value| value / determinant);
        inverse
            .iter()
            .all(|value| value.is_finite())
            .then_some(Self(inverse))
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect {
    pub left: f32,
    pub top: f32,
    pub right: f32,
    pub bottom: f32,
}

impl Rect {
    fn from_flutter(rect: &sys::FlutterRect) -> Self {
        Self {
            left: rect.left as f32,
            top: rect.top as f32,
            right: rect.right as f32,
            bottom: rect.bottom as f32,
        }
    }
}

/// A clip in the coordinate space its transform stack had when it was pushed.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Clip {
    /// Scene coordinates of the entry's outermost space to the clip's space.
    pub scene_to_clip: Matrix3,
    pub rect: Rect,
    /// Corner radii (x, y) upper-left, upper-right, lower-right, lower-left;
    /// all zero for a hard-edged rectangle clip.
    pub radii: [[f32; 2]; 4],
    /// A path clip: `rect` is its bounds, the path its edges.
    pub path: Option<ClipPath>,
}

/// A path clip's polygon edges: `count` of the scene's `path_edges` from
/// `first`, filled by the nonzero or the even-odd rule. No edges: the clip
/// holds nothing.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ClipPath {
    pub first: u32,
    pub count: u32,
    pub even_odd: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WindowStyle {
    pub bounds: Rect,
    pub content_bounds: Rect,
    pub material_bounds: Option<Rect>,
    pub radius: f32,
    /// Non-premultiplied 0xAARRGGBB.
    pub frame_color: u32,
    pub direct_texture: bool,
}

/// Denial glass parameters, as `DlGlassImageFilter` (lengths in the
/// material's local coordinates).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Glass {
    pub shape: Rect,
    /// Corner radii (x, y) upper-left, upper-right, lower-right, lower-left.
    pub radii: [[f32; 2]; 4],
    pub thickness: f32,
    pub refraction: f32,
    pub dispersion: f32,
    pub saturation: f32,
    /// Non-premultiplied 0xAARRGGBB.
    pub tint: u32,
    pub tint_strength: f32,
    pub brightness: f32,
    pub light_angle: f32,
    pub light_intensity: f32,
    pub edge_strength: f32,
    pub bevel_width_scale: f32,
    pub refraction_depth_scale: f32,
    pub rim_width: f32,
    pub rim_falloff: f32,
    pub opposite_light_strength: f32,
}

/// Glass over a frost made once for a whole scene: a slice version whose
/// top-left `size` pixels cover `rect` (material-local), refracted and lit
/// in place of a blur of the scene below.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FrozenFrost {
    pub key: SliceKey,
    pub bottom_up: bool,
    pub storage_size: (u32, u32),
    pub size: (u32, u32),
    pub rect: Rect,
    /// Drawn over the material within its shape, premultiplied RGBA.
    pub overlay: [f32; 4],
    /// Fades the material, not the overlay.
    pub opacity: f32,
}

/// A backdrop material: the scene below it, blurred (and shaded as glass),
/// then the entries up to its end, composited as one layer.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Material {
    /// None: a plain Gaussian blur.
    pub glass: Option<Glass>,
    /// Gaussian standard deviation, local units.
    pub sigma: [f32; 2],
    /// `DlBlendMode` of the layer.
    pub blend_mode: u32,
    /// The layer's bounds, local.
    pub bounds: Rect,
    /// Clips the material's children, local.
    pub content_clip: Option<Rect>,
    /// Changes whenever the scene below the material changes; None when the
    /// engine does not track it.
    pub backdrop_token: Option<i64>,
    /// Behind a window: the client alpha the material needs, 0..1.
    pub alpha_threshold: f32,
    /// Glass over a frost made once for the scene, instead of the scene
    /// below; such a material has no content.
    pub frozen: Option<FrozenFrost>,
}

impl Material {
    fn from_raw(raw: &RawMaterial) -> Option<Self> {
        let glass = match raw.filter {
            MATERIAL_BLUR => None,
            MATERIAL_GLASS => {
                let shape = &raw.shape;
                let radius = |size: &sys::FlutterSize| [size.width as f32, size.height as f32];
                Some(Glass {
                    shape: Rect::from_flutter(&shape.rect),
                    radii: [
                        radius(&shape.upper_left_corner_radius),
                        radius(&shape.upper_right_corner_radius),
                        radius(&shape.lower_right_corner_radius),
                        radius(&shape.lower_left_corner_radius),
                    ],
                    thickness: raw.thickness as f32,
                    refraction: raw.refraction as f32,
                    dispersion: raw.dispersion as f32,
                    saturation: raw.saturation as f32,
                    tint: raw.tint,
                    tint_strength: raw.tint_strength as f32,
                    brightness: raw.brightness as f32,
                    light_angle: raw.light_angle as f32,
                    light_intensity: raw.light_intensity as f32,
                    edge_strength: raw.edge_strength as f32,
                    bevel_width_scale: raw.bevel_width_scale as f32,
                    refraction_depth_scale: raw.refraction_depth_scale as f32,
                    rim_width: raw.rim_width as f32,
                    rim_falloff: raw.rim_falloff as f32,
                    opposite_light_strength: raw.opposite_light_strength as f32,
                })
            }
            _ => return None,
        };
        Some(Self {
            glass,
            sigma: [raw.sigma_x as f32, raw.sigma_y as f32],
            blend_mode: raw.blend_mode,
            bounds: Rect::from_flutter(&raw.bounds),
            content_clip: raw
                .has_content_clip
                .then(|| Rect::from_flutter(&raw.content_clip)),
            backdrop_token: raw.has_backdrop_token.then_some(raw.backdrop_token),
            alpha_threshold: raw.alpha_threshold as f32,
            frozen: (raw.struct_size >= std::mem::size_of::<RawMaterial>()
                && raw.has_frozen_frost
                && glass.is_some())
            .then(|| FrozenFrost {
                key: raw.frozen_frost,
                bottom_up: raw.frozen_frost_bottom_up,
                storage_size: (
                    raw.frozen_frost_storage_width,
                    raw.frozen_frost_storage_height,
                ),
                size: (raw.frozen_frost_width, raw.frozen_frost_height),
                rect: Rect::from_flutter(&raw.frozen_frost_rect),
                overlay: raw.frozen_overlay.map(|v| v as f32),
                opacity: raw.frozen_opacity as f32,
            }),
        })
    }
}

/// What the mutator stack resolves to for a texture, window or material.
#[derive(Clone, Debug, PartialEq)]
pub struct EntryLocal {
    /// Entry-local coordinates to scene coordinates.
    pub scene_from_local: Matrix3,
    pub opacity: f32,
    /// Range into [`Scene::clips`].
    pub clips: std::ops::Range<usize>,
    pub sampling: Sampling,
    pub freeze: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub enum SceneEntry {
    Slice {
        key: SliceKey,
        bottom_up: bool,
        storage_width: u32,
        storage_height: u32,
        /// A placed slice: its blit scales, sampled linearly. Otherwise
        /// blits copy pixel for pixel, nearest.
        linear: bool,
        /// Range into [`Scene::blits`].
        blits: std::ops::Range<usize>,
    },
    Texture {
        texture_id: i64,
        bounds: Rect,
        local: EntryLocal,
    },
    Window {
        texture_id: i64,
        texture_bounds: Rect,
        texture_transform: Matrix3,
        surface_opacity: f32,
        style: WindowStyle,
        /// The material behind the client, where its alpha lets it show.
        backdrop: Option<Material>,
        local: EntryLocal,
    },
    MaterialBegin {
        material: Material,
        local: EntryLocal,
    },
    /// Closes the innermost open material.
    MaterialEnd,
}

/// One staged output frame. Kept by the embedder and refilled every frame,
/// so staging allocates only when a scene outgrows every earlier one.
#[derive(Clone, Debug, PartialEq)]
pub struct Scene {
    pub view_id: i64,
    pub ticket: u64,
    pub revision: u64,
    pub width: u32,
    pub height: u32,
    pub output_from_scene: Matrix3,
    pub entries: Vec<SceneEntry>,
    pub blits: Vec<SliceBlit>,
    pub clips: Vec<Clip>,
    /// Path clips' edges in their clips' spaces: x0, y0, x1, y1. Edges
    /// along x are left out; they never cross a row.
    pub path_edges: Vec<[f32; 4]>,
    pub rewritten: Vec<SliceKey>,
}

impl Default for Scene {
    fn default() -> Self {
        Self {
            view_id: 0,
            ticket: 0,
            revision: 0,
            width: 0,
            height: 0,
            output_from_scene: Matrix3::IDENTITY,
            entries: Vec::new(),
            blits: Vec::new(),
            clips: Vec::new(),
            path_edges: Vec::new(),
            rewritten: Vec::new(),
        }
    }
}

/// The engine's borrowed scene, valid only during the `stage` callback.
pub struct SceneSource<'a> {
    raw: &'a RawScene,
}

impl SceneSource<'_> {
    /// # Safety
    /// `raw` and every array it points at must stay valid for `'a`.
    pub(crate) unsafe fn new(raw: &RawScene) -> SceneSource<'_> {
        SceneSource { raw }
    }

    pub fn view_id(&self) -> i64 {
        self.raw.view_id
    }

    pub fn ticket(&self) -> u64 {
        self.raw.ticket
    }

    /// A scene of one slice the engine composed itself, after the composer
    /// declined the frame's own scene.
    pub fn engine_composed(&self) -> bool {
        self.raw.scene_revision & (1 << 63) != 0
    }

    /// Copies the scene into `scene`, reusing its buffers. False when the
    /// engine described something this embedder cannot show exactly; `scene`
    /// is then partly overwritten, so copy into a scratch scene.
    pub fn copy_into(&self, scene: &mut Scene) -> bool {
        // SAFETY: SceneSource is only created for the duration of `stage`,
        // whose arrays the engine keeps valid for that call.
        unsafe { copy_scene(self.raw, scene) }
    }
}

unsafe fn borrowed<'a, T>(pointer: *const T, count: usize) -> &'a [T] {
    if count == 0 || pointer.is_null() {
        &[]
    } else {
        // SAFETY: upheld by the caller.
        unsafe { std::slice::from_raw_parts(pointer, count) }
    }
}

/// Appends a path's polygon edges to `edges`. None when the contours do not
/// fit the points.
///
/// # Safety
/// The path's arrays must be valid for this call.
unsafe fn path_edges(path: &RawClipPath, edges: &mut Vec<[f32; 4]>) -> Option<ClipPath> {
    // SAFETY: upheld by the caller.
    let points = unsafe { borrowed(path.points, path.point_count) };
    // SAFETY: upheld by the caller.
    let ends = unsafe { borrowed(path.contour_ends, path.contour_count) };
    let first = edges.len();
    let mut start = 0usize;
    for &end in ends {
        let end = end as usize;
        if end <= start || end > points.len() {
            return None;
        }
        let contour = &points[start..end];
        for (index, a) in contour.iter().enumerate() {
            let b = &contour[(index + 1) % contour.len()];
            if a.y != b.y {
                edges.push([a.x as f32, a.y as f32, b.x as f32, b.y as f32]);
            }
        }
        start = end;
    }
    Some(ClipPath {
        first: u32::try_from(first).ok()?,
        count: u32::try_from(edges.len() - first).ok()?,
        even_odd: path.fill == CLIP_PATH_FILL_EVEN_ODD,
    })
}

/// None when a clip's space cannot be inverted (the clip cannot be dropped)
/// or a mutation is not one this build knows.
///
/// # Safety
/// The path clips' arrays must be valid for this call.
unsafe fn resolve_mutations(
    mutations: &[sys::FlutterPlatformViewMutation],
    paths: &[RawClipPath],
    clips: &mut Vec<Clip>,
    edges: &mut Vec<[f32; 4]>,
) -> Option<(Matrix3, f32)> {
    let mut transform = Matrix3::IDENTITY;
    let mut opacity = 1.0f32;
    let mut paths = paths.iter();
    for mutation in mutations {
        match mutation.type_ {
            sys::FlutterPlatformViewMutationType_kFlutterPlatformViewMutationTypeOpacity => {
                // SAFETY: the type tag selects the union member.
                opacity *= unsafe { mutation.__bindgen_anon_1.opacity } as f32;
            }
            sys::FlutterPlatformViewMutationType_kFlutterPlatformViewMutationTypeTransformation => {
                // SAFETY: the type tag selects the union member.
                let matrix =
                    Matrix3::from_flutter(unsafe { &mutation.__bindgen_anon_1.transformation });
                transform = transform.then(&matrix);
            }
            sys::FlutterPlatformViewMutationType_kFlutterPlatformViewMutationTypeClipRect => {
                // SAFETY: the type tag selects the union member.
                let rect = Rect::from_flutter(unsafe { &mutation.__bindgen_anon_1.clip_rect });
                let scene_to_clip = transform.inverse()?;
                clips.push(Clip { scene_to_clip, rect, radii: [[0.0; 2]; 4], path: None });
            }
            sys::FlutterPlatformViewMutationType_kFlutterPlatformViewMutationTypeClipRoundedRect => {
                // SAFETY: the type tag selects the union member.
                let rounded = unsafe { &mutation.__bindgen_anon_1.clip_rounded_rect };
                let radius = |size: &sys::FlutterSize| [size.width as f32, size.height as f32];
                clips.push(Clip {
                    scene_to_clip: transform.inverse()?,
                    rect: Rect::from_flutter(&rounded.rect),
                    radii: [
                        radius(&rounded.upper_left_corner_radius),
                        radius(&rounded.upper_right_corner_radius),
                        radius(&rounded.lower_right_corner_radius),
                        radius(&rounded.lower_left_corner_radius),
                    ],
                    path: None,
                });
            }
            MUTATION_CLIP_PATH => {
                // SAFETY: the type tag selects the union member: the bounds.
                let rect = Rect::from_flutter(unsafe { &mutation.__bindgen_anon_1.clip_rect });
                // SAFETY: upheld by the caller.
                let path = unsafe { path_edges(paths.next()?, edges) }?;
                clips.push(Clip {
                    scene_to_clip: transform.inverse()?,
                    rect,
                    radii: [[0.0; 2]; 4],
                    path: Some(path),
                });
            }
            _ => return None,
        }
    }
    // Every path clip belongs to one mutation.
    paths.next().is_none().then_some((transform, opacity))
}

/// # Safety
/// `raw` and every array it points at must be valid for this call.
unsafe fn copy_scene(raw: &RawScene, scene: &mut Scene) -> bool {
    // V1 layouts exactly: entries are iterated with this build's stride.
    if raw.struct_size != std::mem::size_of::<RawScene>() {
        return false;
    }
    scene.entries.clear();
    scene.blits.clear();
    scene.clips.clear();
    scene.path_edges.clear();
    scene.rewritten.clear();
    scene.view_id = raw.view_id;
    scene.ticket = raw.ticket;
    scene.revision = raw.scene_revision;
    scene.width = raw.width;
    scene.height = raw.height;
    scene.output_from_scene = Matrix3::from_flutter(&raw.output_from_scene);
    // SAFETY: upheld by the caller.
    scene
        .rewritten
        .extend_from_slice(unsafe { borrowed(raw.rewritten, raw.rewritten_count) });
    // The engine's entry stride must be this build's before the array is
    // read as RawEntry at all.
    // SAFETY: upheld by the caller; struct_size leads every layout.
    if raw.entry_count > 0
        && (raw.entries.is_null()
            || unsafe { raw.entries.cast::<usize>().read() } != std::mem::size_of::<RawEntry>())
    {
        return false;
    }
    // SAFETY: upheld by the caller, with the stride checked above.
    for entry in unsafe { borrowed(raw.entries, raw.entry_count) } {
        if entry.struct_size != std::mem::size_of::<RawEntry>() {
            return false;
        }
        match entry.kind {
            ENTRY_SLICE => {
                let first = scene.blits.len();
                // SAFETY: upheld by the caller.
                scene
                    .blits
                    .extend_from_slice(unsafe { borrowed(entry.blits, entry.blit_count) });
                scene.entries.push(SceneEntry::Slice {
                    key: entry.slice,
                    bottom_up: entry.slice_bottom_up,
                    storage_width: entry.slice_storage_width,
                    storage_height: entry.slice_storage_height,
                    linear: Sampling::from_raw(entry.sampling) != Sampling::Nearest,
                    blits: first..scene.blits.len(),
                });
            }
            ENTRY_MATERIAL_END => scene.entries.push(SceneEntry::MaterialEnd),
            ENTRY_TEXTURE | ENTRY_WINDOW | ENTRY_MATERIAL_BEGIN | ENTRY_WINDOW_MATERIAL => {
                let first = scene.clips.len();
                // SAFETY: upheld by the caller.
                let mutations = unsafe { borrowed(entry.mutations, entry.mutation_count) };
                // SAFETY: upheld by the caller.
                let paths = unsafe { borrowed(entry.clip_paths, entry.clip_path_count) };
                // SAFETY: upheld by the caller.
                let Some((scene_from_local, opacity)) = (unsafe {
                    resolve_mutations(mutations, paths, &mut scene.clips, &mut scene.path_edges)
                }) else {
                    return false;
                };
                let local = EntryLocal {
                    scene_from_local,
                    opacity,
                    clips: first..scene.clips.len(),
                    sampling: Sampling::from_raw(entry.sampling),
                    freeze: entry.freeze,
                };
                let material = if matches!(entry.kind, ENTRY_MATERIAL_BEGIN | ENTRY_WINDOW_MATERIAL)
                {
                    if entry.material.is_null() {
                        return false;
                    }
                    // SAFETY: upheld by the caller.
                    let raw = unsafe { &*entry.material };
                    if raw.struct_size != std::mem::size_of::<RawMaterial>() {
                        return false;
                    }
                    let Some(material) = Material::from_raw(raw) else {
                        return false;
                    };
                    Some(material)
                } else {
                    None
                };
                scene.entries.push(if entry.kind == ENTRY_MATERIAL_BEGIN {
                    let Some(material) = material else {
                        return false;
                    };
                    SceneEntry::MaterialBegin { material, local }
                } else if entry.kind == ENTRY_TEXTURE {
                    SceneEntry::Texture {
                        texture_id: entry.texture_id,
                        bounds: Rect::from_flutter(&entry.texture_bounds),
                        local,
                    }
                } else {
                    SceneEntry::Window {
                        texture_id: entry.texture_id,
                        texture_bounds: Rect::from_flutter(&entry.texture_bounds),
                        texture_transform: Matrix3::from_flutter(&entry.texture_transform),
                        surface_opacity: entry.surface_opacity as f32,
                        style: WindowStyle {
                            bounds: Rect::from_flutter(&entry.window_bounds),
                            content_bounds: Rect::from_flutter(&entry.content_bounds),
                            material_bounds: entry
                                .has_material_bounds
                                .then(|| Rect::from_flutter(&entry.material_bounds)),
                            radius: entry.radius as f32,
                            frame_color: entry.frame_color,
                            direct_texture: entry.direct_texture,
                        },
                        backdrop: material,
                        local,
                    }
                });
            }
            _ => return false,
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matrix_composition_applies_right_operand_first() {
        let translate = Matrix3([1.0, 0.0, 10.0, 0.0, 1.0, 20.0, 0.0, 0.0, 1.0]);
        let scale = Matrix3([2.0, 0.0, 0.0, 0.0, 3.0, 0.0, 0.0, 0.0, 1.0]);
        // translate * scale maps (1, 1) to (12, 23).
        let m = translate.then(&scale).0;
        assert_eq!((m[0] + m[1] + m[2], m[3] + m[4] + m[5]), (12.0, 23.0));
        let inverse = translate.then(&scale).inverse().unwrap().0;
        let x = inverse[0] * 12.0 + inverse[1] * 23.0 + inverse[2];
        let y = inverse[3] * 12.0 + inverse[4] * 23.0 + inverse[5];
        assert!((x - 1.0).abs() < 1e-5 && (y - 1.0).abs() < 1e-5);
    }

    #[test]
    fn raw_layout_matches_the_c_header() {
        // Checked against the fork's embedder.h on x86-64 and AArch64 (LP64).
        assert_eq!(std::mem::size_of::<SliceKey>(), 16);
        assert_eq!(std::mem::size_of::<SliceWriter>(), 40);
        assert_eq!(std::mem::size_of::<SliceBlit>(), 64);
        assert_eq!(std::mem::size_of::<RawEntry>(), 360);
        assert_eq!(std::mem::offset_of!(RawEntry, material), 336);
        assert_eq!(std::mem::offset_of!(RawEntry, clip_paths), 352);
        assert_eq!(std::mem::size_of::<RawClipPath>(), 40);
        assert_eq!(std::mem::size_of::<RawMaterial>(), 464);
        assert_eq!(std::mem::offset_of!(RawMaterial, has_frozen_frost), 344);
        assert_eq!(std::mem::offset_of!(RawMaterial, frozen_frost), 352);
        assert_eq!(
            std::mem::offset_of!(RawMaterial, frozen_frost_bottom_up),
            368
        );
        assert_eq!(
            std::mem::offset_of!(RawMaterial, frozen_frost_storage_width),
            372
        );
        assert_eq!(std::mem::offset_of!(RawMaterial, frozen_frost_width), 380);
        assert_eq!(std::mem::offset_of!(RawMaterial, frozen_frost_rect), 392);
        assert_eq!(std::mem::offset_of!(RawMaterial, frozen_overlay), 424);
        assert_eq!(std::mem::offset_of!(RawMaterial, frozen_opacity), 456);
        assert_eq!(std::mem::offset_of!(RawMaterial, content_clip), 56);
        assert_eq!(std::mem::offset_of!(RawMaterial, backdrop_token), 96);
        assert_eq!(std::mem::offset_of!(RawMaterial, shape), 120);
        assert_eq!(std::mem::offset_of!(RawMaterial, tint), 248);
        assert_eq!(
            std::mem::offset_of!(RawMaterial, opposite_light_strength),
            328
        );
        assert_eq!(std::mem::offset_of!(RawEntry, texture_id), 64);
        assert_eq!(std::mem::offset_of!(RawEntry, sampling), 176);
        assert_eq!(std::mem::offset_of!(RawEntry, surface_opacity), 184);
        assert_eq!(std::mem::offset_of!(RawEntry, frame_color), 312);
        assert_eq!(std::mem::offset_of!(RawEntry, mutations), 328);
        assert_eq!(std::mem::size_of::<RawScene>(), 144);
        assert_eq!(std::mem::offset_of!(RawScene, entries), 120);
        assert_eq!(std::mem::offset_of!(RawScene, rewritten), 136);
        assert_eq!(std::mem::size_of::<SliceWriterVk>(), 56);
        assert_eq!(std::mem::size_of::<RawComposer>(), 104);
        assert_eq!(std::mem::offset_of!(RawComposer, resolve_texture_vk), 80);
        assert_eq!(std::mem::offset_of!(RawComposer, return_textures_vk), 96);
        assert_eq!(std::mem::offset_of!(TextureImageVk, has_presentation), 36);
        assert_eq!(std::mem::offset_of!(TextureImageVk, presentation), 40);
        assert_eq!(std::mem::size_of::<TextureImageVk>(), 168);
        assert_eq!(std::mem::offset_of!(RawComposer, acquire_writer_vk), 72);
        assert_eq!(std::mem::offset_of!(RawComposer, prepare_gles_read), 56);
        assert_eq!(std::mem::offset_of!(RawComposer, pin_backdrop), 64);
    }
}
