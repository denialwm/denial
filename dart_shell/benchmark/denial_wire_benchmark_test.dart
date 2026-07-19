import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:denial_dart_shell/src/input/input_layout.dart';
import 'package:denial_dart_shell/src/models/denial_window.dart';
import 'package:denial_dart_shell/src/models/denial_window_event.dart';
import 'package:denial_dart_shell/src/platform/denial_wire.dart' as wire;

int _sink = 0;

void main() {
  test('measure historical JSON against the binary bridge', () {
    for (final count in <int>[1, 8, 32]) {
      final snapshot = _inputLayout(count);
      final codec = wire.DenialWireCodec();
      final jsonInput = _encodeJsonInput(snapshot);
      final flatInput = codec.encodeInputLayout(snapshot)!;
      final jsonWindows = _encodeJsonWindows(count);
      final label = switch (count) { 1 => 'one', 8 => 'eight', _ => 'many' };
      final flatWindows =
          File('../protocol/golden/native_windows_$label.denw').readAsBytesSync();
      final iterations = switch (count) { 1 => 10000, 8 => 4000, _ => 1000 };

      final jsonEncodeUs = _measure(iterations, () {
        _sink ^= _encodeJsonInput(snapshot).length;
      });
      final flatEncodeUs = _measure(iterations, () {
        _sink ^= codec.encodeInputLayout(snapshot)!.length;
      });
      final jsonDecodeUs = _measure(iterations, () {
        _sink ^= _decodeJsonWindows(jsonWindows).length;
      });
      final decodeCodec = wire.DenialWireCodec();
      final flatData = ByteData.sublistView(flatWindows);
      final flatDecodeUs = _measure(iterations, () {
        final envelope = decodeCodec.decodeStructured(flatData)!;
        final response = envelope.payload as wire.WindowResponse;
        _sink ^= decodeCodec.decodeWindows(response.windows!)!.length;
      });

      // Keep this one-line format easy for protocol/PERFORMANCE.md updates.
      // ignore: avoid_print
      print(
        'DART count=$count '
        'input_json_bytes=${jsonInput.length} '
        'input_flat_bytes=${flatInput.length} '
        'input_json_encode_us=${jsonEncodeUs.toStringAsFixed(3)} '
        'input_flat_encode_us=${flatEncodeUs.toStringAsFixed(3)} '
        'windows_json_bytes=${jsonWindows.length} '
        'windows_flat_bytes=${flatWindows.length} '
        'windows_json_decode_us=${jsonDecodeUs.toStringAsFixed(3)} '
        'windows_flat_decode_us=${flatDecodeUs.toStringAsFixed(3)}',
      );
    }

    _measurePlacementDecode();
    expect(_sink, isNot(-1));
  });
}

double _measure(int iterations, void Function() operation) {
  for (var index = 0; index < 200; index += 1) {
    operation();
  }
  final samples = <double>[];
  for (var sample = 0; sample < 5; sample += 1) {
    final stopwatch = Stopwatch()..start();
    for (var index = 0; index < iterations; index += 1) {
      operation();
    }
    stopwatch.stop();
    samples.add(stopwatch.elapsedMicroseconds / iterations);
  }
  samples.sort();
  return samples[samples.length ~/ 2];
}

void _measurePlacementDecode() {
  const iterations = 20000;
  final json = Uint8List.fromList(utf8.encode(
    '{"type":"window_placement","windowId":12884901888,'
    '"monitorId":4,"workspaceId":7,"phase":"update","change":"resize",'
    '"x":-12.5,"y":4.75,'
    '"width":640.5,"height":480.25}',
  ));
  final packets = <ByteData>[
    for (var index = 0; index < iterations; index += 1)
      _placementPacket(index + 1),
  ];

  final jsonUs = _measure(iterations, () {
    final event = _decodeJsonPlacement(json);
    _sink ^= event.windowId;
  });

  final samples = <double>[];
  for (var sample = 0; sample < 5; sample += 1) {
    final codec = wire.DenialWireCodec();
    final stopwatch = Stopwatch()..start();
    for (final packet in packets) {
      _sink ^= codec.decodePlacement(packet)!.windowId;
    }
    stopwatch.stop();
    samples.add(stopwatch.elapsedMicroseconds / iterations);
  }
  samples.sort();

  // ignore: avoid_print
  print(
    'DART placement_json_bytes=${json.length} placement_fixed_bytes=80 '
    'placement_json_decode_us=${jsonUs.toStringAsFixed(3)} '
    'placement_fixed_decode_us=${samples[2].toStringAsFixed(3)}',
  );
}

