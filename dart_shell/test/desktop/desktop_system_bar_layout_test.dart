import 'package:denial_dart_shell/src/desktop/desktop_system_bar.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('horizontal workspace indicator does not fill the bar width', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 800,
            height: 48,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                Center(
                  child: DesktopSystemBarIndicatorSlot(
                    horizontal: true,
                    child: _ExpandingIndicatorCard(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byKey(_cardKey)), const Size(180, 48));
  });

  testWidgets('vertical workspace indicator does not fill the bar height', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 48,
            height: 600,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                Center(
                  child: DesktopSystemBarIndicatorSlot(
                    horizontal: false,
                    child: _ExpandingIndicatorCard(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byKey(_cardKey)), const Size(48, 28));
  });
}

const _cardKey = ValueKey<String>('workspace-indicator-card');

class _ExpandingIndicatorCard extends StatelessWidget {
  const _ExpandingIndicatorCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: _cardKey,
      alignment: Alignment.center,
      child: const SizedBox(width: 180, height: 28),
    );
  }
}
