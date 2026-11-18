import 'dart:io';

import 'package:denial_plugin_manager/denial_plugin_manager.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late ManagerStore store;
  setUp(() {
    root = Directory.systemTemp.createTempSync('denial-report-test-');
    store = ManagerStore(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  /// A plugin whose package exists; [provides] makes it the desktop itself.
  Map<String, Object?> plugin(
    String name, {
    String kind = 'builtin',
    bool desktop = false,
  }) {
    final directory = Directory('${root.path}/src/$name')
      ..createSync(recursive: true);
    File('${directory.path}/pubspec.yaml').writeAsStringSync(
      [
        'name: $name',
        if (desktop) ...[
          'denial_plugin:',
          '  schema: 1',
          '  name: $name',
          '  provides:',
          '    - contract: package:denial_flutter_sdk/application.dart#ShellApplication',
        ],
        '',
      ].join('\n'),
    );
    return {
      'source': {'kind': kind, 'location': directory.path, 'path': '.'},
      'name': name,
      'directory': directory.path,
      'revision': 'r',
      'description': name,
    };
  }

  Map<String, Object?> state(
    Map<String, Object?> native, {
    String? running,
    String? problem,
    bool ready = true,
    Map<String, Object?> dart = const {'available': true},
    List<Map<String, Object?>> jobs = const [],
  }) => {
    'native': native,
    'selection': store.selection,
    'active': {'id': running},
    'problem': problem,
    'ready': ready,
    'dart': dart,
    'preflight': SelectionPreflight(store).check(),
    'jobs': jobs,
  };

  const capable = {
    'capabilities': ['pluginBundleV2'],
  };

  String status(Map<String, Object?> state) =>
      describeStatus(summarize(store, state));

  test('status says what runs, why, and the one next command', () {
    store.write('selection.json', {
      ...store.selection,
      'revision': 1,
      'roots': {'clock': plugin('clock', desktop: true)},
    });
    expect(
      status(state({...capable, 'active_mode': 'official_optimized'})),
      'The standard desktop is running.\n'
      'Selected: clock\n'
      'Next: denial-plugins apply',
    );

    store.write('candidates/one/plan.json', {
      'roots': {'clock': plugin('clock')},
    });
    final running = {
      ...capable,
      'active_mode': 'custom_optimized',
      'plugin_bundle': '${root.path}/candidates/one/bundle',
      'plugin_healthy': true,
    };
    expect(
      status(state(running, running: 'one')),
      'Your plugins are running: clock\n'
      'Selected: clock',
    );
    expect(
      status(
        state({...running, 'plugin_engine_differs': true}, running: 'one'),
      ),
      contains(
        'built for another engine than this session runs, and loaded anyway',
      ),
    );

    store.write('selection.json', {
      ...store.selection,
      'roots': {
        'clock': plugin('clock', desktop: true),
        'notes': plugin('notes', kind: 'local'),
      },
    });
    expect(
      status(state(running, running: 'one')),
      'Your plugins are running: clock\n'
      'Selected: clock, notes\n'
      '  Your selection changed since then: clock, notes\n'
      'Next: denial-plugins apply',
    );
  });

  test('status explains a rebuild, an old session and missing tools', () {
    store.write('selection.json', {
      ...store.selection,
      'roots': {'clock': plugin('clock', desktop: true)},
    });
    final waiting = status(
      state({
        ...capable,
        'active_mode': 'official_optimized',
        'error': 'The shell showed nothing.',
        'plugin_rebuild': {'reason': 'engine', 'bundle': '/somewhere/bundle'},
      }),
    );
    expect(waiting, contains('did not start on this session\'s engine'));
    expect(waiting, contains('Denial said: The shell showed nothing.'));
    expect(waiting, endsWith('Next: denial-plugins apply'));

    expect(
      status(state({'active_mode': 'official_optimized'})),
      endsWith('Next: Log out and back into Denial once.'),
    );
    expect(
      status(state({'available': false, 'error': 'no socket'})),
      startsWith('Denial does not answer in this session.'),
    );
    final missing = status(
      state({
        ...capable,
        'active_mode': 'official_optimized',
      }, problem: 'gen_snapshot is missing. Build the shell once.'),
    );
    expect(missing, contains('gen_snapshot is missing'));
    expect(missing, isNot(contains('Next:')));

    final failed = status(
      state(
        {...capable, 'active_mode': 'official_optimized'},
        jobs: [
          {'operation': 'apply', 'phase': 'failed', 'error': 'pub get failed'},
        ],
      ),
    );
    expect(failed, contains('The last change failed: pub get failed'));
    expect(failed, endsWith('Next: denial-plugins apply'));
  });

  test('a program gets codes, the running step and what it may offer', () {
    store.write('selection.json', {
      ...store.selection,
      'roots': {'clock': plugin('clock', desktop: true)},
    });
    const standard = {...capable, 'active_mode': 'official_optimized'};
    var summary = summarize(store, state(standard));
    expect(summary['contract'], statusContract);
    expect((summary['desktop']! as Map)['code'], 'standard');
    expect((summary['next']! as Map)['code'], 'apply');
    expect((summary['setup']! as Map)['code'], 'ready');
    expect(summary['can'], {
      'change': true,
      'apply': true,
      'undo': false,
      'off': false,
      'switch_now': false,
    });

    // A request and the build it runs inside itself are one piece of work.
    summary = summarize(
      store,
      state(
        standard,
        jobs: [
          {
            'id': 'inner',
            'operation': 'plan',
            'phase': 'running',
            'arguments': {'command': 'apply', 'request': 'outer'},
            'message': 'Resolving packages',
          },
          {
            'id': 'outer',
            'operation': 'apply',
            'phase': 'running',
            'arguments': {
              'argv': ['apply'],
            },
            'progress': {
              'completed': 2,
              'total': 5,
              'label': 'Compiling your desktop',
              'started': '2026-11-18T10:00:00Z',
            },
          },
        ],
      ),
    );
    expect(summary['work'], {
      'job': 'outer',
      'operation': 'apply',
      'label': 'Compiling your desktop',
      'step': 3,
      'steps': 5,
      'started': '2026-11-18T10:00:00Z',
    });
    expect((summary['next']! as Map)['code'], 'wait');
    expect((summary['can']! as Map)['apply'], isFalse);
    expect((summary['can']! as Map)['change'], isFalse);
    expect(
      describeStatus(summary),
      contains('Working: Compiling your desktop (step 3 of 5)'),
    );

    // The same for an apply typed into a terminal: it has no request.
    summary = summarize(
      store,
      state(
        standard,
        jobs: [
          {
            'id': 'typed',
            'operation': 'plan',
            'phase': 'running',
            'arguments': {'command': 'apply'},
            'message': 'Validating and sealing the new bundle',
            'updated': '2026-11-18T10:01:00Z',
          },
        ],
      ),
    );
    expect(summary['work'], {
      'job': 'typed',
      'operation': 'apply',
      'label': 'Verifying your desktop',
      'step': 4,
      'steps': 5,
      'started': '2026-11-18T10:01:00Z',
    });

    summary = summarize(
      store,
      state(
        standard,
        jobs: [
          {
            'id': 'waiting',
            'operation': 'rebuild',
            'phase': 'running',
            'arguments': {
              'argv': ['rebuild'],
            },
            'progress': {
              'completed': 4,
              'total': 6,
              'label': 'Switching when you pause',
            },
          },
        ],
      ),
    );
    expect((summary['can']! as Map)['switch_now'], isTrue);

    summary = summarize(
      store,
      state(
        standard,
        jobs: [
          {
            'id': 'broken',
            'operation': 'apply',
            'phase': 'failed',
            'arguments': {
              'argv': ['apply'],
            },
            'error': 'Your plugins did not start: The shell showed nothing.',
            'updated': '2026-11-18T10:02:00Z',
          },
          {
            'id': 'older',
            'operation': 'apply',
            'phase': 'succeeded',
            'updated': '2026-11-18T10:01:00Z',
          },
        ],
      ),
    );
    expect(summary['failure'], {
      'job': 'broken',
      'operation': 'apply',
      'code': 'did_not_start',
      'text': 'Your plugins were built but did not start. Denial kept the desktop it was running.',
      'detail': 'Your plugins did not start: The shell showed nothing.',
    });
    // A later success ends it, also the success of a request that was
    // running when a second one was refused.
    summary = summarize(
      store,
      state(
        standard,
        jobs: [
          {
            'id': 'refused',
            'operation': 'apply',
            'phase': 'failed',
            'updated': '2026-11-18T10:00:01Z',
          },
          {
            'id': 'first',
            'operation': 'apply',
            'phase': 'succeeded',
            'updated': '2026-11-18T10:01:00Z',
          },
        ],
      ),
    );
    expect(summary['failure'], isNull);
  });

  test('a selection that cannot be built names what to change', () {
    store.write('selection.json', {
      ...store.selection,
      'roots': {
        'one': plugin('one', desktop: true),
        'two': plugin('two', desktop: true),
      },
    });
    final summary = summarize(
      store,
      state({...capable, 'active_mode': 'official_optimized'}),
    );
    final issue = (summary['issues']! as List).single as Map;
    expect(issue['code'], 'too_many_providers');
    expect(issue['plugins'], unorderedEquals(['one', 'two']));
    expect(issue['feature'], 'Desktop');
    expect((summary['next']! as Map)['code'], 'fix_selection');
    expect((summary['can']! as Map)['apply'], isFalse);
    expect((summary['can']! as Map)['change'], isTrue);
    expect(describeStatus(summary), contains('Desktop is provided by'));
  });

  test('a refused selection fails for what it is', () {
    expect(
      failureCode(
        'Native work area is provided by Top Bar and Taskbar. Reference '
        'Desktop accepts only one. Disable one of these plugins before applying.',
      ),
      'conflict',
    );
    expect(
      failureCode(
        'Reference Desktop needs a provider for Native work area. Enable a '
        'compatible plugin before applying.',
      ),
      'missing',
    );
    expect(
      failureCode('panel has invalid compatibility declarations. Bad range'),
      'declaration',
    );
  });

  test('undo and off are offered only when Denial can do them', () {
    final bundle = '${root.path}/candidates/one/bundle';
    store.write('candidates/one/plan.json', {'roots': <String, Object?>{}});
    final summary = summarize(
      store,
      state({
        ...capable,
        'active_mode': 'custom_optimized',
        'plugin_bundle': bundle,
        'plugin_healthy': true,
        'plugin_previous': '/somewhere/bundle',
      }, running: 'one'),
    );
    expect((summary['can']! as Map)['undo'], isTrue);
    expect((summary['can']! as Map)['off'], isTrue);
  });

  test('setup says why nothing can be built here', () {
    const standard = {...capable, 'active_mode': 'official_optimized'};
    Map setup(Map<String, Object?> state) =>
        summarize(store, state)['setup']! as Map;
    expect(setup(state(standard, ready: false))['code'], 'needed');
    expect(
      setup(
        state(
          standard,
          ready: false,
          jobs: [
            {
              'id': 'setup',
              'operation': 'initialize',
              'phase': 'running',
              'arguments': {
                'argv': ['initialize'],
              },
            },
          ],
        ),
      )['code'],
      'preparing',
    );
    final missing = state(
      standard,
      ready: false,
      problem: 'Dart 3.13.2 was not found in PATH.',
      dart: {'available': false, 'expectedVersion': '3.13.2'},
    );
    expect(setup(missing), {
      'code': 'missing_dart',
      'text': 'Dart 3.13.2 was not found in PATH.',
      'expected': '3.13.2',
    });
    expect((summarize(store, missing)['can']! as Map)['apply'], isFalse);
    expect(
      setup(
        state(
          standard,
          problem: 'Dart 3.13.4 is installed, but Denial requires 3.13.2.',
          dart: {
            'available': false,
            'expectedVersion': '3.13.2',
            'version': '3.13.4',
            'constraint': '3.13.2',
          },
        ),
      )['code'],
      'incompatible_dart',
    );
  });

  test('list shows every known plugin once, selected ones marked', () {
    store.write('installed.json', {
      'plugins': {
        'clock': plugin('clock'),
        'mine': plugin('mine', kind: 'local'),
      },
    });
    store.write('selection.json', {
      ...store.selection,
      'roots': {'mine': plugin('mine', kind: 'local')},
    });
    final catalog = {
      'builtins': [
        {...plugin('clock'), 'default': true},
      ],
      'catalog': {
        'entries': [plugin('weather', kind: 'git')],
        'errors': ['no network'],
      },
    };
    final report = listReport(store, catalog);
    expect(report['contract'], statusContract);
    expect(report['errors'], ['no network']);
    expect(report['default_selection'], isFalse);
    expect(report['community'], {'configured': false, 'updated': null});
    final plugins = pluginList(store, catalog);
    expect(plugins[0]['default'], isTrue);
    expect(plugins[0]['kind'], 'builtin');
    expect(plugins[1]['title'], 'Mine');
    expect(plugins.map((plugin) => plugin['name']), [
      'clock',
      'mine',
      'weather',
    ]);
    expect(plugins[0]['from'], 'built in');
    expect(plugins[1]['selected'], isTrue);
    expect(plugins[2]['installed'], isFalse);
    final text = describePlugins(plugins);
    expect(text, contains('on  mine     ${root.path}/src/mine'));
    expect(text, contains('    clock    built in'));
  });

  test('defaults select what Denial comes with, and only that', () async {
    final runtime = '${root.path}/runtime';
    void package(String path, String name) {
      Directory('$runtime/plugins/$path').createSync(recursive: true);
      File('$runtime/plugins/$path/pubspec.yaml')
          .writeAsStringSync('name: $name\n');
    }

    package('clock', 'clock');
    package('pets', 'pets');
    File('$runtime/plugins/builtins.yaml').writeAsStringSync(
      'schema: 1\nplugins:\n  - path: clock\n    default: true\n  - path: pets\n',
    );
    final repository = SourceRepository(Directory('${root.path}/repositories'));
    final available = AvailablePlugins(store, repository);
    final pets = await repository.resolve(
      PluginSource(
        kind: SourceKind.builtin,
        location: '$runtime/plugins',
        path: 'pets',
      ),
    );
    store.select(pets);
    store.write('selection.json', {
      ...store.selection,
      'roots': {
        ...store.selection['roots']! as Map,
        'mine': plugin('mine', kind: 'local'),
      },
    });
    final catalog = {'builtins': await available.builtins(runtime)};
    expect(listReport(store, catalog)['default_selection'], isFalse);

    await available.defaults(runtime);
    expect((store.selection['roots']! as Map).keys, ['clock']);
    expect(listReport(store, catalog)['default_selection'], isTrue);
    // What was turned off is still known.
    expect(
      (store.read('installed.json')['plugins']! as Map).keys,
      contains('pets'),
    );
  });

  test('what a build took in besides the selection is named', () {
    store.write('selection.json', {
      ...store.selection,
      'revision': 3,
      'roots': {'panel': plugin('panel')},
    });
    Map<String, Object?> plan(int revision) => {
      'selectionRevision': revision,
      'discovery': {
        'plugins': ['panel', 'denial_clock_core'],
        'dependencyChains': {
          'panel': ['shell', 'panel'],
          'denial_clock_core': ['shell', 'panel', 'denial_clock_core'],
        },
      },
    };
    expect(summarize(store, {...state(capable), 'plan': plan(3)})['included'], [
      {
        'name': 'denial_clock_core',
        'title': 'Clock Core',
        'through': ['panel'],
      },
    ]);
    // A build of another selection says nothing about this one.
    expect(
      summarize(store, {...state(capable), 'plan': plan(2)})['included'],
      isEmpty,
    );
    expect(summarize(store, state(capable))['included'], isEmpty);
  });

  test('history tells the requests, the newest first', () {
    final history = historyReport([
      {
        'id': '1',
        'operation': 'apply',
        'arguments': {
          'argv': ['apply'],
        },
        'phase': 'succeeded',
        'updated': '2026-11-18T10:00:00Z',
      },
      // What the apply ran inside itself.
      {
        'id': '2',
        'operation': 'plan',
        'arguments': {'command': 'apply', 'request': '1'},
        'phase': 'succeeded',
        'updated': '2026-11-18T09:59:00Z',
      },
      {
        'id': '3',
        'operation': 'inspect',
        'arguments': {
          'argv': ['inspect', '/somewhere'],
        },
        'phase': 'succeeded',
        'updated': '2026-11-18T11:00:00Z',
      },
      // Typed in a terminal.
      {
        'id': '4',
        'operation': 'plan',
        'arguments': {'command': 'apply'},
        'phase': 'failed',
        'error': 'Your plugins did not start: The shell showed nothing.',
        'updated': '2026-11-18T12:00:00Z',
      },
      // From before requests said what they were asked.
      {
        'id': '6',
        'operation': 'plan',
        'arguments': {'runtime': '/kit'},
        'phase': 'succeeded',
        'updated': '2026-11-18T13:00:00Z',
      },
      {
        'id': '5',
        'operation': 'refresh-catalog',
        'arguments': <String, Object?>{},
        'phase': 'interrupted',
        'created': '2026-11-18T08:00:00Z',
      },
    ]);
    final entries = (history['entries']! as List).cast<Map<String, Object?>>();
    expect(entries.map((entry) => entry['job']), ['4', '1', '5']);
    expect(entries[0], {
      'job': '4',
      'operation': 'apply',
      'state': 'failed',
      'when': '2026-11-18T12:00:00Z',
      'code': 'did_not_start',
      'text': isA<String>(),
      'detail': 'Your plugins did not start: The shell showed nothing.',
    });
    expect(entries[1], {
      'job': '1',
      'operation': 'apply',
      'state': 'done',
      'when': '2026-11-18T10:00:00Z',
    });
    expect(entries[2]['state'], 'stopped');
    expect(entries[2]['code'], 'stopped');
    expect(describeHistory(history), contains('apply           failed: Your'));
    expect(describeHistory(historyReport([])), 'Nothing was asked yet.');
  });
}
