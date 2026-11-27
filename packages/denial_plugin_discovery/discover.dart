// Finds the plugin contributions of a resolved plugin workspace with Dart's
// analyzer: @Plugin libraries, @Provides classes, the @ExtensionPoint
// contracts they implement and the contracts their constructors take, with
// aliases and re-exports resolved. It analyzes source and never imports or
// runs plugin code.
//
// The plugin manager (denial-apps, libraries/denial-plugins) runs this file
// uncompiled, with the package configuration of the Flutter tool, whose
// analyzer it uses, and caches a kernel snapshot of it per Dart version. It
// reads one JSON request on stdin and prints one JSON answer on stdout:
//
//   {"sdk": DART_SDK, "cache": ANALYZER_CACHE_OR_NULL, "application": ROOT,
//    "packages": [{"name", "lib"}], "eligible": [NAME]}
//   {"plugins": [NAME], "contracts": [...], "contributions": [...]}
//
// `packages` is the whole runtime graph, which names every library;
// `eligible` the packages that depend on denial_sdk, the only ones that can
// contribute. A failure is one line on stderr and exit code 1.
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
// The public factory always creates a fresh memory store; the file store
// keeps analysis results between runs.
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/file_byte_store.dart';

const cardinalities = ['exactlyOne', 'zeroOrOne', 'zeroOrMore'];

final class Failure implements Exception {
  const Failure(this.message);
  final String message;
}

final class TypeId implements Comparable<TypeId> {
  const TypeId(this.library, this.name);
  final String library;
  final String name;
  String get key => '$library#$name';
  Map<String, Object?> toJson() => {'library': library, 'name': name};
  @override
  String toString() => key;
  @override
  bool operator ==(Object other) => other is TypeId && key == other.key;
  @override
  int get hashCode => key.hashCode;
  @override
  int compareTo(TypeId other) => key.compareTo(other.key);
}

Future<void> main() async {
  try {
    final request = jsonDecode(
      await stdin.transform(utf8.decoder).join(),
    ) as Map<String, Object?>;
    stdout.write(jsonEncode(await discover(request)));
  } on Failure catch (failure) {
    stderr.writeln(failure.message);
    exitCode = 1;
  }
}

AnalysisContextCollection contexts(String root, String sdk, String? cache) {
  if (cache != null) {
    try {
      Directory(cache).createSync(recursive: true);
      return AnalysisContextCollectionImpl(
        includedPaths: [root],
        sdkPath: sdk,
        byteStore: FileByteStore(cache),
      );
    } on FileSystemException {
      // An unavailable cache must not block valid plugin work.
    }
  }
  return AnalysisContextCollection(includedPaths: [root], sdkPath: sdk);
}

