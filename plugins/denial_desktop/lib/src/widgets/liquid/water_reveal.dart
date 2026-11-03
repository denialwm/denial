import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'liquid.dart';

/// Fills a node with water as a panel opens and drains it as the panel
/// closes, following the panel's [progress] directly: under a finger the
/// water moves with the finger, and on release it follows the panel's own
/// spring. Nothing runs on a clock of its own, so the node is never left
/// behind by its panel.
///
/// The node fills while [progress] crosses `start .. start + span`. Water
/// lands on the middle of the top edge, spreads along it and runs down, its
/// front leading in the middle. Closing, the surface drops away to the
/// bottom; opening again after that, the level rises back as in a glass.
/// Nothing scales: the node is revealed, never zoomed.
class WaterReveal extends StatefulWidget {
  const WaterReveal({
    super.key,
    required this.progress,
    required this.start,
    required this.child,
    this.span = 0.45,
  });

  final Animation<double> progress;
  final double start;
  final double span;
  final Widget child;

  @override
  State<WaterReveal> createState() => _WaterRevealState();
}

class _WaterRevealState extends State<WaterReveal> {
  late final _WaterShape _shape = _WaterShape(_amountAt(widget.progress.value));

  @override
  void initState() {
    super.initState();
    widget.progress.addListener(_progressChanged);
  }

  @override
  void didUpdateWidget(covariant WaterReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.progress != widget.progress) {
      oldWidget.progress.removeListener(_progressChanged);
      widget.progress.addListener(_progressChanged);
    }
    _progressChanged();
  }

  @override
  void dispose() {
    widget.progress.removeListener(_progressChanged);
    _shape.dispose();
    super.dispose();
  }

  double _amountAt(double progress) =>
      liquidSmooth((progress - widget.start) / widget.span);

  void _progressChanged() {
    final progress = widget.progress.value;
    _shape.update(_amountAt(progress), progress);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _shape,
      child: LiquidRevealScope(reveal: _shape, child: widget.child),
      builder: (context, child) {
        // The tree keeps one shape in every phase, so the node's state
        // survives the reveal.
        return Visibility(
          visible: _shape.value > 0,
          maintainState: true,
          maintainAnimation: true,
          maintainSize: true,
          child: IgnorePointer(
            ignoring: _shape.value < 0.5,
            child: ExcludeSemantics(
              excluding: _shape.value <= 0,
              child: ClipPath(
                clipper: _WaterClipper(_shape),
                clipBehavior: _shape.full ? Clip.none : Clip.antiAlias,
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The wet band of a node, from its top to its bottom as fractions of its
/// height. Its value is how full the node is.
class _WaterShape extends ChangeNotifier implements ValueListenable<double> {
  _WaterShape(double amount) : _amount = amount, _bottom = amount;

  /// The width of the stream where it lands.
  static const double _landingWidth = 12;

  double _amount;
  double _top = 0;
  double _bottom;
  double _phase = 0;

  bool? _opening;
  double _anchorAmount = 0;
  double _anchorTop = 0;
  double _anchorBottom = 0;

  @override
  double get value => _amount;

  bool get full => _amount >= 1;

  void update(double amount, double progress) {
    _phase = progress;
    final change = amount - _amount;
    if (change == 0) return;
    final opening = change > 0;
    // A turn of the finger keeps the water where it is and carries on
    // from there.
    if (opening != _opening) {
      _opening = opening;
      _anchorAmount = _amount;
      _anchorTop = _top;
      _anchorBottom = _bottom;
    }
    _amount = amount;
    if (amount <= 0) {
      _top = 0;
      _bottom = 0;
      _opening = null;
    } else if (amount >= 1) {
      _top = 0;
      _bottom = 1;
      _opening = null;
    } else if (opening) {
      // The front runs on down and a dropped surface rises back.
      final s = (amount - _anchorAmount) / (1 - _anchorAmount);
      _top = _anchorTop * (1 - s);
      _bottom = _anchorBottom + (1 - _anchorBottom) * s;
    } else {
      // The surface drops toward the water's lowest point.
      final r = _anchorAmount <= 0 ? 0.0 : amount / _anchorAmount;
      _top = _anchorBottom - r * (_anchorBottom - _anchorTop);
      _bottom = _anchorBottom;
    }
    notifyListeners();
  }

  Path region(Size size) {
    final width = size.width;
    final height = size.height;
    if (_amount >= 1) return Path()..addRect(Offset.zero & size);
    if (_bottom <= _top) return Path();
    // Shapes are sized in pixels: a wide node is a wide container, with a
    // deeper front and more waves across it, not a stretched small one.
    final lead = (width * 0.16).clamp(0.0, 22.0);
    final waves = (width / 76).clamp(1.0, 2.0);
    // The water spreads along the top edge as it starts to run down.
    final spread =
        _landingWidth +
        (width - _landingWidth) * (1 - math.exp(-_bottom / 0.12));
    final left = (width - spread) / 2;
    const steps = 12;

    // The surface: flat at the top while pouring, dipping in the middle as
    // it drops away.
    final surface = _top * (height + lead);
    double surfaceAt(double t) {
      if (_top <= 0) return 0;
      final centred = (t - 0.5) * 2;
      return surface -
          lead +
          lead * 0.5 * (1 - centred * centred) +
          2 * waves * math.sin(_phase * 50) * (1 - 2 * t) +
          1.5 * waves * math.sin(t * width / 18 - _phase * 60);
    }

    // The front: its middle leads, and it ripples less as the node fills.
    final front = _bottom * (height + lead);
    final ripple = 2.5 * waves * (1 - _bottom);
    double frontAt(double t) {
      if (_bottom >= 1) return height;
      final centred = (t - 0.5) * 2;
      return front -
          lead * centred * centred +
          ripple * math.sin(t * width / 16 + _phase * 40);
    }

    final path = Path();
    for (var i = 0; i <= steps; i += 1) {
      final t = i / steps;
      final x = left + spread * t;
      final y = surfaceAt(t);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    for (var i = steps; i >= 0; i -= 1) {
      final t = i / steps;
      path.lineTo(left + spread * t, math.max(surfaceAt(t), frontAt(t)));
    }
    return path..close();
  }
}

class _WaterClipper extends CustomClipper<Path> {
  _WaterClipper(this.shape) : super(reclip: shape);

  final _WaterShape shape;

  @override
  Path getClip(Size size) => shape.region(size);

  @override
  bool shouldReclip(_WaterClipper oldClipper) => oldClipper.shape != shape;
}

/// The water reveal a node is in, for descendants that pour their own
/// contents in as it fills.
class LiquidRevealScope extends InheritedWidget {
  const LiquidRevealScope({
    super.key,
    required this.reveal,
    required super.child,
  });

  /// How full the node is, 0 to 1.
  final ValueListenable<double> reveal;

  static ValueListenable<double>? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LiquidRevealScope>()?.reveal;

  @override
  bool updateShouldNotify(LiquidRevealScope oldWidget) =>
      reveal != oldWidget.reveal;
}
