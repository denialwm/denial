//! Stagecraft, Denial's Vulkan scene composer (docs/STAGECRAFT.md). The
//! engine half is the Flutter fork's layered mode: it cuts each frame into
//! slices and stages them (`DenialStageScene`, embedder.h); this module draws
//! them. Wherever Vulkan opens the GPU, Denial renders with Vulkan alone: the
//! engine renders the shell with Impeller Vulkan on this module's device and
//! queue, into private slice images, and the composer draws each output frame
//! from them. Where Vulkan cannot open the GPU there
//! is no composer and everything renders with GLES; never half of each.
//!
//! Each output frame it can describe, the engine stages as an ordered list of
//! slices, client textures and windows; the composer draws that list into the
//! output buffer. A frame it cannot describe the engine composes itself, with
//! Vulkan, into composer storage (`engine_frames`).
//!
//! Synchronization:
//! - Slices are written on the composer's queue before the submission that
//!   shows them.
//! - Vulkan only reads client buffers, in `GENERAL` layout with FOREIGN
//!   ownership acquired and released in the same submission.
//! - Before GLES samples composer storage itself, its context waits for the
//!   last Vulkan submission (`prepare_gles_read`), and the next submission
//!   waits for that GLES work.
//! - The completion sync_file of a submission is the frame's fence for KMS,
//!   cross-GPU transfer and client buffer release.
//! - Within one raster transaction the last fence covers every earlier
//!   frame: a submission after a GLES present waits for GLES, and a GLES
//!   present after a submission waits for Vulkan. Client buffers sampled by
//!   either are released on that last fence.
//!
//! Backdrop materials (blur, glass) are drawn natively (`material.rs`): the
//! frame copies the target as drawn so far, blurs it into a frost and draws
//! the material from it, all within the frame's one submission. A frost is
//! kept per view and material and reused while the engine reports no damage
//! in its region, or its backdrop token says the scene below is unchanged.
//!
//! A frame redraws only what the engine reports changed since its output
//! buffer was last presented (the damage GLES composes and the scanout copy
//! takes), grown by the region of every frost made again; the rest of the
//! buffer keeps its pixels.

#[path = "convert.rs"]
mod convert;
#[path = "device.rs"]
mod device;
#[path = "material.rs"]
mod material;
#[path = "record.rs"]
mod record;
#[path = "shell_queue.rs"]
mod shell_queue;

use std::collections::HashMap;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::os::fd::{AsFd, OwnedFd};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};

use denial_flutter_engine::scene::{
    BLEND_SRC, BLEND_SRC_OVER, Matrix3, Rect, Sampling, Scene, SceneEntry, SceneSource, SliceKey,
    SliceWriterVk,
};
use denial_flutter_engine::sys;
use smithay::backend::allocator::dmabuf::{AsDmabuf, Dmabuf, WeakDmabuf};
use smithay::backend::allocator::gbm::{GbmBuffer, GbmDevice};
use smithay::backend::allocator::{Fourcc, Modifier};
use smithay::backend::drm::DrmDeviceFd;
use tracing::{info, warn};

pub(super) use convert::ConvertKey;
pub(super) use device::Image;
pub(in crate::flutter_runtime) use device::ShellDevice;
use device::{Batch, Frame, Gpu, MAX_FRAMES, MaterialStep, Merge, Step, Upload, Usage, WindowDraw};
use material::Frost;
pub(super) use record::Placement;
use record::{ClipRecord, ClipSpan, Draw, FrostPlan, Glass};
pub(in crate::flutter_runtime) use shell_queue::instance_proc as shell_instance_proc;

use crate::output_color::Lut;

/// Whether this session renders in hardware and so tries the composer.
pub(super) fn requested() -> bool {
    crate::options::VULKAN_COMPOSER.load(Ordering::Relaxed)
}

/// The client buffer formats to advertise on the GPU behind the DRM node
/// `device_number`, out of what GLES imports (`formats`): with the composer,
/// only layouts it can sample (`device::sampled_client_formats`).
pub(crate) fn client_formats(
    device_number: libc::dev_t,
    formats: smithay::backend::allocator::format::FormatSet,
) -> smithay::backend::allocator::format::FormatSet {
    if !requested() {
        return formats;
    }
    match device::sampled_client_formats(device_number, &formats) {
        Ok(sampled) => {
            let dropped = formats.iter().count() - sampled.iter().count();
            tracing::info!(
                dropped,
                "client buffer layouts limited to what Stagecraft samples"
            );
            sampled
        }
        Err(error) => {
            tracing::warn!(%error, "client buffer layouts stay as GLES imports them");
            formats
        }
    }
}

/// Blocks until a completion fence signals. Failure paths only.
pub(super) fn wait_completion(fence: &OwnedFd) {
    device::wait_fd(fence.as_fd(), -1);
}

/// Whether `fence` has signalled. Does not wait.
pub(super) fn signalled(fence: &OwnedFd) -> bool {
    device::wait_fd(fence.as_fd(), 0)
}

/// A copy of `fence` for another waiter, or None once it signalled. A
/// failed copy waits for the fence here: a dependency is never dropped.
fn share(fence: &OwnedFd) -> Option<OwnedFd> {
    if device::wait_fd(fence.as_fd(), 0) {
        return None;
    }
    match fence.try_clone() {
        Ok(copy) => Some(copy),
        Err(error) => {
            warn!(%error, "could not share a Stagecraft fence; waiting on the CPU");
            device::wait_fd(fence.as_fd(), -1);
            None
        }
    }
}

/// The target pixels each engine damage rect touches.
fn target_damage(
    rects: &[sys::FlutterRect],
    output_from_scene: Matrix3,
    size: (u32, u32),
) -> impl Iterator<Item = [i32; 4]> + '_ {
    rects.iter().map(move |rect| {
        record::target_pixels(
            &output_from_scene,
            [rect.left, rect.top, rect.right, rect.bottom],
            size,
        )
    })
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// How long a submission waits for a frame when all are in flight. Frames
/// complete within a refresh or two; past this the GPU is stuck.
const FRAME_WAIT: std::time::Duration = std::time::Duration::from_secs(2);

/// A client import unused for this many submissions is released: each live
/// shared import costs every submission (~0.7 µs on RADV), and re-importing
/// costs about 20 submissions' worth. An import whose buffer the client
/// destroyed goes at the next reap, submissions or not: the image holds only
/// Vulkan's own reference, never the client's `Dmabuf`.
const CLIENT_IMPORT_IDLE_SUBMITS: u64 = 64;

/// Retired Vulkan slice images kept for later versions of the same size,
/// at most this many bytes: every slice version the engine renders is a
/// fresh image, and the engine buckets slice sizes, so most reuse one.
const SLICE_POOL_BYTES: u64 = 96 << 20;

/// A pooled slice image unused for this many submissions is destroyed.
const SLICE_POOL_IDLE_SUBMITS: u64 = 240;

/// One version of a slice's storage.
struct Slice {
    /// GLES-written slices only; zero GL names for Vulkan-written ones.
    _bo: Option<GbmBuffer>,
    egl_image: usize,
    gl_texture: u32,
    image: Arc<Image>,
    /// The engine still references this version.
    engine_ref: bool,
    /// The last submission that sampled it.
    last_serial: u64,
}

struct ClientImport {
    image: Arc<Image>,
    last_serial: u64,
}

/// A texture's SHM pixels, copied into an image of its own. Retired like
/// client imports, after `CLIENT_IMPORT_IDLE_SUBMITS` unused.
struct ShmImport {
    image: Arc<Image>,
    /// What a submitted upload left in it; None before the first.
    pixels: Option<super::ShmPixelsId>,
    last_serial: u64,
}

/// What the frame must do on the handler's side once it is submitted.
pub(super) struct SampledClient {
    pub(super) texture_id: i64,
    pub(super) generation: u64,
    pub(super) source: super::ExternalTextureSource,
}

impl SampledClient {
    /// Feeds the buffer into `state`: its storage and the revision of its
    /// pixels.
    fn hash_content(&self, state: &mut DefaultHasher) {
        state.write_i64(self.texture_id);
        state.write_u64(self.generation);
        match &self.source {
            super::ExternalTextureSource::Dmabuf { dmabuf, .. } => dmabuf.weak().hash(state),
            super::ExternalTextureSource::Shm(_) => state.write_u8(0),
        }
    }
}

/// What a slice version holds: a rewrite renders a new generation.
fn slice_content(key: &SliceKey) -> u64 {
    let mut content = DefaultHasher::new();
    content.write_u64(key.allocation);
    content.write_u64(key.generation);
    content.finish()
}

/// A submitted frame.
pub(super) struct Submitted {
    /// Its completion; None when it already completed.
    pub(super) completion: Option<OwnedFd>,
    /// Scene pixels it changed beyond the engine's damage, which the frame's
    /// damage must take for the scanout copy and the other buffers.
    pub(super) added: Option<sys::FlutterRect>,
}

/// The scene rectangle holding target pixels `rect`.
fn scene_rect(output_from_scene: &Matrix3, rect: [i32; 4]) -> Option<sys::FlutterRect> {
    let [left, top, right, bottom] =
        record::map_bounds(&output_from_scene.inverse()?, rect.map(f64::from))?;
    Some(sys::FlutterRect {
        left,
        top,
        right,
        bottom,
    })
}

/// What the engine reports changed in an output frame, in scene pixels.
#[derive(Clone, Copy)]
pub(super) struct FrameDamage<'a> {
    /// Since the view's previous frame.
    pub(super) frame: &'a [sys::FlutterRect],
    /// Since the output buffer was last presented: what the frame redraws.
    pub(super) buffer: &'a [sys::FlutterRect],
}

/// A frame accepted by `stage`, presented with its view's root frame.
pub(super) struct Staged {
    view_id: i64,
    /// Maps the engine's damage to target pixels.
    output_from_scene: Matrix3,
    /// The engine's layered build this frame shows: material order names
    /// the same material only within one.
    scene_revision: u64,
    draws: Vec<Draw>,
    glasses: Vec<Glass>,
    /// The clips draws and glass records name by `ClipSpan`.
    clips: Vec<ClipRecord>,
    /// The scene's path clip edges, which path clips name by index.
    edges: Vec<[f32; 4]>,
    steps: Vec<Step>,
    /// Each material's backdrop token when it tracks all the frost reads,
    /// by record.
    backdrop_tokens: Vec<Option<i64>>,
    /// Each material's backdrop token as the engine names it, by record.
    engine_tokens: Vec<Option<i64>>,
    /// Target pixels each material's draw can change, by record.
    outputs: Vec<[i32; 4]>,
    /// Diagnostic: cached frosts by why they were judged (a frost made
    /// below, plan, token, what they read, reused), and frosts without a
    /// cache.
    remade_why: [u32; 6],
    /// Frosts that took new images: none cached fit.
    frosts_allocated: u32,
    slices: Vec<SliceKey>,
    /// Shell slices the engine rendered again for this frame.
    slices_rewritten: u32,
    pub(super) clients: Vec<SampledClient>,
    /// Inputs of merged windows reused as they are: shown again, not read.
    pub(super) credits: Vec<SampledClient>,
    /// Buffers nothing can read: not shown, only let go so the texture
    /// moves on (no presentation feedback).
    pub(super) omitted: Vec<SampledClient>,
    /// SHM pixels the frame copies before it draws.
    uploads: Vec<Upload>,
    /// Native windows merged before the frame draws, and what each image
    /// holds once the submission succeeded.
    merges: Vec<Merge>,
    /// Every merged window this frame shows: its layers, its image and
    /// whether this frame draws it (else a submission drew it before).
    merged_windows: Vec<MergedWindow>,
    /// Merged windows shown from the image a submission drew.
    merges_reused: u32,
    /// Clients shown from an image GLES converted or copied.
    converted: u32,
    /// Target pixels draws paint opaque, by draw record, in draw order.
    covers: Vec<(u32, [i32; 4])>,
    /// Draws and materials hidden under opaque draws above them.
    culled_draws: u32,
    culled_materials: u32,
    /// Draws drawn only where covers above leave them visible.
    split_draws: u32,
    /// Each client texture's draw record, in draw order.
    client_draws: Vec<(i64, u32)>,
    /// Client textures with a draw that changes pixels, and those whose
    /// draws opaque draws above hide (`cull`). A texture off this target is
    /// neither: another output may show it.
    shown_textures: Vec<i64>,
    hidden_textures: Vec<i64>,
    /// Diagnostic: whether the topmost client drawn over the whole target
    /// covers it, else why not; None without such a client.
    full_cover: Option<Option<&'static str>>,
}

