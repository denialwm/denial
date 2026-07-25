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
          color: theme.panelColor(ShellColors.panelBackground),
          borderRadius: BorderRadius.circular(theme.panelRadius),
          border: Border.all(
            color: focusNode.hasFocus ? accent.primary : ShellColors.hairline,
          ),
          boxShadow: const [
            BoxShadow(
              color: ShellColors.shadow,
              blurRadius: 28,
              spreadRadius: 1,
              offset: Offset(0, 12),
            ),
          ],
        ),
        child: SizedBox(
          height: 58,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              children: [
                const Icon(
                  Icons.search_rounded,
                  size: 23,
                  color: ShellColors.textSecondary,
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
                            style: const TextStyle(
                              color: ShellColors.textTertiary,
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
                        backgroundCursorColor: ShellColors.textSecondary,
                        selectionColor: accent.selection,
                      ),
                    ],
                  ),
                ),
                if (hasQuery)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onClear,
                    child: const SizedBox.square(
                      dimension: 34,
                      child: Icon(
                        Icons.close_rounded,
                        size: 20,
                        color: ShellColors.textSecondary,
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
        color: theme.panelColor(ShellColors.panelBackground),
        borderRadius: BorderRadius.circular(ShellRadii.chip),
        border: Border.all(color: ShellColors.hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: ShellColors.textSecondary),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ShellText.cardTitle.copyWith(
                  color: ShellColors.textSecondary,
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
            const Icon(
              Icons.image_search_rounded,
              size: 52,
              color: ShellColors.textTertiary,
            ),
          const SizedBox(height: 16),
          Text(
            error == null
                ? l10n.wallpaperNoneFound
                : l10n.wallpaperServiceUnavailable,
            style: ShellText.cardTitle.copyWith(
              color: ShellColors.textSecondary,
              fontSize: 15,
            ),
          ),
        ],
      ),
    );
  }
}
