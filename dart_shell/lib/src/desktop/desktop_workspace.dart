import 'dart:math' as math;

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/display_layout.dart';
import '../models/denial_window.dart';
import '../models/denial_window_event.dart';
import '../models/shell_popup_placement.dart';
import 'desktop_overview_layout.dart';

abstract final class DesktopMetrics {
  static const double frameBorder = 1.0;
  static const double panelGap = 12.0;
  static const double panelMargin = 14.0;
  static const double edgeTriggerWidth = 8.0;
  static const double edgeTriggerExtent = 96.0;

  /// Clamps the configured system bar strip to the visible canvas. The strip
  /// itself comes from [DisplayLayout.systemBarRect]; hidden bars stay
  /// [Rect.zero].
  static Rect systemBarRect(Size viewSize, Rect configuredRect) {
    if (configuredRect.isEmpty) {
      return Rect.zero;
    }
    final clipped = configuredRect.intersect(Offset.zero & viewSize);
    return clipped.isEmpty ? Rect.zero : clipped;
  }

  static Rect launcherRect(
    Size viewSize, {
    Rect? outputRect,
    ShellPopupPlacement placement = const ShellPopupPlacement(
      anchor: ShellPopupAnchor.topLeft,
      width: 680,
      height: 620,
      margin: panelMargin,
    ),
  }) {
    return placement.resolve(_outputBounds(viewSize, outputRect));
  }

  static Rect dashboardRect(
    Size viewSize, {
    Rect? outputRect,
    ShellPopupPlacement placement = const ShellPopupPlacement(
      anchor: ShellPopupAnchor.bottomLeft,
      width: 470,
      height: 620,
      margin: panelMargin,
    ),
  }) {
    return placement.resolve(_outputBounds(viewSize, outputRect));
  }

  static Rect launcherTriggerRect(
    Size viewSize, {
    Rect? outputRect,
    ShellPopupPlacement placement = const ShellPopupPlacement(
      anchor: ShellPopupAnchor.topLeft,
      width: 680,
      height: 620,
      margin: panelMargin,
    ),
  }) {
    return placement.edgeTrigger(
      _outputBounds(viewSize, outputRect),
      thickness: edgeTriggerWidth,
      extent: edgeTriggerExtent,
    );
  }

  static Rect dashboardTriggerRect(
    Size viewSize, {
    Rect? outputRect,
    ShellPopupPlacement placement = const ShellPopupPlacement(
      anchor: ShellPopupAnchor.bottomLeft,
      width: 470,
      height: 620,
      margin: panelMargin,
    ),
  }) {
    return placement.edgeTrigger(
      _outputBounds(viewSize, outputRect),
      thickness: edgeTriggerWidth,
      extent: edgeTriggerExtent,
    );
  }

  static Rect _outputBounds(Size viewSize, Rect? outputRect) {
    final canvas = Offset.zero & viewSize;
    return (outputRect ?? canvas).intersect(canvas);
  }

  static Rect windowWorkArea(Size viewSize) {
    return Offset.zero & viewSize;
  }
}

enum DesktopPanel { none, launcher, dashboard }

@immutable
class DesktopOverviewState {
  DesktopOverviewState({
    required this.monitorId,
    required this.bounds,
    required this.backgroundBounds,
    required Map<int, Rect> frames,
  }) : frames = Map.unmodifiable(frames);

  final int monitorId;
  final Rect bounds;
  final Rect backgroundBounds;
  final Map<int, Rect> frames;

  bool contains(int objectId) => frames.containsKey(objectId);
}

/// Flutter's canonical live placement for one native window.
///
/// Geometry and monitor/workspace ownership must be updated together. Window
/// snapshots initialize and reconcile this record; overview and fullscreen
/// routing never read live placement back from the texture metadata model.
@immutable
class DesktopWindowPlacement {
  const DesktopWindowPlacement({
    required this.objectId,
    required this.frame,
    required this.z,
    required this.monitorId,
    this.workspaceId = -1,
    this.minimized = false,
    this.maximized = false,
    this.fullscreen = false,
    this.serverSideDecorated = true,
    this.dragging = false,
    this.restoreFrame,
    this.fullscreenRestoreFrame,
  });

  final int objectId;
  final Rect frame;
  final int z;
  final int monitorId;
  final int workspaceId;
  final bool minimized;
  final bool maximized;
  final bool fullscreen;
  final bool serverSideDecorated;
  final bool dragging;
  final Rect? restoreFrame;
  final Rect? fullscreenRestoreFrame;

  double get frameBorder =>
      fullscreen || !serverSideDecorated ? 0.0 : DesktopMetrics.frameBorder;

  Rect get contentRect => frame.deflate(frameBorder);

