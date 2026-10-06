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
}

impl FrameTerminal {
    const fn name(self) -> &'static str {
        match self {
            Self::Presented => "presented",
            Self::IntentionallySkipped => "intentionally_skipped",
            Self::MissedDeadline => "missed_deadline",
            Self::DiscardedByConfigure => "discarded_by_configure",
            Self::AbortedByEpoch => "aborted_by_epoch",
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

#[derive(Debug)]
pub(super) struct FrameTimelineManager {
    _global: GlobalId,
    epoch: u64,
    next_sequence: u64,
    subscriptions: HashMap<ObjectId, OutputSubscription>,
    grants: HashMap<FrameToken, GrantRecord>,
    cadence: HashMap<OutputId, OutputCadence>,
    epoch_guard: Arc<AtomicU64>,
}

impl FrameTimelineManager {
    pub(super) fn new(display: &DisplayHandle) -> Self {
        Self {
            _global: display.create_global::<RuntimeState, DenialFrameTimelineManagerV1, _>(1, ()),
            epoch: 1,
            next_sequence: 0,
            subscriptions: HashMap::new(),
            grants: HashMap::new(),
            cadence: HashMap::new(),
            epoch_guard: Arc::new(AtomicU64::new(1)),
        }
    }

    fn begin_new_epoch(&mut self) {
        for token in self.grants.keys().copied().collect::<Vec<_>>() {
            self.finish(token, FrameTerminal::AbortedByEpoch);
        }
        self.epoch = self.epoch.wrapping_add(1).max(1);
        self.epoch_guard.store(self.epoch, Ordering::Release);
        self.cadence.clear();
        let (epoch_hi, epoch_lo) = split_u64(self.epoch);
        for subscription in self.subscriptions.values_mut() {
            subscription.grants.clear();
            if subscription.active {
                subscription.resource.epoch(epoch_hi, epoch_lo);
                subscription.announced_epoch = Some(self.epoch);
            } else {
                subscription.announced_epoch = None;
            }
        }
        debug!(
            frame_epoch = self.epoch,
            frame_state = "epoch",
            "frame timeline epoch advanced"
        );
    }

    fn allocate_token(&mut self) -> FrameToken {
        let Some(sequence) = self.next_sequence.checked_add(1) else {
            self.begin_new_epoch();
            self.next_sequence = 1;
            return FrameToken {
                epoch: self.epoch,
                sequence: 1,
            };
        };
        self.next_sequence = sequence;
        FrameToken {
            epoch: self.epoch,
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
            self.begin_new_epoch();
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
            self.begin_new_epoch();
            return 0;
        };
        let token = self.allocate_token();
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
        self.frame_timeline.begin_new_epoch();
    }

    fn frame_timeline_output_id(&self, resource: &WlOutput) -> Option<OutputId> {
        let output = Output::from_resource(resource)?;
        self.outputs
            .iter()
            .find(|entry| entry.output == output)
            .map(|entry| entry.id)
    }

    fn register_output_timeline(
        &mut self,
        output: Option<OutputId>,
        resource: DenialOutputFrameTimelineV1,
    ) {
        self.frame_timeline.subscriptions.insert(
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

    fn set_output_timeline_active(&mut self, resource: &DenialOutputFrameTimelineV1, active: bool) {
        let disarmed = {
            let Some(subscription) = self.frame_timeline.subscriptions.get_mut(&resource.id())
            else {
                return;
            };
            let disarmed = subscription.active && !active;
            subscription.active = active;
            subscription.grants.clear();
            subscription.announced_epoch = active.then_some(self.frame_timeline.epoch);
            if active {
                let (epoch_hi, epoch_lo) = split_u64(self.frame_timeline.epoch);
                subscription.resource.epoch(epoch_hi, epoch_lo);
            }
            disarmed
        };
        if disarmed {
            self.frame_timeline.begin_new_epoch();
        }
    }

    fn unregister_output_timeline(&mut self, resource: &DenialOutputFrameTimelineV1) {
        if self
            .frame_timeline
            .subscriptions
            .remove(&resource.id())
            .is_some_and(|subscription| subscription.active)
        {
            self.frame_timeline.begin_new_epoch();
        }
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
        let mut rejection = if token.epoch == 0
            || token.sequence == 0
            || token.epoch != self.frame_timeline.epoch
            || token.sequence > self.frame_timeline.next_sequence
        {
            Some(TargetRejection::InvalidIdentity)
        } else {
            None
        };
        let subscription = self.frame_timeline.subscriptions.get(&timeline.id());
        let output = subscription.and_then(|subscription| subscription.output);
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
            if state.last_consumed.is_some_and(|previous| {
                token.epoch < previous.epoch
                    || (token.epoch == previous.epoch && token.sequence <= previous.sequence)
            }) || state.pending.as_ref().is_some_and(|pending| {
                pending.rejection.is_none()
                    && (token.epoch < pending.token.epoch
                        || (token.epoch == pending.token.epoch
                            && token.sequence <= pending.token.sequence))
            }) {
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

    /// Consume the double-buffered target and decide whether this commit may
    /// enter the ordinary surface transaction.
    pub(super) fn accept_frame_timeline_commit(
        &mut self,
        surface: &WlSurface,
        has_new_buffer: bool,
    ) -> Result<Option<FrameTargetReservation>, ()> {
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
            return Ok(None);
        }
        let Some(pending) = pending else {
            if has_new_buffer {
                warn!(
                    ?surface_id,
                    frame_state = "untargeted",
                    "discarding untargeted exact-timeline buffer commit"
                );
                return Err(());
            }
            return Ok(None);
        };
        if let Some(rejection) = pending.rejection {
            debug!(
                ?surface_id,
                frame_epoch = pending.token.epoch,
                frame_sequence = pending.token.sequence,
                frame_state = rejection.name(),
                "discarding semantically invalid targeted commit without disconnecting the client"
            );
            return if has_new_buffer { Err(()) } else { Ok(None) };
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
            return Ok(None);
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
            Ok(grant.map(|grant| FrameTargetReservation {
                token: pending.token,
                deadline: grant.latch_deadline,
            }))
        } else {
            self.frame_timeline.missed(pending.token);
            Err(())
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
        FrameDeadlineBlocker::new(
            target.deadline,
            Arc::clone(&self.frame_timeline.epoch_guard),
            target.token.epoch,
        )
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
const DEADLINE_RELEASED: u8 = 1;
const DEADLINE_CANCELLED: u8 = 2;

/// A transaction blocker paired with the producer acquire fence. It makes the
/// named compositor latch a hard upper bound instead of allowing a pending
/// fence to turn frame N into frame N+1.
#[derive(Clone, Debug)]
pub(super) struct FrameDeadlineBlocker {
    state: Arc<AtomicU8>,
    deadline: Instant,
    epoch_guard: Arc<AtomicU64>,
    epoch: u64,
}

impl FrameDeadlineBlocker {
    fn new(deadline: Instant, epoch_guard: Arc<AtomicU64>, epoch: u64) -> Self {
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
        let terminal =
            if now < self.deadline && self.epoch_guard.load(Ordering::Acquire) == self.epoch {
                DEADLINE_RELEASED
            } else {
                DEADLINE_CANCELLED
            };
        self.state
            .compare_exchange(
                DEADLINE_PENDING,
                terminal,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .ok()
            .map(|_| terminal == DEADLINE_RELEASED)
    }

    pub(super) fn cancel_if_pending(&self) -> bool {
        self.state
            .compare_exchange(
                DEADLINE_PENDING,
                DEADLINE_CANCELLED,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_ok()
    }
}

impl Blocker for FrameDeadlineBlocker {
    fn state(&self) -> BlockerState {
        if self.epoch_guard.load(Ordering::Acquire) != self.epoch {
            return BlockerState::Cancelled;
        }
        match self.state.load(Ordering::Acquire) {
            DEADLINE_PENDING => BlockerState::Pending,
            DEADLINE_RELEASED => BlockerState::Released,
            _ => BlockerState::Cancelled,
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
                    frontend.register_output_timeline(output_id, resource);
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
                    frontend.set_output_timeline_active(resource, false);
                }
            }
            denial_output_frame_timeline_v1::Request::SetActive { active: 1 } => {
                if let Some(frontend) = state.wayland.as_mut() {
                    frontend.set_output_timeline_active(resource, true);
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
            frontend.unregister_output_timeline(resource);
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

fn cadence_changed(previous: OutputCadence, tick: FrameTick) -> bool {
    tick.sequence <= previous.sequence || tick.nominal_interval != previous.nominal_interval
}

fn duration_nanos(value: Duration) -> u64 {
    u64::try_from(value.as_nanos()).unwrap_or(u64::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

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
