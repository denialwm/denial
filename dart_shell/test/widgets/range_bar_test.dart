import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:denial_dart_shell/src/theme/glass_configuration.dart';
import 'package:denial_dart_shell/src/widgets/shade/range_bar.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'glass track keeps foreground and full geometry in one clipped layer',
    (tester) async {
      Widget view(double y) => Directionality(
        textDirection: TextDirection.ltr,
        child: ShellTheme(
          data: const ShellThemeData(
            transparencyMode: ShellTransparencyMode.glass,
          ),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              height: 100,
              child: ClipRect(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Transform.translate(
                    offset: Offset(0, y),
                    child: RangeBar(
                      icon: Icons.volume_up_rounded,
                      value: 0.25,
                      activeColor: const Color(0xff80cbc4),
                      inactiveColor: const Color(0xff263238),
                      translucentTrack: true,
                      showValueMarker: false,
                      height: 56,
                      onChanged: (_) {},
                      onChangeEnd: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      for (final y in [0.0, -20.0, -50.0, -20.0, 0.0]) {
        await tester.pumpWidget(view(y));
        final filter = find.byType(BackdropFilter);
        expect(filter, findsOneWidget);
        expect(tester.getSize(filter), const Size(300, 56));
        expect(
          find.descendant(
            of: filter,
            matching: find.byIcon(Icons.volume_up_rounded),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: filter,
            matching: find.byType(FractionallySizedBox),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('trackpad pan changes the range without snapping to the cursor', (
    tester,
  ) async {
    final changes = <double>[];
    final ended = <double>[];

    await tester.pumpWidget(
      _RangeBarTestHost(onChanged: changes.add, onChangeEnd: ended.add),
    );

    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    final position =
        tester.getTopLeft(find.byType(RangeBar)) + const Offset(270, 19);
    await gesture.panZoomStart(position);
    await gesture.panZoomUpdate(position, pan: const Offset(80, 0));
    await gesture.panZoomEnd();
    await tester.pump();

    expect(changes, isNotEmpty);
    expect(changes.last, closeTo(0.25 + 80 / 300, 0.001));
    expect(ended, hasLength(1));
    expect(ended.single, changes.last);
  });

  testWidgets('direct touch drag still changes the range', (tester) async {
    final changes = <double>[];
    final ended = <double>[];

    await tester.pumpWidget(
      _RangeBarTestHost(onChanged: changes.add, onChangeEnd: ended.add),
    );

    await tester.drag(find.byType(RangeBar), const Offset(80, 0));

    expect(changes, isNotEmpty);
    expect(ended, hasLength(1));
  });

  testWidgets('mouse wheel changes the range by one fixed step', (
    tester,
  ) async {
    final starts = <Object?>[];
    final changes = <double>[];
    final ended = <double>[];

    await tester.pumpWidget(
      _RangeBarTestHost(
        onChangeStart: () => starts.add(null),
        onChanged: changes.add,
        onChangeEnd: ended.add,
      ),
    );

    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    final position = tester.getCenter(find.byType(RangeBar));
    await tester.sendEventToBinding(mouse.hover(position));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -120)));
    await tester.pump();

    expect(starts, hasLength(1));
    expect(changes, <double>[0.30]);
    expect(ended, <double>[0.30]);
  });
}

class _RangeBarTestHost extends StatelessWidget {
  const _RangeBarTestHost({
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
  });

  final ValueChanged<double> onChanged;
  final VoidCallback? onChangeStart;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final child = SizedBox(
      width: 300,
      child: RangeBar(
        icon: Icons.volume_up_rounded,
        value: 0.25,
        activeColor: const Color(0xff80cbc4),
        inactiveColor: const Color(0xff263238),
        onChanged: onChanged,
        onChangeStart: onChangeStart,
        onChangeEnd: onChangeEnd ?? (_) {},
        height: 38,
      ),
    );
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ShellTheme(
        data: const ShellThemeData(),
        child: Center(child: child),
      ),
    );
  }
}
