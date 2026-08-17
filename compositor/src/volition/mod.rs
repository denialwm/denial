//! Volition: ordered atomic-KMS presentation lookahead.
//!
//! Volition is Denial's in-tree display synchronization library. It owns the
//! DRM file descriptor, atomic plane requests, and a bounded deadline scheduler
//! which approaches each physical display edge without blocking in a DRM
//! ioctl. The compositor remains responsible for deciding *what*
//! to present, retaining buffers until page-flip completion, and observing
//! render fences before submitting lookahead work.
//!
//! The separation is intentional: changes to KMS submission timing belong in
//! this module; shell, Flutter, Wayland, DPMS, and screenshot policy do not.

use std::cmp::Ordering as CmpOrdering;
use std::collections::BinaryHeap;
use std::fmt;
use std::io;
use std::os::fd::{AsFd, AsRawFd, BorrowedFd, OwnedFd};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{
    Receiver, RecvTimeoutError, SyncSender, TryRecvError, TrySendError, sync_channel,
};
use std::thread;
use std::time::{Duration, Instant};

use drm_ffi::mode as drm_mode;
use smithay::reexports::drm::control::{
    AtomicCommitFlags, RawResourceHandle, framebuffer, plane, property,
};

use crate::topology::PixelRect;

const MAX_ATOMIC_PLANE_PROPERTIES: usize = 6;
const LOOKAHEAD_RETRY_INTERVAL: Duration = Duration::from_micros(100);
const LOOKAHEAD_MAX_WAIT: Duration = Duration::from_millis(100);
static NEXT_INSTANCE: AtomicU64 = AtomicU64::new(1);

/// Maximum number of generations Denial may retain for one output stream.
///
/// One generation is currently scanning toward completion while the second
/// may sleep in Volition until DRM can legally advance it.
pub const MAX_IN_FLIGHT_COMMITS_PER_STREAM: usize = 2;

fn next_instance() -> u64 {
    loop {
        let instance = NEXT_INSTANCE.fetch_add(1, Ordering::Relaxed);
        if instance != 0 {
            return instance;
        }
    }
}

/// Atomic properties required to move one primary plane to a framebuffer.
#[derive(Clone, Copy, Debug)]
pub struct PlaneProperties {
    pub framebuffer: property::Handle,
    pub source_x: property::Handle,
    pub source_y: property::Handle,
    pub source_width: property::Handle,
    pub source_height: property::Handle,
    pub in_fence_fd: Option<property::Handle>,
}

/// Reusable atomic state for one output plane.
///
/// DRM copies these fixed arrays during each ioctl. A request can therefore
/// be retained by Denial and cloned into a Volition lookahead job.
#[derive(Clone, Debug)]
pub struct PlaneCommit {
    objects: [u32; 1],
    property_counts: [u32; 1],
    properties: [u32; MAX_ATOMIC_PLANE_PROPERTIES],
    values: [u64; MAX_ATOMIC_PLANE_PROPERTIES],
    property_count: usize,
    fence_index: Option<usize>,
}

impl PlaneCommit {
    pub fn new(plane: plane::Handle, properties: PlaneProperties, source: PixelRect) -> Self {
        let plane: RawResourceHandle = plane.into();
        let mut request = Self {
            objects: [u32::from(plane)],
            property_counts: [0],
            properties: [0; MAX_ATOMIC_PLANE_PROPERTIES],
            values: [0; MAX_ATOMIC_PLANE_PROPERTIES],
            property_count: 0,
            fence_index: None,
        };
        request.push(properties.framebuffer, 0);
        request.push(properties.source_x, u64::from(source.x) << 16);
        request.push(properties.source_y, u64::from(source.y) << 16);
        request.push(properties.source_width, u64::from(source.width) << 16);
        request.push(properties.source_height, u64::from(source.height) << 16);
        if let Some(property) = properties.in_fence_fd {
            request.fence_index = Some(request.property_count);
            request.push(property, u64::MAX);
        }
        request.property_counts[0] =
            u32::try_from(request.property_count).expect("atomic plane property count fits u32");
        request
    }

    fn push(&mut self, property: property::Handle, value: u64) {
        debug_assert!(self.property_count < MAX_ATOMIC_PLANE_PROPERTIES);
        self.properties[self.property_count] = u32::from(property);
        self.values[self.property_count] = value;
        self.property_count += 1;
    }