impl Staged {
    /// Diagnostic: notes whether `draw`, when it reaches over the whole
    /// target, covers it.
    fn note_cover(
        &mut self,
        draw: &Draw,
        size: (u32, u32),
        why: impl FnOnce() -> Option<&'static str>,
    ) {
        let target = [0, 0, size.0 as i32, size.1 as i32];
        if record::pixels_contain(draw.bounds(size), target) {
            self.full_cover = Some(why());
        }
    }
}

struct MergedWindow {
    texture_id: i64,
    keys: Vec<MergeKey>,
    image: Arc<Image>,
    drawn: bool,
}

struct State {
    targets: HashMap<u32, Arc<Image>>,
    slices: HashMap<u64, Slice>,
    /// Retired Vulkan-written slice images and the submission count when
    /// they retired, oldest first; the GPU no longer uses any of them.
    slice_pool: Vec<(u64, Image)>,
    clients: HashMap<WeakDmabuf, ClientImport>,
    /// By texture ID.
    uploads: HashMap<i64, ShmImport>,
    /// Merged native windows by texture ID: their image and the layers it
    /// holds (None until a submission drew them).
    merged: HashMap<i64, (Arc<Image>, Option<Vec<MergeKey>>)>,
    frames: Vec<Frame>,
    serial: u64,
    completed: u64,
    ticket: u64,
    /// The view `ticket` was begun for.
    ticket_view: i64,
    staged: Option<(u64, Staged)>,
    scratch: Scene,
    /// The last submission's completion while it may still run.
    last_completion: Option<OwnedFd>,
    /// GLES sampled composer storage since the last submission.
    gles_read: bool,
    /// A failed submission: decline every later frame.
    broken: bool,
    /// Frosts by view and material order, as last submitted.
    frosts: HashMap<(i64, u32), CachedFrost>,
    /// Views whose last frame the composer did not draw (GLES did, or none
    /// was presented): the engine's damage no longer says what changed
    /// since the composer's last frame, so the next one redraws and reports
    /// everything.
    unaccounted: Vec<i64>,
    /// Each view's output buffer as the composer last drew it whole, while
    /// the view has shown no frame since that the composer did not draw:
    /// what the next frame copies the changes of earlier frames from.
    shown: HashMap<i64, Arc<Image>>,
    /// Catch-up as before: frames draw again everything that changed since
    /// their buffer was last shown (`DENIAL_COMPOSER_CATCH_UP=redraw`).
    redraw_catch_up: bool,
    /// App looks as 3D images, while the look lives. Weak: the GLES grades
    /// hold the look too, and each side prunes on its own.
    looks: Vec<(Weak<Lut>, Arc<Image>)>,
    /// The last GLES output present's fence while it may still run: a
    /// submission waits for it, so Vulkan never overlaps a GLES read and the
    /// transaction's last fence covers both queues. The reverse holds by
    /// construction: GLES waits for every submission (handler).
    last_gles_fence: Option<OwnedFd>,
    tally: Tally,
    /// Diagnostic: the last `Staged::full_cover` logged, by view.
    full_covers: HashMap<i64, Option<Option<&'static str>>>,
}

impl State {
    /// `view_id` showed a frame the composer did not draw.
    fn unaccount(&mut self, view_id: i64) {
        crate::client_visibility::forget(view_id);
        self.frosts.retain(|&(view, _), _| view != view_id);
        self.shown.remove(&view_id);
        if !self.unaccounted.contains(&view_id) {
            self.unaccounted.push(view_id);
        }
    }
}

/// Whether frames draw again what changed in earlier frames
/// (`DENIAL_COMPOSER_CATCH_UP=redraw`) rather than copying it from the
/// buffer shown last (`copy`, the default). Copying reads and writes those
/// pixels once; drawing them again may cost less where memory bandwidth is
/// scarcer than shading.
fn redraw_catch_up() -> bool {
    match std::env::var("DENIAL_COMPOSER_CATCH_UP").as_deref() {
        Ok("redraw") => true,
        Ok("copy") | Err(_) => false,
        Ok(other) => {
            warn!(
                value = other,
                "DENIAL_COMPOSER_CATCH_UP is copy or redraw; copying"
            );
            false
        }
    }
}

/// The scene revision bit of a frame the engine composed itself.
const ENGINE_COMPOSED: u64 = 1 << 63;

/// What composed the output frames while the composer is on, logged at 1,
/// 100, 1 000, 10 000… frames: how many Vulkan drew, how many GLES drew and
/// why, and how often frosts are remade.
#[derive(Default)]
struct Tally {
    vulkan_frames: u64,
    /// Presented by GLES: the engine composed them, or the composer declined
    /// them (`declines`).
    gles_frames: u64,
    declines: Vec<(&'static str, u64)>,
    materials: u64,
    frosts_made: u64,
    /// Made because the engine tracks no token for them, or the composer
    /// samples beyond what it tracks.
    frosts_untracked: u64,
    /// Native windows merged with Vulkan, and shown again from their image.
    merges_made: u64,
    merges_reused: u64,
    /// Clients shown from a GLES conversion or copy.
    converted: u64,
    /// Vulkan frames the engine composed itself after the composer declined
    /// its scene (`declines`).
    engine_frames: u64,
    /// Vulkan frames that redrew part of the target, none of it, and the
    /// share of target pixels redrawn over all Vulkan frames.
    partial_frames: u64,
    /// Diagnostic: shares of target pixels the engine's frame damage and the
    /// composer's added damage cover, summed over Vulkan frames; frosts by
    /// why they were judged (`Staged::remade_why`).
    engine_damage: f64,
    added_damage: f64,
    remade_why: [u64; 6],
    frosts_allocated: u64,
    empty_frames: u64,
    redrawn: f64,
    /// Draws and materials not drawn: opaque draws above hide them.
    culled_draws: u64,
    culled_materials: u64,
    /// Draws drawn only where opaque draws above leave them visible.
    split_draws: u64,
    /// Frames that copied earlier frames' changes from the buffer shown last.
    repaired: u64,
    /// Frames for which the engine rendered shell slices again, and how
    /// many slices.
    shell_frames: u64,
    slices_rewritten: u64,
    /// Slice images the engine took for a new version: from the pool, or
    /// freshly allocated.
    slices_pooled: u64,
    slices_allocated: u64,
}

impl Tally {
    fn vulkan(
        &mut self,
        staged: &Staged,
        area: [i32; 4],
        size: (u32, u32),
        engine_damage: f64,
        added_damage: f64,
    ) {
        self.engine_damage += engine_damage;
        self.added_damage += added_damage;
        for (total, count) in self.remade_why.iter_mut().zip(staged.remade_why) {
            *total += u64::from(count);
        }
        self.frosts_allocated += u64::from(staged.frosts_allocated);
        let pixels = if record::pixels_empty(area) {
            0
        } else {
            i64::from(area[2] - area[0]) * i64::from(area[3] - area[1])
        };
        let whole = i64::from(size.0) * i64::from(size.1);
        self.partial_frames += u64::from(pixels != 0 && pixels < whole);
        self.empty_frames += u64::from(pixels == 0);
        self.redrawn += pixels as f64 / whole.max(1) as f64;
        for step in &staged.steps {
            if let Step::Material(material) = step {
                self.materials += 1;
                self.frosts_made += u64::from(material.fresh);
                self.frosts_untracked +=
                    u64::from(staged.backdrop_tokens[material.record as usize].is_none());
            }
        }
        self.merges_made += staged.merges.len() as u64;
        self.merges_reused += u64::from(staged.merges_reused);
        self.converted += u64::from(staged.converted);
        self.culled_draws += u64::from(staged.culled_draws);
        self.culled_materials += u64::from(staged.culled_materials);
        self.split_draws += u64::from(staged.split_draws);
        self.shell_frames += u64::from(staged.slices_rewritten > 0);
        self.slices_rewritten += u64::from(staged.slices_rewritten);
        self.engine_frames += u64::from(staged.scene_revision & ENGINE_COMPOSED != 0);
        self.vulkan_frames += 1;
        self.log();
    }

    fn gles(&mut self) {
        self.gles_frames += 1;
        self.log();
    }

    fn decline(&mut self, reason: &'static str) {
        match self.declines.iter_mut().find(|(known, _)| *known == reason) {
            Some((_, count)) => *count += 1,
            None => self.declines.push((reason, 1)),
        }
    }

    fn log(&self) {
        let frames = self.vulkan_frames + self.gles_frames;
        let mut mark = 1;
        while mark < frames {
            mark *= if mark == 1 { 100 } else { 10 };
        }
        if mark != frames {
            return;
        }
        let declines = self
            .declines
            .iter()
            .map(|(reason, count)| format!("{reason}: {count}"))
            .collect::<Vec<_>>()
            .join(", ");
        info!(
            vulkan_frames = self.vulkan_frames,
            gles_frames = self.gles_frames,
            %declines,
            materials = self.materials,
            frosts_made = self.frosts_made,
            frosts_untracked = self.frosts_untracked,
            merges_made = self.merges_made,
            merges_reused = self.merges_reused,
            converted = self.converted,
            engine_frames = self.engine_frames,
            partial_frames = self.partial_frames,
            engine_damage_percent = format_args!(
                "{:.1}",
                self.engine_damage * 100.0 / self.vulkan_frames.max(1) as f64
            ),
            added_damage_percent = format_args!(
                "{:.1}",
                self.added_damage * 100.0 / self.vulkan_frames.max(1) as f64
            ),
            remade_below = self.remade_why[0],
            remade_plan = self.remade_why[1],
            remade_token = self.remade_why[2],
            remade_read = self.remade_why[3],
            reused = self.remade_why[4],
            uncached = self.remade_why[5],
            frosts_allocated = self.frosts_allocated,
            empty_frames = self.empty_frames,
            culled_draws = self.culled_draws,
            culled_materials = self.culled_materials,
            split_draws = self.split_draws,
            repaired_frames = self.repaired,
            shell_frames = self.shell_frames,
            slices_rewritten = self.slices_rewritten,
            slices_pooled = self.slices_pooled,
            slices_allocated = self.slices_allocated,
            redrawn_percent = format_args!(
                "{:.1}",
                self.redrawn * 100.0 / self.vulkan_frames.max(1) as f64
            ),
            "output frames"
        );
    }
}

struct CachedFrost {
    frost: Arc<Frost>,
    plan: FrostPlan,
    backdrop_token: Option<i64>,
    /// The engine's token for the material, tracked or not: what the engine
    /// asks the composer to pin.
    engine_token: Option<i64>,
    /// What it read below its material (`SceneComposer::resolve_frosts`).
    below: u64,
    /// The submission it was made for: what the materials above it read of
    /// it.
    made: u64,
}

pub(super) struct SceneComposer {
    gpu: Gpu,
    placeholder: Arc<Image>,
    /// Bound as the look of clients without one; never read.
    no_look: Arc<Image>,
    gbm: Mutex<GbmDevice<DrmDeviceFd>>,
    slice_modifiers: Vec<Modifier>,
    /// What EGL renders ABGR16161616F with and Vulkan samples; empty when
    /// none, then half-float conversions decline.
    float_modifiers: Vec<Modifier>,
    /// Clients GLES converted for the composer (convert.rs). Taken after
    /// `state` when both are held.
    converts: Mutex<convert::Pool>,
    next_allocation: AtomicU64,
    dropped: Mutex<Vec<SliceKey>>,
    state: Mutex<State>,
}

impl SceneComposer {
    /// `render_node` is the DRM node the raster context renders with;
    /// `render_modifiers` what EGL renders ABGR8888 with, `float_render`
    /// what it renders ABGR16161616F with.
    pub(super) fn new(
        render_node: DrmDeviceFd,
        render_modifiers: &[Modifier],
        float_render: &[Modifier],
    ) -> Result<Self, String> {
        let gpu = Gpu::new(render_node.as_fd())?;
        let placeholder = gpu.placeholder()?;
        let no_look = gpu.look_image(1, &[0.0, 0.0, 0.0, 1.0])?;
        let sampled = gpu.0.sampled_modifiers(Fourcc::Abgr8888);
        let slice_modifiers: Vec<_> = render_modifiers
            .iter()
            .copied()
            .filter(|modifier| *modifier != Modifier::Invalid && sampled.contains(modifier))
            .collect();
        if slice_modifiers.is_empty() {
            return Err("no ABGR8888 modifier both EGL renders and Vulkan samples".into());
        }
        let float_sampled = gpu.0.sampled_modifiers(Fourcc::Abgr16161616f);
        let float_modifiers: Vec<_> = float_render
            .iter()
            .copied()
            .filter(|modifier| *modifier != Modifier::Invalid && float_sampled.contains(modifier))
            .collect();
        let gbm = GbmDevice::new(render_node)
            .map_err(|error| format!("Stagecraft GBM device: {error}"))?;
        info!(
            modifiers = ?slice_modifiers,
            float = ?float_modifiers,
            "Stagecraft slice storage"
        );
        Ok(Self {
            gpu,
            placeholder,
            no_look,
            gbm: Mutex::new(gbm),
            slice_modifiers,
            float_modifiers,
            converts: convert::pool(),
            next_allocation: AtomicU64::new(1),
            dropped: Mutex::new(Vec::new()),
            state: Mutex::new(State {
                targets: HashMap::new(),
                slices: HashMap::new(),
                slice_pool: Vec::new(),
                clients: HashMap::new(),
                uploads: HashMap::new(),
                merged: HashMap::new(),
                frames: Vec::new(),
                serial: 0,
                completed: 0,
                ticket: 0,
                ticket_view: 0,
                staged: None,
                scratch: Scene::default(),
                last_completion: None,
                gles_read: false,
                broken: false,
                frosts: HashMap::new(),
                unaccounted: Vec::new(),
                shown: HashMap::new(),
                redraw_catch_up: redraw_catch_up(),
                last_gles_fence: None,
                looks: Vec::new(),
                tally: Tally::default(),
                full_covers: HashMap::new(),
            }),
        })
    }

