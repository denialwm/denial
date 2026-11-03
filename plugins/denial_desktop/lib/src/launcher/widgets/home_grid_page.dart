import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'package:denial_flutter_sdk/applications.dart';
import 'package:denial_flutter_sdk/motion.dart' show SelectedListenable;
import 'package:denial_flutter_sdk/rendering.dart';

import '../home_drag_controller.dart';
import '../home_grid_geometry.dart';
import '../home_interactions.dart';
import 'home_tiles.dart';

/// One page of the home grid.
class HomeGridPage extends StatelessWidget {
  const HomeGridPage({
    super.key,
    required this.slots,
    required this.page,
    required this.geometry,
  });

  final List<HomeGridItem?> slots;
  final int page;
  final HomeGridGeometry geometry;

  @override
  Widget build(BuildContext context) {
    final start = page * geometry.pageSize;
    final end = start + geometry.pageSize;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (var index = start; index < end && index < slots.length; index++)
          if (slots[index] case final item?
              when HomeGridLayout.itemFitsInPage(
                index,
                item,
                geometry.pageSize,
                columns: geometry.columns,
              ))
            HomeSlidingTile(
              key: ValueKey(item.id),
              rect: geometry.itemRect(index, item),
              item: item,
              index: index,
            ),
      ],
    );
  }
}

/// A grid or folder tile. It glides to a new place instead of jumping, and
/// steps aside to preview a trade with a dragged tile.
class HomeSlidingTile extends StatefulWidget {
  const HomeSlidingTile({
    super.key,
    required this.rect,
    required this.item,
    required this.index,
    this.inFolder = false,
  });

  final Rect rect;
  final HomeGridItem item;

  /// The item's grid anchor, or its folder's.
  final int index;
  final bool inFolder;

  /// Long presses lift tiles a little sooner than the platform default.
  static const Duration holdDuration = Duration(milliseconds: 380);

  @override
  State<HomeSlidingTile> createState() => _HomeSlidingTileState();
}

typedef _TileLook = ({
  bool hidden,
  bool iconHidden,
  bool merging,
  Offset preview,
});

class _HomeSlidingTileState extends State<HomeSlidingTile>
    with SingleTickerProviderStateMixin {
  final _offset = ValueNotifier(Offset.zero);
  late final _slide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  )..addListener(_glide);
  Offset _from = Offset.zero;
  Offset _to = Offset.zero;
  HomeInteractions? _interactions;
  SelectedListenable<_TileLook>? _look;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final interactions = HomeInteractionScope.of(context);
    if (!identical(interactions, _interactions)) {
      _interactions = interactions;
      _watch();
    }
  }

  @override
  void didUpdateWidget(covariant HomeSlidingTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    final moved = oldWidget.rect.topLeft - widget.rect.topLeft;
    if (moved != Offset.zero) {
      // Keep drawing where it was, then glide to the new place.
      _offset.value += moved;
      _animateTo(_to);
    }
    if (oldWidget.index != widget.index ||
        oldWidget.item.id != widget.item.id) {
      _watch();
    }
  }

  @override
  void dispose() {
    _look?.removeListener(_previewChanged);
    _look?.dispose();
    _slide.dispose();
    _offset.dispose();
    super.dispose();
  }

  void _watch() {
    final interactions = _interactions!;
    _look?.removeListener(_previewChanged);
    _look?.dispose();
    _look = SelectedListenable<_TileLook>(
      Listenable.merge([interactions.drag.drag, interactions.hiddenItems]),
      _lookNow,
    )..addListener(_previewChanged);
    _previewChanged();
  }

  _TileLook _lookNow() {
    final interactions = _interactions!;
    final drag = interactions.drag.drag.value;
    final id = widget.item.id;
    return (
      hidden: drag?.item.id == id,
      iconHidden: interactions.hiddenItems.value.contains(id),
      merging:
          !widget.inFolder &&
          drag != null &&
          drag.landing == null &&
          drag.target == (kind: HomeDropKind.merge, index: widget.index),
      preview: !widget.inFolder && drag?.displacedId == id
          ? drag!.displacement
          : Offset.zero,
    );
  }

  void _previewChanged() {
    final preview = _look!.value.preview;
    if (preview != _to) _animateTo(preview);
  }

  void _animateTo(Offset target) {
    _from = _offset.value;
    _to = target;
    if (_from == _to) return;
    _slide.forward(from: 0);
  }

  void _glide() {
    final t = Curves.easeOutCubic.transform(_slide.value);
    _offset.value = Offset.lerp(_from, _to, t)!;
  }

  Rect? _globalRect() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return MatrixUtils.transformRect(
      box.getTransformTo(null),
      Offset.zero & box.size,
    );
  }

  void _tap() {
    final rect = _globalRect();
    if (rect == null) return;
    final item = widget.item;
    final interactions = _interactions!;
    if (item.isFolder) {
      interactions.openFolder(item, HomeTileMetrics.iconRectIn(rect));
    } else if (item.isApp) {
      interactions.launch(item, HomeTileMetrics.iconRectIn(rect));
    }
  }

  void _hold(LongPressStartDetails details) {
    final rect = _globalRect();
    if (rect == null) return;
    _interactions!.hold(
      widget.item,
      widget.index,
      rect,
      details.globalPosition,
      inFolder: widget.inFolder,
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return Positioned.fromRect(
      rect: widget.rect,
      child: RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: {
          if (!item.resizable)
            TapGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                  TapGestureRecognizer.new,
                  (recognizer) => recognizer.onTap = _tap,
                ),
          LongPressGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                () => LongPressGestureRecognizer(
                  duration: HomeSlidingTile.holdDuration,
                ),
                (recognizer) => recognizer.onLongPressStart = _hold,
              ),
        },
        child: CompositedTranslation(
          translation: _offset,
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
          child: ValueListenableBuilder<_TileLook>(
            valueListenable: _look!,
            builder: (context, look, _) => look.hidden
                ? const SizedBox.expand()
                : RepaintBoundary(
                    child: HomeGridItemCard(
                      item: item,
                      merging: look.merging,
                      iconHidden: look.iconHidden,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
