import 'dart:async';

import 'package:flutter/material.dart' show CircularProgressIndicator, Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../localization/denial_localizations.dart';
import '../../services/network_backend.dart';
import '../../state/network_connectivity.dart';
import '../../theme/motion.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import '../shell_backdrop_blur.dart';

part 'wifi_detail_controls.dart';
part 'wifi_network_list.dart';

class WifiDetailSurface extends ConsumerStatefulWidget {
  const WifiDetailSurface({required this.onClose, super.key});

  final VoidCallback onClose;

  @override
  ConsumerState<WifiDetailSurface> createState() => _WifiDetailSurfaceState();
}

class _WifiDetailSurfaceState extends ConsumerState<WifiDetailSurface> {
  final TextEditingController _passwordController = TextEditingController();
  final FocusNode _passwordFocus = FocusNode(debugLabel: 'wifi-password');
  WifiNetwork? _credentialNetwork;
  String? _credentialError;

  @override
  void initState() {
    super.initState();
    _passwordController.addListener(_passwordChanged);
  }

  void _passwordChanged() {
    if (mounted) {
      setState(() => _credentialError = null);
    }
  }

  void _activate(WifiNetwork network) {
    final controller = ref.read(networkConnectivityProvider.notifier);
    if (network.connected) {
      unawaited(controller.disconnect(network));
      return;
    }
    if (!network.connectable) {
      return;
    }
    if (!network.saved && network.security.requiresPassword) {
      _passwordController.clear();
      setState(() {
        _credentialNetwork = network;
        _credentialError = null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _passwordFocus.requestFocus();
        }
      });
      return;
    }
    unawaited(controller.connect(network));
  }

  void _submitCredential() {
    final network = _credentialNetwork;
    if (network == null) {
      return;
    }
    final secret = _passwordController.text;
    if ((network.security == WifiSecurity.wpaPersonal ||
            network.security == WifiSecurity.wpa3Personal) &&
        !_validPersonalPassword(secret)) {
      setState(() {
        _credentialError = context.l10n.wifiPasswordRequirements;
      });
      return;
    }
    if (network.security == WifiSecurity.wep &&
        (secret.length < 5 || secret.length > 64)) {
      setState(() {
        _credentialError = context.l10n.wifiWepRequirements;
      });
      return;
    }

    _passwordController.clear();
    setState(() {
      _credentialNetwork = null;
      _credentialError = null;
    });
    unawaited(
      ref
          .read(networkConnectivityProvider.notifier)
          .connect(network, password: secret),
    );
  }

  void _cancelCredential() {
    _passwordController.clear();
    setState(() {
      _credentialNetwork = null;
      _credentialError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(networkConnectivityProvider);
    final snapshot = state.snapshot;
    final controller = ref.read(networkConnectivityProvider.notifier);
    final radioEnabled =
        !state.initializing &&
        snapshot.serviceAvailable &&
        snapshot.wifiDeviceAvailable &&
        snapshot.wirelessHardwareEnabled &&
        snapshot.radioPermission != NetworkPermission.denied;
    final scanEnabled =
        snapshot.wirelessEnabled &&
        snapshot.serviceAvailable &&
        snapshot.wifiDeviceAvailable &&
        snapshot.wirelessHardwareEnabled &&
        snapshot.controlPermission != NetworkPermission.denied &&
        !state.scanning;
    final theme = ShellTheme.of(context);
    final l10n = context.l10n;

    return SafeArea(
      minimum: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540, maxHeight: 720),
          child: ShellBackdropBlur(
            blur: theme.effectivePanelOpacity < 1.0,
            borderRadius: BorderRadius.circular(theme.panelRadius),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.panelColor(context.shellColors.panelBackground),
                borderRadius: BorderRadius.circular(theme.panelRadius),
                border: Border.all(color: context.shellColors.hairline),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                child: FocusTraversalGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.wifi_rounded,
                            size: 23,
                            color: theme.accent,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l10n.commonWifi,
                                  style: ShellText.statusClock.copyWith(
                                    fontSize: 20,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  wifiStatusLabel(state, l10n),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: ShellText.base.copyWith(
                                    color: context.shellColors.textTertiary,
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          _WifiIconButton(
                            label: snapshot.wirelessEnabled
                                ? l10n.wifiTurnOff
                                : l10n.wifiTurnOn,
                            icon: Icons.power_settings_new_rounded,
                            active: snapshot.wirelessEnabled,
                            busy: state.radioChanging,
                            enabled: radioEnabled && !state.radioChanging,
                            onPressed: controller.toggleWireless,
                          ),
                          const SizedBox(width: 7),
                          _WifiIconButton(
                            label: state.scanning
                                ? l10n.wifiScanningNetworks
                                : l10n.wifiScanNetworks,
                            icon: Icons.refresh_rounded,
                            active: state.scanning,
                            busy: state.scanning,
                            enabled: scanEnabled,
                            onPressed: controller.scan,
                          ),
                          const SizedBox(width: 7),
                          _WifiIconButton(
                            label: l10n.wifiCloseDetails,
                            icon: Icons.close_rounded,
                            onPressed: widget.onClose,
                          ),
                        ],
                      ),
                      if (snapshot.radioPermission ==
                              NetworkPermission.authenticationRequired ||
                          snapshot.controlPermission ==
                              NetworkPermission.authenticationRequired) ...[
                        const SizedBox(height: 10),
                        _WifiNotice(
                          icon: Icons.admin_panel_settings_rounded,
                          message: l10n.wifiAuthorizationMayBeRequired,
                        ),
                      ],
                      if (snapshot.controlPermission ==
                              NetworkPermission.denied ||
                          snapshot.modifyPermission ==
                              NetworkPermission.denied) ...[
                        const SizedBox(height: 10),
                        _WifiNotice(
                          icon: Icons.block_rounded,
                          message: l10n.wifiPermissionLimited,
                        ),
                      ],
                      if (state.error != null) ...[
                        const SizedBox(height: 10),
                        _WifiErrorNotice(
                          message: l10n.wifiOperationFailed,
                          onDismiss: controller.clearError,
                        ),
                      ],
                      if (_credentialNetwork case final network?) ...[
                        const SizedBox(height: 12),
                        _WifiCredentialPanel(
                          network: network,
                          controller: _passwordController,
                          focusNode: _passwordFocus,
                          error: _credentialError,
                          onCancel: _cancelCredential,
                          onSubmit: _submitCredential,
                        ),
                      ],
                      const SizedBox(height: 12),
                      Expanded(
                        child: _WifiNetworkList(
                          state: state,
                          onActivate: _activate,
                          onForget: (network) =>
                              unawaited(controller.forget(network)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _passwordController
      ..removeListener(_passwordChanged)
      ..clear()
      ..dispose();
    _passwordFocus.dispose();
    super.dispose();
  }
}

String wifiStatusLabel(NetworkConnectivityState state, AppLocalizations l10n) {
  final snapshot = state.snapshot;
  if (state.initializing) {
    return l10n.wifiLoadingService;
  }
  if (!snapshot.serviceAvailable) {
    return l10n.wifiServiceUnavailableShort;
  }
  if (!snapshot.wifiDeviceAvailable) {
    return l10n.wifiNoAdapter;
  }
  if (!snapshot.wirelessHardwareEnabled) {
    return l10n.wifiHardwareDisabled;
  }
  if (!snapshot.wirelessEnabled) {
    return l10n.commonOff;
  }
  final connected = snapshot.connectedNetwork?.ssid;
  return switch (snapshot.status) {
    NetworkConnectivityStatus.connecting => l10n.commonConnecting,
    NetworkConnectivityStatus.online => connected ?? l10n.commonOnline,
    NetworkConnectivityStatus.captivePortal =>
      connected == null
          ? l10n.wifiSignInRequired
          : l10n.wifiNamedStatus(connected, l10n.wifiSignInRequired),
    NetworkConnectivityStatus.limited =>
      connected == null
          ? l10n.wifiLimitedConnection
          : l10n.wifiNamedStatus(connected, l10n.commonLimited),
    NetworkConnectivityStatus.local =>
      connected == null
          ? l10n.wifiLocalConnection
          : l10n.wifiNamedStatus(connected, l10n.wifiLocalOnly),
    NetworkConnectivityStatus.disconnected => l10n.commonNotConnected,
    NetworkConnectivityStatus.disabled => l10n.commonOff,
    NetworkConnectivityStatus.unavailable => l10n.commonUnavailable,
  };
}
