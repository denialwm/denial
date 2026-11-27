import 'dart:async';

import 'package:dbus/dbus.dart';

import '../models/mpris_playback.dart';
import 'mpris_playback_protocol.dart';
import 'mpris_read_reconciliation.dart';

class MediaPlayerService {
  factory MediaPlayerService({
    DBusClient? client,
    DBusRemoteObject Function(String serviceName)? playerFactory,
    DateTime Function()? now,
  }) {
    final bus = client ?? DBusClient.session();
    return MediaPlayerService._(
      bus,
      playerFactory ??
          (name) => DBusRemoteObject(
            bus,
            name: name,
            path: DBusObjectPath(_objectPath),
          ),
      now ?? DateTime.now,
    );
  }

  MediaPlayerService._(this._client, this._createPlayer, this._now);

  static const String _servicePrefix = 'org.mpris.MediaPlayer2.';
  static const String _objectPath = '/org/mpris/MediaPlayer2';
  static const String _rootInterface = 'org.mpris.MediaPlayer2';
  static const String _playerInterface = 'org.mpris.MediaPlayer2.Player';
  static const Duration _readTimeout = Duration(seconds: 2);
  static const Duration _methodTimeout = Duration(seconds: 4);
  static const Duration _recoveryInterval = Duration(minutes: 1);
  static const Duration _signalCoalesce = Duration(milliseconds: 45);
  static const Duration _unavailableGrace = Duration(seconds: 2);
  static const int _maxPlayers = 16;

  final DBusClient _client;
  final DBusRemoteObject Function(String serviceName) _createPlayer;
  final DateTime Function() _now;
  final StreamController<MprisPlaybackState> _snapshots =
      StreamController<MprisPlaybackState>.broadcast(sync: true);

  StreamSubscription<DBusNameOwnerChangedEvent>? _ownerSubscription;
  StreamSubscription<DBusPropertiesChangedSignal>? _propertiesSubscription;
  StreamSubscription<DBusSignal>? _seekedSubscription;
  StreamSubscription<DBusSignal>? _statusSubscription;
  Timer? _refreshTimer;
  Timer? _signalTimer;
  Timer? _unavailableTimer;
  DBusRemoteObject? _activeObject;
  MprisPlaybackState _current = MprisPlaybackState.unavailable();
  bool _started = false;
  bool _disposed = false;
  Completer<void>? _refreshCompletion;
  bool _refreshAgain = false;
  bool _unavailableGraceElapsed = false;
  MprisReadReconciliation? _activeRead;

  Stream<MprisPlaybackState> get snapshots => _snapshots.stream;

  MprisPlaybackState get current => _current;

  Future<void> start() {
    if (_disposed) return Future<void>.value();
    if (_started) return _refreshCompletion?.future ?? Future<void>.value();
    _started = true;
    _ownerSubscription = _client.nameOwnerChanged
        .where((event) => event.name.startsWith(_servicePrefix))
        .listen((_) => _scheduleRefresh(immediate: true));
    // Only the selected player has a properties subscription. Any player's
    // PlaybackStatus change can decide which one is shown, so the others'
    // changes rescan instead of waiting for the recovery scan.
    _statusSubscription = DBusSignalStream(
      _client,
      interface: 'org.freedesktop.DBus.Properties',
      name: 'PropertiesChanged',
      path: DBusObjectPath(_objectPath),
    ).listen(_handleStatusSignal, onError: (Object _) {});
    _refreshTimer = Timer.periodic(
      _recoveryInterval,
      (_) => _scheduleRefresh(immediate: true),
    );
    return refresh();
  }

  Future<void> refresh() {
    if (_disposed) return Future<void>.value();
    _signalTimer?.cancel();
    _signalTimer = null;
    _refreshAgain = true;
    if (_refreshCompletion case final completion?) return completion.future;
    final completion = _refreshCompletion = Completer<void>();
    unawaited(_refreshPlayers(completion));
    return completion.future;
  }

