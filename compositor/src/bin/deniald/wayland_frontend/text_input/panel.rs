//! Optional host dismissal feedback, added for Droidloom's Android IME lifecycle.
//! No application-specific routing: the normal active text-input owns the event.
use super::*;

mod protocol {
    #![allow(
        dead_code,
        non_camel_case_types,
        non_upper_case_globals,
        non_snake_case,
        unused_imports,
        unused_unsafe,
        unused_variables,
        clippy::all
    )]
    use smithay::reexports::wayland_protocols::wp::text_input::zv3::server::*;
    use wayland_server;
    pub mod __interfaces {
        use smithay::reexports::wayland_protocols::wp::text_input::zv3::server::__interfaces::*;
        use wayland_server::backend as wayland_backend;
        wayland_scanner::generate_interfaces!("protocol/denial-text-input-panel-v1.xml");
    }
    use self::__interfaces::*;
    wayland_scanner::generate_server_code!("protocol/denial-text-input-panel-v1.xml");
}
use protocol::{
    denial_text_input_panel_manager_v1::{self as manager, DenialTextInputPanelManagerV1},
    denial_text_input_panel_v1::{self as panel, DenialTextInputPanelV1},
};

#[derive(Debug)]
pub(super) struct PanelFeedback {
    _global: GlobalId,
    resources: Vec<(DenialTextInputPanelV1, ObjectId)>,
}

impl PanelFeedback {
    pub(super) fn new(display: &DisplayHandle) -> Self {
        Self {
            _global: display.create_global::<RuntimeState, DenialTextInputPanelManagerV1, _>(1, ()),
            resources: Vec::new(),
        }
    }

    pub(super) fn dismiss(&self, text_input: &ObjectId, serial: u32) {
        for (panel, owner) in &self.resources {
            if owner == text_input {
                panel.dismissed(serial);
            }
        }
    }
}

impl GlobalDispatch<DenialTextInputPanelManagerV1, ()> for RuntimeState {
    fn bind(
        _: &mut Self,
        _: &DisplayHandle,
        _: &Client,
        resource: New<DenialTextInputPanelManagerV1>,
        _: &(),
        data: &mut DataInit<'_, Self>,
    ) {
        data.init(resource, ());
    }
}

impl Dispatch<DenialTextInputPanelManagerV1, ()> for RuntimeState {
    fn request(
        state: &mut Self,
        client: &Client,
        resource: &DenialTextInputPanelManagerV1,
        request: manager::Request,
        _: &(),
        _: &DisplayHandle,
        data: &mut DataInit<'_, Self>,
    ) {
        if let manager::Request::GetPanel { id, text_input } = request {
            let Some(frontend) = state.wayland.as_mut() else {
                return;
            };
            let manager = &mut frontend.text_input;
            let owner = text_input.id();
            if text_input
                .client()
                .is_none_or(|peer| peer.id() != client.id())
                || !manager.resources.iter().any(|input| input.id() == owner)
                || manager
                    .panels
                    .resources
                    .iter()
                    .any(|(_, input)| input == &owner)
                || manager.panels.resources.len() >= MAX_TEXT_INPUTS
            {
                resource.post_error(
                    manager::Error::InvalidTextInput,
                    "invalid or duplicate text input",
                );
                return;
            }
            manager.panels.resources.push((data.init(id, ()), owner));
        }
    }
}

impl Dispatch<DenialTextInputPanelV1, ()> for RuntimeState {
    fn request(
        _: &mut Self,
        _: &Client,
        _: &DenialTextInputPanelV1,
        _: panel::Request,
        _: &(),
        _: &DisplayHandle,
        _: &mut DataInit<'_, Self>,
    ) {
    }

    fn destroyed(state: &mut Self, _: ClientId, resource: &DenialTextInputPanelV1, _: &()) {
        if let Some(frontend) = state.wayland.as_mut() {
            frontend
                .text_input
                .panels
                .resources
                .retain(|(panel, _)| panel != resource);
        }
    }
}
