import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../localization/denial_localizations.dart';
import '../../models/shortcut_configuration.dart';
import '../../theme/motion.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import 'settings_controls.dart';
import 'settings_shortcut_presentation.dart';

typedef ShortcutValidationCallback =
    Future<DenialShortcutValidation> Function({
      required DenialShortcutBinding shortcut,
      String? existingShortcut,
    });

class SettingsShortcutEditor extends StatefulWidget {
  const SettingsShortcutEditor({
    required this.configuration,
    required this.binding,
    required this.busy,
    required this.deleteBusy,
    required this.nativeError,
    required this.onValidate,
    required this.onSave,
    required this.onDelete,
    required this.onClearError,
    required this.onClose,
    super.key,
  });

  final DenialShortcutConfiguration configuration;
  final DenialShortcutBinding? binding;
  final bool busy;
  final bool deleteBusy;
  final String? nativeError;
  final ShortcutValidationCallback onValidate;
  final Future<bool> Function(DenialShortcutBinding shortcut) onSave;
  final Future<bool> Function()? onDelete;
  final VoidCallback onClearError;
  final VoidCallback onClose;

  @override
  State<SettingsShortcutEditor> createState() => _SettingsShortcutEditorState();
}

enum _EditorView { form, actions, inputs }

enum _EditorTarget { denialAction, spawn, spawnSh }

class _SettingsShortcutEditorState extends State<SettingsShortcutEditor> {
  static const Duration _validationDebounce = Duration(milliseconds: 300);

  late final TextEditingController _shortcut;
  late final TextEditingController _catalogSearch;
  late final TextEditingController _program;
  late final TextEditingController _shellCommand;
  final List<TextEditingController> _arguments = [];
  late _EditorTarget _targetKind;
  late DenialShortcutAction _action;
  late List<DenialShortcutAction> _visibleActions;
  late List<DenialShortcutInput> _visibleInputs;
  Timer? _validationTimer;
  var _validationGeneration = 0;
  var _validating = false;
  DenialShortcutValidation? _validation;
  String? _validationFailure;
  var _view = _EditorView.form;

  String? get _existingShortcut => widget.binding?.shortcut;

  @override
  void initState() {
    super.initState();
    _shortcut = TextEditingController(text: widget.binding?.shortcut ?? '');
    _catalogSearch = TextEditingController();
    final target = widget.binding?.target;
    _targetKind = switch (target) {
      DenialShortcutSpawnTarget() => _EditorTarget.spawn,
      DenialShortcutSpawnShTarget() => _EditorTarget.spawnSh,
      _ => _EditorTarget.denialAction,
    };
    _action = switch (target) {
      DenialShortcutActionTarget(:final action) => action,
      _ => widget.configuration.supportedActions.first,
    };
    final command = switch (target) {
      DenialShortcutSpawnTarget(:final command) => command,
      _ => const <String>[],
    };
    _program = TextEditingController(
      text: command.isEmpty ? '' : command.first,
    );
    for (final argument in command.skip(1)) {
      _arguments.add(TextEditingController(text: argument));
    }
    _shellCommand = TextEditingController(
      text: switch (target) {
        DenialShortcutSpawnShTarget(:final command) => command,
        _ => '',
      },
    );
    _visibleActions = widget.configuration.supportedActions;
    _visibleInputs = widget.configuration.supportedInputs;
    _validating = true;
    final generation = ++_validationGeneration;
    _validationTimer = Timer(
      Duration.zero,
      () => unawaited(_validate(generation)),
    );
  }

