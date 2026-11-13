import 'package:denial_desktop/src/state/reference_shell_metrics.dart';
import 'package:denial_desktop/src/state/reference_shell_presentation.dart';
import 'package:denial_desktop/src/state/reference_shell_profile.dart';

import 'dart:async' show StreamSubscription, Timer;
import 'dart:convert' show jsonDecode;
import 'dart:io' show File;
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui' show ImageFilter, TileMode;

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart'
    show GestureDisposition, PointerEvent, PointerUpEvent, TapGestureRecognizer;
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/applications.dart';

import '../../launcher/widgets/home_tiles.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/platform.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/system_services.dart'
    show
        HapticsService,
        MobileNetworkSnapshot,
        hapticsServiceProvider,
        mobileNetworkProvider,
        mobileNetworkServiceProvider;
import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/tokens.dart';
import 'package:denial_flutter_sdk/wallpaper.dart'
    show
        WallpaperResourceKind,
        wallpaperControllerProvider,
        wallpaperDepthDirectory,
        wallpaperDepthProvider;

import '../../state/notification_groups.dart';
import '../edge_panel_layer.dart';
import '../fingerprint_mark.dart';
import '../mobile_ui_metrics.dart';
import '../notification_banner.dart';

import 'package:denial_flutter_sdk/rendering.dart';

import '../shade/status_glyphs.dart';

import 'sim_pin_lock.dart';
import '../../state/phone_desk.dart';
import '../../state/reference_shell_controller.dart';

part 'lock_authentication_panels.dart';
part 'lock_pin_stage.dart';
part 'lock_screen_background.dart';
part 'lock_screen_pane.dart';
part 'user_verification_sheet.dart';

/// The lock screen's always-on picture on the phone while the session stays
/// unlocked: beside a desk the phone goes dark without locking. It stays
/// built, hidden, while the phone is unlocked beside a desk, so the wallpaper
/// and its subject are ready before the picture fades in.
class UnlockedAmbientDisplay extends ConsumerWidget {
  const UnlockedAmbientDisplay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locked = ref.watch(
      referenceShellProvider.select((state) => state.locked),
    );
    // A locked session shows the always-on picture on its lock screen, and
    // without a desk the phone always locks before it goes dark.
    if (locked || ShellPart.of(context) != ShellPart.phone) {
      return const SizedBox.shrink();
    }
    return const LockScreenLayer(
      unlockProgress: kAlwaysDismissedAnimation,
      animateDesktopEntrance: false,
      ambientOnly: true,
    );
  }
}

class LockScreenLayer extends ConsumerStatefulWidget {
  const LockScreenLayer({
    super.key,
    required this.unlockProgress,
    this.animateDesktopEntrance = true,
    this.ambientOnly = false,
  });

  /// Transition progress is intentionally a listenable rather than a scalar.
  /// Gesture handlers need its current value, but the lock-screen subtree does
  /// not need to rebuild for each transition tick.
  final Animation<double> unlockProgress;
  final bool animateDesktopEntrance;

  /// Only the always-on picture, over an unlocked phone: hidden until the
  /// phone goes dark, then it fades in whole, already dark, and has no
  /// authentication, gestures or keyboard.
  final bool ambientOnly;

  @override
  ConsumerState<LockScreenLayer> createState() => _LockScreenLayerState();
}

