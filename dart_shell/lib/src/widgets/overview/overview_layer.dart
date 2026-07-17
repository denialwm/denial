import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/widgets.dart';

import '../../models/hypr_window.dart';
import '../../theme/motion.dart';
import '../../theme/tokens.dart';
import '../window_hero.dart';
import 'overview_carousel.dart';
import 'overview_geometry.dart';
import 'overview_grid.dart';

/// The recents / overview layer.
///
/// While the user swipes up, the foreground app follows the finger: its bottom
/// edge tracks the touch point and it shrinks toward its overview card. The
/// release outcome (home / recents / cancel) is decided by the gesture handle;
/// this layer just plays the resulting transition:
///  * recents  -> the controller springs to 1, the app settles into its card,
///                then the portrait carousel or landscape grid arrives;
///  * home     -> the thumbnail flies up off-screen and fades, then
///                [onHomeSettled] hands control back to reveal home;
///  * cancel   -> the controller springs back to 0 and the app fills the screen.
class OverviewLayer extends StatefulWidget {
  const OverviewLayer({
    super.key,
    required this.windows,
    required this.foregroundWindow,
    required this.foregroundObjectId,
    required this.visible,
    required this.swipeDy,
    required this.homeTransitionActive,
    required this.onDismissOverview,
    required this.onDismissWindow,
    required this.onFocusWindow,
    required this.onHomeSettled,
  });

  final List<HyprWindow> windows;
  final HyprWindow? foregroundWindow;
  final int? foregroundObjectId;
  final bool visible;

  /// Live vertical travel of the swipe (<= 0 while pulling up).
  final double swipeDy;
  final bool homeTransitionActive;
  final VoidCallback onDismissOverview;
  final ValueChanged<HyprWindow> onDismissWindow;
  final ValueChanged<HyprWindow> onFocusWindow;
  final VoidCallback onHomeSettled;

  @override
  State<OverviewLayer> createState() => _OverviewLayerState();
}

