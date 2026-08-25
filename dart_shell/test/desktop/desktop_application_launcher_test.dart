import 'package:denial_dart_shell/src/desktop/desktop_shell.dart';
import 'package:denial_dart_shell/src/launcher/controllers/home_grid_controller.dart';
import 'package:denial_dart_shell/src/local_apps/local_flutter_application.dart';
import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/settings/settings_application.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Applications includes and launches registered local apps', (
    tester,
  ) async {
    final harness = await _pumpLauncher(
      tester,
      applications: <LocalFlutterApplication>[denialSettingsApplication],
    );

    expect(find.text('Applications'), findsOneWidget);
    expect(find.text('Installed applications: 1'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey<String>('desktop-app-local:dev.denial.settings'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Settings'));
    expect(harness.launched, <LocalFlutterApplication>[
      denialSettingsApplication,
    ]);
  });

  testWidgets('arrow keys select a search result and Enter launches it', (
    tester,
  ) async {
    final apps = _testApplications(2);
    final harness = await _pumpLauncher(tester, applications: apps);

    await tester.enterText(find.byType(EditableText), 'App');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(harness.launched, <LocalFlutterApplication>[apps[1]]);
  });

  testWidgets('arrow keys select without a query and Enter launches', (
    tester,
  ) async {
    final apps = _testApplications(2);
    final harness = await _pumpLauncher(tester, applications: apps);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(harness.launched, <LocalFlutterApplication>[apps[1]]);
  });

  testWidgets('Tab and Shift-Tab cycle the result selection', (tester) async {
    final apps = _testApplications(3);
    final harness = await _pumpLauncher(tester, applications: apps);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(harness.launched, <LocalFlutterApplication>[apps[1]]);
  });

  testWidgets('Escape uses immediate dismissal and preserves search text', (
    tester,
  ) async {
    final harness = await _pumpLauncher(
      tester,
      applications: _testApplications(1),
    );

    await tester.enterText(find.byType(EditableText), 'search');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(harness.dismissCount, 1);
    expect(harness.exitCount, 0);
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.controller.text, 'search');
  });

  testWidgets('control characters committed by an input method are filtered', (
    tester,
  ) async {
    await _pumpLauncher(tester, applications: _testApplications(1));
    await tester.showKeyboard(find.byType(EditableText));

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'a\u001bb\u0009c',
        selection: TextSelection.collapsed(offset: 5),
      ),
    );
    await tester.pump();

    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.controller.text, 'abc');
  });

  testWidgets('horizontal arrows follow reading order across grid rows', (
    tester,
  ) async {
    final apps = _testApplications(5);
    final harness = await _pumpLauncher(tester, applications: apps, width: 300);

    // The 260 px-wide content grid has three columns. Right crosses from the
    // last item of the first row to the first item of the second row.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(harness.launched, <LocalFlutterApplication>[apps[3]]);

    // Left crosses back to the final item of the previous row, one result at
    // a time, rather than jumping to the first result.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(harness.launched, <LocalFlutterApplication>[apps[3], apps[2]]);
  });

  testWidgets('caret movement does not reset a filtered grid selection', (
    tester,
  ) async {
    final apps = _testApplications(12);
    final harness = await _pumpLauncher(tester, applications: apps, width: 300);

    // This query filters out applications 10-12 while leaving enough results
    // to cross a row boundary. Arrow Left also moves the text caret, which
    // must not be mistaken for a query change.
    await tester.enterText(find.byType(EditableText), 'App 0');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'App 0',
        selection: TextSelection.collapsed(offset: 4),
      ),
    );
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(harness.launched, <LocalFlutterApplication>[apps[2]]);
  });

  testWidgets('vertical arrows preserve the column on an incomplete row', (
    tester,
  ) async {
    final apps = _testApplications(5);
    final harness = await _pumpLauncher(tester, applications: apps, width: 300);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(harness.launched, <LocalFlutterApplication>[apps.last]);
  });

  testWidgets('focus changes do not reset the selected result', (tester) async {
    final apps = _testApplications(2);
    final harness = await _pumpLauncher(tester, applications: apps);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    harness.searchFocusNode.unfocus();
    await tester.pump();
    harness.searchFocusNode.requestFocus();
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(harness.launched, <LocalFlutterApplication>[apps.last]);
  });

  testWidgets('keyboard selection automatically scrolls into view', (
    tester,
  ) async {
    final apps = _testApplications(12);
    final harness = await _pumpLauncher(
      tester,
      applications: apps,
      width: 300,
      height: 300,
    );

    for (var index = 0; index < 8; index += 1) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
    }

    final grid = tester.widget<GridView>(find.byType(GridView));
    expect(grid.controller!.offset, greaterThan(0));
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(harness.launched, <LocalFlutterApplication>[apps[8]]);
  });
}

List<LocalFlutterApplication> _testApplications(int count) {
  return List<LocalFlutterApplication>.generate(
    count,
    (index) => LocalFlutterApplication(
      id: 'test.app.${index + 1}',
      title: 'App ${(index + 1).toString().padLeft(2, '0')}',
      builder: _placeholderBuilder,
    ),
    growable: false,
  );
}

Future<_LauncherTestHarness> _pumpLauncher(
  WidgetTester tester, {
  required List<LocalFlutterApplication> applications,
  double width = 680,
  double height = 620,
}) async {
  final harness = _LauncherTestHarness(FocusNode());
  addTearDown(harness.searchFocusNode.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        homeGridControllerProvider.overrideWith(_EmptyHomeGridController.new),
        localFlutterApplicationsProvider.overrideWithValue(applications),
      ],
      child: DenialLocalizationScope(
        locale: const Locale('en'),
        child: MediaQuery(
          data: MediaQueryData(size: Size(width, height)),
          child: Center(
            child: SizedBox(
              width: width,
              height: height,
              child: DesktopApplicationLauncher(
                searchFocusNode: harness.searchFocusNode,
                onEnter: () {},
                onExit: () => harness.exitCount += 1,
                onDismiss: () => harness.dismissCount += 1,
                onLaunch: (_) => fail('launched an external application'),
                onLaunchLocal: harness.launched.add,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return harness;
}

class _LauncherTestHarness {
  _LauncherTestHarness(this.searchFocusNode);

  final FocusNode searchFocusNode;
  final List<LocalFlutterApplication> launched = <LocalFlutterApplication>[];
  int dismissCount = 0;
  int exitCount = 0;
}

class _EmptyHomeGridController extends HomeGridController {
  @override
  Future<HomeGridState> build() async {
    return HomeGridState(slots: const []);
  }
}

Widget _placeholderBuilder(
  BuildContext context,
  LocalFlutterWindowHandle handle,
) => const SizedBox.shrink();
