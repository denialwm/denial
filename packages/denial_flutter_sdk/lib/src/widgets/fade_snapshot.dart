import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Fades [child] through a snapshot of it.
///
/// Opacity over content with text cannot be pushed down to its draws, so a
/// plain fade renders the whole subtree into an offscreen layer on every
/// frame. While [opacity] is strictly between 0 and 1, this renders [child]
/// into an image once and then draws only that image, with the opacity, each
/// frame. At 1 the child paints live and the image is released; at 0 nothing
/// paints.
///
/// The snapshot is taken when a fade begins and is not refreshed during it:
/// use this for content that holds still while it fades, such as a home grid
/// behind a transition. A change made mid-fade shows when the fade ends.
class FadeSnapshot extends StatefulWidget {
  const FadeSnapshot({super.key, required this.opacity, required this.child});

  final Animation<double> opacity;
  final Widget child;

  @override
  State<FadeSnapshot> createState() => _FadeSnapshotState();
}

class _FadeSnapshotState extends State<FadeSnapshot> {
  final _controller = SnapshotController();
  late final _painter = _FadeSnapshotPainter(widget.opacity);

  @override
  void initState() {
    super.initState();
    widget.opacity.addListener(_update);
    _update();
  }

  @override
  void didUpdateWidget(covariant FadeSnapshot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.opacity != widget.opacity) {
      oldWidget.opacity.removeListener(_update);
      widget.opacity.addListener(_update);
      _painter.opacity = widget.opacity;
      _update();
    }
  }

  @override
  void dispose() {
    widget.opacity.removeListener(_update);
    _controller.dispose();
    _painter.dispose();
    super.dispose();
  }

  void _update() {
    final opacity = widget.opacity.value;
    _controller.allowSnapshotting = opacity > 0 && opacity < 1;
    _painter.changed();
  }

  @override
  Widget build(BuildContext context) {
    // Only this boundary re-records, one image draw, as the opacity moves.
    return RepaintBoundary(
      child: SnapshotWidget(
        controller: _controller,
        painter: _painter,
        mode: SnapshotMode.permissive,
        autoresize: true,
        child: widget.child,
      ),
    );
  }
}

class _FadeSnapshotPainter extends SnapshotPainter {
  _FadeSnapshotPainter(this.opacity);

  Animation<double> opacity;
  double? _painted;

  void changed() {
    if (opacity.value != _painted) notifyListeners();
  }

  @override
  void paint(
    PaintingContext context,
    Offset offset,
    Size size,
    PaintingContextCallback painter,
  ) {
    final value = _painted = opacity.value;
    if (value <= 0) return;
    if (value >= 1) {
      painter(context, offset);
      return;
    }
    // A snapshot was unavailable: fade the live child instead.
    context.pushOpacity(offset, (value * 255).round(), painter);
  }

  @override
  void paintSnapshot(
    PaintingContext context,
    Offset offset,
    Size size,
    ui.Image image,
    Size sourceSize,
    double pixelRatio,
  ) {
    final value = _painted = opacity.value;
    context.canvas.drawImageRect(
      image,
      Offset.zero & sourceSize,
      offset & size,
      Paint()
        ..color = Color.fromRGBO(0, 0, 0, value)
        ..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(covariant _FadeSnapshotPainter oldPainter) =>
      oldPainter.opacity != opacity;
}
