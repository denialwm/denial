import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../localization/denial_localizations.dart';
import '../../services/upower_service.dart';
import '../../state/upower.dart';
import '../../theme/shell_theme.dart';
import '../../theme/shell_color_scheme.dart';
import '../../theme/tokens.dart';
import 'settings_controls.dart';

const settingsBatteryRefreshKey = ValueKey<String>('settings-battery-refresh');

ValueKey<String> settingsBatteryChargeLimitKey(String objectPath) =>
    ValueKey<String>('settings-battery-charge-limit-$objectPath');

class SettingsBatterySection extends StatelessWidget {
  const SettingsBatterySection({
    required this.state,
    required this.onRefresh,
    required this.onChargeThresholdChanged,
    super.key,
  });

  final UPowerState state;
  final VoidCallback onRefresh;
  final void Function(UPowerBattery battery, bool enabled)
  onChargeThresholdChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SettingsSection(
      title: l10n.settingsBatteryInformationTitle,
      leading: const _BatterySectionIcon(),
      status: _sectionStatus(l10n),
      trailing: SettingsTextButton(
        key: settingsBatteryRefreshKey,
        label: l10n.settingsRefresh,
        onPressed: state.refreshing ? null : onRefresh,
      ),
      child: _BatteryContent(
        state: state,
        onChargeThresholdChanged: onChargeThresholdChanged,
      ),
    );
  }

  String? _sectionStatus(AppLocalizations l10n) {
    if (state.refreshing) {
      return l10n.settingsBatteryRefreshing;
    }
    final snapshot = state.snapshot;
    if (snapshot == null) {
      return null;
    }
    return snapshot.onBattery
        ? l10n.settingsBatteryOnBatteryPower
        : l10n.settingsBatteryPluggedIn;
  }
}

class _BatterySectionIcon extends StatelessWidget {
  const _BatterySectionIcon();

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: accent.withAlpha(34),
        shape: BoxShape.circle,
        border: Border.all(color: accent.withAlpha(92)),
      ),
      child: SizedBox.square(
        dimension: 42,
        child: Icon(
          Icons.battery_charging_full_rounded,
          size: 20,
          color: accent,
        ),
      ),
    );
  }
}

class _BatteryContent extends StatelessWidget {
  const _BatteryContent({
    required this.state,
    required this.onChargeThresholdChanged,
  });

