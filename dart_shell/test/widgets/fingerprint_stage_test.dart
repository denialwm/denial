import 'package:denial_dart_shell/src/core/fingerprint_stage.dart';
import 'package:denial_dart_shell/src/state/fingerprint_scene.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'overlay keeps the scene, black wake is opaque, authenticated home fades',
    (tester) async {
      final key = GlobalKey();
      final acks = <int>[];
      Widget stage(FingerprintScene scene, bool locked) => Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(),
          child: FingerprintStage(
            scene: scene,
            locked: locked,
            onLaidOut: acks.add,
            child: SizedBox(key: key),
          ),
        ),
      );
      const rect = Rect.fromLTWH(254, 1169, 102, 102);
      const output = Rect.fromLTWH(0, 0, 610, 1356);
      await tester.pumpWidget(stage(const FingerprintScene(), true));
      final element = key.currentContext;
      await tester.pumpWidget(
        stage(
          const FingerprintScene(
            epoch: 1,
            texture: 9,
            target: rect,
            output: output,
          ),
          true,
        ),
      );
      expect(key.currentContext, same(element));
      expect(find.byType(ColoredBox), findsNothing);
      expect(tester.widget<Texture>(find.byType(Texture)).textureId, 9);
      expect(acks.last, 1);
      await tester.pumpWidget(
        stage(
          const FingerprintScene(
            epoch: 2,
            black: true,
            texture: 9,
            target: rect,
            output: output,
          ),
          true,
        ),
      );
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        1,
      );
      expect(key.currentContext, same(element));
      await tester.pumpWidget(
        stage(
          const FingerprintScene(
            epoch: 3,
            black: true,
            texture: 9,
            target: rect,
            output: output,
          ),
          true,
        ),
      );
      expect(find.byType(Texture), findsOneWidget);
      expect(acks.last, 3);
      // Native's reveal can arrive before Flutter's authentication event.
      await tester.pumpWidget(
        stage(
          const FingerprintScene(
            epoch: 4,
            reveal: true,
            texture: 9,
            target: rect,
            output: output,
          ),
          true,
        ),
      );
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        1,
      );
      await tester.pumpWidget(
        stage(
          const FingerprintScene(
            epoch: 4,
            reveal: true,
            texture: 9,
            target: rect,
            output: output,
          ),
          false,
        ),
      );
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        0,
      );
      await tester.pump(const Duration(milliseconds: 110));
      final fade = tester.widget<FadeTransition>(find.byType(FadeTransition));
      expect(fade.opacity.value, greaterThan(0));
      expect(fade.opacity.value, lessThan(1));
      // Both pixels are descendants of the exact same in-progress fade.
      expect(
        find.descendant(
          of: find.byType(FadeTransition),
          matching: find.byType(Texture),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(FadeTransition),
          matching: find.byType(ColoredBox),
        ),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      expect(find.byType(ColoredBox), findsNothing);
      expect(key.currentContext, same(element));
    },
  );
  testWidgets(
    'retry interrupts the fade immediately and reduced motion clears the guard',
    (tester) async {
      const output = Rect.fromLTWH(0, 0, 610, 1356);
      const target = Rect.fromLTWH(254, 1169, 102, 102);
      Widget stage(
        FingerprintScene scene,
        bool locked, {
        bool reduced = false,
      }) => Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: FingerprintStage(
            scene: scene,
            locked: locked,
            onLaidOut: (_) {},
            child: const SizedBox(),
          ),
        ),
      );
      const capture = FingerprintScene(
        epoch: 1,
        black: true,
        texture: 9,
        target: target,
        output: output,
      );
      const reveal = FingerprintScene(
        epoch: 2,
        reveal: true,
        texture: 9,
        target: target,
        output: output,
      );
      await tester.pumpWidget(stage(capture, true));
      await tester.pumpWidget(stage(reveal, false));
      await tester.pump(const Duration(milliseconds: 80));
      expect(
        tester
            .widget<FadeTransition>(find.byType(FadeTransition))
            .opacity
            .value,
        lessThan(1),
      );
      await tester.pumpWidget(
        stage(
          const FingerprintScene(
            epoch: 3,
            black: true,
            texture: 9,
            target: target,
            output: output,
          ),
          true,
        ),
      );
      expect(
        tester
            .widget<FadeTransition>(find.byType(FadeTransition))
            .opacity
            .value,
        1,
      );
      expect(find.byType(ColoredBox), findsOneWidget);
      await tester.pumpWidget(
        stage(
          const FingerprintScene(
            epoch: 4,
            fade: true,
            texture: 9,
            target: target,
            output: output,
          ),
          false,
          reduced: true,
        ),
      );
      await tester.pump();
      expect(
        tester
            .widget<FadeTransition>(find.byType(FadeTransition))
            .opacity
            .value,
        0,
      );
      await tester.pumpWidget(
        stage(
          const FingerprintScene(epoch: 5, output: output),
          false,
          reduced: true,
        ),
      );
      expect(find.byType(Texture), findsNothing);
      expect(find.byType(ColoredBox), findsNothing);
    },
  );
}
