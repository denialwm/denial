import 'dart:async';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../profile/desktop_profile.dart';
import '../profile/profile_avatar.dart';
import '../state/clipboard_tray.dart';
import '../state/quick_settings.dart';
import '../state/reference_shell_presentation.dart';
import '../state/reference_shell_profile.dart';
import '../widgets/notification_center.dart';
import '../widgets/session/power_session_surface.dart';

import 'package:denial_flutter_sdk/controls.dart';

import 'desktop_app_volume_manager.dart';
import 'desktop_audio_device_dropdown.dart';
import 'desktop_dashboard_bluetooth.dart';
import 'desktop_dashboard_controls.dart';
import 'desktop_dashboard_power_modes.dart';
import 'desktop_workspace.dart';
import '../state/phone_desk.dart';

const _dashboardBluetoothMaxHeight = 240.0;

enum _DashboardDetail { power, notifications }

class DesktopDashboard extends ConsumerStatefulWidget {
  const DesktopDashboard({
    super.key,
    required this.onEnter,
    required this.onExit,
    required this.onOpenSettings,
  });

  final VoidCallback onEnter;
  final VoidCallback onExit;
  final VoidCallback onOpenSettings;

  @override
  ConsumerState<DesktopDashboard> createState() => _DesktopDashboardState();
}

