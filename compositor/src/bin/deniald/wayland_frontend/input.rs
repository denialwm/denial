use std::collections::HashSet;
use std::error::Error;
use std::ffi::OsStr;

use denial_core::topology::OutputTransform;
use smithay::backend::input::{
    AbsolutePositionEvent, Axis, AxisSource, ButtonState, Device, DeviceCapability, Event,
    GestureBeginEvent, GestureEndEvent, GestureSwipeUpdateEvent, InputEvent, InputTime, KeyState,
    KeyboardKeyEvent, PointerAxisEvent, PointerButtonEvent, PointerMotionEvent, TouchEvent,
};
#[cfg(feature = "flutter")]
use smithay::backend::input::{Switch, SwitchState, SwitchToggleEvent};
use smithay::backend::libinput::{LibinputInputBackend, LibinputSessionInterface};
use smithay::backend::session::Session;
use smithay::backend::session::libseat::LibSeatSession;
#[cfg(feature = "flutter")]
use smithay::desktop::{WindowSurfaceType, utils::under_from_surface_tree};
use smithay::input::keyboard::{FilterResult, KeyboardHandle, Keycode};
#[cfg(feature = "flutter")]
use smithay::input::keyboard::{XkbConfig, xkb};
use smithay::input::pointer::{
    AxisFrame, ButtonEvent, MotionEvent, PointerHandle, RelativeMotionEvent,
};
#[cfg(feature = "flutter")]
use smithay::input::pointer::{CursorImageStatus, Focus, GrabStartData};
use smithay::input::touch::{DownEvent, MotionEvent as TouchMotionEvent, UpEvent};
use smithay::reexports::calloop::EventLoop;
#[cfg(feature = "flutter")]
use smithay::reexports::calloop::timer::{TimeoutAction, Timer};
use smithay::reexports::input::{AccelProfile, Device as LibinputDevice, Libinput, TapButtonMap};
#[cfg(feature = "flutter")]
use smithay::reexports::wayland_protocols::xdg::shell::server::xdg_toplevel;
#[cfg(feature = "flutter")]
use smithay::reexports::wayland_server::Resource;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
#[cfg(feature = "flutter")]
use smithay::utils::Serial;
use smithay::utils::{Logical, Point, Rectangle, SERIAL_COUNTER};
use smithay::wayland::pointer_constraints::{PointerConstraint, with_pointer_constraint};
use tracing::{info, warn};

#[cfg(feature = "flutter")]
use super::super::PendingWindowEvent;
use super::super::lifecycle::ShutdownReason;
use super::super::native_shortcut::{
    ShortcutAction, ShortcutDisposition, ShortcutGesture, ShortcutTarget,
};
#[cfg(feature = "flutter")]
use super::super::settings::KeyboardSettings;
use super::super::settings::{MouseSettings, TouchpadSettings};
#[cfg(feature = "flutter")]
use super::super::window_grab::{
    LocalFlutterWindowGrab, MoveSurfaceGrab, ResizeEdges, ResizeSurfaceGrab, TileMoveGrab,
    TileResizeGrab,
};
#[cfg(feature = "flutter")]
use super::super::window_layout::{LayoutDirection, LayoutResizeEdges};
#[cfg(feature = "flutter")]
use super::super::wire::{
    InputLayoutSnapshot, InputWindowRegion, WindowPlacementChange, WindowPlacementPhase,
};
use super::super::{RuntimeState, logical_axis_scroll_delta};
use super::ClientSurface;
#[cfg(feature = "flutter")]
use super::FlutterPointerPress;
use super::WaylandFrontend;
use super::input_source::{InputBatchEvent, LibinputBatchSource};
#[cfg(feature = "flutter")]
use super::touch_gestures::{
    self, TouchGestureUpdate, TouchWindowTarget, WINDOW_TOUCH_CORNER_SIZE,
    WINDOW_TOUCH_STRIP_HEIGHT,
};

#[cfg(feature = "flutter")]
#[path = "input/edge_swipe.rs"]
pub(super) mod edge_swipe;
#[path = "input/flutter_route.rs"]
pub(super) mod flutter_route;
#[path = "input/tablet.rs"]
mod tablet;
#[path = "input/wayland_route.rs"]
mod wayland_route;

#[cfg(feature = "flutter")]
use flutter_route::process_flutter_input_event;
use flutter_route::process_wayland_keyboard_transition;
#[cfg(feature = "flutter")]
pub(crate) use flutter_route::reconcile_flutter_pointer_route;
#[cfg(feature = "flutter")]
pub(super) use flutter_route::release_client_geometry_for_shell_grab;
use wayland_route::process_wayland_input_event;

/// Cancel the whole client sequence before retiring any of its surface routes.
/// wl_touch.cancel is client-wide, not a per-slot or per-surface event.
pub(super) fn cancel_touch_for_surface(state: &mut RuntimeState, surface: &WlSurface) -> bool {
    let frontend = state.frontend();
    let touch = frontend.seat.get_touch().expect("seat has no touch");
    let belongs_to_surface = |focus: &WlSurface| {
        let mut current = Some(focus.clone());
        while let Some(candidate) = current {
            if &candidate == surface {
                return true;
            }
            current = smithay::wayland::compositor::get_parent(&candidate);
        }
        #[cfg(feature = "flutter")]
        if frontend.owning_toplevel_surface(focus).as_ref() == Some(surface) {
            return true;
        }
        false
    };
    let affected = touch
        .with_grab(|_, grab| {
            grab.downcast_ref::<denial_core::touch_grab::TouchSessionGrab<RuntimeState>>()
                .and_then(|grab| grab.focus())
                .is_some_and(|focus| belongs_to_surface(focus))
        })
        .unwrap_or(false);
    #[cfg(feature = "flutter")]
    let affected = affected
        || frontend.client_touch_routes.values().any(|route| {
            belongs_to_surface(&route.surface) || route.layer_root.as_ref() == Some(surface)
        });
    if affected {
        touch.cancel(state);
        #[cfg(feature = "flutter")]
        {
            let frontend = state.frontend_mut();
            frontend.client_touch_routes.clear();
            frontend.client_touch_frame_pending = false;
        }
    }
    affected
}

pub(super) fn touch_output_for_device<'a>(
    frontend: &'a WaylandFrontend,
    device: &LibinputDevice,
) -> Option<&'a super::WaylandOutput> {
    if let Some(name) = device.output_name() {
        return frontend
            .outputs
            .iter()
            .find(|output| output.connector == name.as_ref());
    }
    frontend
        .outputs
        .iter()
        .find(|output| {
            ["DSI-", "eDP-", "LVDS-"]
                .iter()
                .any(|prefix| output.connector.starts_with(prefix))
        })
        .or_else(|| {
            frontend
                .outputs
                .iter()
                .find(|output| output.logical_geometry == frontend.touch_bounds)
        })
}

fn touch_device_mapping(
    frontend: &WaylandFrontend,
    device: &LibinputDevice,
) -> (Rectangle<i32, Logical>, OutputTransform) {
    touch_output_for_device(frontend, device)
        .map(|output| (output.logical_geometry, output.transform))
        .unwrap_or((frontend.touch_bounds, frontend.touch_transform))
}

fn output_bound_absolute_position<E>(
    event: &E,
    bounds: Rectangle<i32, Logical>,
    transform: OutputTransform,
) -> Point<f64, Logical>
where
    E: AbsolutePositionEvent<LibinputInputBackend>,
{
    project_touch_position(
        bounds,
        transform,
        event.x_transformed(1),
        event.y_transformed(1),
    )
}

fn project_touch_position(
    bounds: Rectangle<i32, Logical>,
    transform: OutputTransform,
    x: f64,
    y: f64,
) -> Point<f64, Logical> {
    let (x, y) = transform.native_to_logical(x.clamp(0.0, 1.0), y.clamp(0.0, 1.0));
    let left = f64::from(bounds.loc.x);
    let top = f64::from(bounds.loc.y);
    // Output bounds are half-open, including at transformed touch endpoints.
    Point::from((
        (left + x * f64::from(bounds.size.w))
            .clamp(left, (left + f64::from(bounds.size.w)).next_down()),
        (top + y * f64::from(bounds.size.h))
            .clamp(top, (top + f64::from(bounds.size.h)).next_down()),
    ))
}

#[cfg(test)]
mod absolute_touch_bounds_tests {
    use super::*;
    #[test]
    fn edge_contacts_remain_on_their_associated_output_after_rotation() {
        let bounds = Rectangle::new((-800, 150).into(), (800, 600).into());
        for transform in [
            OutputTransform::Normal,
            OutputTransform::Rotate90,
            OutputTransform::Rotate180,
            OutputTransform::Rotate270,
        ] {
            for (x, y) in [(0.0, 0.0), (1.0, 1.0), (0.0, 1.0), (1.0, 0.0)] {
                let position = project_touch_position(bounds, transform, x, y);
                assert!(position.x >= -800.0 && position.x < 0.0);
                assert!(position.y >= 150.0 && position.y < 750.0);
            }
        }
    }
}

#[cfg(feature = "flutter")]
const BTN_LEFT: u32 = 0x110;
#[cfg(feature = "flutter")]
const BTN_RIGHT: u32 = 0x111;
#[cfg(feature = "flutter")]
const MAX_CLIENT_POINTER_PRESSES: usize = 16;

#[cfg(feature = "flutter")]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct ShellKeyStroke {
    pub(super) evdev_keycode: u32,
    pub(super) shift: bool,
}

#[cfg(feature = "flutter")]
fn shell_text_key_stroke(character: char) -> Option<ShellKeyStroke> {
    let (evdev_keycode, shift) = match character {
        'a'..='z' => (
            [
                30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50, 49, 24, 25, 16, 19, 31, 20, 22,
                47, 17, 45, 21, 44,
            ][usize::from(character as u8 - b'a')],
            false,
        ),
        'A'..='Z' => (
            [
                30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50, 49, 24, 25, 16, 19, 31, 20, 22,
                47, 17, 45, 21, 44,
            ][usize::from(character as u8 - b'A')],
            true,
        ),
        '1' => (2, false),
        '2' => (3, false),
        '3' => (4, false),
        '4' => (5, false),
        '5' => (6, false),
        '6' => (7, false),
        '7' => (8, false),
        '8' => (9, false),
        '9' => (10, false),
        '0' => (11, false),
        '!' => (2, true),
        '@' => (3, true),
        '#' => (4, true),
        '$' => (5, true),
        '%' => (6, true),
        '^' => (7, true),
        '&' => (8, true),
        '*' => (9, true),
        '(' => (10, true),
        ')' => (11, true),
        '-' => (12, false),
        '_' => (12, true),
        '=' => (13, false),
        '+' => (13, true),
        '[' => (26, false),
        '{' => (26, true),
        ']' => (27, false),
        '}' => (27, true),
        ';' => (39, false),
        ':' => (39, true),
        '\'' => (40, false),
        '"' => (40, true),
        '`' => (41, false),
        '~' => (41, true),
        '\\' => (43, false),
        '|' => (43, true),
        ',' => (51, false),
        '<' => (51, true),
        '.' => (52, false),
        '>' => (52, true),
        '/' => (53, false),
        '?' => (53, true),
        ' ' => (57, false),
        _ => return None,
    };
    Some(ShellKeyStroke {
        evdev_keycode,
        shift,
    })
}

#[cfg(feature = "flutter")]
fn shell_named_key_stroke(key: &str) -> Option<ShellKeyStroke> {
    let (evdev_keycode, shift) = match key {
        "Escape" => (1, false),
        "BackSpace" | "Backspace" => (14, false),
        "Tab" => (15, false),
        "Return" | "Enter" => (28, false),
        "space" | "Space" => (57, false),
        "Up" => (103, false),
        "Left" => (105, false),
        "Right" => (106, false),
        "Down" => (108, false),
        "Delete" => (111, false),
        "comma" => (51, false),
        "period" => (52, false),
        "slash" => (53, false),
        "backslash" => (43, false),
        "minus" => (12, false),
        "equal" => (13, false),
        "apostrophe" => (40, false),
        "semicolon" => (39, false),
        "colon" => (39, true),
        "bracketleft" => (26, false),
        "bracketright" => (27, false),
        value if value.chars().count() == 1 => shell_text_key_stroke(value.chars().next()?)
            .map(|stroke| (stroke.evdev_keycode, stroke.shift))?,
        _ => return None,
    };
    Some(ShellKeyStroke {
        evdev_keycode,
        shift,
    })
}

