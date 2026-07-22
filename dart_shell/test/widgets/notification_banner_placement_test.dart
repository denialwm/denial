import 'package:denial_dart_shell/src/models/display_layout.dart';
import 'package:denial_dart_shell/src/models/shell_popup_placement.dart';
import 'package:denial_dart_shell/src/settings/settings_controller.dart';
import 'package:denial_dart_shell/src/settings/shell_settings.dart';
import 'package:denial_dart_shell/src/state/desktop_notifications.dart';
import 'package:denial_dart_shell/src/state/display_layout.dart';
import 'package:denial_dart_shell/src/state/shell_controller.dart';
import 'package:denial_dart_shell/src/state/shell_state.dart';
import 'package:denial_dart_shell/src/widgets/notification_banner.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('banner bounds follow the configured main-output placement', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(2000, 800);
    addTearDown(tester.view.reset);
    final container = ProviderContainer.test(
      overrides: [
        desktopNotificationsProvider.overrideWithBuild(
          (ref, controller) => const DesktopNotificationsState(),
        ),
        displayLayoutProvider.overrideWithBuild((ref, controller) => _layout),
        shellControllerProvider.overrideWithBuild(
          (ref, controller) => ShellState.initial(),
        ),
        shellSettingsProvider.overrideWithBuild(
          (ref, controller) => const ShellSettings(
            overlays: ShellOverlaySettings(
              notifications: ShellPopupPlacement(
                anchor: ShellPopupAnchor.topRight,
                width: 300,
                height: 240,
                margin: 20,
              ),
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MediaQuery(
          data: MediaQueryData(size: Size(2000, 800)),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[NotificationBannerLayer()],
            ),
          ),
        ),
      ),
    );

    final positioned = tester.widget<Positioned>(find.byType(Positioned));
    expect(positioned.left, 1680);
    expect(positioned.top, 20);
    expect(positioned.width, 300);
    expect(positioned.height, 240);
  });
}

const _layout = DisplayLayout(
  epoch: 1,
  globalOrigin: Offset.zero,
  logicalSize: Size(2000, 800),
  pixelSize: Size(2000, 800),
  engineScale: 1,
  tickerMonitorId: 22,
  systemBarMonitorId: 22,
  systemBarSide: SystemBarSide.left,
  outputs: <DisplayOutput>[
    DisplayOutput(
      monitorId: 11,
      name: 'secondary',
      logicalRect: Rect.fromLTWH(0, 0, 1200, 800),
      pixelSize: Size(1200, 800),
      scale: 1,
      refreshRate: 60,
    ),
    DisplayOutput(
      monitorId: 22,
      name: 'main',
      logicalRect: Rect.fromLTWH(1200, 0, 800, 800),
      pixelSize: Size(800, 800),
      scale: 1,
      refreshRate: 60,
    ),
  ],
);
