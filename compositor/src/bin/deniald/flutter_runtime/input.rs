//! Bounded compositor-to-Flutter input ingress.

use super::*;

const APPLICATION_WHEEL_SCROLL_PIXELS: f64 = 120.0;
const WHEEL_ANGLE_PER_STEP: f64 = 15.0;
const V120_UNITS_PER_WHEEL_STEP: f64 = 120.0;
const MAX_QUEUED_INPUT_EVENTS: usize = 4096;

#[derive(Clone, Copy, Debug)]
pub(super) struct PointerRecord {
    pub(super) phase: sys::FlutterPointerPhase,
    pub(super) x: f64,
    pub(super) y: f64,
    pub(super) device: i32,
    pub(super) signal_kind: sys::FlutterPointerSignalKind,
    pub(super) scroll_x: f64,
    pub(super) scroll_y: f64,
    pub(super) device_kind: sys::FlutterPointerDeviceKind,
    pub(super) buttons: i64,
    /// True only for position samples which can be superseded before Flutter
    /// observes them. Button transitions can also use Flutter's `Move` phase,
    /// so deriving this from `phase` would occasionally lose state changes.
    pub(super) replaceable_motion: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct KeyboardRecord {
    pub(super) keycode: u32,
    pub(super) unicode: u32,
    pub(super) modifiers: u32,
    pub(super) pressed: bool,
}

#[derive(Clone, Copy, Debug)]
pub(super) enum InputRecord {
    Pointer(PointerRecord),
    Keyboard(KeyboardRecord),
}

pub(super) fn flutter_application_scroll_delta(
    amount: Option<f64>,
    v120: Option<f64>,
    source: AxisSource,
    scroll_speed_factor: f64,
) -> f64 {
    // Wayland applications receive axis metadata and normalize a wheel click
    // into their standard scroll step. Flutter receives only a pixel delta,
    // so perform that wheel normalization here. Finger and continuous input
    // already use motion-equivalent units and must remain one-to-one.
    let delta = if let Some(value) = v120 {
        value * APPLICATION_WHEEL_SCROLL_PIXELS / V120_UNITS_PER_WHEEL_STEP
    } else if matches!(source, AxisSource::Wheel | AxisSource::WheelTilt) {
        amount.unwrap_or(0.0) * APPLICATION_WHEEL_SCROLL_PIXELS / WHEEL_ANGLE_PER_STEP
    } else {
        amount.unwrap_or(0.0)
    };
    if source == AxisSource::Finger {
        delta * scroll_speed_factor
    } else {
        delta
    }
}

pub(super) fn flutter_physical_scroll_delta(logical_delta: f64, device_pixel_ratio: f64) -> f64 {
    // FlutterPointerEvent uses physical pixels and Flutter divides this value
    // by the view's device-pixel ratio. Scale the application-reference
    // logical amount here so shell and client scroll distances remain equal
    // on both integer and fractional-scale outputs.
    logical_delta * device_pixel_ratio
}

#[derive(Debug)]
pub struct InputQueue {
    pub(super) size: Size<i32, Logical>,
    pub(super) pointer_x: f64,
    pub(super) pointer_y: f64,
    pub(super) pointer_buttons: i64,
    pub(super) mouse_added: bool,
    pub(super) touch_positions: HashMap<i32, (f64, f64)>,
    pub(super) events: VecDeque<InputRecord>,
}

impl Default for InputQueue {
    fn default() -> Self {
        Self::new(PixelSize::new(1, 1))
    }
}

impl InputQueue {
    pub fn new(size: PixelSize) -> Self {
        let width = i32::try_from(size.width).unwrap_or(i32::MAX).max(1);
        let height = i32::try_from(size.height).unwrap_or(i32::MAX).max(1);
        Self {
            size: (width, height).into(),
            pointer_x: f64::from(width) / 2.0,
            pointer_y: f64::from(height) / 2.0,
            pointer_buttons: 0,
            mouse_added: false,
            touch_positions: HashMap::with_capacity(10),
            events: VecDeque::with_capacity(64),
        }
    }

    pub fn resize(&mut self, size: PixelSize) {
        let width = i32::try_from(size.width).unwrap_or(i32::MAX).max(1);
        let height = i32::try_from(size.height).unwrap_or(i32::MAX).max(1);
        self.size = (width, height).into();
        self.pointer_x = self.pointer_x.clamp(0.0, f64::from(width));
        self.pointer_y = self.pointer_y.clamp(0.0, f64::from(height));
        // This resize follows a full Flutter engine restart during a topology
        // transaction. The new engine has observed no device lifecycle yet,
        // so retaining Add/Down state from the retired generation would make
        // its first pointer packet invalid. Preserve only the physical
        // position and let subsequent input establish a fresh lifecycle.
        self.pointer_buttons = 0;
        self.mouse_added = false;
        self.events.clear();
        self.touch_positions.clear();
    }

