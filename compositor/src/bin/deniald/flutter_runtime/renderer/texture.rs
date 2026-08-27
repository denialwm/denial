//! External-texture ownership, caching, sampling, and producer arbitration.

use super::*;

#[path = "handler.rs"]
mod handler;

pub(in crate::flutter_runtime) use handler::FlutterGlHandler;

#[derive(Debug, Default)]
pub(in crate::flutter_runtime) struct ExternalTextureResourceBudget {
    live: AtomicUsize,
}

impl ExternalTextureResourceBudget {
    pub(in crate::flutter_runtime) fn try_acquire(
        self: &Arc<Self>,
    ) -> Option<ExternalTextureResourcePermit> {
        self.live
            // This counter bounds ownership but publishes no binding data;
            // Arc and the surrounding mutexes provide that synchronization.
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |live| {
                (live < MAX_LIVE_EXTERNAL_TEXTURE_RESOURCES).then_some(live + 1)
            })
            .ok()?;
        Some(ExternalTextureResourcePermit {
            budget: Arc::clone(self),
        })
    }
}

pub(in crate::flutter_runtime) struct ExternalTextureResourcePermit {
    budget: Arc<ExternalTextureResourceBudget>,
}

impl Drop for ExternalTextureResourcePermit {
    fn drop(&mut self) {
        let previous = self.budget.live.fetch_sub(1, Ordering::Relaxed);
        debug_assert!(previous != 0, "external texture resource budget underflow");
    }
}

pub(in crate::flutter_runtime) struct ExternalTextureBinding {
    // The dma-buf file descriptors must remain live for the EGLImage lifetime.
    pub(in crate::flutter_runtime) dmabuf_image: Option<(Dmabuf, usize)>,
    pub(in crate::flutter_runtime) texture: u32,
    pub(in crate::flutter_runtime) _resource_permit: ExternalTextureResourcePermit,
}

pub(in crate::flutter_runtime) struct RetiredExternalBindingQueue {
    pub(in crate::flutter_runtime) bindings: Mutex<Vec<ExternalTextureBinding>>,
    pub(in crate::flutter_runtime) pending: AtomicBool,
}

impl RetiredExternalBindingQueue {
    pub(in crate::flutter_runtime) fn new() -> Self {
        Self {
            bindings: Mutex::new(Vec::new()),
            pending: AtomicBool::new(false),
        }
    }

    fn push(&self, binding: ExternalTextureBinding) {
        lock(&self.bindings).push(binding);
        // Queue contents are published by the mutex; this is only a fast-path
        // hint for avoiding its acquisition.
        self.pending.store(true, Ordering::Relaxed);
    }
}

pub(in crate::flutter_runtime) struct CachedTextureBinding {
    pub(in crate::flutter_runtime) binding: Option<ExternalTextureBinding>,
    pub(in crate::flutter_runtime) retirements: Arc<RetiredExternalBindingQueue>,
}

impl CachedTextureBinding {
    fn texture(&self) -> u32 {
        self.binding.as_ref().map_or(0, |binding| binding.texture)
    }
}

impl Drop for CachedTextureBinding {
    fn drop(&mut self) {
        if let Some(binding) = self.binding.take() {
            self.retirements.push(binding);
        }
    }
}

pub(in crate::flutter_runtime) enum ExternalTextureLeaseResource {
    Dmabuf {
        // The cached EGLImage/texture can outlive an individual Flutter frame,
        // but the producer buffer guard must not: releasing this lease is what
        // eventually permits the producer to recycle its allocation.
        _binding: Arc<CachedTextureBinding>,
        _buffer_guard: Option<ExternalBufferGuard>,
        _resource_permit: ExternalTextureResourcePermit,
    },
    Shm {
        _binding: Arc<CachedTextureBinding>,
        _resource_permit: ExternalTextureResourcePermit,
    },
    Retained {
        // Native producer buffers are copied once into this private texture.
        // Later Flutter frames never sample producer-owned storage after its
        // release fence signals.
        _binding: Arc<CachedTextureBinding>,
        _resource_permit: ExternalTextureResourcePermit,
    },
}

