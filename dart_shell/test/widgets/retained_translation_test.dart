import 'package:denial_dart_shell/src/widgets/retained_translation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('translation retains child build, layout, and raster work', (
    tester,
  ) async {
    final translation = ValueNotifier<Offset>(Offset.zero);
    addTearDown(translation.dispose);
    var builds = 0;
    var layouts = 0;
    var taps = 0;
    final painter = _CountingPainter();
    const probeKey = ValueKey<String>('probe');

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 400,
          height: 300,
          child: Stack(
            children: [
              Positioned(
                left: 10,
                top: 20,
                width: 100,
                height: 80,
                child: RetainedTranslation(
                  translation: translation,
                  child: Builder(
                    builder: (context) {
                      builds += 1;
                      return RepaintBoundary(
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
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final buildsBeforeMove = builds;
    final layoutsBeforeMove = layouts;
    final paintsBeforeMove = painter.paints;
    translation.value = const Offset(120, 60);
    await tester.pump();

    expect(builds, buildsBeforeMove);
    expect(layouts, layoutsBeforeMove);
    expect(painter.paints, paintsBeforeMove);
    expect(tester.getTopLeft(find.byKey(probeKey)), const Offset(130, 80));

    await tester.tapAt(const Offset(150, 100));
    expect(taps, 1);
  });

  testWidgets('optional snapping keeps translations on physical pixels', (
    tester,
  ) async {
    final translation = ValueNotifier<Offset>(Offset.zero);
    addTearDown(translation.dispose);
    const probeKey = ValueKey<String>('probe');

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            Positioned(
              left: 10,
              top: 20,
              width: 40,
              height: 30,
              child: RetainedTranslation(
                translation: translation,
                devicePixelRatio: 1.5,
                child: const SizedBox.expand(key: probeKey),
              ),
            ),
          ],
        ),
      ),
    );

    translation.value = const Offset(1, 1);
    await tester.pump();

    expect(
      tester.getTopLeft(find.byKey(probeKey)),
      const Offset(10, 20) + const Offset(4 / 3, 4 / 3),
    );
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
