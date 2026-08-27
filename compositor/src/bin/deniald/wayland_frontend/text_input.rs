//! Compositor-owned text sessions and `zwp_text_input_v3`.
//!
//! Smithay's text-input and input-method helpers are intentionally coupled.
//! Denial's broker also serves Flutter editors, so this local state machine
//! lets the shell, Wayland clients, and an external engine meet at one
//! routing boundary.

use std::{
    mem,
    time::{Duration, Instant},
};

use smithay::input::Seat;
use smithay::reexports::wayland_protocols::wp::text_input::zv3::server::{
    zwp_text_input_manager_v3::{self, ZwpTextInputManagerV3},
    zwp_text_input_v3::{self, ChangeCause, ContentPurpose, ZwpTextInputV3},
};
use smithay::reexports::wayland_server::backend::{ClientId, GlobalId, ObjectId};
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::reexports::wayland_server::{
    Client, DataInit, Dispatch, DisplayHandle, GlobalDispatch, New, Resource,
};
use smithay::utils::Rectangle;
use tracing::debug;

#[cfg(feature = "flutter")]
use super::super::flutter_runtime::TextInputSnapshot;
use super::input_method::{EditorEndpoint, EditorSnapshot, InputMethodTransaction};
use super::{RuntimeState, WaylandFrontend};

const MANAGER_VERSION: u32 = 2;
const MAX_TEXT_INPUTS: usize = 1024;
const MAX_TEXT_INPUTS_PER_CLIENT: usize = 16;
const MAX_SURROUNDING_TEXT_BYTES: usize = 4000;
const TOUCH_AUTHORIZATION_WINDOW: Duration = Duration::from_millis(250);

