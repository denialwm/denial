//! Libinput source adapter with an explicit end-of-batch edge.
//!
//! Smithay drains every queued libinput event in one `EventSource` callback,
//! but calloop normally exposes only the individual events to the compositor.
//! The final edge lets Denial flush Wayland clients once after the whole batch
//! without adding a timer, wakeup fd, or allocation to the input path.

use std::io;
#[cfg(feature = "flutter")]
use std::{
    cell::RefCell,
    collections::HashSet,
    os::fd::{AsFd, BorrowedFd, OwnedFd},
    path::{Path, PathBuf},
    rc::Rc,
    time::Duration,
};

use smithay::backend::input::InputEvent;
use smithay::backend::libinput::LibinputInputBackend;
#[cfg(feature = "flutter")]
use smithay::backend::session::Session;
#[cfg(feature = "flutter")]
use smithay::backend::session::libseat::LibSeatSession;
use smithay::reexports::calloop::{
    self, EventSource, Poll, PostAction, Readiness, Token, TokenFactory,
};
#[cfg(feature = "flutter")]
use smithay::reexports::calloop::{
    EventLoop, Interest, LoopHandle, Mode,
    generic::Generic,
    timer::{TimeoutAction, Timer},
};
#[cfg(feature = "flutter")]
use smithay::reexports::rustix::{fs::OFlags, io as rustix_io};
#[cfg(feature = "flutter")]
use tracing::{debug, warn};

#[cfg(feature = "flutter")]
use super::super::RuntimeState;

pub(super) enum InputBatchEvent {
    Input(InputEvent<LibinputInputBackend>),
    Complete,
}

#[derive(Default)]
pub(super) struct InputBatchMetadata {
    pub(super) flush_clients: bool,
}

pub(super) struct LibinputBatchSource {
    inner: LibinputInputBackend,
}

impl LibinputBatchSource {
    pub(super) fn new(inner: LibinputInputBackend) -> Self {
        Self { inner }
    }
}

impl EventSource for LibinputBatchSource {
    type Event = InputBatchEvent;
    type Metadata = InputBatchMetadata;
    type Ret = ();
    type Error = io::Error;

    fn process_events<F>(
        &mut self,
        readiness: Readiness,
        token: Token,
        mut callback: F,
    ) -> Result<PostAction, Self::Error>
    where
        F: FnMut(Self::Event, &mut Self::Metadata) -> Self::Ret,
    {
        let mut dispatched = false;
        let mut metadata = InputBatchMetadata::default();
        let action = self.inner.process_events(readiness, token, |event, _| {
            dispatched = true;
            callback(InputBatchEvent::Input(event), &mut metadata);
        })?;
        if dispatched {
            callback(InputBatchEvent::Complete, &mut metadata);
        }
        Ok(action)
    }

    fn register(
        &mut self,
        poll: &mut Poll,
        token_factory: &mut TokenFactory,
    ) -> calloop::Result<()> {
        self.inner.register(poll, token_factory)
    }

    fn reregister(
        &mut self,
        poll: &mut Poll,
        token_factory: &mut TokenFactory,
    ) -> calloop::Result<()> {
        self.inner.reregister(poll, token_factory)
    }

    fn unregister(&mut self, poll: &mut Poll) -> calloop::Result<()> {
        self.inner.unregister(poll)
    }
}

#[cfg(feature = "flutter")]
const JOYSTICK_RESCAN_INTERVAL: Duration = Duration::from_secs(2);
#[cfg(feature = "flutter")]
const JOYSTICK_EVENT_BYTES: usize = 8;
#[cfg(feature = "flutter")]
const JOYSTICK_AXIS_ACTIVITY_THRESHOLD: i32 = 512;
#[cfg(feature = "flutter")]
const JS_EVENT_BUTTON: u8 = 0x01;
#[cfg(feature = "flutter")]
const JS_EVENT_AXIS: u8 = 0x02;
#[cfg(feature = "flutter")]
const JS_EVENT_INIT: u8 = 0x80;

/// libinput deliberately excludes gamepads. Keep a read-only watch on Linux's
/// joystick character devices so gamepad buttons and meaningful axis motion
/// participate in the same compositor-owned idle clock.
#[cfg(feature = "flutter")]
pub(super) fn init_joystick_activity(
    event_loop: &mut EventLoop<'static, RuntimeState>,
    session: LibSeatSession,
) -> Result<(), Box<dyn std::error::Error>> {
    let watched = Rc::new(RefCell::new(HashSet::new()));
    let handle = event_loop.handle();
    scan_joysticks(&handle, &session, &watched);

    event_loop.handle().insert_source(
        Timer::from_duration(JOYSTICK_RESCAN_INTERVAL),
        move |_, _, _| {
            scan_joysticks(&handle, &session, &watched);
            TimeoutAction::ToDuration(JOYSTICK_RESCAN_INTERVAL)
        },
    )?;
    Ok(())
}

