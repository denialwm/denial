import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../localization/denial_localizations.dart';
import '../../models/shortcut_configuration.dart';
import '../../state/shortcut_configuration.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import 'settings_controls.dart';
import 'settings_shortcut_editor.dart';
import 'settings_shortcut_presentation.dart';

class SettingsShortcutsPage extends ConsumerStatefulWidget {
  const SettingsShortcutsPage({super.key});

  @override
  ConsumerState<SettingsShortcutsPage> createState() =>
      _SettingsShortcutsPageState();
}

class _SettingsShortcutsPageState extends ConsumerState<SettingsShortcutsPage> {
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
          onAdd: configuration == null || state.busy
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontalPadding = constraints.maxWidth < 560 ? 14.0 : 20.0;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            16,
            horizontalPadding,
            16,
          ),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: SizedBox.expand(
                child: Stack(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _ShortcutsHeader(state: state),
                        const SizedBox(height: 14),
                        if (state.error case final error?) ...[
                          _ShortcutErrorBanner(
                            error: error,
                            canRetry: !state.busy,
                            onRetry: onRetry,
                          ),
                          const SizedBox(height: 12),
                        ],
                        Expanded(
                          child: _ShortcutList(
                            state: state,
                            onRetry: onRetry,
                            onEdit: onEdit,
                            onDelete: onDelete,
                          ),
                        ),
                      ],
                    ),
                    Positioned(
                      right: 12,
                      bottom: 12,
                      child: _AddShortcutButton(
                        label: context.l10n.settingsShortcutsAdd,
                        onPressed: onAdd,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ShortcutsHeader extends StatelessWidget {
  const _ShortcutsHeader({required this.state});

  final ShortcutConfigurationState state;

  @override
  Widget build(BuildContext context) {
    final palette = ShellTheme.of(context).accentPalette;
    final accent = palette.primary;
    final count = state.configuration?.shortcuts.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.keyboard_command_key_rounded, size: 15, color: accent),
            const SizedBox(width: 7),
            Text(
              context.l10n.settingsShortcutsSection.toUpperCase(),
              style: ShellText.cardTitle.copyWith(
                color: accent,
                fontSize: 10,
                letterSpacing: 1.3,
              ),
            ),
            const Spacer(),
            if (count != null) ...[
              _ShortcutCountBadge(count: count),
              const SizedBox(width: 8),
            ],
            const SettingsSavedBadge(),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          context.l10n.settingsShortcutsTitle,
          style: ShellText.base.copyWith(
            color: context.shellColors.textPrimary,
            height: 1.35,
          ),
        ),
      ],
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
        color: context.shellColors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(ShellRadii.chip),
        border: Border.all(color: context.shellColors.hairlineSoft),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          context.l10n.settingsShortcutsConfigured(count),
          style: ShellText.cardTitle.copyWith(
            color: context.shellColors.textSecondary,
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
        return _ShortcutStatus(
          icon: Icons.sync_rounded,
          message: context.l10n.settingsShortcutsLoading,
          loading: true,
        );
      }
      return _ShortcutStatus(
        icon: Icons.link_off_rounded,
        message: context.l10n.settingsShortcutsUnavailable,
        actionLabel: context.l10n.settingsShortcutsRetry,
        onAction: onRetry,
      );
    }
    if (configuration.shortcuts.isEmpty) {
      return _ShortcutStatus(
        icon: Icons.keyboard_command_key_rounded,
        message: context.l10n.settingsShortcutsEmpty,
      );
    }
    final theme = ShellTheme.of(context);
    final radius = BorderRadius.circular(theme.panelRadius);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.panelColor(context.shellColors.surfaceContainerLow),
        borderRadius: radius,
        border: Border.all(color: context.shellColors.hairline),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: FocusTraversalGroup(
          child: ListView.separated(
            padding: const EdgeInsets.only(bottom: 82),
            itemCount: configuration.shortcuts.length,
            separatorBuilder: (_, _) => Divider(
              height: 1,
              indent: 16,
              endIndent: 16,
              color: context.shellColors.hairlineSoft,
            ),
            itemBuilder: (context, index) {
              final binding = configuration.shortcuts[index];
              return _ShortcutRow(
                key: ValueKey<String>(binding.shortcut),
                binding: binding,
                deleteBusy: state.deletingShortcut == binding.shortcut,
                deleteEnabled: !state.busy,
                onEdit: onEdit == null ? null : () => onEdit!(binding),
                onDelete: () => onDelete(binding.shortcut),
              );
            },
          ),
        ),
      ),
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
                      color: context.shellColors.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: context.shellColors.hairline),
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
                color: context.shellColors.textTertiary,
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
        : context.shellColors.textSecondary;
    return IconButton(
      tooltip: tooltip,
      onPressed: busy ? null : onPressed,
      iconSize: 18,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        foregroundColor: foreground,
        disabledForegroundColor: context.shellColors.textTertiary.withAlpha(86),
        backgroundColor: context.shellColors.surfaceContainerHigh,
        disabledBackgroundColor: context.shellColors.surfaceContainerHigh
            .withAlpha(120),
        hoverColor: foreground.withAlpha(28),
        focusColor: foreground.withAlpha(28),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(11),
          side: BorderSide(color: context.shellColors.hairline),
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

class _ShortcutErrorBanner extends StatelessWidget {
  const _ShortcutErrorBanner({
    required this.error,
    required this.canRetry,
    required this.onRetry,
  });

  final String error;
  final bool canRetry;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.shellColors.performanceBad.withAlpha(18),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: context.shellColors.performanceBad.withAlpha(82),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(13, 10, 8, 10),
          child: Row(
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 18,
                color: context.shellColors.performanceBad,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  error,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: ShellText.base.copyWith(
                    color: context.shellColors.textSecondary,
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SettingsTextButton(
                label: context.l10n.settingsShortcutsRetry,
                onPressed: canRetry ? onRetry : null,
              ),
            ],
          ),
        ),
      ),
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
              Icon(icon, size: 34, color: context.shellColors.textTertiary),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: ShellText.base.copyWith(
                color: context.shellColors.textSecondary,
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

class _AddShortcutButton extends StatelessWidget {
  const _AddShortcutButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = ShellTheme.of(context).accentPalette;
    return FilledButton.icon(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        backgroundColor: palette.container,
        foregroundColor: palette.onContainer,
        disabledBackgroundColor: palette.container.withAlpha(96),
        disabledForegroundColor: palette.onContainer.withAlpha(92),
        elevation: 8,
        shadowColor: context.shellColors.shadowSoft,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ShellRadii.chip),
          side: BorderSide(color: palette.outline),
        ),
      ),
      icon: Icon(Icons.add_rounded, size: 19),
      label: Text(
        label,
        style: ShellText.cardTitle.copyWith(
          color: onPressed == null
              ? palette.onContainer.withAlpha(92)
              : palette.onContainer,
        ),
      ),
    );
  }
}
