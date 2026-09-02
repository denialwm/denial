import 'package:flutter/material.dart';

import '../../localization/denial_localizations.dart';
import '../../models/suspend_mode.dart';
import 'settings_controls.dart';

class SettingsSuspendModeSelector extends StatelessWidget {
  const SettingsSuspendModeSelector({
    required this.capabilities,
    required this.preferredMode,
    required this.onChanged,
    super.key,
  });

  final SuspendModeCapabilities capabilities;
  final SuspendMode preferredMode;
  final ValueChanged<SuspendMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final choices = capabilities.supported
        .map(
          (mode) => SettingsChoice<SuspendMode>(mode, switch (mode) {
            SuspendMode.s2idle => l10n.settingsSuspendModeS2idle,
            SuspendMode.shallow => l10n.settingsSuspendModeShallow,
            SuspendMode.deep => l10n.settingsSuspendModeDeep,
            SuspendMode.systemDefault => l10n.settingsSuspendModeUnavailable,
          }),
        )
        .toList(growable: false);
    final effectiveChoices = choices.isEmpty
        ? <SettingsChoice<SuspendMode>>[
            SettingsChoice<SuspendMode>(
              SuspendMode.systemDefault,
              l10n.settingsSuspendModeUnavailable,
            ),
          ]
        : choices;
    return SettingsSelect<SuspendMode>(
      label: l10n.settingsSuspendMode,
      description: l10n.settingsSuspendModeDescription,
      value: capabilities.effectiveSelection(preferredMode),
      choices: effectiveChoices,
      enabled: capabilities.canSelect,
      onChanged: onChanged,
    );
  }
}
