import 'dart:ui';

import 'package:flutter/widgets.dart';

import '../models/denial_window.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import 'window_texture_rect.dart';

/// A window's live texture rendered with rounded corners and an optional
/// hairline border, filling its parent. This is the single building block for
/// every place the shell shows a window outside the primary stage: launch,
/// overview cards, the foreground-to-overview hero and the focus zoom.
class WindowSurface extends StatelessWidget {
  const WindowSurface({
    super.key,
    required this.window,
    this.radius = 0.0,
    this.borderColor,
    this.addRepaintBoundary = true,
  });

  final DenialWindow window;
  final double radius;

  /// When non-null, a 1px hairline is drawn over the texture in this colour.
  final Color? borderColor;
  final bool addRepaintBoundary;

  @override
  Widget build(BuildContext context) {
    final effectiveRadius = window.serverSideDecorated ? radius : 0.0;
    final borderRadius = effectiveRadius <= 0.0
        ? BorderRadius.zero
        : BorderRadius.circular(effectiveRadius);

    Widget content = WindowTextureRect(
      window: window,
      borderRadius: borderRadius,
    );

    final border = window.serverSideDecorated ? borderColor : null;
    if (border != null) {
      content = Stack(
        fit: StackFit.expand,
        children: [
          content,
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              border: Border.all(color: border, width: 1),
            ),
          ),
        ],
      );
    }

    return addRepaintBoundary ? RepaintBoundary(child: content) : content;
  }
}

/// A positioned window surface that interpolates its rect, corner radius and
/// border colour by [progress]. Drop it directly into a [Stack].
class WindowHero extends StatelessWidget {
  const WindowHero({
    super.key,
    required this.window,
    required this.beginRect,
    required this.endRect,
    required this.progress,
    this.beginRadius = 0.0,
    this.endRadius = 0.0,
    this.beginBorder,
    this.endBorder,
    this.curve = Motion.standard,
  });

  final DenialWindow window;
  final Rect beginRect;
  final Rect endRect;
  final double progress;
  final double beginRadius;
  final double endRadius;
  final Color? beginBorder;
  final Color? endBorder;
  final Curve curve;

  @override
  Widget build(BuildContext context) {
    final t = curve.transform(unit(progress));
    final rect = Rect.lerp(beginRect, endRect, t)!;
    final radius = lerpDouble(beginRadius, endRadius, t)!;

    Color? border;
    if (beginBorder != null || endBorder != null) {
      const transparent = Color(0x00ffffff);
      border = Color.lerp(
        beginBorder ?? transparent,
        endBorder ?? transparent,
        t,
      );
    }

    return Positioned.fromRect(
      rect: rect,
      child: WindowSurface(
        window: window,
        radius: radius,
        borderColor: border,
      ),
    );
  }
}

/// Convenience border colour for a fully-settled window preview.
const Color kWindowHairline = ShellColors.hairlineWindow;
