import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  String? operator [](String key) => values[key];

  bool flag(String key, {bool defaultValue = false}) {
    final value = values[key]?.trim().toLowerCase();
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