#[cfg(feature = "flutter")]
fn inject_shell_key_stroke(
    state: &mut RuntimeState,
    keyboard: &KeyboardHandle<RuntimeState>,
    stroke: ShellKeyStroke,
    ctrl: bool,
    time: InputTime,
) -> bool {
    const XKB_KEYCODE_OFFSET: u32 = 8;
    const LEFT_CTRL: u32 = 29;
    const LEFT_SHIFT: u32 = 42;

    let keycode = Keycode::new(stroke.evdev_keycode + XKB_KEYCODE_OFFSET);
    if keyboard.pressed_keys().contains(&keycode) {
        warn!(
            keycode = stroke.evdev_keycode,
            "ignored shell keyboard key already held by another input source"
        );
        return false;
    }

    let modifiers = keyboard.modifier_state();
    let inject_ctrl = ctrl && !modifiers.ctrl;
    let inject_shift = stroke.shift && !modifiers.shift;
    let ctrl_keycode = Keycode::new(LEFT_CTRL + XKB_KEYCODE_OFFSET);
    let shift_keycode = Keycode::new(LEFT_SHIFT + XKB_KEYCODE_OFFSET);
    let mut delivered = false;
    let mut send = |state: &mut RuntimeState, keycode: Keycode, key_state: KeyState| {
        delivered |= process_keyboard_transition(state, keycode, key_state, time);
    };

    if inject_ctrl {
        send(state, ctrl_keycode, KeyState::Pressed);
    }
    if inject_shift {
        send(state, shift_keycode, KeyState::Pressed);
    }
    send(state, keycode, KeyState::Pressed);
    send(state, keycode, KeyState::Released);
    if inject_shift {
        send(state, shift_keycode, KeyState::Released);
    }
    if inject_ctrl {
        send(state, ctrl_keycode, KeyState::Released);
    }
    delivered
}

#[cfg(feature = "flutter")]
pub(super) fn inject_shell_key_transition(
    state: &mut RuntimeState,
    keyboard: &KeyboardHandle<RuntimeState>,
    stroke: ShellKeyStroke,
    key_state: KeyState,
    time: InputTime,
) -> bool {
    const XKB_KEYCODE_OFFSET: u32 = 8;

    // Held modified keys require explicit modifier ownership. The OSK uses
    // this lifecycle only for unmodified Backspace; complete modified taps
    // continue through inject_shell_key_stroke().
    if stroke.shift {
        return false;
    }
    let keycode = Keycode::new(stroke.evdev_keycode + XKB_KEYCODE_OFFSET);
    let seat_pressed = keyboard.pressed_keys().contains(&keycode);
    let accepted = {
        let frontend = state.frontend_mut();
        route_shell_key_transition(
            &mut frontend.shell_keyboard_keys,
            keycode.raw(),
            key_state,
            seat_pressed,
        )
    };
    accepted && process_keyboard_transition(state, keycode, key_state, time)
}

/// Linux evdev `KEY_BACK`: a phone's hardware Back key. XKB names it
/// `XF86Back`, and Android, including Droidloom, maps it to `KEYCODE_BACK`.
#[cfg(feature = "flutter")]
const EVDEV_KEY_BACK: u32 = 158;

/// Delivers the system Back action to a client window as one Back key tap.
///
/// Browsers, GTK, Qt and Droidloom's Android tasks treat this key as
/// navigation back, so the action follows keyboard focus like Android's own
/// Back. A dialog of the same client that already holds the focus keeps it:
/// Back belongs to whatever the application presents on top.
#[cfg(feature = "flutter")]
pub(super) fn navigate_back(state: &mut RuntimeState, window: &smithay::desktop::Window) -> bool {
    let (keyboard, time, focused) = {
        let frontend = state.frontend();
        let keyboard = frontend.seat.get_keyboard().expect("seat has no keyboard");
        let client = frontend
            .window_root_surface(window)
            .and_then(|root| root.client())
            .map(|client| client.id());
        let focused = client.is_some()
            && keyboard.current_focus().is_some_and(|focus| {
                smithay::wayland::seat::WaylandFocus::wl_surface(&focus)
                    .and_then(|surface| surface.client())
                    .map(|client| client.id())
                    == client
            });
        (keyboard, InputTime::now(), focused)
    };
    if !focused
        && !super::window_management::activate_window(state, window, SERIAL_COUNTER.next_serial())
    {
        warn!("ignored Back for a window that cannot take keyboard focus");
        return false;
    }
    inject_shell_key_stroke(
        state,
        &keyboard,
        ShellKeyStroke {
            evdev_keycode: EVDEV_KEY_BACK,
            shift: false,
        },
        false,
        time,
    )
}

#[cfg(feature = "flutter")]
/// Turn one shell-keyboard intent into complete virtual key lifecycles.
///
/// These transitions enter the same focus, XKB, shortcut, Flutter and Wayland
/// router as libinput keyboard events. The software keyboard is an input
/// source; only text the keymap cannot type, and replacements of the word
/// before the cursor, go to the focused editor as input-method commits.
pub(crate) fn dispatch_shell_keyboard(
    state: &mut RuntimeState,
    command: &super::super::wire::KeyboardCommand,
) -> bool {
    let (keyboard, time) = {
        let frontend = state.frontend();
        (
            frontend.seat.get_keyboard().expect("seat has no keyboard"),
            InputTime::now(),
        )
    };
    // Do not gate the shared router on a focused Wayland surface. Flutter is a
    // first-class seat focus target, so software and physical keyboards both
    // use process_keyboard_transition() and the same seat dispatch.
    match command {
        super::super::wire::KeyboardCommand::DismissPanel { activation_serial } => {
            let frontend = state.frontend_mut();
            frontend.text_input.dismiss_panel(*activation_serial);
            true
        }
        super::super::wire::KeyboardCommand::PanelMotion {
            height,
            duration_ms,
        } => {
            let frontend = state.frontend_mut();
            frontend.set_keyboard_height(*height, *duration_ms);
            true
        }
        super::super::wire::KeyboardCommand::Text(text)
            if text
                .chars()
                .any(|character| shell_text_key_stroke(character).is_none()) =>
        {
            // The keymap types ASCII only; an editor takes any text.
            let frontend = state.frontend_mut();
            match frontend.commit_shell_keyboard_text(None, text) {
                Some(delivered) => delivered,
                None => type_shell_text(state, &keyboard, text, time),
            }
        }
        super::super::wire::KeyboardCommand::Replace { replaced, text } => {
            let frontend = state.frontend_mut();
            match frontend.commit_shell_keyboard_text(Some(replaced), text) {
                Some(true) => true,
                Some(false) => {
                    tracing::debug!("kept the typed word: the cursor left it");
                    false
                }
                None => {
                    // No text-input: erase the word with keys and retype it.
                    let Some(backspace) = shell_named_key_stroke("BackSpace") else {
                        return false;
                    };
                    for _ in replaced.chars() {
                        inject_shell_key_stroke(state, &keyboard, backspace, false, time);
                    }
                    type_shell_text(state, &keyboard, text, time)
                }
            }
        }
        super::super::wire::KeyboardCommand::Text(text) => {
            type_shell_text(state, &keyboard, text, time)
        }
        super::super::wire::KeyboardCommand::Key { key, ctrl, phase } => {
            let Some(stroke) = shell_named_key_stroke(key) else {
                warn!(%key, "ignored unsupported shell keyboard key");
                return false;
            };
            match phase {
                super::super::wire::KeyboardKeyPhase::Tap => {
                    inject_shell_key_stroke(state, &keyboard, stroke, *ctrl, time)
                }
                super::super::wire::KeyboardKeyPhase::Pressed => {
                    inject_shell_key_transition(state, &keyboard, stroke, KeyState::Pressed, time)
                }
                super::super::wire::KeyboardKeyPhase::Released => {
                    inject_shell_key_transition(state, &keyboard, stroke, KeyState::Released, time)
                }
            }
        }
    }
}

#[cfg(feature = "flutter")]
fn type_shell_text(
    state: &mut RuntimeState,
    keyboard: &KeyboardHandle<RuntimeState>,
    text: &str,
    time: InputTime,
) -> bool {
    let mut delivered = false;
    for character in text.chars() {
        let Some(stroke) = shell_text_key_stroke(character) else {
            warn!(%character, "ignored character unsupported by the shell keyboard keymap");
            continue;
        };
        delivered |= inject_shell_key_stroke(state, keyboard, stroke, false, time);
    }
    delivered
}

#[cfg(feature = "flutter")]
#[derive(Clone)]
pub(super) struct ClientInputRoute {
    window: Option<smithay::desktop::Window>,
    pub(super) layer_root: Option<WlSurface>,
    pub(super) surface: WlSurface,
    region: InputWindowRegion,
    layout_index: usize,
    scene_origin: Point<f64, Logical>,
}

/// A pointer press serial that was actually delivered to a Wayland client.
///
/// Smithay exposes only the serial of its current click grab. Keeping this
/// tiny, physically-bounded list lets XDG move/resize validate a later button
/// in a multi-button grab, and preserves the atlas-routed focus used when the
/// event was delivered.
#[cfg(feature = "flutter")]
pub(super) struct ClientPointerPress {
    serial: Serial,
    button: u32,
    focus: (ClientSurface, Point<f64, Logical>),
    location: Point<f64, Logical>,
}

/// A compositor-forced pointer release remains authoritative until the user
/// deliberately clicks the same toplevel again. Clients may destroy and
/// recreate their protocol constraint after receiving `unlocked`; keying this
/// policy to the window keeps those replacement constraints inactive too.
#[cfg(feature = "flutter")]
#[derive(Debug, Default)]
pub(super) struct PointerConstraintEscape {
    released_window_id: Option<u64>,
}

#[cfg(feature = "flutter")]
impl PointerConstraintEscape {
    fn release_window(&mut self, window_id: u64) {
        self.released_window_id = Some(window_id);
    }

    fn suppresses_window(&self, window_id: u64) -> bool {
        self.released_window_id == Some(window_id)
    }

    fn resume_window(&mut self, window_id: u64) -> bool {
        if !self.suppresses_window(window_id) {
            return false;
        }
        self.released_window_id = None;
        true
    }

    pub(super) fn forget_window(&mut self, window_id: u64) {
        if self.suppresses_window(window_id) {
            self.released_window_id = None;
        }
    }

    fn reset(&mut self) {
        self.released_window_id = None;
    }
}

#[cfg(feature = "flutter")]
impl ClientInputRoute {
    fn mapped_position(&self, position: Point<f64, Logical>) -> Point<f64, Logical> {
        let scene_position = position - self.scene_origin;
        let (local_x, local_y) =
            self.region
                .rect
                .map_to(self.region.source_rect, scene_position.x, scene_position.y);
        Point::from((local_x, local_y))
    }

    fn focus_at_if_hit(
        &self,
        position: Point<f64, Logical>,
    ) -> Option<(ClientSurface, Point<f64, Logical>)> {
        let local_point = self.mapped_position(position);
        let (surface, local_origin) =
            under_from_surface_tree(&self.surface, local_point, (0, 0), WindowSurfaceType::ALL)?;
        Some((
            surface.into(),
            position - local_point + local_origin.to_f64(),
        ))
    }

    fn focus_at(&self, position: Point<f64, Logical>) -> (ClientSurface, Point<f64, Logical>) {
        let local_point = self.mapped_position(position);
        let (surface, local_origin) =
            under_from_surface_tree(&self.surface, local_point, (0, 0), WindowSurfaceType::ALL)
                .unwrap_or_else(|| (self.surface.clone(), (0, 0).into()));
        (
            surface.into(),
            position - local_point + local_origin.to_f64(),
        )
    }

    fn touch_at(
        &self,
        position: Point<f64, Logical>,
    ) -> ((ClientSurface, Point<f64, Logical>), Point<f64, Logical>) {
        let (location, origin) = projected_touch_point(
            self.region.rect,
            self.region.source_rect,
            self.scene_origin,
            position,
        );
        let local_point = location - origin;
        let (surface, local_origin) =
            under_from_surface_tree(&self.surface, local_point, (0, 0), WindowSurfaceType::ALL)
                .unwrap_or_else(|| (self.surface.clone(), (0, 0).into()));
        // Smithay retains the down event's origin for the whole contact. Feed
        // it source-space motion around a fixed origin, so scaling/cropping
        // the texture does not scale input deltas or add the mobile strip.
        ((surface.into(), origin + local_origin.to_f64()), location)
    }
}

#[cfg(feature = "flutter")]
fn projected_touch_point(
    rect: super::super::wire::InputRect,
    source: super::super::wire::InputRect,
    scene_origin: Point<f64, Logical>,
    position: Point<f64, Logical>,
) -> (Point<f64, Logical>, Point<f64, Logical>) {
    let scene = position - scene_origin;
    let (x, y) = rect.map_to(source, scene.x, scene.y);
    let origin = scene_origin
        + Point::from((
            rect.x - source.x * rect.width / source.width,
            rect.y - source.y * rect.height / source.height,
        ));
    (origin + Point::from((x, y)), origin)
}

