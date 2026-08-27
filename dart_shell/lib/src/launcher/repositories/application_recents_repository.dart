import 'dart:convert';
import 'dart:io';

import '../runtime_paths.dart';

const int applicationRecentEntryLimit = 8;
const int _maximumEntryIdLength = 4096;

abstract interface class ApplicationRecentsStore {
  Future<List<String>> readEntries();

  Future<void> saveEntries(List<String> entries);
}

class ApplicationRecentsRepository implements ApplicationRecentsStore {
  const ApplicationRecentsRepository({required RuntimePaths paths})
    : _paths = paths;

  final RuntimePaths _paths;

  @override
  Future<List<String>> readEntries() async {
    try {
      final file = await _paths.applicationRecentsFile();
      if (!await file.exists()) {
        return const <String>[];
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> || decoded['version'] != 1) {
        return const <String>[];
      }
      return _normalizeEntries(decoded['entries']);
    } on Object {
      return const <String>[];
    }
  }

  @override
  Future<void> saveEntries(List<String> entries) async {
    try {
      final file = await _paths.applicationRecentsFile();
      final temporary = File('${file.path}.tmp');
      final payload = jsonEncode(<String, Object>{
        'version': 1,
        'entries': _normalizeEntries(entries),
      });
      await temporary.writeAsString('$payload\n', flush: true);
      await temporary.rename(file.path);
    } on Object {
      // Recency is a best-effort enhancement; launching remains authoritative.
    }
  }
}

List<String> _normalizeEntries(Object? value) {
  if (value is! List) {
    return const <String>[];
  }
  final seen = <String>{};
  final entries = <String>[];
  for (final candidate in value) {
    if (candidate is! String ||
        candidate.isEmpty ||
        candidate.length > _maximumEntryIdLength ||
        !seen.add(candidate)) {
      continue;
    }
    entries.add(candidate);
    if (entries.length == applicationRecentEntryLimit) {
      break;
    }
  }
  return List<String>.unmodifiable(entries);
}
