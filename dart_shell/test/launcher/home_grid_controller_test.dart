import 'dart:io';

import 'package:denial_dart_shell/src/launcher/controllers/home_grid_controller.dart';
import 'package:denial_dart_shell/src/launcher/launcher_providers.dart';
import 'package:denial_dart_shell/src/launcher/runtime_paths.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('denial-home-grid-');
  });

  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  test('adds a desktop entry installed after the initial load', () async {
    final applications = Directory(
      p.join(temporary.path, 'profile', 'share', 'applications'),
    );
    await applications.create(recursive: true);
    final container = ProviderContainer.test(
      overrides: [
        runtimePathsProvider.overrideWithValue(
          RuntimePaths(
            environment: <String, String>{
              'HOME': temporary.path,
              'XDG_DATA_HOME': p.join(temporary.path, 'data'),
              'XDG_DATA_DIRS': p.join(temporary.path, 'profile', 'share'),
              'XDG_CURRENT_DESKTOP': 'Denial',
            },
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final initial = await container.read(homeGridControllerProvider.future);
    expect(
      initial.slots.any((item) => item?.id == 'app:new-application.desktop'),
      isFalse,
    );

    final desktopFile = File(
      p.join(applications.path, 'new-application.desktop'),
    );
    var generation = 0;
    await _waitFor(() async {
      await desktopFile.writeAsString('''
[Desktop Entry]
Type=Application
Name=New Application
Exec=/bin/true
X-Denial-Test-Generation=${generation++}
''');
      await Future<void>.delayed(const Duration(milliseconds: 250));
      return (container
              .read(homeGridControllerProvider)
              .asData
              ?.value
              .slots
              .any((item) => item?.id == 'app:new-application.desktop') ??
          false);
    });
  });
}

Future<void> _waitFor(Future<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for the desktop application refresh.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
