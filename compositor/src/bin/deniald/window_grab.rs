//! Interactive XDG move/resize grabs owned by the native Wayland frontend.

use smithay::backend::input::ButtonState;
use smithay::desktop::Window;
use smithay::input::Seat;
use smithay::input::pointer::{
    AxisFrame, ButtonEvent, GestureHoldBeginEvent, GestureHoldEndEvent, GesturePinchBeginEvent,
    GesturePinchEndEvent, GesturePinchUpdateEvent, GestureSwipeBeginEvent, GestureSwipeEndEvent,
    GestureSwipeUpdateEvent, GrabStartData, MotionEvent, PointerGrab, PointerInnerHandle,
    RelativeMotionEvent,
};
use smithay::reexports::wayland_protocols::xdg::shell::server::xdg_toplevel;
use smithay::reexports::wayland_server::Resource;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::utils::{Logical, Point, Rectangle, Serial, Size};
use smithay::wayland::compositor::with_states;
use smithay::wayland::shell::xdg::{SurfaceCachedState, ToplevelSurface};
use smithay::xwayland::X11Surface;
use smithay::xwayland::xwm::ResizeEdge as X11ResizeEdge;

use super::RuntimeState;
#[cfg(feature = "flutter")]
use super::wire::{WindowGeometry, WindowPlacementChange, WindowPlacementPhase};

const MAX_WINDOW_DIMENSION: i32 = 16_384;

/// Applies the client-provided XDG size hints without ever constructing the
/// inverted range that [`Ord::clamp`] rejects. Zero means "unbounded" for the
/// maximum size; negative hints and a maximum smaller than the minimum are
/// treated conservatively instead of allowing a client request to panic the
/// compositor. Client hints can never raise the result above the compositor's
/// texture and atlas dimension limit.
pub(super) fn constrain_dimension(requested: i32, minimum: i32, maximum: i32) -> i32 {
    let lower = minimum.clamp(1, MAX_WINDOW_DIMENSION);
    let upper = if maximum == 0 {
        MAX_WINDOW_DIMENSION
    } else if maximum < lower {
        lower
    } else {
        maximum.min(MAX_WINDOW_DIMENSION)
    };
    requested.max(lower).min(upper)
}

fn requested_resize_dimension(initial: i32, delta: f64, grows_with_pointer: bool) -> i32 {
    if !delta.is_finite() {
        return initial;
    }
    let delta = if grows_with_pointer { delta } else { -delta };
    round_to_i32_saturating(f64::from(initial) + delta, initial)
}

fn round_to_i32_saturating(value: f64, fallback: i32) -> i32 {
    if value.is_nan() {
        fallback
    } else if value <= f64::from(i32::MIN) {
        i32::MIN
    } else if value >= f64::from(i32::MAX) {
        i32::MAX
    } else {
        value.round() as i32
    }
}

fn anchored_resize_origin(origin: i32, initial_extent: i32, resized_extent: i32) -> i32 {
    let anchored = i64::from(origin) + i64::from(initial_extent) - i64::from(resized_extent);
    anchored.clamp(i64::from(i32::MIN), i64::from(i32::MAX)) as i32
}

