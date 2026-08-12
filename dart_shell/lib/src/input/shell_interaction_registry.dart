import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum ShellPointerPolicy { none, childBounds, fullScene }

enum ShellKeyboardPolicy { none, capture }

enum ShellCompositorPolicy { normal, exclusive }

@immutable
class ShellInteractionSurface {
  const ShellInteractionSurface({
    required this.id,
    required this.debugLabel,
    required this.pointerPolicy,
    required this.keyboardPolicy,
    required this.compositorPolicy,
    this.bounds,
  });

  final int id;
  final String debugLabel;
  final ShellPointerPolicy pointerPolicy;
  final ShellKeyboardPolicy keyboardPolicy;
  final ShellCompositorPolicy compositorPolicy;
  final Rect? bounds;

  @override
  bool operator ==(Object other) {
    return other is ShellInteractionSurface &&
        other.id == id &&
        other.debugLabel == debugLabel &&
        other.pointerPolicy == pointerPolicy &&
        other.keyboardPolicy == keyboardPolicy &&
        other.compositorPolicy == compositorPolicy &&
        other.bounds == bounds;
  }

  @override
  int get hashCode => Object.hash(
    id,
    debugLabel,
    pointerPolicy,
    keyboardPolicy,
    compositorPolicy,
    bounds,
  );
}

@immutable
class ShellInteractionSnapshot {
  ShellInteractionSnapshot(Map<int, ShellInteractionSurface> surfaces)
    : surfaces = Map<int, ShellInteractionSurface>.unmodifiable(surfaces);

  const ShellInteractionSnapshot.empty()
    : surfaces = const <int, ShellInteractionSurface>{};

  final Map<int, ShellInteractionSurface> surfaces;

  Iterable<ShellInteractionSurface> get orderedSurfaces {
    final ordered = surfaces.values.toList(growable: false)
      ..sort((left, right) => left.id.compareTo(right.id));
    return ordered;
  }

  bool get capturesFullScene => surfaces.values.any(
    (surface) => surface.pointerPolicy == ShellPointerPolicy.fullScene,
  );

  bool get capturesKeyboard => surfaces.values.any(
    (surface) => surface.keyboardPolicy == ShellKeyboardPolicy.capture,
  );

  bool get compositorExclusive => surfaces.values.any(
    (surface) => surface.compositorPolicy == ShellCompositorPolicy.exclusive,
  );

  List<Rect> get childRegions => orderedSurfaces
      .where(
        (surface) =>
            surface.pointerPolicy == ShellPointerPolicy.childBounds &&
            surface.bounds != null,
      )
      .map((surface) => surface.bounds!)
      .toList(growable: false);
}

final shellInteractionRegistryProvider =
    NotifierProvider<ShellInteractionRegistry, ShellInteractionSnapshot>(
      ShellInteractionRegistry.new,
    );

class ShellInteractionRegistry extends Notifier<ShellInteractionSnapshot> {
  @override
  ShellInteractionSnapshot build() => ShellInteractionSnapshot.empty();

  int _nextSurfaceId = 1;

  int reserveSurfaceId() => _nextSurfaceId++;

  void upsert(ShellInteractionSurface surface) {
    if (state.surfaces[surface.id] == surface) {
      return;
    }
    final next = Map<int, ShellInteractionSurface>.of(state.surfaces)
      ..[surface.id] = surface;
    state = ShellInteractionSnapshot(next);
  }

  void remove(int surfaceId) {
    if (!state.surfaces.containsKey(surfaceId)) {
      return;
    }
    final next = Map<int, ShellInteractionSurface>.of(state.surfaces)
      ..remove(surfaceId);
    state = ShellInteractionSnapshot(next);
  }

  void removeIfMounted(int surfaceId) {
    if (!ref.mounted) {
      return;
    }
    remove(surfaceId);
  }
}

