import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:denial_dart_shell/src/state/desktop_window_close_effect.dart';
import 'package:denial_dart_shell/src/theme/motion.dart';
import 'package:denial_dart_shell/src/widgets/desktop_window_close_animation.dart';
import 'package:denial_dart_shell/src/widgets/desktop_window_snapshot.dart';

void main() {
  testWidgets('explosion paints particles and completes on schedule', (
    tester,
  ) async {
    var completed = false;
    await tester.pumpWidget(
      _TestHost(
        child: DesktopWindowCloseAnimation(
          effect: DesktopWindowCloseEffect.explosion,
          seed: 17,
          onCompleted: () => completed = true,
          child: const ColoredBox(color: Color(0xff20242c)),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('desktop-window-close-explosion')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<DesktopWindowSnapshotScope>(
            find.byType(DesktopWindowSnapshotScope),
          )
          .snapshotting,
      isTrue,
    );
    expect(completed, isFalse);

    await tester.pump(Motion.desktopWindowCloseExplosion);
    await tester.pump(const Duration(milliseconds: 1));

    expect(completed, isTrue);
  });

  testWidgets('reduced motion completes without retaining a ticker', (
    tester,
  ) async {
    var completed = false;
    await tester.pumpWidget(
      _TestHost(
        disableAnimations: true,
        child: DesktopWindowCloseAnimation(
          effect: DesktopWindowCloseEffect.explosion,
          seed: 23,
          onCompleted: () => completed = true,
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();

    expect(
      tester
          .widget<DesktopWindowSnapshotScope>(
            find.byType(DesktopWindowSnapshotScope),
          )
          .snapshotting,
      isFalse,
    );
    expect(completed, isTrue);
    expect(tester.binding.transientCallbackCount, 0);
  });
}

class _TestHost extends StatelessWidget {
  const _TestHost({required this.child, this.disableAnimations = false});

  final Widget child;
  final bool disableAnimations;

  @override
  Widget build(BuildContext context) {
    return MediaQuery(
      data: MediaQueryData(
        size: const Size(800, 600),
        disableAnimations: disableAnimations,
      ),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: SizedBox(width: 320, height: 220, child: child)),
      ),
    );
  }
}