    fn submit(
        &mut self,
        drm: BorrowedFd<'_>,
        framebuffer: framebuffer::Handle,
        fence: Option<BorrowedFd<'_>>,
        commit_mode: CommitMode,
    ) -> io::Result<()> {
        self.values[0] = u64::from(u32::from(framebuffer));
        debug_assert!(fence.is_none() || self.fence_index.is_some());
        if let Some(index) = self.fence_index {
            self.values[index] = fence
                .map(|fence| i64::from(fence.as_raw_fd()) as u64)
                .unwrap_or(u64::MAX);
        }
        drm_mode::atomic_commit(
            drm,
            commit_flags(commit_mode).bits(),
            &mut self.objects,
            &mut self.property_counts,
            &mut self.properties[..self.property_count],
            &mut self.values[..self.property_count],
        )
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CommitMode {
    Immediate,
    Lookahead,
}

fn commit_flags(mode: CommitMode) -> AtomicCommitFlags {
    let flags = AtomicCommitFlags::PAGE_FLIP_EVENT;
    match mode {
        CommitMode::Immediate => flags | AtomicCommitFlags::NONBLOCK,
        // A synchronous atomic ioctl can sleep uninterruptibly while waiting
        // for the preceding commit. That makes a compositor process
        // impossible to tear down reliably. Volition instead approaches the
        // predicted edge in userspace and retries this bounded nonblocking
        // ioctl until DRM accepts the next generation.
        CommitMode::Lookahead => flags | AtomicCommitFlags::NONBLOCK,
    }
}

/// Identifies one commit in the compositor-owned presentation streams.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CommitId {
    pub stream: usize,
    pub frame: usize,
}

/// Result of attempting to enter the lookahead scheduler without blocking Denial.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[must_use]
pub enum Submission {
    Queued,
    Backpressured,
}

/// An asynchronous failure reported by the Volition commit scheduler.
#[derive(Debug)]
pub struct Failure {
    instance: u64,
    commit: CommitId,
    source: io::Error,
}

impl Failure {
    pub const fn commit(&self) -> CommitId {
        self.commit
    }
}

impl fmt::Display for Failure {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "Volition lookahead failed for stream {} frame {}: {}",
            self.commit.stream, self.commit.frame, self.source
        )
    }
}

impl std::error::Error for Failure {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(&self.source)
    }
}

/// Completion of the asynchronous part of a Volition lookahead submission.
#[derive(Debug)]
pub enum Event {
    Submitted {
        instance: u64,
        commit: CommitId,
        submitted_at: Instant,
    },
    /// A transient kernel refusal outlived Volition's short scheduling window.
    /// The compositor must rebuild its KMS ownership instead of treating this
    /// display backpressure as a process-fatal error.
    Stalled(Failure),
    Failed(Failure),
}

impl Event {
    pub const fn commit(&self) -> CommitId {
        match self {
            Self::Submitted { commit, .. } => *commit,
            Self::Stalled(failure) | Self::Failed(failure) => failure.commit,
        }
    }

    const fn instance(&self) -> u64 {
        match self {
            Self::Submitted { instance, .. } => *instance,
            Self::Stalled(failure) | Self::Failed(failure) => failure.instance,
        }
    }
}

struct CommitJob {
    instance: u64,
    commit: CommitId,
    request: PlaneCommit,
    framebuffer: framebuffer::Handle,
    not_before: Instant,
}

type EventReporter = Arc<dyn Fn(Event) + Send + Sync + 'static>;

