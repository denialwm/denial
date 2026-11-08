import 'package:denial_desktop/src/state/reference_shell_controller.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:denial_flutter_sdk/popups.dart';
import 'package:flutter/material.dart'
    show
        Colors,
        Icons,
        RoundedRectSliderTrackShape,
        RoundSliderOverlayShape,
        RoundSliderThumbShape,
        Slider,
        SliderTheme;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/environment.dart';
import 'package:denial_flutter_sdk/glass_configuration.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/system_services.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/state.dart';

import '../../state/quick_settings.dart';
import '../connectivity/audio_output_surface.dart';
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
import '../../settings/settings_application.dart';

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

/// The wide split layout, measured in real logical pixels.
bool _wideShade(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return size.width >= 900;
}

/// The same breakpoint from inside the shade's reference geometry.
bool _splitShade(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  final scale = ShadeReferenceGeometry.scaleOf(context);
  return size.width * scale >= 900;
}

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
        cached:
            context.shellTheme.backdropBlurEnabled &&
            _frostedShadeBackdrop(context) != null,
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
                  header: ShadeHeaderStatusLayer(
                    progress: progress,
                    collapsed: _wideShade(context),
                  ),
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
    final cache = theme.backdropBlurEnabled
        ? _frostedShadeBackdrop(context)
        : null;
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
              // A translucent panel left sharp under an open app is never
              // acceptable, even when the theme disables backdrop blur.
              force: !theme.backdropBlurEnabled,
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
    // The split keeps a regular status row (52 px in the redesign) and then
    // the shade's own top padding (34 px), both in reference units.
    final contentTop = _splitShade(context)
        ? 35.0
        : headerTop + statusHeight + ShadeHeaderClock.statusGap;
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
        // Lay out in reference units, but decide from the real logical size:
        // a landscape tablet gets the two columns while phones and portrait
        // screens keep the swipe pager.
        final logicalWidth = width * ShadeReferenceGeometry.scaleOf(context);
        final tablet = logicalWidth >= 900;
        // Side by side only when the width is there; a portrait tablet
        // swipes between the same two redesigned pages instead.
        if (tablet && width > constraints.maxHeight) {
          return Row(
            children: [
              Expanded(
                flex: 40,
                child: _NotificationCenterPage(
                  progress: widget.progress,
                  closed: widget.closed,
                  active: widget.active,
                  designLayout: true,
                ),
              ),
              Expanded(
                flex: 60,
                child: _ControlCenterPage(
                  progress: widget.progress,
                  designLayout: true,
                ),
              ),
            ],
          );
        }
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
                        ? _ControlCenterPage(
                            progress: widget.progress,
                            designLayout: tablet,
                          )
                        : _NotificationCenterPage(
                            progress: widget.progress,
                            closed: widget.closed,
                            active: widget.active && isCurrent,
                            designLayout: tablet,
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
  const _ControlCenterPage({required this.progress, this.designLayout = false});

  final Animation<double> progress;

  /// Wide split layout: three columns of stacked tiles and card sliders,
  /// instead of the four-column capsule grid used by the pager.
  final bool designLayout;

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
              height:
                  ShadeHeaderClock.blockHeight *
                  ShadeReferenceGeometry.inverseScaleOf(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (designLayout)
                      Expanded(child: _ShadeClockHeader(progress: progress))
                    else
                      const Spacer(),
                    // Water, like the tiles: it follows the shade and is
                    // gone before the shade is.
                    WaterReveal(
                      progress: progress,
                      start: 0.4,
                      span: 0.3,
                      child: const _ShadeHeaderActions(),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                primary: false,
                padding: const EdgeInsets.fromLTRB(28, 0, 28, 24),
                child: RepaintBoundary(
                  child: _QuickSettingsTilesSection(
                    progress: progress,
                    designLayout: designLayout,
                  ),
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
    this.designLayout = false,
  });

  final Animation<double> progress;
  final bool closed;
  final bool active;

  /// Split layout: a rounded panel with a title and a clear-all action,
  /// starting at the top because the clock lives in the control column.
  final bool designLayout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final padding = MediaQuery.paddingOf(context);
    final inverse = ShadeReferenceGeometry.inverseScaleOf(context);
    final empty = ref.watch(
      desktopNotificationsProvider.select((state) => state.history.isEmpty),
    );
    final history = Stack(
      fit: StackFit.expand,
      children: [
        MobileNotificationHistory(
          progress: progress,
          closed: closed,
          active: active,
        ),
        if (empty) const _EmptyNotifications(),
      ],
    );
    return ShadeDismissGesture(
      progress: progress,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          padding.left + (designLayout ? 20 * inverse : 0),
          0,
          padding.right + (designLayout ? 20 * inverse : 0),
          0,
        ),
        child: Column(
          children: [
            SizedBox(
              height: designLayout
                  ? 0
                  : ShadeHeaderClock.blockHeight * inverse + 16,
            ),
            Expanded(
              child: designLayout
                  ? WaterReveal(
                      progress: progress,
                      start: 0.33,
                      span: 0.4,
                      child: _NotificationPanel(child: history),
                    )
                  : history,
            ),
            SizedBox(height: math.max(4, padding.bottom)),
          ],
        ),
      ),
    );
  }
}

