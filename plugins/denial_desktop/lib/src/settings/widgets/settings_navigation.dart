import 'package:flutter/material.dart';
import 'package:denial_flutter_sdk/materials.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';

const settingsNavigationListKey = ValueKey<String>('settings-navigation-list');

enum SettingsPageId {
  you,
  appearance,
  language,
  keyboard,
  touchpad,
  shortcuts,
  environment,
  animations,
  layout,
  overlays,
  lockScreen,
  fingerprint,
  permissions,
  audio,
  displays,
  network,
  bluetooth,
  power,
  developer,
  device,
  about,
}

extension SettingsPageIdPresentation on SettingsPageId {
  String label(BuildContext context) => switch (this) {
    SettingsPageId.you => context.l10n.settingsNavigationYou,
    SettingsPageId.fingerprint => context.l10n.fingerprintSection,
    SettingsPageId.permissions => context.l10n.settingsNavigationPermissions,
    SettingsPageId.about => context.l10n.settingsNavigationAbout,
    SettingsPageId.appearance => context.l10n.settingsNavigationAppearance,
    SettingsPageId.language => context.l10n.settingsNavigationLanguage,
    SettingsPageId.keyboard => context.l10n.settingsNavigationKeyboard,
    SettingsPageId.touchpad => context.l10n.settingsNavigationTouchpad,
    SettingsPageId.shortcuts => context.l10n.settingsNavigationShortcuts,
    SettingsPageId.environment => context.l10n.settingsNavigationEnvironment,
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
    SettingsPageId.device => context.l10n.settingsNavigationDevice,
  };

  IconData get icon => switch (this) {
    SettingsPageId.you => Icons.person_outline_rounded,
    SettingsPageId.fingerprint => Icons.fingerprint_rounded,
    SettingsPageId.permissions => Icons.shield_outlined,
    SettingsPageId.about => Icons.info_outline_rounded,
    SettingsPageId.appearance => Icons.palette_outlined,
    SettingsPageId.language => Icons.translate_rounded,
    SettingsPageId.keyboard => Icons.keyboard_outlined,
    SettingsPageId.touchpad => Icons.mouse_outlined,
    SettingsPageId.shortcuts => Icons.keyboard_command_key_rounded,
    SettingsPageId.environment => Icons.terminal_rounded,
    SettingsPageId.animations => Icons.animation_rounded,
    SettingsPageId.layout => Icons.space_dashboard_outlined,
    SettingsPageId.overlays => Icons.picture_in_picture_alt_outlined,
    SettingsPageId.power => Icons.power_settings_new_rounded,
    SettingsPageId.lockScreen => Icons.lock_outline_rounded,
    SettingsPageId.audio => Icons.volume_up_outlined,
    SettingsPageId.displays => Icons.monitor_outlined,
    SettingsPageId.network => Icons.wifi_rounded,
    SettingsPageId.bluetooth => Icons.bluetooth_rounded,
    SettingsPageId.developer => Icons.code_rounded,
    SettingsPageId.device => Icons.tablet_android_rounded,
  };
}

/// Navigation destinations grouped by the part of the system they shape. The
/// groups keep their order in every navigation mode.
class SettingsNavigationGroup {
  const SettingsNavigationGroup(this.pages);

  final List<SettingsPageId> pages;
}

const _personalGroup = SettingsNavigationGroup([
  SettingsPageId.you,
  SettingsPageId.appearance,
  SettingsPageId.language,
]);

const _inputGroup = SettingsNavigationGroup([
  SettingsPageId.keyboard,
  SettingsPageId.touchpad,
  SettingsPageId.shortcuts,
]);

const _desktopGroup = SettingsNavigationGroup([
  SettingsPageId.environment,
  SettingsPageId.animations,
  SettingsPageId.layout,
  SettingsPageId.overlays,
  SettingsPageId.lockScreen,
]);

const _systemGroup = SettingsNavigationGroup([
  SettingsPageId.fingerprint,
  SettingsPageId.permissions,
  SettingsPageId.audio,
  SettingsPageId.displays,
  SettingsPageId.network,
  SettingsPageId.bluetooth,
  SettingsPageId.power,
  SettingsPageId.developer,
]);

class SettingsNavigation extends StatelessWidget {
  const SettingsNavigation({
    required this.selected,
    required this.onSelected,
    this.expanded = true,
    this.showTouchpad = false,
    this.showFingerprint = false,
    super.key,
  });

