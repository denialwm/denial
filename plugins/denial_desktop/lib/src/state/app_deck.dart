import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/physics.dart' show Simulation;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart'
    show BoxConstraints, EdgeInsets, Offset, Rect, Size;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:motor/motor.dart' as motor;

import 'package:denial_flutter_sdk/rendering.dart' show WindowPose;

import '../widgets/overview/overview_geometry.dart';
import 'reference_shell_metrics.dart';

final appDeckProvider = Provider<AppDeck>((ref) {
  final deck = AppDeck();
  ref.onDispose(deck.dispose);
  return deck;
});

/// An app leaving the deck for its home icon: where it is drawn and how fast
/// that rectangle moves, as centre x and y, width and height per second.
typedef DeckFlight = ({int objectId, Rect rect, List<double> velocity});

/// The open apps on screen, side by side in one row, from the moment the
/// bottom gesture or recents moves them until they rest again. Launcher3
/// calls this the recents animation: switching apps, lifting one into
/// recents, scrolling recents and opening a card are all this one motion.
///
/// Four values place every app, each on a spring that keeps its velocity:
///  * [open]: 0 the apps fill the screen, 1 they are recents cards;
///  * [row]: where the screen is along the row, in apps, 0 the oldest. One
///    past the newest app is home, when the motion began on home;
///  * [homeward]: how far recents has slid out sideways, toward home or in
///    from it, in screen widths. Its cards keep their size as they slide;
///  * [attached]: the other apps beside the one in the middle. An app lifted
///    toward home goes alone, and the others join it once recents arms, as
///    Launcher3 attaches recents to the app window.
///
/// [DeckGeometry.pose] turns them into each app's rectangle, and nothing else
/// moves an app while the deck presents. A finger holds a value where it is
/// and a release sends it on at the finger's speed, so any gesture takes
/// over from any other in mid-motion. The row keeps its order while the deck
/// presents: apps that close leave a gap the others close, apps that open
/// join at the end.
class AppDeck extends ChangeNotifier {
  AppDeck() {
    _ticker = Ticker(_tick, debugLabel: 'app deck');
  }

  late final Ticker _ticker;
  late final open = DeckAxis._(this, 0);
  late final row = DeckAxis._(this, 0);
  late final homeward = DeckAxis._(this, 0);
  late final attached = DeckAxis._(this, 1);

  List<int> _order = const <int>[];
  final _slots = <int, DeckAxis>{};

  /// Where the apps are drawn, published by the layer that draws them.
  DeckGeometry geometry = DeckGeometry.empty;

  /// The deck is on screen: something moves or is held, or recents is open.
  /// At rest with an app filling the screen, the app's own stage shows it.
  ValueListenable<bool> get presenting => _presenting;
  final _presenting = ValueNotifier(false);

  /// Home is on screen beside the apps: the row is moving between home and
  /// the newest app.
  ValueListenable<bool> get showsHome => _showsHome;
  final _showsHome = ValueNotifier(false);

  /// Home is in the row, one past the newest app: the motion began on home.
  bool homeInRow = false;

  /// The app flying home, until its flight lands or is recalled. The
  /// flight can outlast the deck's own motion.
  int? get flying => _flying;
  int? _flying;

  /// The app the deck does not draw: it flew home. The deck draws it again
  /// once it rests, or when the flight is recalled.
  int? get hidden => _hidden;
  int? _hidden;
  ({int objectId, double openRate})? _pendingFlight;

  /// Tells the flight of [recalled] to end where it is: a gesture took the
  /// deck back from home before the app reached its icon.
  Listenable get recall => _recall;
  final _recall = _Recall();
  int? get recalled => _recall.objectId;

  double? _lastTick;
  double _frameInterval = 1 / 120;

  /// Apps from oldest to newest, left to right.
  List<int> get order => _order;
  int get length => _order.length;
  int? indexOf(int? objectId) {
    if (objectId == null) return null;
    final index = _order.indexOf(objectId);
    return index < 0 ? null : index;
  }

  /// Where [objectId] sits along the row. It differs from its index only
  /// while the row closes a gap.
  double slotOf(int objectId) =>
      _slots[objectId]?.value ?? (indexOf(objectId) ?? 0).toDouble();

