import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../local_apps/local_flutter_application.dart';
import '../localization/denial_localizations.dart';
import '../models/display_layout.dart';
import '../state/display_layout.dart';
import '../theme/motion.dart';
import '../theme/shell_theme.dart';
import '../theme/tokens.dart';
import '../wallpaper/state/wallpaper_accent.dart';
import '../wallpaper/state/wallpaper_controller.dart';
import '../wallpaper/wallpaper.dart';
import 'settings_controller.dart';
import 'shell_settings.dart';
import 'widgets/focused_border_color_picker.dart';
import 'widgets/settings_appearance_page.dart';
import 'widgets/settings_layout_page.dart';
import 'widgets/settings_lock_screen_page.dart';
import 'widgets/settings_navigation.dart';
import 'widgets/settings_overlays_page.dart';

const denialSettingsApplication = LocalFlutterApplication(
  id: 'dev.denial.settings',
  title: 'Settings',
  defaultSize: Size(980, 700),
  minimumSize: Size(560, 440),
  icon: Icons.settings_rounded,
  categories: <String>['Settings', 'System', 'Appearance', 'Preferences'],
  localizedTitle: _localizedSettingsTitle,
  localizedCategories: _localizedSettingsCategories,
  builder: _buildSettingsApplication,
);

String _localizedSettingsTitle(BuildContext context) {
  return context.l10n.settingsApplicationTitle;
}

List<String> _localizedSettingsCategories(BuildContext context) {
  final l10n = context.l10n;
  return <String>[
    l10n.settingsApplicationTitle,
    l10n.settingsApplicationCategorySystem,
    l10n.settingsApplicationCategoryAppearance,
    l10n.settingsApplicationCategoryPreferences,
  ];
}

Widget _buildSettingsApplication(
  BuildContext context,
  LocalFlutterWindowHandle window,
) {
  return const DenialSettingsApplication();
}

enum _ColorTarget { accent, focusedBorder }

class DenialSettingsApplication extends ConsumerStatefulWidget {
  const DenialSettingsApplication({super.key});

  @override
  ConsumerState<DenialSettingsApplication> createState() =>
      _DenialSettingsApplicationState();
}

