import 'dart:math' as math;

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/display_layout.dart';
import '../models/denial_window.dart';
import '../models/denial_window_event.dart';
import '../models/shell_popup_placement.dart';
import 'desktop_overview_layout.dart';

part 'desktop_workspace_controller.dart';

abstract final class DesktopMetrics {
  static const double frameBorder = 1.0;
  static const double panelGap = 12.0;
  static const double panelMargin = 14.0;
  // Meet the panel at its resting edge so crossing from trigger to surface
  // never traverses a compositor-owned input gap.
  static const double edgeTriggerWidth = panelMargin;

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
    return _edgeTriggerRect(viewSize, outputRect, placement);
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
    return _edgeTriggerRect(viewSize, outputRect, placement);
  }

  static Rect _edgeTriggerRect(
    Size viewSize,
    Rect? outputRect,
    ShellPopupPlacement placement,
  ) {
    final outputBounds = _outputBounds(viewSize, outputRect);
    final panelBounds = placement.resolve(outputBounds);
    final extent = placement.anchor.horizontal != 0
        ? panelBounds.height
        : panelBounds.width;
    return placement.edgeTrigger(
      outputBounds,
      thickness: _edgeTriggerWidthFor(placement),
      extent: extent,
    );
  }

  static double _edgeTriggerWidthFor(ShellPopupPlacement placement) {
    final configuredMargin = placement.margin.isFinite
        ? math.max(0.0, placement.margin)
        : 0.0;
    return math.max(edgeTriggerWidth, configuredMargin);
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

  const DesktopWorkspaceState._({
    required this.placements,
    required this.nextZ,
    required this.viewSize,
    required this.panel,
    required this.overview,
    required this.inputLayoutRevision,
  });

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
    return DesktopWorkspaceState._(
      placements: placements == null
          ? this.placements
          : Map.unmodifiable(placements),
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
/// surrounding wallpaper, bars, and every other window is redundant. Panel
/// visibility is consumed by its own overlay and deliberately does not affect
/// the base scene's structure.
bool desktopWorkspaceHasSameSceneStructure(
  DesktopWorkspaceState left,
  DesktopWorkspaceState right,
) {
  if (identical(left, right)) {
    return true;
  }
  if (left.nextZ != right.nextZ ||
      left.viewSize != right.viewSize ||
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
