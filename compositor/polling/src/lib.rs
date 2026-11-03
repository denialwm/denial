//! Linux-only `polling` for Denial: the part of the polling 3.11 API that
//! calloop 0.14 uses, on epoll.
//!
//! Upstream re-arms a timerfd and a one-shot notifier around every wait,
//! costing four system calls beside the wait itself (`timerfd_settime`, two
//! `epoll_ctl`, a `read`). Here a wait is one `epoll_pwait2`, which takes a
//! nanosecond timeout, and the level-triggered eventfd notifier is read only
//! when it fired. Kernels without `epoll_pwait2` (before 5.11) fall back to
//! `epoll_pwait` with the timeout rounded up to whole milliseconds.

use std::fmt;
use std::io;
use std::num::NonZeroUsize;
use std::os::fd::{AsFd, AsRawFd, BorrowedFd, FromRawFd, OwnedFd, RawFd};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

/// Reserved for the notifier; sources may not use it.
const NOTIFY_KEY: usize = usize::MAX;

const READ_FLAGS: u32 = (libc::EPOLLIN | libc::EPOLLHUP | libc::EPOLLERR | libc::EPOLLPRI) as u32;
const WRITE_FLAGS: u32 = (libc::EPOLLOUT | libc::EPOLLHUP | libc::EPOLLERR) as u32;

/// Interest in, or readiness of, the source registered under `key`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Event {
    pub key: usize,
    pub readable: bool,
    pub writable: bool,
}

impl Event {
    pub const fn new(key: usize, readable: bool, writable: bool) -> Event {
        Event {
            key,
            readable,
            writable,
        }
    }

    pub const fn all(key: usize) -> Event {
        Event::new(key, true, true)
    }

    pub const fn readable(key: usize) -> Event {
        Event::new(key, true, false)
    }

    pub const fn writable(key: usize) -> Event {
        Event::new(key, false, true)
    }

    pub const fn none(key: usize) -> Event {
        Event::new(key, false, false)
    }
}

/// How a registered source reports readiness.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum PollMode {
    /// Reported once, then disabled until the source is modified.
    Oneshot,
    /// Reported on every wait while ready.
    Level,
    /// Reported when it becomes ready.
    Edge,
    /// Reported once when it becomes ready, then disabled.
    EdgeOneshot,
}

impl PollMode {
    fn flags(self) -> u32 {
        match self {
            PollMode::Oneshot => libc::EPOLLONESHOT as u32,
            PollMode::Level => 0,
            PollMode::Edge => libc::EPOLLET as u32,
            PollMode::EdgeOneshot => (libc::EPOLLET | libc::EPOLLONESHOT) as u32,
        }
    }
}

/// A file descriptor that can be added to a [`Poller`].
pub trait AsRawSource {
    fn raw(&self) -> RawFd;
}

impl AsRawSource for RawFd {
    fn raw(&self) -> RawFd {
        *self
    }
}

impl<T: AsRawFd> AsRawSource for &T {
    fn raw(&self) -> RawFd {
        self.as_raw_fd()
    }
}

/// A registered file descriptor.
pub trait AsSource: AsFd {}

impl<T: AsFd> AsSource for T {}

/// Ready events filled in by [`Poller::wait`].
pub struct Events {
    list: Vec<libc::epoll_event>,
}

impl Events {
    pub fn new() -> Events {
        Events::with_capacity(NonZeroUsize::new(1024).unwrap())
    }

    pub fn with_capacity(capacity: NonZeroUsize) -> Events {
        Events {
            list: Vec::with_capacity(capacity.get()),
        }
    }

    pub fn iter(&self) -> impl Iterator<Item = Event> + '_ {
        self.list.iter().filter_map(|event| {
            // Copies: the kernel struct is packed on x86-64.
            let (flags, key) = (event.events, event.u64 as usize);
            (key != NOTIFY_KEY).then_some(Event {
                key,
                readable: flags & READ_FLAGS != 0,
                writable: flags & WRITE_FLAGS != 0,
            })
        })
    }

    pub fn clear(&mut self) {
        self.list.clear();
    }

    pub fn len(&self) -> usize {
        self.iter().count()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn capacity(&self) -> NonZeroUsize {
        NonZeroUsize::new(self.list.capacity()).unwrap()
    }
}

impl Default for Events {
    fn default() -> Events {
        Events::new()
    }
}

impl fmt::Debug for Events {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_list().entries(self.iter()).finish()
    }
}

