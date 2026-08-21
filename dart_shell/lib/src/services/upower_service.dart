import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final upowerServiceProvider = Provider<UPowerBackend>((ref) {
  final service = UPowerService();
  ref.onDispose(service.dispose);
  return service;
});

abstract interface class UPowerBackend {
  Future<UPowerSnapshot> readSnapshot();

  Future<void> setChargeThresholdEnabled(String objectPath, bool enabled);

  Future<void> dispose();
}

enum UPowerBatteryState {
  unknown,
  charging,
  discharging,
  empty,
  fullyCharged,
  pendingCharge,
  pendingDischarge,
}

enum UPowerBatteryTechnology {
  unknown,
  lithiumIon,
  lithiumPolymer,
  lithiumIronPhosphate,
  leadAcid,
  nickelCadmium,
  nickelMetalHydride,
}

enum UPowerWarningLevel { unknown, none, discharging, low, critical, action }

@immutable
class UPowerBattery {
  const UPowerBattery({
    required this.objectPath,
    required this.nativePath,
    required this.vendor,
    required this.model,
    required this.serial,
    required this.state,
    required this.technology,
    required this.warningLevel,
    required this.percentage,
    required this.healthPercentage,
    required this.energy,
    required this.energyFull,
    required this.energyFullDesign,
    required this.energyRate,
    required this.voltage,
    required this.temperature,
    required this.timeToEmpty,
    required this.timeToFull,
    required this.chargeCycles,
    required this.chargeThresholdSupported,
    required this.chargeThresholdEnabled,
    required this.chargeThresholdSettings,
    required this.chargeStartThreshold,
    required this.chargeEndThreshold,
  });

  static const int chargeStartSetting = 1;
  static const int chargeEndSetting = 2;
  static const int firmwareOptimizedSetting = 4;

  final String objectPath;
  final String nativePath;
  final String vendor;
  final String model;
  final String serial;
  final UPowerBatteryState state;
  final UPowerBatteryTechnology technology;
  final UPowerWarningLevel warningLevel;
  final double? percentage;
  final double? healthPercentage;
  final double? energy;
  final double? energyFull;
  final double? energyFullDesign;
  final double? energyRate;
  final double? voltage;
  final double? temperature;
  final Duration? timeToEmpty;
  final Duration? timeToFull;
  final int? chargeCycles;
  final bool chargeThresholdSupported;
  final bool chargeThresholdEnabled;
  final int chargeThresholdSettings;
  final int? chargeStartThreshold;
  final int? chargeEndThreshold;

  bool get chargeStartThresholdSupported =>
      chargeThresholdSettings & chargeStartSetting != 0;

  bool get chargeEndThresholdSupported =>
      chargeThresholdSettings & chargeEndSetting != 0;

  bool get firmwareOptimizedChargingSupported =>
      chargeThresholdSettings & firmwareOptimizedSetting != 0;

  String get displayName {
    final components = <String>[
      if (vendor.trim().isNotEmpty) vendor.trim(),
      if (model.trim().isNotEmpty && model.trim() != vendor.trim())
        model.trim(),
    ];
    return components.isNotEmpty ? components.join(' ') : nativePath.trim();
  }

  UPowerBattery withChargeThresholdEnabled(bool enabled) {
    return UPowerBattery(
      objectPath: objectPath,
      nativePath: nativePath,
      vendor: vendor,
      model: model,
      serial: serial,
      state: state,
      technology: technology,
      warningLevel: warningLevel,
      percentage: percentage,
      healthPercentage: healthPercentage,
      energy: energy,
      energyFull: energyFull,
      energyFullDesign: energyFullDesign,
      energyRate: energyRate,
      voltage: voltage,
      temperature: temperature,
      timeToEmpty: timeToEmpty,
      timeToFull: timeToFull,
      chargeCycles: chargeCycles,
      chargeThresholdSupported: chargeThresholdSupported,
      chargeThresholdEnabled: enabled,
      chargeThresholdSettings: chargeThresholdSettings,
      chargeStartThreshold: chargeStartThreshold,
      chargeEndThreshold: chargeEndThreshold,
    );
  }
}

