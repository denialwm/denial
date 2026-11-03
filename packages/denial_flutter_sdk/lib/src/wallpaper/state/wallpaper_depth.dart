import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../launcher/launcher_providers.dart';
import '../../launcher/runtime_paths.dart';
import '../../settings/settings_controller.dart';
import '../../state/display_layout.dart';
import '../wallpaper.dart';
import 'wallpaper_controller.dart';

/// Lock-screen depth masks from the optional `wallpaper-depth` program
/// (Phonewave's services/wallpaper/wallpaper-depth), which cuts the
/// wallpaper's subject out so the lock screen can draw its clock behind it.
/// Without the program on `PATH` nothing runs and the lock screen draws no
/// cut.
///
/// The state counts the masks written, so the lock screen knows when to read
/// the cache again. It counts every new sidecar in the cache, whoever ran the
/// program: the phone's Settings makes the mask of a wallpaper it sets.
final wallpaperDepthProvider = NotifierProvider<WallpaperDepth, int>(
  WallpaperDepth.new,
);

/// Where `wallpaper-depth` writes `lock-mask.png` and the `lock-mask.json`
/// sidecar naming the wallpaper it belongs to.
String wallpaperDepthDirectory(RuntimePaths paths) =>
    p.join(paths.cacheHome, 'denial', 'wallpaper-depth');

class WallpaperDepth extends Notifier<int> {
  bool _running = false;
  String? _next;

  @override
  int build() {
    unawaited(_follow());
    return 0;
  }

  /// Counts each `lock-mask.json` the program renames into the cache: it
  /// writes the sidecar last, so the mask beside it is complete.
  Future<void> _follow() async {
    final paths = ref.read(runtimePathsProvider);
    if (_program(paths) == null) return;
    try {
      final directory = Directory(wallpaperDepthDirectory(paths)).absolute;
      await directory.create(recursive: true);
      if (!ref.mounted) return;
      final sidecar = p.join(directory.path, 'lock-mask.json');
      final subscription = directory
          .watch(events: FileSystemEvent.create | FileSystemEvent.move)
          .where(
            (event) =>
                event.path == sidecar ||
                (event is FileSystemMoveEvent && event.destination == sidecar),
          )
          .listen((_) {
            if (ref.mounted) state++;
          });
      ref.onDispose(subscription.cancel);
    } on FileSystemException catch (error) {
      debugPrint('wallpaper-depth: cannot follow the cache: $error');
    }
  }

  /// Makes the mask for the wallpaper the lock screen shows, once the picker
  /// has closed.
  void pickerClosed() {
    final paths = ref.read(runtimePathsProvider);
    if (_program(paths) == null ||
        !ref.read(shellSettingsProvider).lockScreen.useSystemWallpaper) {
      return;
    }
    final assignment = ref.read(wallpaperControllerProvider).assignment;
    final output = ref.read(displayLayoutProvider)?.mainOutput?.name;
    final resource = output == null
        ? assignment.all
        : assignment.forOutput(output);
    if (resource.kind == WallpaperResourceKind.file) {
      _request(resource.path);
    }
  }

  /// One mask at a time: a request made while one runs waits for it, and
  /// only the latest one does.
  void _request(String wallpaper) {
    if (_running) {
      _next = wallpaper;
      return;
    }
    unawaited(_run(wallpaper));
  }

  Future<void> _run(String wallpaper) async {
    _running = true;
    try {
      final paths = ref.read(runtimePathsProvider);
      final program = _program(paths);
      if (program == null || await _cached(paths, wallpaper)) return;
      final process = await Process.start(program, ['mask', wallpaper]);
      unawaited(process.stdout.drain<void>());
      final errors = process.stderr.transform(utf8.decoder).join();
      final code = await process.exitCode;
      if (code != 0) {
        final lines = (await errors).trim().split('\n');
        debugPrint('wallpaper-depth: $wallpaper failed ($code): ${lines.last}');
      }
    } on Object catch (error) {
      debugPrint('wallpaper-depth: $error');
    } finally {
      _running = false;
      final next = _next;
      _next = null;
      if (next != null && ref.mounted) _request(next);
    }
  }

  static String? _program(RuntimePaths paths) {
    for (final directory in (paths.environment['PATH'] ?? '').split(':')) {
      if (directory.isEmpty) continue;
      final candidate = p.join(directory, 'wallpaper-depth');
      final stat = FileStat.statSync(candidate);
      if (stat.type == FileSystemEntityType.file && stat.mode & 0x49 != 0) {
        return candidate;
      }
    }
    return null;
  }

  /// Whether the cache holds a mask for [wallpaper] made after the file was
  /// last changed.
  static Future<bool> _cached(RuntimePaths paths, String wallpaper) async {
    try {
      final directory = wallpaperDepthDirectory(paths);
      final sidecar = jsonDecode(
        await File(p.join(directory, 'lock-mask.json')).readAsString(),
      );
      if (sidecar is! Map || sidecar['wallpaper'] != wallpaper) return false;
      final mask = await File(p.join(directory, 'lock-mask.png'))
          .lastModified();
      return mask.isAfter(await File(wallpaper).lastModified());
    } on Object {
      return false;
    }
  }
}