struct PreparedExternalTexture {
    texture_id: i64,
    source_generation: u64,
    width: usize,
    height: usize,
    name: u32,
    resource: ExternalTextureLeaseResource,
    sampled_buffer: Option<ExternalBufferGuard>,
}

type ExternalTextureLeasePool = Mutex<Vec<Box<ExternalTextureLease>>>;

pub(in crate::flutter_runtime) struct ExternalTextureLease {
    pub(in crate::flutter_runtime) resource: Option<ExternalTextureLeaseResource>,
    pub(in crate::flutter_runtime) pool: Weak<ExternalTextureLeasePool>,
}

impl ExternalTextureLease {
    fn retire(mut lease: Box<Self>) {
        // Release buffer guards and resource permits before making this token
        // reusable. Cached GL bindings remain alive through their cache Arc.
        drop(lease.resource.take());
        let Some(pool) = lease.pool.upgrade() else {
            return;
        };
        let mut available = lock(&pool);
        if available.len() < MAX_CACHED_EXTERNAL_TEXTURE_LEASES {
            available.push(lease);
        }
    }
}

struct RecencyEntry<K, V> {
    key: K,
    value: V,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(in crate::flutter_runtime) struct RecencyCacheStats {
    pub(in crate::flutter_runtime) hits: u64,
    pub(in crate::flutter_runtime) misses: u64,
    pub(in crate::flutter_runtime) capacity_evictions: u64,
    pub(in crate::flutter_runtime) explicit_removals: u64,
}

/// Tiny bounded LRU used on the raster path. The ring is deliberate: Flutter
/// normally visits external textures in the same order every frame, making
/// each oldest-to-newest rotation O(1), while the bounded linear lookup keeps
/// dma-buf identity as Smithay's Arc identity without a second hash-key model.
pub(in crate::flutter_runtime) struct RecencyCache<K, V> {
    entries: VecDeque<RecencyEntry<K, V>>,
    capacity: usize,
    stats: RecencyCacheStats,
}

impl<K: Eq, V: Clone> RecencyCache<K, V> {
    pub(in crate::flutter_runtime) fn new(capacity: usize) -> Self {
        assert!(capacity > 0, "recency cache capacity must be positive");
        Self {
            entries: VecDeque::with_capacity(capacity),
            capacity,
            stats: RecencyCacheStats::default(),
        }
    }

    pub(in crate::flutter_runtime) fn get_by(
        &mut self,
        mut matches: impl FnMut(&K) -> bool,
    ) -> Option<V> {
        let Some(index) = self.entries.iter().position(|entry| matches(&entry.key)) else {
            if cfg!(test) {
                self.stats.misses = self.stats.misses.saturating_add(1);
            }
            return None;
        };
        if cfg!(test) {
            self.stats.hits = self.stats.hits.saturating_add(1);
        }
        let entry = self
            .entries
            .remove(index)
            .expect("located recency entry disappeared");
        let value = entry.value.clone();
        // Entries are stored oldest-to-newest, avoiding a wrapping/saturating
        // logical clock entirely.
        self.entries.push_back(entry);
        Some(value)
    }

    pub(in crate::flutter_runtime) fn insert(&mut self, key: K, value: V) -> Option<V> {
        if let Some(index) = self.entries.iter().position(|entry| entry.key == key) {
            let mut entry = self
                .entries
                .remove(index)
                .expect("located recency entry disappeared");
            let previous = mem::replace(&mut entry.value, value);
            self.entries.push_back(entry);
            return Some(previous);
        }
        self.entries.push_back(RecencyEntry { key, value });
        if self.entries.len() <= self.capacity {
            return None;
        }
        if cfg!(test) {
            self.stats.capacity_evictions = self.stats.capacity_evictions.saturating_add(1);
        }
        Some(
            self.entries
                .pop_front()
                .expect("over-capacity recency cache is non-empty")
                .value,
        )
    }

