import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:denial_dart_shell/src/launcher/runtime_paths.dart';
import 'package:denial_dart_shell/src/wallpaper/state/wallpaper_controller.dart';
import 'package:denial_dart_shell/src/wallpaper/wallpaper.dart';
import 'package:denial_dart_shell/src/wallpaper/wallpaper_provider.dart';

import '../support/wallpaper_controller_harness.dart';

void main() {
  test('committing a wallpaper keeps the selector open', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'denial-wallpaper-test-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final resource = WallpaperResource.file('${temporary.path}/selected.jpg');
    await File(resource.path).writeAsBytes(const <int>[1, 2, 3]);
    final candidate = WallpaperCandidate(
      id: 'selected',
      providerId: 'fake',
      label: 'Selected',
      previewUri: Uri.file(resource.path),
      width: 1920,
      height: 1080,
      resource: resource,
    );
    final source = _FakeWallpaperProvider(candidate);
    final store = WallpaperStore(
      RuntimePaths(
        environment: <String, String>{
          'HOME': temporary.path,
          'XDG_STATE_HOME': '${temporary.path}/state',
        },
      ),
    );
    final harness = WallpaperControllerTestHarness(
      sources: <WallpaperProvider>[source],
      store: store,
    );
    final controller = harness.controller;

    controller.openSelector(targetPixelSize: const Size(1920, 1080));
    await pumpEventQueue();
    final resolved = await controller.resolveCandidate(candidate);
    controller.commitCandidate(
      candidate,
      resolved!,
      revealOriginFraction: const Offset(0.25, 0.75),
    );

    expect(harness.state.selectorVisible, isTrue);
    expect(harness.state.current, resource);
    expect(harness.state.outgoing, WallpaperResource.defaultWallpaper);
    expect(harness.state.revealOriginFraction, const Offset(0.25, 0.75));

    controller.completeTransition(harness.state.transitionId);
    expect(harness.state.outgoing, isNull);
  });

  test('per-monitor overrides are isolated and All clears them', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'denial-wallpaper-target-test-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final base = WallpaperResource.file('${temporary.path}/base.jpg');
    final left = WallpaperResource.file('${temporary.path}/left.jpg');
    for (final resource in <WallpaperResource>[base, left]) {
      await File(resource.path).writeAsBytes(const <int>[1, 2, 3]);
    }
    final harness = WallpaperControllerTestHarness(
      sources: const <WallpaperProvider>[],
      store: WallpaperStore(
        RuntimePaths(
          environment: <String, String>{
            'HOME': temporary.path,
            'XDG_STATE_HOME': '${temporary.path}/state',
          },
        ),
      ),
    );
    final controller = harness.controller;
    final candidate = WallpaperCandidate(
      id: 'direct',
      providerId: 'direct',
      label: 'Direct',
      previewUri: Uri.file(base.path),
      width: 2560,
      height: 1440,
    );

    controller.openSelector(targetPixelSize: const Size(2560, 1440));
    controller.commitCandidate(
      candidate,
      base,
      revealOriginFraction: const Offset(0.5, 0.5),
    );
    controller.completeTransition(harness.state.transitionId);
    controller.selectTarget(
      target: const WallpaperTarget.output('DP-5'),
      targetPixelSize: const Size(2560, 1440),
    );
    controller.commitCandidate(
      candidate,
      left,
      revealOriginFraction: const Offset(0.4, 0.6),
    );

    expect(harness.state.assignment.all, base);
    expect(harness.state.assignment.forOutput('DP-5'), left);
    expect(harness.state.assignment.forOutput('DP-4'), base);
    expect(
      harness.state.transitionTarget,
      const WallpaperTarget.output('DP-5'),
    );

    controller.completeTransition(harness.state.transitionId);
    controller.selectTarget(
      target: const WallpaperTarget.all(),
      targetPixelSize: const Size(2560, 1440),
    );
    controller.commitCandidate(
      candidate,
      base,
      revealOriginFraction: const Offset(0.5, 0.5),
    );

    expect(harness.state.assignment.all, base);
    expect(harness.state.assignment.outputOverrides, isEmpty);
    expect(harness.state.assignment.forOutput('DP-5'), base);
  });

  test('darkness supports per-monitor overrides and All resets them', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'denial-wallpaper-darkness-test-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final harness = WallpaperControllerTestHarness(
      sources: const <WallpaperProvider>[],
      store: WallpaperStore(
        RuntimePaths(
          environment: <String, String>{
            'HOME': temporary.path,
            'XDG_STATE_HOME': '${temporary.path}/state',
          },
        ),
      ),
    );
    final controller = harness.controller;

    controller.openSelector(targetPixelSize: const Size(2560, 1440));
    controller.setDarkness(0.25);
    controller.commitDarkness(0.25);
    controller.selectTarget(
      target: const WallpaperTarget.output('DP-5'),
      targetPixelSize: const Size(2560, 1440),
    );
    controller.setDarkness(0.7);
    controller.commitDarkness(0.7);

    expect(harness.state.assignment.allDarkness, 0.25);
    expect(harness.state.assignment.darknessForOutput('DP-5'), 0.7);
    expect(harness.state.assignment.darknessForOutput('DP-4'), 0.25);
    expect(harness.state.assignment.outputDarknessOverrides, <String, double>{
      'DP-5': 0.7,
    });

    controller.selectTarget(
      target: const WallpaperTarget.all(),
      targetPixelSize: const Size(5120, 1440),
    );
    controller.setDarkness(0.4);
    controller.commitDarkness(0.4);

    expect(harness.state.assignment.allDarkness, 0.4);
    expect(harness.state.assignment.outputDarknessOverrides, isEmpty);
    expect(harness.state.assignment.darknessForOutput('DP-5'), 0.4);
    await pumpEventQueue();
  });

  test(
    'alignment supports per-monitor overrides and All resets them',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'denial-wallpaper-alignment-test-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final harness = WallpaperControllerTestHarness(
        sources: const <WallpaperProvider>[],
        store: WallpaperStore(
          RuntimePaths(environment: <String, String>{'HOME': temporary.path}),
        ),
      );
      final controller = harness.controller;

      controller.openSelector(targetPixelSize: const Size(5120, 1440));
      controller.commitSpanAlignment(
        const WallpaperSpanAlignment.precise(x: 0.25, y: -0.4),
      );
      controller.selectTarget(
        target: const WallpaperTarget.output('DP-5'),
        targetPixelSize: const Size(2560, 1440),
      );

      expect(
        harness.state.assignment.alignmentForTarget(harness.state.target),
        const WallpaperSpanAlignment(),
      );

      controller.commitSpanAlignment(
        const WallpaperSpanAlignment.precise(x: -0.7, y: 0.6),
      );

      expect(
        harness.state.assignment.spanAlignment,
        const WallpaperSpanAlignment.precise(x: 0.25, y: -0.4),
      );
      expect(
        harness.state.assignment.alignmentForOutput('DP-5'),
        const WallpaperSpanAlignment.precise(x: -0.7, y: 0.6),
      );
      expect(
        harness.state.assignment.alignmentForOutput('DP-4'),
        const WallpaperSpanAlignment(),
      );

      controller.selectTarget(
        target: const WallpaperTarget.all(),
        targetPixelSize: const Size(5120, 1440),
      );
      controller.commitSpanAlignment(
        const WallpaperSpanAlignment.precise(x: 0.1, y: 0.2),
      );

      expect(harness.state.assignment.outputAlignmentOverrides, isEmpty);
      expect(
        harness.state.assignment.spanAlignment,
        const WallpaperSpanAlignment.precise(x: 0.1, y: 0.2),
      );
      await pumpEventQueue();
    },
  );

  test('wallpaper assignments persist and legacy values migrate', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'denial-wallpaper-store-test-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final paths = RuntimePaths(
      environment: <String, String>{
        'HOME': temporary.path,
        'XDG_STATE_HOME': '${temporary.path}/state',
      },
    );
    final store = WallpaperStore(paths);
    final legacy = WallpaperResource.file('${temporary.path}/legacy.jpg');
    final right = WallpaperResource.file('${temporary.path}/right.png');
    await File(legacy.path).writeAsBytes(const <int>[1]);
    await File(right.path).writeAsBytes(const <int>[2]);
    final stateFile = await paths.wallpaperStateFile();
    await stateFile.writeAsString('${legacy.persistenceValue}\n');

    expect(await store.read(), WallpaperAssignment(all: legacy));

    final assignment = WallpaperAssignment(
      all: legacy,
      spanAlignment: const WallpaperSpanAlignment.precise(x: 0.37, y: -0.64),
      allDarkness: 0.3,
      outputOverrides: <String, WallpaperResource>{'DP-4': right},
      outputAlignmentOverrides: const <String, WallpaperSpanAlignment>{
        'DP-4': WallpaperSpanAlignment.precise(x: -0.45, y: 0.72),
      },
      outputDarknessOverrides: const <String, double>{'DP-4': 0.65},
    );
    await store.write(assignment);

    expect(await store.read(), assignment);

    await stateFile.writeAsString(
      '{"version":3,"all":"asset:$defaultShellWallpaperAsset",'
      '"horizontalAlignment":"left","verticalAlignment":"bottom"}\n',
    );
    expect(
      (await store.read())!.spanAlignment,
      const WallpaperSpanAlignment(
        horizontal: WallpaperHorizontalAlignment.left,
        vertical: WallpaperVerticalAlignment.bottom,
      ),
    );
  });

  test('changing monitor target reruns the query for its resolution', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'denial-wallpaper-query-target-test-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final source = _RecordingWallpaperProvider();
    final harness = WallpaperControllerTestHarness(
      sources: <WallpaperProvider>[source],
      store: WallpaperStore(
        RuntimePaths(environment: <String, String>{'HOME': temporary.path}),
      ),
    );
    final controller = harness.controller;

    controller.openSelector(targetPixelSize: const Size(2560, 1440));
    await pumpEventQueue();
    controller.setQuery('forest');
    controller.submitQuery();
    await pumpEventQueue();
    controller.selectTarget(
      target: const WallpaperTarget.output('portrait'),
      targetPixelSize: const Size(2160, 3840),
    );
    await pumpEventQueue();

    expect(source.queries.last.text, 'forest');
    expect(source.queries.last.targetPixelSize, const Size(2160, 3840));
  });
}

