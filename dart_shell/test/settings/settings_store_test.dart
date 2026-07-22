import 'dart:convert';
import 'dart:io';

import 'package:denial_dart_shell/src/launcher/runtime_paths.dart';
import 'package:denial_dart_shell/src/settings/settings_store.dart';
import 'package:denial_dart_shell/src/settings/shell_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late RuntimePaths paths;
  late FileSettingsStore store;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('denial-settings-');
    paths = RuntimePaths(
      environment: <String, String>{'XDG_CONFIG_HOME': directory.path},
    );
    store = FileSettingsStore(paths);
  });

  tearDown(() {
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  });

  test('writes atomically and restores the latest complete settings', () async {
    const first = ShellSettings(
      appearance: ShellAppearanceSettings(windowRadius: 18),
    );
    const latest = ShellSettings(
      appearance: ShellAppearanceSettings(windowRadius: 37),
    );

    await Future.wait(<Future<void>>[store.write(first), store.write(latest)]);

    expect(await store.read(), latest);
    expect(File('${paths.settingsPath}.tmp').existsSync(), isFalse);
    final decoded = jsonDecode(File(paths.settingsPath).readAsStringSync());
    expect(decoded['version'], ShellSettings.schemaVersion);
  });

  test('missing or malformed files fall back without throwing', () async {
    expect(await store.read(), isNull);

    final file = await paths.settingsFile();
    file.writeAsStringSync('{ this is not JSON', flush: true);

    expect(await store.read(), isNull);
  });
}
