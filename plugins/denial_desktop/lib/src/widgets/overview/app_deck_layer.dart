import 'package:denial_desktop/src/state/app_deck.dart';
import 'package:denial_desktop/src/state/reference_shell_metrics.dart';

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:motor/motor.dart' as motor;

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/rendering.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';

import 'overview_card_label.dart';
import 'overview_chrome.dart';

/// Draws the open apps wherever the [deck] has them, while it presents:
/// switching, lifting into recents, recents itself, a card opening, and
/// recents leaving for home. At rest with an app filling the screen it draws
/// nothing, and the app's own stage shows the app.
///
/// In recents a tap opens a card, a card swiped up closes its app, a
/// sideways drag scrolls the row, and a tap beside the cards goes home.
class AppDeckLayer extends StatefulWidget {
  const AppDeckLayer({
    super.key,
    required this.deck,
    required this.windows,
    required this.recents,
    this.backdrop,
    required this.onPresentationChanged,
    this.onProgressChanged,
    required this.onCloseRecents,
    required this.onDismissWindow,
    required this.onOpenWindow,
    this.onMoveWindowToDesk,
  });

  final AppDeck deck;

  /// The open apps.
  final List<DenialWindow> windows;

  /// Recents is open or opening, and takes touches.
  final bool recents;

  /// The scene behind recents, frosted once. Translucent apps draw slices of
  /// it as their glass instead of filtering the scene on every frame.
  final ValueListenable<FrostedBackdrop?>? backdrop;
  final ValueChanged<bool> onPresentationChanged;

  /// How far recents is open, for the launcher beneath.
  final ValueChanged<double>? onProgressChanged;
  final VoidCallback onCloseRecents;
  final ValueChanged<DenialWindow> onDismissWindow;
  final ValueChanged<DenialWindow> onOpenWindow;

  /// Moves an app to the monitor beside the phone; none without a monitor.
  final ValueChanged<DenialWindow>? onMoveWindowToDesk;

  @override
  State<AppDeckLayer> createState() => _AppDeckLayerState();
}

class _AppDeckLayerState extends State<AppDeckLayer> {
  /// How far a fling carries the recents row, in seconds of its speed.
  static const double _rowFlingProjection = 0.35;

  /// A fling coasts to its card for at least this long, in seconds; a card
  /// nearer than that is passed for the next one. Slower than the longest,
  /// a release springs to the nearest card instead.
  static const double _shortestGlide = 0.3;
  static const double _longestGlide = 1.1;

  final _open = ValueNotifier(0.0);
  late final Animation<double> _openAnimation = Animation.fromValueListenable(
    _open,
  );
  late final Animation<double> _labelOpacity = Animation.fromValueListenable(
    _open,
    transformer: const Interval(0.7, 1).transform,
  );
  var _windows = <int, DenialWindow>{};
  final _poses = <int, ValueNotifier<WindowPose>>{};

  /// The apps drawn, back to front.
  List<int> _drawn = const <int>[];
  bool _presenting = false;

  bool _rowDragging = false;
  double _rowDrag = 0;

  /// A touch stopped the recents row where it was.
  bool _rowCaught = false;

  @override
  void initState() {
    super.initState();
    _indexWindows();
    widget.deck.addListener(_update);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final theme = context.shellTheme;
    final geometry = DeckGeometry(
      size: MediaQuery.sizeOf(context),
      padding: MediaQuery.paddingOf(context),
      windowRadius: theme.windowRadius,
      switchRadius: theme.scaledRadius(18),
      ltr: Directionality.of(context) == TextDirection.ltr,
    );
    if (geometry != widget.deck.geometry) {
      widget.deck.geometry = geometry;
      WidgetsBinding.instance.addPostFrameCallback((_) => _update());
    }
  }

