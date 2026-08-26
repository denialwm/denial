import 'package:denial_dart_shell/src/desktop/desktop_overview_preview_interaction.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('scaled overview preview follows the global pointer delta', (
    tester,
  ) async {
    final updates = <Offset>[];

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: Transform.scale(
            scale: 0.5,
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              height: 300,
              child: DesktopOverviewPreviewInteraction(
                overviewActive: true,
                overview: true,
                desktopWidget: false,
                dragging: false,
                label: 'Window',
                onTap: () {},
                onDragStart: () {},
                onDragUpdate: updates.add,
                onDragEnd: () {},
                onDragCancel: () {},
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(const Offset(80, 60));
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    updates.clear();

    await gesture.moveBy(const Offset(30, 12));
    await tester.pump();

    expect(
      updates.fold<Offset>(Offset.zero, (sum, delta) => sum + delta),
      const Offset(30, 12),
    );
    await gesture.up();
  });
}
