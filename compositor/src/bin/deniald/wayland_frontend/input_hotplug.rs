//! Finds the evdev nodes libinput leaves to Denial (joysticks) when
//! `/dev/input` changes or the seat session returns, instead of polling the
//! directory.

use std::cell::RefCell;
use std::error::Error;
use std::mem::MaybeUninit;
use std::os::fd::AsFd;

use smithay::backend::session::libseat::LibSeatSession;
use smithay::reexports::calloop::{
    EventLoop, Interest, Mode, PostAction,
    generic::Generic,
    ping::{Ping, make_ping},
};
use smithay::reexports::rustix::{
    fs::inotify::{self, CreateFlags, WatchFlags},
    io::Errno,
};
use tracing::warn;

use super::super::RuntimeState;

/// Requests one coalesced rescan, for example after the session returns: a
/// paused session revokes the descriptors the scans opened.
pub(super) struct InputRescan(Ping);

impl InputRescan {
    pub(super) fn request(&self) {
        self.0.ping();
    }
}

pub(super) fn init(
    event_loop: &mut EventLoop<'static, RuntimeState>,
    session: &LibSeatSession,
) -> Result<InputRescan, Box<dyn Error>> {
    let handle = event_loop.handle();
    let scans = RefCell::new(vec![super::input_source::joystick_scan(
        &handle,
        session.clone(),
    )]);
    let run = move || {
        for scan in scans.borrow_mut().iter_mut() {
            scan();
        }
    };
    run();

    let (ping, source) = make_ping()?;
    handle.insert_source(source, move |_, _, _| run())?;
    let rescan = InputRescan(ping.clone());

    // Device nodes appear on creation; udev's later permission change gives
    // a node that could not be opened yet a second chance.
    let watcher = inotify::init(CreateFlags::CLOEXEC | CreateFlags::NONBLOCK)?;
    if let Err(error) = inotify::add_watch(
        &watcher,
        "/dev/input",
        WatchFlags::CREATE | WatchFlags::MOVED_TO | WatchFlags::ATTRIB,
    ) {
        warn!(%error, "cannot watch /dev/input; input devices added later stay unwatched");
        return Ok(rescan);
    }
    handle.insert_source(
        Generic::new(watcher, Interest::READ, Mode::Level),
        move |_, watcher, _| {
            let mut buffer = [MaybeUninit::uninit(); 4096];
            let mut reader = inotify::Reader::new(watcher.as_fd(), &mut buffer);
            loop {
                match reader.next() {
                    Ok(_) => ping.ping(),
                    Err(Errno::AGAIN) => return Ok(PostAction::Continue),
                    Err(Errno::INTR) => {}
                    Err(error) => {
                        warn!(%error, "/dev/input watch failed");
                        return Ok(PostAction::Remove);
                    }
                }
            }
        },
    )?;
    Ok(rescan)
}