    /// Imports the output buffer the engine renders into as `framebuffer`.
    /// A buffer that cannot be imported keeps its frames on GLES.
    pub(super) fn add_target(&self, framebuffer: u32, dmabuf: &Dmabuf) {
        match self.gpu.import(dmabuf, Usage::Target) {
            Ok(image) => {
                lock(&self.state).targets.insert(framebuffer, image);
            }
            Err(error) => warn!(framebuffer, %error, "output buffer stays on GLES composition"),
        }
    }

    /// Releases what finished submissions held and destroys slice versions
    /// nothing uses any more. Raster thread, raster context current.
    pub(super) fn reap(&self, gl: &super::GlApi, display: &super::EGLDisplayHandle) {
        self.reap_conversions(gl, display);
        let dropped = std::mem::take(&mut *lock(&self.dropped));
        let mut state = lock(&self.state);
        let mut completed = state.completed;
        for frame in &mut state.frames {
            if frame.idle() {
                completed = completed.max(frame.serial);
            }
        }
        state.completed = completed;
        if state
            .last_completion
            .as_ref()
            .is_some_and(|fd| device::wait_fd(fd.as_fd(), 0))
        {
            state.last_completion = None;
        }
        for key in dropped {
            if let Some(slice) = state.slices.get_mut(&key.allocation) {
                slice.engine_ref = false;
            }
        }
        let staged: Vec<SliceKey> = state
            .staged
            .as_ref()
            .map(|(_, staged)| staged.slices.clone())
            .unwrap_or_default();
        let retired: Vec<u64> = state
            .slices
            .iter()
            .filter(|(allocation, slice)| {
                !slice.engine_ref
                    && slice.last_serial <= completed
                    && !staged.iter().any(|key| key.allocation == **allocation)
            })
            .map(|(allocation, _)| *allocation)
            .collect();
        let serial = state.serial;
        for allocation in retired {
            let Some(slice) = state.slices.remove(&allocation) else {
                continue;
            };
            destroy_gl(gl, display, &slice);
            // A Vulkan-written version nothing else holds goes to the pool.
            if slice.egl_image == 0
                && let Ok(image) = Arc::try_unwrap(slice.image)
            {
                state.slice_pool.push((serial, image));
            }
        }
        state
            .slice_pool
            .retain(|(retired, _)| serial - retired < SLICE_POOL_IDLE_SUBMITS);
        let mut bytes: u64 = state
            .slice_pool
            .iter()
            .map(|(_, image)| slice_bytes(image))
            .sum();
        while bytes > SLICE_POOL_BYTES {
            let (_, oldest) = state.slice_pool.remove(0);
            bytes -= slice_bytes(&oldest);
        }
        state.clients.retain(|weak, import| {
            !weak.is_gone() && serial - import.last_serial < CLIENT_IMPORT_IDLE_SUBMITS
        });
        state
            .uploads
            .retain(|_, import| serial - import.last_serial < CLIENT_IMPORT_IDLE_SUBMITS);
    }

    /// Drops a texture's SHM image once its source is gone; frames that
    /// still sample it hold it until they complete.
    pub(super) fn forget_texture(&self, texture_id: i64) {
        self.forget_conversions(texture_id);
        let mut state = lock(&self.state);
        let retired = (
            state.uploads.remove(&texture_id),
            state.merged.remove(&texture_id),
        );
        drop(state);
        drop(retired);
    }

    /// None unless every buffer in `framebuffers` (at least one) was
    /// imported; then whether materials can copy from all of them.
    pub(super) fn targets_copyable(
        &self,
        framebuffers: impl IntoIterator<Item = u32>,
    ) -> Option<bool> {
        let state = lock(&self.state);
        let mut copyable = None;
        for framebuffer in framebuffers {
            let target = state.targets.get(&framebuffer)?;
            copyable = Some(copyable.unwrap_or(true) && target.copyable);
        }
        copyable
    }

    /// An output frame of `view_id` GLES presented while the composer is
    /// on. Its damage never reached the composer: the view's frosts can no
    /// longer tell what changed below them.
    pub(super) fn gles_presented(&self, view_id: i64) {
        let mut state = lock(&self.state);
        state.unaccount(view_id);
        state.tally.gles();
    }

    /// The view's last frame never reached the screen.
    pub(super) fn frame_lost(&self, view_id: i64) {
        lock(&self.state).unaccount(view_id);
    }

    /// Why the composer did not draw a staged frame.
    pub(super) fn declined(&self, reason: &'static str) {
        lock(&self.state).tally.decline(reason);
    }

    pub(super) fn begin(&self, view_id: i64) -> u64 {
        let mut state = lock(&self.state);
        if state.broken || state.targets.is_empty() {
            return 0;
        }
        if let Some((_, staged)) = state.staged.take() {
            state.unaccount(staged.view_id);
        }
        state.ticket = state.ticket.wrapping_add(1).max(1);
        state.ticket_view = view_id;
        state.ticket
    }

    /// Whether frame `ticket`'s view holds a frost made from the engine's
    /// backdrop `token`. The engine then leaves that backdrop's readback out
    /// of the frame's damage; should the frame make the frost again after
    /// all, it redraws the frost's region and reports it (`submit_locked`).
    pub(super) fn pin_backdrop(&self, ticket: u64, token: i64) -> bool {
        // Diagnostic: DENIAL_COMPOSER_NO_PIN=1 measures without pins.
        static NO_PIN: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
        if *NO_PIN.get_or_init(|| std::env::var_os("DENIAL_COMPOSER_NO_PIN").is_some()) {
            return false;
        }
        let state = lock(&self.state);
        let view_id = state.ticket_view;
        ticket == state.ticket
            && !state.unaccounted.contains(&view_id)
            && state
                .frosts
                .iter()
                .any(|(&(view, _), cached)| view == view_id && cached.engine_token == Some(token))
    }

    /// A begun frame the composer will not draw: the engine composes it or
    /// drops it, after planning its damage (maybe with pins).
    /// The raster task ended: a staged frame its view's root present did
    /// not take is dropped with the client buffers it holds, and the view
    /// redraws whole.
    pub(super) fn abandon_staged(&self) {
        let mut state = lock(&self.state);
        if let Some((_, staged)) = state.staged.take() {
            state.unaccount(staged.view_id);
        }
    }

    pub(super) fn cancel(&self, ticket: u64) {
        let mut state = lock(&self.state);
        if state
            .staged
            .as_ref()
            .is_some_and(|(staged, _)| *staged == ticket)
        {
            state.staged = None;
        }
        if ticket == state.ticket {
            let view_id = state.ticket_view;
            state.unaccount(view_id);
        }
    }

    pub(super) fn drop_engine_ref(&self, key: SliceKey) {
        lock(&self.dropped).push(key);
    }

    /// Storage GLES renders into and the composer samples: its buffer, the
    /// imported image, the EGLImage and the GL texture bound to it. The
    /// raster context is current. Takes no composer state.
    fn shared_storage(
        &self,
        width: u32,
        height: u32,
        fourcc: Fourcc,
        modifiers: &[Modifier],
        gl: &super::GlApi,
        display: &smithay::backend::egl::EGLDisplay,
    ) -> Option<(GbmBuffer, Arc<Image>, usize, u32)> {
        if width == 0 || height == 0 || width > 16384 || height > 16384 {
            return None;
        }
        // GBM picks among them: only those the image imports with, and
        // without one whose allocation did not import.
        let mut modifiers = self.gpu.0.importable(fourcc, (width, height), modifiers);
        let (bo, image, egl_image) = loop {
            if modifiers.is_empty() {
                warn!(
                    width,
                    height,
                    ?fourcc,
                    "no Stagecraft storage modifier imports at this size"
                );
                return None;
            }
            let bo = {
                let gbm = lock(&self.gbm);
                let raw = gbm
                    .create_buffer_object_with_modifiers::<()>(
                        width,
                        height,
                        fourcc,
                        modifiers.iter().copied(),
                    )
                    .map_err(
                        |error| warn!(%error, width, height, "Stagecraft storage allocation failed"),
                    )
                    .ok()?;
                GbmBuffer::from_bo(raw, false)
            };
            let dmabuf = bo
                .export()
                .map_err(|error| warn!(%error, "Stagecraft storage export failed"))
                .ok()?;
            let imported = self
                .gpu
                .import(&dmabuf, Usage::Sampled)
                .map_err(|error| error.to_string())
                .and_then(|image| {
                    display
                        .create_image_from_dmabuf(&dmabuf)
                        .map(|egl_image| (image, egl_image))
                        .map_err(|error| format!("EGLImage: {error}"))
                });
            match imported {
                Ok((image, egl_image)) => break (bo, image, egl_image),
                Err(error) => {
                    let chosen = smithay::backend::allocator::Buffer::format(&dmabuf).modifier;
                    warn!(%error, ?chosen, "Stagecraft storage import failed; trying another modifier");
                    let before = modifiers.len();
                    modifiers.retain(|modifier| *modifier != chosen);
                    if modifiers.len() == before {
                        return None;
                    }
                }
            }
        };
        let mut gl_texture = 0;
        let mut previous_texture = 0;
        // SAFETY: the raster context is current (the engine's contract for
        // acquire_writer, the stage's for conversions); the image is live.
        // The engine's texture binding is put back.
        let error = unsafe {
            let _ = (gl.get_error)();
            (gl.get_integer_v)(super::gl::TEXTURE_BINDING_2D, &mut previous_texture);
            (gl.gen_textures)(1, &mut gl_texture);
            (gl.bind_texture)(super::gl::TEXTURE_2D, gl_texture);
            (gl.image_target_texture)(super::gl::TEXTURE_2D, egl_image.cast());
            (gl.bind_texture)(super::gl::TEXTURE_2D, previous_texture as u32);
            (gl.get_error)()
        };
        if gl_texture == 0 || error != super::gl::NO_ERROR {
            warn!(
                error = format_args!("{error:#x}"),
                "Stagecraft storage GL binding failed"
            );
            // SAFETY: as above; the texture and image have not escaped.
            unsafe {
                if gl_texture != 0 {
                    (gl.delete_textures)(1, &gl_texture);
                }
                smithay::backend::egl::ffi::egl::DestroyImageKHR(
                    display.get_display_handle().handle,
                    egl_image as *const std::ffi::c_void,
                );
            }
            return None;
        }
        Some((bo, image, egl_image as usize, gl_texture))
    }

