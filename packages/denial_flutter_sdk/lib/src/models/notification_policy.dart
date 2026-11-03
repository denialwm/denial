/// What notifications show while the session is locked.
enum NotificationPreviewMode {
  hidden,
  full;

  static NotificationPreviewMode parse(Object? value) {
    return value == 'hidden'
        ? NotificationPreviewMode.hidden
        : NotificationPreviewMode.full;
  }
}
