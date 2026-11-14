import 'package:flutter/material.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/models.dart';

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

class SettingsPowerButtonLongPressSelector extends StatelessWidget {
  const SettingsPowerButtonLongPressSelector({
    required this.value,
    required this.hibernateAvailable,
    required this.onChanged,
    super.key,
  });

  final PowerButtonLongPressAction value;
  final bool hibernateAvailable;
  final ValueChanged<PowerButtonLongPressAction> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SettingsSelect<PowerButtonLongPressAction>(
      label: l10n.settingsPowerButtonLongPress,
      description: l10n.settingsPowerButtonLongPressDescription,
      value: value,
      choices: <SettingsChoice<PowerButtonLongPressAction>>[
        SettingsChoice<PowerButtonLongPressAction>(
          PowerButtonLongPressAction.nothing,
          l10n.settingsPowerButtonLongPressNothing,
        ),
        SettingsChoice<PowerButtonLongPressAction>(
          PowerButtonLongPressAction.powerMenu,
          l10n.settingsPowerButtonLongPressMenu,
        ),
        SettingsChoice<PowerButtonLongPressAction>(
          PowerButtonLongPressAction.suspend,
          l10n.settingsPowerButtonSuspend,
        ),
        if (hibernateAvailable || value == PowerButtonLongPressAction.hibernate)
          SettingsChoice<PowerButtonLongPressAction>(
            PowerButtonLongPressAction.hibernate,
            hibernateAvailable
                ? l10n.settingsPowerButtonHibernate
                : l10n.settingsPowerButtonHibernateUnavailable,
            enabled: hibernateAvailable,
          ),
        SettingsChoice<PowerButtonLongPressAction>(
          PowerButtonLongPressAction.powerOff,
          l10n.settingsPowerButtonPowerOff,
        ),
      ],
      onChanged: onChanged,
    );
  }
}
