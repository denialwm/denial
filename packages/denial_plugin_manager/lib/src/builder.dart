import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'model.dart';
import 'progress.dart';
import 'build_cache.dart';
import 'build_provenance.dart';
import 'source.dart';
import 'store.dart';
import 'workspace.dart';

/// Builds only the generated Flutter application using existing pinned release
/// engine artifacts. It never rebuilds Rust/the engine or modifies active files.
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
    if (Directory(p.join(candidate, 'bundle')).existsSync()) {
      throw const CompositionException(
        'Candidate already has a staged bundle; create a new plan',
      );
    }
    final plan = store.read('candidates/$id/plan.json');
    if (plan['status'] != 'planned') {
      throw const CompositionException(
        'A successful, unbuilt plan is required',
      );
    }
    requireCurrentPlan(store, plan);
    if (plan['inputDigest'] !=
        treeDigest(Directory(p.join(candidate, 'packages')))) {
      throw const CompositionException(
        'Planned runtime/package sources changed; plan again',
      );
    }
    progress?.call('Preparing the release compiler');
    final inputs = plan['applicationInputs'] as Map<String, Object?>?;
    if (inputs == null) {
      throw const CompositionException(
        'Plan lacks input fingerprints; plan again',
      );
    }
    for (final input in inputs.entries) {
      if (fileDigest(p.join(candidate, 'app', input.key)) != input.value) {
        throw CompositionException(
          'Planned application input ${input.key} changed; plan again',
        );
      }
    }
    if (plan['applicationDigest'] !=
        treeDigest(Directory(p.join(candidate, 'app')))) {
      throw const CompositionException(
        'Planned application inputs or assets changed; plan again',
      );
    }
    final resolved = plan['resolvedInputs'] as Map<String, Object?>?;
    if (resolved == null) {
      throw const CompositionException(
        'Plan lacks resolved source fingerprints; plan again',
      );
    }
    final digests = FileDigestCache(store);
    for (final entry in resolved.entries) {
      final input = entry.value! as Map<String, Object?>;
      if (digests.tree(Directory(input['root']! as String)) !=
          input['digest']) {
        throw CompositionException(
          'Resolved package ${entry.key} changed since planning; plan again',
        );
      }
    }
    if (plan['flutterGeneration'] is! String) {
      throw const CompositionException(
        'Missing runtime compatibility generation; plan again',
      );
    }
    final flutter = plan['flutter']! as String;
    final version = jsonDecode(
      await run(flutter, ['--version', '--machine']),
    ) as Map<String, Object?>;
    verifyBuildProvenance(plan, version, engineRoot, engineTarget, platform);
    final runtimeRoot = plan['runtimeRoot']! as String;
    final engine = p.join(
      runtimeRoot,
      'prebuilt/flutter-engine/$platform-release/libflutter_engine.so',
    );
    final checksum = File('$engine.sha256')
        .readAsStringSync()
        .trim()
        .split(RegExp(r'\s+'))
        .first;
    if ((plan['releaseEngineChecksums'] as Map?)?[platform] != checksum) {
      throw const CompositionException(
        'Release engine checksum changed since planning; plan again',
      );
    }
    if (fileDigest(engine) != checksum) {
      throw const CompositionException(
        'Release engine differs from the runtime checksum',
      );
    }
    if (fileDigest(
          p.join(engineRoot, 'out', engineTarget, 'libflutter_engine.so'),
        ) !=
        checksum) {
      throw const CompositionException(
        'Compiler output root does not contain the attested release engine',
      );
    }
    final output = p.join(candidate, 'assembly');
    final app = p.join(candidate, 'app');
    final compositionKey = plan['compositionKey'] as String?;
    final cacheKey = compositionKey == null
        ? null
        : contentKey({
            'format': 1,
            'composition': compositionKey,
            'engine': checksum,
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
    final retained = cacheKey == null ? null : cache.lookup(cacheKey, checksum);
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
    File(engine).copySync(p.join(bundle.path, 'lib/libflutter_engine.so'));
    File(p.join(engineRoot, 'out', engineTarget, 'icudtl.dat'))
        .copySync(p.join(bundle.path, 'data/icudtl.dat'));
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
      'engine_sha256': checksum,
      'app_sha256': fileDigest(p.join(bundle.path, 'lib/libapp.so')),
      'icu_sha256': fileDigest(p.join(bundle.path, 'data/icudtl.dat')),
      'assets_sha256': treeDigest(
        Directory(p.join(bundle.path, 'data/flutter_assets')),
      ),
      'framework_revision': version['frameworkRevision'],
      'source_identity': plan['sourceIdentity'],
      'input_digest': plan['inputDigest'],
      'pub_lock_sha256': fileDigest(p.join(app, 'pubspec.lock')),
    };
    File(p.join(bundle.path, 'denial-plugin-bundle.json')).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(manifest),
      flush: true,
    );
    // Final artifact becomes read-only only after all writes and checks finish.
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