    /// The device was lost: every later frame declines.
    pub(super) fn broken(&self) -> bool {
        lock(&self.state).broken
    }

    /// The device the engine renders on.
    pub(super) fn shell_device(&self) -> ShellDevice {
        self.gpu.shell_device()
    }

    /// Fresh private storage for one slice version the engine renders with
    /// Impeller Vulkan on the shared queue. Raster thread.
    pub(super) fn acquire_writer_vk(&self, width: u32, height: u32) -> Option<SliceWriterVk> {
        if width == 0 || height == 0 || width > 16384 || height > 16384 {
            return None;
        }
        let pooled = {
            let mut state = lock(&self.state);
            // The engine renders into storage at least its size. A pooled
            // image a little larger serves: slices change size as the shell
            // moves (recents cards), and each miss allocates.
            let needed = u64::from(width) * u64::from(height);
            let found = state
                .slice_pool
                .iter()
                .enumerate()
                .filter(|(_, (_, image))| {
                    let (w, h) = image.size;
                    let area = u64::from(w) * u64::from(h);
                    w >= width && h >= height && area * 2 <= needed * 3
                })
                .min_by_key(|(_, (_, image))| u64::from(image.size.0) * u64::from(image.size.1))
                .map(|(index, _)| index);
            let pooled = found.map(|index| state.slice_pool.remove(index).1);
            state.tally.slices_pooled += u64::from(pooled.is_some());
            state.tally.slices_allocated += u64::from(pooled.is_none());
            pooled
        };
        // A pooled image's contents are discarded: the engine clears every
        // slice it renders, from UNDEFINED.
        let image = if let Some(image) = pooled {
            image
        } else {
            self.gpu
                .private_image(
                    (width, height),
                    1,
                    ash::vk::ImageUsageFlags::COLOR_ATTACHMENT
                        | ash::vk::ImageUsageFlags::INPUT_ATTACHMENT
                        | ash::vk::ImageUsageFlags::SAMPLED
                        | ash::vk::ImageUsageFlags::TRANSFER_SRC
                        | ash::vk::ImageUsageFlags::TRANSFER_DST,
                )
                .map_err(|error| warn!(%error, width, height, "Stagecraft slice allocation failed"))
                .ok()?
        };
        let writer = SliceWriterVk {
            struct_size: 0,
            key: SliceKey {
                allocation: self.next_allocation.fetch_add(1, Ordering::Relaxed),
                generation: 1,
            },
            image: ash::vk::Handle::as_raw(image.image),
            image_view: ash::vk::Handle::as_raw(image.view),
            format: image.format.as_raw() as u32,
            layout: ash::vk::ImageLayout::UNDEFINED.as_raw() as u32,
            // A pooled image may be larger than asked for.
            width: image.size.0,
            height: image.size.1,
        };
        let slice = Slice {
            _bo: None,
            egl_image: 0,
            gl_texture: 0,
            image: Arc::new(image),
            engine_ref: true,
            last_serial: 0,
        };
        lock(&self.state)
            .slices
            .insert(writer.key.allocation, slice);
        Some(writer)
    }

    /// The engine composes a frame itself from composer storage. GLES is
    /// already ordered after every submission; the next submission must
    /// wait for this read.
    pub(super) fn prepare_gles_read(&self) {
        lock(&self.state).gles_read = true;
    }

    /// GLES presented an output frame fenced by `fence`.
    pub(super) fn gles_fenced(&self, fence: &OwnedFd) {
        let shared = share(fence);
        lock(&self.state).last_gles_fence = shared;
    }

    /// Blocks until every submission completed. Failure paths only.
    pub(super) fn wait_idle(&self) {
        let state = lock(&self.state);
        if let Some(fence) = &state.last_completion
            && !device::wait_fd(fence.as_fd(), -1)
        {
            tracing::error!("could not wait for Stagecraft's last submission");
        }
    }

    pub(super) fn take_staged(&self, view_id: i64) -> Option<Staged> {
        let mut state = lock(&self.state);
        if state
            .staged
            .as_ref()
            .is_some_and(|(_, staged)| staged.view_id == view_id)
        {
            state.staged.take().map(|(_, staged)| staged)
        } else {
            None
        }
    }

    /// What the next submission waits for on the GLES side: a fresh fence
    /// for GLES reads of composer storage or unwaited conversions, else the
    /// last output present's fence while it may still run.
    pub(super) fn producer_wait(&self) -> ProducerWait {
        let mut state = lock(&self.state);
        // Slices precede the submission on the same queue.
        if state.gles_read || lock(&self.converts).unwaited {
            return ProducerWait::Fresh;
        }
        match state.last_gles_fence.as_ref().and_then(share) {
            Some(fence) => ProducerWait::Existing(fence),
            None => {
                state.last_gles_fence = None;
                ProducerWait::None
            }
        }
    }

    /// Draws `staged` into `framebuffer` after `wait`. Returns the
    /// submission's completion, None when it already completed.
    ///
    /// A failed submission draws nothing and leaves the composer usable:
    /// the view's next frame redraws and reports everything, and waits for
    /// all GLES work. Only a lost device disables the composer.
    pub(super) fn submit(
        &self,
        staged: &mut Staged,
        framebuffer: u32,
        damage: FrameDamage<'_>,
        wait: Option<OwnedFd>,
    ) -> Result<Submitted, String> {
        let (mut state, result) = match self.lock_free_frame() {
            Ok(mut state) => {
                let result =
                    Self::submit_locked(&mut state, &self.gpu, staged, framebuffer, damage, wait);
                (state, result)
            }
            Err(error) => (lock(&self.state), Err(error)),
        };
        if result.is_err() {
            if device::device_lost() {
                state.broken = true;
            }
            state.unaccount(staged.view_id);
        } else {
            // `producer_wait` gave a fresh fence while conversions were
            // unwaited: this submission followed them.
            self.conversions_waited();
        }
        result
    }

    /// The state, once a frame is free to record or one more may be made.
    /// With every frame in flight, waits for the oldest outside the lock,
    /// for at most `FRAME_WAIT`: the GPU has stopped completing work.
    fn lock_free_frame(&self) -> Result<std::sync::MutexGuard<'_, State>, String> {
        let deadline = std::time::Instant::now() + FRAME_WAIT;
        loop {
            let mut state = lock(&self.state);
            if state.frames.len() < MAX_FRAMES || state.frames.iter_mut().any(Frame::idle) {
                return Ok(state);
            }
            if device::device_lost() {
                return Err("Stagecraft: device lost".into());
            }
            if std::time::Instant::now() >= deadline {
                return Err(format!(
                    "Stagecraft: no frame completed within {} ms",
                    FRAME_WAIT.as_millis()
                ));
            }
            let oldest = state
                .frames
                .iter()
                .min_by_key(|frame| frame.serial)
                .and_then(Frame::pending_completion);
            drop(state);
            let left = deadline.saturating_duration_since(std::time::Instant::now());
            let waited = match oldest {
                Some(completion) => device::wait_fd(
                    completion.as_fd(),
                    left.as_millis().min(i32::MAX as u128) as i32,
                ),
                // Tracked by its fence alone (its completion could not be
                // exported or copied): look again shortly.
                None => {
                    std::thread::sleep(left.min(std::time::Duration::from_millis(1)));
                    false
                }
            };
            if waited {
                // The sync file signals just before the fence: let the
                // fence catch up rather than spin on the lock.
                std::thread::yield_now();
            }
        }
    }

    fn submit_locked(
        state: &mut State,
        gpu: &Gpu,
        staged: &mut Staged,
        framebuffer: u32,
        damage: FrameDamage<'_>,
        wait: Option<OwnedFd>,
    ) -> Result<Submitted, String> {
        let target = state
            .targets
            .get(&framebuffer)
            .cloned()
            .ok_or("staged frame for an output buffer Stagecraft did not import")?;
        let index = match state.frames.iter_mut().position(Frame::idle) {
            Some(index) => index,
            None if state.frames.len() < MAX_FRAMES => {
                state.frames.push(Frame::new(gpu)?);
                state.frames.len() - 1
            }
            // `lock_free_frame` returns with a frame free or room for one.
            None => return Err("Stagecraft: every frame in flight".into()),
        };
        let (output_from_scene, size) = (staged.output_from_scene, target.size);
        let to_target = |rects| target_damage(rects, output_from_scene, size);
        let view_id = staged.view_id;
        let unaccounted = state.unaccounted.contains(&view_id);
        Self::resolve_frosts(state, gpu, staged, size)?;
        // What the frame redraws: the buffer's damage, and every frost made
        // again with all it reads, so its copy sees this frame below it
        // (outside the damage the target holds the previous frame, the
        // material's own glass included).
        //
        // A frost made again may change what its material draws beyond what
        // the engine reports (the composer's blur reaches past the engine's
        // readback bounds, and GLES drew the last frame differently): that
        // is reported as damage too, so the scanout copy and the other
        // buffers take it. The rest of its region is redrawn as it was. A
        // frame after one the composer did not draw redraws and reports the
        // whole target.
        let whole = [0, 0, size.0 as i32, size.1 as i32];
        let mut added = if unaccounted { whole } else { [0; 4] };
        let mut inputs = [0; 4];
        for step in &staged.steps {
            if let Step::Material(material) = step
                && material.fresh
            {
                added = record::pixels_union(added, staged.outputs[material.record as usize]);
                inputs = record::pixels_union(inputs, material.plan.region);
            }
        }
        // What changed in earlier frames, which this buffer has not shown
        // yet, is copied from the buffer shown last, which holds it: the
        // frame draws only its own damage. A wallpaper that changes the whole
        // screen would otherwise make the next frame draw everything again.
        let own =
            to_target(damage.frame).fold(record::pixels_union(added, inputs), record::pixels_union);
        let previous = state
            .shown
            .get(&view_id)
            .filter(|_| !state.redraw_catch_up && !record::pixels_empty(own));
        let mut repair_rects = Vec::new();
        if previous.is_some() {
            let own_f = own.map(|v| v as f32);
            let mut pieces = Vec::new();
            for rect in to_target(damage.buffer) {
                pieces.clear();
                record::rect_subtract(rect.map(|v| v as f32), own_f, &mut pieces);
                repair_rects.extend(pieces.iter().map(|piece| piece.map(|v| v as i32)));
            }
        }
        let area = match previous {
            Some(_) => own,
            None => to_target(damage.buffer).fold(own, record::pixels_union),
        };
        let repair = previous.map(|source| device::Repair {
            source,
            rects: &repair_rects,
        });
        // Client buffers pass to the composer and back to their owner in
        // each submission; one still running may not have handed back what
        // this one takes: start after it. (A GLES wait already follows it.)
        let wait = wait.or_else(|| state.last_completion.as_ref().and_then(share));
        let serial = state.serial + 1;
        let completion = state.frames[index].submit(
            serial,
            &target,
            &staged.draws,
            &staged.glasses,
            &staged.clips,
            &staged.edges,
            &staged.merges,
            &staged.steps,
            &staged.uploads,
            area,
            repair,
            wait,
        )?;
        state.serial = serial;
        state.shown.insert(view_id, Arc::clone(&target));
        state.tally.repaired += u64::from(!repair_rects.is_empty());
        let coverage = |rect: [i32; 4]| {
            if record::pixels_empty(rect) {
                0.0
            } else {
                f64::from(rect[2] - rect[0]) * f64::from(rect[3] - rect[1])
                    / (f64::from(size.0) * f64::from(size.1)).max(1.0)
            }
        };
        let engine_damage = to_target(damage.frame).map(coverage).sum::<f64>().min(1.0);
        state
            .tally
            .vulkan(staged, area, target.size, engine_damage, coverage(added));
        crate::client_visibility::composed(
            staged.view_id,
            &staged.shown_textures,
            &staged.hidden_textures,
        );
        state.gles_read = false;
        state.last_gles_fence = None;
        for key in &staged.slices {
            if let Some(slice) = state.slices.get_mut(&key.allocation) {
                slice.last_serial = serial;
            }
        }
        for upload in &staged.uploads {
            if let Some(import) = state
                .uploads
                .values_mut()
                .find(|import| Arc::ptr_eq(&import.image, &upload.image))
            {
                import.pixels = Some(upload.frame.pixels_id());
            }
        }
        // The merged images now hold these layers.
        for window in staged
            .merged_windows
            .drain(..)
            .filter(|window| window.drawn)
        {
            state
                .merged
                .insert(window.texture_id, (window.image, Some(window.keys)));
        }
        let mut sampled = |image: &Arc<Image>| {
            for import in state.clients.values_mut() {
                if Arc::ptr_eq(&import.image, image) {
                    import.last_serial = serial;
                }
            }
            for import in state.uploads.values_mut() {
                if Arc::ptr_eq(&import.image, image) {
                    import.last_serial = serial;
                }
            }
        };
        for batch in staged.merges.iter().flat_map(|merge| &merge.batches) {
            sampled(&batch.image);
        }
        for step in &staged.steps {
            match step {
                Step::Draws(batch) => sampled(&batch.image),
                Step::Material(material) => {
                    if let Some(window) = &material.window {
                        sampled(&window.image);
                    }
                    if let Some(frost) = &material.frost {
                        state.frosts.insert(
                            (staged.view_id, material.record),
                            CachedFrost {
                                frost: Arc::clone(frost),
                                plan: material.plan,
                                backdrop_token: staged.backdrop_tokens[material.record as usize],
                                engine_token: staged.engine_tokens[material.record as usize],
                                below: material.below,
                                made: material.made,
                            },
                        );
                    }
                }
            }
        }
        // Materials this view no longer shows.
        let count = staged.glasses.len() as u32;
        state
            .frosts
            .retain(|&(view, order), _| view != staged.view_id || order < count);
        state.last_completion = completion.as_ref().and_then(share);
        if staged.scene_revision & ENGINE_COMPOSED != 0 {
            // The engine drew this frame: the next one the composer draws
            // redraws and reports the whole target, so no pixels of two
            // renderers mix.
            state.unaccount(view_id);
        } else {
            state.unaccounted.retain(|&view| view != view_id);
        }
        let added = (!record::pixels_empty(added))
            .then(|| scene_rect(&output_from_scene, added))
            .flatten();
        Ok(Submitted { completion, added })
    }