class _OverviewLayerState extends State<OverviewLayer>
    with TickerProviderStateMixin {
  static const double _pageViewportFraction = 0.72;

  late final AnimationController _controller;
  late final AnimationController _focusController;
  late final AnimationController _homeController;
  late final PageController _pageController;
  HyprWindow? _focusWindow;
  Rect? _focusStartRect;
  Rect? _lastHeroRect;
  HyprWindow? _lastHeroWindow;
  bool? _wasLandscape;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController.unbounded(
      vsync: this,
      value: widget.visible ? 1.0 : 0.0,
    );
    _focusController =
        AnimationController(vsync: this, duration: Motion.focusZoom)
          ..addStatusListener(_handleFocusStatus);
    _homeController =
        AnimationController(vsync: this, duration: Motion.homeFlyAway)
          ..addStatusListener(_handleHomeStatus);
    _pageController = PageController(viewportFraction: _pageViewportFraction);
    if (widget.visible) {
      _scheduleForegroundPageJump();
    }
  }

  @override
  void didUpdateWidget(covariant OverviewLayer oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.homeTransitionActive && !oldWidget.homeTransitionActive) {
      MotionTelemetry.observe(
        _homeController,
        _homeController.forward(from: 0.0),
        'overview_home',
        target: 1.0,
      );
      springTo(
        _controller,
        0.0,
        spring: Motion.gentle,
        telemetryLabel: 'overview_home_settle',
      );
      return;
    }
    if (!widget.homeTransitionActive && oldWidget.homeTransitionActive) {
      _homeController.stop();
      _homeController.value = 0.0;
    }

    if (widget.visible != oldWidget.visible) {
      if (widget.visible) {
        _scheduleForegroundPageJump();
      }
      springTo(
        _controller,
        widget.visible ? 1.0 : 0.0,
        spring: Motion.gentle,
        telemetryLabel: widget.visible ? 'overview_open' : 'overview_close',
      );
      return;
    }

    final isDragging = widget.swipeDy < 0.0;
    final wasDragging = oldWidget.swipeDy < 0.0;
    if (isDragging && !wasDragging) {
      _scheduleForegroundPageJump();
    }

    if (widget.visible) {
      return;
    }

    final t = _dragProgressFor(widget.swipeDy);
    if (t > 0.0) {
      _controller.stop();
      _controller.value = t;
    } else if (wasDragging && _controller.value > 0.0) {
      springTo(
        _controller,
        0.0,
        spring: Motion.gentle,
        telemetryLabel: 'overview_drag_cancel',
      );
    } else if (!_controller.isAnimating && _controller.value != 0.0) {
      _controller.value = 0.0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height;
    if (_wasLandscape == true &&
        !isLandscape &&
        (widget.visible || widget.swipeDy < 0.0)) {
      // The PageView is absent in landscape. Wait until its first portrait
      // frame is attached before restoring the foreground page.
      _scheduleForegroundPageJump();
    }
    _wasLandscape = isLandscape;
  }

  @override
  void dispose() {
    _pageController.dispose();
    _homeController.dispose();
    _focusController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: Listenable.merge([
          _controller,
          _focusController,
          _homeController,
        ]),
        builder: (context, child) {
          final progress = unit(_controller.value);
          final homeActive = widget.homeTransitionActive;
          if (progress <= 0.001 && !widget.visible && !homeActive) {
            return const SizedBox.expand();
          }

          final viewSize = MediaQuery.sizeOf(context);
          final heroWindow =
              homeActive ? null : _foregroundHeroWindow(progress);

          final overviewContent = widget.windows.isEmpty
              ? _EmptyOverviewState(progress: progress)
              : viewSize.width > viewSize.height
                  ? OverviewGrid(
                      windows: widget.windows,
                      progress: progress,
                      foregroundObjectId: widget.foregroundObjectId,
                      onDismissWindow: widget.onDismissWindow,
                      onFocusWindow: _startFocusTransition,
                    )
                  : OverviewCarousel(
                      windows: widget.windows,
                      progress: progress,
                      pageController: _pageController,
                      foregroundObjectId: widget.foregroundObjectId,
                      onDismissWindow: widget.onDismissWindow,
                      onFocusWindow: _startFocusTransition,
                    );

          return Stack(
            fit: StackFit.expand,
            children: [
              IgnorePointer(
                ignoring: progress < 0.96 || _focusWindow != null,
                child: _OverviewScrim(
                  progress: progress,
                  onTap: widget.onDismissOverview,
                ),
              ),
              if (_focusWindow == null && !homeActive)
                IgnorePointer(
                  ignoring: progress < 0.96,
                  child: overviewContent,
                ),
              if (heroWindow != null)
                _buildForegroundHero(heroWindow, progress, viewSize),
              if (homeActive && _lastHeroWindow != null)
                _buildHomeFlyAway(_lastHeroWindow!, viewSize),
              if (_focusWindow != null && _focusStartRect != null)
                _FocusZoomOverlay(
                  controller: _focusController,
                  window: _focusWindow!,
                  startRect: _focusStartRect!,
                ),
            ],
          );
        },
      ),
    );
  }

  /// The finger-following foreground hero. Interpolating the rect *linearly*
  /// keeps the bottom edge locked to the finger (progress is fed as travel /
  /// reference distance, so `bottom = screenHeight - travel`).
  Widget _buildForegroundHero(
    HyprWindow window,
    double progress,
    Size viewSize,
  ) {
    final cardRect = _cardRectFor(viewSize);
    final rect = Rect.lerp(Offset.zero & viewSize, cardRect, progress)!;
    _lastHeroRect = rect;
    _lastHeroWindow = window;
    final radius = lerpDouble(0.0, ShellRadii.window, progress)!;
    final border = Color.lerp(
      const Color(0x00ffffff),
      kWindowHairline,
      progress,
    );

    return Positioned.fromRect(
      rect: rect,
      child: IgnorePointer(
        child:
            WindowSurface(window: window, radius: radius, borderColor: border),
      ),
    );
  }

  /// The app flying up and fading away as home is revealed beneath it.
  Widget _buildHomeFlyAway(HyprWindow window, Size viewSize) {
    final start = _lastHeroRect ?? (Offset.zero & viewSize);
    final t = Motion.standard.transform(unit(_homeController.value));
    final exit = Rect.fromCenter(
      center: start.center.translate(0.0, -viewSize.height * 0.55),
      width: start.width * 0.85,
      height: start.height * 0.85,
    );
    final rect = Rect.lerp(start, exit, t)!;

    return Positioned.fromRect(
      rect: rect,
      child: IgnorePointer(
        child: Opacity(
          opacity: 1.0 - t,
          child: WindowSurface(window: window, radius: ShellRadii.window),
        ),
      ),
    );
  }

  Rect _cardRectFor(Size viewSize) {
    if (viewSize.width > viewSize.height && widget.windows.isNotEmpty) {
      final layout = landscapeOverviewLayoutFor(
        viewSize: viewSize,
        padding: MediaQuery.paddingOf(context),
        itemCount: widget.windows.length,
        aspect: viewAspectFor(viewSize),
      );
      final foregroundIndex = widget.windows.indexWhere(
        (window) => window.objectId == widget.foregroundObjectId,
      );
      if (foregroundIndex >= 0) {
        return layout.previewRectAt(0);
      }
    }

    final cardSize = cardSizeFor(
      constraints: BoxConstraints.tight(viewSize),
      padding: MediaQuery.paddingOf(context),
      aspect: viewAspectFor(viewSize),
    );
    return centerPreviewRectFor(viewSize, cardSize);
  }

  /// Maps the live swipe travel to overview progress so that the app's bottom
  /// edge stays under the finger (reaching the card exactly at progress 1).
  double _dragProgressFor(double swipeDy) {
    if (swipeDy >= 0.0) {
      return 0.0;
    }
    final size = MediaQuery.sizeOf(context);
    if (size.height <= 0) {
      return 0.0;
    }
    return (-swipeDy / _referenceTravel(size)).clamp(0.0, 1.0).toDouble();
  }

  double _referenceTravel(Size size) {
    final window = widget.foregroundWindow;
    if (window == null || !window.isUserApp) {
      return size.height * 0.45;
    }
    return math.max(1.0, size.height - _cardRectFor(size).bottom);
  }

  HyprWindow? _foregroundHeroWindow(double progress) {
    final window = widget.foregroundWindow;
    if ((!widget.visible && widget.swipeDy >= 0.0) ||
        window == null ||
        !window.isUserApp ||
        progress <= 0.001 ||
        progress >= 0.995) {
      return null;
    }

    for (final candidate in widget.windows) {
      if (candidate.objectId == window.objectId) {
        return candidate;
      }
    }
    return null;
  }

  void _handleFocusStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) {
      return;
    }
    final window = _focusWindow;
    if (window == null) {
      return;
    }

    _controller.value = 0.0;
    widget.onFocusWindow(window);
    if (mounted) {
      setState(() {
        _focusWindow = null;
        _focusStartRect = null;
      });
    }
  }

  void _handleHomeStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && widget.homeTransitionActive) {
      widget.onHomeSettled();
    }
  }

  void _startFocusTransition(HyprWindow window, Rect startRect) {
    if (_focusWindow != null) {
      return;
    }
    setState(() {
      _focusWindow = window;
      _focusStartRect = startRect;
    });
    MotionTelemetry.observe(
      _focusController,
      _focusController.forward(from: 0.0),
      'overview_focus',
      target: 1.0,
    );
  }

  void _scheduleForegroundPageJump() {
    final objectId = widget.foregroundObjectId;
    if (objectId == null) {
      return;
    }
    final index =
        widget.windows.indexWhere((window) => window.objectId == objectId);
    if (index < 0) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageController.hasClients) {
        return;
      }
      _pageController.jumpToPage(index);
    });
  }
}

