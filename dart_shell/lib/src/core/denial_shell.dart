import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/startup_environment.dart';
import '../desktop/desktop_input_layout_publisher.dart';
import '../localization/denial_localizations.dart';
import '../settings/settings_controller.dart';
import '../state/cursor_theme.dart';
import '../state/display_layout.dart';
import '../state/screenshot_selection.dart';
import '../state/shell_controller.dart';
import '../state/shell_profile.dart';
import '../theme/cursor_themes.dart';
import '../theme/shell_color_scheme.dart';
import '../theme/shell_theme.dart';
import '../wallpaper/state/wallpaper_accent.dart';
import '../widgets/input_layout_publisher.dart';
import '../widgets/low_battery_notification_binding.dart';
import '../widgets/mobile_text_input_policy.dart';
import '../widgets/edge_panel_layer.dart';
import '../widgets/screenshot_selection_layer.dart';
import '../widgets/shell_cursor.dart';
import '../widgets/shell_surface_host.dart';
import 'shell_overlay_host.dart';
import 'shell_runtime_bindings.dart';
import 'shell_scene.dart';
import 'shell_secure_stage.dart';

const _shellDragDevices = <PointerDeviceKind>{
  PointerDeviceKind.touch,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
  PointerDeviceKind.trackpad,
  PointerDeviceKind.mouse,
  PointerDeviceKind.unknown,
};

/// The reusable Denial compositor host.
///
/// Feature authors provide a mobile and desktop [DenialShellScene]. The host
/// installs Denial's protocol lifecycle, theme, localization, cursor, input,
/// secure-session, overlay, software-keyboard, and screenshot infrastructure.
class DenialShell extends ConsumerWidget {
  const DenialShell({
    super.key,
    required this.mobile,
    required this.desktop,
    this.pairingSurfaceBuilder,
    this.onLocked,
  });

  final DenialShellScene mobile;
  final DenialShellScene desktop;
  final DenialPairingSurfaceBuilder? pairingSurfaceBuilder;
  final DenialShellEffect? onLocked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(shellProfileProvider);
    final displayLayout = ref.watch(displayLayoutProvider);
    final effectiveProfile = (displayLayout?.outputs.length ?? 0) > 1
        ? ShellProfile.desktop
        : profile;
    final presentation = ref.watch(
      shellSettingsProvider.select(
        (settings) => (
          appearance: settings.appearance,
          animationDurationScale: settings.animations.durationScale,
          locale: settings.localization.localeOverride,
        ),
      ),
    );
    final appearance = presentation.appearance;
    final startupCursorThemeId = ref
        .watch(startupEnvironmentProvider)['DENIA_CURSOR_THEME']
        ?.trim();
    final cursorTheme = resolveShellCursorTheme(
      ref.watch(availableShellCursorThemesProvider),
      startupCursorThemeId?.isNotEmpty == true
          ? startupCursorThemeId!
          : appearance.cursorThemeId,
    );
    final accent = ref.watch(
      shellAccentProvider.select((accent) => accent.color),
    );
    final colors =
        appearance.colorSchemePreference.effectiveBrightness == Brightness.light
        ? ShellColorScheme.light
        : ShellColorScheme.dark;
    final theme = ShellThemeData(
      colors: colors,
      accent: accent,
      cornerRadiusScale: appearance.cornerRadiusScale,
      panelOpacity: appearance.panelOpacity,
      cardOpacity: appearance.cardOpacity,
      backdropBlurEnabled: appearance.backdropBlurEnabled,
      backdropBlurLevel: appearance.backdropBlurLevel,
      backdropBlurOpacityThreshold: appearance.backdropBlurOpacityThreshold,
      focusedWindowBorderEnabled: appearance.focusedWindowBorderEnabled,
      focusedWindowOpacity: appearance.focusedWindowOpacity,
      unfocusedWindowOpacity: appearance.unfocusedWindowOpacity,
    );
    final bridge = ref.watch(denialBridgeProvider);
    final hideCursor = ref.watch(
      screenshotSelectionProvider.select(
        (session) => session?.hidesCursor ?? false,
      ),
    );
    final scene = _ProfileScene(
      profile: effectiveProfile,
      scene: effectiveProfile == ShellProfile.mobile ? mobile : desktop,
    );
    final content = ShellCursorHost(
      theme: effectiveProfile == ShellProfile.desktop
          ? cursorTheme
          : ShellCursorThemes.bibataModernIce,
      platformCursorShapes: bridge.cursorShapes,
      platformCursorStates: bridge.cursorStates,
      platformCursorPositions: bridge.cursorPositions,
      platformDragIcons: bridge.dragIcons,
      hideCursor: hideCursor,
      displayLayout: displayLayout,
      cursorSize: appearance.cursorSize,
      onCursorStatePresented: bridge.acknowledgeCursorPresented,
      child: ShellOverlayHost(child: scene),
    );

    return ShellRuntimeBindings(
      pairingSurfaceBuilder: pairingSurfaceBuilder,
      onLocked: onLocked,
      child: AnimatedShellTheme(
        data: theme,
        duration: Duration(
          milliseconds: (200 * presentation.animationDurationScale).round(),
        ),
        child: DenialLocalizationScope(
          locale: presentation.locale,
          child: LowBatteryNotificationBinding(
            child: _ShellEnvironment(profile: effectiveProfile, child: content),
          ),
        ),
      ),
    );
  }
}

class _ProfileScene extends StatelessWidget {
  const _ProfileScene({required this.profile, required this.scene});

  final ShellProfile profile;
  final DenialShellScene scene;

  @override
  Widget build(BuildContext context) {
    return switch (profile) {
      ShellProfile.mobile => InputLayoutPublisher(
        child: Stack(
          fit: StackFit.expand,
          children: [
            ShellSurfaceHost(
              child: ShellSecureStage(
                scene: Stack(
                  fit: StackFit.expand,
                  children: [scene.content, ...scene.overlays],
                ),
                chrome: scene.chrome,
              ),
            ),
            const MobileSystemKeyboardLayer(),
          ],
        ),
      ),
      ShellProfile.desktop => DesktopInputLayoutPublisher(
        child: ShellSecureStage(
          useConfiguredLockAnimation: true,
          scene: Stack(
            fit: StackFit.expand,
            children: [
              ShellSurfaceHost(
                child: DesktopSceneOverlayHost(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [scene.content, ...scene.overlays],
                  ),
                ),
              ),
              const ScreenshotSelectionLayer(),
            ],
          ),
        ),
      ),
    };
  }
}

class _ShellEnvironment extends StatelessWidget {
  const _ShellEnvironment({required this.profile, required this.child});

  final ShellProfile profile;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final animatedTheme = context.shellTheme;
    final textInputPolicy = TapRegionSurface(
      child: ShellDefaultTextStyle(child: child),
    );
    return MediaQuery(
      data: MediaQueryData.fromView(
        View.of(context),
      ).copyWith(platformBrightness: animatedTheme.brightness),
      child: ScrollConfiguration(
        behavior: const _ShellScrollBehavior(),
        child: profile == ShellProfile.mobile
            ? MobileTextInputPolicy(child: textInputPolicy)
            : textInputPolicy,
      ),
    );
  }
}

class _ShellScrollBehavior extends ScrollBehavior {
  const _ShellScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => _shellDragDevices;
}
