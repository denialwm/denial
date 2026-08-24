import 'package:denial_dart_shell/src/config/startup_environment.dart';
import 'package:denial_dart_shell/src/settings/settings_application.dart';
import 'package:denial_dart_shell/src/settings/settings_standalone_app.dart';
import 'package:denial_dart_shell/src/state/shell_controller.dart';
import 'package:denial_dart_shell/src/wallpaper/widgets/wallpaper_selector_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('standalone Settings owns the socket-backed root scope', (
    tester,
  ) async {
    final environment = StartupEnvironment(<String, String>{
      'DENIAL_SETTINGS_TEST': 'root-scope',
    });

    await tester.pumpWidget(
      DenialSettingsStandaloneApp(
        startupEnvironment: environment,
        controlSocketPath: '/tmp/denial-settings-test-no-socket',
      ),
    );
    await tester.pump();

    final context = tester.element(find.byType(DenialSettingsApplication));
    final container = ProviderScope.containerOf(context, listen: false);
    expect(container.read(startupEnvironmentProvider), same(environment));
    expect(container.read(denialBridgeProvider).useControlSocket, isTrue);
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.color, Colors.transparent);
    expect(app.theme?.scaffoldBackgroundColor, Colors.transparent);
    expect(find.byType(WallpaperSelectorOverlay), findsNothing);
    final surface = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(DenialSettingsApplication),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(surface.color!.a, closeTo(0.74, 0.001));

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
