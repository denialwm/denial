import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../localization/denial_localizations.dart';
import '../../models/display_layout.dart';
import '../../theme/motion.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/shell_cursor.dart';
import '../wallpaper.dart';

class WallpaperTargetSelector extends StatelessWidget {
  const WallpaperTargetSelector({
    super.key,
    required this.outputs,
    required this.selected,
    required this.onSelected,
  });

  final List<DisplayOutput> outputs;
  final WallpaperTarget selected;
  final ValueChanged<WallpaperTarget> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final orderedOutputs = outputs.toList(growable: false)
      ..sort((a, b) {
        final horizontal = a.logicalRect.left.compareTo(b.logicalRect.left);
        return horizontal != 0
            ? horizontal
            : a.logicalRect.top.compareTo(b.logicalRect.top);
      });
    return Semantics(
      container: true,
      label: l10n.wallpaperTarget,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: FocusTraversalGroup(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _WallpaperTargetButton(
                label: l10n.wallpaperAllDisplays,
                semanticsLabel: l10n.wallpaperApplyAllDisplays,
                selected: selected.isAll,
                onPressed: () => onSelected(const WallpaperTarget.all()),
              ),
              for (final output in orderedOutputs) ...[
                const SizedBox(width: 8),
                _WallpaperTargetButton(
                  label: output.name,
                  semanticsLabel: l10n.wallpaperApplyDisplay(output.name),
                  selected: selected.outputName == output.name,
                  onPressed: () =>
                      onSelected(WallpaperTarget.output(output.name)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _WallpaperTargetButton extends StatefulWidget {
  const _WallpaperTargetButton({
    required this.label,
    required this.semanticsLabel,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final String semanticsLabel;
  final bool selected;
  final VoidCallback onPressed;

  @override
  State<_WallpaperTargetButton> createState() => _WallpaperTargetButtonState();
}

class _WallpaperTargetButtonState extends State<_WallpaperTargetButton> {
  var _hovered = false;
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final highlighted = _hovered || _focused;
    final accent = ShellTheme.of(context).accentPalette;
    return Semantics(
      button: true,
      selected: selected,
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
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: Motion.tile,
            curve: Motion.standard,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            decoration: BoxDecoration(
              color: selected
                  ? accent.container
                  : highlighted
                  ? context.shellColors.surfaceContainerHighest
                  : context.shellColors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(ShellRadii.chip),
              border: Border.all(
                color: highlighted || selected
                    ? accent.primary
                    : context.shellColors.hairline,
              ),
            ),
            child: Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ShellText.cardTitle.copyWith(
                color: selected
                    ? accent.onContainer
                    : context.shellColors.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
