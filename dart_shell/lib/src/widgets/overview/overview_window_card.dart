import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/widgets.dart';

import '../../models/hypr_window.dart';
import '../../theme/motion.dart';
import '../../theme/tokens.dart';
import '../window_hero.dart';

/// A single overview preview: a live window texture with a centred title that
/// can be flicked up to dismiss its window.
///
/// The dismiss gesture is driven entirely by an unbounded [AnimationController]
/// read inside an [AnimatedBuilder], so dragging and settling never rebuild the
/// (expensive) texture beneath it.
class OverviewWindowCard extends StatefulWidget {
  const OverviewWindowCard({
    super.key,
    required this.window,
    required this.index,
    required this.progress,
    required this.pageOffset,
    required this.cardSize,
    required this.hidden,
    required this.onDismiss,
    required this.onFocus,
  });

  final HyprWindow window;
  final int index;
  final double progress;
  final double pageOffset;
  final Size cardSize;
  final bool hidden;
  final ValueChanged<HyprWindow> onDismiss;
  final void Function(HyprWindow window, Rect startRect) onFocus;

  @override
  State<OverviewWindowCard> createState() => _OverviewWindowCardState();
}

class _OverviewWindowCardState extends State<OverviewWindowCard>
    with SingleTickerProviderStateMixin {
  static const double _downwardRubberBandLimit = 56.0;
  static const double _dismissDistanceRatio = 0.32;
  static const double _dismissFlingVelocity = -760.0;
  static const Duration _dismissMinDuration = Duration(milliseconds: 90);
  static const Duration _dismissMaxDuration = Duration(milliseconds: 240);

  late final AnimationController _dismiss;
  double _exitY = -double.maxFinite;
  bool _dismissed = false;
  final GlobalKey _previewKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _dismiss = AnimationController.unbounded(vsync: this)
      ..addListener(_checkCommit);
  }

  @override
  void didUpdateWidget(covariant OverviewWindowCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.window.objectId != widget.window.objectId) {
      _dismiss.stop();
      _dismiss.value = 0.0;
      _exitY = -double.maxFinite;
      _dismissed = false;
    }
  }

  @override
  void dispose() {
    _dismiss.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final placeholderHeight = widget.cardSize.height + 44.0;
    if (widget.hidden || _dismissed) {
      return Center(
        child:
            SizedBox(width: widget.cardSize.width, height: placeholderHeight),
      );
    }

    final cappedIndex = math.min(widget.index, 4);
    final intro = interval(widget.progress, cappedIndex * 0.045, 1.0);
    final easedIntro = Motion.standard.transform(intro);
    final pageDistance = widget.pageOffset.abs().clamp(0.0, 1.0).toDouble();
    final sideScale = lerpDouble(1.0, 0.925, pageDistance)!;
    final introScale = lerpDouble(0.86, 1.0, easedIntro)!;
    // The whole strip slides in horizontally (see OverviewCarousel); each card
    // only keeps the small side-card dip plus its page parallax.
    final y = pageDistance * 18.0;
    final x = widget.pageOffset.clamp(-1.0, 1.0).toDouble() *
        lerpDouble(18.0, 0.0, easedIntro)!;
    final baseOpacity = easedIntro * lerpDouble(1.0, 0.68, pageDistance)!;

    return Center(
      child: AnimatedBuilder(
        animation: _dismiss,
        child: _buildBody(),
        builder: (context, child) {
          final dismissY = _dismiss.value;
          final dismissProgress =
              unit(-dismissY / (widget.cardSize.height * 0.72));
          final opacity =
              unit(baseOpacity * lerpDouble(1.0, 0.48, dismissProgress)!);

          return Opacity(
            opacity: opacity,
            child: Transform.translate(
              offset: Offset(x, y + dismissY),
              child: Transform.scale(
                scale: introScale * sideScale,
                child: child,
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBody() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _handleTap,
      onVerticalDragStart: (_) {
        if (_dismissed) return;
        _dismiss.stop();
      },
      onVerticalDragUpdate: _handleVerticalDragUpdate,
      onVerticalDragEnd: _handleVerticalDragEnd,
      onVerticalDragCancel: _settleBack,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            key: _previewKey,
            width: widget.cardSize.width,
            height: widget.cardSize.height,
            child: WindowSurface(
              window: widget.window,
              radius: ShellRadii.window,
              borderColor: kWindowHairline,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: widget.cardSize.width,
            height: 28,
            child: Center(
              child: Text(
                widget.window.displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: ShellText.cardTitle,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _handleTap() {
    if (_dismissed) return;

    final renderObject = _previewKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return;
    }
    final origin = renderObject.localToGlobal(Offset.zero);
    widget.onFocus(widget.window, origin & renderObject.size);
  }

  void _handleVerticalDragUpdate(DragUpdateDetails details) {
    if (_dismissed) return;

    _dismiss.stop();
    _dismiss.value = (_dismiss.value + details.delta.dy)
        .clamp(_exitOffset(context), _downwardRubberBandLimit)
        .toDouble();
  }

  void _handleVerticalDragEnd(DragEndDetails details) {
    if (_dismissed) return;

    final velocity = details.primaryVelocity ?? 0.0;
    final passedDistance =
        _dismiss.value <= -widget.cardSize.height * _dismissDistanceRatio;
    if (passedDistance || velocity <= _dismissFlingVelocity) {
      _flingOffscreen(velocity);
    } else {
      _settleBack(velocity);
    }
  }

  void _settleBack([double velocity = 0.0]) {
    if (_dismissed) return;
    springTo(
      _dismiss,
      0.0,
      velocity: velocity,
      spring: Motion.bouncy,
      telemetryLabel: 'overview_card_settle',
    );
  }

  void _flingOffscreen(double velocity) {
    _exitY = _exitOffset(context);
    final distance = (_dismiss.value - _exitY).abs();
    final speed = math.max(velocity.abs(), 1600.0);
    final durationMs = ((distance / speed) * 1000.0)
        .clamp(
          _dismissMinDuration.inMilliseconds.toDouble(),
          _dismissMaxDuration.inMilliseconds.toDouble(),
        )
        .round();
    _dismiss.animateTo(
      _exitY,
      duration: Duration(milliseconds: durationMs),
      curve: Motion.emphasized,
    );
  }

  void _checkCommit() {
    if (!_dismissed && _dismiss.value <= _exitY) {
      _dismiss.stop();
      setState(() => _dismissed = true);
      widget.onDismiss(widget.window);
    }
  }

  double _exitOffset(BuildContext context) {
    final viewHeight = MediaQuery.sizeOf(context).height;
    return -(viewHeight + widget.cardSize.height + 160.0);
  }
}
