import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'shade_backdrop_scene.dart';

/// A normal, lazily laid-out list with expansion-aware vertical positions.
/// [progress] compresses vertical spacing without cropping the cards;
/// [entrance] invalidates the cached silhouettes while descendant rows run
/// their ColorOS alpha/scale/spacing reveal. Neither animation rebuilds or
/// resizes notification cards or scroll extent.
///
/// Rows that overlap while the stack compresses stack by direction: opening
/// from closed, each row lies over the ones below it; closing from open, the
/// last row lies on top, so the stack gathers upward under it. The order only
/// changes at rest, fully open or closed, where no rows overlap.
class NotificationShadeList extends SliverList {
  const NotificationShadeList({
    required super.delegate,
    required this.progress,
    required this.entrance,
    this.opaqueRows = false,
    this.onRowsMoved,
    super.key,
  });

  final Animation<double> progress;
  final Animation<double> entrance;

  /// The rows paint opaque material. Once [entrance] has revealed them they
  /// hide one another by paint order alone, without per-row clips.
  final bool opaqueRows;

  /// Called whenever rows may have moved without this list repainting them:
  /// after a layout, and for a descendant transform such as a dismissal.
  /// Retained glass slices in the rows follow through it.
  final VoidCallback? onRowsMoved;

  /// Descendant paint transforms (for example a sideways dismissal) also move
  /// the silhouette, even when a retained row does not repaint this sliver.
  static void invalidateOcclusion(BuildContext context) {
    final list = context
        .findAncestorRenderObjectOfType<_RenderNotificationShadeList>();
    list?.markNeedsPaint();
    list?.onRowsMoved?.call();
  }

  @override
  RenderSliverList createRenderObject(BuildContext context) =>
      _RenderNotificationShadeList(
          progress,
          entrance,
          childManager: context as SliverMultiBoxAdaptorElement,
        )
        ..opaqueRows = opaqueRows
        ..onRowsMoved = onRowsMoved;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderSliverList renderObject,
  ) {
    (renderObject as _RenderNotificationShadeList)
      ..progress = progress
      ..entrance = entrance
      ..opaqueRows = opaqueRows
      ..onRowsMoved = onRowsMoved;
  }
}

class _RenderNotificationShadeList extends RenderSliverList {
  _RenderNotificationShadeList(
    this._progress,
    this._entrance, {
    required super.childManager,
  });

  Animation<double> _progress;
  Animation<double> _entrance;
  VoidCallback? onRowsMoved;
  bool _opaqueRows = false;
  set opaqueRows(bool value) {
    if (value == _opaqueRows) return;
    _opaqueRows = value;
    markNeedsPaint();
  }

  final _surfaces = <_RenderNotificationShadeSurface>{};
  final _clips = <RenderBox, LayerHandle<ClipPathLayer>>{};
  List<_NotificationPaintRow>? _cachedRows;
  RenderShadeBackdropScene? _scene;
  double _exitExtent = 0;
  double _restingOpen = 0;
  bool _lastOnTop = false;

  @override
  void markNeedsPaint() {
    _cachedRows = null;
    super.markNeedsPaint();
    if (_scene?.attached ?? false) _scene!.markNeedsPaint();
  }

  @override
  void performLayout() {
    super.performLayout();
    _exitExtent = 0;
    final live = <RenderBox>{};
    for (var child = firstChild; child != null; child = childAfter(child)) {
      live.add(child);
      final y = super.childMainAxisPosition(child);
      if (y < constraints.remainingPaintExtent &&
          y + child.size.height > 0 &&
          child.size.height > _exitExtent) {
        _exitExtent = child.size.height;
      }
    }
    for (final child
        in _clips.keys.where((child) => !live.contains(child)).toList()) {
      _clips.remove(child)!.layer = null;
    }
    _cachedRows = null;
    onRowsMoved?.call();
  }

  @override
  bool paintsChild(RenderBox child) {
    if (!super.paintsChild(child) || !child.hasSize) return false;
    final y = super.childMainAxisPosition(child);
    return y < constraints.remainingPaintExtent && y + child.size.height > 0;
  }

  @override
  void dispose() {
    for (final clip in _clips.values) {
      clip.layer = null;
    }
    _clips.clear();
    super.dispose();
  }