#[cfg(all(test, feature = "flutter"))]
mod touch_projection_tests {
    use super::super::super::wire::InputRect;
    use super::*;

    #[test]
    fn captured_touch_tracks_source_pixels_through_scale_crop_and_atlas_offset() {
        let scene_origin = Point::from((-1920.0, 100.0));
        let rect = InputRect {
            x: 100.0,
            y: 148.0,
            width: 600.0,
            height: 352.0,
        };
        let source = InputRect {
            x: 12.0,
            y: 48.0,
            width: 1200.0,
            height: 704.0,
        };
        let down = scene_origin + Point::from((250.0, 248.0));
        let (location, origin) = projected_touch_point(rect, source, scene_origin, down);
        assert_eq!(location - origin, Point::from((312.0, 248.0)));
        let captured_origin = origin;
        let moved = down + Point::from((30.0, 60.0));
        let (location, origin) = projected_touch_point(rect, source, scene_origin, moved);
        assert_eq!(origin, captured_origin);
        assert_eq!(location - captured_origin, Point::from((372.0, 368.0)));
        // The second contact uses the same source coordinate system, even
        // while Smithay retains the first contact's down origin.
        let (second, second_origin) = projected_touch_point(
            rect,
            source,
            scene_origin,
            down + Point::from((100.0, 20.0)),
        );
        assert_eq!(second_origin, captured_origin);
        assert_eq!(second - captured_origin, Point::from((512.0, 288.0)));
    }
}

#[cfg(feature = "flutter")]
impl WaylandFrontend {
    #[cfg(feature = "xwayland")]
    pub(super) fn invalidate_window_input_routes(&mut self, window: &smithay::desktop::Window) {
        if self
            .client_input_route_cache
            .as_ref()
            .is_some_and(|route| route.window.as_ref() == Some(window))
        {
            self.client_input_route_cache = None;
        }
        if self
            .client_pointer_capture
            .as_ref()
            .is_some_and(|route| route.window.as_ref() == Some(window))
        {
            self.client_pointer_capture = None;
            self.client_pointer_buttons.clear();
            self.client_pointer_presses.clear();
        }
        self.client_touch_routes
            .retain(|_, route| route.window.as_ref() != Some(window));
    }

    fn window_id_for_input_surface(&self, surface: &WlSurface) -> Option<u64> {
        let root = self
            .owning_toplevel_surface(surface)
            .or_else(|| self.layer_root_surface(surface).map(|(root, _)| root))?;
        self.surface_id(&root)
    }

    pub(super) fn pointer_constraint_released_for_surface(&self, surface: &WlSurface) -> bool {
        self.window_id_for_input_surface(surface)
            .is_some_and(|window_id| self.pointer_constraint_escape.suppresses_window(window_id))
    }

    fn resume_pointer_constraint_for_route(&mut self, route: &ClientInputRoute) -> bool {
        self.pointer_constraint_escape
            .resume_window(route.region.window_id)
    }

    fn remember_client_pointer_press(
        &mut self,
        route: &ClientInputRoute,
        serial: Serial,
        button: u32,
    ) {
        self.client_pointer_presses
            .retain(|press| press.button != button && press.serial != serial);
        if self.client_pointer_presses.len() == MAX_CLIENT_POINTER_PRESSES {
            self.client_pointer_presses.remove(0);
        }
        self.client_pointer_presses.push(ClientPointerPress {
            serial,
            button,
            focus: route.focus_at(self.pointer_location),
            location: self.pointer_location,
        });
    }

    fn forget_client_pointer_button(&mut self, button: u32) {
        self.client_pointer_presses
            .retain(|press| press.button != button);
    }

    pub(super) fn take_client_pointer_press(
        &mut self,
        surface: &WlSurface,
        serial: Serial,
    ) -> Option<GrabStartData<RuntimeState>> {
        let index = self.client_pointer_presses.iter().position(|press| {
            press.serial == serial && press.focus.0.id().same_client_as(&surface.id())
        })?;
        let press = self.client_pointer_presses.remove(index);
        Some(GrabStartData {
            focus: Some(press.focus),
            button: press.button,
            location: press.location,
        })
    }
}

#[cfg(feature = "flutter")]
enum InputTarget {
    Flutter,
    Client(ClientInputRoute),
}

#[cfg(feature = "flutter")]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SuperPointerAction {
    Move,
    Resize,
}

#[cfg(feature = "flutter")]
fn super_pointer_action(logo: bool, button: u32) -> Option<SuperPointerAction> {
    if !logo {
        return None;
    }
    match button {
        BTN_LEFT => Some(SuperPointerAction::Move),
        BTN_RIGHT => Some(SuperPointerAction::Resize),
        _ => None,
    }
}

#[cfg(feature = "flutter")]
fn resize_edge_for_geometry(
    pointer: Point<f64, Logical>,
    geometry: Rectangle<i32, Logical>,
) -> xdg_toplevel::ResizeEdge {
    let midpoint_x = f64::from(geometry.loc.x) + f64::from(geometry.size.w) / 2.0;
    let midpoint_y = f64::from(geometry.loc.y) + f64::from(geometry.size.h) / 2.0;
    match (pointer.x < midpoint_x, pointer.y < midpoint_y) {
        (true, true) => xdg_toplevel::ResizeEdge::TopLeft,
        (true, false) => xdg_toplevel::ResizeEdge::BottomLeft,
        (false, true) => xdg_toplevel::ResizeEdge::TopRight,
        (false, false) => xdg_toplevel::ResizeEdge::BottomRight,
    }
}

#[cfg(feature = "flutter")]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum RoutedPointerTarget {
    Flutter,
    Client(u64),
}

#[cfg(feature = "flutter")]
pub(super) struct PointerMotionTarget {
    routed: RoutedPointerTarget,
    focus: Option<(ClientSurface, Point<f64, Logical>)>,
}

#[cfg(feature = "flutter")]
impl PointerMotionTarget {
    pub(super) const FLUTTER: Self = Self {
        routed: RoutedPointerTarget::Flutter,
        focus: None,
    };

    pub(super) fn client(route: &ClientInputRoute, position: Point<f64, Logical>) -> Self {
        Self {
            routed: RoutedPointerTarget::Client(route.region.surface_id),
            focus: Some(route.focus_at(position)),
        }
    }
}

#[derive(Clone, Copy, Debug, Default)]
struct InputDeviceReset {
    keyboard: bool,
    pointer: bool,
    touch: bool,
}

impl InputDeviceReset {
    const ALL: Self = Self {
        keyboard: true,
        pointer: true,
        touch: true,
    };

    const fn any(self) -> bool {
        self.keyboard || self.pointer || self.touch
    }
}

fn retired_key_consumes_transition(
    retired: &mut HashSet<u32>,
    keycode: u32,
    state: KeyState,
) -> bool {
    match state {
        KeyState::Pressed => retired.contains(&keycode),
        KeyState::Released => retired.remove(&keycode),
    }
}

#[cfg(feature = "flutter")]
fn retired_pointer_button_consumes_transition(
    retired: &mut HashSet<u32>,
    button: u32,
    state: ButtonState,
) -> bool {
    match state {
        ButtonState::Pressed => retired.contains(&button),
        ButtonState::Released => retired.remove(&button),
    }
}

fn update_pressed_buttons(buttons: &mut HashSet<u32>, button: u32, state: ButtonState) {
    match state {
        ButtonState::Pressed => {
            buttons.insert(button);
        }
        ButtonState::Released => {
            buttons.remove(&button);
        }
    }
}

#[cfg(feature = "flutter")]
pub(super) fn retire_flutter_generation_keys(
    active: &mut HashSet<u32>,
    retired: &mut HashSet<u32>,
) {
    retired.extend(active.drain());
}

#[cfg(feature = "flutter")]
fn route_shell_key_transition(
    held: &mut HashSet<u32>,
    keycode: u32,
    state: KeyState,
    seat_pressed: bool,
) -> bool {
    match state {
        KeyState::Pressed => !seat_pressed && held.insert(keycode),
        KeyState::Released => held.remove(&keycode),
    }
}

#[cfg(feature = "flutter")]
fn region_accepts_input(region: &InputWindowRegion, position: Point<f64, Logical>) -> bool {
    region.rect.contains(position.x, position.y)
        && region.visible()
        && region.hit_test_enabled()
        && region.window_id == region.object_id
}

#[cfg(feature = "flutter")]
fn software_keyboard_owns_touch(
    layout: Option<&InputLayoutSnapshot>,
    scene_position: Point<f64, Logical>,
) -> bool {
    layout.is_some_and(|layout| {
        layout
            .software_keyboard_regions
            .iter()
            .any(|region| region.contains(scene_position.x, scene_position.y))
    })
}

#[cfg(feature = "flutter")]
impl WaylandFrontend {
    fn client_input_route_is_live(&self, route: &ClientInputRoute) -> bool {
        // Window unmap paths invalidate their cached routes explicitly. The
        // stable surface map is therefore the only lifecycle check needed at
        // input frequency; avoiding Space's element lookup keeps a cache hit
        // independent of the number of windows.
        self.surfaces_by_id
            .get(&route.region.surface_id)
            .is_some_and(|surface| surface == &route.surface)
            && (route.window.is_some()
                || route.layer_root.as_ref().is_some_and(|expected| {
                    self.layer_root_surface(&route.surface)
                        .is_some_and(|(current, _)| current == *expected)
                })
                || self.input_method.owns_popup_surface(&route.surface))
    }

    pub(super) fn input_route(
        &mut self,
        position: Point<f64, Logical>,
    ) -> Option<&ClientInputRoute> {
        let layout = self.input_layout.as_ref()?;
        let scene_position = position - self.atlas_origin;
        if layout.exclusive_shell()
            || layout
                .shell_regions
                .iter()
                .any(|region| region.contains(scene_position.x, scene_position.y))
        {
            return None;
        }

        // Local Flutter windows participate in the same front-to-back window
        // region list as client surfaces. They intentionally have no Smithay
        // input target: once the topmost hit is local, stop traversal so a
        // covered Wayland client cannot receive the event through it.
        if layout
            .windows
            .iter()
            .find(|region| region_accepts_input(region, scene_position))
            .is_some_and(|region| self.local_windows.contains(region.window_id))
        {
            self.client_input_route_cache = None;
            return None;
        }

        // Pointer samples commonly arrive much faster than Flutter layout
        // snapshots. Reuse the fully validated route while it remains the
        // topmost candidate instead of walking Space and the surface tree at
        // input frequency. Regions preceding it still need a cheap geometry
        // check because windows are ordered front-to-back and may overlap.
        let cached_is_valid = self.client_input_route_cache.as_ref().is_some_and(|route| {
            region_accepts_input(&route.region, scene_position)
                && route.focus_at_if_hit(position).is_some()
                && layout
                    .windows
                    .get(..route.layout_index)
                    .is_some_and(|higher_regions| {
                        !higher_regions
                            .iter()
                            .any(|region| region_accepts_input(region, scene_position))
                    })
                && self.client_input_route_is_live(route)
        });
        if cached_is_valid {
            return self.client_input_route_cache.as_ref();
        }

        let route = layout
            .windows
            .iter()
            .enumerate()
            .find_map(|(layout_index, region)| {
                if !region_accepts_input(region, scene_position) {
                    return None;
                }
                let surface = self.surfaces_by_id.get(&region.surface_id).cloned()?;
                if self.input_method.owns_popup_surface(&surface) {
                    return Some(ClientInputRoute {
                        window: None,
                        layer_root: None,
                        surface,
                        region: *region,
                        layout_index,
                        scene_origin: self.atlas_origin,
                    });
                }
                if let Some((layer_root, _)) = self.layer_root_surface(&surface) {
                    if self.surface_id(&layer_root) != Some(region.window_id) {
                        return None;
                    }
                    let route = ClientInputRoute {
                        window: None,
                        layer_root: Some(layer_root),
                        surface,
                        region: *region,
                        layout_index,
                        scene_origin: self.atlas_origin,
                    };
                    return route.focus_at_if_hit(position).is_some().then_some(route);
                }
                let window = self.window_for_id(region.window_id)?;
                let root_surface = self.window_root_surface(&window)?;
                if self.owning_toplevel_surface(&surface).as_ref() != Some(&root_surface) {
                    return None;
                }
                let route = ClientInputRoute {
                    window: Some(window.clone()),
                    layer_root: None,
                    surface,
                    region: *region,
                    layout_index,
                    scene_origin: self.atlas_origin,
                };
                route.focus_at_if_hit(position).is_some().then_some(route)
            });

        if let Some(route) = route {
            self.client_input_route_cache = Some(route);
            return self.client_input_route_cache.as_ref();
        }

        None
    }

