import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind, PointerExitEvent;
import 'package:flutter/services.dart'
    show MouseCursor, MouseCursorSession, SystemChannels;
import 'package:flutter/widgets.dart';

import '../models/denial_drag_icon.dart';
import '../theme/cursor_themes.dart';
import '../theme/tokens.dart';
import 'window_surface_tree.dart';

/// Flutter-owned cursors that also keep any platform cursor hidden.
///
/// Use these in descendant mouse regions so [ShellCursorHost] can select the
/// matching artwork without handing rendering back to the embedder.
abstract final class ShellMouseCursors {
  static const MouseCursor normal = _ShellMouseCursor(ShellCursorKind.normal);
  static const MouseCursor help = _ShellMouseCursor(ShellCursorKind.help);
  static const MouseCursor working = _ShellMouseCursor(
    ShellCursorKind.working,
  );
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
    'click' =>
      ShellCursorKind.link,
    'progress' || 'working' || 'left-ptr-watch' => ShellCursorKind.working,
    'wait' || 'watch' || 'busy' => ShellCursorKind.busy,
    'cell' ||
    'crosshair' ||
    'precise' ||
    'precision' ||
    'zoom-in' ||
    'zoom-out' ||
    'zoomin' ||
    'zoomout' =>
      ShellCursorKind.precision,
    'text' ||
    'vertical-text' ||
    'verticaltext' ||
    'xterm' =>
      ShellCursorKind.text,
    'handwriting' || 'pencil' || 'nwpen' => ShellCursorKind.handwriting,
    'invalid' ||
    'no-drop' ||
    'nodrop' ||
    'not-allowed' ||
    'notallowed' ||
    'forbidden' ||
    'unavailable' =>
      ShellCursorKind.unavailable,
    'n-resize' ||
    's-resize' ||
    'ns-resize' ||
    'row-resize' ||
    'top-side' ||
    'bottom-side' ||
    'resizeupdown' ||
    'resizeup' ||
    'resizedown' ||
    'resizerow' =>
      ShellCursorKind.verticalResize,
    'e-resize' ||
    'w-resize' ||
    'ew-resize' ||
    'col-resize' ||
    'left-side' ||
    'right-side' ||
    'resizeleftright' ||
    'resizeleft' ||
    'resizeright' ||
    'resizecolumn' =>
      ShellCursorKind.horizontalResize,
    'nw-resize' ||
    'se-resize' ||
    'nwse-resize' ||
    'top-left-corner' ||
    'bottom-right-corner' ||
    'resizeupleftdownright' ||
    'resizeupleft' ||
    'resizedownright' =>
      ShellCursorKind.diagonalNwSeResize,
    'ne-resize' ||
    'sw-resize' ||
    'nesw-resize' ||
    'top-right-corner' ||
    'bottom-left-corner' ||
    'resizeuprightdownleft' ||
    'resizeupright' ||
    'resizedownleft' =>
      ShellCursorKind.diagonalNeSwResize,
    'move' ||
    'grab' ||
    'grabbing' ||
    'all-scroll' ||
    'allscroll' ||
    'all-resize' ||
    'allresize' =>
      ShellCursorKind.move,
    'alias' ||
    'copy' ||
    'alternate' ||
    'up-arrow' ||
    'uparrow' =>
      ShellCursorKind.alternate,
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
  });

  final Widget child;
  final ShellCursorThemeData theme;
  final Stream<String>? platformCursorShapes;
  final Stream<Offset>? platformCursorPositions;
  final Stream<DenialDragIcon?>? platformDragIcons;

  @override
  State<ShellCursorHost> createState() => _ShellCursorHostState();
}

