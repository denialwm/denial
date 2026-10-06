//! `wlr-gamma-control-unstable-v1` protocol plumbing.

use std::collections::{BTreeMap, HashMap};
use std::os::fd::AsFd;

use denial_core::topology::OutputId;
use smithay::output::Output;
use smithay::reexports::calloop::{
    Interest, Mode, PostAction, RegistrationToken, generic::Generic,
};
use smithay::reexports::rustix::fs::{OFlags, fcntl_getfl, fcntl_setfl};
use smithay::reexports::rustix::io::{Errno, read};
use smithay::reexports::wayland_protocols_wlr::gamma_control::v1::server::{
    zwlr_gamma_control_manager_v1::{self, ZwlrGammaControlManagerV1},
    zwlr_gamma_control_v1::{self, ZwlrGammaControlV1},
};
use smithay::reexports::wayland_server::{
    Client, DataInit, Dispatch, DisplayHandle, GlobalDispatch, New, Resource, backend::GlobalId,
};

use super::{RuntimeState, WaylandFrontend};

const VERSION: u32 = 1;

pub(super) struct GammaControlManager {
    _global: GlobalId,
    capabilities: BTreeMap<OutputId, u32>,
    controls: HashMap<OutputId, ZwlrGammaControlV1>,
    reads: HashMap<OutputId, RegistrationToken>,
    pending: BTreeMap<OutputId, Option<Vec<u16>>>,
}

