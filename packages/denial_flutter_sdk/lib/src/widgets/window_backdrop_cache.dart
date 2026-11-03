import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../theme/glass_configuration.dart';
import '../theme/shell_theme.dart';

/// A window backdrop frosted once for a whole scene.
///
/// [image] covers [rect], in the logical coordinates of [frame]'s render
/// object, or of the view when [frame] is null.
@immutable
class FrostedBackdrop {
  const FrostedBackdrop(
    this.image,
    this.rect, {
    this.frame,
    required this.frost,
    this.shaded,
    this.shading,
  });

  final ui.Image image;
  final Rect rect;
  final GlobalKey? frame;

  /// The theme's window frost that blurred [image]. Glass windows shade
  /// their part with the rest of the material; see [WindowBackdropSlice].
  final ui.ImageFilter frost;

  /// [image] with [shading]'s tint, saturation and brightness applied: the
  /// whole glass material away from a window's edge.
  final ui.Image? shaded;
  final WindowGlassShading? shading;

  void dispose() {
    image.dispose();
    shaded?.dispose();
  }

  /// The render object [rect] is relative to; null for the view.
  RenderObject? get frameObject => _frameObjectOf(frame);
}

const ImageFilterContext _frostKeyContext = ImageFilterContext(
  bounds: Rect.fromLTWH(0, 0, 1, 1),
);

/// The frost of the window material [theme] puts behind translucent windows,
/// or null when transparency is off.
ImageFilterConfig? _windowFrostOf(ShellThemeData theme) {
  final enabled =
      theme.backdropBlurEnabled &&
      (theme.transparencyMode == ShellTransparencyMode.glass ||
          theme.backdropBlurSigma > 0);
  return enabled ? theme.windowFrostConfig : null;
}

/// The window glass shader, loaded once. Null when it is unavailable; glass
/// windows then show the frost alone.
final Future<ui.FragmentProgram?> _windowGlass =
    ui.FragmentProgram.fromAsset(
          'packages/denial_flutter_sdk/shaders/window_glass.frag',
        )
        .then<ui.FragmentProgram?>((program) => _loadedWindowGlass = program)
        .catchError((Object error, StackTrace stack) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stack,
              library: 'denial rendering',
              context: ErrorDescription(
                'while loading the window glass shader',
              ),
            ),
          );
          return null;
        });
ui.FragmentProgram? _loadedWindowGlass;

RenderObject? _frameObjectOf(GlobalKey? frame) {
  final object = frame?.currentContext?.findRenderObject();
  return object != null && object.attached ? object : null;
}

/// Frosts a painted boundary, such as the wallpaper, with the window frost.
///
/// The boundary reports each repaint through [painted]. Once its content has
/// settled, it is captured and frosted asynchronously and published as
/// [value]. Windows that move over that static backdrop draw a slice of the
/// image instead of filtering the live scene behind them on every frame.
///
/// Give [frame] when the scene, wallpaper included, can move as a whole: the
/// backdrop is anchored to the frame, so that motion needs no repaints.
class FrostedBackdropCapture extends ValueNotifier<FrostedBackdrop?> {
  FrostedBackdropCapture({this.frame}) : super(null);

  final GlobalKey? frame;

  // A wallpaper change animates for a while. Capture only its final frame.
  static const Duration _settleDelay = Duration(milliseconds: 250);

  // Keeps the blur's darkened edge outside the view.
  static const double _margin = 160;

  RenderRepaintBoundary? _boundary;
  ImageFilterConfig? _filter;
  ui.ImageFilter? _filterKey;
  WindowGlassShading? _shading;
  double _pixelRatio = 1;
  Timer? _timer;
  int _generation = 0;
  bool _capturing = false;
  bool _pending = false;
  bool _disposed = false;

  /// Uses [theme]'s window frost, or clears the backdrop when the theme turns
  /// transparency off. [pixelRatio] is in image pixels per logical pixel;
  /// the frost hides detail, so it can stay below the device's.
  void configure({required ShellThemeData theme, required double pixelRatio}) {
    final filter = _windowFrostOf(theme);
    final key = filter?.resolve(_frostKeyContext);
    final shading = filter == null ? null : theme.windowGlassShading;
    if (key == _filterKey && shading == _shading && pixelRatio == _pixelRatio) {
      return;
    }
    _filter = filter;
    _filterKey = key;
    _shading = shading;
    _pixelRatio = pixelRatio;
    _generation++;
    _schedule(filter == null ? Duration.zero : _settleDelay);
  }

