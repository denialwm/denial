//! deniald's shared system bus connection.
//!
//! Long-lived system clients share one connection, and with it one socket and
//! one zbus executor thread. Its calls are bounded by [`CALL_TIMEOUT`]. A
//! client that needs another bound or a connection of its own builds one:
//! haptics drops stale taps after 250 ms, a fingerprint verify keeps old
//! signals out of a retry, and an interactive power action waits for polkit.

use std::sync::{Mutex, PoisonError};
use std::time::Duration;

/// System services answer at once, or after D-Bus activation within this.
const CALL_TIMEOUT: Duration = Duration::from_secs(3);

static SYSTEM: Mutex<Option<zbus::Connection>> = Mutex::new(None);

/// The shared connection, opened on first use and again once the bus has
/// closed it.
pub(super) async fn system() -> zbus::Result<zbus::Connection> {
    if let Some(connection) = open() {
        return Ok(connection);
    }
    let connection = zbus::connection::Builder::system()?
        .method_timeout(CALL_TIMEOUT)
        .build()
        .await?;
    let mut shared = SYSTEM.lock().unwrap_or_else(PoisonError::into_inner);
    // Two first users may race; the later one drops its connection.
    match shared.as_ref().filter(|existing| !existing.is_closed()) {
        Some(existing) => Ok(existing.clone()),
        None => Ok(shared.insert(connection).clone()),
    }
}

/// [`system`] for blocking clients.
pub(super) fn blocking_system() -> zbus::Result<zbus::blocking::Connection> {
    async_io::block_on(system()).map(Into::into)
}

fn open() -> Option<zbus::Connection> {
    SYSTEM
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .as_ref()
        .filter(|connection| !connection.is_closed())
        .cloned()
}
