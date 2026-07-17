import 'package:flutter/widgets.dart';

import '../../theme/tokens.dart';

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
        return GestureDetector(
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
            _updateFromPosition(details.localPosition, constraints.maxWidth);
          },
          onHorizontalDragUpdate: (details) {
            _updateFromPosition(details.localPosition, constraints.maxWidth);
          },
          onHorizontalDragEnd: (_) => _endGesture(),
          onHorizontalDragCancel: _endGesture,
          child: SizedBox(
            height: widget.height,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: widget.inactiveColor,
                borderRadius: BorderRadius.circular(widget.height / 2),
                border: Border.all(color: ShellColors.hairlineSoft),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(widget.height / 2),
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
                      left: (constraints.maxWidth * clamped - 2)
                          .clamp(16.0, constraints.maxWidth - 18.0),
                      width: 5,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: ShellColors.sliderThumb,
                          borderRadius: BorderRadius.circular(4),
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
                            ? ShellColors.sliderIconDark
                            : ShellColors.panelText,
                        size: 25,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
