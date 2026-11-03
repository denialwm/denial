import 'package:flutter/widgets.dart';

import 'package:denial_flutter_sdk/motion.dart';

import '../home_drag_controller.dart';
import '../home_grid_geometry.dart';
import '../home_interactions.dart';
import 'home_item_icon.dart';
import 'home_tiles.dart';
import 'rect_follower.dart';

/// The tile lifted off home: it follows the finger, then settles into its
/// cell, or shrinks into the folder that takes it.
class HomeDragLayer extends StatefulWidget {
  const HomeDragLayer({super.key});

  @override
  State<HomeDragLayer> createState() => _HomeDragLayerState();
}

class _HomeDragLayerState extends State<HomeDragLayer>
    with TickerProviderStateMixin {
  /// A lifted icon grows by this much.
  static const double _liftScale = 1.12;

  late final _lift = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
  );
  late final _land = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  )..addStatusListener(_landed);
  final _rect = ValueNotifier(Rect.zero);
  late final _opacity = _land.drive(
    Animatable<double>.fromCallback(
      (t) => _absorbed ? 1 - Curves.easeIn.transform(t) : 1,
    ),
  );
  late HomeDragController _drag;
  bool _attached = false;
  HomeDrag? _shown;
  Rect _landFrom = Rect.zero;
  bool _absorbed = false;

  @override
  void initState() {
    super.initState();
    _lift.addListener(_place);
    _land.addListener(_place);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final drag = HomeInteractionScope.of(context).drag;
    if (_attached && identical(drag, _drag)) return;
    if (_attached) _detach();
    _drag = drag;
    _attached = true;
    _drag.drag.addListener(_dragChanged);
    _drag.pointer.addListener(_place);
    _dragChanged();
  }

  void _detach() {
    if (!_attached) return;
    _drag.drag.removeListener(_dragChanged);
    _drag.pointer.removeListener(_place);
  }

  @override
  void dispose() {
    _detach();
    _lift.dispose();
    _land.dispose();
    _rect.dispose();
    super.dispose();
  }

  void _dragChanged() {
    final drag = _drag.drag.value;
    final previous = _shown;
    if (drag == null) {
      if (previous != null) setState(() => _shown = null);
      return;
    }
    if (previous == null || previous.item.id != drag.item.id) {
      _land.value = 0;
      _lift.forward(from: 0);
      setState(() => _shown = drag);
    } else {
      _shown = drag;
    }
    final landing = drag.landing;
    if (landing != null && previous?.landing == null) {
      _landFrom = _liftedRect(drag);
      _absorbed = landing.absorbed;
      _land.forward(from: 0);
    }
    _place();
  }

  void _landed(AnimationStatus status) {
    if (status == AnimationStatus.completed && _drag.drag.value != null) {
      _drag.landed();
    }
  }

  Rect _liftedRect(HomeDrag drag) {
    final rect = HomeDragController.visualRectFor(drag, _drag.pointer.value);
    if (drag.item.resizable) return rect;
    final scale = 1 + (_liftScale - 1) * Motion.standard.transform(_lift.value);
    return Rect.fromCenter(
      center: rect.center,
      width: rect.width * scale,
      height: rect.height * scale,
    );
  }

  void _place() {
    final drag = _shown;
    final box = context.findRenderObject();
    if (drag == null || box is! RenderBox || !box.attached) return;
    final landing = drag.landing;
    final global = landing == null
        ? _liftedRect(drag)
        : Rect.lerp(
            _landFrom,
            landing.rect,
            Motion.md3Emphasized.transform(_land.value),
          )!;
    final origin = box.localToGlobal(Offset.zero);
    _rect.value = global.shift(-origin);
  }

  @override
  Widget build(BuildContext context) {
    final drag = _shown;
    if (drag == null) return const SizedBox.shrink();
    final item = drag.item;
    // Icons travel without their labels; a widget travels as it is.
    final size = item.resizable
        ? drag.size
        : const Size.square(HomeTileMetrics.icon);
    return IgnorePointer(
      child: RectFollower(
        rect: _rect,
        size: size,
        child: FadeTransition(
          opacity: _opacity,
          child: item.resizable
              ? HomeGridItemCard(item: item)
              : HomeItemIcon(item: item, rasterize: true),
        ),
      ),
    );
  }
}