  @override
  void didUpdateWidget(covariant SettingsShortcutEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.configuration.revision != widget.configuration.revision) {
      _filterCatalog(_catalogSearch.text);
      _scheduleValidation();
    }
  }

  @override
  void dispose() {
    _validationTimer?.cancel();
    _validationGeneration += 1;
    _shortcut.dispose();
    _catalogSearch.dispose();
    _program.dispose();
    _shellCommand.dispose();
    for (final argument in _arguments) {
      argument.dispose();
    }
    super.dispose();
  }

  void _scheduleValidation() {
    _validationTimer?.cancel();
    final generation = ++_validationGeneration;
    widget.onClearError();
    setState(() {
      _validating = true;
      _validation = null;
      _validationFailure = null;
    });
    _validationTimer = Timer(
      _validationDebounce,
      () => unawaited(_validate(generation)),
    );
  }

  Future<void> _validate(int generation) async {
    try {
      final validation = await widget.onValidate(
        shortcut: _draftBinding(_shortcut.text),
        existingShortcut: _existingShortcut,
      );
      if (!mounted || generation != _validationGeneration) {
        return;
      }
      setState(() {
        _validating = false;
        _validation = validation;
        _validationFailure = null;
      });
    } on Object catch (error) {
      if (!mounted || generation != _validationGeneration) {
        return;
      }
      setState(() {
        _validating = false;
        _validation = null;
        _validationFailure = error.toString();
      });
    }
  }

  Future<void> _save() async {
    final validation = _validation;
    final canonical = validation?.canonical;
    if (widget.busy || validation?.isValid != true || canonical == null) {
      return;
    }
    await widget.onSave(_draftBinding(canonical));
  }

  DenialShortcutBinding _draftBinding(String shortcut) {
    return switch (_targetKind) {
      _EditorTarget.denialAction => DenialShortcutBinding(
        shortcut: shortcut,
        target: DenialShortcutActionTarget(_action),
      ),
      _EditorTarget.spawn => DenialShortcutBinding(
        shortcut: shortcut,
        target: DenialShortcutSpawnTarget(<String>[
          _program.text,
          for (final argument in _arguments) argument.text,
        ]),
      ),
      _EditorTarget.spawnSh => DenialShortcutBinding(
        shortcut: shortcut,
        target: DenialShortcutSpawnShTarget(_shellCommand.text),
      ),
    };
  }

  void _selectTarget(_EditorTarget target) {
    if (_targetKind == target) {
      return;
    }
    _targetKind = target;
    _scheduleValidation();
  }

  void _addArgument() {
    _arguments.add(TextEditingController());
    _scheduleValidation();
  }

  void _removeArgument(int index) {
    final controller = _arguments.removeAt(index);
    controller.dispose();
    _scheduleValidation();
  }

  void _openCatalog(_EditorView view) {
    _catalogSearch.clear();
    setState(() {
      _view = view;
      _visibleActions = widget.configuration.supportedActions;
      _visibleInputs = widget.configuration.supportedInputs;
    });
  }

  void _closeCatalog() {
    setState(() => _view = _EditorView.form);
  }

  void _filterCatalog(String query) {
    final normalized = query.trim().toLowerCase();
    if (_view == _EditorView.actions) {
      final actions = normalized.isEmpty
          ? widget.configuration.supportedActions
          : widget.configuration.supportedActions
                .where((action) {
                  return settingsShortcutActionLabel(
                    context,
                    action,
                  ).toLowerCase().contains(normalized);
                })
                .toList(growable: false);
      setState(() => _visibleActions = actions);
      return;
    }
    if (_view == _EditorView.inputs) {
      final inputs = normalized.isEmpty
          ? widget.configuration.supportedInputs
          : widget.configuration.supportedInputs
                .where((input) {
                  final category = settingsShortcutInputCategoryLabel(
                    context,
                    input.category,
                  ).toLowerCase();
                  return input.canonical.toLowerCase().contains(normalized) ||
                      category.contains(normalized) ||
                      input.aliases.any(
                        (alias) => alias.toLowerCase().contains(normalized),
                      );
                })
                .toList(growable: false);
      setState(() => _visibleInputs = inputs);
    }
  }

  void _selectAction(DenialShortcutAction action) {
    _action = action;
    _view = _EditorView.form;
    _scheduleValidation();
  }

  void _insertInput(DenialShortcutInput input) {
    if (input.kind == DenialShortcutInputKind.gesture) {
      _shortcut.value = TextEditingValue(
        text: input.canonical,
        selection: TextSelection.collapsed(offset: input.canonical.length),
      );
      _view = _EditorView.form;
      _scheduleValidation();
      return;
    }
    final value = _shortcut.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final before = value.text.substring(0, selection.start);
    final after = value.text.substring(selection.end);
    final leadingSeparator = before.isNotEmpty && !before.endsWith('+')
        ? '+'
        : '';
    final trailingSeparator = after.isNotEmpty && !after.startsWith('+')
        ? '+'
        : '';
    final insertion = '$leadingSeparator${input.canonical}$trailingSeparator';
    final text = '$before$insertion$after';
    _shortcut.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(
        offset: before.length + insertion.length,
      ),
    );
    _catalogSearch.clear();
    _visibleInputs = widget.configuration.supportedInputs;
    _scheduleValidation();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.binding == null
        ? context.l10n.settingsShortcutEditorAddTitle
        : context.l10n.settingsShortcutEditorEditTitle;
    final closeOrBack = _view == _EditorView.form
        ? widget.onClose
        : _closeCatalog;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): widget.busy
            ? () {}
            : closeOrBack,
      },
      child: Semantics(
        container: true,
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: title,
        child: ColoredBox(
          color: ShellColors.overviewScrim,
          child: LayoutBuilder(
            builder: (context, constraints) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: 620,
                      maxHeight: constraints.maxHeight - 32,
                    ),
                    child: _EditorSurface(
                      title: title,
                      busy: widget.busy,
                      onClose: widget.onClose,
                      child: AnimatedSwitcher(
                        duration: Motion.tile,
                        switchInCurve: Motion.md3EmphasizedDecelerate,
                        switchOutCurve: Motion.md3EmphasizedAccelerate,
                        child: switch (_view) {
                          _EditorView.form => _buildForm(),
                          _EditorView.actions => _buildActionCatalog(),
                          _EditorView.inputs => _buildInputCatalog(),
                        },
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildForm() {
    return Column(
      key: const ValueKey<String>('shortcut-editor-form'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
            child: FocusTraversalGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    context.l10n.settingsShortcutEditorDescription,
                    style: ShellText.base.copyWith(
                      color: ShellColors.textSecondary,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 18),
                  _EditorFieldLabel(
                    label: context.l10n.settingsShortcutEditorShortcutLabel,
                  ),
                  const SizedBox(height: 8),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final field = _ShortcutTextField(
                        controller: _shortcut,
                        enabled: !widget.busy,
                        onChanged: (_) => _scheduleValidation(),
                      );
                      final browser = SettingsTextButton(
                        label:
                            context.l10n.settingsShortcutEditorSupportedInputs,
                        onPressed: widget.busy
                            ? null
                            : () => _openCatalog(_EditorView.inputs),
                      );
                      if (constraints.maxWidth < 470) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            field,
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerRight,
                              child: browser,
                            ),
                          ],
                        );
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: field),
                          const SizedBox(width: 10),
                          browser,
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 20),
                  _EditorFieldLabel(
                    label: context.l10n.settingsShortcutEditorTargetLabel,
                  ),
                  const SizedBox(height: 8),
                  _TargetSelectionField(
                    target: _targetKind,
                    enabled: !widget.busy,
                    onSelected: _selectTarget,
                  ),
                  const SizedBox(height: 12),
                  switch (_targetKind) {
                    _EditorTarget.denialAction => _ActionSelectionField(
                      action: _action,
                      enabled: !widget.busy,
                      onPressed: () => _openCatalog(_EditorView.actions),
                    ),
                    _EditorTarget.spawn => _DirectCommandEditor(
                      program: _program,
                      arguments: _arguments,
                      enabled: !widget.busy,
                      onChanged: _scheduleValidation,
                      onAddArgument: _addArgument,
                      onRemoveArgument: _removeArgument,
                    ),
                    _EditorTarget.spawnSh => _ShellCommandEditor(
                      controller: _shellCommand,
                      enabled: !widget.busy,
                      onChanged: _scheduleValidation,
                    ),
                  },
                  const SizedBox(height: 12),
                  _ValidationMessage(
                    validating: _validating,
                    validation: _validation,
                    failure: _validationFailure,
                  ),
                  if (widget.nativeError case final error?) ...[
                    const SizedBox(height: 14),
                    _EditorErrorMessage(error: error),
                  ],
                ],
              ),
            ),
          ),
        ),
        const Divider(height: 1, color: ShellColors.hairlineSoft),
        _EditorFooter(
          canSave: !widget.busy && _validation?.isValid == true,
          saving: widget.busy && !widget.deleteBusy,
          deleting: widget.deleteBusy,
          showDelete: widget.binding != null,
          onDelete: widget.busy ? null : widget.onDelete,
          onCancel: widget.busy ? null : widget.onClose,
          onSave: () => unawaited(_save()),
        ),
      ],
    );
  }

  Widget _buildActionCatalog() {
    return _CatalogLayout(
      key: const ValueKey<String>('shortcut-editor-actions'),
      title: context.l10n.settingsShortcutEditorChooseAction,
      searchController: _catalogSearch,
      onSearchChanged: _filterCatalog,
      onBack: _closeCatalog,
      empty: _visibleActions.isEmpty,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        itemCount: _visibleActions.length,
        separatorBuilder: (_, _) => const SizedBox(height: 5),
        itemBuilder: (context, index) {
          final action = _visibleActions[index];
          return _ActionCatalogRow(
            key: ValueKey<DenialShortcutAction>(action),
            action: action,
            selected: action == _action,
            onPressed: () => _selectAction(action),
          );
        },
      ),
    );
  }

  Widget _buildInputCatalog() {
    return _CatalogLayout(
      key: const ValueKey<String>('shortcut-editor-inputs'),
      title: context.l10n.settingsShortcutEditorSupportedInputs,
      searchController: _catalogSearch,
      onSearchChanged: _filterCatalog,
      onBack: _closeCatalog,
      header: _ShortcutDraftPreview(text: _shortcut.text),
      footer: Align(
        alignment: Alignment.centerRight,
        child: SettingsTextButton(
          label: context.l10n.settingsShortcutEditorDone,
          onPressed: _closeCatalog,
        ),
      ),
      empty: _visibleInputs.isEmpty,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        itemCount: _visibleInputs.length,
        separatorBuilder: (_, _) => const SizedBox(height: 5),
        itemBuilder: (context, index) {
          final input = _visibleInputs[index];
          return _InputCatalogRow(
            key: ValueKey<String>(input.canonical),
            input: input,
            onPressed: () => _insertInput(input),
          );
        },
      ),
    );
  }
}