    pub(in crate::flutter_runtime) fn remove_where(
        &mut self,
        mut predicate: impl FnMut(&K) -> bool,
    ) -> Vec<V> {
        let mut removed = Vec::new();
        let mut index = 0;
        while index < self.entries.len() {
            if predicate(&self.entries[index].key) {
                removed.push(
                    self.entries
                        .remove(index)
                        .expect("indexed recency entry disappeared")
                        .value,
                );
            } else {
                index += 1;
            }
        }
        if cfg!(test) {
            self.stats.explicit_removals = self
                .stats
                .explicit_removals
                .saturating_add(u64::try_from(removed.len()).unwrap_or(u64::MAX));
        }
        removed
    }

    pub(in crate::flutter_runtime) fn drain(&mut self) -> Vec<V> {
        self.entries.drain(..).map(|entry| entry.value).collect()
    }
}

/// Independent bounded buffer rings keyed by Flutter external-texture ID.
///
/// A single global LRU becomes a complete miss stream when several clients'
/// rotating DMA-BUF pools collectively exceed its capacity: Flutter visits
/// the textures in a stable order, so each miss evicts the buffer needed by a
/// later texture in the same frame. Partitioning keeps one busy client from
/// evicting every other client's reusable EGLImages. The compositor-wide
/// `ExternalTextureResourceBudget` remains the hard ownership bound.
pub(in crate::flutter_runtime) struct PartitionedRecencyCache<O, K, V> {
    partitions: HashMap<O, RecencyCache<K, V>>,
    capacity_per_partition: usize,
}

impl<O: Eq + Hash, K: Eq, V: Clone> PartitionedRecencyCache<O, K, V> {
    pub(in crate::flutter_runtime) fn new(capacity_per_partition: usize) -> Self {
        assert!(
            capacity_per_partition > 0,
            "partitioned recency cache capacity must be positive"
        );
        Self {
            partitions: HashMap::new(),
            capacity_per_partition,
        }
    }

    pub(in crate::flutter_runtime) fn get_by(
        &mut self,
        owner: &O,
        matches: impl FnMut(&K) -> bool,
    ) -> Option<V> {
        self.partitions.get_mut(owner)?.get_by(matches)
    }

    pub(in crate::flutter_runtime) fn insert(&mut self, owner: O, key: K, value: V) -> Option<V> {
        let capacity = self.capacity_per_partition;
        self.partitions
            .entry(owner)
            .or_insert_with(|| RecencyCache::new(capacity))
            .insert(key, value)
    }

    pub(in crate::flutter_runtime) fn remove(&mut self, owner: &O) -> Vec<V> {
        self.partitions
            .remove(owner)
            .map_or_else(Vec::new, |mut partition| partition.drain())
    }

    pub(in crate::flutter_runtime) fn drain(&mut self) -> Vec<V> {
        self.partitions
            .drain()
            .flat_map(|(_, mut partition)| partition.drain())
            .collect()
    }
}

#[derive(Default)]
struct ShmSnapshotPoolState {
    buffers: Vec<Vec<u8>>,
    retained_bytes: usize,
}

pub(crate) struct ShmSnapshotPool {
    state: Mutex<ShmSnapshotPoolState>,
}

impl ShmSnapshotPool {
    pub(crate) fn new() -> Self {
        Self {
            state: Mutex::new(ShmSnapshotPoolState {
                buffers: Vec::with_capacity(MAX_RECYCLED_SHM_BUFFERS),
                retained_bytes: 0,
            }),
        }
    }

