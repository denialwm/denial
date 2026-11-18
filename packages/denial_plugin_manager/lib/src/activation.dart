import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'model.dart';
import 'build_cache.dart';
import 'rebuild.dart';
import 'source.dart';
import 'store.dart';

/// Requests native transitions only. The compositor validates compatibility,
/// confirms startup, persists selection, and owns packaged-shell recovery. It
/// is also the only record of what runs: the manager asks, it keeps no copy.
/// deniald loads compositions that carry no engine of their own.
const bundleCapability = 'pluginBundleV2';

final class CompositionActivation {
  CompositionActivation(
    this.store, {
    this.denialctl = 'denialctl',
    this.run = runCommand,
  });
  final ManagerStore store;
  final String denialctl;
  final CommandRunner run;

  Future<Map<String, Object?>> status() async {
    try {
      return await _request(['status']);
    } catch (error) {
      return {'available': false, 'error': '$error'};
    }
  }

  Future<void> requireSupport() async {
    final native = await status();
    if (native['available'] == false) {
      throw const CompositionException(
        'Denial is not available. Apply plugins from your Denial session.',
      );
    }
    // A compositor from before compositions stopped carrying an engine
    // would refuse what this manager builds.
    if (!(native['capabilities'] as List? ?? const []).contains(
      bundleCapability,
    )) {
      throw const CompositionException(
        'Log out and back into Denial once to finish the update. Your plugin choices are saved.',
      );
    }
  }

  /// The candidate deniald runs, or null for the packaged shell and for a
  /// composition this manager did not build.
  String? runningCandidate(Map<String, Object?> native) =>
      candidateOf(native['plugin_bundle']);

  /// The candidate whose bundle is [bundle] in this manager's state.
  String? candidateOf(Object? bundle) {
    if (bundle is! String || p.basename(bundle) != 'bundle') return null;
    final id = p.basename(p.dirname(bundle));
    return RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id) &&
            bundle == p.join(store.root.path, 'candidates', id, 'bundle')
        ? id
        : null;
  }

  Future<Map<String, Object?>> activate(String id) async {
    ManagerStore.validateId(id);
    final plan = store.read('candidates/$id/plan.json');
    final build = store.read('candidates/$id/build.json');
    if (build['status'] != 'built' || plan['status'] != 'built') {
      throw const CompositionException('Build the candidate before activation');
    }
    if (plan['rebuildOf'] case final String base) {
      // A rebuild may replace only the composition deniald is still waiting
      // for. Restoring the packaged shell or applying another composition
      // meanwhile is the user's newer decision.
      if (!waitsForRebuildOf(store, await status(), base)) {
        throw const CompositionException(
          'Denial no longer waits for these plugins to be rebuilt',
        );
      }
    }
    final identity = plan['sourceIdentity'] as Map?;
    final required = (identity?['required_native_capabilities'] as List? ?? [])
        .cast<String>();
    if (required.isNotEmpty) {
      final native = await status();
      final supported = (native['capabilities'] as List? ?? []).cast<String>();
      if (required.any((capability) => !supported.contains(capability))) {
        throw const CompositionException(
          'Log out and back into Denial once to finish the update. Your plugin choices are saved.',
        );
      }
    }
    final bundle = Directory(
      p.join(store.root.path, 'candidates', id, 'bundle'),
    ).resolveSymbolicLinksSync();
    // Applying an unchanged composition should not interrupt the desktop:
    // deniald already runs the very build this one was copied from.
    if (build['reusedFrom'] != null) {
      final status = await this.status();
      final running = runningCandidate(status);
      if (running != null &&
          store.read('candidates/$running/build.json')['cacheKey'] ==
              build['cacheKey'] &&
          status['plugin_healthy'] == true &&
          status['active_mode'] == 'custom_optimized' &&
          BuildCache.validBundle(
            Directory(status['plugin_bundle']! as String),
          )) {
        _rememberInstalled(plan);
        return status;
      }
    }
    final native = await _request(['activate', bundle]);
    if (native['plugin_bundle'] != bundle ||
        native['plugin_healthy'] != true ||
        native['active_mode'] != 'custom_optimized') {
      final error = native['error'];
      throw CompositionException(
        error is String && error.trim().isNotEmpty
            ? 'Your plugins did not start: ${error.trim()}'
            : 'Your plugins did not start. Denial keeps the desktop it was running.',
      );
    }
    _rememberInstalled(plan);
    return native;
  }

  Future<Map<String, Object?>> restore() async {
    final native = await _request(['restore']);
    if (native['active_mode'] != 'official_optimized') {
      throw const CompositionException(
        'The compositor did not restore the packaged shell',
      );
    }
    return native;
  }

  Future<Map<String, Object?>> revert() async {
    final native = await _request(['revert']);
    if (native['plugin_healthy'] != true ||
        native['plugin_bundle'] is! String) {
      throw const CompositionException(
        'The previous composition was not confirmed healthy',
      );
    }
    final id = runningCandidate(native);
    if (id == null) {
      // deniald went back to plugins this manager has no record of. They
      // run; the saved selection simply does not describe them.
      return native;
    }
    final plan = store.read('candidates/$id/plan.json');
    final selection = store.selection;
    // Rollback restores intent as well as the retained binary. Explicit updates
    // remain available later; rollback never rewrites an old candidate.
    store.write('selection.json', {
      ...selection,
      'roots': plan['roots'],
      'selections': plan['selections'] ?? <String, Object?>{},
      'ordering': plan['ordering'] ?? <String, Object?>{},
      'revision': (selection['revision']! as int) + 1,
    });
    // Subsequent apply must retain this composition's pins, rather than those
    // of the candidate that was rolled back. Only update advances revisions.
    store.write('last-plan.json', {'id': id});
    _rememberInstalled(plan);
    return native;
  }

  void _rememberInstalled(Map<String, Object?> plan) {
    // Re-enabling an updated plugin must retain its last confirmed revision,
    // including after another composition no longer contains that root.
    final installed = store.read('installed.json');
    store.write('installed.json', {
      'plugins': {
        ...?installed['plugins'] as Map<String, Object?>?,
        ...?plan['roots'] as Map<String, Object?>?,
      },
    });
  }

  Future<Map<String, Object?>> _request(List<String> operation) async =>
      // denialctl waits for mode transitions by default; its opt-out is
      // --no-wait. It deliberately has no separate --wait option.
      jsonDecode(await run(denialctl, ['--json', 'ui', ...operation]))
          as Map<String, Object?>;
}
