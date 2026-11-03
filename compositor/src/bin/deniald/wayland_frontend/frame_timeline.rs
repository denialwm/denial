//! Generic compositor-issued exact frame grants.
//!
//! This protocol does not create a new kind of window. It only constrains
//! when a buffer commit on an ordinary `wl_surface` is eligible to enter the
//! existing scene and KMS pipeline.

use std::collections::{HashMap, HashSet};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicU8, AtomicU64, Ordering},
};
use std::time::{Duration, Instant};

use denial_core::topology::OutputId;
use smithay::output::Output;
use smithay::reexports::wayland_server::backend::{ClientId, GlobalId, ObjectId};
use smithay::reexports::wayland_server::protocol::{wl_output::WlOutput, wl_surface::WlSurface};
use smithay::reexports::wayland_server::{
    Client, DataInit, Dispatch, DisplayHandle, GlobalDispatch, New, Resource,
};
use smithay::wayland::compositor::with_states;
use smithay::wayland::compositor::{Blocker, BlockerState};
use tracing::{debug, warn};

use super::super::frame_scheduler::FrameTick;
use super::{RuntimeState, WaylandFrontend};

pub mod protocol {
    pub mod server {
        #![allow(
            dead_code,
            non_camel_case_types,
            non_upper_case_globals,
            non_snake_case,
            unused_imports,
            unused_unsafe,
            unused_variables,
            clippy::all,
            missing_docs
        )]

        use wayland_server;
        use wayland_server::protocol::*;

        pub mod __interfaces {
            use wayland_server::backend as wayland_backend;
            use wayland_server::protocol::__interfaces::*;
            wayland_scanner::generate_interfaces!("protocol/denial-frame-timeline-v1.xml");
        }
        use self::__interfaces::*;

        wayland_scanner::generate_server_code!("protocol/denial-frame-timeline-v1.xml");
    }
}

use protocol::server::{
    denial_frame_timeline_manager_v1::{self, DenialFrameTimelineManagerV1},
    denial_output_frame_timeline_v1::{self, DenialOutputFrameTimelineV1},
    denial_surface_frame_timeline_v1::{self, DenialSurfaceFrameTimelineV1},
};

const MAX_LIVE_GRANTS: usize = 64;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
struct FrameToken {
    epoch: u64,
    sequence: u64,
}

#[derive(Clone, Debug)]
struct GrantRecord {
    output: OutputId,
    latch_output_sequence: u64,
    latch_deadline: Instant,
    ready_commits: u32,
    missed_commits: u32,
    configure_discards: u32,
}

#[derive(Clone, Copy, Debug)]
enum FrameTerminal {
    Presented,
    IntentionallySkipped,
    MissedDeadline,
    DiscardedByConfigure,
    AbortedByEpoch,
    AbortedByDisarm,
}

impl FrameTerminal {
    const fn name(self) -> &'static str {
        match self {
            Self::Presented => "presented",
            Self::IntentionallySkipped => "intentionally_skipped",
            Self::MissedDeadline => "missed_deadline",
            Self::DiscardedByConfigure => "discarded_by_configure",
            Self::AbortedByEpoch => "aborted_by_epoch",
            Self::AbortedByDisarm => "aborted_by_disarm",
        }
    }
}

#[derive(Debug)]
struct OutputSubscription {
    resource: DenialOutputFrameTimelineV1,
    output: Option<OutputId>,
    active: bool,
    announced_epoch: Option<u64>,
    grants: HashSet<FrameToken>,
}

#[derive(Clone, Copy, Debug)]
struct OutputCadence {
    sequence: u64,
    nominal_interval: Duration,
}

/// One output's current epoch. Epoch values come from one counter, so a value
/// names exactly one output generation; sequences are global as well.
#[derive(Debug)]
struct OutputEpoch {
    epoch: u64,
    guard: Arc<AtomicU64>,
}

#[derive(Debug)]
pub(super) struct FrameTimelineManager {
    _global: GlobalId,
    last_epoch: u64,
    next_sequence: u64,
    subscriptions: HashMap<ObjectId, OutputSubscription>,
    grants: HashMap<FrameToken, GrantRecord>,
    cadence: HashMap<OutputId, OutputCadence>,
    epochs: HashMap<OutputId, OutputEpoch>,
}

impl FrameTimelineManager {
    pub(super) fn new(display: &DisplayHandle) -> Self {
        Self {
            _global: display.create_global::<RuntimeState, DenialFrameTimelineManagerV1, _>(1, ()),
            last_epoch: 0,
            next_sequence: 0,
            subscriptions: HashMap::new(),
            grants: HashMap::new(),
            cadence: HashMap::new(),
            epochs: HashMap::new(),
        }
    }

    pub(super) fn has_active_subscription(&self) -> bool {
        self.subscriptions
            .values()
            .any(|subscription| subscription.active)
    }

    fn allocate_epoch(&mut self) -> u64 {
        self.last_epoch = self.last_epoch.wrapping_add(1).max(1);
        self.last_epoch
    }

    fn epoch(&mut self, output: OutputId) -> u64 {
        if let Some(current) = self.epochs.get(&output) {
            return current.epoch;
        }
        let epoch = self.allocate_epoch();
        self.epochs.insert(
            output,
            OutputEpoch {
                epoch,
                guard: Arc::new(AtomicU64::new(epoch)),
            },
        );
        epoch
    }

    fn current_epoch(&self, output: OutputId) -> Option<u64> {
        self.epochs.get(&output).map(|current| current.epoch)
    }