/// An epoll instance with a notifier that wakes its waiter.
pub struct Poller {
    epoll: OwnedFd,
    notifier: OwnedFd,
    notified: AtomicBool,
    waiting: AtomicBool,
    pwait2: bool,
}

impl Poller {
    pub fn new() -> io::Result<Poller> {
        let epoll = owned(unsafe { libc::epoll_create1(libc::EPOLL_CLOEXEC) })?;
        let notifier = owned(unsafe { libc::eventfd(0, libc::EFD_CLOEXEC | libc::EFD_NONBLOCK) })?;
        let mut poller = Poller {
            epoll,
            notifier,
            notified: AtomicBool::new(false),
            waiting: AtomicBool::new(false),
            pwait2: true,
        };
        poller.ctl(
            libc::EPOLL_CTL_ADD,
            poller.notifier.as_raw_fd(),
            NOTIFY_KEY,
            libc::EPOLLIN as u32,
        )?;
        // The instance is empty, so the probe returns at once.
        let mut probe = Vec::with_capacity(1);
        if let Err(error) = poller.epoll_wait(&mut probe, Some(Duration::ZERO)) {
            if error.raw_os_error() != Some(libc::ENOSYS) {
                return Err(error);
            }
            poller.pwait2 = false;
        }
        Ok(poller)
    }

    pub fn supports_level(&self) -> bool {
        true
    }

    pub fn supports_edge(&self) -> bool {
        true
    }

    /// Adds a source in one-shot mode.
    ///
    /// # Safety
    ///
    /// The source must be deleted before it is closed.
    pub unsafe fn add(&self, source: impl AsRawSource, interest: Event) -> io::Result<()> {
        unsafe { self.add_with_mode(source, interest, PollMode::Oneshot) }
    }

    /// # Safety
    ///
    /// The source must be deleted before it is closed.
    pub unsafe fn add_with_mode(
        &self,
        source: impl AsRawSource,
        interest: Event,
        mode: PollMode,
    ) -> io::Result<()> {
        self.ctl(
            libc::EPOLL_CTL_ADD,
            source.raw(),
            source_key(interest)?,
            interest_flags(interest, mode),
        )
    }

    pub fn modify(&self, source: impl AsSource, interest: Event) -> io::Result<()> {
        self.modify_with_mode(source, interest, PollMode::Oneshot)
    }

    pub fn modify_with_mode(
        &self,
        source: impl AsSource,
        interest: Event,
        mode: PollMode,
    ) -> io::Result<()> {
        self.ctl(
            libc::EPOLL_CTL_MOD,
            source.as_fd().as_raw_fd(),
            source_key(interest)?,
            interest_flags(interest, mode),
        )
    }

    pub fn delete(&self, source: impl AsSource) -> io::Result<()> {
        self.ctl(libc::EPOLL_CTL_DEL, source.as_fd().as_raw_fd(), 0, 0)
    }

    /// Replaces `events` with the ready sources, waiting up to `timeout`
    /// (forever when `None`) or until [`Poller::notify`]. Returns the number
    /// of events. As upstream, a concurrent second waiter returns at once
    /// with no events.
    pub fn wait(&self, events: &mut Events, timeout: Option<Duration>) -> io::Result<usize> {
        if self.waiting.swap(true, Ordering::Acquire) {
            events.clear();
            return Ok(0);
        }
        let result = self.wait_exclusive(events, timeout);
        self.waiting.store(false, Ordering::Release);
        result
    }

    /// Wakes the current or next [`Poller::wait`].
    pub fn notify(&self) -> io::Result<()> {
        if self
            .notified
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_ok()
        {
            let count = 1u64;
            // Fails only when the counter is saturated, which wakes the waiter too.
            unsafe { libc::write(self.notifier.as_raw_fd(), (&raw const count).cast(), 8) };
        }
        Ok(())
    }

    fn wait_exclusive(&self, events: &mut Events, timeout: Option<Duration>) -> io::Result<usize> {
        let start = timeout.filter(|t| !t.is_zero()).map(|_| Instant::now());
        let mut remaining = timeout;
        loop {
            match self.epoll_wait(&mut events.list, remaining) {
                Ok(()) => break,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => {
                    if let (Some(timeout), Some(start)) = (timeout, start) {
                        remaining = Some(timeout.saturating_sub(start.elapsed()));
                    }
                }
                Err(error) => return Err(error),
            }
        }
        if events
            .list
            .iter()
            .any(|event| { event.u64 } == NOTIFY_KEY as u64)
        {
            let mut count = 0u64;
            // A notify racing this read is covered by this wait returning.
            unsafe { libc::read(self.notifier.as_raw_fd(), (&raw mut count).cast(), 8) };
            self.notified.store(false, Ordering::SeqCst);
        }
        Ok(events.len())
    }

