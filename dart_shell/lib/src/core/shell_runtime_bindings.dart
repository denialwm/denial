import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings/settings_controller.dart';
import '../settings/shell_settings.dart';
import '../state/bluetooth.dart';
import '../state/cursor_theme.dart';
import '../state/desktop_notifications.dart';
import '../state/display_layout.dart';
import '../state/shell_controller.dart';
import '../wallpaper/state/wallpaper_accent.dart';
import '../widgets/shell_surface_host.dart';

typedef DenialPairingSurfaceBuilder =
    Widget Function(BuildContext context, VoidCallback close);
typedef DenialShellEffect = void Function(WidgetRef ref);

/// Owns process-lifetime synchronization independently of feature UI.
class ShellRuntimeBindings extends ConsumerStatefulWidget {
  const ShellRuntimeBindings({
    super.key,
    required this.child,
    this.pairingSurfaceBuilder,
    this.onLocked,
  });

  final Widget child;
  final DenialPairingSurfaceBuilder? pairingSurfaceBuilder;
  final DenialShellEffect? onLocked;

  @override
  ConsumerState<ShellRuntimeBindings> createState() =>
      _ShellRuntimeBindingsState();
}

class _ShellRuntimeBindingsState extends ConsumerState<ShellRuntimeBindings> {
  @override
  void initState() {
    super.initState();
    ref.listenManual(
      shellSettingsProvider.select((settings) => settings.layout),
      (_, layout) => _scheduleLayoutSync(layout),
      fireImmediately: true,
    );
    ref.listenManual(
      shellSettingsProvider.select((settings) => settings.power),
      (_, power) => _schedulePowerSync(power),
      fireImmediately: true,
    );
    ref.listenManual(
      shellAccentProvider,
      (_, accent) => _scheduleAccentSync(accent),
      fireImmediately: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    // These providers own process-lifetime integrations. Keeping the eager
    // subscriptions here makes that runtime contract explicit.
    ref.watch(shellControllerProvider.select((_) => null));
    ref.watch(desktopNotificationsProvider.select((_) => null));
    ref.listen<bool>(
      shellControllerProvider.select((state) => state.lockLayerVisible),
      (_, lockLayerVisible) {
        if (!lockLayerVisible) {
          return;
        }
        ref
            .read(shellSurfaceControllerProvider.notifier)
            .dismissAllImmediately();
        widget.onLocked?.call(ref);
      },
    );
    ref.listen<int?>(
      bluetoothProvider.select((state) => state.pairingRequest?.id),
      (_, requestId) => _presentPairingRequest(requestId),
    );
    ref.listen<String>(
      shellSettingsProvider.select(
        (settings) => settings.appearance.cursorThemeId,
      ),
      (previous, next) {
        if (previous != next) {
          unawaited(ref.read(cursorThemeCatalogProvider.notifier).refresh());
        }
      },
    );
    return widget.child;
  }

  void _presentPairingRequest(int? requestId) {
    if (requestId == null) {
      return;
    }
    final bluetooth = ref.read(bluetoothProvider.notifier);
    if (ref.read(shellControllerProvider).lockLayerVisible) {
      bluetooth.respondToPairing(accepted: false);
      return;
    }
    final builder = widget.pairingSurfaceBuilder;
    if (builder == null) {
      // A custom shell that omits pairing UI must fail closed.
      bluetooth.respondToPairing(accepted: false);
      return;
    }
    ref
        .read(shellSurfaceControllerProvider.notifier)
        .show(
          keyName: 'bluetooth-details',
          debugLabel: 'Bluetooth pairing',
          builder: (context, handle) => builder(context, handle.close),
        );
  }

  void _scheduleLayoutSync(ShellLayoutSettings layout) {
    scheduleMicrotask(() {
      if (!mounted) {
        return;
      }
      ref
          .read(displayLayoutProvider.notifier)
          .applyShellConfiguration(
            side: layout.systemBarSide,
            outputNames: layout.systemBarOutputNames,
            systemBarThickness: layout.systemBarThickness,
            maximizePadding: layout.maximizePadding,
          );
    });
  }

  void _schedulePowerSync(ShellPowerSettings power) {
    scheduleMicrotask(() {
      if (!mounted) {
        return;
      }
      ref
          .read(denialBridgeProvider)
          .setIdlePolicy(
            lockEnabled: power.idleLockEnabled,
            lockTimeout: Duration(minutes: power.idleLockTimeoutMinutes),
            dpmsEnabled: power.idleDpmsEnabled,
            dpmsTimeout: Duration(minutes: power.idleDpmsTimeoutMinutes),
            suspendEnabled: power.idleSuspendEnabled,
            suspendTimeout: Duration(minutes: power.idleSuspendTimeoutMinutes),
          );
    });
  }

  void _scheduleAccentSync(WallpaperAccent accent) {
    // Keep the cached portal accent authoritative while wallpaper decoding is
    // still in flight; publishing the fallback would flash the wrong accent.
    if (!accent.isResolved) {
      return;
    }
    scheduleMicrotask(() {
      if (mounted) {
        ref
            .read(denialBridgeProvider)
            .publishThemeAccent(accent.color.toARGB32());
      }
    });
  }
}