    /// Updates the desktop bounds without synthesizing a new input device
    /// generation. Transform-only topology changes keep the engine alive, so
    /// pressed buttons and touch contacts must remain coherent.
    pub fn resize_preserving_state(&mut self, size: PixelSize) {
        let width = i32::try_from(size.width).unwrap_or(i32::MAX).max(1);
        let height = i32::try_from(size.height).unwrap_or(i32::MAX).max(1);
        self.size = (width, height).into();
        self.pointer_x = self.pointer_x.clamp(0.0, f64::from(width));
        self.pointer_y = self.pointer_y.clamp(0.0, f64::from(height));
        for position in self.touch_positions.values_mut() {
            position.0 = position.0.clamp(0.0, f64::from(width));
            position.1 = position.1.clamp(0.0, f64::from(height));
        }
    }

    pub fn has_pending(&self) -> bool {
        !self.events.is_empty()
    }

    pub fn handle(&mut self, event: &SmithayInputEvent<LibinputInputBackend>) {
        self.handle_with_scroll_speed_factor(event, 1.0);
    }

    pub fn handle_with_scroll_speed_factor(
        &mut self,
        event: &SmithayInputEvent<LibinputInputBackend>,
        scroll_speed_factor: f64,
    ) {
        match event {
            // Mouse motion must enter through `handle_pointer_motion_at`.
            // Libinput deltas are not an absolute-position authority: the
            // compositor may clamp, confine, lock, or warp the pointer before
            // Flutter observes it. Integrating them here would make Flutter's
            // hit-test position drift away from the Wayland seat.
            SmithayInputEvent::PointerMotion { .. }
            | SmithayInputEvent::PointerMotionAbsolute { .. } => {}
            SmithayInputEvent::PointerButton { event, .. } => {
                let Some(mask) = mouse_button_mask(event.button_code()) else {
                    return;
                };
                self.ensure_mouse_added();
                let was_pressed = self.pointer_buttons != 0;
                match event.state() {
                    ButtonState::Pressed => self.pointer_buttons |= mask,
                    ButtonState::Released => self.pointer_buttons &= !mask,
                }
                let is_pressed = self.pointer_buttons != 0;
                self.push_mouse(
                    match (was_pressed, is_pressed) {
                        (false, true) => sys::FlutterPointerPhase_kDown,
                        (true, false) => sys::FlutterPointerPhase_kUp,
                        _ => sys::FlutterPointerPhase_kMove,
                    },
                    false,
                );
            }
            SmithayInputEvent::PointerAxis { event, .. } => {
                self.ensure_mouse_added();
                let scroll_x = flutter_application_scroll_delta(
                    event.amount(Axis::Horizontal),
                    event.amount_v120(Axis::Horizontal),
                    event.source(),
                    scroll_speed_factor,
                );
                let scroll_y = flutter_application_scroll_delta(
                    event.amount(Axis::Vertical),
                    event.amount_v120(Axis::Vertical),
                    event.source(),
                    scroll_speed_factor,
                );
                if scroll_x != 0.0 || scroll_y != 0.0 {
                    self.push(InputRecord::Pointer(PointerRecord {
                        phase: if self.pointer_buttons == 0 {
                            sys::FlutterPointerPhase_kHover
                        } else {
                            sys::FlutterPointerPhase_kMove
                        },
                        x: self.pointer_x,
                        y: self.pointer_y,
                        device: 0,
                        signal_kind: sys::FlutterPointerSignalKind_kFlutterPointerSignalKindScroll,
                        scroll_x,
                        scroll_y,
                        device_kind: sys::FlutterPointerDeviceKind_kFlutterPointerDeviceKindMouse,
                        buttons: self.pointer_buttons,
                        replaceable_motion: false,
                    }));
                }
            }
            SmithayInputEvent::TouchDown { event, .. } => {
                let position = event.position_transformed(self.size);
                let device = touch_device(event.slot());
                self.touch_positions
                    .insert(device, (position.x, position.y));
                self.push_touch(
                    sys::FlutterPointerPhase_kAdd,
                    position.x,
                    position.y,
                    device,
                    false,
                );
                self.push_touch(
                    sys::FlutterPointerPhase_kDown,
                    position.x,
                    position.y,
                    device,
                    false,
                );
            }
            SmithayInputEvent::TouchMotion { event, .. } => {
                let position = event.position_transformed(self.size);
                let device = touch_device(event.slot());
                self.touch_positions
                    .insert(device, (position.x, position.y));
                self.push_touch(
                    sys::FlutterPointerPhase_kMove,
                    position.x,
                    position.y,
                    device,
                    true,
                );
            }
            SmithayInputEvent::TouchUp { event, .. } => {
                let device = touch_device(event.slot());
                let (x, y) = self.touch_positions.remove(&device).unwrap_or((0.0, 0.0));
                self.push_touch(sys::FlutterPointerPhase_kUp, x, y, device, false);
                self.push_touch(sys::FlutterPointerPhase_kRemove, x, y, device, false);
            }
            SmithayInputEvent::TouchCancel { event, .. } => {
                let device = touch_device(event.slot());
                let (x, y) = self.touch_positions.remove(&device).unwrap_or((0.0, 0.0));
                self.push_touch(sys::FlutterPointerPhase_kCancel, x, y, device, false);
                self.push_touch(sys::FlutterPointerPhase_kRemove, x, y, device, false);
            }
            _ => {}
        }
    }

