import 'dart:convert';
import 'dart:io';

import 'package:denial_plugin_manager/denial_plugin_manager.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(
    () => root = Directory.systemTemp.createTempSync('denial-snapshot-test-'),
  );
  tearDown(() => root.deleteSync(recursive: true));

  void package(String path, String name, Map<String, Object?> dependencies) {
    final directory = Directory(p.join(root.path, path))
      ..createSync(recursive: true);
    File(p.join(directory.path, 'pubspec.yaml')).writeAsStringSync(
      jsonEncode({
        'name': name,
        'version': '0.0.0',
        'dependencies': dependencies,
        'dev_dependencies': {'unused': 'any'},
      }),
    );
    final source = File(p.join(directory.path, 'lib/source.dart'));
    source.parent.createSync();
    source.writeAsStringSync('library;');
    final cache = File(p.join(directory.path, '.dart_tool/private'));
    cache.parent.createSync();
    cache.writeAsStringSync('not a build input');
  }

  test(
    'snapshot relocates shared path dependencies without modifying sources',
    () {
      package('sdk', 'api', {});
      package('plugin', 'plugin', {
        'api': {'path': '../sdk'},
      });
      package('runtime', 'runtime', {
        'api': {'path': '../sdk'},
      });
      final before = treeDigest(Directory(p.join(root.path, 'plugin')));
      final snapshots = PackageSnapshot(
        Directory(p.join(root.path, 'snapshot')),
      );
      final plugin = snapshots.copy(p.join(root.path, 'plugin'));
      snapshots.copy(p.join(root.path, 'runtime'));
      final manifest = readYamlMap(File(p.join(plugin, 'pubspec.yaml')));
      expect(manifest['dependencies'], {
        'api': {'path': '../api'},
      });
      expect(manifest, isNot(contains('dev_dependencies')));
      expect(Directory(p.join(plugin, '.dart_tool')).existsSync(), isFalse);
      expect(treeDigest(Directory(p.join(root.path, 'plugin'))), before);
      File(p.join(root.path, 'plugin/lib/source.dart'))
          .writeAsStringSync('changed after planning');
      expect(
        File(p.join(plugin, 'lib/source.dart')).readAsStringSync(),
        'library;',
      );
    },
  );

  test('installed SDK overrides escaped or duplicate developer SDK paths', () {
    package('installed-sdk', 'denial_sdk', {});
    package('checkout-sdk', 'denial_sdk', {});
    package('plugin', 'plugin', {
      'denial_sdk': {'path': '../missing-checkout/packages/denial_sdk'},
    });
    final snapshot = PackageSnapshot(
      Directory(p.join(root.path, 'snapshot')),
      packageOverrides: {'denial_sdk': p.join(root.path, 'installed-sdk')},
    );
    final plugin = snapshot.copy(p.join(root.path, 'plugin'));
    expect(
      snapshot.copy(p.join(root.path, 'checkout-sdk')),
      p.join(root.path, 'snapshot/denial_sdk'),
    );
    expect(
      snapshot.originals['denial_sdk'],
      p.join(root.path, 'installed-sdk'),
    );
    expect(readYamlMap(File(p.join(plugin, 'pubspec.yaml')))['dependencies'], {
      'denial_sdk': {'path': '../denial_sdk'},
    });
  });

  test(
    'duplicate local package identities and source symlinks are rejected',
    () {
      package('first', 'api', {});
      package('second', 'api', {});
      final snapshots = PackageSnapshot(
        Directory(p.join(root.path, 'snapshot')),
      );
      snapshots.copy(p.join(root.path, 'first'));
      expect(
        () => snapshots.copy(p.join(root.path, 'second')),
        throwsA(isA<CompositionException>()),
      );
      package('plugin', 'plugin', {});
      Link(p.join(root.path, 'plugin/external')).createSync(root.path);
      expect(
        () => snapshots.copy(p.join(root.path, 'plugin')),
        throwsA(isA<CompositionException>()),
      );
    },
  );

  test('installed read-only package files can be snapshotted and rebased', () {
    package('sdk', 'api', {});
    package('plugin', 'plugin', {
      'api': {'path': '../sdk'},
    });
    final source = File(p.join(root.path, 'plugin/pubspec.yaml'));
    final bytes = source.readAsBytesSync();
    expect(Process.runSync('chmod', ['a-w', source.path]).exitCode, 0);
    final readOnlyMode = Process.runSync('stat', [
      '-c',
      '%a',
      source.path,
    ]).stdout.toString().trim();
    final target = PackageSnapshot(Directory(p.join(root.path, 'snapshot')))
        .copy(p.join(root.path, 'plugin'));
    expect(readYamlMap(File(p.join(target, 'pubspec.yaml')))['dependencies'], {
      'api': {'path': '../api'},
    });
    expect(source.readAsBytesSync(), bytes);
    expect(
      Process.runSync('stat', [
        '-c',
        '%a',
        source.path,
      ]).stdout.toString().trim(),
      readOnlyMode,
    );
  });

  test('a candidate is built once, before any tool runs twice', () async {
    final store = ManagerStore(Directory(p.join(root.path, 'state')));
    final builder = CompositionBuilder(
      store,
      run: (executable, arguments, {workingDirectory, onOutput}) async =>
          throw StateError('Must not invoke tools for a built candidate'),
    );
    store.write('candidates/test/plan.json', {'status': 'built'});
    await expectLater(
      builder.build(
        'test',
        engineRoot: '/unused',
        engineTarget: 'denial_host_release',
        platform: 'linux-x64',
      ),
      throwsA(
        isA<CompositionException>().having(
          (e) => e.message,
          'message',
          contains('already built'),
        ),
      ),
    );
  });
}
