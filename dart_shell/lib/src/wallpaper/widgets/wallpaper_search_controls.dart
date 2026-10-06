import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

class WallpaperFolderHint extends StatelessWidget {
  const WallpaperFolderHint({super.key, required this.directory});

  final String directory;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(
          child: Icon(
            Icons.folder_outlined,
            size: 16,
            color: context.shellColors.textTertiary,
          ),
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            context.l10n.wallpaperFolderHint(directory),
            style: ShellText.base.copyWith(
              color: context.shellColors.textTertiary,
              fontSize: 12,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}

class WallpaperNetworkWarning extends StatelessWidget {
  const WallpaperNetworkWarning({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final warning = context.shellColors.performanceWarning;
    final l10n = context.l10n;
    return Semantics(
      container: true,
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: warning.withValues(alpha: 0.10),
          borderRadius: context.shellTheme.borderRadius(ShellRadii.chip),
          border: Border.all(color: warning.withValues(alpha: 0.32)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 7, 8),
          child: Row(
            children: [
              ExcludeSemantics(
                child: Icon(Icons.cloud_off_rounded, size: 18, color: warning),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.wallpaperImageServerUnavailable,
                  style: ShellText.base.copyWith(
                    color: context.shellColors.textSecondary,
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _WallpaperRetryButton(
                label: l10n.commonRetry,
                color: warning,
                onPressed: onRetry,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WallpaperRetryButton extends StatefulWidget {
  const _WallpaperRetryButton({
    required this.label,
    required this.color,
    required this.onPressed,
  });

  final String label;
  final Color color;
  final VoidCallback onPressed;

  @override
  State<_WallpaperRetryButton> createState() => _WallpaperRetryButtonState();
}

class _WallpaperRetryButtonState extends State<_WallpaperRetryButton> {
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.label,
      child: Tooltip(
        message: widget.label,
        child: FocusableActionDetector(
          mouseCursor: ShellMouseCursors.link,
          onShowFocusHighlight: (focused) => setState(() => _focused = focused),
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
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: widget.color.withValues(alpha: 0.10),
                shape: BoxShape.circle,
                border: Border.all(
                  color: _focused
                      ? ShellTheme.of(context).accent
                      : widget.color.withValues(alpha: 0.28),
                ),
              ),
              child: SizedBox.square(
                dimension: 34,
                child: Icon(
                  Icons.refresh_rounded,
                  size: 19,
                  color: widget.color,
                ),
              ),
            ),
          ),
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