class _FakeWallpaperProvider implements WallpaperProvider {
  const _FakeWallpaperProvider(this.candidate);

  final WallpaperCandidate candidate;

  @override
  String get id => 'fake';

  @override
  String get displayName => 'Fake';

  @override
  Future<WallpaperPage> search(WallpaperQuery query) async {
    return WallpaperPage(
      items: <WallpaperCandidate>[candidate],
      page: 1,
      hasMore: false,
    );
  }

  @override
  Future<WallpaperResource> materialize(
    WallpaperCandidate candidate, {
    WallpaperDownloadProgress? onProgress,
  }) async {
    onProgress?.call(1.0);
    return candidate.resource!;
  }

  @override
  void dispose() {}
}

class _RecordingWallpaperProvider implements WallpaperProvider {
  final List<WallpaperQuery> queries = <WallpaperQuery>[];

  @override
  String get id => 'recording';

  @override
  String get displayName => 'Recording';

  @override
  Future<WallpaperPage> search(WallpaperQuery query) async {
    queries.add(query);
    return WallpaperPage(
      items: const <WallpaperCandidate>[],
      page: query.page,
      hasMore: false,
    );
  }

  @override
  Future<WallpaperResource> materialize(
    WallpaperCandidate candidate, {
    WallpaperDownloadProgress? onProgress,
  }) {
    throw UnsupportedError('not used by this test');
  }

  @override
  void dispose() {}
}
