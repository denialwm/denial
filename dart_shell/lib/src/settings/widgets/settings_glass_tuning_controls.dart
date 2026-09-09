import 'package:flutter/material.dart';

import '../../localization/denial_localizations.dart';
import '../../theme/glass_configuration.dart';
import 'settings_controls.dart';

/// Additional optical controls, preserving the original material by default.
class SettingsGlassTuningControls extends StatelessWidget {
  const SettingsGlassTuningControls({
    required this.configuration,
    required this.onChanged,
    super.key,
  });

  final ShellGlassConfiguration configuration;
  final ValueChanged<ShellGlassConfiguration> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SettingsSection(
      title: l10n.settingsGlassAdvanced,
      trailing: SettingsTextButton(
        key: const ValueKey('settings-glass-reset'),
        label: l10n.settingsGlassReset,
        onPressed: () => onChanged(
          const ShellGlassConfiguration().copyWith(
            appearance: configuration.appearance,
            opacity: configuration.opacity,
          ),
        ),
      ),
      child: FocusTraversalGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.settingsGlassTuningDescription),
            const SizedBox(height: 8),
            SettingsSlider(
              key: const ValueKey('settings-glass-bevelWidthScale'),
              label: l10n.settingsGlassBevelWidth,
              value: configuration.bevelWidthScale,
              minimum: ShellGlassConfiguration.minimumBevelWidthScale,
              maximum: ShellGlassConfiguration.maximumBevelWidthScale,
              divisions: 55,
              valueLabel: l10n.settingsPercent(
                (configuration.bevelWidthScale * 100).round(),
              ),
              onChanged: (value) =>
                  onChanged(configuration.copyWith(bevelWidthScale: value)),
            ),
            const SizedBox(height: 8),
            SettingsSlider(
              key: const ValueKey('settings-glass-refractionDepthScale'),
              label: l10n.settingsGlassRefractionDepth,
              value: configuration.refractionDepthScale,
              minimum: ShellGlassConfiguration.minimumRefractionDepthScale,
              maximum: ShellGlassConfiguration.maximumRefractionDepthScale,
              divisions: 55,
              valueLabel: l10n.settingsPercent(
                (configuration.refractionDepthScale * 100).round(),
              ),
              onChanged: (value) => onChanged(
                configuration.copyWith(refractionDepthScale: value),
              ),
            ),
            const SizedBox(height: 8),
            SettingsSlider(
              key: const ValueKey('settings-glass-rimWidth'),
              label: l10n.settingsGlassRimWidth,
              value: configuration.rimWidth,
              minimum: ShellGlassConfiguration.minimumRimWidth,
              maximum: ShellGlassConfiguration.maximumRimWidth,
              divisions: 55,
              valueLabel: l10n.settingsGlassRimPixels(
                configuration.rimWidth.toStringAsFixed(1),
              ),
              onChanged: (value) =>
                  onChanged(configuration.copyWith(rimWidth: value)),
            ),
            const SizedBox(height: 8),
            SettingsSlider(
              key: const ValueKey('settings-glass-rimFalloff'),
              label: l10n.settingsGlassRimFalloff,
              value: configuration.rimFalloff,
              minimum: ShellGlassConfiguration.minimumRimFalloff,
              maximum: ShellGlassConfiguration.maximumRimFalloff,
              divisions: 290,
              valueLabel: configuration.rimFalloff.toStringAsFixed(2),
              onChanged: (value) =>
                  onChanged(configuration.copyWith(rimFalloff: value)),
            ),
            const SizedBox(height: 8),
            SettingsSlider(
              key: const ValueKey('settings-glass-oppositeLightStrength'),
              label: l10n.settingsGlassOppositeLight,
              value: configuration.oppositeLightStrength,
              minimum: ShellGlassConfiguration.minimumOppositeLightStrength,
              maximum: ShellGlassConfiguration.maximumOppositeLightStrength,
              divisions: 150,
              valueLabel: l10n.settingsPercent(
                (configuration.oppositeLightStrength * 100).round(),
              ),
              onChanged: (value) => onChanged(
                configuration.copyWith(oppositeLightStrength: value),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