class _EditorSurface extends StatelessWidget {
  const _EditorSurface({
    required this.title,
    required this.busy,
    required this.onClose,
    required this.child,
  });

  final String title;
  final bool busy;
  final VoidCallback onClose;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    return Material(
      color: ShellColors.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: accent.withAlpha(86)),
      ),
      elevation: 18,
      shadowColor: ShellColors.shadow,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 10, 12),
            child: Row(
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: accent.withAlpha(32),
                    shape: BoxShape.circle,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(
                      Icons.keyboard_command_key_rounded,
                      color: accent,
                      size: 19,
                    ),
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ShellText.cardTitle.copyWith(fontSize: 16),
                  ),
                ),
                IconButton(
                  tooltip: context.l10n.settingsShortcutEditorCancel,
                  onPressed: busy ? null : onClose,
                  icon: const Icon(Icons.close_rounded),
                  style: IconButton.styleFrom(
                    foregroundColor: ShellColors.textSecondary,
                    disabledForegroundColor: ShellColors.textTertiary.withAlpha(
                      92,
                    ),
                    hoverColor: ShellColors.textPrimary.withAlpha(18),
                    focusColor: ShellColors.textPrimary.withAlpha(18),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: ShellColors.hairlineSoft),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _ShortcutTextField extends StatelessWidget {
  const _ShortcutTextField({
    required this.controller,
    required this.enabled,
    required this.onChanged,
  });

  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      autofocus: true,
      autocorrect: false,
      enableSuggestions: false,
      onChanged: onChanged,
      style: ShellText.base.copyWith(
        color: ShellColors.textPrimary,
        fontFamily: ShellText.systemBarFontFamily,
      ),
      decoration: InputDecoration(
        labelText: context.l10n.settingsShortcutEditorShortcutLabel,
        hintText: context.l10n.settingsShortcutEditorShortcutHint,
        helperText: context.l10n.settingsShortcutEditorShortcutExample,
        helperMaxLines: 2,
        helperStyle: ShellText.base.copyWith(
          color: ShellColors.textTertiary,
          fontSize: 11,
          height: 1.3,
        ),
        filled: true,
        fillColor: ShellColors.surfaceContainerHighest,
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

class _EditorFieldLabel extends StatelessWidget {
  const _EditorFieldLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: ShellText.cardTitle.copyWith(color: ShellColors.textSecondary),
    );
  }
}

class _TargetSelectionField extends StatelessWidget {
  const _TargetSelectionField({
    required this.target,
    required this.enabled,
    required this.onSelected,
  });

  final _EditorTarget target;
  final bool enabled;
  final ValueChanged<_EditorTarget> onSelected;

  @override
  Widget build(BuildContext context) {
    final palette = ShellTheme.of(context).accentPalette;
    final selector = SegmentedButton<_EditorTarget>(
      segments: <ButtonSegment<_EditorTarget>>[
        ButtonSegment(
          value: _EditorTarget.denialAction,
          icon: const Icon(Icons.auto_awesome_rounded, size: 17),
          label: Text(context.l10n.settingsShortcutEditorTargetAction),
        ),
        ButtonSegment(
          value: _EditorTarget.spawn,
          icon: const Icon(Icons.terminal_rounded, size: 17),
          label: Text(context.l10n.settingsShortcutEditorTargetProgram),
        ),
        ButtonSegment(
          value: _EditorTarget.spawnSh,
          icon: const Icon(Icons.code_rounded, size: 17),
          label: Text(context.l10n.settingsShortcutEditorTargetShell),
        ),
      ],
      selected: <_EditorTarget>{target},
      showSelectedIcon: false,
      onSelectionChanged: enabled
          ? (selection) => onSelected(selection.single)
          : null,
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected)
              ? palette.onContainer
              : ShellColors.textSecondary;
        }),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected)
              ? palette.container
              : ShellColors.surfaceContainerHighest;
        }),
        side: WidgetStateProperty.resolveWith((states) {
          return BorderSide(
            color: states.contains(WidgetState.selected)
                ? palette.outline
                : ShellColors.hairline,
          );
        }),
        overlayColor: WidgetStatePropertyAll(
          ShellColors.textPrimary.withAlpha(12),
        ),
      ),
    );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: selector,
    );
  }
}

