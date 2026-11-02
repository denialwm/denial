import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/applications.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/rendering.dart';

import '../state/reference_shell_controller.dart';
import 'home_drag_controller.dart';
import 'home_grid_geometry.dart';
import 'home_icon_locator.dart';
import 'home_interactions.dart';
import 'home_launch.dart';
import 'home_pager.dart';
import 'home_resize_controller.dart';
import 'widgets/home_backdrop.dart';
import 'widgets/home_drag_layer.dart';
import 'widgets/home_folder_panel.dart';
import 'widgets/home_resize_frame.dart';

/// The mobile home screen: paged apps, folders and widgets over the
/// wallpaper.
class HomeSurface extends ConsumerStatefulWidget {
  const HomeSurface({
    super.key,
    this.active = true,
    this.interactive = true,
    this.contentOpacity,
  });

  /// Whether home is part of the visible shell scene. Its laid-out subtree
  /// is retained offstage while inactive, avoiding a cold grid and icon
  /// rebuild on the first frame of a swipe back to home.
  final bool active;

  /// Whether pointer events may reach home. Home can stay visible behind
  /// shell-owned transitions without accepting accidental taps.
  final bool interactive;

  /// Fades icons, widgets and page indicators independently of the backdrop.
  /// The animation updates composited opacity without rebuilding the grid.
  final Animation<double>? contentOpacity;

  @override
  ConsumerState<HomeSurface> createState() => _HomeSurfaceState();
}

