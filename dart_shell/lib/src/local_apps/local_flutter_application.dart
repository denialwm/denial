import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/denial_window.dart';
import '../platform/denial_bridge.dart';
import '../state/shell_controller.dart';

typedef LocalFlutterApplicationBuilder =
    Widget Function(BuildContext context, LocalFlutterWindowHandle window);

typedef LocalFlutterApplicationTitleBuilder =
    String Function(BuildContext context);

typedef LocalFlutterApplicationCategoriesBuilder =
    List<String> Function(BuildContext context);

/// Describes trusted application content compiled into the shell bundle.
///
/// The native protocol carries only [id], title, geometry, and lifecycle
/// commands. Executable code and widget factories never cross the boundary.
@immutable
class LocalFlutterApplication {
  const LocalFlutterApplication({
    required this.id,
    required this.title,
    required this.builder,
    this.defaultSize = const Size(800, 600),
    this.minimumSize = const Size(320, 240),
    this.singleInstance = true,
    this.icon,
    this.categories = const <String>[],
    this.localizedTitle,
    this.localizedCategories,
  });

  final String id;
  final String title;
  final Size defaultSize;
  final Size minimumSize;
  final bool singleInstance;
  final IconData? icon;
  final List<String> categories;
  final LocalFlutterApplicationTitleBuilder? localizedTitle;
  final LocalFlutterApplicationCategoriesBuilder? localizedCategories;
  final LocalFlutterApplicationBuilder builder;

  /// Resolves the application name for the active Flutter locale. [title]
  /// remains the protocol-safe English fallback used before a build context
  /// exists.
  String titleFor(BuildContext context) =>
      localizedTitle?.call(context) ?? title;

  /// Keeps the stable English categories searchable while adding terms from
  /// the active locale. This makes locale changes useful without making an
  /// application undiscoverable by its canonical metadata.
  List<String> categoriesFor(BuildContext context) {
    final localized = localizedCategories?.call(context);
    if (localized == null || localized.isEmpty) {
      return categories;
    }
    return List<String>.unmodifiable(<String>{...categories, ...localized});
  }
}

@immutable
class LocalFlutterWindowHandle {
  const LocalFlutterWindowHandle({
    required this.window,
    required this.focus,
    required this.close,
  });

  final DenialWindow window;
  final VoidCallback focus;
  final VoidCallback close;
}

class LocalFlutterApplicationRegistry {
  LocalFlutterApplicationRegistry(Iterable<LocalFlutterApplication> apps)
    : _applications = _validate(apps);

  final Map<String, LocalFlutterApplication> _applications;

  Iterable<LocalFlutterApplication> get applications => _applications.values;

  LocalFlutterApplication? operator [](String id) => _applications[id];

  static Map<String, LocalFlutterApplication> _validate(
    Iterable<LocalFlutterApplication> apps,
  ) {
    final result = <String, LocalFlutterApplication>{};
    for (final app in apps) {
      final idBytes = utf8.encode(app.id);
      final titleBytes = utf8.encode(app.title);
      if (idBytes.isEmpty ||
          idBytes.length > 256 ||
          app.id.contains('\u0000') ||
          titleBytes.isEmpty ||
          titleBytes.length > 1024 ||
          app.title.contains('\u0000') ||
          !_validSize(app.defaultSize) ||
          !_validSize(app.minimumSize)) {
        throw ArgumentError.value(app.id, 'apps', 'invalid local application');
      }
      if (result.containsKey(app.id)) {
        throw ArgumentError.value(app.id, 'apps', 'duplicate application id');
      }
      result[app.id] = app;
    }
    return Map<String, LocalFlutterApplication>.unmodifiable(result);
  }

  static bool _validSize(Size size) {
    return size.width.isFinite &&
        size.height.isFinite &&
        size.width >= 64.0 &&
        size.height >= 64.0 &&
        size.width <= 16384.0 &&
        size.height <= 16384.0;
  }
}

/// Override this provider at the shell root to register any trusted built-in
/// Flutter applications. It intentionally defaults to an empty catalog.
final localFlutterApplicationsProvider =
    Provider<List<LocalFlutterApplication>>((ref) {
      return const <LocalFlutterApplication>[];
    });

final localFlutterApplicationRegistryProvider =
    Provider<LocalFlutterApplicationRegistry>((ref) {
      return LocalFlutterApplicationRegistry(
        ref.watch(localFlutterApplicationsProvider),
      );
    });

final localFlutterApplicationLauncherProvider =
    Provider<LocalFlutterApplicationLauncher>((ref) {
      return LocalFlutterApplicationLauncher(
        registry: ref.watch(localFlutterApplicationRegistryProvider),
        bridge: ref.read(denialBridgeProvider),
        windows: () => ref.read(shellControllerProvider).windows,
        focus: ref.read(shellControllerProvider.notifier).focusWindow,
      );
    });

class LocalFlutterApplicationLauncher {
  const LocalFlutterApplicationLauncher({
    required this._registry,
    required this._bridge,
    required this._windows,
    required this._focus,
  });

  final LocalFlutterApplicationRegistry _registry;
  final DenialBridge _bridge;
  final List<DenialWindow> Function() _windows;
  final ValueChanged<DenialWindow> _focus;

  /// Opens [appId] inside [availableBounds], or focuses its existing local
  /// window when the descriptor is single-instance.
  bool launch(
    String appId, {
    required Rect availableBounds,
    Rect? geometry,
    String? title,
  }) {
    final app = _registry[appId];
    if (app == null ||
        availableBounds.width < 64.0 ||
        availableBounds.height < 64.0) {
      return false;
    }
    if (app.singleInstance) {
      for (final window in _windows()) {
        if (window.isLocalFlutter && window.appId == app.id) {
          _focus(window);
          return true;
        }
      }
    }

    final target = geometry ?? _centeredGeometry(app, availableBounds);
    return _bridge.createLocalWindow(
      appId: app.id,
      title: title ?? app.title,
      geometry: target,
    );
  }

  static Rect _centeredGeometry(
    LocalFlutterApplication app,
    Rect availableBounds,
  ) {
    final preferredWidth = math.max(
      app.minimumSize.width,
      app.defaultSize.width,
    );
    final preferredHeight = math.max(
      app.minimumSize.height,
      app.defaultSize.height,
    );
    final width = preferredWidth
        .clamp(64.0, math.min(16384.0, availableBounds.width))
        .toDouble();
    final height = preferredHeight
        .clamp(64.0, math.min(16384.0, availableBounds.height))
        .toDouble();
    return Rect.fromCenter(
      center: availableBounds.center,
      width: width,
      height: height,
    );
  }
}
