import 'dart:async';

import 'package:flutter/material.dart' show CircularProgressIndicator, Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/network_manager_service.dart';
import '../../state/network_connectivity.dart';
import '../../theme/motion.dart';
import '../../theme/tokens.dart';

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
        _credentialError = 'Use 8–63 characters, or a 64-digit hex key.';
      });
      return;
    }
    if (network.security == WifiSecurity.wep &&
        (secret.length < 5 || secret.length > 64)) {
      setState(() {
        _credentialError = 'WEP keys must contain 5–64 characters.';
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

    return SafeArea(
      minimum: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540, maxHeight: 720),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: ShellColors.panelBackground,
              borderRadius: BorderRadius.circular(ShellRadii.panel),
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
                        const Icon(
                          Icons.wifi_rounded,
                          size: 23,
                          color: ShellColors.accent,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Wi-Fi',
                                style: ShellText.statusClock.copyWith(
                                  fontSize: 20,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                wifiStatusLabel(state),
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
                              ? 'Turn Wi-Fi off'
                              : 'Turn Wi-Fi on',
                          icon: Icons.power_settings_new_rounded,
                          active: snapshot.wirelessEnabled,
                          busy: state.radioChanging,
                          enabled: radioEnabled && !state.radioChanging,
                          onPressed: controller.toggleWireless,
                        ),
                        const SizedBox(width: 7),
                        _WifiIconButton(
                          label: state.scanning
                              ? 'Scanning for Wi-Fi networks'
                              : 'Scan for Wi-Fi networks',
                          icon: Icons.refresh_rounded,
                          active: state.scanning,
                          busy: state.scanning,
                          enabled: scanEnabled,
                          onPressed: controller.scan,
                        ),
                        const SizedBox(width: 7),
                        _WifiIconButton(
                          label: 'Close Wi-Fi details',
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
                      const _WifiNotice(
                        icon: Icons.admin_panel_settings_rounded,
                        message:
                            'A system authorization prompt may be required.',
                      ),
                    ],
                    if (snapshot.controlPermission ==
                            NetworkPermission.denied ||
                        snapshot.modifyPermission ==
                            NetworkPermission.denied) ...[
                      const SizedBox(height: 10),
                      const _WifiNotice(
                        icon: Icons.block_rounded,
                        message:
                            'Your session is not permitted to change every Wi-Fi setting.',
                      ),
                    ],
                    if (state.error case final error?) ...[
                      const SizedBox(height: 10),
                      _WifiErrorNotice(
                        message: error,
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

String wifiStatusLabel(NetworkConnectivityState state) {
  final snapshot = state.snapshot;
  if (state.initializing) {
    return 'Loading NetworkManager…';
  }
  if (!snapshot.serviceAvailable) {
    return 'NetworkManager unavailable';
  }
  if (!snapshot.wifiDeviceAvailable) {
    return 'No Wi-Fi adapter';
  }
  if (!snapshot.wirelessHardwareEnabled) {
    return 'Disabled by hardware switch';
  }
  if (!snapshot.wirelessEnabled) {
    return 'Off';
  }
  final connected = snapshot.connectedNetwork?.ssid;
  return switch (snapshot.status) {
    NetworkConnectivityStatus.connecting => 'Connecting…',
    NetworkConnectivityStatus.online => connected ?? 'Online',
    NetworkConnectivityStatus.captivePortal =>
      connected == null ? 'Sign-in required' : '$connected · sign-in required',
    NetworkConnectivityStatus.limited =>
      connected == null ? 'Limited connection' : '$connected · limited',
    NetworkConnectivityStatus.local =>
      connected == null ? 'Local connection' : '$connected · local only',
    NetworkConnectivityStatus.disconnected => 'Not connected',
    NetworkConnectivityStatus.disabled => 'Off',
    NetworkConnectivityStatus.unavailable => 'Unavailable',
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
    if (state.initializing) {
      return const Center(
        child: SizedBox.square(
          dimension: 25,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: ShellColors.accent,
          ),
        ),
      );
    }
    if (!snapshot.serviceAvailable) {
      return const _WifiEmptyState(
        icon: Icons.portable_wifi_off_rounded,
        title: 'NetworkManager is unavailable',
        body: 'Wi-Fi controls are disabled until the service returns.',
      );
    }
    if (!snapshot.wifiDeviceAvailable) {
      return const _WifiEmptyState(
        icon: Icons.wifi_off_rounded,
        title: 'No Wi-Fi adapter',
        body: 'Denial will enable these controls when an adapter appears.',
      );
    }
    if (!snapshot.wirelessHardwareEnabled) {
      return const _WifiEmptyState(
        icon: Icons.phonelink_erase_rounded,
        title: 'Wi-Fi is hardware-blocked',
        body: 'Use the device wireless switch or clear the RF kill block.',
      );
    }
    if (!snapshot.wirelessEnabled) {
      return const _WifiEmptyState(
        icon: Icons.wifi_off_rounded,
        title: 'Wi-Fi is off',
        body: 'Turn it on to discover nearby networks.',
      );
    }
    if (snapshot.networks.isEmpty) {
      return _WifiEmptyState(
        icon: state.scanning ? Icons.radar_rounded : Icons.wifi_find_rounded,
        title: state.scanning ? 'Scanning…' : 'No networks found',
        body: state.scanning
            ? 'Nearby access points will appear automatically.'
            : 'Run a scan to refresh NetworkManager results.',
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
    final enabled =
        widget.activationEnabled && (network.connectable || network.connected);
    final status = network.connected
        ? 'Connected'
        : network.saved && !network.available
        ? 'Saved · out of range'
        : network.saved
        ? 'Saved · ${network.security.label}'
        : network.security.label;
    return Semantics(
      button: true,
      explicitChildNodes: widget.onForget != null,
      enabled: enabled && !widget.busy,
      label: network.connected
          ? 'Disconnect ${network.ssid}'
          : 'Connect ${network.ssid}, $status, signal ${network.strength} percent',
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
                color: _focused ? ShellColors.accent : ShellColors.hairlineSoft,
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
                    label: 'Forget ${network.ssid}',
                    icon: Icons.delete_outline_rounded,
                    enabled: !widget.busy,
                    onPressed: widget.onForget!,
                  ),
                ],
                const SizedBox(width: 5),
                if (widget.busy)
                  const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: ShellColors.accent,
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
              'Password for ${network.ssid}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ShellText.cardTitle,
            ),
            const SizedBox(height: 9),
            Semantics(
              textField: true,
              obscured: true,
              label: 'Wi-Fi password for ${network.ssid}',
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: ShellColors.panelBackground,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: focusNode.hasFocus
                        ? ShellColors.accent
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
                    cursorColor: ShellColors.accent,
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
                _WifiTextButton(label: 'Cancel', onPressed: onCancel),
                const SizedBox(width: 8),
                _WifiTextButton(
                  label: 'Connect',
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
      label: '$title. $body',
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
              label: 'Dismiss network error',
              icon: Icons.close_rounded,
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
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
                color: _focused ? ShellColors.accent : ShellColors.hairlineSoft,
              ),
            ),
            child: widget.busy
                ? const Padding(
                    padding: EdgeInsets.all(9),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: ShellColors.accent,
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
              border: _focused ? Border.all(color: ShellColors.accent) : null,
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
                color: _focused ? ShellColors.accent : ShellColors.hairlineSoft,
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
