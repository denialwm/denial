import 'dart:async';

import 'package:flutter/material.dart' show CircularProgressIndicator, Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/bluetooth_service.dart';
import '../../state/bluetooth.dart';
import '../../theme/motion.dart';
import '../../theme/tokens.dart';

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
          _pairingInputError = 'Enter a PIN containing 1–16 characters.';
        });
        return;
      }
      if (request.kind == BluetoothPairingRequestKind.passkey &&
          (response.length > 6 ||
              int.tryParse(response) == null ||
              int.parse(response) > 999999)) {
        setState(() {
          _pairingInputError = 'Enter a numeric passkey up to 6 digits.';
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
    final powerEnabled = !state.initializing &&
        state.serviceAvailable &&
        state.available &&
        !state.powerChanging;
    final scanEnabled = state.available &&
        state.powered &&
        !state.scanning &&
        !state.powerChanging;

    return SafeArea(
      minimum: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720),
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
                          Icons.bluetooth_rounded,
                          size: 23,
                          color: ShellColors.accent,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Bluetooth',
                                style: ShellText.statusClock.copyWith(
                                  fontSize: 20,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                bluetoothStatusLabel(state),
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
                        _BluetoothIconButton(
                          label: state.powered
                              ? 'Turn Bluetooth off'
                              : 'Turn Bluetooth on',
                          icon: Icons.power_settings_new_rounded,
                          active: state.powered,
                          busy: state.powerChanging,
                          enabled: powerEnabled,
                          onPressed: controller.togglePower,
                        ),
                        const SizedBox(width: 7),
                        _BluetoothIconButton(
                          label: state.scanning
                              ? 'Stop scanning for Bluetooth devices'
                              : 'Scan for Bluetooth devices',
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
                          label: 'Close Bluetooth details',
                          icon: Icons.close_rounded,
                          onPressed: _close,
                        ),
                      ],
                    ),
                    if (state.error case final error?) ...[
                      const SizedBox(height: 10),
                      _BluetoothErrorNotice(
                        message: error,
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
                        onPair: (device) => unawaited(controller.pair(device)),
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
    if (!state.serviceAvailable) {
      return const _BluetoothEmptyState(
        icon: Icons.bluetooth_disabled_rounded,
        title: 'BlueZ is unavailable',
        body: 'Bluetooth controls will return when the service starts.',
      );
    }
    if (!state.available) {
      return const _BluetoothEmptyState(
        icon: Icons.bluetooth_disabled_rounded,
        title: 'No Bluetooth adapter',
        body: 'Denial will enable these controls when an adapter appears.',
      );
    }
    if (!state.powered) {
      return const _BluetoothEmptyState(
        icon: Icons.bluetooth_disabled_rounded,
        title: 'Bluetooth is off',
        body: 'Turn it on to see paired and nearby devices.',
      );
    }
    if (state.devices.isEmpty) {
      return _BluetoothEmptyState(
        icon: state.discovering
            ? Icons.bluetooth_searching_rounded
            : Icons.bluetooth_rounded,
        title: state.discovering ? 'Scanning…' : 'No devices found',
        body: state.discovering
            ? 'Nearby devices will appear automatically.'
            : 'Start a scan and make the other device discoverable.',
      );
    }
    return ListView.separated(
      key: const PageStorageKey<String>('bluetooth-device-list'),
      itemCount: state.devices.length,
      separatorBuilder: (_, __) => const SizedBox(height: 7),
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
    final status = device.blocked
        ? 'Blocked'
        : device.connected
            ? device.servicesResolved
                ? 'Connected'
                : 'Connected · configuring services'
            : device.paired
                ? device.trusted
                    ? 'Paired · trusted'
                    : 'Paired'
                : device.signalStrength == null
                    ? 'Available'
                    : 'Available · ${device.signalStrength} dBm';
    return Semantics(
      button: true,
      explicitChildNodes: true,
      enabled: enabled,
      label: device.connected
          ? 'Disconnect ${device.name}'
          : 'Connect ${device.name}, $status',
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor:
            enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
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
                  _deviceIcon(device.icon),
                  size: 23,
                  color: device.connected
                      ? ShellColors.onPrimaryContainer
                      : device.blocked
                          ? ShellColors.glyphInactive
                          : ShellColors.textPrimary,
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
                          color: device.connected
                              ? ShellColors.onPrimaryContainerSecondary
                              : ShellColors.textTertiary,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!device.paired)
                  _BluetoothInlineButton(
                    label: 'Pair ${device.name}',
                    icon: Icons.link_rounded,
                    enabled: enabled,
                    onPressed: widget.onPair,
                  ),
                if (device.paired) ...[
                  _BluetoothInlineButton(
                    label: device.trusted
                        ? 'Stop trusting ${device.name}'
                        : 'Trust ${device.name}',
                    icon: device.trusted
                        ? Icons.verified_rounded
                        : Icons.verified_outlined,
                    enabled: enabled,
                    onPressed: widget.onToggleTrust,
                  ),
                  _BluetoothInlineButton(
                    label: 'Remove ${device.name}',
                    icon: Icons.delete_outline_rounded,
                    enabled: enabled,
                    onPressed: widget.onRemove,
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
                    device.connected
                        ? Icons.link_off_rounded
                        : Icons.chevron_right_rounded,
                    size: 20,
                    color: device.connected
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
    final title = _pairingTitle(request);
    final message = _pairingMessage(request);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ShellColors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: inputError == null
              ? ShellColors.hairlineSoft
              : ShellColors.performanceBad,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.security_rounded,
                  size: 19,
                  color: ShellColors.accent,
                ),
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
                color: ShellColors.textSecondary,
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
                    ? 'Bluetooth PIN code'
                    : 'Bluetooth passkey',
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: ShellColors.panelBackground,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: ShellColors.hairline),
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
                      style: ShellText.base,
                      cursorColor: ShellColors.accent,
                      backgroundCursorColor: ShellColors.textSecondary,
                      selectionColor: ShellColors.primaryContainer,
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
                  color: ShellColors.performanceBad,
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
                    label: 'Reject',
                    onPressed: onReject,
                  ),
                  const SizedBox(width: 8),
                  _BluetoothTextButton(
                    label: request.kind.needsTextInput ? 'Submit' : 'Allow',
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
      label: '$title. $body',
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 330),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 36, color: ShellColors.textTertiary),
              const SizedBox(height: 10),
              Text(title,
                  textAlign: TextAlign.center, style: ShellText.cardTitle),
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

class _BluetoothErrorNotice extends StatelessWidget {
  const _BluetoothErrorNotice({
    required this.message,
    required this.onDismiss,
  });

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
            _BluetoothInlineButton(
              label: 'Dismiss Bluetooth error',
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

String _pairingTitle(BluetoothPairingRequest request) => switch (request.kind) {
      BluetoothPairingRequestKind.pinCode =>
        'Enter the PIN for ${request.deviceName}',
      BluetoothPairingRequestKind.passkey =>
        'Enter the passkey for ${request.deviceName}',
      BluetoothPairingRequestKind.confirmation =>
        'Confirm ${request.deviceName}',
      BluetoothPairingRequestKind.authorization =>
        'Allow ${request.deviceName} to pair?',
      BluetoothPairingRequestKind.serviceAuthorization =>
        'Allow a Bluetooth service?',
      BluetoothPairingRequestKind.displayPinCode =>
        'Enter this PIN on ${request.deviceName}',
      BluetoothPairingRequestKind.displayPasskey =>
        'Enter this passkey on ${request.deviceName}',
    };

String _pairingMessage(BluetoothPairingRequest request) {
  final code = request.pinCode ?? request.passkey?.toString().padLeft(6, '0');
  return switch (request.kind) {
    BluetoothPairingRequestKind.pinCode =>
      'The PIN is sent once to BlueZ and is not retained by Denial.',
    BluetoothPairingRequestKind.passkey =>
      'The passkey is sent once to BlueZ and is not retained by Denial.',
    BluetoothPairingRequestKind.confirmation =>
      'Confirm that both devices display ${code ?? 'the same code'}.',
    BluetoothPairingRequestKind.authorization =>
      'Only continue if you recognize this device.',
    BluetoothPairingRequestKind.serviceAuthorization =>
      'Only continue if you trust ${request.deviceName}.',
    BluetoothPairingRequestKind.displayPinCode =>
      '${code ?? 'A code is being displayed'} · waiting for the other device.',
    BluetoothPairingRequestKind.displayPasskey =>
      '${code ?? 'A code is being displayed'} · '
          '${request.enteredDigits} of 6 digits entered.',
  };
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