    /// Queues a touch position already projected into Flutter's physical
    /// desktop pixels. Output rotation is owned by the compositor, so passing
    /// libinput's native-axis coordinates through `position_transformed`
    /// would make Flutter disagree with Wayland hit testing.
    pub fn handle_touch_at(
        &mut self,
        event: &SmithayInputEvent<LibinputInputBackend>,
        x: f64,
        y: f64,
    ) {
        let x = x.clamp(0.0, f64::from(self.size.w));
        let y = y.clamp(0.0, f64::from(self.size.h));
        match event {
            SmithayInputEvent::TouchDown { event, .. } => {
                let device = touch_device(event.slot());
                self.touch_positions.insert(device, (x, y));
                self.push_touch(sys::FlutterPointerPhase_kAdd, x, y, device, false);
                self.push_touch(sys::FlutterPointerPhase_kDown, x, y, device, false);
            }
            SmithayInputEvent::TouchMotion { event, .. } => {
                let device = touch_device(event.slot());
                self.touch_positions.insert(device, (x, y));
                self.push_touch(sys::FlutterPointerPhase_kMove, x, y, device, true);
            }
            _ => debug_assert!(false, "touch position supplied for a non-positional event"),
        }
    }

    /// Aligns Flutter's mouse state to the compositor-owned desktop position.
    ///
    /// This does not emit an event or start a Flutter device lifecycle. It is
    /// used before semantic mouse transitions and after topology changes so
    /// their coordinates can never inherit independently integrated motion.
    pub fn synchronize_pointer_position(&mut self, x: f64, y: f64) {
        debug_assert!(x.is_finite() && y.is_finite());
        if !x.is_finite() || !y.is_finite() {
            return;
        }
        self.pointer_x = x.clamp(0.0, f64::from(self.size.w));
        self.pointer_y = y.clamp(0.0, f64::from(self.size.h));
    }

    /// Queues mouse motion at the position already resolved by the compositor.
    pub fn handle_pointer_motion_at(&mut self, x: f64, y: f64) {
        self.synchronize_pointer_position(x, y);
        self.ensure_mouse_added();
        self.push_mouse(
            if self.pointer_buttons == 0 {
                sys::FlutterPointerPhase_kHover
            } else {
                sys::FlutterPointerPhase_kMove
            },
            true,
        );
    }

    /// Ends Flutter's mouse-device lifecycle when compositor routing leaves
    /// the shell input endpoint.
    pub fn handle_pointer_leave_at(&mut self, x: f64, y: f64) {
        self.synchronize_pointer_position(x, y);
        if !self.mouse_added {
            return;
        }
        // A compositor drag can route motion through Smithay while Flutter
        // still owns the pressed-button lifecycle. Defer Remove until the
        // matching Up has reached Flutter; a later client-routed sample will
        // retry this idempotently.
        if self.pointer_buttons != 0 {
            return;
        }
        self.push_mouse(sys::FlutterPointerPhase_kRemove, false);
        self.mouse_added = false;
    }

    pub fn mouse_lifecycle_active(&self) -> bool {
        self.mouse_added
    }

    pub fn pointer_captured(&self) -> bool {
        self.pointer_buttons != 0
    }