/// Declares a shell-owned input surface without requiring callers to calculate
/// or publish its global rectangle. Child-bound surfaces are measured from the
/// render tree after paint, including their current transform.
class ShellInputRegion extends ConsumerStatefulWidget {
  const ShellInputRegion({
    required this.debugLabel,
    required this.child,
    super.key,
    this.active = true,
    this.pointerPolicy = ShellPointerPolicy.childBounds,
    this.keyboardPolicy = ShellKeyboardPolicy.none,
    this.compositorPolicy = ShellCompositorPolicy.normal,
  });

  final String debugLabel;
  final Widget child;
  final bool active;
  final ShellPointerPolicy pointerPolicy;
  final ShellKeyboardPolicy keyboardPolicy;
  final ShellCompositorPolicy compositorPolicy;

  @override
  ConsumerState<ShellInputRegion> createState() => _ShellInputRegionState();
}

class _ShellInputRegionState extends ConsumerState<ShellInputRegion> {
  late final ShellInteractionRegistry _registry;
  late final int _surfaceId;
  Rect? _paintBounds;
  Rect? _pendingBounds;
  bool _publishScheduled = false;

  @override
  void initState() {
    super.initState();
    _registry = ref.read(shellInteractionRegistryProvider.notifier);
    _surfaceId = _registry.reserveSurfaceId();
    _schedulePublish();
  }

  @override
  void didUpdateWidget(covariant ShellInputRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active ||
        oldWidget.debugLabel != widget.debugLabel ||
        oldWidget.pointerPolicy != widget.pointerPolicy ||
        oldWidget.keyboardPolicy != widget.keyboardPolicy ||
        oldWidget.compositorPolicy != widget.compositorPolicy) {
      _schedulePublish();
    }
  }

  void _handlePaintBounds(Rect bounds) {
    if (_pendingBounds == bounds || _paintBounds == bounds) {
      return;
    }
    _pendingBounds = bounds;
    _schedulePublish();
  }

  void _schedulePublish() {
    if (_publishScheduled) {
      return;
    }
    _publishScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _publishScheduled = false;
      if (!mounted) {
        return;
      }
      if (!widget.active) {
        _registry.remove(_surfaceId);
        return;
      }

      if (_pendingBounds case final bounds?) {
        _paintBounds = bounds;
        _pendingBounds = null;
      }
      if (widget.pointerPolicy == ShellPointerPolicy.childBounds &&
          _paintBounds == null) {
        return;
      }
      _registry.upsert(
        ShellInteractionSurface(
          id: _surfaceId,
          debugLabel: widget.debugLabel,
          pointerPolicy: widget.pointerPolicy,
          keyboardPolicy: widget.keyboardPolicy,
          compositorPolicy: widget.compositorPolicy,
          bounds: widget.pointerPolicy == ShellPointerPolicy.childBounds
              ? _paintBounds
              : null,
        ),
      );
    });
  }

  @override
  void dispose() {
    final surfaceId = _surfaceId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _registry.removeIfMounted(surfaceId);
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.pointerPolicy != ShellPointerPolicy.childBounds) {
      return widget.child;
    }
    return _PaintBoundsReporter(
      onPaintBounds: _handlePaintBounds,
      child: widget.child,
    );
  }
}

class _PaintBoundsReporter extends SingleChildRenderObjectWidget {
  const _PaintBoundsReporter({
    required this.onPaintBounds,
    required super.child,
  });

  final ValueChanged<Rect> onPaintBounds;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderPaintBoundsReporter(onPaintBounds);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderPaintBoundsReporter renderObject,
  ) {
    renderObject.onPaintBounds = onPaintBounds;
  }
}

class _RenderPaintBoundsReporter extends RenderProxyBox {
  _RenderPaintBoundsReporter(this.onPaintBounds);

  ValueChanged<Rect> onPaintBounds;
  Rect? _lastBounds;

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    if (!hasSize || size.isEmpty) {
      return;
    }
    final bounds = MatrixUtils.transformRect(
      getTransformTo(null),
      Offset.zero & size,
    );
    if (bounds == _lastBounds) {
      return;
    }
    _lastBounds = bounds;
    onPaintBounds(bounds);
  }
}
