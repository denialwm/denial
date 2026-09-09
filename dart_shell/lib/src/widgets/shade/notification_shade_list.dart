import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../theme/motion.dart';
import 'shade_backdrop_scene.dart';

/// A normal, lazily laid-out list with two independent paint transforms.
/// [progress] compresses vertical spacing without cropping the cards;
/// [entrance] slides each row from the physical left on its own timeline.
/// Neither animation rebuilds or resizes notification cards or scroll extent.
class NotificationShadeList extends SliverList {
  const NotificationShadeList({
    required super.delegate,
    required this.progress,
    required this.entrance,
    super.key,
  });

  final Animation<double> progress;
  final Animation<double> entrance;

  /// Descendant paint transforms (for example a sideways dismissal) also move
  /// the silhouette, even when a retained row does not repaint this sliver.
  static void invalidateOcclusion(BuildContext context) {
    context
        .findAncestorRenderObjectOfType<_RenderNotificationShadeList>()
        ?.markNeedsPaint();
  }

  @override
  RenderSliverList createRenderObject(BuildContext context) =>
      _RenderNotificationShadeList(
        progress,
        entrance,
        childManager: context as SliverMultiBoxAdaptorElement,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderSliverList renderObject,
  ) {
    (renderObject as _RenderNotificationShadeList)
      ..progress = progress
      ..entrance = entrance;
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
  final _surfaces = <_RenderNotificationShadeSurface>{};
  final _clips = <RenderBox, LayerHandle<ClipPathLayer>>{};
  List<_NotificationPaintRow>? _cachedRows;
  RenderShadeBackdropScene? _scene;
  double _exitExtent = 0;

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

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    RenderObject? ancestor = parent;
    while (ancestor != null && ancestor is! RenderShadeBackdropScene) {
      ancestor = ancestor.parent;
    }
    _scene = ancestor as RenderShadeBackdropScene?;
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
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  double childMainAxisPosition(RenderBox child) =>
      super.childMainAxisPosition(child) * _open - _exitExtent * (1 - _open);

  @override
  double childCrossAxisPosition(RenderBox child) {
    final index = indexOf(child).clamp(0, Motion.notificationHistoryMaxStagger);
    final duration = Motion.notificationHistorySlide.inMilliseconds;
    final stagger = Motion.notificationHistoryStagger.inMilliseconds;
    final total = duration + stagger * Motion.notificationHistoryMaxStagger;
    final phase = ((_entrance.value * total - index * stagger) / duration)
        .clamp(0.0, 1.0);
    return -(constraints.crossAxisExtent + 16) *
        (1 - Curves.easeOutCubic.transform(phase));
  }

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
    for (final surface in _surfaces) {
      final row = byChild[surface._row];
      if (row == null || !surface.hasSize || surface.size.isEmpty) continue;
      row.silhouettes.add(
        surface.shape.transform(surface.getTransformTo(this).storage),
      );
    }
    // Non-zero winding represents the union of the rounded silhouettes.
    // Build one prefix path; subtract once per covered row, not once per pair.
    final covering = Path();
    Rect? coveringBounds;
    void addCover(Path path) {
      covering.addPath(path, Offset.zero);
      final bounds = path.getBounds();
      coveringBounds = coveringBounds?.expandToInclude(bounds) ?? bounds;
    }

    for (final path in _scene?.occludersFor(this) ?? const <Path>[]) {
      addCover(path);
    }
    for (final row in rows) {
      if (coveringBounds != null && row.bounds.overlaps(coveringBounds!)) {
        row.visible = Path.combine(
          PathOperation.difference,
          Path()..addRect(row.bounds),
          covering,
        );
      }
      for (final silhouette in row.silhouettes) {
        addCover(silhouette);
      }
    }
    _cachedRows = rows;
    return rows;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_open <= 0) return;
    for (final row in _paintRows().reversed) {
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
    for (final row in _paintRows()) {
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
