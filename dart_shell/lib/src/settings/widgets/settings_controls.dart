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
    required this.children,
    required this.onReset,
    super.key,
  });

  final IconData icon;
  final String eyebrow;
  final String title;
  final List<Widget> children;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontalPadding = constraints.maxWidth < 560 ? 14.0 : 20.0;
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            16,
            horizontalPadding,
            24,
          ),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(icon, size: 15, color: accent),
                      const SizedBox(width: 7),
                      Text(
                        eyebrow.toUpperCase(),
                        style: ShellText.cardTitle.copyWith(
                          color: accent,
                          fontSize: 10,
                          letterSpacing: 1.3,
                        ),
                      ),
                      const Spacer(),
                      const SettingsSavedBadge(),
                      const SizedBox(width: 8),
                      SettingsTextButton(
                        label: context.l10n.settingsResetPage,
                        onPressed: onReset,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    title,
                    style: ShellText.base.copyWith(
                      color: ShellColors.textPrimary,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 16),
                  for (var index = 0; index < children.length; index++) ...[
                    if (index > 0) const SizedBox(height: 12),
                    children[index],
                  ],
                ],
              ),
            ),
          ),
        );
      },
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

class SettingsCardGroup extends StatelessWidget {
  const SettingsCardGroup({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final radius = BorderRadius.circular(theme.panelRadius);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ShellColors.surfaceContainerLow.withValues(
          alpha: theme.panelOpacity * 0.84,
        ),
        borderRadius: radius,
        border: Border.all(color: ShellColors.hairline),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var index = 0; index < children.length; index++) ...[
              if (index > 0)
                const Divider(height: 1, color: ShellColors.hairlineSoft),
              children[index],
            ],
          ],
        ),
      ),
    );
  }
}

class SettingsSection extends StatelessWidget {
  const SettingsSection({
    required this.title,
    required this.child,
    this.leading,
    this.status,
    this.trailing,
    super.key,
  });

  final String title;
  final Widget child;
  final Widget? leading;
  final String? status;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (leading case final leading?) ...[
                leading,
                const SizedBox(width: 11),
              ],
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ShellText.base.copyWith(
                    color: ShellColors.textPrimary,
                    height: 1.32,
                  ),
                ),
              ),
              if (status case final status?) ...[
                const SizedBox(width: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: Text(
                    status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: ShellText.base.copyWith(
                      color: ShellColors.textTertiary,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
              if (trailing case final trailing?) ...[
                const SizedBox(width: 12),
                trailing,
              ],
            ],
          ),
          const SizedBox(height: 13),
          child,
        ],
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
    this.onChangeStart,
    this.onChangeEnd,
    this.divisions,
    this.valueLabel,
    this.enabled = true,
    super.key,
  });

  final String label;
  final double value;
  final double minimum;
  final double maximum;
  final int? divisions;
  final String? valueLabel;
  final bool enabled;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    final displayValue = valueLabel ?? value.toStringAsFixed(0);
    return Semantics(
      slider: true,
      enabled: enabled,
      label: label,
      value: displayValue,
      child: AnimatedOpacity(
        duration: Motion.tile,
        opacity: enabled ? 1 : 0.46,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 430;
            final heading = Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: ShellText.cardTitle.copyWith(
                      color: ShellColors.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  displayValue,
                  textAlign: TextAlign.right,
                  style: ShellText.cardTitle.copyWith(
                    fontFamily: ShellText.systemBarFontFamily,
                  ),
                ),
              ],
            );
            final slider = SliderTheme(
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
                onChanged: enabled ? onChanged : null,
                onChangeStart: enabled ? onChangeStart : null,
                onChangeEnd: enabled ? onChangeEnd : null,
              ),
            );
            if (compact) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [heading, const SizedBox(height: 3), slider],
              );
            }
            return Row(
              children: [
                SizedBox(
                  width: 150,
                  child: Text(
                    label,
                    style: ShellText.cardTitle.copyWith(
                      color: ShellColors.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(child: slider),
                const SizedBox(width: 10),
                SizedBox(
                  width: 58,
                  child: Text(
                    displayValue,
                    textAlign: TextAlign.right,
                    style: ShellText.cardTitle.copyWith(
                      fontFamily: ShellText.systemBarFontFamily,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
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
    this.enabled = true,
    super.key,
  });

  final String label;
  final String description;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    return Semantics(
      button: true,
      enabled: enabled,
      toggled: value,
      label: label,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: enabled
            ? ShellMouseCursors.link
            : SystemMouseCursors.basic,
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              if (enabled) {
                onChanged(!value);
              }
              return null;
            },
          ),
        },
        child: AnimatedOpacity(
          duration: Motion.tile,
          opacity: enabled ? 1 : 0.46,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: enabled ? () => onChanged(!value) : null,
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
                  alignment: value
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
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
      label: context.l10n.settingsScreenAnchor,
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
  final VoidCallback? onPressed;

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
  final VoidCallback? onPressed;

  @override
  State<_SettingsChoiceChip> createState() => _SettingsChoiceChipState();
}

class _SettingsChoiceChipState extends State<_SettingsChoiceChip> {
  var _highlighted = false;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    final enabled = widget.onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      selected: widget.selected,
      label: widget.label,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: enabled
            ? ShellMouseCursors.link
            : SystemMouseCursors.basic,
        onShowFocusHighlight: (value) => setState(() => _highlighted = value),
        onShowHoverHighlight: (value) => setState(() => _highlighted = value),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed?.call();
              return null;
            },
          ),
        },
        child: AnimatedOpacity(
          duration: Motion.tile,
          opacity: enabled ? 1 : 0.46,
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
      label: _anchorLabel(anchor, context),
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

String _anchorLabel(ShellPopupAnchor anchor, BuildContext context) {
  final l10n = context.l10n;
  return switch (anchor) {
    ShellPopupAnchor.topLeft => l10n.anchorTopLeft,
    ShellPopupAnchor.topCenter => l10n.anchorTopCenter,
    ShellPopupAnchor.topRight => l10n.anchorTopRight,
    ShellPopupAnchor.centerLeft => l10n.anchorCenterLeft,
    ShellPopupAnchor.center => l10n.anchorCenter,
    ShellPopupAnchor.centerRight => l10n.anchorCenterRight,
    ShellPopupAnchor.bottomLeft => l10n.anchorBottomLeft,
    ShellPopupAnchor.bottomCenter => l10n.anchorBottomCenter,
    ShellPopupAnchor.bottomRight => l10n.anchorBottomRight,
  };
}
