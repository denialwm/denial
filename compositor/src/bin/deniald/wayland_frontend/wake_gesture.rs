//! Hardware-decoded wake gestures excluded by libinput (for example, a
//! touchscreen's vendor gesture-only evdev node). Never synthesize input.
use super::super::RuntimeState;
use serde::Deserialize;
use smithay::backend::session::{Session, libseat::LibSeatSession};
use smithay::reexports::{
    calloop::{
        EventLoop, Interest, LoopHandle, Mode, PostAction,
        generic::Generic,
        timer::{TimeoutAction, Timer},
    },
    rustix::{fs::OFlags, io as rio, ioctl::opcode},
};
use std::{
    cell::RefCell,
    collections::HashSet,
    error::Error,
    fs, io,
    os::{
        fd::{AsFd, AsRawFd, BorrowedFd, OwnedFd},
        unix::fs::MetadataExt,
    },
    path::{Path, PathBuf},
    rc::Rc,
    time::Duration,
};
use tracing::{info, warn};

const RESCAN: Duration = Duration::from_secs(2);
const EVENT_BYTES: usize = size_of::<libc::input_event>();
const EVENT_PAYLOAD: usize = std::mem::offset_of!(libc::input_event, type_);

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Profile {
    input_name: String,
    key_code: u16,
    output: String,
}
impl Profile {
    fn validate(&self) -> Result<(), &'static str> {
        if self.input_name.is_empty()
            || self.input_name.len() > 128
            || self.input_name.chars().any(char::is_control)
            || self.output.is_empty()
            || self.output.len() > 128
            || !self
                .output
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
            || !(1..=767).contains(&self.key_code)
        {
            return Err("invalid wake gesture profile");
        }
        Ok(())
    }
    fn load(path: &Path) -> Result<Self, Box<dyn Error>> {
        let meta = fs::symlink_metadata(path)?;
        if !meta.is_file() || meta.uid() != 0 || meta.mode() & 0o022 != 0 || meta.len() > 4096 {
            return Err("wake gesture profile must be a protected root-owned regular file".into());
        }
        let profile: Self = serde_json::from_slice(&fs::read(path)?)?;
        profile.validate()?;
        Ok(profile)
    }
}

pub(super) fn init(
    event_loop: &mut EventLoop<'static, RuntimeState>,
    session: LibSeatSession,
) -> Result<(), Box<dyn Error>> {
    let path = Path::new("/etc/denial/wake-gesture.json");
    if !path.exists() {
        return Ok(());
    }
    let profile = match Profile::load(path) {
        Ok(p) => Rc::new(p),
        Err(error) => {
            warn!(%error, "wake gesture profile rejected");
            return Ok(());
        }
    };
    let watched = Rc::new(RefCell::new(HashSet::new()));
    let handle = event_loop.handle();
    scan(&handle, &session, &watched, &profile);
    event_loop
        .handle()
        .insert_source(Timer::from_duration(RESCAN), move |_, _, _| {
            scan(&handle, &session, &watched, &profile);
            TimeoutAction::ToDuration(RESCAN)
        })?;
    Ok(())
}

fn scan(
    handle: &LoopHandle<'static, RuntimeState>,
    session: &LibSeatSession,
    watched: &Rc<RefCell<HashSet<PathBuf>>>,
    profile: &Rc<Profile>,
) {
    if !session.is_active() {
        return;
    }
    let Ok(entries) = fs::read_dir("/sys/class/input") else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else {
            continue;
        };
        if !name
            .strip_prefix("event")
            .is_some_and(|s| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()))
        {
            continue;
        }
        if fs::read_to_string(entry.path().join("device/name"))
            .ok()
            .as_deref()
            .map(str::trim)
            != Some(&profile.input_name)
        {
            continue;
        }
        let path = Path::new("/dev/input").join(name);
        if watched.borrow().contains(&path) {
            continue;
        }
        if let Err(error) = watch(
            handle,
            session.clone(),
            watched.clone(),
            path.clone(),
            profile.clone(),
        ) {
            warn!(%error, device = %path.display(), "could not watch hardware wake gesture");
        }
    }
}

struct SeatFd {
    fd: Option<OwnedFd>,
    session: LibSeatSession,
    path: PathBuf,
    watched: Rc<RefCell<HashSet<PathBuf>>>,
    decoder: RefCell<Decoder>,
}
impl AsFd for SeatFd {
    fn as_fd(&self) -> BorrowedFd<'_> {
        self.fd.as_ref().expect("live wake gesture fd").as_fd()
    }
}
impl Drop for SeatFd {
    fn drop(&mut self) {
        self.watched.borrow_mut().remove(&self.path);
        if let Some(fd) = self.fd.take() {
            if let Err(error) = self.session.close(fd) {
                warn!(%error, "could not close wake gesture device");
            }
        }
    }
}

