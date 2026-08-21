use std::cmp::Ordering;
use std::io;
use std::time::{Duration, Instant};

use super::{
    LOOKAHEAD_SUBMIT_LEAD, LookaheadFailureDisposition, MAX_IN_FLIGHT_COMMITS_PER_STREAM,
    Submission, commit_flags, is_retryable_lookahead_error, lookahead_failure_disposition,
    lookahead_not_before, schedule_order,
};
use smithay::reexports::drm::control::AtomicCommitFlags;

#[test]
fn every_volition_ioctl_is_nonblocking() {
    let flags = commit_flags();
    assert!(flags.contains(AtomicCommitFlags::PAGE_FLIP_EVENT));
    assert!(flags.contains(AtomicCommitFlags::NONBLOCK));
}

#[test]
fn lookahead_derives_its_deadline_from_the_explicit_presentation_target() {
    let now = Instant::now();
    let target = now + Duration::from_millis(7);

    assert_eq!(
        lookahead_not_before(target, now),
        target - LOOKAHEAD_SUBMIT_LEAD
    );
    assert_eq!(lookahead_not_before(now, now), now);
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
fn each_output_stream_retains_only_one_volition_generation() {
    assert_eq!(MAX_IN_FLIGHT_COMMITS_PER_STREAM, 1);
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
