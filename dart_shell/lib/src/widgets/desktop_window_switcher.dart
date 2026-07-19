import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../desktop/desktop_workspace.dart';
import '../input/shell_interaction_registry.dart';
import '../models/denial_window.dart';
import '../state/desktop_window_switcher.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';

/// Geometry and stacking for SUPER+TAB's existing desktop window widgets.
///
/// This deliberately does not build window textures. The desktop scene keeps
/// ownership of the single live desktop frame for every window and feeds the
/// frame returned here to that widget, exactly as it does for SUPER+A.
abstract final class DesktopWindowSwitcherLayout {
  static bool contains(
    DesktopWindowSwitcherState? switcher,
    int objectId,
  ) {
    return switcher?.objectIds.contains(objectId) ?? false;
  }

  static bool isSelected(
    DesktopWindowSwitcherState? switcher,
    int objectId,
  ) {
    return switcher?.selectedObjectId == objectId;
  }

  static Duration motionDuration(DesktopWindowSwitcherState switcher) {
    return switch (switcher.phase) {
      DesktopWindowSwitcherPhase.pending => Motion.windowSwitcherQuick,
      DesktopWindowSwitcherPhase.expanded => Motion.windowSwitcherCycle,
      DesktopWindowSwitcherPhase.quickExit => Motion.windowSwitcherQuick,
      DesktopWindowSwitcherPhase.expandedExit => Motion.windowSwitcherCollapse,
    };
  }

  static Rect visualFrame({
    required DesktopWindowPlacement placement,
    required DesktopWindowSwitcherState? switcher,
    required Rect stageBounds,
  }) {
    if (switcher == null ||
        !contains(switcher, placement.objectId) ||
        stageBounds.isEmpty) {
      return placement.frame;
    }

    return switch (switcher.phase) {
      DesktopWindowSwitcherPhase.pending => _pendingFrame(
          placement: placement,
          switcher: switcher,
          stageBounds: stageBounds,
        ),
      DesktopWindowSwitcherPhase.expanded => _expandedFrame(
          placement: placement,
          switcher: switcher,
          stageBounds: stageBounds,
        ),
      DesktopWindowSwitcherPhase.quickExit ||
      DesktopWindowSwitcherPhase.expandedExit =>
        placement.frame,
    };
  }

  /// Minimized candidates become live only while they participate in the
  /// switch. Everyone else retains the compositor's real minimized state.
  static bool isVisible({
    required DesktopWindowPlacement placement,
    required DesktopWindowSwitcherState? switcher,
  }) {
    if (switcher == null || !contains(switcher, placement.objectId)) {
      return !placement.minimized;
    }

    return switch (switcher.phase) {
      DesktopWindowSwitcherPhase.pending =>
        placement.objectId == switcher.sourceObjectId ||
            placement.objectId == switcher.selectedObjectId ||
            !placement.minimized,
      DesktopWindowSwitcherPhase.expanded => true,
      DesktopWindowSwitcherPhase.quickExit ||
      DesktopWindowSwitcherPhase.expandedExit =>
        placement.objectId == switcher.selectedObjectId || !placement.minimized,
    };
  }

  /// Orders the same canonical desktop children from back to front.
  static int compare(
    DesktopWindowPlacement left,
    DesktopWindowPlacement right,
    Map<int, DenialWindow> windowsById,
    DesktopWindowSwitcherState? switcher,
  ) {
    final desktopOrder = compareDesktopWindowStack(left, right, windowsById);
    if (switcher == null) {
      return desktopOrder;
    }

    final leftIndex = switcher.objectIds.indexOf(left.objectId);
    final rightIndex = switcher.objectIds.indexOf(right.objectId);
    final leftParticipates = leftIndex >= 0;
    final rightParticipates = rightIndex >= 0;
    if (leftParticipates != rightParticipates) {
      return leftParticipates ? 1 : -1;
    }
    if (!leftParticipates) {
      return desktopOrder;
    }

    switch (switcher.phase) {
      case DesktopWindowSwitcherPhase.pending:
        final leftRank = _pendingStackRank(left.objectId, switcher);
        final rightRank = _pendingStackRank(right.objectId, switcher);
        final rankOrder = leftRank.compareTo(rightRank);
        return rankOrder != 0 ? rankOrder : desktopOrder;
      case DesktopWindowSwitcherPhase.expanded:
        final leftDistance = _signedDistance(
          index: leftIndex,
          selectedIndex: switcher.selectedIndex,
          length: switcher.objectIds.length,
        ).abs();
        final rightDistance = _signedDistance(
          index: rightIndex,
          selectedIndex: switcher.selectedIndex,
          length: switcher.objectIds.length,
        ).abs();
        final distanceOrder = rightDistance.compareTo(leftDistance);
        return distanceOrder != 0 ? distanceOrder : desktopOrder;
      case DesktopWindowSwitcherPhase.quickExit:
      case DesktopWindowSwitcherPhase.expandedExit:
        final leftSelected = left.objectId == switcher.selectedObjectId;
        final rightSelected = right.objectId == switcher.selectedObjectId;
        if (leftSelected != rightSelected) {
          return leftSelected ? 1 : -1;
        }
        return desktopOrder;
    }
  }

