import 'package:flutter/material.dart';

import '../../localization/denial_localizations.dart';
import '../../state/desktop_window_close_effect.dart';
import '../shell_settings.dart';
import 'settings_controls.dart';

class SettingsAnimationsPage extends StatelessWidget {
  const SettingsAnimationsPage({
    required this.settings,
    required this.onCloseEffectChanged,
    required this.onDurationScaleChanged,
    required this.onPanelTravelChanged,
    required this.onLockAnimationChanged,
    required this.onReset,
    super.key,
  });

  final ShellAnimationSettings settings;
  final ValueChanged<DesktopWindowCloseEffect> onCloseEffectChanged;
  final ValueChanged<double> onDurationScaleChanged;
  final ValueChanged<double> onPanelTravelChanged;
  final ValueChanged<bool> onLockAnimationChanged;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SettingsPageLayout(
      icon: Icons.animation_rounded,
      eyebrow: l10n.settingsAnimationsSection,
      title: l10n.settingsAnimationsTitle,
      onReset: onReset,
      children: [
        SettingsCardGroup(
          children: [
            SettingsSection(
              title: l10n.settingsWindowCloseEffectTitle,
              child: SettingsSegmentedControl<DesktopWindowCloseEffect>(
                value: settings.windowCloseEffect,
                choices: [
                  SettingsChoice(
                    DesktopWindowCloseEffect.explosion,
                    l10n.settingsCloseEffectExplosion,
                  ),
                  SettingsChoice(
                    DesktopWindowCloseEffect.implode,
                    l10n.settingsCloseEffectImplode,
                  ),
                  SettingsChoice(
                    DesktopWindowCloseEffect.fade,
                    l10n.settingsCloseEffectFade,
                  ),
                  SettingsChoice(
                    DesktopWindowCloseEffect.none,
                    l10n.settingsCloseEffectNone,
                  ),
                ],
                onChanged: onCloseEffectChanged,
              ),
            ),
            SettingsSection(
              title: l10n.settingsPanelMotionTitle,
              child: Column(
                children: [
                  SettingsSlider(
                    label: l10n.settingsAnimationSpeed,
                    value: 1 / settings.durationScale,
                    minimum: 0.5,
                    maximum: 2,
                    divisions: 30,
                    valueLabel: l10n.settingsAnimationSpeedValue(
                      (100 / settings.durationScale).round(),
                    ),
                    onChanged: (speed) => onDurationScaleChanged(1 / speed),
                  ),
                  const SizedBox(height: 8),
                  SettingsSlider(
                    label: l10n.settingsPanelTravel,
                    value: settings.panelTravel,
                    minimum: 0,
                    maximum: 96,
                    divisions: 48,
                    valueLabel: l10n.settingsPixels(
                      settings.panelTravel.round(),
                    ),
                    onChanged: onPanelTravelChanged,
                  ),
                ],
              ),
            ),
            SettingsSection(
              title: l10n.settingsLockMotionTitle,
              child: SettingsToggle(
                label: l10n.settingsAnimateLockScreen,
                description: l10n.settingsAnimateLockScreenDescription,
                value: settings.animateLockScreen,
                onChanged: onLockAnimationChanged,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
