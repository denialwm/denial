//! Vulkan scene composer (`--vulkan-composer`).
//!
//! The engine keeps rendering shell slices with GLES, into storage this
//! module allocates (GBM, bound to GL through an EGLImage and imported into
//! Vulkan once). Each output frame it can describe, the engine stages as an
//! ordered list of slices, client textures and windows; the composer draws
//! that list into the output buffer on its own Vulkan queue. Frames it cannot
//! describe the engine composes as before, sampling the same storage.
//!
//! Synchronization:
//! - GLES writes a slice version once. The first scene that shows it waits
//!   for one EGL native fence covering every version written since.
//! - Vulkan only reads slices and client buffers, in `GENERAL` layout with
//!   FOREIGN ownership acquired and released in the same submission.
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

#[path = "device.rs"]
mod device;
#[path = "material.rs"]
mod material;
#[path = "record.rs"]
mod record;

use std::collections::HashMap;
use std::os::fd::{AsFd, OwnedFd};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};

use denial_flutter_engine::scene::{
    BLEND_SRC, BLEND_SRC_OVER, Matrix3, Rect, Sampling, Scene, SceneEntry, SceneSource, SliceKey,
    SliceWriter,
};
use denial_flutter_engine::sys;
use smithay::backend::allocator::dmabuf::{AsDmabuf, Dmabuf, WeakDmabuf};
use smithay::backend::allocator::gbm::{GbmBuffer, GbmDevice};
use smithay::backend::allocator::{Fourcc, Modifier};
use smithay::backend::drm::DrmDeviceFd;
use tracing::{info, warn};

use device::{
    Batch, Frame, Gpu, Image, MAX_FRAMES, MaterialStep, Merge, Step, Upload, Usage, WindowDraw,
};
use material::Frost;
pub(super) use record::Placement;
use record::{ClipRecord, ClipSpan, Draw, FrostPlan, Glass};

use crate::output_color::Lut;

/// `--vulkan-composer`.
pub(super) fn requested() -> bool {
    crate::options::VULKAN_COMPOSER.load(Ordering::Relaxed)
}

/// Blocks until a completion fence signals. Failure paths only.
pub(super) fn wait_completion(fence: &OwnedFd) {
    device::wait_fd(fence.as_fd(), -1);
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
            warn!(%error, "could not share a composer fence; waiting on the CPU");
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

/// A client import unused for this many submissions is released: each live
/// shared import costs every submission (~0.7 µs on RADV), and re-importing
/// costs about 20 submissions' worth. An import whose buffer the client
/// destroyed goes at the next reap, submissions or not: the image holds only
/// Vulkan's own reference, never the client's `Dmabuf`.
const CLIENT_IMPORT_IDLE_SUBMITS: u64 = 64;

/// One version of a slice's storage.
struct Slice {
    _bo: GbmBuffer,
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
    /// Diagnostic: cached frosts by why they were judged (below, plan,
    /// token, revision, damage, reused), and frosts without a cache.
    remade_why: [u32; 7],
    slices: Vec<SliceKey>,
    rewritten: bool,
    pub(super) clients: Vec<SampledClient>,
    /// Inputs of merged windows reused as they are: shown again, not read.
    pub(super) credits: Vec<SampledClient>,
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
    /// A staged frame with new slice versions was not submitted: the next
    /// submission still owes a wait for GLES.
    producer_pending: bool,
    /// A failed submission: decline every later frame.
    broken: bool,
    /// Frosts by view and material order, as last submitted.
    frosts: HashMap<(i64, u32), CachedFrost>,
    /// Views whose last frame the composer did not draw (GLES did, or none
    /// was presented): the engine's damage no longer says what changed
    /// since the composer's last frame, so the next one redraws and reports
    /// everything.
    unaccounted: Vec<i64>,
    /// App looks as 3D images, while the look lives. Weak: the GLES grades
    /// hold the look too, and each side prunes on its own.
    looks: Vec<(Weak<Lut>, Arc<Image>)>,
    /// The last GLES output present's fence while it may still run: a
    /// submission waits for it, so Vulkan never overlaps a GLES read and the
    /// transaction's last fence covers both queues. The reverse holds by
    /// construction: GLES waits for every submission (handler).
    last_gles_fence: Option<OwnedFd>,
    tally: Tally,
}

impl State {
    /// `view_id` showed a frame the composer did not draw.
    fn unaccount(&mut self, view_id: i64) {
        self.frosts.retain(|&(view, _), _| view != view_id);
        if !self.unaccounted.contains(&view_id) {
            self.unaccounted.push(view_id);
        }
    }
}

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
    /// Vulkan frames that redrew part of the target, none of it, and the
    /// share of target pixels redrawn over all Vulkan frames.
    partial_frames: u64,
    /// Diagnostic: shares of target pixels the engine's frame damage and the
    /// composer's added damage cover, summed over Vulkan frames; frosts by
    /// why they were judged (`Staged::remade_why`).
    engine_damage: f64,
    added_damage: f64,
    remade_why: [u64; 7],
    empty_frames: u64,
    redrawn: f64,
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
            remade_revision = self.remade_why[3],
            remade_damage = self.remade_why[4],
            reused = self.remade_why[5],
            uncached = self.remade_why[6],
            empty_frames = self.empty_frames,
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
    /// The layered build it was last shown in.
    scene_revision: u64,
    /// The engine reported a change in its region since then.
    damaged: bool,
}