class _DirectCommandEditor extends StatelessWidget {
  const _DirectCommandEditor({
    required this.program,
    required this.arguments,
    required this.enabled,
    required this.onChanged,
    required this.onAddArgument,
    required this.onRemoveArgument,
  });

  final TextEditingController program;
  final List<TextEditingController> arguments;
  final bool enabled;
  final VoidCallback onChanged;
  final VoidCallback onAddArgument;
  final ValueChanged<int> onRemoveArgument;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          context.l10n.settingsShortcutEditorProgramDescription,
          style: ShellText.base.copyWith(
            color: ShellColors.textTertiary,
            fontSize: 12,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 10),
        _CommandTextField(
          controller: program,
          enabled: enabled,
          label: context.l10n.settingsShortcutEditorProgramLabel,
          hint: context.l10n.settingsShortcutEditorProgramHint,
          onChanged: onChanged,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _EditorFieldLabel(
                label: context.l10n.settingsShortcutEditorArgumentsLabel,
              ),
            ),
            SettingsTextButton(
              label: context.l10n.settingsShortcutEditorAddArgument,
              onPressed: enabled ? onAddArgument : null,
            ),
          ],
        ),
        if (arguments.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              context.l10n.settingsShortcutEditorNoArguments,
              style: ShellText.base.copyWith(
                color: ShellColors.textTertiary,
                fontSize: 12,
              ),
            ),
          )
        else
          for (var index = 0; index < arguments.length; index++) ...[
            const SizedBox(height: 8),
            Row(
              key: ValueKey<TextEditingController>(arguments[index]),
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: _CommandTextField(
                    controller: arguments[index],
                    enabled: enabled,
                    label: context.l10n.settingsShortcutEditorArgumentLabel(
                      index + 1,
                    ),
                    hint: context.l10n.settingsShortcutEditorArgumentHint,
                    onChanged: onChanged,
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  tooltip: context.l10n.settingsShortcutEditorRemoveArgument(
                    index + 1,
                  ),
                  onPressed: enabled ? () => onRemoveArgument(index) : null,
                  icon: const Icon(Icons.remove_circle_outline_rounded),
                  color: ShellColors.textSecondary,
                ),
              ],
            ),
          ],
      ],
    );
  }
}

