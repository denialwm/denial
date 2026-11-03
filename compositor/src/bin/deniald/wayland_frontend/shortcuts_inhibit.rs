//! `zwp_keyboard_shortcuts_inhibit_manager_v1`: the focused app receives the
//! keys Denial uses for its own shortcuts, once the user allows it.
//!
//! Remote desktops and virtual machines ask for this so that Super and its
//! chords reach the other system. The first time an app asks, Denial shows
//! the Access dialog of its portal backend (`org.freedesktop.impl.portal.Access`
//! in denial-portal). The portal permission store keeps each app's answer in
//! table `denial`, entry `shortcuts-inhibit`, by app ID: `yes` for "Always
//! allow", `no` for "Never allow", `ask` once it was asked. "Allow once" and
//! "Decline once" last while the app stays connected. A change in the store,
//! as Settings makes, applies at once: an app whose answer it changes is
//! asked again.
//!
//! Some keys never go to an app: VT switching, the emergency exit, volume
//! and brightness, and the pointer release shortcut. That one also takes the
//! shortcuts back until the app is focused again.

use std::collections::{HashMap, HashSet};
use std::time::Duration;

use smithay::reexports::calloop::LoopHandle;
use smithay::reexports::calloop::channel::{Event as ChannelEvent, Sender, channel};
use smithay::reexports::wayland_server::backend::ClientId;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::reexports::wayland_server::{DisplayHandle, Resource};
use smithay::wayland::keyboard_shortcuts_inhibit::{
    KeyboardShortcutsInhibitHandler, KeyboardShortcutsInhibitState, KeyboardShortcutsInhibitor,
};
use tracing::{debug, info, warn};
use zbus::zvariant::{ObjectPath, OwnedValue, Value};

use super::managed_window::ManagedWindow;
use super::{RuntimeState, WaylandFrontend};
use crate::native_shortcut::{ShortcutAction, ShortcutTarget};

const ACCESS_SERVICE: &str = "org.freedesktop.impl.portal.desktop.denial";
const ACCESS_PATH: &str = "/org/freedesktop/portal/desktop";
const ACCESS_INTERFACE: &str = "org.freedesktop.impl.portal.Access";
const REQUEST_INTERFACE: &str = "org.freedesktop.impl.portal.Request";
const PERMISSION_STORE_SERVICE: &str = "org.freedesktop.impl.portal.PermissionStore";
const PERMISSION_STORE_PATH: &str = "/org/freedesktop/impl/portal/PermissionStore";
const PERMISSION_STORE_INTERFACE: &str = "org.freedesktop.impl.portal.PermissionStore";
const PERMISSION_TABLE: &str = "denial";
const PERMISSION_ID: &str = "shortcuts-inhibit";
/// The Access choice that makes an answer "always" or "never". Other Access
/// backends show it as a checkbox.
const REMEMBER_CHOICE: &str = "remember";
/// Stored answers. Any other value asks, like `ask`.
const ALLOWED: &str = "yes";
const DENIED: &str = "no";
const ASKED: &str = "ask";
/// The store answers at once. The bound only keeps a wedged bus from holding
/// a request; the dialog itself waits for the user without one.
const PERMISSION_STORE_TIMEOUT: Duration = Duration::from_secs(2);

pub(super) struct ShortcutsInhibit {
    state: KeyboardShortcutsInhibitState,
    inhibitors: Vec<KeyboardShortcutsInhibitor>,
    /// The surface with keyboard focus, as of the last focus change.
    focus: Option<WlSurface>,
    /// The focused surface the user took the shortcuts back from.
    suspended: Option<WlSurface>,
    /// The user's answer for each connected app.
    answers: HashMap<ClientId, ClientAnswer>,
    request: Option<PendingRequest>,
    next_request: u64,
    events: Sender<Event>,
    /// Whether a worker follows changes to the stored answers.
    watching: bool,
    /// Keys pressed while an app held the shortcuts. Each release goes where
    /// its press went, so neither the app nor Denial keeps a key held.
    forwarded_keys: HashSet<u32>,
}

struct PendingRequest {
    id: u64,
    client: ClientId,
    app_id: String,
    handle: String,
}

struct ClientAnswer {
    app_id: String,
    allowed: bool,
    /// The stored answer this one followed, if the store could be read.
    stored: Option<String>,
}

impl ClientAnswer {
    /// Whether the store still holds the answer this one followed.
    fn follows(&self, stored: &HashMap<String, Vec<String>>) -> bool {
        stored.get(&self.app_id).and_then(|values| values.first()) == self.stored.as_ref()
    }
}

