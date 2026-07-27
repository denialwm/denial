//! Native clipboard history, retention, and the binary Flutter control API.
//!
//! Wayland and X11 remain the authoritative live clipboard sources. Denial
//! captures a deliberately small set of safe representations in parallel and
//! only becomes the selection owner when Flutter sets text or the user
//! explicitly activates a retained entry.

use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::fmt;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{SystemTime, UNIX_EPOCH};

pub const CONTROL_CHANNEL: &str = "denial/clipboard";
pub const STATE_CHANNEL: &std::ffi::CStr = c"denial/clipboard_state";

const REQUEST_MAGIC: &[u8; 4] = b"DCLP";
const RESPONSE_MAGIC: &[u8; 4] = b"DCLS";
const PROTOCOL_VERSION: u16 = 1;

const COMMAND_SNAPSHOT: u8 = 0;
const COMMAND_READ: u8 = 1;
const COMMAND_ACTIVATE: u8 = 2;
const COMMAND_SET_PINNED: u8 = 3;
const COMMAND_DELETE: u8 = 4;
const COMMAND_CLEAR: u8 = 5;
const COMMAND_SET_PAUSED: u8 = 6;
const COMMAND_START_DRAG: u8 = 7;

const RESPONSE_ACK: u8 = 0;
const RESPONSE_SNAPSHOT: u8 = 1;
const RESPONSE_DATA: u8 = 2;
const RESPONSE_ERROR: u8 = u8::MAX;

const STATUS_OK: u8 = 0;
const STATUS_BAD_REQUEST: u8 = 1;
const STATUS_NOT_FOUND: u8 = 2;
const STATUS_LOCKED: u8 = 3;
const STATUS_TOO_LARGE: u8 = 4;
const STATUS_UNSUPPORTED: u8 = 5;

const SNAPSHOT_PAUSED: u8 = 1 << 0;
const SNAPSHOT_LOCKED: u8 = 1 << 1;
const ENTRY_PINNED: u8 = 1 << 0;
const ENTRY_ACTIVE: u8 = 1 << 1;