    pub fn cancel_device_lifecycles(&mut self, pointer: bool, touch: bool) {
        if pointer {
            if self.mouse_added {
                if self.pointer_buttons != 0 {
                    self.pointer_buttons = 0;
                    self.push_mouse(sys::FlutterPointerPhase_kCancel, false);
                }
                self.push_mouse(sys::FlutterPointerPhase_kRemove, false);
            }
            self.pointer_buttons = 0;
            self.mouse_added = false;
        }

        if touch {
            let mut positions = self.touch_positions.drain().collect::<Vec<_>>();
            positions.sort_unstable_by_key(|(device, _)| *device);
            for (device, (x, y)) in positions {
                self.push_touch(sys::FlutterPointerPhase_kCancel, x, y, device, false);
                self.push_touch(sys::FlutterPointerPhase_kRemove, x, y, device, false);
            }
        }
    }

    /// Retires only the Flutter touch contacts claimed by a compositor
    /// gesture, leaving unrelated fingers and the mouse lifecycle intact.
    pub fn cancel_touch_slots(&mut self, slots: &[i32]) {
        for slot in slots {
            let device = touch_device_from_slot(*slot);
            let Some((x, y)) = self.touch_positions.remove(&device) else {
                continue;
            };
            self.push_touch(sys::FlutterPointerPhase_kCancel, x, y, device, false);
            self.push_touch(sys::FlutterPointerPhase_kRemove, x, y, device, false);
        }
    }

    pub fn handle_keyboard(
        &mut self,
        key: KeysymHandle<'_>,
        state: KeyState,
        modifiers: &ModifiersState,
    ) {
        let unicode = key.modified_sym().key_char().map(u32::from).unwrap_or(0);
        self.handle_keyboard_with_unicode(key.raw_code().raw(), state, modifiers, unicode);
    }

    pub fn handle_keyboard_with_unicode(
        &mut self,
        xkb_keycode: u32,
        state: KeyState,
        modifiers: &ModifiersState,
        unicode: u32,
    ) {
        let keycode = xkb_keycode.saturating_sub(8);
        self.push(InputRecord::Keyboard(KeyboardRecord {
            keycode,
            unicode,
            modifiers: glfw_modifiers(modifiers),
            pressed: state == KeyState::Pressed,
        }));
    }

    fn ensure_mouse_added(&mut self) {
        if self.mouse_added {
            return;
        }
        self.mouse_added = true;
        self.push_mouse(sys::FlutterPointerPhase_kAdd, false);
    }

    fn push_mouse(&mut self, phase: sys::FlutterPointerPhase, replaceable_motion: bool) {
        self.push(InputRecord::Pointer(PointerRecord {
            phase,
            x: self.pointer_x,
            y: self.pointer_y,
            device: 0,
            signal_kind: sys::FlutterPointerSignalKind_kFlutterPointerSignalKindNone,
            scroll_x: 0.0,
            scroll_y: 0.0,
            device_kind: sys::FlutterPointerDeviceKind_kFlutterPointerDeviceKindMouse,
            buttons: self.pointer_buttons,
            replaceable_motion,
        }));
    }

    fn push_touch(
        &mut self,
        phase: sys::FlutterPointerPhase,
        x: f64,
        y: f64,
        device: i32,
        replaceable_motion: bool,
    ) {
        self.push(InputRecord::Pointer(PointerRecord {
            phase,
            x,
            y,
            device,
            signal_kind: sys::FlutterPointerSignalKind_kFlutterPointerSignalKindNone,
            scroll_x: 0.0,
            scroll_y: 0.0,
            device_kind: sys::FlutterPointerDeviceKind_kFlutterPointerDeviceKindTouch,
            buttons: 0,
            replaceable_motion,
        }));
    }