    fn local_flutter_window_region_at(
        &self,
        position: Point<f64, Logical>,
    ) -> Option<InputWindowRegion> {
        let layout = self.input_layout.as_ref()?;
        let scene_position = position - self.atlas_origin;
        if layout.exclusive_shell()
            || layout
                .shell_regions
                .iter()
                .any(|region| region.contains(scene_position.x, scene_position.y))
        {
            return None;
        }
        layout
            .windows
            .iter()
            .find(|region| region_accepts_input(region, scene_position))
            .copied()
            .filter(|region| self.local_windows.contains(region.window_id))
    }

    fn touch_window_target_at(&self, position: Point<f64, Logical>) -> Option<TouchWindowTarget> {
        let layout = self.input_layout.as_ref()?;
        let scene_position = position - self.atlas_origin;
        if layout.exclusive_shell()
            || layout
                .shell_regions
                .iter()
                .any(|region| region.contains(scene_position.x, scene_position.y))
        {
            return None;
        }
        let region = layout
            .windows
            .iter()
            .find(|region| region_accepts_input(region, scene_position))?;
        let geometry = if self.local_windows.contains(region.window_id) {
            self.local_flutter_window_geometry(region.window_id)?
        } else {
            let window = self.window_for_id(region.window_id)?;
            let geometry = self.window_geometry_target(&window);
            super::super::wire::WindowGeometry {
                x: f64::from(geometry.loc.x),
                y: f64::from(geometry.loc.y),
                width: f64::from(geometry.size.w),
                height: f64::from(geometry.size.h),
            }
        };
        Some(TouchWindowTarget {
            window_id: region.window_id,
            geometry,
            in_gesture_strip: scene_position.y
                >= region.rect.y + region.rect.height
                    - WINDOW_TOUCH_STRIP_HEIGHT.min(region.rect.height),
            in_move_corner: {
                let corner_width = WINDOW_TOUCH_CORNER_SIZE.min(region.rect.width * 0.5);
                let corner_height = WINDOW_TOUCH_CORNER_SIZE.min(region.rect.height * 0.5);
                let on_horizontal_edge = scene_position.x < region.rect.x + corner_width
                    || scene_position.x >= region.rect.x + region.rect.width - corner_width;
                let on_vertical_edge = scene_position.y < region.rect.y + corner_height
                    || scene_position.y >= region.rect.y + region.rect.height - corner_height;
                on_horizontal_edge && on_vertical_edge
            },
            geometry_locked: region.geometry_locked(),
        })
    }

    fn input_target(&mut self, position: Point<f64, Logical>) -> InputTarget {
        self.input_route(position)
            .cloned()
            .map_or(InputTarget::Flutter, InputTarget::Client)
    }

    pub(super) fn pointer_motion_target(
        &mut self,
        position: Point<f64, Logical>,
    ) -> PointerMotionTarget {
        self.input_route(position)
            .map_or(PointerMotionTarget::FLUTTER, |route| {
                PointerMotionTarget::client(route, position)
            })
    }
}

pub(in super::super) fn init_libinput(
    event_loop: &mut EventLoop<'static, RuntimeState>,
    session: LibSeatSession,
    seat_name: &str,
) -> Result<Libinput, Box<dyn Error>> {
    let mut context =
        Libinput::new_with_udev::<LibinputSessionInterface<LibSeatSession>>(session.into());
    context
        .udev_assign_seat(seat_name)
        .map_err(|()| "libinput could not assign the active seat")?;
    // Libinput's context survives a libseat pause, but its device descriptors
    // do not. Keep one reference beside the event source so the session
    // lifecycle can suspend the old descriptors and reopen them on activation.
    let lifecycle_context = context.clone();
    let backend = LibinputBatchSource::new(LibinputInputBackend::new(context));
    event_loop
        .handle()
        .insert_source(backend, |event, batch, state| {
            match event {
                InputBatchEvent::Input(event) => {
                    batch.flush_clients |= process_input_event(state, event);
                }
                // libinput is independent from the Wayland client socket
                // source. Flush after Smithay has drained the complete batch:
                // clients still observe input immediately, while a burst of
                // samples costs one non-blocking socket flush instead of one
                // syscall per event.
                InputBatchEvent::Complete => {
                    if batch.flush_clients
                        && let Some(frontend) = state.wayland.as_mut()
                        && let Err(error) = frontend.display_handle.flush_clients()
                    {
                        warn!(%error, "could not flush Wayland clients after native input batch");
                    }
                }
            }
        })?;
    Ok(lifecycle_context)
}

impl WaylandFrontend {
    pub(in super::super) fn suspend_input_session(&mut self) {
        self.libinput.suspend();
    }

    pub(in super::super) fn resume_input_session(&mut self) -> Result<(), &'static str> {
        #[cfg(feature = "flutter")]
        self.input_rescan.request();
        self.libinput
            .resume()
            .map_err(|()| "libinput rejected session resume")
    }
}

#[cfg(feature = "flutter")]
fn process_keyboard_transition(
    state: &mut RuntimeState,
    keycode: Keycode,
    key_state: KeyState,
    time: InputTime,
) -> bool {
    state.note_user_activity();
    if intercept_native_escape(state, keycode.raw(), key_state) {
        return true;
    }
    if !state.secure_session_locked() {
        focus_exclusive_layer_for_keyboard_event(state);
    }
    if state.flutter_active {
        return process_flutter_keyboard_transition(state, keycode, key_state, time);
    }
    if state.secure_session_locked() {
        // Native lock state remains authoritative if Flutter is restarting or
        // unavailable. No keyboard source may fall through to a client.
        return true;
    }
    process_wayland_keyboard_transition(state, keycode, key_state, time);
    true
}

fn focus_exclusive_layer_for_keyboard_event(state: &mut RuntimeState) {
    let Some((keyboard, focus)) = state.wayland.as_ref().and_then(|frontend| {
        if frontend.text_input.shell_captures_keyboard() {
            return None;
        }
        Some((
            frontend.seat.get_keyboard()?,
            frontend.exclusive_layer_keyboard_focus()?,
        ))
    }) else {
        return;
    };
    if keyboard.current_focus().as_ref() != Some(&focus) {
        super::focus::request_keyboard_focus(
            state,
            &keyboard,
            Some(focus),
            SERIAL_COUNTER.next_serial(),
        );
    }
}

fn configure_touchpad_device(
    device: &mut LibinputDevice,
    settings: &TouchpadSettings,
) -> Result<(), String> {
    let finger_count = device.config_tap_finger_count();
    if finger_count > 0 {
        if let Err(error) = device.config_tap_set_button_map(TapButtonMap::LeftRightMiddle) {
            // Keep tap-to-click usable if a device rejects explicit remapping;
            // libinput's normal default is the same left/right/middle order.
            warn!(
                ?error,
                device = %device.name(),
                "could not configure multi-finger tap button mapping"
            );
        }

        device
            .config_tap_set_enabled(settings.tap_to_click_enabled)
            .map_err(|error| {
                format!(
                    "could not set tap-to-click on {} to {}: {error:?}",
                    device.name(),
                    settings.tap_to_click_enabled
                )
            })?;
    }

    let natural_scroll_supported = device.config_scroll_has_natural_scroll();
    if natural_scroll_supported {
        device
            .config_scroll_set_natural_scroll_enabled(settings.natural_scroll_enabled)
            .map_err(|error| {
                format!(
                    "could not set natural scrolling on {} to {}: {error:?}",
                    device.name(),
                    settings.natural_scroll_enabled
                )
            })?;
    }

    info!(
        device = %device.name(),
        finger_count,
        tap_to_click_enabled = settings.tap_to_click_enabled,
        natural_scroll_enabled = settings.natural_scroll_enabled,
        natural_scroll_supported,
        two_finger_right_click = finger_count >= 2,
        "configured touchpad"
    );
    Ok(())
}

fn is_touchpad_device(device: &LibinputDevice) -> bool {
    // SAFETY: this device came from the same udev-backed libinput context used
    // to construct the event source, as required by input::Device::udev_device.
    let udev_marks_touchpad = unsafe { device.udev_device() }.and_then(|device| {
        device
            .property_value("ID_INPUT_TOUCHPAD")
            .map(|value| value == OsStr::new("1"))
    });
    udev_marks_touchpad.unwrap_or_else(|| device.config_tap_finger_count() > 0)
}

fn is_mouse_device(device: &LibinputDevice) -> bool {
    // Do not infer this from pointer capability alone: touchpads expose the
    // same capability and have an independently configurable input model.
    let udev_marks_mouse = unsafe { device.udev_device() }.and_then(|device| {
        device
            .property_value("ID_INPUT_MOUSE")
            .map(|value| value == OsStr::new("1"))
    });
    udev_marks_mouse.unwrap_or(false) && device.config_accel_is_available()
}

fn configure_mouse_device(
    device: &mut LibinputDevice,
    settings: &MouseSettings,
) -> Result<(), String> {
    device
        .config_accel_set_speed(settings.speed)
        .map_err(|error| {
            format!(
                "could not set pointer speed on {} to {}: {error:?}",
                device.name(),
                settings.speed
            )
        })?;
    let profile = if settings.acceleration_enabled {
        AccelProfile::Adaptive
    } else {
        AccelProfile::Flat
    };
    device.config_accel_set_profile(profile).map_err(|error| {
        format!(
            "could not set pointer acceleration on {} to {profile:?}: {error:?}",
            device.name()
        )
    })?;
    info!(
        device = %device.name(),
        speed = settings.speed,
        ?profile,
        "configured mouse pointer speed and acceleration"
    );
    Ok(())
}

#[cfg(feature = "flutter")]
pub(in super::super) fn install_mouse_settings(
    state: &mut RuntimeState,
    settings: &MouseSettings,
) -> Result<(), String> {
    for device in state.input_devices.mice.values_mut() {
        configure_mouse_device(device, settings)?;
    }
    Ok(())
}

#[cfg(feature = "flutter")]
pub(in super::super) fn install_touchpad_settings(
    state: &mut RuntimeState,
    settings: &TouchpadSettings,
) -> Result<(), String> {
    for device in state.input_devices.touchpads.values_mut() {
        configure_touchpad_device(device, settings)?;
    }
    Ok(())
}

#[cfg(feature = "flutter")]
fn process_touchpad_gesture_event(
    state: &mut RuntimeState,
    event: &InputEvent<LibinputInputBackend>,
) -> Option<bool> {
    if !state.flutter_active || state.secure_session_locked() {
        if matches!(
            event,
            InputEvent::GestureSwipeBegin { .. }
                | InputEvent::GestureSwipeUpdate { .. }
                | InputEvent::GestureSwipeEnd { .. }
        ) {
            if state.touchpad_gestures.reset() {
                finish_horizontal_layout_scroll(state, true, None);
            }
            state.native_escape_shortcut.cancel_gestures();
            return Some(false);
        }
        return None;
    }

    let gesture_event = match event {
        InputEvent::GestureSwipeBegin { event } => {
            let device = event.device();
            let horizontal_scroll_directions = swipe_scroll_directions(state, None);
            state.touchpad_gestures.begin_swipe(
                device.sysname(),
                event.fingers(),
                horizontal_scroll_directions,
            );
            None
        }
        InputEvent::GestureSwipeUpdate { event } => {
            let device = event.device();
            state.touchpad_gestures.update_swipe(
                device.sysname(),
                event.delta_x(),
                event.delta_y(),
                event.time().micros(),
            )
        }
        InputEvent::GestureSwipeEnd { event } => {
            let device = event.device();
            state.touchpad_gestures.end_swipe(
                device.sysname(),
                event.cancelled(),
                event.time().micros(),
            )
        }
        _ => return None,
    };

    Some(gesture_event.is_some_and(|event| dispatch_swipe_gesture(state, event, None)))
}

#[cfg(feature = "flutter")]
fn swipe_scroll_directions(
    state: &RuntimeState,
    position: Option<Point<f64, Logical>>,
) -> super::super::touchpad_gestures::HorizontalScrollDirections {
    use super::super::touchpad_gestures::HorizontalScrollDirections;
    let scrolling_layout = state
        .wayland
        .as_ref()
        .is_some_and(|frontend| frontend.can_scroll_layout_horizontally_at(position));
    if !scrolling_layout {
        return HorizontalScrollDirections::default();
    }
    HorizontalScrollDirections {
        left: state.native_escape_shortcut.gesture_invokes(
            ShortcutGesture::ThreeFingerSwipeLeft,
            ShortcutAction::WindowSwitcher,
        ),
        right: state.native_escape_shortcut.gesture_invokes(
            ShortcutGesture::ThreeFingerSwipeRight,
            ShortcutAction::WindowSwitcher,
        ),
    }
}

