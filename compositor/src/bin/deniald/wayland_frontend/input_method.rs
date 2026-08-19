//! External input methods and `zwp_input_method_v2`.
//!
//! Smithay's helper intentionally couples this protocol to Smithay's own
//! text-input implementation. Denial has a compositor-owned broker with both
//! Wayland and Flutter endpoints, so this adapter keeps the protocol state
//! local and feeds committed transactions through that broker.

use std::collections::{HashSet, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use smithay::backend::input::{KeyState, Keycode};
use smithay::input::Seat;
use smithay::input::keyboard::{
    GrabStartData as KeyboardGrabStartData, KeyboardGrab, KeyboardHandle, KeyboardInnerHandle,
    KeymapFile, ModifiersState,
};
use smithay::reexports::wayland_protocols::wp::text_input::zv3::server::zwp_text_input_v3::{
    ChangeCause, ContentHint, ContentPurpose,
};
use smithay::reexports::wayland_protocols_misc::zwp_input_method_v2::server::{
    zwp_input_method_keyboard_grab_v2::{self, ZwpInputMethodKeyboardGrabV2},
    zwp_input_method_manager_v2::{self, ZwpInputMethodManagerV2},
    zwp_input_method_v2::{self, ZwpInputMethodV2},
    zwp_input_popup_surface_v2::{self, ZwpInputPopupSurfaceV2},
};
use smithay::reexports::wayland_protocols_misc::zwp_virtual_keyboard_v1::server::{
    zwp_virtual_keyboard_manager_v1::{self, ZwpVirtualKeyboardManagerV1},
    zwp_virtual_keyboard_v1::{self, ZwpVirtualKeyboardV1},
};
use smithay::reexports::wayland_server::backend::{ClientId, GlobalId, ObjectId};
use smithay::reexports::wayland_server::protocol::{
    wl_keyboard::KeymapFormat, wl_surface::WlSurface,
};
use smithay::reexports::wayland_server::{
    Client, DataInit, Dispatch, DisplayHandle, GlobalDispatch, New, Resource,
};
use smithay::utils::{Logical, Rectangle, SERIAL_COUNTER, Serial};
use smithay::wayland::compositor::{get_role, give_role};
use smithay::wayland::input_method::INPUT_POPUP_SURFACE_ROLE;
use tracing::{debug, info, warn};

use super::RuntimeState;
use super::focus::KeyboardFocusTarget;
use super::handlers::DenialClientState;

const MANAGER_VERSION: u32 = 1;
const MAX_INPUT_METHOD_TEXT_BYTES: usize = 4000;
const MAX_INPUT_METHOD_POPUPS: usize = 8;
const MAX_VIRTUAL_KEYBOARDS: usize = 4;
const MAX_VIRTUAL_KEYMAP_BYTES: u32 = 1_048_576;
const MAX_VIRTUAL_KEYCODE: u32 = 0x2ff;
const XKB_KEYCODE_OFFSET: u32 = 8;
const PASSWORD_PURPOSE: u32 = 8;
const PIN_PURPOSE: u32 = 9;

fn is_public_session_client(client: &Client) -> bool {
    // Connections accepted on Denial's public socket carry this state.
    // Compositor-owned clients such as Xwayland use separate client data.
    client.get_data::<DenialClientState>().is_some()
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct InputMethodTransaction {
    pub commit_string: Option<String>,
    pub preedit_string: Option<(String, i32, i32)>,
    pub delete_surrounding: Option<(u32, u32)>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) enum EditorEndpoint {
    Wayland {
        resource: ObjectId,
        serial: u32,
        surface: WlSurface,
    },
    Flutter {
        generation: u64,
        lifecycle: u64,
        client_id: i64,
    },
}

impl EditorEndpoint {
    fn same_editor(&self, other: &Self) -> bool {
        match (self, other) {
            (
                Self::Wayland { resource: left, .. },
                Self::Wayland {
                    resource: right, ..
                },
            ) => left == right,
            (
                Self::Flutter {
                    generation: left_generation,
                    lifecycle: left_lifecycle,
                    client_id: left_client,
                },
                Self::Flutter {
                    generation: right_generation,
                    lifecycle: right_lifecycle,
                    client_id: right_client,
                },
            ) => {
                left_generation == right_generation
                    && left_lifecycle == right_lifecycle
                    && left_client == right_client
            }
            _ => false,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct EditorSnapshot {
    pub endpoint: EditorEndpoint,
    pub surrounding_text: Option<(String, u32, u32)>,
    pub change_cause: u32,
    pub content_hint: u32,
    pub content_purpose: u32,
    pub cursor_rectangle: Option<Rectangle<i32, Logical>>,
}

impl EditorSnapshot {
    fn permits_external_input_method(&self) -> bool {
        !matches!(self.content_purpose, PASSWORD_PURPOSE | PIN_PURPOSE)
    }
}

#[derive(Debug)]
struct InputMethodInstance {
    resource: ZwpInputMethodV2,
    client: ClientId,
    serial: u32,
    active: bool,
    active_endpoint: Option<EditorEndpoint>,
    pending: InputMethodTransaction,
}

#[derive(Clone, Debug)]
pub(super) struct InputMethodPopup {
    role: ZwpInputPopupSurfaceV2,
    surface: WlSurface,
}

impl InputMethodPopup {
    pub(super) fn surface(&self) -> &WlSurface {
        &self.surface
    }

    fn alive(&self) -> bool {
        self.role.is_alive() && self.surface.is_alive()
    }
}

#[derive(Debug, Default)]
struct KeyboardRouteState {
    resource: Option<ZwpInputMethodKeyboardGrabV2>,
    active: bool,
    input_method_keys: HashSet<u32>,
}

#[derive(Clone, Debug, Default)]
struct InputMethodKeyboardRoute {
    inner: Arc<Mutex<KeyboardRouteState>>,
    forwarding_virtual_key: Arc<AtomicBool>,
}

impl InputMethodKeyboardRoute {
    fn install(&self, resource: ZwpInputMethodKeyboardGrabV2) {
        let mut inner = self
            .inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        inner.resource = Some(resource);
    }

    fn remove(&self, resource: &ZwpInputMethodKeyboardGrabV2) {
        let mut inner = self
            .inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if inner.resource.as_ref() == Some(resource) {
            inner.resource = None;
            inner.active = false;
        }
    }

    fn set_active(&self, active: bool) {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .active = active;
    }

    fn resource(&self) -> Option<ZwpInputMethodKeyboardGrabV2> {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .resource
            .clone()
            .filter(Resource::is_alive)
    }

    fn forward_virtual_key(
        &self,
        keyboard: &KeyboardHandle<RuntimeState>,
        state: &mut RuntimeState,
        keycode: u32,
        key_state: KeyState,
        time: u32,
    ) {
        if self
            .forwarding_virtual_key
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            warn!(keycode, "discarding recursive virtual-keyboard event");
            return;
        }
        let _guard = VirtualForwardGuard(&self.forwarding_virtual_key);
        // The physical event has already updated the seat's XKB state before
        // the input-method grab received it. Forwarding here deliberately
        // bypasses both that update and the grab, preventing an IM -> virtual
        // keyboard -> IM loop while preserving the original modifier state.
        keyboard.input_forward(
            state,
            Keycode::new(keycode + XKB_KEYCODE_OFFSET),
            key_state,
            SERIAL_COUNTER.next_serial(),
            time,
            false,
        );
    }
}

struct VirtualForwardGuard<'a>(&'a AtomicBool);

impl Drop for VirtualForwardGuard<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

impl KeyboardGrab<RuntimeState> for InputMethodKeyboardRoute {
    fn input(
        &mut self,
        data: &mut RuntimeState,
        handle: &mut KeyboardInnerHandle<'_, RuntimeState>,
        keycode: Keycode,
        state: KeyState,
        modifiers: Option<ModifiersState>,
        serial: Serial,
        time: u32,
    ) {
        if self.forwarding_virtual_key.load(Ordering::Acquire) {
            handle.input(data, keycode, state, modifiers, serial, time);
            return;
        }
        let raw = keycode.raw().saturating_sub(8);
        let mut inner = self
            .inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let resource = inner.resource.clone().filter(Resource::is_alive);
        let route_to_input_method = match state {
            KeyState::Pressed if inner.active && resource.is_some() => {
                inner.input_method_keys.insert(raw);
                true
            }
            KeyState::Released if inner.input_method_keys.remove(&raw) => true,
            _ => false,
        };
        if route_to_input_method {
            if let Some(resource) = resource {
                resource.key(serial.into(), time, raw, state.into());
                if let Some(modifiers) = modifiers {
                    let serialized = modifiers.serialized;
                    resource.modifiers(
                        serial.into(),
                        serialized.depressed,
                        serialized.latched,
                        serialized.locked,
                        serialized.layout_effective,
                    );
                }
            }
            return;
        }
        drop(inner);
        handle.input(data, keycode, state, modifiers, serial, time);
    }

    fn set_focus(
        &mut self,
        data: &mut RuntimeState,
        handle: &mut KeyboardInnerHandle<'_, RuntimeState>,
        focus: Option<KeyboardFocusTarget>,
        serial: Serial,
    ) {
        handle.set_focus(data, focus, serial);
    }

    fn start_data(&self) -> &KeyboardGrabStartData<RuntimeState> {
        &KeyboardGrabStartData { focus: None }
    }

    fn unset(&mut self, _data: &mut RuntimeState) {}
}

#[derive(Debug)]
pub(super) struct InputMethodManager {
    _input_method_global: GlobalId,
    _virtual_keyboard_global: GlobalId,
    instance: Option<InputMethodInstance>,
    editor: Option<EditorSnapshot>,
    blocked: bool,
    popups: Vec<InputMethodPopup>,
    keyboard_route: InputMethodKeyboardRoute,
    virtual_keyboards: Vec<ZwpVirtualKeyboardV1>,
    flutter_transactions: VecDeque<(u64, i64, InputMethodTransaction)>,
}

impl InputMethodManager {
    pub(super) fn new(display: &DisplayHandle) -> Self {
        Self {
            _input_method_global: display
                .create_global::<RuntimeState, ZwpInputMethodManagerV2, _>(MANAGER_VERSION, ()),
            _virtual_keyboard_global: display
                .create_global::<RuntimeState, ZwpVirtualKeyboardManagerV1, _>(MANAGER_VERSION, ()),
            instance: None,
            editor: None,
            blocked: false,
            popups: Vec::new(),
            keyboard_route: InputMethodKeyboardRoute::default(),
            virtual_keyboards: Vec::new(),
            flutter_transactions: VecDeque::new(),
        }
    }

    pub(super) fn set_blocked(&mut self, blocked: bool) -> bool {
        if self.blocked == blocked {
            return false;
        }
        self.blocked = blocked;
        self.publish_editor_state()
    }

    pub(super) fn synchronize(&mut self, editor: Option<EditorSnapshot>) -> bool {
        if self.editor == editor {
            return false;
        }
        self.editor = editor;
        self.publish_editor_state()
    }

    fn publish_editor_state(&mut self) -> bool {
        let effective = self
            .editor
            .as_ref()
            .filter(|editor| !self.blocked && editor.permits_external_input_method())
            .cloned();
        let Some(instance) = self
            .instance
            .as_mut()
            .filter(|instance| instance.resource.is_alive())
        else {
            self.keyboard_route.set_active(false);
            return false;
        };
        let same_editor = match (
            instance.active,
            effective.as_ref(),
            instance.active_endpoint.as_ref(),
        ) {
            (true, Some(next), Some(current)) => next.endpoint.same_editor(current),
            _ => false,
        };
        if instance.active && (!same_editor || effective.is_none()) {
            instance.resource.deactivate();
            instance.resource.done();
            instance.serial = instance.serial.wrapping_add(1);
            instance.active = false;
            instance.active_endpoint = None;
            instance.pending = InputMethodTransaction::default();
        }
        if let Some(editor) = effective {
            if !instance.active {
                instance.resource.activate();
                instance.active = true;
            }
            // `same_editor` deliberately ignores mutable routing metadata such
            // as a Wayland text-input commit serial. Keep the identity stable,
            // but always retain the newest endpoint snapshot so transactions
            // are delivered with the serial the editor currently expects.
            instance.active_endpoint = Some(editor.endpoint.clone());
            if let Some((text, cursor, anchor)) = editor.surrounding_text {
                instance.resource.surrounding_text(text, cursor, anchor);
            }
            instance
                .resource
                .text_change_cause(change_cause(editor.change_cause));
            instance.resource.content_type(
                ContentHint::from_bits_truncate(editor.content_hint),
                content_purpose(editor.content_purpose),
            );
            let rectangle = editor.cursor_rectangle.unwrap_or_default();
            for popup in self.popups.iter().filter(|popup| popup.alive()) {
                popup.role.text_input_rectangle(
                    rectangle.loc.x,
                    rectangle.loc.y,
                    rectangle.size.w,
                    rectangle.size.h,
                );
            }
            instance.resource.done();
            instance.serial = instance.serial.wrapping_add(1);
        }
        self.keyboard_route.set_active(instance.active);
        self.popups.retain(InputMethodPopup::alive);
        true
    }

    fn can_register(&self) -> bool {
        // input-method-v2 permits one live input-method object per seat. Its
        // client owns the role until that object is destroyed or disconnects.
        self.instance
            .as_ref()
            .is_none_or(|instance| !instance.resource.is_alive())
    }

    fn register(&mut self, resource: ZwpInputMethodV2, client: ClientId) {
        debug_assert!(
            self.instance
                .as_ref()
                .is_none_or(|instance| !instance.resource.is_alive())
        );
        self.popups.clear();
        self.flutter_transactions.clear();
        self.instance = Some(InputMethodInstance {
            resource,
            client,
            serial: 0,
            active: false,
            active_endpoint: None,
            pending: InputMethodTransaction::default(),
        });
        self.publish_editor_state();
        info!("Wayland input method connected");
    }

    fn unregister(&mut self, resource: &ZwpInputMethodV2) -> bool {
        if self
            .instance
            .as_ref()
            .is_none_or(|instance| instance.resource != *resource)
        {
            return false;
        }
        self.instance = None;
        self.popups.clear();
        self.flutter_transactions.clear();
        self.virtual_keyboards.clear();
        self.keyboard_route.set_active(false);
        info!("Wayland input method disconnected");
        true
    }

    fn accepts(&self, resource: &ZwpInputMethodV2) -> bool {
        self.instance
            .as_ref()
            .is_some_and(|instance| instance.resource == *resource && resource.is_alive())
    }

    fn can_register_virtual_keyboard(&self, client: &ClientId) -> bool {
        self.virtual_keyboards
            .iter()
            .filter(|resource| resource.is_alive())
            .count()
            < MAX_VIRTUAL_KEYBOARDS
            && self
                .instance
                .as_ref()
                .is_some_and(|instance| instance.resource.is_alive() && &instance.client == client)
    }

    fn register_virtual_keyboard(&mut self, resource: ZwpVirtualKeyboardV1) {
        self.virtual_keyboards.retain(Resource::is_alive);
        self.virtual_keyboards.push(resource);
    }

    fn unregister_virtual_keyboard(&mut self, resource: &ZwpVirtualKeyboardV1) {
        self.virtual_keyboards
            .retain(|candidate| candidate != resource && candidate.is_alive());
    }

    fn accepts_virtual_keyboard(&self, resource: &ZwpVirtualKeyboardV1) -> bool {
        resource.is_alive()
            && self
                .virtual_keyboards
                .iter()
                .any(|candidate| candidate == resource)
    }

    fn stage_commit_string(&mut self, resource: &ZwpInputMethodV2, text: String) {
        if text.len() <= MAX_INPUT_METHOD_TEXT_BYTES
            && !text.contains('\0')
            && let Some(instance) = self
                .instance
                .as_mut()
                .filter(|instance| instance.resource == *resource)
        {
            instance.pending.commit_string = Some(text);
        }
    }

    fn stage_preedit(
        &mut self,
        resource: &ZwpInputMethodV2,
        text: String,
        cursor_begin: i32,
        cursor_end: i32,
    ) {
        let cursor_valid = (cursor_begin == -1 && cursor_end == -1)
            || (cursor_begin >= 0
                && cursor_end >= 0
                && usize::try_from(cursor_begin)
                    .is_ok_and(|cursor| cursor <= text.len() && text.is_char_boundary(cursor))
                && usize::try_from(cursor_end)
                    .is_ok_and(|cursor| cursor <= text.len() && text.is_char_boundary(cursor)));
        if text.len() <= MAX_INPUT_METHOD_TEXT_BYTES
            && !text.contains('\0')
            && cursor_valid
            && let Some(instance) = self
                .instance
                .as_mut()
                .filter(|instance| instance.resource == *resource)
        {
            instance.pending.preedit_string = Some((text, cursor_begin, cursor_end));
        }
    }

    fn stage_delete(&mut self, resource: &ZwpInputMethodV2, before: u32, after: u32) {
        if let Some(instance) = self
            .instance
            .as_mut()
            .filter(|instance| instance.resource == *resource)
        {
            instance.pending.delete_surrounding = Some((before, after));
        }
    }

    fn commit(
        &mut self,
        resource: &ZwpInputMethodV2,
        serial: u32,
    ) -> Option<(EditorEndpoint, InputMethodTransaction, bool)> {
        let current_endpoint = self.editor.as_ref()?.endpoint.clone();
        let instance = self
            .instance
            .as_mut()
            .filter(|instance| instance.resource == *resource)?;
        let transaction = std::mem::take(&mut instance.pending);
        if !instance.active {
            return None;
        }
        if !instance
            .active_endpoint
            .as_ref()
            .is_some_and(|active| active.same_editor(&current_endpoint))
        {
            return None;
        }
        instance.active_endpoint = Some(current_endpoint.clone());
        Some((current_endpoint, transaction, serial == instance.serial))
    }

    fn register_popup(&mut self, role: ZwpInputPopupSurfaceV2, surface: WlSurface) -> bool {
        self.popups.retain(InputMethodPopup::alive);
        if self.popups.len() >= MAX_INPUT_METHOD_POPUPS {
            return false;
        }
        let rectangle = self
            .editor
            .as_ref()
            .and_then(|editor| editor.cursor_rectangle)
            .unwrap_or_default();
        role.text_input_rectangle(
            rectangle.loc.x,
            rectangle.loc.y,
            rectangle.size.w,
            rectangle.size.h,
        );
        self.popups.push(InputMethodPopup { role, surface });
        true
    }

    fn unregister_popup(&mut self, role: &ZwpInputPopupSurfaceV2) -> bool {
        let previous = self.popups.len();
        self.popups.retain(|popup| popup.role != *role);
        self.popups.len() != previous
    }

    pub(super) fn visible_popups(&mut self) -> Vec<InputMethodPopup> {
        self.popups.retain(InputMethodPopup::alive);
        let visible = self
            .instance
            .as_ref()
            .is_some_and(|instance| instance.active && instance.resource.is_alive());
        if visible {
            self.popups.clone()
        } else {
            Vec::new()
        }
    }

    fn active_editor_ref(&self) -> Option<&EditorSnapshot> {
        let instance = self
            .instance
            .as_ref()
            .filter(|instance| instance.active && instance.resource.is_alive())?;
        let editor = self.editor.as_ref()?;
        instance
            .active_endpoint
            .as_ref()
            .is_some_and(|endpoint| endpoint.same_editor(&editor.endpoint))
            .then_some(editor)
    }

    pub(super) fn active_editor(&self) -> Option<EditorSnapshot> {
        self.active_editor_ref().cloned()
    }

    fn flutter_editor_active(&self) -> bool {
        self.active_editor_ref()
            .is_some_and(|editor| matches!(&editor.endpoint, EditorEndpoint::Flutter { .. }))
    }

    pub(super) fn owns_popup_surface(&self, surface: &WlSurface) -> bool {
        let mut root = surface.clone();
        while let Some(parent) = smithay::wayland::compositor::get_parent(&root) {
            root = parent;
        }
        self.popups
            .iter()
            .any(|popup| popup.surface == root && popup.alive())
    }

    fn queue_flutter_transaction(
        &mut self,
        generation: u64,
        client_id: i64,
        transaction: InputMethodTransaction,
    ) {
        const MAX_PENDING: usize = 64;
        if self.flutter_transactions.len() >= MAX_PENDING {
            self.flutter_transactions.pop_front();
            warn!("dropped oldest pending Flutter input-method transaction");
        }
        self.flutter_transactions
            .push_back((generation, client_id, transaction));
    }

    pub(super) fn drain_flutter_transactions(
        &mut self,
    ) -> impl Iterator<Item = (u64, i64, InputMethodTransaction)> + '_ {
        self.flutter_transactions.drain(..)
    }

    fn keyboard_route(&self) -> InputMethodKeyboardRoute {
        self.keyboard_route.clone()
    }

    fn refresh_keyboard(
        route: &InputMethodKeyboardRoute,
        keyboard: &KeyboardHandle<RuntimeState>,
        state: &mut RuntimeState,
        repeat_rate: i32,
        repeat_delay: i32,
    ) {
        let Some(resource) = route.resource() else {
            return;
        };
        let keymap = keyboard.with_xkb_state(state, |context| {
            let xkb = context.xkb().lock().unwrap();
            // SAFETY: the keymap is borrowed only while the XKB mutex is held.
            KeymapFile::new(unsafe { xkb.keymap() })
        });
        if let Err(error) = keymap.with_fd(false, |fd, size| {
            resource.keymap(KeymapFormat::XkbV1, fd, size as u32);
        }) {
            warn!(%error, "could not send input-method keymap");
        }
        resource.repeat_info(repeat_rate, repeat_delay);
        let modifiers = keyboard.modifier_state().serialized;
        resource.modifiers(
            SERIAL_COUNTER.next_serial().into(),
            modifiers.depressed,
            modifiers.latched,
            modifiers.locked,
            modifiers.layout_effective,
        );
    }
}

fn change_cause(raw: u32) -> ChangeCause {
    match raw {
        1 => ChangeCause::Other,
        _ => ChangeCause::InputMethod,
    }
}

fn content_purpose(raw: u32) -> ContentPurpose {
    match raw {
        1 => ContentPurpose::Alpha,
        2 => ContentPurpose::Digits,
        3 => ContentPurpose::Number,
        4 => ContentPurpose::Phone,
        5 => ContentPurpose::Url,
        6 => ContentPurpose::Email,
        7 => ContentPurpose::Name,
        8 => ContentPurpose::Password,
        9 => ContentPurpose::Pin,
        10 => ContentPurpose::Date,
        11 => ContentPurpose::Time,
        12 => ContentPurpose::Datetime,
        13 => ContentPurpose::Terminal,
        _ => ContentPurpose::Normal,
    }
}

#[derive(Clone, Copy, Debug)]
pub(super) struct InputMethodUserData {
    accepted: bool,
}

#[derive(Clone, Debug)]
pub(super) struct InputMethodPopupUserData {
    accepted: bool,
}

#[derive(Clone, Debug)]
pub(super) struct InputMethodKeyboardUserData {
    accepted: bool,
    grab_serial: Option<Serial>,
}

#[derive(Debug)]
pub(super) struct VirtualKeyboardUserData {
    accepted: bool,
    keymap_ready: AtomicBool,
}

impl VirtualKeyboardUserData {
    fn new(accepted: bool) -> Self {
        Self {
            accepted,
            keymap_ready: AtomicBool::new(false),
        }
    }

    fn ready(&self) -> bool {
        self.keymap_ready.load(Ordering::Acquire)
    }
}

fn virtual_key_state(raw: u32) -> Option<KeyState> {
    match raw {
        0 => Some(KeyState::Released),
        1 => Some(KeyState::Pressed),
        _ => None,
    }
}

impl GlobalDispatch<ZwpVirtualKeyboardManagerV1, ()> for RuntimeState {
    fn bind(
        _state: &mut Self,
        _handle: &DisplayHandle,
        _client: &Client,
        resource: New<ZwpVirtualKeyboardManagerV1>,
        _global_data: &(),
        data_init: &mut DataInit<'_, Self>,
    ) {
        data_init.init(resource, ());
    }

    fn can_view(client: Client, _global_data: &()) -> bool {
        is_public_session_client(&client)
    }
}

impl Dispatch<ZwpVirtualKeyboardManagerV1, ()> for RuntimeState {
    fn request(
        state: &mut Self,
        client: &Client,
        resource: &ZwpVirtualKeyboardManagerV1,
        request: zwp_virtual_keyboard_manager_v1::Request,
        _data: &(),
        _handle: &DisplayHandle,
        data_init: &mut DataInit<'_, Self>,
    ) {
        match request {
            zwp_virtual_keyboard_manager_v1::Request::CreateVirtualKeyboard { seat, id } => {
                let accepted = state.wayland.as_ref().is_some_and(|frontend| {
                    Seat::<RuntimeState>::from_resource(&seat)
                        .is_some_and(|seat| seat == frontend.seat)
                        && frontend
                            .input_method
                            .can_register_virtual_keyboard(&client.id())
                });
                let keyboard = data_init.init(id, VirtualKeyboardUserData::new(accepted));
                if accepted {
                    if let Some(frontend) = state.wayland.as_mut() {
                        frontend.input_method.register_virtual_keyboard(keyboard);
                    }
                } else {
                    resource.post_error(
                        zwp_virtual_keyboard_manager_v1::Error::Unauthorized,
                        "virtual keyboard is restricted to Denial's active input method",
                    );
                }
            }
            _ => unreachable!(),
        }
    }
}

impl Dispatch<ZwpVirtualKeyboardV1, VirtualKeyboardUserData> for RuntimeState {
    fn request(
        state: &mut Self,
        _client: &Client,
        resource: &ZwpVirtualKeyboardV1,
        request: zwp_virtual_keyboard_v1::Request,
        data: &VirtualKeyboardUserData,
        _handle: &DisplayHandle,
        _data_init: &mut DataInit<'_, Self>,
    ) {
        if !data.accepted {
            return;
        }
        match request {
            zwp_virtual_keyboard_v1::Request::Keymap {
                format,
                fd: _,
                size,
            } => {
                if format == u32::from(KeymapFormat::XkbV1)
                    && size > 0
                    && size <= MAX_VIRTUAL_KEYMAP_BYTES
                {
                    data.keymap_ready.store(true, Ordering::Release);
                } else {
                    resource.post_error(
                        zwp_virtual_keyboard_v1::Error::NoKeymap,
                        "invalid virtual-keyboard keymap",
                    );
                }
            }
            zwp_virtual_keyboard_v1::Request::Key {
                time,
                key,
                state: key_state,
            } => {
                if !data.ready() {
                    resource.post_error(
                        zwp_virtual_keyboard_v1::Error::NoKeymap,
                        "virtual-keyboard key event arrived before its keymap",
                    );
                    return;
                }
                let Some(key_state) = virtual_key_state(key_state) else {
                    warn!(key_state, "discarding invalid virtual-keyboard key state");
                    return;
                };
                if key > MAX_VIRTUAL_KEYCODE {
                    warn!(key, "discarding out-of-range virtual-keyboard keycode");
                    return;
                }
                let Some((keyboard, route, flutter_editor_active)) =
                    state.wayland.as_ref().and_then(|frontend| {
                        frontend
                            .input_method
                            .accepts_virtual_keyboard(resource)
                            .then(|| {
                                Some((
                                    frontend.seat.get_keyboard()?,
                                    frontend.input_method.keyboard_route(),
                                    frontend.input_method.flutter_editor_active(),
                                ))
                            })?
                    })
                else {
                    return;
                };
                let keycode = Keycode::new(key + XKB_KEYCODE_OFFSET);
                if super::input::dispatch_input_method_key_to_flutter(
                    state,
                    &keyboard,
                    keycode,
                    key_state,
                    flutter_editor_active,
                ) {
                    return;
                }
                route.forward_virtual_key(&keyboard, state, key, key_state, time);
            }
            zwp_virtual_keyboard_v1::Request::Modifiers {
                mods_depressed: _,
                mods_latched: _,
                mods_locked: _,
                group: _,
            } => {
                if !data.ready() {
                    resource.post_error(
                        zwp_virtual_keyboard_v1::Error::NoKeymap,
                        "virtual-keyboard modifiers arrived before its keymap",
                    );
                    return;
                }
                // The seat state was already updated by the corresponding
                // physical key before the input method received it. Re-advertise that
                // canonical state to the focused client after the forwarded
                // virtual key, matching wl_keyboard event ordering.
                let keyboard = state.wayland.as_ref().and_then(|frontend| {
                    frontend
                        .input_method
                        .accepts_virtual_keyboard(resource)
                        .then(|| frontend.seat.get_keyboard())?
                });
                if let Some(keyboard) = keyboard {
                    keyboard.advertise_modifier_state(state);
                }
            }
            zwp_virtual_keyboard_v1::Request::Destroy => {}
            _ => unreachable!(),
        }
    }

    fn destroyed(
        state: &mut Self,
        _client: ClientId,
        resource: &ZwpVirtualKeyboardV1,
        data: &VirtualKeyboardUserData,
    ) {
        if data.accepted
            && let Some(frontend) = state.wayland.as_mut()
        {
            frontend.input_method.unregister_virtual_keyboard(resource);
        }
    }
}

impl GlobalDispatch<ZwpInputMethodManagerV2, ()> for RuntimeState {
    fn bind(
        _state: &mut Self,
        _handle: &DisplayHandle,
        _client: &Client,
        resource: New<ZwpInputMethodManagerV2>,
        _global_data: &(),
        data_init: &mut DataInit<'_, Self>,
    ) {
        data_init.init(resource, ());
    }

    fn can_view(client: Client, _global_data: &()) -> bool {
        is_public_session_client(&client)
    }
}

impl Dispatch<ZwpInputMethodManagerV2, ()> for RuntimeState {
    fn request(
        state: &mut Self,
        client: &Client,
        _resource: &ZwpInputMethodManagerV2,
        request: zwp_input_method_manager_v2::Request,
        _data: &(),
        _handle: &DisplayHandle,
        data_init: &mut DataInit<'_, Self>,
    ) {
        match request {
            zwp_input_method_manager_v2::Request::GetInputMethod { seat, input_method } => {
                let accepted = state.wayland.as_ref().is_some_and(|frontend| {
                    Seat::<RuntimeState>::from_resource(&seat)
                        .is_some_and(|seat| seat == frontend.seat)
                        && frontend.input_method.can_register()
                });
                let resource = data_init.init(input_method, InputMethodUserData { accepted });
                if accepted {
                    if let Some(frontend) = state.wayland.as_mut() {
                        frontend
                            .input_method
                            .register(resource.clone(), client.id());
                    }
                    state.scene_sync.mark_dirty();
                } else {
                    resource.unavailable();
                }
            }
            zwp_input_method_manager_v2::Request::Destroy => {}
            _ => unreachable!(),
        }
    }
}

impl Dispatch<ZwpInputMethodV2, InputMethodUserData> for RuntimeState {
    fn request(
        state: &mut Self,
        _client: &Client,
        resource: &ZwpInputMethodV2,
        request: zwp_input_method_v2::Request,
        data: &InputMethodUserData,
        _handle: &DisplayHandle,
        data_init: &mut DataInit<'_, Self>,
    ) {
        if !data.accepted {
            return;
        }
        match request {
            zwp_input_method_v2::Request::CommitString { text } => {
                if let Some(frontend) = state.wayland.as_mut() {
                    frontend.input_method.stage_commit_string(resource, text);
                }
            }
            zwp_input_method_v2::Request::SetPreeditString {
                text,
                cursor_begin,
                cursor_end,
            } => {
                if let Some(frontend) = state.wayland.as_mut() {
                    frontend
                        .input_method
                        .stage_preedit(resource, text, cursor_begin, cursor_end);
                }
            }
            zwp_input_method_v2::Request::DeleteSurroundingText {
                before_length,
                after_length,
            } => {
                if let Some(frontend) = state.wayland.as_mut() {
                    frontend
                        .input_method
                        .stage_delete(resource, before_length, after_length);
                }
            }
            zwp_input_method_v2::Request::Commit { serial } => {
                let committed = state
                    .wayland
                    .as_mut()
                    .and_then(|frontend| frontend.input_method.commit(resource, serial));
                if let Some((endpoint, transaction, serial_matches)) = committed {
                    let delivered = match endpoint {
                        EditorEndpoint::Wayland {
                            resource, serial, ..
                        } => state.wayland.as_mut().is_some_and(|frontend| {
                            frontend.text_input.apply_input_method(
                                &resource,
                                serial,
                                &transaction,
                                serial_matches,
                            )
                        }),
                        EditorEndpoint::Flutter {
                            generation,
                            client_id,
                            ..
                        } => {
                            if !serial_matches {
                                debug!(
                                    generation,
                                    client_id, "discarded stale Flutter input-method transaction"
                                );
                                false
                            } else if let Some(frontend) = state.wayland.as_mut() {
                                frontend.input_method.queue_flutter_transaction(
                                    generation,
                                    client_id,
                                    transaction,
                                );
                                true
                            } else {
                                false
                            }
                        }
                    };
                    if !delivered {
                        debug!("input-method transaction lost its active editor");
                    }
                }
            }
            zwp_input_method_v2::Request::GetInputPopupSurface { id, surface } => {
                let accepted = state
                    .wayland
                    .as_ref()
                    .is_some_and(|frontend| frontend.input_method.accepts(resource))
                    && (give_role(&surface, INPUT_POPUP_SURFACE_ROLE).is_ok()
                        || get_role(&surface) == Some(INPUT_POPUP_SURFACE_ROLE));
                if !accepted && get_role(&surface).is_some() {
                    resource.post_error(0u32, "surface already has a role");
                }
                let role = data_init.init(id, InputMethodPopupUserData { accepted });
                if accepted
                    && let Some(frontend) = state.wayland.as_mut()
                    && frontend.input_method.register_popup(role, surface)
                {
                    state.scene_sync.mark_dirty();
                }
            }
            zwp_input_method_v2::Request::GrabKeyboard { keyboard } => {
                install_keyboard_grab(state, resource, keyboard, data_init);
            }
            zwp_input_method_v2::Request::Destroy => {}
            _ => unreachable!(),
        }
    }

    fn destroyed(
        state: &mut Self,
        _client: ClientId,
        resource: &ZwpInputMethodV2,
        data: &InputMethodUserData,
    ) {
        if data.accepted
            && state
                .wayland
                .as_mut()
                .is_some_and(|frontend| frontend.input_method.unregister(resource))
        {
            state.scene_sync.mark_dirty();
        }
    }
}

fn install_keyboard_grab(
    state: &mut RuntimeState,
    owner: &ZwpInputMethodV2,
    keyboard_resource: New<ZwpInputMethodKeyboardGrabV2>,
    data_init: &mut DataInit<'_, RuntimeState>,
) {
    let accepted = state
        .wayland
        .as_ref()
        .is_some_and(|frontend| frontend.input_method.accepts(owner));
    let grab_serial = accepted.then(|| SERIAL_COUNTER.next_serial());
    let resource = data_init.init(
        keyboard_resource,
        InputMethodKeyboardUserData {
            accepted,
            grab_serial,
        },
    );
    if !accepted {
        return;
    }
    let Some((keyboard, route, repeat_rate, repeat_delay)) =
        state.wayland.as_ref().and_then(|frontend| {
            Some((
                frontend.seat.get_keyboard()?,
                frontend.input_method.keyboard_route(),
                i32::try_from(frontend.settings.keyboard().repeat_rate_hz).ok()?,
                i32::try_from(frontend.settings.keyboard().repeat_delay_ms).ok()?,
            ))
        })
    else {
        return;
    };
    route.install(resource);
    keyboard.set_grab(
        state,
        route.clone(),
        grab_serial.expect("accepted grab has a serial"),
    );
    InputMethodManager::refresh_keyboard(&route, &keyboard, state, repeat_rate, repeat_delay);
}

pub(super) fn refresh_keyboard_grab(state: &mut RuntimeState, repeat_rate: i32, repeat_delay: i32) {
    let Some((keyboard, route)) = state.wayland.as_ref().and_then(|frontend| {
        Some((
            frontend.seat.get_keyboard()?,
            frontend.input_method.keyboard_route(),
        ))
    }) else {
        return;
    };
    InputMethodManager::refresh_keyboard(&route, &keyboard, state, repeat_rate, repeat_delay);
}

impl Dispatch<ZwpInputPopupSurfaceV2, InputMethodPopupUserData> for RuntimeState {
    fn request(
        _state: &mut Self,
        _client: &Client,
        _resource: &ZwpInputPopupSurfaceV2,
        request: zwp_input_popup_surface_v2::Request,
        _data: &InputMethodPopupUserData,
        _handle: &DisplayHandle,
        _data_init: &mut DataInit<'_, Self>,
    ) {
        match request {
            zwp_input_popup_surface_v2::Request::Destroy => {}
            _ => unreachable!(),
        }
    }

    fn destroyed(
        state: &mut Self,
        _client: ClientId,
        resource: &ZwpInputPopupSurfaceV2,
        data: &InputMethodPopupUserData,
    ) {
        if data.accepted
            && state
                .wayland
                .as_mut()
                .is_some_and(|frontend| frontend.input_method.unregister_popup(resource))
        {
            state.scene_sync.mark_dirty();
        }
    }
}

impl Dispatch<ZwpInputMethodKeyboardGrabV2, InputMethodKeyboardUserData> for RuntimeState {
    fn request(
        _state: &mut Self,
        _client: &Client,
        _resource: &ZwpInputMethodKeyboardGrabV2,
        request: zwp_input_method_keyboard_grab_v2::Request,
        _data: &InputMethodKeyboardUserData,
        _handle: &DisplayHandle,
        _data_init: &mut DataInit<'_, Self>,
    ) {
        match request {
            zwp_input_method_keyboard_grab_v2::Request::Release => {}
            _ => unreachable!(),
        }
    }

    fn destroyed(
        state: &mut Self,
        _client: ClientId,
        resource: &ZwpInputMethodKeyboardGrabV2,
        data: &InputMethodKeyboardUserData,
    ) {
        if !data.accepted {
            return;
        }
        let Some((keyboard, route)) = state.wayland.as_ref().and_then(|frontend| {
            Some((
                frontend.seat.get_keyboard()?,
                frontend.input_method.keyboard_route(),
            ))
        }) else {
            return;
        };
        route.remove(resource);
        if data
            .grab_serial
            .is_some_and(|serial| keyboard.has_grab(serial))
        {
            keyboard.unset_grab(state);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn flutter_editor(client_id: i64, purpose: u32) -> EditorSnapshot {
        EditorSnapshot {
            endpoint: EditorEndpoint::Flutter {
                generation: 4,
                lifecycle: 7,
                client_id,
            },
            surrounding_text: Some(("ni".to_owned(), 2, 2)),
            change_cause: 0,
            content_hint: 3,
            content_purpose: purpose,
            cursor_rectangle: Some(Rectangle::new((10, 20).into(), (1, 18).into())),
        }
    }

    #[test]
    fn endpoint_identity_separates_flutter_replacements_from_state_updates() {
        let first = flutter_editor(1, 0).endpoint;
        let same = flutter_editor(1, 0).endpoint;
        let replacement = flutter_editor(2, 0).endpoint;
        assert!(first.same_editor(&same));
        assert!(!first.same_editor(&replacement));
    }

    #[test]
    fn password_and_pin_purposes_never_activate_an_external_engine() {
        assert!(flutter_editor(1, 0).permits_external_input_method());
        assert!(!flutter_editor(1, PASSWORD_PURPOSE).permits_external_input_method());
        assert!(!flutter_editor(1, PIN_PURPOSE).permits_external_input_method());
    }

    #[test]
    fn preedit_cursor_validation_uses_utf8_byte_boundaries() {
        let text = "你a";
        let valid = |cursor: i32| {
            cursor >= 0
                && usize::try_from(cursor)
                    .is_ok_and(|cursor| cursor <= text.len() && text.is_char_boundary(cursor))
        };
        assert!(valid(0));
        assert!(valid(3));
        assert!(valid(4));
        assert!(!valid(1));
        assert!(!valid(2));
    }

    #[test]
    fn virtual_keyboard_accepts_only_wayland_key_states() {
        assert_eq!(virtual_key_state(0), Some(KeyState::Released));
        assert_eq!(virtual_key_state(1), Some(KeyState::Pressed));
        assert_eq!(virtual_key_state(2), None);
        assert_eq!(virtual_key_state(u32::MAX), None);
    }
}