class _ShellCommandEditor extends StatelessWidget {
  const _ShellCommandEditor({
    required this.controller,
    required this.enabled,
    required this.onChanged,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          context.l10n.settingsShortcutEditorShellDescription,
          style: ShellText.base.copyWith(
            color: ShellColors.textTertiary,
            fontSize: 12,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 10),
        _CommandTextField(
          controller: controller,
          enabled: enabled,
          label: context.l10n.settingsShortcutEditorShellCommandLabel,
          hint: context.l10n.settingsShortcutEditorShellCommandHint,
          minLines: 2,
          maxLines: 4,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _CommandTextField extends StatelessWidget {
  const _CommandTextField({
    required this.controller,
    required this.enabled,
    required this.label,
    required this.hint,
    required this.onChanged,
    this.minLines = 1,
    this.maxLines = 1,
  });

  final TextEditingController controller;
  final bool enabled;
  final String label;
  final String hint;
  final VoidCallback onChanged;
  final int minLines;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      autocorrect: false,
      enableSuggestions: false,
      minLines: minLines,
      maxLines: maxLines,
      onChanged: (_) => onChanged(),
      style: ShellText.base.copyWith(
        color: ShellColors.textPrimary,
        fontFamily: ShellText.systemBarFontFamily,
      ),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        filled: true,
        fillColor: ShellColors.surfaceContainerHighest,
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

class _ActionSelectionField extends StatelessWidget {
  const _ActionSelectionField({
    required this.action,
    required this.enabled,
    required this.onPressed,
  });

  final DenialShortcutAction action;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    return OutlinedButton(
      onPressed: enabled ? onPressed : null,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        foregroundColor: ShellColors.textPrimary,
        backgroundColor: ShellColors.surfaceContainerHighest,
        side: const BorderSide(color: ShellColors.hairline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: Row(
        children: [
          Icon(settingsShortcutActionIcon(action), color: accent, size: 19),
          const SizedBox(width: 11),
          Expanded(
            child: Text(
              settingsShortcutActionLabel(context, action),
              textAlign: TextAlign.left,
              style: ShellText.cardTitle,
            ),
          ),
          const Icon(
            Icons.unfold_more_rounded,
            size: 18,
            color: ShellColors.textTertiary,
          ),
        ],
      ),
    );
  }
}

class _ValidationMessage extends StatelessWidget {
  const _ValidationMessage({
    required this.validating,
    required this.validation,
    required this.failure,
  });

  final bool validating;
  final DenialShortcutValidation? validation;
  final String? failure;

  @override
  Widget build(BuildContext context) {
    if (validating) {
      return _ValidationLine(
        color: ShellColors.textTertiary,
        icon: Icons.sync_rounded,
        message: context.l10n.settingsShortcutEditorValidating,
        progress: true,
      );
    }
    if (failure case final failure?) {
      return _ValidationLine(
        color: ShellColors.performanceBad,
        icon: Icons.error_outline_rounded,
        message: failure,
      );
    }
    final validation = this.validation;
    if (validation == null) {
      return const SizedBox.shrink();
    }
    return switch (validation.kind) {
      DenialShortcutValidationKind.valid => _ValidationLine(
        color: ShellColors.performanceGood,
        icon: Icons.check_circle_outline_rounded,
        message: context.l10n.settingsShortcutEditorValid(
          settingsShortcutDisplay(context, validation.canonical!),
        ),
      ),
      DenialShortcutValidationKind.conflict => _ValidationLine(
        color: ShellColors.performanceWarning,
        icon: Icons.warning_amber_rounded,
        message: context.l10n.settingsShortcutEditorConflict(
          settingsShortcutDisplay(context, validation.canonical!),
          settingsShortcutTargetLabel(context, validation.conflict!),
        ),
      ),
      DenialShortcutValidationKind.invalid => _ValidationLine(
        color: ShellColors.performanceWarning,
        icon: Icons.warning_amber_rounded,
        message: validation.error!,
      ),
    };
  }
}

class _ValidationLine extends StatelessWidget {
  const _ValidationLine({
    required this.color,
    required this.icon,
    required this.message,
    this.progress = false,
  });

  final Color color;
  final IconData icon;
  final String message;
  final bool progress;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (progress)
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: SizedBox.square(
                dimension: 15,
                child: CircularProgressIndicator(
                  strokeWidth: 1.8,
                  color: color,
                ),
              ),
            )
          else
            Icon(icon, color: color, size: 17),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: ShellText.base.copyWith(
                color: color,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EditorErrorMessage extends StatelessWidget {
  const _EditorErrorMessage({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ShellColors.performanceBad.withAlpha(18),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ShellColors.performanceBad.withAlpha(82)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(11),
        child: Text(
          error,
          style: ShellText.base.copyWith(
            color: ShellColors.textSecondary,
            fontSize: 12,
            height: 1.35,
          ),
        ),
      ),
    );
  }
}

class _EditorFooter extends StatelessWidget {
  const _EditorFooter({
    required this.canSave,
    required this.saving,
    required this.deleting,
    required this.showDelete,
    required this.onDelete,
    required this.onCancel,
    required this.onSave,
  });

  final bool canSave;
  final bool saving;
  final bool deleting;
  final bool showDelete;
  final Future<bool> Function()? onDelete;
  final VoidCallback? onCancel;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      child: Row(
        children: [
          if (showDelete)
            _EditorButton(
              label: context.l10n.settingsShortcutEditorDelete,
              icon: Icons.delete_outline_rounded,
              destructive: true,
              busy: deleting,
              onPressed: onDelete == null
                  ? null
                  : () => unawaited(onDelete!.call()),
            ),
          const Spacer(),
          _EditorButton(
            label: context.l10n.settingsShortcutEditorCancel,
            onPressed: onCancel,
          ),
          const SizedBox(width: 8),
          _EditorButton(
            label: saving
                ? context.l10n.settingsShortcutEditorSaving
                : context.l10n.settingsShortcutEditorSave,
            icon: Icons.check_rounded,
            primary: true,
            busy: saving,
            onPressed: canSave ? onSave : null,
          ),
        ],
      ),
    );
  }
}

class _EditorButton extends StatelessWidget {
  const _EditorButton({
    required this.label,
    this.icon,
    this.primary = false,
    this.destructive = false,
    this.busy = false,
    this.onPressed,
  });

  final String label;
  final IconData? icon;
  final bool primary;
  final bool destructive;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = ShellTheme.of(context).accentPalette;
    final foreground = primary
        ? palette.onContainer
        : destructive
        ? ShellColors.performanceBad
        : ShellColors.textSecondary;
    final enabled = busy || onPressed != null;
    final displayForeground = enabled ? foreground : foreground.withAlpha(92);
    return FilledButton.icon(
      onPressed: busy ? null : onPressed,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
        backgroundColor: primary
            ? palette.container
            : ShellColors.surfaceContainerHighest,
        foregroundColor: foreground,
        disabledBackgroundColor: primary
            ? palette.container.withAlpha(96)
            : ShellColors.surfaceContainerHighest.withAlpha(120),
        disabledForegroundColor: foreground.withAlpha(92),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ShellRadii.chip),
          side: BorderSide(
            color: primary ? palette.outline : ShellColors.hairline,
          ),
        ),
      ),
      icon: busy
          ? SizedBox.square(
              dimension: 15,
              child: CircularProgressIndicator(
                strokeWidth: 1.8,
                color: foreground,
              ),
            )
          : icon == null
          ? const SizedBox.shrink()
          : Icon(icon, size: 17),
      label: Text(
        label,
        style: ShellText.cardTitle.copyWith(color: displayForeground),
      ),
    );
  }
}