pub const MAX_REQUEST_BYTES: usize = 4096;
pub const MAX_QUERY_BYTES: usize = 256;
pub const MAX_MIME_BYTES: usize = 256;
pub const MAX_TEXT_BYTES: usize = 1024 * 1024;
pub const MAX_IMAGE_BYTES: usize = 16 * 1024 * 1024;
pub const MAX_ITEM_BYTES: usize = 24 * 1024 * 1024;
pub const MAX_HISTORY_BYTES: usize = 64 * 1024 * 1024;
pub const MAX_HISTORY_ITEMS: usize = 100;
const MAX_CAPTURE_REPRESENTATIONS: usize = 4;
const MAX_OFFERED_MIME_TYPES: usize = 256;
const MAX_SOURCE_APP_ID_BYTES: usize = 512;
const MAX_SOURCE_TITLE_BYTES: usize = 1024;
const MAX_PREVIEW_BYTES: usize = 1024;
const MAX_IMAGE_DIMENSION: u32 = 16_384;
const MAX_IMAGE_PIXELS: u64 = 64 * 1024 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum ClipboardOrigin {
    Wayland = 0,
    X11 = 1,
    Flutter = 2,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum ClipboardContentKind {
    Text = 0,
    Image = 1,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ClipboardSourceIdentity {
    pub app_id: String,
    pub title: String,
}

impl ClipboardSourceIdentity {
    pub fn bounded(app_id: impl Into<String>, title: impl Into<String>) -> Option<Self> {
        let app_id = sanitize_metadata(app_id.into(), MAX_SOURCE_APP_ID_BYTES);
        let title = sanitize_metadata(title.into(), MAX_SOURCE_TITLE_BYTES);
        if app_id.is_empty() && title.is_empty() {
            None
        } else {
            Some(Self { app_id, title })
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ClipboardSelection {
    Xwayland,
    History { item_id: u64 },
}

impl ClipboardSelection {
    pub fn history_item_id(self) -> Option<u64> {
        match self {
            Self::History { item_id } => Some(item_id),
            Self::Xwayland => None,
        }
    }

    pub fn is_xwayland(self) -> bool {
        self == Self::Xwayland
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CaptureRepresentation {
    pub mime_type: String,
    pub max_bytes: usize,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ClipboardCapturePlan {
    pub epoch: u64,
    pub representations: Vec<CaptureRepresentation>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ClipboardAction {
    Publish {
        epoch: u64,
        item_id: u64,
        paste: bool,
    },
    Clear {
        epoch: u64,
    },
    StartDrag {
        item_id: u64,
    },
}

#[derive(Clone, Debug)]
pub struct ClipboardDragPayload {
    pub item_id: u64,
    pub representations: Vec<(String, Arc<[u8]>)>,
}

#[derive(Clone, Debug)]
struct ClipboardRepresentation {
    mime_type: String,
    data: Arc<[u8]>,
    kind: ClipboardContentKind,
    dimensions: Option<(u32, u32)>,
}

#[derive(Clone, Debug)]
struct ClipboardItem {
    id: u64,
    captured_unix_ms: u64,
    origin: ClipboardOrigin,
    source: Option<ClipboardSourceIdentity>,
    representations: Vec<ClipboardRepresentation>,
    kind: ClipboardContentKind,
    byte_len: usize,
    preview: String,
    width: u32,
    height: u32,
    pinned: bool,
}

impl ClipboardItem {
    fn primary(&self) -> &ClipboardRepresentation {
        self.representations
            .first()
            .expect("clipboard items always contain a representation")
    }

    fn same_content(&self, other: &Self) -> bool {
        let left = self.primary();
        let right = other.primary();
        left.kind == right.kind && left.data.as_ref() == right.data.as_ref()
    }

    fn data(&self, mime_type: &str) -> Option<Arc<[u8]>> {
        self.representations
            .iter()
            .find(|representation| representation.mime_type.eq_ignore_ascii_case(mime_type))
            .map(|representation| Arc::clone(&representation.data))
    }

    fn text(&self) -> Option<String> {
        self.representations
            .iter()
            .filter(|representation| representation.kind == ClipboardContentKind::Text)
            .min_by_key(|representation| representation_priority(&representation.mime_type))
            .and_then(|representation| {
                std::str::from_utf8(&representation.data)
                    .ok()
                    .map(str::to_owned)
            })
    }

    fn matches(&self, folded_query: &str) -> bool {
        if folded_query.is_empty() {
            return true;
        }
        if self.preview.to_lowercase().contains(folded_query)
            || self.source.as_ref().is_some_and(|source| {
                source.app_id.to_lowercase().contains(folded_query)
                    || source.title.to_lowercase().contains(folded_query)
            })
            || self.representations.iter().any(|representation| {
                representation
                    .mime_type
                    .to_lowercase()
                    .contains(folded_query)
            })
        {
            return true;
        }
        false
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CurrentSelection {
    None,
    External {
        epoch: u64,
        history_item_id: Option<u64>,
    },
    Managed {
        epoch: u64,
        item_id: u64,
    },
}

#[derive(Debug)]
struct PendingCapture {
    epoch: u64,
    origin: ClipboardOrigin,
    source: Option<ClipboardSourceIdentity>,
    remaining: BTreeSet<String>,
    representations: BTreeMap<String, ClipboardRepresentation>,
}

#[derive(Debug)]
struct ClipboardState {
    revision: u64,
    next_item_id: u64,
    next_epoch: u64,
    paused: bool,
    locked: bool,
    history: VecDeque<Arc<ClipboardItem>>,
    history_bytes: usize,
    current: CurrentSelection,
    managed: Option<Arc<ClipboardItem>>,
    pending_capture: Option<PendingCapture>,
    actions: VecDeque<ClipboardAction>,
}

impl Default for ClipboardState {
    fn default() -> Self {
        Self {
            revision: 1,
            next_item_id: 1,
            next_epoch: 1,
            paused: false,
            locked: false,
            history: VecDeque::new(),
            history_bytes: 0,
            current: CurrentSelection::None,
            managed: None,
            pending_capture: None,
            actions: VecDeque::new(),
        }
    }
}

impl ClipboardState {
    fn bump_revision(&mut self) {
        self.revision = self.revision.wrapping_add(1).max(1);
    }

    fn new_epoch(&mut self) -> u64 {
        let epoch = self.next_epoch;
        self.next_epoch = self.next_epoch.wrapping_add(1).max(1);
        epoch
    }

    fn new_item_id(&mut self) -> u64 {
        let id = self.next_item_id;
        self.next_item_id = self.next_item_id.wrapping_add(1).max(1);
        id
    }

    fn history_item(&self, item_id: u64) -> Option<&Arc<ClipboardItem>> {
        self.history.iter().find(|item| item.id == item_id)
    }

    fn retained_item(&self, item_id: u64) -> Option<&Arc<ClipboardItem>> {
        self.managed
            .as_ref()
            .filter(|item| item.id == item_id)
            .or_else(|| self.history_item(item_id))
    }

    fn active_history_id(&self) -> Option<u64> {
        let CurrentSelection::Managed { item_id, .. } = self.current else {
            return None;
        };
        self.history_item(item_id).map(|_| item_id)
    }

    fn recalculate_history_bytes(&mut self) {
        self.history_bytes = self.history.iter().map(|item| item.byte_len).sum();
    }

    fn enforce_limits(&mut self) {
        self.enforce_limits_to(MAX_HISTORY_ITEMS, MAX_HISTORY_BYTES);
    }

    fn enforce_limits_to(&mut self, maximum_items: usize, maximum_bytes: usize) {
        self.recalculate_history_bytes();
        while self.history.len() > maximum_items || self.history_bytes > maximum_bytes {
            // Pinning influences eviction order, but can never weaken the hard
            // memory and count ceilings. If every entry is pinned, discard the
            // oldest pinned entry rather than allowing unbounded retention.
            let index = self
                .history
                .iter()
                .rposition(|item| !item.pinned)
                .unwrap_or_else(|| self.history.len().saturating_sub(1));
            if let Some(removed) = self.history.remove(index) {
                self.history_bytes = self.history_bytes.saturating_sub(removed.byte_len);
                if let CurrentSelection::External {
                    history_item_id, ..
                } = &mut self.current
                    && *history_item_id == Some(removed.id)
                {
                    *history_item_id = None;
                }
            }
        }
    }
}

#[derive(Clone, Default)]
pub struct ClipboardManager {
    inner: Arc<Mutex<ClipboardState>>,
}

impl fmt::Debug for ClipboardManager {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let state = self.lock();
        formatter
            .debug_struct("ClipboardManager")
            .field("revision", &state.revision)
            .field("paused", &state.paused)
            .field("locked", &state.locked)
            .field("items", &state.history.len())
            .field("bytes", &state.history_bytes)
            .finish()
    }
}

impl ClipboardManager {
    fn lock(&self) -> MutexGuard<'_, ClipboardState> {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn revision(&self) -> u64 {
        self.lock().revision
    }

    pub fn set_locked(&self, locked: bool) {
        let mut state = self.lock();
        if state.locked == locked {
            return;
        }
        state.locked = locked;
        state.pending_capture = None;
        state.actions.clear();
        if !locked && let CurrentSelection::Managed { epoch, item_id } = state.current {
            state.actions.push_back(ClipboardAction::Publish {
                epoch,
                item_id,
                paste: false,
            });
        }
        state.bump_revision();
    }

    pub fn observe_external_selection(
        &self,
        origin: ClipboardOrigin,
        offered_mime_types: &[String],
        source: Option<ClipboardSourceIdentity>,
    ) -> Option<ClipboardCapturePlan> {
        let mut state = self.lock();
        let epoch = state.new_epoch();
        state.actions.clear();
        state.pending_capture = None;
        state.managed = None;
        if offered_mime_types.is_empty() {
            state.current = CurrentSelection::None;
            state.bump_revision();
            return None;
        }
        state.current = CurrentSelection::External {
            epoch,
            history_item_id: None,
        };
        state.bump_revision();
        if state.locked || state.paused {
            return None;
        }

        let representations = select_capture_representations(offered_mime_types);
        if representations.is_empty() {
            return None;
        }
        let remaining = representations
            .iter()
            .map(|representation| representation.mime_type.clone())
            .collect();
        state.pending_capture = Some(PendingCapture {
            epoch,
            origin,
            source,
            remaining,
            representations: BTreeMap::new(),
        });
        Some(ClipboardCapturePlan {
            epoch,
            representations,
        })
    }

    pub fn capture_is_current(&self, epoch: u64) -> bool {
        self.lock()
            .pending_capture
            .as_ref()
            .is_some_and(|capture| capture.epoch == epoch)
    }

    pub fn has_pending_capture(&self) -> bool {
        self.lock().pending_capture.is_some()
    }

    pub fn finish_capture(&self, epoch: u64, mime_type: &str, data: Option<Vec<u8>>) {
        let mut state = self.lock();
        let Some(capture) = state.pending_capture.as_mut() else {
            return;
        };
        if capture.epoch != epoch || !capture.remaining.remove(mime_type) {
            return;
        }
        if let Some(data) = data
            && let Some(representation) = validate_representation(mime_type, data)
        {
            capture
                .representations
                .insert(mime_type.to_owned(), representation);
        }
        if !capture.remaining.is_empty() {
            return;
        }
        let capture = state
            .pending_capture
            .take()
            .expect("completed clipboard capture disappeared");
        finalize_capture(&mut state, capture);
    }

    pub fn set_text(&self, text: &str) -> Result<u64, ClipboardError> {
        if text.len() > MAX_TEXT_BYTES {
            return Err(ClipboardError::TooLarge);
        }
        if text.as_bytes().contains(&0) {
            return Err(ClipboardError::Unsupported);
        }
        let representation =
            validate_representation("text/plain;charset=utf-8", text.as_bytes().to_vec())
                .ok_or(ClipboardError::Unsupported)?;
        let mut state = self.lock();
        if state.locked {
            return Err(ClipboardError::Locked);
        }
        let item = Arc::new(item_from_representations(
            state.new_item_id(),
            ClipboardOrigin::Flutter,
            ClipboardSourceIdentity::bounded("denial", "Denial shell"),
            vec![representation],
            false,
        ));
        let item = if state.paused {
            item
        } else {
            insert_history_item(&mut state, item)
        };
        let item_id = item.id;
        let epoch = state.new_epoch();
        state.current = CurrentSelection::Managed { epoch, item_id };
        state.managed = Some(item);
        state.pending_capture = None;
        state.actions.clear();
        state.actions.push_back(ClipboardAction::Publish {
            epoch,
            item_id,
            paste: false,
        });
        state.bump_revision();
        Ok(item_id)
    }

    pub fn current_text(&self) -> Option<String> {
        let state = self.lock();
        if state.locked {
            return None;
        }
        match state.current {
            CurrentSelection::Managed { item_id, .. } => {
                state.retained_item(item_id).and_then(|item| item.text())
            }
            CurrentSelection::External {
                history_item_id: Some(item_id),
                ..
            } => state.history_item(item_id).and_then(|item| item.text()),
            CurrentSelection::None
            | CurrentSelection::External {
                history_item_id: None,
                ..
            } => None,
        }
    }

    pub fn has_strings(&self) -> bool {
        self.current_text().is_some()
    }

    pub fn retained_data(&self, item_id: u64, mime_type: &str) -> Option<Arc<[u8]>> {
        let state = self.lock();
        if state.locked {
            return None;
        }
        state
            .retained_item(item_id)
            .and_then(|item| item.data(mime_type))
    }

    pub fn retained_mime_types(&self, epoch: u64, item_id: u64) -> Option<Vec<String>> {
        let state = self.lock();
        if state.locked || state.current != (CurrentSelection::Managed { epoch, item_id }) {
            return None;
        }
        Some(
            state
                .retained_item(item_id)?
                .representations
                .iter()
                .map(|representation| representation.mime_type.clone())
                .collect(),
        )
    }

    pub fn drag_payload(&self, item_id: u64) -> Option<ClipboardDragPayload> {
        let state = self.lock();
        if state.locked {
            return None;
        }
        let item = state.history_item(item_id)?;
        Some(ClipboardDragPayload {
            item_id,
            representations: item
                .representations
                .iter()
                .map(|representation| {
                    (
                        representation.mime_type.clone(),
                        Arc::clone(&representation.data),
                    )
                })
                .collect(),
        })
    }

    pub fn take_actions(&self) -> Vec<ClipboardAction> {
        self.lock().actions.drain(..).collect()
    }

    pub fn state_packet(&self) -> Vec<u8> {
        encode_snapshot(&self.lock(), "")
    }

    pub fn handle_control_packet(&self, packet: &[u8]) -> Vec<u8> {
        match decode_request(packet) {
            Ok(ClipboardRequest::Snapshot { query }) => {
                let state = self.lock();
                encode_snapshot(&state, &query.to_lowercase())
            }
            Ok(ClipboardRequest::Read { item_id, mime_type }) => {
                let state = self.lock();
                if state.locked {
                    return encode_error(ClipboardError::Locked);
                }
                let Some(item) = state.history_item(item_id) else {
                    return encode_error(ClipboardError::NotFound);
                };
                let Some(data) = item.data(&mime_type) else {
                    return encode_error(ClipboardError::Unsupported);
                };
                drop(state);
                encode_data(item_id, &mime_type, &data)
            }
            Ok(ClipboardRequest::Activate { item_id }) => {
                self.activate(item_id).map_or_else(encode_error, encode_ack)
            }
            Ok(ClipboardRequest::SetPinned { item_id, pinned }) => self
                .set_pinned(item_id, pinned)
                .map_or_else(encode_error, encode_ack),
            Ok(ClipboardRequest::Delete { item_id }) => {
                self.delete(item_id).map_or_else(encode_error, encode_ack)
            }
            Ok(ClipboardRequest::Clear) => self.clear().map_or_else(encode_error, encode_ack),
            Ok(ClipboardRequest::SetPaused { paused }) => self
                .set_paused(paused)
                .map_or_else(encode_error, encode_ack),
            Ok(ClipboardRequest::StartDrag { item_id }) => self
                .start_drag(item_id)
                .map_or_else(encode_error, encode_ack),
            Err(error) => encode_error(error),
        }
    }

    fn activate(&self, item_id: u64) -> Result<u64, ClipboardError> {
        let mut state = self.lock();
        if state.locked {
            return Err(ClipboardError::Locked);
        }
        let item = Arc::clone(
            state
                .history_item(item_id)
                .ok_or(ClipboardError::NotFound)?,
        );
        let epoch = state.new_epoch();
        state.current = CurrentSelection::Managed { epoch, item_id };
        state.managed = Some(item);
        state.pending_capture = None;
        state.actions.clear();
        state.actions.push_back(ClipboardAction::Publish {
            epoch,
            item_id,
            paste: true,
        });
        state.bump_revision();
        Ok(state.revision)
    }

    fn set_pinned(&self, item_id: u64, pinned: bool) -> Result<u64, ClipboardError> {
        let mut state = self.lock();
        if state.locked {
            return Err(ClipboardError::Locked);
        }
        let index = state
            .history
            .iter()
            .position(|item| item.id == item_id)
            .ok_or(ClipboardError::NotFound)?;
        if state.history[index].pinned == pinned {
            return Ok(state.revision);
        }
        let mut item = (*state.history[index]).clone();
        item.pinned = pinned;
        state.history[index] = Arc::new(item);
        if state
            .managed
            .as_ref()
            .is_some_and(|managed| managed.id == item_id)
        {
            state.managed = Some(Arc::clone(&state.history[index]));
        }
        state.bump_revision();
        Ok(state.revision)
    }

    fn delete(&self, item_id: u64) -> Result<u64, ClipboardError> {
        let mut state = self.lock();
        if state.locked {
            return Err(ClipboardError::Locked);
        }
        let index = state
            .history
            .iter()
            .position(|item| item.id == item_id)
            .ok_or(ClipboardError::NotFound)?;
        let removed = state
            .history
            .remove(index)
            .expect("located clipboard entry disappeared");
        state.history_bytes = state.history_bytes.saturating_sub(removed.byte_len);
        match &mut state.current {
            CurrentSelection::Managed {
                item_id: active_id, ..
            } if *active_id == item_id => {
                let epoch = state.new_epoch();
                state.current = CurrentSelection::None;
                state.managed = None;
                state.actions.clear();
                state.actions.push_back(ClipboardAction::Clear { epoch });
            }
            CurrentSelection::External {
                history_item_id, ..
            } if *history_item_id == Some(item_id) => {
                *history_item_id = None;
            }
            _ => {}
        }
        state.bump_revision();
        Ok(state.revision)
    }

    fn clear(&self) -> Result<u64, ClipboardError> {
        let mut state = self.lock();
        if state.locked {
            return Err(ClipboardError::Locked);
        }
        state.history.clear();
        state.history_bytes = 0;
        state.pending_capture = None;
        match state.current {
            CurrentSelection::Managed { .. } => {
                let epoch = state.new_epoch();
                state.current = CurrentSelection::None;
                state.managed = None;
                state.actions.clear();
                state.actions.push_back(ClipboardAction::Clear { epoch });
            }
            CurrentSelection::External { epoch, .. } => {
                state.current = CurrentSelection::External {
                    epoch,
                    history_item_id: None,
                };
                state.managed = None;
            }
            CurrentSelection::None => {
                state.managed = None;
            }
        }
        state.bump_revision();
        Ok(state.revision)
    }

    fn set_paused(&self, paused: bool) -> Result<u64, ClipboardError> {
        let mut state = self.lock();
        if state.locked {
            return Err(ClipboardError::Locked);
        }
        if state.paused == paused {
            return Ok(state.revision);
        }
        state.paused = paused;
        if paused {
            state.pending_capture = None;
        }
        state.bump_revision();
        Ok(state.revision)
    }

    fn start_drag(&self, item_id: u64) -> Result<u64, ClipboardError> {
        let mut state = self.lock();
        if state.locked {
            return Err(ClipboardError::Locked);
        }
        if state.history_item(item_id).is_none() {
            return Err(ClipboardError::NotFound);
        }
        state
            .actions
            .push_back(ClipboardAction::StartDrag { item_id });
        Ok(state.revision)
    }
}

fn finalize_capture(state: &mut ClipboardState, capture: PendingCapture) {
    if state.locked
        || state.paused
        || !matches!(
            state.current,
            CurrentSelection::External { epoch, .. } if epoch == capture.epoch
        )
        || capture.representations.is_empty()
    {
        return;
    }
    let mut representations = capture.representations.into_values().collect::<Vec<_>>();
    representations
        .sort_by_key(|representation| representation_priority(&representation.mime_type));
    let mut retained_bytes = 0usize;
    representations.retain(|representation| {
        let Some(next) = retained_bytes.checked_add(representation.data.len()) else {
            return false;
        };
        if next > MAX_ITEM_BYTES {
            return false;
        }
        retained_bytes = next;
        true
    });
    if representations.is_empty() {
        return;
    }

    let candidate_id = state.new_item_id();
    let mut item = item_from_representations(
        candidate_id,
        capture.origin,
        capture.source,
        representations,
        false,
    );
    let item_id = if state
        .history
        .front()
        .is_some_and(|previous| previous.same_content(&item))
    {
        let previous = state
            .history
            .pop_front()
            .expect("front clipboard item disappeared");
        state.history_bytes = state.history_bytes.saturating_sub(previous.byte_len);
        item.id = previous.id;
        item.pinned = previous.pinned;
        let item_id = item.id;
        state.history.push_front(Arc::new(item));
        item_id
    } else {
        let item_id = item.id;
        state.history.push_front(Arc::new(item));
        item_id
    };
    state.enforce_limits();
    let retained = state.history_item(item_id).is_some();
    if let CurrentSelection::External {
        epoch,
        history_item_id,
    } = &mut state.current
        && *epoch == capture.epoch
    {
        *history_item_id = retained.then_some(item_id);
    }
    state.bump_revision();
}

fn insert_history_item(
    state: &mut ClipboardState,
    mut item: Arc<ClipboardItem>,
) -> Arc<ClipboardItem> {
    if state
        .history
        .front()
        .is_some_and(|previous| previous.same_content(&item))
    {
        let previous = state
            .history
            .pop_front()
            .expect("front clipboard item disappeared");
        state.history_bytes = state.history_bytes.saturating_sub(previous.byte_len);
        let mut replacement = (*item).clone();
        replacement.id = previous.id;
        replacement.pinned = previous.pinned;
        item = Arc::new(replacement);
    }
    state.history.push_front(Arc::clone(&item));
    state.enforce_limits();
    item
}

fn item_from_representations(
    id: u64,
    origin: ClipboardOrigin,
    source: Option<ClipboardSourceIdentity>,
    representations: Vec<ClipboardRepresentation>,
    pinned: bool,
) -> ClipboardItem {
    let byte_len = representations
        .iter()
        .map(|representation| representation.data.len())
        .sum();
    let primary = representations
        .first()
        .expect("clipboard item needs a representation");
    let kind = primary.kind;
    let (width, height) = primary.dimensions.unwrap_or((0, 0));
    let preview = representations
        .iter()
        .find(|representation| representation.kind == ClipboardContentKind::Text)
        .and_then(|representation| std::str::from_utf8(&representation.data).ok())
        .map(text_preview)
        .unwrap_or_default();
    ClipboardItem {
        id,
        captured_unix_ms: SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
            .try_into()
            .unwrap_or(u64::MAX),
        origin,
        source,
        representations,
        kind,
        byte_len,
        preview,
        width,
        height,
        pinned,
    }
}

fn select_capture_representations(offered: &[String]) -> Vec<CaptureRepresentation> {
    let mut safe = offered
        .iter()
        .take(MAX_OFFERED_MIME_TYPES)
        .filter(|mime_type| {
            !mime_type.is_empty()
                && mime_type.len() <= MAX_MIME_BYTES
                && mime_type.is_ascii()
                && !mime_type.bytes().any(|byte| byte.is_ascii_control())
        })
        .filter_map(|mime_type| mime_kind(mime_type).map(|kind| (mime_type.clone(), kind)))
        .collect::<Vec<_>>();
    safe.sort_by_key(|(mime_type, _)| representation_priority(mime_type));

    let mut selected = Vec::with_capacity(MAX_CAPTURE_REPRESENTATIONS);
    let mut keys = BTreeSet::new();
    let mut image_selected = false;
    for (mime_type, kind) in safe {
        let key = mime_type.to_ascii_lowercase();
        if !keys.insert(key) || (kind == ClipboardContentKind::Image && image_selected) {
            continue;
        }
        image_selected |= kind == ClipboardContentKind::Image;
        selected.push(CaptureRepresentation {
            max_bytes: match kind {
                ClipboardContentKind::Text => MAX_TEXT_BYTES,
                ClipboardContentKind::Image => MAX_IMAGE_BYTES,
            },
            mime_type,
        });
        if selected.len() == MAX_CAPTURE_REPRESENTATIONS {
            break;
        }
    }
    selected
}

fn representation_priority(mime_type: &str) -> u8 {
    let mime_type = mime_type.to_ascii_lowercase();
    match mime_type.as_str() {
        "image/png" => 0,
        "image/webp" => 1,
        "image/jpeg" | "image/jpg" => 2,
        "text/plain;charset=utf-8" | "text/plain;charset=utf8" => 3,
        "text/plain" => 4,
        "text/uri-list" => 5,
        value if value.starts_with("text/plain;") => 6,
        _ => u8::MAX,
    }
}

fn mime_kind(mime_type: &str) -> Option<ClipboardContentKind> {
    let mime_type = mime_type.trim().to_ascii_lowercase();
    if mime_type == "text/plain"
        || mime_type.starts_with("text/plain;")
        || mime_type == "text/uri-list"
    {
        Some(ClipboardContentKind::Text)
    } else if matches!(
        mime_type.as_str(),
        "image/png" | "image/webp" | "image/jpeg" | "image/jpg"
    ) {
        Some(ClipboardContentKind::Image)
    } else {
        None
    }
}

fn validate_representation(mime_type: &str, data: Vec<u8>) -> Option<ClipboardRepresentation> {
    let kind = mime_kind(mime_type)?;
    let limit = match kind {
        ClipboardContentKind::Text => MAX_TEXT_BYTES,
        ClipboardContentKind::Image => MAX_IMAGE_BYTES,
    };
    if data.len() > limit {
        return None;
    }
    let dimensions = match kind {
        ClipboardContentKind::Text => {
            std::str::from_utf8(&data).ok()?;
            if data.contains(&0) {
                return None;
            }
            None
        }
        ClipboardContentKind::Image => validate_image(mime_type, &data),
    };
    if kind == ClipboardContentKind::Image && dimensions.is_none() {
        return None;
    }
    Some(ClipboardRepresentation {
        mime_type: mime_type.to_owned(),
        data: data.into(),
        kind,
        dimensions,
    })
}

fn validate_image(mime_type: &str, data: &[u8]) -> Option<(u32, u32)> {
    let mime_type = mime_type.to_ascii_lowercase();
    let dimensions = match mime_type.as_str() {
        "image/png" => png_dimensions(data),
        "image/jpeg" | "image/jpg" => jpeg_dimensions(data),
        "image/webp" => webp_dimensions(data),
        _ => None,
    }?;
    valid_image_dimensions(dimensions).then_some(dimensions)
}

fn valid_image_dimensions((width, height): (u32, u32)) -> bool {
    width > 0
        && height > 0
        && width <= MAX_IMAGE_DIMENSION
        && height <= MAX_IMAGE_DIMENSION
        && u64::from(width) * u64::from(height) <= MAX_IMAGE_PIXELS
}

fn png_dimensions(data: &[u8]) -> Option<(u32, u32)> {
    const SIGNATURE: &[u8; 8] = b"\x89PNG\r\n\x1a\n";
    if !data.starts_with(SIGNATURE) {
        return None;
    }
    let mut cursor = SIGNATURE.len();
    let mut dimensions = None;
    let mut saw_iend = false;
    while cursor.checked_add(12)? <= data.len() {
        let length = u32::from_be_bytes(data.get(cursor..cursor + 4)?.try_into().ok()?) as usize;
        let kind = data.get(cursor + 4..cursor + 8)?;
        let payload_start = cursor + 8;
        let payload_end = payload_start.checked_add(length)?;
        let chunk_end = payload_end.checked_add(4)?;
        if chunk_end > data.len() {
            return None;
        }
        if dimensions.is_none() {
            if kind != b"IHDR" || length != 13 {
                return None;
            }
            dimensions = Some((
                u32::from_be_bytes(
                    data.get(payload_start..payload_start + 4)?
                        .try_into()
                        .ok()?,
                ),
                u32::from_be_bytes(
                    data.get(payload_start + 4..payload_start + 8)?
                        .try_into()
                        .ok()?,
                ),
            ));
        }
        cursor = chunk_end;
        if kind == b"IEND" {
            if length != 0 || cursor != data.len() {
                return None;
            }
            saw_iend = true;
            break;
        }
    }
    saw_iend.then_some(dimensions?)
}

fn jpeg_dimensions(data: &[u8]) -> Option<(u32, u32)> {
    if data.len() < 4 || !data.starts_with(&[0xff, 0xd8]) || !data.ends_with(&[0xff, 0xd9]) {
        return None;
    }
    let mut cursor = 2usize;
    while cursor + 1 < data.len() {
        while data.get(cursor) == Some(&0xff) {
            cursor += 1;
        }
        let marker = *data.get(cursor)?;
        cursor += 1;
        if marker == 0xd9 || marker == 0xda {
            break;
        }
        if marker == 0x01 || (0xd0..=0xd7).contains(&marker) {
            continue;
        }
        let segment_len =
            u16::from_be_bytes(data.get(cursor..cursor + 2)?.try_into().ok()?) as usize;
        if segment_len < 2 {
            return None;
        }
        let segment_end = cursor.checked_add(segment_len)?;
        if segment_end > data.len() {
            return None;
        }
        if matches!(
            marker,
            0xc0 | 0xc1
                | 0xc2
                | 0xc3
                | 0xc5
                | 0xc6
                | 0xc7
                | 0xc9
                | 0xca
                | 0xcb
                | 0xcd
                | 0xce
                | 0xcf
        ) {
            if segment_len < 7 {
                return None;
            }
            let height =
                u16::from_be_bytes(data.get(cursor + 3..cursor + 5)?.try_into().ok()?) as u32;
            let width =
                u16::from_be_bytes(data.get(cursor + 5..cursor + 7)?.try_into().ok()?) as u32;
            return Some((width, height));
        }
        cursor = segment_end;
    }
    None
}

fn webp_dimensions(data: &[u8]) -> Option<(u32, u32)> {
    if data.len() < 20 || &data[..4] != b"RIFF" || &data[8..12] != b"WEBP" {
        return None;
    }
    let riff_size = u32::from_le_bytes(data.get(4..8)?.try_into().ok()?) as usize;
    if riff_size.checked_add(8)? != data.len() {
        return None;
    }
    let mut cursor = 12usize;
    while cursor.checked_add(8)? <= data.len() {
        let kind = data.get(cursor..cursor + 4)?;
        let length =
            u32::from_le_bytes(data.get(cursor + 4..cursor + 8)?.try_into().ok()?) as usize;
        let payload_start = cursor + 8;
        let payload_end = payload_start.checked_add(length)?;
        if payload_end > data.len() {
            return None;
        }
        let payload = &data[payload_start..payload_end];
        let dimensions = match kind {
            b"VP8X" if payload.len() >= 10 => Some((
                1 + read_u24_le(&payload[4..7]),
                1 + read_u24_le(&payload[7..10]),
            )),
            b"VP8L" if payload.len() >= 5 && payload[0] == 0x2f => {
                let bits = u32::from_le_bytes(payload[1..5].try_into().ok()?);
                Some((1 + (bits & 0x3fff), 1 + ((bits >> 14) & 0x3fff)))
            }
            b"VP8 " if payload.len() >= 10 && payload[3..6] == [0x9d, 0x01, 0x2a] => Some((
                u16::from_le_bytes(payload[6..8].try_into().ok()?) as u32 & 0x3fff,
                u16::from_le_bytes(payload[8..10].try_into().ok()?) as u32 & 0x3fff,
            )),
            _ => None,
        };
        if dimensions.is_some() {
            return dimensions;
        }
        cursor = payload_end.checked_add(length & 1)?;
    }
    None
}

fn read_u24_le(bytes: &[u8]) -> u32 {
    u32::from(bytes[0]) | (u32::from(bytes[1]) << 8) | (u32::from(bytes[2]) << 16)
}

fn text_preview(text: &str) -> String {
    let mut output = String::new();
    let mut separating = false;
    for character in text.trim().chars() {
        if character.is_whitespace() {
            separating = !output.is_empty();
            continue;
        }
        if separating {
            if output.len() + 1 > MAX_PREVIEW_BYTES {
                break;
            }
            output.push(' ');
            separating = false;
        }
        if output.len() + character.len_utf8() > MAX_PREVIEW_BYTES {
            break;
        }
        output.push(character);
    }
    output
}

fn sanitize_metadata(mut value: String, max_bytes: usize) -> String {
    value.retain(|character| !character.is_control());
    let value = value.trim();
    if value.len() <= max_bytes {
        return value.to_owned();
    }
    let mut end = max_bytes;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].trim().to_owned()
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ClipboardError {
    BadRequest,
    NotFound,
    Locked,
    TooLarge,
    Unsupported,
}

impl ClipboardError {
    fn status(self) -> u8 {
        match self {
            Self::BadRequest => STATUS_BAD_REQUEST,
            Self::NotFound => STATUS_NOT_FOUND,
            Self::Locked => STATUS_LOCKED,
            Self::TooLarge => STATUS_TOO_LARGE,
            Self::Unsupported => STATUS_UNSUPPORTED,
        }
    }

    fn message(self) -> &'static str {
        match self {
            Self::BadRequest => "Malformed clipboard request",
            Self::NotFound => "Clipboard entry not found",
            Self::Locked => "Clipboard history is unavailable while locked",
            Self::TooLarge => "Clipboard payload exceeds its limit",
            Self::Unsupported => "Clipboard representation is unsupported",
        }
    }
}

enum ClipboardRequest {
    Snapshot { query: String },
    Read { item_id: u64, mime_type: String },
    Activate { item_id: u64 },
    SetPinned { item_id: u64, pinned: bool },
    Delete { item_id: u64 },
    Clear,
    SetPaused { paused: bool },
    StartDrag { item_id: u64 },
}

fn decode_request(packet: &[u8]) -> Result<ClipboardRequest, ClipboardError> {
    if packet.len() > MAX_REQUEST_BYTES {
        return Err(ClipboardError::TooLarge);
    }
    let mut decoder = Decoder::new(packet);
    if decoder.take(4)? != REQUEST_MAGIC
        || decoder.u16()? != PROTOCOL_VERSION
        || decoder.u8()? > COMMAND_START_DRAG
    {
        return Err(ClipboardError::BadRequest);
    }
    let command = packet[6];
    if decoder.u8()? != 0 {
        return Err(ClipboardError::BadRequest);
    }
    let request = match command {
        COMMAND_SNAPSHOT => {
            let query = decoder.string_u16(MAX_QUERY_BYTES)?;
            ClipboardRequest::Snapshot { query }
        }
        COMMAND_READ => ClipboardRequest::Read {
            item_id: decoder.nonzero_u64()?,
            mime_type: decoder.string_u16(MAX_MIME_BYTES)?,
        },
        COMMAND_ACTIVATE => ClipboardRequest::Activate {
            item_id: decoder.nonzero_u64()?,
        },
        COMMAND_SET_PINNED => ClipboardRequest::SetPinned {
            item_id: decoder.nonzero_u64()?,
            pinned: decoder.boolean()?,
        },
        COMMAND_DELETE => ClipboardRequest::Delete {
            item_id: decoder.nonzero_u64()?,
        },
        COMMAND_CLEAR => ClipboardRequest::Clear,
        COMMAND_SET_PAUSED => ClipboardRequest::SetPaused {
            paused: decoder.boolean()?,
        },
        COMMAND_START_DRAG => ClipboardRequest::StartDrag {
            item_id: decoder.nonzero_u64()?,
        },
        _ => return Err(ClipboardError::BadRequest),
    };
    if !decoder.is_empty() {
        return Err(ClipboardError::BadRequest);
    }
    Ok(request)
}

fn encode_header(kind: u8, status: u8) -> Encoder {
    let mut encoder = Encoder::new();
    encoder.bytes(RESPONSE_MAGIC);
    encoder.u16(PROTOCOL_VERSION);
    encoder.u8(kind);
    encoder.u8(status);
    encoder
}

fn encode_ack(revision: u64) -> Vec<u8> {
    let mut encoder = encode_header(RESPONSE_ACK, STATUS_OK);
    encoder.u64(revision);
    encoder.finish()
}

fn encode_error(error: ClipboardError) -> Vec<u8> {
    let mut encoder = encode_header(RESPONSE_ERROR, error.status());
    encoder.string_u16(error.message());
    encoder.finish()
}

fn encode_data(item_id: u64, mime_type: &str, data: &[u8]) -> Vec<u8> {
    let mut encoder = encode_header(RESPONSE_DATA, STATUS_OK);
    encoder.u64(item_id);
    encoder.string_u16(mime_type);
    encoder.u64(data.len().try_into().unwrap_or(u64::MAX));
    encoder.bytes(data);
    encoder.finish()
}

fn encode_snapshot(state: &ClipboardState, folded_query: &str) -> Vec<u8> {
    let mut encoder = encode_header(RESPONSE_SNAPSHOT, STATUS_OK);
    encoder.u64(state.revision);
    let history_bytes = if state.locked { 0 } else { state.history_bytes };
    encoder.u64(history_bytes.try_into().unwrap_or(u64::MAX));
    let active_id = (!state.locked)
        .then(|| state.active_history_id())
        .flatten()
        .unwrap_or(0);
    encoder.u64(active_id);
    let flags =
        (u8::from(state.paused) * SNAPSHOT_PAUSED) | (u8::from(state.locked) * SNAPSHOT_LOCKED);
    encoder.u8(flags);

    let visible = if state.locked {
        Vec::new()
    } else {
        state
            .history
            .iter()
            .filter(|item| item.matches(folded_query))
            .take(MAX_HISTORY_ITEMS)
            .collect::<Vec<_>>()
    };
    encoder.u16(visible.len().try_into().unwrap_or(u16::MAX));
    for item in visible {
        encoder.u64(item.id);
        encoder.u64(item.captured_unix_ms);
        encoder.u64(item.byte_len.try_into().unwrap_or(u64::MAX));
        encoder.u32(item.width);
        encoder.u32(item.height);
        encoder.u8(item.origin as u8);
        encoder.u8(item.kind as u8);
        let flags = (u8::from(item.pinned) * ENTRY_PINNED)
            | (u8::from(active_id == item.id) * ENTRY_ACTIVE);
        encoder.u8(flags);
        encoder.u8(item.representations.len().try_into().unwrap_or(u8::MAX));
        encoder.string_u16(&item.preview);
        encoder.string_u16(
            item.source
                .as_ref()
                .map(|source| source.app_id.as_str())
                .unwrap_or_default(),
        );
        encoder.string_u16(
            item.source
                .as_ref()
                .map(|source| source.title.as_str())
                .unwrap_or_default(),
        );
        for representation in &item.representations {
            encoder.string_u16(&representation.mime_type);
        }
    }
    encoder.finish()
}

struct Decoder<'a> {
    bytes: &'a [u8],
    cursor: usize,
}

impl<'a> Decoder<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, cursor: 0 }
    }

    fn take(&mut self, length: usize) -> Result<&'a [u8], ClipboardError> {
        let end = self
            .cursor
            .checked_add(length)
            .ok_or(ClipboardError::BadRequest)?;
        let value = self
            .bytes
            .get(self.cursor..end)
            .ok_or(ClipboardError::BadRequest)?;
        self.cursor = end;
        Ok(value)
    }

    fn u8(&mut self) -> Result<u8, ClipboardError> {
        Ok(self.take(1)?[0])
    }

    fn u16(&mut self) -> Result<u16, ClipboardError> {
        Ok(u16::from_le_bytes(
            self.take(2)?
                .try_into()
                .map_err(|_| ClipboardError::BadRequest)?,
        ))
    }

    fn u64(&mut self) -> Result<u64, ClipboardError> {
        Ok(u64::from_le_bytes(
            self.take(8)?
                .try_into()
                .map_err(|_| ClipboardError::BadRequest)?,
        ))
    }

    fn nonzero_u64(&mut self) -> Result<u64, ClipboardError> {
        let value = self.u64()?;
        (value != 0)
            .then_some(value)
            .ok_or(ClipboardError::BadRequest)
    }

    fn boolean(&mut self) -> Result<bool, ClipboardError> {
        match self.u8()? {
            0 => Ok(false),
            1 => Ok(true),
            _ => Err(ClipboardError::BadRequest),
        }
    }

    fn string_u16(&mut self, maximum: usize) -> Result<String, ClipboardError> {
        let length = usize::from(self.u16()?);
        if length > maximum {
            return Err(ClipboardError::TooLarge);
        }
        let value =
            std::str::from_utf8(self.take(length)?).map_err(|_| ClipboardError::BadRequest)?;
        if value.as_bytes().contains(&0) {
            return Err(ClipboardError::BadRequest);
        }
        Ok(value.to_owned())
    }

    fn is_empty(&self) -> bool {
        self.cursor == self.bytes.len()
    }
}

struct Encoder {
    bytes: Vec<u8>,
}

impl Encoder {
    fn new() -> Self {
        Self {
            bytes: Vec::with_capacity(256),
        }
    }

    fn bytes(&mut self, value: &[u8]) {
        self.bytes.extend_from_slice(value);
    }

    fn u8(&mut self, value: u8) {
        self.bytes.push(value);
    }

    fn u16(&mut self, value: u16) {
        self.bytes.extend_from_slice(&value.to_le_bytes());
    }

    fn u32(&mut self, value: u32) {
        self.bytes.extend_from_slice(&value.to_le_bytes());
    }

    fn u64(&mut self, value: u64) {
        self.bytes.extend_from_slice(&value.to_le_bytes());
    }

    fn string_u16(&mut self, value: &str) {
        let length = u16::try_from(value.len()).unwrap_or(u16::MAX);
        self.u16(length);
        self.bytes(&value.as_bytes()[..usize::from(length)]);
    }

    fn finish(self) -> Vec<u8> {
        self.bytes
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(command: u8, payload: impl FnOnce(&mut Encoder)) -> Vec<u8> {
        let mut encoder = Encoder::new();
        encoder.bytes(REQUEST_MAGIC);
        encoder.u16(PROTOCOL_VERSION);
        encoder.u8(command);
        encoder.u8(0);
        payload(&mut encoder);
        encoder.finish()
    }

    fn response_kind(packet: &[u8]) -> (u8, u8) {
        assert_eq!(&packet[..4], RESPONSE_MAGIC);
        (packet[6], packet[7])
    }

    fn capture_text(manager: &ClipboardManager, text: &str, origin: ClipboardOrigin) -> u64 {
        let mime_types = vec!["text/plain;charset=utf-8".to_owned()];
        let plan = manager
            .observe_external_selection(origin, &mime_types, None)
            .unwrap();
        manager.finish_capture(
            plan.epoch,
            &plan.representations[0].mime_type,
            Some(text.as_bytes().to_vec()),
        );
        manager.lock().history.front().unwrap().id
    }

    #[test]
    fn text_capture_is_bounded_deduplicated_and_searchable() {
        let manager = ClipboardManager::default();
        let first = capture_text(&manager, "Denial clipboard", ClipboardOrigin::Wayland);
        let duplicate = capture_text(&manager, "Denial clipboard", ClipboardOrigin::X11);
        assert_eq!(first, duplicate);
        assert_eq!(manager.lock().history.len(), 1);

        let packet = request(COMMAND_SNAPSHOT, |encoder| encoder.string_u16("clipboard"));
        let response = manager.handle_control_packet(&packet);
        assert_eq!(response_kind(&response), (RESPONSE_SNAPSHOT, STATUS_OK));
        let count = u16::from_le_bytes(response[33..35].try_into().unwrap());
        assert_eq!(count, 1);

        let packet = request(COMMAND_SNAPSHOT, |encoder| encoder.string_u16("missing"));
        let response = manager.handle_control_packet(&packet);
        let count = u16::from_le_bytes(response[33..35].try_into().unwrap());
        assert_eq!(count, 0);
    }

    #[test]
    fn activation_retains_data_and_clear_queues_selection_release() {
        let manager = ClipboardManager::default();
        let item_id = capture_text(&manager, "persistent", ClipboardOrigin::Wayland);
        let response = manager.handle_control_packet(&request(COMMAND_ACTIVATE, |encoder| {
            encoder.u64(item_id);
        }));
        assert_eq!(response_kind(&response), (RESPONSE_ACK, STATUS_OK));
        let action = manager.take_actions().pop().unwrap();
        let ClipboardAction::Publish {
            epoch,
            item_id: id,
            paste,
        } = action
        else {
            panic!("expected clipboard publish");
        };
        assert_eq!(id, item_id);
        assert!(paste);
        assert_eq!(
            manager
                .retained_data(item_id, "text/plain;charset=utf-8")
                .unwrap()
                .as_ref(),
            b"persistent"
        );
        assert_eq!(
            manager.retained_mime_types(epoch, item_id).unwrap(),
            vec!["text/plain;charset=utf-8"]
        );

        let response = manager.handle_control_packet(&request(COMMAND_CLEAR, |_| {}));
        assert_eq!(response_kind(&response), (RESPONSE_ACK, STATUS_OK));
        assert!(matches!(
            manager.take_actions().as_slice(),
            [ClipboardAction::Clear { .. }]
        ));
        assert!(
            manager
                .retained_data(item_id, "text/plain;charset=utf-8")
                .is_none()
        );
    }

    #[test]
    fn drag_request_retains_every_mime_representation() {
        let manager = ClipboardManager::default();
        let item_id = capture_text(&manager, "drag me", ClipboardOrigin::Wayland);

        let response = manager.handle_control_packet(&request(COMMAND_START_DRAG, |encoder| {
            encoder.u64(item_id);
        }));
        assert_eq!(response_kind(&response), (RESPONSE_ACK, STATUS_OK));
        assert!(matches!(
            manager.take_actions().as_slice(),
            [ClipboardAction::StartDrag { item_id: queued }] if *queued == item_id
        ));
        let payload = manager.drag_payload(item_id).unwrap();
        assert_eq!(payload.item_id, item_id);
        assert_eq!(payload.representations.len(), 1);
        assert_eq!(payload.representations[0].0, "text/plain;charset=utf-8");
        assert_eq!(payload.representations[0].1.as_ref(), b"drag me");
    }

    #[test]
    fn pause_suppresses_capture_but_not_flutter_clipboard_ownership() {
        let manager = ClipboardManager::default();
        manager.handle_control_packet(&request(COMMAND_SET_PAUSED, |encoder| encoder.u8(1)));
        assert!(
            manager
                .observe_external_selection(
                    ClipboardOrigin::Wayland,
                    &["text/plain".to_owned()],
                    None,
                )
                .is_none()
        );
        assert!(manager.lock().history.is_empty());

        let item_id = manager.set_text("from shell").unwrap();
        assert_eq!(manager.current_text().as_deref(), Some("from shell"));
        assert!(manager.lock().history.is_empty());
        assert!(
            manager
                .retained_data(item_id, "text/plain;charset=utf-8")
                .is_some()
        );
    }

    #[test]
    fn locked_snapshots_are_redacted_and_controls_fail_closed() {
        let manager = ClipboardManager::default();
        let item_id = capture_text(&manager, "secret", ClipboardOrigin::Wayland);
        manager.set_locked(true);
        let response = manager.handle_control_packet(&request(COMMAND_SNAPSHOT, |encoder| {
            encoder.string_u16("");
        }));
        assert_eq!(response_kind(&response), (RESPONSE_SNAPSHOT, STATUS_OK));
        assert_ne!(response[32] & SNAPSHOT_LOCKED, 0);
        assert_eq!(u16::from_le_bytes(response[33..35].try_into().unwrap()), 0);

        let response = manager.handle_control_packet(&request(COMMAND_READ, |encoder| {
            encoder.u64(item_id);
            encoder.string_u16("text/plain;charset=utf-8");
        }));
        assert_eq!(response_kind(&response), (RESPONSE_ERROR, STATUS_LOCKED));
        assert!(manager.current_text().is_none());
    }

    #[test]
    fn malformed_and_oversized_representations_are_rejected() {
        let manager = ClipboardManager::default();
        let plan = manager
            .observe_external_selection(
                ClipboardOrigin::Wayland,
                &["text/plain".to_owned(), "image/png".to_owned()],
                None,
            )
            .unwrap();
        for representation in plan.representations {
            let data = if representation.mime_type == "text/plain" {
                vec![0xff, 0xfe]
            } else {
                b"not a png".to_vec()
            };
            manager.finish_capture(plan.epoch, &representation.mime_type, Some(data));
        }
        assert!(manager.lock().history.is_empty());

        let oversized = vec![b'x'; MAX_TEXT_BYTES + 1];
        assert!(
            validate_representation("text/plain", oversized).is_none(),
            "oversized text must not enter history"
        );
    }

    #[test]
    fn validated_image_formats_publish_dimensions_without_decoding_pixels() {
        let mut png = Vec::from(b"\x89PNG\r\n\x1a\n".as_slice());
        png.extend_from_slice(&13u32.to_be_bytes());
        png.extend_from_slice(b"IHDR");
        png.extend_from_slice(&2u32.to_be_bytes());
        png.extend_from_slice(&3u32.to_be_bytes());
        png.extend_from_slice(&[8, 6, 0, 0, 0]);
        png.extend_from_slice(&0u32.to_be_bytes());
        png.extend_from_slice(&0u32.to_be_bytes());
        png.extend_from_slice(b"IEND");
        png.extend_from_slice(&0u32.to_be_bytes());
        assert_eq!(
            validate_representation("image/png", png)
                .unwrap()
                .dimensions,
            Some((2, 3))
        );

        let jpeg = vec![
            0xff, 0xd8, 0xff, 0xc0, 0x00, 0x11, 8, 0x00, 0x03, 0x00, 0x02, 3, 1, 0x11, 0, 2, 0x11,
            0, 3, 0x11, 0, 0xff, 0xd9,
        ];
        assert_eq!(
            validate_representation("image/jpeg", jpeg)
                .unwrap()
                .dimensions,
            Some((2, 3))
        );

        let mut webp = Vec::from(b"RIFF".as_slice());
        webp.extend_from_slice(&22u32.to_le_bytes());
        webp.extend_from_slice(b"WEBPVP8X");
        webp.extend_from_slice(&10u32.to_le_bytes());
        webp.extend_from_slice(&[0, 0, 0, 0, 1, 0, 0, 2, 0, 0]);
        assert_eq!(
            validate_representation("image/webp", webp)
                .unwrap()
                .dimensions,
            Some((2, 3))
        );
    }

    #[test]
    fn item_count_pin_and_delete_controls_remain_bounded() {
        let manager = ClipboardManager::default();
        for index in 0..(MAX_HISTORY_ITEMS + 5) {
            capture_text(
                &manager,
                &format!("entry {index}"),
                ClipboardOrigin::Wayland,
            );
        }
        assert_eq!(manager.lock().history.len(), MAX_HISTORY_ITEMS);
        let newest = manager.lock().history.front().unwrap().id;
        let response = manager.handle_control_packet(&request(COMMAND_SET_PINNED, |encoder| {
            encoder.u64(newest);
            encoder.u8(1);
        }));
        assert_eq!(response_kind(&response), (RESPONSE_ACK, STATUS_OK));
        assert!(manager.lock().history.front().unwrap().pinned);

        let response = manager.handle_control_packet(&request(COMMAND_DELETE, |encoder| {
            encoder.u64(newest);
        }));
        assert_eq!(response_kind(&response), (RESPONSE_ACK, STATUS_OK));
        assert_eq!(manager.lock().history.len(), MAX_HISTORY_ITEMS - 1);
        assert!(manager.lock().history_item(newest).is_none());
    }

    #[test]
    fn pins_never_weaken_hard_retention_limits() {
        let manager = ClipboardManager::default();
        for index in 0..3 {
            let item_id = capture_text(
                &manager,
                &format!("pinned entry {index}"),
                ClipboardOrigin::Wayland,
            );
            manager.set_pinned(item_id, true).unwrap();
        }
        let newest_ids = manager
            .lock()
            .history
            .iter()
            .take(2)
            .map(|item| item.id)
            .collect::<Vec<_>>();

        let mut state = manager.lock();
        state.enforce_limits_to(2, usize::MAX);
        assert_eq!(state.history.len(), 2);
        assert_eq!(
            state.history.iter().map(|item| item.id).collect::<Vec<_>>(),
            newest_ids
        );
    }

    #[test]
    fn protocol_rejects_trailing_bytes_invalid_ids_and_unknown_versions() {
        let manager = ClipboardManager::default();
        let mut trailing = request(COMMAND_CLEAR, |_| {});
        trailing.push(0);
        assert_eq!(
            response_kind(&manager.handle_control_packet(&trailing)),
            (RESPONSE_ERROR, STATUS_BAD_REQUEST)
        );
        assert_eq!(
            response_kind(
                &manager
                    .handle_control_packet(&request(COMMAND_ACTIVATE, |encoder| encoder.u64(0),))
            ),
            (RESPONSE_ERROR, STATUS_BAD_REQUEST)
        );
        let mut wrong_version = request(COMMAND_CLEAR, |_| {});
        wrong_version[4] = 2;
        assert_eq!(
            response_kind(&manager.handle_control_packet(&wrong_version)),
            (RESPONSE_ERROR, STATUS_BAD_REQUEST)
        );
    }
}
