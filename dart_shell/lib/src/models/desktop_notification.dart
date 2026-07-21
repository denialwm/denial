import 'dart:typed_data';

enum DesktopNotificationEventKind { added, replaced, closed }

enum DesktopNotificationUrgency { low, normal, critical }

class DesktopNotificationAction {
  const DesktopNotificationAction({required this.key, required this.label});

  final String key;
  final String label;
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
        'suppressSound=${value.suppressSound}, actionIcons=${value.actionIcons}',
      );
    if (value.actions.isEmpty) {
      output.writeln('  actions: none');
    } else {
      output.writeln('  actions:');
      for (final action in value.actions) {
        output.writeln('    ${action.key}: ${action.label}');
      }
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
