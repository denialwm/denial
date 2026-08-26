import 'dart:async';
import 'dart:ui' show CheckedState, SemanticsRole;

import 'package:denial_dart_shell/src/settings/widgets/focused_border_color_picker.dart';
import 'package:denial_dart_shell/src/settings/widgets/hsv_color_wheel.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_about_page.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_appearance_page.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_controls.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_developer_page.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_displays_page.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_language_page.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_power_page.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_touchpad_page.dart';
import 'package:denial_dart_shell/src/settings/widgets/settings_navigation.dart';
import 'package:denial_dart_shell/src/settings/widgets/system_bar_placement_card.dart';
import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/models/display_layout.dart';
import 'package:denial_dart_shell/src/models/input_device_capabilities.dart';
import 'package:denial_dart_shell/src/models/keyboard_configuration.dart';
import 'package:denial_dart_shell/src/models/output_configuration.dart';
import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:denial_dart_shell/src/services/brightness_service.dart';
import 'package:denial_dart_shell/src/settings/settings_application.dart';
import 'package:denial_dart_shell/src/settings/settings_controller.dart';
import 'package:denial_dart_shell/src/settings/settings_store.dart';
import 'package:denial_dart_shell/src/settings/shell_settings.dart';
import 'package:denial_dart_shell/src/state/display_layout.dart';
import 'package:denial_dart_shell/src/state/output_configuration.dart';
import 'package:denial_dart_shell/src/state/shell_controller.dart';
import 'package:denial_dart_shell/src/theme/backdrop_blur_level.dart';
import 'package:denial_dart_shell/src/theme/shell_color_scheme.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:denial_dart_shell/src/theme/tokens.dart';
import 'package:denial_dart_shell/src/wallpaper/state/wallpaper_controller.dart';
import 'package:denial_dart_shell/src/widgets/denial_wordmark.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

