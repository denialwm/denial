part of 'wifi_detail_surface.dart';

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
        color: context.shellColors.surfaceContainerHigh,
        borderRadius: context.shellTheme.borderRadius(16),
        border: Border.all(
          color: error == null
              ? context.shellColors.hairlineSoft
              : context.shellColors.performanceBad,
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
                  color: theme.cardColor(context.shellColors.panelBackground),
                  borderRadius: context.shellTheme.borderRadius(12),
                  border: Border.all(
                    color: focusNode.hasFocus
                        ? theme.accent
                        : context.shellColors.hairline,
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
                    style: context.shellTheme.text.base,
                    cursorColor: theme.accent,
                    backgroundCursorColor: context.shellColors.textSecondary,
                    selectionColor: context.shellTheme.accentPalette.container,
                  ),
                ),
              ),
            ),
            if (error case final message?) ...[
              const SizedBox(height: 7),
              Text(
                message,
                style: ShellText.base.copyWith(
                  color: context.shellColors.performanceBad,
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

class _WifiNotice extends StatelessWidget {
  const _WifiNotice({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.shellTheme.accentPalette.mutedContainer,
        borderRadius: context.shellTheme.borderRadius(12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            Icon(
              icon,
              size: 16,
              color: context.shellTheme.accentPalette.onMutedContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: ShellText.base.copyWith(
                  color: context.shellTheme.accentPalette.onMutedContainer,
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
        color: context.shellColors.surfaceContainerHigh,
        borderRadius: context.shellTheme.borderRadius(12),
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
                  ? context.shellTheme.accentPalette.container
                  : context.shellColors.surfaceContainerHigh,
              borderRadius: context.shellTheme.borderRadius(12),
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
              borderRadius: context.shellTheme.borderRadius(9),
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
                  ? context.shellTheme.accentPalette.container
                  : context.shellColors.surfaceContainerHighest,
              borderRadius: context.shellTheme.borderRadius(11),
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
