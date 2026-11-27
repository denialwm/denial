//! Client buffers as the renderers sample them: SHM snapshots, dmabufs and
//! the guards that hold them, and what changed between their generations.

use std::collections::VecDeque;
use std::os::fd::OwnedFd;
use std::sync::{Arc, Mutex, Weak};

use smithay::backend::allocator::Buffer as _;
use smithay::backend::allocator::dmabuf::Dmabuf;
use smithay::backend::renderer::utils::Buffer as RendererBufferGuard;
use tracing::warn;

use crate::mapped_shm::{MappedShmPool, MappedShmStorage, PendingMappedShm};
use crate::native_window_pool::NativeWindowStorage;

pub const MAX_RECYCLED_SHM_BUFFERS: usize = 8;
pub const MAX_RECYCLED_SHM_BYTES: usize = 64 * 1024 * 1024;

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

#[derive(Default)]
struct ShmSnapshotPoolState {
    buffers: Vec<Vec<u8>>,
    retained_bytes: usize,
}

pub struct ShmSnapshotPool {
    state: Mutex<ShmSnapshotPoolState>,
    mapped: Option<Arc<MappedShmPool>>,
}

impl ShmSnapshotPool {
    pub fn new() -> Self {
        Self {
            state: Mutex::new(ShmSnapshotPoolState {
                buffers: Vec::with_capacity(MAX_RECYCLED_SHM_BUFFERS),
                retained_bytes: 0,
            }),
            mapped: None,
        }
    }

    pub fn new_for_device(device: smithay::backend::drm::DrmDeviceFd) -> Self {
        let mut pool = Self::new();
        match MappedShmPool::new(device) {
            Ok(mapped) => pool.mapped = Some(Arc::new(mapped)),
            Err(error) => warn!(%error, "mapped SHM GBM initialization unavailable"),
        }
        pool
    }

    pub fn enable_mapped(
        &self,
        renderer: &mut smithay::backend::renderer::gles::GlesRenderer,
    ) {
        if let Some(pool) = &self.mapped {
            pool.enable(renderer);
        }
    }

    pub fn acquire_mapped(&self, width: u32, height: u32) -> Option<PendingMappedShm> {
        self.mapped.as_ref()?.acquire(width, height)
    }

    pub fn disable_mapped(&self, error: &std::io::Error) {
        if let Some(pool) = &self.mapped {
            pool.disable(error);
        }
    }

    pub fn acquire(&self, desired_len: usize) -> Vec<u8> {
        let mut state = lock(&self.state);
        let candidate = state
            .buffers
            .iter()
            .enumerate()
            .filter(|(_, buffer)| buffer.capacity() >= desired_len)
            .min_by_key(|(_, buffer)| buffer.capacity())
            .map(|(index, _)| index);
        let Some(index) = candidate else {
            return Vec::new();
        };
        let mut buffer = state.buffers.swap_remove(index);
        state.retained_bytes = state.retained_bytes.saturating_sub(buffer.capacity());
        buffer.clear();
        buffer
    }

    pub fn recycle(&self, mut buffer: Vec<u8>) {
        buffer.clear();
        let retained = buffer.capacity();
        if retained == 0 || retained > MAX_RECYCLED_SHM_BYTES {
            return;
        }
        let mut state = lock(&self.state);
        let Some(next_retained) = state.retained_bytes.checked_add(retained) else {
            return;
        };
        if state.buffers.len() >= MAX_RECYCLED_SHM_BUFFERS || next_retained > MAX_RECYCLED_SHM_BYTES
        {
            return;
        }
        state.buffers.push(buffer);
        state.retained_bytes = next_retained;
    }
}

pub struct ShmPixelStorage {
    pub pixels: Option<Vec<u8>>,
    pub pool: Weak<ShmSnapshotPool>,
    pub mapped: Option<Arc<MappedShmStorage>>,
    pub fully_transparent: bool,
}

