import 'package:denial_flutter_sdk/materials.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/system_services.dart';
import 'package:denial_flutter_sdk/state.dart';

import '../../state/quick_settings.dart';

import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/tokens.dart';

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
        ref.read(audioDevicesProvider.notifier).refresh();
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
    final devices = ref.watch(audioDevicesProvider);
    final deviceController = ref.read(audioDevicesProvider.notifier);
    return SettingsPageLayout(
      icon: Icons.volume_up_rounded,
      eyebrow: l10n.settingsAudioSection,
      title: l10n.settingsAudioTitle,
      onReset: () => quickController.commitVolume(0.46),
      commands: [
        SettingsCommand(
          label: l10n.settingsRefresh,
          icon: Icons.refresh_rounded,
          onPressed: () {
            applicationController.refresh();
            deviceController.refresh();
          },
        ),
      ],
      footer: SettingsErrorNotice(
        message: applications.error,
        onRetry: applicationController.refresh,
      ),
      children: [
        SettingsCardGroup(
          children: [
            SettingsSection(
              title: l10n.settingsAudioOutputTitle,
              status: devices.activeDevice == null
                  ? null
                  : l10n.settingsAudioOutputInUse(
                      devices.activeDevice!.description,
                    ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final device in devices.devices)
                    _AudioOutputDeviceRow(
                      device: device,
                      busy: devices.changing,
                      onSelected: () {
                        deviceController.select(device.name);
                        Future<void>.delayed(
                          const Duration(milliseconds: 500),
                          () {
                            if (!mounted) return;
                            ref
                                .read(quickSettingsProvider.notifier)
                                .refreshVolume();
                          },
                        );
                      },
                    ),
                  if (devices.devices.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                        devices.loading
                            ? l10n.settingsAudioOutputLoading
                            : l10n.settingsAudioOutputUnavailable,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: context.applicationColors.secondary,
                        ),
                      ),
                    ),
                  if (devices.devices.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
                      child: Text(
                        l10n.settingsAudioOutputNote,
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.4,
                          color: context.applicationColors.secondary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
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
      commands: [
        SettingsCommand(
          label: state.scanning ? l10n.settingsScanning : l10n.settingsScan,
          icon: Icons.wifi_find_rounded,
          onPressed: state.scanning ? null : controller.scan,
        ),
      ],
      footer: SettingsErrorNotice(
        message: state.error,
        onRetry: controller.refresh,
        onDismiss: controller.clearError,
      ),
      children: [
        SettingsCardGroup(
          children: [
            SettingsSection(
              title: l10n.settingsWifiTitle,
              status: _networkStatusLabel(l10n, snapshot.status),
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
                              } else if (network.connectable &&
                                  (network.saved ||
                                      !network.security.requiresPassword)) {
                                controller.connect(network);
                              }
                            },
                          ),
                          if (index != snapshot.networks.length - 1)
                            Divider(
                              height: 20,
                              color: context.applicationColors.separator,
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
        (network.connectable &&
            (network.saved || !network.security.requiresPassword));
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
      commands: [
        SettingsCommand(
          label: state.scanning ? l10n.settingsScanning : l10n.settingsScan,
          icon: Icons.bluetooth_searching_rounded,
          onPressed: state.scanning ? null : controller.scan,
        ),
      ],
      footer: SettingsErrorNotice(
        message: state.error,
        onRetry: controller.refresh,
        onDismiss: controller.clearError,
      ),
      children: [
        SettingsCardGroup(
          children: [
            SettingsSection(
              title: l10n.settingsBluetoothRadioTitle,
              status: state.adapterName.isEmpty
                  ? l10n.settingsBluetoothAdapterDescription
                  : state.adapterName,
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
                            Divider(
                              height: 20,
                              color: context.applicationColors.separator,
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
                  color: context.applicationColors.secondary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
        if (actionLabel case final label?)
          SettingsTextButton(
            label: label,
            onPressed: actionEnabled ? onAction : null,
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
          Icon(icon, size: 18, color: context.applicationColors.secondary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: ShellText.base.copyWith(
                color: context.applicationColors.secondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AudioOutputDeviceRow extends StatelessWidget {
  const _AudioOutputDeviceRow({
    required this.device,
    required this.busy,
    required this.onSelected,
  });

  final AudioOutputDevice device;
  final bool busy;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final accent = ShellTheme.of(context).accent;
    final enabled = device.available && !device.active && !busy;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Semantics(
        button: true,
        selected: device.active,
        label: device.description,
        child: TextButton(
          onPressed: enabled ? onSelected : null,
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 58),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            foregroundColor: context.applicationColors.foreground,
            backgroundColor: device.active
                ? accent.withValues(alpha: .10)
                : null,
            alignment: AlignmentDirectional.centerStart,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: SizedBox(
            height: 58,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: device.active
                        ? context.applicationColors.chrome
                        : context.applicationColors.control,
                    border: Border.all(
                      color: device.active
                          ? accent.withValues(alpha: .55)
                          : Colors.transparent,
                    ),
                  ),
                  child: Icon(
                    device.active
                        ? Icons.volume_up_rounded
                        : Icons.speaker_rounded,
                    size: 19,
                    color: device.active
                        ? accent
                        : context.applicationColors.secondary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        device.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: context.applicationColors.foreground,
                          fontSize: 14,
                          fontWeight: device.active
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        device.available
                            ? device.name
                            : '${device.name} · '
                                  '${l10n.settingsAudioOutputUnavailable}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: context.applicationColors.secondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: device.active
                        ? context.applicationColors.chrome
                        : Colors.transparent,
                    border: Border.all(
                      color: device.active
                          ? accent
                          : context.applicationColors.separator,
                      width: device.active ? 6 : 1.6,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
