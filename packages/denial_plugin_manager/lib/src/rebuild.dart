import 'dart:io';

import 'package:path/path.dart' as p;

import 'model.dart';
import 'store.dart';
import 'tools.dart';

/// The installed plugin build tools do not belong to the installed Denial.
const buildKitMismatch =
    'These plugin build tools belong to another Denial than the one this session runs. Use the plugin manager that came with it, then try again.';

/// The composition deniald last confirmed, which a Denial update rejected
/// (PLUGIN_MANAGER.md section 21). deniald runs the packaged shell meanwhile.
final class RebuildTarget {
  const RebuildTarget({
    required this.candidate,
    required this.bundle,
    required this.version,
    this.installedSource,
  });

  /// What deniald waits for, or null when it waits for nothing.
  static RebuildTarget? fromNative(
    ManagerStore store,
    Map<String, Object?> native,
  ) {
    final waiting = native['plugin_rebuild'];
    if (waiting is! Map || waiting['bundle'] is! String) return null;
    final bundle = waiting['bundle']! as String;
    final candidate = p.basename(p.dirname(bundle));
    if (p.basename(bundle) != 'bundle' ||
        !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(candidate) ||
        !store.file('candidates/$candidate/plan.json').existsSync()) {
      throw const CompositionException(
        'The plugins Denial was running were not built by this plugin manager. Open Plugins and apply your selection again.',
      );
    }
    if (store.read('candidates/$candidate/build.json')['bundle'] != bundle) {
      throw const CompositionException(
        'The plugins that were running can no longer be rebuilt. Open Plugins and apply your selection again.',
      );
    }
    final source = waiting['installed_source'];
    return RebuildTarget(
      candidate: candidate,
      bundle: bundle,
      version: waiting['version'] as String? ?? '',
      installedSource: source is Map ? source.cast<String, Object?>() : null,
    );
  }

  /// The candidate deniald last confirmed.
  final String candidate;
  final String bundle;

  /// The installed release, or a development build identity.
  final String version;

  /// The installed shell's source identity; null for a development bundle.
  final Map<String, Object?>? installedSource;

  /// A tagged release, which has release notes.
  bool get release => isReleaseVersion(version);
}

bool isReleaseVersion(String version) =>
    RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version);

/// Whether deniald still waits for candidate [base] to be rebuilt.
bool waitsForRebuildOf(
  ManagerStore store,
  Map<String, Object?> native,
  String base,
) {
  ManagerStore.validateId(base);
  final waiting = native['plugin_rebuild'];
  return waiting is Map &&
      waiting['bundle'] is String &&
      waiting['bundle'] == store.read('candidates/$base/build.json')['bundle'];
}

/// Build tools that belong to another Denial would compile a composition
/// that deniald rejects again. Compare before compiling anything.
void requireMatchingBuildKit(String runtimeRoot, RebuildTarget target) {
  final installed = target.installedSource;
  if (installed == null) return;
  if (contentKey(sourceIdentity(runtimeRoot)) != contentKey(installed)) {
    throw const CompositionException(buildKitMismatch);
  }
}

/// How long an automatic rebuild waits before asking deniald again, or null
/// when this is a quiet moment to switch the shell: the session is unlocked,
/// no input arrived for [idle], the shell does not capture the keyboard, no
/// visible application inhibits idling (a playing video, for example), and no
/// runtime transition is running.
Duration? untilQuietMoment(
  Map<String, Object?> native, {
  Duration idle = const Duration(milliseconds: 2500),
}) {
  final activity = native['session_activity'];
  if (activity is! Map) return null;
  if (native['operation'] != 'idle') return const Duration(seconds: 1);
  if (activity['locked'] == true) return const Duration(seconds: 2);
  if (activity['shell_captures_keyboard'] == true) {
    return const Duration(seconds: 1);
  }
  if (activity['idle_inhibited'] == true) return const Duration(seconds: 5);
  final quiet = activity['input_idle_ms'];
  if (quiet is! int) return null;
  final remaining = idle - Duration(milliseconds: quiet);
  // Ask again just after the idle threshold would pass without more input.
  return remaining <= Duration.zero
      ? null
      : remaining + const Duration(milliseconds: 100);
}

/// Asks a waiting rebuild to switch now; Plugins offers this while it waits.
File switchNowRequest(ManagerStore store) => store.file('rebuild-now');

/// Waits until a quiet moment while deniald still waits for [base], or until
/// the user asks to switch now. Returns false when the user meanwhile chose
/// the packaged shell or another composition. A session that stays
/// unavailable ends the wait with an error.
Future<bool> waitForQuietMoment(
  ManagerStore store,
  Future<Map<String, Object?>> Function() status,
  String base, {
  void Function(String)? progress,
  Future<void> Function(Duration) sleep = _sleep,
}) async {
  final request = switchNowRequest(store);
  bool requested() => request.existsSync();
  // Asking deniald spawns a process; the user's request needs no such cost.
  Future<void> pause(Duration duration) async {
    const slice = Duration(milliseconds: 250);
    for (var left = duration; left > Duration.zero; left -= slice) {
      if (requested()) return;
      await sleep(left < slice ? left : slice);
    }
  }

  var announced = false;
  var unavailable = 0;
  while (true) {
    final native = await status();
    if (native['available'] == false) {
      if (++unavailable > 30) {
        throw const CompositionException(
          'Denial is not available. Your plugins will be rebuilt at your next login.',
        );
      }
      await pause(const Duration(seconds: 1));
      continue;
    }
    unavailable = 0;
    if (!waitsForRebuildOf(store, native, base)) return false;
    final wait = requested() ? null : untilQuietMoment(native);
    if (wait == null) return true;
    if (!announced) {
      progress?.call('Waiting for a pause to switch');
      announced = true;
    }
    await pause(wait);
  }
}

Future<void> _sleep(Duration duration) => Future<void>.delayed(duration);
