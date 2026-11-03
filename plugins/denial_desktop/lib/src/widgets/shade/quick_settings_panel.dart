import 'package:denial_desktop/src/state/reference_shell_controller.dart';

import 'dart:math' as math;

import 'package:denial_flutter_sdk/popups.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/system_services.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/state.dart';

import '../../state/quick_settings.dart';
import '../../state/reference_shell_presentation.dart';
import '../../state/reference_shell_profile.dart';

import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/rendering.dart'
    show
        CompositedTranslation,
        WindowBackdropCache,
        WindowBackdropMotion,
        WindowBackdropSlice;
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/tokens.dart';

import '../connectivity/bluetooth_detail_surface.dart';
import '../connectivity/wifi_detail_surface.dart';
import '../connectivity/mobile_data_tile.dart';
import '../session/power_session_surface.dart';

import 'package:denial_flutter_sdk/effects.dart';

import '../liquid/water_reveal.dart';
import 'liquid_range_bar.dart';
import 'quick_settings_tiles.dart';

import 'mobile_notification_history.dart';
import 'shade_backdrop_scene.dart';
import 'shade_dismiss_gesture.dart';
import 'shade_expansion_motion.dart';
import 'shade_reference_geometry.dart';
import 'status_bar.dart';
import '../../state/phone_desk.dart';

enum ShadePage { notifications, quickSettings }

/// The scene's backdrop frosted once, when the translucent shade can show it
/// in place of live material.
WindowBackdropCache? _frostedShadeBackdrop(BuildContext context) =>
    context.shellTheme.effectivePanelOpacity < 1
    ? WindowBackdropCache.maybeOf(context)
    : null;