  final UPowerState state;
  final void Function(UPowerBattery battery, bool enabled)
  onChargeThresholdChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final snapshot = state.snapshot;
    if (state.loading && snapshot == null) {
      return _BatteryNotice(
        icon: Icons.sync_rounded,
        message: l10n.settingsBatteryLoading,
        busy: true,
      );
    }
    if (snapshot == null) {
      return _BatteryNotice(
        icon: Icons.battery_unknown_rounded,
        message: l10n.settingsBatteryServiceUnavailable,
        error: true,
      );
    }
    if (snapshot.batteries.isEmpty) {
      return _BatteryNotice(
        icon: Icons.battery_unknown_rounded,
        message: l10n.settingsBatteryNoSystemBattery,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (state.error != null) ...<Widget>[
          _BatteryNotice(
            icon: Icons.error_outline_rounded,
            message: l10n.settingsBatteryUpdateFailed,
            error: true,
          ),
          const SizedBox(height: 12),
        ],
        for (var index = 0; index < snapshot.batteries.length; index++) ...[
          _BatteryPanel(
            battery: snapshot.batteries[index],
            thresholdChanging: state.changingThresholds.contains(
              snapshot.batteries[index].objectPath,
            ),
            onChargeThresholdChanged: onChargeThresholdChanged,
          ),
          if (index != snapshot.batteries.length - 1)
            const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _BatteryNotice extends StatelessWidget {
  const _BatteryNotice({
    required this.icon,
    required this.message,
    this.busy = false,
    this.error = false,
  });

  final IconData icon;
  final String message;
  final bool busy;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final color = error
        ? context.shellColors.performanceBad
        : context.shellColors.textTertiary;
    return Semantics(
      liveRegion: true,
      label: message,
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.shellColors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(ShellRadii.chip),
          border: Border.all(color: context.shellColors.hairlineSoft),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: <Widget>[
              if (busy)
                SizedBox.square(
                  dimension: 17,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: ShellTheme.of(context).accent,
                  ),
                )
              else
                Icon(icon, size: 18, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: ShellText.base.copyWith(
                    color: error ? color : context.shellColors.textSecondary,
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

class _BatteryPanel extends StatelessWidget {
  const _BatteryPanel({
    required this.battery,
    required this.thresholdChanging,
    required this.onChargeThresholdChanged,
  });

  final UPowerBattery battery;
  final bool thresholdChanging;
  final void Function(UPowerBattery battery, bool enabled)
  onChargeThresholdChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final name = battery.displayName.isEmpty
        ? l10n.settingsBatteryUnknownDevice
        : battery.displayName;
    final percentage = battery.percentage?.clamp(0, 100).toDouble();
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.shellColors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(ShellRadii.tile),
          border: Border.all(color: context.shellColors.hairlineSoft),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _BatteryHeading(
                battery: battery,
                name: name,
                percentage: percentage,
              ),
              if (percentage != null) ...<Widget>[
                const SizedBox(height: 12),
                _BatteryLevelIndicator(percentage: percentage),
              ],
              const SizedBox(height: 14),
              _BatteryMetricGrid(battery: battery),
              if (battery.chargeThresholdSupported) ...<Widget>[
                const SizedBox(height: 14),
                Divider(height: 1, color: context.shellColors.hairlineSoft),
                const SizedBox(height: 14),
                _ChargeThresholdControls(
                  battery: battery,
                  changing: thresholdChanging,
                  onChanged: (value) =>
                      onChargeThresholdChanged(battery, value),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _BatteryHeading extends StatelessWidget {
  const _BatteryHeading({
    required this.battery,
    required this.name,
    required this.percentage,
  });

  final UPowerBattery battery;
  final String name;
  final double? percentage;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = _batteryStateLabel(l10n, battery);
    final color = _batteryStateColor(context.shellColors, battery);
    final charge = percentage == null
        ? l10n.batteryCapacityUnavailable
        : l10n.settingsPercent(percentage!.round());
    return LayoutBuilder(
      builder: (context, constraints) {
        final identity = Row(
          children: <Widget>[
            Icon(_batteryStateIcon(battery.state), size: 22, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: ShellText.cardTitle.copyWith(
                  color: context.shellColors.textPrimary,
                ),
              ),
            ),
          ],
        );
        final status = Column(
          crossAxisAlignment: constraints.maxWidth < 420
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.end,
          children: <Widget>[
            Text(
              charge,
              style: ShellText.cardTitle.copyWith(
                color: context.shellColors.textPrimary,
                fontFamily: ShellText.systemBarFontFamily,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              state,
              style: ShellText.base.copyWith(color: color, fontSize: 11),
            ),
          ],
        );
        if (constraints.maxWidth < 420) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              identity,
              const SizedBox(height: 8),
              Padding(padding: const EdgeInsets.only(left: 32), child: status),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Expanded(child: identity),
            const SizedBox(width: 16),
            status,
          ],
        );
      },
    );
  }
}

class _BatteryLevelIndicator extends StatelessWidget {
  const _BatteryLevelIndicator({required this.percentage});

  final double percentage;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Semantics(
      label: l10n.settingsBatteryChargeLevel,
      value: l10n.settingsPercent(percentage.round()),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(ShellRadii.chip),
        child: LinearProgressIndicator(
          value: percentage / 100,
          minHeight: 6,
          color: ShellTheme.of(context).accent,
          backgroundColor: context.shellColors.surfaceContainerHighest,
        ),
      ),
    );
  }
}

class _BatteryMetricGrid extends StatelessWidget {
  const _BatteryMetricGrid({required this.battery});

  final UPowerBattery battery;

  @override
  Widget build(BuildContext context) {
    final metrics = _metrics(context.l10n, battery);
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 520 ? 2 : 1;
        final width = columns == 2
            ? (constraints.maxWidth - 8) / 2
            : constraints.maxWidth;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final metric in metrics)
              SizedBox(
                width: width,
                child: _BatteryMetricTile(metric: metric),
              ),
          ],
        );
      },
    );
  }
}

class _BatteryMetricTile extends StatelessWidget {
  const _BatteryMetricTile({required this.metric});

