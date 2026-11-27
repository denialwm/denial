import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:path/path.dart' as p;

/// One desktop notification as the user sees it.
final class NotificationContent {
  const NotificationContent({
    required this.title,
    required this.body,
    this.actions = const [],
    this.resident = false,
    this.persistent = false,
  });
  final String title;
  final String body;

  /// Action keys and labels, in presentation order. The `default` key is the
  /// notification body itself.
  final List<(String, String)> actions;

  /// Stays visible after one of its actions was invoked.
  final bool resident;

  /// Never expires; the user or its sender closes it.
  final bool persistent;
}

sealed class NotificationEvent {
  const NotificationEvent(this.id);
  final int id;
}

final class NotificationActionInvoked extends NotificationEvent {
  const NotificationActionInvoked(super.id, this.key, this.activationToken);
  final String key;

  /// Lets the launched window take focus, when the server provided one.
  final String? activationToken;
}

final class NotificationClosed extends NotificationEvent {
  const NotificationClosed(super.id);
}

abstract interface class Notifier {
  Stream<NotificationEvent> get events;

  /// Shows [content], replacing notification [replaces] while it is open.
  Future<int> show(NotificationContent content, {int replaces = 0});
  Future<void> close(int id);
  Future<void> dispose();
}

/// org.freedesktop.Notifications on the session bus, which Denial serves.
final class DesktopNotifications implements Notifier {
  DesktopNotifications._(this._client, this._object);

  static const _interface = 'org.freedesktop.Notifications';

  /// Connects to the session bus, or to [client] when tests provide one.
  ///
  /// deniald claims the service from its event loop, which starts just after
  /// it launches this process. Wait for that owner: activating the service
  /// early could start another notification daemon in Denial's place.
  static Future<DesktopNotifications> connect({
    DBusClient? client,
    Duration wait = const Duration(minutes: 1),
  }) async {
    client ??= DBusClient.session();
    final notifications = DesktopNotifications._(
      client,
      DBusRemoteObject(
        client,
        name: _interface,
        path: DBusObjectPath('/org/freedesktop/Notifications'),
      ),
    );
    try {
      final deadline = DateTime.now().add(wait);
      while (!await client.nameHasOwner(_interface)) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('no notification server owns $_interface');
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      await notifications._subscribe();
      await notifications._object.callMethod(
        _interface,
        'GetCapabilities',
        const [],
        replySignature: DBusSignature('as'),
        noAutoStart: true,
      );
      return notifications;
    } catch (_) {
      await notifications.dispose();
      rethrow;
    }
  }

  final DBusClient _client;
  final DBusRemoteObject _object;
  final _events = StreamController<NotificationEvent>.broadcast();
  final _subscriptions = <StreamSubscription<DBusSignal>>[];
  // The server announces an action's token just before the action itself.
  final _tokens = <int, String>{};

  @override
  Stream<NotificationEvent> get events => _events.stream;

  Future<void> _subscribe() async {
    Stream<DBusSignal> signal(String name, String signature) =>
        DBusRemoteObjectSignalStream(
          object: _object,
          interface: _interface,
          name: name,
          signature: DBusSignature(signature),
        );
    _subscriptions
      ..add(
        signal('ActivationToken', 'us').listen((signal) {
          _tokens[signal.values[0].asUint32()] = signal.values[1].asString();
        }),
      )
      ..add(
        signal('ActionInvoked', 'us').listen((signal) {
          final id = signal.values[0].asUint32();
          _events.add(
            NotificationActionInvoked(
              id,
              signal.values[1].asString(),
              _tokens.remove(id),
            ),
          );
        }),
      )
      ..add(
        signal('NotificationClosed', 'uu').listen((signal) {
          final id = signal.values[0].asUint32();
          _tokens.remove(id);
          _events.add(NotificationClosed(id));
        }),
      );
  }

