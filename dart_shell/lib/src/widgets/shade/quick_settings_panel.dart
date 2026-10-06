import 'dart:math' as math;

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../localization/denial_localizations.dart';
import '../../services/network_backend.dart';
import '../../state/bluetooth.dart';
import '../../state/desktop_notifications.dart';
import '../../state/network_connectivity.dart';
import '../../state/quick_settings.dart';
import '../../state/shell_controller.dart';
import '../../state/system_status.dart';
import '../../theme/motion.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import '../connectivity/bluetooth_detail_surface.dart';
import '../connectivity/wifi_detail_surface.dart';
import '../connectivity/mobile_data_tile.dart';
import '../session/power_session_surface.dart';
import '../shell_backdrop_blur.dart';
import '../shell_surface_host.dart';
import 'quick_settings_tiles.dart';
import 'range_bar.dart';
import 'mobile_notification_history.dart';
import 'shade_backdrop_scene.dart';
import 'shade_dismiss_gesture.dart';
import 'shade_expansion_motion.dart';
import 'shade_reference_geometry.dart';

enum ShadePage { notifications, quickSettings }

EdgeInsets _divideInsets(EdgeInsets insets, double divisor) => EdgeInsets.only(
  left: insets.left / divisor,
  top: insets.top / divisor,
  right: insets.right / divisor,
  bottom: insets.bottom / divisor,
);

/// ColorOS-style split notification and control-center shade. [progress] is
/// `0` when hidden and `1` when open. The originating half of the status bar
/// selects a page; a horizontal swipe switches pages once fully expanded.
class QuickSettingsShade extends ConsumerWidget {
  const QuickSettingsShade({
    super.key,
    required this.progress,
    this.active = true,
    this.closed = false,
    this.page = ShadePage.quickSettings,
    this.onPageChanged,
  });

  final Animation<double> progress;
  final bool active;
  final bool closed;
  final ShadePage page;
  final ValueChanged<ShadePage>? onPageChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(shellControllerProvider.notifier);

    return IgnorePointer(
      ignoring: !active,
      child: ShadeBackdropScene(
        progress: progress,
        child: BackdropGroup(
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ShadeDismissGesture(
                  progress: progress,
                  child: const SizedBox.expand(),
                ),
                _FullScreenShade(
                  progress: progress,
                  child: Focus(
                    autofocus: active,
                    canRequestFocus: active,
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
                      child: _ColorOsReferenceViewport(
                        child: ColorOsShadeContentTranslation(
                          progress: progress,
                          child: _ShadeChrome(
                            progress: progress,
                            closed: closed,
                            active: active,
                            page: page,
                            onPageChanged: onPageChanged,
                          ),
                        ),
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

class _FullScreenShade extends StatelessWidget {
  const _FullScreenShade({required this.progress, required this.child});

  final Animation<double> progress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final background = AnimatedBuilder(
      animation: progress,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: theme.panelGradient(
            context.shellColors.panelBackground,
            context.shellColors.panelBackgroundBottom,
          ),
        ),
      ),
      builder: (context, background) => Opacity(
        opacity: ColorOsShadeMotion.blurFraction(progress.value),
        child: background,
      ),
    );
    return RepaintBoundary(
      child: ShadeBackdropRegion(
        occludesNotifications: false,
        borderRadius: BorderRadius.zero,
        child: AnimatedBuilder(
          animation: progress,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(child: background),
              child,
            ],
          ),
          builder: (context, composedShade) {
            final blur = ColorOsShadeMotion.blurFraction(progress.value);
            return ShellBackdropBlur(
              grouped: true,
              blur:
                  !ShadeBackdropScene.sharesBlur(context) &&
                  theme.effectivePanelOpacity < 1.0,
              strength: blur,
              separateChild: true,
              borderRadius: BorderRadius.zero,
              child: composedShade!,
            );
          },
        ),
      ),
    );
  }
}

class _ShadeChrome extends StatelessWidget {
  const _ShadeChrome({
    required this.progress,
    required this.closed,
    required this.active,
    required this.page,
    required this.onPageChanged,
  });

  final Animation<double> progress;
  final bool closed;
  final bool active;
  final ShadePage page;
  final ValueChanged<ShadePage>? onPageChanged;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final headerTop = math.max(40.0, padding.top);
    const statusHeight = 18.0;
    const statusToContentGap = 12.0;
    final contentTop = headerTop + statusHeight + statusToContentGap;
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          top: contentTop,
          child: _ShadePager(
            progress: progress,
            closed: closed,
            active: active,
            page: page,
            onPageChanged: onPageChanged,
          ),
        ),
      ],
    );
  }
}

class _ShadePager extends StatefulWidget {
  const _ShadePager({
    required this.progress,
    required this.closed,
    required this.active,
    required this.page,
    required this.onPageChanged,
  });

