import 'dart:ui' show SemanticsRole;
import 'dart:math' as math;

import 'package:denial_flutter_sdk/materials.dart';

import 'package:flutter/material.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/tokens.dart';
import 'package:denial_flutter_sdk/settings.dart';

import 'settings_page_chrome.dart';
export 'settings_page_chrome.dart';

/// Widest reading column for page headers and cards. Keeping one width for
/// both keeps the header aligned with the cards on wide tablets.
const double settingsContentMaxWidth = 1180;

double settingsContentInset(double width) =>
    math.max(24.0, (width - settingsContentMaxWidth) / 2);

/// Fixed page header over a page-owned body.
///
/// The header never scrolls, so page commands stay reachable. When the shell
/// hides navigation behind an overlay the header also carries the menu button.
class SettingsPageScaffold extends StatelessWidget {
  const SettingsPageScaffold({
    required this.title,
    required this.body,
    this.description,
    this.leading,
    this.actions = const [],
    this.footer,
    super.key,
  });

  final String title;
  final String? description;
  final Widget? leading;
  final List<Widget> actions;
  final Widget body;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final shell = SettingsShellScope.maybeOf(context);
    final menu =
        leading ??
        (shell != null && shell.navigationOverlay
            ? IconButton(
                tooltip: context.l10n.settingsNavigationOpenMenu,
                icon: const Icon(Icons.menu_rounded),
                onPressed: shell.openNavigation,
              )
            : null);
    return LayoutBuilder(
      builder: (context, constraints) {
        final inset = settingsContentInset(constraints.maxWidth);
        final stackedHeader = constraints.maxWidth < 720;
        final heading = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(
                title,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.5,
                  color: context.applicationColors.foreground,
                ),
              ),
            ),
            if (description != null) ...[
              const SizedBox(height: 6),
              Text(
                description!,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontSize: 13,
                  height: 1.4,
                  color: context.applicationColors.secondary,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ],
        );
        final commands = actions.isEmpty ? const <Widget>[] : actions;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(inset, 28, inset, 18),
              child: stackedHeader
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (menu != null) ...[
                              menu,
                              const SizedBox(width: 4),
                            ],
                            Expanded(child: heading),
                          ],
                        ),
                        if (commands.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Wrap(
                              alignment: WrapAlignment.end,
                              spacing: 8,
                              runSpacing: 8,
                              children: commands,
                            ),
                          ),
                      ],
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (menu != null) ...[menu, const SizedBox(width: 4)],
                        Expanded(child: heading),
                        if (commands.isNotEmpty) ...[
                          const SizedBox(width: 16),
                          Padding(
                            padding: const EdgeInsets.only(top: 2, right: 2),
                            child: Wrap(
                              alignment: WrapAlignment.end,
                              spacing: 8,
                              runSpacing: 8,
                              children: commands,
                            ),
                          ),
                        ],
                      ],
                    ),
            ),
            Divider(
              height: 1,
              thickness: 1,
              color: context.applicationColors.separator,
            ),
            Expanded(child: body),
            ?footer,
          ],
        );
      },
    );
  }
}

class SettingsPageBackButton extends StatelessWidget {
  const SettingsPageBackButton({required this.onPressed, super.key});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: context.l10n.commonBack,
    icon: const Icon(Icons.arrow_back_rounded),
    onPressed: onPressed,
  );
}

/// Standard page: fixed heading plus a scrolling column of cards.
class SettingsPageLayout extends StatelessWidget {
  const SettingsPageLayout({
    required this.icon,
    required this.eyebrow,
    required this.title,
    required this.children,
    this.onReset,
    this.commands = const [],
    this.footer,
    this.cardSpacing = 16,
    this.leading,
    super.key,
  });

