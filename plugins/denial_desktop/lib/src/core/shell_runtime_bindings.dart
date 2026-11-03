import 'package:denial_desktop/src/state/notification_groups.dart';
import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_desktop/src/widgets/notification_open.dart';

import 'dart:async';

import 'package:denial_flutter_sdk/popups.dart';
import 'package:denial_flutter_sdk/surfaces.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/wallpaper.dart';

typedef DenialPairingSurfaceBuilder = Widget Function(
  BuildContext context,
  VoidCallback close,
);
typedef DenialShellEffect = void Function(WidgetRef ref);

/// Owns process-lifetime synchronization independently of feature UI.
class ShellRuntimeBindings extends ConsumerStatefulWidget {
  const ShellRuntimeBindings({
    super.key,
    required this.child,
    this.pairingSurfaceBuilder,
    this.onLocked,
    this.workArea,
    this.mobilePresentation = false,
    this.deskBeside = false,
  });

  final Widget child;
  final DenialPairingSurfaceBuilder? pairingSurfaceBuilder;
  final DenialShellEffect? onLocked;
  final ShellWorkArea? workArea;
  final bool mobilePresentation;

  /// A monitor runs the desktop shell beside the phone: its windows keep
  /// desktop padding and it locks after its own idle timeout.
  final bool deskBeside;

  @override
  ConsumerState<ShellRuntimeBindings> createState() =>
      _ShellRuntimeBindingsState();
}

class _ShellRuntimeBindingsState extends ConsumerState<ShellRuntimeBindings> {
  @override
  void didUpdateWidget(ShellRuntimeBindings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workArea != widget.workArea ||
        oldWidget.mobilePresentation != widget.mobilePresentation ||
        oldWidget.deskBeside != widget.deskBeside) {
      _scheduleLayoutSync(ref.read(shellSettingsProvider).layout);
    }
    if (oldWidget.mobilePresentation != widget.mobilePresentation ||
        oldWidget.deskBeside != widget.deskBeside) {
      _schedulePowerSync(ref.read(shellSettingsProvider).power);
    }
  }

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
    ref.watch(referenceShellProvider.select((_) => null));
    ref.watch(desktopNotificationsProvider.select((_) => null));
    ref.listen<bool>(
      referenceShellProvider.select((state) => state.lockLayerVisible),
      (_, lockLayerVisible) {
        if (!lockLayerVisible) {
          openLockNotification(ref);
          return;
        }
        ref.read(lockNotificationOpenProvider.notifier).clear();
        ref.read(shellPopupControllerProvider.notifier).dismissAllImmediately();
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
    if (ref.read(referenceShellProvider).lockLayerVisible) {
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
        .read(shellPopupControllerProvider.notifier)
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
      final reservation = widget.workArea?.reserve(layout);
      ref
          .read(displayLayoutProvider.notifier)
          .applyShellConfiguration(
            side: reservation?.edge ?? PanelEdge.hidden,
            outputNames: reservation?.outputNames ?? const [],
            systemBarThickness: reservation?.thickness ?? 0,
            maximizePadding: widget.mobilePresentation && !widget.deskBeside
                ? 0
                : layout.maximizePadding,
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
            powerButtonAction: power.powerButtonAction,
            // A phone locks a set time after its screen goes dark, or never.
            // Beside a desk, the desk's idle timeout locks both screens.
            lockEnabled:
                power.idleLockEnabled &&
                (!widget.mobilePresentation || widget.deskBeside),
            lockTimeout: Duration(seconds: power.idleLockTimeoutSeconds),
            dpmsEnabled: power.idleDpmsEnabled,
            dpmsTimeout: Duration(seconds: power.idleDpmsTimeoutSeconds),
            suspendEnabled: power.idleSuspendEnabled,
            suspendTimeout: Duration(seconds: power.idleSuspendTimeoutSeconds),
            suspendMode: power.suspendMode,
            lockAfterScreenOff:
                power.idleLockEnabled && widget.mobilePresentation
                ? Duration(seconds: power.screenOffLockDelaySeconds)
                : null,
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
