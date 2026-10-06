import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final lockFrameRequestProvider = NotifierProvider<LockFrameRequest, int>(
  LockFrameRequest.new,
);

/// Native keeps KMS off until a frame authorized after this handshake is ready.
class LockFrameRequest extends Notifier<int> {
  static const _channel = BasicMessageChannel<String>(
    'denial/lock_frame',
    StringCodec(),
  );
  bool _disposed = false;
  int _acknowledged = 0;

  @override
  int build() {
    _disposed = false;
    _channel.setMessageHandler((message) async {
      _receive(message);
      return '';
    });
    ref.onDispose(() {
      _disposed = true;
      _channel.setMessageHandler(null);
    });
    unawaited(
      _channel.send('sync').then((message) {
        if (!_disposed && state == 0) _receive(message);
      }),
    );
    return 0;
  }

  void _receive(String? message) {
    if (_disposed || message == null) return;
    final token = int.tryParse(message);
    if (token == null || token < 0) return;
    state = token;
  }

  /// Called only after the secure stage built the fully settled lock layout.
  Future<void> laidOut(int token) async {
    if (_disposed || token == 0 || state != token || _acknowledged == token) {
      return;
    }
    _acknowledged = token;
    await _channel.send('$token');
    if (_disposed || state != token) return;
    // Native has accepted the token before authorizing this replacement frame.
    // The acknowledgement frame itself may already have been rasterized with
    // an old token and is deliberately ineligible for display wake.
    WidgetsBinding.instance.scheduleFrame();
  }
}
