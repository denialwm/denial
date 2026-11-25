import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'denial_bridge_models.dart';

/// Decodes native system-control messages independently of transport and state.
/// Records contain only wire data; the bridge determines which reads complete.
abstract final class SystemControlProtocol {
  static ({
    double level,
    int requestSerial,
    bool muted,
    bool limitReached,
    bool fromKey,
  })?
  decodeAudioState(ByteData? data) {
    if (data == null || data.lengthInBytes < 1) return null;
    return (
      level: _percent(data, 0),
      requestSerial: data.lengthInBytes >= 5
          ? data.getUint32(1, Endian.little)
          : 0,
      muted: data.lengthInBytes >= 6 && data.getUint8(5) != 0,
      limitReached: data.lengthInBytes >= 7 && data.getUint8(6) != 0,
      fromKey: data.lengthInBytes >= 8 && data.getUint8(7) != 0,
    );
  }

  static DenialCallVolume? decodeCallVolume(ByteData? data) {
    if (data == null || data.lengthInBytes != 12) return null;
    final previous = data.getUint32(0, Endian.little);
    final step = data.getUint32(4, Endian.little);
    final maximum = data.getUint32(8, Endian.little);
    if (maximum == 0 || previous > maximum || step > maximum) return null;
    return (previous: previous, step: step, maximum: maximum);
  }

  static ByteData setCallVolume(int step) => ByteData(5)
    ..setUint8(0, 6)
    ..setUint32(1, step.clamp(0, 0xffffffff), Endian.little);

  static List<DenialAudioStream>? decodeAudioStreams(ByteData? data) {
    if (data == null || data.lengthInBytes < 4) return null;
    final count = data.getUint32(0, Endian.little);
    // Even empty names require a complete fixed header per entry. Reject an
    // impossible count before allocating models or decoding any strings.
    if (count > (data.lengthInBytes - 4) ~/ 8) return null;
    if (count == 0) return const [];
    final streams = <DenialAudioStream>[];
    final bytes = Uint8List.sublistView(data);
    var offset = 4;
    for (var i = 0; i < count; i++) {
      if (offset + 8 > data.lengthInBytes) return null;
      final id = data.getUint32(offset, Endian.little);
      final level = _percent(data, offset + 4);
      final muted = data.getUint8(offset + 5) != 0;
      final nameLength = data.getUint16(offset + 6, Endian.little);
      offset += 8;
      if (offset + nameLength > data.lengthInBytes) return null;
      streams.add(
        DenialAudioStream(
          id: id,
          name: _text(bytes, offset, nameLength),
          level: level,
          muted: muted,
        ),
      );
      offset += nameLength;
    }
    return UnmodifiableListView(streams);
  }

  static List<DenialAudioDevice>? decodeAudioDevices(ByteData? data) {
    if (data == null || data.lengthInBytes < 4) return null;
    final count = data.getUint32(0, Endian.little);
    if (count > (data.lengthInBytes - 4) ~/ 6) return null;
    if (count == 0) return const [];
    final devices = <DenialAudioDevice>[];
    final bytes = Uint8List.sublistView(data);
    var offset = 4;
    for (var i = 0; i < count; i++) {
      if (offset + 6 > data.lengthInBytes) return null;
      final active = data.getUint8(offset) != 0;
      final available = data.getUint8(offset + 1) != 0;
      final nameLength = data.getUint16(offset + 2, Endian.little);
      final descriptionLength = data.getUint16(offset + 4, Endian.little);
      offset += 6;
      if (offset + nameLength + descriptionLength > data.lengthInBytes) {
        return null;
      }
      devices.add(
        DenialAudioDevice(
          name: _text(bytes, offset, nameLength),
          description: _text(bytes, offset + nameLength, descriptionLength),
          active: active,
          available: available,
        ),
      );
      offset += nameLength + descriptionLength;
    }
    return UnmodifiableListView(devices);
  }

  static ({int monitorId, double level})? decodeBrightness(ByteData? data) {
    if (data == null || data.lengthInBytes < 9) return null;
    final monitorId = data.getInt64(0, Endian.little);
    if (monitorId < 0) return null;
    return (monitorId: monitorId, level: _percent(data, 8));
  }

  static ({int monitorId, double level, bool supported})? decodeSoftwareDimming(
    ByteData? data,
  ) {
    if (data == null || data.lengthInBytes < 10) return null;
    final monitorId = data.getInt64(0, Endian.little);
    if (monitorId <= 0) return null;
    return (
      monitorId: monitorId,
      level: _percent(data, 8),
      supported: data.getUint8(9) != 0,
    );
  }

  static double _percent(ByteData data, int offset) =>
      data.getUint8(offset).clamp(0, 100) / 100.0;

  static String _text(Uint8List bytes, int offset, int length) =>
      const Utf8Decoder(allowMalformed: true)
          .convert(bytes, offset, offset + length);
}
