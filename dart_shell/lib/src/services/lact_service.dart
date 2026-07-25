import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

final lactServiceProvider = Provider<LactService>((ref) => LactService());

typedef LactRequestSender =
    Future<Object?> Function(Map<String, Object?> request);

abstract final class LactPerformancePreset {
  static const String low = 'low';
  static const String automatic = 'auto';
  static const String high = 'high';

  static const Set<String> values = <String>{low, automatic, high};

  static String? normalize(Object? value) {
    if (value is! String) {
      return null;
    }
    final normalized = value.trim().toLowerCase();
    return values.contains(normalized) ? normalized : null;
  }
}

class LactAmdPerformanceSnapshot {
  const LactAmdPerformanceSnapshot({
    required this.available,
    required this.preset,
  });

  const LactAmdPerformanceSnapshot.unavailable()
    : available = false,
      preset = null;

  final bool available;
  final String? preset;
}

/// Minimal client for LACT's newline-delimited JSON API.
///
/// Only the first AMD GPU is targeted. Configuration changes use LACT's
/// get/set/confirm flow so every unrelated tuning value survives unchanged.
class LactService {
  LactService({
    this.socketPath = '/run/lactd.sock',
    LactRequestSender? requestSender,
  }) : _requestSender =
           requestSender ??
           ((request) => _sendSocketRequest(socketPath, request));

  static const Duration _requestTimeout = Duration(seconds: 2);
  static const String _amdVendorPrefix = '1002:';

  final String socketPath;
  final LactRequestSender _requestSender;

  Future<LactAmdPerformanceSnapshot> readAmdPerformancePreset() async {
    try {
      final target = await _readAmdConfig();
      return LactAmdPerformanceSnapshot(
        available: true,
        preset: LactPerformancePreset.normalize(
          target.config['performance_level'],
        ),
      );
    } on Object {
      return const LactAmdPerformanceSnapshot.unavailable();
    }
  }

  Future<void> applyAmdPerformancePreset(String preset) async {
    if (!LactPerformancePreset.values.contains(preset)) {
      throw ArgumentError.value(
        preset,
        'preset',
        'Preset prestazioni LACT non valido',
      );
    }

    final target = await _readAmdConfig();
    if (LactPerformancePreset.normalize(target.config['performance_level']) ==
        preset) {
      return;
    }

    final updatedConfig = Map<String, Object?>.from(target.config)
      ..['performance_level'] = preset;
    await _requestSender(<String, Object?>{
      'command': 'set_gpu_config',
      'args': <String, Object?>{'id': target.id, 'config': updatedConfig},
    });
    await _requestSender(<String, Object?>{
      'command': 'confirm_pending_config',
      'args': <String, Object?>{'command': 'confirm'},
    });
  }

  Future<({String id, Map<String, Object?> config})> _readAmdConfig() async {
    final id = await _findAmdGpuId();
    final data = await _requestSender(<String, Object?>{
      'command': 'get_gpu_config',
      'args': <String, Object?>{'id': id},
    });
    if (data is! Map) {
      throw StateError('Configurazione GPU AMD non disponibile in LACT');
    }
    return (id: id, config: Map<String, Object?>.from(data));
  }

  Future<String> _findAmdGpuId() async {
    final data = await _requestSender(<String, Object?>{
      'command': 'list_devices',
    });
    if (data is! List) {
      throw StateError('Elenco GPU LACT non valido');
    }

    for (final device in data) {
      if (device is! Map) {
        continue;
      }
      final id = device['id'];
      if (id is String && id.toUpperCase().startsWith(_amdVendorPrefix)) {
        return id;
      }
    }
    throw StateError('GPU AMD non disponibile in LACT');
  }

  static Future<Object?> _sendSocketRequest(
    String socketPath,
    Map<String, Object?> request,
  ) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
        timeout: _requestTimeout,
      );
      socket.add(utf8.encode('${jsonEncode(request)}\n'));
      await socket.flush().timeout(_requestTimeout);

      final responseLine = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(_requestTimeout);
      final response = jsonDecode(responseLine);
      if (response is! Map) {
        throw StateError('Risposta LACT non valida');
      }
      if (response['status'] != 'ok') {
        final detail = response['data']?.toString().trim();
        throw StateError(
          detail == null || detail.isEmpty
              ? 'Richiesta LACT non riuscita'
              : detail,
        );
      }
      return response['data'];
    } on TimeoutException {
      throw StateError('Il daemon LACT non risponde');
    } on SocketException catch (error) {
      throw StateError('Daemon LACT non disponibile: ${error.message}');
    } on FormatException {
      throw StateError('Risposta LACT non valida');
    } finally {
      socket?.destroy();
    }
  }
}
