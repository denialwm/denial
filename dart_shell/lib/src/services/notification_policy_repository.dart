import 'dart:convert';
import 'dart:io';

import '../launcher/runtime_paths.dart';

enum NotificationPreviewMode {
  hidden,
  applicationOnly,
  full;

  static NotificationPreviewMode parse(Object? value) {
    return switch (value) {
      'hidden' => NotificationPreviewMode.hidden,
      'full' => NotificationPreviewMode.full,
      _ => NotificationPreviewMode.applicationOnly,
    };
  }
}

class NotificationPolicy {
  const NotificationPolicy({
    this.doNotDisturb = false,
    this.lockPreview = NotificationPreviewMode.applicationOnly,
  });

  final bool doNotDisturb;
  final NotificationPreviewMode lockPreview;

  NotificationPolicy copyWith({
    bool? doNotDisturb,
    NotificationPreviewMode? lockPreview,
  }) {
    return NotificationPolicy(
      doNotDisturb: doNotDisturb ?? this.doNotDisturb,
      lockPreview: lockPreview ?? this.lockPreview,
    );
  }
}

abstract interface class NotificationPolicyStore {
  Future<NotificationPolicy> read();

  Future<void> write(NotificationPolicy policy);
}

/// Persists notification policy only. Notification contents remain bounded to
/// the current session and are never written to disk.
class NotificationPolicyRepository implements NotificationPolicyStore {
  const NotificationPolicyRepository({required this._paths});

  final RuntimePaths _paths;

  @override
  Future<NotificationPolicy> read() async {
    try {
      final file = await _paths.notificationPolicyFile();
      if (!await file.exists()) {
        return const NotificationPolicy();
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) {
        return const NotificationPolicy();
      }
      return NotificationPolicy(
        doNotDisturb: decoded['doNotDisturb'] == true,
        lockPreview: NotificationPreviewMode.parse(decoded['lockPreview']),
      );
    } on Object {
      return const NotificationPolicy();
    }
  }

  @override
  Future<void> write(NotificationPolicy policy) async {
    try {
      final file = await _paths.notificationPolicyFile();
      final temporary = File('${file.path}.tmp');
      final payload = jsonEncode(<String, Object>{
        'version': 1,
        'doNotDisturb': policy.doNotDisturb,
        'lockPreview': policy.lockPreview.name,
      });
      await temporary.writeAsString('$payload\n', flush: true);
      await temporary.rename(file.path);
    } on Object {
      // Policy persistence must never make the shell controls unusable. The
      // in-memory state remains authoritative for this session.
    }
  }
}
