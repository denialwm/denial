import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../localization/denial_localizations.dart';
import '../../theme/motion.dart';
import '../../theme/tokens.dart';
import '../../widgets/shell_cursor.dart';
import '../color_format.dart';

class HsvColorWheel extends StatefulWidget {
  const HsvColorWheel({
    super.key,
    required this.color,
    required this.onChanged,
  });

  final Color color;
  final ValueChanged<Color> onChanged;

  @override
  State<HsvColorWheel> createState() => _HsvColorWheelState();
}

class _HsvColorWheelState extends State<HsvColorWheel> {
  static const double _hueStep = 3.0;
  static const double _saturationStep = 0.04;

  final FocusNode _focusNode = FocusNode(debugLabel: 'hsv-color-wheel');
  var _focused = false;

  HSVColor get _hsv => HSVColor.fromColor(widget.color);

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _select(Offset position, Size size) {
    final center = size.center(Offset.zero);
    final vector = position - center;
    final radius = size.shortestSide / 2.0;
    if (radius <= 0.0 || vector.distance > radius) {
      return;
    }
    final hue =
        (math.atan2(vector.dy, vector.dx) * 180.0 / math.pi + 360.0) % 360.0;
    final saturation = (vector.distance / radius).clamp(0.0, 1.0);
    widget.onChanged(
      HSVColor.fromAHSV(1.0, hue, saturation, _hsv.value).toColor(),
    );
  }

  void _adjust({double hue = 0.0, double saturation = 0.0}) {
    final current = _hsv;
    widget.onChanged(
      current
          .withHue((current.hue + hue + 360.0) % 360.0)
          .withSaturation(
            (current.saturation + saturation).clamp(0.0, 1.0),
          )
          .toColor(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hex = formatOpaqueColorHex(widget.color);
    final l10n = context.l10n;
    return Semantics(
      excludeSemantics: true,
      slider: true,
      label: l10n.settingsColorWheelSemanticsLabel,
      value: hex,
      increasedValue: l10n.settingsColorWheelNextHue,
      decreasedValue: l10n.settingsColorWheelPreviousHue,
      onIncrease: () => _adjust(hue: _hueStep),
      onDecrease: () => _adjust(hue: -_hueStep),
      child: FocusableActionDetector(
        focusNode: _focusNode,
        mouseCursor: ShellMouseCursors.precision,
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.arrowLeft):
              _ColorWheelAdjustmentIntent(hue: -_hueStep),
          SingleActivator(LogicalKeyboardKey.arrowRight):
              _ColorWheelAdjustmentIntent(hue: _hueStep),
          SingleActivator(LogicalKeyboardKey.arrowDown):
              _ColorWheelAdjustmentIntent(saturation: -_saturationStep),
          SingleActivator(LogicalKeyboardKey.arrowUp):
              _ColorWheelAdjustmentIntent(saturation: _saturationStep),
        },
        actions: <Type, Action<Intent>>{
          _ColorWheelAdjustmentIntent:
              CallbackAction<_ColorWheelAdjustmentIntent>(
            onInvoke: (intent) {
              _adjust(hue: intent.hue, saturation: intent.saturation);
              return null;
            },
          ),
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = Size.square(constraints.biggest.shortestSide);
            return Center(
              child: RepaintBoundary(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) {
                    _focusNode.requestFocus();
                    _select(details.localPosition, size);
                  },
                  onPanStart: (details) {
                    _focusNode.requestFocus();
                    _select(details.localPosition, size);
                  },
                  onPanUpdate: (details) =>
                      _select(details.localPosition, size),
                  child: AnimatedContainer(
                    duration: Motion.tile,
                    curve: Motion.standard,
                    width: size.width,
                    height: size.height,
                    padding: EdgeInsets.all(_focused ? 3.0 : 4.0),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _focused
                            ? ShellColors.accent
                            : ShellColors.hairline,
                      ),
                    ),
                    child: CustomPaint(
                      painter: HsvColorWheelPainter(color: widget.color),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class HsvColorWheelPainter extends CustomPainter {
  const HsvColorWheelPainter({required this.color});

  final Color color;

  static const List<Color> _hues = <Color>[
    // These are the mathematical RGB gamut stops, not interface tokens.
    Color(0xffff0000),
    Color(0xffffff00),
    Color(0xff00ff00),
    Color(0xff00ffff),
    Color(0xff0000ff),
    Color(0xffff00ff),
    Color(0xffff0000),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2.0;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final hsv = HSVColor.fromColor(color);

    canvas
      ..save()
      ..clipPath(Path()..addOval(rect))
      ..drawCircle(
        center,
        radius,
        Paint()..shader = const SweepGradient(colors: _hues).createShader(rect),
      )
      ..drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: <Color>[
              Colors.white,
              Colors.white.withAlpha(0),
            ],
          ).createShader(rect),
      );
    if (hsv.value < 1.0) {
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = Colors.black.withAlpha(((1.0 - hsv.value) * 255).round()),
      );
    }
    canvas.restore();

    final angle = hsv.hue * math.pi / 180.0;
    final selectionRadius = math.max(0.0, radius - 8.0);
    final indicator = center +
        Offset(math.cos(angle), math.sin(angle)) *
            (hsv.saturation * selectionRadius);
    canvas
      ..drawCircle(
        indicator,
        7.0,
        Paint()..color = ShellColors.shadow,
      )
      ..drawCircle(
        indicator,
        6.0,
        Paint()..color = ShellColors.textPrimary,
      )
      ..drawCircle(
        indicator,
        3.5,
        Paint()..color = color,
      );
  }

  @override
  bool shouldRepaint(covariant HsvColorWheelPainter oldDelegate) {
    return color != oldDelegate.color;
  }
}

class _ColorWheelAdjustmentIntent extends Intent {
  const _ColorWheelAdjustmentIntent({this.hue = 0.0, this.saturation = 0.0});

  final double hue;
  final double saturation;
}
