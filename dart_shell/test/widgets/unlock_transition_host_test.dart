import 'package:denial_dart_shell/src/shell_app.dart';
import 'package:denial_dart_shell/src/theme/motion.dart';
import 'package:denial_dart_shell/src/widgets/desktop_window_reveal.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('unlock keeps existing desktop window scene mounted',
      (tester) async {
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
    expect(_clipsInside(reveal), findsNothing);

    harnessKey.currentState!.unlock();
    await tester.pump();
    expect(tester.state(reveal), same(originalRevealState));
    expect(_clipsInside(reveal), findsNothing);

    await tester.pump(Motion.unlock + const Duration(milliseconds: 1));
    await tester.pump();

    expect(find.byKey(const ValueKey<String>('lock-layer')), findsNothing);
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

  void _completeUnlock() {
    setState(() => _lockLayerVisible = false);
  }

  @override
  Widget build(BuildContext context) {
    return UnlockTransitionHost(
      locked: _locked,
      lockLayerVisible: _lockLayerVisible,
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
