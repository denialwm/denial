import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../launcher_providers.dart';
import '../repositories/application_recents_repository.dart';

String desktopApplicationRecentId(String desktopFileId) =>
    'desktop:$desktopFileId';

String localApplicationRecentId(String applicationId) => 'local:$applicationId';

final applicationRecentsStoreProvider = Provider<ApplicationRecentsStore>((
  ref,
) {
  return ApplicationRecentsRepository(paths: ref.watch(runtimePathsProvider));
});

final applicationRecentsProvider =
    NotifierProvider<ApplicationRecentsController, List<String>>(
      ApplicationRecentsController.new,
    );

class ApplicationRecentsController extends Notifier<List<String>> {
  Future<void> _writeQueue = Future<void>.value();
  int _mutationRevision = 0;
  bool _disposed = false;

  @override
  List<String> build() {
    _disposed = false;
    final store = ref.watch(applicationRecentsStoreProvider);
    final loadRevision = _mutationRevision;
    ref.onDispose(() => _disposed = true);
    unawaited(_load(store, loadRevision));
    return const <String>[];
  }

  void record(String entryId) {
    if (entryId.isEmpty || entryId.length > 4096) {
      return;
    }
    final next = _prioritize(entryId, state);
    if (listEquals(next, state)) {
      return;
    }
    _mutationRevision += 1;
    state = next;
    _queueSave(ref.read(applicationRecentsStoreProvider), next);
  }

  Future<void> _load(ApplicationRecentsStore store, int loadRevision) async {
    final saved = await store.readEntries();
    if (_disposed) {
      return;
    }
    if (_mutationRevision == loadRevision) {
      if (!listEquals(saved, state)) {
        state = saved;
      }
      return;
    }

    final merged = _mergeEntries(state, saved);
    if (!listEquals(merged, state)) {
      state = merged;
      _queueSave(store, merged);
    }
  }

  void _queueSave(ApplicationRecentsStore store, List<String> entries) {
    _writeQueue = _writeQueue.then((_) => store.saveEntries(entries));
  }
}

List<String> _prioritize(String entryId, List<String> entries) {
  return _mergeEntries(<String>[entryId], entries);
}

List<String> _mergeEntries(List<String> first, List<String> second) {
  final seen = <String>{};
  final merged = <String>[];
  for (final entry in <String>[...first, ...second]) {
    if (!seen.add(entry)) {
      continue;
    }
    merged.add(entry);
    if (merged.length == applicationRecentEntryLimit) {
      break;
    }
  }
  return List<String>.unmodifiable(merged);
}