macro_rules! forward_pointer_events {
    () => {
        fn relative_motion(
            &mut self,
            data: &mut RuntimeState,
            handle: &mut PointerInnerHandle<'_, RuntimeState>,
            focus: Option<(WlSurface, Point<f64, Logical>)>,
            event: &RelativeMotionEvent,
        ) {
            handle.relative_motion(data, focus, event);
        }

        fn axis(
            &mut self,
            data: &mut RuntimeState,
            handle: &mut PointerInnerHandle<'_, RuntimeState>,
            details: AxisFrame,
        ) {
            handle.axis(data, details);
        }

        fn frame(
            &mut self,
            data: &mut RuntimeState,
            handle: &mut PointerInnerHandle<'_, RuntimeState>,
        ) {
            handle.frame(data);
        }

        fn gesture_swipe_begin(
            &mut self,
            data: &mut RuntimeState,
            handle: &mut PointerInnerHandle<'_, RuntimeState>,
            event: &GestureSwipeBeginEvent,
        ) {
            handle.gesture_swipe_begin(data, event);
        }

        fn gesture_swipe_update(
            &mut self,
            data: &mut RuntimeState,
            handle: &mut PointerInnerHandle<'_, RuntimeState>,
            event: &GestureSwipeUpdateEvent,
        ) {
            handle.gesture_swipe_update(data, event);
        }

        fn gesture_swipe_end(
            &mut self,
            data: &mut RuntimeState,
            handle: &mut PointerInnerHandle<'_, RuntimeState>,
            event: &GestureSwipeEndEvent,
        ) {
            handle.gesture_swipe_end(data, event);
        }

        fn gesture_pinch_begin(
            &mut self,
            data: &mut RuntimeState,
            handle: &mut PointerInnerHandle<'_, RuntimeState>,
            event: &GesturePinchBeginEvent,
        ) {
            handle.gesture_pinch_begin(data, event);
        }

        fn gesture_pinch_update(
            &mut self,
            data: &mut RuntimeState,
            handle: &mut PointerInnerHandle<'_, RuntimeState>,
            event: &GesturePinchUpdateEvent,
        ) {
            handle.gesture_pinch_update(data, event);
        }

        fn gesture_pinch_end(
            &mut self,
            data: &mut RuntimeState,
            handle: &mut PointerInnerHandle<'_, RuntimeState>,
            event: &GesturePinchEndEvent,
        ) {
            handle.gesture_pinch_end(data, event);
        }

        fn gesture_hold_begin(
            &mut self,
            data: &mut RuntimeState,
            handle: &mut PointerInnerHandle<'_, RuntimeState>,
            event: &GestureHoldBeginEvent,
        ) {
            handle.gesture_hold_begin(data, event);
        }

        fn gesture_hold_end(
            &mut self,
            data: &mut RuntimeState,
            handle: &mut PointerInnerHandle<'_, RuntimeState>,
            event: &GestureHoldEndEvent,
        ) {
            handle.gesture_hold_end(data, event);
        }
    };
}

pub(super) fn checked_pointer_grab(
    seat: &Seat<RuntimeState>,
    surface: &WlSurface,
    serial: Serial,
) -> Option<GrabStartData<RuntimeState>> {
    let pointer = seat.get_pointer()?;
    if !pointer.has_grab(serial) {
        return None;
    }
    let start_data = pointer.grab_start_data()?;
    let (focus, _) = start_data.focus.as_ref()?;
    focus
        .id()
        .same_client_as(&surface.id())
        .then_some(start_data)
}

fn window_is_mapped(data: &RuntimeState, window: &Window) -> bool {
    let Some(frontend) = data.wayland.as_ref() else {
        return false;
    };
    let Some(surface) = frontend.window_root_surface(window) else {
        return false;
    };
    surface.is_alive()
        && frontend
            .space
            .elements()
            .any(|candidate| candidate == window)
}

fn toplevel_is_constrained(toplevel: &ToplevelSurface) -> bool {
    toplevel.with_pending_state(|pending| {
        pending.states.contains(xdg_toplevel::State::Fullscreen)
            || pending.states.contains(xdg_toplevel::State::Maximized)
    })
}

fn toplevel_is_resizing(toplevel: &ToplevelSurface) -> bool {
    toplevel.with_pending_state(|pending| pending.states.contains(xdg_toplevel::State::Resizing))
}

fn window_accepts_grab_updates(data: &RuntimeState, window: &Window) -> bool {
    window_is_mapped(data, window)
        && if let Some(toplevel) = window.toplevel() {
            !toplevel_is_constrained(toplevel)
        } else if let Some(x11) = window.x11_surface() {
            !x11.is_override_redirect() && !x11.is_fullscreen() && !x11.is_maximized()
        } else {
            false
        }
}

pub(super) struct MoveSurfaceGrab {
    start_data: GrabStartData<RuntimeState>,
    window: Window,
    initial_location: Point<i32, Logical>,
    forward_buttons: bool,
}

impl MoveSurfaceGrab {
    pub(super) fn new(
        start_data: GrabStartData<RuntimeState>,
        window: Window,
        initial_location: Point<i32, Logical>,
    ) -> Self {
        Self {
            start_data,
            window,
            initial_location,
            forward_buttons: true,
        }
    }

    /// Build a compositor-owned grab. Pointer button transitions still pass
    /// through Smithay so its physical pressed-button bookkeeping remains
    /// correct, but are not leaked to the client below the SUPER binding.
    #[cfg(feature = "flutter")]
    pub(super) fn new_compositor(
        start_data: GrabStartData<RuntimeState>,
        window: Window,
        initial_location: Point<i32, Logical>,
    ) -> Self {
        Self {
            start_data,
            window,
            initial_location,
            forward_buttons: false,
        }
    }
}

