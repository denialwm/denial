import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter/gestures.dart' show VelocityTracker;

import '../../models/denial_window.dart';
import '../../theme/motion.dart';
import '../retained_translation.dart';
import 'overview_window_preview.dart';

/// A fixed-size preview with paint-only drag and settle motion.
class OverviewWindowCard extends StatefulWidget {
  const OverviewWindowCard({
    super.key,
    required this.window,
    required this.cardSize,
    required this.foreground,
    this.focusing = false,
    required this.onDismiss,
    required this.onFocus,
  });

  final DenialWindow window;
  final Size cardSize;
  final bool foreground;
  final bool focusing;
  final ValueChanged<DenialWindow> onDismiss;
  final void Function(DenialWindow window, Rect startRect) onFocus;

  @override
  State<OverviewWindowCard> createState() => _OverviewWindowCardState();
}

class _OverviewWindowCardState extends State<OverviewWindowCard>
    with SingleTickerProviderStateMixin {
  // Android 16 TaskViewDismissTouchController: half the off-screen travel,
  // 25dp undershoot, and BaseSwipeDetector's 1dp/ms release threshold.
  static const double _downwardRubberBandLimit = 25.0;
  static const double _dismissDistanceRatio = 0.5;
  static const double _dismissFlingVelocity = 1000.0;
  static const double _offscreenMargin = 16.0;

  late final AnimationController _dismiss;
  late final Animation<Offset> _translation;
  double _exitY = -double.maxFinite;
  double _dragDisplacement = 0;
  double _dismissLength = 1;
  VelocityTracker? _velocityTracker;
  int? _trackedPointer;
  bool _pointerCancelled = false;
  bool _dismissed = false;
  bool _exiting = false;
  bool _commitScheduled = false;
  final GlobalKey _previewKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _dismiss = AnimationController.unbounded(vsync: this)
      ..addListener(_checkCommit);
    _translation = _dismiss.drive(
      Tween(begin: Offset.zero, end: const Offset(0, 1)),
    );
  }

  @override
  void didUpdateWidget(covariant OverviewWindowCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.window.objectId != widget.window.objectId) {
      _dismiss.stop();
      _dismiss.value = 0.0;
      _exitY = -double.maxFinite;
      _dismissed = false;
      _exiting = false;
      _commitScheduled = false;
    }
  }

  @override
  void dispose() {
    _dismiss.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed || widget.focusing || widget.foreground) {
      return Center(
        child: SizedBox(
          width: widget.cardSize.width,
          height: widget.cardSize.height,
        ),
      );
    }

    final card = Center(
      child: RetainedTranslation(
        translation: _translation,
        child: Listener(
          onPointerDown: (event) {
            if (_trackedPointer != null) return;
            _trackedPointer = event.pointer;
            _pointerCancelled = false;
            _velocityTracker = VelocityTracker.withKind(event.kind)
              ..addPosition(event.timeStamp, event.position);
          },
          onPointerMove: (event) {
            if (event.pointer == _trackedPointer) {
              _velocityTracker?.addPosition(event.timeStamp, event.position);
            }
          },
          onPointerUp: (event) {
            if (event.pointer == _trackedPointer) _trackedPointer = null;
          },
          onPointerCancel: (event) {
            if (event.pointer != _trackedPointer) return;
            _trackedPointer = null;
            _pointerCancelled = true;
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _handleTap,
            onVerticalDragStart: _handleVerticalDragStart,
            onVerticalDragUpdate: _handleVerticalDragUpdate,
            onVerticalDragEnd: _handleVerticalDragEnd,
            onVerticalDragCancel: _settleBack,
            child: OverviewWindowPreview(
              previewKey: _previewKey,
              window: widget.window,
              size: widget.cardSize,
            ),
          ),
        ),
      ),
    );
    return card;
  }

  void _handleTap() {
    if (_dismissed || _exiting) return;

    final renderObject = _previewKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return;
    }
    final origin = renderObject.localToGlobal(Offset.zero);
    widget.onFocus(widget.window, origin & renderObject.size);
  }

  void _handleVerticalDragUpdate(DragUpdateDetails details) {
    if (_dismissed || _exiting) return;

    _dragDisplacement += details.delta.dy;
    if (_dragDisplacement <= 0) {
      _dismiss.value = _dragDisplacement.clamp(-_dismissLength, 0.0);
    } else {
      // Track raw finger travel separately: resistance must unwind smoothly
      // when the user reverses, rather than sticking at a hard clamp.
      final fraction = (_dragDisplacement / _dismissLength).clamp(0.0, 1.0);
      _dismiss.value =
          _downwardRubberBandLimit * Curves.decelerate.transform(fraction);
    }
  }

  void _handleVerticalDragStart(DragStartDetails details) {
    if (_dismissed || _exiting) return;
    _dismiss.stop();
    _dismissLength = math.max(1.0, -_exitOffset(context));
    _dragDisplacement = _dismiss.value <= 0
        ? _dismiss.value
        : _dismissLength *
              (1 -
                  math.sqrt(
                    1 -
                        (_dismiss.value / _downwardRubberBandLimit).clamp(
                          0.0,
                          1.0,
                        ),
                  ));
  }

  void _handleVerticalDragEnd(DragEndDetails details) {
    if (_dismissed || _exiting) return;
    // An accepted Flutter drag reports PointerCancel through onEnd too.
    if (_pointerCancelled) {
      _settleBack();
      return;
    }

    // The preview follows the finger. Estimate velocity in screen coordinates
    // so its moving local coordinate space cannot cancel out the fling.
    final velocity =
        (_velocityTracker?.getVelocity().pixelsPerSecond.dy ??
                details.primaryVelocity ??
                0.0)
            .clamp(-8000.0, 8000.0);
    final passedDistance =
        _dismiss.value < -_dismissLength * _dismissDistanceRatio;
    final flingingUp = velocity < -_dismissFlingVelocity;
    final flingingDown = velocity > _dismissFlingVelocity;
    // Release direction takes precedence over distance, so throwing a card
    // back down cancels even after crossing the dismissal threshold.
    if (flingingUp || (passedDistance && !flingingDown)) {
      _flingOffscreen(velocity);
    } else {
      _settleBack(velocity);
    }
  }

  void _settleBack([double velocity = 0.0]) {
    if (_dismissed || _exiting) return;
    springTo(
      _dismiss,
      0.0,
      velocity: velocity,
      spring: Motion.bouncy,
      telemetryLabel: 'overview_card_settle',
    );
  }

  void _flingOffscreen(double velocity) {
    _exiting = true;
    _exitY = _exitOffset(context);
    springTo(
      _dismiss,
      _exitY,
      velocity: velocity,
      spring: Motion.snappy,
      telemetryLabel: 'overview_card_dismiss',
    );
  }

  void _checkCommit() {
    if (!_exiting ||
        _dismissed ||
        _commitScheduled ||
        _dismiss.value > _exitY + _offscreenMargin) {
      return;
    }
    _commitScheduled = true;
    final objectId = widget.window.objectId;
    // Commit as soon as the preview leaves the screen. The spring's
    // target has extra clearance; waiting for that exact value adds its slow
    // settling tail after the card is already invisible.
    // Present this last frame before releasing the app's surface.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.window.objectId != objectId) return;
      _dismiss.stop();
      setState(() => _dismissed = true);
      widget.onDismiss(widget.window);
    });
  }

  double _exitOffset(BuildContext context) {
    final preview = _previewKey.currentContext?.findRenderObject();
    if (preview is RenderBox && preview.hasSize) {
      return _dismiss.value -
          preview.localToGlobal(Offset(0, preview.size.height)).dy -
          _offscreenMargin;
    }
    return -(MediaQuery.sizeOf(context).height + widget.cardSize.height);
  }
}