  set progress(Animation<double> value) {
    if (identical(value, _progress)) return;
    if (attached) _progress.removeListener(_motionChanged);
    _progress = value;
    if (attached) _progress.addListener(_motionChanged);
    _motionChanged();
  }

  set entrance(Animation<double> value) {
    if (identical(value, _entrance)) return;
    if (attached) _entrance.removeListener(_motionChanged);
    _entrance = value;
    if (attached) _entrance.addListener(_motionChanged);
    _motionChanged();
  }

  double get _open => _progress.value.clamp(0.0, 1.0);

  // Complete the row exit before the shade itself reaches zero. Stopping at
  // exactly one row height leaves a visible strip pinned to the screen edge
  // until the enclosing shade is removed.
  static const double _exitTravel = 1.2;

  /// How far a closed row sits above its list: past the top of the screen,
  /// so rows leave over the header rather than stopping below it. It is the
  /// list's live distance from the screen top, so the shade's own motion
  /// cannot leave a row on screen.
  double get _exitDistance {
    final toScreen = Matrix4.tryInvert(getTransformTo(null));
    final screenTop = toScreen == null
        ? 0.0
        : MatrixUtils.transformPoint(toScreen, Offset.zero).dy;
    return math.max(0.0, -screenTop) + _exitExtent * _exitTravel;
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    RenderObject? ancestor = parent;
    while (ancestor != null && ancestor is! RenderShadeBackdropScene) {
      ancestor = ancestor.parent;
    }
    _scene = ancestor as RenderShadeBackdropScene?;
    _restingOpen = _open;
    _progress.addListener(_motionChanged);
    _entrance.addListener(_motionChanged);
  }

  @override
  void detach() {
    _progress.removeListener(_motionChanged);
    _entrance.removeListener(_motionChanged);
    _scene = null;
    super.detach();
  }

  void _motionChanged() {
    final open = _open;
    if (_restingOpen >= 1 && open < 1) {
      _lastOnTop = true;
    } else if (_restingOpen <= 0 && open > 0) {
      _lastOnTop = false;
    }
    _restingOpen = open;
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  double childMainAxisPosition(RenderBox child) {
    final open = _open;
    final base = super.childMainAxisPosition(child) * open;
    return open >= 1 ? base : base - _exitDistance * (1 - open);
  }

  @override
  double childCrossAxisPosition(RenderBox child) => 0;

  List<_NotificationPaintRow> _paintRows() {
    // This shell list always runs downward. Keep the standard sliver's layout,
    // scroll extent and visible-child selection; only its paint regions differ.
    assert(constraints.axisDirection == AxisDirection.down);
    assert(constraints.growthDirection == GrowthDirection.forward);
    if (_cachedRows != null) return _cachedRows!;
    final rows = <_NotificationPaintRow>[];
    final byChild = <RenderObject, _NotificationPaintRow>{};
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final baseY = super.childMainAxisPosition(child);
      if (baseY >= constraints.remainingPaintExtent ||
          baseY + child.size.height <= 0) {
        continue;
      }
      final row = _NotificationPaintRow(
        child,
        Offset(childCrossAxisPosition(child), childMainAxisPosition(child)),
      );
      rows.add(row);
      byChild[child] = row;
    }
    // Opaque rows need no silhouettes once fully revealed: each one covers
    // whatever it overlaps, and only scene occluders still cut them.
    final rowsOcclude = !_opaqueRows || _entrance.value < 1;
    for (final surface
        in rowsOcclude
            ? _surfaces
            : const <_RenderNotificationShadeSurface>{}) {
      final row = byChild[surface._row];
      if (row == null || !surface.hasSize || surface.size.isEmpty) continue;
      row.silhouettes.add(
        surface.shape.transform(surface.getTransformTo(this).storage),
      );
    }
    // From the top of the stack down, each row subtracts only the silhouettes
    // above it that reach it, usually just its neighbor while the stack
    // compresses, so the boolean work stays linear in the row count. Non-zero
    // winding represents their union. A row that nothing reaches paints
    // without a clip.
    final covers = <(Path, Rect)>[
      for (final path in _scene?.occludersFor(this) ?? const <Path>[])
        (path, path.getBounds()),
    ];
    for (final row in _lastOnTop ? rows.reversed : rows) {
      final bounds = row.bounds;
      Path? covering;
      for (final (path, coverBounds) in covers) {
        if (!coverBounds.overlaps(bounds)) continue;
        (covering ??= Path()).addPath(path, Offset.zero);
      }
      if (covering != null) {
        row.visible = Path.combine(
          PathOperation.difference,
          Path()..addRect(bounds),
          covering,
        );
      }
      for (final silhouette in row.silhouettes) {
        covers.add((silhouette, silhouette.getBounds()));
      }
    }
    _cachedRows = rows;
    return rows;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_open <= 0) return;
    final rows = _paintRows();
    for (final row in _lastOnTop ? rows : rows.reversed) {
      final visible = row.visible;
      if (visible == null) {
        context.paintChild(row.child, offset + row.offset);
      } else if (!visible.getBounds().isEmpty) {
        final clip = _clips.putIfAbsent(
          row.child,
          () => LayerHandle<ClipPathLayer>(),
        );
        clip.layer = context.pushClipPath(
          needsCompositing,
          offset,
          row.bounds,
          visible,
          (context, offset) =>
              context.paintChild(row.child, offset + row.offset),
          oldLayer: clip.layer,
        );
      }
    }
  }

  @override
  bool hitTestChildren(
    SliverHitTestResult result, {
    required double mainAxisPosition,
    required double crossAxisPosition,
  }) {
    if (_open <= 0) return false;
    final point = Offset(crossAxisPosition, mainAxisPosition);
    final boxResult = BoxHitTestResult.wrap(result);
    final rows = _paintRows();
    for (final row in _lastOnTop ? rows.reversed : rows) {
      if (row.visible != null && !row.visible!.contains(point)) continue;
      if (hitTestBoxChild(
        boxResult,
        row.child,
        mainAxisPosition: mainAxisPosition,
        crossAxisPosition: crossAxisPosition,
      )) {
        return true;
      }
    }
    return false;
  }
}

