import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'model.dart';
import 'store.dart';

/// An additive schema-1 source identity extension, not a verification bypass.
/// Legacy and release kits still use SOURCE_LOCK as their revision authority.
void verifyBuildProvenance(
  Map<String, Object?> plan,
  Map<String, Object?> version,
  String engineRoot,
  String engineTarget,
  String platform,
) {
  final identity = plan['sourceIdentity'] as Map?;
  final provenance = identity?['build_provenance'];
  if (provenance == null) {
    final locked = plan['engineSourceLock'] as Map?;
    if (locked == null ||
        version['frameworkRevision'] !=
            (locked['flutter'] as Map?)?['revision']) {
      throw const CompositionException(
        'Flutter toolchain does not match the runtime source lock',
      );
    }
    return;
  }
  Never invalid() => throw const CompositionException(
    'Unsupported or inconsistent development build provenance',
  );
  bool hash(Object? value) =>
      value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
  if (provenance is! Map ||
      provenance['schema'] != 1 ||
      provenance['mode'] != 'development' ||
      provenance['platform'] != platform ||
      provenance['engine_target'] != engineTarget ||
      !hash(provenance['args_gn_sha256']) ||
      !hash(provenance['engine_sha256']) ||
      provenance['engine_build_id'] is! String ||
      !RegExp(r'^[0-9a-f]+$')
          .hasMatch(provenance['engine_build_id'] as String)) {
    invalid();
  }
  final sources = provenance['sources'];
  if (sources is! Map) invalid();
  for (final name in ['flutter', 'skia', 'denial']) {
    final source = sources[name];
    if (source is! Map ||
        source['revision'] is! String ||
        !RegExp(r'^[0-9a-f]{40}$').hasMatch(source['revision'] as String) ||
        source['path'] is! String ||
        !p.isAbsolute(source['path'] as String) ||
        (source['dirty_sha256'] != null && !hash(source['dirty_sha256']))) {
      invalid();
    }
  }
  if (provenance['framework_revision'] !=
          (sources['flutter'] as Map)['revision'] ||
      version['frameworkRevision'] != provenance['framework_revision'] ||
      (plan['releaseEngineChecksums'] as Map?)?[platform] !=
          provenance['engine_sha256']) {
    invalid();
  }
  final marker = File(
    p.join(plan['runtimeRoot'] as String, '.denial-ui-source.json'),
  );
  if (contentKey(jsonDecode(marker.readAsStringSync())) !=
      contentKey(identity)) {
    throw const CompositionException(
      'Runtime build provenance changed; plan again',
    );
  }
  final inputs = provenance['compiler_inputs'];
  const required = [
    'gen_snapshot',
    'font-subset',
    'impellerc',
    'icudtl.dat',
    'flutter_patched_sdk',
    'flutter_linux',
    'libflutter_linux_gtk.so',
    'shader_lib',
    'gen/const_finder.dart.snapshot',
  ];
  if (inputs is! Map || inputs.length != required.length) invalid();
  for (final name in required) {
    if (!hash(inputs[name])) invalid();
    final path = p.join(engineRoot, 'out', engineTarget, name);
    final actual = Directory(path).existsSync()
        ? treeDigest(Directory(path))
        : fileDigest(path);
    if (actual != inputs[name]) {
      throw CompositionException('Development compiler input changed: $name');
    }
  }
  final flutterRoot = p.dirname(p.dirname(plan['flutter'] as String));
  final dartRoot = p.join(flutterRoot, 'bin/cache/dart-sdk');
  if (File(p.join(dartRoot, 'version')).readAsStringSync().trim() !=
          provenance['dart_sdk_version'] ||
      !hash(provenance['frontend_server_sha256']) ||
      fileDigest(
            p.join(dartRoot, 'bin/snapshots/frontend_server_aot.dart.snapshot'),
          ) !=
          provenance['frontend_server_sha256']) {
    throw const CompositionException(
      'Development Dart frontend differs from the attested compiler',
    );
  }
  if (!hash(provenance['sky_engine_sha256']) ||
      treeDigest(Directory(p.join(flutterRoot, 'bin/cache/pkg/sky_engine'))) !=
          provenance['sky_engine_sha256']) {
    throw const CompositionException(
      'Development dart:ui declarations changed',
    );
  }
}
