import 'package:flutter/material.dart' show IconData, Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../localization/denial_localizations.dart';
import '../models/display_layout.dart';
import '../settings/settings_controller.dart';
import '../state/display_layout.dart';
import '../state/system_level_hud.dart';
import '../theme/motion.dart';
import '../theme/shell_theme.dart';
import '../theme/tokens.dart';
import 'shell_backdrop_blur.dart';

class SystemLevelHudLayer extends ConsumerWidget {
  const SystemLevelHudLayer({super.key});

  static const double _height = 74;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = ref.watch(systemLevelHudProvider);
    final output = _outputFor(ref.watch(displayLayoutProvider), hud);
    if (hud == null || output == null) {
      return const SizedBox.shrink();
    }

    final placement = ref.watch(
      shellSettingsProvider.select((settings) => settings.overlays.systemHud),
    );
    final rect = placement.resolve(output.logicalRect, fixedHeight: _height);
    if (rect.isEmpty) {
      return const SizedBox.shrink();
    }
    final isBrightness = hud.kind == SystemLevelHudKind.brightness;
    final l10n = context.l10n;

    return Positioned.fromRect(
      rect: rect,
      child: IgnorePointer(
        child: _SystemLevelHudCard(
          level: hud.level,
          visible: hud.visible,
          onDismissed: () => ref
              .read(systemLevelHudProvider.notifier)
              .completeDismissal(hud.revision),
          icon: isBrightness
              ? Icons.brightness_6_rounded
              : _volumeIcon(hud.level),
          title: isBrightness ? l10n.brightnessTitle : l10n.volumeTitle,
          detail: isBrightness ? output.name : null,
          semanticLabel: isBrightness
              ? l10n.outputBrightnessSemantics(output.name)
              : l10n.outputVolumeSemantics,
          inactiveColor: isBrightness
              ? context.shellColors.brightnessTrack
              : context.shellColors.volumeTrack,
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
    required this.onDismissed,
    required this.icon,
    required this.title,
    required this.semanticLabel,
    required this.inactiveColor,
    this.detail,
  });

  final double level;
  final bool visible;
  final VoidCallback onDismissed;
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
    final theme = ShellTheme.of(context);

    return ClipRect(
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: visible ? 1 : 0),
        duration: duration,
        curve: visible
            ? Motion.md3EmphasizedDecelerate
            : Motion.md3EmphasizedAccelerate,
        onEnd: visible ? null : onDismissed,
        builder: (context, progress, child) => FractionalTranslation(
          translation: Offset(0, 1 - progress),
          child: child,
        ),
        child: Semantics(
          container: true,
          role: .status,
          hidden: !visible,
          label: semanticLabel,
          value: context.l10n.percentValue(percent),
          child: RepaintBoundary(
            child: ShellBackdropBlur(
              blur: theme.panelOpacity < 1.0,
              borderRadius: BorderRadius.circular(theme.panelRadius),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[
                      theme.panelColor(context.shellColors.panelBackground),
                      theme.panelColor(
                        context.shellColors.panelBackgroundBottom,
                      ),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(theme.panelRadius),
                  border: Border.all(color: context.shellColors.hairline),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: context.shellColors.shadow,
                      blurRadius: 22,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Row(
                    children: [
                      Icon(icon, size: 22, color: theme.accent),
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
                                        color: context.shellColors.textTertiary,
                                        fontSize: 11,
                                      ),
                                    ),
                                  )
                                else
                                  const Spacer(),
                                Text(
                                  context.l10n.percentCompact(percent),
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
                child: ColoredBox(color: ShellTheme.of(context).accent),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