  final IconData icon;
  final String eyebrow;
  final String title;
  final List<Widget> children;
  final VoidCallback? onReset;
  final List<Widget> commands;
  final Widget? footer;
  final double cardSpacing;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: eyebrow,
      description: title,
      leading: leading,
      actions: [
        ...commands,
        if (onReset != null)
          SettingsCommand(
            label: context.l10n.settingsResetPage,
            icon: Icons.restart_alt_rounded,
            onPressed: onReset,
          ),
      ],
      footer: footer,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final inset = settingsContentInset(constraints.maxWidth);
          return SingleChildScrollView(
            key: PageStorageKey<String>('settings-page-$eyebrow'),
            padding: EdgeInsets.fromLTRB(inset, 22, inset, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var index = 0; index < children.length; index++) ...[
                  if (index > 0) SizedBox(height: cardSpacing),
                  children[index],
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Master-detail page: an independently scrolling list beside an independently
/// scrolling detail column. Narrow layouts show one column at a time.
class SettingsSplitLayout extends StatelessWidget {
  const SettingsSplitLayout({
    required this.title,
    required this.list,
    required this.detail,
    this.description,
    this.leading,
    this.actions = const [],
    this.footer,
    this.listWidth = 320,
    this.detailVisible = true,
    super.key,
  });

  final String title;
  final String? description;
  final Widget list;
  final Widget detail;
  final Widget? leading;
  final List<Widget> actions;
  final Widget? footer;
  final double listWidth;
  final bool detailVisible;

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: title,
      description: description,
      leading: leading,
      actions: actions,
      footer: footer,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final inset = settingsContentInset(constraints.maxWidth);
          if (!detailVisible) {
            return SingleChildScrollView(
              key: PageStorageKey<String>('settings-page-$title'),
              padding: EdgeInsets.fromLTRB(inset, 20, inset, 28),
              child: list,
            );
          }
          return Padding(
            padding: EdgeInsets.fromLTRB(inset, 20, inset, 24),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: listWidth,
                  child: SingleChildScrollView(child: list),
                ),
                const SizedBox(width: 16),
                Expanded(child: SingleChildScrollView(child: detail)),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Keep titles on the opaque reading surface, matching the Plugins hierarchy.
class SettingsPageHeading extends StatelessWidget {
  const SettingsPageHeading({
    required this.title,
    required this.description,
    super.key,
  });

  final String title;
  final String description;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Semantics(
        header: true,
        child: Text(
          title,
          style: Theme.of(context).textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -.4),
        ),
      ),
      const SizedBox(height: 10),
      Text(
        description,
        style: Theme.of(context).textTheme.bodyMedium
            ?.copyWith(color: context.applicationColors.secondary, height: 1.5),
      ),
    ],
  );
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
          color: context.applicationColors.control,
          borderRadius: DenialSurfaceGeometry.borderRadiusOf(context),
          border: Border.all(color: context.applicationColors.separator),
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
                  color: context.applicationColors.secondary,
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
  const SettingsCardGroup({
    required this.children,
    this.title,
    this.description,
    super.key,
  });

  final List<Widget> children;
  final String? title;
  final String? description;

  @override
  Widget build(BuildContext context) {
    return DenialMaterial(
      role: DenialMaterialRole.card,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      title!,
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontSize: 18, fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (description != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      description!,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: context.applicationColors.secondary,
                        height: 1.5,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          for (var index = 0; index < children.length; index++) ...[
            if (index > 0)
              Divider(
                height: 1,
                indent: 20,
                endIndent: 20,
                color: context.applicationColors.separator,
              ),
            children[index],
          ],
        ],
      ),
    );
  }
}

/// One disclosure level for less common controls, on the containing opaque card.
/// A PageStorageKey keeps expansion stable when its card scrolls out of view.
class SettingsDisclosure extends StatelessWidget {
  const SettingsDisclosure({
    required this.title,
    required this.children,
    this.description,
    super.key,
  });

  final String title;
  final String? description;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: DenialSurfaceGeometry.borderRadiusOf(context),
    );
    return ExpansionTile(
      maintainState: true,
      shape: shape,
      collapsedShape: shape,
      backgroundColor: Colors.transparent,
      collapsedBackgroundColor: Colors.transparent,
      textColor: context.applicationColors.foreground,
      collapsedTextColor: context.applicationColors.foreground,
      iconColor: context.applicationColors.secondary,
      collapsedIconColor: context.applicationColors.secondary,
      tilePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      childrenPadding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      expansionAnimationStyle: AnimationStyle(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 160),
      ),
      title: Text(title, style: Theme.of(context).textTheme.titleSmall),
      subtitle: description == null
          ? null
          : Text(
              description!,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: context.applicationColors.secondary,
                height: 1.5,
              ),
            ),
      children: [
        DenialSurfaceGeometry(
          radius: DenialSurfaceGeometry.nestedRadius(context, inset: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ],
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
    return DenialSurfaceGeometry(
      radius: DenialSurfaceGeometry.nestedRadius(context, inset: 20),
      child: Padding(
        padding: const EdgeInsets.all(20),
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
                      color: context.applicationColors.foreground,
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
                        color: context.applicationColors.secondary,
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
      ),
    );
  }
}

