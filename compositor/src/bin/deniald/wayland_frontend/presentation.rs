use std::time::Duration;

use smithay::desktop::{PopupManager, Window, utils::SurfacePresentationFeedback};
use smithay::output::{Output, WeakOutput};
use smithay::reexports::wayland_protocols::wp::presentation_time::server::wp_presentation_feedback;
use smithay::reexports::wayland_server::DisplayHandle;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
#[cfg(feature = "flutter")]
use smithay::utils::Time;
use smithay::utils::{Clock, Monotonic};
use smithay::wayland::compositor::{
    SurfaceAttributes, TraversalAction, with_surface_tree_downward,
};
use smithay::wayland::presentation::{PresentationState, Refresh};
use smithay::wayland::seat::WaylandFocus;

use super::RuntimeState;

#[cfg(feature = "flutter")]
const MAX_REUSABLE_OUTPUT_FEEDBACKS: usize = 256;

struct PendingPresentation {
    output: WeakOutput,
    feedbacks: Vec<SurfacePresentationFeedback>,
    refresh: Refresh,
}

impl PendingPresentation {
    fn new(output: &Output, refresh: Refresh) -> Self {
        Self {
            output: output.downgrade(),
            feedbacks: Vec::new(),
            refresh,
        }
    }

    fn discard(&mut self) {
        for mut feedback in self.feedbacks.drain(..) {
            feedback.discarded();
        }
    }
}

#[cfg(feature = "flutter")]
pub(super) struct OutputPresentationBatch {
    slots: Vec<PendingPresentation>,
    active: usize,
    refresh: Refresh,
}

#[cfg(feature = "flutter")]
impl OutputPresentationBatch {
    pub(super) fn new() -> Self {
        Self {
            slots: Vec::new(),
            active: 0,
            refresh: Refresh::Unknown,
        }
    }

    pub(super) fn begin(&mut self, output: &Output) {
        // A second submit before page-flip supersedes the old attribution.
        // Discard its callbacks explicitly, but retain Smithay's internal
        // callback Vec for the next frame on this same output.
        for pending in &mut self.slots[..self.active] {
            pending.discard();
        }
        self.active = 0;
        self.slots.truncate(MAX_REUSABLE_OUTPUT_FEEDBACKS);
        self.refresh = output_refresh(output);
    }

    pub(super) fn submit_window(&mut self, output: &Output, window: &Window) {
        // Presentation feedback belongs to the buffer accepted by KMS and is
        // therefore captured at submission. wl_surface.frame is deliberately
        // not drained here; Denial's display clock releases that scheduling
        // hint independently of whether the scanout buffer changes.
        if self.active == self.slots.len() {
            self.slots
                .push(PendingPresentation::new(output, self.refresh));
        }
        let pending = &mut self.slots[self.active];
        debug_assert!(pending.feedbacks.is_empty());
        debug_assert_eq!(pending.output.upgrade().as_ref(), Some(output));
        pending.refresh = self.refresh;
        collect_window_presentation_feedback(window, &mut pending.feedbacks);
        self.active += 1;
    }
}

/// Keeps frame scheduling and presentation feedback on their distinct
/// protocol boundaries.
///
/// `wl_surface.frame` tells a client when it is useful to start producing the
/// *next* frame and is dispatched by Denial's KMS-derived display clock.
/// `wp_presentation` describes the submitted atlas and is captured when KMS
/// accepts it, then retained until that same page-flip event.
pub(super) struct PresentationTracker {
    _state: PresentationState,
    clock: Clock<Monotonic>,
    clock_id: u32,
    sequence: u64,
    shared_pending: Vec<PendingPresentation>,
}

impl PresentationTracker {
    pub(super) fn new(display: &DisplayHandle) -> Self {
        let clock = Clock::<Monotonic>::new();
        let clock_id = clock.id() as u32;
        let state = PresentationState::new::<RuntimeState>(display, clock_id);
        Self {
            _state: state,
            clock,
            clock_id,
            sequence: 0,
            shared_pending: Vec::new(),
        }
    }

    pub(super) fn submitted(
        &mut self,
        windows: impl IntoIterator<Item = (Window, Output)>,
        callback_time: Duration,
    ) {
        // Denial permits only one outstanding atomic atlas commit. Reaching a
        // second submit with live feedback would mean the KMS completion was
        // not paired with the previous submission; discard rather than ever
        // attributing those callbacks to the wrong frame.
        self.shared_pending.clear();

        for (window, output) in windows {
            let mut pending = PendingPresentation::new(&output, output_refresh(&output));
            send_window_frame_callbacks(&window, callback_time);
            collect_window_presentation_feedback(&window, &mut pending.feedbacks);
            self.shared_pending.push(pending);
        }
    }

    pub(super) fn presented(&mut self) {
        self.sequence = next_presentation_sequence(self.sequence);
        let sequence = self.sequence;
        let now = self.clock.now();
        for pending in &mut self.shared_pending {
            present_feedback(pending, now, self.clock_id, sequence);
        }
        self.shared_pending.clear();
    }

    pub(super) fn monotonic_now(&self) -> Duration {
        self.clock.now().into()
    }

