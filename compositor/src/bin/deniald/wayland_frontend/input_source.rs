//! Libinput source adapter with an explicit end-of-batch edge.
//!
//! Smithay drains every queued libinput event in one `EventSource` callback,
//! but calloop normally exposes only the individual events to the compositor.
//! The final edge lets Denial flush Wayland clients once after the whole batch
//! without adding a timer, wakeup fd, or allocation to the input path.

use std::io;

use smithay::backend::input::InputEvent;
use smithay::backend::libinput::LibinputInputBackend;
use smithay::reexports::calloop::{
    self, EventSource, Poll, PostAction, Readiness, Token, TokenFactory,
};

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