    /// Gives every material its frost: the cached one when what it reads is
    /// unchanged, else images to make it in (the cached ones when their
    /// sizes fit).
    ///
    /// A frost copies the target where its material reads, as the steps
    /// below the material drew it. A tracked backdrop token says whether
    /// that changed. Else the frost keeps a fingerprint of those steps:
    /// each draw's record, clips and image content (a slice's version, a
    /// client's buffer revision), and each lower material's glass and the
    /// submission its frost was made for. Changes above a material, which
    /// the engine's damage also reports, leave its frost as it is.
    fn resolve_frosts(
        state: &State,
        gpu: &Gpu,
        staged: &mut Staged,
        size: (u32, u32),
    ) -> Result<(), String> {
        // The submission this frame becomes.
        let serial = state.serial + 1;
        let Staged {
            view_id,
            draws,
            glasses,
            clips,
            edges,
            steps,
            backdrop_tokens,
            outputs,
            remade_why,
            frosts_allocated,
            ..
        } = staged;
        // What each step drew so far, in paint order: where, and a
        // fingerprint of what.
        let mut drawn: Vec<([i32; 4], u64)> = Vec::new();
        // What materials whose frosts are made this frame draw: a tracked
        // token does not see it change.
        let mut remade: Vec<[i32; 4]> = Vec::new();
        for step in steps.iter_mut() {
            let material = match step {
                Step::Draws(batch) => {
                    let range = batch.first as usize..(batch.first + batch.count) as usize;
                    for draw in &draws[range] {
                        let mut fingerprint = DefaultHasher::new();
                        fingerprint.write_u64(batch.content);
                        fingerprint.write_usize(Arc::as_ptr(&batch.look) as usize);
                        fingerprint.write_u8(u8::from(batch.nearest));
                        draw.hash_into(clips, edges, &mut fingerprint);
                        drawn.push((draw.bounds(size), fingerprint.finish()));
                    }
                    continue;
                }
                Step::Material(material) => material,
            };
            let record = material.record as usize;
            if let Some((_, content)) = &material.frozen {
                // No frost to make: what it draws is its record and frost.
                let mut fingerprint = DefaultHasher::new();
                fingerprint.write_u64(*content);
                glasses[record].hash_into(clips, edges, &mut fingerprint);
                drawn.push((outputs[record], fingerprint.finish()));
                continue;
            }
            let region = material.plan.region;
            let mut below = DefaultHasher::new();
            for &(_, fingerprint) in drawn
                .iter()
                .filter(|(bounds, _)| record::pixels_overlap(*bounds, region))
            {
                below.write_u64(fingerprint);
            }
            let below = below.finish();
            let token = backdrop_tokens[record];
            let cached = state.frosts.get(&(*view_id, material.record));
            let below_changed = remade
                .iter()
                .any(|&output| record::pixels_overlap(output, region));
            let unchanged = |cached: &CachedFrost| match token {
                Some(_) => cached.backdrop_token == token,
                None => cached.below == below,
            };
            // Diagnostic: why a cached frost is made again.
            remade_why[match cached {
                Some(_) if below_changed => 0,
                Some(cached) if cached.plan != material.plan => 1,
                Some(cached) if !unchanged(cached) => 2 + usize::from(token.is_none()),
                Some(_) => 4,
                None => 5,
            }] += 1;
            let (frost, kept) = match cached {
                Some(cached)
                    if !below_changed && cached.plan == material.plan && unchanged(cached) =>
                {
                    (Arc::clone(&cached.frost), Some(cached.made))
                }
                Some(cached) if cached.frost.fits(&material.plan) => {
                    (Arc::clone(&cached.frost), None)
                }
                _ => {
                    *frosts_allocated += 1;
                    (Arc::new(Frost::with_room(gpu, material.plan)?), None)
                }
            };
            if kept.is_none() {
                remade.push(outputs[record]);
            }
            glasses[record].place_frost(&material.plan, frost.last_storage());
            material.frost = Some(frost);
            material.fresh = kept.is_none();
            material.below = below;
            material.made = kept.unwrap_or(serial);
            // What the material draws, for the materials above it.
            let mut fingerprint = DefaultHasher::new();
            fingerprint.write_u64(material.made);
            glasses[record].hash_into(clips, edges, &mut fingerprint);
            let mut bounds = outputs[record];
            if let Some(window) = &material.window {
                let draw = &draws[window.draw as usize];
                fingerprint.write_u64(window.content);
                fingerprint.write_usize(Arc::as_ptr(&window.look) as usize);
                fingerprint.write_u8(u8::from(window.nearest));
                draw.hash_into(clips, edges, &mut fingerprint);
                bounds = record::pixels_union(bounds, draw.bounds(size));
            }
            drawn.push((bounds, fingerprint.finish()));
        }
        Ok(())
    }

    /// Destroys every GL object. Render-thread shutdown, context current.
    pub(super) fn shutdown(&self, gl: &super::GlApi, display: &super::EGLDisplayHandle) {
        let mut state = lock(&self.state);
        state.staged = None;
        // Frames wait for their submissions as they drop.
        state.frames.clear();
        for (_, slice) in state.slices.drain() {
            destroy_gl(gl, display, &slice);
        }
        state.clients.clear();
        state.uploads.clear();
        state.frosts.clear();
        state.shown.clear();
        state.targets.clear();
        drop(state);
        self.shutdown_conversions(gl, display);
    }
}

/// What a pooled slice image holds, RGBA8.
fn slice_bytes(image: &Image) -> u64 {
    u64::from(image.size.0) * u64::from(image.size.1) * 4
}

fn destroy_gl(gl: &super::GlApi, display: &super::EGLDisplayHandle, slice: &Slice) {
    if slice.egl_image == 0 {
        return;
    }
    // SAFETY: the raster context is current; the engine no longer uses the
    // texture (drop_engine_ref) and GL keeps storage alive for its own queued
    // commands.
    unsafe {
        if slice.gl_texture != 0 {
            (gl.delete_textures)(1, &slice.gl_texture);
        }
        smithay::backend::egl::ffi::egl::DestroyImageKHR(
            display.handle,
            slice.egl_image as *const std::ffi::c_void,
        );
    }
}

/// What a submission waits for on the GLES side.
pub(super) enum ProducerWait {
    None,
    /// Create, flush and export a fence now.
    Fresh,
    /// The last output present's fence.
    Existing(OwnedFd),
}

/// What a client texture resolves to for one frame.
pub(super) enum Client {
    /// The texture has no image: nothing is drawn (a window keeps its frame).
    Missing,
    /// A native window's surfaces, merged into an image of its own.
    Merged {
        placement: Placement,
        merged: MergedClient,
        look: Option<Arc<Lut>>,
    },
    /// `sampled.source` holds the pixels: a DMA-BUF or SHM.
    Image {
        placement: Placement,
        sampled: SampledClient,
        /// The app's look, graded as the client is sampled.
        look: Option<Arc<Lut>>,
    },
    /// A buffer neither the composer nor GLES can read: not drawn, as the
    /// GLES pass leaves it out, and still counted as shown so the texture
    /// moves on to its next buffer.
    Omitted(SampledClient),
    /// `sampled`'s pixels as GLES grades them, drawn into `image`
    /// (`SceneComposer::converted`).
    Converted {
        placement: Placement,
        sampled: SampledClient,
        image: Arc<Image>,
    },
}

impl Client {
    /// What the client's image holds: equal values, equal pixels.
    fn content(&self) -> u64 {
        let mut content = DefaultHasher::new();
        match self {
            Self::Missing | Self::Omitted(_) => {}
            Self::Image { sampled, .. } | Self::Converted { sampled, .. } => {
                sampled.hash_content(&mut content);
            }
            Self::Merged { merged, .. } => {
                for layer in &merged.layers {
                    layer.sampled.hash_content(&mut content);
                    let values = layer.quad.iter().chain(layer.uv.iter().flatten());
                    for value in values.chain(&layer.limits).chain([&layer.opacity]) {
                        content.write_u32(value.to_bits());
                    }
                }
            }
        }
        content.finish()
    }

    /// The client's surface declared its pixels opaque through its opaque
    /// region: it hides what lies under it even when its buffer's format
    /// carries alpha.
    fn declared_opaque(&self) -> bool {
        match self {
            Self::Image { sampled, .. } | Self::Converted { sampled, .. } => {
                sampled.source.opaque()
            }
            Self::Missing | Self::Merged { .. } | Self::Omitted(_) => false,
        }
    }
}

/// What the handler resolves while the composer stages a scene. Neither
/// call may take the composer's state, which `stage` holds.
pub(super) trait Resolve {
    /// What texture `texture_id` shows within `bounds`.
    fn client(&mut self, texture_id: i64, bounds: Rect) -> Result<Client, Decline>;
    /// `sampled` copied by GLES into an image the composer samples, for a
    /// buffer the composer could not import or upload; None when GLES
    /// cannot read it either, so the GLES pass leaves it out too.
    fn copy(&mut self, sampled: &SampledClient) -> Result<Option<Arc<Image>>, Decline>;
}

/// A native window whose layers the composer merges, as the GLES pass
/// does: each layer's client drawn into the window's `size` image.
pub(super) struct MergedClient {
    pub(super) texture_id: i64,
    pub(super) size: (u32, u32),
    pub(super) layers: Vec<MergedLayer>,
    /// Current buffers of layers outside the image: not drawn, still shown.
    pub(super) unseen: Vec<SampledClient>,
}

/// One merged layer: its client, the image pixels it covers (`quad`), its
/// normalized texture coordinates at the quad's upper left, upper right
/// and lower left corners, the texel limits it samples within and its
/// opacity.
pub(super) struct MergedLayer {
    pub(super) sampled: SampledClient,
    pub(super) quad: [f32; 4],
    pub(super) uv: [[f32; 2]; 3],
    pub(super) limits: [f32; 4],
    pub(super) opacity: f32,
    /// What changed between the client's recent buffers.
    pub(super) history: super::DamageHistory,
}

