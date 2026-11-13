import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_desktop/src/state/reference_shell_profile.dart';
import 'package:denial_desktop/src/state/reference_shell_presentation.dart';

import 'package:denial_flutter_sdk/popups.dart';
import 'package:denial_flutter_sdk/surfaces.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/environment.dart';
import 'package:denial_flutter_sdk/input.dart';

import '../desktop/desktop_input_layout_publisher.dart';
import '../diagnostics/desktop_benchmark_binding.dart';
import '../desktop/desktop_pet_holds.dart';
import '../features/mobile/mobile_system_overlay_layer.dart';
import '../state/phone_desk.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/theme.dart';
import 'package:denial_flutter_sdk/wallpaper.dart';

import '../widgets/fingerprint_mark.dart';
import '../widgets/input_layout_publisher.dart';
import '../widgets/mobile_screenshot_flash.dart';
import '../widgets/mobile_volume_hud.dart';
import '../widgets/low_battery_notification_binding.dart';

import 'package:denial_flutter_sdk/rendering.dart';

import '../widgets/edge_panel_layer.dart';
import '../widgets/input_deck/input_deck_layer.dart';
import '../widgets/screenshot_selection_layer.dart';

import 'package:denial_flutter_sdk/shell.dart';

import 'shell_runtime_bindings.dart';
import 'shell_secure_stage.dart';
import '../features/setup/first_user_setup_layer.dart';
import '../widgets/lock/lock_screen_layer.dart';

const _shellDragDevices = <PointerDeviceKind>{
  PointerDeviceKind.touch,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
  PointerDeviceKind.trackpad,
  PointerDeviceKind.mouse,
  PointerDeviceKind.unknown,
};

/// The reference plugin's root presentation assembly.
///
/// This plugin supplies mobile and desktop [DenialShellScene] trees. It
/// installs Denial's protocol lifecycle, theme, localization, cursor, input,
/// secure-session, overlay, software-keyboard, and screenshot infrastructure.
class DenialShell extends ConsumerWidget {
  const DenialShell({
    super.key,
    required this.mobile,
    required this.desktop,
    this.pairingSurfaceBuilder,
    this.onLocked,
    this.desktopWorkArea,
  });

