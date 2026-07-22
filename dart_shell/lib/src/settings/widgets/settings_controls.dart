import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../localization/denial_localizations.dart';
import '../../models/shell_popup_placement.dart';
import '../../theme/motion.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/shell_cursor.dart';
import '../color_format.dart';

class SettingsPageLayout extends StatelessWidget {
  const SettingsPageLayout({
    required this.icon,
    required this.eyebrow,
    required this.title,
    required this.description,
    required this.children,
    required this.onReset,
    super.key,
  });

  final IconData icon;
  final String eyebrow;
  final String title;
  final String description;
  final List<Widget> children;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 36),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 16, color: accent),
                  const SizedBox(width: 8),
                  Text(
                    eyebrow.toUpperCase(),
                    style: ShellText.cardTitle.copyWith(
                      color: accent,
                      fontSize: 11,
                      letterSpacing: 1.4,
                    ),
                  ),
                  const Spacer(),
                  const SettingsSavedBadge(),
                  const SizedBox(width: 10),
                  SettingsTextButton(label: 'Reset page', onPressed: onReset),
                ],
              ),
              const SizedBox(height: 18),
              Text(
                title,
                style: const TextStyle(
                  color: ShellColors.textPrimary,
                  fontSize: 25,
                  height: 1.12,
                  fontWeight: FontWeight.w800,
                  decoration: TextDecoration.none,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                description,
                style: ShellText.base.copyWith(
                  color: ShellColors.textSecondary,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 24),
              for (var index = 0; index < children.length; index += 1) ...[
                children[index],
                if (index != children.length - 1) const SizedBox(height: 16),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class SettingsSavedBadge extends StatelessWidget {
  const SettingsSavedBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Semantics(
      label: l10n.settingsLiveChangesSemanticsLabel,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: ShellColors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(ShellRadii.chip),
          border: Border.all(color: ShellColors.hairlineSoft),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: ShellColors.gestureArmed,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 7),
              Text(
                l10n.settingsLiveBadge,
                style: ShellText.cardTitle.copyWith(
                  color: ShellColors.textSecondary,
                  fontSize: 9,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SettingsCard extends StatelessWidget {
  const SettingsCard({
    required this.title,
    required this.description,
    required this.child,
    this.leading,
    this.trailing,
    super.key,
  });

  final String title;
  final String description;
  final Widget child;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.panelColor(ShellColors.surfaceContainerLow),
        borderRadius: BorderRadius.circular(theme.panelRadius),
        border: Border.all(color: ShellColors.hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (leading case final leading?) ...[
                  leading,
                  const SizedBox(width: 14),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: ShellText.statusClock),
                      const SizedBox(height: 6),
                      Text(
                        description,
                        style: ShellText.base.copyWith(
                          color: ShellColors.textSecondary,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                if (trailing case final trailing?) ...[
                  const SizedBox(width: 16),
                  trailing,
                ],
              ],
            ),
            const SizedBox(height: 18),
            child,
          ],
        ),
      ),
    );
  }
}

class SettingsSlider extends StatelessWidget {
  const SettingsSlider({
    required this.label,
    required this.value,
    required this.minimum,
    required this.maximum,
    required this.onChanged,
    this.divisions,
    this.valueLabel,
    super.key,
  });

  final String label;
  final double value;
  final double minimum;
  final double maximum;
  final int? divisions;
  final String? valueLabel;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    final displayValue = valueLabel ?? value.toStringAsFixed(0);
    return Semantics(
      slider: true,
      label: label,
      value: displayValue,
      child: Row(
        children: [
          SizedBox(
            width: 168,
            child: Text(
              label,
              style: ShellText.cardTitle.copyWith(
                color: ShellColors.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: accent,
                inactiveTrackColor: ShellColors.surfaceContainerHighest,
                thumbColor: ShellColors.sliderThumb,
                overlayColor: accent.withAlpha(32),
                trackHeight: 5,
              ),
              child: Slider(
                value: value.clamp(minimum, maximum).toDouble(),
                min: minimum,
                max: maximum,
                divisions: divisions,
                onChanged: onChanged,
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 66,
            child: Text(
              displayValue,
              textAlign: TextAlign.right,
              style: ShellText.cardTitle.copyWith(
                fontFamily: ShellText.systemBarFontFamily,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SettingsToggle extends StatelessWidget {
  const SettingsToggle({
    required this.label,
    required this.description,
    required this.value,
    required this.onChanged,
    super.key,
  });

  final String label;
  final String description;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    return Semantics(
      toggled: value,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(!value),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: ShellText.cardTitle),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: ShellText.base.copyWith(
                      color: ShellColors.textTertiary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 18),
            AnimatedContainer(
              duration: Motion.tile,
              width: 44,
              height: 25,
              padding: const EdgeInsets.all(3),
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              decoration: BoxDecoration(
                color: value ? accent : ShellColors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(99),
                border: Border.all(
                  color: value ? accent : ShellColors.hairline,
                ),
              ),
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  color: ShellColors.sliderThumb,
                  shape: BoxShape.circle,
                ),
                child: SizedBox.square(dimension: 17),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SettingsChoice<T> {
  const SettingsChoice(this.value, this.label);

  final T value;
  final String label;
}

class SettingsSegmentedControl<T> extends StatelessWidget {
  const SettingsSegmentedControl({
    required this.value,
    required this.choices,
    required this.onChanged,
    super.key,
  });

  final T value;
  final List<SettingsChoice<T>> choices;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final choice in choices)
          _SettingsChoiceChip(
            label: choice.label,
            selected: choice.value == value,
            onPressed: () => onChanged(choice.value),
          ),
      ],
    );
  }
}

class SettingsColorButton extends StatelessWidget {
  const SettingsColorButton({
    required this.color,
    required this.label,
    required this.onPressed,
    super.key,
  });

  final Color color;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      value: formatOpaqueColorHex(color),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: ShellColors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(ShellRadii.chip),
            border: Border.all(color: ShellColors.hairline),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: Motion.tile,
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(color: ShellColors.panelHighlight),
                  ),
                ),
                const SizedBox(width: 9),
                Text(
                  formatOpaqueColorHex(color),
                  style: ShellText.cardTitle.copyWith(
                    color: ShellColors.textSecondary,
                    fontFamily: ShellText.systemBarFontFamily,
                  ),
                ),
                const SizedBox(width: 7),
                const Icon(
                  Icons.expand_more_rounded,
                  size: 18,
                  color: ShellColors.textTertiary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SettingsAnchorPicker extends StatelessWidget {
  const SettingsAnchorPicker({
    required this.value,
    required this.onChanged,
    super.key,
  });

  final ShellPopupAnchor value;
  final ValueChanged<ShellPopupAnchor> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Screen anchor',
      explicitChildNodes: true,
      child: SizedBox(
        width: 132,
        height: 92,
        child: GridView.count(
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 3,
          childAspectRatio: 1.5,
          mainAxisSpacing: 5,
          crossAxisSpacing: 5,
          children: [
            for (final anchor in ShellPopupAnchor.values)
              _AnchorButton(
                anchor: anchor,
                selected: anchor == value,
                onPressed: () => onChanged(anchor),
              ),
          ],
        ),
      ),
    );
  }
}

class SettingsTextButton extends StatelessWidget {
  const SettingsTextButton({
    required this.label,
    required this.onPressed,
    super.key,
  });

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return _SettingsChoiceChip(
      label: label,
      selected: false,
      onPressed: onPressed,
    );
  }
}

class _SettingsChoiceChip extends StatefulWidget {
  const _SettingsChoiceChip({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  State<_SettingsChoiceChip> createState() => _SettingsChoiceChipState();
}

class _SettingsChoiceChipState extends State<_SettingsChoiceChip> {
  var _highlighted = false;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.label,
      child: FocusableActionDetector(
        mouseCursor: ShellMouseCursors.link,
        onShowFocusHighlight: (value) => setState(() => _highlighted = value),
        onShowHoverHighlight: (value) => setState(() => _highlighted = value),
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
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
            decoration: BoxDecoration(
              color: widget.selected
                  ? accent.withAlpha(42)
                  : _highlighted
                  ? ShellColors.surfaceContainerHighest
                  : ShellColors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(ShellRadii.chip),
              border: Border.all(
                color: widget.selected
                    ? accent
                    : _highlighted
                    ? ShellColors.textTertiary
                    : ShellColors.hairline,
              ),
            ),
            child: Text(
              widget.label,
              style: ShellText.cardTitle.copyWith(
                color: widget.selected ? accent : ShellColors.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AnchorButton extends StatelessWidget {
  const _AnchorButton({
    required this.anchor,
    required this.selected,
    required this.onPressed,
  });

  final ShellPopupAnchor anchor;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    return Semantics(
      button: true,
      selected: selected,
      label: _anchorLabel(anchor),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: AnimatedContainer(
          duration: Motion.tile,
          decoration: BoxDecoration(
            color: selected
                ? accent.withAlpha(46)
                : ShellColors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: selected ? accent : ShellColors.hairline),
          ),
          child: Center(
            child: AnimatedContainer(
              duration: Motion.tile,
              width: selected ? 10 : 7,
              height: selected ? 10 : 7,
              decoration: BoxDecoration(
                color: selected ? accent : ShellColors.textTertiary,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _anchorLabel(ShellPopupAnchor anchor) {
  return switch (anchor) {
    ShellPopupAnchor.topLeft => 'Top left',
    ShellPopupAnchor.topCenter => 'Top center',
    ShellPopupAnchor.topRight => 'Top right',
    ShellPopupAnchor.centerLeft => 'Center left',
    ShellPopupAnchor.center => 'Center',
    ShellPopupAnchor.centerRight => 'Center right',
    ShellPopupAnchor.bottomLeft => 'Bottom left',
    ShellPopupAnchor.bottomCenter => 'Bottom center',
    ShellPopupAnchor.bottomRight => 'Bottom right',
  };
}
