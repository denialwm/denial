part of 'bluetooth_service.dart';

enum BluetoothPairingRequestKind {
  pinCode,
  passkey,
  confirmation,
  authorization,
  serviceAuthorization,
  displayPinCode,
  displayPasskey;

  bool get needsTextInput =>
      this == BluetoothPairingRequestKind.pinCode ||
      this == BluetoothPairingRequestKind.passkey;

  bool get informational =>
      this == BluetoothPairingRequestKind.displayPinCode ||
      this == BluetoothPairingRequestKind.displayPasskey;
}

@immutable
class BluetoothPairingRequest {
  const BluetoothPairingRequest({
    required this.id,
    required this.kind,
    required this.devicePath,
    required this.address,
    required this.deviceName,
    this.passkey,
    this.pinCode,
    this.enteredDigits = 0,
    this.serviceUuid,
  });

  final int id;
  final BluetoothPairingRequestKind kind;
  final String devicePath;
  final String address;
  final String deviceName;
  final int? passkey;
  final String? pinCode;
  final int enteredDigits;
  final String? serviceUuid;
}

@immutable
class BluetoothDeviceInfo {
  const BluetoothDeviceInfo({
    required this.objectPath,
    required this.adapterPath,
    required this.address,
    required this.name,
    required this.icon,
    required this.connected,
    required this.paired,
    required this.trusted,
    required this.blocked,
    required this.servicesResolved,
    required this.signalStrength,
  });

  final String objectPath;
  final String adapterPath;
  final String address;
  final String name;
  final String icon;
  final bool connected;
  final bool paired;
  final bool trusted;
  final bool blocked;
  final bool servicesResolved;
  final int? signalStrength;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BluetoothDeviceInfo &&
          other.objectPath == objectPath &&
          other.adapterPath == adapterPath &&
          other.address == address &&
          other.name == name &&
          other.icon == icon &&
          other.connected == connected &&
          other.paired == paired &&
          other.trusted == trusted &&
          other.blocked == blocked &&
          other.servicesResolved == servicesResolved &&
          other.signalStrength == signalStrength;

  @override
  int get hashCode => Object.hash(
    objectPath,
    adapterPath,
    address,
    name,
    icon,
    connected,
    paired,
    trusted,
    blocked,
    servicesResolved,
    signalStrength,
  );
}

@immutable
class BluetoothSnapshot {
  const BluetoothSnapshot({
    required this.serviceAvailable,
    required this.available,
    required this.adapterPath,
    required this.adapterName,
    required this.powered,
    required this.discovering,
    required this.pairable,
    required this.devices,
  });

  const BluetoothSnapshot.unavailable()
    : serviceAvailable = false,
      available = false,
      adapterPath = null,
      adapterName = '',
      powered = false,
      discovering = false,
      pairable = false,
      devices = const <BluetoothDeviceInfo>[];

  final bool serviceAvailable;
  final bool available;
  final String? adapterPath;
  final String adapterName;
  final bool powered;
  final bool discovering;
  final bool pairable;
  final List<BluetoothDeviceInfo> devices;

  BluetoothDeviceInfo? deviceAt(String objectPath) {
    for (final device in devices) {
      if (device.objectPath == objectPath) {
        return device;
      }
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BluetoothSnapshot &&
          other.serviceAvailable == serviceAvailable &&
          other.available == available &&
          other.adapterPath == adapterPath &&
          other.adapterName == adapterName &&
          other.powered == powered &&
          other.discovering == discovering &&
          other.pairable == pairable &&
          listEquals(other.devices, devices);

  @override
  int get hashCode => Object.hash(
    serviceAvailable,
    available,
    adapterPath,
    adapterName,
    powered,
    discovering,
    pairable,
    Object.hashAll(devices),
  );
}

abstract interface class BluetoothBackend {
  Stream<BluetoothSnapshot> get snapshots;

  Stream<BluetoothPairingRequest?> get pairingRequests;

  BluetoothSnapshot get currentSnapshot;

  BluetoothPairingRequest? get currentPairingRequest;

  Future<void> start();

  Future<void> refresh();

  Future<void> setPowered(bool powered);

  Future<void> startDiscovery();

  Future<void> stopDiscovery();

  Future<void> pair(BluetoothDeviceInfo device);

  Future<void> setTrusted(BluetoothDeviceInfo device, bool trusted);

  Future<void> connect(BluetoothDeviceInfo device);

  Future<void> disconnect(BluetoothDeviceInfo device);

  Future<void> remove(BluetoothDeviceInfo device);

  void respondToPairing(
    int requestId, {
    required bool accepted,
    String? response,
  });

  Future<void> dispose();
}