class _NotificationPaintRow {
  _NotificationPaintRow(this.child, this.offset);

  final RenderBox child;
  final Offset offset;
  final silhouettes = <Path>[];
  Path? visible;
  Rect get bounds {
    var bounds = child.paintBounds.shift(offset);
    for (final silhouette in silhouettes) {
      bounds = bounds.expandToInclude(silhouette.getBounds());
    }
    return bounds;
  }
}

/// Marks the actual rounded card, excluding row gutters and external controls.
/// Its transform includes both the stack motion and a sideways dismissal.
class NotificationShadeSurface extends SingleChildRenderObjectWidget {
  const NotificationShadeSurface({
    required super.child,
    required this.borderRadius,
    super.key,
  });

  final BorderRadius borderRadius;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderNotificationShadeSurface(borderRadius);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderNotificationShadeSurface).radius = borderRadius;
  }
}

class _RenderNotificationShadeSurface extends RenderProxyBox {
  _RenderNotificationShadeSurface(this._radius);

  BorderRadius _radius;
  _RenderNotificationShadeList? _owner;
  RenderObject? _row;
  Path? _shape;
  Path get shape =>
      _shape ??= Path()..addRRect(radius.toRRect(Offset.zero & size));

  @override
  void performLayout() {
    super.performLayout();
    _shape = null;
    _owner?.markNeedsPaint();
  }

  BorderRadius get radius => _radius;
  set radius(BorderRadius value) {
    if (_radius == value) return;
    _radius = value;
    _shape = null;
    _owner?.markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    RenderObject? ancestor = parent;
    _row = this;
    while (ancestor != null && ancestor is! _RenderNotificationShadeList) {
      _row = ancestor;
      ancestor = ancestor.parent;
    }
    _owner = ancestor as _RenderNotificationShadeList?;
    _owner?._surfaces.add(this);
    _owner?.markNeedsPaint();
  }

  @override
  void detach() {
    final owner = _owner;
    owner?._surfaces.remove(this);
    if (owner?.attached ?? false) owner!.markNeedsPaint();
    _owner = null;
    _row = null;
    super.detach();
  }
}