  DesktopWindowPlacement copyWith({
    Rect? frame,
    int? z,
    int? monitorId,
    int? workspaceId,
    bool? minimized,
    bool? maximized,
    bool? fullscreen,
    bool? serverSideDecorated,
    bool? dragging,
    Rect? restoreFrame,
    bool clearRestoreFrame = false,
    Rect? fullscreenRestoreFrame,
    bool clearFullscreenRestoreFrame = false,
  }) {
    return DesktopWindowPlacement(
      objectId: objectId,
      frame: frame ?? this.frame,
      z: z ?? this.z,
      monitorId: monitorId ?? this.monitorId,
      workspaceId: workspaceId ?? this.workspaceId,
      minimized: minimized ?? this.minimized,
      maximized: maximized ?? this.maximized,
      fullscreen: fullscreen ?? this.fullscreen,
      serverSideDecorated: serverSideDecorated ?? this.serverSideDecorated,
      dragging: dragging ?? this.dragging,
      restoreFrame: clearRestoreFrame
          ? null
          : restoreFrame ?? this.restoreFrame,
      fullscreenRestoreFrame: clearFullscreenRestoreFrame
          ? null
          : fullscreenRestoreFrame ?? this.fullscreenRestoreFrame,
    );
  }
}

/// Orders Flutter-composited windows from back to front.
///
/// Pin state is native window metadata, while transient focus order remains in
/// [DesktopWindowPlacement.z]. Keeping the comparison here lets painting and
/// native input routing share exactly the same stack.
int compareDesktopWindowStack(
  DesktopWindowPlacement a,
  DesktopWindowPlacement b,
  Map<int, DenialWindow> windowsById,
) {
  final aPinned = windowsById[a.objectId]?.pinned ?? false;
  final bPinned = windowsById[b.objectId]?.pinned ?? false;
  if (aPinned != bPinned) {
    return aPinned ? 1 : -1;
  }
  final zOrder = a.z.compareTo(b.z);
  return zOrder != 0 ? zOrder : a.objectId.compareTo(b.objectId);
}

/// Returns the visually topmost window at [position] using the same pinned and
/// focus ordering as painting and native input publication.
DenialWindow? desktopWindowAtPosition({
  required Offset position,
  required DesktopWorkspaceState workspace,
  required Map<int, DenialWindow> windowsById,
}) {
  final placements =
      workspace.placements.values
          .where(
            (placement) =>
                !placement.minimized &&
                windowsById.containsKey(placement.objectId),
          )
          .toList(growable: false)
        ..sort((a, b) => compareDesktopWindowStack(a, b, windowsById));
  for (final placement in placements.reversed) {
    final window = windowsById[placement.objectId]!;
    for (final popup in window.popupRoots.toList(growable: false).reversed) {
      final popupRect = window.mapSurfaceRect(popup, placement.contentRect);
      if (popupRect.contains(position)) {
        return window;
      }
    }
    if (placement.frame.contains(position)) {
      return window;
    }
  }
  return null;
}

@immutable
class DesktopWorkspaceState {
  DesktopWorkspaceState({
    required Map<int, DesktopWindowPlacement> placements,
    required this.nextZ,
    required this.viewSize,
    this.panel = DesktopPanel.none,
    this.overview,
    this.inputLayoutRevision = 0,
  }) : placements = Map.unmodifiable(placements);

  factory DesktopWorkspaceState.initial() {
    return DesktopWorkspaceState(
      placements: const <int, DesktopWindowPlacement>{},
      nextZ: 1,
      viewSize: Size.zero,
    );
  }

  final Map<int, DesktopWindowPlacement> placements;
  final int nextZ;
  final Size viewSize;
  final DesktopPanel panel;
  final DesktopOverviewState? overview;

  /// Advances only when state consumed by native input publication may have
  /// changed. Panel-only updates therefore do not rebuild routing maps.
  final int inputLayoutRevision;

  bool get launcherOpen => panel == DesktopPanel.launcher;
  bool get dashboardOpen => panel == DesktopPanel.dashboard;
  bool get overviewActive => overview != null;

  bool isInOverview(int objectId) => overview?.contains(objectId) ?? false;

  Rect visualFrame(DesktopWindowPlacement placement) {
    return overview?.frames[placement.objectId] ?? placement.frame;
  }

  DesktopWorkspaceState copyWith({
    Map<int, DesktopWindowPlacement>? placements,
    int? nextZ,
    Size? viewSize,
    DesktopPanel? panel,
    DesktopOverviewState? overview,
    bool clearOverview = false,
  }) {
    return DesktopWorkspaceState(
      placements: placements ?? this.placements,
      nextZ: nextZ ?? this.nextZ,
      viewSize: viewSize ?? this.viewSize,
      panel: panel ?? this.panel,
      overview: clearOverview ? null : overview ?? this.overview,
      inputLayoutRevision:
          inputLayoutRevision +
          ((placements != null || overview != null || clearOverview) ? 1 : 0),
    );
  }
}

/// Whether rebuilding the static desktop scene can change its structure.
///
/// A native move/resize grab changes only one keyed window's geometry. That
/// layer samples its live rectangle independently, so rebuilding the
/// surrounding wallpaper, bars, panels, and every other window is redundant.
bool desktopWorkspaceHasSameSceneStructure(
  DesktopWorkspaceState left,
  DesktopWorkspaceState right,
) {
  if (identical(left, right)) {
    return true;
  }
  if (left.nextZ != right.nextZ ||
      left.viewSize != right.viewSize ||
      left.panel != right.panel ||
      !identical(left.overview, right.overview) ||
      left.placements.length != right.placements.length) {
    return false;
  }
  for (final entry in left.placements.entries) {
    final other = right.placements[entry.key];
    if (other == null ||
        !_desktopPlacementHasSameSceneStructure(entry.value, other)) {
      return false;
    }
  }
  return true;
}

