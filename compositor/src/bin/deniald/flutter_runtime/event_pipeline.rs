//! Bounded cross-thread event ingress and coalesced wakeups.

use super::*;

#[derive(Debug, Default)]
pub(super) struct PlatformTaskBudget {
    pending: AtomicUsize,
}

impl PlatformTaskBudget {
    pub(super) fn try_acquire(self: &Arc<Self>) -> Option<PlatformTaskPermit> {
        self.pending
            // This is only a hard quota. Task publication and ownership are
            // synchronized independently by the inbox mutex and Arc.
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |pending| {
                (pending < MAX_PENDING_PLATFORM_TASKS).then_some(pending + 1)
            })
            .ok()?;
        Some(PlatformTaskPermit {
            budget: Arc::clone(self),
        })
    }

    #[cfg(test)]
    pub(super) fn pending(&self) -> usize {
        self.pending.load(Ordering::Acquire)
    }
}

#[derive(Debug)]
pub(super) struct PlatformTaskPermit {
    budget: Arc<PlatformTaskBudget>,
}

impl Drop for PlatformTaskPermit {
    fn drop(&mut self) {
        let previous = self.budget.pending.fetch_sub(1, Ordering::Relaxed);
        debug_assert!(previous != 0, "platform task budget underflow");
    }
}

#[derive(Debug)]
pub(super) struct PendingPlatformTask {
    pub(super) task: ScheduledTask,
    pub(super) permit: PlatformTaskPermit,
}

#[derive(Debug, Default)]
pub(super) struct CoalescedWakeup {
    pending: AtomicBool,
}

impl CoalescedWakeup {
    pub(super) fn begin(&self) -> bool {
        // The flag carries edge ownership only; payloads are synchronized by
        // their broker mutex or channel send.
        !self.pending.swap(true, Ordering::Relaxed)
    }

    pub(super) fn acknowledge(&self) {
        self.pending.store(false, Ordering::Relaxed);
    }
}

/// A producer-side batch whose channel carries only an edge notification.
///
/// Producers append before arming the wakeup. The consumer disarms before it
/// swaps buffers, so a concurrent append is either included in this batch or
/// emits the next edge; it can never remain queued without a wakeup.
#[derive(Debug)]
pub(super) struct CoalescedInbox<T> {
    state: Mutex<CoalescedInboxState<T>>,
}

#[derive(Debug)]
struct CoalescedInboxState<T> {
    items: Vec<T>,
    armed: bool,
}

impl<T> CoalescedInbox<T> {
    pub(super) fn with_capacity(capacity: usize) -> Self {
        Self {
            state: Mutex::new(CoalescedInboxState {
                items: Vec::with_capacity(capacity),
                armed: false,
            }),
        }
    }

    /// Returns true only for the producer responsible for sending the edge.
    pub(super) fn push(&self, item: T) -> bool {
        let mut state = lock(&self.state);
        state.items.push(item);
        if state.armed {
            false
        } else {
            state.armed = true;
            true
        }
    }

    pub(super) fn take_into(&self, output: &mut Vec<T>) {
        debug_assert!(output.is_empty());
        let mut state = lock(&self.state);
        state.armed = false;
        mem::swap(&mut state.items, output);
    }

    pub(super) fn discard_after_failed_wakeup(&self) {
        let mut state = lock(&self.state);
        state.armed = false;
        state.items.clear();
    }
}

#[derive(Debug)]
pub enum RuntimeEvent {
    Engine {
        generation: u64,
        event: EngineEvent,
    },
    PlatformTasksReady {
        generation: u64,
    },
    QueueOverflow {
        generation: u64,
        queue: &'static str,
    },
    FatalRender {
        generation: u64,
        reason: String,
    },
    VmServiceUri {
        generation: u64,
        uri: String,
    },
    FrameReady {
        generation: u64,
    },
    SampledBuffersReady {
        fence: Option<OwnedFd>,
        batch: SampledBufferHoldBatch,
    },
}
