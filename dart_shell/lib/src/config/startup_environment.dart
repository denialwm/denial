import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _canonicalDenialPrefix = 'DENIAL_';
const _legacyDeniaPrefix = 'DENIA_';

/// Reads a Denial environment variable while the legacy `DENIA_*` prefix is
/// supported. The canonical `DENIAL_*` spelling wins when both are present.
String? denialEnvironmentValue(Map<String, String> environment, String name) {
  final String canonical;
  final String legacy;
  if (name.startsWith(_canonicalDenialPrefix)) {
    canonical = name;
    legacy =
        '$_legacyDeniaPrefix${name.substring(_canonicalDenialPrefix.length)}';
  } else if (name.startsWith(_legacyDeniaPrefix)) {
    canonical =
        '$_canonicalDenialPrefix${name.substring(_legacyDeniaPrefix.length)}';
    legacy = name;
  } else {
    return environment[name];
  }
  return environment[canonical] ?? environment[legacy];
}

/// Immutable process environment captured before Flutter starts.
///
/// Runtime code consumes this snapshot through [startupEnvironmentProvider].
/// Keeping the only [Platform.environment] read here prevents lazy providers
/// and render paths from consulting mutable process-global state.
@immutable
class StartupEnvironment {
  StartupEnvironment(Map<String, String> values)
    : values = Map<String, String>.unmodifiable(values);

  const StartupEnvironment.empty() : values = const <String, String>{};

  factory StartupEnvironment.capture() {
    return StartupEnvironment(Platform.environment);
  }

  final Map<String, String> values;

  String? operator [](String key) => denialEnvironmentValue(values, key);

  bool flag(String key, {bool defaultValue = false}) {
    final value = this[key]?.trim().toLowerCase();
    if (value == null || value.isEmpty) {
      return defaultValue;
    }
    return switch (value) {
      '1' || 'true' || 'yes' || 'on' => true,
      '0' || 'false' || 'no' || 'off' => false,
      _ => defaultValue,
    };
  }
}

/// Tests and isolated widgets get deterministic empty startup state unless
/// they explicitly override it. Production overrides this in `main()`.
final startupEnvironmentProvider = Provider<StartupEnvironment>(
  (ref) => const StartupEnvironment.empty(),
);