  @override
  Future<int> show(NotificationContent content, {int replaces = 0}) async {
    final response = await _object.callMethod(
      _interface,
      'Notify',
      [
        const DBusString('Plugins'),
        DBusUint32(replaces),
        const DBusString('preferences-desktop'),
        DBusString(content.title),
        DBusString(content.body),
        DBusArray.string([
          for (final (key, label) in content.actions) ...[key, label],
        ]),
        DBusDict.stringVariant({
          'desktop-entry': const DBusString('org.denialwm.Settings'),
          'urgency': const DBusByte(1),
          if (content.resident) 'resident': const DBusBoolean(true),
        }),
        DBusInt32(content.persistent ? 0 : -1),
      ],
      replySignature: DBusSignature('u'),
      noAutoStart: true,
    );
    return response.values.single.asUint32();
  }

  @override
  Future<void> close(int id) async {
    await _object.callMethod(
      _interface,
      'CloseNotification',
      [DBusUint32(id)],
      replySignature: DBusSignature(''),
      noAutoStart: true,
    );
  }

  @override
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _events.close();
    await _client.close();
  }
}

/// NetworkManager's global connectivity: true when connected, false when
/// it knows the session is offline, null when nobody can tell.
Future<bool?> networkConnected() async {
  final client = DBusClient.system();
  try {
    final state = await DBusRemoteObject(
      client,
      name: 'org.freedesktop.NetworkManager',
      path: DBusObjectPath('/org/freedesktop/NetworkManager'),
    ).getProperty('org.freedesktop.NetworkManager', 'State');
    final value = state.asUint32();
    // NM_STATE_CONNECTED_GLOBAL is 70; 0 means NetworkManager cannot tell.
    return value == 0 ? null : value == 70;
  } catch (_) {
    return null;
  } finally {
    await client.close();
  }
}

/// The command line of an installed desktop entry, or null when it is not
/// installed. Field codes are dropped: no files or URLs are passed.
List<String>? desktopEntryCommand(
  String id, {
  Map<String, String>? environment,
}) {
  final env = environment ?? Platform.environment;
  final home = env['HOME'];
  final dataHome =
      env['XDG_DATA_HOME'] ??
      (home == null ? null : p.join(home, '.local/share'));
  final dataDirs = (env['XDG_DATA_DIRS'] ?? '/usr/local/share:/usr/share')
      .split(':')
      .where((directory) => directory.isNotEmpty);
  for (final directory in [?dataHome, ...dataDirs]) {
    final file = File(p.join(directory, 'applications', id));
    if (!file.existsSync()) continue;
    var inEntry = false;
    for (final line in file.readAsLinesSync()) {
      final trimmed = line.trim();
      if (trimmed.startsWith('[')) {
        inEntry = trimmed == '[Desktop Entry]';
      } else if (inEntry && trimmed.startsWith('Exec=')) {
        final command = _splitExec(trimmed.substring(5));
        return command.isEmpty ? null : command;
      }
    }
    // The first entry with this ID is the one launchers use.
    return null;
  }
  return null;
}

List<String> _splitExec(String value) {
  final arguments = <String>[];
  final current = StringBuffer();
  var quoted = false;
  var started = false;
  for (var index = 0; index < value.length; index++) {
    final character = value[index];
    if (character == r'\' && quoted && index + 1 < value.length) {
      current.write(value[++index]);
    } else if (character == '"') {
      quoted = !quoted;
      started = true;
    } else if (character == ' ' && !quoted) {
      if (started) arguments.add(current.toString());
      current.clear();
      started = false;
    } else {
      current.write(character);
      started = true;
    }
  }
  if (started) arguments.add(current.toString());
  return [
    for (final argument in arguments)
      if (!RegExp(r'^%[a-zA-Z]$').hasMatch(argument))
        argument.replaceAll('%%', '%'),
  ];
}

/// Starts a detached process that may take focus with [activationToken].
Future<void> launchDetached(
  List<String> command, {
  String? activationToken,
}) async {
  await Process.start(
    command.first,
    command.skip(1).toList(),
    mode: ProcessStartMode.detached,
    environment: {
      if (activationToken != null) ...{
        'XDG_ACTIVATION_TOKEN': activationToken,
        'DESKTOP_STARTUP_ID': activationToken,
      },
    },
  );
}
