import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/input/shell_interaction_registry.dart';
import 'package:denial_dart_shell/src/launcher/runtime_paths.dart';
import 'package:denial_dart_shell/src/models/display_layout.dart';
import 'package:denial_dart_shell/src/state/shell_controller.dart';
import 'package:denial_dart_shell/src/theme/motion.dart';
import 'package:denial_dart_shell/src/theme/shell_theme.dart';
import 'package:denial_dart_shell/src/wallpaper/state/wallpaper_controller.dart';
import 'package:denial_dart_shell/src/wallpaper/wallpaper.dart';
import 'package:denial_dart_shell/src/wallpaper/wallpaper_provider.dart';
import 'package:denial_dart_shell/src/wallpaper/widgets/wallpaper_darkness_control.dart';
import 'package:denial_dart_shell/src/wallpaper/widgets/mobile_wallpaper_selector_layer.dart';
import 'package:denial_dart_shell/src/wallpaper/widgets/mobile_wallpaper_selector_surface.dart';
import 'package:denial_dart_shell/src/wallpaper/widgets/wallpaper_search_controls.dart';
import 'package:denial_dart_shell/src/wallpaper/widgets/wallpaper_selector_surface.dart';
import 'package:denial_dart_shell/src/wallpaper/widgets/wallpaper_span_controls.dart';
import 'package:denial_dart_shell/src/wallpaper/widgets/wallpaper_target_selector.dart';
import 'package:denial_dart_shell/src/widgets/edge_panel_layer.dart';
import 'package:denial_dart_shell/src/widgets/shade/range_bar.dart';

import '../support/wallpaper_controller_harness.dart';

