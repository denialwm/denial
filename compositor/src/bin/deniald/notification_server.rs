//! Native `org.freedesktop.Notifications` ownership.
//!
//! D-Bus dispatch runs on zbus's internal executor, but all mutable
//! notification state, expiry scheduling, and signal ordering live on one
//! dedicated worker. Interface methods enqueue bounded requests and await a
//! small in-process reply future, so neither the compositor nor the zbus
//! executor blocks on notification work.

use std::collections::{HashMap, HashSet, VecDeque};
use std::error::Error;
use std::fmt;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, SyncSender, TrySendError};
use std::sync::{Arc, Mutex, MutexGuard};
use std::task::{Context, Poll, Waker};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use tracing::{info, warn};
use zbus::blocking::Connection;
use zbus::blocking::connection::Builder as ConnectionBuilder;
use zbus::message::Header;
use zbus::object_server::SignalEmitter;
use zbus::zvariant::OwnedValue;

const SERVICE_NAME: &str = "org.freedesktop.Notifications";
const OBJECT_PATH: &str = "/org/freedesktop/Notifications";
const INTERFACE_NAME: &str = "org.freedesktop.Notifications";

const MAX_STRING_BYTES: usize = 4096;
const MAX_ACTIONS: usize = 16;
const MAX_IMAGE_DATA_BYTES: usize = 512 * 1024;
const MAX_NOTIFICATIONS: usize = 256;
const COMMAND_QUEUE_CAPACITY: usize = 128;
const LOW_DEFAULT_TIMEOUT: Duration = Duration::from_secs(4);
const NORMAL_DEFAULT_TIMEOUT: Duration = Duration::from_secs(7);

