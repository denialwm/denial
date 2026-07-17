import 'package:denial_dart_shell/src/theme/motion.dart';
import 'package:denial_dart_shell/src/widgets/desktop_window_reveal.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const viewport = Size(1000, 800);

  test('window entrance uses the fixed fast duration', () {
    expect(
      Motion.desktopWindowRevealLeadIn,
      const Duration(milliseconds: 64),
    );
    expect(Motion.desktopWindowReveal, const Duration(milliseconds: 320));
  });

  test('origins remain at the centres of the four window quarters', () {
    expect(
      DesktopWindowRevealOrigin.topLeftQuarter.resolve(viewport),
      const Offset(125, 100),
    );
    expect(
      DesktopWindowRevealOrigin.topRightQuarter.resolve(viewport),
      const Offset(875, 100),
    );
    expect(
      DesktopWindowRevealOrigin.bottomRightQuarter.resolve(viewport),
      const Offset(875, 700),
    );
    expect(
      DesktopWindowRevealOrigin.bottomLeftQuarter.resolve(viewport),
      const Offset(125, 700),
    );
  });

  test('completed squircle still covers the whole window', () {
    for (final origin in DesktopWindowRevealOrigin.values) {
      final path = DesktopWindowSquircleRevealClipper(
        origin: origin,
        progress: 1.0,
      ).getClip(viewport);

      expect(path.contains(Offset.zero), isTrue, reason: origin.name);
      expect(
        path.contains(Offset(viewport.width, 0)),
        isTrue,
        reason: origin.name,
      );
      expect(
        path.contains(Offset(0, viewport.height)),
        isTrue,
        reason: origin.name,
      );
      expect(
        path.contains(Offset(viewport.width, viewport.height)),
        isTrue,
        reason: origin.name,
      );
    }
  });

  test('entrance retains Denial squircle profile', () {
    final path = const DesktopWindowSquircleRevealClipper(
      origin: DesktopWindowRevealOrigin.topLeftQuarter,
      progress: 0.5,
    ).getClip(viewport);
    final bounds = path.getBounds();
    final center = DesktopWindowRevealOrigin.topLeftQuarter.resolve(viewport);

    expect(bounds.width / bounds.height, closeTo(viewport.aspectRatio, 0.01));
    expect(path.contains(bounds.topLeft), isFalse);
    expect(
      path.contains(
        Offset(
          center.dx + bounds.width * 0.45,
          center.dy + bounds.height * 0.35,
        ),
      ),
      isTrue,
    );
  });

  testWidgets('new scene entry warms its texture and animates only once',
      (tester) async {
    await tester.pumpWidget(const _RevealHarness());

    expect(find.byType(ClipPath), findsOneWidget);
    expect(find.byType(AnimatedBuilder), findsNothing);
    expect(_clipper(tester).progress, 0.001);

    await tester.pump(
      Motion.desktopWindowRevealLeadIn + const Duration(milliseconds: 1),
    );
    expect(find.byType(AnimatedBuilder), findsOneWidget);
    expect(_clipper(tester).progress, 0.0);

    // The controller begins from the post-frame callback above, so its first
    // ticker frame intentionally preserves the fully laid-out start state.
    await tester.pump();
    await tester.pump(Motion.desktopWindowReveal * 0.5);
    expect(_clipper(tester).progress, inExclusiveRange(0.0, 1.0));

    await tester.pump(
      Motion.desktopWindowReveal + const Duration(milliseconds: 1),
    );
    await tester.pump();
    expect(find.byType(ClipPath), findsNothing);
    expect(find.byType(AnimatedBuilder), findsNothing);

    await tester.pumpWidget(const _RevealHarness());
    expect(find.byType(ClipPath), findsNothing);
    expect(find.byType(AnimatedBuilder), findsNothing);
  });

  testWidgets('entrance timeline is independent of window size',
      (tester) async {
    final compactProgress = await _midpointProgress(
      tester,
      key: const ValueKey<String>('compact'),
      size: const Size(240, 160),
    );
    final largeProgress = await _midpointProgress(
      tester,
      key: const ValueKey<String>('large'),
      size: const Size(1600, 1000),
    );

    expect(compactProgress, inExclusiveRange(0.0, 1.0));
    expect(largeProgress, closeTo(compactProgress, 0.000001));
  });

  testWidgets('normal root still enters after transient metadata settles',
      (tester) async {
    await tester.pumpWidget(const _RevealHarness(enabled: false));
    expect(find.byType(AnimatedBuilder), findsNothing);

    await tester.pumpWidget(const _RevealHarness());
    expect(find.byType(ClipPath), findsOneWidget);

    await tester.pump(
      Motion.desktopWindowRevealLeadIn + const Duration(milliseconds: 1),
    );
    expect(find.byType(AnimatedBuilder), findsOneWidget);
  });

  testWidgets('disabled entrance displays transient surfaces immediately',
      (tester) async {
    await tester.pumpWidget(const _RevealHarness(enabled: false));

    expect(find.byType(ClipPath), findsNothing);
    expect(find.byType(AnimatedBuilder), findsNothing);
    expect(find.byKey(const ValueKey<String>('window')), findsOneWidget);
  });

  testWidgets('reduced motion displays the scene entry immediately',
      (tester) async {
    await tester.pumpWidget(
      const _RevealHarness(disableAnimations: true),
    );

    expect(find.byType(ClipPath), findsNothing);
    expect(find.byType(AnimatedBuilder), findsNothing);
    expect(find.byKey(const ValueKey<String>('window')), findsOneWidget);
  });
}

DesktopWindowSquircleRevealClipper _clipper(WidgetTester tester) {
  return tester.widget<ClipPath>(find.byType(ClipPath)).clipper!
      as DesktopWindowSquircleRevealClipper;
}

Future<double> _midpointProgress(
  WidgetTester tester, {
  required Key key,
  required Size size,
}) async {
  await tester.pumpWidget(_RevealHarness(key: key, size: size));
  await tester.pump(
    Motion.desktopWindowRevealLeadIn + const Duration(milliseconds: 1),
  );
  await tester.pump();
  await tester.pump(Motion.desktopWindowReveal * 0.5);
  return _clipper(tester).progress;
}

class _RevealHarness extends StatelessWidget {
  const _RevealHarness({
    super.key,
    this.size = const Size(1000, 800),
    this.disableAnimations = false,
    this.enabled = true,
  });

  final Size size;
  final bool disableAnimations;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return MediaQuery(
      data: MediaQueryData(size: size, disableAnimations: disableAnimations),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox.fromSize(
          size: size,
          child: DesktopWindowReveal(
            enabled: enabled,
            origin: DesktopWindowRevealOrigin.topLeftQuarter,
            child: const ColoredBox(
              key: ValueKey<String>('window'),
              color: Color(0xff000000),
            ),
          ),
        ),
      ),
    );
  }
}
