import 'package:flutter/material.dart';

import '../../localization/denial_localizations.dart';
import '../../settings/shell_settings.dart';
import '../../theme/tokens.dart';
import 'settings_controls.dart';

const settingsAccentColorTriggerKey = ValueKey<String>(
  'settings-accent-color-trigger',
);
const settingsBackdropBlurToggleKey = ValueKey<String>(
  'settings-backdrop-blur-toggle',
);
const settingsBackdropBlurSliderKey = ValueKey<String>(
  'settings-backdrop-blur-slider',
);

class SettingsAppearancePage extends StatelessWidget {
  const SettingsAppearancePage({
    required this.settings,
    required this.extractedAccent,
    required this.onAccentSourceChanged,
    required this.onOpenAccentPicker,
    required this.onWindowRadiusChanged,
    required this.onPanelRadiusChanged,
    required this.onPanelOpacityChanged,
    required this.onBackdropBlurEnabledChanged,
    required this.onBackdropBlurSigmaChanged,
    required this.onFocusedOpacityChanged,
    required this.onUnfocusedOpacityChanged,
    required this.onReset,
    super.key,
  });

  final ShellAppearanceSettings settings;
  final Color extractedAccent;
  final ValueChanged<ShellAccentSource> onAccentSourceChanged;
  final VoidCallback onOpenAccentPicker;
  final ValueChanged<double> onWindowRadiusChanged;
  final ValueChanged<double> onPanelRadiusChanged;
  final ValueChanged<double> onPanelOpacityChanged;
  final ValueChanged<bool> onBackdropBlurEnabledChanged;
  final ValueChanged<double> onBackdropBlurSigmaChanged;
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
      onReset: onReset,
      children: [
        SettingsCardGroup(
          children: [
            SettingsSection(
              title: l10n.settingsShellAccentTitle,
              leading: _ColorOrb(color: effectiveAccent),
              trailing: settings.accentSource == ShellAccentSource.custom
                  ? SettingsColorButton(
                      key: settingsAccentColorTriggerKey,
                      color: settings.customAccentColor,
                      label: l10n.settingsShellAccentChoose,
                      onPressed: onOpenAccentPicker,
                    )
                  : null,
              child: SettingsSegmentedControl<ShellAccentSource>(
                value: settings.accentSource,
                choices: [
                  SettingsChoice(
                    ShellAccentSource.wallpaper,
                    l10n.settingsShellAccentWallpaper,
                  ),
                  SettingsChoice(
                    ShellAccentSource.custom,
                    l10n.settingsShellAccentCustom,
                  ),
                ],
                onChanged: onAccentSourceChanged,
              ),
            ),
            SettingsSection(
              title: l10n.settingsBackdropBlur,
              child: Column(
                children: [
                  SettingsToggle(
                    key: settingsBackdropBlurToggleKey,
                    label: l10n.settingsBackdropBlurEnabled,
                    description: l10n.settingsBackdropBlurEnabledDescription,
                    value: settings.backdropBlurEnabled,
                    onChanged: onBackdropBlurEnabledChanged,
                  ),
                  const SizedBox(height: 12),
                  SettingsSlider(
                    key: settingsBackdropBlurSliderKey,
                    label: l10n.settingsBackdropBlurIntensity,
                    value: settings.backdropBlurSigma,
                    minimum: 4,
                    maximum: 32,
                    divisions: 28,
                    enabled: settings.backdropBlurEnabled,
                    valueLabel: l10n.settingsPixels(
                      settings.backdropBlurSigma.round(),
                    ),
                    onChanged: onBackdropBlurSigmaChanged,
                  ),
                ],
              ),
            ),
            SettingsSection(
              title: l10n.settingsShapeTitle,
              child: Column(
                children: [
                  SettingsSlider(
                    label: l10n.settingsWindowRadius,
                    value: settings.windowRadius,
                    minimum: 0,
                    maximum: 48,
                    divisions: 48,
                    valueLabel: l10n.settingsPixels(
                      settings.windowRadius.round(),
                    ),
                    onChanged: onWindowRadiusChanged,
                  ),
                  const SizedBox(height: 8),
                  SettingsSlider(
                    label: l10n.settingsPanelRadius,
                    value: settings.panelRadius,
                    minimum: 8,
                    maximum: 56,
                    divisions: 48,
                    valueLabel: l10n.settingsPixels(
                      settings.panelRadius.round(),
                    ),
                    onChanged: onPanelRadiusChanged,
                  ),
                  const SizedBox(height: 8),
                  SettingsSlider(
                    label: l10n.settingsPanelOpacity,
                    value: settings.panelOpacity,
                    minimum: 0.35,
                    maximum: 1,
                    divisions: 65,
                    valueLabel: l10n.settingsPercent(
                      (settings.panelOpacity * 100).round(),
                    ),
                    onChanged: onPanelOpacityChanged,
                  ),
                ],
              ),
            ),
            SettingsSection(
              title: l10n.settingsWindowOpacityTitle,
              child: Column(
                children: [
                  SettingsSlider(
                    label: l10n.settingsFocusedWindows,
                    value: settings.focusedWindowOpacity,
                    minimum: 0.35,
                    maximum: 1,
                    divisions: 65,
                    valueLabel: l10n.settingsPercent(
                      (settings.focusedWindowOpacity * 100).round(),
                    ),
                    onChanged: onFocusedOpacityChanged,
                  ),
                  const SizedBox(height: 8),
                  SettingsSlider(
                    label: l10n.settingsUnfocusedWindows,
                    value: settings.unfocusedWindowOpacity,
                    minimum: 0.2,
                    maximum: 1,
                    divisions: 80,
                    valueLabel: l10n.settingsPercent(
                      (settings.unfocusedWindowOpacity * 100).round(),
                    ),
                    onChanged: onUnfocusedOpacityChanged,
                  ),
                ],
              ),
            ),
          ],
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