/// Padding publishes the card's inset geometry to its controls.
class SettingsCardPadding extends StatelessWidget {
  const SettingsCardPadding({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => DenialSurfaceGeometry(
    radius: DenialSurfaceGeometry.nestedRadius(context, inset: 20),
    child: Padding(padding: const EdgeInsets.all(20), child: child),
  );
}

/// Keep reading and interaction in consistent columns, with room for labels
/// and controls to wrap when the window or text scale requires it.
class SettingsControlRow extends StatelessWidget {
  const SettingsControlRow({
    required this.label,
    required this.description,
    required this.control,
    this.leading,
    this.controlWidth = 320,
    super.key,
  });

  final String label;
  final String description;
  final Widget control;
  final Widget? leading;
  final double controlWidth;

  @override
  Widget build(BuildContext context) {
    final heading = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (leading != null) ...[leading!, const SizedBox(width: 12)],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (label.isNotEmpty)
                Text(label, style: Theme.of(context).textTheme.titleSmall),
              if (description.isNotEmpty) ...[
                if (label.isNotEmpty) const SizedBox(height: 6),
                Text(
                  description,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: context.applicationColors.secondary,
                    height: 1.5,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        if (constraints.maxWidth < (controlWidth + 264) * scale) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              heading,
              const SizedBox(height: 16),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: control,
              ),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: heading),
            const SizedBox(width: 24),
            SizedBox(
              width: controlWidth * scale,
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: control,
              ),
            ),
          ],
        );
      },
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
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : Motion.tile,
        opacity: enabled ? 1 : 0.46,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
            final compact = constraints.maxWidth < 560 * scale;
            final heading = Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  displayValue,
                  textAlign: TextAlign.right,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            );
            final slider = SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: accent,
                inactiveTrackColor: context.applicationColors.control,
                thumbColor: context.shellColors.sliderThumb,
                overlayColor: accent.withAlpha(32),
                trackHeight: 5,
                trackShape: _SettingsSliderTrackShape(
                  cornerRadius: DenialSurfaceGeometry.radiusOf(context),
                ),
                thumbShape: _SettingsSliderThumbShape(
                  cornerRadius: DenialSurfaceGeometry.radiusOf(context),
                  shadowColor: context.shellColors.shadow,
                ),
                overlayShape: _SettingsSliderOverlayShape(
                  cornerRadius: DenialSurfaceGeometry.radiusOf(context),
                ),
                tickMarkShape: _SettingsSliderTickMarkShape(
                  cornerRadius: DenialSurfaceGeometry.radiusOf(context),
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
                  width: 176 * scale,
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(child: slider),
                const SizedBox(width: 10),
                SizedBox(
                  width: 64 * scale,
                  child: Text(
                    displayValue,
                    textAlign: TextAlign.right,
                    style: Theme.of(context).textTheme.bodyMedium,
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
    this.showLabel = true,
    super.key,
  });

  final String label;
  final String description;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  /// Hide visible text when the surrounding row already supplies it.
  /// The label remains available to accessibility services.
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final accent = theme.accent;
    return Semantics(
      toggled: value,
      enabled: enabled,
      label: label,
      child: InkWell(
        onTap: enabled ? () => onChanged(!value) : null,
        borderRadius: DenialSurfaceGeometry.borderRadiusOf(context),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Opacity(
            opacity: enabled ? 1 : .46,
            child: Row(
              mainAxisSize: showLabel ? MainAxisSize.max : MainAxisSize.min,
              children: [
                if (showLabel) ...[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          description,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: context.applicationColors.secondary,
                                height: 1.5,
                              ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 18),
                ],
                AnimatedContainer(
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : Motion.tile,
                  width: 44,
                  height: 25,
                  padding: const EdgeInsets.all(3),
                  alignment: value
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  decoration: BoxDecoration(
                    color: value ? accent : context.applicationColors.control,
                    borderRadius: DenialSurfaceGeometry.borderRadiusOf(context),
                    border: Border.all(
                      color: value
                          ? accent
                          : context.applicationColors.separator,
                    ),
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: context.shellColors.sliderThumb,
                      borderRadius: DenialSurfaceGeometry.borderRadiusOf(
                        context,
                        inset: 3,
                      ),
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
  const _SettingsSliderTrackShape({required this.cornerRadius});

  final double cornerRadius;

  @override
  bool get isRounded => cornerRadius > 0;

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
      _controlRadius(trackRect.height / 2, cornerRadius),
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
    required this.cornerRadius,
    required this.shadowColor,
  });

  static const double _extent = 20;

  final double cornerRadius;
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
      Radius.circular(_controlRadius(_extent / 2, cornerRadius)),
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
  const _SettingsSliderOverlayShape({required this.cornerRadius});

  static const double _extent = 40;

  final double cornerRadius;

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
        Radius.circular(_controlRadius(_extent / 2, cornerRadius)),
      ),
      Paint()..color = overlayColor.withValues(alpha: overlayColor.a * opacity),
    );
  }
}

class _SettingsSliderTickMarkShape extends SliderTickMarkShape {
  const _SettingsSliderTickMarkShape({required this.cornerRadius});

  final double cornerRadius;

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
        Radius.circular(_controlRadius(extent / 2, cornerRadius)),
      ),
      Paint()..color = color,
    );
  }
}