const _settingsPages = <SettingsPageId>[
  SettingsPageId.appearance,
  SettingsPageId.language,
  SettingsPageId.keyboard,
  SettingsPageId.animations,
  SettingsPageId.layout,
  SettingsPageId.overlays,
  SettingsPageId.lockScreen,
  SettingsPageId.power,
  SettingsPageId.developer,
  SettingsPageId.about,
];

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
    expect(find.text('Colour scheme'), findsOneWidget);
    expect(find.byKey(settingsColorSchemeControlKey), findsOneWidget);
    expect(find.text('Wallpaper'), findsOneWidget);
    expect(find.byKey(settingsWallpaperTriggerKey), findsOneWidget);
    expect(find.text('Shell accent'), findsOneWidget);
    expect(find.text('Backdrop blur'), findsOneWidget);
    expect(find.text('Shape'), findsOneWidget);
    expect(find.text('Cursor'), findsOneWidget);
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
    expect(find.byType(SettingsSection), findsNWidgets(7));

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

  testWidgets('colour scheme previews immediately through shell settings', (
    tester,
  ) async {
    final container = _settingsContainer();
    addTearDown(container.dispose);
    await _pumpSettings(tester, container);

    expect(
      find.descendant(
        of: find.byKey(settingsColorSchemeControlKey),
        matching: find.byType(AnimatedContainer),
      ),
      findsNothing,
      reason: 'theme colors must not be retweened by each choice chip',
    );

    expect(
      container.read(shellSettingsProvider).appearance.colorSchemePreference,
      DesktopColorSchemePreference.preferDark,
    );
    await tester.tap(find.text('Light'));
    await tester.pump();
    expect(
      container.read(shellSettingsProvider).appearance.colorSchemePreference,
      DesktopColorSchemePreference.preferLight,
    );
    final lightSemantics = tester.getSemantics(find.text('Light'));
    expect(lightSemantics.flagsCollection.isChecked, CheckedState.isTrue);
    expect(lightSemantics.flagsCollection.isInMutuallyExclusiveGroup, isTrue);

    await tester.tap(find.text('No preference'));
    await tester.pump();
    expect(
      container.read(shellSettingsProvider).appearance.colorSchemePreference,
      DesktopColorSchemePreference.noPreference,
    );
    expect(
      find.textContaining('Denial keeps its default dark'),
      findsOneWidget,
    );
    await container.read(shellSettingsProvider.notifier).flush();
  });

  testWidgets('panel radius accepts a square zero-radius presentation', (
    tester,
  ) async {
    final container = _settingsContainer();
    addTearDown(container.dispose);
    await _pumpSettings(tester, container);

    final slider = tester.widget<SettingsSlider>(
      find.byKey(settingsPanelRadiusSliderKey),
    );
    expect(slider.minimum, 0);
    expect(slider.maximum, 56);
    expect(slider.divisions, 56);

    slider.onChanged(0);
    await tester.pump();
    expect(container.read(shellSettingsProvider).appearance.panelRadius, 0);
    await container.read(shellSettingsProvider.notifier).flush();
  });

  testWidgets('clicked navigation entry keeps its selected hover treatment', (
    tester,
  ) async {
    final container = _settingsContainer();
    addTearDown(container.dispose);
    await _pumpSettings(tester, container, size: const Size(980, 700));

    final destination = find.descendant(
      of: find.byType(SettingsNavigation),
      matching: find.byKey(
        const ValueKey<SettingsPageId>(SettingsPageId.language),
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(
      location: tester.getTopLeft(destination) - const Offset(6, 6),
    );
    await mouse.moveTo(tester.getCenter(destination));
    await tester.pumpAndSettle();

    final darkHover = ShellColorScheme.dark.surfaceContainerHigh;
    expect(_destinationColors(tester, destination), contains(darkHover));

    await mouse.down(tester.getCenter(destination));
    await tester.pump();
    await mouse.up();
    await tester.pump();

    final accent = const ShellThemeData().accent;
    expect(
      _destinationColors(tester, destination),
      contains(accent.withAlpha(20)),
    );
    expect(_destinationColors(tester, destination), isNot(contains(darkHover)));
  });

  testWidgets('wallpaper action opens the shared selector', (tester) async {
    final container = _settingsContainer();
    addTearDown(container.dispose);
    await _pumpSettings(tester, container, size: const Size(420, 792));

    await tester.tap(find.byKey(settingsWallpaperTriggerKey));
    await tester.pump();

    final wallpaperState = container.read(wallpaperControllerProvider);
    expect(wallpaperState.selectorVisible, isTrue);
    expect(wallpaperState.targetPixelSize, _displayLayout.pixelSize);
  });

  testWidgets('wallpaper action delegates to an external shell launcher', (
    tester,
  ) async {
    final container = _settingsContainer();
    addTearDown(container.dispose);
    var launches = 0;
    await _pumpSettings(
      tester,
      container,
      size: const Size(420, 792),
      onOpenWallpaperSelector: () async {
        launches += 1;
      },
    );

    await tester.tap(find.byKey(settingsWallpaperTriggerKey));
    await tester.pump();

    expect(launches, 1);
    expect(
      container.read(wallpaperControllerProvider).selectorVisible,
      isFalse,
    );
  });

  testWidgets('touchpad settings follow compositor device detection', (
    tester,
  ) async {
    final container = _settingsContainer();
    addTearDown(container.dispose);
    await _pumpSettings(tester, container, size: const Size(980, 700));
    await tester.pumpAndSettle();

    expect(find.text('Touchpad'), findsOneWidget);
    final bridge = container.read(denialBridgeProvider) as _SettingsBridge;
    bridge.setHasTouchpad(true);
    await tester.pumpAndSettle();

    expect(find.text('Touchpad'), findsOneWidget);
    await tester.tap(find.text('Touchpad'));
    await tester.pumpAndSettle();
    expect(find.text('Touchpad detected'), findsNothing);
    expect(find.text('Gesture shortcuts'), findsNothing);
    expect(find.text('Tap to click'), findsOneWidget);
    expect(find.text('Reverse two-finger scrolling'), findsOneWidget);
    expect(find.text('Finger scroll speed'), findsOneWidget);

    final scrollSpeedSlider = tester.widget<SettingsSlider>(
      find.byKey(settingsScrollSpeedSliderKey),
    );
    expect(scrollSpeedSlider.minimum, 0.05);
    expect(scrollSpeedSlider.maximum, 5);
    expect(scrollSpeedSlider.value, 1);

    await tester.tap(find.byKey(settingsTapToClickToggleKey));
    await tester.pumpAndSettle();
    expect(bridge.touchpad.tapToClickEnabled, isFalse);
    expect(bridge.touchpadConfigureCount, 1);

    await tester.tap(find.byKey(settingsNaturalScrollToggleKey));
    await tester.pumpAndSettle();
    expect(bridge.touchpad.naturalScrollEnabled, isTrue);
    expect(bridge.touchpadConfigureCount, 2);

    scrollSpeedSlider.onChangeStart?.call(1);
    scrollSpeedSlider.onChanged(2.5);
    scrollSpeedSlider.onChangeEnd?.call(2.5);
    await tester.pumpAndSettle();
    expect(bridge.touchpad.scrollSpeedFactor, 2.5);
    expect(bridge.touchpadConfigureCount, 3);

    bridge.setHasTouchpad(false);
    await tester.pumpAndSettle();
    expect(find.text('Touchpad'), findsOneWidget);
    expect(
      tester
          .widget<SettingsToggle>(find.byKey(settingsTapToClickToggleKey))
          .enabled,
      isFalse,
    );
  });

  testWidgets('short settings tabs remain aligned to the top', (tester) async {
    final container = _settingsContainer();
    addTearDown(container.dispose);
    await _pumpSettings(tester, container, size: const Size(980, 700));

    final appearanceTop = tester.getTopLeft(find.text('APPEARANCE')).dy;
    tester
        .widget<SettingsNavigation>(find.byType(SettingsNavigation))
        .onSelected(SettingsPageId.power);
    await tester.pumpAndSettle();

    final powerTop = tester.getTopLeft(find.text('POWER')).dy;
    expect(powerTop, closeTo(appearanceTop, 0.01));
    expect(powerTop, lessThan(100));
    expect(find.byType(SettingsCardGroup), findsOneWidget);
    expect(find.byType(SettingsSection), findsNWidgets(2));
  });

  testWidgets('page open request selects Power when Settings mounts', (
    tester,
  ) async {
    final container = _settingsContainer();
    addTearDown(container.dispose);
    container
        .read(settingsPageOpenRequestProvider.notifier)
        .request(SettingsPageId.power);

    await _pumpSettings(tester, container, size: const Size(980, 700));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<SettingsNavigation>(find.byType(SettingsNavigation))
          .selected,
      SettingsPageId.power,
    );
    expect(find.byKey(settingsIdleDpmsToggleKey), findsOneWidget);
    expect(container.read(settingsPageOpenRequestProvider), isNull);

    tester
        .widget<SettingsNavigation>(find.byType(SettingsNavigation))
        .onSelected(SettingsPageId.appearance);
    await tester.pumpAndSettle();
    container
        .read(settingsPageOpenRequestProvider.notifier)
        .request(SettingsPageId.power);
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<SettingsNavigation>(find.byType(SettingsNavigation))
          .selected,
      SettingsPageId.power,
    );
    expect(container.read(settingsPageOpenRequestProvider), isNull);
  });

  testWidgets('localized settings tabs fit the minimum application size', (
    tester,
  ) async {
    for (final locale in const <Locale>[Locale('en'), Locale('zh')]) {
      final container = _settingsContainer();
      addTearDown(container.dispose);
      await _pumpSettings(
        tester,
        container,
        size: const Size(560, 440),
        locale: locale,
      );

      for (final page in _settingsPages) {
        tester
            .widget<SettingsNavigation>(find.byType(SettingsNavigation))
            .onSelected(page);
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: '${locale.languageCode}/${page.name}',
        );
      }
    }
  });

  testWidgets('localized settings tabs fit a phone viewport', (tester) async {
    for (final locale in const <Locale>[Locale('en'), Locale('zh')]) {
      final container = _settingsContainer();
      addTearDown(container.dispose);
      await _pumpSettings(
        tester,
        container,
        size: const Size(420, 792),
        locale: locale,
      );

      for (final page in _settingsPages) {
        tester
            .widget<SettingsNavigation>(find.byType(SettingsNavigation))
            .onSelected(page);
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: '${locale.languageCode}/${page.name}',
        );
      }
    }
  });

  testWidgets('language selector applies and resets the locale live', (
    tester,
  ) async {
    final container = _settingsContainer();
    addTearDown(container.dispose);
    await _pumpSettings(tester, container, size: const Size(980, 700));

    await tester.tap(find.text('Language'));
    await tester.pumpAndSettle();
    expect(find.byKey(settingsLanguageSelectorKey), findsOneWidget);
    expect(find.text('Choose the language Denial uses.'), findsOneWidget);

    await tester.tap(find.text('简体中文'));
    await tester.pumpAndSettle();
    expect(
      container.read(shellSettingsProvider).localization.locale,
      ShellLocalePreference.simplifiedChinese,
    );
    expect(find.text('选择 Denial 使用的语言。'), findsOneWidget);
    expect(find.bySemanticsLabel('Denial 界面语言'), findsOneWidget);

    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    expect(
      container.read(shellSettingsProvider).localization.locale,
      ShellLocalePreference.english,
    );
    expect(find.text('Choose the language Denial uses.'), findsOneWidget);

    await tester.tap(find.text('Reset page'));
    await tester.pumpAndSettle();
    expect(
      container.read(shellSettingsProvider).localization.locale,
      ShellLocalePreference.system,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard page applies the shared native XKB configuration', (
    tester,
  ) async {
    final container = _settingsContainer();
    addTearDown(container.dispose);
    await _pumpSettings(tester, container, size: const Size(980, 700));

    await tester.tap(find.text('Keyboard'));
    await tester.pumpAndSettle();
    expect(find.text('Layouts and variants'), findsOneWidget);
    expect(find.textContaining('English (US)'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Layouts'),
      'us, de:nodeadkeys',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'XKB options'),
      'compose:menu',
    );
    await tester.ensureVisible(find.text('Apply keyboard settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply keyboard settings'));
    await tester.pumpAndSettle();

    final bridge = container.read(denialBridgeProvider) as _SettingsBridge;
    expect(bridge.keyboard.revision, 2);
    expect(bridge.keyboard.layouts, const <DenialKeyboardLayout>[
      DenialKeyboardLayout(layout: 'us'),
      DenialKeyboardLayout(layout: 'de', variant: 'nodeadkeys'),
    ]);
    expect(bridge.keyboard.options, const <String>['compose:menu']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('display page edits rotation, arrangement, and applies once', (
    tester,
  ) async {
    final container = _settingsContainer();
    addTearDown(container.dispose);
    await _pumpSettings(tester, container, size: const Size(980, 700));

    tester
        .widget<SettingsNavigation>(find.byType(SettingsNavigation))
        .onSelected(SettingsPageId.displays);
    await tester.pumpAndSettle();
    expect(find.byKey(settingsMonitorLayoutEditorKey), findsOneWidget);
    expect(find.text('DP-1'), findsWidgets);
    expect(find.text('HDMI-A-1'), findsWidgets);

    final monitor = find.byKey(const ValueKey<String>('monitor-DP-1'));
    final drag = await tester.startGesture(tester.getCenter(monitor));
    await drag.moveBy(const Offset(40, 0));
    await tester.pump();
    await drag.moveBy(const Offset(80, 0));
    await drag.up();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Landscape'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Landscape'));
    await tester.pumpAndSettle();
    expect(find.text('90° clockwise'), findsOneWidget);
    await tester.ensureVisible(find.text('90° clockwise'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('90° clockwise'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(settingsApplyDisplayConfigurationKey),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(settingsApplyDisplayConfigurationKey));
    await tester.pumpAndSettle();

    final bridge = container.read(denialBridgeProvider) as _SettingsBridge;
    expect(bridge.outputApplyCount, 1);
    expect(
      bridge.outputConfiguration.outputs.first.transform,
      DenialOutputTransform.rotate90,
    );
    expect(
      bridge.outputConfiguration.outputs.first.x,
      greaterThan(_outputConfiguration.outputs.first.x),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('display page selects and persists the primary output', (
    tester,
  ) async {
    final container = _settingsContainer();
    addTearDown(container.dispose);
    await _pumpSettings(tester, container, size: const Size(980, 700));

    tester
        .widget<SettingsNavigation>(find.byType(SettingsNavigation))
        .onSelected(SettingsPageId.displays);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(settingsPrimaryDisplaySelectorKey));
    await tester.pumpAndSettle();
    expect(find.text('Automatic (highest refresh rate)'), findsOneWidget);

    await tester.tap(find.byKey(settingsPrimaryDisplaySelectorKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('HDMI-A-1').last);
    await tester.pumpAndSettle();

    expect(
      container.read(outputConfigurationProvider).draftPrimaryOutput,
      'HDMI-A-1',
    );
    await tester.ensureVisible(
      find.byKey(settingsApplyDisplayConfigurationKey),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(settingsApplyDisplayConfigurationKey));
    await tester.pumpAndSettle();

    final bridge = container.read(denialBridgeProvider) as _SettingsBridge;
    expect(bridge.outputConfiguration.primaryOutput, 'HDMI-A-1');
    expect(bridge.outputApplyCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('VRR is editable only for supported monitors', (tester) async {
    final container = _settingsContainer();
    addTearDown(container.dispose);
    await _pumpSettings(tester, container, size: const Size(980, 700));

    tester
        .widget<SettingsNavigation>(find.byType(SettingsNavigation))
        .onSelected(SettingsPageId.displays);
    await tester.pumpAndSettle();

    expect(find.byKey(settingsVariableRefreshRateToggleKey), findsOneWidget);
    expect(find.text('Variable refresh rate (VRR)'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(settingsVariableRefreshRateToggleKey),
    );
    await tester.tap(find.byKey(settingsVariableRefreshRateToggleKey));
    await tester.pumpAndSettle();
    expect(
      container
          .read(outputConfigurationProvider)
          .draftOutputs
          .first
          .adaptiveSync,
      isTrue,
    );

    container.read(outputConfigurationProvider.notifier).select('HDMI-A-1');
    await tester.pump();
    expect(find.byKey(settingsVariableRefreshRateToggleKey), findsNothing);
    expect(find.text('Variable refresh rate (VRR)'), findsNothing);

    container.read(outputConfigurationProvider.notifier).select('DP-1');
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(settingsVariableRefreshRateToggleKey),
    );
    await tester.tap(find.byKey(settingsVariableRefreshRateToggleKey));
    await tester.pumpAndSettle();
    expect(
      container
          .read(outputConfigurationProvider)
          .draftOutputs
          .first
          .adaptiveSync,
      isFalse,
    );
    await tester.tap(find.byKey(settingsVariableRefreshRateToggleKey));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(settingsApplyDisplayConfigurationKey),
    );
    await tester.tap(find.byKey(settingsApplyDisplayConfigurationKey));
    await tester.pumpAndSettle();

    final bridge = container.read(denialBridgeProvider) as _SettingsBridge;
    expect(bridge.outputApplyCount, 1);
    expect(bridge.outputConfiguration.outputs.first.adaptiveSync, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('display canvas scroll zoom requires Ctrl or Meta', (
    tester,
  ) async {
    final container = _settingsContainer();
    addTearDown(container.dispose);
    await _pumpSettings(tester, container, size: const Size(980, 1000));

    tester
        .widget<SettingsNavigation>(find.byType(SettingsNavigation))
        .onSelected(SettingsPageId.displays);
    await tester.pumpAndSettle();

    final monitor = find.byKey(const ValueKey<String>('monitor-DP-1'));
    final canvas = find.byKey(settingsMonitorCanvasKey);
    await tester.ensureVisible(canvas);
    await tester.pumpAndSettle();
    expect(tester.getSize(canvas).height, 360);
    final monitorIcon = tester.widget<Icon>(
      find.descendant(
        of: monitor,
        matching: find.byIcon(Icons.monitor_rounded),
      ),
    );
    final monitorCard = tester.widget<AnimatedContainer>(
      find.descendant(of: monitor, matching: find.byType(AnimatedContainer)),
    );
    expect(monitorIcon.color, ShellColorScheme.dark.textPrimary);
    expect((monitorCard.decoration! as BoxDecoration).borderRadius, isNull);
    final initialMonitorRect = tester.getRect(monitor);
    final canvasRect = tester.getRect(canvas);
    final pan = await tester.startGesture(
      canvasRect.bottomRight - const Offset(24, 24),
    );
    await pan.moveBy(const Offset(32, 0));
    await tester.pump();
    await pan.moveBy(const Offset(700, 500));
    await pan.up();
    await tester.pumpAndSettle();

    final pannedMonitorRect = tester.getRect(monitor);
    expect(pannedMonitorRect.left - initialMonitorRect.left, greaterThan(650));
    expect(pannedMonitorRect.top - initialMonitorRect.top, greaterThan(450));
    expect(
      container.read(outputConfigurationProvider).draftOutputs.first.x,
      _outputConfiguration.outputs.first.x,
    );

    final pageScrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(SettingsDisplaysPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    final pageOffsetBeforeScroll = pageScrollable.position.pixels;
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(canvas),
        scrollDelta: const Offset(0, 20),
        kind: PointerDeviceKind.mouse,
      ),
    );
    await tester.pumpAndSettle();
    expect(pageScrollable.position.pixels, greaterThan(pageOffsetBeforeScroll));
    expect(tester.getSize(monitor).width, pannedMonitorRect.width);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(canvas),
        scrollDelta: const Offset(0, -20),
        kind: PointerDeviceKind.mouse,
      ),
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(tester.getSize(monitor).width, greaterThan(pannedMonitorRect.width));
    expect(find.text('20%'), findsOneWidget);
    expect(find.byKey(settingsMonitorZoomOutKey), findsOneWidget);
    expect(find.byKey(settingsMonitorZoomFitKey), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(canvas),
        scrollDelta: const Offset(0, 20),
        kind: PointerDeviceKind.mouse,
      ),
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(find.text('15%'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    for (var index = 0; index < 10; index++) {
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(canvas),
          scrollDelta: const Offset(0, 20),
          kind: PointerDeviceKind.mouse,
        ),
      );
      await tester.pump();
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('1%'), findsOneWidget);
    expect(tester.getSize(monitor).width, closeTo(19.2, 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unselected monitor selects and drags in one gesture', (
    tester,
  ) async {
    final container = _settingsContainer();
    addTearDown(container.dispose);
    await _pumpSettings(tester, container, size: const Size(980, 1000));

    tester
        .widget<SettingsNavigation>(find.byType(SettingsNavigation))
        .onSelected(SettingsPageId.displays);
    await tester.pumpAndSettle();

    final monitor = find.byKey(const ValueKey<String>('monitor-HDMI-A-1'));
    final initialX = container
        .read(outputConfigurationProvider)
        .draftOutputs
        .last
        .x;
    final drag = await tester.startGesture(tester.getCenter(monitor));
    await drag.moveBy(const Offset(36, 0));
    await tester.pump();
    await drag.moveBy(const Offset(80, 0));
    await drag.up();
    await tester.pumpAndSettle();

    final state = container.read(outputConfigurationProvider);
    expect(state.selectedOutput?.name, 'HDMI-A-1');
    expect(state.draftOutputs.last.x, greaterThan(initialX));
    expect(tester.takeException(), isNull);
  });

  testWidgets('single display omits the monitor layout editor', (tester) async {
    final singleOutput = DenialOutputConfiguration(
      serial: _outputConfiguration.serial,
      capabilities: _outputCapabilities,
      outputs: <DenialOutput>[_outputConfiguration.outputs.first],
    );
    final container = _settingsContainer(outputConfiguration: singleOutput);
    addTearDown(container.dispose);
    await _pumpSettings(tester, container, size: const Size(980, 700));

    tester
        .widget<SettingsNavigation>(find.byType(SettingsNavigation))
        .onSelected(SettingsPageId.displays);
    await tester.pumpAndSettle();

    expect(find.byKey(settingsMonitorLayoutEditorKey), findsNothing);
    expect(find.text('Resolution'), findsOneWidget);
    expect(find.text('Landscape'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending display changes reopen Displays and can be kept', (
    tester,
  ) async {
    final pending = DenialOutputConfiguration(
      serial: _outputConfiguration.serial,
      capabilities: _outputCapabilities,
      outputs: _outputConfiguration.outputs,
      pendingConfirmation: DenialOutputConfirmation(
        token: 91,
        deadlineUnixMilliseconds: DateTime.now().millisecondsSinceEpoch + 10000,
      ),
    );
    final container = _settingsContainer(outputConfiguration: pending);
    addTearDown(container.dispose);
    await _pumpSettings(tester, container, size: const Size(980, 700));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(settingsDisplayConfirmationDialogKey), findsOneWidget);
    expect(find.text('Monitor configuration'), findsOneWidget);

    await tester.tap(find.byKey(settingsKeepDisplayConfigurationKey));
    await tester.pump();
    await tester.pump();

    final bridge = container.read(denialBridgeProvider) as _SettingsBridge;
    expect(bridge.outputConfirmCount, 1);
    expect(find.byKey(settingsDisplayConfirmationDialogKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('backdrop blur enablement and quality update live', (
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
    expect(
      tester
          .widget<SettingsSlider>(
            find.byKey(settingsBackdropBlurOpacityThresholdKey),
          )
          .enabled,
      isFalse,
    );

    await tester.tap(find.byKey(settingsBackdropBlurToggleKey));
    await tester.pump();
    final slider = tester.widget<SettingsSlider>(
      find.byKey(settingsBackdropBlurSliderKey),
    );
    expect(slider.valueLabel, 'Fast');
    slider.onChanged(0);
    tester
        .widget<SettingsSlider>(
          find.byKey(settingsBackdropBlurOpacityThresholdKey),
        )
        .onChanged(0.12);
    await tester.pump();

    final appearance = container.read(shellSettingsProvider).appearance;
    expect(appearance.backdropBlurEnabled, isTrue);
    expect(appearance.backdropBlurLevel, ShellBackdropBlurLevel.shitty);
    expect(appearance.backdropBlurOpacityThreshold, 0.12);
    await container.read(shellSettingsProvider.notifier).flush();
  });

  testWidgets('cursor size updates live from appearance settings', (
    tester,
  ) async {
    final container = _settingsContainer();
    addTearDown(container.dispose);
    await _pumpSettings(tester, container);

    await tester.ensureVisible(find.byKey(settingsCursorSizeSliderKey));
    final slider = tester.widget<SettingsSlider>(
      find.byKey(settingsCursorSizeSliderKey),
    );
    expect(slider.valueLabel, '32 px');
    slider.onChanged(48);
    await tester.pump();

    expect(container.read(shellSettingsProvider).appearance.cursorSize, 48);
    expect(
      tester
          .widget<SettingsSlider>(find.byKey(settingsCursorSizeSliderKey))
          .valueLabel,
      '48 px',
    );
    await container.read(shellSettingsProvider.notifier).flush();
  });

  testWidgets('about is the last destination and presents Denial credits', (
    tester,
  ) async {
    final container = _settingsContainer();
    addTearDown(container.dispose);
    await _pumpSettings(tester, container, size: const Size(980, 700));

    expect(SettingsPageId.values.last, SettingsPageId.about);
    await tester.scrollUntilVisible(
      find.text('About'),
      180,
      scrollable: find.descendant(
        of: find.byKey(settingsNavigationListKey),
        matching: find.byType(Scrollable),
      ),
    );
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

    await tester.scrollUntilVisible(
      find.text('About'),
      180,
      scrollable: find.descendant(
        of: find.byKey(settingsNavigationListKey),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();

    expect(find.byKey(settingsAboutWordmarkKey), findsOneWidget);
    expect(find.text('Doctor Logix'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('developer page offers automatic editable UI setup', (
    tester,
  ) async {
    final container = _settingsContainer();
    addTearDown(container.dispose);
    await _pumpSettings(tester, container, size: const Size(980, 700));

    await tester.scrollUntilVisible(
      find.text('About'),
      180,
      scrollable: find.descendant(
        of: find.byKey(settingsNavigationListKey),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.text('Developer'));
    await tester.pumpAndSettle();

    expect(find.text('Create and start editable UI'), findsOneWidget);
    expect(find.byKey(settingsDeveloperWorkspaceFieldKey), findsOneWidget);
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

  testWidgets('colour-scheme choices wrap at large accessible text sizes', (
    tester,
  ) async {
    final container = _settingsContainer();
    addTearDown(container.dispose);
    await _pumpSettings(
      tester,
      container,
      size: const Size(360, 640),
      textScaler: const TextScaler.linear(2),
    );

    expect(find.text('Dark'), findsOneWidget);
    expect(find.text('Light'), findsOneWidget);
    expect(find.text('No preference'), findsOneWidget);
    await tester.ensureVisible(find.text('No preference'));
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

    tester
        .widget<SettingsNavigation>(find.byType(SettingsNavigation))
        .onSelected(SettingsPageId.power);
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

List<Color?> _destinationColors(WidgetTester tester, Finder destination) {
  return tester
      .widgetList<DecoratedBox>(
        find.descendant(of: destination, matching: find.byType(DecoratedBox)),
      )
      .map((box) => (box.decoration as BoxDecoration).color)
      .toList(growable: false);
}

ProviderContainer _settingsContainer({
  DenialOutputConfiguration outputConfiguration = _outputConfiguration,
}) {
  return ProviderContainer.test(
    overrides: [
      settingsStoreProvider.overrideWithValue(_MemorySettingsStore()),
      wallpaperSourcesProvider.overrideWithValue(const []),
      denialBridgeProvider.overrideWith((ref) {
        final bridge = _SettingsBridge(
          _displayLayout,
          outputConfiguration: outputConfiguration,
        );
        ref.onDispose(bridge.dispose);
        return bridge;
      }),
      brightnessServiceProvider.overrideWith(
        (ref) => _TestBrightnessService(ref.watch(denialBridgeProvider)),
      ),
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
  Locale locale = const Locale('en'),
  TextScaler textScaler = TextScaler.noScaling,
  Future<void> Function()? onOpenWallpaperSelector,
}) {
  return tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: Consumer(
        builder: (context, ref, child) {
          final localeOverride = ref.watch(
            shellSettingsProvider.select(
              (settings) => settings.localization.localeOverride,
            ),
          );
          return DenialLocalizationScope(
            locale: localeOverride ?? locale,
            child: child!,
          );
        },
        child: MediaQuery(
          data: MediaQueryData(size: size, textScaler: textScaler),
          child: Overlay(
            initialEntries: <OverlayEntry>[
              OverlayEntry(
                builder: (_) => SizedBox(
                  width: size.width,
                  height: size.height,
                  child: DenialSettingsApplication(
                    onOpenWallpaperSelector: onOpenWallpaperSelector,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _TestBrightnessService extends BrightnessService {
  const _TestBrightnessService(super.bridge);

  @override
  Future<double?> readLevel([DisplayOutput? output]) async => 0.72;

  @override
  Future<void> apply(int percent, [DisplayOutput? output]) async {}
}

class _SettingsBridge extends DenialBridge {
  _SettingsBridge(
    this.layout, {
    this.outputConfiguration = _outputConfiguration,
  });

  DisplayLayout layout;
  DenialOutputConfiguration outputConfiguration;
  final _inputDeviceCapabilities =
      StreamController<DenialInputDeviceCapabilities>.broadcast(sync: true);
  var hasTouchpad = false;
  var touchpad = const DenialInputDeviceCapabilities(
    revision: 1,
    hasTouchpad: false,
    tapToClickEnabled: true,
    naturalScrollEnabled: false,
    scrollSpeedFactor: 1,
  );
  int touchpadConfigureCount = 0;
  int outputApplyCount = 0;
  int outputConfirmCount = 0;
  int outputRollbackCount = 0;
  DenialKeyboardConfiguration keyboard = const DenialKeyboardConfiguration(
    revision: 1,
    layouts: <DenialKeyboardLayout>[
      DenialKeyboardLayout(layout: 'us', displayName: 'English (US)'),
    ],
    options: <String>[],
    repeatDelayMs: 600,
    repeatRateHz: 25,
    activeLayout: 0,
  );

  @override
  int queryUiDevelopmentState() => 1;

  @override
  Future<DenialKeyboardConfiguration> readKeyboardConfiguration() async {
    return keyboard;
  }

  @override
  Stream<DenialInputDeviceCapabilities> get inputDeviceCapabilities =>
      _inputDeviceCapabilities.stream;

  @override
  Future<DenialInputDeviceCapabilities> readInputDeviceCapabilities() async {
    return touchpad;
  }

  void setHasTouchpad(bool value) {
    hasTouchpad = value;
    touchpad = touchpad.copyWith(hasTouchpad: value);
    _inputDeviceCapabilities.add(touchpad);
  }

  @override
  Future<DenialInputDeviceCapabilities> configureTouchpad(
    DenialInputDeviceCapabilities capabilities,
  ) async {
    touchpadConfigureCount += 1;
    hasTouchpad = capabilities.hasTouchpad;
    touchpad = capabilities.copyWith(revision: touchpad.revision + 1);
    return touchpad;
  }

  @override
  void dispose() {
    unawaited(_inputDeviceCapabilities.close());
    super.dispose();
  }

  @override
  Future<DenialKeyboardConfiguration> configureKeyboard(
    DenialKeyboardConfiguration configuration,
  ) async {
    keyboard = configuration.copyWith(revision: keyboard.revision + 1);
    return keyboard;
  }

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

  @override
  Future<DenialOutputConfiguration> readOutputConfiguration() async {
    return outputConfiguration;
  }

  @override
  Future<DenialOutputConfiguration> applyOutputConfiguration({
    required int serial,
    required List<DenialOutput> outputs,
    required bool persistent,
    String? primaryOutput,
    int? confirmationTimeoutMilliseconds,
  }) async {
    outputApplyCount += 1;
    outputConfiguration = DenialOutputConfiguration(
      serial: serial + 1,
      capabilities: outputConfiguration.capabilities,
      primaryOutput: primaryOutput,
      outputs: List<DenialOutput>.unmodifiable(outputs),
    );
    return outputConfiguration;
  }

  @override
  Future<void> confirmOutputConfiguration(int token) async {
    if (outputConfiguration.pendingConfirmation?.token != token) {
      throw const DenialOutputControlException(
        'stale_confirmation',
        'stale output confirmation',
      );
    }
    outputConfirmCount += 1;
    outputConfiguration = DenialOutputConfiguration(
      serial: outputConfiguration.serial + 1,
      capabilities: outputConfiguration.capabilities,
      primaryOutput: outputConfiguration.primaryOutput,
      outputs: outputConfiguration.outputs,
    );
  }

  @override
  Future<void> rollbackOutputConfiguration(int token) async {
    if (outputConfiguration.pendingConfirmation?.token != token) {
      throw const DenialOutputControlException(
        'stale_confirmation',
        'stale output confirmation',
      );
    }
    outputRollbackCount += 1;
    outputConfiguration = DenialOutputConfiguration(
      serial: outputConfiguration.serial + 1,
      capabilities: outputConfiguration.capabilities,
      primaryOutput: outputConfiguration.primaryOutput,
      outputs: outputConfiguration.outputs,
    );
  }
}

const _outputCapabilities = DenialOutputCapabilities(
  apply: true,
  position: true,
  mode: true,
  scale: true,
  transform: true,
  adaptiveSync: true,
  persistent: true,
);

const _mode1080p120 = DenialOutputMode(
  width: 1920,
  height: 1080,
  refreshMillihz: 120000,
  preferred: true,
);

const _mode1080p60 = DenialOutputMode(
  width: 1920,
  height: 1080,
  refreshMillihz: 60000,
  preferred: true,
);

const _outputConfiguration = DenialOutputConfiguration(
  serial: 4,
  capabilities: _outputCapabilities,
  outputs: <DenialOutput>[
    DenialOutput(
      name: 'DP-1',
      description: 'DP-1',
      connected: true,
      enabled: true,
      powered: true,
      x: 0,
      y: 0,
      logicalWidth: 1920,
      logicalHeight: 1080,
      scale: 1,
      transform: DenialOutputTransform.normal,
      adaptiveSyncSupported: true,
      adaptiveSync: false,
      currentMode: _mode1080p120,
      modes: <DenialOutputMode>[_mode1080p120, _mode1080p60],
    ),
    DenialOutput(
      name: 'HDMI-A-1',
      description: 'HDMI-A-1',
      connected: true,
      enabled: true,
      powered: true,
      x: 1920,
      y: 0,
      logicalWidth: 1920,
      logicalHeight: 1080,
      scale: 1,
      transform: DenialOutputTransform.normal,
      adaptiveSyncSupported: false,
      adaptiveSync: false,
      currentMode: _mode1080p60,
      modes: <DenialOutputMode>[_mode1080p60],
    ),
  ],
);

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
