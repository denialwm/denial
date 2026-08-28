import 'package:flutter/material.dart';

import '../../localization/denial_localizations.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/shell_cursor.dart';

class WallpaperSearchField extends StatelessWidget {
  const WallpaperSearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onClear,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onClear;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final hasQuery = controller.text.isNotEmpty;
    final theme = ShellTheme.of(context);
    final accent = theme.accentPalette;
    final l10n = context.l10n;
    return Semantics(
      textField: true,
      label: l10n.wallpaperSearchSemantics,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.panelColor(context.shellColors.panelBackground),
          borderRadius: BorderRadius.circular(theme.panelRadius),
          border: Border.all(
            color: focusNode.hasFocus
                ? accent.primary
                : context.shellColors.hairline,
          ),
        ),
        child: SizedBox(
          height: 58,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              children: [
                Icon(
                  Icons.search_rounded,
                  size: 23,
                  color: context.shellColors.textSecondary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      if (!hasQuery)
                        IgnorePointer(
                          child: Text(
                            l10n.wallpaperSearchHint,
                            style: TextStyle(
                              color: context.shellColors.textTertiary,
                              fontSize: 15,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                      EditableText(
                        controller: controller,
                        focusNode: focusNode,
                        mouseCursor: ShellMouseCursors.text,
                        maxLines: 1,
                        keyboardType: TextInputType.text,
                        textInputAction: TextInputAction.search,
                        onEditingComplete: () {},
                        onSubmitted: (_) => onSubmit(),
                        style: ShellText.base.copyWith(fontSize: 15),
                        cursorColor: accent.primary,
                        backgroundCursorColor:
                            context.shellColors.textSecondary,
                        selectionColor: accent.selection,
                      ),
                    ],
                  ),
                ),
                if (hasQuery)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onClear,
                    child: SizedBox.square(
                      dimension: 34,
                      child: Icon(
                        Icons.close_rounded,
                        size: 20,
                        color: context.shellColors.textSecondary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class WallpaperStatusChip extends StatelessWidget {
  const WallpaperStatusChip({
    super.key,
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.panelColor(context.shellColors.panelBackground),
        borderRadius: context.shellTheme.borderRadius(ShellRadii.chip),
        border: Border.all(color: context.shellColors.hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: context.shellColors.textSecondary),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ShellText.cardTitle.copyWith(
                  color: context.shellColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class WallpaperEmptyState extends StatelessWidget {
  const WallpaperEmptyState({
    super.key,
    required this.loading,
    required this.error,
  });

  final bool loading;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accentPalette;
    final l10n = context.l10n;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (loading)
            CircularProgressIndicator(color: accent.primary)
          else
            Icon(
              Icons.image_search_rounded,
              size: 52,
              color: context.shellColors.textTertiary,
            ),
          const SizedBox(height: 16),
          Text(
            error == null
                ? l10n.wallpaperNoneFound
                : l10n.wallpaperServiceUnavailable,
            style: ShellText.cardTitle.copyWith(
              color: context.shellColors.textSecondary,
              fontSize: 15,
            ),
          ),
        ],
      ),
    );
  }
}
