import 'package:denial_dart_shell/src/local_apps/local_flutter_application.dart';
import 'package:denial_dart_shell/src/local_apps/local_flutter_window_host.dart';
import 'package:denial_dart_shell/src/models/denial_window.dart';
import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:denial_dart_shell/src/widgets/desktop_window_snapshot.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registry accepts arbitrary descriptors and rejects duplicate ids', () {
    final first = _application('dev.denial.notes', 'Notes');
    final second = _application('dev.denial.paint', 'Paint');
    final registry = LocalFlutterApplicationRegistry(<LocalFlutterApplication>[
      first,
      second,
    ]);

    expect(registry['dev.denial.notes'], same(first));
    expect(registry['dev.denial.paint'], same(second));
    expect(registry.applications, hasLength(2));
    expect(
      () => LocalFlutterApplicationRegistry(<LocalFlutterApplication>[
        first,
        _application('dev.denial.notes', 'Duplicate'),
      ]),
      throwsArgumentError,
    );
  });

  test('single-instance launch updates geometry before focusing', () {
    final application = _application('dev.denial.counter', 'Counter');
    final window = _localWindow(title: 'Counter');
    final bridge = _LauncherBridge();
    DenialWindow? focused;
    final launcher = LocalFlutterApplicationLauncher(
      registry: LocalFlutterApplicationRegistry(<LocalFlutterApplication>[
        application,
      ]),
      bridge: bridge,
      windows: () => <DenialWindow>[window],
      focus: (value) => focused = value,
    );
    const geometry = Rect.fromLTWH(0, 48, 420, 792);

    final launched = launcher.launch(
      application.id,
      availableBounds: const Offset(0, 0) & Size(420, 840),
      geometry: geometry,
    );

    expect(launched, isTrue);
    expect(bridge.configuredWindow, same(window));
    expect(bridge.configuredGeometry, geometry);
    expect(focused, same(window));
  });

  testWidgets('local host preserves application state across window updates', (
    tester,
  ) async {
    final application = LocalFlutterApplication(
      id: 'dev.denial.counter',
      title: 'Counter',
      builder: (_, handle) =>
          _CounterApplication(metadataTitle: handle.window.title),
    );

    Future<void> pump(DenialWindow window) {
      return tester.pumpWidget(
        ProviderScope(
          overrides: [
            localFlutterApplicationsProvider.overrideWithValue(
              <LocalFlutterApplication>[application],
            ),
          ],
          child: MediaQuery(
            data: const MediaQueryData(size: Size(800, 600)),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: LocalFlutterWindowHost(
                key: const ValueKey<int>(91),
                window: window,
                active: false,
              ),
            ),
          ),
        ),
      );
    }

    await pump(_localWindow(title: 'Counter'));
    expect(find.text('Counter: 0'), findsOneWidget);
    await tester.tap(find.text('Counter: 0'));
    await tester.pump();
    expect(find.text('Counter: 1'), findsOneWidget);

    await pump(_localWindow(title: 'Renamed'));
    expect(find.text('Renamed: 1'), findsOneWidget);
  });

  testWidgets(
    'local host keeps application state and snapshots when moved to close layer',
    (tester) async {
      final application = LocalFlutterApplication(
        id: 'dev.denial.counter',
        title: 'Counter',
        builder: (_, handle) =>
            _CounterApplication(metadataTitle: handle.window.title),
      );

      Future<void> pump({required bool closing}) {
        final host = LocalFlutterWindowHost(
          key: const LocalFlutterWindowHostKey(91),
          window: _localWindow(title: 'Counter'),
          active: false,
        );
        return tester.pumpWidget(
          ProviderScope(
            overrides: [
              localFlutterApplicationsProvider.overrideWithValue(
                <LocalFlutterApplication>[application],
              ),
            ],
            child: MediaQuery(
              data: const MediaQueryData(size: Size(800, 600)),
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: SizedBox(
                  width: 800,
                  height: 600,
                  child: Stack(
                    children: [
                      if (!closing) Align(child: host),
                      if (closing)
                        Positioned.fill(
                          child: DesktopWindowSnapshotScope(
                            snapshotting: true,
                            child: host,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      }

      await pump(closing: false);
      await tester.tap(find.text('Counter: 0'));
      await tester.pump();
      expect(find.text('Counter: 1'), findsOneWidget);
      expect(_snapshotController(tester).allowSnapshotting, isFalse);

      await pump(closing: true);

      expect(find.text('Counter: 1'), findsOneWidget);
      expect(_snapshotController(tester).allowSnapshotting, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}

SnapshotController _snapshotController(WidgetTester tester) {
  return tester.widget<SnapshotWidget>(find.byType(SnapshotWidget)).controller;
}

LocalFlutterApplication _application(String id, String title) {
  return LocalFlutterApplication(
    id: id,
    title: title,
    builder: (_, _) => const SizedBox.shrink(),
  );
}

DenialWindow _localWindow({required String title}) {
  return DenialWindow(
    objectId: 91,
    objectKind: 'root_surface',
    surfaceId: 91,
    windowId: 91,
    textureId: 0,
    title: title,
    appId: 'dev.denial.counter',
    width: 800,
    height: 600,
    surfaceX: 0,
    surfaceY: 0,
    surfaceWidth: 800,
    surfaceHeight: 600,
    textureSourceX: 0,
    textureSourceY: 0,
    textureSourceWidth: 0,
    textureSourceHeight: 0,
    geometryX: 100,
    geometryY: 80,
    geometryWidth: 800,
    geometryHeight: 600,
    monitorId: 0,
    transform: 0,
    scale120: 120,
    contentWidth: 800,
    contentHeight: 600,
    contentKind: DenialWindowContentKind.localFlutter,
  );
}

class _CounterApplication extends StatefulWidget {
  const _CounterApplication({required this.metadataTitle});

  final String metadataTitle;

  @override
  State<_CounterApplication> createState() => _CounterApplicationState();
}

class _CounterApplicationState extends State<_CounterApplication> {
  int _count = 0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _count += 1),
      child: Center(child: Text('${widget.metadataTitle}: $_count')),
    );
  }
}

class _LauncherBridge extends DenialBridge {
  DenialWindow? configuredWindow;
  Rect? configuredGeometry;

  @override
  void configureWindow(DenialWindow window, Rect contentRect) {
    configuredWindow = window;
    configuredGeometry = contentRect;
  }
}
