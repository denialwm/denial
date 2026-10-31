import 'dart:async' show scheduleMicrotask;
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:motor/motor.dart' as motor;

import 'package:denial_flutter_sdk/applications.dart'
    show HomeGridItem, homeGridControllerProvider;
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/motion.dart'
    show RectCenterSizeConverter, ShellSprings;
import 'package:denial_flutter_sdk/rendering.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';

import '../launcher/home_grid_geometry.dart';
import '../launcher/home_icon_locator.dart';
import '../launcher/widgets/home_item_icon.dart';
import '../launcher/widgets/launcher_icon.dart';
import '../launcher/widgets/rect_follower.dart';
import '../state/reference_shell_controller.dart';
import '../state/reference_shell_metrics.dart';
import 'overview/overview_geometry.dart';

enum _Heading { open, home }

/// Apps flying between their home icon and the screen, both ways.
///
/// Each app is one flight: one rectangle on a spring, which a launch sends
/// to the screen and home sends back to the icon. Interrupting a flight only
/// retargets that spring, so it reverses from where it is with the speed it
/// has: going home mid-launch shrinks the opening card back into its icon,
/// and tapping the icon of an app still flying home grows it out again.
///
/// The card's look is a function of its size alone, the same in both
/// directions: near the icon's size the icon covers it, and the window, or
/// the glass a new app opens on, shows as it grows. A new app's first frame
/// fades in where the glass was, wherever the card is.
///
/// A launch hands the app over as soon as its window is on screen and the
/// card has arrived; the glass finishes fading over the live app, which
/// already takes input. While a launch flies, the bottom gesture holds the
/// card, and its release sends the card home or back to the screen with the
/// finger's speed.
class AppFlightLayer extends ConsumerStatefulWidget {
  const AppFlightLayer({super.key});

  @override
  ConsumerState<AppFlightLayer> createState() => _AppFlightLayerState();
}

