import 'dart:async';

import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

import '../../theme/motion.dart';

/// Expansion thresholds and motion taken from ColorOS' layered separate shade.
abstract final class ColorOsShadeMotion {
  /// Separate-mode blur is fully established at 33% panel expansion.
  static double blurFraction(double progress) => unit(progress / 0.33);

  /// The shade content finishes its short header-offset translation at 86%.
  static double translationFraction(double progress) => unit(progress / 0.86);

  static const double translationDistance = 34;

  /// ColorOS keeps a distinct 102dp root-view translation for collapsing QS.
  static const double collapseTranslationDistance = 102;
  static const double fixedElementThreshold = 0.05;
  static const double firstElementThreshold = 0.50;
  static const double contentElementThreshold = 0.86;
  static const Duration nodeStagger = Duration(milliseconds: 16);

  // COUI's element reveal uses response=0.3 and dampingRatio=1.
  static const SpringDescription elementSpring = SpringDescription(
    mass: 1,
    stiffness: 438.65,
    damping: 41.89,
  );
}

/// Moves the laid-out shade content along ColorOS' direction-specific paths.
///
/// The background is deliberately outside this widget. ColorOS does not pull a
/// full-screen sheet into view. Opening retains the short header-offset motion,
/// while closing drives the separate QS root-view translation from 0 to -102.
class ColorOsShadeContentTranslation extends StatefulWidget {
  const ColorOsShadeContentTranslation({
    super.key,
    required this.progress,
    required this.child,
  });

  final Animation<double> progress;
  final Widget child;

  @override
  State<ColorOsShadeContentTranslation> createState() =>
      _ColorOsShadeContentTranslationState();
}

class _ColorOsShadeContentTranslationState
    extends State<ColorOsShadeContentTranslation> {
  static const double _directionEpsilon = 0.000001;

  late double _lastProgress;
  late bool _closing;
  late double _anchorProgress;
  late double _anchorOffset;

  @override
  void initState() {
    super.initState();
    _reset(widget.progress.value);
    widget.progress.addListener(_observeDirection);
  }

  void _reset(double progress) {
    _lastProgress = unit(progress);
    _closing = false;
    _anchorProgress = 0;
    _anchorOffset = -ColorOsShadeMotion.translationDistance;
  }

  @override
  void didUpdateWidget(covariant ColorOsShadeContentTranslation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.progress == widget.progress) return;
    oldWidget.progress.removeListener(_observeDirection);
    _reset(widget.progress.value);
    widget.progress.addListener(_observeDirection);
  }

  void _observeDirection() {
    final next = unit(widget.progress.value);
    final delta = next - _lastProgress;

    // A fully closed shade is offstage. Start its next entrance from the short
    // header offset instead of carrying the completed -102 exit into opening.
    if (delta > _directionEpsilon && _lastProgress <= _directionEpsilon) {
      _closing = false;
      _anchorProgress = 0;
      _anchorOffset = -ColorOsShadeMotion.translationDistance;
    } else if (delta < -_directionEpsilon && !_closing) {
      _anchorOffset = _offsetAt(_lastProgress);
      _anchorProgress = _lastProgress;
      _closing = true;
    } else if (delta > _directionEpsilon && _closing) {
      // Preserve position if a closing gesture reverses before completion.
      _anchorOffset = _offsetAt(_lastProgress);
      _anchorProgress = _lastProgress;
      _closing = false;
    }
    _lastProgress = next;
  }

  double _offsetAt(double progress) {
    if (_closing) {
      if (_anchorProgress <= _directionEpsilon) {
        return -ColorOsShadeMotion.collapseTranslationDistance;
      }
      final fraction = unit((_anchorProgress - progress) / _anchorProgress);
      return _anchorOffset +
          (-ColorOsShadeMotion.collapseTranslationDistance - _anchorOffset) *
              fraction;
    }

    final endProgress = _anchorProgress < 0.86 ? 0.86 : 1.0;
    final range = endProgress - _anchorProgress;
    if (range <= _directionEpsilon) return 0;
    final fraction = unit((progress - _anchorProgress) / range);
    return _anchorOffset * (1 - fraction);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.progress,
      child: widget.child,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, _offsetAt(unit(widget.progress.value))),
          child: child,
        );
      },
    );
  }

  @override
  void dispose() {
    widget.progress.removeListener(_observeDirection);
    super.dispose();
  }
}

/// ColorOS' independent alpha/scale entrance for header and control nodes.
/// Once revealed, nodes keep their full geometry while the shade closes; the
/// shared shade translation carries them away without a grid-wide implosion.
class ColorOsShadeElementReveal extends StatefulWidget {
  const ColorOsShadeElementReveal({
    super.key,
    required this.progress,
    required this.threshold,
    required this.child,
    this.delay = Duration.zero,
    this.fade = true,
    this.collapseTranslation = 0,
  });

