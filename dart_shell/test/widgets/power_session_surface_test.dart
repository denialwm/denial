import 'dart:async';
import 'dart:ui' show SemanticsRole;

import 'package:denial_dart_shell/src/models/display_layout.dart';
import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:denial_dart_shell/src/services/logind_service.dart';
import 'package:denial_dart_shell/src/state/session_power.dart';
import 'package:denial_dart_shell/src/state/shell_controller.dart';
import 'package:denial_dart_shell/src/theme/tokens.dart';
import 'package:denial_dart_shell/src/widgets/session/power_session_surface.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('service loss is honest while local actions remain available', (
    tester,
  ) async {
    final logind = _FakeLogind(LogindSnapshot.unavailable());
    final runtime = _FakeRuntime();
    final harness = _Harness(logind: logind, runtime: runtime);
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build());
    await tester.pump();
    final l10n = tester.element(find.byType(PowerSessionSurface)).l10n;

    expect(
      _surfaceSemantics(tester, l10n.powerSessionSemantics).properties.role,
      SemanticsRole.dialog,
    );

    expect(find.byKey(const ValueKey('session-power-unavailable')), findsOne);
    expect(find.text(l10n.powerPermissionUnavailable), findsNWidgets(4));

    await tester.tap(find.text(l10n.powerActionSuspend));
    await tester.pump();
    expect(logind.actions, isEmpty);

    await tester.tap(find.text(l10n.powerActionLock));
    await tester.pump();
    expect(runtime.lockCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('logout confirmation can be cancelled and accepted once', (
    tester,
  ) async {
    final logind = _FakeLogind(_snapshot());
    final runtime = _FakeRuntime();
    final harness = _Harness(logind: logind, runtime: runtime);
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build());
    await tester.pump();
    final l10n = tester.element(find.byType(PowerSessionSurface)).l10n;

    await tester.ensureVisible(find.text(l10n.powerActionLogOut));
    await tester.tap(find.text(l10n.powerActionLogOut));
    await tester.pumpAndSettle();
    expect(find.text(l10n.powerConfirmLogOutTitle), findsOne);
    expect(
      _surfaceSemantics(tester, l10n.powerSessionSemantics).properties.role,
      SemanticsRole.alertDialog,
    );
    expect(runtime.logoutCalls, 0);

    await tester.tap(find.text(l10n.actionCancel));
    await tester.pumpAndSettle();
    expect(find.text(l10n.powerConfirmLogOutTitle), findsNothing);
    expect(runtime.logoutCalls, 0);

    await tester.ensureVisible(find.text(l10n.powerActionLogOut));
    await tester.tap(find.text(l10n.powerActionLogOut));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.powerActionLogOut));
    await tester.pump(const Duration(milliseconds: 2));
    expect(runtime.logoutCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('inhibitors, authorization, and enlarged text stay legible', (
    tester,
  ) async {
    final blocker = LogindInhibitor(
      what: <String>{'sleep'},
      who: 'Game',
      why: 'Saving progress',
      mode: 'block',
      uid: 1000,
      pid: 42,
    );
    final logind = _FakeLogind(
      _snapshot(
        suspend: LogindCapability.authenticationRequired,
        inhibitors: <LogindInhibitor>[blocker],
      ),
    );
    final harness = _Harness(logind: logind, runtime: _FakeRuntime());
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.build(size: const Size(420, 650), textScale: 1.6),
    );
    await tester.pump();
    final l10n = tester.element(find.byType(PowerSessionSurface)).l10n;

    expect(
      find.text(l10n.powerBlockedBy(blocker.description)),
      findsNWidgets(2),
    );
    await tester.tap(find.text(l10n.powerActionSuspend));
    await tester.pump();
    expect(logind.actions, isEmpty);
    expect(tester.takeException(), isNull);

    logind.emit(_snapshot(suspend: LogindCapability.authenticationRequired));
    await tester.pump();
    expect(
      find.text(
        l10n.powerAuthenticationRequired(l10n.powerActionSuspendDescription),
      ),
      findsOne,
    );
    expect(tester.takeException(), isNull);
  });
}