    pub(crate) fn acquire(&self, desired_len: usize) -> Vec<u8> {
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

    fn recycle(&self, mut buffer: Vec<u8>) {
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

struct ShmPixelStorage {
    pixels: Option<Vec<u8>>,
    pool: Weak<ShmSnapshotPool>,
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
pub(crate) struct ShmTextureFrame {
    width: u32,
    height: u32,
    revision: u64,
    rgba: Arc<ShmPixelStorage>,
}

impl ShmTextureFrame {
    pub(crate) fn new_pooled(
        width: u32,
        height: u32,
        revision: u64,
        rgba: Vec<u8>,
        pool: &Arc<ShmSnapshotPool>,
    ) -> Result<Self, &'static str> {
        Self::from_pixels(width, height, revision, rgba, Arc::downgrade(pool))
    }

    fn from_pixels(
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
            // Keep the snapshot's Vec allocation intact. Converting Vec<u8>
            // into Arc<[u8]> may copy the complete client frame.
            rgba: Arc::new(ShmPixelStorage {
                pixels: Some(rgba),
                pool,
            }),
        })
    }

    pub(in crate::flutter_runtime) fn pixels(&self) -> &[u8] {
        self.rgba
            .pixels
            .as_deref()
            .expect("live SHM frame lost its pixel storage")
    }

    pub(crate) fn width(&self) -> u32 {
        self.width
    }

    pub(crate) fn height(&self) -> u32 {
        self.height
    }
}

#[derive(Clone)]
pub(in crate::flutter_runtime) enum ExternalBufferGuard {
    Wayland { _guard: RendererBufferGuard },
    Native(NativeBufferRelease),
}

impl ExternalBufferGuard {
    fn is_native(&self) -> bool {
        matches!(self, Self::Native(_))
    }
}

#[derive(Clone)]
pub(in crate::flutter_runtime) enum ExternalTextureSource {
    Dmabuf {
        dmabuf: Dmabuf,
        buffer_guard: Option<ExternalBufferGuard>,
        revision: u64,
    },
    Shm(ShmTextureFrame),
}

impl ExternalTextureSource {
    pub(in crate::flutter_runtime) fn generation(&self) -> u64 {
        match self {
            Self::Dmabuf { revision, .. } => *revision,
            Self::Shm(frame) => frame.revision,
        }
    }

    pub(in crate::flutter_runtime) fn same_generation(&self, other: &Self) -> bool {
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

#[derive(Default)]
pub(in crate::flutter_runtime) struct ExternalTextureSlot {
    pub(in crate::flutter_runtime) current: Option<ExternalTextureSource>,
    pub(in crate::flutter_runtime) queued: Option<ExternalTextureSource>,
    pub(in crate::flutter_runtime) lookahead: Option<ExternalTextureSource>,
    pub(in crate::flutter_runtime) current_sampled: bool,
    pub(in crate::flutter_runtime) expects_sample: bool,
}

impl ExternalTextureSlot {
    pub(in crate::flutter_runtime) fn queue(
        &mut self,
        source: ExternalTextureSource,
        expects_sample: bool,
    ) -> bool {
        self.expects_sample = expects_sample;
        let unchanged = self
            .queued
            .as_ref()
            .is_some_and(|candidate| candidate.same_generation(&source))
            || self
                .lookahead
                .as_ref()
                .is_some_and(|candidate| candidate.same_generation(&source))
            || self
                .current
                .as_ref()
                .is_some_and(|candidate| candidate.same_generation(&source));
        if unchanged {
            return false;
        }
        // Preserve one generation on either side of a tick boundary. The
        // immediate successor is stable; only excess lookahead is latest-only.
        if self.queued.is_none() {
            self.queued = Some(source);
        } else {
            self.lookahead = Some(source);
        }
        true
    }

    pub(in crate::flutter_runtime) fn advance(&mut self) -> bool {
        if self.queued.is_none()
            || (self.current.is_some() && !self.current_sampled && self.expects_sample)
        {
            return false;
        }
        self.current = self.queued.take();
        self.queued = self.lookahead.take();
        self.current_sampled = false;
        true
    }

    pub(in crate::flutter_runtime) fn has_queued(&self) -> bool {
        self.queued.is_some()
    }
}

struct SampledBufferHold {
    texture_id: i64,
    generation: u64,
    buffer_guard: ExternalBufferGuard,
}

type SampledBufferBatchPool = Mutex<Vec<Vec<SampledBufferHold>>>;

pub struct SampledBufferHoldBatch {
    holds: Option<Vec<SampledBufferHold>>,
    pool: Weak<SampledBufferBatchPool>,
}

impl SampledBufferHoldBatch {
    pub(in crate::flutter_runtime) fn len(&self) -> usize {
        self.holds.as_ref().map_or(0, Vec::len)
    }

    pub(in crate::flutter_runtime) fn texture_generations(
        &self,
    ) -> impl Iterator<Item = (i64, u64)> + '_ {
        self.holds
            .iter()
            .flatten()
            .map(|hold| (hold.texture_id, hold.generation))
    }

    pub(crate) fn materialize_native_releases(
        &self,
        fence: std::os::fd::BorrowedFd<'_>,
    ) -> Result<(), Box<dyn Error>> {
        for hold in self.holds.iter().flatten() {
            if let ExternalBufferGuard::Native(release) = &hold.buffer_guard {
                release.materialize(fence)?;
            }
        }
        Ok(())
    }

    pub(crate) fn complete_native_releases(&self) -> Result<(), Box<dyn Error>> {
        for hold in self.holds.iter().flatten() {
            if let ExternalBufferGuard::Native(release) = &hold.buffer_guard {
                release.complete()?;
            }
        }
        Ok(())
    }

    pub(crate) fn complete_native_releases_without_fence(&self) -> Result<(), Box<dyn Error>> {
        for hold in self.holds.iter().flatten() {
            if let ExternalBufferGuard::Native(release) = &hold.buffer_guard {
                release.complete_without_fence()?;
            }
        }
        Ok(())
    }
}

impl std::fmt::Debug for SampledBufferHoldBatch {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SampledBufferHoldBatch")
            .field("len", &self.holds.as_ref().map_or(0, std::vec::Vec::len))
            .finish()
    }
}

impl Drop for SampledBufferHoldBatch {
    fn drop(&mut self) {
        let Some(mut holds) = self.holds.take() else {
            return;
        };
        // RendererBufferGuard destruction may emit wl_buffer.release and, for
        // wp_linux_drm_syncobj_v1 clients, signal the matching release point.
        // Batches are deliberately dropped by the compositor event loop only
        // after the Flutter render fence signals, never by the raster thread.
        holds.clear();
        let Some(pool) = self.pool.upgrade() else {
            return;
        };
        let mut available = lock(&pool);
        if available.len() < MAX_RECYCLED_SAMPLED_BUFFER_BATCHES {
            available.push(holds);
        }
    }
}

#[repr(u8)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::flutter_runtime) enum FlutterProducerState {
    Idle,
    Requested,
    Rasterizing,
    Preparing,
}

impl FlutterProducerState {
    const fn as_u8(self) -> u8 {
        self as u8
    }

