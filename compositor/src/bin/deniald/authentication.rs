//! Process-lifetime secure session lock and PAM authentication boundary.

use std::collections::VecDeque;
use std::error::Error;
use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::fmt;
use std::io;
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering, compiler_fence};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use libloading::Library;
use tracing::{info, warn};

pub(super) const CHANNEL: &CStr = c"denial/authentication";
pub(super) const STATE_CHANNEL: &CStr = c"denial/authentication_state";

const MAGIC: &[u8; 4] = b"DAUT";
const VERSION: u16 = 1;
const HEADER_SIZE: usize = 24;
const MAX_PAYLOAD_BYTES: usize = 4096;
const MAX_PACKET_BYTES: usize = HEADER_SIZE + MAX_PAYLOAD_BYTES;
const MAX_STATUS_BYTES: usize = 1024;
const MAX_PENDING_EVENTS: usize = 64;
const PROMPT_TIMEOUT: Duration = Duration::from_secs(120);
const BASE_COOLDOWN: Duration = Duration::from_millis(750);
const MAX_COOLDOWN: Duration = Duration::from_secs(30);

const KIND_SYNC: u8 = 1;
const KIND_LOCK: u8 = 2;
const KIND_BEGIN: u8 = 3;
const KIND_RESPOND: u8 = 4;
const KIND_CANCEL: u8 = 5;
const KIND_STATE: u8 = 0x81;
const KIND_PROMPT: u8 = 0x82;
const KIND_RESULT: u8 = 0x83;

const STATE_LOCKED: u8 = 1 << 0;
const STATE_AVAILABLE: u8 = 1 << 1;
const STATE_BUSY: u8 = 1 << 2;
const STATE_RATE_LIMITED: u8 = 1 << 3;
const RESULT_SUCCESS: u8 = 1 << 4;
const RESULT_CANCELLED: u8 = 1 << 5;
const PROMPT_STYLE_SHIFT: u8 = 4;

#[derive(Debug, Eq, PartialEq)]
pub(super) enum AuthenticationDecodeError {
    InvalidSize(usize),
    InvalidMagic,
    UnsupportedVersion(u16),
    UnsupportedKind(u8),
    InvalidFlags(u8),
    InvalidPayloadLength(u32),
    EmbeddedNul,
    UnexpectedMetadata,
}

impl fmt::Display for AuthenticationDecodeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidSize(size) => {
                write!(formatter, "invalid authentication packet size {size}")
            }
            Self::InvalidMagic => formatter.write_str("invalid authentication packet magic"),
            Self::UnsupportedVersion(version) => {
                write!(
                    formatter,
                    "unsupported authentication protocol version {version}"
                )
            }
            Self::UnsupportedKind(kind) => {
                write!(formatter, "unsupported authentication command {kind}")
            }
            Self::InvalidFlags(flags) => {
                write!(formatter, "authentication command has flags {flags:#x}")
            }
            Self::InvalidPayloadLength(length) => {
                write!(formatter, "invalid authentication payload length {length}")
            }
            Self::EmbeddedNul => formatter.write_str("authentication payload contains NUL"),
            Self::UnexpectedMetadata => {
                formatter.write_str("authentication command carries unexpected metadata")
            }
        }
    }
}

impl Error for AuthenticationDecodeError {}

enum AuthenticationCommand {
    Synchronize,
    Lock,
    Begin,
    Respond {
        attempt_id: u64,
        prompt_sequence: u32,
        response: SecureString,
    },
    Cancel {
        attempt_id: u64,
    },
}

fn decode(packet: &[u8]) -> Result<AuthenticationCommand, AuthenticationDecodeError> {
    if !(HEADER_SIZE..=MAX_PACKET_BYTES).contains(&packet.len()) {
        return Err(AuthenticationDecodeError::InvalidSize(packet.len()));
    }
    if &packet[..MAGIC.len()] != MAGIC {
        return Err(AuthenticationDecodeError::InvalidMagic);
    }
    let version = u16::from_le_bytes(packet[4..6].try_into().expect("fixed protocol header"));
    if version != VERSION {
        return Err(AuthenticationDecodeError::UnsupportedVersion(version));
    }
    let kind = packet[6];
    let flags = packet[7];
    if flags != 0 {
        return Err(AuthenticationDecodeError::InvalidFlags(flags));
    }
    let attempt_id = u64::from_le_bytes(packet[8..16].try_into().expect("fixed protocol header"));
    let argument = u32::from_le_bytes(packet[16..20].try_into().expect("fixed protocol header"));
    let payload_length =
        u32::from_le_bytes(packet[20..24].try_into().expect("fixed protocol header"));
    if payload_length as usize > MAX_PAYLOAD_BYTES
        || HEADER_SIZE + payload_length as usize != packet.len()
    {
        return Err(AuthenticationDecodeError::InvalidPayloadLength(
            payload_length,
        ));
    }
    let payload = &packet[HEADER_SIZE..];
    if payload.contains(&0) {
        return Err(AuthenticationDecodeError::EmbeddedNul);
    }

    match kind {
        KIND_SYNC if attempt_id == 0 && argument == 0 && payload.is_empty() => {
            Ok(AuthenticationCommand::Synchronize)
        }
        KIND_LOCK if attempt_id == 0 && argument == 0 && payload.is_empty() => {
            Ok(AuthenticationCommand::Lock)
        }
        KIND_BEGIN if attempt_id == 0 && argument == 0 && payload.is_empty() => {
            Ok(AuthenticationCommand::Begin)
        }
        KIND_RESPOND if attempt_id != 0 && argument != 0 => Ok(AuthenticationCommand::Respond {
            attempt_id,
            prompt_sequence: argument,
            response: SecureString::new(payload),
        }),
        KIND_CANCEL if argument == 0 && payload.is_empty() => {
            Ok(AuthenticationCommand::Cancel { attempt_id })
        }
        KIND_SYNC | KIND_LOCK | KIND_BEGIN | KIND_RESPOND | KIND_CANCEL => {
            Err(AuthenticationDecodeError::UnexpectedMetadata)
        }
        _ => Err(AuthenticationDecodeError::UnsupportedKind(kind)),
    }
}

