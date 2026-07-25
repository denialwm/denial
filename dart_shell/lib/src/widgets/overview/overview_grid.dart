import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/widgets.dart';

import '../../models/denial_window.dart';
import '../../theme/motion.dart';
import 'overview_geometry.dart';
import 'overview_window_card.dart';

/// A space-filling landscape overview that keeps every recent app visible.
///
/// The active app always occupies the first, top-left grid slot. Cards fan out
/// from it during the swipe-up transition, while [AnimatedPositioned] gives the
/// remaining cards a soft reflow when a window is dismissed.
class OverviewGrid extends StatelessWidget {
  const OverviewGrid({
    super.key,
    required this.windows,
    required this.progress,
    required this.foregroundObjectId,
    required this.onDismissWindow,
    required this.onFocusWindow,
  });

  final List<DenialWindow> windows;
  final double progress;
  final int? foregroundObjectId;
  final ValueChanged<DenialWindow> onDismissWindow;
  final void Function(DenialWindow window, Rect startRect) onFocusWindow;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewSize = constraints.biggest;
        final layout = landscapeOverviewLayoutFor(
          viewSize: viewSize,
          padding: padding,
          itemCount: windows.length,
          aspect: viewAspectFor(viewSize),
        );
        final sourceForegroundIndex = windows.indexWhere(
          (window) => window.objectId == foregroundObjectId,
        );
        final originRect = sourceForegroundIndex >= 0
            ? layout.previewRectAt(0)
            : Rect.fromCenter(
                center: viewSize.center(Offset.zero),
                width: layout.cardSize.width,
                height: layout.cardSize.height,
              );

        return Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.none,
          children: [
            for (var visualIndex = 0;
                visualIndex < windows.length;
                visualIndex += 1)
              _positionedCard(
                layout: layout,
                originRect: originRect,
                sourceForegroundIndex: sourceForegroundIndex,
                visualIndex: visualIndex,
              ),
          ],
        );
      },
    );
  }

  Widget _positionedCard({
    required LandscapeOverviewLayout layout,
    required Rect originRect,
    required int sourceForegroundIndex,
    required int visualIndex,
  }) {
    final sourceIndex = _sourceIndexForVisualIndex(
      visualIndex,
      sourceForegroundIndex,
    );
    final window = windows[sourceIndex];
    final itemRect = layout.itemRects[visualIndex];
    final previewRect = layout.previewRectAt(visualIndex);

    return AnimatedPositioned(
      key: ValueKey<int>(window.objectId),
      duration: progress >= 0.995 ? Motion.cardSettle : Duration.zero,
      curve: Motion.md3Emphasized,
      left: itemRect.left,
      top: itemRect.top,
      width: itemRect.width,
      height: itemRect.height,
      child: _OverviewGridEntry(
        progress: progress,
        delayRank: math.min(visualIndex, 6),
        originOffset: originRect.center - previewRect.center,
        child: OverviewWindowCard(
          window: window,
          index: visualIndex,
          progress: progress,
          pageOffset: 0.0,
          cardSize: layout.cardSize,
          hidden: foregroundObjectId == window.objectId && progress < 0.995,
          onDismiss: onDismissWindow,
          onFocus: onFocusWindow,
        ),
      ),
    );
  }

  int _sourceIndexForVisualIndex(int visualIndex, int foregroundIndex) {
    if (foregroundIndex <= 0) {
      return visualIndex;
    }
    if (visualIndex == 0) {
      return foregroundIndex;
    }
    if (visualIndex <= foregroundIndex) {
      return visualIndex - 1;
    }
    return visualIndex;
  }
}

class _OverviewGridEntry extends StatelessWidget {
  const _OverviewGridEntry({
    required this.progress,
    required this.delayRank,
    required this.originOffset,
    required this.child,
  });

  final double progress;
  final int delayRank;
  final Offset originOffset;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final delay = 0.06 + delayRank * 0.035;
    final rawEntry = interval(progress, delay, math.min(0.86, delay + 0.68));
    final entry = Motion.md3EmphasizedDecelerate.transform(rawEntry);
    final offset = Offset.lerp(originOffset, Offset.zero, entry)!;
    final scale = lerpDouble(0.76, 1.0, entry)!;

    return Opacity(
      opacity: unit(rawEntry * 1.45),
      child: Transform.translate(
        offset: offset,
        child: Transform.scale(
          scale: scale,
          alignment: Alignment.topCenter,
          child: child,
        ),
      ),
    );
  }
}
