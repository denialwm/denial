import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../localization/denial_localizations.dart';
import '../state/shell_controller.dart';
import 'controllers/home_grid_controller.dart';
import 'controllers/home_grid_layout.dart';
import 'launcher_providers.dart';
import 'models/desktop_app.dart';
import 'models/home_drag_session.dart';
import 'models/home_grid_item.dart';
import 'widgets/home_app_page.dart';
import 'widgets/home_backdrop.dart';
import 'widgets/home_empty_state.dart';
import 'widgets/home_tiles.dart';
import 'widgets/page_dots.dart';

class HomeSurface extends ConsumerStatefulWidget {
  const HomeSurface({
    super.key,
    this.active = true,
    this.interactive = true,
    this.useShellLaunchTransition = false,
  });

  /// Whether the built-in launcher is currently part of the visible shell
  /// scene. Its laid-out subtree is retained offstage while inactive, avoiding
  /// a cold grid/icon rebuild on the first frame of a swipe back to home.
  final bool active;

  /// Whether pointer events may reach launcher content. The launcher can stay
  /// visible behind shell-owned transitions without accepting accidental taps.
  final bool interactive;

  /// Coordinates launches with the integrated shell's placeholder and window
  /// matching. The standalone launcher leaves this off and starts apps
  /// directly because it does not render the shell transition layer.
  final bool useShellLaunchTransition;

  @override
  ConsumerState<HomeSurface> createState() => _HomeSurfaceState();
}

class _HomeSurfaceState extends ConsumerState<HomeSurface> {
  static const double _pageHorizontalPadding = 22;
  static const double _appRowVisualHeight = 126;
  static const double _pageDotsReservedHeight = 7;
  static const EdgeInsets _contentPadding = EdgeInsets.fromLTRB(0, 66, 0, 4);
  static const Duration _backgroundTapMaxDuration = Duration(milliseconds: 260);
  static const Duration _doubleTapMaxInterval = Duration(milliseconds: 360);
  static const double _tapMoveTolerance = 18;
  static const double _doubleTapDistanceTolerance = 72;

