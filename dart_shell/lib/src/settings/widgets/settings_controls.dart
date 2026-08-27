import 'dart:ui' show SemanticsRole;

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
    this.onReset,
    super.key,
  });

  final IconData icon;
  final String eyebrow;
  final String title;
  final List<Widget> children;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final accent = theme.accent;
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
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
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
                        ],
                      ),
                      if (onReset != null)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SettingsSavedBadge(),
                            const SizedBox(width: 8),
                            SettingsTextButton(
                              label: context.l10n.settingsResetPage,
                              onPressed: onReset,
                            ),
                          ],
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    title,
                    style: ShellText.base.copyWith(
                      color: context.shellColors.textPrimary,
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
          color: context.shellColors.surfaceContainerHigh,
          borderRadius: context.shellTheme.borderRadius(ShellRadii.chip),
          border: Border.all(color: context.shellColors.hairlineSoft),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: context.shellColors.gestureArmed,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 7),
              Text(
                l10n.settingsLiveBadge,
                style: ShellText.cardTitle.copyWith(
                  color: context.shellColors.textSecondary,
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
        color: theme.cardColor(context.shellColors.surfaceContainerLow),
        borderRadius: radius,
        border: Border.all(color: context.shellColors.hairline),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var index = 0; index < children.length; index++) ...[
              if (index > 0)
                Divider(height: 1, color: context.shellColors.hairlineSoft),
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
                    color: context.shellColors.textPrimary,
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
                      color: context.shellColors.textTertiary,
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
    final theme = ShellTheme.of(context);
    final accent = theme.accent;
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
                      color: context.shellColors.textSecondary,
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
                inactiveTrackColor: context.shellColors.surfaceContainerHighest,
                thumbColor: context.shellColors.sliderThumb,
                overlayColor: accent.withAlpha(32),
                trackHeight: 5,
                trackShape: _SettingsSliderTrackShape(
                  cornerRadiusScale: theme.cornerRadiusScale,
                ),
                thumbShape: _SettingsSliderThumbShape(
                  cornerRadiusScale: theme.cornerRadiusScale,
                  shadowColor: context.shellColors.shadow,
                ),
                overlayShape: _SettingsSliderOverlayShape(
                  cornerRadiusScale: theme.cornerRadiusScale,
                ),
                tickMarkShape: _SettingsSliderTickMarkShape(
                  cornerRadiusScale: theme.cornerRadiusScale,
                ),
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
                      color: context.shellColors.textSecondary,
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
    final theme = ShellTheme.of(context);
    final accent = theme.accent;
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
                          color: context.shellColors.textTertiary,
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
                    color: value
                        ? accent
                        : context.shellColors.surfaceContainerHighest,
                    borderRadius: context.shellTheme.borderRadius(99),
                    border: Border.all(
                      color: value ? accent : context.shellColors.hairline,
                    ),
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: context.shellColors.sliderThumb,
                      borderRadius: theme.borderRadius(8.5),
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

class _SettingsSliderTrackShape extends SliderTrackShape
    with BaseSliderTrackShape {
  const _SettingsSliderTrackShape({required this.cornerRadiusScale});

  final double cornerRadiusScale;

  @override
  bool get isRounded => cornerRadiusScale > 0;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    final trackHeight = sliderTheme.trackHeight;
    if (trackHeight == null || trackHeight <= 0) {
      return;
    }
    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final radius = Radius.circular(
      _scaledControlRadius(trackRect.height / 2, cornerRadiusScale),
    );
    final activePaint = Paint()
      ..color = ColorTween(
        begin: sliderTheme.disabledActiveTrackColor,
        end: sliderTheme.activeTrackColor,
      ).evaluate(enableAnimation)!;
    final inactivePaint = Paint()
      ..color = ColorTween(
        begin: sliderTheme.disabledInactiveTrackColor,
        end: sliderTheme.inactiveTrackColor,
      ).evaluate(enableAnimation)!;
    final canvas = context.canvas;
    canvas.drawRRect(RRect.fromRectAndRadius(trackRect, radius), inactivePaint);

    final thumbX = thumbCenter.dx.clamp(trackRect.left, trackRect.right);
    final activeRect = textDirection == TextDirection.ltr
        ? Rect.fromLTRB(trackRect.left, trackRect.top, thumbX, trackRect.bottom)
        : Rect.fromLTRB(
            thumbX,
            trackRect.top,
            trackRect.right,
            trackRect.bottom,
          );
    if (!activeRect.isEmpty) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(activeRect, radius),
        activePaint,
      );
    }

    final secondaryColor = ColorTween(
      begin: sliderTheme.disabledSecondaryActiveTrackColor,
      end: sliderTheme.secondaryActiveTrackColor,
    ).evaluate(enableAnimation);
    if (secondaryOffset == null || secondaryColor == null) {
      return;
    }
    final secondaryX = secondaryOffset.dx.clamp(
      trackRect.left,
      trackRect.right,
    );
    final secondaryRect = textDirection == TextDirection.ltr
        ? Rect.fromLTRB(thumbX, trackRect.top, secondaryX, trackRect.bottom)
        : Rect.fromLTRB(secondaryX, trackRect.top, thumbX, trackRect.bottom);
    if (!secondaryRect.isEmpty) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(secondaryRect, radius),
        Paint()..color = secondaryColor,
      );
    }
  }
}

