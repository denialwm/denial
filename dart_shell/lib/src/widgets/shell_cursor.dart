import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind, PointerExitEvent;
import 'package:flutter/services.dart'
    show MouseCursor, MouseCursorSession, SystemChannels;
import 'package:flutter/widgets.dart';

import '../models/denial_drag_icon.dart';
import '../models/display_layout.dart';
import '../theme/cursor_themes.dart';
import '../theme/tokens.dart';
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
    this.theme = ShellCursorThemes.standard,
    this.platformCursorShapes,
    this.platformCursorPositions,
    this.platformDragIcons,
    this.hideCursor = false,
    this.displayLayout,
    this.cursorSize = shellCursorDefaultSize,
  });

  final Widget child;
  final ShellCursorThemeData theme;
  final Stream<String>? platformCursorShapes;
  final Stream<Offset>? platformCursorPositions;
  final Stream<DenialDragIcon?>? platformDragIcons;
  final bool hideCursor;
  final DisplayLayout? displayLayout;

  /// Target size of the longest cursor-artwork edge in physical pixels.
  final double cursorSize;

  @override
  State<ShellCursorHost> createState() => _ShellCursorHostState();
}

class _ShellCursorHostState extends State<ShellCursorHost> {
  final _cursorController = _ShellCursorController.instance;
  final _cursorTranslation = ValueNotifier<Offset>(Offset.zero);
  Offset? _position;
  ShellCursorKind _kind = ShellCursorKind.normal;
  bool _visible = true;
  Timer? _frameTimer;
  StreamSubscription<String>? _platformCursorSubscription;
  StreamSubscription<Offset>? _platformPositionSubscription;
  StreamSubscription<DenialDragIcon?>? _platformDragIconSubscription;
  DenialDragIcon? _dragIcon;
  int _frame = 0;
  bool _assetsPrecached = false;

  @override
  void initState() {
    super.initState();
    _kind = _cursorController.kind;
    _visible = _cursorController.visible;
    _cursorController.addListener(_handleCursorKindChanged);
    _subscribeToPlatformCursorShapes();
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
    _frame = 0;
    _assetsPrecached = false;
    _frameTimer?.cancel();
    _frameTimer = null;
    _syncFrameTimer();
    _precacheCursorAssets();
  }

  @override
  void dispose() {
    _frameTimer?.cancel();
    unawaited(_platformCursorSubscription?.cancel());
    unawaited(_platformPositionSubscription?.cancel());
    unawaited(_platformDragIconSubscription?.cancel());
    _cursorController.removeListener(_handleCursorKindChanged);
    _cursorTranslation.dispose();
    super.dispose();
  }

  void _precacheCursorAssets() {
    if (_assetsPrecached || !widget.theme.usesAssetFrames) {
      return;
    }
    _assetsPrecached = true;
    for (final path in widget.theme.assetPaths) {
      unawaited(precacheImage(AssetImage(path), context));
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
      _frame = 0;
    });
    _frameTimer?.cancel();
    _frameTimer = null;
    _syncFrameTimer();
  }

  void _subscribeToPlatformCursorShapes() {
    _platformCursorSubscription = widget.platformCursorShapes?.listen(
      _cursorController.activatePlatformShape,
    );
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
      setState(() {
        if (wasHidden) {
          _frame = 0;
        }
      });
    }
    if (wasHidden) {
      _syncFrameTimer();
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
    _syncFrameTimer();
  }

  void _syncFrameTimer() {
    final role = widget.theme.usesAssetFrames
        ? widget.theme.roleFor(_kind)
        : null;
    if (_position == null || !_visible || role == null || !role.isAnimated) {
      _frameTimer?.cancel();
      _frameTimer = null;
      return;
    }
    _frameTimer ??= Timer.periodic(role.frameDuration, (_) {
      if (!mounted || _position == null) {
        _syncFrameTimer();
        return;
      }
      setState(() => _frame = (_frame + 1) % role.frameCount);
    });
  }

  @override
  Widget build(BuildContext context) {
    final position = _position;
    final dragIcon = _dragIcon;
    final assetRole = widget.theme.usesAssetFrames
        ? widget.theme.roleFor(_kind)
        : null;
    final nativeSize = assetRole?.size ?? _ShellCursorPainter.size;
    final nativeExtent = nativeSize.width > nativeSize.height
        ? nativeSize.width
        : nativeSize.height;
    final fallbackScale = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    final outputScale = _cursorOutputScale(
      widget.displayLayout,
      position ?? Offset.zero,
      fallbackScale,
    );
    final configuredSize = widget.cursorSize.isFinite && widget.cursorSize > 0
        ? widget.cursorSize
        : shellCursorDefaultSize;
    final artworkScale = configuredSize / nativeExtent / outputScale;
    final artworkSize = nativeSize * artworkScale;
    final hotspot = (assetRole?.hotspot ?? Offset.zero) * artworkScale;
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
            if (position != null && _visible && !widget.hideCursor)
              Positioned(
                left: -hotspot.dx,
                top: -hotspot.dy,
                child: RetainedTranslation(
                  translation: _cursorTranslation,
                  child: IgnorePointer(
                    child: ExcludeSemantics(
                      child: RepaintBoundary(
                        child: assetRole != null
                            ? Image.asset(
                                widget.theme.assetPath(_kind, _frame),
                                width: artworkSize.width,
                                height: artworkSize.height,
                                filterQuality: FilterQuality.none,
                                gaplessPlayback: true,
                                excludeFromSemantics: true,
                              )
                            : CustomPaint(
                                size: artworkSize,
                                painter: const _ShellCursorPainter(),
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

class _ShellCursorPainter extends CustomPainter {
  const _ShellCursorPainter();

  static const Size size = Size(24, 32);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }
    canvas
      ..save()
      ..scale(size.width / _ShellCursorPainter.size.width);
    final path = Path()
      ..moveTo(1.5, 1.0)
      ..lineTo(1.5, 24.5)
      ..lineTo(7.9, 18.3)
      ..lineTo(13.2, 30.2)
      ..lineTo(18.0, 28.0)
      ..lineTo(12.8, 16.5)
      ..lineTo(21.7, 16.5)
      ..close();

    canvas.drawShadow(path, ShellColors.shadow, 3.0, false);
    canvas.drawPath(
      path,
      Paint()
        ..color = ShellColors.textPrimary
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = ShellColors.background
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ShellCursorPainter oldDelegate) => false;
}
