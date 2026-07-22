import 'package:flutter/material.dart';

import '../../theme/motion.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/shell_cursor.dart';

enum SettingsPageId { appearance, layout, overlays, lockScreen }

extension SettingsPageIdPresentation on SettingsPageId {
  String get label => switch (this) {
    SettingsPageId.appearance => 'Appearance',
    SettingsPageId.layout => 'Desktop layout',
    SettingsPageId.overlays => 'Popups & overlays',
    SettingsPageId.lockScreen => 'Lock screen',
  };

  IconData get icon => switch (this) {
    SettingsPageId.appearance => Icons.palette_outlined,
    SettingsPageId.layout => Icons.space_dashboard_outlined,
    SettingsPageId.overlays => Icons.picture_in_picture_alt_outlined,
    SettingsPageId.lockScreen => Icons.lock_outline_rounded,
  };
}

class SettingsNavigation extends StatelessWidget {
  const SettingsNavigation({
    required this.selected,
    required this.onSelected,
    required this.compact,
    super.key,
  });

  final SettingsPageId selected;
  final ValueChanged<SettingsPageId> onSelected;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return SizedBox(
        height: 62,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          children: [
            for (final page in SettingsPageId.values)
              Padding(
                padding: const EdgeInsets.only(right: 7),
                child: _NavigationDestination(
                  page: page,
                  selected: page == selected,
                  compact: true,
                  onPressed: () => onSelected(page),
                ),
              ),
          ],
        ),
      );
    }
    return SizedBox(
      width: 210,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: ShellColors.surfaceContainerLow,
          border: Border(right: BorderSide(color: ShellColors.hairlineSoft)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 18, 12, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  'PERSONALIZATION',
                  style: ShellText.cardTitle.copyWith(
                    color: ShellColors.textTertiary,
                    fontSize: 9,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              for (final page in SettingsPageId.values) ...[
                _NavigationDestination(
                  page: page,
                  selected: page == selected,
                  compact: false,
                  onPressed: () => onSelected(page),
                ),
                const SizedBox(height: 6),
              ],
              const Spacer(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  'Settings are stored in\n~/.config/denial/settings.json',
                  style: ShellText.base.copyWith(
                    color: ShellColors.textTertiary,
                    fontSize: 9,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavigationDestination extends StatefulWidget {
  const _NavigationDestination({
    required this.page,
    required this.selected,
    required this.compact,
    required this.onPressed,
  });

  final SettingsPageId page;
  final bool selected;
  final bool compact;
  final VoidCallback onPressed;

  @override
  State<_NavigationDestination> createState() => _NavigationDestinationState();
}

class _NavigationDestinationState extends State<_NavigationDestination> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.page.label,
      child: MouseRegion(
        cursor: ShellMouseCursors.link,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: Motion.tile,
            padding: EdgeInsets.symmetric(
              horizontal: widget.compact ? 13 : 12,
              vertical: widget.compact ? 10 : 12,
            ),
            decoration: BoxDecoration(
              color: widget.selected
                  ? accent.withAlpha(36)
                  : _hovered
                  ? ShellColors.surfaceContainerHigh
                  : const Color(0x00000000),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: widget.selected
                    ? accent.withAlpha(112)
                    : Colors.transparent,
              ),
            ),
            child: Row(
              mainAxisSize: widget.compact
                  ? MainAxisSize.min
                  : MainAxisSize.max,
              children: [
                Icon(
                  widget.page.icon,
                  size: 18,
                  color: widget.selected ? accent : ShellColors.textTertiary,
                ),
                const SizedBox(width: 10),
                Text(
                  widget.page.label,
                  style: ShellText.cardTitle.copyWith(
                    color: widget.selected
                        ? ShellColors.textPrimary
                        : ShellColors.textSecondary,
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