  final DenialShellScene mobile;
  final DenialShellScene desktop;
  final DenialPairingSurfaceBuilder? pairingSurfaceBuilder;
  final DenialShellEffect? onLocked;
  final ShellWorkArea? desktopWorkArea;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(referenceShellProfileProvider);
    final displayLayout = ref.watch(displayLayoutProvider);
    // A phone with a monitor keeps the mobile shell on its panel and runs the
    // desktop shell on the monitor. Several outputs without a built-in panel
    // run the desktop shell on all of them.
    final split = ref.watch(phoneDeskProvider);
    final forceDesktop =
        split == null && (displayLayout?.outputs.length ?? 0) > 1;
    final effectiveProfile = forceDesktop
        ? ReferenceShellProfile.desktop
        : profile;
    final selectedPresentation = ref.watch(referenceShellPresentationProvider);
    final effectivePresentation = forceDesktop
        ? ReferenceShellProfile.desktop
        : selectedPresentation;
    final presentation = ref.watch(
      shellSettingsProvider.select(
        (settings) => (
          appearance: settings.appearance,
          animationDurationScale: settings.animations.durationScale,
          locale: settings.localization.localeOverride,
          twentyFourHourClock: settings.localization.twentyFourHourClock,
        ),
      ),
    );
    final appearance = presentation.appearance;
    final startupCursorThemeId = ref
        .watch(startupEnvironmentProvider)['DENIAL_CURSOR_THEME']
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
    final light = appearance.transparencyMode == ShellTransparencyMode.glass
        ? appearance.glass.appearance == ShellGlassAppearance.light
        : appearance.colorSchemePreference.effectiveBrightness ==
              Brightness.light;
    final colors = light ? ShellColorScheme.light : ShellColorScheme.dark;
    final theme = ShellThemeData(
      colors: colors,
      accent: accent,
      fontFamily: appearance.fontFamily,
      cornerRadiusScale: appearance.cornerRadiusScale,
      panelOpacity: appearance.panelOpacity,
      cardOpacity: appearance.cardOpacity,
      transparencyMode: appearance.transparencyMode,
      backdropBlurLevel: appearance.backdropBlurLevel,
      backdropBlurOpacityThreshold: appearance.backdropBlurOpacityThreshold,
      glass: appearance.glass,
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
    final scene = effectivePresentation == ReferenceShellProfile.mobile
        ? _PhoneDeskScene(
            split: split,
            policyProfile: effectiveProfile,
            mobile: mobile,
            desktop: desktop,
          )
        : _ProfileScene(
            profile: effectivePresentation,
            policyProfile: effectiveProfile,
            scene: desktop,
          );
    final fingerprint = ref.watch(fingerprintSceneProvider);
    final locked = ref.watch(
      referenceShellProvider.select((state) => state.locked),
    );
    final content = FingerprintStage(
      scene: fingerprint,
      locked: locked,
      onLaidOut: ref.read(fingerprintSceneProvider.notifier).laidOut,
      child: ShellCursorHost(
        theme:
            effectivePresentation == ReferenceShellProfile.desktop ||
                split != null
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
        benchmarkSocket: ref.watch(
          startupEnvironmentProvider,
        )['DENIAL_CURSOR_BENCHMARK_SOCKET'],
        child: ShellOverlayHost(child: scene),
      ),
    );

    return ShellRuntimeBindings(
      mobilePresentation: effectivePresentation == ReferenceShellProfile.mobile,
      deskBeside: split != null,
      workArea:
          effectivePresentation == ReferenceShellProfile.desktop ||
              split != null
          ? desktopWorkArea
          : null,
      pairingSurfaceBuilder: pairingSurfaceBuilder,
      onLocked: onLocked,
      child: AnimatedShellTheme(
        data: theme,
        duration: Duration(
          milliseconds: (200 * presentation.animationDurationScale).round(),
        ),
        child: DenialLocalizationScope(
          locale: presentation.locale,
          twentyFourHourClock: presentation.twentyFourHourClock,
          child: LowBatteryNotificationBinding(
            child: _ShellEnvironment(
              profile: effectivePresentation,
              child: DesktopBenchmarkBinding(child: content),
            ),
          ),
        ),
      ),
    );
  }
}

/// The mobile presentation: the mobile shell on the phone's panel and, while
/// a monitor is plugged in, the desktop shell on the monitor beneath it. The
/// phone's part keeps its place in the tree, so plugging a monitor in or out
/// leaves the phone's state alone.
class _PhoneDeskScene extends ConsumerWidget {
  const _PhoneDeskScene({
    required this.split,
    required this.policyProfile,
    required this.mobile,
    required this.desktop,
  });

