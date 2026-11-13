//! The PIN or password sheet for clients (`protocol/denial-user-verify-v1.xml`).
//!
//! A client such as Droidloom's device broker asks for the screen lock the
//! way an Android app does. The shell draws the sheet and sends what the
//! user typed back here; it goes to the asking client alone, which checks it
//! and answers. Nothing here judges a credential or unlocks anything.
//!
//! A client that also verifies a fingerprint for the prompt gets the sheet
//! folded behind a button to the PIN or password. When the user takes it,
//! the client hears `opened` and stops its fingerprint verification; when
//! that verification ends without a match, the sheet opens by itself.
//!
//! The shell's channel carries little-endian records. To the shell:
//! `1 id:u32 pin_length:u8 password:u8 fingerprint:u8 (len:u16 utf8){app,
//! title, description}` shows a sheet, `2 id:u32 retry_ms:u32` asks again,
//! `3 id:u32 accepted:u8` closes it, `4 id:u32` opens a folded sheet. From
//! the shell: `1 id:u32 kind:u8 secret...` is what the user typed, `2
//! id:u32` the user closed the sheet, `3` the shell started and wants the
//! sheet showing, if any, `4 id:u32` the user opened a folded sheet.

use std::collections::VecDeque;
use std::ffi::CStr;

use smithay::reexports::wayland_server::backend::ClientId;
use smithay::reexports::wayland_server::{
    Client, DataInit, Dispatch, DisplayHandle, GlobalDispatch, New, Resource,
};
use tracing::{info, warn};

use super::RuntimeState;

pub(super) const CHANNEL: &CStr = c"denial/user_verification";

const SHOW: u8 = 1;
const REJECTED: u8 = 2;
const CLOSE: u8 = 3;
const OPEN: u8 = 4;
/// Where the show record keeps whether the sheet waits for a fingerprint.
const FOLDED_AT: usize = 7;
const CREDENTIAL: u8 = 1;
const CANCEL: u8 = 2;
const SYNC: u8 = 3;
const OPENED: u8 = 4;
const PIN: u8 = 1;
const PASSWORD: u8 = 2;
/// Bounds every text the client sends, so a record stays small.
const MAX_TEXT: usize = 512;
const MAX_SECRET: usize = 1024;
const MAX_PENDING: usize = 16;

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
            wayland_scanner::generate_interfaces!("protocol/denial-user-verify-v1.xml");
        }
        use self::__interfaces::*;
        wayland_scanner::generate_server_code!("protocol/denial-user-verify-v1.xml");
    }
}

use protocol::server::denial_user_verification_v1::{
    self as verification, DenialUserVerificationV1,
};
use protocol::server::denial_user_verifier_v1::{
    self as verifier, Credential, DenialUserVerifierV1,
};

/// The sheet showing: its request, the client's object and the record that
/// shows it again to a restarted shell.
struct Sheet {
    id: u32,
    resource: DenialUserVerificationV1,
    show: Vec<u8>,
}

/// The sheet showing, and the records for the shell.
#[derive(Default)]
pub(super) struct Verifications {
    current: Option<Sheet>,
    next: u32,
    outgoing: VecDeque<Vec<u8>>,
}

impl Verifications {
    fn send(&mut self, record: Vec<u8>) {
        if self.outgoing.len() < MAX_PENDING {
            self.outgoing.push_back(record);
        } else {
            warn!("dropped a user verification record for the shell");
        }
    }

    fn is_current(&self, id: u32) -> bool {
        self.current.as_ref().is_some_and(|sheet| sheet.id == id)
    }

    fn close(&mut self, id: u32, accepted: bool) {
        if self.is_current(id) {
            self.current = None;
            let mut record = vec![CLOSE];
            record.extend_from_slice(&id.to_le_bytes());
            record.push(u8::from(accepted));
            self.send(record);
        }
    }

    /// A fingerprint verification of `client` ended without a match: its
    /// folded sheet opens on the PIN or password.
    pub(super) fn fingerprint_ended(&mut self, client: &ClientId) {
        let Some(sheet) = self.current.as_mut() else {
            return;
        };
        if sheet.show[FOLDED_AT] == 0
            || sheet.resource.client().map(|c| c.id()) != Some(client.clone())
        {
            return;
        }
        sheet.show[FOLDED_AT] = 0;
        let mut record = vec![OPEN];
        record.extend_from_slice(&sheet.id.to_le_bytes());
        self.send(record);
    }
}

fn text(record: &mut Vec<u8>, value: &str) {
    let mut end = value.len().min(MAX_TEXT);
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    record.extend_from_slice(&(end as u16).to_le_bytes());
    record.extend_from_slice(&value.as_bytes()[..end]);
}

pub(super) fn init(display: &DisplayHandle) {
    display.create_global::<RuntimeState, DenialUserVerifierV1, _>(1, ());
}

impl GlobalDispatch<DenialUserVerifierV1, ()> for RuntimeState {
    fn can_view(client: Client, _data: &()) -> bool {
        super::wayland_frontend::is_session_user_client(&client)
    }

    fn bind(
        _state: &mut Self,
        _handle: &DisplayHandle,
        _client: &Client,
        resource: New<DenialUserVerifierV1>,
        _data: &(),
        init: &mut DataInit<'_, Self>,
    ) {
        init.init(resource, ());
    }
}

