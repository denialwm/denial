import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../theme/motion.dart';
import 'desktop_window_snapshot.dart';

/// Centres of the four quarters inside a desktop window.
///
/// These positions keep the reveal away from literal corners and edges while
/// still making consecutive entrances feel spatially varied.
enum DesktopWindowRevealOrigin {
  topLeftQuarter(Alignment(-0.75, -0.75)),
  topRightQuarter(Alignment(0.75, -0.75)),
  bottomRightQuarter(Alignment(0.75, 0.75)),
  bottomLeftQuarter(Alignment(-0.75, 0.75));

  const DesktopWindowRevealOrigin(this.alignment);

  final Alignment alignment;

  Offset resolve(Size size) => alignment.alongSize(size);
}

/// Reveals a newly inserted desktop window with Denial's expanding squircle.
///
/// The state belongs to the window's keyed scene entry, so focus changes,
/// overview transitions, and minimize/restore never replay the entrance. Its
/// duration is fixed; window dimensions affect only the final clip geometry.
class DesktopWindowReveal extends StatefulWidget {
  const DesktopWindowReveal({
    super.key,
    required this.child,
    this.enabled = true,
    this.origin,
  });

  final Widget child;

  /// False for transient surfaces, such as XWayland menus and tooltips, which
  /// should appear immediately like native xdg_popup surfaces.
  final bool enabled;

  /// An optional fixed origin, primarily useful for previews and tests.
  /// Production callers omit this to select a random quarter centre once.
  final DesktopWindowRevealOrigin? origin;

  @override
  State<DesktopWindowReveal> createState() => _DesktopWindowRevealState();
}

class _DesktopWindowRevealState extends State<DesktopWindowReveal>
    with SingleTickerProviderStateMixin {
  static final math.Random _random = math.Random();
  static const double _textureWarmupProgress = 0.001;

  late final AnimationController _controller;
  late DesktopWindowRevealOrigin _origin;
  Timer? _leadInTimer;
  var _revealScheduled = false;
  var _revealStarted = false;
  var _revealComplete = false;

  @override
  void initState() {
    super.initState();
    _origin = widget.origin ?? _randomOrigin();
    _controller = AnimationController(
      vsync: this,
      duration: Motion.desktopWindowReveal,
      animationBehavior: AnimationBehavior.preserve,
    )..addStatusListener(_handleAnimationStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget.enabled || MediaQuery.disableAnimationsOf(context)) {
      _completeImmediately();
      return;
    }
    _scheduleReveal();
  }

  @override
  void didUpdateWidget(covariant DesktopWindowReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.origin != oldWidget.origin) {
      _origin = widget.origin ?? _randomOrigin();
    }
    if (oldWidget.enabled && !widget.enabled) {
      _completeImmediately();
      return;
    }
    if (!oldWidget.enabled && widget.enabled) {
      // XWayland metadata can settle over more than one snapshot. If a normal
      // root was briefly classified as transient, give it its one entrance as
      // soon as the authoritative classification arrives.
      _resetReveal();
      if (!MediaQuery.disableAnimationsOf(context)) {
        _scheduleReveal();
      } else {
        _completeImmediately();
      }
    }
  }

  @override
  void dispose() {
    _leadInTimer?.cancel();
    _controller
      ..removeStatusListener(_handleAnimationStatus)
      ..dispose();
    super.dispose();
  }

  void _scheduleReveal() {
    if (_revealScheduled || _revealComplete || !widget.enabled) {
      return;
    }

    // Give placement and a new external texture a short, fixed warm-up before
    // making the entrance visible. The controller starts only after the
    // initial clipped state has itself reached a frame; this prevents a busy
    // first client frame from swallowing the transition.
    _revealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _revealComplete || !widget.enabled) {
        return;
      }
      _leadInTimer = Timer(Motion.desktopWindowRevealLeadIn, () {
        if (!mounted || _revealComplete || !widget.enabled) {
          return;
        }
        setState(() => _revealStarted = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _revealComplete || !widget.enabled) {
            return;
          }
          MotionTelemetry.observe(
            _controller,
            _controller.forward(from: 0.0),
            'desktop_window_reveal',
            target: 1.0,
          );
        });
      });
    });
  }

  void _resetReveal() {
    _leadInTimer?.cancel();
    _leadInTimer = null;
    _controller
      ..stop()
      ..value = 0.0;
    _revealScheduled = false;
    _revealStarted = false;
    _revealComplete = false;
  }

  void _completeImmediately() {
    _leadInTimer?.cancel();
    _leadInTimer = null;
    _revealStarted = true;
    _revealComplete = true;
    _controller
      ..stop()
      ..value = 1.0;
  }

  void _handleAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted && !_revealComplete) {
      setState(() => _revealComplete = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final revealActive =
        widget.enabled &&
        !_revealComplete &&
        !MediaQuery.disableAnimationsOf(context);
    final transitionChild = DesktopWindowSnapshotScope(
      snapshotting: revealActive,
      child: widget.child,
    );
    return AnimatedBuilder(
      animation: _controller,
      child: transitionChild,
      builder: (context, child) {
        final progress = _revealStarted
            ? Motion.desktopWindowRevealCurve.transform(_controller.value)
            : _textureWarmupProgress;
        return ClipPath(
          clipBehavior: revealActive ? Clip.antiAlias : Clip.none,
          clipper: revealActive
              ? DesktopWindowSquircleRevealClipper(
                  origin: _origin,
                  progress: progress,
                )
              : null,
          child: child,
        );
      },
    );
  }

  DesktopWindowRevealOrigin _randomOrigin() {
    final origins = DesktopWindowRevealOrigin.values;
    return origins[_random.nextInt(origins.length)];
  }
}

