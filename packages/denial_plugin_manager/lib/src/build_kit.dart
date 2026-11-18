import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'model.dart';
import 'source.dart';
import 'store.dart';
import 'available.dart';
import 'catalog.dart';
import 'dart_sdk.dart';
import 'tools.dart';

/// Copies the packaged release compiler into a per-user writable cache. Flutter
/// writes cache locks and stamps; package-managed files remain immutable.
final class BuildKit implements BuildTools {
  BuildKit(
    this.store, {
    required this.source,
    this.run = runCommand,
    this.dartExecutable,
  });
  final ManagerStore store;
  final Directory source;
  final CommandRunner run;
  final String? dartExecutable;

  @override
  bool get available => File(p.join(source.path, 'kit.json')).existsSync();

  @override
  Map<String, Object?> get configuration =>
      PluginCatalog.configuration(store.read('configuration.json'));

  @override
  String? get problem => !available
      ? 'Denial plugin build tools are missing. Install the denial-plugin-manager package.'
      : dartStatus['error'] as String?;

  @override
  String get identity {
    final file = File(p.join(source.path, 'kit.json'));
    if (!file.existsSync()) {
      throw const CompositionException(
        'Denial plugin build tools are missing. Update or repair Denial.',
      );
    }
    return sha256.convert(file.readAsBytesSync()).toString();
  }

  @override
  Map<String, Object?> get dartStatus {
    final expected = _manifest()?['dartVersion'];
    final constraint = _manifest()?['dartConstraint'];
    if (expected is! String ||
        expected.isEmpty ||
        constraint is! String ||
        constraint.isEmpty) {
      return {
        'available': false,
        'found': false,
        'error':
            'The installed plugin build kit does not declare its Dart version.',
      };
    }
    return DartSdk.status(
      expectedVersion: expected,
      constraint: constraint,
      executable: dartExecutable,
    );
  }

  @override
  bool get ready {
    if (!available) return false;
    final config = store.read('configuration.json');
    final root = p.join(store.root.path, 'build-kits', identity);
    final expected = _manifest()?['dartVersion'];
    final constraint = _manifest()?['dartConstraint'];
    if (expected is! String || constraint is! String) return false;
    late final DartSdk dart;
    try {
      dart = DartSdk.discover(
        expectedVersion: expected,
        constraint: constraint,
        executable: dartExecutable,
      );
    } on DartSdkException {
      return false;
    }
    return config['build-kit'] == identity &&
        config['runtime'] == p.join(root, 'runtime') &&
        config['flutter'] == p.join(root, 'flutter/bin/flutter') &&
        config['engine-root'] == p.join(root, 'engine') &&
        config['dart-sdk'] == dart.root &&
        config['dart'] == dart.executable &&
        config['dart-version'] == dart.version &&
        config['dart-constraint'] == constraint &&
        File(p.join(root, 'runtime/.denial-ui-source.json')).existsSync() &&
        File(p.join(root, 'flutter/bin/flutter')).existsSync() &&
        _linkTargets(p.join(root, 'flutter/bin/cache/dart-sdk'), dart.root) &&
        _linkTargets(
          p.join(
            root,
            'engine/out',
            config['engine-target'] as String? ?? '',
            'dart-sdk',
          ),
          dart.root,
        ) &&
        File(
          p.join(
            root,
            'engine/out',
            config['engine-target'] as String? ?? '',
            'gen_snapshot',
          ),
        ).existsSync();
  }

  /// Call under the manager mutation lock. Defaults are seeded only once;
  /// removing every root deliberately must survive app and installation restarts.
  @override
  Future<Map<String, Object?>> initialize({
    void Function(String)? progress,
  }) async {
    final configuration = await ensure(progress: progress);
    await seedDefaults(store, configuration['runtime']! as String);
    return configuration;
  }

  Future<Map<String, Object?>> ensure({void Function(String)? progress}) async {
    if (ready) {
      final configuration = PluginCatalog.configuration(
        store.read('configuration.json'),
      );
      store.write('configuration.json', configuration);
      return configuration;
    }
    return prepare(progress: progress);
  }