    fn push(&mut self, event: InputRecord) {
        push_bounded_input(&mut self.events, event, MAX_QUEUED_INPUT_EVENTS);
    }
}

pub(super) fn push_bounded_input(
    events: &mut VecDeque<InputRecord>,
    event: InputRecord,
    capacity: usize,
) {
    if capacity == 0 {
        return;
    }

    if let Some(device) = event.replaceable_motion_device() {
        // Keep at most one sample per device in the replaceable tail. Removing
        // and appending (instead of overwriting in place) preserves the order
        // of interleaved multi-touch samples by their most recent occurrence.
        let replace = events
            .iter()
            .enumerate()
            .rev()
            .take_while(|(_, queued)| queued.replaceable_motion_device().is_some())
            .find_map(|(index, queued)| {
                (queued.replaceable_motion_device() == Some(device)).then_some(index)
            });
        if let Some(index) = replace {
            events.remove(index);
            events.push_back(event);
            return;
        }
    }

    if events.len() >= capacity {
        if let Some(index) = events
            .iter()
            .position(|queued| queued.replaceable_motion_device().is_some())
        {
            events.remove(index);
        } else if event.replaceable_motion_device().is_some() {
            // A fresh position sample must never displace a queued Add,
            // Down/Up, button-state change or keyboard event.
            return;
        } else {
            // A finite queue cannot retain an unbounded stream made entirely
            // of semantic transitions. This pathological fallback keeps the
            // hard bound; ordinary motion floods take the branches above.
            events.pop_front();
        }
    }
    events.push_back(event);
}

impl InputRecord {
    fn replaceable_motion_device(self) -> Option<i32> {
        match self {
            Self::Pointer(event) if event.replaceable_motion => Some(event.device),
            Self::Pointer(_) | Self::Keyboard(_) => None,
        }
    }
}

fn glfw_modifiers(modifiers: &ModifiersState) -> u32 {
    u32::from(modifiers.shift)
        | (u32::from(modifiers.ctrl) << 1)
        | (u32::from(modifiers.alt) << 2)
        | (u32::from(modifiers.logo) << 3)
        | (u32::from(modifiers.caps_lock) << 4)
        | (u32::from(modifiers.num_lock) << 5)
}

pub(super) fn glfw_keycode(keycode: u32) -> u32 {
    match keycode {
        1 => 256,                   // Escape
        2..=10 => 49 + keycode - 2, // 1..9
        11 => 48,                   // 0
        12 => 45,                   // Minus
        13 => 61,                   // Equal
        14 => 259,                  // Backspace
        15 => 258,                  // Tab
        16..=25 => [81, 87, 69, 82, 84, 89, 85, 73, 79, 80][(keycode - 16) as usize],
        26 => 91,  // Left bracket
        27 => 93,  // Right bracket
        28 => 257, // Enter
        29 => 341, // Left control
        30..=38 => [65, 83, 68, 70, 71, 72, 74, 75, 76][(keycode - 30) as usize],
        39 => 59,  // Semicolon
        40 => 39,  // Apostrophe
        41 => 96,  // Grave accent
        42 => 340, // Left shift
        43 => 92,  // Backslash
        44..=50 => [90, 88, 67, 86, 66, 78, 77][(keycode - 44) as usize],
        51 => 44,  // Comma
        52 => 46,  // Period
        53 => 47,  // Slash
        54 => 344, // Right shift
        55 => 332, // Keypad multiply
        56 => 342, // Left alt
        57 => 32,  // Space
        58 => 280, // Caps lock
        59..=68 => 290 + keycode - 59,
        69 => 282,       // Num lock
        70 => 281,       // Scroll lock
        71 => 327,       // Keypad 7
        72 => 328,       // Keypad 8
        73 => 329,       // Keypad 9
        74 => 333,       // Keypad subtract
        75 => 324,       // Keypad 4
        76 => 325,       // Keypad 5
        77 => 326,       // Keypad 6
        78 => 334,       // Keypad add
        79 => 321,       // Keypad 1
        80 => 322,       // Keypad 2
        81 => 323,       // Keypad 3
        82 => 320,       // Keypad 0
        83 | 121 => 330, // Keypad decimal/comma
        87 => 300,       // F11
        88 => 301,       // F12
        96 => 335,       // Keypad enter
        97 => 345,       // Right control
        98 => 331,       // Keypad divide
        99 => 283,       // Print screen
        100 => 346,      // Right alt
        102 => 268,      // Home
        103 => 265,      // Up
        104 => 266,      // Page up
        105 => 263,      // Left
        106 => 262,      // Right
        107 => 269,      // End
        108 => 264,      // Down
        109 => 267,      // Page down
        110 => 260,      // Insert
        111 => 261,      // Delete
        117 => 336,      // Keypad equal
        119 => 284,      // Pause
        125 => 343,      // Left super
        126 => 347,      // Right super
        127 => 348,      // Menu
        183..=194 => 302 + keycode - 183,
        _ => keycode,
    }
}

fn mouse_button_mask(button: u32) -> Option<i64> {
    match button {
        0x110 => Some(1),
        0x111 => Some(2),
        0x112 => Some(4),
        0x113 | 0x116 => Some(8),
        0x114 | 0x115 => Some(16),
        _ => None,
    }
}

fn touch_device(slot: smithay::backend::input::TouchSlot) -> i32 {
    touch_device_from_slot(i32::from(slot))
}

fn touch_device_from_slot(slot: i32) -> i32 {
    slot.saturating_add(1).max(1)
}
