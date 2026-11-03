import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/rendering.dart' show CompositedTranslation;

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
  static const Duration nodeStagger = Duration(milliseconds: 12);

  /// Closing retracts the lowest node first, on a tighter chain.
  static const Duration exitStagger = Duration(milliseconds: 8);

  // COUI's element reveal uses response=0.3 and dampingRatio=1; Denial runs
  // it a little quicker at response=0.25.
  static const SpringDescription elementSpring = SpringDescription(
    mass: 1,
    stiffness: 631.65,
    damping: 50.27,
  );

  /// Critically damped, response=0.2: nodes are gone before the blur fades.
  static const SpringDescription elementExitSpring = SpringDescription(
    mass: 1,
    stiffness: 986.96,
    damping: 62.83,
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
  final _translation = ValueNotifier(Offset.zero);

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
    _translation.value = Offset(0, _offsetAt(_lastProgress));
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
    _translation.value = Offset(0, _offsetAt(next));
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
    // The content moves as a layer: the shade's motion neither rebuilds nor
    // repaints it.
    return CompositedTranslation(
      translation: _translation,
      child: widget.child,
    );
  }

  @override
  void dispose() {
    widget.progress.removeListener(_observeDirection);
    _translation.dispose();
    super.dispose();
  }
}

/// ColorOS' independent alpha/scale entrance for header and control nodes.
///
/// Closing mirrors it: once the shade falls below [threshold] again, the node
/// shrinks back after [exitDelay] while the shared shade translation carries
/// the content up. Nodes never move on their own, so an enclosing scroll
/// viewport never slices them, and they only rebuild while they animate.
class ColorOsShadeElementReveal extends StatefulWidget {
  const ColorOsShadeElementReveal({
    super.key,
    required this.progress,
    required this.threshold,
    required this.child,
    this.delay = Duration.zero,
    this.exitDelay = Duration.zero,
    this.fade = true,
  });

  final Animation<double> progress;
  final double threshold;
  final Duration delay;
  final Duration exitDelay;

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
  static const double _directionEpsilon = 0.000001;

  late final AnimationController _reveal;
  Timer? _delay;
  late bool _shown;
  late double _lastProgress;
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
    _lastProgress = progress;
    if (progress <= 0) {
      _delay?.cancel();
      _shown = false;
      _reveal.stop();
      _reveal.value = 0;
      return;
    }
    final opening = progress > previous + _directionEpsilon;
    final closing = progress < previous - _directionEpsilon;
    if (!_shown && opening && progress >= widget.threshold) {
      _show(true, widget.delay);
    } else if (_shown && closing && progress < widget.threshold) {
      _show(false, widget.exitDelay);
    }
  }

  void _show(bool shown, Duration delay) {
    _shown = shown;
    _delay?.cancel();
    final target = shown ? 1.0 : 0.0;
    if (_reducedMotion) {
      _reveal.value = target;
      return;
    }
    if (delay > Duration.zero) {
      _delay = Timer(delay, () {
        if (mounted && _shown == shown) _animateTo(target);
      });
      return;
    }
    _animateTo(target);
  }

  void _animateTo(double target) {
    springTo(
      _reveal,
      target,
      spring: target > 0
          ? ColorOsShadeMotion.elementSpring
          : ColorOsShadeMotion.elementExitSpring,
      telemetryLabel: target > 0
          ? 'shade_element_reveal'
          : 'shade_element_exit',
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
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
  }

  @override
  void dispose() {
    widget.progress.removeListener(_syncWithProgress);
    _delay?.cancel();
    _reveal.dispose();
    super.dispose();
  }
}
