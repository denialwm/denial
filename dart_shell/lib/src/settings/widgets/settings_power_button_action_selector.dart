import 'package:flutter/material.dart';

import '../../localization/denial_localizations.dart';
import '../../models/power_button_action.dart';
import 'settings_controls.dart';

class SettingsPowerButtonActionSelector extends StatelessWidget {
  const SettingsPowerButtonActionSelector({
    required this.value,
    required this.hibernateAvailable,
    required this.onChanged,
    super.key,
  });

  final PowerButtonAction value;
  final bool hibernateAvailable;
  final ValueChanged<PowerButtonAction> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SettingsSelect<PowerButtonAction>(
      label: l10n.settingsPowerButtonAction,
      description: l10n.settingsPowerButtonDescription,
      value: value,
      choices: <SettingsChoice<PowerButtonAction>>[
        SettingsChoice<PowerButtonAction>(
          PowerButtonAction.suspend,
          l10n.settingsPowerButtonSuspend,
        ),
        if (hibernateAvailable || value == PowerButtonAction.hibernate)
          SettingsChoice<PowerButtonAction>(
            PowerButtonAction.hibernate,
            hibernateAvailable
                ? l10n.settingsPowerButtonHibernate
                : l10n.settingsPowerButtonHibernateUnavailable,
            enabled: hibernateAvailable,
          ),
        SettingsChoice<PowerButtonAction>(
          PowerButtonAction.dpms,
          l10n.settingsPowerButtonDpms,
        ),
        SettingsChoice<PowerButtonAction>(
          PowerButtonAction.powerOff,
          l10n.settingsPowerButtonPowerOff,
        ),
      ],
      onChanged: onChanged,
    );
  }
}
