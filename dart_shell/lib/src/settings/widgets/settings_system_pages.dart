import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../localization/denial_localizations.dart';
import '../../services/audio_service.dart';
import '../../services/bluetooth_service.dart';
import '../../services/network_manager_service.dart';
import '../../state/app_audio.dart';
import '../../state/bluetooth.dart';
import '../../state/network_connectivity.dart';
import '../../state/quick_settings.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import 'settings_controls.dart';

class SettingsAudioPage extends ConsumerStatefulWidget {
  const SettingsAudioPage({super.key});

  @override
  ConsumerState<SettingsAudioPage> createState() => _SettingsAudioPageState();
}

class _SettingsAudioPageState extends ConsumerState<SettingsAudioPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(appAudioProvider.notifier).refresh();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final quick = ref.watch(quickSettingsProvider);
    final quickController = ref.read(quickSettingsProvider.notifier);
    final applications = ref.watch(appAudioProvider);
    final applicationController = ref.read(appAudioProvider.notifier);
    return SettingsPageLayout(
      icon: Icons.volume_up_rounded,
      eyebrow: l10n.settingsAudioSection,
      title: l10n.settingsAudioTitle,
      onReset: () => quickController.commitVolume(0.46),
      children: [
        SettingsCardGroup(
          children: [
            SettingsSection(
              title: l10n.settingsMasterOutputTitle,
              child: SettingsSlider(
                label: l10n.settingsOutputVolume,
                value: quick.volume,
                minimum: 0,
                maximum: 1,
                divisions: 100,
                valueLabel: l10n.settingsPercent((quick.volume * 100).round()),
                onChangeStart: (_) => quickController.beginVolumeInteraction(),
                onChanged: quickController.setVolume,
                onChangeEnd: quickController.commitVolume,
              ),
            ),
            SettingsSection(
              title: l10n.settingsApplicationAudioTitle,
              trailing: SettingsTextButton(
                label: l10n.settingsRefresh,
                onPressed: applicationController.refresh,
              ),
              child: _ApplicationAudioList(
                state: applications,
                onChanged: applicationController.setVolume,
                onChangeEnd: applicationController.commitVolume,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ApplicationAudioList extends StatelessWidget {
  const _ApplicationAudioList({
    required this.state,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final AppAudioState state;
  final void Function(int streamId, double value) onChanged;
  final void Function(int streamId, double value) onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (state.loading && state.streams.isEmpty) {
      return _SettingsNotice(
        icon: Icons.sync_rounded,
        message: l10n.settingsLoadingAudio,
      );
    }
    if (state.error != null) {
      return _SettingsNotice(
        icon: Icons.error_outline_rounded,
        message: l10n.settingsAudioUnavailable,
      );
    }
    if (state.streams.isEmpty) {
      return _SettingsNotice(
        icon: Icons.music_off_rounded,
        message: l10n.settingsNoApplicationAudio,
      );
    }
    return Column(
      children: [
        for (var index = 0; index < state.streams.length; index++) ...[
          _ApplicationAudioSlider(
            stream: state.streams[index],
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
          if (index != state.streams.length - 1) const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _ApplicationAudioSlider extends StatelessWidget {
  const _ApplicationAudioSlider({
    required this.stream,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final AppAudioStream stream;
  final void Function(int streamId, double value) onChanged;
  final void Function(int streamId, double value) onChangeEnd;

  @override
  Widget build(BuildContext context) {
    return SettingsSlider(
      label: stream.name,
      value: stream.level,
      minimum: 0,
      maximum: 1,
      divisions: 100,
      valueLabel: context.l10n.settingsPercent((stream.level * 100).round()),
      onChanged: (value) => onChanged(stream.id, value),
      onChangeEnd: (value) => onChangeEnd(stream.id, value),
    );
  }
}

class SettingsNetworkPage extends ConsumerWidget {
  const SettingsNetworkPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final state = ref.watch(networkConnectivityProvider);
    final controller = ref.read(networkConnectivityProvider.notifier);
    final snapshot = state.snapshot;
    return SettingsPageLayout(
      icon: Icons.wifi_rounded,
      eyebrow: l10n.settingsNetworkSection,
      title: l10n.settingsNetworkTitle,
      onReset: () => controller.setWirelessEnabled(true),
      children: [
        SettingsCardGroup(
          children: [
            SettingsSection(
              title: l10n.settingsWifiTitle,
              status: _networkStatusLabel(l10n, snapshot.status),
              trailing: SettingsTextButton(
                label: state.scanning
                    ? l10n.settingsScanning
                    : l10n.settingsScan,
                onPressed: controller.scan,
              ),
              child: SettingsToggle(
                label: l10n.settingsWifiEnabled,
                description: l10n.settingsWifiEnabledDescription,
                value: snapshot.wirelessEnabled,
                onChanged: controller.setWirelessEnabled,
              ),
            ),
            SettingsSection(
              title: l10n.settingsAvailableNetworksTitle,
              child: state.error != null
                  ? _SettingsNotice(
                      icon: Icons.error_outline_rounded,
                      message: l10n.settingsNetworkUnavailable,
                    )
                  : snapshot.networks.isEmpty
                  ? _SettingsNotice(
                      icon: Icons.signal_wifi_off_rounded,
                      message: l10n.settingsNoNetworks,
                    )
                  : Column(
                      children: [
                        for (
                          var index = 0;
                          index < snapshot.networks.length;
                          index++
                        ) ...[
                          _NetworkRow(
                            network: snapshot.networks[index],
                            busy: state.busyNetworks.contains(
                              snapshot.networks[index].identity,
                            ),
                            onToggle: () {
                              final network = snapshot.networks[index];
                              if (network.connected) {
                                controller.disconnect(network);
                              } else if (network.saved ||
                                  !network.security.requiresPassword) {
                                controller.connect(network);
                              }
                            },
                          ),
                          if (index != snapshot.networks.length - 1)
                            const Divider(
                              height: 20,
                              color: ShellColors.hairlineSoft,
                            ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ],
    );
  }
}

class _NetworkRow extends StatelessWidget {
  const _NetworkRow({
    required this.network,
    required this.busy,
    required this.onToggle,
  });

  final WifiNetwork network;
  final bool busy;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final canConnect =
        network.connected ||
        network.saved ||
        !network.security.requiresPassword;
    return _StatusRow(
      icon: network.connected ? Icons.wifi_rounded : Icons.wifi_outlined,
      title: network.ssid,
      subtitle: network.connected
          ? l10n.settingsConnected
          : l10n.settingsSignalStrength(network.strength),
      actionLabel: network.connected
          ? l10n.settingsDisconnect
          : network.security.requiresPassword && !network.saved
          ? l10n.settingsPasswordRequired
          : l10n.settingsConnect,
      actionEnabled: canConnect && !busy,
      onAction: onToggle,
    );
  }
}

class SettingsBluetoothPage extends ConsumerWidget {
  const SettingsBluetoothPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final state = ref.watch(bluetoothProvider);
    final controller = ref.read(bluetoothProvider.notifier);
    return SettingsPageLayout(
      icon: Icons.bluetooth_rounded,
      eyebrow: l10n.settingsBluetoothSection,
      title: l10n.settingsBluetoothTitle,
      onReset: () {
        if (state.available && !state.powered) {
          controller.togglePower();
        }
      },
      children: [
        SettingsCardGroup(
          children: [
            SettingsSection(
              title: l10n.settingsBluetoothRadioTitle,
              status: state.adapterName.isEmpty
                  ? l10n.settingsBluetoothAdapterDescription
                  : state.adapterName,
              trailing: SettingsTextButton(
                label: state.scanning
                    ? l10n.settingsScanning
                    : l10n.settingsScan,
                onPressed: controller.scan,
              ),
              child: SettingsToggle(
                label: l10n.settingsBluetoothEnabled,
                description: l10n.settingsBluetoothEnabledDescription,
                value: state.powered,
                onChanged: (_) => controller.togglePower(),
              ),
            ),
            SettingsSection(
              title: l10n.settingsBluetoothDevicesTitle,
              child: state.error != null
                  ? _SettingsNotice(
                      icon: Icons.error_outline_rounded,
                      message: l10n.settingsBluetoothUnavailable,
                    )
                  : state.devices.isEmpty
                  ? _SettingsNotice(
                      icon: Icons.bluetooth_disabled_rounded,
                      message: l10n.settingsNoBluetoothDevices,
                    )
                  : Column(
                      children: [
                        for (
                          var index = 0;
                          index < state.devices.length;
                          index++
                        ) ...[
                          _BluetoothRow(
                            device: state.devices[index],
                            busy: state.busyDevices.contains(
                              state.devices[index].objectPath,
                            ),
                            onToggle: () => controller.toggleConnection(
                              state.devices[index],
                            ),
                          ),
                          if (index != state.devices.length - 1)
                            const Divider(
                              height: 20,
                              color: ShellColors.hairlineSoft,
                            ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ],
    );
  }
}

class _BluetoothRow extends StatelessWidget {
  const _BluetoothRow({
    required this.device,
    required this.busy,
    required this.onToggle,
  });

  final BluetoothDeviceInfo device;
  final bool busy;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return _StatusRow(
      icon: device.connected
          ? Icons.bluetooth_connected_rounded
          : Icons.bluetooth_rounded,
      title: device.name,
      subtitle: device.connected
          ? l10n.settingsConnected
          : device.paired
          ? l10n.settingsPaired
          : l10n.settingsAvailable,
      actionLabel: device.connected
          ? l10n.settingsDisconnect
          : l10n.settingsConnect,
      actionEnabled: !busy,
      onAction: onToggle,
    );
  }
}

String _networkStatusLabel(
  AppLocalizations l10n,
  NetworkConnectivityStatus status,
) {
  return switch (status) {
    NetworkConnectivityStatus.unavailable =>
      l10n.settingsNetworkStatusUnavailable,
    NetworkConnectivityStatus.disabled => l10n.settingsNetworkStatusDisabled,
    NetworkConnectivityStatus.disconnected =>
      l10n.settingsNetworkStatusDisconnected,
    NetworkConnectivityStatus.connecting =>
      l10n.settingsNetworkStatusConnecting,
    NetworkConnectivityStatus.local => l10n.settingsNetworkStatusLocal,
    NetworkConnectivityStatus.limited => l10n.settingsNetworkStatusLimited,
    NetworkConnectivityStatus.captivePortal =>
      l10n.settingsNetworkStatusCaptivePortal,
    NetworkConnectivityStatus.online => l10n.settingsNetworkStatusOnline,
  };
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.actionEnabled = true,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final bool actionEnabled;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    return Row(
      children: [
        Icon(icon, color: accent, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: ShellText.cardTitle),
              const SizedBox(height: 3),
              Text(
                subtitle,
                style: ShellText.base.copyWith(
                  color: ShellColors.textTertiary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
        if (actionLabel case final label?)
          Opacity(
            opacity: actionEnabled ? 1 : 0.45,
            child: IgnorePointer(
              ignoring: !actionEnabled,
              child: SettingsTextButton(
                label: label,
                onPressed: onAction ?? () {},
              ),
            ),
          ),
      ],
    );
  }
}

class _SettingsNotice extends StatelessWidget {
  const _SettingsNotice({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Icon(icon, size: 18, color: ShellColors.textTertiary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: ShellText.base.copyWith(color: ShellColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
