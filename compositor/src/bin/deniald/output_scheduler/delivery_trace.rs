//! Opt-in, bounded CPU-side output delivery history. No GL queries or hot-path I/O.
//!
//! A ready-fence token identifies one published generation, independently of
//! reused buffer slots, logical ticks, or possibly repeated KMS sequences.
use std::collections::VecDeque;
use std::time::{Duration, Instant};

use super::super::presentation_clock::monotonic_now;
use super::{OutputFrameRequest, ReadyOutputFrame};

const CAPACITY: usize = 4096;

#[derive(Clone, Copy, Debug, Default)]
pub(super) enum Outcome {
    #[default]
    Pending = 0,
    Presented = 1,
    ElapsedSuccessor = 2,
    InvalidWakeOrFingerprint = 3,
    PowerOff = 4,
    UnpoweredOutput = 5,
}

#[derive(Clone, Copy, Debug)]
pub(super) struct DeliveryFrame {
    id: u64,
    output: u64,
    generation: u64,
    slot: usize,
    transaction: u64,
    request: OutputFrameRequest,
    rendered_at: Option<Instant>,
    published_at: Instant,
    pub(super) fence_observed_at: Option<Instant>,
    pub(super) queued_at: Option<Instant>,
    pub(super) submitted_at: Option<Instant>,
    edge: Option<Instant>,
    terminal_at: Option<Instant>,
    physical_us: Option<u64>,
    kms_sequence: Option<u64>,
    outcome: Outcome,
}

impl DeliveryFrame {
    pub(super) fn fence_signal(&mut self, token: u64, now: Instant) {
        if self.id == token && self.fence_observed_at.is_none() {
            self.fence_observed_at = Some(now);
        }
    }
}

pub(super) struct DeliveryTrace {
    origin: Instant,
    origin_us: u64,
    anchor_span_ns: u128,
    rows: VecDeque<DeliveryFrame>,
    published: u64,
    evicted: u64,
    outcomes: [u64; 6],
}

impl DeliveryTrace {
    pub(super) fn from_environment() -> Option<Self> {
        if !denial_core::environment::flag("DENIAL_OUTPUT_FRAME_TRACE") {
            return None;
        }
        let before = Instant::now();
        let origin_us = u64::try_from(monotonic_now()?.as_micros()).ok()?;
        let after = Instant::now();
        Some(Self::new(
            before + (after - before) / 2,
            origin_us,
            (after - before).as_nanos(),
        ))
    }

    fn new(origin: Instant, origin_us: u64, anchor_span_ns: u128) -> Self {
        Self {
            origin,
            origin_us,
            anchor_span_ns,
            rows: VecDeque::with_capacity(CAPACITY),
            published: 0,
            evicted: 0,
            outcomes: [0; 6],
        }
    }

    pub(super) fn publish(&mut self, id: u64, output: &ReadyOutputFrame) -> DeliveryFrame {
        self.published += 1;
        let now = Instant::now();
        DeliveryFrame {
            id,
            output: output.output_id.0,
            generation: output.configuration_generation,
            slot: output.index,
            transaction: output.raster_transaction,
            request: output.request,
            rendered_at: output.rendered_at,
            published_at: now,
            fence_observed_at: output.fence.is_none().then_some(now),
            queued_at: None,
            submitted_at: None,
            edge: None,
            terminal_at: None,
            physical_us: None,
            kms_sequence: None,
            outcome: Outcome::Pending,
        }
    }

    pub(super) fn finish(
        &mut self,
        frame: Option<DeliveryFrame>,
        outcome: Outcome,
        edge: Option<Instant>,
        physical: Option<Duration>,
        sequence: Option<u64>,
    ) {
        if let Some(mut frame) = frame {
            frame.outcome = outcome;
            frame.edge = edge;
            frame.terminal_at = Some(Instant::now());
            frame.physical_us = physical.and_then(|time| u64::try_from(time.as_micros()).ok());
            frame.kms_sequence = sequence;
            self.outcomes[outcome as usize] += 1;
            if self.rows.len() == CAPACITY {
                self.rows.pop_front();
                self.evicted += 1;
            }
            self.rows.push_back(frame);
        }
    }