  /// Reports that [boundary] repainted. Called from its paint.
  void painted(RenderRepaintBoundary boundary) {
    _boundary = boundary;
    _generation++;
    _schedule(_settleDelay);
  }

  void _schedule(Duration delay) {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer(delay, _capture);
  }

  Future<void> _capture() async {
    if (_disposed) return;
    final filter = _filter;
    final frost = _filterKey;
    if (filter == null || frost == null) {
      _replace(null);
      return;
    }
    final boundary = _boundary;
    if (boundary == null || !boundary.attached || !boundary.hasSize) return;
    if (_capturing) {
      _pending = true;
      return;
    }
    _capturing = true;
    final generation = _generation;
    final pixelRatio = _pixelRatio;
    final shading = _shading;
    ui.Image? source;
    try {
      final rect = MatrixUtils.transformRect(
        boundary.getTransformTo(_frameObjectOf(frame)),
        Offset.zero & boundary.size,
      );
      source = await boundary.toImage(pixelRatio: pixelRatio);
      if (_disposed || generation != _generation) return;
      final frosted = await _frost(source, rect.size, filter, pixelRatio);
      final backdrop = FrostedBackdrop(
        frosted,
        rect,
        frame: frame,
        frost: frost,
        shaded: shading == null ? null : await _shade(frosted, shading),
        shading: shading,
      );
      await _windowGlass;
      if (_disposed || generation != _generation) {
        backdrop.dispose();
        return;
      }
      _replace(backdrop);
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'denial rendering',
          context: ErrorDescription('while frosting a window backdrop'),
        ),
      );
    } finally {
      source?.dispose();
      _capturing = false;
      if (_pending) {
        _pending = false;
        _schedule(Duration.zero);
      }
    }
  }

  static Future<ui.Image> _frost(
    ui.Image source,
    Size size,
    ImageFilterConfig filter,
    double pixelRatio,
  ) async {
    // Extend the edge pixels past the view so the blur samples a continuous
    // scene up to every edge.
    final bounds = (Offset.zero & size).inflate(_margin);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(pixelRatio);
    canvas.saveLayer(
      null,
      Paint()..imageFilter = filter.resolve(ImageFilterContext(bounds: bounds)),
    );
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = ImageShader(
          source,
          TileMode.clamp,
          TileMode.clamp,
          Matrix4.diagonal3Values(1 / pixelRatio, 1 / pixelRatio, 1).storage,
          filterQuality: FilterQuality.low,
        ),
    );
    canvas.restore();
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(
        (size.width * pixelRatio).ceil(),
        (size.height * pixelRatio).ceil(),
      );
    } finally {
      picture.dispose();
    }
  }

  /// Applies [shading]'s tint, saturation and brightness to [frost] once.
  /// They are a fixed affine color transform of each frost pixel, as
  /// window_glass.frag computes them.
  static Future<ui.Image> _shade(
    ui.Image frost,
    WindowGlassShading shading,
  ) async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImage(
      frost,
      Offset.zero,
      Paint()..colorFilter = ColorFilter.matrix(_glassColorMatrix(shading)),
    );
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(frost.width, frost.height);
    } finally {
      picture.dispose();
    }
  }

  void _replace(FrostedBackdrop? next) {
    final previous = value;
    if (previous == null && next == null) return;
    value = next;
    if (previous == null) return;
    // Recorded slices hold their own reference. Release this one once the
    // dependents have rebuilt with the new image.
    SchedulerBinding.instance
      ..addPostFrameCallback((_) => previous.dispose())
      ..ensureVisualUpdate();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    value?.dispose();
    super.dispose();
  }
}