struct ScheduledCommit {
    job: CommitJob,
    ready_at: Instant,
    expires_at: Option<Instant>,
    order: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum LookaheadFailureDisposition {
    Retry,
    Recover,
    Fail,
}

impl PartialEq for ScheduledCommit {
    fn eq(&self, other: &Self) -> bool {
        self.ready_at == other.ready_at && self.order == other.order
    }
}

impl Eq for ScheduledCommit {}

impl PartialOrd for ScheduledCommit {
    fn partial_cmp(&self, other: &Self) -> Option<CmpOrdering> {
        Some(self.cmp(other))
    }
}

impl Ord for ScheduledCommit {
    fn cmp(&self, other: &Self) -> CmpOrdering {
        schedule_order(self.ready_at, self.order, other.ready_at, other.order)
    }
}

fn schedule_order(
    left_ready_at: Instant,
    left_order: u64,
    right_ready_at: Instant,
    right_order: u64,
) -> CmpOrdering {
    // BinaryHeap is a max-heap. Reverse the keys so the earliest deadline and
    // then the oldest arrival are serviced first.
    right_ready_at
        .cmp(&left_ready_at)
        .then_with(|| right_order.cmp(&left_order))
}

struct CommitScheduler {
    jobs: Option<SyncSender<CommitJob>>,
    cancelled: Arc<AtomicBool>,
    pending: Arc<AtomicUsize>,
    capacity: usize,
    worker: Option<thread::JoinHandle<()>>,
}

impl CommitScheduler {
    fn start(
        drm: OwnedFd,
        initialize_thread: fn(),
        report_event: EventReporter,
        capacity: usize,
    ) -> io::Result<Self> {
        if capacity == 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Volition lookahead capacity must be non-zero",
            ));
        }
        let (jobs, receiver) = sync_channel::<CommitJob>(capacity);
        let cancelled = Arc::new(AtomicBool::new(false));
        let worker_cancelled = Arc::clone(&cancelled);
        let pending = Arc::new(AtomicUsize::new(0));
        let worker_pending = Arc::clone(&pending);
        let worker = thread::Builder::new()
            .name("volition-kms".into())
            .spawn(move || {
                initialize_thread();
                run_scheduler(
                    drm,
                    receiver,
                    &worker_cancelled,
                    &worker_pending,
                    &report_event,
                );
            })?;
        Ok(Self {
            jobs: Some(jobs),
            cancelled,
            pending,
            capacity,
            worker: Some(worker),
        })
    }

    fn try_submit(&self, job: CommitJob) -> io::Result<Submission> {
        let Some(jobs) = self.jobs.as_ref() else {
            return Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "Volition KMS commit scheduler is shut down",
            ));
        };
        if self
            .pending
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |pending| {
                (pending < self.capacity).then_some(pending + 1)
            })
            .is_err()
        {
            return Ok(Submission::Backpressured);
        }
        match jobs.try_send(job) {
            Ok(()) => Ok(Submission::Queued),
            Err(TrySendError::Full(_)) => {
                self.pending.fetch_sub(1, Ordering::AcqRel);
                Ok(Submission::Backpressured)
            }
            Err(TrySendError::Disconnected(_)) => {
                self.pending.fetch_sub(1, Ordering::AcqRel);
                Err(io::Error::new(
                    io::ErrorKind::BrokenPipe,
                    "Volition KMS commit scheduler exited unexpectedly",
                ))
            }
        }
    }

    fn shutdown(&mut self) {
        if self.worker.is_none() {
            return;
        }
        self.cancelled.store(true, Ordering::Release);
        self.jobs.take();
        if let Some(worker) = self.worker.take() {
            worker.thread().unpark();
            let _ = worker.join();
        }
    }
}

