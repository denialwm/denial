import 'dart:math' as math;

import 'package:flutter/material.dart' show IconData, Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/display_layout.dart';
import '../state/display_layout.dart';
import '../state/system_level_hud.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';

class SystemLevelHudLayer extends ConsumerWidget {
  const SystemLevelHudLayer({super.key});

  static const double _height = 74;
  static const double _bottomInset = 28;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = ref.watch(systemLevelHudProvider);
    final output = _outputFor(ref.watch(displayLayoutProvider), hud);
    if (hud == null || output == null) {
      return const SizedBox.shrink();
    }

    final width = math
        .min(380.0, math.max(220.0, output.logicalRect.width - 32))
        .toDouble();
    final left =
        output.logicalRect.left + (output.logicalRect.width - width) / 2;
    final top = output.logicalRect.bottom - _bottomInset - _height;
    final isBrightness = hud.kind == SystemLevelHudKind.brightness;

    return Positioned(
      left: left,
      top: top,
      width: width,
      height: _height,
      child: IgnorePointer(
        child: _SystemLevelHudCard(
          level: hud.level,
          visible: hud.visible,
          icon: isBrightness
              ? Icons.brightness_6_rounded
              : _volumeIcon(hud.level),
          title: isBrightness ? 'Brightness' : 'Volume',
          detail: isBrightness ? output.name : null,
          semanticLabel: isBrightness
              ? '${output.name} brightness'
              : 'Output volume',
          inactiveColor: isBrightness
              ? ShellColors.brightnessTrack
              : ShellColors.volumeTrack,
        ),
      ),
    );
  }

  DisplayOutput? _outputFor(DisplayLayout? layout, SystemLevelHudState? hud) {
    if (layout == null || hud == null) {
      return null;
    }
    if (hud.kind == SystemLevelHudKind.audio) {
      return layout.mainOutput;
    }
    for (final output in layout.outputs) {
      if (output.monitorId == hud.monitorId) {
        return output;
      }
    }
    return null;
  }

  IconData _volumeIcon(double level) {
    if (level <= 0.01) {
      return Icons.volume_off_rounded;
    }
    if (level < 0.5) {
      return Icons.volume_down_rounded;
    }
    return Icons.volume_up_rounded;
  }
}

class _SystemLevelHudCard extends StatelessWidget {
  const _SystemLevelHudCard({
    required this.level,
    required this.visible,
    required this.icon,
    required this.title,
    required this.semanticLabel,
    required this.inactiveColor,
    this.detail,
  });

  final double level;
  final bool visible;
  final IconData icon;
  final String title;
  final String? detail;
  final String semanticLabel;
  final Color inactiveColor;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final duration = reduceMotion ? Duration.zero : Motion.systemLevelHud;
    final percent = (level * 100).round();

    return AnimatedSlide(
      duration: duration,
      curve: Motion.md3Emphasized,
      offset: visible ? Offset.zero : const Offset(0, 0.22),
      child: AnimatedOpacity(
        duration: duration,
        curve: visible
            ? Motion.md3EmphasizedDecelerate
            : Motion.md3EmphasizedAccelerate,
        opacity: visible ? 1 : 0,
        child: Semantics(
          container: true,
          role: .status,
          hidden: !visible,
          label: semanticLabel,
          value: '$percent percent',
          child: RepaintBoundary(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    ShellColors.panelBackground,
                    ShellColors.panelBackgroundBottom,
                  ],
                ),
                borderRadius: BorderRadius.circular(ShellRadii.panel),
                border: Border.all(color: ShellColors.hairline),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: ShellColors.shadow,
                    blurRadius: 22,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Row(
                  children: [
                    Icon(icon, size: 22, color: ShellColors.accent),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Text(title, style: ShellText.cardTitle),
                              const SizedBox(width: 8),
                              if (detail case final detail?)
                                Expanded(
                                  child: Text(
                                    detail,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: ShellText.base.copyWith(
                                      color: ShellColors.textTertiary,
                                      fontSize: 11,
                                    ),
                                  ),
                                )
                              else
                                const Spacer(),
                              Text(
                                '$percent%',
                                style: ShellText.base.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 9),
                          _LevelProgress(
                            level: level,
                            inactiveColor: inactiveColor,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LevelProgress extends StatelessWidget {
  const _LevelProgress({required this.level, required this.inactiveColor});

  final double level;
  final Color inactiveColor;

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : Motion.systemLevelHudValue;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: level),
      duration: duration,
      // Re-targeting this implicit tween starts from its current rendered
      // value, so rapid hardware-key presses form one continuous glide.
      curve: Motion.md3EmphasizedDecelerate,
      builder: (context, value, _) => ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          height: 7,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: inactiveColor),
              FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: value.clamp(0.0, 1.0).toDouble(),
                child: const ColoredBox(color: ShellColors.accent),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
