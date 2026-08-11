import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../localization/denial_localizations.dart';
import '../../models/keyboard_configuration.dart';
import '../../state/keyboard_configuration.dart';
import '../../theme/tokens.dart';
import 'settings_controls.dart';

class SettingsKeyboardPage extends ConsumerWidget {
  const SettingsKeyboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(keyboardConfigurationProvider);
    final controller = ref.read(keyboardConfigurationProvider.notifier);
    final configuration = state.configuration;
    if (configuration == null) {
      return SettingsPageLayout(
        icon: Icons.keyboard_rounded,
        eyebrow: context.l10n.settingsKeyboardSection,
        title: context.l10n.settingsKeyboardTitle,
        onReset: () {},
        children: [
          SettingsCardGroup(
            children: [
              SettingsSection(
                title: context.l10n.settingsKeyboardLayoutsTitle,
                child: Text(
                  state.error ?? context.l10n.settingsKeyboardLoading,
                  style: ShellText.base.copyWith(
                    color: state.error == null
                        ? ShellColors.textSecondary
                        : ShellColors.performanceBad,
                  ),
                ),
              ),
            ],
          ),
        ],
      );
    }
    return _KeyboardEditor(
      configuration: configuration,
      busy: state.busy,
      nativeError: state.error,
      onApply: controller.configure,
    );
  }
}

class _KeyboardEditor extends StatefulWidget {
  const _KeyboardEditor({
    required this.configuration,
    required this.busy,
    required this.nativeError,
    required this.onApply,
  });

  final DenialKeyboardConfiguration configuration;
  final bool busy;
  final String? nativeError;
  final Future<bool> Function(DenialKeyboardConfiguration) onApply;

  @override
  State<_KeyboardEditor> createState() => _KeyboardEditorState();
}

class _KeyboardEditorState extends State<_KeyboardEditor> {
  late final TextEditingController _layouts;
  late final TextEditingController _options;
  late int _repeatDelayMs;
  late int _repeatRateHz;
  String? _validationError;

  @override
  void initState() {
    super.initState();
    _layouts = TextEditingController();
    _options = TextEditingController();
    _load(widget.configuration);
  }