bool _desktopPlacementHasSameSceneStructure(
  DesktopWindowPlacement left,
  DesktopWindowPlacement right,
) {
  if (identical(left, right)) {
    return true;
  }
  final livePlacementOnly = left.dragging && right.dragging;
  return left.objectId == right.objectId &&
      (left.frame == right.frame || livePlacementOnly) &&
      left.z == right.z &&
      left.monitorId == right.monitorId &&
      left.workspaceId == right.workspaceId &&
      left.minimized == right.minimized &&
      left.maximized == right.maximized &&
      left.fullscreen == right.fullscreen &&
      left.serverSideDecorated == right.serverSideDecorated &&
      left.dragging == right.dragging &&
      left.restoreFrame == right.restoreFrame &&
      left.fullscreenRestoreFrame == right.fullscreenRestoreFrame;
}

/// Applies one live native placement delta to its derived visual rectangle.
///
/// [visualFrame] may include a shell-only offset while [placementFrame] is the
/// canonical native frame. Applying deltas edge-by-edge preserves that offset
/// and follows left/top-edge resizes as well as bottom/right-edge resizes.
Rect desktopLivePlacementVisualFrame({
  required Rect visualFrame,
  required Rect placementFrame,
  required Rect livePlacementFrame,
}) {
  return Rect.fromLTRB(
    visualFrame.left + livePlacementFrame.left - placementFrame.left,
    visualFrame.top + livePlacementFrame.top - placementFrame.top,
    visualFrame.right + livePlacementFrame.right - placementFrame.right,
    visualFrame.bottom + livePlacementFrame.bottom - placementFrame.bottom,
  );
}

final desktopWorkspaceProvider =
    NotifierProvider<DesktopWorkspaceController, DesktopWorkspaceState>(
      DesktopWorkspaceController.new,
    );

class DesktopWorkspaceController extends Notifier<DesktopWorkspaceState> {
  @override
  DesktopWorkspaceState build() => DesktopWorkspaceState.initial();

  final Map<int, Offset> _moveRemainders = <int, Offset>{};
  final Map<int, Rect> _pendingNativeFrames = <int, Rect>{};
  // Native ordering prevents stale placement events but has no visual effect,
  // so keep it outside provider state and its widget rebuild boundary.
  final Map<int, int> _nativeSequences = <int, int>{};
  final Map<int, ({Rect frame, int z})> _overviewDragOrigins =
      <int, ({Rect frame, int z})>{};
  List<DenialWindow>? _lastSyncedWindows;
  int _lastSyncedSnapshotSequence = -1;
  double _devicePixelRatio = 1.0;
  Map<int, Rect> _workAreas = const <int, Rect>{};

  /// Publishes per-monitor work areas (output rect minus the system bar).
  /// Maximized windows are reconciled immediately so a late display-layout
  /// load or a bar change never leaves a window under the bar.
  void syncWorkAreas(Map<int, Rect> workAreas) {
    if (mapEquals(_workAreas, workAreas)) {
      return;
    }
    _workAreas = Map<int, Rect>.unmodifiable(workAreas);
    if (state.viewSize.isEmpty) {
      return;
    }
    var changed = false;
    final next = Map<int, DesktopWindowPlacement>.of(state.placements);
    for (final placement in state.placements.values) {
      if (!placement.maximized || placement.fullscreen) {
        continue;
      }
      final frame = _maximizedFrame(placement.monitorId, state.viewSize);
      if (frame != placement.frame) {
        _pendingNativeFrames[placement.objectId] = frame;
        next[placement.objectId] = placement.copyWith(frame: frame);
        changed = true;
      }
    }
    if (changed) {
      state = state.copyWith(placements: next);
    }
  }

  Rect _maximizedFrame(int monitorId, Size viewSize) {
    final workArea = _workAreas[monitorId]?.intersect(Offset.zero & viewSize);
    if (workArea == null || workArea.isEmpty) {
      return DesktopMetrics.windowWorkArea(viewSize);
    }
    return workArea;
  }

