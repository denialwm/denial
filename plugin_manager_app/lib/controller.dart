import 'dart:async';
import 'dart:convert';

import 'package:denial_sdk/plugin_selection.dart';

import 'selection_draft.dart';

import 'package:flutter/foundation.dart';

import 'backend.dart';
import 'selection_status.dart';
import 'job_feedback.dart';

class ManagerController extends ChangeNotifier {
  ManagerController(this.backend);
  final PluginBackend backend;
  Map<String, Object?> state = {};
  Map<String, Object?> catalog = {};
  final draft = SelectionDraft();
  String? _error;
  final connection = ConnectionFeedback();
  final feedback = JobFeedback();
  String? get startupError => compositionStartupError(state);
  String? get error =>
      _error ??
      connection.error ??
      startupError ??
      feedback.failure?['error'] as String?;
  set error(String? value) => _error = value;
  bool loading = true;
  bool submitting = false;
  String? _pendingRequest;
  bool _polling = false;
  bool _disposed = false;
  Timer? _timer;

  void start() {
    unawaited(refresh());
    _schedulePoll();
  }

  Map<String, Object?> get selection => draft.selection;
  Map<String, Object?> get roots => object(selection['roots']);
  Map<String, Object?> get installed =>
      object(object(state['installed'])['plugins']);
  List<Map<String, Object?>> get jobs => objects(state['jobs']);
  bool get busy =>
      submitting ||
      _pendingRequest != null ||
      jobs.any((j) => j['phase'] == 'queued' || j['phase'] == 'running');
  bool get configured => state['ready'] == true;

  Map<String, Object?> get preflight => checkPluginSelection(selection, {
    ...object(catalog['declarations']),
    ...object(state['declarations']),
  });
  List<Map<String, Object?>> get compatibilityIssues => [
    if (draft.stale) {'code': 'stale_selection'},
    ...objects(preflight['issues']),
  ];
  bool get canApply =>
      !loading &&
      !busy &&
      configured &&
      connection.available &&
      compatibilityIssues.isEmpty;

  /// Denial was updated and waits for the plugins it was running. Unsaved
  /// switch changes take precedence: applying them also brings plugins back.
  Map<String, Object?>? get pendingRebuild =>
      configured && !draft.dirty ? pluginRebuild(state) : null;

  /// Rebuilding restores a composition that already worked, so issues in a
  /// different saved selection do not block it.
  bool get canRebuild =>
      !loading && !busy && configured && connection.available;

  bool get needsApply =>
      configured &&
      (draft.dirty || pendingRebuild != null || selectionNeedsApply(state));

  bool get canSubmitApply =>
      needsApply && (pendingRebuild != null ? canRebuild : canApply);

  /// Plugins asked for it, so the shell switches as soon as it is built.
  List<String> get applyOperation =>
      pendingRebuild != null ? const ['rebuild', '--now'] : const ['apply'];

  void _schedulePoll() {
    _timer?.cancel();
    if (!_disposed) {
      _timer = Timer(
        busy ? const Duration(milliseconds: 600) : const Duration(seconds: 5),
        () async {
          await refresh(reloadCatalog: false);
          _schedulePoll();
        },
      );
    }
  }

  Future<void> refresh({bool reloadCatalog = true}) async {
    if (_polling || _disposed) return;
    _polling = true;
    try {
      final wasBusy = busy;
      final next = await backend.status();
      final finished =
          wasBusy &&
          !objects(
            next['jobs'],
          ).any((job) => job['phase'] == 'running' || job['phase'] == 'queued');
      if (_disposed) return;
      state = next;
      draft.observe(object(next['selection']));
      if (jobs.any((job) => job['id'] == _pendingRequest)) {
        _pendingRequest = null;
      }
      feedback.observe(jobs);
      final nextCatalog = reloadCatalog || catalog.isEmpty || finished
          ? await backend.catalog()
          : catalog;
      if (_disposed) return;
      catalog = nextCatalog;
      connection.succeeded();
    } catch (failure) {
      if (!_disposed) connection.failed(failure);
    } finally {
      _polling = false;
      if (!_disposed) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> submit(List<String> operation) async {
    if (busy) return;
    if (operation.first == 'rebuild' && !canRebuild) return;
    if ({'apply', 'update'}.contains(operation.first)) {
      if (!canApply) return;
      if (draft.dirty) {
        operation = [...operation, '--draft', jsonEncode(selection)];
      }
    }
    submitting = true;
    error = null;
    feedback.dismiss();
    notifyListeners();
    try {
      _pendingRequest = await backend.submit(operation);
    } catch (failure) {
      error = '$failure';
    } finally {
      if (!_disposed) {
        await refresh(reloadCatalog: false);
        submitting = false;
        if (!_disposed) {
          notifyListeners();
          _schedulePoll();
        }
      }
    }
  }

  void enable(Map<String, Object?> plugin) {
    if (busy) return;
    draft.enable(
      installed.containsKey(plugin['name'])
          ? object(installed[plugin['name']])
          : plugin,
    );
    notifyListeners();
  }

  void disable(String name) {
    if (busy) return;
    draft.disable(name);
    notifyListeners();
  }

  void discardDraft() {
    if (busy) return;
    draft.discard();
    notifyListeners();
  }

  void useDefaults() {
    if (busy) return;
    for (final name in roots.keys.toList()) {
      draft.disable(name);
    }
    for (final plugin in objects(catalog['builtins'])) {
      if (plugin['default'] == true) draft.enable(plugin);
    }
    notifyListeners();
  }

  static List<String> sourceArguments(
    String command,
    Map<String, Object?> source,
  ) => [
    command,
    source['location']! as String,
    if (source['kind'] == 'builtin') '--builtin',
    if (source['kind'] == 'local') '--local',
    if (source['path'] != null) ...['--path', source['path']! as String],
    if (source['ref'] != null) ...['--ref', source['ref']! as String],
  ];

  /// The running rebuild waits for a pause before replacing the shell. While
  /// the user watches it here, they are rarely idle, so offer to switch now.
  bool get rebuildWaitsForPause => jobs.any(
    (job) =>
        job['operation'] == 'rebuild' &&
        job['phase'] == 'running' &&
        (job['progress'] as Map?)?['label'] == 'Switching when you pause',
  );

  bool _switchRequested = false;
  bool get switchRequested => _switchRequested && rebuildWaitsForPause;

  Future<void> switchNow() async {
    if (!rebuildWaitsForPause || _switchRequested) return;
    _switchRequested = true;
    notifyListeners();
    try {
      await backend.invoke(['rebuild-now']);
    } catch (failure) {
      _switchRequested = false;
      error = '$failure';
    }
    if (!_disposed) {
      notifyListeners();
      await refresh(reloadCatalog: false);
    }
  }

  void dismissError() {
    error = null;
    connection.dismiss();
    feedback.dismiss();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
