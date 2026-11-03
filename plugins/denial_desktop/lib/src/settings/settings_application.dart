import '../profile/profile_image.dart';
import 'widgets/settings_you_page.dart';

import 'package:denial_flutter_sdk/settings.dart';

import 'widgets/settings_fingerprint_page.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:denial_flutter_sdk/materials.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/applications.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/theme.dart';
import 'package:denial_flutter_sdk/wallpaper.dart';

import '../state/reference_shell_profile.dart';
import 'settings_wallpaper_status.dart';
import 'widgets/focused_border_color_picker.dart';
import 'widgets/settings_about_page.dart';
import 'widgets/settings_appearance_page.dart';
import 'widgets/settings_animations_page.dart';
import 'widgets/settings_developer_page.dart';
import 'widgets/settings_displays_page.dart';
import 'widgets/settings_environment_page.dart';
import 'widgets/settings_layout_page.dart';
import 'widgets/settings_keyboard_page.dart';
import 'widgets/settings_language_page.dart';
import 'widgets/settings_lock_screen_page.dart';
import 'widgets/settings_navigation.dart';
import 'widgets/settings_page_chrome.dart';
import 'widgets/settings_overlays_page.dart';
import 'widgets/settings_permissions_page.dart';
import 'widgets/settings_power_page.dart';
import 'widgets/settings_shortcuts_page.dart';
import 'widgets/settings_system_pages.dart';
import 'widgets/settings_touchpad_page.dart';

final settingsDesktopApplicationsProvider = FutureProvider<List<DesktopApp>>(
  (ref) => ref.watch(desktopAppsRepositoryProvider).loadApplications(),
  isAutoDispose: true,
);
const denialSettingsApplicationId = 'dev.denial.settings';

bool isDenialSettingsApplicationId(String appId) =>
    appId.trim().toLowerCase() == denialSettingsApplicationId;

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

class DenialSettingsApplication extends ConsumerStatefulWidget {
  const DenialSettingsApplication({
    this.initialPage = SettingsPageId.appearance,
    this.onOpenWallpaperSelector,
    this.onPickCursorZip,
    this.onPickProfileImage,
    super.key,
  });

  final SettingsPageId initialPage;
  final Future<void> Function()? onOpenWallpaperSelector;
  final Future<String?> Function()? onPickCursorZip;
  final ProfileImagePicker? onPickProfileImage;

  @override
  ConsumerState<DenialSettingsApplication> createState() =>
      _DenialSettingsApplicationState();
}

