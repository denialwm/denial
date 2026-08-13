//! Volition: ordered atomic-KMS presentation lookahead.
//!
//! Volition is Denial's in-tree display synchronization library. It owns the
//! DRM file descriptor, atomic plane requests, and the two alternating commit
//! lanes which approach the next physical display edge without blocking in a
//! DRM ioctl. The compositor remains responsible for deciding *what*
//! to present, retaining buffers until page-flip completion, and observing
//! render fences before submitting lookahead work.
//!
//! The separation is intentional: changes to KMS submission timing belong in
//! this module; shell, Flutter, Wayland, DPMS, and screenshot policy do not.

use std::fmt;
use std::io;
use std::os::fd::{AsFd, AsRawFd, BorrowedFd, OwnedFd};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{SyncSender, TrySendError, sync_channel};
use std::thread;
use std::time::{Duration, Instant};

use drm_ffi::mode as drm_mode;
use smithay::reexports::drm::control::{
    AtomicCommitFlags, RawResourceHandle, framebuffer, plane, property,
};

use crate::topology::PixelRect;

const MAX_ATOMIC_PLANE_PROPERTIES: usize = 6;
const COMMIT_LANES: usize = 2;
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

/// Result of attempting to enter a lookahead lane without blocking Denial.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[must_use]
pub enum Submission {
    Queued,
    Backpressured,
}

/// An asynchronous failure reported by a Volition commit lane.
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
    Submitted { instance: u64, commit: CommitId },
    Failed(Failure),
}

impl Event {
    pub const fn commit(&self) -> CommitId {
        match self {
            Self::Submitted { commit, .. } => *commit,
            Self::Failed(failure) => failure.commit,
        }
    }