enum Event {
    Answered {
        id: u64,
        allowed: bool,
        stored: Option<String>,
    },
    /// Every app's stored answer, after a change.
    Stored(HashMap<String, Vec<String>>),
}

/// The answer to a prompt, and the stored answer it leaves.
struct Decision {
    allowed: bool,
    stored: Option<String>,
}

/// What the dialog says. Built on the compositor thread, asked on a worker.
struct Prompt {
    handle: String,
    app_id: String,
    title: String,
    release_shortcut: Option<String>,
}

impl ShortcutsInhibit {
    pub(super) fn new(
        display: &DisplayHandle,
        loop_handle: &LoopHandle<'static, RuntimeState>,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        let (events, received) = channel();
        loop_handle.insert_source(received, |event, _, state: &mut RuntimeState| {
            let ChannelEvent::Msg(event) = event else {
                return;
            };
            let Some(frontend) = state.wayland.as_mut() else {
                return;
            };
            match event {
                Event::Answered {
                    id,
                    allowed,
                    stored,
                } => frontend.note_shortcuts_inhibit_answer(id, allowed, stored),
                Event::Stored(stored) => frontend.note_stored_shortcuts_inhibit_answers(&stored),
            }
        })?;
        Ok(Self {
            state: KeyboardShortcutsInhibitState::new::<RuntimeState>(display),
            inhibitors: Vec::new(),
            focus: None,
            suspended: None,
            answers: HashMap::new(),
            request: None,
            next_request: 0,
            events,
            watching: false,
            forwarded_keys: HashSet::new(),
        })
    }

    /// Whether the focused app currently receives Denial's shortcuts.
    pub(super) fn active(&self) -> bool {
        self.inhibitors
            .iter()
            .any(KeyboardShortcutsInhibitor::is_active)
    }

    /// Records whether a key press went to the app that holds the shortcuts.
    pub(super) fn note_press(&mut self, xkb_keycode: u32, forwarded: bool) {
        if forwarded {
            self.forwarded_keys.insert(xkb_keycode);
        } else {
            self.forwarded_keys.remove(&xkb_keycode);
        }
    }

    /// Whether a released key was pressed while an app held the shortcuts.
    pub(super) fn take_forwarded_release(&mut self, xkb_keycode: u32) -> bool {
        self.forwarded_keys.remove(&xkb_keycode)
    }
}

impl WaylandFrontend {
    pub(super) fn shortcuts_inhibit_focus_changed(&mut self, focus: Option<WlSurface>) {
        self.shortcuts_inhibit.focus = focus;
        self.refresh_shortcuts_inhibit();
    }

    /// Gives the shortcuts back to Denial until the app is focused again.
    pub(super) fn suspend_shortcuts_inhibit(&mut self) {
        let inhibit = &mut self.shortcuts_inhibit;
        let Some(active) = inhibit
            .inhibitors
            .iter()
            .find(|inhibitor| inhibitor.is_active())
        else {
            return;
        };
        inhibit.suspended = Some(active.wl_surface().clone());
        active.inactivate();
        info!("keyboard shortcuts returned to Denial");
    }

    /// Activates the focused surface's inhibitor when its app is allowed,
    /// deactivates every other one, and asks the user about an app that has
    /// no answer yet.
    fn refresh_shortcuts_inhibit(&mut self) {
        let backend = self.display_handle.backend_handle();
        let inhibit = &mut self.shortcuts_inhibit;
        inhibit
            .answers
            .retain(|client, _| backend.get_client_data(client.clone()).is_ok());
        if inhibit.suspended != inhibit.focus {
            inhibit.suspended = None;
        }
        let mut unanswered = None;
        for inhibitor in &inhibit.inhibitors {
            let surface = inhibitor.wl_surface();
            let focused = inhibit.focus.as_ref() == Some(surface)
                && inhibit.suspended.is_none()
                && surface.is_alive();
            let answer = surface
                .client()
                .and_then(|client| inhibit.answers.get(&client.id()))
                .map(|answer| answer.allowed);
            let active = focused && answer == Some(true);
            if active != inhibitor.is_active() {
                if active {
                    inhibitor.activate();
                } else {
                    inhibitor.inactivate();
                }
            }
            if focused && answer.is_none() {
                unanswered = Some(surface.clone());
            }
        }
        if let Some(surface) = unanswered
            && inhibit.request.is_none()
        {
            self.ask_shortcuts_inhibit(&surface);
        }
    }

