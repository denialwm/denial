#![deny(unsafe_op_in_unsafe_fn)]
#![deny(clippy::undocumented_unsafe_blocks)]
mod bus;
mod session;
mod ui;

use bus::AgentError;
use serde_json::json;
use session::{Conversation, Session};
use std::{
    collections::VecDeque,
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};
use zeroize::Zeroizing;

struct Request {
    action_id: String,
    message: String,
    icon_name: String,
    /// What Polkit's caller says it will run, and as whom (pkexec).
    command: Option<String>,
    run_as: Option<String>,
    cookie: String,
    uids: Vec<u32>,
    done: async_channel::Sender<Result<(), AgentError>>,
}

enum Event {
    Begin(Request),
    Cancel(String),
    Lock,
    Unavailable,
    Exit(Option<String>),
    Ui(u64, ui::Input),
    UiClosed(u64),
    Conversation(u64, u64, Conversation),
}

struct Active {
    id: u64,
    request: Request,
    ui: ui::Ui,
    session: Option<Session>,
    uid: Option<u32>,
    attempt: u64,
    failures: u8,
    prompt: Option<u64>,
    deadline: Instant,
    /// Attempts are exhausted; the dialog stays briefly to say so.
    closing: bool,
}

struct Controller {
    config: ui::Config,
    events: mpsc::Sender<Event>,
    locked: Arc<AtomicBool>,
    pending: VecDeque<Request>,
    active: Option<Active>,
    next_id: u64,
    next_prompt: u64,
    cancelled: VecDeque<String>,
}

