import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../localization/denial_localizations.dart';
import '../../theme/motion.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/shade/range_bar.dart';
import '../../widgets/shell_cursor.dart';
import '../wallpaper.dart';

class WallpaperSpanAlignmentSelector extends StatelessWidget {
  const WallpaperSpanAlignmentSelector({
    super.key,
    required this.value,
    required this.onChanged,
    required this.onChangeEnd,
    this.onChangeStart,
  });

  final WallpaperSpanAlignment value;
  final ValueChanged<WallpaperSpanAlignment> onChanged;
  final ValueChanged<WallpaperSpanAlignment> onChangeEnd;
  final VoidCallback? onChangeStart;

  WallpaperSpanAlignment _withPosition({double? x, double? y}) {
    return WallpaperSpanAlignment.precise(
      x: (x ?? value.x).clamp(-1.0, 1.0).toDouble(),
      y: (y ?? value.y).clamp(-1.0, 1.0).toDouble(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: l10n.wallpaperSpanAlignment,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final horizontal = WallpaperAlignmentSlider(
            label: l10n.wallpaperMobileHorizontalPosition,
            icon: Icons.align_horizontal_center_rounded,
            value: value.x,
            onChangeStart: onChangeStart,
            onChanged: (next) => onChanged(_withPosition(x: next)),
            onChangeEnd: (next) => onChangeEnd(_withPosition(x: next)),
          );
          final vertical = WallpaperAlignmentSlider(
            label: l10n.wallpaperMobileVerticalPosition,
            icon: Icons.align_vertical_center_rounded,
            value: value.y,
            onChangeStart: onChangeStart,
            onChanged: (next) => onChanged(_withPosition(y: next)),
            onChangeEnd: (next) => onChangeEnd(_withPosition(y: next)),
          );
          final center = _ShellIconControl(
            icon: Icons.center_focus_strong_rounded,
            semanticsLabel: l10n.wallpaperMobileCenterPosition,
            selected: value == const WallpaperSpanAlignment(),
            onPressed: () {
              const centered = WallpaperSpanAlignment();
              onChanged(centered);
              onChangeEnd(centered);
            },
          );
          if (constraints.maxWidth >= 580) {
            return Row(
              children: [
                Expanded(child: horizontal),
                const SizedBox(width: 10),
                Expanded(child: vertical),
                const SizedBox(width: 10),
                center,
              ],
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              horizontal,
              const SizedBox(height: 6),
              vertical,
              const SizedBox(height: 8),
              center,
            ],
          );
        },
      ),
    );
  }
}

class WallpaperAlignmentSlider extends StatefulWidget {
  const WallpaperAlignmentSlider({
    super.key,
    required this.label,
    required this.icon,
    required this.value,
    required this.onChanged,
    required this.onChangeEnd,
    this.onChangeStart,
  });

  final String label;
  final IconData icon;
  final double value;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final VoidCallback? onChangeStart;

  @override
  State<WallpaperAlignmentSlider> createState() =>
      _WallpaperAlignmentSliderState();
}

class _WallpaperAlignmentSliderState extends State<WallpaperAlignmentSlider> {
  static const double _keyboardStep = 0.05;

  var _focused = false;

  double get _value => widget.value.clamp(-1.0, 1.0).toDouble();

  void _adjust(double delta) {
    final next = (_value + delta).clamp(-1.0, 1.0).toDouble();
    if (next == _value) {
      return;
    }
    widget.onChanged(next);
    widget.onChangeEnd(next);
  }

