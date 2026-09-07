import 'package:denial_dart_shell/src/widgets/retained_window_motion.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('60 motion frames retain app build, layout and paint', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final progress = AnimationController(vsync: tester);
    addTearDown(progress.dispose);
    var builds = 0;
    final probe = _Probe();
    const start = Rect.fromLTWH(0, 0, 400, 800);
    const end = Rect.fromLTWH(60, 98, 280, 560);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 400,
            height: 800,
            child: RetainedWindowMotion(
              progress: progress,
              begin: start,
              end: end,
              endRadius: 24,
              child: RepaintBoundary(
                child: Builder(
                  builder: (_) {
                    builds++;
                    return probe;
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final render = tester.renderObject<_RenderProbe>(find.byType(_Probe));
    final initial = (builds, render.layouts, render.paints);
    for (var frame = 1; frame <= 60; frame++) {
      progress.value = frame / 60;
      await tester.pump();
      final matrix = render.getTransformTo(
        tester.renderObject(find.byType(RetainedWindowMotion)),
      );
      final visual = MatrixUtils.transformRect(
        matrix,
        Offset.zero & render.size,
      );
      expect(visual, rectMoreOrLessEquals(Rect.lerp(start, end, frame / 60)!));
    }
    expect((builds, render.layouts, render.paints), initial);
    expect(render.size, const Size(400, 800));
  });
}

class _Probe extends LeafRenderObjectWidget {
  @override
  RenderObject createRenderObject(BuildContext context) => _RenderProbe();
}

class _RenderProbe extends RenderBox {
  int layouts = 0;
  int paints = 0;
  @override
  void performLayout() {
    layouts++;
    size = constraints.biggest;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    paints++;
    context.canvas.drawRect(
      offset & size,
      Paint()..color = const Color(0xffabcdef),
    );
  }
}
