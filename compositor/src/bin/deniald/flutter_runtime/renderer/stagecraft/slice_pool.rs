//! Retired slice images kept for later slice versions. Every version the
//! engine renders gets fresh storage; most take a pooled image instead of
//! new memory. A pooled image unused for `IDLE` is destroyed by the pool's
//! own thread, so a still screen, which reaps nothing, gives the memory back
//! too. The thread sleeps without a timeout while the pool is empty.

use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use super::device::Image;

/// A pooled image unused this long is destroyed.
const IDLE: Duration = Duration::from_secs(1);

/// At most this many bytes stay pooled; the oldest go first.
const BYTES: u64 = 96 << 20;

pub(super) struct SlicePool {
    shared: Arc<Shared>,
    janitor: Option<JoinHandle<()>>,
}

struct Shared {
    entries: Mutex<Entries>,
    wake: Condvar,
}

#[derive(Default)]
struct Entries {
    /// Oldest first, with when each retired.
    images: Vec<(Instant, Image)>,
    closing: bool,
}

fn lock(shared: &Shared) -> std::sync::MutexGuard<'_, Entries> {
    shared
        .entries
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

impl SlicePool {
    pub(super) fn new() -> Self {
        let shared = Arc::new(Shared {
            entries: Mutex::new(Entries::default()),
            wake: Condvar::new(),
        });
        let janitor = std::thread::Builder::new()
            .name("stagecraft-pool".into())
            .spawn({
                let shared = Arc::clone(&shared);
                move || janitor(&shared)
            })
            .map_err(|error| tracing::warn!(%error, "Stagecraft slice pool expires only on reap"))
            .ok();
        Self { shared, janitor }
    }

    /// Keeps a retired image the GPU no longer uses.
    pub(super) fn put(&self, image: Image) {
        let evicted = {
            let mut entries = lock(&self.shared);
            let was_empty = entries.images.is_empty();
            entries.images.push((Instant::now(), image));
            let mut bytes: u64 = entries
                .images
                .iter()
                .map(|(_, image)| image.allocated_bytes())
                .sum();
            let mut over = 0;
            while bytes > BYTES && over < entries.images.len() {
                bytes -= entries.images[over].1.allocated_bytes();
                over += 1;
            }
            if was_empty {
                self.shared.wake.notify_one();
            }
            entries.images.drain(..over).collect::<Vec<_>>()
        };
        // Destroyed outside the pool's lock.
        drop(evicted);
    }

    /// The smallest pooled image at least `width`×`height` and at most half
    /// as large again in area: slices change size as the shell moves.
    pub(super) fn take(&self, width: u32, height: u32) -> Option<Image> {
        let needed = u64::from(width) * u64::from(height);
        let mut entries = lock(&self.shared);
        let index = entries
            .images
            .iter()
            .enumerate()
            .filter(|(_, (_, image))| {
                let (w, h) = image.size;
                let area = u64::from(w) * u64::from(h);
                w >= width && h >= height && area * 2 <= needed * 3
            })
            .min_by_key(|(_, (_, image))| u64::from(image.size.0) * u64::from(image.size.1))
            .map(|(index, _)| index)?;
        Some(entries.images.remove(index).1)
    }

    /// The allocator bytes of the pooled images; for the log marks.
    pub(super) fn bytes(&self) -> u64 {
        lock(&self.shared)
            .images
            .iter()
            .map(|(_, image)| image.allocated_bytes())
            .sum()
    }
}

impl Drop for SlicePool {
    fn drop(&mut self) {
        lock(&self.shared).closing = true;
        self.shared.wake.notify_one();
        if let Some(janitor) = self.janitor.take() {
            let _ = janitor.join();
        }
    }
}

/// Takes the images idle for `IDLE` at `now` out of the pool.
fn expired(entries: &mut Entries, now: Instant) -> Vec<(Instant, Image)> {
    let idle = entries
        .images
        .iter()
        .take_while(|(retired, _)| now.duration_since(*retired) >= IDLE)
        .count();
    entries.images.drain(..idle).collect()
}

fn janitor(shared: &Shared) {
    let mut entries = lock(shared);
    loop {
        if entries.closing {
            return;
        }
        let gone = expired(&mut entries, Instant::now());
        if !gone.is_empty() {
            // Destroyed outside the pool's lock.
            drop(entries);
            drop(gone);
            entries = lock(shared);
            continue;
        }
        entries = match entries.images.first() {
            None => shared
                .wake
                .wait(entries)
                .unwrap_or_else(std::sync::PoisonError::into_inner),
            Some((retired, _)) => {
                let wait = IDLE.saturating_sub(retired.elapsed());
                shared
                    .wake
                    .wait_timeout(entries, wait)
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .0
            }
        };
    }
}

#[cfg(test)]
impl SlicePool {
    pub(super) fn len(&self) -> usize {
        lock(&self.shared).images.len()
    }

    /// Expires as if `IDLE` had passed since every image retired.
    pub(super) fn expire_all(&self) {
        drop(expired(&mut lock(&self.shared), Instant::now() + IDLE));
    }
}
