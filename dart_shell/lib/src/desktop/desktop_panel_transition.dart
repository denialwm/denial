import 'package:flutter/material.dart';

import '../input/shell_interaction_registry.dart';
import '../theme/motion.dart';
import '../theme/shell_theme.dart';
import '../widgets/shell_backdrop_blur.dart';

/// Animates a desktop panel and optionally retains its state while closed.
class DesktopPanelTransition extends StatefulWidget {
  const DesktopPanelTransition({
    super.key,
    required this.inputDebugLabel,
    required this.visible,
    required this.child,
    this.entryDirection = const Offset(-1, 0),
    this.entryDistance = 0,
    this.durationScale = 1,
    this.keyboardPolicy = ShellKeyboardPolicy.none,
    this.maintainState = false,
  });

  final String inputDebugLabel;
  final bool visible;
  final Widget child;
  final Offset entryDirection;
  final double entryDistance;
  final double durationScale;
  final ShellKeyboardPolicy keyboardPolicy;

  /// Keeps the child mounted and offstage after its first completed close.
  ///
  /// The child is still built lazily on the first open. This is useful for
  /// panels whose initial state contains decoded images or other expensive
  /// resources that should survive repeated open/close cycles.
  final bool maintainState;

  @override
  State<DesktopPanelTransition> createState() => _DesktopPanelTransitionState();
}

class _DesktopPanelTransitionState extends State<DesktopPanelTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _progress;
  late bool _showChild;
  var _offstage = false;

  @override
  void initState() {
    super.initState();
    _showChild = widget.visible;
    _controller = AnimationController(
      vsync: this,
      value: widget.visible ? 1.0 : 0.0,
      duration: _scaledDuration(Motion.desktopPanelOpen, widget.durationScale),
      reverseDuration: _scaledDuration(
        Motion.desktopPanelClose,
        widget.durationScale,
      ),
    );
    _progress = CurvedAnimation(
      parent: _controller,
      curve: Motion.md3EmphasizedDecelerate,
      reverseCurve: Motion.md3EmphasizedAccelerate,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateDurations();
  }

  @override
  void didUpdateWidget(covariant DesktopPanelTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.durationScale != oldWidget.durationScale) {
      _updateDurations();
    }
    if (widget.visible == oldWidget.visible) {
      if (!widget.visible &&
          !widget.maintainState &&
          oldWidget.maintainState &&
          _controller.value == 0.0) {
        _showChild = false;
        _offstage = false;
      }
      return;
    }

    if (widget.visible) {
      _showChild = true;
      _offstage = false;
      _controller.forward();
      return;
    }

    _controller.reverse().whenCompleteOrCancel(() {
      if (!mounted || widget.visible || _controller.value != 0.0) {
        return;
      }
      setState(() {
        if (widget.maintainState) {
          _offstage = true;
        } else {
          _showChild = false;
        }
      });
    });
  }

  void _updateDurations() {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    _controller
      ..duration = reduceMotion
          ? Duration.zero
          : _scaledDuration(Motion.desktopPanelOpen, widget.durationScale)
      ..reverseDuration = reduceMotion
          ? Duration.zero
          : _scaledDuration(Motion.desktopPanelClose, widget.durationScale);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_showChild) {
      return const SizedBox.shrink();
    }

    Widget panel = ShellInputRegion(
      active: !_offstage,
      debugLabel: widget.inputDebugLabel,
      keyboardPolicy: widget.visible
          ? widget.keyboardPolicy
          : ShellKeyboardPolicy.none,
      child: IgnorePointer(
        ignoring: !widget.visible,
        child: ExcludeSemantics(
          excluding: !widget.visible,
          child: AnimatedBuilder(
            animation: _progress,
            child: RepaintBoundary(
              child: ShellBackdropBlur(
                blur: ShellTheme.of(context).panelOpacity < 1.0,
                borderRadius: BorderRadius.circular(
                  ShellTheme.of(context).panelRadius,
                ),
                child: widget.child,
              ),
            ),
            builder: (context, child) {
              final progress = _progress.value;
              return LayoutBuilder(
                builder: (context, constraints) {
                  final direction = widget.entryDirection;
                  final travel = Offset(
                    direction.dx *
                        (constraints.maxWidth + widget.entryDistance),
                    direction.dy *
                        (constraints.maxHeight + widget.entryDistance),
                  );
                  return Transform.translate(
                    offset: travel * (1.0 - progress),
                    child: child,
                  );
                },
              );
            },
          ),
        ),
      ),
    );
    if (widget.maintainState) {
      panel = TickerMode(
        enabled: !_offstage,
        child: Offstage(offstage: _offstage, child: panel),
      );
    }
    return panel;
  }
}

Duration _scaledDuration(Duration duration, double scale) {
  return Duration(microseconds: (duration.inMicroseconds * scale).round());
}
