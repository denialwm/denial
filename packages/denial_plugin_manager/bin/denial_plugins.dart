import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:denial_plugin_manager/denial_plugin_manager.dart';
import 'package:path/path.dart' as p;

final parser = ArgParser()
  ..addOption('state', help: 'Internal manager state directory', hide: true)
  ..addOption(
    'draft',
    help: 'Internal selection draft JSON, committed by Apply',
    hide: true,
  )
  ..addOption('ref', help: 'add: Git branch, tag, or commit')
  ..addOption(
    'path',
    defaultsTo: '.',
    help: 'add: package path within the repository',
  )
  ..addFlag('local', negatable: false, hide: true)
  ..addFlag('builtin', negatable: false, hide: true)
  ..addFlag(
    'update',
    negatable: false,
    help: 'apply: also move Git plugins to their newest revision',
  )
  ..addFlag('now', negatable: false, hide: true)
  ..addFlag('json', negatable: false, help: 'Print JSON instead of text')
  ..addFlag('brief', negatable: false, hide: true)
  ..addFlag('help', negatable: false);

/// Set by a background request for the command it runs.
const requestVariable = 'DENIAL_PLUGINS_JOB';

const usage = '''
Denial plugins

  denial-plugins status         What runs now, why, and what to do next
  denial-plugins list           Plugins you can use, and which are on
  denial-plugins add PLUGIN     Turn a plugin on: a name from list, a folder, or a Git URL
  denial-plugins remove PLUGIN  Turn a plugin off
  denial-plugins defaults       Select the plugins Denial comes with, and only them
  denial-plugins apply          Build your selection and switch the desktop to it
  denial-plugins undo           Go back to the plugins that ran before
  denial-plugins off            Use the standard desktop; your selection is kept
  denial-plugins history        What was asked lately, and how it ended

add and remove only change the selection. Nothing changes on screen until apply.
''';

