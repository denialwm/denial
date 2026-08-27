import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerDeviceKind, PointerExitEvent;
import 'package:flutter/services.dart'
    show MouseCursor, MouseCursorSession, SystemChannels;
import 'package:flutter/widgets.dart';

import '../models/denial_drag_icon.dart';
import '../models/denial_cursor_state.dart';
import '../models/display_layout.dart';
import '../theme/cursor_themes.dart';
import 'retained_translation.dart';
import 'window_surface_tree.dart';

/// Cursor intents for Flutter-owned shell regions.
///
/// Sessions report a semantic shape to the compositor. [ShellCursorHost]
/// changes artwork only after Rust echoes the authoritative cursor state.
abstract final class ShellMouseCursors {
  static const MouseCursor normal = _ShellMouseCursor(ShellCursorKind.normal);
  static const MouseCursor help = _ShellMouseCursor(ShellCursorKind.help);
  static const MouseCursor working = _ShellMouseCursor(ShellCursorKind.working);
  static const MouseCursor text = _ShellMouseCursor(ShellCursorKind.text);
  static const MouseCursor link = _ShellMouseCursor(ShellCursorKind.link);
  static const MouseCursor busy = _ShellMouseCursor(ShellCursorKind.busy);
  static const MouseCursor precision = _ShellMouseCursor(
    ShellCursorKind.precision,
  );
  static const MouseCursor handwriting = _ShellMouseCursor(
    ShellCursorKind.handwriting,
  );
  static const MouseCursor unavailable = _ShellMouseCursor(
    ShellCursorKind.unavailable,
  );
  static const MouseCursor verticalResize = _ShellMouseCursor(
    ShellCursorKind.verticalResize,
  );
  static const MouseCursor horizontalResize = _ShellMouseCursor(
    ShellCursorKind.horizontalResize,
  );
  static const MouseCursor diagonalNwSeResize = _ShellMouseCursor(
    ShellCursorKind.diagonalNwSeResize,
  );
  static const MouseCursor diagonalNeSwResize = _ShellMouseCursor(
    ShellCursorKind.diagonalNeSwResize,
  );
  static const MouseCursor move = _ShellMouseCursor(ShellCursorKind.move);
  static const MouseCursor alternate = _ShellMouseCursor(
    ShellCursorKind.alternate,
  );
  static const MouseCursor person = _ShellMouseCursor(ShellCursorKind.person);
  static const MouseCursor pin = _ShellMouseCursor(ShellCursorKind.pin);
}

String _normalizeShellCursorShape(String shape) {
  return shape.trim().toLowerCase().replaceAll('_', '-');
}

enum ShellCursorArtworkSource { none, themed, clientSurface }

@visibleForTesting
ShellCursorArtworkSource shellCursorArtworkSource({
  required bool hasPosition,
  required bool themedCursorVisible,
  required bool cursorHidden,
  required bool clientSurfaceRequested,
  required bool dragActive,
}) {
  if (!hasPosition || cursorHidden) {
    return ShellCursorArtworkSource.none;
  }
  if (clientSurfaceRequested && !dragActive) {
    return ShellCursorArtworkSource.clientSurface;
  }
  return themedCursorVisible
      ? ShellCursorArtworkSource.themed
      : ShellCursorArtworkSource.none;
}