    fn epoll_wait(
        &self,
        list: &mut Vec<libc::epoll_event>,
        timeout: Option<Duration>,
    ) -> io::Result<()> {
        list.clear();
        let capacity = list.capacity().min(libc::c_int::MAX as usize) as libc::c_long;
        let ready = if self.pwait2 {
            let timespec = timeout.map(|t| {
                let mut timespec: libc::timespec = unsafe { std::mem::zeroed() };
                timespec.tv_sec = t.as_secs().min(libc::time_t::MAX as u64) as libc::time_t;
                timespec.tv_nsec = t.subsec_nanos() as _;
                timespec
            });
            unsafe {
                libc::syscall(
                    libc::SYS_epoll_pwait2,
                    self.epoll.as_raw_fd() as libc::c_long,
                    list.as_mut_ptr(),
                    capacity,
                    timespec
                        .as_ref()
                        .map_or(std::ptr::null(), |t| t as *const libc::timespec),
                    std::ptr::null::<libc::sigset_t>(),
                    0 as libc::size_t,
                )
            }
        } else {
            let millis = timeout.map_or(-1, |t| {
                t.as_nanos()
                    .div_ceil(1_000_000)
                    .min(libc::c_int::MAX as u128) as libc::c_int
            });
            unsafe {
                libc::epoll_wait(
                    self.epoll.as_raw_fd(),
                    list.as_mut_ptr(),
                    capacity as libc::c_int,
                    millis,
                )
            }
            .into()
        };
        if ready < 0 {
            return Err(io::Error::last_os_error());
        }
        unsafe { list.set_len(ready as usize) };
        Ok(())
    }

    fn ctl(&self, op: libc::c_int, fd: RawFd, key: usize, flags: u32) -> io::Result<()> {
        let mut event = libc::epoll_event {
            events: flags,
            u64: key as u64,
        };
        if unsafe { libc::epoll_ctl(self.epoll.as_raw_fd(), op, fd, &mut event) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }
}

impl AsRawFd for Poller {
    fn as_raw_fd(&self) -> RawFd {
        self.epoll.as_raw_fd()
    }
}

impl AsFd for Poller {
    fn as_fd(&self) -> BorrowedFd<'_> {
        self.epoll.as_fd()
    }
}

impl fmt::Debug for Poller {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Poller")
            .field("epoll", &self.epoll)
            .field("notifier", &self.notifier)
            .field("pwait2", &self.pwait2)
            .finish_non_exhaustive()
    }
}

fn owned(fd: libc::c_int) -> io::Result<OwnedFd> {
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

fn source_key(interest: Event) -> io::Result<usize> {
    if interest.key == NOTIFY_KEY {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "the key is not allowed to be `usize::MAX`",
        ));
    }
    Ok(interest.key)
}

