import 'package:denial_desktop/src/state/phone_desk.dart';
import 'package:denial_desktop/src/state/phone_desk_input.dart';
import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/platform.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the phone sees its panel alone, from its own origin', () {
    final split = PhoneDeskLayout(phone: _phone(), desks: [_desk()]);
    final layout = _layout();

    final phone = split.phoneLayout(layout);
    expect(phone.outputs.single.logicalRect, Offset.zero & phoneRect.size);
    expect(phone.logicalSize, phoneRect.size);
    expect(phone.systemBarMonitorId, -1);

    final desk = split.deskLayout(layout);
    expect(desk.outputs.map((output) => output.monitorId), [2]);
    expect(desk.tickerMonitorId, 2);
    expect(split.isDeskMonitor(1), isFalse);
    expect(split.isDeskMonitor(2), isTrue);
  });

  test('composer moves the phone into the scene and ranks it first', () {
    final bridge = _RecordingBridge();
    final composer = PhoneDeskInputComposer(bridge);
    final phoneWindow = _window(objectId: 3);
    final deskWindow = _window(objectId: 7);

    composer.publishPhone(
      InputLayoutSnapshot(
        epoch: 1,
        shellRegions: const [Rect.fromLTWH(0, 0, 400, 48)],
        windows: [
          InputWindowRegion(
            window: phoneWindow,
            rect: const Rect.fromLTWH(0, 48, 400, 852),
            sourceRect: const Rect.fromLTWH(0, 0, 400, 852),
            z: 0,
          ),
        ],
        edgeSwipeRegions: const [
          InputEdgeSwipeRegion(
            rect: Rect.fromLTWH(0, 48, 20, 852),
            edge: InputEdge.left,
          ),
        ],
        visibleSurfaceIds: const [3],
        mobilePresentation: true,
      ),
      phoneRect.topLeft,
    );
    expect(bridge.published, isEmpty, reason: 'waits for the desk');

    composer.publishDesk(
      InputLayoutSnapshot(
        epoch: 1,
        shellRegions: const [Rect.fromLTWH(0, 0, 1920, 1080)],
        windows: [
          InputWindowRegion(
            window: deskWindow,
            rect: const Rect.fromLTWH(100, 100, 800, 600),
            sourceRect: const Rect.fromLTWH(0, 0, 800, 600),
            z: 2000000000,
          ),
        ],
        visibleSurfaceIds: const [7],
        keyboardCapture: true,
        mobilePresentation: false,
      ),
    );

    final snapshot = bridge.published.single;
    expect(snapshot.shellRegions, const [
      Rect.fromLTWH(1920, 0, 400, 48),
      Rect.fromLTWH(0, 0, 1920, 1080),
    ]);
    expect(snapshot.windows.map((region) => region.window.objectId), [3, 7]);
    expect(snapshot.windows.map((region) => region.z), [1, 0]);
    expect(
      snapshot.windows.first.rect,
      const Rect.fromLTWH(1920, 48, 400, 852),
    );
    expect(
      snapshot.windows.first.sourceRect,
      const Rect.fromLTWH(0, 0, 400, 852),
    );
    expect(snapshot.windows.last.rect, const Rect.fromLTWH(100, 100, 800, 600));
    expect(
      snapshot.edgeSwipeRegions.single.rect,
      const Rect.fromLTWH(1920, 48, 20, 852),
    );
    expect(snapshot.visibleSurfaceIds.toSet(), {3, 7});
    expect(snapshot.keyboardCapture, isTrue);
    expect(snapshot.mobilePresentation, isTrue);

    composer.publishDesk(
      InputLayoutSnapshot(
        epoch: 2,
        shellRegions: const [Rect.fromLTWH(0, 0, 1920, 1080)],
        windows: [
          InputWindowRegion(
            window: deskWindow,
            rect: const Rect.fromLTWH(100, 100, 800, 600),
            sourceRect: const Rect.fromLTWH(0, 0, 800, 600),
            z: 2000000000,
          ),
        ],
        visibleSurfaceIds: const [7],
        keyboardCapture: true,
        mobilePresentation: false,
      ),
    );
    expect(bridge.published, hasLength(1), reason: 'same routing');
  });
}

DisplayOutput _phone() => const DisplayOutput(
  monitorId: 1,
  name: 'DSI-1',
  logicalRect: phoneRect,
  pixelSize: Size(1200, 2700),
  scale: 3,
  refreshRate: 120,
);

const phoneRect = Rect.fromLTWH(1920, 0, 400, 900);

DisplayOutput _desk() => const DisplayOutput(
  monitorId: 2,
  name: 'DP-1',
  logicalRect: Rect.fromLTWH(0, 0, 1920, 1080),
  pixelSize: Size(1920, 1080),
  scale: 1,
  refreshRate: 60,
);

DisplayLayout _layout() => DisplayLayout(
  epoch: 1,
  globalOrigin: Offset.zero,
  logicalSize: const Size(2320, 1080),
  pixelSize: const Size(3120, 2700),
  engineScale: 1,
  tickerMonitorId: 1,
  systemBarMonitorId: -1,
  systemBarSide: SystemBarSide.hidden,
  outputs: [_phone(), _desk()],
);

DenialWindow _window({required int objectId}) => DenialWindow(
  objectId: objectId,
  objectKind: 'xdg',
  surfaceId: objectId,
  windowId: objectId,
  textureId: objectId,
  title: 'app',
  appId: 'app',
  width: 100,
  height: 100,
  surfaceX: 0,
  surfaceY: 0,
  surfaceWidth: 100,
  surfaceHeight: 100,
  textureSourceX: 0,
  textureSourceY: 0,
  textureSourceWidth: 100,
  textureSourceHeight: 100,
  geometryX: 0,
  geometryY: 0,
  geometryWidth: 100,
  geometryHeight: 100,
  monitorId: 1,
  transform: 0,
  scale120: 120,
  contentX: 0,
  contentY: 0,
  contentWidth: 100,
  contentHeight: 100,
  contentKind: DenialWindowContentKind.surfaceTree,
);

class _RecordingBridge extends DenialBridge {
  final published = <InputLayoutSnapshot>[];

  @override
  bool publishInputLayout(InputLayoutSnapshot snapshot) {
    published.add(snapshot);
    return true;
  }
}
