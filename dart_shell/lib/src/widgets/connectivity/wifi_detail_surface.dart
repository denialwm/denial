import 'dart:async';

import 'package:flutter/material.dart' show CircularProgressIndicator, Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../localization/denial_localizations.dart';
import '../../services/network_manager_service.dart';
import '../../state/network_connectivity.dart';
import '../../theme/motion.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import '../shell_backdrop_blur.dart';

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
            blur: theme.panelOpacity < 1.0,
            borderRadius: BorderRadius.circular(theme.panelRadius),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.panelColor(ShellColors.panelBackground),
                borderRadius: BorderRadius.circular(theme.panelRadius),
                border: Border.all(color: ShellColors.hairline),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: ShellColors.shadow,
                    blurRadius: 36,
                    spreadRadius: 3,
                    offset: Offset(0, 16),
                  ),
                ],
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
                                    color: ShellColors.textTertiary,
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
                  ? ShellColors.primaryContainer
                  : _hovered || _focused
                  ? ShellColors.surfaceContainerHighest
                  : ShellColors.surfaceContainer,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _focused ? accent : ShellColors.hairlineSoft,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _strengthIcon(network.strength),
                  size: 23,
                  color: network.connected
                      ? ShellColors.onPrimaryContainer
                      : enabled
                      ? ShellColors.textPrimary
                      : ShellColors.glyphInactive,
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
                              ? ShellColors.onPrimaryContainer
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
                              ? ShellColors.onPrimaryContainerSecondary
                              : ShellColors.textTertiary,
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
                        ? ShellColors.onPrimaryContainerSecondary
                        : ShellColors.textTertiary,
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
                        ? ShellColors.onPrimaryContainer
                        : ShellColors.textSecondary,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WifiCredentialPanel extends StatelessWidget {
  const _WifiCredentialPanel({
    required this.network,
    required this.controller,
    required this.focusNode,
    required this.error,
    required this.onCancel,
    required this.onSubmit,
  });

  final WifiNetwork network;
  final TextEditingController controller;
  final FocusNode focusNode;
  final String? error;
  final VoidCallback onCancel;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final l10n = context.l10n;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ShellColors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: error == null
              ? ShellColors.hairlineSoft
              : ShellColors.performanceBad,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.wifiPasswordFor(network.ssid),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ShellText.cardTitle,
            ),
            const SizedBox(height: 9),
            Semantics(
              textField: true,
              obscured: true,
              label: l10n.wifiPasswordField(network.ssid),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.panelColor(ShellColors.panelBackground),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: focusNode.hasFocus
                        ? theme.accent
                        : ShellColors.hairline,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: EditableText(
                    controller: controller,
                    focusNode: focusNode,
                    autofocus: true,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    keyboardType: TextInputType.visiblePassword,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => onSubmit(),
                    style: ShellText.base,
                    cursorColor: theme.accent,
                    backgroundCursorColor: ShellColors.textSecondary,
                    selectionColor: ShellColors.primaryContainer,
                  ),
                ),
              ),
            ),
            if (error case final message?) ...[
              const SizedBox(height: 7),
              Text(
                message,
                style: ShellText.base.copyWith(
                  color: ShellColors.performanceBad,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 9),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _WifiTextButton(label: l10n.commonCancel, onPressed: onCancel),
                const SizedBox(width: 8),
                _WifiTextButton(
                  label: l10n.settingsConnect,
                  emphasized: true,
                  onPressed: onSubmit,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _WifiEmptyState extends StatelessWidget {
  const _WifiEmptyState({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: context.l10n.commonTitleAndBody(title, body),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 330),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 36, color: ShellColors.textTertiary),
              const SizedBox(height: 10),
              Text(
                title,
                textAlign: TextAlign.center,
                style: ShellText.cardTitle,
              ),
              const SizedBox(height: 5),
              Text(
                body,
                textAlign: TextAlign.center,
                style: ShellText.base.copyWith(
                  color: ShellColors.textTertiary,
                  fontSize: 11.5,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WifiNotice extends StatelessWidget {
  const _WifiNotice({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ShellColors.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 16, color: ShellColors.onSecondaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: ShellText.base.copyWith(
                  color: ShellColors.onSecondaryContainer,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WifiErrorNotice extends StatelessWidget {
  const _WifiErrorNotice({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ShellColors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ShellColors.performanceBad),
      ),
      child: Padding(
        padding: const EdgeInsets.only(left: 10, top: 7, bottom: 7),
        child: Row(
          children: [
            const Icon(
              Icons.error_outline_rounded,
              size: 17,
              color: ShellColors.performanceBad,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: ShellText.base.copyWith(
                  color: ShellColors.performanceBad,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            _WifiInlineButton(
              label: context.l10n.wifiDismissError,
              icon: Icons.close_rounded,
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}

String _wifiSecurityLabel(AppLocalizations l10n, WifiSecurity security) {
  return switch (security) {
    WifiSecurity.open => l10n.wifiSecurityOpen,
    WifiSecurity.wep => l10n.wifiSecurityWep,
    WifiSecurity.wpaPersonal => l10n.wifiSecurityWpaPersonal,
    WifiSecurity.wpa3Personal => l10n.wifiSecurityWpa3Personal,
    WifiSecurity.owe => l10n.wifiSecurityEnhancedOpen,
    WifiSecurity.enterprise => l10n.wifiSecurityEnterprise,
    WifiSecurity.unknown => l10n.wifiSecurityUnsupported,
  };
}

class _WifiIconButton extends StatefulWidget {
  const _WifiIconButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.active = false,
    this.busy = false,
    this.enabled = true,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool active;
  final bool busy;
  final bool enabled;

  @override
  State<_WifiIconButton> createState() => _WifiIconButtonState();
}

class _WifiIconButtonState extends State<_WifiIconButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    return Semantics(
      button: true,
      enabled: widget.enabled,
      toggled: widget.active,
      label: widget.label,
      child: FocusableActionDetector(
        enabled: widget.enabled,
        mouseCursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              if (widget.enabled) {
                widget.onPressed();
              }
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.enabled ? widget.onPressed : null,
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : Motion.pill,
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: widget.active
                  ? ShellColors.primaryContainer
                  : ShellColors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _focused ? accent : ShellColors.hairlineSoft,
              ),
            ),
            child: widget.busy
                ? Padding(
                    padding: const EdgeInsets.all(9),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: accent,
                    ),
                  )
                : Icon(
                    widget.icon,
                    size: 18,
                    color: widget.enabled
                        ? widget.active
                              ? ShellColors.onPrimaryContainer
                              : ShellColors.textSecondary
                        : ShellColors.glyphInactive,
                  ),
          ),
        ),
      ),
    );
  }
}

class _WifiInlineButton extends StatefulWidget {
  const _WifiInlineButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.enabled = true,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool enabled;

  @override
  State<_WifiInlineButton> createState() => _WifiInlineButtonState();
}

class _WifiInlineButtonState extends State<_WifiInlineButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.label,
      child: FocusableActionDetector(
        enabled: widget.enabled,
        mouseCursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              if (widget.enabled) {
                widget.onPressed();
              }
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.enabled ? widget.onPressed : null,
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : Motion.pill,
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              border: _focused ? Border.all(color: accent) : null,
            ),
            child: Icon(
              widget.icon,
              size: 17,
              color: widget.enabled
                  ? ShellColors.textSecondary
                  : ShellColors.glyphInactive,
            ),
          ),
        ),
      ),
    );
  }
}

class _WifiTextButton extends StatefulWidget {
  const _WifiTextButton({
    required this.label,
    required this.onPressed,
    this.emphasized = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool emphasized;

  @override
  State<_WifiTextButton> createState() => _WifiTextButtonState();
}

class _WifiTextButtonState extends State<_WifiTextButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    return Semantics(
      button: true,
      label: widget.label,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : Motion.pill,
            decoration: BoxDecoration(
              color: widget.emphasized
                  ? ShellColors.primaryContainer
                  : ShellColors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(
                color: _focused ? accent : ShellColors.hairlineSoft,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
              child: Text(
                widget.label,
                style: ShellText.cardTitle.copyWith(
                  color: widget.emphasized
                      ? ShellColors.onPrimaryContainer
                      : ShellColors.textSecondary,
                  fontSize: 11.5,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

IconData _strengthIcon(int strength) {
  if (strength >= 70) {
    return Icons.wifi_rounded;
  }
  if (strength >= 40) {
    return Icons.network_wifi_2_bar_rounded;
  }
  if (strength > 0) {
    return Icons.network_wifi_1_bar_rounded;
  }
  return Icons.wifi_find_rounded;
}

bool _validPersonalPassword(String value) {
  return (value.length >= 8 && value.length <= 63) ||
      RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value);
}
