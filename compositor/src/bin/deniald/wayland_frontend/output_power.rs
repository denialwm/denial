//! `zwlr-output-power-management-v1` protocol state.
//!
//! A powered-off output remains part of the Wayland topology. Requests are
//! only journaled here; the outer KMS loop applies them after any in-flight
//! page flip has retired and reports the resulting hardware state back.

use std::collections::{BTreeMap, HashMap};

use denial_core::topology::OutputId;
use smithay::output::Output;
use smithay::reexports::wayland_protocols_wlr::output_power_management::v1::server::{
    zwlr_output_power_manager_v1::{self, ZwlrOutputPowerManagerV1},
    zwlr_output_power_v1::{self, ZwlrOutputPowerV1},
};
use smithay::reexports::wayland_server::{
    Client, DataInit, Dispatch, DisplayHandle, GlobalDispatch, New, Resource, WEnum,
    backend::GlobalId,
};

use super::{RuntimeState, WaylandFrontend};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct OutputPowerRequest {
    pub(crate) output: OutputId,
    pub(crate) powered: bool,
}

#[derive(Debug)]
pub(super) struct OutputPowerManager {
    _global: GlobalId,
    controllers: HashMap<OutputId, ZwlrOutputPowerV1>,
    pending: BTreeMap<OutputId, bool>,
}

impl OutputPowerManager {
    pub(super) fn new(display: &DisplayHandle) -> Self {
        Self {
            _global: display.create_global::<RuntimeState, ZwlrOutputPowerManagerV1, _>(1, ()),
            controllers: HashMap::new(),
            pending: BTreeMap::new(),
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub(super) struct OutputPowerUserData {
    output: Option<OutputId>,
}

impl WaylandFrontend {
    fn output_id_for_resource(
        &self,
        resource: &smithay::reexports::wayland_server::protocol::wl_output::WlOutput,
    ) -> Option<OutputId> {
        let output = Output::from_resource(resource)?;
        self.outputs
            .iter()
            .find(|entry| entry.output == output)
            .map(|entry| entry.id)
    }

    fn register_output_power(&mut self, output: Option<OutputId>, resource: ZwlrOutputPowerV1) {
        let Some(output) = output else {
            resource.failed();
            return;
        };
        let Some(powered) = self
            .outputs
            .iter()
            .find(|entry| entry.id == output)
            .map(|entry| entry.powered)
        else {
            resource.failed();
            return;
        };
        if self.output_power.controllers.contains_key(&output) {
            resource.failed();
            return;
        }

        resource.mode(if powered {
            zwlr_output_power_v1::Mode::On
        } else {
            zwlr_output_power_v1::Mode::Off
        });
        self.output_power.controllers.insert(output, resource);
    }

    fn unregister_output_power(&mut self, output: OutputId, resource: &ZwlrOutputPowerV1) {
        let owns_control = self
            .output_power
            .controllers
            .get(&output)
            .is_some_and(|current| current.id() == resource.id());
        if owns_control {
            self.output_power.controllers.remove(&output);
            self.output_power.pending.remove(&output);
        }
    }

    fn queue_output_power(
        &mut self,
        output: OutputId,
        resource: &ZwlrOutputPowerV1,
        powered: bool,
    ) {
        if self
            .output_power
            .controllers
            .get(&output)
            .is_some_and(|current| current.id() == resource.id())
            && self.outputs.iter().any(|entry| entry.id == output)
        {
            self.output_power.pending.insert(output, powered);
        }
    }

    pub(crate) fn take_output_power_requests(&mut self) -> Vec<OutputPowerRequest> {
        std::mem::take(&mut self.output_power.pending)
            .into_iter()
            .map(|(output, powered)| OutputPowerRequest { output, powered })
            .collect()
    }

    pub(crate) fn output_power_applied(&mut self, output: OutputId, powered: bool) {
        let Some(entry) = self.outputs.iter_mut().find(|entry| entry.id == output) else {
            return;
        };
        entry.powered = powered;
        if !powered {
            self.fail_screencopies_for_output(output);
        }
        if let Some(resource) = self.output_power.controllers.get(&output) {
            resource.mode(if powered {
                zwlr_output_power_v1::Mode::On
            } else {
                zwlr_output_power_v1::Mode::Off
            });
        }
    }

    pub(crate) fn fail_output_power(&mut self, output: OutputId) {
        self.output_power.pending.remove(&output);
        if let Some(resource) = self.output_power.controllers.remove(&output) {
            resource.failed();
        }
    }
}

impl GlobalDispatch<ZwlrOutputPowerManagerV1, ()> for RuntimeState {
    fn bind(
        _state: &mut Self,
        _handle: &DisplayHandle,
        _client: &Client,
        resource: New<ZwlrOutputPowerManagerV1>,
        _global_data: &(),
        data_init: &mut DataInit<'_, Self>,
    ) {
        data_init.init(resource, ());
    }
}

impl Dispatch<ZwlrOutputPowerManagerV1, ()> for RuntimeState {
    fn request(
        state: &mut Self,
        _client: &Client,
        _resource: &ZwlrOutputPowerManagerV1,
        request: zwlr_output_power_manager_v1::Request,
        _data: &(),
        _handle: &DisplayHandle,
        data_init: &mut DataInit<'_, Self>,
    ) {
        match request {
            zwlr_output_power_manager_v1::Request::GetOutputPower { id, output } => {
                let output = state
                    .wayland
                    .as_ref()
                    .and_then(|frontend| frontend.output_id_for_resource(&output));
                let resource = data_init.init(id, OutputPowerUserData { output });
                if let Some(frontend) = state.wayland.as_mut() {
                    frontend.register_output_power(output, resource);
                } else {
                    resource.failed();
                }
            }
            zwlr_output_power_manager_v1::Request::Destroy => {}
            _ => unreachable!(),
        }
    }
}

impl Dispatch<ZwlrOutputPowerV1, OutputPowerUserData> for RuntimeState {
    fn request(
        state: &mut Self,
        _client: &Client,
        resource: &ZwlrOutputPowerV1,
        request: zwlr_output_power_v1::Request,
        data: &OutputPowerUserData,
        _handle: &DisplayHandle,
        _data_init: &mut DataInit<'_, Self>,
    ) {
        match request {
            zwlr_output_power_v1::Request::SetMode {
                mode: WEnum::Value(mode),
            } => {
                let Some(output) = data.output else {
                    return;
                };
                let powered = match mode {
                    zwlr_output_power_v1::Mode::Off => false,
                    zwlr_output_power_v1::Mode::On => true,
                    _ => unreachable!(),
                };
                if let Some(frontend) = state.wayland.as_mut() {
                    frontend.queue_output_power(output, resource, powered);
                }
            }
            zwlr_output_power_v1::Request::SetMode {
                mode: WEnum::Unknown(mode),
            } => resource.post_error(
                zwlr_output_power_v1::Error::InvalidMode,
                format!("invalid output power mode {mode}"),
            ),
            zwlr_output_power_v1::Request::Destroy => {}
            _ => unreachable!(),
        }
    }

    fn destroyed(
        state: &mut Self,
        _client: smithay::reexports::wayland_server::backend::ClientId,
        resource: &ZwlrOutputPowerV1,
        data: &OutputPowerUserData,
    ) {
        if let Some(output) = data.output
            && let Some(frontend) = state.wayland.as_mut()
        {
            frontend.unregister_output_power(output, resource);
        }
    }
}