impl PointerGrab<RuntimeState> for MoveSurfaceGrab {
    fn motion(
        &mut self,
        data: &mut RuntimeState,
        handle: &mut PointerInnerHandle<'_, RuntimeState>,
        _focus: Option<(WlSurface, Point<f64, Logical>)>,
        event: &MotionEvent,
    ) {
        handle.motion(data, None, event);
        if !window_accepts_grab_updates(data, &self.window) {
            handle.unset_grab(self, data, event.serial, event.time, true);
            return;
        }
        if !event.location.x.is_finite()
            || !event.location.y.is_finite()
            || !self.start_data.location.x.is_finite()
            || !self.start_data.location.y.is_finite()
        {
            return;
        }
        let delta = event.location - self.start_data.location;
        let location = Point::from((
            round_to_i32_saturating(
                f64::from(self.initial_location.x) + delta.x,
                self.initial_location.x,
            ),
            round_to_i32_saturating(
                f64::from(self.initial_location.y) + delta.y,
                self.initial_location.y,
            ),
        ));
        let geometry = {
            let frontend = data.wayland.as_ref().expect("missing Wayland frontend");
            let current = frontend.window_geometry_target(&self.window);
            Rectangle::new(location, current.size)
        };
        data.wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .set_window_geometry_target(&self.window, geometry);
        #[cfg(feature = "flutter")]
        {
            super::wayland_frontend::queue_window_placement(
                data,
                &self.window,
                geometry,
                WindowPlacementPhase::Update,
                WindowPlacementChange::Move,
            );
        }
        // The placement event is the authoritative high-rate Flutter update.
        // Rebuilding the complete surface snapshot for every pointer sample is
        // redundant; the final grab state is synchronized from unset().
    }

    fn button(
        &mut self,
        data: &mut RuntimeState,
        handle: &mut PointerInnerHandle<'_, RuntimeState>,
        event: &ButtonEvent,
    ) {
        if self.forward_buttons {
            handle.button(data, event);
        }
        if event.state == ButtonState::Released
            && !handle.current_pressed().contains(&self.start_data.button)
        {
            handle.unset_grab(self, data, event.serial, event.time, true);
        }
    }

    forward_pointer_events!();

    fn start_data(&self) -> &GrabStartData<RuntimeState> {
        &self.start_data
    }

    fn unset(&mut self, data: &mut RuntimeState) {
        #[cfg(feature = "flutter")]
        if window_accepts_grab_updates(data, &self.window) {
            let geometry = data
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .window_geometry_target(&self.window);
            super::wayland_frontend::queue_window_placement(
                data,
                &self.window,
                geometry,
                WindowPlacementPhase::End,
                WindowPlacementChange::Move,
            );
        }
        data.scene_sync.mark_dirty();
    }
}

#[derive(Clone, Copy)]
pub(super) struct ResizeEdges {
    top: bool,
    bottom: bool,
    left: bool,
    right: bool,
}

impl ResizeEdges {
    pub(super) fn from_xdg(edge: xdg_toplevel::ResizeEdge) -> Option<Self> {
        use xdg_toplevel::ResizeEdge as Edge;
        let edges = match edge {
            Edge::Top => Self::new(true, false, false, false),
            Edge::Bottom => Self::new(false, true, false, false),
            Edge::Left => Self::new(false, false, true, false),
            Edge::Right => Self::new(false, false, false, true),
            Edge::TopLeft => Self::new(true, false, true, false),
            Edge::BottomLeft => Self::new(false, true, true, false),
            Edge::TopRight => Self::new(true, false, false, true),
            Edge::BottomRight => Self::new(false, true, false, true),
            _ => return None,
        };
        Some(edges)
    }

    pub(super) const fn from_x11(edge: X11ResizeEdge) -> Self {
        match edge {
            X11ResizeEdge::Top => Self::new(true, false, false, false),
            X11ResizeEdge::Bottom => Self::new(false, true, false, false),
            X11ResizeEdge::Left => Self::new(false, false, true, false),
            X11ResizeEdge::Right => Self::new(false, false, false, true),
            X11ResizeEdge::TopLeft => Self::new(true, false, true, false),
            X11ResizeEdge::BottomLeft => Self::new(false, true, true, false),
            X11ResizeEdge::TopRight => Self::new(true, false, false, true),
            X11ResizeEdge::BottomRight => Self::new(false, true, false, true),
        }
    }

