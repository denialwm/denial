part of 'bluetooth_service.dart';

class _AdapterSnapshot {
  const _AdapterSnapshot({
    required this.path,
    required this.name,
    required this.powered,
    required this.discovering,
    required this.pairable,
  });

  final String path;
  final String name;
  final bool powered;
  final bool discovering;
  final bool pairable;
}

class _PendingPairing {
  const _PendingPairing(this.request, this.completer);

  final BluetoothPairingRequest request;
  final Completer<DBusMethodResponse> completer;
}

@visibleForTesting
class BluetoothAgentEndpoint extends DBusObject {
  BluetoothAgentEndpoint()
    : super(DBusObjectPath('/org/denial/BluetoothAgent'));

  String? Function()? owner;
  Future<DBusMethodResponse> Function(DBusMethodCall)? handler;

  @override
  List<DBusIntrospectInterface> introspect() => <DBusIntrospectInterface>[
    DBusIntrospectInterface(
      'org.bluez.Agent1',
      methods: <DBusIntrospectMethod>[
        _agentMethod('Release'),
        _agentMethod('RequestPinCode', input: 'o', output: 's'),
        _agentMethod('DisplayPinCode', input: 'os'),
        _agentMethod('RequestPasskey', input: 'o', output: 'u'),
        _agentMethod('DisplayPasskey', input: 'ouq'),
        _agentMethod('RequestConfirmation', input: 'ou'),
        _agentMethod('RequestAuthorization', input: 'o'),
        _agentMethod('AuthorizeService', input: 'os'),
        _agentMethod('Cancel'),
      ],
    ),
  ];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != 'org.bluez.Agent1') {
      return DBusMethodErrorResponse.unknownInterface();
    }
    final expectedOwner = owner?.call();
    if (expectedOwner == null || methodCall.sender != expectedOwner) {
      return DBusMethodErrorResponse.accessDenied();
    }
    final callback = handler;
    return callback == null
        ? DBusMethodErrorResponse.failed('Pairing agent is unavailable')
        : callback(methodCall);
  }
}

DBusIntrospectMethod _agentMethod(
  String name, {
  String input = '',
  String output = '',
}) {
  final arguments = <DBusIntrospectArgument>[
    for (var index = 0; index < input.length; index++)
      DBusIntrospectArgument(
        DBusSignature(input[index]),
        DBusArgumentDirection.in_,
      ),
    for (var index = 0; index < output.length; index++)
      DBusIntrospectArgument(
        DBusSignature(output[index]),
        DBusArgumentDirection.out,
      ),
  ];
  return DBusIntrospectMethod(name, args: arguments);
}

DBusMethodErrorResponse _bluezRejected(String message) =>
    DBusMethodErrorResponse('org.bluez.Error.Rejected', <DBusValue>[
      DBusString(message),
    ]);

DBusMethodErrorResponse _bluezCanceled(String message) =>
    DBusMethodErrorResponse('org.bluez.Error.Canceled', <DBusValue>[
      DBusString(message),
    ]);

String _string(
  Map<String, DBusValue> properties,
  String name, {
  String fallback = '',
}) {
  final value = properties[name];
  return value is DBusString && value.value.trim().isNotEmpty
      ? value.value.trim()
      : fallback;
}

bool _boolean(Map<String, DBusValue> properties, String name) {
  final value = properties[name];
  return value is DBusBoolean && value.value;
}

String? _objectPath(Map<String, DBusValue> properties, String name) {
  final value = properties[name];
  return value is DBusObjectPath ? value.value : null;
}

int? _int16(Map<String, DBusValue> properties, String name) {
  final value = properties[name];
  return value is DBusInt16 ? value.value : null;
}

int _compareTrueFirst(bool left, bool right) {
  if (left == right) {
    return 0;
  }
  return left ? -1 : 1;
}

int _compareBluetoothDevices(
  BluetoothDeviceInfo left,
  BluetoothDeviceInfo right,
) {
  var result = _compareTrueFirst(left.connected, right.connected);
  if (result != 0) {
    return result;
  }
  result = _compareTrueFirst(left.paired, right.paired);
  if (result != 0) {
    return result;
  }
  result = _compareTrueFirst(left.trusted, right.trusted);
  if (result != 0) {
    return result;
  }
  final leftSignal = left.signalStrength ?? -32768;
  final rightSignal = right.signalStrength ?? -32768;
  result = rightSignal.compareTo(leftSignal);
  return result != 0
      ? result
      : left.name.toLowerCase().compareTo(right.name.toLowerCase());
}

String _bounded(String value, int maxLength) =>
    value.length <= maxLength ? value : value.substring(0, maxLength);
