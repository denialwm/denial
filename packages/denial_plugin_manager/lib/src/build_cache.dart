import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'store.dart';

/// A cache hit reuses only verified output bytes. Every new candidate retains
/// its own plan, lock and sealed bundle.
final class BuildCache {
  const BuildCache(this.store);
  final ManagerStore store;

  Directory? lookup(String key) {
    try {
      final record = store.read('cache/builds/$key.json');
      final id = record['id']! as String;
      ManagerStore.validateId(id);
      final bundle = Directory(
        p.join(store.root.path, 'candidates', id, 'bundle'),
      );
      final build = store.read('candidates/$id/build.json');
      if (build['cacheKey'] != key ||
          build['bundle'] != bundle.path ||
          !validBundle(bundle)) {
        return null;
      }
      return bundle;
    } on Object {
      return null; // Missing or damaged cache entries simply take the build path.
    }
  }

  static bool validBundle(Directory bundle) {
    try {
      if (FileSystemEntity.isLinkSync(bundle.path) ||
          FileSystemEntity.isLinkSync(bundle.parent.path) ||
          bundle
              .listSync(recursive: true, followLinks: false)
              .any((file) => file is Link)) {
        return false;
      }
      final manifest = jsonDecode(
        File(p.join(bundle.path, 'denial-plugin-bundle.json'))
            .readAsStringSync(),
      ) as Map;
      return manifest['id'] == p.basename(bundle.parent.path) &&
          fileDigest(p.join(bundle.path, 'lib/libapp.so')) ==
              manifest['app_sha256'] &&
          treeDigest(Directory(p.join(bundle.path, 'data/flutter_assets'))) ==
              manifest['assets_sha256'];
    } on Object {
      return false;
    }
  }

  void remember(String key, String candidate) =>
      store.write('cache/builds/$key.json', {'id': candidate});
}

/// Compiler inputs are explicit: never hash a multi-gigabyte engine object tree.
/// These are the existing tools consumed by Flutter assemble, not build targets.
String compilerFingerprint(
  String flutter,
  String engineRoot,
  String target, {
  FileDigestCache? digests,
}) {
  final sdk = p.dirname(p.dirname(File(flutter).resolveSymbolicLinksSync()));
  final output = p.join(engineRoot, 'out', target);
  final inputs = <String, String>{};
  void include(String name, String path) {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.directory) {
      inputs[name] = treeDigest(Directory(path), digestFile: digests?.digest);
    } else if (type == FileSystemEntityType.file) {
      inputs[name] = digests?.digest(File(path)) ?? fileDigest(path);
    } else {
      throw FileSystemException('Missing compiler cache input', path);
    }
  }

  for (final name in [
    'gen_snapshot',
    'font-subset',
    'impellerc',
    'flutter_patched_sdk',
    'shader_lib',
    'gen/const_finder.dart.snapshot',
    'icudtl.dat',
  ]) {
    include('engine/$name', p.join(output, name));
  }
  include('launcher', flutter);
  final toolSnapshot = p.join(sdk, 'bin/cache/flutter_tools.snapshot');
  if (File(toolSnapshot).existsSync()) include('tool-snapshot', toolSnapshot);
  include('dart', p.join(sdk, 'bin/cache/dart-sdk/bin/dart'));
  include('dart-snapshots', p.join(sdk, 'bin/cache/dart-sdk/bin/snapshots'));
  include('internal', p.join(sdk, 'bin/internal'));
  final configuration = File(
    p.join(sdk, 'packages/flutter_tools/.dart_tool/package_config.json'),
  );
  final packages = jsonDecode(configuration.readAsStringSync()) as Map;
  for (final package in packages['packages'] as List) {
    final value = package as Map;
    final root = configuration.uri
        .resolve(value['rootUri'] as String)
        .toFilePath();
    // Some tool dependencies contain only data (no lib/). Fingerprint their
    // static resources too, excluding disposable caches and repository metadata.
    inputs['tool/${value['name']}'] = treeDigest(
      Directory(root),
      ignoredNames: {'.git', '.dart_tool', 'build'},
      digestFile: digests?.digest,
    );
  }
  digests?.save();
  return contentKey(inputs);
}
