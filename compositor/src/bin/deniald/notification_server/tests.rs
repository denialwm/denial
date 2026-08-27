use super::*;
use zbus::zvariant::{Str, Value};

#[allow(clippy::too_many_arguments)]
#[zbus::proxy(
    interface = "org.freedesktop.Notifications",
    default_service = "org.freedesktop.Notifications",
    default_path = "/org/freedesktop/Notifications"
)]
trait NotificationsTest {
    #[zbus(name = "GetCapabilities")]
    fn get_capabilities(&self) -> zbus::Result<Vec<String>>;

    #[zbus(name = "GetServerInformation")]
    fn get_server_information(&self) -> zbus::Result<(String, String, String, String)>;

    #[zbus(name = "Notify")]
    fn notify(
        &self,
        app_name: String,
        replaces_id: u32,
        app_icon: String,
        summary: String,
        body: String,
        actions: Vec<String>,
        hints: HashMap<String, OwnedValue>,
        expire_timeout: i32,
    ) -> zbus::Result<u32>;

    #[zbus(name = "CloseNotification")]
    fn close_notification(&self, id: u32) -> zbus::Result<()>;

    #[zbus(signal, name = "NotificationClosed")]
    fn notification_closed(&self, id: u32, reason: u32) -> zbus::Result<()>;

    #[zbus(signal, name = "ActivationToken")]
    fn activation_token(&self, id: u32, activation_token: &str) -> zbus::Result<()>;

    #[zbus(signal, name = "ActionInvoked")]
    fn action_invoked(&self, id: u32, action_key: &str) -> zbus::Result<()>;
}

fn notification(summary: &str, timeout: i32) -> Notification {
    normalize_notification(
        ":1.42".into(),
        "Denial test".into(),
        "dialog-information".into(),
        summary.into(),
        "Body".into(),
        vec!["default".into(), "Open".into()],
        &HashMap::new(),
        timeout,
    )
}

#[test]
fn bounds_strings_actions_and_known_hints() {
    let mut hints = HashMap::new();
    hints.insert("urgency".into(), OwnedValue::from(9u8));
    hints.insert("resident".into(), OwnedValue::from(true));
    hints.insert("x".into(), OwnedValue::from(12i32));
    hints.insert(
        "category".into(),
        OwnedValue::from(Str::from("device.test")),
    );
    let mut actions = Vec::new();
    for index in 0..24 {
        actions.push(format!("action-{index}"));
        actions.push(format!("Action {index}"));
    }
    actions.extend(["action-0".into(), "Duplicate".into()]);

    let value = normalize_notification(
        ":1.7".into(),
        "App".into(),
        "icon".into(),
        format!("{}é", "x".repeat(MAX_STRING_BYTES - 1)),
        "Body".into(),
        actions,
        &hints,
        -1,
    );

    assert!(value.summary.len() <= MAX_STRING_BYTES);
    assert!(value.summary.is_char_boundary(value.summary.len()));
    assert_eq!(value.actions.len(), MAX_ACTIONS);
    assert_eq!(value.urgency, NotificationUrgency::Critical);
    assert_eq!(value.category, "device.test");
    assert!(value.resident);
    assert!(!value.has_position);
}

#[test]
fn accepts_valid_images_and_rejects_oversized_images() {
    let pixels = vec![0x7f; 12];
    let image = Value::new((2i32, 2i32, 6i32, false, 8i32, 3i32, pixels.clone()));
    let mut hints = HashMap::new();
    hints.insert(
        "image_data".into(),
        OwnedValue::try_from(image).expect("image tuple should be representable"),
    );
    let value = normalize_notification(
        String::new(),
        String::new(),
        String::new(),
        String::new(),
        String::new(),
        Vec::new(),
        &hints,
        -1,
    );
    assert_eq!(value.image_data.expect("valid image").data, pixels);

    let oversized = Value::new((
        1024i32,
        129i32,
        4096i32,
        true,
        8i32,
        4i32,
        vec![0x7f; MAX_IMAGE_DATA_BYTES + 96],
    ));
    hints.insert(
        "image_data".into(),
        OwnedValue::try_from(oversized).expect("image tuple should be representable"),
    );
    assert!(parse_image_data(&hints).is_none());
}

#[test]
fn replaces_expires_evicts_and_resets_actions() {
    let now = Instant::now();
    let mut store = NotificationStore::default();
    let (id, events) = store.notify(0, notification("Original", 25), now);
    assert_eq!(events[0].kind, NotificationEventKind::Added);
    assert!(matches!(
        store.begin_action(id, "default"),
        ActionDecision::Invoke { resident: false }
    ));
    assert!(matches!(
        store.begin_action(id, "default"),
        ActionDecision::AlreadyInvoked
    ));

    let (replaced_id, events) = store.notify(id, notification("Updated", 50), now);
    assert_eq!(replaced_id, id);
    assert_eq!(events[0].kind, NotificationEventKind::Replaced);
    assert!(matches!(
        store.begin_action(id, "default"),
        ActionDecision::Invoke { resident: false }
    ));
    assert!(store.expire_due(now + Duration::from_millis(49)).is_empty());
    let expired = store.expire_due(now + Duration::from_millis(50));
    assert_eq!(expired, vec![NotificationEvent::closed(id, 1)]);

    let mut oldest = 0;
    for index in 0..=MAX_NOTIFICATIONS {
        let (id, events) = store.notify(0, notification(&format!("{index}"), 0), now);
        if index == 0 {
            oldest = id;
        }
        if index == MAX_NOTIFICATIONS {
            assert_eq!(events[0], NotificationEvent::closed(oldest, 4));
            assert_eq!(events[1].kind, NotificationEventKind::Added);
        }
    }
    assert_eq!(store.notifications.len(), MAX_NOTIFICATIONS);
}

