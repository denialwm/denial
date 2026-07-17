import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dbus/dbus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'non_blocking_fifo.dart';
import 'power_profile_service.dart';
import '../config/startup_environment.dart';

final desktopPowerModesServiceProvider = Provider<DesktopPowerModesService>((
  ref,
) {
  final service = DesktopPowerModesService(
    environment: ref.watch(startupEnvironmentProvider).values,
  );
  ref.onDispose(service.dispose);
  return service;
});

class DesktopPowerModesSnapshot {
  const DesktopPowerModesSnapshot({
    required this.systemAvailable,
    required this.systemProfile,
    required this.pboAvailable,
    required this.pboProfile,
  });

  final bool systemAvailable;
  final String systemProfile;
  final bool pboAvailable;
  final String? pboProfile;
}

class DesktopPowerModesService {
  DesktopPowerModesService({
    required Map<String, String> environment,
    DBusClient? systemBus,
    NonBlockingFifoWriter? fifoWriter,
  })  : _systemBus = systemBus ?? DBusClient.system(),
        _environment = Map.unmodifiable(environment),
        _fifoWriter = fifoWriter;

  static const Duration _dbusTimeout = Duration(seconds: 3);
  static const List<_PowerProfilesEndpoint> _powerProfileEndpoints = [
    _PowerProfilesEndpoint(
      busName: 'org.freedesktop.UPower.PowerProfiles',
      objectPath: '/org/freedesktop/UPower/PowerProfiles',
      interface: 'org.freedesktop.UPower.PowerProfiles',
    ),
    _PowerProfilesEndpoint(
      busName: 'net.hadess.PowerProfiles',
      objectPath: '/net/hadess/PowerProfiles',
      interface: 'net.hadess.PowerProfiles',
    ),
  ];

  final DBusClient _systemBus;
  final Map<String, String> _environment;
  NonBlockingFifoWriter? _fifoWriter;
  _PowerProfilesEndpoint? _activeEndpoint;

  String? get _pboRuntimeDirectory {
    final runtime = _environment['XDG_RUNTIME_DIR']?.trim();
    return runtime == null || runtime.isEmpty
        ? null
        : '$runtime/caelestia-ryzen-pbo';
  }

  String? get _systemProfileCachePath {
    final runtime = _environment['XDG_RUNTIME_DIR']?.trim();
    return runtime == null || runtime.isEmpty
        ? null
        : '$runtime/denial-system-profile';
  }

  Future<DesktopPowerModesSnapshot> readSnapshot() async {
    final systemProfile = await _readSystemProfile();
    final pbo = await _readPboSnapshot();
    return DesktopPowerModesSnapshot(
      systemAvailable: systemProfile != null,
      systemProfile: systemProfile ?? PowerProfile.balanced,
      pboAvailable: pbo.available,
      pboProfile: pbo.profile,
    );
  }

  Future<void> applySystemProfile(String profile) async {
    final normalized = PowerProfile.normalize(profile);
    if (normalized == null) {
      throw ArgumentError.value(profile, 'profile', 'Profilo non valido');
    }

    final endpoint = _activeEndpoint ?? await _resolvePowerProfilesEndpoint();
    if (endpoint == null) {
      throw StateError('Servizio dei profili energetici non disponibile');
    }

    final desktopProfile =
        normalized == PowerProfile.powerSave ? 'power-saver' : normalized;
    final systemCommand = _systemCommand(normalized);
    try {
      await _object(endpoint)
          .setProperty(
            endpoint.interface,
            'ActiveProfile',
            DBusString(desktopProfile),
          )
          .timeout(_dbusTimeout);
    } on Object catch (dbusError) {
      // Some amd_pstate kernels expose per-policy boost files that
      // power-profiles-daemon cannot restore (EINVAL). The already-running PBO
      // daemon owns the privileged direct fallback and accepts the same system
      // modes over its non-blocking FIFO.
      try {
        _writePboCommand(systemCommand);
        await _writeSystemProfileCache(normalized);
        return;
      } on Object {
        throw dbusError;
      }
    }

    try {
      _writePboCommand(systemCommand);
    } on Object {
      // D-Bus already applied the requested profile; the direct AMD tuning is
      // supplemental when the PBO daemon is unavailable.
    }
    await _writeSystemProfileCache(normalized);
  }

  Future<void> applyPboProfile(String profile) async {
    if (!DesktopPboProfile.values.contains(profile)) {
      throw ArgumentError.value(profile, 'profile', 'Profilo PBO non valido');
    }
    _writePboCommand(profile);
  }

  Future<void> dispose() => _systemBus.close();

  Future<String?> _readSystemProfile() async {
    final cached = await _readSystemProfileCache();
    if (cached != null) {
      return cached;
    }

    final endpoint = _activeEndpoint;
    if (endpoint != null) {
      final profile = await _tryReadSystemProfile(endpoint);
      if (profile != null) {
        return profile;
      }
      _activeEndpoint = null;
    }

    final resolved = await _resolvePowerProfilesEndpoint();
    return resolved == null ? null : _tryReadSystemProfile(resolved);
  }