fn watch(
    handle: &LoopHandle<'static, RuntimeState>,
    mut session: LibSeatSession,
    watched: Rc<RefCell<HashSet<PathBuf>>>,
    path: PathBuf,
    profile: Rc<Profile>,
) -> Result<(), Box<dyn Error>> {
    let fd = session.open(&path, OFlags::RDONLY | OFlags::CLOEXEC | OFlags::NONBLOCK)?;
    let device = SeatFd {
        fd: Some(fd),
        session,
        path: path.clone(),
        watched: watched.clone(),
        decoder: RefCell::new(Decoder::default()),
    };
    // Recheck the opened object, not just a sysfs path that could be hot-replaced.
    let mut name = [0u8; 256];
    let mut keys = [0u8; 96];
    // SAFETY: EVIOCGNAME/EVIOCGBIT(EV_KEY) write at most the exact encoded
    // array sizes to initialized writable buffers; the seat owns a live fd.
    let (named, keyed) = unsafe {
        (
            libc::ioctl(
                device.as_fd().as_raw_fd(),
                opcode::read::<[u8; 256]>(b'E', 0x06) as _,
                name.as_mut_ptr(),
            ),
            libc::ioctl(
                device.as_fd().as_raw_fd(),
                opcode::read::<[u8; 96]>(b'E', 0x21) as _,
                keys.as_mut_ptr(),
            ),
        )
    };
    if named < 0 || keyed < 0 {
        return Err(io::Error::last_os_error().into());
    }
    let end = name.iter().position(|b| *b == 0).unwrap_or(name.len());
    let key = usize::from(profile.key_code);
    if &name[..end] != profile.input_name.as_bytes() || keys[key / 8] & (1 << (key % 8)) == 0 {
        return Err("wake gesture device identity/capability changed".into());
    }
    watched.borrow_mut().insert(path.clone());
    handle.insert_source(
        Generic::new(device, Interest::READ, Mode::Level),
        move |_, device, state| {
            let mut bytes = [0u8; EVENT_BYTES * 64];
            let mut wake = false;
            // Keep dispatch bounded even if a device floods its input queue.
            for _ in 0..4 {
                match rio::read(device.as_fd(), &mut bytes) {
                    Ok(0) => return Ok(PostAction::Remove),
                    Ok(n) if n % EVENT_BYTES == 0 => {
                        let mut decoder = device.as_ref().decoder.borrow_mut();
                        for raw in bytes[..n].chunks_exact(EVENT_BYTES) {
                            let b = &raw[EVENT_PAYLOAD..];
                            wake |= decoder.event(
                                u16::from_ne_bytes([b[0], b[1]]),
                                u16::from_ne_bytes([b[2], b[3]]),
                                i32::from_ne_bytes(b[4..8].try_into().unwrap()),
                                profile.key_code,
                            );
                        }
                    }
                    Ok(_) => {
                        warn!("malformed wake gesture input read");
                        return Ok(PostAction::Remove);
                    }
                    Err(rio::Errno::AGAIN) => break,
                    Err(rio::Errno::INTR) => continue,
                    Err(error) => {
                        warn!(%error, "wake gesture input removed");
                        return Ok(PostAction::Remove);
                    }
                }
            }
            if device.as_ref().session.is_active() {
                if wake {
                    state.wake_gesture_outputs.insert(profile.output.clone());
                }
            } else {
                *device.as_ref().decoder.borrow_mut() = Decoder::default();
            }
            Ok(PostAction::Continue)
        },
    )?;
    info!(device = %path.display(), "watching hardware wake gesture");
    Ok(())
}

#[derive(Default)]
struct Decoder {
    dropped: bool,
    pending: bool,
    held: bool,
}
impl Decoder {
    fn event(&mut self, kind: u16, code: u16, value: i32, expected: u16) -> bool {
        if kind == 0 && code == 3 {
            // SYN_DROPPED
            self.dropped = true;
            self.pending = false;
            self.held = false;
            return false;
        }
        if kind == 0 && code == 0 {
            // SYN_REPORT: commit only complete frames.
            if self.dropped {
                self.dropped = false;
                return false;
            }
            return std::mem::take(&mut self.pending);
        }
        if !self.dropped && kind == 1 && code == expected {
            match value {
                1 if !self.held => {
                    self.held = true;
                    self.pending = true;
                }
                0 => self.held = false,
                _ => {}
            }
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_a_complete_double_tap_press_wakes() {
        let mut d = Decoder::default();
        for code in [704, 705, 706, 707, 708] {
            assert!(!d.event(1, code, 1, 709));
            assert!(!d.event(0, 0, 0, 709));
        }
        assert!(!d.event(3, 0, 1000, 709));
        assert!(!d.event(1, 709, 1, 709));
        assert!(d.event(0, 0, 0, 709));
        assert!(!d.event(1, 709, 1, 709));
        assert!(!d.event(1, 709, 2, 709));
        assert!(!d.event(0, 0, 0, 709));
        assert!(!d.event(1, 709, 0, 709));
        assert!(!d.event(0, 0, 0, 709));
        assert!(!d.event(1, 709, 1, 709));
        assert!(d.event(0, 0, 0, 709));
    }
    #[test]
    fn lost_input_cannot_complete_a_partial_wake() {
        let mut d = Decoder::default();
        d.event(1, 709, 1, 709);
        d.event(0, 3, 0, 709);
        d.event(1, 709, 1, 709);
        assert!(!d.event(0, 0, 0, 709));
        assert!(!d.event(0, 0, 0, 709));
        d.event(1, 709, 1, 709);
        assert!(d.event(0, 0, 0, 709));
    }
    #[test]
    fn profile_requires_a_bounded_exact_device_key_and_output() {
        let mut p = Profile {
            input_name: "double-tap".into(),
            key_code: 709,
            output: "DSI-1".into(),
        };
        assert!(p.validate().is_ok());
        p.key_code = 768;
        assert!(p.validate().is_err());
        p.key_code = 709;
        p.output = "../x".into();
        assert!(p.validate().is_err());
    }
}