class _LockScreenLayerState extends ConsumerState<LockScreenLayer>
    with TickerProviderStateMixin {
  late final AnimationController _entrance;

  /// 1 while the panel keeps only the always-on picture lit: the wallpaper
  /// darkens under the face, and the face keeps the time, the date, the
  /// wallpaper's subject and the fingerprint mark.
  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  )..addStatusListener(_ambientStatusChanged);

  /// The [LockScreenLayer.ambientOnly] picture's fade over the phone.
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  )..addStatusListener(_revealStatusChanged);

  /// Whether the [LockScreenLayer.ambientOnly] picture shows at all.
  bool _revealed = false;

  /// Whether any of the always-on look shows, for the parts drawn only then.
  bool _ambientShown = false;
  StreamSubscription<bool>? _ambientChanges;

  /// The lock backdrop frosted once: the PIN keys draw their glass from it,
  /// so the glass fades in with the keys instead of appearing at the end.
  final _glass = FrostedBackdropCapture(
    frame: GlobalKey(debugLabel: 'lock scene'),
  );

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
    );
    if (widget.animateDesktopEntrance) {
      _entrance.forward();
    }
    // The ambient-only picture is always dark, with its subject's halo.
    if (widget.ambientOnly) {
      _ambientShown = true;
      _ambient.value = 1.0;
    }
    final bridge = ref.read(denialBridgeProvider);
    _ambientChanges = bridge.ambientDisplay.listen(_ambientChanged);
    // deniald locks before it asks: the request can come before this layer.
    if (bridge.ambientDisplayActive) {
      // Shown before the controller says so: no setState in initState.
      _ambientShown = true;
      _revealed = widget.ambientOnly;
      _ambientChanged(true);
    }
  }

  void _ambientStatusChanged(AnimationStatus status) {
    final shown = status != AnimationStatus.dismissed;
    if (shown != _ambientShown) {
      setState(() => _ambientShown = shown);
    }
  }

  void _revealStatusChanged(AnimationStatus status) {
    final revealed = status != AnimationStatus.dismissed;
    if (revealed != _revealed) {
      setState(() => _revealed = revealed);
    }
  }

  /// deniald turns the output off once the picture is on screen, and lights
  /// it again before it asks for the rest back.
  void _ambientChanged(bool active) {
    final fade = widget.ambientOnly ? _reveal : _ambient;
    if (!active) {
      fade.animateBack(0.0, curve: Curves.easeOutCubic);
      return;
    }
    fade.animateTo(1.0, curve: Curves.easeInOutCubic).then((_) async {
      // The last fade frame is drawn at the end of this one and handed to
      // the display by the next.
      await SchedulerBinding.instance.endOfFrame;
      await SchedulerBinding.instance.endOfFrame;
      final bridge = ref.read(denialBridgeProvider);
      if (mounted && fade.value == 1.0 && bridge.ambientDisplayActive) {
        bridge.ambientDisplayReady();
      }
    });
  }

  @override
  void didUpdateWidget(covariant LockScreenLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.animateDesktopEntrance && widget.animateDesktopEntrance) {
      _entrance.forward(from: 0.0);
    } else if (oldWidget.animateDesktopEntrance &&
        !widget.animateDesktopEntrance) {
      _entrance.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _glass.configure(
      theme: context.shellTheme,
      pixelRatio: math.min(MediaQuery.devicePixelRatioOf(context), 1),
    );
  }

  @override
  void dispose() {
    _ambientChanges?.cancel();
    _ambient.dispose();
    _reveal.dispose();
    _entrance.dispose();
    _glass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final layout = ref.watch(sceneDisplayLayoutProvider(ShellPart.of(context)));
    // The shell as shown: a tablet in desktop view locks like a desktop.
    final shellProfile = ref.watch(referenceShellPresentationProvider);
    final animateEntrance = ref.watch(
      shellSettingsProvider.select(
        (settings) => settings.animations.animateLockScreen,
      ),
    );
    final ambientOnly = widget.ambientOnly;
    return ShellInputRegion(
      debugLabel: ambientOnly
          ? 'unlocked always-on display'
          : 'secure lock screen',
      pointerPolicy: ambientOnly && !_revealed
          ? ShellPointerPolicy.none
          : ShellPointerPolicy.fullScene,
      keyboardPolicy: ambientOnly
          ? ShellKeyboardPolicy.none
          : ShellKeyboardPolicy.capture,
      // Only the phone goes dark: the desk keeps its windows.
      compositorPolicy: ambientOnly
          ? ShellCompositorPolicy.normal
          : ShellCompositorPolicy.exclusive,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final canvas = Offset.zero & constraints.biggest;
          final outputs = (layout?.outputs ?? [])
              .map(
                (output) => (
                  output: output,
                  rect: output.logicalRect.intersect(canvas),
                ),
              )
              .where((entry) => !entry.rect.isEmpty)
              .toList(growable: false);
          // A phone or tablet keeps its own face, with the PIN pad, in
          // either orientation; a desk or a second screen gets the desktop's.
          final desktop =
              shellProfile == ReferenceShellProfile.desktop ||
              outputs.length > 1;
          late final Widget scene;
          if (outputs.length <= 1) {
            scene = ValueListenableBuilder<FrostedBackdrop?>(
              valueListenable: _glass,
              builder: (context, backdrop, scene) => WindowBackdropCache(
                backdrop: backdrop,
                motion: const AlwaysStoppedAnimation<double>(0),
                child: scene!,
              ),
              child: Stack(
                key: _glass.frame,
                fit: StackFit.expand,
                children: [
                  _LockBackdrop(onPainted: desktop ? null : _glass.painted),
                  if (!desktop)
                    CustomPaint(painter: _AmbientVeilPainter(_ambient)),
                  // The scene comes back through the veil near the subject's
                  // outline, so the cut meets light rather than black. It is
                  // laid out while hidden, so its mask is ready when the veil
                  // falls.
                  if (!desktop)
                    Offstage(
                      offstage: !_ambientShown,
                      child: const _LockDepthForeground(
                        spread: _ambientHaloSpread,
                      ),
                    ),
                  _LockScreenPane(
                    unlockProgress: widget.unlockProgress,
                    authenticationEnabled: !ambientOnly,
                    ambientOnly: ambientOnly,
                    desktop: desktop,
                    ambient: desktop ? kAlwaysDismissedAnimation : _ambient,
                  ),
                ],
              ),
            );
          } else {
            final authenticationMonitorId = layout?.mainOutput?.monitorId;
            final hasAtlasGaps = layout?.hasAtlasGaps ?? false;
            scene = Stack(
              fit: StackFit.expand,
              children: [
                if (!hasAtlasGaps)
                  CustomPaint(
                    painter: _LockFillPainter(
                      color: context.shellColors.background,
                    ),
                  ),
                for (final entry in outputs)
                  Positioned.fromRect(
                    rect: entry.rect,
                    child: ClipRect(
                      key: ValueKey<String>(
                        'lock-output-clip-${entry.output.monitorId}',
                      ),
                      child: MediaQuery(
                        data: MediaQuery.of(context).copyWith(
                          size: entry.rect.size,
                          padding: EdgeInsets.zero,
                          viewPadding: EdgeInsets.zero,
                        ),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            _LockBackdrop(output: entry.output),
                            _LockScreenPane(
                              key: ValueKey<int>(entry.output.monitorId),
                              unlockProgress: widget.unlockProgress,
                              authenticationEnabled:
                                  entry.output.monitorId ==
                                  authenticationMonitorId,
                              desktop: true,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            );
          }
          if (ambientOnly) {
            // Hidden, it is laid out and keeps its images, but neither
            // paints, animates nor takes touches.
            return IgnorePointer(
              ignoring: !_revealed,
              child: TickerMode(
                enabled: _revealed,
                child: FadeSnapshot(opacity: _reveal, child: scene),
              ),
            );
          }
          if (!widget.animateDesktopEntrance ||
              !desktop ||
              !animateEntrance ||
              MediaQuery.disableAnimationsOf(context)) {
            return scene;
          }
          return _DesktopLockEntrance(animation: _entrance, child: scene);
        },
      ),
    );
  }
}

/// How far the scene stays lit around the subject in the always-on picture.
const double _ambientHaloSpread = 56.0;

/// Black over the lock wallpaper while the panel goes to the always-on
/// picture: the scene stays faintly behind the brighter subject.
class _AmbientVeilPainter extends CustomPainter {
  _AmbientVeilPainter(this.ambient) : super(repaint: ambient);

  final Animation<double> ambient;

  /// How much of the wallpaper's light the veil takes.
  static const double _depth = 0.72;

  @override
  void paint(Canvas canvas, Size size) {
    final alpha = ambient.value * _depth;
    if (alpha <= 0.0) {
      return;
    }
    // Round-rect geometry, as in _LockFillPainter.
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(0.01)),
      Paint()..color = const Color(0xFF000000).withValues(alpha: alpha),
    );
  }

  @override
  bool shouldRepaint(covariant _AmbientVeilPainter oldDelegate) =>
      oldDelegate.ambient != ambient;
}

