part of 'bluetooth_detail_surface.dart';

class _BluetoothDeviceList extends StatelessWidget {
  const _BluetoothDeviceList({
    required this.state,
    required this.onPair,
    required this.onToggleTrust,
    required this.onToggleConnection,
    required this.onRemove,
  });

  final BluetoothState state;
  final ValueChanged<BluetoothDeviceInfo> onPair;
  final ValueChanged<BluetoothDeviceInfo> onToggleTrust;
  final ValueChanged<BluetoothDeviceInfo> onToggleConnection;
  final ValueChanged<BluetoothDeviceInfo> onRemove;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    final l10n = context.l10n;
    if (state.initializing) {
      return Center(
        child: SizedBox.square(
          dimension: 25,
          child: CircularProgressIndicator(strokeWidth: 2, color: accent),
        ),
      );
    }
    if (!state.serviceAvailable) {
      return _BluetoothEmptyState(
        icon: Icons.bluetooth_disabled_rounded,
        title: l10n.bluetoothServiceUnavailable,
        body: l10n.bluetoothServiceUnavailableDescription,
      );
    }
    if (!state.available) {
      return _BluetoothEmptyState(
        icon: Icons.bluetooth_disabled_rounded,
        title: l10n.bluetoothNoAdapter,
        body: l10n.bluetoothNoAdapterDescription,
      );
    }
    if (!state.powered) {
      return _BluetoothEmptyState(
        icon: Icons.bluetooth_disabled_rounded,
        title: l10n.bluetoothOff,
        body: l10n.bluetoothOffDescription,
      );
    }
    if (state.devices.isEmpty) {
      return _BluetoothEmptyState(
        icon: state.discovering
            ? Icons.bluetooth_searching_rounded
            : Icons.bluetooth_rounded,
        title: state.discovering
            ? l10n.commonScanning
            : l10n.bluetoothNoDevices,
        body: state.discovering
            ? l10n.bluetoothScanningDescription
            : l10n.bluetoothNoDevicesDescription,
      );
    }
    return ListView.separated(
      key: const PageStorageKey<String>('bluetooth-device-list'),
      itemCount: state.devices.length,
      separatorBuilder: (_, _) => const SizedBox(height: 7),
      itemBuilder: (context, index) {
        final device = state.devices[index];
        return _BluetoothDeviceRow(
          device: device,
          busy: state.busyDevices.contains(device.objectPath),
          onPair: () => onPair(device),
          onToggleTrust: () => onToggleTrust(device),
          onToggleConnection: () => onToggleConnection(device),
          onRemove: () => onRemove(device),
        );
      },
    );
  }
}

class _BluetoothDeviceRow extends StatefulWidget {
  const _BluetoothDeviceRow({
    required this.device,
    required this.busy,
    required this.onPair,
    required this.onToggleTrust,
    required this.onToggleConnection,
    required this.onRemove,
  });

  final BluetoothDeviceInfo device;
  final bool busy;
  final VoidCallback onPair;
  final VoidCallback onToggleTrust;
  final VoidCallback onToggleConnection;
  final VoidCallback onRemove;

  @override
  State<_BluetoothDeviceRow> createState() => _BluetoothDeviceRowState();
}

class _BluetoothDeviceRowState extends State<_BluetoothDeviceRow> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final device = widget.device;
    final enabled = !device.blocked && !widget.busy;
    final accent = ShellTheme.of(context).accent;
    final l10n = context.l10n;
    final status = device.blocked
        ? l10n.bluetoothBlocked
        : device.connected
        ? device.servicesResolved
              ? l10n.settingsConnected
              : l10n.bluetoothConnectedConfiguring
        : device.paired
        ? device.trusted
              ? l10n.bluetoothPairedTrusted
              : l10n.settingsPaired
        : device.signalStrength == null
        ? l10n.settingsAvailable
        : l10n.bluetoothAvailableSignal(device.signalStrength!);
    return Semantics(
      button: true,
      explicitChildNodes: true,
      enabled: enabled,
      label: device.connected
          ? l10n.desktopDisconnectDevice(device.name)
          : l10n.bluetoothConnectDeviceStatus(device.name, status),
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              if (enabled) {
                widget.onToggleConnection();
              }
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? widget.onToggleConnection : null,
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : Motion.tile,
            constraints: const BoxConstraints(minHeight: 68),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: device.connected
                  ? context.shellTheme.accentPalette.container
                  : _hovered || _focused
                  ? context.shellColors.surfaceContainerHighest
                  : context.shellColors.surfaceContainer,
              borderRadius: context.shellTheme.borderRadius(16),
              border: Border.all(
                color: _focused ? accent : context.shellColors.hairlineSoft,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _deviceIcon(device.icon),
                  size: 23,
                  color: device.connected
                      ? context.shellTheme.accentPalette.onContainer
                      : device.blocked
                      ? context.shellColors.glyphInactive
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
                        style: ShellText.cardTitle.copyWith(
                          color: device.connected
                              ? context.shellTheme.accentPalette.onContainer
                              : null,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ShellText.base.copyWith(
                          color: device.connected
                              ? context
                                    .shellTheme
                                    .accentPalette
                                    .onContainerSecondary
                              : context.shellColors.textTertiary,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!device.paired)
                  _BluetoothInlineButton(
                    label: l10n.bluetoothPairDevice(device.name),
                    icon: Icons.link_rounded,
                    enabled: enabled,
                    onPressed: widget.onPair,
                  ),
                if (device.paired) ...[
                  _BluetoothInlineButton(
                    label: device.trusted
                        ? l10n.bluetoothStopTrustingDevice(device.name)
                        : l10n.bluetoothTrustDevice(device.name),
                    icon: device.trusted
                        ? Icons.verified_rounded
                        : Icons.verified_outlined,
                    enabled: enabled,
                    onPressed: widget.onToggleTrust,
                  ),
                  _BluetoothInlineButton(
                    label: l10n.bluetoothRemoveDevice(device.name),
                    icon: Icons.delete_outline_rounded,
                    enabled: enabled,
                    onPressed: widget.onRemove,
                  ),
                ],
                const SizedBox(width: 5),
                if (widget.busy)
                  SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: accent,
                    ),
                  )
                else
                  Icon(
                    device.connected
                        ? Icons.link_off_rounded
                        : Icons.chevron_right_rounded,
                    size: 20,
                    color: device.connected
                        ? context.shellTheme.accentPalette.onContainer
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
