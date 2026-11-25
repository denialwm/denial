import 'package:denial_flutter_sdk/rendering.dart' show ShellMouseCursors;
import 'package:flutter/widgets.dart';

import 'frame_colors.dart';

enum CaptionGlyph { minimize, maximize, restore, close }

/// One of the buttons at the right end of the title bar.
class CaptionButton extends StatefulWidget {
  const CaptionButton({
    required this.glyph,
    required this.label,
    required this.colors,
    required this.onPressed,
    super.key,
  });

  static const width = 46.0;

  final CaptionGlyph glyph;
  final String label;
  final WindowFrameColors colors;
  final VoidCallback onPressed;

  @override
  State<CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<CaptionButton> {
  bool _hovered = false;
  bool _pressed = false;

  void _set({bool? hovered, bool? pressed}) {
    final nextHovered = hovered ?? _hovered;
    final nextPressed = pressed ?? _pressed;
    if (nextHovered == _hovered && nextPressed == _pressed) {
      return;
    }
    setState(() {
      _hovered = nextHovered;
      _pressed = nextPressed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final close = widget.glyph == CaptionGlyph.close;
    final colors = widget.colors;
    final Color? background;
    if (_pressed) {
      background = close ? WindowFrameColors.closePressed : colors.pressed;
    } else if (_hovered) {
      background = close ? WindowFrameColors.closeHover : colors.hover;
    } else {
      background = null;
    }
    final glyphColor = close && (_hovered || _pressed)
        ? WindowFrameColors.closeGlyph
        : colors.text;
    return Semantics(
      button: true,
      label: widget.label,
      onTap: widget.onPressed,
      child: MouseRegion(
        cursor: ShellMouseCursors.normal,
        onEnter: (_) => _set(hovered: true),
        onExit: (_) => _set(hovered: false, pressed: false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _set(pressed: true),
          onTapCancel: () => _set(pressed: false),
          onTap: () {
            _set(pressed: false);
            widget.onPressed();
          },
          child: SizedBox(
            width: CaptionButton.width,
            child: CustomPaint(
              painter: _CaptionGlyphPainter(
                glyph: widget.glyph,
                color: glyphColor,
                background: background,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CaptionGlyphPainter extends CustomPainter {
  const _CaptionGlyphPainter({
    required this.glyph,
    required this.color,
    required this.background,
  });

  /// The glyph's side, in logical pixels.
  static const _side = 10.0;

  final CaptionGlyph glyph;
  final Color color;
  final Color? background;

  @override
  void paint(Canvas canvas, Size size) {
    if (background case final background?) {
      canvas.drawRect(Offset.zero & size, Paint()..color = background);
    }
    // Half-pixel coordinates put one-pixel strokes on whole pixels.
    final left = ((size.width - _side) / 2.0).floorToDouble() + 0.5;
    final top = ((size.height - _side) / 2.0).floorToDouble() + 0.5;
    final right = left + _side - 1.0;
    final bottom = top + _side - 1.0;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    switch (glyph) {
      case CaptionGlyph.minimize:
        final middle = top + (_side / 2.0).floorToDouble();
        canvas.drawLine(Offset(left, middle), Offset(right, middle), stroke);
      case CaptionGlyph.maximize:
        canvas.drawRect(Rect.fromLTRB(left, top, right, bottom), stroke);
      case CaptionGlyph.restore:
        // A window in front of another: the front one whole, and the two
        // sides of the back one that show past it.
        canvas.drawRect(
          Rect.fromLTRB(left, top + 2.0, right - 2.0, bottom),
          stroke,
        );
        canvas.drawPath(
          Path()
            ..moveTo(left + 2.0, top + 2.0)
            ..lineTo(left + 2.0, top)
            ..lineTo(right, top)
            ..lineTo(right, bottom - 2.0)
            ..lineTo(right - 2.0, bottom - 2.0),
          stroke,
        );
      case CaptionGlyph.close:
        final cross = stroke..isAntiAlias = true;
        canvas.drawLine(Offset(left, top), Offset(right, bottom), cross);
        canvas.drawLine(Offset(right, top), Offset(left, bottom), cross);
    }
  }

  @override
  bool shouldRepaint(covariant _CaptionGlyphPainter oldDelegate) =>
      glyph != oldDelegate.glyph ||
      color != oldDelegate.color ||
      background != oldDelegate.background;
}
