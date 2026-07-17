import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../launcher/launcher_providers.dart';
import '../../launcher/runtime_paths.dart';
import '../providers/local_wallpaper_provider.dart';
import '../providers/wallhaven_wallpaper_provider.dart';
import '../wallpaper.dart';
import '../wallpaper_provider.dart';

final localWallpaperSourceProvider = Provider<WallpaperProvider>((ref) {
  final paths = ref.watch(runtimePathsProvider);
  return LocalWallpaperProvider(
    directory: Directory(paths.wallpaperDirectory),
  );
});

final wallhavenWallpaperSourceProvider = Provider<WallpaperProvider>((ref) {
  final paths = ref.watch(runtimePathsProvider);
  final provider = WallhavenWallpaperProvider(
    downloadDirectory: Directory(paths.wallpaperDirectory),
    apiKey: paths.environment['WALLHAVEN_API_KEY'] ?? '',
  );
  ref.onDispose(provider.dispose);
  return provider;
});

final wallpaperSourcesProvider = Provider<List<WallpaperProvider>>((ref) {
  return <WallpaperProvider>[
    ref.watch(localWallpaperSourceProvider),
    ref.watch(wallhavenWallpaperSourceProvider),
  ];
});

final wallpaperStoreProvider = Provider<WallpaperStore>((ref) {
  return WallpaperStore(ref.watch(runtimePathsProvider));
});

final wallpaperControllerProvider =
    StateNotifierProvider<WallpaperController, WallpaperExperienceState>((ref) {
  return WallpaperController(
    sources: ref.watch(wallpaperSourcesProvider),
    store: ref.watch(wallpaperStoreProvider),
  );
});

@immutable
class WallpaperExperienceState {
  const WallpaperExperienceState({
    required this.assignment,
    required this.outgoingAssignment,
    required this.target,
    required this.transitionTarget,
    required this.revealOriginFraction,
    required this.transitionId,
    required this.selectorVisible,
    required this.targetPixelSize,
    required this.candidates,
    required this.query,
    required this.loading,
    required this.downloadingKey,
    required this.downloadProgress,
    required this.error,
  });

  factory WallpaperExperienceState.initial() {
    return WallpaperExperienceState(
      assignment: WallpaperAssignment.initial(),
      outgoingAssignment: null,
      target: const WallpaperTarget.all(),
      transitionTarget: const WallpaperTarget.all(),
      revealOriginFraction: const Offset(0.5, 0.5),
      transitionId: 0,
      selectorVisible: false,
      targetPixelSize: Size.zero,
      candidates: <WallpaperCandidate>[],
      query: '',
      loading: false,
      downloadingKey: null,
      downloadProgress: 0.0,
      error: null,
    );
  }

  final WallpaperAssignment assignment;
  final WallpaperAssignment? outgoingAssignment;
  final WallpaperTarget target;
  final WallpaperTarget transitionTarget;
  final Offset revealOriginFraction;
  final int transitionId;
  final bool selectorVisible;
  final Size targetPixelSize;
  final List<WallpaperCandidate> candidates;
  final String query;
  final bool loading;
  final String? downloadingKey;
  final double downloadProgress;
  final String? error;

  WallpaperResource get current => assignment.forTarget(target);

  WallpaperResource? get outgoing {
    return outgoingAssignment?.forTarget(transitionTarget);
  }