    fn relative_us(&self, time: Instant) -> i128 {
        if time >= self.origin {
            time.duration_since(self.origin).as_micros() as i128
        } else {
            -(self.origin.duration_since(time).as_micros() as i128)
        }
    }

    pub(super) fn snapshot<'a>(
        &self,
        pending: impl Iterator<Item = &'a DeliveryFrame>,
    ) -> serde_json::Value {
        use serde_json::{Value, json};
        let time = |value: Option<Instant>| {
            value
                .map(|value| json!(self.relative_us(value)))
                .unwrap_or(Value::Null)
        };
        let row = |frame: &DeliveryFrame| {
            json!([
                frame.id,
                frame.output,
                frame.generation,
                frame.slot,
                frame.request.tick.sequence,
                frame.request.dirty_serial,
                frame.transaction,
                time(frame.rendered_at),
                self.relative_us(frame.request.tick.render_deadline),
                self.relative_us(frame.request.tick.presentation_target),
                u64::try_from(frame.request.tick.nominal_interval.as_nanos()).ok(),
                self.relative_us(frame.published_at),
                time(frame.fence_observed_at),
                time(frame.queued_at),
                time(frame.submitted_at),
                time(frame.edge),
                time(frame.terminal_at),
                frame.physical_us,
                frame.kms_sequence,
                frame.outcome as u8
            ])
        };
        json!({ "enabled": true, "version": 1, "clock_origin_monotonic_us": self.origin_us,
            "clock_anchor_span_ns": self.anchor_span_ns, "capacity": CAPACITY,
            "total_published": self.published, "evicted_terminal_records": self.evicted,
            "total_outcomes": self.outcomes,
            "columns": ["frame_id", "output_id", "configuration_generation", "slot", "logical_sequence", "dirty_serial", "raster_transaction", "rendered_us", "deadline_us", "target_us", "nominal_interval_ns", "published_us", "fence_observed_us", "queued_us", "submitted_us", "edge_us", "terminal_us", "physical_monotonic_us", "kms_sequence", "outcome"],
            "outcomes": ["pending", "presented", "elapsed_successor", "invalid_wake_or_fingerprint", "power_off", "unpowered_output"],
            "rows": self.rows.iter().map(row).collect::<Vec<_>>(), "pending": pending.map(row).collect::<Vec<_>>() })
    }
}

#[cfg(test)]
mod tests {
    use super::super::super::frame_scheduler::FrameTick;
    use super::*;
    use denial_core::topology::OutputId;

    fn frame(id: u64, now: Instant) -> DeliveryFrame {
        let output = OutputId(7);
        DeliveryFrame {
            id,
            output: 7,
            generation: 3,
            slot: 1,
            transaction: 11,
            request: OutputFrameRequest {
                tick: FrameTick {
                    output,
                    sequence: 42,
                    nominal_interval: Duration::from_nanos(8_333_333),
                    interval: Duration::from_nanos(8_333_333),
                    render_deadline: now,
                    presentation_target: now + Duration::from_nanos(8_333_333),
                },
                dirty_serial: 5,
                lock_frame_token: 0,
                fingerprint_epoch: 0,
            },
            rendered_at: Some(now),
            published_at: now,
            fence_observed_at: Some(now),
            queued_at: None,
            submitted_at: None,
            edge: None,
            terminal_at: None,
            physical_us: None,
            kms_sequence: None,
            outcome: Outcome::Pending,
        }
    }