  final Animation<double> progress;
  final double threshold;
  final Duration delay;

  /// Upward travel used while this node collapses.
  ///
  /// Glass nodes use translation instead of ColorOS' accompanying alpha and
  /// scale animations so their backdrop sample remains live throughout.
  final double collapseTranslation;

  /// Whether to use ColorOS' alpha reveal in addition to scale.
  ///
  /// Backdrop-filtered children set this to false because fractional opacity
  /// introduces an offscreen save layer that cannot sample their live glass.
  /// Those children scale from zero instead, retaining a complete reveal.
  final bool fade;
  final Widget child;

  @override
  State<ColorOsShadeElementReveal> createState() =>
      _ColorOsShadeElementRevealState();
}

class _ColorOsShadeElementRevealState extends State<ColorOsShadeElementReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _reveal;
  Timer? _delay;
  late bool _shown;
  late double _lastProgress;
  bool _collapsing = false;
  double _collapseStart = 1;
  bool _reducedMotion = false;

  @override
  void initState() {
    super.initState();
    _lastProgress = widget.progress.value;
    _shown = widget.progress.value >= widget.threshold;
    _reveal = AnimationController(vsync: this, value: _shown ? 1 : 0);
    widget.progress.addListener(_syncWithProgress);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (_reducedMotion) _reveal.value = _shown ? 1 : 0;
  }

  @override
  void didUpdateWidget(covariant ColorOsShadeElementReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.progress != widget.progress) {
      oldWidget.progress.removeListener(_syncWithProgress);
      widget.progress.addListener(_syncWithProgress);
      _lastProgress = widget.progress.value;
    }
    _syncWithProgress();
  }

  void _syncWithProgress() {
    final progress = widget.progress.value;
    final previous = _lastProgress;
    final closing = progress < previous - 0.000001;
    final opening = progress > previous + 0.000001;
    if (closing && !_collapsing) {
      _collapsing = true;
      _collapseStart = previous;
    } else if (opening &&
        (_lastProgress <= 0.000001 || progress >= _collapseStart)) {
      _collapsing = false;
    }
    _lastProgress = progress;
    if (progress <= 0) {
      _delay?.cancel();
      _shown = false;
      _reveal.stop();
      _reveal.value = 0;
      return;
    }
    if (closing || _shown || progress < widget.threshold) {
      if (closing) _delay?.cancel();
      return;
    }
    _shown = true;
    _delay?.cancel();
    if (_reducedMotion) {
      _reveal.value = 1;
      return;
    }
    if (widget.delay > Duration.zero) {
      _delay = Timer(widget.delay, () {
        if (mounted && _shown) _animateTo(1);
      });
      return;
    }
    _animateTo(1);
  }

  void _animateTo(double target) {
    springTo(
      _reveal,
      target,
      spring: ColorOsShadeMotion.elementSpring,
      telemetryLabel: 'shade_element_reveal',
    );
  }

  @override
  Widget build(BuildContext context) {
    final revealed = AnimatedBuilder(
      animation: _reveal,
      child: widget.child,
      builder: (context, child) {
        final value = unit(_reveal.value);
        final scaled = Transform.scale(
          scale: widget.fade ? 0.8 + 0.2 * value : value,
          alignment: Alignment.center,
          child: child,
        );
        return IgnorePointer(
          ignoring: value < 0.5,
          child: ExcludeSemantics(
            excluding: value == 0,
            child: widget.fade
                ? Opacity(opacity: value, child: scaled)
                : scaled,
          ),
        );
      },
    );
    return AnimatedBuilder(
      animation: widget.progress,
      child: revealed,
      builder: (context, child) {
        final start = _collapseStart < widget.threshold
            ? _collapseStart
            : widget.threshold;
        // Reference second-stage nodes begin their negative-Y spring at 86%
        // and finish before the shade reaches zero. That avoids a last-frame
        // pop when the enclosing shade becomes offstage.
        final finish = start * 0.1;
        final range = start - finish;
        final fraction = !_collapsing || range <= 0
            ? 0.0
            : unit((start - widget.progress.value) / range);
        return Transform.translate(
          offset: Offset(0, -widget.collapseTranslation * fraction),
          child: child,
        );
      },
    );
  }

  @override
  void dispose() {
    widget.progress.removeListener(_syncWithProgress);
    _delay?.cancel();
    _reveal.dispose();
    super.dispose();
  }
}