  bool get _moving =>
      open.moving ||
      row.moving ||
      homeward.moving ||
      attached.moving ||
      _slots.values.any((slot) => slot.moving);

  bool get _held => open.held || row.held;

  /// Lays the apps out at rest: [order] from oldest to newest, the screen at
  /// [rowAt], nothing open. Nothing moves on screen; the deck presents
  /// nothing at rest.
  void arrange(List<int> order, {required double rowAt}) {
    if (_moving || _held || open.value != 0) return;
    if (_flying case final id? when !order.contains(id)) _flying = null;
    _hidden = null;
    final same =
        listEquals(order, _order) &&
        row.value == rowAt &&
        homeward.value == 0 &&
        attached.value == 1 &&
        homeInRow == (rowAt >= order.length);
    if (same) return;
    if (!listEquals(order, _order)) {
      _order = List.unmodifiable(order);
      for (final slot in _slots.values) {
        slot._stop();
      }
      _slots
        ..clear()
        ..addEntries([
          for (final (index, id) in order.indexed)
            MapEntry(id, DeckAxis._(this, index.toDouble())),
        ]);
    }
    row._set(rowAt);
    homeward._set(0);
    attached._set(1);
    homeInRow = rowAt >= order.length;
    _changed();
  }

  /// Changes the row while the deck presents, without moving anything on
  /// screen: the app nearest the screen's centre keeps its place, and the
  /// others close any gap toward it. New apps join at the end.
  void reorder(List<int> order, motor.Motion motion) {
    if (listEquals(order, _order)) return;
    final previous = _order;
    _order = List.unmodifiable(order);
    final kept = [
      for (final id in order)
        if (previous.contains(id)) id,
    ];
    var shift = 0.0;
    if (kept.isNotEmpty) {
      final anchor = kept.reduce(
        (a, b) => (slotOf(a) - row.value).abs() <= (slotOf(b) - row.value).abs()
            ? a
            : b,
      );
      shift = order.indexOf(anchor) - (_slots[anchor]?.target ?? 0);
    }
    row.shift(shift);
    final removed = previous.where((id) => !order.contains(id));
    for (final id in removed) {
      _slots.remove(id)?._stop();
      if (_flying == id) _flying = null;
      if (_hidden == id) _hidden = null;
    }
    for (final (index, id) in order.indexed) {
      final slot = _slots[id];
      if (slot == null) {
        _slots[id] = DeckAxis._(this, index.toDouble());
        continue;
      }
      slot.shift(shift);
      if (slot.target != index) slot.settle(index.toDouble(), motion);
    }
    // The row comes to rest on an app, never on the gap a closed one left
    // at either end; home past the newest app counts only outside recents.
    final home = homeInRow && open.target == 0;
    final last = math.max(0, home ? order.length : order.length - 1);
    final onApp = row.target.clamp(0, last).toDouble();
    if (onApp != row.target && !row.held) row.settle(onApp, motion);
    _changed();
  }

  /// The app in front leaves for its home icon. [openRate] is how fast
  /// recents was opening as it left, in progress per second: the finger's
  /// speed when a swipe sends it.
  void sendHome(int objectId, {double openRate = 0}) {
    if (indexOf(objectId) == null) return;
    _pendingFlight = (objectId: objectId, openRate: openRate);
  }

  /// The app [sendHome] named, as it is now, for the flight that takes it.
  /// The deck stops drawing it.
  DeckFlight? takeFlight() {
    final pending = _pendingFlight;
    _pendingFlight = null;
    if (pending == null || geometry.isEmpty) return null;
    final id = pending.objectId;
    final slot = slotOf(id);
    final openRate = pending.openRate.clamp(-5.0, 5.0);
    const step = 1 / 240;
    final now = poseOf(id).rect;
    final next = geometry
        .pose(
          slot,
          length,
          open: open.value + openRate * step,
          row: row.value + row.velocity * step,
          homeward: homeward.value + homeward.velocity * step,
          attached: attached.value + attached.velocity * step,
        )
        .rect;
    _flying = _hidden = id;
    _changed();
    return (
      objectId: id,
      rect: now,
      velocity: [
        (next.center.dx - now.center.dx) / step,
        (next.center.dy - now.center.dy) / step,
        (next.width - now.width) / step,
        (next.height - now.height) / step,
      ],
    );
  }

