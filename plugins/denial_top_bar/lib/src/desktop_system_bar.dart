import 'dart:async';
import 'dart:math' as math;

import 'package:denial_flutter_sdk/effects.dart';
import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/panels.dart';
import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/theme.dart';
import 'package:denial_sdk/system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

part 'desktop_system_bar_components.dart';
part 'desktop_system_bar_media.dart';
part 'desktop_workspace_indicator.dart';

/// The desktop system bar. Its strip is reserved from the window work area,
/// so windows maximize beside it while true fullscreen covers it.
///
/// The strip itself paints nothing: modules float as borderless pill cards
/// over the bare wallpaper, and every card follows the wallpaper's extracted
/// accent. Cards cluster at the trailing edge of the strip and spring in one
/// after another when the bar mounts.
const systemBarBatteryButtonKey = ValueKey<String>('system-bar-battery-button');
const systemBarClockButtonKey = ValueKey<String>('system-bar-clock-button');

class _DesktopSystemBarContent extends ConsumerWidget {
  const _DesktopSystemBarContent({
    required this.monitorId,
    required this.side,
    required this.onOpenPowerSettings,
    required this.onOpenDashboard,
  });

  static const double _edgePadding = 8.0;
  static const double _cardMargin = 5.0;
  static const double _cardGap = 8.0;

  final int monitorId;
  final PanelEdge side;
  final VoidCallback onOpenPowerSettings;
  final VoidCallback onOpenDashboard;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = WallpaperAccent(
      ref.watch(context.presentationServices.accent),
    );
    final batteryVisible = ref.watch(
      context.telemetryServices.battery.select(
        (battery) => battery.capacity != null,
      ),
    );
    final cpuVisible = ref.watch(
      context.telemetryServices.cpu.select((cpu) => cpu.current != null),
    );
    final gpuCount = ref.watch(
      context.telemetryServices.gpus.select((gpus) => gpus.length),
    );
    final mediaVisible = ref.watch(
      context.mediaServices.media.select(
        (media) => media.value?.available ?? false,
      ),
    );
    final trayVisible = ref.watch(context.trayServices.trayVisible);
    final horizontal = side.isHorizontal;
    final modules = Flex(
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
                (cpuVisible ? 1 : 0) + gpuCount + (batteryVisible ? 1 : 0) + 1,
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
        if (cpuVisible) _CpuStatusCard(accent: accent, horizontal: horizontal),
        _SystemBarEntrance(
          key: const ValueKey('system-bar-clock'),
          index: 0,
          horizontal: horizontal,
          child: _SystemBarButton(
            key: systemBarClockButtonKey,
            accent: accent,
            label: context.pluginStrings.openDashboard,
            onPressed: onOpenDashboard,
            child: _ClockStatusModule(accent: accent),
          ),
        ),
      ],
    );
    final workspacesEnabled = ref.watch(
      context.workspaceServices.workspacesEnabled,
    );
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
      child: Stack(
        fit: StackFit.expand,
        children: [
          modules,
          if (workspacesEnabled)
            Center(
              child: DesktopSystemBarIndicatorSlot(
                horizontal: horizontal,
                child: _WorkspaceIndicator(
                  monitorId: monitorId,
                  horizontal: horizontal,
                  accent: accent,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Shrink-wraps the centered workspace pill along the bar's main axis.
///
/// System-bar cards intentionally fill the cross axis. Without this flex
/// boundary, the expanding [Stack] also gives the centered card a bounded main
/// axis, causing its backdrop-filter clip to cover the complete bar strip.
class DesktopSystemBarIndicatorSlot extends StatelessWidget {
  const DesktopSystemBarIndicatorSlot({
    required this.horizontal,
    required this.child,
    super.key,
  });

  final bool horizontal;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Flex(
      direction: horizontal ? Axis.horizontal : Axis.vertical,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[child],
    );
  }
}

/// Keeps changes to tray contents out of the complete system-bar build.
class _SystemTrayStatusModule extends ConsumerWidget {
  const _SystemTrayStatusModule({required this.horizontal});

  final bool horizontal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return context.trayServices.buildSystemTray(
      context,
      horizontal: horizontal,
    );
  }
}

/// Default bar presentation, supplied entirely by the plugin package.
class DesktopSystemBar extends StatelessWidget {
  const DesktopSystemBar({
    required this.monitorId,
    required this.side,
    required this.services,
    super.key,
  });
  final int monitorId;
  final PanelEdge side;
  final ShellServices services;

  @override
  Widget build(BuildContext context) => ShellServicesScope(
    services: services,
    child: _DesktopSystemBarContent(
      monitorId: monitorId,
      side: side,
      onOpenPowerSettings: services.openPowerSettings,
      onOpenDashboard: services.openDashboard,
    ),
  );
}

extension _PluginContext on BuildContext {
  ShellTelemetryServices get telemetryServices => ShellServicesScope.of(this);
  ShellMediaServices get mediaServices => ShellServicesScope.of(this);
  ShellWorkspaceServices get workspaceServices => ShellServicesScope.of(this);
  ShellPresentationServices get presentationServices =>
      ShellServicesScope.of(this);
  ShellTrayServices get trayServices => ShellServicesScope.of(this);
  ShellStrings get pluginStrings => presentationServices.strings(this);
}