#[cfg(feature = "flutter")]
pub(super) fn dispatch_swipe_gesture(
    state: &mut RuntimeState,
    gesture_event: super::super::touchpad_gestures::TouchpadGestureEvent,
    position: Option<Point<f64, Logical>>,
) -> bool {
    use super::super::touchpad_gestures::TouchpadGestureEvent;

    if !state.flutter_active || state.secure_session_locked() {
        if matches!(
            gesture_event,
            TouchpadGestureEvent::HorizontalScrollEnd { .. }
        ) {
            finish_horizontal_layout_scroll(state, true, None);
        }
        state.native_escape_shortcut.cancel_gestures();
        return false;
    }

    match gesture_event {
        TouchpadGestureEvent::HorizontalScrollBegin { delta_x } => {
            let handled = update_horizontal_layout_scroll(state, delta_x);
            if handled {
                info!("began continuous scrolling-layout gesture");
            }
            return handled;
        }
        TouchpadGestureEvent::HorizontalScrollUpdate { delta_x } => {
            return update_horizontal_layout_scroll(state, delta_x);
        }
        TouchpadGestureEvent::HorizontalScrollEnd {
            cancelled,
            projected_delta_x,
        } => {
            return finish_horizontal_layout_scroll(state, cancelled, Some(projected_delta_x));
        }
        TouchpadGestureEvent::Trigger(_)
        | TouchpadGestureEvent::Repeat(_)
        | TouchpadGestureEvent::End(_) => {}
    }

    let (gesture, disposition) = match gesture_event {
        TouchpadGestureEvent::Trigger(gesture) => (
            gesture,
            state.native_escape_shortcut.observe_gesture(gesture),
        ),
        TouchpadGestureEvent::Repeat(gesture) => (
            gesture,
            state.native_escape_shortcut.observe_gesture_repeat(gesture),
        ),
        TouchpadGestureEvent::End(gesture) => {
            (gesture, state.native_escape_shortcut.end_gesture(gesture))
        }
        TouchpadGestureEvent::HorizontalScrollBegin { .. }
        | TouchpadGestureEvent::HorizontalScrollUpdate { .. }
        | TouchpadGestureEvent::HorizontalScrollEnd { .. } => {
            unreachable!("continuous scroll events return before shortcut dispatch")
        }
    };
    let handled = execute_shortcut_disposition_at(state, disposition, position);
    if handled {
        info!(
            ?gesture,
            "recognized configured compositor shortcut gesture"
        );
    }
    handled
}

#[cfg(feature = "flutter")]
fn update_horizontal_layout_scroll(state: &mut RuntimeState, delta_x: f64) -> bool {
    let Some(frame) = state
        .wayland
        .as_mut()
        .and_then(|frontend| frontend.scroll_layout_horizontally(delta_x))
    else {
        return false;
    };
    let changed = !frame.placements.is_empty();
    for (window, geometry) in frame.placements {
        super::window_management::queue_transient_window_placement_for_monitor(
            state,
            &window,
            geometry,
            frame.monitor_geometry,
            WindowPlacementPhase::Update,
            WindowPlacementChange::Move,
        );
    }
    if changed {
        state.scene_sync.mark_dirty();
    }
    changed
}

#[cfg(feature = "flutter")]
fn update_mouse_wheel_layout_scroll(state: &mut RuntimeState, vertical_delta: f64) -> bool {
    let Some(frame) = state
        .wayland
        .as_mut()
        .and_then(|frontend| frontend.scroll_layout_with_mouse_wheel(vertical_delta))
    else {
        return false;
    };
    let changed = !frame.placements.is_empty();
    for (window, geometry) in frame.placements {
        super::window_management::queue_transient_window_placement_for_monitor(
            state,
            &window,
            geometry,
            frame.monitor_geometry,
            WindowPlacementPhase::Update,
            WindowPlacementChange::Move,
        );
    }
    if changed {
        state.scene_sync.mark_dirty();
    }
    changed
}

#[cfg(feature = "flutter")]
fn finish_horizontal_layout_scroll(
    state: &mut RuntimeState,
    cancelled: bool,
    projected_delta_x: Option<f64>,
) -> bool {
    let Some(frame) = state.wayland.as_mut().and_then(|frontend| {
        frontend.finish_layout_horizontal_scroll(cancelled, projected_delta_x)
    }) else {
        return false;
    };
    let selected = frame.selected.clone();
    let changed = !frame.placements.is_empty();
    for (window, geometry) in frame.placements {
        super::window_management::queue_transient_window_placement_for_monitor(
            state,
            &window,
            geometry,
            frame.monitor_geometry,
            WindowPlacementPhase::End,
            WindowPlacementChange::Move,
        );
    }
    if !cancelled && let Some(selected) = selected {
        super::window_management::activate_window(state, &selected, SERIAL_COUNTER.next_serial());
    }
    if changed {
        state.scene_sync.mark_dirty();
    }
    changed
}

fn process_input_event(
    state: &mut RuntimeState,
    mut event: InputEvent<LibinputInputBackend>,
) -> bool {
    let mut tablet_clients_changed = false;
    #[cfg(feature = "flutter")]
    let pointer_kinds = state.input_devices.pointer_kinds();
    if let InputEvent::DeviceAdded { device } = &mut event {
        tablet_clients_changed = tablet::register_device(state, device);
        #[cfg(feature = "flutter")]
        if Device::has_capability(device, DeviceCapability::Touch) {
            state
                .input_devices
                .touchscreens
                .insert(device.sysname().to_owned(), device.clone());
        }
        if Device::has_capability(device, DeviceCapability::Keyboard) {
            if let Some(led_state) = state
                .wayland
                .as_ref()
                .and_then(|frontend| frontend.seat.get_keyboard())
                .map(|keyboard| keyboard.led_state())
            {
                device.led_update(led_state.into());
            }
            state
                .input_devices
                .keyboards
                .insert(device.sysname().to_owned(), device.clone());
        }
        let touchpad = is_touchpad_device(device);
        if touchpad {
            let settings = state
                .wayland
                .as_ref()
                .map(|frontend| frontend.settings.touchpad().clone())
                .unwrap_or_default();
            // libinput recognizes taps and emits ordinary BTN_LEFT transitions.
            // Keeping recognition at the device boundary lets synthesized
            // clicks use the same Flutter/Wayland focus and grab path as
            // physical buttons.
            if let Err(error) = configure_touchpad_device(device, &settings) {
                warn!(%error, "could not apply persisted touchpad settings");
            }
            #[cfg(feature = "flutter")]
            state
                .input_devices
                .touchpads
                .insert(device.sysname().to_owned(), device.clone());
        }
        let mouse = is_mouse_device(device);
        if mouse {
            let settings = state
                .wayland
                .as_ref()
                .map(|frontend| frontend.settings.mouse().clone())
                .unwrap_or_default();
            if let Err(error) = configure_mouse_device(device, &settings) {
                warn!(%error, "could not apply persisted mouse settings");
            }
            #[cfg(feature = "flutter")]
            state
                .input_devices
                .mice
                .insert(device.sysname().to_owned(), device.clone());
        }
        #[cfg(feature = "flutter")]
        {
            state.input_device_capabilities_changed |=
                state.input_devices.pointer_kinds() != pointer_kinds;
        }
    }

    if let InputEvent::DeviceRemoved { device } = &event {
        #[cfg(feature = "flutter")]
        state.power_button.remove_device(device.sysname());
        tablet_clients_changed = tablet::unregister_device(state, device);
        state.input_devices.remove(device.sysname());
        #[cfg(feature = "flutter")]
        {
            state.screen_off_touch.remove_device(device.sysname());
            state.input_device_capabilities_changed |=
                state.input_devices.pointer_kinds() != pointer_kinds;
        }
        let reset = InputDeviceReset {
            keyboard: Device::has_capability(device, DeviceCapability::Keyboard),
            pointer: Device::has_capability(device, DeviceCapability::Pointer),
            touch: Device::has_capability(device, DeviceCapability::Touch),
        };
        if reset.any() {
            reset_input_devices(state, reset);
        }
        return reset.any() || tablet_clients_changed;
    }

    #[cfg(feature = "flutter")]
    if let InputEvent::Keyboard {
        event: key_event, ..
    } = &event
    {
        // KEY_POWER (116) plus the XKB offset. Handle the entire physical key
        // sequence before note_user_activity: waking first would invert an
        // off-to-on toggle, and routing the release would undo on-to-off.
        // Power plus Volume Down is the mobile shell's screenshot.
        let chords = state
            .wayland
            .as_ref()
            .is_some_and(|frontend| frontend.mobile_shell);
        if key_event.key_code().raw() == 116 + 8 {
            state.power_button.note_key(
                key_event.device().sysname(),
                key_event.state() == KeyState::Pressed,
                chords,
            );
            return false;
        }
        // KEY_VOLUMEDOWN (114).
        if key_event.key_code().raw() == 114 + 8 {
            use super::super::idle_policy::VolumeDownRoute;
            let keycode = key_event.key_code();
            match state
                .power_button
                .note_volume_down(key_event.state() == KeyState::Pressed, chords)
            {
                VolumeDownRoute::Deliver => {}
                VolumeDownRoute::Take => return false,
                VolumeDownRoute::HoldBack => {
                    hold_back_volume_down(state, keycode);
                    return false;
                }
                VolumeDownRoute::DeliverHeldPress => {
                    let time = key_event.time();
                    let pressed =
                        process_keyboard_transition(state, keycode, KeyState::Pressed, time);
                    return process_keyboard_transition(state, keycode, KeyState::Released, time)
                        || pressed;
                }
            }
        }
        return process_keyboard_transition(
            state,
            key_event.key_code(),
            key_event.state(),
            key_event.time(),
        );
    }

    #[cfg(feature = "flutter")]
    {
        use crate::screen_off_touch::Event as TouchPowerEvent;
        let touch = match &event {
            InputEvent::TouchDown { event, .. } => Some((
                event.device(),
                TouchPowerEvent::Down(i32::from(event.slot())),
            )),
            InputEvent::TouchMotion { event, .. } => Some((
                event.device(),
                TouchPowerEvent::Motion(i32::from(event.slot())),
            )),
            InputEvent::TouchUp { event, .. } => {
                Some((event.device(), TouchPowerEvent::Up(i32::from(event.slot()))))
            }
            InputEvent::TouchCancel { event, .. } => {
                Some((event.device(), TouchPowerEvent::Cancel))
            }
            InputEvent::TouchFrame { event, .. } => Some((event.device(), TouchPowerEvent::Frame)),
            _ => None,
        };
        if let Some((device, touch)) = touch {
            let powered = state
                .wayland
                .as_ref()
                .and_then(|frontend| touch_output_for_device(frontend, &device))
                .is_none_or(|output| {
                    state
                        .output_power_requests
                        .get(&output.id)
                        .copied()
                        .unwrap_or(output.powered)
                });
            // The root fingerprint listener has its own read-only evdev stream.
            // Only its bounded presentation or an explicit wake gesture/button
            // may wake this panel; raw DOWN/MOTION must not expose the lock UI.
            if state
                .screen_off_touch
                .suppress(device.sysname(), touch, powered)
            {
                return false;
            }
        }
    }

    #[cfg(feature = "flutter")]
    if state.fingerprint.active()
        && matches!(
            &event,
            InputEvent::TouchDown { .. }
                | InputEvent::TouchMotion { .. }
                | InputEvent::TouchUp { .. }
                | InputEvent::TouchCancel { .. }
                | InputEvent::TouchFrame { .. }
        )
    {
        return false;
    }

    // libinput's own event type has an inherent `switch()`; ask Smithay's.
    #[cfg(feature = "flutter")]
    if let InputEvent::SwitchToggle { event } = &event
        && SwitchToggleEvent::switch(event) == Some(Switch::Lid)
    {
        let closed = SwitchToggleEvent::state(event) == SwitchState::On;
        state.lid.note_toggle(closed);
        if !closed {
            // Opening the lid asks to see the panel, as a key press would.
            state.note_user_activity();
        }
        return false;
    }

    #[cfg(feature = "flutter")]
    if !matches!(&event, InputEvent::DeviceAdded { .. }) {
        state.note_user_activity();
    }

    #[cfg(feature = "flutter")]
    if let Some(flush_clients) = process_touchpad_gesture_event(state, &event) {
        return flush_clients;
    }

    if tablet::process_event(state, &event) {
        return true;
    }

    if tablet_clients_changed {
        return true;
    }

    #[cfg(not(feature = "flutter"))]
    match &event {
        InputEvent::Keyboard {
            event: key_event, ..
        } if intercept_native_escape(state, key_event.key_code().raw(), key_event.state()) => {
            // Native window actions may emit configure/focus messages. This
            // edge is infrequent, so retain the conservative immediate flush.
            return true;
        }
        _ => {}
    }

    #[cfg(feature = "flutter")]
    if state.flutter_active {
        return process_flutter_input_event(state, event);
    }

    #[cfg(feature = "flutter")]
    if state.secure_session_locked() {
        // Native lock state remains authoritative if Flutter is restarting or
        // unavailable. No physical input may fall through to a client.
        return true;
    }

    process_wayland_input_event(state, event);
    true
}