  final PhoneDeskLayout? split;
  final ReferenceShellProfile policyProfile;
  final DenialShellScene mobile;
  final DenialShellScene desktop;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final split = this.split;
    final active = ref.read(activeShellPartProvider.notifier);
    final monitorCornerRadiusScale = ref.watch(
      shellSettingsProvider.select(
        (settings) => settings.appearance.monitorCornerRadiusScale,
      ),
    );
    Widget part(ShellPart part, Widget child) => Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => active.note(part),
      child: ShellPartScope(part: part, child: child),
    );
    final phoneRect = split?.phoneRect;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (split != null)
          KeyedSubtree(
            key: const ValueKey(ShellPart.desk),
            child: part(
              ShellPart.desk,
              // The desk keeps its own corners; the phone's are tuned for the
              // mobile shell.
              ShellTheme(
                data: ShellTheme.of(context)
                    .copyWith(cornerRadiusScale: monitorCornerRadiusScale),
                child: _ProfileScene(
                  profile: ReferenceShellProfile.desktop,
                  policyProfile: policyProfile,
                  scene: desktop,
                  besidePhone: true,
                ),
              ),
            ),
          ),
        Positioned.fromRect(
          key: const ValueKey(ShellPart.phone),
          rect: phoneRect ?? Offset.zero & MediaQuery.sizeOf(context),
          // Beside a desk, what the phone draws past its edges (recents
          // cards, apps sliding in and out) must not land on the desk.
          child: ClipRect(
            clipBehavior: split == null ? Clip.none : Clip.hardEdge,
            child: part(
              split == null ? ShellPart.whole : ShellPart.phone,
              // Nor does its input: a full-scene capture on the phone, such
              // as its dark always-on picture, leaves the desk its pointer.
              ShellInputClip(
                bounds: phoneRect,
                child: MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    size: phoneRect?.size ?? MediaQuery.sizeOf(context),
                  ),
                  child: _ProfileScene(
                    profile: ReferenceShellProfile.mobile,
                    policyProfile: policyProfile,
                    scene: mobile,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ProfileScene extends StatelessWidget {
  const _ProfileScene({
    required this.profile,
    required this.policyProfile,
    required this.scene,
    this.besidePhone = false,
  });

  final ReferenceShellProfile profile;
  final ReferenceShellProfile policyProfile;
  final DenialShellScene scene;

  /// The desktop shell runs on a monitor beside the phone, which owns the
  /// software keyboard.
  final bool besidePhone;

  @override
  Widget build(BuildContext context) {
    return switch (profile) {
      ReferenceShellProfile.mobile => InputLayoutPublisher(
        child: Stack(
          fit: StackFit.expand,
          children: [
            ShellPopupHost(
              child: ShellSecureStage(
                useConfiguredLockAnimation:
                    policyProfile == ReferenceShellProfile.desktop,
                scene: Stack(
                  fit: StackFit.expand,
                  children: [scene.content, ...scene.overlays],
                ),
                chrome: scene.chrome,
              ),
            ),
            const MobileSystemOverlayLayer(),
            // Before the device has a person's account, setup covers all of
            // the above; the keyboard stays over it.
            const FirstUserSetupLayer(),
            const SystemKeyboardLayer(hints: true),
            // Over everything on the phone, like the lock screen it comes
            // from.
            const UnlockedAmbientDisplay(),
            // The fingerprint sensor, for the lock screen, the ambient
            // display and applications alike.
            const FingerprintMark(),
            // Volume shows over the lock screen too, as on any phone.
            const MobileVolumeHud(),
            // Above everything, the lock screen included.
            const MobileScreenshotFlash(),
          ],
        ),
      ),
      ReferenceShellProfile.desktop => DesktopInputLayoutPublisher(
        // The startup profile controls automatic pop-up, not access to the
        // manual edge gesture. Desktop-first touch devices need it too.
        softwareKeyboardEnabled: !besidePhone,
        child: DesktopPetHoldPublisher(
          child: Stack(
            fit: StackFit.expand,
            children: [
              ShellSecureStage(
                useConfiguredLockAnimation:
                    policyProfile == ReferenceShellProfile.desktop,
                scene: Stack(
                  fit: StackFit.expand,
                  children: [
                    ShellPopupHost(
                      // Keep desktop feature popups inside the scene's paint plane.
                      // The screenshot selection layer remains above this overlay,
                      // so its frozen texture includes open menus while its controls
                      // paint and receive input above them.
                      child: ShellOverlayHost(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [scene.content, ...scene.overlays],
                        ),
                      ),
                    ),
                    const InputDeckLayer(),
                    const ScreenshotSelectionLayer(),
                  ],
                ),
              ),
              if (!besidePhone) const FirstUserSetupLayer(),
              if (!besidePhone) const SystemKeyboardLayer(),
            ],
          ),
        ),
      ),
    };
  }
}

class _ShellEnvironment extends StatelessWidget {
  const _ShellEnvironment({required this.profile, required this.child});

  final ReferenceShellProfile profile;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final animatedTheme = context.shellTheme;
    final textInputPolicy = TapRegionSurface(
      child: ShellDefaultTextStyle(child: child),
    );
    return MediaQuery(
      data: MediaQueryData.fromView(View.of(context))
          .copyWith(platformBrightness: animatedTheme.brightness),
      child: ScrollConfiguration(
        behavior: const _ShellScrollBehavior(),
        child: profile == ReferenceShellProfile.mobile
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