class _ShellCursorHostState extends State<ShellCursorHost> {
  final _cursorController = _ShellCursorController.instance;
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
    final wasHidden = _position == null;
    if (position == _position) {
      return;
    }
    setState(() {
      _position = position;
      if (wasHidden) {
        _frame = 0;
      }
    });
    if (wasHidden) {
      _syncFrameTimer();
    }
  }

  void _updatePosition(PointerEvent event) {
    if (event.kind != PointerDeviceKind.mouse ||
        event.localPosition == _position) {
      return;
    }
    final wasHidden = _position == null;
    setState(() {
      _position = event.localPosition;
      if (wasHidden) {
        _frame = 0;
      }
    });
    if (wasHidden) {
      debugPrint(
        'Denial CURSOR_TRACE software_cursor=visible gate=position '
        'reason=pointer_event event=${event.runtimeType} device=${event.device} '
        'position=${event.localPosition}',
      );
      _syncFrameTimer();
    }
  }

  void _handleExit(PointerExitEvent event) {
    if (event.kind != PointerDeviceKind.mouse || _position == null) {
      return;
    }
    debugPrint(
      'Denial CURSOR_TRACE software_cursor=hidden gate=position '
      'reason=pointer_exit device=${event.device} '
      'position=${event.localPosition}',
    );
    setState(() => _position = null);
    _syncFrameTimer();
  }

  void _syncFrameTimer() {
    final role =
        widget.theme.usesAssetFrames ? widget.theme.roleFor(_kind) : null;
    if (_position == null ||
        !_visible ||
        role == null ||
        role.frameCount <= 1) {
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
    final assetRole =
        widget.theme.usesAssetFrames ? widget.theme.roleFor(_kind) : null;
    final hotspot = assetRole?.hotspot ?? Offset.zero;
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
                left: position.dx + dragIcon.offset.dx,
                top: position.dy + dragIcon.offset.dy,
                width: dragIcon.size.width,
                height: dragIcon.size.height,
                child: IgnorePointer(
                  child: ExcludeSemantics(
                    child: RepaintBoundary(
                      child: SurfaceLayerTexture(layer: dragIcon.layer),
                    ),
                  ),
                ),
              ),
            if (position != null && _visible)
              Positioned(
                left: position.dx - hotspot.dx,
                top: position.dy - hotspot.dy,
                child: IgnorePointer(
                  child: ExcludeSemantics(
                    child: RepaintBoundary(
                      child: assetRole != null
                          ? Image.asset(
                              widget.theme.assetPath(_kind, _frame),
                              width: assetRole.size.width,
                              height: assetRole.size.height,
                              filterQuality: FilterQuality.none,
                              gaplessPlayback: true,
                              excludeFromSemantics: true,
                            )
                          : const CustomPaint(
                              size: _ShellCursorPainter.size,
                              painter: _ShellCursorPainter(),
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

class _ShellCursorController extends ChangeNotifier {
  _ShellCursorController._();

  static final _ShellCursorController instance = _ShellCursorController._();

  final Map<int, ShellCursorKind> _deviceKinds = <int, ShellCursorKind>{};
  ShellCursorKind _kind = ShellCursorKind.normal;

  ShellCursorKind get kind => _kind;
  bool get visible => _visible;

  bool _visible = true;

  void activate(int device, ShellCursorKind kind) {
    _deviceKinds[device] = kind;
    if (_kind == kind && _visible) {
      return;
    }
    if (!_visible) {
      debugPrint(
        'Denial CURSOR_TRACE software_cursor=visible '
        'gate=platform_shape reason=flutter_cursor_activation '
        'device=$device kind=${kind.name}',
      );
    }
    _kind = kind;
    _visible = true;
    notifyListeners();
  }

  void activatePlatformShape(String shape) {
    final normalized = _normalizeShellCursorShape(shape);
    final visible = normalized != 'none' && normalized != 'hidden';
    final kind = shellCursorKindForPlatformShape(normalized);
    if (_kind == kind && _visible == visible) {
      return;
    }
    if (_visible != visible) {
      debugPrint(
        'Denial CURSOR_TRACE software_cursor=${visible ? 'visible' : 'hidden'} '
        'gate=platform_shape reason=native_cursor_shape shape=$normalized',
      );
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
    _ShellCursorController.instance.activate(device, cursor.kind);
    return SystemChannels.mouseCursor.invokeMethod<void>(
      'activateSystemCursor',
      <String, dynamic>{
        'device': device,
        'kind': 'none',
      },
    );
  }

  @override
  void dispose() {}
}

class _ShellCursorPainter extends CustomPainter {
  const _ShellCursorPainter();

  static const Size size = Size(24, 32);

  @override
  void paint(Canvas canvas, Size size) {
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
  }

  @override
  bool shouldRepaint(covariant _ShellCursorPainter oldDelegate) => false;
}