  void syncWindows(
    List<DenialWindow> windows,
    Size viewSize,
    double devicePixelRatio, {
    int snapshotSequence = 0,
  }) {
    if (viewSize.width <= 0.0 || viewSize.height <= 0.0) {
      return;
    }

    final nextPixelRatio = devicePixelRatio.isFinite && devicePixelRatio > 0.0
        ? devicePixelRatio
        : 1.0;
    final pixelRatioChanged = nextPixelRatio != _devicePixelRatio;
    if (identical(windows, _lastSyncedWindows) &&
        snapshotSequence == _lastSyncedSnapshotSequence &&
        !pixelRatioChanged &&
        state.viewSize == viewSize) {
      return;
    }
    _lastSyncedWindows = windows;
    _lastSyncedSnapshotSequence = snapshotSequence;
    final viewMetricsChanged = pixelRatioChanged || state.viewSize != viewSize;
    if (pixelRatioChanged) {
      _devicePixelRatio = nextPixelRatio;
      _moveRemainders.clear();
    }

    final userWindows = windows.where((window) => window.isUserApp).toList();
    final activeIds = {for (final window in userWindows) window.objectId};
    _moveRemainders.removeWhere((objectId, _) => !activeIds.contains(objectId));
    _pendingNativeFrames.removeWhere(
      (objectId, _) => !activeIds.contains(objectId),
    );
    _nativeSequences.removeWhere(
      (objectId, _) => !activeIds.contains(objectId),
    );
    final next = <int, DesktopWindowPlacement>{
      for (final entry in state.placements.entries)
        if (activeIds.contains(entry.key)) entry.key: entry.value,
    };
    var nextZ = state.nextZ;
    var changed = viewMetricsChanged || next.length != state.placements.length;

    for (final window in userWindows) {
      final existing = next[window.objectId];
      if (existing == null) {
        final nativeGeometry = window.geometry;
        if (nativeGeometry == null) {
          continue;
        }
        next[window.objectId] = DesktopWindowPlacement(
          objectId: window.objectId,
          frame: _initialFrame(
            nativeGeometry,
            serverSideDecorated: window.serverSideDecorated,
          ),
          z: nextZ++,
          monitorId: window.monitorId,
          serverSideDecorated: window.serverSideDecorated,
        );
        _nativeSequences[window.objectId] = snapshotSequence;
        changed = true;
        continue;
      }

      var current = existing;
      final nativeGeometry = window.geometry;
      if (snapshotSequence > (_nativeSequences[window.objectId] ?? 0)) {
        _nativeSequences[window.objectId] = snapshotSequence;
        var frame = existing.frame;
        var fullscreenRestoreFrame = existing.fullscreenRestoreFrame;
        var monitorId = existing.monitorId;
        final decorationChanged =
            existing.serverSideDecorated != window.serverSideDecorated;
        // Rust owns geometry throughout a native grab. A presentation or
        // metadata snapshot (for example, an animating title) can carry the
        // latest native rectangle before Flutter receives the matching
        // placement packet. Rebasing the workspace here would combine that
        // rectangle with the retained live-move delta and visibly apply the
        // motion twice. Placement packets remain the only geometry authority
        // until their end phase commits the final frame.
        if (!existing.dragging && nativeGeometry != null) {
          final nativeFrame = existing.fullscreen
              ? nativeGeometry.intersect(Offset.zero & viewSize)
              : _initialFrame(
                  nativeGeometry,
                  serverSideDecorated: window.serverSideDecorated,
                );
          final pendingFrame = _pendingNativeFrames[window.objectId];
          final nativeAcknowledgedPending =
              pendingFrame != null &&
              _framesApproximatelyEqual(nativeFrame, pendingFrame);
          if (nativeAcknowledgedPending) {
            _pendingNativeFrames.remove(window.objectId);
          }

          // Shell-authored maximize/restore geometry crosses the native bridge
          // asynchronously. A newer texture or metadata snapshot can still
          // describe the preceding native frame; keep the requested frame and
          // its monitor ownership until Rust echoes the complete rectangle.
          if (pendingFrame == null || nativeAcknowledgedPending) {
            if (!nativeFrame.isEmpty) {
              if (existing.fullscreen &&
                  window.monitorId != existing.monitorId) {
                final delta = nativeFrame.topLeft - existing.frame.topLeft;
                fullscreenRestoreFrame = fullscreenRestoreFrame?.shift(delta);
              }
              frame = nativeFrame;
              monitorId = window.monitorId;
            }
          }
        } else if (!existing.dragging &&
            decorationChanged &&
            !existing.fullscreen) {
          frame = _initialFrame(
            existing.contentRect,
            serverSideDecorated: window.serverSideDecorated,
          );
          monitorId = window.monitorId;
        } else if (!existing.dragging &&
            _pendingNativeFrames[window.objectId] == null) {
          monitorId = window.monitorId;
        }
        current = existing.copyWith(
          frame: frame,
          monitorId: monitorId,
          serverSideDecorated: window.serverSideDecorated,
          fullscreenRestoreFrame: fullscreenRestoreFrame,
        );
        if (current.frame != existing.frame ||
            current.monitorId != existing.monitorId ||
            current.serverSideDecorated != existing.serverSideDecorated ||
            current.fullscreenRestoreFrame != existing.fullscreenRestoreFrame) {
          next[window.objectId] = current;
          changed = true;
        }
      }

      if (!viewMetricsChanged) {
        continue;
      }

      final frame = current.fullscreen
          ? _clampFrame(current.frame, viewSize)
          : current.maximized
          ? _maximizedFrame(current.monitorId, viewSize)
          : _clampFrame(current.frame, viewSize);
      if (frame != current.frame) {
        _pendingNativeFrames[window.objectId] = frame;
        next[window.objectId] = current.copyWith(frame: frame);
        changed = true;
      }
    }

    var nextOverview = state.overview;
    if (nextOverview != null && changed) {
      if (state.viewSize != Size.zero && state.viewSize != viewSize) {
        nextOverview = null;
      } else {
        final overviewItems = <DesktopOverviewItem>[
          for (final placement in next.values)
            if (nextOverview.contains(placement.objectId))
              DesktopOverviewItem(
                objectId: placement.objectId,
                frame: placement.frame,
                z: placement.z,
              ),
        ];
        final frames = Map<int, Rect>.of(
          DesktopOverviewLayout.arrange(
            items: overviewItems,
            bounds: nextOverview.bounds,
          ),
        );
        for (final placement in next.values) {
          if (placement.dragging &&
              frames.containsKey(placement.objectId) &&
              nextOverview.frames.containsKey(placement.objectId)) {
            frames[placement.objectId] =
                nextOverview.frames[placement.objectId]!;
          }
        }
        if (frames.isEmpty) {
          nextOverview = null;
        } else {
          nextOverview = DesktopOverviewState(
            monitorId: nextOverview.monitorId,
            bounds: nextOverview.bounds,
            backgroundBounds: nextOverview.backgroundBounds,
            frames: frames,
          );
        }
      }
    }

    if (!changed) {
      return;
    }
    if (state.overview != null && nextOverview == null) {
      for (final entry in next.entries.toList(growable: false)) {
        if (entry.value.dragging) {
          next[entry.key] = entry.value.copyWith(
            z: _overviewDragOrigins[entry.key]?.z,
            dragging: false,
          );
        }
      }
      _overviewDragOrigins.clear();
    }
    state = state.copyWith(
      placements: next,
      nextZ: nextZ,
      viewSize: viewSize,
      overview: nextOverview,
      clearOverview: nextOverview == null,
    );
  }