final _blurFraction = Animatable<double>.fromCallback(
  ColorOsShadeMotion.blurFraction,
);

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
    final controller = ref.read(referenceShellProvider.notifier);

    return IgnorePointer(
      ignoring: !active,
      child: ShadeBackdropScene(
        progress: progress,
        cached: _frostedShadeBackdrop(context) != null,
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
                  // Notifications scroll over the status row.
                  header: ShadeHeaderStatusLayer(progress: progress),
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
  const _FullScreenShade({
    required this.progress,
    required this.header,
    required this.child,
  });

  final Animation<double> progress;

  /// Drawn over the shade's material, beneath [child].
  final Widget header;
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
    final cache = _frostedShadeBackdrop(context);
    if (cache != null) {
      final fade = progress.drive(_blurFraction);
      return RepaintBoundary(
        child: ShadeBackdropRegion(
          occludesNotifications: false,
          borderRadius: BorderRadius.zero,
          // The frosted wallpaper fades in as the live material's strength
          // would ramp, and its overlay dims the scene beneath. Notification
          // cards draw the same dimmed frost as their glass.
          child: WindowBackdropCache(
            backdrop: cache.backdrop,
            motion: cache.motion,
            overlayColor: ShadeBackdropScene.dim,
            overlayOpacity: fade,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Builder(
                  builder: (context) {
                    final dimmed = WindowBackdropCache.maybeOf(context);
                    return dimmed == null
                        ? const SizedBox.expand()
                        : WindowBackdropSlice(
                            cache: dimmed,
                            glass: theme.windowGlassShading,
                            opacity: fade,
                          );
                  },
                ),
                background,
                header,
                // Live glass would blur the panel backing and the dim
                // together. The cards' frost carries both in its overlay.
                WindowBackdropCache(
                  backdrop: cache.backdrop,
                  motion: cache.motion,
                  overlayColor: Color.alphaBlend(
                    theme.panelColor(
                      Color.lerp(
                        context.shellColors.panelBackground,
                        context.shellColors.panelBackgroundBottom,
                        0.5,
                      )!,
                    ),
                    ShadeBackdropScene.dim,
                  ),
                  overlayOpacity: fade,
                  child: child,
                ),
              ],
            ),
          ),
        ),
      );
    }
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
              header,
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
    final contentTop = headerTop + statusHeight + ShadeHeaderClock.statusGap;
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

  // Each page moves as its own layer; a page swipe rebuilds nothing.
  final _pageTranslations = [
    ValueNotifier(Offset.zero),
    ValueNotifier(Offset.zero),
  ];
  late final _pageMotion = Listenable.merge(_pageTranslations);
  double _width = 0;
  int _currentIndex = 0;

  /// Moves the pages to [fraction]. Rebuilds only when the neighbor page
  /// starts or stops being painted.
  void _setDragFraction(double fraction) {
    final wasMoving = _dragFraction != 0;
    _dragFraction = fraction;
    _syncPages();
    if (wasMoving != (fraction != 0) && mounted) setState(() {});
  }

  void _syncPages() {
    for (var index = 0; index < _pageTranslations.length; index++) {
      _pageTranslations[index].value = Offset(
        (index - _currentIndex + _dragFraction) * _width,
        0,
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _settle = AnimationController(vsync: this, duration: Motion.cardSettle)
      ..addListener(() {
        final animation = _settleValue;
        if (animation != null) _setDragFraction(animation.value);
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
    for (final translation in _pageTranslations) {
      translation.dispose();
    }
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
    _setDragFraction(0);
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
    _setDragFraction(
      next.clamp(index == 0 ? -1.0 : 0.0, index == 0 ? 0.0 : 1.0).toDouble(),
    );
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
        _settleValue = null;
        _setDragFraction(0);
      });
  }

  @override
  Widget build(BuildContext context) {
    final direction = Directionality.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final currentIndex = _index(widget.page, direction);
        _width = width;
        _currentIndex = currentIndex;
        _syncPages();
        final pixelRatio = MediaQuery.devicePixelRatioOf(context);
        Widget buildPage(ShadePage page) {
          final index = _index(page, direction);
          final isCurrent = index == currentIndex;
          return Positioned.fill(
            child: CompositedTranslation(
              translation: _pageTranslations[index],
              devicePixelRatio: pixelRatio,
              child: IgnorePointer(
                ignoring: !isCurrent,
                child: ExcludeSemantics(
                  excluding: !isCurrent,
                  // The other page is a full width away until a page drag or
                  // its settle moves it. Keep it laid out, but do not paint
                  // its glass and lists off screen.
                  child: Offstage(
                    offstage: !isCurrent && _dragFraction == 0,
                    child: page == ShadePage.quickSettings
                        ? _ControlCenterPage(progress: widget.progress)
                        : _NotificationCenterPage(
                            progress: widget.progress,
                            closed: widget.closed,
                            active: widget.active && isCurrent,
                          ),
                  ),
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
          child: WindowBackdropMotion(
            motion: _pageMotion,
            child: Stack(
              fit: StackFit.expand,
              children: [
                buildPage(ShadePage.notifications),
                buildPage(ShadePage.quickSettings),
              ],
            ),
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
            // The status bar draws the grown clock and date in this block.
            SizedBox(
              height:
                  ShadeHeaderClock.blockHeight *
                  ShadeReferenceGeometry.inverseScaleOf(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  // Water, like the tiles: it follows the shade and is
                  // gone before the shade is.
                  child: WaterReveal(
                    progress: progress,
                    start: 0.4,
                    span: 0.3,
                    child: const _ShadeHeaderActions(),
                  ),
                ),
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
            SizedBox(
              height:
                  ShadeHeaderClock.blockHeight *
                      ShadeReferenceGeometry.inverseScaleOf(context) +
                  16,
            ),
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
    final profile = ref.watch(
      quickSettingsProvider.select((state) => state.profile),
    );
    final quickSettingsController = ref.read(quickSettingsProvider.notifier);
    final network = ref.watch(networkConnectivityProvider);
    final networkController = ref.read(networkConnectivityProvider.notifier);
    final bluetooth = ref.watch(bluetoothProvider);
    final bluetoothController = ref.read(bluetoothProvider.notifier);
    final notificationPolicy = (
      doNotDisturb: ref.watch(
        desktopNotificationsProvider.select((state) => state.doNotDisturb),
      ),
      loaded:
          ref.watch(shellSettingsSyncStatusProvider).phase ==
          ShellSettingsSyncPhase.ready,
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
    final rotationLock = ref.watch(rotationLockProvider);
    final recording = ref.watch(screenRecordingProvider);
    final presentation = ref.watch(referenceShellPresentationProvider);
    final singleOutput =
        (ref
                .watch(sceneDisplayLayoutProvider(ShellPart.of(context)))
                ?.outputs
                .length ??
            0) <=
        1;
    final footerTiles = [
      if (rotationLock.supported)
        QuickTile(
          icon: rotationLock.locked
              ? Icons.screen_lock_rotation_rounded
              : Icons.screen_rotation_rounded,
          title: l10n.quickSettingsAutoRotate,
          subtitle: rotationLock.error != null
              ? l10n.commonError
              : (rotationLock.locked ? l10n.commonOff : l10n.commonOn),
          active: !rotationLock.locked,
          enabled: !rotationLock.busy,
          busy: rotationLock.busy,
          onTap: () => ref.read(rotationLockProvider.notifier).toggle(),
        ),
      if (recording.available)
        QuickTile(
          icon: recording.recording
              ? Icons.stop_circle_rounded
              : Icons.radio_button_checked_rounded,
          title: recording.recording
              ? l10n.quickSettingsRecording
              : l10n.quickSettingsScreenRecording,
          active: recording.recording,
          enabled: !recording.busy,
          busy: recording.busy,
          onTap: () => ref.read(screenRecordingProvider.notifier).toggle(),
        ),
      if (singleOutput)
        QuickTile(
          icon: Icons.desktop_windows_rounded,
          title: l10n.shellPresentationDesktop,
          subtitle: presentation == ReferenceShellProfile.desktop
              ? l10n.commonOn
              : l10n.commonOff,
          active: presentation == ReferenceShellProfile.desktop,
          wide: true,
          onTap: () {
            ref.read(referenceShellProvider.notifier).closeQuickSettings();
            ref.read(referenceShellPresentationProvider.notifier).toggle();
          },
        ),
    ];
    return QuickSettingsTiles(
      expansionProgress: progress,
      footerTiles: footerTiles,
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
      dnd: notificationPolicy.doNotDisturb,
      dndReady: notificationPolicy.loaded,
      profile: profile,
      onToggleWifi: networkController.toggleWireless,
      onOpenWifi: () {
        ref
            .read(shellPopupControllerProvider.notifier)
            .show(
              keyName: 'wifi-details',
              debugLabel: 'Wi-Fi details',
              builder: (_, handle) => WifiDetailSurface(onClose: handle.close),
            );
      },
      onToggleBluetooth: bluetoothController.togglePower,
      onOpenBluetooth: () {
        ref
            .read(shellPopupControllerProvider.notifier)
            .show(
              keyName: 'bluetooth-details',
              debugLabel: 'Bluetooth details',
              builder: (_, handle) =>
                  BluetoothDetailSurface(onClose: handle.close),
            );
      },
      onToggleDnd: notificationController.toggleDoNotDisturb,
      onCycleProfile: quickSettingsController.cycleProfile,
    );
  }
}

class _BrightnessRangeBar extends ConsumerWidget {
  const _BrightnessRangeBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final output = ref.watch(
      sceneDisplayLayoutProvider(ShellPart.of(context))
          .select((layout) => layout?.mainOutput),
    );
    final brightness = ref.watch(
      displayBrightnessProvider.select(
        (state) => state.levels[output?.monitorId] ?? 0.72,
      ),
    );
    final controller = ref.read(displayBrightnessProvider.notifier);
    return LiquidRangeBar(
      iconScale: ShadeReferenceGeometry.inverseScaleOf(context),
      icon: Icons.brightness_6_rounded,
      value: brightness,
      trackColor: context.shellColors.brightnessTrack,
      onChanged: (value) {
        if (output != null) controller.setLevel(output, value);
      },
      onChangeEnd: (value) {
        if (output != null) controller.commitLevel(output, value);
      },
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
    return LiquidRangeBar(
      iconScale: ShadeReferenceGeometry.inverseScaleOf(context),
      icon: Icons.volume_up_rounded,
      value: volume,
      trackColor: context.shellColors.volumeTrack,
      // The bar shows the level itself: no volume indicator over the shade.
      onChangeStart: controller.beginVolumeInteraction,
      onChanged: controller.setDashboardVolume,
      onChangeEnd: controller.commitDashboardVolume,
    );
  }
}

class _ShadeHeaderActions extends ConsumerWidget {
  const _ShadeHeaderActions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ShadeActions(onOpenPower: () => showPowerSessionSurface(ref));
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
