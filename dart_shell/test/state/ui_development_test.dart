import 'dart:io';

import 'package:denial_dart_shell/src/state/ui_development.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'workspace setup uses configured control and development tools',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'denial-ui-development-test-',
      );
      addTearDown(() => temporary.delete(recursive: true));

      final invocation = File('${temporary.path}/invocation');
      final controlTool = File('${temporary.path}/denialctl');
      final developmentTool = File('${temporary.path}/denial-ui');
      await controlTool.writeAsString('''#!/bin/sh
printf '%s\n' "\$@" > "\$DENIAL_TEST_INVOCATION"
printf '%s' "\$DENIAL_DEVELOPMENT_TOOL" >> "\$DENIAL_TEST_INVOCATION"
''');
      await developmentTool.writeAsString('#!/bin/sh\nexit 0\n');
      for (final tool in <File>[controlTool, developmentTool]) {
        final chmod = await Process.run('chmod', <String>['700', tool.path]);
        expect(chmod.exitCode, 0, reason: chmod.stderr.toString());
      }

      final service = SystemUiWorkspaceSetupService(
        environment: <String, String>{
          'DENIAL_CONTROL_TOOL': controlTool.path,
          'DENIAL_DEVELOPMENT_TOOL': developmentTool.path,
          'DENIAL_TEST_INVOCATION': invocation.path,
        },
      );

      expect(service.available, isTrue);
      await service.setup();
      expect(await invocation.readAsLines(), <String>[
        '--json',
        'ui',
        'setup',
        developmentTool.path,
      ]);
    },
  );
}