    fn from_u8(value: u8) -> Self {
        match value {
            value if value == Self::Requested.as_u8() => Self::Requested,
            value if value == Self::Rasterizing.as_u8() => Self::Rasterizing,
            value if value == Self::Preparing.as_u8() => Self::Preparing,
            _ => Self::Idle,
        }
    }
}

/// Serializes display authorization with Flutter's asynchronous UI/raster
/// pipeline. `OnVsync` can legitimately produce no raster task, so a
/// reservation cannot remain `Requested` forever; conversely, releasing it
/// immediately from a render-thread marker races ahead of the UI thread that
/// will enqueue the real raster task.
pub(in crate::flutter_runtime) struct ProducerArbiter {
    state: AtomicU8,
    requested_at: Mutex<Option<Instant>>,
}

impl ProducerArbiter {
    pub(in crate::flutter_runtime) fn new() -> Self {
        Self {
            state: AtomicU8::new(FlutterProducerState::Idle.as_u8()),
            requested_at: Mutex::new(None),
        }
    }

    pub(in crate::flutter_runtime) fn try_request(&self, now: Instant) -> bool {
        if self
            .state
            .compare_exchange(
                FlutterProducerState::Idle.as_u8(),
                FlutterProducerState::Requested.as_u8(),
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_err()
        {
            return false;
        }
        *lock(&self.requested_at) = Some(now);
        true
    }

    pub(in crate::flutter_runtime) fn cancel_request(&self) {
        self.state
            .store(FlutterProducerState::Idle.as_u8(), Ordering::Release);
        lock(&self.requested_at).take();
    }

    pub(in crate::flutter_runtime) fn begin_raster(&self) -> bool {
        // A raster task may begin after a no-raster timeout won its Requested
        // -> Idle race. Claim Idle as well so that late work still excludes a
        // second producer until present()/raster_idle() closes it.
        loop {
            let state = FlutterProducerState::from_u8(self.state.load(Ordering::Acquire));
            if !matches!(
                state,
                FlutterProducerState::Idle | FlutterProducerState::Requested
            ) {
                return false;
            }
            if self
                .state
                .compare_exchange(
                    state.as_u8(),
                    FlutterProducerState::Rasterizing.as_u8(),
                    Ordering::AcqRel,
                    Ordering::Acquire,
                )
                .is_ok()
            {
                lock(&self.requested_at).take();
                return true;
            }
        }
    }

    pub(in crate::flutter_runtime) fn begin_present(&self) {
        self.state
            .store(FlutterProducerState::Preparing.as_u8(), Ordering::Release);
        lock(&self.requested_at).take();
    }

    pub(in crate::flutter_runtime) fn finish(&self) -> FlutterProducerState {
        let previous = FlutterProducerState::from_u8(
            self.state
                .swap(FlutterProducerState::Idle.as_u8(), Ordering::AcqRel),
        );
        lock(&self.requested_at).take();
        previous
    }
}

#[derive(Clone)]
pub(crate) struct ExternalTextureFrame {
    pub texture_id: i64,
    source: ExternalTextureSource,
    expects_sample: bool,
}

impl ExternalTextureFrame {
    pub(crate) fn from_dmabuf(
        texture_id: i64,
        dmabuf: Dmabuf,
        buffer_guard: RendererBufferGuard,
        revision: u64,
        expects_sample: bool,
    ) -> Self {
        Self {
            texture_id,
            source: ExternalTextureSource::Dmabuf {
                dmabuf,
                buffer_guard: Some(ExternalBufferGuard::Wayland {
                    _guard: buffer_guard,
                }),
                revision,
            },
            expects_sample,
        }
    }