  /// Where the deck draws [objectId] now.
  WindowPose poseOf(int objectId) => geometry.pose(
    slotOf(objectId),
    length,
    open: open.value,
    row: row.value,
    homeward: homeward.value,
    attached: attached.value,
  );

  /// The flight home of [objectId] has reached its icon.
  void flightLanded(int objectId) {
    if (_flying != objectId) return;
    _flying = null;
    _changed();
  }

  /// Ends the flight home at once and draws its app again. The caller puts
  /// the deck where the app may show.
  void recallFlight() {
    final id = _flying;
    _flying = _hidden = null;
    if (id != null) _recall.call(id);
    _changed();
  }

  /// The motion is within a hair of rest with nothing open: nothing held
  /// and every value nearer its target than a pixel or two.
  bool get nearRest {
    if (_held || open.target != 0) return false;
    for (final axis in [open, row, homeward, attached, ..._slots.values]) {
      if ((axis.value - axis.target).abs() > 0.005) return false;
    }
    return true;
  }

  /// Puts every value at its target at once, where it was about to rest.
  void finish() {
    for (final axis in [open, row, homeward, attached, ..._slots.values]) {
      axis._set(axis.target);
    }
    _changed();
  }

  /// Stops everything where it is, as the lock screen does.
  void halt() {
    for (final axis in [open, row, homeward, attached, ..._slots.values]) {
      axis._stop();
      axis.held = false;
    }
    open._set(0);
    homeward._set(0);
    _changed();
  }

  /// Recents waits beside home to slide in, its newest card nearest, held
  /// there until a finger or a spring moves it.
  void enterFromHome() {
    open._set(1);
    homeward._set(1);
    homeward.held = true;
    attached._set(1);
    row._set(math.max(0, length - 1).toDouble());
    _changed();
  }

  /// How much of recents shows, 0 to 1, for what fades in with it.
  double get shown =>
      open.value.clamp(0.0, 1.0) * (1 - homeward.value.clamp(0.0, 1.0));

  void _start() {
    if (!_ticker.isActive) _ticker.start();
    _changed();
  }

  void _tick(Duration elapsed) {
    final now = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final last = _lastTick;
    // A spring that starts between frames moves on the next one already.
    final dt = last == null ? _frameInterval : now - last;
    if (last != null && dt > 0) {
      _frameInterval = dt.clamp(1 / 240, 1 / 30);
    }
    _lastTick = now;
    var moving = false;
    for (final axis in [open, row, homeward, attached, ..._slots.values]) {
      if (axis._step(dt)) moving = true;
    }
    if (!moving) {
      _ticker.stop();
      _lastTick = null;
    }
    _changed();
  }

  void _changed() {
    // Recents slid all the way out is home: nothing is open.
    if (homeward.value >= 1 && !homeward.moving && !homeward.held) {
      homeward._set(0);
      open._set(0);
    }
    final presenting = _moving || _held || open.value > 0;
    if (!presenting) _hidden = null;
    // Whoever draws the apps at rest hears of it in the same frame as the
    // deck's own listeners.
    _presenting.value = presenting;
    _showsHome.value =
        presenting &&
        homeInRow &&
        open.value < 1 &&
        row.value > length - 1 + 1e-6;
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _recall.dispose();
    _presenting.dispose();
    _showsHome.dispose();
    super.dispose();
  }
}

class _Recall extends ChangeNotifier {
  int? objectId;

  void call(int id) {
    objectId = id;
    notifyListeners();
  }
}

/// One of the deck's values: held by a finger, or on a spring toward its
/// [target].
class DeckAxis {
  DeckAxis._(this._deck, double value) : _value = value, _target = value;

  final AppDeck _deck;
  double _value;
  double _target;
  double _velocity = 0;
  Simulation? _simulation;
  double _time = 0;
  double _offset = 0;

  /// A finger holds the value.
  bool held = false;
  double _grab = 0;

  /// Where the finger took the value.
  double get grabbedAt => _grab;

  double get value => _value;
  double get target => _target;

