import 'dart:async';

import 'package:denial_flutter_sdk/effects.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_sdk/input.dart';
import 'package:flutter/widgets.dart';

/// A deck element on the shell's panel material: the same backdrop, backing
/// gradient, outline and roundness as panels, HUDs and notifications.
///
/// Deck elements never overlap, so they share one engine blur through the
/// [BackdropGroup] that the deck installs above them.
class InputDeckGlass extends StatelessWidget {
  const InputDeckGlass({required this.radius, required this.child, super.key});

  /// Base corner radius; the theme's roundness scale is applied.
  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    final borderRadius = theme.borderRadius(radius);
    return ShellBackdropBlur(
      grouped: true,
      separateChild: true,
      blur: theme.effectivePanelOpacity < 1.0,
      borderRadius: borderRadius,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: theme.panelGradient(
            colors.panelBackground,
            colors.panelBackgroundBottom,
          ),
        ),
        // The outline stays above content tints such as pressed zones.
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            border: Border.all(color: colors.hairline),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Raw contacts allow chords and release keys on cancellation and disposal.
///
/// [builder] receives the press highlight: it rises immediately on contact
/// and fades after the last contact lifts, so quick taps stay visible.
class DeckKeyButton extends StatefulWidget {
  const DeckKeyButton({
    required this.label,
    required this.onTransition,
    required this.builder,
    this.activateOnDown,
    this.onCancelled,
    super.key,
  });
  final String label;
  final ValueChanged<bool> onTransition;
  final Widget Function(BuildContext context, Animation<double> pressed)
  builder;
  final bool Function()? activateOnDown;
  final VoidCallback? onCancelled;

  @override
  State<DeckKeyButton> createState() => _DeckKeyButtonState();
}

class _DeckKeyButtonState extends State<DeckKeyButton>
    with SingleTickerProviderStateMixin {
  static const _minimumVisible = Duration(milliseconds: 90);
  static const _fadeOut = Duration(milliseconds: 220);

  late final _pressed = AnimationController(vsync: this);
  Timer? _holdTimer;
  Timer? _releaseTimer;
  DateTime? _pressedAt;
  bool _reduceMotion = false;
  late final _contacts = TouchKeyGesture(
    transition: (pressed, cancelled) {
      if (cancelled && !pressed && widget.onCancelled != null) {
        widget.onCancelled!();
      } else {
        widget.onTransition(pressed);
      }
    },
  );

  @override
  void dispose() {
    _holdTimer?.cancel();
    _releaseTimer?.cancel();
    _contacts.cancel();
    _pressed.dispose();
    super.dispose();
  }

  void _highlight() {
    _releaseTimer?.cancel();
    _pressedAt = DateTime.now();
    _pressed
      ..stop()
      ..value = 1;
  }

  void _settle() {
    final visible = DateTime.now().difference(_pressedAt ?? DateTime.now());
    final remaining = _minimumVisible - visible;
    void fade() => _pressed.animateTo(
      0,
      duration: _reduceMotion ? Duration.zero : _fadeOut,
      curve: Curves.easeOutCubic,
    );
    if (remaining <= Duration.zero) {
      fade();
    } else {
      _releaseTimer = Timer(remaining, fade);
    }
  }

  void _end(int pointer, {bool cancelled = false}) {
    _contacts.up(pointer, cancelled: cancelled);
    if (_contacts.hasContacts) return;
    _holdTimer?.cancel();
    _settle();
  }

  @override
  Widget build(BuildContext context) {
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      button: true,
      label: widget.label,
      onTap: () {
        widget.onTransition(true);
        widget.onTransition(false);
      },
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          final immediate = widget.activateOnDown?.call() ?? true;
          final wasActive = _contacts.hasContacts;
          _contacts.down(
            event.pointer,
            event.localPosition.dx,
            event.localPosition.dy,
            immediate: immediate,
          );
          if (!wasActive && !immediate) {
            _holdTimer = Timer(
              const Duration(milliseconds: 150),
              _contacts.hold,
            );
          }
          _highlight();
        },
        onPointerMove: (event) => _contacts.move(
          event.pointer,
          event.localPosition.dx,
          event.localPosition.dy,
        ),
        onPointerUp: (event) => _end(event.pointer),
        onPointerCancel: (event) => _end(event.pointer, cancelled: true),
        child: widget.builder(context, _pressed),
      ),
    );
  }
}
