import 'package:denial_dart_shell/src/settings/widgets/focused_border_color_picker.dart';
import 'package:denial_dart_shell/src/settings/widgets/hsv_color_wheel.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_appearance_page.dart';
import 'package:denial_dart_shell/src/settings/widgets/system_bar_placement_card.dart';
import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/models/display_layout.dart';
import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:denial_dart_shell/src/settings/settings_application.dart';
import 'package:denial_dart_shell/src/state/display_layout.dart';
import 'package:denial_dart_shell/src/state/shell_appearance.dart';
import 'package:denial_dart_shell/src/state/shell_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('settings application presents the live appearance control', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final container = _settingsContainer();

    await _pumpSettings(tester, container);

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Make the desktop feel like yours.'), findsOneWidget);
    expect(find.text('Focused window border'), findsOneWidget);
    expect(find.text('Desktop system bar'), findsOneWidget);
    expect(find.byKey(settingsSystemBarPlacementCardKey), findsOneWidget);
    expect(find.text('#4F378B'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Denial Settings')), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('color wheel changes and resets the focused border live', (
    tester,
  ) async {
    final container = _settingsContainer();
    await _pumpSettings(tester, container);
    final initial = container.read(shellAppearanceProvider);

    await tester.ensureVisible(
      find.byKey(settingsFocusedBorderColorTriggerKey),
    );
    await tester.tap(find.byKey(settingsFocusedBorderColorTriggerKey));
    await tester.pumpAndSettle();

    expect(find.byKey(settingsFocusedBorderColorPickerKey), findsOneWidget);
    expect(find.byType(HsvColorWheel), findsOneWidget);

    final wheelRect = tester.getRect(find.byType(HsvColorWheel));
    await tester.tapAt(wheelRect.center + Offset(wheelRect.width * 0.36, 0));
    await tester.pump();

    final pointerColor = container
        .read(shellAppearanceProvider)
        .focusedWindowBorderColor;
    expect(pointerColor, isNot(initial.focusedWindowBorderColor));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      container.read(shellAppearanceProvider).focusedWindowBorderColor,
      isNot(pointerColor),
    );

    await tester.tap(find.byKey(settingsFocusedBorderResetKey));
    await tester.pump();
    expect(
      container.read(shellAppearanceProvider).focusedWindowBorderColor,
      initial.focusedWindowBorderColor,
    );

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.byKey(settingsFocusedBorderColorPickerKey), findsNothing);
  });

  testWidgets('appearance page and picker fit the minimum application size', (
    tester,
  ) async {
    final container = _settingsContainer();
    await _pumpSettings(tester, container, size: const Size(480, 360));

    await tester.ensureVisible(
      find.byKey(settingsFocusedBorderColorTriggerKey),
    );
    await tester.tap(find.byKey(settingsFocusedBorderColorTriggerKey));
    await tester.pumpAndSettle();

    expect(find.byType(HsvColorWheel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('system bar edge and monitor clones update live', (tester) async {
    final container = _settingsContainer();
    await _pumpSettings(tester, container);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Bottom'));
    await tester.tap(find.text('Bottom'));
    await tester.pump();
    expect(
      container.read(displayLayoutProvider)?.systemBarSide,
      SystemBarSide.bottom,
    );

    final secondDisplay = find.byKey(
      const ValueKey<String>('settings-system-bar-display-2'),
    );
    await tester.ensureVisible(secondDisplay);
    await tester.tap(secondDisplay);
    await tester.pump();
    expect(
      container
          .read(displayLayoutProvider)
          ?.effectiveSystemBarMonitorIds
          .toSet(),
      <int>{1, 2},
    );

    final firstDisplay = find.byKey(
      const ValueKey<String>('settings-system-bar-display-1'),
    );
    await tester.tap(firstDisplay);
    await tester.pump();
    expect(
      container.read(displayLayoutProvider)?.effectiveSystemBarMonitorIds,
      <int>[2],
    );

    // The remaining selected display is intentionally not removable.
    await tester.tap(secondDisplay);
    await tester.pump();
    expect(
      container.read(displayLayoutProvider)?.effectiveSystemBarMonitorIds,
      <int>[2],
    );
  });
}

ProviderContainer _settingsContainer() {
  return ProviderContainer.test(
    overrides: [
      denialBridgeProvider.overrideWith((ref) {
        final bridge = _SettingsBridge(_displayLayout);
        ref.onDispose(bridge.dispose);
        return bridge;
      }),
    ],
  );
}

Future<void> _pumpSettings(
  WidgetTester tester,
  ProviderContainer container, {
  Size size = const Size(760, 540),
}) {
  return tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: DenialLocalizationScope(
        locale: const Locale('en'),
        child: MediaQuery(
          data: MediaQueryData(size: size),
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: const DenialSettingsApplication(),
          ),
        ),
      ),
    ),
  );
}

class _SettingsBridge extends DenialBridge {
  _SettingsBridge(this.layout);

  DisplayLayout layout;

  @override
  Future<DisplayLayout?> getDisplayLayout() async => layout;

  @override
  Future<DisplayLayout?> configureSystemBar({
    required SystemBarSide side,
    required List<int> monitorIds,
  }) async {
    layout = layout.copyWithSystemBar(side: side, monitorIds: monitorIds);
    return layout;
  }
}

const _displayLayout = DisplayLayout(
  epoch: 1,
  globalOrigin: Offset.zero,
  logicalSize: Size(3840, 1080),
  pixelSize: Size(3840, 1080),
  engineScale: 1,
  tickerMonitorId: 1,
  systemBarMonitorId: 1,
  systemBarMonitorIds: <int>[1],
  systemBarSide: SystemBarSide.top,
  systemBarThickness: 32,
  outputs: <DisplayOutput>[
    DisplayOutput(
      monitorId: 1,
      name: 'DP-1',
      logicalRect: Rect.fromLTWH(0, 0, 1920, 1080),
      pixelSize: Size(1920, 1080),
      scale: 1,
      refreshRate: 120,
    ),
    DisplayOutput(
      monitorId: 2,
      name: 'HDMI-A-1',
      logicalRect: Rect.fromLTWH(1920, 0, 1920, 1080),
      pixelSize: Size(1920, 1080),
      scale: 1,
      refreshRate: 60,
    ),
  ],
);
