import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../localization/denial_localizations.dart';
import '../../state/input_device_capabilities.dart';
import '../../theme/tokens.dart';
import 'settings_controls.dart';

const settingsTapToClickToggleKey = Key('settings-touchpad-tap-to-click');
const settingsNaturalScrollToggleKey = Key('settings-touchpad-natural-scroll');

class SettingsTouchpadPage extends ConsumerWidget {
  const SettingsTouchpadPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final state = ref.watch(inputDeviceCapabilitiesProvider);
    final controller = ref.read(inputDeviceCapabilitiesProvider.notifier);
    final capabilities = state.capabilities;
    return SettingsPageLayout(
      icon: Icons.touch_app_rounded,
      eyebrow: l10n.settingsTouchpadSection,
      title: l10n.settingsTouchpadTitle,
      children: [
        SettingsCardGroup(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: SettingsToggle(
                key: settingsTapToClickToggleKey,
                label: l10n.settingsTouchpadTapToClick,
                description: l10n.settingsTouchpadTapToClickDescription,
                value: capabilities.tapToClickEnabled,
                enabled: !state.busy,
                onChanged: controller.setTapToClick,
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SettingsToggle(
                key: settingsNaturalScrollToggleKey,
                label: l10n.settingsTouchpadNaturalScroll,
                description: l10n.settingsTouchpadNaturalScrollDescription,
                value: capabilities.naturalScrollEnabled,
                enabled: !state.busy,
                onChanged: controller.setNaturalScroll,
              ),
            ),
          ],
        ),
        if (state.error case final error?)
          Semantics(
            liveRegion: true,
            child: Text(
              error,
              style: ShellText.base.copyWith(color: ShellColors.performanceBad),
            ),
          ),
      ],
    );
  }
}