    /// Abort one output's grants and announce a new epoch to its armed
    /// subscriptions. Other outputs keep their epochs and grants.
    fn begin_new_epoch(&mut self, output: OutputId) {
        let aborted = self
            .grants
            .iter()
            .filter_map(|(token, record)| (record.output == output).then_some(*token))
            .collect::<Vec<_>>();
        for token in aborted {
            self.finish(token, FrameTerminal::AbortedByEpoch);
        }
        let epoch = self.allocate_epoch();
        match self.epochs.get_mut(&output) {
            Some(current) => {
                current.epoch = epoch;
                current.guard.store(epoch, Ordering::Release);
            }
            None => {
                self.epochs.insert(
                    output,
                    OutputEpoch {
                        epoch,
                        guard: Arc::new(AtomicU64::new(epoch)),
                    },
                );
            }
        }
        self.cadence.remove(&output);
        let (epoch_hi, epoch_lo) = split_u64(epoch);
        for subscription in self
            .subscriptions
            .values_mut()
            .filter(|subscription| subscription.output == Some(output))
        {
            subscription.grants.clear();
            if subscription.active {
                subscription.resource.epoch(epoch_hi, epoch_lo);
                subscription.announced_epoch = Some(epoch);
            } else {
                subscription.announced_epoch = None;
            }
        }
        debug!(
            ?output,
            frame_epoch = epoch,
            frame_state = "epoch",
            "frame timeline epoch advanced"
        );
    }

    /// A timeline reset: every output starts a new epoch.
    fn reset(&mut self) {
        for output in self.epochs.keys().copied().collect::<Vec<_>>() {
            self.begin_new_epoch(output);
        }
    }

    fn register(&mut self, output: Option<OutputId>, resource: DenialOutputFrameTimelineV1) {
        self.subscriptions.insert(
            resource.id(),
            OutputSubscription {
                resource,
                output,
                active: false,
                announced_epoch: None,
                grants: HashSet::new(),
            },
        );
    }

    fn set_active(&mut self, id: &ObjectId, active: bool) {
        let Some(output) = self
            .subscriptions
            .get(id)
            .map(|subscription| subscription.output)
        else {
            return;
        };
        let epoch = output.filter(|_| active).map(|output| self.epoch(output));
        let Some(subscription) = self.subscriptions.get_mut(id) else {
            return;
        };
        subscription.active = active;
        subscription.announced_epoch = epoch;
        if let Some(epoch) = epoch {
            let (epoch_hi, epoch_lo) = split_u64(epoch);
            subscription.resource.epoch(epoch_hi, epoch_lo);
        }
        let released = std::mem::take(&mut subscription.grants);
        self.abort_unheld(released);
    }

    fn unregister(&mut self, id: &ObjectId) {
        if let Some(subscription) = self.subscriptions.remove(id) {
            self.abort_unheld(subscription.grants);
        }
    }

    /// Disarming or destroying one subscription aborts the grants it held
    /// that are not latched yet and that no other armed subscription holds.
    /// No epoch ends, so the output's other subscriptions keep their grants.
    fn abort_unheld(&mut self, released: HashSet<FrameToken>) {
        for token in released {
            let held = self
                .subscriptions
                .values()
                .any(|subscription| subscription.active && subscription.grants.contains(&token));
            let latched = self.grants.get(&token).is_some_and(|record| {
                self.cadence
                    .get(&record.output)
                    .is_some_and(|cadence| cadence.sequence >= record.latch_output_sequence)
            });
            if !held && !latched {
                self.finish(token, FrameTerminal::AbortedByDisarm);
            }
        }
    }

    fn allocate_token(&mut self, output: OutputId) -> FrameToken {
        let Some(sequence) = self.next_sequence.checked_add(1) else {
            self.reset();
            self.next_sequence = 1;
            return FrameToken {
                epoch: self.epoch(output),
                sequence: 1,
            };
        };
        self.next_sequence = sequence;
        FrameToken {
            epoch: self.epoch(output),
            sequence,
        }
    }

    fn finish(&mut self, token: FrameToken, terminal: FrameTerminal) {
        let Some(record) = self.grants.remove(&token) else {
            return;
        };
        for subscription in self.subscriptions.values_mut() {
            subscription.grants.remove(&token);
        }
        debug!(
            frame_epoch = token.epoch,
            frame_sequence = token.sequence,
            ?record.output,
            output_sequence = record.latch_output_sequence,
            ready_commits = record.ready_commits,
            missed_commits = record.missed_commits,
            configure_discards = record.configure_discards,
            frame_state = terminal.name(),
            "frame grant reached exactly one terminal state"
        );
    }

    fn ready(&mut self, token: FrameToken) {
        if let Some(record) = self.grants.get_mut(&token) {
            record.ready_commits = record.ready_commits.saturating_add(1);
        }
    }

    fn missed(&mut self, token: FrameToken) {
        if let Some(record) = self.grants.get_mut(&token) {
            record.missed_commits = record.missed_commits.saturating_add(1);
        }
    }

    fn discarded_by_configure(&mut self, token: FrameToken) {
        if let Some(record) = self.grants.get_mut(&token) {
            record.configure_discards = record.configure_discards.saturating_add(1);
        }
    }

    pub(super) fn presented(&mut self, output: OutputId, output_sequence: u64) {
        let token = self.grants.iter().find_map(|(token, record)| {
            (record.output == output
                && record.latch_output_sequence == output_sequence
                && record.ready_commits != 0)
                .then_some(*token)
        });
        if let Some(token) = token {
            self.finish(token, FrameTerminal::Presented);
        }
    }