/// Resolves native Wayland/XCursor names and Flutter system cursor names to
/// the closest artwork supplied by the active shell cursor theme.
ShellCursorKind shellCursorKindForPlatformShape(String shape) {
  return switch (_normalizeShellCursorShape(shape)) {
    'help' || 'question-arrow' || 'dnd-ask' => ShellCursorKind.help,
    'pointer' ||
    'hand' ||
    'hand1' ||
    'hand2' ||
    'click' => ShellCursorKind.link,
    'progress' || 'working' || 'left-ptr-watch' => ShellCursorKind.working,
    'wait' || 'watch' || 'busy' => ShellCursorKind.busy,
    'cell' ||
    'crosshair' ||
    'precise' ||
    'precision' ||
    'zoom-in' ||
    'zoom-out' ||
    'zoomin' ||
    'zoomout' => ShellCursorKind.precision,
    'text' ||
    'vertical-text' ||
    'verticaltext' ||
    'xterm' => ShellCursorKind.text,
    'handwriting' || 'pencil' || 'nwpen' => ShellCursorKind.handwriting,
    'invalid' ||
    'no-drop' ||
    'nodrop' ||
    'not-allowed' ||
    'notallowed' ||
    'forbidden' ||
    'unavailable' => ShellCursorKind.unavailable,
    'n-resize' ||
    's-resize' ||
    'ns-resize' ||
    'row-resize' ||
    'top-side' ||
    'bottom-side' ||
    'resizeupdown' ||
    'resizeup' ||
    'resizedown' ||
    'resizerow' => ShellCursorKind.verticalResize,
    'e-resize' ||
    'w-resize' ||
    'ew-resize' ||
    'col-resize' ||
    'left-side' ||
    'right-side' ||
    'resizeleftright' ||
    'resizeleft' ||
    'resizeright' ||
    'resizecolumn' => ShellCursorKind.horizontalResize,
    'nw-resize' ||
    'se-resize' ||
    'nwse-resize' ||
    'top-left-corner' ||
    'bottom-right-corner' ||
    'resizeupleftdownright' ||
    'resizeupleft' ||
    'resizedownright' => ShellCursorKind.diagonalNwSeResize,
    'ne-resize' ||
    'sw-resize' ||
    'nesw-resize' ||
    'top-right-corner' ||
    'bottom-left-corner' ||
    'resizeuprightdownleft' ||
    'resizeupright' ||
    'resizedownleft' => ShellCursorKind.diagonalNeSwResize,
    'move' ||
    'grab' ||
    'grabbing' ||
    'all-scroll' ||
    'allscroll' ||
    'all-resize' ||
    'allresize' => ShellCursorKind.move,
    'alias' ||
    'copy' ||
    'alternate' ||
    'up-arrow' ||
    'uparrow' => ShellCursorKind.alternate,
    'person' => ShellCursorKind.person,
    'pin' || 'location' || 'loc' => ShellCursorKind.pin,
    _ => ShellCursorKind.normal,
  };
}

class ShellCursorHost extends StatefulWidget {
  const ShellCursorHost({
    super.key,
    required this.child,
    this.theme = ShellCursorThemes.bibataModernIce,
    this.platformCursorShapes,
    this.platformCursorStates,
    this.platformCursorPositions,
    this.platformDragIcons,
    this.hideCursor = false,
    this.displayLayout,
    this.cursorSize = shellCursorDefaultSize,
    this.onCursorStatePresented,
  });

  final Widget child;
  final ShellCursorThemeData theme;
  final Stream<String>? platformCursorShapes;
  final Stream<DenialCursorState>? platformCursorStates;
  final Stream<Offset>? platformCursorPositions;
  final Stream<DenialDragIcon?>? platformDragIcons;
  final bool hideCursor;
  final DisplayLayout? displayLayout;

  /// Target size of the longest cursor-artwork edge in physical pixels.
  final double cursorSize;
  final ValueChanged<int>? onCursorStatePresented;

  @override
  State<ShellCursorHost> createState() => _ShellCursorHostState();
}

class _ShellCursorHostState extends State<ShellCursorHost> {
  final _cursorController = _ShellCursorController.instance;
  final _cursorTranslation = ValueNotifier<Offset>(Offset.zero);
  Offset? _position;
  ShellCursorKind _kind = ShellCursorKind.normal;
  bool _visible = true;
  StreamSubscription<String>? _platformCursorSubscription;
  StreamSubscription<DenialCursorState>? _platformCursorStateSubscription;
  StreamSubscription<Offset>? _platformPositionSubscription;
  StreamSubscription<DenialDragIcon?>? _platformDragIconSubscription;
  DenialDragIcon? _dragIcon;
  DenialCursorState? _platformCursorState;
  int _pendingCursorAckEpoch = 0;
  bool _cursorAckScheduled = false;
  ShellCursorThemeData? _precacheTheme;

