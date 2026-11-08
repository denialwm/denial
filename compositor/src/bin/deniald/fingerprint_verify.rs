//! Fingerprint verification for clients (`protocol/denial-fingerprint-verify-v1.xml`).
//!
//! A client such as Droidloom's device broker asks for a fingerprint the way
//! an Android app asks for its biometric prompt. The authentication worker
//! serves the newest request while the session is unlocked and the shell
//! marks the sensor, exactly as on the lock screen. A match answers only the
//! asking client; it never unlocks anything.

use std::collections::HashMap;

use smithay::reexports::wayland_server::{
    Client, DataInit, Dispatch, DisplayHandle, GlobalDispatch, New,
};
use tracing::info;

use super::RuntimeState;
use super::authentication::{AppFingerprintEvent, AppFingerprintResult};

pub mod protocol {
    pub mod server {
        #![allow(
            dead_code,
            non_camel_case_types,
            non_upper_case_globals,
            non_snake_case,
            unused_imports,
            unused_unsafe,
            unused_variables,
            clippy::all,
            missing_docs
        )]
        use wayland_server;
        use wayland_server::protocol::*;
        pub mod __interfaces {
            use wayland_server::backend as wayland_backend;
            use wayland_server::protocol::__interfaces::*;
            wayland_scanner::generate_interfaces!("protocol/denial-fingerprint-verify-v1.xml");
        }
        use self::__interfaces::*;
        wayland_scanner::generate_server_code!("protocol/denial-fingerprint-verify-v1.xml");
    }
}

use protocol::server::denial_fingerprint_verification_v1::{
    self as verification, DenialFingerprintVerificationV1,
};
use protocol::server::denial_fingerprint_verifier_v1::{
    self as verifier, DenialFingerprintVerifierV1,
};

/// Pending verifications by authentication request.
#[derive(Default)]
pub(super) struct Verifications {
    pending: HashMap<u64, DenialFingerprintVerificationV1>,
}

pub(super) fn init(display: &DisplayHandle) {
    display.create_global::<RuntimeState, DenialFingerprintVerifierV1, _>(1, ());
}

impl GlobalDispatch<DenialFingerprintVerifierV1, ()> for RuntimeState {
    fn can_view(client: Client, _data: &()) -> bool {
        super::wayland_frontend::is_session_user_client(&client)
    }

    fn bind(
        _state: &mut Self,
        _handle: &DisplayHandle,
        _client: &Client,
        resource: New<DenialFingerprintVerifierV1>,
        _data: &(),
        init: &mut DataInit<'_, Self>,
    ) {
        init.init(resource, ());
    }
}

impl Dispatch<DenialFingerprintVerifierV1, ()> for RuntimeState {
    fn request(
        state: &mut Self,
        _client: &Client,
        _resource: &DenialFingerprintVerifierV1,
        request: verifier::Request,
        _data: &(),
        _handle: &DisplayHandle,
        init: &mut DataInit<'_, Self>,
    ) {
        match request {
            verifier::Request::Verify { id } => {
                let Some(authentication) = state.authentication.clone() else {
                    let resource = init.init(id, 0);
                    resource.done(verification::Outcome::Unavailable);
                    return;
                };
                let request = authentication.request_fingerprint();
                let resource = init.init(id, request);
                info!(request, "client fingerprint verification requested");
                state
                    .fingerprint_verifications
                    .pending
                    .insert(request, resource);
            }
            verifier::Request::Destroy => {}
        }
    }
}

impl Dispatch<DenialFingerprintVerificationV1, u64> for RuntimeState {
    fn request(
        state: &mut Self,
        _client: &Client,
        _resource: &DenialFingerprintVerificationV1,
        request: verification::Request,
        data: &u64,
        _handle: &DisplayHandle,
        _init: &mut DataInit<'_, Self>,
    ) {
        match request {
            verification::Request::Destroy => end(state, *data),
        }
    }

    fn destroyed(
        state: &mut Self,
        _client: smithay::reexports::wayland_server::backend::ClientId,
        _resource: &DenialFingerprintVerificationV1,
        data: &u64,
    ) {
        end(state, *data);
    }
}

fn end(state: &mut RuntimeState, request: u64) {
    if state
        .fingerprint_verifications
        .pending
        .remove(&request)
        .is_some()
        && let Some(authentication) = &state.authentication
    {
        authentication.end_fingerprint_request(request);
    }
}

/// Delivers what the reader reported since the last loop iteration.
pub(super) fn service(state: &mut RuntimeState) {
    let Some(authentication) = &state.authentication else {
        return;
    };
    for (request, event) in authentication.take_fingerprint_events() {
        let pending = &mut state.fingerprint_verifications.pending;
        let Some(resource) = pending.get(&request) else {
            continue;
        };
        match event {
            AppFingerprintEvent::Ready => resource.ready(),
            AppFingerprintEvent::Rejected => resource.rejected(),
            AppFingerprintEvent::Done(result) => {
                resource.done(match result {
                    AppFingerprintResult::Match => verification::Outcome::Match,
                    AppFingerprintResult::Unavailable => verification::Outcome::Unavailable,
                    AppFingerprintResult::Cancelled => verification::Outcome::Cancelled,
                });
                pending.remove(&request);
            }
        }
    }
}
