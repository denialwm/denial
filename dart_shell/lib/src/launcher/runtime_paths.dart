import 'dart:io';

import 'package:path/path.dart' as p;

class RuntimePaths {
  RuntimePaths({required Map<String, String> environment})
    : environment = Map.unmodifiable(environment);

  final Map<String, String> environment;

  String get homeDir => environment['HOME'] ?? '/home/logix';

  String get configHome =>
      environment['XDG_CONFIG_HOME'] ?? p.join(homeDir, '.config');

  String get dataHome =>
      environment['XDG_DATA_HOME'] ?? p.join(homeDir, '.local', 'share');

  String get stateHome =>
      environment['XDG_STATE_HOME'] ?? p.join(homeDir, '.local', 'state');

  String get cacheHome =>
      environment['XDG_CACHE_HOME'] ?? p.join(homeDir, '.cache');

  String get wallpaperDirectory =>
      environment['DENIA_WALLPAPER_DIR'] ??
      p.join(homeDir, 'Pictures', 'Wallpapers');

  List<String> get dataDirs {
    return (environment['XDG_DATA_DIRS'] ?? '/usr/local/share:/usr/share')
        .split(':')
        .where((dir) => dir.isNotEmpty)
        .toList(growable: false);
  }

  String get powerdControlSocketPath =>
      environment['DENIA_POWERD_CONTROL_SOCKET'] ??
      '/run/denia-powerd/control.sock';

  Future<File> layoutFile() async {
    final dir = Directory(p.join(configHome, 'denia-home'));
    await dir.create(recursive: true);
    return File(p.join(dir.path, 'layout.json'));
  }

  Future<File> wallpaperStateFile() async {
    final dir = Directory(p.join(stateHome, 'denial'));
    await dir.create(recursive: true);
    return File(p.join(dir.path, 'wallpaper'));
  }

  Future<File> settingsFile() async {
    final dir = Directory(p.join(configHome, 'denial'));
    await dir.create(recursive: true);
    return File(p.join(dir.path, 'settings.json'));
  }

  String get settingsPath => p.join(configHome, 'denial', 'settings.json');

  Future<File> notificationPolicyFile() async {
    final dir = Directory(p.join(stateHome, 'denial'));
    await dir.create(recursive: true);
    return File(p.join(dir.path, 'notifications.json'));
  }

  List<Directory> desktopApplicationDirs() {
    final paths = <String>[
      p.join(dataHome, 'applications'),
      for (final dir in dataDirs) p.join(dir, 'applications'),
      p.join(
        homeDir,
        '.local',
        'share',
        'flatpak',
        'exports',
        'share',
        'applications',
      ),
      '/var/lib/flatpak/exports/share/applications',
    ];

    return uniquePaths(paths).map(Directory.new).toList(growable: false);
  }

  List<String> iconRoots() {
    return uniquePaths([
      dataHome,
      ...dataDirs,
      p.join(homeDir, '.local', 'share', 'flatpak', 'exports', 'share'),
      '/var/lib/flatpak/exports/share',
    ]);
  }

  static List<String> uniquePaths(Iterable<String> paths) {
    final seen = <String>{};
    final unique = <String>[];
    for (final path in paths) {
      if (path.isEmpty || !seen.add(path)) {
        continue;
      }
      unique.add(path);
    }
    return unique;
  }
}