class _SettingsSliderThumbShape extends SliderComponentShape {
  const _SettingsSliderThumbShape({
    required this.cornerRadiusScale,
    required this.shadowColor,
  });

  static const double _extent = 20;

  final double cornerRadiusScale;
  final Color shadowColor;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      const Size.square(_extent);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final color = ColorTween(
      begin: sliderTheme.disabledThumbColor,
      end: sliderTheme.thumbColor,
    ).evaluate(enableAnimation)!;
    final rect = Rect.fromCenter(
      center: center,
      width: _extent,
      height: _extent,
    );
    final shape = RRect.fromRectAndRadius(
      rect,
      Radius.circular(_scaledControlRadius(_extent / 2, cornerRadiusScale)),
    );
    final canvas = context.canvas;
    canvas.drawShadow(
      Path()..addRRect(shape),
      shadowColor,
      1 + 5 * activationAnimation.value,
      true,
    );
    canvas.drawRRect(shape, Paint()..color = color);
  }
}

class _SettingsSliderOverlayShape extends SliderComponentShape {
  const _SettingsSliderOverlayShape({required this.cornerRadiusScale});

  static const double _extent = 40;

  final double cornerRadiusScale;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      const Size.square(_extent);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final overlayColor = sliderTheme.overlayColor;
    final opacity = activationAnimation.value;
    if (overlayColor == null || opacity <= 0) {
      return;
    }
    final rect = Rect.fromCenter(
      center: center,
      width: _extent,
      height: _extent,
    );
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect,
        Radius.circular(_scaledControlRadius(_extent / 2, cornerRadiusScale)),
      ),
      Paint()..color = overlayColor.withValues(alpha: overlayColor.a * opacity),
    );
  }
}

class _SettingsSliderTickMarkShape extends SliderTickMarkShape {
  const _SettingsSliderTickMarkShape({required this.cornerRadiusScale});

  final double cornerRadiusScale;

  @override
  Size getPreferredSize({
    required SliderThemeData sliderTheme,
    required bool isEnabled,
  }) {
    final extent = (sliderTheme.trackHeight ?? 0) / 2;
    return Size.square(extent);
  }

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    required bool isEnabled,
    required TextDirection textDirection,
  }) {
    final inactive = switch (textDirection) {
      TextDirection.ltr => center.dx > thumbCenter.dx,
      TextDirection.rtl => center.dx < thumbCenter.dx,
    };
    final color = ColorTween(
      begin: inactive
          ? sliderTheme.disabledInactiveTickMarkColor
          : sliderTheme.disabledActiveTickMarkColor,
      end: inactive
          ? sliderTheme.inactiveTickMarkColor
          : sliderTheme.activeTickMarkColor,
    ).evaluate(enableAnimation);
    final extent = getPreferredSize(
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
    ).width;
    if (color == null || extent <= 0) {
      return;
    }
    final rect = Rect.fromCenter(center: center, width: extent, height: extent);
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect,
        Radius.circular(_scaledControlRadius(extent / 2, cornerRadiusScale)),
      ),
      Paint()..color = color,
    );
  }
}

