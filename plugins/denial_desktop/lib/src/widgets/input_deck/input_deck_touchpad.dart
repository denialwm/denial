import 'dart:math' as math;

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_sdk/input.dart';
import 'package:denial_flutter_sdk/platform.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'input_deck_surface.dart';

/// A clickpad: the tracking surface above, left and right click zones along
/// its lower edge. The zones hold their buttons independently of surface
/// taps, so a resting thumb and a moving finger drag like on a laptop.
class InputDeckTouchpad extends StatefulWidget {
  const InputDeckTouchpad({
    required this.bridge,
    required this.settings,
    super.key,
  });
  final DenialBridge bridge;
  final InputDeckSettings settings;

  @override
  State<InputDeckTouchpad> createState() => _InputDeckTouchpadState();
}

class _InputDeckTouchpadState extends State<InputDeckTouchpad>
    with SingleTickerProviderStateMixin {
  late final _contacts = _ContactGlow(this);
  late final _gestures = TouchpadGesture(
    motion: (dx, dy) => widget.bridge.moveInputDeckPointer(
      dx * widget.settings.pointerSpeed,
      dy * widget.settings.pointerSpeed,
    ),
    scroll: (dx, dy, stop) {
      final direction = widget.settings.naturalScroll ? -1.0 : 1.0;
      widget.bridge.scrollInputDeck(dx * direction, dy * direction, stop: stop);
    },
    button: (button, pressed) => widget.bridge.inputDeckButton(button, pressed),
  );

  @override
  void dispose() {
    _gestures.cancel();
    _contacts.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = context.shellColors;
    return InputDeckGlass(
      radius: 24,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final zone = (constraints.maxHeight * 0.2)
              .clamp(44.0, 84.0)
              .clamp(0.0, constraints.maxHeight * 0.4);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _surface(context)),
              ColoredBox(
                color: colors.hairlineSoft,
                child: const SizedBox(height: 1),
              ),
              SizedBox(
                height: math.max(0, zone - 1),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _ClickZone(
                        label: l10n.inputDeckLeftClick,
                        onTransition: (pressed) => widget.bridge
                            .inputDeckButton(0x110, pressed, source: 1),
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: zone * 0.22),
                      child: ColoredBox(
                        color: colors.hairlineSoft,
                        child: const SizedBox(width: 1),
                      ),
                    ),
                    Expanded(
                      child: _ClickZone(
                        label: l10n.inputDeckRightClick,
                        onTransition: (pressed) => widget.bridge
                            .inputDeckButton(0x111, pressed, source: 1),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _surface(BuildContext context) => Semantics(
    label: context.l10n.inputDeckTouchpadHint,
    child: Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        if (event.kind != PointerDeviceKind.touch) return;
        _contacts.down(event.pointer, event.localPosition);
        _gestures.down(
          event.pointer,
          event.localPosition.dx,
          event.localPosition.dy,
          event.timeStamp,
        );
      },
      onPointerMove: (event) {
        _contacts.move(event.pointer, event.localPosition);
        _gestures.move(
          event.pointer,
          event.localPosition.dx,
          event.localPosition.dy,
        );
      },
      onPointerUp: (event) {
        _contacts.up(event.pointer);
        _gestures.up(event.pointer, event.timeStamp);
      },
      onPointerCancel: (event) {
        _contacts.up(event.pointer);
        _gestures.up(event.pointer, event.timeStamp, cancelled: true);
      },
      child: ClipRect(
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _ContactPainter(
              _contacts,
              context.shellTheme.accentPalette.primary,
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    ),
  );
}

/// One click zone. A small rest mark identifies the button and lights up
/// with the zone while it is held.
class _ClickZone extends StatelessWidget {
  const _ClickZone({required this.label, required this.onTransition});
  final String label;
  final ValueChanged<bool> onTransition;

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    final accent = context.shellTheme.accentPalette;
    return DeckKeyButton(
      label: label,
      onTransition: onTransition,
      builder: (context, pressed) => AnimatedBuilder(
        animation: pressed,
        builder: (context, _) {
          final t = pressed.value;
          return ColoredBox(
            color: accent.container.withValues(alpha: 0.55 * t),
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Color.lerp(
                    colors.textTertiary.withValues(alpha: 0.35),
                    accent.primary,
                    t,
                  ),
                  borderRadius: const BorderRadius.all(Radius.circular(2)),
                ),
                child: const SizedBox(width: 24, height: 3),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Soft light under each finger on the surface, fading after it lifts.
/// Contacts repaint only the painter; nothing rebuilds per pointer move.
class _ContactGlow extends ChangeNotifier {
  _ContactGlow(TickerProvider vsync) {
    _ticker = vsync.createTicker((_) => _advance());
  }

  static const _fade = Duration(milliseconds: 220);
  final _clock = Stopwatch()..start();
  final _contacts = <int, _Contact>{};
  late final Ticker _ticker;

  void down(int pointer, Offset position) {
    _contacts[pointer] = _Contact(position);
    notifyListeners();
  }

  void move(int pointer, Offset position) {
    final contact = _contacts[pointer];
    if (contact == null || contact.releasedAt != null) return;
    contact.position = position;
    notifyListeners();
  }

  void up(int pointer) {
    final contact = _contacts[pointer];
    if (contact == null || contact.releasedAt != null) return;
    contact.releasedAt = _clock.elapsed;
    if (!_ticker.isActive) _ticker.start();
  }

  void _advance() {
    final now = _clock.elapsed;
    _contacts.removeWhere(
      (_, contact) =>
          contact.releasedAt != null && now - contact.releasedAt! >= _fade,
    );
    if (!_contacts.values.any((contact) => contact.releasedAt != null)) {
      _ticker.stop();
    }
    notifyListeners();
  }

  void paint(Canvas canvas, Color color) {
    final now = _clock.elapsed;
    for (final contact in _contacts.values) {
      final released = contact.releasedAt;
      final strength = released == null
          ? 1.0
          : 1 - (now - released).inMicroseconds / _fade.inMicroseconds;
      if (strength <= 0) continue;
      final bounds = Rect.fromCircle(center: contact.position, radius: 56);
      canvas.drawCircle(
        contact.position,
        56,
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: 0.30 * strength),
              color.withValues(alpha: 0.10 * strength),
              color.withValues(alpha: 0),
            ],
            stops: const [0, 0.45, 1],
          ).createShader(bounds),
      );
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}

class _Contact {
  _Contact(this.position);
  Offset position;
  Duration? releasedAt;
}

class _ContactPainter extends CustomPainter {
  _ContactPainter(this.contacts, this.color) : super(repaint: contacts);
  final _ContactGlow contacts;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) => contacts.paint(canvas, color);

  @override
  bool shouldRepaint(_ContactPainter oldDelegate) =>
      contacts != oldDelegate.contacts || color != oldDelegate.color;
}