    fn ask_shortcuts_inhibit(&mut self, surface: &WlSurface) {
        let Some(client) = surface.client() else {
            return;
        };
        let (title, app_id) = self
            .owning_toplevel_surface(surface)
            .and_then(|root| self.window_for_root_surface(&root))
            .and_then(|window| ManagedWindow::new(&window).map(|window| window.metadata()))
            .unwrap_or_default();
        let release_shortcut = self
            .shortcuts
            .file()
            .shortcuts
            .iter()
            .find(|binding| {
                binding.target
                    == ShortcutTarget::DenialAction {
                        action: ShortcutAction::ReleasePointer,
                    }
            })
            .map(|binding| binding.shortcut.clone());
        let inhibit = &mut self.shortcuts_inhibit;
        inhibit.next_request += 1;
        let id = inhibit.next_request;
        let handle = format!("/org/freedesktop/portal/desktop/request/deniald/shortcuts{id}");
        inhibit.request = Some(PendingRequest {
            id,
            client: client.id(),
            app_id: app_id.clone(),
            handle: handle.clone(),
        });
        if !inhibit.watching {
            inhibit.watching = watch_stored_answers(inhibit.events.clone());
        }
        let prompt = Prompt {
            handle,
            app_id,
            title,
            release_shortcut,
        };
        let events = inhibit.events.clone();
        let worker = std::thread::Builder::new()
            .name("denial-shortcuts".to_owned())
            .spawn(move || {
                crate::cpu_scheduling::normalize_current_worker("shortcuts");
                let decision = decide(&prompt).unwrap_or_else(|error| {
                    warn!(%error, app_id = %prompt.app_id, "could not ask whether an app may use all keyboard shortcuts");
                    Decision {
                        allowed: false,
                        stored: None,
                    }
                });
                // The compositor may already be shutting down.
                let _ = events.send(Event::Answered {
                    id,
                    allowed: decision.allowed,
                    stored: decision.stored,
                });
            });
        if let Err(error) = worker {
            warn!(%error, "could not start the keyboard shortcuts prompt");
            self.shortcuts_inhibit.request = None;
        }
    }

    fn note_shortcuts_inhibit_answer(&mut self, id: u64, allowed: bool, stored: Option<String>) {
        let inhibit = &mut self.shortcuts_inhibit;
        let Some(request) = inhibit.request.take_if(|request| request.id == id) else {
            return;
        };
        debug!(allowed, "keyboard shortcuts answer");
        inhibit.answers.insert(
            request.client,
            ClientAnswer {
                app_id: request.app_id,
                allowed,
                stored,
            },
        );
        self.refresh_shortcuts_inhibit();
    }

    /// Forgets the answers whose stored answer changed, so those apps are
    /// asked again. Settings changes them; Denial's own writes keep them.
    fn note_stored_shortcuts_inhibit_answers(&mut self, stored: &HashMap<String, Vec<String>>) {
        let inhibit = &mut self.shortcuts_inhibit;
        let before = inhibit.answers.len();
        inhibit.answers.retain(|_, answer| answer.follows(stored));
        if inhibit.answers.len() != before {
            info!("stored keyboard shortcuts answers changed");
            self.refresh_shortcuts_inhibit();
        }
    }

    /// Closes the dialog of an app that has disconnected. An app that only
    /// drops its inhibitor keeps its question: some drop it whenever they
    /// lose focus, as they do to the dialog itself.
    fn withdraw_shortcuts_inhibit_request(&mut self) {
        let inhibit = &mut self.shortcuts_inhibit;
        let Some(request) = inhibit.request.as_ref() else {
            return;
        };
        if self
            .display_handle
            .backend_handle()
            .get_client_data(request.client.clone())
            .is_ok()
        {
            return;
        }
        let handle = request.handle.clone();
        inhibit.request = None;
        let closer = std::thread::Builder::new()
            .name("denial-shortcuts".to_owned())
            .spawn(move || {
                let result = zbus::blocking::Connection::session().and_then(|bus| {
                    bus.call_method(
                        Some(ACCESS_SERVICE),
                        handle.as_str(),
                        Some(REQUEST_INTERFACE),
                        "Close",
                        &(),
                    )
                    .map(drop)
                });
                if let Err(error) = result {
                    debug!(%error, "could not close the keyboard shortcuts prompt");
                }
            });
        if let Err(error) = closer {
            warn!(%error, "could not close the keyboard shortcuts prompt");
        }
    }
}

