import 'package:denial_dart_shell/src/desktop/retained_animated_positioned.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const source = Rect.fromLTWH(20, 30, 100, 80);
  const destination = Rect.fromLTWH(220, 130, 200, 160);
  const probeKey = ValueKey<String>('probe');

  testWidgets('animation retains the destination layout between ticks', (
    tester,
  ) async {
    var layouts = 0;
    var taps = 0;
    final painter = _CountingPainter();

    Widget scene(Rect rect) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 640,
          height: 480,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              RetainedAnimatedPositioned(
                rect: rect,
                duration: const Duration(seconds: 1),
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: painter,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        layouts += 1;
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => taps += 1,
                          child: const SizedBox.expand(key: probeKey),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    await tester.pumpWidget(scene(source));
    await tester.pumpWidget(scene(destination));

    final probe = tester.renderObject<RenderBox>(find.byKey(probeKey));
    expect(probe.size, destination.size);
    final layoutsAfterRetarget = layouts;
    final paintsAfterRetarget = painter.paints;
    expect(paintsAfterRetarget, greaterThan(0));

    await tester.pump(const Duration(milliseconds: 500));

    expect(layouts, layoutsAfterRetarget);
    expect(painter.paints, paintsAfterRetarget);
    expect(probe.localToGlobal(Offset.zero), const Offset(120, 80));
    expect(
      probe.localToGlobal(Offset(probe.size.width, probe.size.height)),
      const Offset(270, 200),
    );

    await tester.tapAt(const Offset(195, 140));
    expect(taps, 1);

    await tester.pump(const Duration(milliseconds: 250));
    expect(layouts, layoutsAfterRetarget);
    expect(painter.paints, paintsAfterRetarget);
  });

  testWidgets('retargeting continues from the current visual rectangle', (
    tester,
  ) async {
    const finalRect = Rect.fromLTWH(40, 240, 160, 120);

    Widget scene(Rect rect) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 640,
          height: 480,
          child: Stack(
            children: [
              RetainedAnimatedPositioned(
                rect: rect,
                duration: const Duration(seconds: 1),
                child: const SizedBox.expand(key: probeKey),
              ),
            ],
          ),
        ),
      );
    }

    await tester.pumpWidget(scene(source));
    await tester.pumpWidget(scene(destination));
    await tester.pump(const Duration(milliseconds: 500));

    var probe = tester.renderObject<RenderBox>(find.byKey(probeKey));
    final beforeRetarget = probe.localToGlobal(Offset.zero);

    await tester.pumpWidget(scene(finalRect));
    probe = tester.renderObject<RenderBox>(find.byKey(probeKey));

    expect(probe.localToGlobal(Offset.zero), beforeRetarget);
  });
}

class _CountingPainter extends CustomPainter {
  int paints = 0;

  @override
  void paint(Canvas canvas, Size size) {
    paints += 1;
  }

  @override
  bool shouldRepaint(_CountingPainter oldDelegate) => false;
}
