//! Client images GLES draws into storage the composer samples: clients the
//! composer cannot read as they are (a conversion or look GLES grades
//! first, a buffer Vulkan cannot import), so a frame never declines for a
//! client the GLES pass would show.
//!
//! Each texture keeps the image showing its last conversion, drawn again
//! only when the client's buffer, generation or grade changes, and up to
//! `SPARES` earlier images that no frame reads any more are rewritten
//! instead of allocated.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use smithay::backend::allocator::Fourcc;
use smithay::backend::allocator::gbm::GbmBuffer;

use super::device::Transfer;
use super::{Backing, Decline, Image, SampledClient, SceneComposer, lock};

/// Earlier images kept per texture, as the GLES pass's graded spares.
const SPARES: usize = 2;

/// A texture not converted for this long gives its images back.
const IDLE: Duration = Duration::from_secs(2);

/// What a converted image shows: the client's storage, generation and size,
/// and the pass that drew it.
#[derive(Clone)]
pub struct ConvertKey {
    backing: Backing,
    generation: u64,
    pub size: (u32, u32),
    /// Half floats: a converted HDR grade, or a deeper source copied.
    pub float: bool,
    /// The grade, or None for a plain copy of the pixels.
    grade: Option<crate::Grade>,
}

impl ConvertKey {
    pub fn new(
        sampled: &SampledClient,
        size: (u32, u32),
        float: bool,
        grade: Option<crate::Grade>,
    ) -> Self {
        Self {
            backing: Backing::of(&sampled.source),
            generation: sampled.generation,
            size,
            float,
            grade,
        }
    }

    fn same(&self, other: &Self) -> bool {
        self.backing == other.backing
            && self.generation == other.generation
            && self.size == other.size
            && self.float == other.float
            && match (&self.grade, &other.grade) {
                (Some(a), Some(b)) => a.same(b),
                (None, None) => true,
                _ => false,
            }
    }
}

/// An image both APIs share: GLES draws into `gl_texture`, the composer
/// samples `image`.
struct Target {
    _bo: GbmBuffer,
    egl_image: usize,
    gl_texture: u32,
    image: Arc<Image>,
    size: (u32, u32),
    float: bool,
}

impl Target {
    /// No staged or submitted frame holds its image.
    fn free(&self) -> bool {
        Arc::strong_count(&self.image) == 1
    }
}

struct Entry {
    current: Option<(ConvertKey, Target)>,
    spares: Vec<Target>,
    used: Instant,
}

#[derive(Default)]
pub(super) struct Pool {
    entries: HashMap<i64, Entry>,
    /// Targets of forgotten or idle textures, destroyed once free.
    retired: Vec<Target>,
    /// Clients GLES read since the last submission that waited for GLES:
    /// their buffers stay held until a present's fence follows the read.
    reads: Vec<SampledClient>,
    /// GLES wrote an image no submission has waited for yet.
    pub(super) unwaited: bool,
    /// Copies GLES made for the engine's own composition of a frame the
    /// composer could not stage, and whether they are lent.
    lending: Lending,
    /// Copies of earlier fallbacks, rewritten once free, and when last used.
    fallback_spares: Vec<(Target, Instant)>,
    /// Lend and return submissions still running.
    transfers: Vec<Transfer>,
}

#[derive(Default)]
struct Lending {
    ticket: u64,
    targets: Vec<Target>,
    lent: bool,
}

/// Zero copy is the rule: a client whose buffer GLES copies for the
/// composer, such as a YUV video frame, says so at most once in this long,
/// with how often since.
const COPY_WARNING_INTERVAL: Duration = Duration::from_secs(10);