impl Drop for ShmPixelStorage {
    fn drop(&mut self) {
        let Some(pixels) = self.pixels.take() else {
            return;
        };
        if let Some(pool) = self.pool.upgrade() {
            pool.recycle(pixels);
        }
    }
}

#[derive(Clone)]
pub struct ShmTextureFrame {
    pub width: u32,
    pub height: u32,
    pub revision: u64,
    pub rgba: Arc<ShmPixelStorage>,
    pub feedback: Option<crate::surface_feedback::SurfaceFeedback>,
    pub color: Option<Arc<denial_color::color_space::SurfaceColor>>,
    /// The surface's opaque region covers it: see `ExternalTextureSource::opaque`.
    pub opaque: bool,
}

impl ShmTextureFrame {
    pub fn new_owned(
        width: u32,
        height: u32,
        revision: u64,
        rgba: Vec<u8>,
    ) -> Result<Self, &'static str> {
        Self::from_pixels(width, height, revision, rgba, Weak::new())
    }

    pub fn new_pooled(
        width: u32,
        height: u32,
        revision: u64,
        rgba: Vec<u8>,
        pool: &Arc<ShmSnapshotPool>,
    ) -> Result<Self, &'static str> {
        Self::from_pixels(width, height, revision, rgba, Arc::downgrade(pool))
    }

    pub fn from_pixels(
        width: u32,
        height: u32,
        revision: u64,
        rgba: Vec<u8>,
        pool: Weak<ShmSnapshotPool>,
    ) -> Result<Self, &'static str> {
        let expected = usize::try_from(width)
            .ok()
            .and_then(|width| width.checked_mul(usize::try_from(height).ok()?))
            .and_then(|pixels| pixels.checked_mul(4))
            .ok_or("SHM texture dimensions overflow")?;
        if width == 0 || height == 0 || rgba.len() != expected {
            return Err("SHM texture has invalid dimensions or payload length");
        }
        Ok(Self {
            width,
            height,
            revision,
            feedback: None,
            color: None,
            opaque: false,
            // Keep the snapshot's Vec allocation intact. Converting Vec<u8>
            // into Arc<[u8]> may copy the complete client frame.
            rgba: Arc::new(ShmPixelStorage {
                pixels: Some(rgba),
                pool,
                mapped: None,
                fully_transparent: false,
            }),
        })
    }

    pub fn new_mapped(
        width: u32,
        height: u32,
        revision: u64,
        mapped: Arc<MappedShmStorage>,
        fully_transparent: bool,
    ) -> Self {
        Self {
            width,
            height,
            revision,
            feedback: None,
            color: None,
            opaque: false,
            rgba: Arc::new(ShmPixelStorage {
                pixels: None,
                pool: Weak::new(),
                mapped: Some(mapped),
                fully_transparent,
            }),
        }
    }

    pub fn pixels(&self) -> &[u8] {
        self.rgba
            .pixels
            .as_deref()
            .expect("live SHM frame lost its pixel storage")
    }

    /// Names these pixels while anything holds the name: storage is
    /// immutable once published, so the same name means the same pixels.
    pub fn pixels_id(&self) -> ShmPixelsId {
        ShmPixelsId(Arc::downgrade(&self.rgba))
    }

    pub fn width(&self) -> u32 {
        self.width
    }

    pub fn height(&self) -> u32 {
        self.height
    }

    pub fn same_cursor_pixels(&self, other: &Self) -> bool {
        self.revision == other.revision && Arc::ptr_eq(&self.rgba, &other.rgba)
    }

    pub fn pixels_if_single(&self) -> Option<[u8; 4]> {
        (self.width == 1 && self.height == 1).then(|| {
            self.pixels()
                .try_into()
                .expect("one RGBA pixel is four bytes")
        })
    }

    pub fn is_fully_transparent(&self) -> bool {
        if self.rgba.mapped.is_some() {
            return self.rgba.fully_transparent;
        }
        self.pixels()
            .as_chunks::<4>()
            .0
            .iter()
            .all(|pixel| pixel[3] == 0)
    }
}

