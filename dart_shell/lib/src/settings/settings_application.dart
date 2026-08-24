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
import 'widgets/settings_touchpad_page.dart';

final _englishSettings = AppLocalizationsEn();

@immutable
class SettingsPageOpenRequest {
  const SettingsPageOpenRequest({required this.id, required this.page});

  final int id;
  final SettingsPageId page;
}

final settingsPageOpenRequestProvider =
    NotifierProvider<
      SettingsPageOpenRequestController,
      SettingsPageOpenRequest?
    >(SettingsPageOpenRequestController.new);

/// Carries one-shot navigation requests into the single-instance Settings app.
/// The request remains pending while the native local window is being created,
/// then the mounted Settings surface consumes it after selecting the page.
class SettingsPageOpenRequestController
    extends Notifier<SettingsPageOpenRequest?> {
  var _nextId = 0;

  @override
  SettingsPageOpenRequest? build() => null;

  void request(SettingsPageId page) {
    state = SettingsPageOpenRequest(id: ++_nextId, page: page);
  }

  void consume(int id) {
    if (state?.id == id) {
      state = null;
    }
  }
}

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
  const DenialSettingsApplication({
    this.initialPage = SettingsPageId.appearance,
    this.onOpenWallpaperSelector,
    super.key,
  });

  final SettingsPageId initialPage;
  final Future<void> Function()? onOpenWallpaperSelector;

  @override
  ConsumerState<DenialSettingsApplication> createState() =>
      _DenialSettingsApplicationState();
}

class _DenialSettingsApplicationState
    extends ConsumerState<DenialSettingsApplication> {
  late SettingsPageId _page;
  var _colorPickerOpen = false;
  int? _scheduledPageRequestId;

  @override
  void initState() {
    super.initState();
    _page = widget.initialPage;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_revealPendingDisplayConfirmation());
    });
  }

  Future<void> _revealPendingDisplayConfirmation() async {
    final outputController = ref.read(outputConfigurationProvider.notifier);
    await outputController.refresh();
    if (!mounted ||
        ref
                .read(outputConfigurationProvider)
                .configuration
                ?.pendingConfirmation ==
            null) {
      return;
    }
    _selectPage(SettingsPageId.displays);
  }

  void _selectPage(SettingsPageId page) {
    if (_page == page) {
      return;
    }
    setState(() => _page = page);
  }

  @override
  Widget build(BuildContext context) {
    _scheduleRequestedPage(ref.watch(settingsPageOpenRequestProvider));
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
                    showTouchpad: true,
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
                          showTouchpad: true,
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
                            child: _SettingsPageBody(
                              page: _page,
                              onOpenAccentPicker: () =>
                                  setState(() => _colorPickerOpen = true),
                              onOpenWallpaperSelector: () =>
                                  unawaited(_openWallpaperSelector()),
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
                    child: _buildColorPicker(),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  void _scheduleRequestedPage(SettingsPageOpenRequest? request) {
    if (request == null || request.id == _scheduledPageRequestId) {
      return;
    }
    _scheduledPageRequestId = request.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          ref.read(settingsPageOpenRequestProvider)?.id != request.id) {
        return;
      }
      _selectPage(request.page);
      ref.read(settingsPageOpenRequestProvider.notifier).consume(request.id);
    });
  }

  Widget _buildColorPicker() {
    if (!_colorPickerOpen) {
      return const SizedBox.shrink(
        key: ValueKey<String>('settings-color-picker-closed'),
      );
    }
    final settings = ref.watch(
      shellSettingsProvider.select((settings) => settings.appearance),
    );
    final controller = ref.read(shellSettingsProvider.notifier);
    return SettingsAccentColorPicker(
      key: settingsAccentColorPickerKey,
      color: settings.customAccentColor,
      title: context.l10n.settingsShellAccentTitle,
      routeLabel: context.l10n.settingsAccentPickerRouteLabel,
      wheelSemanticsLabel: context.l10n.settingsAccentPickerWheelLabel,
      onChanged: controller.setCustomAccentColor,
      onReset: () => controller.setCustomAccentColor(ShellColors.accent),
      onClose: () => setState(() => _colorPickerOpen = false),
    );
  }

  Future<void> _openWallpaperSelector() async {
    final externalLauncher = widget.onOpenWallpaperSelector;
    if (externalLauncher != null) {
      await externalLauncher();
      return;
    }
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
}

class _SettingsPageBody extends ConsumerWidget {
  const _SettingsPageBody({
    required this.page,
    required this.onOpenAccentPicker,
    required this.onOpenWallpaperSelector,
  });