void main() {
  testWidgets('desktop selector retains its carousel and autofocus behavior', (
    tester,
  ) async {
    final temporary = Directory(
      '${Directory.systemTemp.path}/denial-wallpaper-desktop-widget-'
      '${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    addTearDown(() => temporary.deleteSync(recursive: true));
    final candidate = WallpaperCandidate(
      id: 'default',
      providerId: 'fixed',
      label: 'Default',
      previewUri: Uri(scheme: 'asset', path: defaultShellWallpaperAsset),
      width: 1920,
      height: 1080,
      resource: WallpaperResource.defaultWallpaper,
    );
    final harness = WallpaperControllerTestHarness(
      sources: <WallpaperProvider>[_FixedWallpaperProvider(candidate)],
      store: WallpaperStore(
        RuntimePaths(environment: <String, String>{'HOME': temporary.path}),
      ),
      displayLayout: _desktopDisplayLayout,
    );
    addTearDown(harness.container.dispose);
    harness.controller.openSelector(targetPixelSize: const Size(1264, 2780));

    await tester.pumpWidget(
      DenialLocalizationScope(
        locale: const Locale('en'),
        child: UncontrolledProviderScope(
          container: harness.container,
          child: MediaQuery(
            data: const MediaQueryData(size: Size(500, 800)),
            child: WallpaperSelectorOverlay(
              visible: true,
              displayRect: const Rect.fromLTWH(0, 0, 500, 800),
              onDismiss: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(WallpaperSelectorSurface), findsOneWidget);
    expect(find.byType(MobileWallpaperSelectorSurface), findsNothing);
    expect(
      tester
          .widget<PageView>(find.byType(PageView))
          .controller!
          .viewportFraction,
      closeTo(0.208, 0.0001),
    );
    expect(
      tester
          .widget<WallpaperSearchField>(find.byType(WallpaperSearchField))
          .focusNode
          .hasFocus,
      isTrue,
    );

    await tester.tap(find.text('DP-4'));
    await tester.pump();

    expect(harness.state.target, const WallpaperTarget.output('DP-4'));
    expect(find.byType(WallpaperSpanAlignmentSelector), findsOneWidget);

    final tileOpacity = find.byKey(
      const ValueKey<String>('desktop-wallpaper-tiles-opacity'),
    );
    expect(tester.widget<AnimatedOpacity>(tileOpacity).opacity, 1.0);

    final darknessRect = tester.getRect(find.byType(RangeBar).first);
    final darknessGesture = await tester.startGesture(darknessRect.center);
    await darknessGesture.moveBy(const Offset(24, 0));
    await tester.pump();
    final opacityWidget = tester.widget<AnimatedOpacity>(tileOpacity);
    expect(opacityWidget.opacity, 0.0);
    expect(opacityWidget.duration, Motion.wallpaperTilesFade);

    await tester.pump(const Duration(milliseconds: 150));
    final renderedOpacity = tester
        .widget<FadeTransition>(
          find
              .descendant(
                of: tileOpacity,
                matching: find.byType(FadeTransition),
              )
              .first,
        )
        .opacity
        .value;
    expect(renderedOpacity, closeTo(0.5, 0.08));

    await darknessGesture.up();
    await tester.pump();
    expect(tester.widget<AnimatedOpacity>(tileOpacity).opacity, 1.0);

    final alignmentRect = tester.getRect(find.byType(RangeBar).at(1));
    final alignmentGesture = await tester.startGesture(alignmentRect.center);
    await alignmentGesture.moveBy(const Offset(24, 0));
    await tester.pump();
    expect(tester.widget<AnimatedOpacity>(tileOpacity).opacity, 0.0);

    await alignmentGesture.up();
    await tester.pump();
    expect(tester.widget<AnimatedOpacity>(tileOpacity).opacity, 1.0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile selector owns input without opening the keyboard', (
    tester,
  ) async {
    final temporary = Directory(
      '${Directory.systemTemp.path}/denial-mobile-wallpaper-widget-'
      '${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    addTearDown(() => temporary.deleteSync(recursive: true));
    final harness = WallpaperControllerTestHarness(
      sources: const <WallpaperProvider>[],
      store: WallpaperStore(
        RuntimePaths(environment: <String, String>{'HOME': temporary.path}),
      ),
    );
    addTearDown(harness.container.dispose);

    await tester.pumpWidget(
      DenialLocalizationScope(
        locale: const Locale('en'),
        child: UncontrolledProviderScope(
          container: harness.container,
          child: const MediaQuery(
            data: MediaQueryData(size: Size(420, 792)),
            child: SizedBox.expand(child: MobileWallpaperSelectorLayer()),
          ),
        ),
      ),
    );

    harness.controller.openSelector(targetPixelSize: const Size(1264, 2780));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(MobileWallpaperSelectorSurface), findsOneWidget);
    expect(find.byType(WallpaperSelectorSurface), findsNothing);
    expect(find.byType(PageView), findsNothing);
    final search = tester.widget<WallpaperSearchField>(
      find.byType(WallpaperSearchField),
    );
    expect(search.focusNode.hasFocus, isFalse);
    final input = harness.container.read(shellInteractionRegistryProvider);
    expect(input.capturesFullScene, isTrue);
    expect(input.capturesKeyboard, isTrue);
    expect(input.compositorExclusive, isTrue);
    expect(tester.takeException(), isNull);

    await tester.tap(
      find.bySemanticsLabel(
        tester
            .element(find.byType(MobileWallpaperSelectorSurface))
            .l10n
            .wallpaperCloseSelector,
      ),
    );
    await tester.pump();
    expect(harness.state.selectorVisible, isFalse);
  });

  testWidgets(
    'mobile selector hides every control and restores on background tap',
    (tester) async {
      final temporary = Directory(
        '${Directory.systemTemp.path}/denial-mobile-wallpaper-preview-'
        '${DateTime.now().microsecondsSinceEpoch}',
      )..createSync(recursive: true);
      addTearDown(() => temporary.deleteSync(recursive: true));
      final harness = WallpaperControllerTestHarness(
        sources: const <WallpaperProvider>[],
        store: WallpaperStore(
          RuntimePaths(environment: <String, String>{'HOME': temporary.path}),
        ),
      );
      addTearDown(harness.container.dispose);
      harness.controller.openSelector(targetPixelSize: const Size(1264, 2780));

      await tester.pumpWidget(
        DenialLocalizationScope(
          locale: const Locale('en'),
          child: UncontrolledProviderScope(
            container: harness.container,
            child: const ShellTheme(
              data: ShellThemeData(),
              child: MediaQuery(
                data: MediaQueryData(size: Size(420, 840)),
                child: MobileWallpaperSelectorLayer(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final l10n = tester
          .element(find.byType(MobileWallpaperSelectorSurface))
          .l10n;

      await tester.tap(find.bySemanticsLabel(l10n.wallpaperMobileHideControls));
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('mobile-wallpaper-preview-only')),
        findsOneWidget,
      );
      expect(find.byType(WallpaperSearchField), findsNothing);
      expect(find.text(l10n.wallpaperMobileTitle), findsNothing);

      await tester.tapAt(const Offset(210, 420));
      await tester.pump();

      expect(find.byType(WallpaperSearchField), findsOneWidget);
      expect(find.text(l10n.wallpaperMobileTitle), findsOneWidget);
    },
  );

  testWidgets(
    'mobile positioning supports drag, fine adjustment, and centering',
    (tester) async {
      final temporary = Directory(
        '${Directory.systemTemp.path}/denial-mobile-wallpaper-position-'
        '${DateTime.now().microsecondsSinceEpoch}',
      )..createSync(recursive: true);
      addTearDown(() => temporary.deleteSync(recursive: true));
      final candidate = WallpaperCandidate(
        id: 'default',
        providerId: 'fixed',
        label: 'Default',
        previewUri: Uri(scheme: 'asset', path: defaultShellWallpaperAsset),
        width: 2400,
        height: 1200,
        resource: WallpaperResource.defaultWallpaper,
      );
      final harness = WallpaperControllerTestHarness(
        sources: <WallpaperProvider>[_FixedWallpaperProvider(candidate)],
        store: WallpaperStore(
          RuntimePaths(environment: <String, String>{'HOME': temporary.path}),
        ),
      );
      addTearDown(harness.container.dispose);
      harness.controller.openSelector(targetPixelSize: const Size(1264, 2780));

      await tester.pumpWidget(
        DenialLocalizationScope(
          locale: const Locale('en'),
          child: UncontrolledProviderScope(
            container: harness.container,
            child: const ShellTheme(
              data: ShellThemeData(),
              child: MediaQuery(
                data: MediaQueryData(size: Size(420, 840)),
                child: MobileWallpaperSelectorLayer(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final l10n = tester
          .element(find.byType(MobileWallpaperSelectorSurface))
          .l10n;

      expect(
        find.byKey(const ValueKey<String>('mobile-wallpaper-candidates')),
        findsOneWidget,
      );
      await tester.tap(find.bySemanticsLabel(l10n.wallpaperMobilePosition));
      await tester.pump();

      final gesture = await tester.startGesture(const Offset(200, 320));
      await gesture.moveBy(const Offset(50, 0));
      await gesture.up();
      await tester.pump();
      expect(harness.state.assignment.spanAlignment.x, lessThan(0.0));

      final horizontal = tester.getRect(find.byType(RangeBar).first);
      await tester.tapAt(
        Offset(horizontal.left + horizontal.width * 0.75, horizontal.center.dy),
      );
      await tester.pump();
      expect(harness.state.assignment.spanAlignment.x, closeTo(0.5, 0.02));

      await tester.tap(
        find.bySemanticsLabel(l10n.wallpaperMobileCenterPosition),
      );
      await tester.pump();
      expect(
        harness.state.assignment.spanAlignment,
        const WallpaperSpanAlignment(),
      );

      await tester.tap(find.bySemanticsLabel(l10n.wallpaperMobileHideControls));
      await tester.pump();
      expect(find.byType(RangeBar), findsNothing);
      await tester.tapAt(const Offset(210, 420));
      await tester.pump();
      expect(find.byType(RangeBar), findsNWidgets(2));
    },
  );

  testWidgets(
    'open keyboard pans the mobile selector and survives outside taps',
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(420, 840);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final temporary = Directory(
        '${Directory.systemTemp.path}/denial-mobile-wallpaper-keyboard-'
        '${DateTime.now().microsecondsSinceEpoch}',
      )..createSync(recursive: true);
      addTearDown(() => temporary.deleteSync(recursive: true));
      final harness = WallpaperControllerTestHarness(
        sources: const <WallpaperProvider>[],
        store: WallpaperStore(
          RuntimePaths(environment: <String, String>{'HOME': temporary.path}),
        ),
      );
      addTearDown(harness.container.dispose);
      harness.container.read(shellControllerProvider.notifier).openEdgePanel();
      harness.controller.openSelector(targetPixelSize: const Size(1264, 2780));

      await tester.pumpWidget(
        DenialLocalizationScope(
          locale: const Locale('en'),
          child: UncontrolledProviderScope(
            container: harness.container,
            child: const ShellTheme(
              data: ShellThemeData(),
              child: MediaQuery(
                data: MediaQueryData(size: Size(420, 840)),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _KeyboardDismissingUnderlay(),
                    MobileWallpaperSelectorLayer(),
                    MobileSystemKeyboardLayer(),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      final selector = find.byType(MobileWallpaperSelectorSurface);
      final initialTop = tester.getTopLeft(selector).dy;
      final gesture = await tester.startGesture(const Offset(419, 120));
      await gesture.moveBy(const Offset(0, 120));
      await tester.pump();

      expect(tester.getTopLeft(selector).dy, greaterThan(initialTop + 100));
      await gesture.up();

      final search = tester.widget<WallpaperSearchField>(
        find.byType(WallpaperSearchField),
      );
      search.focusNode.requestFocus();
      await tester.pump();
      expect(search.focusNode.hasFocus, isTrue);

      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      expect(search.focusNode.hasFocus, isTrue);
      expect(
        harness.container.read(shellControllerProvider).edgePanelVisible,
        isTrue,
      );
      expect(harness.state.selectorVisible, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('only the close control dismisses the selector', (tester) async {
    final temporary = Directory(
      '${Directory.systemTemp.path}/denial-wallpaper-widget-'
      '${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    addTearDown(() => temporary.deleteSync(recursive: true));
    final harness = WallpaperControllerTestHarness(
      sources: const <WallpaperProvider>[],
      store: WallpaperStore(
        RuntimePaths(environment: <String, String>{'HOME': temporary.path}),
      ),
    );
    var dismissed = false;

    await tester.pumpWidget(
      DenialLocalizationScope(
        locale: const Locale('en'),
        child: UncontrolledProviderScope(
          container: harness.container,
          child: MediaQuery(
            data: const MediaQueryData(size: Size(800, 700)),
            child: WallpaperSelectorOverlay(
              visible: true,
              displayRect: const Rect.fromLTWH(150, 80, 500, 560),
              onDismiss: () => dismissed = true,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    final l10n = tester.element(find.byType(WallpaperSelectorOverlay)).l10n;

    await tester.tapAt(const Offset(30, 30));
    await tester.pump();

    expect(dismissed, isFalse);

    await tester.tap(find.bySemanticsLabel(l10n.wallpaperCloseSelector));
    await tester.pump();

    expect(dismissed, isTrue);
    harness.container.dispose();
  });

  testWidgets('target controls expose All and every monitor', (tester) async {
    WallpaperTarget? selected;
    final outputs = <DisplayOutput>[
      const DisplayOutput(
        monitorId: 0,
        name: 'DP-4',
        logicalRect: Rect.fromLTWH(2560, 0, 2560, 1440),
        pixelSize: Size(2560, 1440),
        scale: 1,
        refreshRate: 180,
      ),
      const DisplayOutput(
        monitorId: 1,
        name: 'DP-5',
        logicalRect: Rect.fromLTWH(0, 0, 2560, 1440),
        pixelSize: Size(2560, 1440),
        scale: 1,
        refreshRate: 200,
      ),
    ];

    await tester.pumpWidget(
      DenialLocalizationScope(
        locale: const Locale('en'),
        child: WallpaperTargetSelector(
          outputs: outputs,
          selected: const WallpaperTarget.all(),
          onSelected: (target) => selected = target,
        ),
      ),
    );
    final l10n = tester.element(find.byType(WallpaperTargetSelector)).l10n;

    expect(find.text(l10n.wallpaperAllDisplays), findsOneWidget);
    expect(find.text('DP-5'), findsOneWidget);
    expect(find.text('DP-4'), findsOneWidget);

    await tester.tap(find.text('DP-4'));
    await tester.pump();

    expect(selected, const WallpaperTarget.output('DP-4'));
  });

  testWidgets('span alignment controls preview and commit both axes', (
    tester,
  ) async {
    var alignment = const WallpaperSpanAlignment();
    var committed = const WallpaperSpanAlignment();

    await tester.pumpWidget(
      DenialLocalizationScope(
        locale: const Locale('en'),
        child: StatefulBuilder(
          builder: (context, setState) => WallpaperSpanAlignmentSelector(
            value: alignment,
            onChanged: (value) => setState(() => alignment = value),
            onChangeEnd: (value) => committed = value,
          ),
        ),
      ),
    );
    final l10n = tester
        .element(find.byType(WallpaperSpanAlignmentSelector))
        .l10n;

    final sliders = find.byType(RangeBar);
    expect(sliders, findsNWidgets(2));

    final horizontal = tester.getRect(sliders.first);
    await tester.tapAt(
      Offset(horizontal.left + horizontal.width * 0.75, horizontal.center.dy),
    );
    await tester.pump();

    final vertical = tester.getRect(sliders.last);
    await tester.tapAt(
      Offset(vertical.left + vertical.width * 0.25, vertical.center.dy),
    );
    await tester.pump();

    expect(alignment, const WallpaperSpanAlignment.precise(x: 0.5, y: -0.5));
    expect(committed, alignment);

    await tester.tap(find.bySemanticsLabel(l10n.wallpaperMobileCenterPosition));
    await tester.pump();

    expect(alignment, const WallpaperSpanAlignment());
    expect(committed, alignment);
  });

  testWidgets('darkness control previews, commits, and exposes semantics', (
    tester,
  ) async {
    var value = 0.25;
    var committed = -1.0;

    await tester.pumpWidget(
      DenialLocalizationScope(
        locale: const Locale('en'),
        child: MediaQuery(
          data: const MediaQueryData(size: Size(800, 600)),
          child: StatefulBuilder(
            builder: (context, setState) => Center(
              child: SizedBox(
                width: 600,
                child: WallpaperDarknessControl(
                  value: value,
                  onChanged: (next) => setState(() => value = next),
                  onChangeEnd: (next) => committed = next,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final l10n = tester.element(find.byType(WallpaperDarknessControl)).l10n;

    expect(find.bySemanticsLabel(l10n.wallpaperDarkness), findsOneWidget);
    final trackRect = tester.getRect(find.byType(RangeBar));
    await tester.tapAt(
      Offset(trackRect.left + trackRect.width * 0.75, trackRect.center.dy),
    );
    await tester.pump();

    expect(value, closeTo(0.75, 0.01));
    expect(committed, closeTo(0.75, 0.01));
    expect(find.text(l10n.settingsPercent(75)), findsOneWidget);
  });
}

class _FixedWallpaperProvider implements WallpaperProvider {
  const _FixedWallpaperProvider(this.candidate);

  final WallpaperCandidate candidate;

  @override
  String get id => 'fixed';

  @override
  String get displayName => 'Fixed';

  @override
  Future<WallpaperPage> search(WallpaperQuery query) async {
    return WallpaperPage(
      items: <WallpaperCandidate>[candidate],
      page: query.page,
      hasMore: false,
    );
  }

  @override
  Future<WallpaperResource> materialize(
    WallpaperCandidate candidate, {
    WallpaperDownloadProgress? onProgress,
  }) async {
    onProgress?.call(1.0);
    return candidate.resource!;
  }

  @override
  void dispose() {}
}

const _desktopDisplayLayout = DisplayLayout(
  epoch: 1,
  globalOrigin: Offset.zero,
  logicalSize: Size(500, 800),
  pixelSize: Size(500, 800),
  engineScale: 1,
  tickerMonitorId: 0,
  systemBarMonitorId: 0,
  systemBarSide: SystemBarSide.top,
  outputs: <DisplayOutput>[
    DisplayOutput(
      monitorId: 0,
      name: 'DP-4',
      logicalRect: Rect.fromLTWH(0, 0, 500, 800),
      pixelSize: Size(500, 800),
      scale: 1,
      refreshRate: 60,
    ),
  ],
);

class _KeyboardDismissingUnderlay extends ConsumerWidget {
  const _KeyboardDismissingUnderlay();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: ref.read(shellControllerProvider.notifier).closeEdgePanel,
      child: const SizedBox.expand(),
    );
  }
}
