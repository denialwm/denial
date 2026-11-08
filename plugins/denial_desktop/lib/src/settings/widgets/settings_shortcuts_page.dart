import 'dart:async';

import 'package:denial_flutter_sdk/materials.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/applications.dart';
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/tokens.dart';

import 'settings_controls.dart';
import 'settings_shortcut_editor.dart';
import 'settings_shortcut_presentation.dart';

class SettingsShortcutsPage extends ConsumerStatefulWidget {
  const SettingsShortcutsPage({
    this.applications = const <DesktopApp>[],
    super.key,
  });

  final List<DesktopApp> applications;

  @override
  ConsumerState<SettingsShortcutsPage> createState() =>
      _SettingsShortcutsPageState();
}

class _SettingsShortcutsPageState extends ConsumerState<SettingsShortcutsPage> {
  Timer? _catalogPoll;
  bool _refreshing = false;
  @override
  void initState() {
    super.initState();
    _catalogPoll = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_refreshing ||
          !mounted ||
          ref.read(shortcutConfigurationProvider).busy) {
        return;
      }
      _refreshing = true;
      try {
        await ref.read(shortcutConfigurationProvider.notifier).refresh();
      } finally {
        _refreshing = false;
      }
    });
  }

  @override
  void dispose() {
    _catalogPoll?.cancel();
    super.dispose();
  }

  var _editorOpen = false;
  DenialShortcutBinding? _editedBinding;

  void _openEditor(DenialShortcutBinding? binding) {
    ref.read(shortcutConfigurationProvider.notifier).clearError();
    setState(() {
      _editedBinding = binding;
      _editorOpen = true;
    });
  }

  void _closeEditor() {
    ref.read(shortcutConfigurationProvider.notifier).clearError();
    setState(() {
      _editorOpen = false;
      _editedBinding = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(shortcutConfigurationProvider);
    final controller = ref.read(shortcutConfigurationProvider.notifier);
    final configuration = state.configuration;
    return Stack(
      fit: StackFit.expand,
      children: [
        _ShortcutsPageLayout(
          state: state,
          onRetry: () => unawaited(controller.refresh()),
          onAdd: configuration == null || state.busy || _editorOpen
              ? null
              : () => _openEditor(null),
          onEdit: state.busy ? null : _openEditor,
          onDelete: (shortcut) =>
              unawaited(controller.removeShortcut(shortcut)),
        ),
        if (_editorOpen && configuration != null)
          SettingsShortcutEditor(
            key: ValueKey<String>(
              _editedBinding == null
                  ? 'shortcut-editor-add'
                  : 'shortcut-editor-${_editedBinding!.shortcut}',
            ),
            configuration: configuration,
            applications: widget.applications,
            binding: _editedBinding,
            busy: state.busy,
            deleteBusy: state.deletingShortcut == _editedBinding?.shortcut,
            nativeError: state.error,
            onValidate: controller.validateShortcut,
            onSave: (shortcut) async {
              final edited = _editedBinding;
              final saved = edited == null
                  ? await controller.addShortcut(shortcut)
                  : await controller.updateShortcut(
                      existingShortcut: edited.shortcut,
                      shortcut: shortcut,
                    );
              if (mounted && saved) {
                _closeEditor();
              }
              return saved;
            },
            onDelete: _editedBinding == null
                ? null
                : () async {
                    final deleted = await controller.removeShortcut(
                      _editedBinding!.shortcut,
                    );
                    if (mounted && deleted) {
                      _closeEditor();
                    }
                    return deleted;
                  },
            onClearError: controller.clearError,
            onClose: state.busy ? () {} : _closeEditor,
          ),
      ],
    );
  }
}

class _ShortcutsPageLayout extends StatelessWidget {
  const _ShortcutsPageLayout({
    required this.state,
    required this.onRetry,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
  });

  final ShortcutConfigurationState state;
  final VoidCallback onRetry;
  final VoidCallback? onAdd;
  final ValueChanged<DenialShortcutBinding>? onEdit;
  final ValueChanged<String> onDelete;

  @override
  Widget build(BuildContext context) {
    final count = state.configuration?.shortcuts.length;
    return SettingsPageScaffold(
      title: context.l10n.settingsShortcutsSection,
      description: context.l10n.settingsShortcutsTitle,
      actions: [
        SettingsCommand(
          label: context.l10n.settingsShortcutsAdd,
          icon: Icons.add_rounded,
          onPressed: onAdd,
        ),
      ],
      footer: SettingsErrorNotice(
        message: state.error,
        onRetry: state.busy ? null : onRetry,
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final inset = settingsContentInset(constraints.maxWidth);
          return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(inset, 20, inset, 12),
                sliver: SliverToBoxAdapter(
                  child: count == null
                      ? const SizedBox.shrink()
                      : Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: _ShortcutCountBadge(count: count),
                        ),
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(inset, 0, inset, 28),
                sliver: _ShortcutList(
                  state: state,
                  onRetry: onRetry,
                  onEdit: onEdit,
                  onDelete: onDelete,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ShortcutCountBadge extends StatelessWidget {
  const _ShortcutCountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.applicationColors.control,
        borderRadius: DenialSurfaceGeometry.borderRadiusOf(context),
        border: Border.all(color: context.applicationColors.separator),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          context.l10n.settingsShortcutsConfigured(count),
          style: ShellText.cardTitle.copyWith(
            color: context.applicationColors.secondary,
            fontSize: 9,
          ),
        ),
      ),
    );
  }
}

class _ShortcutList extends StatelessWidget {
  const _ShortcutList({
    required this.state,
    required this.onRetry,
    required this.onEdit,
    required this.onDelete,
  });

  final ShortcutConfigurationState state;
  final VoidCallback onRetry;
  final ValueChanged<DenialShortcutBinding>? onEdit;
  final ValueChanged<String> onDelete;

  @override
  Widget build(BuildContext context) {
    final configuration = state.configuration;
    if (configuration == null) {
      if (state.loading) {
        return SliverToBoxAdapter(
          child: _ShortcutStatus(
            icon: Icons.sync_rounded,
            message: context.l10n.settingsShortcutsLoading,
            loading: true,
          ),
        );
      }
      return SliverToBoxAdapter(
        child: _ShortcutStatus(
          icon: Icons.link_off_rounded,
          message: context.l10n.settingsShortcutsUnavailable,
          actionLabel: context.l10n.settingsShortcutsRetry,
          onAction: onRetry,
        ),
      );
    }
    if (configuration.shortcuts.isEmpty) {
      return SliverToBoxAdapter(
        child: _ShortcutStatus(
          icon: Icons.keyboard_command_key_rounded,
          message: context.l10n.settingsShortcutsEmpty,
        ),
      );
    }
    return SliverList.separated(
      itemCount: configuration.shortcuts.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final binding = configuration.shortcuts[index];
        return DenialMaterial(
          role: DenialMaterialRole.card,
          child: _ShortcutRow(
            key: ValueKey<String>(binding.shortcut),
            binding: binding,
            deleteBusy: state.deletingShortcut == binding.shortcut,
            deleteEnabled: !state.busy,
            onEdit: onEdit == null ? null : () => onEdit!(binding),
            onDelete: () => onDelete(binding.shortcut),
          ),
        );
      },
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({
    required this.binding,
    required this.deleteBusy,
    required this.deleteEnabled,
    required this.onEdit,
    required this.onDelete,
    super.key,
  });

  final DenialShortcutBinding binding;
  final bool deleteBusy;
  final bool deleteEnabled;
  final VoidCallback? onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final actionLabel = settingsShortcutTargetLabel(context, binding);
    final displayShortcut = settingsShortcutDisplay(context, binding.shortcut);
    return Semantics(
      container: true,
      label: context.l10n.settingsShortcutsRowSemantics(
        displayShortcut,
        actionLabel,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
        child: Row(
          children: [
            Expanded(
              flex: 5,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Tooltip(
                  message: displayShortcut,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: context.applicationColors.control,
                      borderRadius: DenialSurfaceGeometry.borderRadiusOf(
                        context,
                      ),
                      border: Border.all(
                        color: context.applicationColors.separator,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 11,
                        vertical: 8,
                      ),
                      child: Text(
                        displayShortcut,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ShellText.cardTitle.copyWith(
                          fontFamily: ShellText.systemBarFontFamily,
                          fontSize: 12,
                          letterSpacing: 0.15,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Icon(
                Icons.arrow_forward_rounded,
                size: 15,
                color: context.applicationColors.secondary,
              ),
            ),
            Expanded(
              flex: 5,
              child: Row(
                children: [
                  _ShortcutTargetGlyph(binding: binding),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      actionLabel,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: ShellText.cardTitle.copyWith(height: 1.25),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _ShortcutIconButton(
              icon: Icons.edit_outlined,
              tooltip: context.l10n.settingsShortcutEditorEditTitle,
              onPressed: onEdit,
            ),
            const SizedBox(width: 4),
            _ShortcutIconButton(
              icon: Icons.delete_outline_rounded,
              tooltip: context.l10n.settingsShortcutsDeleteTooltip(
                displayShortcut,
              ),
              destructive: true,
              busy: deleteBusy,
              onPressed: deleteEnabled ? onDelete : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _ShortcutTargetGlyph extends StatelessWidget {
  const _ShortcutTargetGlyph({required this.binding});

  final DenialShortcutBinding binding;

  @override
  Widget build(BuildContext context) {
    final palette = ShellTheme.of(context).accentPalette;
    final accent = palette.primary;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: accent.withAlpha(30),
        shape: BoxShape.circle,
        border: Border.all(color: accent.withAlpha(70)),
      ),
      child: SizedBox.square(
        dimension: 34,
        child: Icon(
          settingsShortcutTargetIcon(binding),
          size: 17,
          color: accent,
        ),
      ),
    );
  }
}

class _ShortcutIconButton extends StatelessWidget {
  const _ShortcutIconButton({
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.destructive = false,
    this.busy = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool destructive;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final foreground = destructive
        ? context.shellColors.performanceBad
        : context.applicationColors.secondary;
    return IconButton(
      tooltip: tooltip,
      onPressed: busy ? null : onPressed,
      iconSize: 18,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        foregroundColor: foreground,
        disabledForegroundColor: context.applicationColors.secondary.withAlpha(
          86,
        ),
        backgroundColor: context.applicationColors.control,
        disabledBackgroundColor: context.applicationColors.control.withAlpha(
          120,
        ),
        hoverColor: foreground.withAlpha(28),
        focusColor: foreground.withAlpha(28),
        shape: RoundedRectangleBorder(
          borderRadius: DenialSurfaceGeometry.borderRadiusOf(context),
          side: BorderSide(color: context.applicationColors.separator),
        ),
      ),
      icon: busy
          ? SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: foreground,
              ),
            )
          : Icon(icon),
    );
  }
}

class _ShortcutStatus extends StatelessWidget {
  const _ShortcutStatus({
    required this.icon,
    required this.message,
    this.loading = false,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String message;
  final bool loading;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              SizedBox.square(
                dimension: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: accent,
                ),
              )
            else
              Icon(icon, size: 34, color: context.applicationColors.secondary),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: ShellText.base.copyWith(
                color: context.applicationColors.secondary,
                height: 1.4,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 14),
              SettingsTextButton(label: actionLabel!, onPressed: onAction),
            ],
          ],
        ),
      ),
    );
  }
}
