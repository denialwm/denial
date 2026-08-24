//! Volition: ordered atomic-KMS presentation lookahead.
//!
//! Volition is Denial's in-tree display synchronization library. It owns the
//! DRM file descriptor, atomic plane requests, and a bounded deadline scheduler
//! which approaches each compositor-selected physical display edge without
//! blocking in a DRM ioctl. The compositor remains responsible for deciding *what*
//! to present, retaining buffers until page-flip completion, and observing
//! render fences before submitting lookahead work.
//!
//! The separation is intentional: changes to KMS submission timing belong in
//! this module; shell, Flutter, Wayland, DPMS, and screenshot policy do not.

use std::cmp::Ordering as CmpOrdering;
use std::collections::BinaryHeap;
use std::fmt;
use std::io;
use std::os::fd::{AsFd, BorrowedFd, OwnedFd};
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

const MAX_ATOMIC_PLANE_PROPERTIES: usize = 7;
/// Submit far enough ahead of the target for the driver to latch the atomic
/// state for that edge.  The ioctl itself is cheap, but several DRM drivers
/// close their scanout latch materially earlier than the physical vblank.
const LOOKAHEAD_SUBMIT_LEAD: Duration = Duration::from_millis(2);
const LOOKAHEAD_RETRY_INTERVAL: Duration = Duration::from_micros(100);
const LOOKAHEAD_MAX_WAIT: Duration = Duration::from_millis(100);
static NEXT_INSTANCE: AtomicU64 = AtomicU64::new(1);

/// Maximum number of generations Denial may retain for one output stream.
///
/// The compositor owns the scanning generation. Volition may own exactly one
/// successor, either sleeping until its target or submitted to DRM awaiting
/// page-flip completion.
pub const MAX_IN_FLIGHT_COMMITS_PER_STREAM: usize = 1;

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
    pub rotation: Option<(property::Handle, u64)>,
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
        if let Some((property, value)) = properties.rotation {
            request.push(property, value);
        }
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

    fn submit(&mut self, drm: BorrowedFd<'_>, framebuffer: framebuffer::Handle) -> io::Result<()> {
        self.values[0] = u64::from(u32::from(framebuffer));
        if let Some(index) = self.fence_index {
            self.values[index] = u64::MAX;
        }
        drm_mode::atomic_commit(
            drm,
            commit_flags().bits(),
            &mut self.objects,
            &mut self.property_counts,
            &mut self.properties[..self.property_count],
            &mut self.values[..self.property_count],
        )
    }
}

fn commit_flags() -> AtomicCommitFlags {
    // A synchronous atomic ioctl can sleep uninterruptibly while waiting for
    // a preceding commit. Volition approaches the caller-selected edge in
    // userspace and retries a bounded nonblocking ioctl instead.
    AtomicCommitFlags::PAGE_FLIP_EVENT | AtomicCommitFlags::NONBLOCK
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
        match scheduled
            .job
            .request
            .submit(drm.as_fd(), scheduled.job.framebuffer)
        {
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
    if is_retryable_lookahead_error(error) && attempted_at < expires_at {
        LookaheadFailureDisposition::Retry
    } else if is_retryable_lookahead_error(error) || is_recoverable_kms_error(error) {
        LookaheadFailureDisposition::Recover
    } else {
        LookaheadFailureDisposition::Fail
    }
}

fn is_retryable_lookahead_error(error: &io::Error) -> bool {
    matches!(
        error.raw_os_error(),
        Some(libc::EBUSY | libc::EAGAIN | libc::EINTR)
    )
}

/// Atomic KMS can reject a previously valid plane request when a connector is
/// link-training, a DRM object was replaced, the device reset, or libseat is
/// transferring mastership. Rebuilding the compositor-owned KMS state is the
/// correct boundary for these failures; aborting the graphical session is not.
fn is_recoverable_kms_error(error: &io::Error) -> bool {
    matches!(
        error.raw_os_error(),
        Some(
            libc::EACCES
                | libc::EPERM
                | libc::EINVAL
                | libc::ENOENT
                | libc::ENODEV
                | libc::EIO
                | libc::ETIMEDOUT
        )
    )
}

fn lookahead_not_before(presentation_target: Instant, now: Instant) -> Instant {
    presentation_target
        .checked_sub(LOOKAHEAD_SUBMIT_LEAD)
        .unwrap_or(now)
        .max(now)
}

/// Ordered atomic-KMS presentation engine used by Denial.
pub struct Volition {
    instance: u64,
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
        let report_event: EventReporter = Arc::new(report_event);
        let scheduler = CommitScheduler::start(
            drm.try_clone_to_owned()?,
            initialize_thread,
            report_event,
            lookahead_capacity,
        )?;
        Ok(Self {
            instance: next_instance(),
            scheduler,
        })
    }

    /// Queues a render-complete generation for the compositor-selected edge.
    ///
    /// The caller must observe the frame's render fence before invoking this
    /// method. Volition approaches the caller's presentation target on a
    /// single deadline scheduler, then retries a nonblocking atomic ioctl
    /// until DRM accepts the generation. Retryable work is reinserted so a
    /// busy output cannot hold another output behind it. This preserves
    /// edge-adjacent submission without allowing a kernel wait to pin the
    /// compositor during shutdown.
    pub fn submit_for_target(
        &mut self,
        commit: CommitId,
        request: &PlaneCommit,
        framebuffer: framebuffer::Handle,
        presentation_target: Instant,
    ) -> io::Result<Submission> {
        let not_before = lookahead_not_before(presentation_target, Instant::now());
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
#[path = "tests.rs"]
mod tests;
