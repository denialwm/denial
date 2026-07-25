import 'package:denial_dart_shell/src/shell_app.dart';
import 'package:denial_dart_shell/src/theme/motion.dart';
import 'package:denial_dart_shell/src/widgets/desktop_window_reveal.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('desktop lock is the inverse of unlock without remounting', (
    tester,
  ) async {
    final harnessKey = GlobalKey<_UnlockHarnessState>();

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1000, 800)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox.fromSize(
            size: const Size(1000, 800),
            child: _UnlockHarness(key: harnessKey),
          ),
        ),
      ),
    );
    await tester.pump(
      Motion.desktopWindowRevealLeadIn + const Duration(milliseconds: 1),
    );
    await tester.pump(
      Motion.desktopWindowReveal + const Duration(milliseconds: 1),
    );
    await tester.pump();

    final reveal = find.byType(DesktopWindowReveal);
    final originalRevealState = tester.state(reveal);
    final transitionHeight = tester
        .getSize(find.byType(UnlockTransitionHost))
        .height;
    expect(_clipsInside(reveal), findsNothing);

    harnessKey.currentState!.unlock();
    await tester.pump();
    expect(tester.state(reveal), same(originalRevealState));
    expect(_clipsInside(reveal), findsNothing);

    await tester.pump(
      Duration(microseconds: Motion.unlock.inMicroseconds ~/ 2),
    );
    final lockRect = tester.getRect(
      find.byKey(const ValueKey<String>('lock-layer')),
    );
    final desktopRect = tester.getRect(
      find.byKey(const ValueKey<String>('existing-window')),
    );
    expect(lockRect.top, lessThan(0));
    expect(desktopRect.top, greaterThan(0));
    expect(lockRect.bottom, closeTo(desktopRect.top, 0.01));
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey<String>('unlock-lock-stage')),
        matching: find.byType(Opacity),
      ),
      findsNothing,
    );
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey<String>('unlock-desktop-stage')),
        matching: find.byType(Opacity),
      ),
      findsNothing,
    );

    await tester.pump(Motion.unlock + const Duration(milliseconds: 1));
    await tester.pump();

    expect(find.byKey(const ValueKey<String>('lock-layer')), findsNothing);
    expect(tester.state(reveal), same(originalRevealState));
    expect(_clipsInside(reveal), findsNothing);

    harnessKey.currentState!.lock();
    await tester.pump();

    expect(tester.state(reveal), same(originalRevealState));
    expect(
      tester.getRect(find.byKey(const ValueKey<String>('lock-layer'))).top,
      closeTo(-transitionHeight, 0.01),
    );
    expect(
      tester.getRect(find.byKey(const ValueKey<String>('existing-window'))).top,
      closeTo(0, 0.01),
    );

    await tester.pump(
      Duration(microseconds: Motion.unlock.inMicroseconds ~/ 2),
    );

    final inverseLockRect = tester.getRect(
      find.byKey(const ValueKey<String>('lock-layer')),
    );
    final inverseDesktopRect = tester.getRect(
      find.byKey(const ValueKey<String>('existing-window')),
    );
    expect(inverseLockRect, lockRect);
    expect(inverseDesktopRect, desktopRect);

    await tester.pump(Motion.unlock + const Duration(milliseconds: 1));

    expect(
      tester.getRect(find.byKey(const ValueKey<String>('lock-layer'))).top,
      closeTo(0, 0.01),
    );
    expect(
      tester.getRect(find.byKey(const ValueKey<String>('existing-window'))).top,
      closeTo(transitionHeight, 0.01),
    );
    expect(tester.state(reveal), same(originalRevealState));
    expect(_clipsInside(reveal), findsNothing);
  });
}

Finder _clipsInside(Finder reveal) {
  return find.descendant(
    of: reveal,
    matching: find.byWidgetPredicate(
      (widget) => widget is ClipRect || widget is TweenAnimationBuilder<double>,
    ),
  );
}

class _UnlockHarness extends StatefulWidget {
  const _UnlockHarness({super.key});

  @override
  State<_UnlockHarness> createState() => _UnlockHarnessState();
}

class _UnlockHarnessState extends State<_UnlockHarness> {
  var _locked = true;
  var _lockLayerVisible = true;

  void unlock() {
    setState(() => _locked = false);
  }

  void lock() {
    setState(() {
      _locked = true;
      _lockLayerVisible = true;
    });
  }

  void _completeUnlock() {
    setState(() => _lockLayerVisible = false);
  }

  @override
  Widget build(BuildContext context) {
    return UnlockTransitionHost(
      locked: _locked,
      lockLayerVisible: _lockLayerVisible,
      animateLock: true,
      onUnlockComplete: _completeUnlock,
      backdrop: const SizedBox.shrink(),
      lockLayerBuilder: (_) => const ColoredBox(
        key: ValueKey<String>('lock-layer'),
        color: Color(0xff050608),
      ),
      scene: const DesktopWindowReveal(
        child: ColoredBox(
          key: ValueKey<String>('existing-window'),
          color: Color(0xff20242b),
        ),
      ),
      chrome: const SizedBox.shrink(),
    );
  }
}
