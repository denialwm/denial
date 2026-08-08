import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final logindServiceProvider = Provider<LogindBackend>((ref) {
  final service = LogindService();
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

enum LogindAction {
  suspend('Suspend', 'sleep'),
  hibernate('Hibernate', 'sleep'),
  reboot('Reboot', 'shutdown'),
  powerOff('PowerOff', 'shutdown');

  const LogindAction(this.method, this.inhibitorClass);

  final String method;
  final String inhibitorClass;
}

enum LogindCapability {
  available,
  authenticationRequired,
  denied,
  unsupported,
  unavailable;

  bool get canRequest =>
      this == LogindCapability.available ||
      this == LogindCapability.authenticationRequired;
}

@immutable
class LogindInhibitor {
  LogindInhibitor({
    required Set<String> what,
    required this.who,
    required this.why,
    required this.mode,
    required this.uid,
    required this.pid,
  }) : what = Set<String>.unmodifiable(what);

  final Set<String> what;
  final String who;
  final String why;
  final String mode;
  final int uid;
  final int pid;

  bool affects(LogindAction action) => what.contains(action.inhibitorClass);

  bool blocks(LogindAction action) => mode == 'block' && affects(action);

  bool delays(LogindAction action) => mode == 'delay' && affects(action);

  String get description {
    if (who.isNotEmpty && why.isNotEmpty) {
      return '$who: $why';
    }
    if (why.isNotEmpty) {
      return why;
    }
    if (who.isNotEmpty) {
      return who;
    }
    return 'An application is preventing this action';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LogindInhibitor &&
          setEquals(other.what, what) &&
          other.who == who &&
          other.why == why &&
          other.mode == mode &&
          other.uid == uid &&
          other.pid == pid;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(what.toList()..sort()),
    who,
    why,
    mode,
    uid,
    pid,
  );
}

@immutable
class LogindSnapshot {
  LogindSnapshot({
    required this.serviceAvailable,
    required Map<LogindAction, LogindCapability> capabilities,
    required List<LogindInhibitor> inhibitors,
  }) : capabilities = Map<LogindAction, LogindCapability>.unmodifiable(
         capabilities,
       ),
       inhibitors = List<LogindInhibitor>.unmodifiable(inhibitors);

  LogindSnapshot.unavailable()
    : serviceAvailable = false,
      capabilities = Map<LogindAction, LogindCapability>.unmodifiable(
        <LogindAction, LogindCapability>{
          for (final action in LogindAction.values)
            action: LogindCapability.unavailable,
        },
      ),
      inhibitors = const <LogindInhibitor>[];

  final bool serviceAvailable;
  final Map<LogindAction, LogindCapability> capabilities;
  final List<LogindInhibitor> inhibitors;

  LogindCapability capabilityFor(LogindAction action) =>
      capabilities[action] ?? LogindCapability.unavailable;

  List<LogindInhibitor> blockersFor(LogindAction action) => inhibitors
      .where((inhibitor) => inhibitor.blocks(action))
      .toList(growable: false);

  List<LogindInhibitor> delaysFor(LogindAction action) => inhibitors
      .where((inhibitor) => inhibitor.delays(action))
      .toList(growable: false);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LogindSnapshot &&
          other.serviceAvailable == serviceAvailable &&
          mapEquals(other.capabilities, capabilities) &&
          listEquals(other.inhibitors, inhibitors);

  @override
  int get hashCode => Object.hash(
    serviceAvailable,
    Object.hashAll(
      LogindAction.values.map(
        (action) => Object.hash(action, capabilities[action]),
      ),
    ),
    Object.hashAll(inhibitors),
  );
}

abstract interface class LogindBackend {
  Stream<LogindSnapshot> get snapshots;

  LogindSnapshot get currentSnapshot;

  Future<void> start();

  Future<void> refresh();

  Future<void> perform(LogindAction action);

  Future<void> dispose();
}

class LogindActionUnavailableException implements Exception {
  const LogindActionUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LogindService implements LogindBackend {
  factory LogindService({DBusClient? client}) {
    return LogindService._(client ?? DBusClient.system());
  }

  LogindService._(this._client)
    : _manager = DBusRemoteObject(
        _client,
        name: _serviceName,
        path: DBusObjectPath(_managerPath),
      );

  static const String _serviceName = 'org.freedesktop.login1';
  static const String _managerPath = '/org/freedesktop/login1';
  static const String _managerInterface = 'org.freedesktop.login1.Manager';
  static const Duration _readTimeout = Duration(seconds: 4);
  static const Duration _actionTimeout = Duration(seconds: 30);
  static const Duration _signalCoalesce = Duration(milliseconds: 75);

  final DBusClient _client;
  final DBusRemoteObject _manager;
  final StreamController<LogindSnapshot> _snapshots =
      StreamController<LogindSnapshot>.broadcast(sync: true);

  StreamSubscription<DBusSignal>? _signalSubscription;
  StreamSubscription<DBusNameOwnerChangedEvent>? _ownerSubscription;
  Timer? _refreshTimer;
  bool _started = false;
  bool _disposed = false;
  bool _refreshing = false;
  bool _refreshAgain = false;
  Completer<void>? _refreshSettled;
  LogindSnapshot _current = LogindSnapshot.unavailable();

  @override
  Stream<LogindSnapshot> get snapshots => _snapshots.stream;

  @override
  LogindSnapshot get currentSnapshot => _current;

  @override
  Future<void> start() async {
    if (_started || _disposed) {
      return;
    }
    _started = true;
    _signalSubscription = DBusSignalStream(
      _client,
      sender: _serviceName,
      path: DBusObjectPath(_managerPath),
    ).listen((_) => _scheduleRefresh(), onError: (_) => _scheduleRefresh());
    _ownerSubscription = _client.nameOwnerChanged
        .where((event) => event.name == _serviceName)
        .listen((event) {
          if (event.newOwner == null) {
            _refreshTimer?.cancel();
            _emit(LogindSnapshot.unavailable());
          } else {
            _scheduleRefresh(immediate: true);
          }
        });
    await refresh();
  }

  @override
  Future<void> refresh() async {
    if (_disposed) {
      return;
    }
    if (_refreshing) {
      _refreshAgain = true;
      final settled = _refreshSettled ??= Completer<void>();
      await settled.future;
      return;
    }
    _refreshing = true;
    try {
      do {
        _refreshAgain = false;
        try {
          final snapshot = await _readSnapshot();
          if (!_disposed) {
            _emit(snapshot);
          }
        } on Object {
          if (!_disposed) {
            _emit(LogindSnapshot.unavailable());
          }
        }
      } while (_refreshAgain && !_disposed);
    } finally {
      _refreshing = false;
      final settled = _refreshSettled;
      _refreshSettled = null;
      if (settled != null && !settled.isCompleted) {
        settled.complete();
      }
    }
  }

  @override
  Future<void> perform(LogindAction action) async {
    if (_disposed) {
      throw const LogindActionUnavailableException(
        'The session service is unavailable',
      );
    }

    // Capability and inhibitor state is intentionally refreshed immediately
    // before a system-changing request. There is no reliable inhibitor-change
    // signal in logind, so this one-shot read is the authoritative guard.
    await refresh();
    final capability = _current.capabilityFor(action);
    if (!capability.canRequest) {
      throw LogindActionUnavailableException(_capabilityFailure(capability));
    }
    final blockers = _current.blockersFor(action);
    if (blockers.isNotEmpty) {
      throw LogindActionUnavailableException(blockers.first.description);
    }

    await _manager
        .callMethod(_managerInterface, action.method, const <DBusValue>[
          DBusBoolean(true),
        ], replySignature: DBusSignature(''))
        .timeout(_actionTimeout);
  }

  Future<LogindSnapshot> _readSnapshot() async {
    final replies = await Future.wait<DBusMethodSuccessResponse>(
      <Future<DBusMethodSuccessResponse>>[
        for (final action in LogindAction.values)
          _manager
              .callMethod(
                _managerInterface,
                'Can${action.method}',
                const <DBusValue>[],
                replySignature: DBusSignature('s'),
              )
              .timeout(_readTimeout),
        _manager
            .callMethod(
              _managerInterface,
              'ListInhibitors',
              const <DBusValue>[],
              replySignature: DBusSignature('a(ssssuu)'),
            )
            .timeout(_readTimeout),
      ],
    );

    final capabilities = <LogindAction, LogindCapability>{};
    for (var index = 0; index < LogindAction.values.length; index += 1) {
      final values = replies[index].returnValues;
      capabilities[LogindAction.values[index]] = values.length == 1
          ? parseLogindCapability(values.single.asString())
          : LogindCapability.unavailable;
    }
    final inhibitorValues = replies.last.returnValues;
    final inhibitors = inhibitorValues.length == 1
        ? parseLogindInhibitors(inhibitorValues.single)
        : const <LogindInhibitor>[];
    return LogindSnapshot(
      serviceAvailable: true,
      capabilities: capabilities,
      inhibitors: inhibitors,
    );
  }

  void _scheduleRefresh({bool immediate = false}) {
    if (_disposed) {
      return;
    }
    _refreshTimer?.cancel();
    _refreshTimer = Timer(immediate ? Duration.zero : _signalCoalesce, () {
      _refreshTimer = null;
      unawaited(refresh());
    });
  }

  void _emit(LogindSnapshot snapshot) {
    if (snapshot == _current) {
      return;
    }
    _current = snapshot;
    if (!_snapshots.isClosed) {
      _snapshots.add(snapshot);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _refreshTimer?.cancel();
    await _signalSubscription?.cancel();
    await _ownerSubscription?.cancel();
    await _snapshots.close();
    await _client.close();
  }
}

LogindCapability parseLogindCapability(String value) => switch (value) {
  'yes' => LogindCapability.available,
  'challenge' => LogindCapability.authenticationRequired,
  'no' => LogindCapability.denied,
  'na' => LogindCapability.unsupported,
  _ => LogindCapability.unavailable,
};

List<LogindInhibitor> parseLogindInhibitors(
  DBusValue value, {
  int maximum = 64,
}) {
  if (value is! DBusArray || maximum <= 0) {
    return const <LogindInhibitor>[];
  }

  final result = <LogindInhibitor>[];
  for (final entry in value.children) {
    if (result.length >= maximum ||
        entry is! DBusStruct ||
        entry.children.length != 6) {
      continue;
    }
    try {
      final fields = entry.children;
      final mode = fields[3].asString();
      if (mode != 'block' && mode != 'delay') {
        continue;
      }
      final what = fields[0]
          .asString()
          .split(':')
          .map((part) => _boundedText(part, 64))
          .where((part) => part.isNotEmpty)
          .take(16)
          .toSet();
      if (what.isEmpty) {
        continue;
      }
      result.add(
        LogindInhibitor(
          what: what,
          who: _boundedText(fields[1].asString(), 160),
          why: _boundedText(fields[2].asString(), 256),
          mode: mode,
          uid: fields[4].asUint32(),
          pid: fields[5].asUint32(),
        ),
      );
    } on Object {
      // A malformed third-party inhibitor must not poison the entire surface.
    }
  }
  return List<LogindInhibitor>.unmodifiable(result);
}

String _capabilityFailure(LogindCapability capability) => switch (capability) {
  LogindCapability.denied => 'This action is not authorized',
  LogindCapability.unsupported => 'This action is not supported',
  _ => 'The session service is unavailable',
};

String _boundedText(String value, int maximumRunes) {
  final normalized = value
      .replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final runes = normalized.runes.take(maximumRunes).toList(growable: false);
  return String.fromCharCodes(runes);
}
