import 'dart:convert';
import 'dart:io';

import 'package:denial_plugin_manager/denial_plugin_manager.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late ManagerStore store;
  late DevelopmentInstallation installation;

  File put(String relative, String text) {
    final file = File(p.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
    return file;
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('denial-tools-test-');
    store = ManagerStore(Directory(p.join(root.path, 'state')));
    put('checkout/plugins/builtins.yaml', 'schema: 1\nplugins: []\n');
    put('checkout/packages/denial_flutter_sdk/pubspec.yaml', 'name: sdk\n');
    put('flutter/bin/flutter', 'launcher');
    put('flutter/bin/cache/dart-sdk/bin/dart', 'dart');
    put('flutter/bin/cache/dart-sdk/version', '3.13.4\n');
    installation = DevelopmentInstallation(
      checkout: p.join(root.path, 'checkout'),
      flutter: p.join(root.path, 'flutter/bin/flutter'),
      engineRoot: p.join(root.path, 'engine'),
      engineTarget: 'denial_host_release',
      platform: 'linux-x64',
    );
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('a checkout builds with its own tools, in place', () async {
    final tools = BuildTools.of(
      store,
      PluginInstallation(development: installation, denialctl: 'denialctl'),
    );
    expect(tools.available, isTrue);
    // The engine was never built: say what is missing and what builds it.
    expect(tools.ready, isFalse);
    expect(tools.problem, contains('gen_snapshot is missing'));
    expect(tools.problem, contains('tools/denial-pc bundle'));
    await expectLater(tools.initialize(), throwsA(isA<CompositionException>()));

    final compiler = put('engine/out/denial_host_release/gen_snapshot', 'one');
    expect(tools.problem, isNull);
    final settings = await tools.initialize();
    expect(tools.ready, isTrue);
    expect(settings['runtime'], installation.checkout);
    expect(settings['flutter'], installation.flutter);
    expect(settings['engine-root'], installation.engineRoot);
    expect(settings['flutter-arguments'], [
      '--local-engine-src-path=${installation.engineRoot}',
      '--local-engine=denial_host_release',
      '--local-engine-host=denial_host_release',
    ]);
    expect(tools.dartStatus['version'], '3.13.4');
    // Nothing is copied and no path is remembered: the checkout is read live.
    expect(
      Directory(p.join(store.root.path, 'build-kits')).existsSync(),
      isFalse,
    );
    expect(store.read('configuration.json'), isEmpty);

    // A rebuilt engine makes a failed rebuild worth another try.
    final before = tools.identity;
    compiler.writeAsStringSync('another compiler');
    expect(tools.identity, isNot(before));
  });

  test('a checkout keeps one identity across commits, edits and engines', () {
    final checkout = installation.checkout;
    final identity = sourceIdentity(checkout);
    expect(identity, {
      'schema': 1,
      'development': Directory(checkout).resolveSymbolicLinksSync(),
    });
    put('checkout/packages/denial_flutter_sdk/lib/sdk.dart', '// edited');
    put('engine/out/denial_host_release/libflutter_engine.so', 'rebuilt');
    expect(sourceIdentity(checkout), identity);
    // A release names itself with the marker its build kit carries.
    put('checkout/.denial-ui-source.json', '{"source_revision":"0.6.4"}');
    expect(sourceIdentity(checkout), {'source_revision': '0.6.4'});
  });

  test(
    'built-in plugins of another installation are adopted, not refused',
    () async {
      put('engine/out/denial_host_release/gen_snapshot', 'compiler');
      put(
        'checkout/plugins/builtins.yaml',
        'schema: 1\nplugins:\n  - path: clock\n    default: true\n',
      );
      put(
        'checkout/plugins/clock/pubspec.yaml',
        'name: clock\ndescription: A clock\n',
      );
      store.write('initialization.json', {'complete': true});
      final packaged = {
        'source': {
          'kind': 'builtin',
          'location': '/usr/lib/denial/plugin-build-kit/runtime/plugins',
          'path': 'clock',
        },
        'name': 'clock',
        'directory': '/usr/lib/denial/plugin-build-kit/runtime/plugins/clock',
        'revision': 'packaged',
        'description': 'A clock',
      };
      store.write('installed.json', {
        'plugins': {'clock': packaged},
      });
      store.write('selection.json', {
        ...store.selection,
        'revision': 4,
        'roots': {'clock': packaged},
      });
      final tools = DevelopmentTools(store, installation);
      expect(tools.ready, isFalse);
      await tools.initialize();
      expect(tools.ready, isTrue);
      final root = (store.selection['roots']! as Map)['clock'] as Map;
      expect(
        (root['source'] as Map)['location'],
        p.join(installation.checkout, 'plugins'),
      );
    },
  );

  test('installation metadata names a checkout or a build kit', () {
    final bin = Directory(p.join(root.path, 'bin'))..createSync();
    File(p.join(bin.path, 'denial-plugins.installation.json'))
        .writeAsStringSync(
          jsonEncode({
            'schema': 1,
            'denialctl': 'denialctl',
            'development': {
              'checkout': '../checkout',
              'flutter': '../flutter/bin/flutter',
              'engineRoot': '../engine',
              'engineTarget': 'denial_host_release',
              'platform': 'linux-x64',
            },
          }),
        );
    final found = PluginInstallation.discover(
      executable: p.join(bin.path, 'denial-plugins'),
    );
    expect(found.buildKit, isNull);
    expect(found.development!.checkout, installation.checkout);
    expect(found.development!.flutter, installation.flutter);
    expect(found.development!.engineRoot, installation.engineRoot);
  });
}
