//! Cancellation-safe touch ownership for the pinned Smithay touch implementation.
//!
//! Smithay (through 24647fc) ties cancellation to an unflushed frame, and skips slots
//! unchanged since that frame. Keep the cancellation recipient independently
//! of frame bookkeeping (and of the lifetime of its first surface).

use std::collections::HashSet;

use smithay::backend::input::{InputTime, TouchSlot};
use smithay::input::SeatHandler;
use smithay::input::touch::{
    DownEvent, GrabStartData, MotionEvent, OrientationEvent, ShapeEvent, TouchGrab,
    TouchInnerHandle, UpEvent,
};
use smithay::utils::{Logical, Point};

/// A recipient retained at Down, which must survive surface destruction.
pub trait TouchCancellation: SeatHandler {
    type Recipient: Send + 'static;

    fn touch_recipient(&self, focus: &Self::TouchFocus) -> Option<Self::Recipient>;
    fn cancel_touch_recipient(&mut self, recipient: &Self::Recipient);
}

/// Install with `Seat::add_touch_with_default_grab` instead of Smithay's default.
pub struct DefaultTouchGrab;

pub struct TouchSessionGrab<D: TouchCancellation> {
    start: GrabStartData<D>,
    focus: Option<(D::TouchFocus, Point<f64, Logical>)>,
    recipient: Option<D::Recipient>,
    active: HashSet<TouchSlot>,
    seen: HashSet<TouchSlot>,
}

impl<D: TouchCancellation> TouchSessionGrab<D> {
    pub fn focus(&self) -> Option<&D::TouchFocus> {
        self.focus.as_ref().map(|(focus, _)| focus)
    }
}

impl<D: TouchCancellation + 'static> TouchGrab<D> for DefaultTouchGrab {
    fn down(
        &mut self,
        data: &mut D,
        handle: &mut TouchInnerHandle<'_, D>,
        focus: Option<(D::TouchFocus, Point<f64, Logical>)>,
        event: &DownEvent,
    ) {
        let recipient = focus
            .as_ref()
            .and_then(|(focus, _)| data.touch_recipient(focus));
        handle.down(data, focus.clone(), event);
        handle.set_grab(
            self,
            data,
            event.serial,
            TouchSessionGrab {
                // Smithay discards grabs with a dead start surface before calling
                // cancel. Retain the actual focus separately so lifecycle cleanup
                // can still cancel a living client after wl_surface destruction.
                start: GrabStartData {
                    focus: None,
                    slot: event.slot,
                    location: event.location,
                },
                focus,
                recipient,
                active: HashSet::from([event.slot]),
                seen: HashSet::from([event.slot]),
            },
        );
    }
    fn up(&mut self, data: &mut D, handle: &mut TouchInnerHandle<'_, D>, event: &UpEvent) {
        handle.up(data, event);
    }
    fn motion(
        &mut self,
        data: &mut D,
        handle: &mut TouchInnerHandle<'_, D>,
        focus: Option<(D::TouchFocus, Point<f64, Logical>)>,
        event: &MotionEvent,
    ) {
        handle.motion(data, focus, event);
    }
    fn frame(&mut self, data: &mut D, handle: &mut TouchInnerHandle<'_, D>) {
        handle.frame(data);
    }
    fn cancel(&mut self, _data: &mut D, _handle: &mut TouchInnerHandle<'_, D>) {}
    fn shape(&mut self, data: &mut D, handle: &mut TouchInnerHandle<'_, D>, event: &ShapeEvent) {
        handle.shape(data, event);
    }
    fn orientation(
        &mut self,
        data: &mut D,
        handle: &mut TouchInnerHandle<'_, D>,
        event: &OrientationEvent,
    ) {
        handle.orientation(data, event);
    }
    fn start_data(&self) -> &GrabStartData<D> {
        unreachable!()
    }
    fn unset(&mut self, _data: &mut D) {}
}

