import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/rendering.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/tokens.dart';

enum WallpaperSelectorLayout { strips, gallery }

/// The wallpaper selector's preview layout.
///
/// Deliberately not persisted: the choice survives closing and reopening the
/// selector for the rest of the shell session, and every new session starts
/// with the narrow strips.
final wallpaperSelectorLayoutProvider =
    NotifierProvider<WallpaperSelectorLayoutChoice, WallpaperSelectorLayout>(
      WallpaperSelectorLayoutChoice.new,
    );

class WallpaperSelectorLayoutChoice extends Notifier<WallpaperSelectorLayout> {
  @override
  WallpaperSelectorLayout build() => WallpaperSelectorLayout.strips;

  void select(WallpaperSelectorLayout layout) {
    if (state != layout) state = layout;
  }
}

class WallpaperLayoutSwitch extends StatelessWidget {
  const WallpaperLayoutSwitch({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final WallpaperSelectorLayout value;
  final ValueChanged<WallpaperSelectorLayout> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Semantics(
      container: true,
      label: l10n.wallpaperLayout,
      child: FocusTraversalGroup(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _WallpaperLayoutButton(
              key: const ValueKey<String>('wallpaper-layout-strips'),
              icon: Icons.view_week_rounded,
              label: l10n.wallpaperLayoutStrips,
              semanticsLabel: l10n.wallpaperLayoutStripsDescription,
              selected: value == WallpaperSelectorLayout.strips,
              onPressed: () => onChanged(WallpaperSelectorLayout.strips),
            ),
            const SizedBox(width: 8),
            _WallpaperLayoutButton(
              key: const ValueKey<String>('wallpaper-layout-gallery'),
              icon: Icons.grid_view_rounded,
              label: l10n.wallpaperLayoutGallery,
              semanticsLabel: l10n.wallpaperLayoutGalleryDescription,
              selected: value == WallpaperSelectorLayout.gallery,
              onPressed: () => onChanged(WallpaperSelectorLayout.gallery),
            ),
          ],
        ),
      ),
    );
  }
}

class _WallpaperLayoutButton extends StatefulWidget {
  const _WallpaperLayoutButton({
    super.key,
    required this.icon,
    required this.label,
    required this.semanticsLabel,
    required this.selected,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final String semanticsLabel;
  final bool selected;
  final VoidCallback onPressed;

  @override
  State<_WallpaperLayoutButton> createState() => _WallpaperLayoutButtonState();
}

class _WallpaperLayoutButtonState extends State<_WallpaperLayoutButton> {
  var _hovered = false;
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final highlighted = _hovered || _focused;
    final accent = ShellTheme.of(context).accentPalette;
    final foreground = selected
        ? accent.onContainer
        : context.shellColors.textPrimary;
    return Semantics(
      button: true,
      selected: selected,
      excludeSemantics: true,
      label: widget.semanticsLabel,
      onTap: widget.onPressed,
      child: FocusableActionDetector(
        mouseCursor: ShellMouseCursors.link,
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
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: Motion.tile,
            curve: Motion.standard,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: selected
                  ? accent.container
                  : highlighted
                  ? context.shellColors.surfaceContainerHighest
                  : context.shellColors.surfaceContainerHigh,
              borderRadius: context.shellTheme.borderRadius(ShellRadii.chip),
              border: Border.all(
                color: highlighted || selected
                    ? accent.primary
                    : context.shellColors.hairline,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.icon, size: 18, color: foreground),
                const SizedBox(width: 6),
                Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ShellText.cardTitle.copyWith(color: foreground),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