  static Rect _pendingFrame({
    required DesktopWindowPlacement placement,
    required DesktopWindowSwitcherState switcher,
    required Rect stageBounds,
  }) {
    final objectId = placement.objectId;
    if (objectId == switcher.selectedObjectId) {
      return _scaleAndShift(
        placement.frame,
        scale: 0.92,
        dx: stageBounds.width * 0.035,
      );
    }
    if (objectId == switcher.sourceObjectId) {
      return _scaleAndShift(
        placement.frame,
        scale: 0.88,
        dx: -stageBounds.width * 0.055,
      );
    }
    return placement.frame;
  }

  static Rect _expandedFrame({
    required DesktopWindowPlacement placement,
    required DesktopWindowSwitcherState switcher,
    required Rect stageBounds,
  }) {
    final source = placement.frame;
    if (source.isEmpty) {
      return source;
    }

    final padding = math.min(
      28.0,
      math.min(stageBounds.width, stageBounds.height) * 0.045,
    );
    final available = stageBounds.deflate(padding);
    if (available.isEmpty) {
      return source;
    }

    final index = switcher.objectIds.indexOf(placement.objectId);
    final distance = _signedDistance(
      index: index,
      selectedIndex: switcher.selectedIndex,
      length: switcher.objectIds.length,
    );
    final verySmall = source.width * source.height < 130000.0 ||
        math.min(source.width, source.height) < 180.0;

    if (distance == 0) {
      return _fitAt(
        source,
        center: Offset(
          available.center.dx,
          available.top + available.height * 0.45,
        ),
        maximumWidth: available.width * 0.48,
        maximumHeight: available.height * 0.70,
        maximumScale: verySmall ? 1.0 : 1.45,
      );
    }

    final sameSideDistances = <int>[
      for (var candidateIndex = 0;
          candidateIndex < switcher.objectIds.length;
          candidateIndex += 1)
        _signedDistance(
          index: candidateIndex,
          selectedIndex: switcher.selectedIndex,
          length: switcher.objectIds.length,
        ),
    ]
      ..removeWhere(
        (candidateDistance) =>
            candidateDistance == 0 ||
            candidateDistance.isNegative != distance.isNegative,
      )
      ..sort((left, right) => left.abs().compareTo(right.abs()));
    final railIndex = sameSideDistances.indexOf(distance);
    final railCount = math.max(1, sameSideDistances.length);
    final railSpacing = available.height *
        (railCount <= 2 ? 0.36 : 0.82 / railCount.toDouble());
    final railOffset = _centeredRailOffset(railIndex, railCount);
    final railCenter = Offset(
      distance.isNegative
          ? available.left + available.width * 0.125
          : available.right - available.width * 0.125,
      available.center.dy + railOffset * railSpacing,
    );

    return _fitAt(
      source,
      center: railCenter,
      maximumWidth: available.width * 0.22,
      maximumHeight:
          railCount == 1 ? available.height * 0.48 : railSpacing * 0.82,
      maximumScale: verySmall ? 1.0 : 1.15,
    );
  }

  static int _pendingStackRank(
    int objectId,
    DesktopWindowSwitcherState switcher,
  ) {
    if (objectId == switcher.sourceObjectId) {
      return 3;
    }
    if (objectId == switcher.selectedObjectId) {
      return 2;
    }
    return 1;
  }

  static int _signedDistance({
    required int index,
    required int selectedIndex,
    required int length,
  }) {
    var distance = index - selectedIndex;
    final half = length / 2.0;
    if (distance > half) {
      distance -= length;
    } else if (distance < -half) {
      distance += length;
    }
    return distance;
  }