pub(in super::super) fn reset_all_input_devices(state: &mut RuntimeState) {
    #[cfg(feature = "flutter")]
    {
        state.power_button = Default::default();
    }
    reset_input_devices(state, InputDeviceReset::ALL);
}

#[cfg(feature = "flutter")]
pub(in super::super) fn install_keyboard_settings(
    state: &mut RuntimeState,
    settings: &KeyboardSettings,
) -> Result<Vec<String>, Box<dyn Error>> {
    let layout_names = settings.compiled_layout_names()?;
    let names = settings.xkb_names();
    // Retire every key against the old map before replacing it. A later
    // physical release is consumed, so neither Flutter nor a client can keep
    // a modifier logically held across the keymap boundary.
    reset_input_devices(
        state,
        InputDeviceReset {
            keyboard: true,
            pointer: false,
            touch: false,
        },
    );
    let keyboard = state
        .wayland
        .as_ref()
        .and_then(|frontend| frontend.seat.get_keyboard())
        .ok_or("seat has no keyboard")?;
    keyboard.set_xkb_config(
        state,
        XkbConfig {
            rules: "evdev",
            model: "pc105",
            layout: &names.layout,
            variant: &names.variant,
            options: Some(names.options),
        },
    )?;
    keyboard.change_repeat_info(
        i32::try_from(settings.repeat_rate_hz)?,
        i32::try_from(settings.repeat_delay_ms)?,
    );
    {
        let frontend = state.frontend_mut();
        #[cfg(feature = "flutter")]
        if let Some(compose) = frontend.flutter_compose.as_mut() {
            compose.reset();
        }
        frontend.keyboard_layout_names = layout_names.clone();
        frontend.active_keyboard_layout = 0;
        frontend.keyboard_configuration_changed = true;
    }
    super::input_method::refresh_keyboard_grab(
        state,
        i32::try_from(settings.repeat_rate_hz)?,
        i32::try_from(settings.repeat_delay_ms)?,
    );
    Ok(layout_names)
}

fn reset_input_devices(state: &mut RuntimeState, reset: InputDeviceReset) {
    // End direct-touch shortcut lifecycles before a seat-wide reset clears
    // their shortcut owner; otherwise the window switcher cannot finish.
    #[cfg(feature = "flutter")]
    if reset.touch {
        super::input_deck::cancel_screen_gestures(state);
        let actions = state
            .wayland
            .as_mut()
            .map(|frontend| frontend.touch_gestures.cancel_all())
            .unwrap_or_default();
        touch_gestures::apply_actions(state, actions);
    }
    if reset.keyboard {
        state.native_escape_shortcut.reset();
        #[cfg(feature = "flutter")]
        cancel_flutter_repeat(state);
    }
    #[cfg(feature = "flutter")]
    if reset.pointer {
        if state.touchpad_gestures.reset() {
            finish_horizontal_layout_scroll(state, true, None);
        }
        state.native_escape_shortcut.cancel_gestures();
    }
    #[cfg(feature = "flutter")]
    if state.flutter_active {
        state
            .flutter_input
            .cancel_device_lifecycles(reset.pointer, reset.touch);
    }
    let Some(frontend) = state.wayland.as_mut() else {
        return;
    };
    let time = InputTime::now();
    let pointer = reset
        .pointer
        .then(|| frontend.seat.get_pointer().expect("seat has no pointer"));
    let touch = reset
        .touch
        .then(|| frontend.seat.get_touch().expect("seat has no touch"));
    let keyboard = reset
        .keyboard
        .then(|| frontend.seat.get_keyboard().expect("seat has no keyboard"));
    let mut pointer_buttons = if reset.pointer {
        let mut buttons = std::mem::take(&mut frontend.wayland_pointer_buttons)
            .into_iter()
            .collect::<Vec<_>>();
        buttons.sort_unstable();
        #[cfg(feature = "flutter")]
        {
            frontend.client_pointer_capture = None;
            frontend.pointer_constraint_escape.reset();
            frontend.client_pointer_buttons.clear();
            frontend.client_pointer_presses.clear();
            frontend.flutter_pointer_press = None;
            frontend.set_clipboard_drag_active(false);
            frontend.retired_pointer_buttons.clear();
            frontend.set_routed_pointer_target(RoutedPointerTarget::Flutter);
        }
        buttons
    } else {
        Vec::new()
    };
    #[cfg(feature = "flutter")]
    let cancel_client_touch = reset.touch
        && (!frontend.client_touch_routes.is_empty()
            || touch.as_ref().is_some_and(|touch| touch.is_grabbed()));
    #[cfg(not(feature = "flutter"))]
    let cancel_client_touch = reset.touch;
    if reset.touch {
        #[cfg(feature = "flutter")]
        {
            frontend.flutter_touch_slots.clear();
            frontend.client_touch_routes.clear();
            frontend.client_touch_frame_pending = false;
        }
    }

    #[cfg(feature = "flutter")]
    if reset.keyboard {
        frontend.shell_keyboard_keys.clear();
    }
    let previously_retired_keys = if reset.keyboard {
        frontend.retired_keyboard_keys.clone()
    } else {
        HashSet::new()
    };
    if let Some(keyboard) = keyboard.as_ref() {
        for keycode in keyboard.pressed_keys() {
            frontend.retired_keyboard_keys.insert(keycode.raw());
        }
    }
    if let Some(pointer) = pointer {
        let had_buttons = !pointer_buttons.is_empty();
        let had_grab = pointer.is_grabbed();
        for button in pointer_buttons.drain(..) {
            pointer.button(
                state,
                &ButtonEvent {
                    button,
                    state: ButtonState::Released,
                    serial: SERIAL_COUNTER.next_serial(),
                    time,
                },
            );
        }
        if pointer.is_grabbed() {
            pointer.unset_grab(state, SERIAL_COUNTER.next_serial(), time);
        }
        if had_buttons || had_grab {
            pointer.frame(state);
        }
    }

    if cancel_client_touch && let Some(touch) = touch {
        touch.cancel(state);
        if touch.is_grabbed() {
            touch.unset_grab(state);
        }
    }

    if let Some(keyboard) = keyboard {
        let mut pressed_keys = keyboard.pressed_keys().into_iter().collect::<Vec<_>>();
        pressed_keys.sort_unstable_by_key(|keycode| keycode.raw());
        for keycode in pressed_keys {
            let raw_keycode = keycode.raw();
            let was_retired = previously_retired_keys.contains(&raw_keycode);
            super::input_method::input_key(
                state,
                &keyboard,
                keycode,
                KeyState::Released,
                SERIAL_COUNTER.next_serial(),
                time,
                move |_, _, _| {
                    if was_retired {
                        FilterResult::Intercept(())
                    } else {
                        FilterResult::Forward
                    }
                },
            );
        }
        if keyboard.is_grabbed() {
            keyboard.unset_grab(state);
        }
    }
    state.scene_sync.mark_dirty();
}

#[cfg(feature = "flutter")]
fn flutter_unicode_for_keysym(
    compose: Option<&mut xkb::compose::State>,
    keysym: xkb::Keysym,
) -> u32 {
    let direct = || keysym.key_char().map(u32::from).unwrap_or(0);
    let Some(compose) = compose else {
        return direct();
    };
    match compose.feed(keysym) {
        xkb::compose::FeedResult::Ignored => direct(),
        xkb::compose::FeedResult::Accepted => match compose.status() {
            xkb::compose::Status::Nothing => direct(),
            xkb::compose::Status::Composing | xkb::compose::Status::Cancelled => 0,
            xkb::compose::Status::Composed => compose
                .utf8()
                .as_deref()
                .and_then(single_unicode_scalar)
                .or_else(|| {
                    compose
                        .keysym()
                        .and_then(|symbol| symbol.key_char().map(u32::from))
                })
                .unwrap_or(0),
        },
    }
}

#[cfg(feature = "flutter")]
fn single_unicode_scalar(value: &str) -> Option<u32> {
    let mut characters = value.chars();
    let character = characters.next()?;
    characters.next().is_none().then(|| u32::from(character))
}

#[cfg(feature = "flutter")]
fn flutter_key_repeats(key: &smithay::input::keyboard::KeysymHandle<'_>) -> bool {
    let xkb = key.xkb().lock().unwrap();
    // SAFETY: the keymap reference is used only while the owning XKB mutex is
    // held and is not retained beyond this call.
    unsafe { xkb.keymap() }.key_repeats(key.raw_code())
}

#[cfg(feature = "flutter")]
fn flutter_modifiers_for_key(
    key: &smithay::input::keyboard::KeysymHandle<'_>,
) -> smithay::input::keyboard::ModifiersState {
    let xkb = key.xkb().lock().unwrap();
    let mut modifiers = smithay::input::keyboard::ModifiersState::default();
    // SAFETY: the state reference remains inside the XKB mutex guard.
    modifiers.update_with(unsafe { xkb.state() });
    modifiers
}

/// Deliver a seat keyboard event whose real focus target is the compositor's
/// Flutter shell.
///
/// This is the sole Flutter hardware-key delivery point. Physical keys and
/// keys returned by an input method both arrive here through Smithay's seat.
#[cfg(feature = "flutter")]
pub(super) fn dispatch_focused_flutter_key(
    state: &mut RuntimeState,
    key: smithay::input::keyboard::KeysymHandle<'_>,
    key_state: KeyState,
) {
    let raw_keycode = key.raw_code().raw();
    let (dispatch, input_method_owns_repeat) = {
        let frontend = state.frontend_mut();
        let dispatch = match key_state {
            KeyState::Pressed => {
                frontend.flutter_keyboard_keys.insert(raw_keycode);
                true
            }
            KeyState::Released => frontend.flutter_keyboard_keys.remove(&raw_keycode),
        };
        (dispatch, frontend.input_method.flutter_editor_active())
    };
    if !dispatch || !state.flutter_active {
        return;
    }

    let repeatable = matches!(key_state, KeyState::Pressed) && flutter_key_repeats(&key);
    let unicode = if matches!(key_state, KeyState::Pressed) {
        let frontend = state.frontend_mut();
        flutter_unicode_for_keysym(frontend.flutter_compose.as_mut(), key.modified_sym())
    } else {
        key.modified_sym().key_char().map(u32::from).unwrap_or(0)
    };
    let modifiers = flutter_modifiers_for_key(&key);
    state
        .flutter_input
        .handle_keyboard_with_unicode(raw_keycode, key_state, &modifiers, unicode);
    if repeatable && !input_method_owns_repeat {
        start_flutter_repeat(state, raw_keycode);
    } else if matches!(key_state, KeyState::Released)
        && state
            .wayland
            .as_ref()
            .is_some_and(|frontend| frontend.flutter_repeat_key == Some(raw_keycode))
    {
        cancel_flutter_repeat(state);
    }
}

#[cfg(feature = "flutter")]
pub(super) fn leave_focused_flutter_keyboard(state: &mut RuntimeState) {
    cancel_flutter_repeat(state);
    let mut keys = {
        let frontend = state.frontend_mut();
        std::mem::take(&mut frontend.flutter_keyboard_keys)
            .into_iter()
            .collect::<Vec<_>>()
    };
    keys.sort_unstable();
    let modifiers = smithay::input::keyboard::ModifiersState::default();
    for keycode in keys {
        state.flutter_input.handle_keyboard_with_unicode(
            keycode,
            KeyState::Released,
            &modifiers,
            0,
        );
    }
}

/// How long a Volume Down press waits for Power to join it as a
/// screenshot before it changes the volume.
#[cfg(feature = "flutter")]
const SCREENSHOT_CHORD_WINDOW: std::time::Duration = std::time::Duration::from_millis(150);

#[cfg(feature = "flutter")]
fn hold_back_volume_down(state: &mut RuntimeState, keycode: Keycode) {
    let Some(frontend) = state.wayland.as_ref() else {
        return;
    };
    let loop_handle = frontend.loop_handle.clone();
    let scheduled = loop_handle.insert_source(
        Timer::from_duration(SCREENSHOT_CHORD_WINDOW),
        move |_, _, state| {
            if state.power_button.take_held_volume_down()
                && process_keyboard_transition(state, keycode, KeyState::Pressed, InputTime::now())
                && let Some(frontend) = state.wayland.as_mut()
                && let Err(error) = frontend.display_handle.flush_clients()
            {
                warn!(%error, "could not flush Wayland clients after Volume Down");
            }
            TimeoutAction::Drop
        },
    );
    if let Err(error) = scheduled {
        warn!(%error, "could not hold Volume Down back for the screenshot chord");
        if state.power_button.take_held_volume_down() {
            process_keyboard_transition(state, keycode, KeyState::Pressed, InputTime::now());
        }
    }
}

