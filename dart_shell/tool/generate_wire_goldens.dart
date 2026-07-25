import 'dart:io';
import 'dart:typed_data';

import 'package:flat_buffers/flat_buffers.dart' as fb;
import 'package:denial_wire_protocol/denial_denial.wire_generated.dart' as wire;

void main() {
  final output = Directory('../protocol/golden')..createSync(recursive: true);
  for (final count in <int>[0, 1, 8, 32]) {
    final bytes = _inputLayout(count);
    final label = switch (count) {
      0 => 'empty',
      1 => 'one',
      8 => 'eight',
      _ => 'many',
    };
    File('${output.path}/dart_input_$label.denw').writeAsBytesSync(bytes);
  }
  File('${output.path}/dart_system_bar.denw').writeAsBytesSync(
    _systemBarConfiguration(),
  );
}

List<int> _systemBarConfiguration() {
  return wire.EnvelopeObjectBuilder(
    protocolVersion: 1,
    sequence: 1,
    requestId: 41,
    payloadType: wire.PayloadTypeId.WindowRequest,
    payload: _AlignedSystemBarRequestObjectBuilder(
      side: wire.SystemBarSide.Right,
      monitorIds: const <int>[7, 9],
    ),
  ).toBytes('DENW');
}

List<int> _inputLayout(int count) {
  final indexes = <int>[for (var index = 0; index < count; index += 1) index]
    ..sort((left, right) {
      final zOrder = (right % 5).compareTo(left % 5);
      return zOrder != 0 ? zOrder : right.compareTo(left);
    });

  var layoutFlags = 0;
  if (count.isOdd) {
    layoutFlags |= 1;
  }
  if (count == 32) {
    layoutFlags |= 2;
  }

  return wire.EnvelopeObjectBuilder(
    protocolVersion: 1,
    sequence: 1,
    requestId: 0,
    payloadType: wire.PayloadTypeId.InputLayout,
    payload: _AlignedInputLayoutObjectBuilder(
      epoch: 0x100000000 + count,
      flags: layoutFlags,
      shellRegions: count == 0
          ? const <wire.WireRectObjectBuilder>[]
          : <wire.WireRectObjectBuilder>[
              wire.WireRectObjectBuilder(
                x: -0.5,
                y: 0.25,
                width: 177.75,
                height: 72.5,
              ),
            ],
      windows: <wire.InputWindowRegionObjectBuilder>[
        for (final index in indexes) _inputWindow(index),
      ],
      visibleSurfaceIds: const <int>[],
    ),
  ).toBytes('DENW');
}

class _AlignedInputLayoutObjectBuilder extends fb.ObjectBuilder {
  _AlignedInputLayoutObjectBuilder({
    required this.epoch,
    required this.flags,
    required this.shellRegions,
    required this.windows,
    required this.visibleSurfaceIds,
  });

  final int epoch;
  final int flags;
  final List<wire.WireRectObjectBuilder> shellRegions;
  final List<wire.InputWindowRegionObjectBuilder> windows;
  final List<int> visibleSurfaceIds;

  @override
  int finish(fb.Builder builder) {
    final shellRegionsOffset = _writeAlignedStructVector(
      builder,
      shellRegions,
    );
    final windowsOffset = _writeAlignedStructVector(builder, windows);
    final visibleSurfaceIdsOffset = _writeAlignedUint64Vector(
      builder,
      visibleSurfaceIds,
    );
    builder.startTable(5);
    builder.addUint64(0, epoch);
    builder.addUint32(1, flags);
    builder.addOffset(2, shellRegionsOffset);
    builder.addOffset(3, windowsOffset);
    builder.addOffset(4, visibleSurfaceIdsOffset);
    return builder.endTable();
  }

  @override
  Uint8List toBytes([String? fileIdentifier]) {
    final builder = fb.Builder(deduplicateTables: false);
    builder.finish(finish(builder), fileIdentifier);
    return builder.buffer;
  }
}

class _AlignedSystemBarRequestObjectBuilder extends fb.ObjectBuilder {
  _AlignedSystemBarRequestObjectBuilder({
    required this.side,
    required this.monitorIds,
  });

  final wire.SystemBarSide side;
  final List<int> monitorIds;

  @override
  int finish(fb.Builder builder) {
    final monitorIdsOffset = _writeAlignedInt64Vector(builder, monitorIds);
    builder.startTable(7);
    builder.addUint8(0, wire.WindowRequestKind.ConfigureSystemBar.value);
    builder.addUint8(5, side.value);
    builder.addOffset(6, monitorIdsOffset);
    return builder.endTable();
  }

  @override
  Uint8List toBytes([String? fileIdentifier]) {
    final builder = fb.Builder(deduplicateTables: false);
    builder.finish(finish(builder), fileIdentifier);
    return builder.buffer;
  }
}

int _writeAlignedStructVector(
  fb.Builder builder,
  List<fb.ObjectBuilder> values,
) {
  builder.pad((-builder.offset) & 7);
  return builder.writeListOfStructs(values);
}

int _writeAlignedUint64Vector(fb.Builder builder, List<int> values) {
  builder.pad((-builder.offset) & 7);
  for (var index = values.length - 1; index >= 0; index -= 1) {
    builder.putUint64(values[index]);
  }
  return builder.endStructVector(values.length);
}

int _writeAlignedInt64Vector(fb.Builder builder, List<int> values) {
  builder.pad((-builder.offset) & 7);
  for (var index = values.length - 1; index >= 0; index -= 1) {
    builder.putInt64(values[index]);
  }
  return builder.endStructVector(values.length);
}

wire.InputWindowRegionObjectBuilder _inputWindow(int index) {
  var flags = 0;
  if (index % 7 != 0 || index == 0) {
    flags |= 1;
  }
  if (index % 3 == 0 && index != 0) {
    flags |= 2;
  }
  if (index.isEven) {
    flags |= 4;
  }

  return wire.InputWindowRegionObjectBuilder(
    objectId: 0x100000000 + index,
    surfaceId: 0x200000000 + index,
    windowId: 0x300000000 + index,
    rect: wire.WireRectObjectBuilder(
      x: -12.5 + index * 3.25,
      y: 4.75 + index,
      width: 640.5,
      height: 480.25,
    ),
    sourceRect: wire.WireRectObjectBuilder(
      x: 0.25,
      y: 1.5,
      width: 1280.5,
      height: 960.25,
    ),
    z: index % 5,
    flags: flags,
  );
}