    fn expire_at_latch(&mut self, output: OutputId, output_sequence: u64) {
        let due = self
            .grants
            .iter()
            .filter_map(|(token, record)| {
                (record.output == output && record.latch_output_sequence <= output_sequence)
                    .then_some(*token)
            })
            .collect::<Vec<_>>();
        for token in due {
            let Some(record) = self.grants.get(&token) else {
                continue;
            };
            let terminal = if record.latch_output_sequence < output_sequence {
                Some(FrameTerminal::MissedDeadline)
            } else if record.ready_commits != 0 {
                None
            } else if record.missed_commits != 0 {
                Some(FrameTerminal::MissedDeadline)
            } else if record.configure_discards != 0 {
                Some(FrameTerminal::DiscardedByConfigure)
            } else {
                Some(FrameTerminal::IntentionallySkipped)
            };
            if let Some(terminal) = terminal {
                self.finish(token, terminal);
            } else {
                debug!(
                    frame_epoch = token.epoch,
                    frame_sequence = token.sequence,
                    ?output,
                    output_sequence,
                    frame_state = "latched",
                    "frame grant entered the ordinary output composition"
                );
            }
        }
    }

    fn publish(&mut self, tick: FrameTick, latch: Duration, target: Duration) -> usize {
        let cadence_changed = self
            .cadence
            .get(&tick.output)
            .is_some_and(|cadence| cadence_changed(*cadence, tick));
        if cadence_changed {
            self.begin_new_epoch(tick.output);
        }
        self.cadence.insert(
            tick.output,
            OutputCadence {
                sequence: tick.sequence,
                nominal_interval: tick.nominal_interval,
            },
        );
        self.expire_at_latch(tick.output, tick.sequence);

        let Some(latch_output_sequence) = tick.sequence.checked_add(1) else {
            self.begin_new_epoch(tick.output);
            return 0;
        };
        let token = self.allocate_token(tick.output);
        self.grants.insert(
            token,
            GrantRecord {
                output: tick.output,
                latch_output_sequence,
                latch_deadline: tick.presentation_target,
                ready_commits: 0,
                missed_commits: 0,
                configure_discards: 0,
            },
        );

        let period_nanos = u64::try_from(tick.nominal_interval.as_nanos()).unwrap_or(u64::MAX);
        let (epoch_hi, epoch_lo) = split_u64(token.epoch);
        let (sequence_hi, sequence_lo) = split_u64(token.sequence);
        let (latch_sec_hi, latch_sec_lo) = split_u64(latch.as_secs());
        let (target_sec_hi, target_sec_lo) = split_u64(target.as_secs());
        let (period_ns_hi, period_ns_lo) = split_u64(period_nanos);
        let mut sent = 0usize;
        for subscription in self
            .subscriptions
            .values_mut()
            .filter(|subscription| subscription.active && subscription.output == Some(tick.output))
        {
            if subscription.announced_epoch != Some(token.epoch) {
                subscription.resource.epoch(epoch_hi, epoch_lo);
                subscription.announced_epoch = Some(token.epoch);
                sent = sent.saturating_add(1);
            }
            subscription.resource.grant(
                epoch_hi,
                epoch_lo,
                sequence_hi,
                sequence_lo,
                latch_sec_hi,
                latch_sec_lo,
                latch.subsec_nanos(),
                target_sec_hi,
                target_sec_lo,
                target.subsec_nanos(),
                period_ns_hi,
                period_ns_lo,
            );
            subscription.grants.insert(token);
            sent = sent.saturating_add(1);
        }

        if self.grants.len() > MAX_LIVE_GRANTS {
            let minimum = self
                .grants
                .keys()
                .map(|token| token.sequence)
                .min()
                .unwrap_or(0);
            if let Some(token) = self
                .grants
                .keys()
                .copied()
                .find(|token| token.sequence == minimum)
            {
                self.finish(token, FrameTerminal::AbortedByEpoch);
            }
        }

        debug!(
            frame_epoch = token.epoch,
            frame_sequence = token.sequence,
            ?tick.output,
            latch_ns = duration_nanos(latch),
            target_ns = duration_nanos(target),
            period_ns = period_nanos,
            frame_state = "granted",
            subscribers = sent,
            "published frame grant"
        );
        sent
    }
}

#[derive(Clone, Copy, Debug)]
pub(super) struct OutputTimelineUserData {
    _output: Option<OutputId>,
}

#[derive(Clone, Debug)]
pub(super) struct SurfaceTimelineUserData {
    surface: WlSurface,
}

#[derive(Clone, Debug)]
struct PendingSurfaceTarget {
    token: FrameToken,
    timeline: ObjectId,
    output: Option<OutputId>,
    rejection: Option<TargetRejection>,
}

#[derive(Clone, Copy, Debug)]
pub(super) struct FrameTargetReservation {
    token: FrameToken,
    output: OutputId,
    pub(super) deadline: Instant,
}

