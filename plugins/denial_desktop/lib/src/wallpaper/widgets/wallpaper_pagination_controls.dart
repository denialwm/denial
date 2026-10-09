import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/rendering.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/tokens.dart';

/// Catalog pages, shared by both desktop preview layouts. Not strip indices.
class WallpaperPaginationControls extends StatelessWidget {
  const WallpaperPaginationControls({
    super.key,
    required this.page,
    required this.lastPage,
    required this.loading,
    required this.hasMore,
    required this.hasError,
    required this.onPrevious,
    required this.onNext,
    required this.onRetry,
  });

  final int page;
  final int? lastPage;
  final bool loading;
  final bool hasMore;
  final bool hasError;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final total = lastPage;
    return FocusTraversalGroup(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PageButton(
            key: const ValueKey('wallpaper-previous-page'),
            icon: Icons.chevron_left_rounded,
            label: l10n.wallpaperPreviousPage,
            onPressed: !loading && page > 1 ? onPrevious : null,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Semantics(
              liveRegion: true,
              child: Text(
                total == null
                    ? l10n.wallpaperPageNumber(page)
                    : l10n.wallpaperPageOfTotal(page, total),
                style: ShellText.cardTitle.copyWith(
                  color: context.shellColors.textPrimary,
                ),
              ),
            ),
          ),
          _PageButton(
            key: const ValueKey('wallpaper-next-page'),
            icon: Icons.chevron_right_rounded,
            label: l10n.wallpaperNextPage,
            onPressed: !loading && !hasError && hasMore ? onNext : null,
          ),
          if (hasError) ...[
            const SizedBox(width: 8),
            _PageButton(
              key: const ValueKey('wallpaper-retry-page'),
              icon: Icons.refresh_rounded,
              label: l10n.commonRetry,
              onPressed: loading ? null : onRetry,
            ),
          ],
        ],
      ),
    );
  }
}

class _PageButton extends StatefulWidget {
  const _PageButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  State<_PageButton> createState() => _PageButtonState();
}

class _PageButtonState extends State<_PageButton> {
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      excludeSemantics: true,
      label: widget.label,
      onTap: widget.onPressed,
      child: Tooltip(
        message: widget.label,
        child: FocusableActionDetector(
          enabled: enabled,
          mouseCursor: enabled
              ? ShellMouseCursors.link
              : SystemMouseCursors.basic,
          onShowFocusHighlight: (value) => setState(() => _focused = value),
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          },
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onPressed?.call();
                return null;
              },
            ),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: context.shellColors.surfaceContainerHigh,
                borderRadius: context.shellTheme.borderRadius(ShellRadii.chip),
                border: Border.all(
                  color: enabled && _focused
                      ? ShellTheme.of(context).accent
                      : context.shellColors.hairline,
                ),
              ),
              child: SizedBox.square(
                dimension: 38,
                child: Icon(
                  widget.icon,
                  size: 22,
                  color: enabled
                      ? context.shellColors.textPrimary
                      : context.shellColors.textTertiary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