class _DesktopDashboardState extends ConsumerState<DesktopDashboard>
    with SingleTickerProviderStateMixin {
  final _powerButtonKey = GlobalKey();
  final _notificationButtonKey = GlobalKey();
  final _bodyKey = GlobalKey();
  final _powerButtonFocus = FocusNode(debugLabel: 'Dashboard power button');
  final _notificationButtonFocus = FocusNode(
    debugLabel: 'Dashboard notifications button',
  );
  final _detailFocus = FocusNode(debugLabel: 'Dashboard expanded card');
  late final AnimationController _expansion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  );
  _DashboardDetail? _detail;
  _DashboardDetail _displayedDetail = _DashboardDetail.power;
  bool get _detailOpen => _detail != null;

  FocusNode _buttonFocus(_DashboardDetail detail) => switch (detail) {
    _DashboardDetail.power => _powerButtonFocus,
    _DashboardDetail.notifications => _notificationButtonFocus,
  };
  Rect _origin = Rect.zero;
  double _originRight = 0;

  @override
  void dispose() {
    _expansion.dispose();
    _powerButtonFocus.dispose();
    _notificationButtonFocus.dispose();
    _detailFocus.dispose();
    super.dispose();
  }

  void _closeDetail({bool restoreFocus = true, bool animate = true}) {
    final detail = _detail;
    if (detail == _DashboardDetail.power) {
      ref.read(sessionPowerProvider.notifier).cancelConfirmation();
    }
    setState(() => _detail = null);
    if (animate) {
      _expansion.reverse();
    } else {
      _expansion.value = 0;
    }
    if (restoreFocus && detail != null) _buttonFocus(detail).requestFocus();
  }

  void _toggleDetail(_DashboardDetail detail) {
    if (_detail == detail) {
      _closeDetail();
      return;
    }
    final buttonKey = detail == _DashboardDetail.power
        ? _powerButtonKey
        : _notificationButtonKey;
    final button = buttonKey.currentContext!.findRenderObject()! as RenderBox;
    final body = _bodyKey.currentContext!.findRenderObject()! as RenderBox;
    _origin =
        body.globalToLocal(button.localToGlobal(Offset.zero)) & button.size;
    _originRight = body.size.width - _origin.right;
    if (_detail == _DashboardDetail.power || detail == _DashboardDetail.power) {
      ref.read(sessionPowerProvider.notifier).cancelConfirmation();
    }
    if (detail == _DashboardDetail.power) {
      unawaited(ref.read(sessionPowerProvider.notifier).refresh());
    }
    widget.onEnter();
    setState(() {
      _detail = detail;
      _displayedDetail = detail;
    });
    _expansion.forward(from: 0).whenCompleteOrCancel(() {
      // Wait for the final frame to re-enable the expanded card's focus tree.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _detail == detail && _expansion.value == 1) {
          _detailFocus.requestFocus();
        }
      });
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) {
      if (_detail == _DashboardDetail.power &&
          ref.read(sessionPowerProvider).confirmationAction != null) {
        ref.read(sessionPowerProvider.notifier).cancelConfirmation();
        _detailFocus.requestFocus();
      } else if (_detailOpen) {
        _closeDetail();
      } else {
        ref.read(desktopWorkspaceProvider.notifier).closePanels();
      }
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final scale = ref.watch(
      shellSettingsProvider.select((s) => s.animations.durationScale),
    );
    _expansion.duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : Duration(milliseconds: (250 * scale).round());
    ref.listen(desktopWorkspaceProvider.select((s) => s.dashboardOpen), (
      _,
      open,
    ) {
      if (!open && _detailOpen) {
        _closeDetail(restoreFocus: false, animate: false);
      }
    });
    return MouseRegion(
      onEnter: (_) => widget.onEnter(),
      onExit: (_) => widget.onExit(),
      child: Focus(
        onKeyEvent: _onKey,
        child: FocusTraversalGroup(
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: theme.panelColor(context.shellColors.panelBackground),
              borderRadius: BorderRadius.circular(theme.panelRadius),
              border: Border.all(color: context.shellColors.hairline),
            ),
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _DashboardHeader(
                  onOpenSettings: widget.onOpenSettings,
                  onTogglePower: () => _toggleDetail(_DashboardDetail.power),
                  powerOpen: _detail == _DashboardDetail.power,
                  onToggleNotifications: () =>
                      _toggleDetail(_DashboardDetail.notifications),
                  notificationsOpen: _detail == _DashboardDetail.notifications,
                  notificationButtonKey: _notificationButtonKey,
                  notificationFocusNode: _notificationButtonFocus,
                  powerButtonKey: _powerButtonKey,
                  powerFocusNode: _powerButtonFocus,
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: LayoutBuilder(
                    key: _bodyKey,
                    builder: (context, constraints) => AnimatedBuilder(
                      animation: _expansion,
                      builder: (context, child) {
                        final t = Motion.md3EmphasizedDecelerate.transform(
                          _expansion.value,
                        );
                        final target = Offset.zero & constraints.biggest;
                        final origin = Rect.fromLTWH(
                          target.width - _originRight - _origin.width,
                          _origin.top,
                          _origin.width,
                          _origin.height,
                        );
                        final rect = Rect.lerp(origin, target, t)!;
                        final radius = 12 + (theme.panelRadius - 12) * t;
                        return Stack(
                          clipBehavior: Clip.none,
                          fit: StackFit.expand,
                          children: [
                            IgnorePointer(
                              ignoring: _detailOpen || _expansion.value > 0,
                              child: ExcludeFocus(
                                excluding: _detailOpen || _expansion.value > 0,
                                child: ExcludeSemantics(
                                  excluding:
                                      _detailOpen || _expansion.value > 0,
                                  child: Opacity(opacity: 1 - t, child: child),
                                ),
                              ),
                            ),
                            if (_expansion.value > 0 || _detailOpen) ...[
                              Positioned.fromRect(
                                rect: rect,
                                child: IgnorePointer(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: Color.lerp(
                                        theme.accentPalette.container,
                                        context.shellColors.surfaceContainer,
                                        t,
                                      ),
                                      borderRadius: BorderRadius.circular(
                                        radius,
                                      ),
                                      border: Border.all(
                                        color: context.shellColors.hairlineSoft,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              IgnorePointer(
                                ignoring: !_detailOpen || _expansion.value < 1,
                                child: ExcludeFocus(
                                  excluding:
                                      !_detailOpen || _expansion.value < 1,
                                  child: ExcludeSemantics(
                                    excluding:
                                        !_detailOpen || _expansion.value < 1,
                                    child: ClipRRect(
                                      clipper: _DashboardDetailClipper(
                                        rect,
                                        radius,
                                      ),
                                      child: Opacity(
                                        opacity: const Interval(
                                          .35,
                                          1,
                                        ).transform(_expansion.value),
                                        child: Focus(
                                          focusNode: _detailFocus,
                                          child:
                                              _displayedDetail ==
                                                  _DashboardDetail.power
                                              ? PowerSessionContent(
                                                  embedded: true,
                                                  onClose: _closeDetail,
                                                )
                                              : _DashboardNotificationCard(
                                                  active:
                                                      _detail ==
                                                          _DashboardDetail
                                                              .notifications &&
                                                      _expansion.value == 1,
                                                  onClose: _closeDetail,
                                                ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        );
                      },
                      child: DesktopDashboardCardLayout(
                        volume: const _DashboardVolumeCard(),
                        powerModes: const DesktopPowerModesSection(),
                        bluetooth: const _DashboardBluetoothCard(),
                      ),
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

class _DashboardDetailClipper extends CustomClipper<RRect> {
  const _DashboardDetailClipper(this.rect, this.radius);
  final Rect rect;
  final double radius;

  @override
  RRect getClip(Size size) =>
      RRect.fromRectAndRadius(rect, Radius.circular(radius));

  @override
  bool shouldReclip(_DashboardDetailClipper oldClipper) =>
      rect != oldClipper.rect || radius != oldClipper.radius;
}

class DesktopDashboardCardLayout extends StatelessWidget {
  const DesktopDashboardCardLayout({
    required this.volume,
    required this.powerModes,
    required this.bluetooth,
    super.key,
  });

  final Widget volume;
  final Widget powerModes;
  final Widget bluetooth;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      primary: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          volume,
          const SizedBox(height: 12),
          powerModes,
          SizedBox(height: _dashboardBluetoothMaxHeight, child: bluetooth),
        ],
      ),
    );
  }
}

class _DashboardHeader extends ConsumerWidget {
  const _DashboardHeader({
    required this.onOpenSettings,
    required this.onTogglePower,
    required this.powerOpen,
    required this.powerButtonKey,
    required this.powerFocusNode,
    required this.onToggleNotifications,
    required this.notificationsOpen,
    required this.notificationButtonKey,
    required this.notificationFocusNode,
  });

  final VoidCallback onOpenSettings;
  final VoidCallback onTogglePower;
  final bool powerOpen;
  final GlobalKey powerButtonKey;
  final FocusNode powerFocusNode;
  final VoidCallback onToggleNotifications;
  final bool notificationsOpen;
  final GlobalKey notificationButtonKey;
  final FocusNode notificationFocusNode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unreadCount = ref.watch(
      desktopNotificationsProvider.select((state) => state.unreadCount),
    );
    final l10n = context.l10n;
    final presentation = ref.watch(referenceShellPresentationProvider);
    final singleOutput =
        (ref.watch(deskDisplayLayoutProvider)?.outputs.length ?? 0) <= 1;

    return Row(
      children: [
        const Expanded(child: _DashboardProfile()),
        const SizedBox(width: 12),
        if (singleOutput) ...[
          DashboardIconButton(
            semanticLabel: l10n.shellPresentationMobile,
            icon: Icons.smartphone_rounded,
            active: presentation == ReferenceShellProfile.mobile,
            onTap: () {
              ref.read(desktopWorkspaceProvider.notifier).closePanels();
              ref.read(referenceShellPresentationProvider.notifier).toggle();
            },
          ),
          const SizedBox(width: 7),
        ],
        DashboardIconButton(
          key: notificationButtonKey,
          focusNode: notificationFocusNode,
          semanticLabel: unreadCount == 0
              ? l10n.desktopOpenNotificationCenter
              : l10n.desktopOpenNotificationCenterUnread(unreadCount),
          icon: unreadCount == 0
              ? Icons.notifications_none_rounded
              : Icons.notifications_active_rounded,
          active: notificationsOpen || unreadCount > 0,
          onTap: onToggleNotifications,
        ),
        const SizedBox(width: 7),
        DashboardIconButton(
          semanticLabel: l10n.settingsApplicationSemanticsLabel,
          icon: Icons.settings_rounded,
          onTap: onOpenSettings,
        ),
        const SizedBox(width: 7),
        DashboardIconButton(
          key: powerButtonKey,
          focusNode: powerFocusNode,
          active: powerOpen,
          semanticLabel: l10n.desktopOpenPowerControls,
          icon: Icons.power_settings_new_rounded,
          onTap: onTogglePower,
        ),
      ],
    );
  }
}

class _DashboardProfile extends ConsumerWidget {
  const _DashboardProfile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile =
        ref.watch(desktopProfileProvider).value ?? const DesktopProfile();
    final userName = profile.displayName.isNotEmpty
        ? profile.displayName
        : ref.watch(desktopAccountNameProvider) ??
              context.l10n.desktopCurrentUser;
    final avatarPath = ref
        .watch(desktopProfileStoreProvider)
        .avatarPath(profile);
    return Tooltip(
      message: userName,
      excludeFromSemantics: true,
      child: Semantics(
        container: true,
        label: userName,
        child: ExcludeSemantics(
          child: Row(
            children: [
              ProfileAvatar(path: avatarPath),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  userName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.shellTheme.text.cardTitle.copyWith(
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashboardVolumeCard extends ConsumerWidget {
  const _DashboardVolumeCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final volume = ref.watch(
      quickSettingsProvider.select((state) => state.volume),
    );
    final devices = ref.watch(audioDevicesProvider);
    final controller = ref.read(quickSettingsProvider.notifier);
    final deviceController = ref.read(audioDevicesProvider.notifier);
    return DashboardCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            slider: true,
            label: context.l10n.commonVolume,
            value: context.l10n.settingsPercent((volume * 100).round()),
            onIncrease: () => controller.commitDashboardVolume(
              (volume + .05).clamp(0.0, 1.0),
            ),
            onDecrease: () => controller.commitDashboardVolume(
              (volume - .05).clamp(0.0, 1.0),
            ),
            child: RangeBar(
              icon: volume <= 0.01
                  ? Icons.volume_off_rounded
                  : Icons.volume_up_rounded,
              value: volume,
              activeColor: ShellTheme.of(context).accent,
              inactiveColor: context.shellColors.volumeTrack,
              onChangeStart: controller.beginVolumeInteraction,
              onChanged: controller.setDashboardVolume,
              onChangeEnd: controller.commitDashboardVolume,
              height: 48,
            ),
          ),
          const SizedBox(height: 10),
          DashboardAudioDeviceDropdown(
            state: devices,
            onRefresh: deviceController.refresh,
            onSelected: deviceController.select,
          ),
          const SizedBox(height: 10),
          const DashboardMixer(),
        ],
      ),
    );
  }
}

class _DashboardBluetoothCard extends ConsumerWidget {
  const _DashboardBluetoothCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bluetooth = ref.watch(bluetoothProvider);
    final controller = ref.read(bluetoothProvider.notifier);
    final l10n = context.l10n;
    final accent = ShellTheme.of(context).accent;
    return DashboardCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.bluetooth_rounded, size: 21, color: accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.commonBluetooth,
                  style: context.shellTheme.text.cardTitle,
                ),
              ),
              DashboardIconButton(
                semanticLabel: bluetooth.powered
                    ? l10n.desktopTurnBluetoothOff
                    : l10n.desktopTurnBluetoothOn,
                icon: Icons.power_settings_new_rounded,
                active: bluetooth.powered,
                busy: bluetooth.powerChanging,
                onTap: controller.togglePower,
              ),
              const SizedBox(width: 7),
              DashboardIconButton(
                semanticLabel: l10n.desktopScanBluetooth,
                icon: Icons.bluetooth_searching_rounded,
                active: bluetooth.scanning || bluetooth.discovering,
                busy: bluetooth.scanning,
                enabled: bluetooth.powered,
                onTap: controller.scan,
              ),
              const SizedBox(width: 7),
              DashboardIconButton(
                semanticLabel: l10n.desktopRefreshBluetooth,
                icon: Icons.refresh_rounded,
                busy: bluetooth.refreshing,
                onTap: controller.refresh,
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (bluetooth.error != null) ...[
            Text(
              l10n.settingsBluetoothUnavailable,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.shellTheme.text.cardTitle.copyWith(
                color: context.shellColors.performanceBad,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 10),
          ],
          Expanded(
            child: DashboardBluetoothDeviceList(
              state: bluetooth,
              onToggleConnection: controller.toggleConnection,
            ),
          ),
        ],
      ),
    );
  }
}

class _DashboardNotificationCard extends StatelessWidget {
  const _DashboardNotificationCard({
    required this.active,
    required this.onClose,
  });

  final bool active;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Semantics(
      label: l10n.notificationsTitle,
      container: true,
      explicitChildNodes: true,
      child: FocusScope(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.notificationsTitle,
                      style: context.shellTheme.text.statusClock.copyWith(
                        fontSize: 17,
                      ),
                    ),
                  ),
                  DashboardIconButton(
                    semanticLabel: l10n.notificationsCloseCenter,
                    icon: Icons.close_rounded,
                    onTap: onClose,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Expanded(
                child: NotificationCenter(showTitle: false, active: active),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
