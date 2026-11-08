import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/materials.dart';
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/state.dart';

import '../../state/reference_shell_profile.dart';
import '../device_info/device_info.dart';
import 'settings_controls.dart';

final deviceInfoProvider = FutureProvider.autoDispose<DeviceInfo>(
  (ref) => DeviceInfoService().load(),
);

class SettingsDevicePage extends ConsumerStatefulWidget {
  const SettingsDevicePage({super.key});

  @override
  ConsumerState<SettingsDevicePage> createState() =>
      _SettingsDevicePageState();
}

class _SettingsDevicePageState extends ConsumerState<SettingsDevicePage> {
  DeviceInfo? _latest;
  var _copied = false;
  Timer? _copiedTimer;

  @override
  void dispose() {
    _copiedTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy(BuildContext context) async {
    final info = _latest;
    if (info == null) return;
    final l10n = context.l10n;
    final lines = <String>[
      '${l10n.settingsDeviceModel}: ${info.displayName ?? '—'}',
      '${l10n.settingsDeviceCodename}: ${info.codename ?? '—'}',
      '${l10n.settingsDeviceOs}: ${info.osName ?? '—'}',
      '${l10n.settingsDeviceKernel}: ${info.kernel ?? '—'}',
      '${l10n.settingsDeviceArchitecture}: ${info.architecture ?? '—'}',
      '${l10n.settingsDeviceSoc}: ${info.socName ?? '—'}',
      '${l10n.settingsDeviceCpu}: ${info.cpuName ?? '—'}',
      '${l10n.settingsDeviceMemory}: ${_formatBytes(info.memoryTotalBytes)}',
      '${l10n.settingsDeviceStorage}: ${_formatBytes(info.storageTotalBytes)}',
      '${l10n.settingsDeviceVersion}: ${info.denialVersion ?? '—'}',
    ];
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    if (!mounted) return;
    setState(() => _copied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final info = ref.watch(deviceInfoProvider);
    final device = info.value;
    if (device != null) _latest = device;
    return SettingsPageScaffold(
      title: l10n.settingsDeviceTitle,
      description: l10n.settingsDeviceDescription,
      actions: [
        SettingsCommand(
          label: _copied ? l10n.settingsDeviceCopied : l10n.settingsDeviceCopy,
          icon: _copied ? Icons.check_rounded : Icons.copy_rounded,
          onPressed: device == null ? null : () => _copy(context),
        ),
      ],
      body: switch (info) {
        AsyncData(:final value) => LayoutBuilder(
          builder: (context, constraints) {
            final inset = settingsContentInset(constraints.maxWidth);
            return SingleChildScrollView(
              key: const PageStorageKey<String>('settings-page-device'),
              padding: EdgeInsets.fromLTRB(inset, 20, inset, 28),
              child: _DeviceBody(info: value),
            );
          },
        ),
        AsyncError(:final error) => _DeviceError(
          message: error.toString(),
          onRetry: () => ref.invalidate(deviceInfoProvider),
        ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class _DeviceBody extends ConsumerWidget {
  const _DeviceBody({required this.info});

  final DeviceInfo info;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final upower = ref.watch(upowerProvider).snapshot;
    final battery = upower?.batteries.firstOrNull;
    final network = ref.watch(networkConnectivityProvider).snapshot;
    final bluetooth = ref.watch(bluetoothProvider);
    final display = ref.watch(displayLayoutProvider)?.mainOutput;
    final profile = ref.watch(referenceShellProfileProvider);

    final chips = <Widget>[
      if (info.osName != null) _Chip(label: info.osName!),
      if (info.denialVersion != null)
        _Chip(label: 'Denial ${_shortVersion(info.denialVersion!)}'),
      if (info.architecture != null) _Chip(label: info.architecture!),
      if (info.formFactor != null)
        _Chip(label: _formFactorLabel(l10n, info.formFactor!), neutral: true),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DeviceHero(info: info, chips: chips),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 960
                ? 3
                : constraints.maxWidth >= 620
                ? 2
                : 1;
            final cards = <Widget>[
              _InfoCard(
                title: l10n.settingsDeviceCardHardware,
                icon: Icons.memory_rounded,
                rows: [
                  _InfoRow(
                    label: l10n.settingsDeviceSoc,
                    value: info.socName,
                    sub: info.socVendor,
                  ),
                  _InfoRow(
                    label: l10n.settingsDeviceCpu,
                    value: info.cpuName,
                    sub: info.cpuCores == null || info.cpuMaxClock == null
                        ? null
                        : l10n.settingsDeviceCpuDetail(
                            info.cpuCores!,
                            info.cpuMaxClock!,
                          ),
                  ),
                  _InfoRow(label: l10n.settingsDeviceGpu, value: info.gpu),
                  _InfoRow(
                    label: l10n.settingsDeviceMemory,
                    value: _formatBytes(info.memoryTotalBytes),
                    sub: info.memoryAvailableBytes == null
                        ? null
                        : l10n.settingsDeviceMemoryAvailable(
                            _formatBytes(info.memoryAvailableBytes),
                          ),
                  ),
                  _InfoRow(
                    label: l10n.settingsDeviceStorage,
                    value: _formatBytes(info.storageTotalBytes),
                    sub: info.storageFreeBytes == null
                        ? null
                        : l10n.settingsDeviceStorageFree(
                            _formatBytes(info.storageFreeBytes),
                          ),
                  ),
                  _InfoRow(
                    label: l10n.settingsDeviceBattery,
                    value: battery == null || battery.percentage == null
                        ? null
                        : '${battery.percentage!.round()}% · '
                              '${_batteryStateLabel(l10n, battery.state)}',
                    sub:
                        battery == null ||
                            (battery.healthPercentage == null &&
                                battery.chargeCycles == null)
                        ? null
                        : l10n.settingsDeviceBatteryDetail(
                            battery.healthPercentage?.round() ?? 0,
                            battery.chargeCycles ?? 0,
                          ),
                  ),
                ],
              ),
              _InfoCard(
                title: l10n.settingsDeviceCardSystem,
                icon: Icons.dns_outlined,
                rows: [
                  _InfoRow(
                    label: l10n.settingsDeviceOs,
                    value: info.osName,
                    sub: info.osBuild,
                  ),
                  _InfoRow(
                    label: l10n.settingsDeviceKernel,
                    value: info.kernel,
                    mono: true,
                  ),
                  _InfoRow(
                    label: l10n.settingsDeviceArchitecture,
                    value: info.architecture,
                  ),
                  _InfoRow(
                    label: l10n.settingsDeviceHostname,
                    value: info.hostname,
                    mono: true,
                  ),
                  _InfoRow(
                    label: l10n.settingsDeviceTimezone,
                    value: info.timezone,
                    sub: info.timezoneOffset,
                  ),
                  _InfoRow(
                    label: l10n.settingsDeviceUptime,
                    value: _formatUptime(l10n, info.uptime),
                  ),
                ],
              ),
              _InfoCard(
                title: l10n.settingsDeviceCardDevice,
                icon: Icons.tablet_android_rounded,
                rows: [
                  _InfoRow(
                    label: l10n.settingsDeviceModel,
                    value: info.displayName,
                  ),
                  _InfoRow(
                    label: l10n.settingsDeviceCodename,
                    value: info.codename,
                    mono: true,
                  ),
                  _InfoRow(
                    label: l10n.settingsDeviceHardwareVersion,
                    value: info.sku == null
                        ? info.codename
                        : '${info.codename ?? '—'} / ${info.sku}',
                    mono: true,
                  ),
                  _InfoRow(
                    label: l10n.settingsDeviceFirmware,
                    value: info.firmware,
                    mono: true,
                  ),
                  _InfoRow(
                    label: l10n.settingsDeviceManufacturer,
                    value: info.vendor,
                  ),
                  _InfoRow(
                    label: l10n.settingsDeviceFormFactor,
                    value: info.formFactor == null
                        ? null
                        : _formFactorLabel(l10n, info.formFactor!),
                  ),
                ],
              ),
              _InfoCard(
                title: l10n.settingsDeviceCardDisplay,
                icon: Icons.monitor_outlined,
                rows: [
                  _InfoRow(
                    label: l10n.settingsDeviceResolution,
                    value: display == null
                        ? null
                        : '${display.pixelSize.width.round()} × '
                              '${display.pixelSize.height.round()}',
                    mono: true,
                  ),
                  _InfoRow(
                    label: l10n.settingsDeviceRefreshRate,
                    value: display == null
                        ? null
                        : '${display.refreshRate.round()} Hz',
                  ),
                  _InfoRow(
                    label: l10n.settingsDeviceDisplayPort,
                    value: display?.name,
                    mono: true,
                  ),
                  _InfoRow(
                    label: l10n.settingsDeviceScale,
                    value: display == null
                        ? null
                        : l10n.settingsDeviceScaleDetail(
                            (display.scale * 100).round().toString(),
                            display.logicalRect.width.round(),
                            display.logicalRect.height.round(),
                          ),
                  ),
                  _InfoRow(
                    label: l10n.settingsDeviceOrientation,
                    value: display == null
                        ? null
                        : display.logicalRect.width > display.logicalRect.height
                        ? l10n.settingsDeviceLandscape
                        : l10n.settingsDevicePortrait,
                  ),
                ],
              ),
              _InfoCard(
                title: l10n.settingsDeviceCardConnection,
                icon: Icons.wifi_rounded,
                rows: [
                  _InfoRow(
                    label: l10n.settingsDeviceWifi,
                    value: network.connectedNetwork?.ssid,
                    sub: info.wifiInterface,
                  ),
                  _InfoRow(
                    label: l10n.settingsDeviceIp,
                    value: info.ipAddress,
                    mono: true,
                  ),
                  _InfoRow(
                    label: l10n.settingsDeviceMac,
                    value: info.macAddress,
                    mono: true,
                  ),
                  _InfoRow(
                    label: l10n.settingsDeviceBluetooth,
                    value: !bluetooth.available
                        ? null
                        : bluetooth.powered
                        ? l10n.settingsDeviceEnabled
                        : l10n.settingsDeviceDisabled,
                    sub: bluetooth.adapterName.isEmpty
                        ? null
                        : bluetooth.adapterName,
                  ),
                  _InfoRow(
                    label: l10n.settingsDeviceUsb,
                    value: 'USB-C',
                    sub: l10n.settingsDeviceNoExternal,
                  ),
                  _InfoRow(
                    label: l10n.settingsDeviceEthernet,
                    value: info.ethernetInterfaces.isEmpty
                        ? null
                        : info.ethernetInterfaces.join(', '),
                    mono: true,
                  ),
                ],
              ),
              _InfoCard(
                title: l10n.settingsDeviceCardDenial,
                icon: Icons.power_settings_new_rounded,
                rows: [
                  _InfoRow(
                    label: l10n.settingsDeviceVersion,
                    value: info.denialVersion,
                    mono: true,
                  ),
                  _InfoRow(
                    label: l10n.settingsDeviceCommit,
                    value: info.denialCommit,
                    mono: true,
                  ),
                  _InfoRow(
                    label: l10n.settingsDeviceEngine,
                    value: info.denialEngineVersion,
                    mono: true,
                  ),
                  _InfoRow(
                    label: l10n.settingsDevicePlugins,
                    value: info.pluginManagerVersion,
                    mono: true,
                  ),
                  _InfoRow(
                    label: l10n.settingsDeviceSession,
                    value: profile.name,
                    sub: 'Wayland',
                  ),
                  _InfoRow(
                    label: l10n.settingsDeviceBuild,
                    value: info.denialDirty
                        ? l10n.settingsDeviceLocalBuild
                        : l10n.settingsDeviceReleaseBuild,
                    sub: '${info.denialDirty ? 'dirty' : 'release'} · '
                        '${info.architecture ?? '—'}',
                  ),
                ],
              ),
            ];
            return _CardGrid(columns: columns, cards: cards);
          },
        ),
      ],
    );
  }
}

class _DeviceHero extends StatelessWidget {
  const _DeviceHero({required this.info, required this.chips});

  final DeviceInfo info;
  final List<Widget> chips;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    final compact = MediaQuery.sizeOf(context).width < 700;
    final summary = [
      if (info.codename != null) info.codename,
      if (info.formFactor != null)
        _formFactorLabel(context.l10n, info.formFactor!),
      if (info.socName != null) info.socName,
    ].whereType<String>().join(' · ');
    return DenialMaterial(
      role: DenialMaterialRole.card,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 20),
        child: Row(
          children: [
            Container(
              width: compact ? 120 : 196,
              height: compact ? 68 : 108,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color.alphaBlend(
                      accent.withValues(alpha: .38),
                      const Color(0xff18212e),
                    ),
                    const Color(0xff1a2330),
                  ],
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x33202c3c),
                    blurRadius: 22,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: Icon(
                Icons.tablet_android_rounded,
                size: compact ? 28 : 44,
                color: Colors.white.withValues(alpha: .78),
              ),
            ),
            SizedBox(width: compact ? 18 : 28),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    info.displayName ?? info.model ?? '—',
                    style: TextStyle(
                      fontSize: compact ? 23 : 30,
                      height: 1.15,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -.6,
                    ),
                  ),
                  if (summary.isNotEmpty) ...[
                    const SizedBox(height: 7),
                    Text(
                      summary,
                      style: TextStyle(
                        fontSize: 13.5,
                        color: context.applicationColors.secondary,
                      ),
                    ),
                  ],
                  if (chips.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Wrap(spacing: 8, runSpacing: 8, children: chips),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, this.neutral = false});

  final String label;
  final bool neutral;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: neutral
            ? context.applicationColors.control
            : accent.withValues(alpha: .13),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: neutral ? context.applicationColors.secondary : accent,
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.title,
    required this.icon,
    required this.rows,
  });

  final String title;
  final IconData icon;
  final List<_InfoRow> rows;

  @override
  Widget build(BuildContext context) {
    return DenialMaterial(
      role: DenialMaterialRole.card,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 17, color: ShellTheme.of(context).accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            for (final (index, row) in rows.indexed) ...[
              if (index > 0)
                Divider(
                  height: 1,
                  thickness: 1,
                  color: context.applicationColors.separator,
                ),
              row,
            ],
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.sub,
    this.mono = false,
  });

  final String label;
  final String? value;
  final String? sub;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final valueStyle = TextStyle(
      fontSize: mono ? 11.5 : 12.5,
      height: 1.35,
      fontWeight: FontWeight.w500,
      fontFamily: mono ? 'monospace' : null,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.35,
              color: context.applicationColors.secondary,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  value ?? '—',
                  textAlign: TextAlign.right,
                  style: valueStyle,
                ),
                if (sub != null)
                  Text(
                    sub!,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.35,
                      color: context.applicationColors.secondary.withValues(
                        alpha: .75,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CardGrid extends StatelessWidget {
  const _CardGrid({required this.columns, required this.cards});

  final int columns;
  final List<Widget> cards;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var start = 0; start < cards.length; start += columns) {
      final rowCards = cards.sublist(
        start,
        math.min(start + columns, cards.length),
      );
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var index = 0; index < columns; index++) ...[
                if (index > 0) const SizedBox(width: 14),
                Expanded(
                  child: index < rowCards.length
                      ? rowCards[index]
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        for (var index = 0; index < rows.length; index++) ...[
          if (index > 0) const SizedBox(height: 14),
          rows[index],
        ],
      ],
    );
  }
}