#[derive(Debug, Default)]
struct SurfaceTimelineState {
    owner: Option<ObjectId>,
    pending: Option<PendingSurfaceTarget>,
    last_consumed: Option<FrameToken>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum TargetError {
    InvalidIdentity,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum TargetRejection {
    InvalidIdentity,
    InactiveTimeline,
    WrongOutput,
    Regression,
}

impl TargetRejection {
    const fn name(self) -> &'static str {
        match self {
            Self::InvalidIdentity => "invalid_identity",
            Self::InactiveTimeline => "inactive_timeline",
            Self::WrongOutput => "wrong_output",
            Self::Regression => "target_regression",
        }
    }
}

fn lock_surface_state(
    state: &Mutex<SurfaceTimelineState>,
) -> std::sync::MutexGuard<'_, SurfaceTimelineState> {
    state
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl WaylandFrontend {
    pub(super) fn invalidate_frame_timeline(&mut self) {
        self.frame_timeline.reset();
    }

    pub(super) fn invalidate_output_frame_timeline(&mut self, output: OutputId) {
        self.frame_timeline.begin_new_epoch(output);
    }

    fn frame_timeline_output_id(&self, resource: &WlOutput) -> Option<OutputId> {
        let output = Output::from_resource(resource)?;
        self.outputs
            .iter()
            .find(|entry| entry.output == output)
            .map(|entry| entry.id)
    }

    fn register_surface_timeline(
        &mut self,
        surface: &WlSurface,
        resource: &DenialSurfaceFrameTimelineV1,
    ) -> Result<(), TargetError> {
        with_states(surface, |states| {
            states
                .data_map
                .insert_if_missing_threadsafe(|| Mutex::new(SurfaceTimelineState::default()));
            let state = states
                .data_map
                .get::<Mutex<SurfaceTimelineState>>()
                .expect("surface timeline state was just installed");
            let mut state = lock_surface_state(state);
            if state.owner.is_some() {
                return Err(TargetError::InvalidIdentity);
            }
            state.owner = Some(resource.id());
            state.pending = None;
            Ok(())
        })
    }

    fn unregister_surface_timeline(
        &mut self,
        surface: &WlSurface,
        resource: &DenialSurfaceFrameTimelineV1,
    ) {
        with_states(surface, |states| {
            let Some(state) = states.data_map.get::<Mutex<SurfaceTimelineState>>() else {
                return;
            };
            let mut state = lock_surface_state(state);
            if state.owner.as_ref() == Some(&resource.id()) {
                state.owner = None;
                state.pending = None;
            }
        });
    }

    fn set_surface_target(
        &mut self,
        surface_resource: &DenialSurfaceFrameTimelineV1,
        surface: &WlSurface,
        timeline: &DenialOutputFrameTimelineV1,
        token: FrameToken,
    ) {
        let subscription = self.frame_timeline.subscriptions.get(&timeline.id());
        let output = subscription.and_then(|subscription| subscription.output);
        let mut rejection = if token.epoch == 0
            || token.sequence == 0
            || output.and_then(|output| self.frame_timeline.current_epoch(output))
                != Some(token.epoch)
            || token.sequence > self.frame_timeline.next_sequence
        {
            Some(TargetRejection::InvalidIdentity)
        } else {
            None
        };
        if rejection.is_none() && subscription.is_none_or(|subscription| !subscription.active) {
            rejection = Some(TargetRejection::InactiveTimeline);
        }
        if rejection.is_none()
            && let (Some(grant), Some(subscription), Some(output)) =
                (self.frame_timeline.grants.get(&token), subscription, output)
            && (grant.output != output || !subscription.grants.contains(&token))
        {
            rejection = Some(TargetRejection::WrongOutput);
        }

        with_states(surface, |states| {
            let Some(state) = states.data_map.get::<Mutex<SurfaceTimelineState>>() else {
                warn!(
                    ?token,
                    "ignored target for a surface without timeline state"
                );
                return;
            };
            let mut state = lock_surface_state(state);
            if state.owner.as_ref() != Some(&surface_resource.id()) {
                warn!(
                    ?token,
                    "ignored target from a stale surface timeline object"
                );
                return;
            }
            if state
                .last_consumed
                .is_some_and(|previous| !newer(token, previous))
                || state.pending.as_ref().is_some_and(|pending| {
                    pending.rejection.is_none() && !newer(token, pending.token)
                })
            {
                rejection = Some(TargetRejection::Regression);
            }
            state.pending = Some(PendingSurfaceTarget {
                token,
                timeline: timeline.id(),
                output,
                rejection,
            });
        });
    }

    /// Consume the double-buffered target and decide whether this commit is
    /// latched for its grant. A commit that cannot be still applies, untargeted,
    /// once its buffer is ready: cancelling it would leave its state cached
    /// until the surface's next commit.
    pub(super) fn accept_frame_timeline_commit(
        &mut self,
        surface: &WlSurface,
        has_new_buffer: bool,
    ) -> Option<FrameTargetReservation> {
        let surface_id = surface.id();
        let state = with_states(surface, |states| {
            states
                .data_map
                .get::<Mutex<SurfaceTimelineState>>()
                .map(|state| {
                    let mut state = lock_surface_state(state);
                    if state.owner.is_none() {
                        return (false, None);
                    }
                    let pending = state.pending.take();
                    if let Some(pending) = pending.as_ref()
                        && pending.rejection.is_none()
                    {
                        state.last_consumed = Some(pending.token);
                    }
                    (true, pending)
                })
                .unwrap_or((false, None))
        });
        let (constrained, pending) = state;
        if !constrained {
            return None;
        }
        let Some(pending) = pending else {
            if has_new_buffer {
                warn!(
                    ?surface_id,
                    frame_state = "untargeted",
                    "applying an untargeted exact-timeline buffer commit"
                );
            }
            return None;
        };
        if let Some(rejection) = pending.rejection {
            debug!(
                ?surface_id,
                frame_epoch = pending.token.epoch,
                frame_sequence = pending.token.sequence,
                frame_state = rejection.name(),
                "applying a commit with a semantically invalid target untargeted"
            );
            return None;
        }
        if !has_new_buffer {
            self.frame_timeline.discarded_by_configure(pending.token);
            debug!(
                ?surface_id,
                frame_epoch = pending.token.epoch,
                frame_sequence = pending.token.sequence,
                frame_state = "discarded_by_configure",
                "surface target was consumed by a commit without a new buffer"
            );
            return None;
        }
        let subscription_eligible = self
            .frame_timeline
            .subscriptions
            .get(&pending.timeline)
            .is_some_and(|subscription| {
                subscription.active
                    && subscription.output == pending.output
                    && subscription.grants.contains(&pending.token)
            });
        let grant = self.frame_timeline.grants.get(&pending.token);
        let eligible = subscription_eligible
            && grant.is_some_and(|grant| {
                Some(grant.output) == pending.output && Instant::now() < grant.latch_deadline
            });
        debug!(
            ?surface_id,
            frame_epoch = pending.token.epoch,
            frame_sequence = pending.token.sequence,
            frame_state = if eligible {
                "accepted"
            } else {
                "missed_deadline"
            },
            "consumed exact surface target"
        );
        if eligible {
            grant.map(|grant| FrameTargetReservation {
                token: pending.token,
                output: grant.output,
                deadline: grant.latch_deadline,
            })
        } else {
            self.frame_timeline.missed(pending.token);
            None
        }
    }

    pub(super) fn frame_target_ready(&mut self, target: FrameTargetReservation, surface: ObjectId) {
        self.frame_timeline.ready(target.token);
        debug!(
            ?surface,
            frame_epoch = target.token.epoch,
            frame_sequence = target.token.sequence,
            frame_state = "ready",
            "targeted surface commit became ready before its latch"
        );
    }

    pub(super) fn frame_target_missed(
        &mut self,
        target: FrameTargetReservation,
        surface: ObjectId,
    ) {
        self.frame_timeline.missed(target.token);
        debug!(
            ?surface,
            frame_epoch = target.token.epoch,
            frame_sequence = target.token.sequence,
            frame_state = "missed_deadline",
            "targeted surface commit missed its latch"
        );
    }

    pub(super) fn frame_target_blocker(
        &self,
        target: FrameTargetReservation,
    ) -> FrameDeadlineBlocker {
        // Epochs start at one, so a detached zero guard reads as ended.
        let guard = self
            .frame_timeline
            .epochs
            .get(&target.output)
            .map(|current| Arc::clone(&current.guard))
            .unwrap_or_default();
        FrameDeadlineBlocker::new(target.deadline, guard, target.token.epoch)
    }

    pub(super) fn publish_frame_grant(&mut self, tick: FrameTick) -> usize {
        let latch = self.presentation.timeline_time(tick.presentation_target);
        let Some(target_instant) = tick.presentation_target.checked_add(tick.nominal_interval)
        else {
            return 0;
        };
        let target = self.presentation.timeline_time(target_instant);
        self.frame_timeline.publish(tick, latch, target)
    }
}

const DEADLINE_PENDING: u8 = 0;
const DEADLINE_READY: u8 = 1;
const DEADLINE_MISSED: u8 = 2;

/// A transaction blocker paired with the producer acquire fence. It holds the
/// commit until the race between that fence and the named compositor latch is
/// settled, so the grant records the commit as ready or missed before it
/// applies.
///
/// It never cancels the transaction. Smithay would keep a cancelled commit's
/// state cached until the surface's next applied commit and merge it there;
/// if that commit detaches the surface, or never comes, the buffer's syncobj
/// release point is never signalled and the producer stalls. A commit that
/// misses its latch, or whose epoch ends first, applies once its acquire fence
/// allows and is shown at the next opportunity.
#[derive(Clone, Debug)]
pub(super) struct FrameDeadlineBlocker {
    state: Arc<AtomicU8>,
    deadline: Instant,
    epoch_guard: Arc<AtomicU64>,
    epoch: u64,
}

impl FrameDeadlineBlocker {
    pub(super) fn new(deadline: Instant, epoch_guard: Arc<AtomicU64>, epoch: u64) -> Self {
        Self {
            state: Arc::new(AtomicU8::new(DEADLINE_PENDING)),
            deadline,
            epoch_guard,
            epoch,
        }
    }