impl Dispatch<DenialUserVerifierV1, ()> for RuntimeState {
    fn request(
        state: &mut Self,
        _client: &Client,
        _resource: &DenialUserVerifierV1,
        request: verifier::Request,
        _data: &(),
        _handle: &DisplayHandle,
        init: &mut DataInit<'_, Self>,
    ) {
        match request {
            verifier::Request::Verify {
                id,
                app,
                title,
                description,
                credentials,
            } => {
                let verifications = &mut state.user_verifications;
                verifications.next = verifications.next.wrapping_add(1).max(1);
                let request = verifications.next;
                let resource = init.init(id, request);
                if let Some(older) = verifications.current.take() {
                    older.resource.cancelled();
                    let mut record = vec![CLOSE];
                    record.extend_from_slice(&older.id.to_le_bytes());
                    record.push(0);
                    verifications.send(record);
                }
                let pin_length = if credentials & Credential::Pin as u32 != 0 {
                    super::authentication::configured_pin_length()
                } else {
                    0
                };
                let password = credentials & Credential::Password as u32 != 0;
                if pin_length == 0 && !password {
                    resource.cancelled();
                    return;
                }
                let mut record = vec![SHOW];
                record.extend_from_slice(&request.to_le_bytes());
                record.push(pin_length.min(u32::from(u8::MAX)) as u8);
                record.push(u8::from(password));
                record.push(u8::from(credentials & Credential::Fingerprint as u32 != 0));
                text(&mut record, &app);
                text(&mut record, &title);
                text(&mut record, &description);
                info!(
                    request,
                    pin = pin_length != 0,
                    "client user verification requested"
                );
                verifications.send(record.clone());
                verifications.current = Some(Sheet {
                    id: request,
                    resource,
                    show: record,
                });
            }
            verifier::Request::Destroy => {}
        }
    }
}

impl Dispatch<DenialUserVerificationV1, u32> for RuntimeState {
    fn request(
        state: &mut Self,
        _client: &Client,
        _resource: &DenialUserVerificationV1,
        request: verification::Request,
        data: &u32,
        _handle: &DisplayHandle,
        _init: &mut DataInit<'_, Self>,
    ) {
        let verifications = &mut state.user_verifications;
        match request {
            verification::Request::Accepted => verifications.close(*data, true),
            verification::Request::Rejected { retry_ms } => {
                if verifications.is_current(*data) {
                    let mut record = vec![REJECTED];
                    record.extend_from_slice(&data.to_le_bytes());
                    record.extend_from_slice(&retry_ms.to_le_bytes());
                    verifications.send(record);
                }
            }
            verification::Request::Destroy => verifications.close(*data, false),
        }
    }

    fn destroyed(
        state: &mut Self,
        _client: smithay::reexports::wayland_server::backend::ClientId,
        _resource: &DenialUserVerificationV1,
        data: &u32,
    ) {
        state.user_verifications.close(*data, false);
    }
}

/// One record from the shell.
fn receive(verifications: &mut Verifications, record: &[u8]) {
    let id = |record: &[u8]| {
        record
            .get(1..5)
            .map(|bytes| u32::from_le_bytes(bytes.try_into().expect("four bytes")))
    };
    match record.first() {
        Some(&SYNC) if record.len() == 1 => {
            if let Some(sheet) = &verifications.current {
                let show = sheet.show.clone();
                verifications.send(show);
            }
        }
        Some(&CANCEL) if record.len() == 5 => {
            if id(record).is_some_and(|id| verifications.is_current(id))
                && let Some(sheet) = verifications.current.take()
            {
                sheet.resource.cancelled();
            }
        }
        Some(&CREDENTIAL) if (7..=6 + MAX_SECRET).contains(&record.len()) => {
            let kind = match record[5] {
                PIN => Credential::Pin,
                PASSWORD => Credential::Password,
                _ => return,
            };
            let Some(sheet) = &verifications.current else {
                return;
            };
            if id(record) != Some(sheet.id) {
                return;
            }
            match std::str::from_utf8(&record[6..]) {
                Ok(secret) => sheet.resource.credential(kind, secret.to_owned()),
                Err(_) => warn!("rejected a credential that is not UTF-8"),
            }
        }
        Some(&OPENED) if record.len() == 5 => {
            let Some(sheet) = verifications.current.as_mut() else {
                return;
            };
            if id(record) == Some(sheet.id) && sheet.show[FOLDED_AT] != 0 {
                sheet.show[FOLDED_AT] = 0;
                sheet.resource.opened();
            }
        }
        _ => warn!("rejected a malformed user verification record from the shell"),
    }
}

/// Moves records between the shell and the clients.
pub(super) fn service(
    flutter: &mut super::flutter_runtime::FlutterRuntime,
    state: &mut RuntimeState,
) {
    for mut record in flutter.take_user_verification_records() {
        receive(&mut state.user_verifications, &record);
        super::authentication::erase_bytes(&mut record);
    }
    while let Some(record) = state.user_verifications.outgoing.pop_front() {
        if let Err(error) = flutter.send_user_verification(&record) {
            warn!(%error, "user verification record not sent to the shell");
        }
    }
}
