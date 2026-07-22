import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  });

  final double value;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

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
    return Semantics(
      excludeSemantics: true,
      label: 'Wallpaper darkness',
      value: '$percentage percent',
      increasedValue:
          '${((value + _keyboardStep).clamp(0.0, 1.0) * 100).round()} percent',
      decreasedValue:
          '${((value - _keyboardStep).clamp(0.0, 1.0) * 100).round()} percent',
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
            color: theme.panelColor(ShellColors.panelBackground),
            borderRadius: BorderRadius.circular(ShellRadii.tile),
            border: Border.all(
              color: _focused ? theme.accent : ShellColors.hairline,
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.dark_mode_rounded, size: 20, color: theme.accent),
              const SizedBox(width: 8),
              const Text('Darkness', style: ShellText.cardTitle),
              const SizedBox(width: 8),
              SizedBox(
                width: 42,
                child: Text(
                  '$percentage%',
                  textAlign: TextAlign.right,
                  style: ShellText.cardTitle.copyWith(
                    color: ShellColors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: RangeBar(
                  icon: Icons.dark_mode_rounded,
                  value: value,
                  activeColor: theme.accent,
                  inactiveColor: ShellColors.wallpaperEffectTrack,
                  onChanged: widget.onChanged,
                  onChangeEnd: widget.onChangeEnd,
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