    #[cfg(feature = "flutter")]
    pub(super) fn begin_output_batch(&mut self) {
        self.shared_pending.clear();
    }

    #[cfg(feature = "flutter")]
    pub(super) fn presented_output(
        &mut self,
        batch: &mut OutputPresentationBatch,
        kernel_timestamp: Option<Duration>,
        observation_delay: Duration,
        kernel_sequence: Option<u64>,
    ) {
        let sequence = kernel_sequence.unwrap_or_else(|| {
            self.sequence = next_presentation_sequence(self.sequence);
            self.sequence
        });
        let presented_at: Time<Monotonic> = kernel_timestamp
            .unwrap_or_else(|| {
                let now: Duration = self.clock.now().into();
                now.saturating_sub(observation_delay)
            })
            .into();
        for feedback in &mut batch.slots[..batch.active] {
            present_feedback(feedback, presented_at, self.clock_id, sequence);
        }
        batch.active = 0;
        batch.slots.truncate(MAX_REUSABLE_OUTPUT_FEEDBACKS);
    }
}

fn present_feedback(
    pending: &mut PendingPresentation,
    now: smithay::utils::Time<Monotonic>,
    clock_id: u32,
    sequence: u64,
) {
    let Some(output) = pending.output.upgrade() else {
        pending.discard();
        return;
    };
    for mut feedback in pending.feedbacks.drain(..) {
        feedback.presented(
            &output,
            clock_id,
            now,
            pending.refresh,
            sequence,
            wp_presentation_feedback::Kind::Vsync,
        );
    }
}

/// Capture feedback for the buffer which is entering KMS without advancing
/// the client's frame clock. Keeping these operations separate is important:
/// a submission can precede the physical edge by almost a complete refresh.
fn collect_window_presentation_feedback(
    window: &Window,
    feedbacks: &mut Vec<SurfacePresentationFeedback>,
) {
    let Some(root) = window.wl_surface() else {
        return;
    };
    collect_surface_presentation_feedback(&root, feedbacks);
    for (popup, _) in PopupManager::popups_for_surface(&root) {
        collect_surface_presentation_feedback(popup.wl_surface(), feedbacks);
    }
}

fn collect_surface_presentation_feedback(
    root: &WlSurface,
    feedbacks: &mut Vec<SurfacePresentationFeedback>,
) {
    with_surface_tree_downward(
        root,
        (),
        |_, _, &()| TraversalAction::DoChildren(()),
        |_, states, &()| {
            if let Some(feedback) = SurfacePresentationFeedback::from_states(
                states,
                wp_presentation_feedback::Kind::empty(),
            ) {
                feedbacks.push(feedback);
            }
        },
        |_, _, &()| true,
    );
}

/// Advance every outstanding client frame callback on one display-clock tick.
/// The returned count lets the caller avoid refreshing and flushing an idle
/// Wayland space.
pub(super) fn send_window_frame_callbacks(window: &Window, callback_time: Duration) -> usize {
    let Some(root) = window.wl_surface() else {
        return 0;
    };
    let callback_millis = callback_time.as_millis() as u32;
    let mut sent = send_surface_frame_callbacks(&root, callback_millis);
    for (popup, _) in PopupManager::popups_for_surface(&root) {
        sent = sent.saturating_add(send_surface_frame_callbacks(
            popup.wl_surface(),
            callback_millis,
        ));
    }
    sent
}

fn send_surface_frame_callbacks(root: &WlSurface, callback_millis: u32) -> usize {
    let mut sent = 0usize;
    with_surface_tree_downward(
        root,
        (),
        |_, _, &()| TraversalAction::DoChildren(()),
        |_, states, &()| {
            for callback in states
                .cached_state
                .get::<SurfaceAttributes>()
                .current()
                .frame_callbacks
                .drain(..)
            {
                callback.done(callback_millis);
                sent = sent.saturating_add(1);
            }
        },
        |_, _, &()| true,
    );
    sent
}

fn output_refresh(output: &Output) -> Refresh {
    output
        .current_mode()
        .and_then(|mode| refresh_interval(mode.refresh))
        .map(Refresh::fixed)
        .unwrap_or(Refresh::Unknown)
}

fn refresh_interval(refresh_millihz: i32) -> Option<Duration> {
    let refresh_millihz = u64::try_from(refresh_millihz).ok()?;
    (refresh_millihz > 0).then(|| Duration::from_nanos(1_000_000_000_000 / refresh_millihz))
}

const fn next_presentation_sequence(current: u64) -> u64 {
    current.wrapping_add(1)
}

#[cfg(test)]
mod tests {
    use super::{next_presentation_sequence, refresh_interval};
    use std::time::Duration;

    #[test]
    fn physical_refresh_is_converted_from_millihertz() {
        let interval = refresh_interval(180_000).expect("valid refresh");
        assert_eq!(interval, Duration::from_nanos(5_555_555));
        assert_eq!(refresh_interval(0), None);
        assert_eq!(refresh_interval(-1), None);
    }

    #[test]
    fn presentation_sequence_is_monotonic_modulo_protocol_width() {
        assert_eq!(next_presentation_sequence(41), 42);
        assert_eq!(next_presentation_sequence(u64::MAX), 0);
    }
}
