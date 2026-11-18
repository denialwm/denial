import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'model.dart';

/// A Denial checkout whose plugins are compiled in place, with the Flutter
/// tool and the engine output the checkout's own shell is built with.
final class DevelopmentInstallation {
  const DevelopmentInstallation({
    required this.checkout,
    required this.flutter,
    required this.engineRoot,
    required this.engineTarget,
    required this.platform,
  });

  /// Holds `packages/`, `plugins/` and `compositor/`.
  final String checkout;

  /// The Flutter launcher, `bin/flutter` of the Flutter source tree.
  final String flutter;

  /// The directory that owns `out/<engineTarget>`.
  final String engineRoot;
  final String engineTarget;
  final String platform;
}

/// Build/packaging-owned metadata, located beside the actual executable.
/// Users never configure these paths, and PATH is not an installation authority.
final class PluginInstallation {
  const PluginInstallation({
    this.buildKit,
    this.development,
    required this.denialctl,
  });

  factory PluginInstallation.discover({String? executable}) {
    final file = File(
      p.join(
        p.dirname(executable ?? Platform.resolvedExecutable),
        'denial-plugins.installation.json',
      ),
    );
    if (!file.existsSync()) {
      throw const CompositionException(
        'Denial plugin tools are incomplete. Update or repair the Denial installation.',
      );
    }
    final value = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    if (value['schema'] != 1) {
      throw const CompositionException(
        'Unsupported Denial plugin installation metadata',
      );
    }
    String resolve(Map<String, Object?> from, String key) {
      final path = from[key];
      if (path is! String || path.isEmpty) {
        throw CompositionException(
          'Incomplete Denial plugin installation: $key',
        );
      }
      return p.normalize(p.join(file.parent.path, path));
    }

    String word(Map<String, Object?> from, String key) {
      final value = from[key];
      if (value is! String || !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(value)) {
        throw CompositionException(
          'Incomplete Denial plugin installation: $key',
        );
      }
      return value;
    }

    final development = value['development'];
    if (development is Map<String, Object?>) {
      return PluginInstallation(
        development: DevelopmentInstallation(
          checkout: resolve(development, 'checkout'),
          flutter: resolve(development, 'flutter'),
          engineRoot: resolve(development, 'engineRoot'),
          engineTarget: word(development, 'engineTarget'),
          platform: word(development, 'platform'),
        ),
        denialctl: resolve(value, 'denialctl'),
      );
    }
    return PluginInstallation(
      buildKit: resolve(value, 'buildKit'),
      denialctl: resolve(value, 'denialctl'),
    );
  }

  /// The packaged release compiler kit; null for a development checkout.
  final String? buildKit;
  final DevelopmentInstallation? development;
  final String denialctl;
}
