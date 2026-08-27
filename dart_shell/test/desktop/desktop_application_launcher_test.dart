import 'dart:ui' show PointerDeviceKind;

import 'package:denial_dart_shell/src/desktop/desktop_shell.dart';
import 'package:denial_dart_shell/src/launcher/controllers/application_recents_controller.dart';
import 'package:denial_dart_shell/src/launcher/controllers/home_grid_controller.dart';
import 'package:denial_dart_shell/src/launcher/repositories/application_recents_repository.dart';
import 'package:denial_dart_shell/src/local_apps/local_flutter_application.dart';
import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/settings/settings_application.dart';
import 'package:denial_dart_shell/src/theme/shell_color_scheme.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('HomeGridState preserves its slot cache across page-only changes', () {
    final state = HomeGridState(slots: const []);

    final changed = state.copyWith(page: 1);

    expect(identical(changed.slots, state.slots), isTrue);
  });

  testWidgets('light theme resolves launcher app names', (tester) async {
    await _pumpLauncher(
      tester,
      applications: _testApplications(2),
      colors: ShellColorScheme.light,
    );

    final selectedApp = tester.widget<Text>(find.text('App 01'));
    final unselectedApp = tester.widget<Text>(find.text('App 02'));
    final accent = ShellAccentPalette.from(
      const ShellThemeData().accentSeed,
      ShellColorScheme.light,
    );

    expect(selectedApp.style?.color, accent.onContainer);
    expect(unselectedApp.style?.color, ShellColorScheme.light.textPrimary);
  });

  testWidgets('app hover transitions directly through the accent hue', (
    tester,
  ) async {
    await _pumpLauncher(tester, applications: _testApplications(2));

    final tile = find.byKey(
      const ValueKey<String>('desktop-app-local:test.app.2'),
    );
    final animatedTile = find.descendant(
      of: tile,
      matching: find.byType(AnimatedContainer),
    );
    final accent = const ShellThemeData().accentPalette;

    BoxDecoration decoration() =>
        tester.widget<AnimatedContainer>(animatedTile).decoration!
            as BoxDecoration;

    expect(decoration().color, accent.container.withValues(alpha: 0));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(
      location: tester.getTopLeft(tile) - const Offset(8, 8),
    );
    await mouse.moveTo(tester.getCenter(tile));
    await tester.pump();

    expect(decoration().color, accent.container);
    final label = tester.widget<Text>(find.text('App 02'));
    expect(label.style?.color, accent.onContainer);
  });

  testWidgets('recents use one row while the full catalog stays searchable', (
    tester,
  ) async {
    final apps = _testApplications(6);
    final harness = await _pumpLauncher(
      tester,
      applications: apps,
      width: 300,
      recentEntries: <String>[
        localApplicationRecentId(apps[5].id),
        localApplicationRecentId(apps[4].id),
        localApplicationRecentId(apps[3].id),
        localApplicationRecentId(apps[2].id),
      ],
    );

    expect(find.byKey(desktopApplicationSuggestionsRowKey), findsOneWidget);
    expect(find.byKey(desktopApplicationSuggestionsDividerKey), findsOneWidget);
    expect(find.text('SUGGESTED'), findsNothing);
    expect(
      tester.getSize(find.byKey(desktopApplicationSuggestionsRowKey)).height,
      96,
    );
    for (final app in apps.reversed.take(3)) {
      expect(
        find.byKey(
          ValueKey<String>(
            'desktop-suggested-app-${localApplicationRecentId(app.id)}',
          ),
        ),
        findsOneWidget,
      );
    }
    expect(
      find.byKey(
        ValueKey<String>(
          'desktop-suggested-app-${localApplicationRecentId(apps[2].id)}',
        ),
      ),
      findsNothing,
      reason: 'suggestions must never overflow into a second row',
    );
    final firstSuggested = find.byKey(
      const ValueKey<String>('desktop-suggested-app-local:test.app.6'),
    );
    final firstSuggestedName = tester.widget<Text>(
      find.descendant(of: firstSuggested, matching: find.text('App 06')),
    );
    final firstSuggestedDecoration =
        tester
                .widget<AnimatedContainer>(
                  find.descendant(
                    of: firstSuggested,
                    matching: find.byType(AnimatedContainer),
                  ),
                )
                .decoration!
            as BoxDecoration;
    expect(firstSuggestedName.maxLines, 1);
    expect(
      firstSuggestedDecoration.border,
      isNotNull,
      reason: 'the first recent app must own the initial keyboard selection',
    );
    for (final app in apps) {
      expect(
        find.byKey(
          ValueKey<String>('desktop-app-${localApplicationRecentId(app.id)}'),
        ),
        findsOneWidget,
        reason: 'the full catalog must still include suggested apps',
      );
    }
    expect(
      tester
          .getTopLeft(
            find.byKey(
              const ValueKey<String>('desktop-suggested-app-local:test.app.6'),
            ),
          )
          .dy,
      lessThan(
        tester
            .getTopLeft(
              find.byKey(
                const ValueKey<String>('desktop-app-local:test.app.1'),
              ),
            )
            .dy,
      ),
    );
    expect(
      tester
          .getTopLeft(
            find.byKey(const ValueKey<String>('desktop-app-local:test.app.1')),
          )
          .dx,
      lessThan(
        tester
            .getTopLeft(
              find.byKey(
                const ValueKey<String>('desktop-app-local:test.app.2'),
              ),
            )
            .dx,
      ),
      reason: 'recency must not reorder the complete application catalog',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(harness.launched, <LocalFlutterApplication>[apps[0]]);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(harness.launched, <LocalFlutterApplication>[apps[0], apps[4]]);

    await tester.enterText(find.byType(EditableText), 'App 06');
    await tester.pump();

    expect(find.byKey(desktopApplicationSuggestionsRowKey), findsNothing);
    expect(find.byKey(desktopApplicationSuggestionsDividerKey), findsNothing);
    expect(
      find.byKey(
        const ValueKey<String>('desktop-suggested-app-local:test.app.6'),
      ),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('desktop-app-local:test.app.6')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('desktop-app-local:test.app.6')),
        matching: find.text('App 06'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('launcher remains layout-safe at its 200px minimum height', (
    tester,
  ) async {
    final apps = _testApplications(6);
    await _pumpLauncher(
      tester,
      applications: apps,
      height: 200,
      recentEntries: <String>[
        localApplicationRecentId(apps[2].id),
        localApplicationRecentId(apps[1].id),
        localApplicationRecentId(apps[0].id),
      ],
    );

    expect(find.byKey(desktopApplicationSuggestionsRowKey), findsOneWidget);
    expect(tester.takeException(), isNull);

    final suggestionsTop = tester
        .getTopLeft(find.byKey(desktopApplicationSuggestionsRowKey))
        .dy;
    final scrollView = find.byType(CustomScrollView);
    await tester.drag(scrollView, const Offset(0, -80));
    await tester.pumpAndSettle();

    expect(
      tester.widget<CustomScrollView>(scrollView).controller!.offset,
      greaterThan(0),
    );
    expect(
      tester.getTopLeft(find.byKey(desktopApplicationSuggestionsRowKey)).dy,
      lessThan(suggestionsTop),
      reason: 'the recent row must scroll with the complete application grid',
    );
  });

  testWidgets('Applications includes and launches registered local apps', (
    tester,
  ) async {
    final harness = await _pumpLauncher(
      tester,
      applications: <LocalFlutterApplication>[denialSettingsApplication],
    );

    expect(find.text('Applications'), findsNothing);
    expect(find.text('Installed applications: 1'), findsNothing);
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
    final scrollView = tester.widget<CustomScrollView>(
      find.byType(CustomScrollView),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      identical(
        tester.widget<CustomScrollView>(find.byType(CustomScrollView)),
        scrollView,
      ),
      isTrue,
      reason: 'keyboard selection must update only the old and new tiles',
    );
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
    final scrollView = tester.widget<CustomScrollView>(
      find.byType(CustomScrollView),
    );
    harness.searchFocusNode.unfocus();
    await tester.pump();
    expect(
      identical(
        tester.widget<CustomScrollView>(find.byType(CustomScrollView)),
        scrollView,
      ),
      isTrue,
      reason: 'focus changes must rebuild only the search border',
    );
    harness.searchFocusNode.requestFocus();
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(harness.launched, <LocalFlutterApplication>[apps.last]);
  });

  testWidgets('unrelated launcher rebuilds reuse the installed app catalog', (
    tester,
  ) async {
    var localizedTitleReads = 0;
    final app = LocalFlutterApplication(
      id: 'test.cached-app',
      title: 'Cached app',
      localizedTitle: (_) {
        localizedTitleReads += 1;
        return 'Cached app';
      },
      builder: _placeholderBuilder,
    );
    final harness = await _pumpLauncher(tester, applications: [app]);
    expect(localizedTitleReads, 1);

    harness.searchFocusNode.unfocus();
    await tester.pump();
    harness.searchFocusNode.requestFocus();
    await tester.pump();

    expect(localizedTitleReads, 1);
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

    final scrollView = tester.widget<CustomScrollView>(
      find.byType(CustomScrollView),
    );
    expect(scrollView.controller!.offset, greaterThan(0));
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
  ShellColorScheme colors = ShellColorScheme.dark,
  List<String> recentEntries = const <String>[],
}) async {
  final harness = _LauncherTestHarness(FocusNode());
  final recentsStore = _MemoryApplicationRecentsStore(recentEntries);
  addTearDown(harness.searchFocusNode.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        applicationRecentsStoreProvider.overrideWithValue(recentsStore),
        homeGridControllerProvider.overrideWith(_EmptyHomeGridController.new),
        localFlutterApplicationsProvider.overrideWithValue(applications),
      ],
      child: ShellTheme(
        data: ShellThemeData(colors: colors),
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

class _MemoryApplicationRecentsStore implements ApplicationRecentsStore {
  _MemoryApplicationRecentsStore(List<String> entries)
    : entries = List<String>.unmodifiable(entries);

  List<String> entries;

  @override
  Future<List<String>> readEntries() async => entries;

  @override
  Future<void> saveEntries(List<String> entries) async {
    this.entries = List<String>.unmodifiable(entries);
  }
}