class _CatalogLayout extends StatelessWidget {
  const _CatalogLayout({
    required this.title,
    required this.searchController,
    required this.onSearchChanged,
    required this.onBack,
    required this.empty,
    required this.child,
    this.header,
    this.footer,
    super.key,
  });

  final String title;
  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onBack;
  final bool empty;
  final Widget child;
  final Widget? header;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
          child: Row(
            children: [
              IconButton(
                tooltip: context.l10n.settingsShortcutEditorBack,
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back_rounded),
                style: IconButton.styleFrom(
                  foregroundColor: ShellColors.textSecondary,
                  hoverColor: ShellColors.textPrimary.withAlpha(18),
                  focusColor: ShellColors.textPrimary.withAlpha(18),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: ShellText.cardTitle.copyWith(fontSize: 15),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          child: TextField(
            controller: searchController,
            autofocus: true,
            onChanged: onSearchChanged,
            style: ShellText.base,
            decoration: InputDecoration(
              hintText: context.l10n.settingsShortcutEditorSearch,
              prefixIcon: const Icon(Icons.search_rounded, size: 19),
              filled: true,
              fillColor: ShellColors.surfaceContainerHighest,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: ShellColors.hairline),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: ShellColors.hairline),
              ),
            ),
          ),
        ),
        if (header case final header?) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: header,
          ),
        ],
        Expanded(
          child: empty
              ? Center(
                  child: Text(
                    context.l10n.settingsShortcutEditorNoResults,
                    style: ShellText.base.copyWith(
                      color: ShellColors.textTertiary,
                    ),
                  ),
                )
              : child,
        ),
        if (footer case final footer?) ...[
          const Divider(height: 1, color: ShellColors.hairlineSoft),
          Padding(padding: const EdgeInsets.all(12), child: footer),
        ],
      ],
    );
  }
}

