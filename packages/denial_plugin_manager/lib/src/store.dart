import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'model.dart';
import 'source.dart';

/// Durable manager state. Mutating commands run under [exclusive]. Builds live
/// in fresh candidate directories; active/previous point only to verified IDs.
final class ManagerStore {
  ManagerStore(this.root);
  final Directory root;
  File file(String relative) => File(p.join(root.path, relative));

  static Directory defaultRoot() {
    final env = Platform.environment;
    final state = env['XDG_STATE_HOME'] ?? p.join(env['HOME']!, '.local/state');
    return Directory(p.join(state, 'denial/plugins'));
  }

  Map<String, Object?> read(
    String relative, {
    Map<String, Object?> fallback = const {},
  }) {
    final target = file(relative);
    if (!target.existsSync()) return fallback;
    final value = jsonDecode(target.readAsStringSync()) as Map<String, Object?>;
    if (value['schema'] != 1) {
      throw CompositionException('Unsupported state schema in ${target.path}');
    }
    return value;
  }

  void write(String relative, Map<String, Object?> value) {
    final target = file(relative);
    target.parent.createSync(recursive: true);
    final temporary = File('${target.path}.$pid.tmp');
    temporary.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({'schema': 1, ...value})}\n',
      flush: true,
    );
    temporary.renameSync(target.path);
  }

  /// Runs [action] under the manager mutation lock. A background operation
  /// that resumes after waiting may [wait] briefly for a short command, such
  /// as one started from Plugins, to release the lock.
  Future<T> exclusive<T>(
    Future<T> Function() action, {
    Duration wait = Duration.zero,
  }) async {
    root.createSync(recursive: true);
    final lock = await file('manager.lock').open(mode: FileMode.append);
    try {
      final deadline = DateTime.now().add(wait);
      while (true) {
        try {
          await lock.lock(FileLock.exclusive);
          break;
        } on FileSystemException {
          if (DateTime.now().isAfter(deadline)) {
            throw const CompositionException(
              'Another plugin manager operation is running. Wait for its job to finish.',
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }
      return await action();
    } finally {
      await lock.close();
    }
  }

  Map<String, Object?> get selection => read(
    'selection.json',
    fallback: {
      'schema': 1,
      'revision': 0,
      'roots': <String, Object?>{},
      'selections': <String, Object?>{},
      'ordering': <String, Object?>{},
    },
  );

  void select(ResolvedSource plugin) {
    final state = selection;
    final roots = Map<String, Object?>.from(state['roots']! as Map);
    final existing = roots[plugin.name] as Map<String, Object?>?;
    if (existing != null &&
        !(plugin.source.kind == SourceKind.builtin &&
            (existing['source'] as Map?)?['kind'] == 'builtin') &&
        jsonEncode(existing['source']) != jsonEncode(plugin.source.toJson())) {
      throw CompositionException(
        '${plugin.name} already has a different source; remove it before replacing its source',
      );
    }
    final installed = read(
      'installed.json',
      fallback: {'plugins': <String, Object?>{}},
    );
    final known = Map<String, Object?>.from(installed['plugins']! as Map);
    known[plugin.name] = plugin.toJson();
    write('installed.json', {'plugins': known});
    roots[plugin.name] = plugin.toJson();
    write('selection.json', {
      ...state,
      'revision': (state['revision']! as int) + 1,
      'roots': roots,
    });
  }

  void remove(String package) {
    final state = selection;
    final roots = Map<String, Object?>.from(state['roots']! as Map);
    if (!roots.containsKey(package)) {
      throw CompositionException(
        '$package is not a selected root. Required dependencies follow their dependent roots.',
      );
    }
    roots.remove(package);
    write('selection.json', {
      ...state,
      'revision': (state['revision']! as int) + 1,
      'roots': roots,
    });
  }

  String createJob(String operation, Map<String, Object?> arguments) {
    final stamp = DateTime.now().toUtc();
    final id = '${stamp.microsecondsSinceEpoch}-$pid';
    write('jobs/$id.json', {
      'id': id,
      'operation': operation,
      'arguments': arguments,
      'phase': 'queued',
      'created': stamp.toIso8601String(),
      'ownerPid': pid,
      'ownerStart': processStart(pid),
    });
    return id;
  }

  void updateJob(String id, Map<String, Object?> updates) {
    validateId(id);
    final old = read('jobs/$id.json');
    write('jobs/$id.json', {
      ...old,
      ...updates,
      'updated': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// One job's status, including whether its worker exited unrecorded.
  Map<String, Object?> job(String id) {
    validateId(id);
    return _jobStatus(read('jobs/$id.json'));
  }

  List<Map<String, Object?>> jobs() {
    final directory = Directory(p.join(root.path, 'jobs'));
    if (!directory.existsSync()) return [];
    final files =
        directory
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .toList()
          ..sort((a, b) => b.path.compareTo(a.path));
    return files
        .take(30)
        .map((f) => _jobStatus(read(p.relative(f.path, from: root.path))))
        .toList();
  }

  Map<String, Object?> _jobStatus(Map<String, Object?> job) {
    if (job['phase'] != 'running' && job['phase'] != 'queued') return job;
    final spawn = read('jobs/${job['id']}.spawn');
    // A process ID is judged only by the start time recorded beside it: the
    // worker's own record, else its spawn record, else the submitting client.
    // A spawn record without a start time can only show the process exists.
    final (process, expected) = switch ((job['pid'], spawn['pid'])) {
      (final int worker, _) => (worker, job['processStart'] as String?),
      (_, final int spawned) => (spawned, spawn['processStart'] as String?),
      _ => (job['ownerPid'] as int?, job['ownerStart'] as String?),
    };
    final actual = process == null ? null : processStart(process);
    if (process != null &&
        (expected == null ? actual == null : actual != expected)) {
      return {
        ...job,
        'phase': 'interrupted',
        'error': 'The worker exited before completion was recorded. Check the native composition status before retrying.',
      };
    }
    return job;
  }

  static String? processStart(int process) {
    try {
      final text = File('/proc/$process/stat').readAsStringSync();
      return text.substring(text.lastIndexOf(')') + 2).split(' ')[19];
    } on FileSystemException {
      return null;
    }
  }

  static void validateId(String id) {
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) {
      throw const CompositionException('Invalid candidate/job identity');
    }
  }
}

/// The file checksum shared by planning, compilation and artifact verification.
String fileDigest(String path) =>
    sha256.convert(File(path).readAsBytesSync()).toString();

/// Fingerprints files, relative names, and symlink targets. Callers must freeze
/// local inputs before hashing; a Git revision alone cannot identify dirty work.
String treeDigest(
  Directory root, {
  Set<String> ignoredNames = const {},
  String Function(File)? digestFile,
}) {
  final entries = <FileSystemEntity>[];
  void visit(Directory directory) {
    for (final entry in directory.listSync(followLinks: false)) {
      if (ignoredNames.contains(p.basename(entry.path))) continue;
      entries.add(entry);
      if (entry is Directory) visit(entry);
    }
  }

  visit(root);
  entries.sort((a, b) => a.path.compareTo(b.path));
  final chunks = <int>[];
  for (final entry in entries) {
    final relative = p.relative(entry.path, from: root.path);
    chunks.addAll(utf8.encode('$relative\u0000'));
    if (entry is File) {
      chunks.addAll(
        utf8.encode(
          'file:${digestFile == null ? sha256.convert(entry.readAsBytesSync()) : digestFile(entry)}\n',
        ),
      );
    } else if (entry is Link) {
      chunks.addAll(utf8.encode('link:${entry.targetSync()}\n'));
    } else {
      chunks.addAll(utf8.encode('directory\n'));
    }
  }
  return sha256.convert(chunks).toString();
}

/// Stable keys ignore map insertion order, while retaining meaningful list order.
String contentKey(Object? value) {
  Object? sorted(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: sorted(value[key])};
    }
    if (value is List) return value.map(sorted).toList();
    return value;
  }

  return sha256.convert(utf8.encode(jsonEncode(sorted(value)))).toString();
}

/// Avoid re-reading unchanged compiler bytes. Size, mtime, ctime and mode must
/// all match; ctime detects replacements and writes whose mtime was preserved.
/// This is build acceleration for trusted local inputs, not a security boundary.
final class FileDigestCache {
  FileDigestCache(this.store) {
    try {
      entries = Map<String, Object?>.from(
        store.read('cache/file-digests.json')['files'] as Map? ?? {},
      );
    } on Object {
      entries = {};
    }
  }
  final ManagerStore store;
  late final Map<String, Object?> entries;
  bool dirty = false;

  String digest(File file) {
    final canonical = file.resolveSymbolicLinksSync();
    String stamp(FileStat stat) =>
        '${stat.size}:${stat.modified.microsecondsSinceEpoch}:${stat.changed.microsecondsSinceEpoch}:${stat.mode}';
    final before = stamp(file.statSync());
    final cached = entries[canonical] as Map?;
    if (cached?['stamp'] == before && cached?['digest'] is String) {
      return cached!['digest'] as String;
    }
    final result = sha256.convert(file.readAsBytesSync()).toString();
    if (stamp(file.statSync()) != before) {
      throw CompositionException(
        'Input changed while checking $canonical; try again',
      );
    }
    entries[canonical] = {'stamp': before, 'digest': result};
    dirty = true;
    return result;
  }

  String tree(Directory directory, {Set<String> ignoredNames = const {}}) =>
      treeDigest(directory, ignoredNames: ignoredNames, digestFile: digest);
  void save() {
    if (dirty) store.write('cache/file-digests.json', {'files': entries});
  }
}
