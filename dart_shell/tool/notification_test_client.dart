import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';

const _interface = 'org.freedesktop.Notifications';
const _serviceName = 'org.freedesktop.Notifications';
const _objectPath = '/org/freedesktop/Notifications';
const _appName = 'Denial Notification Test';

Future<void> main(List<String> arguments) async {
  final command = arguments.isEmpty ? 'help' : arguments.first;
  if (command == 'help' || command == '--help' || command == '-h') {
    _printUsage();
    return;
  }

  final client = NotificationTestClient();
  try {
    switch (command) {
      case 'info':
        await client.printServerInformation();
      case 'basic':
        await client.sendBasic();
      case 'stack':
        await client.sendStack();
      case 'markup':
        await client.sendMarkup();
      case 'urgency':
      case 'urgencies':
        await client.sendUrgencies();
      case 'image':
        await client.sendImage();
      case 'replace':
      case 'progress':
        await client.sendProgressReplacement();
      case 'actions':
        await client.sendActions(wait: !arguments.contains('--no-wait'));
      case 'suite':
        await client.sendSuite(wait: !arguments.contains('--no-wait'));
      case 'listen':
        await client.listen();
      case 'close':
        if (arguments.length != 2) {
          throw const FormatException('close requires one notification ID');
        }
        final id = int.tryParse(arguments[1]);
        if (id == null || id <= 0 || id > 0xffffffff) {
          throw FormatException('invalid notification ID: ${arguments[1]}');
        }
        await client.closeNotification(id);
        stdout.writeln('Closed notification #$id');
      default:
        throw FormatException('unknown command: $command');
    }
  } on DBusServiceUnknownException {
    stderr.writeln(
      'No org.freedesktop.Notifications service is available on the session '
      'bus.',
    );
    exitCode = 2;
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln();
    _printUsage(stream: stderr);
    exitCode = 64;
  } on Object catch (error) {
    stderr.writeln('Notification test failed: $error');
    exitCode = 1;
  } finally {
    await client.close();
  }
}

void _printUsage({IOSink? stream}) {
  final output = stream ?? stdout;
  output.writeln('''
Usage: tools/notification-test-client COMMAND [OPTION]

Commands:
  info                 Print server identity and capabilities
  basic                Send a plain notification
  stack                Send three staggered, expiring notifications
  markup               Send body markup and a themed icon
  urgency              Send low, normal, and critical notifications
  image                Send generated raw RGBA image-data
  replace              Replace one progress notification several times
  actions [--no-wait]  Send actions and wait for the D-Bus round trip
  suite [--no-wait]    Run every scenario, then wait for an action
  listen               Print action, close, and activation-token signals
  close ID             Close a live notification through D-Bus
''');
}

class NotificationTestClient {
  NotificationTestClient({DBusClient? bus})
    : _bus = bus ?? DBusClient.session() {
    _object = DBusRemoteObject(
      _bus,
      name: _serviceName,
      path: DBusObjectPath(_objectPath),
    );
    actionInvoked =
        DBusRemoteObjectSignalStream(
          object: _object,
          interface: _interface,
          name: 'ActionInvoked',
          signature: DBusSignature('us'),
        ).map(
          (signal) => ActionInvokedEvent(
            id: signal.values[0].asUint32(),
            actionKey: signal.values[1].asString(),
          ),
        );
    notificationClosed =
        DBusRemoteObjectSignalStream(
          object: _object,
          interface: _interface,
          name: 'NotificationClosed',
          signature: DBusSignature('uu'),
        ).map(
          (signal) => NotificationClosedEvent(
            id: signal.values[0].asUint32(),
            reason: signal.values[1].asUint32(),
          ),
        );
    activationToken =
        DBusRemoteObjectSignalStream(
          object: _object,
          interface: _interface,
          name: 'ActivationToken',
          signature: DBusSignature('us'),
        ).map(
          (signal) => ActivationTokenEvent(
            id: signal.values[0].asUint32(),
            token: signal.values[1].asString(),
          ),
        );
  }

