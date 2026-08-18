use std::collections::HashSet;
use std::error::Error;

use smithay::backend::input::{
    AbsolutePositionEvent, Axis, AxisSource, ButtonState, Device, DeviceCapability, Event,
    GestureBeginEvent, GestureSwipeUpdateEvent, InputEvent, KeyState, KeyboardKeyEvent,
    PointerAxisEvent, PointerButtonEvent, PointerMotionEvent, TouchEvent,
};
use smithay::backend::libinput::{LibinputInputBackend, LibinputSessionInterface};
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
use smithay::reexports::input::event::pointer::PointerEventTrait;
use smithay::reexports::input::event::touch::TouchEventTrait;
use smithay::reexports::input::{Device as LibinputDevice, Libinput, TapButtonMap};
#[cfg(feature = "flutter")]
use smithay::reexports::wayland_protocols::xdg::shell::server::xdg_toplevel;
#[cfg(feature = "flutter")]
use smithay::reexports::wayland_server::Resource;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::utils::{Logical, Point, SERIAL_COUNTER};
#[cfg(feature = "flutter")]
use smithay::utils::{Rectangle, Serial};
use smithay::wayland::pointer_constraints::{PointerConstraint, with_pointer_constraint};
use tracing::{info, warn};

#[cfg(feature = "flutter")]
use super::super::PendingWindowEvent;
use super::super::RuntimeState;
#[cfg(test)]
use super::super::lifecycle::LifecycleState;
use super::super::lifecycle::ShutdownReason;
#[cfg(test)]
use super::super::native_shortcut::NativeEscapeShortcut;
use super::super::native_shortcut::{ShortcutDisposition, ShortcutTarget};
#[cfg(feature = "flutter")]
use super::super::settings::KeyboardSettings;
#[cfg(feature = "flutter")]
use super::super::window_grab::{
    LocalFlutterWindowGrab, MoveSurfaceGrab, ResizeEdges, ResizeSurfaceGrab, X11ResizeSurfaceGrab,
};
#[cfg(all(feature = "flutter", test))]
use super::super::wire::InputRect;
#[cfg(feature = "flutter")]
use super::super::wire::{
    InputLayoutSnapshot, InputWindowRegion, WindowPlacementChange, WindowPlacementPhase,
};
#[cfg(feature = "flutter")]
use super::FlutterPointerPress;
use super::WaylandFrontend;
#[cfg(feature = "flutter")]
use super::input_source::init_joystick_activity;
use super::input_source::{InputBatchEvent, LibinputBatchSource};

#[cfg(feature = "flutter")]
const BTN_LEFT: u32 = 0x110;
#[cfg(feature = "flutter")]
const BTN_RIGHT: u32 = 0x111;
#[cfg(feature = "flutter")]
const MAX_CLIENT_POINTER_PRESSES: usize = 16;

#[cfg(feature = "flutter")]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct ShellKeyStroke {
    evdev_keycode: u32,
    shift: bool,
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
    time: u32,
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
fn inject_shell_key_transition(
    state: &mut RuntimeState,
    keyboard: &KeyboardHandle<RuntimeState>,
    stroke: ShellKeyStroke,
    key_state: KeyState,
    time: u32,
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
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        route_shell_key_transition(
            &mut frontend.shell_keyboard_keys,
            keycode.raw(),
            key_state,
            seat_pressed,
        )
    };
    accepted && process_keyboard_transition(state, keycode, key_state, time)
}