impl Drop for CommitScheduler {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn schedule_job(queue: &mut BinaryHeap<ScheduledCommit>, order: &mut u64, job: CommitJob) {
    queue.push(ScheduledCommit {
        ready_at: job.not_before,
        job,
        expires_at: None,
        order: *order,
    });
    *order = order.wrapping_add(1);
}

fn drain_jobs(
    receiver: &Receiver<CommitJob>,
    queue: &mut BinaryHeap<ScheduledCommit>,
    order: &mut u64,
) -> bool {
    loop {
        match receiver.try_recv() {
            Ok(job) => schedule_job(queue, order, job),
            Err(TryRecvError::Empty) => return true,
            Err(TryRecvError::Disconnected) => return false,
        }
    }
}

fn finish_job(pending: &AtomicUsize, report_event: &EventReporter, event: Event) {
    let previous = pending.fetch_sub(1, Ordering::AcqRel);
    debug_assert!(previous > 0);
    report_event(event);
}

fn run_scheduler(
    drm: OwnedFd,
    receiver: Receiver<CommitJob>,
    cancelled: &AtomicBool,
    pending: &AtomicUsize,
    report_event: &EventReporter,
) {
    let mut queue = BinaryHeap::new();
    let mut order = 0_u64;
    let mut connected = true;

    while !cancelled.load(Ordering::Acquire) {
        if connected {
            connected = drain_jobs(&receiver, &mut queue, &mut order);
        }

        let Some(next_ready_at) = queue.peek().map(|scheduled| scheduled.ready_at) else {
            if !connected {
                return;
            }
            match receiver.recv() {
                Ok(job) => schedule_job(&mut queue, &mut order, job),
                Err(_) => return,
            }
            continue;
        };

        let now = Instant::now();
        if now < next_ready_at && connected {
            match receiver.recv_timeout(next_ready_at.saturating_duration_since(now)) {
                Ok(job) => schedule_job(&mut queue, &mut order, job),
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => connected = false,
            }
            continue;
        }
        if now < next_ready_at {
            thread::park_timeout(next_ready_at.saturating_duration_since(now));
            continue;
        }

        let mut scheduled = queue.pop().expect("peeked Volition commit");
        let attempted_at = Instant::now();
        let expires_at = *scheduled
            .expires_at
            .get_or_insert(attempted_at + LOOKAHEAD_MAX_WAIT);
        match scheduled.job.request.submit(
            drm.as_fd(),
            scheduled.job.framebuffer,
            None,
            CommitMode::Lookahead,
        ) {
            Ok(()) => finish_job(
                pending,
                report_event,
                Event::Submitted {
                    instance: scheduled.job.instance,
                    commit: scheduled.job.commit,
                    submitted_at: Instant::now(),
                },
            ),
            Err(source) => match lookahead_failure_disposition(&source, attempted_at, expires_at) {
                LookaheadFailureDisposition::Retry => {
                    // Reinsert instead of retrying in place. Another output whose
                    // edge is already due can then enter KMS before this busy
                    // stream's next attempt.
                    scheduled.ready_at = attempted_at + LOOKAHEAD_RETRY_INTERVAL;
                    queue.push(scheduled);
                }
                LookaheadFailureDisposition::Recover => finish_job(
                    pending,
                    report_event,
                    Event::Stalled(Failure {
                        instance: scheduled.job.instance,
                        commit: scheduled.job.commit,
                        source,
                    }),
                ),
                LookaheadFailureDisposition::Fail => finish_job(
                    pending,
                    report_event,
                    Event::Failed(Failure {
                        instance: scheduled.job.instance,
                        commit: scheduled.job.commit,
                        source,
                    }),
                ),
            },
        }
    }
}

fn lookahead_failure_disposition(
    error: &io::Error,
    attempted_at: Instant,
    expires_at: Instant,
) -> LookaheadFailureDisposition {
    if !is_retryable_lookahead_error(error) {
        LookaheadFailureDisposition::Fail
    } else if attempted_at < expires_at {
        LookaheadFailureDisposition::Retry
    } else {
        LookaheadFailureDisposition::Recover
    }
}

fn is_retryable_lookahead_error(error: &io::Error) -> bool {
    matches!(
        error.raw_os_error(),
        Some(libc::EBUSY | libc::EAGAIN | libc::EINTR)
    )
}

/// Ordered atomic-KMS presentation engine used by Denial.
pub struct Volition {
    instance: u64,
    drm: OwnedFd,
    scheduler: CommitScheduler,
}

impl Volition {
    /// Creates one Volition instance for one DRM device.
    ///
    /// `initialize_thread` applies the host compositor's scheduling policy.
    /// `report_event` must wake the owner because lookahead completion occurs
    /// after the submission call has returned.
    pub fn new<F>(
        drm: BorrowedFd<'_>,
        lookahead_capacity: usize,
        initialize_thread: fn(),
        report_event: F,
    ) -> io::Result<Self>
    where
        F: Fn(Event) + Send + Sync + 'static,
    {
        let drm = drm.try_clone_to_owned()?;
        let report_event: EventReporter = Arc::new(report_event);
        let scheduler = CommitScheduler::start(
            drm.as_fd().try_clone_to_owned()?,
            initialize_thread,
            report_event,
            lookahead_capacity,
        )?;
        Ok(Self {
            instance: next_instance(),
            drm,
            scheduler,
        })
    }

    /// Submits the first generation immediately with an optional render fence.
    pub fn submit_immediate(
        &self,
        request: &mut PlaneCommit,
        framebuffer: framebuffer::Handle,
        fence: Option<BorrowedFd<'_>>,
    ) -> io::Result<()> {
        request.submit(self.drm.as_fd(), framebuffer, fence, CommitMode::Immediate)
    }

