import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/widgets.dart';

import '../../models/denial_window.dart';
import '../../theme/motion.dart';
import 'overview_geometry.dart';
import 'overview_page_controller.dart';
import '../retained_translation.dart';
import 'overview_window_card.dart';

/// The swipeable strip of window previews shown when the overview is open.
class OverviewCarousel extends StatefulWidget {
  const OverviewCarousel({
    super.key,
    required this.windows,
    required this.progress,
    this.focusProgress = const AlwaysStoppedAnimation(0.0),
    required this.pageController,
    required this.foregroundObjectId,
    this.foregroundInHero = false,
    this.focusingObjectId,
    required this.onDismissWindow,
    required this.onFocusWindow,
  });

  final List<DenialWindow> windows;
  final Animation<double> progress;
  final Animation<double> focusProgress;
  final PageController pageController;
  final int? foregroundObjectId;
  final bool foregroundInHero;
  final int? focusingObjectId;
  final ValueChanged<DenialWindow> onDismissWindow;
  final void Function(DenialWindow window, Rect startRect) onFocusWindow;

  @override
  State<OverviewCarousel> createState() => _OverviewCarouselState();
}

class _OverviewCarouselState extends State<OverviewCarousel>
    with SingleTickerProviderStateMixin {
  late List<DenialWindow> _items;
  late final AnimationController _reflow;
  final _dismissRequested = <int>{};
  final _removing = <int>{};
  final _targetIndices = <int, int>{};
  double _startPage = 0;
  int _targetPage = 0;
  bool _reconcileScheduled = false;
  ScrollHoldController? _pointerHold;
  int? _heldPointer;

  @override
  void initState() {
    super.initState();
    _items = List.of(widget.windows);
    _reflow =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 300),
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed) _finishRemoval();
        });
  }

  @override
  void didUpdateWidget(covariant OverviewCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pageController != oldWidget.pageController) {
      _releasePointerHold();
    }
    final byId = {for (final window in widget.windows) window.objectId: window};
    _dismissRequested.removeWhere((id) => !byId.containsKey(id));
    _items = [
      for (final item in _items) byId[item.objectId] ?? item,
      if (_removing.isEmpty)
        for (final item in widget.windows)
          if (!_dismissRequested.contains(item.objectId) &&
              !_items.any((old) => old.objectId == item.objectId))
            item,
    ];
    _scheduleReconcile();
  }

  @override
  void dispose() {
    _releasePointerHold();
    _reflow.dispose();
    super.dispose();
  }

  void _holdForMouse(PointerDownEvent event) {
    // Mouse presses do not enter Scrollable's touch-drag recognizer, which
    // normally holds a moving page as soon as the user touches it.
    if (event.kind != PointerDeviceKind.mouse ||
        _heldPointer != null ||
        !widget.pageController.hasClients) {
      return;
    }
    _heldPointer = event.pointer;
    _pointerHold = widget.pageController.position.hold(() {
      _pointerHold = null;
      _heldPointer = null;
    });
  }

  void _releasePointerHold() {
    final hold = _pointerHold;
    _pointerHold = null;
    _heldPointer = null;
    hold?.cancel();
  }

  void _releaseMouse(PointerEvent event) {
    if (event.pointer == _heldPointer) _releasePointerHold();
  }

  void _scheduleReconcile() {
    if (_reconcileScheduled || _removing.isNotEmpty) return;
    _reconcileScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reconcileScheduled = false;
      if (mounted) _beginRemoval();
    });
  }

  void _dismissWindow(DenialWindow window) {
    if (!_dismissRequested.add(window.objectId)) return;
    // Send the close only after the card is fully off-screen. Keep its slot
    // until the neighbors arrive, independent of the client's close latency.
    widget.onDismissWindow(window);
    if (mounted) _beginRemoval();
  }

  void _beginRemoval() {
    if (_removing.isNotEmpty || _items.isEmpty) return;
    final liveIds = widget.windows.map((window) => window.objectId).toSet();
    final removed = _items
        .where(
          (item) =>
              !liveIds.contains(item.objectId) ||
              _dismissRequested.contains(item.objectId),
        )
        .map((item) => item.objectId)
        .toSet();
    if (removed.isEmpty) return;
    final pages = widget.pageController;
    _startPage = pages.hasClients
        ? (pages.page ?? pages.initialPage.toDouble())
        : pages.initialPage.toDouble();
    final selected = _startPage.round().clamp(0, _items.length - 1);
    final remaining = _items
        .where((item) => !removed.contains(item.objectId))
        .toList();
    _targetIndices
      ..clear()
      ..addEntries([
        for (var index = 0; index < remaining.length; index++)
          MapEntry(remaining[index].objectId, index),
      ]);
    // Preserve the selected task by identity; when it is removed, choose the
    // next older task, or the preceding task when dismissing the last page.
    final preferred = _items
        .skip(selected)
        .where((item) => _targetIndices.containsKey(item.objectId));
    _targetPage = preferred.isNotEmpty
        ? _targetIndices[preferred.first.objectId]!
        : remaining.isEmpty
        ? 0
        : remaining.length - 1;
    if (pages.hasClients) pages.jumpTo(pages.offset);
    setState(() => _removing.addAll(removed));
    if (removed.length == 1 && remaining.isNotEmpty) {
      _reflow.forward(from: 0);
    } else {
      // A batch snapshot can remove arbitrarily many pages at once. Resolve
      // that topology directly instead of translating through missing tasks.
      _finishRemoval();
    }
  }

  void _finishRemoval() {
    setState(() {
      _items.removeWhere((item) => _removing.contains(item.objectId));
      final known = _items.map((item) => item.objectId).toSet();
      _items.addAll(
        widget.windows.where(
          (item) =>
              !known.contains(item.objectId) &&
              !_dismissRequested.contains(item.objectId) &&
              !_removing.contains(item.objectId),
        ),
      );
      _removing.clear();
      _targetIndices.clear();
    });
    if (widget.pageController.hasClients && _items.isNotEmpty) {
      widget.pageController.jumpToPage(_targetPage);
    }
    _reflow.value = 0;
    _scheduleReconcile();
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final focusingId = widget.focusingObjectId;
    final focusIndex = focusingId == null ? null : _indexOf(focusingId);

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewAspect = viewAspectFor(constraints.biggest);
        final cardSize = cardSizeFor(
          constraints: constraints,
          padding: padding,
          aspect: viewAspect,
        );
        final viewportWidth = overviewCarouselViewportWidthFor(
          constraints.biggest,
          cardSize,
        );
        // With the foreground in its own hero, only the older card's exposed
        // edge needs to enter. Starting a full screen away hides it until the
        // very end of the gesture. Start just beyond the left edge instead,
        // so the neighbor follows the shrinking app from the first drag frame.
        final entryTravel = widget.foregroundObjectId != null
            ? ((constraints.maxWidth - cardSize.width) / 2 -
                      overviewPageSpacing)
                  .clamp(0.0, constraints.maxWidth)
            : constraints.maxWidth;
        return RetainedTranslation(
          translation: widget.progress.drive(
            Tween(begin: Offset(-entryTravel, 0), end: Offset.zero),
          ),
          child: ClipRect(
            child: OverflowBox(
              minWidth: viewportWidth,
              maxWidth: viewportWidth,
              child: SizedBox(
                width: viewportWidth,
                child: IgnorePointer(
                  ignoring: _removing.isNotEmpty,
                  child: Listener(
                    onPointerDown: _holdForMouse,
                    onPointerUp: _releaseMouse,
                    onPointerCancel: _releaseMouse,
                    child: PageView.builder(
                      hitTestBehavior: HitTestBehavior.translucent,
                      controller: widget.pageController,
                      // Older tasks always sit to the physical left, including
                      // while the foreground app is still entering overview.
                      reverse: Directionality.of(context) == TextDirection.ltr,
                      pageSnapping: false,
                      physics: const OverviewScrollPhysics(),
                      clipBehavior: Clip.hardEdge,
                      itemCount: _items.length,
                      findChildIndexCallback: (key) => switch (key) {
                        ValueKey<int>(:final value) => _indexOf(value),
                        _ => null,
                      },
                      itemBuilder: (context, index) {
                        final window = _items[index];
                        final targetIndex = _targetIndices[window.objectId];
                        final shift = targetIndex == null
                            ? 0.0
                            : (targetIndex - _targetPage - index + _startPage) *
                                  viewportWidth *
                                  widget.pageController.viewportFraction *
                                  -1;
                        final focusShift = focusIndex == null
                            ? 0.0
                            : (focusIndex - index).sign * constraints.maxWidth;
                        return RetainedTranslation(
                          key: ValueKey<int>(window.objectId),
                          translation: _reflow
                              .drive(CurveTween(curve: Motion.standard))
                              .drive(
                                Tween(
                                  begin: Offset.zero,
                                  end: Offset(shift, 0),
                                ),
                              ),
                          child: RetainedTranslation(
                            translation: widget.focusProgress
                                .drive(CurveTween(curve: Motion.standard))
                                .drive(
                                  Tween(
                                    begin: Offset.zero,
                                    end: Offset(focusShift, 0),
                                  ),
                                ),
                            child: OverviewWindowCard(
                              window: window,
                              cardSize: cardSize,
                              foreground:
                                  widget.foregroundInHero &&
                                  widget.foregroundObjectId == window.objectId,
                              focusing:
                                  widget.focusingObjectId == window.objectId ||
                                  _removing.contains(window.objectId),
                              onDismiss: _dismissWindow,
                              onFocus: widget.onFocusWindow,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  int? _indexOf(int objectId) {
    final index = _items.indexWhere((window) => window.objectId == objectId);
    return index < 0 ? null : index;
  }
}