class _DenialSettingsApplicationState
    extends ConsumerState<DenialSettingsApplication> {
  late SettingsPageId _page;
  final _chrome = SettingsChromeController();
  var _colorPickerOpen = false;
  int? _scheduledPageRequestId;

  @override
  void initState() {
    super.initState();
    _page = widget.initialPage;
    _chrome.select(_page);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_revealPendingDisplayConfirmation());
    });
  }

  @override
  void dispose() {
    _chrome.dispose();
    super.dispose();
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
    if (_page == SettingsPageId.fingerprint) {
      ref.read(fingerprintSessionProvider).close();
    }
    _chrome.select(page);
    setState(() => _page = page);
  }

  @override
  Widget build(BuildContext context) {
    _scheduleRequestedPage(ref.watch(settingsPageOpenRequestProvider));
    final showFingerprint = ref.watch(fingerprintDeviceProvider).value ?? false;
    return Semantics(
      container: true,
      role: .main,
      label: context.l10n.settingsApplicationSemanticsLabel,
      child: Theme(
        data: context.applicationTheme.materialTheme,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compactNavigation =
                constraints.maxWidth < 800 ||
                MediaQuery.textScalerOf(context).scale(14) > 21;
            return Stack(
              fit: StackFit.expand,
              children: [
                AnimatedBuilder(
                  animation: _chrome,
                  child: DenialContentSwitcher(
                    contentKey: ValueKey<SettingsPageId>(_page),
                    duration:
                        MediaQuery.disableAnimationsOf(context) ||
                            ref.watch(
                                  shellSettingsProvider.select(
                                    (settings) =>
                                        settings.animations.durationScale,
                                  ),
                                ) ==
                                0
                        ? Duration.zero
                        : const Duration(milliseconds: 160),
                    child: SettingsChromeScope(
                      controller: _chrome,
                      page: _page,
                      child: _SettingsPageBody(
                        page: _page,
                        onOpenAccentPicker: () =>
                            setState(() => _colorPickerOpen = true),
                        onOpenWallpaperSelector: () =>
                            unawaited(_openWallpaperSelector()),
                        onPickCursorZip: widget.onPickCursorZip,
                        onPickProfileImage: widget.onPickProfileImage,
                      ),
                    ),
                  ),
                  builder: (context, content) => DenialApplicationFrame(
                    compact: compactNavigation,
                    navigation: SettingsNavigation(
                      selected: _page,
                      compact: compactNavigation,
                      showTouchpad: true,
                      showFingerprint: showFingerprint,
                      onSelected: _selectPage,
                    ),
                    toolbar: _chrome.toolbar ?? const SizedBox.shrink(),
                    footer: _chrome.footer,
                    content: content!,
                  ),
                ),
                Positioned.fill(
                  child: AnimatedSwitcher(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : Motion.cardSettle,
                    reverseDuration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : Motion.tile,
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
      onReset: () => controller.setCustomAccentColor(
        const ShellAppearanceSettings().customAccentColor,
      ),
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
    required this.onPickCursorZip,
    required this.onPickProfileImage,
  });

  final SettingsPageId page;
  final VoidCallback onOpenAccentPicker;
  final VoidCallback onOpenWallpaperSelector;
  final Future<String?> Function()? onPickCursorZip;
  final ProfileImagePicker? onPickProfileImage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(shellSettingsProvider.notifier);
    switch (page) {
      case SettingsPageId.you:
        return SettingsYouPage(onPickImage: onPickProfileImage);
      case SettingsPageId.fingerprint:
        if (!(ref.watch(fingerprintDeviceProvider).value ?? false)) {
          return const SizedBox.shrink();
        }
        return const SettingsFingerprintPage();
      case SettingsPageId.permissions:
        final applications = ref.watch(settingsDesktopApplicationsProvider);
        return SettingsPermissionsPage(
          applications: applications.asData?.value ?? const <DesktopApp>[],
        );
      case SettingsPageId.appearance:
        final settings = ref.watch(
          shellSettingsProvider.select((settings) => settings.appearance),
        );
        final displayLayout = ref.watch(displayLayoutProvider);
        final assignment = ref.watch(
          wallpaperControllerProvider.select((state) => state.assignment),
        );
        final cursorThemes = ref.watch(availableShellCursorThemesProvider);
        final cursorCatalogLoading = ref
            .watch(cursorThemeCatalogProvider)
            .isLoading;
        final fontCatalog = ref.watch(availableShellFontFamiliesProvider);
        return SettingsAppearancePage(
          settings: settings,
          extractedAccent: ref.watch(wallpaperAccentProvider).color,
          wallpaper: _wallpaperFor(assignment, displayLayout),
          wallpaperApps: ref
              .watch(settingsWallpaperStatusProvider)
              .value
              ?.appsForMonitor(displayLayout?.mainOutput?.monitorId),
          wallpaperOutputName: displayLayout?.mainOutput?.name,
          onOpenWallpaperSelector: onOpenWallpaperSelector,
          onColorSchemePreferenceChanged: controller.setColorSchemePreference,
          onAccentSourceChanged: controller.setAccentSource,
          onOpenAccentPicker: onOpenAccentPicker,
          fontFamilies: fontCatalog.value ?? const <String>[],
          fontCatalogLoading: fontCatalog.isLoading,
          onFontFamilyChanged: controller.setFontFamily,
          onCornerRadiusScaleChanged: controller.setCornerRadiusScale,
          onPanelOpacityChanged: controller.setPanelOpacity,
          onCardOpacityChanged: controller.setCardOpacity,
          onTransparencyModeChanged: controller.setTransparencyMode,
          onBackdropBlurLevelChanged: controller.setBackdropBlurLevel,
          onBackdropBlurOpacityThresholdChanged:
              controller.setBackdropBlurOpacityThreshold,
          onGlassChanged: controller.setGlassConfiguration,
          onApplicationThemingEnabledChanged:
              controller.setApplicationThemingEnabled,
          onReapplyApplicationTheming: controller.reapplyApplicationTheming,
          onFocusedWindowBorderEnabledChanged:
              controller.setFocusedWindowBorderEnabled,
          onFocusedOpacityChanged: controller.setFocusedWindowOpacity,
          onUnfocusedOpacityChanged: controller.setUnfocusedWindowOpacity,
          onCursorSizeChanged: controller.setCursorSize,
          cursorThemes: cursorThemes,
          cursorCatalogLoading: cursorCatalogLoading,
          onCursorThemeChanged: controller.setCursorThemeId,
          onAllowClientCursorSurfacesChanged:
              controller.setAllowClientCursorSurfaces,
          onImportCursorZip: onPickCursorZip == null
              ? null
              : () async {
                  final path = await onPickCursorZip!();
                  if (path == null) {
                    return null;
                  }
                  final imported = await ref
                      .read(cursorThemeCatalogProvider.notifier)
                      .importZip(path);
                  controller.setCursorThemeId(imported.id);
                  await controller.flush();
                  return imported;
                },
          onRemoveCursorTheme: (theme) async {
            if (settings.cursorThemeId == theme.id) {
              controller.setCursorThemeId(ShellCursorThemes.bibataModernIce.id);
              await controller.flush();
            }
            await ref.read(cursorThemeCatalogProvider.notifier).remove(theme);
          },
          onReset: controller.resetAppearance,
          mobile:
              ref.watch(referenceShellProfileProvider) ==
              ReferenceShellProfile.mobile,
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
        final applications = ref.watch(settingsDesktopApplicationsProvider);
        return SettingsShortcutsPage(
          applications: applications.asData?.value ?? const <DesktopApp>[],
        );
      case SettingsPageId.environment:
        final settings = ref.watch(
          shellSettingsProvider.select(
            (settings) => settings.applicationEnvironment,
          ),
        );
        final applications = ref.watch(settingsDesktopApplicationsProvider);
        return SettingsEnvironmentPage(
          settings: settings,
          applications: applications.asData?.value ?? const <DesktopApp>[],
          applicationsLoading: applications.isLoading,
          applicationsUnavailable: applications.hasError,
          onSave: (desktopFileId, previousName, name, value) {
            controller.replaceApplicationEnvironmentOverride(
              desktopFileId: desktopFileId,
              previousName: previousName,
              name: name,
              value: value,
            );
          },
          onDelete: (desktopFileId, name) {
            controller.removeApplicationEnvironmentOverride(
              name,
              desktopFileId: desktopFileId,
            );
          },
          onReset: controller.resetApplicationEnvironment,
          onResetScope: controller.resetApplicationEnvironmentScope,
        );
      case SettingsPageId.layout:
        final settings = ref.watch(
          shellSettingsProvider.select((settings) => settings.layout),
        );
        final displayLayout = ref.watch(displayLayoutProvider);
        return SettingsLayoutPage(
          settings: settings,
          displayLayout: displayLayout,
          onWindowLayoutChanged: controller.setDesktopWindowLayout,
          onScrollingLayoutPreserveSwapSizesChanged:
              controller.setScrollingLayoutPreserveSwapSizes,
          onScrollingLayoutWheelSpeedChanged:
              controller.setScrollingLayoutWheelSpeed,
          onScrollingLayoutWheelUpDirectionChanged:
              controller.setScrollingLayoutWheelUpDirection,
          onWorkspacesEnabledChanged: controller.setWorkspacesEnabled,
          onWorkspaceCountChanged: controller.setWorkspaceCount,
          onWorkspaceSwitchingOrientationChanged:
              controller.setWorkspaceSwitchingOrientation,
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
          onMinimizedWindowPlacementChanged:
              controller.setMinimizedWindowPlacement,
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
          onLockEnabledChanged: controller.setIdleLockEnabled,
          onLockTimeoutChanged: controller.setIdleLockTimeoutSeconds,
          onDpmsEnabledChanged: controller.setIdleDpmsEnabled,
          onDpmsTimeoutChanged: controller.setIdleDpmsTimeoutSeconds,
          onSuspendEnabledChanged: controller.setIdleSuspendEnabled,
          onSuspendTimeoutChanged: controller.setIdleSuspendTimeoutSeconds,
          onSuspendModeChanged: controller.setSuspendMode,
          onPowerButtonActionChanged: controller.setPowerButtonAction,
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
            onExpired: () => unawaited(
              controller.refreshAfterConfirmationExpiry(confirmation.token),
            ),
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