  Future<Map<String, Object?>> prepare({
    void Function(String)? progress,
  }) async {
    if (!available) {
      throw const CompositionException(
        'Installed plugin build tools are missing. Update or repair the Denial installation.',
      );
    }
    final bytes = File(p.join(source.path, 'kit.json')).readAsBytesSync();
    final manifest = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    if (manifest['schema'] != 1 ||
        !{'linux-x64', 'linux-arm64'}.contains(manifest['platform']) ||
        manifest['dartVersion'] is! String ||
        (manifest['dartVersion']! as String).isEmpty ||
        manifest['dartConstraint'] is! String ||
        (manifest['dartConstraint']! as String).isEmpty ||
        manifest['engineTarget'] is! String ||
        !RegExp(r'^[a-zA-Z0-9_-]+$')
            .hasMatch(manifest['engineTarget']! as String)) {
      throw const CompositionException('Unsupported plugin build kit');
    }
    final id = sha256.convert(bytes).toString();
    final destination = Directory(p.join(store.root.path, 'build-kits', id));
    final dart = DartSdk.discover(
      expectedVersion: manifest['dartVersion']! as String,
      constraint: manifest['dartConstraint']! as String,
      executable: dartExecutable,
    );
    progress?.call('Verifying the installed release build tools');
    await _verify(source, manifest);
    if (!destination.existsSync()) {
      destination.parent.createSync(recursive: true);
      final temporary = destination.parent.createTempSync('preparing-');
      try {
        progress?.call('Preparing your compiler cache');
        await run('cp', ['-a', '--', '${source.path}/.', temporary.path]);
        await _verify(temporary, manifest);
        // No other process may use this directory until it is fully prepared.
        await run('chmod', ['-R', 'u+rwX', '--', temporary.path]);
        temporary.renameSync(destination.path);
      } finally {
        if (temporary.existsSync()) temporary.deleteSync(recursive: true);
      }
    } else {
      await _verify(destination, manifest);
    }
    _linkDartSdk(destination, manifest['engineTarget']! as String, dart.root);
    final configuration = <String, Object?>{
      ...PluginCatalog.configuration({}),
      for (final entry in store.read('configuration.json').entries)
        if (entry.key.startsWith('catalog-')) entry.key: entry.value,
      'schema': 1,
      'runtime': p.join(destination.path, 'runtime'),
      'flutter': p.join(destination.path, 'flutter/bin/flutter'),
      'engine-root': p.join(destination.path, 'engine'),
      'engine-target': manifest['engineTarget'],
      'dart-sdk': dart.root,
      'dart': dart.executable,
      'dart-version': dart.version,
      'dart-constraint': manifest['dartConstraint'],
      'platform': manifest['platform'],
      'build-kit': id,
    };
    await AvailablePlugins(
      store,
      SourceRepository(Directory(p.join(store.root.path, 'repositories'))),
    ).adoptBuiltins(configuration['runtime']! as String);
    store.write('configuration.json', configuration);
    _pruneStaleBuildKits(destination);
    return configuration;
  }

  static void _pruneStaleBuildKits(Directory retained) {
    final identity = RegExp(r'^[0-9a-f]{64}$');
    for (final entry in retained.parent.listSync(followLinks: false)) {
      if (entry is! Directory ||
          entry.path == retained.path ||
          !identity.hasMatch(p.basename(entry.path))) {
        continue;
      }
      try {
        entry.deleteSync(recursive: true);
      } on FileSystemException {
        // A stale cache must not prevent the newly verified kit from working.
      }
    }
  }

  Future<void> _verify(Directory root, Map<String, Object?> manifest) async {
    String checked(String relative) {
      if (p.isAbsolute(relative) ||
          p.normalize(relative) != relative ||
          !p.isWithin(
            root.absolute.path,
            p.join(root.absolute.path, relative),
          )) {
        throw CompositionException('Invalid build kit path: $relative');
      }
      final path = p.join(root.absolute.path, relative);
      // A parent link must not redirect manifest verification outside the kit.
      if (!p.isWithin(
        root.resolveSymbolicLinksSync(),
        File(path).resolveSymbolicLinksSync(),
      )) {
        throw CompositionException(
          'Build kit path escapes its root: $relative',
        );
      }
      return path;
    }

    final files = manifest['files']! as Map<String, Object?>;
    for (final entry in files.entries) {
      final file = File(checked(entry.key));
      if (FileSystemEntity.isLinkSync(file.path) ||
          (await sha256.bind(file.openRead()).first).toString() !=
              entry.value) {
        throw CompositionException('Build kit input changed: ${entry.key}');
      }
    }
    for (final entry in (manifest['links']! as Map<String, Object?>).entries) {
      final link = Link(checked(entry.key));
      if (link.targetSync() != entry.value) {
        throw CompositionException('Build kit link changed: ${entry.key}');
      }
    }
    for (final required in [
      'runtime/.denial-ui-source.json',
      'runtime/plugins/builtins.yaml',
      'flutter/bin/flutter',
      'engine/out/${manifest['engineTarget']}/gen_snapshot',
    ]) {
      if (!files.containsKey(required)) {
        throw CompositionException('Incomplete build kit: $required');
      }
    }
  }

  Map<String, Object?>? _manifest() {
    final file = File(p.join(source.path, 'kit.json'));
    if (!file.existsSync()) return null;
    try {
      return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    } on FormatException {
      return null;
    }
  }

  static bool _linkTargets(String path, String target) {
    if (!FileSystemEntity.isLinkSync(path)) return false;
    try {
      return Link(path).resolveSymbolicLinksSync() ==
          Directory(target).resolveSymbolicLinksSync();
    } on FileSystemException {
      return false;
    }
  }

  static void _linkDartSdk(
    Directory destination,
    String engineTarget,
    String dartRoot,
  ) {
    for (final path in [
      p.join(destination.path, 'flutter/bin/cache/dart-sdk'),
      p.join(destination.path, 'engine/out', engineTarget, 'dart-sdk'),
    ]) {
      final entity = FileSystemEntity.typeSync(path, followLinks: false);
      if (entity != FileSystemEntityType.notFound) {
        if (entity != FileSystemEntityType.link) {
          throw CompositionException(
            'Plugin build kit path is not a link: $path',
          );
        }
        Link(path).deleteSync();
      }
      Directory(p.dirname(path)).createSync(recursive: true);
      Link(path).createSync(dartRoot);
    }
  }
}