  @override
  Widget build(BuildContext context) {
    final value = _value;
    final normalized = (value + 1.0) / 2.0;
    final percentage = (value * 100).round();
    final accent = ShellTheme.of(context).accentPalette;
    return Semantics(
      excludeSemantics: true,
      slider: true,
      label: widget.label,
      value: '$percentage%',
      increasedValue:
          '${((value + _keyboardStep).clamp(-1.0, 1.0) * 100).round()}%',
      decreasedValue:
          '${((value - _keyboardStep).clamp(-1.0, 1.0) * 100).round()}%',
      onIncrease: () => _adjust(_keyboardStep),
      onDecrease: () => _adjust(-_keyboardStep),
      child: FocusableActionDetector(
        mouseCursor: ShellMouseCursors.link,
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.arrowLeft):
              _AlignmentAdjustmentIntent(-_keyboardStep),
          SingleActivator(LogicalKeyboardKey.arrowDown):
              _AlignmentAdjustmentIntent(-_keyboardStep),
          SingleActivator(LogicalKeyboardKey.arrowRight):
              _AlignmentAdjustmentIntent(_keyboardStep),
          SingleActivator(LogicalKeyboardKey.arrowUp):
              _AlignmentAdjustmentIntent(_keyboardStep),
        },
        actions: <Type, Action<Intent>>{
          _AlignmentAdjustmentIntent:
              CallbackAction<_AlignmentAdjustmentIntent>(
                onInvoke: (intent) {
                  _adjust(intent.delta);
                  return null;
                },
              ),
        },
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        child: AnimatedContainer(
          duration: Motion.tile,
          curve: Motion.standard,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            borderRadius: context.shellTheme.borderRadius(ShellRadii.tile),
            border: Border.all(
              color: _focused
                  ? accent.primary
                  : ShellMediaColors.transparentDark,
            ),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 84,
                child: Text(widget.label, style: ShellText.cardTitle),
              ),
              Expanded(
                child: RangeBar(
                  icon: widget.icon,
                  value: normalized,
                  activeColor: accent.primary,
                  inactiveColor: context.shellColors.wallpaperEffectTrack,
                  onChangeStart: widget.onChangeStart,
                  onChanged: (next) => widget.onChanged(next * 2.0 - 1.0),
                  onChangeEnd: (next) => widget.onChangeEnd(next * 2.0 - 1.0),
                  height: 38,
                ),
              ),
              SizedBox(
                width: 54,
                child: Text(
                  '$percentage%',
                  textAlign: TextAlign.right,
                  style: ShellText.cardTitle.copyWith(
                    color: context.shellColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AlignmentAdjustmentIntent extends Intent {
  const _AlignmentAdjustmentIntent(this.delta);

  final double delta;
}

class WallpaperSelectorCloseButton extends StatelessWidget {
  const WallpaperSelectorCloseButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return _ShellIconControl(
      icon: Icons.close_rounded,
      semanticsLabel: context.l10n.wallpaperCloseSelector,
      selected: false,
      dimension: 46,
      iconSize: 24,
      onPressed: onPressed,
    );
  }
}

class _ShellIconControl extends StatefulWidget {
  const _ShellIconControl({
    required this.icon,
    required this.semanticsLabel,
    required this.selected,
    required this.onPressed,
    this.dimension = 36,
    this.iconSize = 20,
  });

  final IconData icon;
  final String semanticsLabel;
  final bool selected;
  final VoidCallback onPressed;
  final double dimension;
  final double iconSize;

  @override
  State<_ShellIconControl> createState() => _ShellIconControlState();
}

class _ShellIconControlState extends State<_ShellIconControl> {
  var _hovered = false;
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final highlighted = _hovered || _focused;
    final accent = ShellTheme.of(context).accentPalette;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.semanticsLabel,
      child: FocusableActionDetector(
        mouseCursor: ShellMouseCursors.link,
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
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: Motion.tile,
            curve: Motion.standard,
            width: widget.dimension,
            height: widget.dimension,
            decoration: BoxDecoration(
              color: widget.selected
                  ? accent.container
                  : highlighted
                  ? context.shellColors.surfaceContainerHighest
                  : context.shellTheme.cardColor(
                      context.shellColors.panelBackground,
                    ),
              shape: BoxShape.circle,
              border: Border.all(
                color: widget.selected || highlighted
                    ? accent.primary
                    : context.shellColors.hairline,
              ),
            ),
            child: Icon(
              widget.icon,
              size: widget.iconSize,
              color: widget.selected
                  ? accent.onContainer
                  : context.shellColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