    /// Queues a render-complete generation behind the current hardware commit.
    ///
    /// The caller must observe the frame's render fence before invoking this
    /// method. Volition approaches the predicted presentation edge on a
    /// single deadline scheduler, then retries a nonblocking atomic ioctl
    /// until DRM accepts the generation. Retryable work is reinserted so a
    /// busy output cannot hold another output behind it. This preserves
    /// edge-adjacent submission without allowing a kernel wait to pin the
    /// compositor during shutdown.
    pub fn submit_lookahead(
        &mut self,
        commit: CommitId,
        request: &PlaneCommit,
        framebuffer: framebuffer::Handle,
        not_before: Instant,
    ) -> io::Result<Submission> {
        self.scheduler.try_submit(CommitJob {
            instance: self.instance,
            commit,
            request: request.clone(),
            framebuffer,
            not_before,
        })
    }

    /// Distinguishes this instance from workers retiring after an old display
    /// topology has already been replaced.
    pub const fn owns(&self, event: &Event) -> bool {
        event.instance() == self.instance
    }

    /// Cancels queued lookahead work and joins the KMS scheduler. Every ioctl
    /// issued by a worker is nonblocking, so this operation is bounded.
    pub fn shutdown(&mut self) {
        self.scheduler.shutdown();
    }
}

impl Drop for Volition {
    fn drop(&mut self) {
        self.shutdown();
    }
}

#[cfg(test)]
mod tests {
    use std::cmp::Ordering;
    use std::io;
    use std::time::{Duration, Instant};

    use super::{
        CommitMode, LookaheadFailureDisposition, Submission, commit_flags,
        is_retryable_lookahead_error, lookahead_failure_disposition, schedule_order,
    };
    use smithay::reexports::drm::control::AtomicCommitFlags;

    #[test]
    fn every_volition_ioctl_is_nonblocking() {
        let immediate = commit_flags(CommitMode::Immediate);
        assert!(immediate.contains(AtomicCommitFlags::PAGE_FLIP_EVENT));
        assert!(immediate.contains(AtomicCommitFlags::NONBLOCK));

        let lookahead = commit_flags(CommitMode::Lookahead);
        assert!(lookahead.contains(AtomicCommitFlags::PAGE_FLIP_EVENT));
        assert!(lookahead.contains(AtomicCommitFlags::NONBLOCK));
    }

    #[test]
    fn lookahead_retries_only_transient_submission_errors() {
        for errno in [libc::EBUSY, libc::EAGAIN, libc::EINTR] {
            assert!(is_retryable_lookahead_error(&io::Error::from_raw_os_error(
                errno
            )));
        }
        for errno in [libc::EACCES, libc::EINVAL, libc::ENOMEM] {
            assert!(!is_retryable_lookahead_error(
                &io::Error::from_raw_os_error(errno)
            ));
        }
    }

    #[test]
    fn exhausted_busy_lookahead_requests_compositor_recovery() {
        let deadline = Instant::now();
        let busy = io::Error::from_raw_os_error(libc::EBUSY);
        assert_eq!(
            lookahead_failure_disposition(&busy, deadline - Duration::from_nanos(1), deadline),
            LookaheadFailureDisposition::Retry
        );
        assert_eq!(
            lookahead_failure_disposition(&busy, deadline, deadline),
            LookaheadFailureDisposition::Recover
        );

        let invalid = io::Error::from_raw_os_error(libc::EINVAL);
        assert_eq!(
            lookahead_failure_disposition(&invalid, deadline - Duration::from_nanos(1), deadline),
            LookaheadFailureDisposition::Fail
        );
    }

    #[test]
    fn queue_result_is_explicit_backpressure_not_an_error() {
        assert_ne!(Submission::Queued, Submission::Backpressured);
    }

    #[test]
    fn scheduler_prioritizes_earliest_deadline_then_oldest_arrival() {
        let now = Instant::now();
        assert_eq!(
            schedule_order(now, 4, now + Duration::from_millis(1), 1),
            Ordering::Greater
        );
        assert_eq!(schedule_order(now, 4, now, 5), Ordering::Greater);
        assert_eq!(schedule_order(now, 5, now, 4), Ordering::Less);
    }
}
