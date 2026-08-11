import 'package:denial_dart_shell/src/launcher/controllers/home_grid_layout.dart';
import 'package:denial_dart_shell/src/launcher/controllers/home_grid_controller.dart';
import 'package:denial_dart_shell/src/launcher/home_surface.dart';
import 'package:denial_dart_shell/src/launcher/models/home_grid_item.dart';
import 'package:denial_dart_shell/src/launcher/widgets/home_tiles.dart';
import 'package:denial_dart_shell/src/local_apps/local_flutter_application.dart';
import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/models/display_layout.dart';
import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:denial_dart_shell/src/settings/settings_application.dart';
import 'package:denial_dart_shell/src/state/display_layout.dart';
import 'package:denial_dart_shell/src/state/shell_controller.dart';
import 'package:denial_dart_shell/src/state/shell_state.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('built-in applications are included in the persisted home grid', () {
    final slots = HomeGridLayout.initialSlotsForApps(const [], [
      denialSettingsApplication,
    ], const []);

    final settings = slots.whereType<HomeGridItem>().singleWhere(
      (item) => item.id == 'local:dev.denial.settings',
    );
    expect(settings.localApp, same(denialSettingsApplication));
    expect(settings.app, isNull);
  });

  test('desktop application refreshes preserve built-in applications', () {
    final initial = HomeGridLayout.initialSlotsForApps(const [], [
      denialSettingsApplication,
    ], null);
    final refreshed = HomeGridLayout.refreshSlotsForApps(initial, const [], [
      denialSettingsApplication,
    ]);

    expect(
      refreshed.whereType<HomeGridItem>().where(
        (item) => item.localApp == denialSettingsApplication,
      ),
      hasLength(1),
    );
  });

  testWidgets('the home tile presents and activates built-in Settings', (
    tester,
  ) async {
    final item = HomeGridItem.localApp(denialSettingsApplication);
    HomeGridItem? launched;

    await tester.pumpWidget(
      ProviderScope(
        child: DenialLocalizationScope(
          locale: const Locale('en'),
          child: SizedBox(
            width: 180,
            height: 150,
            child: HomeGridItemCard(
              item: item,
              onLaunch: (value) => launched = value,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Settings'), findsOneWidget);
    expect(find.byIcon(Icons.settings_rounded), findsOneWidget);
    await tester.tap(find.text('Settings'));
    expect(launched, same(item));
  });

  testWidgets('mobile home launches Settings through the shell transaction', (
    tester,
  ) async {
    final bridge = _RecordingBridge();
    final shellController = _RecordingShellController();
    addTearDown(bridge.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          denialBridgeProvider.overrideWithValue(bridge),
          shellControllerProvider.overrideWith(() => shellController),
          displayLayoutProvider.overrideWith(_EmptyDisplayLayout.new),
          homeGridControllerProvider.overrideWith(_SettingsHomeGrid.new),
          localFlutterApplicationsProvider.overrideWithValue(
            <LocalFlutterApplication>[denialSettingsApplication],
          ),
        ],
        child: const DenialLocalizationScope(
          locale: Locale('en'),
          child: ShellTheme(
            data: ShellThemeData(),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: MediaQuery(
                data: MediaQueryData(size: Size(420, 840)),
                child: SizedBox(
                  width: 420,
                  height: 840,
                  child: HomeSurface(useShellLaunchTransition: true),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('Settings'));
    await tester.pump();

    expect(shellController.appName, 'Settings');
    expect(shellController.expectedAppIds, <String>['dev.denial.settings']);
    expect(bridge.appId, 'dev.denial.settings');
    expect(bridge.title, 'Settings');
    expect(bridge.geometry, isNotNull);
    expect(shellController.failedRequestIds, isEmpty);
  });
}

class _SettingsHomeGrid extends HomeGridController {
  @override
  Future<HomeGridState> build() async {
    return HomeGridState(
      slots: <HomeGridItem?>[HomeGridItem.localApp(denialSettingsApplication)],
    );
  }
}

class _EmptyDisplayLayout extends DisplayLayoutController {
  @override
  DisplayLayout? build() => null;
}

class _RecordingShellController extends ShellController {
  String? appName;
  List<String>? expectedAppIds;
  final List<int> failedRequestIds = <int>[];

  @override
  ShellState build() => ShellState.initial();

  @override
  int? beginAppLaunch({
    required String appName,
    required String? iconPath,
    required Iterable<String> expectedAppIds,
  }) {
    this.appName = appName;
    this.expectedAppIds = expectedAppIds.toList(growable: false);
    return 73;
  }

  @override
  void failAppLaunch(int requestId) {
    failedRequestIds.add(requestId);
  }
}

class _RecordingBridge extends DenialBridge {
  String? appId;
  String? title;
  Rect? geometry;

  @override
  bool createLocalWindow({
    required String appId,
    required String title,
    required Rect geometry,
  }) {
    this.appId = appId;
    this.title = title;
    this.geometry = geometry;
    return true;
  }
}
