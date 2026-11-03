//! The on-screen keyboard through text-input-v3: Flutter's text field asks
//! for it, the compositor shows it after a touch, and its text comes back.
//!
//! Without the protocol, a compositor can only guess that a touched client
//! wants a keyboard; with it, the keyboard follows the focused field.

use smithay_client_toolkit::reexports::protocols::wp::text_input::zv3::client::{
    zwp_text_input_manager_v3::ZwpTextInputManagerV3,
    zwp_text_input_v3::{self, ChangeCause, ContentHint, ContentPurpose, ZwpTextInputV3},
};
use wayland_client::{
    Connection, Dispatch, Proxy, QueueHandle, globals::GlobalList, protocol::wl_seat,
};

use crate::app::App;
use crate::platform::text_input::TextInputSnapshot;
use crate::wayland_frontend::input_method::InputMethodTransaction;

#[derive(Default)]
pub struct Ime {
    manager: Option<ZwpTextInputManagerV3>,
    input: Option<ZwpTextInputV3>,
    /// The compositor sent `enter` for this surface.
    entered: bool,
    enabled: bool,
    /// Flutter's client the last state described.
    client: i64,
    /// What Flutter last asked for: a field that wants the keyboard.
    wanted: Option<TextInputSnapshot>,
    pending: InputMethodTransaction,
}

impl Ime {
    pub fn bind(globals: &GlobalList, qh: &QueueHandle<App>) -> Self {
        Self {
            manager: globals.bind(qh, 1..=2, ()).ok(),
            ..Self::default()
        }
    }

    pub fn seat(&mut self, seat: &wl_seat::WlSeat, qh: &QueueHandle<App>) {
        if self.input.is_none()
            && let Some(manager) = &self.manager
        {
            self.input = Some(manager.get_text_input(seat, qh, ()));
        }
    }

    pub fn remove_seat(&mut self) {
        if let Some(input) = self.input.take() {
            input.destroy();
        }
        self.entered = false;
        self.enabled = false;
    }

    /// Follows Flutter's text input. `engage` is a fresh request for the
    /// keyboard, a tap on a field that may already have it.
    pub fn follow(&mut self, state: Option<TextInputSnapshot>, engage: bool) {
        if let Some(state) = state {
            self.client = state.client_id;
            self.wanted = (state.active && state.input_panel_visible).then_some(state);
        }
        let Some(input) = self.input.as_ref().filter(|_| self.entered) else {
            return;
        };
        match &self.wanted {
            Some(state) => {
                if engage || !self.enabled {
                    input.enable();
                    input.set_content_type(
                        ContentHint::from_bits_truncate(state.content_hint),
                        ContentPurpose::try_from(state.content_purpose)
                            .unwrap_or(ContentPurpose::Normal),
                    );
                    if input.version() >= 2 {
                        input.show_input_panel();
                    }
                    self.enabled = true;
                }
                if let Some(text) = &state.surrounding_text {
                    input.set_surrounding_text(
                        text.clone(),
                        state.cursor as i32,
                        state.anchor as i32,
                    );
                    input.set_text_change_cause(ChangeCause::Other);
                }
                if let Some(rect) = &state.cursor_rectangle {
                    input.set_cursor_rectangle(
                        rect.x as i32,
                        rect.y as i32,
                        rect.width.max(1.0) as i32,
                        rect.height.max(1.0) as i32,
                    );
                }
                input.commit();
            }
            None if self.enabled => {
                input.disable();
                input.commit();
                self.enabled = false;
            }
            None => {}
        }
    }
}

impl Dispatch<ZwpTextInputManagerV3, ()> for App {
    fn event(
        _: &mut Self,
        _: &ZwpTextInputManagerV3,
        _: <ZwpTextInputManagerV3 as Proxy>::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<ZwpTextInputV3, ()> for App {
    fn event(
        app: &mut Self,
        _: &ZwpTextInputV3,
        event: zwp_text_input_v3::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        let ime = &mut app.ime;
        match event {
            zwp_text_input_v3::Event::Enter { .. } => {
                ime.entered = true;
                ime.enabled = false;
                ime.follow(None, false);
            }
            zwp_text_input_v3::Event::Leave { .. } => {
                ime.entered = false;
                ime.enabled = false;
            }
            zwp_text_input_v3::Event::PreeditString {
                text,
                cursor_begin,
                cursor_end,
            } => {
                ime.pending.preedit_string =
                    Some((text.unwrap_or_default(), cursor_begin, cursor_end));
            }
            zwp_text_input_v3::Event::CommitString { text } => {
                ime.pending.commit_string = text;
            }
            zwp_text_input_v3::Event::DeleteSurroundingText {
                before_length,
                after_length,
            } => {
                ime.pending.delete_surrounding = Some((before_length, after_length));
            }
            zwp_text_input_v3::Event::Done { .. } => {
                let transaction = std::mem::take(&mut ime.pending);
                let client = ime.client;
                app.input_method(client, &transaction);
            }
            _ => {}
        }
    }
}
