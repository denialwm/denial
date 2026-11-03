import 'dart:io';
import 'dart:math' as math;

import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'glass.dart';

/// A dialog card, centered in a transparent overlay canvas.
///
/// Layers, from the desktop up: compositor glass under the card, then the
/// card's translucent body and rim, then [child].
class PromptCanvas extends StatefulWidget {
  const PromptCanvas({
    required this.revealed,
    required this.child,
    this.shake,
    super.key,
  });

  /// Hidden, not faded, until the card's final colors are known.
  final bool revealed;

  /// Shakes the card sideways from 0 to 1, on the desktop only.
  final Animation<double>? shake;
  final Widget child;

  @override
  State<PromptCanvas> createState() => _PromptCanvasState();
}

class _PromptCanvasState extends State<PromptCanvas> {
  static const _cardWidth = 520.0;
  static const _canvasMargin = 28.0;

  /// On a phone the shell frosts the whole overlay as one card, the way it
  /// frosts windows. The card then fills the surface, which follows the
  /// card's height.
  static final _phone =
      Platform.environment['DENIAL_SHELL_PROFILE'] == 'mobile';
  static const _overlay = MethodChannel('denial/overlay', JSONMethodCodec());
  final _cardKey = GlobalKey();
  Size? _fitted;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final palette = PromptPalette.of(theme);
    final radius = BorderRadius.circular(theme.panelRadius.clamp(8.0, 44.0));
    final fontFamily = theme.fontFamily.isEmpty ? null : theme.fontFamily;

    final card = CustomPaint(
      painter: _phone
          ? null
          : CardShadowPainter(palette: palette, borderRadius: radius),
      child: CustomPaint(
        painter: CardPainter(palette: palette, borderRadius: radius),
        foregroundPainter: RimPainter(
          borderRadius: radius,
          top: palette.rimTop.withValues(alpha: palette.rimTop.a * .5),
          bottom: palette.rimTop.withValues(alpha: palette.rimTop.a * .5),
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
            child: widget.child,
          ),
        ),
      ),
    );

    final shown = IgnorePointer(
      ignoring: !widget.revealed,
      child: Opacity(opacity: widget.revealed ? 1 : 0, child: card),
    );

    return DefaultTextStyle(
      style: TextStyle(
        fontFamily: fontFamily,
        fontFamilyFallback: ShellText.fallbackFontFamilies,
        fontSize: 14,
        color: palette.foreground,
        decoration: TextDecoration.none,
      ),
      child: _phone ? _phoneCanvas(shown) : _desktopCanvas(shown),
    );
  }

  /// The card, centered in the overlay's fixed canvas. An unusually long
  /// message scrolls rather than overflowing it.
  Widget _desktopCanvas(Widget card) {
    final shake = widget.shake;
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: _canvasMargin),
              child: SizedBox(
                width: math.max(
                  0,
                  math.min(
                    _cardWidth,
                    constraints.maxWidth - _canvasMargin * 2,
                  ),
                ),
                child: shake == null
                    ? card
                    : AnimatedBuilder(
                        animation: shake,
                        builder: (context, card) {
                          final t = shake.value;
                          return Transform.translate(
                            offset: Offset(
                              10 * math.sin(t * math.pi * 6) * (1 - t),
                              0,
                            ),
                            child: card,
                          );
                        },
                        child: card,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The card as the whole overlay, which takes the card's height once it
  /// is laid out. It stays still: the shell's glass under it does not shake.
  Widget _phoneCanvas(Widget card) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _fit());
    return SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      child: KeyedSubtree(key: _cardKey, child: card),
    );
  }

  void _fit() {
    final size = _cardKey.currentContext?.size;
    if (!mounted || size == null || size.isEmpty || size == _fitted) return;
    _fitted = size;
    _overlay
        .invokeMethod<void>('resize', [size.width, size.height])
        .catchError((Object _) {});
  }
}