double _scaledControlRadius(double maximum, double scale) =>
    (maximum * scale).clamp(0.0, maximum).toDouble();

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
    return Semantics(
      role: SemanticsRole.radioGroup,
      explicitChildNodes: true,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final choice in choices)
            _SettingsChoiceChip(
              label: choice.label,
              selected: choice.value == value,
              selectionControl: true,
              onPressed: () => onChanged(choice.value),
            ),
        ],
      ),
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
            color: context.shellColors.surfaceContainerHigh,
            borderRadius: context.shellTheme.borderRadius(ShellRadii.chip),
            border: Border.all(color: context.shellColors.hairline),
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
                    border: Border.all(
                      color: context.shellColors.panelHighlight,
                    ),
                  ),
                ),
                const SizedBox(width: 9),
                Text(
                  formatOpaqueColorHex(color),
                  style: ShellText.cardTitle.copyWith(
                    color: context.shellColors.textSecondary,
                    fontFamily: ShellText.systemBarFontFamily,
                  ),
                ),
                const SizedBox(width: 7),
                Icon(
                  Icons.expand_more_rounded,
                  size: 18,
                  color: context.shellColors.textTertiary,
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
    this.selectionControl = false,
  });

  final String label;
  final bool selected;
  final VoidCallback? onPressed;
  final bool selectionControl;

  @override
  State<_SettingsChoiceChip> createState() => _SettingsChoiceChipState();
}

class _SettingsChoiceChipState extends State<_SettingsChoiceChip> {
  var _hovered = false;
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    final enabled = widget.onPressed != null;
    final motionDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : Motion.tile;
    return Semantics(
      button: !widget.selectionControl,
      checked: widget.selectionControl ? widget.selected : null,
      inMutuallyExclusiveGroup: widget.selectionControl,
      enabled: enabled,
      selected: widget.selectionControl ? null : widget.selected,
      label: widget.label,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: enabled
            ? ShellMouseCursors.link
            : SystemMouseCursors.basic,
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
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
          duration: motionDuration,
          opacity: enabled ? 1 : 0.46,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: context.shellColors.surfaceContainerHigh,
                borderRadius: context.shellTheme.borderRadius(ShellRadii.chip),
                border: Border.all(color: context.shellColors.hairline),
              ),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        duration: motionDuration,
                        curve: Motion.standard,
                        opacity: widget.selected ? 1 : 0,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: accent.withAlpha(42),
                            borderRadius: context.shellTheme.borderRadius(
                              ShellRadii.chip,
                            ),
                            border: Border.all(color: accent),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        duration: motionDuration,
                        curve: Motion.standard,
                        opacity: !widget.selected && (_hovered || _focused)
                            ? 1
                            : 0,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: context.shellColors.surfaceContainerHighest,
                            borderRadius: context.shellTheme.borderRadius(
                              ShellRadii.chip,
                            ),
                            border: Border.all(
                              color: _focused
                                  ? accent
                                  : context.shellColors.textTertiary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 13,
                      vertical: 9,
                    ),
                    child: Text(
                      widget.label,
                      style: ShellText.cardTitle.copyWith(
                        color: widget.selected
                            ? accent
                            : context.shellColors.textSecondary,
                      ),
                    ),
                  ),
                ],
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
                : context.shellColors.surfaceContainerHigh,
            borderRadius: context.shellTheme.borderRadius(8),
            border: Border.all(
              color: selected ? accent : context.shellColors.hairline,
            ),
          ),
          child: Center(
            child: AnimatedContainer(
              duration: Motion.tile,
              width: selected ? 10 : 7,
              height: selected ? 10 : 7,
              decoration: BoxDecoration(
                color: selected ? accent : context.shellColors.textTertiary,
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