impl Controller {
    fn finish(&mut self, result: Result<(), AgentError>) {
        if let Some(active) = self.active.take() {
            let _ = active.request.done.try_send(result);
        }
    }
    fn cancel_all(&mut self) {
        self.finish(Err(AgentError::Cancelled("Session unavailable".into())));
        for request in self.pending.drain(..) {
            let _ = request
                .done
                .try_send(Err(AgentError::Cancelled("Session unavailable".into())));
        }
    }
    fn start_next(&mut self) {
        if self.locked.load(Ordering::Acquire) {
            self.cancel_all();
            return;
        }
        if self.active.is_some() {
            return;
        }
        while let Some(request) = self.pending.pop_front() {
            self.next_id += 1;
            match ui::Ui::spawn(&self.config, self.next_id, self.events.clone()) {
                Ok(ui) => {
                    let identities: Vec<_> = request
                        .uids
                        .iter()
                        .map(|uid| json!({"uid": uid, "name": session::identity_name(*uid)}))
                        .collect();
                    ui.send(json!({"type":"request", "schema":1, "action":request.action_id, "message":request.message,
                        "icon":request.icon_name, "command":request.command, "runAs":request.run_as,
                        "identities":identities}));
                    self.active = Some(Active {
                        id: self.next_id,
                        request,
                        ui,
                        session: None,
                        uid: None,
                        attempt: 0,
                        failures: 0,
                        prompt: None,
                        deadline: Instant::now() + Duration::from_secs(300),
                        closing: false,
                    });
                    break;
                }
                Err(error) => {
                    let _ = request.done.try_send(Err(AgentError::Failed(error)));
                }
            }
        }
    }
    fn start_session(&mut self, uid: u32) {
        let Some(active) = self.active.as_mut() else {
            return;
        };
        if !active.request.uids.contains(&uid) {
            return;
        }
        active.session = None;
        active.prompt = None;
        active.attempt += 1;
        active.uid = Some(uid);
        match Session::new(
            uid,
            &active.request.cookie,
            active.id,
            active.attempt,
            self.events.clone(),
        ) {
            Ok(session) => active.session = Some(session),
            Err(error) => self.finish(Err(AgentError::Failed(error))),
        }
    }
    fn event(&mut self, event: Event) -> Option<Result<(), String>> {
        // Check the authoritative shared state before handling queued UI input.
        if self.locked.load(Ordering::Acquire) {
            self.cancel_all();
        }
        match event {
            Event::Exit(error) => {
                self.cancel_all();
                return Some(error.map_or(Ok(()), Err));
            }
            Event::Lock | Event::Unavailable => self.cancel_all(),
            Event::Begin(request) => {
                if let Some(index) = self
                    .cancelled
                    .iter()
                    .position(|cookie| *cookie == request.cookie)
                {
                    self.cancelled.remove(index);
                    let _ = request.done.try_send(Err(AgentError::Cancelled(
                        "Authentication cancelled".into(),
                    )));
                } else if self.locked.load(Ordering::Acquire) || self.pending.len() >= 8 {
                    let _ = request.done.try_send(Err(AgentError::Cancelled(
                        "Session unavailable or too many requests".into(),
                    )));
                } else if self
                    .active
                    .as_ref()
                    .is_some_and(|a| a.request.cookie == request.cookie)
                    || self.pending.iter().any(|r| r.cookie == request.cookie)
                {
                    let _ = request.done.try_send(Err(AgentError::Failed(
                        "Duplicate authentication cookie".into(),
                    )));
                } else {
                    self.pending.push_back(request);
                }
            }
            Event::Cancel(cookie) => {
                let mut found = false;
                if self
                    .active
                    .as_ref()
                    .is_some_and(|a| a.request.cookie == cookie)
                {
                    found = true;
                    self.finish(Err(AgentError::Cancelled(
                        "Authentication cancelled".into(),
                    )));
                }
                if let Some(index) = self.pending.iter().position(|r| r.cookie == cookie) {
                    found = true;
                    let request = self.pending.remove(index).unwrap();
                    let _ = request.done.try_send(Err(AgentError::Cancelled(
                        "Authentication cancelled".into(),
                    )));
                }
                // D-Bus method tasks can run out of order. A cancellation that
                // arrives first must prevent a later Begin from opening a dialog.
                if !found && !self.cancelled.contains(&cookie) {
                    if self.cancelled.len() == 32 {
                        self.cancelled.pop_front();
                    }
                    self.cancelled.push_back(cookie);
                }
            }
            Event::UiClosed(id) => {
                if self.active.as_ref().is_some_and(|a| a.id == id) {
                    self.finish(Err(AgentError::Cancelled(
                        "Authentication window closed".into(),
                    )));
                }
            }
            Event::Ui(id, mut input) => {
                if !self.active.as_ref().is_some_and(|a| a.id == id) {
                    return None;
                }
                match &mut input {
                    ui::Input::Cancel => self.finish(Err(AgentError::Cancelled(
                        "Authentication cancelled".into(),
                    ))),
                    ui::Input::Select { uid } => {
                        // Identity selection happens before starting a conversation.
                        let active = self.active.as_ref().unwrap();
                        if active.session.is_none() && !active.closing {
                            self.start_session(*uid);
                        }
                    }
                    ui::Input::Response { prompt, text } => {
                        let active = self.active.as_mut().unwrap();
                        if active.prompt == Some(*prompt)
                            && let Some(session) = &active.session
                        {
                            let response = Zeroizing::new(std::mem::take(text));
                            if let Err(error) = session.respond(response) {
                                active.ui.send(json!({"type":"error", "text":error}));
                            } else {
                                active.prompt = None;
                            }
                        }
                    }
                    ui::Input::Hello { .. } => {}
                }
            }
            Event::Conversation(id, attempt, conversation) => {
                let active = self
                    .active
                    .as_mut()
                    .filter(|a| a.id == id && a.attempt == attempt)?;
                match conversation {
                    Conversation::Prompt { text, echo } => {
                        self.next_prompt += 1;
                        active.prompt = Some(self.next_prompt);
                        active.ui.send(json!({"type":"prompt", "prompt":self.next_prompt, "text":text, "echo":echo}));
                    }
                    Conversation::Info(text) => active.ui.send(json!({"type":"info", "text":text})),
                    Conversation::Error(text) => {
                        active.ui.send(json!({"type":"error", "text":text}))
                    }
                    Conversation::Completed(gained) => {
                        if let Some(session) = &mut active.session {
                            session.completed();
                        }
                        active.session = None;
                        active.prompt = None;
                        active.failures += u8::from(!gained);
                        if gained {
                            // Only Polkit's privileged helper reports authorization.
                            // A normal method return does not itself grant anything.
                            self.finish(Ok(()));
                        } else if active.failures >= 3 {
                            // Say so before leaving; vanishing looks like success.
                            active
                                .ui
                                .send(json!({"type":"failed", "text":"Too many failed attempts."}));
                            active.closing = true;
                            active.deadline = Instant::now() + Duration::from_secs(4);
                        } else {
                            let uid = active.uid.unwrap();
                            active.ui.send(json!({"type":"error", "text":"Authentication failed. Please try again."}));
                            self.start_session(uid);
                        }
                    }
                }
            }
        }
        self.start_next();
        None
    }
    fn tick(&mut self) {
        if self.locked.load(Ordering::Acquire) {
            self.cancel_all();
        }
        if self
            .active
            .as_ref()
            .is_some_and(|a| a.closing && Instant::now() >= a.deadline)
        {
            self.finish(Ok(()));
        } else if self
            .active
            .as_mut()
            .is_some_and(|a| a.ui.exited() || Instant::now() >= a.deadline)
        {
            self.finish(Err(AgentError::Cancelled(
                "Authentication dialog ended or timed out".into(),
            )));
        }
        self.start_next();
    }
}