    #[test]
    fn identities_survive_slot_and_logical_sequence_reuse_and_pending_is_not_a_drop() {
        let now = Instant::now();
        let mut trace = DeliveryTrace::new(now, 1_000_000, 100);
        let mut first = frame(1, now);
        first.queued_at = Some(now);
        first.submitted_at = Some(now);
        trace.finish(
            Some(first),
            Outcome::Presented,
            Some(now),
            Some(Duration::from_secs(1)),
            Some(99),
        );
        let mut second = frame(2, now);
        second.fence_observed_at = None;
        second.fence_signal(1, now);
        assert!(second.fence_observed_at.is_none());
        second.fence_signal(2, now);
        assert_eq!(second.fence_observed_at, Some(now));
        let snapshot = trace.snapshot(std::iter::once(&second));
        assert_eq!(snapshot["rows"][0][0], 1);
        assert_eq!(snapshot["pending"][0][0], 2);
        assert_eq!(snapshot["rows"][0][4], snapshot["pending"][0][4]);
        assert_eq!(snapshot["rows"][0][6], 11);
        assert_eq!(snapshot["pending"][0][19], 0);
        assert_eq!(
            snapshot["total_outcomes"],
            serde_json::json!([0, 1, 0, 0, 0, 0])
        );
        trace.finish(Some(second), Outcome::ElapsedSuccessor, None, None, None);
        assert_eq!(
            trace.snapshot(std::iter::empty())["total_outcomes"],
            serde_json::json!([0, 1, 1, 0, 0, 0])
        );
    }

    #[test]
    fn bounded_history_reports_eviction_and_preserves_pre_origin_times() {
        let now = Instant::now();
        let mut trace = DeliveryTrace::new(now + Duration::from_micros(50), 1_000_000, 100);
        assert_eq!(trace.relative_us(now), -50);
        let mut maximum = frame(u64::MAX, now);
        maximum.output = u64::MAX;
        maximum.generation = u64::MAX;
        maximum.transaction = u64::MAX;
        maximum.slot = usize::MAX;
        maximum.request.tick.sequence = u64::MAX;
        maximum.request.dirty_serial = u64::MAX;
        for id in 0..=CAPACITY as u64 {
            let mut frame = maximum;
            frame.id = id;
            trace.finish(
                Some(frame),
                Outcome::Presented,
                Some(now),
                Some(Duration::from_micros(u64::MAX)),
                Some(u64::MAX),
            );
        }
        let snapshot = trace.snapshot(std::iter::empty());
        assert_eq!(snapshot["evicted_terminal_records"], 1);
        assert_eq!(snapshot["rows"].as_array().unwrap().len(), CAPACITY);
        assert_eq!(snapshot["rows"][0][0], 1);
        assert_eq!(snapshot["total_outcomes"][1], CAPACITY + 1);
        // Even maximal identities fit denialctl's 4 MiB response limit.
        assert!(serde_json::to_vec(&snapshot).unwrap().len() < 3 * 1024 * 1024);
    }
    #[test]
    fn queued_and_submitted_timestamps_follow_the_owned_generation() {
        use super::super::{CompletionRetirement, OutputFrame, OutputPipelineFrames};
        use denial_core::volition::CommitId;
        let now = Instant::now();
        let record = frame(9, now);
        let mut frames = OutputPipelineFrames::default();
        frames
            .install_ready(OutputFrame {
                delivery: Some(record),
                index: 1,
                capture_revision: 1,
                screenshot_request_id: None,
                request: record.request,
                submitted_at: now,
                feedback: Vec::new(),
            })
            .unwrap();
        let commit = CommitId {
            stream: 0,
            frame: 1,
        };
        frames.schedule_ready(commit, Some(now)).unwrap();
        assert!(matches!(
            frames.retire_completion(),
            CompletionRetirement::Deferred
        ));
        let submitted = Instant::now();
        frames.acknowledge_submission(commit, submitted).unwrap();
        let CompletionRetirement::Retired(retired) = frames.retire_completion() else {
            panic!("accepted frame must retire")
        };
        let record = retired.delivery.unwrap();
        assert_eq!(record.id, 9);
        assert_eq!(record.submitted_at, Some(submitted));
        assert!(record.queued_at.is_some_and(|queued| queued <= submitted));
        assert!(matches!(
            frames.retire_completion(),
            CompletionRetirement::Stale
        ));
    }
}