  final SettingsPageId selected;
  final ValueChanged<SettingsPageId> onSelected;

  /// Full labels and group headings; otherwise only icons and group dividers.
  final bool expanded;
  final bool showTouchpad;
  final bool showFingerprint;

  List<SettingsPageId> _visible(List<SettingsPageId> pages) => [
    for (final page in pages)
      if ((page != SettingsPageId.touchpad || showTouchpad) &&
          (page != SettingsPageId.fingerprint || showFingerprint))
        page,
  ];

  @override
  Widget build(BuildContext context) {
    final groups = [
      (
        context.l10n.settingsNavigationGroupPersonal,
        _visible(_personalGroup.pages),
      ),
      (context.l10n.settingsNavigationGroupInput, _visible(_inputGroup.pages)),
      (
        context.l10n.settingsNavigationGroupDesktop,
        _visible(_desktopGroup.pages),
      ),
      (
        context.l10n.settingsNavigationGroupSystem,
        _visible(_systemGroup.pages),
      ),
    ];
    // A hint of foreground over the chrome keeps the navigation distinct from
    // the white cards without introducing a second palette.
    final tint = Color.alphaBlend(
      context.applicationColors.foreground.withValues(alpha: .04),
      context.applicationColors.chrome,
    );
    return DenialMaterial(
      role: DenialMaterialRole.sidebar,
      child: ColoredBox(
        color: tint,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              right: BorderSide(color: context.applicationColors.separator),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _brand(context),
              Expanded(
                child: ListView(
                  key: settingsNavigationListKey,
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                  children: [
                    for (final (index, group) in groups.indexed) ...[
                      if (group.$2.isNotEmpty) ...[
                        if (!expanded && index > 0) _groupSeparator(context),
                        if (expanded)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
                            child: Text(
                              group.$1,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                letterSpacing: .8,
                                color: context.applicationColors.secondary
                                    .withValues(alpha: .78),
                              ),
                            ),
                          )
                        else
                          const SizedBox(height: 6),
                        for (final page in group.$2)
                          _destination(context, page),
                      ],
                    ],
                  ],
                ),
              ),
              _footer(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _brand(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        expanded ? 22 : 0,
        20,
        expanded ? 20 : 0,
        16,
      ),
      child: Row(
        mainAxisAlignment: expanded
            ? MainAxisAlignment.start
            : MainAxisAlignment.center,
        children: [
          Icon(
            Icons.settings_outlined,
            size: 22,
            color: context.applicationColors.foreground,
          ),
          if (expanded) ...[
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                context.l10n.settingsNavigationSection,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -.3),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _footer(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Divider(
        height: 1,
        thickness: 1,
        indent: expanded ? 16 : 10,
        endIndent: expanded ? 16 : 10,
        color: context.applicationColors.separator,
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
        child: _destination(context, SettingsPageId.device),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(0, 0, 0, 12),
        child: _destination(context, SettingsPageId.about),
      ),
    ],
  );

  Widget _groupSeparator(BuildContext context) => Divider(
    height: expanded ? 20 : 13,
    thickness: 1,
    indent: 12,
    endIndent: 12,
    color: context.applicationColors.separator.withValues(alpha: .7),
  );

  Widget _destination(BuildContext context, SettingsPageId page) {
    final active = page == selected;
    final accent = ShellTheme.of(context).accent;
    final label = page.label(context);
    final icon = Icon(
      page.icon,
      size: 18,
      color: active ? accent : context.applicationColors.secondary,
    );
    final button = TextButton(
      onPressed: () => onSelected(page),
      style: TextButton.styleFrom(
        foregroundColor: active
            ? context.applicationColors.foreground
            : context.applicationColors.secondary,
        backgroundColor: active
            ? context.applicationColors.foreground.withValues(alpha: .10)
            : null,
        minimumSize: const Size(0, 40),
        padding: EdgeInsets.symmetric(horizontal: expanded ? 12 : 0),
        alignment: expanded
            ? AlignmentDirectional.centerStart
            : AlignmentDirectional.center,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
      ),
      child: expanded
          ? Row(
              children: [
                icon,
                const SizedBox(width: 11),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ],
            )
          : icon,
    );
    return Padding(
      key: ValueKey<SettingsPageId>(page),
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
      child: Semantics(
        selected: active,
        child: expanded
            ? button
            : Tooltip(
                message: label,
                child: Semantics(label: label, button: true, child: button),
              ),
      ),
    );
  }
}