#[cfg(feature = "flutter")]
fn scan_joysticks(
    handle: &LoopHandle<'static, RuntimeState>,
    session: &LibSeatSession,
    watched: &Rc<RefCell<HashSet<PathBuf>>>,
) {
    let Ok(entries) = std::fs::read_dir("/dev/input") else {
        return;
    };
    for path in entries.flatten().filter_map(|entry| {
        let name = entry.file_name();
        let name = name.to_str()?;
        name.strip_prefix("js")
            .is_some_and(|suffix| {
                !suffix.is_empty() && suffix.bytes().all(|byte| byte.is_ascii_digit())
            })
            .then(|| entry.path())
    }) {
        if watched.borrow().contains(&path) {
            continue;
        }
        if let Err(error) = watch_joystick(handle, session.clone(), watched.clone(), path.clone()) {
            debug!(%error, device = %path.display(), "could not watch joystick for idle activity");
        }
    }
}

#[cfg(feature = "flutter")]
fn watch_joystick(
    handle: &LoopHandle<'static, RuntimeState>,
    mut session: LibSeatSession,
    watched: Rc<RefCell<HashSet<PathBuf>>>,
    path: PathBuf,
) -> Result<(), Box<dyn std::error::Error>> {
    let fd = session.open(
        Path::new(&path),
        OFlags::RDONLY | OFlags::CLOEXEC | OFlags::NONBLOCK,
    )?;
    watched.borrow_mut().insert(path.clone());
    let device = SeatJoystickFd {
        fd: Some(fd),
        session,
        path,
        watched,
        axes: RefCell::new(JoystickAxes::default()),
    };
    handle.insert_source(
        Generic::new(device, Interest::READ, Mode::Level),
        |_, device, state| {
            let mut buffer = [0u8; JOYSTICK_EVENT_BYTES * 64];
            let mut activity = false;
            loop {
                match rustix_io::read(device.as_fd(), &mut buffer) {
                    Ok(0) => return Ok(PostAction::Remove),
                    Ok(read) => {
                        activity |= joystick_events_have_activity(
                            &buffer[..read],
                            &mut device.as_ref().axes.borrow_mut(),
                        );
                    }
                    Err(rustix_io::Errno::AGAIN) => break,
                    Err(error) => {
                        warn!(%error, "joystick idle-activity source stopped");
                        return Ok(PostAction::Remove);
                    }
                }
            }
            if activity {
                state.note_user_activity();
            }
            Ok(PostAction::Continue)
        },
    )?;
    Ok(())
}

#[cfg(feature = "flutter")]
struct SeatJoystickFd {
    fd: Option<OwnedFd>,
    session: LibSeatSession,
    path: PathBuf,
    watched: Rc<RefCell<HashSet<PathBuf>>>,
    axes: RefCell<JoystickAxes>,
}

#[cfg(feature = "flutter")]
impl AsFd for SeatJoystickFd {
    fn as_fd(&self) -> BorrowedFd<'_> {
        self.fd
            .as_ref()
            .expect("joystick fd is unavailable before drop")
            .as_fd()
    }
}

#[cfg(feature = "flutter")]
impl Drop for SeatJoystickFd {
    fn drop(&mut self) {
        self.watched.borrow_mut().remove(&self.path);
        if let Some(fd) = self.fd.take()
            && let Err(error) = self.session.close(fd)
        {
            debug!(%error, device = %self.path.display(), "could not close joystick seat device");
        }
    }
}

#[cfg(feature = "flutter")]
struct JoystickAxes {
    values: [i16; 256],
    known: [bool; 256],
}

#[cfg(feature = "flutter")]
impl Default for JoystickAxes {
    fn default() -> Self {
        Self {
            values: [0; 256],
            known: [false; 256],
        }
    }
}

#[cfg(feature = "flutter")]
fn joystick_events_have_activity(bytes: &[u8], axes: &mut JoystickAxes) -> bool {
    let mut activity = false;
    for event in bytes.as_chunks::<JOYSTICK_EVENT_BYTES>().0 {
        let value = i16::from_ne_bytes([event[4], event[5]]);
        let kind = event[6];
        let axis = usize::from(event[7]);
        let initial = kind & JS_EVENT_INIT != 0;
        match kind & !JS_EVENT_INIT {
            JS_EVENT_BUTTON if !initial => activity = true,
            JS_EVENT_AXIS => {
                if initial {
                    axes.values[axis] = value;
                    axes.known[axis] = true;
                } else if !axes.known[axis] {
                    axes.values[axis] = value;
                    axes.known[axis] = true;
                    activity = true;
                } else if i32::from(value).abs_diff(i32::from(axes.values[axis]))
                    >= JOYSTICK_AXIS_ACTIVITY_THRESHOLD as u32
                {
                    axes.values[axis] = value;
                    activity = true;
                }
            }
            _ => {}
        }
    }
    activity
}
