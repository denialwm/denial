import 'dart:io';

import '../runtime_paths.dart';
import '../models/desktop_app.dart';

class DesktopAppsRepository {
  const DesktopAppsRepository({required RuntimePaths paths}) : _paths = paths;

  final RuntimePaths _paths;

  Future<List<DesktopApp>> loadApplications() async {
    final filesById = <String, File>{};
    for (final dir in _paths.desktopApplicationDirs()) {
      if (!await dir.exists()) {
        continue;
      }

      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.desktop')) {
          continue;
        }

        filesById.putIfAbsent(_basename(entity.path), () => entity);
      }
    }

    final iconCache = <String, String?>{};
    final apps = <DesktopApp>[];
    for (final entry in filesById.entries) {
      final app = await _parseDesktopFile(entry.key, entry.value, iconCache);
      if (app != null) {
        apps.add(app);
      }
    }

    apps.sort((a, b) {
      final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      if (byName != 0) {
        return byName;
      }
      return a.id.compareTo(b.id);
    });
    return apps;
  }

  Future<DesktopApp?> _parseDesktopFile(
    String id,
    File file,
    Map<String, String?> iconCache,
  ) async {
    final fields = <String, String>{};
    var inDesktopEntry = false;

    for (final rawLine in await file.readAsLines()) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) {
        continue;
      }

      if (line.startsWith('[') && line.endsWith(']')) {
        inDesktopEntry = line == '[Desktop Entry]';
        continue;
      }

      if (!inDesktopEntry) {
        continue;
      }

      final equals = line.indexOf('=');
      if (equals <= 0) {
        continue;
      }

      fields[line.substring(0, equals)] = line.substring(equals + 1);
    }

    if ((fields['Type'] ?? 'Application') != 'Application') {
      return null;
    }
    if (_desktopBool(fields['Hidden']) || _desktopBool(fields['NoDisplay'])) {
      return null;
    }
    if (_desktopBool(fields['Terminal'])) {
      return null;
    }
    if (!_matchesCurrentDesktop(fields)) {
      return null;
    }

    final tryExec = fields['TryExec'];
    if (tryExec != null && tryExec.isNotEmpty && !_binaryAvailable(tryExec)) {
      return null;
    }

    final name = _localizedDesktopValue(fields, 'Name');
    final exec = fields['Exec'];
    if (name == null || name.trim().isEmpty || exec == null || exec.isEmpty) {
      return null;
    }

    final icon = fields['Icon']?.trim();
    final iconPath = icon == null || icon.isEmpty
        ? null
        : iconCache.putIfAbsent(icon, () => resolveIconPath(icon));
    final categories = (fields['Categories'] ?? '')
        .split(';')
        .map((category) => category.trim())
        .where((category) => category.isNotEmpty)
        .toList(growable: false);

    return DesktopApp(
      id: id,
      name: _unescapeDesktopValue(name.trim()),
      exec: exec,
      desktopPath: file.path,
      categories: categories,
      icon: icon,
      iconPath: iconPath,
      startupWmClass: fields['StartupWMClass']?.trim(),
    );
  }

  String? _localizedDesktopValue(Map<String, String> fields, String key) {
    final locale = _paths.environment['LANG'] ?? '';
    final localeBase = locale.split('.').first;
    final language = localeBase.split('_').first;
    return fields['$key[$localeBase]'] ??
        fields['$key[$language]'] ??
        fields[key];
  }

  bool _matchesCurrentDesktop(Map<String, String> fields) {
    final current =
        (_paths.environment['XDG_CURRENT_DESKTOP'] ?? 'Denial')
            .split(':')
            .where((item) => item.isNotEmpty)
            .toSet();
    if (current.isEmpty) {
      current.add('Denial');
    }

    final onlyShowIn = _desktopList(fields['OnlyShowIn']);
    if (onlyShowIn.isNotEmpty && onlyShowIn.intersection(current).isEmpty) {
      return false;
    }

    final notShowIn = _desktopList(fields['NotShowIn']);
    if (notShowIn.intersection(current).isNotEmpty) {
      return false;
    }

    return true;
  }

  bool _binaryAvailable(String command) {
    final trimmed = command.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    if (trimmed.startsWith('/')) {
      return File(trimmed).existsSync();
    }

    final path = _paths.environment['PATH'] ??
        '/usr/local/sbin:/usr/local/bin:/usr/bin:/bin';
    for (final dir in path.split(':')) {
      if (dir.isEmpty) {
        continue;
      }
      if (File('$dir/$trimmed').existsSync()) {
        return true;
      }
    }
    return false;
  }

  /// Resolves a freedesktop icon name or an absolute image path.
  ///
  /// Callers displaying external events should run this filesystem search off
  /// the UI isolate and cache its result.
  String? resolveIconPath(String icon) {
    if (icon.startsWith('/')) {
      return _isSafeIconFile(icon) ? icon : null;
    }

    final name = _stripSupportedExtension(icon);
    final extensions = ['png', 'webp', 'jpg', 'jpeg', 'svg'];
    final sizes = [
      'scalable',
      '512x512',
      '256x256',
      '192x192',
      '128x128',
      '96x96',
      '64x64',
      '48x48',
      '32x32',
    ];
    final contexts = ['apps', 'categories', 'devices', 'places'];

    for (final root in _paths.iconRoots()) {
      for (final extension in extensions) {
        final pixmap = '$root/pixmaps/$name.$extension';
        if (_isSafeIconFile(pixmap)) {
          return pixmap;
        }
      }

      final iconsDir = Directory('$root/icons');
      if (!iconsDir.existsSync()) {
        continue;
      }

      final themes = <String>[
        '$root/icons/hicolor',
        '$root/icons/Adwaita',
        '$root/icons/Tela',
      ];
      try {
        for (final entity in iconsDir.listSync(followLinks: false)) {
          if (entity is Directory) {
            themes.add(entity.path);
          }
        }
      } on FileSystemException {
        continue;
      }

      for (final theme in RuntimePaths.uniquePaths(themes)) {
        for (final size in sizes) {
          for (final context in contexts) {
            for (final extension in extensions) {
              final path = '$theme/$size/$context/$name.$extension';
              if (_isSafeIconFile(path)) {
                return path;
              }
            }
          }
        }
      }
    }

    return null;
  }

  String? resolveNotificationIcon({
    required String appIcon,
    required String desktopEntry,
  }) {
    if (appIcon.trim().isNotEmpty) {
      final direct = resolveIconPath(appIcon.trim());
      if (direct != null) {
        return direct;
      }
    }

    final requestedEntry = desktopEntry.trim();
    if (requestedEntry.contains('/') ||
        requestedEntry.contains(r'\') ||
        requestedEntry == '.' ||
        requestedEntry == '..') {
      return null;
    }
    final normalizedEntry = requestedEntry.endsWith('.desktop')
        ? requestedEntry
        : '$requestedEntry.desktop';
    if (normalizedEntry == '.desktop') {
      return null;
    }
    for (final directory in _paths.desktopApplicationDirs()) {
      final file = File('${directory.path}/$normalizedEntry');
      if (!file.existsSync()) {
        continue;
      }
      try {
        var inDesktopEntry = false;
        for (final rawLine in file.readAsLinesSync()) {
          final line = rawLine.trim();
          if (line.startsWith('[') && line.endsWith(']')) {
            inDesktopEntry = line == '[Desktop Entry]';
            continue;
          }
          if (!inDesktopEntry || !line.startsWith('Icon=')) {
            continue;
          }
          final icon = line.substring('Icon='.length).trim();
          return icon.isEmpty ? null : resolveIconPath(icon);
        }
      } on FileSystemException {
        return null;
      }
    }
    return null;
  }
}

