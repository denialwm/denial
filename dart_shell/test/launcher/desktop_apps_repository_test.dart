import 'dart:io';

import 'package:denial_dart_shell/src/launcher/repositories/desktop_apps_repository.dart';
import 'package:denial_dart_shell/src/launcher/runtime_paths.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('denial-desktop-apps-');
  });

  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  test('loads desktop entries linked into an XDG data directory', () async {
    final applications = Directory(
      p.join(temporary.path, 'profile', 'share', 'applications'),
    );
    await applications.create(recursive: true);
    final source = File(p.join(temporary.path, 'nix-store-app.desktop'));
    await source.writeAsString('''
[Desktop Entry]
Type=Application
Name=Store Application
Exec=/bin/true
''');
    await Link(
      p.join(applications.path, 'store-application.desktop'),
    ).create(source.path);

    final repository = DesktopAppsRepository(
      paths: RuntimePaths(
        environment: <String, String>{
          'HOME': temporary.path,
          'XDG_DATA_DIRS': p.join(temporary.path, 'profile', 'share'),
          'XDG_CURRENT_DESKTOP': 'Denial',
        },
      ),
    );

    final applicationsFound = await repository.loadApplications();

    expect(applicationsFound, hasLength(1));
    expect(applicationsFound.single.id, 'store-application.desktop');
    expect(applicationsFound.single.name, 'Store Application');
    expect(
      applicationsFound.single.desktopPath,
      p.join(applications.path, 'store-application.desktop'),
    );
  });

  test('ignores broken desktop-entry links', () async {
    final applications = Directory(
      p.join(temporary.path, 'profile', 'share', 'applications'),
    );
    await applications.create(recursive: true);
    await Link(
      p.join(applications.path, 'broken.desktop'),
    ).create(p.join(temporary.path, 'missing.desktop'));

    final repository = DesktopAppsRepository(
      paths: RuntimePaths(
        environment: <String, String>{
          'HOME': temporary.path,
          'XDG_DATA_DIRS': p.join(temporary.path, 'profile', 'share'),
        },
      ),
    );

    expect(await repository.loadApplications(), isEmpty);
  });
}