  final DBusClient _bus;
  late final DBusRemoteObject _object;
  late final Stream<ActionInvokedEvent> actionInvoked;
  late final Stream<NotificationClosedEvent> notificationClosed;
  late final Stream<ActivationTokenEvent> activationToken;

  Future<void> close() => _bus.close();

  Future<List<String>> capabilities() async {
    final response = await _object.callMethod(
      _interface,
      'GetCapabilities',
      const [],
      replySignature: DBusSignature('as'),
    );
    return response.returnValues.single.asStringArray().toList();
  }

  Future<void> printServerInformation() async {
    final response = await _object.callMethod(
      _interface,
      'GetServerInformation',
      const [],
      replySignature: DBusSignature('ssss'),
    );
    final values = response.returnValues;
    stdout.writeln('Server:       ${values[0].asString()}');
    stdout.writeln('Vendor:       ${values[1].asString()}');
    stdout.writeln('Version:      ${values[2].asString()}');
    stdout.writeln('Specification: ${values[3].asString()}');
    final supported = await capabilities();
    stdout.writeln(
      'Capabilities: ${supported.isEmpty ? '(none)' : supported.join(', ')}',
    );
  }

  Future<int> notify(NotificationRequest request) async {
    if (request.actions.length.isOdd) {
      throw ArgumentError.value(
        request.actions,
        'actions',
        'action keys and labels must be pairs',
      );
    }
    final response = await _object.callMethod(_interface, 'Notify', [
      DBusString(request.appName),
      DBusUint32(request.replacesId),
      DBusString(request.appIcon),
      DBusString(request.summary),
      DBusString(request.body),
      DBusArray.string(request.actions),
      DBusDict.stringVariant(request.hints),
      DBusInt32(request.expireTimeoutMs),
    ], replySignature: DBusSignature('u'));
    final id = response.returnValues.single.asUint32();
    stdout.writeln('Sent #$id: ${request.summary}');
    return id;
  }

  Future<void> closeNotification(int id) async {
    await _object.callMethod(_interface, 'CloseNotification', [
      DBusUint32(id),
    ], replySignature: DBusSignature(''));
  }

  Future<int> sendBasic() {
    return notify(
      NotificationRequest(
        summary: 'A normal desktop notification',
        body: 'Plain UTF-8 body text from the Denial test client. ✓',
        appIcon: 'dialog-information',
        expireTimeoutMs: 6000,
        hints: const {
          'urgency': DBusByte(1),
          'category': DBusString('device'),
          'desktop-entry': DBusString('denial-notification-test'),
        },
      ),
    );
  }

  Future<List<int>> sendStack() async {
    const messages = <(String, String)>[
      ('First notification', 'The oldest card expires first.'),
      ('Second notification', 'New notifications stack underneath.'),
      ('Third notification', 'Each card keeps its own six-second timeout.'),
    ];
    final ids = <int>[];
    for (var index = 0; index < messages.length; index += 1) {
      final (summary, body) = messages[index];
      ids.add(
        await notify(
          NotificationRequest(
            summary: summary,
            body: body,
            appIcon: 'dialog-information',
            expireTimeoutMs: 6000,
            hints: const {
              'urgency': DBusByte(1),
              'category': DBusString('test.stack'),
              'desktop-entry': DBusString('denial-notification-test'),
            },
          ),
        ),
      );
      if (index < messages.length - 1) {
        await Future<void>.delayed(const Duration(milliseconds: 650));
      }
    }
    return ids;
  }

  Future<int> sendMarkup() {
    return notify(
      NotificationRequest(
        summary: 'Supported body markup',
        body:
            'This has <b>bold</b>, <i>italic</i>, <u>underline</u>, a '
            '<a href="https://example.com">link</a>, and\na second line.',
        appIcon: 'mail-unread',
        expireTimeoutMs: 9000,
        hints: const {
          'urgency': DBusByte(1),
          'category': DBusString('email.arrived'),
        },
      ),
    );
  }

