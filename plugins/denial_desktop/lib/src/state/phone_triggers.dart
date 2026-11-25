import 'dart:io' show Directory, File, FileSystemException;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// KEY_MACRO1 and KEY_MACRO2: the left and right shoulder trigger.
const List<int> _triggerKeys = <int>[0x290, 0x291];

/// Whether this device has shoulder triggers: an input device that sends
/// either trigger key. Read once; the triggers are part of the phone.
final phoneTriggersAvailableProvider = Provider<bool>((ref) => _hasTriggers());

/// The app id whose trigger spots are being placed, or null while the
/// editor is closed.
final triggerPointsEditorProvider =
    NotifierProvider<TriggerPointsEditor, String?>(TriggerPointsEditor.new);

class TriggerPointsEditor extends Notifier<String?> {
  @override
  String? build() => null;

  void open(String appId) => state = appId.isEmpty ? null : appId;

  void close() => state = null;
}

bool _hasTriggers() {
  try {
    for (final entry in Directory('/sys/class/input').listSync()) {
      if (!entry.path.split('/').last.startsWith('input')) continue;
      final File keys = File('${entry.path}/capabilities/key');
      final words = keys.readAsStringSync().trim().split(' ');
      if (_triggerKeys.any((code) => _hasKey(words, code))) return true;
    }
  } on FileSystemException {
    return false;
  }
  return false;
}

/// The kernel prints a key bitmap as hexadecimal 64-bit words, the highest
/// first.
bool _hasKey(List<String> words, int code) {
  final index = words.length - 1 - code ~/ 64;
  if (index < 0) return false;
  final word = BigInt.tryParse(words[index], radix: 16);
  return word != null && (word >> (code % 64)).isOdd;
}
