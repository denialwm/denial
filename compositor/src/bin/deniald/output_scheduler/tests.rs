use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

use super::{
    CommitId, FrameTick, InFlightFrame, OutputFrame, OutputFrameRequest, OutputPipelineFrames,
    OutputSchedulerAudit, PRESENTATION_STALL_TIMEOUT, ReadyFenceSlot, presentation_stall_age,
    presentation_watchdog_remaining,
};
use denial_core::topology::OutputId;

fn output_frame(index: usize, screenshot_request_id: Option<u64>) -> OutputFrame {
    let render_deadline = Instant::now();
    OutputFrame {
        index,
        screenshot_request_id,
        request: OutputFrameRequest {
            tick: FrameTick {
                output: OutputId(1),
                sequence: u64::try_from(index).unwrap() + 1,
                interval: Duration::from_millis(10),
                render_deadline,
                presentation_target: render_deadline + Duration::from_millis(10),
            },
            dirty_serial: u64::try_from(index).unwrap() + 1,
        },
        submitted_at: render_deadline,
    }
}

#[test]
fn output_pipeline_never_replaces_its_unconsumed_ready_frame() {
    let mut frames = OutputPipelineFrames::default();
    frames.install_ready(output_frame(1, None)).unwrap();

    assert!(frames.install_ready(output_frame(2, None)).is_err());
    assert_eq!(frames.ready.as_ref().map(|frame| frame.index), Some(1));

    let mut screenshot = OutputPipelineFrames::default();
    screenshot.install_ready(output_frame(1, Some(41))).unwrap();
    assert!(screenshot.install_ready(output_frame(2, None)).is_err());
    assert_eq!(
        screenshot
            .ready
            .as_ref()
            .and_then(|frame| frame.screenshot_request_id),
        Some(41)
    );
}

#[test]
fn output_pipeline_holds_one_in_flight_and_one_ready_successor() {
    let mut frames = OutputPipelineFrames::default();
    let commit = CommitId {
        stream: 0,
        frame: 1,
    };

    frames.install_ready(output_frame(1, None)).unwrap();
    frames.schedule_ready(commit).unwrap();
    assert!(frames.render_available());
    assert_eq!(frames.scheduled_commit(), Some(commit));

    frames.install_ready(output_frame(2, None)).unwrap();
    assert!(!frames.render_available());
    assert!(frames.install_ready(output_frame(0, None)).is_err());

    let submitted_at = Instant::now();
    assert_eq!(
        frames.acknowledge_submission(commit, submitted_at).unwrap(),
        1
    );
    assert!(matches!(
        frames.in_flight.as_ref(),
        Some(InFlightFrame::Submitted(frame)) if frame.index == 1
    ));
    assert_eq!(frames.retire_submitted().map(|frame| frame.index), Some(1));
    assert_eq!(frames.ready.as_ref().map(|frame| frame.index), Some(2));
    assert!(!frames.render_available());
}

#[test]
fn ready_fence_slot_closes_only_after_its_last_pipeline_user() {
    let mut slot = ReadyFenceSlot::default();
    assert!(slot.is_available());
    slot.claim(None, 2, 11).unwrap();
    assert!(!slot.is_available());
    assert!(slot.claim(None, 1, 12).is_err());

    slot.release_user().unwrap();
    assert_eq!(slot.users, 1);
    slot.release_user().unwrap();
    assert!(slot.is_available());
    assert!(slot.release_user().is_err());
    assert!(slot.claim(None, 0, 13).is_err());
    assert!(slot.claim(None, 1, 0).is_err());
}

#[test]
fn ready_fence_slot_ignores_stale_signals() {
    let mut slot = ReadyFenceSlot::default();
    let (fence, _peer) = UnixStream::pair().unwrap();
    slot.claim(Some(fence.into()), 1, 21).unwrap();
    assert!(!slot.mark_signaled(20));
    assert!(slot.mark_signaled(21));
    assert!(slot.signaled);

    slot.release_user().unwrap();
    assert!(!slot.mark_signaled(21));
    assert!(slot.is_available());
}

#[test]
fn discarded_gpu_frame_is_not_reusable_until_its_fence_user_retires() {
    let mut slot = ReadyFenceSlot::default();
    let (fence, _peer) = UnixStream::pair().unwrap();
    slot.claim(Some(fence.into()), 2, 31).unwrap();
    slot.discard_user_when_signaled().unwrap();
    slot.discard_user_when_signaled().unwrap();
    assert!(slot.discard_user_when_signaled().is_err());

    assert!(!slot.is_available());
    assert!(slot.mark_signaled(31));
    let discard_users = slot.discard_users_on_signal;
    slot.discard_users_on_signal = 0;
    assert_eq!(discard_users, 2);
    for _ in 0..discard_users {
        slot.release_user().unwrap();
    }
    assert!(slot.is_available());
    assert!(slot.release_user().is_err());
}

#[test]
fn scheduler_audit_counts_wrapped_drm_sequence_gaps() {
    let mut audit = OutputSchedulerAudit::new(4, 1);
    let now = Instant::now();
    audit.record_presentation(0, now, now, Some(u64::from(u32::MAX - 1)));
    audit.record_presentation(0, now, now, Some(1));

    assert_eq!(audit.presentations, 2);
    assert_eq!(audit.sequence_samples, 1);
    assert_eq!(audit.sequence_delta_total, 3);
    assert_eq!(audit.sequence_delta_max, 3);
    assert_eq!(audit.missed_vblanks, 2);
}

#[test]
fn scheduler_audit_tracks_kernel_owned_fence_after_submission() {
    let mut audit = OutputSchedulerAudit::new(4, 1);
    audit.record_ready(0, 41, true, None);
    audit.record_real_submission(0, 0, Instant::now());

    audit.record_fence_signal(0, 40);
    assert_eq!(audit.fence_signals, 0);
    audit.record_fence_signal(0, 41);
    assert_eq!(audit.fence_signals, 1);
    assert_eq!(audit.ready_to_fence.samples, 1);

    audit.record_fence_signal(0, 41);
    assert_eq!(audit.fence_signals, 1);
}

#[test]
fn scheduler_audit_tracks_the_single_submitted_generation() {
    let mut audit = OutputSchedulerAudit::new(4, 1);
    audit.record_ready(0, 51, false, None);
    audit.record_real_submission(0, 0, Instant::now());
    assert_eq!(audit.volition_scheduled_submissions, 1);
    assert!(audit.submitted_at[0].is_some());

    let now = Instant::now();
    audit.record_presentation(0, now, now, Some(1));
    assert!(audit.submitted_at[0].is_none());
    assert_eq!(audit.submit_to_presentation.samples, 1);
}

#[test]
fn presentation_watchdog_trips_at_its_deadline() {
    let submitted_at = Instant::now();
    let before = submitted_at + PRESENTATION_STALL_TIMEOUT - Duration::from_nanos(1);
    let deadline = submitted_at + PRESENTATION_STALL_TIMEOUT;

    assert_eq!(presentation_stall_age(submitted_at, before), None);
    assert_eq!(
        presentation_watchdog_remaining(submitted_at, before),
        Duration::from_nanos(1)
    );
    assert_eq!(
        presentation_stall_age(submitted_at, deadline),
        Some(PRESENTATION_STALL_TIMEOUT)
    );
    assert_eq!(
        presentation_watchdog_remaining(submitted_at, deadline),
        Duration::ZERO
    );
}