  /// Units per second.
  double get velocity => _simulation == null ? 0 : _velocity;
  bool get moving => _simulation != null;

  /// A finger takes the value where it is.
  void grab() {
    hold(_value);
    _grab = _value;
  }

  /// Holds the value at [value], from a finger.
  void hold(double value) {
    _simulation = null;
    held = true;
    _value = _target = value;
    _velocity = 0;
    _deck._changed();
  }

  /// Sends the value to [target] on [motion], continuing at [velocity], or
  /// at the velocity it has.
  void settle(double target, motor.Motion motion, {double? velocity}) {
    final speed = velocity ?? this.velocity;
    if (_value == target && speed == 0) {
      held = false;
      _target = target;
      _simulation = null;
      _deck._changed();
      return;
    }
    _run(
      target,
      motion.createSimulation(start: _value, end: target, velocity: speed),
      speed,
    );
  }

  /// Coasts to [target] from [velocity], slowing down like a fling under
  /// friction, and stops there without overshooting. [target] must lie
  /// ahead in [velocity]'s direction.
  void glide(double target, double velocity) =>
      _run(target, _Glide(_value, target, velocity), velocity);

  /// How long [glide] takes from here to [target] at [velocity], in seconds.
  double glideTime(double target, double velocity) =>
      _Glide.durationFor(target - _value, velocity);

  void _run(double target, Simulation simulation, double speed) {
    held = false;
    _target = target;
    _simulation = simulation;
    _time = 0;
    _offset = 0;
    _velocity = speed;
    _deck._start();
  }

  /// Moves the value's coordinates by [by] without moving it on screen or
  /// restarting its spring.
  void shift(double by) {
    if (by == 0) return;
    _value += by;
    _target += by;
    _offset += by;
    _grab += by;
  }

  /// Puts the value at [value] at once, where no one sees it move.
  void jump(double value) {
    _set(value);
    _deck._changed();
  }

  void _set(double value) {
    _simulation = null;
    held = false;
    _value = _target = value;
    _velocity = 0;
  }

  void _stop() {
    _simulation = null;
    _velocity = 0;
  }

  bool _step(double dt) {
    final simulation = _simulation;
    if (simulation == null) return false;
    _time += dt;
    final x = simulation.x(_time) + _offset;
    final v = simulation.dx(_time);
    // Within a fraction of a pixel and barely moving is rest: a spring's
    // long tail would keep the apps from taking touches.
    final still = (x - _target).abs() < 1e-3 && v.abs() < 0.02;
    if (still || simulation.isDone(_time)) {
      _simulation = null;
      _value = _target;
      _velocity = 0;
      return false;
    }
    _value = x;
    _velocity = v;
    return true;
  }
}

/// A fling slowing to a stop at a chosen point: a cubic ease-out whose
/// starting speed is the fling's.
class _Glide extends Simulation {
  _Glide(this._start, this._end, double velocity)
    : _duration = durationFor(_end - _start, velocity);

  final double _start;
  final double _end;
  final double _duration;

  static double durationFor(double distance, double velocity) =>
      velocity == 0 || distance * velocity <= 0
      ? double.infinity
      : 3 * distance / velocity;

  double _u(double time) => (time / _duration).clamp(0.0, 1.0);

  @override
  double x(double time) {
    final rest = 1 - _u(time);
    return _end - (_end - _start) * rest * rest * rest;
  }

  @override
  double dx(double time) {
    final rest = 1 - _u(time);
    return 3 * (_end - _start) * rest * rest / _duration;
  }

  @override
  bool isDone(double time) => time >= _duration;
}

/// Where the deck draws each app, from the deck's four values.
@immutable
class DeckGeometry {
  DeckGeometry({
    required this.size,
    required this.padding,
    required this.windowRadius,
    required this.switchRadius,
    required this.ltr,
  }) : card = centerPreviewRectFor(
         size,
         cardSizeFor(
           constraints: BoxConstraints.tight(size),
           padding: padding,
           aspect: viewAspectFor(size),
         ),
       );

  static final empty = DeckGeometry(
    size: Size.zero,
    padding: EdgeInsets.zero,
    windowRadius: 0,
    switchRadius: 0,
    ltr: true,
  );

  final Size size;
  final EdgeInsets padding;

