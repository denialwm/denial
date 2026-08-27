part of 'desktop_shell.dart';

class _BluetoothDeviceList extends StatelessWidget {
  const _BluetoothDeviceList({
    required this.state,
    required this.onToggleConnection,
  });

  final BluetoothState state;
  final ValueChanged<BluetoothDeviceInfo> onToggleConnection;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (state.refreshing && state.devices.isEmpty) {
      return Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: ShellTheme.of(context).accent,
          ),
        ),
      );
    }
    if (!state.available) {
      return _DashboardEmptyState(
        icon: Icons.bluetooth_disabled_rounded,
        label: l10n.settingsBluetoothUnavailable,
      );
    }
    if (!state.powered) {
      return _DashboardEmptyState(
        icon: Icons.bluetooth_disabled_rounded,
        label: l10n.desktopEnableBluetoothForDevices,
      );
    }
    if (state.devices.isEmpty) {
      return _DashboardEmptyState(
        icon: state.scanning
            ? Icons.bluetooth_searching_rounded
            : Icons.bluetooth_rounded,
        label: state.scanning
            ? l10n.desktopScanningBluetoothDevices
            : l10n.settingsNoBluetoothDevices,
      );
    }

    return ListView.separated(
      itemCount: state.devices.length,
      separatorBuilder: (_, _) => const SizedBox(height: 7),
      itemBuilder: (context, index) {
        final device = state.devices[index];
        return _BluetoothDeviceRow(
          device: device,
          busy: state.busyDevices.contains(device.objectPath),
          onTap: () => onToggleConnection(device),
        );
      },
    );
  }
}

class _DashboardEmptyState extends StatelessWidget {
  const _DashboardEmptyState({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 34, color: context.shellColors.textTertiary),
          const SizedBox(height: 10),
          Text(
            label,
            textAlign: TextAlign.center,
            style: context.shellTheme.text.cardTitle.copyWith(
              color: context.shellColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _BluetoothDeviceRow extends StatefulWidget {
  const _BluetoothDeviceRow({
    required this.device,
    required this.busy,
    required this.onTap,
  });

  final BluetoothDeviceInfo device;
  final bool busy;
  final VoidCallback onTap;

  @override
  State<_BluetoothDeviceRow> createState() => _BluetoothDeviceRowState();
}

class _BluetoothDeviceRowState extends State<_BluetoothDeviceRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final device = widget.device;
    final accent = ShellTheme.of(context).accentPalette;
    final l10n = context.l10n;
    final status = device.connected
        ? l10n.settingsConnected
        : device.paired
        ? l10n.settingsPaired
        : l10n.settingsAvailable;
    return Semantics(
      button: true,
      label: device.connected
          ? l10n.desktopDisconnectDevice(device.name)
          : l10n.desktopConnectDevice(device.name),
      child: MouseRegion(
        cursor: widget.busy
            ? ShellMouseCursors.working
            : ShellMouseCursors.link,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.busy ? null : widget.onTap,
          child: AnimatedContainer(
            duration: Motion.tile,
            curve: Motion.standard,
            height: 60,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            decoration: BoxDecoration(
              color: device.connected
                  ? accent.container
                  : _hovered
                  ? context.shellColors.surfaceContainerHighest
                  : context.shellColors.surfaceContainer,
              borderRadius: context.shellTheme.borderRadius(16),
            ),
            child: Row(
              children: [
                Icon(
                  _bluetoothIcon(device.icon),
                  size: 22,
                  color: device.connected
                      ? accent.onContainer
                      : context.shellColors.textPrimary,
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.shellTheme.text.cardTitle,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        status,
                        style: context.shellTheme.text.cardTitle.copyWith(
                          color: device.connected
                              ? accent.onContainerSecondary
                              : context.shellColors.textTertiary,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                if (widget.busy)
                  SizedBox(
                    width: 21,
                    height: 21,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: accent.primary,
                    ),
                  )
                else
                  Icon(
                    device.connected ? Icons.link_off_rounded : Icons.link,
                    size: 20,
                    color: device.connected
                        ? accent.onContainer
                        : context.shellColors.textSecondary,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
