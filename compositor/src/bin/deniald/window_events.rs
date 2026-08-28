use tracing::warn;

use super::wire;

#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) enum PendingWindowEvent {
    Activated(u64),
    Action(u64, wire::WindowAction),
    Placement(wire::WindowPlacement),
}

impl PendingWindowEvent {
    pub(super) fn window_id(&self) -> u64 {
        match self {
            Self::Activated(window_id) | Self::Action(window_id, _) => *window_id,
            Self::Placement(placement) => placement.window_id,
        }
    }

    pub(super) fn is_activation(&self) -> bool {
        matches!(self, Self::Activated(_))
    }
}

const MAX_PENDING_WINDOW_EVENTS: usize = 4096;

/// A bounded FIFO for native-to-Flutter window state.
///
/// Most events are intentionally left in strict order. Only transitions whose
/// final meaning is unambiguous are compacted: focus is last-writer-wins,
/// adjacent placement updates replace one another, idempotent state actions are
/// deduplicated, and adjacent geometry toggles cancel in pairs.
#[derive(Default)]
pub(super) struct PendingWindowEventQueue {
    events: Vec<PendingWindowEvent>,
    drain_scratch: Vec<PendingWindowEvent>,
    overflow_reported: bool,
}

impl PendingWindowEventQueue {
    pub(super) fn push_activation(&mut self, window_id: u64, restore_minimized: bool) {
        if restore_minimized {
            self.push(PendingWindowEvent::Action(
                window_id,
                wire::WindowAction::Restore,
            ));
        }
        self.push(PendingWindowEvent::Activated(window_id));
    }

    pub(super) fn push(&mut self, event: PendingWindowEvent) {
        match event {
            PendingWindowEvent::Activated(_) => self.remove_activations(),
            PendingWindowEvent::Action(window_id, action) => {
                if let Some(PendingWindowEvent::Action(previous_id, previous_action)) =
                    self.events.last()
                    && *previous_id == window_id
                    && *previous_action == action
                {
                    if matches!(
                        action,
                        wire::WindowAction::ToggleMaximize | wire::WindowAction::ToggleFullscreen
                    ) {
                        self.events.pop();
                    }
                    return;
                }
            }
            PendingWindowEvent::Placement(placement) => {
                if let Some(PendingWindowEvent::Placement(previous)) = self.events.last_mut() {
                    if *previous == placement {
                        return;
                    }
                    if previous.window_id == placement.window_id
                        && previous.phase == wire::WindowPlacementPhase::Update
                        && placement.phase == wire::WindowPlacementPhase::Update
                        && previous.change == placement.change
                    {
                        *previous = placement;
                        return;
                    }
                }
            }
        }

        if self.events.len() >= MAX_PENDING_WINDOW_EVENTS {
            if !self.overflow_reported {
                warn!(
                    limit = MAX_PENDING_WINDOW_EVENTS,
                    "dropping excess native-to-Flutter window events"
                );
                self.overflow_reported = true;
            }
            return;
        }
        self.events.push(event);
    }

    pub(super) fn extend(&mut self, events: impl IntoIterator<Item = PendingWindowEvent>) {
        for event in events {
            self.push(event);
        }
    }

    pub(super) fn drain_events(&mut self) -> Vec<PendingWindowEvent> {
        self.overflow_reported = false;
        let replacement = std::mem::take(&mut self.drain_scratch);
        std::mem::replace(&mut self.events, replacement)
    }

    pub(super) fn recycle_drained(&mut self, mut drained: Vec<PendingWindowEvent>) {
        drained.clear();
        // When processing retained nothing, put the larger active allocation
        // straight back on the producer side. If events were retained, keep
        // both buffers and alternate them on the next drain.
        if self.events.is_empty() {
            std::mem::swap(&mut self.events, &mut drained);
        }
        debug_assert!(self.drain_scratch.is_empty());
        self.drain_scratch = drained;
    }

    pub(super) fn is_empty(&self) -> bool {
        self.events.is_empty()
    }

    pub(super) fn remove_activations(&mut self) {
        self.events.retain(|event| !event.is_activation());
    }

    pub(super) fn clear(&mut self) {
        self.events.clear();
        self.overflow_reported = false;
    }
}
