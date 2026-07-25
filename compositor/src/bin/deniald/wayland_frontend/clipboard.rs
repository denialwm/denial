use std::fs::File;
use std::io::Write;
use std::os::fd::{AsFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::thread;
use std::time::Duration;

use smithay::backend::input::{ButtonState, KeyState};
use smithay::input::dnd::{DnDGrab, DndAction, Source, SourceMetadata};
use smithay::input::keyboard::{FilterResult, Keycode};
use smithay::input::pointer::{ButtonEvent, Focus, GrabStartData};
use smithay::reexports::calloop::{
    Interest, Mode, PostAction, generic::Generic, timer::TimeoutAction, timer::Timer,
};
use smithay::reexports::rustix::fs::{OFlags, fcntl_getfl, fcntl_setfl};
use smithay::reexports::rustix::io::{Errno, read, write};
use smithay::utils::{IsAlive, SERIAL_COUNTER};
use smithay::wayland::selection::SelectionTarget;
use smithay::wayland::selection::data_device::{
    clear_data_device_selection, current_data_device_selection_userdata,
    request_data_device_client_selection, set_data_device_selection,
};
use tracing::{debug, warn};

use super::super::clipboard::{
    ClipboardAction, ClipboardCapturePlan, ClipboardDragPayload, ClipboardOrigin,
    ClipboardSelection, ClipboardSourceIdentity,
};
use super::{
    KeyboardFocusTarget, RuntimeState, WaylandFrontend, XdgToplevelSurfaceData, with_states,
};

const CAPTURE_TIMEOUT: Duration = Duration::from_secs(3);
const SEND_TIMEOUT: Duration = Duration::from_secs(5);
const TRANSFER_CHUNK_BYTES: usize = 64 * 1024;
const BTN_LEFT: u32 = 0x110;
const MAX_DND_TRANSFERS: usize = 8;

struct ClipboardDndSource {
    item_id: u64,
    representations: Vec<(String, Arc<[u8]>)>,
    alive: AtomicBool,
    in_flight: Arc<AtomicUsize>,
}

impl ClipboardDndSource {
    fn new(payload: ClipboardDragPayload) -> Self {
        Self {
            item_id: payload.item_id,
            representations: payload.representations,
            alive: AtomicBool::new(true),
            in_flight: Arc::new(AtomicUsize::new(0)),
        }
    }
}

impl IsAlive for ClipboardDndSource {
    fn alive(&self) -> bool {
        self.alive.load(Ordering::Acquire)
    }
}

impl Source for ClipboardDndSource {
    fn metadata(&self) -> Option<SourceMetadata> {
        Some(SourceMetadata {
            mime_types: self
                .representations
                .iter()
                .map(|(mime_type, _)| mime_type.clone())
                .collect(),
            dnd_actions: std::iter::once(DndAction::Copy).collect(),
        })
    }

    fn choose_action(&self, action: DndAction) {
        debug!(
            item_id = self.item_id,
            ?action,
            "clipboard drag action selected"
        );
    }

    fn send(&self, mime_type: &str, fd: OwnedFd) {
        if self
            .in_flight
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
                (count < MAX_DND_TRANSFERS).then_some(count + 1)
            })
            .is_err()
        {
            warn!(
                item_id = self.item_id,
                mime_type, "clipboard drag transfer limit reached"
            );
            return;
        }
        let Some(data) = self
            .representations
            .iter()
            .find(|(offered, _)| offered == mime_type)
            .map(|(_, data)| Arc::clone(data))
        else {
            self.in_flight.fetch_sub(1, Ordering::AcqRel);
            warn!(
                item_id = self.item_id,
                mime_type, "clipboard drag target requested an unknown MIME type"
            );
            return;
        };
        let item_id = self.item_id;
        let mime_type = mime_type.to_owned();
        let transfer_mime_type = mime_type.clone();
        let in_flight = Arc::clone(&self.in_flight);
        let spawn = thread::Builder::new()
            .name("denial-clipboard-dnd".to_owned())
            .spawn(move || {
                let mut file = File::from(fd);
                if let Err(error) = file.write_all(&data) {
                    debug!(
                        %error,
                        item_id,
                        mime_type = transfer_mime_type,
                        "clipboard drag data transfer failed"
                    );
                }
                in_flight.fetch_sub(1, Ordering::AcqRel);
            });
        if let Err(error) = spawn {
            self.in_flight.fetch_sub(1, Ordering::AcqRel);
            warn!(
                %error,
                item_id,
                mime_type, "could not start clipboard drag data transfer"
            );
        }
    }

    fn drop_performed(&self) {
        debug!(item_id = self.item_id, "clipboard drag dropped");
    }

    fn cancel(&self) {
        self.alive.store(false, Ordering::Release);
        debug!(item_id = self.item_id, "clipboard drag cancelled");
    }

    fn finished(&self) {
        self.alive.store(false, Ordering::Release);
        debug!(item_id = self.item_id, "clipboard drag finished");
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum CaptureOwner {
    Wayland,
    Xwayland,
}

impl CaptureOwner {
    fn origin(self) -> ClipboardOrigin {
        match self {
            Self::Wayland => ClipboardOrigin::Wayland,
            Self::Xwayland => ClipboardOrigin::X11,
        }
    }
}

pub(super) fn observe_selection(
    state: &mut RuntimeState,
    owner: CaptureOwner,
    mime_types: &[String],
) {
    cancel_clipboard_captures(state);
    let identity = state.wayland.as_ref().and_then(focused_source_identity);
    let plan = state
        .clipboard
        .observe_external_selection(owner.origin(), mime_types, identity);
    let Some(plan) = plan else {
        return;
    };
    let handle = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .loop_handle
        .clone();
    handle.insert_idle(move |state| start_capture(state, owner, plan));
}

pub(crate) fn cancel_clipboard_captures(state: &mut RuntimeState) {
    let Some(handle) = state
        .wayland
        .as_ref()
        .map(|frontend| frontend.loop_handle.clone())
    else {
        state.clipboard_capture_tokens.clear();
        return;
    };
    for token in state.clipboard_capture_tokens.drain(..) {
        handle.remove(token);
    }
}

fn start_capture(state: &mut RuntimeState, owner: CaptureOwner, plan: ClipboardCapturePlan) {
    if !state.clipboard.capture_is_current(plan.epoch) {
        return;
    }
    for representation in plan.representations {
        if !state.clipboard.capture_is_current(plan.epoch) {
            break;
        }
        if let Err(error) = start_representation_capture(
            state,
            owner,
            plan.epoch,
            representation.mime_type,
            representation.max_bytes,
        ) {
            warn!(%error, "could not start clipboard-history capture");
        }
    }
}

fn start_representation_capture(
    state: &mut RuntimeState,
    owner: CaptureOwner,
    epoch: u64,
    mime_type: String,
    maximum: usize,
) -> Result<(), Box<dyn std::error::Error>> {
    let (reader, writer) = UnixStream::pair()?;
    reader.set_nonblocking(true)?;
    let manager = state.clipboard.clone();
    let completed = Arc::new(AtomicBool::new(false));
    let reader_completed = Arc::clone(&completed);
    let reader_mime = mime_type.clone();
    let mut payload = Vec::new();
    let reader_token = state.wayland.as_ref().expect("missing Wayland frontend").loop_handle.insert_source(
        Generic::new(reader, Interest::READ, Mode::Level),
        move |_, reader, _| {
            let mut chunk = [0u8; TRANSFER_CHUNK_BYTES];
            loop {
                match read(reader.as_fd(), &mut chunk) {
                    Ok(0) => {
                        if !reader_completed.swap(true, Ordering::AcqRel) {
                            manager.finish_capture(
                                epoch,
                                &reader_mime,
                                Some(std::mem::take(&mut payload)),
                            );
                        }
                        return Ok(PostAction::Remove);
                    }
                    Ok(length) => {
                        let Some(next) = payload.len().checked_add(length) else {
                            if !reader_completed.swap(true, Ordering::AcqRel) {
                                manager.finish_capture(epoch, &reader_mime, None);
                            }
                            return Ok(PostAction::Remove);
                        };
                        if next > maximum {
                            if !reader_completed.swap(true, Ordering::AcqRel) {
                                manager.finish_capture(epoch, &reader_mime, None);
                            }
                            return Ok(PostAction::Remove);
                        }
                        payload.extend_from_slice(&chunk[..length]);
                    }
                    Err(Errno::AGAIN) => return Ok(PostAction::Continue),
                    Err(error) => {
                        debug!(%error, mime_type = reader_mime, "clipboard capture read failed");
                        if !reader_completed.swap(true, Ordering::AcqRel) {
                            manager.finish_capture(epoch, &reader_mime, None);
                        }
                        return Ok(PostAction::Remove);
                    }
                }
            }
        },
    )?;
    state.clipboard_capture_tokens.push(reader_token);

    let request = match owner {
        CaptureOwner::Wayland => {
            let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
            request_data_device_client_selection(
                &frontend.seat,
                mime_type.clone(),
                OwnedFd::from(writer),
            )
            .map_err(|error| error.to_string())
        }
        CaptureOwner::Xwayland => state
            .wayland
            .as_mut()
            .expect("missing Wayland frontend")
            .xwm
            .as_mut()
            .ok_or_else(|| "Xwayland clipboard owner disappeared".to_owned())
            .and_then(|xwm| {
                xwm.send_selection(
                    SelectionTarget::Clipboard,
                    mime_type.clone(),
                    OwnedFd::from(writer),
                )
                .map_err(|error| error.to_string())
            }),
    };
    if let Err(error) = request {
        state
            .wayland
            .as_ref()
            .expect("missing Wayland frontend")
            .loop_handle
            .remove(reader_token);
        if !completed.swap(true, Ordering::AcqRel) {
            state.clipboard.finish_capture(epoch, &mime_type, None);
        }
        return Err(error.into());
    }

    let timeout_completed = Arc::clone(&completed);
    let timeout_manager = state.clipboard.clone();
    let timeout_mime = mime_type;
    let timeout_handle = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .loop_handle
        .clone();
    let removal_handle = timeout_handle.clone();
    let timer_token =
        timeout_handle.insert_source(Timer::from_duration(CAPTURE_TIMEOUT), move |_, _, _| {
            if !timeout_completed.swap(true, Ordering::AcqRel) {
                removal_handle.remove(reader_token);
                timeout_manager.finish_capture(epoch, &timeout_mime, None);
            }
            TimeoutAction::Drop
        })?;
    state.clipboard_capture_tokens.push(timer_token);
    Ok(())
}

pub(super) fn send_retained_selection(
    state: &mut RuntimeState,
    item_id: u64,
    mime_type: &str,
    fd: OwnedFd,
) {
    let Some(data) = state.clipboard.retained_data(item_id, mime_type) else {
        debug!(
            item_id,
            mime_type, "retained clipboard representation is unavailable"
        );
        return;
    };
    let handle = state
        .wayland
        .as_ref()
        .expect("missing Wayland frontend")
        .loop_handle
        .clone();
    if let Err(error) = install_nonblocking_writer(handle, fd, data) {
        warn!(%error, item_id, mime_type, "could not serve retained clipboard data");
    }
}

fn install_nonblocking_writer(
    handle: smithay::reexports::calloop::LoopHandle<'static, RuntimeState>,
    fd: OwnedFd,
    data: Arc<[u8]>,
) -> Result<(), Box<dyn std::error::Error>> {
    let flags = fcntl_getfl(&fd).unwrap_or(OFlags::WRONLY);
    fcntl_setfl(&fd, flags | OFlags::NONBLOCK)?;
    let completed = Arc::new(AtomicBool::new(false));
    let writer_completed = Arc::clone(&completed);
    let mut offset = 0usize;
    let writer_token = handle.insert_source(
        Generic::new(fd, Interest::WRITE, Mode::Level),
        move |_, fd, _| {
            while offset < data.len() {
                match write(fd.as_fd(), &data[offset..]) {
                    Ok(0) => return Ok(PostAction::Continue),
                    Ok(length) => offset += length,
                    Err(Errno::AGAIN) => return Ok(PostAction::Continue),
                    Err(error) => {
                        debug!(%error, "retained clipboard write failed");
                        writer_completed.store(true, Ordering::Release);
                        return Ok(PostAction::Remove);
                    }
                }
            }
            writer_completed.store(true, Ordering::Release);
            Ok(PostAction::Remove)
        },
    )?;
    let timeout_handle = handle.clone();
    handle.insert_source(Timer::from_duration(SEND_TIMEOUT), move |_, _, _| {
        if !completed.swap(true, Ordering::AcqRel) {
            timeout_handle.remove(writer_token);
        }
        TimeoutAction::Drop
    })?;
    Ok(())
}

pub(crate) fn apply_clipboard_actions(state: &mut RuntimeState, actions: Vec<ClipboardAction>) {
    let manager = state.clipboard.clone();
    if state.wayland.is_none() {
        return;
    }
    for action in actions {
        match action {
            ClipboardAction::Publish {
                epoch,
                item_id,
                paste,
            } => {
                let Some(mime_types) = manager.retained_mime_types(epoch, item_id) else {
                    continue;
                };
                {
                    let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                    set_data_device_selection(
                        &frontend.display_handle,
                        &frontend.seat,
                        mime_types.clone(),
                        ClipboardSelection::History { item_id },
                    );
                    if let Some(xwm) = frontend.xwm.as_mut()
                        && let Err(error) =
                            xwm.new_selection(SelectionTarget::Clipboard, Some(mime_types))
                    {
                        warn!(%error, item_id, "could not publish retained clipboard to Xwayland");
                    }
                }
                if paste {
                    paste_into_focused_client(state);
                }
            }
            ClipboardAction::Clear { epoch } => {
                let _ = epoch;
                let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
                let should_clear = current_data_device_selection_userdata(&frontend.seat)
                    .and_then(|selection| selection.history_item_id())
                    .is_some();
                if !should_clear {
                    continue;
                }
                clear_data_device_selection(&frontend.display_handle, &frontend.seat);
                if let Some(xwm) = frontend.xwm.as_mut()
                    && let Err(error) = xwm.new_selection(SelectionTarget::Clipboard, None)
                {
                    warn!(%error, "could not clear retained Xwayland clipboard");
                }
            }
            ClipboardAction::StartDrag { item_id } => start_retained_drag(state, item_id),
        }
    }
}

fn paste_into_focused_client(state: &mut RuntimeState) {
    const XKB_LEFT_CTRL: u32 = 29 + 8;
    const XKB_V: u32 = 47 + 8;

    let (keyboard, time) = {
        let frontend = state.wayland.as_ref().expect("missing Wayland frontend");
        (
            frontend.seat.get_keyboard().expect("seat has no keyboard"),
            frontend.start_time.elapsed().as_millis() as u32,
        )
    };
    if keyboard.current_focus().is_none() {
        debug!("clipboard activation has no focused client to paste into");
        return;
    }
    let ctrl = Keycode::new(XKB_LEFT_CTRL);
    let v = Keycode::new(XKB_V);
    if keyboard.pressed_keys().contains(&v) {
        warn!("clipboard activation skipped paste while V is already pressed");
        return;
    }
    let inject_ctrl = !keyboard.modifier_state().ctrl;
    if inject_ctrl {
        keyboard.input::<(), _>(
            state,
            ctrl,
            KeyState::Pressed,
            SERIAL_COUNTER.next_serial(),
            time,
            |_, _, _| FilterResult::Forward,
        );
    }
    keyboard.input::<(), _>(
        state,
        v,
        KeyState::Pressed,
        SERIAL_COUNTER.next_serial(),
        time,
        |_, _, _| FilterResult::Forward,
    );
    keyboard.input::<(), _>(
        state,
        v,
        KeyState::Released,
        SERIAL_COUNTER.next_serial(),
        time,
        |_, _, _| FilterResult::Forward,
    );
    if inject_ctrl {
        keyboard.input::<(), _>(
            state,
            ctrl,
            KeyState::Released,
            SERIAL_COUNTER.next_serial(),
            time,
            |_, _, _| FilterResult::Forward,
        );
    }
    debug!("pasted activated clipboard item into focused client");
}

fn start_retained_drag(state: &mut RuntimeState, item_id: u64) {
    if state.secure_session_locked() || !state.flutter_input.pointer_captured() {
        warn!(
            item_id,
            "rejected clipboard drag without an active shell pointer press"
        );
        return;
    }
    if state
        .wayland
        .as_ref()
        .is_some_and(|frontend| frontend.clipboard_drag_active)
    {
        warn!(item_id, "rejected overlapping clipboard drag");
        return;
    }
    let Some(payload) = state.clipboard.drag_payload(item_id) else {
        warn!(
            item_id,
            "rejected clipboard drag for an unavailable history item"
        );
        return;
    };
    let (press, seat, display_handle) = {
        let frontend = state.wayland.as_mut().expect("missing Wayland frontend");
        let Some(press) = frontend.flutter_pointer_press.take() else {
            warn!(
                item_id,
                "rejected clipboard drag without pointer press metadata"
            );
            return;
        };
        (
            press,
            frontend.seat.clone(),
            frontend.display_handle.clone(),
        )
    };
    if press.button != BTN_LEFT {
        warn!(
            item_id,
            button = press.button,
            "rejected clipboard drag from a non-primary button"
        );
        return;
    }
    let Some(pointer) = seat.get_pointer() else {
        warn!(
            item_id,
            "rejected clipboard drag on a seat without a pointer"
        );
        return;
    };

    // Shell-owned pointer presses deliberately do not enter Smithay's client
    // seat state. Seed a focusless click grab only when Flutter has crossed
    // the drag threshold, then replace it with the compositor DnD grab.
    pointer.button(
        state,
        &ButtonEvent {
            button: press.button,
            state: ButtonState::Pressed,
            serial: press.serial,
            time: press.time,
        },
    );
    let start_data = GrabStartData {
        focus: None,
        button: press.button,
        location: press.location,
    };

    state
        .wayland
        .as_mut()
        .expect("missing Wayland frontend")
        .clipboard_drag_active = true;
    let source = ClipboardDndSource::new(payload);
    let grab = DnDGrab::new_pointer(&display_handle, start_data, source, seat);
    pointer.set_grab(state, grab, press.serial, Focus::Keep);
    pointer.frame(state);
    state.scene_sync.mark_dirty();
    debug!(item_id, "started compositor clipboard drag");
}

fn focused_source_identity(frontend: &WaylandFrontend) -> Option<ClipboardSourceIdentity> {
    let focus = frontend.seat.get_keyboard()?.current_focus()?;
    match focus {
        KeyboardFocusTarget::X11(surface) => {
            ClipboardSourceIdentity::bounded(surface.class(), surface.title())
        }
        KeyboardFocusTarget::Wayland(surface) => with_states(&surface, |states| {
            let attributes = states.data_map.get::<XdgToplevelSurfaceData>()?;
            let attributes = attributes
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            ClipboardSourceIdentity::bounded(
                attributes.app_id.clone().unwrap_or_default(),
                attributes.title.clone().unwrap_or_default(),
            )
        }),
    }
}