  WallpaperExperienceState copyWith({
    WallpaperAssignment? assignment,
    WallpaperAssignment? outgoingAssignment,
    bool clearOutgoing = false,
    WallpaperTarget? target,
    WallpaperTarget? transitionTarget,
    Offset? revealOriginFraction,
    int? transitionId,
    bool? selectorVisible,
    Size? targetPixelSize,
    List<WallpaperCandidate>? candidates,
    String? query,
    bool? loading,
    String? downloadingKey,
    bool clearDownloadingKey = false,
    double? downloadProgress,
    String? error,
    bool clearError = false,
  }) {
    return WallpaperExperienceState(
      assignment: assignment ?? this.assignment,
      outgoingAssignment:
          clearOutgoing ? null : outgoingAssignment ?? this.outgoingAssignment,
      target: target ?? this.target,
      transitionTarget: transitionTarget ?? this.transitionTarget,
      revealOriginFraction: revealOriginFraction ?? this.revealOriginFraction,
      transitionId: transitionId ?? this.transitionId,
      selectorVisible: selectorVisible ?? this.selectorVisible,
      targetPixelSize: targetPixelSize ?? this.targetPixelSize,
      candidates: candidates ?? this.candidates,
      query: query ?? this.query,
      loading: loading ?? this.loading,
      downloadingKey:
          clearDownloadingKey ? null : downloadingKey ?? this.downloadingKey,
      downloadProgress: downloadProgress ?? this.downloadProgress,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class WallpaperController extends StateNotifier<WallpaperExperienceState> {
  WallpaperController({
    required List<WallpaperProvider> sources,
    required WallpaperStore store,
  })  : _sources = List<WallpaperProvider>.unmodifiable(sources),
        _store = store,
        super(WallpaperExperienceState.initial()) {
    unawaited(_restore());
  }

  static const Duration _searchDebounce = Duration(milliseconds: 360);

  final List<WallpaperProvider> _sources;
  final WallpaperStore _store;
  final Map<String, List<WallpaperCandidate>> _sourceResults =
      <String, List<WallpaperCandidate>>{};
  Timer? _searchTimer;
  int _searchGeneration = 0;
  int _assignmentGeneration = 0;

  void openSelector({required Size targetPixelSize}) {
    _searchTimer?.cancel();
    state = state.copyWith(
      selectorVisible: true,
      target: const WallpaperTarget.all(),
      targetPixelSize: targetPixelSize,
      query: '',
      clearError: true,
    );
    unawaited(_search(''));
  }

  void selectTarget({
    required WallpaperTarget target,
    required Size targetPixelSize,
  }) {
    if (target == state.target && targetPixelSize == state.targetPixelSize) {
      return;
    }
    _searchTimer?.cancel();
    state = state.copyWith(
      target: target,
      targetPixelSize: targetPixelSize,
      clearError: true,
    );
    unawaited(_search(state.query));
  }

  void setSpanAlignment(WallpaperSpanAlignment alignment) {
    final assignment = state.assignment.withSpanAlignment(alignment);
    if (assignment == state.assignment) {
      return;
    }
    _assignmentGeneration += 1;
    state = state.copyWith(
      assignment: assignment,
      clearOutgoing: true,
    );
    unawaited(_store.write(assignment));
  }

  void setDarkness(double darkness) {
    final assignment = state.assignment.withDarkness(state.target, darkness);
    if (assignment == state.assignment) {
      return;
    }
    _assignmentGeneration += 1;
    state = state.copyWith(
      assignment: assignment,
      clearOutgoing: true,
    );
  }

  void commitDarkness(double darkness) {
    setDarkness(darkness);
    unawaited(_store.write(state.assignment));
  }

  void closeSelector() {
    if (!state.selectorVisible) {
      return;
    }
    _searchTimer?.cancel();
    state = state.copyWith(selectorVisible: false, clearError: true);
  }

  void setQuery(String query) {
    if (query == state.query) {
      return;
    }
    state = state.copyWith(query: query, clearError: true);
    _searchTimer?.cancel();
    _searchTimer = Timer(_searchDebounce, () => unawaited(_search(query)));
  }

  void submitQuery() {
    _searchTimer?.cancel();
    unawaited(_search(state.query));
  }

  void reportError(String message) {
    state = state.copyWith(error: message);
  }

  Future<WallpaperResource?> resolveCandidate(
    WallpaperCandidate candidate,
  ) async {
    if (state.downloadingKey != null) {
      return null;
    }
    WallpaperProvider? source;
    for (final candidateSource in _sources) {
      if (candidateSource.id == candidate.providerId) {
        source = candidateSource;
        break;
      }
    }
    if (source == null) {
      state = state.copyWith(error: 'Wallpaper source is unavailable');
      return null;
    }

    state = state.copyWith(
      downloadingKey: candidate.key,
      downloadProgress: candidate.resource == null ? 0.0 : 1.0,
      clearError: true,
    );
    try {
      final resource = await source.materialize(
        candidate,
        onProgress: (progress) {
          if (mounted && state.downloadingKey == candidate.key) {
            state = state.copyWith(downloadProgress: progress);
          }
        },
      );
      if (!mounted || state.downloadingKey != candidate.key) {
        return null;
      }
      _rememberMaterialized(candidate, resource);
      state = state.copyWith(
        clearDownloadingKey: true,
        downloadProgress: 0.0,
      );
      return resource;
    } on Object catch (error) {
      if (mounted) {
        state = state.copyWith(
          clearDownloadingKey: true,
          downloadProgress: 0.0,
          error: _friendlyError(error),
        );
      }
      return null;
    }
  }

  void commitCandidate(
    WallpaperCandidate candidate,
    WallpaperResource resource, {
    required Offset revealOriginFraction,
    WallpaperTarget? target,
  }) {
    final committedTarget = target ?? state.target;
    final assignment = state.assignment.apply(committedTarget, resource);
    if (assignment == state.assignment) {
      return;
    }
    _rememberMaterialized(candidate, resource);
    final outgoingAssignment = state.assignment;
    _assignmentGeneration += 1;
    state = state.copyWith(
      assignment: assignment,
      outgoingAssignment: outgoingAssignment,
      transitionTarget: committedTarget,
      revealOriginFraction: revealOriginFraction,
      transitionId: state.transitionId + 1,
      clearError: true,
    );
    unawaited(_store.write(assignment));
  }

  void completeTransition(int transitionId) {
    if (transitionId != state.transitionId || state.outgoing == null) {
      return;
    }
    state = state.copyWith(clearOutgoing: true);
  }

  Future<void> _restore() async {
    final generation = _assignmentGeneration;
    final restored = await _store.read();
    if (!mounted ||
        generation != _assignmentGeneration ||
        restored == null ||
        restored == state.assignment) {
      return;
    }
    state = state.copyWith(assignment: restored);
  }

  Future<void> _search(String rawQuery) async {
    final generation = ++_searchGeneration;
    _sourceResults.clear();
    state = state.copyWith(
      loading: true,
      candidates: const <WallpaperCandidate>[],
      clearError: true,
    );
    if (_sources.isEmpty) {
      state = state.copyWith(
        loading: false,
        error: 'No wallpaper sources are available',
      );
      return;
    }

    var pending = _sources.length;
    final errors = <Object>[];
    final query = WallpaperQuery(
      text: rawQuery.trim(),
      page: 1,
      limit: 24,
      targetPixelSize: state.targetPixelSize,
    );
    for (final source in _sources) {
      unawaited(() async {
        try {
          final page = await source.search(query);
          if (!mounted || generation != _searchGeneration) {
            return;
          }
          _sourceResults[source.id] = page.items;
        } on Object catch (error) {
          errors.add(error);
        } finally {
          if (!mounted || generation != _searchGeneration) {
            return;
          }
          pending -= 1;
          final combined = <WallpaperCandidate>[
            for (final orderedSource in _sources)
              ...?_sourceResults[orderedSource.id],
          ];
          state = state.copyWith(
            candidates: List<WallpaperCandidate>.unmodifiable(combined),
            loading: pending > 0,
            error: pending == 0 && combined.isEmpty && errors.isNotEmpty
                ? _friendlyError(errors.last)
                : null,
            clearError:
                !(pending == 0 && combined.isEmpty && errors.isNotEmpty),
          );
        }
      }());
    }
  }

  void _rememberMaterialized(
    WallpaperCandidate candidate,
    WallpaperResource resource,
  ) {
    final updated = state.candidates
        .map(
          (item) => item.key == candidate.key
              ? item.copyWith(resource: resource)
              : item,
        )
        .toList(growable: false);
    final sourceItems = _sourceResults[candidate.providerId];
    if (sourceItems != null) {
      _sourceResults[candidate.providerId] = sourceItems
          .map(
            (item) => item.key == candidate.key
                ? item.copyWith(resource: resource)
                : item,
          )
          .toList(growable: false);
    }
    state = state.copyWith(candidates: updated);
  }

  String _friendlyError(Object error) {
    if (error is SocketException) {
      return 'Wallhaven is unreachable';
    }
    if (error is TimeoutException) {
      return 'The wallpaper request timed out';
    }
    if (error is HttpException || error is FormatException) {
      return error.toString().replaceFirst(RegExp('^[^:]+: '), '');
    }
    return 'Could not load this wallpaper';
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    super.dispose();
  }
}

class WallpaperStore {
  WallpaperStore(this._paths);

  final RuntimePaths _paths;
  Future<void> _writeQueue = Future<void>.value();

  Future<WallpaperAssignment?> read() async {
    try {
      final file = await _paths.wallpaperStateFile();
      if (!await file.exists()) {
        return null;
      }
      final value = (await file.readAsString()).trim();
      if (value.isEmpty) {
        return null;
      }
      if (!value.startsWith('{')) {
        final legacy = WallpaperResource.fromPersistenceValue(value);
        return await _validResource(legacy)
            ? WallpaperAssignment(all: legacy!)
            : null;
      }
      final decoded = jsonDecode(value);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      final parsedAll = WallpaperResource.fromPersistenceValue(
        decoded['all'] is String ? decoded['all'] as String : '',
      );
      final all = await _validResource(parsedAll)
          ? parsedAll!
          : WallpaperResource.defaultWallpaper;
      final alignment = WallpaperSpanAlignment(
        horizontal: _horizontalAlignment(decoded['horizontalAlignment']),
        vertical: _verticalAlignment(decoded['verticalAlignment']),
      );
      final allDarkness = _darkness(decoded['darkness']) ?? 0.0;
      final overrides = <String, WallpaperResource>{};
      final rawOverrides = decoded['outputs'];
      if (rawOverrides is Map) {
        for (final entry in rawOverrides.entries) {
          final name = entry.key;
          final value = entry.value;
          if (name is! String || name.isEmpty || value is! String) {
            continue;
          }
          final resource = WallpaperResource.fromPersistenceValue(value);
          if (await _validResource(resource) && resource != all) {
            overrides[name] = resource!;
          }
        }
      }
      final darknessOverrides = <String, double>{};
      final rawDarknessOverrides = decoded['outputDarkness'];
      if (rawDarknessOverrides is Map) {
        for (final entry in rawDarknessOverrides.entries) {
          final name = entry.key;
          final darkness = _darkness(entry.value);
          if (name is! String ||
              name.isEmpty ||
              darkness == null ||
              darkness == allDarkness) {
            continue;
          }
          darknessOverrides[name] = darkness;
        }
      }
      return WallpaperAssignment(
        all: all,
        spanAlignment: alignment,
        allDarkness: allDarkness,
        outputOverrides: overrides,
        outputDarknessOverrides: darknessOverrides,
      );
    } on FileSystemException catch (_) {
      return null;
    } on FormatException catch (_) {
      return null;
    }
  }

  Future<void> write(WallpaperAssignment assignment) async {
    final write = _writeQueue.then((_) => _write(assignment));
    _writeQueue = write;
    await write;
  }

  Future<void> _write(WallpaperAssignment assignment) async {
    try {
      final file = await _paths.wallpaperStateFile();
      final temporary = File('${file.path}.tmp');
      final payload = jsonEncode(<String, Object>{
        'version': 3,
        'all': assignment.all.persistenceValue,
        'horizontalAlignment': assignment.spanAlignment.horizontal.name,
        'verticalAlignment': assignment.spanAlignment.vertical.name,
        'darkness': assignment.allDarkness,
        'outputs': <String, String>{
          for (final entry in assignment.outputOverrides.entries)
            entry.key: entry.value.persistenceValue,
        },
        'outputDarkness': assignment.outputDarknessOverrides,
      });
      await temporary.writeAsString(
        '$payload\n',
        flush: true,
      );
      await temporary.rename(file.path);
    } on FileSystemException {
      // Persistence is best-effort; the committed wallpaper remains visible.
    }
  }

  Future<bool> _validResource(WallpaperResource? resource) async {
    if (resource == null) {
      return false;
    }
    if (resource.kind == WallpaperResourceKind.asset) {
      return true;
    }
    return File(resource.path).exists();
  }

  WallpaperHorizontalAlignment _horizontalAlignment(Object? value) {
    for (final alignment in WallpaperHorizontalAlignment.values) {
      if (alignment.name == value) {
        return alignment;
      }
    }
    return WallpaperHorizontalAlignment.center;
  }

  WallpaperVerticalAlignment _verticalAlignment(Object? value) {
    for (final alignment in WallpaperVerticalAlignment.values) {
      if (alignment.name == value) {
        return alignment;
      }
    }
    return WallpaperVerticalAlignment.center;
  }

  double? _darkness(Object? value) {
    if (value is! num) {
      return null;
    }
    final darkness = value.toDouble();
    if (!darkness.isFinite) {
      return null;
    }
    return darkness.clamp(0.0, 1.0).toDouble();
  }
}