Uint8List _encodeJsonInput(InputLayoutSnapshot snapshot) {
  final value = <String, Object?>{
    'type': 'input_layout',
    'epoch': snapshot.epoch,
    'keyboardCapture': snapshot.keyboardCapture,
    'exclusiveShellMode': snapshot.exclusiveShellMode,
    'shellRegions': <Object>[
      for (final region in snapshot.shellRegions)
        <String, Object?>{
          'rect': <double>[
            region.left,
            region.top,
            region.width,
            region.height,
          ],
          'mode': 'flutter',
        },
    ],
    'windows': <Object>[
      for (final window in snapshot.windows)
        <String, Object?>{
          'objectId': window.window.objectId,
          'surfaceId': window.window.surfaceId,
          'windowId': window.window.windowId,
          'rect': <double>[
            window.rect.left,
            window.rect.top,
            window.rect.width,
            window.rect.height,
          ],
          'sourceRect': <double>[
            window.sourceRect.left,
            window.sourceRect.top,
            window.sourceRect.width,
            window.sourceRect.height,
          ],
          'z': window.z,
          'visible': window.visible,
          'hitTest': window.hitTest,
          'geometryLocked': window.geometryLocked,
        },
    ],
  };
  return Uint8List.fromList(utf8.encode(jsonEncode(value)));
}

Uint8List _encodeJsonWindows(int count) {
  return Uint8List.fromList(utf8.encode(jsonEncode(<String, Object?>{
    'type': 'windows',
    'requestId': 77,
    'windows': <Object>[
      for (var index = 0; index < count; index += 1) _jsonWindow(index),
    ],
  })));
}

Map<String, Object?> _jsonWindow(int index) {
  return <String, Object?>{
    'objectId': 0x100000000 + index,
    'objectKind': index.isEven ? 'root_surface' : 'surface',
    'surfaceId': 0x200000000 + index,
    'windowId': 0x300000000 + index,
    'textureId': index + 1,
    'width': 1280,
    'height': 960,
    'surfaceX': 0.25,
    'surfaceY': 1.5,
    'surfaceWidth': 1280.5,
    'surfaceHeight': 960.25,
    'textureSourceX': 2.5,
    'textureSourceY': 3.75,
    'textureSourceWidth': 1275.5,
    'textureSourceHeight': 955.25,
    'geometryX': -12.5,
    'geometryY': 4.75,
    'geometryWidth': 640.5,
    'geometryHeight': 480.25,
    'monitorId': index % 2,
    'transform': index % 8,
    'scale120': 120,
    'title': 'Golden café 🐒 $index',
    'appId': 'dev.denial.golden.$index',
    if (index == 0) 'statusColorArgb': 0xff123456,
  };
}

List<DenialWindow> _decodeJsonWindows(Uint8List bytes) {
  final root = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  final source = root['windows'] as List<dynamic>;
  return <DenialWindow>[
    for (final value in source) _windowFromJson(value as Map<String, dynamic>),
  ];
}