/// A frame's pixel storage, by identity (`ShmTextureFrame::pixels_id`). The
/// weak reference keeps the allocation's address from being reused.
#[derive(Clone)]
pub struct ShmPixelsId(Weak<ShmPixelStorage>);

impl PartialEq for ShmPixelsId {
    fn eq(&self, other: &Self) -> bool {
        Weak::ptr_eq(&self.0, &other.0)
    }
}

impl ShmPixelsId {
    pub fn names(&self, frame: &ShmTextureFrame) -> bool {
        std::ptr::eq(self.0.as_ptr(), Arc::as_ptr(&frame.rgba))
    }
}

#[derive(Clone)]
pub enum ExternalBufferGuard {
    Wayland {
        // Drops first: wl_buffer.release precedes the release point.
        _guard: RendererBufferGuard,
        release: Option<Arc<denial_kms::client_release::ClientRelease>>,
    },
    OwnedShm {
        frame: ShmTextureFrame,
    },
    OwnedNative {
        storage: Arc<NativeWindowStorage>,
    },
}

impl ExternalBufferGuard {
    /// Hand `fence`, a submission that sampled this guard's buffer, to the
    /// client release, and stop holding the release.
    pub fn sampled_by(&mut self, fence: &Arc<OwnedFd>) {
        if let Self::Wayland { release, .. } = self
            && let Some(release) = release.take()
        {
            release.sampled_by(fence);
        }
    }

    pub fn owned_native(&self) -> Option<&Arc<NativeWindowStorage>> {
        match self {
            Self::OwnedNative { storage } => Some(storage),
            _ => None,
        }
    }

    pub fn owned_shm(&self) -> Option<&ShmTextureFrame> {
        match self {
            Self::OwnedShm { frame } => Some(frame),
            _ => None,
        }
    }
}

#[derive(Clone)]
pub enum ExternalTextureSource {
    Dmabuf {
        dmabuf: Dmabuf,
        buffer_guard: Option<ExternalBufferGuard>,
        revision: u64,
        feedback: Option<crate::surface_feedback::SurfaceFeedback>,
        color: Option<Arc<denial_color::color_space::SurfaceColor>>,
        /// See `ExternalTextureSource::opaque`.
        opaque: bool,
    },
    Shm(ShmTextureFrame),
}

impl ExternalTextureSource {
    /// A single fully transparent pixel, as a client shows on a surface it
    /// keeps mapped but hidden: drawing it changes nothing.
    pub fn shows_nothing(&self) -> bool {
        let frame = match self {
            Self::Shm(frame) => frame,
            Self::Dmabuf {
                buffer_guard: Some(ExternalBufferGuard::OwnedShm { frame }),
                ..
            } => frame,
            Self::Dmabuf { .. } => return false,
        };
        frame.pixels_if_single() == Some([0; 4])
    }

    /// The buffer's size in pixels.
    pub fn pixel_size(&self) -> (u32, u32) {
        match self {
            Self::Dmabuf { dmabuf, .. } => (dmabuf.width(), dmabuf.height()),
            Self::Shm(frame) => (frame.width(), frame.height()),
        }
    }

    pub fn feedback(&self) -> Option<crate::surface_feedback::SurfaceFeedback> {
        match self {
            Self::Dmabuf { feedback, .. } => feedback.clone(),
            Self::Shm(frame) => frame.feedback.clone(),
        }
    }

    pub fn color(
        &self,
    ) -> Option<Arc<denial_color::color_space::SurfaceColor>> {
        match self {
            Self::Dmabuf { color, .. } => color.clone(),
            Self::Shm(frame) => frame.color.clone(),
        }
    }

    /// The surface shows these pixels at full opacity and its opaque region
    /// (`wl_surface.set_opaque_region`) covers all of it: what lies under it
    /// cannot be seen, whatever alpha the buffer's format carries.
    pub fn opaque(&self) -> bool {
        match self {
            Self::Dmabuf { opaque, .. } => *opaque,
            Self::Shm(frame) => frame.opaque,
        }
    }

