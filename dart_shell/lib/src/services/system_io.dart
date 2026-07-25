import 'dart:convert';
import 'dart:io';

/// Low-level, best-effort helpers for talking to the device's sysfs / runtime
/// files. Every call swallows the failure path so the shell stays responsive
/// on a dev box where the hardware nodes are absent.

Future<String?> readSysString(String path) async {
  try {
    return (await File(path).readAsString()).trim();
  } on FileSystemException {
    return null;
  }
}

Future<int?> readSysInt(String path) async {
  final value = await readSysString(path);
  return value == null ? null : int.tryParse(value);
}

Future<Map<String, String>> readKeyValueFile(String path) async {
  try {
    final fields = <String, String>{};
    final content = await File(path).readAsString();
    for (final line in const LineSplitter().convert(content)) {
      final split = line.indexOf('=');
      if (split > 0) {
        fields[line.substring(0, split)] = line.substring(split + 1).trim();
      }
    }
    return fields;
  } on FileSystemException {
    return const <String, String>{};
  }
}