  @override
  void initState() {
    super.initState();
    _kind = _cursorController.kind;
    _visible = _cursorController.visible;
    _cursorController.addListener(_handleCursorKindChanged);
    _subscribeToPlatformCursorShapes();
    _subscribeToPlatformCursorStates();
    _subscribeToPlatformCursorPositions();
    _subscribeToPlatformDragIcons();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _precacheCursorAssets();
  }

  @override
  void didUpdateWidget(covariant ShellCursorHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.platformCursorShapes != widget.platformCursorShapes) {
      unawaited(_platformCursorSubscription?.cancel());
      _subscribeToPlatformCursorShapes();
    }
    if (oldWidget.platformCursorStates != widget.platformCursorStates) {
      unawaited(_platformCursorStateSubscription?.cancel());
      _subscribeToPlatformCursorStates();
    }
    if (oldWidget.platformCursorPositions != widget.platformCursorPositions) {
      unawaited(_platformPositionSubscription?.cancel());
      _subscribeToPlatformCursorPositions();
    }
    if (oldWidget.platformDragIcons != widget.platformDragIcons) {
      unawaited(_platformDragIconSubscription?.cancel());
      _subscribeToPlatformDragIcons();
    }
    if (oldWidget.theme == widget.theme) {
      return;
    }
    _precacheTheme = null;
    _precacheCursorAssets();
  }

  @override
  void dispose() {
    unawaited(_platformCursorSubscription?.cancel());
    unawaited(_platformCursorStateSubscription?.cancel());
    unawaited(_platformPositionSubscription?.cancel());
    unawaited(_platformDragIconSubscription?.cancel());
    _cursorController.removeListener(_handleCursorKindChanged);
    _cursorTranslation.dispose();
    super.dispose();
  }

  void _precacheCursorAssets() {
    if (identical(_precacheTheme, widget.theme) ||
        !widget.theme.usesImageFrames) {
      return;
    }
    _precacheTheme = widget.theme;
    for (final provider in widget.theme.imageProviders) {
      unawaited(precacheImage(provider, context));
    }
  }

  void _handleCursorKindChanged() {
    final kind = _cursorController.kind;
    final visible = _cursorController.visible;
    if (!mounted || (kind == _kind && visible == _visible)) {
      return;
    }
    setState(() {
      _kind = kind;
      _visible = visible;
    });
  }

  void _subscribeToPlatformCursorShapes() {
    _platformCursorSubscription = widget.platformCursorShapes?.listen(
      _cursorController.activatePlatformShape,
    );
  }

  void _subscribeToPlatformCursorStates() {
    _platformCursorStateSubscription = widget.platformCursorStates?.listen(
      _updatePlatformCursorState,
    );
  }

  void _updatePlatformCursorState(DenialCursorState state) {
    if (!mounted ||
        (_platformCursorState?.epoch ?? 0) >= state.epoch ||
        state.epoch <= 0) {
      return;
    }
    setState(() => _platformCursorState = state);
    switch (state.kind) {
      case DenialCursorStateKind.hidden:
        _cursorController.activatePlatformShape('none');
      case DenialCursorStateKind.named:
        _cursorController.activatePlatformShape(state.shape);
      case DenialCursorStateKind.surface:
        break;
    }
    _pendingCursorAckEpoch = state.epoch;
    if (_cursorAckScheduled) {
      return;
    }
    _cursorAckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _cursorAckScheduled = false;
      if (!mounted) {
        return;
      }
      final epoch = _pendingCursorAckEpoch;
      _pendingCursorAckEpoch = 0;
      if (epoch > 0) {
        widget.onCursorStatePresented?.call(epoch);
      }
    });
  }

  void _subscribeToPlatformCursorPositions() {
    _platformPositionSubscription = widget.platformCursorPositions?.listen(
      _updatePlatformPosition,
    );
  }

  void _subscribeToPlatformDragIcons() {
    _platformDragIconSubscription = widget.platformDragIcons?.listen(
      _updatePlatformDragIcon,
    );
  }

  void _updatePlatformDragIcon(DenialDragIcon? icon) {
    if (!mounted || icon == _dragIcon) {
      return;
    }
    setState(() => _dragIcon = icon);
  }

  void _updatePlatformPosition(Offset position) {
    if (!mounted || !position.dx.isFinite || !position.dy.isFinite) {
      return;
    }
    _setPosition(position);
  }

  void _updatePosition(PointerEvent event) {
    if (event.kind != PointerDeviceKind.mouse ||
        event.localPosition == _position) {
      return;
    }
    _setPosition(event.localPosition);
  }

  void _setPosition(Offset position) {
    final previous = _position;
    if (position == previous) {
      return;
    }
    final wasHidden = _position == null;
    final outputScaleChanged =
        previous != null &&
        _cursorOutputScale(widget.displayLayout, previous, 1.0) !=
            _cursorOutputScale(widget.displayLayout, position, 1.0);
    _position = position;
    _cursorTranslation.value = position;
    if (wasHidden || outputScaleChanged) {
      setState(() {});
    }
  }

  void _handleExit(PointerExitEvent event) {
    // A Remove is also the compositor's endpoint boundary when a native
    // client takes the pointer. Keep the last rendered position in that case;
    // Rust's non-hit-testing position stream takes over on client motion.
    if (widget.platformCursorPositions != null ||
        event.kind != PointerDeviceKind.mouse ||
        _position == null) {
      return;
    }
    setState(() => _position = null);
  }

  @override
  Widget build(BuildContext context) {
    final position = _position;
    final dragIcon = _dragIcon;
    final cursorState = _platformCursorState;
    final clientSurface = cursorState?.kind == DenialCursorStateKind.surface
        ? cursorState
        : null;
    final cursorHidden =
        cursorState?.kind == DenialCursorStateKind.hidden || widget.hideCursor;
    final artworkSource = shellCursorArtworkSource(
      hasPosition: position != null,
      themedCursorVisible: _visible,
      cursorHidden: cursorHidden,
      clientSurfaceRequested: clientSurface != null,
      dragActive: dragIcon != null,
    );
    final fallbackScale = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    final outputScale = _cursorOutputScale(
      widget.displayLayout,
      position ?? Offset.zero,
      fallbackScale,
    );
    final configuredSize = widget.cursorSize.isFinite && widget.cursorSize > 0
        ? widget.cursorSize
        : shellCursorDefaultSize;
    final artworkExtent = configuredSize / outputScale;
    return MouseRegion(
      opaque: false,
      cursor: ShellMouseCursors.normal,
      onHover: _updatePosition,
      onExit: _handleExit,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _updatePosition,
        onPointerMove: _updatePosition,
        onPointerUp: _updatePosition,
        child: Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            if (position != null && dragIcon != null)
              Positioned(
                left: dragIcon.offset.dx,
                top: dragIcon.offset.dy,
                width: dragIcon.size.width,
                height: dragIcon.size.height,
                child: RetainedTranslation(
                  translation: _cursorTranslation,
                  child: IgnorePointer(
                    child: ExcludeSemantics(
                      child: RepaintBoundary(
                        child: SurfaceLayerTexture(layer: dragIcon.layer),
                      ),
                    ),
                  ),
                ),
              ),
            if (artworkSource == ShellCursorArtworkSource.clientSurface)
              Positioned(
                left: 0,
                top: 0,
                child: RetainedTranslation(
                  translation: _cursorTranslation,
                  child: IgnorePointer(
                    child: ExcludeSemantics(
                      child: RepaintBoundary(
                        child: _ClientCursorSurfaceTree(state: clientSurface!),
                      ),
                    ),
                  ),
                ),
              ),
            if (artworkSource == ShellCursorArtworkSource.themed)
              Positioned(
                left: 0,
                top: 0,
                child: RetainedTranslation(
                  translation: _cursorTranslation,
                  child: IgnorePointer(
                    child: ExcludeSemantics(
                      child: RepaintBoundary(
                        child: ShellCursorArtwork(
                          theme: widget.theme,
                          kind: dragIcon == null
                              ? _kind
                              : ShellCursorKind.normal,
                          longestEdge: artworkExtent,
                          anchorAtHotspot: true,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ClientCursorSurfaceTree extends StatelessWidget {
  const _ClientCursorSurfaceTree({required this.state});

  final DenialCursorState state;

  @override
  Widget build(BuildContext context) {
    final layers = state.surfaceLayers
        .where((layer) => layer.textureId > 0)
        .toList(growable: false);
    if (layers.isEmpty) {
      return const SizedBox.shrink();
    }
    var left = layers.first.surfaceX;
    var top = layers.first.surfaceY;
    var right = layers.first.surfaceX + layers.first.surfaceWidth;
    var bottom = layers.first.surfaceY + layers.first.surfaceHeight;
    for (final layer in layers.skip(1)) {
      left = math.min(left, layer.surfaceX);
      top = math.min(top, layer.surfaceY);
      right = math.max(right, layer.surfaceX + layer.surfaceWidth);
      bottom = math.max(bottom, layer.surfaceY + layer.surfaceHeight);
    }
    return Transform.translate(
      offset: Offset(left, top) - state.hotspot,
      child: SizedBox(
        width: right - left,
        height: bottom - top,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (final layer in layers)
              Positioned(
                left: layer.surfaceX - left,
                top: layer.surfaceY - top,
                width: layer.surfaceWidth,
                height: layer.surfaceHeight,
                child: SurfaceLayerTexture(layer: layer),
              ),
          ],
        ),
      ),
    );
  }
}

/// Shared image player used by both the live software cursor and Settings
/// previews. Imported ANI steps may carry different durations and hotspots;
/// every frame therefore schedules its own successor instead of using a fixed
/// periodic tick.
class ShellCursorArtwork extends StatefulWidget {
  const ShellCursorArtwork({
    required this.theme,
    required this.kind,
    required this.longestEdge,
    this.anchorAtHotspot = false,
    this.running = true,
    super.key,
  });

  final ShellCursorThemeData theme;
  final ShellCursorKind kind;
  final double longestEdge;
  final bool anchorAtHotspot;
  final bool running;

  @override
  State<ShellCursorArtwork> createState() => _ShellCursorArtworkState();
}

class _ShellCursorArtworkState extends State<ShellCursorArtwork> {
  Timer? _timer;
  int _frame = 0;

  ShellCursorRoleData get _role => widget.theme.roleFor(widget.kind);

  @override
  void initState() {
    super.initState();
    _scheduleNextFrame();
  }

  @override
  void didUpdateWidget(covariant ShellCursorArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.theme != widget.theme || oldWidget.kind != widget.kind) {
      _frame = 0;
    }
    if (oldWidget.theme != widget.theme ||
        oldWidget.kind != widget.kind ||
        oldWidget.running != widget.running) {
      _scheduleNextFrame();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _scheduleNextFrame() {
    _timer?.cancel();
    _timer = null;
    final role = _role;
    if (!widget.running || !role.isAnimated) {
      return;
    }
    final duration = role.frameDurationAt(_frame);
    if (duration.inMicroseconds <= 0) {
      return;
    }
    _timer = Timer(duration, () {
      if (!mounted || !widget.running) {
        return;
      }
      setState(() => _frame = (_frame + 1) % role.effectiveFrameCount);
      _scheduleNextFrame();
    });
  }

  @override
  Widget build(BuildContext context) {
    final role = _role;
    final nativeSize = role.size;
    final nativeExtent = nativeSize.width > nativeSize.height
        ? nativeSize.width
        : nativeSize.height;
    final requestedExtent =
        widget.longestEdge.isFinite && widget.longestEdge > 0
        ? widget.longestEdge
        : shellCursorDefaultSize;
    final scale = requestedExtent / nativeExtent;
    final artworkSize = nativeSize * scale;
    final hotspot = role.hotspotAt(_frame);
    final artwork = Image(
      image: widget.theme.imageProvider(widget.kind, _frame)!,
      width: artworkSize.width,
      height: artworkSize.height,
      filterQuality: FilterQuality.none,
      gaplessPlayback: true,
      excludeFromSemantics: true,
    );
    if (!widget.anchorAtHotspot) {
      return artwork;
    }
    return Transform.translate(offset: -hotspot * scale, child: artwork);
  }
}

double _cursorOutputScale(
  DisplayLayout? layout,
  Offset position,
  double fallback,
) {
  final outputs = layout?.outputs ?? const <DisplayOutput>[];
  for (final output in outputs) {
    if (output.logicalRect.contains(position)) {
      return _validDisplayScale(output.scale, fallback);
    }
  }

  DisplayOutput? nearest;
  var nearestDistanceSquared = double.infinity;
  for (final output in outputs) {
    final distanceSquared = _distanceSquaredToRect(
      position,
      output.logicalRect,
    );
    if (distanceSquared < nearestDistanceSquared) {
      nearest = output;
      nearestDistanceSquared = distanceSquared;
    }
  }
  return _validDisplayScale(nearest?.scale, fallback);
}

double _validDisplayScale(double? scale, double fallback) {
  if (scale != null && scale.isFinite && scale > 0) {
    return scale;
  }
  return fallback.isFinite && fallback > 0 ? fallback : 1.0;
}

double _distanceSquaredToRect(Offset point, Rect rect) {
  final dx = point.dx < rect.left
      ? rect.left - point.dx
      : point.dx > rect.right
      ? point.dx - rect.right
      : 0.0;
  final dy = point.dy < rect.top
      ? rect.top - point.dy
      : point.dy > rect.bottom
      ? point.dy - rect.bottom
      : 0.0;
  return dx * dx + dy * dy;
}

class _ShellCursorController extends ChangeNotifier {
  _ShellCursorController._();

  static final _ShellCursorController instance = _ShellCursorController._();

  ShellCursorKind _kind = ShellCursorKind.normal;

  ShellCursorKind get kind => _kind;
  bool get visible => _visible;

  bool _visible = true;

  void activatePlatformShape(String shape) {
    final normalized = _normalizeShellCursorShape(shape);
    final visible = normalized != 'none' && normalized != 'hidden';
    final kind = shellCursorKindForPlatformShape(normalized);
    if (_kind == kind && _visible == visible) {
      return;
    }
    _kind = kind;
    _visible = visible;
    notifyListeners();
  }
}

class _ShellMouseCursor extends MouseCursor {
  const _ShellMouseCursor(this.kind);

  final ShellCursorKind kind;

  @override
  MouseCursorSession createSession(int device) =>
      _ShellMouseCursorSession(this, device);

  @override
  String get debugDescription => 'Flutter shell ${kind.name} cursor';
}

class _ShellMouseCursorSession extends MouseCursorSession {
  _ShellMouseCursorSession(_ShellMouseCursor super.cursor, super.device);

  @override
  _ShellMouseCursor get cursor => super.cursor as _ShellMouseCursor;

  @override
  Future<void> activate() {
    return SystemChannels.mouseCursor.invokeMethod<void>(
      'activateSystemCursor',
      <String, dynamic>{
        'device': device,
        'kind': _flutterCursorKind(cursor.kind),
      },
    );
  }

  @override
  void dispose() {}
}

String _flutterCursorKind(ShellCursorKind kind) {
  return switch (kind) {
    ShellCursorKind.normal => 'basic',
    ShellCursorKind.help => 'help',
    ShellCursorKind.working => 'progress',
    ShellCursorKind.text => 'text',
    ShellCursorKind.link => 'click',
    ShellCursorKind.busy => 'wait',
    ShellCursorKind.precision => 'precise',
    ShellCursorKind.handwriting => 'handwriting',
    ShellCursorKind.unavailable => 'forbidden',
    ShellCursorKind.verticalResize => 'resizeUpDown',
    ShellCursorKind.horizontalResize => 'resizeLeftRight',
    ShellCursorKind.diagonalNwSeResize => 'resizeUpLeftDownRight',
    ShellCursorKind.diagonalNeSwResize => 'resizeUpRightDownLeft',
    ShellCursorKind.move => 'move',
    ShellCursorKind.alternate => 'alias',
    ShellCursorKind.person => 'person',
    ShellCursorKind.pin => 'pin',
  };
}
