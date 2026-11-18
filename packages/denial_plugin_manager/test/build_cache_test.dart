import 'dart:convert';
import 'dart:io';

import 'package:denial_plugin_manager/denial_plugin_manager.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late ManagerStore store;
  late String flutter;
  late String engineRoot;
  var compilations = 0;

  File put(String relative, String text) {
    final file = File(p.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
    return file;
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('denial-build-cache-');
    store = ManagerStore(Directory(p.join(root.path, 'state')));
    flutter = put('flutter/bin/flutter', 'launcher').path;
    engineRoot = p.join(root.path, 'engine');
    put('engine/out/release/libflutter_engine.so', 'the engine');
    for (final file in [
      'gen_snapshot',
      'font-subset',
      'impellerc',
      'flutter_patched_sdk/kernel',
      'shader_lib/shader',
      'gen/const_finder.dart.snapshot',
      'icudtl.dat',
    ]) {
      put('engine/out/release/$file', 'compiler input $file');
    }
    put('flutter/bin/cache/dart-sdk/bin/dart', 'dart');
    put('flutter/bin/cache/dart-sdk/bin/snapshots/frontend', 'frontend');
    put('flutter/bin/internal/engine.version', 'revision');
    put('flutter/packages/flutter_tools/pubspec.yaml', 'name: flutter_tools');
    put('flutter/packages/flutter_tools/lib/source.dart', 'tool code');
    put(
      'flutter/packages/flutter_tools/.dart_tool/package_config.json',
      jsonEncode({
        'packages': [
          {'name': 'flutter_tools', 'rootUri': '../', 'packageUri': 'lib/'},
        ],
      }),
    );
    put('flutter/tool_assets/pubspec.yaml', 'name: tool_assets');
    put('flutter/tool_assets/images/template', 'template image');
    final config = File(
      p.join(
        root.path,
        'flutter/packages/flutter_tools/.dart_tool/package_config.json',
      ),
    );
    final packages =
        jsonDecode(config.readAsStringSync()) as Map<String, dynamic>;
    (packages['packages'] as List).add({
      'name': 'tool_assets',
      'rootUri': '../../../tool_assets/',
      'packageUri': 'lib/',
    });
    config.writeAsStringSync(jsonEncode(packages));
    compilations = 0;
  });
  tearDown(() {
    Process.runSync('chmod', ['-R', 'u+w', root.path]);
    root.deleteSync(recursive: true);
  });

  void plan(String id, {String asset = 'asset'}) {
    Directory(p.join(store.root.path, 'candidates/$id/packages'))
        .createSync(recursive: true);
    put('state/candidates/$id/app/lib/main.dart', 'void main() {}');
    put('state/candidates/$id/app/assets/icon', asset);
    put('state/candidates/$id/app/pubspec.lock', 'locked');
    store.write('candidates/$id/plan.json', {
      'id': id,
      'status': 'planned',
      'selectionRevision': 0,
      'flutterGeneration': 'generation',
      'flutterVersion': {'frameworkRevision': 'revision'},
      'flutter': flutter,
      'runtimeRoot': p.join(root.path, 'runtime'),
      'compositionKey': contentKey({'main': 'void main() {}', 'asset': asset}),
      'sourceIdentity': {'schema': 1, 'development': '/checkout'},
    });
  }

  Future<Map<String, Object?>> build(String id) =>
      CompositionBuilder(
        store,
        run: (executable, arguments, {workingDirectory, onOutput}) async {
          if (executable == flutter && arguments.first == 'assemble') {
            compilations++;
            final output = arguments
                .singleWhere((a) => a.startsWith('--output='))
                .substring(9);
            for (final file in ['lib/libapp.so', 'flutter_assets/icon']) {
              final target = File(p.join(output, file));
              target.parent.createSync(recursive: true);
              target.writeAsStringSync('compiled-$compilations-$file');
            }
            return '';
          }
          return runCommand(
            executable,
            arguments,
            workingDirectory: workingDirectory,
          );
        },
      ).build(
        id,
        engineRoot: engineRoot,
        engineTarget: 'release',
        platform: 'linux-x64',
      );

  test(
    'equivalent selections reuse sealed output; changed inputs compile again',
    () async {
      plan('first');
      expect((await build('first'))['reused'], false);
      plan('again');
      expect((await build('again'))['reused'], true);
      expect(compilations, 1);
      expect(
        File(p.join(store.root.path, 'candidates/again/bundle/lib/libapp.so'))
            .readAsStringSync(),
        'compiled-1-lib/libapp.so',
      );
      plan('asset-change', asset: 'different');
      expect((await build('asset-change'))['reused'], false);
      plan('compiler-change');
      put('engine/out/release/gen_snapshot', 'new compiler');
      expect((await build('compiler-change'))['reused'], false);
      expect(compilations, 3);
      put('flutter/bin/cache/flutter_tools.snapshot', 'compiled tool');
      plan('tool-snapshot');
      expect((await build('tool-snapshot'))['reused'], false);
      plan('tool-snapshot-again');
      expect((await build('tool-snapshot-again'))['reused'], true);
      put('flutter/bin/cache/flutter_tools.snapshot', 'changed tool');
      plan('tool-snapshot-change');
      expect((await build('tool-snapshot-change'))['reused'], false);
      expect(compilations, 5);
    },
  );

  test('snapshots omit native runner caches but preserve plugin assets', () {
    put('plugin/pubspec.yaml', 'name: example_plugin\n');
    put('plugin/linux/flutter/ephemeral/generated', 'runner cache');
    put('plugin/assets/ephemeral/icon', 'plugin asset');
    final snapshot = PackageSnapshot(Directory(p.join(root.path, 'snapshot')));
    final result = snapshot.copy(p.join(root.path, 'plugin'));
    expect(
      Directory(p.join(result, 'linux/flutter/ephemeral')).existsSync(),
      false,
    );
    expect(
      File(p.join(result, 'assets/ephemeral/icon')).readAsStringSync(),
      'plugin asset',
    );
  });

  test(
    'the bundle carries the shell and what it was built for, never an engine',
    () async {
      plan('one');
      final result = await build('one');
      final bundle = Directory(result['bundle']! as String);
      expect(
        bundle
            .listSync(recursive: true)
            .whereType<File>()
            .map((file) => p.relative(file.path, from: bundle.path))
            .toSet(),
        {
          'denial-plugin-bundle.json',
          'lib/libapp.so',
          'data/flutter_assets/icon',
        },
      );
      final manifest = result['manifest']! as Map;
      expect(manifest['source_identity'], {
        'schema': 1,
        'development': '/checkout',
      });
      expect(manifest['framework_revision'], 'revision');
      // Informational: deniald uses it only to explain a failed start.
      expect(
        manifest['engine_sha256'],
        fileDigest(p.join(engineRoot, 'out/release/libflutter_engine.so')),
      );
      await expectLater(build('one'), throwsA(isA<CompositionException>()));
      expect(compilations, 1);
    },
  );

  test('an engine rebuilt with the same compilers reuses the build', () async {
    plan('first');
    await build('first');
    put('engine/out/release/libflutter_engine.so', 'the engine, rebuilt');
    plan('again');
    expect((await build('again'))['reused'], true);
    expect(compilations, 1);
  });

  test(
    'damaged output and a cache index pointing at another composition miss',
    () async {
      plan('first');
      await build('first');
      final key =
          store.read('candidates/first/build.json')['cacheKey']! as String;
      final bundle = Directory(
        p.join(store.root.path, 'candidates/first/bundle'),
      );
      Process.runSync('chmod', ['-R', 'u+w', bundle.path]);
      File(p.join(bundle.path, 'data/flutter_assets/icon'))
          .writeAsStringSync('damaged');
      expect(BuildCache(store).lookup(key), isNull);
      plan('second', asset: 'other');
      await build('second');
      store.write('cache/builds/$key.json', {'id': 'second'});
      expect(BuildCache(store).lookup(key), isNull);
    },
  );

  test(
    'digest memo detects changed bytes even with preserved modification time',
    () {
      final file = put('mutable/input', 'before');
      final first = FileDigestCache(store);
      final original = first.digest(file);
      first.save();
      final modified = file.statSync().modified;
      file.writeAsStringSync('after!');
      file.setLastModifiedSync(modified);
      final next = FileDigestCache(store);
      expect(next.digest(file), isNot(original));
      expect(next.digest(file), fileDigest(file.path));
    },
  );

  test('unchanged apply does not request another shell refresh', () async {
    plan('first');
    await build('first');
    final bundle = p.join(store.root.path, 'candidates/first/bundle');
    plan('again');
    await build('again');
    final calls = <List<String>>[];
    final activation = CompositionActivation(
      store,
      run: (_, args, {workingDirectory, onOutput}) async {
        calls.add(args);
        return jsonEncode({
          'plugin_bundle': bundle,
          'plugin_healthy': true,
          'active_mode': 'custom_optimized',
        });
      },
    );
    await activation.activate('again');
    expect(calls, [
      ['--json', 'ui', 'status'],
    ]);
    // deniald itself says it runs this build; the manager keeps no record.
    expect(store.file('active.json').existsSync(), isFalse);
  });
}
