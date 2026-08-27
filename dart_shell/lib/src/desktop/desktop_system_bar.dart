import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../input/shell_interaction_registry.dart';
import '../models/display_layout.dart';
import '../localization/denial_localizations.dart';
import '../models/battery_status.dart';
import '../services/media_player_service.dart';
import '../state/system_status.dart';
import '../theme/motion.dart';
import '../theme/shell_theme.dart';
import '../theme/tokens.dart';
import '../wallpaper/state/wallpaper_accent.dart';
import '../widgets/notification_media.dart';
import '../widgets/shell_backdrop_blur.dart';
import '../widgets/shell_cursor.dart';
import '../state/system_tray.dart';
import 'system_tray_module.dart';

part 'desktop_system_bar_components.dart';
part 'desktop_system_bar_media.dart';

/// The desktop system bar. Its strip is reserved from the window work area,
/// so windows maximize beside it while true fullscreen covers it.
///
/// The strip itself paints nothing: modules float as borderless pill cards
/// over the bare wallpaper, and every card follows the wallpaper's extracted
/// accent. Cards cluster at the trailing edge of the strip and spring in one
/// after another when the bar mounts.
const systemBarBatteryButtonKey = ValueKey<String>('system-bar-battery-button');

class DesktopSystemBar extends ConsumerWidget {
  const DesktopSystemBar({
    required this.side,
    required this.onOpenPowerSettings,
    super.key,
  });

  static const double _edgePadding = 8.0;
  static const double _cardMargin = 5.0;
  static const double _cardGap = 8.0;

  final SystemBarSide side;
  final VoidCallback onOpenPowerSettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = WallpaperAccent(
      ref.watch(shellAccentProvider.select((accent) => accent.color)),
    );
    final batteryVisible = ref.watch(
      batteryProvider.select((battery) => battery.capacity != null),
    );
    final cpuVisible = ref.watch(
      cpuUsageProvider.select((cpu) => cpu.current != null),
    );
    final gpuCount = ref.watch(gpuUsageProvider.select((gpus) => gpus.length));
    final mediaVisible = ref.watch(
      mediaPlaybackProvider.select((media) => media.value?.available ?? false),
    );
    final trayVisible = ref.watch(
      systemTrayProvider.select((items) => items.isNotEmpty),
    );
    final horizontal = side.isHorizontal;
    return Padding(
      padding: horizontal
          ? const EdgeInsets.symmetric(
              horizontal: _edgePadding,
              vertical: _cardMargin,
            )
          : const EdgeInsets.symmetric(
              horizontal: _cardMargin,
              vertical: _edgePadding,
            ),
      child: Flex(
        direction: horizontal ? Axis.horizontal : Axis.vertical,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (trayVisible)
            Expanded(
              child: Align(
                alignment: horizontal
                    ? Alignment.centerLeft
                    : Alignment.topCenter,
                child: SingleChildScrollView(
                  scrollDirection: horizontal ? Axis.horizontal : Axis.vertical,
                  child: _SystemBarEntrance(
                    key: const ValueKey('system-bar-tray'),
                    index: 0,
                    horizontal: horizontal,
                    child: _SystemBarCard(
                      accent: accent,
                      child: _SystemTrayStatusModule(horizontal: horizontal),
                    ),
                  ),
                ),
              ),
            ),
          if (mediaVisible)
            _SystemBarEntrance(
              key: const ValueKey('system-bar-media'),
              index:
                  (cpuVisible ? 1 : 0) +
                  gpuCount +
                  (batteryVisible ? 1 : 0) +
                  1,
              horizontal: horizontal,
              child: Padding(
                padding: horizontal
                    ? const EdgeInsets.only(right: _cardGap)
                    : const EdgeInsets.only(bottom: _cardGap),
                child: _SystemBarCard(
                  accent: accent,
                  child: _MediaStatusProviderModule(accent: accent, side: side),
                ),
              ),
            ),
          if (batteryVisible)
            _SystemBarEntrance(
              key: const ValueKey('system-bar-battery'),
              index: (cpuVisible ? 1 : 0) + gpuCount + 1,
              horizontal: horizontal,
              child: Padding(
                padding: horizontal
                    ? const EdgeInsets.only(right: _cardGap)
                    : const EdgeInsets.only(bottom: _cardGap),
                child: _BatteryStatusCard(
                  accent: accent,
                  onPressed: onOpenPowerSettings,
                ),
              ),
            ),
          if (gpuCount > 0)
            _GpuStatusCards(
              accent: accent,
              horizontal: horizontal,
              cpuVisible: cpuVisible,
            ),
          if (cpuVisible)
            _CpuStatusCard(accent: accent, horizontal: horizontal),
          _SystemBarEntrance(
            key: const ValueKey('system-bar-clock'),
            index: 0,
            horizontal: horizontal,
            child: _SystemBarCard(
              accent: accent,
              child: _ClockStatusModule(accent: accent),
            ),
          ),
        ],
      ),
    );
  }
}

/// Keeps changes to tray contents out of the complete system-bar build.
class _SystemTrayStatusModule extends ConsumerWidget {
  const _SystemTrayStatusModule({required this.horizontal});

  final bool horizontal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SystemTrayModule(
      horizontal: horizontal,
      accent: context.shellTheme.accent,
      items: ref.watch(systemTrayProvider),
    );
  }
}