  @override
  void didUpdateWidget(covariant _KeyboardEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.configuration.revision != widget.configuration.revision) {
      _load(widget.configuration);
    }
  }

  @override
  void dispose() {
    _layouts.dispose();
    _options.dispose();
    super.dispose();
  }

  void _load(DenialKeyboardConfiguration configuration) {
    _layouts.text = configuration.layouts
        .map(
          (layout) => layout.variant.isEmpty
              ? layout.layout
              : '${layout.layout}:${layout.variant}',
        )
        .join(', ');
    _options.text = configuration.options.join(', ');
    _repeatDelayMs = configuration.repeatDelayMs;
    _repeatRateHz = configuration.repeatRateHz;
    _validationError = null;
  }

  Future<void> _apply() async {
    final layouts = <DenialKeyboardLayout>[];
    final identities = <String>{};
    for (final raw in _layouts.text.split(',')) {
      final token = raw.trim();
      if (token.isEmpty) {
        continue;
      }
      final separator = token.indexOf(':');
      final layout = separator < 0 ? token : token.substring(0, separator);
      final variant = separator < 0 ? '' : token.substring(separator + 1);
      final identity = '$layout\u0000$variant';
      if (layout.isEmpty || !identities.add(identity)) {
        setState(() {
          _validationError = context.l10n.settingsKeyboardInvalidLayouts;
        });
        return;
      }
      layouts.add(DenialKeyboardLayout(layout: layout, variant: variant));
    }
    if (layouts.isEmpty || layouts.length > 8) {
      setState(() {
        _validationError = context.l10n.settingsKeyboardInvalidLayouts;
      });
      return;
    }
    final options = _options.text
        .split(',')
        .map((option) => option.trim())
        .where((option) => option.isNotEmpty)
        .toSet()
        .toList(growable: false);
    setState(() => _validationError = null);
    await widget.onApply(
      widget.configuration.copyWith(
        layouts: layouts,
        options: options,
        repeatDelayMs: _repeatDelayMs,
        repeatRateHz: _repeatRateHz,
        activeLayout: 0,
      ),
    );
  }

  void _reset() {
    const defaults = DenialKeyboardConfiguration.defaults();
    unawaited(
      widget.onApply(
        defaults.copyWith(revision: widget.configuration.revision),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final error = _validationError ?? widget.nativeError;
    return SettingsPageLayout(
      icon: Icons.keyboard_rounded,
      eyebrow: l10n.settingsKeyboardSection,
      title: l10n.settingsKeyboardTitle,
      onReset: widget.busy ? () {} : _reset,
      children: [
        SettingsCardGroup(
          children: [
            SettingsSection(
              title: l10n.settingsKeyboardLayoutsTitle,
              status:
                  '${l10n.settingsKeyboardActiveLayout}: ${widget.configuration.active.label}',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.settingsKeyboardLayoutsDescription,
                    style: ShellText.base.copyWith(
                      color: ShellColors.textSecondary,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _KeyboardTextField(
                    controller: _layouts,
                    label: l10n.settingsKeyboardLayoutsLabel,
                    hint: l10n.settingsKeyboardLayoutsHint,
                    enabled: !widget.busy,
                  ),
                  const SizedBox(height: 14),
                  Text(
                    l10n.settingsKeyboardOptionsDescription,
                    style: ShellText.base.copyWith(
                      color: ShellColors.textSecondary,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _KeyboardTextField(
                    controller: _options,
                    label: l10n.settingsKeyboardOptionsLabel,
                    hint: l10n.settingsKeyboardOptionsHint,
                    enabled: !widget.busy,
                  ),
                ],
              ),
            ),
          ],
        ),
        SettingsCardGroup(
          children: [
            SettingsSection(
              title: l10n.settingsKeyboardRepeatTitle,
              child: Column(
                children: [
                  SettingsSlider(
                    label: l10n.settingsKeyboardRepeatDelay,
                    value: _repeatDelayMs.toDouble(),
                    minimum: 100,
                    maximum: 5000,
                    divisions: 98,
                    valueLabel: '$_repeatDelayMs ms',
                    enabled: !widget.busy,
                    onChanged: (value) => setState(
                      () => _repeatDelayMs = (value / 50).round() * 50,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SettingsSlider(
                    label: l10n.settingsKeyboardRepeatRate,
                    value: _repeatRateHz.toDouble(),
                    minimum: 0,
                    maximum: 60,
                    divisions: 60,
                    valueLabel: '$_repeatRateHz Hz',
                    enabled: !widget.busy,
                    onChanged: (value) =>
                        setState(() => _repeatRateHz = value.round()),
                  ),
                ],
              ),
            ),
            SettingsSection(
              title: l10n.settingsKeyboardSwitchingTitle,
              child: Text(
                l10n.settingsKeyboardSwitchingShortcut,
                style: ShellText.base.copyWith(
                  color: ShellColors.textSecondary,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
        if (error != null)
          Text(
            error,
            style: ShellText.base.copyWith(
              color: ShellColors.performanceBad,
              height: 1.35,
            ),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: SettingsTextButton(
            label: widget.busy
                ? l10n.settingsKeyboardApplying
                : l10n.settingsKeyboardApply,
            onPressed: widget.busy ? null : () => unawaited(_apply()),
          ),
        ),
      ],
    );
  }
}

class _KeyboardTextField extends StatelessWidget {
  const _KeyboardTextField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.enabled,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      autocorrect: false,
      enableSuggestions: false,
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9_,:+\-\s]')),
      ],
      style: ShellText.base.copyWith(
        color: ShellColors.textPrimary,
        fontFamily: ShellText.systemBarFontFamily,
      ),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        filled: true,
        fillColor: ShellColors.surfaceContainerHigh,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: ShellColors.hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: ShellColors.hairline),
        ),
      ),
    );
  }
}
