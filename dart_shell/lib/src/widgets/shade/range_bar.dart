import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../../theme/shell_theme.dart';

/// A pill-shaped horizontal slider used for brightness and volume. Tapping or
/// dragging anywhere along the track sets the value.
class RangeBar extends StatefulWidget {
  const RangeBar({
    super.key,
    required this.icon,
    required this.value,
    required this.activeColor,
    required this.inactiveColor,
    required this.onChanged,
    required this.onChangeEnd,
    required this.height,
    this.onChangeStart,
  });

  final IconData icon;
  final double value;
  final Color activeColor;
  final Color inactiveColor;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final double height;
  final VoidCallback? onChangeStart;

  @override
  State<RangeBar> createState() => _RangeBarState();
}

class _RangeBarState extends State<RangeBar> {
  static const _wheelStep = 0.05;

  double? _gestureValue;

  double get _displayValue =>
      (_gestureValue ?? widget.value).clamp(0.0, 1.0).toDouble();

  void _updateFromPosition(Offset position, double width) {
    if (width <= 0) {
      return;
    }
    if (_gestureValue == null) {
      widget.onChangeStart?.call();
    }
    final next = (position.dx / width).clamp(0.0, 1.0).toDouble();
    setState(() {
      _gestureValue = next;
    });
    widget.onChanged(next);
  }

  void _startRelativeGesture() {
    if (_gestureValue != null) {
      return;
    }
    widget.onChangeStart?.call();
    setState(() {
      _gestureValue = widget.value.clamp(0.0, 1.0).toDouble();
    });
  }

  void _updateFromDelta(double delta, double width) {
    if (width <= 0) {
      return;
    }
    _startRelativeGesture();
    final next = (_gestureValue! + delta / width).clamp(0.0, 1.0).toDouble();
    setState(() {
      _gestureValue = next;
    });
    widget.onChanged(next);
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) {
      return;
    }
    final delta = event.scrollDelta;
    final direction = delta.dy.abs() >= delta.dx.abs()
        ? -delta.dy.sign
        : delta.dx.sign;
    if (direction == 0) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      final current = widget.value.clamp(0.0, 1.0).toDouble();
      final next = (current + direction * _wheelStep)
          .clamp(0.0, 1.0)
          .toDouble();
      if (next == current) {
        return;
      }
      widget.onChangeStart?.call();
      widget.onChanged(next);
      widget.onChangeEnd(next);
    });
  }

  void _endGesture() {
    final value = _gestureValue;
    if (value == null) {
      return;
    }
    widget.onChangeEnd(value);
    if (!mounted) {
      return;
    }
    setState(() {
      _gestureValue = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final clamped = _displayValue;
        return Listener(
          onPointerSignal: _handlePointerSignal,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) {
              _updateFromPosition(details.localPosition, constraints.maxWidth);
            },
            onTapUp: (details) {
              _updateFromPosition(details.localPosition, constraints.maxWidth);
              _endGesture();
            },
            onTapCancel: _endGesture,
            onHorizontalDragStart: (details) {
              if (details.kind == PointerDeviceKind.trackpad) {
                _startRelativeGesture();
              } else {
                _updateFromPosition(
                  details.localPosition,
                  constraints.maxWidth,
                );
              }
            },
            onHorizontalDragUpdate: (details) {
              if (details.kind == PointerDeviceKind.trackpad) {
                _updateFromDelta(
                  details.primaryDelta ?? 0,
                  constraints.maxWidth,
                );
              } else {
                _updateFromPosition(
                  details.localPosition,
                  constraints.maxWidth,
                );
              }
            },
            onHorizontalDragEnd: (_) => _endGesture(),
            onHorizontalDragCancel: _endGesture,
            child: SizedBox(
              height: widget.height,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: widget.inactiveColor,
                  borderRadius: context.shellTheme.borderRadius(
                    widget.height / 2,
                  ),
                  border: Border.all(color: context.shellColors.hairlineSoft),
                ),
                child: ClipRRect(
                  borderRadius: context.shellTheme.borderRadius(
                    widget.height / 2,
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: clamped,
                        child: ColoredBox(color: widget.activeColor),
                      ),
                      Positioned(
                        top: 6,
                        bottom: 6,
                        left: (constraints.maxWidth * clamped - 2).clamp(
                          16.0,
                          constraints.maxWidth - 18.0,
                        ),
                        width: 5,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: context.shellColors.sliderThumb,
                            borderRadius: context.shellTheme.borderRadius(4),
                          ),
                        ),
                      ),
                      Positioned(
                        right: 15,
                        top: 0,
                        bottom: 0,
                        child: Icon(
                          widget.icon,
                          color: clamped > 0.72
                              ? context.shellTheme.accentPalette.onPrimary
                              : context.shellColors.panelText,
                          size: 25,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