impl<D: TouchCancellation + 'static> TouchGrab<D> for TouchSessionGrab<D> {
    fn down(
        &mut self,
        data: &mut D,
        handle: &mut TouchInnerHandle<'_, D>,
        _focus: Option<(D::TouchFocus, Point<f64, Logical>)>,
        event: &DownEvent,
    ) {
        handle.down(data, self.focus.clone(), event);
        self.active.insert(event.slot);
        self.seen.insert(event.slot);
    }
    fn up(&mut self, data: &mut D, handle: &mut TouchInnerHandle<'_, D>, event: &UpEvent) {
        if self.active.remove(&event.slot) {
            handle.up(data, event);
        }
        if self.active.is_empty() {
            handle.unset_grab(self, data);
        }
    }
    fn motion(
        &mut self,
        data: &mut D,
        handle: &mut TouchInnerHandle<'_, D>,
        _focus: Option<(D::TouchFocus, Point<f64, Logical>)>,
        event: &MotionEvent,
    ) {
        if self.active.contains(&event.slot) {
            handle.motion(data, self.focus.clone(), event);
        }
    }
    fn frame(&mut self, data: &mut D, handle: &mut TouchInnerHandle<'_, D>) {
        handle.frame(data);
    }
    fn cancel(&mut self, data: &mut D, handle: &mut TouchInnerHandle<'_, D>) {
        if !self.active.is_empty()
            && let Some(recipient) = &self.recipient
        {
            data.cancel_touch_recipient(recipient);
        }
        // Replace Smithay's slot focuses with None without sending any wire
        // Down. Include already-released slots: they may still hold a deferred
        // Up frame. This primes a fresh marker and prevents duplicate cancels
        // or frames to retired recipients in Smithay's inner cancellation.
        for slot in &self.seen {
            handle.down(
                data,
                None,
                &DownEvent {
                    slot: *slot,
                    location: self.start.location,
                    serial: 0.into(),
                    time: InputTime::from_micros(0),
                },
            );
        }
        handle.cancel(data);
        self.active.clear();
        handle.unset_grab(self, data);
    }
    fn shape(&mut self, data: &mut D, handle: &mut TouchInnerHandle<'_, D>, event: &ShapeEvent) {
        if self.active.contains(&event.slot) {
            handle.shape(data, event);
        }
    }
    fn orientation(
        &mut self,
        data: &mut D,
        handle: &mut TouchInnerHandle<'_, D>,
        event: &OrientationEvent,
    ) {
        if self.active.contains(&event.slot) {
            handle.orientation(data, event);
        }
    }
    fn start_data(&self) -> &GrabStartData<D> {
        &self.start
    }
    fn unset(&mut self, _data: &mut D) {}
}