  Future<List<int>> sendUrgencies() async {
    final ids = <int>[];
    ids.add(
      await notify(
        NotificationRequest(
          summary: 'Low urgency',
          body: 'Short-lived and transient; it should not enter history.',
          appIcon: 'dialog-information',
          expireTimeoutMs: 3500,
          hints: const {'urgency': DBusByte(0), 'transient': DBusBoolean(true)},
        ),
      ),
    );
    ids.add(
      await notify(
        NotificationRequest(
          summary: 'Normal urgency',
          body: 'This uses the server default timeout.',
          appIcon: 'dialog-information',
          hints: const {'urgency': DBusByte(1)},
        ),
      ),
    );
    ids.add(
      await notify(
        NotificationRequest(
          summary: 'Critical urgency',
          body: 'This must remain until the user or client dismisses it.',
          appIcon: 'dialog-warning',
          expireTimeoutMs: 0,
          hints: const {
            'urgency': DBusByte(2),
            'category': DBusString('device.error'),
          },
        ),
      ),
    );
    return ids;
  }

  Future<int> sendImage() {
    const size = 48;
    final pixels = <int>[];
    for (var y = 0; y < size; y += 1) {
      for (var x = 0; x < size; x += 1) {
        final light = ((x ~/ 8) + (y ~/ 8)).isEven;
        pixels.addAll(
          light ? const [126, 87, 194, 255] : const [41, 34, 58, 255],
        );
      }
    }
    final image = DBusStruct([
      const DBusInt32(size),
      const DBusInt32(size),
      const DBusInt32(size * 4),
      const DBusBoolean(true),
      const DBusInt32(8),
      const DBusInt32(4),
      DBusArray.byte(pixels),
    ]);
    return notify(
      NotificationRequest(
        summary: 'Raw image-data',
        body: 'A generated 48×48 RGBA checkerboard using (iiibiiay).',
        appIcon: 'applications-graphics',
        expireTimeoutMs: 9000,
        hints: {'urgency': const DBusByte(1), 'image-data': image},
      ),
    );
  }

  Future<int> sendProgressReplacement() async {
    var id = await notify(
      NotificationRequest(
        summary: 'Copying desktop assets',
        body: 'Starting…',
        appIcon: 'folder-download',
        expireTimeoutMs: 0,
        hints: const {
          'urgency': DBusByte(0),
          'category': DBusString('transfer'),
          'value': DBusInt32(0),
          'x-canonical-private-synchronous': DBusString('denial-copy'),
        },
      ),
    );

    for (final progress in const [25, 50, 75]) {
      await Future<void>.delayed(const Duration(milliseconds: 450));
      final replacementId = await notify(
        NotificationRequest(
          replacesId: id,
          summary: 'Copying desktop assets',
          body: '$progress% complete',
          appIcon: 'folder-download',
          expireTimeoutMs: 0,
          hints: {
            'urgency': const DBusByte(0),
            'category': const DBusString('transfer'),
            'value': DBusInt32(progress),
            'x-canonical-private-synchronous': const DBusString('denial-copy'),
          },
        ),
      );
      if (replacementId != id) {
        throw StateError('server changed replacement ID $id to $replacementId');
      }
      id = replacementId;
    }

    await Future<void>.delayed(const Duration(milliseconds: 450));
    final completedId = await notify(
      NotificationRequest(
        replacesId: id,
        summary: 'Desktop assets copied',
        body: 'Replacement completed without removing and re-adding the card.',
        appIcon: 'emblem-default',
        expireTimeoutMs: 6000,
        hints: const {
          'urgency': DBusByte(1),
          'category': DBusString('transfer.complete'),
          'value': DBusInt32(100),
          'x-canonical-private-synchronous': DBusString('denial-copy'),
        },
      ),
    );
    if (completedId != id) {
      throw StateError('server changed replacement ID $id to $completedId');
    }
    return completedId;
  }

  Future<int> sendActions({required bool wait}) async {
    final supported = await capabilities();
    if (!supported.contains('actions')) {
      stderr.writeln(
        'Warning: the server does not advertise the actions capability.',
      );
    }

    final id = await notify(
      NotificationRequest(
        summary: 'Interactive notification',
        body: 'Invoke the notification or choose Reply or Archive.',
        appIcon: 'mail-unread',
        actions: const [
          'default',
          'Open',
          'reply',
          'Reply',
          'archive',
          'Archive',
        ],
        expireTimeoutMs: 0,
        hints: const {
          'urgency': DBusByte(1),
          'category': DBusString('im.received'),
          'resident': DBusBoolean(true),
          'action-icons': DBusBoolean(false),
          'desktop-entry': DBusString('denial-notification-test'),
        },
      ),
    );

    if (wait) {
      await _waitForInteraction(id);
    } else {
      stdout.writeln(
        'Action notification #$id remains resident; use the listen command '
        'to observe signals.',
      );
    }
    return id;
  }

