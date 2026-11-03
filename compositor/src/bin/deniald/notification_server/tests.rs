use super::*;
use zbus::zvariant::Value;

fn notification(urgency: u8, expire_timeout_ms: i32) -> Notification {
    let hints = HashMap::from([("urgency".to_owned(), OwnedValue::from(urgency))]);
    normalize_notification(
        String::new(),
        "app".into(),
        String::new(),
        "summary".into(),
        "body".into(),
        Vec::new(),
        &hints,
        expire_timeout_ms,
    )
}

fn transient(urgency: u8, expire_timeout_ms: i32) -> Notification {
    Notification {
        transient: true,
        ..notification(urgency, expire_timeout_ms)
    }
}

#[test]
fn ordinary_notifications_never_expire() {
    let now = Instant::now();
    let later = now + Duration::from_secs(3600);
    for (urgency, timeout) in [(0, -1), (1, -1), (1, 2000), (2, -1)] {
        let mut store = NotificationStore::default();
        store.notify(0, notification(urgency, timeout), None, now);
        assert_eq!(store.next_deadline(), None);
        assert!(store.expire_due(later).is_empty());
    }
}

#[test]
fn transient_notifications_expire_as_expired() {
    let now = Instant::now();
    let mut store = NotificationStore::default();
    let (low, _) = store.notify(0, transient(0, -1), None, now);
    let (explicit, _) = store.notify(0, transient(1, 1500), None, now);
    assert_eq!(
        store.next_deadline(),
        Some(now + Duration::from_millis(1500))
    );

    let expired = store.expire_due(now + LOW_DEFAULT_TIMEOUT);
    assert_eq!(
        expired,
        [
            NotificationEvent::closed(low, 1),
            NotificationEvent::closed(explicit, 1),
        ]
    );
}

#[test]
fn transient_notifications_that_must_stay_never_expire() {
    let now = Instant::now();
    for notification in [
        transient(2, -1),
        transient(1, 0),
        Notification {
            resident: true,
            ..transient(1, 1000)
        },
    ] {
        let mut store = NotificationStore::default();
        store.notify(0, notification, None, now);
        assert_eq!(store.next_deadline(), None);
    }
}

#[test]
fn replacing_keeps_the_id_without_a_deadline() {
    let now = Instant::now();
    let mut store = NotificationStore::default();
    let (id, _) = store.notify(0, notification(1, -1), None, now);
    let (replaced, events) = store.notify(id, notification(1, -1), None, now);
    assert_eq!(replaced, id);
    assert_eq!(events[0].kind, NotificationEventKind::Replaced);
    assert_eq!(store.next_deadline(), None);
}

#[test]
fn updates_alert_only_when_their_content_changes() {
    let now = Instant::now();
    let mut store = NotificationStore::default();
    let (id, events) = store.notify(0, notification(1, -1), None, now);
    assert!(events[0].notification.as_ref().unwrap().alert);

    let progress = Notification {
        progress: 40,
        has_progress: true,
        ..notification(1, -1)
    };
    let (_, events) = store.notify(id, progress, None, now);
    assert!(!events[0].notification.as_ref().unwrap().alert);

    let reworded = Notification {
        body: "new body".into(),
        ..notification(1, -1)
    };
    let (_, events) = store.notify(id, reworded, None, now);
    assert!(events[0].notification.as_ref().unwrap().alert);
}

#[test]
fn the_sender_can_decide_whether_a_post_alerts() {
    let now = Instant::now();
    let mut store = NotificationStore::default();
    let (id, events) = store.notify(0, notification(1, -1), Some(false), now);
    assert!(!events[0].notification.as_ref().unwrap().alert);
    let (_, events) = store.notify(id, notification(1, -1), Some(true), now);
    assert!(events[0].notification.as_ref().unwrap().alert);
}

#[test]
fn replays_are_quiet_and_oldest_first() {
    let now = Instant::now();
    let mut store = NotificationStore::default();
    let (first, _) = store.notify(0, notification(1, -1), None, now);
    let (second, _) = store.notify(0, notification(1, -1), None, now);
    let replay = store.replay();
    assert_eq!(
        replay
            .iter()
            .map(|event| (event.kind, event.notification_id))
            .collect::<Vec<_>>(),
        [
            (NotificationEventKind::Added, first),
            (NotificationEventKind::Added, second),
        ]
    );
    assert!(
        replay
            .iter()
            .all(|event| !event.notification.as_ref().unwrap().alert)
    );
}

fn hinted(app_name: &str, hints: Vec<(&str, OwnedValue)>) -> Notification {
    let hints = hints
        .into_iter()
        .map(|(key, value)| (key.to_owned(), value))
        .collect();
    normalize_notification(
        ":1.7".into(),
        app_name.into(),
        String::new(),
        "summary".into(),
        "body".into(),
        Vec::new(),
        &hints,
        -1,
    )
}

#[test]
fn groups_stay_inside_their_app() {
    assert_eq!(hinted("Mail", Vec::new()).group_key, "Mail");
    assert_eq!(hinted("", Vec::new()).group_key, ":1.7");
    let entry = || OwnedValue::try_from(Value::from("org.example.Chat")).unwrap();
    assert_eq!(
        hinted("Chat", vec![("desktop-entry", entry())]).group_key,
        "org.example.Chat"
    );
    let conversation = hinted(
        "Chat",
        vec![
            ("desktop-entry", entry()),
            (
                "x-denial-group",
                OwnedValue::try_from(Value::from("ana")).unwrap(),
            ),
            ("x-denial-group-summary", OwnedValue::from(true)),
        ],
    );
    assert_eq!(conversation.group_key, "org.example.Chat\nana");
    assert!(conversation.group_summary);
}

#[test]
fn time_comes_from_the_sender_or_arrival() {
    let sent = hinted(
        "Chat",
        vec![("x-denial-time", OwnedValue::from(1_700_000_000_000_i64))],
    );
    assert_eq!(sent.time_ms, 1_700_000_000_000);
    assert!(hinted("Chat", Vec::new()).time_ms > 1_700_000_000_000);
}

#[test]
fn only_the_latest_messages_are_kept() {
    let messages = (0..7)
        .map(|index| (format!("sender {index}"), format!("text {index}")))
        .collect::<Vec<_>>();
    let chat = hinted(
        "Chat",
        vec![(
            "x-denial-messages",
            OwnedValue::try_from(Value::from(messages)).unwrap(),
        )],
    );
    let texts = chat
        .messages
        .iter()
        .map(|message| message.text.as_str())
        .collect::<Vec<_>>();
    assert_eq!(texts, ["text 2", "text 3", "text 4", "text 5", "text 6"]);
    assert_eq!(chat.messages[0].sender, "sender 2");
}

#[test]
fn actions_leave_notifications_the_user_cannot_clear() {
    let mut store = NotificationStore::default();
    for clearable in [true, false] {
        let hints = HashMap::from([("x-denial-clearable".to_owned(), OwnedValue::from(clearable))]);
        let notification = normalize_notification(
            String::new(),
            "app".into(),
            String::new(),
            "summary".into(),
            "body".into(),
            vec!["default".into(), "Open".into()],
            &hints,
            -1,
        );
        assert_eq!(notification.clearable, clearable);
        let (id, _) = store.notify(0, notification, None, Instant::now());
        assert!(matches!(
            store.begin_action(id, "default"),
            ActionDecision::Invoke { resident } if resident != clearable
        ));
    }
}