DenialWindow _windowFromJson(Map<String, dynamic> json) {
  final width = (json['width'] as num).toInt();
  final height = (json['height'] as num).toInt();
  return DenialWindow(
    objectId: (json['objectId'] as num).toInt(),
    objectKind: json['objectKind'] as String? ?? 'root_surface',
    surfaceId: (json['surfaceId'] as num).toInt(),
    windowId: (json['windowId'] as num).toInt(),
    textureId: (json['textureId'] as num).toInt(),
    title: json['title'] as String? ?? '',
    appId: json['appId'] as String? ?? '',
    width: width,
    height: height,
    surfaceX: (json['surfaceX'] as num?)?.toDouble() ?? 0,
    surfaceY: (json['surfaceY'] as num?)?.toDouble() ?? 0,
    surfaceWidth:
        (json['surfaceWidth'] as num?)?.toDouble() ?? width.toDouble(),
    surfaceHeight:
        (json['surfaceHeight'] as num?)?.toDouble() ?? height.toDouble(),
    textureSourceX: (json['textureSourceX'] as num?)?.toDouble() ?? 0,
    textureSourceY: (json['textureSourceY'] as num?)?.toDouble() ?? 0,
    textureSourceWidth:
        (json['textureSourceWidth'] as num?)?.toDouble() ?? width.toDouble(),
    textureSourceHeight:
        (json['textureSourceHeight'] as num?)?.toDouble() ?? height.toDouble(),
    geometryX: (json['geometryX'] as num?)?.toDouble() ?? 0,
    geometryY: (json['geometryY'] as num?)?.toDouble() ?? 0,
    geometryWidth: (json['geometryWidth'] as num?)?.toDouble() ?? 0,
    geometryHeight: (json['geometryHeight'] as num?)?.toDouble() ?? 0,
    monitorId: (json['monitorId'] as num?)?.toInt() ?? -1,
    transform: (json['transform'] as num).toInt(),
    scale120: (json['scale120'] as num).toInt(),
    statusColorArgb: (json['statusColorArgb'] as num?)?.toInt(),
  );
}

DenialWindowPlacementEvent _decodeJsonPlacement(Uint8List bytes) {
  final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  return DenialWindowPlacementEvent(
    sequence: 1,
    windowId: (json['windowId'] as num).toInt(),
    contentRect: Rect.fromLTWH(
      (json['x'] as num).toDouble(),
      (json['y'] as num).toDouble(),
      (json['width'] as num).toDouble(),
      (json['height'] as num).toDouble(),
    ),
    phase: switch (json['phase']) {
      'begin' => DenialWindowPlacementPhase.begin,
      'end' => DenialWindowPlacementPhase.end,
      _ => DenialWindowPlacementPhase.update,
    },
    monitorId: (json['monitorId'] as num).toInt(),
    workspaceId: (json['workspaceId'] as num).toInt(),
    change: json['change'] == 'resize'
        ? DenialWindowPlacementChange.resize
        : DenialWindowPlacementChange.move,
  );
}

InputLayoutSnapshot _inputLayout(int count) {
  return InputLayoutSnapshot(
    epoch: 0x100000000 + count,
    shellRegions: <Rect>[
      const Rect.fromLTWH(-0.5, 0.25, 177.75, 72.5),
    ],
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

DenialWindow _window(int index) {
  return _windowFromJson(_jsonWindow(index));
}

ByteData _placementPacket(int sequence) {
  return ByteData(80)
    ..setUint8(0, 0x44)
    ..setUint8(1, 0x45)
    ..setUint8(2, 0x4e)
    ..setUint8(3, 0x50)
    ..setUint16(4, 1, Endian.little)
    ..setUint16(6, 2, Endian.little)
    ..setUint32(8, 80, Endian.little)
    ..setUint64(12, sequence, Endian.little)
    ..setUint64(20, 0x300000000, Endian.little)
    ..setInt64(28, 4, Endian.little)
    ..setInt64(36, 7, Endian.little)
    ..setUint8(44, DenialWindowPlacementPhase.update.index)
    ..setUint8(45, DenialWindowPlacementChange.resize.index)
    ..setFloat64(48, -12.5, Endian.little)
    ..setFloat64(56, 4.75, Endian.little)
    ..setFloat64(64, 640.5, Endian.little)
    ..setFloat64(72, 480.25, Endian.little);
}