@visibleForTesting
class DesktopWindowSquircleRevealClipper extends CustomClipper<Path> {
  const DesktopWindowSquircleRevealClipper({
    required this.origin,
    required this.progress,
  });

  static const double _exponent = 4.0;
  static const int _segments = 64;

  final DesktopWindowRevealOrigin origin;
  final double progress;

  @override
  Path getClip(Size size) {
    if (size.isEmpty || progress <= 0.0) {
      return Path();
    }

    final bounds = Offset.zero & size;
    final center = origin.resolve(size);
    final farthestX = math.max(
      center.dx - bounds.left,
      bounds.right - center.dx,
    );
    final farthestY = math.max(
      center.dy - bounds.top,
      bounds.bottom - center.dy,
    );
    // A superellipse corner at (a, b) satisfies 2 / scale^exponent = 1.
    // Expanding each half-extent by this factor guarantees that the farthest
    // window corner is inside the completed squircle.
    final cornerCoverageScale = math.pow(2.0, 1.0 / _exponent).toDouble();
    final revealProgress = unit(progress);
    final halfWidth = (farthestX + 1.0) * cornerCoverageScale * revealProgress;
    final halfHeight = (farthestY + 1.0) * cornerCoverageScale * revealProgress;
    return _superellipsePath(
      center: center,
      halfWidth: halfWidth,
      halfHeight: halfHeight,
    );
  }

  @override
  bool shouldReclip(covariant DesktopWindowSquircleRevealClipper oldClipper) {
    return origin != oldClipper.origin || progress != oldClipper.progress;
  }

  Path _superellipsePath({
    required Offset center,
    required double halfWidth,
    required double halfHeight,
  }) {
    final path = Path();
    const coordinatePower = 2.0 / _exponent;
    for (var index = 0; index <= _segments; index += 1) {
      final angle = 2.0 * math.pi * index / _segments;
      final cosine = math.cos(angle);
      final sine = math.sin(angle);
      final point = Offset(
        center.dx + halfWidth * _signedPower(cosine, coordinatePower),
        center.dy + halfHeight * _signedPower(sine, coordinatePower),
      );
      if (index == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    return path..close();
  }

  double _signedPower(double value, double exponent) {
    final magnitude = math.pow(value.abs(), exponent).toDouble();
    return value.isNegative ? -magnitude : magnitude;
  }
}
