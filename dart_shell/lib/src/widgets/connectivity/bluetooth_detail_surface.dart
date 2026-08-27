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

part 'bluetooth_detail_controls.dart';
part 'bluetooth_device_list.dart';

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
