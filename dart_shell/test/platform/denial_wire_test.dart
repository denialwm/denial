import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:denial_dart_shell/src/input/input_layout.dart';
import 'package:denial_dart_shell/src/models/hypr_window.dart';
import 'package:denial_dart_shell/src/models/hypr_window_event.dart';
import 'package:denial_dart_shell/src/platform/denial_wire.dart'
    hide InputWindowRegion;

void main() {
  test('routing comparison is allocation-free and includes surface identity',
      () {
    final original = _inputLayout(1);
    final sameRouting = _inputLayout(1, epoch: original.epoch + 1);
    expect(original.hasSameRoutingAs(sameRouting), isTrue);

    final source = original.windows.single;
    final changedSurface = InputLayoutSnapshot(
      epoch: original.epoch + 1,
      shellRegions: original.shellRegions,
      windows: <InputWindowRegion>[
        InputWindowRegion(
          window: _window(0, surfaceId: source.window.surfaceId + 1),
          rect: source.rect,
          sourceRect: source.sourceRect,
          z: source.z,
          visible: source.visible,
          hitTest: source.hitTest,
          geometryLocked: source.geometryLocked,
        ),
      ],
      keyboardCapture: original.keyboardCapture,
      exclusiveShellMode: original.exclusiveShellMode,
    );
    expect(original.hasSameRoutingAs(changedSurface), isFalse);
  });

  test('Dart input goldens are current and decode in Dart', () {
    for (final count in <int>[0, 1, 8, 32]) {
      final codec = DenialWireCodec();
      final bytes = codec.encodeInputLayout(_inputLayout(count));
      expect(bytes, isNotNull);
      final label = switch (count) {
        0 => 'empty',
        1 => 'one',
        8 => 'eight',
        _ => 'many',
      };
      expect(
        bytes,
        orderedEquals(
          File('../protocol/golden/dart_input_$label.denw').readAsBytesSync(),
        ),
      );
      final root = Envelope(bytes!);
      expect(root.protocolVersion, denialWireVersion);
      expect(root.payloadType, PayloadTypeId.InputLayout);
      final layout = root.payload as InputLayout;
      expect(layout.windows, hasLength(count));
      if (count > 1) {
        final windows = layout.windows!;
        for (var index = 1; index < windows.length; index += 1) {
          expect(windows[index - 1].z, greaterThanOrEqualTo(windows[index].z));
        }
      }
    }
  });

  test('input layout preserves positive subpixel routing rectangles', () {
    final codec = DenialWireCodec();
    final bytes = codec.encodeInputLayout(InputLayoutSnapshot(
      epoch: 1,
      shellRegions: const <Rect>[Rect.fromLTWH(10, 20, 0.25, 0.5)],
      windows: const <InputWindowRegion>[],
    ));

    expect(bytes, isNotNull);
    final layout = Envelope(bytes!).payload as InputLayout;
    expect(layout.shellRegions, hasLength(1));
    expect(layout.shellRegions!.single.width, 0.25);
    expect(layout.shellRegions!.single.height, 0.5);
  });

  test('input layout preserves hit testing as the missing-bit default', () {
    final codec = DenialWireCodec();
    final bytes = codec.encodeInputLayout(InputLayoutSnapshot(
      epoch: 1,
      shellRegions: const <Rect>[],
      windows: <InputWindowRegion>[
        InputWindowRegion(
          window: _window(0),
          rect: const Rect.fromLTWH(0, 0, 100, 100),
          sourceRect: const Rect.fromLTWH(0, 0, 100, 100),
          z: 1,
        ),
        InputWindowRegion(
          window: _window(1),
          rect: const Rect.fromLTWH(100, 0, 100, 100),
          sourceRect: const Rect.fromLTWH(0, 0, 100, 100),
          z: 0,
          hitTest: false,
        ),
      ],
    ));

    expect(bytes, isNotNull);
    final windows = (Envelope(bytes!).payload as InputLayout).windows!;
    expect(windows.map((window) => window.flags).toList(), <int>[1, 3]);
  });

  test('input layout carries popup targets and independent visibility', () {
    final codec = DenialWireCodec();
    final window = _window(0);
    final bytes = codec.encodeInputLayout(InputLayoutSnapshot(
      epoch: 1,
      shellRegions: const <Rect>[],
      windows: <InputWindowRegion>[
        InputWindowRegion(
          window: window,
          surfaceId: 0x400000000,
          rect: const Rect.fromLTWH(40, 50, 320, 240),
          sourceRect: const Rect.fromLTWH(0, 0, 320, 240),
          z: 2,
        ),
      ],
      visibleSurfaceIds: const <int>[0x200000000, 0x400000000],
    ));

    expect(bytes, isNotNull);
    final layout = Envelope(bytes!).payload as InputLayout;
    expect(layout.windows!.single.surfaceId, 0x400000000);
    expect(layout.visibleSurfaceIds, <int>[0x200000000, 0x400000000]);
  });

  test('input layout can route a logical window through its root surface', () {
    final codec = DenialWireCodec();
    final window = _window(0);
    final bytes = codec.encodeInputLayout(InputLayoutSnapshot(
      epoch: 1,
      shellRegions: const <Rect>[],
      windows: <InputWindowRegion>[
        InputWindowRegion(
          window: window,
          surfaceId: window.objectId,
          rect: const Rect.fromLTWH(0, 0, 640, 480),
          sourceRect: const Rect.fromLTWH(0, 0, 1280, 960),
          z: 0,
        ),
      ],
    ));

    expect(bytes, isNotNull);
    final layout = Envelope(bytes!).payload as InputLayout;
    expect(window.objectId, isNot(window.surfaceId));
    expect(layout.windows!.single.surfaceId, window.objectId);
  });

  test('input layout still rejects empty routing rectangles', () {
    final codec = DenialWireCodec();
    final bytes = codec.encodeInputLayout(InputLayoutSnapshot(
      epoch: 1,
      shellRegions: const <Rect>[Rect.fromLTWH(10, 20, 0, 0.5)],
      windows: const <InputWindowRegion>[],
    ));

    expect(bytes, isNull);
  });

  test('C++ window goldens decode to Dart models', () {
    for (final count in <int>[0, 1, 8, 32]) {
      final label = switch (count) {
        0 => 'empty',
        1 => 'one',
        8 => 'eight',
        _ => 'many',
      };
      final bytes =
          File('../protocol/golden/cpp_windows_$label.denw').readAsBytesSync();
      final codec = DenialWireCodec();
      final decoded = codec.decodeStructured(ByteData.sublistView(bytes));
      expect(decoded, isNotNull);
      expect(decoded!.requestId, 77);
      expect(decoded.payload, isA<WindowResponse>());
      final response = decoded.payload as WindowResponse;
      expect(response.kind, WindowResponseKind.Windows);
      final windows = codec.decodeWindows(response.windows!);
      expect(windows, hasLength(count));
      if (count > 0) {
        expect(windows!.first.objectId, 0x100000000);
        expect(windows.first.title, 'Golden café 🐒 0');
        expect(windows.first.geometryX, -12.5);
        expect(windows.first.statusColorArgb, 0xff123456);
        expect(windows.first.pinned, isFalse);
        expect(windows.first.suppressAnimations, isFalse);
        expect(windows.first.serverSideDecorated, isTrue);
        expect(windows.first.opacity, 1.0);
        expect(
          windows.first.contentCoordinateRect,
          const Rect.fromLTWH(0.25, 1.5, 1280.5, 960.25),
        );
        expect(windows.first.surfaceLayers, hasLength(2));
        expect(windows.first.surfaceLayers.first.opacity, 1.0);
        expect(windows.first.popupRoots.single.surfaceId, 0x400000000);
        expect(
          windows.first.mapSurfaceRect(
            windows.first.popupRoots.single,
            const Rect.fromLTWH(10, 20, 640.25, 480.125),
          ),
          const Rect.fromLTWH(60, 59.5, 160, 120),
        );
      }
    }
  });

  test('window appearance policy crosses the structured bridge', () {
    final bytes = EnvelopeObjectBuilder(
      protocolVersion: 1,
      sequence: 1,
      payloadType: PayloadTypeId.WindowSnapshot,
      payload: WindowSnapshotObjectBuilder(windows: <WindowObjectBuilder>[
        WindowObjectBuilder(
          objectId: 1,
          surfaceId: 2,
          windowId: 3,
          textureId: 4,
          width: 100,
          height: 80,
          contentWidth: 100,
          contentHeight: 80,
          surfaces: <SurfaceLayerObjectBuilder>[
            SurfaceLayerObjectBuilder(
              surfaceId: 5,
              textureId: 6,
              width: 100,
              height: 80,
              surfaceWidth: 100,
              surfaceHeight: 80,
              textureSourceWidth: 100,
              textureSourceHeight: 80,
              opacity: 0.5,
            ),
          ],
          suppressAnimations: true,
          serverSideDecorated: false,
          opacity: 0.75,
        ),
      ]),
    ).toBytes('DENW');
    final codec = DenialWireCodec();
    final decoded = codec.decodeStructured(ByteData.sublistView(bytes));

    expect(decoded, isNotNull);
    final windows = codec.decodeWindows(decoded!.payload as WindowSnapshot);
    expect(windows, hasLength(1));
    expect(windows!.single.suppressAnimations, isTrue);
    expect(windows.single.serverSideDecorated, isFalse);
    expect(windows.single.opacity, closeTo(0.75, 0.0001));
    expect(windows.single.surfaceLayers.single.opacity, closeTo(0.5, 0.0001));
  });

  test('window business validation rejects opacity outside the unit range', () {
    final invalid = EnvelopeObjectBuilder(
      protocolVersion: 1,
      sequence: 1,
      payloadType: PayloadTypeId.WindowSnapshot,
      payload: WindowSnapshotObjectBuilder(windows: <WindowObjectBuilder>[
        WindowObjectBuilder(
          objectId: 1,
          surfaceId: 2,
          windowId: 3,
          textureId: 4,
          width: 100,
          height: 100,
          opacity: 1.1,
        ),
      ]),
    ).toBytes('DENW');
    final codec = DenialWireCodec();
    final decoded = codec.decodeStructured(ByteData.sublistView(invalid));

    expect(decoded, isNotNull);
    expect(codec.decodeWindows(decoded!.payload as WindowSnapshot), isNull);
  });

  test('structured decoder rejects bad buffers and direction', () {
    final codec = DenialWireCodec();
    expect(codec.decodeStructured(null), isNull);
    expect(codec.decodeStructured(ByteData(7)), isNull);
    expect(
      codec.decodeStructured(ByteData(denialWireMaxBytes + 1)),
      isNull,
    );

    final outbound =
        codec.encodeWindowRequest(WindowRequestKind.ListWindows, requestId: 1);
    expect(codec.decodeStructured(ByteData.sublistView(outbound)), isNull);

    final wrongIdentifier = Uint8List.fromList(
      File('../protocol/golden/cpp_windows_one.denw').readAsBytesSync(),
    )..[4] = 0;
    expect(
      codec.decodeStructured(ByteData.sublistView(wrongIdentifier)),
      isNull,
    );

    final wrongVersion = EnvelopeObjectBuilder(
      protocolVersion: 2,
      sequence: 1,
      payloadType: PayloadTypeId.WindowEvent,
      payload: WindowEventObjectBuilder(kind: WindowEventKind.WindowsChanged),
    ).toBytes('DENW');
    expect(
      codec.decodeStructured(ByteData.sublistView(wrongVersion)),
      isNull,
    );

    final zeroSequence = EnvelopeObjectBuilder(
      protocolVersion: 1,
      sequence: 0,
      payloadType: PayloadTypeId.WindowEvent,
      payload: WindowEventObjectBuilder(kind: WindowEventKind.WindowsChanged),
    ).toBytes('DENW');
    expect(
      codec.decodeStructured(ByteData.sublistView(zeroSequence)),
      isNull,
    );
    expect(codec.rejectedStructuredMessages, 7);
  });

  test('window business validation rejects missing identity and NaN', () {
    final invalid = EnvelopeObjectBuilder(
      protocolVersion: 1,
      sequence: 1,
      payloadType: PayloadTypeId.WindowSnapshot,
      payload: WindowSnapshotObjectBuilder(windows: <WindowObjectBuilder>[
        WindowObjectBuilder(
          objectId: 0,
          surfaceId: 2,
          windowId: 3,
          textureId: 4,
          width: 100,
          height: 100,
          surfaceX: double.nan,
        ),
      ]),
    ).toBytes('DENW');
    final codec = DenialWireCodec();
    final decoded = codec.decodeStructured(ByteData.sublistView(invalid));
    expect(decoded, isNotNull);
    expect(
      codec.decodeWindows(decoded!.payload as WindowSnapshot),
      isNull,
    );
  });

  test('fixed placement packet validates ownership and ordering', () {
    final codec = DenialWireCodec();
    final packet = _placementPacket(
      sequence: 9,
      phase: HyprWindowPlacementPhase.end,
      change: HyprWindowPlacementChange.move,
    );
    final decoded = codec.decodePlacement(packet);
    expect(decoded, isNotNull);
    expect(decoded!.windowId, 0x100000002);
    expect(decoded.monitorId, 4);
    expect(decoded.workspaceId, 7);
    expect(decoded.phase, HyprWindowPlacementPhase.end);
    expect(decoded.change, HyprWindowPlacementChange.move);
    expect(
        decoded.contentRect, const Rect.fromLTWH(-12.5, 4.75, 640.5, 480.25));

    expect(codec.decodePlacement(packet), isNull, reason: 'duplicate sequence');
    final badMagic = _copy(packet)..setUint8(0, 0);
    expect(codec.decodePlacement(badMagic), isNull);
    final badPhase = _copy(packet)..setUint8(44, 9);
    expect(codec.decodePlacement(badPhase), isNull);
    final badChange = _copy(packet)
      ..setUint64(12, 10, Endian.little)
      ..setUint8(45, 9);
    expect(codec.decodePlacement(badChange), isNull);
    final badReserved = _copy(packet)..setUint16(46, 1, Endian.little);
    expect(codec.decodePlacement(badReserved), isNull);
    final nanWidth = _copy(packet)
      ..setUint64(12, 10, Endian.little)
      ..setFloat64(64, double.nan, Endian.little);
    expect(codec.decodePlacement(nanWidth), isNull);
    expect(codec.decodePlacement(ByteData(79)), isNull);
  });

  test('fixed drag-icon packet validates texture metadata and ordering', () {
    final codec = DenialWireCodec();
    final active = _dragIconPacket(sequence: 9);
    expect(isDenialDragIconPacket(active), isTrue);

    final decoded = codec.decodeDragIcon(active);
    expect(decoded, isNotNull);
    expect(decoded!.sequence, 9);
    expect(decoded.icon, isNotNull);
    expect(decoded.icon!.surfaceId, 0x200000004);
    expect(decoded.icon!.layer.textureId, 7);
    expect(decoded.icon!.offset, const Offset(-12.5, 8.25));
    expect(decoded.icon!.size, const Size(160, 120));
    expect(decoded.icon!.layer.textureSourceWidth, 319);

    final inactive = codec.decodeDragIcon(
      _dragIconPacket(sequence: 10, active: false),
    );
    expect(inactive, isNotNull);
    expect(inactive!.icon, isNull);
    expect(codec.decodeDragIcon(_dragIconPacket(sequence: 10)), isNull);

    final malformedCodec = DenialWireCodec();
    expect(
      malformedCodec.decodeDragIcon(_copy(active)..setUint8(0, 0)),
      isNull,
    );
    expect(
      malformedCodec.decodeDragIcon(_copy(active)..setUint32(24, 1)),
      isNull,
    );
    expect(
      malformedCodec.decodeDragIcon(_copy(active)..setUint32(20, 2)),
      isNull,
    );
    expect(
      malformedCodec.decodeDragIcon(_copy(active)..setUint32(52, 8)),
      isNull,
    );
    expect(
      malformedCodec.decodeDragIcon(
        _copy(active)..setFloat64(64, double.nan, Endian.little),
      ),
      isNull,
    );
    expect(
      malformedCodec.decodeDragIcon(
        _copy(active)..setUint32(44, 10, Endian.little),
      ),
      isNull,
    );
    expect(malformedCodec.decodeDragIcon(ByteData(127)), isNull);
    expect(malformedCodec.rejectedDragIconPackets, 7);

    expect(
      malformedCodec.decodeDragIcon(_dragIconPacket(sequence: 9)),
      isNotNull,
      reason: 'malformed packets must not consume sequence numbers',
    );
  });
}

