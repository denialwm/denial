import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/settings.dart';

import 'desktop_overview_layout.dart';
import 'desktop_workspace_overview_layout.dart';
import 'transient_family_order.dart';

part 'desktop_workspace_controller.dart';

/// A screen-edge strip a finger swipes in from, and the edge it starts at.
typedef DesktopPanelSwipe = ({Rect rect, InputEdge edge});

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

  /// Width of the strip a finger swipes in from to open a panel.
  static const double panelSwipeWidth = 24.0;

  /// The strips a finger swipes in from to open the launcher and the
  /// dashboard. Touch has no hover, so this is its way in. When both panels
  /// would open from the same place, the launcher keeps it.
  static ({DesktopPanelSwipe? launcher, DesktopPanelSwipe? dashboard})
  panelSwipes(
    Size viewSize, {
    Rect? outputRect,
    required ShellOverlaySettings overlays,
    required bool hasLauncher,
  }) {
    final launcher = hasLauncher
        ? panelSwipeEdge(
            viewSize,
            outputRect: outputRect,
            placement: overlays.launcher,
          )
        : null;
    final dashboard = panelSwipeEdge(
      viewSize,
      outputRect: outputRect,
      placement: overlays.dashboard,
    );
    final shared =
        launcher != null &&
        dashboard != null &&
        launcher.edge == dashboard.edge &&
        launcher.rect.overlaps(dashboard.rect);
    return (launcher: launcher, dashboard: shared ? null : dashboard);
  }

  /// Where a finger swipes in to open a panel: along the edge the panel
  /// opens from, beside it, or along the bottom under it when it is
  /// centered.
  static DesktopPanelSwipe? panelSwipeEdge(
    Size viewSize, {
    Rect? outputRect,
    required ShellPopupPlacement placement,
  }) {
    final bounds = _outputBounds(viewSize, outputRect);
    if (bounds.isEmpty) {
      return null;
    }
    final panel = placement.resolve(bounds);
    final anchor = placement.anchor;
    final width = math.min(panelSwipeWidth, bounds.shortestSide);
    final DesktopPanelSwipe swipe;
    if (anchor.horizontal < 0) {
      swipe = (
        rect: Rect.fromLTRB(
          bounds.left,
          panel.top,
          bounds.left + width,
          panel.bottom,
        ),
        edge: InputEdge.left,
      );
    } else if (anchor.horizontal > 0) {
      swipe = (
        rect: Rect.fromLTRB(
          bounds.right - width,
          panel.top,
          bounds.right,
          panel.bottom,
        ),
        edge: InputEdge.right,
      );
    } else if (anchor.vertical < 0) {
      swipe = (
        rect: Rect.fromLTRB(
          panel.left,
          bounds.top,
          panel.right,
          bounds.top + width,
        ),
        edge: InputEdge.top,
      );
    } else {
      swipe = (
        rect: Rect.fromLTRB(
          panel.left,
          bounds.bottom - width,
          panel.right,
          bounds.bottom,
        ),
        edge: InputEdge.bottom,
      );
    }
    final rect = swipe.rect.intersect(bounds);
    return rect.isEmpty ? null : (rect: rect, edge: swipe.edge);
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

/// Clips a window to its owning output viewport.
///
/// This clip is invariant across overview, switcher, workspace, minimize, and
/// pinned-window presentation. Only an actively dragged window may cross its
/// owning output while the drag is in progress.
Rect? desktopOutputClip({
  required bool activelyDragging,
  required Rect? outputRect,
}) => activelyDragging ? null : outputRect;

enum DesktopPanel { none, launcher, dashboard }

/// The per-workspace miniature presentation used by managed layouts.
///
/// Stacking keeps the free-form spread in [DesktopOverviewState.frames].
/// Dwindle and scrolling instead present every workspace of the overview's
/// monitor as a true-to-layout card, so these fields retain the inputs needed
/// to re-arrange them as windows open, close, and move.
@immutable
class DesktopWorkspaceOverview {
  DesktopWorkspaceOverview({
    required this.viewport,
    required this.orientation,
    required List<DesktopWorkspaceOverviewCard> cards,
    required this.shelf,
    this.dropSlot,
  }) : cards = List.unmodifiable(cards);

  /// The output work area the cards miniaturize, in scene coordinates.
  final Rect viewport;
  final WorkspaceSwitchingOrientation orientation;
  final List<DesktopWorkspaceOverviewCard> cards;

  /// Background of the minimized-window shelf, or [Rect.zero] when empty.
  final Rect shelf;

  /// Where the dragged window will land, as planned by the compositor's
  /// layout for the card under it.
  final Rect? dropSlot;

  DesktopWorkspaceOverviewCard? cardFor(int workspaceId) {
    for (final card in cards) {
      if (card.workspaceId == workspaceId) {
        return card;
      }
    }
    return null;
  }

  DesktopWorkspaceOverviewCard? cardAt(Offset position) {
    for (final card in cards) {
      if (card.rect.contains(position)) {
        return card;
      }
    }
    return null;
  }

  /// Maps an overview rectangle to the scene as if [workspaceId]'s card were
  /// zoomed back to fill its output. Its windows return to their real frames,
  /// while every other card lands beside the screen in its grid direction.
  Rect cameraRect(Rect overviewRect, int workspaceId) {
    final camera = cardFor(workspaceId) ?? (cards.isEmpty ? null : cards.first);
    return camera?.unproject(overviewRect) ?? overviewRect;
  }
}

@immutable
class DesktopOverviewState {
  DesktopOverviewState({
    required this.monitorId,
    required this.bounds,
    required this.backgroundBounds,
    required this.selectedObjectId,
    required Map<int, Rect> frames,
    this.workspaces,
  }) : frames = Map.unmodifiable(frames);

  const DesktopOverviewState._({
    required this.monitorId,
    required this.bounds,
    required this.backgroundBounds,
    required this.selectedObjectId,
    required this.frames,
    required this.workspaces,
  });

  final int monitorId;
  final Rect bounds;
  final Rect backgroundBounds;

  /// Null only when a workspace overview has no windows to select.
  final int? selectedObjectId;
  final Map<int, Rect> frames;

  /// Present when the overview shows workspace miniatures instead of the
  /// stacking spread.
  final DesktopWorkspaceOverview? workspaces;

  bool contains(int objectId) => frames.containsKey(objectId);

  DesktopOverviewState copyWith({
    int? selectedObjectId,
    Map<int, Rect>? frames,
  }) {
    return DesktopOverviewState._(
      monitorId: monitorId,
      bounds: bounds,
      backgroundBounds: backgroundBounds,
      selectedObjectId: selectedObjectId ?? this.selectedObjectId,
      frames: frames == null || identical(frames, this.frames)
          ? this.frames
          : Map.unmodifiable(frames),
      workspaces: workspaces,
    );
  }
}

enum DesktopOverviewDirection { left, right, up, down }

/// Finds the next overview preview in [direction] using the arranged geometry.
///
/// Left and right step through the previews in reading order: along a row,
/// from the end of one row to the start of the next, and around from the last
/// preview to the first. Up and down move to the nearest preview in that
/// direction, preferring one in the same visual column, and stop at the edge.
int? desktopOverviewNeighbor({
  required Map<int, Rect> frames,
  required int fromObjectId,
  required DesktopOverviewDirection direction,
}) {
  final source = frames[fromObjectId];
  if (source == null) {
    return null;
  }
  if (direction == DesktopOverviewDirection.left ||
      direction == DesktopOverviewDirection.right) {
    final order = desktopOverviewReadingOrder(frames);
    if (order.length < 2) {
      return null;
    }
    final index = order.indexOf(fromObjectId);
    final step = direction == DesktopOverviewDirection.right ? 1 : -1;
    return order[(index + step) % order.length];
  }

  int? bestObjectId;
  double? bestPerpendicularGap;
  double? bestPrimaryDistance;
  double? bestPerpendicularDistance;
  for (final entry in frames.entries) {
    if (entry.key == fromObjectId) {
      continue;
    }
    final candidate = entry.value;
    final (
      primaryDistance,
      perpendicularDistance,
      perpendicularGap,
    ) = switch (direction) {
      DesktopOverviewDirection.left => (
        source.center.dx - candidate.center.dx,
        (source.center.dy - candidate.center.dy).abs(),
        _separation(source.top, source.bottom, candidate.top, candidate.bottom),
      ),
      DesktopOverviewDirection.right => (
        candidate.center.dx - source.center.dx,
        (source.center.dy - candidate.center.dy).abs(),
        _separation(source.top, source.bottom, candidate.top, candidate.bottom),
      ),
      DesktopOverviewDirection.up => (
        source.center.dy - candidate.center.dy,
        (source.center.dx - candidate.center.dx).abs(),
        _separation(source.left, source.right, candidate.left, candidate.right),
      ),
      DesktopOverviewDirection.down => (
        candidate.center.dy - source.center.dy,
        (source.center.dx - candidate.center.dx).abs(),
        _separation(source.left, source.right, candidate.left, candidate.right),
      ),
    };
    if (primaryDistance <= 0.0) {
      continue;
    }
    final better =
        bestObjectId == null ||
        perpendicularGap < bestPerpendicularGap! ||
        (perpendicularGap == bestPerpendicularGap &&
            (primaryDistance < bestPrimaryDistance! ||
                (primaryDistance == bestPrimaryDistance &&
                    (perpendicularDistance < bestPerpendicularDistance! ||
                        (perpendicularDistance == bestPerpendicularDistance &&
                            entry.key < bestObjectId)))));
    if (better) {
      bestObjectId = entry.key;
      bestPerpendicularGap = perpendicularGap;
      bestPrimaryDistance = primaryDistance;
      bestPerpendicularDistance = perpendicularDistance;
    }
  }
  return bestObjectId;
}

/// The previews in reading order: rows from top to bottom, each from left to
/// right. A preview joins the row above when it overlaps that row vertically.
List<int> desktopOverviewReadingOrder(Map<int, Rect> frames) {
  final byTop = frames.entries.toList()
    ..sort((a, b) {
      final order = a.value.top.compareTo(b.value.top);
      return order != 0 ? order : a.value.left.compareTo(b.value.left);
    });
  final rows = <List<MapEntry<int, Rect>>>[];
  var rowBottom = double.negativeInfinity;
  for (final entry in byTop) {
    if (rows.isEmpty || entry.value.top >= rowBottom) {
      rows.add([entry]);
      rowBottom = entry.value.bottom;
    } else {
      rows.last.add(entry);
      if (entry.value.bottom > rowBottom) rowBottom = entry.value.bottom;
    }
  }
  return [
    for (final row in rows)
      ...(row..sort((a, b) {
            final order = a.value.left.compareTo(b.value.left);
            return order != 0 ? order : a.key.compareTo(b.key);
          }))
          .map((entry) => entry.key),
  ];
}

double _separation(double aStart, double aEnd, double bStart, double bEnd) {
  if (aEnd < bStart) {
    return bStart - aEnd;
  }
  if (bEnd < aStart) {
    return aStart - bEnd;
  }
  return 0.0;
}

@immutable
class DesktopWorkspaceTransition {
  const DesktopWorkspaceTransition({
    required this.monitorId,
    required this.fromWorkspace,
    required this.toWorkspace,
    required this.serial,
    this.retainedExits = const <int, DesktopWorkspaceTransition>{},
  });

  final int monitorId;
  final int fromWorkspace;
  final int toWorkspace;
  final int serial;

  /// Earlier departures still on screen during a burst of workspace changes.
  /// Entries are immutable, flat snapshots, keyed by the departing workspace.
  final Map<int, DesktopWorkspaceTransition> retainedExits;

  DesktopWorkspaceTransition? forWorkspace(int workspaceId) =>
      workspaceId == fromWorkspace || workspaceId == toWorkspace
      ? this
      : retainedExits[workspaceId];

  int get direction => toWorkspace >= fromWorkspace ? 1 : -1;
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
    this.serverFrameWhileMaximized = false,
    this.dragging = false,
    this.resizing = false,
    this.layoutPreviewing = false,
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

  /// Whether the active layout keeps the shell frame around a maximized
  /// window. Managed layouts leave breathing room around their tiles, unlike
  /// stacking-mode maximize and true fullscreen.
  final bool serverFrameWhileMaximized;
  final bool dragging;

  /// Tracks native resize transactions, including tiles sharing a split.
  /// Their geometry follows the pointer without a placement animation.
  final bool resizing;

  /// Whether this window is temporarily displaced by a managed layout drag.
  final bool layoutPreviewing;
  final Rect? restoreFrame;
  final Rect? fullscreenRestoreFrame;

  bool get drawsLiveServerFrame =>
      serverSideDecorated &&
      !fullscreen &&
      (!maximized || serverFrameWhileMaximized);

  double get frameBorder =>
      drawsLiveServerFrame ? DesktopMetrics.frameBorder : 0.0;

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
    bool? serverFrameWhileMaximized,
    bool? dragging,
    bool? resizing,
    bool? layoutPreviewing,
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
      serverFrameWhileMaximized:
          serverFrameWhileMaximized ?? this.serverFrameWhileMaximized,
      dragging: dragging ?? this.dragging,
      resizing: resizing ?? this.resizing,
      layoutPreviewing: layoutPreviewing ?? this.layoutPreviewing,
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
  DesktopWindowPlacement? topmost;
  DenialWindow? hit;
  for (final placement in workspace.placements.values) {
    final window = windowsById[placement.objectId];
    if (placement.minimized ||
        !workspace.isPlacementOnActiveWorkspace(placement) ||
        window == null ||
        (topmost != null &&
            compareDesktopWindowStack(placement, topmost, windowsById) <= 0)) {
      continue;
    }
    if (placement.frame.contains(position) ||
        window.popupRoots.any(
          (popup) => window
              .mapSurfaceRect(popup, placement.contentRect)
              .contains(position),
        )) {
      topmost = placement;
      hit = window;
    }
  }
  return hit;
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
    this.workspacesEnabled = false,
    this.workspaceCount = 4,
    Map<int, int> activeWorkspaces = const <int, int>{},
    Map<int, DesktopWorkspaceTransition> workspaceTransitions =
        const <int, DesktopWorkspaceTransition>{},
  }) : placements = Map.unmodifiable(placements),
       activeWorkspaces = Map.unmodifiable(activeWorkspaces),
       workspaceTransitions = Map.unmodifiable(workspaceTransitions);

  const DesktopWorkspaceState._({
    required this.placements,
    required this.nextZ,
    required this.viewSize,
    required this.panel,
    required this.overview,
    required this.inputLayoutRevision,
    required this.workspacesEnabled,
    required this.workspaceCount,
    required this.activeWorkspaces,
    required this.workspaceTransitions,
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
  final bool workspacesEnabled;
  final int workspaceCount;
  final Map<int, int> activeWorkspaces;
  final Map<int, DesktopWorkspaceTransition> workspaceTransitions;

  bool get launcherOpen => panel == DesktopPanel.launcher;
  bool get dashboardOpen => panel == DesktopPanel.dashboard;
  bool get overviewActive => overview != null;

  int activeWorkspaceFor(int monitorId) =>
      workspacesEnabled ? activeWorkspaces[monitorId] ?? 1 : 1;

  bool isPlacementOnActiveWorkspace(DesktopWindowPlacement placement) {
    return placement.minimized ||
        !workspacesEnabled ||
        placement.workspaceId == activeWorkspaceFor(placement.monitorId);
  }

  bool isPlacementPresented(DesktopWindowPlacement placement) {
    if (isPlacementOnActiveWorkspace(placement) ||
        isInOverview(placement.objectId)) {
      return true;
    }
    final transition = workspaceTransitions[placement.monitorId];
    return transition?.forWorkspace(placement.workspaceId) != null;
  }

  bool isInOverview(int objectId) => overview?.contains(objectId) ?? false;

  Rect visualFrame(DesktopWindowPlacement placement) {
    return overview?.frames[placement.objectId] ?? placement.frame;
  }

  DesktopWorkspaceState _replacePlacement(DesktopWindowPlacement placement) {
    // This map is created here and never exposed mutably. A read-only view
    // avoids copying it again through the public copyWith snapshot boundary.
    final next = Map<int, DesktopWindowPlacement>.of(placements);
    next[placement.objectId] = placement;
    return DesktopWorkspaceState._(
      placements: UnmodifiableMapView(next),
      nextZ: nextZ,
      viewSize: viewSize,
      panel: panel,
      overview: overview,
      inputLayoutRevision: inputLayoutRevision + 1,
      workspacesEnabled: workspacesEnabled,
      workspaceCount: workspaceCount,
      activeWorkspaces: activeWorkspaces,
      workspaceTransitions: workspaceTransitions,
    );
  }

  DesktopWorkspaceState copyWith({
    Map<int, DesktopWindowPlacement>? placements,
    int? nextZ,
    Size? viewSize,
    DesktopPanel? panel,
    DesktopOverviewState? overview,
    bool clearOverview = false,
    bool? workspacesEnabled,
    int? workspaceCount,
    Map<int, int>? activeWorkspaces,
    Map<int, DesktopWorkspaceTransition>? workspaceTransitions,
  }) {
    return DesktopWorkspaceState._(
      placements: placements == null || identical(placements, this.placements)
          ? this.placements
          : Map.unmodifiable(placements),
      nextZ: nextZ ?? this.nextZ,
      viewSize: viewSize ?? this.viewSize,
      panel: panel ?? this.panel,
      overview: clearOverview ? null : overview ?? this.overview,
      inputLayoutRevision:
          inputLayoutRevision +
          ((placements != null ||
                  overview != null ||
                  clearOverview ||
                  activeWorkspaces != null ||
                  workspaceTransitions != null)
              ? 1
              : 0),
      workspacesEnabled: workspacesEnabled ?? this.workspacesEnabled,
      workspaceCount: workspaceCount ?? this.workspaceCount,
      activeWorkspaces:
          activeWorkspaces == null ||
              identical(activeWorkspaces, this.activeWorkspaces)
          ? this.activeWorkspaces
          : Map.unmodifiable(activeWorkspaces),
      workspaceTransitions:
          workspaceTransitions == null ||
              identical(workspaceTransitions, this.workspaceTransitions)
          ? this.workspaceTransitions
          : Map.unmodifiable(workspaceTransitions),
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
      left.workspacesEnabled != right.workspacesEnabled ||
      left.workspaceCount != right.workspaceCount ||
      !mapEquals(left.activeWorkspaces, right.activeWorkspaces) ||
      !mapEquals(left.workspaceTransitions, right.workspaceTransitions) ||
      !identical(left.overview, right.overview) ||
      left.placements.length != right.placements.length) {
    return false;
  }
  if (identical(left.placements, right.placements)) {
    return true;
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
      left.serverFrameWhileMaximized == right.serverFrameWhileMaximized &&
      left.dragging == right.dragging &&
      left.resizing == right.resizing &&
      left.layoutPreviewing == right.layoutPreviewing &&
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
