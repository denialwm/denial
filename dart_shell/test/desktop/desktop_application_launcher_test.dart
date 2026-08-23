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
    final searchFocusNode = FocusNode();
    addTearDown(searchFocusNode.dispose);
    LocalFlutterApplication? launchedApplication;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeGridControllerProvider.overrideWith(_EmptyHomeGridController.new),
          localFlutterApplicationsProvider.overrideWithValue(
            <LocalFlutterApplication>[denialSettingsApplication],
          ),
        ],
        child: DenialLocalizationScope(
          locale: const Locale('en'),
          child: MediaQuery(
            data: const MediaQueryData(size: Size(680, 620)),
            child: SizedBox(
              width: 680,
              height: 620,
              child: DesktopApplicationLauncher(
                searchFocusNode: searchFocusNode,
                onEnter: () {},
                onExit: () {},
                onLaunch: (_) => fail('launched an external application'),
                onLaunchLocal: (app) => launchedApplication = app,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Applications'), findsOneWidget);
    expect(find.text('Installed applications: 1'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('desktop-app-dev.denial.settings')),
      findsOneWidget,
    );

    await tester.tap(find.text('Settings'));
    expect(launchedApplication, same(denialSettingsApplication));
  });

  testWidgets('arrow keys select a search result and Enter launches it', (
    tester,
  ) async {
    final searchFocusNode = FocusNode();
    addTearDown(searchFocusNode.dispose);
    final launched = <LocalFlutterApplication>[];

    final first = LocalFlutterApplication(
      id: 'test.app.alpha',
      title: 'Alpha Search App',
      builder: _placeholderBuilder,
    );
    final second = LocalFlutterApplication(
      id: 'test.app.beta',
      title: 'Beta Search App',
      builder: _placeholderBuilder,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeGridControllerProvider.overrideWith(_EmptyHomeGridController.new),
          localFlutterApplicationsProvider.overrideWithValue([first, second]),
        ],
        child: DenialLocalizationScope(
          locale: const Locale('en'),
          child: MediaQuery(
            data: const MediaQueryData(size: Size(680, 620)),
            child: SizedBox(
              width: 680,
              height: 620,
              child: DesktopApplicationLauncher(
                searchFocusNode: searchFocusNode,
                onEnter: () {},
                onExit: () {},
                onLaunch: (_) => fail('launched an external application'),
                onLaunchLocal: launched.add,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(EditableText), 'search');
    await tester.pumpAndSettle();

    // First result is selected by default; ArrowRight moves to the second.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(launched, [second]);
  });

  testWidgets('arrow keys select an app without searching and Enter launches it', (
    tester,
  ) async {
    final searchFocusNode = FocusNode();
    addTearDown(searchFocusNode.dispose);
    final launched = <LocalFlutterApplication>[];

    final first = LocalFlutterApplication(
      id: 'test.app.alpha',
      title: 'Alpha Search App',
      builder: _placeholderBuilder,
    );
    final second = LocalFlutterApplication(
      id: 'test.app.beta',
      title: 'Beta Search App',
      builder: _placeholderBuilder,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeGridControllerProvider.overrideWith(_EmptyHomeGridController.new),
          localFlutterApplicationsProvider.overrideWithValue([first, second]),
        ],
        child: DenialLocalizationScope(
          locale: const Locale('en'),
          child: MediaQuery(
            data: const MediaQueryData(size: Size(680, 620)),
            child: SizedBox(
              width: 680,
              height: 620,
              child: DesktopApplicationLauncher(
                searchFocusNode: searchFocusNode,
                onEnter: () {},
                onExit: () {},
                onLaunch: (_) => fail('launched an external application'),
                onLaunchLocal: launched.add,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // First app is selected by default; ArrowRight moves to the second.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(launched, [second]);
  });

  testWidgets('tab moves the selection to the next app', (tester) async {
    final searchFocusNode = FocusNode();
    addTearDown(searchFocusNode.dispose);
    final launched = <LocalFlutterApplication>[];

    final first = LocalFlutterApplication(
      id: 'test.app.alpha',
      title: 'Alpha Search App',
      builder: _placeholderBuilder,
    );
    final second = LocalFlutterApplication(
      id: 'test.app.beta',
      title: 'Beta Search App',
      builder: _placeholderBuilder,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeGridControllerProvider.overrideWith(_EmptyHomeGridController.new),
          localFlutterApplicationsProvider.overrideWithValue([first, second]),
        ],
        child: DenialLocalizationScope(
          locale: const Locale('en'),
          child: MediaQuery(
            data: const MediaQueryData(size: Size(680, 620)),
            child: SizedBox(
              width: 680,
              height: 620,
              child: DesktopApplicationLauncher(
                searchFocusNode: searchFocusNode,
                onEnter: () {},
                onExit: () {},
                onLaunch: (_) => fail('launched an external application'),
                onLaunchLocal: launched.add,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Tab must move the grid selection, not trigger focus traversal.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(launched, [second]);
  });

  testWidgets('escape dismisses the launcher without polluting the search text', (
    tester,
  ) async {
    final searchFocusNode = FocusNode();
    addTearDown(searchFocusNode.dispose);
    var exitCount = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeGridControllerProvider.overrideWith(_EmptyHomeGridController.new),
          localFlutterApplicationsProvider.overrideWithValue(
            <LocalFlutterApplication>[
              LocalFlutterApplication(
                id: 'test.app.alpha',
                title: 'Alpha App',
                builder: _placeholderBuilder,
              ),
            ],
          ),
        ],
        child: DenialLocalizationScope(
          locale: const Locale('en'),
          child: MediaQuery(
            data: const MediaQueryData(size: Size(680, 620)),
            child: SizedBox(
              width: 680,
              height: 620,
              child: DesktopApplicationLauncher(
                searchFocusNode: searchFocusNode,
                onEnter: () {},
                onExit: () => exitCount++,
                onLaunch: (_) => fail('launched an external application'),
                onLaunchLocal: (_) => fail('launched a local application'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(EditableText), 'search');
    await tester.pumpAndSettle();

    // ESC via the key event channel must dismiss the launcher and must not
    // insert any text into the search box.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(exitCount, 1);
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.controller.text, 'search');
  });

  testWidgets('control characters submitted by an input method are filtered', (
    tester,
  ) async {
    final searchFocusNode = FocusNode();
    addTearDown(searchFocusNode.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeGridControllerProvider.overrideWith(_EmptyHomeGridController.new),
          localFlutterApplicationsProvider.overrideWithValue(
            <LocalFlutterApplication>[
              LocalFlutterApplication(
                id: 'test.app.alpha',
                title: 'Alpha App',
                builder: _placeholderBuilder,
              ),
            ],
          ),
        ],
        child: DenialLocalizationScope(
          locale: const Locale('en'),
          child: MediaQuery(
            data: const MediaQueryData(size: Size(680, 620)),
            child: SizedBox(
              width: 680,
              height: 620,
              child: DesktopApplicationLauncher(
                searchFocusNode: searchFocusNode,
                onEnter: () {},
                onExit: () {},
                onLaunch: (_) => fail('launched an external application'),
                onLaunchLocal: (_) => fail('launched a local application'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.showKeyboard(find.byType(EditableText));

    // Simulate an IME committing ESC (0x1B) and TAB (0x09) as text: the
    // formatter must strip them so they never reach the search box.
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
) =>
    const SizedBox.shrink();
