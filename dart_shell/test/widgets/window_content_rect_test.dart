import 'package:denial_dart_shell/src/local_apps/local_flutter_application.dart';
import 'package:denial_dart_shell/src/local_apps/local_flutter_window_host.dart';
import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/models/denial_window.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:denial_dart_shell/src/widgets/window_content_rect.dart';
import 'package:denial_dart_shell/src/widgets/window_texture_rect.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('local windows mount their registered Flutter application', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localFlutterApplicationsProvider.overrideWithValue(const [
            _testApplication,
          ]),
        ],
        child: const DenialLocalizationScope(
          locale: Locale('en'),
          child: ShellTheme(
            data: ShellThemeData(),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: SizedBox(
                width: 360,
                height: 640,
                child: WindowContentRect(window: _localWindow, active: true),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(LocalFlutterWindowHost), findsOneWidget);
    expect(find.text('Built-in application content'), findsOneWidget);
    expect(find.byType(WindowTextureRect), findsNothing);
  });

  testWidgets('Wayland windows retain the compositor texture path', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ShellTheme(
        data: ShellThemeData(),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 360,
            height: 640,
            child: WindowContentRect(window: _waylandWindow),
          ),
        ),
      ),
    );

    expect(find.byType(WindowTextureRect), findsOneWidget);
    expect(find.byType(LocalFlutterWindowHost), findsNothing);
  });
}

Widget _buildTestApplication(
  BuildContext context,
  LocalFlutterWindowHandle window,
) {
  return const Center(child: Text('Built-in application content'));
}

const _testApplication = LocalFlutterApplication(
  id: 'dev.denial.test-local',
  title: 'Test local app',
  defaultSize: Size(360, 640),
  minimumSize: Size(320, 480),
  builder: _buildTestApplication,
);

const _localWindow = DenialWindow(
  objectId: 91,
  objectKind: 'local_flutter',
  surfaceId: 91,
  windowId: 91,
  textureId: 0,
  title: 'Test local app',
  appId: 'dev.denial.test-local',
  width: 360,
  height: 640,
  surfaceX: 0,
  surfaceY: 0,
  surfaceWidth: 360,
  surfaceHeight: 640,
  textureSourceX: 0,
  textureSourceY: 0,
  textureSourceWidth: 0,
  textureSourceHeight: 0,
  geometryX: 0,
  geometryY: 0,
  geometryWidth: 360,
  geometryHeight: 640,
  monitorId: 1,
  transform: 0,
  scale120: 120,
  serverSideDecorated: false,
  contentKind: DenialWindowContentKind.localFlutter,
);

const _waylandWindow = DenialWindow(
  objectId: 7,
  objectKind: 'root_surface',
  surfaceId: 7,
  windowId: 7,
  textureId: 70,
  title: 'Wayland app',
  appId: 'dev.denial.wayland',
  width: 360,
  height: 640,
  surfaceX: 0,
  surfaceY: 0,
  surfaceWidth: 360,
  surfaceHeight: 640,
  textureSourceX: 0,
  textureSourceY: 0,
  textureSourceWidth: 360,
  textureSourceHeight: 640,
  geometryX: 0,
  geometryY: 0,
  geometryWidth: 360,
  geometryHeight: 640,
  monitorId: 1,
  transform: 0,
  scale120: 120,
);