/// Call for each plain copy (no grade) of `texture_id`'s buffer.
fn warn_client_copied(texture_id: i64, size: (u32, u32)) {
    // Per texture: when it last warned and its copies since.
    static COPIED: Mutex<Vec<(i64, Instant, u64)>> = Mutex::new(Vec::new());
    let now = Instant::now();
    let mut copied = COPIED
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let copies = match copied.iter_mut().find(|entry| entry.0 == texture_id) {
        Some(entry) => {
            entry.2 += 1;
            if now.duration_since(entry.1) < COPY_WARNING_INTERVAL {
                return;
            }
            entry.1 = now;
            std::mem::take(&mut entry.2)
        }
        None => {
            copied.retain(|entry| now.duration_since(entry.1) < 6 * COPY_WARNING_INTERVAL);
            copied.push((texture_id, now, 0));
            1
        }
    };
    drop(copied);
    tracing::warn!(
        texture_id,
        width = size.0,
        height = size.1,
        copies,
        "client copied: Stagecraft cannot sample its buffer, so GLES copies it into one it can"
    );
}

impl SceneComposer {
    /// The image showing `key` for `texture_id`: the one drawn before when
    /// it shows it already, else `draw` writes the GL texture it is given
    /// (the raster context is current) into a free or new image. The read
    /// client stays held until a present follows it.
    pub fn converted(
        &self,
        sampled: &SampledClient,
        key: ConvertKey,
        gl: &crate::GlApi,
        display: &smithay::backend::egl::EGLDisplay,
        draw: impl FnOnce(u32) -> Result<(), u32>,
    ) -> Result<Arc<Image>, Decline> {
        let mut pool = lock(&self.converts);
        let entry = pool.entries.entry(sampled.texture_id).or_insert(Entry {
            current: None,
            spares: Vec::new(),
            used: Instant::now(),
        });
        entry.used = Instant::now();
        if let Some((held, target)) = &entry.current
            && held.same(&key)
        {
            return Ok(Arc::clone(&target.image));
        }
        let free = entry
            .spares
            .iter()
            .position(|spare| spare.free() && spare.size == key.size && spare.float == key.float);
        let target = match free {
            Some(index) => entry.spares.swap_remove(index),
            None => self.allocate_target(key.size, key.float, gl, display)?,
        };
        let drawn = draw(target.gl_texture);
        // Even a draw that reports an error may have queued its read, and
        // Vulkan reads of the source (imported once the grade is gone) wait
        // for it as for a drawn conversion.
        pool.reads.push(SampledClient {
            texture_id: sampled.texture_id,
            generation: sampled.generation,
            source: sampled.source.clone(),
        });
        pool.unwaited = true;
        if let Err(error) = drawn {
            tracing::warn!(
                texture_id = sampled.texture_id,
                error = format_args!("{error:#x}"),
                "GLES could not convert a client for Stagecraft"
            );
            // Not reused: its storage may be what failed.
            pool.retired.push(target);
            return Err("client conversion");
        }
        if key.grade.is_none() {
            warn_client_copied(sampled.texture_id, key.size);
        }
        let entry = pool
            .entries
            .get_mut(&sampled.texture_id)
            .expect("entry made above");
        let image = Arc::clone(&target.image);
        if let Some((_, previous)) = entry.current.replace((key, target)) {
            entry.spares.push(previous);
        }
        let mut retired = Vec::new();
        while entry.spares.len() > SPARES {
            retired.push(entry.spares.remove(0));
        }
        pool.retired.extend(retired);
        Ok(image)
    }

    fn allocate_target(
        &self,
        (width, height): (u32, u32),
        float: bool,
        gl: &crate::GlApi,
        display: &smithay::backend::egl::EGLDisplay,
    ) -> Result<Target, Decline> {
        let (fourcc, modifiers) = if float {
            (Fourcc::Abgr16161616f, &self.float_modifiers)
        } else {
            (Fourcc::Abgr8888, &self.slice_modifiers)
        };
        if modifiers.is_empty() {
            return Err("no half-float storage both EGL renders and Vulkan samples");
        }
        let (bo, image, egl_image, gl_texture) = self
            .shared_storage(width, height, fourcc, modifiers, gl, display)
            .ok_or("client conversion storage")?;
        Ok(Target {
            _bo: bo,
            egl_image,
            gl_texture,
            image,
            size: (width, height),
            float,
        })
    }

