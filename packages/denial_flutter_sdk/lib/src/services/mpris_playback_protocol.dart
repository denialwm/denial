import 'package:collection/collection.dart';
import 'package:dbus/dbus.dart';

import '../core/bounded_text.dart';
import '../models/mpris_playback.dart';

const _maximumLengthMicros = 7 * 24 * 60 * 60 * 1000000;
const _servicePrefix = 'org.mpris.MediaPlayer2.';

const mprisPlayerProperties = {
  'Metadata',
  'Position',
  'PlaybackStatus',
  'CanGoNext',
  'CanGoPrevious',
  'CanPlay',
  'CanPause',
};

MprisPlaybackState? parseMprisPlaybackState(
  String serviceName,
  Map<String, DBusValue> player,
  Map<String, DBusValue> root,
  DateTime now,
) {
  final status = _playbackStatus(_string(player['PlaybackStatus']));
  if (status == MprisPlaybackStatus.stopped) return null;
  final suffix = serviceName.indexOf('.', _servicePrefix.length);
  final identity = normalizeBoundedText(
    _string(
      root['Identity'],
      fallback: serviceName.substring(
        _servicePrefix.length,
        suffix < 0 ? null : suffix,
      ),
    ),
    128,
  );
  final metadata = _readMetadata(player['Metadata'], identity);
  return MprisPlaybackState(
    serviceName: serviceName,
    identity: identity,
    title: metadata.title,
    artists: metadata.artists,
    album: metadata.album,
    artUrl: metadata.artUrl,
    length: Duration(microseconds: metadata.lengthMicros),
    position: Duration(
      microseconds: _position(player['Position'], metadata.lengthMicros),
    ),
    observedAt: now,
    status: status,
    canGoNext: _boolean(player['CanGoNext']),
    canGoPrevious: _boolean(player['CanGoPrevious']),
    canPlay: _boolean(player['CanPlay']),
    canPause: _boolean(player['CanPause']),
  );
}

/// Returns null for unrelated properties and retains [current] for unchanged
/// values. Explicit position reports always establish a new time anchor.
MprisPlaybackState? applyMprisPlayerProperties(
  MprisPlaybackState current,
  Map<String, DBusValue> changed,
  DateTime now,
) {
  final metadataValue = changed['Metadata'];
  final positionValue = changed['Position'];
  final statusValue = changed['PlaybackStatus'];
  final nextValue = changed['CanGoNext'];
  final previousValue = changed['CanGoPrevious'];
  final playValue = changed['CanPlay'];
  final pauseValue = changed['CanPause'];
  if (metadataValue == null &&
      positionValue == null &&
      statusValue == null &&
      nextValue == null &&
      previousValue == null &&
      playValue == null &&
      pauseValue == null) {
    return null;
  }
  final metadata = metadataValue == null
      ? null
      : _readMetadata(metadataValue, current.identity);
  final status = statusValue == null
      ? current.status
      : _playbackStatus(_string(statusValue));
  final canGoNext = nextValue == null ? current.canGoNext : _boolean(nextValue);
  final canGoPrevious = previousValue == null
      ? current.canGoPrevious
      : _boolean(previousValue);
  final canPlay = playValue == null ? current.canPlay : _boolean(playValue);
  final canPause = pauseValue == null ? current.canPause : _boolean(pauseValue);
  final lengthMicros = metadata?.lengthMicros ?? current.length.inMicroseconds;
  final title = metadata?.title ?? current.title;
  final album = metadata?.album ?? current.album;
  final artUrl = metadata?.artUrl ?? current.artUrl;
  final sameArtists =
      metadata == null ||
      const ListEquality<String>().equals(metadata.artists, current.artists);
  final artists = sameArtists ? current.artists : metadata.artists;

  if (positionValue == null &&
      status == current.status &&
      canGoNext == current.canGoNext &&
      canGoPrevious == current.canGoPrevious &&
      canPlay == current.canPlay &&
      canPause == current.canPause &&
      lengthMicros == current.length.inMicroseconds &&
      title == current.title &&
      album == current.album &&
      artUrl == current.artUrl &&
      sameArtists) {
    return current;
  }
  final positionMicros = positionValue != null
      ? _position(positionValue, lengthMicros)
      : current
            .positionAt(now)
            .inMicroseconds
            .clamp(0, lengthMicros > 0 ? lengthMicros : 1 << 53);
  return MprisPlaybackState(
    serviceName: current.serviceName,
    identity: current.identity,
    title: title,
    artists: artists,
    album: album,
    artUrl: artUrl,
    length: metadata == null
        ? current.length
        : Duration(microseconds: lengthMicros),
    position: Duration(microseconds: positionMicros),
    observedAt: now,
    status: status,
    canGoNext: canGoNext,
    canGoPrevious: canGoPrevious,
    canPlay: canPlay,
    canPause: canPause,
  );
}

typedef _Metadata = ({
  int lengthMicros,
  String title,
  List<String> artists,
  String album,
  String artUrl,
});

_Metadata _readMetadata(DBusValue? value, String identity) {
  Map<String, DBusValue> properties;
  try {
    properties = value?.asStringVariantDict() ?? const {};
  } on Object {
    properties = const {};
  }
  final title = normalizeBoundedText(_string(properties['xesam:title']), 256);
  Iterable<String> artists;
  try {
    artists = properties['xesam:artist']?.asStringArray() ?? const [];
  } on Object {
    artists = const [];
  }
  return (
    lengthMicros: _integer(properties['mpris:length'])
        .clamp(0, _maximumLengthMicros),
    title: title.isEmpty ? identity : title,
    artists: List.unmodifiable(
      artists
          .map((name) => normalizeBoundedText(name, 128))
          .where((name) => name.isNotEmpty)
          .take(8),
    ),
    album: normalizeBoundedText(_string(properties['xesam:album']), 256),
    artUrl: _safeArtworkUrl(_string(properties['mpris:artUrl'])),
  );
}

int _position(DBusValue? value, int lengthMicros) =>
    _integer(value)
        .clamp(0, lengthMicros > 0 ? lengthMicros : _maximumLengthMicros);

MprisPlaybackStatus _playbackStatus(String value) => switch (value) {
  'Playing' => MprisPlaybackStatus.playing,
  'Paused' => MprisPlaybackStatus.paused,
  _ => MprisPlaybackStatus.stopped,
};

String _string(DBusValue? value, {String fallback = ''}) =>
    value is DBusString ? value.value : fallback;

bool _boolean(DBusValue? value) => value is DBusBoolean && value.value;

/// MPRIS types length and position as int64, but some players send other
/// numbers. Reading those as zero hid the progress.
int _integer(DBusValue? value) => switch (value) {
  DBusInt64(:final value) ||
  DBusUint64(:final value) ||
  DBusInt32(:final value) ||
  DBusUint32(:final value) ||
  DBusInt16(:final value) ||
  DBusUint16(:final value) ||
  DBusByte(:final value) => value,
  // Callers clamp to this range anyway; clamping first keeps round() finite.
  DBusDouble(:final value) when !value.isNaN =>
    value.clamp(0, _maximumLengthMicros).round(),
  _ => 0,
};

String _safeArtworkUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      (uri.scheme != 'file' && uri.scheme != 'http' && uri.scheme != 'https')) {
    return '';
  }
  return uri.toString();
}