Future<void> main(List<String> arguments) async {
  try {
    final options = parser.parse(arguments);
    if (options.flag('help') || options.rest.isEmpty) {
      stdout.writeln('$usage\n${parser.usage}');
      return;
    }
    final store = ManagerStore(
      options.option('state') == null
          ? ManagerStore.defaultRoot()
          : Directory(options.option('state')!).absolute,
    );
    final repositories = SourceRepository(
      Directory(p.join(store.root.path, 'repositories')),
    );
    final installation = PluginInstallation.discover();
    final tools = BuildTools.of(store, installation);
    final settings = Map<String, Object?>.of(tools.configuration);
    final available = AvailablePlugins(store, repositories);
    String? setting(String key) => settings[key] as String?;
    List<String> flutterArguments() =>
        (settings['flutter-arguments'] as List?)?.cast<String>() ?? const [];
    final activation = CompositionActivation(
      store,
      denialctl: installation.denialctl,
    );
    Future<void> initialize() async {
      settings
        ..clear()
        ..addAll(await tools.initialize(progress: stderr.writeln));
    }

    bool initialized() =>
        tools.ready && store.read('initialization.json')['complete'] == true;
    // People read text; the app and the background worker read JSON.
    final json = options.flag('json') || options.flag('brief');
    Object? result;
    String? text;
    switch (options.rest) {
      case ['submit', ...final operation]:
        final forwarded = <String>[...operation];
        for (final option in ['ref', 'path', 'draft']) {
          if (options.wasParsed(option)) {
            forwarded.addAll(['--$option', options.option(option)!]);
          }
        }
        for (final flag in ['local', 'builtin', 'update', 'now']) {
          if (options.wasParsed(flag)) {
            forwarded.add(options.flag(flag) ? '--$flag' : '--no-$flag');
          }
        }
        result = {'job': await JobWorker(store).submit(forwarded)};
      case ['worker', final id]:
        await JobWorker(store).run(id, (argv) async {
          // Same CLI/backend operation in a process independent of the GUI.
          final packageConfig = Platform.executableArguments
              .where((a) => a.startsWith('--packages='))
              .toList();
          final command = <String>[
            if (Platform.script.path.endsWith('.dart')) ...[
              ...packageConfig,
              Platform.script.toFilePath(),
            ],
            '--state',
            store.root.path,
            '--json',
            ...argv,
          ];
          // What the request runs inside itself is marked as its own.
          final process = await Process.start(
            Platform.resolvedExecutable,
            command,
            environment: {requestVariable: id},
          );
          final output = StringBuffer();
          final errorLines = <String>[];
          Map<String, Object?>? lastProgress;
          final stdoutDone = process.stdout
              .transform(utf8.decoder)
              .listen(output.write)
              .asFuture<void>();
          final stderrDone = process.stderr
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen((line) {
                errorLines.add(line);
                if (errorLines.length > 200) errorLines.removeAt(0);
                if (line.trim().isNotEmpty) {
                  final progress = jobProgress(argv.first, line);
                  if (progress != null) {
                    final samePhase =
                        lastProgress?['label'] == progress['label'] &&
                        lastProgress?['completed'] == progress['completed'];
                    progress['started'] = samePhase
                        ? lastProgress!['started']
                        : DateTime.now().toUtc().toIso8601String();
                    lastProgress = progress;
                  }
                  store.updateJob(id, {'message': line, 'progress': ?progress});
                }
                store
                    .file('jobs/$id.progress.log')
                    .writeAsStringSync('$line\n', mode: FileMode.append);
              })
              .asFuture<void>();
          final code = await process.exitCode;
          await Future.wait([stdoutDone, stderrDone]);
          if (code != 0) {
            throw CompositionException(operationFailure(errorLines, code));
          }
          return jsonDecode(output.toString());
        });
        return;
      case ['bootstrap']:
        Map<String, Object?>? pending() {
          final jobs = store.jobs().where(
            (job) =>
                job['operation'] == 'initialize' &&
                {'queued', 'running'}.contains(job['phase']),
          );
          return jobs.isEmpty ? null : {'job': jobs.first['id']};
        }

        result = initialized()
            ? {'ready': true}
            : pending() ??
                  await store.exclusive(
                    () async => initialized()
                        ? {'ready': true}
                        : pending() ??
                              {
                                'job': await JobWorker(store)
                                    .submit(['initialize']),
                              },
                  );
      case ['job-details', final id]:
        ManagerStore.validateId(id);
        final log = store.file('jobs/$id.progress.log');
        result = {
          'job': store.read('jobs/$id.json'),
          'log': log.existsSync() ? log.readAsStringSync() : '',
        };
      case ['catalog']:
        result = await available.list(settings);
      case ['list']:
        final catalog = await available.list(settings);
        final report = listReport(store, catalog);
        result = report;
        text = describePlugins(
          (report['plugins']! as List).cast<Map<String, Object?>>(),
        );
      case ['history']:
        final history = historyReport(store.jobs());
        result = history;
        text = describeHistory(history);
      case ['status']:
        final native = await activation.status();
        final selection = store.selection;
        final last = store.read('last-plan.json');
        final installed = store.read(
          'installed.json',
          fallback: {'plugins': selection['roots']},
        );
        final running = activation.runningCandidate(native);
        final state = <String, Object?>{
          'plan': last['id'] is String
              ? store.read('candidates/${last['id']}/plan.json')
              : <String, Object?>{},
          'build': last['id'] is String
              ? store.read('candidates/${last['id']}/build.json')
              : <String, Object?>{},
          'native': native,
          'configuration': settings,
          'buildKitAvailable': tools.available,
          'problem': tools.problem,
          'dart': tools.dartStatus,
          'ready': initialized(),
          'selection': selection,
          'declarations': SelectionPreflight(store).describe({
            ...installed['plugins']! as Map,
            ...selection['roots']! as Map,
          }),
          'preflight': SelectionPreflight(store).check(selection: selection),
          'installed': installed,
          'lastPlan': last,
          // What deniald runs, when this manager built it. deniald is the
          // only record; nothing is kept here.
          'active': {
            'id': running,
            'bundle': running == null ? null : native['plugin_bundle'],
            'previous': activation.candidateOf(native['plugin_previous']),
          },
          'jobs': store.jobs(),
        };
        state['summary'] = summarize(store, state);
        result = state;
        text = describeStatus(state['summary']! as Map<String, Object?>);
        if (options.flag('brief')) {
          state['plan'] = {
            for (final entry
                in (state['plan']! as Map<String, Object?>).entries)
              if ({
                'id',
                'roots',
                'discovery',
                'status',
                'selectionRevision',
              }.contains(entry.key))
                entry.key: entry.value,
          };
          // The app needs activation identity to distinguish a pending
          // selection from a built composition already running on the desktop.
          state['build'] = {
            for (final entry
                in (state['build']! as Map<String, Object?>).entries)
              if ({'status', 'bundle', 'reusedFrom'}.contains(entry.key))
                entry.key: entry.value,
          };
          state['jobs'] = [
            for (final job in (state['jobs']! as List<Map<String, Object?>>))
              if (((job['arguments'] as Map?)?.containsKey('argv') ?? false) ||
                  job['phase'] == 'running' ||
                  job['phase'] == 'queued')
                {
                  for (final entry in job.entries)
                    if (entry.key != 'result') entry.key: entry.value,
                },
          ];
        }
      case ['rebuild']:
        result = await rebuild(
          store: store,
          repositories: repositories,
          activation: activation,
          initialize: () async {
            await initialize();
            return settings;
          },
          now: options.flag('now'),
        );
      case ['resume']:
        await resume(store, activation, tools);
        return;
      case ['rebuild-now']:
        // Not a mutation: a waiting rebuild owns the switch and its checks.
        store.root.createSync(recursive: true);
        switchNowRequest(store).writeAsStringSync('');
        result = {'requested': true};
      case ['discover', final workspace]:
        await store.exclusive(initialize);
        final flutter = setting('flutter')!;
        result = (await PluginDiscovery(
          sdkPath: p.join(
            p.dirname(File(flutter).resolveSymbolicLinksSync()),
            'cache/dart-sdk',
          ),
          cacheDirectory: store.file('cache/analyzer').path,
        ).discover(PackageGraph.read(p.absolute(workspace)))).toJson();
      default:
        result = await store.exclusive(() async {
          await initialize();
          PluginSource source(String location) => PluginSource(
            kind: options.flag('local')
                ? SourceKind.local
                : options.flag('builtin')
                ? SourceKind.builtin
                : SourceKind.git,
            location: location,
            path: options.option('path')!,
            ref: options.option('ref'),
          );
          Future<ResolvedSource> enable(String name) async {
            final installed = store.read('installed.json')['plugins'] as Map?;
            final value = installed?[name] as Map<String, Object?>?;
            if (value == null) {
              throw CompositionException(
                '$name is not a plugin you have. See denial-plugins list.',
              );
            }
            final retained = PluginSource.fromJson(
              value['source']! as Map<String, Object?>,
            );
            final plugin = await repositories.resolve(
              retained,
              pinnedRevision: retained.kind == SourceKind.git
                  ? value['revision'] as String?
                  : null,
            );
            store.select(plugin);
            return plugin;
          }

          switch (options.rest) {
            case ['initialize'] || ['prepare']:
              return settings;
            case ['defaults']:
              await available.defaults(setting('runtime'));
              text = 'The plugins Denial comes with are selected. denial-plugins apply switches the desktop to them.';
              return store.selection;
            case ['refresh-catalog']:
              return available.refresh(settings);
            case ['off'] || ['restore']:
              stderr.writeln('Applying your desktop');
              final native = await activation.restore();
              text = 'The standard desktop is running. Your selection is kept: denial-plugins apply brings it back.';
              return native;
            case ['undo'] || ['revert']:
              stderr.writeln('Applying your desktop');
              final native = await activation.revert();
              text = 'The plugins that ran before are running again.';
              return native;
            case ['inspect', final location]:
              return repositories.inspect(source(location));
            case ['add', final location]:
              // A name from the list, a folder, or a Git URL.
              final ResolvedSource plugin;
              final flagged = options.flag('local') || options.flag('builtin');
              final catalog = flagged || location.contains('/')
                  ? null
                  : pluginList(store, await available.list(settings)).where((
                      Map<String, Object?> entry,
                    ) {
                      return entry['name'] == location;
                    }).firstOrNull;
              if (catalog != null) {
                plugin = catalog['installed'] == true
                    ? await enable(location)
                    : await repositories.resolve(
                        PluginSource.fromJson(
                          catalog['source']! as Map<String, Object?>,
                        ),
                      );
              } else if (!flagged && Directory(location).existsSync()) {
                plugin = await repositories.resolve(
                  PluginSource(
                    kind: SourceKind.local,
                    location: Directory(location).absolute.path,
                    path: options.option('path')!,
                  ),
                );
              } else {
                plugin = await repositories.resolve(source(location));
              }
              store.select(plugin);
              text =
                  '${plugin.name} is selected. denial-plugins apply switches the desktop to it.';
              return plugin.toJson();
            case ['enable', final name]:
              return (await enable(name)).toJson();
            case ['remove', final package]:
              store.remove(package);
              text =
                  '$package is no longer selected. denial-plugins apply switches the desktop.';
              return store.selection;
            case ['plan'] || ['apply'] || ['update']:
              final runtime = setting('runtime');
              final flutter = setting('flutter');
              final engineRoot = setting('engine-root');
              if (runtime == null || flutter == null || engineRoot == null) {
                throw const CompositionException(
                  'Installed source and release compiler are incomplete',
                );
              }
              final check = options.rest.single == 'plan';
              if (options.option('draft') case final String draft) {
                if (check) {
                  throw const CompositionException(
                    'Only Apply can commit a selection draft.',
                  );
                }
                await activation.requireSupport();
                await commitSelectionDraft(
                  store,
                  repositories,
                  jsonDecode(draft) as Map<String, Object?>,
                );
              }
              SelectionPreflight(store).requireValid();
              if (!check) await activation.requireSupport();
              final id = store.createJob('plan', {
                'runtime': runtime,
                'flutter': flutter,
                'command': options.rest.single,
                'request': ?Platform.environment[requestVariable],
              });
              store.updateJob(id, {'phase': 'running', 'pid': pid});
              // Status shows the step also for a run started from a terminal.
              void say(String phase) {
                stderr.writeln(phase);
                store.updateJob(id, {'message': phase});
              }

              try {
                final result =
                    await WorkspacePlanner(
                      store: store,
                      repository: repositories,
                    ).plan(
                      runtimeRoot: p.absolute(runtime),
                      flutter: p.absolute(flutter),
                      flutterArguments: flutterArguments(),
                      candidateId: id,
                      update:
                          options.flag('update') ||
                          options.rest.single == 'update',
                      sdkRoot: Platform.environment['DENIAL_SDK_PATH'],
                      progress: say,
                    );
                if (!check) {
                  await CompositionBuilder(store).build(
                    id,
                    engineRoot: p.absolute(engineRoot),
                    engineTarget: setting('engine-target')!,
                    platform: setting('platform')!,
                    progress: say,
                  );
                  say('Applying your desktop');
                  final native = await activation.activate(id);
                  text = native['plugin_engine_differs'] == true
                      ? 'Your plugins are running. They were built for another engine than this session runs, and loaded anyway.'
                      : 'Your plugins are running.';
                }
                store.updateJob(id, {'phase': 'succeeded', 'candidate': id});
                return result;
              } catch (error) {
                store.updateJob(id, {'phase': 'failed', 'error': '$error'});
                rethrow;
              }
            default:
              throw CompositionException(
                'Unknown command: ${options.rest.join(' ')}\n\n$usage',
              );
          }
        });
    }
    stdout.writeln(
      json || text == null
          ? const JsonEncoder.withIndent('  ').convert(result)
          : text,
    );
  } catch (error) {
    stderr.writeln('denial-plugins: $error');
    exitCode = 1;
  }
}