  void activate(int objectId) {
    final placement = state.placements[objectId];
    if (placement == null) {
      return;
    }
    final topVisibleZ = state.placements.values
        .where((candidate) => !candidate.minimized)
        .fold<int>(0, (top, candidate) => math.max(top, candidate.z));
    if (!state.overviewActive &&
        !placement.minimized &&
        placement.z == topVisibleZ) {
      return;
    }
    final next = Map<int, DesktopWindowPlacement>.of(state.placements);
    next[objectId] = placement.copyWith(z: state.nextZ, minimized: false);
    state = state.copyWith(
      placements: next,
      nextZ: state.nextZ + 1,
      clearOverview: state.overviewActive,
    );
  }

  void toggleOverview({
    required int monitorId,
    required Rect bounds,
    required Rect backgroundBounds,
    Set<int>? objectIds,
  }) {
    if (state.overviewActive) {
      closeOverview();
      return;
    }
    if (bounds.width <= 0.0 || bounds.height <= 0.0) {
      return;
    }

    _moveRemainders.clear();
    _overviewDragOrigins.clear();
    final settledPlacements = <int, DesktopWindowPlacement>{
      for (final placement in state.placements.values)
        placement.objectId: placement.dragging
            ? placement.copyWith(dragging: false)
            : placement,
    };
    final items = <DesktopOverviewItem>[
      for (final placement in settledPlacements.values)
        if ((objectIds?.contains(placement.objectId) ?? false) ||
            (objectIds == null && bounds.contains(placement.frame.center)))
          DesktopOverviewItem(
            objectId: placement.objectId,
            frame: placement.frame,
            z: placement.z,
          ),
    ];
    final frames = DesktopOverviewLayout.arrange(items: items, bounds: bounds);
    if (frames.isEmpty) {
      return;
    }

    state = state.copyWith(
      placements: settledPlacements,
      panel: DesktopPanel.none,
      overview: DesktopOverviewState(
        monitorId: monitorId,
        bounds: bounds,
        backgroundBounds: backgroundBounds,
        frames: frames,
      ),
    );
  }

  void closeOverview() {
    if (!state.overviewActive) {
      return;
    }
    final next = <int, DesktopWindowPlacement>{
      for (final placement in state.placements.values)
        placement.objectId: placement.dragging
            ? placement.copyWith(
                z: _overviewDragOrigins[placement.objectId]?.z,
                dragging: false,
              )
            : placement,
    };
    _overviewDragOrigins.clear();
    state = state.copyWith(placements: next, clearOverview: true);
  }

  void beginOverviewDrag(int objectId) {
    final overview = state.overview;
    final placement = state.placements[objectId];
    final previewFrame = overview?.frames[objectId];
    if (overview == null ||
        placement == null ||
        previewFrame == null ||
        placement.dragging) {
      return;
    }
    _overviewDragOrigins[objectId] = (frame: previewFrame, z: placement.z);
    final next = Map<int, DesktopWindowPlacement>.of(state.placements);
    next[objectId] = placement.copyWith(z: state.nextZ, dragging: true);
    state = state.copyWith(placements: next, nextZ: state.nextZ + 1);
  }

  void moveOverviewBy(int objectId, Offset delta) {
    final overview = state.overview;
    final placement = state.placements[objectId];
    final previewFrame = overview?.frames[objectId];
    if (overview == null ||
        placement == null ||
        !placement.dragging ||
        previewFrame == null ||
        delta == Offset.zero) {
      return;
    }
    final frames = Map<int, Rect>.of(overview.frames);
    frames[objectId] = _clampFrame(previewFrame.shift(delta), state.viewSize);
    state = state.copyWith(
      overview: DesktopOverviewState(
        monitorId: overview.monitorId,
        bounds: overview.bounds,
        backgroundBounds: overview.backgroundBounds,
        frames: frames,
      ),
    );
  }

