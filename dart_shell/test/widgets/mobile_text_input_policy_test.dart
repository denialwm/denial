import 'package:denial_dart_shell/src/widgets/mobile_text_input_policy.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('outside touchscreen tap unfocuses the mobile editor', (
    tester,
  ) async {
    final focusNode = FocusNode();
    final controller = TextEditingController();
    const outsideKey = Key('outside');
    addTearDown(focusNode.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MobileTextInputPolicy(
          child: TapRegionSurface(
            child: Column(
              children: [
                EditableText(
                  controller: controller,
                  focusNode: focusNode,
                  style: const TextStyle(),
                  cursorColor: const Color(0xFFFFFFFF),
                  backgroundCursorColor: const Color(0xFF000000),
                ),
                const Expanded(child: _OutsideTarget(key: outsideKey)),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(EditableText));
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);

    await tester.tap(find.byKey(outsideKey), kind: PointerDeviceKind.touch);
    await tester.pump();

    expect(focusNode.hasFocus, isFalse);
  });

  testWidgets('field-to-field touchscreen tap preserves text focus', (
    tester,
  ) async {
    final firstFocus = FocusNode();
    final secondFocus = FocusNode();
    final firstController = TextEditingController();
    final secondController = TextEditingController();
    addTearDown(firstFocus.dispose);
    addTearDown(secondFocus.dispose);
    addTearDown(firstController.dispose);
    addTearDown(secondController.dispose);

    Widget editor(TextEditingController controller, FocusNode focusNode) {
      return TextFieldTapRegion(
        child: EditableText(
          controller: controller,
          focusNode: focusNode,
          style: const TextStyle(),
          cursorColor: const Color(0xFFFFFFFF),
          backgroundCursorColor: const Color(0xFF000000),
        ),
      );
    }

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MobileTextInputPolicy(
          child: TapRegionSurface(
            child: Column(
              children: [
                editor(firstController, firstFocus),
                editor(secondController, secondFocus),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(EditableText).first);
    await tester.pump();
    await tester.tap(find.byType(EditableText).last);
    await tester.pump();

    expect(firstFocus.hasFocus, isFalse);
    expect(secondFocus.hasFocus, isTrue);
  });
}

class _OutsideTarget extends StatelessWidget {
  const _OutsideTarget({super.key});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: const SizedBox.expand(),
    );
  }
}