  late final PageController _pageController;
  final GlobalKey _homeStackKey = GlobalKey();
  final GlobalKey _gridViewportKey = GlobalKey();
  _HomeResizeSession? _resizeSession;
  int? _resizeModeIndex;
  double _currentTileWidth = 0;
  double _currentTileHeight = 0;
  int _currentRows = 0;
  int _currentPageCount = 0;
  Timer? _dragEndTimer;
  bool _interactionResetScheduled = false;
  DateTime _lastAutoPageTurn = DateTime.fromMillisecondsSinceEpoch(0);
  int? _activePointer;
  Offset? _tapStartGlobalPosition;
  Duration? _tapStartTime;
  bool _tapMoved = false;
  bool _tapStartedOnInteractiveItem = false;
  Duration? _lastBackgroundTapTime;
  Offset? _lastBackgroundTapPosition;
  DateTime _lastScreenOffRequest = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      ref
          .read(homeGridControllerProvider.notifier)
          .setLauncherActive(widget.active && widget.interactive);
    });
  }

  @override
  void didUpdateWidget(covariant HomeSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasRefreshActive = oldWidget.active && oldWidget.interactive;
    final isRefreshActive = widget.active && widget.interactive;
    if (wasRefreshActive != isRefreshActive) {
      ref
          .read(homeGridControllerProvider.notifier)
          .setLauncherActive(isRefreshActive);
    }
    if ((oldWidget.active && !widget.active) ||
        (oldWidget.interactive && !widget.interactive)) {
      _cancelInteraction();
    }
  }

  @override
  void dispose() {
    _dragEndTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  void _cancelInteraction() {
    _dragEndTimer?.cancel();
    _dragEndTimer = null;
    _activePointer = null;
    _resetTapTracking();
    _resizeSession = null;
    _resizeModeIndex = null;
    if (_interactionResetScheduled) {
      return;
    }
    _interactionResetScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _interactionResetScheduled = false;
      if (!mounted) {
        return;
      }
      ref.read(homeDragSessionProvider.notifier).clear();
      ref
          .read(homeGridControllerProvider.notifier)
          .setDraggingSourceIndex(null);
    });
  }

  void _handlePointerDown(PointerDownEvent event) {
    final resizeModeWasActive = _resizeModeIndex != null;
    _dismissResizeModeIfPointerOutside(event.position);
    if (_activePointer != null) {
      return;
    }

    _activePointer = event.pointer;
    _tapStartGlobalPosition = event.position;
    _tapStartTime = event.timeStamp;
    _tapMoved = false;
    _tapStartedOnInteractiveItem =
        resizeModeWasActive || _pointerInsideHomeItem(event.position);
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.pointer != _activePointer) {
      return;
    }
    final tapStart = _tapStartGlobalPosition;
    if (tapStart != null &&
        (event.position - tapStart).distance > _tapMoveTolerance) {
      _tapMoved = true;
    }
    _syncDragSessionToPointer(
      event.position,
      pageCount: _currentPageCount,
      autoPage: true,
    );
  }

  void _handlePointerUp(PointerEvent event) {
    if (event.pointer != _activePointer) {
      return;
    }
    _activePointer = null;
    if (event is PointerUpEvent) {
      if (ref.read(homeDragSessionProvider) != null) {
        _handleItemDragEnd(event.position);
      }
      _handlePotentialBackgroundTap(event);
    } else {
      if (ref.read(homeDragSessionProvider) != null) {
        _handleItemDragEnd();
      }
      _resetTapTracking();
    }
  }

  Future<void> _launchApp(DesktopApp app) async {
    final launcher = ref.read(appLauncherProvider);
    if (!widget.useShellLaunchTransition) {
      await launcher.launch(app);
      return;
    }

    final shellController = ref.read(shellControllerProvider.notifier);
    final requestId = shellController.beginAppLaunch(
      appName: app.name,
      iconPath: app.iconPath,
      expectedAppIds: launcher.expectedWindowAppIds(app),
    );
    if (requestId == null) {
      return;
    }

    final started = await launcher.launch(app, launchRequestId: requestId);
    if (mounted && !started) {
      shellController.failAppLaunch(requestId);
    }
  }

  void _handlePotentialBackgroundTap(PointerUpEvent event) {
    final startPosition = _tapStartGlobalPosition;
    final startTime = _tapStartTime;
    final invalidTap =
        startPosition == null ||
        startTime == null ||
        _tapMoved ||
        _tapStartedOnInteractiveItem ||
        (event.position - startPosition).distance > _tapMoveTolerance ||
        event.timeStamp - startTime > _backgroundTapMaxDuration ||
        _pointerInsideHomeItem(event.position);
    _resetTapTracking();

    if (invalidTap) {
      _lastBackgroundTapTime = null;
      _lastBackgroundTapPosition = null;
      return;
    }

    final lastTime = _lastBackgroundTapTime;
    final lastPosition = _lastBackgroundTapPosition;
    if (lastTime != null &&
        lastPosition != null &&
        event.timeStamp - lastTime <= _doubleTapMaxInterval &&
        (event.position - lastPosition).distance <=
            _doubleTapDistanceTolerance) {
      _lastBackgroundTapTime = null;
      _lastBackgroundTapPosition = null;
      _requestScreenOffFromDoubleTap();
      return;
    }

    _lastBackgroundTapTime = event.timeStamp;
    _lastBackgroundTapPosition = event.position;
  }

  void _resetTapTracking() {
    _tapStartGlobalPosition = null;
    _tapStartTime = null;
    _tapMoved = false;
    _tapStartedOnInteractiveItem = false;
  }

  void _requestScreenOffFromDoubleTap() {
    final now = DateTime.now();
    if (now.difference(_lastScreenOffRequest) < const Duration(seconds: 1)) {
      return;
    }

    _lastScreenOffRequest = now;
    unawaited(
      ref.read(screenPowerServiceProvider).screenOff(reason: 'home-double-tap'),
    );
  }

  bool _pointerInsideHomeItem(Offset globalPosition) {
    if (_currentRows <= 0 ||
        _currentTileWidth <= 0 ||
        _currentTileHeight <= 0) {
      return false;
    }

    final gridState = ref.read(homeGridControllerProvider).asData?.value;
    if (gridState == null) {
      return false;
    }

    final context = _gridViewportKey.currentContext;
    final renderObject = context?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return false;
    }

    final pageSize = HomeGridLayout.columns * _currentRows;
    if (pageSize <= 0) {
      return false;
    }

    final pageStart = gridState.page * pageSize;
    final pageEnd = pageStart + pageSize;
    final localPosition = renderObject.globalToLocal(globalPosition);
    for (
      var index = pageStart;
      index < pageEnd && index < gridState.slots.length;
      index += 1
    ) {
      final item = gridState.slots[index];
      if (item == null) {
        continue;
      }

      final cells = HomeGridLayout.cellsFor(
        index,
        item,
        columns: HomeGridLayout.columns,
      );
      if (cells.any((cell) => cell < pageStart || cell >= pageEnd)) {
        continue;
      }

      final localIndex = index - pageStart;
      final row = localIndex ~/ HomeGridLayout.columns;
      final column = localIndex % HomeGridLayout.columns;
      final rect = Rect.fromLTWH(
        _pageHorizontalPadding +
            column * (_currentTileWidth + HomeGridLayout.gridGap),
        row * (_currentTileHeight + HomeGridLayout.gridGap),
        item.colSpan * _currentTileWidth +
            (item.colSpan - 1) * HomeGridLayout.gridGap,
        item.rowSpan * _currentTileHeight +
            (item.rowSpan - 1) * HomeGridLayout.gridGap,
      ).inflate(8);

      if (rect.contains(localPosition)) {
        return true;
      }
    }

    return false;
  }

  void _handleItemDragAutoPage(Offset globalPosition, int pageCount) {
    final now = DateTime.now();
    if (now.difference(_lastAutoPageTurn) < const Duration(milliseconds: 520)) {
      return;
    }

    final page = ref.read(homeGridControllerProvider).asData?.value.page ?? 0;
    final width = MediaQuery.sizeOf(context).width;
    final x = globalPosition.dx;
    if (x > width - 64 && page < pageCount - 1) {
      _lastAutoPageTurn = now;
      unawaited(
        _pageController.nextPage(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        ),
      );
    } else if (x < 64 && page > 0) {
      _lastAutoPageTurn = now;
      unawaited(
        _pageController.previousPage(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  void _handleItemDragStart(
    HomeGridItem item,
    int fromIndex,
    int pageSize,
    LongPressStartDetails details,
    Size feedbackSize,
  ) {
    _startItemDrag(
      item: item,
      fromIndex: fromIndex,
      pageSize: pageSize,
      pointerGlobalPosition: details.globalPosition,
      localAnchor: details.localPosition,
      feedbackSize: feedbackSize,
    );
  }

  void _startItemDrag({
    required HomeGridItem item,
    required int fromIndex,
    required int pageSize,
    required Offset pointerGlobalPosition,
    required Offset localAnchor,
    required Size feedbackSize,
  }) {
    _dragEndTimer?.cancel();
    _dragEndTimer = null;
    final session = HomeDragSession(
      item: item,
      fromIndex: fromIndex,
      pageSize: pageSize,
      pointerGlobalPosition: pointerGlobalPosition,
      localAnchor: _clampDragAnchor(localAnchor, feedbackSize),
      feedbackSize: feedbackSize,
    );
    final targetedSession = session.copyWith(
      targetIndex: _targetIndexForDragSession(session),
      replaceTargetIndex: true,
    );
    ref
        .read(homeGridControllerProvider.notifier)
        .setDraggingSourceIndex(fromIndex);
    ref.read(homeDragSessionProvider.notifier).setSession(targetedSession);
  }

  void _handleItemResizeModeStart(
    HomeGridItem item,
    int index,
    int pageSize,
    LongPressStartDetails details,
  ) {
    if (!item.resizable) {
      return;
    }
    _dragEndTimer?.cancel();
    _dragEndTimer = null;
    _resizeSession = null;
    ref.read(homeDragSessionProvider.notifier).clear();
    ref.read(homeGridControllerProvider.notifier).setDraggingSourceIndex(null);
    setState(() {
      _resizeModeIndex = index;
    });
  }

  void _handleItemResizeModeMove(
    HomeGridItem item,
    int index,
    int pageSize,
    LongPressMoveUpdateDetails details,
    Size feedbackSize,
  ) {
    if (_resizeModeIndex == null) {
      return;
    }
    if (details.offsetFromOrigin.distance < 12) {
      return;
    }

    final localAnchor = details.localPosition - details.localOffsetFromOrigin;
    _clearResizeMode();
    _startItemDrag(
      item: item,
      fromIndex: index,
      pageSize: pageSize,
      pointerGlobalPosition: details.globalPosition,
      localAnchor: localAnchor,
      feedbackSize: feedbackSize,
    );
    _syncDragSessionToPointer(
      details.globalPosition,
      pageCount: _currentPageCount,
      autoPage: true,
    );
  }

  void _handleItemResizeModeEnd() {
    _resizeSession = null;
  }

  void _handleItemResizeStart(
    HomeGridItem item,
    int index,
    int pageSize,
    DragStartDetails details,
  ) {
    if (!item.resizable ||
        pageSize <= 0 ||
        _currentRows <= 0 ||
        _currentTileWidth <= 0 ||
        _currentTileHeight <= 0) {
      return;
    }
    _dragEndTimer?.cancel();
    _dragEndTimer = null;
    ref.read(homeDragSessionProvider.notifier).clear();
    ref.read(homeGridControllerProvider.notifier).setDraggingSourceIndex(null);
    _resizeSession = _HomeResizeSession(
      item: item,
      index: index,
      pageSize: pageSize,
      startGlobalPosition: details.globalPosition,
      startColSpan: item.colSpan,
      startRowSpan: item.rowSpan,
    );
  }

  void _handleItemResizeUpdate(DragUpdateDetails details) {
    final session = _resizeSession;
    if (session == null) {
      return;
    }
    final target = _targetSpanForResizeSession(session, details.globalPosition);
    final best = _bestResizableSpan(session, target);
    if (best == null) {
      return;
    }

    final gridState = ref.read(homeGridControllerProvider).asData?.value;
    final currentItem =
        gridState != null && session.index < gridState.slots.length
        ? gridState.slots[session.index]
        : null;
    if (currentItem == null ||
        (currentItem.colSpan == best.colSpan &&
            currentItem.rowSpan == best.rowSpan)) {
      return;
    }

    ref
        .read(homeGridControllerProvider.notifier)
        .resizeSlot(
          session.index,
          best.colSpan,
          best.rowSpan,
          session.pageSize,
        );
  }

  void _handleItemResizeEnd() {
    final session = _resizeSession;
    if (session == null) {
      return;
    }
    _resizeSession = null;
  }

  void _clearResizeMode() {
    if (_resizeModeIndex == null && _resizeSession == null) {
      return;
    }

    _resizeSession = null;
    if (mounted) {
      setState(() {
        _resizeModeIndex = null;
      });
    } else {
      _resizeModeIndex = null;
    }
  }

  void _dismissResizeModeIfPointerOutside(Offset globalPosition) {
    if (_resizeModeIndex == null ||
        _currentRows <= 0 ||
        _currentTileWidth <= 0 ||
        _currentTileHeight <= 0) {
      return;
    }

    if (_pointerInsideResizeModeItem(globalPosition)) {
      return;
    }

    _clearResizeMode();
  }

  bool _pointerInsideResizeModeItem(Offset globalPosition) {
    final index = _resizeModeIndex;
    if (index == null) {
      return false;
    }

    final gridState = ref.read(homeGridControllerProvider).asData?.value;
    if (gridState == null || index < 0 || index >= gridState.slots.length) {
      return false;
    }

    final item = gridState.slots[index];
    if (item == null) {
      return false;
    }

    final context = _gridViewportKey.currentContext;
    final renderObject = context?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return false;
    }

    final pageSize = HomeGridLayout.columns * _currentRows;
    if (pageSize <= 0) {
      return false;
    }
    final page = gridState.page;
    final localIndex = index - page * pageSize;
    if (localIndex < 0 || localIndex >= pageSize) {
      return false;
    }

    final row = localIndex ~/ HomeGridLayout.columns;
    final column = localIndex % HomeGridLayout.columns;
    final localPosition = renderObject.globalToLocal(globalPosition);
    final rect = Rect.fromLTWH(
      _pageHorizontalPadding +
          column * (_currentTileWidth + HomeGridLayout.gridGap),
      row * (_currentTileHeight + HomeGridLayout.gridGap),
      item.colSpan * _currentTileWidth +
          (item.colSpan - 1) * HomeGridLayout.gridGap,
      item.rowSpan * _currentTileHeight +
          (item.rowSpan - 1) * HomeGridLayout.gridGap,
    ).inflate(14);
    return rect.contains(localPosition);
  }

  void _handleItemDragUpdate(
    LongPressMoveUpdateDetails details,
    int pageCount,
  ) {
    _syncDragSessionToPointer(
      details.globalPosition,
      pageCount: pageCount,
      autoPage: true,
    );
  }

  void _syncDragSessionToPointer(
    Offset globalPosition, {
    required int pageCount,
    required bool autoPage,
  }) {
    final session = ref.read(homeDragSessionProvider);
    if (session == null) {
      return;
    }
    final next = session.copyWith(
      pointerGlobalPosition: globalPosition,
      replaceTargetIndex: true,
    );
    final targetedNext = next.copyWith(
      targetIndex: _targetIndexForDragSession(next),
      replaceTargetIndex: true,
    );
    ref.read(homeDragSessionProvider.notifier).setSession(targetedNext);
    if (autoPage && pageCount > 1) {
      _handleItemDragAutoPage(globalPosition, pageCount);
    }
  }

  _HomeGridSpan _targetSpanForResizeSession(
    _HomeResizeSession session,
    Offset globalPosition,
  ) {
    final stepX = _currentTileWidth + HomeGridLayout.gridGap;
    final stepY = _currentTileHeight + HomeGridLayout.gridGap;
    final delta = globalPosition - session.startGlobalPosition;
    final colSpan = session.startColSpan + (delta.dx / stepX).round();
    final rowSpan = session.startRowSpan + (delta.dy / stepY).round();

    return _HomeGridSpan(
      colSpan: colSpan
          .clamp(session.item.minColSpan, _maxColSpan(session))
          .toInt(),
      rowSpan: rowSpan
          .clamp(session.item.minRowSpan, _maxRowSpan(session))
          .toInt(),
    );
  }

  _HomeGridSpan? _bestResizableSpan(
    _HomeResizeSession session,
    _HomeGridSpan target,
  ) {
    final controller = ref.read(homeGridControllerProvider.notifier);
    _HomeGridSpan? best;
    var bestDistance = double.infinity;
    var bestAreaDistance = double.infinity;

    for (
      var rowSpan = session.item.minRowSpan;
      rowSpan <= _maxRowSpan(session);
      rowSpan += 1
    ) {
      for (
        var colSpan = session.item.minColSpan;
        colSpan <= _maxColSpan(session);
        colSpan += 1
      ) {
        if (!controller.canResizeSlot(
          session.index,
          colSpan,
          rowSpan,
          session.pageSize,
        )) {
          continue;
        }

        final distance =
            math.pow(colSpan - target.colSpan, 2) +
            math.pow(rowSpan - target.rowSpan, 2);
        final areaDistance =
            (colSpan * rowSpan - target.colSpan * target.rowSpan).abs();
        if (distance < bestDistance ||
            (distance == bestDistance && areaDistance < bestAreaDistance)) {
          best = _HomeGridSpan(colSpan: colSpan, rowSpan: rowSpan);
          bestDistance = distance.toDouble();
          bestAreaDistance = areaDistance.toDouble();
        }
      }
    }

    return best;
  }

  int _maxColSpan(_HomeResizeSession session) {
    final localIndex = session.index % session.pageSize;
    final column = localIndex % HomeGridLayout.columns;
    return math.min(session.item.maxColSpan, HomeGridLayout.columns - column);
  }

  int _maxRowSpan(_HomeResizeSession session) {
    final localIndex = session.index % session.pageSize;
    final row = localIndex ~/ HomeGridLayout.columns;
    return math.min(
      session.item.maxRowSpan,
      math.max(session.item.minRowSpan, _currentRows - row),
    );
  }

  void _handleItemDragEnd([Offset? finalGlobalPosition]) {
    var session = ref.read(homeDragSessionProvider);
    if (session == null) {
      return;
    }
    if (finalGlobalPosition != null) {
      session = session.copyWith(
        pointerGlobalPosition: finalGlobalPosition,
        replaceTargetIndex: true,
      );
      session = session.copyWith(
        targetIndex: _targetIndexForDragSession(session),
        replaceTargetIndex: true,
      );
      ref.read(homeDragSessionProvider.notifier).setSession(session);
    }

    final targetIndex = session.targetIndex;
    final gridController = ref.read(homeGridControllerProvider.notifier);
    if (targetIndex != null &&
        gridController.canMoveSlot(
          session.fromIndex,
          targetIndex,
          session.pageSize,
        )) {
      gridController.moveSlot(session.fromIndex, targetIndex, session.pageSize);
    }

    _dragEndTimer?.cancel();
    _dragEndTimer = Timer(const Duration(milliseconds: 70), () {
      _dragEndTimer = null;
      if (!mounted || ref.read(homeDragSessionProvider) != session) {
        return;
      }
      ref.read(homeDragSessionProvider.notifier).clear();
      ref
          .read(homeGridControllerProvider.notifier)
          .setDraggingSourceIndex(null);
    });
  }

  Offset _clampDragAnchor(Offset anchor, Size size) {
    return Offset(
      anchor.dx.clamp(0.0, size.width).toDouble(),
      anchor.dy.clamp(0.0, size.height).toDouble(),
    );
  }

  int? _targetIndexForDragSession(HomeDragSession session) {
    if (session.pageSize <= 0 ||
        _currentRows <= 0 ||
        _currentTileWidth <= 0 ||
        _currentTileHeight <= 0) {
      return null;
    }

    final gridState = ref.read(homeGridControllerProvider).asData?.value;
    if (gridState == null) {
      return null;
    }

    final context = _gridViewportKey.currentContext;
    final renderObject = context?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return null;
    }

    final pointerLocal = renderObject.globalToLocal(
      session.pointerGlobalPosition,
    );
    final dragRect = session.localAnchor & session.feedbackSize;
    final localRect = Rect.fromLTWH(
      pointerLocal.dx - dragRect.left,
      pointerLocal.dy - dragRect.top,
      dragRect.width,
      dragRect.height,
    );
    final gridRect = Rect.fromLTWH(
      _pageHorizontalPadding,
      0,
      renderObject.size.width - _pageHorizontalPadding * 2,
      renderObject.size.height,
    );
    if (!localRect.overlaps(gridRect)) {
      return null;
    }

    final stepX = _currentTileWidth + HomeGridLayout.gridGap;
    final stepY = _currentTileHeight + HomeGridLayout.gridGap;
    final pageStart = gridState.page * session.pageSize;
    var bestIndex = pageStart;
    var bestOverlap = -1.0;
    var bestDistance = double.infinity;
    final dragCenter = localRect.center;
    final gridController = ref.read(homeGridControllerProvider.notifier);

    for (var row = 0; row <= _currentRows - session.item.rowSpan; row += 1) {
      for (
        var column = 0;
        column <= HomeGridLayout.columns - session.item.colSpan;
        column += 1
      ) {
        final left = _pageHorizontalPadding + column * stepX;
        final top = row * stepY;
        final candidateRect = Rect.fromLTWH(
          left,
          top,
          session.item.colSpan * _currentTileWidth +
              (session.item.colSpan - 1) * HomeGridLayout.gridGap,
          session.item.rowSpan * _currentTileHeight +
              (session.item.rowSpan - 1) * HomeGridLayout.gridGap,
        );
        final overlap = HomeGridLayout.rectOverlapArea(
          localRect,
          candidateRect,
        );
        if (overlap <= 0) {
          continue;
        }

        final index = pageStart + row * HomeGridLayout.columns + column;
        if (!gridController.canMoveSlot(
          session.fromIndex,
          index,
          session.pageSize,
        )) {
          continue;
        }

        final distance = (dragCenter - candidateRect.center).distanceSquared;
        if (overlap > bestOverlap ||
            (overlap == bestOverlap && distance < bestDistance)) {
          bestIndex = index;
          bestOverlap = overlap;
          bestDistance = distance;
        }
      }
    }

    return bestOverlap > 0 ? bestIndex : null;
  }

  Offset? _dragOverlayOffset(HomeDragSession session) {
    final context = _homeStackKey.currentContext;
    final renderObject = context?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return null;
    }

    return renderObject.globalToLocal(session.pointerGlobalPosition) -
        session.localAnchor;
  }

  void _syncSafePage(int currentPage, int safePage) {
    if (currentPage == safePage) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      ref.read(homeGridControllerProvider.notifier).setPage(safePage);
    });
  }

  @override
  Widget build(BuildContext context) {
    final gridAsync = ref.watch(homeGridControllerProvider);
    final gridState = gridAsync.asData?.value;

    return Offstage(
      offstage: !widget.active,
      child: IgnorePointer(
        ignoring: !widget.interactive,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _handlePointerDown,
          onPointerMove: _handlePointerMove,
          onPointerUp: _handlePointerUp,
          onPointerCancel: _handlePointerUp,
          child: Stack(
            key: _homeStackKey,
            fit: StackFit.expand,
            children: [
              const CustomPaint(painter: HomeBackdropPainter()),
              Padding(
                padding: _contentPadding,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final gridWidth =
                              constraints.maxWidth - _pageHorizontalPadding * 2;
                          // Wide panels get more columns (not smaller pages):
                          // full-bleed paging and no vertical overflow.
                          HomeGridLayout.columns =
                              HomeGridLayout.columnsForViewport(gridWidth);
                          final tileWidth =
                              (gridWidth -
                                  HomeGridLayout.gridGap *
                                      (HomeGridLayout.columns - 1)) /
                              HomeGridLayout.columns;
                          // Cell content is fixed-size, so height must not
                          // follow width past its cap (phone tiles never
                          // reach it and keep the tuned aspect).
                          final tileHeight = math.min(
                            tileWidth / HomeAppPage.childAspectRatio,
                            HomeGridLayout.maxTileHeight,
                          );
                          final rows = HomeGridLayout.rowsForHeight(
                            constraints.maxHeight - _pageDotsReservedHeight,
                            tileHeight,
                          );
                          final pageSize = HomeGridLayout.columns * rows;
                          final gridHeight =
                              rows * tileHeight +
                              (rows - 1) * HomeGridLayout.gridGap;
                          final rowVisualHeight = math.min(
                            tileHeight,
                            _appRowVisualHeight,
                          );
                          final visualRowsHeight =
                              (rows - 1) *
                                  (tileHeight + HomeGridLayout.gridGap) +
                              rowVisualHeight;
                          final pageDotsTop =
                              visualRowsHeight +
                              math.max(
                                    0,
                                    constraints.maxHeight -
                                        visualRowsHeight -
                                        _pageDotsReservedHeight,
                                  ) /
                                  3;
                          _currentTileWidth = tileWidth;
                          _currentTileHeight = tileHeight;
                          _currentRows = rows;

                          final rawSlots =
                              gridState?.slots ?? const <HomeGridItem?>[];
                          final slots = HomeGridLayout.ensureSlotCapacity(
                            rawSlots,
                            pageSize,
                          );
                          final pageCount = HomeGridLayout.pageCountForSlots(
                            slots,
                            pageSize,
                          );
                          _currentPageCount = pageCount;
                          final currentPage = gridState?.page ?? 0;
                          final safePage = currentPage
                              .clamp(0, pageCount - 1)
                              .toInt();
                          _syncSafePage(currentPage, safePage);

                          final content = gridState == null
                              ? gridAsync.hasError
                                    ? HomeEmptyState(
                                        label: context.l10n.commonError,
                                      )
                                    : HomeEmptyState(
                                        label: context.l10n.commonLoading,
                                      )
                              : PageView.builder(
                                  controller: _pageController,
                                  itemCount: pageCount,
                                  onPageChanged: (page) {
                                    _clearResizeMode();
                                    ref
                                        .read(
                                          homeGridControllerProvider.notifier,
                                        )
                                        .setPage(page);
                                    final activeDrag = ref.read(
                                      homeDragSessionProvider,
                                    );
                                    if (activeDrag != null) {
                                      _syncDragSessionToPointer(
                                        activeDrag.pointerGlobalPosition,
                                        pageCount: pageCount,
                                        autoPage: false,
                                      );
                                    }
                                  },
                                  itemBuilder: (context, page) {
                                    final start = page * pageSize;
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: _pageHorizontalPadding,
                                      ),
                                      child: HomeAppPage(
                                        slots: slots,
                                        startIndex: start,
                                        pageSize: pageSize,
                                        columns: HomeGridLayout.columns,
                                        gap: HomeGridLayout.gridGap,
                                        tileWidth: tileWidth,
                                        tileHeight: tileHeight,
                                        draggingSourceIndex:
                                            gridState.draggingSourceIndex,
                                        resizeModeIndex: _resizeModeIndex,
                                        onLaunch: _launchApp,
                                        onDragStart: _handleItemDragStart,
                                        onDragEnd: _handleItemDragEnd,
                                        onDragUpdate: (details) {
                                          _handleItemDragUpdate(
                                            details,
                                            pageCount,
                                          );
                                        },
                                        onResizeModeStart:
                                            _handleItemResizeModeStart,
                                        onResizeModeMove:
                                            _handleItemResizeModeMove,
                                        onResizeModeEnd:
                                            _handleItemResizeModeEnd,
                                        onResizeStart: _handleItemResizeStart,
                                        onResizeUpdate: _handleItemResizeUpdate,
                                        onResizeEnd: _handleItemResizeEnd,
                                      ),
                                    );
                                  },
                                );

                          return Stack(
                            children: [
                              Align(
                                alignment: Alignment.topCenter,
                                child: SizedBox(
                                  width: double.infinity,
                                  height: gridHeight,
                                  child: SizedBox.expand(
                                    key: _gridViewportKey,
                                    child: content,
                                  ),
                                ),
                              ),
                              Positioned(
                                top: pageDotsTop,
                                left: 0,
                                right: 0,
                                child: PageDots(
                                  count: pageCount,
                                  active: safePage,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              Consumer(
                builder: (context, ref, _) {
                  final dragSession = ref.watch(homeDragSessionProvider);
                  if (dragSession == null) {
                    return const SizedBox.shrink();
                  }
                  final offset = _dragOverlayOffset(dragSession);
                  if (offset == null) {
                    return const SizedBox.shrink();
                  }

                  return Positioned(
                    left: offset.dx,
                    top: offset.dy,
                    width: dragSession.feedbackSize.width,
                    height: dragSession.feedbackSize.height,
                    child: IgnorePointer(
                      child: RepaintBoundary(
                        child: HomeGridItemCard(
                          item: dragSession.item,
                          onLaunch: _launchApp,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeResizeSession {
  const _HomeResizeSession({
    required this.item,
    required this.index,
    required this.pageSize,
    required this.startGlobalPosition,
    required this.startColSpan,
    required this.startRowSpan,
  });

  final HomeGridItem item;
  final int index;
  final int pageSize;
  final Offset startGlobalPosition;
  final int startColSpan;
  final int startRowSpan;
}

class _HomeGridSpan {
  const _HomeGridSpan({required this.colSpan, required this.rowSpan});

  final int colSpan;
  final int rowSpan;
}
