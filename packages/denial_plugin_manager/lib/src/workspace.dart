import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import 'generator.dart';
import 'discovery.dart';
import 'sdk_boundary.dart';
import 'model.dart';
import 'package_graph.dart';
import 'source.dart';
import 'store.dart';
import 'available.dart';
import 'tools.dart';

const shellApplication = TypeId(
  'package:denial_flutter_sdk/application.dart',
  'ShellApplication',
);

/// Copies path packages into an isolated, self-contained source snapshot.
/// Dependencies are read from pubspecs; this never invents dependency edges.
final class PackageSnapshot {
  PackageSnapshot(this.destination, {this.packageOverrides = const {}});
  final Map<String, String> packageOverrides;
  final Directory destination;
  final Map<String, String> originals = {};
  final Map<String, String> snapshots = {};

  String copy(String source) {
    final canonical = Directory(source).resolveSymbolicLinksSync();
    final manifest = readYamlMap(File(p.join(canonical, 'pubspec.yaml')));
    final name = manifest['name']! as String;
    final override = packageOverrides[name];
    if (override != null &&
        Directory(override).resolveSymbolicLinksSync() != canonical) {
      return copy(override);
    }
    if (originals.containsKey(name)) {
      if (originals[name] != canonical) {
        throw CompositionException(
          'Package $name has conflicting local sources: ${originals[name]} and $canonical',
        );
      }
      return snapshots[name]!;
    }
    final target = p.join(destination.path, name);
    originals[name] = canonical;
    snapshots[name] = target;
    copySourceTree(Directory(canonical), Directory(target));
    // Installed/plugin-cache sources can be read-only. File.copy preserves
    // those modes, but this private snapshot must permit manifest rewriting
    // and normal generated-source output without changing the original tree.
    final writable = Process.runSync('chmod', ['-R', 'u+rwX', '--', target]);
    if (writable.exitCode != 0) {
      throw CompositionException(
        'Cannot prepare writable snapshot $name: ${writable.stderr}',
      );
    }
    manifest.remove('dev_dependencies');
    manifest.remove('dependency_overrides');
    manifest.remove('workspace');
    manifest.remove('resolution');
    final dependencies = Map<String, Object?>.from(
      manifest['dependencies'] as Map? ?? {},
    );
    for (final entry in dependencies.entries.toList()) {
      final value = entry.value;
      if (value is Map && value['path'] is String) {
        final dependency = copy(
          packageOverrides[entry.key] ??
              p.normalize(p.join(canonical, value['path'] as String)),
        );
        dependencies[entry.key] = {
          'path': p.relative(dependency, from: target),
          if (value['version'] != null) 'version': value['version'],
        };
      }
    }
    manifest['dependencies'] = dependencies;
    File(
      p.join(target, 'pubspec.yaml'),
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(manifest));
    // Source-only inputs never inherit a developer's package configuration,
    // lockfile overrides, analysis session, or generated build output.
    for (final name in ['pubspec_overrides.yaml', 'pubspec.lock']) {
      final file = File(p.join(target, name));
      if (file.existsSync()) file.deleteSync();
    }
    return target;
  }
}

void copySourceTree(
  Directory source,
  Directory destination, {
  String? sourceRoot,
}) {
  sourceRoot ??= source.path;
  destination.createSync(recursive: true);
  for (final entry in source.listSync(followLinks: false)) {
    final name = p.basename(entry.path);
    final relative = p.relative(entry.path, from: sourceRoot);
    if ({
      'linux/flutter/ephemeral',
      'windows/flutter/ephemeral',
      'macos/Flutter/ephemeral',
    }.contains(relative)) {
      continue;
    }
    if ({
      '.git',
      '.dart_tool',
      'build',
      '.flutter-plugins',
      '.flutter-plugins-dependencies',
      'pubspec_overrides.yaml',
    }.contains(name)) {
      continue;
    }
    final target = p.join(destination.path, name);
    if (entry is Directory) {
      copySourceTree(entry, Directory(target), sourceRoot: sourceRoot);
    } else if (entry is File) {
      entry.copySync(target);
    } else if (entry is Link) {
      // Reject links rather than accidentally reading mutable external inputs.
      throw CompositionException(
        'Source snapshot contains a symlink: ${entry.path}',
      );
    }
  }
}