  Future<void> sendSuite({required bool wait}) async {
    await printServerInformation();
    stdout.writeln();
    await sendBasic();
    await sendMarkup();
    await sendUrgencies();
    await sendImage();
    await sendProgressReplacement();
    await sendActions(wait: wait);
  }

  Future<void> listen() async {
    stdout.writeln('Listening for notification signals; press Ctrl+C to stop.');
    final subscriptions = <StreamSubscription<Object>>[
      actionInvoked.listen(
        (event) => stdout.writeln(
          'ActionInvoked: #${event.id} key="${event.actionKey}"',
        ),
      ),
      notificationClosed.listen(
        (event) => stdout.writeln(
          'NotificationClosed: #${event.id} reason=${event.reason} '
          '(${event.reasonLabel})',
        ),
      ),
      activationToken.listen(
        (event) => stdout.writeln(
          'ActivationToken: #${event.id} token="${event.token}"',
        ),
      ),
    ];
    try {
      await Completer<void>().future;
    } finally {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    }
  }

  Future<void> _waitForInteraction(int id) async {
    final result = Completer<_InteractionResult>();
    final actionSubscription = actionInvoked.listen((event) {
      if (event.id == id && !result.isCompleted) {
        result.complete(_InteractionResult(action: event));
      }
    });
    final closeSubscription = notificationClosed.listen((event) {
      if (event.id == id && !result.isCompleted) {
        result.complete(_InteractionResult(closed: event));
      }
    });

    stdout.writeln(
      'Waiting up to 2 minutes for an action or dismissal on #$id…',
    );
    try {
      final interaction = await result.future.timeout(
        const Duration(minutes: 2),
      );
      final action = interaction.action;
      if (action != null) {
        stdout.writeln(
          'Received ActionInvoked for #$id: key="${action.actionKey}"',
        );
        try {
          await closeNotification(id);
          stdout.writeln('Closed resident action notification #$id');
        } on DBusMethodResponseException catch (error) {
          stderr.writeln('The server already closed #$id: $error');
        }
      } else {
        final closed = interaction.closed!;
        stdout.writeln(
          'Received NotificationClosed for #$id: ${closed.reasonLabel}',
        );
      }
    } on TimeoutException {
      stderr.writeln(
        'Timed out waiting for interaction with #$id; closing it.',
      );
      await closeNotification(id);
    } finally {
      await actionSubscription.cancel();
      await closeSubscription.cancel();
    }
  }
}

class NotificationRequest {
  const NotificationRequest({
    required this.summary,
    this.appName = _appName,
    this.replacesId = 0,
    this.appIcon = '',
    this.body = '',
    this.actions = const [],
    this.hints = const {},
    this.expireTimeoutMs = -1,
  });

  final String appName;
  final int replacesId;
  final String appIcon;
  final String summary;
  final String body;
  final List<String> actions;
  final Map<String, DBusValue> hints;
  final int expireTimeoutMs;
}

class ActionInvokedEvent {
  const ActionInvokedEvent({required this.id, required this.actionKey});

  final int id;
  final String actionKey;
}

class NotificationClosedEvent {
  const NotificationClosedEvent({required this.id, required this.reason});

  final int id;
  final int reason;

  String get reasonLabel => switch (reason) {
    1 => 'expired',
    2 => 'dismissed by user',
    3 => 'closed by client',
    _ => 'undefined',
  };
}

class ActivationTokenEvent {
  const ActivationTokenEvent({required this.id, required this.token});

  final int id;
  final String token;
}

class _InteractionResult {
  const _InteractionResult({this.action, this.closed});

  final ActionInvokedEvent? action;
  final NotificationClosedEvent? closed;
}