    const fn new(top: bool, bottom: bool, left: bool, right: bool) -> Self {
        Self {
            top,
            bottom,
            left,
            right,
        }
    }
}

/// Compositor-owned SUPER+pointer grab for a window whose content and native
/// identity are local to the embedded Flutter shell. It publishes the same
/// placement phases as XDG/X11 grabs, without inventing a Wayland surface.
#[cfg(feature = "flutter")]
pub(super) struct LocalFlutterWindowGrab {
    start_data: GrabStartData<RuntimeState>,
    window_id: u64,
    initial_geometry: WindowGeometry,
    last_geometry: WindowGeometry,
    change: WindowPlacementChange,
    resize_edges: Option<ResizeEdges>,
}

#[cfg(feature = "flutter")]
impl LocalFlutterWindowGrab {
    pub(super) fn new_move(
        start_data: GrabStartData<RuntimeState>,
        window_id: u64,
        geometry: WindowGeometry,
    ) -> Self {
        Self {
            start_data,
            window_id,
            initial_geometry: geometry,
            last_geometry: geometry,
            change: WindowPlacementChange::Move,
            resize_edges: None,
        }
    }

    pub(super) fn new_resize(
        start_data: GrabStartData<RuntimeState>,
        window_id: u64,
        geometry: WindowGeometry,
        resize_edges: ResizeEdges,
    ) -> Self {
        Self {
            start_data,
            window_id,
            initial_geometry: geometry,
            last_geometry: geometry,
            change: WindowPlacementChange::Resize,
            resize_edges: Some(resize_edges),
        }
    }

    fn update_geometry(&mut self, location: Point<f64, Logical>) {
        if !location.x.is_finite()
            || !location.y.is_finite()
            || !self.start_data.location.x.is_finite()
            || !self.start_data.location.y.is_finite()
        {
            return;
        }
        let delta = location - self.start_data.location;
        let Some(edges) = self.resize_edges else {
            self.last_geometry.x = (self.initial_geometry.x + delta.x).round();
            self.last_geometry.y = (self.initial_geometry.y + delta.y).round();
            return;
        };

        let requested_width = if edges.left {
            self.initial_geometry.width - delta.x
        } else if edges.right {
            self.initial_geometry.width + delta.x
        } else {
            self.initial_geometry.width
        };
        let requested_height = if edges.top {
            self.initial_geometry.height - delta.y
        } else if edges.bottom {
            self.initial_geometry.height + delta.y
        } else {
            self.initial_geometry.height
        };
        let width = constrain_local_dimension(requested_width, self.initial_geometry.width);
        let height = constrain_local_dimension(requested_height, self.initial_geometry.height);
        self.last_geometry = WindowGeometry {
            x: if edges.left {
                self.initial_geometry.x + self.initial_geometry.width - width
            } else {
                self.initial_geometry.x
            },
            y: if edges.top {
                self.initial_geometry.y + self.initial_geometry.height - height
            } else {
                self.initial_geometry.y
            },
            width,
            height,
        };
    }
}

#[cfg(feature = "flutter")]
fn constrain_local_dimension(requested: f64, fallback: f64) -> f64 {
    if requested.is_finite() {
        requested
            .round()
            .clamp(64.0, f64::from(MAX_WINDOW_DIMENSION))
    } else {
        fallback
    }
}

#[cfg(feature = "flutter")]
impl PointerGrab<RuntimeState> for LocalFlutterWindowGrab {
    fn motion(
        &mut self,
        data: &mut RuntimeState,
        handle: &mut PointerInnerHandle<'_, RuntimeState>,
        _focus: Option<(WlSurface, Point<f64, Logical>)>,
        event: &MotionEvent,
    ) {
        handle.motion(data, None, event);
        if !data
            .wayland
            .as_ref()
            .is_some_and(|frontend| frontend.is_local_flutter_window(self.window_id))
        {
            handle.unset_grab(self, data, event.serial, event.time, true);
            return;
        }
        self.update_geometry(event.location);
        data.wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .set_local_flutter_window_global_geometry(self.window_id, self.last_geometry);
        super::wayland_frontend::queue_local_flutter_window_placement(
            data,
            self.window_id,
            WindowPlacementPhase::Update,
            self.change,
        );
    }

