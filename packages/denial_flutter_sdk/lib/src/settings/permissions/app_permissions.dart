import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What an app may ask Denial for. Each permission is one entry of the portal
/// permission store, keyed by app ID.
enum AppPermission {
  /// Receive the keys Denial uses for its own shortcuts while focused.
  keyboardShortcuts('denial', 'shortcuts-inhibit');

  const AppPermission(this.table, this.id);

  final String table;
  final String id;
}

enum AppPermissionAnswer {
  /// Ask the next time the app wants it.
  ask('ask'),
  allow('yes'),
  deny('no');

  const AppPermissionAnswer(this.stored);

  /// The value in the permission store.
  final String stored;

  /// Any value but `yes` and `no` asks.
  static AppPermissionAnswer fromStored(String? value) => switch (value) {
    'yes' => allow,
    'no' => deny,
    _ => ask,
  };
}

/// The stored answers of every app that was asked, by permission and app ID.
typedef AppPermissionAnswers =
    Map<AppPermission, Map<String, AppPermissionAnswer>>;

final appPermissionsServiceProvider =
    Provider.autoDispose<AppPermissionsService>((ref) {
      final service = AppPermissionsService();
      ref.onDispose(service.close);
      return service;
    });

/// Follows the store, so an app that asks while Settings is open appears.
final appPermissionsProvider = StreamProvider.autoDispose<AppPermissionAnswers>(
  (ref) => ref.watch(appPermissionsServiceProvider).watch(),
);

/// Reads and changes the answers in `xdg-permission-store`. The apps' askers,
/// such as deniald, follow its changes themselves.
class AppPermissionsService {
  AppPermissionsService({DBusClient? client})
    : _client = client ?? DBusClient.session(),
      _ownsClient = client == null;

  static const _service = 'org.freedesktop.impl.portal.PermissionStore';
  static const _interface = 'org.freedesktop.impl.portal.PermissionStore';
  static final _path = DBusObjectPath(
    '/org/freedesktop/impl/portal/PermissionStore',
  );
  static const _timeout = Duration(seconds: 3);

  final DBusClient _client;
  final bool _ownsClient;
  late final _store = DBusRemoteObject(_client, name: _service, path: _path);

  Stream<AppPermissionAnswers> watch() {
    late final StreamController<AppPermissionAnswers> controller;
    StreamSubscription<DBusSignal>? changes;
    var generation = 0;
    Future<void> reload() async {
      final current = ++generation;
      try {
        final answers = await read();
        if (current == generation && !controller.isClosed) {
          controller.add(answers);
        }
      } catch (error, stack) {
        if (current == generation && !controller.isClosed) {
          controller.addError(error, stack);
        }
      }
    }

    controller = StreamController<AppPermissionAnswers>(
      onListen: () {
        // No sender: the store starts on demand. A signal only causes a read.
        changes =
            DBusSignalStream(
              _client,
              interface: _interface,
              name: 'Changed',
              path: _path,
            ).listen((signal) {
              if (signal.values
                  case [
                    DBusString(value: final table),
                    DBusString(value: final id),
                    ...,
                  ]
                  when AppPermission.values.any(
                    (permission) =>
                        permission.table == table && permission.id == id,
                  )) {
                unawaited(reload());
              }
            }, onError: (Object _) {});
        unawaited(reload());
      },
      onCancel: () => changes?.cancel(),
    );
    return controller.stream;
  }

  Future<AppPermissionAnswers> read() async => {
    for (final permission in AppPermission.values)
      permission: await _lookup(permission),
  };

  Future<Map<String, AppPermissionAnswer>> _lookup(
    AppPermission permission,
  ) async {
    final DBusMethodSuccessResponse reply;
    try {
      reply = await _store
          .callMethod(_interface, 'Lookup', [
            DBusString(permission.table),
            DBusString(permission.id),
          ], replySignature: DBusSignature('a{sas}v'))
          .timeout(_timeout);
    } on DBusMethodResponseException catch (error) {
      // The entry exists once an app was asked.
      if (error.errorName == 'org.freedesktop.portal.Error.NotFound') {
        return const {};
      }
      rethrow;
    }
    final answers = <String, AppPermissionAnswer>{};
    final entries = reply.returnValues.first as DBusDict;
    for (final MapEntry(:key, :value) in entries.children.entries) {
      final values = (value as DBusArray).children;
      answers[(key as DBusString).value] = AppPermissionAnswer.fromStored(
        values.isEmpty ? null : (values.first as DBusString).value,
      );
    }
    return answers;
  }

  Future<void> set(
    AppPermission permission,
    String appId,
    AppPermissionAnswer answer,
  ) => _store
      .callMethod(_interface, 'SetPermission', [
        DBusString(permission.table),
        const DBusBoolean(true),
        DBusString(permission.id),
        DBusString(appId),
        DBusArray.string([answer.stored]),
      ], replySignature: DBusSignature(''))
      .timeout(_timeout);

  Future<void> close() async {
    if (_ownsClient) await _client.close();
  }
}