impl KeyboardShortcutsInhibitHandler for RuntimeState {
    fn keyboard_shortcuts_inhibit_state(&mut self) -> &mut KeyboardShortcutsInhibitState {
        &mut self.frontend_mut().shortcuts_inhibit.state
    }

    fn new_inhibitor(&mut self, inhibitor: KeyboardShortcutsInhibitor) {
        let frontend = self.frontend_mut();
        frontend.shortcuts_inhibit.inhibitors.push(inhibitor);
        frontend.refresh_shortcuts_inhibit();
    }

    fn inhibitor_destroyed(&mut self, inhibitor: KeyboardShortcutsInhibitor) {
        let frontend = self.frontend_mut();
        frontend
            .shortcuts_inhibit
            .inhibitors
            .retain(|existing| existing != &inhibitor);
        frontend.refresh_shortcuts_inhibit();
        // A disconnecting client destroys its inhibitors before it is gone.
        frontend.loop_handle.insert_idle(|state| {
            if let Some(frontend) = state.wayland.as_mut() {
                frontend.withdraw_shortcuts_inhibit_request();
            }
        });
    }
}

/// A stored answer, else the user's answer from the Access dialog.
fn decide(prompt: &Prompt) -> zbus::Result<Decision> {
    // `Ok(None)`: the app has no stored answer yet.
    let mut stored = Err(());
    if !prompt.app_id.is_empty() {
        match stored_answer(&prompt.app_id) {
            Ok(Some(value)) if value == ALLOWED || value == DENIED => {
                return Ok(Decision {
                    allowed: value == ALLOWED,
                    stored: Some(value),
                });
            }
            Ok(value) => stored = Ok(value),
            Err(error) => debug!(%error, "could not read stored keyboard shortcuts answers"),
        }
    }
    let name = if !prompt.title.is_empty() {
        prompt.title.as_str()
    } else if !prompt.app_id.is_empty() {
        prompt.app_id.as_str()
    } else {
        "this app"
    };
    let title = format!("Let {name} use all keyboard shortcuts?");
    let subtitle = "While it has focus, it receives the keys Denial uses for its own \
                    shortcuts, such as Super.";
    let body = prompt
        .release_shortcut
        .as_ref()
        .map(|shortcut| format!("Press {shortcut} to use Denial's shortcuts again."))
        .unwrap_or_default();
    // Denial's dialog shows it as "Always allow" and "Never allow" buttons.
    let choices: Vec<(&str, &str, Vec<(&str, &str)>, &str)> =
        vec![(REMEMBER_CHOICE, "Remember this answer", Vec::new(), "false")];
    let mut options: HashMap<&str, Value<'_>> = HashMap::new();
    options.insert("modal", Value::from(true));
    options.insert("choices", Value::from(choices));
    let reply = zbus::blocking::Connection::session()?.call_method(
        Some(ACCESS_SERVICE),
        ACCESS_PATH,
        Some(ACCESS_INTERFACE),
        "AccessDialog",
        &(
            ObjectPath::try_from(prompt.handle.as_str())?,
            prompt.app_id.as_str(),
            "",
            title.as_str(),
            subtitle,
            body.as_str(),
            options,
        ),
    )?;
    let (response, results): (u32, HashMap<String, OwnedValue>) = reply.body().deserialize()?;
    let allowed = response == 0;
    let remember = results
        .get("choices")
        .and_then(|choices| Vec::<(String, String)>::try_from(choices.clone()).ok())
        .is_some_and(|choices| {
            choices
                .iter()
                .any(|(id, value)| id == REMEMBER_CHOICE && value == "true")
        });
    info!(app_id = %prompt.app_id, allowed, remember, "keyboard shortcuts prompt answered");
    // An asked app is listed in Settings, whatever the answer was.
    let store = if remember {
        Some(if allowed { ALLOWED } else { DENIED })
    } else if stored == Ok(None) {
        Some(ASKED)
    } else {
        None
    };
    let stored = match store {
        Some(value) if !prompt.app_id.is_empty() => match store_answer(&prompt.app_id, value) {
            Ok(()) => Some(value.to_owned()),
            Err(error) => {
                warn!(%error, app_id = %prompt.app_id, "could not store an app's keyboard shortcuts answer");
                None
            }
        },
        _ => stored.ok().flatten(),
    };
    Ok(Decision { allowed, stored })
}

