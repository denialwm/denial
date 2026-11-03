import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_desktop/src/state/reference_shell_metrics.dart';
import 'package:denial_desktop/src/state/reference_shell_state.dart';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/input.dart' show InputEdge;
import 'package:denial_flutter_sdk/rendering.dart' show CompositedTranslation;
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/system_services.dart';

/// Android's edge Back gesture.
///
/// A swipe inward from the left or right edge, between the status bar and
/// the bottom gesture area, performs [ReferenceShellController.navigateBack]
/// once it travels past [_triggerDistance], or flings inward. Over an app
/// the compositor hands the swipe to these strips as it moves inward; over
/// shell surfaces they receive it directly.
class MobileBackGestureLayer extends ConsumerStatefulWidget {
  const MobileBackGestureLayer({super.key, this.onBack});

  /// Handles Back in place of [ReferenceShellController.navigateBack], for a
  /// surface that covers the shell's own strips.
  final VoidCallback? onBack;

  @override
  ConsumerState<MobileBackGestureLayer> createState() =>
      _MobileBackGestureLayerState();
}

class _MobileBackGestureLayerState extends ConsumerState<MobileBackGestureLayer>
    with TickerProviderStateMixin {
  static const double _touchSlop = 8.0;
  static const double _triggerDistance = 44.0;
  static const double _disarmDistance = 36.0;
  static const double _flingVelocity = 600.0;
  static const double _flingTravel = 16.0;

  final _indicator = _BackIndicator();
  final _indicatorOffset = ValueNotifier(Offset.zero);

  /// Animates the indicator away after release.
  late final AnimationController _release = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  )..addListener(_syncRelease);

  /// Blends the indicator between its idle and armed colours.
  late final AnimationController _arm = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 90),
  )..addListener(() => _indicator.armed = _arm.value);

  InputEdge? _edge;
  int _gesture = 0;
  Offset _origin = Offset.zero;
  bool _armed = false;
  bool _committed = false;
  double _releaseStretch = 0;

  @override
  void dispose() {
    _release.dispose();
    _arm.dispose();
    _indicator.dispose();
    _indicatorOffset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shell = ref.watch(
      referenceShellProvider.select(
        (state) => (
          enabled: state.backTarget != MobileBackTarget.none,
          keyboard: state.edgePanelVisible,
        ),
      ),
    );
    final size = MediaQuery.sizeOf(context);
    final strips = ReferenceShellMetrics.backGestureRects(
      size,
      bottom: shell.keyboard
          ? size.height - ReferenceShellMetrics.edgePanelHeight(size)
          : null,
    );
    final colors = context.shellColors;
    final accent = context.shellTheme.accentPalette;
    final edge = _edge;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Disabling keeps a gesture in flight alive; its release then finds
        // nothing to go back from.
        IgnorePointer(
          ignoring: !shell.enabled && widget.onBack == null,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _strip(strips.left, InputEdge.left),
              _strip(strips.right, InputEdge.right),
            ],
          ),
        ),
        if (edge != null)
          Positioned(
            left: edge == InputEdge.left ? 0 : null,
            right: edge == InputEdge.right ? 0 : null,
            top: 0,
            width: _BackIndicatorPainter.boxSize.width,
            height: _BackIndicatorPainter.boxSize.height,
            child: IgnorePointer(
              child: CompositedTranslation(
                translation: _indicatorOffset,
                devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                child: RepaintBoundary(
                  child: CustomPaint(
                    size: _BackIndicatorPainter.boxSize,
                    painter: _BackIndicatorPainter(
                      indicator: _indicator,
                      mirrored: edge == InputEdge.right,
                      fill: colors.surfaceContainerHighest,
                      glyph: colors.textPrimary,
                      armedFill: accent.primary,
                      armedGlyph: accent.onPrimary,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _strip(Rect rect, InputEdge edge) {
    return Positioned.fromRect(
      rect: rect,
      child: RawGestureDetector(
        behavior: HitTestBehavior.translucent,
        gestures: <Type, GestureRecognizerFactory>{
          HorizontalDragGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<
                HorizontalDragGestureRecognizer
              >(() => HorizontalDragGestureRecognizer(debugOwner: this), (
                recognizer,
              ) {
                recognizer
                  ..gestureSettings = const DeviceGestureSettings(
                    touchSlop: _touchSlop,
                  )
                  ..dragStartBehavior = DragStartBehavior.down
                  ..onStart = ((details) => _start(edge, details))
                  ..onUpdate = _update
                  ..onEnd = _end
                  ..onCancel = (() => _finish(commit: false));
              }),
        },
      ),
    );
  }

  void _start(InputEdge edge, DragStartDetails details) {
    _gesture += 1;
    _release.stop();
    _arm.value = 0;
    _armed = false;
    _committed = false;
    _origin = details.globalPosition;
    _indicator.set(stretch: 0, exit: 0);
    _placeAt(details.globalPosition.dy);
    if (_edge != edge) {
      setState(() => _edge = edge);
    }
  }

  void _update(DragUpdateDetails details) {
    if (_edge == null) return;
    final travel = _inward(details.globalPosition.dx - _origin.dx);
    _indicator.set(stretch: (travel / _triggerDistance).clamp(0.0, 1.4));
    final armed = _armed
        ? travel >= _disarmDistance
        : travel >= _triggerDistance;
    if (armed == _armed) return;
    _armed = armed;
    if (armed) {
      _arm.forward();
      ref.read(hapticsServiceProvider).pulse();
    } else {
      _arm.reverse();
    }
  }

  void _end(DragEndDetails details) {
    if (_edge == null) return;
    final travel = _indicator.stretch * _triggerDistance;
    final velocity = _inward(details.velocity.pixelsPerSecond.dx);
    _finish(
      commit: _armed || (velocity >= _flingVelocity && travel >= _flingTravel),
    );
  }

  void _finish({required bool commit}) {
    if (_edge == null) return;
    _committed = commit;
    _releaseStretch = _indicator.stretch;
    final gesture = _gesture;
    _release.forward(from: 0).whenCompleteOrCancel(() {
      // A new swipe that interrupts the release owns the indicator now.
      if (!mounted || gesture != _gesture) return;
      _indicator.set(stretch: 0, exit: 0);
      setState(() => _edge = null);
    });
    if (commit) {
      final onBack = widget.onBack;
      if (onBack != null) {
        onBack();
      } else {
        ref.read(referenceShellProvider.notifier).navigateBack();
      }
    } else {
      _arm.reverse();
    }
    _armed = false;
  }

  void _syncRelease() {
    final t = Curves.easeOutCubic.transform(_release.value);
    if (_committed) {
      // The arrow carries on inward a little while it fades.
      _indicator.set(stretch: _releaseStretch + 0.25 * t, exit: t);
    } else {
      _indicator.set(stretch: _releaseStretch * (1 - t), exit: 0);
    }
  }

  /// Places the indicator at the height where the swipe started; it stays
  /// there for the rest of the gesture.
  void _placeAt(double y) {
    final half = _BackIndicatorPainter.boxSize.height / 2;
    _indicatorOffset.value = Offset(0, (y - half).roundToDouble());
  }

  double _inward(double dx) => _edge == InputEdge.right ? -dx : dx;
}

/// The indicator's animated values, repainted without rebuilding.
class _BackIndicator extends ChangeNotifier {
  /// Inward travel as a share of the trigger distance; above 1 when armed.
  double stretch = 0;

  /// 0 idle colours, 1 armed colours.
  double get armed => _armed;
  double _armed = 0;
  set armed(double value) {
    if (value == _armed) return;
    _armed = value;
    notifyListeners();
  }

  /// 0 while held, 1 once a committed Back has faded out.
  double exit = 0;

  void set({double? stretch, double? exit}) {
    final nextStretch = stretch ?? this.stretch;
    final nextExit = exit ?? this.exit;
    if (nextStretch == this.stretch && nextExit == this.exit) return;
    this.stretch = nextStretch;
    this.exit = nextExit;
    notifyListeners();
  }
}

/// A half-pill attached to the edge with a back chevron, growing inward with
/// the swipe as Android's Back arrow does.
class _BackIndicatorPainter extends CustomPainter {
  _BackIndicatorPainter({
    required this.indicator,
    required this.mirrored,
    required this.fill,
    required this.glyph,
    required this.armedFill,
    required this.armedGlyph,
  }) : super(repaint: indicator);

  static const Size boxSize = Size(72, 72);
  static const double _width = 44;
  static const double _overshoot = 18;
  static const double _height = 44;

  final _BackIndicator indicator;
  final bool mirrored;
  final Color fill;
  final Color glyph;
  final Color armedFill;
  final Color armedGlyph;

  @override
  void paint(Canvas canvas, Size size) {
    final stretch = indicator.stretch;
    final opacity = ((stretch * 4).clamp(0.0, 1.0)) * (1 - indicator.exit);
    if (opacity <= 0) return;
    final grow = Curves.easeOutCubic.transform(stretch.clamp(0.0, 1.0));
    final width =
        _width * grow + _overshoot * (stretch - 1).clamp(0.0, 1.0).toDouble();
    if (width < 1) return;
    final armed = indicator.armed;
    final height = _height + 4 * armed;
    final centerY = size.height / 2;

    if (mirrored) {
      canvas
        ..translate(size.width, 0)
        ..scale(-1, 1);
    }
    // The pill's rounded inner end is the visible part; the rest lies past
    // the screen edge.
    canvas.drawRRect(
      RRect.fromLTRBR(
        width - height,
        centerY - height / 2,
        width,
        centerY + height / 2,
        Radius.circular(height / 2),
      ),
      Paint()
        ..color = Color.lerp(
          fill,
          armedFill,
          armed,
        )!.withValues(alpha: opacity * (0.9 + 0.1 * armed)),
    );

    final arrowOpacity = ((width - 18) / 14).clamp(0.0, 1.0) * opacity;
    if (arrowOpacity <= 0) return;
    final tipX = width - 22 + 2 * armed;
    const arm = 7.0;
    canvas.drawPath(
      Path()
        ..moveTo(tipX + arm, centerY - arm)
        ..lineTo(tipX, centerY)
        ..lineTo(tipX + arm, centerY + arm),
      Paint()
        ..color = Color.lerp(
          glyph,
          armedGlyph,
          armed,
        )!.withValues(alpha: arrowOpacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_BackIndicatorPainter oldDelegate) =>
      oldDelegate.indicator != indicator ||
      oldDelegate.mirrored != mirrored ||
      oldDelegate.fill != fill ||
      oldDelegate.glyph != glyph ||
      oldDelegate.armedFill != armedFill ||
      oldDelegate.armedGlyph != armedGlyph;
}