  Future<void> _refreshPlayers(Completer<void> completion) async {
    try {
      while (_refreshAgain && !_disposed) {
        _refreshAgain = false;
        try {
          final names = await _listPlayerNames();
          if (_disposed) break;
          final reads = await Future.wait(names.map(_readPlayer));
          if (_disposed) break;
          // Only the winner is needed. Keep the existing status/name ordering
          // without allocating and sorting a second candidate list.
          final shown = _activeObject?.name;
          _MprisCandidate? candidate;
          for (final read in reads) {
            if (read == null) continue;
            final state = read.resolve();
            if (state == null) continue;
            final next = _MprisCandidate(object: read.object, state: state);
            if (candidate == null || _ranksBefore(next, candidate, shown)) {
              candidate = next;
            }
          }
          if (candidate == null || !candidate.state.available) {
            await _handleUnavailable();
          } else {
            _cancelUnavailableGrace();
            // Avoid yielding between reconciliation and publication when the
            // subscription already belongs to this player.
            if (_activeObject?.name != candidate.object.name) {
              await _selectPlayer(candidate.object);
            }
            _emit(candidate.state);
          }
        } on Object {
          if (!_disposed) await _handleUnavailable();
        } finally {
          _activeRead = null;
        }
      }
      completion.complete();
    } on Object catch (error, stackTrace) {
      completion.completeError(error, stackTrace);
    } finally {
      _refreshCompletion = null;
    }
  }

  Future<void> previous() => _invoke('Previous', _current.canGoPrevious);

  Future<void> next() => _invoke('Next', _current.canGoNext);

  Future<void> playPause() => _invoke(
    'PlayPause',
    _current.playing ? _current.canPause : _current.canPlay,
  );

  Future<void> _invoke(String method, bool supported) async {
    final object = _activeObject;
    if (object == null || !supported || _disposed) {
      return;
    }
    try {
      await object
          .callMethod(
            _playerInterface,
            method,
            const <DBusValue>[],
            replySignature: DBusSignature(''),
          )
          .timeout(_methodTimeout);
    } on Object {
      // The player can disappear between hover and click.
    }
  }

  Future<Iterable<String>> _listPlayerNames() async {
    return (await _client.listNames().timeout(_readTimeout))
        .where((name) => name.startsWith(_servicePrefix))
        .take(_maxPlayers);
  }

  Future<_MprisRead?> _readPlayer(String serviceName) async {
    // The selected object already owns the properties subscription. Reuse its
    // proxy instead of rebuilding its signal streams on each recovery scan.
    final active = _activeObject;
    final object = active?.name == serviceName
        ? active!
        : _createPlayer(serviceName);
    final changes = identical(object, active)
        ? _activeRead = MprisReadReconciliation(_current)
        : null;
    try {
      final (player, root) = await (
        object
            .getAllProperties(_playerInterface)
            .timeout(_readTimeout)
            .then((properties) => (properties: properties, observedAt: _now())),
        object.getAllProperties(_rootInterface).timeout(_readTimeout),
      ).wait;
      if (_disposed) return null;
      return _MprisRead(
        object: object,
        player: player.properties,
        root: root,
        observedAt: player.observedAt,
        changes: changes,
      );
    } on Object {
      return null;
    }
  }

  Future<void> _selectPlayer(DBusRemoteObject? object) async {
    if (_disposed || _activeObject?.name == object?.name) {
      return;
    }
    final previous = [?_propertiesSubscription, ?_seekedSubscription];
    _propertiesSubscription = null;
    _seekedSubscription = null;
    await Future.wait([
      for (final subscription in previous) subscription.cancel(),
    ]);
    if (_disposed) return;
    _activeObject = object;
    if (object != null) {
      _propertiesSubscription = object.propertiesChanged
          .where((signal) => signal.propertiesInterface == _playerInterface)
          .listen(_handlePropertiesChanged, onError: (_) => _scheduleRefresh());
      // MPRIS reports a seek only with Seeked: players never send Position
      // in PropertiesChanged, so without it the playhead stays put.
      _seekedSubscription = DBusRemoteObjectSignalStream(
        object: object,
        interface: _playerInterface,
        name: 'Seeked',
      ).listen(_handleSeeked, onError: (Object _) {});
    }
  }

  void _handleStatusSignal(DBusSignal signal) {
    if (_disposed || signal.signature.value != 'sa{sv}as') return;
    final [interface, changed, _] = signal.values;
    if (interface.asString() == _playerInterface &&
        changed.asStringVariantDict().containsKey('PlaybackStatus')) {
      _scheduleRefresh();
    }
  }