Semantics _surfaceSemantics(WidgetTester tester, String label) {
  return tester.widget<Semantics>(
    find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.label == label,
    ),
  );
}

class _Harness {
  _Harness({required this.logind, required this.runtime});

  final _FakeLogind logind;
  final _FakeRuntime runtime;
  final _LayoutBridge layoutBridge = _LayoutBridge();
  late final ProviderContainer container = ProviderContainer.test(
    overrides: [
      logindServiceProvider.overrideWithValue(logind),
      sessionRuntimeBackendProvider.overrideWithValue(runtime),
      sessionLogoutWatchdogProvider.overrideWithValue(
        const Duration(milliseconds: 1),
      ),
      denialBridgeProvider.overrideWithValue(layoutBridge),
    ],
  );

  Widget build({Size size = const Size(700, 760), double textScale = 1}) {
    return UncontrolledProviderScope(
      container: container,
      child: DenialLocalizationScope(
        locale: const Locale('en'),
        child: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
          ),
          child: DefaultTextStyle(
            style: ShellText.base,
            child: SizedBox.fromSize(
              size: size,
              child: Overlay(
                initialEntries: <OverlayEntry>[
                  OverlayEntry(
                    builder: (_) => PowerSessionSurface(onClose: _noop),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> dispose() async {
    layoutBridge.dispose();
    await logind.dispose();
  }
}

void _noop() {}

class _FakeLogind implements LogindBackend {
  _FakeLogind(this._current);

  final StreamController<LogindSnapshot> _snapshots =
      StreamController<LogindSnapshot>.broadcast(sync: true);
  LogindSnapshot _current;
  final List<LogindAction> actions = <LogindAction>[];

  @override
  LogindSnapshot get currentSnapshot => _current;

  @override
  Stream<LogindSnapshot> get snapshots => _snapshots.stream;

  void emit(LogindSnapshot snapshot) {
    _current = snapshot;
    _snapshots.add(snapshot);
  }

  @override
  Future<void> start() async => emit(_current);

  @override
  Future<void> refresh() async => emit(_current);

  @override
  Future<void> perform(LogindAction action) async => actions.add(action);

  @override
  Future<void> dispose() => _snapshots.close();
}

class _FakeRuntime implements SessionRuntimeBackend {
  int lockCalls = 0;
  int logoutCalls = 0;

  @override
  void lock() => lockCalls += 1;

  @override
  bool requestLogout() {
    logoutCalls += 1;
    return true;
  }
}

class _LayoutBridge extends DenialBridge {
  @override
  Future<DisplayLayout?> getDisplayLayout() async => _layout;
}

LogindSnapshot _snapshot({
  LogindCapability suspend = LogindCapability.available,
  List<LogindInhibitor> inhibitors = const <LogindInhibitor>[],
}) {
  return LogindSnapshot(
    serviceAvailable: true,
    capabilities: <LogindAction, LogindCapability>{
      LogindAction.suspend: suspend,
      LogindAction.hibernate: LogindCapability.available,
      LogindAction.reboot: LogindCapability.available,
      LogindAction.powerOff: LogindCapability.available,
    },
    inhibitors: inhibitors,
  );
}

const DisplayLayout _layout = DisplayLayout(
  epoch: 1,
  globalOrigin: Offset.zero,
  logicalSize: Size(700, 760),
  pixelSize: Size(700, 760),
  engineScale: 1,
  tickerMonitorId: 1,
  systemBarMonitorId: 1,
  systemBarSide: SystemBarSide.left,
  outputs: <DisplayOutput>[
    DisplayOutput(
      monitorId: 1,
      name: 'main',
      logicalRect: Rect.fromLTWH(0, 0, 700, 760),
      pixelSize: Size(700, 760),
      scale: 1,
      refreshRate: 60,
    ),
  ],
);