#[cfg(feature = "flutter")]
/// Turn one shell-keyboard intent into complete virtual key lifecycles.
///
/// These transitions enter the same focus, XKB, shortcut, Flutter and Wayland
/// router as libinput keyboard events. The software keyboard is an input
/// source, not a separate text-delivery protocol.
pub(crate) fn dispatch_shell_keyboard(
    state: &mut RuntimeState,
    command: &super::super::wire::KeyboardCommand,
) -> bool {
    let (keyboard, time) = {
        let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
        (
            frontend.seat.get_keyboard().expect("seat has no keyboard"),
            frontend.start_time.elapsed().as_millis() as u32,
        )
    };
    // Do not gate the shared router on Wayland seat focus. Secure lock
    // deliberately clears client focus, and process_keyboard_transition()
    // routes that same focusless stream to Flutter just as it does for a
    // physical keyboard.
    match command {
        super::super::wire::KeyboardCommand::Text(text) => {
            let mut delivered = false;
            for character in text.chars() {
                let Some(stroke) = shell_text_key_stroke(character) else {
                    warn!(%character, "ignored character unsupported by the shell keyboard keymap");
                    continue;
                };
                delivered |= inject_shell_key_stroke(state, &keyboard, stroke, false, time);
            }
            delivered
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
#[derive(Clone)]
pub(super) struct ClientInputRoute {
    window: Option<smithay::desktop::Window>,
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
    focus: (WlSurface, Point<f64, Logical>),
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
    fn focus_at(&self, position: Point<f64, Logical>) -> (WlSurface, Point<f64, Logical>) {
        let scene_position = position - self.scene_origin;
        let (local_x, local_y) =
            self.region
                .rect
                .map_to(self.region.source_rect, scene_position.x, scene_position.y);
        let local_point = Point::from((local_x, local_y));
        let (surface, local_origin) =
            under_from_surface_tree(&self.surface, local_point, (0, 0), WindowSurfaceType::ALL)
                .unwrap_or_else(|| (self.surface.clone(), (0, 0).into()));
        let scale_x = self.region.rect.width / self.region.source_rect.width;
        let scale_y = self.region.rect.height / self.region.source_rect.height;
        let global_origin = self.scene_origin
            + Point::from((
                self.region.rect.x
                    + (f64::from(local_origin.x) - self.region.source_rect.x) * scale_x,
                self.region.rect.y
                    + (f64::from(local_origin.y) - self.region.source_rect.y) * scale_y,
            ));
        (surface, global_origin)
    }
}

#[cfg(feature = "flutter")]
impl WaylandFrontend {
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
        let root = self.owning_toplevel_surface(surface)?;
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
struct PointerMotionTarget {
    routed: RoutedPointerTarget,
    focus: Option<(WlSurface, Point<f64, Logical>)>,
}

#[cfg(feature = "flutter")]
impl PointerMotionTarget {
    const FLUTTER: Self = Self {
        routed: RoutedPointerTarget::Flutter,
        focus: None,
    };

    fn client(route: &ClientInputRoute, position: Point<f64, Logical>) -> Self {
        Self {
            routed: RoutedPointerTarget::Client(route.region.surface_id),
            focus: Some(route.focus_at(position)),
        }
    }
}

#[cfg(feature = "flutter")]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum FlutterKeyDisposition {
    Forward,
    Dispatch,
    ConsumeRetired,
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
fn route_flutter_key_transition(
    active: &mut HashSet<u32>,
    retired: &mut HashSet<u32>,
    keycode: u32,
    state: KeyState,
    capture_new_press: bool,
) -> FlutterKeyDisposition {
    if retired_key_consumes_transition(retired, keycode, state) {
        if state == KeyState::Released {
            active.remove(&keycode);
        }
        return FlutterKeyDisposition::ConsumeRetired;
    }
    match state {
        KeyState::Pressed if active.contains(&keycode) || capture_new_press => {
            active.insert(keycode);
            FlutterKeyDisposition::Dispatch
        }
        KeyState::Pressed => FlutterKeyDisposition::Forward,
        KeyState::Released if active.remove(&keycode) => FlutterKeyDisposition::Dispatch,
        KeyState::Released => FlutterKeyDisposition::Forward,
    }
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
            && (route.window.is_some() || self.input_method.owns_popup_surface(&route.surface))
    }

    fn input_route(&mut self, position: Point<f64, Logical>) -> Option<&ClientInputRoute> {
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
                        surface,
                        region: *region,
                        layout_index,
                        scene_origin: self.atlas_origin,
                    });
                }
                let window = self.window_for_id(region.window_id)?;
                let root_surface = self.window_root_surface(&window)?;
                if self.owning_toplevel_surface(&surface).as_ref() != Some(&root_surface) {
                    return None;
                }
                Some(ClientInputRoute {
                    window: Some(window.clone()),
                    surface,
                    region: *region,
                    layout_index,
                    scene_origin: self.atlas_origin,
                })
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

    fn input_target(&mut self, position: Point<f64, Logical>) -> InputTarget {
        self.input_route(position)
            .cloned()
            .map_or(InputTarget::Flutter, InputTarget::Client)
    }

    fn pointer_motion_target(&mut self, position: Point<f64, Logical>) -> PointerMotionTarget {
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
) -> Result<(), Box<dyn Error>> {
    #[cfg(feature = "flutter")]
    init_joystick_activity(event_loop, session.clone())?;
    let mut context =
        Libinput::new_with_udev::<LibinputSessionInterface<LibSeatSession>>(session.into());
    context
        .udev_assign_seat(seat_name)
        .map_err(|()| "libinput could not assign the active seat")?;
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
    Ok(())
}

#[cfg(feature = "flutter")]
fn process_keyboard_transition(
    state: &mut RuntimeState,
    keycode: Keycode,
    key_state: KeyState,
    time: u32,
) -> bool {
    state.note_user_activity();
    if intercept_native_escape(state, keycode.raw(), key_state) {
        return true;
    }
    if let Some(evdev_keycode) = keycode.raw().checked_sub(8) {
        let allow_new = !state.secure_session_locked();
        let routed = state.native_app_plugins.as_mut().map(|manager| {
            manager.route_key(
                evdev_keycode,
                key_state == KeyState::Pressed,
                u64::from(time).saturating_mul(1_000_000),
                allow_new,
            )
        });
        match routed {
            Some(Ok(true)) => return true,
            Some(Err(error)) => {
                warn!(%error, evdev_keycode, "native application key routing failed");
                return true;
            }
            Some(Ok(false)) | None => {}
        }
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

fn enable_tap_to_click(device: &mut LibinputDevice) {
    let finger_count = device.config_tap_finger_count();
    if finger_count == 0 {
        return;
    }

    if let Err(error) = device.config_tap_set_button_map(TapButtonMap::LeftRightMiddle) {
        // Keep tap-to-click usable if a device rejects explicit remapping;
        // libinput's normal default is the same left/right/middle order.
        warn!(
            ?error,
            device = %device.name(),
            "could not configure multi-finger tap button mapping"
        );
    }

    if let Err(error) = device.config_tap_set_enabled(true) {
        warn!(
            ?error,
            device = %device.name(),
            "could not enable touchpad tap-to-click"
        );
        return;
    }

    info!(
        device = %device.name(),
        finger_count,
        two_finger_right_click = finger_count >= 2,
        "enabled touchpad tap-to-click"
    );
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
            state.touchpad_gestures.reset();
            return Some(false);
        }
        return None;
    }

    let gesture = match event {
        InputEvent::GestureSwipeBegin { event } => {
            let device = event.device();
            state
                .touchpad_gestures
                .begin_swipe(device.sysname(), event.fingers());
            None
        }
        InputEvent::GestureSwipeUpdate { event } => {
            let device = event.device();
            state
                .touchpad_gestures
                .update_swipe(device.sysname(), event.delta_x(), event.delta_y())
        }
        InputEvent::GestureSwipeEnd { event } => {
            let device = event.device();
            state.touchpad_gestures.end_swipe(device.sysname());
            None
        }
        _ => return None,
    };

    if let Some(gesture) = gesture {
        let disposition = state.native_escape_shortcut.observe_gesture(gesture);
        let handled = execute_shortcut_disposition(state, disposition);
        if handled {
            info!(
                ?gesture,
                "recognized configured compositor shortcut gesture"
            );
        }
        Some(handled)
    } else {
        Some(false)
    }
}

fn process_input_event(
    state: &mut RuntimeState,
    mut event: InputEvent<LibinputInputBackend>,
) -> bool {
    if let InputEvent::DeviceAdded { device } = &mut event {
        // libinput recognizes taps and emits ordinary BTN_LEFT transitions.
        // Keeping recognition at the device boundary lets synthesized clicks
        // use the exact same Flutter/Wayland focus and grab path as buttons.
        enable_tap_to_click(device);
    }

    if let InputEvent::DeviceRemoved { device } = &event {
        let reset = InputDeviceReset {
            keyboard: Device::has_capability(device, DeviceCapability::Keyboard),
            pointer: Device::has_capability(device, DeviceCapability::Pointer),
            touch: Device::has_capability(device, DeviceCapability::Touch),
        };
        if reset.any() {
            reset_input_devices(state, reset);
        }
        return reset.any();
    }

    #[cfg(feature = "flutter")]
    if let InputEvent::Keyboard {
        event: key_event, ..
    } = &event
    {
        return process_keyboard_transition(
            state,
            key_event.key_code(),
            key_event.state(),
            key_event.time_msec(),
        );
    }

    #[cfg(feature = "flutter")]
    if !matches!(&event, InputEvent::DeviceAdded { .. }) {
        state.note_user_activity();
    }

    #[cfg(feature = "flutter")]
    if let Some(flush_clients) = process_touchpad_gesture_event(state, &event) {
        return flush_clients;
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
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
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
    if reset.keyboard {
        state.native_escape_shortcut.reset();
        #[cfg(feature = "flutter")]
        cancel_flutter_repeat(state);
    }
    #[cfg(feature = "flutter")]
    if reset.pointer {
        state.touchpad_gestures.reset();
    }
    #[cfg(feature = "flutter")]
    if state.flutter_active {
        state
            .flutter_input
            .cancel_device_lifecycles(reset.pointer, reset.touch);
    }
    #[cfg(feature = "flutter")]
    if let Some(manager) = state.native_app_plugins.as_mut()
        && let Err(error) = manager.reset_input(reset.keyboard, reset.touch)
    {
        warn!(%error, "could not reset native application input");
    }

    let Some(frontend) = state.wayland.as_mut() else {
        return;
    };
    let time = frontend.start_time.elapsed().as_millis() as u32;
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
    let active_flutter_keys = if reset.keyboard {
        std::mem::take(&mut frontend.flutter_keyboard_keys)
    } else {
        HashSet::new()
    };
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
        #[cfg(feature = "flutter")]
        frontend
            .retired_keyboard_keys
            .extend(active_flutter_keys.iter().copied());
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
            #[cfg(feature = "flutter")]
            let was_flutter = active_flutter_keys.contains(&raw_keycode);
            #[cfg(not(feature = "flutter"))]
            let was_flutter = false;
            let was_retired = previously_retired_keys.contains(&raw_keycode);
            keyboard.input::<(), _>(
                state,
                keycode,
                KeyState::Released,
                SERIAL_COUNTER.next_serial(),
                time,
                move |state, modifiers, key| {
                    #[cfg(not(feature = "flutter"))]
                    let _ = (&state, &modifiers, &key);
                    #[cfg(feature = "flutter")]
                    if was_flutter && state.flutter_active {
                        state
                            .flutter_input
                            .handle_keyboard(key, KeyState::Released, modifiers);
                    }
                    if was_flutter || was_retired {
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
fn retained_flutter_xkb_keycode(keycode: u32) -> Keycode {
    // flutter_keyboard_keys retains Smithay/XKB keycodes, which already
    // include XKB's evdev + 8 offset. Replay that value unchanged; adding the
    // offset again turns XKB Backspace (22) into XKB U (30).
    Keycode::new(keycode)
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
            state
                .wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .flutter_repeat_token = Some(token);
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
    let xkb_keycode = retained_flutter_xkb_keycode(keycode);
    let keysym = keyboard.with_xkb_state(state, |context| {
        let xkb = context.xkb().lock().unwrap();
        // SAFETY: the state reference remains inside the XKB mutex guard.
        unsafe { xkb.state() }.key_get_one_sym(xkb_keycode)
    });
    let modifiers = keyboard.modifier_state();
    let unicode = {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        flutter_unicode_for_keysym(frontend.flutter_compose.as_mut(), keysym)
    };
    state.flutter_input.handle_keyboard_with_unicode(
        xkb_keycode.raw(),
        KeyState::Pressed,
        &modifiers,
        unicode,
    );
    true
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
    let disposition = state
        .native_escape_shortcut
        .observe(evdev_keycode, key_state == KeyState::Pressed);
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
    execute_shortcut_disposition(state, disposition)
}

fn execute_shortcut_disposition(
    state: &mut RuntimeState,
    disposition: ShortcutDisposition,
) -> bool {
    match disposition {
        ShortcutDisposition::Forward => false,
        ShortcutDisposition::Consume => true,
        ShortcutDisposition::RequestShutdown => {
            state
                .lifecycle
                .request_shutdown(ShutdownReason::NativeEscapeShortcut);
            true
        }
        ShortcutDisposition::RequestApplications => {
            #[cfg(feature = "flutter")]
            state.queue_shell_action(super::super::wire::ShellAction::Applications, None);
            true
        }
        ShortcutDisposition::RequestOverview => {
            #[cfg(feature = "flutter")]
            {
                let monitor_id = prepare_shell_overlay_action(state);
                state.queue_shell_action(super::super::wire::ShellAction::Overview, monitor_id);
            }
            true
        }
        ShortcutDisposition::RequestToggleVerticalMaximize => {
            #[cfg(feature = "flutter")]
            super::window_management::toggle_shell_vertical_maximize_focused_toplevel(state);
            true
        }
        ShortcutDisposition::RequestWindowSwitcherNext => {
            #[cfg(feature = "flutter")]
            {
                let monitor_id = prepare_shell_overlay_action(state);
                state.queue_shell_action(
                    super::super::wire::ShellAction::WindowSwitcherNext,
                    monitor_id,
                );
            }
            true
        }
        ShortcutDisposition::RequestWindowSwitcherEnd => {
            #[cfg(feature = "flutter")]
            state.queue_shell_action(super::super::wire::ShellAction::WindowSwitcherEnd, None);
            true
        }
        ShortcutDisposition::RequestClipboard => {
            #[cfg(feature = "flutter")]
            {
                let monitor_id = prepare_shell_overlay_action(state);
                state.queue_shell_action(super::super::wire::ShellAction::Clipboard, monitor_id);
            }
            true
        }
        ShortcutDisposition::RequestScreenshotRegion => {
            #[cfg(feature = "flutter")]
            {
                let monitor_id = prepare_shell_overlay_action(state);
                state.request_screenshot_selection(monitor_id);
            }
            true
        }
        ShortcutDisposition::RequestMinimize => {
            #[cfg(feature = "flutter")]
            super::window_management::minimize_focused_toplevel(state);
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
        ShortcutDisposition::RequestReleasePointer => {
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
        ShortcutDisposition::Spawn(arguments) => {
            #[cfg(feature = "flutter")]
            state
                .pending_shortcut_launches
                .push_back(ShortcutTarget::Spawn { command: arguments });
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
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
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
        (
            pressed_buttons,
            frontend.start_time.elapsed().as_millis() as u32,
        )
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
    if had_grab
        || !state
            .wayland
            .as_ref()
            .expect("missing Wayland frontend")
            .retired_pointer_buttons
            .is_empty()
    {
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
fn prepare_shell_overlay_action(state: &mut RuntimeState) -> Option<i64> {
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

    state
        .wayland
        .as_ref()
        .and_then(WaylandFrontend::control_output_under_pointer)
        .map(|(_, monitor_id)| monitor_id)
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
    time: u32,
) -> bool {
    let secure_locked = state.secure_session_locked();
    let raw_keycode = keycode.raw();
    let keyboard = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .seat
        .get_keyboard()
        .expect("seat has no keyboard");
    let keyboard_grabbed = keyboard.is_grabbed();
    let disposition = {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        let capture_new_press = matches!(key_state, KeyState::Pressed)
            && (secure_locked
                || (frontend.text_input.shell_captures_keyboard() && !keyboard_grabbed));
        route_flutter_key_transition(
            &mut frontend.flutter_keyboard_keys,
            &mut frontend.retired_keyboard_keys,
            raw_keycode,
            key_state,
            capture_new_press,
        )
    };
    keyboard.input::<(), _>(
        state,
        keycode,
        key_state,
        SERIAL_COUNTER.next_serial(),
        time,
        move |state, modifiers, key| match disposition {
            FlutterKeyDisposition::Dispatch => {
                let repeatable =
                    matches!(key_state, KeyState::Pressed) && flutter_key_repeats(&key);
                let unicode = if matches!(key_state, KeyState::Pressed) {
                    let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                    flutter_unicode_for_keysym(
                        frontend.flutter_compose.as_mut(),
                        key.modified_sym(),
                    )
                } else {
                    key.modified_sym().key_char().map(u32::from).unwrap_or(0)
                };
                state.flutter_input.handle_keyboard_with_unicode(
                    key.raw_code().raw(),
                    key_state,
                    modifiers,
                    unicode,
                );
                if repeatable {
                    start_flutter_repeat(state, raw_keycode);
                } else if matches!(key_state, KeyState::Released)
                    && state
                        .wayland
                        .as_ref()
                        .is_some_and(|frontend| frontend.flutter_repeat_key == Some(raw_keycode))
                {
                    cancel_flutter_repeat(state);
                }
                FilterResult::Intercept(())
            }
            FlutterKeyDisposition::ConsumeRetired => FilterResult::Intercept(()),
            FlutterKeyDisposition::Forward => FilterResult::Forward,
        },
    );
    synchronize_active_keyboard_layout(state, &keyboard);
    true
}

#[cfg(feature = "flutter")]
fn process_flutter_input_event(
    state: &mut RuntimeState,
    event: InputEvent<LibinputInputBackend>,
) -> bool {
    debug_assert!(!matches!(&event, InputEvent::Keyboard { .. }));
    let secure_locked = state.secure_session_locked();
    match &event {
        InputEvent::PointerMotion { event: motion, .. } => {
            let flutter_captured = state.flutter_input.pointer_captured();
            let delta = motion.delta();
            let delta_unaccel = motion.delta_unaccel();
            let (position, target, relative) = {
                let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                frontend.set_pointer_cursor_visible(true);
                let scale = frontend.atlas_scale.max(f64::EPSILON);
                let delta = Point::from((delta.x / scale, delta.y / scale));
                let position = frontend.clamp_pointer(frontend.pointer_location + delta);
                let target =
                    if secure_locked || (flutter_captured && !frontend.clipboard_drag_active) {
                        PointerMotionTarget::FLUTTER
                    } else if let Some(route) = frontend.client_pointer_capture.as_ref() {
                        PointerMotionTarget::client(route, position)
                    } else {
                        frontend.pointer_motion_target(position)
                    };
                let relative = RelativeMotionEvent {
                    delta,
                    delta_unaccel: Point::from((delta_unaccel.x / scale, delta_unaccel.y / scale)),
                    utime: motion.time_usec(),
                };
                (position, target, relative)
            };
            route_pointer_motion(state, position, target, motion.time_msec(), Some(relative))
        }
        InputEvent::PointerMotionAbsolute { event: motion, .. } => {
            let flutter_captured = state.flutter_input.pointer_captured();
            let (position, target) = {
                let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                frontend.set_pointer_cursor_visible(true);
                let local = motion.position_transformed(frontend.desktop_bounds.size);
                let position = frontend.clamp_pointer(local + frontend.desktop_bounds.loc.to_f64());
                let target =
                    if secure_locked || (flutter_captured && !frontend.clipboard_drag_active) {
                        PointerMotionTarget::FLUTTER
                    } else if let Some(route) = frontend.client_pointer_capture.as_ref() {
                        PointerMotionTarget::client(route, position)
                    } else {
                        frontend.pointer_motion_target(position)
                    };
                (position, target)
            };
            route_pointer_motion(state, position, target, motion.time_msec(), None)
        }
        InputEvent::PointerButton { event: button, .. } => {
            let serial = SERIAL_COUNTER.next_serial();
            let button_code = button.button_code();
            state
                .wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .set_pointer_cursor_visible(true);
            state
                .native_escape_shortcut
                .note_pointer_button(button.state() == ButtonState::Pressed);
            if retired_pointer_button_consumes_transition(
                &mut state
                    .wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .retired_pointer_buttons,
                button_code,
                button.state(),
            ) {
                return true;
            }
            let pointer = state
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .seat
                .get_pointer()
                .expect("seat has no pointer");
            let pointer_grabbed = pointer.is_grabbed();
            let flutter_captured = state.flutter_input.pointer_captured();
            let clipboard_drag_active = state
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .clipboard_drag_active;
            let (target, local_window_region) = {
                let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                let target =
                    if secure_locked || (flutter_captured && !frontend.clipboard_drag_active) {
                        InputTarget::Flutter
                    } else if let Some(route) = frontend.client_pointer_capture.clone() {
                        InputTarget::Client(route)
                    } else {
                        let position = frontend.pointer_location;
                        frontend.input_target(position)
                    };
                let local_window_region = if !secure_locked
                    && !flutter_captured
                    && matches!(&target, InputTarget::Flutter)
                {
                    frontend.local_flutter_window_region_at(frontend.pointer_location)
                } else {
                    None
                };
                (target, local_window_region)
            };
            if button.state() == ButtonState::Released {
                state
                    .wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .forget_client_pointer_button(button_code);
            }
            // SUPER is compositor-owned and deliberately never enters the
            // client-facing seat state. Use the native physical-key tracker
            // for compositor pointer chords instead of Smithay's modifiers.
            let logo = state.native_escape_shortcut.super_pressed();
            let super_action = super_pointer_action(logo, button_code);
            let began_super_grab = if !pointer_grabbed
                && button.state() == ButtonState::Pressed
                && let Some(action) = super_action
            {
                match (&target, local_window_region) {
                    (InputTarget::Client(route), _) => {
                        begin_super_pointer_grab(state, route, action, button_code, serial)
                    }
                    (InputTarget::Flutter, Some(region)) => {
                        begin_local_super_pointer_grab(state, region, action, button_code, serial)
                    }
                    _ => false,
                }
            } else {
                false
            };
            if began_super_grab {
                update_pressed_buttons(
                    &mut state
                        .wayland
                        .as_mut()
                        .expect("missing Wayland frontend")
                        .wayland_pointer_buttons,
                    button_code,
                    ButtonState::Pressed,
                );
                pointer.button(
                    state,
                    &ButtonEvent {
                        button: button_code,
                        state: ButtonState::Pressed,
                        serial,
                        time: button.time_msec(),
                    },
                );
                pointer.frame(state);
                state.scene_sync.mark_dirty();
                return true;
            }
            if !logo
                && button.state() == ButtonState::Pressed
                && let InputTarget::Client(route) = &target
                && state
                    .wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .resume_pointer_constraint_for_route(route)
            {
                state.scene_sync.mark_dirty();
            }
            let mut scene_changed = false;
            if matches!(&target, InputTarget::Flutter) {
                let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                match button.state() {
                    ButtonState::Pressed if button_code == BTN_LEFT => {
                        frontend.flutter_pointer_press = Some(FlutterPointerPress {
                            button: button_code,
                            serial,
                            time: button.time_msec(),
                            location: frontend.pointer_location,
                        });
                    }
                    ButtonState::Released
                        if frontend
                            .flutter_pointer_press
                            .is_some_and(|press| press.button == button_code) =>
                    {
                        frontend.flutter_pointer_press = None;
                    }
                    _ => {}
                }
            }
            if clipboard_drag_active && button.state() == ButtonState::Released {
                // A compositor-owned DnD grab still mirrors the terminal
                // release into Flutter. This completes the original shell
                // gesture so its card preview can settle instead of being
                // abandoned when Smithay receives the actual drop.
                state.synchronize_flutter_pointer_position();
                state.flutter_input.handle(&event);
                state
                    .wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .set_clipboard_drag_active(false);
            }
            match target {
                InputTarget::Flutter if secure_locked || !pointer_grabbed => {
                    state.synchronize_flutter_pointer_position();
                    state.flutter_input.handle(&event);
                    false
                }
                target => {
                    if button.state() == ButtonState::Pressed
                        && let InputTarget::Client(route) = &target
                    {
                        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                        frontend.remember_client_pointer_press(route, serial, button_code);
                        if !pointer_grabbed {
                            frontend.client_pointer_capture = Some(route.clone());
                            frontend.client_pointer_buttons.insert(button_code);
                            scene_changed = activate_client_route(state, route, serial);
                        }
                    }
                    update_pressed_buttons(
                        &mut state
                            .wayland
                            .as_mut()
                            .expect("missing Wayland frontend")
                            .wayland_pointer_buttons,
                        button_code,
                        button.state(),
                    );
                    pointer.button(
                        state,
                        &ButtonEvent {
                            button: button_code,
                            state: button.state(),
                            serial,
                            time: button.time_msec(),
                        },
                    );
                    pointer.frame(state);
                    if button.state() == ButtonState::Released {
                        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                        frontend.client_pointer_buttons.remove(&button_code);
                        if frontend.client_pointer_buttons.is_empty() && !pointer.is_grabbed() {
                            frontend.client_pointer_capture = None;
                        }
                    }
                    if scene_changed {
                        state.scene_sync.mark_dirty();
                    }
                    true
                }
            }
        }
        InputEvent::PointerAxis { event: axis, .. } => {
            state
                .wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .set_pointer_cursor_visible(true);
            let pointer_grabbed = state
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .seat
                .get_pointer()
                .expect("seat has no pointer")
                .is_grabbed();
            let flutter_captured = state.flutter_input.pointer_captured();
            let flutter_target = {
                let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                if secure_locked || flutter_captured {
                    true
                } else if frontend.client_pointer_capture.is_some() {
                    false
                } else {
                    let position = frontend.pointer_location;
                    frontend.input_route(position).is_none()
                }
            };
            if flutter_target && (secure_locked || !pointer_grabbed) {
                state.synchronize_flutter_pointer_position();
                state.flutter_input.handle(&event);
                false
            } else {
                route_pointer_axis(state, axis);
                true
            }
        }
        InputEvent::TouchDown {
            event: touch_event, ..
        } => {
            let serial = SERIAL_COUNTER.next_serial();
            let slot = i32::from(touch_event.slot());
            let (position, scene_position, software_keyboard_touch) = {
                let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                frontend.set_pointer_cursor_visible(false);
                let local = touch_event.position_transformed(frontend.touch_bounds.size);
                let position = local + frontend.touch_bounds.loc.to_f64();
                let scene_position = position - frontend.atlas_origin;
                (
                    position,
                    scene_position,
                    software_keyboard_owns_touch(frontend.input_layout.as_ref(), scene_position),
                )
            };
            let native_target = (!secure_locked)
                .then(|| {
                    state.native_app_plugins.as_ref().and_then(|manager| {
                        manager.native_window_at(scene_position.x, scene_position.y)
                    })
                })
                .flatten();
            if let Some(host_id) = native_target {
                let routed = state
                    .native_app_plugins
                    .as_mut()
                    .expect("native touch target lost its plugin manager")
                    .touch_down(
                        host_id,
                        slot,
                        scene_position.x,
                        scene_position.y,
                        touch_event.time_usec().saturating_mul(1_000),
                    );
                if let Err(error) = routed {
                    warn!(%error, host_id, slot, "native application touch-down routing failed");
                    return false;
                }
                let keyboard = state
                    .wayland
                    .as_ref()
                    .expect("missing Wayland frontend")
                    .seat
                    .get_keyboard()
                    .expect("seat has no keyboard");
                keyboard.set_focus(state, Option::<super::KeyboardFocusTarget>::None, serial);
                state
                    .wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .text_input
                    .note_client_touch();
                state
                    .pending_window_events
                    .push(PendingWindowEvent::Activated(host_id));
                state.scene_sync.mark_dirty();
                return false;
            }
            let target = if secure_locked {
                InputTarget::Flutter
            } else {
                state
                    .wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .input_target(position)
            };
            match target {
                InputTarget::Flutter => {
                    let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                    if !software_keyboard_touch {
                        frontend.text_input.note_flutter_touch();
                    }
                    frontend.flutter_touch_slots.insert(slot);
                    state.flutter_input.handle(&event);
                    false
                }
                InputTarget::Client(route) => {
                    let scene_changed = activate_client_route(state, &route, serial);
                    state
                        .wayland
                        .as_mut()
                        .expect("missing Wayland frontend")
                        .text_input
                        .note_client_touch();
                    let focus = route.focus_at(position);
                    let touch = state
                        .wayland
                        .as_ref()
                        .expect("missing Wayland frontend")
                        .seat
                        .get_touch()
                        .expect("seat has no touch");
                    touch.down(
                        state,
                        Some(focus),
                        &DownEvent {
                            slot: touch_event.slot(),
                            location: position,
                            serial,
                            time: touch_event.time_msec(),
                        },
                    );
                    state
                        .wayland
                        .as_mut()
                        .expect("missing Wayland frontend")
                        .client_touch_routes
                        .insert(slot, route);
                    state
                        .wayland
                        .as_mut()
                        .expect("missing Wayland frontend")
                        .client_touch_frame_pending = true;
                    if scene_changed {
                        state.scene_sync.mark_dirty();
                    }
                    true
                }
            }
        }
        InputEvent::TouchMotion {
            event: touch_event, ..
        } => {
            let slot = i32::from(touch_event.slot());
            let (position, scene_position) = {
                let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
                let local = touch_event.position_transformed(frontend.touch_bounds.size);
                let position = local + frontend.touch_bounds.loc.to_f64();
                (position, position - frontend.atlas_origin)
            };
            let native_routed = state.native_app_plugins.as_mut().map(|manager| {
                manager.touch_motion(
                    slot,
                    scene_position.x,
                    scene_position.y,
                    touch_event.time_usec().saturating_mul(1_000),
                )
            });
            match native_routed {
                Some(Ok(true)) => return false,
                Some(Err(error)) => {
                    warn!(%error, slot, "native application touch-motion routing failed");
                    return false;
                }
                Some(Ok(false)) | None => {}
            }
            let flutter_target = state
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .flutter_touch_slots
                .contains(&slot);
            if flutter_target {
                state.flutter_input.handle(&event);
                return false;
            }
            let focus = {
                let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
                frontend
                    .client_touch_routes
                    .get(&slot)
                    .map(|route| route.focus_at(position))
            };
            if let Some(focus) = focus {
                let touch = state
                    .wayland
                    .as_ref()
                    .expect("missing Wayland frontend")
                    .seat
                    .get_touch()
                    .expect("seat has no touch");
                touch.motion(
                    state,
                    Some(focus),
                    &TouchMotionEvent {
                        slot: touch_event.slot(),
                        location: position,
                        time: touch_event.time_msec(),
                    },
                );
                state
                    .wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .client_touch_frame_pending = true;
                true
            } else {
                false
            }
        }
        InputEvent::TouchUp {
            event: touch_event, ..
        } => {
            let slot = i32::from(touch_event.slot());
            let native_routed = state.native_app_plugins.as_mut().map(|manager| {
                manager.touch_up(slot, touch_event.time_usec().saturating_mul(1_000))
            });
            match native_routed {
                Some(Ok(true)) => return false,
                Some(Err(error)) => {
                    warn!(%error, slot, "native application touch-up routing failed");
                    return false;
                }
                Some(Ok(false)) | None => {}
            }
            let flutter_target = state
                .wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .flutter_touch_slots
                .remove(&slot);
            if flutter_target {
                state.flutter_input.handle(&event);
                return false;
            }
            let client_target = state
                .wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .client_touch_routes
                .remove(&slot)
                .is_some();
            if client_target {
                let touch = state
                    .wayland
                    .as_ref()
                    .expect("missing Wayland frontend")
                    .seat
                    .get_touch()
                    .expect("seat has no touch");
                touch.up(
                    state,
                    &UpEvent {
                        slot: touch_event.slot(),
                        serial: SERIAL_COUNTER.next_serial(),
                        time: touch_event.time_msec(),
                    },
                );
                state
                    .wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .client_touch_frame_pending = true;
            }
            client_target
        }
        InputEvent::TouchFrame { .. }
            if std::mem::take(
                &mut state
                    .wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .client_touch_frame_pending,
            ) =>
        {
            let touch = state
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .seat
                .get_touch()
                .expect("seat has no touch");
            touch.frame(state);
            true
        }
        InputEvent::TouchFrame { .. } => false,
        InputEvent::TouchCancel {
            event: touch_event, ..
        } => {
            let slot = i32::from(touch_event.slot());
            let native_routed = state.native_app_plugins.as_mut().map(|manager| {
                manager.touch_cancel(slot, touch_event.time_usec().saturating_mul(1_000))
            });
            match native_routed {
                Some(Ok(true)) => return false,
                Some(Err(error)) => {
                    warn!(%error, slot, "native application touch-cancel routing failed");
                    return false;
                }
                Some(Ok(false)) | None => {}
            }
            let flutter_target = state
                .wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .flutter_touch_slots
                .remove(&slot);
            if flutter_target {
                state.flutter_input.handle(&event);
                false
            } else if state
                .wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .client_touch_routes
                .remove(&slot)
                .is_some()
            {
                let touch = state
                    .wayland
                    .as_ref()
                    .expect("missing Wayland frontend")
                    .seat
                    .get_touch()
                    .expect("seat has no touch");
                touch.cancel(state);
                let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                frontend.client_touch_routes.clear();
                frontend.client_touch_frame_pending = false;
                true
            } else {
                false
            }
        }
        _ => false,
    }
}

#[cfg(feature = "flutter")]
fn deliver_routed_flutter_pointer_motion(state: &mut RuntimeState, target: RoutedPointerTarget) {
    let position = state.compositor_pointer_in_flutter_pixels();
    let Some((x, y)) = position else {
        return;
    };
    match target {
        RoutedPointerTarget::Flutter => state.flutter_input.handle_pointer_motion_at(x, y),
        RoutedPointerTarget::Client(_) => {
            if let Some(frontend) = state.wayland.as_mut() {
                frontend.queue_cursor_position();
            }
            // This is intentionally retried for every client-routed sample.
            // A Flutter-owned drag keeps its Down lifecycle until drop, so the
            // first eligible Remove can occur after the route itself changed.
            state.flutter_input.handle_pointer_leave_at(x, y);
        }
    }
}

#[cfg(feature = "flutter")]
fn route_pointer_motion(
    state: &mut RuntimeState,
    position: Point<f64, Logical>,
    target: PointerMotionTarget,
    time: u32,
    relative: Option<RelativeMotionEvent>,
) -> bool {
    let PointerMotionTarget {
        routed: routed_target,
        focus: under,
    } = target;
    super::clipboard_io::release_deferred_clipboard_capture(
        state,
        under.as_ref().map(|(surface, _)| surface),
    );
    let pointer = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .seat
        .get_pointer()
        .expect("seat has no pointer");
    if under.is_none() && pointer.current_focus().is_none() && !pointer.is_grabbed() {
        // Flutter owns this part of the scene and no Wayland client can
        // observe relative or absolute pointer traffic here. Once the leave
        // edge has cleared Smithay's focus, keep cursor state current without
        // constructing protocol events or consuming a serial per sample.
        {
            let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
            frontend.pointer_location = position;
            frontend.set_routed_pointer_target(routed_target);
        }
        deliver_routed_flutter_pointer_motion(state, routed_target);
        return false;
    }
    let blocked = pointer_constraint_blocks_motion(
        &pointer,
        &under,
        position,
        pointer_constraint_reactivation_suppressed(state, &pointer),
    );
    if let Some(relative) = relative {
        let relative_focus = if blocked {
            pointer
                .current_focus()
                .map(|surface| (surface, Point::from((0.0, 0.0))))
        } else {
            under.clone()
        };
        pointer.relative_motion(state, relative_focus, &relative);
    }
    if blocked {
        pointer.frame(state);
        return true;
    }
    {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        frontend.pointer_location = position;
        frontend.set_routed_pointer_target(routed_target);
    }
    pointer.motion(
        state,
        under,
        &MotionEvent {
            location: position,
            serial: SERIAL_COUNTER.next_serial(),
            time,
        },
    );
    pointer.frame(state);
    deliver_routed_flutter_pointer_motion(state, routed_target);
    true
}

#[cfg(feature = "flutter")]
fn flutter_pointer_endpoint_is_synchronized(
    current: RoutedPointerTarget,
    desired: RoutedPointerTarget,
    lifecycle_active: bool,
    flutter_capture_active: bool,
) -> bool {
    if current != desired {
        return false;
    }
    match desired {
        RoutedPointerTarget::Flutter => lifecycle_active,
        RoutedPointerTarget::Client(_) => !lifecycle_active || flutter_capture_active,
    }
}

#[cfg(feature = "flutter")]
pub(in super::super) fn reconcile_flutter_pointer_route(state: &mut RuntimeState) {
    if !state.flutter_active {
        return;
    }
    let pointer = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .seat
        .get_pointer()
        .expect("seat has no pointer");
    if pointer.is_grabbed() {
        return;
    }
    let secure_locked = state.secure_session_locked();
    let flutter_captured = state.flutter_input.pointer_captured();
    let lifecycle_active = state.flutter_input.mouse_lifecycle_active();
    let (position, target, current_target, time) = {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        let position = frontend.pointer_location;
        let target = if secure_locked || (flutter_captured && !frontend.clipboard_drag_active) {
            PointerMotionTarget::FLUTTER
        } else if let Some(route) = frontend.client_pointer_capture.as_ref() {
            PointerMotionTarget::client(route, position)
        } else {
            frontend.pointer_motion_target(position)
        };
        (
            position,
            target,
            frontend.routed_pointer_target,
            frontend.start_time.elapsed().as_millis() as u32,
        )
    };
    if flutter_pointer_endpoint_is_synchronized(
        current_target,
        target.routed,
        lifecycle_active,
        flutter_captured,
    ) {
        return;
    }
    route_pointer_motion(state, position, target, time, None);
}

fn pointer_constraint_blocks_motion(
    pointer: &PointerHandle<RuntimeState>,
    proposed_focus: &Option<(WlSurface, Point<f64, Logical>)>,
    proposed_location: Point<f64, Logical>,
    reactivation_suppressed: bool,
) -> bool {
    let Some(current_focus) = pointer.current_focus() else {
        return false;
    };
    with_pointer_constraint(&current_focus, pointer, |constraint| {
        let Some(constraint) = constraint else {
            return false;
        };
        if reactivation_suppressed {
            // SUPER+Escape is an explicit user override. Even if Xwayland
            // replaces its constraint before the pointer leaves the game,
            // keep it inactive until a plain click acknowledges re-entry.
            constraint.deactivate();
            return false;
        }
        if !constraint.is_active() {
            // SUPER+A/TAB deliberately deactivates the client's constraint
            // before the shell overlay takes the pointer. Do not immediately
            // reactivate it while motion is trying to leave that surface.
            let remains_on_focused_surface = proposed_focus
                .as_ref()
                .is_some_and(|(surface, _)| surface == &current_focus);
            if !remains_on_focused_surface {
                return false;
            }
            constraint.activate();
        }
        match &*constraint {
            PointerConstraint::Locked(_) => true,
            PointerConstraint::Confined(_) => {
                let Some((surface, origin)) = proposed_focus else {
                    return true;
                };
                if surface != &current_focus {
                    return true;
                }
                constraint.region().is_some_and(|region| {
                    !region.contains((proposed_location - *origin).to_i32_round())
                })
            }
        }
    })
}

fn pointer_constraint_reactivation_suppressed(
    state: &RuntimeState,
    pointer: &PointerHandle<RuntimeState>,
) -> bool {
    #[cfg(feature = "flutter")]
    {
        let Some(surface) = pointer.current_focus() else {
            return false;
        };
        state
            .wayland
            .as_ref()
            .is_some_and(|frontend| frontend.pointer_constraint_released_for_surface(&surface))
    }
    #[cfg(not(feature = "flutter"))]
    {
        let _ = (state, pointer);
        false
    }
}

fn route_pointer_axis<E: PointerAxisEvent<LibinputInputBackend>>(
    state: &mut RuntimeState,
    event: &E,
) {
    let source = event.source();
    let horizontal_amount = event.amount(Axis::Horizontal);
    let vertical_amount = event.amount(Axis::Vertical);
    let horizontal_v120 = event.amount_v120(Axis::Horizontal);
    let vertical_v120 = event.amount_v120(Axis::Vertical);
    let horizontal =
        horizontal_amount.unwrap_or_else(|| horizontal_v120.unwrap_or(0.0) * 15.0 / 120.0);
    let vertical = vertical_amount.unwrap_or_else(|| vertical_v120.unwrap_or(0.0) * 15.0 / 120.0);
    let mut frame = AxisFrame::new(event.time_msec()).source(source);
    if horizontal != 0.0 {
        frame = frame.value(Axis::Horizontal, horizontal);
        if let Some(v120) = horizontal_v120 {
            frame = frame.v120(Axis::Horizontal, v120 as i32);
        }
    }
    if vertical != 0.0 {
        frame = frame.value(Axis::Vertical, vertical);
        if let Some(v120) = vertical_v120 {
            frame = frame.v120(Axis::Vertical, v120 as i32);
        }
    }
    if source == AxisSource::Finger {
        if horizontal_amount == Some(0.0) {
            frame = frame.stop(Axis::Horizontal);
        }
        if vertical_amount == Some(0.0) {
            frame = frame.stop(Axis::Vertical);
        }
    }
    let pointer = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .seat
        .get_pointer()
        .expect("seat has no pointer");
    pointer.axis(state, frame);
    pointer.frame(state);
}

#[cfg(feature = "flutter")]
fn activate_client_route(
    state: &mut RuntimeState,
    route: &ClientInputRoute,
    serial: Serial,
) -> bool {
    let Some(target_window) = route.window.as_ref() else {
        // Input-method candidate surfaces receive pointer/touch input without
        // stealing the keyboard focus from the editor they serve.
        return false;
    };
    if let Some(manager) = state.native_app_plugins.as_mut()
        && let Err(error) = manager.clear_focus()
    {
        warn!(%error, "could not clear native application focus");
    }
    let keyboard = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .seat
        .get_keyboard()
        .expect("seat has no keyboard");
    let scene_changed = {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        let mut changed = frontend.space.elements().next_back() != Some(target_window);
        // Always offer the raise to XWM too: Space may already be correct
        // while Xwayland's independent X stack is stale.
        frontend.raise_window(target_window, true);
        for window in frontend.space.elements() {
            let activation_changed = window.set_activated(window == target_window);
            changed |= activation_changed;
            if activation_changed && let Some(toplevel) = window.toplevel() {
                toplevel.send_pending_configure();
            }
        }
        changed
    };
    let Some(keyboard_focus) = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .keyboard_focus_for_window(target_window)
    else {
        return scene_changed;
    };
    if keyboard.current_focus().as_ref() != Some(&keyboard_focus) {
        keyboard.set_focus(state, Some(keyboard_focus), serial);
        state
            .pending_window_events
            .push(PendingWindowEvent::Activated(route.region.window_id));
    }
    scene_changed
}

#[cfg(feature = "flutter")]
fn release_client_geometry_for_shell_grab(
    state: &mut RuntimeState,
    window: &smithay::desktop::Window,
) {
    let client_constraints_cleared =
        super::window_management::clear_client_geometry_constraints(window);

    let target = {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        let root = frontend.window_root_surface(window);
        let restore = root.as_ref().and_then(|surface| {
            frontend
                .shell_maximize_restore_geometries
                .remove(&surface.id())
                .or_else(|| frontend.restore_window_geometries.remove(&surface.id()))
        });
        if let Some(restore) = restore {
            frontend.set_window_geometry_target(window, restore);
            Some(restore)
        } else if client_constraints_cleared {
            Some(frontend.window_geometry_target(window))
        } else {
            None
        }
    };
    let Some(target) = target else {
        return;
    };
    if let Some(toplevel) = window.toplevel() {
        toplevel.with_pending_state(|pending| pending.size = Some(target.size));
        toplevel.send_pending_configure();
    }
    state.scene_sync.mark_dirty();
}

#[cfg(feature = "flutter")]
fn begin_local_super_pointer_grab(
    state: &mut RuntimeState,
    region: InputWindowRegion,
    action: SuperPointerAction,
    button: u32,
    serial: Serial,
) -> bool {
    if region.geometry_locked() {
        return false;
    }
    let Some((position, geometry)) = state.wayland.as_ref().and_then(|frontend| {
        frontend
            .local_flutter_window_geometry(region.window_id)
            .map(|geometry| (frontend.pointer_location, geometry))
    }) else {
        return false;
    };
    if !super::window_management::activate_local_flutter_window(state, region.window_id) {
        return false;
    }
    super::window_management::queue_local_flutter_window_placement(
        state,
        region.window_id,
        WindowPlacementPhase::Begin,
        match action {
            SuperPointerAction::Move => WindowPlacementChange::Move,
            SuperPointerAction::Resize => WindowPlacementChange::Resize,
        },
    );
    let start_data = GrabStartData {
        focus: None,
        button,
        location: position,
    };
    let grab = match action {
        SuperPointerAction::Move => {
            LocalFlutterWindowGrab::new_move(start_data, region.window_id, geometry)
        }
        SuperPointerAction::Resize => {
            let global_geometry = Rectangle::new(
                Point::from((geometry.x.round() as i32, geometry.y.round() as i32)),
                (
                    geometry.width.round() as i32,
                    geometry.height.round() as i32,
                )
                    .into(),
            );
            let edge = resize_edge_for_geometry(position, global_geometry);
            let edges = ResizeEdges::from_xdg(edge).expect("corner is a valid resize edge");
            LocalFlutterWindowGrab::new_resize(start_data, region.window_id, geometry, edges)
        }
    };
    state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .seat
        .get_pointer()
        .expect("seat has no pointer")
        .set_grab(state, grab, serial, Focus::Clear);
    true
}

#[cfg(feature = "flutter")]
fn begin_super_pointer_grab(
    state: &mut RuntimeState,
    route: &ClientInputRoute,
    action: SuperPointerAction,
    button: u32,
    serial: Serial,
) -> bool {
    let Some(window) = route.window.clone() else {
        return false;
    };
    // Match the C++ compositor contract: only Flutter's shell-fullscreen lock
    // suppresses SUPER+LMB/RMB. Client XDG/EWMH state is released so a game can
    // be pulled out of its own maximize/fullscreen state by the compositor.
    if route.region.geometry_locked() {
        return false;
    }
    release_client_geometry_for_shell_grab(state, &window);
    let (position, initial_location, geometry) = {
        let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
        (
            frontend.pointer_location,
            frontend.space.element_location(&window).unwrap_or_default(),
            frontend.window_geometry_target(&window),
        )
    };
    let start_data = GrabStartData {
        focus: Some(route.focus_at(position)),
        button,
        location: position,
    };

    activate_client_route(state, route, serial);
    let pointer = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .seat
        .get_pointer()
        .expect("seat has no pointer");
    match action {
        SuperPointerAction::Move => {
            super::queue_window_placement(
                state,
                &window,
                geometry,
                WindowPlacementPhase::Begin,
                WindowPlacementChange::Move,
            );
            pointer.set_grab(
                state,
                MoveSurfaceGrab::new_compositor(start_data, window, initial_location),
                serial,
                Focus::Clear,
            );
        }
        SuperPointerAction::Resize => {
            let edge = resize_edge_for_geometry(position, geometry);
            let edges = ResizeEdges::from_xdg(edge).expect("corner is a valid resize edge");
            super::queue_window_placement(
                state,
                &window,
                geometry,
                WindowPlacementPhase::Begin,
                WindowPlacementChange::Resize,
            );
            if let Some(toplevel) = window.toplevel().cloned() {
                toplevel.with_pending_state(|pending| {
                    pending.states.set(xdg_toplevel::State::Resizing);
                });
                toplevel.send_pending_configure();
                pointer.set_grab(
                    state,
                    ResizeSurfaceGrab::new_compositor(
                        start_data,
                        window,
                        toplevel,
                        edges,
                        initial_location,
                        geometry.size,
                    ),
                    serial,
                    Focus::Clear,
                );
            } else if let Some(x11) = window.x11_surface().cloned() {
                pointer.set_grab(
                    state,
                    X11ResizeSurfaceGrab::new_compositor(start_data, window, x11, edges, geometry),
                    serial,
                    Focus::Clear,
                );
            } else {
                return false;
            }
        }
    }
    true
}

fn process_wayland_keyboard_transition(
    state: &mut RuntimeState,
    keycode: Keycode,
    key_state: KeyState,
    time: u32,
) {
    let keyboard = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .seat
        .get_keyboard()
        .expect("seat has no keyboard");
    let consume_retired = retired_key_consumes_transition(
        &mut state
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .retired_keyboard_keys,
        keycode.raw(),
        key_state,
    );
    keyboard.input::<(), _>(
        state,
        keycode,
        key_state,
        SERIAL_COUNTER.next_serial(),
        time,
        move |_, _, _| {
            if consume_retired {
                FilterResult::Intercept(())
            } else {
                FilterResult::Forward
            }
        },
    );
    #[cfg(feature = "flutter")]
    synchronize_active_keyboard_layout(state, &keyboard);
}

fn process_wayland_input_event(state: &mut RuntimeState, event: InputEvent<LibinputInputBackend>) {
    match event {
        InputEvent::Keyboard { event, .. } => process_wayland_keyboard_transition(
            state,
            event.key_code(),
            event.state(),
            event.time_msec(),
        ),
        InputEvent::PointerMotion { event, .. } => {
            let (position, under) = {
                let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                let position = frontend.clamp_pointer(frontend.pointer_location + event.delta());
                (position, frontend.surface_under(position))
            };
            let pointer = state
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .seat
                .get_pointer()
                .expect("seat has no pointer");
            let blocked = pointer_constraint_blocks_motion(
                &pointer,
                &under,
                position,
                pointer_constraint_reactivation_suppressed(state, &pointer),
            );
            pointer.relative_motion(
                state,
                if blocked {
                    pointer
                        .current_focus()
                        .map(|surface| (surface, Point::from((0.0, 0.0))))
                } else {
                    under.clone()
                },
                &RelativeMotionEvent {
                    delta: event.delta(),
                    delta_unaccel: event.delta_unaccel(),
                    utime: event.time_usec(),
                },
            );
            if blocked {
                pointer.frame(state);
                return;
            }
            state
                .wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .pointer_location = position;
            pointer.motion(
                state,
                under,
                &MotionEvent {
                    location: position,
                    serial: SERIAL_COUNTER.next_serial(),
                    time: event.time_msec(),
                },
            );
            pointer.frame(state);
        }
        InputEvent::PointerMotionAbsolute { event, .. } => {
            let (position, under) = {
                let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                let local = event.position_transformed(frontend.desktop_bounds.size);
                let position = local + frontend.desktop_bounds.loc.to_f64();
                (position, frontend.surface_under(position))
            };
            let pointer = state
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .seat
                .get_pointer()
                .expect("seat has no pointer");
            if pointer_constraint_blocks_motion(
                &pointer,
                &under,
                position,
                pointer_constraint_reactivation_suppressed(state, &pointer),
            ) {
                pointer.frame(state);
                return;
            }
            state
                .wayland
                .as_mut()
                .expect("missing Wayland frontend")
                .pointer_location = position;
            pointer.motion(
                state,
                under,
                &MotionEvent {
                    location: position,
                    serial: SERIAL_COUNTER.next_serial(),
                    time: event.time_msec(),
                },
            );
            pointer.frame(state);
        }
        InputEvent::PointerButton { event, .. } => {
            let serial = SERIAL_COUNTER.next_serial();
            #[cfg(feature = "flutter")]
            if retired_pointer_button_consumes_transition(
                &mut state
                    .wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .retired_pointer_buttons,
                event.button_code(),
                event.state(),
            ) {
                return;
            }
            let pointer = state
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .seat
                .get_pointer()
                .expect("seat has no pointer");
            let keyboard = state
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .seat
                .get_keyboard()
                .expect("seat has no keyboard");

            if event.state() == ButtonState::Pressed && !pointer.is_grabbed() {
                let window = state
                    .wayland
                    .as_ref()
                    .expect("missing Wayland frontend")
                    .space
                    .element_under(pointer.current_location())
                    .map(|(window, _)| window.clone());
                if let Some(window) = window {
                    #[cfg(feature = "flutter")]
                    {
                        let window_id = state
                            .wayland
                            .as_ref()
                            .expect("missing Wayland frontend")
                            .window_root_surface(&window)
                            .and_then(|surface| {
                                state
                                    .wayland
                                    .as_ref()
                                    .expect("missing Wayland frontend")
                                    .surface_id(&surface)
                            });
                        if let Some(window_id) = window_id {
                            state
                                .wayland
                                .as_mut()
                                .expect("missing Wayland frontend")
                                .pointer_constraint_escape
                                .resume_window(window_id);
                        }
                    }
                    let focus = state
                        .wayland
                        .as_ref()
                        .expect("missing Wayland frontend")
                        .keyboard_focus_for_window(&window);
                    let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                    frontend.raise_window(&window, true);
                    for candidate in frontend.space.elements() {
                        let changed = candidate.set_activated(candidate == &window);
                        if changed && let Some(toplevel) = candidate.toplevel() {
                            toplevel.send_pending_configure();
                        }
                    }
                    keyboard.set_focus(state, focus, serial);
                } else {
                    keyboard.set_focus(state, Option::<super::KeyboardFocusTarget>::None, serial);
                }
            }

            update_pressed_buttons(
                &mut state
                    .wayland
                    .as_mut()
                    .expect("missing Wayland frontend")
                    .wayland_pointer_buttons,
                event.button_code(),
                event.state(),
            );
            pointer.button(
                state,
                &ButtonEvent {
                    button: event.button_code(),
                    state: event.state(),
                    serial,
                    time: event.time_msec(),
                },
            );
            pointer.frame(state);
            state.scene_sync.mark_dirty();
        }
        InputEvent::PointerAxis { event, .. } => route_pointer_axis(state, &event),
        InputEvent::TouchDown { event, .. } => {
            let serial = SERIAL_COUNTER.next_serial();
            let (position, window) = {
                let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
                let local = event.position_transformed(frontend.touch_bounds.size);
                let position = local + frontend.touch_bounds.loc.to_f64();
                let window = frontend
                    .space
                    .element_under(position)
                    .map(|(window, _)| window.clone());
                (position, window)
            };
            let (touch, keyboard) = {
                let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
                (
                    frontend.seat.get_touch().expect("seat has no touch"),
                    frontend.seat.get_keyboard().expect("seat has no keyboard"),
                )
            };

            if let Some(window) = window {
                let focus = state
                    .wayland
                    .as_ref()
                    .expect("missing Wayland frontend")
                    .keyboard_focus_for_window(&window);
                let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                frontend.raise_window(&window, true);
                for candidate in frontend.space.elements() {
                    let changed = candidate.set_activated(candidate == &window);
                    if changed && let Some(toplevel) = candidate.toplevel() {
                        toplevel.send_pending_configure();
                    }
                }
                keyboard.set_focus(state, focus, serial);
            } else {
                keyboard.set_focus(state, Option::<super::KeyboardFocusTarget>::None, serial);
            }

            let under = state
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .surface_under(position);
            touch.down(
                state,
                under,
                &DownEvent {
                    slot: event.slot(),
                    location: position,
                    serial,
                    time: event.time_msec(),
                },
            );
            state.scene_sync.mark_dirty();
        }
        InputEvent::TouchMotion { event, .. } => {
            let (position, under) = {
                let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
                let local = event.position_transformed(frontend.touch_bounds.size);
                let position = local + frontend.touch_bounds.loc.to_f64();
                (position, frontend.surface_under(position))
            };
            let touch = state
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .seat
                .get_touch()
                .expect("seat has no touch");
            touch.motion(
                state,
                under,
                &TouchMotionEvent {
                    slot: event.slot(),
                    location: position,
                    time: event.time_msec(),
                },
            );
        }
        InputEvent::TouchUp { event, .. } => {
            let touch = state
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .seat
                .get_touch()
                .expect("seat has no touch");
            touch.up(
                state,
                &UpEvent {
                    slot: event.slot(),
                    serial: SERIAL_COUNTER.next_serial(),
                    time: event.time_msec(),
                },
            );
        }
        InputEvent::TouchFrame { .. } => {
            let touch = state
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .seat
                .get_touch()
                .expect("seat has no touch");
            touch.frame(state);
        }
        InputEvent::TouchCancel { .. } => {
            let touch = state
                .wayland
                .as_ref()
                .expect("missing Wayland frontend")
                .seat
                .get_touch()
                .expect("seat has no touch");
            touch.cancel(state);
        }
        _ => {}
    }
}

#[cfg(test)]
mod software_keyboard_touch_tests {
    use super::*;

    #[cfg(feature = "flutter")]
    #[test]
    fn only_published_software_keyboard_regions_preserve_an_editor() {
        let mut layout = InputLayoutSnapshot::default();
        layout.software_keyboard_regions.push(InputRect {
            x: 0.0,
            y: 700.0,
            width: 400.0,
            height: 300.0,
        });

        assert!(software_keyboard_owns_touch(
            Some(&layout),
            Point::from((200.0, 800.0)),
        ));
        assert!(!software_keyboard_owns_touch(
            Some(&layout),
            Point::from((200.0, 100.0)),
        ));
        assert!(!software_keyboard_owns_touch(
            None,
            Point::from((200.0, 800.0)),
        ));
    }
}

#[cfg(test)]
mod native_escape_tests {
    use super::*;

    #[cfg(feature = "flutter")]
    const XKB_ESCAPE: u32 = 1 + 8;
    const XKB_LEFT_CTRL: u32 = 29 + 8;
    const XKB_LEFT_ALT: u32 = 56 + 8;
    const XKB_BACKSPACE: u32 = 14 + 8;
    #[cfg(feature = "flutter")]
    const XKB_TAB: u32 = 15 + 8;
    #[cfg(feature = "flutter")]
    const XKB_A: u32 = 30 + 8;
    #[cfg(feature = "flutter")]
    const XKB_S: u32 = 31 + 8;
    #[cfg(feature = "flutter")]
    const XKB_LEFT_SHIFT: u32 = 42 + 8;
    #[cfg(feature = "flutter")]
    const XKB_LEFT_META: u32 = 125 + 8;

    fn input(runtime: &mut RuntimeState, keycode: u32, state: KeyState) -> bool {
        intercept_native_escape(runtime, keycode, state)
    }

    #[test]
    fn native_escape_requests_graceful_lifecycle_shutdown_and_is_consumed() {
        let mut runtime = RuntimeState {
            native_escape_shortcut: NativeEscapeShortcut::default(),
            lifecycle: LifecycleState::default(),
            ..RuntimeState::default()
        };

        assert!(!input(&mut runtime, XKB_LEFT_CTRL, KeyState::Pressed));
        assert!(!input(&mut runtime, XKB_LEFT_ALT, KeyState::Pressed));
        assert!(input(&mut runtime, XKB_BACKSPACE, KeyState::Pressed));
        assert_eq!(
            runtime.lifecycle.shutdown_reason(),
            Some(ShutdownReason::NativeEscapeShortcut)
        );
    }

    #[test]
    fn ordinary_backspace_remains_available_to_clients() {
        let mut runtime = RuntimeState {
            native_escape_shortcut: NativeEscapeShortcut::default(),
            lifecycle: LifecycleState::default(),
            ..RuntimeState::default()
        };

        assert!(!input(&mut runtime, XKB_BACKSPACE, KeyState::Pressed));
        assert_eq!(runtime.lifecycle.shutdown_reason(), None);
    }

    #[cfg(feature = "flutter")]
    #[test]
    fn super_escape_is_consumed_even_without_an_active_client() {
        let mut runtime = RuntimeState::default();

        assert!(input(&mut runtime, XKB_LEFT_META, KeyState::Pressed));
        assert!(input(&mut runtime, XKB_ESCAPE, KeyState::Pressed));
        assert!(input(&mut runtime, XKB_ESCAPE, KeyState::Pressed));
        assert!(input(&mut runtime, XKB_LEFT_META, KeyState::Released));
        assert!(input(&mut runtime, XKB_ESCAPE, KeyState::Released));
    }

    #[cfg(feature = "flutter")]
    #[test]
    fn native_shell_chords_queue_the_cpp_equivalent_actions() {
        let mut runtime = RuntimeState::default();

        assert!(input(&mut runtime, XKB_LEFT_META, KeyState::Pressed));
        assert!(input(&mut runtime, XKB_A, KeyState::Pressed));
        assert!(input(&mut runtime, XKB_A, KeyState::Released));
        assert!(input(&mut runtime, XKB_LEFT_META, KeyState::Released));
        assert_eq!(
            runtime.pending_shell_actions.pop_front(),
            Some((super::super::super::wire::ShellAction::Overview, None))
        );

        assert!(!input(&mut runtime, XKB_LEFT_SHIFT, KeyState::Pressed));
        assert!(input(&mut runtime, XKB_LEFT_META, KeyState::Pressed));
        assert!(input(&mut runtime, XKB_S, KeyState::Pressed));
        assert!(input(&mut runtime, XKB_S, KeyState::Released));
        assert!(input(&mut runtime, XKB_LEFT_META, KeyState::Released));
        assert!(!input(&mut runtime, XKB_LEFT_SHIFT, KeyState::Released));
        assert!(runtime.pending_shell_actions.is_empty());
        assert_eq!(runtime.pending_screenshot_selection, None);
        runtime.request_screenshot_selection(Some(12));
        assert_eq!(
            runtime.pending_screenshot_selection,
            Some(denial_core::topology::OutputId(12))
        );
        runtime.pending_screenshot_selection = None;

        assert!(input(&mut runtime, XKB_LEFT_META, KeyState::Pressed));
        assert!(input(&mut runtime, XKB_TAB, KeyState::Pressed));
        assert!(input(&mut runtime, XKB_TAB, KeyState::Released));
        assert!(input(&mut runtime, XKB_TAB, KeyState::Pressed));
        assert!(input(&mut runtime, XKB_LEFT_META, KeyState::Released));
        assert!(input(&mut runtime, XKB_TAB, KeyState::Pressed));
        assert!(input(&mut runtime, XKB_TAB, KeyState::Released));
        assert_eq!(
            runtime.pending_shell_actions.pop_front(),
            Some((
                super::super::super::wire::ShellAction::WindowSwitcherNext,
                None,
            ))
        );
        assert_eq!(
            runtime.pending_shell_actions.pop_front(),
            Some((
                super::super::super::wire::ShellAction::WindowSwitcherNext,
                None,
            ))
        );
        assert_eq!(
            runtime.pending_shell_actions.pop_front(),
            Some((
                super::super::super::wire::ShellAction::WindowSwitcherEnd,
                None,
            ))
        );
        assert!(runtime.pending_shell_actions.is_empty());
    }
}

#[cfg(all(test, feature = "flutter"))]
mod pointer_constraint_escape_tests {
    use super::*;

    #[test]
    fn only_a_click_on_the_released_window_allows_recapture() {
        let mut escape = PointerConstraintEscape::default();
        escape.release_window(41);

        assert!(escape.suppresses_window(41));
        assert!(!escape.resume_window(99));
        assert!(escape.suppresses_window(41));
        assert!(escape.resume_window(41));
        assert!(!escape.suppresses_window(41));
    }

    #[test]
    fn cancelled_pointer_button_release_is_consumed_once() {
        let mut retired = HashSet::from([BTN_LEFT]);

        assert!(retired_pointer_button_consumes_transition(
            &mut retired,
            BTN_LEFT,
            ButtonState::Pressed,
        ));
        assert!(retired_pointer_button_consumes_transition(
            &mut retired,
            BTN_LEFT,
            ButtonState::Released,
        ));
        assert!(!retired_pointer_button_consumes_transition(
            &mut retired,
            BTN_LEFT,
            ButtonState::Released,
        ));
    }
}

#[cfg(all(test, feature = "flutter"))]
mod compositor_pointer_binding_tests {
    use super::*;

    #[test]
    fn shell_keyboard_maps_its_visual_us_layout_to_evdev_strokes() {
        assert_eq!(
            shell_text_key_stroke('a'),
            Some(ShellKeyStroke {
                evdev_keycode: 30,
                shift: false,
            })
        );
        assert_eq!(
            shell_text_key_stroke('A'),
            Some(ShellKeyStroke {
                evdev_keycode: 30,
                shift: true,
            })
        );
        assert_eq!(
            shell_text_key_stroke('?'),
            Some(ShellKeyStroke {
                evdev_keycode: 53,
                shift: true,
            })
        );
        assert_eq!(
            shell_named_key_stroke("BackSpace"),
            Some(ShellKeyStroke {
                evdev_keycode: 14,
                shift: false,
            })
        );
        assert_eq!(shell_text_key_stroke('😀'), None);
        assert_eq!(shell_named_key_stroke("unsupported"), None);
    }

    #[test]
    fn held_shell_keys_are_balanced_and_never_claim_physical_keys() {
        let mut held = HashSet::new();
        let backspace = 22;

        assert!(route_shell_key_transition(
            &mut held,
            backspace,
            KeyState::Pressed,
            false,
        ));
        assert!(!route_shell_key_transition(
            &mut held,
            backspace,
            KeyState::Pressed,
            true,
        ));
        assert!(route_shell_key_transition(
            &mut held,
            backspace,
            KeyState::Released,
            true,
        ));
        assert!(!route_shell_key_transition(
            &mut held,
            backspace,
            KeyState::Released,
            false,
        ));

        assert!(!route_shell_key_transition(
            &mut held,
            backspace,
            KeyState::Pressed,
            true,
        ));
        assert!(held.is_empty());
    }

    #[test]
    fn super_left_moves_and_super_right_resizes() {
        assert_eq!(
            super_pointer_action(true, BTN_LEFT),
            Some(SuperPointerAction::Move)
        );
        assert_eq!(
            super_pointer_action(true, BTN_RIGHT),
            Some(SuperPointerAction::Resize)
        );
        assert_eq!(super_pointer_action(false, BTN_LEFT), None);
        assert_eq!(super_pointer_action(true, 0x112), None);
    }

    #[test]
    fn resize_corner_follows_pointer_quadrant() {
        let geometry = Rectangle::new((100, 200).into(), (800, 600).into());
        assert_eq!(
            resize_edge_for_geometry((101.0, 201.0).into(), geometry),
            xdg_toplevel::ResizeEdge::TopLeft
        );
        assert_eq!(
            resize_edge_for_geometry((899.0, 201.0).into(), geometry),
            xdg_toplevel::ResizeEdge::TopRight
        );
        assert_eq!(
            resize_edge_for_geometry((101.0, 799.0).into(), geometry),
            xdg_toplevel::ResizeEdge::BottomLeft
        );
        assert_eq!(
            resize_edge_for_geometry((899.0, 799.0).into(), geometry),
            xdg_toplevel::ResizeEdge::BottomRight
        );
    }
}

#[cfg(all(test, feature = "flutter"))]
mod flutter_pointer_endpoint_tests {
    use super::*;

    #[test]
    fn route_identity_alone_cannot_mask_a_missing_flutter_lifecycle() {
        assert!(!flutter_pointer_endpoint_is_synchronized(
            RoutedPointerTarget::Flutter,
            RoutedPointerTarget::Flutter,
            false,
            false,
        ));
        assert!(flutter_pointer_endpoint_is_synchronized(
            RoutedPointerTarget::Flutter,
            RoutedPointerTarget::Flutter,
            true,
            false,
        ));
    }

    #[test]
    fn client_routes_remove_flutter_after_capture_releases() {
        let client = RoutedPointerTarget::Client(42);
        assert!(flutter_pointer_endpoint_is_synchronized(
            client, client, true, true,
        ));
        assert!(!flutter_pointer_endpoint_is_synchronized(
            client, client, true, false,
        ));
        assert!(flutter_pointer_endpoint_is_synchronized(
            client, client, false, false,
        ));
    }
}

#[cfg(all(test, feature = "flutter"))]
mod flutter_key_lifecycle_tests {
    use super::*;

    #[test]
    fn repeated_flutter_key_preserves_the_retained_xkb_keycode() {
        const XKB_BACKSPACE: u32 = 22;

        let keycode = retained_flutter_xkb_keycode(XKB_BACKSPACE);

        assert_eq!(keycode.raw(), XKB_BACKSPACE);
        assert_eq!(keycode.raw().saturating_sub(8), 14);
    }

    #[test]
    fn compose_and_dead_keys_emit_only_the_completed_unicode_scalar() {
        let context = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
        let table = xkb::compose::Table::new_from_locale(
            &context,
            std::ffi::OsStr::new("C.UTF-8"),
            xkb::compose::COMPILE_NO_FLAGS,
        )
        .expect("C.UTF-8 Compose table");
        let mut compose = xkb::compose::State::new(&table, xkb::compose::STATE_NO_FLAGS);

        assert_eq!(
            flutter_unicode_for_keysym(
                Some(&mut compose),
                xkb::Keysym::new(xkb::keysyms::KEY_dead_acute),
            ),
            0
        );
        assert_eq!(
            flutter_unicode_for_keysym(Some(&mut compose), xkb::Keysym::new(xkb::keysyms::KEY_e),),
            u32::from('é')
        );
    }

    #[test]
    fn retired_generation_consumes_repeat_and_release_before_reuse() {
        let mut active = HashSet::new();
        let mut retired = HashSet::new();
        let keycode = 38;

        assert_eq!(
            route_flutter_key_transition(
                &mut active,
                &mut retired,
                keycode,
                KeyState::Pressed,
                true,
            ),
            FlutterKeyDisposition::Dispatch
        );
        retire_flutter_generation_keys(&mut active, &mut retired);
        assert!(active.is_empty());
        assert!(retired.contains(&keycode));

        assert_eq!(
            route_flutter_key_transition(
                &mut active,
                &mut retired,
                keycode,
                KeyState::Pressed,
                false,
            ),
            FlutterKeyDisposition::ConsumeRetired
        );
        assert_eq!(
            route_flutter_key_transition(
                &mut active,
                &mut retired,
                keycode,
                KeyState::Released,
                false,
            ),
            FlutterKeyDisposition::ConsumeRetired
        );
        assert!(retired.is_empty());
        assert_eq!(
            route_flutter_key_transition(
                &mut active,
                &mut retired,
                keycode,
                KeyState::Pressed,
                false,
            ),
            FlutterKeyDisposition::Forward
        );
    }

    #[test]
    fn current_generation_keeps_key_ownership_until_release() {
        let mut active = HashSet::new();
        let mut retired = HashSet::new();
        let keycode = 38;

        assert_eq!(
            route_flutter_key_transition(
                &mut active,
                &mut retired,
                keycode,
                KeyState::Pressed,
                true,
            ),
            FlutterKeyDisposition::Dispatch
        );
        assert_eq!(
            route_flutter_key_transition(
                &mut active,
                &mut retired,
                keycode,
                KeyState::Pressed,
                false,
            ),
            FlutterKeyDisposition::Dispatch
        );
        assert_eq!(
            route_flutter_key_transition(
                &mut active,
                &mut retired,
                keycode,
                KeyState::Released,
                false,
            ),
            FlutterKeyDisposition::Dispatch
        );
        assert!(active.is_empty());
    }
}