Future<Map<String, Object?>> discover(Map<String, Object?> request) async {
  final packages = [
    for (final item in request['packages']! as List)
      (
        name: (item as Map)['name'] as String,
        lib: Directory(item['lib'] as String).absolute.path,
      ),
  ];
  final eligible = (request['eligible']! as List).cast<String>().toSet();
  String libraryUri(String path) {
    final absolute = File(path).absolute.path;
    for (final package in packages) {
      final lib = package.lib.endsWith('/') ? package.lib : '${package.lib}/';
      if (absolute.startsWith(lib)) {
        return 'package:${package.name}/${absolute.substring(lib.length)}';
      }
    }
    throw Failure('Declaration outside runtime package libraries: $path');
  }

  final root = request['application']! as String;
  final collection = contexts(
    root,
    request['sdk']! as String,
    request['cache'] as String?,
  );
  final session = collection.contextFor(root).currentSession;
  try {
    final contracts = <TypeId, Map<String, Object?>>{};
    final contributions = <(TypeId, Map<String, Object?>)>[];
    final plugins = <String>{};
    final files = <(String, String)>[];
    for (final package in packages) {
      if (!eligible.contains(package.name)) continue;
      final lib = Directory(package.lib);
      if (!lib.existsSync()) continue;
      for (final file
          in lib
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        // Only a candidate filter; the analyzer resolves aliases and SDK
        // identity below.
        final source = file.readAsStringSync();
        if (!source.contains('@') || !source.contains('library')) continue;
        final unit = parseString(
          content: source,
          throwIfDiagnostics: false,
        ).unit;
        if (!unit.directives.whereType<LibraryDirective>().any(
          (directive) => directive.metadata.isNotEmpty,
        )) {
          continue;
        }
        files.add((package.name, file.path));
      }
    }
    files.sort((a, b) => a.$2.compareTo(b.$2));
    final markerResult = await session.getLibraryByUri(
      'package:denial_sdk/src/composition/annotations.dart',
    );
    if (markerResult is! LibraryElementResult) {
      throw const Failure('Cannot resolve SDK composition metadata');
    }
    final markers = {for (final c in markerResult.element.classes) c.name: c};
    for (final (package, path) in files) {
      final resolved = await session.getLibraryByUri(libraryUri(path));
      if (resolved is! LibraryElementResult) {
        throw Failure('Cannot resolve contribution library $path');
      }
      final library = resolved.element;
      List<DartObject> annotations(Element element, String marker) => element
          .metadata
          .annotations
          .map((a) => a.computeConstantValue())
          .whereType<DartObject>()
          .where(
            (a) =>
                a.type is InterfaceType &&
                (a.type! as InterfaceType).element == markers[marker],
          )
          .toList();
      if (annotations(library, 'Plugin').isEmpty) continue;
      plugins.add(package);
      TypeId identity(InterfaceElement element) {
        final uri = element.library.uri;
        return TypeId(
          uri.scheme == 'package'
              ? uri.toString()
              : libraryUri(element.library.firstFragment.source.fullName),
          element.name!,
        );
      }

      TypeId contractType(InterfaceType type, String origin) {
        final metadata = annotations(type.element, 'ExtensionPoint');
        if (metadata.length != 1 ||
            type.typeArguments.isNotEmpty ||
            type.element.isPrivate) {
          throw Failure(
            '$origin: ${type.getDisplayString()} must be a public, non-generic @ExtensionPoint',
          );
        }
        final index = metadata.single
            .getField('cardinality')
            ?.getField('index')
            ?.toIntValue();
        if (index == null || index < 0 || index >= cardinalities.length) {
          throw Failure('$origin: invalid cardinality');
        }
        final id = identity(type.element);
        contracts[id] = {
          'type': id.toJson(),
          'cardinality': cardinalities[index],
        };
        return id;
      }

      for (final implementation in library.classes) {
        final provides = annotations(implementation, 'Provides');
        if (provides.isEmpty) continue;
        final id = identity(implementation);
        if (implementation.isAbstract ||
            implementation.isPrivate ||
            implementation.typeParameters.isNotEmpty) {
          throw Failure('$id must be public, concrete, and non-generic');
        }
        final supplied = <TypeId>[];
        for (final annotation in provides) {
          final type = annotation.getField('contract')?.toTypeValue();
          if (type is! InterfaceType) {
            throw Failure('$id: @Provides needs an interface type');
          }
          final contract = contractType(type, id.key);
          if (!library.typeSystem.isSubtypeOf(implementation.thisType, type)) {
            throw Failure('$id does not implement $contract');
          }
          if (supplied.contains(contract)) {
            throw Failure('$id provides $contract more than once');
          }
          supplied.add(contract);
        }
        final constructor = implementation.unnamedConstructor;
        if (constructor == null) {
          throw Failure(
            '$id needs an unnamed constructor for generated injection',
          );
        }
        final arguments = <Map<String, Object?>>[];
        for (final parameter in constructor.formalParameters) {
          final type = parameter.type;
          InterfaceType? dependency;
          var many = false;
          if (type is InterfaceType) {
            if (type.isDartCoreList &&
                type.typeArguments.single is InterfaceType &&
                annotations(
                  (type.typeArguments.single as InterfaceType).element,
                  'ExtensionPoint',
                ).isNotEmpty) {
              dependency = type.typeArguments.single as InterfaceType;
              many = true;
            } else if (annotations(type.element, 'ExtensionPoint').isNotEmpty) {
              dependency = type;
            }
          }
          if (dependency == null) {
            if (parameter.isOptionalNamed) continue;
            throw Failure(
              '$id parameter ${parameter.name}: use a typed extension point, List<Contract>, or an optional named default',
            );
          }
          final contract = contractType(dependency, id.key);
          arguments.add({
            'name': parameter.name!,
            'contract': contract.toJson(),
            'named': parameter.isNamed,
            'many': many,
            'nullable': type.nullabilitySuffix == NullabilitySuffix.question,
          });
        }
        supplied.sort();
        contributions.add((
          id,
          {
            'package': package,
            'type': id.toJson(),
            'contracts': [for (final contract in supplied) contract.toJson()],
            'arguments': arguments,
          },
        ));
      }
    }
    contributions.sort((a, b) => a.$1.compareTo(b.$1));
    final contractIds = contracts.keys.toList()..sort();
    return {
      'plugins': plugins.toList()..sort(),
      'contracts': [for (final id in contractIds) contracts[id]],
      'contributions': [for (final (_, value) in contributions) value],
    };
  } finally {
    await collection.dispose();
  }
}
