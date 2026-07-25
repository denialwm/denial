import 'dart:math' as math;
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../input/input_layout.dart';
import '../../localization/denial_localizations.dart';
import '../../services/network_manager_service.dart';
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
import '../notification_center.dart';
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
      child: Transform.translate(
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
    );
  }
}

enum _ShadeSection { controls, notifications }

class _ControlPanel extends ConsumerStatefulWidget {
  const _ControlPanel();

  @override
  ConsumerState<_ControlPanel> createState() => _ControlPanelState();
}

class _ControlPanelState extends ConsumerState<_ControlPanel> {
  _ShadeSection _section = _ShadeSection.controls;

  @override
  Widget build(BuildContext context) {
    final qs = ref.watch(quickSettingsProvider);
    final qsController = ref.read(quickSettingsProvider.notifier);
    final network = ref.watch(networkConnectivityProvider);
    final networkController = ref.read(networkConnectivityProvider.notifier);
    final bluetooth = ref.watch(bluetoothProvider);
    final bluetoothController = ref.read(bluetoothProvider.notifier);
    final notifications = ref.watch(desktopNotificationsProvider);
    final notificationController = ref.read(
      desktopNotificationsProvider.notifier,
    );
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
            color: theme.panelColor(ShellColors.panelBackground),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                theme.panelColor(ShellColors.panelBackground),
                theme.panelColor(ShellColors.panelBackgroundBottom),
              ],
            ),
            border: const Border(
              bottom: BorderSide(color: ShellColors.hairline, width: 1),
            ),
            boxShadow: const [
              BoxShadow(
                color: ShellColors.shadow,
                blurRadius: 24,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 900;
              final controls = _ControlContents(
                quickSettings: qs,
                controller: qsController,
                network: network,
                bluetooth: bluetooth,
                doNotDisturb: notifications.doNotDisturb,
                notificationPolicyLoaded: notifications.policyLoaded,
                onToggleWifi: networkController.toggleWireless,
                onOpenWifi: () {
                  ref
                      .read(shellSurfaceControllerProvider.notifier)
                      .show(
                        keyName: 'wifi-details',
                        debugLabel: 'Wi-Fi details',
                        builder: (_, handle) =>
                            WifiDetailSurface(onClose: handle.close),
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
                onToggleDoNotDisturb: notificationController.toggleDoNotDisturb,
                onOpenPower: () => showPowerSessionSurface(ref),
              );
              return Padding(
                padding: EdgeInsets.fromLTRB(20, padding.top + 18, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _ShadeHeader(),
                    const SizedBox(height: 12),
                    if (!wide) ...[
                      _ShadeSectionSwitcher(
                        selected: _section,
                        unreadCount: notifications.unreadCount,
                        onSelected: (section) {
                          if (_section != section) {
                            setState(() => _section = section);
                          }
                        },
                      ),
                      const SizedBox(height: 11),
                    ],
                    Expanded(
                      child: wide
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(child: controls),
                                const SizedBox(width: 20),
                                const SizedBox(
                                  width: 1,
                                  child: ColoredBox(
                                    color: ShellColors.hairlineSoft,
                                  ),
                                ),
                                const SizedBox(width: 20),
                                const Expanded(child: NotificationCenter()),
                              ],
                            )
                          : _section == _ShadeSection.controls
                          ? controls
                          : const NotificationCenter(),
                    ),
                    const SizedBox(height: 8),
                    const Center(child: _ShadeHandle()),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ControlContents extends StatelessWidget {
  const _ControlContents({
    required this.quickSettings,
    required this.controller,
    required this.network,
    required this.bluetooth,
    required this.doNotDisturb,
    required this.notificationPolicyLoaded,
    required this.onToggleWifi,
    required this.onOpenWifi,
    required this.onToggleBluetooth,
    required this.onOpenBluetooth,
    required this.onToggleDoNotDisturb,
    required this.onOpenPower,
  });

  final QuickSettingsState quickSettings;
  final QuickSettingsController controller;
  final NetworkConnectivityState network;
  final BluetoothState bluetooth;
  final bool doNotDisturb;
  final bool notificationPolicyLoaded;
  final VoidCallback onToggleWifi;
  final VoidCallback onOpenWifi;
  final VoidCallback onToggleBluetooth;
  final VoidCallback onOpenBluetooth;
  final VoidCallback onToggleDoNotDisturb;
  final VoidCallback onOpenPower;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
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
    return ListView(
      primary: false,
      padding: EdgeInsets.zero,
      children: [
        QuickSettingsTiles(
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
          dnd: doNotDisturb,
          dndReady: notificationPolicyLoaded,
          profile: quickSettings.profile,
          keyboardOpening: quickSettings.keyboardOpening,
          onToggleWifi: onToggleWifi,
          onOpenWifi: onOpenWifi,
          onToggleBluetooth: onToggleBluetooth,
          onOpenBluetooth: onOpenBluetooth,
          onToggleRotation: controller.toggleRotation,
          onToggleDnd: onToggleDoNotDisturb,
          onCycleProfile: controller.cycleProfile,
          onOpenKeyboard: () => controller.openKeyboard(),
        ),
        const SizedBox(height: 14),
        RangeBar(
          icon: Icons.brightness_6_rounded,
          value: quickSettings.brightness,
          activeColor: accent,
          inactiveColor: ShellColors.brightnessTrack,
          onChanged: controller.setBrightness,
          onChangeEnd: controller.commitBrightness,
          height: 56,
        ),
        const SizedBox(height: 10),
        RangeBar(
          icon: Icons.volume_up_rounded,
          value: quickSettings.volume,
          activeColor: accent,
          inactiveColor: ShellColors.volumeTrack,
          onChangeStart: controller.beginVolumeInteraction,
          onChanged: controller.setVolume,
          onChangeEnd: controller.commitVolume,
          height: 56,
        ),
        const SizedBox(height: 12),
        ShadeFooter(onOpenPower: onOpenPower),
      ],
    );
  }
}

class _ShadeSectionSwitcher extends StatelessWidget {
  const _ShadeSectionSwitcher({
    required this.selected,
    required this.unreadCount,
    required this.onSelected,
  });

  final _ShadeSection selected;
  final int unreadCount;
  final ValueChanged<_ShadeSection> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Row(
      children: [
        Expanded(
          child: _ShadeSectionButton(
            label: l10n.quickSettingsControls,
            icon: Icons.tune_rounded,
            selected: selected == _ShadeSection.controls,
            onPressed: () => onSelected(_ShadeSection.controls),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _ShadeSectionButton(
            label: unreadCount > 0
                ? l10n.quickSettingsNotificationsCount(unreadCount)
                : l10n.notificationsTitle,
            icon: Icons.notifications_rounded,
            selected: selected == _ShadeSection.notifications,
            onPressed: () => onSelected(_ShadeSection.notifications),
          ),
        ),
      ],
    );
  }
}

class _ShadeSectionButton extends StatefulWidget {
  const _ShadeSectionButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onPressed;

  @override
  State<_ShadeSectionButton> createState() => _ShadeSectionButtonState();
}

class _ShadeSectionButtonState extends State<_ShadeSectionButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final accent = ShellTheme.of(context).accent;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.label,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 160),
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: widget.selected
                  ? ShellColors.primaryContainer
                  : ShellColors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(13),
              border: Border.all(
                color: _focused ? accent : ShellColors.hairlineSoft,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  widget.icon,
                  size: 16,
                  color: widget.selected
                      ? ShellColors.onPrimaryContainer
                      : ShellColors.textSecondary,
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ShellText.base.copyWith(
                      color: widget.selected
                          ? ShellColors.onPrimaryContainer
                          : ShellColors.textSecondary,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
        color: ShellColors.surfaceContainer,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: ShellColors.hairlineSoft),
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
                  color: ShellColors.textTertiary,
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