    fn button(
        &mut self,
        data: &mut RuntimeState,
        handle: &mut PointerInnerHandle<'_, RuntimeState>,
        event: &ButtonEvent,
    ) {
        if event.state == ButtonState::Released
            && !handle.current_pressed().contains(&self.start_data.button)
        {
            handle.unset_grab(self, data, event.serial, event.time, true);
        }
    }

    forward_pointer_events!();

    fn start_data(&self) -> &GrabStartData<RuntimeState> {
        &self.start_data
    }

    fn unset(&mut self, data: &mut RuntimeState) {
        if data
            .wayland
            .as_ref()
            .is_some_and(|frontend| frontend.is_local_flutter_window(self.window_id))
        {
            super::wayland_frontend::queue_local_flutter_window_placement(
                data,
                self.window_id,
                WindowPlacementPhase::End,
                self.change,
            );
        }
        data.scene_sync.mark_dirty();
    }
}

pub(super) struct ResizeSurfaceGrab {
    start_data: GrabStartData<RuntimeState>,
    window: Window,
    toplevel: ToplevelSurface,
    edges: ResizeEdges,
    initial_location: Point<i32, Logical>,
    initial_size: Size<i32, Logical>,
    last_location: Point<i32, Logical>,
    last_size: Size<i32, Logical>,
    finished: bool,
    forward_buttons: bool,
}

impl ResizeSurfaceGrab {
    pub(super) fn new(
        start_data: GrabStartData<RuntimeState>,
        window: Window,
        toplevel: ToplevelSurface,
        edges: ResizeEdges,
        initial_location: Point<i32, Logical>,
        initial_size: Size<i32, Logical>,
    ) -> Self {
        let initial_size = Size::from((
            initial_size.w.clamp(1, MAX_WINDOW_DIMENSION),
            initial_size.h.clamp(1, MAX_WINDOW_DIMENSION),
        ));
        Self {
            start_data,
            window,
            toplevel,
            edges,
            initial_location,
            initial_size,
            last_location: initial_location,
            last_size: initial_size,
            finished: false,
            forward_buttons: true,
        }
    }

    /// Equivalent to [`Self::new`], but consumes the initiating pointer button
    /// as a compositor binding instead of forwarding it to the client.
    #[cfg(feature = "flutter")]
    pub(super) fn new_compositor(
        start_data: GrabStartData<RuntimeState>,
        window: Window,
        toplevel: ToplevelSurface,
        edges: ResizeEdges,
        initial_location: Point<i32, Logical>,
        initial_size: Size<i32, Logical>,
    ) -> Self {
        let mut grab = Self::new(
            start_data,
            window,
            toplevel,
            edges,
            initial_location,
            initial_size,
        );
        grab.forward_buttons = false;
        grab
    }

    fn finish(&mut self, data: &mut RuntimeState) {
        if self.finished {
            return;
        }
        self.finished = true;
        let constrained =
            self.toplevel.wl_surface().is_alive() && toplevel_is_constrained(&self.toplevel);
        if self.toplevel.wl_surface().is_alive() {
            self.toplevel.with_pending_state(|pending| {
                pending.states.unset(xdg_toplevel::State::Resizing);
                if !constrained {
                    pending.size = Some(self.last_size);
                }
            });
            self.toplevel.send_pending_configure();
        }
        if constrained || !window_is_mapped(data, &self.window) {
            data.scene_sync.mark_dirty();
            return;
        }
        let target = Rectangle::new(self.last_location, self.last_size);
        data.wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .set_window_geometry_target(&self.window, target);
        #[cfg(feature = "flutter")]
        super::wayland_frontend::queue_window_placement(
            data,
            &self.window,
            target,
            WindowPlacementPhase::End,
            WindowPlacementChange::Resize,
        );
        data.scene_sync.mark_dirty();
    }
}