  final _BatteryMetric metric;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.shellColors.surfaceContainer,
        borderRadius: BorderRadius.circular(ShellRadii.chip),
        border: Border.all(color: context.shellColors.hairlineSoft),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        child: Row(
          children: <Widget>[
            Icon(
              metric.icon,
              size: 16,
              color: context.shellColors.textTertiary,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                metric.label,
                style: ShellText.base.copyWith(
                  color: context.shellColors.textTertiary,
                  fontSize: 11,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                metric.value,
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: ShellText.cardTitle.copyWith(
                  color: context.shellColors.textSecondary,
                  fontFamily: metric.monospace
                      ? ShellText.systemBarFontFamily
                      : null,
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChargeThresholdControls extends StatelessWidget {
  const _ChargeThresholdControls({
    required this.battery,
    required this.changing,
    required this.onChanged,
  });

  final UPowerBattery battery;
  final bool changing;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final capabilities = <Widget>[
      if (battery.chargeStartThresholdSupported &&
          battery.chargeStartThreshold != null)
        _ThresholdChip(
          icon: Icons.play_arrow_rounded,
          label: l10n.settingsBatteryChargeStart,
          value: l10n.settingsPercent(battery.chargeStartThreshold!),
        ),
      if (battery.chargeEndThresholdSupported &&
          battery.chargeEndThreshold != null)
        _ThresholdChip(
          icon: Icons.stop_rounded,
          label: l10n.settingsBatteryChargeEnd,
          value: l10n.settingsPercent(battery.chargeEndThreshold!),
        ),
      if (battery.firmwareOptimizedChargingSupported)
        _ThresholdChip(
          icon: Icons.auto_awesome_rounded,
          label: l10n.settingsBatteryFirmwareOptimized,
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SettingsToggle(
          key: settingsBatteryChargeLimitKey(battery.objectPath),
          label: l10n.settingsBatteryChargeLimit,
          description: _chargeLimitDescription(l10n, battery),
          value: battery.chargeThresholdEnabled,
          enabled: !changing,
          onChanged: onChanged,
        ),
        if (capabilities.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: capabilities),
          const SizedBox(height: 9),
          Text(
            l10n.settingsBatteryChargeLimitLevelsReadOnly,
            style: ShellText.base.copyWith(
              color: context.shellColors.textTertiary,
              fontSize: 11,
              height: 1.35,
            ),
          ),
        ],
      ],
    );
  }
}

class _ThresholdChip extends StatelessWidget {
  const _ThresholdChip({required this.icon, required this.label, this.value});

  final IconData icon;
  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: accent.withAlpha(20),
        borderRadius: BorderRadius.circular(ShellRadii.chip),
        border: Border.all(color: accent.withAlpha(70)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 15, color: accent),
            const SizedBox(width: 6),
            Text(
              value == null ? label : '$label · $value',
              style: ShellText.cardTitle.copyWith(
                color: context.shellColors.textSecondary,
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BatteryMetric {
  const _BatteryMetric({
    required this.icon,
    required this.label,
    required this.value,
    this.monospace = true,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool monospace;
}

List<_BatteryMetric> _metrics(AppLocalizations l10n, UPowerBattery battery) {
  final metrics = <_BatteryMetric>[];
  void add(
    IconData icon,
    String label,
    String? value, {
    bool monospace = true,
  }) {
    if (value != null && value.trim().isNotEmpty) {
      metrics.add(
        _BatteryMetric(
          icon: icon,
          label: label,
          value: value,
          monospace: monospace,
        ),
      );
    }
  }

  add(
    Icons.health_and_safety_outlined,
    l10n.settingsBatteryHealth,
    battery.healthPercentage == null
        ? null
        : l10n.settingsPercent(battery.healthPercentage!.round()),
  );
  add(
    Icons.sync_rounded,
    l10n.settingsBatteryChargeCycles,
    battery.chargeCycles?.toString(),
  );
  add(
    Icons.battery_5_bar_rounded,
    l10n.settingsBatteryStoredEnergy,
    _wattHours(l10n, battery.energy),
  );
  add(
    Icons.battery_full_rounded,
    l10n.settingsBatteryFullCapacity,
    _fullCapacity(l10n, battery.energyFull, battery.energyFullDesign),
  );
  add(
    Icons.bolt_rounded,
    l10n.settingsBatteryPowerRate,
    battery.energyRate == null || battery.energyRate! <= 0
        ? null
        : l10n.powerWattsDecimal(battery.energyRate!.toStringAsFixed(1)),
  );
  add(
    Icons.electric_meter_outlined,
    l10n.settingsBatteryVoltage,
    battery.voltage == null || battery.voltage! <= 0
        ? null
        : l10n.voltageVolts(battery.voltage!.toStringAsFixed(2)),
  );
  add(
    Icons.thermostat_rounded,
    l10n.settingsBatteryTemperature,
    battery.temperature == null || battery.temperature! <= 0
        ? null
        : l10n.temperatureCelsius(battery.temperature!.round()),
  );
  add(
    Icons.science_outlined,
    l10n.settingsBatteryTechnology,
    _technologyLabel(l10n, battery.technology),
    monospace: false,
  );
  add(
    Icons.hourglass_bottom_rounded,
    l10n.settingsBatteryTimeRemaining,
    _durationLabel(l10n, battery.timeToEmpty),
  );
  add(
    Icons.hourglass_top_rounded,
    l10n.settingsBatteryTimeToFull,
    _durationLabel(l10n, battery.timeToFull),
  );
  add(Icons.memory_rounded, l10n.settingsBatteryDevice, battery.nativePath);
  add(Icons.numbers_rounded, l10n.settingsBatterySerial, battery.serial);
  return metrics;
}

String? _wattHours(AppLocalizations l10n, double? value) {
  return value == null || value <= 0
      ? null
      : l10n.settingsBatteryWattHours(value.toStringAsFixed(1));
}

String? _fullCapacity(AppLocalizations l10n, double? full, double? design) {
  if (full == null || full <= 0) {
    return null;
  }
  if (design == null || design <= 0) {
    return _wattHours(l10n, full);
  }
  return l10n.settingsBatteryFullCapacityValue(
    full.toStringAsFixed(1),
    design.toStringAsFixed(1),
  );
}

String? _durationLabel(AppLocalizations l10n, Duration? duration) {
  if (duration == null || duration.inMinutes <= 0) {
    return null;
  }
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  if (hours == 0) {
    return l10n.settingsMinutes(minutes);
  }
  if (hours == 1 && minutes == 0) {
    return l10n.settingsOneHour;
  }
  return l10n.settingsBatteryDuration(hours, minutes);
}

String? _technologyLabel(
  AppLocalizations l10n,
  UPowerBatteryTechnology technology,
) => switch (technology) {
  UPowerBatteryTechnology.lithiumIon => l10n.settingsBatteryLithiumIon,
  UPowerBatteryTechnology.lithiumPolymer => l10n.settingsBatteryLithiumPolymer,
  UPowerBatteryTechnology.lithiumIronPhosphate =>
    l10n.settingsBatteryLithiumIronPhosphate,
  UPowerBatteryTechnology.leadAcid => l10n.settingsBatteryLeadAcid,
  UPowerBatteryTechnology.nickelCadmium => l10n.settingsBatteryNickelCadmium,
  UPowerBatteryTechnology.nickelMetalHydride =>
    l10n.settingsBatteryNickelMetalHydride,
  UPowerBatteryTechnology.unknown => null,
};

String _batteryStateLabel(AppLocalizations l10n, UPowerBattery battery) {
  if (battery.warningLevel == UPowerWarningLevel.critical ||
      battery.warningLevel == UPowerWarningLevel.action) {
    return l10n.settingsBatteryCritical;
  }
  if (battery.warningLevel == UPowerWarningLevel.low) {
    return l10n.settingsBatteryLow;
  }
  return switch (battery.state) {
    UPowerBatteryState.charging => l10n.batteryCharging,
    UPowerBatteryState.discharging => l10n.batteryDischarging,
    UPowerBatteryState.empty => l10n.settingsBatteryEmpty,
    UPowerBatteryState.fullyCharged => l10n.settingsBatteryFullyCharged,
    UPowerBatteryState.pendingCharge => l10n.settingsBatteryPendingCharge,
    UPowerBatteryState.pendingDischarge => l10n.settingsBatteryPendingDischarge,
    UPowerBatteryState.unknown => l10n.batteryIdle,
  };
}

Color _batteryStateColor(ShellColorScheme colors, UPowerBattery battery) {
  if (battery.warningLevel == UPowerWarningLevel.critical ||
      battery.warningLevel == UPowerWarningLevel.action) {
    return colors.performanceBad;
  }
  if (battery.warningLevel == UPowerWarningLevel.low) {
    return colors.performanceWarning;
  }
  return switch (battery.state) {
    UPowerBatteryState.charging ||
    UPowerBatteryState.fullyCharged => colors.gestureArmed,
    _ => colors.textTertiary,
  };
}

IconData _batteryStateIcon(UPowerBatteryState state) => switch (state) {
  UPowerBatteryState.charging ||
  UPowerBatteryState.pendingCharge => Icons.battery_charging_full_rounded,
  UPowerBatteryState.fullyCharged => Icons.battery_full_rounded,
  UPowerBatteryState.empty => Icons.battery_0_bar_rounded,
  _ => Icons.battery_5_bar_rounded,
};

String _chargeLimitDescription(AppLocalizations l10n, UPowerBattery battery) {
  final start = battery.chargeStartThreshold;
  final end = battery.chargeEndThreshold;
  if (battery.chargeStartThresholdSupported &&
      battery.chargeEndThresholdSupported &&
      start != null &&
      end != null) {
    return l10n.settingsBatteryChargeLimitStartEndDescription(start, end);
  }
  if (battery.chargeEndThresholdSupported && end != null) {
    return l10n.settingsBatteryChargeLimitEndDescription(end);
  }
  if (battery.firmwareOptimizedChargingSupported) {
    return l10n.settingsBatteryChargeLimitOptimizedDescription;
  }
  return l10n.settingsBatteryChargeLimitDescription;
}