class _NotificationPanel extends ConsumerWidget {
  const _NotificationPanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShellTheme.of(context);
    final glass = theme.transparencyMode == ShellTransparencyMode.glass;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.cardColor(context.shellColors.tileOff),
        borderRadius: theme.borderRadius(12),
        border: glass
            ? null
            : Border.all(color: context.shellColors.hairlineSoft),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(9, 9, 9, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  context.l10n.notificationsTitle,
                  style: TextStyle(
                    color: context.shellColors.panelText,
                    fontSize: 20,
                    height: 1.1,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                    decoration: TextDecoration.none,
                  ),
                ),
                const Spacer(),
                _ClearAllButton(
                  onPressed: () => ref
                      .read(desktopNotificationsProvider.notifier)
                      .clearAll(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class _ClearAllButton extends StatelessWidget {
  const _ClearAllButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: context.l10n.notificationsClearAll,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Text(
            context.l10n.clipboardClearAll,
            style: TextStyle(
              color: context.shellColors.textTertiary,
              fontSize: 14,
              height: 1.1,
              fontWeight: FontWeight.w500,
              letterSpacing: 0,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ),
    );
  }
}

class _ShadeClockHeader extends ConsumerWidget {
  const _ShadeClockHeader({required this.progress});

  final Animation<double> progress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).value ?? DateTime.now();
    final inverse = ShadeReferenceGeometry.inverseScaleOf(context);
    return WaterReveal(
      progress: progress,
      start: 0.36,
      span: 0.3,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            localizedTime(context, now),
            style: TextStyle(
              color: context.shellColors.panelText,
              fontSize: ShadeHeaderClock.expandedFontSize,
              height: 0.95,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.5,
              decoration: TextDecoration.none,
            ),
          ),
          SizedBox(height: ShadeHeaderClock.dateGap * inverse),
          Text(
            localizedLongDate(context, now),
            maxLines: 1,
            style: TextStyle(
              color: context.shellColors.textSecondary,
              fontSize: ShadeHeaderClock.dateFontSize,
              height: 1,
              fontWeight: FontWeight.w500,
              decoration: TextDecoration.none,
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickSettingsTilesSection extends ConsumerWidget {
  const _QuickSettingsTilesSection({
    required this.progress,
    this.designLayout = false,
  });

  final Animation<double> progress;
  final bool designLayout;

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
          stacked: designLayout,
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
          stacked: designLayout,
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
          stacked: designLayout,
          onTap: () {
            ref.read(referenceShellProvider.notifier).closeQuickSettings();
            ref.read(referenceShellPresentationProvider.notifier).toggle();
          },
        ),
    ];
    return QuickSettingsTiles(
      expansionProgress: progress,
      footerTiles: footerTiles,
      designLayout: designLayout,
      mobileDataTile: MobileDataTile(stacked: designLayout),
      airplaneTile: _AirplaneModeTile(stacked: designLayout),
      orientationLockTile: QuickTile(
        icon: Icons.screen_lock_rotation_rounded,
        title: l10n.quickSettingsOrientationLock,
        subtitle: rotationLock.locked ? l10n.commonOn : l10n.commonOff,
        active: rotationLock.locked,
        enabled: rotationLock.supported && !rotationLock.busy,
        busy: rotationLock.busy,
        stacked: designLayout,
        onTap: () => ref.read(rotationLockProvider.notifier).toggle(),
      ),
      autoRotateTile: QuickTile(
        icon: Icons.screen_rotation_rounded,
        title: l10n.quickSettingsAutoRotate,
        subtitle: rotationLock.locked ? l10n.commonOff : l10n.commonOn,
        active: !rotationLock.locked,
        enabled: rotationLock.supported && !rotationLock.busy,
        busy: rotationLock.busy,
        stacked: designLayout,
        onTap: () => ref.read(rotationLockProvider.notifier).toggle(),
      ),
      desktopViewTile: QuickTile(
        icon: Icons.desktop_windows_rounded,
        title: l10n.shellPresentationDesktop,
        subtitle: presentation == ReferenceShellProfile.desktop
            ? l10n.commonOn
            : l10n.commonOff,
        active: presentation == ReferenceShellProfile.desktop,
        stacked: designLayout,
        onTap: () {
          ref.read(referenceShellProvider.notifier).closeQuickSettings();
          ref.read(referenceShellPresentationProvider.notifier).toggle();
        },
      ),
      brightnessControl: _BrightnessRangeBar(horizontal: designLayout),
      volumeControl: _VolumeRangeBar(horizontal: designLayout),
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
  const _BrightnessRangeBar({this.horizontal = false});

  final bool horizontal;

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
    void changed(double value) {
      if (output != null) controller.setLevel(output, value);
    }

    void committed(double value) {
      if (output != null) controller.commitLevel(output, value);
    }

    if (horizontal) {
      return _HorizontalRangeCard(
        icon: Icons.brightness_6_rounded,
        label: context.l10n.brightnessTitle,
        value: brightness,
        onChanged: changed,
        onChangeEnd: committed,
      );
    }
    return LiquidRangeBar(
      iconScale: ShadeReferenceGeometry.inverseScaleOf(context),
      icon: Icons.brightness_6_rounded,
      value: brightness,
      trackColor: context.shellColors.brightnessTrack,
      onChanged: changed,
      onChangeEnd: committed,
    );
  }
}

class _VolumeRangeBar extends ConsumerWidget {
  const _VolumeRangeBar({this.horizontal = false});

  final bool horizontal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final volume = ref.watch(
      quickSettingsProvider.select((state) => state.volume),
    );
    final controller = ref.read(quickSettingsProvider.notifier);
    if (horizontal) {
      return _HorizontalRangeCard(
        icon: Icons.volume_up_rounded,
        label: context.l10n.commonVolume,
        value: volume,
        onSecondaryTap: () {
          ref
              .read(shellPopupControllerProvider.notifier)
              .show(
                keyName: 'audio-output',
                debugLabel: 'Audio output',
                builder: (_, handle) =>
                    AudioOutputSurface(onClose: handle.close),
              );
        },
        onChangeStart: controller.beginVolumeInteraction,
        onChanged: controller.setDashboardVolume,
        onChangeEnd: controller.commitDashboardVolume,
      );
    }
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

/// A full-width slider card for the wide split layout: label and percentage
/// above a rounded track, matching the redesign.
class _HorizontalRangeCard extends StatelessWidget {
  const _HorizontalRangeCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
    required this.onChangeEnd,
    this.onChangeStart,
    this.onSecondaryTap,
  });

  final IconData icon;
  final String label;
  final double value;

  /// Opens the output picker; renders a compact chevron button.
  final VoidCallback? onSecondaryTap;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final VoidCallback? onChangeStart;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final glass = theme.transparencyMode == ShellTransparencyMode.glass;
    final inverse = ShadeReferenceGeometry.inverseScaleOf(context);
    final clamped = value.clamp(0.0, 1.0);
    final start = onChangeStart;
    final accent = theme.accentPalette.primary;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.cardColor(context.shellColors.tileOff),
        borderRadius: theme.borderRadius(10),
        border: glass
            ? null
            : Border.all(color: context.shellColors.hairlineSoft),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
        child: Row(
          children: [
            Icon(
              icon,
              size: 20 * inverse,
              color: context.shellColors.panelText,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: context.shellColors.panelText,
                fontSize: 14.5,
                height: 1.1,
                fontWeight: FontWeight.w600,
                letterSpacing: 0,
                decoration: TextDecoration.none,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SizedBox(
                height: 32,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    activeTrackColor: accent,
                    inactiveTrackColor: Colors.white.withValues(alpha: 0.18),
                    thumbColor: Colors.white,
                    overlayColor: accent.withValues(alpha: 0.16),
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 5.5,
                      elevation: 2,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 14,
                    ),
                    trackShape: const RoundedRectSliderTrackShape(),
                  ),
                  child: Slider(
                    value: clamped,
                    onChangeStart: start == null ? null : (_) => start(),
                    onChanged: onChanged,
                    onChangeEnd: onChangeEnd,
                  ),
                ),
              ),
            ),
            if (onSecondaryTap case final open?) ...[
              const SizedBox(width: 8),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: open,
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: context.shellColors.surfaceContainerHigh,
                    borderRadius: theme.borderRadius(8),
                  ),
                  child: Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: context.shellColors.panelText,
                  ),
                ),
              ),
            ],
            const SizedBox(width: 8),
            SizedBox(
              width: 38,
              child: Text(
                '${(clamped * 100).round()}%',
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: context.shellColors.textTertiary,
                  fontSize: 12.5,
                  height: 1.1,
                  letterSpacing: 0,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShadeHeaderActions extends ConsumerWidget {
  const _ShadeHeaderActions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ShadeActions(
      onOpenPower: () {
        final openingContext = context;
        ref.read(referenceShellProvider.notifier).closeQuickSettings();
        // Let the shade finish sliding away before the panel appears.
        Future<void>.delayed(const Duration(milliseconds: 260), () {
          if (openingContext.mounted) showPowerSessionSurface(ref);
        });
      },
      onScreenshot: () {
        ref.read(referenceShellProvider.notifier).closeQuickSettings();
        unawaited(ref.read(quickSettingsProvider.notifier).takeScreenshot());
      },
      onOpenSettings: () {
        final shell = ref.read(referenceShellProvider.notifier);
        shell.closeQuickSettings();
        for (final window in ref.read(referenceShellProvider).openAppWindows) {
          if (isDenialSettingsApplicationId(window.appId)) {
            shell.focusWindow(window);
            return;
          }
        }
        final environment = ref.read(startupEnvironmentProvider);
        final binary = environment['DENIAL_SETTINGS_BINARY']?.trim();
        ref.read(denialBridgeProvider).launchApplication(<String>[
          binary == null || binary.isEmpty ? 'denial-settings' : binary,
        ]);
      },
    );
  }
}

class _AirplaneModeTile extends ConsumerStatefulWidget {
  const _AirplaneModeTile({this.stacked = false});

  final bool stacked;

  @override
  ConsumerState<_AirplaneModeTile> createState() => _AirplaneModeTileState();
}

class _AirplaneModeTileState extends ConsumerState<_AirplaneModeTile> {
  bool _busy = false;
  bool _savedWifi = true;
  bool _savedBluetooth = true;
  bool _savedMobile = false;

  Future<void> _setRadios({
    required bool wifi,
    required bool bluetooth,
    required bool mobile,
    required bool hasModem,
  }) async {
    setState(() => _busy = true);
    try {
      final network = ref.read(networkConnectivityProvider.notifier);
      final bluetoothController = ref.read(bluetoothProvider.notifier);
      final mobileService = ref.read(mobileNetworkServiceProvider);
      final wifiOn = ref
          .read(networkConnectivityProvider)
          .snapshot
          .wirelessEnabled;
      final bluetoothOn = ref.read(bluetoothProvider).powered;
      final mobileOn = ref.read(mobileNetworkProvider).value?.enabled ?? false;
      try {
        if (wifiOn != wifi) await network.setWirelessEnabled(wifi);
      } on Object {
        // Keep switching the other radios when one service is unavailable.
      }
      try {
        if (bluetoothOn != bluetooth) {
          await bluetoothController.togglePower();
        }
      } on Object {
        // Keep switching the other radios.
      }
      if (hasModem) {
        try {
          if (mobileOn != mobile) {
            await mobileService.setEnabled(mobile);
          }
        } on Object {
          // The modem may be busy with a call or a pending transaction.
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final network = ref.watch(networkConnectivityProvider);
    final bluetooth = ref.watch(bluetoothProvider);
    final mobile =
        ref.watch(mobileNetworkProvider).value ?? const MobileNetworkSnapshot();
    final l10n = context.l10n;
    final wifiOn =
        network.snapshot.wirelessEnabled &&
        network.snapshot.wifiDeviceAvailable;
    final bluetoothOn = bluetooth.powered && bluetooth.available;
    final hasModem = mobile.modemPath != null;
    final mobileOn = mobile.enabled;
    final active = !wifiOn && !bluetoothOn && (!hasModem || !mobileOn);
    return QuickTile(
      icon: active
          ? Icons.airplanemode_active_rounded
          : Icons.airplanemode_inactive_rounded,
      title: l10n.quickSettingsAirplaneMode,
      subtitle: active ? l10n.commonOn : l10n.commonOff,
      active: active,
      enabled: !_busy,
      busy: _busy,
      stacked: widget.stacked,
      onTap: () {
        if (active) {
          _setRadios(
            wifi: _savedWifi,
            bluetooth: _savedBluetooth,
            mobile: _savedMobile,
            hasModem: hasModem,
          );
        } else {
          _savedWifi = wifiOn;
          _savedBluetooth = bluetoothOn;
          _savedMobile = mobileOn;
          _setRadios(
            wifi: false,
            bluetooth: false,
            mobile: false,
            hasModem: hasModem,
          );
        }
      },
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