  final SettingsPageId page;
  final VoidCallback onOpenAccentPicker;
  final VoidCallback onOpenWallpaperSelector;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(shellSettingsProvider.notifier);
    switch (page) {
      case SettingsPageId.appearance:
        final settings = ref.watch(
          shellSettingsProvider.select((settings) => settings.appearance),
        );
        final displayLayout = ref.watch(displayLayoutProvider);
        final assignment = ref.watch(
          wallpaperControllerProvider.select((state) => state.assignment),
        );
        return SettingsAppearancePage(
          settings: settings,
          extractedAccent: ref.watch(wallpaperAccentProvider).color,
          wallpaper: _wallpaperFor(assignment, displayLayout),
          onOpenWallpaperSelector: onOpenWallpaperSelector,
          onAccentSourceChanged: controller.setAccentSource,
          onOpenAccentPicker: onOpenAccentPicker,
          onWindowRadiusChanged: controller.setWindowRadius,
          onPanelRadiusChanged: controller.setPanelRadius,
          onPanelOpacityChanged: controller.setPanelOpacity,
          onBackdropBlurEnabledChanged: controller.setBackdropBlurEnabled,
          onBackdropBlurLevelChanged: controller.setBackdropBlurLevel,
          onBackdropBlurOpacityThresholdChanged:
              controller.setBackdropBlurOpacityThreshold,
          onFocusedOpacityChanged: controller.setFocusedWindowOpacity,
          onUnfocusedOpacityChanged: controller.setUnfocusedWindowOpacity,
          onCursorSizeChanged: controller.setCursorSize,
          onReset: controller.resetAppearance,
        );
      case SettingsPageId.language:
        final settings = ref.watch(
          shellSettingsProvider.select((settings) => settings.localization),
        );
        return SettingsLanguagePage(
          settings: settings,
          onChanged: controller.setLocalePreference,
          onReset: controller.resetLocalization,
        );
      case SettingsPageId.keyboard:
        return const SettingsKeyboardPage();
      case SettingsPageId.touchpad:
        return const SettingsTouchpadPage();
      case SettingsPageId.shortcuts:
        return const SettingsShortcutsPage();
      case SettingsPageId.layout:
        final settings = ref.watch(
          shellSettingsProvider.select((settings) => settings.layout),
        );
        final displayLayout = ref.watch(displayLayoutProvider);
        return SettingsLayoutPage(
          settings: settings,
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
            ref
                .read(displayLayoutProvider.notifier)
                .previewSystemBar(side: side, monitorIds: monitorIds);
          },
          onSystemBarThicknessChanged: controller.setSystemBarThickness,
          onMaximizePaddingChanged: controller.setMaximizePadding,
          onClipboardTrayEdgeChanged: controller.setClipboardTrayEdge,
          onClipboardTrayExtentChanged: controller.setClipboardTrayExtent,
          onReset: controller.resetLayout,
        );
      case SettingsPageId.animations:
        final settings = ref.watch(
          shellSettingsProvider.select((settings) => settings.animations),
        );
        return SettingsAnimationsPage(
          settings: settings,
          onCloseEffectChanged: controller.setWindowCloseEffect,
          onDurationScaleChanged: controller.setAnimationDurationScale,
          onPanelTravelChanged: controller.setPanelTravel,
          onLockAnimationChanged: controller.setLockScreenAnimationEnabled,
          onReset: controller.resetAnimations,
        );
      case SettingsPageId.overlays:
        final settings = ref.watch(
          shellSettingsProvider.select((settings) => settings.overlays),
        );
        return SettingsOverlaysPage(
          settings: settings,
          onChanged: controller.setOverlayPlacement,
          onReset: controller.resetOverlays,
        );
      case SettingsPageId.power:
        final settings = ref.watch(
          shellSettingsProvider.select((settings) => settings.power),
        );
        return SettingsPowerPage(
          settings: settings,
          onEnabledChanged: controller.setIdleDpmsEnabled,
          onTimeoutChanged: controller.setIdleDpmsTimeoutMinutes,
          onReset: controller.resetPower,
        );
      case SettingsPageId.lockScreen:
        final settings = ref.watch(
          shellSettingsProvider.select((settings) => settings.lockScreen),
        );
        final displayLayout = ref.watch(displayLayoutProvider);
        final assignment = ref.watch(
          wallpaperControllerProvider.select((state) => state.assignment),
        );
        return SettingsLockScreenPage(
          settings: settings,
          wallpaper: _wallpaperFor(assignment, displayLayout),
          onUseWallpaperChanged: (value) =>
              controller.setLockScreen(useSystemWallpaper: value),
          onDimChanged: (value) => controller.setLockScreen(dimAmount: value),
          onBlurChanged: (value) => controller.setLockScreen(blurRadius: value),
          onClockScaleChanged: (value) =>
              controller.setLockScreen(clockScale: value),
          onShowStatusChanged: (value) =>
              controller.setLockScreen(showSystemStatus: value),
          onReset: controller.resetLockScreen,
        );
      case SettingsPageId.audio:
        return const SettingsAudioPage();
      case SettingsPageId.displays:
        return const _SettingsDisplaysBody();
      case SettingsPageId.network:
        return const SettingsNetworkPage();
      case SettingsPageId.bluetooth:
        return const SettingsBluetoothPage();
      case SettingsPageId.developer:
        return SettingsDeveloperPage(
          state: ref.watch(uiDevelopmentProvider),
          controller: ref.read(uiDevelopmentProvider.notifier),
          workspaceSetup: ref.watch(uiWorkspaceSetupProvider),
        );
      case SettingsPageId.about:
        return const SettingsAboutPage();
    }
  }
}

class _SettingsDisplaysBody extends ConsumerWidget {
  const _SettingsDisplaysBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(outputConfigurationProvider);
    final controller = ref.read(outputConfigurationProvider.notifier);
    final confirmation = state.configuration?.pendingConfirmation;
    return Stack(
      fit: StackFit.expand,
      children: [
        const SettingsDisplaysPage(),
        if (confirmation != null)
          SettingsDisplayConfirmationDialog(
            confirmation: confirmation,
            busy: state.applying,
            onKeep: () => unawaited(controller.keepChanges()),
            onRevert: () => unawaited(controller.rollbackChanges()),
            onExpired: () => unawaited(controller.refresh()),
          ),
      ],
    );
  }
}

WallpaperResource _wallpaperFor(
  WallpaperAssignment assignment,
  DisplayLayout? layout,
) {
  final outputName = layout?.mainOutput?.name;
  return outputName == null ? assignment.all : assignment.forOutput(outputName);
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