  /// The corners of a recents card.
  final double windowRadius;

  /// The corners of apps sliding side by side.
  final double switchRadius;
  final bool ltr;

  /// The portrait recents card in the screen's centre.
  final Rect card;

  bool get isEmpty => size.isEmpty;
  bool get landscape => size.width > size.height;
  Rect get screen => Offset.zero & size;
  double get _sign => ltr ? 1 : -1;

  /// One app's width plus the gap to the next, in logical pixels, with
  /// recents [open] that far.
  double strideAt(double open) => lerpDouble(
    size.width + ReferenceShellMetrics.appSwitchGap,
    landscape
        ? size.width + ReferenceShellMetrics.appSwitchGap
        : card.width + overviewPageSpacing,
    open.clamp(0.0, 1.0),
  )!;

  /// Finger travel that lifts an app from the screen into its card: the
  /// app's bottom edge stays under the finger. From home, a fixed share of
  /// the screen opens recents.
  double liftTravel({required bool fromApp}) => fromApp
      ? math.max(1.0, size.height - card.bottom)
      : math.max(1.0, size.height * 0.45);

  /// A horizontal finger travel [dx] as a change of the row, in apps.
  double rowDelta(double dx, double open) => -dx * _sign / strideAt(open);

  /// A row change in apps as finger travel, in logical pixels.
  double rowTravel(double apps, double open) => -apps * _sign * strideAt(open);

  /// The app at [slot] of [count], with recents [open] that far, the screen
  /// at [row] along the row, recents [homeward] that far and the other apps
  /// [attached] that far.
  ///
  /// At 0 open the apps lie side by side, a gap apart, filling the screen;
  /// at 1 they are recents cards. Homeward, they slide a screen sideways,
  /// as they are, out to home or in from it: the middle one and the older
  /// ones toward the older side, the newer ones the other way, so none is
  /// left on screen. Detached, the apps beside the middle one wait a screen
  /// further out.
  WindowPose pose(
    double slot,
    int count, {
    required double open,
    required double row,
    required double homeward,
    required double attached,
  }) {
    final p = open.clamp(0.0, 1.0);
    final h = homeward.clamp(0.0, 1.0);
    final along = slot - row;
    final offset = along * _sign;
    final leave = landscape ? -1.0 : along.clamp(0.0, 1.0) * 2 - 1;
    final away = leave * h * size.width * _sign;
    final aside =
        (1 - attached.clamp(0.0, 1.0)) *
        along.clamp(-1.0, 1.0) *
        size.width *
        _sign;
    final Rect app;
    if (landscape) {
      app = Rect.lerp(
        screen,
        _gridRect(slot, count),
        p,
      )!.shift(Offset(offset * strideAt(0) * (1 - p), 0));
    } else {
      app = Rect.lerp(screen, card, p)!.shift(Offset(offset * strideAt(p), 0));
    }
    // Sliding apps round their corners as soon as they leave the screen's
    // edges, and square them again as they come to rest.
    final apart = ((row - row.roundToDouble()).abs() * 8).clamp(0.0, 1.0);
    final appRadius = math.max(
      lerpDouble(0, windowRadius, p)!,
      switchRadius * apart,
    );
    return WindowPose(app.shift(Offset(away + aside, 0)), appRadius);
  }

  /// Landscape recents is a grid, newest app first.
  Rect _gridRect(double slot, int count) {
    if (count <= 0) return card;
    final layout = landscapeOverviewLayoutFor(
      viewSize: size,
      padding: padding,
      itemCount: count,
      aspect: viewAspectFor(size),
    );
    final cell = (count - 1 - slot).clamp(0.0, count - 1.0);
    final before = cell.floor();
    final after = cell.ceil();
    return Rect.lerp(
      layout.previewRectAt(before),
      layout.previewRectAt(after),
      cell - before,
    )!;
  }

  @override
  bool operator ==(Object other) =>
      other is DeckGeometry &&
      other.size == size &&
      other.padding == padding &&
      other.windowRadius == windowRadius &&
      other.switchRadius == switchRadius &&
      other.ltr == ltr;

  @override
  int get hashCode =>
      Object.hash(size, padding, windowRadius, switchRadius, ltr);
}