class _DenialSettingsApplicationState
    extends ConsumerState<DenialSettingsApplication> {
  var _page = SettingsPageId.appearance;
  _ColorTarget? _colorTarget;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(shellSettingsProvider);
    final settingsController = ref.read(shellSettingsProvider.notifier);
    final displayLayout = ref.watch(displayLayoutProvider);
    final displayController = ref.read(displayLayoutProvider.notifier);
    final extractedAccent = ref.watch(wallpaperAccentProvider).color;
    final wallpaper = _wallpaperFor(
      ref.watch(
        wallpaperControllerProvider.select((state) => state.assignment),
      ),
      displayLayout,
    );
    return Semantics(
      container: true,
      role: .main,
      label: context.l10n.settingsApplicationSemanticsLabel,
      child: ColoredBox(
        color: ShellColors.background,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compactNavigation = constraints.maxWidth < 760;
            final content = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _SettingsHeader(),
                const Divider(height: 1, color: ShellColors.hairlineSoft),
                if (compactNavigation) ...[
                  SettingsNavigation(
                    selected: _page,
                    compact: true,
                    onSelected: (page) => setState(() => _page = page),
                  ),
                  const Divider(height: 1, color: ShellColors.hairlineSoft),
                ],
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!compactNavigation)
                        SettingsNavigation(
                          selected: _page,
                          compact: false,
                          onSelected: (page) => setState(() => _page = page),
                        ),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: Motion.cardSettle,
                          switchInCurve: Motion.md3EmphasizedDecelerate,
                          switchOutCurve: Motion.md3EmphasizedAccelerate,
                          child: KeyedSubtree(
                            key: ValueKey<SettingsPageId>(_page),
                            child: _buildPage(
                              settings: settings,
                              controller: settingsController,
                              displayLayout: displayLayout,
                              displayController: displayController,
                              extractedAccent: extractedAccent,
                              wallpaper: wallpaper,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
            return Stack(
              fit: StackFit.expand,
              children: [
                content,
                Positioned.fill(
                  child: AnimatedSwitcher(
                    duration: Motion.cardSettle,
                    reverseDuration: Motion.tile,
                    child: _buildColorPicker(settings, settingsController),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildPage({
    required ShellSettings settings,
    required ShellSettingsController controller,
    required DisplayLayout? displayLayout,
    required DisplayLayoutController displayController,
    required Color extractedAccent,
    required WallpaperResource wallpaper,
  }) {
    return switch (_page) {
      SettingsPageId.appearance => SettingsAppearancePage(
        settings: settings.appearance,
        extractedAccent: extractedAccent,
        onAccentSourceChanged: controller.setAccentSource,
        onOpenAccentPicker: () =>
            setState(() => _colorTarget = _ColorTarget.accent),
        onOpenBorderPicker: () =>
            setState(() => _colorTarget = _ColorTarget.focusedBorder),
        onWindowRadiusChanged: controller.setWindowRadius,
        onPanelRadiusChanged: controller.setPanelRadius,
        onPanelOpacityChanged: controller.setPanelOpacity,
        onFocusedOpacityChanged: controller.setFocusedWindowOpacity,
        onUnfocusedOpacityChanged: controller.setUnfocusedWindowOpacity,
        onReset: controller.resetAppearance,
      ),
      SettingsPageId.layout => SettingsLayoutPage(
        settings: settings.layout,
        displayLayout: displayLayout,
        onSystemBarChanged: (side, monitorIds) {
          final outputNames = <String>[
            for (final output
                in displayLayout?.outputs ?? const <DisplayOutput>[])
              if (monitorIds.contains(output.monitorId)) output.name,
          ];
          controller.setSystemBarPlacement(
            side: side,
            outputNames: outputNames,
          );
          unawaited(
            displayController.configureSystemBar(
              side: side,
              monitorIds: monitorIds,
            ),
          );
        },
        onSystemBarThicknessChanged: (value) {
          controller.setSystemBarThickness(value);
          _syncDisplayConfiguration(
            settings.layout.copyWith(systemBarThickness: value),
            displayController,
          );
        },
        onMaximizePaddingChanged: (value) {
          controller.setMaximizePadding(value);
          _syncDisplayConfiguration(
            settings.layout.copyWith(maximizePadding: value),
            displayController,
          );
        },
        onReset: () {
          controller.resetLayout();
          _syncDisplayConfiguration(
            const ShellLayoutSettings(),
            displayController,
          );
        },
      ),
      SettingsPageId.overlays => SettingsOverlaysPage(
        settings: settings.overlays,
        onChanged: controller.setOverlayPlacement,
        onReset: controller.resetOverlays,
      ),
      SettingsPageId.lockScreen => SettingsLockScreenPage(
        settings: settings.lockScreen,
        wallpaper: wallpaper,
        onUseWallpaperChanged: (value) =>
            controller.setLockScreen(useSystemWallpaper: value),
        onDimChanged: (value) => controller.setLockScreen(dimAmount: value),
        onBlurChanged: (value) => controller.setLockScreen(blurRadius: value),
        onClockScaleChanged: (value) =>
            controller.setLockScreen(clockScale: value),
        onShowStatusChanged: (value) =>
            controller.setLockScreen(showSystemStatus: value),
        onReset: controller.resetLockScreen,
      ),
    };
  }

  Widget _buildColorPicker(
    ShellSettings settings,
    ShellSettingsController controller,
  ) {
    final target = _colorTarget;
    if (target == null) {
      return const SizedBox.shrink(
        key: ValueKey<String>('settings-color-picker-closed'),
      );
    }
    final accent = target == _ColorTarget.accent;
    return FocusedBorderColorPicker(
      key: settingsFocusedBorderColorPickerKey,
      color: accent
          ? settings.appearance.customAccentColor
          : settings.appearance.focusedWindowBorderColor,
      title: accent ? 'Shell accent' : 'Border color',
      routeLabel: accent
          ? 'Custom shell accent color picker'
          : 'Focused window border color picker',
      wheelSemanticsLabel: accent
          ? 'Custom shell accent color'
          : 'Focused window border color',
      onChanged: accent
          ? controller.setCustomAccentColor
          : controller.setFocusedWindowBorderColor,
      onReset: () {
        if (accent) {
          controller.setCustomAccentColor(ShellColors.accent);
        } else {
          controller.setFocusedWindowBorderColor(
            ShellColors.focusedWindowBorder,
          );
        }
      },
      onClose: () => setState(() => _colorTarget = null),
    );
  }

  void _syncDisplayConfiguration(
    ShellLayoutSettings settings,
    DisplayLayoutController displayController,
  ) {
    displayController.applyShellConfiguration(
      side: settings.systemBarSide,
      outputNames: settings.systemBarOutputNames,
      systemBarThickness: settings.systemBarThickness,
      maximizePadding: settings.maximizePadding,
    );
  }

  WallpaperResource _wallpaperFor(
    WallpaperAssignment assignment,
    DisplayLayout? layout,
  ) {
    final outputName = layout?.mainOutput?.name;
    return outputName == null
        ? assignment.all
        : assignment.forOutput(outputName);
  }
}

class _SettingsHeader extends StatelessWidget {
  const _SettingsHeader();

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 22, 14),
      child: Row(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: accent.withAlpha(48),
              shape: BoxShape.circle,
              border: Border.all(color: accent.withAlpha(96)),
            ),
            child: SizedBox.square(
              dimension: 38,
              child: Icon(Icons.settings_rounded, size: 21, color: accent),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              context.l10n.settingsApplicationTitle,
              style: ShellText.statusClock,
            ),
          ),
          Text(
            context.l10n.settingsHeaderContext,
            style: ShellText.cardTitle.copyWith(
              color: ShellColors.textTertiary,
              fontSize: 9,
              letterSpacing: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}
