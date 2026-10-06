import 'package:denial_dart_shell/src/models/desktop_notification.dart';

DesktopNotification notificationFixture({
  int id = 1,
  bool resident = false,
  bool transient = false,
  int timeout = -1,
  DesktopNotificationUrgency urgency = DesktopNotificationUrgency.normal,
  String summary = 'Message title',
}) => DesktopNotification(
  id: id,
  sender: ':1.42',
  appName: '',
  appIcon: '',
  summary: summary,
  body: 'Message body',
  actions: const [
    DesktopNotificationAction(key: 'default', label: 'Open'),
    DesktopNotificationAction(key: 'reply', label: 'Reply'),
  ],
  urgency: urgency,
  category: '',
  desktopEntry: '',
  imagePath: '',
  imageData: null,
  resident: resident,
  transient: transient,
  suppressSound: false,
  actionIcons: false,
  soundName: '',
  soundFile: '',
  x: 0,
  y: 0,
  hasPosition: false,
  progress: 0,
  hasProgress: false,
  expireTimeoutMs: timeout,
);

DesktopNotificationEvent notificationEvent(
  DesktopNotification notification, {
  DesktopNotificationEventKind kind = DesktopNotificationEventKind.added,
}) => DesktopNotificationEvent(
  kind: kind,
  notificationId: notification.id,
  closeReason: 0,
  notification: notification,
);