struct SecureString {
    bytes: Vec<u8>,
}

impl SecureString {
    fn new(bytes: &[u8]) -> Self {
        Self {
            bytes: bytes.to_vec(),
        }
    }

    fn as_bytes(&self) -> &[u8] {
        &self.bytes
    }

    fn clear(&mut self) {
        erase_bytes(&mut self.bytes);
        self.bytes.clear();
    }
}

impl Drop for SecureString {
    fn drop(&mut self) {
        self.clear();
    }
}

fn erase_bytes(bytes: &mut [u8]) {
    for byte in bytes {
        // SAFETY: byte is a valid unique pointer into the owned secret buffer.
        unsafe { ptr::write_volatile(byte, 0) };
    }
    compiler_fence(Ordering::SeqCst);
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PromptStyle {
    EchoOff = 1,
    EchoOn = 2,
    Info = 3,
    Error = 4,
}

impl PromptStyle {
    fn requires_response(self) -> bool {
        matches!(self, Self::EchoOff | Self::EchoOn)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum BackendResult {
    Success,
    Failure,
    Cancelled,
    Error,
}

trait AuthenticationBackend: Send {
    fn available(&self) -> bool;
    fn unavailable_reason(&self) -> String;
    fn authenticate(
        &mut self,
        username: &str,
        conversation: &mut dyn FnMut(PromptStyle, &str) -> Option<SecureString>,
        cancelled: &dyn Fn() -> bool,
    ) -> BackendResult;
}

struct UnavailableBackend {
    reason: String,
}

impl AuthenticationBackend for UnavailableBackend {
    fn available(&self) -> bool {
        false
    }

    fn unavailable_reason(&self) -> String {
        self.reason.clone()
    }

    fn authenticate(
        &mut self,
        _username: &str,
        _conversation: &mut dyn FnMut(PromptStyle, &str) -> Option<SecureString>,
        _cancelled: &dyn Fn() -> bool,
    ) -> BackendResult {
        BackendResult::Error
    }
}

#[repr(C)]
struct PamHandle {
    _private: [u8; 0],
}

#[repr(C)]
struct PamMessage {
    msg_style: c_int,
    msg: *const c_char,
}

#[repr(C)]
struct PamResponse {
    resp: *mut c_char,
    resp_retcode: c_int,
}

type PamConversationCallback = unsafe extern "C" fn(
    c_int,
    *mut *const PamMessage,
    *mut *mut PamResponse,
    *mut c_void,
) -> c_int;

#[repr(C)]
struct PamConversation {
    conv: Option<PamConversationCallback>,
    appdata_ptr: *mut c_void,
}

struct PamApi {
    _library: Library,
    start: unsafe extern "C" fn(
        *const c_char,
        *const c_char,
        *const PamConversation,
        *mut *mut PamHandle,
    ) -> c_int,
    end: unsafe extern "C" fn(*mut PamHandle, c_int) -> c_int,
    authenticate: unsafe extern "C" fn(*mut PamHandle, c_int) -> c_int,
    account_management: unsafe extern "C" fn(*mut PamHandle, c_int) -> c_int,
    set_item: unsafe extern "C" fn(*mut PamHandle, c_int, *const c_void) -> c_int,
    fail_delay: unsafe extern "C" fn(*mut PamHandle, u32) -> c_int,
}

impl PamApi {
    fn load() -> Result<Self, String> {
        // SAFETY: every symbol is copied from a retained, fixed-SONAME library.
        unsafe {
            let library = Library::new("libpam.so.0")
                .map_err(|error| format!("could not load libpam.so.0: {error}"))?;
            macro_rules! symbol {
                ($name:literal) => {
                    *library
                        .get(concat!($name, "\0").as_bytes())
                        .map_err(|error| format!("missing libpam symbol {}: {error}", $name))?
                };
            }
            Ok(Self {
                start: symbol!("pam_start"),
                end: symbol!("pam_end"),
                authenticate: symbol!("pam_authenticate"),
                account_management: symbol!("pam_acct_mgmt"),
                set_item: symbol!("pam_set_item"),
                fail_delay: symbol!("pam_fail_delay"),
                _library: library,
            })
        }
    }
}

struct PamBackend {
    api: PamApi,
    service: CString,
}

impl PamBackend {
    fn load() -> Result<Self, String> {
        let service = configured_pam_service();
        Ok(Self {
            api: PamApi::load()?,
            service: CString::new(service).expect("validated PAM service contains no NUL"),
        })
    }
}

const PAM_SUCCESS: c_int = 0;
const PAM_BUF_ERR: c_int = 5;
const PAM_AUTH_ERR: c_int = 7;
const PAM_CRED_INSUFFICIENT: c_int = 8;
const PAM_AUTHINFO_UNAVAIL: c_int = 9;
const PAM_USER_UNKNOWN: c_int = 10;
const PAM_MAXTRIES: c_int = 11;
const PAM_CONV_ERR: c_int = 19;
const PAM_PROMPT_ECHO_OFF: c_int = 1;
const PAM_PROMPT_ECHO_ON: c_int = 2;
const PAM_ERROR_MSG: c_int = 3;
const PAM_TEXT_INFO: c_int = 4;
const PAM_TTY: c_int = 3;
const PAM_SILENT: c_int = 0x8000;
const PAM_DISALLOW_NULL_AUTHTOK: c_int = 0x0001;
const PAM_MAX_NUM_MSG: c_int = 32;

struct PamConversationContext<'a> {
    conversation: &'a mut dyn FnMut(PromptStyle, &str) -> Option<SecureString>,
    cancelled: &'a dyn Fn() -> bool,
}

unsafe extern "C" fn pam_conversation(
    count: c_int,
    messages: *mut *const PamMessage,
    output: *mut *mut PamResponse,
    userdata: *mut c_void,
) -> c_int {
    if userdata.is_null()
        || output.is_null()
        || messages.is_null()
        || count <= 0
        || count > PAM_MAX_NUM_MSG
    {
        return PAM_CONV_ERR;
    }
    // SAFETY: PamBackend keeps the stack context alive for the full PAM call.
    let context = unsafe { &mut *userdata.cast::<PamConversationContext<'_>>() };
    if (context.cancelled)() {
        return PAM_CONV_ERR;
    }
    let count = count as usize;
    // SAFETY: calloc receives a checked small count and the complete response size.
    let responses = unsafe { libc::calloc(count, size_of::<PamResponse>()) }.cast::<PamResponse>();
    if responses.is_null() {
        return PAM_BUF_ERR;
    }

    for index in 0..count {
        if (context.cancelled)() {
            // SAFETY: responses contains exactly count initialized zeroed entries.
            unsafe { clear_pam_responses(responses, count) };
            return PAM_CONV_ERR;
        }
        // SAFETY: PAM supplied count message pointers for callback life.
        let message = unsafe { *messages.add(index) };
        if message.is_null() {
            // SAFETY: responses contains exactly count initialized zeroed entries.
            unsafe { clear_pam_responses(responses, count) };
            return PAM_CONV_ERR;
        }
        // SAFETY: message is non-null and points to the active PAM record.
        let message = unsafe { &*message };
        let style = match message.msg_style {
            PAM_PROMPT_ECHO_OFF => PromptStyle::EchoOff,
            PAM_PROMPT_ECHO_ON => PromptStyle::EchoOn,
            PAM_TEXT_INFO => PromptStyle::Info,
            PAM_ERROR_MSG => PromptStyle::Error,
            _ => {
                // SAFETY: responses contains exactly count initialized entries.
                unsafe { clear_pam_responses(responses, count) };
                return PAM_CONV_ERR;
            }
        };
        let text = if message.msg.is_null() {
            String::new()
        } else {
            // SAFETY: PAM messages are NUL-terminated for callback life.
            unsafe { CStr::from_ptr(message.msg) }
                .to_string_lossy()
                .into_owned()
        };
        let Some(mut response) = (context.conversation)(style, &text) else {
            // SAFETY: responses contains exactly count initialized entries.
            unsafe { clear_pam_responses(responses, count) };
            return PAM_CONV_ERR;
        };
        if !style.requires_response() {
            continue;
        }
        let length = response.as_bytes().len();
        // SAFETY: the extra terminator byte is checked by the protocol's 4 KiB bound.
        let destination = unsafe { libc::calloc(length + 1, 1) }.cast::<u8>();
        if destination.is_null() {
            response.clear();
            // SAFETY: responses contains exactly count initialized entries.
            unsafe { clear_pam_responses(responses, count) };
            return PAM_BUF_ERR;
        }
        // SAFETY: destination has length + 1 bytes and response has length bytes.
        unsafe {
            ptr::copy_nonoverlapping(response.as_bytes().as_ptr(), destination, length);
            (*responses.add(index)).resp = destination.cast();
        }
        response.clear();
    }

    // SAFETY: output is a valid PAM-owned out pointer for this callback.
    unsafe { *output = responses };
    PAM_SUCCESS
}

unsafe fn clear_pam_responses(responses: *mut PamResponse, count: usize) {
    if responses.is_null() {
        return;
    }
    for index in 0..count {
        // SAFETY: caller guarantees a count-entry response allocation.
        let response = unsafe { &mut *responses.add(index) };
        if !response.resp.is_null() {
            // SAFETY: response strings were allocated by this callback and are terminated.
            let length = unsafe { CStr::from_ptr(response.resp) }.to_bytes().len();
            // SAFETY: the allocation has at least length bytes before its terminator.
            let bytes =
                unsafe { std::slice::from_raw_parts_mut(response.resp.cast::<u8>(), length) };
            erase_bytes(bytes);
            // SAFETY: response was allocated by calloc and has not been freed.
            unsafe { libc::free(response.resp.cast()) };
            response.resp = ptr::null_mut();
        }
    }
    // SAFETY: scrub the complete response array before returning it to libc.
    let bytes = unsafe {
        std::slice::from_raw_parts_mut(
            responses.cast::<u8>(),
            count.saturating_mul(size_of::<PamResponse>()),
        )
    };
    erase_bytes(bytes);
    // SAFETY: responses was allocated by calloc and has not been freed.
    unsafe { libc::free(responses.cast()) };
}

impl AuthenticationBackend for PamBackend {
    fn available(&self) -> bool {
        true
    }

    fn unavailable_reason(&self) -> String {
        String::new()
    }

    fn authenticate(
        &mut self,
        username: &str,
        conversation: &mut dyn FnMut(PromptStyle, &str) -> Option<SecureString>,
        cancelled: &dyn Fn() -> bool,
    ) -> BackendResult {
        let Ok(username) = CString::new(username) else {
            return BackendResult::Error;
        };
        let mut context = PamConversationContext {
            conversation,
            cancelled,
        };
        let adapter = PamConversation {
            conv: Some(pam_conversation),
            appdata_ptr: (&mut context as *mut PamConversationContext<'_>).cast(),
        };
        let mut handle = ptr::null_mut();
        // SAFETY: service, username, adapter and handle out-pointer remain live for pam_start.
        let mut result = unsafe {
            (self.api.start)(
                self.service.as_ptr(),
                username.as_ptr(),
                &adapter,
                &mut handle,
            )
        };
        if result != PAM_SUCCESS || handle.is_null() {
            return if cancelled() {
                BackendResult::Cancelled
            } else {
                BackendResult::Error
            };
        }

        // SAFETY: handle is live until the balanced pam_end below.
        unsafe {
            (self.api.fail_delay)(handle, 0);
            (self.api.set_item)(handle, PAM_TTY, c"denial".as_ptr().cast());
            result = (self.api.authenticate)(handle, PAM_DISALLOW_NULL_AUTHTOK);
            if result == PAM_SUCCESS {
                result = (self.api.account_management)(handle, PAM_SILENT);
            }
        }
        let was_cancelled = cancelled();
        // SAFETY: balances the successful pam_start exactly once.
        unsafe { (self.api.end)(handle, result) };

        if was_cancelled {
            BackendResult::Cancelled
        } else if result == PAM_SUCCESS {
            BackendResult::Success
        } else if matches!(
            result,
            PAM_AUTH_ERR
                | PAM_USER_UNKNOWN
                | PAM_MAXTRIES
                | PAM_CRED_INSUFFICIENT
                | PAM_AUTHINFO_UNAVAIL
        ) {
            BackendResult::Failure
        } else {
            BackendResult::Error
        }
    }
}

fn configured_pam_service() -> String {
    let Some(candidate) = std::env::var_os("DENIAL_PAM_SERVICE") else {
        return "login".into();
    };
    let candidate = candidate.to_string_lossy();
    if !candidate.is_empty()
        && candidate.len() <= 64
        && candidate
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        candidate.into_owned()
    } else {
        warn!("ignored invalid DENIAL_PAM_SERVICE value");
        "login".into()
    }
}

fn default_backend() -> Box<dyn AuthenticationBackend> {
    match PamBackend::load() {
        Ok(backend) => {
            info!("Denial native authentication connected through PAM");
            Box::new(backend)
        }
        Err(error) => {
            warn!(%error, "native PAM authentication is unavailable");
            Box::new(UnavailableBackend {
                reason: "System authentication is unavailable on this build.".into(),
            })
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct AuthenticationSnapshot {
    locked: bool,
    available: bool,
    busy: bool,
    attempt_id: u64,
    cooldown_ms: u32,
    status_message: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum AuthenticationEventKind {
    State,
    Prompt { style: PromptStyle, sequence: u32 },
    Result { success: bool, cancelled: bool },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct AuthenticationEvent {
    kind: AuthenticationEventKind,
    state: AuthenticationSnapshot,
    message: String,
}

impl AuthenticationEvent {
    pub(super) fn encode(&self) -> Vec<u8> {
        let mut flags = 0u8;
        if self.state.locked {
            flags |= STATE_LOCKED;
        }
        if self.state.available {
            flags |= STATE_AVAILABLE;
        }
        if self.state.busy {
            flags |= STATE_BUSY;
        }
        if self.state.cooldown_ms > 0 {
            flags |= STATE_RATE_LIMITED;
        }
        let (kind, argument, payload) = match self.kind {
            AuthenticationEventKind::State => (
                KIND_STATE,
                self.state.cooldown_ms,
                self.state.status_message.as_str(),
            ),
            AuthenticationEventKind::Prompt { style, sequence } => {
                flags |= (style as u8) << PROMPT_STYLE_SHIFT;
                (KIND_PROMPT, sequence, self.message.as_str())
            }
            AuthenticationEventKind::Result { success, cancelled } => {
                if success {
                    flags |= RESULT_SUCCESS;
                }
                if cancelled {
                    flags |= RESULT_CANCELLED;
                }
                (KIND_RESULT, self.state.cooldown_ms, self.message.as_str())
            }
        };
        let payload = payload.as_bytes();
        debug_assert!(payload.len() <= MAX_PAYLOAD_BYTES && !payload.contains(&0));
        let mut packet = vec![0u8; HEADER_SIZE + payload.len()];
        packet[..4].copy_from_slice(MAGIC);
        packet[4..6].copy_from_slice(&VERSION.to_le_bytes());
        packet[6] = kind;
        packet[7] = flags;
        packet[8..16].copy_from_slice(&self.state.attempt_id.to_le_bytes());
        packet[16..20].copy_from_slice(&argument.to_le_bytes());
        packet[20..24].copy_from_slice(&(payload.len() as u32).to_le_bytes());
        packet[HEADER_SIZE..].copy_from_slice(payload);
        packet
    }
}

struct PromptState {
    style: PromptStyle,
    sequence: u32,
    message: String,
    requires_response: bool,
}

#[derive(Clone, Copy)]
struct WorkItem {
    attempt_id: u64,
    generation: u64,
}

struct AuthenticationState {
    stopping: bool,
    busy: bool,
    cancel_requested: bool,
    generation: u64,
    next_attempt_id: u64,
    active_attempt_id: u64,
    next_prompt_sequence: u32,
    failure_count: u32,
    cooldown_until: Option<Instant>,
    pending_work: Option<WorkItem>,
    prompt: Option<PromptState>,
    response: Option<SecureString>,
    available: bool,
    unavailable_reason: String,
}

struct SharedAuthentication {
    locked: AtomicBool,
    security_gate_locked: AtomicBool,
    events_pending: AtomicBool,
    state: Mutex<AuthenticationState>,
    condition: Condvar,
    events: Mutex<VecDeque<AuthenticationEvent>>,
}

impl SharedAuthentication {
    fn push_event(&self, event: AuthenticationEvent) {
        let mut events = lock_unpoisoned(&self.events);
        if events.len() == MAX_PENDING_EVENTS {
            events.pop_front();
        }
        events.push_back(event);
        self.events_pending.store(true, Ordering::Release);
    }
}

pub(super) struct AuthenticationController {
    shared: Arc<SharedAuthentication>,
    worker: Mutex<Option<JoinHandle<()>>>,
}

impl AuthenticationController {
    pub(super) fn new(start_locked: bool) -> io::Result<Self> {
        Self::with_backend(default_backend(), start_locked)
    }

    fn with_backend(
        mut backend: Box<dyn AuthenticationBackend>,
        start_locked: bool,
    ) -> io::Result<Self> {
        let available = backend.available();
        let unavailable_reason = backend.unavailable_reason();
        let shared = Arc::new(SharedAuthentication {
            locked: AtomicBool::new(start_locked),
            security_gate_locked: AtomicBool::new(start_locked),
            events_pending: AtomicBool::new(false),
            state: Mutex::new(AuthenticationState {
                stopping: false,
                busy: false,
                cancel_requested: false,
                generation: 0,
                next_attempt_id: 1,
                active_attempt_id: 0,
                next_prompt_sequence: 1,
                failure_count: 0,
                cooldown_until: None,
                pending_work: None,
                prompt: None,
                response: None,
                available,
                unavailable_reason,
            }),
            condition: Condvar::new(),
            events: Mutex::new(VecDeque::with_capacity(16)),
        });
        let worker_shared = Arc::clone(&shared);
        let username = current_username();
        let worker = thread::Builder::new()
            .name("denial-authentication".into())
            .spawn(move || {
                crate::cpu_scheduling::normalize_current_worker("authentication");
                run_authentication_worker(&worker_shared, &mut *backend, &username);
            })?;
        Ok(Self {
            shared,
            worker: Mutex::new(Some(worker)),
        })
    }

    pub(super) fn locked(&self) -> bool {
        self.shared.locked.load(Ordering::Acquire)
    }

    pub(super) fn security_gate_locked(&self) -> bool {
        self.locked() || self.shared.security_gate_locked.load(Ordering::Acquire)
    }

    pub(super) fn acknowledge_unlocked_boundary(&self) {
        // Authentication success is produced by the worker, but the main
        // compositor loop must first balance client input and cancel grabs.
        // Keep privileged platform commands closed until that boundary has
        // been applied. A concurrent lock stores `locked` before setting this
        // gate, so the recheck cannot leave an actively locked session open.
        self.shared
            .security_gate_locked
            .store(false, Ordering::Release);
        if self.locked() {
            self.shared
                .security_gate_locked
                .store(true, Ordering::Release);
        }
    }

    pub(super) fn handle_packet(&self, packet: &[u8]) -> Result<(), AuthenticationDecodeError> {
        match decode(packet)? {
            AuthenticationCommand::Synchronize => self.synchronize(),
            AuthenticationCommand::Lock => self.lock(),
            AuthenticationCommand::Begin => self.begin(),
            AuthenticationCommand::Respond {
                attempt_id,
                prompt_sequence,
                response,
            } => {
                self.respond(attempt_id, prompt_sequence, response);
            }
            AuthenticationCommand::Cancel { attempt_id } => self.cancel(attempt_id),
        }
        Ok(())
    }

    pub(super) fn lock(&self) {
        {
            let mut state = lock_unpoisoned(&self.shared.state);
            self.shared.locked.store(true, Ordering::Release);
            self.shared
                .security_gate_locked
                .store(true, Ordering::Release);
            if state.busy {
                state.generation = state.generation.wrapping_add(1);
                state.cancel_requested = true;
                state.response = None;
                state.prompt = None;
            }
        }
        self.shared.condition.notify_all();
        self.publish_state();
    }

    pub(super) fn try_event(&self) -> Option<AuthenticationEvent> {
        let mut events = lock_unpoisoned(&self.shared.events);
        let event = events.pop_front();
        if events.is_empty() {
            self.shared.events_pending.store(false, Ordering::Release);
        }
        event
    }

    pub(super) fn has_pending_events(&self) -> bool {
        self.shared.events_pending.load(Ordering::Acquire)
    }

    fn synchronize(&self) {
        let (state_event, prompt_event) = {
            let state = lock_unpoisoned(&self.shared.state);
            let snapshot = snapshot_locked(&self.shared, &state, Instant::now());
            let prompt = state.prompt.as_ref().map(|prompt| AuthenticationEvent {
                kind: AuthenticationEventKind::Prompt {
                    style: prompt.style,
                    sequence: prompt.sequence,
                },
                state: snapshot.clone(),
                message: prompt.message.clone(),
            });
            (
                AuthenticationEvent {
                    kind: AuthenticationEventKind::State,
                    state: snapshot,
                    message: String::new(),
                },
                prompt,
            )
        };
        self.shared.push_event(state_event);
        if let Some(prompt) = prompt_event {
            self.shared.push_event(prompt);
        }
    }

    fn begin(&self) {
        let immediate = {
            let mut state = lock_unpoisoned(&self.shared.state);
            let now = Instant::now();
            if !self.locked() || state.busy {
                return;
            }
            if !state.available {
                Some(AuthenticationEvent {
                    kind: AuthenticationEventKind::Result {
                        success: false,
                        cancelled: false,
                    },
                    state: snapshot_locked(&self.shared, &state, now),
                    message: state.unavailable_reason.clone(),
                })
            } else if state.cooldown_until.is_some_and(|until| until > now) {
                Some(AuthenticationEvent {
                    kind: AuthenticationEventKind::Result {
                        success: false,
                        cancelled: false,
                    },
                    state: snapshot_locked(&self.shared, &state, now),
                    message: "Please wait before trying again.".into(),
                })
            } else {
                state.generation = state.generation.wrapping_add(1);
                state.active_attempt_id = state.next_attempt_id;
                state.next_attempt_id = state.next_attempt_id.wrapping_add(1).max(1);
                state.busy = true;
                state.cancel_requested = false;
                state.prompt = None;
                state.response = None;
                state.pending_work = Some(WorkItem {
                    attempt_id: state.active_attempt_id,
                    generation: state.generation,
                });
                None
            }
        };
        if let Some(event) = immediate {
            self.shared.push_event(event);
            self.publish_state();
            return;
        }
        self.shared.condition.notify_all();
        self.publish_state();
    }

    fn respond(&self, attempt_id: u64, prompt_sequence: u32, response: SecureString) -> bool {
        {
            let mut state = lock_unpoisoned(&self.shared.state);
            let valid = state.busy
                && !state.cancel_requested
                && attempt_id != 0
                && attempt_id == state.active_attempt_id
                && prompt_sequence != 0
                && state.prompt.as_ref().is_some_and(|prompt| {
                    prompt.requires_response && prompt.sequence == prompt_sequence
                })
                && state.response.is_none();
            if !valid {
                return false;
            }
            state.response = Some(response);
        }
        self.shared.condition.notify_all();
        true
    }

    fn cancel(&self, attempt_id: u64) {
        {
            let mut state = lock_unpoisoned(&self.shared.state);
            if !state.busy || (attempt_id != 0 && attempt_id != state.active_attempt_id) {
                return;
            }
            state.generation = state.generation.wrapping_add(1);
            state.cancel_requested = true;
            state.response = None;
            state.prompt = None;
        }
        self.shared.condition.notify_all();
        self.publish_state();
    }

    fn publish_state(&self) {
        let state = lock_unpoisoned(&self.shared.state);
        self.shared.push_event(AuthenticationEvent {
            kind: AuthenticationEventKind::State,
            state: snapshot_locked(&self.shared, &state, Instant::now()),
            message: String::new(),
        });
    }
}

impl Drop for AuthenticationController {
    fn drop(&mut self) {
        {
            let mut state = lock_unpoisoned(&self.shared.state);
            state.stopping = true;
            state.generation = state.generation.wrapping_add(1);
            state.cancel_requested = true;
            state.response = None;
            state.prompt = None;
        }
        self.shared.condition.notify_all();
        if lock_unpoisoned(&self.worker)
            .take()
            .is_some_and(|worker| worker.join().is_err())
        {
            warn!("native authentication worker panicked during shutdown");
        }
    }
}

fn lock_unpoisoned<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

fn snapshot_locked(
    shared: &SharedAuthentication,
    state: &AuthenticationState,
    now: Instant,
) -> AuthenticationSnapshot {
    let cooldown_ms = state
        .cooldown_until
        .and_then(|until| until.checked_duration_since(now))
        .map(|remaining| {
            u32::try_from(remaining.as_millis())
                .unwrap_or(u32::MAX)
                .max(1)
        })
        .unwrap_or(0);
    let status_message = if !state.available {
        state.unavailable_reason.clone()
    } else if state.cancel_requested && state.busy {
        "Cancelling authentication…".into()
    } else {
        String::new()
    };
    AuthenticationSnapshot {
        locked: shared.locked.load(Ordering::Acquire),
        available: state.available,
        busy: state.busy,
        attempt_id: state.active_attempt_id,
        cooldown_ms,
        status_message,
    }
}

fn run_authentication_worker(
    shared: &Arc<SharedAuthentication>,
    backend: &mut dyn AuthenticationBackend,
    username: &str,
) {
    loop {
        let work = {
            let mut state = lock_unpoisoned(&shared.state);
            while !state.stopping && state.pending_work.is_none() {
                state = match shared.condition.wait(state) {
                    Ok(state) => state,
                    Err(poisoned) => poisoned.into_inner(),
                };
            }
            if state.stopping {
                return;
            }
            state
                .pending_work
                .take()
                .expect("authentication wakeup had pending work")
        };

        let conversation_shared = Arc::clone(shared);
        let mut conversation = move |style: PromptStyle, message: &str| {
            converse(&conversation_shared, work, style, message)
        };
        let cancellation_shared = Arc::clone(shared);
        let cancelled = move || authentication_cancelled(&cancellation_shared, work.generation);
        let result = backend.authenticate(username, &mut conversation, &cancelled);

        let event = {
            let mut state = lock_unpoisoned(&shared.state);
            let current = !state.stopping
                && work.attempt_id == state.active_attempt_id
                && work.generation == state.generation
                && !state.cancel_requested;
            let success = current && result == BackendResult::Success;
            let was_cancelled = !current || result == BackendResult::Cancelled;
            state.busy = false;
            state.cancel_requested = false;
            state.prompt = None;
            state.response = None;

            let message = if success {
                shared.locked.store(false, Ordering::Release);
                state.failure_count = 0;
                state.cooldown_until = None;
                "Authentication successful".into()
            } else if was_cancelled {
                "Authentication cancelled".into()
            } else {
                state.failure_count = state.failure_count.saturating_add(1);
                state.cooldown_until = Some(Instant::now() + cooldown_for(state.failure_count));
                if result == BackendResult::Failure {
                    "Authentication failed. Try again.".into()
                } else {
                    "System authentication could not complete.".into()
                }
            };
            AuthenticationEvent {
                kind: AuthenticationEventKind::Result {
                    success,
                    cancelled: was_cancelled,
                },
                state: snapshot_locked(shared, &state, Instant::now()),
                message,
            }
        };
        shared.push_event(event);
        let state = lock_unpoisoned(&shared.state);
        shared.push_event(AuthenticationEvent {
            kind: AuthenticationEventKind::State,
            state: snapshot_locked(shared, &state, Instant::now()),
            message: String::new(),
        });
    }
}

fn authentication_cancelled(shared: &SharedAuthentication, generation: u64) -> bool {
    let state = lock_unpoisoned(&shared.state);
    state.stopping || generation != state.generation || state.cancel_requested
}

fn converse(
    shared: &SharedAuthentication,
    work: WorkItem,
    style: PromptStyle,
    message: &str,
) -> Option<SecureString> {
    let requires_response = style.requires_response();
    let (sequence, event) = {
        let mut state = lock_unpoisoned(&shared.state);
        if state.stopping
            || work.generation != state.generation
            || state.cancel_requested
            || work.attempt_id != state.active_attempt_id
        {
            return None;
        }
        let sequence = state.next_prompt_sequence;
        state.next_prompt_sequence = state.next_prompt_sequence.wrapping_add(1).max(1);
        let message = sanitize_message(message);
        state.prompt = Some(PromptState {
            style,
            sequence,
            message: message.clone(),
            requires_response,
        });
        state.response = None;
        let event = AuthenticationEvent {
            kind: AuthenticationEventKind::Prompt { style, sequence },
            state: snapshot_locked(shared, &state, Instant::now()),
            message,
        };
        (sequence, event)
    };
    shared.push_event(event);
    if !requires_response {
        return Some(SecureString::new(&[]));
    }

    let state = lock_unpoisoned(&shared.state);
    let (mut state, timeout) =
        match shared
            .condition
            .wait_timeout_while(state, PROMPT_TIMEOUT, |state| {
                !state.stopping
                    && work.generation == state.generation
                    && !state.cancel_requested
                    && state.response.is_none()
            }) {
            Ok(result) => result,
            Err(poisoned) => poisoned.into_inner(),
        };
    if timeout.timed_out() && state.response.is_none() {
        state.generation = state.generation.wrapping_add(1);
        state.cancel_requested = true;
        state.prompt = None;
        return None;
    }
    if state.stopping
        || work.generation != state.generation
        || state.cancel_requested
        || state.response.is_none()
    {
        return None;
    }
    let response = state.response.take();
    if state
        .prompt
        .as_ref()
        .is_some_and(|prompt| prompt.sequence == sequence)
    {
        state.prompt = None;
    }
    response
}

fn sanitize_message(message: &str) -> String {
    let mut sanitized = String::with_capacity(message.len().min(MAX_STATUS_BYTES));
    for character in message.chars() {
        if sanitized.len() + character.len_utf8() > MAX_STATUS_BYTES {
            break;
        }
        if matches!(character, '\n' | '\t') || !character.is_control() {
            sanitized.push(character);
        }
    }
    while sanitized.ends_with(['\n', '\r', ' ']) {
        sanitized.pop();
    }
    if sanitized.is_empty() {
        "Authenticate to unlock".into()
    } else {
        sanitized
    }
}

fn cooldown_for(failures: u32) -> Duration {
    let exponent = failures.saturating_sub(1).min(6);
    BASE_COOLDOWN
        .checked_mul(1 << exponent)
        .unwrap_or(MAX_COOLDOWN)
        .min(MAX_COOLDOWN)
}

fn current_username() -> String {
    // SAFETY: all libc pointers target live stack/Vec allocations and the
    // returned passwd fields are copied before the backing buffer is dropped.
    unsafe {
        let user_id = libc::getuid();
        let suggested = libc::sysconf(libc::_SC_GETPW_R_SIZE_MAX);
        let size = if suggested > 0 {
            suggested as usize
        } else {
            4096
        }
        .clamp(1024, 64 * 1024);
        let mut buffer = vec![0u8; size];
        let mut record = std::mem::zeroed::<libc::passwd>();
        let mut result = ptr::null_mut();
        if libc::getpwuid_r(
            user_id,
            &mut record,
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            &mut result,
        ) == 0
            && !result.is_null()
            && !record.pw_name.is_null()
        {
            let username = CStr::from_ptr(record.pw_name).to_string_lossy();
            if !username.is_empty() {
                return username.chars().take(256).collect();
            }
        }
        user_id.to_string()
    }
}

#[cfg(test)]
#[path = "authentication/tests.rs"]
mod tests;
