import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_desktop/src/state/reference_shell_state.dart';
import 'package:denial_desktop/src/state/reference_shell_metrics.dart';

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/shell_color_scheme.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/tokens.dart';

import 'shade_expansion_motion.dart';
import 'shade_reference_geometry.dart';
import 'status_glyphs.dart';

/// The status row's geometry and its path into the shade header, shared by
/// [ShadeStatusBar] and [ShadeHeaderStatusLayer].
class _StatusGeometry {
  _StatusGeometry.of(BuildContext context)
    : topPadding = MediaQuery.paddingOf(context).top,
      referenceScale = colorOsShadeScaleForViewport(MediaQuery.sizeOf(context));

  final double topPadding;
  final double referenceScale;

  double get collapsedTop => topPadding + 10;
  static const collapsedHeight = ReferenceShellMetrics.statusBarHeight - 18;
  double get expandedTop => math.max(40 * referenceScale, topPadding);
  double get expandedHeight => 18 * referenceScale;
  double get hitHeight => math.max(
    topPadding + ReferenceShellMetrics.statusBarHeight,
    expandedTop + expandedHeight,
  );

  /// The status row at [progress] of the shade, in screen coordinates.
  List<Widget> foreground(
    BuildContext context,
    double progress,
    Color foreground,
  ) {
    final fraction = ColorOsShadeMotion.translationFraction(progress);
    final color = _statusColorAt(context, foreground, progress);
    return [_cluster(fraction, color), ..._clock(context, fraction, color)];
  }

  /// The icons rise with the row into the shade header.
  Widget _cluster(double fraction, Color color) {
    final horizontal = 20 + (35 * referenceScale - 20) * fraction;
    return Positioned(
      top: collapsedTop + (expandedTop - collapsedTop) * fraction,
      left: horizontal,
      right: horizontal,
      height: collapsedHeight + (expandedHeight - collapsedHeight) * fraction,
      child: Row(
        children: [
          const Spacer(),
          _StatusCluster(color: color),
        ],
      ),
    );
  }

  /// The clock leaves the status row: it grows from its slot into the shade
  /// header, in line with the tiles, and carries the date.
  List<Widget> _clock(BuildContext context, double fraction, Color color) {
    const clockSize = ShadeHeaderClock.fontSize;
    final clockStartTop = collapsedTop + (collapsedHeight - clockSize) / 2;
    final clockEndTop =
        expandedTop +
        expandedHeight +
        ShadeHeaderClock.statusGap * referenceScale;
    final clockTop = clockStartTop + (clockEndTop - clockStartTop) * fraction;
    final clockStart =
        20 + (ShadeHeaderClock.inset * referenceScale - 20) * fraction;
    final clockScale = 1 + (ShadeHeaderClock.expandedScale - 1) * fraction;
    final dateAlpha = unit((fraction - 0.6) / 0.4);
    return [
      PositionedDirectional(
        start: clockStart,
        top: clockTop,
        child: Transform.scale(
          scale: clockScale,
          alignment: AlignmentDirectional.topStart,
          child: _StatusClock(color: color),
        ),
      ),
      if (dateAlpha > 0)
        PositionedDirectional(
          start: clockStart,
          top: clockTop + clockSize * clockScale + ShadeHeaderClock.dateGap,
          child: _StatusDate(
            color: context.shellColors.textSecondary.withValues(
              alpha: context.shellColors.textSecondary.a * dateAlpha,
            ),
          ),
        ),
    ];
  }
}

/// The status foreground over the current app, or white over a dark scene.
Color _statusForeground(BuildContext context, WidgetRef ref) {
  final statusColorArgb = ref.watch(
    referenceShellProvider.select(
      (state) => state.foregroundWindow?.statusColorArgb,
    ),
  );
  final forceWhiteForeground = ref.watch(
    referenceShellProvider.select(
      (state) =>
          state.overviewVisible ||
          state.launchTransitionActive ||
          state.gesture == GestureDragPhase.up ||
          state.homeTransitionActive,
    ),
  );
  return forceWhiteForeground
      ? ShellMediaColors.contrastLight
      : _statusForegroundFor(context.shellColors, statusColorArgb);
}

/// The status color blends into the panel text as the shade opens.
Color _statusColorAt(BuildContext context, Color foreground, double progress) {
  return Color.lerp(
    foreground,
    context.shellColors.panelText,
    ColorOsShadeMotion.blurFraction(progress),
  )!;
}

