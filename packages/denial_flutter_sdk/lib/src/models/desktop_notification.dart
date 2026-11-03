import 'dart:typed_data';

enum DesktopNotificationEventKind { added, replaced, closed }

enum DesktopNotificationUrgency { low, normal, critical }

class DesktopNotificationAction {
  const DesktopNotificationAction({required this.key, required this.label});

  final String key;
  final String label;
}

/// One message of a conversation, as the sender showed it.
class DesktopNotificationMessage {
  const DesktopNotificationMessage({required this.sender, required this.text});

  final String sender;
  final String text;
}

class DesktopNotificationImageData {
  const DesktopNotificationImageData({
    required this.width,
    required this.height,
    required this.rowStride,
    required this.hasAlpha,
    required this.bitsPerSample,
    required this.channels,
    required this.data,
  });

  final int width;
  final int height;
  final int rowStride;
  final bool hasAlpha;
  final int bitsPerSample;
  final int channels;
  final Uint8List data;
}

class DesktopNotification {
  const DesktopNotification({
    required this.id,
    required this.sender,
    required this.appName,
    required this.appIcon,
    required this.summary,
    required this.body,
    required this.actions,
    required this.urgency,
    required this.category,
    required this.desktopEntry,
    required this.imagePath,
    required this.imageData,
    required this.resident,
    required this.transient,
    required this.suppressSound,
    required this.actionIcons,
    required this.soundName,
    required this.soundFile,
    required this.x,
    required this.y,
    required this.hasPosition,
    required this.progress,
    required this.hasProgress,
    required this.expireTimeoutMs,
    this.alert = true,
    this.groupKey = '',
    this.groupSummary = false,
    this.timeMs = 0,
    this.messages = const [],
    this.clearable = true,
  });

  final int id;
  final String sender;
  final String appName;
  final String appIcon;
  final String summary;
  final String body;
  final List<DesktopNotificationAction> actions;
  final DesktopNotificationUrgency urgency;
  final String category;
  final String desktopEntry;
  final String imagePath;
  final DesktopNotificationImageData? imageData;
  final bool resident;
  final bool transient;
  final bool suppressSound;
  final bool actionIcons;
  final String soundName;
  final String soundFile;
  final int x;
  final int y;
  final bool hasPosition;
  final int progress;
  final bool hasProgress;
  final int expireTimeoutMs;

  /// Whether this post shows a banner and wakes the screen. deniald clears it
  /// for replays and for updates that change no content.
  final bool alert;

  /// Notifications with the same key belong together; deniald keeps keys
  /// inside one app.
  final String groupKey;

  /// Stands for its group instead of being one of its members.
  final bool groupSummary;

  /// When the sender says this happened, in milliseconds since the epoch.
  final int timeMs;

  /// The latest messages of a conversation, oldest first.
  final List<DesktopNotificationMessage> messages;

  /// The group key, or one of its own when the sender gave none.
  String get groupingKey => groupKey.isEmpty ? '\u0000$id' : groupKey;

  /// False when the user can't dismiss it; it leaves when its app closes it.
  final bool clearable;

  /// Ongoing notifications belong in history, without a heads-up banner.
  bool get historyOnly => resident || expireTimeoutMs == 0;

  /// A tap opens something: the default action, else the desktop entry's app.
  bool get opensApp =>
      desktopEntry.isNotEmpty ||
      actions.any((action) => action.key == 'default');

  /// How long a desktop banner stays up; null keeps it until dismissed.
  /// The notification itself stays in history either way.
  Duration? get bannerDuration {
    if (urgency == DesktopNotificationUrgency.critical) return null;
    if (expireTimeoutMs > 0) return Duration(milliseconds: expireTimeoutMs);
    return urgency == DesktopNotificationUrgency.low
        ? const Duration(seconds: 4)
        : const Duration(seconds: 7);
  }
}

class DesktopNotificationEvent {
  const DesktopNotificationEvent({
    required this.kind,
    required this.notificationId,
    required this.closeReason,
    this.notification,
  });

  final DesktopNotificationEventKind kind;
  final DesktopNotification? notification;
  final int notificationId;
  final int closeReason;

  String toReadableString() {
    final output = StringBuffer()
      ..writeln('Denial notification ${kind.name}')
      ..writeln('  id: $notificationId');
    if (kind == DesktopNotificationEventKind.closed) {
      output.writeln('  close reason: $closeReason ($_closeReasonLabel)');
      return output.toString().trimRight();
    }

    final value = notification!;
    output
      ..writeln('  sender: ${_shown(value.sender)}')
      ..writeln('  app: ${_shown(value.appName)}')
      ..writeln('  desktop entry: ${_shown(value.desktopEntry)}')
      ..writeln('  icon: ${_shown(value.appIcon)}')
      ..writeln('  summary: ${_shown(value.summary)}')
      ..writeln('  body: ${_shown(value.body)}')
      ..writeln('  urgency: ${value.urgency.name}')
      ..writeln('  category: ${_shown(value.category)}')
      ..writeln('  timeout: ${value.expireTimeoutMs} ms')
      ..writeln(
        '  flags: resident=${value.resident}, transient=${value.transient}, '
        'suppressSound=${value.suppressSound}, actionIcons=${value.actionIcons}, '
        'clearable=${value.clearable}',
      );
    if (value.actions.isEmpty) {
      output.writeln('  actions: none');
    } else {
      output.writeln('  actions:');
      for (final action in value.actions) {
        output.writeln('    ${action.key}: ${action.label}');
      }
    }
    if (value.groupKey.isNotEmpty) {
      output.writeln(
        '  group: ${value.groupKey.replaceAll('\n', ' / ')}'
        '${value.groupSummary ? ' (summary)' : ''}',
      );
    }
    for (final message in value.messages) {
      output.writeln('  message: ${_shown(message.sender)}: ${message.text}');
    }
    if (value.hasProgress) {
      output.writeln('  progress: ${value.progress}%');
    }
    if (value.hasPosition) {
      output.writeln('  position: ${value.x}, ${value.y}');
    }
    output
      ..writeln('  image path: ${_shown(value.imagePath)}')
      ..writeln('  sound name: ${_shown(value.soundName)}')
      ..writeln('  sound file: ${_shown(value.soundFile)}');
    final image = value.imageData;
    if (image == null) {
      output.writeln('  image data: none');
    } else {
      output.writeln(
        '  image data: ${image.width}x${image.height}, '
        'rowStride=${image.rowStride}, alpha=${image.hasAlpha}, '
        'bits=${image.bitsPerSample}, channels=${image.channels}, '
        '${image.data.length} bytes',
      );
    }
    return output.toString().trimRight();
  }

  String get _closeReasonLabel => switch (closeReason) {
    1 => 'expired',
    2 => 'dismissed',
    3 => 'closed by sender',
    _ => 'undefined',
  };
}

String _shown(String value) => value.isEmpty ? '(none)' : value;