  bool endOverviewDrag(
    int objectId, {
    required Map<int, Rect> outputBounds,
    required Map<int, Rect> workAreas,
  }) {
    final overview = state.overview;
    final placement = state.placements[objectId];
    final previewFrame = overview?.frames[objectId];
    if (overview == null ||
        placement == null ||
        !placement.dragging ||
        previewFrame == null) {
      _overviewDragOrigins.remove(objectId);
      return false;
    }

    int? targetMonitorId;
    for (final entry in outputBounds.entries) {
      if (entry.value.contains(previewFrame.center)) {
        targetMonitorId = entry.key;
        break;
      }
    }
    final targetOutput = outputBounds[targetMonitorId];
    if (targetMonitorId == null ||
        targetMonitorId == placement.monitorId ||
        targetOutput == null ||
        targetOutput.isEmpty) {
      _restoreOverviewDrag(objectId, placement, overview);
      return false;
    }

    final targetWorkArea = workAreas[targetMonitorId] ?? targetOutput;
    final sourceOutput =
        outputBounds[placement.monitorId] ?? overview.backgroundBounds;
    final outputDelta = targetOutput.topLeft - sourceOutput.topLeft;
    Rect? shiftedRestoreFrame(Rect? frame) {
      if (frame == null) {
        return null;
      }
      return _clampFrame(
        frame.shift(outputDelta),
        state.viewSize,
        bounds: targetWorkArea,
      );
    }

    final destinationFrame = placement.fullscreen
        ? targetOutput
        : placement.maximized
        ? targetWorkArea
        : _clampFrame(
            Rect.fromCenter(
              center: previewFrame.center,
              width: placement.frame.width,
              height: placement.frame.height,
            ),
            state.viewSize,
            bounds: targetWorkArea,
          );
    final fullscreenRestoreFrame = placement.fullscreen && placement.maximized
        ? targetWorkArea
        : shiftedRestoreFrame(placement.fullscreenRestoreFrame);
    final next = Map<int, DesktopWindowPlacement>.of(state.placements);
    final transferred = placement.copyWith(
      frame: destinationFrame,
      monitorId: targetMonitorId,
      minimized: false,
      dragging: false,
      restoreFrame: shiftedRestoreFrame(placement.restoreFrame),
      fullscreenRestoreFrame: fullscreenRestoreFrame,
    );
    next[objectId] = transferred;
    _pendingNativeFrames[objectId] = destinationFrame;
    _overviewDragOrigins.clear();
    state = state.copyWith(placements: next, clearOverview: true);
    return true;
  }

  void cancelOverviewDrag(int objectId) {
    final overview = state.overview;
    final placement = state.placements[objectId];
    if (overview == null || placement == null || !placement.dragging) {
      _overviewDragOrigins.remove(objectId);
      return;
    }
    _restoreOverviewDrag(objectId, placement, overview);
  }

  void _restoreOverviewDrag(
    int objectId,
    DesktopWindowPlacement placement,
    DesktopOverviewState overview,
  ) {
    final frames = Map<int, Rect>.of(overview.frames);
    final origin = _overviewDragOrigins.remove(objectId);
    if (origin != null) {
      frames[objectId] = origin.frame;
    }
    final next = Map<int, DesktopWindowPlacement>.of(state.placements);
    next[objectId] = placement.copyWith(z: origin?.z, dragging: false);
    state = state.copyWith(
      placements: next,
      overview: DesktopOverviewState(
        monitorId: overview.monitorId,
        bounds: overview.bounds,
        backgroundBounds: overview.backgroundBounds,
        frames: frames,
      ),
    );
  }

  void moveBy(int objectId, Offset delta) {
    if (state.overviewActive) {
      return;
    }
    final placement = state.placements[objectId];
    if (placement == null ||
        placement.maximized ||
        placement.fullscreen ||
        placement.minimized) {
      return;
    }

    final pendingDelta = (_moveRemainders[objectId] ?? Offset.zero) + delta;
    final snappedDelta = _snapOffset(pendingDelta);
    if (snappedDelta == Offset.zero) {
      _moveRemainders[objectId] = pendingDelta;
      return;
    }

    final frame = _clampFrame(
      placement.frame.shift(snappedDelta),
      state.viewSize,
    );
    final appliedDelta = frame.topLeft - placement.frame.topLeft;
    var remainder = pendingDelta - appliedDelta;
    if ((appliedDelta.dx - snappedDelta.dx).abs() > 0.000001) {
      remainder = Offset(0.0, remainder.dy);
    }
    if ((appliedDelta.dy - snappedDelta.dy).abs() > 0.000001) {
      remainder = Offset(remainder.dx, 0.0);
    }
    _moveRemainders[objectId] = remainder;

    if (frame == placement.frame) {
      return;
    }
    final next = Map<int, DesktopWindowPlacement>.of(state.placements);
    next[objectId] = placement.copyWith(frame: frame);
    _pendingNativeFrames[objectId] = frame;
    state = state.copyWith(placements: next);
  }

