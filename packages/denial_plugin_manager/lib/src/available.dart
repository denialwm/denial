import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'catalog.dart';
import 'model.dart';
import 'preflight.dart';
import 'package_graph.dart';
import 'source.dart';
import 'store.dart';

final class AvailablePlugins {
  AvailablePlugins(this.store, this.repository);
  final ManagerStore store;
  final SourceRepository repository;

  Future<List<Map<String, Object?>>> builtins(String? runtime) async {
    if (runtime == null) return [];
    final manifest = File(p.join(runtime, 'plugins/builtins.yaml'));
    if (!manifest.existsSync()) {
      throw const CompositionException(
        'Installed source has no built-in plugin manifest',
      );
    }
    final value = readYamlMap(manifest);
    if (value['schema'] != 1) {
      throw const CompositionException('Unsupported built-in plugin manifest');
    }
    final result = <Map<String, Object?>>[];
    for (final item in value['plugins']! as List) {
      final entry = item as Map<String, Object?>;
      final source = PluginSource(
        kind: SourceKind.builtin,
        location: p.join(runtime, 'plugins'),
        path: entry['path']! as String,
      );
      final resolved = await repository.resolve(source);
      result.add({
        ...resolved.toJson(),
        'builtin': true,
        'default': entry['default'] == true,
      });
    }
    return result;
  }

  Future<Map<String, Object?>> list(Map<String, Object?> configuration) async {
    configuration = PluginCatalog.configuration(configuration);
    final builtIn = await builtins(configuration['runtime'] as String?);
    final url = configuration['catalog-git'] as String?;
    final configured = url != null && url.isNotEmpty;
    var catalog = store.read('catalog.json');
    if (configured && catalog.isEmpty) {
      catalog = await store.exclusive(() async {
        final cached = store.read('catalog.json');
        if (cached.isNotEmpty) return cached;
        try {
          return await refresh(configuration);
        } catch (error) {
          // A first-run network failure must leave built-ins usable and must
          // not refetch on every GUI poll. Explicit Refresh retries it.
          final failed = <String, Object?>{
            'entries': <Object?>[],
            'errors': ['$error'],
          };
          store.write('catalog.json', failed);
          return store.read('catalog.json');
        }
      });
    }
    return {
      'builtins': builtIn,
      'catalog': catalog,
      'configured': configured,
      'declarations': SelectionPreflight(store).describe({
        for (final plugin in [...builtIn, ...?catalog['entries'] as List?])
          (plugin as Map)['name']: plugin,
      }),
    };
  }

  Future<Map<String, Object?>> refresh(
    Map<String, Object?> configuration,
  ) async {
    configuration = PluginCatalog.configuration(configuration);
    final url = configuration['catalog-git'] as String?;
    if (url == null || url.isEmpty) {
      throw const CompositionException(
        'No community catalog repository is configured',
      );
    }
    final source = PluginSource(
      kind: SourceKind.git,
      location: url,
      ref: configuration['catalog-ref'] as String?,
    );
    final sources = await PluginCatalog.fetch(
      repository,
      source,
      file: configuration['catalog-file'] as String? ?? 'plugins.yaml',
    );
    final entries = <Map<String, Object?>>[];
    final errors = <String>[];
    for (final plugin in sources) {
      try {
        entries.add((await repository.resolve(plugin)).toJson());
      } catch (error) {
        errors.add('${plugin.location}: $error');
      }
    }
    final result = {
      'source': source.toJson(),
      'entries': entries,
      'errors': errors,
      'updated': DateTime.now().toUtc().toIso8601String(),
    };
    store.write('catalog.json', result);
    return result;
  }

  /// Points the built-in plugin records at [runtime]'s sources. Shipped
  /// plugins are already installed, but another runtime must never select
  /// newly introduced defaults for an existing user.
  Future<void> adoptBuiltins(String runtime) async {
    final selection = store.selection;
    final roots = Map<String, Object?>.from(selection['roots']! as Map);
    final installed = store.read(
      'installed.json',
      fallback: {'plugins': roots},
    );
    final known = Map<String, Object?>.from(installed['plugins']! as Map);
    final before = jsonEncode(known);
    bool builtin(Object? value) =>
        value is Map &&
        value['source'] is Map &&
        (value['source'] as Map)['kind'] == 'builtin';
    var changed = false;
    for (final entry in await builtins(runtime)) {
      final name = entry['name']! as String;
      final value = Map<String, Object?>.from(entry)
        ..remove('builtin')
        ..remove('default');
      if (!known.containsKey(name) || builtin(known[name])) {
        known[name] = value;
      }
      if (builtin(roots[name]) &&
          jsonEncode(roots[name]) != jsonEncode(value)) {
        roots[name] = value;
        changed = true;
      }
    }
    if (jsonEncode(known) != before ||
        !store.file('installed.json').existsSync()) {
      store.write('installed.json', {'plugins': known});
    }
    if (changed) {
      store.write('selection.json', {
        ...selection,
        'roots': roots,
        'revision': (selection['revision']! as int) + 1,
      });
    }
  }

  /// Makes the selection the plugins Denial comes with, and only them.
  /// What was turned off stays known and can be turned on again.
  Future<void> defaults(String? runtime) async {
    final defaults = [
      for (final item in await builtins(runtime))
        if (item['default'] == true)
          await repository.resolve(
            PluginSource.fromJson(item['source']! as Map<String, Object?>),
          ),
    ];
    final names = {for (final plugin in defaults) plugin.name};
    final roots = store.selection['roots']! as Map;
    for (final root in roots.entries.toList()) {
      final source = (root.value as Map)['source'] as Map?;
      if (!names.contains(root.key) || source?['kind'] != 'builtin') {
        store.remove(root.key as String);
      }
    }
    for (final plugin in defaults) {
      if (!(store.selection['roots']! as Map).containsKey(plugin.name)) {
        store.select(plugin);
      }
    }
  }
}