  static double _centeredRailOffset(int index, int count) {
    if (count.isOdd) {
      if (index == 0) {
        return 0.0;
      }
      final magnitude = (index + 1) ~/ 2;
      return index.isOdd ? -magnitude.toDouble() : magnitude.toDouble();
    }
    final magnitude = index ~/ 2 + 0.5;
    return index.isEven ? -magnitude : magnitude;
  }

  static Rect _fitAt(
    Rect source, {
    required Offset center,
    required double maximumWidth,
    required double maximumHeight,
    required double maximumScale,
  }) {
    final availableScale = math.min(
      maximumWidth / source.width,
      maximumHeight / source.height,
    );
    final scale = math.min(maximumScale, availableScale);
    if (!scale.isFinite || scale <= 0.0) {
      return source;
    }
    return Rect.fromCenter(
      center: center,
      width: source.width * scale,
      height: source.height * scale,
    );
  }

  static Rect _scaleAndShift(
    Rect source, {
    required double scale,
    required double dx,
  }) {
    return Rect.fromCenter(
      center: source.center + Offset(dx, 0.0),
      width: source.width * scale,
      height: source.height * scale,
    );
  }
}

/// The only visual behind the live managed windows in the held view.
class DesktopWindowSwitcherBackdrop extends StatelessWidget {
  const DesktopWindowSwitcherBackdrop({
    required this.switcher,
    required this.bounds,
    super.key,
  });

  final DesktopWindowSwitcherState switcher;
  final Rect bounds;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final expanded = switcher.phase == DesktopWindowSwitcherPhase.expanded;
    return Positioned.fromRect(
      rect: bounds,
      child: IgnorePointer(
        child: AnimatedContainer(
          duration: reduceMotion
              ? Duration.zero
              : expanded
                  ? Motion.windowSwitcherExpand
                  : Motion.windowSwitcherCollapse,
          curve: Motion.md3Emphasized,
          color: expanded
              ? ShellColors.background.withValues(alpha: 0.72)
              : ShellColors.background.withValues(alpha: 0.0),
        ),
      ),
    );
  }
}

/// Input capture and restrained chrome only. Window surfaces stay in the
/// desktop scene and are never recreated here.
class DesktopWindowSwitcherLayer extends StatelessWidget {
  const DesktopWindowSwitcherLayer({
    required this.switcher,
    required this.selectedWindow,
    required this.stageBounds,
    super.key,
  });

  final DesktopWindowSwitcherState switcher;
  final DenialWindow? selectedWindow;
  final Rect stageBounds;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final expanded = switcher.phase == DesktopWindowSwitcherPhase.expanded;
    final duration = reduceMotion
        ? Duration.zero
        : expanded
            ? Motion.windowSwitcherExpand
            : Motion.windowSwitcherCollapse;
    final labelWidth = math.max(0.0, math.min(520.0, stageBounds.width - 64.0));

    return Positioned.fill(
      child: ShellInputRegion(
        debugLabel: 'Desktop window switcher',
        active: switcher.isSelecting,
        pointerPolicy: ShellPointerPolicy.fullScene,
        keyboardPolicy: ShellKeyboardPolicy.capture,
        compositorPolicy: ShellCompositorPolicy.exclusive,
        child: IgnorePointer(
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (!stageBounds.isEmpty && labelWidth > 0.0)
                Positioned.fromRect(
                  rect: stageBounds,
                  child: ClipRect(
                    child: Stack(
                      children: [
                        AnimatedPositioned(
                          duration: duration,
                          curve: Motion.md3Emphasized,
                          left: (stageBounds.width - labelWidth) / 2.0,
                          bottom: expanded ? 24.0 : -52.0,
                          width: labelWidth,
                          height: 40.0,
                          child: ExcludeSemantics(
                            excluding: !expanded,
                            child: Semantics(
                              liveRegion: true,
                              label: selectedWindow == null
                                  ? null
                                  : 'Selected ${selectedWindow!.displayTitle}',
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: ShellColors.panelBackground,
                                  borderRadius:
                                      BorderRadius.circular(ShellRadii.chip),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18.0,
                                  ),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        '${switcher.selectedIndex + 1} / '
                                        '${switcher.objectIds.length}',
                                        style: ShellText.cardTitle.copyWith(
                                          color: ShellColors.textSecondary,
                                        ),
                                      ),
                                      const SizedBox(width: 12.0),
                                      Flexible(
                                        child: Text(
                                          selectedWindow?.displayTitle ?? '',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: ShellText.cardTitle,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
