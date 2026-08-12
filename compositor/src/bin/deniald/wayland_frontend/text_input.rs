//! Compositor-owned text sessions and `zwp_text_input_v3`.
//!
//! Smithay's text-input and input-method helpers are intentionally coupled.
//! Denial's broker also serves Flutter editors, so this local state machine
//! lets the shell, Wayland clients, and an external engine meet at one
//! routing boundary.

use std::mem;

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
use tracing::{debug, warn};

#[cfg(feature = "flutter")]
use super::super::flutter_runtime::TextInputSnapshot;
use super::input_method::{EditorEndpoint, EditorSnapshot, InputMethodTransaction};
use super::{RuntimeState, WaylandFrontend};

const MANAGER_VERSION: u32 = 2;
const MAX_TEXT_INPUTS: usize = 1024;
const MAX_TEXT_INPUTS_PER_CLIENT: usize = 16;
const MAX_SURROUNDING_TEXT_BYTES: usize = 4000;
const MAX_COMMIT_STRING_BYTES: usize = 4000;

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
            && instance.input_panel_visible_hint != Some(visible)
        {
            instance.input_panel_visible_hint = Some(visible);
        }
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
        match pending.enabled {
            Some(true) => {
                if self.active.as_ref().is_some_and(|active| active != id) {
                    return CommitEffect::Ignored;
                }
                self.active = Some(id.clone());
                self.instances[index].current = EditorState::default();
                Self::apply_pending(&mut self.instances[index], pending);
                CommitEffect::Activated
            }
            Some(false) => {
                if self.active.as_ref() == Some(id) {
                    self.active = None;
                    self.instances[index].current = EditorState::default();
                    self.instances[index].input_panel_visible_hint = None;
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

    #[cfg(test)]
    fn instance(&self, id: &I) -> Option<&Instance<I, C>> {
        self.instances.iter().find(|instance| &instance.id == id)
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
    secure: bool,
    surrounding_text: Option<(String, u32, u32)>,
    content_hint: u32,
    content_purpose: u32,
    cursor_rectangle: Option<CursorRectangle>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ShellCommandTarget {
    Flutter,
    WaylandText,
    Seat,
    Captured,
    None,
}

#[derive(Debug, Default)]
struct TextSessionBroker {
    seat_focus: SeatFocusKind,
    shell_capture: bool,
    flutter: Option<FlutterEditor>,
}

impl TextSessionBroker {
    fn set_seat_focus(&mut self, focus: SeatFocusKind) {
        self.seat_focus = focus;
    }

    fn set_shell_capture(&mut self, capture: bool) {
        self.shell_capture = capture;
    }

    fn retire_flutter_generation(&mut self) {
        self.flutter = None;
    }

    #[cfg(feature = "flutter")]
    fn observe_flutter_editor(&mut self, generation: u64, snapshot: TextInputSnapshot) -> bool {
        if self.flutter.as_ref().is_some_and(|current| {
            current.generation > generation
                || (current.generation == generation && current.revision >= snapshot.revision)
        }) {
            return false;
        }
        let revision = snapshot.revision;
        self.flutter = Some(FlutterEditor {
            generation,
            lifecycle: snapshot.lifecycle_revision,
            revision,
            client_id: snapshot.client_id,
            active: snapshot.active,
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

    fn flutter_editor_active(&self) -> bool {
        self.flutter.as_ref().is_some_and(|editor| editor.active)
    }

    fn text_target(&self, wayland_editor_active: bool) -> ShellCommandTarget {
        if self.shell_capture {
            return if self.flutter_editor_active() {
                ShellCommandTarget::Flutter
            } else {
                ShellCommandTarget::Captured
            };
        }
        match self.seat_focus {
            SeatFocusKind::Wayland if wayland_editor_active => ShellCommandTarget::WaylandText,
            SeatFocusKind::Wayland | SeatFocusKind::Xwayland => ShellCommandTarget::Seat,
            SeatFocusKind::None if self.flutter_editor_active() => ShellCommandTarget::Flutter,
            SeatFocusKind::None => ShellCommandTarget::None,
        }
    }

    fn key_target(&self) -> ShellCommandTarget {
        if self.shell_capture {
            return if self.flutter_editor_active() {
                ShellCommandTarget::Flutter
            } else {
                ShellCommandTarget::Captured
            };
        }
        match self.seat_focus {
            SeatFocusKind::Wayland | SeatFocusKind::Xwayland => ShellCommandTarget::Seat,
            SeatFocusKind::None if self.flutter_editor_active() => ShellCommandTarget::Flutter,
            SeatFocusKind::None => ShellCommandTarget::None,
        }
    }
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
        self.broker.set_seat_focus(focus_kind);
        if self.focus_surface.as_ref().map(Resource::id) == surface.as_ref().map(Resource::id) {
            return;
        }

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

    pub(super) fn text_target(&self) -> ShellCommandTarget {
        self.broker
            .text_target(self.sessions.active_serial().is_some())
    }

    pub(super) fn key_target(&self) -> ShellCommandTarget {
        self.broker.key_target()
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

    pub(super) fn commit_text(&mut self, text: &str) -> bool {
        let Some((id, serial)) = self.sessions.active_serial() else {
            return false;
        };
        let Some(resource) = self.resource(&id).cloned() else {
            self.sessions.remove(&id);
            return false;
        };
        if text.contains('\0') {
            warn!("refused a NUL-containing text-input commit");
            return false;
        }
        if text.is_empty() {
            return true;
        }
        for chunk in utf8_chunks(text, MAX_COMMIT_STRING_BYTES) {
            resource.commit_string(Some(chunk.to_owned()));
            resource.done(serial);
        }
        true
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
                if accepted {
                    if let Some(frontend) = state.wayland.as_mut() {
                        frontend.text_input.register(resource, client.id());
                    }
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
                sessions.commit(&id);
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
    let chunks = bytes.chunks_exact(4);
    if !chunks.remainder().is_empty() {
        return None;
    }
    let mut actions = Vec::with_capacity(bytes.len() / 4);
    for chunk in chunks {
        let action = u32::from_ne_bytes(chunk.try_into().ok()?);
        if action == 0 || actions.contains(&action) {
            return None;
        }
        actions.push(action);
    }
    Some(actions)
}

fn utf8_chunks(text: &str, max_bytes: usize) -> impl Iterator<Item = &str> {
    let mut remaining = text;
    std::iter::from_fn(move || {
        if remaining.is_empty() {
            return None;
        }
        let mut end = remaining.len().min(max_bytes.max(1));
        while !remaining.is_char_boundary(end) {
            end -= 1;
        }
        let (chunk, rest) = remaining.split_at(end);
        remaining = rest;
        Some(chunk)
    })
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
    pub(crate) fn text_input_target_for_text(&self) -> ShellCommandTarget {
        self.text_input.text_target()
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn text_input_target_for_key(&self) -> ShellCommandTarget {
        self.text_input.key_target()
    }

    #[cfg(feature = "flutter")]
    pub(crate) fn commit_text_input(&mut self, text: &str) -> bool {
        self.text_input.commit_text(text)
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

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(feature = "flutter")]
    fn flutter_snapshot(revision: u64, active: bool) -> TextInputSnapshot {
        TextInputSnapshot {
            revision,
            lifecycle_revision: revision,
            client_id: 17,
            active,
            secure: false,
            surrounding_text: Some("ni".to_owned()),
            cursor: 2,
            anchor: 2,
            content_hint: 0,
            content_purpose: 0,
            cursor_rectangle: None,
        }
    }

    fn focused_sessions() -> SessionState<u64, u64, u64> {
        let mut sessions = SessionState::default();
        sessions.set_focus(Some(Focus {
            surface: 10,
            client: 1,
        }));
        sessions.register(100, 1, 2);
        sessions.register(200, 2, 2);
        sessions
    }

    #[test]
    fn focus_enters_every_object_for_the_client_and_leave_clears_activation() {
        let mut sessions = focused_sessions();
        assert!(sessions.is_entered(&100));
        assert!(!sessions.is_entered(&200));
        sessions.request_enablement(&100, true);
        assert_eq!(sessions.commit(&100), CommitEffect::Activated);

        let transition = sessions.set_focus(Some(Focus {
            surface: 20,
            client: 2,
        }));
        assert_eq!(transition.left, vec![100]);
        assert_eq!(transition.entered, vec![200]);
        assert!(sessions.active_serial().is_none());
    }

    #[test]
    fn commits_are_double_buffered_and_serials_include_ignored_commits() {
        let mut sessions = focused_sessions();
        sessions.set_content_type(&100, 7, 8);
        assert_eq!(sessions.commit(&100), CommitEffect::Ignored);
        assert_eq!(sessions.instance(&100).unwrap().serial, 1);
        assert!(
            sessions
                .instance(&100)
                .unwrap()
                .current
                .content_type
                .is_none()
        );

        sessions.request_enablement(&100, true);
        sessions.set_content_type(&100, 3, 4);
        assert_eq!(sessions.commit(&100), CommitEffect::Activated);
        assert_eq!(sessions.instance(&100).unwrap().serial, 2);
        assert_eq!(
            sessions.instance(&100).unwrap().current.content_type,
            Some((3, 4))
        );
    }

    #[test]
    fn a_second_object_cannot_replace_the_active_editor() {
        let mut sessions = focused_sessions();
        sessions.register(101, 1, 2);
        sessions.request_enablement(&100, true);
        assert_eq!(sessions.commit(&100), CommitEffect::Activated);
        sessions.request_enablement(&101, true);
        assert_eq!(sessions.commit(&101), CommitEffect::Ignored);
        assert_eq!(sessions.active_serial(), Some((100, 1)));
    }

    #[test]
    fn version_two_cursor_rectangles_apply_with_the_surface_commit() {
        let mut sessions = focused_sessions();
        let rectangle = CursorRectangle {
            x: 2,
            y: 3,
            width: 4,
            height: 5,
        };
        sessions.request_enablement(&100, true);
        sessions.set_cursor_rectangle(&100, rectangle);
        sessions.commit(&100);
        assert_eq!(
            sessions.instance(&100).unwrap().current.cursor_rectangle,
            None
        );
        sessions.surface_committed(&10);
        assert_eq!(
            sessions.instance(&100).unwrap().current.cursor_rectangle,
            Some(rectangle)
        );
    }

    #[test]
    fn destroying_the_active_object_removes_the_editor() {
        let mut sessions = focused_sessions();
        sessions.request_enablement(&100, true);
        sessions.commit(&100);
        assert!(sessions.remove(&100));
        assert!(sessions.active_serial().is_none());
        assert!(sessions.instance(&100).is_none());
    }

    #[test]
    fn surrounding_offsets_are_utf8_byte_boundaries() {
        let valid = valid_surrounding_text("a中b".to_owned(), 4, 1).unwrap();
        assert_eq!(valid.cursor, 4);
        assert!(valid_surrounding_text("a中b".to_owned(), 2, 1).is_none());
        assert!(valid_surrounding_text("hello".to_owned(), -1, 0).is_none());
        assert!(valid_surrounding_text("x".repeat(4001), 0, 0).is_none());
    }

    #[test]
    fn utf8_commit_chunks_never_split_a_code_point() {
        assert_eq!(
            utf8_chunks("ab中文cd", 5).collect::<Vec<_>>(),
            vec!["ab中", "文cd"]
        );
    }

    #[test]
    fn broker_routes_by_capture_focus_and_editor_identity() {
        let mut broker = TextSessionBroker::default();
        broker.set_seat_focus(SeatFocusKind::Wayland);
        assert_eq!(broker.text_target(false), ShellCommandTarget::Seat);
        assert_eq!(broker.text_target(true), ShellCommandTarget::WaylandText);

        assert!(broker.observe_flutter_editor(4, flutter_snapshot(1, true)));
        // A native focus remains authoritative until Flutter owns capture.
        assert_eq!(broker.text_target(true), ShellCommandTarget::WaylandText);
        broker.set_shell_capture(true);
        assert_eq!(broker.text_target(true), ShellCommandTarget::Flutter);
        broker.observe_flutter_editor(4, flutter_snapshot(2, false));
        assert_eq!(broker.text_target(true), ShellCommandTarget::Captured);
    }

    #[test]
    fn stale_flutter_lifecycle_updates_cannot_revive_an_editor() {
        let mut broker = TextSessionBroker::default();
        assert!(broker.observe_flutter_editor(8, flutter_snapshot(3, false)));
        assert!(!broker.observe_flutter_editor(8, flutter_snapshot(2, true)));
        assert!(!broker.observe_flutter_editor(7, flutter_snapshot(99, true)));
        assert!(!broker.flutter_editor_active());
        broker.retire_flutter_generation();
        assert!(broker.observe_flutter_editor(9, flutter_snapshot(0, true)));
        assert!(broker.flutter_editor_active());
    }

    #[test]
    fn available_actions_reject_none_duplicates_and_malformed_arrays() {
        let bytes = [1_u32.to_ne_bytes(), 2_u32.to_ne_bytes()].concat();
        assert_eq!(parse_available_actions(&bytes), Some(vec![1, 2]));
        assert!(parse_available_actions(&0_u32.to_ne_bytes()).is_none());
        assert!(parse_available_actions(&[1, 2, 3]).is_none());
        let duplicate = [1_u32.to_ne_bytes(), 1_u32.to_ne_bytes()].concat();
        assert!(parse_available_actions(&duplicate).is_none());
    }

    #[test]
    fn advertises_the_complete_version_two_text_input_interface() {
        let display = smithay::reexports::wayland_server::Display::<RuntimeState>::new()
            .expect("Wayland display should initialize");
        let display_handle = display.handle();
        let manager = TextInputManager::new(&display_handle);
        let global = display_handle
            .backend_handle()
            .global_info(manager._global.clone())
            .expect("text-input manager global should remain registered");

        assert_eq!(global.interface.name, "zwp_text_input_manager_v3");
        assert_eq!(global.version, 2);
        assert!(!global.disabled);
    }

    #[test]
    fn requests_queued_before_enter_cannot_activate_after_focus_returns() {
        let mut sessions = SessionState::<u64, u64, u64>::default();
        sessions.register(100, 1, 2);
        sessions.request_enablement(&100, true);
        assert_eq!(sessions.commit(&100), CommitEffect::Ignored);

        sessions.set_focus(Some(Focus {
            surface: 10,
            client: 1,
        }));
        assert_eq!(sessions.commit(&100), CommitEffect::Ignored);
        assert!(sessions.active_serial().is_none());
    }
}
