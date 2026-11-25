import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../denial_bridge_models.dart';
import '../system_control_protocol.dart';
import 'context.dart';

final class BridgeAudioClient {
  BridgeAudioClient(this._context);

  final BridgeContext _context;
  static const String _audioChannel = 'denial/audio';
  final _callVolumes = StreamController<DenialCallVolume>.broadcast(sync: true);
  Stream<DenialCallVolume> get callVolumes => _callVolumes.stream;

  Set<Completer<double?>> _pendingAudioReads = {};
  final StreamController<DenialAudioState> _audioStates =
      StreamController<DenialAudioState>.broadcast(sync: true);
  final StreamController<List<DenialAudioStream>> _audioStreamStates =
      StreamController<List<DenialAudioStream>>.broadcast(sync: true);
  final StreamController<List<DenialAudioDevice>> _audioDeviceStates =
      StreamController<List<DenialAudioDevice>>.broadcast(sync: true);

  Future<double?> readAudioLevel() async {
    if (!_context.useControlSocket) return _readAudioLevelFromPlatform();
    try {
      final result = await _context.control.request('audio.get');
      final value = result['level'];
      if (value is! num) return null;
      final level = value.toDouble().clamp(0.0, 1.0);
      final requestSerial = result['request_serial'];
      final muted = result['muted'];
      final limitReached = result['limit_reached'];
      if (!_audioStates.isClosed) {
        _audioStates.add(
          DenialAudioState(
            level: level,
            requestSerial: requestSerial is int ? requestSerial : 0,
            muted: muted is bool && muted,
            limitReached: limitReached is bool && limitReached,
            completesRead: true,
          ),
        );
      }
      return level;
    } on Object {
      return _readAudioLevelFromPlatform();
    }
  }

