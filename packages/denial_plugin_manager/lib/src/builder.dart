import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'model.dart';
import 'progress.dart';
import 'build_cache.dart';
import 'source.dart';
import 'store.dart';

/// Compiles the planned application with the installation's Flutter tool and
/// engine compilers. It never rebuilds Rust or the engine, and writes only
/// into its own candidate directory.
///
/// Planning and building run back to back under the manager lock, so a plan is
/// not checked again here. The result carries no engine: deniald runs every
/// composition on the session's own engine.
final class CompositionBuilder {
  CompositionBuilder(this.store, {this.run = runCommand});
  final ManagerStore store;
  final CommandRunner run;

  Future<Map<String, Object?>> build(
    String id, {
    required String engineRoot,
    required String engineTarget,
    required String platform,
    void Function(String)? progress,
  }) async {
    ManagerStore.validateId(id);
    if (!{'linux-x64', 'linux-arm64'}.contains(platform)) {
      throw const CompositionException('Unsupported target platform');
    }
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(engineTarget)) {
      throw const CompositionException('Invalid engine target');
    }
    final candidate = p.join(store.root.path, 'candidates', id);
    final plan = store.read('candidates/$id/plan.json');
    if (plan['status'] != 'planned' ||
        Directory(p.join(candidate, 'bundle')).existsSync()) {
      throw const CompositionException(
        'This selection was already built; apply it again to build a new one',
      );
    }
    progress?.call('Preparing the release compiler');
    final flutter = plan['flutter']! as String;
    final digests = FileDigestCache(store);
    // The engine these compilers belong to. deniald compares it with the
    // session's engine only to explain a start that failed.
    final engine = File(
      p.join(engineRoot, 'out', engineTarget, 'libflutter_engine.so'),
    );
    final builtFor = engine.existsSync() ? digests.digest(engine) : null;
    final output = p.join(candidate, 'assembly');
    final app = p.join(candidate, 'app');
    final compositionKey = plan['compositionKey'] as String?;
    final cacheKey = compositionKey == null
        ? null
        : contentKey({
            'format': 2,
            'composition': compositionKey,
            'compiler': compilerFingerprint(
              flutter,
              engineRoot,
              engineTarget,
              digests: digests,
            ),
            'target': engineTarget,
            'platform': platform,
          });
    final cache = BuildCache(store);
    final retained = cacheKey == null ? null : cache.lookup(cacheKey);
    if (retained == null) {
      progress?.call('Compiling the generated release shell');
      final compilerProgress = CompilerProgress();
      await run(
        flutter,
        [
          'assemble',
          '--verbose',
          '--local-engine-src-path=$engineRoot',
          '--local-engine=$engineTarget',
          '--local-engine-host=$engineTarget',
          '--suppress-analytics',
          '--resource-pool-size=${Platform.numberOfProcessors > 2 ? Platform.numberOfProcessors - 2 : 1}',
          '--output=$output',
          '-dTargetFile=lib/main.dart',
          '-dBuildMode=release',
          '-dTargetPlatform=$platform',
          '-dDartObfuscation=false',
          '-dTrackWidgetCreation=true',
          '-dTreeShakeIcons=true',
          'release_bundle_${platform}_assets',
        ],
        workingDirectory: app,
        onOutput: (line) {
          final phase = compilerProgress.observe(line);
          if (phase != null) progress?.call(phase);
        },
      );
    } else {
      progress?.call('Reusing a verified desktop bundle');
    }
    progress?.call('Validating and sealing the new bundle');
    final bundle = Directory(p.join(candidate, 'bundle'))..createSync();
    Directory(p.join(bundle.path, 'lib')).createSync();
    Directory(p.join(bundle.path, 'data')).createSync();
    File(p.join(retained?.path ?? output, 'lib/libapp.so'))
        .copySync(p.join(bundle.path, 'lib/libapp.so'));
    await run('cp', [
      '-a',
      '--',
      retained == null
          ? p.join(output, 'flutter_assets')
          : p.join(retained.path, 'data/flutter_assets'),
      p.join(bundle.path, 'data/flutter_assets'),
    ]);
    final manifest = <String, Object?>{
      'schema': 1,
      'flutter_generation': plan['flutterGeneration'],
      'id': id,
      'mode': 'release',
      'platform': platform,
      'engine_sha256': ?builtFor,
      'app_sha256': fileDigest(p.join(bundle.path, 'lib/libapp.so')),
      'assets_sha256': treeDigest(
        Directory(p.join(bundle.path, 'data/flutter_assets')),
      ),
      'framework_revision':
          (plan['flutterVersion'] as Map?)?['frameworkRevision'],
      'source_identity': plan['sourceIdentity'],
      'pub_lock_sha256': fileDigest(p.join(app, 'pubspec.lock')),
    };
    File(p.join(bundle.path, 'denial-plugin-bundle.json')).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(manifest),
      flush: true,
    );
    // deniald loads only a bundle nothing can write to any more.
    await run('chmod', ['-R', 'a-w', '--', bundle.path]);
    store.write('candidates/$id/build.json', {
      'id': id,
      'status': 'built',
      'bundle': bundle.path,
      'manifest': manifest,
      'cacheKey': ?cacheKey,
      if (retained != null) 'reusedFrom': p.basename(retained.parent.path),
    });
    store.write('candidates/$id/plan.json', {...plan, 'status': 'built'});
    if (cacheKey != null) cache.remember(cacheKey, id);
    return {
      'id': id,
      'bundle': bundle.path,
      'manifest': manifest,
      'reused': retained != null,
    };
  }
}