impl GammaControlManager {
    pub(super) fn new(display: &DisplayHandle) -> Self {
        Self {
            _global: display
                .create_global::<RuntimeState, ZwlrGammaControlManagerV1, _>(VERSION, ()),
            capabilities: BTreeMap::new(),
            controls: HashMap::new(),
            reads: HashMap::new(),
            pending: BTreeMap::new(),
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub(super) struct GammaControlUserData {
    output: Option<OutputId>,
    size: u32,
}

enum GammaRead {
    Pending,
    Complete(Vec<u16>),
    Invalid(String),
}

fn read_gamma_payload(
    fd: std::os::fd::BorrowedFd<'_>,
    expected: usize,
    payload: &mut Vec<u8>,
) -> GammaRead {
    loop {
        let remaining = expected.saturating_add(1).saturating_sub(payload.len());
        if remaining == 0 {
            return GammaRead::Invalid("gamma table is larger than advertised".to_owned());
        }
        let mut chunk = [0u8; 4096];
        let length = chunk.len().min(remaining);
        match read(fd, &mut chunk[..length]) {
            Ok(0) if payload.len() == expected => {
                return GammaRead::Complete(
                    payload
                        .chunks_exact(2)
                        .map(|bytes| u16::from_ne_bytes([bytes[0], bytes[1]]))
                        .collect(),
                );
            }
            Ok(0) => {
                return GammaRead::Invalid(format!(
                    "gamma table has {} bytes, expected {expected}",
                    payload.len()
                ));
            }
            Ok(length) => payload.extend_from_slice(&chunk[..length]),
            Err(Errno::AGAIN) => return GammaRead::Pending,
            Err(Errno::INTR) => continue,
            Err(error) => {
                return GammaRead::Invalid(format!("could not read gamma table: {error}"));
            }
        }
    }
}

impl WaylandFrontend {
    fn gamma_output_id(
        &self,
        resource: &smithay::reexports::wayland_server::protocol::wl_output::WlOutput,
    ) -> Option<OutputId> {
        let output = Output::from_resource(resource)?;
        self.outputs
            .iter()
            .find(|entry| entry.output == output)
            .map(|entry| entry.id)
    }

    fn register_gamma_control(&mut self, output: Option<OutputId>, resource: ZwlrGammaControlV1) {
        let Some(output) = output else {
            resource.failed();
            return;
        };
        let Some(size) = self.gamma_control.capabilities.get(&output).copied() else {
            resource.failed();
            return;
        };
        if self.gamma_control.controls.contains_key(&output) {
            resource.failed();
            return;
        }
        resource.gamma_size(size);
        self.gamma_control.controls.insert(output, resource);
    }

    fn gamma_control_is_current(&self, output: OutputId, resource: &ZwlrGammaControlV1) -> bool {
        self.gamma_control
            .controls
            .get(&output)
            .is_some_and(|current| current.id() == resource.id())
    }

    fn cancel_gamma_read(&mut self, output: OutputId) {
        if let Some(token) = self.gamma_control.reads.remove(&output) {
            self.loop_handle.remove(token);
        }
    }

    fn unregister_gamma_control(&mut self, output: OutputId, resource: &ZwlrGammaControlV1) {
        if !self.gamma_control_is_current(output, resource) {
            return;
        }
        self.cancel_gamma_read(output);
        self.gamma_control.controls.remove(&output);
        self.gamma_control.pending.insert(output, None);
    }

    fn fail_gamma_control(&mut self, output: OutputId) {
        self.cancel_gamma_read(output);
        self.gamma_control.pending.remove(&output);
        if let Some(resource) = self.gamma_control.controls.remove(&output) {
            resource.failed();
        }
    }

    fn reject_gamma_data(
        &mut self,
        output: OutputId,
        resource: &ZwlrGammaControlV1,
        message: impl Into<String>,
    ) {
        if self.gamma_control_is_current(output, resource) {
            self.gamma_control.reads.remove(&output);
            self.gamma_control.controls.remove(&output);
            self.gamma_control.pending.insert(output, None);
        }
        resource.post_error(zwlr_gamma_control_v1::Error::InvalidGamma, message.into());
    }

    fn start_gamma_read(
        &mut self,
        output: OutputId,
        size: u32,
        resource: ZwlrGammaControlV1,
        fd: std::os::fd::OwnedFd,
    ) {
        if !self.gamma_control_is_current(output, &resource) {
            return;
        }
        self.cancel_gamma_read(output);
        let expected = usize::try_from(size)
            .ok()
            .and_then(|size| size.checked_mul(3))
            .and_then(|entries| entries.checked_mul(size_of::<u16>()));
        let Some(expected) = expected else {
            self.reject_gamma_data(output, &resource, "gamma table size overflow");
            return;
        };
        let flags = fcntl_getfl(&fd).unwrap_or(OFlags::RDONLY);
        if let Err(error) = fcntl_setfl(&fd, flags | OFlags::NONBLOCK) {
            self.reject_gamma_data(
                output,
                &resource,
                format!("could not read gamma table: {error}"),
            );
            return;
        }

        let mut payload = Vec::with_capacity(expected.saturating_add(1));
        match read_gamma_payload(fd.as_fd(), expected, &mut payload) {
            GammaRead::Complete(ramp) => {
                self.gamma_control.pending.insert(output, Some(ramp));
                return;
            }
            GammaRead::Invalid(message) => {
                self.reject_gamma_data(output, &resource, message);
                return;
            }
            GammaRead::Pending => {}
        }
        let callback_resource = resource.clone();
        let source = self.loop_handle.insert_source(
            Generic::new(fd, Interest::READ, Mode::Level),
            move |_, fd, state: &mut RuntimeState| match read_gamma_payload(
                fd.as_fd(),
                expected,
                &mut payload,
            ) {
                GammaRead::Pending => Ok(PostAction::Continue),
                GammaRead::Complete(ramp) => {
                    if let Some(frontend) = state.wayland.as_mut() {
                        frontend.gamma_control.reads.remove(&output);
                        if frontend.gamma_control_is_current(output, &callback_resource) {
                            frontend.gamma_control.pending.insert(output, Some(ramp));
                        }
                    }
                    Ok(PostAction::Remove)
                }
                GammaRead::Invalid(message) => {
                    if let Some(frontend) = state.wayland.as_mut() {
                        frontend.reject_gamma_data(output, &callback_resource, message);
                    }
                    Ok(PostAction::Remove)
                }
            },
        );
        match source {
            Ok(token) => {
                self.gamma_control.reads.insert(output, token);
            }
            Err(error) => self.reject_gamma_data(
                output,
                &resource,
                format!("could not monitor gamma table: {error}"),
            ),
        }
    }

    pub(crate) fn set_gamma_capabilities(&mut self, capabilities: BTreeMap<OutputId, u32>) {
        let invalidated = self
            .gamma_control
            .controls
            .keys()
            .copied()
            .filter(|output| {
                self.gamma_control.capabilities.get(output) != capabilities.get(output)
            })
            .collect::<Vec<_>>();
        self.gamma_control.capabilities = capabilities;
        for output in invalidated {
            self.fail_gamma_control(output);
        }
    }

    pub(crate) fn take_gamma_changes(&mut self) -> BTreeMap<OutputId, Option<Vec<u16>>> {
        std::mem::take(&mut self.gamma_control.pending)
    }

    pub(crate) fn gamma_control_failed(&mut self, output: OutputId) {
        self.fail_gamma_control(output);
    }
}

impl GlobalDispatch<ZwlrGammaControlManagerV1, ()> for RuntimeState {
    fn bind(
        _state: &mut Self,
        _handle: &DisplayHandle,
        _client: &Client,
        resource: New<ZwlrGammaControlManagerV1>,
        _global_data: &(),
        data_init: &mut DataInit<'_, Self>,
    ) {
        data_init.init(resource, ());
    }
}

impl Dispatch<ZwlrGammaControlManagerV1, ()> for RuntimeState {
    fn request(
        state: &mut Self,
        _client: &Client,
        _resource: &ZwlrGammaControlManagerV1,
        request: zwlr_gamma_control_manager_v1::Request,
        _data: &(),
        _handle: &DisplayHandle,
        data_init: &mut DataInit<'_, Self>,
    ) {
        match request {
            zwlr_gamma_control_manager_v1::Request::GetGammaControl { id, output } => {
                let output = state
                    .wayland
                    .as_ref()
                    .and_then(|frontend| frontend.gamma_output_id(&output));
                let size = output
                    .and_then(|output| {
                        state
                            .wayland
                            .as_ref()?
                            .gamma_control
                            .capabilities
                            .get(&output)
                    })
                    .copied()
                    .unwrap_or(0);
                let resource = data_init.init(id, GammaControlUserData { output, size });
                if let Some(frontend) = state.wayland.as_mut() {
                    frontend.register_gamma_control(output, resource);
                } else {
                    resource.failed();
                }
            }
            zwlr_gamma_control_manager_v1::Request::Destroy => {}
            _ => unreachable!(),
        }
    }
}

impl Dispatch<ZwlrGammaControlV1, GammaControlUserData> for RuntimeState {
    fn request(
        state: &mut Self,
        _client: &Client,
        resource: &ZwlrGammaControlV1,
        request: zwlr_gamma_control_v1::Request,
        data: &GammaControlUserData,
        _handle: &DisplayHandle,
        _data_init: &mut DataInit<'_, Self>,
    ) {
        match request {
            zwlr_gamma_control_v1::Request::SetGamma { fd } => {
                if let Some(output) = data.output
                    && let Some(frontend) = state.wayland.as_mut()
                {
                    frontend.start_gamma_read(output, data.size, resource.clone(), fd);
                }
            }
            zwlr_gamma_control_v1::Request::Destroy => {}
            _ => unreachable!(),
        }
    }

    fn destroyed(
        state: &mut Self,
        _client: smithay::reexports::wayland_server::backend::ClientId,
        resource: &ZwlrGammaControlV1,
        data: &GammaControlUserData,
    ) {
        if let Some(output) = data.output
            && let Some(frontend) = state.wayland.as_mut()
        {
            frontend.unregister_gamma_control(output, resource);
        }
    }
}
