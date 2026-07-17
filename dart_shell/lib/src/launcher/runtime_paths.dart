import 'dart:io';

class RuntimePaths {
  RuntimePaths({required Map<String, String> environment})
      : environment = Map.unmodifiable(environment);

  final Map<String, String> environment;

  String get homeDir => environment['HOME'] ?? '/home/logix';

  String get configHome => environment['XDG_CONFIG_HOME'] ?? '$homeDir/.config';

  String get dataHome =>
      environment['XDG_DATA_HOME'] ?? '$homeDir/.local/share';

  String get stateHome =>
      environment['XDG_STATE_HOME'] ?? '$homeDir/.local/state';

  String get cacheHome => environment['XDG_CACHE_HOME'] ?? '$homeDir/.cache';

  String get wallpaperDirectory =>
      environment['DENIA_WALLPAPER_DIR'] ?? '$homeDir/Pictures/Wallpapers';

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
    final dir = Directory('$configHome/denia-home');
    await dir.create(recursive: true);
    return File('${dir.path}/layout.json');
  }

  Future<File> wallpaperStateFile() async {
    final dir = Directory('$stateHome/denial');
    await dir.create(recursive: true);
    return File('${dir.path}/wallpaper');
  }

  Future<File> notificationPolicyFile() async {
    final dir = Directory('$stateHome/denial');
    await dir.create(recursive: true);
    return File('${dir.path}/notifications.json');
  }

  List<Directory> desktopApplicationDirs() {
    final paths = <String>[
      '$dataHome/applications',
      for (final dir in dataDirs) '$dir/applications',
      '$homeDir/.local/share/flatpak/exports/share/applications',
      '/var/lib/flatpak/exports/share/applications',
    ];

    return uniquePaths(paths).map(Directory.new).toList(growable: false);
  }

  List<String> iconRoots() {
    return uniquePaths([
      dataHome,
      ...dataDirs,
      '$homeDir/.local/share/flatpak/exports/share',
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
