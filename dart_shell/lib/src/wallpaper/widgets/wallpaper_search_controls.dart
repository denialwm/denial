import 'package:flutter/material.dart';

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
    return Semantics(
      textField: true,
      label: 'Search Wallhaven wallpapers',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: ShellColors.panelBackground,
          borderRadius: BorderRadius.circular(ShellRadii.panel),
          border: Border.all(
            color:
                focusNode.hasFocus ? ShellColors.accent : ShellColors.hairline,
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
                        const IgnorePointer(
                          child: Text(
                            'Search Wallhaven',
                            style: TextStyle(
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
                        cursorColor: ShellColors.accent,
                        backgroundCursorColor: ShellColors.textSecondary,
                        selectionColor: ShellColors.primaryContainer,
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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ShellColors.panelBackground,
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
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (loading)
            const CircularProgressIndicator(color: ShellColors.accent)
          else
            const Icon(
              Icons.image_search_rounded,
              size: 52,
              color: ShellColors.textTertiary,
            ),
          const SizedBox(height: 16),
          Text(
            error ?? 'No wallpapers found',
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