/// The glass shader's tint, then saturation, then brightness, as one color
/// matrix over straight RGB. Offsets use [ColorFilter.matrix]'s 0–255 scale.
List<double> _glassColorMatrix(WindowGlassShading shading) {
  final tint = [shading.tint.r, shading.tint.g, shading.tint.b];
  final strength = (shading.tintStrength * shading.tint.a).clamp(0.0, 1.0);
  final tintLuminance = 0.299 * tint[0] + 0.587 * tint[1] + 0.114 * tint[2];
  // Dark tints multiply, light tints screen: per channel c * m + o.
  final multiply = tintLuminance < 0.5;
  final m = [
    for (final t in tint)
      multiply ? 1 - strength + 2 * strength * t : 1 - strength * t,
  ];
  final o = [for (final t in tint) multiply ? 0.0 : strength * t];
  // Saturation mixes each channel with the Rec. 709 luminance.
  const luma = [0.2126, 0.7152, 0.0722];
  final saturation = shading.saturation;
  double mix(int row, int column) =>
      (row == column ? saturation : 0) + (1 - saturation) * luma[column];
  // Brightness moves toward white or black: c * a + d.
  final brightness = shading.brightness;
  final a = brightness >= 0 ? 1 - brightness : 1 + brightness;
  final d = brightness >= 0 ? brightness : 0.0;
  return [
    for (var row = 0; row < 3; row++) ...[
      for (var column = 0; column < 3; column++)
        a * mix(row, column) * m[column],
      0,
      255 *
          (a * (mix(row, 0) * o[0] + mix(row, 1) * o[1] + mix(row, 2) * o[2]) +
              d),
    ],
    0,
    0,
    0,
    1,
    0,
  ];
}

/// Lets translucent windows below draw a slice of [backdrop] as their glass,
/// instead of filtering the live scene behind them.
///
/// The slices stay anchored to the backdrop's frame and repaint only when
/// [motion] notifies. It must notify whenever a window below may move within
/// that frame, and whenever [overlayOpacity] changes. Add motion local to a subtree with
/// [WindowBackdropMotion]. A null [backdrop] keeps the live glass.
class WindowBackdropCache extends InheritedWidget {
  const WindowBackdropCache({
    super.key,
    required this.backdrop,
    required this.motion,
    this.overlayColor = const Color(0x00000000),
    this.overlayOpacity,
    required super.child,
  });

  final FrostedBackdrop? backdrop;
  final Listenable motion;

  /// Drawn over the backdrop, such as a scrim between the scene and windows.
  final Color overlayColor;
  final ValueListenable<double>? overlayOpacity;

  /// The nearest scope whose backdrop was frosted with the current theme's
  /// window frost. A window without one keeps the live material, or none when
  /// the theme turns transparency off, until the backdrop is recaptured.
  static WindowBackdropCache? maybeOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<WindowBackdropCache>();
    final backdrop = scope?.backdrop;
    if (backdrop == null) return null;
    final frost = _windowFrostOf(ShellTheme.of(context));
    return frost?.resolve(_frostKeyContext) == backdrop.frost ? scope : null;
  }

  @override
  bool updateShouldNotify(WindowBackdropCache oldWidget) =>
      backdrop != oldWidget.backdrop ||
      motion != oldWidget.motion ||
      overlayColor != oldWidget.overlayColor ||
      overlayOpacity != oldWidget.overlayOpacity;
}

/// Adds [motion] that moves the windows in [child] on screen to the
/// enclosing [WindowBackdropCache].
class WindowBackdropMotion extends StatefulWidget {
  const WindowBackdropMotion({
    super.key,
    required this.motion,
    required this.child,
  });

  final Listenable motion;
  final Widget child;

  @override
  State<WindowBackdropMotion> createState() => _WindowBackdropMotionState();
}

class _WindowBackdropMotionState extends State<WindowBackdropMotion> {
  Listenable? _outer;
  Listenable? _inner;
  Listenable? _merged;

  /// The same merge while both motions are unchanged. A new one on every
  /// build would make each slice below re-subscribe and repaint.
  Listenable _mergedMotion(Listenable outer) {
    if (!identical(outer, _outer) || !identical(widget.motion, _inner)) {
      _outer = outer;
      _inner = widget.motion;
      _merged = Listenable.merge([outer, widget.motion]);
    }
    return _merged!;
  }