    /// An image for the engine's fallback composition of `ticket` that
    /// `draw` writes through the GL texture it is given (raster context
    /// current): a free earlier copy of that size and format, or a new one.
    pub fn fallback_image(
        &self,
        ticket: u64,
        size: (u32, u32),
        float: bool,
        gl: &crate::GlApi,
        display: &smithay::backend::egl::EGLDisplay,
        draw: impl FnOnce(u32) -> Result<(), u32>,
    ) -> Result<Arc<Image>, Decline> {
        let mut pool = lock(&self.converts);
        if pool.lending.ticket != ticket {
            // A fallback that was never returned (its frame ended early).
            let earlier = std::mem::take(&mut pool.lending);
            self.give_back(&mut pool, earlier);
            pool.lending.ticket = ticket;
        }
        let free = pool
            .fallback_spares
            .iter()
            .position(|(spare, _)| spare.free() && spare.size == size && spare.float == float);
        let target = match free {
            Some(index) => pool.fallback_spares.swap_remove(index).0,
            None => self.allocate_target(size, float, gl, display)?,
        };
        if let Err(error) = draw(target.gl_texture) {
            tracing::warn!(
                error = format_args!("{error:#x}"),
                "GLES could not copy a client for the engine's fallback"
            );
            pool.retired.push(target);
            return Err("fallback client copy");
        }
        let image = Arc::clone(&target.image);
        pool.lending.targets.push(target);
        Ok(image)
    }

    /// Lends the fallback copies of `ticket` to the engine's renderer, after
    /// `wait` (a GLES fence following the copies). False skips the frame.
    pub fn lend_fallback(
        &self,
        ticket: u64,
        wait: Option<std::os::fd::OwnedFd>,
    ) -> bool {
        let mut pool = lock(&self.converts);
        // Submitted even with no copies: its wait and memory barrier also
        // order the engine's reads after the slices written before.
        let images = if pool.lending.ticket == ticket {
            pool.lending
                .targets
                .iter()
                .map(|target| Arc::clone(&target.image))
                .collect()
        } else {
            Vec::new()
        };
        match self.gpu.transfer(images, true, wait) {
            Ok(transfer) => {
                pool.transfers.push(transfer);
                pool.lending.lent = true;
                true
            }
            Err(error) => {
                tracing::error!(%error, "Stagecraft could not lend client copies");
                false
            }
        }
    }

    /// The engine submitted its fallback composition of `ticket`, or gave
    /// it up: its copies come back.
    pub fn return_fallback(&self, ticket: u64) {
        let mut pool = lock(&self.converts);
        if pool.lending.ticket != ticket {
            return;
        }
        let lending = std::mem::take(&mut pool.lending);
        self.give_back(&mut pool, lending);
    }

    fn give_back(&self, pool: &mut Pool, lending: Lending) {
        if lending.lent {
            let images = lending
                .targets
                .iter()
                .map(|target| Arc::clone(&target.image))
                .collect();
            match self.gpu.transfer(images, false, None) {
                Ok(transfer) => pool.transfers.push(transfer),
                Err(error) => {
                    // Not given back: never reused. The engine may still be
                    // sampling them, which no fence of ours covers, so they
                    // go only once the queue is idle.
                    tracing::error!(%error, "Stagecraft could not take client copies back");
                    self.gpu.wait_queue_idle();
                    pool.retired.extend(lending.targets);
                    return;
                }
            }
        }
        let now = Instant::now();
        pool.fallback_spares
            .extend(lending.targets.into_iter().map(|target| (target, now)));
    }

    /// Whether GLES read clients whose buffers are still held.
    pub fn has_converted_reads(&self) -> bool {
        !lock(&self.converts).reads.is_empty()
    }

