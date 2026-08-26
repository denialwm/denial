import 'dart:async';

import 'package:flutter/material.dart' show CircularProgressIndicator, Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../localization/denial_localizations.dart';
import '../../services/bluetooth_service.dart';
import '../../state/bluetooth.dart';
import '../../theme/motion.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import '../shell_backdrop_blur.dart';

class BluetoothDetailSurface extends ConsumerStatefulWidget {
  const BluetoothDetailSurface({required this.onClose, super.key});

  final VoidCallback onClose;

  @override
  ConsumerState<BluetoothDetailSurface> createState() =>
      _BluetoothDetailSurfaceState();
}

class _BluetoothDetailSurfaceState
    extends ConsumerState<BluetoothDetailSurface> {
  final TextEditingController _pairingResponse = TextEditingController();
  final FocusNode _pairingFocus = FocusNode(debugLabel: 'bluetooth-pairing');
  late final BluetoothController _bluetoothController;
  BluetoothPairingRequest? _activePairingRequest;
  String? _pairingInputError;
  bool _disposing = false;

  @override
  void initState() {
    super.initState();
    _bluetoothController = ref.read(bluetoothProvider.notifier);
    _pairingResponse.addListener(_responseChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusPairingRequest(ref.read(bluetoothProvider).pairingRequest);
      }
    });
  }

  void _responseChanged() {
    if (mounted && !_disposing && _pairingInputError != null) {
      setState(() => _pairingInputError = null);
    }
  }

  void _pairingChanged(BluetoothPairingRequest? request) {
    if (_disposing) {
      return;
    }
    _activePairingRequest = request;
    _pairingResponse.clear();
    if (mounted) {
      setState(() => _pairingInputError = null);
    }
    _focusPairingRequest(request);
  }

  void _focusPairingRequest(BluetoothPairingRequest? request) {
    if (request?.kind.needsTextInput ?? false) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_disposing) {
          _pairingFocus.requestFocus();
        }
      });
    }
  }

  void _acceptPairing(BluetoothPairingRequest request) {
    String? response;
    if (request.kind.needsTextInput) {
      response = _pairingResponse.text;
      if (request.kind == BluetoothPairingRequestKind.pinCode &&
          (response.isEmpty ||
              response.length > 16 ||
              !RegExp(r'^[\x20-\x7e]+$').hasMatch(response))) {
        setState(() {
          _pairingInputError = context.l10n.bluetoothPinRequirements;
        });
        return;
      }
      if (request.kind == BluetoothPairingRequestKind.passkey &&
          (response.length > 6 ||
              int.tryParse(response) == null ||
              int.parse(response) > 999999)) {
        setState(() {
          _pairingInputError = context.l10n.bluetoothPasskeyRequirements;
        });
        return;
      }
    }
    _pairingResponse.clear();
    ref
        .read(bluetoothProvider.notifier)
        .respondToPairing(accepted: true, response: response);
  }

  void _rejectPairing() {
    _pairingResponse.clear();
    ref.read(bluetoothProvider.notifier).respondToPairing(accepted: false);
  }

  void _close() {
    final request = ref.read(bluetoothProvider).pairingRequest;
    if (request != null && !request.kind.informational) {
      _rejectPairing();
    }
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int?>(
      bluetoothProvider.select((state) => state.pairingRequest?.id),
      (previous, next) {
        if (previous != next) {
          _pairingChanged(ref.read(bluetoothProvider).pairingRequest);
        }
      },
    );
    final state = ref.watch(bluetoothProvider);
    _activePairingRequest = state.pairingRequest;
    final controller = ref.read(bluetoothProvider.notifier);
    final powerEnabled =
        !state.initializing &&
        state.serviceAvailable &&
        state.available &&
        !state.powerChanging;
    final scanEnabled =
        state.available &&
        state.powered &&
        !state.scanning &&
        !state.powerChanging;
    final theme = ShellTheme.of(context);
    final l10n = context.l10n;

    return SafeArea(
      minimum: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720),
          child: ShellBackdropBlur(
            blur: theme.panelOpacity < 1.0,
            borderRadius: BorderRadius.circular(theme.panelRadius),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.panelColor(context.shellColors.panelBackground),
                borderRadius: BorderRadius.circular(theme.panelRadius),
                border: Border.all(color: context.shellColors.hairline),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: context.shellColors.shadow,
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
                            Icons.bluetooth_rounded,
                            size: 23,
                            color: theme.accent,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l10n.commonBluetooth,
                                  style: ShellText.statusClock.copyWith(
                                    fontSize: 20,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  bluetoothStatusLabel(state, l10n),
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
                          _BluetoothIconButton(
                            label: state.powered
                                ? l10n.desktopTurnBluetoothOff
                                : l10n.desktopTurnBluetoothOn,
                            icon: Icons.power_settings_new_rounded,
                            active: state.powered,
                            busy: state.powerChanging,
                            enabled: powerEnabled,
                            onPressed: controller.togglePower,
                          ),
                          const SizedBox(width: 7),
                          _BluetoothIconButton(
                            label: state.scanning
                                ? l10n.bluetoothStopScanning
                                : l10n.desktopScanBluetooth,
                            icon: state.scanning
                                ? Icons.stop_rounded
                                : Icons.bluetooth_searching_rounded,
                            active: state.scanning || state.discovering,
                            busy: state.scanning,
                            enabled: state.scanning || scanEnabled,
                            onPressed: state.scanning
                                ? () => unawaited(controller.stopScan())
                                : controller.scan,
                          ),
                          const SizedBox(width: 7),
                          _BluetoothIconButton(
                            label: l10n.bluetoothCloseDetails,
                            icon: Icons.close_rounded,
                            onPressed: _close,
                          ),
                        ],
                      ),
                      if (state.error != null) ...[
                        const SizedBox(height: 10),
                        _BluetoothErrorNotice(
                          message: l10n.bluetoothOperationFailed,
                          onDismiss: controller.clearError,
                        ),
                      ],
                      if (state.pairingRequest case final request?) ...[
                        const SizedBox(height: 12),
                        _BluetoothPairingPanel(
                          request: request,
                          responseController: _pairingResponse,
                          responseFocus: _pairingFocus,
                          inputError: _pairingInputError,
                          onAccept: () => _acceptPairing(request),
                          onReject: _rejectPairing,
                        ),
                      ],
                      const SizedBox(height: 12),
                      Expanded(
                        child: _BluetoothDeviceList(
                          state: state,
                          onPair: (device) =>
                              unawaited(controller.pair(device)),
                          onToggleTrust: (device) =>
                              unawaited(controller.toggleTrust(device)),
                          onToggleConnection: (device) =>
                              unawaited(controller.toggleConnection(device)),
                          onRemove: (device) =>
                              unawaited(controller.remove(device)),
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
    _disposing = true;
    final request = _activePairingRequest;
    if (request != null && !request.kind.informational) {
      try {
        _bluetoothController.respondToPairing(accepted: false);
      } on StateError {
        // The provider may already be gone during whole-tree teardown.
      }
    }
    _pairingResponse
      ..removeListener(_responseChanged)
      ..clear()
      ..dispose();
    _pairingFocus.dispose();
    super.dispose();
  }
}

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
              borderRadius: BorderRadius.circular(16),
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

class _BluetoothPairingPanel extends StatelessWidget {
  const _BluetoothPairingPanel({
    required this.request,
    required this.responseController,
    required this.responseFocus,
    required this.inputError,
    required this.onAccept,
    required this.onReject,
  });

  final BluetoothPairingRequest request;
  final TextEditingController responseController;
  final FocusNode responseFocus;
  final String? inputError;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final title = _pairingTitle(request, l10n);
    final message = _pairingMessage(request, l10n);
    final theme = ShellTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.shellColors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: inputError == null
              ? context.shellColors.hairlineSoft
              : context.shellColors.performanceBad,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.security_rounded, size: 19, color: theme.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ShellText.cardTitle,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              message,
              style: ShellText.base.copyWith(
                color: context.shellColors.textSecondary,
                fontSize: 11,
                height: 1.35,
              ),
            ),
            if (request.kind.needsTextInput) ...[
              const SizedBox(height: 9),
              Semantics(
                textField: true,
                obscured: true,
                label: request.kind == BluetoothPairingRequestKind.pinCode
                    ? l10n.bluetoothPinCode
                    : l10n.bluetoothPasskey,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.panelColor(
                      context.shellColors.panelBackground,
                    ),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: context.shellColors.hairline),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: EditableText(
                      controller: responseController,
                      focusNode: responseFocus,
                      autofocus: true,
                      obscureText: true,
                      enableSuggestions: false,
                      autocorrect: false,
                      keyboardType:
                          request.kind == BluetoothPairingRequestKind.passkey
                          ? TextInputType.number
                          : TextInputType.visiblePassword,
                      inputFormatters:
                          request.kind == BluetoothPairingRequestKind.passkey
                          ? <TextInputFormatter>[
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(6),
                            ]
                          : <TextInputFormatter>[
                              LengthLimitingTextInputFormatter(16),
                            ],
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => onAccept(),
                      style: context.shellTheme.text.base,
                      cursorColor: theme.accent,
                      backgroundCursorColor: context.shellColors.textSecondary,
                      selectionColor:
                          context.shellTheme.accentPalette.container,
                    ),
                  ),
                ),
              ),
            ],
            if (inputError case final error?) ...[
              const SizedBox(height: 7),
              Text(
                error,
                style: ShellText.base.copyWith(
                  color: context.shellColors.performanceBad,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (!request.kind.informational) ...[
              const SizedBox(height: 9),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _BluetoothTextButton(
                    label: l10n.bluetoothReject,
                    onPressed: onReject,
                  ),
                  const SizedBox(width: 8),
                  _BluetoothTextButton(
                    label: request.kind.needsTextInput
                        ? l10n.bluetoothSubmit
                        : l10n.bluetoothAllow,
                    emphasized: true,
                    onPressed: onAccept,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _BluetoothEmptyState extends StatelessWidget {
  const _BluetoothEmptyState({
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
              Icon(icon, size: 36, color: context.shellColors.textTertiary),
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
                  color: context.shellColors.textTertiary,
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

class _BluetoothErrorNotice extends StatelessWidget {
  const _BluetoothErrorNotice({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.shellColors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.shellColors.performanceBad),
      ),
      child: Padding(
        padding: const EdgeInsets.only(left: 10, top: 7, bottom: 7),
        child: Row(
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 17,
              color: context.shellColors.performanceBad,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: ShellText.base.copyWith(
                  color: context.shellColors.performanceBad,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            _BluetoothInlineButton(
              label: context.l10n.bluetoothDismissError,
              icon: Icons.close_rounded,
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}

class _BluetoothIconButton extends StatefulWidget {
  const _BluetoothIconButton({
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
  State<_BluetoothIconButton> createState() => _BluetoothIconButtonState();
}

class _BluetoothIconButtonState extends State<_BluetoothIconButton> {
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
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: widget.active
                  ? context.shellTheme.accentPalette.container
                  : context.shellColors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _focused ? accent : context.shellColors.hairlineSoft,
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
                              ? context.shellTheme.accentPalette.onContainer
                              : context.shellColors.textSecondary
                        : context.shellColors.glyphInactive,
                  ),
          ),
        ),
      ),
    );
  }
}

class _BluetoothInlineButton extends StatefulWidget {
  const _BluetoothInlineButton({
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
  State<_BluetoothInlineButton> createState() => _BluetoothInlineButtonState();
}

class _BluetoothInlineButtonState extends State<_BluetoothInlineButton> {
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
                  ? context.shellColors.textSecondary
                  : context.shellColors.glyphInactive,
            ),
          ),
        ),
      ),
    );
  }
}

class _BluetoothTextButton extends StatefulWidget {
  const _BluetoothTextButton({
    required this.label,
    required this.onPressed,
    this.emphasized = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool emphasized;

  @override
  State<_BluetoothTextButton> createState() => _BluetoothTextButtonState();
}

class _BluetoothTextButtonState extends State<_BluetoothTextButton> {
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
                  ? context.shellTheme.accentPalette.container
                  : context.shellColors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(
                color: _focused ? accent : context.shellColors.hairlineSoft,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
              child: Text(
                widget.label,
                style: ShellText.cardTitle.copyWith(
                  color: widget.emphasized
                      ? context.shellTheme.accentPalette.onContainer
                      : context.shellColors.textSecondary,
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

String _pairingTitle(BluetoothPairingRequest request, AppLocalizations l10n) =>
    switch (request.kind) {
      BluetoothPairingRequestKind.pinCode => l10n.bluetoothEnterPin(
        request.deviceName,
      ),
      BluetoothPairingRequestKind.passkey => l10n.bluetoothEnterPasskey(
        request.deviceName,
      ),
      BluetoothPairingRequestKind.confirmation => l10n.bluetoothConfirmDevice(
        request.deviceName,
      ),
      BluetoothPairingRequestKind.authorization => l10n.bluetoothAllowPairing(
        request.deviceName,
      ),
      BluetoothPairingRequestKind.serviceAuthorization =>
        l10n.bluetoothAllowService,
      BluetoothPairingRequestKind.displayPinCode =>
        l10n.bluetoothEnterPinOnDevice(request.deviceName),
      BluetoothPairingRequestKind.displayPasskey =>
        l10n.bluetoothEnterPasskeyOnDevice(request.deviceName),
    };

String _pairingMessage(BluetoothPairingRequest request, AppLocalizations l10n) {
  final code = request.pinCode ?? request.passkey?.toString().padLeft(6, '0');
  return switch (request.kind) {
    BluetoothPairingRequestKind.pinCode => l10n.bluetoothPinPrivacy,
    BluetoothPairingRequestKind.passkey => l10n.bluetoothPasskeyPrivacy,
    BluetoothPairingRequestKind.confirmation => l10n.bluetoothConfirmCode(
      code ?? l10n.bluetoothSameCode,
    ),
    BluetoothPairingRequestKind.authorization => l10n.bluetoothRecognizeDevice,
    BluetoothPairingRequestKind.serviceAuthorization =>
      l10n.bluetoothTrustServiceDevice(request.deviceName),
    BluetoothPairingRequestKind.displayPinCode =>
      l10n.bluetoothWaitingForDevice(code ?? l10n.bluetoothCodeDisplayed),
    BluetoothPairingRequestKind.displayPasskey => l10n.bluetoothPasskeyProgress(
      code ?? l10n.bluetoothCodeDisplayed,
      request.enteredDigits,
    ),
  };
}

String bluetoothStatusLabel(BluetoothState state, AppLocalizations l10n) {
  if (state.initializing) {
    return l10n.bluetoothLoadingService;
  }
  if (!state.serviceAvailable) {
    return l10n.bluetoothServiceUnavailableShort;
  }
  if (!state.available) {
    return l10n.bluetoothNoAdapterShort;
  }
  if (!state.powered) {
    return l10n.commonOff;
  }
  var connectedCount = 0;
  String? connectedName;
  for (final device in state.devices) {
    if (device.connected) {
      connectedCount += 1;
      connectedName ??= device.name;
    }
  }
  if (connectedCount > 0) {
    return connectedCount == 1
        ? connectedName!
        : l10n.bluetoothDevicesConnected(connectedCount);
  }
  if (state.discovering) {
    return l10n.commonScanning;
  }
  return l10n.commonOn;
}

IconData _deviceIcon(String icon) {
  if (icon.contains('audio') || icon.contains('headset')) {
    return Icons.headphones_rounded;
  }
  if (icon.contains('input') || icon.contains('keyboard')) {
    return Icons.keyboard_rounded;
  }
  if (icon.contains('mouse')) {
    return Icons.mouse_rounded;
  }
  if (icon.contains('phone')) {
    return Icons.smartphone_rounded;
  }
  if (icon.contains('computer')) {
    return Icons.computer_rounded;
  }
  return Icons.bluetooth_rounded;
}
