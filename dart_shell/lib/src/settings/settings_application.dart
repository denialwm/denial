import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations_en.dart';
import '../local_apps/local_flutter_application.dart';
import '../localization/denial_localizations.dart';
import '../models/display_layout.dart';
import '../state/display_layout.dart';
import '../state/output_configuration.dart';
import '../state/ui_development.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../wallpaper/state/wallpaper_accent.dart';
import '../wallpaper/state/wallpaper_controller.dart';
import '../wallpaper/wallpaper.dart';
import '../widgets/denial_wordmark.dart';
import 'settings_controller.dart';
import 'shell_settings.dart';
import 'widgets/focused_border_color_picker.dart';
import 'widgets/settings_about_page.dart';
import 'widgets/settings_appearance_page.dart';
import 'widgets/settings_animations_page.dart';
import 'widgets/settings_developer_page.dart';
import 'widgets/settings_displays_page.dart';
import 'widgets/settings_layout_page.dart';
import 'widgets/settings_keyboard_page.dart';
import 'widgets/settings_language_page.dart';
import 'widgets/settings_lock_screen_page.dart';
import 'widgets/settings_navigation.dart';
import 'widgets/settings_overlays_page.dart';
import 'widgets/settings_power_page.dart';
import 'widgets/settings_shortcuts_page.dart';
import 'widgets/settings_system_pages.dart';

final _englishSettings = AppLocalizationsEn();

