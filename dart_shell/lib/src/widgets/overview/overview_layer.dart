import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show Drag;

import '../../models/denial_window.dart';
import '../../theme/motion.dart';
import '../../theme/shell_theme.dart';
import '../window_hero.dart';
import '../retained_window_motion.dart';
import '../retained_translation.dart';
import 'overview_carousel.dart';
import 'overview_geometry.dart';
import 'overview_page_controller.dart';
import 'overview_grid.dart';
import 'overview_chrome.dart';
import 'overview_focus_overlay.dart';

/// The recents / overview layer.
///
/// While the user swipes up, the foreground app follows the finger: its bottom
/// edge tracks the touch point and it shrinks toward its overview card. The
/// release outcome (home / recents / cancel) is decided by the gesture handle;
/// this layer just plays the resulting transition:
///  * recents  -> the app settles into its card as the other previews arrive;
///  * home     -> the thumbnail flies up off-screen, then
///                [onHomeSettled] hands control back to reveal home;
///  * cancel   -> the controller returns to 0 and the app fills the screen.
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
    this.onPresentationChanged,
  });

  final List<DenialWindow> windows;
  final DenialWindow? foregroundWindow;
  final int? foregroundObjectId;
  final bool visible;

  /// Live vertical travel of the swipe (<= 0 while pulling up).
  final ValueListenable<double> swipeDy;
  final bool homeTransitionActive;
  final VoidCallback onDismissOverview;
  final ValueChanged<DenialWindow> onDismissWindow;
  final ValueChanged<DenialWindow> onFocusWindow;
  final VoidCallback onHomeSettled;
  final ValueChanged<bool>? onPresentationChanged;

  @override
  State<OverviewLayer> createState() => _OverviewLayerState();
}

