import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final fingerprintSceneProvider =
    NotifierProvider<FingerprintSceneController, FingerprintScene>(
      FingerprintSceneController.new,
    );

class FingerprintScene {
  const FingerprintScene({
    this.epoch = 0,
    this.black = false,
    this.reveal = false,
    this.fade = false,
    this.texture,
    this.target = Rect.zero,
    this.output = Rect.zero,
  });
  final int epoch;
  final bool black;
  final bool reveal;
  final bool fade;
  bool get fading => reveal || fade;
  final int? texture;
  final Rect target;
  final Rect output;
}

class FingerprintSceneController extends Notifier<FingerprintScene> {
  static const _channel = BasicMessageChannel<String>(
    'denial/fingerprint_scene',
    StringCodec(),
  );
  bool _disposed = false;
  int _acknowledged = 0;
  @override
  FingerprintScene build() {
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
        if (!_disposed && state.epoch == 0) _receive(message);
      }),
    );
    return const FingerprintScene();
  }

  void _receive(String? message) {
    if (_disposed || message == null || message.isEmpty) return;
    final data = jsonDecode(message) as Map<String, dynamic>;
    final epoch = data['epoch'] as int;
    if (epoch <= state.epoch) return;
    double n(String key) => (data[key] as num).toDouble();
    state = FingerprintScene(
      epoch: epoch,
      black: data['black'] as bool,
      reveal: data['reveal'] as bool,
      fade: data['fade'] as bool? ?? false,
      texture: data['texture'] as int?,
      target: Rect.fromLTWH(n('x'), n('y'), n('width'), n('height')),
      output: Rect.fromLTWH(
        n('outputX'),
        n('outputY'),
        n('outputWidth'),
        n('outputHeight'),
      ),
    );
  }

  Future<void> laidOut(int epoch) async {
    if (_disposed ||
        epoch == 0 ||
        state.epoch != epoch ||
        _acknowledged == epoch)
      return;
    _acknowledged = epoch;
    await _channel.send('$epoch');
    if (!_disposed && state.epoch == epoch)
      WidgetsBinding.instance.scheduleFrame();
  }
}