class _OverviewScrim extends StatelessWidget {
  const _OverviewScrim({required this.progress, required this.onTap});

  final double progress;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ColoredBox(
        color: Color.lerp(
          const Color(0x00000000),
          ShellColors.overviewScrim,
          progress,
        )!,
      ),
    );
  }
}

class _EmptyOverviewState extends StatelessWidget {
  const _EmptyOverviewState({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    final intro = Motion.standard.transform(progress);
    return Center(
      child: Transform.translate(
        offset: Offset(0, lerpDouble(28.0, 0.0, intro)!),
        child: Opacity(
          opacity: unit(progress * 1.3),
          child: const Text(
            'No windows',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: ShellColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ),
    );
  }
}

/// Morphs a tapped overview card back to full screen before focusing it.
class _FocusZoomOverlay extends StatelessWidget {
  const _FocusZoomOverlay({
    required this.controller,
    required this.window,
    required this.startRect,
  });

  final AnimationController controller;
  final HyprWindow window;
  final Rect startRect;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, child) {
            final viewSize = MediaQuery.sizeOf(context);
            return Stack(
              fit: StackFit.expand,
              children: [
                WindowHero(
                  window: window,
                  beginRect: startRect,
                  endRect: Offset.zero & viewSize,
                  progress: controller.value,
                  beginRadius: ShellRadii.window,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
