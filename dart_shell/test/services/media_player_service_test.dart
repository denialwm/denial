import 'package:dbus/dbus.dart';
import 'package:denial_dart_shell/src/services/media_player_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('player property signals update cached state without a rescan', () {
    final observedAt = DateTime(2026, 8, 25, 10);
    final current = MprisPlaybackState(
      serviceName: 'org.mpris.MediaPlayer2.test',
      identity: 'Test Player',
      title: 'Old title',
      artists: const <String>['Old artist'],
      album: 'Old album',
      artUrl: '',
      length: const Duration(minutes: 4),
      position: const Duration(seconds: 20),
      observedAt: observedAt,
      status: MprisPlaybackStatus.playing,
      canGoNext: false,
      canGoPrevious: false,
      canPlay: true,
      canPause: true,
    );
    final now = observedAt.add(const Duration(seconds: 2));

    final updated = applyMprisPlayerProperties(current, <String, DBusValue>{
      'PlaybackStatus': const DBusString('Paused'),
      'Position': const DBusInt64(42 * Duration.microsecondsPerSecond),
      'CanGoNext': const DBusBoolean(true),
      'Metadata': DBusDict.stringVariant(<String, DBusValue>{
        'mpris:length': const DBusInt64(5 * Duration.microsecondsPerMinute),
        'xesam:title': const DBusString('New title'),
        'xesam:artist': DBusArray.string(const <String>['New artist']),
        'xesam:album': const DBusString('New album'),
      }),
    }, now);

    expect(updated, isNotNull);
    expect(updated!.status, MprisPlaybackStatus.paused);
    expect(updated.position, const Duration(seconds: 42));
    expect(updated.length, const Duration(minutes: 5));
    expect(updated.title, 'New title');
    expect(updated.artists, const <String>['New artist']);
    expect(updated.album, 'New album');
    expect(updated.canGoNext, isTrue);
    expect(updated.canPause, isTrue);
    expect(updated.observedAt, now);
  });

  test('irrelevant property signals do not publish a new snapshot', () {
    final current = MprisPlaybackState.unavailable();

    expect(
      applyMprisPlayerProperties(current, const <String, DBusValue>{
        'Volume': DBusDouble(0.5),
      }, DateTime(2026, 8, 25)),
      isNull,
    );
  });
}