fn config() -> Result<Option<ui::Config>, String> {
    let mut config = ui::Config {
        runner: "/usr/lib/denial/polkit/denial-app".into(),
        bundle: "/usr/lib/denial/polkit".into(),
        engine: "/usr/lib/denial/polkit/lib/libflutter_engine.so".into(),
    };
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        if matches!(arg.as_str(), "--help" | "-h") {
            println!(
                "denial-polkit-agent [--runner FILE] [--bundle DIR] [--engine FILE]\nRegisters for the current logind session; opens a native Flutter dialog only on demand."
            );
            return Ok(None);
        }
        let value = args
            .next()
            .ok_or_else(|| format!("Missing value for {arg}"))?;
        match arg.as_str() {
            "--runner" => config.runner = PathBuf::from(value),
            "--bundle" => config.bundle = PathBuf::from(value),
            "--engine" => config.engine = PathBuf::from(value),
            _ => return Err(format!("Unknown option {arg}")),
        }
    }
    Ok(Some(config))
}

fn run() -> Result<(), String> {
    let Some(config) = config()? else {
        return Ok(());
    };
    if std::env::var("DENIAL_POLKIT_AGENT").as_deref() == Ok("0") {
        eprintln!(
            "denial-polkit-agent: disabled (deniald --no-polkit-agent or DENIAL_POLKIT_AGENT=0)"
        );
        return Ok(());
    }
    let (events, receiver) = mpsc::channel();
    let locked = Arc::new(AtomicBool::new(true));
    let bus_events = events.clone();
    let bus_locked = locked.clone();
    std::thread::spawn(move || {
        for attempt in 0..5 {
            match bus::run(bus_events.clone(), bus_locked.clone()) {
                Ok(()) => return,
                Err(error) => {
                    bus_locked.store(true, Ordering::Release);
                    let _ = bus_events.send(Event::Unavailable);
                    if attempt == 4 {
                        let _ = bus_events.send(Event::Exit(Some(error.to_string())));
                        return;
                    }
                    eprintln!("denial-polkit-agent: authority unavailable; retrying registration");
                    std::thread::sleep(Duration::from_secs(1));
                }
            }
        }
    });
    let mut controller = Controller {
        config,
        events,
        locked,
        pending: VecDeque::new(),
        active: None,
        next_id: 0,
        next_prompt: 0,
        cancelled: VecDeque::new(),
    };
    loop {
        session::dispatch();
        // GLib sessions, the dialog and deadlines need polling only while a
        // request is in progress. Idle, sleep until the next event.
        let event = if controller.active.is_some() || !controller.pending.is_empty() {
            receiver.recv_timeout(Duration::from_millis(20))
        } else {
            receiver
                .recv()
                .map_err(|_| mpsc::RecvTimeoutError::Disconnected)
        };
        match event {
            Ok(event) => {
                if let Some(result) = controller.event(event) {
                    return result;
                }
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                return Err("Agent event loop disconnected".into());
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
        }
        controller.tick();
    }
}

fn main() {
    if let Err(error) = run() {
        eprintln!("denial-polkit-agent: {error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn controller(locked: bool) -> Controller {
        let (events, _) = mpsc::channel();
        Controller {
            config: ui::Config {
                runner: "/unused".into(),
                bundle: "/unused".into(),
                engine: "/unused".into(),
            },
            events,
            locked: Arc::new(AtomicBool::new(locked)),
            pending: VecDeque::new(),
            active: None,
            next_id: 0,
            next_prompt: 0,
            cancelled: VecDeque::new(),
        }
    }
    fn request(cookie: &str) -> (Request, async_channel::Receiver<Result<(), AgentError>>) {
        let (done, result) = async_channel::bounded(1);
        (
            Request {
                action_id: "test".into(),
                message: "test".into(),
                icon_name: String::new(),
                command: None,
                run_as: None,
                cookie: cookie.into(),
                uids: vec![1000],
                done,
            },
            result,
        )
    }
    #[test]
    fn cancellation_before_begin_never_starts_ui() {
        let mut controller = controller(false);
        controller.event(Event::Cancel("cookie".into()));
        let (request, result) = request("cookie");
        controller.event(Event::Begin(request));
        assert!(matches!(
            result.try_recv().unwrap(),
            Err(AgentError::Cancelled(_))
        ));
        assert_eq!(controller.next_id, 0);
    }
    #[test]
    fn lock_cancels_all_queued_requests_and_rejects_new_ones() {
        let mut controller = controller(false);
        let (queued, queued_result) = request("queued");
        controller.pending.push_back(queued);
        controller.locked.store(true, Ordering::Release);
        controller.event(Event::Lock);
        assert!(matches!(
            queued_result.try_recv().unwrap(),
            Err(AgentError::Cancelled(_))
        ));
        let (new, new_result) = request("new");
        controller.event(Event::Begin(new));
        assert!(matches!(
            new_result.try_recv().unwrap(),
            Err(AgentError::Cancelled(_))
        ));
        assert_eq!(controller.next_id, 0);
    }
}
