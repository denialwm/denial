import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'context.dart';

class InputDeckSnapshot {
  const InputDeckSnapshot({
    this.touchOutput,
    this.touchOutputs = const [],
    this.keyLabels = const {},
    this.available = false,
    this.locked = false,
    this.activeOutput,
  });
  final String? touchOutput;
  final List<String> touchOutputs;
  final Map<int, String> keyLabels;
  final bool available;
  final bool locked;
  final String? activeOutput;

  factory InputDeckSnapshot.fromJson(Map<String, dynamic> json) =>
      InputDeckSnapshot(
        touchOutput: json['touch_output'] as String?,
        touchOutputs: List<String>.unmodifiable(
          (json['touch_outputs'] as List?)?.cast<String>() ?? const [],
        ),
        keyLabels: Map<int, String>.unmodifiable({
          for (final entry in (json['key_labels'] as Map? ?? const {}).entries)
            int.parse(entry.key as String): entry.value as String,
        }),
        available: json['available'] == true,
        locked: json['locked'] == true,
        activeOutput: json['active_output'] as String?,
      );
}

final class BridgeInputDeckClient {
  BridgeInputDeckClient(this._context);
  final BridgeContext _context;
  final _states = StreamController<InputDeckSnapshot>.broadcast(sync: true);
  Stream<InputDeckSnapshot> get states => _states.stream;

  void send(Map<String, Object?> command) {
    if (_context.useControlSocket) return;
    _context.platform
        .send(
          'denial/input_deck',
          ByteData.sublistView(
            Uint8List.fromList(utf8.encode(jsonEncode(command))),
          ),
        )
        ?.catchError((Object _) => null);
  }

  Future<void> read() async {
    if (!_context.useControlSocket) {
      send({'kind': 'read'});
      return;
    }
    try {
      final response = await _context.control.request('settings.input.get');
      final value = response['input_deck'];
      if (!_states.isClosed && value is Map<String, dynamic>) {
        _states.add(InputDeckSnapshot.fromJson(value));
      }
    } on Object {
      /* The unavailable state leaves the mode disabled. */
    }
  }

  Future<ByteData?> handleState(ByteData? packet) async {
    if (packet == null || _states.isClosed) return null;
    try {
      final value = jsonDecode(
        utf8.decode(
          packet.buffer.asUint8List(packet.offsetInBytes, packet.lengthInBytes),
        ),
      );
      if (value is Map<String, dynamic>) {
        _states.add(InputDeckSnapshot.fromJson(value));
      }
    } on Object {
      // A malformed or incompatible state cannot enable the deck.
    }
    return null;
  }

  void dispose() => unawaited(_states.close());
}
