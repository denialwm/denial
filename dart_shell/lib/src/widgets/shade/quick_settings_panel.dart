import 'dart:math' as math;
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../input/input_layout.dart';
import '../../localization/denial_localizations.dart';
import '../../services/network_backend.dart';
import '../../state/bluetooth.dart';
import '../../state/desktop_notifications.dart';
import '../../state/network_connectivity.dart';
import '../../state/quick_settings.dart';
import '../../state/shell_controller.dart';
import '../../state/system_status.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import '../connectivity/bluetooth_detail_surface.dart';
import '../connectivity/wifi_detail_surface.dart';
import '../session/power_session_surface.dart';
import '../shell_backdrop_blur.dart';
import '../shell_surface_host.dart';
import 'quick_settings_tiles.dart';
import 'range_bar.dart';
import 'status_glyphs.dart';

/// The sliding quick-settings panel. [progress] is `0` when fully hidden and
/// `1` when fully open; the panel translates in from the top edge accordingly.
class QuickSettingsShade extends ConsumerWidget {
  const QuickSettingsShade({super.key, required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(shellControllerProvider.notifier);
    final size = MediaQuery.sizeOf(context);
    final linearProgress = progress.clamp(0.0, 1.0).toDouble();
    final panelHeight = math
        .min(size.height * 0.74, ShellMetrics.quickSettingsPanelHeight)
        .toDouble();

    return IgnorePointer(
      ignoring: linearProgress < 0.02,
      child: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: controller.closeQuickSettings,
            child: const SizedBox.expand(),
          ),
          Transform.translate(
            offset: Offset(0.0, -panelHeight * (1.0 - linearProgress)),
            child: Align(
              alignment: Alignment.topCenter,
              child: Focus(
                autofocus: true,
                onKeyEvent: (_, event) {
                  if (event is KeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.escape) {
                    controller.closeQuickSettings();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  child: SizedBox(
                    width: double.infinity,
                    height: panelHeight,
                    child: const _ControlPanel(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ControlPanel extends StatelessWidget {
  const _ControlPanel();

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final theme = ShellTheme.of(context);

    return RepaintBoundary(
      child: ShellBackdropBlur(
        blur: theme.panelOpacity < 1.0,
        borderRadius: BorderRadius.vertical(
          bottom: Radius.circular(theme.panelRadius),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.panelColor(context.shellColors.panelBackground),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                theme.panelColor(context.shellColors.panelBackground),
                theme.panelColor(context.shellColors.panelBackgroundBottom),
              ],
            ),
            border: Border(
              bottom: BorderSide(color: context.shellColors.hairline, width: 1),
            ),
            boxShadow: [
              BoxShadow(
                color: context.shellColors.shadow,
                blurRadius: 24,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(20, padding.top + 18, 20, 12),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ShadeHeader(),
                SizedBox(height: 12),
                Expanded(child: _ControlContents()),
                SizedBox(height: 8),
                Center(child: _ShadeHandle()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ControlContents extends StatelessWidget {
  const _ControlContents();

  @override
  Widget build(BuildContext context) {
    return ListView(
      primary: false,
      padding: EdgeInsets.zero,
      children: const [
        _QuickSettingsTilesSection(),
        SizedBox(height: 14),
        _BrightnessRangeBar(),
        SizedBox(height: 10),
        _VolumeRangeBar(),
        SizedBox(height: 12),
        _ShadePowerFooter(),
      ],
    );
  }
}

class _QuickSettingsTilesSection extends ConsumerWidget {
  const _QuickSettingsTilesSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quickSettings = ref.watch(
      quickSettingsProvider.select(
        (state) => (rotationLock: state.rotationLock, profile: state.profile),
      ),
    );
    final quickSettingsController = ref.read(quickSettingsProvider.notifier);
    final network = ref.watch(networkConnectivityProvider);
    final networkController = ref.read(networkConnectivityProvider.notifier);
    final bluetooth = ref.watch(bluetoothProvider);
    final bluetoothController = ref.read(bluetoothProvider.notifier);
    final notificationPolicy = ref.watch(
      desktopNotificationsProvider.select(
        (state) =>
            (doNotDisturb: state.doNotDisturb, loaded: state.policyLoaded),
      ),
    );
    final notificationController = ref.read(
      desktopNotificationsProvider.notifier,
    );
    final l10n = context.l10n;
    final networkSnapshot = network.snapshot;
    final wifiToggleEnabled =
        !network.initializing &&
        networkSnapshot.serviceAvailable &&
        networkSnapshot.wifiDeviceAvailable &&
        networkSnapshot.wirelessHardwareEnabled &&
        networkSnapshot.radioPermission != NetworkPermission.denied &&
        !network.radioChanging;
    final bluetoothToggleEnabled =
        !bluetooth.initializing &&
        bluetooth.serviceAvailable &&
        bluetooth.available &&
        !bluetooth.powerChanging;
    return QuickSettingsTiles(
      wifi:
          networkSnapshot.wirelessEnabled &&
          networkSnapshot.wifiDeviceAvailable,
      wifiSubtitle: wifiStatusLabel(network, l10n),
      wifiEnabled: wifiToggleEnabled,
      wifiBusy: network.radioChanging,
      bluetooth: bluetooth.powered && bluetooth.available,
      bluetoothSubtitle: bluetoothStatusLabel(bluetooth, l10n),
      bluetoothEnabled: bluetoothToggleEnabled,
      bluetoothBusy: bluetooth.powerChanging,
      rotationLock: quickSettings.rotationLock,
      dnd: notificationPolicy.doNotDisturb,
      dndReady: notificationPolicy.loaded,
      profile: quickSettings.profile,
      onToggleWifi: networkController.toggleWireless,
      onOpenWifi: () {
        ref
            .read(shellSurfaceControllerProvider.notifier)
            .show(
              keyName: 'wifi-details',
              debugLabel: 'Wi-Fi details',
              builder: (_, handle) => WifiDetailSurface(onClose: handle.close),
            );
      },
      onToggleBluetooth: bluetoothController.togglePower,
      onOpenBluetooth: () {
        ref
            .read(shellSurfaceControllerProvider.notifier)
            .show(
              keyName: 'bluetooth-details',
              debugLabel: 'Bluetooth details',
              builder: (_, handle) =>
                  BluetoothDetailSurface(onClose: handle.close),
            );
      },
      onToggleRotation: quickSettingsController.toggleRotation,
      onToggleDnd: notificationController.toggleDoNotDisturb,
      onCycleProfile: quickSettingsController.cycleProfile,
    );
  }
}

class _BrightnessRangeBar extends ConsumerWidget {
  const _BrightnessRangeBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final brightness = ref.watch(
      quickSettingsProvider.select((state) => state.brightness),
    );
    final controller = ref.read(quickSettingsProvider.notifier);
    return RangeBar(
      icon: Icons.brightness_6_rounded,
      value: brightness,
      activeColor: ShellTheme.of(context).accent,
      inactiveColor: context.shellColors.brightnessTrack,
      onChanged: controller.setBrightness,
      onChangeEnd: controller.commitBrightness,
      height: 56,
    );
  }
}

class _VolumeRangeBar extends ConsumerWidget {
  const _VolumeRangeBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final volume = ref.watch(
      quickSettingsProvider.select((state) => state.volume),
    );
    final controller = ref.read(quickSettingsProvider.notifier);
    return RangeBar(
      icon: Icons.volume_up_rounded,
      value: volume,
      activeColor: ShellTheme.of(context).accent,
      inactiveColor: context.shellColors.volumeTrack,
      onChangeStart: controller.beginVolumeInteraction,
      onChanged: controller.setVolume,
      onChangeEnd: controller.commitVolume,
      height: 56,
    );
  }
}

class _ShadePowerFooter extends ConsumerWidget {
  const _ShadePowerFooter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ShadeFooter(onOpenPower: () => showPowerSessionSurface(ref));
  }
}

class _ShadeHeader extends ConsumerWidget {
  const _ShadeHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).value ?? DateTime.now();
    final battery = ref.watch(batteryProvider);
    final l10n = context.l10n;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              localizedTime(context, now),
              softWrap: false,
              style: ShellText.shadeClock,
            ),
            const SizedBox(height: 7),
            Text(
              l10n.quickSettingsDate(_weekday(now.weekday, l10n), now.day),
              softWrap: false,
              style: ShellText.shadeDate,
            ),
          ],
        ),
        const Spacer(),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: _StatusPill(child: StatusCluster(battery: battery)),
        ),
      ],
    );
  }

  String _weekday(int weekday, AppLocalizations l10n) => switch (weekday) {
    DateTime.monday => l10n.weekdayMonday,
    DateTime.tuesday => l10n.weekdayTuesday,
    DateTime.wednesday => l10n.weekdayWednesday,
    DateTime.thursday => l10n.weekdayThursday,
    DateTime.friday => l10n.weekdayFriday,
    DateTime.saturday => l10n.weekdaySaturday,
    _ => l10n.weekdaySunday,
  };
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.shellColors.surfaceContainer,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: context.shellColors.hairlineSoft),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: child,
      ),
    );
  }
}

class _ShadeHandle extends ConsumerWidget {
  const _ShadeHandle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(shellControllerProvider.notifier);
    return Semantics(
      button: true,
      label: context.l10n.quickSettingsClose,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              controller.closeQuickSettings();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: controller.closeQuickSettings,
          onVerticalDragStart: (_) => controller.startQuickSettingsDrag(),
          onVerticalDragUpdate: (details) =>
              controller.updateQuickSettingsDrag(Offset(0.0, details.delta.dy)),
          onVerticalDragEnd: (details) =>
              controller.endQuickSettingsDrag(details.primaryVelocity ?? 0.0),
          onVerticalDragCancel: () => controller.endQuickSettingsDrag(0.0),
          child: SizedBox(
            width: 72,
            height: 24,
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: context.shellColors.textTertiary,
                  borderRadius: BorderRadius.circular(2),
                ),
                child: const SizedBox(width: 44, height: 4),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
