import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../runtime_paths.dart';
import '../models/desktop_app.dart';

class DesktopAppsRepository {
  const DesktopAppsRepository({required this._paths});

  final RuntimePaths _paths;

  /// Watches the XDG application directories for desktop-entry changes.
  ///
  /// Filesystem watching is best effort. Directories which do not exist or
  /// cannot be watched are skipped, while the launcher's slower polling path
  /// remains available as a fallback.
  Future<DesktopAppsWatcher> watchApplications({
    required void Function() onChanged,
  }) async {
    final subscriptions = <StreamSubscription<FileSystemEvent>>[];
    for (final directory in _paths.desktopApplicationDirs()) {
      try {
        if (!await directory.exists()) {
          continue;
        }
        subscriptions.add(
          directory.watch().listen(
            (event) {
              if (_isDesktopApplicationEvent(event)) {
                onChanged();
              }
            },
            onError: (_) {
              // A periodic rescan remains active if a mount or directory stops
              // supporting filesystem notifications during the session.
            },
          ),
        );
      } on Object {
        // Some system and sandboxed application directories may be
        // inaccessible. Discovery still covers every readable directory.
      }
    }
    return DesktopAppsWatcher._(subscriptions);
  }

  Future<List<DesktopApp>> loadApplications() async {
    final filesById = <String, File>{};
    for (final dir in _paths.desktopApplicationDirs()) {
      if (!await dir.exists()) {
        continue;
      }

      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (!entity.path.endsWith('.desktop')) {
          continue;
        }
        final type = await FileSystemEntity.type(
          entity.path,
          followLinks: true,
        );
        if (type != FileSystemEntityType.file) {
          continue;
        }

        final relative = p.relative(entity.path, from: dir.path);
        final desktopFileId = p.split(relative).join('-');
        filesById.putIfAbsent(desktopFileId, () => File(entity.path));
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
    final current = (_paths.environment['XDG_CURRENT_DESKTOP'] ?? 'Denial')
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
    if (p.isAbsolute(trimmed)) {
      return File(trimmed).existsSync();
    }

    final path =
        _paths.environment['PATH'] ??
        '/usr/local/sbin:/usr/local/bin:/usr/bin:/bin';
    for (final dir in path.split(':')) {
      if (dir.isEmpty) {
        continue;
      }
      if (File(p.join(dir, trimmed)).existsSync()) {
        return true;
      }
    }
    return false;
  }

  /// Resolves a freedesktop icon name, absolute image path, or file URI.
  ///
  /// Callers displaying external events should run this filesystem search off
  /// the UI isolate and cache its result.
  String? resolveIconPath(String icon) {
    final requested = icon.trim();
    final directPath = _localIconPath(requested);
    if (directPath != null) {
      return _isSafeIconFile(directPath) ? directPath : null;
    }
    final uri = Uri.tryParse(requested);
    if (uri != null && uri.hasScheme) {
      return null;
    }

    final name = _stripSupportedExtension(requested);
    if (name.isEmpty || name.contains('/') || name.contains(r'\')) {
      return null;
    }
    final extensions = ['png', 'webp', 'jpg', 'jpeg', 'svg'];

    for (final root in _paths.iconRoots()) {
      for (final extension in extensions) {
        final pixmap = p.join(root, 'pixmaps', '$name.$extension');
        if (_isSafeIconFile(pixmap)) {
          return pixmap;
        }
      }

      final iconsDir = Directory(p.join(root, 'icons'));
      if (!iconsDir.existsSync()) {
        continue;
      }

      final themes = <String>[
        p.join(root, 'icons', 'hicolor'),
        p.join(root, 'icons', 'Adwaita'),
        p.join(root, 'icons', 'Tela'),
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
        for (final directory in _iconThemeDirectories(theme)) {
          for (final extension in extensions) {
            final path = p.join(theme, directory, '$name.$extension');
            if (_isSafeIconFile(path)) {
              return path;
            }
          }
        }
      }
    }

    return null;
  }

  String? resolveTrayIcon({
    required String iconName,
    required String iconThemePath,
  }) {
    final requested = iconName.trim();
    if (requested.isEmpty) {
      return null;
    }
    final name = _stripSupportedExtension(requested);
    final extensions = ['png', 'webp', 'jpg', 'jpeg', 'svg'];
    final sizes = [
      'scalable',
      '128x128',
      '96x96',
      '64x64',
      '48x48',
      '32x32',
      '24x24',
      '22x22',
      '16x16',
    ];
    final contexts = ['status', 'apps', 'devices', 'actions'];
    for (final root in RuntimePaths.uniquePaths(iconThemePath.split(':'))) {
      if (!p.isAbsolute(root)) {
        continue;
      }
      for (final extension in extensions) {
        final direct = p.join(root, '$name.$extension');
        if (_isSafeIconFile(direct)) {
          return direct;
        }
      }
      for (final size in sizes) {
        for (final context in contexts) {
          for (final extension in extensions) {
            final candidate = p.join(root, size, context, '$name.$extension');
            if (_isSafeIconFile(candidate)) {
              return candidate;
            }
          }
        }
      }
    }
    return resolveIconPath(requested);
  }

  String? resolveNotificationIcon({
    required String appIcon,
    required String desktopEntry,
    required String appName,
  }) {
    if (appIcon.trim().isNotEmpty) {
      final direct = resolveIconPath(appIcon.trim());
      if (direct != null) {
        return direct;
      }
    }

    final desktopIcon = _resolveDesktopEntryIcon(desktopEntry);
    if (desktopIcon != null) {
      return desktopIcon;
    }

    final requestedName = _normalizedDesktopIdentity(appName);
    if (requestedName.isEmpty) {
      return null;
    }

    for (final directory in _paths.desktopApplicationDirs()) {
      try {
        if (!directory.existsSync()) {
          continue;
        }
        for (final entity in directory.listSync(
          recursive: true,
          followLinks: false,
        )) {
          if (!entity.path.endsWith('.desktop') ||
              FileSystemEntity.typeSync(entity.path, followLinks: true) !=
                  FileSystemEntityType.file) {
            continue;
          }
          final fields = _readDesktopEntryFields(File(entity.path));
          if (!_desktopEntryMatchesAppName(
            fields,
            file: entity.path,
            directory: directory.path,
            requestedName: requestedName,
          )) {
            continue;
          }
          final icon = fields['Icon']?.trim() ?? '';
          if (icon.isNotEmpty) {
            final resolved = resolveIconPath(icon);
            if (resolved != null) {
              return resolved;
            }
          }
        }
      } on FileSystemException {
        continue;
      }
    }
    return null;
  }

  String? _resolveDesktopEntryIcon(String desktopEntry) {
    final requestedEntry = desktopEntry.trim();
    if (requestedEntry.isEmpty ||
        requestedEntry.contains('/') ||
        requestedEntry.contains(r'\') ||
        requestedEntry == '.' ||
        requestedEntry == '..') {
      return null;
    }
    final normalizedEntry = requestedEntry.endsWith('.desktop')
        ? requestedEntry
        : '$requestedEntry.desktop';

    for (final directory in _paths.desktopApplicationDirs()) {
      try {
        final direct = File(p.join(directory.path, normalizedEntry));
        if (direct.existsSync()) {
          final icon = _readDesktopEntryFields(direct)['Icon']?.trim() ?? '';
          if (icon.isNotEmpty) {
            final resolved = resolveIconPath(icon);
            if (resolved != null) {
              return resolved;
            }
          }
        }
        if (!directory.existsSync()) {
          continue;
        }
        for (final entity in directory.listSync(
          recursive: true,
          followLinks: false,
        )) {
          if (!entity.path.endsWith('.desktop') ||
              FileSystemEntity.typeSync(entity.path, followLinks: true) !=
                  FileSystemEntityType.file) {
            continue;
          }
          final relative = p.relative(entity.path, from: directory.path);
          final desktopFileId = p.split(relative).join('-');
          if (desktopFileId != normalizedEntry) {
            continue;
          }
          final icon =
              _readDesktopEntryFields(File(entity.path))['Icon']?.trim() ?? '';
          if (icon.isNotEmpty) {
            final resolved = resolveIconPath(icon);
            if (resolved != null) {
              return resolved;
            }
          }
        }
      } on FileSystemException {
        continue;
      }
    }
    return null;
  }
}

class DesktopAppsWatcher {
  DesktopAppsWatcher._(this._subscriptions);

  final List<StreamSubscription<FileSystemEvent>> _subscriptions;
  bool _disposed = false;

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await Future.wait(
      _subscriptions.map((subscription) => subscription.cancel()),
    );
  }
}

bool _isDesktopApplicationEvent(FileSystemEvent event) {
  if (event.path.endsWith('.desktop')) {
    return true;
  }
  return event is FileSystemMoveEvent &&
      (event.destination?.endsWith('.desktop') ?? false);
}

const List<String> _preferredIconSizes = <String>[
  'scalable',
  '512x512',
  '256x256',
  '192x192',
  '128x128',
  '96x96',
  '64x64',
  '48x48',
  '36x36',
  '32x32',
  '24x24',
  '22x22',
  '16x16',
];

const List<String> _preferredIconContexts = <String>[
  'apps',
  'status',
  'actions',
  'devices',
  'categories',
  'places',
  'mimetypes',
  'legacy',
  'panel',
  'ui',
];

List<String> _iconThemeDirectories(String theme) {
  final directories = <String>[
    for (final size in _preferredIconSizes)
      for (final context in _preferredIconContexts) p.join(size, context),
    for (final context in _preferredIconContexts) p.join('symbolic', context),
  ];
  final index = File(p.join(theme, 'index.theme'));
  try {
    var inIconTheme = false;
    for (final rawLine in index.readAsLinesSync()) {
      final line = rawLine.trim();
      if (line.startsWith('[') && line.endsWith(']')) {
        inIconTheme = line == '[Icon Theme]';
        continue;
      }
      if (!inIconTheme) {
        continue;
      }
      final equals = line.indexOf('=');
      if (equals <= 0) {
        continue;
      }
      final key = line.substring(0, equals);
      if (key != 'Directories' && key != 'ScaledDirectories') {
        continue;
      }
      for (final value in line.substring(equals + 1).split(',')) {
        final directory = value.trim();
        if (_isSafeRelativeIconDirectory(directory)) {
          directories.add(directory);
        }
      }
    }
  } on FileSystemException {
    // Themes without an index still get the conventional lookup paths above.
  }
  return RuntimePaths.uniquePaths(directories);
}

bool _isSafeRelativeIconDirectory(String value) {
  if (value.isEmpty || p.isAbsolute(value)) {
    return false;
  }
  return !p
      .split(value)
      .any(
        (component) =>
            component.isEmpty || component == '.' || component == '..',
      );
}

String? _localIconPath(String value) {
  if (p.isAbsolute(value)) {
    return value;
  }
  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme != 'file') {
    return null;
  }
  try {
    return uri.toFilePath();
  } on FormatException {
    return null;
  } on UnsupportedError {
    return null;
  }
}

Map<String, String> _readDesktopEntryFields(File file) {
  final fields = <String, String>{};
  var inDesktopEntry = false;
  for (final rawLine in file.readAsLinesSync()) {
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
  return fields;
}

bool _desktopEntryMatchesAppName(
  Map<String, String> fields, {
  required String file,
  required String directory,
  required String requestedName,
}) {
  final relative = p.relative(file, from: directory);
  final desktopFileId = p.split(relative).join('-');
  final identities = <String>[
    desktopFileId.substring(0, desktopFileId.length - '.desktop'.length),
    fields['Name'] ?? '',
    fields['GenericName'] ?? '',
    fields['StartupWMClass'] ?? '',
    fields['X-GNOME-FullName'] ?? '',
    for (final entry in fields.entries)
      if (entry.key.startsWith('Name[')) entry.value,
  ];
  for (final identity in identities) {
    final normalized = _normalizedDesktopIdentity(identity);
    if (normalized == requestedName ||
        (requestedName.length >= 4 && normalized.endsWith(requestedName)) ||
        (normalized.length >= 4 && requestedName.endsWith(normalized))) {
      return true;
    }
  }
  return false;
}

String _normalizedDesktopIdentity(String value) {
  return value.toLowerCase().replaceAll(_desktopIdentityNoise, '');
}

final RegExp _desktopIdentityNoise = RegExp('[^a-z0-9]');

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
