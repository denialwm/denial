import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'available.dart';
import 'build_kit.dart';
import 'catalog.dart';
import 'installation.dart';
import 'model.dart';
import 'source.dart';
import 'store.dart';

/// What a plugin selection is compiled with: the Denial source it is built
/// for, a Flutter tool and the engine's compilers. A packaged installation
/// carries them as a build kit; a development checkout uses its own, in place.
abstract interface class BuildTools {
  factory BuildTools.of(ManagerStore store, PluginInstallation installation) {
    if (installation.development case final development?) {
      return DevelopmentTools(store, development);
    }
    return BuildKit(store, source: Directory(installation.buildKit!));
  }

  /// The installation carries build tools at all.
  bool get available;

  /// Nothing has to be prepared before compiling.
  bool get ready;

  /// Why nothing can be built here, with what fixes it, or null.
  String? get problem;

  /// Changes when a failed rebuild is worth trying again.
  String get identity;
  Map<String, Object?> get dartStatus;

  /// Where the tools are, without preparing anything.
  Map<String, Object?> get configuration;

  /// Call under the manager mutation lock.
  Future<Map<String, Object?>> initialize({void Function(String)? progress});
}

/// What a composition built from [checkout] is stamped with, and what the
/// development session's shell bundle declares. It names the checkout only:
/// commits, edits and engine rebuilds keep it, so they never refuse plugins.
Map<String, Object?> developmentIdentity(String checkout) => {
  'schema': 1,
  'development': Directory(checkout).resolveSymbolicLinksSync(),
};

/// What a composition built from [runtime] is stamped with: the packaged
/// release's own identity, or the development checkout.
Map<String, Object?> sourceIdentity(String runtime) {
  final marker = File(p.join(runtime, '.denial-ui-source.json'));
  return marker.existsSync()
      ? jsonDecode(marker.readAsStringSync()) as Map<String, Object?>
      : developmentIdentity(runtime);
}

/// Built-in plugins are selected once, for a selection nobody touched yet.
/// Removing every root deliberately must survive restarts and upgrades.
Future<void> seedDefaults(ManagerStore store, String runtime) async {
  if (store.read('initialization.json')['complete'] == true) return;
  if (store.selection['revision'] == 0 &&
      (store.selection['roots'] as Map).isEmpty) {
    await AvailablePlugins(
      store,
      SourceRepository(Directory(p.join(store.root.path, 'repositories'))),
    ).defaults(runtime);
  }
  store.write('initialization.json', {'complete': true});
}

final class DevelopmentTools implements BuildTools {
  DevelopmentTools(this.store, this.installation);
  final ManagerStore store;
  final DevelopmentInstallation installation;

  String get _dartSdk =>
      p.join(p.dirname(installation.flutter), 'cache/dart-sdk');
  String get _compiler => p.join(
    installation.engineRoot,
    'out',
    installation.engineTarget,
    'gen_snapshot',
  );

  /// What is missing before this checkout can compile plugins, or null.
  String? get _missing {
    for (final path in [
      p.join(installation.checkout, 'plugins/builtins.yaml'),
      p.join(installation.checkout, 'packages/denial_flutter_sdk/pubspec.yaml'),
      installation.flutter,
      p.join(_dartSdk, 'bin/dart'),
      _compiler,
    ]) {
      if (!File(path).existsSync()) return path;
    }
    return null;
  }

  @override
  bool get available => true;

  /// The built-in plugin records still point at another installation, such
  /// as the packaged one this machine also has.
  bool get _foreignBuiltins {
    final plugins = store.read('installed.json')['plugins'];
    if (plugins is! Map) return true;
    final own = p.join(installation.checkout, 'plugins');
    return plugins.values.any(
      (plugin) =>
          plugin is Map &&
          plugin['source'] is Map &&
          (plugin['source'] as Map)['kind'] == 'builtin' &&
          (plugin['source'] as Map)['location'] != own,
    );
  }

  @override
  bool get ready => _missing == null && !_foreignBuiltins;

  @override
  String? get problem => switch (_missing) {
    final path? =>
      'This checkout cannot build plugins yet: $path is missing. '
          'Build the shell once with tools/denial-pc bundle.',
    null => null,
  };

  @override
  String get identity {
    final compiler = File(_compiler);
    final stat = compiler.existsSync() ? compiler.statSync() : null;
    return contentKey({
      'development': installation.checkout,
      'compiler': stat == null
          ? null
          : '${stat.size}:${stat.modified.microsecondsSinceEpoch}',
    });
  }

  @override
  Map<String, Object?> get dartStatus {
    final version = File(p.join(_dartSdk, 'version'));
    if (!version.existsSync()) {
      return {
        'available': false,
        'found': false,
        'error':
            'The Flutter checkout has no Dart SDK yet: ${p.dirname(version.path)}.',
      };
    }
    final found = version.readAsStringSync().trim();
    return {
      'available': true,
      'found': true,
      'expectedVersion': found,
      'version': found,
      'executable': p.join(_dartSdk, 'bin/dart'),
    };
  }

  @override
  Map<String, Object?> get configuration => {
    ...PluginCatalog.configuration({
      for (final entry in store.read('configuration.json').entries)
        if (entry.key.startsWith('catalog-')) entry.key: entry.value,
    }),
    'schema': 1,
    'development': true,
    'runtime': installation.checkout,
    'flutter': installation.flutter,
    // The Flutter tool takes Denial's dart:ui from the engine output for
    // every command, as the kit's launcher does.
    'flutter-arguments': [
      '--local-engine-src-path=${installation.engineRoot}',
      '--local-engine=${installation.engineTarget}',
      '--local-engine-host=${installation.engineTarget}',
    ],
    'engine-root': installation.engineRoot,
    'engine-target': installation.engineTarget,
    'platform': installation.platform,
    'dart-sdk': _dartSdk,
  };

  @override
  Future<Map<String, Object?>> initialize({
    void Function(String)? progress,
  }) async {
    if (problem case final problem?) throw CompositionException(problem);
    await seedDefaults(store, installation.checkout);
    await AvailablePlugins(
      store,
      SourceRepository(Directory(p.join(store.root.path, 'repositories'))),
    ).adoptBuiltins(installation.checkout);
    return configuration;
  }
}