#[cfg(feature = "flutter")]
fn cancel_flutter_repeat(state: &mut RuntimeState) {
    let Some(frontend) = state.wayland.as_mut() else {
        return;
    };
    frontend.flutter_repeat_generation = frontend.flutter_repeat_generation.wrapping_add(1);
    frontend.flutter_repeat_key = None;
    if let Some(token) = frontend.flutter_repeat_token.take() {
        frontend.loop_handle.remove(token);
    }
}

#[cfg(feature = "flutter")]
fn start_flutter_repeat(state: &mut RuntimeState, keycode: u32) {
    cancel_flutter_repeat(state);
    let Some(frontend) = state.wayland.as_mut() else {
        return;
    };
    let rate = frontend.settings.keyboard().repeat_rate_hz;
    if rate == 0 {
        return;
    }
    let delay =
        std::time::Duration::from_millis(u64::from(frontend.settings.keyboard().repeat_delay_ms));
    let interval = std::time::Duration::from_secs_f64(1.0 / f64::from(rate));
    frontend.flutter_repeat_generation = frontend.flutter_repeat_generation.wrapping_add(1);
    let generation = frontend.flutter_repeat_generation;
    frontend.flutter_repeat_key = Some(keycode);
    let loop_handle = frontend.loop_handle.clone();
    match loop_handle.insert_source(Timer::from_duration(delay), move |_, _, state| {
        let current = state.wayland.as_ref().is_some_and(|frontend| {
            frontend.flutter_repeat_generation == generation
                && frontend.flutter_repeat_key == Some(keycode)
        });
        if !current || !dispatch_flutter_repeat(state, keycode) {
            return TimeoutAction::Drop;
        }
        TimeoutAction::ToDuration(interval)
    }) {
        Ok(token) => {
            state.frontend_mut().flutter_repeat_token = Some(token);
        }
        Err(error) => {
            warn!(%error, "could not schedule Flutter keyboard repeat");
            cancel_flutter_repeat(state);
        }
    }
}

#[cfg(feature = "flutter")]
fn dispatch_flutter_repeat(state: &mut RuntimeState, keycode: u32) -> bool {
    if !state.flutter_active {
        return false;
    }
    let Some(keyboard) = state
        .wayland
        .as_ref()
        .and_then(|frontend| frontend.seat.get_keyboard())
    else {
        return false;
    };
    let owned = state
        .wayland
        .as_ref()
        .is_some_and(|frontend| frontend.flutter_keyboard_keys.contains(&keycode));
    if !owned {
        return false;
    }
    let time = InputTime::now();
    super::input_method::forward_key(
        state,
        &keyboard,
        Keycode::new(keycode),
        KeyState::Pressed,
        SERIAL_COUNTER.next_serial(),
        time,
        false,
    );
    true
}

#[cfg(feature = "flutter")]
fn start_system_control_repeat(state: &mut RuntimeState, keycode: u32) {
    cancel_flutter_repeat(state);
    let Some(frontend) = state.wayland.as_mut() else {
        return;
    };
    let rate = frontend.settings.keyboard().repeat_rate_hz;
    if rate == 0 {
        return;
    }
    let delay =
        std::time::Duration::from_millis(u64::from(frontend.settings.keyboard().repeat_delay_ms));
    let interval = std::time::Duration::from_secs_f64(1.0 / f64::from(rate));
    frontend.flutter_repeat_generation = frontend.flutter_repeat_generation.wrapping_add(1);
    let generation = frontend.flutter_repeat_generation;
    frontend.flutter_repeat_key = Some(keycode);
    let loop_handle = frontend.loop_handle.clone();
    match loop_handle.insert_source(Timer::from_duration(delay), move |_, _, state| {
        let current = state.wayland.as_ref().is_some_and(|frontend| {
            frontend.flutter_repeat_generation == generation
                && frontend.flutter_repeat_key == Some(keycode)
        });
        if !current || !dispatch_system_control_repeat(state, keycode) {
            return TimeoutAction::Drop;
        }
        TimeoutAction::ToDuration(interval)
    }) {
        Ok(token) => {
            state.frontend_mut().flutter_repeat_token = Some(token);
        }
        Err(error) => {
            warn!(%error, "could not schedule system-control keyboard repeat");
            cancel_flutter_repeat(state);
        }
    }
}

#[cfg(feature = "flutter")]
fn dispatch_system_control_repeat(state: &mut RuntimeState, xkb_keycode: u32) -> bool {
    if !state.flutter_active || state.secure_session_locked() {
        return false;
    }
    let Some(evdev_keycode) = xkb_keycode.checked_sub(8) else {
        return false;
    };
    let disposition = state.native_escape_shortcut.observe(evdev_keycode, true);
    if !disposition.repeats_with_timer() {
        return false;
    }
    execute_shortcut_disposition(state, disposition)
}

fn intercept_native_escape(
    state: &mut RuntimeState,
    xkb_keycode: u32,
    key_state: KeyState,
) -> bool {
    // Smithay/XKB keycodes carry the conventional eight-code offset over the
    // Linux evdev values emitted by libinput.
    let Some(evdev_keycode) = xkb_keycode.checked_sub(8) else {
        return false;
    };
    #[cfg(feature = "flutter")]
    if key_state == KeyState::Released
        && state
            .wayland
            .as_ref()
            .is_some_and(|frontend| frontend.flutter_repeat_key == Some(xkb_keycode))
    {
        cancel_flutter_repeat(state);
    }
    let disposition = state
        .native_escape_shortcut
        .observe(evdev_keycode, key_state == KeyState::Pressed);
    // VT switching is a seat-level escape, not a client, window, or shell
    // action. Keep it available while the native lock screen owns input.
    if let ShortcutDisposition::RequestVtSwitch(vt) = &disposition {
        return execute_shortcut_disposition(state, ShortcutDisposition::RequestVtSwitch(*vt));
    }
    #[cfg(feature = "flutter")]
    if state.secure_session_locked() {
        return match disposition {
            ShortcutDisposition::Forward => false,
            ShortcutDisposition::RequestLock => {
                if let Some(authentication) = state.authentication.as_ref() {
                    authentication.lock();
                }
                true
            }
            ShortcutDisposition::RequestShutdown => {
                state
                    .lifecycle
                    .request_shutdown(ShutdownReason::NativeEscapeShortcut);
                true
            }
            // Shortcut state still observes every transition so releases stay
            // balanced, but locked sessions cannot trigger client/window or
            // system-control actions.
            _ => true,
        };
    }
    // The shortcut engine has observed the key either way, so its modifier
    // and chord state stays balanced while an app holds the shortcuts.
    if let Some(frontend) = state.wayland.as_mut() {
        let inhibit = &mut frontend.shortcuts_inhibit;
        if key_state == KeyState::Released {
            if inhibit.take_forwarded_release(xkb_keycode) {
                return false;
            }
        } else {
            let forwarded = inhibit.active() && !disposition.survives_shortcuts_inhibit();
            inhibit.note_press(xkb_keycode, forwarded);
            if forwarded {
                state.native_escape_shortcut.pass_through_key(evdev_keycode);
                return false;
            }
        }
    }
    #[cfg(feature = "flutter")]
    let repeats_system_control = key_state == KeyState::Pressed && disposition.repeats_with_timer();
    let handled = execute_shortcut_disposition(state, disposition);
    if !handled && key_state == KeyState::Pressed {
        state.native_escape_shortcut.pass_through_key(evdev_keycode);
    }
    #[cfg(feature = "flutter")]
    if handled && repeats_system_control {
        start_system_control_repeat(state, xkb_keycode);
    }
    handled
}

pub(super) fn execute_shortcut_disposition(
    state: &mut RuntimeState,
    disposition: ShortcutDisposition,
) -> bool {
    execute_shortcut_disposition_at(state, disposition, None)
}