  void _handleSeeked(DBusSignal signal) {
    if (signal.signature.value != 'x') return;
    _applyPlayerChanges({'Position': signal.values.single});
  }

  void _handlePropertiesChanged(DBusPropertiesChangedSignal signal) {
    if (_disposed || _activeObject?.name != _current.serviceName) {
      return;
    }
    if (signal.values[2].asStringArray().any(mprisPlayerProperties.contains)) {
      _scheduleRefresh();
    }
    _applyPlayerChanges(signal.changedProperties);
  }

  void _applyPlayerChanges(Map<String, DBusValue> changed) {
    if (_disposed || _activeObject?.name != _current.serviceName) {
      return;
    }
    final activeRead = _activeRead;
    final changes = activeRead?.current.serviceName == _activeObject?.name
        ? activeRead
        : null;
    final next = applyMprisPlayerProperties(
      changes?.current ?? _current,
      changed,
      _now(),
    );
    if (next == null) {
      return;
    }
    changes?.record(changed, next);
    if (!next.available) {
      // Another paused or playing service may already be available. A full
      // scan happens only on this topology-relevant transition, not for every
      // metadata or position signal.
      _scheduleRefresh();
      return;
    }
    _cancelUnavailableGrace();
    _emit(next);
  }

  void _scheduleRefresh({bool immediate = false}) {
    if (_disposed) {
      return;
    }
    _signalTimer?.cancel();
    _signalTimer = Timer(immediate ? Duration.zero : _signalCoalesce, () {
      _signalTimer = null;
      unawaited(refresh().catchError((Object _) {}));
    });
  }

  Future<void> _handleUnavailable() async {
    if (_disposed) return;
    if (_current.available && !_unavailableGraceElapsed) {
      _unavailableTimer ??= Timer(_unavailableGrace, () {
        _unavailableTimer = null;
        _unavailableGraceElapsed = true;
        _scheduleRefresh(immediate: true);
      });
      return;
    }
    _cancelUnavailableGrace();
    await _selectPlayer(null);
    _emit(MprisPlaybackState.unavailable());
  }

  void _cancelUnavailableGrace() {
    _unavailableTimer?.cancel();
    _unavailableTimer = null;
    _unavailableGraceElapsed = false;
  }

  void _emit(MprisPlaybackState state) {
    if (_disposed || identical(state, _current)) return;
    _current = state;
    if (!_snapshots.isClosed) {
      _snapshots.add(state);
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _refreshAgain = false;
    _refreshTimer?.cancel();
    _signalTimer?.cancel();
    _unavailableTimer?.cancel();
    await _ownerSubscription?.cancel();
    await _statusSubscription?.cancel();
    await _propertiesSubscription?.cancel();
    await _seekedSubscription?.cancel();
    await _snapshots.close();
    await _client.close();
  }
}

class const _MprisCandidate({
  required final DBusRemoteObject object,
  required final MprisPlaybackState state,
});

class const _MprisRead({
  required final DBusRemoteObject object,
  required final Map<String, DBusValue> player,
  required final Map<String, DBusValue> root,
  required final DateTime observedAt,
  required final MprisReadReconciliation? changes,
}) {
  MprisPlaybackState? resolve() {
    try {
      final reconciliation = changes;
      return reconciliation == null
          ? parseMprisPlaybackState(object.name, player, root, observedAt)
          : reconciliation.resolve(object.name, player, root, observedAt);
    } on Object {
      // One malformed player must not discard the other candidates.
      return null;
    }
  }
}

int _statusPriority(MprisPlaybackStatus status) => switch (status) {
  MprisPlaybackStatus.playing => 0,
  MprisPlaybackStatus.paused => 1,
  MprisPlaybackStatus.stopped => 2,
};

/// Playing before paused. On equal status the player already [shown] keeps
/// its place, so rescans never swap two paused players; identity decides the
/// rest.
bool _ranksBefore(_MprisCandidate left, _MprisCandidate right, String? shown) {
  final byStatus =
      _statusPriority(left.state.status) - _statusPriority(right.state.status);
  if (byStatus != 0) return byStatus < 0;
  final leftShown = left.object.name == shown;
  if (leftShown != (right.object.name == shown)) return leftShown;
  return left.state.identity.compareTo(right.state.identity) < 0;
}
