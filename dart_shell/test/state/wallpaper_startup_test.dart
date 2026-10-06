import 'dart:convert';
import 'dart:io';

import 'package:denial_dart_shell/src/launcher/runtime_paths.dart';
import 'package:denial_dart_shell/src/state/display_layout.dart';
import 'package:denial_dart_shell/src/wallpaper/state/wallpaper_accent.dart';
import 'package:denial_dart_shell/src/wallpaper/state/wallpaper_controller.dart';
import 'package:denial_dart_shell/src/wallpaper/wallpaper.dart';
import 'package:denial_dart_shell/src/wallpaper/wallpaper_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'a preloaded custom wallpaper is the only startup decode target',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'denial-wallpaper-startup-',
      );
      addTearDown(() => root.delete(recursive: true));

      final customFile = File('${root.path}/custom.png');
      await customFile.writeAsBytes(const <int>[0]);
      final custom = WallpaperResource.file(customFile.path);
      final paths = RuntimePaths(
        environment: <String, String>{
          'HOME': root.path,
          'XDG_STATE_HOME': '${root.path}/state',
        },
      );
      final stateFile = await paths.wallpaperStateFile();
      await stateFile.writeAsString(
        '${jsonEncode(<String, Object>{'version': 5, 'all': custom.persistenceValue})}\n',
      );

      final store = _StartupWallpaperStore(paths);
      final initialAssignment = await store.read();
      expect(initialAssignment, isNotNull);
      expect(initialAssignment!.all, custom);

      final decodeTargets = <WallpaperResource>[];
      final container = ProviderContainer.test(
        overrides: [
          wallpaperSourcesProvider.overrideWithValue(
            const <WallpaperProvider>[],
          ),
          wallpaperStoreProvider.overrideWithValue(store),
          initialWallpaperAssignmentProvider.overrideWithValue(
            initialAssignment,
          ),
          wallpaperAccentExtractorProvider.overrideWithValue((resource) async {
            decodeTargets.add(resource);
            return null;
          }),
          displayLayoutProvider.overrideWithBuild((ref, controller) => null),
        ],
      );
      addTearDown(container.dispose);

      final initialState = container.read(wallpaperControllerProvider);
      container.read(wallpaperAccentProvider);
      await Future<void>.delayed(Duration.zero);

      expect(initialState.assignment.all, custom);
      expect(decodeTargets, <WallpaperResource>[custom]);
      expect(
        decodeTargets,
        isNot(contains(WallpaperResource.defaultWallpaper)),
      );
      expect(store.readCount, 1);
    },
  );
}

class _StartupWallpaperStore extends WallpaperStore {
  _StartupWallpaperStore(super.paths);

  int readCount = 0;

  @override
  Future<WallpaperAssignment?> read() {
    readCount += 1;
    return super.read();
  }

  @override
  Future<Stream<FileSystemEvent>> watch() async => const Stream.empty();
}