  void beginMove(int objectId) {
    if (state.overviewActive) {
      return;
    }
    final placement = state.placements[objectId];
    if (placement == null ||
        placement.maximized ||
        placement.fullscreen ||
        placement.minimized) {
      return;
    }
    _moveRemainders[objectId] = Offset.zero;
    final next = Map<int, DesktopWindowPlacement>.of(state.placements);
    next[objectId] = placement.copyWith(dragging: true);
    state = state.copyWith(placements: next);
  }

  void endMove(int objectId) {
    if (state.overviewActive) {
      return;
    }
    _moveRemainders.remove(objectId);
    final placement = state.placements[objectId];
    if (placement == null || !placement.dragging) {
      return;
    }
    final next = Map<int, DesktopWindowPlacement>.of(state.placements);
    next[objectId] = placement.copyWith(dragging: false);
    state = state.copyWith(placements: next);
  }

  bool applyNativePlacement(int objectId, DenialWindowPlacementEvent event) {
    if (state.overviewActive) {
      return false;
    }
    if (event.phase == DenialWindowPlacementPhase.begin) {
      activate(objectId);
    }
    final placement = state.placements[objectId];
    if (placement == null ||
        event.sequence <= (_nativeSequences[objectId] ?? 0)) {
      return false;
    }
    _pendingNativeFrames.remove(objectId);

    final monitorChanged = event.monitorId != placement.monitorId;

    if (placement.fullscreen) {
      final transferActive = monitorChanged || placement.dragging;
      if (!transferActive) {
        final next = Map<int, DesktopWindowPlacement>.of(state.placements);
        next[objectId] = placement.copyWith(
          monitorId: event.monitorId,
          workspaceId: event.workspaceId,
        );
        _nativeSequences[objectId] = event.sequence;
        state = state.copyWith(placements: next);
        return true;
      }
      final fullscreenFrame = event.contentRect.intersect(
        Offset.zero & state.viewSize,
      );
      if (fullscreenFrame.isEmpty) {
        return false;
      }
      final delta = fullscreenFrame.topLeft - placement.frame.topLeft;
      final next = Map<int, DesktopWindowPlacement>.of(state.placements);
      next[objectId] = placement.copyWith(
        frame: fullscreenFrame,
        monitorId: event.monitorId,
        workspaceId: event.workspaceId,
        dragging: event.phase != DenialWindowPlacementPhase.end,
        fullscreenRestoreFrame: monitorChanged
            ? placement.fullscreenRestoreFrame?.shift(delta)
            : placement.fullscreenRestoreFrame,
      );
      _nativeSequences[objectId] = event.sequence;
      state = state.copyWith(placements: next);
      return true;
    }

    // This is compositor-owned geometry. Mirror it exactly, including
    // intentional off-screen popup animation, rather than applying another
    // Flutter-side placement policy.
    final frame = _initialFrame(
      event.contentRect,
      serverSideDecorated: placement.serverSideDecorated,
    );
    final next = Map<int, DesktopWindowPlacement>.of(state.placements);
    next[objectId] = placement.copyWith(
      frame: frame,
      monitorId: event.monitorId,
      workspaceId: event.workspaceId,
      minimized: false,
      maximized: false,
      fullscreen: false,
      dragging: event.phase != DenialWindowPlacementPhase.end,
      clearRestoreFrame: true,
      clearFullscreenRestoreFrame: true,
    );
    _nativeSequences[objectId] = event.sequence;
    state = state.copyWith(placements: next);
    return true;
  }

  void minimize(int objectId) {
    if (state.overviewActive) {
      return;
    }
    final placement = state.placements[objectId];
    if (placement == null || placement.minimized) {
      return;
    }
    final next = Map<int, DesktopWindowPlacement>.of(state.placements);
    next[objectId] = placement.copyWith(minimized: true, dragging: false);
    state = state.copyWith(
      placements: next,
      clearOverview: state.overviewActive,
    );
  }

  void maximize(int objectId, {Rect? bounds}) {
    if (state.overviewActive) {
      return;
    }
    final placement = state.placements[objectId];
    if (placement == null || placement.maximized || placement.fullscreen) {
      return;
    }
    toggleMaximized(objectId, bounds: bounds);
  }

  void restore(int objectId) {
    if (state.overviewActive) {
      return;
    }
    final placement = state.placements[objectId];
    if (placement == null) {
      return;
    }
    if (placement.minimized) {
      activate(objectId);
    } else if (placement.fullscreen) {
      _exitFullscreen(objectId, placement);
    } else if (placement.maximized) {
      toggleMaximized(objectId);
    }
  }

  void toggleMinimized(int objectId) {
    if (state.overviewActive) {
      return;
    }
    final placement = state.placements[objectId];
    if (placement == null) {
      return;
    }
    final next = Map<int, DesktopWindowPlacement>.of(state.placements);
    next[objectId] = placement.copyWith(minimized: !placement.minimized);
    state = state.copyWith(
      placements: next,
      clearOverview: state.overviewActive,
    );
  }