impl MergedLayer {
    /// The image pixels that show `rects` of the client's buffer, as bounds
    /// `[left, top, right, bottom]` one pixel wider, for filtering, and
    /// within the quad; None when the mapping is degenerate.
    fn shown(&self, rects: &[[i32; 4]]) -> Option<[f64; 4]> {
        let (width, height) = self.sampled.source.pixel_size();
        let [upper_left, upper_right, lower_left] =
            self.uv.map(|[u, v]| [f64::from(u), f64::from(v)]);
        // The quad's corners sample these points: solve a point's position
        // along the quad's two edges from its texture coordinates.
        let across = [
            upper_right[0] - upper_left[0],
            upper_right[1] - upper_left[1],
        ];
        let down = [lower_left[0] - upper_left[0], lower_left[1] - upper_left[1]];
        let determinant = across[0] * down[1] - across[1] * down[0];
        if determinant.abs() < 1e-12 || width == 0 || height == 0 {
            return None;
        }
        let [left, top, right, bottom] = self.quad.map(f64::from);
        let position = |x: f64, y: f64| {
            let point = [
                x / f64::from(width) - upper_left[0],
                y / f64::from(height) - upper_left[1],
            ];
            let s = (point[0] * down[1] - point[1] * down[0]) / determinant;
            let t = (across[0] * point[1] - across[1] * point[0]) / determinant;
            [left + s * (right - left), top + t * (bottom - top)]
        };
        let mut bounds = [
            f64::INFINITY,
            f64::INFINITY,
            f64::NEG_INFINITY,
            f64::NEG_INFINITY,
        ];
        for &[x, y, w, h] in rects {
            let (x, y, w, h) = (f64::from(x), f64::from(y), f64::from(w), f64::from(h));
            for [px, py] in [
                position(x, y),
                position(x + w, y),
                position(x, y + h),
                position(x + w, y + h),
            ] {
                bounds = [
                    bounds[0].min(px),
                    bounds[1].min(py),
                    bounds[2].max(px),
                    bounds[3].max(py),
                ];
            }
        }
        Some([
            (bounds[0] - 1.0).max(left.min(right)),
            (bounds[1] - 1.0).max(top.min(bottom)),
            (bounds[2] + 1.0).min(left.max(right)),
            (bounds[3] + 1.0).min(top.max(bottom)),
        ])
    }
}

/// The storage a client's pixels live in, without keeping it.
#[derive(Clone, PartialEq)]
enum Backing {
    Dmabuf(smithay::backend::allocator::dmabuf::WeakDmabuf),
    Shm(super::ShmPixelsId),
}

/// What a merged image shows of one layer: its client's storage and
/// generation (revisions count per kind of buffer), and where it lands.
#[derive(Clone, PartialEq)]
struct MergeKey {
    texture_id: i64,
    backing: Backing,
    generation: u64,
    quad: [f32; 4],
    uv: [[f32; 2]; 3],
    limits: [f32; 4],
    opacity: f32,
}

impl Backing {
    fn of(source: &super::ExternalTextureSource) -> Self {
        match source {
            super::ExternalTextureSource::Dmabuf { dmabuf, .. } => Self::Dmabuf(dmabuf.weak()),
            super::ExternalTextureSource::Shm(frame) => Self::Shm(frame.pixels_id()),
        }
    }
}

impl MergeKey {
    fn new(layer: &MergedLayer) -> Self {
        Self {
            texture_id: layer.sampled.texture_id,
            backing: Backing::of(&layer.sampled.source),
            generation: layer.sampled.generation,
            quad: layer.quad,
            uv: layer.uv,
            limits: layer.limits,
            opacity: layer.opacity,
        }
    }
}

/// Why a frame stays with the engine.
pub(super) type Decline = &'static str;

/// A client buffer as the composer reads it.
enum Resolved {
    /// Imported or uploaded.
    Read(Arc<Image>),
    /// Copied by GLES (`Resolve::copy`).
    Copied(Arc<Image>),
    /// Neither the composer nor GLES can read it.
    Unreadable,
}

/// Merged native window images the composer keeps, as the GLES pool's
/// budget.
const MERGED_BYTES: u64 = 512 << 20;

fn image_bytes((width, height): (u32, u32)) -> u64 {
    u64::from(width) * u64::from(height) * 4
}

/// The pixels of a merged image that change from the layers it `held` to
/// `keys`, `[x, y, width, height]`: None when the whole image is drawn
/// again, Some(None) when nothing that shows changed.
fn changed_area(
    held: &[MergeKey],
    keys: &[MergeKey],
    layers: &[MergedLayer],
    (width, height): (u32, u32),
) -> Option<Option<[u32; 4]>> {
    if held.len() != keys.len() {
        return None;
    }
    let mut bounds: Option<[f64; 4]> = None;
    for ((held, key), layer) in held.iter().zip(keys).zip(layers) {
        if held == key {
            continue;
        }
        // Only a new buffer in the same place, both DMA-BUFs: their
        // generations name one history.
        let same_place = held.texture_id == key.texture_id
            && held.quad == key.quad
            && held.uv == key.uv
            && held.limits == key.limits
            && held.opacity == key.opacity
            && matches!(
                (&held.backing, &key.backing),
                (Backing::Dmabuf(_), Backing::Dmabuf(_))
            );
        if !same_place {
            return None;
        }
        let rects = layer.history.between(held.generation, key.generation)?;
        if rects.is_empty() {
            continue;
        }
        let [left, top, right, bottom] = layer.shown(&rects)?;
        if right <= left || bottom <= top {
            continue;
        }
        bounds = Some(match bounds {
            None => [left, top, right, bottom],
            Some(b) => [
                b[0].min(left),
                b[1].min(top),
                b[2].max(right),
                b[3].max(bottom),
            ],
        });
    }
    let Some([left, top, right, bottom]) = bounds else {
        return Some(None);
    };
    let left = left.floor().clamp(0.0, f64::from(width)) as u32;
    let top = top.floor().clamp(0.0, f64::from(height)) as u32;
    let right = right.ceil().clamp(0.0, f64::from(width)) as u32;
    let bottom = bottom.ceil().clamp(0.0, f64::from(height)) as u32;
    if right <= left || bottom <= top {
        return Some(None);
    }
    Some(Some([left, top, right - left, bottom - top]))
}

/// Declines a scene whose texture shows other pixels than where it was
/// drawn before in it: draws share one image per texture, and the handler
/// credits each staged generation as sampled.
fn resolved_once(staged: &Staged, sampled: &SampledClient) -> Result<(), Decline> {
    let changed = staged
        .clients
        .iter()
        .chain(&staged.credits)
        .chain(&staged.omitted)
        .any(|seen| {
            seen.texture_id == sampled.texture_id && !seen.source.same_generation(&sampled.source)
        });
    if changed {
        return Err("texture changed while staging");
    }
    Ok(())
}

impl SceneComposer {
    /// The image showing a client's pixels: its DMA-BUF imported, or its
    /// SHM pixels copied into an image of the texture's own (queued in
    /// `uploads` unless the image holds them already).
    fn client_image(
        &self,
        state: &mut State,
        uploads: &mut Vec<Upload>,
        sampled: &SampledClient,
        resolve: &mut dyn Resolve,
    ) -> Result<Resolved, Decline> {
        let dmabuf = match &sampled.source {
            super::ExternalTextureSource::Dmabuf { dmabuf, .. } => dmabuf,
            super::ExternalTextureSource::Shm(frame) => {
                return match self.shm_image(state, uploads, sampled.texture_id, frame) {
                    Ok(image) => Ok(Resolved::Read(image)),
                    Err(_) => Self::copied(resolve, sampled),
                };
            }
        };
        let weak = dmabuf.weak();
        if let Some(import) = state.clients.get(&weak) {
            return Ok(Resolved::Read(Arc::clone(&import.image)));
        }
        let image = match self.gpu.import(dmabuf, Usage::Sampled) {
            Ok(image) => image,
            Err(error) => {
                tracing::debug!(%error, "client buffer copied by GLES for Stagecraft");
                return Self::copied(resolve, sampled);
            }
        };
        state.clients.insert(
            weak,
            ClientImport {
                image: Arc::clone(&image),
                last_serial: state.serial,
            },
        );
        Ok(Resolved::Read(image))
    }

    fn copied(resolve: &mut dyn Resolve, sampled: &SampledClient) -> Result<Resolved, Decline> {
        Ok(match resolve.copy(sampled)? {
            Some(image) => Resolved::Copied(image),
            None => Resolved::Unreadable,
        })
    }

    fn shm_image(
        &self,
        state: &mut State,
        uploads: &mut Vec<Upload>,
        texture_id: i64,
        frame: &super::ShmTextureFrame,
    ) -> Result<Arc<Image>, Decline> {
        let size = (frame.width(), frame.height());
        if state
            .uploads
            .get(&texture_id)
            .is_none_or(|import| import.image.size != size)
        {
            let image = self.gpu.upload_image(size).map_err(|error| {
                tracing::warn!(%error, "SHM client stays on GLES composition");
                "SHM image"
            })?;
            state.uploads.insert(
                texture_id,
                ShmImport {
                    image,
                    pixels: None,
                    last_serial: state.serial,
                },
            );
        }
        let import = &state.uploads[&texture_id];
        let image = Arc::clone(&import.image);
        // One copy per image and frame: a texture drawn twice shows the
        // first pixels it resolved to.
        let queued = uploads
            .iter()
            .any(|upload| Arc::ptr_eq(&upload.image, &image));
        if !queued
            && !import
                .pixels
                .as_ref()
                .is_some_and(|pixels| pixels.names(frame))
        {
            uploads.push(Upload {
                image: Arc::clone(&image),
                frame: frame.clone(),
                fresh: import.pixels.is_none(),
            });
        }
        Ok(image)
    }

    /// The image a texture or window entry samples, with where it lands and
    /// its look; None when the texture has no image. Credits what the
    /// frame shows to `staged`.
    fn resolved_image(
        &self,
        state: &mut State,
        staged: &mut Staged,
        client: Client,
        resolve: &mut dyn Resolve,
    ) -> Result<Option<(Arc<Image>, Placement, Option<Arc<Lut>>)>, Decline> {
        match client {
            Client::Missing => Ok(None),
            Client::Image {
                placement,
                sampled,
                look,
            } => {
                resolved_once(staged, &sampled)?;
                match self.client_image(state, &mut staged.uploads, &sampled, resolve)? {
                    Resolved::Read(image) => {
                        staged.clients.push(sampled);
                        Ok(Some((image, placement, look)))
                    }
                    // GLES read it; the pool holds the buffer until a
                    // present follows that read.
                    Resolved::Copied(image) => {
                        staged.converted += 1;
                        staged.credits.push(sampled);
                        Ok(Some((image, placement, look)))
                    }
                    Resolved::Unreadable => {
                        staged.omitted.push(sampled);
                        Ok(None)
                    }
                }
            }
            Client::Omitted(sampled) => {
                resolved_once(staged, &sampled)?;
                staged.omitted.push(sampled);
                Ok(None)
            }
            Client::Converted {
                placement,
                sampled,
                image,
            } => {
                resolved_once(staged, &sampled)?;
                staged.converted += 1;
                staged.credits.push(sampled);
                Ok(Some((image, placement, None)))
            }
            Client::Merged {
                placement,
                merged,
                look,
            } => Ok(Some((
                self.merged_image(state, staged, merged, resolve)?,
                placement,
                look,
            ))),
        }
    }

