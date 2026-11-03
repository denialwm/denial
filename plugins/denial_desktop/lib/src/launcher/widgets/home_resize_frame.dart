import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/applications.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/tokens.dart';

import '../home_grid_geometry.dart';
import '../home_interactions.dart';
import '../home_resize_controller.dart';

/// The frame around a widget being resized, with a handle on each edge it
/// can move.
///
/// The frame tracks the held handle's finger; the cells the widget will
/// take show beneath it. Released, the frame settles onto them.
class HomeResizeFrame extends ConsumerStatefulWidget {
  const HomeResizeFrame({
    super.key,
    required this.geometry,
    required this.gridToLocal,
  });

  final ValueGetter<HomeGridGeometry?> geometry;

  /// Maps grid coordinates into this frame's.
  final Rect Function(Rect grid) gridToLocal;

  /// Touch target of a handle; the dot drawn in it is much smaller.
  static const double handleExtent = 56;
  static const double _dot = 16;

  @override
  ConsumerState<HomeResizeFrame> createState() => _HomeResizeFrameState();
}

class _HomeResizeFrameState extends ConsumerState<HomeResizeFrame>
    with TickerProviderStateMixin {
  late final _settle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );

  /// The frame and its handles fade in around the held widget and out
  /// when it is let go.
  late final _appear = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );

  /// The cells the widget will take show while a handle is held.
  late final _fill = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
  );
  late final _appearOpacity = _appear.drive(CurveTween(curve: Curves.easeOut));
  late final _fillOpacity = _fill.drive(CurveTween(curve: Curves.easeOut));
  HomeResizeController? _resize;
  Rect? _released;

  /// The widget the frame shows around; it outlives the target while the
  /// frame fades out.
  int? _shown;

  @override
  void initState() {
    super.initState();
    _appear.addStatusListener((status) {
      if (status == AnimationStatus.dismissed && mounted) {
        setState(() => _shown = null);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final resize = HomeInteractionScope.of(context).resize;
    if (identical(resize, _resize)) return;
    _resize?.target.removeListener(_targetChanged);
    _resize = resize..target.addListener(_targetChanged);
    _targetChanged();
  }

  @override
  void dispose() {
    _resize?.target.removeListener(_targetChanged);
    _settle.dispose();
    _appear.dispose();
    _fill.dispose();
    super.dispose();
  }

  void _targetChanged() {
    final index = _resize!.target.value;
    if (index != null) {
      _shown = index;
      _appear.forward();
    } else {
      _fill.reverse();
      _appear.reverse();
    }
  }

  Widget _handle(HomeResizeEdge edge, Rect frame) {
    final center = switch (edge) {
      HomeResizeEdge.left => frame.centerLeft,
      HomeResizeEdge.top => frame.topCenter,
      HomeResizeEdge.right => frame.centerRight,
      HomeResizeEdge.bottom => frame.bottomCenter,
    };
    const extent = HomeResizeFrame.handleExtent;
    return Positioned.fromRect(
      rect: Rect.fromCenter(center: center, width: extent, height: extent),
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          _settle.stop();
          _fill.forward();
          _resize!.beginHandle(edge, event.position);
        },
        onPointerMove: (event) => _resize!.moveHandle(event.position),
        onPointerUp: (_) => _letGo(),
        onPointerCancel: (_) => _letGo(),
        child: Semantics(
          label: context.l10n.homeResizeWidget,
          child: Center(
            child: Container(
              width: HomeResizeFrame._dot,
              height: HomeResizeFrame._dot,
              decoration: BoxDecoration(
                color: ShellMediaColors.contrastLight,
                shape: BoxShape.circle,
                border: Border.all(
                  color: ShellMediaColors.darkSurface.withValues(alpha: 0.4),
                ),
                boxShadow: const [
                  BoxShadow(color: ShellMediaColors.shadow, blurRadius: 6),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _letGo() {
    _released = _resize!.frame.value;
    _resize!.endHandle();
    _settle.forward(from: 0);
    _fill.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final slots = ref.watch(
      homeGridControllerProvider.select((value) => value.asData?.value.slots),
    );
    return ListenableBuilder(
      listenable: Listenable.merge([_resize!.target, _resize!.frame, _settle]),
      builder: (context, _) {
        final index = _shown;
        final ready = _resize!.target.value == index;
        final geometry = widget.geometry();
        final item = index == null || slots == null || index >= slots.length
            ? null
            : slots[index];
        if (index == null || geometry == null || item == null) {
          return const SizedBox.shrink();
        }
        final span = widget.gridToLocal(geometry.itemRect(index, item));
        final held = _resize!.frame.value;
        final released = _released;
        final frame = held != null
            ? widget.gridToLocal(held)
            : released != null && _settle.isAnimating
            ? Rect.lerp(
                widget.gridToLocal(released),
                span,
                Curves.easeOutCubic.transform(_settle.value),
              )!
            : span;
        final radius = context.shellTheme.scaledRadius(18);
        return IgnorePointer(
          // Fading out, the handles no longer take touches.
          ignoring: !ready,
          child: FadeTransition(
            opacity: _appearOpacity,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // The cells the widget takes while the frame moves freely.
                AnimatedPositioned.fromRect(
                  rect: span,
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOutCubic,
                  child: IgnorePointer(
                    child: FadeTransition(
                      opacity: _fillOpacity,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: ShellMediaColors.lightForeground.withValues(
                            alpha: 0.12,
                          ),
                          borderRadius: BorderRadius.circular(radius),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned.fromRect(
                  rect: frame,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(radius),
                        border: Border.all(
                          color: ShellMediaColors.contrastLight.withValues(
                            alpha: 0.92,
                          ),
                          width: 2.5,
                        ),
                      ),
                    ),
                  ),
                ),
                if (item.minColSpan < item.maxColSpan) ...[
                  _handle(HomeResizeEdge.left, frame),
                  _handle(HomeResizeEdge.right, frame),
                ],
                if (item.minRowSpan < item.maxRowSpan) ...[
                  _handle(HomeResizeEdge.top, frame),
                  _handle(HomeResizeEdge.bottom, frame),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