fn execute_shortcut_disposition_at(
    state: &mut RuntimeState,
    disposition: ShortcutDisposition,
    _position: Option<Point<f64, Logical>>,
) -> bool {
    match disposition {
        ShortcutDisposition::Forward => false,
        ShortcutDisposition::Consume => true,
        ShortcutDisposition::RequestVtSwitch(vt) => {
            let result = if let Some(frontend) = state.wayland.as_mut() {
                frontend
                    .session
                    .change_vt(vt)
                    .map_err(|error| error.to_string())
            } else {
                Err("Wayland frontend is unavailable".to_owned())
            };
            match result {
                Ok(()) => info!(vt, "requested virtual terminal switch"),
                Err(error) => warn!(%error, vt, "could not switch virtual terminal"),
            }
            true
        }
        ShortcutDisposition::RequestShutdown => {
            state
                .lifecycle
                .request_shutdown(ShutdownReason::NativeEscapeShortcut);
            true
        }
        ShortcutDisposition::PluginAction(id) => {
            #[cfg(feature = "flutter")]
            if state.secure_session_locked() {
                return false;
            }
            state.plugin_actions.queue(id, None)
        }
        ShortcutDisposition::RequestApplications => {
            #[cfg(feature = "flutter")]
            if state.secure_session_locked() {
                return false;
            }
            state
                .plugin_actions
                .queue(crate::plugin_actions::LEGACY_LAUNCHER_ACTION.into(), None)
        }
        ShortcutDisposition::RequestDashboard => {
            #[cfg(feature = "flutter")]
            state.queue_shell_action(super::super::wire::ShellAction::Dashboard, None);
            true
        }
        ShortcutDisposition::RequestOverview => {
            #[cfg(feature = "flutter")]
            {
                let monitor_id = prepare_shell_overlay_action(state, _position);
                state.queue_shell_action(super::super::wire::ShellAction::Overview, monitor_id);
            }
            true
        }
        direction @ (ShortcutDisposition::RequestPreviousWorkspace
        | ShortcutDisposition::RequestNextWorkspace) => {
            #[cfg(feature = "flutter")]
            {
                let delta = if matches!(direction, ShortcutDisposition::RequestPreviousWorkspace) {
                    -1
                } else {
                    1
                };
                let Some(monitor_id) = prepare_shell_overlay_action(state, _position) else {
                    return false;
                };
                let target = state
                    .wayland
                    .as_ref()
                    .and_then(|frontend| frontend.adjacent_workspace(monitor_id, delta));
                let Some(target) = target else {
                    return false;
                };
                return super::window_management::switch_monitor_workspace(
                    state, monitor_id, target,
                );
            }
            #[cfg(not(feature = "flutter"))]
            false
        }
        ShortcutDisposition::RequestSwitchWorkspace(workspace_id) => {
            #[cfg(feature = "flutter")]
            {
                let Some(monitor_id) = prepare_shell_overlay_action(state, _position) else {
                    return false;
                };
                return super::window_management::switch_monitor_workspace(
                    state,
                    monitor_id,
                    workspace_id,
                );
            }
            #[cfg(not(feature = "flutter"))]
            false
        }
        direction @ (ShortcutDisposition::RequestMoveToPreviousWorkspace
        | ShortcutDisposition::RequestMoveToNextWorkspace) => {
            #[cfg(feature = "flutter")]
            {
                let delta = if matches!(
                    direction,
                    ShortcutDisposition::RequestMoveToPreviousWorkspace
                ) {
                    -1
                } else {
                    1
                };
                let Some((window_id, monitor_id)) =
                    super::window_management::focused_workspace_window(state)
                else {
                    return false;
                };
                let target = state
                    .wayland
                    .as_ref()
                    .and_then(|frontend| frontend.adjacent_workspace(monitor_id, delta));
                let Some(target) = target else {
                    return false;
                };
                return super::window_management::move_window_to_workspace(
                    state, window_id, None, target, true,
                );
            }
            #[cfg(not(feature = "flutter"))]
            false
        }
        ShortcutDisposition::RequestMoveToWorkspace(workspace_id) => {
            #[cfg(feature = "flutter")]
            {
                let Some((window_id, _)) =
                    super::window_management::focused_workspace_window(state)
                else {
                    return false;
                };
                return super::window_management::move_window_to_workspace(
                    state,
                    window_id,
                    None,
                    workspace_id,
                    true,
                );
            }
            #[cfg(not(feature = "flutter"))]
            false
        }
        ShortcutDisposition::RequestResize(action) => {
            #[cfg(feature = "flutter")]
            super::window_management::resize_focused_toplevel(state, action);
            #[cfg(not(feature = "flutter"))]
            let _ = action;
            true
        }
        ShortcutDisposition::RequestToggleVerticalMaximize => {
            #[cfg(feature = "flutter")]
            super::window_management::toggle_shell_vertical_maximize_focused_toplevel(state);
            true
        }
        ShortcutDisposition::RequestFocus(direction) => {
            #[cfg(feature = "flutter")]
            {
                let shell_owns_scene = state
                    .wayland
                    .as_ref()
                    .and_then(|frontend| frontend.input_layout.as_ref())
                    .is_some_and(InputLayoutSnapshot::exclusive_shell);
                if shell_owns_scene {
                    let action = match direction {
                        LayoutDirection::Left => super::super::wire::ShellAction::FocusLeft,
                        LayoutDirection::Right => super::super::wire::ShellAction::FocusRight,
                        LayoutDirection::Up => super::super::wire::ShellAction::FocusUp,
                        LayoutDirection::Down => super::super::wire::ShellAction::FocusDown,
                    };
                    state.queue_shell_action(action, None);
                    true
                } else {
                    super::window_management::focus_toplevel_in_direction(state, direction);
                    true
                }
            }
            #[cfg(not(feature = "flutter"))]
            false
        }
        ShortcutDisposition::RequestSwap(direction) => {
            #[cfg(feature = "flutter")]
            super::window_management::swap_toplevel_in_direction(state, direction);
            true
        }
        ShortcutDisposition::RequestWindowSwitcherNext => {
            #[cfg(feature = "flutter")]
            {
                let monitor_id = prepare_shell_overlay_action(state, _position);
                state.queue_shell_action(
                    super::super::wire::ShellAction::WindowSwitcherNext,
                    monitor_id,
                );
            }
            true
        }
        ShortcutDisposition::RequestWindowSwitcherPrevious => {
            #[cfg(feature = "flutter")]
            {
                let monitor_id = prepare_shell_overlay_action(state, _position);
                state.queue_shell_action(
                    super::super::wire::ShellAction::WindowSwitcherPrevious,
                    monitor_id,
                );
            }
            true
        }
        ShortcutDisposition::RequestWindowSwitcherEnd { forward } => {
            #[cfg(feature = "flutter")]
            state.queue_shell_action(super::super::wire::ShellAction::WindowSwitcherEnd, None);
            !forward
        }
        ShortcutDisposition::RequestClipboard => {
            #[cfg(feature = "flutter")]
            {
                let monitor_id = prepare_shell_overlay_action(state, _position);
                state.queue_shell_action(super::super::wire::ShellAction::Clipboard, monitor_id);
            }
            true
        }
        ShortcutDisposition::RequestScreenshotRegion => {
            #[cfg(feature = "flutter")]
            {
                let monitor_id = prepare_shell_overlay_action(state, _position);
                state.request_screenshot_selection(monitor_id);
            }
            true
        }
        ShortcutDisposition::RequestMinimize => {
            #[cfg(feature = "flutter")]
            super::window_management::minimize_focused_toplevel(state);
            true
        }
        ShortcutDisposition::RequestMinimizeAll => {
            #[cfg(feature = "flutter")]
            super::window_management::minimize_all_toplevels(state);
            true
        }
        ShortcutDisposition::RequestClose => {
            #[cfg(feature = "flutter")]
            super::window_management::close_focused_toplevel(state);
            true
        }
        ShortcutDisposition::RequestToggleMaximize => {
            #[cfg(feature = "flutter")]
            super::window_management::toggle_shell_maximize_focused_toplevel(state);
            true
        }
        ShortcutDisposition::RequestToggleFullscreen => {
            #[cfg(feature = "flutter")]
            super::window_management::toggle_shell_fullscreen_focused_toplevel(state);
            true
        }
        ShortcutDisposition::RequestToggleWindowAlwaysOnTop => {
            #[cfg(feature = "flutter")]
            super::window_management::toggle_always_on_top_focused_toplevel(state);
            true
        }
        ShortcutDisposition::RequestReleasePointer => {
            if let Some(frontend) = state.wayland.as_mut() {
                frontend.suspend_shortcuts_inhibit();
            }
            #[cfg(feature = "flutter")]
            release_pointer_to_shell(state);
            true
        }
        ShortcutDisposition::RequestLock => {
            #[cfg(feature = "flutter")]
            if let Some(authentication) = state.authentication.as_ref() {
                authentication.lock();
            }
            true
        }
        ShortcutDisposition::RequestVolumeUp => {
            if let Some(controls) = state.system_controls.as_ref() {
                controls.volume_up();
            }
            true
        }
        ShortcutDisposition::RequestVolumeDown => {
            if let Some(controls) = state.system_controls.as_ref() {
                controls.volume_down();
            }
            true
        }
        ShortcutDisposition::RequestMute => {
            if let Some(controls) = state.system_controls.as_ref() {
                controls.toggle_mute();
            }
            true
        }
        ShortcutDisposition::RequestBrightnessUp => {
            adjust_brightness_for_pointer_output(state, true);
            true
        }
        ShortcutDisposition::RequestBrightnessDown => {
            adjust_brightness_for_pointer_output(state, false);
            true
        }
        ShortcutDisposition::RequestNextKeyboardLayout => {
            cycle_keyboard_layout(state, true);
            true
        }
        ShortcutDisposition::RequestPreviousKeyboardLayout => {
            cycle_keyboard_layout(state, false);
            true
        }
        ShortcutDisposition::RequestOpenSettings => {
            #[cfg(feature = "flutter")]
            state.queue_shell_action(super::super::wire::ShellAction::OpenSettings, None);
            true
        }
        ShortcutDisposition::Spawn {
            command,
            desktop_file_id,
        } => {
            #[cfg(feature = "flutter")]
            state
                .pending_shortcut_launches
                .push_back(ShortcutTarget::Spawn {
                    command,
                    desktop_file_id,
                });
            true
        }
        ShortcutDisposition::SpawnSh(command) => {
            #[cfg(feature = "flutter")]
            state
                .pending_shortcut_launches
                .push_back(ShortcutTarget::SpawnSh { command });
            true
        }
    }
}

fn cycle_keyboard_layout(state: &mut RuntimeState, forward: bool) {
    let Some(keyboard) = state
        .wayland
        .as_ref()
        .and_then(|frontend| frontend.seat.get_keyboard())
    else {
        return;
    };
    let active = keyboard.with_xkb_state(state, |mut context| {
        if forward {
            context.cycle_next_layout();
        } else {
            context.cycle_prev_layout();
        }
        context.xkb().lock().unwrap().active_layout().0 as usize
    });
    publish_active_keyboard_layout(state, active);
}

fn synchronize_active_keyboard_layout(
    state: &mut RuntimeState,
    keyboard: &KeyboardHandle<RuntimeState>,
) {
    let active = keyboard.with_xkb_state(state, |context| {
        context.xkb().lock().unwrap().active_layout().0 as usize
    });
    publish_active_keyboard_layout(state, active);
}

fn publish_active_keyboard_layout(state: &mut RuntimeState, active: usize) {
    let Some(frontend) = state.wayland.as_mut() else {
        return;
    };
    if frontend.active_keyboard_layout == active {
        return;
    }
    frontend.active_keyboard_layout = active;
    frontend.keyboard_configuration_changed = true;
    let name = frontend
        .keyboard_layout_names
        .get(active)
        .map(String::as_str)
        .unwrap_or("unknown");
    info!(
        layout_index = active,
        layout_name = name,
        "switched keyboard layout"
    );
}

#[cfg(feature = "flutter")]
fn release_pointer_to_shell(state: &mut RuntimeState) {
    let Some(pointer) = state
        .wayland
        .as_ref()
        .and_then(|frontend| frontend.seat.get_pointer())
    else {
        return;
    };
    let focused_surface = pointer.current_focus();
    let released_window_id = focused_surface.as_ref().and_then(|surface| {
        state
            .wayland
            .as_ref()
            .and_then(|frontend| frontend.window_id_for_input_surface(surface))
    });
    let had_constraint = focused_surface.as_ref().is_some_and(|surface| {
        with_pointer_constraint(surface, &pointer, |constraint| {
            let Some(constraint) = constraint else {
                return false;
            };
            constraint.deactivate();
            true
        })
    });

    let (mut pressed_buttons, time) = {
        let frontend = state.frontend_mut();
        if let Some(window_id) = released_window_id {
            frontend.pointer_constraint_escape.release_window(window_id);
        }
        frontend.client_pointer_capture = None;
        frontend.client_pointer_buttons.clear();
        frontend.client_pointer_presses.clear();
        frontend.flutter_pointer_press = None;
        frontend.set_clipboard_drag_active(false);
        let mut pressed_buttons = std::mem::take(&mut frontend.wayland_pointer_buttons)
            .into_iter()
            .collect::<Vec<_>>();
        pressed_buttons.sort_unstable();
        frontend
            .retired_pointer_buttons
            .extend(pressed_buttons.iter().copied());
        frontend.update_cursor_image(CursorImageStatus::default_named());
        (pressed_buttons, InputTime::now())
    };

    let had_grab = pointer.is_grabbed();
    for button in pressed_buttons.drain(..) {
        pointer.button(
            state,
            &ButtonEvent {
                button,
                state: ButtonState::Released,
                serial: SERIAL_COUNTER.next_serial(),
                time,
            },
        );
    }
    if pointer.is_grabbed() {
        pointer.unset_grab(state, SERIAL_COUNTER.next_serial(), time);
    }
    if had_grab || !state.frontend().retired_pointer_buttons.is_empty() {
        pointer.frame(state);
    }
    state.scene_sync.mark_dirty();
    info!(
        window_id = ?released_window_id,
        had_constraint,
        had_grab,
        "released pointer capture until the client is clicked again"
    );
}

#[cfg(feature = "flutter")]
fn prepare_shell_overlay_action(
    state: &mut RuntimeState,
    position: Option<Point<f64, Logical>>,
) -> Option<i64> {
    let pointer = state
        .wayland
        .as_ref()
        .and_then(|frontend| frontend.seat.get_pointer());
    let focused_surface = pointer.as_ref().and_then(PointerHandle::current_focus);
    let released_constraint = match (pointer, focused_surface) {
        (Some(pointer), Some(surface)) => {
            with_pointer_constraint(&surface, &pointer, |constraint| {
                let Some(constraint) = constraint else {
                    return false;
                };
                if !constraint.is_active() {
                    return false;
                }
                constraint.deactivate();
                true
            })
        }
        _ => false,
    };
    if released_constraint {
        if let Some(frontend) = state.wayland.as_mut() {
            frontend.update_cursor_image(CursorImageStatus::default_named());
        }
        state.scene_sync.mark_dirty();
    }

    let pointer_monitor = state
        .wayland
        .as_ref()
        .and_then(WaylandFrontend::control_output_under_pointer)
        .map(|(_, monitor_id)| monitor_id);
    let touch_monitor = position.and_then(|position| {
        state
            .wayland
            .as_ref()?
            .outputs
            .iter()
            .find(|output| output.logical_geometry.to_f64().contains(position))
            .and_then(|output| i64::try_from(output.id.0).ok())
    });
    touch_monitor
        .or(pointer_monitor)
        .or_else(|| super::window_management::focused_workspace_window(state).map(|(_, id)| id))
        .or_else(|| {
            let frontend = state.wayland.as_ref()?;
            frontend
                .ticker_output
                .or_else(|| frontend.outputs.first().map(|output| output.id))
                .and_then(|output| i64::try_from(output.0).ok())
        })
}

fn adjust_brightness_for_pointer_output(state: &RuntimeState, increase: bool) {
    let Some((connector, monitor_id)) = state
        .wayland
        .as_ref()
        .and_then(WaylandFrontend::control_output_under_pointer)
    else {
        warn!("brightness shortcut has no output under the pointer");
        return;
    };
    let Some(controls) = state.system_controls.as_ref() else {
        return;
    };
    if increase {
        controls.brightness_up(connector.to_owned(), monitor_id);
    } else {
        controls.brightness_down(connector.to_owned(), monitor_id);
    }
}

#[cfg(feature = "flutter")]
fn process_flutter_keyboard_transition(
    state: &mut RuntimeState,
    keycode: Keycode,
    key_state: KeyState,
    time: InputTime,
) -> bool {
    let secure_locked = state.secure_session_locked();
    let keyboard = state
        .frontend()
        .seat
        .get_keyboard()
        .expect("seat has no keyboard");
    let consume_retired = {
        let frontend = state.frontend_mut();
        retired_key_consumes_transition(
            &mut frontend.retired_keyboard_keys,
            keycode.raw(),
            key_state,
        )
    };
    let secure_route_invalid = secure_locked
        && !matches!(
            keyboard.current_focus(),
            Some(super::focus::KeyboardFocusTarget::Flutter)
        );
    super::input_method::input_key(
        state,
        &keyboard,
        keycode,
        key_state,
        SERIAL_COUNTER.next_serial(),
        time,
        move |_, _, _| {
            if consume_retired || secure_route_invalid {
                FilterResult::Intercept(())
            } else {
                FilterResult::Forward
            }
        },
    );
    synchronize_active_keyboard_layout(state, &keyboard);
    true
}