    /// A native window's merged image: the one a submission drew when its
    /// layers are unchanged, else drawn again before this frame.
    fn merged_image(
        &self,
        state: &mut State,
        staged: &mut Staged,
        merged: MergedClient,
        resolve: &mut dyn Resolve,
    ) -> Result<Arc<Image>, Decline> {
        let keys: Vec<MergeKey> = merged.layers.iter().map(MergeKey::new).collect();
        // Shown twice in one frame: the first resolution stands.
        if let Some(window) = staged
            .merged_windows
            .iter()
            .find(|window| window.texture_id == merged.texture_id)
        {
            if window.keys != keys || window.image.size != merged.size {
                return Err("texture changed while staging");
            }
            return Ok(Arc::clone(&window.image));
        }
        let cached = state
            .merged
            .get(&merged.texture_id)
            .filter(|(image, _)| image.size == merged.size);
        if let Some((image, Some(held))) = cached
            && *held == keys
        {
            let image = Arc::clone(image);
            staged
                .credits
                .extend(merged.layers.into_iter().map(|layer| layer.sampled));
            staged.credits.extend(merged.unseen);
            staged.merges_reused += 1;
            staged.merged_windows.push(MergedWindow {
                texture_id: merged.texture_id,
                keys,
                image: Arc::clone(&image),
                drawn: false,
            });
            return Ok(image);
        }
        // What changed since the image was last drawn, when only its
        // layers' buffers did: the rest of the image stays.
        let area = match cached {
            Some((image, Some(held))) => changed_area(held, &keys, &merged.layers, image.size),
            _ => None,
        };
        if let Some(None) = area {
            // Nothing that shows changed.
            let image = Arc::clone(&cached.expect("changed from a drawn image").0);
            staged
                .credits
                .extend(merged.layers.into_iter().map(|layer| layer.sampled));
            staged.credits.extend(merged.unseen);
            staged.merges_reused += 1;
            staged.merged_windows.push(MergedWindow {
                texture_id: merged.texture_id,
                keys,
                image: Arc::clone(&image),
                drawn: true,
            });
            return Ok(image);
        }
        let area = area.flatten();
        let image = match cached {
            Some((image, _)) => Arc::clone(image),
            None => {
                // Merged images in the cache, the one this replaces aside.
                let held: u64 = state
                    .merged
                    .iter()
                    .filter(|(texture_id, _)| **texture_id != merged.texture_id)
                    .map(|(_, (image, _))| image_bytes(image.size))
                    .sum();
                if held + image_bytes(merged.size) > MERGED_BYTES {
                    return Err("merged window memory");
                }
                self.gpu.merge_image(merged.size).map_err(|error| {
                    tracing::warn!(%error, "native window stays on GLES composition");
                    "merged window image"
                })?
            }
        };
        let mut batches: Vec<Batch> = Vec::with_capacity(merged.layers.len());
        for layer in merged.layers {
            resolved_once(staged, &layer.sampled)?;
            let (input, copied) =
                match self.client_image(state, &mut staged.uploads, &layer.sampled, resolve)? {
                    Resolved::Read(image) => (image, false),
                    Resolved::Copied(image) => (image, true),
                    // The GLES merge cannot read it either and leaves the
                    // window to its surfaces.
                    Resolved::Unreadable => return Err("native window input GLES cannot read"),
                };
            let draw = record::merged_layer(
                merged.size,
                layer.quad,
                layer.uv,
                layer.limits,
                layer.opacity,
            )
            .ok_or("merged layer")?;
            let index = staged.draws.len() as u32;
            staged.draws.push(draw);
            match batches.last_mut() {
                Some(last) if Arc::ptr_eq(&last.image, &input) => last.count += 1,
                _ => batches.push(Batch {
                    image: input,
                    look: Arc::clone(&self.no_look),
                    nearest: false,
                    first: index,
                    count: 1,
                    content: 0,
                }),
            }
            if copied {
                staged.converted += 1;
                staged.credits.push(layer.sampled);
            } else {
                staged.clients.push(layer.sampled);
            }
        }
        staged.credits.extend(merged.unseen);
        staged.merges.push(Merge {
            image: Arc::clone(&image),
            batches,
            area,
        });
        // The cache takes the image once a submission drew it.
        staged.merged_windows.push(MergedWindow {
            texture_id: merged.texture_id,
            keys,
            image: Arc::clone(&image),
            drawn: true,
        });
        Ok(image)
    }

    /// The image for a client's look; the stand-in for none.
    fn look_image(
        &self,
        state: &mut State,
        look: Option<&Arc<Lut>>,
    ) -> Result<Arc<Image>, Decline> {
        let Some(look) = look else {
            return Ok(Arc::clone(&self.no_look));
        };
        if let Some((_, image)) = state
            .looks
            .iter()
            .find(|(held, _)| std::ptr::eq(held.as_ptr(), Arc::as_ptr(look)))
        {
            return Ok(Arc::clone(image));
        }
        let size = u32::try_from(look.size).map_err(|_| "app look size")?;
        let image = self.gpu.look_image(size, &look.texels).map_err(|error| {
            tracing::warn!(%error, "app look stays on GLES composition");
            "app look upload"
        })?;
        state.looks.push((Arc::downgrade(look), Arc::clone(&image)));
        Ok(image)
    }

    /// Copies the engine's scene and builds its draws. `resolve` gives each
    /// texture's image as the engine would paint it; `copyable` says whether
    /// materials can copy from the view's output buffers. On success the
    /// frame waits for its view's root present.
    pub(super) fn stage(
        &self,
        source: SceneSource<'_>,
        (width, height): (u32, u32),
        copyable: bool,
        resolve: &mut dyn Resolve,
    ) -> Result<(), Decline> {
        let mut state = lock(&self.state);
        if state.broken || source.ticket() != state.ticket {
            return Err("stale ticket");
        }
        let mut scene = std::mem::take(&mut state.scratch);
        // Looks that are gone; frames in flight keep their images.
        state.looks.retain(|(look, _)| look.strong_count() > 0);
        let result = (|| {
            if !source.copy_into(&mut scene) {
                return Err("scene Stagecraft cannot describe");
            }
            let ndc_from_target = record::ndc_from_target(width, height);
            let ndc_from_scene = ndc_from_target.then(&scene.output_from_scene);
            let scene_from_target = scene
                .output_from_scene
                .inverse()
                .ok_or("output transform")?;
            let mut staged = Staged {
                view_id: scene.view_id,
                output_from_scene: scene.output_from_scene,
                scene_revision: scene.revision,
                draws: Vec::with_capacity(scene.entries.len() + scene.blits.len()),
                glasses: Vec::new(),
                clips: Vec::new(),
                edges: scene.path_edges.clone(),
                steps: Vec::new(),
                backdrop_tokens: Vec::new(),
                engine_tokens: Vec::new(),
                outputs: Vec::new(),
                remade_why: [0; 6],
                frosts_allocated: 0,
                slices: Vec::new(),
                slices_rewritten: scene.rewritten.len() as u32,
                clients: Vec::new(),
                credits: Vec::new(),
                omitted: Vec::new(),
                uploads: Vec::new(),
                merges: Vec::new(),
                merged_windows: Vec::new(),
                merges_reused: 0,
                converted: 0,
                covers: Vec::new(),
                culled_draws: 0,
                culled_materials: 0,
                split_draws: 0,
                client_draws: Vec::new(),
                shown_textures: Vec::new(),
                hidden_textures: Vec::new(),
                full_cover: None,
            };
            let push = |staged: &mut Staged,
                        draw: Draw,
                        image: &Arc<Image>,
                        content: u64,
                        look: &Arc<Image>,
                        nearest: bool| {
                let index = staged.draws.len() as u32;
                staged.draws.push(draw);
                if let Some(Step::Draws(last)) = staged.steps.last_mut()
                    && Arc::ptr_eq(&last.image, image)
                    && last.content == content
                    && Arc::ptr_eq(&last.look, look)
                    && last.nearest == nearest
                    && last.first + last.count == index
                {
                    last.count += 1;
                    return;
                }
                staged.steps.push(Step::Draws(Batch {
                    image: Arc::clone(image),
                    look: Arc::clone(look),
                    nearest,
                    first: index,
                    count: 1,
                    content,
                }));
            };
            // Each entry's clips, reduced to what the shaders evaluate and
            // stored once in the frame's clip buffer; consecutive entries
            // with the same clips share them.
            let screen = record::screen_in_scene(&scene.output_from_scene, (width, height));
            let mut reduced = Vec::new();
            let mut last_clips = ClipSpan::default();
            let mut reduce = |range: std::ops::Range<usize>, records: &mut Vec<ClipRecord>| {
                record::reduce_clips(&scene.clips[range], screen, &mut reduced);
                last_clips = record::intern_clips(&reduced, last_clips, records);
                last_clips
            };
            // Open materials, innermost last: the clips and opacity of the
            // slices they contain. Cuts inside carry the material's mutators
            // in their own.
            let mut open: Vec<(ClipSpan, f32)> = Vec::new();
            for entry in &scene.entries {
                match entry {
                    SceneEntry::Slice {
                        key,
                        bottom_up,
                        storage_width,
                        storage_height,
                        linear,
                        opacity,
                        blits,
                    } => {
                        let slice = state.slices.get(&key.allocation).ok_or("unknown slice")?;
                        if slice.image.size != (*storage_width, *storage_height) {
                            return Err("slice storage size");
                        }
                        let image = Arc::clone(&slice.image);
                        let content = slice_content(key);
                        staged.slices.push(*key);
                        for blit in &scene.blits[blits.clone()] {
                            let mut draw =
                                record::slice_blit(blit, image.size, *bottom_up, &ndc_from_target);
                            record::fade(&mut draw, *opacity);
                            if let Some(&(clips, opacity)) = open.last() {
                                record::inside_material(
                                    &mut draw,
                                    clips,
                                    opacity,
                                    &scene_from_target,
                                );
                            }
                            push(&mut staged, draw, &image, content, &self.no_look, !*linear);
                        }
                    }
                    SceneEntry::Texture {
                        texture_id,
                        bounds,
                        local,
                    } => {
                        let clips = reduce(local.clips.clone(), &mut staged.clips);
                        let client = resolve.client(*texture_id, *bounds)?;
                        let content = client.content();
                        let declared_opaque = client.declared_opaque();
                        let Some((image, placement, look)) =
                            self.resolved_image(&mut state, &mut staged, client, resolve)?
                        else {
                            continue;
                        };
                        let opaque = image.opaque || declared_opaque;
                        let look_image = self.look_image(&mut state, look.as_ref())?;
                        let draw =
                            record::texture(local, clips, &ndc_from_scene, &placement, image.size)
                                .ok_or("texture transform")?
                                .with_look(look.is_some());
                        staged.note_cover(&draw, (width, height), || {
                            draw.why_no_cover(opaque, None, (width, height))
                        });
                        let index = staged.draws.len() as u32;
                        staged.client_draws.push((
                            crate::flutter_runtime::renderer::native_window::surface_texture(
                                *texture_id,
                            ),
                            index,
                        ));
                        if opaque {
                            for cover in draw.opaque(None, (width, height)).into_iter().flatten() {
                                staged.covers.push((index, cover));
                            }
                        }
                        push(
                            &mut staged,
                            draw,
                            &image,
                            content,
                            &look_image,
                            local.sampling == Sampling::Nearest,
                        );
                    }
                    SceneEntry::Window {
                        texture_id,
                        texture_bounds,
                        texture_transform,
                        surface_opacity,
                        style,
                        backdrop,
                        local,
                    } => {
                        let clips = reduce(local.clips.clone(), &mut staged.clips);
                        let client = resolve.client(*texture_id, *texture_bounds)?;
                        let content = client.content();
                        let declared_opaque = client.declared_opaque();
                        let (image, look) =
                            match self.resolved_image(&mut state, &mut staged, client, resolve)? {
                                Some((image, placement, look)) => (Some((image, placement)), look),
                                None => (None, None),
                            };
                        let look_image = self.look_image(&mut state, look.as_ref())?;
                        let draw = record::window(
                            local,
                            clips,
                            &ndc_from_scene,
                            style,
                            texture_transform,
                            *surface_opacity,
                            image
                                .as_ref()
                                .map(|(image, placement)| (placement, image.size)),
                        )
                        .ok_or("window transform")?
                        .with_look(look.is_some());
                        // A frame without a surface samples nothing; the
                        // previous image or the placeholder keeps the
                        // descriptor valid.
                        let bound = match &image {
                            Some((image, _)) => Arc::clone(image),
                            None => match staged.steps.last() {
                                Some(Step::Draws(batch)) => Arc::clone(&batch.image),
                                _ => Arc::clone(&self.placeholder),
                            },
                        };
                        let nearest = local.sampling == Sampling::Nearest;
                        let behind = match backdrop {
                            Some(material) => {
                                if !copyable {
                                    return Err("output buffer Stagecraft cannot copy");
                                }
                                record::window_material(
                                    material,
                                    style.material_bounds.as_ref(),
                                    local,
                                    clips,
                                    &scene.output_from_scene,
                                    (width, height),
                                )?
                                .map(|behind| (material, behind))
                            }
                            None => None,
                        };
                        let opaque = image
                            .as_ref()
                            .is_some_and(|(image, _)| image.opaque || declared_opaque);
                        let surface = image.as_ref().and_then(|(_, placement)| {
                            opaque
                                .then(|| record::window_surface(texture_transform, placement))
                                .flatten()
                        });
                        staged.note_cover(&draw, (width, height), || match (&image, &behind) {
                            (None, _) => Some("window without a client image"),
                            (Some(_), Some(_)) => Some("window over a material"),
                            (Some(_), None) => draw.why_no_cover(opaque, surface, (width, height)),
                        });
                        if image.is_some() {
                            staged.client_draws.push((
                                crate::flutter_runtime::renderer::native_window::surface_texture(
                                    *texture_id,
                                ),
                                staged.draws.len() as u32,
                            ));
                        }
                        let Some((material, behind)) = behind else {
                            if surface.is_some() {
                                let index = staged.draws.len() as u32;
                                for cover in
                                    draw.opaque(surface, (width, height)).into_iter().flatten()
                                {
                                    staged.covers.push((index, cover));
                                }
                            }
                            push(&mut staged, draw, &bound, content, &look_image, nearest);
                            continue;
                        };
                        // The window draws itself over its material, in one
                        // draw that samples the client and the frost.
                        let record = staged.glasses.len() as u32;
                        let index = staged.draws.len() as u32;
                        staged.draws.push(draw.with_glass(record));
                        staged.glasses.push(behind.glass);
                        staged
                            .backdrop_tokens
                            .push(material.backdrop_token.filter(|_| behind.tracked));
                        staged.engine_tokens.push(material.backdrop_token);
                        staged.outputs.push(behind.output);
                        staged.steps.push(Step::Material(MaterialStep {
                            record,
                            plan: behind.plan,
                            frost: None,
                            fresh: false,
                            below: 0,
                            made: 0,
                            frozen: None,
                            window: Some(WindowDraw {
                                draw: index,
                                image: bound,
                                look: look_image,
                                nearest,
                                content,
                            }),
                        }));
                    }
                    SceneEntry::MaterialBegin { material, local } => {
                        if !copyable {
                            return Err("output buffer Stagecraft cannot copy");
                        }
                        // Backdrop layers have no content clip (window
                        // materials do, and the engine keeps those).
                        if material.content_clip.is_some() {
                            return Err("material content clip");
                        }
                        // `src` is drawn as source-over: the layer is opaque
                        // where the material draws.
                        if !matches!(material.blend_mode, BLEND_SRC | BLEND_SRC_OVER) {
                            return Err("material blend mode");
                        }
                        let clips = reduce(local.clips.clone(), &mut staged.clips);
                        open.push((clips, local.opacity));
                        let Some(draw) = record::material(
                            material,
                            local,
                            clips,
                            &scene.output_from_scene,
                            (width, height),
                        )?
                        else {
                            continue;
                        };
                        // Frozen glass samples the slice its frost was copied
                        // into, kept for the frame like the shown slices.
                        let frozen = match &material.frozen {
                            Some(frozen) => {
                                let slice = state
                                    .slices
                                    .get(&frozen.key.allocation)
                                    .ok_or("unknown frozen frost")?;
                                if slice.image.size != frozen.storage_size {
                                    return Err("frozen frost storage size");
                                }
                                staged.slices.push(frozen.key);
                                Some((Arc::clone(&slice.image), slice_content(&frozen.key)))
                            }
                            None => None,
                        };
                        let record = staged.glasses.len() as u32;
                        staged.glasses.push(draw.glass);
                        // An untracked frost is kept by the engine's damage.
                        staged
                            .backdrop_tokens
                            .push(material.backdrop_token.filter(|_| draw.tracked));
                        staged.engine_tokens.push(material.backdrop_token);
                        staged.outputs.push(draw.output);
                        staged.steps.push(Step::Material(MaterialStep {
                            record,
                            plan: draw.plan,
                            frost: None,
                            fresh: false,
                            below: 0,
                            made: 0,
                            window: None,
                            frozen,
                        }));
                    }
                    SceneEntry::MaterialEnd => {
                        open.pop();
                    }
                }
            }
            cull(&mut staged, (width, height));
            if !self.gpu.records_fit(
                staged.draws.len(),
                staged.glasses.len(),
                staged.clips.len(),
                staged.edges.len(),
            ) {
                return Err("records exceed a storage buffer");
            }
            Ok(staged)
        })();
        match result {
            Ok(staged) => {
                if state.full_covers.get(&staged.view_id) != Some(&staged.full_cover) {
                    state.full_covers.insert(staged.view_id, staged.full_cover);
                    match staged.full_cover {
                        Some(None) => info!(
                            view = staged.view_id,
                            "a client covers the whole output: what it hides is not drawn"
                        ),
                        Some(Some(why)) => info!(
                            view = staged.view_id,
                            why, "a client over the whole output is no cover"
                        ),
                        None => info!(view = staged.view_id, "no client over the whole output"),
                    }
                }
                let ticket = scene.ticket;
                state.scratch = scene;
                state.staged = Some((ticket, staged));
                Ok(())
            }
            Err(reason) => {
                state.scratch = scene;
                Err(reason)
            }
        }
    }
}