/// Darkness rising from the bottom over the always-on picture: the subject
/// and the scene behind it, lit beside the clock, melt into the black below
/// instead of ending at the screen's edge.
class _AmbientFalloffPainter extends CustomPainter {
  _AmbientFalloffPainter({required this.ambient, required this.clockScale})
    : super(repaint: ambient);

  final Animation<double> ambient;
  final double clockScale;

  @override
  void paint(Canvas canvas, Size size) {
    final alpha = ambient.value;
    if (alpha <= 0.0) {
      return;
    }
    // The clock's lower edge, as _LockClockBlock lays it out.
    final clockTop = math.max(48.0, size.height * 0.25 - 96.0);
    final clockHeight = math.min(250.0, size.height * 0.34);
    final clockBottom = clockTop + clockHeight * (1.0 + clockScale) / 2;
    final start = (clockBottom / size.height).clamp(0.0, 1.0);
    final end = math.max(start, 0.85);
    const black = Color(0xFF000000);
    // Round-rect geometry, as in _LockFillPainter.
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(0.01)),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(0, size.height),
          [
            for (final shade in const [0.0, 0.0, 0.2, 0.55, 0.85, 1.0, 1.0])
              black.withValues(alpha: shade * alpha),
          ],
          [
            0.0,
            start,
            start + (end - start) * 0.25,
            start + (end - start) * 0.5,
            start + (end - start) * 0.75,
            end,
            1.0,
          ],
        ),
    );
  }

  @override
  bool shouldRepaint(covariant _AmbientFalloffPainter oldDelegate) =>
      oldDelegate.ambient != ambient || oldDelegate.clockScale != clockScale;
}