fn permission_store() -> zbus::Result<zbus::blocking::Connection> {
    zbus::blocking::connection::Builder::session()?
        .method_timeout(PERMISSION_STORE_TIMEOUT)
        .build()
}

/// The app's stored answer: `yes`, `no`, `ask`, or another value to ask on.
fn stored_answer(app_id: &str) -> zbus::Result<Option<String>> {
    let reply = permission_store()?.call_method(
        Some(PERMISSION_STORE_SERVICE),
        PERMISSION_STORE_PATH,
        Some(PERMISSION_STORE_INTERFACE),
        "Lookup",
        &(PERMISSION_TABLE, PERMISSION_ID),
    );
    let reply = match reply {
        Ok(reply) => reply,
        // The entry exists once something was stored in it.
        Err(zbus::Error::MethodError(name, _, _))
            if name.as_str() == "org.freedesktop.portal.Error.NotFound" =>
        {
            return Ok(None);
        }
        Err(error) => return Err(error),
    };
    let (permissions, _data): (HashMap<String, Vec<String>>, OwnedValue) =
        reply.body().deserialize()?;
    Ok(permissions
        .get(app_id)
        .and_then(|values| values.first().cloned()))
}

fn store_answer(app_id: &str, value: &str) -> zbus::Result<()> {
    permission_store()?.call_method(
        Some(PERMISSION_STORE_SERVICE),
        PERMISSION_STORE_PATH,
        Some(PERMISSION_STORE_INTERFACE),
        "SetPermission",
        &(PERMISSION_TABLE, true, PERMISSION_ID, app_id, vec![value]),
    )?;
    Ok(())
}

/// Follows changes to the stored answers on a worker for the rest of the
/// session. False when the worker could not start.
fn watch_stored_answers(events: Sender<Event>) -> bool {
    let worker = std::thread::Builder::new()
        .name("denial-shortcuts-store".to_owned())
        .spawn(move || {
            crate::cpu_scheduling::normalize_current_worker("shortcuts");
            if let Err(error) = follow_stored_answers(&events) {
                warn!(%error, "could not follow stored keyboard shortcuts answers");
            }
        });
    if let Err(error) = &worker {
        warn!(%error, "could not follow stored keyboard shortcuts answers");
    }
    worker.is_ok()
}

fn follow_stored_answers(events: &Sender<Event>) -> zbus::Result<()> {
    let bus = zbus::blocking::Connection::session()?;
    // No sender: the store starts on demand. A forged signal only makes
    // Denial read the store again.
    let rule = zbus::MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .interface(PERMISSION_STORE_INTERFACE)?
        .member("Changed")?
        .path(PERMISSION_STORE_PATH)?
        .arg(0, PERMISSION_TABLE)?
        .arg(1, PERMISSION_ID)?
        .build();
    for message in zbus::blocking::MessageIterator::for_match_rule(rule, &bus, None)? {
        let message = message?;
        let Ok((table, id, _deleted, _data, permissions)) = message.body().deserialize::<(
            String,
            String,
            bool,
            OwnedValue,
            HashMap<String, Vec<String>>,
        )>() else {
            continue;
        };
        if table != PERMISSION_TABLE || id != PERMISSION_ID {
            continue;
        }
        if events.send(Event::Stored(permissions)).is_err() {
            return Ok(());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn answer(stored: Option<&str>) -> ClientAnswer {
        ClientAnswer {
            app_id: "chromium".to_owned(),
            allowed: true,
            stored: stored.map(str::to_owned),
        }
    }

    fn store(entries: &[(&str, &str)]) -> HashMap<String, Vec<String>> {
        entries
            .iter()
            .map(|(app_id, value)| ((*app_id).to_owned(), vec![(*value).to_owned()]))
            .collect()
    }

    #[test]
    fn an_answer_lasts_until_settings_changes_the_stored_one() {
        // Denial's own write after "Allow once" keeps the answer.
        assert!(answer(Some(ASKED)).follows(&store(&[("chromium", ASKED)])));
        // Another app's change keeps it too.
        assert!(answer(Some(ALLOWED)).follows(&store(&[("chromium", ALLOWED), ("foot", DENIED)])));
        assert!(!answer(Some(ASKED)).follows(&store(&[("chromium", ALLOWED)])));
        assert!(!answer(Some(ALLOWED)).follows(&store(&[("chromium", ASKED)])));
        assert!(!answer(Some(ALLOWED)).follows(&store(&[])));
        // Without a readable store there was nothing to follow.
        assert!(answer(None).follows(&store(&[])));
    }
}
