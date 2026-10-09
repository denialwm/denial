import 'dart:io';

import 'package:denial_plugin_manager_app/selection_status.dart';

void main() {
  void check(String name, Map<String, Object?> state, bool expected) {
    if (selectionNeedsApply(state) != expected) throw StateError(name);
    stdout.writeln('PASS $name');
  }

  check('An untouched collection needs no apply bar', {
    'selection': {'revision': 0, 'roots': <String, Object?>{}},
  }, false);
  check('Removing the last plugin still requires applying', {
    'selection': {'revision': 2, 'roots': <String, Object?>{}},
  }, true);
  final built = <String, Object?>{
    'selection': {
      'revision': 2,
      'roots': {'plugin': <String, Object?>{}},
    },
    'plan': {'selectionRevision': 2},
    'build': {'status': 'built', 'bundle': '/new'},
    'active': {'id': 'old', 'bundle': '/old'},
    'native': {
      'active_mode': 'custom_optimized',
      'plugin_healthy': true,
      'plugin_bundle': '/old',
    },
  };
  check('Building alone does not dismiss pending changes', built, true);
  final applied = {
    ...built,
    'native': {
      'active_mode': 'custom_optimized',
      'plugin_healthy': true,
      'plugin_bundle': '/new',
    },
  };
  check('Healthy activation dismisses pending changes', applied, false);
  check('Changes after activation remain pending', {
    ...applied,
    'selection': {
      'revision': 3,
      'roots': {'different': <String, Object?>{}},
    },
  }, true);
  check('A verified cache reuse needs no second apply', {
    ...built,
    'build': {'status': 'built', 'bundle': '/new', 'reusedFrom': 'old'},
  }, false);
  check('Native restore makes the selected custom composition pending', {
    ...applied,
    'native': {'active_mode': 'official_optimized'},
  }, true);
  check('An unhealthy activation remains pending', {
    ...applied,
    'native': {
      'active_mode': 'custom_optimized',
      'plugin_healthy': false,
      'plugin_bundle': '/new',
    },
  }, true);
  final recovered = <String, Object?>{
    ...applied,
    'active': {'id': 'new', 'bundle': '/new'},
    'native': {
      'active_mode': 'official_optimized',
      'plugin_healthy': false,
      'error': 'plugin bundle needs a different engine',
    },
  };
  check('Saved startup failure is not a new pending action', recovered, false);
  if (compositionStartupError(recovered) !=
      'plugin bundle needs a different engine') {
    throw StateError('Recovery must expose the native error');
  }
  check('New selection remains pending during recovery', {
    ...recovered,
    'selection': {
      'revision': 3,
      'roots': {'changed': <String, Object?>{}},
    },
  }, true);
  check('New candidate remains pending during recovery', {
    ...recovered,
    'build': {'status': 'built', 'bundle': '/replacement'},
  }, true);
  check('Matching engine restores healthy applied state', {
    ...recovered,
    'native': {
      'active_mode': 'custom_optimized',
      'plugin_healthy': true,
      'plugin_bundle': '/new',
    },
  }, false);
  // After a Denial update deniald runs the packaged shell without an error
  // and waits for the composition it had confirmed.
  final updated = <String, Object?>{
    ...applied,
    'native': {
      'active_mode': 'official_optimized',
      'plugin_healthy': false,
      'error': '',
      'plugin_rebuild': {
        'reason': 'source',
        'bundle': '/new',
        'version': '0.3.0',
      },
    },
  };
  if (pluginRebuild(updated)?['bundle'] != '/new' ||
      compositionStartupError(updated) != null ||
      rebuildVersion(pluginRebuild(updated)!) != '0.3.0' ||
      rebuildVersion({'version': 'development'}) != null) {
    throw StateError('An update waits for a rebuild and is not a failure');
  }
  stdout.writeln('PASS An update waits for a rebuild and is not a failure');
  if (pluginRebuild(applied) != null ||
      pluginRebuild({
            'native': {
              'available': false,
              'plugin_rebuild': {'bundle': '/new'},
            },
          }) !=
          null) {
    throw StateError('Only an available session reports a rebuild');
  }
  if (compositionStartupError(applied) != null ||
      compositionStartupError({
            'native': {'available': false, 'error': 'offline'},
          }) !=
          null) {
    throw StateError(
      'Healthy and unavailable sessions are not startup failures',
    );
  }
}