/// Whether the saved [selection] asks for the composition that [plan] was
/// built from. Built-in sources move with every installed release, so their
/// names are the intent; Git and local roots must keep their source. Resolved
/// Git revisions are plan state, never selection intent.
bool sameComposition(
  Map<String, Object?> selection,
  Map<String, Object?> plan,
) {
  Map<String, Object?> map(Object? value) =>
      value is Map ? value.cast<String, Object?>() : const {};
  final saved = map(selection['roots']);
  final built = map(plan['roots']);
  if (saved.length != built.length) return false;
  for (final entry in saved.entries) {
    if (!built.containsKey(entry.key)) return false;
    final wanted = map(map(entry.value)['source']);
    final used = map(map(built[entry.key])['source']);
    if (wanted['kind'] == 'builtin' && used['kind'] == 'builtin') continue;
    if (contentKey(wanted) != contentKey(used)) return false;
  }
  return contentKey(map(selection['selections'])) ==
          contentKey(map(plan['selections'])) &&
      contentKey(map(selection['ordering'])) ==
          contentKey(map(plan['ordering']));
}

final class WorkspacePlanner {
  WorkspacePlanner({
    required this.store,
    required this.repository,
    this.run = runCommand,
  });
  final ManagerStore store;
  final SourceRepository repository;
  final CommandRunner run;