final denialSettingsApplication = LocalFlutterApplication(
  id: 'dev.denial.settings',
  title: _englishSettings.settingsApplicationTitle,
  defaultSize: const Size(900, 620),
  minimumSize: const Size(520, 400),
  translucent: true,
  icon: Icons.settings_rounded,
  categories: <String>[
    _englishSettings.settingsApplicationTitle,
    _englishSettings.settingsApplicationCategorySystem,
    _englishSettings.settingsApplicationCategoryAppearance,
    _englishSettings.settingsApplicationCategoryPreferences,
  ],
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

class DenialSettingsApplication extends ConsumerStatefulWidget {
  const DenialSettingsApplication({super.key});

  @override
  ConsumerState<DenialSettingsApplication> createState() =>
      _DenialSettingsApplicationState();
}

class _DenialSettingsApplicationState
    extends ConsumerState<DenialSettingsApplication> {
  var _page = SettingsPageId.appearance;
  var _colorPickerOpen = false;

  void _selectPage(SettingsPageId page) {
    if (_page == page) {
      return;
    }
    setState(() => _page = page);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(shellSettingsProvider);
    final settingsController = ref.read(shellSettingsProvider.notifier);
    final displayLayout = ref.watch(displayLayoutProvider);
    final displayController = ref.read(displayLayoutProvider.notifier);
    final extractedAccent = ref.watch(wallpaperAccentProvider).color;
    final outputState = ref.watch(outputConfigurationProvider);
    final outputController = ref.read(outputConfigurationProvider.notifier);
    final pendingOutputConfirmation =
        outputState.configuration?.pendingConfirmation;
    if (pendingOutputConfirmation != null && _page != SettingsPageId.displays) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _selectPage(SettingsPageId.displays);
        }
      });
    }
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
      child: Material(
        color: ShellColors.background.withValues(alpha: 0.74),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compactNavigation = constraints.maxWidth < 700;
            final content = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _SettingsHeader(),
                const Divider(height: 1, color: ShellColors.hairlineSoft),
                if (compactNavigation) ...[
                  SettingsNavigation(
                    selected: _page,
                    compact: true,
                    onSelected: _selectPage,
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
                          onSelected: _selectPage,
                        ),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: Motion.cardSettle,
                          switchInCurve: Motion.md3EmphasizedDecelerate,
                          switchOutCurve: Motion.md3EmphasizedAccelerate,
                          layoutBuilder: (currentChild, previousChildren) {
                            return Stack(
                              alignment: Alignment.topCenter,
                              fit: StackFit.expand,
                              children: [...previousChildren, ?currentChild],
                            );
                          },
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
                if (pendingOutputConfirmation != null)
                  Positioned.fill(
                    child: SettingsDisplayConfirmationDialog(
                      confirmation: pendingOutputConfirmation,
                      busy: outputState.applying,
                      onKeep: () => unawaited(outputController.keepChanges()),
                      onRevert: () =>
                          unawaited(outputController.rollbackChanges()),
                      onExpired: () => unawaited(outputController.refresh()),
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
        wallpaper: wallpaper,
        onOpenWallpaperSelector: () => unawaited(_openWallpaperSelector()),
        onAccentSourceChanged: controller.setAccentSource,
        onOpenAccentPicker: () => setState(() => _colorPickerOpen = true),
        onWindowRadiusChanged: controller.setWindowRadius,
        onPanelRadiusChanged: controller.setPanelRadius,
        onPanelOpacityChanged: controller.setPanelOpacity,
        onBackdropBlurEnabledChanged: controller.setBackdropBlurEnabled,
        onBackdropBlurSigmaChanged: controller.setBackdropBlurSigma,
        onBackdropBlurOpacityThresholdChanged:
            controller.setBackdropBlurOpacityThreshold,
        onFocusedOpacityChanged: controller.setFocusedWindowOpacity,
        onUnfocusedOpacityChanged: controller.setUnfocusedWindowOpacity,
        onCursorSizeChanged: controller.setCursorSize,
        onReset: controller.resetAppearance,
      ),
      SettingsPageId.language => SettingsLanguagePage(
        settings: settings.localization,
        onChanged: controller.setLocalePreference,
        onReset: controller.resetLocalization,
      ),
      SettingsPageId.keyboard => const SettingsKeyboardPage(),
      SettingsPageId.shortcuts => const SettingsShortcutsPage(),
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
        onClipboardTrayEdgeChanged: controller.setClipboardTrayEdge,
        onClipboardTrayExtentChanged: controller.setClipboardTrayExtent,
        onReset: () {
          controller.resetLayout();
          _syncDisplayConfiguration(
            const ShellLayoutSettings(),
            displayController,
          );
        },
      ),
      SettingsPageId.animations => SettingsAnimationsPage(
        settings: settings.animations,
        onCloseEffectChanged: controller.setWindowCloseEffect,
        onDurationScaleChanged: controller.setAnimationDurationScale,
        onPanelTravelChanged: controller.setPanelTravel,
        onLockAnimationChanged: controller.setLockScreenAnimationEnabled,
        onReset: controller.resetAnimations,
      ),
      SettingsPageId.overlays => SettingsOverlaysPage(
        settings: settings.overlays,
        onChanged: controller.setOverlayPlacement,
        onReset: controller.resetOverlays,
      ),
      SettingsPageId.power => SettingsPowerPage(
        settings: settings.power,
        onEnabledChanged: controller.setIdleDpmsEnabled,
        onTimeoutChanged: controller.setIdleDpmsTimeoutMinutes,
        onReset: controller.resetPower,
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
      SettingsPageId.audio => const SettingsAudioPage(),
      SettingsPageId.displays => const SettingsDisplaysPage(),
      SettingsPageId.network => const SettingsNetworkPage(),
      SettingsPageId.bluetooth => const SettingsBluetoothPage(),
      SettingsPageId.developer => SettingsDeveloperPage(
        state: ref.watch(uiDevelopmentProvider),
        controller: ref.read(uiDevelopmentProvider.notifier),
        workspaceSetup: ref.watch(uiWorkspaceSetupProvider),
      ),
      SettingsPageId.about => const SettingsAboutPage(),
    };
  }

  Widget _buildColorPicker(
    ShellSettings settings,
    ShellSettingsController controller,
  ) {
    if (!_colorPickerOpen) {
      return const SizedBox.shrink(
        key: ValueKey<String>('settings-color-picker-closed'),
      );
    }
    return SettingsAccentColorPicker(
      key: settingsAccentColorPickerKey,
      color: settings.appearance.customAccentColor,
      title: context.l10n.settingsShellAccentTitle,
      routeLabel: context.l10n.settingsAccentPickerRouteLabel,
      wheelSemanticsLabel: context.l10n.settingsAccentPickerWheelLabel,
      onChanged: controller.setCustomAccentColor,
      onReset: () => controller.setCustomAccentColor(ShellColors.accent),
      onClose: () => setState(() => _colorPickerOpen = false),
    );
  }

  Future<void> _openWallpaperSelector() async {
    var displayLayout = ref.read(displayLayoutProvider);
    displayLayout ??= await ref
        .read(displayLayoutProvider.notifier)
        .ensureLoaded();
    if (!mounted) {
      return;
    }
    final fallbackPixelSize =
        MediaQuery.sizeOf(context) * MediaQuery.devicePixelRatioOf(context);
    ref
        .read(wallpaperControllerProvider.notifier)
        .openSelector(
          targetPixelSize: displayLayout?.pixelSize ?? fallbackPixelSize,
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: 96,
                height: 32,
                child: DenialWordmark(
                  alignment: Alignment.centerLeft,
                  semanticsLabel: context.l10n.settingsHeaderLogoSemanticsLabel,
                ),
              ),
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
