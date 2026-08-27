part of 'bluetooth_detail_surface.dart';

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