  @override
  Widget build(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<WindowBackdropCache>();
    if (scope == null) return widget.child;
    return WindowBackdropCache(
      backdrop: scope.backdrop,
      motion: _mergedMotion(scope.motion),
      overlayColor: scope.overlayColor,
      overlayOpacity: scope.overlayOpacity,
      child: widget.child,
    );
  }
}

/// Fills its parent with the part of [cache]'s backdrop beneath it, in the
/// window's shape.
///
/// The backdrop holds only the frost. A glass window draws [glass], the rest
/// of its material, straight over that frost in one pass: refraction, edge
/// light, rim and tint follow the window's on-screen shape, through any
/// scale, while the costly blur is shared and no layer is allocated.
class WindowBackdropSlice extends LeafRenderObjectWidget {
  const WindowBackdropSlice({
    super.key,
    required this.cache,
    this.borderRadius = BorderRadius.zero,
    this.glass,
    this.opacity,
    this.fadeOverlay = false,
  });

  final WindowBackdropCache cache;
  final BorderRadius borderRadius;
  final WindowGlassShading? glass;

  /// Fades the material. The scope's overlay keeps its own opacity unless
  /// [fadeOverlay] is set.
  final ValueListenable<double>? opacity;

  /// [opacity] fades the material and the scope's overlay together, exactly
  /// as an opacity layer over both would, without the layer.
  final bool fadeOverlay;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderBackdropSlice(
    cache.backdrop!,
    cache.motion,
    cache.overlayColor,
    cache.overlayOpacity,
    borderRadius,
    glass,
    opacity,
    fadeOverlay,
    MediaQuery.devicePixelRatioOf(context),
  );

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderBackdropSlice)
      ..backdrop = cache.backdrop!
      ..motion = cache.motion
      ..overlayColor = cache.overlayColor
      ..overlayOpacity = cache.overlayOpacity
      ..borderRadius = borderRadius
      ..glass = glass
      ..opacity = opacity
      ..fadeOverlay = fadeOverlay
      ..devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
  }
}

class _RenderBackdropSlice extends RenderBox {
  _RenderBackdropSlice(
    this._backdrop,
    this._motion,
    this._overlayColor,
    this._overlayOpacity,
    this._borderRadius,
    this._glass,
    this._opacity,
    this._fadeOverlay,
    this._devicePixelRatio,
  );

  FrostedBackdrop _backdrop;
  Listenable _motion;
  Color _overlayColor;
  ValueListenable<double>? _overlayOpacity;
  BorderRadius _borderRadius;
  WindowGlassShading? _glass;
  ValueListenable<double>? _opacity;
  bool _fadeOverlay;
  double _devicePixelRatio;
  ui.FragmentShader? _shader;

  set backdrop(FrostedBackdrop value) {
    if (identical(value, _backdrop)) return;
    _backdrop = value;
    markNeedsPaint();
  }