@immutable
class UPowerSnapshot {
  UPowerSnapshot({
    required this.daemonVersion,
    required this.onBattery,
    required List<UPowerBattery> batteries,
  }) : batteries = List<UPowerBattery>.unmodifiable(batteries);

  final String daemonVersion;
  final bool onBattery;
  final List<UPowerBattery> batteries;

  UPowerSnapshot withChargeThresholdEnabled(String objectPath, bool enabled) {
    return UPowerSnapshot(
      daemonVersion: daemonVersion,
      onBattery: onBattery,
      batteries: <UPowerBattery>[
        for (final battery in batteries)
          if (battery.objectPath == objectPath)
            battery.withChargeThresholdEnabled(enabled)
          else
            battery,
      ],
    );
  }
}

class UPowerService implements UPowerBackend {
  UPowerService({DBusClient? systemBus})
    : _systemBus = systemBus ?? DBusClient.system();

  static const String _busName = 'org.freedesktop.UPower';
  static const String _rootPath = '/org/freedesktop/UPower';
  static const String _rootInterface = 'org.freedesktop.UPower';
  static const String _deviceInterface = 'org.freedesktop.UPower.Device';
  static const Duration _timeout = Duration(seconds: 3);

  final DBusClient _systemBus;

  DBusRemoteObject get _root => DBusRemoteObject(
    _systemBus,
    name: _busName,
    path: DBusObjectPath(_rootPath),
  );

  @override
  Future<UPowerSnapshot> readSnapshot() async {
    final rootProperties = await _root
        .getAllProperties(_rootInterface)
        .timeout(_timeout);
    final response = await _root
        .callMethod(
          _rootInterface,
          'EnumerateDevices',
          const <DBusValue>[],
          replySignature: DBusSignature('ao'),
        )
        .timeout(_timeout);
    final paths = response.returnValues.single.asObjectPathArray();
    final batteries = await Future.wait<UPowerBattery?>(
      paths.map(_tryReadSystemBattery),
    );
    return UPowerSnapshot(
      daemonVersion: _string(rootProperties, 'DaemonVersion') ?? '',
      onBattery: _boolean(rootProperties, 'OnBattery') ?? false,
      batteries: batteries.whereType<UPowerBattery>().toList(),
    );
  }

  Future<UPowerBattery?> _tryReadSystemBattery(DBusObjectPath path) async {
    try {
      final properties = await _device(
        path.value,
      ).getAllProperties(_deviceInterface).timeout(_timeout);
      return parseUPowerSystemBattery(path.value, properties);
    } on Object {
      // Devices can disappear between EnumerateDevices and GetAll.
      return null;
    }
  }

  @override
  Future<void> setChargeThresholdEnabled(
    String objectPath,
    bool enabled,
  ) async {
    await _device(objectPath)
        .callMethod(
          _deviceInterface,
          'EnableChargeThreshold',
          <DBusValue>[DBusBoolean(enabled)],
          replySignature: DBusSignature(''),
        )
        .timeout(_timeout);
  }

  DBusRemoteObject _device(String objectPath) => DBusRemoteObject(
    _systemBus,
    name: _busName,
    path: DBusObjectPath(objectPath),
  );

  @override
  Future<void> dispose() => _systemBus.close();
}

