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
const settingsIdleLockToggleKey = ValueKey<String>('settings-idle-lock-toggle');
const settingsIdleLockTimeoutKey = ValueKey<String>(
  'settings-idle-lock-timeout',
);
const settingsIdleSuspendToggleKey = ValueKey<String>(
  'settings-idle-suspend-toggle',
);
const settingsIdleSuspendTimeoutKey = ValueKey<String>(
  'settings-idle-suspend-timeout',
);

class SettingsPowerPage extends ConsumerWidget {
  const SettingsPowerPage({
    required this.settings,
    required this.onLockEnabledChanged,
    required this.onLockTimeoutChanged,
    required this.onDpmsEnabledChanged,
    required this.onDpmsTimeoutChanged,
    required this.onSuspendEnabledChanged,
    required this.onSuspendTimeoutChanged,
    required this.onReset,
    super.key,
  });

  final ShellPowerSettings settings;
  final ValueChanged<bool> onLockEnabledChanged;
  final ValueChanged<int> onLockTimeoutChanged;
  final ValueChanged<bool> onDpmsEnabledChanged;
  final ValueChanged<int> onDpmsTimeoutChanged;
  final ValueChanged<bool> onSuspendEnabledChanged;
  final ValueChanged<int> onSuspendTimeoutChanged;
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
            _idlePolicySection(context),
          ],
        ),
      ],
    );
  }

  Widget _idlePolicySection(BuildContext context) {
    final l10n = context.l10n;
    final lockMaximum = settings.idleSuspendTimeoutMinutes;
    final suspendMinimum = settings.idleDpmsTimeoutMinutes;
    return SettingsSection(
      title: l10n.settingsAutomaticIdleTitle,
      leading: _PowerIcon(accent: ShellTheme.of(context).accent),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _IdleActionControls(
            toggleKey: settingsIdleLockToggleKey,
            sliderKey: settingsIdleLockTimeoutKey,
            label: l10n.settingsAutomaticLockToggle,
            description: l10n.settingsAutomaticLockToggleDescription,
            timeoutLabel: l10n.settingsLockTimeout,
            enabled: settings.idleLockEnabled,
            timeoutMinutes: settings.idleLockTimeoutMinutes,
            minimum: ShellPowerSettings.minimumIdleTimeoutMinutes,
            maximum: lockMaximum,
            onEnabledChanged: onLockEnabledChanged,
            onTimeoutChanged: onLockTimeoutChanged,
          ),
          const SizedBox(height: 18),
          Divider(height: 1, color: context.shellColors.hairlineSoft),
          const SizedBox(height: 18),
          _IdleActionControls(
            toggleKey: settingsIdleDpmsToggleKey,
            sliderKey: settingsIdleDpmsTimeoutKey,
            label: l10n.settingsAutomaticDisplayPowerToggle,
            description: l10n.settingsAutomaticDisplayPowerToggleDescription,
            timeoutLabel: l10n.settingsDisplayOffTimeout,
            enabled: settings.idleDpmsEnabled,
            timeoutMinutes: settings.idleDpmsTimeoutMinutes,
            minimum: ShellPowerSettings.minimumIdleTimeoutMinutes,
            maximum: settings.idleSuspendTimeoutMinutes,
            onEnabledChanged: onDpmsEnabledChanged,
            onTimeoutChanged: onDpmsTimeoutChanged,
          ),
          const SizedBox(height: 18),
          Divider(height: 1, color: context.shellColors.hairlineSoft),
          const SizedBox(height: 18),
          _IdleActionControls(
            toggleKey: settingsIdleSuspendToggleKey,
            sliderKey: settingsIdleSuspendTimeoutKey,
            label: l10n.settingsAutomaticSuspendToggle,
            description: l10n.settingsAutomaticSuspendToggleDescription,
            timeoutLabel: l10n.settingsSuspendTimeout,
            enabled: settings.idleSuspendEnabled,
            timeoutMinutes: settings.idleSuspendTimeoutMinutes,
            minimum: suspendMinimum,
            maximum: ShellPowerSettings.maximumIdleTimeoutMinutes,
            onEnabledChanged: onSuspendEnabledChanged,
            onTimeoutChanged: onSuspendTimeoutChanged,
          ),
          const SizedBox(height: 18),
          const _IdleInhibitNotice(),
        ],
      ),
    );
  }
}

class _IdleActionControls extends StatelessWidget {
  const _IdleActionControls({
    required this.toggleKey,
    required this.sliderKey,
    required this.label,
    required this.description,
    required this.timeoutLabel,
    required this.enabled,
    required this.timeoutMinutes,
    required this.minimum,
    required this.maximum,
    required this.onEnabledChanged,
    required this.onTimeoutChanged,
  });

  final Key toggleKey;
  final Key sliderKey;
  final String label;
  final String description;
  final String timeoutLabel;
  final bool enabled;
  final int timeoutMinutes;
  final int minimum;
  final int maximum;
  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<int> onTimeoutChanged;

  @override
  Widget build(BuildContext context) {
    final divisions = maximum - minimum;
    final sliderEnabled = enabled && divisions > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsToggle(
          key: toggleKey,
          label: label,
          description: description,
          value: enabled,
          onChanged: onEnabledChanged,
        ),
        const SizedBox(height: 18),
        SettingsSlider(
          key: sliderKey,
          label: timeoutLabel,
          value: timeoutMinutes.toDouble(),
          minimum: minimum.toDouble(),
          maximum: maximum.toDouble(),
          divisions: divisions > 0 ? divisions : null,
          enabled: sliderEnabled,
          valueLabel: _timeoutLabel(context.l10n, timeoutMinutes),
          onChanged: (value) => onTimeoutChanged(value.round()),
        ),
      ],
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
