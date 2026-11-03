import 'package:denial_flutter_sdk/materials.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:flutter/material.dart';

import 'glass.dart';

/// Hover and press feedback over a toolbar material, without transitions.
Color pressOverlay(DenialApplicationColors colors, PressState state) =>
    state.pressed
    ? colors.foreground.withValues(alpha: .1)
    : state.hovered
    ? colors.foreground.withValues(alpha: .06)
    : Colors.transparent;

class PressState {
  const PressState({
    required this.enabled,
    required this.hovered,
    required this.pressed,
    required this.focused,
  });

  final bool enabled;
  final bool hovered;
  final bool pressed;
  final bool focused;
}

/// Pointer, keyboard and focus behavior shared by the prompt's controls.
class Pressable extends StatefulWidget {
  const Pressable({
    required this.onPressed,
    required this.builder,
    this.onActivate,
    this.onDoubleTap,
    this.onFocus,
    this.autofocus = false,
    this.semanticLabel,
  });

  final VoidCallback? onPressed;

  /// Keyboard activation, when it differs from a pointer press.
  final VoidCallback? onActivate;
  final VoidCallback? onDoubleTap;
  final VoidCallback? onFocus;
  final bool autofocus;
  final String? semanticLabel;
  final Widget Function(BuildContext context, PressState state) builder;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel,
      child: FocusableActionDetector(
        enabled: enabled,
        autofocus: widget.autofocus,
        mouseCursor: enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              (widget.onActivate ?? widget.onPressed)?.call();
              return null;
            },
          ),
        },
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        onFocusChange: (focused) {
          if (focused) widget.onFocus?.call();
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
          onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
          onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
          onTap: widget.onPressed,
          onDoubleTap: widget.onDoubleTap,
          child: widget.builder(
            context,
            PressState(
              enabled: enabled,
              hovered: enabled && _hovered,
              pressed: enabled && _pressed,
              focused: enabled && _focused,
            ),
          ),
        ),
      ),
    );
  }
}

/// An action on the floating toolbar material, like application toolbar
/// actions. The primary action is told apart by its accent label alone.
class PromptButton extends StatelessWidget {
  const PromptButton({
    required this.label,
    required this.onPressed,
    this.primary = false,
    this.held = false,
    this.autofocus = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool primary;

  /// Inert, but drawn as available, while the agent verifies a reply.
  final bool held;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final palette = PromptPalette.of(ShellTheme.of(context));
    final colors = context.applicationColors;
    const inset = DenialApplicationFrame.defaultInset;
    return Pressable(
      onPressed: onPressed,
      autofocus: autofocus,
      semanticLabel: label,
      builder: (context, state) {
        final color = colors.foreground;
        return CustomPaint(
          foregroundPainter: state.focused
              ? OutlinePainter(
                  borderRadius: DenialSurfaceGeometry.borderRadiusOf(
                    context,
                    inset: inset,
                  ),
                  color: palette.accent,
                  outset: 2.5,
                )
              : null,
          child: DenialMaterial(
            role: DenialMaterialRole.toolbar,
            floating: true,
            inset: inset,
            child: Container(
              height: 44,
              constraints: const BoxConstraints(minWidth: 84),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              color: Color.alphaBlend(
                pressOverlay(colors, state),
                primary
                    ? palette.accent.withValues(alpha: .28)
                    : Colors.transparent,
              ),
              alignment: Alignment.center,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: state.enabled || held
                      ? color
                      : color.withValues(alpha: color.a * .45),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
