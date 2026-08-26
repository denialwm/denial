import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  touchpad,
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
    SettingsPageId.touchpad => context.l10n.settingsNavigationTouchpad,
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
    SettingsPageId.touchpad => Icons.touch_app_rounded,
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
    this.showTouchpad = false,
    super.key,
  });

  final SettingsPageId selected;
  final ValueChanged<SettingsPageId> onSelected;
  final bool compact;
  final bool showTouchpad;

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
            for (final page in _visiblePages)
              Padding(
                padding: const EdgeInsets.only(right: 5),
                child: _NavigationDestination(
                  key: ValueKey<SettingsPageId>(page),
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
          color: context.shellColors.surfaceContainerLow.withValues(
            alpha: 0.68,
          ),
          border: Border(
            right: BorderSide(color: context.shellColors.hairlineSoft),
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
                    color: context.shellColors.textTertiary,
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
                    for (final page in _visiblePages) ...[
                      _NavigationDestination(
                        key: ValueKey<SettingsPageId>(page),
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
                    color: context.shellColors.textTertiary,
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

  Iterable<SettingsPageId> get _visiblePages => SettingsPageId.values.where(
    (page) => page != SettingsPageId.touchpad || showTouchpad,
  );
}

class _NavigationDestination extends StatefulWidget {
  const _NavigationDestination({
    required this.page,
    required this.selected,
    required this.compact,
    required this.onPressed,
    super.key,
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
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    final pageLabel = widget.page.label(context);
    final motionDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : Motion.tile;
    final label = Text(
      pageLabel,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: ShellText.cardTitle.copyWith(
        color: widget.selected
            ? context.shellColors.textPrimary
            : context.shellColors.textSecondary,
      ),
    );
    return Semantics(
      button: true,
      selected: widget.selected,
      label: pageLabel,
      child: FocusableActionDetector(
        mouseCursor: ShellMouseCursors.link,
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        onShowFocusHighlight: (value) => setState(() => _focused = value),
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
              color: widget.selected
                  ? accent.withAlpha(36)
                  : ShellMediaColors.transparentDark,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: widget.selected
                    ? accent.withAlpha(112)
                    : ShellMediaColors.transparentDark,
              ),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      duration: motionDuration,
                      curve: Motion.standard,
                      opacity: _hovered || _focused ? 1 : 0,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: widget.selected
                              ? accent.withAlpha(20)
                              : context.shellColors.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(12),
                          border: _focused ? Border.all(color: accent) : null,
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: widget.compact ? 11 : 10,
                    vertical: widget.compact ? 8 : 9,
                  ),
                  child: Row(
                    mainAxisSize: widget.compact
                        ? MainAxisSize.min
                        : MainAxisSize.max,
                    children: [
                      Icon(
                        widget.page.icon,
                        size: 17,
                        color: widget.selected
                            ? accent
                            : context.shellColors.textTertiary,
                      ),
                      const SizedBox(width: 8),
                      if (widget.compact) label else Expanded(child: label),
                    ],
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
