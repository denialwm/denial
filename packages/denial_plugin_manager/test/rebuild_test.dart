import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:denial_plugin_manager/denial_plugin_manager.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late ManagerStore store;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('denial-rebuild-test-');
    store = ManagerStore(Directory(p.join(directory.path, 'state')));
  });
  tearDown(() => directory.deleteSync(recursive: true));

  Map<String, Object?> root(String kind, String location, {String? revision}) =>
      {
        'source': {'kind': kind, 'location': location, 'path': '.'},
        'name': p.basename(location),
        'revision': ?revision,
      };

  /// A built candidate as activation records it: a canonical bundle path.
  String built(String id, Map<String, Object?> roots) {
    final bundle = Directory(
      p.join(store.root.path, 'candidates', id, 'bundle'),
    )..createSync(recursive: true);
    store.write('candidates/$id/plan.json', {
      'status': 'built',
      'selectionRevision': 1,
      'roots': roots,
      'selections': <String, Object?>{},
      'ordering': <String, Object?>{},
    });
    store.write('candidates/$id/build.json', {
      'status': 'built',
      'bundle': bundle.resolveSymbolicLinksSync(),
    });
    return bundle.resolveSymbolicLinksSync();
  }

  group('composition identity', () {
    final panel = root('git', 'https://example.org/panel.git', revision: 'a');
    test('built-in roots are the same intent across installed releases', () {
      final plan = {
        'roots': {
          'clock': root('builtin', '/old-kit/runtime/plugins'),
          'panel': panel,
        },
        'selections': {'contract': 'clock'},
      };
      final selection = {
        'roots': {
          'clock': root('builtin', '/new-kit/runtime/plugins'),
          // Resolved revisions are plan state, never selection intent.
          'panel': root('git', 'https://example.org/panel.git', revision: 'b'),
        },
        'selections': {'contract': 'clock'},
        'ordering': <String, Object?>{},
      };
      expect(sameComposition(selection, plan), isTrue);
      expect(
        sameComposition({
          ...selection,
          'selections': {'contract': 'other'},
        }, plan),
        isFalse,
      );
      expect(
        sameComposition({
          ...selection,
          'roots': {
            'clock': root('builtin', '/new-kit/runtime/plugins'),
            'panel': root('git', 'https://example.org/fork.git'),
          },
        }, plan),
        isFalse,
      );
      expect(
        sameComposition({
          ...selection,
          'roots': {'clock': root('builtin', '/new-kit/runtime/plugins')},
        }, plan),
        isFalse,
      );
    });
  });

  test('quiet moments wait for unlocked, idle, uncaptured sessions', () {
    Map<String, Object?> native({
      String operation = 'idle',
      bool locked = false,
      int idle = 3000,
      bool captured = false,
    }) => {
      'operation': operation,
      'session_activity': {
        'locked': locked,
        'input_idle_ms': idle,
        'shell_captures_keyboard': captured,
      },
    };
    expect(untilQuietMoment(native()), isNull);
    expect(
      untilQuietMoment(native(idle: 1000)),
      const Duration(milliseconds: 1600),
    );
    expect(untilQuietMoment(native(locked: true)), isNotNull);
    expect(untilQuietMoment(native(captured: true)), isNotNull);
    expect(
      untilQuietMoment({
        ...native(),
        'session_activity': {'input_idle_ms': 9000, 'idle_inhibited': true},
      }),
      const Duration(seconds: 5),
    );
    expect(untilQuietMoment(native(operation: 'switching_runtime')), isNotNull);
  });

  test('rebuild progress adds the quiet wait before applying', () {
    expect(jobProgress('rebuild', 'Resolving packages with Pub'), {
      'completed': 0,
      'total': 6,
      'label': 'Preparing your plugins',
    });
    expect(jobProgress('rebuild', 'Validating and sealing the bundle'), {
      'completed': 3,
      'total': 6,
      'label': 'Verifying your desktop',
    });
    expect(jobProgress('rebuild', 'Waiting for a pause to switch'), {
      'completed': 4,
      'total': 6,
      'label': 'Switching when you pause',
    });
    expect(jobProgress('rebuild', 'Applying your desktop')?['completed'], 5);
    expect(jobProgress('apply', 'Applying your desktop')?['completed'], 4);
    expect(jobProgress('apply', 'Waiting for a pause to switch'), isNull);
  });

  group('rebuild target', () {
    test('belongs to this manager and to the installed release', () {
      final bundle = built('base', {});
      final native = {
        'plugin_rebuild': {
          'reason': 'source',
          'bundle': bundle,
          'version': '0.3.0',
          'installed_source': {'source_revision': '0.3.0'},
        },
      };
      expect(RebuildTarget.fromNative(store, {}), isNull);
      final target = RebuildTarget.fromNative(store, native)!;
      expect(target.candidate, 'base');
      expect(target.release, isTrue);
      expect(waitsForRebuildOf(store, native, 'base'), isTrue);
      expect(waitsForRebuildOf(store, {}, 'base'), isFalse);

      final runtime = Directory(p.join(directory.path, 'runtime'))
        ..createSync();
      final marker = File(p.join(runtime.path, '.denial-ui-source.json'))
        ..writeAsStringSync('{"source_revision":"0.2.1"}');
      expect(
        () => requireMatchingBuildKit(runtime.path, target),
        throwsA(
          isA<CompositionException>().having(
            (e) => e.message,
            'message',
            buildKitMismatch,
          ),
        ),
      );
      marker.writeAsStringSync('{"source_revision":"0.3.0"}');
      requireMatchingBuildKit(runtime.path, target);

      expect(
        () => RebuildTarget.fromNative(store, {
          'plugin_rebuild': {'bundle': '/elsewhere/candidates/base/bundle'},
        }),
        throwsA(isA<CompositionException>()),
      );
    });

    test('activation switches only while deniald still waits', () async {
      final base = built('base', {});
      final bundle = built('rebuilt', {});
      store.write('candidates/rebuilt/plan.json', {
        ...store.read('candidates/rebuilt/plan.json'),
        'rebuildOf': 'base',
        // A different saved selection remains pending for Apply.
        'selectionRevision': null,
      });
      store.write('selection.json', {...store.selection, 'revision': 9});
      Map<String, Object?> native = {
        'active_mode': 'official_optimized',
        'plugin_healthy': false,
      };
      final transitions = <String>[];
      final activation = CompositionActivation(
        store,
        run: (_, args, {workingDirectory, onOutput}) async {
          if (args[2] == 'activate') {
            transitions.add(args.last);
            return jsonEncode({
              'active_mode': 'custom_optimized',
              'plugin_bundle': bundle,
              'plugin_healthy': true,
            });
          }
          return jsonEncode(native);
        },
      );
      await expectLater(
        activation.activate('rebuilt'),
        throwsA(isA<CompositionException>()),
      );
      expect(transitions, isEmpty);
      native = {
        ...native,
        'plugin_rebuild': {'bundle': base},
      };
      await activation.activate('rebuilt');
      expect(transitions, [bundle]);
    });

    test('the quiet wait ends early when the user chose otherwise', () async {
      final base = built('base', {});
      final statuses = <Map<String, Object?>>[
        {
          'operation': 'idle',
          'plugin_rebuild': {'bundle': base},
          'session_activity': {'locked': true},
        },
        {
          'operation': 'idle',
          'plugin_rebuild': {'bundle': base},
          'session_activity': {'locked': false, 'input_idle_ms': 100},
        },
        {
          'operation': 'idle',
          'plugin_rebuild': {'bundle': base},
          'session_activity': {'locked': false, 'input_idle_ms': 2600},
        },
      ];
      final progress = <String>[];
      final waits = <Duration>[];
      var index = 0;
      expect(
        await waitForQuietMoment(
          store,
          () async => statuses[index++],
          'base',
          progress: progress.add,
          sleep: (duration) async => waits.add(duration),
        ),
        isTrue,
      );
      expect(progress, ['Waiting for a pause to switch']);
      // Waits are sliced so that Plugins' Switch now is noticed quickly.
      expect(
        waits.fold(Duration.zero, (total, wait) => total + wait),
        const Duration(milliseconds: 4500),
      );
      // The user asked to switch now while a video keeps the session busy.
      final busy = {
        'operation': 'idle',
        'plugin_rebuild': {'bundle': base},
        'session_activity': {'locked': false, 'idle_inhibited': true},
      };
      var asked = 0;
      final now = waitForQuietMoment(
        store,
        () async {
          asked++;
          return busy;
        },
        'base',
        sleep: (duration) =>
            Future<void>.delayed(const Duration(milliseconds: 1)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      switchNowRequest(store).writeAsStringSync('');
      expect(await now, isTrue);
      expect(asked, lessThan(4));
      expect(
        await waitForQuietMoment(
          store,
          () async => {'active_mode': 'official_optimized'},
          'base',
          sleep: (_) async {},
        ),
        isFalse,
      );
    });
  });

  test('a rebuild plans the confirmed composition, pins and lock for the new release', () async {
    final runtime = p.join(directory.path, 'new-kit/runtime');
    void package(String path, Map<String, Object?> pubspec) {
      Directory(path).createSync(recursive: true);
      File(p.join(path, 'pubspec.yaml')).writeAsStringSync(
        jsonEncode({
          'environment': {'sdk': '^3.13.0'},
          ...pubspec,
        }),
      );
    }

    package(p.join(runtime, 'packages/denial_sdk'), {
      'name': 'denial_sdk',
      'version': '0.3.0',
    });
    package(p.join(runtime, 'packages/denial_flutter_sdk'), {
      'name': 'denial_flutter_sdk',
      'version': '0.3.0',
    });
    package(p.join(runtime, 'plugins/clock'), {'name': 'denial_clock'});
    File(p.join(runtime, 'plugins/builtins.yaml'))
        .writeAsStringSync('schema: 1\nplugins:\n  - path: clock\n');
    const url = 'https://example.org/panel.git';
    final confirmed = 'a' * 40;
    final cache = Directory(p.join(store.root.path, 'repositories'));
    final key = sha256.convert(utf8.encode(url)).toString();
    Directory(p.join(cache.path, '$key.git')).createSync(recursive: true);
    package(p.join(cache.path, '$key-$confirmed'), {'name': 'panel'});

    final roots = {
      'denial_clock': root('builtin', '/old-kit/runtime/plugins'),
      'panel': root('git', url, revision: confirmed),
    };
    built('base', roots);
    File(p.join(store.root.path, 'candidates/base/app/pubspec.lock'))
        .createSync(recursive: true);
    File(p.join(store.root.path, 'candidates/base/app/pubspec.lock'))
        .writeAsStringSync('# confirmed lock\n');
    // A newer, never confirmed plan must not leak into the rebuild.
    built('newer', {'panel': root('git', url, revision: 'c' * 40)});
    store.write('last-plan.json', {'id': 'newer'});
    store.write('selection.json', {
      'revision': 4,
      'roots': {
        'denial_clock': root('builtin', p.join(runtime, 'plugins')),
        'panel': root('git', url, revision: 'b' * 40),
      },
      'selections': <String, Object?>{},
      'ordering': <String, Object?>{},
    });

    Map<String, Object?>? manifest;
    String? lock;
    List<String>? pub;
    final planner = WorkspacePlanner(
      store: store,
      repository: SourceRepository(
        cache,
        run: (_, _, {workingDirectory, onOutput}) async =>
            throw StateError('Pinned revisions must not fetch'),
      ),
      run: (executable, arguments, {workingDirectory, onOutput}) async {
        pub = arguments;
        manifest = jsonDecode(
          File(p.join(workingDirectory!, 'pubspec.yaml')).readAsStringSync(),
        ) as Map<String, Object?>;
        lock = File(p.join(workingDirectory, 'pubspec.lock'))
            .readAsStringSync();
        throw const CompositionException('stop after resolution inputs');
      },
    );
    await expectLater(
      planner.plan(
        runtimeRoot: runtime,
        flutter: '/unused/flutter',
        candidateId: 'rebuilt',
        rebuildOf: 'base',
      ),
      throwsA(isA<CompositionException>()),
    );
    expect(pub, ['pub', 'get']);
    expect(lock, '# confirmed lock\n');
    final dependencies = manifest!['dependencies']! as Map;
    expect((dependencies['panel'] as Map)['git'], {
      'url': url,
      'path': '.',
      'ref': confirmed,
    });
    expect(
      (dependencies['denial_clock'] as Map)['path'],
      '../packages/denial_clock',
    );

    await expectLater(
      planner.plan(
        runtimeRoot: runtime,
        flutter: '/unused/flutter',
        candidateId: 'updated',
        rebuildOf: 'base',
        update: true,
      ),
      throwsA(isA<CompositionException>()),
    );
    await expectLater(
      planner.plan(
        runtimeRoot: runtime,
        flutter: '/unused/flutter',
        candidateId: 'missing',
        rebuildOf: 'forgotten',
      ),
      throwsA(
        isA<CompositionException>().having(
          (e) => e.message,
          'message',
          contains('can no longer be rebuilt'),
        ),
      ),
    );
  });

  group('resume', () {
    late FakeNotifier notifier;
    late Map<String, Object?> native;
    late String base;
    final submitted = <List<String>>[];
    final opened = <String?>[];
    bool? connected;

    setUp(() {
      notifier = FakeNotifier();
      submitted.clear();
      opened.clear();
      connected = null;
      base = built('base', {
        'panel': root('git', 'https://example.org/panel.git', revision: 'a'),
      });
      native = {
        'active_mode': 'official_optimized',
        'operation': 'idle',
        'plugin_healthy': false,
        'plugin_rebuild': {
          'reason': 'source',
          'bundle': base,
          'version': '0.3.0',
        },
      };
    });

    var unavailable = 0;
    PluginResume resume() => PluginResume(
      store: store,
      status: () async =>
          unavailable-- > 0 ? const {'available': false} : native,
      submit: (argv) async {
        submitted.add(argv);
        final id = store.createJob(argv.first, {'argv': argv});
        store.updateJob(id, {
          'phase': 'running',
          'pid': pid,
          'processStart': ManagerStore.processStart(pid),
        });
        return id;
      },
      notifier: notifier,
      kitIdentity: 'kit',
      openPlugins: (token) async => opened.add(token),
      online: () async => connected,
      tick: const Duration(milliseconds: 1),
    );

    String job() => store.read('resume.json')['job']! as String;

    test('restores the plugins and thanks the user', () async {
      // The control socket may answer only once deniald's loop runs.
      unavailable = 3;
      final running = resume().run();
      await until(() => notifier.shown.isNotEmpty);
      expect(submitted, [
        ['rebuild'],
      ]);
      final progress = notifier.shown.single;
      expect(progress.content.title, 'Bringing back your plugins');
      expect(progress.content.body, contains('Denial 0.3.0 is installed'));
      expect(progress.content.body, contains('No need to log out'));
      expect(progress.content.persistent, isTrue);
      notifier.emit(NotificationActionInvoked(progress.id, 'open', 'token'));
      await until(() => opened.isNotEmpty);
      expect(opened, ['token']);

      store.updateJob(job(), {'phase': 'succeeded'});
      native = {
        'active_mode': 'custom_optimized',
        'operation': 'idle',
        'plugin_healthy': true,
      };
      await until(() => notifier.shown.length == 2);
      final restored = notifier.shown.last;
      expect(restored.replaces, progress.id);
      expect(restored.content.title, 'Your plugins are back');
      expect(restored.content.body, contains('now on Denial 0.3.0'));
      expect(restored.content.actions, [('whats-new', "What's new")]);
      expect(store.read('resume.json')['outcome'], 'succeeded');
      notifier.emit(NotificationClosed(restored.id));
      await running;
    });

    test(
      'a failure offers recovery once, then later logins only remind',
      () async {
        final running = resume().run();
        await until(() => notifier.shown.isNotEmpty);
        store.updateJob(job(), {
          'phase': 'failed',
          'error': 'panel requires denial_sdk ^0.2.0; selected SDK is 0.3.0.',
        });
        await until(() => notifier.shown.length == 2);
        final failed = notifier.shown.last;
        expect(failed.content.title, "Your plugins couldn't be rebuilt");
        expect(failed.content.body, contains('may need an update'));
        expect(failed.content.body, contains('settings are safe'));
        expect(failed.content.actions.map((action) => action.$1), [
          'retry',
          'update',
          'open',
          'default',
        ]);
        expect(store.read('resume.json')['outcome'], 'failed');
        notifier.emit(NotificationActionInvoked(failed.id, 'retry', null));
        await until(() => submitted.length == 2);
        expect(submitted.last, ['rebuild', '--now']);
        await until(() => notifier.shown.length == 3);
        expect(notifier.shown.last.replaces, failed.id);
        store.updateJob(job(), {'phase': 'failed', 'error': 'still broken'});
        await until(() => notifier.shown.length == 4);
        notifier.emit(NotificationClosed(notifier.shown.last.id));
        await running;

        // The next login does not compile the same failure again.
        final reminder = FakeNotifier();
        notifier = reminder;
        final later = resume().run();
        await until(() => reminder.shown.isNotEmpty);
        expect(
          reminder.shown.single.content.title,
          'Your plugins are still paused',
        );
        expect(submitted, hasLength(2));
        reminder.emit(NotificationClosed(reminder.shown.single.id));
        await later;
      },
    );

    test('waits for a connection and continues by itself', () async {
      final running = resume().run();
      await until(() => notifier.shown.isNotEmpty);
      connected = false;
      store.updateJob(job(), {
        'phase': 'failed',
        'error': "SocketException: Failed host lookup: 'pub.dev'",
      });
      await until(() => notifier.shown.length == 2);
      expect(
        notifier.shown.last.content.title,
        'Your plugins are waiting for a connection',
      );
      expect(store.read('resume.json')['outcome'], 'offline');
      connected = true;
      await until(() => submitted.length == 2);
      expect(submitted.last, ['rebuild']);
      await until(() => notifier.shown.length == 3);
      expect(notifier.shown.last.content.body, contains('back online'));
      store.updateJob(job(), {'phase': 'succeeded'});
      native = {'active_mode': 'custom_optimized', 'plugin_healthy': true};
      await until(() => notifier.shown.length == 4);
      notifier.emit(NotificationClosed(notifier.shown.last.id));
      await running;
    });

    test('closes the failure once Plugins fixed it', () async {
      final running = resume().run();
      await until(() => notifier.shown.isNotEmpty);
      store.updateJob(job(), {'phase': 'failed', 'error': 'broken'});
      await until(() => notifier.shown.length == 2);
      native = {'active_mode': 'custom_optimized', 'plugin_healthy': true};
      await running;
      expect(notifier.closed, [notifier.shown.last.id]);
    });

    test('says plainly when the composition cannot be rebuilt', () async {
      native = {
        ...native,
        'plugin_rebuild': {
          'bundle': '/elsewhere/candidates/base/bundle',
          'version': 'development',
        },
      };
      final running = resume().run();
      await until(() => notifier.shown.isNotEmpty);
      final failed = notifier.shown.single;
      expect(submitted, isEmpty);
      expect(failed.content.body, contains("can't be rebuilt automatically"));
      // A development build identity is never shown as a release.
      expect(failed.content.body, isNot(contains('development')));
      expect(failed.content.actions.map((action) => action.$1), [
        'open',
        'default',
      ]);
      notifier.emit(NotificationClosed(failed.id));
      await running;
    });
  });

  test('desktop entries launch without field codes', () {
    final data = Directory(p.join(directory.path, 'data/applications'))
      ..createSync(recursive: true);
    File(
      p.join(data.path, 'dev.denial.PluginManager.desktop'),
    ).writeAsStringSync(
      '[Desktop Entry]\nName=Plugins\nExec="/opt/my apps/plugins" --flag %U\n'
      '[Desktop Action other]\nExec=/wrong\n',
    );
    expect(
      desktopEntryCommand(
        'dev.denial.PluginManager.desktop',
        environment: {
          'XDG_DATA_HOME': p.dirname(data.path),
          'XDG_DATA_DIRS': '/nonexistent',
        },
      ),
      ['/opt/my apps/plugins', '--flag'],
    );
    expect(
      desktopEntryCommand(
        'missing.desktop',
        environment: {'XDG_DATA_HOME': p.dirname(data.path)},
      ),
      isNull,
    );
  });
}

Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition was not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

final class Shown {
  Shown(this.id, this.content, this.replaces);
  final int id;
  final NotificationContent content;
  final int replaces;
}

final class FakeNotifier implements Notifier {
  final _events = StreamController<NotificationEvent>.broadcast();
  final shown = <Shown>[];
  final closed = <int>[];
  var _next = 0;

  void emit(NotificationEvent event) => _events.add(event);

  @override
  Stream<NotificationEvent> get events => _events.stream;

  @override
  Future<int> show(NotificationContent content, {int replaces = 0}) async {
    final id = replaces == 0 ? ++_next : replaces;
    shown.add(Shown(id, content, replaces));
    return id;
  }

  @override
  Future<void> close(int id) async => closed.add(id);

  @override
  Future<void> dispose() => _events.close();
}