  final Animation<double> progress;
  final bool closed;
  final bool active;
  final ShadePage page;
  final ValueChanged<ShadePage>? onPageChanged;

  @override
  State<_ShadePager> createState() => _ShadePagerState();
}

class _ShadePagerState extends State<_ShadePager>
    with SingleTickerProviderStateMixin {
  late final AnimationController _settle;
  Animation<double>? _settleValue;
  double _dragFraction = 0;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _settle = AnimationController(vsync: this, duration: Motion.cardSettle)
      ..addListener(() {
        final animation = _settleValue;
        if (animation != null) setState(() => _dragFraction = animation.value);
      });
  }

  @override
  void didUpdateWidget(covariant _ShadePager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active) {
      _settle.stop();
      _settleValue = null;
      _dragFraction = 0;
      _dragging = false;
      return;
    }
    if (oldWidget.page != widget.page && !_settle.isAnimating) {
      _dragFraction = 0;
    }
  }

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  int _index(ShadePage page, TextDirection direction) =>
      direction == TextDirection.ltr
      ? (page == ShadePage.notifications ? 0 : 1)
      : (page == ShadePage.quickSettings ? 0 : 1);

  ShadePage _pageAt(int index, TextDirection direction) =>
      direction == TextDirection.ltr
      ? (index == 0 ? ShadePage.notifications : ShadePage.quickSettings)
      : (index == 0 ? ShadePage.quickSettings : ShadePage.notifications);

  void _startHorizontalDrag(DragStartDetails _) {
    if (widget.progress.value < 0.98) return;
    _settle.stop();
    _settleValue = null;
    _dragFraction = 0;
    _dragging = true;
  }

  void _updateHorizontalDrag(
    DragUpdateDetails details,
    double width,
    TextDirection direction,
  ) {
    if (!_dragging || width <= 0) return;
    final index = _index(widget.page, direction);
    final next = _dragFraction + details.delta.dx / width;
    setState(() {
      _dragFraction = next
          .clamp(index == 0 ? -1.0 : 0.0, index == 0 ? 0.0 : 1.0)
          .toDouble();
    });
  }

  void _endHorizontalDrag(
    DragEndDetails details,
    double width,
    TextDirection direction,
  ) {
    if (!_dragging) return;
    _dragging = false;
    final index = _index(widget.page, direction);
    final velocity = details.primaryVelocity ?? 0;
    final displacement = _dragFraction.abs() * width;
    final referenceScale = colorOsShadeScaleForViewport(
      MediaQuery.sizeOf(context),
    );
    final fling =
        velocity.abs() >= 250 * referenceScale &&
        displacement >= 30 * referenceScale;
    final towardNext = fling ? velocity < 0 : _dragFraction < 0;
    final change = displacement >= 90 * referenceScale || fling;
    final targetIndex = change
        ? (index + (towardNext ? 1 : -1)).clamp(0, 1)
        : index;
    final changing = targetIndex != index;
    final target = changing ? (targetIndex > index ? -1.0 : 1.0) : 0.0;
    _settleValue = Tween<double>(
      begin: _dragFraction,
      end: target,
    ).animate(CurvedAnimation(parent: _settle, curve: Motion.standard));
    _settle.duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : Motion.cardSettle;
    _settle
      ..value = 0
      ..forward().whenComplete(() {
        if (!mounted) return;
        if (changing) {
          widget.onPageChanged?.call(_pageAt(targetIndex, direction));
        }
        setState(() {
          _dragFraction = 0;
          _settleValue = null;
        });
      });
  }

  @override
  Widget build(BuildContext context) {
    final direction = Directionality.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final currentIndex = _index(widget.page, direction);
        Widget buildPage(ShadePage page) {
          final index = _index(page, direction);
          final isCurrent = index == currentIndex;
          final position = index - currentIndex + _dragFraction;
          return Positioned(
            left: position * width,
            top: 0,
            bottom: 0,
            width: width,
            child: IgnorePointer(
              ignoring: !isCurrent,
              child: ExcludeSemantics(
                excluding: !isCurrent,
                child: page == ShadePage.quickSettings
                    ? _ControlCenterPage(progress: widget.progress)
                    : _NotificationCenterPage(
                        progress: widget.progress,
                        closed: widget.closed,
                        active: widget.active && isCurrent,
                      ),
              ),
            ),
          );
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: _startHorizontalDrag,
          onHorizontalDragUpdate: (details) =>
              _updateHorizontalDrag(details, width, direction),
          onHorizontalDragEnd: (details) =>
              _endHorizontalDrag(details, width, direction),
          onHorizontalDragCancel: () => _endHorizontalDrag(
            DragEndDetails(primaryVelocity: 0),
            width,
            direction,
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              buildPage(ShadePage.notifications),
              buildPage(ShadePage.quickSettings),
            ],
          ),
        );
      },
    );
  }
}