    pub(crate) fn from_owned_dmabuf(texture_id: i64, dmabuf: Dmabuf, revision: u64) -> Self {
        Self {
            texture_id,
            source: ExternalTextureSource::Dmabuf {
                dmabuf,
                buffer_guard: None,
                revision,
            },
            expects_sample: false,
        }
    }

    pub(crate) fn from_native_dmabuf(
        texture_id: i64,
        dmabuf: Dmabuf,
        release: NativeBufferRelease,
        revision: u64,
        expects_sample: bool,
    ) -> Self {
        Self {
            texture_id,
            source: ExternalTextureSource::Dmabuf {
                dmabuf,
                buffer_guard: Some(ExternalBufferGuard::Native(release)),
                revision,
            },
            expects_sample,
        }
    }

    pub(crate) fn from_shm(texture_id: i64, frame: ShmTextureFrame, expects_sample: bool) -> Self {
        Self {
            texture_id,
            source: ExternalTextureSource::Shm(frame),
            expects_sample,
        }
    }
}

pub(crate) struct SyncedWaylandScene {
    pub(crate) windows: Vec<wire::WindowDescription>,
    pub(crate) textures: Vec<ExternalTextureFrame>,
    pub(crate) window_snapshot_changed: bool,
}

pub(in crate::flutter_runtime) unsafe extern "C" fn retire_external_texture(
    user_data: *mut c_void,
) {
    if user_data.is_null() {
        return;
    }
    let retired = contain_ffi_unwind(|| {
        // SAFETY: every non-null pointer installed in FlutterOpenGLTexture was
        // produced by Box::into_raw exactly once for this callback. Reclaiming
        // it inside the guard also contains panics from field destructors.
        ExternalTextureLease::retire(unsafe {
            Box::from_raw(user_data.cast::<ExternalTextureLease>())
        });
    });
    if !retired {
        // Logging is also Rust code invoked from the C trampoline, so keep it
        // inside the same no-unwind discipline.
        let _ = contain_ffi_unwind(|| {
            error!("panic while retiring a Flutter external texture lease");
        });
    }
}

pub(in crate::flutter_runtime) fn contain_ffi_unwind(callback: impl FnOnce()) -> bool {
    match catch_unwind(AssertUnwindSafe(callback)) {
        Ok(()) => true,
        Err(payload) => {
            // A `panic_any` payload owns arbitrary user code in Drop. Dropping
            // it after catch_unwind could start a second unwind across C.
            mem::forget(payload);
            false
        }
    }
}