bool _desktopBool(String? value) {
  return value != null && value.toLowerCase() == 'true';
}

Set<String> _desktopList(String? value) {
  if (value == null || value.isEmpty) {
    return const {};
  }
  return value
      .split(';')
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toSet();
}

String _stripSupportedExtension(String icon) {
  final lower = icon.toLowerCase();
  for (final extension in ['.png', '.webp', '.jpg', '.jpeg', '.svg']) {
    if (lower.endsWith(extension)) {
      return icon.substring(0, icon.length - extension.length);
    }
  }
  return icon;
}

bool _isSupportedIconPath(String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.png') ||
      lower.endsWith('.webp') ||
      lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.svg');
}

bool _isSafeIconFile(String path) {
  if (!_isSupportedIconPath(path)) {
    return false;
  }
  try {
    final stat = File(path).statSync();
    return stat.type == FileSystemEntityType.file &&
        stat.size > 0 &&
        stat.size <= 8 * 1024 * 1024;
  } on FileSystemException {
    return false;
  }
}

String _unescapeDesktopValue(String value) {
  return value
      .replaceAll(r'\s', ' ')
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\t', '\t')
      .replaceAll(r'\\', r'\');
}

String _basename(String path) {
  final slash = path.lastIndexOf('/');
  return slash < 0 ? path : path.substring(slash + 1);
}