  String _systemCommand(String normalized) {
    return 'system ${switch (normalized) {
      PowerProfile.powerSave => 'conservative',
      PowerProfile.performance => 'performance',
      _ => 'balanced',
    }}';
  }

  Future<String?> _readSystemProfileCache() async {
    final path = _systemProfileCachePath;
    if (path == null) {
      return null;
    }
    try {
      return PowerProfile.normalize(await File(path).readAsString());
    } on Object {
      return null;
    }
  }

  Future<void> _writeSystemProfileCache(String profile) async {
    final path = _systemProfileCachePath;
    if (path == null) {
      return;
    }
    try {
      await File(path).writeAsString('$profile\n', flush: true);
    } on Object {
      // The mode was still applied; this cache only keeps the UI coherent when
      // power-profiles-daemon cannot represent the direct fallback state.
    }
  }

  Future<_PowerProfilesEndpoint?> _resolvePowerProfilesEndpoint() async {
    for (final endpoint in _powerProfileEndpoints) {
      if (await _tryReadSystemProfile(endpoint) != null) {
        _activeEndpoint = endpoint;
        return endpoint;
      }
    }
    return null;
  }

  Future<String?> _tryReadSystemProfile(
    _PowerProfilesEndpoint endpoint,
  ) async {
    try {
      final value = await _object(endpoint)
          .getProperty(endpoint.interface, 'ActiveProfile')
          .timeout(_dbusTimeout);
      return value is DBusString ? PowerProfile.normalize(value.value) : null;
    } on Object {
      return null;
    }
  }

  DBusRemoteObject _object(_PowerProfilesEndpoint endpoint) {
    return DBusRemoteObject(
      _systemBus,
      name: endpoint.busName,
      path: DBusObjectPath(endpoint.objectPath),
    );
  }

  Future<_PboSnapshot> _readPboSnapshot() async {
    final runtime = _pboRuntimeDirectory;
    if (runtime == null) {
      return const _PboSnapshot.unavailable();
    }
    try {
      if (await FileSystemEntity.type(
            '$runtime/command',
            followLinks: false,
          ) !=
          FileSystemEntityType.pipe) {
        return const _PboSnapshot.unavailable();
      }
      final decoded = jsonDecode(
        await File('$runtime/status.json').readAsString(),
      );
      if (decoded is! Map<String, dynamic> ||
          decoded['ok'] != true ||
          decoded['available'] != true) {
        return const _PboSnapshot.unavailable();
      }
      return _PboSnapshot(
        available: true,
        profile: _profileFromLimits(decoded),
      );
    } on Object {
      return const _PboSnapshot.unavailable();
    }
  }

  void _writePboCommand(String command) {
    final runtime = _pboRuntimeDirectory;
    if (runtime == null) {
      throw StateError('XDG_RUNTIME_DIR non disponibile');
    }
    (_fifoWriter ??= NonBlockingFifoWriter()).writeLine(
      '$runtime/command',
      command,
    );
  }

  String? _profileFromLimits(Map<String, dynamic> status) {
    final ppt = _limit(status, 'ppt');
    final tdc = _limit(status, 'tdc');
    final edc = _limit(status, 'edc');
    if (ppt == null || tdc == null || edc == null) {
      return null;
    }

    for (final profile in _knownPboLimits.entries) {
      final limits = profile.value;
      if (_near(ppt, limits.$1) &&
          _near(tdc, limits.$2) &&
          _near(edc, limits.$3)) {
        return profile.key;
      }
    }
    return null;
  }

  double? _limit(Map<String, dynamic> status, String metric) {
    final value = status[metric];
    if (value is! Map) {
      return null;
    }
    return (value['limit'] as num?)?.toDouble();
  }

  bool _near(double value, double expected) {
    return (value - expected).abs() <= math.max(0.75, expected * 0.01);
  }
}

abstract final class DesktopPboProfile {
  static const String silent = 'silent';
  static const String balanced = 'balanced';
  static const String performance = 'performance';
  static const Set<String> values = {silent, balanced, performance};
}

const Map<String, (double, double, double)> _knownPboLimits = {
  DesktopPboProfile.silent: (70, 50, 80),
  DesktopPboProfile.balanced: (110, 80, 145),
  DesktopPboProfile.performance: (142, 95, 165),
};

class _PowerProfilesEndpoint {
  const _PowerProfilesEndpoint({
    required this.busName,
    required this.objectPath,
    required this.interface,
  });

  final String busName;
  final String objectPath;
  final String interface;
}

class _PboSnapshot {
  const _PboSnapshot({required this.available, required this.profile});

  const _PboSnapshot.unavailable()
      : available = false,
        profile = null;

  final bool available;
  final String? profile;
}