    const fn instance(&self) -> u64 {
        match self {
            Self::Submitted { instance, .. } => *instance,
            Self::Failed(failure) => failure.instance,
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

struct CommitLane {
    jobs: Option<SyncSender<CommitJob>>,
    cancelled: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<()>>,
}

impl CommitLane {
    fn start(
        drm: OwnedFd,
        initialize_thread: fn(),
        report_event: EventReporter,
        lane: usize,
    ) -> io::Result<Self> {
        let (jobs, receiver) = sync_channel::<CommitJob>(1);
        let cancelled = Arc::new(AtomicBool::new(false));
        let worker_cancelled = Arc::clone(&cancelled);
        let worker = thread::Builder::new()
            .name(format!("volition-kms-{lane}"))
            .spawn(move || {
                initialize_thread();
                while let Ok(mut job) = receiver.recv() {
                    if !wait_until(&worker_cancelled, job.not_before) {
                        break;
                    }
                    let expires_at = Instant::now() + LOOKAHEAD_MAX_WAIT;
                    loop {
                        if worker_cancelled.load(Ordering::Acquire) {
                            return;
                        }
                        match job.request.submit(
                            drm.as_fd(),
                            job.framebuffer,
                            None,
                            CommitMode::Lookahead,
                        ) {
                            Ok(()) => {
                                report_event(Event::Submitted {
                                    instance: job.instance,
                                    commit: job.commit,
                                });
                                break;
                            }
                            Err(source)
                                if is_retryable_lookahead_error(&source)
                                    && Instant::now() < expires_at =>
                            {
                                thread::park_timeout(LOOKAHEAD_RETRY_INTERVAL);
                            }
                            Err(source) => {
                                report_event(Event::Failed(Failure {
                                    instance: job.instance,
                                    commit: job.commit,
                                    source,
                                }));
                                break;
                            }
                        }
                    }
                }
            })?;
        Ok(Self {
            jobs: Some(jobs),
            cancelled,
            worker: Some(worker),
        })
    }

    fn try_submit(&self, job: CommitJob) -> io::Result<Submission> {
        let Some(jobs) = self.jobs.as_ref() else {
            return Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "Volition KMS commit lane is shut down",
            ));
        };
        match jobs.try_send(job) {
            Ok(()) => Ok(Submission::Queued),
            Err(TrySendError::Full(_)) => Ok(Submission::Backpressured),
            Err(TrySendError::Disconnected(_)) => Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "Volition KMS commit lane exited unexpectedly",
            )),
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

impl Drop for CommitLane {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn wait_until(cancelled: &AtomicBool, deadline: Instant) -> bool {
    loop {
        if cancelled.load(Ordering::Acquire) {
            return false;
        }
        let now = Instant::now();
        if now >= deadline {
            return true;
        }
        thread::park_timeout(deadline.saturating_duration_since(now));
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
    lanes: Vec<CommitLane>,
    next_lane: usize,
}

impl Volition {
    /// Creates one Volition instance for one DRM device.
    ///
    /// `initialize_thread` applies the host compositor's scheduling policy.
    /// `report_event` must wake the owner because lookahead completion occurs
    /// after the submission call has returned.
    pub fn new<F>(drm: BorrowedFd<'_>, initialize_thread: fn(), report_event: F) -> io::Result<Self>
    where
        F: Fn(Event) + Send + Sync + 'static,
    {
        let drm = drm.try_clone_to_owned()?;
        let report_event: EventReporter = Arc::new(report_event);
        let lanes = (0..COMMIT_LANES)
            .map(|lane| {
                CommitLane::start(
                    drm.as_fd().try_clone_to_owned()?,
                    initialize_thread,
                    Arc::clone(&report_event),
                    lane,
                )
            })
            .collect::<io::Result<Vec<_>>>()?;
        Ok(Self {
            instance: next_instance(),
            drm,
            lanes,
            next_lane: 0,
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
    /// method. Volition approaches the predicted presentation edge on an
    /// alternating worker, then retries a nonblocking atomic ioctl until DRM
    /// accepts the generation. This preserves edge-adjacent submission without
    /// allowing a kernel wait to pin the compositor during shutdown.
    pub fn submit_lookahead(
        &mut self,
        commit: CommitId,
        request: &PlaneCommit,
        framebuffer: framebuffer::Handle,
        not_before: Instant,
    ) -> io::Result<Submission> {
        let lane = self.next_lane;
        let submission = self.lanes[lane].try_submit(CommitJob {
            instance: self.instance,
            commit,
            request: request.clone(),
            framebuffer,
            not_before,
        })?;
        if submission == Submission::Queued {
            self.next_lane = (lane + 1) % self.lanes.len();
        }
        Ok(submission)
    }

    /// Distinguishes this instance from workers retiring after an old display
    /// topology has already been replaced.
    pub const fn owns(&self, event: &Event) -> bool {
        event.instance() == self.instance
    }

    /// Cancels queued lookahead work and joins every KMS worker. Every ioctl
    /// issued by a worker is nonblocking, so this operation is bounded.
    pub fn shutdown(&mut self) {
        for lane in &mut self.lanes {
            lane.shutdown();
        }
    }
}

impl Drop for Volition {
    fn drop(&mut self) {
        self.shutdown();
    }
}

/// Whether a real IN_FENCE_FD failure means userspace should wait instead.
pub fn is_fence_capability_error(error: &io::Error) -> bool {
    matches!(
        error.raw_os_error(),
        Some(libc::EPERM | libc::EINVAL | libc::EOPNOTSUPP | libc::ENOSYS)
    )
}

#[cfg(test)]
mod tests {
    use std::io;

    use super::{
        CommitMode, Submission, commit_flags, is_fence_capability_error,
        is_retryable_lookahead_error,
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
    fn fenced_commit_capability_errors_are_narrowly_classified() {
        for errno in [libc::EPERM, libc::EINVAL, libc::EOPNOTSUPP, libc::ENOSYS] {
            assert!(is_fence_capability_error(&io::Error::from_raw_os_error(
                errno
            )));
        }
        for errno in [libc::EACCES, libc::EBUSY, libc::ENOMEM] {
            assert!(!is_fence_capability_error(&io::Error::from_raw_os_error(
                errno
            )));
        }
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
    fn queue_result_is_explicit_backpressure_not_an_error() {
        assert_ne!(Submission::Queued, Submission::Backpressured);
    }
}
