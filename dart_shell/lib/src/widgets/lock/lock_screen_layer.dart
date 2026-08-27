import 'dart:math' as math;
import 'dart:ui' show ImageFilter, TileMode;

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../input/shell_interaction_registry.dart';
import '../../launcher/models/home_clock_info.dart';
import '../../launcher/widgets/home_tiles.dart';
import '../../localization/denial_localizations.dart';
import '../../models/display_layout.dart';
import '../../models/shell_power_status.dart';
import '../../platform/authentication_protocol.dart';
import '../../settings/settings_controller.dart';
import '../../state/authentication.dart';
import '../../state/display_layout.dart';
import '../../state/shell_profile.dart';
import '../../state/system_status.dart';
import '../../theme/motion.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import '../edge_panel_layer.dart';
import '../shell_wallpaper.dart';
import '../shade/status_glyphs.dart';

part 'lock_authentication_panels.dart';
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
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance;

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
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final layout = ref.watch(displayLayoutProvider);
    final shellProfile = ref.watch(shellProfileProvider);
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
              shellProfile == ShellProfile.desktop ||
              canvas.width >= 900 ||
              outputs.length > 1;
          late final Widget scene;
          if (outputs.length <= 1) {
            scene = Stack(
              fit: StackFit.expand,
              children: [
                const _LockBackdrop(),
                _LockScreenPane(
                  unlockProgress: widget.unlockProgress,
                  authenticationEnabled: true,
                  desktop: desktop,
                ),
              ],
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