#[test]
fn serves_dbus_replacement_expiry_close_and_action_round_trips() {
    if std::env::var_os("DENIAL_NOTIFICATION_TEST_BUS").is_none() {
        return;
    }

    let (event_tx, event_rx) = mpsc::channel();
    let server = NotificationServer::start(move |event, _| {
        let _ = event_tx.send(event);
    })
    .expect("notification service should own the private test bus");
    let client = zbus::blocking::Connection::session().expect("private session bus");
    let proxy = NotificationsTestProxyBlocking::new(&client).expect("notification proxy");
    let mut closed_signals = proxy
        .receive_notification_closed()
        .expect("subscribe to close signals");
    let mut activation_token_signals = proxy
        .receive_activation_token()
        .expect("subscribe to activation-token signals");
    let mut action_signals = proxy
        .receive_action_invoked()
        .expect("subscribe to action signals");

    assert_eq!(
        proxy.get_capabilities().expect("capabilities"),
        ["actions", "body", "icon-static"].map(str::to_owned)
    );
    assert_eq!(
        proxy.get_server_information().expect("server information"),
        (
            "Denial".into(),
            "Denial".into(),
            denial_core::version().into(),
            "1.3".into(),
        )
    );

    let mut hints = HashMap::new();
    hints.insert("resident".into(), OwnedValue::from(true));
    let id = proxy
        .notify(
            "Denial test".into(),
            0,
            "dialog-information".into(),
            "Original".into(),
            "Notification body".into(),
            vec!["default".into(), "Open".into()],
            hints,
            0,
        )
        .expect("send resident notification");
    assert_ne!(id, 0);
    let added = event_rx
        .recv_timeout(Duration::from_secs(1))
        .expect("added event");
    assert_eq!(added.kind, NotificationEventKind::Added);
    assert_eq!(added.notification_id, id);

    let replaced_id = proxy
        .notify(
            "Denial test".into(),
            id,
            "dialog-information".into(),
            "Updated".into(),
            "Replacement body".into(),
            vec!["default".into(), "Open".into()],
            HashMap::from([("resident".into(), OwnedValue::from(true))]),
            0,
        )
        .expect("replace resident notification");
    assert_eq!(replaced_id, id);
    let replaced = event_rx
        .recv_timeout(Duration::from_secs(1))
        .expect("replacement event");
    assert_eq!(replaced.kind, NotificationEventKind::Replaced);
    assert_eq!(
        replaced.notification.expect("replacement value").summary,
        "Updated"
    );

    assert!(server.invoke_default(id, Some("denial-test-token".into())));
    let activation_token = activation_token_signals
        .next()
        .expect("activation-token signal");
    let activation_token = activation_token.args().expect("activation-token arguments");
    assert_eq!(*activation_token.id(), id);
    assert_eq!(*activation_token.activation_token(), "denial-test-token");
    let action = action_signals.next().expect("default action signal");
    let action = action.args().expect("default action arguments");
    assert_eq!(*action.id(), id);
    assert_eq!(*action.action_key(), "default");

    assert!(server.dismiss(id));
    let dismissed = event_rx
        .recv_timeout(Duration::from_secs(1))
        .expect("dismissed event");
    assert_eq!(dismissed, NotificationEvent::closed(id, 2));
    let closed = closed_signals.next().expect("dismiss close signal");
    let closed = closed.args().expect("dismiss close arguments");
    assert_eq!((*closed.id(), *closed.reason()), (id, 2));

    let expiring_id = proxy
        .notify(
            "Denial test".into(),
            0,
            String::new(),
            "Expires".into(),
            String::new(),
            Vec::new(),
            HashMap::new(),
            25,
        )
        .expect("send expiring notification");
    let expiring_added = event_rx
        .recv_timeout(Duration::from_secs(1))
        .expect("expiring added event");
    assert_eq!(expiring_added.notification_id, expiring_id);
    let expired = event_rx
        .recv_timeout(Duration::from_secs(1))
        .expect("expiry event");
    assert_eq!(expired, NotificationEvent::closed(expiring_id, 1));
    let closed = closed_signals.next().expect("expiry close signal");
    let closed = closed.args().expect("expiry close arguments");
    assert_eq!((*closed.id(), *closed.reason()), (expiring_id, 1));

    let client_closed_id = proxy
        .notify(
            "Denial test".into(),
            0,
            String::new(),
            "Client closes".into(),
            String::new(),
            Vec::new(),
            HashMap::new(),
            0,
        )
        .expect("send client-closed notification");
    let _ = event_rx
        .recv_timeout(Duration::from_secs(1))
        .expect("client-closed added event");
    proxy
        .close_notification(client_closed_id)
        .expect("client close notification");
    let client_closed = event_rx
        .recv_timeout(Duration::from_secs(1))
        .expect("client close event");
    assert_eq!(
        client_closed,
        NotificationEvent::closed(client_closed_id, 3)
    );
    let closed = closed_signals.next().expect("client close signal");
    let closed = closed.args().expect("client close arguments");
    assert_eq!((*closed.id(), *closed.reason()), (client_closed_id, 3));

    let error = proxy
        .close_notification(client_closed_id)
        .expect_err("closing an unknown ID must fail");
    assert!(error.to_string().contains("Unknown notification ID"));
}
