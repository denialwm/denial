import 'package:flutter/material.dart';
import 'package:denial_flutter_sdk/materials.dart';

import 'package:denial_flutter_sdk/localization.dart';

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
  };
}

class SettingsNavigation extends StatelessWidget {
  const SettingsNavigation({
    required this.selected,
    required this.onSelected,
    required this.compact,
    this.showTouchpad = false,
    this.showFingerprint = false,
    super.key,
  });

  final SettingsPageId selected;
  final ValueChanged<SettingsPageId> onSelected;
  final bool compact;
  final bool showTouchpad;
  final bool showFingerprint;

  Iterable<SettingsPageId> get _visiblePages => SettingsPageId.values.where(
    (page) =>
        (page != SettingsPageId.touchpad || showTouchpad) &&
        (page != SettingsPageId.fingerprint || showFingerprint),
  );

  Widget _destination(BuildContext context, SettingsPageId page) {
    final active = page == selected;
    final label = Text(
      page.label(context),
      style: TextStyle(fontWeight: active ? FontWeight.w600 : FontWeight.w400),
    );
    return Padding(
      key: ValueKey<SettingsPageId>(page),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Semantics(
        selected: active,
        child: TextButton(
          onPressed: () => onSelected(page),
          style: TextButton.styleFrom(
            foregroundColor: context.applicationColors.foreground,
            backgroundColor: active
                ? context.applicationColors.foreground.withValues(alpha: .12)
                : null,
            minimumSize: const Size(44, 44),
            alignment: AlignmentDirectional.centerStart,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            shape: RoundedRectangleBorder(
              borderRadius: DenialSurfaceGeometry.borderRadiusOf(
                context,
                inset: 12,
              ),
            ),
          ),
          child: Row(
            mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
            children: [
              Icon(page.icon, size: 19),
              const SizedBox(width: 12),
              if (compact) label else Expanded(child: label),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => DenialMaterial(
    role: DenialMaterialRole.sidebar,
    floating: true,
    child: Builder(
      builder: (context) {
        if (compact) {
          return SingleChildScrollView(
            key: settingsNavigationListKey,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                for (final page in _visiblePages) _destination(context, page),
              ],
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 20, 28),
              child: Row(
                children: [
                  const Icon(Icons.settings_outlined, size: 23),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      context.l10n.settingsNavigationSection,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        letterSpacing: -.3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                key: settingsNavigationListKey,
                padding: const EdgeInsets.only(bottom: 12),
                children: [
                  for (final page in _visiblePages) _destination(context, page),
                ],
              ),
            ),
          ],
        );
      },
    ),
  );
}