  @override
  void didUpdateWidget(covariant AppDeckLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.deck != oldWidget.deck) {
      oldWidget.deck.removeListener(_update);
      widget.deck.addListener(_update);
    }
    if (!identical(widget.windows, oldWidget.windows)) _indexWindows();
    if (!widget.recents) _endRowDrag(null);
  }

  @override
  void dispose() {
    widget.deck.removeListener(_update);
    for (final pose in _poses.values) {
      pose.dispose();
    }
    _open.dispose();
    super.dispose();
  }

  void _indexWindows() {
    _windows = {for (final window in widget.windows) window.objectId: window};
    _poses.removeWhere((id, pose) {
      if (_windows.containsKey(id)) return false;
      WidgetsBinding.instance.addPostFrameCallback((_) => pose.dispose());
      return true;
    });
  }

  /// Poses every app from the deck's values, and draws those on screen with
  /// the one nearest the screen's centre in front.
  void _update() {
    if (!mounted) return;
    final deck = widget.deck;
    final shown = deck.shown;
    _open.value = shown;
    widget.onProgressChanged?.call(shown);
    final presenting = deck.presenting.value;
    final geometry = deck.geometry;
    final drawn = <(int, double)>[];
    if (presenting && !geometry.isEmpty) {
      final screen = geometry.screen;
      final row = deck.row.value;
      for (final id in deck.order) {
        if (id == deck.hidden || !_windows.containsKey(id)) continue;
        final slot = deck.slotOf(id);
        final pose = deck.poseOf(id);
        (_poses[id] ??= ValueNotifier(pose)).value = pose;
        if (pose.rect.overlaps(screen)) drawn.add((id, (slot - row).abs()));
      }
      drawn.sort((a, b) => b.$2.compareTo(a.$2));
    }
    final ids = [for (final (id, _) in drawn) id];
    if (presenting != _presenting) {
      widget.onPresentationChanged(presenting);
    }
    if (presenting != _presenting || !listEquals(ids, _drawn)) {
      setState(() {
        _presenting = presenting;
        _drawn = ids;
      });
    }
  }

  // The recents row under the finger --------------------------------------

  void _catchRow(PointerDownEvent event) {
    final row = widget.deck.row;
    if (!widget.recents || !row.moving || row.held) return;
    row.grab();
    _rowCaught = true;
  }

  void _releaseCatch(PointerEvent event) {
    if (!_rowCaught || _rowDragging) return;
    _rowCaught = false;
    final row = widget.deck.row;
    if (row.held) {
      row.settle(_nearestCard(row.value), ShellSprings.appStrip);
    }
  }

  void _startRowDrag(DragStartDetails details) {
    final deck = widget.deck;
    if (!widget.recents || deck.geometry.landscape || deck.length == 0) {
      return;
    }
    if (!deck.row.held) deck.row.grab();
    _rowDragging = true;
    _rowCaught = false;
    _rowDrag = 0;
  }

  void _moveRow(DragUpdateDetails details) {
    if (!_rowDragging) return;
    final deck = widget.deck;
    _rowDrag += details.delta.dx;
    final position = deck.row.grabbedAt + deck.geometry.rowDelta(_rowDrag, 1);
    deck.row.hold(_stretch(position));
  }

  /// A fling coasts on to the card nearest where it would come to rest, or
  /// runs past the first or last card and bounces back; a slow release
  /// springs to the nearest card.
  void _endRowDrag(DragEndDetails? details) {
    if (!_rowDragging) return;
    _rowDragging = false;
    final deck = widget.deck;
    final row = deck.row;
    final rate = deck.geometry.rowDelta(
      details?.velocity.pixelsPerSecond.dx ?? 0,
      1,
    );
    final last = math.max(0, deck.length - 1).toDouble();
    var target = (row.value + rate * _rowFlingProjection).roundToDouble();
    if (row.glideTime(target, rate) < _shortestGlide) target += rate.sign;
    if (target < 0 || target > last) {
      // Already past the end, the stretch springs back on its own.
      final outside = row.value < 0 || row.value > last;
      row.settle(
        target < 0 ? 0.0 : last,
        ShellSprings.recentsEdge,
        velocity: outside ? 0 : rate,
      );
    } else if (row.glideTime(target, rate) <= _longestGlide) {
      row.glide(target, rate);
    } else {
      row.settle(
        _nearestCard(row.value),
        ShellSprings.appStrip,
        velocity: rate,
      );
    }
  }

  double _nearestCard(double position) =>
      position.roundToDouble().clamp(0.0, math.max(0, widget.deck.length - 1));

  /// Past the first and last card the row stretches elastically.
  double _stretch(double position) {
    final deck = widget.deck;
    final last = math.max(0, deck.length - 1).toDouble();
    final edge = position.clamp(0.0, last).toDouble();
    final stride = deck.geometry.strideAt(1);
    final extent = deck.geometry.size.width;
    final past = (position - edge) * stride;
    if (past == 0 || stride <= 0 || extent <= 0) return edge;
    const resistance = 0.55;
    final stretch = 1 - 1 / (past.abs() * resistance / extent + 1);
    return edge + past.sign * stretch * extent / stride;
  }

  @override
  Widget build(BuildContext context) {
    if (!_presenting) return const SizedBox.shrink();
    final deck = widget.deck;
    final geometry = deck.geometry;
    final interactive = widget.recents;
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !interactive,
        child: Listener(
          onPointerDown: _catchRow,
          onPointerUp: _releaseCatch,
          onPointerCancel: _releaseCatch,
          child: GestureDetector(
            onHorizontalDragStart: _startRowDrag,
            onHorizontalDragUpdate: _moveRow,
            onHorizontalDragEnd: _endRowDrag,
            onHorizontalDragCancel: () => _endRowDrag(null),
            child: ValueListenableBuilder<FrostedBackdrop?>(
              valueListenable:
                  widget.backdrop ??
                  const AlwaysStoppedAnimation<FrostedBackdrop?>(null),
              builder: (context, backdrop, stack) => WindowBackdropCache(
                backdrop: backdrop,
                motion: deck,
                overlayColor: OverviewScrim.colorOf(context),
                overlayOpacity: _open,
                child: stack!,
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  OverviewScrim(
                    opacity: _openAnimation,
                    onTap: widget.onCloseRecents,
                  ),
                  if (deck.length == 0)
                    EmptyOverviewState(progress: _openAnimation),
                  for (final id in _drawn)
                    if ((_windows[id], _poses[id]) case (
                      final window?,
                      final pose?,
                    ))
                      _DeckCard(
                        key: ValueKey<int>(id),
                        window: window,
                        pose: pose,
                        labelWidth: geometry.card.width,
                        labelOpacity: geometry.landscape ? null : _labelOpacity,
                        onOpen: widget.onOpenWindow,
                        onDismissed: widget.onDismissWindow,
                        onMoveToDesk: widget.onMoveWindowToDesk,
                      ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One app as the deck poses it. In recents it is a card: a tap opens it,
/// and a swipe up throws it away.
class _DeckCard extends StatefulWidget {
  const _DeckCard({
    super.key,
    required this.window,
    required this.pose,
    required this.labelWidth,
    required this.labelOpacity,
    required this.onOpen,
    required this.onDismissed,
    this.onMoveToDesk,
  });

  final DenialWindow window;
  final ValueListenable<WindowPose> pose;
  final double labelWidth;

  /// The app's icon and name above the card; none without it.
  final Animation<double>? labelOpacity;
  final ValueChanged<DenialWindow> onOpen;
  final ValueChanged<DenialWindow> onDismissed;
  final ValueChanged<DenialWindow>? onMoveToDesk;

  @override
  State<_DeckCard> createState() => _DeckCardState();
}

class _DeckCardState extends State<_DeckCard>
    with SingleTickerProviderStateMixin {
  // Android 16 TaskViewDismissTouchController: half the off-screen travel,
  // 25dp undershoot, and BaseSwipeDetector's 1dp/ms release threshold.
  static const double _downwardRubberBandLimit = 25.0;
  static const double _dismissDistanceRatio = 0.5;
  static const double _dismissFlingVelocity = 1000.0;
  static const double _offscreenMargin = 16.0;

  /// A card swiped away shrinks as it leaves.
  static const double _dismissShrink = 0.1;

  /// How far the card is thrown up, in logical pixels, negative upward.
  late final motor.SingleMotionController _throw;
  late final _CardPose _pose;
  double _drag = 0;
  double _exit = -double.maxFinite;
  bool _leaving = false;
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    _throw = motor.SingleMotionController(
      motion: ShellSprings.cardReturn,
      vsync: this,
      initialValue: 0,
    )..addListener(_checkGone);
    _pose = _CardPose(widget.pose, _throw);
  }

  @override
  void didUpdateWidget(covariant _DeckCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pose != oldWidget.pose) _pose.base = widget.pose;
  }

  @override
  void dispose() {
    _pose.dispose();
    _throw.dispose();
    super.dispose();
  }

  void _startDrag(DragStartDetails details) {
    if (_leaving) return;
    _throw.stop(canceled: true);
    _pose.length = math.max(
      1.0,
      _pose.base.value.rect.bottom + _offscreenMargin,
    );
    final value = _throw.value;
    final length = _pose.length;
    // Continue from where the card is, also inside its downward stretch.
    _drag = value <= 0
        ? value
        : length *
              (1 -
                  math.sqrt(
                    1 - (value / _downwardRubberBandLimit).clamp(0.0, 1.0),
                  ));
  }

  void _moveDrag(DragUpdateDetails details) {
    if (_leaving) return;
    _drag += details.delta.dy;
    final length = _pose.length;
    if (_drag <= 0) {
      _throw.value = _drag.clamp(-length, 0.0);
    } else {
      // Resistance unwinds smoothly when the finger reverses.
      final fraction = (_drag / length).clamp(0.0, 1.0);
      _throw.value =
          _downwardRubberBandLimit * Curves.decelerate.transform(fraction);
    }
  }

  void _endDrag(DragEndDetails details) {
    if (_leaving) return;
    final velocity = details.velocity.pixelsPerSecond.dy.clamp(-8000.0, 8000.0);
    final passed = _throw.value < -_pose.length * _dismissDistanceRatio;
    final flingUp = velocity < -_dismissFlingVelocity;
    final flingDown = velocity > _dismissFlingVelocity;
    // The release's direction comes before distance: thrown back down, a
    // card returns even past the threshold.
    if (flingUp || (passed && !flingDown)) {
      _leaving = true;
      _exit = -_pose.length;
      _throw
        ..motion = ShellSprings.cardDismiss
        ..animateTo(_exit, withVelocity: velocity);
    } else {
      _settleBack(velocity);
    }
  }

  void _settleBack([double velocity = 0]) {
    if (_leaving) return;
    _throw
      ..motion = ShellSprings.cardReturn
      ..animateTo(0, withVelocity: velocity);
  }

  /// The app closes as soon as its card has left the screen; the spring's
  /// tail past that would only delay it.
  void _checkGone() {
    if (!_leaving || _dismissed || _throw.value > _exit + _offscreenMargin) {
      return;
    }
    _dismissed = true;
    final window = widget.window;
    // Present this last frame before releasing the app's surface.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _throw.stop(canceled: true);
      widget.onDismissed(window);
    });
  }

  @override
  Widget build(BuildContext context) {
    final labelOpacity = widget.labelOpacity;
    final onMoveToDesk = widget.onMoveToDesk;
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          child: WindowBackdropMotion(
            motion: _pose,
            child: PosedWindow(
              pose: _pose,
              child: WindowSurface(
                window: widget.window,
                contentPadding: EdgeInsets.only(
                  top: ReferenceShellMetrics.appStatusInset(
                    MediaQuery.sizeOf(context),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (labelOpacity != null)
          Positioned(
            left: 0,
            top: 0,
            width: widget.labelWidth,
            height: OverviewCardLabel.height,
            child: IgnorePointer(
              child: CompositedTranslation(
                translation: _pose.label,
                devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                child: FadeTransition(
                  opacity: labelOpacity,
                  child: OverviewCardLabel(
                    window: widget.window,
                    trailingSpace: onMoveToDesk == null
                        ? 0
                        : _MoveToDeskButton.size + OverviewCardLabel.gap,
                  ),
                ),
              ),
            ),
          ),
        _PoseHitRegion(
          pose: _pose,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (!_leaving) widget.onOpen(widget.window);
            },
            onVerticalDragStart: _startDrag,
            onVerticalDragUpdate: _moveDrag,
            onVerticalDragEnd: _endDrag,
            onVerticalDragCancel: _settleBack,
          ),
        ),
        if (labelOpacity != null && onMoveToDesk != null)
          Positioned(
            left: 0,
            top: 0,
            width: widget.labelWidth,
            height: OverviewCardLabel.height,
            child: _TranslatedHitRegion(
              translation: _pose.label,
              child: CompositedTranslation(
                translation: _pose.label,
                devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                child: FadeTransition(
                  opacity: labelOpacity,
                  child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: _MoveToDeskButton(
                      onTap: () {
                        if (!_leaving) onMoveToDesk(widget.window);
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The deck's pose of a card, thrown up and shrinking as it leaves.
class _CardPose extends ChangeNotifier implements ValueListenable<WindowPose> {
  _CardPose(this._base, this._throw) {
    _base.addListener(_changed);
    _throw.addListener(_changed);
    _changed();
  }

  ValueListenable<WindowPose> _base;
  final Animation<double> _throw;

  /// How far the card travels to leave the screen.
  double length = 1;

  /// Where the card's label goes: above its top edge.
  final label = ValueNotifier(Offset.zero);

  ValueListenable<WindowPose> get base => _base;
  set base(ValueListenable<WindowPose> value) {
    if (identical(value, _base)) return;
    _base.removeListener(_changed);
    _base = value..addListener(_changed);
    _changed();
  }

  @override
  WindowPose get value {
    final pose = _base.value;
    final dy = _throw.value;
    if (dy == 0) return pose;
    final shrink =
        1 - _DeckCardState._dismissShrink * (-dy / length).clamp(0.0, 1.0);
    final rect = pose.rect;
    return WindowPose(
      Rect.fromCenter(
        center: rect.center.translate(0, dy),
        width: rect.width * shrink,
        height: rect.height * shrink,
      ),
      pose.radius * shrink,
      opacity: pose.opacity,
    );
  }

  void _changed() {
    final rect = value.rect;
    label.value = Offset(
      rect.left,
      rect.top - OverviewCardLabel.gap - OverviewCardLabel.height,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _base.removeListener(_changed);
    _throw.removeListener(_changed);
    label.dispose();
    super.dispose();
  }
}

/// Takes touches only inside its [pose], in the screen's coordinates.
class _PoseHitRegion extends SingleChildRenderObjectWidget {
  const _PoseHitRegion({required this.pose, super.child});

  final ValueListenable<WindowPose> pose;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPoseHitRegion(pose);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderPoseHitRegion).pose = pose;
  }
}

class _RenderPoseHitRegion extends RenderProxyBox {
  _RenderPoseHitRegion(this.pose);

  ValueListenable<WindowPose> pose;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final current = pose.value;
    if (current.opacity <= 0 ||
        !RRect.fromRectAndRadius(
          current.rect,
          Radius.circular(current.radius),
        ).contains(position)) {
      return false;
    }
    return super.hitTest(result, position: position);
  }
}

/// Hit tests its child where [translation] paints it.
class _TranslatedHitRegion extends SingleChildRenderObjectWidget {
  const _TranslatedHitRegion({required this.translation, super.child});

  final ValueListenable<Offset> translation;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTranslatedHitRegion(translation);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderTranslatedHitRegion).translation = translation;
  }
}

class _RenderTranslatedHitRegion extends RenderProxyBox {
  _RenderTranslatedHitRegion(this.translation);

  ValueListenable<Offset> translation;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final offset = translation.value;
    return result.addWithPaintOffset(
      offset: offset,
      position: position,
      hitTest: (result, transformed) =>
          super.hitTest(result, position: transformed),
    );
  }
}

/// Sends a card's app to the monitor beside the phone.
class _MoveToDeskButton extends StatelessWidget {
  const _MoveToDeskButton({required this.onTap});

  static const double size = 40;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dark = ShellTheme.of(context).brightness == Brightness.dark;
    final ink = dark ? const Color(0xFFF5F5F7) : const Color(0xFF1C1C1E);
    return Semantics(
      button: true,
      label: context.l10n.moveToMonitor,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: dark ? const Color(0x73000000) : const Color(0x8CFFFFFF),
            border: Border.all(
              color: dark ? const Color(0x24FFFFFF) : const Color(0x1F000000),
            ),
          ),
          child: Icon(Icons.desktop_windows_rounded, size: 20, color: ink),
        ),
      ),
    );
  }
}
