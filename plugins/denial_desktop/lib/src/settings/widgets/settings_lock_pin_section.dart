import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';

import 'settings_controls.dart';

enum _LockPinEdit { setUp, remove }

/// Sets, changes or removes the lock-screen PIN. Every change asks for the
/// account password, which `deniald --lock-pin` checks before touching the
/// stored PIN.
class SettingsLockPinSection extends ConsumerStatefulWidget {
  const SettingsLockPinSection({super.key});

  @override
  ConsumerState<SettingsLockPinSection> createState() =>
      _SettingsLockPinSectionState();
}

class _SettingsLockPinSectionState
    extends ConsumerState<SettingsLockPinSection> {
  final _password = TextEditingController();
  final _pin = TextEditingController();
  final _currentPin = TextEditingController();
  final _confirm = TextEditingController();
  _LockPinEdit? _edit;
  bool _busy = false;
  bool _requiresCurrentPin = false;
  String? _error;

  /// A PIN in use is changed with itself alone; the account password sets
  /// the first one, re-enables a removed one and removes it.
  bool get _changing =>
      _edit == _LockPinEdit.setUp &&
      (ref.read(lockPinLengthProvider).value ?? 0) > 0;

  @override
  void dispose() {
    for (final controller in [_password, _pin, _confirm, _currentPin]) {
      controller.clear();
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _open(_LockPinEdit edit) async {
    _clearFields();
    setState(() {
      _edit = edit;
      _error = null;
      _busy = true;
      _requiresCurrentPin = false;
    });
    final required = await ref
        .read(lockPinServiceProvider)
        .requiresCurrentPin();
    if (!mounted || _edit != edit) return;
    setState(() {
      _requiresCurrentPin = required;
      _busy = false;
    });
  }

  void _close() {
    _clearFields();
    setState(() {
      _edit = null;
      _error = null;
      _busy = false;
      _requiresCurrentPin = false;
    });
  }

  void _clearFields() {
    _password.clear();
    _pin.clear();
    _currentPin.clear();
    _confirm.clear();
  }

  Future<void> _submit() async {
    final edit = _edit;
    if (edit == null || _busy) {
      return;
    }
    final l10n = context.l10n;
    final password = _password.text;
    final pin = _pin.text;
    if (edit == _LockPinEdit.setUp) {
      if (!isValidLockPin(pin)) {
        setState(() => _error = l10n.settingsLockPinLengthHint);
        return;
      }
      if (pin != _confirm.text) {
        _confirm.clear();
        setState(() => _error = l10n.settingsLockPinMismatch);
        return;
      }
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final service = ref.read(lockPinServiceProvider);
    final currentPin = _currentPin.text;
    _currentPin.clear();
    final outcome = edit == _LockPinEdit.remove
        ? await service.clear(password: password)
        : _changing
        ? await service.change(currentPin: currentPin, pin: pin)
        : await service.save(
            password: password,
            pin: pin,
            currentPin: currentPin,
          );
    if (!mounted) {
      return;
    }
    _password.clear();
    setState(() {
      _busy = false;
      _error = switch (outcome) {
        LockPinOutcome.saved || LockPinOutcome.cleared => null,
        LockPinOutcome.authenticationFailed =>
          l10n.settingsLockPinWrongPassword,
        LockPinOutcome.wrongPin => l10n.lockWrongPin,
        LockPinOutcome.invalidPin => l10n.settingsLockPinLengthHint,
        LockPinOutcome.unavailable => l10n.settingsLockPinUnavailable,
      };
    });
    if (outcome == LockPinOutcome.saved || outcome == LockPinOutcome.cleared) {
      ref.invalidate(lockPinLengthProvider);
      _close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final length = ref.watch(lockPinLengthProvider).value;
    final configured = (length ?? 0) > 0;
    final edit = _edit;
    return SettingsSection(
      title: l10n.settingsLockPinTitle,
      status: length == null
          ? null
          : configured
          ? l10n.settingsLockPinOn(length)
          : l10n.settingsLockPinOff,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsControlRow(
            label: l10n.settingsLockPinLabel,
            description: l10n.settingsLockPinDescription,
            controlWidth: 260,
            control: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                SettingsTextButton(
                  label: configured
                      ? l10n.settingsLockPinChange
                      : l10n.settingsLockPinSetUp,
                  onPressed: length == null || _busy
                      ? null
                      : () => _open(_LockPinEdit.setUp),
                ),
                if (configured)
                  SettingsTextButton(
                    label: l10n.settingsLockPinRemove,
                    onPressed: _busy ? null : () => _open(_LockPinEdit.remove),
                  ),
              ],
            ),
          ),
          if (edit != null) ...[
            const SizedBox(height: 18),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if ((_requiresCurrentPin || _changing) &&
                    edit == _LockPinEdit.setUp)
                  TextField(
                    controller: _currentPin,
                    autofocus: _changing,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    maxLength: lockPinMaxLength,
                    decoration: InputDecoration(labelText: l10n.lockEnterPin),
                  ),
                if (!_changing)
                  TextField(
                    key: const ValueKey<String>('lock-pin-password'),
                    controller: _password,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    enabled: !_busy,
                    autofocus: true,
                    maxLength: 1024,
                    decoration: InputDecoration(
                      labelText: l10n.settingsLockPinPassword,
                      counterText: '',
                    ),
                    textInputAction: edit == _LockPinEdit.setUp
                        ? TextInputAction.next
                        : TextInputAction.done,
                    onSubmitted: edit == _LockPinEdit.setUp
                        ? null
                        : (_) => _submit(),
                  ),
                if (edit == _LockPinEdit.setUp) ...[
                  const SizedBox(height: 12),
                  _PinField(
                    fieldKey: const ValueKey<String>('lock-pin-new'),
                    controller: _pin,
                    label: l10n.settingsLockPinNew,
                    helper: l10n.settingsLockPinLengthHint,
                    enabled: !_busy,
                    action: TextInputAction.next,
                  ),
                  const SizedBox(height: 12),
                  _PinField(
                    fieldKey: const ValueKey<String>('lock-pin-confirm'),
                    controller: _confirm,
                    label: l10n.settingsLockPinConfirm,
                    enabled: !_busy,
                    action: TextInputAction.done,
                    onSubmitted: _submit,
                  ),
                ],
              ],
            ),
            if (_error case final error?) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  error,
                  style: TextStyle(color: context.shellColors.performanceBad),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _busy ? null : _close,
                  child: Text(l10n.commonCancel),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          edit == _LockPinEdit.setUp
                              ? l10n.settingsLockPinSave
                              : l10n.settingsLockPinRemove,
                        ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _PinField extends StatelessWidget {
  const _PinField({
    required this.fieldKey,
    required this.controller,
    required this.label,
    required this.enabled,
    required this.action,
    this.helper,
    this.onSubmitted,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;
  final String? helper;
  final bool enabled;
  final TextInputAction action;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: fieldKey,
      controller: controller,
      obscureText: true,
      autocorrect: false,
      enableSuggestions: false,
      enabled: enabled,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(lockPinMaxLength),
      ],
      decoration: InputDecoration(labelText: label, helperText: helper),
      textInputAction: action,
      onSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
    );
  }
}
