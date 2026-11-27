import 'package:dbus/dbus.dart';
import 'package:test/test.dart';

import 'package:denial_flutter_sdk/src/services/mpris_playback_protocol.dart';

void main() {
  final now = DateTime.utc(2026);

  Duration? lengthOf(DBusValue length) => parseMprisPlaybackState(
    'org.mpris.MediaPlayer2.test',
    {
      'PlaybackStatus': const DBusString('Paused'),
      'Metadata': DBusDict.stringVariant({'mpris:length': length}),
    },
    const {},
    now,
  )?.length;

  test('reads length sent as any integer or floating type', () {
    const micros = 180000000;
    for (final value in <DBusValue>[
      const DBusInt64(micros),
      const DBusUint64(micros),
      const DBusInt32(micros),
      const DBusUint32(micros),
      const DBusDouble(180000000.4),
    ]) {
      expect(
        lengthOf(value),
        const Duration(microseconds: micros),
        reason: value.signature.value,
      );
    }
  });

  test('reads position sent as int32', () {
    final state = parseMprisPlaybackState(
      'org.mpris.MediaPlayer2.test',
      {
        'PlaybackStatus': const DBusString('Paused'),
        'Metadata': DBusDict.stringVariant({
          'mpris:length': const DBusInt64(180000000),
        }),
        'Position': const DBusInt32(42000000),
      },
      const {},
      now,
    );
    expect(state?.position, const Duration(seconds: 42));
  });

  test('a non-finite or out of range double stays in range', () {
    expect(lengthOf(const DBusDouble(double.nan)), Duration.zero);
    expect(
      lengthOf(const DBusDouble(double.infinity)),
      const Duration(days: 7),
    );
    expect(lengthOf(const DBusDouble(-5)), Duration.zero);
  });
}
