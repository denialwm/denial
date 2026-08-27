part of 'wifi_detail_surface.dart';

class _WifiNetworkList extends StatelessWidget {
  const _WifiNetworkList({
    required this.state,
    required this.onActivate,
    required this.onForget,
  });

  final NetworkConnectivityState state;
  final ValueChanged<WifiNetwork> onActivate;
  final ValueChanged<WifiNetwork> onForget;

  @override
  Widget build(BuildContext context) {
    final snapshot = state.snapshot;
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
    if (!snapshot.serviceAvailable) {
      return _WifiEmptyState(
        icon: Icons.portable_wifi_off_rounded,
        title: l10n.wifiServiceUnavailable,
        body: l10n.wifiServiceUnavailableDescription,
      );
    }
    if (!snapshot.wifiDeviceAvailable) {
      return _WifiEmptyState(
        icon: Icons.wifi_off_rounded,
        title: l10n.wifiNoAdapter,
        body: l10n.wifiNoAdapterDescription,
      );
    }
    if (!snapshot.wirelessHardwareEnabled) {
      return _WifiEmptyState(
        icon: Icons.phonelink_erase_rounded,
        title: l10n.wifiHardwareBlocked,
        body: l10n.wifiHardwareBlockedDescription,
      );
    }
    if (!snapshot.wirelessEnabled) {
      return _WifiEmptyState(
        icon: Icons.wifi_off_rounded,
        title: l10n.wifiOff,
        body: l10n.wifiOffDescription,
      );
    }
    if (snapshot.networks.isEmpty) {
      return _WifiEmptyState(
        icon: state.scanning ? Icons.radar_rounded : Icons.wifi_find_rounded,
        title: state.scanning ? l10n.commonScanning : l10n.wifiNoNetworks,
        body: state.scanning
            ? l10n.wifiScanningDescription
            : l10n.wifiNoNetworksDescription,
      );
    }

    return ListView.separated(
      key: const PageStorageKey<String>('wifi-network-list'),
      itemCount: snapshot.networks.length,
      separatorBuilder: (_, _) => const SizedBox(height: 7),
      itemBuilder: (context, index) {
        final network = snapshot.networks[index];
        return _WifiNetworkRow(
          network: network,
          busy: state.busyNetworks.contains(network.identity),
          activationEnabled:
              state.snapshot.controlPermission != NetworkPermission.denied &&
              (network.connected ||
                  network.saved ||
                  state.snapshot.modifyPermission != NetworkPermission.denied),
          onActivate: () => onActivate(network),
          onForget:
              network.saved &&
                  state.snapshot.modifyPermission != NetworkPermission.denied
              ? () => onForget(network)
              : null,
        );
      },
    );
  }
}

class _WifiNetworkRow extends StatefulWidget {
  const _WifiNetworkRow({
    required this.network,
    required this.busy,
    required this.activationEnabled,
    required this.onActivate,
    required this.onForget,
  });

  final WifiNetwork network;
  final bool busy;
  final bool activationEnabled;
  final VoidCallback onActivate;
  final VoidCallback? onForget;

  @override
  State<_WifiNetworkRow> createState() => _WifiNetworkRowState();
}

class _WifiNetworkRowState extends State<_WifiNetworkRow> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final network = widget.network;
    final accent = ShellTheme.of(context).accent;
    final l10n = context.l10n;
    final enabled =
        widget.activationEnabled && (network.connectable || network.connected);
    final status = network.connected
        ? l10n.settingsConnected
        : network.saved && !network.available
        ? l10n.wifiSavedOutOfRange
        : network.saved
        ? l10n.wifiSavedWithSecurity(_wifiSecurityLabel(l10n, network.security))
        : _wifiSecurityLabel(l10n, network.security);
    return Semantics(
      button: true,
      explicitChildNodes: widget.onForget != null,
      enabled: enabled && !widget.busy,
      label: network.connected
          ? l10n.wifiDisconnectNetwork(network.ssid)
          : l10n.wifiConnectNetwork(network.ssid, status, network.strength),
      child: FocusableActionDetector(
        enabled: enabled && !widget.busy,
        mouseCursor: enabled && !widget.busy
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onShowHoverHighlight: (hovered) => setState(() => _hovered = hovered),
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              if (enabled && !widget.busy) {
                widget.onActivate();
              }
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled && !widget.busy ? widget.onActivate : null,
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : Motion.tile,
            constraints: const BoxConstraints(minHeight: 62),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: network.connected
                  ? context.shellTheme.accentPalette.container
                  : _hovered || _focused
                  ? context.shellColors.surfaceContainerHighest
                  : context.shellColors.surfaceContainer,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _focused ? accent : context.shellColors.hairlineSoft,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _strengthIcon(network.strength),
                  size: 23,
                  color: network.connected
                      ? context.shellTheme.accentPalette.onContainer
                      : enabled
                      ? context.shellColors.textPrimary
                      : context.shellColors.glyphInactive,
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        network.ssid,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ShellText.cardTitle.copyWith(
                          color: network.connected
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
                          color: network.connected
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
                if (network.security != WifiSecurity.open)
                  Icon(
                    network.security == WifiSecurity.enterprise
                        ? Icons.business_rounded
                        : Icons.lock_rounded,
                    size: 16,
                    color: network.connected
                        ? context.shellTheme.accentPalette.onContainerSecondary
                        : context.shellColors.textTertiary,
                  ),
                if (widget.onForget != null) ...[
                  const SizedBox(width: 7),
                  _WifiInlineButton(
                    label: l10n.wifiForgetNetwork(network.ssid),
                    icon: Icons.delete_outline_rounded,
                    enabled: !widget.busy,
                    onPressed: widget.onForget!,
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
                    network.connected
                        ? Icons.link_off_rounded
                        : Icons.chevron_right_rounded,
                    size: 20,
                    color: network.connected
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