  void toggleMaximized(int objectId, {Rect? bounds}) {
    if (state.overviewActive) {
      return;
    }
    final placement = state.placements[objectId];
    if (placement == null || placement.fullscreen) {
      return;
    }
    _moveRemainders.remove(objectId);
    final next = Map<int, DesktopWindowPlacement>.of(state.placements);
    if (placement.maximized) {
      final restored = placement.copyWith(
        frame: _clampFrame(
          placement.restoreFrame ?? placement.frame,
          state.viewSize,
        ),
        maximized: false,
        dragging: false,
        clearRestoreFrame: true,
      );
      next[objectId] = restored;
      _pendingNativeFrames[objectId] = restored.frame;
    } else {
      final canvas = Offset.zero & state.viewSize;
      final requestedBounds = bounds?.intersect(canvas);
      final maximizedFrame = requestedBounds == null || requestedBounds.isEmpty
          ? _maximizedFrame(placement.monitorId, state.viewSize)
          : requestedBounds;
      final maximized = placement.copyWith(
        frame: maximizedFrame,
        maximized: true,
        minimized: false,
        dragging: false,
        restoreFrame: placement.frame,
      );
      next[objectId] = maximized;
      _pendingNativeFrames[objectId] = maximized.frame;
    }
    state = state.copyWith(
      placements: next,
      clearOverview: state.overviewActive,
    );
  }

  void toggleFullscreen(int objectId, {required Rect bounds}) {
    if (state.overviewActive) {
      return;
    }
    final placement = state.placements[objectId];
    if (placement == null) {
      return;
    }
    if (placement.fullscreen) {
      _exitFullscreen(objectId, placement);
      return;
    }

    final fullscreenFrame = bounds.intersect(Offset.zero & state.viewSize);
    if (fullscreenFrame.isEmpty) {
      return;
    }

    _moveRemainders.remove(objectId);
    final next = Map<int, DesktopWindowPlacement>.of(state.placements);
    final fullscreen = placement.copyWith(
      frame: fullscreenFrame,
      minimized: false,
      fullscreen: true,
      dragging: false,
      fullscreenRestoreFrame: placement.frame,
    );
    next[objectId] = fullscreen;
    _pendingNativeFrames[objectId] = fullscreen.frame;
    state = state.copyWith(
      placements: next,
      clearOverview: state.overviewActive,
    );
  }

  void _exitFullscreen(int objectId, DesktopWindowPlacement placement) {
    _moveRemainders.remove(objectId);
    final next = Map<int, DesktopWindowPlacement>.of(state.placements);
    final restored = placement.copyWith(
      frame: _clampFrame(
        placement.fullscreenRestoreFrame ?? placement.frame,
        state.viewSize,
      ),
      fullscreen: false,
      dragging: false,
      clearFullscreenRestoreFrame: true,
    );
    next[objectId] = restored;
    _pendingNativeFrames[objectId] = restored.frame;
    state = state.copyWith(placements: next);
  }

  void showPanel(DesktopPanel panel) {
    if (state.overviewActive || state.panel == panel) {
      return;
    }
    state = state.copyWith(panel: panel, clearOverview: state.overviewActive);
  }

  void closePanels() {
    showPanel(DesktopPanel.none);
  }

  Rect _initialFrame(Rect contentRect, {required bool serverSideDecorated}) {
    if (!serverSideDecorated) {
      return contentRect;
    }
    return Rect.fromLTRB(
      contentRect.left - DesktopMetrics.frameBorder,
      contentRect.top - DesktopMetrics.frameBorder,
      contentRect.right + DesktopMetrics.frameBorder,
      contentRect.bottom + DesktopMetrics.frameBorder,
    );
  }

  Rect _clampFrame(Rect frame, Size viewSize, {Rect? bounds}) {
    final canvas = Offset.zero & viewSize;
    final requestedBounds = bounds?.intersect(canvas);
    final workArea = requestedBounds == null || requestedBounds.isEmpty
        ? DesktopMetrics.windowWorkArea(viewSize)
        : requestedBounds;
    final workLeft = _snapToPixel(workArea.left);
    final workTop = _snapToPixel(workArea.top);
    final workRight = _snapToPixel(workArea.right);
    final workBottom = _snapToPixel(workArea.bottom);
    final width = _snapToPixel(math.min(frame.width, workRight - workLeft));
    final height = _snapToPixel(math.min(frame.height, workBottom - workTop));
    final left = _snapToPixel(
      frame.left,
    ).clamp(workLeft, math.max(workLeft, workRight - width)).toDouble();
    final top = _snapToPixel(
      frame.top,
    ).clamp(workTop, math.max(workTop, workBottom - height)).toDouble();
    return Rect.fromLTWH(left, top, width, height);
  }

  Offset _snapOffset(Offset offset) {
    return Offset(_snapToPixel(offset.dx), _snapToPixel(offset.dy));
  }

  double _snapToPixel(double value) {
    return (value * _devicePixelRatio).roundToDouble() / _devicePixelRatio;
  }
}

bool _framesApproximatelyEqual(Rect first, Rect second) {
  const tolerance = 1.0;
  return (first.left - second.left).abs() <= tolerance &&
      (first.top - second.top).abs() <= tolerance &&
      (first.width - second.width).abs() <= tolerance &&
      (first.height - second.height).abs() <= tolerance;
}