  Future<double?> _readAudioLevelFromPlatform() {
    final completer = Completer<double?>();
    _pendingAudioReads.add(completer);
    final payload = ByteData(1)..setUint8(0, 0);
    _context.platform.send(_audioChannel, payload)?.catchError((Object _) {
      if (_pendingAudioReads.remove(completer) && !completer.isCompleted) {
        completer.complete(null);
      }
      return null;
    });
    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _pendingAudioReads.remove(completer);
        return null;
      },
    );
  }

  void setAudioLevel(int percent, {required int requestSerial}) {
    final resolvedPercent = percent.clamp(0, 100);
    if (!_context.useControlSocket) {
      final payload = ByteData(6)
        ..setUint8(0, 1)
        ..setUint8(1, resolvedPercent)
        ..setUint32(2, requestSerial & 0xffffffff, Endian.little);
      _context.platform
          .send(_audioChannel, payload)
          ?.catchError((Object _) => null);
      return;
    }
    unawaited(
      _context.control
          .request(
            'audio.set',
            parameters: <String, Object>{
              'percent': resolvedPercent,
              'request_serial': requestSerial & 0xffffffff,
            },
          )
          .catchError((Object _) {
            final payload = ByteData(6)
              ..setUint8(0, 1)
              ..setUint8(1, resolvedPercent)
              ..setUint32(2, requestSerial & 0xffffffff, Endian.little);
            _context.platform
                .send(_audioChannel, payload)
                ?.catchError((Object _) => null);
            return <String, Object?>{};
          }),
    );
  }

  void requestAudioStreams() {
    if (!_context.useControlSocket) {
      final payload = ByteData(1)..setUint8(0, 2);
      _context.platform
          .send(_audioChannel, payload)
          ?.catchError((Object _) => null);
      return;
    }
    unawaited(
      _context.control
          .request('audio.streams.get')
          .then((result) {
            final streams = _audioStreamsFromControl(result);
            if (!_audioStreamStates.isClosed) {
              _audioStreamStates.add(streams);
            }
          })
          .catchError((Object _) {
            final payload = ByteData(1)..setUint8(0, 2);
            _context.platform
                .send(_audioChannel, payload)
                ?.catchError((Object _) => null);
          }),
    );
  }

  void setAudioStreamLevel(int streamId, int percent) {
    final resolvedStreamId = streamId & 0xffffffff;
    final resolvedPercent = percent.clamp(0, 100);
    if (!_context.useControlSocket) {
      final payload = ByteData(6)
        ..setUint8(0, 3)
        ..setUint32(1, resolvedStreamId, Endian.little)
        ..setUint8(5, resolvedPercent);
      _context.platform
          .send(_audioChannel, payload)
          ?.catchError((Object _) => null);
      return;
    }
    unawaited(
      _context.control
          .request(
            'audio.stream.set',
            parameters: <String, Object>{
              'stream_id': resolvedStreamId,
              'percent': resolvedPercent,
            },
          )
          .catchError((Object _) {
            final payload = ByteData(6)
              ..setUint8(0, 3)
              ..setUint32(1, resolvedStreamId, Endian.little)
              ..setUint8(5, resolvedPercent);
            _context.platform
                .send(_audioChannel, payload)
                ?.catchError((Object _) => null);
            return <String, Object?>{};
          }),
    );
  }

  void requestAudioDevices() {
    if (!_context.useControlSocket) {
      final payload = ByteData(1)..setUint8(0, 4);
      _context.platform
          .send(_audioChannel, payload)
          ?.catchError((Object _) => null);
      return;
    }
    unawaited(
      _context.control
          .request('audio.devices.get')
          .then((result) {
            final devices = _audioDevicesFromControl(result);
            if (!_audioDeviceStates.isClosed) {
              _audioDeviceStates.add(devices);
            }
          })
          .catchError((Object _) {
            final payload = ByteData(1)..setUint8(0, 4);
            _context.platform
                .send(_audioChannel, payload)
                ?.catchError((Object _) => null);
          }),
    );
  }

  void setAudioDevice(String name) {
    final nameBytes = utf8.encode(name);
    if (nameBytes.isEmpty ||
        nameBytes.length > 1024 ||
        name.contains('\u0000')) {
      return;
    }
    if (!_context.useControlSocket) {
      _setAudioDeviceFromPlatform(nameBytes);
      return;
    }
    unawaited(
      _context.control
          .request(
            'audio.device.set',
            parameters: <String, Object>{'name': name},
          )
          .then((_) {
            requestAudioDevices();
          })
          .catchError((Object _) {
            _setAudioDeviceFromPlatform(nameBytes);
          }),
    );
  }

  void _setAudioDeviceFromPlatform(List<int> nameBytes) {
    final payload = ByteData(3 + nameBytes.length)
      ..setUint8(0, 5)
      ..setUint16(1, nameBytes.length, Endian.little)
      ..buffer.asUint8List().setRange(3, 3 + nameBytes.length, nameBytes);
    _context.platform
        .send(_audioChannel, payload)
        ?.catchError((Object _) => null);
  }

  List<DenialAudioStream> _audioStreamsFromControl(
    Map<String, Object?> result,
  ) {
    final values = result['streams'];
    if (values is! List<Object?>) {
      throw const FormatException('invalid audio streams');
    }
    return List<DenialAudioStream>.unmodifiable(
      values.map((value) {
        if (value is! Map<String, Object?>) {
          throw const FormatException('invalid audio stream');
        }
        final id = value['id'];
        final name = value['name'];
        final level = value['level'];
        final muted = value['muted'];
        if (id is! int || name is! String || level is! num || muted is! bool) {
          throw const FormatException('invalid audio stream');
        }
        return DenialAudioStream(
          id: id,
          name: name,
          level: level.toDouble().clamp(0.0, 1.0),
          muted: muted,
        );
      }),
    );
  }

  List<DenialAudioDevice> _audioDevicesFromControl(
    Map<String, Object?> result,
  ) {
    final values = result['devices'];
    if (values is! List<Object?>) {
      throw const FormatException('invalid audio devices');
    }
    return List<DenialAudioDevice>.unmodifiable(
      values.map((value) {
        if (value is! Map<String, Object?>) {
          throw const FormatException('invalid audio device');
        }
        final name = value['name'];
        final description = value['description'];
        final active = value['active'];
        final available = value['available'];
        if (name is! String ||
            description is! String ||
            active is! bool ||
            available is! bool) {
          throw const FormatException('invalid audio device');
        }
        return DenialAudioDevice(
          name: name,
          description: description,
          active: active,
          available: available,
        );
      }),
    );
  }

  Future<ByteData?> handleCallVolume(ByteData? data) async {
    final volume = SystemControlProtocol.decodeCallVolume(data);
    if (volume != null && !_callVolumes.isClosed) _callVolumes.add(volume);
    return null;
  }

  void setCallVolume(int step) {
    final payload = SystemControlProtocol.setCallVolume(step);
    _context.platform
        .send(_audioChannel, payload)
        ?.catchError((Object _) => null);
  }

  Future<ByteData?> handleState(ByteData? data) async {
    final update = SystemControlProtocol.decodeAudioState(data);
    if (update == null) return null;
    // Detach this response's readers before notifying synchronous listeners.
    // A listener may start a new read, which must await the next response.
    final pending = _pendingAudioReads.isEmpty ? null : _pendingAudioReads;
    if (pending != null) _pendingAudioReads = {};
    if (!_audioStates.isClosed) {
      _audioStates.add(
        DenialAudioState(
          level: update.level,
          requestSerial: update.requestSerial,
          muted: update.muted,
          limitReached: update.limitReached,
          fromKey: update.fromKey,
          completesRead: pending != null,
        ),
      );
    }
    if (pending != null) {
      for (final completer in pending) {
        if (!completer.isCompleted) {
          completer.complete(update.level);
        }
      }
    }
    return null;
  }

  Future<ByteData?> handleStreams(ByteData? data) async {
    if (_audioStreamStates.isClosed) return null;
    final streams = SystemControlProtocol.decodeAudioStreams(data);
    if (streams != null) _audioStreamStates.add(streams);
    return null;
  }

  Future<ByteData?> handleDevices(ByteData? data) async {
    if (_audioDeviceStates.isClosed) return null;
    final devices = SystemControlProtocol.decodeAudioDevices(data);
    if (devices != null) _audioDeviceStates.add(devices);
    return null;
  }

  Stream<DenialAudioState> get audioStates => _audioStates.stream;

  Stream<List<DenialAudioStream>> get audioStreamStates =>
      _audioStreamStates.stream;

  Stream<List<DenialAudioDevice>> get audioDeviceStates =>
      _audioDeviceStates.stream;
  void dispose() {
    for (final pending in _pendingAudioReads) {
      if (!pending.isCompleted) pending.complete(null);
    }
    _pendingAudioReads.clear();
    unawaited(_callVolumes.close());
    unawaited(_audioStates.close());
    unawaited(_audioStreamStates.close());
    unawaited(_audioDeviceStates.close());
  }
}
