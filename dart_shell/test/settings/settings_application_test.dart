import 'dart:ui' show SemanticsRole;

import 'package:denial_dart_shell/src/settings/widgets/focused_border_color_picker.dart';
import 'package:denial_dart_shell/src/settings/widgets/hsv_color_wheel.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_about_page.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_appearance_page.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_controls.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_power_page.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_navigation.dart';
import 'package:denial_dart_shell/src/settings/widgets/system_bar_placement_card.dart';
import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/models/display_layout.dart';
import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:denial_dart_shell/src/settings/settings_application.dart';
import 'package:denial_dart_shell/src/settings/settings_controller.dart';
import 'package:denial_dart_shell/src/settings/settings_store.dart';
import 'package:denial_dart_shell/src/settings/shell_settings.dart';
import 'package:denial_dart_shell/src/state/display_layout.dart';
import 'package:denial_dart_shell/src/state/shell_controller.dart';
import 'package:denial_dart_shell/src/theme/tokens.dart';
import 'package:denial_dart_shell/src/widgets/denial_wordmark.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('settings application presents the live appearance control', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final container = _settingsContainer();
    addTearDown(container.dispose);

    await _pumpSettings(tester, container);

    expect(find.text('Settings'), findsNothing);
    expect(find.bySemanticsLabel('Denial'), findsOneWidget);
    final headerWordmark = find.byType(DenialWordmark);
    final headerWordmarkRect = tester.getRect(headerWordmark);
    expect(headerWordmarkRect.left, 18);
    expect(headerWordmarkRect.width, 96);
    final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect(svg.allowDrawingOutsideViewBox, isTrue);
    expect(svg.clipBehavior, Clip.none);
    expect(svg.renderingStrategy.name, 'picture');
    expect(find.text('Make the desktop feel like yours.'), findsOneWidget);
    expect(find.text('Shell accent'), findsOneWidget);
    expect(find.text('Backdrop blur'), findsOneWidget);
    expect(find.text('Shape'), findsOneWidget);
    expect(find.text('Window opacity'), findsOneWidget);
    expect(
      find.text(
        'Changes made here are reflected across the desktop in real time.',
      ),
      findsNothing,
    );
    expect(
      find.text(
        'The accent colors focused windows, controls, and active shell '
        'surfaces.',
      ),
      findsNothing,
    );
    expect(find.byType(SettingsCardGroup), findsOneWidget);
    expect(find.byType(SettingsSection), findsNWidgets(4));

    final pageTitle = tester.widget<Text>(
      find.text('Make the desktop feel like yours.'),
    );
    final sectionTitle = tester.widget<Text>(find.text('Shell accent'));
    expect(pageTitle.style?.fontSize, ShellText.base.fontSize);
    expect(pageTitle.style?.fontWeight, ShellText.base.fontWeight);
    expect(sectionTitle.style?.fontSize, ShellText.base.fontSize);
    expect(sectionTitle.style?.fontWeight, ShellText.base.fontWeight);
    expect(find.byKey(settingsSystemBarPlacementCardKey), findsNothing);
    expect(find.bySemanticsLabel(RegExp('Denial Settings')), findsOneWidget);
    final settingsSemantics = tester.widget<Semantics>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label?.contains('Denial Settings') == true,
      ),
    );
    expect(settingsSemantics.properties.role, SemanticsRole.main);
    semantics.dispose();
  });

  testWidgets('short settings tabs remain aligned to the top', (tester) async {
    final container = _settingsContainer();
    addTearDown(container.dispose);
    await _pumpSettings(tester, container, size: const Size(980, 700));

    final appearanceTop = tester.getTopLeft(find.text('APPEARANCE')).dy;
    await tester.ensureVisible(find.text('Power'));
    await tester.tap(find.text('Power'));
    await tester.pumpAndSettle();

    final powerTop = tester.getTopLeft(find.text('POWER')).dy;
    expect(powerTop, closeTo(appearanceTop, 0.01));
    expect(powerTop, lessThan(100));
    expect(find.byType(SettingsCardGroup), findsOneWidget);
    expect(find.byType(SettingsSection), findsOneWidget);
  });

  testWidgets('local settings tabs fit the minimum application size', (
    tester,
  ) async {
    final container = _settingsContainer();
    addTearDown(container.dispose);
    await _pumpSettings(tester, container, size: const Size(560, 440));

    const pages = <SettingsPageId>[
      SettingsPageId.appearance,
      SettingsPageId.animations,
      SettingsPageId.layout,
      SettingsPageId.overlays,
      SettingsPageId.lockScreen,
      SettingsPageId.power,
      SettingsPageId.about,
    ];
    for (final page in pages) {
      tester
          .widget<SettingsNavigation>(find.byType(SettingsNavigation))
          .onSelected(page);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: page.name);
    }
  });

  testWidgets('backdrop blur enablement and intensity update live', (
    tester,
  ) async {
    final container = _settingsContainer();
    addTearDown(container.dispose);
    await _pumpSettings(tester, container);

    await tester.ensureVisible(find.byKey(settingsBackdropBlurToggleKey));
    await tester.tap(find.byKey(settingsBackdropBlurToggleKey));
    await tester.pump();

    expect(
      container.read(shellSettingsProvider).appearance.backdropBlurEnabled,
      isFalse,
    );
    expect(
      tester
          .widget<SettingsSlider>(find.byKey(settingsBackdropBlurSliderKey))
          .enabled,
      isFalse,
    );

    await tester.tap(find.byKey(settingsBackdropBlurToggleKey));
    await tester.pump();
    final slider = tester.widget<SettingsSlider>(
      find.byKey(settingsBackdropBlurSliderKey),
    );
    slider.onChanged(26);
    await tester.pump();

    final appearance = container.read(shellSettingsProvider).appearance;
    expect(appearance.backdropBlurEnabled, isTrue);
    expect(appearance.backdropBlurSigma, 26);
    await container.read(shellSettingsProvider.notifier).flush();
  });

  testWidgets('about is the last destination and presents Denial credits', (
    tester,
  ) async {
    final container = _settingsContainer();
    addTearDown(container.dispose);
    await _pumpSettings(tester, container, size: const Size(980, 700));

    expect(SettingsPageId.values.last, SettingsPageId.about);
    await tester.ensureVisible(find.text('About'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();

    expect(find.byKey(settingsAboutWordmarkKey), findsOneWidget);
    expect(find.text('A Flutter-native Wayland compositor.'), findsOneWidget);
    expect(
      find.text('Origin does not have to dictate purpose.'),
      findsOneWidget,
    );
    expect(find.text('Doctor Logix'), findsOneWidget);
    expect(find.bySemanticsLabel('About Denial'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('about page fits the minimum application size', (tester) async {
    final container = _settingsContainer();
    addTearDown(container.dispose);
    await _pumpSettings(tester, container, size: const Size(560, 440));

    await tester.ensureVisible(find.text('About'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();

    expect(find.byKey(settingsAboutWordmarkKey), findsOneWidget);
    expect(find.text('Doctor Logix'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('color wheel changes and resets the shell accent live', (
    tester,
  ) async {
    final container = _settingsContainer();
    addTearDown(container.dispose);
    await _pumpSettings(tester, container);
    final initial = container.read(shellSettingsProvider).appearance;

    await tester.tap(find.text('Custom color'));
    await tester.pump();
    await tester.ensureVisible(find.byKey(settingsAccentColorTriggerKey));
    await tester.tap(find.byKey(settingsAccentColorTriggerKey));
    await tester.pumpAndSettle();

    expect(find.byKey(settingsAccentColorPickerKey), findsOneWidget);
    expect(find.byType(HsvColorWheel), findsOneWidget);
    final pickerSemantics = tester.widget<Semantics>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.role == SemanticsRole.dialog,
      ),
    );
    expect(pickerSemantics.properties.namesRoute, isTrue);

    final wheelRect = tester.getRect(find.byType(HsvColorWheel));
    await tester.tapAt(wheelRect.center + Offset(wheelRect.width * 0.36, 0));
    await tester.pump();

    final pointerColor = container
        .read(shellSettingsProvider)
        .appearance
        .customAccentColor;
    expect(pointerColor, isNot(initial.customAccentColor));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      container.read(shellSettingsProvider).appearance.customAccentColor,
      isNot(pointerColor),
    );

    await tester.tap(find.byKey(settingsAccentColorResetKey));
    await tester.pump();
    expect(
      container.read(shellSettingsProvider).appearance.customAccentColor,
      initial.customAccentColor,
    );

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.byKey(settingsAccentColorPickerKey), findsNothing);
  });

  testWidgets('appearance page and picker fit the minimum application size', (
    tester,
  ) async {
    final container = _settingsContainer();
    addTearDown(container.dispose);
    await _pumpSettings(tester, container, size: const Size(560, 440));

    await tester.tap(find.text('Custom color'));
    await tester.pump();
    await tester.ensureVisible(find.byKey(settingsAccentColorTriggerKey));
    await tester.tap(find.byKey(settingsAccentColorTriggerKey));
    await tester.pumpAndSettle();

    expect(find.byType(HsvColorWheel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('system bar edge and monitor clones update live', (tester) async {
    final container = _settingsContainer();
    addTearDown(container.dispose);
    await _pumpSettings(tester, container);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Desktop layout'));
    await tester.pumpAndSettle();
    expect(find.byKey(settingsSystemBarPlacementCardKey), findsOneWidget);

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
    await tester.ensureVisible(firstDisplay);
    await tester.pump();
    await tester.tap(firstDisplay);
    await tester.pump();
    expect(
      container.read(displayLayoutProvider)?.effectiveSystemBarMonitorIds,
      <int>[2],
    );
    await container.read(shellSettingsProvider.notifier).flush();

    // The remaining selected display is intentionally not removable.
    await tester.ensureVisible(secondDisplay);
    await tester.pump();
    await tester.tap(secondDisplay);
    await tester.pump();
    expect(
      container.read(displayLayoutProvider)?.effectiveSystemBarMonitorIds,
      <int>[2],
    );
  });

  testWidgets('power page configures automatic DPMS live', (tester) async {
    final container = _settingsContainer();
    addTearDown(container.dispose);
    await _pumpSettings(tester, container);

    await tester.scrollUntilVisible(
      find.text('Power'),
      180,
      scrollable: find.descendant(
        of: find.byKey(settingsNavigationListKey),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.text('Power'));
    await tester.pumpAndSettle();

    expect(find.text('Automatic display power'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('Applications may keep displays awake')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(settingsIdleDpmsToggleKey));
    await tester.pump();
    expect(
      container.read(shellSettingsProvider).power.idleDpmsEnabled,
      isFalse,
    );

    await tester.tap(find.byKey(settingsIdleDpmsToggleKey));
    await tester.pump();
    final timeout = tester.widget<SettingsSlider>(
      find.byKey(settingsIdleDpmsTimeoutKey),
    );
    timeout.onChanged(37);
    await tester.pump();
    expect(
      container.read(shellSettingsProvider).power.idleDpmsTimeoutMinutes,
      37,
    );
    await container.read(shellSettingsProvider.notifier).flush();
  });

  testWidgets('custom accent and popup anchor update the typed settings', (
    tester,
  ) async {
    final container = _settingsContainer();
    addTearDown(container.dispose);
    await _pumpSettings(tester, container, size: const Size(900, 680));

    await tester.tap(find.text('Custom color'));
    await tester.pump();
    expect(
      container.read(shellSettingsProvider).appearance.accentSource,
      ShellAccentSource.custom,
    );
    await tester.tap(find.byKey(settingsAccentColorTriggerKey));
    await tester.pumpAndSettle();
    expect(find.byKey(settingsAccentColorPickerKey), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Overlays'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Top right').first);
    await tester.pump();

    expect(
      container.read(shellSettingsProvider).overlays.launcher.anchor.name,
      'topRight',
    );
    await container.read(shellSettingsProvider.notifier).flush();
  });
}

ProviderContainer _settingsContainer() {
  return ProviderContainer.test(
    overrides: [
      settingsStoreProvider.overrideWithValue(_MemorySettingsStore()),
      denialBridgeProvider.overrideWith((ref) {
        final bridge = _SettingsBridge(_displayLayout);
        ref.onDispose(bridge.dispose);
        return bridge;
      }),
    ],
  );
}

class _MemorySettingsStore implements SettingsStore {
  @override
  Future<ShellSettings?> read() async => null;

  @override
  Future<void> write(ShellSettings settings) async {}
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
          child: Overlay(
            initialEntries: <OverlayEntry>[
              OverlayEntry(
                builder: (_) => SizedBox(
                  width: size.width,
                  height: size.height,
                  child: const DenialSettingsApplication(),
                ),
              ),
            ],
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