  /// [runtimeRoot] is the installed source template, or a development
  /// checkout that is read as it is now. [flutterArguments] precede every
  /// Flutter command.
  ///
  /// [rebuildOf] plans the composition of that earlier candidate, rather than
  /// the saved selection, for the installed release: its roots, provider
  /// choices, Pub lock and Git revisions. It never fetches newer revisions.
  Future<Map<String, Object?>> plan({
    required String runtimeRoot,
    required String flutter,
    List<String> flutterArguments = const [],
    required String candidateId,
    bool update = false,
    String? rebuildOf,
    String? sdkRoot,
    void Function(String)? progress,
  }) async {
    ManagerStore.validateId(candidateId);
    if (rebuildOf != null) {
      ManagerStore.validateId(rebuildOf);
      if (update) {
        throw const CompositionException(
          'A rebuild restores the confirmed plugin revisions; update separately',
        );
      }
    }
    final candidate = Directory(
      p.join(store.root.path, 'candidates', candidateId),
    );
    if (candidate.existsSync()) {
      throw const CompositionException(
        'Candidate already exists; plans are never edited in place',
      );
    }
    final selection = store.selection;
    final base = rebuildOf == null
        ? null
        : store.read('candidates/$rebuildOf/plan.json');
    if (base != null && base['roots'] is! Map) {
      throw const CompositionException(
        'The plugins that were running can no longer be rebuilt. Open Plugins and apply your selection again.',
      );
    }
    candidate.createSync(recursive: true);
    // What to compose: the saved selection, or the confirmed composition that
    // a Denial update left behind.
    final intent = base ?? selection;
    final roots = intent['roots']! as Map<String, Object?>;
    final selections = intent['selections'] as Map<String, Object?>? ?? {};
    final ordering = intent['ordering'] as Map<String, Object?>? ?? {};
    final builtins = {
      for (final entry in await AvailablePlugins(
        store,
        repository,
      ).builtins(runtimeRoot))
        entry['name']! as String: PluginSource.fromJson(
          entry['source']! as Map<String, Object?>,
        ),
    };
    final previousPlan = rebuildOf == null
        ? store.read('last-plan.json')
        : {'id': rebuildOf};
    final previousMetadata = previousPlan['id'] is String
        ? store.read('candidates/${previousPlan['id']}/plan.json')
        : <String, Object?>{};
    final previousRoots =
        previousMetadata['roots'] as Map<String, Object?>? ?? {};
    final sdkSources = <String, String>{
      for (final name in ['denial_sdk', 'denial_flutter_sdk'])
        name: p.join(sdkRoot ?? p.join(runtimeRoot, 'packages'), name),
    };
    for (final entry in sdkSources.entries) {
      final manifest = File(p.join(entry.value, 'pubspec.yaml'));
      if (!manifest.existsSync() ||
          readYamlMap(manifest)['name'] != entry.key) {
        throw CompositionException(
          'SDK source must contain denial_sdk and denial_flutter_sdk packages: ${sdkRoot ?? runtimeRoot}',
        );
      }
    }
    final snapshot = PackageSnapshot(
      Directory(p.join(candidate.path, 'packages')),
      packageOverrides: sdkSources,
    );
    progress?.call('Snapshotting the matching runtime and public SDKs');
    final sdk = snapshot.copy(sdkSources['denial_sdk']!);
    final flutterSdk = snapshot.copy(sdkSources['denial_flutter_sdk']!);
    final app = Directory(p.join(candidate.path, 'app'))..createSync();
    final dependencies = <String, Object?>{
      'flutter': {'sdk': 'flutter'},
      'denial_sdk': {'path': p.relative(sdk, from: app.path)},
      'denial_flutter_sdk': {'path': p.relative(flutterSdk, from: app.path)},
    };
    final resolvedRoots = <String, Object?>{};
    for (final entry in roots.entries) {
      final previous = entry.value! as Map<String, Object?>;
      var source = PluginSource.fromJson(
        previous['source']! as Map<String, Object?>,
      );
      if (source.kind == SourceKind.builtin) {
        final installed = builtins[entry.key];
        if (installed == null) {
          throw CompositionException(
            '${entry.key} is not provided by this installed runtime; remove it or choose another plugin',
          );
        }
        // A rebuild restores the built-in by name, from the installed release.
        // Built-in names are stable selection intent. Their sources always
        // come from the configured release, including after a kit upgrade.
        source = installed;
      }
      final prior = previousRoots[entry.key] as Map<String, Object?>?;
      final retainedRevision =
          prior != null &&
              jsonEncode(prior['source']) == jsonEncode(previous['source'])
          ? prior['revision'] as String?
          : previous['revision'] as String?;
      progress?.call('Resolving ${entry.key}');
      final resolved = await repository.resolve(
        source,
        pinnedRevision: update || source.kind != SourceKind.git
            ? null
            : retainedRevision,
      );
      if (resolved.name != entry.key) {
        throw CompositionException(
          '${entry.key} now declares ${resolved.name}; select it explicitly as a new package',
        );
      }
      resolvedRoots[entry.key] = resolved.toJson();
      if (source.kind == SourceKind.git) {
        dependencies[entry.key] = {
          'git': {
            'url': source.location,
            'path': source.path,
            'ref': resolved.revision,
          },
        };
      } else {
        dependencies[entry.key] = {
          'path': p.relative(snapshot.copy(resolved.directory), from: app.path),
        };
      }
    }
    final sdkManifest = readYamlMap(File(p.join(flutterSdk, 'pubspec.yaml')));
    final manifest = <String, Object?>{
      'name': 'denial_generated_shell',
      'publish_to': 'none',
      'version': '0.0.0',
      'environment': sdkManifest['environment'],
      'dependencies': dependencies,
      'flutter': {'uses-material-design': true},
      'dependency_overrides': {
        'denial_sdk': {'path': p.relative(sdk, from: app.path)},
        'denial_flutter_sdk': {'path': p.relative(flutterSdk, from: app.path)},
      },
    };
    File(
      p.join(app.path, 'pubspec.yaml'),
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(manifest));
    if (!update && previousPlan['id'] is String) {
      final oldLock = store.file(
        'candidates/${previousPlan['id']}/app/pubspec.lock',
      );
      if (oldLock.existsSync()) {
        oldLock.copySync(p.join(app.path, 'pubspec.lock'));
      }
    }
    progress?.call('Resolving packages with Pub');
    await run(flutter, [
      ...flutterArguments,
      'pub',
      update ? 'upgrade' : 'get',
    ], workingDirectory: app.path);
    final graph = PackageGraph.read(app.path);
    validateSdkBoundaries(graph);
    {
      _validateSdkConstraints(graph, {
        'denial_sdk': sdk,
        'denial_flutter_sdk': flutterSdk,
      });
    }
    // Read each resolved package once for planning, discovery reuse, and build
    // provenance. A new workspace path is not a new set of source inputs.
    final digests = FileDigestCache(store);
    final packageDigests = {
      for (final package in graph.packages.values)
        if (package.name != graph.application)
          package.name: p.isWithin(candidate.path, package.root)
              ? treeDigest(Directory(package.root))
              : digests.tree(Directory(package.root)),
    };
    final configuration = jsonDecode(
      File(p.join(app.path, '.dart_tool/package_config.json'))
          .readAsStringSync(),
    ) as Map;
    final languages = {
      for (final item in configuration['packages'] as List)
        if (graph.packages.containsKey((item as Map)['name']))
          item['name'] as String: {
            'languageVersion': item['languageVersion'],
            'packageUri': item['packageUri'],
          },
    };
    final sdkPath = p.join(
      p.dirname(File(flutter).resolveSymbolicLinksSync()),
      'cache/dart-sdk',
    );
    final discoveryKey = contentKey({
      'format': 3,
      'packages': packageDigests,
      'languages': languages,
      'chains': graph.chains,
      'sdkVersion': File(p.join(sdkPath, 'version')).readAsStringSync(),
      'sdkLibraries': digests.tree(Directory(p.join(sdkPath, 'lib'))),
    });
    digests.save();
    Discovery discovery;
    try {
      final cachedDiscovery = store.read('cache/discovery/$discoveryKey.json');
      if (cachedDiscovery.isEmpty) throw const FormatException('Cache miss');
      discovery = Discovery.fromJson(
        cachedDiscovery['discovery']! as Map<String, Object?>,
      );
      progress?.call('Reusing checked plugin contributions');
    } on Object {
      progress?.call('Discovering typed plugin contributions');
      // An AOT CLI has no adjacent SDK: explicitly use the matching Flutter SDK.
      discovery = await PluginDiscovery(
        sdkPath: sdkPath,
        cacheDirectory: store.file('cache/analyzer').path,
      ).discover(graph);
      store.write('cache/discovery/$discoveryKey.json', {
        'discovery': discovery.toJson(),
      });
    }
    for (final root in roots.keys) {
      if (!discovery.plugins.contains(root)) {
        throw CompositionException(
          '$root contains no resolved @Plugin contribution library',
        );
      }
    }
    final composition = CompositionPlan.resolve(
      discovery,
      selections: selections.map((k, v) => MapEntry(k, v! as String)),
      ordering: ordering.map(
        (k, v) => MapEntry(k, (v! as List).cast<String>()),
      ),
      requiredContracts: [shellApplication],
    );
    final generated = composition.generate();
    final lib = Directory(p.join(app.path, 'lib'))..createSync();
    File(p.join(lib.path, 'composition.g.dart'))
        .writeAsStringSync(generated.source);
    File(p.join(lib.path, 'main.dart')).writeAsStringSync('''
import 'package:denial_flutter_sdk/shell.dart';
import 'composition.g.dart' as composition;
Future<void> main() async {
  await runDenialShell(shell: composition.${generated.contracts[shellApplication]}.single.createShell());
}
''');
    final sourceMarker = File(p.join(runtimeRoot, '.denial-ui-source.json'));
    final lock = File(
      p.join(runtimeRoot, 'prebuilt/flutter-engine/SOURCE_LOCK.json'),
    );
    final metadata = <String, Object?>{
      'flutterGeneration': sourceMarker.existsSync()
          ? (jsonDecode(sourceMarker.readAsStringSync())
                as Map)['flutter_generation']
          : RegExp(r'FLUTTER_ENGINE_ABI: &str = "([^"]+)"')
                .firstMatch(
                  File(p.join(runtimeRoot, 'compositor/src/lib.rs'))
                      .readAsStringSync(),
                )
                ?.group(1),
      'id': candidateId,
      // A rebuild of what the user already saved is not pending work. A
      // different saved selection stays pending for Apply.
      'selectionRevision': base == null || sameComposition(selection, base)
          ? selection['revision']
          : null,
      'rebuildOf': ?rebuildOf,
      'roots': resolvedRoots,
      'selections': selections,
      'ordering': ordering,
      'discovery': discovery.toJson(),
      'developmentSdk': sdkRoot != null,
      'sdkOverride': ?sdkRoot,
      'runtimeRoot': Directory(runtimeRoot).absolute.path,
      // What the installed Denial must be for this composition to load: the
      // packaged release, or this development checkout.
      'sourceIdentity': sourceIdentity(runtimeRoot),
      if (lock.existsSync())
        'engineSourceLock': jsonDecode(lock.readAsStringSync()),
      'flutter': flutter,
      'flutterVersion': jsonDecode(
        await run(flutter, [...flutterArguments, '--version', '--machine']),
      ),
      'status': 'planned',
    };
    metadata['compositionKey'] = contentKey({
      'format': 1,
      'discoveryKey': discoveryKey,
      'manifest': manifest,
      'lock': readYamlMap(File(p.join(app.path, 'pubspec.lock'))),
      'generated': generated.source,
      'main': File(p.join(lib.path, 'main.dart')).readAsStringSync(),
      'sourceIdentity': metadata['sourceIdentity'],
      'engineSourceLock': metadata['engineSourceLock'],
      'framework': (metadata['flutterVersion'] as Map)['frameworkRevision'],
      'selections': selections,
      'ordering': ordering,
    });
    store.write('candidates/$candidateId/plan.json', metadata);
    store.write('last-plan.json', {'id': candidateId});
    return metadata;
  }

  void _validateSdkConstraints(PackageGraph graph, Map<String, String> sdks) {
    for (final package in graph.packages.values) {
      final dependencies =
          package.pubspec['dependencies'] as Map<String, Object?>? ?? {};
      for (final sdk in sdks.entries) {
        final constraint = dependencies[sdk.key];
        final version = Version.parse(
          readYamlMap(File(p.join(sdk.value, 'pubspec.yaml')))['version']!
              as String,
        );
        final requested = constraint is String
            ? constraint
            : constraint is Map
            ? constraint['version'] as String?
            : null;
        if (requested != null &&
            !VersionConstraint.parse(requested).allows(version)) {
          throw CompositionException(
            '${package.name} requires ${sdk.key} $requested; selected SDK is $version. Overrides cannot bypass API constraints.',
          );
        }
      }
    }
  }
}
