import 'package:denial_dart_shell/src/desktop/system_tray_module.dart';
import 'package:denial_dart_shell/src/input/shell_interaction_registry.dart';
import 'package:denial_dart_shell/src/models/system_tray_item.dart';
import 'package:denial_dart_shell/src/theme/shell_color_scheme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const active = SystemTrayItem(
    id: 'status-notifier:org.example.App/StatusNotifierItem',
    source: SystemTrayItemSource.statusNotifier,
    title: 'Example App',
    status: SystemTrayStatus.active,
    iconName: '',
    iconThemePath: '',
    iconPixmap: null,
    menuAvailable: true,
    primaryOpensMenu: false,
  );

  testWidgets('exposes status and dispatches primary, secondary, and menu', (
    tester,
  ) async {
    final invocations = <(SystemTrayAction, Offset)>[];
    await _pumpTray(
      tester,
      items: const <SystemTrayItem>[active],
      onInvoke: (item, action, position) {
        expect(item, same(active));
        invocations.add((action, position));
        return true;
      },
    );

    final button = find.byKey(systemTrayItemButtonKey(active.id));
    expect(button, findsOneWidget);
    expect(find.bySemanticsLabel('Example App'), findsOneWidget);

    await tester.tap(button);
    await tester.tap(button, buttons: kMiddleMouseButton);
    await tester.tap(button, buttons: kSecondaryMouseButton);

    expect(invocations.map((invocation) => invocation.$1), <SystemTrayAction>[
      SystemTrayAction.activate,
      SystemTrayAction.secondaryActivate,
      SystemTrayAction.contextMenu,
    ]);
    expect(invocations.every((invocation) => invocation.$2.isFinite), isTrue);
  });

  testWidgets('hovering a tray icon does not show a label popup', (
    tester,
  ) async {
    await _pumpTray(
      tester,
      items: const <SystemTrayItem>[active],
      onInvoke: (_, _, _) => true,
    );

    final button = find.byKey(systemTrayItemButtonKey(active.id));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(button));
    await tester.pump(const Duration(seconds: 1));

    expect(find.byTooltip('Example App'), findsNothing);
    expect(find.text('Example App'), findsNothing);
    expect(find.bySemanticsLabel('Example App'), findsOneWidget);
  });

  testWidgets('attention state is visible without keyboard activation', (
    tester,
  ) async {
    final actions = <SystemTrayAction>[];
    final item = SystemTrayItem(
      id: 'xembed:42',
      source: SystemTrayItemSource.xEmbed,
      title: 'Legacy icon',
      status: SystemTrayStatus.needsAttention,
      iconName: '',
      iconThemePath: '',
      iconPixmap: SystemTrayIconPixmap(
        width: 1,
        height: 1,
        rgba: Uint8List.fromList(<int>[255, 80, 40, 255]),
      ),
      menuAvailable: true,
      primaryOpensMenu: false,
    );
    await _pumpTray(
      tester,
      items: <SystemTrayItem>[item],
      onInvoke: (_, action, _) {
        actions.add(action);
        return true;
      },
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();

    final semantics = find.bySemanticsLabel('Legacy icon');
    expect(semantics, findsOneWidget);
    expect(tester.getSemantics(semantics).value, 'Needs attention');
    expect(find.byType(RawImage), findsOneWidget);
    final button = find.byKey(systemTrayItemButtonKey(item.id));
    final focusable = find.descendant(
      of: button,
      matching: find.byType(FocusableActionDetector),
    );
    expect(focusable, findsNothing);
    await tester.tap(button);
    await tester.pump();
    expect(
      find.descendant(of: button, matching: find.byType(AnimatedContainer)),
      findsNothing,
    );
    expect(
      tester.getSize(find.byKey(systemTrayItemIconKey(item.id))),
      const Size.square(18),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f10);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    expect(actions, <SystemTrayAction>[SystemTrayAction.activate]);
  });

  testWidgets('menu-only items open their menu on primary activation', (
    tester,
  ) async {
    final actions = <SystemTrayAction>[];
    const item = SystemTrayItem(
      id: 'status-notifier:org.example.Menu/StatusNotifierItem',
      source: SystemTrayItemSource.statusNotifier,
      title: 'Menu indicator',
      status: SystemTrayStatus.active,
      iconName: '',
      iconThemePath: '',
      iconPixmap: null,
      menuAvailable: true,
      primaryOpensMenu: true,
    );
    await _pumpTray(
      tester,
      items: const <SystemTrayItem>[item],
      onInvoke: (_, action, _) {
        actions.add(action);
        return true;
      },
    );

    await tester.tap(find.byKey(systemTrayItemButtonKey(item.id)));
    await tester.pumpAndSettle();
    expect(actions, <SystemTrayAction>[SystemTrayAction.contextMenu]);
  });

  testWidgets('outside hover and click pass through while menu dismisses', (
    tester,
  ) async {
    final selected = <int>[];
    var backgroundHovers = 0;
    var backgroundPresses = 0;
    await _pumpTray(
      tester,
      items: const <SystemTrayItem>[active],
      onInvoke: (_, _, _) => true,
      onLoadMenu: (_) async => const <SystemTrayMenuEntry>[
        SystemTrayMenuEntry(
          id: 31,
          label: 'Library',
          enabled: true,
          visible: true,
          separator: false,
          toggleType: SystemTrayMenuToggleType.none,
          toggleState: 0,
          destructive: false,
          children: <SystemTrayMenuEntry>[],
        ),
      ],
      onInvokeMenu: (_, id) {
        selected.add(id);
        return true;
      },
      background: MouseRegion(
        onHover: (_) => backgroundHovers += 1,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) => backgroundPresses += 1,
          child: const SizedBox.expand(),
        ),
      ),
    );

    final button = find.byKey(systemTrayItemButtonKey(active.id));
    await tester.tap(button, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('Library'), findsOneWidget);
    expect(find.byKey(systemTrayMenuDismissLayerKey), findsOneWidget);
    final regions = tester
        .widgetList<ShellInputRegion>(find.byType(ShellInputRegion))
        .toList(growable: false);
    final dismissal = regions.singleWhere(
      (region) => region.debugLabel == 'System tray menu dismissal',
    );
    expect(dismissal.active, isTrue);
    expect(dismissal.pointerPolicy, ShellPointerPolicy.none);
    expect(dismissal.observeClientPointerPresses, isTrue);
    expect(
      regions.any(
        (region) =>
            region.debugLabel == 'System tray menu entry' &&
            region.pointerPolicy == ShellPointerPolicy.childBounds,
      ),
      isTrue,
    );
    expect(
      regions.any(
        (region) => region.pointerPolicy == ShellPointerPolicy.fullScene,
      ),
      isFalse,
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(4, 4));
    await tester.pump();
    await mouse.moveTo(const Offset(8, 8));
    await tester.pump();
    expect(backgroundHovers, greaterThan(0));

    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(find.text('Library'), findsNothing);
    expect(backgroundPresses, 1);
    expect(
      tester
          .widgetList<ShellInputRegion>(find.byType(ShellInputRegion))
          .singleWhere(
            (region) => region.debugLabel == 'System tray menu dismissal',
          )
          .active,
      isFalse,
    );
    expect(selected, isEmpty);
    await mouse.removePointer();
  });

  testWidgets('presses inside the popup are excluded from global dismissal', (
    tester,
  ) async {
    await _pumpTray(
      tester,
      items: const <SystemTrayItem>[active],
      onInvoke: (_, _, _) => true,
      onLoadMenu: (_) async => const <SystemTrayMenuEntry>[
        SystemTrayMenuEntry(
          id: 31,
          label: 'Unavailable',
          enabled: false,
          visible: true,
          separator: false,
          toggleType: SystemTrayMenuToggleType.none,
          toggleState: 0,
          destructive: false,
          children: <SystemTrayMenuEntry>[],
        ),
      ],
    );

    await tester.tap(
      find.byKey(systemTrayItemButtonKey(active.id)),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('Unavailable'), findsOneWidget);

    await tester.tap(find.text('Unavailable'));
    await tester.pumpAndSettle();

    expect(find.text('Unavailable'), findsOneWidget);
  });

  testWidgets('foreground Flutter surfaces receive clicks and dismiss menu', (
    tester,
  ) async {
    final screenshotVisible = ValueNotifier<bool>(false);
    addTearDown(screenshotVisible.dispose);
    var screenshotPointerDowns = 0;
    await _pumpTray(
      tester,
      items: const <SystemTrayItem>[active],
      onInvoke: (_, _, _) => true,
      onLoadMenu: (_) async => const <SystemTrayMenuEntry>[
        SystemTrayMenuEntry(
          id: 31,
          label: 'Settings',
          enabled: true,
          visible: true,
          separator: false,
          toggleType: SystemTrayMenuToggleType.none,
          toggleState: 0,
          destructive: false,
          children: <SystemTrayMenuEntry>[],
        ),
      ],
      foreground: ValueListenableBuilder<bool>(
        valueListenable: screenshotVisible,
        builder: (context, visible, child) => IgnorePointer(
          ignoring: !visible,
          child: Listener(
            key: const ValueKey<String>('mock-screenshot-selection'),
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) => screenshotPointerDowns += 1,
            child: child,
          ),
        ),
        child: const ColoredBox(color: Color(0x33000000)),
      ),
    );

    await tester.tap(
      find.byKey(systemTrayItemButtonKey(active.id)),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);

    screenshotVisible.value = true;
    await tester.pump();
    expect(find.text('Settings'), findsOneWidget);
    await tester.tapAt(tester.getCenter(find.text('Settings')));
    await tester.pumpAndSettle();

    expect(screenshotPointerDowns, 1);
    expect(find.text('Settings'), findsNothing);
  });

  testWidgets('application menu uses compact Denial styling', (tester) async {
    await _pumpTray(
      tester,
      items: const <SystemTrayItem>[active],
      onInvoke: (_, _, _) => true,
      onLoadMenu: (_) async => const <SystemTrayMenuEntry>[
        SystemTrayMenuEntry(
          id: 31,
          label: 'Settings',
          enabled: true,
          visible: true,
          separator: false,
          toggleType: SystemTrayMenuToggleType.none,
          toggleState: 0,
          destructive: false,
          children: <SystemTrayMenuEntry>[],
        ),
      ],
    );

    await tester.tap(
      find.byKey(systemTrayItemButtonKey(active.id)),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    final anchor = tester.widget<MenuAnchor>(find.byType(MenuAnchor));
    expect(
      anchor.style!.backgroundColor!.resolve(const <WidgetState>{}),
      ShellColorScheme.dark.panelBackgroundBottom,
    );
    final entrySize = tester.getSize(
      find.byKey(systemTrayMenuEntryButtonKey(31)),
    );
    expect(entrySize.height, 28);
    expect(entrySize.width, lessThanOrEqualTo(320));
    final entryRect = tester.getRect(
      find.byKey(systemTrayMenuEntryButtonKey(31)),
    );
    final labelBoxRect = tester.getRect(
      find.byKey(systemTrayMenuEntryLabelKey(31)),
    );
    final textRect = tester.getRect(find.text('Settings'));
    expect(textRect.height, greaterThan(12));
    expect(labelBoxRect.top, greaterThanOrEqualTo(entryRect.top + 4));
    expect(labelBoxRect.bottom, lessThanOrEqualTo(entryRect.bottom - 4));
    expect(textRect.top, greaterThanOrEqualTo(labelBoxRect.top + 2));
    expect(textRect.bottom, lessThanOrEqualTo(labelBoxRect.bottom - 2));
  });

  testWidgets('every tray icon uses the same visual footprint', (tester) async {
    final raw = SystemTrayItem(
      id: 'xembed:99',
      source: SystemTrayItemSource.xEmbed,
      title: 'Raw icon',
      status: SystemTrayStatus.active,
      iconName: '',
      iconThemePath: '',
      iconPixmap: SystemTrayIconPixmap(
        width: 2,
        height: 1,
        rgba: Uint8List.fromList(<int>[255, 255, 255, 255, 255, 255, 255, 255]),
      ),
      menuAvailable: false,
      primaryOpensMenu: false,
    );
    await _pumpTray(
      tester,
      items: <SystemTrayItem>[active, raw],
      onInvoke: (_, _, _) => true,
    );

    expect(
      tester.getSize(find.byKey(systemTrayItemIconKey(active.id))),
      const Size.square(18),
    );
    expect(
      tester.getSize(find.byKey(systemTrayItemIconKey(raw.id))),
      const Size.square(18),
    );
  });

  testWidgets('menu selection dispatches the application entry id', (
    tester,
  ) async {
    final selected = <int>[];
    await _pumpTray(
      tester,
      items: const <SystemTrayItem>[active],
      onInvoke: (_, _, _) => true,
      onLoadMenu: (_) async => const <SystemTrayMenuEntry>[
        SystemTrayMenuEntry(
          id: 43,
          label: 'Exit Steam',
          enabled: true,
          visible: true,
          separator: false,
          toggleType: SystemTrayMenuToggleType.none,
          toggleState: 0,
          destructive: true,
          children: <SystemTrayMenuEntry>[],
        ),
      ],
      onInvokeMenu: (_, id) {
        selected.add(id);
        return true;
      },
    );

    await tester.tap(
      find.byKey(systemTrayItemButtonKey(active.id)),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Exit Steam'));
    await tester.pumpAndSettle();

    expect(selected, <int>[43]);
    expect(find.text('Exit Steam'), findsNothing);
  });

  testWidgets('primary click falls back to an exported menu', (tester) async {
    final actions = <SystemTrayAction>[];
    const steam = SystemTrayItem(
      id: 'status-notifier:steam/NotificationItem/steam',
      source: SystemTrayItemSource.statusNotifier,
      title: 'Steam',
      status: SystemTrayStatus.active,
      iconName: 'steam',
      iconThemePath: '',
      iconPixmap: null,
      menuAvailable: true,
      primaryOpensMenu: false,
      menuPath: '/org/ayatana/NotificationItem/steam/Menu',
    );
    await _pumpTray(
      tester,
      items: const <SystemTrayItem>[steam],
      onInvoke: (_, action, _) {
        actions.add(action);
        return false;
      },
      onLoadMenu: (_) async => const <SystemTrayMenuEntry>[
        SystemTrayMenuEntry(
          id: 29,
          label: 'Store',
          enabled: true,
          visible: true,
          separator: false,
          toggleType: SystemTrayMenuToggleType.none,
          toggleState: 0,
          destructive: false,
          children: <SystemTrayMenuEntry>[],
        ),
      ],
    );

    await tester.tap(find.byKey(systemTrayItemButtonKey(steam.id)));
    await tester.pumpAndSettle();

    expect(actions, <SystemTrayAction>[SystemTrayAction.activate]);
    expect(find.text('Store'), findsOneWidget);
  });
}

Future<void> _pumpTray(
  WidgetTester tester, {
  required List<SystemTrayItem> items,
  required SystemTrayInvoke onInvoke,
  SystemTrayMenuLoader? onLoadMenu,
  SystemTrayMenuInvoke? onInvokeMenu,
  Widget? background,
  Widget? foreground,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              _TestDesktopSceneOverlay(
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    if (background != null) Positioned.fill(child: background),
                    const SystemTrayMenuDismissLayer(),
                    Center(
                      child: SystemTrayModule(
                        horizontal: true,
                        accent: const Color(0xff64d8cb),
                        items: items,
                        onInvoke: onInvoke,
                        onLoadMenu: onLoadMenu ?? (_) async => null,
                        onInvokeMenu: onInvokeMenu ?? (_, _) => true,
                      ),
                    ),
                  ],
                ),
              ),
              if (foreground != null) Positioned.fill(child: foreground),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _TestDesktopSceneOverlay extends StatefulWidget {
  const _TestDesktopSceneOverlay({required this.child});

  final Widget child;

  @override
  State<_TestDesktopSceneOverlay> createState() =>
      _TestDesktopSceneOverlayState();
}

class _TestDesktopSceneOverlayState extends State<_TestDesktopSceneOverlay> {
  late final OverlayEntry _entry;

  @override
  void initState() {
    super.initState();
    _entry = OverlayEntry(builder: (_) => widget.child);
  }

  @override
  void didUpdateWidget(covariant _TestDesktopSceneOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    _entry.markNeedsBuild();
  }

  @override
  void dispose() {
    _entry.remove();
    _entry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Overlay(initialEntries: <OverlayEntry>[_entry]);
  }
}