/// The always-on top status bar. Dragging it down opens the quick-settings
/// shade. Time and battery are isolated into their own consumers so their
/// periodic updates never rebuild the drag surface.
///
/// While the shade is open, the shade draws the whole row beneath its
/// notifications through [ShadeHeaderStatusLayer]; the bar keeps only its
/// drag surface. A landscape view shows no bar, only that surface.
class ShadeStatusBar extends ConsumerWidget {
  const ShadeStatusBar({super.key, this.shadeProgress, this.onDragStart});

  final Animation<double>? shadeProgress;
  final ValueChanged<Offset>? onDragStart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(referenceShellProvider.notifier);
    final foreground = _statusForeground(context, ref);
    final progress = shadeProgress ?? const AlwaysStoppedAnimation(0);
    final geometry = _StatusGeometry.of(context);
    final shown = ReferenceShellMetrics.statusBarShown(
      MediaQuery.sizeOf(context),
    );

    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      height: geometry.hitHeight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragStart: (details) {
          onDragStart?.call(details.localPosition);
          controller.startQuickSettingsDrag(progress: shadeProgress?.value);
        },
        onVerticalDragUpdate: (details) {
          controller.updateQuickSettingsDrag(
            Offset(
              0.0,
              details.delta.dy *
                  ReferenceShellMetrics.quickSettingsDragScale(
                    MediaQuery.sizeOf(context),
                  ),
            ),
          );
        },
        onVerticalDragEnd: (details) {
          controller.endQuickSettingsDrag(details.primaryVelocity ?? 0.0);
        },
        onVerticalDragCancel: () => controller.endQuickSettingsDrag(0.0),
        // A clock or battery change repaints only the status bar; sharing a
        // picture with the rest of the chrome would damage everything down
        // to the home pill.
        child: RepaintBoundary(
          child: AnimatedBuilder(
            animation: progress,
            // Only the change to and from closed rebuilds the row.
            builder: (context, _) => progress.value > 0 || !shown
                ? const SizedBox.expand()
                : Stack(
                    fit: StackFit.expand,
                    clipBehavior: Clip.none,
                    children: geometry.foreground(context, 0, foreground),
                  ),
          ),
        ),
      ),
    );
  }
}

/// The status row of an open shade: icons, clock and date, which the shade
/// draws beneath its notifications so they scroll over it. It continues the
/// status bar exactly, in the same screen coordinates.
class ShadeHeaderStatusLayer extends ConsumerWidget {
  const ShadeHeaderStatusLayer({super.key, required this.progress});

  final Animation<double> progress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final foreground = _statusForeground(context, ref);
    final geometry = _StatusGeometry.of(context);
    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: progress,
          builder: (context, _) {
            if (progress.value <= 0) return const SizedBox.expand();
            return Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.none,
              children: geometry.foreground(
                context,
                progress.value,
                foreground,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _StatusClock extends ConsumerWidget {
  const _StatusClock({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).value ?? DateTime.now();
    final time = localizedTime(context, now);
    final base = ShellText.statusClock.copyWith(
      fontSize: ShadeHeaderClock.fontSize,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.2,
    );
    final separator = time.indexOf(':');
    return Text.rich(
      TextSpan(
        children: separator <= 0 || separator == time.length - 1
            ? <InlineSpan>[TextSpan(text: time)]
            : <InlineSpan>[
                TextSpan(text: time.substring(0, separator + 1)),
                TextSpan(
                  text: time.substring(separator + 1),
                  style: TextStyle(color: color.withValues(alpha: 0.62)),
                ),
              ],
      ),
      style: base.copyWith(color: color),
    );
  }
}

class _StatusDate extends ConsumerWidget {
  const _StatusDate({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).value ?? DateTime.now();
    return Text(
      localizedLongDate(context, now),
      maxLines: 1,
      style: ShellText.base.copyWith(
        color: color,
        fontSize: ShadeHeaderClock.dateFontSize,
        height: 1,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}

class _StatusCluster extends ConsumerWidget {
  const _StatusCluster({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return StatusCluster(
      battery: ref.watch(batteryProvider),
      color: color,
      scale: 1.1,
    );
  }
}

Color _statusForegroundFor(ShellColorScheme colors, int? statusColorArgb) {
  if (statusColorArgb == null) {
    return colors.textPrimary;
  }

  final background = Color.alphaBlend(
    Color(statusColorArgb),
    colors.background,
  );
  return background.computeLuminance() > 0.52
      ? ShellMediaColors.darkness
      : ShellMediaColors.contrastLight;
}