    /// Clients GLES read for conversions so far; their buffers go back once
    /// a GLES fence placed after the reads signals.
    pub fn take_converted_reads(&self) -> Vec<SampledClient> {
        std::mem::take(&mut lock(&self.converts).reads)
    }

    /// A submission waited for every GLES command issued before it.
    pub(super) fn conversions_waited(&self) {
        lock(&self.converts).unwaited = false;
    }

    /// Images of a texture the engine let go, destroyed once free.
    pub(super) fn forget_conversions(&self, texture_id: i64) {
        let mut pool = lock(&self.converts);
        if let Some(entry) = pool.entries.remove(&texture_id) {
            let targets = entry
                .current
                .map(|(_, target)| target)
                .into_iter()
                .chain(entry.spares);
            let targets: Vec<_> = targets.collect();
            pool.retired.extend(targets);
        }
    }

    /// Destroys free images of forgotten and idle textures. Raster context
    /// current.
    pub(super) fn reap_conversions(
        &self,
        gl: &crate::GlApi,
        display: &crate::EGLDisplayHandle,
    ) {
        let mut pool = lock(&self.converts);
        let pool = &mut *pool;
        let now = Instant::now();
        for entry in pool.entries.values_mut() {
            if now.duration_since(entry.used) > IDLE {
                pool.retired
                    .extend(entry.current.take().map(|(_, target)| target));
                pool.retired.append(&mut entry.spares);
            }
        }
        pool.entries
            .retain(|_, entry| entry.current.is_some() || !entry.spares.is_empty());
        pool.transfers.retain(|transfer| !transfer.done());
        let (idle, kept): (Vec<_>, Vec<_>) = std::mem::take(&mut pool.fallback_spares)
            .into_iter()
            .partition(|(_, used)| now.duration_since(*used) > IDLE);
        pool.fallback_spares = kept;
        pool.retired
            .extend(idle.into_iter().map(|(target, _)| target));
        pool.retired.retain(|target| {
            if !target.free() {
                return true;
            }
            destroy_target(gl, display, target);
            false
        });
    }

    /// Destroys every image; the GPU is idle. Raster context current.
    pub(super) fn shutdown_conversions(
        &self,
        gl: &crate::GlApi,
        display: &crate::EGLDisplayHandle,
    ) {
        let mut pool = lock(&self.converts);
        let entries = std::mem::take(&mut pool.entries);
        for entry in entries.into_values() {
            let targets = entry.current.map(|(_, target)| target).into_iter();
            for target in targets.chain(entry.spares) {
                destroy_target(gl, display, &target);
            }
        }
        // Waits for the lend and return submissions.
        pool.transfers.clear();
        let lending = std::mem::take(&mut pool.lending);
        let spares = std::mem::take(&mut pool.fallback_spares);
        let targets = lending
            .targets
            .into_iter()
            .chain(spares.into_iter().map(|(target, _)| target))
            .chain(std::mem::take(&mut pool.retired));
        for target in targets {
            destroy_target(gl, display, &target);
        }
        if !pool.reads.is_empty() {
            // SAFETY: the raster context is current; the reads' buffers go
            // back only after GLES finished them.
            unsafe { (gl.finish)() };
            pool.reads.clear();
        }
        pool.unwaited = false;
    }
}

fn destroy_target(
    gl: &crate::GlApi,
    display: &crate::EGLDisplayHandle,
    target: &Target,
) {
    // SAFETY: the raster context is current; no frame holds the image and
    // GL keeps storage alive for its own queued commands.
    unsafe {
        (gl.delete_textures)(1, &target.gl_texture);
        smithay::backend::egl::ffi::egl::DestroyImageKHR(
            display.handle,
            target.egl_image as *const std::ffi::c_void,
        );
    }
}

/// Holds `Mutex<Pool>` for the composer.
pub(super) fn pool() -> Mutex<Pool> {
    Mutex::new(Pool::default())
}
