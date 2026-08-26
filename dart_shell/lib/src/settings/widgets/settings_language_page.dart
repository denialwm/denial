import 'package:flutter/material.dart';

import '../../localization/denial_localizations.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import '../shell_settings.dart';
import 'settings_controls.dart';

const settingsLanguageSelectorKey = ValueKey<String>(
  'settings-language-selector',
);

class SettingsLanguagePage extends StatelessWidget {
  const SettingsLanguagePage({
    required this.settings,
    required this.onChanged,
    required this.onReset,
    super.key,
  });

  final ShellLocalizationSettings settings;
  final ValueChanged<ShellLocalePreference> onChanged;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SettingsPageLayout(
      icon: Icons.translate_rounded,
      eyebrow: l10n.settingsLanguageSection,
      title: l10n.settingsLanguageTitle,
      onReset: onReset,
      children: [
        SettingsCardGroup(
          children: [
            SettingsSection(
              title: l10n.settingsLanguageInterfaceTitle,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.settingsLanguageDescription,
                    style: ShellText.base.copyWith(
                      color: context.shellColors.textSecondary,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Semantics(
                    key: settingsLanguageSelectorKey,
                    container: true,
                    explicitChildNodes: true,
                    label: l10n.settingsLanguageSelectorSemantics,
                    child: SettingsSegmentedControl<ShellLocalePreference>(
                      value: settings.locale,
                      choices: [
                        SettingsChoice(
                          ShellLocalePreference.system,
                          l10n.settingsLanguageSystemDefault,
                        ),
                        SettingsChoice(
                          ShellLocalePreference.english,
                          l10n.settingsLanguageEnglish,
                        ),
                        SettingsChoice(
                          ShellLocalePreference.simplifiedChinese,
                          l10n.settingsLanguageSimplifiedChinese,
                        ),
                      ],
                      onChanged: onChanged,
                    ),
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
