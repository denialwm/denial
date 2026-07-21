import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../localization/denial_localizations.dart';
import '../../theme/motion.dart';
import '../../theme/tokens.dart';
import '../../widgets/shell_cursor.dart';
import '../color_format.dart';
import 'hsv_color_wheel.dart';

const settingsFocusedBorderColorPickerKey = ValueKey<String>(
  'settings-focused-border-color-picker',
);
const settingsFocusedBorderResetKey = ValueKey<String>(
  'settings-focused-border-reset',
);

class FocusedBorderColorPicker extends StatelessWidget {
  const FocusedBorderColorPicker({
    super.key,
    required this.color,
    required this.onChanged,
    required this.onReset,
    required this.onClose,
  });

  final Color color;
  final ValueChanged<Color> onChanged;
  final VoidCallback onReset;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          onClose();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onClose,
            child: const ColoredBox(color: ShellColors.overviewScrim),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final panelWidth = math.min(360.0, constraints.maxWidth - 32.0);
              final panelHeight = math.min(410.0, constraints.maxHeight - 32.0);
              final wheelSize = math.max(
                128.0,
                math.min(220.0, panelHeight - 174.0),
              );
              return Center(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  child: SizedBox(
                    width: panelWidth,
                    height: panelHeight,
                    child: _ColorPickerPanel(
                      color: color,
                      wheelSize: wheelSize,
                      onChanged: onChanged,
                      onReset: onReset,
                      onClose: onClose,
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ColorPickerPanel extends StatelessWidget {
  const _ColorPickerPanel({
    required this.color,
    required this.wheelSize,
    required this.onChanged,
    required this.onReset,
    required this.onClose,
  });

  final Color color;
  final double wheelSize;
  final ValueChanged<Color> onChanged;
  final VoidCallback onReset;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final hex = formatOpaqueColorHex(color);
    final l10n = context.l10n;
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      role: .dialog,
      label: l10n.settingsColorPickerRouteLabel,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: ShellColors.panelBackgroundBottom,
          borderRadius: BorderRadius.circular(ShellRadii.panel),
          border: Border.all(color: ShellColors.hairline),
          boxShadow: const [
            BoxShadow(
              color: ShellColors.shadow,
              blurRadius: 36,
              spreadRadius: 3,
              offset: Offset(0, 16),
            ),
          ],
        ),
        child: FocusTraversalGroup(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
            child: Column(
              children: [
                _PickerHeader(color: color, hex: hex, onClose: onClose),
                const SizedBox(height: 12),
                SizedBox.square(
                  dimension: wheelSize,
                  child: HsvColorWheel(color: color, onChanged: onChanged),
                ),
                const Spacer(),
                Text(
                  l10n.settingsColorPickerInstructions,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ShellText.cardTitle.copyWith(
                    color: ShellColors.textTertiary,
                    fontSize: 10,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _PickerButton(
                      key: settingsFocusedBorderResetKey,
                      label: l10n.settingsColorPickerReset,
                      onPressed: onReset,
                    ),
                    const Spacer(),
                    _PickerButton(
                      label: l10n.settingsColorPickerDone,
                      prominent: true,
                      onPressed: onClose,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PickerHeader extends StatelessWidget {
  const _PickerHeader({
    required this.color,
    required this.hex,
    required this.onClose,
  });

  final Color color;
  final String hex;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Row(
      children: [
        AnimatedContainer(
          duration: Motion.tile,
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: ShellColors.panelHighlight),
          ),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.settingsColorPickerTitle, style: ShellText.cardTitle),
              const SizedBox(height: 2),
              Text(
                hex,
                style: ShellText.cardTitle.copyWith(
                  color: ShellColors.textSecondary,
                  fontFamily: ShellText.systemBarFontFamily,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
        _PickerIconButton(
          icon: Icons.close_rounded,
          semanticsLabel: l10n.settingsColorPickerCloseSemanticsLabel,
          onPressed: onClose,
        ),
      ],
    );
  }
}

class _PickerButton extends StatefulWidget {
  const _PickerButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.prominent = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool prominent;

  @override
  State<_PickerButton> createState() => _PickerButtonState();
}

class _PickerButtonState extends State<_PickerButton> {
  var _hovered = false;
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final highlighted = _hovered || _focused;
    return Semantics(
      button: true,
      label: widget.label,
      child: FocusableActionDetector(
        mouseCursor: ShellMouseCursors.link,
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: Motion.tile,
            curve: Motion.standard,
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: widget.prominent
                  ? highlighted
                        ? ShellColors.onPrimaryContainer
                        : ShellColors.accent
                  : highlighted
                  ? ShellColors.surfaceContainerHighest
                  : ShellColors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(ShellRadii.chip),
              border: Border.all(
                color: _focused ? ShellColors.accent : ShellColors.hairline,
              ),
            ),
            child: Text(
              widget.label,
              style: ShellText.cardTitle.copyWith(
                color: widget.prominent
                    ? ShellColors.onAccent
                    : ShellColors.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PickerIconButton extends StatefulWidget {
  const _PickerIconButton({
    required this.icon,
    required this.semanticsLabel,
    required this.onPressed,
  });

  final IconData icon;
  final String semanticsLabel;
  final VoidCallback onPressed;

  @override
  State<_PickerIconButton> createState() => _PickerIconButtonState();
}

class _PickerIconButtonState extends State<_PickerIconButton> {
  var _hovered = false;
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final highlighted = _hovered || _focused;
    return Semantics(
      button: true,
      label: widget.semanticsLabel,
      child: FocusableActionDetector(
        mouseCursor: ShellMouseCursors.link,
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: Motion.tile,
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: highlighted
                  ? ShellColors.surfaceContainerHighest
                  : ShellColors.surfaceContainerHigh,
              shape: BoxShape.circle,
              border: Border.all(
                color: _focused ? ShellColors.accent : ShellColors.hairline,
              ),
            ),
            child: Icon(
              widget.icon,
              size: 18,
              color: ShellColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