type EventCallback = Arc<dyn Fn(NotificationEvent, &AtomicBool) + Send + Sync>;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum NotificationEventKind {
    Added,
    Replaced,
    Closed,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum NotificationUrgency {
    Low,
    Normal,
    Critical,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct NotificationAction {
    pub(super) key: String,
    pub(super) label: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct NotificationImageData {
    pub(super) width: u32,
    pub(super) height: u32,
    pub(super) row_stride: u32,
    pub(super) has_alpha: bool,
    pub(super) bits_per_sample: u8,
    pub(super) channels: u8,
    pub(super) data: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct Notification {
    pub(super) id: u32,
    pub(super) sender: String,
    pub(super) app_name: String,
    pub(super) app_icon: String,
    pub(super) summary: String,
    pub(super) body: String,
    pub(super) actions: Vec<NotificationAction>,
    pub(super) urgency: NotificationUrgency,
    pub(super) category: String,
    pub(super) desktop_entry: String,
    pub(super) image_path: String,
    pub(super) image_data: Option<NotificationImageData>,
    pub(super) resident: bool,
    pub(super) transient: bool,
    pub(super) suppress_sound: bool,
    pub(super) action_icons: bool,
    pub(super) sound_name: String,
    pub(super) sound_file: String,
    pub(super) x: i32,
    pub(super) y: i32,
    pub(super) has_position: bool,
    pub(super) progress: i32,
    pub(super) has_progress: bool,
    pub(super) expire_timeout_ms: i32,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct NotificationEvent {
    pub(super) kind: NotificationEventKind,
    pub(super) notification: Option<Notification>,
    pub(super) notification_id: u32,
    pub(super) close_reason: u32,
}

impl NotificationEvent {
    fn published(kind: NotificationEventKind, notification: Notification) -> Self {
        let notification_id = notification.id;
        Self {
            kind,
            notification: Some(notification),
            notification_id,
            close_reason: 0,
        }
    }

    fn closed(notification_id: u32, close_reason: u32) -> Self {
        Self {
            kind: NotificationEventKind::Closed,
            notification: None,
            notification_id,
            close_reason,
        }
    }
}

#[derive(Debug)]
pub(super) struct NotificationServerError(String);

impl fmt::Display for NotificationServerError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl Error for NotificationServerError {}

/// Process-lifetime handle used by the compositor event loop.
pub(super) struct NotificationServer {
    commands: SyncSender<Command>,
    stopping: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
}

impl NotificationServer {
    pub(super) fn start(
        publish: impl Fn(NotificationEvent, &AtomicBool) + Send + Sync + 'static,
    ) -> Result<Self, NotificationServerError> {
        let (commands, command_rx) = mpsc::sync_channel(COMMAND_QUEUE_CAPACITY);
        let (ready_tx, ready_rx) = mpsc::sync_channel(1);
        let publish: EventCallback = Arc::new(publish);
        let stopping = Arc::new(AtomicBool::new(false));
        let worker = thread::Builder::new()
            .name("denial-notifications".into())
            .spawn({
                let commands = commands.clone();
                let stopping = Arc::clone(&stopping);
                move || {
                    crate::cpu_scheduling::normalize_current_worker("notifications");
                    run_worker(command_rx, commands, publish, stopping, ready_tx);
                }
            })
            .map_err(|error| {
                NotificationServerError(format!("could not spawn the notification worker: {error}"))
            })?;

        match ready_rx.recv() {
            Ok(Ok(())) => Ok(Self {
                commands,
                stopping,
                worker: Some(worker),
            }),
            Ok(Err(error)) => {
                let _ = worker.join();
                Err(NotificationServerError(error))
            }
            Err(_) => {
                let _ = worker.join();
                Err(NotificationServerError(
                    "notification worker stopped during startup".into(),
                ))
            }
        }
    }

    pub(super) fn dismiss(&self, notification_id: u32) -> bool {
        notification_id != 0
            && self
                .commands
                .try_send(Command::Dismiss { notification_id })
                .is_ok()
    }

    pub(super) fn invoke_action(
        &self,
        notification_id: u32,
        action_key: String,
        activation_token: Option<String>,
    ) -> bool {
        notification_id != 0
            && !action_key.is_empty()
            && action_key.len() <= MAX_STRING_BYTES
            && self
                .commands
                .try_send(Command::InvokeAction {
                    notification_id,
                    action_key,
                    activation_token,
                })
                .is_ok()
    }

    pub(super) fn invoke_default(
        &self,
        notification_id: u32,
        activation_token: Option<String>,
    ) -> bool {
        self.invoke_action(notification_id, "default".into(), activation_token)
    }
}

impl Drop for NotificationServer {
    fn drop(&mut self) {
        self.stopping.store(true, Ordering::Release);
        let _ = self.commands.send(Command::Stop);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

#[derive(Debug, zbus::DBusError)]
#[zbus(prefix = "org.freedesktop.Notifications.Error", impl_display = true)]
enum NotificationMethodError {
    UnknownNotification(String),
    Failed(String),
}

struct NotificationsInterface {
    commands: SyncSender<Command>,
    stopping: Arc<AtomicBool>,
}

impl NotificationsInterface {
    async fn request<T>(
        &self,
        command: impl FnOnce(ReplySender<T>) -> Command,
    ) -> Result<T, NotificationMethodError> {
        if self.stopping.load(Ordering::Acquire) {
            return Err(NotificationMethodError::Failed(
                "notification worker is shutting down".into(),
            ));
        }
        let (reply, response) = reply_channel();
        self.commands
            .try_send(command(reply))
            .map_err(queue_method_error)?;
        Ok(response.await)
    }
}

#[zbus::interface(
    name = "org.freedesktop.Notifications",
    spawn = false,
    introspection_docs = false
)]
impl NotificationsInterface {
    #[zbus(name = "GetCapabilities", out_args("capabilities"))]
    fn get_capabilities(&self) -> Vec<String> {
        ["actions", "body", "icon-static"]
            .into_iter()
            .map(str::to_owned)
            .collect()
    }

    #[zbus(
        name = "GetServerInformation",
        out_args("name", "vendor", "version", "spec_version")
    )]
    fn get_server_information(&self) -> (&'static str, &'static str, &'static str, &'static str) {
        ("Denial", "Denial", denial_core::version(), "1.3")
    }

    #[zbus(name = "Notify", out_args("id"))]
    #[allow(clippy::too_many_arguments)]
    async fn notify(
        &self,
        app_name: String,
        replaces_id: u32,
        app_icon: String,
        summary: String,
        body: String,
        actions: Vec<String>,
        hints: HashMap<String, OwnedValue>,
        expire_timeout: i32,
        #[zbus(header)] header: Header<'_>,
    ) -> Result<u32, NotificationMethodError> {
        let sender = header.sender().map(ToString::to_string).unwrap_or_default();
        let notification = normalize_notification(
            sender,
            app_name,
            app_icon,
            summary,
            body,
            actions,
            &hints,
            expire_timeout,
        );
        self.request(|reply| Command::Notify {
            replaces_id,
            notification: Box::new(notification),
            reply,
        })
        .await
    }

    #[zbus(name = "CloseNotification")]
    async fn close_notification(&self, id: u32) -> Result<(), NotificationMethodError> {
        self.request(|reply| Command::Close {
            notification_id: id,
            reply,
        })
        .await?
    }

    #[zbus(signal, name = "NotificationClosed")]
    async fn notification_closed(
        signal_emitter: &SignalEmitter<'_>,
        id: u32,
        reason: u32,
    ) -> zbus::Result<()>;

    #[zbus(signal, name = "ActivationToken")]
    async fn activation_token(
        signal_emitter: &SignalEmitter<'_>,
        id: u32,
        activation_token: &str,
    ) -> zbus::Result<()>;

    #[zbus(signal, name = "ActionInvoked")]
    async fn action_invoked(
        signal_emitter: &SignalEmitter<'_>,
        id: u32,
        action_key: &str,
    ) -> zbus::Result<()>;
}

fn queue_method_error<T>(error: TrySendError<T>) -> NotificationMethodError {
    let detail = match error {
        TrySendError::Full(_) => "notification command queue is full",
        TrySendError::Disconnected(_) => "notification worker is unavailable",
    };
    NotificationMethodError::Failed(detail.into())
}

enum Command {
    Notify {
        replaces_id: u32,
        notification: Box<Notification>,
        reply: ReplySender<u32>,
    },
    Close {
        notification_id: u32,
        reply: ReplySender<Result<(), NotificationMethodError>>,
    },
    Dismiss {
        notification_id: u32,
    },
    InvokeAction {
        notification_id: u32,
        action_key: String,
        activation_token: Option<String>,
    },
    Stop,
}

fn run_worker(
    commands: Receiver<Command>,
    interface_commands: SyncSender<Command>,
    publish: EventCallback,
    stopping: Arc<AtomicBool>,
    ready: SyncSender<Result<(), String>>,
) {
    let interface = NotificationsInterface {
        commands: interface_commands,
        stopping: Arc::clone(&stopping),
    };
    let connection = match ConnectionBuilder::session()
        .and_then(|builder| builder.name(SERVICE_NAME))
        .and_then(|builder| builder.serve_at(OBJECT_PATH, interface))
        .and_then(ConnectionBuilder::build)
    {
        Ok(connection) => connection,
        Err(error) => {
            let _ = ready.send(Err(format!(
                "could not own {SERVICE_NAME} on the session bus: {error}"
            )));
            return;
        }
    };
    let _ = ready.send(Ok(()));
    info!(
        service = SERVICE_NAME,
        "Denial notification service acquired D-Bus name"
    );

    let mut store = NotificationStore::default();
    loop {
        let received = match store.next_deadline() {
            Some(deadline) => {
                commands.recv_timeout(deadline.saturating_duration_since(Instant::now()))
            }
            None => commands.recv().map_err(|_| RecvTimeoutError::Disconnected),
        };

        match received {
            Ok(Command::Notify {
                replaces_id,
                notification,
                reply,
            }) => {
                let (id, events) = store.notify(replaces_id, *notification, Instant::now());
                publish_events(&connection, &publish, &stopping, events);
                reply.send(id);
            }
            Ok(Command::Close {
                notification_id,
                reply,
            }) => {
                if let Some(event) = store.close(notification_id, 3) {
                    publish_event(&connection, &publish, &stopping, event);
                    reply.send(Ok(()));
                } else {
                    reply.send(Err(NotificationMethodError::UnknownNotification(
                        "Unknown notification ID".into(),
                    )));
                }
            }
            Ok(Command::Dismiss { notification_id }) => {
                if let Some(event) = store.close(notification_id, 2) {
                    publish_event(&connection, &publish, &stopping, event);
                } else {
                    warn!(
                        notification_id,
                        "ignored notification dismiss for unknown ID"
                    );
                }
            }
            Ok(Command::InvokeAction {
                notification_id,
                action_key,
                activation_token,
            }) => invoke_action(
                &connection,
                &publish,
                &stopping,
                &mut store,
                notification_id,
                action_key,
                activation_token.as_deref(),
            ),
            Ok(Command::Stop) | Err(RecvTimeoutError::Disconnected) => break,
            Err(RecvTimeoutError::Timeout) => {}
        }

        let expired = store.expire_due(Instant::now());
        publish_events(&connection, &publish, &stopping, expired);
    }
}

fn invoke_action(
    connection: &Connection,
    publish: &EventCallback,
    stopping: &AtomicBool,
    store: &mut NotificationStore,
    notification_id: u32,
    action_key: String,
    activation_token: Option<&str>,
) {
    let resident = match store.begin_action(notification_id, &action_key) {
        ActionDecision::Invoke { resident } => resident,
        ActionDecision::AlreadyInvoked => return,
        ActionDecision::UnknownNotification => {
            warn!(
                notification_id,
                "ignored action for unknown notification ID"
            );
            return;
        }
        ActionDecision::UnknownAction => {
            warn!(
                notification_id,
                action_key, "ignored unknown notification action"
            );
            return;
        }
    };

    if let Some(activation_token) = activation_token
        && let Err(error) = connection.emit_signal(
            None::<&str>,
            OBJECT_PATH,
            INTERFACE_NAME,
            "ActivationToken",
            &(notification_id, activation_token),
        )
    {
        warn!(notification_id, %error, "failed to emit notification activation token");
    }

    if let Err(error) = connection.emit_signal(
        None::<&str>,
        OBJECT_PATH,
        INTERFACE_NAME,
        "ActionInvoked",
        &(notification_id, action_key.as_str()),
    ) {
        store.rollback_action(notification_id, &action_key);
        warn!(notification_id, %error, "failed to emit notification action signal");
        return;
    }

    if !resident && let Some(event) = store.close(notification_id, 2) {
        publish_event(connection, publish, stopping, event);
    }
}

fn publish_events(
    connection: &Connection,
    publish: &EventCallback,
    stopping: &AtomicBool,
    events: impl IntoIterator<Item = NotificationEvent>,
) {
    for event in events {
        publish_event(connection, publish, stopping, event);
    }
}

fn publish_event(
    connection: &Connection,
    publish: &EventCallback,
    stopping: &AtomicBool,
    event: NotificationEvent,
) {
    let closed = (event.kind == NotificationEventKind::Closed)
        .then_some((event.notification_id, event.close_reason));
    publish(event, stopping);
    let Some((notification_id, reason)) = closed else {
        return;
    };
    if let Err(error) = connection.emit_signal(
        None::<&str>,
        OBJECT_PATH,
        INTERFACE_NAME,
        "NotificationClosed",
        &(notification_id, reason),
    ) {
        warn!(notification_id, reason, %error, "failed to emit notification close signal");
    }
}

#[derive(Default)]
struct NotificationStore {
    notifications: HashMap<u32, StoredNotification>,
    order: VecDeque<u32>,
    next_id: u32,
}

struct StoredNotification {
    notification: Notification,
    expires_at: Option<Instant>,
    invoked_actions: HashSet<String>,
}

impl NotificationStore {
    fn notify(
        &mut self,
        replaces_id: u32,
        mut notification: Notification,
        now: Instant,
    ) -> (u32, Vec<NotificationEvent>) {
        let replacing = replaces_id != 0 && self.notifications.contains_key(&replaces_id);
        let mut events = Vec::with_capacity(2);
        if !replacing
            && self.notifications.len() >= MAX_NOTIFICATIONS
            && let Some(oldest) = self.order.front().copied()
            && let Some(event) = self.close(oldest, 4)
        {
            events.push(event);
        }

        let id = if replacing {
            replaces_id
        } else {
            self.next_notification_id()
        };
        notification.id = id;
        let expires_at =
            effective_timeout(&notification).and_then(|timeout| now.checked_add(timeout));
        self.notifications.insert(
            id,
            StoredNotification {
                notification: notification.clone(),
                expires_at,
                invoked_actions: HashSet::new(),
            },
        );
        if !replacing {
            self.order.push_back(id);
        }
        events.push(NotificationEvent::published(
            if replacing {
                NotificationEventKind::Replaced
            } else {
                NotificationEventKind::Added
            },
            notification,
        ));
        (id, events)
    }

    fn close(&mut self, notification_id: u32, reason: u32) -> Option<NotificationEvent> {
        self.notifications.remove(&notification_id)?;
        self.order.retain(|candidate| *candidate != notification_id);
        Some(NotificationEvent::closed(notification_id, reason))
    }

    fn expire_due(&mut self, now: Instant) -> Vec<NotificationEvent> {
        let expired = self
            .order
            .iter()
            .copied()
            .filter(|id| {
                self.notifications
                    .get(id)
                    .and_then(|stored| stored.expires_at)
                    .is_some_and(|deadline| deadline <= now)
            })
            .collect::<Vec<_>>();
        expired
            .into_iter()
            .filter_map(|id| self.close(id, 1))
            .collect()
    }

    fn next_deadline(&self) -> Option<Instant> {
        self.notifications
            .values()
            .filter_map(|stored| stored.expires_at)
            .min()
    }

    fn begin_action(&mut self, notification_id: u32, action_key: &str) -> ActionDecision {
        let Some(stored) = self.notifications.get_mut(&notification_id) else {
            return ActionDecision::UnknownNotification;
        };
        if !stored
            .notification
            .actions
            .iter()
            .any(|action| action.key == action_key)
        {
            return ActionDecision::UnknownAction;
        }
        if !stored.invoked_actions.insert(action_key.to_owned()) {
            return ActionDecision::AlreadyInvoked;
        }
        ActionDecision::Invoke {
            resident: stored.notification.resident,
        }
    }

    fn rollback_action(&mut self, notification_id: u32, action_key: &str) {
        if let Some(stored) = self.notifications.get_mut(&notification_id) {
            stored.invoked_actions.remove(action_key);
        }
    }

    fn next_notification_id(&mut self) -> u32 {
        loop {
            self.next_id = self.next_id.wrapping_add(1).max(1);
            if !self.notifications.contains_key(&self.next_id) {
                return self.next_id;
            }
        }
    }
}

enum ActionDecision {
    Invoke { resident: bool },
    AlreadyInvoked,
    UnknownNotification,
    UnknownAction,
}

fn effective_timeout(notification: &Notification) -> Option<Duration> {
    if notification.urgency == NotificationUrgency::Critical || notification.expire_timeout_ms == 0
    {
        return None;
    }
    if notification.expire_timeout_ms > 0 {
        return Some(Duration::from_millis(notification.expire_timeout_ms as u64));
    }
    Some(if notification.urgency == NotificationUrgency::Low {
        LOW_DEFAULT_TIMEOUT
    } else {
        NORMAL_DEFAULT_TIMEOUT
    })
}

#[allow(clippy::too_many_arguments)]
fn normalize_notification(
    sender: String,
    app_name: String,
    app_icon: String,
    summary: String,
    body: String,
    actions: Vec<String>,
    hints: &HashMap<String, OwnedValue>,
    expire_timeout_ms: i32,
) -> Notification {
    let urgency = hints
        .get("urgency")
        .and_then(|value| u8::try_from(value).ok())
        .map_or(NotificationUrgency::Normal, |value| match value.min(2) {
            0 => NotificationUrgency::Low,
            1 => NotificationUrgency::Normal,
            _ => NotificationUrgency::Critical,
        });
    let x = hint_i32(hints, "x");
    let y = hint_i32(hints, "y");
    let (x, y, has_position) = match (x, y) {
        (Some(x), Some(y)) => (x, y, true),
        _ => (0, 0, false),
    };
    let progress = hint_i32(hints, "value");
    let image_path = {
        let preferred = hint_string(hints, "image-path");
        if preferred.is_empty() {
            hint_string(hints, "image_path")
        } else {
            preferred
        }
    };

    Notification {
        id: 0,
        sender: bounded_string(sender),
        app_name: bounded_string(app_name),
        app_icon: bounded_string(app_icon),
        summary: bounded_string(summary),
        body: bounded_string(body),
        actions: normalize_actions(actions),
        urgency,
        category: hint_string(hints, "category"),
        desktop_entry: hint_string(hints, "desktop-entry"),
        image_path,
        image_data: parse_image_data(hints),
        resident: hint_bool(hints, "resident"),
        transient: hint_bool(hints, "transient"),
        suppress_sound: hint_bool(hints, "suppress-sound"),
        action_icons: hint_bool(hints, "action-icons"),
        sound_name: hint_string(hints, "sound-name"),
        sound_file: hint_string(hints, "sound-file"),
        x,
        y,
        has_position,
        progress: progress.unwrap_or_default().clamp(0, 100),
        has_progress: progress.is_some(),
        expire_timeout_ms,
    }
}

fn normalize_actions(actions: Vec<String>) -> Vec<NotificationAction> {
    let mut normalized = Vec::with_capacity(MAX_ACTIONS.min(actions.len() / 2));
    let mut keys = HashSet::with_capacity(normalized.capacity());
    for pair in actions.as_chunks::<2>().0 {
        if normalized.len() >= MAX_ACTIONS {
            break;
        }
        let key = bounded_str(&pair[0]);
        if key.is_empty() || !keys.insert(key.clone()) {
            continue;
        }
        normalized.push(NotificationAction {
            key,
            label: bounded_str(&pair[1]),
        });
    }
    normalized
}

fn parse_image_data(hints: &HashMap<String, OwnedValue>) -> Option<NotificationImageData> {
    type RawImage = (i32, i32, i32, bool, i32, i32, Vec<u8>);

    let (width, height, row_stride, has_alpha, bits_per_sample, channels, data) =
        ["image-data", "image_data", "icon_data"]
            .into_iter()
            .find_map(|key| {
                hints
                    .get(key)
                    .and_then(|value| value.try_clone().ok())
                    .and_then(|value| RawImage::try_from(value).ok())
            })?;
    let expected_channels = if has_alpha { 4 } else { 3 };
    if width <= 0
        || height <= 0
        || width > 4096
        || height > 4096
        || channels != expected_channels
        || bits_per_sample != 8
    {
        return None;
    }
    let minimum_stride = width.checked_mul(channels)?;
    if row_stride < minimum_stride {
        return None;
    }
    let required_bytes = usize::try_from(row_stride)
        .ok()?
        .checked_mul(usize::try_from(height).ok()?)?;
    if required_bytes > MAX_IMAGE_DATA_BYTES || required_bytes > data.len() {
        return None;
    }
    Some(NotificationImageData {
        width: width as u32,
        height: height as u32,
        row_stride: row_stride as u32,
        has_alpha,
        bits_per_sample: bits_per_sample as u8,
        channels: channels as u8,
        data: data[..required_bytes].to_vec(),
    })
}

fn hint_bool(hints: &HashMap<String, OwnedValue>, key: &str) -> bool {
    hints
        .get(key)
        .and_then(|value| bool::try_from(value).ok())
        .unwrap_or(false)
}

fn hint_i32(hints: &HashMap<String, OwnedValue>, key: &str) -> Option<i32> {
    hints.get(key).and_then(|value| i32::try_from(value).ok())
}

fn hint_string(hints: &HashMap<String, OwnedValue>, key: &str) -> String {
    hints
        .get(key)
        .and_then(|value| <&str>::try_from(value).ok())
        .map_or_else(String::new, bounded_str)
}

fn bounded_string(value: String) -> String {
    if value.len() <= MAX_STRING_BYTES {
        value
    } else {
        bounded_str(&value)
    }
}

fn bounded_str(value: &str) -> String {
    let mut end = value.len().min(MAX_STRING_BYTES);
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_owned()
}

struct ReplyState<T> {
    value: Option<T>,
    waker: Option<Waker>,
}

struct ReplySender<T>(Arc<Mutex<ReplyState<T>>>);

struct ReplyReceiver<T>(Arc<Mutex<ReplyState<T>>>);

fn reply_channel<T>() -> (ReplySender<T>, ReplyReceiver<T>) {
    let state = Arc::new(Mutex::new(ReplyState {
        value: None,
        waker: None,
    }));
    (ReplySender(Arc::clone(&state)), ReplyReceiver(state))
}

impl<T> ReplySender<T> {
    fn send(self, value: T) {
        let waker = {
            let mut state = lock(&self.0);
            state.value = Some(value);
            state.waker.take()
        };
        if let Some(waker) = waker {
            waker.wake();
        }
    }
}

impl<T> Future for ReplyReceiver<T> {
    type Output = T;

    fn poll(self: Pin<&mut Self>, context: &mut Context<'_>) -> Poll<Self::Output> {
        let mut state = lock(&self.0);
        if let Some(value) = state.value.take() {
            Poll::Ready(value)
        } else {
            let replace = state
                .waker
                .as_ref()
                .is_none_or(|waker| !waker.will_wake(context.waker()));
            if replace {
                state.waker = Some(context.waker().clone());
            }
            Poll::Pending
        }
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[cfg(test)]
#[allow(clippy::too_many_arguments)]
#[path = "notification_server/tests.rs"]
mod tests;