InputLayoutSnapshot _inputLayout(int count, {int? epoch}) {
  return InputLayoutSnapshot(
    epoch: epoch ?? 0x100000000 + count,
    shellRegions: count == 0
        ? const <Rect>[]
        : const <Rect>[Rect.fromLTWH(-0.5, 0.25, 177.75, 72.5)],
    windows: <InputWindowRegion>[
      for (var index = 0; index < count; index += 1)
        InputWindowRegion(
          window: _window(index),
          rect: Rect.fromLTWH(
            -12.5 + index * 3.25,
            4.75 + index,
            640.5,
            480.25,
          ),
          sourceRect: const Rect.fromLTWH(0.25, 1.5, 1280.5, 960.25),
          z: index % 5,
          visible: index % 7 != 0 || index == 0,
          hitTest: index % 3 != 0 || index == 0,
          geometryLocked: index.isEven,
        ),
    ],
    keyboardCapture: count.isOdd,
    exclusiveShellMode: count == 32,
  );
}

HyprWindow _window(int index, {int? surfaceId}) {
  return HyprWindow(
    objectId: 0x100000000 + index,
    objectKind: index.isEven ? 'root_surface' : 'surface',
    surfaceId: surfaceId ?? 0x200000000 + index,
    windowId: 0x300000000 + index,
    textureId: index + 1,
    title: 'Golden café 🐒 $index',
    appId: 'dev.denial.golden.$index',
    width: 1280,
    height: 960,
    surfaceX: 0.25,
    surfaceY: 1.5,
    surfaceWidth: 1280.5,
    surfaceHeight: 960.25,
    textureSourceX: 2.5,
    textureSourceY: 3.75,
    textureSourceWidth: 1275.5,
    textureSourceHeight: 955.25,
    geometryX: -12.5,
    geometryY: 4.75,
    geometryWidth: 640.5,
    geometryHeight: 480.25,
    monitorId: index % 2,
    transform: index % 8,
    scale120: 120,
  );
}