#[cfg(test)]
mod tests {
    use super::*;
    use smithay::input::touch::{FrameMarker, TouchHandle, TouchTarget};
    use smithay::input::{Seat, SeatState};
    use smithay::reexports::wayland_server::{Client, protocol::wl_surface::WlSurface};
    use smithay::utils::IsAlive;
    use smithay::wayland::compositor::{CompositorClientState, CompositorHandler, CompositorState};
    use std::sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    };

    #[derive(Debug, Clone)]
    struct RecordingTarget {
        id: u8,
        alive: Arc<AtomicBool>,
    }
    impl PartialEq for RecordingTarget {
        fn eq(&self, other: &Self) -> bool {
            self.id == other.id
        }
    }
    impl IsAlive for RecordingTarget {
        fn alive(&self) -> bool {
            self.alive.load(Ordering::Relaxed)
        }
    }
    impl TouchTarget<TestState> for RecordingTarget {
        fn down(&self, _seat: &Seat<TestState>, data: &mut TestState, event: &DownEvent) {
            data.events.push((self.id, "down", i32::from(event.slot)));
        }
        fn up(&self, _seat: &Seat<TestState>, data: &mut TestState, event: &UpEvent) {
            data.events.push((self.id, "up", i32::from(event.slot)));
        }
        fn motion(&self, _seat: &Seat<TestState>, data: &mut TestState, event: &MotionEvent) {
            data.events.push((self.id, "motion", i32::from(event.slot)));
        }
        fn frame(&self, _seat: &Seat<TestState>, data: &mut TestState, marker: FrameMarker) {
            data.events.push((self.id, "frame", -1));
            data.markers.insert(self.id, marker);
        }
        fn cancel(&self, _seat: &Seat<TestState>, data: &mut TestState, marker: FrameMarker) {
            data.events.push((self.id, "smithay cancel", -1));
            data.markers.insert(self.id, marker);
        }
        fn shape(&self, _seat: &Seat<TestState>, data: &mut TestState, _event: &ShapeEvent) {
            data.events.push((self.id, "shape", -1));
        }
        fn orientation(
            &self,
            _seat: &Seat<TestState>,
            data: &mut TestState,
            _event: &OrientationEvent,
        ) {
            data.events.push((self.id, "orientation", -1));
        }
        fn last_frame(&self, _seat: &Seat<TestState>, data: &mut TestState) -> Option<FrameMarker> {
            data.markers.get(&self.id).copied()
        }
    }
    struct TestState {
        seats: SeatState<Self>,
        events: Vec<(u8, &'static str, i32)>,
        markers: std::collections::HashMap<u8, FrameMarker>,
    }
    impl SeatHandler for TestState {
        type KeyboardFocus = WlSurface;
        type PointerFocus = WlSurface;
        type TouchFocus = RecordingTarget;
        fn seat_state(&mut self) -> &mut SeatState<Self> {
            &mut self.seats
        }
    }
    impl smithay::wayland::pointer_constraints::PointerConstraintsHandler for TestState {}
    impl CompositorHandler for TestState {
        fn compositor_state(&mut self) -> &mut CompositorState {
            unreachable!()
        }
        fn client_compositor_state<'a>(&self, _client: &'a Client) -> &'a CompositorClientState {
            unreachable!()
        }
        fn commit(&mut self, _surface: &WlSurface) {}
    }
    impl TouchCancellation for TestState {
        type Recipient = RecordingTarget;
        fn touch_recipient(&self, focus: &RecordingTarget) -> Option<RecordingTarget> {
            Some(focus.clone())
        }
        fn cancel_touch_recipient(&mut self, target: &RecordingTarget) {
            self.events.push((target.id, "cancel", -1));
        }
    }
    fn setup() -> (TestState, TouchHandle<TestState>, RecordingTarget) {
        let mut data = TestState {
            seats: SeatState::new(),
            events: Vec::new(),
            markers: Default::default(),
        };
        let mut seat = data.seats.new_seat("recording");
        let touch = seat.add_touch_with_default_grab(|| Box::new(DefaultTouchGrab));
        let target = RecordingTarget {
            id: 1,
            alive: Arc::new(AtomicBool::new(true)),
        };
        (data, touch, target)
    }
    fn down(
        data: &mut TestState,
        touch: &TouchHandle<TestState>,
        target: &RecordingTarget,
        slot: i32,
    ) {
        touch.down(
            data,
            Some((target.clone(), (0.0, 0.0).into())),
            &DownEvent {
                slot: Some(slot as u32).into(),
                location: (10.0, 10.0).into(),
                serial: 1.into(),
                time: InputTime::from_millis(1),
            },
        );
    }
    fn up(data: &mut TestState, touch: &TouchHandle<TestState>, slot: i32) {
        touch.up(
            data,
            &UpEvent {
                slot: Some(slot as u32).into(),
                serial: 2.into(),
                time: InputTime::from_millis(2),
            },
        );
    }
    fn next_tap(data: &mut TestState, touch: &TouchHandle<TestState>, target: &RecordingTarget) {
        let start = data.events.len();
        down(data, touch, target, 0);
        touch.frame(data);
        up(data, touch, 0);
        touch.frame(data);
        assert_eq!(
            &data.events[start..],
            &[
                (target.id, "down", 0),
                (target.id, "frame", -1),
                (target.id, "up", 0),
                (target.id, "frame", -1)
            ]
        );
        assert!(!touch.is_grabbed());
    }

    #[test]
    fn cancel_after_two_completed_frames_then_next_tap() {
        let (mut data, touch, target) = setup();
        down(&mut data, &touch, &target, 0);
        touch.frame(&mut data);
        down(&mut data, &touch, &target, 1);
        touch.frame(&mut data);
        touch.cancel(&mut data);
        assert_eq!(
            data.events,
            [
                (1, "down", 0),
                (1, "frame", -1),
                (1, "down", 1),
                (1, "frame", -1),
                (1, "cancel", -1)
            ]
        );
        assert!(!touch.is_grabbed());
        // Remaining physical Ups and a repeated cancel must not reach the client.
        up(&mut data, &touch, 0);
        up(&mut data, &touch, 1);
        touch.frame(&mut data);
        touch.cancel(&mut data);
        assert_eq!(data.events.len(), 5);
        next_tap(&mut data, &touch, &target);
    }

    #[test]
    fn cancel_pending_frame_covers_unchanged_contact_and_suppresses_deferred_up_frame() {
        let (mut data, touch, target) = setup();
        down(&mut data, &touch, &target, 0);
        touch.frame(&mut data);
        down(&mut data, &touch, &target, 1);
        up(&mut data, &touch, 1);
        touch.cancel(&mut data);
        assert_eq!(
            data.events,
            [
                (1, "down", 0),
                (1, "frame", -1),
                (1, "down", 1),
                (1, "up", 1),
                (1, "cancel", -1)
            ]
        );
        next_tap(&mut data, &touch, &target);
    }

    #[test]
    fn destroyed_first_surface_still_cancels_recipient_then_new_target_owns_next_tap() {
        let (mut data, touch, target) = setup();
        down(&mut data, &touch, &target, 0);
        touch.frame(&mut data);
        down(&mut data, &touch, &target, 1);
        touch.frame(&mut data);
        target.alive.store(false, Ordering::Relaxed);
        touch.cancel(&mut data);
        assert_eq!(data.events.last(), Some(&(1, "cancel", -1)));
        assert_eq!(
            data.events
                .iter()
                .filter(|(_, event, _)| *event == "cancel")
                .count(),
            1
        );
        let next = RecordingTarget {
            id: 2,
            alive: Arc::new(AtomicBool::new(true)),
        };
        next_tap(&mut data, &touch, &next);
    }

    #[test]
    fn second_surface_does_not_steal_stream_ownership_or_receive_cancel() {
        let (mut data, touch, first) = setup();
        let second = RecordingTarget {
            id: 2,
            alive: Arc::new(AtomicBool::new(true)),
        };
        down(&mut data, &touch, &first, 0);
        touch.frame(&mut data);
        down(&mut data, &touch, &second, 1);
        touch.frame(&mut data);
        touch.cancel(&mut data);
        assert!(data.events.iter().all(|(id, _, _)| *id == 1));
        next_tap(&mut data, &touch, &second);
    }

    #[test]
    fn ordinary_two_contact_tap_balances_up_and_frame_without_cancel() {
        let (mut data, touch, target) = setup();
        down(&mut data, &touch, &target, 0);
        down(&mut data, &touch, &target, 1);
        touch.frame(&mut data);
        up(&mut data, &touch, 0);
        up(&mut data, &touch, 1);
        touch.frame(&mut data);
        assert_eq!(
            data.events,
            [
                (1, "down", 0),
                (1, "down", 1),
                (1, "frame", -1),
                (1, "up", 0),
                (1, "up", 1),
                (1, "frame", -1)
            ]
        );
        next_tap(&mut data, &touch, &target);
    }
}