    /// Complete the readiness race once. `Some(true)` means ready before the
    /// latch, `Some(false)` means the fence itself arrived late, and `None`
    /// means the deadline timer already made the transition.
    pub(super) fn release_if_on_time(&self, now: Instant) -> Option<bool> {
        let terminal = if now < self.deadline && self.epoch_is_current() {
            DEADLINE_READY
        } else {
            DEADLINE_MISSED
        };
        self.state
            .compare_exchange(
                DEADLINE_PENDING,
                terminal,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .ok()
            .map(|_| terminal == DEADLINE_READY)
    }

    pub(super) fn miss_if_pending(&self) -> bool {
        self.state
            .compare_exchange(
                DEADLINE_PENDING,
                DEADLINE_MISSED,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_ok()
    }

    fn epoch_is_current(&self) -> bool {
        self.epoch_guard.load(Ordering::Acquire) == self.epoch
    }
}

impl Blocker for FrameDeadlineBlocker {
    fn state(&self) -> BlockerState {
        // A grant from an ended epoch is already aborted, so its commit no
        // longer waits for the latch race.
        if self.state.load(Ordering::Acquire) == DEADLINE_PENDING && self.epoch_is_current() {
            BlockerState::Pending
        } else {
            BlockerState::Released
        }
    }
}

impl GlobalDispatch<DenialFrameTimelineManagerV1, ()> for RuntimeState {
    fn bind(
        _state: &mut Self,
        _handle: &DisplayHandle,
        _client: &Client,
        resource: New<DenialFrameTimelineManagerV1>,
        _global_data: &(),
        data_init: &mut DataInit<'_, Self>,
    ) {
        data_init.init(resource, ());
    }
}

impl Dispatch<DenialFrameTimelineManagerV1, ()> for RuntimeState {
    fn request(
        state: &mut Self,
        _client: &Client,
        _resource: &DenialFrameTimelineManagerV1,
        request: denial_frame_timeline_manager_v1::Request,
        _data: &(),
        _handle: &DisplayHandle,
        data_init: &mut DataInit<'_, Self>,
    ) {
        match request {
            denial_frame_timeline_manager_v1::Request::GetTimeline { id, output } => {
                let output_id = state
                    .wayland
                    .as_ref()
                    .and_then(|frontend| frontend.frame_timeline_output_id(&output));
                let resource = data_init.init(id, OutputTimelineUserData { _output: output_id });
                if let Some(frontend) = state.wayland.as_mut() {
                    frontend.frame_timeline.register(output_id, resource);
                }
            }
            denial_frame_timeline_manager_v1::Request::GetSurfaceTimeline { id, surface } => {
                let resource = data_init.init(
                    id,
                    SurfaceTimelineUserData {
                        surface: surface.clone(),
                    },
                );
                let result = state
                    .wayland
                    .as_mut()
                    .ok_or(TargetError::InvalidIdentity)
                    .and_then(|frontend| frontend.register_surface_timeline(&surface, &resource));
                if result.is_err() {
                    resource.post_error(
                        denial_surface_frame_timeline_v1::Error::InvalidIdentity,
                        "surface already has an exact frame timeline".to_owned(),
                    );
                }
            }
            denial_frame_timeline_manager_v1::Request::Destroy => {}
        }
    }
}

impl Dispatch<DenialOutputFrameTimelineV1, OutputTimelineUserData> for RuntimeState {
    fn request(
        state: &mut Self,
        _client: &Client,
        resource: &DenialOutputFrameTimelineV1,
        request: denial_output_frame_timeline_v1::Request,
        _data: &OutputTimelineUserData,
        _handle: &DisplayHandle,
        _data_init: &mut DataInit<'_, Self>,
    ) {
        match request {
            denial_output_frame_timeline_v1::Request::SetActive { active: 0 } => {
                if let Some(frontend) = state.wayland.as_mut() {
                    frontend.frame_timeline.set_active(&resource.id(), false);
                }
            }
            denial_output_frame_timeline_v1::Request::SetActive { active: 1 } => {
                if let Some(frontend) = state.wayland.as_mut() {
                    frontend.frame_timeline.set_active(&resource.id(), true);
                }
            }
            denial_output_frame_timeline_v1::Request::SetActive { active } => resource.post_error(
                denial_output_frame_timeline_v1::Error::InvalidActive,
                format!("invalid frame timeline active value {active}"),
            ),
            denial_output_frame_timeline_v1::Request::Destroy => {}
        }
    }

    fn destroyed(
        state: &mut Self,
        _client: ClientId,
        resource: &DenialOutputFrameTimelineV1,
        _data: &OutputTimelineUserData,
    ) {
        if let Some(frontend) = state.wayland.as_mut() {
            frontend.frame_timeline.unregister(&resource.id());
        }
    }
}

impl Dispatch<DenialSurfaceFrameTimelineV1, SurfaceTimelineUserData> for RuntimeState {
    fn request(
        state: &mut Self,
        _client: &Client,
        resource: &DenialSurfaceFrameTimelineV1,
        request: denial_surface_frame_timeline_v1::Request,
        data: &SurfaceTimelineUserData,
        _handle: &DisplayHandle,
        _data_init: &mut DataInit<'_, Self>,
    ) {
        match request {
            denial_surface_frame_timeline_v1::Request::SetTarget {
                timeline,
                epoch_hi,
                epoch_lo,
                sequence_hi,
                sequence_lo,
            } => {
                if !timeline.id().same_client_as(&resource.id()) {
                    resource.post_error(
                        denial_surface_frame_timeline_v1::Error::InvalidIdentity,
                        "frame timeline belongs to another client".to_owned(),
                    );
                    return;
                }
                let token = FrameToken {
                    epoch: join_u64(epoch_hi, epoch_lo),
                    sequence: join_u64(sequence_hi, sequence_lo),
                };
                if let Some(frontend) = state.wayland.as_mut() {
                    frontend.set_surface_target(resource, &data.surface, &timeline, token);
                } else {
                    warn!(
                        ?token,
                        "ignored frame target while Wayland frontend is unavailable"
                    );
                }
            }
            denial_surface_frame_timeline_v1::Request::Destroy => {}
        }
    }

    fn destroyed(
        state: &mut Self,
        _client: ClientId,
        resource: &DenialSurfaceFrameTimelineV1,
        data: &SurfaceTimelineUserData,
    ) {
        if let Some(frontend) = state.wayland.as_mut() {
            frontend.unregister_surface_timeline(&data.surface, resource);
        }
    }
}

const fn join_u64(high: u32, low: u32) -> u64 {
    (high as u64) << 32 | low as u64
}

const fn split_u64(value: u64) -> (u32, u32) {
    ((value >> 32) as u32, value as u32)
}

/// Sequences are allocated once across all outputs, so they alone order two
/// identities, whichever outputs and epochs issued them.
fn newer(token: FrameToken, previous: FrameToken) -> bool {
    token.sequence > previous.sequence
}

fn cadence_changed(previous: OutputCadence, tick: FrameTick) -> bool {
    tick.sequence <= previous.sequence || tick.nominal_interval != previous.nominal_interval
}

fn duration_nanos(value: Duration) -> u64 {
    u64::try_from(value.as_nanos()).unwrap_or(u64::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;
    use smithay::reexports::wayland_server::Display;
    use smithay::reexports::wayland_server::backend::ClientData;
    use std::io::{ErrorKind, Read};
    use std::os::unix::net::UnixStream;

    const GRANT: u32 = 0;
    const EPOCH: u32 = 1;
    const PERIOD: Duration = Duration::from_micros(8_333);

    struct TestClient;
    impl ClientData for TestClient {}

    /// One client connection with real timeline objects; no compositor
    /// session, output or surface.
    struct Fixture {
        display: Display<RuntimeState>,
        manager: FrameTimelineManager,
        client: Client,
        socket: UnixStream,
    }

    impl Fixture {
        fn new() -> Self {
            let display = Display::<RuntimeState>::new().unwrap();
            let mut handle = display.handle();
            let manager = FrameTimelineManager::new(&handle);
            let (socket, server) = UnixStream::pair().unwrap();
            socket.set_nonblocking(true).unwrap();
            let client = handle.insert_client(server, Arc::new(TestClient)).unwrap();
            Self {
                display,
                manager,
                client,
                socket,
            }
        }

        fn subscribe(&mut self, output: u64) -> ObjectId {
            let output = Some(OutputId(output));
            let resource = self
                .client
                .create_resource::<DenialOutputFrameTimelineV1, _, RuntimeState>(
                    &self.display.handle(),
                    1,
                    OutputTimelineUserData { _output: output },
                )
                .unwrap();
            let id = resource.id();
            self.manager.register(output, resource);
            self.manager.set_active(&id, true);
            id
        }

        fn tick(&mut self, output: u64, sequence: u64, period: Duration) -> FrameToken {
            let now = Instant::now();
            let output = OutputId(output);
            self.manager.publish(
                FrameTick {
                    output,
                    sequence,
                    nominal_interval: period,
                    interval: period,
                    render_deadline: now,
                    presentation_target: now + period,
                },
                Duration::from_secs(1),
                Duration::from_secs(2),
            );
            self.manager
                .grants
                .iter()
                .filter(|(_, record)| record.output == output)
                .map(|(token, _)| *token)
                .max_by_key(|token| token.sequence)
                .unwrap()
        }

        fn guard(&self, output: u64) -> Arc<AtomicU64> {
            Arc::clone(&self.manager.epochs[&OutputId(output)].guard)
        }

        fn holds(&self, subscription: &ObjectId, token: FrameToken) -> bool {
            self.manager.subscriptions[subscription]
                .grants
                .contains(&token)
        }

        /// (object, opcode) of every event sent since the last call.
        fn events(&mut self) -> Vec<(u32, u32)> {
            self.display.flush_clients().unwrap();
            let mut bytes = Vec::new();
            let mut buffer = [0; 4096];
            loop {
                match self.socket.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(count) => bytes.extend_from_slice(&buffer[..count]),
                    Err(error) if error.kind() == ErrorKind::WouldBlock => break,
                    Err(error) => panic!("reading protocol events: {error}"),
                }
            }
            let words = bytes
                .chunks_exact(4)
                .map(|word| u32::from_ne_bytes(word.try_into().unwrap()))
                .collect::<Vec<_>>();
            let mut events = Vec::new();
            let mut offset = 0;
            while offset < words.len() {
                let length = (words[offset + 1] >> 16) as usize / 4;
                events.push((words[offset], words[offset + 1] & 0xffff));
                offset += length;
            }
            events
        }
    }

    #[test]
    fn disarm_keeps_grants_other_subscriptions_hold() {
        let mut fixture = Fixture::new();
        let first = fixture.subscribe(1);
        let second = fixture.subscribe(1);
        let other_output = fixture.subscribe(2);
        let shared = fixture.tick(1, 10, PERIOD);
        let other = fixture.tick(2, 20, PERIOD);
        fixture.events();

        fixture.manager.set_active(&first, false);
        assert!(fixture.manager.grants.contains_key(&shared));
        assert!(fixture.holds(&second, shared));
        assert!(fixture.holds(&other_output, other));
        assert!(fixture.events().is_empty(), "no epoch ended");

        fixture.manager.set_active(&second, false);
        assert!(!fixture.manager.grants.contains_key(&shared));
        assert!(fixture.manager.grants.contains_key(&other));

        // Re-arming announces the unchanged epoch and replays nothing.
        fixture.manager.set_active(&first, true);
        assert_eq!(fixture.events(), [(first.protocol_id(), EPOCH)]);
        assert_eq!(
            fixture.manager.subscriptions[&first].announced_epoch,
            Some(shared.epoch)
        );
        assert!(fixture.manager.subscriptions[&first].grants.is_empty());
    }

    #[test]
    fn retiming_one_output_keeps_other_outputs_grants() {
        let mut fixture = Fixture::new();
        let retimed = fixture.subscribe(1);
        let steady = fixture.subscribe(2);
        let aborted = fixture.tick(1, 10, PERIOD);
        let kept = fixture.tick(2, 20, PERIOD);
        let deadline = Instant::now() + Duration::from_secs(1);
        let aborted_blocker = FrameDeadlineBlocker::new(deadline, fixture.guard(1), aborted.epoch);
        let kept_blocker = FrameDeadlineBlocker::new(deadline, fixture.guard(2), kept.epoch);
        fixture.events();

        let next = fixture.tick(1, 11, Duration::from_micros(16_666));
        assert_ne!(next.epoch, aborted.epoch);
        assert!(!fixture.manager.grants.contains_key(&aborted));
        assert!(fixture.holds(&steady, kept));
        assert_eq!(aborted_blocker.state(), BlockerState::Released);
        assert_eq!(kept_blocker.state(), BlockerState::Pending);
        assert_eq!(
            fixture.events(),
            [
                (retimed.protocol_id(), EPOCH),
                (retimed.protocol_id(), GRANT)
            ]
        );

        // The older epoch on output 2 still orders after output 1's grant.
        let later = fixture.tick(2, 21, PERIOD);
        assert!(later.epoch < next.epoch);
        assert!(newer(later, next));
    }

    #[test]
    fn disarm_keeps_a_latched_grant_until_presentation() {
        let mut fixture = Fixture::new();
        let subscription = fixture.subscribe(1);
        let latched = fixture.tick(1, 10, PERIOD);
        fixture.manager.ready(latched);
        let pending = fixture.tick(1, 11, PERIOD);

        fixture.manager.set_active(&subscription, false);
        assert!(fixture.manager.grants.contains_key(&latched));
        assert!(!fixture.manager.grants.contains_key(&pending));

        fixture.manager.presented(OutputId(1), 11);
        assert!(fixture.manager.grants.is_empty());
    }

    #[test]
    fn output_reset_spares_other_outputs() {
        let mut fixture = Fixture::new();
        fixture.subscribe(1);
        let steady = fixture.subscribe(2);
        let aborted = fixture.tick(1, 10, PERIOD);
        let kept = fixture.tick(2, 20, PERIOD);
        fixture.events();

        fixture.manager.begin_new_epoch(OutputId(1));
        assert!(!fixture.manager.grants.contains_key(&aborted));
        assert!(fixture.holds(&steady, kept));

        fixture.manager.reset();
        assert!(fixture.manager.grants.is_empty());
        assert!(fixture.events().contains(&(steady.protocol_id(), EPOCH)));
    }

    #[test]
    fn acquire_before_deadline_settles_target_once() {
        let now = Instant::now();
        let guard = Arc::new(AtomicU64::new(7));
        let blocker = FrameDeadlineBlocker::new(now + Duration::from_secs(1), guard, 7);

        assert_eq!(blocker.state(), BlockerState::Pending);
        assert_eq!(blocker.release_if_on_time(now), Some(true));
        assert_eq!(blocker.state(), BlockerState::Released);
        assert!(!blocker.miss_if_pending());
        assert_eq!(blocker.release_if_on_time(now), None);
    }

    #[test]
    fn acquire_at_or_after_deadline_misses_target() {
        let now = Instant::now();
        for acquired_at in [now, now + Duration::from_nanos(1)] {
            let blocker = FrameDeadlineBlocker::new(now, Arc::new(AtomicU64::new(7)), 7);
            assert_eq!(blocker.release_if_on_time(acquired_at), Some(false));
            assert_eq!(blocker.state(), BlockerState::Released);
            assert!(!blocker.miss_if_pending());
        }
    }

    #[test]
    fn deadline_wins_if_dispatched_before_acquire() {
        let now = Instant::now();
        let blocker =
            FrameDeadlineBlocker::new(now + Duration::from_secs(1), Arc::new(AtomicU64::new(7)), 7);

        assert!(blocker.miss_if_pending());
        assert_eq!(blocker.state(), BlockerState::Released);
        assert_eq!(blocker.release_if_on_time(now), None);
    }

    #[test]
    fn invalidated_epoch_releases_without_readiness() {
        let now = Instant::now();
        let guard = Arc::new(AtomicU64::new(7));
        let blocker =
            FrameDeadlineBlocker::new(now + Duration::from_secs(1), Arc::clone(&guard), 7);
        guard.store(8, Ordering::Release);

        assert_eq!(blocker.state(), BlockerState::Released);
        assert_eq!(blocker.release_if_on_time(now), Some(false));
        assert!(!blocker.miss_if_pending());
    }

    #[test]
    fn identity_conversion_preserves_all_bits() {
        let value = 0xfedc_ba98_7654_3210;
        let (high, low) = split_u64(value);
        assert_eq!(join_u64(high, low), value);
    }

    #[test]
    fn phase_adjustment_does_not_advance_epoch() {
        let now = Instant::now();
        let nominal = Duration::from_micros(8_333);
        let previous = OutputCadence {
            sequence: 41,
            nominal_interval: nominal,
        };
        let phase_adjusted_tick = FrameTick {
            output: OutputId(7),
            sequence: 42,
            nominal_interval: nominal,
            interval: nominal + Duration::from_micros(100),
            render_deadline: now,
            presentation_target: now + nominal + Duration::from_micros(100),
        };

        assert!(!cadence_changed(previous, phase_adjusted_tick));
        assert!(cadence_changed(
            previous,
            FrameTick {
                nominal_interval: Duration::from_micros(16_666),
                ..phase_adjusted_tick
            }
        ));
    }
}
