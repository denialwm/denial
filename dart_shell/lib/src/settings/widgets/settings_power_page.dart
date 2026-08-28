import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../localization/denial_localizations.dart';
import '../../state/upower.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import '../shell_settings.dart';
import 'settings_battery_section.dart';
import 'settings_controls.dart';

const settingsIdleDpmsToggleKey = ValueKey<String>('settings-idle-dpms-toggle');
const settingsIdleDpmsTimeoutKey = ValueKey<String>(
  'settings-idle-dpms-timeout',
);

class SettingsPowerPage extends ConsumerWidget {
  const SettingsPowerPage({
    required this.settings,
    required this.onEnabledChanged,
    required this.onTimeoutChanged,
    required this.onReset,
    super.key,
  });

  final ShellPowerSettings settings;
  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<int> onTimeoutChanged;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final upower = ref.watch(upowerProvider);
    final upowerController = ref.read(upowerProvider.notifier);
    return SettingsPageLayout(
      icon: Icons.power_settings_new_rounded,
      eyebrow: l10n.settingsPowerSection,
      title: l10n.settingsPowerTitle,
      onReset: onReset,
      children: <Widget>[
        SettingsCardGroup(
          children: <Widget>[
            SettingsBatterySection(
              state: upower,
              onRefresh: () => unawaited(upowerController.refresh()),
              onChargeThresholdChanged: (battery, enabled) => unawaited(
                upowerController.setChargeThresholdEnabled(battery, enabled),
              ),
            ),
            _displayPowerSection(context),
          ],
        ),
      ],
    );
  }

  Widget _displayPowerSection(BuildContext context) {
    final l10n = context.l10n;
    return SettingsSection(
      title: l10n.settingsAutomaticDisplayPowerTitle,
      leading: _PowerIcon(accent: ShellTheme.of(context).accent),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsToggle(
            key: settingsIdleDpmsToggleKey,
            label: l10n.settingsAutomaticDisplayPowerToggle,
            description: l10n.settingsAutomaticDisplayPowerToggleDescription,
            value: settings.idleDpmsEnabled,
            onChanged: onEnabledChanged,
          ),
          const SizedBox(height: 18),
          Divider(height: 1, color: context.shellColors.hairlineSoft),
          const SizedBox(height: 18),
          SettingsSlider(
            key: settingsIdleDpmsTimeoutKey,
            label: l10n.settingsInactivityTimeout,
            value: settings.idleDpmsTimeoutMinutes.toDouble(),
            minimum: ShellPowerSettings.minimumIdleDpmsMinutes.toDouble(),
            maximum: ShellPowerSettings.maximumIdleDpmsMinutes.toDouble(),
            divisions:
                ShellPowerSettings.maximumIdleDpmsMinutes -
                ShellPowerSettings.minimumIdleDpmsMinutes,
            enabled: settings.idleDpmsEnabled,
            valueLabel: _timeoutLabel(l10n, settings.idleDpmsTimeoutMinutes),
            onChanged: (value) => onTimeoutChanged(value.round()),
          ),
          const SizedBox(height: 18),
          const _IdleInhibitNotice(),
        ],
      ),
    );
  }
}

class _PowerIcon extends StatelessWidget {
  const _PowerIcon({required this.accent});

  final Color accent;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: accent.withAlpha(34),
        shape: BoxShape.circle,
        border: Border.all(color: accent.withAlpha(92)),
      ),
      child: SizedBox.square(
        dimension: 42,
        child: Icon(Icons.bedtime_outlined, size: 20, color: accent),
      ),
    );
  }
}

class _IdleInhibitNotice extends StatelessWidget {
  const _IdleInhibitNotice();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Semantics(
      label: l10n.settingsIdleInhibitSemantics,
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.shellTheme.cardColor(
            context.shellColors.surfaceContainerHigh,
          ),
          borderRadius: context.shellTheme.borderRadius(ShellRadii.chip),
          border: Border.all(color: context.shellColors.hairlineSoft),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.ondemand_video_outlined,
                size: 18,
                color: context.shellColors.textTertiary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.settingsIdleInhibitDescription,
                  style: ShellText.base.copyWith(
                    color: context.shellColors.textSecondary,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _timeoutLabel(AppLocalizations l10n, int minutes) {
  if (minutes == 60) {
    return l10n.settingsOneHour;
  }
  if (minutes == 120) {
    return l10n.settingsTwoHours;
  }
  return l10n.settingsMinutes(minutes);
}
