import 'dart:io';

import 'package:denial_dart_shell/src/launcher/repositories/desktop_apps_repository.dart';
import 'package:denial_dart_shell/src/launcher/runtime_paths.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporaryDirectory;
  late Directory dataDirectory;
  late DesktopAppsRepository repository;

  setUp(() {
    temporaryDirectory = Directory.systemTemp.createTempSync(
      'denial-app-icons-',
    );
    dataDirectory = Directory(p.join(temporaryDirectory.path, 'share'))
      ..createSync(recursive: true);
    repository = DesktopAppsRepository(
      paths: RuntimePaths(
        environment: <String, String>{
          'HOME': p.join(temporaryDirectory.path, 'home'),
          'XDG_DATA_HOME': dataDirectory.path,
          'XDG_DATA_DIRS': '',
        },
      ),
    );
  });

  tearDown(() {
    temporaryDirectory.deleteSync(recursive: true);
  });

  test('resolves file URIs and declared symbolic icon directories', () {
    final directIcon = _writeFile(
      temporaryDirectory,
      'direct/icon.svg',
      '<svg/>',
    );
    expect(
      repository.resolveIconPath(directIcon.uri.toString()),
      directIcon.path,
    );

    final theme = Directory(p.join(dataDirectory.path, 'icons', 'Fixture'))
      ..createSync(recursive: true);
    _writeFile(
      theme,
      'index.theme',
      '[Icon Theme]\n'
          'Name=Fixture\n'
          'Directories=symbolic/status\n',
    );
    final batteryIcon = _writeFile(
      theme,
      'symbolic/status/battery-caution-symbolic.svg',
      '<svg/>',
    );

    expect(
      repository.resolveIconPath('battery-caution-symbolic'),
      batteryIcon.path,
    );
  });

  test('uses the desktop entry icon when the app icon is omitted', () {
    final appIcon = _writeFile(
      dataDirectory,
      'icons/hicolor/128x128/apps/org.example.Chat.svg',
      '<svg/>',
    );
    _writeFile(
      dataDirectory,
      'applications/org.example.Chat.desktop',
      '[Desktop Entry]\n'
          'Type=Application\n'
          'Name=Example Chat\n'
          'Icon=org.example.Chat\n',
    );

    expect(
      repository.resolveNotificationIcon(
        appIcon: '',
        desktopEntry: 'org.example.Chat',
        appName: '',
      ),
      appIcon.path,
    );
  });

  test('falls back to matching app metadata when clients omit icon hints', () {
    final appIcon = _writeFile(
      dataDirectory,
      'icons/hicolor/128x128/apps/org.example.Chat.svg',
      '<svg/>',
    );
    _writeFile(
      dataDirectory,
      'applications/org.example.Chat.desktop',
      '[Desktop Entry]\n'
          'Type=Application\n'
          'Name=Example Chat\n'
          'StartupWMClass=ExampleChat\n'
          'Icon=org.example.Chat\n',
    );

    expect(
      repository.resolveNotificationIcon(
        appIcon: '',
        desktopEntry: '',
        appName: 'Example Chat',
      ),
      appIcon.path,
    );
  });
}

File _writeFile(Directory root, String relativePath, String contents) {
  final file = File(p.join(root.path, relativePath));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
  return file;
}
