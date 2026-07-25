import 'package:denial_dart_shell/src/launcher/runtime_paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses the configured home directory', () {
    final paths = RuntimePaths(
      environment: const <String, String>{'HOME': '/home/example'},
    );

    expect(paths.homeDir, '/home/example');
    expect(paths.configHome, '/home/example/.config');
  });

  test('uses a sentinel path when home is unavailable', () {
    expect(
      RuntimePaths(environment: const <String, String>{}).homeDir,
      '/nonexistent',
    );
    expect(
      RuntimePaths(environment: const <String, String>{'HOME': ''}).homeDir,
      '/nonexistent',
    );
  });
}
