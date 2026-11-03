//! Wakes the compositor event loop from worker threads.
//!
//! The loop sleeps until a source fires or a deadline it knows of passes; it
//! has no periodic tick. A worker which hands the loop work through shared
//! state instead of a calloop source calls [`wake`] after publishing it, and
//! the loop's next turn picks the work up.

use std::sync::{Mutex, PoisonError};

use smithay::reexports::calloop::ping::Ping;

static LOOP: Mutex<Option<Ping>> = Mutex::new(None);

/// Points [`wake`] at the running loop's ping source.
#[cfg_attr(not(feature = "flutter"), allow(dead_code))]
pub(super) fn install(ping: Ping) {
    *LOOP.lock().unwrap_or_else(PoisonError::into_inner) = Some(ping);
}

/// Wakes the running loop. Before a loop is installed there is nothing to
/// wake: its first turn reads all shared state anyway.
pub(super) fn wake() {
    if let Some(ping) = LOOP.lock().unwrap_or_else(PoisonError::into_inner).as_ref() {
        ping.ping();
    }
}