  set motion(Listenable value) {
    if (identical(value, _motion)) return;
    if (attached) _motion.removeListener(markNeedsPaint);
    _motion = value;
    if (attached) _motion.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  set overlayColor(Color value) {
    if (value == _overlayColor) return;
    _overlayColor = value;
    markNeedsPaint();
  }

  set overlayOpacity(ValueListenable<double>? value) {
    if (identical(value, _overlayOpacity)) return;
    _overlayOpacity = value;
    markNeedsPaint();
  }

  set borderRadius(BorderRadius value) {
    if (value == _borderRadius) return;
    _borderRadius = value;
    markNeedsPaint();
  }

  set glass(WindowGlassShading? value) {
    if (value == _glass) return;
    _glass = value;
    markNeedsPaint();
  }

  set fadeOverlay(bool value) {
    if (value == _fadeOverlay) return;
    _fadeOverlay = value;
    markNeedsPaint();
  }

  set opacity(ValueListenable<double>? value) {
    if (identical(value, _opacity)) return;
    if (attached) _opacity?.removeListener(markNeedsPaint);
    _opacity = value;
    if (attached) _opacity?.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  set devicePixelRatio(double value) {
    if (value == _devicePixelRatio) return;
    _devicePixelRatio = value;
    markNeedsPaint();
  }

  // Repaints with every move. Keep them out of the window's layer.
  @override
  bool get isRepaintBoundary => true;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _motion.addListener(markNeedsPaint);
    _opacity?.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _motion.removeListener(markNeedsPaint);
    _opacity?.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void dispose() {
    _shader?.dispose();
    _shader = null;
    super.dispose();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) return;
    final frameObject = _backdrop.frameObject;
    final toFrame = getTransformTo(frameObject);
    // Cards scrolled past the scene still move with it, and repaint when
    // they come back into view.
    if (frameObject is RenderBox &&
        !MatrixUtils.transformRect(
          toFrame,
          Offset.zero & size,
        ).overlaps(Offset.zero & frameObject.size)) {
      return;
    }
    final bounds = offset & size;
    final shape = _borderRadius.toRRect(bounds);
    final canvas = context.canvas;
    var opacity = (_opacity?.value ?? 1).clamp(0.0, 1.0).toDouble();
    var alpha = _overlayColor.a * (_overlayOpacity?.value ?? 1);
    if (_fadeOverlay && opacity < 1) {
      // A group fade of the overlay over the material: the overlay fades,
      // and the material keeps exactly the faded share it left uncovered.
      final uncovered = 1 - alpha * opacity;
      final material = uncovered > 0 ? opacity * (1 - alpha) / uncovered : 0.0;
      alpha *= opacity;
      opacity = material;
    }
    final overlay = alpha > 0 ? _overlayColor.withValues(alpha: alpha) : null;
    if (opacity > 0 &&
        _paintMaterial(canvas, toFrame, offset, shape, opacity, overlay)) {
      return;
    }
    if (overlay != null) {
      canvas.drawRRect(shape, Paint()..color = overlay);
    }
  }

  /// Returns whether the material also drew [overlay], as the glass shader
  /// does in the same pass.
  bool _paintMaterial(
    Canvas canvas,
    Matrix4 toFrame,
    Offset offset,
    RRect shape,
    double opacity,
    Color? overlay,
  ) {
    final glass = _glass;
    final program = _loadedWindowGlass;
    if (glass != null && program != null) {
      final shader = _shadeGlass(
        program,
        glass,
        toFrame,
        offset,
        opacity,
        overlay,
      );
      // The shader masks itself to the window's shape.
      if (shader != null) {
        canvas.drawRect(shape.outerRect, _glassPaint..shader = shader);
      }
      return true;
    }
    final fromFrame = Matrix4.tryInvert(toFrame);
    if (fromFrame == null) return false;
    final image = _backdrop.image;
    final rect = _backdrop.rect;
    final imageToLocal = Matrix4.translationValues(offset.dx, offset.dy, 0)
      ..multiply(fromFrame)
      ..multiply(Matrix4.translationValues(rect.left, rect.top, 0))
      ..multiply(
        Matrix4.diagonal3Values(
          rect.width / image.width,
          rect.height / image.height,
          1,
        ),
      );
    canvas.drawRRect(
      shape,
      Paint()
        ..color = Color.fromRGBO(0, 0, 0, opacity)
        ..shader = ImageShader(
          image,
          TileMode.clamp,
          TileMode.clamp,
          imageToLocal.storage,
          filterQuality: FilterQuality.low,
        ),
    );
    return false;
  }

  final _glassPaint = Paint();

  /// Sets the uniforms of window_glass.frag. Its lengths are physical pixels.
  /// The shape follows the full on-screen scale, but the glass keeps its
  /// depth on screen, like the rim: a window scaled down to a card and one
  /// laid out at that card's size show the same material.
  ui.FragmentShader? _shadeGlass(
    ui.FragmentProgram program,
    WindowGlassShading glass,
    Matrix4 toFrame,
    Offset offset,
    double opacity,
    Color? overlay,
  ) {
    final global = getTransformTo(null).storage;
    final scaleX =
        math.sqrt(global[0] * global[0] + global[1] * global[1]) *
        _devicePixelRatio;
    final scaleY =
        math.sqrt(global[4] * global[4] + global[5] * global[5]) *
        _devicePixelRatio;
    if (!(scaleX > 0 && scaleY > 0)) return null;
    final width = size.width * scaleX;
    final height = size.height * scaleY;
    final halfExtent = math.min(width, height) / 2;
    final thickness = math.min(glass.thickness * _devicePixelRatio, halfExtent);
    double corner(Radius radius) =>
        math.min(radius.x * scaleX, radius.y * scaleY);
    // Keep opposing bevels apart on a narrow window, like the engine.
    final bevelWidthScale = math.min(
      glass.bevelWidthScale,
      halfExtent / math.max(thickness, 1e-4),
    );
    // The shaded frost stands for the whole material wherever the rounded
    // edge is at least the bevel and the 2 px antialiasing away. Without a
    // shaded frost for this glass, a distance past any window disables it.
    final shaded = _backdrop.shading == glass ? _backdrop.shaded : null;
    final interiorInset = shaded == null
        ? 1e9
        : thickness * bevelWidthScale + 2;
    // Frost coordinates of a frame point p are (p - rect.topLeft) / size.
    final frame = toFrame.storage;
    final image = _backdrop.image;
    final rect = _backdrop.rect;
    final u = 1 / rect.width;
    final v = 1 / rect.height;
    final halfTexelU = 0.5 / image.width;
    final halfTexelV = 0.5 / image.height;
    final tint = glass.tint;
    final scrim = overlay ?? const Color(0x00000000);
    // Set in declaration order, without building a list on every frame.
    final shader = _shader ??= program.fragmentShader();
    shader
      ..setFloat(0, offset.dx)
      ..setFloat(1, offset.dy)
      ..setFloat(2, scaleX)
      ..setFloat(3, scaleY)
      ..setFloat(4, width)
      ..setFloat(5, height)
      ..setFloat(6, corner(_borderRadius.topLeft))
      ..setFloat(7, corner(_borderRadius.topRight))
      ..setFloat(8, corner(_borderRadius.bottomRight))
      ..setFloat(9, corner(_borderRadius.bottomLeft))
      ..setFloat(10, (frame[12] - rect.left) * u)
      ..setFloat(11, (frame[13] - rect.top) * v)
      ..setFloat(12, frame[0] / scaleX * u)
      ..setFloat(13, frame[1] / scaleX * v)
      ..setFloat(14, frame[4] / scaleY * u)
      ..setFloat(15, frame[5] / scaleY * v)
      ..setFloat(16, halfTexelU)
      ..setFloat(17, halfTexelV)
      ..setFloat(18, 1 - halfTexelU)
      ..setFloat(19, 1 - halfTexelV)
      ..setFloat(20, tint.r)
      ..setFloat(21, tint.g)
      ..setFloat(22, tint.b)
      ..setFloat(23, tint.a)
      ..setFloat(24, thickness)
      // The engine's mapping: 0...1 spans air (1.0) to liquid glass (1.2).
      ..setFloat(25, 1 + glass.refraction.clamp(0.0, 1.0) * 0.2)
      ..setFloat(26, glass.dispersion)
      ..setFloat(27, glass.saturation)
      ..setFloat(28, glass.tintStrength)
      ..setFloat(29, glass.brightness)
      ..setFloat(30, glass.lightAngle)
      ..setFloat(31, glass.lightIntensity)
      ..setFloat(32, glass.edgeStrength)
      ..setFloat(33, bevelWidthScale)
      ..setFloat(34, glass.refractionDepthScale)
      ..setFloat(35, glass.rimWidth)
      ..setFloat(36, glass.rimFalloff)
      ..setFloat(37, glass.oppositeLightStrength)
      ..setFloat(38, opacity)
      ..setFloat(39, interiorInset)
      // The scrim, premultiplied.
      ..setFloat(40, scrim.r * scrim.a)
      ..setFloat(41, scrim.g * scrim.a)
      ..setFloat(42, scrim.b * scrim.a)
      ..setFloat(43, scrim.a);
    if (!identical(image, _boundFrost) || !identical(shaded, _boundShaded)) {
      _boundFrost = image;
      _boundShaded = shaded;
      shader
        ..setImageSampler(0, image, filterQuality: FilterQuality.low)
        ..setImageSampler(1, shaded ?? image, filterQuality: FilterQuality.low);
    }
    return shader;
  }

  ui.Image? _boundFrost;
  ui.Image? _boundShaded;
}