class _OverviewLayerState extends State<OverviewLayer>
    with TickerProviderStateMixin {
  late final AnimationController _controller;
  late final AnimationController _focusController;
  late final AnimationController _homeController;
  late PageController _pageController;
  double? _pageViewportFraction;
  DenialWindow? _focusWindow;
  Rect? _focusStartRect;
  Rect? _lastHeroRect;
  double _lastSwipeDy = 0;
  bool _shown = false;
  bool _heroVisible = false;
  DenialWindow? _lastHeroWindow;
  late List<DenialWindow> _windows;
  double _dragOrigin = 0;
  bool _heroPressed = false;
  final _heroKey = GlobalKey();
  final _heroPageOffset = ValueNotifier(Offset.zero);
  Drag? _pageDrag;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      value: widget.visible ? 1.0 : 0.0,
    )..addListener(_updatePhase);
    _shown = widget.visible;
    _syncWindows(resetOrder: true);
    widget.swipeDy.addListener(_handleDrag);
    _focusController = AnimationController(
      vsync: this,
      duration: Motion.focusZoom,
    )..addStatusListener(_handleFocusStatus);
    _homeController = AnimationController(
      vsync: this,
      duration: Motion.homeFlyAway,
    )..addStatusListener(_handleHomeStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final fraction = overviewPageViewportFractionFor(
      MediaQuery.sizeOf(context),
      MediaQuery.paddingOf(context),
    );
    if (_pageViewportFraction == fraction) return;
    final previous = _pageViewportFraction == null ? null : _pageController;
    final page = previous?.hasClients == true
        ? (previous!.page ?? previous.initialPage.toDouble()).round()
        : previous?.initialPage ?? 0;
    _cancelPageDrag();
    previous?.removeListener(_syncHeroPageOffset);
    _pageViewportFraction = fraction;
    _pageController = OverviewPageController(
      initialPage: page,
      viewportFraction: fraction,
      keepPage: false,
    )..addListener(_syncHeroPageOffset);
    // PageView detaches the previous position during this frame's build.
    if (previous != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
    }
  }

  @override
  void didUpdateWidget(covariant OverviewLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.swipeDy != oldWidget.swipeDy) {
      oldWidget.swipeDy.removeListener(_handleDrag);
      widget.swipeDy.addListener(_handleDrag);
    }
    _syncWindows(resetOrder: !_shown && !widget.homeTransitionActive);
    if (_focusWindow != null &&
        (!widget.visible ||
            !_windows.any(
              (window) => window.objectId == _focusWindow!.objectId,
            ))) {
      _cancelFocus();
    }

    if (widget.homeTransitionActive && !oldWidget.homeTransitionActive) {
      final viewSize = MediaQuery.sizeOf(context);
      _lastHeroRect = Rect.lerp(
        Offset.zero & viewSize,
        _cardRectFor(viewSize),
        _controller.value,
      );
      _lastHeroWindow = oldWidget.foregroundWindow ?? _lastHeroWindow;
      _cancelFocus();
      MotionTelemetry.observe(
        _homeController,
        _homeController.forward(from: 0.0),
        'overview_home',
        target: 1.0,
      );
      _settleTo(0);
      return;
    }
    if (!widget.homeTransitionActive && oldWidget.homeTransitionActive) {
      _homeController.stop();
      _homeController.value = 0.0;
    }

    if (widget.visible != oldWidget.visible) {
      if (!widget.visible) _cancelPageDrag();
      _settleTo(widget.visible ? 1 : 0);
      return;
    }

    _handleDrag();
  }

  void _handleDrag() {
    final dy = widget.swipeDy.value;
    final wasDragging = _lastSwipeDy < 0;
    _lastSwipeDy = dy;
    if (widget.visible || widget.homeTransitionActive || _focusWindow != null) {
      return;
    }
    if (dy < 0 && !wasDragging) {
      _dragOrigin = _controller.value;
      _lastHeroWindow = widget.foregroundWindow;
      if (!_shown) _syncWindows(resetOrder: true);
    }
    final t = _dragProgressFor(dy);
    if (t > 0) {
      _controller.stop();
      _controller.value = (_dragOrigin + t).clamp(0.0, 1.0);
    } else if (wasDragging && _controller.value > 0) {
      _settleTo(0);
    }
  }

  void _settleTo(double target) {
    final duration = target == 1 ? Motion.overviewOpen : Motion.overviewClose;
    final travel = (target - _controller.value).abs();
    _controller.animateTo(
      target,
      duration: Duration(
        milliseconds: (duration.inMilliseconds * travel).round().clamp(
          90,
          duration.inMilliseconds,
        ),
      ),
      curve: Motion.standard,
    );
  }

  void _updatePhase() {
    // Keep the final frame mounted until the entire carousel is off-screen.
    final shown = _controller.value > 0;
    final hero = shown && (_controller.value < 1 || _heroPressed);
    if (shown == _shown && hero == _heroVisible) return;
    if (shown != _shown) widget.onPresentationChanged?.call(shown);
    if (!shown) _heroPageOffset.value = Offset.zero;
    setState(() {
      _shown = shown;
      _heroVisible = hero;
    });
  }

  @override
  void dispose() {
    widget.swipeDy.removeListener(_handleDrag);
    _pageDrag?.cancel();
    _pageController.dispose();
    _heroPageOffset.dispose();
    _homeController.dispose();
    _focusController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewSize = MediaQuery.sizeOf(context);
    final homeActive = widget.homeTransitionActive;
    if (!_shown && !widget.visible && !homeActive) {
      return const SizedBox.shrink();
    }
    final heroWindow = homeActive || _focusWindow != null
        ? null
        : _foregroundHeroWindow(_controller.value);
    final overviewContent = _windows.isEmpty
        ? AnimatedBuilder(
            animation: _controller,
            builder: (context, _) =>
                EmptyOverviewState(progress: unit(_controller.value)),
          )
        : viewSize.width > viewSize.height
        ? OverviewGrid(
            windows: _windows,
            progress: _controller,
            foregroundObjectId: widget.foregroundObjectId,
            foregroundInHero: heroWindow != null,
            focusingObjectId: _focusWindow?.objectId,
            onDismissWindow: widget.onDismissWindow,
            onFocusWindow: _startFocusTransition,
          )
        : OverviewCarousel(
            windows: _windows,
            progress: _controller,
            focusProgress: _focusController,
            pageController: _pageController,
            foregroundObjectId: widget.foregroundObjectId,
            foregroundInHero: heroWindow != null,
            focusingObjectId: _focusWindow?.objectId,
            onDismissWindow: widget.onDismissWindow,
            onFocusWindow: _startFocusTransition,
          );

    final fullRect = Offset.zero & viewSize;
    final cardRect = _cardRectFor(viewSize);
    if (heroWindow != null) _lastHeroWindow = heroWindow;
    return Positioned.fill(
      child: GestureDetector(
        // PageView handles ordinary paging. This ancestor also accepts a swipe
        // that begins on the moving foreground app during overview entry.
        onHorizontalDragStart:
            widget.visible &&
                _heroVisible &&
                _focusWindow == null &&
                viewSize.width <= viewSize.height
            ? _startPageDrag
            : null,
        onHorizontalDragUpdate: (details) => _pageDrag?.update(details),
        onHorizontalDragEnd: _endPageDrag,
        onHorizontalDragCancel: _cancelPageDrag,
        child: Stack(
          fit: StackFit.expand,
          children: [
            IgnorePointer(
              ignoring: !widget.visible || _focusWindow != null,
              child: OverviewScrim(
                progress: _controller,
                fadingOut: _focusWindow != null,
                onTap: widget.onDismissOverview,
              ),
            ),
            if (!homeActive)
              IgnorePointer(
                ignoring: !widget.visible || _focusWindow != null,
                child: overviewContent,
              ),
            if (heroWindow != null)
              RetainedTranslation(
                translation: _heroPageOffset,
                child: IgnorePointer(
                  ignoring: !widget.visible,
                  child: RetainedWindowMotion(
                    progress: _controller,
                    begin: fullRect,
                    end: cardRect,
                    endRadius: context.shellTheme.windowRadius,
                    child: Listener(
                      onPointerDown: (_) => _heroPressed = true,
                      onPointerCancel: (_) => _releaseHero(),
                      child: GestureDetector(
                        key: _heroKey,
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _selectHero(heroWindow),
                        onTapCancel: _releaseHero,
                        child: WindowSurface(window: heroWindow),
                      ),
                    ),
                  ),
                ),
              ),
            if (homeActive && _lastHeroWindow != null)
              IgnorePointer(
                child: RetainedWindowMotion(
                  progress: _homeController,
                  begin: _lastHeroRect ?? fullRect,
                  end: (_lastHeroRect ?? fullRect).shift(
                    Offset(0, -(_lastHeroRect ?? fullRect).bottom - 32),
                  ),
                  beginRadius: context.shellTheme.windowRadius,
                  endRadius: context.shellTheme.windowRadius,
                  curve: Motion.standard,
                  child: WindowSurface(window: _lastHeroWindow!),
                ),
              ),
            if (_focusWindow != null && _focusStartRect != null)
              OverviewFocusOverlay(
                controller: _focusController,
                window: _focusWindow!,
                startRect: _focusStartRect!,
              ),
          ],
        ),
      ),
    );
  }

  Rect _cardRectFor(Size viewSize) {
    if (viewSize.width > viewSize.height && _windows.isNotEmpty) {
      final layout = landscapeOverviewLayoutFor(
        viewSize: viewSize,
        padding: MediaQuery.paddingOf(context),
        itemCount: _windows.length,
        aspect: viewAspectFor(viewSize),
      );
      final foregroundIndex = _windows.indexWhere(
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

  DenialWindow? _foregroundHeroWindow(double progress) {
    final window = widget.foregroundWindow;
    if (window == null ||
        !window.isUserApp ||
        progress <= 0 ||
        (progress >= 1 && !_heroPressed)) {
      return null;
    }

    for (final candidate in _windows) {
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

  void _startFocusTransition(DenialWindow window, Rect startRect) {
    if (_focusWindow != null || !widget.visible) return;
    _cancelPageDrag();
    if (_pageController.hasClients) {
      _pageController.jumpTo(_pageController.offset);
    }
    _controller.stop();
    _heroPressed = false;
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

  void _releaseHero() {
    _heroPressed = false;
    _updatePhase();
  }

  void _selectHero(DenialWindow window) {
    final render = _heroKey.currentContext?.findRenderObject();
    if (render is RenderBox) {
      final rect = MatrixUtils.transformRect(
        render.getTransformTo(null),
        Offset.zero & render.size,
      );
      _startFocusTransition(window, rect);
    }
    _releaseHero();
  }

  void _cancelFocus() {
    _cancelPageDrag();
    _focusController.stop();
    _focusWindow = null;
    _focusStartRect = null;
    _heroPressed = false;
  }

  void _syncHeroPageOffset() {
    _heroPageOffset.value = _pageController.hasClients
        ? Offset(_pageController.offset, 0)
        : Offset.zero;
  }

  void _startPageDrag(DragStartDetails details) {
    if (!_pageController.hasClients) return;
    _cancelPageDrag();
    _pageDrag = _pageController.position.drag(details, () => _pageDrag = null);
  }

  void _endPageDrag(DragEndDetails details) {
    final drag = _pageDrag;
    _pageDrag = null;
    drag?.end(details);
  }

  void _cancelPageDrag() {
    final drag = _pageDrag;
    _pageDrag = null;
    drag?.cancel();
  }

  void _syncWindows({required bool resetOrder}) {
    final byId = {for (final window in widget.windows) window.objectId: window};
    if (resetOrder) {
      final foreground = byId.remove(widget.foregroundObjectId);
      _windows = [?foreground, ...byId.values.toList().reversed];
    } else {
      _windows = [
        for (final previous in _windows) ?byId.remove(previous.objectId),
        ...byId.values.toList().reversed,
      ];
    }
  }
}