pub(super) struct SceneComposer {
    gpu: Gpu,
    placeholder: Arc<Image>,
    /// Bound as the look of clients without one; never read.
    no_look: Arc<Image>,
    gbm: Mutex<GbmDevice<DrmDeviceFd>>,
    slice_modifiers: Vec<Modifier>,
    next_allocation: AtomicU64,
    dropped: Mutex<Vec<SliceKey>>,
    state: Mutex<State>,
}

impl SceneComposer {
    /// `render_node` is the DRM node the raster context renders with;
    /// `render_modifiers` what EGL renders ABGR8888 with.
    pub(super) fn new(
        render_node: DrmDeviceFd,
        render_modifiers: &[Modifier],
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
        let gbm = GbmDevice::new(render_node)
            .map_err(|error| format!("Vulkan composer GBM device: {error}"))?;
        info!(
            modifiers = ?slice_modifiers,
            "Vulkan scene composer slice storage"
        );
        Ok(Self {
            gpu,
            placeholder,
            no_look,
            gbm: Mutex::new(gbm),
            slice_modifiers,
            next_allocation: AtomicU64::new(1),
            dropped: Mutex::new(Vec::new()),
            state: Mutex::new(State {
                targets: HashMap::new(),
                slices: HashMap::new(),
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
                producer_pending: false,
                broken: false,
                frosts: HashMap::new(),
                unaccounted: Vec::new(),
                last_gles_fence: None,
                looks: Vec::new(),
                tally: Tally::default(),
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
        for allocation in retired {
            if let Some(slice) = state.slices.remove(&allocation) {
                destroy_gl(gl, display, &slice);
            }
        }
        let serial = state.serial;
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

    /// Fresh storage for one slice version. Raster thread, context current.
    pub(super) fn acquire_writer(
        &self,
        width: u32,
        height: u32,
        gl: &super::GlApi,
        display: &smithay::backend::egl::EGLDisplay,
    ) -> Option<SliceWriter> {
        if width == 0 || height == 0 || width > 16384 || height > 16384 {
            return None;
        }
        let bo = {
            let gbm = lock(&self.gbm);
            let raw = gbm
                .create_buffer_object_with_modifiers::<()>(
                    width,
                    height,
                    Fourcc::Abgr8888,
                    self.slice_modifiers.iter().copied(),
                )
                .map_err(|error| warn!(%error, width, height, "composer slice allocation failed"))
                .ok()?;
            GbmBuffer::from_bo(raw, false)
        };
        let dmabuf = bo
            .export()
            .map_err(|error| warn!(%error, "composer slice export failed"))
            .ok()?;
        let image = self
            .gpu
            .import(&dmabuf, Usage::Sampled)
            .map_err(|error| warn!(%error, "composer slice import failed"))
            .ok()?;
        let egl_image = display
            .create_image_from_dmabuf(&dmabuf)
            .map_err(|error| warn!(%error, "composer slice EGLImage failed"))
            .ok()?;
        let mut gl_texture = 0;
        // SAFETY: the raster context is current (the engine's contract for
        // acquire_writer); the image is live.
        let error = unsafe {
            let _ = (gl.get_error)();
            (gl.gen_textures)(1, &mut gl_texture);
            (gl.bind_texture)(super::gl::TEXTURE_2D, gl_texture);
            (gl.image_target_texture)(super::gl::TEXTURE_2D, egl_image.cast());
            (gl.bind_texture)(super::gl::TEXTURE_2D, 0);
            (gl.get_error)()
        };
        let allocation = self.next_allocation.fetch_add(1, Ordering::Relaxed);
        let slice = Slice {
            _bo: bo,
            egl_image: egl_image as usize,
            gl_texture,
            image,
            engine_ref: true,
            last_serial: 0,
        };
        if gl_texture == 0 || error != super::gl::NO_ERROR {
            warn!(
                error = format_args!("{error:#x}"),
                "composer slice GL binding failed"
            );
            destroy_gl(gl, &display.get_display_handle(), &slice);
            return None;
        }
        lock(&self.state).slices.insert(allocation, slice);
        Some(SliceWriter {
            struct_size: 0,
            key: SliceKey {
                allocation,
                generation: 1,
            },
            gl_name: gl_texture,
            width,
            height,
        })
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
            tracing::error!("could not wait for the Vulkan composer's last submission");
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

    /// What `staged` waits for on the GLES side: a fresh fence for new slice
    /// versions or GLES reads of composer storage, else the last output
    /// present's fence while it may still run.
    pub(super) fn producer_wait(&self, staged: &Staged) -> ProducerWait {
        let mut state = lock(&self.state);
        if staged.rewritten || state.producer_pending || state.gles_read {
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
    /// submission's completion, None when it already completed. A failure
    /// disables the composer.
    pub(super) fn submit(
        &self,
        staged: &mut Staged,
        framebuffer: u32,
        damage: FrameDamage<'_>,
        wait: Option<OwnedFd>,
    ) -> Result<Submitted, String> {
        let mut state = lock(&self.state);
        let result = Self::submit_locked(&mut state, &self.gpu, staged, framebuffer, damage, wait);
        if result.is_err() {
            state.broken = true;
        }
        result
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
            .ok_or("staged frame for an output buffer the composer did not import")?;
        let index = match state.frames.iter_mut().position(Frame::idle) {
            Some(index) => index,
            None if state.frames.len() < MAX_FRAMES => {
                state.frames.push(Frame::new(gpu)?);
                state.frames.len() - 1
            }
            None => {
                // Every frame in flight: wait for the oldest.
                let oldest = (0..state.frames.len())
                    .min_by_key(|&index| state.frames[index].serial)
                    .unwrap_or(0);
                while !state.frames[oldest].idle() {
                    std::thread::yield_now();
                }
                oldest
            }
        };
        let (output_from_scene, size) = (staged.output_from_scene, target.size);
        let to_target = |rects| target_damage(rects, output_from_scene, size);
        let view_id = staged.view_id;
        let unaccounted = state.unaccounted.contains(&view_id);
        for (&(view, _), cached) in &mut state.frosts {
            if view == view_id && !cached.damaged {
                let region = cached.plan.region;
                cached.damaged =
                    to_target(damage.frame).any(|rect| record::pixels_overlap(rect, region));
            }
        }
        Self::resolve_frosts(state, gpu, staged)?;
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
        let area = to_target(damage.buffer)
            .fold(record::pixels_union(added, inputs), record::pixels_union);
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
            wait,
        )?;
        state.serial = serial;
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
        state.gles_read = false;
        state.last_gles_fence = None;
        state.producer_pending = false;
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
                                scene_revision: staged.scene_revision,
                                damaged: false,
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
        state.unaccounted.retain(|&view| view != view_id);
        let added = (!record::pixels_empty(added))
            .then(|| scene_rect(&output_from_scene, added))
            .flatten();
        Ok(Submitted { completion, added })
    }

    /// Gives every material its frost: the cached one when the scene below
    /// it is unchanged (no engine damage in its region since it was made,
    /// or an unchanged backdrop token), else images to make it in (the
    /// cached ones when their sizes fit).
    fn resolve_frosts(state: &State, gpu: &Gpu, staged: &mut Staged) -> Result<(), String> {
        // What materials whose frosts are made this frame draw, in paint
        // order: it may have changed below a frost above, which neither its
        // token nor the engine's damage sees.
        let mut remade: Vec<[i32; 4]> = Vec::new();
        for step in &mut staged.steps {
            let Step::Material(material) = step else {
                continue;
            };
            let token = staged.backdrop_tokens[material.record as usize];
            let cached = state.frosts.get(&(staged.view_id, material.record));
            let region = material.plan.region;
            let below_changed = remade
                .iter()
                .any(|&output| record::pixels_overlap(output, region));
            // A tracked token says whether the scene below changed; else no
            // engine damage in the frost's region within one layered build.
            let unchanged = |cached: &CachedFrost| match token {
                Some(_) => cached.backdrop_token == token,
                None => !cached.damaged && cached.scene_revision == staged.scene_revision,
            };
            if let Some(cached) = cached {
                // Diagnostic: why a cached frost is made again.
                let why = if below_changed {
                    1
                } else if cached.plan != material.plan {
                    2
                } else if token.is_some() && cached.backdrop_token != token {
                    3
                } else if token.is_none() && cached.scene_revision != staged.scene_revision {
                    4
                } else if token.is_none() && cached.damaged {
                    5
                } else {
                    6
                };
                staged.remade_why[why - 1] += 1;
            } else {
                staged.remade_why[6] += 1;
            }
            let (frost, fresh) = match cached {
                Some(cached)
                    if !below_changed && cached.plan == material.plan && unchanged(cached) =>
                {
                    (Arc::clone(&cached.frost), false)
                }
                Some(cached) if cached.frost.fits(&material.plan) => {
                    (Arc::clone(&cached.frost), true)
                }
                _ => (Arc::new(Frost::new(gpu, material.plan)?), true),
            };
            if fresh {
                remade.push(staged.outputs[material.record as usize]);
            }
            material.frost = Some(frost);
            material.fresh = fresh;
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
        state.targets.clear();
    }
}

fn destroy_gl(gl: &super::GlApi, display: &super::EGLDisplayHandle, slice: &Slice) {
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

impl MergeKey {
    fn new(layer: &MergedLayer) -> Self {
        let backing = match &layer.sampled.source {
            super::ExternalTextureSource::Dmabuf { dmabuf, .. } => Backing::Dmabuf(dmabuf.weak()),
            super::ExternalTextureSource::Shm(frame) => Backing::Shm(frame.pixels_id()),
        };
        Self {
            texture_id: layer.sampled.texture_id,
            backing,
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

/// Merged native window images the composer keeps, as the GLES pool's
/// budget.
const MERGED_BYTES: u64 = 512 << 20;

fn image_bytes((width, height): (u32, u32)) -> u64 {
    u64::from(width) * u64::from(height) * 4
}

/// Declines a scene whose texture shows other pixels than where it was
/// drawn before in it: draws share one image per texture, and the handler
/// credits each staged generation as sampled.
fn resolved_once(staged: &Staged, sampled: &SampledClient) -> Result<(), Decline> {
    let changed = staged.clients.iter().any(|seen| {
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
    ) -> Result<Arc<Image>, Decline> {
        let dmabuf = match &sampled.source {
            super::ExternalTextureSource::Dmabuf { dmabuf, .. } => dmabuf,
            super::ExternalTextureSource::Shm(frame) => {
                return self.shm_image(state, uploads, sampled.texture_id, frame);
            }
        };
        let weak = dmabuf.weak();
        if let Some(import) = state.clients.get(&weak) {
            return Ok(Arc::clone(&import.image));
        }
        let image = self.gpu.import(dmabuf, Usage::Sampled).map_err(|error| {
            tracing::debug!(%error, "client buffer stays on GLES composition");
            "client buffer import"
        })?;
        state.clients.insert(
            weak,
            ClientImport {
                image: Arc::clone(&image),
                last_serial: state.serial,
            },
        );
        Ok(image)
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
    ) -> Result<Option<(Arc<Image>, Placement, Option<Arc<Lut>>)>, Decline> {
        match client {
            Client::Missing => Ok(None),
            Client::Image {
                placement,
                sampled,
                look,
            } => {
                resolved_once(staged, &sampled)?;
                let image = self.client_image(state, &mut staged.uploads, &sampled)?;
                staged.clients.push(sampled);
                Ok(Some((image, placement, look)))
            }
            Client::Merged {
                placement,
                merged,
                look,
            } => Ok(Some((
                self.merged_image(state, staged, merged)?,
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
            let input = self.client_image(state, &mut staged.uploads, &layer.sampled)?;
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
                }),
            }
            staged.clients.push(layer.sampled);
        }
        staged.credits.extend(merged.unseen);
        staged.merges.push(Merge {
            image: Arc::clone(&image),
            batches,
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
        mut resolve: impl FnMut(i64, Rect) -> Result<Client, Decline>,
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
                return Err("scene the composer cannot describe");
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
                remade_why: [0; 7],
                slices: Vec::new(),
                rewritten: !scene.rewritten.is_empty(),
                clients: Vec::new(),
                credits: Vec::new(),
                uploads: Vec::new(),
                merges: Vec::new(),
                merged_windows: Vec::new(),
                merges_reused: 0,
            };
            let push = |staged: &mut Staged,
                        draw: Draw,
                        image: &Arc<Image>,
                        look: &Arc<Image>,
                        nearest: bool| {
                let index = staged.draws.len() as u32;
                staged.draws.push(draw);
                if let Some(Step::Draws(last)) = staged.steps.last_mut()
                    && Arc::ptr_eq(&last.image, image)
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
                        blits,
                    } => {
                        let slice = state.slices.get(&key.allocation).ok_or("unknown slice")?;
                        if slice.image.size != (*storage_width, *storage_height) {
                            return Err("slice storage size");
                        }
                        let image = Arc::clone(&slice.image);
                        staged.slices.push(*key);
                        for blit in &scene.blits[blits.clone()] {
                            let mut draw =
                                record::slice_blit(blit, image.size, *bottom_up, &ndc_from_target);
                            if let Some(&(clips, opacity)) = open.last() {
                                record::inside_material(
                                    &mut draw,
                                    clips,
                                    opacity,
                                    &scene_from_target,
                                );
                            }
                            push(&mut staged, draw, &image, &self.no_look, true);
                        }
                    }
                    SceneEntry::Texture {
                        texture_id,
                        bounds,
                        local,
                    } => {
                        let clips = reduce(local.clips.clone(), &mut staged.clips);
                        let client = resolve(*texture_id, *bounds)?;
                        let Some((image, placement, look)) =
                            self.resolved_image(&mut state, &mut staged, client)?
                        else {
                            continue;
                        };
                        let look_image = self.look_image(&mut state, look.as_ref())?;
                        let draw =
                            record::texture(local, clips, &ndc_from_scene, &placement, image.size)
                                .ok_or("texture transform")?
                                .with_look(look.is_some());
                        push(
                            &mut staged,
                            draw,
                            &image,
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
                        let client = resolve(*texture_id, *texture_bounds)?;
                        let (image, look) =
                            match self.resolved_image(&mut state, &mut staged, client)? {
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
                                    return Err("output buffer the composer cannot copy");
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
                        let Some((material, behind)) = behind else {
                            push(&mut staged, draw, &bound, &look_image, nearest);
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
                            window: Some(WindowDraw {
                                draw: index,
                                image: bound,
                                look: look_image,
                                nearest,
                            }),
                        }));
                    }
                    SceneEntry::MaterialBegin { material, local } => {
                        if !copyable {
                            return Err("output buffer the composer cannot copy");
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
                            window: None,
                        }));
                    }
                    SceneEntry::MaterialEnd => {
                        open.pop();
                    }
                }
            }
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
                // The engine stops tracking the new versions now: until a
                // submission waits for them, they stay owed.
                state.producer_pending |= staged.rewritten;
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

#[cfg(test)]
#[path = "gpu_test.rs"]
mod gpu_test;