class _DeviceError extends StatelessWidget {
  const _DeviceError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: context.applicationColors.secondary),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: onRetry,
              child: Text(context.l10n.commonRetry),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatBytes(int? bytes) {
  if (bytes == null) return '—';
  const gib = 1024 * 1024 * 1024;
  return '${(bytes / gib).toStringAsFixed(1)} GiB';
}

String _formatUptime(AppLocalizations l10n, Duration? uptime) {
  if (uptime == null) return '—';
  if (uptime.inDays > 0) {
    return '${l10n.settingsDeviceUptimeDays(uptime.inDays)} '
        '${l10n.settingsDeviceUptimeHours(uptime.inHours % 24)}';
  }
  if (uptime.inHours > 0) {
    return '${l10n.settingsDeviceUptimeHours(uptime.inHours)} '
        '${l10n.settingsDeviceUptimeMinutes(uptime.inMinutes % 60)}';
  }
  if (uptime.inMinutes > 0) {
    return l10n.settingsDeviceUptimeMinutes(uptime.inMinutes);
  }
  return l10n.settingsDeviceUptimeSeconds;
}

String _batteryStateLabel(AppLocalizations l10n, UPowerBatteryState state) {
  return switch (state) {
    UPowerBatteryState.charging ||
    UPowerBatteryState.pendingCharge => l10n.settingsDeviceBatteryCharging,
    UPowerBatteryState.discharging ||
    UPowerBatteryState.pendingDischarge ||
    UPowerBatteryState.empty => l10n.settingsDeviceBatteryDischarging,
    UPowerBatteryState.fullyCharged => l10n.settingsDeviceBatteryFull,
    UPowerBatteryState.unknown => l10n.settingsDeviceBatteryUnknown,
  };
}

String _formFactorLabel(AppLocalizations l10n, DeviceFormFactor factor) {
  return switch (factor) {
    DeviceFormFactor.tablet => l10n.settingsDeviceFormFactorTablet,
    DeviceFormFactor.laptop => l10n.settingsDeviceFormFactorLaptop,
    DeviceFormFactor.desktop => l10n.settingsDeviceFormFactorDesktop,
    DeviceFormFactor.handheld => l10n.settingsDeviceFormFactorHandheld,
  };
}

/// "0.0.0.r382.g99a581c0.dirty-1" reads as "0.0.0.r382" on the hero chip.
String _shortVersion(String version) {
  final match = RegExp(r'^(\d+\.\d+\.\d+\.r\d+)').firstMatch(version);
  return match?.group(1) ?? version;
}
