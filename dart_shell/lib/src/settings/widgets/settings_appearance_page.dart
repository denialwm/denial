import 'package:flutter/material.dart';

import '../../localization/denial_localizations.dart';
import '../../settings/shell_settings.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import 'settings_controls.dart';

const settingsFocusedBorderColorTriggerKey = ValueKey<String>(
  'settings-focused-border-color-trigger',
);
const settingsAccentColorTriggerKey = ValueKey<String>(
  'settings-accent-color-trigger',
);

class SettingsAppearancePage extends StatelessWidget {
  const SettingsAppearancePage({
    required this.settings,
    required this.extractedAccent,
    required this.onAccentSourceChanged,
    required this.onOpenAccentPicker,
    required this.onOpenBorderPicker,
    required this.onWindowRadiusChanged,
    required this.onPanelRadiusChanged,
    required this.onPanelOpacityChanged,
    required this.onFocusedOpacityChanged,
    required this.onUnfocusedOpacityChanged,
    required this.onReset,
    super.key,
  });

  final ShellAppearanceSettings settings;
  final Color extractedAccent;
  final ValueChanged<ShellAccentSource> onAccentSourceChanged;
  final VoidCallback onOpenAccentPicker;
  final VoidCallback onOpenBorderPicker;
  final ValueChanged<double> onWindowRadiusChanged;
  final ValueChanged<double> onPanelRadiusChanged;
  final ValueChanged<double> onPanelOpacityChanged;
  final ValueChanged<double> onFocusedOpacityChanged;
  final ValueChanged<double> onUnfocusedOpacityChanged;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final effectiveAccent = settings.accentSource == ShellAccentSource.wallpaper
        ? extractedAccent
        : settings.customAccentColor;
    return SettingsPageLayout(
      icon: Icons.palette_outlined,
      eyebrow: l10n.settingsAppearanceSection,
      title: l10n.settingsAppearanceTitle,
      description: l10n.settingsAppearanceDescription,
      onReset: onReset,
      children: [
        SettingsCard(
          title: 'Shell accent',
          description:
              'Follow the dominant wallpaper color or choose a permanent accent.',
          leading: _ColorOrb(color: effectiveAccent),
          trailing: settings.accentSource == ShellAccentSource.custom
              ? SettingsColorButton(
                  key: settingsAccentColorTriggerKey,
                  color: settings.customAccentColor,
                  label: 'Choose custom shell accent',
                  onPressed: onOpenAccentPicker,
                )
              : null,
          child: SettingsSegmentedControl<ShellAccentSource>(
            value: settings.accentSource,
            choices: const [
              SettingsChoice(ShellAccentSource.wallpaper, 'From wallpaper'),
              SettingsChoice(ShellAccentSource.custom, 'Custom color'),
            ],
            onChanged: onAccentSourceChanged,
          ),
        ),
        SettingsCard(
          title: l10n.settingsFocusedBorderTitle,
          description: l10n.settingsFocusedBorderDescription,
          leading: _WindowPreview(
            color: settings.focusedWindowBorderColor,
            radius: settings.windowRadius,
            semanticsLabel: l10n.settingsFocusedBorderPreviewSemanticsLabel,
          ),
          trailing: SettingsColorButton(
            key: settingsFocusedBorderColorTriggerKey,
            color: settings.focusedWindowBorderColor,
            label: l10n.settingsFocusedBorderChangeSemanticsLabel,
            onPressed: onOpenBorderPicker,
          ),
          child: const SizedBox.shrink(),
        ),
        SettingsCard(
          title: 'Shape & surfaces',
          description:
              'Tune the geometry shared by windows and floating shell panels.',
          child: Column(
            children: [
              SettingsSlider(
                label: 'Window corner radius',
                value: settings.windowRadius,
                minimum: 0,
                maximum: 48,
                divisions: 48,
                valueLabel: '${settings.windowRadius.round()} px',
                onChanged: onWindowRadiusChanged,
              ),
              const SizedBox(height: 8),
              SettingsSlider(
                label: 'Panel corner radius',
                value: settings.panelRadius,
                minimum: 8,
                maximum: 56,
                divisions: 48,
                valueLabel: '${settings.panelRadius.round()} px',
                onChanged: onPanelRadiusChanged,
              ),
              const SizedBox(height: 8),
              SettingsSlider(
                label: 'Panel alpha',
                value: settings.panelOpacity,
                minimum: 0.35,
                maximum: 1,
                divisions: 65,
                valueLabel: '${(settings.panelOpacity * 100).round()}%',
                onChanged: onPanelOpacityChanged,
              ),
            ],
          ),
        ),
        SettingsCard(
          title: 'Window alpha',
          description:
              'Keep focus obvious without forcing applications to draw their own dim state.',
          child: Column(
            children: [
              SettingsSlider(
                label: 'Focused windows',
                value: settings.focusedWindowOpacity,
                minimum: 0.35,
                maximum: 1,
                divisions: 65,
                valueLabel: '${(settings.focusedWindowOpacity * 100).round()}%',
                onChanged: onFocusedOpacityChanged,
              ),
              const SizedBox(height: 8),
              SettingsSlider(
                label: 'Unfocused windows',
                value: settings.unfocusedWindowOpacity,
                minimum: 0.2,
                maximum: 1,
                divisions: 80,
                valueLabel:
                    '${(settings.unfocusedWindowOpacity * 100).round()}%',
                onChanged: onUnfocusedOpacityChanged,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ColorOrb extends StatelessWidget {
  const _ColorOrb({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: ShellColors.panelHighlight),
        boxShadow: [BoxShadow(color: color.withAlpha(48), blurRadius: 18)],
      ),
    );
  }
}

class _WindowPreview extends StatelessWidget {
  const _WindowPreview({
    required this.color,
    required this.radius,
    required this.semanticsLabel,
  });

  final Color color;
  final double radius;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final safeRadius = radius.clamp(0, 32).toDouble();
    return Semantics(
      image: true,
      label: semanticsLabel,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        width: 92,
        height: 62,
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: ShellColors.windowFrameSurface,
          borderRadius: BorderRadius.circular(safeRadius + 2),
          border: Border.all(color: color, width: 2),
          boxShadow: [BoxShadow(color: color.withAlpha(42), blurRadius: 16)],
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: ShellTheme.of(
              context,
            ).panelColor(ShellColors.surfaceContainerHigh),
            borderRadius: BorderRadius.circular(safeRadius),
          ),
        ),
      ),
    );
  }
}
