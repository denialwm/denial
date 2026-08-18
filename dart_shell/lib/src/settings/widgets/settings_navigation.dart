import 'package:flutter/material.dart';

import '../../localization/denial_localizations.dart';
import '../../theme/motion.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/shell_cursor.dart';

const settingsNavigationListKey = ValueKey<String>('settings-navigation-list');

enum SettingsPageId {
  appearance,
  language,
  keyboard,
  shortcuts,
  animations,
  layout,
  overlays,
  lockScreen,
  audio,
  displays,
  network,
  bluetooth,
  power,
  developer,
  about,
}

extension SettingsPageIdPresentation on SettingsPageId {
  String label(BuildContext context) => switch (this) {
    SettingsPageId.about => context.l10n.settingsNavigationAbout,
    SettingsPageId.appearance => context.l10n.settingsNavigationAppearance,
    SettingsPageId.language => context.l10n.settingsNavigationLanguage,
    SettingsPageId.keyboard => context.l10n.settingsNavigationKeyboard,
    SettingsPageId.shortcuts => context.l10n.settingsNavigationShortcuts,
    SettingsPageId.animations => context.l10n.settingsNavigationAnimations,
    SettingsPageId.layout => context.l10n.settingsNavigationDesktopLayout,
    SettingsPageId.overlays => context.l10n.settingsNavigationOverlays,
    SettingsPageId.lockScreen => context.l10n.settingsNavigationLockScreen,
    SettingsPageId.audio => context.l10n.settingsNavigationAudio,
    SettingsPageId.displays => context.l10n.settingsNavigationDisplays,
    SettingsPageId.network => context.l10n.settingsNavigationNetwork,
    SettingsPageId.bluetooth => context.l10n.settingsNavigationBluetooth,
    SettingsPageId.power => context.l10n.settingsNavigationPower,
    SettingsPageId.developer => context.l10n.settingsNavigationDeveloper,
  };

  IconData get icon => switch (this) {
    SettingsPageId.about => Icons.info_outline_rounded,
    SettingsPageId.appearance => Icons.palette_outlined,
    SettingsPageId.language => Icons.translate_rounded,
    SettingsPageId.keyboard => Icons.keyboard_rounded,
    SettingsPageId.shortcuts => Icons.keyboard_command_key_rounded,
    SettingsPageId.animations => Icons.animation_rounded,
    SettingsPageId.layout => Icons.space_dashboard_outlined,
    SettingsPageId.overlays => Icons.picture_in_picture_alt_outlined,
    SettingsPageId.power => Icons.power_settings_new_rounded,
    SettingsPageId.lockScreen => Icons.lock_outline_rounded,
    SettingsPageId.audio => Icons.volume_up_rounded,
    SettingsPageId.displays => Icons.monitor_rounded,
    SettingsPageId.network => Icons.wifi_rounded,
    SettingsPageId.bluetooth => Icons.bluetooth_rounded,
    SettingsPageId.developer => Icons.code_rounded,
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
        height: 54,
        child: ListView(
          key: settingsNavigationListKey,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          children: [
            for (final page in SettingsPageId.values)
              Padding(
                padding: const EdgeInsets.only(right: 5),
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
      width: 184,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: ShellColors.surfaceContainerLow.withValues(alpha: 0.68),
          border: const Border(
            right: BorderSide(color: ShellColors.hairlineSoft),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(9, 13, 9, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  context.l10n.settingsNavigationSection,
                  style: ShellText.cardTitle.copyWith(
                    color: ShellColors.textTertiary,
                    fontSize: 9,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView(
                  key: settingsNavigationListKey,
                  padding: EdgeInsets.zero,
                  children: [
                    for (final page in SettingsPageId.values) ...[
                      _NavigationDestination(
                        page: page,
                        selected: page == selected,
                        compact: false,
                        onPressed: () => onSelected(page),
                      ),
                      const SizedBox(height: 3),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  context.l10n.settingsStorageLocation,
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
    final pageLabel = widget.page.label(context);
    final label = Text(
      pageLabel,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: ShellText.cardTitle.copyWith(
        color: widget.selected
            ? ShellColors.textPrimary
            : ShellColors.textSecondary,
      ),
    );
    return Semantics(
      button: true,
      selected: widget.selected,
      label: pageLabel,
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
              horizontal: widget.compact ? 11 : 10,
              vertical: widget.compact ? 8 : 9,
            ),
            decoration: BoxDecoration(
              color: widget.selected
                  ? accent.withAlpha(36)
                  : _hovered
                  ? ShellColors.surfaceContainerHigh
                  : const Color(0x00000000),
              borderRadius: BorderRadius.circular(12),
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
                  size: 17,
                  color: widget.selected ? accent : ShellColors.textTertiary,
                ),
                const SizedBox(width: 8),
                if (widget.compact) label else Expanded(child: label),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