class _ColorOsReferenceViewport extends StatelessWidget {
  const _ColorOsReferenceViewport({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        final scale = colorOsShadeScaleForViewport(viewport);
        final referenceSize = Size(
          viewport.width / scale,
          viewport.height / scale,
        );
        final media = MediaQuery.of(context);
        final referenceMedia = media.copyWith(
          size: referenceSize,
          devicePixelRatio: media.devicePixelRatio * scale,
          textScaler: TextScaler.linear(media.textScaler.scale(1) / scale),
          padding: _divideInsets(media.padding, scale),
          viewPadding: _divideInsets(media.viewPadding, scale),
          viewInsets: _divideInsets(media.viewInsets, scale),
          systemGestureInsets: _divideInsets(media.systemGestureInsets, scale),
        );
        return ClipRect(
          child: Align(
            alignment: Alignment.topLeft,
            child: Transform.scale(
              scale: scale,
              alignment: Alignment.topLeft,
              child: SizedBox.fromSize(
                size: referenceSize,
                child: MediaQuery(
                  data: referenceMedia,
                  child: ShadeReferenceGeometry(scale: scale, child: child),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ControlCenterPage extends StatelessWidget {
  const _ControlCenterPage({required this.progress});

  final Animation<double> progress;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    return ShadeDismissGesture(
      progress: progress,
      child: Padding(
        padding: EdgeInsets.fromLTRB(padding.left, 0, padding.right, 0),
        child: Column(
          children: [
            SizedBox(
              height: 32,
              child: ColorOsShadeElementReveal(
                progress: progress,
                threshold: ColorOsShadeMotion.firstElementThreshold,
                fade: false,
                child: const _ShadeQuickEntrance(),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                primary: false,
                padding: const EdgeInsets.fromLTRB(28, 0, 28, 24),
                child: RepaintBoundary(
                  child: _QuickSettingsTilesSection(progress: progress),
                ),
              ),
            ),
            SizedBox(height: math.max(4, padding.bottom)),
          ],
        ),
      ),
    );
  }
}

class _NotificationCenterPage extends ConsumerWidget {
  const _NotificationCenterPage({
    required this.progress,
    required this.closed,
    required this.active,
  });

  final Animation<double> progress;
  final bool closed;
  final bool active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final padding = MediaQuery.paddingOf(context);
    final empty = ref.watch(
      desktopNotificationsProvider.select((state) => state.history.isEmpty),
    );
    return ShadeDismissGesture(
      progress: progress,
      child: Padding(
        padding: EdgeInsets.fromLTRB(padding.left, 0, padding.right, 0),
        child: Column(
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  MobileNotificationHistory(
                    progress: progress,
                    closed: closed,
                    active: active,
                  ),
                  if (empty) const _EmptyNotifications(),
                ],
              ),
            ),
            SizedBox(height: math.max(4, padding.bottom)),
          ],
        ),
      ),
    );
  }
}

class _QuickSettingsTilesSection extends ConsumerWidget {
  const _QuickSettingsTilesSection({required this.progress});

  final Animation<double> progress;

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
      expansionProgress: progress,
      mobileDataTile: const MobileDataTile(),
      brightnessControl: const _BrightnessRangeBar(),
      volumeControl: const _VolumeRangeBar(),
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
    return VerticalRangeBar(
      translucentTrack: true,
      icon: Icons.brightness_6_rounded,
      value: brightness,
      activeColor: ShellTheme.of(context).accent,
      inactiveColor: context.shellColors.brightnessTrack,
      onChanged: controller.setBrightness,
      onChangeEnd: controller.commitBrightness,
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
    return VerticalRangeBar(
      translucentTrack: true,
      icon: Icons.volume_up_rounded,
      value: volume,
      activeColor: ShellTheme.of(context).accent,
      inactiveColor: context.shellColors.volumeTrack,
      onChangeStart: controller.beginVolumeInteraction,
      onChanged: controller.setVolume,
      onChangeEnd: controller.commitVolume,
    );
  }
}

class _ShadeQuickEntrance extends ConsumerWidget {
  const _ShadeQuickEntrance();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).value ?? DateTime.now();
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Row(
        children: [
          Expanded(
            child: Text(
              l10n.quickSettingsDate(_weekday(now.weekday, l10n), now.day),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ShellText.base.copyWith(
                color: context.shellColors.panelText,
                fontSize: 14,
                height: 1,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          ShadeActions(onOpenPower: () => showPowerSessionSurface(ref)),
        ],
      ),
    );
  }
}

class _EmptyNotifications extends StatelessWidget {
  const _EmptyNotifications();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.notifications_none_rounded,
              size: 32 * ShadeReferenceGeometry.inverseScaleOf(context),
              color: context.shellColors.textTertiary,
            ),
            const SizedBox(height: 10),
            Text(
              context.l10n.notificationsNone,
              style: ShellText.base.copyWith(
                color: context.shellColors.textSecondary,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
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