impl PointerGrab<RuntimeState> for ResizeSurfaceGrab {
    fn motion(
        &mut self,
        data: &mut RuntimeState,
        handle: &mut PointerInnerHandle<'_, RuntimeState>,
        _focus: Option<(WlSurface, Point<f64, Logical>)>,
        event: &MotionEvent,
    ) {
        handle.motion(data, None, event);
        if !window_accepts_grab_updates(data, &self.window)
            || self
                .window
                .toplevel()
                .is_none_or(|toplevel| toplevel.wl_surface() != self.toplevel.wl_surface())
            || !toplevel_is_resizing(&self.toplevel)
        {
            handle.unset_grab(self, data, event.serial, event.time, true);
            return;
        }
        let delta = event.location - self.start_data.location;
        let mut requested_width = self.initial_size.w;
        let mut requested_height = self.initial_size.h;
        if self.edges.left {
            requested_width = requested_resize_dimension(self.initial_size.w, delta.x, false);
        } else if self.edges.right {
            requested_width = requested_resize_dimension(self.initial_size.w, delta.x, true);
        }
        if self.edges.top {
            requested_height = requested_resize_dimension(self.initial_size.h, delta.y, false);
        } else if self.edges.bottom {
            requested_height = requested_resize_dimension(self.initial_size.h, delta.y, true);
        }

        let (minimum, maximum) = with_states(self.toplevel.wl_surface(), |states| {
            let mut cached = states.cached_state.get::<SurfaceCachedState>();
            let current = cached.current();
            (current.min_size, current.max_size)
        });
        self.last_size = Size::from((
            constrain_dimension(requested_width, minimum.w, maximum.w),
            constrain_dimension(requested_height, minimum.h, maximum.h),
        ));
        self.last_location = Point::from((
            if self.edges.left {
                anchored_resize_origin(
                    self.initial_location.x,
                    self.initial_size.w,
                    self.last_size.w,
                )
            } else {
                self.initial_location.x
            },
            if self.edges.top {
                anchored_resize_origin(
                    self.initial_location.y,
                    self.initial_size.h,
                    self.last_size.h,
                )
            } else {
                self.initial_location.y
            },
        ));

        self.toplevel.with_pending_state(|pending| {
            pending.states.set(xdg_toplevel::State::Resizing);
            pending.size = Some(self.last_size);
        });
        self.toplevel.send_pending_configure();
        let target = Rectangle::new(self.last_location, self.last_size);
        data.wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .set_window_geometry_target(&self.window, target);
        #[cfg(feature = "flutter")]
        super::wayland_frontend::queue_window_placement(
            data,
            &self.window,
            target,
            WindowPlacementPhase::Update,
            WindowPlacementChange::Resize,
        );
        // Client commits publish new texture/size metadata.  Until then the
        // placement event lets Flutter scale the last buffer without a second
        // full-scene walk for this pointer sample.
    }

    fn button(
        &mut self,
        data: &mut RuntimeState,
        handle: &mut PointerInnerHandle<'_, RuntimeState>,
        event: &ButtonEvent,
    ) {
        if self.forward_buttons {
            handle.button(data, event);
        }
        if event.state == ButtonState::Released
            && !handle.current_pressed().contains(&self.start_data.button)
        {
            handle.unset_grab(self, data, event.serial, event.time, true);
        }
    }

    forward_pointer_events!();

    fn start_data(&self) -> &GrabStartData<RuntimeState> {
        &self.start_data
    }

    fn unset(&mut self, data: &mut RuntimeState) {
        self.finish(data);
    }
}

/// Interactive resize for an X11 window. X11 has no configure/ack cycle
/// equivalent to xdg_toplevel, so every motion sends a bounded ConfigureNotify
/// target and the last accepted geometry becomes the restore frame.
pub(super) struct X11ResizeSurfaceGrab {
    start_data: GrabStartData<RuntimeState>,
    window: Window,
    surface: X11Surface,
    edges: ResizeEdges,
    initial_geometry: Rectangle<i32, Logical>,
    last_geometry: Rectangle<i32, Logical>,
    forward_buttons: bool,
}

impl X11ResizeSurfaceGrab {
    pub(super) fn new(
        start_data: GrabStartData<RuntimeState>,
        window: Window,
        surface: X11Surface,
        edges: ResizeEdges,
        initial_geometry: Rectangle<i32, Logical>,
    ) -> Self {
        let initial_geometry = Rectangle::new(
            initial_geometry.loc,
            Size::from((
                initial_geometry.size.w.clamp(1, MAX_WINDOW_DIMENSION),
                initial_geometry.size.h.clamp(1, MAX_WINDOW_DIMENSION),
            )),
        );
        Self {
            start_data,
            window,
            surface,
            edges,
            initial_geometry,
            last_geometry: initial_geometry,
            forward_buttons: true,
        }
    }

