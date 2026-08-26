import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../localization/denial_localizations.dart';
import '../../theme/motion.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/shade/range_bar.dart';
import '../../widgets/shell_cursor.dart';

class WallpaperDarknessControl extends StatefulWidget {
  const WallpaperDarknessControl({
    super.key,
    required this.value,
    required this.onChanged,
    required this.onChangeEnd,
    this.onChangeStart,
  });

  final double value;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final VoidCallback? onChangeStart;

  @override
  State<WallpaperDarknessControl> createState() =>
      _WallpaperDarknessControlState();
}

class _WallpaperDarknessControlState extends State<WallpaperDarknessControl> {
  static const double _keyboardStep = 0.05;

  var _focused = false;

  double get _value => widget.value.clamp(0.0, 1.0).toDouble();

  void _adjust(double delta) {
    final next = (_value + delta).clamp(0.0, 1.0).toDouble();
    if (next == _value) {
      return;
    }
    widget.onChanged(next);
    widget.onChangeEnd(next);
  }

  @override
  Widget build(BuildContext context) {
    final value = _value;
    final percentage = (value * 100).round();
    final theme = ShellTheme.of(context);
    final accent = theme.accentPalette;
    final l10n = context.l10n;
    return Semantics(
      excludeSemantics: true,
      label: l10n.wallpaperDarkness,
      value: l10n.settingsPercent(percentage),
      increasedValue: l10n.settingsPercent(
        ((value + _keyboardStep).clamp(0.0, 1.0) * 100).round(),
      ),
      decreasedValue: l10n.settingsPercent(
        ((value - _keyboardStep).clamp(0.0, 1.0) * 100).round(),
      ),
      onIncrease: () => _adjust(_keyboardStep),
      onDecrease: () => _adjust(-_keyboardStep),
      child: FocusableActionDetector(
        mouseCursor: ShellMouseCursors.link,
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.arrowLeft):
              _DarknessAdjustmentIntent(-_keyboardStep),
          SingleActivator(LogicalKeyboardKey.arrowDown):
              _DarknessAdjustmentIntent(-_keyboardStep),
          SingleActivator(LogicalKeyboardKey.arrowRight):
              _DarknessAdjustmentIntent(_keyboardStep),
          SingleActivator(LogicalKeyboardKey.arrowUp):
              _DarknessAdjustmentIntent(_keyboardStep),
        },
        actions: <Type, Action<Intent>>{
          _DarknessAdjustmentIntent: CallbackAction<_DarknessAdjustmentIntent>(
            onInvoke: (intent) {
              _adjust(intent.delta);
              return null;
            },
          ),
        },
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        child: AnimatedContainer(
          duration: Motion.tile,
          curve: Motion.standard,
          padding: const EdgeInsets.fromLTRB(12, 7, 8, 7),
          decoration: BoxDecoration(
            color: theme.panelColor(context.shellColors.panelBackground),
            borderRadius: BorderRadius.circular(ShellRadii.tile),
            border: Border.all(
              color: _focused ? accent.primary : context.shellColors.hairline,
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.dark_mode_rounded, size: 20, color: accent.primary),
              const SizedBox(width: 8),
              Text(l10n.wallpaperDarknessShort, style: ShellText.cardTitle),
              const SizedBox(width: 8),
              SizedBox(
                width: 42,
                child: Text(
                  l10n.settingsPercent(percentage),
                  textAlign: TextAlign.right,
                  style: ShellText.cardTitle.copyWith(
                    color: context.shellColors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: RangeBar(
                  icon: Icons.dark_mode_rounded,
                  value: value,
                  activeColor: accent.primary,
                  inactiveColor: context.shellColors.wallpaperEffectTrack,
                  onChanged: widget.onChanged,
                  onChangeEnd: widget.onChangeEnd,
                  onChangeStart: widget.onChangeStart,
                  height: 38,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DarknessAdjustmentIntent extends Intent {
  const _DarknessAdjustmentIntent(this.delta);

  final double delta;
}