class _HomeSurfaceState extends ConsumerState<HomeSurface>
    implements HomeGridHost, HomeInteractions {
  static const EdgeInsets _contentPadding = EdgeInsets.fromLTRB(0, 66, 0, 4);

  /// A widget held in its resize frame starts moving past this distance.
  static const double _widgetDragSlop = 28;

  final _pages = PageController();
  final _viewportKey = GlobalKey();
  final _surfaceKey = GlobalKey();
  late final HomeIconLocator _locator = ref.read(homeIconLocatorProvider);
  late final _taps = _BackgroundTaps(onDoubleTap: _sleepFromDoubleTap);

  @override
  final folders = HomeFolderController();
  @override
  late final drag = HomeDragController(this);
  @override
  late final resize = HomeResizeController(this);

  HomeGridGeometry? _geometry;
  int? _pointer;

  /// A widget whose long press opened its resize frame; moving the finger
  /// on lifts it instead.
  ({HomeGridItem item, int index, Rect rect, Offset start})? _heldWidget;

  /// The press that dismissed a resize frame does nothing else.
  bool _swallowTap = false;

  @override
  void initState() {
    super.initState();
    _locator.attach(_iconFor);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(homeGridControllerProvider.notifier)
          .setLauncherActive(widget.active && widget.interactive);
    });
  }

  @override
  void didUpdateWidget(covariant HomeSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasVisible = oldWidget.active && oldWidget.interactive;
    final visible = widget.active && widget.interactive;
    if (wasVisible != visible) {
      ref.read(homeGridControllerProvider.notifier).setLauncherActive(visible);
    }
    if (wasVisible && !visible) _cancelInteraction();
  }

  @override
  void dispose() {
    _locator.detach(_iconFor);
    drag.dispose();
    resize.dispose();
    folders.dispose();
    _pages.dispose();
    super.dispose();
  }

  void _cancelInteraction() {
    _pointer = null;
    _heldWidget = null;
    _taps.reset();
    resize.exit();
    drag.abandon();
  }

  // HomeGridHost -------------------------------------------------------------

  @override
  HomeGridState? get grid => ref.read(homeGridControllerProvider).asData?.value;

  @override
  HomeGridController get gridController =>
      ref.read(homeGridControllerProvider.notifier);

  @override
  HomeGridGeometry? get geometry => _geometry;

  RenderBox? _boxOf(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    return box is RenderBox && box.hasSize ? box : null;
  }

  @override
  Offset globalToGrid(Offset global) =>
      _boxOf(_viewportKey)?.globalToLocal(global) ?? global;

  @override
  Rect gridToGlobal(Rect rect) {
    final box = _boxOf(_viewportKey);
    return box == null ? rect : rect.shift(box.localToGlobal(Offset.zero));
  }

  Rect _gridToSurface(Rect rect) {
    final surface = _boxOf(_surfaceKey);
    final global = gridToGlobal(rect);
    return surface == null
        ? global
        : global.shift(surface.globalToLocal(Offset.zero));
  }

  @override
  void turnPage(int direction) {
    final page = grid?.page ?? 0;
    final target = page + direction;
    if (target < 0) return;
    unawaited(
      _pages.animateToPage(
        target,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  @override
  String folderNameFor(List<HomeGridItem> apps) {
    final l10n = context.l10n;
    Set<String> categoriesOf(HomeGridItem app) => {
      for (final category in [
        ...?app.app?.categories,
        ...?app.localApp?.categories,
      ])
        category.toLowerCase(),
    };
    final shared = apps.map(categoriesOf).reduce((a, b) => a.intersection(b));
    // Freedesktop main categories, most specific first.
    final names = <String, String>{
      'game': l10n.homeFolderGames,
      'development': l10n.homeFolderDevelopment,
      'graphics': l10n.homeFolderGraphics,
      'audiovideo': l10n.homeFolderMedia,
      'audio': l10n.homeFolderMedia,
      'video': l10n.homeFolderMedia,
      'office': l10n.homeFolderOffice,
      'network': l10n.homeFolderInternet,
      'education': l10n.homeFolderEducation,
      'science': l10n.homeFolderScience,
      'settings': l10n.homeFolderSettings,
      'system': l10n.homeFolderSystem,
      'utility': l10n.homeFolderUtilities,
    };
    for (final MapEntry(key: category, value: name) in names.entries) {
      if (shared.contains(category)) return name;
    }
    return l10n.homeFolderDefaultName;
  }

  // HomeInteractions ---------------------------------------------------------

  @override
  ValueListenable<Set<String>> get hiddenItems => _locator.hidden;

  @override
  void launch(HomeGridItem app, Rect iconRect) {
    if (_swallowTap || drag.active) return;
    unawaited(launchHomeApp(context, ref, app, iconRect));
  }

  @override
  void openFolder(HomeGridItem folder, Rect iconRect) {
    if (_swallowTap || drag.active) return;
    folders.show(folder.id, iconRect);
  }

  @override
  void hold(
    HomeGridItem item,
    int index,
    Rect tileRect,
    Offset pointer, {
    bool inFolder = false,
  }) {
    if (drag.active) return;
    if (item.resizable) {
      resize.enter(index);
      _heldWidget = (item: item, index: index, rect: tileRect, start: pointer);
      return;
    }
    resize.exit();
    drag.start(
      item: item,
      source: index,
      inFolder: inFolder,
      tileRect: tileRect,
      global: pointer,
    );
  }

  // Input --------------------------------------------------------------------

  void _pointerDown(PointerDownEvent event) {
    if (_pointer != null) return;
    _pointer = event.pointer;
    _swallowTap = false;
    if (resize.active && !_onResizeFrame(event.position)) {
      resize.exit();
      _swallowTap = true;
    }
    final onBackground =
        !_swallowTap &&
        !resize.active &&
        folders.open.value == null &&
        !_onItem(event.position);
    _taps.down(event, onBackground: onBackground);
  }

  void _pointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    _taps.move(event);
    final held = _heldWidget;
    if (held != null &&
        !drag.active &&
        (event.position - held.start).distance > _widgetDragSlop) {
      _heldWidget = null;
      resize.exit();
      drag.start(
        item: held.item,
        source: held.index,
        inFolder: false,
        tileRect: held.rect,
        global: held.start,
      );
    }
    drag.move(event.position);
  }

  void _pointerUp(PointerEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    _heldWidget = null;
    if (drag.active) {
      drag.move(event.position);
      drag.end(cancelled: event is PointerCancelEvent);
    }
    if (event is PointerUpEvent) {
      _taps.up(event);
    } else {
      _taps.reset();
    }
  }

  bool _onItem(Offset global) {
    final grid = this.grid;
    final geometry = _geometry;
    if (grid == null || geometry == null) return false;
    final cell = geometry.cellAt(globalToGrid(global), grid.page);
    return cell != null &&
        HomeGridLayout.anchorForCell(cell, grid.slots) != null;
  }

  bool _onResizeFrame(Offset global) {
    final index = resize.target.value;
    final grid = this.grid;
    final geometry = _geometry;
    final item = index == null || grid == null ? null : grid.slots[index];
    if (geometry == null || item == null) return false;
    return gridToGlobal(geometry.itemRect(index!, item))
        .inflate(HomeResizeFrame.handleExtent / 2)
        .contains(global);
  }

  void _sleepFromDoubleTap() =>
      ref.read(referenceShellProvider.notifier).blankDisplays();

  void _pageChanged(int page) {
    resize.exit();
    gridController.setPage(page);
    drag.refresh();
  }

  void _layout(HomeGridGeometry geometry) {
    _geometry = geometry;
    final grid = this.grid;
    if (grid == null || drag.active) return;
    if (geometry.orientation != gridController.orientation) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          gridController.arrange(geometry.orientation, geometry.pageSize);
        }
      });
      return;
    }
    final last =
        HomeGridLayout.pageCountForSlots(grid.slots, geometry.pageSize) - 1;
    if (grid.page > last) {
      // The last page emptied: return to the one before it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) gridController.setPage(last);
      });
    }
  }

  /// The icon a window transition starts or ends on: in the open folder, or
  /// on the current page.
  HomeIconTarget? _iconFor(DenialWindow window) {
    final grid = this.grid;
    final geometry = _geometry;
    if (grid == null || geometry == null) return null;
    final launcher = ref.read(appLauncherProvider);
    bool shows(HomeGridItem app) =>
        launcherAppShowsWindow(app, window, launcher);

    final open = folders.open.value;
    final layout = folders.layout;
    if (open != null && layout != null) {
      final folder = grid.slots
          .where((item) => item?.id == open.id)
          .firstOrNull;
      final apps = folder?.folderApps ?? const <HomeGridItem>[];
      final position = apps.indexWhere(shows);
      if (position >= 0) {
        return HomeIconTarget(
          item: apps[position],
          rect: HomeTileMetrics.iconRectIn(layout.tileRect(position)),
        );
      }
    }

    final start = grid.page * geometry.pageSize;
    for (var index = start; index < start + geometry.pageSize; index++) {
      if (index >= grid.slots.length) break;
      final item = grid.slots[index];
      if (item == null) continue;
      if ((item.isApp && shows(item)) ||
          (item.isFolder && item.folderApps.any(shows))) {
        return HomeIconTarget(
          item: item,
          rect: gridToGlobal(
            HomeTileMetrics.iconRectIn(geometry.rectAt(index)),
          ),
        );
      }
    }
    return null;
  }

  // Building -----------------------------------------------------------------

  Widget? _content;
  List<HomeGridItem?>? _contentSlots;
  bool? _contentError;

  /// The same grid widget while its slots hold: visibility, interactivity and
  /// opacity changes then rebuild only the wrappers above it, not each tile.
  Widget _contentFor(List<HomeGridItem?>? slots, bool hasError) {
    if (_content == null ||
        !identical(slots, _contentSlots) ||
        hasError != _contentError) {
      _contentSlots = slots;
      _contentError = hasError;
      _content = HomeInteractionScope(
        interactions: this,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Padding(
              padding: _contentPadding,
              child: HomePager(
                slots: slots,
                hasError: hasError,
                controller: _pages,
                viewportKey: _viewportKey,
                onLayout: _layout,
                onPageChanged: _pageChanged,
              ),
            ),
            Positioned.fill(
              child: HomeResizeFrame(
                geometry: () => _geometry,
                gridToLocal: _gridToSurface,
              ),
            ),
            const Positioned.fill(child: HomeFolderPanel()),
            const Positioned.fill(child: HomeDragLayer()),
          ],
        ),
      );
    }
    return _content!;
  }

  @override
  Widget build(BuildContext context) {
    final contents = ref.watch(
      homeGridControllerProvider.select(
        (value) => (slots: value.asData?.value.slots, hasError: value.hasError),
      ),
    );
    final opacity = widget.contentOpacity;
    final content = _contentFor(contents.slots, contents.hasError);
    return Offstage(
      offstage: !widget.active,
      child: TickerMode(
        enabled: widget.active,
        child: IgnorePointer(
          ignoring: !widget.interactive,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _pointerDown,
            onPointerMove: _pointerMove,
            onPointerUp: _pointerUp,
            onPointerCancel: _pointerUp,
            child: Stack(
              key: _surfaceKey,
              fit: StackFit.expand,
              children: [
                CustomPaint(painter: HomeBackdropPainter(opacity: opacity)),
                if (opacity == null)
                  content
                else
                  FadeSnapshot(opacity: opacity, child: content),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A double tap on home's empty background locks the device and blanks the
/// screen.
class _BackgroundTaps {
  _BackgroundTaps({required this.onDoubleTap});

  final VoidCallback onDoubleTap;

  static const Duration _maxTapDuration = Duration(milliseconds: 260);
  static const Duration _maxInterval = Duration(milliseconds: 360);
  static const double _moveTolerance = 18;
  static const double _distanceTolerance = 72;

  Offset? _start;
  Duration? _startTime;
  bool _valid = false;
  Offset? _lastTap;
  Duration? _lastTapTime;
  DateTime _lastFired = DateTime.fromMillisecondsSinceEpoch(0);

  void down(PointerDownEvent event, {required bool onBackground}) {
    _start = event.position;
    _startTime = event.timeStamp;
    _valid = onBackground;
  }

  void move(PointerMoveEvent event) {
    final start = _start;
    if (start != null && (event.position - start).distance > _moveTolerance) {
      _valid = false;
    }
  }

  void up(PointerUpEvent event) {
    final startTime = _startTime;
    final isTap =
        _valid &&
        startTime != null &&
        event.timeStamp - startTime <= _maxTapDuration;
    _start = null;
    _startTime = null;
    _valid = false;
    if (!isTap) {
      _lastTap = null;
      _lastTapTime = null;
      return;
    }
    final lastTap = _lastTap;
    final lastTime = _lastTapTime;
    if (lastTap != null &&
        lastTime != null &&
        event.timeStamp - lastTime <= _maxInterval &&
        (event.position - lastTap).distance <= _distanceTolerance) {
      _lastTap = null;
      _lastTapTime = null;
      final now = DateTime.now();
      if (now.difference(_lastFired) >= const Duration(seconds: 1)) {
        _lastFired = now;
        onDoubleTap();
      }
      return;
    }
    _lastTap = event.position;
    _lastTapTime = event.timeStamp;
  }

  void reset() {
    _start = null;
    _startTime = null;
    _valid = false;
  }
}