class _ShortcutDraftPreview extends StatelessWidget {
  const _ShortcutDraftPreview({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: accent.withAlpha(22),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent.withAlpha(70)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        child: Row(
          children: [
            Icon(Icons.keyboard_command_key_rounded, size: 16, color: accent),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                text.isEmpty
                    ? context.l10n.settingsShortcutEditorShortcutHint
                    : text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ShellText.cardTitle.copyWith(
                  color: text.isEmpty
                      ? ShellColors.textTertiary
                      : ShellColors.textPrimary,
                  fontFamily: ShellText.systemBarFontFamily,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionCatalogRow extends StatelessWidget {
  const _ActionCatalogRow({
    required this.action,
    required this.selected,
    required this.onPressed,
    super.key,
  });

  final DenialShortcutAction action;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = ShellTheme.of(context).accentPalette;
    final foreground = selected ? palette.onContainer : ShellColors.textPrimary;
    return ListTile(
      selected: selected,
      iconColor: ShellColors.textTertiary,
      textColor: ShellColors.textPrimary,
      selectedColor: foreground,
      selectedTileColor: palette.container,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
      leading: Icon(settingsShortcutActionIcon(action), size: 20),
      title: Text(
        settingsShortcutActionLabel(context, action),
        style: ShellText.cardTitle.copyWith(color: foreground),
      ),
      trailing: selected
          ? Icon(Icons.check_rounded, size: 18, color: foreground)
          : null,
      onTap: onPressed,
    );
  }
}

class _InputCatalogRow extends StatelessWidget {
  const _InputCatalogRow({
    required this.input,
    required this.onPressed,
    super.key,
  });

  final DenialShortcutInput input;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final aliases = input.aliases.join(', ');
    return ListTile(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
      leading: Icon(
        input.kind == DenialShortcutInputKind.gesture
            ? Icons.gesture_rounded
            : Icons.keyboard_rounded,
        size: 20,
        color: ShellColors.textTertiary,
      ),
      title: Text(
        input.canonical,
        style: ShellText.cardTitle.copyWith(
          fontFamily: ShellText.systemBarFontFamily,
        ),
      ),
      subtitle: aliases.isEmpty
          ? null
          : Text(
              aliases,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ShellText.base.copyWith(
                color: ShellColors.textTertiary,
                fontSize: 11,
              ),
            ),
      trailing: Text(
        settingsShortcutInputCategoryLabel(context, input.category),
        style: ShellText.base.copyWith(
          color: ShellColors.textTertiary,
          fontSize: 10,
        ),
      ),
      onTap: onPressed,
    );
  }
}