fn interest_flags(interest: Event, mode: PollMode) -> u32 {
    let mut flags = mode.flags();
    if interest.readable {
        flags |= READ_FLAGS;
    }
    if interest.writable {
        flags |= WRITE_FLAGS;
    }
    flags
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    fn pipe() -> (OwnedFd, OwnedFd) {
        let mut fds = [0; 2];
        assert_eq!(
            unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC | libc::O_NONBLOCK) },
            0
        );
        unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) }
    }

    fn put(fd: &OwnedFd) {
        assert_eq!(
            unsafe { libc::write(fd.as_raw_fd(), [1u8].as_ptr().cast(), 1) },
            1
        );
    }

    fn take(fd: &OwnedFd) {
        let mut byte = [0u8; 64];
        assert!(unsafe { libc::read(fd.as_raw_fd(), byte.as_mut_ptr().cast(), 64) } > 0);
    }

    fn ready(poller: &Poller) -> Vec<Event> {
        let mut events = Events::new();
        poller.wait(&mut events, Some(Duration::ZERO)).unwrap();
        events.iter().collect()
    }

    #[test]
    fn notify_wakes_one_wait_and_rearms() {
        let poller = Poller::new().unwrap();
        let mut events = Events::new();
        for _ in 0..3 {
            poller.notify().unwrap();
            poller.notify().unwrap();
            assert_eq!(poller.wait(&mut events, None).unwrap(), 0);
            assert!(events.is_empty());
            // Drained: the next wait times out.
            let start = Instant::now();
            assert_eq!(
                poller
                    .wait(&mut events, Some(Duration::from_millis(5)))
                    .unwrap(),
                0
            );
            assert!(start.elapsed() >= Duration::from_millis(5));
        }
    }

    #[test]
    fn notify_from_another_thread_wakes_a_blocking_wait() {
        let poller = Arc::new(Poller::new().unwrap());
        let notifier = Arc::clone(&poller);
        let thread = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(20));
            notifier.notify().unwrap();
        });
        let mut events = Events::new();
        assert_eq!(
            poller
                .wait(&mut events, Some(Duration::from_secs(10)))
                .unwrap(),
            0
        );
        thread.join().unwrap();
    }

    #[test]
    fn timeout_is_never_early() {
        let poller = Poller::new().unwrap();
        let mut events = Events::new();
        for micros in [100, 1500, 2300] {
            let timeout = Duration::from_micros(micros);
            let start = Instant::now();
            poller.wait(&mut events, Some(timeout)).unwrap();
            assert!(start.elapsed() >= timeout);
        }
    }

    #[test]
    fn epoll_pwait_fallback_rounds_up() {
        let mut poller = Poller::new().unwrap();
        assert!(poller.pwait2, "kernel without epoll_pwait2");
        poller.pwait2 = false;
        let mut events = Events::new();
        let start = Instant::now();
        poller
            .wait(&mut events, Some(Duration::from_micros(1200)))
            .unwrap();
        assert!(start.elapsed() >= Duration::from_millis(2));
        poller.notify().unwrap();
        assert_eq!(poller.wait(&mut events, None).unwrap(), 0);
    }

    #[test]
    fn modes_report_as_epoll_does() {
        let poller = Poller::new().unwrap();
        let (level_read, level_write) = pipe();
        let (once_read, once_write) = pipe();
        let (edge_read, edge_write) = pipe();
        unsafe {
            poller
                .add_with_mode(&level_read, Event::readable(1), PollMode::Level)
                .unwrap();
            poller
                .add_with_mode(&once_read, Event::readable(2), PollMode::Oneshot)
                .unwrap();
            poller
                .add_with_mode(&edge_read, Event::readable(3), PollMode::Edge)
                .unwrap();
        }
        assert!(ready(&poller).is_empty());
        for fd in [&level_write, &once_write, &edge_write] {
            put(fd);
        }
        let mut keys: Vec<_> = ready(&poller)
            .iter()
            .map(|e| (e.key, e.readable, e.writable))
            .collect();
        keys.sort();
        assert_eq!(keys, [(1, true, false), (2, true, false), (3, true, false)]);
        // Unread data: level repeats, one-shot is disarmed, edge waits for new data.
        assert_eq!(ready(&poller), [Event::readable(1)]);
        poller.modify(&once_read, Event::readable(2)).unwrap();
        put(&edge_write);
        let mut keys: Vec<_> = ready(&poller).iter().map(|e| e.key).collect();
        keys.sort();
        assert_eq!(keys, [1, 2, 3]);
        take(&level_read);
        poller.delete(&once_read).unwrap();
        assert!(ready(&poller).is_empty());
    }

    #[test]
    fn writable_and_hangup() {
        let poller = Poller::new().unwrap();
        let (read, write) = pipe();
        unsafe {
            poller
                .add_with_mode(&write, Event::all(7), PollMode::Level)
                .unwrap();
        }
        assert_eq!(ready(&poller), [Event::new(7, false, true)]);
        poller
            .modify_with_mode(&write, Event::none(7), PollMode::Level)
            .unwrap();
        assert!(ready(&poller).is_empty());
        poller.delete(&write).unwrap();
        unsafe {
            poller
                .add_with_mode(&read, Event::readable(8), PollMode::Level)
                .unwrap();
        }
        drop(write);
        // As upstream, a hangup reads as both readable and writable.
        assert_eq!(ready(&poller), [Event::all(8)]);
    }

    #[test]
    fn notifier_key_is_reserved() {
        let poller = Poller::new().unwrap();
        let (read, _write) = pipe();
        let error = unsafe { poller.add(&read, Event::readable(NOTIFY_KEY)) }.unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
    }
}
