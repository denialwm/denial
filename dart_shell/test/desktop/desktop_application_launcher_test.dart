import 'package:denial_dart_shell/src/desktop/desktop_shell.dart';
import 'package:denial_dart_shell/src/launcher/controllers/home_grid_controller.dart';
import 'package:denial_dart_shell/src/local_apps/local_flutter_application.dart';
import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/settings/settings_application.dart';
import 'package:flutter/material.dart';
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
}

class _EmptyHomeGridController extends HomeGridController {
  @override
  Future<HomeGridState> build() async {
    return HomeGridState(slots: const []);
  }
}
