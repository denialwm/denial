import 'dart:io';

import 'package:denial_dart_shell/src/launcher/runtime_paths.dart';
import 'package:denial_dart_shell/src/services/notification_policy_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('notification policy persists without notification content', () async {
    final directory = await Directory.systemTemp.createTemp(
      'denial-notification-policy-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final paths = RuntimePaths(environment: <String, String>{
      'HOME': directory.path,
      'XDG_STATE_HOME': directory.path,
    });
    final repository = NotificationPolicyRepository(paths: paths);

    await repository.write(const NotificationPolicy(
      doNotDisturb: true,
      lockPreview: NotificationPreviewMode.full,
    ));
    final restored = await repository.read();

    expect(restored.doNotDisturb, isTrue);
    expect(restored.lockPreview, NotificationPreviewMode.full);
    final file = await paths.notificationPolicyFile();
    final contents = await file.readAsString();
    expect(contents, contains('doNotDisturb'));
    expect(contents, contains('lockPreview'));
    expect(contents, isNot(contains('body')));
    expect(contents, isNot(contains('history')));
  });

  test('malformed policy falls back to privacy-safe defaults', () async {
    final directory = await Directory.systemTemp.createTemp(
      'denial-notification-policy-malformed-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final paths = RuntimePaths(environment: <String, String>{
      'HOME': directory.path,
      'XDG_STATE_HOME': directory.path,
    });
    final file = await paths.notificationPolicyFile();
    await file.writeAsString('{broken');

    final restored = await NotificationPolicyRepository(paths: paths).read();
    expect(restored.doNotDisturb, isFalse);
    expect(
      restored.lockPreview,
      NotificationPreviewMode.applicationOnly,
    );
  });
}
