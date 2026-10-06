import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/models/input_device_capabilities.dart';
import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_controls.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_touchpad_page.dart';
import 'package:denial_dart_shell/src/state/shell_controller.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('scrolling layout swipe speed is independent and applied', (
    tester,
  ) async {
    final bridge = _TouchpadBridge();
    addTearDown(bridge.dispose);
    await tester.pumpWidget(_harness(bridge));
    await tester.pumpAndSettle();

    final slider = tester.widget<SettingsSlider>(
      find.byKey(settingsScrollingLayoutSwipeSpeedSliderKey),
    );
    expect(slider.label, 'Scrolling layout swipe speed');
    expect(slider.value, 1.75);
    expect(slider.minimum, touchpadScrollingLayoutSwipeSpeedFactorMinimum);
    expect(slider.maximum, touchpadScrollingLayoutSwipeSpeedFactorMaximum);
    expect(slider.enabled, isTrue);

    slider.onChangeStart?.call(2.25);
    slider.onChanged(2.25);
    slider.onChangeEnd?.call(2.25);
    await tester.pumpAndSettle();

    expect(bridge.requested, isNotNull);
    expect(bridge.requested!.scrollSpeedFactor, 1.5);
    expect(bridge.requested!.scrollingLayoutSwipeSpeedFactor, 2.25);
  });
}

Widget _harness(DenialBridge bridge) {
  return ProviderScope(
    overrides: [denialBridgeProvider.overrideWithValue(bridge)],
    child: MaterialApp(
      home: DenialLocalizationScope(
        locale: const Locale('en'),
        child: ShellTheme(
          data: const ShellThemeData(),
          child: const Material(child: SettingsTouchpadPage()),
        ),
      ),
    ),
  );
}

class _TouchpadBridge extends DenialBridge {
  DenialInputDeviceCapabilities current = const DenialInputDeviceCapabilities(
    revision: 7,
    hasMouse: true,
    mouseSpeed: 0,
    hasTouchpad: true,
    tapToClickEnabled: true,
    naturalScrollEnabled: false,
    scrollSpeedFactor: 1.5,
    scrollingLayoutSwipeSpeedFactor: 1.75,
  );
  DenialInputDeviceCapabilities? requested;

  @override
  Future<DenialInputDeviceCapabilities> readInputDeviceCapabilities() async =>
      current;

  @override
  Future<DenialInputDeviceCapabilities> configureTouchpad(
    DenialInputDeviceCapabilities capabilities,
  ) async {
    requested = capabilities;
    current = capabilities.copyWith(revision: capabilities.revision + 1);
    return current;
  }
}