#[cfg(feature = "flutter")]
fn finite_i32(value: f64) -> i32 {
    value
        .round()
        .clamp(f64::from(i32::MIN), f64::from(i32::MAX)) as i32
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct CursorRectangle {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct SurroundingText {
    text: String,
    cursor: u32,
    anchor: u32,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct PendingState {
    enabled: Option<bool>,
    surrounding: Option<SurroundingText>,
    change_cause: Option<u32>,
    content_type: Option<(u32, u32)>,
    cursor_rectangle: Option<CursorRectangle>,
    available_actions: Option<Vec<u32>>,
}

impl PendingState {
    fn reset_for_enablement(&mut self, enabled: bool) {
        *self = Self {
            enabled: Some(enabled),
            ..Self::default()
        };
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct EditorState {
    surrounding: Option<SurroundingText>,
    change_cause: u32,
    content_type: Option<(u32, u32)>,
    cursor_rectangle: Option<CursorRectangle>,
    committed_cursor_rectangle: Option<CursorRectangle>,
    available_actions: Vec<u32>,
}

#[derive(Clone, Debug)]
struct Instance<I, C> {
    id: I,
    client: C,
    version: u32,
    serial: u32,
    entered: bool,
    pending: PendingState,
    current: EditorState,
    input_panel_visible_hint: Option<bool>,
    touch_dismissed: bool,
    touch_authorization_deadline: Option<Instant>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct Focus<S, C> {
    surface: S,
    client: C,
}

#[derive(Debug)]
struct FocusTransition<I> {
    left: Vec<I>,
    entered: Vec<I>,
}

impl<I> Default for FocusTransition<I> {
    fn default() -> Self {
        Self {
            left: Vec::new(),
            entered: Vec::new(),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CommitEffect {
    Ignored,
    Activated,
    Updated,
    Deactivated,
}

/// The protocol rules without Wayland resources. Keeping identity generic
/// makes focus, ordering, serial, and destruction behavior cheap to test.
#[derive(Debug)]
struct SessionState<I, C, S> {
    instances: Vec<Instance<I, C>>,
    focus: Option<Focus<S, C>>,
    active: Option<I>,
}

impl<I, C, S> Default for SessionState<I, C, S> {
    fn default() -> Self {
        Self {
            instances: Vec::new(),
            focus: None,
            active: None,
        }
    }
}

impl<I, C, S> SessionState<I, C, S>
where
    I: Clone + Eq,
    C: Clone + Eq,
    S: Clone + Eq,
{
    fn register(&mut self, id: I, client: C, version: u32) -> bool {
        let entered = self
            .focus
            .as_ref()
            .is_some_and(|focus| focus.client == client);
        self.instances.push(Instance {
            id,
            client,
            version,
            serial: 0,
            entered,
            pending: PendingState::default(),
            current: EditorState::default(),
            input_panel_visible_hint: None,
            touch_dismissed: true,
            touch_authorization_deadline: None,
        });
        entered
    }

    fn remove(&mut self, id: &I) -> bool {
        let was_active = self.active.as_ref() == Some(id);
        self.instances.retain(|instance| &instance.id != id);
        if was_active {
            self.active = None;
        }
        was_active
    }

    fn set_focus(&mut self, focus: Option<Focus<S, C>>) -> FocusTransition<I> {
        if self.focus == focus {
            return FocusTransition::default();
        }

        self.active = None;
        let mut transition = FocusTransition::default();
        for instance in &mut self.instances {
            if instance.entered {
                transition.left.push(instance.id.clone());
            }
            instance.entered = false;
            instance.pending = PendingState::default();
            instance.current = EditorState::default();
            instance.input_panel_visible_hint = None;
            instance.touch_dismissed = true;
            instance.touch_authorization_deadline = None;
        }

        self.focus = focus;
        let Some(focus) = self.focus.as_ref() else {
            return transition;
        };
        for instance in &mut self.instances {
            if instance.client == focus.client {
                instance.entered = true;
                transition.entered.push(instance.id.clone());
            }
        }
        transition
    }

    fn is_entered(&self, id: &I) -> bool {
        self.instances
            .iter()
            .find(|instance| &instance.id == id)
            .is_some_and(|instance| instance.entered)
    }

    fn request_enablement(&mut self, id: &I, enabled: bool) {
        if let Some(instance) = self
            .instances
            .iter_mut()
            .find(|instance| &instance.id == id && instance.entered)
        {
            instance.pending.reset_for_enablement(enabled);
        }
    }

    fn set_surrounding(&mut self, id: &I, surrounding: SurroundingText) {
        if let Some(instance) = self
            .instances
            .iter_mut()
            .find(|instance| &instance.id == id && instance.entered)
        {
            instance.pending.surrounding = Some(surrounding);
        }
    }

    fn set_change_cause(&mut self, id: &I, cause: u32) {
        if let Some(instance) = self
            .instances
            .iter_mut()
            .find(|instance| &instance.id == id && instance.entered)
        {
            instance.pending.change_cause = Some(cause);
        }
    }

    fn set_content_type(&mut self, id: &I, hint: u32, purpose: u32) {
        if let Some(instance) = self
            .instances
            .iter_mut()
            .find(|instance| &instance.id == id && instance.entered)
        {
            instance.pending.content_type = Some((hint, purpose));
        }
    }

    fn set_cursor_rectangle(&mut self, id: &I, rectangle: CursorRectangle) {
        if let Some(instance) = self
            .instances
            .iter_mut()
            .find(|instance| &instance.id == id && instance.entered)
        {
            instance.pending.cursor_rectangle = Some(rectangle);
        }
    }

    fn set_available_actions(&mut self, id: &I, actions: Vec<u32>) {
        if let Some(instance) = self
            .instances
            .iter_mut()
            .find(|instance| &instance.id == id && instance.entered)
        {
            instance.pending.available_actions = Some(actions);
        }
    }

    fn set_input_panel_hint(&mut self, id: &I, visible: bool) {
        if let Some(instance) = self
            .instances
            .iter_mut()
            .find(|instance| &instance.id == id && instance.entered)
        {
            if instance.input_panel_visible_hint != Some(visible) {
                instance.input_panel_visible_hint = Some(visible);
            }
            let touch_authorized = instance
                .touch_authorization_deadline
                .is_some_and(|deadline| Instant::now() <= deadline);
            if visible && touch_authorized {
                instance.touch_dismissed = false;
            } else if !visible {
                instance.touch_authorization_deadline = None;
                instance.touch_dismissed = true;
            }
        }
    }

    /// Start a short-lived authorization transaction for a client touch.
    ///
    /// The client gets the touch immediately afterward. An editor must commit
    /// fresh state before the authorization expires. Programmatic focus and
    /// delayed lifecycle updates therefore cannot open the software keyboard.
    fn begin_touch_authorization(&mut self) -> bool {
        let deadline = Instant::now() + TOUCH_AUTHORIZATION_WINDOW;
        let active = self.active.clone();
        let mut has_protocol_endpoint = false;
        for instance in self
            .instances
            .iter_mut()
            .filter(|instance| instance.entered)
        {
            has_protocol_endpoint = true;
            instance.touch_authorization_deadline = Some(deadline);
            if active.as_ref() == Some(&instance.id) {
                instance.touch_dismissed = true;
            }
        }
        has_protocol_endpoint
    }

    fn consume_touch_authorization(instance: &mut Instance<I, C>) -> bool {
        instance
            .touch_authorization_deadline
            .take()
            .is_some_and(|deadline| Instant::now() <= deadline)
    }

    fn commit(&mut self, id: &I) -> CommitEffect {
        let Some(index) = self
            .instances
            .iter()
            .position(|instance| &instance.id == id)
        else {
            return CommitEffect::Ignored;
        };
        self.instances[index].serial = self.instances[index].serial.wrapping_add(1);
        if !self.instances[index].entered {
            return CommitEffect::Ignored;
        }

        let pending = mem::take(&mut self.instances[index].pending);
        let touch_authorized = Self::consume_touch_authorization(&mut self.instances[index]);
        let editor_engaged = pending.enabled == Some(true)
            || pending.surrounding.is_some()
            || pending.content_type.is_some()
            || pending.cursor_rectangle.is_some();
        match pending.enabled {
            Some(true) => {
                if self.active.as_ref().is_some_and(|active| active != id) {
                    return CommitEffect::Ignored;
                }
                self.active = Some(id.clone());
                self.instances[index].current = EditorState::default();
                Self::apply_pending(&mut self.instances[index], pending);
                self.instances[index].touch_dismissed = !touch_authorized;
                CommitEffect::Activated
            }
            Some(false) => {
                if self.active.as_ref() == Some(id) {
                    self.active = None;
                    self.instances[index].current = EditorState::default();
                    self.instances[index].input_panel_visible_hint = None;
                    self.instances[index].touch_dismissed = true;
                    CommitEffect::Deactivated
                } else {
                    CommitEffect::Ignored
                }
            }
            None => {
                if self.active.as_ref() != Some(id) {
                    return CommitEffect::Ignored;
                }
                Self::apply_pending(&mut self.instances[index], pending);
                if editor_engaged && touch_authorized {
                    self.instances[index].touch_dismissed = false;
                }
                CommitEffect::Updated
            }
        }
    }

    fn apply_pending(instance: &mut Instance<I, C>, mut pending: PendingState) {
        if let Some(surrounding) = pending.surrounding.take() {
            instance.current.surrounding = Some(surrounding);
        }
        instance.current.change_cause = pending.change_cause.unwrap_or_default();
        if let Some(content_type) = pending.content_type {
            instance.current.content_type = Some(content_type);
        }
        if let Some(rectangle) = pending.cursor_rectangle {
            if instance.version >= 2 {
                instance.current.committed_cursor_rectangle = Some(rectangle);
            } else {
                instance.current.cursor_rectangle = Some(rectangle);
            }
        }
        if let Some(actions) = pending.available_actions {
            instance.current.available_actions = actions;
        }
    }

    fn surface_committed(&mut self, surface: &S) {
        if self.focus.as_ref().map(|focus| &focus.surface) != Some(surface) {
            return;
        }
        let Some(active) = self.active.as_ref() else {
            return;
        };
        let Some(instance) = self
            .instances
            .iter_mut()
            .find(|instance| &instance.id == active)
        else {
            self.active = None;
            return;
        };
        if let Some(rectangle) = instance.current.committed_cursor_rectangle.take() {
            instance.current.cursor_rectangle = Some(rectangle);
        }
    }

    fn active_serial(&self) -> Option<(I, u32)> {
        let active = self.active.as_ref()?;
        self.instances
            .iter()
            .find(|instance| &instance.id == active && instance.entered)
            .map(|instance| (instance.id.clone(), instance.serial))
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(super) enum SeatFocusKind {
    #[default]
    None,
    Wayland,
    Xwayland,
}

#[derive(Clone, Debug, PartialEq)]
struct FlutterEditor {
    generation: u64,
    lifecycle: u64,
    revision: u64,
    client_id: i64,
    active: bool,
    input_panel_visible: bool,
    secure: bool,
    surrounding_text: Option<(String, u32, u32)>,
    content_hint: u32,
    content_purpose: u32,
    cursor_rectangle: Option<CursorRectangle>,
}

#[derive(Debug, Default)]
struct TextSessionBroker {
    seat_focus: SeatFocusKind,
    shell_capture: bool,
    flutter: Option<FlutterEditor>,
    legacy_touch_keyboard: bool,
    flutter_panel_authorized: bool,
    flutter_touch_authorization_deadline: Option<Instant>,
    activation_serial: u64,
}

impl TextSessionBroker {
    fn set_seat_focus(&mut self, focus: SeatFocusKind) {
        if self.seat_focus != focus {
            self.legacy_touch_keyboard = false;
        }
        self.seat_focus = focus;
    }

    fn set_shell_capture(&mut self, capture: bool) {
        self.shell_capture = capture;
    }

    fn note_client_touch(&mut self, protocol_available: bool) {
        self.activation_serial = self.activation_serial.wrapping_add(1);
        self.legacy_touch_keyboard = !protocol_available
            && matches!(
                self.seat_focus,
                SeatFocusKind::Wayland | SeatFocusKind::Xwayland
            );
    }

    fn note_flutter_touch(&mut self) {
        self.legacy_touch_keyboard = false;
        self.flutter_touch_authorization_deadline =
            Some(Instant::now() + TOUCH_AUTHORIZATION_WINDOW);
    }

    fn retire_flutter_generation(&mut self) {
        self.flutter = None;
        self.flutter_panel_authorized = false;
        self.flutter_touch_authorization_deadline = None;
    }

    #[cfg(feature = "flutter")]
    fn observe_flutter_editor(&mut self, generation: u64, snapshot: TextInputSnapshot) -> bool {
        if self.flutter.as_ref().is_some_and(|current| {
            current.generation > generation
                || (current.generation == generation && current.revision >= snapshot.revision)
        }) {
            return false;
        }
        if self
            .flutter_touch_authorization_deadline
            .is_some_and(|deadline| Instant::now() > deadline)
        {
            self.flutter_touch_authorization_deadline = None;
        }
        if snapshot.active && snapshot.input_panel_visible {
            if self.flutter_touch_authorization_deadline.take().is_some() {
                self.flutter_panel_authorized = true;
                self.activation_serial = self.activation_serial.wrapping_add(1);
            }
        } else {
            self.flutter_panel_authorized = false;
        }
        let revision = snapshot.revision;
        self.flutter = Some(FlutterEditor {
            generation,
            lifecycle: snapshot.lifecycle_revision,
            revision,
            client_id: snapshot.client_id,
            active: snapshot.active,
            input_panel_visible: snapshot.input_panel_visible,
            secure: snapshot.secure,
            surrounding_text: snapshot
                .surrounding_text
                .map(|text| (text, snapshot.cursor, snapshot.anchor)),
            content_hint: snapshot.content_hint,
            content_purpose: snapshot.content_purpose,
            cursor_rectangle: snapshot.cursor_rectangle.map(|rectangle| CursorRectangle {
                x: finite_i32(rectangle.x),
                y: finite_i32(rectangle.y),
                width: finite_i32(rectangle.width).max(0),
                height: finite_i32(rectangle.height).max(0),
            }),
        });
        true
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct SoftwareKeyboardState {
    pub active: bool,
    pub input_panel_visible: bool,
    pub legacy: bool,
    pub content_hint: u32,
    pub content_purpose: u32,
    pub activation_serial: u64,
}

#[derive(Debug)]
pub(super) struct TextInputManager {
    _global: GlobalId,
    sessions: SessionState<ObjectId, ClientId, ObjectId>,
    resources: Vec<ZwpTextInputV3>,
    focus_surface: Option<WlSurface>,
    broker: TextSessionBroker,
}

impl TextInputManager {
    pub(super) fn new(display: &DisplayHandle) -> Self {
        Self {
            _global: display
                .create_global::<RuntimeState, ZwpTextInputManagerV3, _>(MANAGER_VERSION, ()),
            sessions: SessionState::default(),
            resources: Vec::new(),
            focus_surface: None,
            broker: TextSessionBroker::default(),
        }
    }

    fn can_register(&self, client: &ClientId) -> bool {
        self.resources.len() < MAX_TEXT_INPUTS
            && self
                .sessions
                .instances
                .iter()
                .filter(|instance| &instance.client == client)
                .count()
                < MAX_TEXT_INPUTS_PER_CLIENT
    }

    fn register(&mut self, resource: ZwpTextInputV3, client: ClientId) {
        let entered = self
            .sessions
            .register(resource.id(), client, resource.version());
        if entered && let Some(surface) = self.focus_surface.as_ref() {
            resource.enter(surface);
        }
        self.resources.push(resource);
    }

    fn unregister(&mut self, id: &ObjectId) {
        self.sessions.remove(id);
        self.resources.retain(|resource| &resource.id() != id);
    }

    pub(super) fn set_keyboard_focus(
        &mut self,
        display: &DisplayHandle,
        surface: Option<WlSurface>,
        focus_kind: SeatFocusKind,
    ) {
        let surface_changed =
            self.focus_surface.as_ref().map(Resource::id) != surface.as_ref().map(Resource::id);
        self.broker.set_seat_focus(focus_kind);
        if !surface_changed {
            return;
        }
        self.broker.legacy_touch_keyboard = false;

        let old_surface = self.focus_surface.take();
        let left = self.sessions.set_focus(None).left;
        if let Some(old_surface) = old_surface.as_ref() {
            for id in left {
                if let Some(resource) = self.resource(&id) {
                    resource.leave(old_surface);
                }
            }
        }

        let Some(surface) = surface else {
            return;
        };
        let Ok(client) = display.get_client(surface.id()) else {
            debug!(surface_id = ?surface.id(), "text-input focus surface lost its client");
            return;
        };
        let transition = self.sessions.set_focus(Some(Focus {
            surface: surface.id(),
            client: client.id(),
        }));
        for id in transition.entered {
            if let Some(resource) = self.resource(&id) {
                resource.enter(&surface);
            }
        }
        self.focus_surface = Some(surface);
    }

    pub(super) fn surface_committed(&mut self, surface: &WlSurface) {
        self.sessions.surface_committed(&surface.id());
    }

    pub(super) fn set_shell_capture(&mut self, capture: bool) {
        self.broker.set_shell_capture(capture);
    }

    pub(super) fn shell_captures_keyboard(&self) -> bool {
        self.broker.shell_capture
    }

    #[cfg(feature = "flutter")]
    pub(super) fn observe_flutter_editor(&mut self, generation: u64, snapshot: TextInputSnapshot) {
        self.broker.observe_flutter_editor(generation, snapshot);
    }

    pub(super) fn retire_flutter_generation(&mut self) {
        self.broker.retire_flutter_generation();
    }

    /// Begin compositor software-keyboard policy for a client touch.
    ///
    /// Protocol-aware editors must publish fresh state after the touch to
    /// reopen. Clients with no text-input protocol endpoint use the focused
    /// seat fallback, which is required for terminals and Xwayland apps.
    pub(super) fn note_client_touch(&mut self) {
        let protocol_available = self.sessions.begin_touch_authorization();
        self.broker.note_client_touch(protocol_available);
    }

    /// A compositor-owned touch is outside the client editor boundary.
    pub(super) fn note_flutter_touch(&mut self) {
        self.sessions.begin_touch_authorization();
        self.broker.note_flutter_touch();
    }

    pub(super) fn software_keyboard_state(&self) -> SoftwareKeyboardState {
        if self.broker.shell_capture {
            return self.flutter_software_keyboard_state();
        }
        match self.broker.seat_focus {
            SeatFocusKind::Wayland => self.wayland_software_keyboard_state(),
            SeatFocusKind::Xwayland => self.legacy_software_keyboard_state(),
            SeatFocusKind::None => self.flutter_software_keyboard_state(),
        }
    }

    fn wayland_software_keyboard_state(&self) -> SoftwareKeyboardState {
        let Some(active) = self.sessions.active.as_ref() else {
            return self.legacy_software_keyboard_state();
        };
        let Some(instance) = self
            .sessions
            .instances
            .iter()
            .find(|instance| &instance.id == active && instance.entered)
        else {
            return self.legacy_software_keyboard_state();
        };
        let (content_hint, content_purpose) = instance.current.content_type.unwrap_or_default();
        SoftwareKeyboardState {
            active: true,
            input_panel_visible: instance.input_panel_visible_hint.unwrap_or(true)
                && !instance.touch_dismissed,
            legacy: false,
            content_hint,
            content_purpose,
            activation_serial: self.broker.activation_serial,
        }
    }

    fn legacy_software_keyboard_state(&self) -> SoftwareKeyboardState {
        SoftwareKeyboardState {
            active: self.broker.legacy_touch_keyboard,
            input_panel_visible: self.broker.legacy_touch_keyboard,
            legacy: true,
            activation_serial: self.broker.activation_serial,
            ..SoftwareKeyboardState::default()
        }
    }

    fn flutter_software_keyboard_state(&self) -> SoftwareKeyboardState {
        let Some(editor) = self.broker.flutter.as_ref().filter(|editor| editor.active) else {
            return SoftwareKeyboardState {
                activation_serial: self.broker.activation_serial,
                ..SoftwareKeyboardState::default()
            };
        };
        SoftwareKeyboardState {
            active: true,
            input_panel_visible: editor.input_panel_visible && self.broker.flutter_panel_authorized,
            legacy: false,
            content_hint: editor.content_hint,
            content_purpose: editor.content_purpose,
            activation_serial: self.broker.activation_serial,
        }
    }

    pub(super) fn input_method_snapshot(&self) -> Option<EditorSnapshot> {
        if self.broker.shell_capture {
            return self.flutter_input_method_snapshot();
        }
        match self.broker.seat_focus {
            SeatFocusKind::Wayland => self.wayland_input_method_snapshot(),
            SeatFocusKind::Xwayland => None,
            SeatFocusKind::None => self.flutter_input_method_snapshot(),
        }
    }

    fn wayland_input_method_snapshot(&self) -> Option<EditorSnapshot> {
        let (id, serial) = self.sessions.active_serial()?;
        let instance = self
            .sessions
            .instances
            .iter()
            .find(|instance| instance.id == id && instance.entered)?;
        let surface = self.focus_surface.as_ref()?.clone();
        let (content_hint, content_purpose) = instance.current.content_type.unwrap_or_default();
        Some(EditorSnapshot {
            endpoint: EditorEndpoint::Wayland {
                resource: id,
                serial,
                surface,
            },
            surrounding_text: instance.current.surrounding.as_ref().map(|surrounding| {
                (
                    surrounding.text.clone(),
                    surrounding.cursor,
                    surrounding.anchor,
                )
            }),
            change_cause: instance.current.change_cause,
            content_hint,
            content_purpose,
            cursor_rectangle: instance.current.cursor_rectangle.map(|rectangle| {
                Rectangle::new(
                    (rectangle.x, rectangle.y).into(),
                    (rectangle.width.max(0), rectangle.height.max(0)).into(),
                )
            }),
        })
    }

    fn flutter_input_method_snapshot(&self) -> Option<EditorSnapshot> {
        let editor = self
            .broker
            .flutter
            .as_ref()
            .filter(|editor| editor.active && !editor.secure)?;
        Some(EditorSnapshot {
            endpoint: EditorEndpoint::Flutter {
                generation: editor.generation,
                lifecycle: editor.lifecycle,
                client_id: editor.client_id,
            },
            surrounding_text: editor.surrounding_text.clone(),
            change_cause: 1,
            content_hint: editor.content_hint,
            content_purpose: editor.content_purpose,
            cursor_rectangle: editor.cursor_rectangle.map(|rectangle| {
                Rectangle::new(
                    (rectangle.x, rectangle.y).into(),
                    (rectangle.width, rectangle.height).into(),
                )
            }),
        })
    }

    #[allow(dead_code)]
    pub(super) fn delete_surrounding_text(&mut self, before: u32, after: u32) -> bool {
        let Some((id, serial)) = self.sessions.active_serial() else {
            return false;
        };
        let Some(resource) = self.resource(&id) else {
            self.sessions.remove(&id);
            return false;
        };
        resource.delete_surrounding_text(before, after);
        resource.done(serial);
        true
    }

    pub(super) fn apply_input_method(
        &mut self,
        id: &ObjectId,
        serial: u32,
        transaction: &InputMethodTransaction,
        serial_matches: bool,
    ) -> bool {
        if self.sessions.active_serial().as_ref() != Some(&(id.clone(), serial)) {
            return false;
        }
        let Some(resource) = self.resource(id).cloned() else {
            self.sessions.remove(id);
            return false;
        };
        if let Some((before, after)) = transaction.delete_surrounding {
            resource.delete_surrounding_text(before, after);
        }
        if let Some(text) = transaction.commit_string.as_ref() {
            resource.commit_string(Some(text.clone()));
        }
        if let Some((text, cursor_begin, cursor_end)) = transaction.preedit_string.as_ref() {
            resource.preedit_string(Some(text.clone()), *cursor_begin, *cursor_end);
        }
        resource.done(if serial_matches { serial } else { 0 });
        true
    }

    fn resource(&self, id: &ObjectId) -> Option<&ZwpTextInputV3> {
        self.resources
            .iter()
            .find(|resource| resource.id() == *id && resource.is_alive())
    }
}

#[derive(Clone, Copy, Debug)]
pub(super) struct TextInputUserData {
    accepted: bool,
}

impl GlobalDispatch<ZwpTextInputManagerV3, ()> for RuntimeState {
    fn bind(
        _state: &mut Self,
        _handle: &DisplayHandle,
        _client: &Client,
        resource: New<ZwpTextInputManagerV3>,
        _global_data: &(),
        data_init: &mut DataInit<'_, Self>,
    ) {
        data_init.init(resource, ());
    }
}

impl Dispatch<ZwpTextInputManagerV3, ()> for RuntimeState {
    fn request(
        state: &mut Self,
        client: &Client,
        _resource: &ZwpTextInputManagerV3,
        request: zwp_text_input_manager_v3::Request,
        _data: &(),
        _handle: &DisplayHandle,
        data_init: &mut DataInit<'_, Self>,
    ) {
        match request {
            zwp_text_input_manager_v3::Request::GetTextInput { id, seat } => {
                let accepted = state.wayland.as_ref().is_some_and(|frontend| {
                    Seat::<RuntimeState>::from_resource(&seat)
                        .is_some_and(|seat| seat == frontend.seat)
                        && frontend.text_input.can_register(&client.id())
                });
                let resource = data_init.init(id, TextInputUserData { accepted });
                if accepted && let Some(frontend) = state.wayland.as_mut() {
                    frontend.text_input.register(resource, client.id());
                }
            }
            zwp_text_input_manager_v3::Request::Destroy => {}
            _ => unreachable!(),
        }
    }
}

impl Dispatch<ZwpTextInputV3, TextInputUserData> for RuntimeState {
    fn request(
        state: &mut Self,
        _client: &Client,
        resource: &ZwpTextInputV3,
        request: zwp_text_input_v3::Request,
        data: &TextInputUserData,
        _handle: &DisplayHandle,
        _data_init: &mut DataInit<'_, Self>,
    ) {
        if !data.accepted {
            return;
        }
        let Some(frontend) = state.wayland.as_mut() else {
            return;
        };
        let synchronize_input_method = matches!(&request, zwp_text_input_v3::Request::Commit);
        let sessions = &mut frontend.text_input.sessions;
        let id = resource.id();
        if !matches!(
            &request,
            zwp_text_input_v3::Request::Commit | zwp_text_input_v3::Request::Destroy
        ) && !sessions.is_entered(&id)
        {
            return;
        }
        match request {
            zwp_text_input_v3::Request::Enable => sessions.request_enablement(&id, true),
            zwp_text_input_v3::Request::Disable => sessions.request_enablement(&id, false),
            zwp_text_input_v3::Request::SetSurroundingText {
                text,
                cursor,
                anchor,
            } => {
                if let Some(surrounding) = valid_surrounding_text(text, cursor, anchor) {
                    sessions.set_surrounding(&id, surrounding);
                }
            }
            zwp_text_input_v3::Request::SetTextChangeCause { cause } => {
                let cause = cause.into_result().unwrap_or(ChangeCause::Other);
                sessions.set_change_cause(&id, cause as u32);
            }
            zwp_text_input_v3::Request::SetContentType { hint, purpose } => {
                let purpose = purpose.into_result().unwrap_or(ContentPurpose::Normal);
                sessions.set_content_type(&id, u32::from(hint), purpose as u32);
            }
            zwp_text_input_v3::Request::SetCursorRectangle {
                x,
                y,
                width,
                height,
            } => sessions.set_cursor_rectangle(
                &id,
                CursorRectangle {
                    x,
                    y,
                    width,
                    height,
                },
            ),
            zwp_text_input_v3::Request::Commit => {
                let effect = sessions.commit(&id);
                if matches!(effect, CommitEffect::Activated | CommitEffect::Updated) {
                    frontend.text_input.broker.legacy_touch_keyboard = false;
                }
            }
            zwp_text_input_v3::Request::SetAvailableActions { available_actions } => {
                match parse_available_actions(&available_actions) {
                    Some(actions) => sessions.set_available_actions(&id, actions),
                    None => resource.post_error(
                        zwp_text_input_v3::Error::InvalidAction,
                        "available actions contain none, duplicates, or malformed data",
                    ),
                }
            }
            zwp_text_input_v3::Request::ShowInputPanel => {
                sessions.set_input_panel_hint(&id, true);
            }
            zwp_text_input_v3::Request::HideInputPanel => {
                sessions.set_input_panel_hint(&id, false);
            }
            zwp_text_input_v3::Request::Destroy => {}
            _ => unreachable!(),
        }
        if synchronize_input_method && frontend.synchronize_input_method() {
            state.scene_sync.mark_dirty();
        }
    }

    fn destroyed(
        state: &mut Self,
        _client: ClientId,
        resource: &ZwpTextInputV3,
        data: &TextInputUserData,
    ) {
        if data.accepted
            && let Some(frontend) = state.wayland.as_mut()
        {
            frontend.text_input.unregister(&resource.id());
            if frontend.synchronize_input_method() {
                state.scene_sync.mark_dirty();
            }
        }
    }
}

fn valid_surrounding_text(text: String, cursor: i32, anchor: i32) -> Option<SurroundingText> {
    if text.len() > MAX_SURROUNDING_TEXT_BYTES {
        return None;
    }
    let cursor = usize::try_from(cursor).ok()?;
    let anchor = usize::try_from(anchor).ok()?;
    if cursor > text.len()
        || anchor > text.len()
        || !text.is_char_boundary(cursor)
        || !text.is_char_boundary(anchor)
    {
        return None;
    }
    Some(SurroundingText {
        text,
        cursor: cursor as u32,
        anchor: anchor as u32,
    })
}

fn parse_available_actions(bytes: &[u8]) -> Option<Vec<u32>> {
    let (chunks, remainder) = bytes.as_chunks::<4>();
    if !remainder.is_empty() {
        return None;
    }
    let mut actions = Vec::with_capacity(bytes.len() / 4);
    for chunk in chunks {
        let action = u32::from_ne_bytes(*chunk);
        if action == 0 || actions.contains(&action) {
            return None;
        }
        actions.push(action);
    }
    Some(actions)
}

impl WaylandFrontend {
    pub(super) fn synchronize_input_method(&mut self) -> bool {
        let snapshot = self.text_input.input_method_snapshot();
        self.input_method.synchronize(snapshot)
    }

    pub(crate) fn set_input_method_blocked(&mut self, blocked: bool) -> bool {
        self.input_method.set_blocked(blocked)
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn software_keyboard_state(&self) -> SoftwareKeyboardState {
        self.text_input.software_keyboard_state()
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn observe_flutter_text_editor(
        &mut self,
        generation: u64,
        snapshot: TextInputSnapshot,
    ) -> bool {
        self.text_input.observe_flutter_editor(generation, snapshot);
        self.synchronize_input_method()
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn drain_flutter_input_method_transactions(
        &mut self,
    ) -> impl Iterator<Item = (u64, i64, InputMethodTransaction)> + '_ {
        self.input_method.drain_flutter_transactions()
    }
}