/// Rebuilds the composition deniald was running before Denial was updated
/// (PLUGIN_MANAGER.md section 21). The manager lock is released while waiting
/// for a quiet moment, so Plugins stays usable.
Future<Map<String, Object?>> rebuild({
  required ManagerStore store,
  required SourceRepository repositories,
  required CompositionActivation activation,
  required Future<Map<String, Object?>> Function() initialize,
  required bool now,
}) async {
  final built = await store.exclusive(() async {
    // Only a request made while this rebuild waits may skip the wait.
    final request = switchNowRequest(store);
    if (request.existsSync()) request.deleteSync();
    final settings = await initialize();
    final target = RebuildTarget.fromNative(store, await activation.status());
    if (target == null) return null;
    final runtime = settings['runtime'] as String?;
    final flutter = settings['flutter'] as String?;
    final engineRoot = settings['engine-root'] as String?;
    if (runtime == null || flutter == null || engineRoot == null) {
      throw const CompositionException(
        'Installed source and release compiler are incomplete',
      );
    }
    requireMatchingBuildKit(runtime, target);
    await activation.requireSupport();
    final flutterArguments =
        (settings['flutter-arguments'] as List?)?.cast<String>() ?? const [];
    final id = store.createJob('plan', {
      'runtime': runtime,
      'flutter': flutter,
      'rebuildOf': target.candidate,
      'command': 'rebuild',
      'request': ?Platform.environment[requestVariable],
    });
    store.updateJob(id, {'phase': 'running', 'pid': pid});
    try {
      await WorkspacePlanner(store: store, repository: repositories).plan(
        runtimeRoot: p.absolute(runtime),
        flutter: p.absolute(flutter),
        flutterArguments: flutterArguments,
        candidateId: id,
        rebuildOf: target.candidate,
        sdkRoot: Platform.environment['DENIAL_SDK_PATH'],
        progress: (phase) {
          stderr.writeln(phase);
          store.updateJob(id, {'message': phase});
        },
      );
      await CompositionBuilder(store).build(
        id,
        engineRoot: p.absolute(engineRoot),
        engineTarget: settings['engine-target']! as String,
        platform: settings['platform']! as String,
        progress: stderr.writeln,
      );
      store.updateJob(id, {'phase': 'succeeded', 'candidate': id});
    } catch (error) {
      store.updateJob(id, {'phase': 'failed', 'error': '$error'});
      rethrow;
    }
    return (candidate: id, base: target.candidate);
  });
  if (built == null) return {'rebuilt': false, 'switched': false};
  final (:candidate, :base) = built;
  final unchanged = {
    'rebuilt': true,
    'switched': false,
    'candidate': candidate,
  };
  if (!now &&
      !await waitForQuietMoment(
        store,
        activation.status,
        base,
        progress: stderr.writeln,
      )) {
    return unchanged;
  }
  return store.exclusive(() async {
    final request = switchNowRequest(store);
    if (request.existsSync()) request.deleteSync();
    if (!waitsForRebuildOf(store, await activation.status(), base)) {
      return unchanged;
    }
    stderr.writeln('Applying your desktop');
    return {
      ...unchanged,
      'switched': true,
      'native': await activation.activate(candidate),
    };
  }, wait: const Duration(minutes: 2));
}

