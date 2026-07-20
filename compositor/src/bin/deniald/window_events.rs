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

    #[cfg(test)]
    fn as_slice(&self) -> &[PendingWindowEvent] {
        &self.events
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pending_window_focus_is_last_writer_wins() {
        let mut queue = PendingWindowEventQueue::default();
        queue.push(PendingWindowEvent::Activated(11));
        queue.push(PendingWindowEvent::Action(11, wire::WindowAction::Maximize));
        queue.push(PendingWindowEvent::Activated(22));

        assert_eq!(
            queue.as_slice(),
            &[
                PendingWindowEvent::Action(11, wire::WindowAction::Maximize),
                PendingWindowEvent::Activated(22),
            ]
        );
    }

    #[test]
    fn pending_window_updates_and_safe_actions_are_compacted() {
        let placement = |x| {
            PendingWindowEvent::Placement(wire::WindowPlacement {
                window_id: 7,
                monitor_id: 1,
                workspace_id: 1,
                phase: wire::WindowPlacementPhase::Update,
                change: wire::WindowPlacementChange::Move,
                geometry: wire::WindowGeometry {
                    x,
                    y: 0.0,
                    width: 640.0,
                    height: 480.0,
                },
            })
        };
        let mut queue = PendingWindowEventQueue::default();
        queue.push(placement(10.0));
        queue.push(placement(20.0));
        queue.push(PendingWindowEvent::Action(7, wire::WindowAction::Maximize));
        queue.push(PendingWindowEvent::Action(7, wire::WindowAction::Maximize));
        queue.push(PendingWindowEvent::Action(
            7,
            wire::WindowAction::ToggleMaximize,
        ));
        queue.push(PendingWindowEvent::Action(
            7,
            wire::WindowAction::ToggleMaximize,
        ));
        queue.push(PendingWindowEvent::Action(
            7,
            wire::WindowAction::ToggleFullscreen,
        ));
        queue.push(PendingWindowEvent::Action(
            7,
            wire::WindowAction::ToggleFullscreen,
        ));

        assert_eq!(
            queue.as_slice(),
            &[
                placement(20.0),
                PendingWindowEvent::Action(7, wire::WindowAction::Maximize),
            ]
        );
    }

    #[test]
    fn pending_window_queue_has_a_hard_memory_bound() {
        let mut queue = PendingWindowEventQueue::default();
        for window_id in 0..=MAX_PENDING_WINDOW_EVENTS as u64 {
            queue.push(PendingWindowEvent::Action(
                window_id,
                wire::WindowAction::Restore,
            ));
        }

        assert_eq!(queue.as_slice().len(), MAX_PENDING_WINDOW_EVENTS);
        assert!(queue.overflow_reported);
        assert_eq!(queue.drain_events().len(), MAX_PENDING_WINDOW_EVENTS);
        assert!(!queue.overflow_reported);
    }

    #[test]
    fn drained_window_event_storage_returns_to_the_producer() {
        let mut queue = PendingWindowEventQueue::default();
        queue.push(PendingWindowEvent::Activated(11));
        let allocation = queue.events.as_ptr();

        let mut drained = queue.drain_events();
        assert_eq!(drained.as_ptr(), allocation);
        drained.clear();
        queue.recycle_drained(drained);

        queue.push(PendingWindowEvent::Activated(12));
        assert_eq!(queue.events.as_ptr(), allocation);
    }
}