UPowerBattery? parseUPowerSystemBattery(
  String objectPath,
  Map<String, DBusValue> properties,
) {
  final kind = _uint32(properties, 'Type');
  final present = _boolean(properties, 'IsPresent') ?? true;
  if ((kind != 2 && kind != 3) || !present) {
    return null;
  }
  return UPowerBattery(
    objectPath: objectPath,
    nativePath: _string(properties, 'NativePath') ?? '',
    vendor: _string(properties, 'Vendor') ?? '',
    model: _string(properties, 'Model') ?? '',
    serial: _string(properties, 'Serial') ?? '',
    state: _batteryState(_uint32(properties, 'State')),
    technology: _batteryTechnology(_uint32(properties, 'Technology')),
    warningLevel: _warningLevel(_uint32(properties, 'WarningLevel')),
    percentage: _finiteNonNegative(_double(properties, 'Percentage')),
    healthPercentage: _finiteNonNegative(_double(properties, 'Capacity')),
    energy: _finiteNonNegative(_double(properties, 'Energy')),
    energyFull: _finiteNonNegative(_double(properties, 'EnergyFull')),
    energyFullDesign: _finiteNonNegative(
      _double(properties, 'EnergyFullDesign'),
    ),
    energyRate: _finiteNonNegative(_double(properties, 'EnergyRate')),
    voltage: _finiteNonNegative(_double(properties, 'Voltage')),
    temperature: _finiteNonNegative(_double(properties, 'Temperature')),
    timeToEmpty: _positiveDuration(_int64(properties, 'TimeToEmpty')),
    timeToFull: _positiveDuration(_int64(properties, 'TimeToFull')),
    chargeCycles: _nonNegativeInt(_int32(properties, 'ChargeCycles')),
    chargeThresholdSupported:
        _boolean(properties, 'ChargeThresholdSupported') ?? false,
    chargeThresholdEnabled:
        _boolean(properties, 'ChargeThresholdEnabled') ?? false,
    chargeThresholdSettings:
        _uint32(properties, 'ChargeThresholdSettingsSupported') ?? 0,
    chargeStartThreshold: _validPercentage(
      _uint32(properties, 'ChargeStartThreshold'),
    ),
    chargeEndThreshold: _validPercentage(
      _uint32(properties, 'ChargeEndThreshold'),
    ),
  );
}

UPowerBatteryState _batteryState(int? value) => switch (value) {
  1 => UPowerBatteryState.charging,
  2 => UPowerBatteryState.discharging,
  3 => UPowerBatteryState.empty,
  4 => UPowerBatteryState.fullyCharged,
  5 => UPowerBatteryState.pendingCharge,
  6 => UPowerBatteryState.pendingDischarge,
  _ => UPowerBatteryState.unknown,
};

UPowerBatteryTechnology _batteryTechnology(int? value) => switch (value) {
  1 => UPowerBatteryTechnology.lithiumIon,
  2 => UPowerBatteryTechnology.lithiumPolymer,
  3 => UPowerBatteryTechnology.lithiumIronPhosphate,
  4 => UPowerBatteryTechnology.leadAcid,
  5 => UPowerBatteryTechnology.nickelCadmium,
  6 => UPowerBatteryTechnology.nickelMetalHydride,
  _ => UPowerBatteryTechnology.unknown,
};

UPowerWarningLevel _warningLevel(int? value) => switch (value) {
  1 => UPowerWarningLevel.none,
  2 => UPowerWarningLevel.discharging,
  3 => UPowerWarningLevel.low,
  4 => UPowerWarningLevel.critical,
  5 => UPowerWarningLevel.action,
  _ => UPowerWarningLevel.unknown,
};

String? _string(Map<String, DBusValue> properties, String name) {
  final value = properties[name];
  return value is DBusString ? value.value : null;
}

bool? _boolean(Map<String, DBusValue> properties, String name) {
  final value = properties[name];
  return value is DBusBoolean ? value.value : null;
}

int? _int32(Map<String, DBusValue> properties, String name) {
  final value = properties[name];
  return value is DBusInt32 ? value.value : null;
}

int? _uint32(Map<String, DBusValue> properties, String name) {
  final value = properties[name];
  return value is DBusUint32 ? value.value : null;
}

int? _int64(Map<String, DBusValue> properties, String name) {
  final value = properties[name];
  return value is DBusInt64 ? value.value : null;
}

double? _double(Map<String, DBusValue> properties, String name) {
  final value = properties[name];
  return value is DBusDouble ? value.value : null;
}

double? _finiteNonNegative(double? value) {
  return value != null && value.isFinite && value >= 0 ? value : null;
}

int? _nonNegativeInt(int? value) => value != null && value >= 0 ? value : null;

int? _validPercentage(int? value) {
  return value != null && value >= 0 && value <= 100 ? value : null;
}

Duration? _positiveDuration(int? seconds) {
  return seconds != null && seconds > 0 ? Duration(seconds: seconds) : null;
}