    pub fn generation(&self) -> u64 {
        match self {
            Self::Dmabuf { revision, .. } => *revision,
            Self::Shm(frame) => frame.revision,
        }
    }

    pub fn same_generation(&self, other: &Self) -> bool {
        match (self.feedback(), other.feedback()) {
            (Some(a), Some(b)) if a.same(&b) => {}
            (None, None) => {}
            _ => return false,
        }
        if self.color() != other.color() {
            return false;
        }

        match (self, other) {
            (
                Self::Dmabuf {
                    dmabuf: current_buffer,
                    revision: current,
                    ..
                },
                Self::Dmabuf {
                    dmabuf: next_buffer,
                    revision: next,
                    ..
                },
            ) => current == next && current_buffer == next_buffer,
            (Self::Shm(current), Self::Shm(next)) => {
                current.revision == next.revision
                    && current.width == next.width
                    && current.height == next.height
                    && Arc::ptr_eq(&current.rgba, &next.rgba)
            }
            _ => false,
        }
    }
}

/// What changed in a surface's buffer since the frame published before it,
/// in buffer pixels `[x, y, width, height]`, between two of its commits.
#[derive(Clone, Debug)]
pub struct BufferDamage {
    pub since: Option<smithay::backend::renderer::utils::CommitCounter>,
    pub commit: smithay::backend::renderer::utils::CommitCounter,
    pub rects: Vec<[i32; 4]>,
}

/// What changed in a texture's pixels over some frames.
#[derive(Clone, Debug, Default, PartialEq)]
pub enum PixelDamage {
    #[default]
    Nothing,
    /// Buffer pixels `[x, y, width, height]`.
    Rects(Vec<[i32; 4]>),
    Whole,
}

impl PixelDamage {
    /// More rects than this become their bounds.
    const MAX_RECTS: usize = 16;

    pub fn join(&mut self, more: Self) {
        *self = match (std::mem::take(self), more) {
            (Self::Whole, _) | (_, Self::Whole) => Self::Whole,
            (Self::Nothing, more) => more,
            (this, Self::Nothing) => this,
            (Self::Rects(mut rects), Self::Rects(more)) => {
                rects.extend(more);
                if rects.len() > Self::MAX_RECTS {
                    let bounds = rects.iter().fold(rects[0], |[x, y, w, h], r| {
                        let (left, top) = (x.min(r[0]), y.min(r[1]));
                        let right = (x + w).max(r[0] + r[2]);
                        let bottom = (y + h).max(r[1] + r[3]);
                        [left, top, right - left, bottom - top]
                    });
                    rects = vec![bounds];
                }
                Self::Rects(rects)
            }
        };
    }
}

/// The generations that last became a slot's current, oldest first, each
/// with what changed from the one before it.
#[derive(Clone, Debug, Default)]
pub struct DamageHistory(VecDeque<HistoryEntry>);

#[derive(Clone, Debug)]
struct HistoryEntry {
    generation: u64,
    previous: Option<u64>,
    damage: PixelDamage,
}

impl DamageHistory {
    const KEPT: usize = 8;

    pub fn push(&mut self, generation: u64, previous: Option<u64>, damage: PixelDamage) {
        if self.0.len() == Self::KEPT {
            self.0.pop_front();
        }
        self.0.push_back(HistoryEntry {
            generation,
            previous,
            damage,
        });
    }

    /// The buffer pixels that changed from generation `old` to `new`
    /// (`[x, y, width, height]`); None when that is not known.
    pub fn between(&self, old: u64, new: u64) -> Option<Vec<[i32; 4]>> {
        let mut changed = PixelDamage::Nothing;
        let mut at = new;
        for _ in 0..Self::KEPT {
            if at == old {
                return match changed {
                    PixelDamage::Nothing => Some(Vec::new()),
                    PixelDamage::Rects(rects) => Some(rects),
                    PixelDamage::Whole => None,
                };
            }
            let entry = self.0.iter().rev().find(|entry| entry.generation == at)?;
            changed.join(entry.damage.clone());
            at = entry.previous?;
        }
        None
    }
}

