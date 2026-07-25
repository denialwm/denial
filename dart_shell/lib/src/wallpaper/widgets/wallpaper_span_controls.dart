import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../localization/denial_localizations.dart';
import '../../theme/motion.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/shell_cursor.dart';
import '../wallpaper.dart';

class WallpaperSpanAlignmentSelector extends StatelessWidget {
  const WallpaperSpanAlignmentSelector({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final WallpaperSpanAlignment value;
  final ValueChanged<WallpaperSpanAlignment> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Semantics(
      container: true,
      label: l10n.wallpaperSpanAlignment,
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 8,
        children: [
          _AlignmentGroup(
            children: [
              _ShellIconControl(
                icon: Icons.align_horizontal_left_rounded,
                semanticsLabel: l10n.wallpaperAlignLeft,
                selected: value.horizontal == WallpaperHorizontalAlignment.left,
                onPressed: () => onChanged(
                  value.copyWith(horizontal: WallpaperHorizontalAlignment.left),
                ),
              ),
              _ShellIconControl(
                icon: Icons.align_horizontal_center_rounded,
                semanticsLabel: l10n.wallpaperAlignHorizontalCenter,
                selected:
                    value.horizontal == WallpaperHorizontalAlignment.center,
                onPressed: () => onChanged(
                  value.copyWith(
                    horizontal: WallpaperHorizontalAlignment.center,
                  ),
                ),
              ),
              _ShellIconControl(
                icon: Icons.align_horizontal_right_rounded,
                semanticsLabel: l10n.wallpaperAlignRight,
                selected:
                    value.horizontal == WallpaperHorizontalAlignment.right,
                onPressed: () => onChanged(
                  value.copyWith(
                    horizontal: WallpaperHorizontalAlignment.right,
                  ),
                ),
              ),
            ],
          ),
          _AlignmentGroup(
            children: [
              _ShellIconControl(
                icon: Icons.align_vertical_top_rounded,
                semanticsLabel: l10n.wallpaperAlignTop,
                selected: value.vertical == WallpaperVerticalAlignment.top,
                onPressed: () => onChanged(
                  value.copyWith(vertical: WallpaperVerticalAlignment.top),
                ),
              ),
              _ShellIconControl(
                icon: Icons.align_vertical_center_rounded,
                semanticsLabel: l10n.wallpaperAlignVerticalCenter,
                selected: value.vertical == WallpaperVerticalAlignment.center,
                onPressed: () => onChanged(
                  value.copyWith(vertical: WallpaperVerticalAlignment.center),
                ),
              ),
              _ShellIconControl(
                icon: Icons.align_vertical_bottom_rounded,
                semanticsLabel: l10n.wallpaperAlignBottom,
                selected: value.vertical == WallpaperVerticalAlignment.bottom,
                onPressed: () => onChanged(
                  value.copyWith(vertical: WallpaperVerticalAlignment.bottom),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class WallpaperSelectorCloseButton extends StatelessWidget {
  const WallpaperSelectorCloseButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return _ShellIconControl(
      icon: Icons.close_rounded,
      semanticsLabel: context.l10n.wallpaperCloseSelector,
      selected: false,
      dimension: 46,
      iconSize: 24,
      onPressed: onPressed,
    );
  }
}

class _AlignmentGroup extends StatelessWidget {
  const _AlignmentGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ShellColors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(ShellRadii.chip),
        border: Border.all(color: ShellColors.hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

class _ShellIconControl extends StatefulWidget {
  const _ShellIconControl({
    required this.icon,
    required this.semanticsLabel,
    required this.selected,
    required this.onPressed,
    this.dimension = 36,
    this.iconSize = 20,
  });

  final IconData icon;
  final String semanticsLabel;
  final bool selected;
  final VoidCallback onPressed;
  final double dimension;
  final double iconSize;

  @override
  State<_ShellIconControl> createState() => _ShellIconControlState();
}

class _ShellIconControlState extends State<_ShellIconControl> {
  var _hovered = false;
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final highlighted = _hovered || _focused;
    final accent = ShellTheme.of(context).accentPalette;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.semanticsLabel,
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
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: Motion.tile,
            curve: Motion.standard,
            width: widget.dimension,
            height: widget.dimension,
            decoration: BoxDecoration(
              color: widget.selected
                  ? accent.container
                  : highlighted
                  ? ShellColors.surfaceContainerHighest
                  : ShellColors.panelBackground,
              shape: BoxShape.circle,
              border: Border.all(
                color: widget.selected || highlighted
                    ? accent.primary
                    : ShellColors.hairline,
              ),
              boxShadow: widget.dimension > 40
                  ? const <BoxShadow>[
                      BoxShadow(
                        color: ShellColors.shadowSoft,
                        blurRadius: 18,
                        offset: Offset(0, 8),
                      ),
                    ]
                  : null,
            ),
            child: Icon(
              widget.icon,
              size: widget.iconSize,
              color: widget.selected
                  ? accent.onContainer
                  : ShellColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