ByteData _placementPacket({
  required int sequence,
  required HyprWindowPlacementPhase phase,
  required HyprWindowPlacementChange change,
}) {
  return ByteData(80)
    ..setUint8(0, 0x44)
    ..setUint8(1, 0x45)
    ..setUint8(2, 0x4e)
    ..setUint8(3, 0x50)
    ..setUint16(4, 1, Endian.little)
    ..setUint16(6, 2, Endian.little)
    ..setUint32(8, 80, Endian.little)
    ..setUint64(12, sequence, Endian.little)
    ..setUint64(20, 0x100000002, Endian.little)
    ..setInt64(28, 4, Endian.little)
    ..setInt64(36, 7, Endian.little)
    ..setUint8(44, phase.index)
    ..setUint8(45, change.index)
    ..setFloat64(48, -12.5, Endian.little)
    ..setFloat64(56, 4.75, Endian.little)
    ..setFloat64(64, 640.5, Endian.little)
    ..setFloat64(72, 480.25, Endian.little);
}

ByteData _dragIconPacket({
  required int sequence,
  bool active = true,
}) {
  return ByteData(128)
    ..setUint8(0, 0x44)
    ..setUint8(1, 0x45)
    ..setUint8(2, 0x4e)
    ..setUint8(3, 0x44)
    ..setUint16(4, 1, Endian.little)
    ..setUint16(6, 3, Endian.little)
    ..setUint32(8, 128, Endian.little)
    ..setUint64(12, sequence, Endian.little)
    ..setUint32(20, active ? 1 : 0, Endian.little)
    ..setUint64(28, 0x200000004, Endian.little)
    ..setUint64(36, 7, Endian.little)
    ..setUint32(44, 320, Endian.little)
    ..setUint32(48, 240, Endian.little)
    ..setUint32(52, 0, Endian.little)
    ..setUint32(56, 120, Endian.little)
    ..setFloat64(64, -12.5, Endian.little)
    ..setFloat64(72, 8.25, Endian.little)
    ..setFloat64(80, 160, Endian.little)
    ..setFloat64(88, 120, Endian.little)
    ..setFloat64(96, 1, Endian.little)
    ..setFloat64(104, 2, Endian.little)
    ..setFloat64(112, 319, Endian.little)
    ..setFloat64(120, 238, Endian.little);
}

ByteData _copy(ByteData source) {
  final bytes = Uint8List.fromList(source.buffer.asUint8List(
    source.offsetInBytes,
    source.lengthInBytes,
  ));
  return ByteData.sublistView(bytes);
}
