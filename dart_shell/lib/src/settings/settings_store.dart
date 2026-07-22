import 'dart:convert';
import 'dart:io';

import '../launcher/runtime_paths.dart';
import 'shell_settings.dart';

abstract interface class SettingsStore {
  Future<ShellSettings?> read();

  Future<void> write(ShellSettings settings);
}

class FileSettingsStore implements SettingsStore {
  FileSettingsStore(this._paths);

  final RuntimePaths _paths;
  Future<void> _writeQueue = Future<void>.value();

  @override
  Future<ShellSettings?> read() async {
    try {
      final file = File(_paths.settingsPath);
      if (!await file.exists()) {
        return null;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      return ShellSettings.fromJson(decoded);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(ShellSettings settings) {
    final write = _writeQueue.then((_) => _write(settings));
    _writeQueue = write.catchError((_) {});
    return write;
  }

  Future<void> _write(ShellSettings settings) async {
    final file = await _paths.settingsFile();
    final temporary = File('${file.path}.tmp');
    final payload = const JsonEncoder.withIndent(
      '  ',
    ).convert(settings.toJson());
    await temporary.writeAsString('$payload\n', flush: true);
    await temporary.rename(file.path);
  }
}