class _AppFlightLayerState extends ConsumerState<AppFlightLayer>
    with TickerProviderStateMixin {
  /// The icon riding a new app's card, once the card fills the screen.
  static const double _placeholderIcon = 112;

  static const _converter = RectCenterSizeConverter();

  final _flights = <_Flight>[];
  late final ReferenceShellController _shell = ref.read(
    referenceShellProvider.notifier,
  );
  late final HomeIconLocator _locator = ref.read(homeIconLocatorProvider);
  late final ValueListenable<Offset> _drag = _shell.gestureDrag;

  AppLaunchRequest? _request;
  bool _started = false;
  Size _size = Size.zero;
  EdgeInsets _padding = EdgeInsets.zero;
  double _windowRadius = 0;

  Rect get _full => Offset.zero & _size;

  /// The foreground app's recents card, where a held launch shrinks to.
  Rect get _card => centerPreviewRectFor(
    _size,
    cardSizeFor(
      constraints: BoxConstraints.tight(_size),
      padding: _padding,
      aspect: viewAspectFor(_size),
    ),
  );

  @override
  void initState() {
    super.initState();
    _drag.addListener(_dragged);
    _shell.deck.recall.addListener(_recalled);
    _shell.deck.presenting.addListener(_deckMoved);
    ref.listenManual(
      referenceShellProvider.select(
        (state) =>
            (request: state.launchRequest, window: state.launchingWindow),
      ),
      (_, next) => _launchChanged(next.request, next.window),
    );
    ref.listenManual(
      referenceShellProvider.select((state) => state.homeTransitionActive),
      (was, active) {
        if (active && was != true) _homeStarted();
      },
    );
    ref.listenManual(
      referenceShellProvider.select((state) => state.windows),
      (_, windows) => _windowsChanged(windows),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _padding = MediaQuery.paddingOf(context);
    _windowRadius = context.shellTheme.windowRadius;
    final size = MediaQuery.sizeOf(context);
    if (size != _size) {
      _size = size;
      for (final flight in _flights) {
        if (flight.handedOver) {
          flight.rect.value = _full;
        } else if (flight.heading == _Heading.open && !flight.grabbed) {
          flight.rect.animateTo(_full);
        }
      }
    }
    if (!_started) {
      _started = true;
      // A launch already under way when the scene mounts.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final state = ref.read(referenceShellProvider);
        _launchChanged(state.launchRequest, state.launchingWindow);
      });
    }
  }

  @override
  void dispose() {
    _drag.removeListener(_dragged);
    _shell.deck.recall.removeListener(_recalled);
    _shell.deck.presenting.removeListener(_deckMoved);
    for (final flight in _flights) {
      if (flight.itemId case final id?) _locator.reveal(id);
      flight.dispose();
    }
    _flights.clear();
    super.dispose();
  }

  // Launches ------------------------------------------------------------------

  void _launchChanged(AppLaunchRequest? request, DenialWindow? window) {
    final previous = _request;
    _request = request;
    if (previous != null && previous.requestId != request?.requestId) {
      final withdrawn = _flightFor(previous.requestId);
      if (withdrawn != null && !withdrawn.handedOver) {
        withdrawn.requestId = null;
        _head(
          withdrawn,
          _Heading.home,
          velocity: withdrawn.grabbed ? _releaseVelocity() : null,
        );
      }
    }
    if (request == null || _size.isEmpty) return;
    final flight =
        _flightFor(request.requestId) ?? _rejoin(request) ?? _launch(request);
    if (window != null && flight.window?.objectId != window.objectId) {
      flight.window = window;
      if (flight.placeholder) flight.ready.animateTo(1);
      _updateSoon(flight);
      _rebuild();
    }
  }

  _Flight? _flightFor(int? requestId) {
    if (requestId == null) return null;
    for (final flight in _flights) {
      if (flight.requestId == requestId) return flight;
    }
    return null;
  }

  /// The flight a new launch continues: the same app still flying home.
  _Flight? _rejoin(AppLaunchRequest request) {
    for (final flight in _flights) {
      if (flight.requestId != null || flight.handedOver) continue;
      final sameWindow =
          request.targetObjectId != null &&
          flight.window?.objectId == request.targetObjectId;
      final sameIcon =
          request.sourceItemId != null && flight.itemId == request.sourceItemId;
      if (!sameWindow && !sameIcon) continue;
      flight
        ..requestId = request.requestId
        ..label = request.appName;
      // Flying out again, the app is the launch's: the deck no longer
      // waits for it.
      if (flight.homeOf case final id?) _shell.deck.flightLanded(id);
      flight.homeOf = null;
      _head(flight, _Heading.open);
      return flight;
    }
    return null;
  }

  _Flight _launch(AppLaunchRequest request) {
    final source = request.sourceRect;
    final icon = source == null ? null : _toLocal(source);
    final anchor = icon ?? _launchCardRect();
    final item = _homeItem(request.sourceItemId);
    final flight = _Flight(
      vsync: this,
      requestId: request.requestId,
      label: request.appName,
      itemId: request.sourceItemId,
      anchor: anchor,
      hasIcon: icon != null,
      placeholder: request.targetObjectId == null,
      icon: item != null
          ? HomeItemIcon(item: item, rasterize: true)
          : LauncherIcon(iconPath: request.iconPath, rasterize: true),
      from: anchor,
    );
    _add(flight);
    _head(flight, _Heading.open);
    return flight;
  }

  HomeGridItem? _homeItem(String? id) {
    if (id == null) return null;
    final grid = ref.read(homeGridControllerProvider).asData?.value;
    return grid?.apps.where((app) => app.id == id).firstOrNull;
  }

  /// Arrival: the window is on screen and the card has reached the screen's
  /// edges. What is left of the spring is under two pixels.
  void _handOver(_Flight flight) {
    final requestId = flight.requestId;
    final window = flight.window;
    if (requestId == null || window == null) return;
    flight.handedOver = true;
    _shell.completeLaunchTransition(requestId, window.objectId);
    if (ref.read(referenceShellProvider).launchRequest?.requestId ==
        requestId) {
      flight.handedOver = false;
      return;
    }
    // Lands it, or leaves the glass fading over the live app.
    flight.rect.value = _full;
    _rebuild();
  }

  // Going home ----------------------------------------------------------------

  void _homeStarted() {
    final hero = _shell.deck.takeFlight();
    final window = hero == null
        ? null
        : ref.read(referenceShellProvider).windowByObjectId(hero.objectId);
    if (hero != null && window != null) {
      _flyHome(window, hero.rect, hero.velocity);
    } else if (hero != null) {
      _shell.deck.flightLanded(hero.objectId);
    }
    // The flag only hands the app over; home owns the screen from here.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _shell.completeHomeTransition();
    });
  }

  /// The deck hands over [window] where it draws it, at [rect], moving at
  /// [velocity] (centre x and y, width and height per second).
  void _flyHome(DenialWindow window, Rect rect, List<double> velocity) {
    for (final flight in [..._flights]) {
      if (flight.window?.objectId == window.objectId) {
        _land(flight, notify: false);
      }
    }
    final target = _locator.iconFor(window);
    final icon = target == null ? null : _toLocal(target.rect);
    final flight = _Flight(
      vsync: this,
      requestId: null,
      label: null,
      itemId: target?.item.id,
      anchor: icon ?? _homeCardRect(rect),
      hasIcon: icon != null,
      placeholder: false,
      icon: target == null
          ? null
          : HomeItemIcon(item: target.item, rasterize: true),
      from: rect,
      window: window,
    )..homeOf = window.objectId;
    _add(flight);
    _head(flight, _Heading.home, velocity: velocity);
  }

  /// A gesture took the deck back from home: the app's flight ends where
  /// it is, and its icon shows.
  void _recalled() {
    final id = _shell.deck.recalled;
    for (final flight in [..._flights]) {
      if (flight.homeOf == id) _land(flight);
    }
  }

  /// The apps start moving: a launch's last fade over its live app would
  /// stay behind on screen as the app moves away, so it ends now.
  void _deckMoved() {
    if (!_shell.deck.presenting.value) return;
    for (final flight in [..._flights]) {
      if (flight.handedOver) _land(flight);
    }
  }

  // Holding a launch -----------------------------------------------------------

  /// The bottom gesture holds the opening card: it shrinks toward its
  /// recents card with its bottom edge under the finger, as a running app
  /// does, set straight from the finger. The release decides, and the card
  /// leaves with the finger's speed; a withdrawn launch heads home on its own.
  void _dragged() {
    final flight = _flightFor(_request?.requestId);
    if (flight == null ||
        flight.handedOver ||
        flight.heading != _Heading.open ||
        _size.isEmpty) {
      return;
    }
    final dy = _drag.value.dy;
    if (dy < 0) {
      flight.grabbed = true;
      final card = _card;
      final t = (-dy / _grabTravel(card)).clamp(0.0, 1.0);
      flight.rect.value = Rect.lerp(_full, card, t)!;
    } else if (flight.grabbed) {
      _head(flight, _Heading.open, velocity: _releaseVelocity());
    }
  }

  double _grabTravel(Rect card) => math.max(1.0, _size.height - card.bottom);

  /// The held card's velocity at the release, from the finger's.
  List<double> _releaseVelocity() {
    final full = _full;
    final card = _card;
    // Progress toward the card per second.
    final rate = (-_shell.gestureReleaseVelocity / _grabTravel(card)).clamp(
      -5.0,
      5.0,
    );
    return [
      (card.center.dx - full.center.dx) * rate,
      (card.center.dy - full.center.dy) * rate,
      (card.width - full.width) * rate,
      (card.height - full.height) * rate,
    ];
  }

  // Flights --------------------------------------------------------------------

  void _add(_Flight flight) {
    if (flight.itemId case final id?) _locator.hide(id);
    flight.rect.addListener(() => _update(flight));
    flight.ready.addListener(() => _update(flight));
    _flights.add(flight);
    _update(flight);
    _rebuild();
  }

  /// Points [flight]'s spring at the screen or at its icon. The spring keeps
  /// its velocity unless [velocity] replaces it.
  void _head(_Flight flight, _Heading heading, {List<double>? velocity}) {
    flight
      ..heading = heading
      ..grabbed = false
      ..rect.motion = heading == _Heading.open
          ? ShellSprings.appOpen
          : ShellSprings.appClose;
    flight.rect.animateTo(
      heading == _Heading.open ? _full : flight.anchor,
      withVelocity: velocity == null ? null : _velocityRect(velocity),
    );
  }

  /// Ends [flight]. A flight home tells the deck its app has arrived,
  /// unless [notify] is false because a new flight home takes over.
  void _land(_Flight flight, {bool notify = true}) {
    if (flight.landed) return;
    flight.landed = true;
    if (flight.homeOf case final id? when notify) {
      _shell.deck.flightLanded(id);
    }
    if (flight.itemId case final id?) _locator.reveal(id);
    flight.rect.stop(canceled: true);
    flight.ready.stop(canceled: true);
    _flights.remove(flight);
    _rebuild();
    WidgetsBinding.instance.addPostFrameCallback((_) => flight.dispose());
  }

  void _windowsChanged(List<DenialWindow> windows) {
    var changed = false;
    for (final flight in _flights) {
      final id = flight.window?.objectId;
      if (id == null) continue;
      final window = windows.where((w) => w.objectId == id).firstOrNull;
      if (identical(window, flight.window)) continue;
      flight.window = window;
      changed = true;
      _updateSoon(flight);
    }
    if (changed) _rebuild();
  }

  /// Poses [flight] for its rectangle, and lands it once it has arrived.
  void _update(_Flight flight) {
    if (flight.landed || _size.isEmpty) return;
    final rect = flight.rect.value;
    final full = _full;
    final anchor = flight.anchor.width;
    // How far the card has grown from its icon, 0 to 1.
    final grown = full.width - anchor <= 1
        ? 1.0
        : ((rect.width - anchor) / (full.width - anchor)).clamp(0.0, 1.0);
    // Corners round from the screen's to a card's, as in recents, then to
    // an icon's.
    final cardWidth = _card.width;
    final carded = full.width - cardWidth <= 1
        ? 0.0
        : ((full.width - rect.width) / (full.width - cardWidth)).clamp(
            0.0,
            1.0,
          );
    final radius = lerpDouble(
      rect.shortestSide * HomeTileMetrics.iconRadiusFraction,
      _windowRadius * carded,
      _ease(grown / 0.3),
    )!;
    final ready = flight.ready.value.clamp(0.0, 1.0);
    // Out of an icon, the card shows under it in the first stretch and the
    // icon then gives way. From a plain card it fades in as it grows.
    final shown = flight.hasIcon ? _ease(grown / 0.14) : _ease(grown / 0.3);
    final iconCovers = flight.hasIcon ? 1 - _ease((grown - 0.06) / 0.26) : 0.0;
    final waiting = flight.placeholder ? 1 - ready : 0.0;
    final windowShown =
        flight.window != null &&
        !flight.handedOver &&
        (!flight.placeholder || ready > 0);
    flight.pose.value = WindowPose(
      rect,
      radius,
      opacity: windowShown ? shown : 0,
    );
    flight.glassOpacity.value = shown * waiting;
    flight.iconOpacity.value = math.max(
      iconCovers,
      waiting * (flight.hasIcon ? 1 : shown),
    );
    // A new app's icon rides the card's centre to its placeholder size; an
    // icon turning into its window fills the card.
    final ride = flight.hasIcon
        ? lerpDouble(anchor, _placeholderIcon, grown)!
        : _placeholderIcon;
    final side = lerpDouble(rect.shortestSide, ride, waiting)!;
    flight.iconRect.value = Rect.fromCenter(
      center: rect.center,
      width: side,
      height: side,
    );

    if (flight.handedOver) {
      if (ready >= 0.995) _land(flight);
    } else if (flight.heading == _Heading.open) {
      if (!flight.grabbed &&
          flight.requestId != null &&
          flight.window != null &&
          _near(flight, full, distance: 1.5, speed: 120)) {
        _handOver(flight);
      }
    } else if (_near(flight, flight.anchor, distance: 0.6, speed: 30)) {
      _land(flight);
    }
  }

  /// Updates [flight] once the shell has finished notifying the change that
  /// led here: arriving may complete the launch, which changes the shell
  /// again. Microtasks run before this frame builds.
  void _updateSoon(_Flight flight) => scheduleMicrotask(() {
    if (mounted) _update(flight);
  });

  bool _near(
    _Flight flight,
    Rect target, {
    required double distance,
    required double speed,
  }) {
    final value = _converter.normalize(flight.rect.value);
    final goal = _converter.normalize(target);
    final velocity = flight.rect.velocities;
    for (var i = 0; i < value.length; i++) {
      if ((value[i] - goal[i]).abs() > distance || velocity[i].abs() > speed) {
        return false;
      }
    }
    return true;
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  Rect _toLocal(Rect global) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return global;
    return Rect.fromPoints(
      box.globalToLocal(global.topLeft),
      box.globalToLocal(global.bottomRight),
    );
  }

  /// A launch from outside home grows from a centred card.
  Rect _launchCardRect() {
    final width = math.min(
      (_size.width - _padding.horizontal - 48) * 0.68,
      390.0,
    );
    final aspect = _size.height <= 0
        ? 1.0
        : (_size.width / _size.height).clamp(0.56, 2.40);
    final height = math.min(width / aspect, _size.height * 0.58);
    return Rect.fromCenter(
      center: _size.center(Offset.zero),
      width: height * aspect,
      height: height,
    );
  }

  /// With no icon on screen an app shrinks toward the middle of home.
  Rect _homeCardRect(Rect from) {
    const width = 120.0;
    return Rect.fromCenter(
      center: Offset(_size.width / 2, _size.height * 0.42),
      width: width,
      height: from.width <= 0 ? width : width * from.height / from.width,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_flights.isEmpty) return const SizedBox.expand();
    final glass = WindowBackdropCache.maybeOf(context);
    final shading = ShellTheme.of(context).windowGlassShading;
    final launchSurface = context.shellColors.launchSurface;
    final l10n = context.l10n;
    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          fit: StackFit.expand,
          children: [
            for (final flight in _flights)
              Semantics(
                key: ObjectKey(flight),
                container: true,
                liveRegion: flight.label != null,
                label: switch (flight.label) {
                  final name? => l10n.launchOpeningApplication(name),
                  null => null,
                },
                child: _FlightView(
                  flight: flight,
                  glass: glass == null
                      ? FadeTransition(
                          opacity: flight.glassFade,
                          child: ColoredBox(color: launchSurface),
                        )
                      : WindowBackdropSlice(
                          cache: glass,
                          glass: shading,
                          opacity: flight.glassOpacity,
                          fadeOverlay: true,
                        ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One flight: the window, then the glass a new app opens on, then the icon.
/// The window draws under the glass so its first frame can fade in where
/// the glass was without fading the window itself, which would allocate a
/// layer for a rectangle that changes every frame.
class _FlightView extends StatelessWidget {
  const _FlightView({required this.flight, required this.glass});

  final _Flight flight;

  /// The new app's glass, drawn in place under the card's clip.
  final Widget glass;

  @override
  Widget build(BuildContext context) {
    final window = flight.window;
    final icon = flight.icon;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (window != null && !flight.handedOver)
          WindowBackdropMotion(
            motion: flight.pose,
            child: PosedWindow(
              pose: flight.pose,
              child: WindowSurface(
                window: window,
                contentPadding: EdgeInsets.only(
                  top: ReferenceShellMetrics.appStatusInset(
                    MediaQuery.sizeOf(context),
                  ),
                ),
              ),
            ),
          ),
        if (flight.placeholder)
          ClipRRect(clipper: _PoseClipper(flight.pose), child: glass),
        if (icon != null)
          RectFollower(
            rect: flight.iconRect,
            // Drawn at the home icon's own size, the icon shares home's
            // decoded image and shows on the flight's first frame.
            size: Size.square(
              flight.hasIcon
                  ? HomeTileMetrics.icon
                  : _AppFlightLayerState._placeholderIcon,
            ),
            child: FadeTransition(opacity: flight.iconFade, child: icon),
          ),
      ],
    );
  }
}

class _Flight {
  _Flight({
    required TickerProvider vsync,
    required this.requestId,
    required this.label,
    required this.itemId,
    required this.anchor,
    required this.hasIcon,
    required this.placeholder,
    required this.icon,
    required Rect from,
    this.window,
  }) : rect = motor.MotionController<Rect>(
         motion: ShellSprings.appOpen,
         vsync: vsync,
         converter: const RectCenterSizeConverter(),
         initialValue: from,
       ),
       ready = motor.SingleMotionController(
         motion: ShellSprings.contentFade,
         vsync: vsync,
         initialValue: placeholder ? 0 : 1,
       ),
       pose = ValueNotifier(WindowPose(from, 0, opacity: 0));

  /// The launch flying this app to the screen; null while it flies home.
  int? requestId;

  /// The app the deck handed over to fly home, until it lands.
  int? homeOf;

  /// The app's name while it opens, for assistive technology.
  String? label;

  /// The home item hidden while this flight draws it.
  final String? itemId;

  /// The icon, or card, this flight grows from and returns to.
  final Rect anchor;
  final bool hasIcon;

  /// A new app opens on glass until its first frame arrives.
  final bool placeholder;
  final Widget? icon;
  DenialWindow? window;

  _Heading heading = _Heading.open;
  bool grabbed = false;

  /// The launch is complete and the shell shows the app; only the glass,
  /// if any, is still fading.
  bool handedOver = false;
  bool landed = false;

  final motor.MotionController<Rect> rect;

  /// The new app's first frame replacing its glass, 0 to 1.
  final motor.SingleMotionController ready;

  final ValueNotifier<WindowPose> pose;
  final iconRect = ValueNotifier(Rect.zero);
  final iconOpacity = ValueNotifier(0.0);
  final glassOpacity = ValueNotifier(0.0);
  late final Animation<double> iconFade = Animation.fromValueListenable(
    iconOpacity,
  );
  late final Animation<double> glassFade = Animation.fromValueListenable(
    glassOpacity,
  );

  void dispose() {
    rect.dispose();
    ready.dispose();
    pose.dispose();
    iconRect.dispose();
    iconOpacity.dispose();
    glassOpacity.dispose();
  }
}

class _PoseClipper extends CustomClipper<RRect> {
  _PoseClipper(this.pose) : super(reclip: pose);

  final ValueListenable<WindowPose> pose;

  @override
  RRect getClip(Size size) => RRect.fromRectAndRadius(
    pose.value.rect,
    Radius.circular(pose.value.radius),
  );

  @override
  bool shouldReclip(_PoseClipper oldClipper) =>
      !identical(oldClipper.pose, pose);
}

/// A centre-and-size velocity as the [Rect] the converter normalizes to it.
Rect _velocityRect(List<double> v) => Rect.fromLTRB(
  v[0] - v[2] / 2,
  v[1] - v[3] / 2,
  v[0] + v[2] / 2,
  v[1] + v[3] / 2,
);

double _ease(double t) {
  final x = t.clamp(0.0, 1.0);
  return x * x * (3 - 2 * x);
}