    #[cfg(feature = "flutter")]
    pub(super) fn new_compositor(
        start_data: GrabStartData<RuntimeState>,
        window: Window,
        surface: X11Surface,
        edges: ResizeEdges,
        initial_geometry: Rectangle<i32, Logical>,
    ) -> Self {
        let mut grab = Self::new(start_data, window, surface, edges, initial_geometry);
        grab.forward_buttons = false;
        grab
    }

    fn update_geometry(&mut self, event: &MotionEvent) {
        let delta = event.location - self.start_data.location;
        let mut requested_width = self.initial_geometry.size.w;
        let mut requested_height = self.initial_geometry.size.h;
        if self.edges.left {
            requested_width =
                requested_resize_dimension(self.initial_geometry.size.w, delta.x, false);
        } else if self.edges.right {
            requested_width =
                requested_resize_dimension(self.initial_geometry.size.w, delta.x, true);
        }
        if self.edges.top {
            requested_height =
                requested_resize_dimension(self.initial_geometry.size.h, delta.y, false);
        } else if self.edges.bottom {
            requested_height =
                requested_resize_dimension(self.initial_geometry.size.h, delta.y, true);
        }

        let minimum = self
            .surface
            .min_size()
            .unwrap_or_else(|| Size::from((1, 1)));
        let maximum = self
            .surface
            .max_size()
            .unwrap_or_else(|| Size::from((0, 0)));
        let size = Size::from((
            constrain_dimension(requested_width, minimum.w, maximum.w),
            constrain_dimension(requested_height, minimum.h, maximum.h),
        ));
        let location = Point::from((
            if self.edges.left {
                anchored_resize_origin(
                    self.initial_geometry.loc.x,
                    self.initial_geometry.size.w,
                    size.w,
                )
            } else {
                self.initial_geometry.loc.x
            },
            if self.edges.top {
                anchored_resize_origin(
                    self.initial_geometry.loc.y,
                    self.initial_geometry.size.h,
                    size.h,
                )
            } else {
                self.initial_geometry.loc.y
            },
        ));
        self.last_geometry = Rectangle::new(location, size);
    }
}

impl PointerGrab<RuntimeState> for X11ResizeSurfaceGrab {
    fn motion(
        &mut self,
        data: &mut RuntimeState,
        handle: &mut PointerInnerHandle<'_, RuntimeState>,
        _focus: Option<(WlSurface, Point<f64, Logical>)>,
        event: &MotionEvent,
    ) {
        handle.motion(data, None, event);
        if !window_accepts_grab_updates(data, &self.window)
            || self.window.x11_surface() != Some(&self.surface)
        {
            handle.unset_grab(self, data, event.serial, event.time, true);
            return;
        }
        self.update_geometry(event);
        data.wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .set_window_geometry_target(&self.window, self.last_geometry);
        #[cfg(feature = "flutter")]
        super::wayland_frontend::queue_window_placement(
            data,
            &self.window,
            self.last_geometry,
            WindowPlacementPhase::Update,
            WindowPlacementChange::Resize,
        );
        // X11 ConfigureNotify/commit publishes the corresponding scene change;
        // placement remains the sole high-frequency update during the grab.
    }

    fn button(
        &mut self,
        data: &mut RuntimeState,
        handle: &mut PointerInnerHandle<'_, RuntimeState>,
        event: &ButtonEvent,
    ) {
        if self.forward_buttons {
            handle.button(data, event);
        }
        if event.state == ButtonState::Released
            && !handle.current_pressed().contains(&self.start_data.button)
        {
            handle.unset_grab(self, data, event.serial, event.time, true);
        }
    }

    forward_pointer_events!();

    fn start_data(&self) -> &GrabStartData<RuntimeState> {
        &self.start_data
    }

    fn unset(&mut self, data: &mut RuntimeState) {
        #[cfg(feature = "flutter")]
        if window_is_mapped(data, &self.window) {
            super::wayland_frontend::queue_window_placement(
                data,
                &self.window,
                self.last_geometry,
                WindowPlacementPhase::End,
                WindowPlacementChange::Resize,
            );
        }
        data.scene_sync.mark_dirty();
    }
}

#[cfg(test)]
#[path = "window_grab/tests.rs"]
mod tests;