/// The parts of a flat draw that covers above leave visible, when they
/// spare enough pixels to be worth more draws; None otherwise. Pixels a
/// frost above reads (`reads`) stay drawn, even under a cover.
fn visible_pieces(
    draw: &record::Draw,
    size: (u32, u32),
    above: &[[i32; 4]],
    reads: &[[i32; 4]],
) -> Option<Vec<[f32; 4]>> {
    /// Fewer spared pixels than this keep the draw whole.
    const MIN_SPARED: f32 = 16384.0;
    /// More pieces than this keep the draw whole.
    const MAX_PIECES: usize = 8;
    let rect = draw.flat_rect(size)?;
    let target = [0.0, 0.0, size.0 as f32, size.1 as f32];
    let float = |r: [i32; 4]| r.map(|v| v as f32);
    // What of a rectangle lies on the target.
    let area = |rect: [f32; 4]| {
        let [l, t, r, b] = [
            rect[0].max(target[0]),
            rect[1].max(target[1]),
            rect[2].min(target[2]),
            rect[3].min(target[3]),
        ];
        (r - l).max(0.0) * (b - t).max(0.0)
    };
    // Covers over the draw, less what frosts read.
    let mut holes = Vec::new();
    for &cover in above {
        let mut parts = vec![float(cover)];
        for &read in reads {
            let mut next = Vec::new();
            for part in parts {
                record::rect_subtract(part, float(read), &mut next);
            }
            parts = next;
        }
        holes.extend(parts.into_iter().filter(|hole| {
            hole[0] < rect[2] && hole[2] > rect[0] && hole[1] < rect[3] && hole[3] > rect[1]
        }));
    }
    if holes.is_empty() {
        return None;
    }
    let mut pieces = vec![rect];
    for hole in holes {
        let mut next = Vec::new();
        for piece in pieces {
            record::rect_subtract(piece, hole, &mut next);
        }
        if next.len() > MAX_PIECES {
            return None;
        }
        pieces = next;
    }
    pieces.retain(|&piece| area(piece) > 0.0);
    let spared = area(rect) - pieces.iter().map(|&piece| area(piece)).sum::<f32>();
    // Nothing left would mean a covered draw, which `hidden` leaves out.
    (spared >= MIN_SPARED && !pieces.is_empty()).then_some(pieces)
}

/// Why `cull` leaves a draw out.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Hidden {
    /// It changes no pixel of the target.
    OffTarget,
    /// Opaque draws above hold it whole.
    Covered,
}

/// Leaves out what opaque draws above hide: a hidden draw gets a quad
/// without area, a hidden material (its frost, its glass and the window
/// over it) its step. Only one cover must hold a hidden draw whole; the
/// target keeps what is below a cover, so a culled draw changes no pixel.
///
/// A cached frost of a material left out keeps taking the engine's damage,
/// so it is made again when the material shows again.
fn cull(staged: &mut Staged, size: (u32, u32)) {
    let mut above: Vec<[i32; 4]> = Vec::new();
    let mut covers = std::mem::take(&mut staged.covers);
    // Pixels past the target do not exist: only what a draw changes on it
    // must be covered, and a draw that changes nothing there is hidden.
    let target = [0, 0, size.0 as i32, size.1 as i32];
    let hidden = |above: &[[i32; 4]], bounds: [i32; 4]| {
        let bounds = record::pixels_intersect(bounds, target);
        if record::pixels_empty(bounds) {
            Some(Hidden::OffTarget)
        } else if above
            .iter()
            .any(|&cover| record::pixels_contain(cover, bounds))
        {
            Some(Hidden::Covered)
        } else {
            None
        }
    };
    // Draws hidden under covers: their clients are hidden on this target.
    let mut covered = Vec::new();
    // What the frosts of materials above read from the target: a cover
    // above them hides nothing there from the draws below.
    let mut reads: Vec<[i32; 4]> = Vec::new();
    let mut steps = std::mem::take(&mut staged.steps);
    let mut kept = Vec::with_capacity(steps.len());
    while let Some(step) = steps.pop() {
        match step {
            Step::Draws(batch) => {
                let mut shown = 0;
                // The batch's runs of draws, topmost first: a draw split
                // into pieces is followed by its pieces, at the end of the
                // draw records.
                let mut runs: Vec<(u32, u32)> = Vec::new();
                let mut end = batch.first + batch.count;
                for index in (batch.first..batch.first + batch.count).rev() {
                    let draw = &mut staged.draws[index as usize];
                    if let Some(why) = hidden(&above, draw.bounds(size)) {
                        draw.hide();
                        staged.culled_draws += 1;
                        if why == Hidden::Covered {
                            covered.push(index);
                        }
                    } else {
                        shown += 1;
                        if let Some(pieces) = visible_pieces(draw, size, &above, &reads) {
                            let first = staged.draws.len() as u32;
                            let draw = staged.draws[index as usize];
                            staged.draws[index as usize] = draw.piece(pieces[0], size);
                            staged
                                .draws
                                .extend(pieces[1..].iter().map(|&piece| draw.piece(piece, size)));
                            staged.split_draws += 1;
                            runs.push((index + 1, end - index - 1));
                            runs.push((first, pieces.len() as u32 - 1));
                            end = index + 1;
                        }
                    }
                    while let Some(&(cover_index, cover)) = covers.last()
                        && cover_index >= index
                    {
                        covers.pop();
                        if cover_index == index {
                            above.push(cover);
                        }
                    }
                }
                runs.push((batch.first, end - batch.first));
                if shown > 0 {
                    for (first, count) in runs.into_iter().filter(|&(_, count)| count > 0) {
                        kept.push(Step::Draws(Batch {
                            image: Arc::clone(&batch.image),
                            look: Arc::clone(&batch.look),
                            nearest: batch.nearest,
                            first,
                            count,
                            content: batch.content,
                        }));
                    }
                }
            }
            Step::Material(material) => {
                let output = staged.outputs[material.record as usize];
                let bounds = match &material.window {
                    Some(window) => record::pixels_union(
                        output,
                        staged.draws[window.draw as usize].bounds(size),
                    ),
                    None => output,
                };
                if let Some(why) = hidden(&above, bounds) {
                    staged.culled_materials += 1;
                    if let Some(window) = &material.window {
                        staged.draws[window.draw as usize].hide();
                        if why == Hidden::Covered {
                            covered.push(window.draw);
                        }
                    }
                } else {
                    reads.push(material.plan.region);
                    kept.push(Step::Material(material));
                }
            }
        }
    }
    kept.reverse();
    staged.steps = kept;
    staged.covers = covers;
    for &(texture_id, index) in &staged.client_draws {
        if !staged.draws[index as usize].hidden() {
            if !staged.shown_textures.contains(&texture_id) {
                staged.shown_textures.push(texture_id);
            }
        }
    }
    for &(texture_id, index) in &staged.client_draws {
        if covered.contains(&index)
            && !staged.shown_textures.contains(&texture_id)
            && !staged.hidden_textures.contains(&texture_id)
        {
            staged.hidden_textures.push(texture_id);
        }
    }
}

#[cfg(test)]
#[path = "gpu_test.rs"]
mod gpu_test;
