import 'package:denial_desktop/src/state/reference_shell_metrics.dart';
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
import '../mobile_ui_metrics.dart';
import '../notification_banner.dart';

import 'package:denial_flutter_sdk/rendering.dart';

import '../shade/status_glyphs.dart';

import 'sim_pin_lock.dart';

part 'lock_authentication_panels.dart';
part 'lock_pin_stage.dart';
part 'lock_screen_background.dart';
part 'lock_screen_pane.dart';

class LockScreenLayer extends ConsumerStatefulWidget {
  const LockScreenLayer({
    super.key,
    required this.unlockProgress,
    this.animateDesktopEntrance = true,
  });

  /// Transition progress is intentionally a listenable rather than a scalar.
  /// Gesture handlers need its current value, but the lock-screen subtree does
  /// not need to rebuild for each transition tick.
  final Animation<double> unlockProgress;
  final bool animateDesktopEntrance;

  @override
  ConsumerState<LockScreenLayer> createState() => _LockScreenLayerState();
}

class _LockScreenLayerState extends ConsumerState<LockScreenLayer>
    with TickerProviderStateMixin {
  late final AnimationController _entrance;

  /// 1 while the panel keeps only the always-on picture lit: the wallpaper
  /// fades to black under the face, and the face keeps the time, the date,
  /// the wallpaper's subject and the fingerprint mark.
  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
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
    final bridge = ref.read(denialBridgeProvider);
    _ambientChanges = bridge.ambientDisplay.listen(_ambientChanged);
    // deniald locks before it asks: the request can come before this layer.
    if (bridge.ambientDisplayActive) {
      _ambientChanged(true);
    }
  }

  /// deniald turns the output off once the picture is on screen, and lights
  /// it again before it asks for the rest back.
  void _ambientChanged(bool active) {
    if (!active) {
      _ambient.animateBack(0.0, curve: Curves.easeOutCubic);
      return;
    }
    _ambient.animateTo(1.0, curve: Curves.easeInOutCubic).then((_) async {
      // The last fade frame is drawn at the end of this one and handed to
      // the display by the next.
      await SchedulerBinding.instance.endOfFrame;
      await SchedulerBinding.instance.endOfFrame;
      final bridge = ref.read(denialBridgeProvider);
      if (mounted && _ambient.value == 1.0 && bridge.ambientDisplayActive) {
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
    _entrance.dispose();
    _glass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final layout = ref.watch(displayLayoutProvider);
    final shellProfile = ref.watch(referenceShellProfileProvider);
    final animateEntrance = ref.watch(
      shellSettingsProvider.select(
        (settings) => settings.animations.animateLockScreen,
      ),
    );
    return ShellInputRegion(
      debugLabel: 'secure lock screen',
      pointerPolicy: ShellPointerPolicy.fullScene,
      keyboardPolicy: ShellKeyboardPolicy.capture,
      compositorPolicy: ShellCompositorPolicy.exclusive,
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
          final desktop =
              shellProfile == ReferenceShellProfile.desktop ||
              canvas.width >= 900 ||
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
                  _LockScreenPane(
                    unlockProgress: widget.unlockProgress,
                    authenticationEnabled: true,
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

/// Pure black over the lock wallpaper while the panel goes to the always-on
/// picture: the panel's dark pixels stay off.
class _AmbientVeilPainter extends CustomPainter {
  _AmbientVeilPainter(this.ambient) : super(repaint: ambient);

  final Animation<double> ambient;

  @override
  void paint(Canvas canvas, Size size) {
    final alpha = ambient.value;
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
