import 'package:denial_dart_shell/src/shell_app.dart';
import 'package:denial_dart_shell/src/theme/motion.dart';
import 'package:denial_dart_shell/src/widgets/desktop_window_reveal.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('session transition keeps moving through its terminal tenth', () {
    final curve = Motion.sessionTransitionCurve;
    final initialTravel = curve.transform(0.1);
    final terminalTravel = 1.0 - curve.transform(0.9);

    expect(initialTravel, greaterThan(0.015));
    expect(terminalTravel, greaterThan(0.015));
    expect(terminalTravel, closeTo(initialTravel, 0.000001));
  });

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

  testWidgets('transition ticks do not rebuild the lock subtree', (
    tester,
  ) async {
    final harnessKey = GlobalKey<_UnlockHarnessState>();
    var lockBuilds = 0;

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1000, 800)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox.fromSize(
            size: const Size(1000, 800),
            child: _UnlockHarness(
              key: harnessKey,
              onLockBuild: () => lockBuilds += 1,
            ),
          ),
        ),
      ),
    );
    expect(lockBuilds, 1);

    harnessKey.currentState!.unlock();
    await tester.pump();
    final buildsAtStart = lockBuilds;
    await tester.pump(
      Duration(microseconds: Motion.unlock.inMicroseconds ~/ 3),
    );
    await tester.pump(
      Duration(microseconds: Motion.unlock.inMicroseconds ~/ 3),
    );

    expect(lockBuilds, buildsAtStart);
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
  const _UnlockHarness({super.key, this.onLockBuild});

  final VoidCallback? onLockBuild;

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
      lockLayerBuilder: (_) => _LockTestLayer(onBuild: widget.onLockBuild),
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

class _LockTestLayer extends StatelessWidget {
  const _LockTestLayer({this.onBuild});

  final VoidCallback? onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild?.call();
    return const ColoredBox(
      key: ValueKey<String>('lock-layer'),
      color: Color(0xff050608),
    );
  }
}