double _controlRadius(double maximum, double radius) =>
    math.min(maximum, radius);

class SettingsChoice<T> {
  const SettingsChoice(this.value, this.label, {this.enabled = true});

  final T value;
  final String label;
  final bool enabled;
}

class SettingsSelect<T> extends StatelessWidget {
  const SettingsSelect({
    required this.label,
    required this.description,
    required this.value,
    required this.choices,
    required this.onChanged,
    this.enabled = true,
    super.key,
  });

  final String label;
  final String description;
  final T value;
  final List<SettingsChoice<T>> choices;
  final ValueChanged<T> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final selected = choices.firstWhere((choice) => choice.value == value);
    final selector = Semantics(
      button: true,
      enabled: enabled,
      label: label,
      value: selected.label,
      child: AnimatedOpacity(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : Motion.tile,
        opacity: enabled ? 1 : 0.46,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: context.applicationColors.control,
            borderRadius: DenialSurfaceGeometry.borderRadiusOf(context),
            border: Border.all(color: context.applicationColors.separator),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<T>(
                value: value,
                isExpanded: true,
                borderRadius: DenialSurfaceGeometry.borderRadiusOf(context),
                dropdownColor: context.applicationColors.raised,
                focusColor: Colors.transparent,
                icon: Icon(
                  Icons.expand_more_rounded,
                  color: context.applicationColors.secondary,
                ),
                items: <DropdownMenuItem<T>>[
                  for (final choice in choices)
                    DropdownMenuItem<T>(
                      value: choice.value,
                      enabled: choice.enabled,
                      child: Text(
                        choice.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ShellText.cardTitle,
                      ),
                    ),
                ],
                onChanged: enabled
                    ? (next) {
                        if (next != null) {
                          onChanged(next);
                        }
                      }
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
    return SettingsControlRow(
      label: label,
      description: description,
      control: selector,
    );
  }
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
              onPressed: choice.enabled ? () => onChanged(choice.value) : null,
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
  Widget build(BuildContext context) => Semantics(
    label: label,
    value: formatOpaqueColorHex(color),
    child: TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
        foregroundColor: context.applicationColors.foreground,
        backgroundColor: context.applicationColors.control,
        shape: RoundedRectangleBorder(
          borderRadius: DenialSurfaceGeometry.borderRadiusOf(context),
          side: BorderSide(color: context.applicationColors.separator),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: context.applicationColors.separator),
            ),
          ),
          const SizedBox(width: 9),
          Text(formatOpaqueColorHex(color)),
          const SizedBox(width: 7),
          const Icon(Icons.expand_more_rounded, size: 18),
        ],
      ),
    ),
  );
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
        width: 154,
        height: 154,
        child: GridView.count(
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 3,
          childAspectRatio: 1,
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

class _SettingsChoiceChip extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final accent = context.applicationTheme.shell.accent;
    return Semantics(
      checked: selectionControl ? selected : null,
      inMutuallyExclusiveGroup: selectionControl,
      selected: selectionControl ? null : selected,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
          foregroundColor: selected
              ? accent
              : context.applicationColors.foreground,
          backgroundColor: selected
              ? accent.withAlpha(32)
              : context.applicationColors.control,
          shape: RoundedRectangleBorder(
            borderRadius: DenialSurfaceGeometry.borderRadiusOf(context),
            side: BorderSide(
              color: selected ? accent : context.applicationColors.separator,
            ),
          ),
        ),
        child: Text(label),
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
    final accent = context.applicationTheme.shell.accent;
    final label = _anchorLabel(anchor, context);
    return Semantics(
      selected: selected,
      label: label,
      child: Tooltip(
        message: label,
        child: TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            padding: EdgeInsets.zero,
            minimumSize: const Size(44, 44),
            backgroundColor: selected
                ? accent.withAlpha(32)
                : context.applicationColors.control,
            shape: RoundedRectangleBorder(
              borderRadius: DenialSurfaceGeometry.borderRadiusOf(context),
              side: BorderSide(
                color: selected ? accent : context.applicationColors.separator,
              ),
            ),
          ),
          child: Icon(
            Icons.circle,
            size: selected ? 10 : 7,
            color: selected ? accent : context.applicationColors.secondary,
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
