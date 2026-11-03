//! A coalescing wakeup that any thread sends and one async worker awaits, so
//! the worker sleeps until it has something to do instead of polling a flag.

use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;

use async_io::Async;

pub(super) struct Wakeup {
    sender: UnixStream,
    receiver: Async<UnixStream>,
}

impl Wakeup {
    pub(super) fn new() -> io::Result<Self> {
        let (sender, receiver) = UnixStream::pair()?;
        sender.set_nonblocking(true)?;
        Ok(Self {
            sender,
            receiver: Async::new(receiver)?,
        })
    }

    /// A full pipe already holds a wake, so a failed write loses nothing.
    pub(super) fn wake(&self) {
        let _ = (&self.sender).write(&[1]);
    }

    /// Returns after the next wake, or at once if one is pending.
    pub(super) async fn wait(&self) {
        let mut drained = [0_u8; 64];
        loop {
            match self.receiver.get_ref().read(&mut drained) {
                Ok(0) => return,
                Ok(_) => return self.drain(),
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    if self.receiver.readable().await.is_err() {
                        return;
                    }
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                Err(_) => return,
            }
        }
    }

    fn drain(&self) {
        let mut drained = [0_u8; 64];
        while matches!(self.receiver.get_ref().read(&mut drained), Ok(read) if read > 0) {}
    }
}
