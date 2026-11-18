import 'dart:convert';
import 'dart:io';

import 'package:denial_plugin_manager/denial_plugin_manager.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late ManagerStore store;
  late Directory directory;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('denial-activation-test-');
    store = ManagerStore(directory);
  });
  tearDown(() => directory.deleteSync(recursive: true));

  String candidate(String id, {int selection = 0}) {
    final path = p.join(directory.path, 'candidates', id, 'bundle');
    Directory(path).createSync(recursive: true);
    store.write('candidates/$id/plan.json', {
      'status': 'built',
      'selectionRevision': selection,
      'roots': <String, Object?>{},
    });
    store.write('candidates/$id/build.json', {
      'status': 'built',
      'bundle': path,
    });
    return path;
  }

  test(
    'preflight distinguishes unavailable, old, and updated native sessions',
    () async {
      Map<String, Object?> status = {'available': false};
      final activation = CompositionActivation(
        store,
        run: (_, args, {workingDirectory, onOutput}) async {
          expect(args, ['--json', 'ui', 'status']);
          return jsonEncode(status);
        },
      );
      await expectLater(
        activation.requireSupport(),
        throwsA(isA<CompositionException>()),
      );
      status = {'active_mode': 'official_optimized'};
      await expectLater(
        activation.requireSupport(),
        throwsA(
          isA<CompositionException>().having(
            (e) => e.message,
            'message',
            contains('Log out and back'),
          ),
        ),
      );
      status = {
        'active_mode': 'official_optimized',
        'capabilities': ['pluginBundleV2'],
      };
      await activation.requireSupport();
    },
  );

  test(
    'only deniald reporting the exact bundle healthy counts as applied',
    () async {
      final bundle = candidate('one');
      final calls = <List<String>>[];
      var healthy = false;
      final activation = CompositionActivation(
        store,
        run: (_, argv, {workingDirectory, onOutput}) async {
          calls.add(argv);
          return jsonEncode({
            'active_mode': 'custom_optimized',
            'plugin_bundle': bundle,
            'plugin_healthy': healthy,
            'error': 'The shell showed nothing.',
            'generation': 3,
          });
        },
      );
      await expectLater(
        activation.activate('one'),
        throwsA(
          isA<CompositionException>().having(
            (e) => e.message,
            'message',
            'Your plugins did not start: The shell showed nothing.',
          ),
        ),
      );
      healthy = true;
      final native = await activation.activate('one');
      expect(calls.last, ['--json', 'ui', 'activate', bundle]);
      // deniald is the only record of what runs.
      expect(activation.runningCandidate(native), 'one');
      expect(store.file('active.json').existsSync(), isFalse);
    },
  );

  test('plugins built elsewhere are not mistaken for a candidate', () {
    final activation = CompositionActivation(store);
    expect(activation.candidateOf('/elsewhere/candidates/one/bundle'), isNull);
    expect(activation.candidateOf(null), isNull);
    expect(activation.candidateOf(candidate('mine')), 'mine');
  });

  test(
    'required native capabilities block activation before shell replacement',
    () async {
      final bundle = candidate('capability');
      store.write('candidates/capability/plan.json', {
        ...store.read('candidates/capability/plan.json'),
        'sourceIdentity': {
          'required_native_capabilities': ['pluginActionsV1'],
        },
      });
      var supported = false;
      var transitions = 0;
      final activation = CompositionActivation(
        store,
        run: (_, args, {workingDirectory, onOutput}) async {
          if (args[2] == 'activate') transitions++;
          return jsonEncode({
            'capabilities': [if (supported) 'pluginActionsV1'],
            'active_mode': 'custom_optimized',
            'plugin_bundle': bundle,
            'plugin_healthy': true,
          });
        },
      );
      await expectLater(
        activation.activate('capability'),
        throwsA(isA<CompositionException>()),
      );
      expect(transitions, 0);
      supported = true;
      await activation.activate('capability');
      expect(transitions, 1);
    },
  );

  test(
    'confirmed updates retain installed pins after disabling the root',
    () async {
      final source = PluginSource(
        kind: SourceKind.git,
        location: 'https://example.org/panel.git',
      );
      ResolvedSource plugin(String revision) => ResolvedSource(
        source: source,
        name: 'panel',
        directory: '/cache/$revision',
        revision: revision,
        description: 'Panel',
      );
      store.select(plugin('old'));
      final bundle = candidate('updated', selection: 1);
      store.write('candidates/updated/plan.json', {
        ...store.read('candidates/updated/plan.json'),
        'roots': {'panel': plugin('new').toJson()},
      });
      var healthy = false;
      final activation = CompositionActivation(
        store,
        run: (_, args, {workingDirectory, onOutput}) async => jsonEncode({
          'active_mode': 'custom_optimized',
          'plugin_bundle': bundle,
          'plugin_healthy': healthy,
        }),
      );
      await expectLater(
        activation.activate('updated'),
        throwsA(isA<CompositionException>()),
      );
      expect(
        ((store.read('installed.json')['plugins'] as Map)['panel']
            as Map)['revision'],
        'old',
      );
      healthy = true;
      await activation.activate('updated');
      store.remove('panel');
      store.write('last-plan.json', {'id': 'another-composition'});
      expect(
        ((store.read('installed.json')['plugins'] as Map)['panel']
            as Map)['revision'],
        'new',
      );
    },
  );

  test('undo restores the saved selection and off keeps it', () async {
    final bundle = candidate('previous');
    store.write('candidates/previous/plan.json', {
      ...store.read('candidates/previous/plan.json'),
      'selections': {'contract': 'provider'},
      'ordering': {
        'collection': ['second', 'first'],
      },
    });
    store.write('last-plan.json', {'id': 'current'});
    final activation = CompositionActivation(
      store,
      run: (_, argv, {workingDirectory, onOutput}) async => jsonEncode(
        argv.last == 'revert'
            ? {'plugin_healthy': true, 'plugin_bundle': bundle, 'generation': 4}
            : {'active_mode': 'official_optimized', 'generation': 5},
      ),
    );
    await activation.revert();
    expect(store.selection['revision'], 1);
    expect(store.selection['selections'], {'contract': 'provider'});
    expect(store.selection['ordering'], {
      'collection': ['second', 'first'],
    });
    expect(store.read('last-plan.json')['id'], 'previous');
    await activation.restore();
    expect(store.read('last-plan.json')['id'], 'previous');
  });

  test('status identifies a vanished worker instead of leaving the GUI busy forever', () {
    final id = store.createJob('build', {});
    store.updateJob(id, {
      'phase': 'running',
      'pid': 2147483647,
      'processStart': 'impossible',
    });
    expect(store.jobs().single['phase'], 'interrupted');
  });
}