/// Started by deniald after an update left its plugins behind. It submits the
/// rebuild and keeps one notification about it until nothing is left to do.
Future<void> resume(
  ManagerStore store,
  CompositionActivation activation,
  BuildTools kit,
) async {
  store.root.createSync(recursive: true);
  final lock = await store.file('resume.lock').open(mode: FileMode.append);
  try {
    try {
      await lock.lock(FileLock.exclusive);
    } on FileSystemException {
      return; // Another resume already keeps the user informed.
    }
    final Notifier notifier;
    try {
      notifier = await DesktopNotifications.connect();
    } catch (error) {
      // Without notifications the rebuild still runs; Plugins shows it.
      stderr.writeln('denial-plugins: notifications are unavailable: $error');
      if (RebuildTarget.fromNative(store, await activation.status()) != null) {
        await JobWorker(store).submit(['rebuild']);
      }
      return;
    }
    final plugins = desktopEntryCommand('dev.denial.PluginManager.desktop');
    try {
      await PluginResume(
        store: store,
        status: activation.status,
        submit: JobWorker(store).submit,
        notifier: notifier,
        kitIdentity: kit.available ? kit.identity : null,
        openPlugins: plugins == null
            ? null
            : (token) => launchDetached(plugins, activationToken: token),
        openUrl: (url, token) =>
            launchDetached(['xdg-open', url], activationToken: token),
        online: networkConnected,
      ).run();
    } finally {
      await notifier.dispose();
    }
  } finally {
    await lock.close();
  }
}
